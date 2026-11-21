//// The tunnel against a fake crush written with stratus: control and data
//// sockets, the shim, and the ways a dial is turned away.

import crushling/gun
import crushling/sandbox_http
import crushling/tunnel
import crushling/tunnel/shim
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import stratus

const secret = "tunnel-test-secret"

@external(erlang, "erlang", "unique_integer")
fn unique() -> Int

@external(erlang, "tunnel_test_ffi", "unix_closed_within")
fn unix_closed_within(path: String, ms: Int) -> Bool

type RawSocket

@external(erlang, "tunnel_test_ffi", "silent_ws")
fn silent_ws(port: Int, path: String, token: String) -> RawSocket

@external(erlang, "tunnel_test_ffi", "closed_within")
fn closed_within(socket: RawSocket, ms: Int) -> Bool

@external(erlang, "crushling_ffi", "is_socket")
fn is_socket(path: String) -> Bool

@external(erlang, "crushling_ffi", "mkdir_p")
fn mkdir_p(path: String) -> Result(Nil, String)

@external(erlang, "tunnel_test_ffi", "upgrade")
fn upgrade(port: Int, path: String, token: String) -> #(Int, RawSocket)

@external(erlang, "tunnel_test_ffi", "receives")
fn receives(socket: RawSocket, needle: BitArray, ms: Int) -> Bool

type Bridge {
  Bridge(tunnels: tunnel.Tunnels, port: Int, key: String, root: String)
}

/// A bridge with fast timers serving a fresh tunnel on a free-ish port.
fn bridge() -> Bridge {
  bridge_with(2000)
}

fn bridge_with(data_timeout_ms: Int) -> Bridge {
  let n = int.absolute_value(unique())
  let root = "/tmp/crushling-tunnel-test-" <> int.to_string(n)
  let config =
    tunnel.Config(..tunnel.config(secret, root), ping_ms: 50, data_timeout_ms:)
  let assert Ok(tunnels) = tunnel.start(config)
  let port = 20_000 + n % 4000
  let assert Ok(Nil) =
    sandbox_http.start("127.0.0.1", port, [tunnel.route(tunnels)])
  Bridge(tunnels:, port:, key: "C1-" <> int.to_string(n), root:)
}

fn url(b: Bridge, path: String) -> String {
  "http://127.0.0.1:" <> int.to_string(b.port) <> "/tunnel/" <> b.key <> path
}

fn get(b: Bridge, path: String, token: String) -> Int {
  let assert Ok(req) = request.to(url(b, path))
  let assert Ok(resp) =
    req
    |> request.set_header("authorization", "Bearer " <> token)
    |> httpc.send
  resp.status
}

// The fake crush -------------------------------------------------------------

/// What the fake crush's control socket saw.
type Seen {
  Frame(String)
  ClosedWith(Int)
}

type Command {
  SayHello(v: Int)
}

/// Dial the control socket. With `serve`, every open is answered by
/// dialing its data socket and serving one tiny HTTP response on it.
fn fake_crush(
  b: Bridge,
  seen: Subject(Seen),
  serve: Bool,
) -> Subject(stratus.InternalMessage(Command)) {
  let assert Ok(req) = request.to(url(b, "/control"))
  let req =
    request.set_header(
      req,
      "authorization",
      "Bearer " <> tunnel.token(secret, b.key),
    )
  let assert Ok(started) =
    stratus.new(req, Nil)
    |> stratus.on_message(fn(state, message, conn) {
      case message {
        stratus.User(SayHello(v)) -> {
          let hello =
            json.object([
              #("op", json.string("hello")),
              #("v", json.int(v)),
              #("crush", json.string("fake")),
            ])
          let assert Ok(Nil) =
            stratus.send_text_message(conn, json.to_string(hello))
          stratus.continue(state)
        }
        stratus.Text(text) -> {
          process.send(seen, Frame(text))
          case serve, json.parse(text, open_decoder()) {
            True, Ok(id) -> fake_data(b, id)
            _, _ -> Nil
          }
          stratus.continue(state)
        }
        stratus.Binary(_) -> stratus.continue(state)
      }
    })
    |> stratus.on_close(fn(_, reason) {
      process.send(seen, ClosedWith(close_code(reason)))
    })
    |> stratus.start
  started.data
}

