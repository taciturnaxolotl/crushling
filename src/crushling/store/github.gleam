//// Each person's GitHub connection: their login and the user access token
//// GitHub gave crushling for them, with its refresh token. Both tokens are
//// sealed under the store key, bound to the workspace and person, so a row
//// copied elsewhere opens nowhere.

import crushling/github.{type Tokens, Tokens}
import crushling/store.{type Store}
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


fn aad(team: String, user: String) -> BitArray {
  bit_array.from_string("github:" <> team <> ":" <> user)
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
  let sealed =
    store.seal(
      key,
      aad(account.team, account.user),
      bit_array.from_string(tokens_json(account.tokens)),
    )
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
        store.unseal(key, aad(team, user), sealed)
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
