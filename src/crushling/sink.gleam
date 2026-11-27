//// The functions a thread actor uses to post in one Slack conversation.
//// `slack/sink.surface` builds the real ones, and the tests build their own.

import crushling/conversation.{type Conversation}
import crushling/render
import crushling/venue.{type Venue}
import gleam/option.{type Option, None, Some}
import slackline/block

/// The sink for each place the work can be, so a thread's sink always
/// matches its venue.
pub type Surface =
  fn(Venue) -> Sink

pub type Sink {
  Sink(
    /// The channel that posts go to, and the thread in it. Posts at the top of
    /// a code channel have no thread.
    conversation: Conversation,
    /// Post a markdown message and return its ts.
    post: fn(String) -> Result(String, String),
    /// Post a message made of blocks, with `text` as its notification
    /// fallback, and return its ts. `update_blocks` replaces one.
    post_blocks: fn(String, List(block.Block)) -> Result(String, String),
    update_blocks: fn(String, String, List(block.Block)) -> Result(Nil, String),
    /// Delete a message the bot posted, by its ts.
    delete: fn(String) -> Result(Nil, String),
    /// Start the reply to a run. Slack streams a reply to one person, so give
    /// their user id, or "" if it is not known.
    reply: fn(String) -> Reply,
    /// Attach a file, given its name and contents.
    upload: fn(String, String) -> Result(Nil, String),
    /// Start a new thread for a subagent: its first message, as text and
    /// blocks, and the title for its session.
    branch: fn(String, List(block.Block), String) -> Result(Branch, String),
    /// The agent session here, where there is one: a thread inside a code
    /// channel has none of its own.
    session: Option(Session),
    /// A code channel's context bar and Code tab.
    code_view: Option(CodeView),
    /// Open a code channel called `name` from here, where Slack allows it.
    open_code_channel: Option(fn(String) -> Result(Opened, String)),
  )
}

pub type Session {
  Session(
    /// Show the agent session as working or as ready. While it works, Slack
    /// shows "Working…" and a Stop button.
    working: fn(Bool) -> Nil,
    /// Name the session.
    title: fn(String) -> Nil,
  )
}

pub type CodeView {
  CodeView(
    /// Set the context bar.
    context: fn(List(ContextItem)) -> Nil,
    /// Set the Code tab from a unified diff, the base branch and the head
    /// branch; an empty diff clears it.
    code: fn(String, String, String) -> Nil,
  )
}

/// A code channel just opened: its id, and when it opened as a Slack ts.
pub type Opened {
  Opened(channel: String, ts: String)
}

/// A subagent's thread: where it posts, a link to it, and its first
/// message's ts, to update it later. Its plan card is posted with
/// `post_plan` and changed with `update_plan`.
pub type Branch {
  Branch(
    sink: Sink,
    link: String,
    root_ts: String,
    post_plan: fn(render.Plan) -> Result(String, String),
    update_plan: fn(String, render.Plan) -> Result(Nil, String),
  )
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

/// Mark the session working or ready, where there is one.
pub fn working(sink: Sink, busy: Bool) -> Nil {
  case sink.session {
    Some(session) -> session.working(busy)
    None -> Nil
  }
}

/// Show the session as working exactly while `busy`, in `here`, the place
/// the work is now: clear the mark in `marked`, where it was shown, if the
/// work moved. Returns where it is shown now.
pub fn mark(marked: Option(Sink), here: Sink, busy: Bool) -> Option(Sink) {
  case busy, marked {
    True, Some(there) if there.conversation == here.conversation -> marked
    True, _ -> {
      option.map(marked, working(_, False))
      working(here, True)
      Some(here)
    }
    False, Some(there) -> {
      working(there, False)
      None
    }
    False, None -> None
  }
}

/// Name the session, where there is one.
pub fn title(sink: Sink, title: String) -> Nil {
  case sink.session {
    Some(session) -> session.title(title)
    None -> Nil
  }
}
