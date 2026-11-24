//// Socket Mode: one WebSocket to Slack, reopened whenever Slack asks or the
//// connection drops, with every event turned into a `msg.Incoming`.

import crushling/connections
import crushling/home
import crushling/models
import crushling/registry
import crushling/registry/incoming as msg
import crushling/registry/tailnet
import crushling/slack
import crushling/sys
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import slackline
import slackline/api/apps
import slackline/app
import slackline/event
import slackline/httpc
import slackline/interaction
import slackline/view
import stratus

/// The registry that serves one Slack workspace, with what routing needs
/// to know about it.
pub type Target {
  Target(team: String, bot_user: String, registry: Subject(registry.Message))
}

/// How the router finds a workspace's registry, from an event's `team_id`
/// and `enterprise_id`.
pub type Find =
  fn(Option(String), Option(String)) -> Result(Target, Nil)

/// One workspace only: for tests and anything with a single registry.
pub fn only(target: Target) -> Find {
  fn(team, enterprise) {
    case team, enterprise {
      Some(team), _ if team == target.team -> Ok(target)
      None, Some(enterprise) if enterprise == target.team -> Ok(target)
      _, _ -> Error(Nil)
    }
  }
}

/// The router: Slack events in, `registry.Received` out to the registry of
/// the workspace each event belongs to. One app serves every workspace the
/// app is installed in: slackline hands each handler the event's
/// `team_id` (and `enterprise_id`), and `find` picks the registry. An
/// event for a workspace with none is dropped, with a log line. Over
/// Socket Mode it is `router(app.unverified(), …)`; over HTTP,
/// `app.new(signing_secret)`.
pub fn router(base: app.App, find: Find) -> app.App {
  base
  |> app.on_event(fn(event, delivery: app.Delivery) {
    let #(team, enterprise) = receiver(delivery)
    case target(find, team, enterprise) {
      Error(Nil) -> Nil
      Ok(Target(bot_user:, registry:, ..)) ->
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
          // The Messages tab opens it too; only the Home tab has a view.
          event.AppHomeOpened(user: Some(user), tab: Some("home"), ..) ->
            process.send(registry, registry.HomeOpened(user))
          _ ->
            case incoming(event, bot_user) {
              Ok(message) -> process.send(registry, registry.Received(message))
              Error(Nil) -> Nil
            }
        }
    }
  })
  |> tailnet_buttons(find)
  |> model_menus(find)
  |> home_buttons(find)
}

/// The GitHub buttons on the App Home, and on the asks in threads.
fn home_buttons(app: app.App, find: Find) -> app.App {
  let app = {
    // A link: GitHub opens in the browser; here the ask says what's next.
    use action, payload <- app.action(app, home.install_action)
    case action, payload.response_url {
      interaction.ButtonAction(value: Some(owner), ..), Some(url) -> {
        process.spawn_unlinked(fn() {
          slack.replace_ephemeral(url, home.installing(owner))
        })
        Nil
      }
      _, _ -> Nil
    }
    app.ack()
  }
  use app, action_id <- list.fold(
    [home.connect_action, home.disconnect_action],
    app,
  )
  use action, payload <- app.action(app, action_id)
  let team = option.map(payload.team, fn(team) { team.id })
  let enterprise = option.map(payload.enterprise, fn(org) { org.id })
  // The note asking someone in a thread carries the thread; the Home's
  // buttons carry nothing.
  let place = case action {
    interaction.ButtonAction(value: Some(value), ..) ->
      home.nudged_from(value)
      |> result.map(fn(pair) {
        connections.Place(pair.0, pair.1, payload.response_url)
      })
    _ -> Error(Nil)
  }
  case target(find, team, enterprise) {
    Ok(Target(registry:, ..)) -> {
      let user = payload.user.id
      process.send(registry, case action_id == home.connect_action, place {
        True, Ok(place) -> registry.GitHubConnectIn(user, place)
        True, Error(Nil) -> registry.GitHubConnect(user)
        False, _ -> registry.GitHubDisconnect(user)
      })
    }
    Error(Nil) -> Nil
  }
  app.ack()
}

/// The installation an event was delivered to: its `authorizations` name
/// it, which matters in a Slack Connect channel, where `team_id` is the
/// workspace the event happened in. Without them, `team_id`.
pub fn receiver(delivery: app.Delivery) -> #(Option(String), Option(String)) {
  case delivery.authorizations {
    [
      event.EnvelopeAuthorization(team_id: Some(_) as team, enterprise_id:, ..),
      ..
    ]
    | [
        event.EnvelopeAuthorization(
          team_id: None as team,
          enterprise_id: Some(_) as enterprise_id,
          ..,
        ),
        ..
      ] -> #(team, enterprise_id)
    _ -> #(delivery.team_id, delivery.enterprise_id)
  }
}

