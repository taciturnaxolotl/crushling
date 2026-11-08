//// The Slack side of a thread: a `Sink` that shows a run as an agent
//// session (Slack's "Working…" and Stop), a plan card and markdown replies, and the helpers that turn a Slack
//// message back into a prompt.

import crushling/crush/client
import crushling/gun
import crushling/render
import crushling/sink.{type Sink} as thread_sink
import crushling/sys
import gleam/bit_array
import gleam/bool
import gleam/erlang/process
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
import slackline/api/agents/conversations_archive
import slackline/api/agents/conversations_create
import slackline/api/agents/conversations_set_properties
import slackline/api/agents/conversations_set_view
import slackline/api/agents/sessions_rename
import slackline/api/agents/sessions_set_status
import slackline/api/chat
import slackline/api/chat/post_ephemeral
import slackline/api/chat/post_message
import slackline/api/chat/update
import slackline/api/conversations
import slackline/api/conversations/history
import slackline/api/conversations/replies
import slackline/api/files/complete_upload_external
import slackline/block
import slackline/file
import slackline/httpc
import slackline/message
import slackline/stream
import slackline/stream/httpc as reply
import slackline/value

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
  |> result.map_error(describe)
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
        status: task_status(task.status),
        details: rich(task.details),
        output: rich(task.output),
        sources: None,
        icon: None,
        hide_title: None,
      )
    })
  [block.plan(plan.title, tasks, [])]
}

fn stream_task(task: render.Task) -> stream.Task {
  stream.Task(
    id: task.id,
    title: task.title,
    status: case task.status {
      render.InProgress -> stream.Running
      render.Complete -> stream.Done
      render.Failed -> stream.Failed
    },
    details: task.details,
    output: task.output,
  )
}

fn task_status(status: render.TaskStatus) -> block.TaskStatus {
  case status {
    render.InProgress -> block.TaskInProgress
    render.Complete -> block.TaskComplete
    render.Failed -> block.TaskError
  }
}

/// Where a sink posts.
pub type Place {
  /// A thread, with its own agent session.
  InThread(thread_ts: String)
  /// A code channel: top-level posts, and the channel is the session.
  InCodeChannel
  /// A thread inside a code channel, which can't have a session of its
  /// own; for subagents working there.
  InCodeThread(thread_ts: String)
}

