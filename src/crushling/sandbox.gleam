//// One gVisor container per Slack thread, managed with the docker CLI the
//// way kloe does it on prattle, with three differences:
////
//// - the container runs `crush server --dial`, which connects out to the
////   bridge's tunnel (`crushling/tunnel`) instead of listening, so nothing
////   is mounted for it and plain `runsc` will do;
//// - it runs as the service's own uid, so the host owns the workspace
////   files;
//// - it joins a network whose egress is filtered on the host, which lets
////   it reach the bridge's one sandbox port.
////
//// The argument building and the adopt/start/recreate decision are pure and
//// tested; `ensure`, `stop` and `remove` shell out to docker.

import crushling/tunnel
import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub type Policy {
  Policy(
    docker: String,
    image: String,
    /// The gVisor runtime, such as `runsc`.
    runtime: String,
    network: String,
    cpus: String,
    memory: String,
    pids: Int,
    uid: Int,
    gid: Int,
    /// Host directory holding one directory per thread.
    root: String,
    /// `KEY=value` pairs passed into every container.
    env: List(String),
    /// The workspace whose sandboxes also get `own_env` (the self-host one,
    /// from `SLACK_BOT_TOKEN`), or "" for none.
    own_team: String,
    /// `KEY=value` pairs only for that workspace's sandboxes, such as the
    /// operator's own Honcho memory settings.
    own_env: List(String),
    /// The container's global crush.json, from `provider.config`.
    crush_config: String,
    /// A static `crush` binary on the host to mount into the container, or
    /// "" to use the image's own.
    crush: String,
    /// Nameservers for the container's own resolv.conf, or [] for docker's.
    /// Docker's embedded DNS doesn't answer gVisor on a custom network.
    dns: List(String),
    /// How the container reaches the bridge's sandbox server, e.g.
    /// `http://172.30.0.1:7469`; crush dials its tunnel there.
    bridge_url: String,
  )
}

/// Where a mounted `crush` binary appears in the container.
pub const mounted_crush = "/opt/crushling/crush"

pub const label = "crushling-sandbox"

pub const workspace = "/workspace"

const docker_timeout_ms = 60_000

/// What a thread's container gets beyond `policy.env`: `own_env`, when the
/// thread is in `own_team`.
pub fn team_env(policy: Policy, key: String) -> List(String) {
  case team_of(key) {
    Ok(team) if team == policy.own_team && team != "" -> policy.own_env
    _ -> []
  }
}

/// A container and directory name for a thread, from the Slack workspace,
/// channel and thread timestamp: `T…-C…-<ts>`. Only `[a-zA-Z0-9_.-]`
/// survive, as in kloe, and it is at most 64 characters (Slack's ids are
/// about 11, so a real key is about 40).
pub fn key(team: String, channel: String, thread_ts: String) -> String {
  safe(team <> "-" <> channel <> "-" <> thread_ts)
}

/// The key a thread had before keys carried the workspace: `C…-<ts>`. Only
/// for moving such threads to their new key.
pub fn legacy_key(channel: String, thread_ts: String) -> String {
  safe(channel <> "-" <> thread_ts)
}