fn hello(fake: Subject(stratus.InternalMessage(Command)), v: Int) -> Nil {
  process.send(fake, stratus.to_user_message(SayHello(v)))
}

fn open_decoder() -> decode.Decoder(Int) {
  use op <- decode.field("op", decode.string)
  use id <- decode.field("id", decode.int)
  case op {
    "open" -> decode.success(id)
    _ -> decode.failure(0, "open")
  }
}

fn close_code(reason: stratus.CloseReason) -> Int {
  case reason {
    stratus.Custom(custom) -> stratus.get_custom_code(custom)
    stratus.Normal(_) -> 1000
    stratus.GoingAway(_) -> 1001
    _ -> 0
  }
}

/// A data socket whose "server" answers any request with `ok <path>`.
fn fake_data(b: Bridge, id: Int) -> Nil {
  let assert Ok(req) = request.to(url(b, "/data/" <> int.to_string(id)))
  let req =
    request.set_header(
      req,
      "authorization",
      "Bearer " <> tunnel.token(secret, b.key),
    )
  let assert Ok(_) =
    stratus.new(req, <<>>)
    |> stratus.on_message(fn(buffer, message, conn) {
      case message {
        stratus.Binary(bytes) -> {
          let buffer = bit_array.append(buffer, bytes)
          let assert Ok(text) = bit_array.to_string(buffer)
          case string.split_once(text, "\r\n\r\n") {
            Ok(#(head, _)) -> {
              let assert [line, ..] = string.split(head, "\r\n")
              let assert [_, path, ..] = string.split(line, " ")
              let body = "ok " <> path
              let reply =
                "HTTP/1.1 200 OK\r\ncontent-length: "
                <> int.to_string(string.length(body))
                <> "\r\n\r\n"
                <> body
              let assert Ok(Nil) =
                stratus.send_binary_message(conn, bit_array.from_string(reply))
              stratus.continue(<<>>)
            }
            Error(Nil) -> stratus.continue(buffer)
          }
        }
        _ -> stratus.continue(buffer)
      }
    })
    |> stratus.start
  Nil
}

/// Wait until `n` shim connections are waiting for a data socket.
fn wait_pending(b: Bridge, n: Int) -> List(Int) {
  wait_pending_loop(b, n, 200)
}

fn wait_pending_loop(b: Bridge, n: Int, tries: Int) -> List(Int) {
  let ids = tunnel.pending(b.tunnels, b.key)
  case list.length(ids) == n, tries {
    True, _ -> ids
    False, 0 -> panic as "shim connections never registered"
    False, _ -> {
      process.sleep(10)
      wait_pending_loop(b, n, tries - 1)
    }
  }
}

/// Make a request through the shim from another process; the reply
/// arrives on the returned subject.
fn ask(
  path: String,
  request_path: String,
) -> Subject(Result(gun.Response, String)) {
  let asker = process.new_subject()
  process.spawn(fn() {
    let assert Ok(conn) = gun.connect_unix(path, 2000)
    process.send(
      asker,
      gun.request(conn, http.Get, request_path, [], <<>>, 5000),
    )
    gun.close(conn)
  })
  asker
}

fn open_id(frame: Seen) -> Int {
  let assert Frame(text) = frame
  let assert Ok(id) = json.parse(text, open_decoder())
  id
}

/// The next control frame the fake saw, skipping nothing.
fn next(seen: Subject(Seen)) -> Seen {
  let assert Ok(s) = process.receive(seen, 2000)
  s
}

// Tests ----------------------------------------------------------------------

