//// Bearer tokens the bridge hands each thread's sandbox, one per purpose.
////
//// Every token is an HMAC of the thread's key under the instance secret,
//// with the purpose as a prefix, so a token minted for one endpoint never
//// opens another.

import gleam/list
import gleam/string

pub type Purpose {
  /// The Slack tools at `/mcp/<key>`.
  Mcp
  /// The dial-out tunnel at `/tunnel/<key>/...`.
  Tunnel
  /// The inference proxy at `/proxy/<key>/...`.
  Proxy
  /// GitHub through the bridge. Its requests carry no key in the path, so
  /// the token carries it: see `bound`.
  GitHub
}

@external(erlang, "crushling_ffi", "hmac_sha256_hex")
fn hmac_sha256_hex(secret: String, data: String) -> String

@external(erlang, "crushling_ffi", "equal_constant_time")
fn equal_constant_time(a: String, b: String) -> Bool

fn prefix(purpose: Purpose) -> String {
  case purpose {
    Mcp -> "mcp:"
    Tunnel -> "tunnel:"
    Proxy -> "proxy:"
    GitHub -> "github:"
  }
}

/// The token a thread presents for `purpose`.
pub fn mint(secret: String, purpose: Purpose, key: String) -> String {
  hmac_sha256_hex(secret, prefix(purpose) <> key)
}

/// Whether an `Authorization` header carries the thread's token for
/// `purpose`.
pub fn authorized(
  secret: String,
  purpose: Purpose,
  key: String,
  header: String,
) -> Bool {
  key != ""
  && equal_constant_time(header, "Bearer " <> mint(secret, purpose, key))
}

/// A token that names its thread: `<key>.<mac>`. For requests whose path
/// can't carry the key, such as gh's to `api.github.com`.
pub fn bound(secret: String, purpose: Purpose, key: String) -> String {
  key <> "." <> mint(secret, purpose, key)
}

/// The thread a `bound` token is for, if it is one.
pub fn opened(
  secret: String,
  purpose: Purpose,
  token: String,
) -> Result(String, Nil) {
  // The mac is hex, so the key is everything before the last dot.
  case string.split(token, ".") |> list.reverse {
    [mac, ..rest] if rest != [] -> {
      let key = list.reverse(rest) |> string.join(".")
      case equal_constant_time(mac, mint(secret, purpose, key)) {
        True -> Ok(key)
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}
