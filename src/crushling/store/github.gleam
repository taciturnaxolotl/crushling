//// Each person's GitHub connection: their login and the user access token
//// GitHub gave crushling for them, with its refresh token. Both tokens are
//// sealed under the store key, bound to the workspace and person, so a row
//// copied elsewhere opens nowhere.

import crushling/github.{type Tokens, Tokens}
import crushling/store.{type Migration, type Store, Migration}
import crushling/store/sealed
import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import sqlight

pub type Account {
  Account(
    team: String,
    user: String,
    login: String,
    tokens: Tokens,
    /// Unix seconds.
    connected_at: Int,
  )
}

pub fn migrations() -> List(Migration) {
  [
    Migration(
      id: "github.1",
      legacy_version: 3,
      sql: "CREATE TABLE github_accounts (
        team_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        login TEXT NOT NULL,
        tokens_enc BLOB NOT NULL,
        connected_at INTEGER NOT NULL,
        PRIMARY KEY (team_id, user_id)
      );",
    ),
    // A workspace's connections go with it. One no workspace has can't be
    // used, so it isn't kept.
    Migration(
      id: "github.2",
      legacy_version: 0,
      sql: "CREATE TABLE github_accounts_new (
        team_id TEXT NOT NULL REFERENCES teams(team_id) ON DELETE CASCADE,
        user_id TEXT NOT NULL,
        login TEXT NOT NULL,
        tokens_enc BLOB NOT NULL,
        connected_at INTEGER NOT NULL,
        PRIMARY KEY (team_id, user_id)
      );
      INSERT INTO github_accounts_new
        SELECT team_id, user_id, login, tokens_enc, connected_at
        FROM github_accounts WHERE team_id IN (SELECT team_id FROM teams);
      DROP TABLE github_accounts;
      ALTER TABLE github_accounts_new RENAME TO github_accounts;",
    ),
  ]
}

fn seal(key: BitArray, team: String, user: String, tokens: Tokens) -> BitArray {
  sealed.seal(
    key,
    sealed.GitHubTokens,
    [team, user],
    bit_array.from_string(tokens_json(tokens)),
  )
}

fn tokens_json(tokens: Tokens) -> String {
  json.object([
    #("access", json.string(tokens.access)),
    #("expires_at", json.int(tokens.expires_at)),
    #("refresh", json.string(tokens.refresh)),
    #("refresh_expires_at", json.int(tokens.refresh_expires_at)),
  ])
  |> json.to_string
}

fn tokens_decoder() -> decode.Decoder(Tokens) {
  use access <- decode.field("access", decode.string)
  use expires_at <- decode.field("expires_at", decode.int)
  use refresh <- decode.field("refresh", decode.string)
  use refresh_expires_at <- decode.field("refresh_expires_at", decode.int)
  decode.success(Tokens(access:, expires_at:, refresh:, refresh_expires_at:))
}

/// Save a connection, replacing the person's earlier one.
pub fn put(store: Store, account: Account) -> Result(Nil, String) {
  use connection, key <- store.run(store)
  let sealed = seal(key, account.team, account.user, account.tokens)
  store.exec(
    connection,
    "INSERT OR REPLACE INTO github_accounts
       (team_id, user_id, login, tokens_enc, connected_at)
     VALUES (?, ?, ?, ?, ?)",
    [
      sqlight.text(account.team),
      sqlight.text(account.user),
      sqlight.text(account.login),
      sqlight.blob(sealed),
      sqlight.int(account.connected_at),
    ],
  )
}

/// A person's connection, if they have one.
pub fn get(
  store: Store,
  team: String,
  user: String,
) -> Result(Option(Account), String) {
  use connection, key <- store.run(store)
  let decoder = {
    use login <- decode.field(0, decode.string)
    use sealed <- decode.field(1, decode.bit_array)
    use connected_at <- decode.field(2, decode.int)
    decode.success(#(login, sealed, connected_at))
  }
  use rows <- result.try(store.query(
    connection,
    "SELECT login, tokens_enc, connected_at FROM github_accounts
     WHERE team_id = ? AND user_id = ?",
    [sqlight.text(team), sqlight.text(user)],
    decoder,
  ))
  case rows {
    [] -> Ok(None)
    [#(login, sealed, connected_at), ..] -> {
      use tokens <- result.map(
        sealed.unseal(key, sealed.GitHubTokens, [team, user], sealed)
        |> result.try(bit_array.to_string)
        |> result.try(fn(text) {
          json.parse(text, tokens_decoder()) |> result.replace_error(Nil)
        })
        |> result.replace_error(
          "can't read the GitHub connection of "
          <> user
          <> "; is CRUSHLING_STORE_KEY the key it was stored with?",
        ),
      )
      Some(Account(team:, user:, login:, tokens:, connected_at:))
    }
  }
}

/// Forget a person's connection.
pub fn delete(store: Store, team: String, user: String) -> Result(Nil, String) {
  use connection, _ <- store.run(store)
  store.exec(
    connection,
    "DELETE FROM github_accounts WHERE team_id = ? AND user_id = ?",
    [sqlight.text(team), sqlight.text(user)],
  )
}

/// Swap in refreshed tokens, but only on the connection they came from:
/// False when it was disconnected or replaced meanwhile, which must win.
pub fn replace_tokens(
  store: Store,
  team: String,
  user: String,
  connected_at: Int,
  tokens: Tokens,
) -> Result(Bool, String) {
  use connection, key <- store.run(store)
  let sealed = seal(key, team, user, tokens)
  store.query(
    connection,
    "UPDATE github_accounts SET tokens_enc = ?
     WHERE team_id = ? AND user_id = ? AND connected_at = ?
     RETURNING user_id",
    [
      sqlight.blob(sealed),
      sqlight.text(team),
      sqlight.text(user),
      sqlight.int(connected_at),
    ],
    decode.success(Nil),
  )
  |> result.map(fn(rows) { rows != [] })
}

/// Forget a connection, but only the one made at `connected_at`, so a lapse
/// noticed late never forgets a newer connection.
pub fn delete_connection(
  store: Store,
  team: String,
  user: String,
  connected_at: Int,
) -> Result(Nil, String) {
  use connection, _ <- store.run(store)
  store.exec(
    connection,
    "DELETE FROM github_accounts
     WHERE team_id = ? AND user_id = ? AND connected_at = ?",
    [sqlight.text(team), sqlight.text(user), sqlight.int(connected_at)],
  )
}

/// Forget every connection in workspace `team`, within a caller's
/// transaction.
@internal
pub fn delete_team(
  connection: sqlight.Connection,
  team: String,
) -> Result(Nil, String) {
  store.exec(connection, "DELETE FROM github_accounts WHERE team_id = ?", [
    sqlight.text(team),
  ])
}