/// Everything a thread actor needs to reply in one place in Slack.
/// `team` is the workspace's id: Slack streams a reply in a channel to one
/// person, named by user and team.
pub fn sink(
  client: slackline.Client,
  team: String,
  channel: String,
  place: Place,
) -> Sink {
  let thread_ts = case place {
    InThread(ts) | InCodeThread(ts) -> Some(ts)
    InCodeChannel -> None
  }
  let has_session = case place {
    InCodeThread(_) -> False
    _ -> True
  }
  let in_code_channel = case place {
    InThread(_) -> False
    _ -> True
  }
  let post = fn(text, blocks) {
    use <- send
    let call =
      chat.post_message(channel:, text: fallback(text))
      |> post_message.blocks(blocks)
      |> post_message.unfurl_links(False)
      |> post_message.unfurl_media(False)
    case thread_ts {
      Some(ts) -> post_message.thread_ts(call, ts)
      None -> call
    }
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
  // A run's reply streams where Slack can, and falls back to a plan card
  // and messages where it can't; slackline's stream handles both.
  let open_reply = fn(from) {
    let builder =
      stream.new(client, channel:)
      |> stream.to(user: from, team:)
    let builder = case thread_ts {
      Some(ts) -> stream.in_thread(builder, ts)
      None -> builder
    }
    case reply.open(builder) {
      Error(error) -> {
        sys.warn("crushling: couldn't open a reply: " <> string.inspect(error))
        thread_sink.Reply(show: fn(_, _, _) { Nil }, finish: fn(_) { [] })
      }
      Ok(opened) ->
        thread_sink.Reply(
          show: fn(text, tasks, title) {
            reply.text(opened, text)
            list.each(tasks, fn(task) { reply.task(opened, stream_task(task)) })
            reply.title(opened, title)
          },
          finish: fn(closing) {
            case reply.finish(opened, closing:) {
              Ok(finished) -> {
                case finished.problem {
                  Some(problem) ->
                    sys.warn("crushling: the reply didn't stream: " <> problem)
                  None -> Nil
                }
                finished.messages
              }
              Error(Nil) -> {
                sys.warn("crushling: the reply's writer stopped answering")
                []
              }
            }
          },
        )
    }
  }
  let set_status = fn(status) {
    case has_session {
      True -> session_status(client, channel, thread_ts, status)
      False -> Nil
    }
  }
  let branch = fn(intro, title) {
    // In a code channel a subagent gets a thread there; elsewhere a new
    // top-level message with its own session.
    let child = case in_code_channel {
      True -> InCodeThread
      False -> InThread
    }
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
    let branch = sink(client, team, channel, child(root))
    branch.title(title)
    Ok(#(branch, link))
  }
  thread_sink.Sink(
    conversation: thread_sink.Conversation(channel, thread_ts),
    // Slack shows "Working…" with its Stop control until the session is
    // set back to active; posting doesn't clear it.
    working: fn(working) {
      set_status(case working {
        True -> agents.Processing
        False -> agents.Active
      })
    },
    title: fn(title) {
      case has_session {
        False -> Nil
        True -> {
          let call =
            agents.sessions_rename(title:)
            |> sessions_rename.channel_id(channel)
          let _ =
            case thread_ts {
              Some(ts) -> sessions_rename.thread_ts(call, ts)
              None -> call
            }
            |> httpc.send(client)
          Nil
        }
      }
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
    reply: open_reply,
    post: fn(markdown) { post(markdown, markdown_blocks(markdown)) },
    upload: fn(name, content) {
      case in_code_channel {
        // The Code tab shows the changes there.
        True -> Ok(Nil)
        False -> {
          let file =
            slackline.FileUpload(
              filename: name,
              content_type: "text/x-diff",
              contents: bit_array.from_string(content),
            )
          use <- send
          httpc.upload_files(client, [file], share: fn(call) {
            let call = complete_upload_external.channel_id(call, channel)
            case thread_ts {
              Some(ts) -> complete_upload_external.thread_ts(call, ts)
              None -> call
            }
          })
          |> result.replace(Nil)
        }
      }
    },
    branch:,
    open_code_channel: fn(name) {
      case place {
        InThread(root) -> {
          use opened <- result.try(
            agents.conversations_create()
            |> conversations_create.name(string.slice(name, 0, 80))
            |> conversations_create.origin_channel_id(channel)
            |> conversations_create.origin_message_ts(root)
            // A session that was archived and picked up again gets a new
            // channel, so the id can't be the thread alone; kept short.
            |> conversations_create.session_id(sys.uuid())
            |> httpc.send(client)
            |> result.map_error(fn(error) {
              describe(error) <> " creating a code channel named " <> name
            }),
          )
          let code = opened.channel_id
          let channel_sink = sink(client, team, code, InCodeChannel)
          channel_sink.title(name)
          Ok(#(channel_sink, code))
        }
        _ -> Error("already in a code channel")
      }
    },
    context: fn(items) {
      case place {
        InCodeChannel -> {
          let items =
            list.take(items, 5)
            |> list.map(fn(item) {
              agents.ContextBarItem(
                key: item.key,
                label: item.label,
                icon: Some(item.icon),
                url: case item.url {
                  "" -> None
                  url -> Some(url)
                },
                item_type: None,
              )
            })
          let _ =
            agents.conversations_set_properties(channel_id: channel)
            |> conversations_set_properties.code_channel(
              agents.CodeChannelProperties(
                context_bar_items: Some(items),
                summary_message: None,
              ),
            )
            |> httpc.send(client)
          Nil
        }
        _ -> Nil
      }
    },
    code: fn(diff, base, head) {
      case place {
        InCodeChannel -> {
          let call =
            agents.conversations_set_view(channel_id: channel)
            |> conversations_set_view.type_("diff")
            |> conversations_set_view.content(diff)
          let call = case base {
            "" -> call
            base -> conversations_set_view.base_branch(call, base)
          }
          let call = case head {
            "" | "HEAD" -> call
            head -> conversations_set_view.head_branch(call, head)
          }
          let attempt = fn() {
            httpc.send(call, client)
            |> result.map_error(describe)
          }
          // A brand-new channel can refuse its first view for a moment.
          let sent = case attempt() {
            Error(reason) ->
              case string.contains(reason, "view_creation_failed") {
                True -> {
                  process.sleep(2000)
                  attempt()
                }
                False -> Error(reason)
              }
            ok -> ok
          }
          case sent {
            Ok(_) -> Nil
            Error(reason) ->
              sys.warn("crushling: Code tab update failed: " <> reason)
          }
        }
        _ -> Nil
      }
    },
  )
}

/// A Slack error for logs and the agent, with the detail Slack gives for
/// vague codes like `invalid_arguments` in `response_metadata.messages`.
pub fn describe(error: slackline.Error) -> String {
  let base = slackline.describe_error(error)
  case error {
    slackline.ApiError(response:, ..) ->
      case value.at(response, ["response_metadata", "messages"]) {
        Ok(value.Array(messages)) ->
          case
            list.filter_map(messages, fn(message) {
              case message {
                value.String(text) -> Ok(text)
                _ -> Error(Nil)
              }
            })
          {
            [] -> base
            details -> base <> " (" <> string.join(details, "; ") <> ")"
          }
        _ -> base
      }
    _ -> base
  }
}

/// Archive a code channel once its work is done, keeping `summary_ts` (a
/// message in it, or "") as its summary.
pub fn archive_code_channel(
  client: slackline.Client,
  channel: String,
  summary_ts: String,
) -> Result(Nil, String) {
  let call = agents.conversations_archive(channel_id: channel)
  case summary_ts {
    "" -> call
    ts -> conversations_archive.summary_message_ts(call, ts)
  }
  |> httpc.send(client)
  |> result.replace(Nil)
  |> result.map_error(describe)
}

/// Set an agent session's status: a thread's, or a whole code channel's
/// when there is no thread. Best effort: it is decoration, and Slack times
/// a working session out after an hour regardless.
fn session_status(
  client: slackline.Client,
  channel: String,
  thread_ts: Option(String),
  status: agents.AgentStatus,
) -> Nil {
  let call =
    agents.sessions_set_status(status:)
    |> sessions_set_status.channel_id(channel)
  let _ =
    case thread_ts {
      Some(ts) -> sessions_set_status.thread_ts(call, ts)
      None -> call
    }
    |> httpc.send(client)
  Nil
}

/// Mark the agent session as ready for the next prompt. `thread_ts` is ""
/// for a code channel.
pub fn session_done(
  client: slackline.Client,
  channel: String,
  thread_ts: String,
) -> Nil {
  let thread = case thread_ts {
    "" -> None
    ts -> Some(ts)
  }
  session_status(client, channel, thread, agents.Active)
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
    |> fn(call) {
      case thread_ts {
        "" -> call
        ts -> post_message.thread_ts(call, ts)
      }
    }
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
  /// Stop following: only mentions reach the agent until `!resume`.
  PauseCommand
  ResumeCommand
  /// Archive the code channel: the work is done.
  DoneCommand
  /// A `##` aside meant for the people in the thread, not the agent.
  SideComment
  NotACommand
}

pub fn command(prompt: String) -> Command {
  case string.lowercase(string.trim(prompt)) {
    "!stop" | "stop" | "cancel" | "stop!" -> StopCommand
    "!help" -> HelpCommand
    "!pause" -> PauseCommand
    "!resume" | "!unpause" -> ResumeCommand
    "!done" | "!archive" -> DoneCommand
    "##" <> _ -> SideComment
    _ -> NotACommand
  }
}

pub const help =
  "*crushling* runs a coding agent for this thread.\n• Reply in the thread to keep going; messages sent while it works run next.\n• `!stop` stops the current run.\n• `!pause` makes it answer only when mentioned; `!resume` has it follow along again.\n• `!done` in a code channel archives it.\n• Start a line with `##` to talk without the agent seeing it.\n• `!help` shows this."

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
) -> #(String, List(client.Attachment)) {
  save_attachments_as(
    token,
    files,
    ts,
    dirs,
    "Attached to this message, saved in the workspace:\n",
  )
}

/// Save the files of messages the prompt only caught up on, so the agent
/// can open those too.
pub fn save_earlier_attachments(
  token: String,
  earlier: List(Earlier),
  dirs: #(String, String),
) -> #(String, List(client.Attachment)) {
  let saved =
    list.map(earlier, fn(message) {
      let Earlier(ts:, files:) = message
      save_attachments_as(
        token,
        files,
        ts,
        dirs,
        "Attached to the earlier message at "
          <> ts
          <> ", saved in the workspace:\n",
      )
    })
  #(
    list.map(saved, fn(pair) { pair.0 })
      |> list.filter(fn(text) { text != "" })
      |> string.join("\n\n"),
    list.flat_map(saved, fn(pair) { pair.1 }),
  )
}

