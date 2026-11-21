//// Where a thread's agent runs. `docker` gives each thread its own gVisor
//// container; `local` runs `crush server` straight on this machine, for
//// development only: the agent is in YOLO mode with your user's access.
////
//// Either way crush runs with `--dial`: it connects out to the bridge's
//// tunnel (`crushling/tunnel`), which the thread reaches through the
//// tunnel's unix socket shim, and it uses Hyper through the bridge's
//// inference proxy (`crushling/proxy`) with a token of the thread's own.
//// The agent's crush.json comes from `provider.config` and holds no key.

import crushling/mcp
import crushling/provider
import crushling/proxy
import crushling/sandbox
import crushling/sys
import crushling/tunnel
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Launched {
  Launched(
    /// The unix socket the thread connects to: the tunnel's shim for the
    /// thread's `crush server`.
    socket: String,
    /// The workspace path as that server sees it.
    root: String,
  )
}

pub type Launcher {
  Launcher(
    launch: fn(String) -> Result(Launched, String),
    /// Stop the thread's agent but keep its workspace. An error says what
    /// couldn't be undone; the stop may be tried again.
    stop: fn(String) -> Result(Nil, String),
    /// Whether the thread has a workspace, so it was started before.
    exists: fn(String) -> Bool,
    /// The thread's workspace on this machine.
    workspace: fn(String) -> String,
    /// Where the bridge keeps the thread's `meta`, outside the workspace.
    meta_path: fn(String) -> String,
    /// Where Slack attachments are saved: the host directory, and the same
    /// directory relative to the agent's workspace.
    attachments: fn(String) -> #(String, String),
    /// Run a script in a thread's sandbox, with extra `NAME=value` pairs.
    /// The local launcher has no sandbox.
    run_in_sandbox: Option(
      fn(String, List(String), String) -> Result(String, String),
    ),
  )
}

/// What a thread's agent needs from the bridge: the URL it reaches the
/// sandbox server at (Slack tools, tunnel and proxy share it), its
/// environment for them, and the tunnel and proxy operations a launch and
/// a stop go through. `bridge` builds the real one.
pub type Bridge {
  Bridge(
    url: String,
    /// `NAME=value` pairs for a thread: its Slack tools token, its tunnel
    /// dial token, and `HYPER_URL` and `HYPER_API_KEY` for the proxy.
    env: fn(String) -> List(String),
    /// Open the thread's tunnel endpoint and return its shim's path.
    open: fn(String) -> Result(String, String),
    /// Wait this long for the thread's crush to dial in.
    await_hello: fn(String, Int) -> Result(String, String),
    /// Tell the thread's crush to exit.
    bye: fn(String) -> Nil,
    /// Close the thread's tunnel endpoint.
    close: fn(String) -> Nil,
    /// Let the thread's proxy token work again.
    restore: fn(String) -> Nil,
    /// Stop the thread's proxy token from working.
    revoke: fn(String) -> Nil,
    /// How long a launch waits for crush to dial in.
    hello_timeout_ms: Int,
  )
}

/// How long a launch waits for crush to dial in, by default. gVisor and
/// crush take a few seconds to boot.
pub const default_hello_timeout_ms = 30_000

/// The bridge, from the instance secret, the URL sandboxes reach the
/// sandbox server at, the tunnels and the proxy.
pub fn bridge(
  url url: String,
  secret secret: String,
  tunnels tunnels: tunnel.Tunnels,
  proxy proxy: proxy.Proxy,
  hello_timeout_ms hello_timeout_ms: Int,
) -> Bridge {
  Bridge(
    url:,
    env: fn(key) {
      list.flatten([
        mcp.env(secret, key),
        tunnel.env(secret, key),
        proxy.crush_env(url, secret, key),
      ])
    },
    open: fn(key) { tunnel.open(tunnels, key) },
    await_hello: fn(key, timeout_ms) {
      tunnel.await_hello(tunnels, key, timeout_ms)
    },
    bye: fn(key) { tunnel.bye(tunnels, key) },
    close: fn(key) { tunnel.close(tunnels, key) },
    restore: fn(key) { proxy.restore(proxy, key) },
    revoke: fn(key) { proxy.revoke(proxy, key) },
    hello_timeout_ms:,
  )
}

