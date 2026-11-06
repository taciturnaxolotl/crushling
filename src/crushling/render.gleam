//// How a run looks in Slack, following gorkie's layout:
////
//// - while it works, a plan card with one task row per tool call;
//// - when it finishes, the answer as its own messages, split to fit, with a
////   line naming the files it changed;
//// - when it fails, a note saying whether what is above is partial.
////
//// Everything here is pure; `crushling/slack` turns it into blocks.

import crushling/run.{type Run}
import crushling/snapshot
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Slack's markdown block accepts up to 12,000 characters; stay well under.
pub const message_limit = 11_000

/// Rows past this many are folded into one, as gorkie does; a plan block
/// with too many tasks is rejected.
const max_tasks = 40

/// Plan task details and outputs are kept to a short line.
const line_limit = 72

pub type TaskStatus {
  InProgress
  Complete
  Failed
}

pub type Task {
  Task(
    id: String,
    title: String,
    status: TaskStatus,
    details: String,
    output: String,
  )
}

pub type Plan {
  Plan(title: String, tasks: List(Task))
}

/// The plan card, or `None` before the run has done anything worth showing.
pub fn plan(run: Run, root: String) -> Option(Plan) {
  case run.tools {
    [] -> None
    tools -> {
      let count = list.length(tools)
      let title = case run.outcome {
        None -> "Working"
        Some(run.Completed(_)) -> "Done · " <> steps(count)
        Some(run.Errored(_)) -> "Failed · " <> steps(count)
        Some(run.Cancelled) -> "Stopped · " <> steps(count)
      }
      let tasks = list.map(tools, task(_, root, run.outcome))
      Some(Plan(title:, tasks: fold(tasks)))
    }
  }
}

fn steps(count: Int) -> String {
  case count {
    1 -> "1 step"
    n -> int.to_string(n) <> " steps"
  }
}

/// Keep the most recent rows and fold the earlier ones into a single row.
fn fold(tasks: List(Task)) -> List(Task) {
  let count = list.length(tasks)
  case count > max_tasks {
    False -> tasks
    True -> {
      let hidden = count - max_tasks + 1
      let earlier =
        Task(
          id: "earlier",
          title: "Earlier steps",
          status: Complete,
          details: "",
          output: int.to_string(hidden) <> " earlier steps",
        )
      [earlier, ..list.drop(tasks, hidden)]
    }
  }
}

fn task(tool: run.Tool, root: String, outcome: Option(run.Outcome)) -> Task {
  let status = case tool.status, outcome {
    run.Succeeded, _ -> Complete
    run.Failed, _ -> Failed
    // A tool still running when the run ended never will finish.
    run.Running, Some(run.Completed(_)) -> Complete
    run.Running, Some(_) -> Failed
    run.Running, None -> InProgress
  }
  let arg =
    tool.summary
    |> string.replace(root <> "/", "")
    |> string.replace(root, ".")
    |> first_line
    |> clip
  // A described call reads as a sentence and needs nothing under it; a
  // generic title ("Reading a file") gets its argument as details.
  let #(title, details) = case tool.description {
    "" -> #(title(tool.name), arg)
    description -> #(string.capitalise(clip(description)), "")
  }
  Task(id: tool.id, title:, status:, details:, output: output(tool, status))
}

/// What a tool is doing, in words rather than its name.
pub fn title(name: String) -> String {
  case name {
    "bash" -> "Running a command"
    "view" -> "Reading a file"
    "write" -> "Writing a file"
    "edit" | "multiedit" -> "Editing a file"
    "ls" -> "Listing files"
    "glob" -> "Finding files"
    "grep" | "rg" -> "Searching the code"
    "fetch" | "agentic_fetch" | "web_fetch" -> "Reading the web"
    "web_search" -> "Searching the web"
    "download" -> "Downloading"
    "sourcegraph" -> "Searching public code"
    "agent" | "agent_dispatch" -> "Running a sub-agent"
    "todos" -> "Updating the plan"
    "job_output" | "job_kill" -> "Checking a background job"
    _ ->
      case string.starts_with(name, "lsp_"), string.starts_with(name, "mcp_") {
        True, _ -> "Asking the language server"
        _, True -> humanize(string.drop_start(name, 4))
        _, _ -> humanize(name)
      }
  }
}

