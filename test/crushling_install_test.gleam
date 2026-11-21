//// Installing the app in a workspace with OAuth: the signed state, the
//// code exchange against a stand-in for Slack, and the workspace stored and
//// started.

import crushling/events
import crushling/install
import crushling/store
import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mist
import slackline
import slackline/oauth
import slackline/verify

@external(erlang, "erlang", "unique_integer")
fn unique() -> Int

@external(erlang, "crushling_ffi", "read_file")
fn read_file(path: String) -> Result(String, Nil)

fn port() -> Int {
  24_000 + int.absolute_value(unique()) % 3000
}

fn open_store() -> store.Store {
  let assert Ok(key) =
    store.parse_key("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")
  let assert Ok(s) = store.start(":memory:", key)
  s
}

const install_body =
  "{\"ok\":true,\"access_token\":\"xoxb-new\",\"token_type\":\"bot\",\"scope\":\"chat:write\",\"bot_user_id\":\"UBOTNEW\",\"app_id\":\"A1\",\"team\":{\"id\":\"TNEW\",\"name\":\"New <Team>\"},\"enterprise\":null,\"authed_user\":{\"id\":\"UINSTALLER\"}}"

/// oauth.v2.access, answering every code with workspace TNEW, and passing
/// on the form it was sent.
fn fake_oauth(forms: Subject(String)) -> String {
  fake_oauth_with(forms, install_body)
}

