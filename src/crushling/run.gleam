//// The pure state of one agent run as seen from a Slack thread: the
//// assistant's text so far and the tools it called.
//// The thread actor feeds events in and renders snapshots out.

import crushling/crush/event.{type Event}
import crushling/text
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
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
    /// Messages that call tools: what they say is narration ("Building it
    /// now."), shown as the run's status rather than in its reply.
    acting: Set(String),
    tools: List(Tool),
    outcome: Option(Outcome),
  )
}

pub fn new(session_id: String, run_id: String) -> Run {
  Run(
    session_id:,
    run_id:,
    order: [],
    texts: dict.new(),
    acting: set.new(),
    tools: [],
    outcome: None,
  )
}

/// Whether a tool call is still running.
pub fn tool_running(run: Run) -> Bool {
  list.any(run.tools, fn(tool) { tool.status == Running })
}

pub fn is_done(run: Run) -> Bool {
  option.is_some(run.outcome)
}

/// Fold one event into the run. Events for other sessions or runs are
/// ignored, so every run can be fed the whole stream.
pub fn apply(run: Run, event: Event) -> Run {
  case event {
    event.MessageEvent(message:, ..) if message.session_id == run.session_id ->
      apply_message(run, message)
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
      let acting = case message.tool_calls {
        [] -> run.acting
        _ -> set.insert(run.acting, message.id)
      }
      let tools =
        list.fold(message.tool_calls, run.tools, fn(tools, call) {
          upsert_tool(tools, call)
        })
      Run(..run, order:, texts:, acting:, tools:)
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

fn one_line(input: String, max: Int) -> String {
  case string.split_once(string.trim(input), "\n") {
    Ok(#(first, _)) -> first <> " …"
    Error(Nil) -> input
  }
  |> text.clip(max)
}

/// What the run says to the person: its messages, without narration
/// between tool calls. While it runs, the latest message is held back,
/// since a tool call may yet make it narration.
pub fn text(run: Run) -> String {
  let order = case run.outcome {
    None -> list.take(run.order, int.max(list.length(run.order) - 1, 0))
    Some(_) -> run.order
  }
  list.filter(order, fn(id) { !set.contains(run.acting, id) })
  |> list.filter_map(fn(id) { dict.get(run.texts, id) })
  |> list.map(string.trim)
  |> list.filter(fn(text) { text != "" })
  |> string.join("\n\n")
}

/// What the agent last said it's doing: the latest message's text while
/// the run goes, or "".
pub fn narration(run: Run) -> String {
  case run.outcome, list.last(run.order) {
    None, Ok(id) -> dict.get(run.texts, id) |> result.unwrap("") |> string.trim
    _, _ -> ""
  }
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