/// Attachments live in the workspace, so the agent can open them, under a
/// directory the change snapshots leave out.
pub const attachments_dir = ".slack"

/// Launch the thread's agent with `launcher`, then do `next` with it. If
/// `next` fails, the agent is stopped again, since nothing would drive it.
pub fn launch_then(
  launcher: Launcher,
  key: String,
  next: fn(Launched) -> Result(a, String),
) -> Result(a, String) {
  use launched <- result.try(launcher.launch(key))
  case next(launched) {
    Ok(value) -> Ok(value)
    Error(reason) ->
      case launcher.stop(key) {
        Ok(Nil) -> Error(reason)
        Error(cleanup) -> {
          sys.warn("crushling: cleaning up " <> key <> ": " <> cleanup)
          Error(reason <> " (cleanup failed: " <> cleanup <> ")")
        }
      }
  }
}

/// A launch's error, with whatever its rollback couldn't undo. Those are
/// logged too.
fn undone(key: String, reason: String, cleanup: List(String)) -> String {
  case cleanup {
    [] -> reason
    errors -> {
      list.each(errors, fn(error) {
        sys.warn("crushling: cleaning up " <> key <> ": " <> error)
      })
      reason <> " (cleanup failed: " <> string.join(errors, "; ") <> ")"
    }
  }
}

/// A stop's result: what couldn't be undone, also logged.
fn stop_result(key: String, errors: List(String)) -> Result(Nil, String) {
  case errors {
    [] -> Ok(Nil)
    errors -> {
      list.each(errors, fn(error) {
        sys.warn("crushling: stopping " <> key <> ": " <> error)
      })
      Error(string.join(errors, "; "))
    }
  }
}

/// Stop the thread's container, close its tunnel and revoke its proxy
/// token. Returns what failed; a container that doesn't exist is fine.
fn docker_cleanup(
  policy: sandbox.Policy,
  bridge: Bridge,
  key: String,
) -> List(String) {
  let errors = case sandbox.stop(policy, key) {
    Ok(Nil) -> []
    Error(sandbox.DockerFailed(output:, ..)) ->
      case string.contains(string.lowercase(output), "no such container") {
        True -> []
        False -> ["docker stop: " <> string.trim(output)]
      }
    Error(error) -> ["docker stop: " <> string.inspect(error)]
  }
  bridge.close(key)
  bridge.revoke(key)
  errors
}

