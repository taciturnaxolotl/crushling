//// Tidying up after quiet threads, hourly. A code channel quiet for a week
//// is archived, the same as `!done`, keeping its workspace so the work can
//// be picked up from the original thread. A thread quiet for 30 days, in a
//// code channel or not, loses its sandbox and workspace: whatever matters
//// is on GitHub by then, and its next message starts afresh.

import crushling/store
import crushling/venue
import gleam/list

pub type Action {
  /// Archive code channel `channel` of thread `key`, whose repository is in
  /// workspace directory `repo`.
  Archive(key: String, channel: String, repo: String)
  /// Remove the thread's sandbox and workspace.
  Forget(key: String)
}

/// How long a code channel stays open with nothing happening, in seconds.
pub const archive_after_s = 604_800

/// How long a thread's workspace is kept with nothing happening.
pub const forget_after_s = 2_592_000

pub const every_ms = 3_600_000

/// What to do with threads quiet since before `now - archive_after_s`,
/// each with when it last saw work (Unix seconds). `busy` threads (with an
/// agent up) are left alone; `exists` says whether a workspace is left to
/// remove.
pub fn plan(
  threads: List(#(store.Thread, Int)),
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
