//// Where in Slack something is said: a channel, and maybe a thread in it.
//// Posts at the top of a channel, such as a code channel, have no thread.

import gleam/option.{type Option, None, Some}

pub type Conversation {
  Conversation(channel: String, thread: Option(String))
}

/// A conversation from Slack's fields, where an empty `thread_ts` means
/// the top of the channel.
pub fn from_slack(channel: String, thread_ts: String) -> Conversation {
  Conversation(channel:, thread: case thread_ts {
    "" -> None
    ts -> Some(ts)
  })
}

/// The thread's ts in Slack's form: "" for the top of the channel.
pub fn thread_ts(conversation: Conversation) -> String {
  option.unwrap(conversation.thread, "")
}

/// Put a Slack call in the conversation's thread, if it has one, with the
/// call's own `thread_ts` setter.
pub fn in_thread(
  call: call,
  conversation: Conversation,
  set: fn(call, String) -> call,
) -> call {
  case conversation.thread {
    Some(ts) -> set(call, ts)
    None -> call
  }
}
