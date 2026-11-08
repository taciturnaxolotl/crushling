//// Turning a Slack message into the agent's next prompt: what was said
//// since the agent last looked, who is asking, and any attached files,
//// saved into the workspace.

import crushling/registry/incoming.{type Incoming}
import crushling/slack
import crushling/thread
import gleam/list
import gleam/string
import slackline

/// How many earlier messages a prompt carries at most.
const catch_up_limit = 10

/// What building a prompt needs: the Slack client and bot token, the bot's
/// user id, and where attachments go (on the host, and in the workspace).
pub type Source {
  Source(
    client: slackline.Client,
    token: String,
    bot_user: String,
    dirs: #(String, String),
  )
}

/// The prompt for `message`. `cursor` is the last message the agent read,
/// and `catch_up` the thread to catch up on, or "" for a whole code channel.
pub fn build(
  source: Source,
  message: Incoming,
  cursor: String,
  catch_up: String,
) -> thread.Message {
  let request = slack.prompt_text(message.text, source.bot_user)
  let first = catch_up != "" && message.ts == message.thread_ts && cursor == ""
  let slack.CatchUp(text: context, earlier:) = case first {
    // The thread's first message: nothing came before.
    True -> slack.CatchUp("", [])
    False ->
      slack.catch_up(
        source.client,
        message.channel,
        catch_up,
        cursor,
        message.ts,
        source.bot_user,
        catch_up_limit,
      )
  }
  let #(earlier_files, earlier_seen) =
    slack.save_earlier_attachments(source.token, earlier, source.dirs)
  let #(files, seen) =
    slack.save_attachments(source.token, message.files, message.ts, source.dirs)
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
