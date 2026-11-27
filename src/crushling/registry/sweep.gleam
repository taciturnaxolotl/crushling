//// Tidying up after quiet threads, hourly. A code channel quiet for a week
//// is archived, the same as `!done`, keeping its workspace so the work can
//// be picked up from the original thread. A thread quiet for 30 days, in a
//// code channel or not, loses its sandbox and workspace: whatever matters
//// is on GitHub by then, and its next message starts afresh.

import crushling/agents
import crushling/registry/code_channel
import crushling/registry/core.{type State, known_entry}
import crushling/registry/entry.{Asleep, Entry}
import crushling/store/threads
import crushling/sys
import crushling/venue
import gleam/dict
import gleam/list
import gleam/option.{Some}

pub type Action {
  /// Archive thread `key`'s code `channel`; its repository is in workspace directory `repo`.
  Archive(key: String, channel: String, repo: String)
  /// Remove the thread's sandbox and workspace.
  Forget(key: String)
}

/// How long a code channel stays open with nothing happening, in seconds.
pub const archive_after_s = 604_800

/// How long a thread's workspace is kept with nothing happening.
pub const forget_after_s = 2_592_000

pub const every_ms = 3_600_000

/// Threads quiet since `now - archive_after_s`, with when they last saw work; `busy` ones are left alone.
pub fn plan(
  threads: List(#(threads.Thread, Int)),
  now: Int,
  busy: fn(String) -> Bool,
  exists: fn(String) -> Bool,
) -> List(Action) {
  list.flat_map(threads, fn(pair) {
    let #(thread, updated_at) = pair
    let key = thread.key
    let quiet = now - updated_at
    case busy(key) {
      True -> []
      False -> {
        let archive = case thread.meta.venue {
          venue.CodeChannel(channel:, repo:) if quiet >= archive_after_s -> [
            Archive(key:, channel:, repo:),
          ]
          _ -> []
        }
        let forget = case quiet >= forget_after_s && exists(key) {
          True -> [Forget(key)]
          False -> []
        }
        list.append(archive, forget)
      }
    }
  })
}

pub const archive_note =
  "_Quiet for a week, so this channel is archived. Mention me in the original thread to pick the work up again._"

/// Carry out the plan: Slack and the disk are touched off the registry.
pub fn run(state: State(msg)) -> State(msg) {
  let config = state.config
  let now = sys.system_ms() / 1000
  case threads.quiet_threads(config.store, config.team, now - archive_after_s) {
    Error(reason) -> {
      sys.warn("crushling: sweeping quiet threads: " <> reason)
      state
    }
    Ok(threads) -> {
      let busy = fn(key) {
        case dict.get(state.threads, key) {
          Ok(Entry(agent: Asleep, ..)) | Error(Nil) -> False
          Ok(_) -> True
        }
      }
      plan(threads, now, busy, config.launcher.exists)
      |> list.fold(state, fn(state, action) {
        case action {
          Archive(key:, channel:, repo:) ->
            known_entry(state, key)
            |> code_channel.archive(
              state,
              key,
              _,
              channel,
              repo,
              "",
              Some(archive_note),
            )
          Forget(key) -> {
            sys.info("crushling: clearing out " <> key <> ", quiet for a month")
            // The owner runs it after anything already asked for this key.
            agents.forget(state.agents, key, fn(result) {
              case result {
                Ok(Nil) -> Nil
                Error(reason) ->
                  sys.warn("crushling: clearing out " <> key <> ": " <> reason)
              }
            })
            state
          }
        }
      })
    }
  }
}
