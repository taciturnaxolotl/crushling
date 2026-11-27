import crushling/crush/event
import crushling/run
import crushling/sink
import crushling/thread/turn
import gleam/option.{None, Some}
import gleam/string

fn says(text: String) -> event.Event {
  event.MessageEvent(
    "updated",
    event.Message("m1", "s1", event.Assistant, text, [], [], []),
  )
}

fn calls_tool() -> event.Event {
  event.MessageEvent(
    "updated",
    event.Message(
      "m1",
      "s1",
      event.Assistant,
      "",
      [event.ToolCall("c1", "bash", "{\"command\":\"make\"}")],
      [],
      [],
    ),
  )
}

fn completes(error: String, cancelled: Bool) -> event.Event {
  event.RunCompleteEvent(event.RunComplete("s1", "r1", "", error, cancelled))
}

fn asked(at: Int) -> turn.Turn {
  turn.asked(run.new("s1", "r1"), "U1", Some("tree"), at - 20, at - 10, at)
}

pub fn origin_test() {
  let assert True = turn.solicited(asked(0))
  let assert Some("U1") = turn.asker(asked(0))
  let report = turn.report(run.new("s1", ""), 0)
  let assert False = turn.solicited(report)
  let assert None = turn.asker(report)
  let nobody = turn.asked(run.new("s1", "r1"), "", None, 0, 0, 0)
  let assert None = turn.asker(nobody)
}

pub fn quiet_until_stalled_test() {
  let t = asked(0)
  let assert #(_, turn.Quiet) = turn.tick(t, turn.stall_ms)
  let assert #(t, turn.Stall) = turn.tick(t, turn.stall_ms + 1)
  // Noted once.
  let assert #(_, turn.Quiet) = turn.tick(t, turn.stall_ms + 60_000)
  // An event makes a later stall worth a note of its own.
  let t = turn.observe(t, says("back"), turn.stall_ms + 2)
  let assert #(_, turn.Stall) = turn.tick(t, 2 * turn.stall_ms + 3)
}

pub fn a_running_tool_is_not_a_stall_test() {
  let t = turn.observe(asked(0), calls_tool(), 0)
  let assert #(_, turn.Quiet) = turn.tick(t, turn.stall_ms + 1)
}

pub fn long_runs_are_marked_again_test() {
  let t = turn.observe(asked(0), calls_tool(), 0)
  let assert #(t, turn.Rework) = turn.tick(t, turn.rework_ms + 1)
  let assert #(_, turn.Quiet) = turn.tick(t, turn.rework_ms + 2)
  let assert #(_, turn.Rework) = turn.tick(t, 2 * turn.rework_ms + 2)
}

pub fn closing_test() {
  let t = turn.observe(asked(0), completes("", True), 1)
  let assert "" = turn.closing(t)
  let t = turn.Turn(..t, stop_note: Some("restarting"))
  let assert "_restarting_" = turn.closing(t)
  let failed = turn.observe(asked(0), completes("429 rate_limit", False), 1)
  let assert True = string.contains(turn.closing(failed), "rate-limited")
  let quiet = turn.observe(asked(0), completes("", False), 1)
  let assert "_no reply._" = turn.closing(quiet)
}

pub fn moved_leaves_out_what_was_said_test() {
  let t = turn.observe(asked(0), says("first part"), 1)
  let t = turn.observe(t, completes("", False), 2)
  let assert "first part" = turn.said(t)
  let reply = sink.Reply(show: fn(_, _, _) { Nil }, finish: fn(_) { [] })
  let t = turn.streaming(t, reply)
  let assert Some(_) = turn.reply(t)
  let t = turn.moved(t)
  let assert None = turn.reply(t)
  let assert "" = turn.said(t)
}

pub fn timings_test() {
  let t = turn.observe(asked(100), says("hi"), 150)
  let t = turn.observe(t, says("more"), 170)
  let t = turn.finished(t, 300)
  let assert Some("run=r1 prepared=10 sent=20 first_event=70 finished=220") =
    turn.timings(t)
  let assert None = turn.timings(turn.report(run.new("s1", ""), 0))
}
