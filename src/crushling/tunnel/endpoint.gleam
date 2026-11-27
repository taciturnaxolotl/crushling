//// Every thread's tunnel endpoint as pure state: its shim, its control
//// socket and generation, the hello waiters, and the shim connections
//// waiting for a data socket by registration ref and wire id. Each change
//// returns the effects it calls for; `tunnel/hub` carries them out.
////
//// Each control socket is a generation. When one goes or is replaced,
//// opens it never answered are reissued under fresh ids, so a late dial
//// for an old id is turned away rather than racing the new crush's dial.

import crushling/tunnel/shim
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// A change in whether a thread's crush is connected.
pub type Change {
  Dialed(key: String)
  Undialed(key: String)
}

/// A shim connection waiting for its data socket. `id` is its current wire
/// id, which changes when it is reissued; `sent` is the control generation
/// its open went out on, if it has.
pub type Pending {
  Pending(
    id: Int,
    socket: shim.Socket,
    events: Subject(shim.Event),
    sent: Option(Int),
    reserved: Bool,
  )
}

pub type Endpoint(control) {
  Endpoint(
    /// None if the listener died; `open` starts another.
    shim: Option(shim.Shim),
    control: Option(control),
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

pub type Endpoints(control) {
  Endpoints(
    endpoints: Dict(String, Endpoint(control)),
    next_id: Int,
    next_ref: Int,
  )
}

pub type Effect(control) {
  /// Ask crush to dial a data socket for wire `id`.
  SendOpen(control: control, id: Int)
  SendBye(control: control)
  /// A newer control socket took over: close this one.
  Supersede(control: control)
  /// Close this control socket.
  Retire(control: control)
  StopShim(shim: shim.Shim)
  /// The listener died: remove its socket file.
  CleanupShim(key: String, shim: shim.Shim)
  Notify(change: Change)
  Hangup(events: Subject(shim.Event))
  Answer(
    waiter: Subject(Result(String, String)),
    result: Result(String, String),
  )
}

pub fn new() -> Endpoints(control) {
  Endpoints(endpoints: dict.new(), next_id: 1, next_ref: 1)
}

fn get(
  state: Endpoints(control),
  key: String,
) -> Result(Endpoint(control), Nil) {
  dict.get(state.endpoints, key)
}

fn put(
  state: Endpoints(control),
  key: String,
  endpoint: Endpoint(control),
) -> Endpoints(control) {
  Endpoints(..state, endpoints: dict.insert(state.endpoints, key, endpoint))
}

/// The key's listening shim, if it has one.
pub fn listening(state: Endpoints(control), key: String) -> Option(shim.Shim) {
  case get(state, key) {
    Ok(Endpoint(shim: Some(listening), ..)) -> Some(listening)
    _ -> None
  }
}

/// The key now listens on `listening`.
pub fn opened(
  state: Endpoints(control),
  key: String,
  listening: shim.Shim,
) -> Endpoints(control) {
  let endpoint = case get(state, key) {
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
  put(state, key, endpoint)
}

pub fn close(
  state: Endpoints(control),
  key: String,
) -> #(Endpoints(control), List(Effect(control))) {
  case get(state, key) {
    Error(Nil) -> #(state, [])
    Ok(endpoint) -> {
      let effects =
        list.flatten([
          option.map(endpoint.shim, StopShim) |> option_list,
          option.map(endpoint.control, Retire) |> option_list,
          list.map(endpoint.waiters, Answer(_, Error("tunnel closed"))),
          dict.values(endpoint.pending)
            |> list.map(fn(pending) { Hangup(pending.events) }),
          undialed(endpoint, key),
        ])
      #(
        Endpoints(..state, endpoints: dict.delete(state.endpoints, key)),
        effects,
      )
    }
  }
}

fn undialed(endpoint: Endpoint(control), key: String) -> List(Effect(control)) {
  case endpoint.crush {
    Some(_) -> [Notify(Undialed(key))]
    None -> []
  }
}

pub fn await_hello(
  state: Endpoints(control),
  key: String,
  waiter: Subject(Result(String, String)),
) -> #(Endpoints(control), List(Effect(control))) {
  case get(state, key) {
    Error(Nil) -> #(state, [Answer(waiter, Error("no tunnel for " <> key))])
    Ok(Endpoint(control: Some(_), crush: Some(crush), ..)) -> #(state, [
      Answer(waiter, Ok(crush)),
    ])
    Ok(endpoint) -> #(
      put(
        state,
        key,
        Endpoint(..endpoint, waiters: [waiter, ..endpoint.waiters]),
      ),
      [],
    )
  }
}

