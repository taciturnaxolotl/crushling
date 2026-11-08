//// The functions a thread actor uses to post in one Slack conversation.
//// `slack.sink` builds the real one, and the tests build their own.

import crushling/render
import gleam/option.{type Option}

pub type Sink {
  Sink(
    /// The channel that posts go to, and the thread in it. Posts at the top of
    /// a code channel have no thread.
    conversation: Conversation,
    /// Show the agent session as working or as ready. While it works, Slack
    /// shows "Working…" and a Stop button.
    working: fn(Bool) -> Nil,
    /// Name the session after the prompt that started it.
    title: fn(String) -> Nil,
    /// Post a markdown message and return its ts.
    post: fn(String) -> Result(String, String),
    /// Post a plan card and return its ts. `update_plan` changes it later.
    post_plan: fn(render.Plan) -> Result(String, String),
    update_plan: fn(String, render.Plan) -> Result(Nil, String),
    /// Start the reply to a run. Slack streams a reply to one person, so give
    /// their user id, or "" if it is not known.
    reply: fn(String) -> Reply,
    /// Attach a file, given its name and contents.
    upload: fn(String, String) -> Result(Nil, String),
    /// Start a new thread for a subagent. `intro` is its first message and
    /// `title` names its session. Returns the new thread's sink and a link to
    /// it.
    branch: fn(String, String) -> Result(#(Sink, String), String),
    /// Open a code channel called `name` from this thread. Returns the
    /// channel's sink and id.
    open_code_channel: fn(String) -> Result(#(Sink, String), String),
    /// Set a code channel's context bar. `code` sets its Code tab from a
    /// unified diff, the base branch and the head branch.
    context: fn(List(ContextItem)) -> Nil,
    code: fn(String, String, String) -> Nil,
  )
}

pub type Conversation {
  Conversation(channel: String, thread_ts: Option(String))
}

/// A run's reply while the agent writes it. Slack streams it where it can.
/// Elsewhere the reply is a plan card and plain messages.
pub type Reply {
  Reply(
    /// Show everything the reply says so far, its steps, and the title over the
    /// steps.
    show: fn(String, List(render.Task), String) -> Nil,
    /// End the reply with a closing line, or "" for none. Returns the ts of
    /// each message it posted, oldest first.
    finish: fn(String) -> List(String),
  )
}

pub type ContextItem {
  ContextItem(key: String, label: String, icon: String, url: String)
}
