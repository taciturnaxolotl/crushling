//// Slack's text, read: a message turned into a prompt, ts values, and what a
//// prompt says of the messages it catches up on.

import crushling/attachments.{type Attachment, type Earlier, Earlier}
import crushling/commands
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import slackline/message

/// Turn the text of a Slack message into a prompt: drop mentions of the bot,
/// unwrap links, and undo Slack's escaping.
pub fn prompt_text(text: String, bot_user: String) -> String {
  text
  |> string.replace("<@" <> bot_user <> ">", "")
  |> unwrap_links
  |> string.replace("&lt;", "<")
  |> string.replace("&gt;", ">")
  |> string.replace("&amp;", "&")
  |> string.trim
}

/// `<https://x|label>` and `<https://x>` become `https://x`. Mentions and
/// channel references (`<@U1>`, `<#C1|name>`) are left as they are.
fn unwrap_links(text: String) -> String {
  case string.split(text, "<") {
    [] -> text
    [first, ..rest] ->
      list.fold(rest, first, fn(acc, part) {
        case string.split_once(part, ">") {
          Ok(#(inside, after)) ->
            case is_link(inside) {
              True -> {
                let url = case string.split_once(inside, "|") {
                  Ok(#(url, _)) -> url
                  Error(Nil) -> inside
                }
                acc <> url <> after
              }
              False -> acc <> "<" <> part
            }
          Error(Nil) -> acc <> "<" <> part
        }
      })
  }
}

fn is_link(inside: String) -> Bool {
  string.starts_with(inside, "http://")
  || string.starts_with(inside, "https://")
  || string.starts_with(inside, "mailto:")
}

/// A Slack ts as seconds.
pub fn ts_value(ts: String) -> Float {
  case float.parse(ts) {
    Ok(value) -> value
    Error(Nil) ->
      int.parse(ts) |> result.map(int.to_float) |> result.unwrap(0.0)
  }
}

/// " [attached: a.png, b.txt]" for a message's files, or "".
pub fn files_note(files: List(Attachment)) -> String {
  case files {
    [] -> ""
    files ->
      " [attached: "
      <> string.join(list.map(files, fn(file) { file.name }), ", ")
      <> "]"
  }
}

/// What a prompt says of what came before it, and the earlier files.
pub type CatchUp {
  CatchUp(text: String, earlier: List(Earlier))
}

pub const nothing = CatchUp("", [])

/// What happened in a conversation between `after_ts` (exclusive; "" for
/// the start) and `before_ts` (exclusive), from people, as context for the
/// next prompt, given its `messages` oldest first. The last `limit`
/// messages are kept; `##` asides are left out.
pub fn catch_up(
  messages: List(message.Message),
  in_thread: Bool,
  after_ts: String,
  before_ts: String,
  bot_user: String,
  limit: Int,
) -> CatchUp {
  let after = case after_ts {
    "" -> -1.0
    ts -> ts_value(ts)
  }
  let before = ts_value(before_ts)
  let kept =
    list.filter_map(messages, fn(message) {
      case message.user, message.text, message.ts, message.bot_id {
        Some(user), Some(text), Some(ts), None if user != bot_user -> {
          let at = ts_value(ts)
          case at >. after && at <. before, commands.parse(text) {
            True, commands.NotACommand -> {
              let files = attachments.from_slack(message.files)
              Ok(#(
                "[<@"
                  <> user
                  <> ">] "
                  <> prompt_text(text, bot_user)
                  <> files_note(files),
                Earlier(ts, files),
              ))
            }
            _, _ -> Error(Nil)
          }
        }
        _, _, _, _ -> Error(Nil)
      }
    })
  let count = list.length(kept)
  let kept = list.drop(kept, int.max(count - limit, 0))
  let lines = list.map(kept, fn(pair) { pair.0 })
  let earlier =
    list.filter_map(kept, fn(pair) {
      case pair.1 {
        Earlier(files: [], ..) -> Error(Nil)
        with_files -> Ok(with_files)
      }
    })
  let where = case in_thread {
    False -> "Slack channel"
    True -> "Slack thread"
  }
  let heading = case after_ts {
    "" -> "Earlier in this " <> where
    _ -> "New in this " <> where <> " since your last turn"
  }
  let text = case lines {
    [] -> ""
    lines ->
      heading
      <> case count > limit {
        True -> " (the last " <> int.to_string(limit) <> " messages)"
        False -> ""
      }
      <> ":\n"
      <> string.join(lines, "\n")
  }
  CatchUp(text:, earlier:)
}