pub fn forget_waiter(
  state: Endpoints(control),
  key: String,
  waiter: Subject(Result(String, String)),
) -> Endpoints(control) {
  case get(state, key) {
    Error(Nil) -> state
    Ok(endpoint) ->
      put(
        state,
        key,
        Endpoint(
          ..endpoint,
          waiters: list.filter(endpoint.waiters, fn(w) { w != waiter }),
        ),
      )
  }
}

pub fn bye(state: Endpoints(control), key: String) -> List(Effect(control)) {
  case get(state, key) {
    Ok(Endpoint(control: Some(control), ..)) -> [SendBye(control)]
    _ -> []
  }
}

/// Whether the key's crush is dialed in and has said hello.
pub fn dialed(state: Endpoints(control), key: String) -> Bool {
  get(state, key) |> result.map(is_dialed) |> result.unwrap(False)
}

pub fn knows(state: Endpoints(control), key: String) -> Bool {
  dict.has_key(state.endpoints, key)
}

/// The wire ids of connections still waiting, in order.
pub fn pending_ids(state: Endpoints(control), key: String) -> List(Int) {
  case get(state, key) {
    Ok(endpoint) -> dict.keys(endpoint.wires) |> list.sort(int.compare)
    Error(Nil) -> []
  }
}

fn is_dialed(endpoint: Endpoint(control)) -> Bool {
  option.is_some(endpoint.control) && option.is_some(endpoint.crush)
}

/// A shim connection arrived: it waits under a new ref and wire id.
pub fn connect(
  state: Endpoints(control),
  key: String,
  socket: shim.Socket,
  events: Subject(shim.Event),
) -> Result(#(Endpoints(control), Int, List(Effect(control))), Nil) {
  use endpoint <- result.map(get(state, key))
  let id = state.next_id
  let ref = state.next_ref
  let #(pending, effects) =
    send_open(
      endpoint,
      Pending(id:, socket:, events:, sent: None, reserved: False),
    )
  let endpoint =
    Endpoint(
      ..endpoint,
      pending: dict.insert(endpoint.pending, ref, pending),
      wires: dict.insert(endpoint.wires, id, ref),
    )
  #(
    Endpoints(
      ..put(state, key, endpoint),
      next_id: next_id(id),
      next_ref: ref + 1,
    ),
    ref,
    effects,
  )
}

/// The connection under `ref` is attached or gave up: forget it.
pub fn drop(
  state: Endpoints(control),
  key: String,
  ref: Int,
) -> Endpoints(control) {
  case get(state, key) {
    Error(Nil) -> state
    Ok(endpoint) -> {
      let wires = case dict.get(endpoint.pending, ref) {
        Ok(pending) -> dict.delete(endpoint.wires, pending.id)
        Error(Nil) -> endpoint.wires
      }
      let pending = dict.delete(endpoint.pending, ref)
      put(state, key, Endpoint(..endpoint, pending:, wires:))
    }
  }
}

/// Hold wire `id` for a data dial while its upgrade is answered.
pub fn reserve(
  state: Endpoints(control),
  key: String,
  id: Int,
) -> Result(#(Endpoints(control), Int, Pending), Nil) {
  use endpoint <- result.try(get(state, key))
  use ref <- result.try(dict.get(endpoint.wires, id))
  case dict.get(endpoint.pending, ref) {
    Ok(Pending(reserved: False, ..) as pending) -> {
      let held = Pending(..pending, reserved: True)
      let endpoint =
        Endpoint(..endpoint, pending: dict.insert(endpoint.pending, ref, held))
      Ok(#(put(state, key, endpoint), ref, pending))
    }
    _ -> Error(Nil)
  }
}

/// The upgrade failed: the connection may be dialed again.
pub fn release(
  state: Endpoints(control),
  key: String,
  ref: Int,
) -> #(Endpoints(control), List(Effect(control))) {
  case get(state, key) {
    Error(Nil) -> #(state, [])
    Ok(endpoint) ->
      case dict.get(endpoint.pending, ref) {
        Error(Nil) -> #(state, [])
        Ok(pending) -> {
          let pending = Pending(..pending, reserved: False)
          let endpoint =
            Endpoint(
              ..endpoint,
              pending: dict.insert(endpoint.pending, ref, pending),
            )
          // Released after its generation ended: reissue it now.
          reissued(state, key, endpoint)
        }
      }
  }
}

