//// One turn of the agent as the thread sees it: the run, who it is for,
//// what of it is shown, whether the agent is still heard from, and how
//// long each part took. Everything here is pure; the thread actor does the
//// posting.

import crushling/crush/event.{type Event}
import crushling/render
import crushling/run.{type Run}
import crushling/sink.{type Reply}
import crushling/thread/say
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// With no event from the agent for this long, say so in the thread.
pub const stall_ms = 600_000

/// Slack drops a session out of working after an hour; mark it again well
/// before.
pub const rework_ms = 1_800_000

pub type Turn {
  Turn(
    run: Run,
    origin: Origin,
    shown: Shown,
    liveness: Liveness,
    /// Said in place of "stopped" when the turn was cancelled for a reason.
    stop_note: Option(String),
    /// How many of the run's steps an earlier reply already showed: a
    /// progress update the agent posts mid-run ends the reply before it,
    /// and the next one carries on from there.
    steps_shown: Int,
  )
}

pub type Origin {
  /// A prompt the bridge sent for `from` ("" if not known). `base` is the
  /// workspace snapshot taken just before it was sent.
  Asked(from: String, base: Option(String), trace: Trace)
  /// A turn crush started on its own to read a subagent's report.
  ReportTurn
}

/// What of the turn is in Slack. After a move to a code channel, `after` is
/// what was said in the thread, which the reply there leaves out.
pub type Shown {
  NotShown(after: String)
  Streaming(after: String, reply: Reply)
}

/// Whether the agent is still heard from. `marked` is when the session was
/// last marked as working.
pub type Liveness {
  Lively(last_event: Int, marked: Int)
  /// The stall note is posted; the next event makes the turn lively again.
  Stalled(marked: Int)
}

/// When each part of an asked turn happened, in monotonic ms.
pub type Trace {
  Trace(
    received: Int,
    prepared: Int,
    sent: Int,
    first_event: Option(Int),
    finished: Option(Int),
  )
}

/// What the watchdog should do.
pub type Tick {
  Quiet
  /// Mark the session working again, before Slack drops it.
  Rework
  /// Say the agent may be stuck, and mark the session working again.
  Stall
}

/// A turn for a prompt that reached the thread at `received`, was ready to
/// send at `prepared` and was sent at `sent`.
pub fn asked(
  run: Run,
  from: String,
  base: Option(String),
  received: Int,
  prepared: Int,
  sent: Int,
) -> Turn {
  let trace =
    Trace(received:, prepared:, sent:, first_event: None, finished: None)
  new(run, Asked(from:, base:, trace:), sent)
}

/// A turn crush started on its own at `now`.
pub fn report(run: Run, now: Int) -> Turn {
  new(run, ReportTurn, now)
}

fn new(run: Run, origin: Origin, now: Int) -> Turn {
  Turn(
    run:,
    origin:,
    shown: NotShown(after: ""),
    liveness: Lively(last_event: now, marked: now),
    stop_note: None,
    steps_shown: 0,
  )
}

/// Whether the bridge sent the prompt, rather than crush starting the turn.
pub fn solicited(turn: Turn) -> Bool {
  case turn.origin {
    Asked(..) -> True
    ReportTurn -> False
  }
}

/// Who asked, when someone did.
pub fn asker(turn: Turn) -> Option(String) {
  case turn.origin {
    Asked(from:, ..) if from != "" -> Some(from)
    _ -> None
  }
}

/// Fold an event from the server into the turn, heard at `now`.
pub fn observe(turn: Turn, event: Event, now: Int) -> Turn {
  let origin = case turn.origin {
    Asked(from:, base:, trace: Trace(first_event: None, ..) as trace) ->
      Asked(from:, base:, trace: Trace(..trace, first_event: Some(now)))
    origin -> origin
  }
  Turn(
    ..turn,
    run: run.apply(turn.run, event),
    origin:,
    liveness: Lively(last_event: now, marked: marked(turn.liveness)),
  )
}

