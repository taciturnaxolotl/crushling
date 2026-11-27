//// The sandbox's `/files` route, which `crushling-fetch` and
//// `crushling-share` talk to:
////
//// - `GET /files/<key>/<file_id>` serves a kept file;
//// - `POST /files/<key>?name=<name>&comment=<text>` keeps an upload of up
////   to 64 MiB, posts it in the thread's conversation, and answers
////   `{"id": ...}`.
////
//// Both take the thread's MCP token, so no new secret is handed out.

import crushling/files.{max_upload_bytes}
import crushling/mcp
import crushling/sandbox_http
import crushling/sys
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import mist

/// An id for an upload, unlike any Slack file id (those start with F).
fn new_id() -> String {
  "S"
  <> {
    sys.uuid()
    |> string.replace("-", "")
    |> string.slice(0, 16)
    |> string.uppercase
  }
}

/// Posts an upload in a thread's conversation: the thread's key, the
/// file's name, its bytes and a comment ("" for none).
pub type Share =
  fn(String, String, BitArray, String) -> Result(String, String)

/// Uploads in flight at once, per thread and in all.
pub const max_uploads_per_thread = 2

pub const max_uploads = 8

/// Counts uploads in flight, so a few large ones can't fill the bridge's
/// memory. A slot is held by the process that took it, and freed when that
/// process lets go or exits.
pub opaque type Limits {
  Limits(subject: Subject(LimitsMessage))
}

pub opaque type Slot {
  Slot(limits: Limits, monitor: process.Monitor)
}

pub opaque type LimitsMessage {
  Acquire(key: String, holder: process.Pid, reply: Subject(Result(Slot, Nil)))
  Release(monitor: process.Monitor)
  HolderDown(process.Down)
}

type LimitsState {
  LimitsState(
    self: Limits,
    per_thread: Int,
    total: Int,
    held: Dict(process.Monitor, String),
  )
}

/// Start counting uploads: at most `per_thread` for one thread and `total`
/// in all.
pub fn new_limits(per_thread: Int, total: Int) -> Limits {
  let assert Ok(started) =
    actor.new_with_initialiser(1000, fn(subject) {
      let limits = Limits(subject)
      LimitsState(limits, per_thread, total, dict.new())
      |> actor.initialised
      |> actor.selecting(
        process.new_selector()
        |> process.select(subject)
        |> process.select_monitors(HolderDown),
      )
      |> actor.returning(limits)
      |> Ok
    })
    |> actor.on_message(handle_limits)
    |> actor.start
  started.data
}

fn handle_limits(
  state: LimitsState,
  message: LimitsMessage,
) -> actor.Next(LimitsState, LimitsMessage) {
  case message {
    Acquire(key:, holder:, reply:) -> {
      let mine = dict.values(state.held) |> list.count(fn(k) { k == key })
      case mine >= state.per_thread || dict.size(state.held) >= state.total {
        True -> {
          process.send(reply, Error(Nil))
          actor.continue(state)
        }
        False -> {
          let monitor = process.monitor(holder)
          process.send(reply, Ok(Slot(state.self, monitor)))
          actor.continue(
            LimitsState(..state, held: dict.insert(state.held, monitor, key)),
          )
        }
      }
    }
    Release(monitor:) -> {
      process.demonitor_process(monitor)
      actor.continue(
        LimitsState(..state, held: dict.delete(state.held, monitor)),
      )
    }
    HolderDown(process.ProcessDown(monitor:, ..))
    | HolderDown(process.PortDown(monitor:, ..)) ->
      actor.continue(
        LimitsState(..state, held: dict.delete(state.held, monitor)),
      )
  }
}

/// Take an upload slot for the thread `key`, held by the calling process,
/// or Error when the thread or the bridge has too many in flight.
pub fn acquire(limits: Limits, key: String) -> Result(Slot, Nil) {
  process.call(limits.subject, 5000, Acquire(key, process.self(), _))
}

pub fn release(slot: Slot) -> Nil {
  process.send(slot.limits.subject, Release(slot.monitor))
}

/// The route that serves `/files/<key>/...`, keeping files under `root`.
pub fn route(secret: String, root: String, share: Share) -> sandbox_http.Route {
  route_with(
    secret,
    root,
    share,
    new_limits(max_uploads_per_thread, max_uploads),
  )
}

/// `route`, counting uploads with `limits`.
pub fn route_with(
  secret: String,
  root: String,
  share: Share,
  limits: Limits,
) -> sandbox_http.Route {
  fn(req: Request(mist.Connection)) {
    case request.path_segments(req) {
      ["files", key, ..rest] ->
        Some(serve(req, secret, root, share, limits, key, rest))
      _ -> None
    }
  }
}