fn fake_oauth_with(forms: Subject(String), answer: String) -> String {
  let port = port()
  let assert Ok(started) =
    mist.new(fn(req: request.Request(mist.Connection)) {
      let body = case mist.read_body(req, 100_000) {
        Ok(req) -> req.body
        Error(_) -> <<>>
      }
      let form = case req.query {
        Some(query) -> query
        None -> ""
      }
      process.send(
        forms,
        req.path <> "?" <> form <> "&" <> result.unwrap(bits(body), ""),
      )
      response.new(200)
      |> response.set_header("content-type", "application/json")
      |> response.set_body(mist.Bytes(bytes_tree.from_string(answer)))
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(port)
    |> mist.start
  // Stopped after a while, so the suite doesn't run out of file
  // descriptors.
  process.unlink(started.pid)
  process.spawn_unlinked(fn() {
    process.sleep(5000)
    process.kill(started.pid)
  })
  "http://127.0.0.1:" <> int.to_string(port) <> "/api"
}

fn bits(body: BitArray) -> Result(String, Nil) {
  bit_array.to_string(body)
}

fn config(
  s: store.Store,
  api: String,
  installed: Subject(store.Team),
) -> install.Config {
  let assert Ok(slack) = slackline.anonymous() |> slackline.with_base_url(api)
  install.Config(
    client_id: "123.456",
    client_secret: "shh",
    public_url: "https://crushling.example/",
    secret: "instance-secret",
    store: s,
    slack:,
    on_installed: fn(team) {
      process.send(installed, team)
      Ok(Nil)
    },
    env_team: None,
  )
}

fn callback(c: install.Config) -> Result(store.Team, String) {
  let now = verify.now_seconds()
  let state = install.sign_state("instance-secret", now)
  install.callback(c, [#("code", "the-code"), #("state", state)], now)
}

pub fn a_reinstall_leaves_settings_alone_test() {
  let s = open_store()
  let c = config(s, fake_oauth(process.new_subject()), process.new_subject())
  let assert Ok(Nil) =
    store.put_team(
      s,
      store.Team(
        id: "TNEW",
        bot_token: "xoxb-old",
        bot_user: "UBOTNEW",
        enterprise_id: None,
        installed_by: "UFIRST",
        installed_at: 5,
        active: True,
      ),
    )
  let assert Ok(Nil) = store.set_setting(s, "TNEW", store.allowed_users, "U7")
  let assert Ok(_) = callback(c)
  let assert Ok(Some("U7")) = store.setting(s, "TNEW", store.allowed_users)
  let assert Ok(None) = store.setting(s, "TNEW", store.admins)
  // The new token, and the first install's installer.
  let assert Ok(Some(store.Team(
    bot_token: "xoxb-new",
    installed_by: "UFIRST",
    installed_at: 5,
    ..,
  ))) = store.team(s, "TNEW")
}

pub fn installing_into_the_self_host_workspace_writes_no_people_test() {
  let s = open_store()
  let c =
    install.Config(
      ..config(s, fake_oauth(process.new_subject()), process.new_subject()),
      env_team: Some("TNEW"),
    )
  let assert Ok(_) = callback(c)
  let assert Ok(settings) = store.settings(s, "TNEW")
  let assert True = dict.is_empty(settings)
}

pub fn org_wide_installs_are_refused_test() {
  let s = open_store()
  let installed = process.new_subject()
  let body =
    "{\"ok\":true,\"access_token\":\"xoxb-org\",\"bot_user_id\":\"UBOT\",\"team\":null,\"enterprise\":{\"id\":\"E1\"},\"is_enterprise_install\":true,\"authed_user\":{\"id\":\"U1\"}}"
  let c = config(s, fake_oauth_with(process.new_subject(), body), installed)
  let assert Error(reason) = callback(c)
  let assert "org-wide installs aren't supported yet" = reason
  let assert Ok(None) = store.team(s, "E1")
  let assert Error(Nil) = process.receive(installed, 50)
}

pub fn a_workspace_that_won_t_start_is_turned_off_test() {
  let s = open_store()
  let c =
    install.Config(
      ..config(s, fake_oauth(process.new_subject()), process.new_subject()),
      on_installed: fn(_) { Error("boom") },
    )
  let assert Error(reason) = callback(c)
  let assert True = string.contains(reason, "turned off")
  let assert Ok(Some(store.Team(active: False, ..))) = store.team(s, "TNEW")
  let assert Ok([]) = store.active_teams(s)
}

pub fn state_is_signed_and_expires_test() {
  let now = 1_800_000_000
  let state = install.sign_state("instance-secret", now)
  let assert Ok(Nil) = install.verify_state("instance-secret", state, now + 60)
  let assert Error(oauth.ExpiredState) =
    install.verify_state("instance-secret", state, now + 601)
  let assert Error(oauth.InvalidState) =
    install.verify_state("another-secret", state, now)
  let assert Error(oauth.InvalidState) =
    install.verify_state("instance-secret", state <> "x", now)
  // Signed with the instance secret itself, as slackline would, isn't ours.
  let assert Error(oauth.InvalidState) =
    install.verify_state(
      "instance-secret",
      oauth.sign_state_at("instance-secret", now),
      now,
    )
}

pub fn the_authorize_url_asks_for_the_manifest_s_scopes_test() {
  let c = config(open_store(), "http://127.0.0.1:1/api", process.new_subject())
  let url = install.authorize_url(c, verify.now_seconds())
  let assert True =
    string.starts_with(url, "https://slack.com/oauth/v2/authorize?")
  let assert Ok(parsed) = uri.parse(url)
  let assert Some(query) = parsed.query
  let assert Ok(params) = uri.parse_query(query)
  let assert Ok("123.456") = list.key_find(params, "client_id")
  let assert Ok("https://crushling.example/slack/oauth/callback") =
    list.key_find(params, "redirect_uri")
  let assert Ok(state) = list.key_find(params, "state")
  let assert Ok(Nil) =
    install.verify_state("instance-secret", state, verify.now_seconds())
  let assert Ok(scope) = list.key_find(params, "scope")
  let assert True = string.split(scope, ",") == install.scopes
  // The same scopes as the manifest's bot scopes.
  let assert Ok(manifest) = read_file("docs/slack-manifest.yaml")
  let assert [_, after_bot] = string.split(manifest, "    bot:\n")
  let assert [block, ..] = string.split(after_bot, "  pkce_enabled")
  let in_manifest =
    string.split(block, "\n")
    |> list.map(string.trim)
    |> list.filter(fn(line) { string.starts_with(line, "- ") })
    |> list.map(string.drop_start(_, 2))
  let assert True = in_manifest == install.scopes
}

pub fn the_callback_stores_and_starts_the_workspace_test() {
  let s = open_store()
  let forms = process.new_subject()
  let installed = process.new_subject()
  let c = config(s, fake_oauth(forms), installed)
  let now = verify.now_seconds()
  let state = install.sign_state("instance-secret", now)
  let assert Ok(team) =
    install.callback(c, [#("code", "the-code"), #("state", state)], now)
  let assert "TNEW" = team.id
  // The exchange sent the code, the app's credentials and the redirect URI.
  let assert Ok(form) = process.receive(forms, 1000)
  let assert True = string.contains(form, "oauth.v2.access")
  let assert True = string.contains(form, "code=the-code")
  let assert True = string.contains(form, "client_secret=shh")
  let assert True = string.contains(form, "redirect_uri=")
  // Stored, token and all, and started.
  let assert Ok(Some(stored)) = store.team(s, "TNEW")
  let assert "xoxb-new" = stored.bot_token
  let assert "UBOTNEW" = stored.bot_user
  let assert "UINSTALLER" = stored.installed_by
  let assert Ok(store.Team(id: "TNEW", ..)) = process.receive(installed, 1000)
  // Whoever installed it may use it.
  let assert Ok(Some("UINSTALLER")) =
    store.setting(s, "TNEW", store.allowed_users)
  let assert Ok(Some("UINSTALLER")) = store.setting(s, "TNEW", store.admins)
}

pub fn a_bad_callback_installs_nothing_test() {
  let s = open_store()
  let forms = process.new_subject()
  let installed = process.new_subject()
  let c = config(s, fake_oauth(forms), installed)
  let now = verify.now_seconds()
  let old = install.sign_state("instance-secret", now - 3600)
  let assert Error(_) =
    install.callback(c, [#("code", "c"), #("state", old)], now)
  let assert Error(_) =
    install.callback(c, [#("code", "c"), #("state", "forged")], now)
  let assert Error(_) = install.callback(c, [#("code", "c")], now)
  let assert Error(_) =
    install.callback(c, [#("error", "access_denied"), #("state", old)], now)
  let assert Error(Nil) = process.receive(forms, 100)
  let assert Error(Nil) = process.receive(installed, 50)
  let assert Ok(None) = store.team(s, "TNEW")
}

pub fn install_is_served_on_the_events_server_test() {
  let s = open_store()
  let forms = process.new_subject()
  let installed = process.new_subject()
  let c = config(s, fake_oauth(forms), installed)
  let port = port()
  let assert Ok(Nil) = events.start("127.0.0.1", port, None, Some(c))
  let base = "http://127.0.0.1:" <> int.to_string(port)
  let assert Ok(req) = request.to(base <> "/slack/install")
  let assert Ok(res) =
    httpc.configure() |> httpc.follow_redirects(False) |> httpc.dispatch(req)
  let assert 302 = res.status
  let assert Ok(location) = response.get_header(res, "location")
  let assert True =
    string.starts_with(location, "https://slack.com/oauth/v2/authorize?")
  let state = install.sign_state("instance-secret", verify.now_seconds())
  let assert Ok(req) =
    request.to(
      base
      <> "/slack/oauth/callback?code=abc&state="
      <> uri.percent_encode(state),
    )
  let assert Ok(res) = httpc.send(req)
  let assert 200 = res.status
  let assert True = string.contains(res.body, "installed")
  let assert Ok(store.Team(id: "TNEW", ..)) = process.receive(installed, 1000)
  // A forged one says why, escaped.
  let assert Ok(req) =
    request.to(base <> "/slack/oauth/callback?error=%3Cscript%3E")
  let assert Ok(res) = httpc.send(req)
  let assert 400 = res.status
  let assert False = string.contains(res.body, "<script>")
  // Without HTTP events, /slack/events isn't served.
  let assert Ok(req) = request.to(base <> "/slack/events")
  let assert Ok(res) = httpc.send(req)
  let assert 404 = res.status
}
