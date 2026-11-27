//// What crush and the bridge say to each other over a tunnel, and where
//// things live: the dial URL and token, the control socket's frames, and
//// the shim's path.
////
//// crush keeps a control socket open at `/tunnel/<key>/control` (JSON
//// text frames). When the shim accepts a connection the bridge sends
//// `{"op":"open","id":N}`, crush dials `/tunnel/<key>/data/N`, and that
//// socket's binary frames carry the connection's bytes. Every dial carries
//// the thread's `token.Tunnel` bearer token.

import crushling/agent/env as agent_env
import crushling/sys
import crushling/token
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string

/// What the hub tells a control socket's process.
pub type Command {
  SendOpen(Int)
  SendBye
  Superseded
  Retire
  /// Time to ping.
  Tick
}

/// The token a thread's crush presents.
pub fn token(secret: String, key: String) -> String {
  token.mint(secret, token.Tunnel, key)
}

/// The environment `crush server --dial` needs.
pub fn env(secret: String, key: String) -> List(String) {
  [agent_env.pair(agent_env.dial_token, token(secret, key))]
}

/// The `--dial` URL for a thread, given the bridge's base URL as the
/// sandbox reaches it (`http(s)://` or `ws(s)://`).
pub fn dial_url(base: String, key: String) -> String {
  let base = case base {
    "https://" <> rest -> "wss://" <> rest
    "http://" <> rest -> "ws://" <> rest
    other -> other
  }
  let base = case string.ends_with(base, "/") {
    True -> string.drop_end(base, 1)
    False -> base
  }
  base <> "/tunnel/" <> key
}

/// Where a thread's shim listens: a short name in one directory, so the
/// path's length doesn't depend on the key's and a unix socket fits it.
pub fn shim_path(root: String, key: String) -> String {
  shim_dir(root) <> "/" <> string.slice(sys.sha256_hex(key), 0, 16) <> ".sock"
}

pub fn shim_dir(root: String) -> String {
  root <> "/s"
}

/// The longest unix socket path, in bytes, that fits a `sockaddr_un` on
/// both macOS (103) and Linux (107).
const max_socket_path = 103

/// Whether shims under `root` fit a unix socket path.
pub fn check_root(root: String) -> Result(Nil, String) {
  let path = shim_path(root, "key")
  let overhead = string.byte_size(path) - string.byte_size(root)
  case string.byte_size(path) > max_socket_path {
    True ->
      Error(
        "shim sockets under "
        <> root
        <> " would be "
        <> int.to_string(string.byte_size(path))
        <> " bytes, over the "
        <> int.to_string(max_socket_path)
        <> " a unix socket path allows; use a root of at most "
        <> int.to_string(max_socket_path - overhead)
        <> " bytes",
      )
    False -> Ok(Nil)
  }
}

/// The frame asking crush to dial a data socket for wire `id`.
pub fn open_frame(id: Int) -> String {
  json.object([#("op", json.string("open")), #("id", json.int(id))])
  |> json.to_string
}

/// The frame telling crush to exit and not redial.
pub fn bye_frame() -> String {
  json.object([#("op", json.string("bye"))]) |> json.to_string
}

/// A hello's major protocol version and crush's version. A `v` given as
/// `"1.2"` or `1.2` counts as major 1.
pub fn hello_decoder() -> decode.Decoder(#(Int, String)) {
  let major =
    decode.one_of(decode.int, [
      decode.float |> decode.map(float_floor),
      decode.string
        |> decode.then(fn(v) {
          case string.split(v, ".") |> list.first |> result.try(int.parse) {
            Ok(major) -> decode.success(major)
            Error(Nil) -> decode.failure(0, "version")
          }
        }),
    ])
  use op <- decode.field("op", decode.string)
  use v <- decode.field("v", major)
  use crush <- decode.optional_field("crush", "", decode.string)
  case op {
    "hello" -> decode.success(#(v, crush))
    _ -> decode.failure(#(0, ""), "hello")
  }
}

@external(erlang, "erlang", "trunc")
fn float_floor(f: Float) -> Int
