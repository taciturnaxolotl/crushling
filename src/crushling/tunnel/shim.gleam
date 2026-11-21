//// The local end of a dial-out tunnel: a unix socket the thread's HTTP
//// client connects to as if `crush server` were listening on it.
////
//// Each accepted connection waits for an upstream (a tunnel data socket)
//// and then has its bytes spliced to and from it until either side
//// closes. There is no half-close: the first close ends both ways.
////
//// Bytes towards the upstream are flow controlled: at most `window`
//// chunks are in flight, and the socket is only read again once the
//// upstream acknowledges one with `Written`. Bytes from the upstream are
//// written straight to the socket, and a write that blocks longer than the
//// shim's write timeout fails and closes the connection.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Subject}
import gleam/result

/// An accepted unix connection.
pub type Socket

type Listener

/// The inode and change time of a socket file, to tell it from a
/// replacement at the same path.
type Identity

/// A listening shim.
pub opaque type Shim {
  Shim(pid: Pid, path: String, identity: Identity)
}

/// Where a connection's bytes go once it has an upstream. Every chunk
/// given to `send` must be acknowledged with `Written`; `hangup` is sent
/// after the last chunk, so the upstream sees them in order. `pid` is
/// watched so the connection ends with it.
pub type Upstream {
  Upstream(pid: Pid, send: fn(BitArray) -> Nil, hangup: fn() -> Nil)
}

/// What a waiting or spliced connection is told.
pub type Event {
  /// The upstream arrived.
  Attached(Upstream)
  /// The upstream has passed one chunk on.
  Written
  /// The upstream has gone; close the connection.
  Hangup
}

/// Chunks in flight towards the upstream before the socket stops being
/// read.
const window = 4

@external(erlang, "crushling_tunnel_ffi", "listen")
fn listen(path: String, write_timeout_ms: Int) -> Result(Listener, String)

@external(erlang, "crushling_tunnel_ffi", "serve")
fn serve(
  listener: Listener,
  handle: fn(Socket) -> Nil,
  owner: Pid,
  path: String,
  identity: Identity,
) -> Nil

@external(erlang, "crushling_tunnel_ffi", "identity")
fn identity(path: String) -> Result(Identity, Nil)

@external(erlang, "crushling_tunnel_ffi", "remove_if_same")
fn remove_if_same(path: String, identity: Identity) -> Nil

@external(erlang, "crushling_tunnel_ffi", "send")
fn send(socket: Socket, data: BitArray) -> Result(Nil, Nil)

@external(erlang, "crushling_tunnel_ffi", "close")
fn close_socket(socket: Socket) -> Nil

@external(erlang, "crushling_tunnel_ffi", "active_once")
fn active_once(socket: Socket) -> Result(Nil, Nil)

/// Listen on `path`, running `handle` in a fresh process for each
/// connection. The shim stops when the calling process exits, and its
/// connections stop with it; one connection dying affects nothing else.
/// However it stops, its socket file is removed if it is still its own.
/// A write to a connection that blocks for `write_timeout_ms` fails.
pub fn start(
  path: String,
  write_timeout_ms: Int,
  handle: fn(Socket) -> Nil,
) -> Result(Shim, String) {
  let reply = process.new_subject()
  let owner = process.self()
  let pid =
    process.spawn_unlinked(fn() {
      case listen(path, write_timeout_ms) {
        Error(reason) -> process.send(reply, Error(reason))
        Ok(listener) ->
          case identity(path) {
            Error(Nil) -> process.send(reply, Error("socket file vanished"))
            Ok(identity) -> {
              process.send(reply, Ok(identity))
              serve(listener, handle, owner, path, identity)
            }
          }
      }
    })
  case process.receive(reply, 5000) {
    Ok(Ok(identity)) -> {
      let shim = Shim(pid:, path:, identity:)
      // A listener that is killed can't clean up after itself.
      process.spawn_unlinked(fn() {
        let monitor = process.monitor(pid)
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(_) { Nil })
        |> process.selector_receive_forever
        cleanup(shim)
      })
      Ok(shim)
    }
    Ok(Error(reason)) -> Error("could not listen on " <> path <> ": " <> reason)
    Error(Nil) -> {
      process.kill(pid)
      Error("could not listen on " <> path <> ": timed out")
    }
  }
}

