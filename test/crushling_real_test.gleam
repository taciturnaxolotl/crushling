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
import crushling/mcp
import crushling/provider
import crushling/registry
import crushling/registry/incoming as msg
import crushling/render
import crushling/run
import crushling/sink
import crushling/slack_tools
import crushling/snapshot
import crushling/sys
import crushling/thread
import crushling/venue
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
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
        with_timeout(600, fn() { shutdown_cancels_and_stops(wiring) }),
        with_timeout(600, fn() { subagents_get_their_own_threads(wiring) }),
        with_timeout(600, fn() { cloning_moves_to_a_code_channel(wiring) }),
        with_timeout(600, fn() { failed_code_channel_keeps_the_diff(wiring) }),
        with_timeout(600, fn() { agent_uses_slack_tools(wiring) }),
        with_timeout(600, fn() { prompts_carry_images(wiring) }),
        ..case env("CRUSHLING_TEST_EXTRA", "") {
          "claude" -> [
            with_timeout(600, fn() { subagents_use_extra_providers(wiring) }),
          ]
          _ -> []
        }
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
  setup_with(name, wiring, launcher.no_bridge())
}

fn setup_with(name: String, wiring: Wiring, bridge: launcher.Bridge) -> Env {
  setup_full(name, wiring, bridge, [], [])
}

fn setup_full(
  name: String,
  wiring: Wiring,
  bridge: launcher.Bridge,
  extras: List(provider.Backend),
  extra_creds: List(process.Subject(credentials.Message)),
) -> Env {
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
  let assert Ok(Nil) =
    write_private(config, provider.config_for(backend, extras, bridge.url))
  list.each([creds, ..list.map(extra_creds, Some)], fn(creds) {
    case creds {
      Some(creds) -> {
        let assert Ok(Nil) = credentials.watch(creds, config)
        Nil
      }
      None -> Nil
    }
  })
  let server_env =
    list.append(
      provider.env_for(backend, extras),
      bridge.env(string.inspect(unique())),
    )
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

fn sink(calls: Subject(Call)) -> sink.Sink {
  let progress = fn(text) {
    process.send(calls, Progress(text))
    Ok("ts" <> int.to_string(unique()))
  }
  let plan_text = fn(plan: render.Plan) { render.plan_markdown(plan) }
  sink.Sink(
    working: fn(_) { Nil },
    title: fn(_) { Nil },
    post_plan: fn(plan) { progress(plan_text(plan)) },
    reply: fn(_) {
      fake_reply(progress, fn(text) { progress(text) |> fn(_) { Nil } })
    },
    update_plan: fn(_, plan) {
      process.send(calls, Progress(plan_text(plan)))
      Ok(Nil)
    },
    post: progress,
    upload: fn(_, _) { Ok(Nil) },
    branch: fn(_, _) { Error("no branches in this test") },
    open_code_channel: fn(_) { Error("no code channels in this test") },
    context: fn(_) { Nil },
    code: fn(_, _, _) { Nil },
    conversation: sink.Conversation("CTEST", Some("1.0")),
  )
}

fn prompt(text: String) -> thread.Message {
  thread.Prompt(text, [], "")
}

/// A thread's notices, keeping only the runs that end.
fn on_finished(then: fn(thread.Finished) -> Nil) -> fn(thread.Notice) -> Nil {
  fn(notice) {
    case notice {
      thread.RunEnded(finished) -> then(finished)
      _ -> Nil
    }
  }
}

fn start_thread(env: Env) -> #(Subject(thread.Message), Subject(Call)) {
  let calls = process.new_subject()
  let assert Ok(t) =
    thread.start(thread.Config(
      socket: env.socket,
      root: env.work,
      title: "crushling real test",
      venue: venue.Thread,
      sink: sink(calls),
      flush_ms: 250,
      mode: client.Sysadmin,
      notify: on_finished(fn(finished) { process.send(calls, Done(finished)) }),
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
    prompt("Reply with exactly the word ALPHA and nothing else. Use no tools."),
  )
  process.send(
    t,
    prompt(
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
  let client_id = sys.uuid()
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
    prompt(
      "Use the bash tool to run: sleep 30\nThen reply with exactly the word DONE.",
    ),
  )
  // A step still running, which is the sleep.
  await_progress(calls, "▸")

  kill(env.server)
  let server = start_server(env.socket, env.log, env.home, env.server_env)
  let env = Env(..env, server:)
  wait_for_socket(env.socket, 15_000)

  let stranded = await_finished(calls)
  let assert run.Errored("lost the connection mid-run") = stranded.outcome

  // The same session carries on after the restart.
  process.send(
    t,
    prompt("Reply with exactly the word GAMMA and nothing else. Use no tools."),
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
  let local =
    launcher.local(
      root,
      wiring.backend,
      [],
      option.values([wiring.credentials]),
      launcher.no_bridge(),
    )
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
      exists: local.exists,
      meta_path: local.meta_path,
      attachments: local.attachments,
      workspace: local.workspace,
      run_in_sandbox: local.run_in_sandbox,
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
      token: "xoxb-test",
      bot_user: "UBOT",
      team: "T1",
      allowed: set.from_list(["U1"]),
      idle_ms: 500,
      flush_ms: 250,
      mode: client.Sysadmin,
      tailnet: None,
    ))
  process.send(
    r,
    registry.Received(
      msg.Incoming(
        "C1",
        "10.1",
        "10.1",
        "U1",
        "<@UBOT> Reply with exactly the word DELTA and nothing else. Use no tools.",
        True,
        [],
      ),
    ),
  )
  let assert Ok(Launched(key)) = process.receive(launches, 60_000)
  let assert True = key == registry.key("C1", "10.1")
  let assert Ok(Stopped(stopped)) = process.receive(launches, 240_000)
  let assert True = stopped == key
  // The session survives: its messages are still in the workspace.
  let assert True = file_exists(root <> "/" <> key <> "/work/.crush/crush.db")
  Nil
}

/// Shutdown mid-run: the turn gets its grace period, is then cancelled, and
/// the agent is stopped before the registry reports done.
fn shutdown_cancels_and_stops(wiring: Wiring) -> Nil {
  let root =
    "/tmp/crushling-real-shutdown-"
    <> int.to_string(int.absolute_value(unique()))
  let local =
    launcher.local(
      root,
      wiring.backend,
      [],
      option.values([wiring.credentials]),
      launcher.no_bridge(),
    )
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
      exists: local.exists,
      meta_path: local.meta_path,
      attachments: local.attachments,
      workspace: local.workspace,
      run_in_sandbox: local.run_in_sandbox,
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
      token: "xoxb-test",
      bot_user: "UBOT",
      team: "T1",
      allowed: set.from_list(["U1"]),
      idle_ms: 600_000,
      flush_ms: 250,
      mode: client.Sysadmin,
      tailnet: None,
    ))
  process.send(
    r,
    registry.Received(
      msg.Incoming(
        "C1",
        "20.1",
        "20.1",
        "U1",
        "<@UBOT> Use the bash tool to run: sleep 120\nThen reply DONE.",
        True,
        [],
      ),
    ),
  )
  let assert Ok(Launched(key)) = process.receive(launches, 60_000)
  // Give the turn time to start its command.
  process.sleep(15_000)
  let done = process.new_subject()
  process.send(r, registry.Shutdown(2000, done))
  let assert Ok(Stopped(stopped)) = process.receive(launches, 60_000)
  let assert True = stopped == key
  let assert Ok(Nil) = process.receive(done, 60_000)
  let assert "" =
    string.trim(sh(
      "/tmp",
      "pgrep -f 'crush server --host unix://" <> root <> "'",
    ))
  Nil
}

