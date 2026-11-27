//// Files attached to Slack messages: fetching them with the bot token,
//// keeping them on the bridge for the agent to fetch, and describing them
//// in the prompt, with small images and text sent along (`place`).

import crushling/crush/client
import crushling/files
import crushling/gun
import crushling/mime
import gleam/bit_array
import gleam/bool
import gleam/http
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import slackline/file

/// Text up to this size goes into the prompt as well as on the bridge.
pub const max_inline_text_bytes = 65_536

/// Images up to this size are shown to the model. crush scales an image
/// down to its provider's budget (5 MiB encoded on Bedrock, 10 MiB direct),
/// so this only keeps prompts from carrying very large files.
pub const max_inline_image_bytes = 5_242_880

/// Files bigger than this are named in the prompt but not kept.
const max_attachment_bytes = files.max_upload_bytes

/// A file attached to a Slack message. `size` is what Slack says, if it
/// says.
pub type Attachment {
  Attachment(
    id: String,
    name: String,
    mimetype: String,
    size: Option(Int),
    url: String,
  )
}

/// The files of a Slack message that can be fetched.
pub fn from_slack(files: Option(List(file.File))) -> List(Attachment) {
  option.unwrap(files, [])
  |> list.filter_map(fn(file) {
    case file.id, file.url_private, file.name {
      Some(id), Some(url), Some(name) ->
        Ok(Attachment(
          id:,
          name:,
          mimetype: option.unwrap(file.mimetype, mime.octet_stream),
          size: file.size,
          url:,
        ))
      _, _, _ -> Error(Nil)
    }
  })
}

/// An earlier message's files, to keep with the prompt that catches up on
/// it.
pub type Earlier {
  Earlier(ts: String, files: List(Attachment))
}

// Fetching ---------------------------------------------------------------------

/// Why a Slack file couldn't be fetched.
pub type FetchError {
  TooLarge
  FetchFailed(String)
}

/// Fetch a Slack file with the bot token, following up to `hops`
/// redirects, reading at most `max` bytes of it. Only https is fetched,
/// except from loopback addresses (for tests). A redirect keeps the token
/// only while it stays on a Slack file host.
pub fn fetch_file(
  token: String,
  url: String,
  max: Int,
  hops: Int,
) -> Result(BitArray, FetchError) {
  fetch_from(Some(token), url, max, hops)
}

@external(erlang, "crushling_ffi", "is_loopback")
fn is_loopback(host: String) -> Bool

/// Whether the bot token may follow a redirect to `host`.
pub fn is_slack_file_host(host: String) -> Bool {
  let host = string.lowercase(host)
  host == "files.slack.com"
  || string.ends_with(host, ".slack.com")
  || string.ends_with(host, ".slack-edge.com")
}

