//// The `crush server` calls the bridge makes. Each call is a pure `Call`
//// (method, path, body, response parser) so it can be tested without a
//// server, and `perform` runs one over a `gun` connection.

import crushling/gun
import gleam/bit_array
import gleam/dynamic/decode.{type Decoder}
import gleam/http.{type Method, Delete, Get, Post}
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleam/uri

pub type Error {
  Transport(reason: String)
  Status(status: Int, message: String)
  BadResponse(body: String)
}

pub type Call(a) {
  Call(
    method: Method,
    path: String,
    body: Option(Json),
    expect: Int,
    parse: fn(String) -> Result(a, Nil),
  )
}

pub type PermissionMode {
  Normal
  Yolo
  Sysadmin
}

const timeout_ms = 30_000

pub fn perform(conn: gun.Conn, call: Call(a)) -> Result(a, Error) {
  let #(headers, body) = case call.body {
    Some(json) -> #(
      [#("content-type", "application/json")],
      bit_array.from_string(json.to_string(json)),
    )
    None -> #([], <<>>)
  }
  let headers = [#("host", "api.crush.localhost"), ..headers]
  case gun.request(conn, call.method, call.path, headers, body, timeout_ms) {
    Error(reason) -> Error(Transport(reason))
    Ok(response) -> {
      let text = bit_array.to_string(response.body) |> result_or("")
      case response.status == call.expect {
        True ->
          case call.parse(text) {
            Ok(value) -> Ok(value)
            Error(Nil) -> Error(BadResponse(text))
          }
        False -> Error(Status(response.status, error_message(text)))
      }
    }
  }
}

fn result_or(result: Result(a, b), default: a) -> a {
  case result {
    Ok(value) -> value
    Error(_) -> default
  }
}

/// The server's errors are `{"message": text}`; fall back to the raw body.
pub fn error_message(body: String) -> String {
  case json.parse(body, decode.at(["message"], decode.string)) {
    Ok(message) -> message
    Error(_) -> body
  }
}

fn ignore_body(_body: String) -> Result(Nil, Nil) {
  Ok(Nil)
}

fn parse_with(decoder: Decoder(a)) -> fn(String) -> Result(a, Nil) {
  fn(body) {
    case json.parse(body, decoder) {
      Ok(value) -> Ok(value)
      Error(_) -> Error(Nil)
    }
  }
}

fn workspace(id: String) -> String {
  "/v1/workspaces/" <> uri.percent_encode(id)
}

fn session(workspace_id: String, session_id: String) -> String {
  workspace(workspace_id)
  <> "/agent/sessions/"
  <> uri.percent_encode(session_id)
}

pub fn health() -> Call(Nil) {
  Call(Get, "/v1/health", None, 200, ignore_body)
}

fn mode_to_string(mode: PermissionMode) -> String {
  case mode {
    Normal -> "normal"
    Yolo -> "yolo"
    Sysadmin -> "sysadmin"
  }
}

/// Returns the workspace id. Workspaces are deduplicated by path, so creating
/// the same path twice joins the existing one.
pub fn create_workspace(
  path path: String,
  client_id client_id: String,
  mode mode: PermissionMode,
  env env: List(String),
) -> Call(String) {
  let body =
    json.object([
      #("path", json.string(path)),
      #("client_id", json.string(client_id)),
      #("permission_mode", json.string(mode_to_string(mode))),
      #("env", json.array(env, json.string)),
    ])
  Call(
    Post,
    "/v1/workspaces",
    Some(body),
    200,
    parse_with(decode.at(["id"], decode.string)),
  )
}

/// The SSE stream path. It must be opened within 30s of creating the
/// workspace and kept open, or the server releases the workspace.
pub fn events_path(workspace_id: String, client_id: String) -> String {
  workspace(workspace_id)
  <> "/events?client_id="
  <> uri.percent_encode(client_id)
}

