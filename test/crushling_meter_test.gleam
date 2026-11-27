//// The proxy's meter on its own: the allow-list, caps per workspace, totals
//// seeded from what was kept, and spend saved in batches that survive a
//// failed save.

import crushling/proxy/meter
import crushling/usage.{type Usage, Cap, Usage, unlimited}
import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}

fn limits() -> meter.Limits {
  meter.Limits(unlimited, unlimited, 4, 4)
}

const one = Usage(10, 5, 0.25, 1)

pub fn only_allowed_threads_may_spend_test() {
  let assert Ok(m) = meter.start(limits())
  let assert Error(meter.Revoked) = meter.check_key(m, "T1-C1-1.0")
  meter.allow(m, "T1-C1-1.0")
  let assert Ok(Nil) = meter.check_key(m, "T1-C1-1.0")
  meter.disallow(m, "T1-C1-1.0")
  let assert Error(meter.Revoked) = meter.check_key(m, "T1-C1-1.0")
}

pub fn the_team_cap_counts_one_workspace_test() {
  let assert Ok(m) =
    meter.start(meter.Limits(..limits(), team_cap: Cap(Some(20), None)))
  meter.allow(m, "T1-C1-1.0")
  meter.allow(m, "T1-C2-1.0")
  meter.allow(m, "T2-C1-1.0")
  meter.record(m, "T1-C1-1.0", one)
  meter.record(m, "T1-C1-1.0", one)
  let assert Error(meter.TeamCap) = meter.check_key(m, "T1-C2-1.0")
  let assert Ok(Nil) = meter.check_key(m, "T2-C1-1.0")
}

fn keeper(
  saves: Subject(List(#(String, Usage))),
  save: fn(List(#(String, Usage))) -> Result(Nil, String),
  every_ms: Int,
) -> meter.Keeper {
  meter.Keeper(
    thread_total: fn(key) {
      case key {
        "T1-C1-1.0" -> Ok(Usage(100, 0, 1.0, 3))
        _ -> Ok(usage.zero)
      }
    },
    team_total: fn(team) {
      case team {
        "T1" -> Ok(Usage(1000, 0, 5.0, 9))
        _ -> Ok(usage.zero)
      }
    },
    save: fn(spent) {
      process.send(saves, spent)
      case spent {
        // The store refuses the first batch of a thread's one request.
        [#("T2-C1-1.0", Usage(requests: 1, ..))] -> Error("database is locked")
        _ -> save(spent)
      }
    },
    every_ms:,
  )
}

/// Caps count what was spent before a restart.
pub fn totals_start_from_what_was_kept_test() {
  let saves = process.new_subject()
  let assert Ok(started) =
    meter.start_with(
      meter.Limits(..limits(), thread_cap: Cap(None, Some(1.2))),
      Some(keeper(saves, fn(_) { Ok(Nil) }, 60_000)),
      None,
    )
  let m = started.data
  meter.allow(m, "T1-C1-1.0")
  let assert Ok(Nil) = meter.check_key(m, "T1-C1-1.0")
  meter.record(m, "T1-C1-1.0", one)
  let assert Usage(110, 5, 1.25, 4) = meter.totals(m, "T1-C1-1.0")
  let assert Usage(1010, 5, 5.25, 10) = meter.team_totals(m, "T1")
  let assert Error(meter.ThreadCap) = meter.check_key(m, "T1-C1-1.0")
  // Only what is new is saved, once.
  let assert Ok(Nil) = meter.flush(m)
  let assert Ok([#("T1-C1-1.0", Usage(10, 5, 0.25, 1))]) =
    process.receive(saves, 1000)
  let assert Ok(Nil) = meter.flush(m)
  let assert Error(Nil) = process.receive(saves, 100)
}

/// A batch the store refuses is kept and saved with the next one.
pub fn a_failed_save_is_tried_again_test() {
  let saves = process.new_subject()
  let assert Ok(started) =
    meter.start_with(limits(), Some(keeper(saves, fn(_) { Ok(Nil) }, 50)), None)
  let m = started.data
  meter.record(m, "T2-C1-1.0", one)
  let assert Ok([#("T2-C1-1.0", Usage(10, 5, 0.25, 1))]) =
    process.receive(saves, 1000)
  meter.record(m, "T2-C1-1.0", one)
  // The timer saves both together, the first having failed.
  let assert Ok([#("T2-C1-1.0", Usage(20, 10, 0.5, 2))]) =
    process.receive(saves, 1000)
  let assert Error(Nil) = process.receive(saves, 200)
}
