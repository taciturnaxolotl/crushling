//// Who may use crushling: listed ids, and `*` for every full member of the
//// workspace, checked with users.info against a fake Slack.

import crushling/crush/client
import crushling/instance
import crushling/launcher
import crushling/people
import crushling/registry
import crushling/registry/incoming as msg
import crushling/store
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import mist
import slackline

// PARSE -----------------------------------------------------------------------

pub fn parse_everyone_test() {
  let assert people.People(everyone: True, ids:) = people.parse("*")
  let assert True = set.is_empty(ids)
}

pub fn parse_everyone_and_ids_test() {
  let assert people.People(everyone: True, ids:) = people.parse(" *, U1 ,")
  let assert True = ids == set.from_list(["U1"])
}

pub fn parse_ids_test() {
  let assert people.People(everyone: False, ids:) = people.parse("U1, U2")
  let assert True = ids == set.from_list(["U1", "U2"])
}

pub fn parse_empty_test() {
  let assert True = people.is_empty(people.parse(""))
  let assert True = people.is_empty(people.parse(" , "))
  let assert False = people.is_empty(people.parse("*"))
}

// ALLOWS ----------------------------------------------------------------------

pub fn a_listed_id_needs_no_lookup_test() {
  let never = fn(_) { panic as "looked up a listed id" }
  let assert True = people.allows(people.parse("U1"), "U1", never)
  let assert True = people.allows(people.parse("*,U1"), "U1", never)
  let assert False = people.needs_lookup(people.parse("*,U1"), "U1")
  let assert False = people.needs_lookup(people.parse("U1"), "U2")
  let assert True = people.needs_lookup(people.parse("*,U1"), "U2")
}

pub fn ids_only_never_look_up_test() {
  let never = fn(_) { panic as "looked up without everyone" }
  let assert False = people.allows(people.parse("U1"), "U2", never)
}

pub fn everyone_asks_the_check_test() {
  let everyone = people.parse("*")
  let assert True = people.allows(everyone, "UMEMBER", fn(_) { True })
  let assert False = people.allows(everyone, "UGUEST", fn(_) { False })
}

// LOOKUP ----------------------------------------------------------------------

fn user_json(id: String, extra: String) -> String {
  "{\"ok\":true,\"user\":{\"id\":\""
  <> id
  <> "\",\"name\":\"x\",\"team_id\":\"T1\""
  <> extra
  <> "}}"
}

/// users.info's answer for each test user.
fn info(id: String) -> String {
  case id {
    "UMEMBER" | "UMEMBER2" -> user_json(id, "")
    "UGUEST" -> user_json(id, ",\"is_restricted\":true")
    "USINGLE" ->
      user_json(id, ",\"is_restricted\":true,\"is_ultra_restricted\":true")
    "UOTHER" -> string.replace(user_json(id, ""), "\"T1\"", "\"T2\"")
    "UBOTX" -> user_json(id, ",\"is_bot\":true")
    "UGONE" -> user_json(id, ",\"deleted\":true")
    _ -> "{\"ok\":false,\"error\":\"internal_error\"}"
  }
}

