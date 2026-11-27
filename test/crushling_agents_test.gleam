//// The lifecycle owner: one operation at a time per key, in order, and the
//// state each key is in meanwhile. A launcher whose calls block until the
//// test lets them go shows what overlaps and what waits.

import crushling/agents
import crushling/launcher
import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}
import gleam/otp/static_supervisor as supervisor

/// A launcher call, held until the test answers it.
type Call {
  Call(what: String, key: String, go: Subject(Result(Nil, String)))
}

fn blocking(calls: Subject(Call)) -> launcher.Launcher {
  let ask = fn(what, key) {
    let go = process.new_subject()
    process.send(calls, Call(what, key, go))
    let assert Ok(result) = process.receive(go, 5000)
    result
  }
  launcher.Launcher(
    launch: fn(key) {
      case ask("launch", key) {
        Ok(Nil) -> Ok(launcher.Launched(socket: "/tmp/none.sock", root: "/w"))
        Error(reason) -> Error(reason)
      }
    },
    stop: ask("stop", _),
    exists: fn(_) { False },
    rekey: fn(old, _) { ask("rekey", old) },
    forget: ask("forget", _),
    run_in_sandbox: None,
  )
}

fn next(calls: Subject(Call)) -> Call {
  let assert Ok(call) = process.receive(calls, 2000)
  call
}

fn nothing(calls: Subject(Call)) -> Nil {
  let assert Error(Nil) = process.receive(calls, 100)
  Nil
}

