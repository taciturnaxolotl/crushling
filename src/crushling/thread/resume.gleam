//// Where a thread's event stream left off, so a dropped stream can resume.
////
//// Every workspace event from `crush server` carries an SSE id
//// `<epoch>-<seq>`. The epoch is random per workspace instance and seq counts
//// its events from 1, so within an epoch ids only go up. A stream reopened
//// with the last id seen as `Last-Event-ID` gets the events it missed, or a
//// resync event when they can't be replayed.
////
//// Only ids a frame itself carried count (see `crushling_sse_h`). The theme
//// and session snapshots sent on attach have none, and are handled without
//// touching the cursor.

import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string

/// What a thread keeps across reconnects. Sessions are stored in the
/// sandbox's database, so a new actor for the same workspace finds the
/// latest one; a dropped connection rejoins the workspace it left and
/// replays the events it missed.
pub type Resume {
  Resume(
    workspace_id: Option(String),
    session_id: Option(String),
    cursor: Cursor,
  )
}

pub fn fresh() -> Resume {
  Resume(workspace_id: None, session_id: None, cursor: new())
}

/// After joining `workspace_id` and its session `session_id`.
pub fn joined(
  resume: Resume,
  workspace_id: String,
  session_id: String,
) -> Resume {
  Resume(
    ..resume,
    workspace_id: Some(workspace_id),
    session_id: Some(session_id),
  )
}

pub type EventId {
  EventId(epoch: String, seq: Int)
}

/// The id of the last event the thread handled, if any carried one.
pub opaque type Cursor {
  Cursor(last: Option(String))
}

pub fn new() -> Cursor {
  Cursor(last: None)
}

/// The id to resume from, for the `Last-Event-ID` header.
pub fn last(cursor: Cursor) -> Option(String) {
  cursor.last
}

pub fn parse(id: String) -> Result(EventId, Nil) {
  case string.split_once(string.trim(id), "-") {
    Ok(#(epoch, seq)) if epoch != "" ->
      case int.parse(seq) {
        Ok(seq) if seq >= 0 -> Ok(EventId(epoch:, seq:))
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// Whether to handle an event that arrived with `id`, and the cursor after
/// it. An event is skipped when its id is from the same epoch and not past
/// the last one handled: it was already handled, before the stream dropped
/// or earlier on this stream. An event without an id is always handled and
/// leaves the cursor alone; an explicit empty id clears it, so the next
/// stream is opened without a `Last-Event-ID`.
pub fn admit(cursor: Cursor, id: Option(String)) -> #(Bool, Cursor) {
  case id {
    None -> #(True, cursor)
    // An empty id resets the stream's position: resume from nothing.
    Some("") -> #(True, Cursor(last: None))
    Some(raw) ->
      case parse(raw), option.map(cursor.last, parse) {
        Ok(new), Some(Ok(old)) if new.epoch == old.epoch && new.seq <= old.seq -> #(
          False,
          cursor,
        )
        Ok(_), _ -> #(True, Cursor(last: Some(raw)))
        // Not an id this server issues; handle the event but don't resume
        // from it.
        Error(Nil), _ -> #(True, cursor)
      }
  }
}

/// A resync positions the stream at its own id, which may be from a new
/// epoch, whatever was handled before.
pub fn resynced(cursor: Cursor, id: Option(String)) -> Cursor {
  case id {
    Some(raw) -> Cursor(last: Some(raw))
    None -> cursor
  }
}
