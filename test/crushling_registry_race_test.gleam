//// A thread's launch and stop never overlap, and shutdown never leaves a
//// sandbox running: checked with a launcher whose launch and stop block
//// until the test lets them finish.

import crushling/crush/client
import crushling/launcher
import crushling/registry
import crushling/registry/incoming as msg
import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}
import gleam/set
import slackline

@external(erlang, "crushling_ffi", "mkdir_p")
fn mkdir_p(path: String) -> Result(Nil, String)

const dir = "/tmp/crushling-registry-race-test"

/// What the launcher was asked to do, with a subject that lets the call
/// finish.
type Call {
  Launch(key: String, go: Subject(Nil))
  /// The test answers with the stop's result.
  Stop(key: String, go: Subject(Result(Nil, String)))
}

fn blocking_launcher(calls: Subject(Call)) -> launcher.Launcher {
  launcher.Launcher(
    launch: fn(key) {
      let go = process.new_subject()
      process.send(calls, Launch(key, go))
      let assert Ok(Nil) = process.receive(go, 10_000)
      // Nothing listens here: the thread actor starts and keeps retrying.
      Ok(launcher.Launched(socket: dir <> "/none.sock", root: dir))
    },
    stop: fn(key) {
      let go = process.new_subject()
      process.send(calls, Stop(key, go))
      let assert Ok(result) = process.receive(go, 10_000)
      result
    },
    exists: fn(_) { False },
    meta_path: fn(key) { dir <> "/" <> key <> ".json" },
    workspace: fn(key) { dir <> "/" <> key },
    attachments: fn(key) { #(dir <> "/" <> key, ".slack") },
    run_in_sandbox: None,
  )
}

fn start(calls: Subject(Call)) -> Subject(registry.Message) {
  start_with(calls, registry.default_stop_backoff_ms)
}

fn start_with(
  calls: Subject(Call),
  stop_backoff_ms: List(Int),
) -> Subject(registry.Message) {
  let assert Ok(Nil) = mkdir_p(dir)
  let assert Ok(client) =
    slackline.new("xoxb-test")
    |> slackline.with_base_url("http://127.0.0.1:1/api")
  let assert Ok(r) =
    registry.start(registry.Config(
      launcher: blocking_launcher(calls),
      client:,
      token: "xoxb-test",
      bot_user: "UBOT",
      team: "T1",
      allowed: set.from_list(["U1"]),
      idle_ms: 600_000,
      flush_ms: 50,
      mode: client.Sysadmin,
      tailnet: None,
      stop_backoff_ms:,
    ))
  r
}

fn message(thread_ts: String, ts: String, text: String, mention: Bool) {
  registry.Received(msg.Incoming("C1", thread_ts, ts, "U1", text, mention, []))
}

fn next(calls: Subject(Call)) -> Call {
  let assert Ok(call) = process.receive(calls, 5000)
  call
}

fn nothing(calls: Subject(Call)) -> Nil {
  let assert Error(Nil) = process.receive(calls, 300)
  Nil
}

/// A message that arrives while the agent is stopping waits for the stop,
/// then starts the agent again.
pub fn a_message_during_a_stop_waits_for_it_test() {
  let calls = process.new_subject()
  let r = start(calls)
  let key = registry.key("C1", "30.1")
  process.send(r, message("30.1", "30.1", "<@UBOT> hi", True))
  let assert Launch(launched, go) = next(calls)
  let assert True = launched == key
  process.send(go, Nil)
  // Up: kill its thread actor, and the registry stops the agent.
  let thread = wait_live(r, key, 50)
  let assert Ok(pid) = process.subject_owner(thread)
  process.kill(pid)
  let assert Stop(stopping, stop_go) = next(calls)
  let assert True = stopping == key
  // A reply while the stop is still running doesn't launch alongside it.
  process.send(r, message("30.1", "30.2", "carry on", False))
  nothing(calls)
  let assert None = process.call(r, 1000, registry.Lookup(key, _))
  process.send(stop_go, Ok(Nil))
  // Once it has stopped, the waiting message starts the agent again.
  let assert Launch(again, go) = next(calls)
  let assert True = again == key
  process.send(go, Nil)
  let _ = wait_live(r, key, 50)
  Nil
}

fn wait_live(
  r: Subject(registry.Message),
  key: String,
  tries: Int,
) -> Subject(_) {
  case process.call(r, 1000, registry.Lookup(key, _)), tries {
    Some(thread), _ -> thread
    None, 0 -> panic as "the agent never came up"
    None, _ -> {
      process.sleep(20)
      wait_live(r, key, tries - 1)
    }
  }
}

/// Shutdown during a launch waits for it, then stops what it started, and
/// only then reports done.
pub fn shutdown_during_a_launch_stops_what_it_starts_test() {
  let calls = process.new_subject()
  let r = start(calls)
  let key = registry.key("C1", "40.1")
  process.send(r, message("40.1", "40.1", "<@UBOT> hi", True))
  let assert Launch(_, launch_go) = next(calls)
  let done = process.new_subject()
  process.send(r, registry.Shutdown(1000, done))
  // Nothing is stopped while the launch is in flight: a stop now would run
  // before the container exists.
  nothing(calls)
  let assert Error(Nil) = process.receive(done, 0)
  process.send(launch_go, Nil)
  // The launch finished, so its agent is stopped.
  let assert Stop(stopped, stop_go) = next(calls)
  let assert True = stopped == key
  let assert Error(Nil) = process.receive(done, 200)
  process.send(stop_go, Ok(Nil))
  let assert Ok(registry.Clean) = process.receive(done, 5000)
  Nil
}

/// Bring a thread's agent up, then kill its thread actor so the registry
/// stops the agent. Returns the first stop call.
fn up_then_stopping(
  r: Subject(registry.Message),
  calls: Subject(Call),
  thread_ts: String,
) -> Call {
  let key = registry.key("C1", thread_ts)
  process.send(r, message(thread_ts, thread_ts, "<@UBOT> hi", True))
  let assert Launch(_, go) = next(calls)
  process.send(go, Nil)
  let thread = wait_live(r, key, 50)
  let assert Ok(pid) = process.subject_owner(thread)
  process.kill(pid)
  next(calls)
}

/// A stop that fails is retried after each backoff; a message that came in
/// meanwhile waits, and starts the agent once a retry succeeds.
pub fn a_failed_stop_is_retried_test() {
  let calls = process.new_subject()
  let r = start_with(calls, [10, 20, 30])
  let key = registry.key("C1", "50.1")
  let assert Stop(_, go) = up_then_stopping(r, calls, "50.1")
  process.send(r, message("50.1", "50.2", "carry on", False))
  process.send(go, Error("docker daemon is down"))
  let assert Stop(again, go) = next(calls)
  let assert True = again == key
  process.send(go, Error("docker daemon is down"))
  let assert Stop(_, go) = next(calls)
  // Still no launch while the stop is failing.
  let assert None = process.call(r, 1000, registry.Lookup(key, _))
  process.send(go, Ok(Nil))
  let assert Launch(relaunched, go) = next(calls)
  let assert True = relaunched == key
  process.send(go, Nil)
  let _ = wait_live(r, key, 50)
  Nil
}

/// A stop that never works is given up on after its retries, and shutdown
/// says it couldn't stop everything.
pub fn a_stop_that_always_fails_is_reported_test() {
  let calls = process.new_subject()
  let r = start_with(calls, [10, 20])
  let key = registry.key("C1", "60.1")
  let assert Stop(_, go) = up_then_stopping(r, calls, "60.1")
  process.send(go, Error("no"))
  let assert Stop(_, go) = next(calls)
  process.send(go, Error("no"))
  let assert Stop(_, go) = next(calls)
  process.send(go, Error("no"))
  // Three tries in all, then nothing more.
  nothing(calls)
  let done = process.new_subject()
  process.send(r, registry.Shutdown(1000, done))
  let assert Ok(registry.Incomplete([failed])) = process.receive(done, 5000)
  let assert True = failed == key
}

/// The caller's deadline covers every timer shutdown has.
pub fn shutdown_budget_covers_its_timers_test() {
  let assert True = registry.shutdown_budget_ms(60_000) > 60_000 + 130_000
  let assert True =
    registry.shutdown_budget_ms(0) == registry.shutdown_budget_ms(1000) - 1000
}
