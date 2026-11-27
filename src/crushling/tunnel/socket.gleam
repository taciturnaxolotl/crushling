//// The tunnel's websockets, served by mist: each thread's control socket
//// and its data sockets, with a keepalive on every one.
////
//// Data sockets are full-close only: there is no half-close, so whichever
//// side closes first ends the connection both ways. The bridge forwards
//// every chunk the unix side sent before acting on its hangup.

import crushling/sandbox_http
import crushling/sys
import crushling/token
import crushling/tunnel/endpoint.{type Pending}
import crushling/tunnel/hub
import crushling/tunnel/protocol.{type Command}
import crushling/tunnel/shim
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import mist

pub type Settings {
  Settings(
    /// The instance secret tokens are derived from.
    secret: String,
    /// How often every socket is pinged.
    ping_ms: Int,
    /// Pings in a row without a reply before a socket is closed.
    missed_pongs: Int,
  )
}

/// The route that accepts tunnels at `/tunnel/<key>/...`.
pub fn route(
  hub: Subject(hub.Message),
  settings: Settings,
) -> sandbox_http.Route {
  fn(req: Request(mist.Connection)) {
    case request.path_segments(req) {
      ["tunnel", key, ..rest] -> Some(serve(hub, settings, req, key, rest))
      _ -> None
    }
  }
}

fn serve(
  hub: Subject(hub.Message),
  settings: Settings,
  req: Request(mist.Connection),
  key: String,
  rest: List(String),
) -> Response(mist.ResponseData) {
  let reply = sandbox_http.reply
  let auth = request.get_header(req, "authorization") |> result.unwrap("")
  case token.authorized(settings.secret, token.Tunnel, key, auth) {
    False -> reply(401, "")
    True ->
      case req.method, rest {
        http.Get, ["control"] ->
          case process.call(hub, 5000, hub.Knows(key, _)) {
            True -> control(hub, settings, req, key)
            False -> reply(404, "")
          }
        http.Get, ["data", id] ->
          case int.parse(id) {
            Error(Nil) -> reply(404, "")
            Ok(id) ->
              case process.call(hub, 5000, hub.Reserve(key, id, _)) {
                Error(Nil) -> reply(404, "")
                Ok(#(ref, pending)) -> {
                  // The data socket commits the claim once it is up.
                  let response = data(hub, settings, key, ref, req, pending)
                  case response.status {
                    200 -> Nil
                    _ -> process.send(hub, hub.Release(key, ref))
                  }
                  response
                }
              }
          }
        _, _ -> reply(404, "")
      }
  }
}

// Keepalive ------------------------------------------------------------------

@external(erlang, "crushling_tunnel_ffi", "ws_ping")
fn ws_ping(conn: mist.WebsocketConnection) -> Nil

@external(erlang, "crushling_tunnel_ffi", "ws_close")
fn ws_close(conn: mist.WebsocketConnection, code: Int, reason: String) -> Nil

@external(erlang, "crushling_tunnel_ffi", "ws_received")
fn ws_received(conn: mist.WebsocketConnection) -> Int

/// mist answers pings but never shows its handler a pong, so liveness is
/// judged by the socket's received byte count: a ping is answered if
/// anything (a pong or data) arrived before the next tick.
type Alive {
  Alive(seen: Int, waiting: Bool, missed: Int)
}

const fresh = Alive(seen: 0, waiting: False, missed: 0)

fn beat(
  conn: mist.WebsocketConnection,
  alive: Alive,
  settings: Settings,
) -> Result(Alive, Nil) {
  let seen = ws_received(conn)
  let missed = case alive.waiting && seen == alive.seen {
    True -> alive.missed + 1
    False -> 0
  }
  case missed >= settings.missed_pongs {
    True -> Error(Nil)
    False -> {
      ws_ping(conn)
      Ok(Alive(seen:, waiting: True, missed:))
    }
  }
}

// The control socket ---------------------------------------------------------

type ControlState {
  ControlState(self: Subject(Command), alive: Alive)
}