pub fn dial_url_and_env_test() {
  let assert "ws://bridge:7469/tunnel/k" =
    tunnel.dial_url("http://bridge:7469/", "k")
  let assert "wss://b.example/tunnel/k" =
    tunnel.dial_url("https://b.example", "k")
  let assert ["CRUSH_SERVER_DIAL_TOKEN=" <> token] = tunnel.env("s", "k")
  let assert True = token == tunnel.token("s", "k")
}

pub fn bad_token_is_refused_before_upgrade_test() {
  let b = bridge()
  let assert Ok(_) = tunnel.open(b.tunnels, b.key)
  let assert 401 = get(b, "/control", "nope")
  let assert 401 = get(b, "/data/1", "nope")
  // A token for another thread opens nothing here.
  let assert 401 = get(b, "/control", tunnel.token(secret, "other"))
  tunnel.close(b.tunnels, b.key)
}

pub fn unknown_data_id_is_404_test() {
  let b = bridge()
  let assert Ok(_) = tunnel.open(b.tunnels, b.key)
  let token = tunnel.token(secret, b.key)
  let assert 404 = get(b, "/data/999", token)
  let assert 404 = get(b, "/data/notanumber", token)
  tunnel.close(b.tunnels, b.key)
  // A key with no endpoint has no control socket either.
  let assert 404 = get(b, "/control", token)
}

pub fn hello_marks_the_key_dialed_test() {
  let b = bridge()
  let assert Ok(path) = tunnel.open(b.tunnels, b.key)
  let assert True = path == b.root <> "/" <> b.key <> "/shim.sock"
  let assert Error(_) = tunnel.await_hello(b.tunnels, b.key, 50)
  let assert False = tunnel.dialed(b.tunnels, b.key)
  let seen = process.new_subject()
  let fake = fake_crush(b, seen, False)
  hello(fake, 1)
  let assert Ok("fake") = tunnel.await_hello(b.tunnels, b.key, 2000)
  let assert True = tunnel.dialed(b.tunnels, b.key)
  // Keepalive pings are answered, so the socket stays up.
  process.sleep(300)
  let assert True = tunnel.dialed(b.tunnels, b.key)
  tunnel.close(b.tunnels, b.key)
  let assert ClosedWith(1000) = next(seen)
  let assert False = tunnel.dialed(b.tunnels, b.key)
}

pub fn wrong_protocol_version_is_closed_with_4001_test() {
  let b = bridge()
  let assert Ok(_) = tunnel.open(b.tunnels, b.key)
  let seen = process.new_subject()
  let fake = fake_crush(b, seen, False)
  hello(fake, 2)
  let assert ClosedWith(4001) = next(seen)
  let assert False = tunnel.dialed(b.tunnels, b.key)
  tunnel.close(b.tunnels, b.key)
}

pub fn get_round_trips_through_the_shim_test() {
  let b = bridge()
  let assert Ok(path) = tunnel.open(b.tunnels, b.key)
  let seen = process.new_subject()
  hello(fake_crush(b, seen, True), 1)
  let assert Ok(_) = tunnel.await_hello(b.tunnels, b.key, 2000)
  let assert Ok(conn) = gun.connect_unix(path, 2000)
  let assert Ok(resp) =
    gun.request(conn, http.Get, "/v1/health", [], <<>>, 5000)
  let assert 200 = resp.status
  let assert <<"ok /v1/health">> = resp.body
  // Keep-alive: a second request reuses the same data socket.
  let assert Ok(resp) = gun.request(conn, http.Get, "/again", [], <<>>, 5000)
  let assert <<"ok /again">> = resp.body
  let assert Frame(open) = next(seen)
  let assert Ok(_) = json.parse(open, open_decoder())
  let assert Error(Nil) = process.receive(seen, 100)
  gun.close(conn)
  tunnel.close(b.tunnels, b.key)
}