/// Image types models take directly, and how big such an image can be.
const seen_images = ["image/png", "image/jpeg", "image/gif", "image/webp"]

const max_seen_image_bytes = 5_000_000

/// Download `files` into the workspace. Returns a note for the prompt, and
/// the images, which go along with the prompt for the model to see.
fn save_attachments_as(
  token: String,
  files: List(Attachment),
  ts: String,
  dirs: #(String, String),
  heading: String,
) -> #(String, List(client.Attachment)) {
  let #(host_dir, agent_dir) = dirs
  let saved =
    list.map(files, fn(file) {
      let name = safe_name(file.name)
      let relative = agent_dir <> "/" <> safe_name(ts) <> "/" <> name
      let about = " (" <> file.mimetype <> ", " <> human_size(file.size) <> ")"
      let failed = fn(why) { #("- " <> file.name <> about <> ": " <> why, []) }
      use <- bool.lazy_guard(file.size > max_attachment_bytes, fn() {
        failed("too large to fetch")
      })
      case download(token, file.url, 2) {
        Error(reason) -> failed("couldn't fetch (" <> reason <> ")")
        Ok(bytes) ->
          case
            write_bytes(host_dir <> "/" <> safe_name(ts) <> "/" <> name, bytes)
          {
            Error(reason) -> failed("couldn't save (" <> reason <> ")")
            Ok(Nil) ->
              case
                list.contains(seen_images, file.mimetype)
                && bit_array.byte_size(bytes) <= max_seen_image_bytes
              {
                False -> #("- `" <> relative <> "`" <> about, [])
                True -> #(
                  "- `"
                    <> relative
                    <> "`"
                    <> about
                    <> ", attached for you to see",
                  [
                    client.Attachment(
                      path: relative,
                      name: file.name,
                      mime_type: file.mimetype,
                      content: bytes,
                    ),
                  ],
                )
              }
          }
      }
    })
  case list.map(saved, fn(pair) { pair.0 }) {
    [] -> #("", [])
    lines -> #(
      heading <> string.join(lines, "\n"),
      list.flat_map(saved, fn(pair) { pair.1 }),
    )
  }
}

