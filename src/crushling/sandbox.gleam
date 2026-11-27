//// One gVisor container per Slack thread, driven through the Docker Engine
//// API on its unix socket, with three differences from kloe on prattle:
////
//// - the container runs `crush server --dial`, which connects out to the
////   bridge's tunnel (`crushling/tunnel`) instead of listening, so nothing
////   is mounted for it and plain `runsc` will do;
//// - it runs as the service's own uid, so the host owns the workspace
////   files;
//// - it joins a network whose egress is filtered on the host, which lets
////   it reach the bridge's one sandbox port.
////
//// The create body, the policy fingerprint and the adopt/start/recreate
//// decision are pure and tested; the rest are Engine API calls. Secrets
//// travel in request bodies, never in arguments or error text.

import crushling/agent/spec.{type Spec}
import crushling/gun
import crushling/sys
import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/float
import gleam/http
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

pub type Policy {
  Policy(
    /// The Docker Engine's unix socket, such as `/var/run/docker.sock`.
    socket: String,
    image: String,
    /// The gVisor runtime, such as `runsc`.
    runtime: String,
    network: String,
    /// As `docker run --cpus` takes them, such as `2` or `1.5`.
    cpus: String,
    /// As `docker run --memory` takes it, such as `4g`.
    memory: String,
    pids: Int,
    uid: Int,
    gid: Int,
    /// Host directory holding one directory per thread.
    root: String,
    /// A static `crush` binary on the host to mount into the container, or
    /// "" to use the image's own.
    crush: String,
    /// Nameservers for the container's own resolv.conf, or [] for docker's.
    /// Docker's embedded DNS doesn't answer gVisor on a custom network.
    dns: List(String),
    /// What every thread's crush is given.
    spec: spec.Settings,
  )
}

/// Where a mounted `crush` binary appears in the container.
pub const mounted_crush = "/opt/crushling/crush"

pub const label = "crushling-sandbox"

pub const workspace = spec.workspace

/// The engine's socket when nothing says otherwise.
pub const default_socket = "/var/run/docker.sock"

const timeout_ms = 60_000

pub fn container_name(key: String) -> String {
  "crushling-" <> key
}

pub fn host_workspace(policy: Policy, key: String) -> String {
  policy.root <> "/" <> key <> "/work"
}

/// Everything that should force a rebuild when it changes. Stored on the
/// container as a label, as kloe does.
pub fn fingerprint(policy: Policy) -> String {
  let settings = policy.spec
  [
    // How crush is reached. Containers from before the tunnel listened on
    // a socket, and must be recreated with the new command.
    "dial",
    settings.bridge_url,
    policy.image,
    policy.runtime,
    policy.network,
    policy.cpus,
    policy.memory,
    int.to_string(policy.pids),
    int.to_string(policy.uid),
    int.to_string(policy.gid),
    policy.root,
    spec.crush_config(settings),
    // A new binary at the same path still means new containers.
    crush_stamp(policy.crush),
    string.join(policy.dns, ","),
    settings.own_team,
    string.join(settings.own_env, "\u{0}"),
    ..settings.env
  ]
  |> string.join("\u{0}")
  |> sys.sha256_hex
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

pub type Error {
  /// The engine answered `status` with `message`.
  Engine(status: Int, message: String)
  /// The engine's socket couldn't be reached, or didn't answer in time.
  Unreachable(reason: String)
  Filesystem(reason: String)
  /// The policy can't be expressed to the engine.
  BadPolicy(reason: String)
  /// A script run in the container exited with `status`.
  Exited(status: Int, output: String)
}

pub fn describe(error: Error) -> String {
  case error {
    Engine(status:, message:) ->
      "docker: " <> message <> " (" <> int.to_string(status) <> ")"
    Unreachable(reason) -> "docker is unreachable: " <> reason
    Filesystem(reason) -> reason
    BadPolicy(reason) -> "sandbox policy: " <> reason
    Exited(status:, output:) ->
      "exit status " <> int.to_string(status) <> ": " <> string.trim(output)
  }
}

/// Check what `create_body` needs from the policy, so a bad setting stops
/// the bridge at start rather than every launch.
pub fn check(policy: Policy) -> Result(Nil, Error) {
  use _ <- result.try(nano_cpus(policy.cpus))
  memory_bytes(policy.memory) |> result.replace(Nil)
}

/// The body of `POST /containers/create` for a thread's container.
pub fn create_body(policy: Policy, spec: Spec) -> Result(Json, Error) {
  use cpus <- result.try(nano_cpus(policy.cpus))
  use memory <- result.map(memory_bytes(policy.memory))
  let binds =
    list.flatten([
      [spec.host_work <> ":" <> workspace],
      case policy.dns {
        [] -> []
        _ -> [host_resolv_conf(policy) <> ":/etc/resolv.conf:ro"]
      },
      case policy.crush {
        "" -> []
        path -> [path <> ":" <> mounted_crush <> ":ro"]
      },
    ])
  let crush = case policy.crush {
    "" -> "crush"
    _ -> mounted_crush
  }
  json.object([
    #("Image", json.string(policy.image)),
    #(
      "Cmd",
      json.array([crush, "server", "--dial", spec.dial_url], json.string),
    ),
    #(
      "User",
      json.string(int.to_string(policy.uid) <> ":" <> int.to_string(policy.gid)),
    ),
    #("WorkingDir", json.string(spec.workdir)),
    #("Env", json.array(spec.env, json.string)),
    #(
      "Labels",
      json.object([
        #(label, json.string("1")),
        #(label <> "-policy", json.string(fingerprint(policy))),
      ]),
    ),
    #(
      "HostConfig",
      json.object([
        #("Runtime", json.string(policy.runtime)),
        #("NetworkMode", json.string(policy.network)),
        #("CapDrop", json.array(["ALL"], json.string)),
        #("SecurityOpt", json.array(["no-new-privileges"], json.string)),
        #("NanoCpus", json.int(cpus)),
        #("Memory", json.int(memory)),
        #("PidsLimit", json.int(policy.pids)),
        #("Binds", json.array(binds, json.string)),
      ]),
    ),
  ])
}

