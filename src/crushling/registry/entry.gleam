//// What the registry knows about one thread.

import crushling/conversation.{type Conversation, Conversation}
import crushling/meta.{type Meta, Meta}
import crushling/registry/idle.{type Idle}
import crushling/registry/incoming.{type Incoming}
import crushling/registry/tailnet
import crushling/slack/text
import crushling/thread
import crushling/venue
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}

pub type Agent {
  /// No agent: the entry was rebuilt from the store, and isn't kept in memory.
  Asleep
  /// The agent is launching, as launch number `launch`.
  Starting(launch: Int)
  /// The agent is up. Its turn and idle state go when it stops.
  Live(
    thread: Subject(thread.Message),
    monitor: process.Monitor,
    turn: Turn,
    idle: Idle,
  )
  /// The launcher is stopping the agent; `attempt` counts retries, and the backlog waits.
  Stopping(attempt: Int)
}

/// What a live agent is doing.
pub type Turn {
  Turn(
    /// Prompts sent and not yet finished.
    in_flight: Int,
    /// Prepared one at a time, so each catches up from where the last left off.
    preparing: Bool,
    /// True while the thread says it is busy.
    working: Bool,
  )
}

pub const no_turn = Turn(in_flight: 0, preparing: False, working: False)

pub type Entry {
  Entry(
    channel: String,
    thread_ts: String,
    agent: Agent,
    meta: Meta,
    /// Messages waiting to be prepared, oldest first.
    backlog: List(Incoming),
    /// The last reply, kept as a code channel's summary when it is archived.
    summary_ts: String,
    /// Messages for the thread actor from while it wasn't up.
    pending: List(thread.Message),
    /// Who has prompted the agent since it woke, for their App Home.
    people: Set(String),
  )
}

pub fn new(channel: String, thread_ts: String, meta: Meta) -> Entry {
  Entry(
    channel:,
    thread_ts:,
    agent: Asleep,
    meta:,
    backlog: [],
    summary_ts: "",
    pending: [],
    people: set.new(),
  )
}

/// Whether the agent already read a message; Slack can deliver late, such as after a restart.
pub fn already_read(known: Option(Entry), ts: String) -> Bool {
  case known {
    Some(Entry(meta: Meta(cursor:, ..), ..)) if cursor != "" ->
      text.ts_value(ts) <=. text.ts_value(cursor)
    _ -> False
  }
}

/// Whether messages wait to be prepared, or for the thread actor.
pub fn has_waiting(entry: Entry) -> Bool {
  entry.backlog != [] || entry.pending != []
}

/// True when the thread is idle and nothing is waiting for it.
pub fn is_quiet(entry: Entry) -> Bool {
  !has_waiting(entry)
  && case entry.agent {
    Live(turn: Turn(in_flight: 0, preparing: False, working: False), ..) -> True
    Live(..) -> False
    Asleep | Starting(..) | Stopping(..) -> True
  }
}

/// Whether a message is being prepared for the agent now.
pub fn preparing(entry: Entry) -> Bool {
  case entry.agent {
    Live(turn:, ..) -> turn.preparing
    Asleep | Starting(..) | Stopping(..) -> False
  }
}

/// The entry with its live agent's turn changed; other agents have none.
pub fn map_turn(entry: Entry, change: fn(Turn) -> Turn) -> Entry {
  case entry.agent {
    Live(turn:, ..) as live ->
      Entry(..entry, agent: Live(..live, turn: change(turn)))
    Asleep | Starting(..) | Stopping(..) -> entry
  }
}

/// The conversation a thread talks in now: its thread, or its code channel.
pub fn conversation(entry: Entry) -> Conversation {
  case entry.meta.venue {
    venue.CodeChannel(channel:, ..) -> Conversation(channel, None)
    _ -> Conversation(entry.channel, Some(entry.thread_ts))
  }
}

/// The thread as tailnet access sees it.
pub fn tailnet_view(entry: Entry) -> tailnet.Thread {
  tailnet.Thread(
    running: case entry.agent {
      Live(..) -> True
      Asleep | Starting(..) | Stopping(..) -> False
    },
    grant: entry.meta.tailnet,
    home: #(entry.channel, entry.thread_ts),
    conversation: conversation(entry),
  )
}
