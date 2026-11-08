//// Socket Mode: one WebSocket to Slack, reopened whenever Slack asks or the
//// connection drops, with every event turned into a `msg.Incoming`.

import crushling/registry
import crushling/registry/incoming as msg
import crushling/registry/tailnet
import crushling/slack
import crushling/sys
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import slackline
import slackline/api/apps
import slackline/app
import slackline/event
import slackline/httpc
import slackline/interaction
import stratus

/// The router: Slack events in, `registry.Received` out.
pub fn router(
  registry: Subject(registry.Message),
  bot_user: String,
) -> app.App {
  app.unverified()
  |> app.on_event(fn(event, _delivery) {
    case event {
      // Slack's own stop control, shown while a session is processing.
      // A code channel's session has no thread.
      event.AgentSessionStopped(channel:, user:, thread_ts:, ..) ->
        process.send(
          registry,
          registry.StopRequested(
            channel,
            option.unwrap(thread_ts, ""),
            option.unwrap(user, ""),
          ),
        )
      _ ->
        case incoming(event, bot_user) {
          Ok(message) -> process.send(registry, registry.Received(message))
          Error(Nil) -> Nil
        }
    }
  })
  |> tailnet_buttons(registry)
}

/// The buttons on a tailnet card. The registry decides what each press
/// does; Slack only needs to hear that it arrived.
fn tailnet_buttons(
  app: app.App,
  registry: Subject(registry.Message),
) -> app.App {
  use app, action_id <- list.fold(tailnet.action_ids(), app)
  use action, payload <- app.action(app, action_id)
  case pressed(action, payload) {
    Ok(message) -> process.send(registry, message)
    Error(Nil) -> Nil
  }
  app.ack()
}

/// A button press on a tailnet card, as a registry message.
pub fn pressed(
  action: interaction.BlockAction,
  payload: interaction.BlockActionsPayload,
) -> Result(registry.Message, Nil) {
  use #(action_id, value) <- result.try(case action {
    interaction.ButtonAction(action_id:, value: Some(value), ..) ->
      Ok(#(action_id, value))
    _ -> Error(Nil)
  })
  use #(choice, channel, thread_ts) <- result.try(tailnet.read_button(
    action_id,
    value,
  ))
  use card <- result.map(case payload.container {
    Some(interaction.MessageContainer(message_ts:, channel_id:, thread_ts:, ..)) ->
      tailnet.card(channel_id, message_ts, thread_ts)
    _ -> Error(Nil)
  })
  let user = payload.user.id
  registry.Tailnet(
    registry.key(channel, thread_ts),
    tailnet.Pressed(choice:, channel:, thread_ts:, user:, card:),
  )
}

/// The messages worth routing: mentions, thread replies, direct messages,
/// and top-level messages (for code channels), from people rather than
/// bots.
pub fn incoming(
  event: event.Event,
  bot_user: String,
) -> Result(msg.Incoming, Nil) {
  let mentions_bot = fn(text) { string.contains(text, "<@" <> bot_user <> ">") }
  case event {
    event.AppMention(
      channel:,
      user: Some(user),
      text: Some(text),
      ts: Some(ts),
      thread_ts:,
      bot_id: None,
      subtype: None,
      files:,
      ..,
    ) ->
      Ok(msg.Incoming(
        channel:,
        thread_ts: option.unwrap(thread_ts, ts),
        ts:,
        user:,
        text:,
        mention: True,
        files: slack.attachments(files),
      ))
    event.MessageEvent(event.PlainMessage(
      channel:,
      user: Some(user),
      text: Some(text),
      ts: Some(ts),
      thread_ts:,
      channel_type:,
      bot_id: None,
      files:,
      ..,
    )) ->
      case mentions_bot(text), thread_ts, channel_type {
        // The app_mention event for the same message handles it.
        True, _, _ -> Error(Nil)
        // A direct message starts a thread, as a mention would.
        False, _, Some(event.Im) ->
          Ok(msg.Incoming(
            channel:,
            thread_ts: option.unwrap(thread_ts, ts),
            ts:,
            user:,
            text:,
            mention: True,
            files: slack.attachments(files),
          ))
        False, Some(root), _ ->
          Ok(msg.Incoming(
            channel:,
            thread_ts: root,
            ts:,
            user:,
            text:,
            mention: False,
            files: slack.attachments(files),
          ))
        // Top-level chatter, which only reaches the agent in one of its
        // code channels.
        False, None, _ ->
          Ok(msg.Incoming(
            channel:,
            thread_ts: ts,
            ts:,
            user:,
            text:,
            mention: False,
            files: slack.attachments(files),
          ))
      }
    // A message with files attached, when Slack gives it its own subtype.
    event.MessageEvent(event.FileShareMessage(
      channel: Some(channel),
      user: Some(user),
      text:,
      ts:,
      thread_ts:,
      channel_type:,
      bot_id: None,
      files:,
      ..,
    )) -> {
      let text = option.unwrap(text, "")
      case mentions_bot(text), thread_ts, channel_type {
        // A mention arrives as app_mention too.
        True, _, _ -> Error(Nil)
        _, _, _ ->
          Ok(msg.Incoming(
            channel:,
            thread_ts: option.unwrap(thread_ts, ts),
            ts:,
            user:,
            text:,
            mention: channel_type == Some(event.Im) && thread_ts == None,
            files: slack.attachments(files),
          ))
      }
    }
    _ -> Error(Nil)
  }
}

/// Connect and stay connected. Never returns.
pub fn run(app_token: String, router: app.App) -> Nil {
  case apps.connections_open() |> httpc.send(slackline.new(app_token)) {
    Error(error) -> {
      sys.warn(
        "crushling: connections.open: " <> slackline.describe_error(error),
      )
      process.sleep(5000)
      run(app_token, router)
    }
    Ok(opened) -> {
      session(opened.url, router)
      process.sleep(1000)
      run(app_token, router)
    }
  }
}

/// One WebSocket session; returns when it ends for any reason. stratus only
/// reports a clean close, so the connection process is monitored as well.
fn session(url: String, router: app.App) -> Nil {
  let url = case url {
    "wss://" <> rest -> "https://" <> rest
    "ws://" <> rest -> "http://" <> rest
    url -> url
  }
  let done = process.new_subject()
  case request.to(url) {
    Error(Nil) -> sys.warn("crushling: bad Socket Mode url")
    Ok(req) -> {
      let started =
        stratus.new(request: req, state: Nil)
        |> stratus.on_message(fn(state, message, connection) {
          case message {
            stratus.Text(frame) ->
              case app.handle_socket(router, frame) {
                app.Send(frame: reply, after:) -> {
                  let _ = stratus.send_text_message(connection, reply)
                  process.spawn_unlinked(after)
                  stratus.continue(state)
                }
                app.Reconnect(_) -> {
                  process.send(done, Nil)
                  stratus.stop()
                }
                app.Ignore -> stratus.continue(state)
              }
            _ -> stratus.continue(state)
          }
        })
        |> stratus.on_close(fn(_, _) { process.send(done, Nil) })
        |> stratus.start
      case started {
        Error(error) ->
          sys.warn("crushling: Socket Mode connect: " <> string.inspect(error))
        Ok(started) -> {
          let monitor = process.monitor(started.pid)
          let selector =
            process.new_selector()
            |> process.select(done)
            |> process.select_specific_monitor(monitor, fn(_) { Nil })
          let _ = process.selector_receive_forever(selector)
          process.demonitor_process(monitor)
          Nil
        }
      }
    }
  }
}
