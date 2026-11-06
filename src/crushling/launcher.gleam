//// Where a thread's agent runs. `docker` gives each thread its own gVisor
//// container; `local` runs `crush server` straight on this machine, for
//// development only: the agent is in YOLO mode with your user's access.
////
//// Either way the agent's crush.json is written from `provider.config`, and
//// for a login `credentials` adds a managed token before crush starts and
//// keeps it fresh until the thread is stopped.

import crushling/credentials
import crushling/provider
import crushling/sandbox
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Launched {
  Launched(
    /// The unix socket of the thread's `crush server`.
    socket: String,
    /// The workspace path as that server sees it.
    root: String,
  )
}

pub type Launcher {
  Launcher(
    launch: fn(String) -> Result(Launched, String),
    /// Stop the thread's agent but keep its workspace.
    stop: fn(String) -> Nil,
    /// Whether the thread has a workspace, so it was started before.
    exists: fn(String) -> Bool,
    /// The thread's workspace on this machine.
    workspace: fn(String) -> String,
    /// Where the bridge keeps the thread's `meta`, outside the workspace.
    meta_path: fn(String) -> String,
    /// Where Slack attachments are saved: the host directory, and the same
    /// directory relative to the agent's workspace.
    attachments: fn(String) -> #(String, String),
  )
}

/// How a thread's agent reaches crushling's Slack tools: the base URL it
/// connects to ("" for none), and each thread's environment for it.
pub type Bridge {
  Bridge(url: String, env: fn(String) -> List(String))
}

pub fn no_bridge() -> Bridge {
  Bridge(url: "", env: fn(_) { [] })
}

/// Attachments live in the workspace, so the agent can open them, under a
/// directory the change snapshots leave out.
pub const attachments_dir = ".slack"

type Credentials =
  Option(Subject(credentials.Message))

fn watch(creds: Credentials, path: String) -> Result(Nil, String) {
  case creds {
    Some(creds) -> credentials.watch(creds, path)
    None -> Ok(Nil)
  }
}

fn unwatch(creds: Credentials, path: String) -> Nil {
  case creds {
    Some(creds) -> credentials.unwatch(creds, path)
    None -> Nil
  }
}

/// `policy.crush_config` should come from `provider.config_with` and the
/// bridge's URL.
pub fn docker(
  policy: sandbox.Policy,
  creds: Credentials,
  bridge: Bridge,
) -> Launcher {
  let config = fn(key) { sandbox.host_crush_data(policy, key) <> "/crush.json" }
  Launcher(
    launch: fn(key) {
      sandbox.ensure(policy, key, bridge.env(key), fn() {
        watch(creds, config(key))
      })
      |> result.map(fn(socket) { Launched(socket:, root: sandbox.workspace) })
      |> result.map_error(string.inspect)
    },
    stop: fn(key) {
      unwatch(creds, config(key))
      let _ = sandbox.stop(policy, key)
      Nil
    },
    exists: fn(key) { file_exists(sandbox.host_workspace(policy, key)) },
    workspace: fn(key) { sandbox.host_workspace(policy, key) },
    meta_path: fn(key) { policy.root <> "/" <> key <> "/crushling.json" },
    attachments: fn(key) {
      #(
        sandbox.host_workspace(policy, key) <> "/" <> attachments_dir,
        attachments_dir,
      )
    },
  )
}

@external(erlang, "crushling_local_ffi", "start")
fn start_server(
  socket: String,
  workdir: String,
  log: String,
  env: List(String),
) -> Result(Int, String)

@external(erlang, "crushling_local_ffi", "stop")
fn stop_server(socket: String) -> Nil

@external(erlang, "crushling_local_ffi", "wait_until_serving")
fn wait_until_serving(
  path: String,
  os_pid: Int,
  timeout_ms: Int,
) -> Result(Nil, String)

@external(erlang, "crushling_ffi", "file_exists")
fn file_exists(path: String) -> Bool

@external(erlang, "crushling_ffi", "mkdir_p")
fn mkdir_p(path: String) -> Result(Nil, String)

@external(erlang, "crushling_ffi", "write_private")
fn write_private(path: String, content: String) -> Result(Nil, String)

/// Run each thread's `crush server` on this machine, under `root/<key>`.
pub fn local(
  root: String,
  backend: provider.Backend,
  creds: Credentials,
  bridge: Bridge,
) -> Launcher {
  let dir = fn(key) { root <> "/" <> key }
  let socket = fn(key) { dir(key) <> "/crush.sock" }
  let config = fn(key) { dir(key) <> "/home/data/crush.json" }
  Launcher(
    launch: fn(key) {
      let base = dir(key)
      let work = base <> "/work"
      use _ <- result.try(mkdir_p(work))
      use _ <- result.try(mkdir_p(base <> "/home/config"))
      use _ <- result.try(mkdir_p(base <> "/home/data"))
      use _ <- result.try(mkdir_p(base <> "/home/honcho"))
      use _ <- result.try(write_private(
        config(key),
        provider.config_with(backend, bridge.url),
      ))
      use _ <- result.try(watch(creds, config(key)))
      // A server left over from an earlier bridge would keep the socket;
      // this waits for it to exit.
      stop_server(socket(key))
      let env = [
        "CRUSH_GLOBAL_CONFIG=" <> base <> "/home/config",
        "CRUSH_GLOBAL_DATA=" <> base <> "/home/data",
        // The same goes for the Honcho memory sign-in in ~/.honcho, which
        // would otherwise record every Slack conversation as yours.
        "HONCHO_CONFIG_DIR=" <> base <> "/home/honcho",
        "CRUSH_SERVER_IDLE_TIMEOUT=31536000",
        "CRUSH_SERVER_DETACH_GRACE=120",
        ..list.append(provider.env(backend), bridge.env(key))
      ]
      use os_pid <- result.try(start_server(
        socket(key),
        work,
        base <> "/server.log",
        env,
      ))
      use _ <- result.try(wait_until_serving(socket(key), os_pid, 15_000))
      Ok(Launched(socket: socket(key), root: work))
    },
    stop: fn(key) {
      unwatch(creds, config(key))
      stop_server(socket(key))
    },
    exists: fn(key) { file_exists(dir(key) <> "/work") },
    workspace: fn(key) { dir(key) <> "/work" },
    meta_path: fn(key) { dir(key) <> "/crushling.json" },
    attachments: fn(key) {
      #(dir(key) <> "/work/" <> attachments_dir, attachments_dir)
    },
  )
}
