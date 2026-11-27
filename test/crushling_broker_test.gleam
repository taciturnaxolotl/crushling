//// The credential broker: whose token a request uses, one refresh per
//// person however many ask at once, a refresh GitHub refuses ending the
//// connection, and waiting for a connection by subscription.

import crushling/github
import crushling/github/broker.{Anonymous, AsPerson, Connect, OpenPr, Push, Read}
import crushling/github/connect
import crushling/github/repo
import crushling/slack/workspace
import crushling/store
import crushling/store/github as accounts
import crushling/store/schema
import crushling/store/teams
import crushling/sys
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import slackline

const test_key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="

fn fresh_store() -> store.Store {
  let assert Ok(key) = store.parse_key(test_key)
  let assert Ok(s) = schema.open(":memory:", key)
  // GitHub connections belong to workspaces the store has.
  list.each(["T1", "T2"], fn(id) {
    let assert Ok(Nil) =
      teams.put_team(
        s,
        teams.Team(id, "xoxb-" <> id, "UBOT", None, "", 0, True),
      )
  })
  s
}

/// A GitHub that answers each path with `answer`, slowly, telling `seen`.
fn fake(
  seen: Subject(String),
  answer: fn(String) -> #(Int, String),
) -> github.Config {
  github.Config(client_id: "Iv1.test", client_secret: None, send: fn(req) {
    let req: Request(String) = req
    process.send(seen, req.path)
    process.sleep(100)
    let #(status, body) = answer(req.path)
    Ok(response.new(status) |> response.set_body(body))
  })
}

fn start(s: store.Store, config: github.Config) -> broker.Broker {
  let assert Ok(client) =
    slackline.new("xoxb-test") |> slackline.with_base_url("http://127.0.0.1:1")
  let assert Ok(c) =
    connect.start(connect.Setup(
      workspace: workspace.new(
        team: "T1",
        bot_user: "UBOT",
        client:,
        token: "xoxb-test",
      ),
      store: s,
      github: Some(config),
    ))
  let assert Ok(b) =
    broker.start(broker.Setup(
      store: s,
      team: "T1",
      github: Some(broker.GitHub(config, None)),
      connect: c,
      requester: fn(_) { Ok("U1") },
      ask: fn(_, _, _) { Nil },
      install_poll_ms: 20,
    ))
  b
}

fn connect_as(s: store.Store, user: String, tokens: github.Tokens) -> Nil {
  let assert Ok(Nil) =
    accounts.put(s, accounts.Account("T1", user, "octo", tokens, 100))
  Nil
}

fn hyper() -> repo.Repo {
  let assert Ok(found) = repo.parse_path("octo", "hyper")
  found
}

fn drain(seen: Subject(String), found: List(String)) -> List(String) {
  case process.receive(seen, 300) {
    Ok(path) -> drain(seen, [path, ..found])
    Error(Nil) -> list.reverse(found)
  }
}