/// Stop listening, close every connection and remove the socket file.
pub fn stop(shim: Shim) -> Nil {
  process.kill(shim.pid)
  cleanup(shim)
}

/// Remove the shim's socket file if it is still the one the shim bound,
/// so a dead shim never removes its replacement's socket.
pub fn cleanup(shim: Shim) -> Nil {
  remove_if_same(shim.path, shim.identity)
}

/// The socket's path.
pub fn path(shim: Shim) -> String {
  shim.path
}

/// The listener's process, to monitor.
pub fn pid(shim: Shim) -> Pid {
  shim.pid
}

/// Write bytes to a connection, from any process. Fails if the connection
/// has closed or the write timed out, which closes it.
pub fn write(socket: Socket, data: BitArray) -> Result(Nil, Nil) {
  send(socket, data)
}

/// Serve one connection from its own process: `request` asks for an
/// upstream to be sent to the given subject and returns a function that
/// withdraws the request. Without an upstream within `timeout_ms` the
/// connection is closed.
pub fn relay(
  socket: Socket,
  request: fn(Subject(Event)) -> Result(fn() -> Nil, Nil),
  timeout_ms: Int,
) -> Nil {
  let events = process.new_subject()
  case request(events) {
    Error(Nil) -> close_socket(socket)
    Ok(withdraw) ->
      case receive_attached(events, timeout_ms) {
        Ok(upstream) -> splice(socket, events, upstream)
        Error(Nil) -> {
          withdraw()
          close_socket(socket)
        }
      }
  }
}

fn receive_attached(
  events: Subject(Event),
  timeout_ms: Int,
) -> Result(Upstream, Nil) {
  case process.receive(events, timeout_ms) {
    Ok(Attached(upstream)) -> Ok(upstream)
    // Nothing else is sent before an upstream; skip it if it is.
    Ok(Written) -> receive_attached(events, timeout_ms)
    Ok(Hangup) | Error(Nil) -> Error(Nil)
  }
}

type Splice {
  Event(Event)
  Received(BitArray)
  Closed
  UpstreamDown
}

type Flow {
  Flow(in_flight: Int, armed: Bool)
}

fn splice(socket: Socket, events: Subject(Event), upstream: Upstream) -> Nil {
  let monitor = process.monitor(upstream.pid)
  let selector =
    process.new_selector()
    |> process.select_map(events, Event)
    |> process.select_specific_monitor(monitor, fn(_) { UpstreamDown })
    |> process.select_record(atom.create("tcp"), 2, fn(record) {
      decode.run(record, decode.at([2], decode.bit_array))
      |> result.map(Received)
      |> result.unwrap(Closed)
    })
    |> process.select_record(atom.create("tcp_closed"), 1, fn(_) { Closed })
    |> process.select_record(atom.create("tcp_error"), 2, fn(_) { Closed })
  arm(socket, selector, upstream, Flow(in_flight: 0, armed: False))
}

/// Read once more, unless the window is full or a read is already armed.
fn arm(
  socket: Socket,
  selector: process.Selector(Splice),
  upstream: Upstream,
  flow: Flow,
) -> Nil {
  case flow.armed || flow.in_flight >= window {
    True -> splice_loop(socket, selector, upstream, flow)
    False ->
      case active_once(socket) {
        Ok(Nil) ->
          splice_loop(socket, selector, upstream, Flow(..flow, armed: True))
        Error(Nil) -> {
          upstream.hangup()
          close_socket(socket)
        }
      }
  }
}

fn splice_loop(
  socket: Socket,
  selector: process.Selector(Splice),
  upstream: Upstream,
  flow: Flow,
) -> Nil {
  case process.selector_receive_forever(selector) {
    Received(data) -> {
      let flow = case bit_array.byte_size(data) {
        0 -> Flow(..flow, armed: False)
        _ -> {
          upstream.send(data)
          Flow(in_flight: flow.in_flight + 1, armed: False)
        }
      }
      arm(socket, selector, upstream, flow)
    }
    Event(Written) ->
      arm(
        socket,
        selector,
        upstream,
        Flow(..flow, in_flight: flow.in_flight - 1),
      )
    Closed -> {
      upstream.hangup()
      close_socket(socket)
    }
    Event(Hangup) | UpstreamDown -> close_socket(socket)
    // A second upstream can't happen; ignore it rather than crash.
    Event(Attached(_)) -> splice_loop(socket, selector, upstream, flow)
  }
}
