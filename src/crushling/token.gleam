//// Bearer tokens the bridge hands each thread's sandbox, one per purpose.
////
//// Every token is an HMAC of the thread's key under the instance secret,
//// with the purpose as a prefix, so a token minted for one endpoint never
//// opens another. A `bound_at` token also carries the sandbox's epoch (when
//// it started), so a sandbox started again gets a token the old one's
//// copies can't stand in for.

import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
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

/// The thread a `bound` or `bound_at` token is for, if it is one.
pub fn opened(
  secret: String,
  purpose: Purpose,
  token: String,
) -> Result(String, Nil) {
  opened_at(secret, purpose, token) |> result.map(fn(found) { found.0 })
}

/// Like `bound`, for the sandbox started at `epoch` (any number that
/// changes with each start, such as its start time in ms).
pub fn bound_at(
  secret: String,
  purpose: Purpose,
  key: String,
  epoch: Int,
) -> String {
  let named = key <> "@" <> int.to_string(epoch)
  named <> "." <> mint(secret, purpose, named)
}

/// The thread a token is for and the epoch it was minted for: None for a
/// `bound` token, which has none.
pub fn opened_at(
  secret: String,
  purpose: Purpose,
  token: String,
) -> Result(#(String, Option(Int)), Nil) {
  // The mac is hex, so what it signs is everything before the last dot.
  case string.split(token, ".") |> list.reverse {
    [mac, ..rest] if rest != [] -> {
      let named = list.reverse(rest) |> string.join(".")
      use <- bool.guard(
        !equal_constant_time(mac, mint(secret, purpose, named)),
        Error(Nil),
      )
      // Keys never hold an @, so one names the epoch.
      case string.split_once(named, "@") {
        Error(Nil) -> Ok(#(named, None))
        Ok(#(key, epoch)) ->
          int.parse(epoch)
          |> result.map(fn(epoch) { #(key, Some(epoch)) })
      }
    }
    _ -> Error(Nil)
  }
}
