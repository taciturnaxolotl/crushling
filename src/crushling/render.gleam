//// Turn a run into Markdown for Slack: a live progress view while it runs,
//// and the final reply split into messages that fit Slack's limits.

import crushling/run.{type Run}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

/// Slack's markdown block accepts up to 12,000 characters; stay well under.
pub const message_limit = 11_000

const tools_shown = 3

pub fn progress(run: Run, limit: Int) -> String {
  let status = case list.reverse(run.tools) {
    [] -> "_thinking…_"
    recent ->
      list.take(recent, tools_shown)
      |> list.reverse
      |> list.map(tool_line)
      |> string.join("\n")
  }
  let hidden = list.length(run.tools) - tools_shown
  let status = case hidden > 0 {
    True -> "_" <> int.to_string(hidden) <> " earlier tool calls_\n" <> status
    False -> status
  }
  case run.text(run) {
    "" -> status
    text -> tail(text, limit - string.length(status) - 2) <> "\n\n" <> status
  }
}

fn tool_line(tool: run.Tool) -> String {
  let mark = case tool.status {
    run.Running -> "▸"
    run.Succeeded -> "✓"
    run.Failed -> "✗"
  }
  let summary = case tool.summary {
    "" -> ""
    summary -> " `" <> string.replace(summary, "`", "'") <> "`"
  }
  "> " <> mark <> " " <> tool.name <> summary
}

/// The end of `text`, cut at a line boundary, with any open code fence
/// reopened so the markdown still renders.
fn tail(text: String, limit: Int) -> String {
  case string.length(text) <= limit {
    True -> text
    False -> {
      let budget = int.max(0, limit - 8)
      let cut = string.slice(text, string.length(text) - budget, budget)
      let cut = case string.split_once(cut, "\n") {
        Ok(#(_, rest)) -> rest
        Error(Nil) -> cut
      }
      let prefix = case odd_fences(text) != odd_fences(cut) {
        True -> "```\n"
        False -> ""
      }
      "…\n" <> prefix <> cut
    }
  }
}

fn odd_fences(text: String) -> Bool {
  int.is_odd(fence_count(text))
}

fn fence_count(text: String) -> Int {
  string.split(text, "\n")
  |> list.count(fn(line) { string.starts_with(string.trim_start(line), "```") })
}

/// The final reply: the assistant's text and a footer naming the changed
/// files, split into messages.
pub fn final(run: Run, changed: List(String)) -> List(String) {
  let body = case run.outcome {
    Some(run.Completed(text)) ->
      case run.text(run) {
        "" -> text
        streamed -> streamed
      }
    Some(run.Errored(error)) ->
      run.text(run) <> "\n\n:warning: run failed: " <> error
    Some(run.Cancelled) -> run.text(run) <> "\n\n_cancelled_"
    None -> run.text(run)
  }
  let footer = footer(run, changed)
  let full = case string.trim(body), footer {
    "", "" -> "_no reply_"
    body, "" -> body
    "", footer -> footer
    body, footer -> body <> "\n\n" <> footer
  }
  chunk(full, message_limit)
}

fn footer(run: Run, changed: List(String)) -> String {
  let tools = list.length(run.tools)
  let files = list.map(changed, fn(path) { "`" <> path <> "`" })
  let parts =
    [
      case tools {
        0 -> ""
        1 -> "1 tool call"
        n -> int.to_string(n) <> " tool calls"
      },
      case files {
        [] -> ""
        files -> "changed " <> string.join(files, ", ")
      },
    ]
    |> list.filter(fn(part) { part != "" })
  case parts {
    [] -> ""
    parts -> "_" <> string.join(parts, " · ") <> "_"
  }
}

/// Split text into pieces of at most `limit` characters, preferring
/// paragraph then line boundaries, and closing and reopening code fences
/// that a split would cut through.
pub fn chunk(text: String, limit: Int) -> List(String) {
  chunk_loop(text, limit, False, [])
}

fn chunk_loop(
  text: String,
  limit: Int,
  reopen: Bool,
  acc: List(String),
) -> List(String) {
  let text = case reopen {
    True -> "```\n" <> text
    False -> text
  }
  case string.length(text) <= limit {
    True -> list.reverse([text, ..acc])
    False -> {
      let room = limit - 4
      let window = string.slice(text, 0, room)
      let at = case last_index(window, "\n\n"), last_index(window, "\n") {
        Ok(i), _ if i > room / 2 -> i
        _, Ok(i) if i > room / 2 -> i
        _, _ -> room
      }
      let head = string.slice(text, 0, at)
      let rest = string.drop_start(text, at) |> string.trim_start
      let open = odd_fences(head)
      let head = case open {
        True -> head <> "\n```"
        False -> head
      }
      chunk_loop(rest, limit, open, [string.trim_end(head), ..acc])
    }
  }
}

fn last_index(haystack: String, needle: String) -> Result(Int, Nil) {
  case string.split(haystack, needle) {
    [_] -> Error(Nil)
    parts -> {
      let assert Ok(last) = list.last(parts)
      Ok(string.length(haystack) - string.length(last) - string.length(needle))
    }
  }
}
