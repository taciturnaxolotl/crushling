//// Files between Slack and a thread's sandbox, through the bridge.
////
//// A sandbox shares no filesystem with the bridge, so files cross over
//// HTTP. Every Slack attachment is kept on the bridge under
//// `<root>/<key>/files/<file_id>-<name>`; small images and text also go
//// straight into the prompt (`place`). The agent fetches a kept file with
//// `crushling-fetch <file_id>` and shares one into its conversation with
//// `crushling-share <path>` (the scripts in `sandbox/bin`), which talk to
//// this module's route:
////
//// - `GET /files/<key>/<file_id>` serves a kept file;
//// - `POST /files/<key>?name=<name>&comment=<text>` keeps an upload of up
////   to 64 MiB, posts it in the thread's conversation, and answers
////   `{"id": ...}`.
////
//// Both take the thread's MCP token, so no new secret is handed out, and a
//// file id only resolves inside its own thread's directory.

import crushling/crush/client
import crushling/mcp
import crushling/sandbox_http
import crushling/sys
import gleam/bit_array
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

/// The biggest upload the route takes.
pub const max_upload_bytes = 67_108_864

/// Text up to this size goes into the prompt as well as on the bridge.
pub const max_inline_text_bytes = 65_536

/// Images up to this size are shown to the model. crush scales an image
/// down to its provider's budget (5 MiB encoded on Bedrock, 10 MiB direct),
/// so this only keeps prompts from carrying very large files.
pub const max_inline_image_bytes = 5_242_880

/// Image types models take directly.
const seen_images = ["image/png", "image/jpeg", "image/gif", "image/webp"]

/// Non-`text/*` types that are text.
const text_types = [
  "application/json", "application/x-ndjson", "application/xml",
  "application/yaml", "application/x-yaml", "application/toml",
  "application/javascript", "application/x-javascript", "application/typescript",
  "application/x-sh", "application/x-shellscript", "application/sql",
  "application/graphql", "application/x-diff", "application/x-patch",
]

/// Extensions of text files, for when Slack gives a vague type.
const text_extensions = [
  "txt", "md", "markdown", "rst", "log", "csv", "tsv", "json", "jsonl", "ndjson",
  "yaml", "yml", "toml", "ini", "cfg", "conf", "env", "xml", "html", "htm",
  "css", "scss", "svg", "diff", "patch", "sh", "bash", "zsh", "fish", "py", "rb",
  "go", "rs", "c", "h", "cc", "cpp", "hpp", "cs", "java", "kt", "kts", "swift",
  "m", "js", "mjs", "cjs", "jsx", "ts", "tsx", "gleam", "erl", "hrl", "ex",
  "exs", "hs", "ml", "lua", "php", "pl", "r", "scala", "sql", "graphql", "proto",
  "nix", "zig", "vue", "svelte", "dockerfile", "makefile", "gradle", "tf",
  "lock",
]

/// The directory that keeps a thread's files.
pub fn dir(root: String, key: String) -> String {
  root <> "/" <> key <> "/files"
}

/// Keep only characters that are safe in a file name.
pub fn safe_name(name: String) -> String {
  let cleaned =
    string.to_graphemes(name)
    |> list.map(fn(g) {
      case is_name_char(g) {
        True -> g
        False -> "_"
      }
    })
    |> string.concat
  case cleaned {
    "" | "." | ".." -> "file"
    cleaned -> cleaned
  }
}

fn is_name_char(g: String) -> Bool {
  g != ""
  && string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-",
    g,
  )
}

/// Whether `id` can name a file: letters and digits only, as Slack's file
/// ids and the ones uploads get.
pub fn valid_id(id: String) -> Bool {
  id != ""
  && string.length(id) <= 64
  && list.all(string.to_graphemes(id), fn(g) {
    g != ""
    && string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
      g,
    )
  })
}

fn valid_key(key: String) -> Bool {
  key != ""
  && key != "."
  && key != ".."
  && list.all(string.to_graphemes(key), is_name_char)
}

@external(erlang, "crushling_ffi", "write_bytes")
fn write_bytes(path: String, bytes: BitArray) -> Result(Nil, String)

/// Keep `bytes` as the thread's file `id`, named `name`.
pub fn store(
  root: String,
  key: String,
  id: String,
  name: String,
  bytes: BitArray,
) -> Result(Nil, String) {
  case valid_key(key) && valid_id(id) {
    False -> Error("bad file id")
    True ->
      write_bytes(dir(root, key) <> "/" <> id <> "-" <> safe_name(name), bytes)
  }
}

