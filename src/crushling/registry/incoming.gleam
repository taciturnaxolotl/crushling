//// A Slack message, reduced to what routing needs.

import crushling/slack
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
    files: List(slack.Attachment),
  )
}

pub fn is_dm(channel: String) -> Bool {
  string.starts_with(channel, "D")
}
