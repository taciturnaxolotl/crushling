//// GitHub connections and the App Home: the device flow against a fake
//// GitHub, tokens sealed in the store, spend kept by day, the Home view,
//// and the registry connecting and disconnecting someone against a fake
//// Slack.

import crushling/crush/client
import crushling/github
import crushling/home
import crushling/launcher
import crushling/people
import crushling/proxy/meter
import crushling/registry
import crushling/registry/incoming as msg
import crushling/slack
import crushling/store
import crushling/store/github as accounts
import crushling/store/usage
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/result
import gleam/string
import gleam/uri
import mist
import slackline
import slackline/block
import slackline/view
import sqlight

const test_key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="

fn fresh_store() -> store.Store {
  let assert Ok(key) = store.parse_key(test_key)
  let assert Ok(s) = store.start(":memory:", key)
  s
}

/// A GitHub that answers from `answers`, by path, each a list used in turn
/// (the last one repeats), and tells `seen` what was asked. The answers live
/// in a process of their own, as the bridge asks from processes it spawns.
fn fake(
  answers: List(#(String, List(#(Int, String)))),
  seen: Subject(Request(String)),
) -> github.Config {
  fake_with(answers, seen, None)
}

fn fake_with(
  answers: List(#(String, List(#(Int, String)))),
  seen: Subject(Request(String)),
  secret: option.Option(String),
) -> github.Config {
  let ready = process.new_subject()
  process.spawn(fn() {
    let asks = process.new_subject()
    process.send(ready, asks)
    serve(asks, answers)
  })
  let assert Ok(asks) = process.receive(ready, 1000)
  github.Config(client_id: "Iv1.test", client_secret: secret, send: fn(req) {
    process.send(seen, req)
    let answer = process.call(asks, 1000, fn(reply) { #(req.path, reply) })
    case answer {
      Ok(#(status, body)) -> Ok(response.new(status) |> response.set_body(body))
      Error(reason) -> Error(reason)
    }
  })
}

fn serve(
  asks: Subject(#(String, Subject(Result(#(Int, String), String)))),
  answers: List(#(String, List(#(Int, String)))),
) -> Nil {
  let #(path, reply) = process.receive_forever(asks)
  let #(answer, answers) = case list.key_find(answers, path) {
    Ok([one]) -> #(Ok(one), answers)
    Ok([one, ..rest]) -> #(Ok(one), list.key_set(answers, path, rest))
    _ -> #(Error("no answer for " <> path), answers)
  }
  process.send(reply, answer)
  serve(asks, answers)
}

const code_body =
  "{\"device_code\":\"dc\",\"user_code\":\"ABCD-1234\",\"verification_uri\":\"https://github.com/login/device\",\"expires_in\":900,\"interval\":0}"

const granted_body =
  "{\"access_token\":\"ghu_a\",\"expires_in\":28800,\"refresh_token\":\"ghr_r\",\"refresh_token_expires_in\":15897600,\"token_type\":\"bearer\",\"scope\":\"\"}"

const pending_body = "{\"error\":\"authorization_pending\"}"

// The device flow.

pub fn device_flow_test() {
  let seen = process.new_subject()
  let config =
    fake(
      [
        #("/login/device/code", [#(200, code_body)]),
        #("/login/oauth/access_token", [
          #(200, pending_body),
          #(200, "{\"error\":\"slow_down\",\"interval\":10}"),
          #(200, "{\"error\":\"slow_down\"}"),
          #(200, granted_body),
        ]),
      ],
      seen,
    )
  let assert Ok(code) = github.device_code(config)
  let assert github.DeviceCode(user_code: "ABCD-1234", interval: 0, ..) = code
  let assert Ok(asked) = process.receive(seen, 100)
  // Form-encoded, asking for JSON back, with the client id and no secret.
  let assert True = string.contains(asked.body, "client_id=Iv1.test")
  let assert Ok("application/json") = request.get_header(asked, "accept")
  let assert github.Pending = github.poll(config, code, 1000)
  let assert github.SlowDown(Some(10)) = github.poll(config, code, 1000)
  let assert github.SlowDown(None) = github.poll(config, code, 1000)
  let assert github.Granted(tokens) = github.poll(config, code, 1000)
  let assert github.Tokens(
    access: "ghu_a",
    expires_at: 29_800,
    refresh: "ghr_r",
    refresh_expires_at: 15_898_600,
  ) = tokens
  let _ = process.receive(seen, 100)
  let _ = process.receive(seen, 100)
  let _ = process.receive(seen, 100)
  let assert Ok(polled) = process.receive(seen, 100)
  let assert True =
    string.contains(
      polled.body,
      "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code",
    )
}

pub fn device_flow_failures_test() {
  let code = github.DeviceCode("dc", "ABCD-1234", "https://x", 900, 0)
  let poll = fn(body) {
    let config =
      fake(
        [#("/login/oauth/access_token", [#(200, body)])],
        process.new_subject(),
      )
    github.poll(config, code, 0)
  }
  let assert github.Failed("it was cancelled on GitHub") =
    poll("{\"error\":\"access_denied\"}")
  let assert github.Failed("the code expired") =
    poll("{\"error\":\"expired_token\"}")
  let assert github.Failed("the GitHub App doesn't have device flow turned on") =
    poll("{\"error\":\"device_flow_disabled\"}")
  // An answer that isn't JSON is refused without being repeated.
  let assert github.Failed(reason) = poll("ghu_secret garbage")
  let assert False = string.contains(reason, "ghu_secret")
}

/// An interval of zero or less from GitHub is held to a second: neither a
/// tight loop nor a crash in `timer:sleep`.
pub fn wait_holds_the_interval_test() {
  list.each([0, -5], fn(interval) {
    let seen = process.new_subject()
    let config =
      fake(
        [
          #("/login/oauth/access_token", [
            #(200, pending_body),
            #(200, granted_body),
          ]),
        ],
        seen,
      )
    let code = github.DeviceCode("dc", "ABCD-1234", "https://x", 900, interval)
    let started = now_ms()
    let assert Ok(github.Tokens(access: "ghu_a", ..)) =
      github.wait(config, code, 1_000_000, fn() { 0 })
    // Two polls, a second apart at least.
    let assert True = now_ms() - started >= 1900
    let assert Ok(_) = process.receive(seen, 0)
    let assert Ok(_) = process.receive(seen, 0)
    let assert Error(Nil) = process.receive(seen, 0)
  })
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic(unit: Atom) -> Int

type Atom

@external(erlang, "erlang", "binary_to_atom")
fn atom(name: String) -> Atom

fn now_ms() -> Int {
  monotonic(atom("millisecond"))
}

pub fn refresh_and_login_test() {
  let seen = process.new_subject()
  let config =
    fake(
      [
        #("/login/oauth/access_token", [#(200, granted_body)]),
        #("/user", [#(200, "{\"login\":\"octo\",\"id\":1}")]),
      ],
      seen,
    )
  let old = github.Tokens("ghu_old", 100, "ghr_old", 999)
  let assert True = github.stale(old, 0)
  let assert False = github.stale(github.Tokens("a", 0, "", 0), 99_999)
  let assert Ok(github.Tokens(access: "ghu_a", ..)) =
    github.refresh(config, old, 0)
  let assert Ok(asked) = process.receive(seen, 100)
  let assert True = string.contains(asked.body, "refresh_token=ghr_old")
  let assert Ok("octo") = github.login(config, old)
  let assert Ok(asked) = process.receive(seen, 100)
  let assert Ok("Bearer ghu_old") = request.get_header(asked, "authorization")
}

pub fn revoke_test() {
  let tokens = github.Tokens("ghu_old", 0, "ghr_old", 0)
  // Without the app's secret, nothing is revoked on GitHub.
  let seen = process.new_subject()
  let assert Ok(False) = github.revoke(fake([], seen), tokens)
  let assert Error(Nil) = process.receive(seen, 50)
  // With it, the grant is deleted, the app authenticating with Basic.
  let seen = process.new_subject()
  let config =
    fake_with(
      [#("/applications/Iv1.test/grant", [#(204, "")])],
      seen,
      Some("s3cret"),
    )
  let assert Ok(True) = github.revoke(config, tokens)
  let assert Ok(asked) = process.receive(seen, 100)
  let assert http.Delete = asked.method
  let assert "api.github.com" = asked.host
  let basic = bit_array.base64_encode(<<"Iv1.test:s3cret":utf8>>, True)
  let assert Ok(header) = request.get_header(asked, "authorization")
  let assert True = header == "Basic " <> basic
  let assert True = asked.body == "{\"access_token\":\"ghu_old\"}"
  // A refusal is an error, without GitHub's body.
  let config =
    fake_with(
      [#("/applications/Iv1.test/grant", [#(422, "ghu_old")])],
      process.new_subject(),
      Some("s3cret"),
    )
  let assert Error(reason) = github.revoke(config, tokens)
  let assert False = string.contains(reason, "ghu_old")
}

// The store.

pub fn accounts_are_sealed_and_bound_test() {
  let s = fresh_store()
  let tokens = github.Tokens("ghu_a", 10, "ghr_r", 20)
  let assert Ok(Nil) =
    accounts.put(s, accounts.Account("T1", "U1", "octo", tokens, 5))
  let assert Ok(Some(accounts.Account(login: "octo", tokens: got, ..))) =
    accounts.get(s, "T1", "U1")
  let assert True = got == tokens
  let assert Ok(None) = accounts.get(s, "T1", "U2")
  let assert Ok(None) = accounts.get(s, "T2", "U1")
  // A row copied to someone else, in this workspace or another, won't open.
  copy_row(s, "T1", "U2")
  copy_row(s, "T2", "U1")
  let assert Error(_) = accounts.get(s, "T1", "U2")
  let assert Error(_) = accounts.get(s, "T2", "U1")
  let assert Ok(Nil) = accounts.delete(s, "T1", "U1")
  let assert Ok(None) = accounts.get(s, "T1", "U1")
  store.close(s)
}

/// Copy (T1, U1)'s sealed tokens to (team, user), as someone with the
/// database but not the key could.
fn copy_row(s: store.Store, team: String, user: String) -> Nil {
  let assert Ok(Nil) = {
    use connection, _ <- store.run(s)
    store.exec(
      connection,
      "INSERT INTO github_accounts
         (team_id, user_id, login, tokens_enc, connected_at)
       SELECT ?, ?, login, tokens_enc, connected_at FROM github_accounts
       WHERE team_id = 'T1' AND user_id = 'U1'",
      [sqlight.text(team), sqlight.text(user)],
    )
  }
  Nil
}

pub fn spend_adds_up_by_day_test() {
  let s = fresh_store()
  let one = meter.Usage(10, 5, 0.25, 1)
  let assert Ok(Nil) =
    usage.record(s, [#("T1-C1-1.0", one), #("T1-C2-2.0", one)])
  let assert Ok(Nil) =
    usage.record(s, [#("T1-C1-1.0", one), #("T2-C1-1.0", one)])
  let assert Ok(meter.Usage(20, 10, 0.5, 2)) =
    usage.thread_total(s, "T1-C1-1.0", usage.Ever)
  let assert Ok(meter.Usage(30, 15, 0.75, 3)) =
    usage.team_total(s, "T1", usage.Today)
  let assert Ok(meter.Usage(requests: 3, ..)) =
    usage.team_total(s, "T1", usage.Month)
  let assert Ok(meter.Usage(0, 0, 0.0, 0)) =
    usage.team_total(s, "T9", usage.Ever)
  let assert Ok(meter.Usage(requests: 3, ..)) =
    usage.threads_total(s, ["T1-C1-1.0", "T2-C1-1.0"], usage.Ever)
  // A key from before keys carried a workspace counts under none.
  let assert Ok(Nil) = usage.record(s, [#("C1-1.0", one)])
  let assert Ok(meter.Usage(requests: 1, ..)) =
    usage.team_total(s, "", usage.Ever)
  let assert Ok(meter.Usage(requests: 0, ..)) =
    usage.team_total(s, "C1", usage.Ever)
  store.close(s)
}

/// The meter hands over what it counted since the last drain, once, so the
/// store adds each response exactly once while caps keep counting.
pub fn the_meter_drains_once_test() {
  let s = fresh_store()
  let assert Ok(m) =
    meter.start(meter.Limits(meter.unlimited, meter.unlimited, 4, 4))
  let one = meter.Usage(10, 5, 0.25, 1)
  meter.record(m, "T1-C1-1.0", one)
  meter.record(m, "T1-C1-1.0", one)
  meter.record(m, "T1-C2-2.0", one)
  let drained = meter.drain(m)
  let assert [#("T1-C1-1.0", meter.Usage(requests: 2, ..)), _] =
    list.sort(drained, fn(a, b) { string.compare(a.0, b.0) })
  let assert [] = meter.drain(m)
  let assert Ok(Nil) = usage.record(s, drained)
  meter.record(m, "T1-C1-1.0", one)
  let assert Ok(Nil) = usage.record(s, meter.drain(m))
  let assert Ok(meter.Usage(requests: 3, ..)) =
    usage.thread_total(s, "T1-C1-1.0", usage.Ever)
  // The meter's own totals are untouched by draining.
  let assert meter.Usage(requests: 3, ..) = meter.totals(m, "T1-C1-1.0")
  store.close(s)
}

// The Home.

fn texts(v: view.View) -> String {
  string.inspect(v.blocks)
}

fn base(github: home.GitHub) -> home.Home {
  home.Home(
    github:,
    threads: [],
    thread_count: 0,
    today: meter.Usage(0, 0, 1.5, 3),
    month: meter.Usage(0, 0, 12.0, 40),
    default_model: "prism",
  )
}

fn buttons(v: view.View) -> List(String) {
  list.filter_map(v.blocks, fn(b) {
    case b {
      block.Section(block.SectionBlock(
        accessory: Some(block.Button(button)),
        ..,
      )) -> option.to_result(button.action_id, Nil)
      _ -> Error(Nil)
    }
  })
}

pub fn home_view_test() {
  let v = home.view(base(home.NotConnected(None)))
  let assert [action] = buttons(v)
  let assert True = action == home.connect_action
  let assert True = string.contains(texts(v), "$1.50")
  let assert True = string.contains(texts(v), "$12.00")
  let assert True = string.contains(texts(v), "None of your threads")
  let v = home.view(base(home.NotConnected(Some("Couldn't connect: nope."))))
  let assert True = string.contains(texts(v), "Couldn't connect: nope.")
  let v = home.view(base(home.Connected("octo", None)))
  let assert [action] = buttons(v)
  let assert True = action == home.disconnect_action
  let assert True = string.contains(texts(v), "@octo")
  let v =
    home.view(
      base(home.Connecting("ABCD-1234", "https://github.com/login/device", 15)),
    )
  let assert [] = buttons(v)
  let assert True = string.contains(texts(v), "ABCD-1234")
  let assert True = string.contains(texts(v), "15 more minutes")
  let assert [] = buttons(home.view(base(home.Asking)))
  let assert [] = buttons(home.view(base(home.Unavailable)))
  // Someone who may not use crushling sees only that.
  let v = home.view(home.NotAllowed)
  let assert [] = buttons(v)
  let assert True = string.contains(texts(v), "can't use crushling")
  let assert False = string.contains(texts(v), "$")
  // Their threads are listed, linked when Slack gave a link.
  let v =
    home.view(
      home.Home(
        github: home.Unavailable,
        today: meter.zero,
        month: meter.zero,
        default_model: "prism",
        threads: [
          home.Thread(
            "C1",
            Some("https://x.slack.com/p1"),
            "kimi-k3",
            meter.Usage(0, 0, 0.42, 1),
          ),
          home.Thread("C2", None, "prism", meter.zero),
        ],
        thread_count: 25,
      ),
    )
  let assert True = string.contains(texts(v), "<https://x.slack.com/p1|a thread>")
  let assert True = string.contains(texts(v), "kimi-k3 · $0.42")
  let assert True = string.contains(texts(v), "a thread in <#C2>")
  let assert True = string.contains(texts(v), "and 23 more")
  // It encodes for views.publish.
  let encoded = json.to_string(view.view_to_json(v))
  let assert True = string.contains(encoded, "\"type\":\"home\"")
}

pub fn github_command_test() {
  let assert slack.GitHubCommand(True) = slack.command("!github")
  let assert slack.GitHubCommand(True) = slack.command("!GitHub connect")
  let assert slack.GitHubCommand(False) = slack.command("!github disconnect")
  let assert True = string.contains(slack.help, "`!github`")
}

// The registry, against a fake Slack.

/// A Slack Web API that says which method was called, with what body, and
/// answers users.info for UMEMBER (a member) and UGUEST (a guest).
fn fake_slack(calls: Subject(#(String, String))) -> #(String, process.Pid) {
  let port = process.new_subject()
  let assert Ok(started) =
    mist.new(fn(req: request.Request(mist.Connection)) {
      let body = case mist.read_body(req, 1_000_000) {
        Ok(req) -> bit_array.to_string(req.body) |> option.from_result
        Error(_) -> None
      }
      let params =
        { option.unwrap(req.query, "") <> "&" <> option.unwrap(body, "") }
        |> string.replace("+", " ")
      let params = uri.percent_decode(params) |> result.unwrap(params)
      let method = string.replace(req.path, "/api/", "")
      process.send(calls, #(method, params))
      let answer = case method {
        "users.info" ->
          case string.contains(params, "UMEMBER") {
            True ->
              "{\"ok\":true,\"user\":{\"id\":\"UMEMBER\",\"name\":\"x\",\"team_id\":\"T1\"}}"
            False ->
              "{\"ok\":true,\"user\":{\"id\":\"UGUEST\",\"name\":\"x\",\"team_id\":\"T1\",\"is_restricted\":true}}"
          }
        "chat.getPermalink" ->
          "{\"ok\":true,\"channel\":\"C1\",\"permalink\":\"https://x.slack.com/p1\"}"
        "views.publish" -> "{\"ok\":true,\"view\":{\"id\":\"V1\",\"type\":\"home\",\"blocks\":[]}}"
        _ -> "{\"ok\":true,\"channel\":\"C1\",\"ts\":\"99.0\"}"
      }
      response.new(200)
      |> response.set_header("content-type", "application/json")
      |> response.set_body(mist.Bytes(bytes_tree.from_string(answer)))
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(p, _, _) { process.send(port, p) })
    |> mist.start
  let assert Ok(port) = process.receive(port, 5000)
  #("http://127.0.0.1:" <> int.to_string(port) <> "/api", started.pid)
}

fn stop(pid: process.Pid) -> Nil {
  process.unlink(pid)
  process.kill(pid)
}

/// The next call to `method` within `ms`, skipping others.
fn next_call(
  calls: Subject(#(String, String)),
  method: String,
  ms: Int,
) -> Result(String, Nil) {
  case process.receive(calls, ms) {
    Ok(#(m, body)) if m == method -> Ok(body)
    Ok(_) -> next_call(calls, method, ms)
    Error(Nil) -> Error(Nil)
  }
}

/// The next Home published within `ms` whose JSON contains `text`.
fn home_with(
  calls: Subject(#(String, String)),
  text: String,
  ms: Int,
) -> Result(String, Nil) {
  case next_call(calls, "views.publish", ms) {
    Ok(body) ->
      case string.contains(body, text) {
        True -> Ok(body)
        False -> home_with(calls, text, ms)
      }
    Error(Nil) -> Error(Nil)
  }
}

/// Whether GitHub was asked for `path` within `ms`.
fn asked_github(seen: Subject(Request(String)), path: String, ms: Int) -> Bool {
  case process.receive(seen, ms) {
    Ok(req) if req.path == path -> True
    Ok(_) -> asked_github(seen, path, ms)
    Error(Nil) -> False
  }
}

pub fn connecting_from_a_thread_saves_the_account_test() {
  let s = fresh_store()
  let calls = process.new_subject()
  let #(api, slack_pid) = fake_slack(calls)
  let config =
    fake(
      [
        #("/login/device/code", [#(200, code_body)]),
        #("/login/oauth/access_token", [#(200, pending_body), #(200, granted_body)]),
        #("/user", [#(200, "{\"login\":\"octo\"}")]),
      ],
      process.new_subject(),
    )
  let r = start_registry(s, api, people.only(["U1"]), Some(config))
  // A DM is heard without a mention.
  process.send(
    r,
    registry.Received(
      msg.Incoming("D1", "1.0", "1.0", "U1", "!github", True, []),
    ),
  )
  let assert Ok(accounts.Account(login: "octo", ..)) = eventually(s, "U1", 50)
  let assert Ok(_) = home_with(calls, "octo", 2000)
  // No agent was started for it.
  let assert Ok(Nil) = store.thread(s, registry.key("T1", "D1", "1.0")) |> none
  // Disconnecting forgets it, and says so on the Home.
  process.send(r, registry.GitHubDisconnect("U1"))
  let assert True = gone(s, "U1", 50)
  let assert Ok(_) = home_with(calls, "GitHub disconnected here", 2000)
  stop(slack_pid)
  store.close(s)
}

pub fn only_allowed_people_connect_test() {
  let s = fresh_store()
  let calls = process.new_subject()
  let #(api, slack_pid) = fake_slack(calls)
  let seen = process.new_subject()
  let config =
    fake(
      [
        #("/login/device/code", [#(200, code_body)]),
        #("/login/oauth/access_token", [#(200, pending_body)]),
      ],
      seen,
    )
  let r = start_registry(s, api, people.only(["U1"]), Some(config))
  // Someone not listed gets no code, and a Home that says why.
  process.send(r, registry.GitHubConnect("U2"))
  let assert Ok(_) = home_with(calls, "can't use crushling", 2000)
  let assert False = asked_github(seen, "/login/device/code", 300)
  // Someone listed does, in the same registry.
  process.send(r, registry.GitHubConnect("U1"))
  let assert True = asked_github(seen, "/login/device/code", 2000)
  let assert Ok(_) = home_with(calls, "ABCD-1234", 2000)
  process.send(r, registry.GitHubDisconnect("U1"))
  stop(slack_pid)
  store.close(s)
}

/// With everyone allowed, a Home press from someone not yet looked up waits
/// for users.info rather than being dropped.
pub fn everyone_may_connect_from_the_home_test() {
  let s = fresh_store()
  let calls = process.new_subject()
  let #(api, slack_pid) = fake_slack(calls)
  let seen = process.new_subject()
  let config =
    fake(
      [
        #("/login/device/code", [#(200, code_body)]),
        #("/login/oauth/access_token", [#(200, pending_body)]),
      ],
      seen,
    )
  let r = start_registry(s, api, people.parse("*"), Some(config))
  process.send(r, registry.GitHubConnect("UMEMBER"))
  let assert True = asked_github(seen, "/login/device/code", 2000)
  let assert Ok(_) = home_with(calls, "ABCD-1234", 2000)
  // A guest is looked up too, and turned away.
  process.send(r, registry.GitHubConnect("UGUEST"))
  let assert Ok(_) = home_with(calls, "can't use crushling", 2000)
  let assert False = asked_github(seen, "/login/device/code", 300)
  // Opening the Home mid-connect keeps the code on it.
  process.send(r, registry.HomeOpened("UMEMBER"))
  let assert Ok(_) = home_with(calls, "ABCD-1234", 2000)
  process.send(r, registry.GitHubDisconnect("UMEMBER"))
  stop(slack_pid)
  store.close(s)
}

/// Disconnecting while GitHub is still being polled stops the poller, and a
/// yes from GitHub afterwards can't bring the account back.
pub fn disconnecting_mid_connect_stops_it_test() {
  let s = fresh_store()
  let calls = process.new_subject()
  let #(api, slack_pid) = fake_slack(calls)
  let seen = process.new_subject()
  let config =
    fake(
      [
        #("/login/device/code", [#(200, code_body)]),
        // Pending once, then yes: only a poller still running would see it.
        #("/login/oauth/access_token", [#(200, pending_body), #(200, granted_body)]),
        #("/user", [#(200, "{\"login\":\"octo\"}")]),
      ],
      seen,
    )
  let r = start_registry(s, api, people.only(["U1"]), Some(config))
  process.send(r, registry.GitHubConnect("U1"))
  let assert True = asked_github(seen, "/login/device/code", 2000)
  let assert Ok(_) = home_with(calls, "ABCD-1234", 2000)
  process.send(r, registry.GitHubDisconnect("U1"))
  let assert Ok(_) = home_with(calls, "wasn't connected", 2000)
  // Polls come a second apart; none after the disconnect.
  let assert False = asked_github(seen, "/login/oauth/access_token", 2500)
  let assert Error(Nil) = eventually(s, "U1", 5)
  // Connecting again starts afresh.
  process.send(r, registry.GitHubConnect("U1"))
  let assert Ok(_) = home_with(calls, "ABCD-1234", 2000)
  process.send(r, registry.GitHubDisconnect("U1"))
  stop(slack_pid)
  store.close(s)
}

fn none(result: Result(option.Option(a), String)) -> Result(Nil, Nil) {
  case result {
    Ok(None) -> Ok(Nil)
    _ -> Error(Nil)
  }
}

/// The account once it's there, checking every 100ms up to `tries` times.
fn eventually(
  s: store.Store,
  user: String,
  tries: Int,
) -> Result(accounts.Account, Nil) {
  case accounts.get(s, "T1", user), tries {
    Ok(Some(account)), _ -> Ok(account)
    _, 0 -> Error(Nil)
    _, _ -> {
      process.sleep(100)
      eventually(s, user, tries - 1)
    }
  }
}

fn gone(s: store.Store, user: String, tries: Int) -> Bool {
  case accounts.get(s, "T1", user), tries {
    Ok(None), _ -> True
    _, 0 -> False
    _, _ -> {
      process.sleep(100)
      gone(s, user, tries - 1)
    }
  }
}

fn start_registry(
  s: store.Store,
  api: String,
  allowed: people.People,
  github: option.Option(github.Config),
) {
  let assert Ok(client) =
    slackline.new("xoxb-test") |> slackline.with_base_url(api)
  let assert Ok(r) =
    registry.start(registry.Config(
      launcher: launcher.Launcher(
        launch: fn(_) { Error("no agents in this test") },
        stop: fn(_) { Ok(Nil) },
        exists: fn(_) { False },
        rekey: fn(_, _) { Ok(Nil) },
        run_in_sandbox: None,
      ),
      client:,
      token: "xoxb-test",
      bot_user: "UBOT",
      team: "T1",
      allowed:,
      admins: set.new(),
      store: s,
      migrate_legacy: False,
      idle_ms: 60_000,
      flush_ms: 50,
      mode: client.Sysadmin,
      tailnet: None,
      stop_backoff_ms: registry.default_stop_backoff_ms,
      root: "/tmp/crushling-github-test",
      github:,
      default_model: "prism",
    ))
  r
}
