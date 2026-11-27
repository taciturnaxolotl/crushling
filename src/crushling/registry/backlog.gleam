//// A thread's waiting messages, prepared into prompts one at a time so each
//// catches up from where the last left off.

import crushling/attachments
import crushling/meta.{Meta}
import crushling/registry/core.{type State, Prepared, put, set_meta}
import crushling/registry/entry.{
  type Entry, Asleep, Entry, Live, Starting, Stopping, Turn, already_read,
  map_turn, preparing,
}
import crushling/registry/incoming.{type Incoming}
import crushling/registry/prompt
import crushling/slack/text
import crushling/sys
import crushling/thread
import gleam/dict
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/option.{Some}

/// Prepare the next waiting message on its own process, since it talks to Slack.
pub fn pump(state: State(msg), key: String) -> State(msg) {
  case dict.get(state.threads, key) {
    Ok(Entry(backlog: [next, ..rest], ..) as entry) ->
      case preparing(entry) {
        True -> state
        False -> pump_next(state, key, entry, next, rest)
      }
    _ -> state
  }
}

fn pump_next(
  state: State(msg),
  key: String,
  entry: Entry,
  next: Incoming,
  rest: List(Incoming),
) -> State(msg) {
  case already_read(Some(entry), next.ts) {
    // Caught up on by an earlier prompt while it waited.
    True -> {
      let entry = Entry(..entry, backlog: rest)
      put(state, key, entry)
      |> pump(key)
    }
    False -> prepare_next(state, key, entry, next, rest)
  }
}

fn prepare_next(
  state: State(msg),
  key: String,
  entry: Entry,
  next: Incoming,
  rest: List(Incoming),
) -> State(msg) {
  case entry.agent {
    Live(..) -> {
      let config = state.config
      let tell = core.teller(state)
      let cursor = entry.meta.cursor
      // A code channel is caught up on as a whole, not by thread.
      let catch_up = case next.channel == entry.channel {
        True -> next.thread_ts
        False -> ""
      }
      process.spawn_unlinked(fn() {
        let keep = attachments.Keep(config.root, key)
        let prompt =
          prompt.build(config.workspace, keep, next, cursor, catch_up)
        tell(Prepared(key, next.ts, prompt))
      })
      let entry =
        Entry(..entry, backlog: rest)
        |> map_turn(fn(turn) { Turn(..turn, preparing: True) })
      put(state, key, entry)
    }
    Asleep | Starting(..) | Stopping(..) -> state
  }
}

/// A prompt is ready: send it, and move the thread's cursor to its message.
pub fn prepared(
  state: State(msg),
  key: String,
  ts: String,
  prompt: thread.Message,
) -> State(msg) {
  case dict.get(state.threads, key) {
    Ok(Entry(agent: Live(thread:, ..), ..) as entry) -> {
      // How long the person waited for their message to reach the agent.
      let waited = sys.system_ms() - float.round(text.ts_value(ts) *. 1000.0)
      sys.info(
        "crushling: "
        <> key
        <> " prompt ready "
        <> int.to_string(waited)
        <> "ms after it was sent",
      )
      process.send(thread, prompt)
      let entry =
        map_turn(entry, fn(turn) {
          Turn(..turn, in_flight: turn.in_flight + 1, preparing: False)
        })
      put(state, key, entry)
      |> set_meta(key, entry, Meta(..entry.meta, cursor: ts))
      |> pump(key)
    }
    _ -> state
  }
}
