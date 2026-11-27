//// Asking Slack for a code channel for the repository the work is on.

import crushling/git
import crushling/sink.{type Sink}
import crushling/sys
import crushling/venue.{type Venue}
import gleam/option.{None, Some}
import gleam/string

pub type Opening {
  /// The work moves to `venue`, code channel `channel`, which opened at `ts`.
  Opened(venue: Venue, channel: String, ts: String)
  /// Slack wouldn't open one, so the work stays in the thread as `venue`;
  /// later clones there do not try again.
  Refused(venue: Venue, reason: String)
}

/// The channel's name: the agent's name for the work, else what the thread
/// is about, else the repository's (the Code tab shows the repository
/// anyway).
pub fn name(asked: String, topic: String, found: git.Found) -> String {
  case string.trim(asked), string.trim(topic) {
    "", "" -> found.name
    "", topic -> topic
    asked, _ -> asked
  }
}

/// Open a code channel called `name` from `thread` for `found`.
pub fn open(thread: Sink, found: git.Found, name: String) -> Opening {
  let opened = case thread.open_code_channel {
    Some(open) -> open(name)
    None -> Error("a code channel can't be opened from here")
  }
  case opened {
    Ok(sink.Opened(channel:, ts:)) ->
      Opened(venue.CodeChannel(channel:, repo: found.dir), channel, ts)
    Error(reason) -> {
      sys.warn("crushling: staying in the thread: " <> reason)
      Refused(venue.ThreadOnly(repo: found.dir), reason)
    }
  }
}