/// A control socket came up; Error if the key has no endpoint.
pub fn control_up(
  state: Endpoints(control),
  key: String,
  control: control,
) -> Result(#(Endpoints(control), List(Effect(control))), Nil) {
  use endpoint <- result.map(get(state, key))
  let before =
    list.append(
      option.map(endpoint.control, Supersede) |> option_list,
      undialed(endpoint, key),
    )
  let endpoint =
    Endpoint(
      ..endpoint,
      control: Some(control),
      generation: endpoint.generation + 1,
      crush: None,
    )
  let #(state, effects) = reissued(state, key, endpoint)
  #(state, list.append(before, effects))
}

pub fn hello(
  state: Endpoints(control),
  key: String,
  control: control,
  crush: String,
) -> #(Endpoints(control), List(Effect(control))) {
  case get(state, key) {
    Ok(Endpoint(control: Some(current), ..) as endpoint) if current == control -> {
      let answers = list.map(endpoint.waiters, Answer(_, Ok(crush)))
      let endpoint = Endpoint(..endpoint, crush: Some(crush), waiters: [])
      let #(pending, opens) =
        dict.fold(endpoint.pending, #(endpoint.pending, []), fn(acc, ref, p) {
          let #(pending, effects) = send_open(endpoint, p)
          #(dict.insert(acc.0, ref, pending), list.append(acc.1, effects))
        })
      #(
        put(state, key, Endpoint(..endpoint, pending:)),
        list.flatten([answers, opens, [Notify(Dialed(key))]]),
      )
    }
    _ -> #(state, [])
  }
}

pub fn control_down(
  state: Endpoints(control),
  key: String,
  control: control,
) -> #(Endpoints(control), List(Effect(control))) {
  case get(state, key) {
    Ok(Endpoint(control: Some(current), ..) as endpoint) if current == control -> {
      let before = undialed(endpoint, key)
      let endpoint =
        Endpoint(
          ..endpoint,
          control: None,
          generation: endpoint.generation + 1,
          crush: None,
        )
      let #(state, effects) = reissued(state, key, endpoint)
      #(state, list.append(before, effects))
    }
    _ -> #(state, [])
  }
}

/// The key's listener died; `open` starts another.
pub fn shim_down(
  state: Endpoints(control),
  key: String,
) -> #(Endpoints(control), List(Effect(control))) {
  case get(state, key) {
    Ok(Endpoint(shim: Some(listening), ..) as endpoint) -> #(
      put(state, key, Endpoint(..endpoint, shim: None)),
      [CleanupShim(key, listening)],
    )
    _ -> #(state, [])
  }
}

/// Send a pending connection's open if crush is listening and it hasn't
/// gone out on this generation.
fn send_open(
  endpoint: Endpoint(control),
  pending: Pending,
) -> #(Pending, List(Effect(control))) {
  case endpoint.control, is_dialed(endpoint), pending.sent {
    Some(control), True, None -> #(
      Pending(..pending, sent: Some(endpoint.generation)),
      [SendOpen(control, pending.id)],
    )
    _, _, _ -> #(pending, [])
  }
}

/// Store `endpoint`, giving every open sent on an earlier generation, and
/// not being dialed right now, a fresh id. The old ids are forgotten, so
/// dials for them get 404; the new ones are sent once the current control
/// socket says hello.
fn reissued(
  state: Endpoints(control),
  key: String,
  endpoint: Endpoint(control),
) -> #(Endpoints(control), List(Effect(control))) {
  let #(endpoint, next, effects) =
    dict.fold(endpoint.pending, #(endpoint, state.next_id, []), fn(acc, ref, p) {
      let #(endpoint, next, effects) = acc
      case p.sent, p.reserved {
        Some(generation), False if generation != endpoint.generation -> {
          let #(fresh, opens) =
            send_open(endpoint, Pending(..p, id: next, sent: None))
          let wires =
            dict.delete(endpoint.wires, p.id) |> dict.insert(next, ref)
          let pending = dict.insert(endpoint.pending, ref, fresh)
          #(
            Endpoint(..endpoint, pending:, wires:),
            next_id(next),
            list.append(effects, opens),
          )
        }
        _, _ -> acc
      }
    })
  #(Endpoints(..put(state, key, endpoint), next_id: next), effects)
}

/// Ids are u32s, and never 0.
fn next_id(id: Int) -> Int {
  case id >= 4_294_967_295 {
    True -> 1
    False -> id + 1
  }
}

fn option_list(value: Option(a)) -> List(a) {
  case value {
    Some(value) -> [value]
    None -> []
  }
}
