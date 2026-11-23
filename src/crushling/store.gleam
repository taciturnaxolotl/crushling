//// The bridge's state, in one SQLite file, `<root>/crushling.db`: the Slack
//// workspaces it serves (`teams`, bot tokens encrypted), their settings,
//// each thread's `meta`, and the links from code channels to threads.
////
//// One actor owns the connection, so writes are serialized; every call runs
//// on it. The schema is versioned with `PRAGMA user_version` and migrated on
//// start. Bot tokens are sealed with AES-256-GCM under the store key (from
//// `CRUSHLING_STORE_KEY`, else `<root>/store-key`), with a fresh nonce per
//// value and the team id as associated data.
////
//// Before the store, meta and links were files under `<root>`. The first
//// start imports them (`import_files`) and never reads them again.

import crushling/meta.{type Link, type Meta, Link, Meta}
import crushling/sys
import crushling/venue
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import sqlight

pub opaque type Store {
  Store(subject: Subject(Message))
}

type Message {
  Run(job: fn(sqlight.Connection, BitArray) -> Nil)
  Close(reply: Subject(Nil))
}

/// A Slack workspace the bridge serves.
pub type Team {
  Team(
    id: String,
    /// The `xoxb-` token, decrypted.
    bot_token: String,
    bot_user: String,
    enterprise_id: Option(String),
    /// Who installed the app, "" when seeded from the environment.
    installed_by: String,
    /// Unix seconds.
    installed_at: Int,
    active: Bool,
  )
}

/// A thread's saved state.
pub type Thread {
  Thread(
    key: String,
    team: String,
    channel: String,
    thread_ts: String,
    meta: Meta,
  )
}

const timeout_ms = 10_000

/// The migrations, in order. `PRAGMA user_version` is how many have run.
const migrations = [
  "CREATE TABLE teams (
    team_id TEXT PRIMARY KEY,
    bot_token_enc BLOB NOT NULL,
    bot_user TEXT NOT NULL,
    enterprise_id TEXT,
    installed_by TEXT NOT NULL DEFAULT '',
    installed_at INTEGER NOT NULL,
    active INTEGER NOT NULL DEFAULT 1
  );
  CREATE TABLE team_settings (
    team_id TEXT NOT NULL REFERENCES teams(team_id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    value TEXT NOT NULL,
    PRIMARY KEY (team_id, name)
  );
  CREATE TABLE threads (
    key TEXT PRIMARY KEY,
    team_id TEXT NOT NULL,
    channel TEXT NOT NULL,
    thread_ts TEXT NOT NULL,
    follow INTEGER NOT NULL,
    paused INTEGER NOT NULL,
    cursor TEXT NOT NULL,
    venue TEXT NOT NULL,
    tailnet TEXT,
    updated_at INTEGER NOT NULL
  );
  CREATE INDEX threads_team ON threads (team_id);
  CREATE TABLE links (
    team_id TEXT NOT NULL,
    channel TEXT NOT NULL,
    origin_channel TEXT NOT NULL,
    origin_ts TEXT NOT NULL,
    opened_ts TEXT NOT NULL,
    PRIMARY KEY (team_id, channel)
  );
  CREATE TABLE bridge (name TEXT PRIMARY KEY, value TEXT NOT NULL);",
  // The model picked with `!model`, as JSON, or NULL for the default.
  "ALTER TABLE threads ADD COLUMN model TEXT;",
]

/// The schema version this code writes.
pub fn schema_version() -> Int {
  list.length(migrations)
}

// Opening ---------------------------------------------------------------------

