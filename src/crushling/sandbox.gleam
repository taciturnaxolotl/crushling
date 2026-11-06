//// One gVisor container per Slack thread, managed with the docker CLI the
//// way kloe does it on prattle, with three differences:
////
//// - the container runs `crush server` on a unix socket in a bind-mounted
////   directory, so the runtime must allow host sockets (`--host-uds=create`);
//// - it runs as the service's own uid, so the host can connect to that
////   socket and owns the workspace files;
//// - it joins a network whose egress is filtered on the host.
////
//// The argument building and the adopt/start/recreate decision are pure and
//// tested; `ensure`, `stop` and `remove` shell out to docker.

import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub type Policy {
  Policy(
    docker: String,
    image: String,
    /// A runtime registered with `--host-uds=create`, such as `runsc-uds`.
    runtime: String,
    network: String,
    cpus: String,
    memory: String,
    pids: Int,
    uid: Int,
    gid: Int,
    /// Host directory holding one directory per thread.
    root: String,
    /// `KEY=value` pairs passed into the container.
    env: List(String),
    /// The container's global crush.json, from `provider.config`.
    crush_config: String,
  )
}

pub const label = "crushling-sandbox"

pub const workspace = "/workspace"

pub const socket_dir = "/run/crushling"

const socket_name = "crush.sock"

const docker_timeout_ms = 60_000

/// A container and directory name for a thread, from the Slack channel and
/// thread timestamp. Only `[a-zA-Z0-9_.-]` survive, as in kloe.
pub fn key(channel: String, thread_ts: String) -> String {
  { channel <> "-" <> thread_ts }
  |> string.to_graphemes
  |> list.map(fn(g) {
    case is_safe(g) {
      True -> g
      False -> "_"
    }
  })
  |> string.concat
  |> string.slice(0, 64)
}

fn is_safe(grapheme: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-",
    grapheme,
  )
  && grapheme != ""
}

pub fn container_name(key: String) -> String {
  "crushling-" <> key
}

pub fn host_workspace(policy: Policy, key: String) -> String {
  policy.root <> "/" <> key <> "/work"
}

pub fn host_socket_dir(policy: Policy, key: String) -> String {
  policy.root <> "/" <> key <> "/sock"
}

/// The socket path the bridge connects to on the host.
pub fn host_socket(policy: Policy, key: String) -> String {
  host_socket_dir(policy, key) <> "/" <> socket_name
}

/// Everything that should force a rebuild when it changes. Stored on the
/// container as a label, as kloe does.
pub fn fingerprint(policy: Policy) -> String {
  [
    policy.image,
    policy.runtime,
    policy.network,
    policy.cpus,
    policy.memory,
    int.to_string(policy.pids),
    int.to_string(policy.uid),
    int.to_string(policy.gid),
    policy.root,
    policy.crush_config,
    ..policy.env
  ]
  |> string.join("\u{0}")
  |> sha256_hex
  |> string.slice(0, 16)
}

@external(erlang, "crushling_ffi", "sha256_hex")
fn sha256_hex(data: String) -> String

pub fn run_args(policy: Policy, key: String) -> List(String) {
  let env = list.flat_map(policy.env, fn(pair) { ["--env", pair] })
  list.flatten([
    ["run", "--detach", "--name", container_name(key)],
    ["--label", label <> "=1"],
    ["--label", label <> "-policy=" <> fingerprint(policy)],
    ["--runtime", policy.runtime, "--network", policy.network],
    ["--user", int.to_string(policy.uid) <> ":" <> int.to_string(policy.gid)],
    ["--cap-drop", "ALL", "--security-opt", "no-new-privileges"],
    ["--cpus", policy.cpus, "--memory", policy.memory],
    ["--pids-limit", int.to_string(policy.pids)],
    ["--workdir", workspace],
    ["--volume", host_workspace(policy, key) <> ":" <> workspace],
    ["--volume", host_socket_dir(policy, key) <> ":" <> socket_dir],
    ["--env", "HOME=" <> workspace <> "/.home"],
    ["--env", "XDG_DATA_HOME=" <> workspace <> "/.home/.local/share"],
    ["--env", "XDG_CACHE_HOME=" <> workspace <> "/.home/.cache"],
    ["--env", "HONCHO_CONFIG_DIR=" <> workspace <> "/.home/.honcho"],
    // The bridge owns the lifecycle; the server must not exit on its own
    // while a thread is quiet.
    ["--env", "CRUSH_SERVER_IDLE_TIMEOUT=31536000"],
    ["--env", "CRUSH_SERVER_DETACH_GRACE=120"],
    env,
    [policy.image, "crush", "server", "--host"],
    ["unix://" <> socket_dir <> "/" <> socket_name],
  ])
}

pub type Observed {
  Missing
  Present(running: Bool, fingerprint: String)
}

pub type Action {
  Adopt
  Start
  Recreate
  Create
}

