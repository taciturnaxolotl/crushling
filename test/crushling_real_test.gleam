//// End to end against a real `crush server` and a real model, wired as in
//// production. Skipped unless `CRUSHLING_REAL=1`:
////
////     CRUSHLING_REAL=1 gleam test                               # hyper key
////     CRUSHLING_REAL=1 CRUSHLING_TEST_BACKEND=claude gleam test # Claude
////     CRUSHLING_REAL=1 CRUSHLING_TEST_BACKEND=hyper-login gleam test
////
//// The hyper key comes from `CRUSH_HYPER_API_KEY` (environment or `.env`).
//// The logins are crush.json files only crushling uses, at
//// `CRUSHLING_CLAUDE_LOGIN` / `CRUSHLING_HYPER_LOGIN` (default
//// `~/.local/state/crushling/<claude|hyper>/crush.json`). Seed one with
////
////     CRUSH_GLOBAL_DATA=~/.local/state/crushling/claude crush login claude
////
//// With a login, the server only ever holds a managed token (no refresh
//// token) that `credentials` keeps fresh, as a container does. Never point a
//// test at the login your own crush uses: refresh tokens are single use.
////
//// Models can be overridden with `CRUSHLING_TEST_LARGE` and
//// `CRUSHLING_TEST_SMALL`. Assertions are about structure (order, diffs,
//// history), never wording, beyond asking the model to echo a marker word.

import crushling/credentials
import crushling/crush/client
import crushling/gun
import crushling/launcher
import crushling/provider
import crushling/registry
import crushling/render
import crushling/run
import crushling/snapshot
import crushling/thread
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import slackline

@external(erlang, "real_server_ffi", "enabled")
fn enabled() -> Bool

@external(erlang, "real_server_ffi", "env")
fn env(name: String, default: String) -> String

@external(erlang, "real_server_ffi", "start")
fn start_server(
  socket: String,
  log: String,
  home: String,
  env: List(String),
) -> Int

@external(erlang, "real_server_ffi", "api_key")
fn api_key(name: String) -> Result(String, Nil)

@external(erlang, "real_server_ffi", "claude_version")
fn claude_version() -> String

@external(erlang, "real_server_ffi", "expand_home")
fn expand_home(path: String) -> String

@external(erlang, "crushling_ffi", "file_exists")
fn file_exists(path: String) -> Bool

@external(erlang, "crushling_ffi", "mkdir_p")
fn mkdir_p(path: String) -> Result(Nil, String)

@external(erlang, "crushling_ffi", "write_private")
fn write_private(path: String, content: String) -> Result(Nil, String)

@external(erlang, "real_server_ffi", "kill")
fn kill(os_pid: Int) -> Nil

@external(erlang, "real_server_ffi", "wait_for_file")
fn wait_for_socket(path: String, timeout_ms: Int) -> Nil

@external(erlang, "real_server_ffi", "sh")
fn sh(dir: String, command: String) -> String

@external(erlang, "real_server_ffi", "timeout")
fn with_timeout(seconds: Int, body: fn() -> Nil) -> Dynamic

@external(erlang, "real_server_ffi", "kill_on_socket")
fn kill_on_socket(socket: String) -> Nil

@external(erlang, "real_server_ffi", "guarded")
fn guarded(body: fn() -> a, cleanup: fn() -> Nil) -> a

@external(erlang, "erlang", "unique_integer")
fn unique() -> Int

@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(a: a) -> Dynamic

type Call {
  Progress(String)
  Done(thread.Finished)
}

/// EUnit generator: a list of tests with long timeouts, or none at all.
pub fn real_server_test_() -> Dynamic {
  case enabled() {
    False -> to_dynamic([])
    True -> {
      let backend = backend()
      let wiring = Wiring(backend, start_credentials(backend))
      to_dynamic([
        with_timeout(600, fn() { queued_prompts_and_bash_diff(wiring) }),
        with_timeout(600, fn() { survives_server_restart(wiring) }),
        with_timeout(600, fn() { registry_launches_and_idles(wiring) }),
      ])
    }
  }
}

fn backend() -> provider.Backend {
  let large = fn(default) { env("CRUSHLING_TEST_LARGE", default) }
  let small = fn(default) { env("CRUSHLING_TEST_SMALL", default) }
  case env("CRUSHLING_TEST_BACKEND", "hyper") {
    "claude" ->
      provider.Claude(
        login: login_path("CRUSHLING_CLAUDE_LOGIN", "claude"),
        version: claude_version(),
        large: large("claude-haiku-4-5-20251001"),
        small: small("claude-haiku-4-5-20251001"),
      )
    "hyper-login" ->
      provider.Hyper(
        login: login_path("CRUSHLING_HYPER_LOGIN", "hyper"),
        large: large("deepseek-v4.1-flash"),
        small: small("prism-flash"),
      )
    _ -> {
      let assert Ok(key) = api_key("CRUSH_HYPER_API_KEY")
        as "set CRUSH_HYPER_API_KEY in the environment or .env"
      provider.HyperKey(
        key:,
        large: large("deepseek-v4.1-flash"),
        small: small("prism-flash"),
      )
    }
  }
}

