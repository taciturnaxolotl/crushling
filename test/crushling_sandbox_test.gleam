import crushling/sandbox
import gleam/int
import gleam/list
import gleam/string

fn policy() -> sandbox.Policy {
  sandbox.Policy(
    docker: "docker",
    image: "crushling-sandbox:latest",
    runtime: "runsc",
    network: "sbx-egress",
    cpus: "2",
    memory: "2g",
    pids: 1024,
    uid: 970,
    gid: 970,
    root: "/storage/crushling/workspaces",
    env: ["EXTRA=1"],
    crush_config: "{}",
    crush: "",
    dns: [],
    bridge_url: "http://172.30.0.1:7469",
  )
}

pub fn key_sanitizes_test() {
  let assert "C0123-1699999999.000100" =
    sandbox.key("C0123", "1699999999.000100")
  let assert "a_b_c-d_e" = sandbox.key("a/b c", "d;e")
  let assert 64 = string.length(sandbox.key(string.repeat("x", 100), "1"))
}

pub fn run_args_test() {
  let args = sandbox.run_args(policy(), "k", [])
  let pairs = list.window_by_2(args)
  let has = fn(a, b) { list.contains(pairs, #(a, b)) }
  let assert True = has("--name", "crushling-k")
  let assert True = has("--runtime", "runsc")
  let assert True = has("--network", "sbx-egress")
  let assert True = has("--user", "970:970")
  let assert True = has("--cap-drop", "ALL")
  let assert True = has("--env", "EXTRA=1")
  let assert True =
    has("--volume", "/storage/crushling/workspaces/k/work:/workspace")
  // crush dials the bridge's tunnel: no socket is mounted, so plain runsc
  // will do.
  let assert False =
    list.any(args, fn(arg) {
      string.contains(arg, "/sock") || string.contains(arg, "unix://")
    })
  let assert ["server", "--dial", "ws://172.30.0.1:7469/tunnel/k"] =
    list.drop(args, list.length(args) - 3)
  let assert ["run", "--detach", ..] = args
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
      sandbox.Policy(..policy(), bridge_url: "http://10.0.0.1:7469"),
    )
}

/// The fingerprint of the same policy before crush dialed out: containers
/// made then listen on a socket nobody connects to now, and are recreated.
pub fn sockets_era_containers_are_recreated_test() {
  let p = policy()
  let old =
    [
      p.image,
      p.runtime,
      p.network,
      p.cpus,
      p.memory,
      "1024",
      "970",
      "970",
      p.root,
      p.crush_config,
      "",
      "",
      ..p.env
    ]
    |> string.join("\u{0}")
    |> sha256_hex
    |> string.slice(0, 16)
  let assert False = old == sandbox.fingerprint(p)
  let assert sandbox.Recreate = sandbox.decide(sandbox.Present(True, old), p)
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
  let assert sandbox.Present(True, "abc") = sandbox.parse_inspect("true abc\n")
  let assert sandbox.Present(False, "") = sandbox.parse_inspect("false \n")
  let assert sandbox.Present(False, "") = sandbox.parse_inspect("false")
  let assert sandbox.Missing = sandbox.parse_inspect("")
}

pub fn docker_missing_is_unavailable_test() {
  let p = sandbox.Policy(..policy(), docker: "definitely-not-docker-xyz")
  let assert Error(sandbox.DockerUnavailable(_)) = sandbox.observe(p, "k")
}

pub fn prepare_creates_dirs_test() {
  let p =
    sandbox.Policy(
      ..policy(),
      root: "/tmp/crushling-sandbox-test-"
        <> int.to_string(int.absolute_value(unique())),
    )
  let assert Ok(Nil) = sandbox.prepare(p, "k")
  let assert True = file_exists(sandbox.host_workspace(p, "k"))
  let assert False = file_exists(p.root <> "/k/sock")
  let assert True =
    file_exists(sandbox.host_crush_data(p, "k") <> "/crush.json")
}

pub fn exec_runs_without_a_shell_test() {
  // `echo` stands in for docker: it prints its arguments, which are not an
  // inspect result, so the container reads as missing.
  let p = sandbox.Policy(..policy(), docker: "echo")
  let assert Ok(sandbox.Missing) = sandbox.observe(p, "k; rm -rf /")
}

pub fn a_mounted_crush_runs_from_the_mount_test() {
  let plain = sandbox.run_args(policy(), "k", [])
  let assert True =
    list.contains(list.window_by_2(plain), #(
      "crushling-sandbox:latest",
      "crush",
    ))
  let mounted =
    sandbox.run_args(sandbox.Policy(..policy(), crush: "/opt/crush"), "k", [])
  let pairs = list.window_by_2(mounted)
  let assert True =
    list.contains(pairs, #("--volume", "/opt/crush:/opt/crushling/crush:ro"))
  let assert True =
    list.contains(pairs, #("crushling-sandbox:latest", "/opt/crushling/crush"))
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
  let plain = list.window_by_2(sandbox.run_args(policy(), "k", []))
  let assert False =
    list.contains(plain, #(
      "--volume",
      "/storage/crushling/workspaces/resolv.conf:/etc/resolv.conf:ro",
    ))
  let with_dns = sandbox.Policy(..policy(), dns: ["1.1.1.1"])
  let assert True =
    list.contains(list.window_by_2(sandbox.run_args(with_dns, "k", [])), #(
      "--volume",
      "/storage/crushling/workspaces/resolv.conf:/etc/resolv.conf:ro",
    ))
  let assert False =
    sandbox.fingerprint(policy()) == sandbox.fingerprint(with_dns)
}

@external(erlang, "crushling_ffi", "file_exists")
fn file_exists(path: String) -> Bool

@external(erlang, "erlang", "unique_integer")
fn unique() -> Int
