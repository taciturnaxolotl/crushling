//// What the inference proxy spent, kept in the store by thread and UTC day,
//// so the App Home's numbers survive restarts. The proxy's caps still count
//// from the bridge's start (`proxy/meter`); this is the record. The meter is
//// drained into it in batches (`record`).

import crushling/key as thread_key
import crushling/store.{type Migration, type Store, Migration}
import crushling/usage.{type Usage, Usage, zero}
import gleam/dynamic/decode
import gleam/list
import gleam/result
import gleam/string
import sqlight

/// No foreign key to `teams`: spend from before keys carried a workspace
/// is kept under none.
pub fn migrations() -> List(Migration) {
  [
    Migration(
      id: "usage.1",
      legacy_version: 3,
      sql: "CREATE TABLE usage (
        team_id TEXT NOT NULL,
        key TEXT NOT NULL,
        day TEXT NOT NULL,
        input_tokens INTEGER NOT NULL,
        output_tokens INTEGER NOT NULL,
        cost_usd REAL NOT NULL,
        requests INTEGER NOT NULL,
        PRIMARY KEY (key, day)
      );
      CREATE INDEX usage_team_day ON usage (team_id, day);",
    ),
  ]
}

/// Add what threads spent to their totals for today, in one transaction.
/// A key without a workspace (from before keys carried one) counts under
/// no workspace.
pub fn record(
  store: Store,
  spent: List(#(String, Usage)),
) -> Result(Nil, String) {
  use connection, _ <- store.run(store)
  use _ <- result.try(store.exec(connection, "BEGIN", []))
  let written =
    list.try_each(spent, fn(pair) {
      let #(key, usage) = pair
      store.exec(
        connection,
        "INSERT INTO usage
           (team_id, key, day, input_tokens, output_tokens, cost_usd, requests)
         VALUES (?, ?, date('now'), ?, ?, ?, ?)
         ON CONFLICT (key, day) DO UPDATE SET
           input_tokens = input_tokens + excluded.input_tokens,
           output_tokens = output_tokens + excluded.output_tokens,
           cost_usd = cost_usd + excluded.cost_usd,
           requests = requests + excluded.requests",
        [
          sqlight.text(
            thread_key.parse(key)
            |> result.map(thread_key.team)
            |> result.unwrap(""),
          ),
          sqlight.text(key),
          sqlight.int(usage.input_tokens),
          sqlight.int(usage.output_tokens),
          sqlight.float(usage.cost_usd),
          sqlight.int(usage.requests),
        ],
      )
    })
  case written {
    Ok(Nil) -> store.exec(connection, "COMMIT", [])
    Error(reason) -> {
      let _ = store.exec(connection, "ROLLBACK", [])
      Error(reason)
    }
  }
}

/// How far back a total reaches.
pub type Since {
  Today
  /// The last 30 days, today included.
  Month
  Ever
}

fn since_clause(since: Since) -> String {
  case since {
    Today -> " AND day = date('now')"
    Month -> " AND day >= date('now', '-29 days')"
    Ever -> ""
  }
}

fn usage_decoder() -> decode.Decoder(Usage) {
  use input_tokens <- decode.field(0, decode.int)
  use output_tokens <- decode.field(1, decode.int)
  use cost_usd <- decode.field(2, decode.float)
  use requests <- decode.field(3, decode.int)
  decode.success(Usage(input_tokens:, output_tokens:, cost_usd:, requests:))
}

const sums =
  "SELECT coalesce(sum(input_tokens), 0), coalesce(sum(output_tokens), 0),
  coalesce(sum(cost_usd), 0.0), coalesce(sum(requests), 0) FROM usage"

fn total(
  store: Store,
  where: String,
  with: List(sqlight.Value),
) -> Result(Usage, String) {
  use connection, _ <- store.run(store)
  case
    store.query(connection, sums <> " WHERE " <> where, with, usage_decoder())
  {
    Ok([usage, ..]) -> Ok(usage)
    Ok([]) -> Ok(zero)
    Error(reason) -> Error(reason)
  }
}

/// Everything a workspace's threads spent.
pub fn team_total(
  store: Store,
  team: String,
  since: Since,
) -> Result(Usage, String) {
  total(store, "team_id = ?" <> since_clause(since), [sqlight.text(team)])
}

/// What one thread spent.
pub fn thread_total(
  store: Store,
  key: String,
  since: Since,
) -> Result(Usage, String) {
  total(store, "key = ?" <> since_clause(since), [sqlight.text(key)])
}

/// What some threads spent, together.
pub fn threads_total(
  store: Store,
  keys: List(String),
  since: Since,
) -> Result(Usage, String) {
  case keys {
    [] -> Ok(zero)
    keys ->
      total(
        store,
        "key IN ("
          <> string.join(list.map(keys, fn(_) { "?" }), ", ")
          <> ")"
          <> since_clause(since),
        list.map(keys, sqlight.text),
      )
  }
}
