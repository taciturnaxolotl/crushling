import crushling/agent/spec
import crushling/provider
import crushling/sandbox
import crushling/sys
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/string

fn settings() -> spec.Settings {
  spec.Settings(
    bridge_url: "http://172.30.0.1:7469",
    secret: "sandbox-test-secret",
    github: False,
    models: provider.Models(provider.default_large, provider.default_small),
    env: ["EXTRA=1"],
    own_team: "",
    own_env: [],
  )
}

fn policy() -> sandbox.Policy {
  sandbox.Policy(
    socket: "/nonexistent/docker.sock",
    image: "crushling-sandbox:latest",
    runtime: "runsc",
    network: "sbx-egress",
    cpus: "2",
    memory: "2g",
    pids: 1024,
    uid: 970,
    gid: 970,
    root: "/storage/crushling/workspaces",
    crush: "",
    dns: [],
    spec: settings(),
  )
}

fn body(p: sandbox.Policy, key: String) -> String {
  let s = spec.build(p.spec, p.root, key, spec.Contained)
  let assert Ok(body) = sandbox.create_body(p, s)
  json.to_string(body)
}

fn field(text: String, path: List(String), of: decode.Decoder(a)) -> a {
  let assert Ok(value) = json.parse(text, decode.at(path, of))
  value
}

pub fn create_body_test() {
  let text = body(policy(), "k")
  let strings = decode.list(decode.string)
  let assert "crushling-sandbox:latest" = field(text, ["Image"], decode.string)
  let assert "970:970" = field(text, ["User"], decode.string)
  let assert "/workspace" = field(text, ["WorkingDir"], decode.string)
  let assert "runsc" = field(text, ["HostConfig", "Runtime"], decode.string)
  let assert "sbx-egress" =
    field(text, ["HostConfig", "NetworkMode"], decode.string)
  let assert ["ALL"] = field(text, ["HostConfig", "CapDrop"], strings)
  let assert ["no-new-privileges"] =
    field(text, ["HostConfig", "SecurityOpt"], strings)
  let assert 2_000_000_000 = field(text, ["HostConfig", "NanoCpus"], decode.int)
  let assert 2_147_483_648 = field(text, ["HostConfig", "Memory"], decode.int)
  let assert 1024 = field(text, ["HostConfig", "PidsLimit"], decode.int)
  let assert ["/storage/crushling/workspaces/k/work:/workspace"] =
    field(text, ["HostConfig", "Binds"], strings)
  let assert "1" = field(text, ["Labels", "crushling-sandbox"], decode.string)
  let assert True =
    field(text, ["Labels", "crushling-sandbox-policy"], decode.string)
    == sandbox.fingerprint(policy())
  // crush dials the bridge's tunnel: no socket is mounted, so plain runsc
  // will do.
  let assert ["crush", "server", "--dial", "ws://172.30.0.1:7469/tunnel/k"] =
    field(text, ["Cmd"], strings)
  let env = field(text, ["Env"], strings)
  let assert True = list.contains(env, "EXTRA=1")
  let assert True = list.contains(env, "HOME=/workspace/.home")
  let assert True = list.contains(env, "CRUSH_SERVER_IDLE_TIMEOUT=31536000")
  let assert True = list.contains(env, "CRUSHLING_THREAD=k")
  let assert False = list.any(env, string.starts_with(_, "CRUSH_HYPER_"))
}

pub fn fingerprint_tracks_policy_test() {
  let base = sandbox.fingerprint(policy())
  let assert 16 = string.length(base)
  let assert True = base == sandbox.fingerprint(policy())
  let assert False =
    base == sandbox.fingerprint(sandbox.Policy(..policy(), memory: "4g"))
  let assert False =
    base
    == sandbox.fingerprint(
      sandbox.Policy(
        ..policy(),
        spec: spec.Settings(..settings(), bridge_url: "http://10.0.0.1:7469"),
      ),
    )
}

/// The fingerprint is the same string the CLI-era bridge labelled
/// containers with, so moving to the Engine API recreates nothing.
pub fn the_fingerprint_is_unchanged_test() {
  let p = policy()
  let old =
    [
      "dial",
      "http://172.30.0.1:7469",
      p.image,
      p.runtime,
      p.network,
      p.cpus,
      p.memory,
      "1024",
      "970",
      "970",
      p.root,
      provider.config(settings().models, "http://172.30.0.1:7469"),
      "",
      "",
      "",
      "",
      "EXTRA=1",
    ]
    |> string.join("\u{0}")
    |> sha256_hex
    |> string.slice(0, 16)
  let assert True = old == sandbox.fingerprint(p)
}