/// A Slack ts as seconds.
pub fn ts_value(ts: String) -> Float {
  case float.parse(ts) {
    Ok(value) -> value
    Error(Nil) ->
      int.parse(ts) |> result.map(int.to_float) |> result.unwrap(0.0)
  }
}

/// Read a conversation, oldest first: a thread's replies, or with no
/// `thread_ts` a channel's top level. `after_ts` and `before_ts` ("" for
/// no bound) narrow a channel's history; a thread's replies come whole.
/// At most 200 messages.
pub fn read_conversation(
  client: slackline.Client,
  channel: String,
  thread_ts: String,
  after_ts: String,
  before_ts: String,
) -> Result(List(message.Message), String) {
  case thread_ts {
    "" -> {
      let call = conversations.history(channel:) |> history.limit(200)
      let call = case before_ts {
        "" -> call
        ts -> history.latest(call, ts)
      }
      case after_ts {
        "" -> call
        ts -> history.oldest(call, ts)
      }
      |> httpc.send(client)
      // History is newest first.
      |> result.map(fn(response) {
        option.unwrap(response.messages, []) |> list.reverse
      })
    }
    ts ->
      conversations.replies(channel:, ts:)
      |> replies.limit(200)
      |> httpc.send(client)
      |> result.map(fn(response) { option.unwrap(response.messages, []) })
  }
  |> result.map_error(describe)
}

/// " [attached: a.png, b.txt]" for a message's files, or "".
pub fn files_note(files: List(Attachment)) -> String {
  case files {
    [] -> ""
    files ->
      " [attached: "
      <> string.join(list.map(files, fn(file) { file.name }), ", ")
      <> "]"
  }
}

/// An earlier message's files, to save with the prompt that catches up on
/// it.
pub type Earlier {
  Earlier(ts: String, files: List(Attachment))
}

/// What a prompt says of what came before it, and the earlier files.
pub type CatchUp {
  CatchUp(text: String, earlier: List(Earlier))
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
) -> CatchUp {
  let after = case after_ts {
    "" -> -1.0
    ts -> ts_value(ts)
  }
  let before = ts_value(before_ts)
  // A code channel is caught up on as a whole.
  let found = read_conversation(client, channel, thread_ts, after_ts, before_ts)
  let kept =
    result.unwrap(found, [])
    |> list.filter_map(fn(message) {
      case message.user, message.text, message.ts, message.bot_id {
        Some(user), Some(text), Some(ts), None if user != bot_user -> {
          let at = ts_value(ts)
          case at >. after && at <. before, command(text) {
            True, NotACommand -> {
              let files = attachments(message.files)
              Ok(#(
                "[<@"
                  <> user
                  <> ">] "
                  <> prompt_text(text, bot_user)
                  <> files_note(files),
                Earlier(ts, files),
              ))
            }
            _, _ -> Error(Nil)
          }
        }
        _, _, _, _ -> Error(Nil)
      }
    })
  let count = list.length(kept)
  let kept = list.drop(kept, int.max(count - limit, 0))
  let lines = list.map(kept, fn(pair) { pair.0 })
  let earlier =
    list.filter_map(kept, fn(pair) {
      case pair.1 {
        Earlier(files: [], ..) -> Error(Nil)
        with_files -> Ok(with_files)
      }
    })
  let place = case thread_ts {
    "" -> "Slack channel"
    _ -> "Slack thread"
  }
  let heading = case after_ts {
    "" -> "Earlier in this " <> place
    _ -> "New in this " <> place <> " since your last turn"
  }
  let text = case lines {
    [] -> ""
    lines ->
      heading
      <> case count > limit {
        True -> " (the last " <> int.to_string(limit) <> " messages)"
        False -> ""
      }
      <> ":\n"
      <> string.join(lines, "\n")
  }
  CatchUp(text:, earlier:)
}