/// `--cpus` as the engine's billionths of a CPU.
pub fn nano_cpus(cpus: String) -> Result(Int, Error) {
  case number(string.trim(cpus)) {
    Ok(n) if n >. 0.0 -> Ok(float.round(n *. 1.0e9))
    _ -> Error(BadPolicy("cpus must be a positive number, not " <> cpus))
  }
}

/// `--memory` in bytes: a number with an optional `b`, `k`, `m`, `g` or `t`
/// suffix (binary multiples, as docker reads them).
pub fn memory_bytes(memory: String) -> Result(Int, Error) {
  let text = string.lowercase(string.trim(memory))
  let text = case string.ends_with(text, "b") && string.length(text) > 1 {
    True -> string.drop_end(text, 1)
    False -> text
  }
  let #(digits, scale) = case string.last(text) {
    Ok("k") -> #(string.drop_end(text, 1), 1024)
    Ok("m") -> #(string.drop_end(text, 1), 1_048_576)
    Ok("g") -> #(string.drop_end(text, 1), 1_073_741_824)
    Ok("t") -> #(string.drop_end(text, 1), 1_099_511_627_776)
    _ -> #(text, 1)
  }
  case number(digits) {
    Ok(n) if n >. 0.0 -> Ok(float.truncate(n *. int.to_float(scale)))
    _ -> Error(BadPolicy("memory must be a size such as 4g, not " <> memory))
  }
}

