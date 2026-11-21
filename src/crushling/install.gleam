//// Installing the app in a Slack workspace with OAuth v2, served on the
//// events server beside `/slack/events`:
////
//// - `GET /slack/install` redirects to Slack's authorize page with the bot
////   scopes, the redirect URI and a signed state;
//// - `GET /slack/oauth/callback` checks the state, exchanges the code with
////   `oauth.v2.access`, stores the workspace (token encrypted), starts its
////   instance and shows a plain page.
////
//// The state is slackline's: an HMAC of its issue time and a nonce, here
//// keyed with the instance secret, and good for ten minutes.
////
//// Until the app's "public distribution" is turned on in its settings, only
//// the workspace the app was created in can complete an install. No
//// Marketplace listing is needed either way.

import crushling/store.{type Store}
import crushling/sys
import gleam/bytes_tree
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mist
import slackline
import slackline/api/oauth as oauth_api
import slackline/api/oauth/v2_access
import slackline/httpc
import slackline/oauth
import slackline/verify

pub type Config {
  Config(
    client_id: String,
    client_secret: String,
    /// The bridge's public base URL, such as `https://crushling.example`.
    public_url: String,
    /// The instance secret, which signs the state.
    secret: String,
    store: Store,
    /// An anonymous Slack client for `oauth.v2.access`.
    slack: slackline.Client,
    /// Start the new workspace's instance.
    on_installed: fn(store.Team) -> Result(Nil, String),
    /// The self-host workspace, from `SLACK_BOT_TOKEN`, if any: its people
    /// come from the environment, so an install never writes them.
    env_team: Option(String),
  )
}

/// The bot scopes the app asks for, as in `docs/slack-manifest.yaml`.
pub const scopes = [
  "app_mentions:read", "assistant:write", "channels:history", "channels:read",
  "groups:history", "groups:read", "im:history", "chat:write",
  "code_channels:manage", "files:read", "files:write", "users:read",
]

pub fn redirect_uri(config: Config) -> String {
  trim_slash(config.public_url) <> "/slack/oauth/callback"
}

fn trim_slash(url: String) -> String {
  case string.ends_with(url, "/") {
    True -> trim_slash(string.drop_end(url, 1))
    False -> url
  }
}

/// The state key: the instance secret, kept apart from its other uses.
fn state_key(secret: String) -> String {
  "install:" <> secret
}

pub fn sign_state(secret: String, now: Int) -> String {
  oauth.sign_state_at(state_key(secret), now)
}

pub fn verify_state(
  secret: String,
  state: String,
  now: Int,
) -> Result(Nil, oauth.StateError) {
  oauth.verify_state_at(state_key(secret), state, now)
}

/// Slack's authorize page for this app, with a fresh state.
pub fn authorize_url(config: Config, now: Int) -> String {
  oauth.authorize_url(
    oauth.Authorize(
      ..oauth.authorize(client_id: config.client_id),
      scopes:,
      redirect_uri: Some(redirect_uri(config)),
      state: Some(sign_state(config.secret, now)),
    ),
  )
}