@external(erlang, "crushling_ffi", "sha256_hex")
fn sha256_hex(data: String) -> String

pub fn decide_test() {
  let p = policy()
  let current = sandbox.fingerprint(p)
  let assert sandbox.Create = sandbox.decide(sandbox.Missing, p)
  let assert sandbox.Adopt = sandbox.decide(sandbox.Present(True, current), p)
  let assert sandbox.Start = sandbox.decide(sandbox.Present(False, current), p)
  let assert sandbox.Recreate = sandbox.decide(sandbox.Present(True, "old"), p)
  let assert sandbox.Recreate = sandbox.decide(sandbox.Present(False, ""), p)
}

pub fn parse_inspect_test() {
  let assert sandbox.Present(True, "abc") =
    sandbox.parse_inspect(
      "{\"State\":{\"Running\":true},\"Config\":{\"Labels\":{\"crushling-sandbox-policy\":\"abc\"}}}",
    )
  let assert sandbox.Present(False, "") =
    sandbox.parse_inspect(
      "{\"State\":{\"Running\":false},\"Config\":{\"Labels\":null}}",
    )
  let assert sandbox.Missing = sandbox.parse_inspect("")
}

pub fn an_unreachable_engine_is_an_error_test() {
  let assert Error(sandbox.Unreachable(_)) = sandbox.observe(policy(), "k")
}

pub fn sizes_are_read_as_docker_reads_them_test() {
  let assert Ok(1_500_000_000) = sandbox.nano_cpus("1.5")
  let assert Error(_) = sandbox.nano_cpus("lots")
  let assert Ok(536_870_912) = sandbox.memory_bytes("512m")
  let assert Ok(4_294_967_296) = sandbox.memory_bytes("4GB")
  let assert Ok(1024) = sandbox.memory_bytes("1024")
  let assert Error(_) = sandbox.memory_bytes("big")
  let assert Error(_) = sandbox.check(sandbox.Policy(..policy(), memory: "0"))
}

pub fn demux_joins_both_streams_test() {
  let frames = <<
    1, 0, 0, 0, 0, 0, 0, 3, "out":utf8, 2, 0, 0, 0, 0, 0, 0, 4, "err!":utf8,
  >>
  let assert <<"outerr!":utf8>> = sandbox.demux(frames, <<>>)
  let assert <<"plain":utf8>> = sandbox.demux(<<"plain":utf8>>, <<>>)
}

pub fn exec_body_carries_env_in_the_body_test() {
  let text = json.to_string(sandbox.exec_body(["TS_AUTHKEY=secret"], "echo hi"))
  let assert ["sh", "-c", "echo hi"] =
    field(text, ["Cmd"], decode.list(decode.string))
  let assert ["TS_AUTHKEY=secret"] =
    field(text, ["Env"], decode.list(decode.string))
}

pub fn prepare_creates_dirs_test() {
  let p =
    sandbox.Policy(
      ..policy(),
      root: "/tmp/crushling-sandbox-test-"
        <> int.to_string(int.absolute_value(unique())),
    )
  let s = spec.build(p.spec, p.root, "k", spec.Contained)
  let assert Ok(Nil) = sandbox.prepare(p, s)
  let assert True = file_exists(sandbox.host_workspace(p, "k"))
  let assert True =
    file_exists(
      sandbox.host_workspace(p, "k") <> "/.home/.local/share/crush/crush.json",
    )
}

pub fn a_mounted_crush_runs_from_the_mount_test() {
  let strings = decode.list(decode.string)
  let mounted = body(sandbox.Policy(..policy(), crush: "/opt/crush"), "k")
  let assert True =
    list.contains(
      field(mounted, ["HostConfig", "Binds"], strings),
      "/opt/crush:/opt/crushling/crush:ro",
    )
  let assert ["/opt/crushling/crush", ..] = field(mounted, ["Cmd"], strings)
}

pub fn a_new_crush_binary_changes_the_fingerprint_test() {
  let path = "/tmp/crushling-sandbox-test-crush"
  let assert Ok(Nil) = write_file(path, "one")
  let p = sandbox.Policy(..policy(), crush: path)
  let before = sandbox.fingerprint(p)
  let assert True = before == sandbox.fingerprint(p)
  let assert Ok(Nil) = write_file(path, "a longer binary")
  let assert False = before == sandbox.fingerprint(p)
}