pub fn connections_wait_for_hello_test() {
  let b = bridge()
  let assert Ok(path) = tunnel.open(b.tunnels, b.key)
  // The shim accepts before crush has dialed; the open goes out on hello.
  let seen = process.new_subject()
  let fake = fake_crush(b, seen, True)
  let assert Ok(conn) = gun.connect_unix(path, 2000)
  let asker = process.new_subject()
  process.spawn(fn() {
    process.send(asker, gun.request(conn, http.Get, "/early", [], <<>>, 5000))
  })
  let assert [_] = wait_pending(b, 1)
  hello(fake, 1)
  let assert Ok(Ok(resp)) = process.receive(asker, 3000)
  let assert <<"ok /early">> = resp.body
  let assert [] = tunnel.pending(b.tunnels, b.key)
  gun.close(conn)
  tunnel.close(b.tunnels, b.key)
}

pub fn second_control_socket_supersedes_the_first_test() {
  let b = bridge()
  let assert Ok(_) = tunnel.open(b.tunnels, b.key)
  let first = process.new_subject()
  hello(fake_crush(b, first, False), 1)
  let assert Ok(_) = tunnel.await_hello(b.tunnels, b.key, 2000)
  let second = process.new_subject()
  let fake = fake_crush(b, second, False)
  let assert ClosedWith(4000) = next(first)
  hello(fake, 1)
  let assert Ok(_) = tunnel.await_hello(b.tunnels, b.key, 2000)
  let assert True = tunnel.dialed(b.tunnels, b.key)
  // Byes and opens go to the newer one.
  tunnel.bye(b.tunnels, b.key)
  let assert Frame("{\"op\":\"bye\"}") = next(second)
  let assert Error(Nil) = process.receive(first, 100)
  tunnel.close(b.tunnels, b.key)
}

pub fn bye_reaches_crush_test() {
  let b = bridge()
  let assert Ok(_) = tunnel.open(b.tunnels, b.key)
  let seen = process.new_subject()
  hello(fake_crush(b, seen, False), 1)
  let assert Ok(_) = tunnel.await_hello(b.tunnels, b.key, 2000)
  tunnel.bye(b.tunnels, b.key)
  let assert Frame(bye) = next(seen)
  let assert Ok("bye") = json.parse(bye, decode.at(["op"], decode.string))
  tunnel.close(b.tunnels, b.key)
}

pub fn shim_connection_without_data_socket_is_closed_test() {
  let b = bridge_with(300)
  let assert Ok(path) = tunnel.open(b.tunnels, b.key)
  let seen = process.new_subject()
  // This crush hears the open but never dials the data socket.
  hello(fake_crush(b, seen, False), 1)
  let assert Ok(_) = tunnel.await_hello(b.tunnels, b.key, 2000)
  let assert True = unix_closed_within(path, 2000)
  let assert Frame(open) = next(seen)
  let assert Ok(id) = json.parse(open, open_decoder())
  // The id was given up, so a late dial is turned away.
  let assert 404 =
    get(b, "/data/" <> int.to_string(id), tunnel.token(secret, b.key))
  tunnel.close(b.tunnels, b.key)
}

pub fn silent_socket_is_closed_after_missed_pongs_test() {
  let b = bridge()
  let assert Ok(_) = tunnel.open(b.tunnels, b.key)
  let socket =
    silent_ws(
      b.port,
      "/tunnel/" <> b.key <> "/control",
      tunnel.token(secret, b.key),
    )
  // Pings every 50ms, closed after two go unanswered.
  let assert True = closed_within(socket, 1000)
  tunnel.close(b.tunnels, b.key)
}

pub fn close_removes_the_shim_test() {
  let b = bridge()
  let assert Ok(path) = tunnel.open(b.tunnels, b.key)
  let assert Ok(same) = tunnel.open(b.tunnels, b.key)
  let assert True = path == same
  tunnel.close(b.tunnels, b.key)
  process.sleep(50)
  let assert Error(_) = gun.connect_unix(path, 500)
  let assert Error(_) = tunnel.await_hello(b.tunnels, b.key, 100)
}

