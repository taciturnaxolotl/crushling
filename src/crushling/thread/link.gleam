//// The thread's link to its server, and the attempts to make it. An
//// attempt runs off the actor (`conn.open_apart`) and its result comes back
//// as a message for `attempted`.

import crushling/gun
import crushling/sys
import crushling/thread/conn.{type Connection, type Target}
import crushling/thread/resume.{type Resume}
import gleam/erlang/process
import gleam/option.{type Option, None, Some}

/// `retries` counts failed attempts in a row, for the backoff and for
/// giving up.
pub type Link {
  Down(retries: Int)
  Connecting(retries: Int)
  Up(Connection)
}

/// How an attempt went, for the thread to act on.
pub type Attempted {
  Joined(Connection)
  /// Try again after `after_ms`.
  Retry(after_ms: Int)
  /// Too many attempts failed: the agent is gone.
  GaveUp
  /// An attempt nobody waits for any more; its connection is closed.
  Stale
}

/// What a message from gun means for the link.
pub type Heard {
  Event(gun.SseEvent)
  /// The stream or a connection dropped.
  Dropped
  /// Not about this link: a connection closed before, say.
  Unrelated
}

const max_retries = 8

pub fn new() -> Link {
  Down(0)
}

/// The connection, when the link is up.
pub fn connection(link: Link) -> Option(Connection) {
  case link {
    Up(connection) -> Some(connection)
    Down(_) | Connecting(_) -> None
  }
}

/// Whether a connection is on its way: being made, or retried soon.
pub fn awaiting(link: Link) -> Bool {
  case link {
    Up(_) -> False
    Connecting(_) -> True
    Down(retries) -> retries <= max_retries
  }
}

/// Start an attempt, unless one is under way; an open connection is closed
/// first. `deliver` gets the result in the attempt's process.
pub fn connect(
  link: Link,
  target: Target,
  resume: Resume,
  deliver: fn(Result(Connection, String)) -> Nil,
) -> Link {
  let start = fn(retries) {
    conn.open_apart(target, resume, process.self(), deliver)
    Connecting(retries)
  }
  case link {
    Connecting(_) -> link
    Up(connection) -> {
      conn.close(connection)
      start(0)
    }
    Down(retries) -> start(retries)
  }
}

/// The link once an attempt has ended with `result`.
pub fn attempted(
  link: Link,
  result: Result(Connection, String),
) -> #(Link, Attempted) {
  case link, result {
    Connecting(_), Ok(connection) -> #(Up(connection), Joined(connection))
    Connecting(retries), Error(reason) -> {
      sys.warn("crushling: connect failed: " <> reason)
      // Past the limit, nothing waits for a connection any more.
      case retries >= max_retries {
        True -> #(Down(retries + 1), GaveUp)
        False -> #(Down(retries + 1), Retry(conn.backoff(retries)))
      }
    }
    _, Ok(connection) -> {
      conn.close(connection)
      #(link, Stale)
    }
    _, Error(_) -> #(link, Stale)
  }
}

/// Close the link, to connect again.
pub fn drop(link: Link) -> Link {
  case link {
    Up(connection) -> conn.close(connection)
    Down(_) | Connecting(_) -> Nil
  }
  Down(0)
}

/// Read a message from gun against the link.
pub fn hear(link: Link, message: gun.Message) -> Heard {
  case link, message {
    Up(connection), gun.Event(stream:, event:, ..)
      if stream == connection.stream
    -> Event(event)
    Up(connection), gun.StreamEnd(stream:, ..)
    | Up(connection), gun.StreamError(stream:, ..)
      if stream == connection.stream
    -> Dropped
    Up(connection), gun.ConnDown(conn:, reason:)
      if conn == connection.events || conn == connection.requests
    -> {
      sys.warn("crushling: connection down: " <> reason)
      Dropped
    }
    _, _ -> Unrelated
  }
}