fn control(
  hub: Subject(hub.Message),
  settings: Settings,
  req: Request(mist.Connection),
  key: String,
) -> Response(mist.ResponseData) {
  mist.websocket(
    request: req,
    on_init: fn(_conn) {
      let self = process.new_subject()
      let selector = process.new_selector() |> process.select(self)
      // The socket goes with the hub.
      let selector = case process.subject_owner(hub) {
        Ok(pid) ->
          process.select_specific_monitor(selector, process.monitor(pid), fn(_) {
            protocol.Retire
          })
        Error(Nil) -> selector
      }
      process.send(hub, hub.ControlUp(key, self))
      process.send_after(self, settings.ping_ms, protocol.Tick)
      #(ControlState(self:, alive: fresh), Some(selector))
    },
    on_close: fn(state) { process.send(hub, hub.ControlDown(key, state.self)) },
    handler: fn(state: ControlState, message, conn) {
      case message {
        mist.Text(text) ->
          case json.parse(text, protocol.hello_decoder()) {
            Ok(#(1, crush)) -> {
              process.send(hub, hub.Hello(key, state.self, crush))
              mist.continue(state)
            }
            Ok(#(v, _)) -> {
              sys.warn(
                "crushling: tunnel "
                <> key
                <> ": crush speaks protocol v"
                <> int.to_string(v),
              )
              ws_close(conn, 4001, "unsupported version")
              mist.stop()
            }
            Error(_) -> mist.continue(state)
          }
        mist.Custom(protocol.SendOpen(id)) ->
          send_text(conn, state, protocol.open_frame(id))
        mist.Custom(protocol.SendBye) ->
          send_text(conn, state, protocol.bye_frame())
        mist.Custom(protocol.Superseded) -> {
          ws_close(conn, 4000, "superseded")
          mist.stop()
        }
        mist.Custom(protocol.Retire) -> mist.stop()
        mist.Custom(protocol.Tick) ->
          case beat(conn, state.alive, settings) {
            Error(Nil) -> mist.stop()
            Ok(alive) -> {
              process.send_after(state.self, settings.ping_ms, protocol.Tick)
              mist.continue(ControlState(..state, alive:))
            }
          }
        _ -> mist.continue(state)
      }
    },
  )
}

fn send_text(
  conn: mist.WebsocketConnection,
  state: ControlState,
  frame: String,
) -> mist.Next(ControlState, Command) {
  case mist.send_text_frame(conn, frame) {
    Ok(Nil) -> mist.continue(state)
    Error(_) -> mist.stop()
  }
}

// Data sockets ---------------------------------------------------------------

type DataMessage {
  Outgoing(BitArray)
  Hangup
  DataTick
}

type DataState {
  DataState(self: Subject(DataMessage), pending: Pending, alive: Alive)
}

fn data(
  hub: Subject(hub.Message),
  settings: Settings,
  key: String,
  ref: Int,
  req: Request(mist.Connection),
  pending: Pending,
) -> Response(mist.ResponseData) {
  mist.websocket(
    request: req,
    on_init: fn(_conn) {
      // Only now, with the upgrade sent, is the id used up.
      process.send(hub, hub.Commit(key, ref))
      let self = process.new_subject()
      let selector = process.new_selector() |> process.select(self)
      // The shim connection may have given up already; then it's gone.
      let selector = case process.subject_owner(pending.events) {
        Ok(pid) ->
          process.select_specific_monitor(selector, process.monitor(pid), fn(_) {
            Hangup
          })
        Error(Nil) -> selector
      }
      process.send(
        pending.events,
        shim.Attached(
          shim.Upstream(
            pid: process.self(),
            send: fn(bytes) { process.send(self, Outgoing(bytes)) },
            hangup: fn() { process.send(self, Hangup) },
          ),
        ),
      )
      process.send_after(self, settings.ping_ms, DataTick)
      #(DataState(self:, pending:, alive: fresh), Some(selector))
    },
    on_close: fn(state) { process.send(state.pending.events, shim.Hangup) },
    handler: fn(state: DataState, message, conn) {
      case message {
        // A write that times out closes the unix side and ends the stream.
        mist.Binary(bytes) ->
          case shim.write(state.pending.socket, bytes) {
            Ok(Nil) -> mist.continue(state)
            Error(Nil) -> mist.stop()
          }
        // The shim sends its hangup after its last chunk, so every chunk
        // is forwarded before the hangup is acted on.
        mist.Custom(Outgoing(bytes)) ->
          case mist.send_binary_frame(conn, bytes) {
            Ok(Nil) -> {
              process.send(state.pending.events, shim.Written)
              mist.continue(state)
            }
            Error(_) -> mist.stop()
          }
        mist.Custom(Hangup) -> mist.stop()
        mist.Custom(DataTick) ->
          case beat(conn, state.alive, settings) {
            Error(Nil) -> mist.stop()
            Ok(alive) -> {
              process.send_after(state.self, settings.ping_ms, DataTick)
              mist.continue(DataState(..state, alive:))
            }
          }
        _ -> mist.continue(state)
      }
    },
  )
}