pub fn redial_reissues_pending_opens_under_fresh_ids_test() {
  let b = bridge()
  let assert Ok(path) = tunnel.open(b.tunnels, b.key)
  // The first crush hears the open but goes away before dialing it.
  let first = process.new_subject()
  hello(fake_crush(b, first, False), 1)
  let assert Ok(_) = tunnel.await_hello(b.tunnels, b.key, 2000)
  let asker = ask(path, "/waiting")
  let old = open_id(next(first))
  // A second crush replaces it; the open is reissued under a new id.
  let second = process.new_subject()
  let fake = fake_crush(b, second, False)
  let assert ClosedWith(4000) = next(first)
  let assert [] =
    list.filter(tunnel.pending(b.tunnels, b.key), fn(id) { id == old })
  hello(fake, 1)
  let new = open_id(next(second))
  let assert True = new != old
  let token = tunnel.token(secret, b.key)
  // A late dial for the old id is turned away.
  let assert 404 = get(b, "/data/" <> int.to_string(old), token)
  // The new id serves the waiting connection, once.
  fake_data(b, new)
  let assert Ok(Ok(resp)) = process.receive(asker, 3000)
  let assert <<"ok /waiting">> = resp.body
  let assert #(404, _) =
    upgrade(
      b.port,
      "/tunnel/" <> b.key <> "/data/" <> int.to_string(new),
      token,
    )
  let assert [] = tunnel.pending(b.tunnels, b.key)
  tunnel.close(b.tunnels, b.key)
}

pub fn failed_upgrade_leaves_the_id_usable_test() {
  let b = bridge()
  let assert Ok(path) = tunnel.open(b.tunnels, b.key)
  let seen = process.new_subject()
  hello(fake_crush(b, seen, False), 1)
  let assert Ok(_) = tunnel.await_hello(b.tunnels, b.key, 2000)
  let asker = ask(path, "/after-bad")
  let id = open_id(next(seen))
  // An authorized GET that isn't a websocket upgrade is refused...
  let assert 400 =
    get(b, "/data/" <> int.to_string(id), tunnel.token(secret, b.key))
  let assert [_] = tunnel.pending(b.tunnels, b.key)
  // ...and the id still works.
  fake_data(b, id)
  let assert Ok(Ok(resp)) = process.receive(asker, 3000)
  let assert <<"ok /after-bad">> = resp.body
  tunnel.close(b.tunnels, b.key)
}

