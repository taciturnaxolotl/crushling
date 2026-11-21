//// The tunnel against a real `crush server --dial`. Skipped unless
//// `CRUSHLING_REAL=1`. The crush comes from `CRUSHLING_TUNNEL_CRUSH`,
//// else `~/.local/state/crushling-dev/crush`. No model is needed.

import crushling/crush/client
import crushling/gun
import crushling/sandbox_http
import crushling/sys
import crushling/tunnel
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/int

@external(erlang, "real_server_ffi", "enabled")
fn enabled() -> Bool

@external(erlang, "real_server_ffi", "timeout")
fn with_timeout(seconds: Int, body: fn() -> Nil) -> Dynamic

@external(erlang, "real_server_ffi", "guarded")
fn guarded(body: fn() -> a, cleanup: fn() -> Nil) -> a

@external(erlang, "crushling_ffi", "mkdir_p")
fn mkdir_p(path: String) -> Result(Nil, String)

@external(erlang, "tunnel_real_ffi", "crush")
fn crush_path() -> String

type Crush

@external(erlang, "tunnel_real_ffi", "start")
fn start_crush(
  crush: String,
  url: String,
  token: String,
  home: String,
  log: String,
) -> #(Crush, Int)

@external(erlang, "tunnel_real_ffi", "wait_exit")
fn wait_exit(crush: Crush, timeout_ms: Int) -> Result(Int, Nil)

@external(erlang, "tunnel_real_ffi", "kill")
fn kill(os_pid: Int) -> Nil

@external(erlang, "erlang", "unique_integer")
fn unique() -> Int

@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(a: a) -> Dynamic

/// EUnit generator: the test with a long timeout, or nothing.
pub fn real_tunnel_test_() -> Dynamic {
  case enabled() {
    False -> to_dynamic([])
    True -> to_dynamic([with_timeout(120, dial_health_events_bye)])
  }
}

fn dial_health_events_bye() -> Nil {
  let n = int.absolute_value(unique())
  // Short: unix socket paths are limited to about 100 bytes.
  let root = "/tmp/crushling-tr-" <> int.to_string(n % 1_000_000)
  let home = root <> "/home"
  let work = root <> "/work"
  let assert Ok(Nil) = mkdir_p(home)
  let assert Ok(Nil) = mkdir_p(work)
  let secret = "real-tunnel-secret"
  let key = "C1-" <> int.to_string(n % 1_000_000)
  let assert Ok(tunnels) = tunnel.start(tunnel.config(secret, root))
  let port = 24_000 + n % 4000
  let assert Ok(Nil) =
    sandbox_http.start("127.0.0.1", port, [tunnel.route(tunnels)])
  let assert Ok(shim) = tunnel.open(tunnels, key)

  let url = tunnel.dial_url("http://127.0.0.1:" <> int.to_string(port), key)
  let #(crush, os_pid) =
    start_crush(
      crush_path(),
      url,
      tunnel.token(secret, key),
      home,
      root <> "/server.log",
    )
  use <-
    guarded(_, fn() {
      kill(os_pid)
      tunnel.close(tunnels, key)
    })

  let assert Ok(_version) = tunnel.await_hello(tunnels, key, 30_000)
  let assert True = tunnel.dialed(tunnels, key)

  // Plain requests through the shim, as the thread's client makes them.
  let client_id = sys.uuid()
  let assert Ok(requests) = gun.connect_unix(shim, 5000)
  let assert Ok(Nil) = client.perform(requests, client.health())
  let assert Ok(workspace) =
    client.perform(
      requests,
      client.create_workspace(work, client_id, client.Yolo, []),
    )

  // The event stream on its own connection, as in thread/conn.
  let assert Ok(events) = gun.connect_unix(shim, 5000)
  let stream = gun.stream(events, client.events_path(workspace, client_id), [])
  let selector = gun.select(process.new_selector(), fn(m) { m })
  let assert gun.StreamResponse(status: 200, stream: got, ..) =
    next_for(selector, events)
  let assert True = got == stream
  // The request connection still works while the stream is open.
  let assert Ok(Nil) = client.perform(requests, client.health())
  gun.close(events)
  gun.close(requests)

  tunnel.bye(tunnels, key)
  let assert Ok(0) = wait_exit(crush, 30_000)
  Nil
}

/// The next gun message about `conn`. Earlier tests in the same process can
/// leave messages about their own connections behind.
fn next_for(
  selector: process.Selector(gun.Message),
  conn: gun.Conn,
) -> gun.Message {
  let assert Ok(message) = process.selector_receive(selector, 10_000)
  case message {
    gun.Ignored -> next_for(selector, conn)
    gun.ConnDown(conn: other, ..)
      | gun.StreamResponse(conn: other, ..)
      if other != conn
    -> next_for(selector, conn)
    _ -> message
  }
}
