//// Dial-out tunnels: each thread's `crush server` runs with
//// `--dial ws://<bridge>/tunnel/<key>` and connects to the bridge instead
//// of listening, and the bridge exposes it again as a unix socket (the
//// shim, `<root>/<key>/shim.sock`), so the HTTP client is unchanged.
////
//// crush keeps a control socket open at `/tunnel/<key>/control` (JSON
//// text frames). When the shim accepts a connection the bridge sends
//// `{"op":"open","id":N}`, crush dials `/tunnel/<key>/data/N`, and that
//// socket's binary frames carry the connection's bytes. Every dial carries
//// the thread's `token.Tunnel` bearer token.
////
//// One actor holds every key's endpoint. Bytes never pass through it: each
//// shim connection is spliced directly to its data socket's process.
////
//// Data sockets are full-close only: there is no half-close, so whichever
//// side closes first ends the connection both ways. The bridge forwards
//// every chunk the unix side sent before acting on its hangup.
////
//// Each control socket is a generation. When one goes or is replaced,
//// opens it never answered are reissued under fresh ids, so a late dial
//// for an old id is turned away rather than racing the new crush's dial.

import crushling/sandbox_http
import crushling/sys
import crushling/token
import crushling/tunnel/shim
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import mist

/// A change in whether a thread's crush is connected.
pub type Event {
  /// A control socket said hello.
  Dialed(key: String)
  /// The control socket that said hello has gone.
  Undialed(key: String)
}

pub type Config {
  Config(
    /// The instance secret tokens are derived from.
    secret: String,
    /// The threads' root; each shim is `<root>/<key>/shim.sock`.
    root: String,
    /// How often every socket is pinged.
    ping_ms: Int,
    /// Pings in a row without a reply before a socket is closed.
    missed_pongs: Int,
    /// How long a shim connection waits for its data socket.
    data_timeout_ms: Int,
    /// How long a write to a shim connection may block before the
    /// connection is aborted.
    write_timeout_ms: Int,
    /// Told about `Event`s, from the tunnels' actor: it must not block.
    on_event: fn(Event) -> Nil,
  )
}

/// The production settings.
pub fn config(secret: String, root: String) -> Config {
  Config(
    secret:,
    root:,
    ping_ms: 15_000,
    missed_pongs: 2,
    data_timeout_ms: 10_000,
    write_timeout_ms: 30_000,
    on_event: fn(_) { Nil },
  )
}

/// The running tunnels.
pub opaque type Tunnels {
  Tunnels(subject: Subject(Message), config: Config)
}

/// The token a thread's crush presents.
pub fn token(secret: String, key: String) -> String {
  token.mint(secret, token.Tunnel, key)
}