fn humanize(name: String) -> String {
  case string.replace(name, "_", " ") |> string.trim {
    "" -> "Using a tool"
    words -> string.capitalise(words)
  }
}

/// Only a failure says anything under its row: the first line of the
/// error. Successful output is the agent's to summarise in its answer.
fn output(tool: run.Tool, status: TaskStatus) -> String {
  case status {
    Failed -> first_line(tool.output) |> clip
    _ -> ""
  }
}

fn first_line(text: String) -> String {
  text
  |> string.replace("<result>", "")
  |> string.replace("</result>", "")
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.find(fn(line) { line != "" && !string.starts_with(line, "<") })
  |> option.from_result
  |> option.unwrap("")
}

fn clip(text: String) -> String {
  let text = string.trim(text)
  case string.length(text) > line_limit {
    True -> string.slice(text, 0, line_limit - 1) <> "…"
    False -> text
  }
}

/// The answer, split into messages. Empty when there is nothing to say.
pub fn answer(run: Run) -> List(String) {
  let text = case run.text(run), run.outcome {
    "", Some(run.Completed(text)) -> string.trim(text)
    streamed, _ -> streamed
  }
  case text {
    "" -> []
    text -> chunk(text, message_limit)
  }
}

/// A closing note, when the run didn't simply finish. `answered` is whether
/// any of the answer was posted.
pub fn note(run: Run, answered: Bool) -> Option(String) {
  let did_work = run.tools != []
  case run.outcome {
    Some(run.Cancelled) -> Some("_stopped._")
    Some(run.Errored(reason)) -> {
      let #(cause, advice) = explain(reason)
      let where = case answered, did_work {
        True, _ -> " The reply above may be partial."
        False, True -> " The steps above show what got done."
        False, False -> ""
      }
      Some(
        "_"
        <> cause
        <> "."
        <> where
        <> " "
        <> advice
        <> "_\n> `"
        <> clip_reason(reason)
        <> "`",
      )
    }
    Some(run.Completed(_)) if !answered && !did_work -> Some("_no reply._")
    _ -> None
  }
}

/// What went wrong in words, and what to do about it, from an error as
/// crush reports it. Crush passes provider errors through, so this goes by
/// what the text contains.
pub fn explain(reason: String) -> #(String, String) {
  let text = string.lowercase(reason)
  let has = fn(needles) { list.any(needles, string.contains(text, _)) }
  case Nil {
    _ if text == "lost the connection mid-run" -> #(
      "Lost touch with the agent partway through",
      "Send a follow-up to carry on.",
    )
    _ ->
      case
        has([
          "prompt is too long",
          "context length",
          "context_length",
          "too many tokens",
          "maximum context",
        ]),
        has([
          "credit",
          "billing",
          "insufficient_quota",
          "payment required",
          "402",
        ]),
        has(["rate limit", "rate_limit", "429", "too many requests"]),
        has([
          "unauthorized",
          "authentication",
          "invalid token",
          "invalid api key",
          "401",
          "token is expired",
          "re-authenticate",
        ]),
        has(["claude_code_version_too_old"]),
        has([
          "overloaded",
          "529",
          "503",
          "502",
          "500 internal",
          "internal server error",
          "bad gateway",
          "service unavailable",
        ]),
        has([
          "timeout",
          "timed out",
          "deadline exceeded",
          "connection reset",
          "eof",
        ]),
        has(["max_tokens", "invalid_request", "bad request", "400"])
      {
        True, _, _, _, _, _, _, _ -> #(
          "The conversation got too long for the model",
          "Start a new thread to carry on.",
        )
        _, True, _, _, _, _, _, _ -> #(
          "The model provider is out of credits",
          "Top up the account, then send a follow-up to carry on.",
        )
        _, _, True, _, _, _, _, _ -> #(
          "The model provider is rate limiting us",
          "Wait a minute, then send a follow-up to carry on.",
        )
        _, _, _, True, _, _, _, _ -> #(
          "The model provider rejected crushling's login",
          "Someone needs to sign crushling in again.",
        )
        _, _, _, _, True, _, _, _ -> #(
          "Anthropic now wants a newer Claude Code version",
          "Raise CRUSHLING_CLAUDE_VERSION and restart crushling.",
        )
        _, _, _, _, _, True, _, _ -> #(
          "The model provider is having trouble",
          "Try again in a bit.",
        )
        _, _, _, _, _, _, True, _ -> #(
          "The connection to the model provider dropped",
          "Send a follow-up to carry on.",
        )
        _, _, _, _, _, _, _, True -> #(
          "The model provider refused the request",
          "This is likely a configuration problem; check the model settings.",
        )
        _, _, _, _, _, _, _, _ -> #(
          "Something went wrong",
          "Send a follow-up to try again.",
        )
      }
  }
}