fn marked(liveness: Liveness) -> Int {
  case liveness {
    Lively(marked:, ..) | Stalled(marked:) -> marked
  }
}

/// The watchdog's check at `now`. A tool still running (a long build, or a
/// GitHub read waiting for someone to connect) sends no events while it
/// runs, and isn't the agent being stuck. A stall is noted once.
pub fn tick(turn: Turn, now: Int) -> #(Turn, Tick) {
  let waiting_on_tool = run.tool_running(turn.run)
  case turn.liveness {
    Lively(last_event:, ..) if now - last_event > stall_ms && !waiting_on_tool -> #(
      Turn(..turn, liveness: Stalled(marked: now)),
      Stall,
    )
    liveness ->
      case now - marked(liveness) > rework_ms {
        True -> #(Turn(..turn, liveness: remarked(liveness, now)), Rework)
        False -> #(turn, Quiet)
      }
  }
}

fn remarked(liveness: Liveness, now: Int) -> Liveness {
  case liveness {
    Lively(last_event:, ..) -> Lively(last_event:, marked: now)
    Stalled(..) -> Stalled(marked: now)
  }
}

/// What the reply shows now: what the agent said since the move, if any.
pub fn said(turn: Turn) -> String {
  let text = render.reply(turn.run)
  let before = turn.shown.after
  case before, string.starts_with(text, before) {
    "", _ -> text
    _, True -> string.drop_start(text, string.length(before)) |> string.trim
    _, False -> text
  }
}

/// The reply, when one is open.
pub fn reply(turn: Turn) -> Option(Reply) {
  case turn.shown {
    Streaming(reply:, ..) -> Some(reply)
    NotShown(..) -> None
  }
}

/// The turn once its reply is open as `reply`.
pub fn streaming(turn: Turn, reply: Reply) -> Turn {
  Turn(..turn, shown: Streaming(reply:, after: turn.shown.after))
}

/// The turn after the work moved: the reply so far stays where it was, and a
/// new one starts after it.
pub fn moved(turn: Turn) -> Turn {
  Turn(..turn, shown: NotShown(after: render.reply(turn.run)))
}

/// The turn after the agent posted a progress update: the reply so far
/// stays above it, and a new one starts below with what comes next.
pub fn split(turn: Turn) -> Turn {
  Turn(
    ..turn,
    shown: NotShown(after: render.reply(turn.run)),
    steps_shown: list.length(turn.run.tools),
  )
}

/// The line that ends the reply, or "" for none.
pub fn closing(turn: Turn) -> String {
  case turn.run.outcome, turn.stop_note {
    Some(run.Cancelled), Some(note) -> say.aside(note)
    _, _ ->
      render.note(turn.run, render.answer(turn.run) != [])
      |> option.unwrap("")
  }
}

/// The turn once it has finished at `now`.
pub fn finished(turn: Turn, now: Int) -> Turn {
  case turn.origin {
    Asked(from:, base:, trace:) ->
      Turn(
        ..turn,
        origin: Asked(from:, base:, trace: Trace(..trace, finished: Some(now))),
      )
    ReportTurn -> turn
  }
}

/// An asked turn's timings for the log, as key=value pairs in ms since the
/// prompt reached the thread.
pub fn timings(turn: Turn) -> Option(String) {
  case turn.origin {
    ReportTurn -> None
    Asked(trace:, ..) -> {
      let at = fn(key, ms) { key <> "=" <> int.to_string(ms - trace.received) }
      let maybe = fn(key, ms) {
        case ms {
          Some(ms) -> at(key, ms)
          None -> key <> "=none"
        }
      }
      Some(string.join(
        [
          "run=" <> string.slice(turn.run.run_id, 0, 8),
          at("prepared", trace.prepared),
          at("sent", trace.sent),
          maybe("first_event", trace.first_event),
          maybe("finished", trace.finished),
        ],
        " ",
      ))
    }
  }
}
