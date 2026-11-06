//// The Slack side of a thread: a `thread.Sink` that shows a run as a status,
//// a plan card and markdown replies, and the helpers that turn a Slack
//// message back into a prompt.

import crushling/render
import crushling/thread
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import slackline
import slackline/api/assistant
import slackline/api/assistant/threads_set_status
import slackline/api/chat
import slackline/api/chat/post_ephemeral
import slackline/api/chat/post_message
import slackline/api/chat/update
import slackline/api/files/complete_upload_external
import slackline/api/reactions
import slackline/block
import slackline/element
import slackline/element/button
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

/// The action id of a run's Stop button. Its value is the run id.
pub const stop_action = "crushling_stop"

const loading_messages = [
  "is reading the thread", "is looking around", "is thinking it over",
  "is working on it", "is checking its work",
]

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
    status: fn(status) {
      // Best effort: the status is decoration, and Slack clears it itself
      // when the bot posts.
      let call =
        assistant.threads_set_status(channel_id: channel, thread_ts:, status:)
      let call = case status {
        "" -> call
        _ -> threads_set_status.loading_messages(call, loading_messages)
      }
      let _ = httpc.send(call, client)
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
    post_controls: fn(run_id) {
      post("Working on it", [
        block.actions(
          [
            element.button("Stop", stop_action, [
              button.value(run_id),
              button.style(block.Danger),
            ]),
          ],
          [],
        ),
      ])
    },
    delete: fn(ts) {
      let _ = chat.delete(channel:, ts:) |> httpc.send(client)
      Nil
    },
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

/// Reply to one user only, such as when they press Stop with nothing
/// running.
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

pub fn react(
  client: slackline.Client,
  channel: String,
  ts: String,
  name: String,
) -> Nil {
  let _ = reactions.add(channel:, name:, timestamp: ts) |> httpc.send(client)
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

/// A thread reply that asks to stop the current run.
pub fn is_stop(prompt: String) -> Bool {
  case string.lowercase(prompt) {
    "stop" | "cancel" | "stop!" -> True
    _ -> False
  }
}
