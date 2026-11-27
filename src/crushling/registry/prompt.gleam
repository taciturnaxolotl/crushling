//// Turning a Slack message into the agent's next prompt: what was said
//// since the agent last looked, who is asking, and any attached files,
//// kept on the bridge for the agent to fetch, with small images and text
//// sent along.

import crushling/attachments.{type Keep}
import crushling/conversation
import crushling/registry/incoming.{type Incoming}
import crushling/slack/text
import crushling/slack/workspace.{type Workspace}
import crushling/sys
import crushling/thread
import gleam/list
import gleam/string

/// How many earlier messages a prompt carries at most.
const catch_up_limit = 10

/// The prompt for `message`, keeping its files under `keep`. `cursor` is
/// the last message the agent read, and `catch_up` the thread to catch up
/// on, or "" for a whole code channel.
pub fn build(
  workspace: Workspace,
  keep: Keep,
  message: Incoming,
  cursor: String,
  catch_up: String,
) -> thread.Message {
  let request = text.prompt_text(message.text, workspace.bot_user(workspace))
  let first = catch_up != "" && message.ts == message.thread_ts && cursor == ""
  let text.CatchUp(text: context, earlier:) = case first {
    // The thread's first message: nothing came before.
    True -> text.nothing
    False ->
      case
        workspace.catch_up(
          workspace,
          conversation.from_slack(message.channel, catch_up),
          cursor,
          message.ts,
          catch_up_limit,
        )
      {
        Ok(caught_up) -> caught_up
        // The prompt still goes, without what came before.
        Error(reason) -> {
          sys.warn(
            "crushling: catching up in " <> message.channel <> ": " <> reason,
          )
          text.nothing
        }
      }
  }
  let #(earlier_files, earlier_seen) =
    workspace.keep_earlier(workspace, earlier, keep)
  let #(files, seen) =
    workspace.keep_attachments(workspace, message.files, keep)
  let from = case incoming.is_dm(message.channel) {
    True -> ""
    False -> "From <@" <> message.user <> ">:\n"
  }
  let prompt =
    [context, earlier_files, from <> request, files]
    |> list.filter(fn(part) { string.trim(part) != "" })
    |> string.join("\n\n")
  thread.Prompt(prompt, list.append(earlier_seen, seen), message.user)
}
