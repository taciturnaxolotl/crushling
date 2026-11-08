//// Where a thread does its work. Every thread starts in its Slack thread, and
//// the work moves to a code channel when the agent clones a repository.

import gleam/dynamic/decode
import gleam/json

pub type Venue {
  /// The Slack thread. This is where every thread starts.
  Thread
  /// The Slack thread, with the repository in workspace directory `repo`. Slack
  /// would not open a code channel for it, so later clones do not try again.
  ThreadOnly(repo: String)
  /// Code channel `channel`, which shows the repository in workspace directory
  /// `repo`.
  CodeChannel(channel: String, repo: String)
  /// The code channel for `repo` was archived with `!done`. The next prompt
  /// opens a new one.
  Archived(repo: String)
}

pub fn to_json(venue: Venue) -> json.Json {
  case venue {
    Thread -> json.object([#("kind", json.string("thread"))])
    ThreadOnly(repo:) ->
      json.object([
        #("kind", json.string("thread_only")),
        #("repo", json.string(repo)),
      ])
    CodeChannel(channel:, repo:) ->
      json.object([
        #("kind", json.string("code_channel")),
        #("channel", json.string(channel)),
        #("repo", json.string(repo)),
      ])
    Archived(repo:) ->
      json.object([
        #("kind", json.string("archived")),
        #("repo", json.string(repo)),
      ])
  }
}

pub fn decoder() -> decode.Decoder(Venue) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "thread_only" -> {
      use repo <- decode.optional_field("repo", "", decode.string)
      decode.success(ThreadOnly(repo:))
    }
    "code_channel" -> {
      use channel <- decode.field("channel", decode.string)
      use repo <- decode.field("repo", decode.string)
      decode.success(CodeChannel(channel:, repo:))
    }
    "archived" -> {
      use repo <- decode.field("repo", decode.string)
      decode.success(Archived(repo:))
    }
    _ -> decode.success(Thread)
  }
}