fn login_path(variable: String, name: String) -> String {
  let path =
    expand_home(env(
      variable,
      "~/.local/state/crushling/" <> name <> "/crush.json",
    ))
  case file_exists(path) {
    True -> path
    False ->
      panic as {
        "no crushling "
        <> name
        <> " login at "
        <> path
        <> "; seed one with CRUSH_GLOBAL_DATA=<its dir> crush login "
        <> name
      }
  }
}

type Wiring {
  Wiring(
    backend: provider.Backend,
    credentials: option.Option(process.Subject(credentials.Message)),
  )
}

/// One credentials actor for every test, as for every thread in production.
/// Started unlinked, because EUnit runs the generator in a process that
/// exits before the tests do.
fn start_credentials(
  backend: provider.Backend,
) -> option.Option(process.Subject(credentials.Message)) {
  case provider.login(backend) {
    None -> None
    Some(login) -> {
      let started = process.new_subject()
      process.spawn_unlinked(fn() {
        let assert Ok(creds) = credentials.start(login)
        process.send(started, creds)
        process.sleep_forever()
      })
      let assert Ok(creds) = process.receive(started, 10_000)
      Some(creds)
    }
  }
}

type Env {
  Env(
    dir: String,
    work: String,
    socket: String,
    log: String,
    home: String,
    server_env: List(String),
    server: Int,
  )
}

fn setup(name: String, wiring: Wiring) -> Env {
  let dir =
    "/tmp/crushling-real-"
    <> name
    <> "-"
    <> int.to_string(int.absolute_value(unique()))
  let work = dir <> "/work"
  let _ = sh("/tmp", "rm -rf '" <> dir <> "' && mkdir -p '" <> work <> "'")
  let _ =
    sh(
      work,
      "git init -q && printf 'first line\\n' > notes.txt && git add . && git -c user.email=t@t -c user.name=t commit -qm init",
    )
  let home = dir <> "/home"
  let Wiring(backend:, credentials: creds) = wiring
  let assert Ok(Nil) = mkdir_p(home <> "/config")
  let assert Ok(Nil) = mkdir_p(home <> "/data")
  let config = home <> "/data/crush.json"
  let assert Ok(Nil) = write_private(config, provider.config(backend))
  case creds {
    Some(creds) -> {
      let assert Ok(Nil) = credentials.watch(creds, config)
      Nil
    }
    None -> Nil
  }
  let server_env = provider.env(backend)
  let socket = dir <> "/crush.sock"
  let log = dir <> "/server.log"
  let server = start_server(socket, log, home, server_env)
  wait_for_socket(socket, 15_000)
  Env(dir:, work:, socket:, log:, home:, server_env:, server:)
}

/// Set up a server and workspace, run the body, and always tear down, so a
/// failed assertion never leaves a server running.
fn with_env(name: String, wiring: Wiring, body: fn(Env) -> Nil) -> Nil {
  let env = setup(name, wiring)
  guarded(fn() { body(env) }, fn() { teardown(env) })
}

fn teardown(env: Env) -> Nil {
  kill_on_socket(env.socket)
  let _ = sh("/tmp", "rm -rf '" <> env.dir <> "'")
  Nil
}

fn sink(calls: Subject(Call)) -> thread.Sink {
  let progress = fn(text) {
    process.send(calls, Progress(text))
    Ok("ts" <> int.to_string(unique()))
  }
  let plan_text = fn(plan: render.Plan) { render.plan_markdown(plan) }
  thread.Sink(
    status: fn(_) { Nil },
    post_plan: fn(plan) { progress(plan_text(plan)) },
    update_plan: fn(_, plan) {
      process.send(calls, Progress(plan_text(plan)))
      Ok(Nil)
    },
    post: progress,
    post_controls: fn(_) { Ok("controls") },
    delete: fn(_) { Nil },
    upload: fn(_, _) { Ok(Nil) },
    finished: fn(finished) { process.send(calls, Done(finished)) },
  )
}

fn start_thread(env: Env) -> #(Subject(thread.Message), Subject(Call)) {
  let calls = process.new_subject()
  let assert Ok(t) =
    thread.start(thread.Config(
      socket: env.socket,
      root: env.work,
      title: "crushling real test",
      sink: sink(calls),
      flush_ms: 250,
    ))
  #(t, calls)
}

fn await_finished(calls: Subject(Call)) -> thread.Finished {
  case process.receive(calls, 240_000) {
    Ok(Done(finished)) -> finished
    Ok(Progress(_)) -> await_finished(calls)
    Error(Nil) -> panic as "no run finished within 4 minutes"
  }
}

fn await_progress(calls: Subject(Call), containing: String) -> Nil {
  case process.receive(calls, 240_000) {
    Ok(Progress(text)) ->
      case string.contains(text, containing) {
        True -> Nil
        False -> await_progress(calls, containing)
      }
    Ok(Done(finished)) ->
      panic as { "run finished before showing progress: " <> finished.text }
    Error(Nil) -> panic as "no progress within 4 minutes"
  }
}

