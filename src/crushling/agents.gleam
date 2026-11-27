//// The one owner of every thread's agent lifecycle. A thread's key is
//// always in one state, `Absent | Starting | Live | Stopping | Forgetting`,
//// and its launches, stops, forgets and rekeys run one at a time, in the
//// order they were asked for; what arrives while one runs waits its turn.
//// Each operation runs on an unlinked worker the actor monitors, so the
//// actor never blocks and a worker that crashes (a timed-out call, say)
//// only fails its own operation: the key's queue goes on, and the rest of
//// the bridge never notices. A launch that crashed is stopped again, as it
//// may have got partway up.
////
//// At start, sandboxes a previous bridge left running are stopped rather
//// than adopted: no registry knows their threads, and the next message
//// starts them again, warm.
////
//// Callers hear back through the callbacks they pass, which run on this
//// actor and so must only send messages.

import crushling/key as thread_key
import crushling/launcher.{type Launched, type Launcher}
import crushling/sys
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string

/// Where a thread's agent is in its lifecycle.
pub type Status {
  Absent
  Starting
  /// Up since `since_ms` (system time); `generation` numbers each launch
  /// the bridge made, so a later one is always larger.
  Live(generation: Int, since_ms: Int)
  Stopping
  Forgetting
}

pub opaque type Agents {
  Agents(subject: Subject(Message), launcher: Launcher)
}

type Done =
  fn(Result(Nil, String)) -> Nil

type Op {
  /// `attach` runs on the worker once the agent is up; if it fails, the
  /// agent is stopped again, since nothing would drive it.
  Launch(done: Done, attach: fn(Launched) -> Result(Nil, String))
  Stop(done: Done)
  Forget(done: Done)
  Rekey(done: Done, new: String)
}

pub opaque type Message {
  Request(key: String, op: Op)
  Reset(team: String)
  GetStatus(key: String, reply: Subject(Status))
  GetEpoch(key: String, reply: Subject(Option(Int)))
  Reconcile
  Finished(key: String, worker: Pid, outcome: Outcome)
  WorkerDown(worker: Pid, reason: process.ExitReason)
}

type Outcome {
  Launched(Result(Launched, String))
  Stopped(Result(Nil, String))
  Forgot(Result(Nil, String))
}

type Up {
  Up(generation: Int, since_ms: Int, launched: Option(Launched))
}

type Slot {
  Slot(
    status: Status,
    /// The agent while it is up, kept through a stop that fails.
    up: Option(Up),
    /// The operation running, if any.
    running: Option(Op),
    queue: List(Op),
    /// When the agent's current start began (system ms), from then until
    /// it is stopped: what its per-start tokens are bound to.
    epoch: Option(Int),
  )
}

const idle =
  Slot(status: Absent, up: None, running: None, queue: [], epoch: None)