fn number(text: String) -> Result(Float, Nil) {
  case int.parse(text) {
    Ok(whole) -> Ok(int.to_float(whole))
    Error(Nil) -> float.parse(text)
  }
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

/// Parse the body of `GET /containers/<name>/json`.
pub fn parse_inspect(body: String) -> Observed {
  let decoder = {
    use running <- decode.subfield(["State", "Running"], decode.bool)
    use labels <- decode.subfield(
      ["Config", "Labels"],
      decode.optional(decode.dict(decode.string, decode.string)),
    )
    let seen =
      option.unwrap(labels, dict.new())
      |> dict.get(label <> "-policy")
      |> result.unwrap("")
    decode.success(Present(running, seen))
  }
  json.parse(body, decoder) |> result.unwrap(Missing)
}

// The engine ------------------------------------------------------------------

type Reply {
  Reply(status: Int, body: String)
}

fn call(
  policy: Policy,
  method: http.Method,
  path: String,
  body: Option(Json),
) -> Result(#(Int, BitArray), Error) {
  use conn <- result.try(
    gun.connect_unix(policy.socket, 5000) |> result.map_error(Unreachable),
  )
  let #(headers, payload) = case body {
    Some(body) -> #(
      [#("content-type", "application/json")],
      bit_array.from_string(json.to_string(body)),
    )
    None -> #([], <<>>)
  }
  let answer = gun.request(conn, method, path, headers, payload, timeout_ms)
  gun.close(conn)
  case answer {
    Ok(response) -> Ok(#(response.status, response.body))
    Error(reason) -> Error(Unreachable(reason))
  }
}

/// Succeed with the body on any status in `ok`, else the engine's error.
fn expect(
  answer: Result(#(Int, BitArray), Error),
  ok: List(Int),
) -> Result(Reply, Error) {
  use #(status, body) <- result.try(answer)
  let reply = Reply(status, bit_array.to_string(body) |> result.unwrap(""))
  case list.contains(ok, status) {
    True -> Ok(reply)
    False -> Error(engine_error(reply))
  }
}

/// The engine's error from a failed answer's `{"message": ...}`.
fn engine_error(reply: Reply) -> Error {
  let message =
    json.parse(reply.body, decode.at(["message"], decode.string))
    |> result.unwrap(string.trim(reply.body))
  Engine(reply.status, message)
}

fn container(key: String) -> String {
  "/containers/" <> container_name(key)
}

pub fn observe(policy: Policy, key: String) -> Result(Observed, Error) {
  use reply <- result.try(
    call(policy, http.Get, container(key) <> "/json", None)
    |> expect([200, 404]),
  )
  case reply.status {
    404 -> Ok(Missing)
    _ -> Ok(parse_inspect(reply.body))
  }
}

fn create(policy: Policy, spec: Spec) -> Result(Nil, Error) {
  use body <- result.try(create_body(policy, spec))
  call(
    policy,
    http.Post,
    "/containers/create?name=" <> container_name(spec.key),
    Some(body),
  )
  |> expect([201])
  |> result.replace(Nil)
}

fn start(policy: Policy, key: String) -> Result(Nil, Error) {
  // 304: already running.
  call(policy, http.Post, container(key) <> "/start", None)
  |> expect([204, 304])
  |> result.replace(Nil)
}

/// Make sure the thread's container is running under the current policy.
/// Its crush then dials the bridge; waiting for that is the launcher's job.
pub fn ensure(policy: Policy, spec: Spec) -> Result(Nil, Error) {
  use observed <- result.try(observe(policy, spec.key))
  case decide(observed, policy) {
    Adopt -> Ok(Nil)
    Start -> start(policy, spec.key)
    Recreate -> {
      use _ <- result.try(remove(policy, spec.key))
      use _ <- result.try(create(policy, spec))
      start(policy, spec.key)
    }
    Create -> {
      use _ <- result.try(create(policy, spec))
      start(policy, spec.key)
    }
  }
}

/// Warm tier: stop the container but keep it, so installed state survives.
/// One that is already stopped or doesn't exist is fine.
pub fn stop(policy: Policy, key: String) -> Result(Nil, Error) {
  call(policy, http.Post, container(key) <> "/stop?t=2", None)
  |> expect([204, 304, 404])
  |> result.replace(Nil)
}

/// Cold tier: remove the container, keeping the workspace on disk. One that
/// doesn't exist is fine.
pub fn remove(policy: Policy, key: String) -> Result(Nil, Error) {
  call(policy, http.Delete, container(key) <> "?force=true", None)
  |> expect([204, 404])
  |> result.replace(Nil)
}

/// The body of `POST /containers/<name>/exec`: `script` with `sh`, as the
/// container's own user, with `env` (`NAME=value` pairs) added.
pub fn exec_body(env: List(String), script: String) -> Json {
  json.object([
    #("AttachStdout", json.bool(True)),
    #("AttachStderr", json.bool(True)),
    #("Env", json.array(env, json.string)),
    #("Cmd", json.array(["sh", "-c", script], json.string)),
  ])
}

/// Run `script` in a thread's running container and return its output,
/// stdout and stderr together. A non-zero exit is an error with the output.
pub fn run_in(
  policy: Policy,
  key: String,
  env: List(String),
  script: String,
) -> Result(String, Error) {
  use created <- result.try(
    call(
      policy,
      http.Post,
      container(key) <> "/exec",
      Some(exec_body(env, script)),
    )
    |> expect([201]),
  )
  use id <- result.try(
    json.parse(created.body, decode.at(["Id"], decode.string))
    |> result.replace_error(Engine(201, "no exec id in the answer")),
  )
  let detached = json.object([#("Detach", json.bool(False))])
  use stream <- result.try(call(
    policy,
    http.Post,
    "/exec/" <> id <> "/start",
    Some(detached),
  ))
  use _ <- result.try(case stream.0 {
    200 | 101 -> Ok(Nil)
    status ->
      Error(
        engine_error(Reply(
          status,
          bit_array.to_string(stream.1) |> result.unwrap(""),
        )),
      )
  })
  let output = demux(stream.1, <<>>) |> bit_array.to_string |> result.unwrap("")
  use inspected <- result.try(
    call(policy, http.Get, "/exec/" <> id <> "/json", None) |> expect([200]),
  )
  case json.parse(inspected.body, decode.at(["ExitCode"], decode.int)) {
    Ok(0) -> Ok(output)
    Ok(status) -> Error(Exited(status, output))
    Error(_) -> Error(Exited(-1, output))
  }
}

/// The payloads of a multiplexed stdout and stderr stream, in order: each
/// frame is a stream byte, three zero bytes, a 32-bit length and the data.
pub fn demux(stream: BitArray, acc: BitArray) -> BitArray {
  case stream {
    <<kind, 0, 0, 0, size:32, rest:bits>> if kind <= 2 ->
      case rest {
        <<payload:bytes-size(size), more:bits>> ->
          demux(more, bit_array.append(acc, payload))
        _ -> bit_array.append(acc, rest)
      }
    // Not multiplexed after all (a TTY): take it as it is.
    rest -> bit_array.append(acc, rest)
  }
}

/// A container in a list, by name, with its image and whether it runs.
type Listed {
  Listed(name: String, image: String, running: Bool)
}

fn filters(pairs: List(#(String, List(String)))) -> String {
  json.object(
    list.map(pairs, fn(pair) { #(pair.0, json.array(pair.1, json.string)) }),
  )
  |> json.to_string
  |> uri.percent_encode
}

fn list_containers(
  policy: Policy,
  by: List(#(String, List(String))),
) -> Result(List(Listed), Error) {
  use reply <- result.try(
    call(
      policy,
      http.Get,
      "/containers/json?all=true&filters=" <> filters(by),
      None,
    )
    |> expect([200]),
  )
  let item = {
    use names <- decode.field("Names", decode.list(decode.string))
    use image <- decode.field("Image", decode.string)
    use state <- decode.optional_field("State", "", decode.string)
    let name = case names {
      ["/" <> name, ..] | [name, ..] -> name
      [] -> ""
    }
    decode.success(Listed(name, image, state == "running"))
  }
  json.parse(reply.body, decode.list(item))
  |> result.replace_error(Engine(200, "unreadable container list"))
}

/// The keys of every sandbox container still running.
pub fn running(policy: Policy) -> Result(List(String), Error) {
  use listed <- result.map(
    list_containers(policy, [#("label", [label <> "=1"])]),
  )
  list.filter_map(listed, fn(container) {
    case container.running, container.name {
      True, "crushling-" <> key -> Ok(key)
      _, _ -> Error(Nil)
    }
  })
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
    list_containers(policy, [
      #("label", [label <> "=1"]),
      #("status", ["exited"]),
    ]),
  )
  list.each(stopped, fn(container) {
    case container.image != policy.image {
      True -> {
        let _ =
          call(policy, http.Delete, "/containers/" <> container.name, None)
        Nil
      }
      False -> Nil
    }
  })
  let repository = case string.split_once(policy.image, ":") {
    Ok(#(repository, _)) -> repository
    Error(Nil) -> policy.image
  }
  use images <- result.try(
    call(
      policy,
      http.Get,
      "/images/json?filters=" <> filters([#("reference", [repository])]),
      None,
    )
    |> expect([200]),
  )
  let repo_tags = {
    use tags <- decode.optional_field(
      "RepoTags",
      [],
      decode.optional(decode.list(decode.string))
        |> decode.map(option.unwrap(_, [])),
    )
    decode.success(tags)
  }
  let tags =
    json.parse(images.body, decode.list(repo_tags))
    |> result.unwrap([])
    |> list.flatten
  use used <- result.try(list_containers(policy, []))
  let used = list.map(used, fn(container) { container.image })
  unused_images(tags, used, policy.image)
  |> list.filter(fn(image) {
    call(policy, http.Delete, "/images/" <> uri.percent_encode(image), None)
    |> expect([200])
    |> result.is_ok
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

/// The resolv.conf every container shares, beside the threads.
pub fn host_resolv_conf(policy: Policy) -> String {
  policy.root <> "/resolv.conf"
}

/// Create the thread's host directories and files as the bridge's own
/// user. Left to docker, missing mount sources are created owned by root,
/// and the container's uid could then not write its workspace.
pub fn prepare(policy: Policy, spec: Spec) -> Result(Nil, Error) {
  use _ <- result.try(
    list.try_each(spec.dirs, sys.mkdir_p) |> result.map_error(Filesystem),
  )
  use _ <- result.try(case policy.dns {
    [] -> Ok(Nil)
    servers ->
      list.map(servers, fn(server) { "nameserver " <> server <> "\n" })
      |> string.concat
      |> sys.write_private(host_resolv_conf(policy), _)
      |> result.map_error(Filesystem)
  })
  list.try_each(spec.files, fn(file) { sys.write_private(file.0, file.1) })
  |> result.map_error(Filesystem)
}