fn noted(results: Subject(#(String, Result(Nil, String))), what: String) {
  fn(result) { process.send(results, #(what, result)) }
}

fn attach_ok(_: launcher.Launched) -> Result(Nil, String) {
  Ok(Nil)
}

pub fn a_stop_waits_for_the_launch_before_it_test() {
  let calls = process.new_subject()
  let results = process.new_subject()
  let assert Ok(owner) = agents.start(blocking(calls))
  agents.launch(owner, "T1-C1-1.0", attach_ok, noted(results, "launch"))
  agents.stop(owner, "T1-C1-1.0", noted(results, "stop"))
  let assert Call("launch", "T1-C1-1.0", go) = next(calls)
  let assert agents.Starting = agents.status(owner, "T1-C1-1.0")
  let assert Some(epoch) = agents.epoch(owner, "T1-C1-1.0")
  // The stop doesn't start while the launch runs.
  nothing(calls)
  process.send(go, Ok(Nil))
  let assert Ok(#("launch", Ok(Nil))) = process.receive(results, 1000)
  let assert Call("stop", "T1-C1-1.0", go) = next(calls)
  let assert agents.Stopping = agents.status(owner, "T1-C1-1.0")
  // The epoch holds from the start until the stop is done.
  let assert True = agents.epoch(owner, "T1-C1-1.0") == Some(epoch)
  process.send(go, Ok(Nil))
  let assert Ok(#("stop", Ok(Nil))) = process.receive(results, 1000)
  let assert agents.Absent = agents.status(owner, "T1-C1-1.0")
  let assert None = agents.epoch(owner, "T1-C1-1.0")
}

pub fn other_keys_run_alongside_test() {
  let calls = process.new_subject()
  let assert Ok(owner) = agents.start(blocking(calls))
  agents.launch(owner, "T1-C1-1.0", attach_ok, fn(_) { Nil })
  agents.launch(owner, "T1-C2-1.0", attach_ok, fn(_) { Nil })
  let assert Call("launch", _, first) = next(calls)
  let assert Call("launch", _, second) = next(calls)
  process.send(first, Ok(Nil))
  process.send(second, Ok(Nil))
}

pub fn each_launch_gets_a_later_generation_test() {
  let calls = process.new_subject()
  let results = process.new_subject()
  let assert Ok(owner) = agents.start(blocking(calls))
  let up = fn(key) {
    agents.launch(owner, key, attach_ok, noted(results, key))
    let assert Call("launch", _, go) = next(calls)
    process.send(go, Ok(Nil))
    let assert Ok(_) = process.receive(results, 1000)
    agents.status(owner, key)
  }
  let assert agents.Live(generation: first, since_ms:) = up("T1-C1-1.0")
  let assert True = since_ms > 0
  let assert agents.Live(generation: second, ..) = up("T1-C2-1.0")
  let assert True = second > first
}

pub fn a_failed_attach_stops_the_agent_test() {
  let calls = process.new_subject()
  let results = process.new_subject()
  let assert Ok(owner) = agents.start(blocking(calls))
  agents.launch(
    owner,
    "T1-C1-1.0",
    fn(_) { Error("thread: boom") },
    noted(results, "launch"),
  )
  let assert Call("launch", _, go) = next(calls)
  process.send(go, Ok(Nil))
  let assert Call("stop", _, go) = next(calls)
  process.send(go, Ok(Nil))
  let assert Ok(#("launch", Error("thread: boom"))) =
    process.receive(results, 1000)
  let assert agents.Absent = agents.status(owner, "T1-C1-1.0")
}

pub fn a_failed_stop_leaves_it_live_for_a_retry_test() {
  let calls = process.new_subject()
  let results = process.new_subject()
  let assert Ok(owner) = agents.start(blocking(calls))
  agents.launch(owner, "T1-C1-1.0", attach_ok, fn(_) { Nil })
  let assert Call("launch", _, go) = next(calls)
  process.send(go, Ok(Nil))
  agents.stop(owner, "T1-C1-1.0", noted(results, "stop"))
  let assert Call("stop", _, go) = next(calls)
  process.send(go, Error("docker is unreachable"))
  let assert Ok(#("stop", Error(_))) = process.receive(results, 1000)
  let assert agents.Live(..) = agents.status(owner, "T1-C1-1.0")
  // Nothing forgets a live agent.
  agents.forget(owner, "T1-C1-1.0", noted(results, "forget"))
  let assert Ok(#("forget", Error("its agent is running"))) =
    process.receive(results, 1000)
  nothing(calls)
}

/// The sweep's forget can't race a launch the registry asked for after it.
pub fn a_launch_after_a_forget_waits_for_it_test() {
  let calls = process.new_subject()
  let assert Ok(owner) = agents.start(blocking(calls))
  agents.forget(owner, "T1-C1-1.0", fn(_) { Nil })
  agents.launch(owner, "T1-C1-1.0", attach_ok, fn(_) { Nil })
  let assert Call("forget", _, go) = next(calls)
  let assert agents.Forgetting = agents.status(owner, "T1-C1-1.0")
  nothing(calls)
  process.send(go, Ok(Nil))
  let assert Call("launch", _, go) = next(calls)
  process.send(go, Ok(Nil))
}

/// A thread moving to a new key holds it, so nothing launches there until
/// the move is done.
pub fn a_rekey_holds_the_new_key_test() {
  let calls = process.new_subject()
  let assert Ok(owner) = agents.start(blocking(calls))
  let moved = process.new_subject()
  process.spawn(fn() {
    process.send(moved, agents.rekey(owner, "C1-1.0", "T1-C1-1.0"))
  })
  let assert Call("rekey", "C1-1.0", go) = next(calls)
  agents.launch(owner, "T1-C1-1.0", attach_ok, fn(_) { Nil })
  nothing(calls)
  process.send(go, Ok(Nil))
  let assert Ok(Ok(Nil)) = process.receive(moved, 1000)
  let assert Call("launch", "T1-C1-1.0", go) = next(calls)
  process.send(go, Ok(Nil))
}

/// A restarted registry knows none of its agents: they are stopped, and
/// only its own workspace's.
pub fn a_reset_stops_only_that_workspace_test() {
  let calls = process.new_subject()
  let assert Ok(owner) = agents.start(blocking(calls))
  let up = fn(key) {
    agents.launch(owner, key, attach_ok, fn(_) { Nil })
    let assert Call("launch", _, go) = next(calls)
    process.send(go, Ok(Nil))
  }
  up("T1-C1-1.0")
  up("T2-C1-1.0")
  let _ = agents.status(owner, "T1-C1-1.0")
  agents.reset(owner, "T1")
  let assert Call("stop", "T1-C1-1.0", go) = next(calls)
  process.send(go, Ok(Nil))
  nothing(calls)
  let assert agents.Live(..) = agents.status(owner, "T2-C1-1.0")
}

/// Sandboxes a previous bridge left running are stopped at start.
pub fn strays_are_stopped_at_start_test() {
  let calls = process.new_subject()
  let name = process.new_name("agents_test")
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(agents.supervised(
      blocking(calls),
      fn() { Ok(["T1-C9-1.0"]) },
      name,
    ))
    |> supervisor.start
  let assert Call("stop", "T1-C9-1.0", go) = next(calls)
  process.send(go, Ok(Nil))
  let owner = agents.named(blocking(calls), name)
  let _ = agents.status(owner, "T1-C9-1.0")
  let assert agents.Absent = agents.status(owner, "T1-C9-1.0")
}