/// The workspace in a key made by `key`: everything before the first `-`,
/// when that is a workspace (`T…`) or organization (`E…`) id. A key from
/// before keys carried the workspace (`C…-<ts>`) has none.
pub fn team_of(key: String) -> Result(String, Nil) {
  case string.split_once(key, "-") {
    Ok(#("T" <> _ as team, _))
      | Ok(#("E" <> _ as team, _))
      if team != "T" && team != "E"
    -> Ok(team)
    _ -> Error(Nil)
  }
}

fn safe(name: String) -> String {
  name
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

/// Everything that should force a rebuild when it changes. Stored on the
/// container as a label, as kloe does.
pub fn fingerprint(policy: Policy) -> String {
  [
    // How crush is reached. Containers from before the tunnel listened on
    // a socket, and must be recreated with the new command.
    "dial",
    policy.bridge_url,
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
    // A new binary at the same path still means new containers.
    crush_stamp(policy.crush),
    string.join(policy.dns, ","),
    policy.own_team,
    string.join(policy.own_env, "\u{0}"),
    ..policy.env
  ]
  |> string.join("\u{0}")
  |> sha256_hex
  |> string.slice(0, 16)
}

fn crush_stamp(path: String) -> String {
  case path {
    "" -> ""
    path -> path <> "@" <> result.unwrap(file_stamp(path), "missing")
  }
}

@external(erlang, "crushling_ffi", "file_stamp")
fn file_stamp(path: String) -> Result(String, Nil)

@external(erlang, "crushling_ffi", "sha256_hex")
fn sha256_hex(data: String) -> String

/// `key_env` is the thread's own environment: its tokens for the Slack
/// tools, the tunnel and the proxy. They are derived from the key, so they
/// needn't be part of the fingerprint.
pub fn run_args(
  policy: Policy,
  key: String,
  key_env: List(String),
) -> List(String) {
  let env =
    list.flatten([policy.env, team_env(policy, key), key_env])
    |> list.flat_map(fn(pair) { ["--env", pair] })
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
    ["--env", "HOME=" <> workspace <> "/.home"],
    ["--env", "XDG_DATA_HOME=" <> workspace <> "/.home/.local/share"],
    ["--env", "XDG_CACHE_HOME=" <> workspace <> "/.home/.cache"],
    ["--env", "HONCHO_CONFIG_DIR=" <> workspace <> "/.home/.honcho"],
    // The bridge owns the lifecycle; the server must not exit on its own
    // while a thread is quiet.
    ["--env", "CRUSH_SERVER_IDLE_TIMEOUT=31536000"],
    ["--env", "CRUSH_SERVER_DETACH_GRACE=120"],
    env,
    case policy.dns {
      [] -> []
      _ -> ["--volume", host_resolv_conf(policy) <> ":/etc/resolv.conf:ro"]
    },
    case policy.crush {
      "" -> [policy.image, "crush"]
      path -> [
        "--volume",
        path <> ":" <> mounted_crush <> ":ro",
        policy.image,
        mounted_crush,
      ]
    },
    ["server", "--dial", tunnel.dial_url(policy.bridge_url, key)],
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

/// Remove sandbox images nothing will run again. Old images are what fill
/// the disk: containers are only kilobytes over theirs. First the stopped
/// sandbox containers on an image other than `policy.image`: their next
/// launch recreates them anyway (the image is in their fingerprint), and
/// their workspaces are kept. Then the repository's tags that are neither
/// the image in use nor run by any container left. Returns the images
/// removed.
pub fn prune_images(policy: Policy) -> Result(List(String), Error) {
  use stopped <- result.try(
    docker(policy, [
      "ps",
      "--all",
      "--filter",
      "label=" <> label <> "=1",
      "--filter",
      "status=exited",
      "--format",
      "{{.Names}} {{.Image}}",
    ]),
  )
  string.split(stopped, "\n")
  |> list.each(fn(line) {
    case string.split(string.trim(line), " ") {
      [name, image] if image != policy.image -> {
        let _ = docker(policy, ["rm", name])
        Nil
      }
      _ -> Nil
    }
  })
  let repository = case string.split_once(policy.image, ":") {
    Ok(#(repository, _)) -> repository
    Error(Nil) -> policy.image
  }
  use tags <- result.try(
    docker(policy, [
      "image", "ls", repository, "--format", "{{.Repository}}:{{.Tag}}",
    ]),
  )
  use used <- result.try(
    docker(policy, ["ps", "--all", "--format", "{{.Image}}"]),
  )
  let used = string.split(used, "\n") |> list.map(string.trim)
  let stale = unused_images(string.split(tags, "\n"), used, policy.image)
  list.filter(stale, fn(image) {
    case docker(policy, ["image", "rm", image]) {
      Ok(_) -> True
      Error(_) -> False
    }
  })
  |> Ok
}

/// Of `tags`, those that aren't `current` and that no container in `used`
/// runs.
pub fn unused_images(
  tags: List(String),
  used: List(String),
  current: String,
) -> List(String) {
  tags
  |> list.map(string.trim)
  |> list.filter(fn(tag) {
    tag != ""
    && tag != current
    && !string.ends_with(tag, ":<none>")
    && !list.contains(used, tag)
  })
}

fn docker(policy: Policy, args: List(String)) -> Result(String, Error) {
  case exec(policy.docker, args, docker_timeout_ms) {
    Ok(#(0, output)) -> Ok(output)
    Ok(#(status, output)) ->
      Error(DockerFailed(redact(args), status, redact_output(args, output)))
    Error(reason) -> Error(DockerUnavailable(reason))
  }
}

/// `output` with every `--env` value from `args` hidden, so a docker that
/// echoes its arguments back can't leak a token either. Values shorter
/// than 4 bytes (`1`, `on`) are left alone: hiding them would hide most of
/// the output and they are never secrets.
pub fn redact_output(args: List(String), output: String) -> String {
  env_values(args)
  |> list.filter(fn(value) { string.byte_size(value) >= 4 })
  // Longest first, so a value containing another is hidden whole.
  |> list.sort(fn(a, b) {
    int.compare(string.byte_size(b), string.byte_size(a))
  })
  |> list.fold(output, fn(output, value) {
    string.replace(output, value, "<redacted>")
  })
}

fn env_values(args: List(String)) -> List(String) {
  case args {
    ["--env", pair, ..rest] ->
      case string.split_once(pair, "=") {
        Ok(#(_, value)) -> [value, ..env_values(rest)]
        Error(Nil) -> env_values(rest)
      }
    [_, ..rest] -> env_values(rest)
    [] -> []
  }
}

/// The arguments with every `--env NAME=value` value hidden, so an error
/// that is logged or posted in Slack carries no token.
pub fn redact(args: List(String)) -> List(String) {
  case args {
    ["--env", pair, ..rest] -> {
      let name = case string.split_once(pair, "=") {
        Ok(#(name, _)) -> name
        Error(Nil) -> pair
      }
      ["--env", name <> "=<redacted>", ..redact(rest)]
    }
    [arg, ..rest] -> [arg, ..redact(rest)]
    [] -> []
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

/// Make sure the thread's container is running under the current policy.
/// Its crush then dials the bridge; waiting for that is the launcher's job.
pub fn ensure(
  policy: Policy,
  key: String,
  key_env: List(String),
) -> Result(Nil, Error) {
  use _ <- result.try(prepare(policy, key))
  use observed <- result.try(observe(policy, key))
  let name = container_name(key)
  case decide(observed, policy) {
    Adopt -> Ok("")
    Start -> docker(policy, ["start", name])
    Recreate -> {
      use _ <- result.try(docker(policy, ["rm", "--force", name]))
      docker(policy, run_args(policy, key, key_env))
    }
    Create -> docker(policy, run_args(policy, key, key_env))
  }
  |> result.replace(Nil)
}

/// Warm tier: stop the container but keep it, so installed state survives.
pub fn stop(policy: Policy, key: String) -> Result(Nil, Error) {
  docker(policy, ["stop", "--time", "2", container_name(key)])
  |> result.replace(Nil)
}

/// The arguments to run `script` with `sh` in a thread's running container,
/// as its own user, with `env` (`NAME=value` pairs) added.
pub fn exec_args(
  key: String,
  env: List(String),
  script: String,
) -> List(String) {
  list.flatten([
    ["exec"],
    list.flat_map(env, fn(pair) { ["--env", pair] }),
    [container_name(key), "sh", "-c", script],
  ])
}

/// Run `script` in a thread's running container and return its output.
pub fn run_in(
  policy: Policy,
  key: String,
  env: List(String),
  script: String,
) -> Result(String, Error) {
  docker(policy, exec_args(key, env, script))
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

/// The resolv.conf every container shares, beside the threads.
pub fn host_resolv_conf(policy: Policy) -> String {
  policy.root <> "/resolv.conf"
}

/// Create the thread's host directories as the bridge's own user. Left to
/// docker, missing mount sources are created owned by root, and the
/// container's uid could then not write its workspace.
pub fn prepare(policy: Policy, key: String) -> Result(Nil, Error) {
  use _ <- result.try(
    mkdir_p(host_workspace(policy, key)) |> result.map_error(Filesystem),
  )
  let data = host_crush_data(policy, key)
  use _ <- result.try(mkdir_p(data) |> result.map_error(Filesystem))
  use _ <- result.try(case policy.dns {
    [] -> Ok(Nil)
    servers ->
      list.map(servers, fn(server) { "nameserver " <> server <> "\n" })
      |> string.concat
      |> write_private(host_resolv_conf(policy), _)
      |> result.map_error(Filesystem)
  })
  write_private(data <> "/crush.json", policy.crush_config)
  |> result.map_error(Filesystem)
}