fn says(finished: thread.Finished, word: String) -> Bool {
  string.contains(string.uppercase(finished.text), word)
}

fn queued_prompts_and_bash_diff(wiring: Wiring) -> Nil {
  use env <- with_env("queue", wiring)
  let #(t, calls) = start_thread(env)
  process.send(
    t,
    thread.Prompt(
      "Reply with exactly the word ALPHA and nothing else. Use no tools.",
    ),
  )
  process.send(
    t,
    thread.Prompt(
      "Use the bash tool to run: printf 'second line\\n' >> notes.txt\nThen reply with exactly the word BETA.",
    ),
  )

  let first = await_finished(calls)
  let assert run.Completed(_) = first.outcome
  let assert True = says(first, "ALPHA")
  let assert "" = first.patch

  let second = await_finished(calls)
  let assert run.Completed(_) = second.outcome
  let assert True = says(second, "BETA")
  let assert [snapshot.Change("notes.txt", Ok(1), Ok(0))] = second.changes
  let assert True = string.contains(second.patch, "+second line")

  // Snapshot shell calls must not end up in the agent's history, and the
  // workspace's own repository must only see the agent's edit.
  let assert 0 = shell_parts_in_history(env)
  let assert " M notes.txt\n" = sh(env.work, "git status --short")

  process.send(t, thread.Stop)
}

fn shell_parts_in_history(env: Env) -> Int {
  let assert Ok(conn) = gun.connect_unix(env.socket, 5000)
  let client_id = thread.uuid()
  let assert Ok(workspace_id) =
    client.perform(
      conn,
      client.create_workspace(env.work, client_id, client.Yolo, []),
    )
  let assert Ok(sessions) =
    client.perform(conn, client.list_sessions(workspace_id))
  let count =
    list.fold(sessions, 0, fn(count, session_id) {
      let assert Ok(body) =
        client.perform(conn, client.session_messages(workspace_id, session_id))
      count + list.length(string.split(body, "\"shell_command\"")) - 1
    })
  let _ = client.perform(conn, client.retire_client(client_id))
  gun.close(conn)
  count
}

fn survives_server_restart(wiring: Wiring) -> Nil {
  use env <- with_env("restart", wiring)
  let #(t, calls) = start_thread(env)
  process.send(
    t,
    thread.Prompt(
      "Use the bash tool to run: sleep 30\nThen reply with exactly the word DONE.",
    ),
  )
  await_progress(calls, "sleep")

  kill(env.server)
  let server = start_server(env.socket, env.log, env.home, env.server_env)
  let env = Env(..env, server:)
  wait_for_socket(env.socket, 15_000)

  let stranded = await_finished(calls)
  let assert run.Errored("lost the connection mid-run") = stranded.outcome

  // The same session carries on after the restart.
  process.send(
    t,
    thread.Prompt(
      "Reply with exactly the word GAMMA and nothing else. Use no tools.",
    ),
  )
  let after = await_finished(calls)
  let assert run.Completed(_) = after.outcome
  let assert True = says(after, "GAMMA")

  process.send(t, thread.Stop)
}

type Launch {
  Launched(String)
  Stopped(String)
}

/// A mention through the registry and the local launcher: an agent comes up,
/// runs the prompt, and is stopped once the thread goes idle. Slack itself
/// is unreachable here, so replies fail quietly; the launcher is what is
/// observed.
fn registry_launches_and_idles(wiring: Wiring) -> Nil {
  let root =
    "/tmp/crushling-real-registry-"
    <> int.to_string(int.absolute_value(unique()))
  let local = launcher.local(root, wiring.backend, wiring.credentials)
  let launches = process.new_subject()
  let watched =
    launcher.Launcher(
      launch: fn(key) {
        let result = local.launch(key)
        process.send(launches, Launched(key))
        result
      },
      stop: fn(key) {
        local.stop(key)
        process.send(launches, Stopped(key))
      },
    )
  use <-
    guarded(_, fn() {
      let _ =
        sh("/tmp", "pkill -9 -f 'crush server --host unix://" <> root <> "'")
      let _ = sh("/tmp", "rm -rf '" <> root <> "'")
      Nil
    })
  let assert Ok(client) =
    slackline.new("xoxb-test")
    |> slackline.with_base_url("http://127.0.0.1:1/api")
  let assert Ok(r) =
    registry.start(registry.Config(
      launcher: watched,
      client:,
      bot_user: "UBOT",
      allowed: set.from_list(["U1"]),
      idle_ms: 500,
      flush_ms: 250,
    ))
  process.send(
    r,
    registry.Received(registry.Incoming(
      "C1",
      "10.1",
      "10.1",
      "U1",
      "<@UBOT> Reply with exactly the word DELTA and nothing else. Use no tools.",
      True,
    )),
  )
  let assert Ok(Launched(key)) = process.receive(launches, 60_000)
  let assert True = key == registry.key("C1", "10.1")
  let assert Ok(Stopped(stopped)) = process.receive(launches, 240_000)
  let assert True = stopped == key
  // The session survives: its messages are still in the workspace.
  let assert True = file_exists(root <> "/" <> key <> "/work/.crush/crush.db")
  Nil
}
