//// The Slack side of a thread: a `Sink` that shows a run as an agent
//// session (Slack's "Working…" and Stop), a plan card and markdown replies, and the helpers that turn a Slack
//// message back into a prompt.

import crushling/crush/client
import crushling/files
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
import slackline/interaction
import slackline/message
import slackline/stream
import slackline/stream/httpc as reply

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
  let branch = fn(intro, blocks, title) {
    // In a code channel a subagent gets a thread there; elsewhere a new
    // top-level message with its own session.
    let child = case in_code_channel {
      True -> InCodeThread
      False -> InThread
    }
    use root <- result.try(
      send(fn() {
        chat.post_message(channel:, text: fallback(intro))
        |> post_message.blocks(blocks)
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
    Ok(#(branch, link, root))
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
    post_blocks: post,
    update_blocks: update,
    delete: fn(ts) {
      use <- send
      chat.delete(channel:, ts:)
      |> httpc.send(client)
      |> result.replace(Nil)
    },
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
          set_code_commands(client, code)
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
      case place, string.trim(diff) {
        InCodeChannel, "" -> {
          let _ =
            agents.conversations_remove_view(channel_id: channel)
            |> httpc.send(client)
          Nil
        }
        InCodeChannel, _ -> {
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
        _, _ -> Nil
      }
    },
  )
}

/// A Slack error for logs and the agent; slackline includes the detail
/// Slack gives for vague codes like `invalid_arguments`.
pub fn describe(error: slackline.Error) -> String {
  slackline.describe_error(error)
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
/// Show the agent session in `channel` (and thread, if any) as working at
/// once, before its agent is even up: the thread's sink does the rest.
pub fn mark_working(
  client: slackline.Client,
  channel: String,
  thread_ts: Option(String),
) -> Nil {
  session_status(client, channel, thread_ts, agents.Processing)
}

fn session_status(
  client: slackline.Client,
  channel: String,
  thread_ts: Option(String),
  status: agents.AgentStatus,
) -> Nil {
  let call =
    agents.sessions_set_status(status:)
    |> sessions_set_status.channel_id(channel)
  let sent =
    case thread_ts {
      Some(ts) -> sessions_set_status.thread_ts(call, ts)
      None -> call
    }
    |> httpc.send(client)
  case sent {
    Ok(_) -> Nil
    Error(error) ->
      sys.warn(
        "crushling: setting the session in "
        <> channel
        <> " to "
        <> agents.agent_status_to_string(status)
        <> " failed: "
        <> describe(error),
      )
  }
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
    |> fn(call) {
      case thread_ts {
        "" -> call
        ts -> post_ephemeral.thread_ts(call, ts)
      }
    }
    |> httpc.send(client)
  Nil
}

/// The slash commands crushling offers in its code channels, by name
/// without the slash, each standing for its `!` command. None may be one of
/// Slack's own (`/status`, `/archive`…): a clash fails the whole set.
pub const code_commands = [
  #("pr", "Propose a pull request for the pushed branch", "[title]"),
  #("info", "Show the branch, what changed, and whether it's pushed", ""),
  #("done", "Wrap up: archive this channel", ""),
  #("stop", "Stop the current run", ""),
  #("model", "Show or switch the agent's model", "[model] [reasoning]"),
]

/// Offer `code_commands` in code channel `channel`. Best effort: the `!`
/// commands work regardless.
pub fn set_code_commands(client: slackline.Client, channel: String) -> Nil {
  let commands =
    list.map(code_commands, fn(command) {
      let #(name, description, hint) = command
      agents.AgentCommand(name:, description:, argument_hint: case hint {
        "" -> None
        hint -> Some(hint)
      })
    })
  case
    agents.conversations_set_commands(channel_id: channel, commands:)
    |> httpc.send(client)
  {
    Ok(_) -> Nil
    Error(error) ->
      sys.warn(
        "crushling: offering commands in " <> channel <> ": " <> describe(error),
      )
  }
}

/// Answer whoever pressed a button, privately, through its `response_url`,
/// leaving the message they pressed alone.
pub fn reply_ephemeral(response_url: String, text: String) -> Nil {
  let message =
    interaction.ResponseMessage(
      ..interaction.ephemeral(text),
      replace_original: Some(False),
    )
  let _ =
    httpc.webhook(response_url, interaction.response_message_to_json(message))
  Nil
}

/// Replace the ephemeral message an interaction came from, through its
/// `response_url`, with `text`.
pub fn replace_ephemeral(response_url: String, text: String) -> Nil {
  let message =
    interaction.ResponseMessage(
      ..interaction.ephemeral(text),
      replace_original: Some(True),
    )
  let _ =
    httpc.webhook(response_url, interaction.response_message_to_json(message))
  Nil
}

/// `whisper`, with blocks; `text` is the fallback for notifications.
pub fn whisper_blocks(
  client: slackline.Client,
  channel: String,
  thread_ts: String,
  user: String,
  text: String,
  blocks: List(block.Block),
) -> Nil {
  let _ =
    chat.post_ephemeral(channel:, user:, text:)
    |> post_ephemeral.thread_ts(thread_ts)
    |> post_ephemeral.blocks(blocks)
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
  /// Where the work stands: branch, changes, pushed or not.
  InfoCommand
  /// Post a card proposing a PR for the pushed branch, titled `title` if
  /// given.
  PrCommand(title: String)
  /// `!tailnet` asks to put the sandbox on the tailnet; `!tailnet off`
  /// takes it off.
  TailnetCommand(on: Bool)
  /// `!model` shows the model card; `!model <id> [level]` switches.
  ModelCommand(argument: String)
  /// `!github connect` or `!github disconnect`; `!github` alone connects.
  GitHubCommand(connect: Bool)
  /// A `##` aside meant for the people in the thread, not the agent.
  SideComment
  NotACommand
}

pub fn command(prompt: String) -> Command {
  let trimmed = string.trim(prompt)
  case string.lowercase(trimmed) {
    "!stop" | "stop" | "cancel" | "stop!" -> StopCommand
    "!help" -> HelpCommand
    "!pause" -> PauseCommand
    "!resume" | "!unpause" -> ResumeCommand
    "!done" | "!archive" -> DoneCommand
    "!info" -> InfoCommand
    "!pr" -> PrCommand("")
    "!tailnet" | "!tailscale" -> TailnetCommand(on: True)
    "!tailnet off" | "!tailscale off" -> TailnetCommand(on: False)
    "!github" | "!github connect" -> GitHubCommand(connect: True)
    "!github disconnect" -> GitHubCommand(connect: False)
    "!model" -> ModelCommand("")
    // Model ids keep their case: take the argument from the original.
    "!model " <> _ -> ModelCommand(string.trim(string.drop_start(trimmed, 7)))
    "!pr " <> _ -> PrCommand(string.trim(string.drop_start(trimmed, 4)))
    "##" <> _ -> SideComment
    _ -> NotACommand
  }
}

pub const help =
  "*crushling* runs a coding agent for this thread.\n• Reply in the thread to keep going; messages sent while it works run next.\n• `!stop` stops the current run.\n• `!pause` makes it answer only when mentioned; `!resume` has it follow along again.\n• `!pr [title]` posts a card proposing a pull request for the agent's pushed branch; whoever presses Open PR opens it, as themselves.\n• `!info` shows the branch, what changed, and whether it's pushed.\n• `!done` in a code channel archives it. In a code channel these are slash commands too: `/pr`, `/info`, `/done`, `/stop`, `/model`.\n• `!tailnet` asks to put the agent's sandbox on your tailnet for a while; `!tailnet off` ends it.\n• `!model` shows the model and lets you pick another and its reasoning; `!model <id> [level]` switches directly, and `!model default` goes back.\n• `!github` connects your GitHub account so agents can work in your repos as you; `!github disconnect` forgets it. The App Home has both too.\n• Start a line with `##` to talk without the agent seeing it.\n• `!help` shows this."

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

pub fn attachments(files: Option(List(file.File))) -> List(Attachment) {
  option.unwrap(files, [])
  |> list.filter_map(fn(file) {
    case file.id, file.url_private, file.name {
      Some(id), Some(url), Some(name) ->
        Ok(Attachment(
          id:,
          name:,
          mimetype: option.unwrap(file.mimetype, "application/octet-stream"),
          size: file.size,
          url:,
        ))
      _, _, _ -> Error(Nil)
    }
  })
}

/// Files bigger than this are named in the prompt but not kept.
const max_attachment_bytes = files.max_upload_bytes

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

/// Where a thread's attachments are kept on the bridge: the instance root
/// and the thread's key.
pub type Keep {
  Keep(root: String, key: String)
}

/// Keep a message's attachments on the bridge and describe them for the
/// prompt; small images and text go along as attachments too.
pub fn keep_attachments(
  token: String,
  files: List(Attachment),
  keep: Keep,
) -> #(String, List(client.Attachment)) {
  keep_attachments_as(token, files, keep, "Attached to this message:\n")
}

/// Keep the files of messages the prompt only caught up on, so the agent
/// can fetch those too.
pub fn keep_earlier_attachments(
  token: String,
  earlier: List(Earlier),
  keep: Keep,
) -> #(String, List(client.Attachment)) {
  let kept =
    list.map(earlier, fn(message) {
      let Earlier(ts:, files:) = message
      keep_attachments_as(
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
fn keep_attachments_as(
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
              Ok(Nil) -> files.place(file.id, file.name, file.mimetype, bytes)
            }
        }
    }
  })
  |> files.describe(heading, _)
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

/// An earlier message's files, to keep with the prompt that catches up on
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