pub fn fresh_tokens_are_used_as_they_are_test() {
  let s = fresh_store()
  let seen = process.new_subject()
  let b = start(s, fake(seen, fn(_) { #(500, "") }))
  connect_as(s, "U1", github.Tokens("ghu_a", 0, "ghr_r", 0))
  let assert Ok(AsPerson("octo", "ghu_a")) =
    broker.credential(b, "k", "U1", Some(hyper()), Push)
  // Nobody connected: reads go anonymous without the app's key, and
  // pushes and pull requests need a connection.
  let assert Ok(Anonymous) =
    broker.credential(b, "k", "U2", Some(hyper()), Read)
  let assert Error(Connect(Some(_))) =
    broker.credential(b, "k", "U2", Some(hyper()), Push)
  let assert Error(Connect(None)) = broker.credential(b, "k", "", None, OpenPr)
  let assert [] = drain(seen, [])
  store.close(s)
}

pub fn a_refresh_happens_once_for_everyone_waiting_test() {
  let s = fresh_store()
  let seen = process.new_subject()
  let b =
    start(
      s,
      fake(seen, fn(_) {
        #(
          200,
          "{\"access_token\":\"ghu_new\",\"expires_in\":28800,\"refresh_token\":\"ghr_new\",\"refresh_token_expires_in\":15897600}",
        )
      }),
    )
  let now = sys.now()
  connect_as(s, "U1", github.Tokens("ghu_old", now + 10, "ghr_r", now + 9999))
  let answers = process.new_subject()
  list.each([1, 2, 3, 4, 5], fn(_) {
    process.spawn(fn() {
      process.send(
        answers,
        broker.credential(b, "k", "U1", Some(hyper()), Read),
      )
    })
  })
  list.each([1, 2, 3, 4, 5], fn(_) {
    let assert Ok(Ok(AsPerson("octo", "ghu_new"))) =
      process.receive(answers, 5000)
  })
  let assert ["/login/oauth/access_token"] = drain(seen, [])
  let assert Ok(Some(account)) = accounts.get(s, "T1", "U1")
  let assert "ghr_new" = account.tokens.refresh
  store.close(s)
}

pub fn a_refused_refresh_ends_the_connection_test() {
  let s = fresh_store()
  let seen = process.new_subject()
  let b =
    start(s, fake(seen, fn(_) { #(200, "{\"error\":\"bad_refresh_token\"}") }))
  let now = sys.now()
  connect_as(s, "U1", github.Tokens("ghu_old", now + 10, "ghr_r", now + 9999))
  let assert Ok(Anonymous) =
    broker.credential(b, "k", "U1", Some(hyper()), Read)
  let assert Ok(None) = accounts.get(s, "T1", "U1")
  // A refresh token past its time isn't even tried.
  connect_as(s, "U2", github.Tokens("ghu_old", now - 10, "ghr_r", now - 5))
  let _ = drain(seen, [])
  let assert Error(Connect(_)) =
    broker.credential(b, "k", "U2", Some(hyper()), Push)
  let assert [] = drain(seen, [])
  let assert Ok(None) = accounts.get(s, "T1", "U2")
  store.close(s)
}

/// A refresh that lands after the person reconnected doesn't overwrite the
/// new connection.
pub fn a_late_refresh_keeps_a_newer_connection_test() {
  let s = fresh_store()
  let now = sys.now()
  connect_as(s, "U1", github.Tokens("ghu_old", now + 10, "ghr_r", now + 9999))
  let assert Ok(Nil) =
    accounts.put(
      s,
      accounts.Account(
        "T1",
        "U1",
        "octo",
        github.Tokens("ghu_b", 0, "", 0),
        200,
      ),
    )
  let assert Ok(False) =
    accounts.replace_tokens(
      s,
      "T1",
      "U1",
      100,
      github.Tokens("ghu_x", 0, "", 0),
    )
  let assert Ok(Nil) = accounts.delete_connection(s, "T1", "U1", 100)
  let assert Ok(Some(accounts.Account(
    tokens: github.Tokens(access: "ghu_b", ..),
    ..,
  ))) = accounts.get(s, "T1", "U1")
  store.close(s)
}

const code_body =
  "{\"device_code\":\"dc\",\"user_code\":\"ABCD-1234\",\"verification_uri\":\"https://github.com/login/device\",\"expires_in\":900,\"interval\":0}"

const granted_body =
  "{\"access_token\":\"ghu_a\",\"expires_in\":28800,\"refresh_token\":\"ghr_r\",\"refresh_token_expires_in\":15897600}"

/// Someone waiting for a connection is told when it's made, not left to
/// look.
pub fn waiting_for_a_connection_is_told_test() {
  let s = fresh_store()
  let seen = process.new_subject()
  let config =
    fake(seen, fn(path) {
      case path {
        "/login/device/code" -> #(200, code_body)
        "/login/oauth/access_token" -> #(200, granted_body)
        _ -> #(200, "{\"login\":\"octo\"}")
      }
    })
  let assert Ok(client) =
    slackline.new("xoxb-test") |> slackline.with_base_url("http://127.0.0.1:1")
  let assert Ok(c) =
    connect.start(connect.Setup(
      workspace: workspace.new(
        team: "T1",
        bot_user: "UBOT",
        client:,
        token: "xoxb-test",
      ),
      store: s,
      github: Some(config),
    ))
  let assert Ok(b) =
    broker.start(broker.Setup(
      store: s,
      team: "T1",
      github: Some(broker.GitHub(config, None)),
      connect: c,
      requester: fn(_) { Ok("U1") },
      ask: fn(_, _, _) { Nil },
      install_poll_ms: 20,
    ))
  // Not connected, nobody connects: no.
  let assert False = broker.await(b, "U1", Connect(None), 100)
  let done = process.new_subject()
  process.spawn(fn() {
    process.send(done, broker.await(b, "U1", Connect(None), 10_000))
  })
  process.sleep(50)
  process.send(c, connect.Connect("U1", None))
  let assert Ok(True) = process.receive(done, 8000)
  // Already connected: at once.
  let assert True = broker.await(b, "U1", Connect(None), 1000)
  let assert Ok(access) = broker.thread(b, "k")
  let assert Ok(AsPerson("octo", "ghu_a")) = access.credential(None, Read)
  store.close(s)
}
