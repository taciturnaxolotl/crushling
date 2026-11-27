//// The actor that holds every thread's tunnel endpoint (`tunnel/endpoint`)
//// and carries out what its changes call for. Bytes never pass through it:
//// each shim connection is spliced directly to its data socket's process.
////
//// It monitors each endpoint's listener and control socket, indexed by
//// pid, so a process going down is found at once, and stops watching
//// whatever it closes or replaces.

import crushling/sys
import crushling/tunnel/endpoint.{type Effect, type Endpoints, type Pending}
import crushling/tunnel/protocol.{type Command}
import crushling/tunnel/shim
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result

pub type Settings {
  Settings(
    /// The threads' root; each shim is `protocol.shim_path(root, key)`.
    root: String,
    /// How long a shim connection waits for its data socket.
    data_timeout_ms: Int,
    /// How long a write to a shim connection may block.
    write_timeout_ms: Int,
    /// Told about changes, from the hub: it must not block.
    on_change: fn(endpoint.Change) -> Nil,
  )
}

pub type Message {
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
  ControlUp(key: String, control: Subject(Command))
  Hello(key: String, control: Subject(Command), crush: String)
  ControlDown(key: String, control: Subject(Command))
  /// A watched listener or control socket exited.
  Down(pid: Pid)
}

type Watched {
  Listener
  ControlSocket(Subject(Command))
}

type Watch {
  Watch(key: String, what: Watched, monitor: process.Monitor)
}

type State {
  State(
    self: Subject(Message),
    settings: Settings,
    endpoints: Endpoints(Subject(Command)),
    watched: Dict(Pid, Watch),
  )
}