fn serve(
  req: Request(mist.Connection),
  secret: String,
  root: String,
  share: Share,
  limits: Limits,
  key: String,
  rest: List(String),
) -> Response(mist.ResponseData) {
  let reply = sandbox_http.reply
  let auth = request.get_header(req, "authorization") |> result.unwrap("")
  case
    mcp.authorized(secret, key, auth) && files.valid_key(key),
    req.method,
    rest
  {
    False, _, _ -> reply(401, "")
    True, http.Get, [id] -> download(root, key, id)
    True, http.Post, [] -> upload(req, root, key, share, limits)
    True, http.Get, _ | True, http.Post, _ -> reply(404, "")
    True, _, _ -> reply(405, "") |> response.set_header("allow", "GET, POST")
  }
}

fn download(
  root: String,
  key: String,
  id: String,
) -> Response(mist.ResponseData) {
  case files.find(root, key, id) {
    Error(Nil) -> sandbox_http.reply(404, "no such file")
    Ok(#(path, name)) ->
      case mist.send_file(path, offset: 0, limit: None) {
        Error(_) -> sandbox_http.reply(404, "no such file")
        Ok(body) ->
          response.new(200)
          |> response.set_body(body)
          |> response.set_header("content-type", "application/octet-stream")
          |> response.set_header("x-file-name", name)
          |> response.set_header(
            "content-disposition",
            "attachment; filename=\"" <> name <> "\"",
          )
      }
  }
}

/// How long an upload's body may be: Error with the status to answer when
/// it has no length, is chunked, or is too long.
pub fn upload_length(
  headers: List(#(String, String)),
) -> Result(Int, #(Int, String)) {
  let header = fn(name) { list.key_find(headers, name) }
  case header("transfer-encoding"), header("content-length") {
    Ok(_), _ -> Error(#(411, "send the file with a Content-Length, unchunked"))
    _, Error(Nil) -> Error(#(411, "send the file with a Content-Length"))
    _, Ok(length) ->
      case int.parse(string.trim(length)) {
        Ok(n) if n < 0 -> Error(#(400, "bad Content-Length"))
        Ok(n) if n > max_upload_bytes ->
          Error(#(
            413,
            "files over "
              <> files.human_size(max_upload_bytes)
              <> " can't be shared",
          ))
        Ok(n) -> Ok(n)
        Error(Nil) -> Error(#(400, "bad Content-Length"))
      }
  }
}

fn upload(
  req: Request(mist.Connection),
  root: String,
  key: String,
  share: Share,
  limits: Limits,
) -> Response(mist.ResponseData) {
  let query = request.get_query(req) |> result.unwrap([])
  let name = list.key_find(query, "name") |> result.unwrap("") |> string.trim
  let comment = list.key_find(query, "comment") |> result.unwrap("")
  // Only the last part of a path names the file.
  let name = string.split(name, "/") |> list.last |> result.unwrap("")
  case name, upload_length(req.headers) {
    "", _ -> sandbox_http.reply(400, "give the file's name as ?name=")
    _, Error(#(status, why)) -> sandbox_http.reply(status, why)
    name, Ok(_) ->
      case acquire(limits, key) {
        Error(Nil) ->
          sandbox_http.reply(429, "too many uploads at once; try again soon")
        Ok(slot) -> {
          let response = receive(req, root, key, name, comment, share)
          release(slot)
          response
        }
      }
  }
}

/// Read an upload whose Content-Length is checked, keep it and share it.
/// A file that couldn't be shared isn't kept, so retries don't pile up.
fn receive(
  req: Request(mist.Connection),
  root: String,
  key: String,
  name: String,
  comment: String,
  share: Share,
) -> Response(mist.ResponseData) {
  // With a Content-Length mist reads exactly that many bytes.
  case mist.read_body(req, max_upload_bytes) {
    Error(mist.ExcessBody) -> sandbox_http.reply(413, "")
    Error(mist.MalformedBody) -> sandbox_http.reply(400, "")
    Ok(req) -> {
      let id = new_id()
      case files.store(root, key, id, name, req.body) {
        Error(reason) -> sandbox_http.reply(500, "couldn't keep it: " <> reason)
        Ok(Nil) ->
          case share(key, name, req.body, comment) {
            Error(reason) -> {
              files.remove(root, key, id)
              sandbox_http.reply(502, reason)
            }
            Ok(shared) ->
              sandbox_http.reply(
                200,
                json.object([
                  #("id", json.string(id)),
                  #("message", json.string(shared)),
                ])
                  |> json.to_string,
              )
              |> response.set_header("content-type", "application/json")
          }
      }
    }
  }
}
