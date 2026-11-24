//// The inference proxy's bookkeeping: what each thread has spent, the caps
//// it is held to, which threads are cut off, and which requests are in
//// flight. One actor holds it all, so admission is atomic and a revocation
//// or a cap takes effect on the very next request or chunk.
////
//// Spend is counted in tokens (prompt plus completion) and in US dollars, as
//// Hyper reports both in every response's `usage`. A cap may set either or
//// both; a thread is over its cap once it reaches any limit that is set.
////
//// These are soft limits held by one process:
////
//// - totals, revocations and per-thread overrides live in memory and reset
////   when the bridge restarts (`drain` hands what was spent to something
////   that keeps it);
//// - usage is only known when a response finishes, so requests already in
////   flight when a cap is reached can overshoot it, each by at most its own
////   cost (and a thread has at most `max_per_thread` in flight).

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}

/// What was spent: by one response, one thread, or the whole instance.
pub type Usage {
  Usage(input_tokens: Int, output_tokens: Int, cost_usd: Float, requests: Int)
}

pub const zero = Usage(0, 0, 0.0, 0)

pub fn add(a: Usage, b: Usage) -> Usage {
  Usage(
    input_tokens: a.input_tokens + b.input_tokens,
    output_tokens: a.output_tokens + b.output_tokens,
    cost_usd: a.cost_usd +. b.cost_usd,
    requests: a.requests + b.requests,
  )
}

pub fn tokens(usage: Usage) -> Int {
  usage.input_tokens + usage.output_tokens
}

/// A spending limit. `None` in a field means no limit on that measure.
pub type Cap {
  Cap(tokens: Option(Int), usd: Option(Float))
}

pub const unlimited = Cap(None, None)

pub fn reached(usage: Usage, cap: Cap) -> Bool {
  let over_tokens = case cap.tokens {
    Some(limit) -> tokens(usage) >= limit
    None -> False
  }
  let over_usd = case cap.usd {
    Some(limit) -> usage.cost_usd >=. limit
    None -> False
  }
  over_tokens || over_usd
}

/// How much may happen at once.
pub type Limits {
  Limits(
    thread_cap: Cap,
    instance_cap: Cap,
    /// Requests one thread may have in flight.
    max_per_thread: Int,
    /// Request bodies being read at once, across every thread.
    max_uploads: Int,
  )
}

/// Why a thread may not spend.
pub type Denial {
  Revoked
  ThreadCap
  InstanceCap
  /// The thread already has `max_per_thread` requests in flight.
  ThreadBusy
  /// `max_uploads` request bodies are already being read.
  InstanceBusy
}

