//// Shutting a registry down: drain running turns, cancel what's left, stop
//// every agent, then say how it went.

import crushling/sys
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// How shutdown went.
pub type ShutdownOutcome {
  /// Every agent was stopped.
  Clean
  /// Launches or stops were still in flight when the time ran out.
  TimedOut
  /// The launcher couldn't stop these threads' agents.
  Incomplete(failed: List(String))
}

pub type Lifecycle {
  Serving
  /// Running turns get the grace period to finish; `reply` hears the outcome.
  Draining(reply: Subject(ShutdownOutcome))
  /// Every agent is being stopped; done once no thread is left.
  Finishing(reply: Subject(ShutdownOutcome))
}

/// After cancelling, how long turns get to post their closing note.
pub const cancel_wait_ms = 10_000

/// Waits for launches and stops in flight, retries included.
pub const give_up_ms = 120_000

/// Slack for the caller on top of the registry's own timers.
const margin_ms = 5000

/// The longest a shutdown with `grace_ms` takes to reply; the caller waits no longer.
pub fn budget_ms(grace_ms: Int) -> Int {
  grace_ms + cancel_wait_ms + give_up_ms + margin_ms
}

pub fn is_serving(lifecycle: Lifecycle) -> Bool {
  lifecycle == Serving
}

pub fn is_finishing(lifecycle: Lifecycle) -> Bool {
  case lifecycle {
    Finishing(..) -> True
    Serving | Draining(..) -> False
  }
}

/// Move on to stopping every agent: the new lifecycle, the first time only.
pub fn finish(lifecycle: Lifecycle) -> Option(Lifecycle) {
  case lifecycle {
    Draining(reply) -> Some(Finishing(reply))
    Serving | Finishing(..) -> None
  }
}

/// How shutdown went once it is finishing and no thread is left.
pub fn outcome(
  lifecycle: Lifecycle,
  threads_left: Bool,
  abandoned: List(String),
) -> Option(ShutdownOutcome) {
  case lifecycle, threads_left, abandoned {
    Finishing(..), False, [] -> Some(Clean)
    Finishing(..), False, failed -> Some(Incomplete(list.unique(failed)))
    _, _, _ -> None
  }
}

/// Log the outcome and tell whoever asked for the shutdown.
pub fn report(lifecycle: Lifecycle, outcome: ShutdownOutcome) -> Nil {
  case outcome {
    Clean -> sys.info("crushling: stopped every agent")
    _ -> sys.warn("crushling: shutdown incomplete: " <> string.inspect(outcome))
  }
  case lifecycle {
    Draining(reply) | Finishing(reply) -> process.send(reply, outcome)
    Serving -> Nil
  }
}