@external(erlang, "crushling_ffi", "write_private")
fn write_file(path: String, content: String) -> Result(Nil, String)

pub fn sandboxes_get_their_own_nameservers_test() {
  let strings = decode.list(decode.string)
  let resolv = "/storage/crushling/workspaces/resolv.conf:/etc/resolv.conf:ro"
  let assert False =
    list.contains(
      field(body(policy(), "k"), ["HostConfig", "Binds"], strings),
      resolv,
    )
  let with_dns = sandbox.Policy(..policy(), dns: ["1.1.1.1"])
  let assert True =
    list.contains(
      field(body(with_dns, "k"), ["HostConfig", "Binds"], strings),
      resolv,
    )
  let assert False =
    sandbox.fingerprint(policy()) == sandbox.fingerprint(with_dns)
}

@external(erlang, "crushling_ffi", "file_exists")
fn file_exists(path: String) -> Bool

@external(erlang, "erlang", "unique_integer")
fn unique() -> Int

pub fn unused_images_test() {
  let tags = [
    "crushling-sandbox:new", "crushling-sandbox:old", "crushling-sandbox:pinned",
    "crushling-sandbox:<none>", "",
  ]
  let assert ["crushling-sandbox:old"] =
    sandbox.unused_images(
      tags,
      ["crushling-sandbox:pinned", "erlang:27"],
      "crushling-sandbox:new",
    )
}

@external(erlang, "crushling_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "crushling_test_ffi", "make_executable")
fn make_executable(path: String) -> Nil

/// The Engine API calls against a real docker, with `CRUSHLING_DOCKER=1`
/// and `alpine:3` pulled: runc stands in for runsc, and a script mounted as
/// crush sleeps instead of dialing.
pub fn real_docker_test() {
  case getenv("CRUSHLING_DOCKER") {
    Ok("1") -> real_docker()
    _ -> Nil
  }
}

fn real_docker() -> Nil {
  let root =
    "/tmp/crushling-docker-test-" <> int.to_string(int.absolute_value(unique()))
  let crush = root <> "/fake-crush"
  let assert Ok(Nil) = sys.mkdir_p(root)
  let assert Ok(Nil) = write_file(crush, "#!/bin/sh\nexec sleep 300\n")
  make_executable(crush)
  let p =
    sandbox.Policy(
      ..policy(),
      socket: sandbox.default_socket,
      image: "alpine:3",
      runtime: "runc",
      network: "bridge",
      cpus: "1",
      memory: "256m",
      root:,
      crush:,
    )
  let key = "T1-C1-" <> int.to_string(int.absolute_value(unique()))
  let s = spec.build(p.spec, p.root, key, spec.Contained)
  let assert Ok(Nil) = sandbox.prepare(p, s)
  let assert Ok(sandbox.Missing) = sandbox.observe(p, key)
  let assert Ok(Nil) = sandbox.ensure(p, s)
  let current = sandbox.fingerprint(p)
  let assert Ok(sandbox.Present(True, seen)) = sandbox.observe(p, key)
  let assert True = seen == current
  let assert Ok(running) = sandbox.running(p)
  let assert True = list.contains(running, key)
  // Adopted as it is.
  let assert Ok(Nil) = sandbox.ensure(p, s)
  let assert Ok(out) =
    sandbox.run_in(p, key, ["GREETING=hi"], "echo $GREETING; echo oops >&2")
  let assert True = string.contains(out, "hi") && string.contains(out, "oops")
  let assert Error(sandbox.Exited(3, _)) = sandbox.run_in(p, key, [], "exit 3")
  let assert Ok(Nil) = sandbox.stop(p, key)
  let assert Ok(sandbox.Present(False, _)) = sandbox.observe(p, key)
  // Already stopped is fine; started again under the same policy.
  let assert Ok(Nil) = sandbox.stop(p, key)
  let assert Ok(Nil) = sandbox.ensure(p, s)
  let assert Ok(sandbox.Present(True, _)) = sandbox.observe(p, key)
  let assert Ok(Nil) = sandbox.remove(p, key)
  let assert Ok(sandbox.Missing) = sandbox.observe(p, key)
  // Gone already is fine.
  let assert Ok(Nil) = sandbox.remove(p, key)
  let assert Ok(Nil) = sandbox.stop(p, key)
  Nil
}