/// Finish an install from the callback's query: check the state, exchange
/// the code, store the workspace and start it.
pub fn callback(
  config: Config,
  query: List(#(String, String)),
  now: Int,
) -> Result(store.Team, String) {
  use _ <- result.try(case list.key_find(query, "error") {
    Ok(error) -> Error("Slack said: " <> error)
    Error(Nil) -> Ok(Nil)
  })
  use state <- result.try(
    list.key_find(query, "state") |> result.replace_error("there's no state"),
  )
  use _ <- result.try(
    verify_state(config.secret, state, now)
    |> result.map_error(fn(error) {
      case error {
        oauth.ExpiredState -> "the install link expired"
        oauth.InvalidState -> "the install link isn't one of ours"
      }
    }),
  )
  use code <- result.try(
    list.key_find(query, "code") |> result.replace_error("there's no code"),
  )
  use access <- result.try(
    oauth_api.v2_access()
    |> v2_access.client_id(config.client_id)
    |> v2_access.client_secret(config.client_secret)
    |> v2_access.code(code)
    |> v2_access.redirect_uri(redirect_uri(config))
    |> httpc.send(config.slack)
    |> result.map_error(fn(error) {
      "oauth.v2.access: " <> slackline.describe_error(error)
    }),
  )
  use team <- result.try(team_from(access, now))
  use known <- result.try(store.team(config.store, team.id))
  use _ <- result.try(store.put_team(config.store, team))
  // Only a new workspace, and never the self-host one, gets its installer
  // as its people; a reinstall keeps what it has.
  use _ <- result.try(case known, config.env_team {
    Some(_), _ -> Ok(Nil)
    None, Some(env) if env == team.id -> Ok(Nil)
    None, _ -> seed_people(config.store, team)
  })
  use _ <- result.map(
    config.on_installed(team)
    |> result.map_error(fn(reason) {
      let _ = store.set_active(config.store, team.id, False)
      "the workspace was saved but couldn't start ("
      <> reason
      <> "), so it is turned off until you install again"
    }),
  )
  sys.info(
    "crushling: installed in "
    <> team.id
    <> " by "
    <> case team.installed_by {
      "" -> "someone"
      user -> user
    },
  )
  team
}

fn team_from(
  access: oauth_api.OAuthV2AccessResponse,
  now: Int,
) -> Result(store.Team, String) {
  let enterprise_id = option.map(access.enterprise, fn(org) { org.id })
  // The app isn't set up for org deployment (the manifest's
  // org_deploy_enabled is false), and routing assumes one workspace per
  // install.
  use _ <- result.try(case access.is_enterprise_install {
    Some(True) -> Error("org-wide installs aren't supported yet")
    _ -> Ok(Nil)
  })
  use id <- result.try(case access.team {
    Some(team) -> Ok(team.id)
    None -> Error("Slack named no workspace")
  })
  use bot_token <- result.try(option.to_result(
    access.access_token,
    "Slack sent no bot token",
  ))
  use bot_user <- result.map(option.to_result(
    access.bot_user_id,
    "Slack sent no bot user",
  ))
  store.Team(
    id:,
    bot_token:,
    bot_user:,
    enterprise_id:,
    installed_by: option.map(access.authed_user, fn(user) { user.id })
      |> option.unwrap(""),
    installed_at: now,
    active: True,
  )
}

/// Whoever installed the app in a new workspace may use it and approve
/// tailnet access, until the workspace's settings say otherwise.
fn seed_people(store: Store, team: store.Team) -> Result(Nil, String) {
  case team.installed_by {
    "" -> Ok(Nil)
    user -> {
      use _ <- result.try(store.set_setting(
        store,
        team.id,
        store.allowed_users,
        user,
      ))
      store.set_setting(store, team.id, store.admins, user)
    }
  }
}

// HTTP ------------------------------------------------------------------------

/// Answer `/slack/install` and `/slack/oauth/callback`; None for anything
/// else.
pub fn route(
  config: Config,
  req: Request(a),
) -> Option(Response(mist.ResponseData)) {
  case request.path_segments(req), req.method {
    ["slack", "install"], http.Get ->
      Some(
        response.new(302)
        |> response.set_header(
          "location",
          authorize_url(config, verify.now_seconds()),
        )
        |> response.set_body(mist.Bytes(bytes_tree.new())),
      )
    ["slack", "oauth", "callback"], http.Get -> {
      let query = request.get_query(req) |> result.unwrap([])
      Some(case callback(config, query, verify.now_seconds()) {
        Ok(_) ->
          page(
            200,
            "crushling is installed",
            "Mention @crushling in a channel it's in, or send it a direct message, to start.",
          )
        Error(reason) -> {
          sys.warn("crushling: install failed: " <> reason)
          page(
            400,
            "crushling wasn't installed",
            escape(reason) <> ". <a href=\"/slack/install\">Start again</a>.",
          )
        }
      })
    }
    _, _ -> None
  }
}

fn page(
  status: Int,
  title: String,
  body: String,
) -> Response(mist.ResponseData) {
  let html =
    "<!doctype html><meta charset=\"utf-8\"><title>"
    <> escape(title)
    <> "</title><body style=\"font-family: sans-serif; max-width: 36em; margin: 4em auto\"><h1>"
    <> escape(title)
    <> "</h1><p>"
    <> body
    <> "</p></body>"
  response.new(status)
  |> response.set_header("content-type", "text/html; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(html)))
}

fn escape(text: String) -> String {
  text
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
}