fn fetch_from(
  token: Option(String),
  url: String,
  max: Int,
  hops: Int,
) -> Result(BitArray, FetchError) {
  let failed = fn(why) { Error(FetchFailed(why)) }
  case uri.parse(url) {
    Error(Nil) -> failed("bad url")
    Ok(parsed) ->
      case parsed.host, parsed.scheme {
        None, _ | Some(""), _ -> failed("bad url")
        Some(host), scheme -> {
          let tls = scheme == Some("https")
          let allowed = tls || scheme == Some("http") && is_loopback(host)
          use <- bool.guard(!allowed, failed("only https is fetched"))
          let port =
            option.unwrap(parsed.port, case tls {
              True -> 443
              False -> 80
            })
          let path = case parsed.query {
            Some(query) -> parsed.path <> "?" <> query
            None -> parsed.path
          }
          let headers = case token {
            Some(token) -> [
              #("host", host),
              #("authorization", "Bearer " <> token),
            ]
            None -> [#("host", host)]
          }
          case gun.connect_tcp(host, port, tls, 10_000) {
            Error(reason) -> failed(reason)
            Ok(conn) -> {
              let response =
                gun.request_capped(conn, http.Get, path, headers, max, 120_000)
              gun.close_and_flush(conn)
              case response {
                Error(gun.TooLarge) -> Error(TooLarge)
                Error(gun.Failed(reason)) -> failed(reason)
                Ok(response) ->
                  case response.status {
                    200 -> Ok(response.body)
                    301 | 302 | 303 | 307 | 308 if hops > 0 ->
                      case list.key_find(response.headers, "location") {
                        Ok(location) ->
                          redirect(token, url, location, max, hops)
                        Error(Nil) -> failed("redirect without a location")
                      }
                    status -> failed("status " <> int.to_string(status))
                  }
              }
            }
          }
        }
      }
  }
}

/// Follow a redirect from `from` to `location`, which may be relative.
fn redirect(
  token: Option(String),
  from: String,
  location: String,
  max: Int,
  hops: Int,
) -> Result(BitArray, FetchError) {
  let target = {
    use base <- result.try(uri.parse(from))
    use relative <- result.try(uri.parse(location))
    uri.merge(base, relative)
  }
  case target {
    Error(Nil) -> Error(FetchFailed("bad redirect"))
    Ok(target) -> {
      let token = case target.host {
        Some(host) ->
          case is_slack_file_host(host) {
            True -> token
            False -> None
          }
        None -> None
      }
      fetch_from(token, uri.to_string(target), max, hops - 1)
    }
  }
}

// Keeping ----------------------------------------------------------------------

/// Where a thread's attachments are kept on the bridge: the instance root
/// and the thread's key.
pub type Keep {
  Keep(root: String, key: String)
}

/// Keep a message's attachments on the bridge and describe them for the
/// prompt; small images and text go along as attachments too.
pub fn keep(
  token: String,
  files: List(Attachment),
  keep: Keep,
) -> #(String, List(client.Attachment)) {
  keep_as(token, files, keep, "Attached to this message:\n")
}

/// Keep the files of messages the prompt only caught up on, so the agent
/// can fetch those too.
pub fn keep_earlier(
  token: String,
  earlier: List(Earlier),
  keep: Keep,
) -> #(String, List(client.Attachment)) {
  let kept =
    list.map(earlier, fn(message) {
      let Earlier(ts:, files:) = message
      keep_as(
        token,
        files,
        keep,
        "Attached to the earlier message at " <> ts <> ":\n",
      )
    })
  #(
    list.map(kept, fn(pair) { pair.0 })
      |> list.filter(fn(text) { text != "" })
      |> string.join("\n\n"),
    list.flat_map(kept, fn(pair) { pair.1 }),
  )
}

/// Download `files` and keep them on the bridge. Returns a note for the
/// prompt, and the files that go along with it.
fn keep_as(
  token: String,
  attached: List(Attachment),
  keep: Keep,
  heading: String,
) -> #(String, List(client.Attachment)) {
  list.map(attached, fn(file) {
    let size = case file.size {
      Some(size) -> files.human_size(size)
      None -> "size unknown"
    }
    let failed = fn(why) {
      #(
        "- "
          <> file.name
          <> " ("
          <> file.mimetype
          <> ", "
          <> size
          <> "): "
          <> why,
        [],
      )
    }
    let too_large = "too large to fetch"
    // Slack's size is only a hint: the download is capped as it is read.
    case file.size {
      Some(size) if size > max_attachment_bytes -> failed(too_large)
      _ ->
        case fetch_file(token, file.url, max_attachment_bytes, 2) {
          Error(TooLarge) -> failed(too_large)
          Error(FetchFailed(reason)) ->
            failed("couldn't fetch (" <> reason <> ")")
          Ok(bytes) ->
            case files.store(keep.root, keep.key, file.id, file.name, bytes) {
              Error(reason) -> failed("couldn't keep (" <> reason <> ")")
              Ok(Nil) -> place(file.id, file.name, file.mimetype, bytes)
            }
        }
    }
  })
  |> describe(heading, _)
}

// Placing in the prompt --------------------------------------------------------

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
  let about = name <> " (" <> mimetype <> ", " <> files.human_size(size) <> ")"
  let fetch = "crushling-fetch " <> file_id
  let stored = #("- " <> about <> " - fetch it with: " <> fetch, [])
  let attach = fn(mime_type) {
    [client.Attachment(path: name, name:, mime_type:, content: bytes)]
  }
  case mime.image_type(mimetype, bytes), mime.is_text(name, mimetype) {
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