/// `policy.crush_config` should come from `provider.config` with the
/// bridge's URL, and `policy.bridge_url` should be that URL.
///
/// A launch opens the tunnel, restores the proxy token, then starts the
/// container and waits for its crush to dial in. Any failure after the
/// tunnel opened undoes all of it: the container is stopped even when
/// `docker` reported a failure, since a timed-out CLI doesn't prove the
/// container didn't start.
pub fn docker(policy: sandbox.Policy, bridge: Bridge) -> Launcher {
  Launcher(
    launch: fn(key) {
      use shim <- result.try(
        bridge.open(key)
        |> result.map_error(fn(reason) { "tunnel: " <> reason }),
      )
      bridge.restore(key)
      let undo = fn(reason) {
        Error(undone(key, reason, docker_cleanup(policy, bridge, key)))
      }
      case sandbox.ensure(policy, key, bridge.env(key)) {
        Error(error) -> undo(string.inspect(error))
        // Wait here, rather than have the thread spend its reconnect
        // attempts on a shim with nothing behind it. A sandbox that never
        // dials in is stopped, or nothing would ever stop it.
        Ok(Nil) ->
          case bridge.await_hello(key, bridge.hello_timeout_ms) {
            Ok(_) -> Ok(Launched(socket: shim, root: sandbox.workspace))
            Error(reason) -> undo(reason)
          }
      }
    },
    stop: fn(key) {
      bridge.bye(key)
      stop_result(key, docker_cleanup(policy, bridge, key))
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
    run_in_sandbox: Some(fn(key, env, script) {
      sandbox.run_in(policy, key, env, script)
      |> result.map_error(string.inspect)
    }),
  )
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
fn alive(os_pid: Int) -> Bool

@external(erlang, "crushling_ffi", "file_exists")
fn file_exists(path: String) -> Bool

@external(erlang, "crushling_ffi", "mkdir_p")
fn mkdir_p(path: String) -> Result(Nil, String)

@external(erlang, "crushling_ffi", "write_private")
fn write_private(path: String, content: String) -> Result(Nil, String)

/// Run each thread's `crush server --dial` on this machine, under
/// `root/<key>`, the same way a sandbox runs it. `crush` is the binary, or
/// "" for the one on `PATH`. Each server's pid is kept in
/// `root/<key>/server.pid`, and it is stopped by that pid.
pub fn local(
  root: String,
  crush: String,
  models: provider.Models,
  bridge: Bridge,
) -> Launcher {
  let dir = fn(key) { root <> "/" <> key }
  let pid_file = fn(key) { dir(key) <> "/server.pid" }
  let cleanup = fn(key) {
    let errors = case stop_server(pid_file(key)) {
      Ok(Nil) -> []
      Error(reason) -> ["crush server: " <> reason]
    }
    bridge.close(key)
    bridge.revoke(key)
    errors
  }
  Launcher(
    launch: fn(key) {
      let base = dir(key)
      let work = base <> "/work"
      // A server left over from an earlier bridge would keep dialing; this
      // waits for it to exit.
      use _ <- result.try(
        stop_server(pid_file(key))
        |> result.map_error(fn(reason) {
          "an earlier crush server is still running: " <> reason
        }),
      )
      use shim <- result.try(
        bridge.open(key)
        |> result.map_error(fn(reason) { "tunnel: " <> reason }),
      )
      bridge.restore(key)
      let started = {
        use _ <- result.try(mkdir_p(work))
        use _ <- result.try(mkdir_p(base <> "/home/config"))
        use _ <- result.try(mkdir_p(base <> "/home/data"))
        use _ <- result.try(mkdir_p(base <> "/home/honcho"))
        use _ <- result.try(write_private(
          base <> "/home/data/crush.json",
          provider.config(models, bridge.url),
        ))
        let env = [
          "CRUSH_GLOBAL_CONFIG=" <> base <> "/home/config",
          "CRUSH_GLOBAL_DATA=" <> base <> "/home/data",
          // The same goes for the Honcho memory sign-in in ~/.honcho, which
          // would otherwise record every Slack conversation as yours.
          "HONCHO_CONFIG_DIR=" <> base <> "/home/honcho",
          "CRUSH_SERVER_IDLE_TIMEOUT=31536000",
          "CRUSH_SERVER_DETACH_GRACE=120",
          ..bridge.env(key)
        ]
        use os_pid <- result.try(start_server(
          crush,
          tunnel.dial_url(bridge.url, key),
          work,
          base <> "/server.log",
          env,
          pid_file(key),
        ))
        await_local_hello(bridge, key, os_pid, bridge.hello_timeout_ms)
      }
      case started {
        Ok(Nil) -> Ok(Launched(socket: shim, root: work))
        Error(reason) -> Error(undone(key, reason, cleanup(key)))
      }
    },
    stop: fn(key) {
      bridge.bye(key)
      stop_result(key, cleanup(key))
    },
    exists: fn(key) { file_exists(dir(key) <> "/work") },
    workspace: fn(key) { dir(key) <> "/work" },
    meta_path: fn(key) { dir(key) <> "/crushling.json" },
    attachments: fn(key) {
      #(dir(key) <> "/work/" <> attachments_dir, attachments_dir)
    },
    run_in_sandbox: None,
  )
}

/// Wait for the local crush to dial in, failing at once if it exits.
fn await_local_hello(
  bridge: Bridge,
  key: String,
  os_pid: Int,
  left_ms: Int,
) -> Result(Nil, String) {
  let slice = int.min(500, left_ms)
  case bridge.await_hello(key, slice) {
    Ok(_) -> Ok(Nil)
    Error(reason) ->
      case alive(os_pid), left_ms <= slice {
        False, _ -> Error("crush server exited while starting; see server.log")
        True, True -> Error(reason)
        True, False -> await_local_hello(bridge, key, os_pid, left_ms - slice)
      }
  }
}
