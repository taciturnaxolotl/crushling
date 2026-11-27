//// When a live thread's agent is stopped for being idle. Pure: each function
//// returns the new idle state and what the registry should do about it.

import gleam/option.{type Option, None, Some}

pub type Idle {
  /// Not quiet when last looked at: no idle check is due.
  Active
  /// Quiet, with an idle check due under `token`.
  Quiet(token: Int)
  /// The check under `token` asked for a job count; `held_since` carries over a hold.
  Counting(token: Int, held_since: Option(Int))
  /// Kept since `since` (monotonic ms) for background jobs; checked again under `token`.
  Held(token: Int, since: Int)
}

pub type Action {
  /// Check again after the idle time, under `token`.
  CheckLater(token: Int)
  /// Ask for a job count under `token`, going ahead without it after `count_timeout_ms`.
  CountJobs(token: Int)
  /// The agent is kept for `running` background jobs.
  Keep(running: Int)
  /// Stop the agent; `why` is for the log.
  Stop(why: String)
}

/// The longest a quiet agent is kept for background jobs, so a forgotten server can't hold a sandbox.
pub const max_hold_ms = 7_200_000

/// How long the thread gets to count its jobs before the idle stop goes ahead.
pub const count_timeout_ms = 30_000

/// The thread changed: `token` replaces any due check; work ends a hold.
pub fn settle(idle: Idle, quiet: Bool, token: Int) -> #(Idle, List(Action)) {
  case quiet, held_since(idle) {
    False, _ -> #(Active, [])
    True, Some(since) -> #(Held(token, since), [CheckLater(token)])
    True, None -> #(Quiet(token), [CheckLater(token)])
  }
}

/// The idle time under `token` is up: a quiet thread is asked for its jobs.
pub fn check(idle: Idle, quiet: Bool, token: Int) -> #(Idle, List(Action)) {
  case current(idle, token) && quiet {
    True -> #(Counting(token, held_since(idle)), [CountJobs(token)])
    False -> #(idle, [])
  }
}

/// None running stops the agent; some keep it, up to `max_hold_ms` in all.
pub fn counted(
  idle: Idle,
  quiet: Bool,
  token: Int,
  running: Int,
  now: Int,
) -> #(Idle, List(Action)) {
  case current(idle, token) {
    False -> #(idle, [])
    True -> {
      let held = held_since(idle)
      let waiting = case held {
        Some(since) -> Held(token, since)
        None -> Quiet(token)
      }
      let since = option.unwrap(held, now)
      case quiet, running {
        // Something happened since the check without settling it.
        False, _ -> #(waiting, [])
        True, 0 -> #(waiting, [Stop("is idle")])
        True, _ if now - since >= max_hold_ms -> #(waiting, [
          Stop("has been idle with background jobs too long"),
        ])
        True, _ -> #(Held(token, since), [Keep(running), CheckLater(token)])
      }
    }
  }
}

/// Whether a count for `token` is still awaited.
pub fn awaits_count(idle: Idle, token: Int) -> Bool {
  case idle {
    Counting(token: t, ..) -> t == token
    _ -> False
  }
}

fn current(idle: Idle, token: Int) -> Bool {
  case idle {
    Active -> False
    Quiet(token: t) | Counting(token: t, ..) | Held(token: t, ..) -> t == token
  }
}

fn held_since(idle: Idle) -> Option(Int) {
  case idle {
    Active | Quiet(..) -> None
    Counting(held_since:, ..) -> held_since
    Held(since:, ..) -> Some(since)
  }
}