/// Open (or create) the store at `path`, migrate it, and start its actor.
/// `key` is the 32-byte store key.
pub fn start(path: String, key: BitArray) -> Result(Store, String) {
  use _ <- result.try(case bit_array.byte_size(key) {
    32 -> Ok(Nil)
    _ -> Error("the store key must be 32 bytes")
  })
  actor.new_with_initialiser(timeout_ms, fn(self) {
    use connection <- result.try(
      sqlight.open(path) |> result.map_error(describe),
    )
    use _ <- result.try(
      sqlight.exec(
        "PRAGMA journal_mode = WAL;
         PRAGMA foreign_keys = ON;
         PRAGMA busy_timeout = 5000;
         PRAGMA synchronous = NORMAL;",
        connection,
      )
      |> result.map_error(describe),
    )
    use _ <- result.try(migrate(connection))
    actor.initialised(#(connection, key))
    |> actor.returning(Store(self))
    |> Ok
  })
  |> actor.on_message(fn(state, message) {
    let #(connection, key) = state
    case message {
      Run(job) -> {
        job(connection, key)
        actor.continue(state)
      }
      Close(reply) -> {
        let _ = sqlight.close(connection)
        process.send(reply, Nil)
        actor.stop()
      }
    }
  })
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.map_error(fn(error) {
    case error {
      actor.InitFailed(reason) -> "store " <> path <> ": " <> reason
      _ -> "store " <> path <> ": " <> string.inspect(error)
    }
  })
}

/// Close the connection and stop the actor.
pub fn close(store: Store) -> Nil {
  let _ = process.call(store.subject, timeout_ms, Close)
  Nil
}

fn migrate(connection: sqlight.Connection) -> Result(Nil, String) {
  use version <- result.try(user_version(connection))
  migrations
  |> list.drop(version)
  |> list.index_fold(Ok(Nil), fn(acc, sql, i) {
    use _ <- result.try(acc)
    let to = version + i + 1
    sqlight.exec(
      "BEGIN;\n"
        <> sql
        <> "\nPRAGMA user_version = "
        <> int.to_string(to)
        <> ";\nCOMMIT;",
      connection,
    )
    |> result.map_error(fn(error) {
      let _ = sqlight.exec("ROLLBACK;", connection)
      "migration " <> int.to_string(to) <> ": " <> describe(error)
    })
  })
}

fn user_version(connection: sqlight.Connection) -> Result(Int, String) {
  sqlight.query(
    "PRAGMA user_version",
    connection,
    [],
    decode.field(0, decode.int, decode.success),
  )
  |> result.map_error(describe)
  |> result.map(fn(rows) { list.first(rows) |> result.unwrap(0) })
}

/// The schema version of an open store.
pub fn version(store: Store) -> Result(Int, String) {
  run(store, fn(connection, _) { user_version(connection) })
}

fn describe(error: sqlight.Error) -> String {
  "sqlite: " <> error.message
}

/// Run `job` on the store's actor and wait for its answer.
fn run(
  store: Store,
  job: fn(sqlight.Connection, BitArray) -> Result(a, String),
) -> Result(a, String) {
  let reply = process.new_subject()
  process.send(
    store.subject,
    Run(fn(connection, key) { process.send(reply, job(connection, key)) }),
  )
  process.receive(reply, timeout_ms)
  |> result.replace_error("the store didn't answer in time")
  |> result.flatten
}

fn query(
  connection: sqlight.Connection,
  sql: String,
  with: List(sqlight.Value),
  expecting: decode.Decoder(a),
) -> Result(List(a), String) {
  sqlight.query(sql, connection, with, expecting)
  |> result.map_error(describe)
}

fn exec(
  connection: sqlight.Connection,
  sql: String,
  with: List(sqlight.Value),
) -> Result(Nil, String) {
  query(connection, sql, with, decode.success(Nil))
  |> result.replace(Nil)
}

// The key ---------------------------------------------------------------------

/// The store key: `from_env` (`CRUSHLING_STORE_KEY`, base64) if set, else
/// `<root>/store-key`, made with a fresh key if it doesn't exist yet. The
/// second value says whether it was just made.
pub fn load_key(
  from_env: Result(String, Nil),
  root: String,
) -> Result(#(BitArray, Bool), String) {
  case from_env {
    Ok(text) ->
      parse_key(text)
      |> result.map(fn(key) { #(key, False) })
      |> result.map_error(fn(reason) { "CRUSHLING_STORE_KEY " <> reason })
    Error(Nil) -> {
      let path = root <> "/store-key"
      case read_file(path) {
        Ok(text) ->
          parse_key(text)
          |> result.map(fn(key) { #(key, False) })
          |> result.map_error(fn(reason) { path <> " " <> reason })
        Error(Nil) -> {
          let key = random_key()
          use _ <- result.try(mkdir_p(root))
          use _ <- result.map(write_private(
            path,
            bit_array.base64_encode(key, True) <> "\n",
          ))
          #(key, True)
        }
      }
    }
  }
}

pub fn parse_key(text: String) -> Result(BitArray, String) {
  case bit_array.base64_decode(string.trim(text)) {
    Ok(key) ->
      case bit_array.byte_size(key) {
        32 -> Ok(key)
        _ -> Error("must be 32 bytes, base64")
      }
    Error(Nil) -> Error("is not base64")
  }
}

/// Seal `plain` under `key`, bound to `aad`.
@external(erlang, "crushling_store_ffi", "seal")
pub fn seal(key: BitArray, aad: BitArray, plain: BitArray) -> BitArray

/// Open what `seal` sealed; an error for the wrong key, `aad` or a damaged
/// value.
@external(erlang, "crushling_store_ffi", "open")
pub fn unseal(
  key: BitArray,
  aad: BitArray,
  sealed: BitArray,
) -> Result(BitArray, Nil)

@external(erlang, "crushling_store_ffi", "random_key")
fn random_key() -> BitArray

@external(erlang, "crushling_ffi", "read_file")
fn read_file(path: String) -> Result(String, Nil)

@external(erlang, "crushling_ffi", "mkdir_p")
fn mkdir_p(path: String) -> Result(Nil, String)

@external(erlang, "crushling_ffi", "write_private")
fn write_private(path: String, content: String) -> Result(Nil, String)

@external(erlang, "crushling_ffi", "list_dir")
fn list_dir(path: String) -> Result(List(String), Nil)

fn now_seconds() -> Int {
  sys.system_ms() / 1000
}

// Teams -----------------------------------------------------------------------

/// Add a team. A team already there (a reinstall, or the self-host
/// workspace on every start) gets the new token, bot user, organization and
/// active flag, and keeps who installed it and when.
pub fn put_team(store: Store, team: Team) -> Result(Nil, String) {
  use connection, key <- run(store)
  let sealed =
    seal(
      key,
      bit_array.from_string(team.id),
      bit_array.from_string(team.bot_token),
    )
  exec(
    connection,
    "INSERT INTO teams
       (team_id, bot_token_enc, bot_user, enterprise_id, installed_by,
        installed_at, active)
     VALUES (?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT (team_id) DO UPDATE SET
       bot_token_enc = excluded.bot_token_enc,
       bot_user = excluded.bot_user,
       enterprise_id = excluded.enterprise_id,
       active = excluded.active",
    [
      sqlight.text(team.id),
      sqlight.blob(sealed),
      sqlight.text(team.bot_user),
      sqlight.nullable(sqlight.text, team.enterprise_id),
      sqlight.text(team.installed_by),
      sqlight.int(team.installed_at),
      sqlight.bool(team.active),
    ],
  )
}

const team_columns =
  "team_id, bot_token_enc, bot_user, enterprise_id, installed_by, installed_at, active"

type SealedTeam {
  SealedTeam(team: Team, sealed: BitArray)
}

fn team_decoder() -> decode.Decoder(SealedTeam) {
  use id <- decode.field(0, decode.string)
  use sealed <- decode.field(1, decode.bit_array)
  use bot_user <- decode.field(2, decode.string)
  use enterprise_id <- decode.field(3, decode.optional(decode.string))
  use installed_by <- decode.field(4, decode.string)
  use installed_at <- decode.field(5, decode.int)
  use active <- decode.field(6, sqlight.decode_bool())
  decode.success(SealedTeam(
    Team(
      id:,
      bot_token: "",
      bot_user:,
      enterprise_id:,
      installed_by:,
      installed_at:,
      active:,
    ),
    sealed,
  ))
}

fn unseal_team(key: BitArray, row: SealedTeam) -> Result(Team, String) {
  unseal(key, bit_array.from_string(row.team.id), row.sealed)
  |> result.try(bit_array.to_string)
  |> result.map(fn(token) { Team(..row.team, bot_token: token) })
  |> result.replace_error(
    "can't decrypt the bot token of "
    <> row.team.id
    <> "; is CRUSHLING_STORE_KEY the key it was stored with?",
  )
}

pub fn team(store: Store, id: String) -> Result(Option(Team), String) {
  use connection, key <- run(store)
  use rows <- result.try(query(
    connection,
    "SELECT " <> team_columns <> " FROM teams WHERE team_id = ?",
    [sqlight.text(id)],
    team_decoder(),
  ))
  case rows {
    [row, ..] -> unseal_team(key, row) |> result.map(Some)
    [] -> Ok(None)
  }
}

/// Every active team.
pub fn active_teams(store: Store) -> Result(List(Team), String) {
  use connection, key <- run(store)
  use rows <- result.try(query(
    connection,
    "SELECT "
      <> team_columns
      <> " FROM teams WHERE active = 1 ORDER BY installed_at",
    [],
    team_decoder(),
  ))
  list.try_map(rows, unseal_team(key, _))
}

/// Mark a team inactive (or active again), keeping its row.
pub fn set_active(
  store: Store,
  id: String,
  active: Bool,
) -> Result(Nil, String) {
  use connection, _ <- run(store)
  exec(connection, "UPDATE teams SET active = ? WHERE team_id = ?", [
    sqlight.bool(active),
    sqlight.text(id),
  ])
}

// Settings --------------------------------------------------------------------

/// The names settings are kept under.
pub const allowed_users = "allowed_users"

pub const admins = "admins"

pub fn set_setting(
  store: Store,
  team: String,
  name: String,
  value: String,
) -> Result(Nil, String) {
  use connection, _ <- run(store)
  exec(
    connection,
    "INSERT INTO team_settings (team_id, name, value) VALUES (?, ?, ?)
     ON CONFLICT (team_id, name) DO UPDATE SET value = excluded.value",
    [sqlight.text(team), sqlight.text(name), sqlight.text(value)],
  )
}

pub fn settings(
  store: Store,
  team: String,
) -> Result(Dict(String, String), String) {
  use connection, _ <- run(store)
  query(
    connection,
    "SELECT name, value FROM team_settings WHERE team_id = ?",
    [sqlight.text(team)],
    {
      use name <- decode.field(0, decode.string)
      use value <- decode.field(1, decode.string)
      decode.success(#(name, value))
    },
  )
  |> result.map(dict.from_list)
}

pub fn setting(
  store: Store,
  team: String,
  name: String,
) -> Result(Option(String), String) {
  settings(store, team)
  |> result.map(fn(all) { dict.get(all, name) |> option.from_result })
}

// Threads ---------------------------------------------------------------------

pub fn put_thread(store: Store, thread: Thread) -> Result(Nil, String) {
  use connection, _ <- run(store)
  write_thread(connection, thread, "INSERT OR REPLACE")
}

fn write_thread(
  connection: sqlight.Connection,
  thread: Thread,
  verb: String,
) -> Result(Nil, String) {
  let Thread(key:, team:, channel:, thread_ts:, meta:) = thread
  exec(connection, verb <> " INTO threads
       (key, team_id, channel, thread_ts, follow, paused, cursor, venue,
        tailnet, model, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [
    sqlight.text(key),
    sqlight.text(team),
    sqlight.text(channel),
    sqlight.text(thread_ts),
    sqlight.bool(meta.follow),
    sqlight.bool(meta.paused),
    sqlight.text(meta.cursor),
    sqlight.text(json.to_string(venue.to_json(meta.venue))),
    sqlight.nullable(
      sqlight.text,
      option.map(meta.tailnet, fn(grant) {
        json.to_string(meta.grant_to_json(grant))
      }),
    ),
    sqlight.nullable(
      sqlight.text,
      option.map(meta.model, fn(choice) {
        json.to_string(meta.model_choice_to_json(choice))
      }),
    ),
    sqlight.int(now_seconds()),
  ])
}

fn thread_decoder() -> decode.Decoder(Thread) {
  use key <- decode.field(0, decode.string)
  use team <- decode.field(1, decode.string)
  use channel <- decode.field(2, decode.string)
  use thread_ts <- decode.field(3, decode.string)
  use follow <- decode.field(4, sqlight.decode_bool())
  use paused <- decode.field(5, sqlight.decode_bool())
  use cursor <- decode.field(6, decode.string)
  use venue_json <- decode.field(7, decode.string)
  use tailnet_json <- decode.field(8, decode.optional(decode.string))
  use model_json <- decode.field(9, decode.optional(decode.string))
  let venue =
    json.parse(venue_json, venue.decoder()) |> result.unwrap(venue.Thread)
  let tailnet =
    option.then(tailnet_json, fn(text) {
      json.parse(text, meta.grant_decoder()) |> option.from_result
    })
  let model =
    option.then(model_json, fn(text) {
      json.parse(text, meta.model_choice_decoder()) |> option.from_result
    })
  decode.success(Thread(
    key:,
    team:,
    channel:,
    thread_ts:,
    meta: Meta(follow:, paused:, cursor:, venue:, tailnet:, model:),
  ))
}

pub fn thread(store: Store, key: String) -> Result(Option(Thread), String) {
  use connection, _ <- run(store)
  read_thread(connection, key)
}

fn read_thread(
  connection: sqlight.Connection,
  key: String,
) -> Result(Option(Thread), String) {
  query(
    connection,
    "SELECT key, team_id, channel, thread_ts, follow, paused, cursor, venue,
       tailnet, model FROM threads WHERE key = ?",
    [sqlight.text(key)],
    thread_decoder(),
  )
  |> result.map(fn(rows) { list.first(rows) |> option.from_result })
}

/// Move a thread's row from `old` to `new`, setting its team, unless `new`
/// already has one, in one transaction. True when a row moved.
pub fn rename_thread(
  store: Store,
  old old: String,
  new new: String,
  team team: String,
) -> Result(Bool, String) {
  use connection, _ <- run(store)
  use _ <- result.try(exec(connection, "BEGIN IMMEDIATE", []))
  let moved = {
    use found <- result.try(read_thread(connection, old))
    use taken <- result.try(read_thread(connection, new))
    case found, taken {
      Some(_), None -> {
        use _ <- result.map(
          exec(
            connection,
            "UPDATE threads SET key = ?, team_id = ? WHERE key = ?",
            [sqlight.text(new), sqlight.text(team), sqlight.text(old)],
          ),
        )
        True
      }
      _, _ -> Ok(False)
    }
  }
  case moved {
    Ok(moved) -> exec(connection, "COMMIT", []) |> result.replace(moved)
    Error(reason) -> {
      let _ = exec(connection, "ROLLBACK", [])
      Error(reason)
    }
  }
}

// Links -----------------------------------------------------------------------

pub fn put_link(
  store: Store,
  team: String,
  channel: String,
  link: Link,
) -> Result(Nil, String) {
  use connection, _ <- run(store)
  write_link(connection, team, channel, link, "INSERT OR REPLACE")
}

fn write_link(
  connection: sqlight.Connection,
  team: String,
  channel: String,
  link: Link,
  verb: String,
) -> Result(Nil, String) {
  exec(
    connection,
    verb
      <> " INTO links (team_id, channel, origin_channel, origin_ts, opened_ts)
     VALUES (?, ?, ?, ?, ?)",
    [
      sqlight.text(team),
      sqlight.text(channel),
      sqlight.text(link.origin_channel),
      sqlight.text(link.origin_ts),
      sqlight.text(link.opened_ts),
    ],
  )
}

pub fn link(
  store: Store,
  team: String,
  channel: String,
) -> Result(Option(Link), String) {
  use connection, _ <- run(store)
  query(
    connection,
    "SELECT origin_channel, origin_ts, opened_ts FROM links
     WHERE team_id = ? AND channel = ?",
    [sqlight.text(team), sqlight.text(channel)],
    {
      use origin_channel <- decode.field(0, decode.string)
      use origin_ts <- decode.field(1, decode.string)
      use opened_ts <- decode.field(2, decode.string)
      decode.success(Link(origin_channel:, origin_ts:, opened_ts:))
    },
  )
  |> result.map(fn(rows) { list.first(rows) |> option.from_result })
}

// Importing the old files -----------------------------------------------------

/// What `import_files` brought in.
pub type Imported {
  /// `skipped` names each directory not imported, and why.
  Imported(
    threads: List(String),
    links: List(String),
    skipped: List(#(String, String)),
  )
  /// The store had already imported them once.
  AlreadyImported
}

const imported_marker = "imported_files"

/// Import the meta and link files the bridge kept before the store, once:
/// `<root>/<key>/crushling.json` for threads, and
/// `<root>/<channel>-code/crushling.json` for code channels, all for `team`.
/// Rows already in the store win. The files stay where they are; later
/// starts skip this.
pub fn import_files(
  store: Store,
  root: String,
  team: String,
) -> Result(Imported, String) {
  use connection, _ <- run(store)
  use done <- result.try(query(
    connection,
    "SELECT value FROM bridge WHERE name = ?",
    [sqlight.text(imported_marker)],
    decode.field(0, decode.string, decode.success),
  ))
  case done {
    [_, ..] -> Ok(AlreadyImported)
    [] -> {
      let entries =
        list_dir(root) |> result.unwrap([]) |> list.sort(string.compare)
      use found <- result.try(
        list.try_fold(entries, #([], [], []), fn(found, entry) {
          import_entry(connection, root, team, entry, found)
        }),
      )
      use _ <- result.map(
        exec(connection, "INSERT INTO bridge (name, value) VALUES (?, ?)", [
          sqlight.text(imported_marker),
          sqlight.text(int.to_string(now_seconds())),
        ]),
      )
      let #(threads, links, skipped) = found
      Imported(
        threads: list.reverse(threads),
        links: list.reverse(links),
        skipped: list.reverse(skipped),
      )
    }
  }
}

fn import_entry(
  connection: sqlight.Connection,
  root: String,
  team: String,
  entry: String,
  found: #(List(String), List(String), List(#(String, String))),
) -> Result(#(List(String), List(String), List(#(String, String))), String) {
  let #(threads, links, skipped) = found
  let skip = fn(why) { Ok(#(threads, links, [#(entry, why), ..skipped])) }
  let dir = root <> "/" <> entry
  let path = dir <> "/crushling.json"
  case dir_exists(dir), file_exists(path), string.ends_with(entry, "-code") {
    // The store's own files and the key, not directories.
    False, _, _ -> Ok(found)
    True, False, _ -> skip("no crushling.json")
    True, True, True ->
      case meta.read_link(path) {
        Error(Nil) -> skip("crushling.json isn't a code channel link")
        Ok(link) -> {
          let channel = string.drop_end(entry, 5)
          use known <- result.try(link_row(connection, team, channel))
          case known {
            True -> skip("already in the store")
            False -> {
              use _ <- result.map(write_link(
                connection,
                team,
                channel,
                link,
                "INSERT",
              ))
              #(threads, [channel, ..links], skipped)
            }
          }
        }
      }
    True, True, False ->
      case meta.read(path) {
        Error(Nil) -> skip("crushling.json isn't thread meta")
        Ok(saved) -> {
          use known <- result.try(read_thread(connection, entry))
          case known, string.split_once(entry, "-") {
            Some(_), _ -> skip("already in the store")
            None, Error(Nil) -> skip("not a channel-ts key")
            None, Ok(#(channel, thread_ts)) -> {
              use _ <- result.map(write_thread(
                connection,
                Thread(key: entry, team:, channel:, thread_ts:, meta: saved),
                "INSERT",
              ))
              #([entry, ..threads], links, skipped)
            }
          }
        }
      }
  }
}

fn link_row(
  connection: sqlight.Connection,
  team: String,
  channel: String,
) -> Result(Bool, String) {
  query(
    connection,
    "SELECT 1 FROM links WHERE team_id = ? AND channel = ?",
    [sqlight.text(team), sqlight.text(channel)],
    decode.success(Nil),
  )
  |> result.map(fn(rows) { rows != [] })
}

@external(erlang, "crushling_store_ffi", "dir_exists")
fn dir_exists(path: String) -> Bool

@external(erlang, "crushling_ffi", "file_exists")
fn file_exists(path: String) -> Bool
