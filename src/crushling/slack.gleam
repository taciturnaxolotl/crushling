//// The Slack side of a thread: a `thread.Sink` that shows a run as an agent
//// session (Slack's "Working…" and Stop), a plan card and markdown replies, and the helpers that turn a Slack
//// message back into a prompt.

import crushling/render
import crushling/thread
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
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

/// The messages before `before_ts` in a thread, as context for an agent
/// first mentioned partway in. At most `limit` of the latest, from people.
pub fn thread_context(
  client: slackline.Client,
  channel: String,
  thread_ts: String,
  before_ts: String,
  bot_user: String,
  limit: Int,
) -> String {
  let lines =
    conversations.replies(channel:, ts: thread_ts)
    |> replies.limit(100)
    |> httpc.send(client)
    |> result.map(fn(response) { option.unwrap(response.messages, []) })
    |> result.unwrap([])
    |> list.filter_map(fn(message) {
      case message.user, message.text, message.ts, message.bot_id {
        Some(user), Some(text), Some(ts), None
          if ts != before_ts && user != bot_user
        ->
          case string.compare(ts, before_ts), command(text) {
            order.Lt, NotACommand ->
              Ok("[<@" <> user <> ">] " <> prompt_text(text, bot_user))
            _, _ -> Error(Nil)
          }
        _, _, _, _ -> Error(Nil)
      }
    })
  let count = list.length(lines)
  case lines {
    [] -> ""
    lines ->
      "Earlier in this Slack thread"
      <> case count > limit {
        True -> " (the last " <> int.to_string(limit) <> " messages)"
        False -> ""
      }
      <> ":\n"
      <> string.join(list.drop(lines, int.max(count - limit, 0)), "\n")
  }
}
