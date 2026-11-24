//// One bridge, several workspaces: each event reaches only its own
//// workspace's registry, which talks to Slack with its own token.

import crushling/crush/client
import crushling/instance
import crushling/launcher
import crushling/people
import crushling/registry
import crushling/slack_tools
import crushling/socket
import crushling/store
import crushling/sys
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import gleam/string
import mist
import slackline
import slackline/app

@external(erlang, "erlang", "unique_integer")
fn unique() -> Int

@external(erlang, "crushling_ffi", "mkdir_p")
fn mkdir_p(path: String) -> Result(Nil, String)

fn tmp() -> String {
  let dir = "/tmp/crushling-instance-" <> sys.uuid()
  let assert Ok(Nil) = mkdir_p(dir)
  dir
}

/// A Slack Web API that records each call's method and token, and answers
/// auth.test as workspace TA.
fn fake_slack(calls: Subject(#(String, String))) -> #(String, process.Pid) {
  let port = 21_000 + int.absolute_value(unique()) % 3000
  let assert Ok(started) =
    mist.new(fn(req: request.Request(mist.Connection)) {
      let token =
        request.get_header(req, "authorization")
        |> result.unwrap("")
        |> string.replace("Bearer ", "")
      let method = string.replace(req.path, "/api/", "")
      process.send(calls, #(method, token))
      let body = case method {
        "auth.test" ->
          "{\"ok\":true,\"url\":\"https://a.slack.com/\",\"team\":\"Team A\",\"user\":\"crushling\",\"team_id\":\"TA\",\"user_id\":\"UBOTA\"}"
        _ -> "{\"ok\":true,\"channel\":\"C1\",\"ts\":\"99.0\"}"
      }
      response.new(200)
      |> response.set_header("content-type", "application/json")
      |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(port)
    |> mist.start
  #("http://127.0.0.1:" <> int.to_string(port) <> "/api", started.pid)
}

/// Stop a server the test started, so the suite doesn't run out of file
/// descriptors.
fn stop(pid: process.Pid) -> Nil {
  process.unlink(pid)
  process.kill(pid)
}

fn open_store(dir: String) -> store.Store {
  let assert Ok(key) =
    store.parse_key("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")
  let _ = dir
  let assert Ok(s) = store.start(":memory:", key)
  s
}

/// A launcher that never starts anything, and says which keys it was asked
/// for.
fn failing(launches: Subject(String)) -> launcher.Launcher {
  launcher.Launcher(
    launch: fn(key) {
      process.send(launches, key)
      Error("no agents in this test")
    },
    stop: fn(_) { Ok(Nil) },
    exists: fn(_) { False },
    rekey: fn(_, _) { Ok(Nil) },
    run_in_sandbox: None,
  )
}

fn shared(
  s: store.Store,
  dir: String,
  launches: Subject(String),
  api: String,
  env_team: option.Option(instance.EnvTeam),
) -> instance.Shared {
  instance.Shared(
    launcher: failing(launches),
    store: s,
    root: dir,
    mode: client.Sysadmin,
    idle_ms: 60_000,
    flush_ms: 50,
    env_team:,
    tailnet: None,
    client: fn(token) {
      let assert Ok(client) =
        slackline.new(token) |> slackline.with_base_url(api)
      client
    },
    github: None,
    default_model: "prism",
  )
}

fn team(id: String, token: String) -> store.Team {
  store.Team(
    id:,
    bot_token: token,
    bot_user: "UBOT" <> id,
    enterprise_id: None,
    installed_by: "U1",
    installed_at: 1,
    active: True,
  )
}

fn mention_frame(team: String, envelope: String) -> String {
  "{\"envelope_id\":\""
  <> envelope
  <> "\",\"type\":\"events_api\",\"accepts_response_payload\":false,\"retry_attempt\":0,\"retry_reason\":\"\",\"payload\":{\"token\":\"t\",\"team_id\":\""
  <> team
  <> "\",\"api_app_id\":\"A1\",\"type\":\"event_callback\",\"event_id\":\"Ev"
  <> envelope
  <> "\",\"event_time\":1,\"event\":{\"type\":\"app_mention\",\"user\":\"U1\",\"text\":\"<@UBOT"
  <> team
  <> "> hi\",\"ts\":\"10.1\",\"channel\":\"C1\",\"event_ts\":\"10.1\"}}}"
}

fn deliver(router: app.App, frame: String) -> Nil {
  let assert app.Send(after:, ..) = app.handle_socket(router, frame)
  after()
}

fn drain(calls: Subject(a), acc: List(a), wait: Int) -> List(a) {
  case process.receive(calls, wait) {
    Ok(call) -> drain(calls, [call, ..acc], wait)
    Error(Nil) -> list.reverse(acc)
  }
}

pub fn events_reach_only_their_own_workspace_test() {
  let dir = tmp()
  let s = open_store(dir)
  let calls = process.new_subject()
  let #(api, server) = fake_slack(calls)
  let launches = process.new_subject()
  let assert Ok(Nil) = store.put_team(s, team("TA", "xoxb-a"))
  let assert Ok(Nil) = store.put_team(s, team("TB", "xoxb-b"))
  // Each workspace allows its own people.
  let assert Ok(Nil) = store.set_setting(s, "TA", store.allowed_users, "U1")
  let assert Ok(Nil) = store.set_setting(s, "TB", store.allowed_users, "U1")
  let assert Ok(teams) = instance.start(shared(s, dir, launches, api, None))
  let assert Ok([]) = instance.start_stored(teams, s)
  let assert 2 = list.length(instance.all(teams))
  let router = socket.router(app.unverified(), instance.finder(teams))

  deliver(router, mention_frame("TA", "e1"))
  let assert Ok("TA-C1-10.1") = process.receive(launches, 2000)
  let assert Error(Nil) = process.receive(launches, 200)
  // The failed launch is reported in the thread, with A's token only.
  let sent = drain(calls, [], 300)
  let assert True = sent != []
  let assert True = list.all(sent, fn(call) { call.1 == "xoxb-a" })

  deliver(router, mention_frame("TB", "e2"))
  let assert Ok("TB-C1-10.1") = process.receive(launches, 2000)
  let sent = drain(calls, [], 300)
  let assert True = sent != []
  let assert True = list.all(sent, fn(call) { call.1 == "xoxb-b" })

  // A workspace the bridge doesn't serve: dropped.
  deliver(router, mention_frame("TZ", "e3"))
  let assert Error(Nil) = process.receive(launches, 300)
  let assert [] = drain(calls, [], 100)
  stop(server)
}

pub fn settings_come_from_the_store_or_the_environment_test() {
  let dir = tmp()
  let s = open_store(dir)
  let assert Ok(Nil) = store.put_team(s, team("TA", "xoxb-a"))
  let assert Ok(Nil) = store.put_team(s, team("TB", "xoxb-b"))
  let env =
    instance.EnvTeam(
      id: "TA",
      allowed: people.only(["U1", "U2"]),
      admins: set.from_list(["U1"]),
    )
  let shared = shared(s, dir, process.new_subject(), "http://x/api", Some(env))
  // The environment's workspace falls back to the environment.
  let assert Ok(#(allowed, admins)) = instance.people(shared, "TA")
  let assert 2 = set.size(allowed.ids)
  let assert True = set.contains(admins, "U1")
  // Another workspace gets nobody until its settings say.
  let assert Ok(#(allowed, _)) = instance.people(shared, "TB")
  let assert True = people.is_empty(allowed)
  let assert Ok(Nil) = store.set_setting(s, "TB", store.allowed_users, "U7, U8")
  let assert Ok(#(allowed, _)) = instance.people(shared, "TB")
  let assert True = allowed == people.only(["U7", "U8"])
  // Settings win over the environment.
  let assert Ok(Nil) = store.set_setting(s, "TA", store.allowed_users, "U9")
  let assert Ok(#(allowed, _)) = instance.people(shared, "TA")
  let assert True = allowed == people.only(["U9"])
}

pub fn self_host_seeds_its_workspace_test() {
  let dir = tmp()
  let s = open_store(dir)
  let calls = process.new_subject()
  let #(api, server) = fake_slack(calls)
  let assert Ok(client) =
    slackline.new("xoxb-env") |> slackline.with_base_url(api)
  let assert Ok(#(seeded, me)) = instance.seed(s, client, "xoxb-env")
  let assert "TA" = seeded.id
  let assert "UBOTA" = seeded.bot_user
  let assert "Team A" = me.team
  let assert Ok(#("auth.test", "xoxb-env")) = process.receive(calls, 1000)
  // It is in the store, token and all, and starts like any other.
  let assert Ok(Some(stored)) = store.team(s, "TA")
  let assert "xoxb-env" = stored.bot_token
  let launches = process.new_subject()
  let env =
    instance.EnvTeam(id: "TA", allowed: people.only(["U1"]), admins: set.new())
  let assert Ok(teams) =
    instance.start(shared(s, dir, launches, api, Some(env)))
  let assert Ok(started) = instance.start_team(teams, seeded)
  let assert "TA" = started.team
  // Starting the stored teams doesn't start it twice.
  let assert Ok([]) = instance.start_stored(teams, s)
  let assert [_] = instance.all(teams)
  // Seeding again keeps when it was installed.
  let assert Ok(#(again, _)) = instance.seed(s, client, "xoxb-env")
  let assert True = again.installed_at == seeded.installed_at
  stop(server)
}

pub fn tools_reach_the_thread_s_own_workspace_test() {
  let dir = tmp()
  let s = open_store(dir)
  let assert Ok(Nil) = store.put_team(s, team("TA", "xoxb-a"))
  let assert Ok(Nil) = store.put_team(s, team("TB", "xoxb-b"))
  let assert Ok(teams) =
    instance.start(shared(s, dir, process.new_subject(), "http://x/api", None))
  let assert Ok([]) = instance.start_stored(teams, s)
  let context = instance.tools_context(teams, s)
  let assert Ok(slack_tools.Workspace(bot_user: "UBOTTA", ..)) =
    context.workspace("TA-C1-1.0")
  let assert Ok(slack_tools.Workspace(bot_user: "UBOTTB", ..)) =
    context.workspace("TB-C1-1.0")
  let assert Error(_) = context.workspace("TZ-C1-1.0")
  // No agent is up, so there is no thread to use.
  let assert None = context.lookup("TA-C1-1.0")
  let assert None = context.lookup("TZ-C1-1.0")
}

/// One workspace's registry crashing leaves the others alone, and comes
/// back.
pub fn a_crashed_registry_is_restarted_alone_test() {
  let dir = tmp()
  let s = open_store(dir)
  let assert Ok(Nil) = store.put_team(s, team("TA", "xoxb-a"))
  let assert Ok(Nil) = store.put_team(s, team("TB", "xoxb-b"))
  let assert Ok(teams) =
    instance.start(shared(s, dir, process.new_subject(), "http://x/api", None))
  let assert Ok([]) = instance.start_stored(teams, s)
  let assert Some(a) = instance.find(teams, "TA")
  let assert Some(b) = instance.find(teams, "TB")
  let assert Ok(a_pid) = process.subject_owner(a.registry)
  let assert Ok(b_pid) = process.subject_owner(b.registry)
  process.send_abnormal_exit(a_pid, "boom")
  process.sleep(100)
  let assert False = process.is_alive(a_pid)
  let assert True = process.is_alive(b_pid)
  // The teams actor is fine, and starts A again.
  let assert Some(_) = instance.find(teams, "TB")
  process.sleep(1200)
  let assert Some(again) = instance.find(teams, "TA")
  let assert Ok(again_pid) = process.subject_owner(again.registry)
  let assert True = again_pid != a_pid
  let assert True = process.is_alive(again_pid)
  // Shutdown stops them for good.
  let assert registry.Clean = instance.shutdown(teams, 100)
  process.sleep(1200)
  let assert [] = instance.all(teams)
}