pub fn init_agent(workspace_id: String, interactive: Bool) -> Call(Nil) {
  let body = json.object([#("interactive", json.bool(interactive))])
  Call(
    Post,
    workspace(workspace_id) <> "/agent/init",
    Some(body),
    200,
    ignore_body,
  )
}

pub fn agent_ready(workspace_id: String) -> Call(Bool) {
  let decoder =
    decode.optional_field("is_ready", False, decode.bool, decode.success)
  Call(Get, workspace(workspace_id) <> "/agent", None, 200, parse_with(decoder))
}

pub fn update_agent(workspace_id: String) -> Call(Nil) {
  Call(Post, workspace(workspace_id) <> "/agent/update", None, 200, ignore_body)
}

/// Returns the session id.
pub fn create_session(workspace_id: String, title: String) -> Call(String) {
  let body = json.object([#("title", json.string(title))])
  Call(
    Post,
    workspace(workspace_id) <> "/sessions",
    Some(body),
    200,
    parse_with(decode.at(["id"], decode.string)),
  )
}

/// Always pass a fresh `run_id`: a prompt sent while the session is busy is
/// then queued as its own turn with its own `run_complete`, instead of being
/// folded into the turn already running.
pub fn send_prompt(
  workspace_id workspace_id: String,
  session_id session_id: String,
  run_id run_id: String,
  prompt prompt: String,
) -> Call(Nil) {
  let body =
    json.object([
      #("session_id", json.string(session_id)),
      #("run_id", json.string(run_id)),
      #("prompt", json.string(prompt)),
    ])
  Call(Post, workspace(workspace_id) <> "/agent", Some(body), 202, ignore_body)
}

pub fn cancel(workspace_id: String, session_id: String) -> Call(Nil) {
  Call(
    Post,
    session(workspace_id, session_id) <> "/cancel",
    None,
    200,
    ignore_body,
  )
}

pub fn clear_queue(workspace_id: String, session_id: String) -> Call(Nil) {
  Call(
    Post,
    session(workspace_id, session_id) <> "/prompts/clear",
    None,
    200,
    ignore_body,
  )
}

pub fn summarize(workspace_id: String, session_id: String) -> Call(Nil) {
  Call(
    Post,
    session(workspace_id, session_id) <> "/summarize",
    None,
    200,
    ignore_body,
  )
}

pub fn retire_client(client_id: String) -> Call(Nil) {
  Call(
    Delete,
    "/v1/clients/" <> uri.percent_encode(client_id),
    None,
    200,
    ignore_body,
  )
}

pub fn session_busy(workspace_id: String, session_id: String) -> Call(Bool) {
  let decoder =
    decode.optional_field("is_busy", False, decode.bool, decode.success)
  Call(Get, session(workspace_id, session_id), None, 200, parse_with(decoder))
}

/// Run a shell command in the workspace directory, on the server's side of
/// the sandbox. The server saves the output into the session named in the
/// path, unless that session doesn't exist, so callers pass a random id to
/// keep bridge housekeeping out of the agent's history.
pub fn shell(
  workspace_id workspace_id: String,
  scratch_session scratch_session: String,
  command command: String,
) -> Call(#(Int, String)) {
  let body =
    json.object([
      #("command", json.string(command)),
      #("term_width", json.int(200)),
    ])
  let decoder = {
    use output <- decode.optional_field("output", "", decode.string)
    use exit_code <- decode.optional_field("exit_code", 0, decode.int)
    decode.success(#(exit_code, output))
  }
  Call(
    Post,
    session(workspace_id, scratch_session) <> "/shell",
    Some(body),
    200,
    parse_with(decoder),
  )
}

pub fn list_sessions(workspace_id: String) -> Call(List(String)) {
  let decoder = decode.list(decode.at(["id"], decode.string))
  Call(
    Get,
    workspace(workspace_id) <> "/sessions",
    None,
    200,
    parse_with(decoder),
  )
}

/// A session's messages as the raw JSON array.
pub fn session_messages(
  workspace_id: String,
  session_id: String,
) -> Call(String) {
  Call(
    Get,
    workspace(workspace_id)
      <> "/sessions/"
      <> uri.percent_encode(session_id)
      <> "/messages",
    None,
    200,
    Ok,
  )
}