type SubCall {
  Branched(intro: String, title: String)
  InBranch(text: String)
  InMain(text: String)
  MainFinished(solicited: Bool)
}

fn recording_sink(calls: Subject(SubCall), in_branch: Bool) -> sink.Sink {
  let post = fn(text) {
    process.send(calls, case in_branch {
      True -> InBranch(text)
      False -> InMain(text)
    })
    Ok("ts" <> int.to_string(unique()))
  }
  sink.Sink(
    working: fn(_) { Nil },
    title: fn(_) { Nil },
    post_plan: fn(plan) { post(render.plan_markdown(plan)) },
    reply: fn(_) { fake_reply(post, fn(_) { Nil }) },
    update_plan: fn(_, _) { Ok(Nil) },
    post:,
    upload: fn(_, _) { Ok(Nil) },
    branch: fn(intro, title) {
      process.send(calls, Branched(intro, title))
      Ok(#(recording_sink(calls, True), "https://slack.example/thread"))
    },
    open_code_channel: fn(_) { Error("no code channels in this test") },
    context: fn(_) { Nil },
    code: fn(_, _, _) { Nil },
    conversation: sink.Conversation("CTEST", Some("1.0")),
  )
}

/// A dispatched subagent opens its own thread, works there, and its report
/// comes back to the main thread; crush's own turn to read the report is
/// adopted and reported as unsolicited.
fn subagents_get_their_own_threads(wiring: Wiring) -> Nil {
  use env <- with_env("subagent", wiring)
  let calls = process.new_subject()
  let assert Ok(t) =
    thread.start(thread.Config(
      socket: env.socket,
      root: env.work,
      title: "crushling subagent test",
      venue: venue.Thread,
      sink: recording_sink(calls, False),
      flush_ms: 250,
      mode: client.Sysadmin,
      notify: on_finished(fn(finished) {
        process.send(calls, MainFinished(finished.solicited))
      }),
    ))
  process.send(
    t,
    prompt(
      "Start one subagent (agent_dispatch if you have it, otherwise agent) with the label \"count-files\" and the prompt \"Use the ls tool on the current directory, then reply with how many entries it has.\". Then reply with the word OK.",
    ),
  )
  let seen = collect_sub_calls(calls, 0, [])
  // The subagent got a thread of its own, worked there, and reported back.
  let assert True =
    list.any(seen, fn(call) {
      case call {
        Branched(..) -> True
        _ -> False
      }
    })
  let assert True =
    list.any(seen, fn(call) {
      case call {
        InBranch(text) ->
          string.contains(text, "▸") || string.contains(text, "✓")
        _ -> False
      }
    })
  let assert True =
    list.any(seen, fn(call) {
      case call {
        InMain(text) -> string.contains(text, "* finished _")
        _ -> False
      }
    })
  let assert True = list.contains(seen, MainFinished(True))
  // Crush's own turn to read the report was adopted, not lost.
  let assert True = list.contains(seen, MainFinished(False))
  process.send(t, thread.Stop)
}

/// Collect until the prompt's run has finished and the subagent reported
/// back, plus the turn crush starts to read the report, if any.
fn collect_sub_calls(
  calls: Subject(SubCall),
  finished: Int,
  acc: List(SubCall),
) -> List(SubCall) {
  let reported =
    list.any(acc, fn(call) {
      case call {
        InMain(text) -> string.contains(text, "* finished _")
        _ -> False
      }
    })
  let report_turn = list.contains(acc, MainFinished(False))
  case finished >= 2 && reported && report_turn {
    True -> list.reverse(acc)
    False ->
      case process.receive(calls, 240_000) {
        Ok(MainFinished(_) as call) ->
          collect_sub_calls(calls, finished + 1, [call, ..acc])
        Ok(call) -> collect_sub_calls(calls, finished, [call, ..acc])
        Error(Nil) ->
          panic as { "stuck; saw " <> string.inspect(list.reverse(acc)) }
      }
  }
}

type CodeCall {
  Opened(name: String)
  InThreadPost(String)
  InChannelPost(String)
  CodeView(diff: String)
  CodeFinished(changes: List(snapshot.Change), patch: String)
}

/// A sink that records where things are posted. `opens` is whether
/// Slack lets it open a code channel.
fn code_sink(
  calls: Subject(CodeCall),
  in_channel: Bool,
  opens: Bool,
) -> sink.Sink {
  let post = fn(text) {
    process.send(calls, case in_channel {
      True -> InChannelPost(text)
      False -> InThreadPost(text)
    })
    Ok("ts" <> int.to_string(unique()))
  }
  sink.Sink(
    working: fn(_) { Nil },
    title: fn(_) { Nil },
    post_plan: fn(plan) { post(render.plan_markdown(plan)) },
    reply: fn(_) { fake_reply(post, fn(_) { Nil }) },
    update_plan: fn(_, _) { Ok(Nil) },
    post:,
    upload: fn(_, _) { Ok(Nil) },
    branch: fn(_, _) { Error("no branches in this test") },
    open_code_channel: fn(name) {
      process.send(calls, Opened(name))
      case in_channel, opens {
        True, _ -> Error("already in a code channel")
        False, False -> Error("not_allowed creating a code channel")
        False, True -> Ok(#(code_sink(calls, True, True), "CCODE"))
      }
    },
    context: fn(_) { Nil },
    code: fn(diff, _, _) {
      case in_channel {
        True -> process.send(calls, CodeView(diff))
        False -> Nil
      }
    },
    conversation: sink.Conversation("CTEST", Some("1.0")),
  )
}

fn collect_code_calls(
  calls: Subject(CodeCall),
  acc: List(CodeCall),
) -> List(CodeCall) {
  case process.receive(calls, 240_000) {
    Ok(CodeFinished(..) as call) -> list.reverse([call, ..acc])
    Ok(call) -> collect_code_calls(calls, [call, ..acc])
    Error(Nil) -> panic as { "stuck; saw " <> string.inspect(list.reverse(acc)) }
  }
}

/// Clone a repository and change it, with a sink that can or can't open
/// a code channel. What the sinks saw, up to the run's end.
fn clone_and_edit(env: Env, opens: Bool) -> List(CodeCall) {
  let source = env.dir <> "/source"
  let _ =
    sh(
      "/tmp",
      "mkdir -p '"
        <> source
        <> "' && cd '"
        <> source
        <> "' && git init -q -b main && printf 'one\\n' > notes.txt && git add . && git -c user.name=t -c user.email=t@t commit -qm init",
    )
  let calls = process.new_subject()
  let assert Ok(t) =
    thread.start(thread.Config(
      socket: env.socket,
      root: env.work,
      title: "crushling code channel test",
      venue: venue.Thread,
      sink: code_sink(calls, False, opens),
      flush_ms: 250,
      mode: client.Sysadmin,
      notify: on_finished(fn(finished) {
        process.send(calls, CodeFinished(finished.changes, finished.patch))
      }),
    ))
  process.send(
    t,
    prompt(
      "Use the bash tool to run exactly `git clone "
      <> source
      <> " demo`. Then use bash to append the line two to demo/notes.txt. Then reply with the word DONE.",
    ),
  )
  let seen = collect_code_calls(calls, [])
  process.send(t, thread.Stop)
  seen
}

/// Cloning a repository moves the work to a code channel, whose Code tab
/// shows the repository's changes instead of an attached patch.
fn cloning_moves_to_a_code_channel(wiring: Wiring) -> Nil {
  use env <- with_env("code-channel", wiring)
  let seen = clone_and_edit(env, True)
  let assert True = list.contains(seen, Opened("source"))
  let assert True =
    list.any(seen, fn(call) {
      case call {
        InThreadPost(text) -> string.contains(text, "<#CCODE>")
        _ -> False
      }
    })
  let assert True =
    list.any(seen, fn(call) {
      case call {
        InChannelPost(text) -> string.contains(string.uppercase(text), "DONE")
        _ -> False
      }
    })
  let assert True =
    list.any(seen, fn(call) {
      case call {
        CodeView(diff) -> string.contains(diff, "+two")
        _ -> False
      }
    })
  // The run moved mid-turn, and the channel's Code tab lists the changes:
  // no line naming them, and no patch.
  let assert False =
    list.any(seen, fn(call) {
      case call {
        InChannelPost(text) -> string.contains(text, "notes.txt")
        _ -> False
      }
    })
  let assert Ok(CodeFinished(
    changes: [snapshot.Change("notes.txt", Ok(1), Ok(0))],
    patch: "",
  )) = list.last(seen)
  Nil
}

/// When Slack won't open a code channel the work stays in the thread, and
/// so does the run's diff.
fn failed_code_channel_keeps_the_diff(wiring: Wiring) -> Nil {
  use env <- with_env("code-channel-refused", wiring)
  let seen = clone_and_edit(env, False)
  let assert True = list.contains(seen, Opened("source"))
  let assert False =
    list.any(seen, fn(call) {
      case call {
        InChannelPost(_) | CodeView(_) -> True
        _ -> False
      }
    })
  let assert Ok(CodeFinished(changes:, patch:)) = list.last(seen)
  let assert True = changes != []
  let assert True = string.contains(patch, "+two")
  Nil
}

/// The agent reaches crushling's Slack tools over MCP, with its own token.
fn agent_uses_slack_tools(wiring: Wiring) -> Nil {
  let port = 17_000 + int.absolute_value(unique()) % 2000
  let calls = process.new_subject()
  let secret = "test-secret"
  let assert Ok(Nil) =
    mcp.start(
      "127.0.0.1",
      port,
      secret,
      slack_tools.tools(tailnet: False),
      fn(key, name, arguments) {
        process.send(calls, #(key, name, arguments))
        Ok("posted")
      },
    )
  let keys = process.new_subject()
  let bridge =
    launcher.Bridge(
      url: "http://127.0.0.1:" <> int.to_string(port),
      env: fn(key) {
        process.send(keys, key)
        mcp.env(secret, key)
      },
    )
  let env = setup_with("mcp", wiring, bridge)
  let assert Ok(key) = process.receive(keys, 1000)
  use <- guarded(_, fn() { teardown(env) })
  let #(t, finished) = start_thread(env)
  process.send(
    t,
    prompt(
      "Call the post_message tool from the slack MCP server with the text HELLO-MCP. Then reply with the word DONE.",
    ),
  )
  let _ = await_finished(finished)
  let assert Ok(#(called_key, "post_message", arguments)) =
    process.receive(calls, 1000)
  let assert True = called_key == key
  let assert Ok(text) =
    decode.run(arguments, decode.at(["text"], decode.string))
  let assert True = string.contains(text, "HELLO-MCP")
  process.send(t, thread.Stop)
}

/// A prompt with an image attached reaches crush and runs; a model without
/// vision gets the text alone.
fn prompts_carry_images(wiring: Wiring) -> Nil {
  use env <- with_env("image", wiring)
  let #(t, calls) = start_thread(env)
  // A 1x1 red PNG.
  let assert Ok(png) =
    bit_array.base64_decode(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==",
    )
  process.send(
    t,
    thread.Prompt(
      "An image may be attached. Use no tools; reply with the word SEEN.",
      [
        client.Attachment(
          path: ".slack/1.0/red.png",
          name: "red.png",
          mime_type: "image/png",
          content: png,
        ),
      ],
      "",
    ),
  )
  let finished = await_finished(calls)
  let assert True = says(finished, "SEEN")
  process.send(t, thread.Stop)
}

/// With Claude as an extra backend, the agent can run a subagent on a
/// Claude model while it runs on its own provider.
fn subagents_use_extra_providers(wiring: Wiring) -> Nil {
  let claude =
    provider.Claude(
      login: login_path("CRUSHLING_CLAUDE_LOGIN", "claude"),
      version: claude_version(),
      large: "claude-haiku-4-5-20251001",
      small: "claude-haiku-4-5-20251001",
    )
  let assert Some(claude_creds) = start_credentials(claude)
  let env =
    setup_full("extra", wiring, launcher.no_bridge(), [claude], [
      claude_creds,
    ])
  use <- guarded(_, fn() { teardown(env) })
  let calls = process.new_subject()
  let assert Ok(t) =
    thread.start(thread.Config(
      socket: env.socket,
      root: env.work,
      title: "crushling extra provider test",
      venue: venue.Thread,
      sink: recording_sink(calls, False),
      flush_ms: 250,
      mode: client.Sysadmin,
      notify: on_finished(fn(finished) {
        process.send(calls, MainFinished(finished.solicited))
      }),
    ))
  process.send(
    t,
    prompt(
      "Start one subagent with agent_dispatch, label \"hello\", provider \"anthropic\", model \"claude-haiku-4-5-20251001\", and the prompt \"Reply with the word HI.\". Then reply with the word OK.",
    ),
  )
  await_report(calls, False, False)
  process.send(t, thread.Stop)
  let providers =
    sh(
      env.work,
      "for db in $(find .. -name crush.db); do sqlite3 \"$db\" \"select distinct provider from messages where role='assistant' and provider != ''\"; done",
    )
  let assert True = string.contains(providers, "anthropic")
  let assert True = string.contains(providers, "hyper")
  Nil
}

/// Wait until the subagent has reported back and the prompt's run is done,
/// in either order.
fn await_report(calls: Subject(SubCall), reported: Bool, done: Bool) -> Nil {
  case reported && done {
    True -> Nil
    False ->
      case process.receive(calls, 240_000) {
        Ok(InMain(text)) ->
          await_report(
            calls,
            reported || string.contains(text, "* finished _"),
            done,
          )
        Ok(MainFinished(True)) -> await_report(calls, reported, True)
        Ok(_) -> await_report(calls, reported, done)
        Error(Nil) -> panic as "the subagent never reported back"
      }
  }
}

/// A reply that posts its last text, and its closing line, when it
/// finishes; `progress` sees each step list as markdown.
fn fake_reply(
  post: fn(String) -> Result(String, String),
  progress: fn(String) -> Nil,
) -> sink.Reply {
  let latest = process.new_subject()
  sink.Reply(
    show: fn(text, tasks, title) {
      process.send(latest, text)
      case tasks {
        [] -> Nil
        tasks -> progress(render.plan_markdown(render.Plan(title:, tasks:)))
      }
    },
    finish: fn(closing) {
      let text = drain(latest, "")
      case
        [text, closing]
        |> list.filter(fn(part) { part != "" })
        |> string.join("\n\n")
      {
        "" -> []
        text ->
          case post(text) {
            Ok(ts) -> [ts]
            Error(_) -> []
          }
      }
    },
  )
}

fn drain(subject: Subject(String), last: String) -> String {
  case process.receive(subject, 0) {
    Ok(text) -> drain(subject, text)
    Error(Nil) -> last
  }
}