/// The path of the thread's file `id`, and its name.
pub fn find(
  root: String,
  key: String,
  id: String,
) -> Result(#(String, String), Nil) {
  case valid_key(key) && valid_id(id) {
    False -> Error(Nil)
    True -> {
      let dir = dir(root, key)
      use names <- result.try(sys.list_dir(dir))
      list.find_map(names, fn(entry) {
        case string.split_once(entry, "-") {
          Ok(#(found, name)) if found == id -> Ok(#(dir <> "/" <> entry, name))
          _ -> Error(Nil)
        }
      })
    }
  }
}

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

pub fn human_size(bytes: Int) -> String {
  case bytes {
    b if b < 1024 -> int.to_string(b) <> " B"
    b if b < 1_048_576 -> int.to_string(b / 1024) <> " KB"
    b -> int.to_string(b / 1_048_576) <> " MB"
  }
}

fn extension(name: String) -> String {
  case string.split(string.lowercase(name), ".") {
    [whole] -> whole
    parts -> list.last(parts) |> result.unwrap("")
  }
}

/// Types that say nothing about what a file is, so its name and first
/// bytes are what to go by.
fn is_generic(mimetype: String) -> Bool {
  case string.lowercase(mimetype) {
    "" | "application/octet-stream" | "binary/octet-stream" | "text/plain" ->
      True
    _ -> False
  }
}

/// Whether a file is text, by its type, or by its name when the type is
/// generic. The bytes are checked separately.
pub fn is_text(name: String, mimetype: String) -> Bool {
  let lower = string.lowercase(mimetype)
  string.starts_with(lower, "text/")
  || list.contains(text_types, lower)
  || string.ends_with(lower, "+json")
  || string.ends_with(lower, "+xml")
  || is_generic(lower)
  && list.contains(text_extensions, extension(name))
}

/// Whether `bytes` can be pasted into a prompt: UTF-8 without NUL bytes.
fn is_text_content(bytes: BitArray) -> Bool {
  bit_array.is_utf8(bytes) && !has_nul(bytes)
}

fn has_nul(bytes: BitArray) -> Bool {
  case bytes {
    <<0, _:bits>> -> True
    <<_, rest:bits>> -> has_nul(rest)
    _ -> False
  }
}

/// The image type `bytes` start with, if they are PNG, JPEG, GIF or WebP.
pub fn sniff_image(bytes: BitArray) -> Result(String, Nil) {
  case bytes {
    <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _:bits>> -> Ok("image/png")
    <<0xFF, 0xD8, 0xFF, _:bits>> -> Ok("image/jpeg")
    <<"GIF87a", _:bits>> | <<"GIF89a", _:bits>> -> Ok("image/gif")
    <<"RIFF", _:bytes-size(4), "WEBP", _:bits>> -> Ok("image/webp")
    _ -> Error(Nil)
  }
}

/// The image type a model can see this file as: its own type if it is one,
/// or what its bytes say when its type is generic.
fn image_type(mimetype: String, bytes: BitArray) -> Result(String, Nil) {
  let lower = string.lowercase(mimetype)
  case list.contains(seen_images, lower), is_generic(lower) {
    True, _ -> Ok(lower)
    False, True -> sniff_image(bytes)
    False, False -> Error(Nil)
  }
}

/// How a kept file reaches the prompt: its line, and the attachment that
/// carries it to the model if it is small enough to send along. crush
/// shows the model `image/*` attachments and pastes `text/*` ones into the
/// prompt, so other text types go as `text/plain`.
pub fn place(
  file_id: String,
  name: String,
  mimetype: String,
  bytes: BitArray,
) -> #(String, List(client.Attachment)) {
  let size = bit_array.byte_size(bytes)
  let about = name <> " (" <> mimetype <> ", " <> human_size(size) <> ")"
  let fetch = "crushling-fetch " <> file_id
  let stored = #("- " <> about <> " - fetch it with: " <> fetch, [])
  let attach = fn(mime_type) {
    [client.Attachment(path: name, name:, mime_type:, content: bytes)]
  }
  case image_type(mimetype, bytes), is_text(name, mimetype) {
    Ok(image), _ if size <= max_inline_image_bytes -> #(
      "- " <> about <> ", shown to you; to get it on disk: " <> fetch,
      attach(image),
    )
    Ok(_), _ -> #(
      "- " <> about <> ", too large to show you - fetch it with: " <> fetch,
      [],
    )
    Error(Nil), True ->
      case size <= max_inline_text_bytes && is_text_content(bytes) {
        True -> #(
          "- " <> about <> ", included below; to get it on disk: " <> fetch,
          attach(case string.starts_with(string.lowercase(mimetype), "text/") {
            True -> string.lowercase(mimetype)
            False -> "text/plain"
          }),
        )
        False -> stored
      }
    Error(Nil), False -> stored
  }
}

/// The prompt's note on placed files under `heading`, and what goes along
/// with the prompt; "" when there are none.
pub fn describe(
  heading: String,
  placed: List(#(String, List(client.Attachment))),
) -> #(String, List(client.Attachment)) {
  case list.map(placed, fn(pair) { pair.0 }) {
    [] -> #("", [])
    lines -> #(
      heading <> string.join(lines, "\n"),
      list.flat_map(placed, fn(pair) { pair.1 }),
    )
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
  case mcp.authorized(secret, key, auth) && valid_key(key), req.method, rest {
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
  case find(root, key, id) {
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
            "files over " <> human_size(max_upload_bytes) <> " can't be shared",
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
      case store(root, key, id, name, req.body) {
        Error(reason) -> sandbox_http.reply(500, "couldn't keep it: " <> reason)
        Ok(Nil) ->
          case share(key, name, req.body, comment) {
            Error(reason) -> {
              remove(root, key, id)
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

@external(erlang, "crushling_ffi", "delete_file")
fn delete_file(path: String) -> Nil

/// Delete the thread's file `id`, if it is there.
pub fn remove(root: String, key: String, id: String) -> Nil {
  case find(root, key, id) {
    Ok(#(path, _)) -> delete_file(path)
    Error(Nil) -> Nil
  }
}
