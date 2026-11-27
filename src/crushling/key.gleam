//// A thread's key: the Slack workspace, channel and thread timestamp it
//// lives at. Its string form, `T…-C…-<ts>`, names the thread's row in the
//// store, its directory, its container and its tunnel, so only
//// `[a-zA-Z0-9_.-]` survive in it, as in kloe, and it is at most 64
//// characters (Slack's ids are about 11, so a real key is about 40).

import gleam/list
import gleam/string

pub opaque type Key {
  Key(team: String, channel: String, ts: String)
}

/// The key of thread `ts` in `channel` of workspace `team`. Characters that
/// can't appear in a file or container name become `_`.
pub fn new(team: String, channel: String, ts: String) -> Key {
  Key(team: sanitize(team), channel: sanitize(channel), ts: sanitize(ts))
}

pub fn to_string(key: Key) -> String {
  string.slice(key.team <> "-" <> key.channel <> "-" <> key.ts, 0, 64)
}

/// A key's string form back into a key. Its workspace must be a workspace
/// (`T…`) or organization (`E…`) id, so a key from before keys carried the
/// workspace (`C…-<ts>`) doesn't parse.
pub fn parse(text: String) -> Result(Key, Nil) {
  case is_valid(text), string.split_once(text, "-") {
    True, Ok(#(team, rest)) ->
      case is_team(team), string.split_once(rest, "-") {
        True, Ok(#(channel, ts)) if channel != "" && ts != "" ->
          Ok(Key(team:, channel:, ts:))
        _, _ -> Error(Nil)
      }
    _, _ -> Error(Nil)
  }
}

pub fn team(key: Key) -> String {
  key.team
}

pub fn channel(key: Key) -> String {
  key.channel
}

pub fn ts(key: Key) -> String {
  key.ts
}

/// Whether `text` is safe to use as a key's string form: one path segment
/// of at most 64 safe characters, so it can only name its own directory,
/// container or socket.
pub fn is_valid(text: String) -> Bool {
  let length = string.length(text)
  text != "."
  && text != ".."
  && length >= 1
  && length <= 64
  && list.all(string.to_graphemes(text), is_safe)
}

fn is_team(text: String) -> Bool {
  case text {
    "T" | "E" -> False
    "T" <> _ | "E" <> _ -> True
    _ -> False
  }
}

fn sanitize(text: String) -> String {
  text
  |> string.to_graphemes
  |> list.map(fn(g) {
    case is_safe(g) {
      True -> g
      False -> "_"
    }
  })
  |> string.concat
}

fn is_safe(grapheme: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-",
    grapheme,
  )
  && grapheme != ""
}
