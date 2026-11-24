//// What the registry knows about one thread.

import crushling/meta.{type Meta, Meta}
import crushling/registry/incoming.{type Incoming}
import crushling/registry/tailnet
import crushling/slack
import crushling/thread
import crushling/venue
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}

pub type Agent {
  /// The agent is launching.
  Starting
  Live(thread: Subject(thread.Message), monitor: process.Monitor)
  /// The launcher is stopping the agent; `attempt` counts the retries so
  /// far. Messages wait in the backlog; once the stop has finished, a
  /// thread with any starts again.
  Stopping(attempt: Int)
}

pub type Entry {
  Entry(
    channel: String,
    thread_ts: String,
    generation: Int,
    agent: Agent,
    meta: Meta,
    /// Prompts sent and not yet finished.
    in_flight: Int,
    /// Messages waiting to be prepared, oldest first.
    backlog: List(Incoming),
    /// Whether one is being prepared now. They are prepared one at a time,
    /// so each catches up from where the last left off.
    preparing: Bool,
    /// The last reply posted, kept as a code channel's summary when it is
    /// archived.
    summary_ts: String,
    /// True while the thread says it is busy.
    working: Bool,
    /// Messages for the thread actor that came while its agent was asleep
    /// or starting, sent once it is live.
    pending: List(thread.Message),
    /// Since when (monotonic ms) a quiet thread's agent has been kept for its
    /// background jobs; None when it isn't.
    held_since: Option(Int),
    /// Whether an idle check is waiting for the thread to count its jobs.
    counting: Bool,
    /// Who has sent the agent a prompt here since it last woke, for their
    /// App Home.
    people: Set(String),
  )
}

pub fn new(channel: String, thread_ts: String, meta: Meta) -> Entry {
  Entry(
    channel:,
    thread_ts:,
    generation: 0,
    agent: Starting,
    meta:,
    in_flight: 0,
    backlog: [],
    preparing: False,
    summary_ts: "",
    working: False,
    pending: [],
    held_since: None,
    counting: False,
    people: set.new(),
  )
}

/// Whether the agent has already read a message: it is no newer than the
/// last prompt. Slack can deliver an event late, such as after a restart.
pub fn already_read(known: Option(Entry), ts: String) -> Bool {
  case known {
    Some(Entry(meta: Meta(cursor:, ..), ..)) if cursor != "" ->
      slack.ts_value(ts) <=. slack.ts_value(cursor)
    _ -> False
  }
}

/// True when something waits for the agent: messages to prepare, or
/// messages for the thread actor that came while it wasn't up.
pub fn has_waiting(entry: Entry) -> Bool {
  entry.backlog != [] || entry.pending != []
}

/// True when the thread is idle and nothing is waiting for it.
pub fn is_quiet(entry: Entry) -> Bool {
  entry.in_flight == 0
  && !entry.preparing
  && !has_waiting(entry)
  && !entry.working
}

/// The conversation a thread talks in now: its thread, or its code channel.
pub fn conversation(entry: Entry) -> #(String, String) {
  case entry.meta.venue {
    venue.CodeChannel(channel:, ..) -> #(channel, "")
    _ -> #(entry.channel, entry.thread_ts)
  }
}

/// The thread as tailnet access sees it.
pub fn tailnet_view(entry: Entry) -> tailnet.Thread {
  tailnet.Thread(
    running: case entry.agent {
      Live(..) -> True
      Starting | Stopping(..) -> False
    },
    grant: entry.meta.tailnet,
    home: #(entry.channel, entry.thread_ts),
    conversation: conversation(entry),
  )
}
