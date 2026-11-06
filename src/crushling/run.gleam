//// The pure state of one agent run as seen from a Slack thread: the
//// assistant's text so far, the tools it called, and the files it changed.
//// The thread actor feeds events in and renders snapshots out.

import crushling/crush/event.{type Event}
import crushling/diff
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type ToolStatus {
  Running
  Succeeded
  Failed
}

pub type Tool {
  Tool(
    id: String,
    name: String,
    /// The raw JSON input, for renderers that want more than `summary`.
    input: String,
    summary: String,
    /// What the agent said the call is for, when the tool asks for one
    /// (bash's `description`, a sub-agent's `label`).
    description: String,
    status: ToolStatus,
    /// The result text, once it arrives.
    output: String,
  )
}

pub type Outcome {
  Completed(text: String)
  Errored(error: String)
  Cancelled
}

pub type Run {
  Run(
    session_id: String,
    run_id: String,
    order: List(String),
    texts: Dict(String, String),
    tools: List(Tool),
    baseline: Dict(String, Option(String)),
    latest: Dict(String, String),
    outcome: Option(Outcome),
  )
}

/// File contents as last seen anywhere in the thread, so a later run that
/// edits a file without re-reading it still has a baseline to diff against.
pub type Known =
  Dict(String, String)

pub fn new(session_id: String, run_id: String) -> Run {
  Run(
    session_id:,
    run_id:,
    order: [],
    texts: dict.new(),
    tools: [],
    baseline: dict.new(),
    latest: dict.new(),
    outcome: None,
  )
}

pub fn is_done(run: Run) -> Bool {
  option.is_some(run.outcome)
}

/// Fold one event into the run. Events for other sessions or runs are
/// ignored, so every run can be fed the whole stream.
pub fn apply(run: Run, known: Known, event: Event) -> Run {
  case event {
    event.MessageEvent(message:, ..) if message.session_id == run.session_id ->
      apply_message(run, message)
    event.FileEvent(file) if file.session_id == run.session_id ->
      apply_file(run, known, file)
    event.RunCompleteEvent(done)
      if done.run_id == run.run_id && done.session_id == run.session_id
    -> {
      let outcome = case done.cancelled, done.error {
        True, _ -> Cancelled
        False, "" -> Completed(done.text)
        False, error -> Errored(error)
      }
      Run(..run, outcome: Some(outcome))
    }
    _ -> run
  }
}

fn apply_message(run: Run, message: event.Message) -> Run {
  case message.role {
    event.Assistant -> {
      let order = case dict.has_key(run.texts, message.id) {
        True -> run.order
        False -> list.append(run.order, [message.id])
      }
      let texts = dict.insert(run.texts, message.id, message.text)
      let tools =
        list.fold(message.tool_calls, run.tools, fn(tools, call) {
          upsert_tool(tools, call)
        })
      Run(..run, order:, texts:, tools:)
    }
    event.Tool -> {
      let tools =
        list.fold(message.tool_results, run.tools, fn(tools, result) {
          let status = case result.is_error {
            True -> Failed
            False -> Succeeded
          }
          list.map(tools, fn(tool) {
            case tool.id == result.tool_call_id {
              True -> Tool(..tool, status:, output: result.content)
              False -> tool
            }
          })
        })
      Run(..run, tools:)
    }
    _ -> run
  }
}

fn upsert_tool(tools: List(Tool), call: event.ToolCall) -> List(Tool) {
  let summary = summarize_input(call.input)
  case list.any(tools, fn(tool) { tool.id == call.id }) {
    True ->
      list.map(tools, fn(tool) {
        case tool.id == call.id {
          True ->
            Tool(
              ..tool,
              name: call.name,
              input: call.input,
              summary:,
              description: describe_input(call.input),
            )
          False -> tool
        }
      })
    False ->
      list.append(tools, [
        Tool(
          id: call.id,
          name: call.name,
          input: call.input,
          summary:,
          description: describe_input(call.input),
          status: Running,
          output: "",
        ),
      ])
  }
}

