import crushling/sandbox
import gleam/list
import gleam/string

fn policy() -> sandbox.Policy {
  sandbox.Policy(
    docker: "docker",
    image: "crushling-sandbox:latest",
    runtime: "runsc-uds",
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
  )
}

pub fn key_sanitizes_test() {
  let assert "C0123-1699999999.000100" =
    sandbox.key("C0123", "1699999999.000100")
  let assert "a_b_c-d_e" = sandbox.key("a/b c", "d;e")
  let assert 64 = string.length(sandbox.key(string.repeat("x", 100), "1"))
}

pub fn paths_test() {
  let assert "/storage/crushling/workspaces/k/sock/crush.sock" =
    sandbox.host_socket(policy(), "k")
}

pub fn run_args_test() {
  let args = sandbox.run_args(policy(), "k", [])
  let pairs = list.window_by_2(args)
  let has = fn(a, b) { list.contains(pairs, #(a, b)) }
  let assert True = has("--name", "crushling-k")
  let assert True = has("--runtime", "runsc-uds")
  let assert True = has("--network", "sbx-egress")
  let assert True = has("--user", "970:970")
  let assert True = has("--cap-drop", "ALL")
  let assert True = has("--env", "EXTRA=1")
  let assert True =
    has("--volume", "/storage/crushling/workspaces/k/work:/workspace")
  let assert True =
    has("--volume", "/storage/crushling/workspaces/k/sock:/run/crushling")
  let assert Ok("unix:///run/crushling/crush.sock") = list.last(args)
  let assert ["run", "--detach", ..] = args
}

pub fn fingerprint_tracks_policy_test() {
  let base = sandbox.fingerprint(policy())
  let assert 16 = string.length(base)
  let assert True = base == sandbox.fingerprint(policy())
  let assert False =
    base == sandbox.fingerprint(sandbox.Policy(..policy(), memory: "4g"))
}

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
  let p = sandbox.Policy(..policy(), root: "/tmp/crushling-sandbox-test")
  let assert Ok(Nil) = sandbox.prepare(p, "k")
  let assert True = sandbox.socket_ready(sandbox.host_workspace(p, "k"))
  let assert True = sandbox.socket_ready(sandbox.host_socket_dir(p, "k"))
  let assert True =
    sandbox.socket_ready(sandbox.host_crush_data(p, "k") <> "/crush.json")
}

pub fn exec_runs_without_a_shell_test() {
  // `echo` stands in for docker: it prints its arguments, which are not an
  // inspect result, so the container reads as missing.
  let p = sandbox.Policy(..policy(), docker: "echo")
  let assert Ok(sandbox.Missing) = sandbox.observe(p, "k; rm -rf /")
}

pub fn a_mounted_crush_runs_from_the_mount_test() {
  let assert Ok("unix:///run/crushling/crush.sock") =
    list.last(sandbox.run_args(policy(), "k", []))
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
