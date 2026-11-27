//// Each thread's saved state (`meta`), and the links from code channels to
//// the threads that moved there.

import crushling/meta.{type Link, type Meta, Link, Meta}
import crushling/store.{type Migration, type Store, Migration}
import crushling/sys
import crushling/venue
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sqlight

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

pub fn migrations() -> List(Migration) {
  [
    Migration(
      id: "threads.1",
      legacy_version: 1,
      sql: "CREATE TABLE threads (
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
      );",
    ),
    // The model picked with `!model`, as JSON, or NULL for the default.
    Migration(
      id: "threads.2",
      legacy_version: 2,
      sql: "ALTER TABLE threads ADD COLUMN model TEXT;",
    ),
  ]
}

// Threads ---------------------------------------------------------------------

pub fn put_thread(store: Store, thread: Thread) -> Result(Nil, String) {
  use connection, _ <- store.run(store)
  write_thread(connection, thread, "INSERT OR REPLACE")
}

@internal
pub fn write_thread(
  connection: sqlight.Connection,
  thread: Thread,
  verb: String,
) -> Result(Nil, String) {
  let Thread(key:, team:, channel:, thread_ts:, meta:) = thread
  store.exec(connection, verb <> " INTO threads
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
    sqlight.int(sys.now()),
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
  let tailnet =
    option.then(tailnet_json, fn(text) {
      json.parse(text, meta.grant_decoder()) |> option.from_result
    })
  let model =
    option.then(model_json, fn(text) {
      json.parse(text, meta.model_choice_decoder()) |> option.from_result
    })
  case json.parse(venue_json, venue.decoder()) {
    Error(_) ->
      decode.failure(empty_thread(), "a known venue, not " <> venue_json)
    Ok(venue) ->
      decode.success(Thread(
        key:,
        team:,
        channel:,
        thread_ts:,
        meta: Meta(follow:, paused:, cursor:, venue:, tailnet:, model:),
      ))
  }
}

fn empty_thread() -> Thread {
  Thread(key: "", team: "", channel: "", thread_ts: "", meta: meta.new(False))
}

pub fn thread(store: Store, key: String) -> Result(Option(Thread), String) {
  use connection, _ <- store.run(store)
  read_thread(connection, key)
}

@internal
pub fn read_thread(
  connection: sqlight.Connection,
  key: String,
) -> Result(Option(Thread), String) {
  store.query(
    connection,
    "SELECT key, team_id, channel, thread_ts, follow, paused, cursor, venue,
       tailnet, model FROM threads WHERE key = ?",
    [sqlight.text(key)],
    thread_decoder(),
  )
  |> result.map(fn(rows) { list.first(rows) |> option.from_result })
}

/// A workspace's threads, with those that have no workspace recorded.
pub fn team_threads(
  store: Store,
  team: String,
) -> Result(List(Thread), String) {
  use connection, _ <- store.run(store)
  store.query(
    connection,
    "SELECT key, team_id, channel, thread_ts, follow, paused, cursor, venue,
       tailnet, model FROM threads WHERE team_id = ? OR team_id = ''",
    [sqlight.text(team)],
    thread_decoder(),
  )
}

/// A workspace's threads whose meta last changed before `before` (Unix
/// seconds), with when. Meta changes with every message the agent reads,
/// so this is when each thread last saw work.
pub fn quiet_threads(
  store: Store,
  team: String,
  before: Int,
) -> Result(List(#(Thread, Int)), String) {
  use connection, _ <- store.run(store)
  let decoder = {
    use thread <- decode.then(thread_decoder())
    use updated_at <- decode.field(10, decode.int)
    decode.success(#(thread, updated_at))
  }
  store.query(
    connection,
    "SELECT key, team_id, channel, thread_ts, follow, paused, cursor, venue,
       tailnet, model, updated_at FROM threads
     WHERE team_id = ? AND updated_at < ?",
    [sqlight.text(team), sqlight.int(before)],
    decoder,
  )
}

/// Move a thread's row from `old` to `new`, setting its team, unless `new`
/// already has one, in one transaction. True when a row moved.
pub fn rename_thread(
  store: Store,
  old old: String,
  new new: String,
  team team: String,
) -> Result(Bool, String) {
  use connection, _ <- store.run(store)
  use <- store.transaction(connection)
  use found <- result.try(read_thread(connection, old))
  use taken <- result.try(read_thread(connection, new))
  case found, taken {
    Some(_), None -> {
      use _ <- result.map(
        store.exec(
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

// Links -----------------------------------------------------------------------

pub fn put_link(
  store: Store,
  team: String,
  channel: String,
  link: Link,
) -> Result(Nil, String) {
  use connection, _ <- store.run(store)
  write_link(connection, team, channel, link, "INSERT OR REPLACE")
}

@internal
pub fn write_link(
  connection: sqlight.Connection,
  team: String,
  channel: String,
  link: Link,
  verb: String,
) -> Result(Nil, String) {
  store.exec(
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
  use connection, _ <- store.run(store)
  store.query(
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

@internal
pub fn link_row(
  connection: sqlight.Connection,
  team: String,
  channel: String,
) -> Result(Bool, String) {
  store.query(
    connection,
    "SELECT 1 FROM links WHERE team_id = ? AND channel = ?",
    [sqlight.text(team), sqlight.text(channel)],
    decode.success(Nil),
  )
  |> result.map(fn(rows) { rows != [] })
}
