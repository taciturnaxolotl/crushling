//// Posting to Slack from the registry, each on its own process so a slow
//// Slack never holds the registry up.

import crushling/conversation.{type Conversation, Conversation}
import crushling/registry/config.{type Config}
import crushling/registry/incoming.{type Incoming}
import crushling/slack
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import slackline

pub fn post(
  client: slackline.Client,
  place: Conversation,
  text: String,
) -> Nil {
  process.spawn_unlinked(fn() { slack.say(client, place, text) })
  Nil
}

/// Say something only `user` sees.
pub fn privately(
  client: slackline.Client,
  place: Conversation,
  user: String,
  text: String,
) -> Nil {
  process.spawn_unlinked(fn() { slack.whisper(client, place, user, text) })
  Nil
}

/// Clear the session's "Working…".
pub fn session_done(client: slackline.Client, place: Conversation) -> Nil {
  process.spawn_unlinked(fn() { slack.session_done(client, place) })
  Nil
}

/// Answer whoever sent `incoming`, privately.
pub fn whisper(config: Config, incoming: Incoming, text: String) -> Nil {
  conversation.from_slack(incoming.channel, incoming.thread_ts)
  |> privately(config.client, _, incoming.user, text)
}

/// Said in the thread, or at the top of a code channel.
pub fn announce(
  config: Config,
  incoming: Incoming,
  origin: Option(#(String, String)),
  text: String,
) -> Nil {
  let thread = case origin, incoming.ts == incoming.thread_ts {
    Some(_), True -> None
    _, _ -> Some(incoming.thread_ts)
  }
  post(config.client, Conversation(incoming.channel, thread), text)
}
