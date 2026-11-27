//// The bridge's state, in one SQLite file, `<root>/crushling.db`.
////
//// One actor owns the connection, so writes are serialized; every call runs
//// on it. Each domain module keeps its own tables and their migrations
//// (`store/teams`, `store/threads`, `store/usage`, `store/github`,
//// `store/legacy_import`); `store/schema` puts them in order and opens the
//// store with them. Which have run is kept in a `migrations` table.
////
//// Secrets are sealed under the store key (from `CRUSHLING_STORE_KEY`, else
//// `<root>/store-key`): see `store/sealed`.

import crushling/sys
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/set
import gleam/string
import sqlight

pub opaque type Store {
  Store(subject: Subject(Message))
}

type Message {
  Run(job: fn(sqlight.Connection, BitArray) -> Nil)
  Close(reply: Subject(Nil))
}

/// One step of a module's schema. `id` names it for good: once run, a
/// migration is never run again, so it is never edited, only followed.
pub type Migration {
  Migration(
    id: String,
    sql: String,
    /// Before the `migrations` table, how many steps had run was kept in
    /// `PRAGMA user_version`; this step had run when it was at least this.
    /// 0 for steps newer than that.
    legacy_version: Int,
  )
}

const timeout_ms = 10_000

// Opening ---------------------------------------------------------------------

/// Open (or create) the store at `path`, run whichever of `migrations`
/// haven't run, in order, and start its actor. `key` is the 32-byte store
/// key. `store/schema.open` passes every module's.
pub fn start(
  path: String,
  key: BitArray,
  migrations: List(Migration),
) -> Result(Store, String) {
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
    use _ <- result.try(migrate(connection, migrations))
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

/// Run the migrations not yet run, each in a transaction with its record.
/// A store from before the `migrations` table counts the steps its
/// `user_version` covers as run.
fn migrate(
  connection: sqlight.Connection,
  migrations: List(Migration),
) -> Result(Nil, String) {
  use _ <- result.try(
    sqlight.exec(
      "CREATE TABLE IF NOT EXISTS migrations (
        id TEXT PRIMARY KEY,
        applied_at INTEGER NOT NULL
      )",
      connection,
    )
    |> result.map_error(describe),
  )
  use version <- result.try(user_version(connection))
  use ran <- result.try(ran(connection))
  let ran = set.from_list(ran)
  list.try_each(migrations, fn(migration) {
    let Migration(id:, sql:, legacy_version:) = migration
    case
      set.contains(ran, id),
      legacy_version > 0 && version >= legacy_version
    {
      True, _ -> Ok(Nil)
      False, True -> record(connection, id) |> result.map_error(describe)
      False, False ->
        sqlight.exec("BEGIN;\n" <> sql <> "\n", connection)
        |> result.try(fn(_) { record(connection, id) })
        |> result.try(fn(_) { sqlight.exec("COMMIT;", connection) })
        |> result.map_error(fn(error) {
          let _ = sqlight.exec("ROLLBACK;", connection)
          "migration " <> id <> ": " <> describe(error)
        })
    }
  })
}

fn record(
  connection: sqlight.Connection,
  id: String,
) -> Result(Nil, sqlight.Error) {
  sqlight.query(
    "INSERT INTO migrations (id, applied_at) VALUES (?, ?)",
    connection,
    [sqlight.text(id), sqlight.int(sys.now())],
    decode.success(Nil),
  )
  |> result.replace(Nil)
}

fn ran(connection: sqlight.Connection) -> Result(List(String), String) {
  sqlight.query(
    "SELECT id FROM migrations ORDER BY rowid",
    connection,
    [],
    decode.field(0, decode.string, decode.success),
  )
  |> result.map_error(describe)
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

/// The migrations an open store has run, in the order they ran.
pub fn applied(store: Store) -> Result(List(String), String) {
  run(store, fn(connection, _) { ran(connection) })
}

fn describe(error: sqlight.Error) -> String {
  "sqlite: " <> error.message
}

/// Run `job` on the store's actor and wait for its answer.
@internal
pub fn run(
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

/// Run `job` in a transaction, committed when it succeeds.
@internal
pub fn transaction(
  connection: sqlight.Connection,
  job: fn() -> Result(a, String),
) -> Result(a, String) {
  use _ <- result.try(exec(connection, "BEGIN IMMEDIATE", []))
  case job() {
    Ok(done) -> exec(connection, "COMMIT", []) |> result.replace(done)
    Error(reason) -> {
      case exec(connection, "ROLLBACK", []) {
        Ok(Nil) -> Nil
        Error(why) -> sys.warn("crushling: store rollback: " <> why)
      }
      Error(reason)
    }
  }
}

@internal
pub fn query(
  connection: sqlight.Connection,
  sql: String,
  with: List(sqlight.Value),
  expecting: decode.Decoder(a),
) -> Result(List(a), String) {
  sqlight.query(sql, connection, with, expecting)
  |> result.map_error(describe)
}

@internal
pub fn exec(
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
      case sys.read_file(path) {
        Ok(text) ->
          parse_key(text)
          |> result.map(fn(key) { #(key, False) })
          |> result.map_error(fn(reason) { path <> " " <> reason })
        Error(Nil) -> {
          let key = random_key()
          use _ <- result.try(sys.mkdir_p(root))
          use _ <- result.map(sys.write_private(
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

@external(erlang, "crushling_store_ffi", "random_key")
fn random_key() -> BitArray
