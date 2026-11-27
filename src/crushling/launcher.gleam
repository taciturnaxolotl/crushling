//// Launching and stopping a thread's agent, written once against a
//// `Backend` (`crushling/agent/backend`): docker or local.
////
//// Either way crush runs with `--dial`: it connects out to the bridge's
//// tunnel (`crushling/tunnel`), which the thread reaches through the
//// tunnel's unix socket shim, and it uses Hyper through the bridge's
//// inference proxy (`crushling/proxy`) with a token of the thread's own,
//// which works only while the agent is up. What crush is given comes from
//// `crushling/agent/spec`.
////
//// Nothing here serializes calls for one key: `crushling/agents` owns
//// that, and is the only caller in the bridge.

import crushling/agent/backend.{type Backend}
import crushling/agent/spec
import crushling/key as thread_key
import crushling/proxy
import crushling/sys
import crushling/tunnel
import gleam/int
import gleam/list
import gleam/option.{type Option}
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

/// A thread's agent, by key. Tests stand in for it with plain functions.
pub type Launcher {
  Launcher(
    launch: fn(String) -> Result(Launched, String),
    /// Stop the thread's agent but keep its workspace. An error says what
    /// couldn't be undone; the stop may be tried again.
    stop: fn(String) -> Result(Nil, String),
    /// Whether the thread has a workspace, so it was started before.
    exists: fn(String) -> Bool,
    /// Move a thread from an old key to a new one (`rekey(old, new)`):
    /// stop and remove whatever runs under the old key, and rename its
    /// directory. The next launch starts it afresh under the new key.
    rekey: fn(String, String) -> Result(Nil, String),
    /// Remove a stopped thread's sandbox and workspace for good. Its row
    /// in the store stays, so the thread can start again, from nothing.
    forget: fn(String) -> Result(Nil, String),
    /// Run a script in a thread's sandbox, with extra `NAME=value` pairs.
    /// The local launcher has no sandbox.
    run_in_sandbox: Option(
      fn(String, List(String), String) -> Result(String, String),
    ),
  )
}

/// What a launch needs from the rest of the bridge.
pub type Wiring {
  Wiring(
    tunnels: tunnel.Tunnels,
    proxy: proxy.Proxy,
    /// What every thread's crush is given.
    spec: spec.Settings,
    /// How long a launch waits for crush to dial in.
    hello_timeout_ms: Int,
  )
}

/// How long a launch waits for crush to dial in, by default. gVisor and
/// crush take a few seconds to boot.
pub const default_hello_timeout_ms = 30_000

/// Attachments live in the workspace, so the agent can open them, under a
/// directory the change snapshots leave out.
pub const attachments_dir = ".slack"

/// A launch prepares the thread's directories, opens its tunnel, lets its
/// proxy token work, then starts (or adopts) its crush and waits for it to
/// dial in. Any failure after the tunnel opened undoes all of it: crush is
/// stopped even when starting it reported a failure, since a timed-out
/// call doesn't prove it didn't start. A stop says bye and undoes the same.
pub fn new(wiring: Wiring, backend: Backend) -> Launcher {
  Launcher(
    launch: fn(key) { launch(wiring, backend, key) },
    stop: fn(key) {
      tunnel.bye(wiring.tunnels, key)
      stop_result(key, cleanup(wiring, backend, key))
    },
    exists: backend.exists,
    rekey: fn(old, new) {
      // Its tokens came from the old key, so whatever ran under it can't
      // be reused; remove it rather than leave it running unseen.
      use _ <- result.try(backend.remove(old))
      move_dir(backend.root, old, new)
    },
    forget: fn(key) {
      use _ <- result.try(backend.remove(key))
      delete_thread_dir(backend.root, key)
    },
    run_in_sandbox: backend.exec,
  )
}

fn launch(
  wiring: Wiring,
  backend: Backend,
  key: String,
) -> Result(Launched, String) {
  let spec = spec.build(wiring.spec, backend.root, key, backend.home)
  use _ <- result.try(backend.prepare(spec))
  use shim <- result.try(
    tunnel.open(wiring.tunnels, key)
    |> result.map_error(fn(reason) { "tunnel: " <> reason }),
  )
  proxy.allow(wiring.proxy, key)
  let started = {
    use _ <- result.try(backend.start(spec))
    // Wait here, rather than have the thread spend its reconnect attempts
    // on a shim with nothing behind it.
    await_hello(wiring, backend, key, wiring.hello_timeout_ms)
  }
  case started {
    Ok(Nil) -> Ok(Launched(socket: shim, root: spec.workdir))
    Error(reason) -> Error(undone(key, reason, cleanup(wiring, backend, key)))
  }
}

/// Wait for crush to dial in, failing at once if it is no longer alive.
fn await_hello(
  wiring: Wiring,
  backend: Backend,
  key: String,
  left_ms: Int,
) -> Result(Nil, String) {
  let slice = int.min(500, left_ms)
  case tunnel.await_hello(wiring.tunnels, key, slice) {
    Ok(_) -> Ok(Nil)
    Error(reason) ->
      case
        string.starts_with(reason, "crush did not dial in"),
        backend.alive(key),
        left_ms <= slice
      {
        // The tunnel closed or went: waiting longer won't help.
        False, _, _ -> Error(reason)
        True, False, _ ->
          Error("crush server exited while starting; see server.log")
        True, True, True ->
          Error(
            "crush did not dial in within "
            <> int.to_string(wiring.hello_timeout_ms)
            <> "ms",
          )
        True, True, False -> await_hello(wiring, backend, key, left_ms - slice)
      }
  }
}

/// Stop crush, close the tunnel and disallow the proxy token. Returns what
/// failed; nothing running is fine.
fn cleanup(wiring: Wiring, backend: Backend, key: String) -> List(String) {
  let errors = case backend.stop(key) {
    Ok(Nil) -> []
    Error(reason) -> [reason]
  }
  tunnel.close(wiring.tunnels, key)
  proxy.disallow(wiring.proxy, key)
  errors
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

@external(erlang, "crushling_store_ffi", "dir_exists")
fn dir_exists(path: String) -> Bool

@external(erlang, "crushling_store_ffi", "rename")
fn rename(from: String, to: String) -> Result(Nil, String)

@external(erlang, "crushling_ffi", "delete_tree")
fn delete_tree(path: String) -> Result(Nil, String)

/// Delete `<root>/<key>`, for a key that can only name a thread's own
/// directory.
fn delete_thread_dir(root: String, key: String) -> Result(Nil, String) {
  case thread_key.is_valid(key) {
    False -> Error("not a thread key: " <> key)
    True ->
      delete_tree(root <> "/" <> key)
      |> result.map_error(fn(reason) { "deleting the workspace: " <> reason })
  }
}

/// Rename `root/old` to `root/new`, unless there's nothing to move or the
/// new one already exists.
pub fn move_dir(root: String, old: String, new: String) -> Result(Nil, String) {
  let from = root <> "/" <> old
  let to = root <> "/" <> new
  case dir_exists(from), dir_exists(to) {
    True, False ->
      rename(from, to)
      |> result.map_error(fn(reason) { "renaming " <> from <> ": " <> reason })
    True, True -> Error(to <> " already exists")
    False, _ -> Ok(Nil)
  }
}
