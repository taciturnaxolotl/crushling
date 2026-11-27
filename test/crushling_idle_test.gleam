import crushling/registry/idle.{
  Active, CheckLater, CountJobs, Counting, Held, Keep, Quiet, Stop,
}
import gleam/option.{None, Some}

pub fn a_quiet_thread_gets_a_check_test() {
  let assert #(Quiet(1), [CheckLater(1)]) = idle.settle(Active, True, 1)
}

pub fn a_busy_thread_has_no_check_test() {
  let assert #(Active, []) = idle.settle(Quiet(1), False, 2)
  // Work ends a hold.
  let assert #(Active, []) = idle.settle(Held(1, 50), False, 2)
}

pub fn settling_again_replaces_the_token_and_keeps_a_hold_test() {
  let assert #(Quiet(2), [CheckLater(2)]) = idle.settle(Quiet(1), True, 2)
  let assert #(Held(3, 50), [CheckLater(3)]) = idle.settle(Held(1, 50), True, 3)
  let assert #(Held(3, 50), [CheckLater(3)]) =
    idle.settle(Counting(1, Some(50)), True, 3)
  let assert #(Quiet(3), [CheckLater(3)]) =
    idle.settle(Counting(1, None), True, 3)
}

pub fn the_check_asks_for_jobs_test() {
  let assert #(Counting(1, None), [CountJobs(1)]) =
    idle.check(Quiet(1), True, 1)
  let assert #(Counting(1, Some(50)), [CountJobs(1)]) =
    idle.check(Held(1, 50), True, 1)
}

pub fn a_stale_or_unquiet_check_does_nothing_test() {
  let assert #(Quiet(2), []) = idle.check(Quiet(2), True, 1)
  let assert #(Active, []) = idle.check(Active, True, 1)
  let assert #(Quiet(1), []) = idle.check(Quiet(1), False, 1)
}

pub fn no_jobs_stops_the_agent_test() {
  let assert #(_, [Stop(_)]) = idle.counted(Counting(1, None), True, 1, 0, 100)
}

pub fn jobs_hold_the_agent_test() {
  let assert #(Held(1, 100), [Keep(2), CheckLater(1)]) =
    idle.counted(Counting(1, None), True, 1, 2, 100)
  // A hold already under way keeps its start.
  let assert #(Held(1, 100), [Keep(2), CheckLater(1)]) =
    idle.counted(Counting(1, Some(100)), True, 1, 2, 5000)
}

pub fn a_hold_ends_after_the_most_test() {
  let assert #(_, [Stop(_)]) =
    idle.counted(Counting(1, Some(0)), True, 1, 2, idle.max_hold_ms)
}

pub fn a_stale_count_is_ignored_test() {
  let assert #(Counting(2, None), []) =
    idle.counted(Counting(2, None), True, 1, 0, 100)
  let assert #(Active, []) = idle.counted(Active, True, 1, 0, 100)
}

pub fn a_count_for_a_thread_no_longer_quiet_waits_test() {
  let assert #(Quiet(1), []) = idle.counted(Counting(1, None), False, 1, 0, 100)
  let assert #(Held(1, 7), []) =
    idle.counted(Counting(1, Some(7)), False, 1, 0, 100)
}

pub fn awaits_count_test() {
  let assert True = idle.awaits_count(Counting(1, None), 1)
  let assert False = idle.awaits_count(Counting(1, None), 2)
  let assert False = idle.awaits_count(Quiet(1), 1)
}