fn target(
  find: Find,
  team: Option(String),
  enterprise: Option(String),
) -> Result(Target, Nil) {
  case find(team, enterprise) {
    Ok(target) -> Ok(target)
    Error(Nil) -> {
      sys.warn(
        "crushling: dropping an event for "
        <> case team, enterprise {
          Some(team), _ -> "unknown workspace " <> team
          None, Some(enterprise) -> "unknown organization " <> enterprise
          None, None -> "no workspace"
        },
      )
      Error(Nil)
    }
  }
}

/// The buttons on a tailnet card. The registry decides what each press
/// does; Slack only needs to hear that it arrived.
fn tailnet_buttons(app: app.App, find: Find) -> app.App {
  use app, action_id <- list.fold(tailnet.action_ids(), app)
  use action, payload <- app.action(app, action_id)
  let team = option.map(payload.team, fn(team) { team.id })
  let enterprise = option.map(payload.enterprise, fn(org) { org.id })
  case target(find, team, enterprise) {
    Ok(Target(team:, registry:, ..)) ->
      case pressed(action, payload, team) {
        Ok(message) -> process.send(registry, message)
        Error(Nil) -> Nil
      }
    Error(Nil) -> Nil
  }
  app.ack()
}

/// A button press on a tailnet card in workspace `team`, as a registry
/// message.
pub fn pressed(
  action: interaction.BlockAction,
  payload: interaction.BlockActionsPayload,
  team: String,
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
    registry.key(team, channel, thread_ts),
    tailnet.Pressed(choice:, channel:, thread_ts:, user:, card:),
  )
}

/// The model menu and Confirm button on a `!model` card. The thread does
/// the switching; Slack only needs to hear that the action arrived.
fn model_menus(app: app.App, find: Find) -> app.App {
  use app, action_id <- list.fold(
    [models.model_action, models.confirm_action],
    app,
  )
  use action, payload <- app.action(app, action_id)
  let team = option.map(payload.team, fn(team) { team.id })
  let enterprise = option.map(payload.enterprise, fn(org) { org.id })
  case target(find, team, enterprise), picked(action, payload) {
    Ok(Target(registry:, ..)), Ok(message) -> process.send(registry, message)
    _, _ -> Nil
  }
  app.ack()
}

/// An action on a model card, as a registry message. The block id names
/// the thread the card belongs to, which may not be where the card is (a
/// code channel's card sits at the top of the channel).
pub fn picked(
  action: interaction.BlockAction,
  payload: interaction.BlockActionsPayload,
) -> Result(registry.Message, Nil) {
  use #(block_id, pick) <- result.try(case action {
    // The model menu changed.
    interaction.StaticSelectAction(
      action_id:,
      block_id: Some(block_id),
      selected_option: Some(option),
      ..,
    )
      if action_id == models.model_action
    -> Ok(#(block_id, models.Preview(option.value)))
    // Confirm: what the menus hold now is in the payload's state.
    interaction.ButtonAction(action_id:, block_id: Some(block_id), ..)
      if action_id == models.confirm_action
    -> {
      let value = fn(of) { menu_value(payload.state, of) }
      let model =
        option.or(value(models.model_action), models.confirm_model(block_id))
      use pick <- result.map(models.read_confirm(
        model,
        value(models.reasoning_action),
      ))
      #(block_id, pick)
    }
    _ -> Error(Nil)
  })
  use home <- result.try(models.read_block_id(block_id))
  use card <- result.map(case payload.container {
    Some(interaction.MessageContainer(message_ts:, channel_id:, thread_ts:, ..)) ->
      tailnet.card(channel_id, message_ts, thread_ts)
    _ -> Error(Nil)
  })
  registry.ModelPicked(home:, pick:, card:, user: payload.user.id)
}

/// The value picked in the card's menu `action_id`, whichever block it is in.
fn menu_value(
  state: Option(view.ViewState),
  action_id: String,
) -> Option(String) {
  case state {
    None -> None
    Some(state) ->
      dict.values(state.values)
      |> list.find_map(fn(block) {
        case dict.get(block, action_id) {
          Ok(view.StateStaticSelect(selected_option: Some(option))) ->
            Ok(option.value)
          _ -> Error(Nil)
        }
      })
      |> option.from_result
  }
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