type State {
  State(
    self: Subject(Message),
    launcher: Launcher,
    stray: fn() -> Result(List(String), String),
    slots: Dict(String, Slot),
    generation: Int,
    /// Each running worker's key and the status it runs under.
    workers: Dict(Pid, #(String, Status)),
  )
}

/// The owner, linked to the caller, with nothing to reconcile at start.
pub fn start(launcher: Launcher) -> Result(Agents, String) {
  start_with(launcher, fn() { Ok([]) }, None)
  |> result.map(fn(started) { Agents(started.data, launcher) })
  |> result.map_error(fn(error) { "agents: " <> string.inspect(error) })
}

/// The owner as a supervised child registered under `name`; reach it with
/// `named`. `stray` lists the agents still running, to stop at start.
pub fn supervised(
  launcher: Launcher,
  stray: fn() -> Result(List(String), String),
  name: process.Name(Message),
) -> supervision.ChildSpecification(Subject(Message)) {
  supervision.worker(fn() { start_with(launcher, stray, Some(name)) })
}

/// The owner registered under `name`.
pub fn named(launcher: Launcher, name: process.Name(Message)) -> Agents {
  Agents(process.named_subject(name), launcher)
}

fn start_with(
  launcher: Launcher,
  stray: fn() -> Result(List(String), String),
  name: Option(process.Name(Message)),
) -> actor.StartResult(Subject(Message)) {
  let builder =
    actor.new_with_initialiser(1000, fn(self) {
      process.send(self, Reconcile)
      let selector =
        process.new_selector()
        |> process.select(self)
        |> process.select_monitors(fn(down) {
          case down {
            process.ProcessDown(pid:, reason:, ..) -> WorkerDown(pid, reason)
            // Only processes are monitored.
            process.PortDown(reason:, ..) -> WorkerDown(process.self(), reason)
          }
        })
      State(
        self:,
        launcher:,
        stray:,
        slots: dict.new(),
        generation: 0,
        workers: dict.new(),
      )
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

/// Launch thread `key`'s agent and run `attach` with it; `done` hears how
/// it went. Already up, it is attached again as it is.
pub fn launch(
  agents: Agents,
  key: String,
  attach: fn(Launched) -> Result(Nil, String),
  done: Done,
) -> Nil {
  process.send(agents.subject, Request(key, Launch(done, attach)))
}

/// Stop thread `key`'s agent, keeping its workspace. Nothing up is fine.
pub fn stop(agents: Agents, key: String, done: Done) -> Nil {
  process.send(agents.subject, Request(key, Stop(done)))
}

/// Remove a stopped thread's sandbox and workspace for good.
pub fn forget(agents: Agents, key: String, done: Done) -> Nil {
  process.send(agents.subject, Request(key, Forget(done)))
}

/// Move a stopped thread from `old` to `new`, waiting for it.
pub fn rekey(agents: Agents, old: String, new: String) -> Result(Nil, String) {
  let reply = process.new_subject()
  process.send(
    agents.subject,
    Request(old, Rekey(fn(result) { process.send(reply, result) }, new)),
  )
  process.receive(reply, 120_000)
  |> result.unwrap(Error("moving " <> old <> " took too long"))
}

/// A workspace's registry started afresh and knows none of its agents:
/// stop every one of them, after whatever is running for them.
pub fn reset(agents: Agents, team: String) -> Nil {
  process.send(agents.subject, Reset(team))
}

pub fn status(agents: Agents, key: String) -> Status {
  process.call(agents.subject, 5000, GetStatus(key, _))
}

/// When the agent's current start began, while it is starting or up: it
/// changes on each start, so tokens bound to it die with the sandbox.
pub fn epoch(agents: Agents, key: String) -> Option(Int) {
  process.call(agents.subject, 5000, GetEpoch(key, _))
}

/// The launcher the owner runs.
pub fn launcher(agents: Agents) -> Launcher {
  agents.launcher
}

/// Whether the thread has a workspace, so it was started before.
pub fn exists(agents: Agents, key: String) -> Bool {
  agents.launcher.exists(key)
}

/// Run a script in a thread's sandbox, if agents have one.
pub fn run_in_sandbox(
  agents: Agents,
) -> Option(fn(String, List(String), String) -> Result(String, String)) {
  agents.launcher.run_in_sandbox
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Request(key, op) -> actor.continue(enqueue(state, key, op))
    GetStatus(key, reply) -> {
      process.send(reply, slot(state, key).status)
      actor.continue(state)
    }
    GetEpoch(key, reply) -> {
      process.send(reply, slot(state, key).epoch)
      actor.continue(state)
    }
    Reset(team) -> actor.continue(reset_team(state, team))
    Reconcile ->
      case state.stray() {
        Error(reason) -> {
          sys.warn("crushling: listing leftover sandboxes: " <> reason)
          actor.continue(state)
        }
        Ok(keys) ->
          list.fold(keys, state, fn(state, key) {
            sys.info("crushling: stopping " <> key <> ", left running")
            let up =
              Up(generation: 0, since_ms: sys.system_ms(), launched: None)
            let state =
              put(
                state,
                key,
                Slot(..slot(state, key), status: live(up), up: Some(up)),
              )
            enqueue(state, key, Stop(fn(_) { Nil }))
          })
          |> actor.continue
      }
    Finished(key, worker, outcome) ->
      State(..state, workers: dict.delete(state.workers, worker))
      |> finished(key, outcome)
      |> actor.continue
    WorkerDown(worker, reason) ->
      case dict.get(state.workers, worker) {
        // It finished first, and said so.
        Error(Nil) -> actor.continue(state)
        Ok(#(key, status)) ->
          State(..state, workers: dict.delete(state.workers, worker))
          |> crashed(key, status, reason)
          |> actor.continue
      }
  }
}

fn slot(state: State, key: String) -> Slot {
  dict.get(state.slots, key) |> result.unwrap(idle)
}

fn put(state: State, key: String, slot: Slot) -> State {
  case slot {
    Slot(status: Absent, running: None, queue: [], ..) ->
      State(..state, slots: dict.delete(state.slots, key))
    _ -> State(..state, slots: dict.insert(state.slots, key, slot))
  }
}

fn live(up: Up) -> Status {
  Live(generation: up.generation, since_ms: up.since_ms)
}

fn enqueue(state: State, key: String, op: Op) -> State {
  let current = slot(state, key)
  put(state, key, Slot(..current, queue: list.append(current.queue, [op])))
  |> next(key)
}

/// Run the next waiting operation for `key`, if nothing is running.
fn next(state: State, key: String) -> State {
  case slot(state, key) {
    Slot(running: Some(_), ..) | Slot(queue: [], ..) -> state
    Slot(queue: [op, ..rest], ..) as current -> {
      let current = Slot(..current, queue: rest)
      case run(state, key, current, op) {
        // Answered at once: go on with the rest.
        #(state, None) -> next(state, key)
        #(state, Some(_)) -> state
      }
    }
  }
}

/// Start `op` on a worker, or answer it at once (None).
fn run(
  state: State,
  key: String,
  current: Slot,
  op: Op,
) -> #(State, Option(Nil)) {
  let launcher = state.launcher
  let self = state.self
  let busy = fn(state: State, status: Status, work: fn() -> Outcome) {
    // `current` has the op taken off its queue; the epoch may be new.
    let epoch = case status {
      Starting if current.up == None -> Some(sys.system_ms())
      _ -> current.epoch
    }
    let worker =
      process.spawn_unlinked(fn() {
        process.send(self, Finished(key, process.self(), work()))
      })
    process.monitor(worker)
    let workers = dict.insert(state.workers, worker, #(key, status))
    #(
      put(
        State(..state, workers:),
        key,
        Slot(..current, status:, running: Some(op), epoch:),
      ),
      Some(Nil),
    )
  }
  let answer = fn(result) {
    op.done(result)
    #(put(state, key, current), None)
  }
  case op, current.up {
    Launch(attach:, ..), None ->
      busy(state, Starting, fn() {
        Launched({
          use launched <- result.try(launcher.launch(key))
          attached(launcher, key, launched, attach)
        })
      })
    Launch(attach:, ..), Some(Up(launched: Some(launched), ..)) ->
      busy(state, Starting, fn() {
        Launched(attached(launcher, key, launched, attach))
      })
    // Up but never attached (left over): stop it, then launch afresh.
    // The stop runs as its own op, so the launch's `done` hears only once.
    Launch(..), Some(Up(launched: None, ..)) ->
      run(
        state,
        key,
        Slot(..current, queue: [op, ..current.queue]),
        Stop(fn(_) { Nil }),
      )
    Stop(..), None -> answer(Ok(Nil))
    Stop(..), Some(_) ->
      busy(state, Stopping, fn() { Stopped(launcher.stop(key)) })
    Forget(..), Some(_) | Rekey(..), Some(_) ->
      answer(Error("its agent is running"))
    Forget(..), None ->
      busy(state, Forgetting, fn() { Forgot(launcher.forget(key)) })
    Rekey(new:, ..), None ->
      case slot(state, new) {
        Slot(status: Absent, running: None, ..) as target ->
          // Held while it moves, so nothing launches under it meanwhile.
          put(state, new, Slot(..target, status: Forgetting, running: Some(op)))
          |> busy(Forgetting, fn() { Forgot(launcher.rekey(key, new)) })
        _ -> answer(Error(new <> " is in use"))
      }
  }
}

/// Run `attach`; if it fails, stop the agent again.
fn attached(
  launcher: Launcher,
  key: String,
  launched: Launched,
  attach: fn(Launched) -> Result(Nil, String),
) -> Result(Launched, String) {
  case attach(launched) {
    Ok(Nil) -> Ok(launched)
    Error(reason) ->
      case launcher.stop(key) {
        Ok(Nil) -> Error(reason)
        Error(cleanup) -> {
          sys.warn("crushling: cleaning up " <> key <> ": " <> cleanup)
          Error(reason <> " (cleanup failed: " <> cleanup <> ")")
        }
      }
  }
}

fn finished(state: State, key: String, outcome: Outcome) -> State {
  let current = slot(state, key)
  let op = current.running
  let reply = fn(result) { option.map(op, fn(op) { op.done(result) }) }
  let current = Slot(..current, running: None)
  let state = case outcome {
    Launched(Ok(launched)) -> {
      let generation = state.generation + 1
      let up =
        Up(generation:, since_ms: sys.system_ms(), launched: Some(launched))
      reply(Ok(Nil))
      State(
        ..put(state, key, Slot(..current, status: live(up), up: Some(up))),
        generation:,
      )
    }
    Launched(Error(reason)) -> {
      reply(Error(reason))
      put(state, key, Slot(..current, status: Absent, up: None, epoch: None))
    }
    Stopped(Ok(Nil)) -> {
      reply(Ok(Nil))
      put(state, key, Slot(..current, status: Absent, up: None, epoch: None))
    }
    // It may still be up: a retry stops it, and nothing forgets it.
    Stopped(Error(reason)) -> {
      reply(Error(reason))
      let status = case current.up {
        Some(up) -> live(up)
        None -> Absent
      }
      put(state, key, Slot(..current, status:))
    }
    Forgot(result) -> {
      reply(result)
      let state =
        put(state, key, Slot(..current, status: Absent, up: None, epoch: None))
      case op {
        Some(Rekey(new:, ..)) ->
          put(
            state,
            new,
            Slot(..slot(state, new), status: Absent, running: None),
          )
          |> next(new)
        _ -> state
      }
    }
  }
  next(state, key)
}

/// A worker died before it answered: its operation failed.
fn crashed(
  state: State,
  key: String,
  status: Status,
  reason: process.ExitReason,
) -> State {
  let why = "crashed: " <> string.inspect(reason)
  sys.warn("crushling: " <> key <> " " <> why)
  case status {
    Starting -> {
      let current = slot(state, key)
      option.map(current.running, fn(op) { op.done(Error(why)) })
      // It may be partway up: stop it before anything else runs for it.
      let up = Up(generation: 0, since_ms: sys.system_ms(), launched: None)
      put(
        state,
        key,
        Slot(..current, status: live(up), up: Some(up), running: None, queue: [
          Stop(fn(_) { Nil }),
          ..current.queue
        ]),
      )
      |> next(key)
    }
    Stopping -> finished(state, key, Stopped(Error(why)))
    _ -> finished(state, key, Forgot(Error(why)))
  }
}

fn reset_team(state: State, team: String) -> State {
  dict.fold(state.slots, state, fn(state, key, current) {
    let ours = case thread_key.parse(key) {
      Ok(parsed) -> thread_key.team(parsed) == team
      Error(Nil) -> False
    }
    case ours {
      False -> state
      True -> {
        // Launches the old registry asked for have nobody to hand them to.
        let #(launches, rest) =
          list.partition(current.queue, fn(op) {
            case op {
              Launch(..) -> True
              _ -> False
            }
          })
        list.each(launches, fn(op) {
          case op {
            Launch(done:, ..) -> done(Error("the workspace restarted"))
            _ -> Nil
          }
        })
        put(state, key, Slot(..current, queue: rest))
        |> enqueue(key, Stop(fn(_) { Nil }))
      }
    }
  })
}
