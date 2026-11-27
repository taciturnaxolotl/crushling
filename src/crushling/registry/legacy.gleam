//// Threads from before keys carried the workspace live under their old key,
//// `channel-ts`: their row in the store, their directory under the root,
//// and maybe their container. Only the workspace the bridge served then,
//// the one of `SLACK_BOT_TOKEN`, has such threads. `migrate` moves them all
//// to their new keys once, when the bridge starts.

import crushling/agents.{type Agents}
import crushling/key
import crushling/store.{type Store}
import crushling/store/threads
import crushling/sys
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// Move every thread of workspace `team` still under its old key to its new
/// key: the row, unless the new key has one; the directory (and the old
/// container goes), unless the new key has one. Each step is safe to repeat,
/// so a move cut short finishes on the next start. Returns the new keys of
/// threads that couldn't be moved, which must not start afresh and hide
/// their old work.
pub fn migrate(
  store: Store,
  owner: Agents,
  root: String,
  team: String,
) -> Set(String) {
  let rows = case threads.team_threads(store, team) {
    Ok(rows) ->
      list.filter_map(rows, fn(row) {
        case key.parse(row.key) {
          Ok(_) -> Error(Nil)
          Error(Nil) -> Ok(#(row.key, row.channel, row.thread_ts))
        }
      })
    Error(reason) -> {
      sys.warn("crushling: listing threads to move failed: " <> reason)
      []
    }
  }
  let dirs =
    sys.list_dir(root)
    |> result.unwrap([])
    |> list.filter_map(fn(name) {
      case key.parse(name), string.split_once(name, "-") {
        Error(Nil), Ok(#(channel, ts)) if channel != "" ->
          case is_ts(ts) && agents.exists(owner, name) {
            True -> Ok(#(name, channel, ts))
            False -> Error(Nil)
          }
        _, _ -> Error(Nil)
      }
    })
  list.append(rows, dirs)
  |> list.unique
  |> list.fold(set.new(), fn(stranded, old) {
    let #(old, channel, ts) = old
    let new = key.new(team, channel, ts) |> key.to_string
    case move(store, owner, team, old, new) {
      Ok(Nil) -> stranded
      Error(reason) -> {
        sys.warn(
          "crushling: moving " <> old <> " to " <> new <> " failed: " <> reason,
        )
        set.insert(stranded, new)
      }
    }
  })
}

fn move(
  store: Store,
  owner: Agents,
  team: String,
  old: String,
  new: String,
) -> Result(Nil, String) {
  // An old row of another workspace (a channel shared with it) isn't this
  // one's to take, and neither is its directory.
  use old_row <- result.try(case threads.thread(store, old) {
    Ok(Some(thread)) -> Ok(Some(thread.team == "" || thread.team == team))
    Ok(None) -> Ok(None)
    Error(reason) -> Error("reading " <> old <> ": " <> reason)
  })
  use new_row <- result.try(
    threads.thread(store, new)
    |> result.map(option.is_some)
    |> result.map_error(fn(reason) { "reading " <> new <> ": " <> reason }),
  )
  let ours = old_row != Some(False)
  let move_row = old_row == Some(True) && !new_row
  let move_dir = ours && agents.exists(owner, old) && !agents.exists(owner, new)
  case move_row || move_dir {
    False -> Ok(Nil)
    True -> {
      sys.info("crushling: moving " <> old <> " to " <> new)
      use _ <- result.try(case move_dir {
        True -> agents.rekey(owner, old, new)
        False -> Ok(Nil)
      })
      case move_row {
        True ->
          threads.rename_thread(store, old:, new:, team:)
          |> result.replace(Nil)
        False -> Ok(Nil)
      }
    }
  }
}

/// Whether `text` looks like a Slack message ts, so a directory such as a
/// code channel's `<channel>-code` isn't taken for a thread's.
fn is_ts(text: String) -> Bool {
  text != ""
  && string.to_graphemes(text)
  |> list.all(fn(c) { string.contains("0123456789.", c) })
}
