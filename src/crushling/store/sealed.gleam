//// Secrets sealed under the store key: AES-256-GCM with a fresh nonce per
//// value, bound to what it is and whose by its associated data, so a value
//// copied onto another row, or read as another kind of secret, opens
//// nowhere.
////
//// A sealed value is a version byte, then nonce (12), tag (16) and
//// ciphertext. Version 1 binds `v1:<purpose>:<ids>`. Values sealed before
//// versions have no version byte and bind the older data (the team id for
//// a bot token, `github:<team>:<user>` for GitHub tokens); they still open,
//// and are written back in the new form the next time they're saved.

import gleam/bit_array
import gleam/string

/// What a sealed value is.
pub type Purpose {
  /// A workspace's bot token; ids: the team.
  BotToken
  /// A person's GitHub tokens; ids: the team and the user.
  GitHubTokens
}

const version = 1

fn name(purpose: Purpose) -> String {
  case purpose {
    BotToken -> "bot_token"
    GitHubTokens -> "github_tokens"
  }
}

fn aad(purpose: Purpose, ids: List(String)) -> BitArray {
  bit_array.from_string("v1:" <> name(purpose) <> ":" <> string.join(ids, ":"))
}

/// What a value sealed before versions was bound to.
fn legacy_aad(purpose: Purpose, ids: List(String)) -> BitArray {
  case purpose {
    BotToken -> bit_array.from_string(string.join(ids, ":"))
    GitHubTokens -> bit_array.from_string("github:" <> string.join(ids, ":"))
  }
}

/// Seal `plain` under `key` as a `purpose` secret of `ids`.
pub fn seal(
  key: BitArray,
  purpose: Purpose,
  ids: List(String),
  plain: BitArray,
) -> BitArray {
  <<version, raw_seal(key, aad(purpose, ids), plain):bits>>
}

/// Open what `seal` sealed, or a value sealed before versions; an error
/// for the wrong key, purpose or ids, or a damaged value.
pub fn unseal(
  key: BitArray,
  purpose: Purpose,
  ids: List(String),
  sealed: BitArray,
) -> Result(BitArray, Nil) {
  // A legacy value starts with a random nonce, which may happen to look
  // like a version byte; the tag tells which it is.
  let current = case sealed {
    <<1, rest:bits>> -> raw_unseal(key, aad(purpose, ids), rest)
    _ -> Error(Nil)
  }
  case current {
    Ok(plain) -> Ok(plain)
    Error(Nil) -> raw_unseal(key, legacy_aad(purpose, ids), sealed)
  }
}

@external(erlang, "crushling_store_ffi", "seal")
fn raw_seal(key: BitArray, aad: BitArray, plain: BitArray) -> BitArray

@external(erlang, "crushling_store_ffi", "open")
fn raw_unseal(
  key: BitArray,
  aad: BitArray,
  sealed: BitArray,
) -> Result(BitArray, Nil)

/// A value sealed the way rows were before versions, for tests of reading
/// them.
@internal
pub fn seal_legacy(
  key: BitArray,
  purpose: Purpose,
  ids: List(String),
  plain: BitArray,
) -> BitArray {
  raw_seal(key, legacy_aad(purpose, ids), plain)
}