/// The raw error, on one line and short, for a code span.
fn clip_reason(reason: String) -> String {
  let reason =
    reason
    |> string.replace("\n", " ")
    |> string.replace("`", "'")
    |> string.trim
  case string.length(reason) > 200 {
    True -> string.slice(reason, 0, 199) <> "…"
    False -> reason
  }
}

/// A line naming what changed, with line counts.
pub fn changes(changes: List(snapshot.Change)) -> Option(String) {
  case changes {
    [] -> None
    changes -> {
      let shown = list.take(changes, 8)
      let more = list.length(changes) - list.length(shown)
      let items =
        list.map(shown, fn(change) {
          let counts = case change.added, change.removed {
            Ok(added), Ok(removed) ->
              " +" <> int.to_string(added) <> " −" <> int.to_string(removed)
            _, _ -> " (binary)"
          }
          "`" <> string.replace(change.path, "`", "'") <> "`" <> counts
        })
      let items = case more > 0 {
        True -> list.append(items, ["and " <> int.to_string(more) <> " more"])
        False -> items
      }
      Some("_changed " <> string.join(items, ", ") <> "_")
    }
  }
}

/// The same plan as plain markdown, for workspaces that reject plan blocks.
pub fn plan_markdown(plan: Plan) -> String {
  let rows =
    list.map(plan.tasks, fn(task) {
      let mark = case task.status {
        InProgress -> "▸"
        Complete -> "✓"
        Failed -> "✗"
      }
      let details = case task.details {
        "" -> ""
        details -> " `" <> string.replace(details, "`", "'") <> "`"
      }
      "> " <> mark <> " " <> task.title <> details
    })
  "*"
  <> plan.title
  <> "*\n"
  <> string.join(list.take(list.reverse(rows), 12) |> list.reverse, "\n")
}

/// Split text into pieces of at most `limit` characters, preferring
/// paragraph then line boundaries, and closing and reopening code fences
/// that a split would cut through.
pub fn chunk(text: String, limit: Int) -> List(String) {
  chunk_loop(text, limit, None, [])
}

fn chunk_loop(
  text: String,
  limit: Int,
  reopen: Option(String),
  acc: List(String),
) -> List(String) {
  let text = case reopen {
    Some(fence) -> fence <> "\n" <> text
    None -> text
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
      let open = open_fence(head)
      let head = case open {
        Some(_) -> head <> "\n```"
        None -> head
      }
      chunk_loop(rest, limit, open, [string.trim_end(head), ..acc])
    }
  }
}

/// The fence line (with its language) left open at the end of `text`.
fn open_fence(text: String) -> Option(String) {
  string.split(text, "\n")
  |> list.fold(None, fn(open, line) {
    let trimmed = string.trim_start(line)
    case string.starts_with(trimmed, "```"), open {
      True, None -> Some(string.trim(trimmed))
      True, Some(_) -> None
      False, _ -> open
    }
  })
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