pub fn concurrent_claims_attach_once_test() {
  let b = bridge()
  let assert Ok(path) = tunnel.open(b.tunnels, b.key)
  let seen = process.new_subject()
  hello(fake_crush(b, seen, False), 1)
  let assert Ok(_) = tunnel.await_hello(b.tunnels, b.key, 2000)
  let _asker = ask(path, "/once")
  let id = open_id(next(seen))
  let dial_path = "/tunnel/" <> b.key <> "/data/" <> int.to_string(id)
  let token = tunnel.token(secret, b.key)
  let results = process.new_subject()
  list.each([1, 2], fn(_) {
    process.spawn(fn() {
      let #(status, socket) = upgrade(b.port, dial_path, token)
      // The winner carries the request; hold its socket until checked.
      let carried = status == 101 && receives(socket, <<"GET /once">>, 2000)
      process.send(results, #(status, carried))
      process.sleep(500)
    })
  })
  let assert Ok(one) = process.receive(results, 3000)
  let assert Ok(two) = process.receive(results, 3000)
  let assert True =
    list.sort([one, two], fn(a, b) { int.compare(a.0, b.0) })
    == [#(101, True), #(404, False)]
  tunnel.close(b.tunnels, b.key)
}

pub fn superseded_crush_keeps_serving_live_streams_test() {
  let b = bridge()
  let assert Ok(path) = tunnel.open(b.tunnels, b.key)
  let first = process.new_subject()
  hello(fake_crush(b, first, True), 1)
  let assert Ok(_) = tunnel.await_hello(b.tunnels, b.key, 2000)
  let assert Ok(conn) = gun.connect_unix(path, 2000)
  let assert Ok(resp) = gun.request(conn, http.Get, "/one", [], <<>>, 5000)
  let assert <<"ok /one">> = resp.body
  let _ = next(first)
  // Another crush takes over the control socket...
  let second = process.new_subject()
  hello(fake_crush(b, second, True), 1)
  let assert ClosedWith(4000) = next(first)
  let assert Ok(_) = tunnel.await_hello(b.tunnels, b.key, 2000)
  // ...but the stream the first one is serving carries on.
  let assert Ok(resp) = gun.request(conn, http.Get, "/two", [], <<>>, 5000)
  let assert <<"ok /two">> = resp.body
  let assert Error(Nil) = process.receive(second, 100)
  gun.close(conn)
  // New connections go to the new crush.
  let assert Ok(Ok(resp)) = process.receive(ask(path, "/three"), 3000)
  let assert <<"ok /three">> = resp.body
  let _ = open_id(next(second))
  tunnel.close(b.tunnels, b.key)
}

pub fn open_checks_the_key_and_path_test() {
  let b = bridge()
  let assert Error(_) = tunnel.open(b.tunnels, "")
  let assert Error(_) = tunnel.open(b.tunnels, ".")
  let assert Error(_) = tunnel.open(b.tunnels, "..")
  let assert Error(_) = tunnel.open(b.tunnels, "a/b")
  let assert Error(_) = tunnel.open(b.tunnels, string.repeat("a", 65))
  let assert Ok(long) =
    tunnel.start(tunnel.config(secret, "/tmp/" <> string.repeat("r", 95)))
  let assert Error(reason) = tunnel.open(long, "C1-1.2")
  let assert True = string.contains(reason, "too long")
  let assert True = string.contains(reason, "/shim.sock")
}

pub fn reissued_open_that_times_out_is_forgotten_test() {
  let b = bridge_with(400)
  let assert Ok(path) = tunnel.open(b.tunnels, b.key)
  let first = process.new_subject()
  hello(fake_crush(b, first, False), 1)
  let assert Ok(_) = tunnel.await_hello(b.tunnels, b.key, 2000)
  let asker = ask(path, "/never")
  let old = open_id(next(first))
  // Redialed: the open goes out again under a new id, which nobody dials.
  let second = process.new_subject()
  hello(fake_crush(b, second, False), 1)
  let assert ClosedWith(4000) = next(first)
  let new = open_id(next(second))
  let assert True = new != old
  let assert [_] = tunnel.pending(b.tunnels, b.key)
  // The connection gives up, and leaves nothing behind.
  let assert Ok(Error(_)) = process.receive(asker, 3000)
  let assert [] = wait_pending(b, 0)
  tunnel.close(b.tunnels, b.key)
}

fn wait_gone(path: String, tries: Int) -> Bool {
  case is_socket(path), tries {
    False, _ -> True
    True, 0 -> False
    True, _ -> {
      process.sleep(10)
      wait_gone(path, tries - 1)
    }
  }
}

pub fn dead_shim_removes_only_its_own_socket_test() {
  let dir =
    "/tmp/crushling-shim-" <> int.to_string(int.absolute_value(unique()))
  let assert Ok(Nil) = mkdir_p(dir)
  let path = dir <> "/shim.sock"
  let assert Ok(old) = shim.start(path, 1000, fn(_) { Nil })
  let assert True = is_socket(path)
  // Killed, the listener's socket file goes with it.
  process.kill(shim.pid(old))
  let assert True = wait_gone(path, 200)
  // A replacement at the same path is left alone by the old shim.
  let assert Ok(new) = shim.start(path, 1000, fn(_) { Nil })
  shim.stop(old)
  shim.cleanup(old)
  let assert True = is_socket(path)
  let assert Ok(conn) = gun.connect_unix(path, 1000)
  gun.close(conn)
  shim.stop(new)
  let assert False = is_socket(path)
}