const salient_fields = [
  "command", "file_path", "path", "pattern", "url", "query", "prompt",
]

/// The one input field that says what a tool call is doing, cut to a line.
pub fn summarize_input(input: String) -> String {
  pick(input, salient_fields)
}

/// The agent's own description of the call, if the tool takes one.
pub fn describe_input(input: String) -> String {
  pick(input, ["description", "label"])
}

fn pick(input: String, names: List(String)) -> String {
  let fields =
    json.parse(input, decode.dict(decode.string, decode.dynamic))
    |> option.from_result
    |> option.unwrap(dict.new())
  let picked =
    list.find_map(names, fn(name) {
      case dict.get(fields, name) {
        Ok(value) ->
          case decode.run(value, decode.string) {
            Ok(text) -> Ok(text)
            Error(_) -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
    })
  case picked {
    Ok(text) -> one_line(text, 80)
    Error(Nil) -> ""
  }
}

fn one_line(text: String, max: Int) -> String {
  let line = case string.split_once(string.trim(text), "\n") {
    Ok(#(first, _)) -> first <> " …"
    Error(Nil) -> string.trim(text)
  }
  case string.length(line) > max {
    True -> string.slice(line, 0, max - 1) <> "…"
    False -> line
  }
}

fn apply_file(run: Run, known: Known, file: event.FileVersion) -> Run {
  let baseline = case dict.has_key(run.baseline, file.path) {
    True -> run.baseline
    False -> {
      let base = case file.version {
        0 -> Some(file.content)
        _ -> dict.get(known, file.path) |> option.from_result
      }
      dict.insert(run.baseline, file.path, base)
    }
  }
  Run(
    ..run,
    baseline:,
    latest: dict.insert(run.latest, file.path, file.content),
  )
}

/// Remember this run's final file contents for the next run in the thread.
pub fn remember(known: Known, run: Run) -> Known {
  dict.merge(known, run.latest)
}

pub fn text(run: Run) -> String {
  list.filter_map(run.order, fn(id) { dict.get(run.texts, id) })
  |> list.map(string.trim)
  |> list.filter(fn(text) { text != "" })
  |> string.join("\n\n")
}

/// The assistant's messages so far as id and text, without empty ones.
/// While the run is going only messages followed by a later one are
/// included, since the last may still be growing; `done` includes it too.
pub fn messages(run: Run, done: Bool) -> List(#(String, String)) {
  let order = case done || run.outcome != None {
    True -> run.order
    False -> list.take(run.order, list.length(run.order) - 1)
  }
  list.filter_map(order, fn(id) {
    case dict.get(run.texts, id) {
      Ok(text) ->
        case string.trim(text) {
          "" -> Error(Nil)
          text -> Ok(#(id, text))
        }
      Error(Nil) -> Error(Nil)
    }
  })
}

pub type FileChange {
  Changed(path: String, diff: String)
  Unknown(path: String)
}

pub fn changes(run: Run, root: String) -> List(FileChange) {
  dict.to_list(run.latest)
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.filter_map(fn(pair) {
    let #(path, latest) = pair
    let shown = display_path(path, root)
    case dict.get(run.baseline, path) {
      Ok(Some(base)) ->
        case diff.unified(shown, base, latest) {
          "" -> Error(Nil)
          patch -> Ok(Changed(shown, patch))
        }
      _ -> Ok(Unknown(shown))
    }
  })
}

pub fn display_path(path: String, root: String) -> String {
  let root = case string.ends_with(root, "/") {
    True -> root
    False -> root <> "/"
  }
  case string.starts_with(path, root) {
    True -> string.drop_start(path, string.length(root))
    False -> path
  }
}

/// Everything changed in the run as one patch, for attaching to the thread.
pub fn patch(run: Run, root: String) -> String {
  changes(run, root)
  |> list.filter_map(fn(change) {
    case change {
      Changed(diff:, ..) -> Ok(diff)
      Unknown(_) -> Error(Nil)
    }
  })
  |> string.concat
}