/// What to do with whatever container already exists for a thread.
pub fn decide(observed: Observed, policy: Policy) -> Action {
  case observed {
    Missing -> Create
    Present(running:, fingerprint: seen) if seen != "" ->
      case seen == fingerprint(policy), running {
        True, True -> Adopt
        True, False -> Start
        False, _ -> Recreate
      }
    Present(..) -> Recreate
  }
}

/// Parse `docker inspect -f '{{.State.Running}} {{index .Config.Labels "…"}}'`.
pub fn parse_inspect(output: String) -> Observed {
  case string.split_once(string.trim(output), " ") {
    Ok(#("true", fingerprint)) -> Present(True, string.trim(fingerprint))
    Ok(#("false", fingerprint)) -> Present(False, string.trim(fingerprint))
    _ ->
      case string.trim(output) {
        "true" -> Present(True, "")
        "false" -> Present(False, "")
        _ -> Missing
      }
  }
}

@external(erlang, "crushling_ffi", "exec")
fn exec(
  program: String,
  args: List(String),
  timeout_ms: Int,
) -> Result(#(Int, String), String)

pub type Error {
  DockerFailed(args: List(String), status: Int, output: String)
  DockerUnavailable(reason: String)
  Filesystem(reason: String)
}

fn docker(policy: Policy, args: List(String)) -> Result(String, Error) {
  case exec(policy.docker, args, docker_timeout_ms) {
    Ok(#(0, output)) -> Ok(output)
    Ok(#(status, output)) -> Error(DockerFailed(args, status, output))
    Error(reason) -> Error(DockerUnavailable(reason))
  }
}

pub fn observe(policy: Policy, key: String) -> Result(Observed, Error) {
  let format =
    "{{.State.Running}} {{index .Config.Labels \"" <> label <> "-policy\"}}"
  case docker(policy, ["inspect", "--format", format, container_name(key)]) {
    Ok(output) -> Ok(parse_inspect(output))
    Error(DockerFailed(output:, ..)) ->
      case string.contains(string.lowercase(output), "no such") {
        True -> Ok(Missing)
        False -> Error(DockerFailed(["inspect"], 1, output))
      }
    Error(error) -> Error(error)
  }
}

/// Make sure the thread's container is running under the current policy and
/// return the host path of its socket.
///
/// `before_start` runs once the container's crush.json is written and
/// before crush starts, which is when a managed token has to be added: crush
/// only adopts newer tokens from disk for a provider that had one when it
/// loaded.
pub fn ensure(
  policy: Policy,
  key: String,
  before_start: fn() -> Result(Nil, String),
) -> Result(String, Error) {
  use _ <- result.try(prepare(policy, key))
  use _ <- result.try(before_start() |> result.map_error(Filesystem))
  use observed <- result.try(observe(policy, key))
  let name = container_name(key)
  use _ <- result.try(case decide(observed, policy) {
    Adopt -> Ok("")
    Start -> docker(policy, ["start", name])
    Recreate -> {
      use _ <- result.try(docker(policy, ["rm", "--force", name]))
      docker(policy, run_args(policy, key))
    }
    Create -> docker(policy, run_args(policy, key))
  })
  Ok(host_socket(policy, key))
}

/// Warm tier: stop the container but keep it, so installed state survives.
pub fn stop(policy: Policy, key: String) -> Result(Nil, Error) {
  docker(policy, ["stop", "--time", "2", container_name(key)])
  |> result.replace(Nil)
}

/// Cold tier: remove the container, keeping the workspace on disk.
pub fn remove(policy: Policy, key: String) -> Result(Nil, Error) {
  docker(policy, ["rm", "--force", container_name(key)])
  |> result.replace(Nil)
}

@external(erlang, "crushling_ffi", "mkdir_p")
fn mkdir_p(path: String) -> Result(Nil, String)

@external(erlang, "crushling_ffi", "write_private")
fn write_private(path: String, content: String) -> Result(Nil, String)

/// Where crush in the container keeps its global data, under the
/// `XDG_DATA_HOME` set in `run_args`.
pub fn host_crush_data(policy: Policy, key: String) -> String {
  host_workspace(policy, key) <> "/.home/.local/share/crush"
}

/// Create the thread's host directories as the bridge's own user. Left to
/// docker, missing mount sources are created owned by root, and the
/// container's uid could then not write its workspace or socket.
pub fn prepare(policy: Policy, key: String) -> Result(Nil, Error) {
  use _ <- result.try(
    mkdir_p(host_workspace(policy, key)) |> result.map_error(Filesystem),
  )
  use _ <- result.try(
    mkdir_p(host_socket_dir(policy, key)) |> result.map_error(Filesystem),
  )
  let data = host_crush_data(policy, key)
  use _ <- result.try(mkdir_p(data) |> result.map_error(Filesystem))
  write_private(data <> "/crush.json", policy.crush_config)
  |> result.map_error(Filesystem)
}

@external(erlang, "crushling_ffi", "file_exists")
pub fn socket_ready(path: String) -> Bool
