//// How a run looks in Slack, following gorkie's layout:
////
//// - while it works, a plan card with one task row per tool call;
//// - when it finishes, the answer as its own messages, split to fit, with a
////   line naming the files it changed;
//// - when it fails, a note saying whether what is above is partial.
////
//// Everything here is pure; `crushling/slack/sink` turns it into blocks.

import crushling/run.{type Run}
import crushling/text
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
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
    _ -> Some(Plan(title: progress_title(run), tasks: tasks(run, root)))
  }
}

/// The plan card's title for the run as it stands: "Working" while it runs,
/// then how much it did.
pub fn progress_title(run: Run) -> String {
  let count = list.length(run.tools)
  case run.outcome {
    // What the agent says it's doing, on one line, else "Working".
    None ->
      case run.narration(run) |> first_line |> string.trim {
        "" -> "Working"
        said -> clip(said)
      }
    Some(run.Completed(_)) -> "Done · " <> steps(count)
    Some(run.Errored(_)) -> "Failed · " <> steps(count)
    Some(run.Cancelled) -> "Stopped · " <> steps(count)
  }
}

/// One row per tool call, the most recent kept and earlier ones folded.
pub fn tasks(run: Run, root: String) -> List(Task) {
  fold(rows(run, root))
}

/// One task per tool call, none folded away: a streamed reply carries on in
/// a new message when one holds too many.
pub fn all_tasks(run: Run, root: String) -> List(Task) {
  rows(run, root)
}

fn rows(run: Run, root: String) -> List(Task) {
  list.map(run.tools, task(_, root, run.outcome))
}

/// "1 step", "5 steps".
pub fn steps(count: Int) -> String {
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
    run.Failed, None -> Failed
    run.Failed, Some(run.Errored(_)) -> Failed
    // A command that failed and was worked around isn't how the run ended,
    // so it doesn't leave a failed row, and with it Slack's warning badge,
    // on a run that finished fine.
    run.Failed, Some(run.Completed(_)) -> Complete
    run.Failed, Some(run.Cancelled) -> Failed
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
  let details = case tool.description {
    "" -> arg
    _ -> ""
  }
  Task(
    id: tool.id,
    title: tool_title(tool),
    status:,
    details:,
    output: output(tool, status),
  )
}

/// A tool call's row title: what the agent said it is for, else what the
/// tool does.
pub fn tool_title(tool: run.Tool) -> String {
  case tool.description {
    "" -> title(tool.name)
    description -> string.capitalise(clip(description))
  }
}

