//// Typed events from the `crush server` SSE stream.
////
//// Every frame is `data: {"type": kind, "payload": {"type": op, "payload": body}}`.
//// Only the kinds the bridge acts on are decoded; everything else becomes
//// `Other` so a new server version never breaks the stream.

import gleam/dynamic/decode.{type Decoder}
import gleam/json
import gleam/list
import gleam/option
import gleam/string

pub type Role {
  User
  Assistant
  Tool
  System
}

pub type ToolCall {
  ToolCall(id: String, name: String, input: String, finished: Bool)
}

pub type ToolResult {
  ToolResult(
    tool_call_id: String,
    name: String,
    content: String,
    is_error: Bool,
  )
}

/// A finished subagent's report, delivered into its parent's session.
pub type SubReport {
  SubReport(label: String, output: String, failed: Bool)
}

pub type Message {
  Message(
    id: String,
    session_id: String,
    role: Role,
    text: String,
    tool_calls: List(ToolCall),
    tool_results: List(ToolResult),
    reports: List(SubReport),
  )
}

pub type RunComplete {
  RunComplete(
    session_id: String,
    run_id: String,
    message_id: String,
    text: String,
    error: String,
    cancelled: Bool,
  )
}

pub type FileVersion {
  FileVersion(session_id: String, path: String, content: String, version: Int)
}

pub type Event {
  MessageEvent(op: String, message: Message)
  /// A session was created or changed; subagents run in child sessions.
  SessionEvent(id: String, parent_session_id: String, title: String)
  RunCompleteEvent(RunComplete)
  AgentError(session_id: String, run_id: String, error: String)
  FileEvent(FileVersion)
  Other(kind: String)
}

pub fn parse(data: String) -> Result(Event, json.DecodeError) {
  json.parse(data, decoder())
}

pub fn decoder() -> Decoder(Event) {
  use kind <- decode.field("type", decode.string)
  use op <- decode.subfield(["payload", "type"], lenient_string())
  case kind {
    "message" -> body(message_decoder()) |> decode.map(MessageEvent(op, _))
    "run_complete" ->
      body(run_complete_decoder()) |> decode.map(RunCompleteEvent)
    "file" -> body(file_decoder()) |> decode.map(FileEvent)
    "session" ->
      body({
        use id <- str("id")
        use parent_session_id <- str("parent_session_id")
        use title <- str("title")
        decode.success(SessionEvent(id:, parent_session_id:, title:))
      })
    "agent_event" -> body(agent_event_decoder(kind))
    _ -> decode.success(Other(kind))
  }
}

fn body(inner: Decoder(a)) -> Decoder(a) {
  decode.at(["payload", "payload"], inner)
}

fn lenient_string() -> Decoder(String) {
  decode.optional(decode.string) |> decode.map(option.unwrap(_, ""))
}

fn str(name: String, next: fn(String) -> Decoder(a)) -> Decoder(a) {
  decode.optional_field(name, "", lenient_string(), next)
}

fn message_decoder() -> Decoder(Message) {
  use id <- str("id")
  use session_id <- str("session_id")
  use role <- str("role")
  use parts <- decode.optional_field("parts", [], parts_decoder())
  let text =
    list.filter_map(parts, fn(part) {
      case part {
        TextPart(text) -> Ok(text)
        _ -> Error(Nil)
      }
    })
    |> string.join("")
  let tool_calls =
    list.filter_map(parts, fn(part) {
      case part {
        CallPart(call) -> Ok(call)
        _ -> Error(Nil)
      }
    })
  let tool_results =
    list.filter_map(parts, fn(part) {
      case part {
        ResultPart(result) -> Ok(result)
        _ -> Error(Nil)
      }
    })
  let reports =
    list.filter_map(parts, fn(part) {
      case part {
        ReportPart(report) -> Ok(report)
        _ -> Error(Nil)
      }
    })
  decode.success(Message(
    id:,
    session_id:,
    role: role_from_string(role),
    text:,
    tool_calls:,
    tool_results:,
    reports:,
  ))
}

fn role_from_string(role: String) -> Role {
  case role {
    "user" -> User
    "tool" -> Tool
    "system" -> System
    _ -> Assistant
  }
}

type Part {
  TextPart(String)
  CallPart(ToolCall)
  ResultPart(ToolResult)
  ReportPart(SubReport)
  OtherPart
}

fn parts_decoder() -> Decoder(List(Part)) {
  decode.optional(decode.list(part_decoder()))
  |> decode.map(option.unwrap(_, []))
}

fn part_decoder() -> Decoder(Part) {
  use kind <- str("type")
  let data = fn(inner: Decoder(Part)) {
    decode.optionally_at(["data"], OtherPart, inner)
  }
  case kind {
    "text" ->
      data({
        use text <- str("text")
        use hidden <- decode.optional_field("hidden", False, decode.bool)
        case hidden {
          True -> decode.success(OtherPart)
          False -> decode.success(TextPart(text))
        }
      })
    "tool_call" ->
      data({
        use id <- str("id")
        use name <- str("name")
        use input <- str("input")
        use finished <- decode.optional_field("finished", False, decode.bool)
        decode.success(CallPart(ToolCall(id:, name:, input:, finished:)))
      })
    "tool_result" ->
      data({
        use tool_call_id <- str("tool_call_id")
        use name <- str("name")
        use content <- str("content")
        use is_error <- decode.optional_field("is_error", False, decode.bool)
        decode.success(
          ResultPart(ToolResult(tool_call_id:, name:, content:, is_error:)),
        )
      })
    "sub_agent_report" ->
      data({
        use label <- str("label")
        use output <- str("output")
        use failed <- decode.optional_field("failed", False, decode.bool)
        decode.success(ReportPart(SubReport(label:, output:, failed:)))
      })
    _ -> decode.success(OtherPart)
  }
}

fn run_complete_decoder() -> Decoder(RunComplete) {
  use session_id <- str("session_id")
  use run_id <- str("run_id")
  use message_id <- str("message_id")
  use text <- str("text")
  use error <- str("error")
  use cancelled <- decode.optional_field("cancelled", False, decode.bool)
  decode.success(RunComplete(
    session_id:,
    run_id:,
    message_id:,
    text:,
    error:,
    cancelled:,
  ))
}

fn file_decoder() -> Decoder(FileVersion) {
  use session_id <- str("session_id")
  use path <- str("path")
  use content <- str("content")
  use version <- decode.optional_field("version", 0, decode.int)
  decode.success(FileVersion(session_id:, path:, content:, version:))
}

fn agent_event_decoder(kind: String) -> Decoder(Event) {
  use agent_type <- str("type")
  use session_id <- str("session_id")
  use run_id <- str("run_id")
  use error <- str("error")
  case agent_type {
    "error" -> decode.success(AgentError(session_id:, run_id:, error:))
    _ -> decode.success(Other(kind <> ":" <> agent_type))
  }
}
