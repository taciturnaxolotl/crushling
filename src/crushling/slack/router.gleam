//// The router: Slack events and interactions in, registry messages out to
//// the registry of the workspace each belongs to. One app serves every
//// workspace the app is installed in, over Socket Mode
//// (`router(app.unverified(), …)`) or HTTP (`app.new(signing_secret)`):
//// slackline hands each handler the `team_id` (and `enterprise_id`) it
//// came with, and `find` picks the workspace. Anything for a workspace
//// with none is dropped, with a log line.

import crushling/attachments
import crushling/commands
import crushling/github/nudge
import crushling/home
import crushling/instance.{type Instance, Instance}
import crushling/pr
import crushling/registry
import crushling/registry/incoming.{type Incoming}
import crushling/registry/tailnet
import crushling/slack/model_card
import crushling/slack/workspace.{type Workspace}
import crushling/sys
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import slackline/app
import slackline/event
import slackline/file
import slackline/interaction

/// How the router finds a workspace, from the `team_id` and
/// `enterprise_id` something arrived with.
pub type Find =
  fn(Option(String), Option(String)) -> Result(Instance, Nil)

/// Buttons and menus whose presses `decode` turns into a registry message.
type Interaction {
  Interaction(
    actions: List(String),
    decode: fn(
      interaction.BlockAction,
      interaction.BlockActionsPayload,
      Workspace,
    ) -> Result(registry.Message, Nil),
  )
}

fn interactions() -> List(Interaction) {
  [
    Interaction(pr.actions(), fn(action, payload, _) {
      pr.decode(action, payload) |> result.map(registry.PrPressed)
    }),
    Interaction(home.actions(), fn(action, payload, _) {
      // Asks posted before they had an action of their own use the Home's.
      case nudge.decode(action, payload) {
        Ok(pressed) -> Ok(nudged(pressed))
        Error(Nil) ->
          home.decode(action, payload)
          |> result.map(fn(pressed) {
            case pressed {
              home.Connect(user) -> registry.GitHubConnect(user)
              home.Disconnect(user) -> registry.GitHubDisconnect(user)
            }
          })
      }
    }),
    Interaction(nudge.actions(), fn(action, payload, _) {
      nudge.decode(action, payload) |> result.map(nudged)
    }),
    Interaction(tailnet.action_ids(), fn(action, payload, workspace) {
      tailnet.decode(action, payload, workspace.team(workspace))
      |> result.map(fn(pressed) { registry.Tailnet(pressed.0, pressed.1) })
    }),
    Interaction(model_card.actions(), fn(action, payload, _) {
      use model_card.Picked(home:, pick:, card:, user:) <- result.map(
        model_card.decode(action, payload),
      )
      registry.ModelPicked(home:, pick:, card:, user:)
    }),
  ]
}

fn nudged(pressed: nudge.Pressed) -> registry.Message {
  case pressed {
    nudge.ConnectHere(user:, place:) -> registry.GitHubConnectIn(user, place)
    nudge.Installing(respond:, text:) -> registry.Respond(respond, text, True)
  }
}

pub fn router(base: app.App, find: Find) -> app.App {
  base
  |> app.on_event(fn(event, delivery: app.Delivery) {
    let #(team, enterprise) = receiver(delivery)
    use Instance(workspace:, registry:) <- served(find, team, enterprise)
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
        case incoming(event, workspace.bot_user(workspace)) {
          Ok(message) -> process.send(registry, registry.Received(message))
          Error(Nil) -> Nil
        }
    }
  })
  |> list.fold(interactions(), _, fn(app, handler) {
    list.fold(handler.actions, app, fn(app, action_id) {
      use action, payload <- app.action(app, action_id)
      let team = option.map(payload.team, fn(team) { team.id })
      let enterprise = option.map(payload.enterprise, fn(org) { org.id })
      served(find, team, enterprise, fn(found) {
        case handler.decode(action, payload, found.workspace) {
          Ok(message) -> process.send(found.registry, message)
          Error(Nil) -> Nil
        }
      })
      app.ack()
    })
  })
  |> code_commands(find)
}

/// The slash commands offered in code channels: each is its `!` command,
/// said in the channel by whoever typed it.
fn code_commands(app: app.App, find: Find) -> app.App {
  use app, slash <- list.fold(commands.slash_commands(), app)
  let name = slash.name
  use command <- app.command(app, "/" <> name)
  served(find, command.team_id, command.enterprise_id, fn(found) {
    process.send(
      found.registry,
      registry.Slash(
        channel: command.channel_id,
        user: command.user_id,
        text: commands.from_slash(name, option.unwrap(command.text, "")),
      ),
    )
  })
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

/// Hand the workspace serving `team` (or `enterprise`) to `next`, or drop
/// what came for it with a log line.
fn served(
  find: Find,
  team: Option(String),
  enterprise: Option(String),
  next: fn(Instance) -> Nil,
) -> Nil {
  case find(team, enterprise) {
    Ok(found) -> next(found)
    Error(Nil) ->
      sys.warn(
        "crushling: dropping an event for "
        <> case team, enterprise {
          Some(team), _ -> "unknown workspace " <> team
          None, Some(enterprise) -> "unknown organization " <> enterprise
          None, None -> "no workspace"
        },
      )
  }
}

/// The messages worth routing: mentions, thread replies, direct messages,
/// and top-level messages (for code channels), from people rather than
/// bots.
pub fn incoming(event: event.Event, bot_user: String) -> Result(Incoming, Nil) {
  let mentions_bot = fn(text) { string.contains(text, "<@" <> bot_user <> ">") }
  let message = fn(
    channel,
    thread_ts,
    ts,
    user,
    text,
    mention,
    files: Option(List(file.File)),
  ) {
    Ok(incoming.Incoming(
      channel:,
      thread_ts:,
      ts:,
      user:,
      text:,
      mention:,
      files: attachments.from_slack(files),
    ))
  }
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
      message(
        channel,
        option.unwrap(thread_ts, ts),
        ts,
        user,
        text,
        True,
        files,
      )
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
          message(
            channel,
            option.unwrap(thread_ts, ts),
            ts,
            user,
            text,
            True,
            files,
          )
        False, Some(root), _ ->
          message(channel, root, ts, user, text, False, files)
        // Top-level chatter, which only reaches the agent in one of its
        // code channels.
        False, None, _ -> message(channel, ts, ts, user, text, False, files)
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
      case mentions_bot(text) {
        // A mention arrives as app_mention too.
        True -> Error(Nil)
        False ->
          message(
            channel,
            option.unwrap(thread_ts, ts),
            ts,
            user,
            text,
            channel_type == Some(event.Im) && thread_ts == None,
            files,
          )
      }
    }
    _ -> Error(Nil)
  }
}