/// A Slack Web API that answers users.info from `info`, says which users it
/// was asked about, and answers anything else with ok.
fn fake_slack(asked: Subject(String)) -> #(String, process.Pid) {
  let port = process.new_subject()
  let assert Ok(started) =
    mist.new(fn(req: request.Request(mist.Connection)) {
      let body = case mist.read_body(req, 100_000) {
        Ok(req) -> bit_array.to_string(req.body) |> option.from_result
        Error(_) -> None
      }
      let params =
        option.unwrap(req.query, "") <> "&" <> option.unwrap(body, "")
      let answer = case string.replace(req.path, "/api/", "") {
        "users.info" -> {
          let user =
            string.split(params, "&")
            |> list.find_map(fn(pair) {
              case pair {
                "user=" <> user -> Ok(user)
                _ -> Error(Nil)
              }
            })
            |> option.from_result
            |> option.unwrap("")
          process.send(asked, user)
          info(user)
        }
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

fn slack_client(api: String) -> slackline.Client {
  let assert Ok(client) =
    slackline.new("xoxb-test") |> slackline.with_base_url(api)
  client
}

pub fn only_full_members_of_this_workspace_are_members_test() {
  let asked = process.new_subject()
  let #(api, pid) = fake_slack(asked)
  let client = slack_client(api)
  let assert Ok(True) = people.lookup(client, "T1", "UMEMBER")
  let assert Ok(False) = people.lookup(client, "T1", "UGUEST")
  let assert Ok(False) = people.lookup(client, "T1", "USINGLE")
  let assert Ok(False) = people.lookup(client, "T1", "UOTHER")
  let assert Ok(False) = people.lookup(client, "T1", "UBOTX")
  let assert Ok(False) = people.lookup(client, "T1", "UGONE")
  let assert Error(_) = people.lookup(client, "T1", "UFAIL")
  let assert Ok("UMEMBER") = process.receive(asked, 1000)
  stop(pid)
}

pub fn the_cache_keeps_answers_until_they_expire_test() {
  let cache = people.new_cache(1000)
  let assert None = people.cached(cache, "U1", 0)
  let cache = people.remember(cache, "U1", True, 0)
  let cache = people.remember(cache, "U2", False, 0)
  let assert Some(True) = people.cached(cache, "U1", 999)
  let assert Some(False) = people.cached(cache, "U2", 999)
  let assert None = people.cached(cache, "U1", 1000)
  let assert None = people.cached(people.forget(cache, "U1"), "U1", 10)
}

// REGISTRY --------------------------------------------------------------------

fn launcher_reporting(launches: Subject(String)) -> launcher.Launcher {
  launcher.Launcher(
    launch: fn(key) {
      process.send(launches, key)
      Error("no agents in this test")
    },
    stop: fn(_) { Ok(Nil) },
    exists: fn(_) { False },
    forget: fn(_) { Ok(Nil) },
    rekey: fn(_, _) { Ok(Nil) },
    run_in_sandbox: None,
  )
}

fn start_registry(
  api: String,
  allowed: String,
  launches: Subject(String),
) -> process.Subject(registry.Message) {
  let assert Ok(key) =
    store.parse_key("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")
  let assert Ok(s) = store.start(":memory:", key)
  let assert Ok(r) =
    registry.start(registry.Config(
      launcher: launcher_reporting(launches),
      client: slack_client(api),
      token: "xoxb-test",
      bot_user: "UBOT",
      team: "T1",
      allowed: people.parse(allowed),
      admins: set.new(),
      store: s,
      stranded: set.new(),
      idle_ms: 600_000,
      flush_ms: 50,
      mode: client.Sysadmin,
      tailnet: None,
      stop_backoff_ms: registry.default_stop_backoff_ms,
      root: "/tmp/crushling-people-test",
      github: None,
      default_model: "prism",
    ))
  r
}

fn mention(user: String, ts: String) -> registry.Message {
  registry.Received(msg.Incoming("C1", ts, ts, user, "<@UBOT> hi", True, []))
}

pub fn with_everyone_a_member_launches_and_a_guest_does_not_test() {
  let asked = process.new_subject()
  let launches = process.new_subject()
  let #(api, pid) = fake_slack(asked)
  let r = start_registry(api, "*", launches)
  process.send(r, mention("UMEMBER", "10.1"))
  let assert Ok("UMEMBER") = process.receive(asked, 2000)
  let assert Ok("T1-C1-10.1") = process.receive(launches, 2000)
  // Each in its own thread: one message id is only ever handled once.
  list.each(["UGUEST", "USINGLE", "UOTHER", "UBOTX", "UGONE"], fn(user) {
    process.send(r, mention(user, "11." <> user))
    let assert Ok(looked_up) = process.receive(asked, 2000)
    let assert True = looked_up == user
  })
  let assert Error(Nil) = process.receive(launches, 300)
  stop(pid)
}

pub fn a_cached_answer_avoids_a_second_lookup_test() {
  let asked = process.new_subject()
  let launches = process.new_subject()
  let #(api, pid) = fake_slack(asked)
  let r = start_registry(api, "*", launches)
  // Two at once share one lookup.
  process.send(r, mention("UMEMBER", "20.1"))
  process.send(r, mention("UMEMBER", "21.1"))
  let assert Ok("T1-C1-20.1") = process.receive(launches, 2000)
  let assert Ok("T1-C1-21.1") = process.receive(launches, 2000)
  // And a later one uses the answer kept.
  process.send(r, mention("UMEMBER", "22.1"))
  let assert Ok("T1-C1-22.1") = process.receive(launches, 2000)
  // So does a "no".
  process.send(r, mention("UGUEST", "23.1"))
  process.send(r, mention("UGUEST", "24.1"))
  let assert Error(Nil) = process.receive(launches, 300)
  let assert Ok("UMEMBER") = process.receive(asked, 0)
  let assert Ok("UGUEST") = process.receive(asked, 0)
  let assert Error(Nil) = process.receive(asked, 0)
  stop(pid)
}

pub fn a_failed_lookup_denies_and_is_not_kept_test() {
  let asked = process.new_subject()
  let launches = process.new_subject()
  let #(api, pid) = fake_slack(asked)
  let r = start_registry(api, "*", launches)
  process.send(r, mention("UFAIL", "30.1"))
  let assert Ok("UFAIL") = process.receive(asked, 2000)
  let assert Error(Nil) = process.receive(launches, 300)
  // The next message asks again.
  process.send(r, mention("UFAIL", "31.1"))
  let assert Ok("UFAIL") = process.receive(asked, 2000)
  let assert Error(Nil) = process.receive(launches, 300)
  stop(pid)
}

pub fn a_listed_id_beside_everyone_is_not_looked_up_test() {
  let asked = process.new_subject()
  let launches = process.new_subject()
  let #(api, pid) = fake_slack(asked)
  let r = start_registry(api, "*,ULISTED", launches)
  process.send(r, mention("ULISTED", "40.1"))
  let assert Ok("T1-C1-40.1") = process.receive(launches, 2000)
  let assert Error(Nil) = process.receive(asked, 100)
  stop(pid)
}

pub fn ids_only_never_ask_slack_test() {
  let asked = process.new_subject()
  let launches = process.new_subject()
  let #(api, pid) = fake_slack(asked)
  let r = start_registry(api, "ULISTED", launches)
  process.send(r, mention("UMEMBER", "50.1"))
  let assert Error(Nil) = process.receive(launches, 300)
  let assert Error(Nil) = process.receive(asked, 0)
  stop(pid)
}

// STARTUP AND APPROVERS -------------------------------------------------------

pub fn admins_cannot_be_everyone_test() {
  let assert Error(reason) = instance.env_people("U1", "*")
  let assert True = string.contains(reason, "CRUSHLING_ADMINS")
  let assert Error(_) = instance.env_people("U1", "U2,*")
}

pub fn the_allowlist_must_not_be_empty_test() {
  let assert Error(reason) = instance.env_people(" ", "")
  let assert True = string.contains(reason, "CRUSHLING_ALLOWED_USERS")
}

pub fn everyone_is_accepted_at_startup_test() {
  let assert Ok(#(allowed, admins)) = instance.env_people("*", "U1")
  let assert True = allowed.everyone
  let assert True = admins == set.from_list(["U1"])
}

pub fn everyone_without_admins_means_nobody_approves_test() {
  let assert True =
    people.is_empty(registry.approvers(people.parse("*"), set.new()))
  let assert True =
    people.is_empty(registry.approvers(people.parse("*,U1"), set.new()))
  // Explicit admins still approve.
  let assert True =
    registry.approvers(people.parse("*"), set.from_list(["U2"]))
    == people.only(["U2"])
  // Without everyone, the ids allowed approve, as before.
  let assert True =
    registry.approvers(people.parse("U1"), set.new()) == people.only(["U1"])
}
