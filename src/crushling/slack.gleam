//// The Slack side of a thread: a `thread.Sink` that shows a run as an agent
//// session (Slack's "Working…" and Stop), a plan card and markdown replies, and the helpers that turn a Slack
//// message back into a prompt.

import crushling/gun
import crushling/render
import crushling/thread
import gleam/bit_array
import gleam/float
import gleam/http
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import slackline
import slackline/api/agents
import slackline/api/agents/sessions_rename
import slackline/api/agents/sessions_set_status
import slackline/api/chat
import slackline/api/chat/post_ephemeral
import slackline/api/chat/post_message
import slackline/api/chat/update
import slackline/api/conversations
import slackline/api/conversations/replies
import slackline/api/files/complete_upload_external
import slackline/block
import slackline/file
import slackline/httpc

/// Notifications and old clients show `text`; keep it short.
const fallback_length = 200

fn fallback(markdown: String) -> String {
  let text = string.trim(markdown)
  case string.length(text) > fallback_length {
    True -> string.slice(text, 0, fallback_length - 1) <> "…"
    False -> text
  }
}

fn send(run: fn() -> Result(a, slackline.Error)) -> Result(a, String) {
  httpc.retrying(attempts: 3, run:)
  |> result.map_error(slackline.describe_error)
}

fn markdown_blocks(markdown: String) -> List(block.Block) {
  [block.markdown(markdown, [])]
}

fn rich(text: String) -> Option(block.RichText) {
  case text {
    "" -> None
    text ->
      Some(block.RichText(
        elements: [block.rich_text_section([block.rich_text_run(text)])],
        block_id: None,
      ))
  }
}

fn plan_blocks(plan: render.Plan) -> List(block.Block) {
  let tasks =
    list.map(plan.tasks, fn(task) {
      block.PlanTask(
        task_id: task.id,
        title: task.title,
        status: case task.status {
          render.InProgress -> block.TaskInProgress
          render.Complete -> block.TaskComplete
          render.Failed -> block.TaskError
        },
        details: rich(task.details),
        output: rich(task.output),
        sources: None,
        icon: None,
        hide_title: None,
      )
    })
  [block.plan(plan.title, tasks, [])]
}