/// How a whole run stands, as a row for it.
pub fn run_status(run: Run) -> TaskStatus {
  case run.outcome {
    None -> InProgress
    Some(run.Completed(_)) -> Complete
    Some(_) -> Failed
  }
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

fn clip(line: String) -> String {
  text.clip(line, line_limit)
}

/// The reply as one piece of markdown: what the agent said, or, when it said
/// nothing, what crush reported it finished with.
pub fn reply(run: Run) -> String {
  case run.text(run), run.outcome {
    "", Some(run.Completed(text)) -> string.trim(text)
    streamed, _ -> streamed
  }
}

/// The answer, split into messages. Empty when there is nothing to say.
pub fn answer(run: Run) -> List(String) {
  case reply(run) {
    "" -> []
    text -> chunk(text, message_limit)
  }
}

/// A closing note, when the run didn't simply finish. `answered` is whether
/// any of the answer was posted. A run someone stopped gets none: they know.
pub fn note(run: Run, answered: Bool) -> Option(String) {
  let did_work = run.tools != []
  case run.outcome {
    Some(run.Cancelled) -> None
    Some(run.Errored(reason)) -> {
      let failure = explain(reason)
      let where = case answered {
        True -> " The reply above may be partial."
        False -> ""
      }
      let next = case failure.advice, failure.retry {
        "", _ -> " Send a follow-up to try again."
        advice, False -> " " <> advice
        advice, True -> " " <> advice <> " Send a follow-up to try again."
      }
      let quoted = case failure.quote {
        True -> "\n> `" <> clip_reason(reason) <> "`"
        False -> ""
      }
      Some("_" <> failure.cause <> "." <> where <> next <> "_" <> quoted)
    }
    Some(run.Completed(_)) if !answered && !did_work ->
      Some("_The agent finished without replying._")
    _ -> None
  }
}

/// Why a run failed, in words for the people in the thread.
pub type Failure {
  Failure(
    cause: String,
    /// What to do before trying again, or "" for nothing.
    advice: String,
    /// Whether a follow-up is the way to try again.
    retry: Bool,
    /// Whether crush's own error text adds anything worth quoting.
    quote: Bool,
  )
}

/// What went wrong, from an error as crush reports it. Crush passes provider
/// errors through as text, so this goes by what the text says: telling
/// phrases first, then HTTP statuses, which count only as whole words so a
/// token count can't pass for one.
pub fn explain(reason: String) -> Failure {
  let text = string.lowercase(reason)
  let words = words(text)
  let says = fn(phrases) {
    fn() { list.any(phrases, string.contains(text, _)) }
  }
  let status = fn(codes) { fn() { list.any(codes, list.contains(words, _)) } }
  let checks = [
    #(fn() { text == "lost the connection mid-run" }, lost_agent),
    #(
      says([
        "prompt is too long", "context length", "context_length",
        "context window", "too many tokens", "maximum context",
      ]),
      too_long,
    ),
    #(
      says([
        "credit balance", "out of credits", "insufficient credits",
        "insufficient_quota", "billing", "payment required",
      ]),
      out_of_credits,
    ),
    #(says(["rate limit", "rate_limit", "too many requests"]), rate_limited),
    #(
      says([
        "unauthorized", "authentication", "invalid token", "invalid api key",
        "invalid x-api-key", "token is expired",
      ]),
      key_rejected,
    ),
    #(
      says([
        "overloaded", "internal server error", "bad gateway",
        "service unavailable", "gateway timeout",
      ]),
      server_error,
    ),
    #(
      says([
        "timed out", "timeout", "deadline exceeded", "connection reset",
        "connection refused",
      ]),
      dropped,
    ),
    #(status(["eof"]), dropped),
    #(
      says(["invalid_request", "invalid request", "bad request", "max_tokens"]),
      invalid,
    ),
    #(status(["429"]), rate_limited),
    #(status(["402"]), out_of_credits),
    #(status(["401", "403"]), key_rejected),
    #(status(["500", "502", "503", "504", "529"]), server_error),
    #(status(["400", "413", "422"]), invalid),
  ]
  list.find(checks, fn(check) { check.0() })
  |> result.map(fn(check) { check.1 })
  |> result.unwrap(unrecognized)
}

/// The text split into runs of letters and digits.
fn words(text: String) -> List(String) {
  string.to_graphemes(text)
  |> list.map(fn(c) {
    case string.contains("abcdefghijklmnopqrstuvwxyz0123456789_", c) {
      True -> c
      False -> " "
    }
  })
  |> string.concat
  |> string.split(" ")
  |> list.filter(fn(word) { word != "" })
}

const lost_agent =
  Failure("The connection to the agent dropped mid-run", "", True, False)

const too_long =
  Failure(
    "The conversation exceeded the model's context window",
    "Start a new thread to carry on.",
    False,
    False,
  )

const out_of_credits =
  Failure(
    "The model provider account is out of credits",
    "Ask whoever runs crushling to top it up.",
    False,
    False,
  )

const rate_limited =
  Failure(
    "The model provider rate-limited the request",
    "Wait a minute.",
    True,
    False,
  )

const key_rejected =
  Failure(
    "The model provider rejected crushling's API key",
    "Ask whoever runs crushling to check it.",
    False,
    True,
  )

const server_error =
  Failure(
    "The model provider returned a server error",
    "Wait a bit.",
    True,
    False,
  )

const dropped =
  Failure("The connection to the model provider dropped", "", True, False)

const invalid =
  Failure(
    "The model provider rejected the request as invalid",
    "Try another model with `!model`, or ask whoever runs crushling to check the model settings.",
    False,
    True,
  )

const unrecognized =
  Failure("The run failed with an unrecognized error", "", True, True)

fn clip_reason(reason: String) -> String {
  reason
  |> string.replace("\n", " ")
  |> string.replace("`", "'")
  |> text.clip(200)
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
