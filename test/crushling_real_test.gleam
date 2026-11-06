//// End to end against a real `crush server` and a real model. Skipped unless
//// `CRUSHLING_REAL=1`:
////
////     CRUSHLING_REAL=1 gleam test
////
//// The server gets an isolated global config holding only one provider. Its
//// settings are copied from `~/.local/share/crush/crush.json` but its key
//// comes from `CRUSHLING_TEST_API_KEY` or `CRUSH_<PROVIDER>_API_KEY`, in the
//// environment or `.env`: copying an OAuth login would let the
//// test server rotate, and so revoke, the real refresh token. By default that is hyper,
//// with deepseek as the large model and prism-flash as the small one;
//// override with `CRUSHLING_TEST_PROVIDER`, `CRUSHLING_TEST_LARGE` and
//// `CRUSHLING_TEST_SMALL`. Set `HYPER_URL` to point hyper elsewhere, such
//// as `https://hyper.charmcli.dev`, with a key from that deployment.
////
//// Assertions are about structure (order, diffs, history), never wording,
//// beyond asking the model to echo a marker word.

import crushling/crush/client
import crushling/gun
import crushling/run
import crushling/thread
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/string

@external(erlang, "real_server_ffi", "enabled")
fn enabled() -> Bool

@external(erlang, "real_server_ffi", "env")
fn env(name: String, default: String) -> String

@external(erlang, "real_server_ffi", "start")
fn start_server(socket: String, log: String, home: String) -> Int

@external(erlang, "real_server_ffi", "isolated_config")
fn isolated_config(
  home: String,
  provider: String,
  large: String,
  small: String,
) -> Nil

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
    True ->
      to_dynamic([
        with_timeout(600, queued_prompts_and_bash_diff),
        with_timeout(600, survives_server_restart),
      ])
  }
}

type Env {
  Env(
    dir: String,
    work: String,
    socket: String,
    log: String,
    home: String,
    server: Int,
  )
}

fn setup(name: String) -> Env {
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
  isolated_config(
    home,
    env("CRUSHLING_TEST_PROVIDER", "hyper"),
    env("CRUSHLING_TEST_LARGE", "deepseek-v4.1-flash"),
    env("CRUSHLING_TEST_SMALL", "prism-flash"),
  )
  let socket = dir <> "/crush.sock"
  let log = dir <> "/server.log"
  let server = start_server(socket, log, home)
  wait_for_socket(socket, 15_000)
  Env(dir:, work:, socket:, log:, home:, server:)
}

/// Set up a server and workspace, run the body, and always tear down, so a
/// failed assertion never leaves a server running.
fn with_env(name: String, body: fn(Env) -> Nil) -> Nil {
  let env = setup(name)
  guarded(fn() { body(env) }, fn() { teardown(env) })
}

fn teardown(env: Env) -> Nil {
  kill_on_socket(env.socket)
  let _ = sh("/tmp", "rm -rf '" <> env.dir <> "'")
  Nil
}

fn sink(calls: Subject(Call)) -> thread.Sink {
  thread.Sink(
    post: fn(text) {
      process.send(calls, Progress(text))
      Ok("ts" <> int.to_string(unique()))
    },
    update: fn(_, text) {
      process.send(calls, Progress(text))
      Ok(Nil)
    },
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

fn queued_prompts_and_bash_diff() -> Nil {
  use env <- with_env("queue")
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
  let assert ["notes.txt"] = second.files
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

fn survives_server_restart() -> Nil {
  use env <- with_env("restart")
  let #(t, calls) = start_thread(env)
  process.send(
    t,
    thread.Prompt(
      "Use the bash tool to run: sleep 30\nThen reply with exactly the word DONE.",
    ),
  )
  await_progress(calls, "sleep")

  kill(env.server)
  let server = start_server(env.socket, env.log, env.home)
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
