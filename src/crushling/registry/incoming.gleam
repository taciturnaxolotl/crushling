//// A Slack message, reduced to what routing needs.

import crushling/attachments.{type Attachment}
import crushling/conversation.{type Conversation, Conversation}
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Incoming {
  Incoming(
    channel: String,
    /// The thread's root; the message's own ts when it starts a thread.
    thread_ts: String,
    ts: String,
    user: String,
    text: String,
    /// Whether the bot was mentioned (or messaged directly), which may
    /// start a thread and always reaches the agent.
    mention: Bool,
    files: List(Attachment),
  )
}

pub fn is_dm(channel: String) -> Bool {
  string.starts_with(channel, "D")
}

/// Where `incoming` was said: its thread, or the top of the channel.
pub fn conversation(incoming: Incoming) -> Conversation {
  conversation.from_slack(incoming.channel, incoming.thread_ts)
}

/// Where to answer `incoming` for everyone to see: in its thread, or at the
/// top of a code channel (one with an `origin` thread) when it was said
/// there.
pub fn announce_place(
  incoming: Incoming,
  origin: Option(#(String, String)),
) -> Conversation {
  let thread = case origin, incoming.ts == incoming.thread_ts {
    Some(_), True -> None
    _, _ -> Some(incoming.thread_ts)
  }
  Conversation(incoming.channel, thread)
}