/// The environment `crush server --dial` needs.
pub fn env(secret: String, key: String) -> List(String) {
  ["CRUSH_SERVER_DIAL_TOKEN=" <> token(secret, key)]
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

/// Where a thread's shim listens.
pub fn shim_path(root: String, key: String) -> String {
  root <> "/" <> key <> "/shim.sock"
}

/// The longest unix socket path, in bytes, that fits a `sockaddr_un` on
/// both macOS (103) and Linux (107).
const max_socket_path = 103

// The actor ------------------------------------------------------------------

type Message {
  Open(key: String, reply: Subject(Result(String, String)))
  Close(key: String)
  AwaitHello(key: String, reply: Subject(Result(String, String)))
  ForgetWaiter(key: String, reply: Subject(Result(String, String)))
  Bye(key: String)
  IsDialed(key: String, reply: Subject(Bool))
  Knows(key: String, reply: Subject(Bool))
  PendingIds(key: String, reply: Subject(List(Int)))
  Connect(
    key: String,
    socket: shim.Socket,
    events: Subject(shim.Event),
    reply: Subject(Result(Int, Nil)),
  )
  /// The connection with this registration ref gave up waiting.
  Abandon(key: String, ref: Int)
  /// Hold a pending id for a data dial while its upgrade is answered.
  /// Replies with the connection's ref.
  Reserve(key: String, id: Int, reply: Subject(Result(#(Int, Pending), Nil)))
  /// The upgrade went through: the connection is attached.
  Commit(key: String, ref: Int)
  /// The upgrade failed: the connection may be dialed again.
  Release(key: String, ref: Int)
  ControlUp(key: String, control: Subject(ControlMessage))
  Hello(key: String, control: Subject(ControlMessage), crush: String)
  ControlDown(key: String, control: Subject(ControlMessage))
  /// A listener or control socket process exited.
  Down(pid: process.Pid)
}

/// A shim connection waiting for its data socket. `id` is its current
/// wire id, which changes when it is reissued; `sent` is the control
/// generation its open went out on, if it has.
type Pending {
  Pending(
    id: Int,
    socket: shim.Socket,
    events: Subject(shim.Event),
    sent: Option(Int),
    reserved: Bool,
  )
}

type Endpoint {
  Endpoint(
    /// None if the listener died; `open` starts another.
    shim: Option(shim.Shim),
    control: Option(Subject(ControlMessage)),
    /// Bumped whenever the control socket goes or is replaced.
    generation: Int,
    /// crush's version, once the current control socket said hello.
    crush: Option(String),
    waiters: List(Subject(Result(String, String))),
    /// Waiting connections by their registration ref, which never changes.
    pending: Dict(Int, Pending),
    /// Wire id to registration ref.
    wires: Dict(Int, Int),
  )
}

type State {
  State(
    self: Subject(Message),
    config: Config,
    endpoints: Dict(String, Endpoint),
    next_id: Int,
    next_ref: Int,
  )
}

/// Start the tunnels' actor. Serve them with `route`. Its listeners and
/// control sockets stop if it does.
pub fn start(config: Config) -> Result(Tunnels, String) {
  actor.new_with_initialiser(1000, fn(self) {
    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select_monitors(fn(down) {
        case down {
          process.ProcessDown(pid:, ..) -> Down(pid)
          process.PortDown(..) -> Down(process.self())
        }
      })
    State(self:, config:, endpoints: dict.new(), next_id: 1, next_ref: 1)
    |> actor.initialised
    |> actor.selecting(selector)
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { Tunnels(subject: started.data, config:) })
  |> result.map_error(fn(error) { "tunnels: " <> string.inspect(error) })
}

/// Start a thread's endpoint: listen on its shim and accept its crush.
/// Returns the shim's path. Opening an open endpoint returns the same path.
/// The key must be one path component of `A-Za-z0-9._-`, at most 64 long.
pub fn open(tunnels: Tunnels, key: String) -> Result(String, String) {
  use _ <- result.try(check_key(key))
  let path = shim_path(tunnels.config.root, key)
  use _ <- result.try(case string.byte_size(path) > max_socket_path {
    True ->
      Error(
        "shim socket path is too long for a unix socket ("
        <> int.to_string(string.byte_size(path))
        <> " bytes, at most "
        <> int.to_string(max_socket_path)
        <> "): "
        <> path,
      )
    False -> Ok(Nil)
  })
  process.call(tunnels.subject, 10_000, Open(key, _))
}

fn check_key(key: String) -> Result(Nil, String) {
  let safe = fn(c) {
    let c = string.utf_codepoint_to_int(c)
    { c >= 0x41 && c <= 0x5A }
    || { c >= 0x61 && c <= 0x7A }
    || { c >= 0x30 && c <= 0x39 }
    || c == 0x2E
    || c == 0x5F
    || c == 0x2D
  }
  let length = string.length(key)
  case
    key != "."
    && key != ".."
    && length >= 1
    && length <= 64
    && list.all(string.to_utf_codepoints(key), safe)
  {
    True -> Ok(Nil)
    False -> Error("not a valid tunnel key: " <> string.inspect(key))
  }
}

/// Wait until the thread's crush has dialed in and said hello, returning
/// its version. Returns at once if it already has.
pub fn await_hello(
  tunnels: Tunnels,
  key: String,
  timeout_ms: Int,
) -> Result(String, String) {
  let reply = process.new_subject()
  process.send(tunnels.subject, AwaitHello(key, reply))
  case process.receive(reply, timeout_ms) {
    Ok(result) -> result
    Error(Nil) -> {
      process.send(tunnels.subject, ForgetWaiter(key, reply))
      Error(
        "crush did not dial in within " <> int.to_string(timeout_ms) <> "ms",
      )
    }
  }
}

/// Tell the thread's crush to exit and not redial.
pub fn bye(tunnels: Tunnels, key: String) -> Nil {
  process.send(tunnels.subject, Bye(key))
}

/// Close a thread's endpoint: its shim, its connections and its sockets.
pub fn close(tunnels: Tunnels, key: String) -> Nil {
  process.send(tunnels.subject, Close(key))
}

/// Whether the thread's crush is dialed in and has said hello.
pub fn dialed(tunnels: Tunnels, key: String) -> Bool {
  process.call(tunnels.subject, 5000, IsDialed(key, _))
}

/// The ids of shim connections still waiting for a data socket, for
/// diagnostics and tests.
pub fn pending(tunnels: Tunnels, key: String) -> List(Int) {
  process.call(tunnels.subject, 5000, PendingIds(key, _))
}

@external(erlang, "crushling_ffi", "mkdir_p")
fn mkdir_p(path: String) -> Result(Nil, String)

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  let config = state.config
  let update = fn(key, endpoint) {
    State(..state, endpoints: dict.insert(state.endpoints, key, endpoint))
  }
  let get = fn(key) { dict.get(state.endpoints, key) }
  case message {
    Open(key, reply) ->
      case get(key) {
        Ok(Endpoint(shim: Some(listening), ..)) -> {
          process.send(reply, Ok(shim.path(listening)))
          actor.continue(state)
        }
        found -> {
          let path = shim_path(config.root, key)
          let started = {
            use _ <- result.try(mkdir_p(config.root <> "/" <> key))
            shim.start(path, config.write_timeout_ms, connection(
              state.self,
              config,
              key,
              _,
            ))
          }
          case started {
            Error(reason) -> {
              process.send(reply, Error(reason))
              actor.continue(state)
            }
            Ok(listening) -> {
              process.monitor(shim.pid(listening))
              process.send(reply, Ok(path))
              let endpoint = case found {
                Ok(endpoint) -> Endpoint(..endpoint, shim: Some(listening))
                Error(Nil) ->
                  Endpoint(
                    shim: Some(listening),
                    control: None,
                    generation: 0,
                    crush: None,
                    waiters: [],
                    pending: dict.new(),
                    wires: dict.new(),
                  )
              }
              actor.continue(update(key, endpoint))
            }
          }
        }
      }

    Close(key) ->
      case get(key) {
        Error(Nil) -> actor.continue(state)
        Ok(endpoint) -> {
          option.map(endpoint.shim, shim.stop)
          option.map(endpoint.control, process.send(_, Retire))
          list.each(endpoint.waiters, process.send(_, Error("tunnel closed")))
          dict.each(endpoint.pending, fn(_, pending) {
            process.send(pending.events, shim.Hangup)
          })
          case endpoint.crush {
            Some(_) -> config.on_event(Undialed(key))
            None -> Nil
          }
          actor.continue(
            State(..state, endpoints: dict.delete(state.endpoints, key)),
          )
        }
      }

    AwaitHello(key, reply) ->
      case get(key) {
        Error(Nil) -> {
          process.send(reply, Error("no tunnel for " <> key))
          actor.continue(state)
        }
        Ok(Endpoint(control: Some(_), crush: Some(crush), ..)) -> {
          process.send(reply, Ok(crush))
          actor.continue(state)
        }
        Ok(endpoint) ->
          actor.continue(update(
            key,
            Endpoint(..endpoint, waiters: [reply, ..endpoint.waiters]),
          ))
      }

    ForgetWaiter(key, reply) ->
      case get(key) {
        Error(Nil) -> actor.continue(state)
        Ok(endpoint) ->
          actor.continue(update(
            key,
            Endpoint(
              ..endpoint,
              waiters: list.filter(endpoint.waiters, fn(w) { w != reply }),
            ),
          ))
      }

    Bye(key) -> {
      case get(key) {
        Ok(Endpoint(control: Some(control), ..)) ->
          process.send(control, SendBye)
        _ -> Nil
      }
      actor.continue(state)
    }

    IsDialed(key, reply) -> {
      process.send(reply, case get(key) {
        Ok(endpoint) -> is_dialed(endpoint)
        Error(Nil) -> False
      })
      actor.continue(state)
    }

    Knows(key, reply) -> {
      process.send(reply, dict.has_key(state.endpoints, key))
      actor.continue(state)
    }

    PendingIds(key, reply) -> {
      process.send(reply, case get(key) {
        Ok(endpoint) -> dict.keys(endpoint.wires) |> list.sort(int.compare)
        Error(Nil) -> []
      })
      actor.continue(state)
    }

    Connect(key, socket, events, reply) ->
      case get(key) {
        Error(Nil) -> {
          process.send(reply, Error(Nil))
          actor.continue(state)
        }
        Ok(endpoint) -> {
          let id = state.next_id
          let ref = state.next_ref
          process.send(reply, Ok(ref))
          let pending =
            Pending(id:, socket:, events:, sent: None, reserved: False)
            |> send_open(endpoint, _)
          let endpoint =
            Endpoint(
              ..endpoint,
              pending: dict.insert(endpoint.pending, ref, pending),
              wires: dict.insert(endpoint.wires, id, ref),
            )
          actor.continue(
            State(
              ..update(key, endpoint),
              next_id: next_id(id),
              next_ref: ref + 1,
            ),
          )
        }
      }

    Abandon(key, ref) -> actor.continue(drop_pending(state, key, ref))

    Reserve(key, id, reply) ->
      case
        get(key)
        |> result.try(fn(e) {
          use ref <- result.try(dict.get(e.wires, id))
          dict.get(e.pending, ref) |> result.map(fn(p) { #(ref, p) })
        })
      {
        Ok(#(ref, Pending(reserved: False, ..) as pending)) -> {
          process.send(reply, Ok(#(ref, pending)))
          let assert Ok(endpoint) = get(key)
          let pending = Pending(..pending, reserved: True)
          actor.continue(update(
            key,
            Endpoint(
              ..endpoint,
              pending: dict.insert(endpoint.pending, ref, pending),
            ),
          ))
        }
        _ -> {
          process.send(reply, Error(Nil))
          actor.continue(state)
        }
      }

    Commit(key, ref) -> actor.continue(drop_pending(state, key, ref))

    Release(key, ref) ->
      case get(key) |> result.try(fn(e) { dict.get(e.pending, ref) }) {
        Error(Nil) -> actor.continue(state)
        Ok(pending) -> {
          let assert Ok(endpoint) = get(key)
          let pending = Pending(..pending, reserved: False)
          let endpoint =
            Endpoint(
              ..endpoint,
              pending: dict.insert(endpoint.pending, ref, pending),
            )
          // Released after its generation ended: reissue it now.
          let #(endpoint, next_id) = reissue(endpoint, state.next_id)
          actor.continue(State(..update(key, endpoint), next_id:))
        }
      }

    ControlUp(key, control) ->
      case get(key), process.subject_owner(control) {
        Ok(endpoint), Ok(pid) -> {
          process.monitor(pid)
          case endpoint.control {
            Some(old) -> process.send(old, Superseded)
            None -> Nil
          }
          case endpoint.crush {
            Some(_) -> config.on_event(Undialed(key))
            None -> Nil
          }
          let endpoint =
            Endpoint(
              ..endpoint,
              control: Some(control),
              generation: endpoint.generation + 1,
              crush: None,
            )
          let #(endpoint, next_id) = reissue(endpoint, state.next_id)
          actor.continue(State(..update(key, endpoint), next_id:))
        }
        _, _ -> {
          process.send(control, Retire)
          actor.continue(state)
        }
      }

    Hello(key, control, crush) ->
      case get(key) {
        Ok(Endpoint(control: Some(current), ..) as endpoint)
          if current == control
        -> {
          sys.info("crushling: tunnel " <> key <> ": crush " <> crush)
          list.each(endpoint.waiters, process.send(_, Ok(crush)))
          let endpoint = Endpoint(..endpoint, crush: Some(crush), waiters: [])
          let pending =
            dict.map_values(endpoint.pending, fn(_, pending) {
              send_open(endpoint, pending)
            })
          config.on_event(Dialed(key))
          actor.continue(update(key, Endpoint(..endpoint, pending:)))
        }
        _ -> actor.continue(state)
      }

    ControlDown(key, control) ->
      actor.continue(control_down(state, key, control))

    Down(pid) -> {
      let state =
        dict.fold(state.endpoints, state, fn(state, key, endpoint) {
          let state = case endpoint.shim {
            Some(listening) ->
              case shim.pid(listening) == pid {
                True -> {
                  sys.warn("crushling: tunnel " <> key <> ": shim stopped")
                  shim.cleanup(listening)
                  State(
                    ..state,
                    endpoints: dict.insert(
                      state.endpoints,
                      key,
                      Endpoint(..endpoint, shim: None),
                    ),
                  )
                }
                False -> state
              }
            _ -> state
          }
          case endpoint.control {
            Some(control) ->
              case process.subject_owner(control) == Ok(pid) {
                True -> control_down(state, key, control)
                False -> state
              }
            None -> state
          }
        })
      actor.continue(state)
    }
  }
}

fn is_dialed(endpoint: Endpoint) -> Bool {
  option.is_some(endpoint.control) && option.is_some(endpoint.crush)
}

/// Send a pending connection's open if crush is listening and it hasn't
/// gone out on this generation.
fn send_open(endpoint: Endpoint, pending: Pending) -> Pending {
  case endpoint.control, is_dialed(endpoint), pending.sent {
    Some(control), True, None -> {
      process.send(control, SendOpen(pending.id))
      Pending(..pending, sent: Some(endpoint.generation))
    }
    _, _, _ -> pending
  }
}

/// Give every open sent on an earlier generation, and not being dialed
/// right now, a fresh id. The old ids are forgotten, so dials for them get
/// 404; the new ones are sent once the current control socket says hello.
fn reissue(endpoint: Endpoint, first: Int) -> #(Endpoint, Int) {
  dict.fold(endpoint.pending, #(endpoint, first), fn(acc, ref, pending) {
    let #(endpoint, next) = acc
    case pending.sent, pending.reserved {
      Some(generation), False if generation != endpoint.generation -> {
        let fresh =
          send_open(endpoint, Pending(..pending, id: next, sent: None))
        let wires =
          dict.delete(endpoint.wires, pending.id) |> dict.insert(next, ref)
        let pending = dict.insert(endpoint.pending, ref, fresh)
        #(Endpoint(..endpoint, pending:, wires:), next_id(next))
      }
      _, _ -> acc
    }
  })
}

fn drop_pending(state: State, key: String, ref: Int) -> State {
  case dict.get(state.endpoints, key) {
    Error(Nil) -> state
    Ok(endpoint) -> {
      let wires = case dict.get(endpoint.pending, ref) {
        Ok(pending) -> dict.delete(endpoint.wires, pending.id)
        Error(Nil) -> endpoint.wires
      }
      let pending = dict.delete(endpoint.pending, ref)
      State(
        ..state,
        endpoints: dict.insert(
          state.endpoints,
          key,
          Endpoint(..endpoint, pending:, wires:),
        ),
      )
    }
  }
}

fn control_down(
  state: State,
  key: String,
  control: Subject(ControlMessage),
) -> State {
  case dict.get(state.endpoints, key) {
    Ok(Endpoint(control: Some(current), ..) as endpoint) if current == control -> {
      case endpoint.crush {
        Some(_) -> state.config.on_event(Undialed(key))
        None -> Nil
      }
      let endpoint =
        Endpoint(
          ..endpoint,
          control: None,
          generation: endpoint.generation + 1,
          crush: None,
        )
      let #(endpoint, next_id) = reissue(endpoint, state.next_id)
      State(
        ..state,
        endpoints: dict.insert(state.endpoints, key, endpoint),
        next_id:,
      )
    }
    _ -> state
  }
}

/// Ids are u32s, and never 0.
fn next_id(id: Int) -> Int {
  case id >= 4_294_967_295 {
    True -> 1
    False -> id + 1
  }
}

/// Serve one shim connection, in its own process.
fn connection(
  tunnels: Subject(Message),
  config: Config,
  key: String,
  socket: shim.Socket,
) -> Nil {
  shim.relay(
    socket,
    fn(events) {
      process.call(tunnels, 5000, Connect(key, socket, events, _))
      |> result.map(fn(ref) {
        fn() { process.send(tunnels, Abandon(key, ref)) }
      })
    },
    config.data_timeout_ms,
  )
}

// The route ------------------------------------------------------------------

/// The route that accepts tunnels at `/tunnel/<key>/...`.
pub fn route(tunnels: Tunnels) -> sandbox_http.Route {
  fn(req: Request(mist.Connection)) {
    case request.path_segments(req) {
      ["tunnel", key, ..rest] -> Some(serve(tunnels, req, key, rest))
      _ -> None
    }
  }
}

fn serve(
  tunnels: Tunnels,
  req: Request(mist.Connection),
  key: String,
  rest: List(String),
) -> Response(mist.ResponseData) {
  let reply = sandbox_http.reply
  let auth = request.get_header(req, "authorization") |> result.unwrap("")
  case token.authorized(tunnels.config.secret, token.Tunnel, key, auth) {
    False -> reply(401, "")
    True ->
      case req.method, rest {
        http.Get, ["control"] ->
          case process.call(tunnels.subject, 5000, Knows(key, _)) {
            True -> control(tunnels, req, key)
            False -> reply(404, "")
          }
        http.Get, ["data", id] ->
          case int.parse(id) {
            Error(Nil) -> reply(404, "")
            Ok(id) ->
              case process.call(tunnels.subject, 5000, Reserve(key, id, _)) {
                Error(Nil) -> reply(404, "")
                Ok(#(ref, pending)) -> {
                  // The data socket commits the claim once it is up.
                  let response = data(tunnels, key, ref, req, pending)
                  case response.status {
                    200 -> Nil
                    _ -> process.send(tunnels.subject, Release(key, ref))
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

fn beat(
  conn: mist.WebsocketConnection,
  alive: Alive,
  config: Config,
) -> Result(Alive, Nil) {
  let seen = ws_received(conn)
  let missed = case alive.waiting && seen == alive.seen {
    True -> alive.missed + 1
    False -> 0
  }
  case missed >= config.missed_pongs {
    True -> Error(Nil)
    False -> {
      ws_ping(conn)
      Ok(Alive(seen:, waiting: True, missed:))
    }
  }
}

// The control socket ---------------------------------------------------------

type ControlMessage {
  SendOpen(Int)
  SendBye
  Superseded
  Retire
  ControlTick
}

type ControlState {
  ControlState(self: Subject(ControlMessage), alive: Alive)
}

fn control(
  tunnels: Tunnels,
  req: Request(mist.Connection),
  key: String,
) -> Response(mist.ResponseData) {
  let config = tunnels.config
  mist.websocket(
    request: req,
    on_init: fn(_conn) {
      let self = process.new_subject()
      let selector = process.new_selector() |> process.select(self)
      // The socket goes with the tunnels' actor.
      let selector = case process.subject_owner(tunnels.subject) {
        Ok(pid) ->
          process.select_specific_monitor(selector, process.monitor(pid), fn(_) {
            Retire
          })
        Error(Nil) -> selector
      }
      process.send(tunnels.subject, ControlUp(key, self))
      process.send_after(self, config.ping_ms, ControlTick)
      #(
        ControlState(self:, alive: Alive(seen: 0, waiting: False, missed: 0)),
        Some(selector),
      )
    },
    on_close: fn(state) {
      process.send(tunnels.subject, ControlDown(key, state.self))
    },
    handler: fn(state: ControlState, message, conn) {
      case message {
        mist.Text(text) ->
          case json.parse(text, hello_decoder()) {
            Ok(#(1, crush)) -> {
              process.send(tunnels.subject, Hello(key, state.self, crush))
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
        mist.Custom(SendOpen(id)) ->
          send_text(conn, state, [
            #("op", json.string("open")),
            #("id", json.int(id)),
          ])
        mist.Custom(SendBye) ->
          send_text(conn, state, [#("op", json.string("bye"))])
        mist.Custom(Superseded) -> {
          ws_close(conn, 4000, "superseded")
          mist.stop()
        }
        mist.Custom(Retire) -> mist.stop()
        mist.Custom(ControlTick) ->
          case beat(conn, state.alive, config) {
            Error(Nil) -> mist.stop()
            Ok(alive) -> {
              process.send_after(state.self, config.ping_ms, ControlTick)
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
  fields: List(#(String, json.Json)),
) -> mist.Next(ControlState, ControlMessage) {
  case mist.send_text_frame(conn, json.to_string(json.object(fields))) {
    Ok(Nil) -> mist.continue(state)
    Error(_) -> mist.stop()
  }
}

/// A hello's major protocol version and crush's version. A `v` given as
/// `"1.2"` or `1.2` counts as major 1.
fn hello_decoder() -> decode.Decoder(#(Int, String)) {
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
  tunnels: Tunnels,
  key: String,
  ref: Int,
  req: Request(mist.Connection),
  pending: Pending,
) -> Response(mist.ResponseData) {
  let config = tunnels.config
  mist.websocket(
    request: req,
    on_init: fn(_conn) {
      // Only now, with the upgrade sent, is the id used up.
      process.send(tunnels.subject, Commit(key, ref))
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
      process.send_after(self, config.ping_ms, DataTick)
      #(
        DataState(
          self:,
          pending:,
          alive: Alive(seen: 0, waiting: False, missed: 0),
        ),
        Some(selector),
      )
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
          case beat(conn, state.alive, config) {
            Error(Nil) -> mist.stop()
            Ok(alive) -> {
              process.send_after(state.self, config.ping_ms, DataTick)
              mist.continue(DataState(..state, alive:))
            }
          }
        _ -> mist.continue(state)
      }
    },
  )
}
