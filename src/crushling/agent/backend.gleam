//// Where a thread's crush runs, as the few operations a launch and a stop
//// need. The launch itself (tunnel, proxy, waiting for hello, rollback) is
//// written once, in `crushling/launcher`, against this record.
////
//// `docker` gives each thread its own gVisor container; `local` runs
//// `crush server` straight on this machine, for development only: the
//// agent is in YOLO mode with your user's access.

import crushling/agent/post_mortem.{type PostMortem}
import crushling/agent/spec.{type Spec}
import crushling/sandbox
import crushling/sys
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Backend {
  Backend(
    /// Host directory holding one directory per thread.
    root: String,
    /// How crush's home is laid out.
    home: spec.Home,
    /// Make the thread's directories and files, before its tunnel opens.
    prepare: fn(Spec) -> Result(Nil, String),
    /// Start the thread's crush, or adopt one already running as `spec`.
    start: fn(Spec) -> Result(Nil, String),
    /// Whether what `start` started may still dial in; a launch gives up
    /// early once it is False.
    alive: fn(String) -> Bool,
    /// Stop the thread's crush, keeping its state. Nothing running is fine.
    stop: fn(String) -> Result(Nil, String),
    /// Remove whatever runs the thread, for good. Nothing there is fine.
    remove: fn(String) -> Result(Nil, String),
    /// Run a script beside the thread's crush, with extra `NAME=value`
    /// pairs. The local backend has no sandbox to run it in.
    exec: Option(fn(String, List(String), String) -> Result(String, String)),
    /// Whether the thread has a workspace, so it was started before.
    exists: fn(String) -> Bool,
    /// The keys of agents still running, such as ones a previous bridge
    /// left behind.
    running: fn() -> Result(List(String), String),
    /// Why the thread's crush went quiet, asked before it is stopped.
    post_mortem: fn(String) -> PostMortem,
  )
}

/// Each thread in its own gVisor container, through the Engine API.
pub fn docker(policy: sandbox.Policy) -> Backend {
  Backend(
    root: policy.root,
    home: spec.Contained,
    prepare: fn(spec) { sandbox.prepare(policy, spec) |> described },
    start: fn(spec) { sandbox.ensure(policy, spec) |> described },
    // A container that exits early is caught by the hello timeout, which
    // saves an inspect every half second.
    alive: fn(_) { True },
    stop: fn(key) { sandbox.stop(policy, key) |> described },
    remove: fn(key) { sandbox.remove(policy, key) |> described },
    exec: Some(fn(key, env, script) {
      sandbox.run_in(policy, key, env, script) |> described
    }),
    exists: fn(key) { file_exists(sandbox.host_workspace(policy, key)) },
    running: fn() { sandbox.running(policy) |> described },
    post_mortem: fn(key) { docker_post_mortem(policy, key) },
  )
}

fn docker_post_mortem(policy: sandbox.Policy, key: String) -> PostMortem {
  // crush logs to its cache inside the workspace, in a directory named
  // after the tunnel it dials; docker's own log of it is empty.
  let cache = sandbox.host_workspace(policy, key) <> "/.home/.cache/crush"
  let words = fn() {
    sys.list_dir(cache)
    |> result.unwrap([])
    |> list.find(string.starts_with(_, "server-"))
    |> result.try(fn(dir) { sys.read_file(cache <> "/" <> dir <> "/crush.log") })
    |> result.map(post_mortem.last_words)
    |> result.unwrap("")
  }
  case sandbox.remains(policy, key) {
    Ok(sandbox.Running) -> post_mortem.StillRunning(words())
    Ok(sandbox.Gone) -> post_mortem.Vanished
    Ok(sandbox.Stopped(oom: True, ..)) -> post_mortem.OutOfMemory(policy.memory)
    Ok(sandbox.Stopped(code:, ..)) -> post_mortem.Exited(Some(code), words())
    Error(error) -> post_mortem.Unknown(sandbox.describe(error))
  }
}

fn described(result: Result(a, sandbox.Error)) -> Result(a, String) {
  result.map_error(result, sandbox.describe)
}

@external(erlang, "crushling_local_ffi", "start")
fn start_server(
  crush: String,
  dial_url: String,
  workdir: String,
  log: String,
  env: List(String),
  pid_file: String,
) -> Result(Int, String)

@external(erlang, "crushling_local_ffi", "stop")
fn stop_server(pid_file: String) -> Result(Nil, String)

@external(erlang, "crushling_local_ffi", "alive")
fn os_alive(os_pid: Int) -> Bool

@external(erlang, "crushling_local_ffi", "recorded_pid")
fn recorded_pid(pid_file: String) -> Result(Int, Nil)

@external(erlang, "crushling_ffi", "file_exists")
fn file_exists(path: String) -> Bool

/// Each thread's `crush server --dial` on this machine, under
/// `root/<key>`, the same way a sandbox runs it. `crush` is the binary, or
/// "" for the one on `PATH`. Each server's pid is kept in
/// `root/<key>/server.pid`, and it is stopped by that pid.
pub fn local(root: String, crush: String) -> Backend {
  let dir = fn(key) { root <> "/" <> key }
  let pid_file = fn(key) { dir(key) <> "/server.pid" }
  let stop = fn(key) {
    stop_server(pid_file(key))
    |> result.map_error(fn(reason) { "crush server: " <> reason })
  }
  Backend(
    root:,
    home: spec.Beside,
    prepare: fn(spec: Spec) {
      // A server left over from an earlier bridge would keep dialing; this
      // waits for it to exit.
      use _ <- result.try(
        stop_server(pid_file(spec.key))
        |> result.map_error(fn(reason) {
          "an earlier crush server is still running: " <> reason
        }),
      )
      use _ <- result.try(list.try_each(spec.dirs, sys.mkdir_p))
      list.try_each(spec.files, fn(file) { sys.write_private(file.0, file.1) })
    },
    start: fn(spec: Spec) {
      start_server(
        crush,
        spec.dial_url,
        spec.workdir,
        spec.dir <> "/server.log",
        spec.env,
        pid_file(spec.key),
      )
      |> result.replace(Nil)
    },
    alive: fn(key) {
      case recorded_pid(pid_file(key)) {
        Ok(os_pid) -> os_alive(os_pid)
        Error(Nil) -> False
      }
    },
    stop:,
    remove: stop,
    exec: None,
    exists: fn(key) { file_exists(dir(key) <> "/work") },
    // Each launch stops the server its key left behind, so there is
    // nothing to sweep at boot.
    running: fn() { Ok([]) },
    post_mortem: fn(key) {
      let words =
        sys.read_file(dir(key) <> "/server.log")
        |> result.map(post_mortem.last_words)
        |> result.unwrap("")
      case recorded_pid(pid_file(key)) {
        Ok(os_pid) ->
          case os_alive(os_pid) {
            True -> post_mortem.StillRunning(words)
            False -> post_mortem.Exited(None, words)
          }
        Error(Nil) -> post_mortem.Exited(None, words)
      }
    },
  )
}