/// Everything a thread actor needs to reply in one Slack thread.
/// `finished` is called after each run's reply is posted.
pub fn sink(
  client: slackline.Client,
  channel: String,
  thread_ts: String,
  finished: fn(thread.Finished) -> Nil,
) -> thread.Sink {
  let branch = fn(intro, title) {
    use root <- result.try(
      send(fn() {
        chat.post_message(channel:, text: fallback(intro))
        |> post_message.blocks(markdown_blocks(intro))
        |> post_message.unfurl_links(False)
        |> httpc.send(client)
        |> result.map(fn(posted) { posted.ts })
      }),
    )
    let link =
      chat.get_permalink(channel:, message_ts: root)
      |> httpc.send(client)
      |> result.map(fn(found) { found.permalink })
      |> result.unwrap("")
    let branch = sink(client, channel, root, fn(_) { Nil })
    branch.title(title)
    Ok(#(branch, link))
  }
  let post = fn(text, blocks) {
    use <- send
    chat.post_message(channel:, text: fallback(text))
    |> post_message.thread_ts(thread_ts)
    |> post_message.blocks(blocks)
    |> post_message.unfurl_links(False)
    |> post_message.unfurl_media(False)
    |> httpc.send(client)
    |> result.map(fn(posted) { posted.ts })
  }
  let update = fn(ts, text, blocks) {
    use <- send
    chat.update(channel:, ts:)
    |> update.text(fallback(text))
    |> update.blocks(blocks)
    |> httpc.send(client)
    |> result.replace(Nil)
  }
  thread.Sink(
    working: fn(working) {
      case working {
        // Slack shows "Working…" with its Stop control until the session
        // is set back to active; posting no longer clears it.
        True -> session_status(client, channel, thread_ts, agents.Processing)
        False -> session_status(client, channel, thread_ts, agents.Active)
      }
    },
    title: fn(title) {
      let _ =
        agents.sessions_rename(title:)
        |> sessions_rename.channel_id(channel)
        |> sessions_rename.thread_ts(thread_ts)
        |> httpc.send(client)
      Nil
    },
    post_plan: fn(plan) {
      case post(plan.title, plan_blocks(plan)) {
        Ok(ts) -> Ok(ts)
        // A workspace that rejects plan blocks gets the same as markdown.
        Error(_) -> {
          let markdown = render.plan_markdown(plan)
          post(markdown, markdown_blocks(markdown))
        }
      }
    },
    update_plan: fn(ts, plan) {
      case update(ts, plan.title, plan_blocks(plan)) {
        Ok(Nil) -> Ok(Nil)
        Error(_) -> {
          let markdown = render.plan_markdown(plan)
          update(ts, markdown, markdown_blocks(markdown))
        }
      }
    },
    post: fn(markdown) { post(markdown, markdown_blocks(markdown)) },
    upload: fn(name, content) {
      let file =
        slackline.FileUpload(
          filename: name,
          content_type: "text/x-diff",
          contents: bit_array.from_string(content),
        )
      use <- send
      httpc.upload_files(client, [file], share: fn(call) {
        call
        |> complete_upload_external.channel_id(channel)
        |> complete_upload_external.thread_ts(thread_ts)
      })
      |> result.replace(Nil)
    },
    finished:,
    branch:,
  )
}

/// Set the thread's agent session status. Best effort: it is decoration,
/// and Slack times a working session out after an hour regardless.
fn session_status(
  client: slackline.Client,
  channel: String,
  thread_ts: String,
  status: agents.AgentStatus,
) -> Nil {
  let _ =
    agents.sessions_set_status(status:)
    |> sessions_set_status.channel_id(channel)
    |> sessions_set_status.thread_ts(thread_ts)
    |> httpc.send(client)
  Nil
}

/// Mark the thread's agent session as ready for the next prompt.
pub fn session_done(
  client: slackline.Client,
  channel: String,
  thread_ts: String,
) -> Nil {
  session_status(client, channel, thread_ts, agents.Active)
}

/// Reply to one user only, such as for `!help`.
pub fn whisper(
  client: slackline.Client,
  channel: String,
  thread_ts: String,
  user: String,
  text: String,
) -> Nil {
  let _ =
    chat.post_ephemeral(channel:, user:, text:)
    |> post_ephemeral.thread_ts(thread_ts)
    |> httpc.send(client)
  Nil
}

pub fn say(
  client: slackline.Client,
  channel: String,
  thread_ts: String,
  markdown: String,
) -> Nil {
  let _ =
    chat.post_message(channel:, text: fallback(markdown))
    |> post_message.thread_ts(thread_ts)
    |> post_message.blocks([block.markdown(markdown, [])])
    |> httpc.send(client)
  Nil
}

/// Turn the text of a Slack message into a prompt: drop mentions of the bot,
/// unwrap links, and undo Slack's escaping.
pub fn prompt_text(text: String, bot_user: String) -> String {
  text
  |> string.replace("<@" <> bot_user <> ">", "")
  |> unwrap_links
  |> string.replace("&lt;", "<")
  |> string.replace("&gt;", ">")
  |> string.replace("&amp;", "&")
  |> string.trim
}

/// `<https://x|label>` and `<https://x>` become `https://x`. Mentions and
/// channel references (`<@U1>`, `<#C1|name>`) are left as they are.
fn unwrap_links(text: String) -> String {
  case string.split(text, "<") {
    [] -> text
    [first, ..rest] ->
      list.fold(rest, first, fn(acc, part) {
        case string.split_once(part, ">") {
          Ok(#(inside, after)) ->
            case is_link(inside) {
              True -> {
                let url = case string.split_once(inside, "|") {
                  Ok(#(url, _)) -> url
                  Error(Nil) -> inside
                }
                acc <> url <> after
              }
              False -> acc <> "<" <> part
            }
          Error(Nil) -> acc <> "<" <> part
        }
      })
  }
}

fn is_link(inside: String) -> Bool {
  string.starts_with(inside, "http://")
  || string.starts_with(inside, "https://")
  || string.starts_with(inside, "mailto:")
}

pub type Command {
  StopCommand
  HelpCommand
  /// A `##` aside meant for the people in the thread, not the agent.
  SideComment
  NotACommand
}

pub fn command(prompt: String) -> Command {
  case string.lowercase(string.trim(prompt)) {
    "!stop" | "stop" | "cancel" | "stop!" -> StopCommand
    "!help" -> HelpCommand
    "##" <> _ -> SideComment
    _ -> NotACommand
  }
}

pub const help =
  "*crushling* runs a coding agent for this thread.\n• Reply in the thread to keep going; messages sent while it works run next.\n• `!stop` stops the current run.\n• Start a line with `##` to talk without the agent seeing it.\n• `!help` shows this."

/// A file attached to a Slack message.
pub type Attachment {
  Attachment(name: String, mimetype: String, size: Int, url: String)
}

pub fn attachments(files: Option(List(file.File))) -> List(Attachment) {
  option.unwrap(files, [])
  |> list.filter_map(fn(file) {
    case file.url_private, file.name {
      Some(url), Some(name) ->
        Ok(Attachment(
          name:,
          mimetype: option.unwrap(file.mimetype, "application/octet-stream"),
          size: option.unwrap(file.size, 0),
          url:,
        ))
      _, _ -> Error(Nil)
    }
  })
}

/// Files bigger than this are named in the prompt but not fetched.
const max_attachment_bytes = 25_000_000

@external(erlang, "crushling_ffi", "write_bytes")
fn write_bytes(path: String, bytes: BitArray) -> Result(Nil, String)

/// Fetch a Slack file with the bot token, following one redirect.
fn download(token: String, url: String, hops: Int) -> Result(BitArray, String) {
  use parsed <- result.try(uri.parse(url) |> result.replace_error("bad url"))
  use host <- result.try(option.to_result(parsed.host, "bad url"))
  let path = case parsed.query {
    Some(query) -> parsed.path <> "?" <> query
    None -> parsed.path
  }
  use conn <- result.try(gun.connect_tcp(host, 443, True, 10_000))
  let response =
    gun.request(
      conn,
      http.Get,
      path,
      [#("host", host), #("authorization", "Bearer " <> token)],
      <<>>,
      120_000,
    )
  gun.close(conn)
  use response <- result.try(response)
  case response.status {
    200 -> Ok(response.body)
    301 | 302 | 303 | 307 | 308 if hops > 0 ->
      case list.key_find(response.headers, "location") {
        Ok(location) -> download(token, location, hops - 1)
        Error(Nil) -> Error("redirect without a location")
      }
    status -> Error("status " <> int.to_string(status))
  }
}

/// Keep only characters that are safe in a file name.
fn safe_name(name: String) -> String {
  let cleaned =
    string.to_graphemes(name)
    |> list.map(fn(g) {
      case
        string.contains(
          "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-",
          g,
        )
      {
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

fn human_size(bytes: Int) -> String {
  case bytes {
    b if b < 1024 -> int.to_string(b) <> " B"
    b if b < 1_048_576 -> int.to_string(b / 1024) <> " KB"
    b -> int.to_string(b / 1_048_576) <> " MB"
  }
}

/// Save a message's attachments into the workspace and describe them for
/// the prompt. `dirs` is the host directory and the same directory as the
/// agent sees it, relative to its workspace.
pub fn save_attachments(
  token: String,
  files: List(Attachment),
  ts: String,
  dirs: #(String, String),
) -> String {
  let #(host_dir, agent_dir) = dirs
  let lines =
    list.map(files, fn(file) {
      let name = safe_name(file.name)
      let relative = agent_dir <> "/" <> safe_name(ts) <> "/" <> name
      let about = " (" <> file.mimetype <> ", " <> human_size(file.size) <> ")"
      case file.size > max_attachment_bytes {
        True -> "- " <> file.name <> about <> ": too large to fetch"
        False ->
          case download(token, file.url, 2) {
            Error(reason) ->
              "- "
              <> file.name
              <> about
              <> ": couldn't fetch ("
              <> reason
              <> ")"
            Ok(bytes) ->
              case
                write_bytes(
                  host_dir <> "/" <> safe_name(ts) <> "/" <> name,
                  bytes,
                )
              {
                Ok(Nil) -> "- `" <> relative <> "`" <> about
                Error(reason) ->
                  "- "
                  <> file.name
                  <> about
                  <> ": couldn't save ("
                  <> reason
                  <> ")"
              }
          }
      }
    })
  case lines {
    [] -> ""
    lines ->
      "Attached to this message, saved in the workspace:\n"
      <> string.join(lines, "\n")
  }
}

fn ts_value(ts: String) -> Float {
  case float.parse(ts) {
    Ok(value) -> value
    Error(Nil) ->
      int.parse(ts) |> result.map(int.to_float) |> result.unwrap(0.0)
  }
}

/// What happened in a thread between `after_ts` (exclusive; "" for the
/// start) and `before_ts` (exclusive), from people, as context for the next
/// prompt. The last `limit` messages are kept; `##` asides are left out.
pub fn catch_up(
  client: slackline.Client,
  channel: String,
  thread_ts: String,
  after_ts: String,
  before_ts: String,
  bot_user: String,
  limit: Int,
) -> String {
  let after = case after_ts {
    "" -> -1.0
    ts -> ts_value(ts)
  }
  let before = ts_value(before_ts)
  let lines =
    conversations.replies(channel:, ts: thread_ts)
    |> replies.limit(200)
    |> httpc.send(client)
    |> result.map(fn(response) { option.unwrap(response.messages, []) })
    |> result.unwrap([])
    |> list.filter_map(fn(message) {
      case message.user, message.text, message.ts, message.bot_id {
        Some(user), Some(text), Some(ts), None if user != bot_user -> {
          let at = ts_value(ts)
          case at >. after && at <. before, command(text) {
            True, NotACommand -> {
              let files = case attachments(message.files) {
                [] -> ""
                files ->
                  " [attached: "
                  <> string.join(list.map(files, fn(f) { f.name }), ", ")
                  <> "]"
              }
              Ok("[<@" <> user <> ">] " <> prompt_text(text, bot_user) <> files)
            }
            _, _ -> Error(Nil)
          }
        }
        _, _, _, _ -> Error(Nil)
      }
    })
  let count = list.length(lines)
  let heading = case after_ts {
    "" -> "Earlier in this Slack thread"
    _ -> "New in this Slack thread since your last turn"
  }
  case lines {
    [] -> ""
    lines ->
      heading
      <> case count > limit {
        True -> " (the last " <> int.to_string(limit) <> " messages)"
        False -> ""
      }
      <> ":\n"
      <> string.join(list.drop(lines, int.max(count - limit, 0)), "\n")
  }
}