pub type Message {
  Admit(key: String, owner: Pid, reply: Subject(Result(Nil, Denial)))
  Uploaded(owner: Pid)
  Check(key: String, reply: Subject(Result(Nil, Denial)))
  Record(key: String, usage: Usage, reply: Subject(Nil))
  Revoke(key: String)
  Restore(key: String)
  SetThreadCap(key: String, cap: Option(Cap))
  Totals(key: String, reply: Subject(Usage))
  InstanceTotals(reply: Subject(Usage))
  AllTotals(reply: Subject(List(#(String, Usage))))
  Drain(reply: Subject(List(#(String, Usage))))
  OwnerDown(owner: Pid)
}

/// An admitted request, held until its owner exits.
type Admission {
  Admission(key: String, uploading: Bool, monitor: process.Monitor)
}

type State {
  State(
    limits: Limits,
    usage: Dict(String, Usage),
    /// What was recorded since the last `drain`, by thread.
    undrained: Dict(String, Usage),
    instance: Usage,
    revoked: Set(String),
    overrides: Dict(String, Cap),
    admitted: Dict(Pid, Admission),
  )
}

pub fn start(limits: Limits) -> Result(Subject(Message), actor.StartError) {
  actor.new_with_initialiser(1000, fn(self) {
    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select_monitors(fn(down) {
        case down {
          process.ProcessDown(pid:, ..) -> OwnerDown(pid)
          // Only processes are monitored.
          process.PortDown(..) -> OwnerDown(process.self())
        }
      })
    State(
      limits:,
      usage: dict.new(),
      undrained: dict.new(),
      instance: zero,
      revoked: set.new(),
      overrides: dict.new(),
      admitted: dict.new(),
    )
    |> actor.initialised
    |> actor.selecting(selector)
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Admit(key, owner, reply) -> {
      let in_flight =
        dict.fold(state.admitted, 0, fn(n, _, admission) {
          case admission.key == key {
            True -> n + 1
            False -> n
          }
        })
      let uploads =
        dict.fold(state.admitted, 0, fn(n, _, admission) {
          case admission.uploading {
            True -> n + 1
            False -> n
          }
        })
      let verdict = case check(state, key) {
        Error(denial) -> Error(denial)
        Ok(Nil) if in_flight >= state.limits.max_per_thread -> Error(ThreadBusy)
        Ok(Nil) if uploads >= state.limits.max_uploads -> Error(InstanceBusy)
        Ok(Nil) -> Ok(Nil)
      }
      process.send(reply, verdict)
      case verdict, dict.has_key(state.admitted, owner) {
        Ok(Nil), False -> {
          let admission = Admission(key, True, process.monitor(owner))
          actor.continue(
            State(
              ..state,
              admitted: dict.insert(state.admitted, owner, admission),
            ),
          )
        }
        _, _ -> actor.continue(state)
      }
    }
    Uploaded(owner) ->
      case dict.get(state.admitted, owner) {
        Ok(admission) ->
          actor.continue(
            State(
              ..state,
              admitted: dict.insert(
                state.admitted,
                owner,
                Admission(..admission, uploading: False),
              ),
            ),
          )
        Error(Nil) -> actor.continue(state)
      }
    OwnerDown(owner) ->
      actor.continue(
        State(..state, admitted: dict.delete(state.admitted, owner)),
      )
    Check(key, reply) -> {
      process.send(reply, check(state, key))
      actor.continue(state)
    }
    Record(key, usage, reply) -> {
      let thread = dict.get(state.usage, key) |> result.unwrap(zero)
      let undrained = dict.get(state.undrained, key) |> result.unwrap(zero)
      process.send(reply, Nil)
      actor.continue(
        State(
          ..state,
          usage: dict.insert(state.usage, key, add(thread, usage)),
          undrained: dict.insert(state.undrained, key, add(undrained, usage)),
          instance: add(state.instance, usage),
        ),
      )
    }
    Revoke(key) ->
      actor.continue(State(..state, revoked: set.insert(state.revoked, key)))
    Restore(key) ->
      actor.continue(State(..state, revoked: set.delete(state.revoked, key)))
    SetThreadCap(key, Some(cap)) ->
      actor.continue(
        State(..state, overrides: dict.insert(state.overrides, key, cap)),
      )
    SetThreadCap(key, None) ->
      actor.continue(
        State(..state, overrides: dict.delete(state.overrides, key)),
      )
    Totals(key, reply) -> {
      process.send(reply, dict.get(state.usage, key) |> result.unwrap(zero))
      actor.continue(state)
    }
    InstanceTotals(reply) -> {
      process.send(reply, state.instance)
      actor.continue(state)
    }
    AllTotals(reply) -> {
      process.send(reply, dict.to_list(state.usage))
      actor.continue(state)
    }
    Drain(reply) -> {
      process.send(reply, dict.to_list(state.undrained))
      actor.continue(State(..state, undrained: dict.new()))
    }
  }
}

/// Revocation and caps, without the in-flight limits.
fn check(state: State, key: String) -> Result(Nil, Denial) {
  let thread = dict.get(state.usage, key) |> result.unwrap(zero)
  let cap =
    dict.get(state.overrides, key) |> result.unwrap(state.limits.thread_cap)
  case
    set.contains(state.revoked, key),
    reached(thread, cap),
    reached(state.instance, state.limits.instance_cap)
  {
    True, _, _ -> Error(Revoked)
    _, True, _ -> Error(ThreadCap)
    _, _, True -> Error(InstanceCap)
    False, False, False -> Ok(Nil)
  }
}

const timeout = 5000

/// Admit a request for `key`, held by `owner` until it exits. The request
/// counts as an upload until `uploaded`.
pub fn admit(
  meter: Subject(Message),
  key: String,
  owner: Pid,
) -> Result(Nil, Denial) {
  process.call(meter, timeout, Admit(key, owner, _))
}

/// `owner` has finished reading its request body.
pub fn uploaded(meter: Subject(Message), owner: Pid) -> Nil {
  process.send(meter, Uploaded(owner))
}

/// Whether `key` may keep spending: not revoked and under its caps.
pub fn check_key(meter: Subject(Message), key: String) -> Result(Nil, Denial) {
  process.call(meter, timeout, Check(key, _))
}

/// Add a response's usage to `key`'s and the instance's totals.
pub fn record(meter: Subject(Message), key: String, usage: Usage) -> Nil {
  process.call(meter, timeout, Record(key, usage, _))
}

pub fn revoke(meter: Subject(Message), key: String) -> Nil {
  process.send(meter, Revoke(key))
}

pub fn restore(meter: Subject(Message), key: String) -> Nil {
  process.send(meter, Restore(key))
}

/// Hold `key` to `cap` instead of the default thread cap, or back to the
/// default with `None`.
pub fn set_thread_cap(
  meter: Subject(Message),
  key: String,
  cap: Option(Cap),
) -> Nil {
  process.send(meter, SetThreadCap(key, cap))
}

pub fn totals(meter: Subject(Message), key: String) -> Usage {
  process.call(meter, timeout, Totals(key, _))
}

pub fn instance_totals(meter: Subject(Message)) -> Usage {
  process.call(meter, timeout, InstanceTotals)
}

pub fn all_totals(meter: Subject(Message)) -> List(#(String, Usage)) {
  process.call(meter, timeout, AllTotals)
}

/// What each thread spent since the last drain, emptied as it is taken.
pub fn drain(meter: Subject(Message)) -> List(#(String, Usage)) {
  process.call(meter, timeout, Drain)
}
