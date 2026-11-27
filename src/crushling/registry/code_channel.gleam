//// Threads that moved their work to a code channel: opening one, linking
//// it to its thread, and archiving it once the work is done.

import crushling/conversation.{Conversation}
import crushling/meta.{Link, Meta}
import crushling/registry/core.{
  type State, Deferred, State, apply_tailnet, set_meta,
}
import crushling/registry/entry.{type Entry, Entry, is_quiet, tailnet_view}
import crushling/registry/incoming.{type Incoming}
import crushling/registry/lifecycle.{stop_agent}
import crushling/registry/links
import crushling/registry/say.{announce, whisper}
import crushling/registry/tailnet
import crushling/registry/text
import crushling/slack
import crushling/sys
import crushling/venue
import gleam/dict
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/set

/// How long a held-back message waits before it is tried again.
const defer_ms = 250

/// The most tries a held-back message gets.
const defer_attempts = 40

/// Thread `key` is about to open a code channel.
pub fn opening(state: State(msg), key: String) -> State(msg) {
  State(..state, opening: set.insert(state.opening, key))
}

/// Slack can post the request's copy in a new code channel before the thread names it, so hold unknown messages meanwhile.
pub fn hold(
  state: State(msg),
  incoming: Incoming,
  known: Option(Entry),
  attempts: Int,
  next: fn() -> State(msg),
) -> State(msg) {
  case known, set.is_empty(state.opening), attempts < defer_attempts {
    None, False, True -> {
      core.tell_after(state, defer_ms, Deferred(incoming, attempts + 1))
      state
    }
    _, _, _ -> next()
  }
}

/// Save the thread's new venue, linking a new code channel to it.
pub fn moved(
  state: State(msg),
  key: String,
  found: Result(Entry, Nil),
  to: venue.Venue,
  opened_ts: String,
) -> State(msg) {
  let state = State(..state, opening: set.delete(state.opening, key))
  case found, to {
    Ok(entry), venue.CodeChannel(channel:, ..) -> {
      let state = set_meta(state, key, entry, Meta(..entry.meta, venue: to))
      let link =
        Link(
          origin_channel: entry.channel,
          origin_ts: entry.thread_ts,
          opened_ts:,
        )
      let threads =
        dict.upsert(state.threads, key, fn(found) {
          let entry = option.unwrap(found, entry)
          Entry(..entry, summary_ts: "")
        })
      State(
        ..state,
        threads:,
        code_channels: links.add(state.code_channels, channel, link),
      )
    }
    Ok(entry), _ -> set_meta(state, key, entry, Meta(..entry.meta, venue: to))
    Error(Nil), _ -> state
  }
}

/// Archive a code channel, keeping its workspace: `note` goes first, `summary_ts` is kept, tailnet access ends.
pub fn archive(
  state: State(msg),
  key: String,
  entry: Option(Entry),
  channel: String,
  repo: String,
  summary_ts: String,
  note: Option(String),
) -> State(msg) {
  sys.info("crushling: archiving code channel " <> channel)
  let client = state.config.client
  process.spawn_unlinked(fn() {
    case note {
      Some(note) -> slack.say(client, Conversation(channel, None), note)
      None -> Nil
    }
    case slack.archive_code_channel(client, channel, summary_ts) {
      Ok(Nil) -> Nil
      Error(reason) ->
        sys.warn("crushling: archiving " <> channel <> " failed: " <> reason)
    }
  })
  case entry {
    Some(entry) ->
      tailnet.end(
        state.tailnets,
        key,
        tailnet_view(entry),
        text.tailnet_ended_with_channel,
      )
      |> apply_tailnet(state, key, Some(entry), _)
      |> set_meta(
        key,
        entry,
        Meta(..entry.meta, venue: venue.Archived(repo), tailnet: None),
      )
    None -> state
  }
}

/// `!done`: archive the code channel and stop the agent; a later message opens a new channel.
pub fn wrap_up(
  state: State(msg),
  incoming: Incoming,
  origin: Option(#(String, String)),
  key: String,
  entry: Entry,
) -> State(msg) {
  case entry.meta.venue, is_quiet(entry) {
    venue.CodeChannel(channel:, repo:), True -> {
      announce(state.config, incoming, origin, text.wrapping_up)
      // Its sink posts to the old channel; the next message starts anew.
      archive(state, key, Some(entry), channel, repo, entry.summary_ts, None)
      |> stop_agent(key)
    }
    venue.CodeChannel(..), False -> {
      whisper(state.config, incoming, text.still_working)
      state
    }
    _, _ -> {
      whisper(state.config, incoming, text.no_code_channel)
      state
    }
  }
}
