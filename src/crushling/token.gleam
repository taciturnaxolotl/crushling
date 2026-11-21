//// Bearer tokens the bridge hands each thread's sandbox, one per purpose.
////
//// Every token is an HMAC of the thread's key under the instance secret,
//// with the purpose as a prefix, so a token minted for one endpoint never
//// opens another.

pub type Purpose {
  /// The Slack tools at `/mcp/<key>`.
  Mcp
  /// The dial-out tunnel at `/tunnel/<key>/...`.
  Tunnel
  /// The inference proxy at `/proxy/<key>/...`.
  Proxy
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