/// Start the hub, registered under `name` when given. Its listeners and
/// control sockets stop if it does.
pub fn start(
  settings: Settings,
  name: Option(process.Name(Message)),
) -> actor.StartResult(Subject(Message)) {
  let builder =
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
      State(self:, settings:, endpoints: endpoint.new(), watched: dict.new())
      |> actor.initialised
      |> actor.selecting(selector)
      |> actor.returning(self)
      |> Ok
    })
    |> actor.on_message(handle)
  case name {
    Some(name) -> actor.named(builder, name)
    None -> builder
  }
  |> actor.start
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Open(key, reply) ->
      case endpoint.listening(state.endpoints, key) {
        Some(listening) -> {
          process.send(reply, Ok(shim.path(listening)))
          actor.continue(state)
        }
        None -> {
          let settings = state.settings
          let path = protocol.shim_path(settings.root, key)
          let started = {
            use _ <- result.try(sys.mkdir_p(protocol.shim_dir(settings.root)))
            shim.start(path, settings.write_timeout_ms, connection(
              state.self,
              settings,
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
              let state = watch(state, shim.pid(listening), key, Listener)
              process.send(reply, Ok(path))
              actor.continue(
                State(
                  ..state,
                  endpoints: endpoint.opened(state.endpoints, key, listening),
                ),
              )
            }
          }
        }
      }
    Close(key) -> apply(state, endpoint.close(state.endpoints, key))
    AwaitHello(key, reply) ->
      apply(state, endpoint.await_hello(state.endpoints, key, reply))
    ForgetWaiter(key, reply) ->
      actor.continue(
        State(
          ..state,
          endpoints: endpoint.forget_waiter(state.endpoints, key, reply),
        ),
      )
    Bye(key) ->
      apply(state, #(state.endpoints, endpoint.bye(state.endpoints, key)))
    IsDialed(key, reply) -> {
      process.send(reply, endpoint.dialed(state.endpoints, key))
      actor.continue(state)
    }
    Knows(key, reply) -> {
      process.send(reply, endpoint.knows(state.endpoints, key))
      actor.continue(state)
    }
    PendingIds(key, reply) -> {
      process.send(reply, endpoint.pending_ids(state.endpoints, key))
      actor.continue(state)
    }
    Connect(key, socket, events, reply) ->
      case endpoint.connect(state.endpoints, key, socket, events) {
        Error(Nil) -> {
          process.send(reply, Error(Nil))
          actor.continue(state)
        }
        Ok(#(endpoints, ref, effects)) -> {
          process.send(reply, Ok(ref))
          apply(state, #(endpoints, effects))
        }
      }
    Abandon(key, ref) | Commit(key, ref) ->
      actor.continue(
        State(..state, endpoints: endpoint.drop(state.endpoints, key, ref)),
      )
    Reserve(key, id, reply) ->
      case endpoint.reserve(state.endpoints, key, id) {
        Ok(#(endpoints, ref, pending)) -> {
          process.send(reply, Ok(#(ref, pending)))
          actor.continue(State(..state, endpoints:))
        }
        Error(Nil) -> {
          process.send(reply, Error(Nil))
          actor.continue(state)
        }
      }
    Release(key, ref) ->
      apply(state, endpoint.release(state.endpoints, key, ref))
    ControlUp(key, control) ->
      case
        endpoint.control_up(state.endpoints, key, control),
        process.subject_owner(control)
      {
        Ok(changed), Ok(pid) ->
          apply(watch(state, pid, key, ControlSocket(control)), changed)
        _, _ -> {
          process.send(control, protocol.Retire)
          actor.continue(state)
        }
      }
    Hello(key, control, crush) ->
      apply(state, endpoint.hello(state.endpoints, key, control, crush))
    ControlDown(key, control) ->
      apply(state, endpoint.control_down(state.endpoints, key, control))
    Down(pid) ->
      case dict.get(state.watched, pid) {
        Error(Nil) -> actor.continue(state)
        Ok(Watch(key:, what:, ..)) -> {
          let state = State(..state, watched: dict.delete(state.watched, pid))
          case what {
            Listener -> apply(state, endpoint.shim_down(state.endpoints, key))
            ControlSocket(control) ->
              apply(state, endpoint.control_down(state.endpoints, key, control))
          }
        }
      }
  }
}

fn watch(state: State, pid: Pid, key: String, what: Watched) -> State {
  let state = unwatch(state, pid)
  let watched =
    dict.insert(state.watched, pid, Watch(key, what, process.monitor(pid)))
  State(..state, watched:)
}

fn unwatch(state: State, pid: Pid) -> State {
  case dict.get(state.watched, pid) {
    Ok(watch) -> {
      process.demonitor_process(watch.monitor)
      State(..state, watched: dict.delete(state.watched, pid))
    }
    Error(Nil) -> state
  }
}

fn unwatch_control(state: State, control: Subject(Command)) -> State {
  case process.subject_owner(control) {
    Ok(pid) -> unwatch(state, pid)
    Error(Nil) -> state
  }
}

fn apply(
  state: State,
  changed: #(Endpoints(Subject(Command)), List(Effect(Subject(Command)))),
) -> actor.Next(State, Message) {
  let #(endpoints, effects) = changed
  let state = State(..state, endpoints:)
  effects
  |> list.fold(state, fn(state, effect) {
    case effect {
      endpoint.SendOpen(control, id) -> {
        process.send(control, protocol.SendOpen(id))
        state
      }
      endpoint.SendBye(control) -> {
        process.send(control, protocol.SendBye)
        state
      }
      endpoint.Supersede(control) -> {
        process.send(control, protocol.Superseded)
        unwatch_control(state, control)
      }
      endpoint.Retire(control) -> {
        process.send(control, protocol.Retire)
        unwatch_control(state, control)
      }
      endpoint.StopShim(listening) -> {
        let state = unwatch(state, shim.pid(listening))
        shim.stop(listening)
        state
      }
      endpoint.CleanupShim(key, listening) -> {
        sys.warn("crushling: tunnel " <> key <> ": shim stopped")
        shim.cleanup(listening)
        state
      }
      endpoint.Notify(change) -> {
        state.settings.on_change(change)
        state
      }
      endpoint.Hangup(events) -> {
        process.send(events, shim.Hangup)
        state
      }
      endpoint.Answer(waiter, result) -> {
        process.send(waiter, result)
        state
      }
    }
  })
  |> actor.continue
}

/// Serve one shim connection, in its own process.
fn connection(
  hub: Subject(Message),
  settings: Settings,
  key: String,
  socket: shim.Socket,
) -> Nil {
  shim.relay(
    socket,
    fn(events) {
      process.call(hub, 5000, Connect(key, socket, events, _))
      |> result.map(fn(ref) { fn() { process.send(hub, Abandon(key, ref)) } })
    },
    settings.data_timeout_ms,
  )
}
