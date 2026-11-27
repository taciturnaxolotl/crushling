//// The launchers' wiring to the bridge: what a sandbox's crush is given,
//// and what a launch and a stop do with the tunnel and the proxy. Docker
//// is stood in for by a script that logs its arguments.

import crushling/launcher
import crushling/mcp
import crushling/provider
import crushling/proxy
import crushling/sandbox
import crushling/sys
import crushling/tunnel
import crushling/usage as spend
import gleam/erlang/charlist
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string

const secret = "launcher-test-secret"

const url = "http://172.30.0.1:7469"

@external(erlang, "erlang", "unique_integer")
fn unique() -> Int

@external(erlang, "crushling_ffi", "mkdir_p")
fn mkdir_p(path: String) -> Result(Nil, String)

@external(erlang, "crushling_ffi", "write_private")
fn write_private(path: String, content: String) -> Result(Nil, String)

@external(erlang, "crushling_ffi", "read_file")
fn read_file(path: String) -> Result(String, Nil)

@external(erlang, "crushling_ffi", "file_exists")
fn file_exists(path: String) -> Bool

@external(erlang, "crushling_test_ffi", "make_executable")
fn make_executable(path: String) -> Nil

fn tmp(name: String) -> String {
  let dir =
    "/tmp/crushling-launcher-"
    <> name
    <> "-"
    <> int.to_string(int.absolute_value(unique()) % 1_000_000)
  let assert Ok(Nil) = mkdir_p(dir)
  dir
}

/// The real bridge, for its environment.
fn real_bridge(root: String) -> launcher.Bridge {
  real_bridge_at(root, url)
}

fn real_bridge_at(root: String, url: String) -> launcher.Bridge {
  let assert Ok(tunnels) = tunnel.start(tunnel.config(secret, root))
  let assert Ok(p) =
    proxy.start(proxy.Config(
      secret:,
      org_key: "org-key",
      upstream: proxy.default_upstream,
      thread_cap: spend.unlimited,
      instance_cap: spend.unlimited,
      max_per_thread: proxy.default_max_per_thread,
      max_uploads: proxy.default_max_uploads,
      upload_timeout_ms: proxy.default_upload_timeout_ms,
    ))
  launcher.bridge(
    url:,
    secret:,
    tunnels:,
    proxy: p,
    github: False,
    hello_timeout_ms: launcher.default_hello_timeout_ms,
  )
}

/// The real environment, with the tunnel and proxy operations recorded.
/// `hello` answers `await_hello`.
fn recording_bridge(
  root: String,
  calls: Subject(String),
  hello: fn(String) -> Result(String, String),
) -> launcher.Bridge {
  recording_bridge_at(root, url, calls, hello)
}

fn recording_bridge_at(
  root: String,
  url: String,
  calls: Subject(String),
  hello: fn(String) -> Result(String, String),
) -> launcher.Bridge {
  launcher.Bridge(
    ..real_bridge_at(root, url),
    open: fn(key) {
      process.send(calls, "open " <> key)
      Ok(tunnel.shim_path(root, key))
    },
    await_hello: fn(key, _) {
      process.send(calls, "await_hello " <> key)
      hello(key)
    },
    bye: fn(key) { process.send(calls, "bye " <> key) },
    close: fn(key) { process.send(calls, "close " <> key) },
    restore: fn(key) { process.send(calls, "restore " <> key) },
    revoke: fn(key) { process.send(calls, "revoke " <> key) },
    hello_timeout_ms: 1000,
  )
}

fn drain(calls: Subject(String), acc: List(String)) -> List(String) {
  case process.receive(calls, 0) {
    Ok(call) -> drain(calls, [call, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

/// A docker that logs each call's arguments, one line each, and prints
/// nothing, so every container reads as missing.
fn fake_docker(dir: String) -> #(String, String) {
  let path = dir <> "/docker"
  let log = dir <> "/docker.log"
  let assert Ok(Nil) =
    write_private(path, "#!/bin/sh\necho \"$@\" >> '" <> log <> "'\n")
  make_executable(path)
  #(path, log)
}

fn policy(dir: String, docker: String) -> sandbox.Policy {
  sandbox.Policy(
    docker:,
    image: "crushling-sandbox:latest",
    runtime: "runsc",
    network: "sbx-egress",
    cpus: "2",
    memory: "4g",
    pids: 1024,
    uid: 970,
    gid: 970,
    root: dir,
    env: ["HONCHO_URL=https://honcho.example"],
    own_team: "",
    own_env: [],
    crush_config: provider.config(provider.Models("big", "small"), url),
    crush: "",
    dns: [],
    bridge_url: url,
  )
}

/// The operator's Honcho settings reach only the self-host workspace's
/// sandboxes.
pub fn honcho_settings_reach_only_the_own_workspace_test() {
  let p =
    sandbox.Policy(..policy("/tmp", "docker"), own_team: "T1", own_env: [
      "HONCHO_API_KEY=hk-secret",
    ])
  let has = fn(key) {
    sandbox.run_args(p, key, [])
    |> list.contains("HONCHO_API_KEY=hk-secret")
  }
  let assert True = has("T1-C1-1.0")
  let assert False = has("T2-C1-1.0")
  let assert False = has("C1-1.0")
  // Nobody's, without a workspace of its own.
  let assert [] = sandbox.team_env(sandbox.Policy(..p, own_team: ""), "-C1-1.0")
  // Changing them recreates containers.
  let assert False =
    sandbox.fingerprint(p)
    == sandbox.fingerprint(sandbox.Policy(..p, own_env: []))
}

pub fn bridge_env_has_tokens_and_no_crush_hyper_test() {
  let root = tmp("env")
  let env = real_bridge(root).env("C1-1.0")
  let assert True =
    list.contains(
      env,
      "CRUSH_SERVER_DIAL_TOKEN=" <> tunnel.token(secret, "C1-1.0"),
    )
  let assert True = list.contains(env, "HYPER_URL=" <> url <> "/proxy/C1-1.0")
  let assert True =
    list.contains(env, "HYPER_API_KEY=" <> proxy.token(secret, "C1-1.0"))
  let assert True = list.contains(env, "CRUSHLING_THREAD=C1-1.0")
  let assert True =
    list.any(env, fn(pair) { string.starts_with(pair, "CRUSHLING_MCP_TOKEN=") })
  // The file helpers' bridge URL, exactly once.
  let assert ["CRUSHLING_BRIDGE_URL=" <> bridge_url] =
    list.filter(env, fn(pair) {
      string.starts_with(pair, "CRUSHLING_BRIDGE_URL=")
    })
  let assert True = bridge_url == url
  let assert False =
    list.any(env, fn(pair) { string.starts_with(pair, "CRUSH_HYPER_") })
  // The org's key never reaches a sandbox.
  let assert False =
    list.any(env, fn(pair) { string.contains(pair, "org-key") })
}

pub fn docker_run_dials_with_the_bridge_env_test() {
  let dir = tmp("args")
  let bridge = real_bridge(dir)
  let args =
    sandbox.run_args(policy(dir, "docker"), "C1-1.0", bridge.env("C1-1.0"))
  let pairs = list.window_by_2(args)
  let env =
    list.filter_map(pairs, fn(pair) {
      case pair {
        #("--env", value) -> Ok(value)
        _ -> Error(Nil)
      }
    })
  let assert True =
    list.any(env, fn(pair) {
      string.starts_with(pair, "CRUSH_SERVER_DIAL_TOKEN=")
    })
  let assert True = list.contains(env, "HYPER_URL=" <> url <> "/proxy/C1-1.0")
  let assert True =
    list.any(env, fn(pair) { string.starts_with(pair, "HYPER_API_KEY=") })
  let assert False =
    list.any(env, fn(pair) { string.starts_with(pair, "CRUSH_HYPER_") })
  let volumes =
    list.filter_map(pairs, fn(pair) {
      case pair {
        #("--volume", value) -> Ok(value)
        _ -> Error(Nil)
      }
    })
  let assert [_workspace] = volumes
  let assert True = list.contains(pairs, #("--runtime", "runsc"))
  let assert ["server", "--dial", "ws://172.30.0.1:7469/tunnel/C1-1.0"] =
    list.drop(args, list.length(args) - 3)
}

pub fn docker_launch_returns_the_shim_test() {
  let dir = tmp("launch")
  let #(docker, log) = fake_docker(dir)
  let calls = process.new_subject()
  let bridge = recording_bridge(dir, calls, fn(_) { Ok("v1") })
  let l = launcher.docker(policy(dir, docker), bridge)
  let assert Ok(launched) = l.launch("C1-1.0")
  let assert True = launched.socket == tunnel.shim_path(dir, "C1-1.0")
  let assert "/workspace" = launched.root
  let assert ["open C1-1.0", "restore C1-1.0", "await_hello C1-1.0"] =
    drain(calls, [])
  let assert Ok(ran) = read_file(log)
  let assert True = string.contains(ran, "run --detach --name crushling-C1-1.0")
  let assert False = string.contains(ran, "stop")
}

pub fn docker_hello_timeout_stops_and_cleans_up_test() {
  let dir = tmp("timeout")
  let #(docker, log) = fake_docker(dir)
  let calls = process.new_subject()
  let bridge =
    recording_bridge(dir, calls, fn(_) { Error("crush did not dial in") })
  let l = launcher.docker(policy(dir, docker), bridge)
  let assert Error("crush did not dial in") = l.launch("C1-1.0")
  let assert [
    "open C1-1.0",
    "restore C1-1.0",
    "await_hello C1-1.0",
    "close C1-1.0",
    "revoke C1-1.0",
  ] = drain(calls, [])
  let assert Ok(ran) = read_file(log)
  let assert True = string.contains(ran, "stop --time 2 crushling-C1-1.0")
}

/// A docker whose `run` fails, and whose `stop` fails too unless the
/// container is missing; it logs every call's arguments.
fn failing_docker(dir: String, stop_output: String) -> #(String, String) {
  let path = dir <> "/docker"
  let log = dir <> "/docker.log"
  let assert Ok(Nil) =
    write_private(
      path,
      "#!/bin/sh\necho \"$@\" >> '"
        <> log
        <> "'\ncase \"$1\" in\n  run) echo 'timed out talking to the daemon'; exit 1;;\n  stop) echo '"
        <> stop_output
        <> "'; exit 1;;\nesac\n",
    )
  make_executable(path)
  #(path, log)
}

pub fn open_failure_touches_nothing_test() {
  let dir = tmp("open-fails")
  let #(docker, log) = fake_docker(dir)
  let calls = process.new_subject()
  let bridge =
    launcher.Bridge(
      ..recording_bridge(dir, calls, fn(_) { Ok("v1") }),
      open: fn(key) {
        process.send(calls, "open " <> key)
        Error("too many endpoints")
      },
    )
  let l = launcher.docker(policy(dir, docker), bridge)
  let assert Error(reason) = l.launch("C1-1.0")
  let assert True = string.contains(reason, "too many endpoints")
  // Nothing was restored, so nothing needs revoking, and docker never ran.
  let assert ["open C1-1.0"] = drain(calls, [])
  let assert Error(Nil) = read_file(log)
}

pub fn ensure_failure_still_stops_the_container_test() {
  let dir = tmp("ensure-fails")
  let #(docker, log) = failing_docker(dir, "Error: No such container")
  let calls = process.new_subject()
  let bridge = recording_bridge(dir, calls, fn(_) { Ok("v1") })
  let l = launcher.docker(policy(dir, docker), bridge)
  let assert Error(reason) = l.launch("C1-1.0")
  let assert True = string.contains(reason, "timed out talking to the daemon")
  // The CLI failing doesn't prove the container isn't there.
  let assert Ok(ran) = read_file(log)
  let assert True = string.contains(ran, "stop --time 2 crushling-C1-1.0")
  // A missing container is nothing to report.
  let assert False = string.contains(reason, "cleanup failed")
  let assert ["open C1-1.0", "restore C1-1.0", "close C1-1.0", "revoke C1-1.0"] =
    drain(calls, [])
}

pub fn cleanup_failures_are_reported_test() {
  let dir = tmp("cleanup-fails")
  let #(docker, _) = failing_docker(dir, "Cannot connect to the Docker daemon")
  let calls = process.new_subject()
  let bridge = recording_bridge(dir, calls, fn(_) { Ok("v1") })
  let l = launcher.docker(policy(dir, docker), bridge)
  let assert Error(reason) = l.launch("C1-1.0")
  let assert True = string.contains(reason, "cleanup failed")
  let assert True =
    string.contains(reason, "Cannot connect to the Docker daemon")
  // The tunnel and token are undone all the same.
  let calls = drain(calls, [])
  let assert True = list.contains(calls, "close C1-1.0")
  let assert True = list.contains(calls, "revoke C1-1.0")
}

pub fn failed_docker_run_hides_the_tokens_test() {
  let dir = tmp("redact")
  let #(docker, _) = failing_docker(dir, "Error: No such container")
  let calls = process.new_subject()
  let bridge = recording_bridge(dir, calls, fn(_) { Ok("v1") })
  let l = launcher.docker(policy(dir, docker), bridge)
  let assert Error(reason) = l.launch("C1-1.0")
  let assert True = string.contains(reason, "DockerFailed")
  let assert False = string.contains(reason, tunnel.token(secret, "C1-1.0"))
  let assert False = string.contains(reason, proxy.token(secret, "C1-1.0"))
  let assert False = string.contains(reason, mcp.token(secret, "C1-1.0"))
  let assert True = string.contains(reason, "HYPER_API_KEY=<redacted>")
  let assert True =
    string.contains(reason, "CRUSH_SERVER_DIAL_TOKEN=<redacted>")
  let assert True = string.contains(reason, "HONCHO_URL=<redacted>")
}

pub fn redact_hides_only_env_values_test() {
  let assert [
    "run",
    "--env",
    "A=<redacted>",
    "--name",
    "x",
    "--env",
    "B=<redacted>",
    "image",
  ] =
    sandbox.redact([
      "run", "--env", "A=secret=more", "--name", "x", "--env", "B=", "image",
    ])
}

/// A launcher whose launch succeeds, recording its stops.
fn launching(calls: Subject(String)) -> launcher.Launcher {
  launcher.Launcher(
    launch: fn(key) {
      process.send(calls, "launch " <> key)
      Ok(launcher.Launched(socket: "/tmp/none.sock", root: "/workspace"))
    },
    stop: fn(key) {
      process.send(calls, "stop " <> key)
      Ok(Nil)
    },
    exists: fn(_) { False },
    forget: fn(_) { Ok(Nil) },
    rekey: fn(_, _) { Ok(Nil) },
    run_in_sandbox: None,
  )
}

pub fn a_thread_that_fails_to_start_stops_its_agent_test() {
  let calls = process.new_subject()
  let assert Error("thread: boom") =
    launcher.launch_then(launching(calls), "C1-1.0", fn(_) {
      Error("thread: boom")
    })
  let assert ["launch C1-1.0", "stop C1-1.0"] = drain(calls, [])
  let assert Ok(3) =
    launcher.launch_then(launching(calls), "C1-1.0", fn(_) { Ok(3) })
  let assert ["launch C1-1.0"] = drain(calls, [])
}

pub fn docker_stop_says_bye_and_revokes_test() {
  let dir = tmp("stop")
  let #(docker, log) = fake_docker(dir)
  let calls = process.new_subject()
  let bridge = recording_bridge(dir, calls, fn(_) { Ok("v1") })
  let l = launcher.docker(policy(dir, docker), bridge)
  let assert Ok(Nil) = l.stop("C1-1.0")
  let assert ["bye C1-1.0", "close C1-1.0", "revoke C1-1.0"] = drain(calls, [])
  let assert Ok(ran) = read_file(log)
  let assert True = string.contains(ran, "stop --time 2 crushling-C1-1.0")
}

/// A crush stand-in that records its environment and arguments, then waits
/// to be stopped. It isn't named `crush`: the launcher stops it by pid.
fn fake_crush(dir: String) -> String {
  let path = dir <> "/agent-bin"
  let assert Ok(Nil) =
    write_private(
      path,
      "#!/bin/sh\nprintenv > \"$CRUSH_GLOBAL_DATA/env.txt\"\necho \"$@\" > \"$CRUSH_GLOBAL_DATA/args.txt\"\nwhile :; do sleep 1; done\n",
    )
  make_executable(path)
  path
}

fn wait_for(path: String, tries: Int) -> Result(String, String) {
  case file_exists(path), tries {
    True, _ -> {
      // Give the stand-in a moment to finish writing.
      process.sleep(50)
      Ok("fake")
    }
    False, 0 -> Error("never wrote " <> path)
    False, _ -> {
      process.sleep(50)
      wait_for(path, tries - 1)
    }
  }
}

pub fn local_launch_dials_with_the_bridge_env_test() {
  let dir = tmp("local")
  let crush = fake_crush(dir)
  let calls = process.new_subject()
  let key = "C1-" <> int.to_string(int.absolute_value(unique()) % 1_000_000)
  let data = dir <> "/" <> key <> "/home/data"
  let bridge =
    recording_bridge_at(dir, "http://127.0.0.1:7469", calls, fn(_) {
      wait_for(data <> "/env.txt", 100)
    })
  let l = launcher.local(dir, crush, provider.Models("big", "small"), bridge)
  let assert Ok(launched) = l.launch(key)
  let assert Ok(pid) = read_file(dir <> "/" <> key <> "/server.pid")
  // Its identity: pid, start time, and the exact dial URL with the key.
  let assert [pid_line, started, dial] = string.split(string.trim(pid), "\n")
  let assert Ok(_) = int.parse(pid_line)
  let assert True = started != ""
  let assert True = dial == "ws://127.0.0.1:7469/tunnel/" <> key
  // Stopped whatever happens, so a failure leaves no stand-in running.
  use <-
    guarded(_, fn() {
      let _ = l.stop(key)
      Nil
    })
  let assert True = launched.socket == tunnel.shim_path(dir, key)
  let assert True = launched.root == dir <> "/" <> key <> "/work"
  let assert Ok(args) = read_file(data <> "/args.txt")
  let assert True =
    string.trim(args) == "server --dial ws://127.0.0.1:7469/tunnel/" <> key
  let assert Ok(env) = read_file(data <> "/env.txt")
  let env = string.split(env, "\n")
  let assert True =
    list.any(env, fn(pair) {
      string.starts_with(pair, "CRUSH_SERVER_DIAL_TOKEN=")
    })
  let assert True =
    list.contains(env, "HYPER_URL=http://127.0.0.1:7469/proxy/" <> key)
  let assert True =
    list.any(env, fn(pair) { string.starts_with(pair, "HYPER_API_KEY=") })
  // Even when the bridge itself has them.
  let assert False =
    list.any(env, fn(pair) { string.starts_with(pair, "CRUSH_HYPER_") })
  let assert Ok(config) = read_file(data <> "/crush.json")
  let assert False = string.contains(config, "api_key")
  let assert Ok(Nil) = l.stop(key)
  let assert [
    "open " <> _,
    "restore " <> _,
    "await_hello " <> _,
    "bye " <> _,
    "close " <> _,
    "revoke " <> _,
  ] = drain(calls, [])
  // The stand-in is gone, stopped by its pid.
  let assert "" = string.trim(sh("pgrep -f '" <> crush <> "'"))
  let assert False = file_exists(dir <> "/" <> key <> "/server.pid")
  Nil
}

@external(erlang, "real_server_ffi", "guarded")
fn guarded(body: fn() -> a, cleanup: fn() -> Nil) -> a

@external(erlang, "os", "cmd")
fn os_cmd(command: charlist.Charlist) -> charlist.Charlist

fn sh(command: String) -> String {
  charlist.to_string(os_cmd(charlist.from_string(command)))
}

pub fn local_crush_that_exits_is_cleaned_up_test() {
  let dir = tmp("local-exit")
  let calls = process.new_subject()
  let bridge = recording_bridge(dir, calls, fn(_) { Error("not yet") })
  let l =
    launcher.local(dir, "/usr/bin/false", provider.Models("a", "b"), bridge)
  let assert Error(reason) = l.launch("C1-2.0")
  let assert True = string.contains(reason, "exited")
  let calls = drain(calls, [])
  let assert True = list.contains(calls, "close C1-2.0")
  let assert True = list.contains(calls, "revoke C1-2.0")
}

pub fn crush_config_names_hyper_without_a_key_test() {
  let config = provider.config(provider.Models("big", "small"), url)
  let assert True = string.contains(config, "\"hyper\":{}")
  let assert True =
    string.contains(config, "{\"provider\":\"hyper\",\"model\":\"big\"}")
  let assert True =
    string.contains(config, "{\"provider\":\"hyper\",\"model\":\"small\"}")
  let assert True = string.contains(config, url <> "/mcp/$CRUSHLING_THREAD")
  let assert False = string.contains(config, "api_key")
  let assert False = string.contains(config, "base_url")
  let assert False =
    string.contains(provider.config(provider.Models("a", "b"), ""), "\"mcp\"")
}

/// A docker whose `run` echoes its arguments to stderr and fails.
fn echoing_docker(dir: String) -> String {
  let path = dir <> "/docker"
  let assert Ok(Nil) =
    write_private(
      path,
      "#!/bin/sh\ncase \"$1\" in\n  run) echo \"docker: bad flags: $*\" >&2; exit 125;;\n  stop) echo 'Error: No such container'; exit 1;;\nesac\n",
    )
  make_executable(path)
  path
}

pub fn docker_output_hides_the_tokens_test() {
  let dir = tmp("redact-output")
  let calls = process.new_subject()
  let bridge = recording_bridge(dir, calls, fn(_) { Ok("v1") })
  let l = launcher.docker(policy(dir, echoing_docker(dir)), bridge)
  let assert Error(reason) = l.launch("C1-1.0")
  let assert True = string.contains(reason, "bad flags")
  let assert True = string.contains(reason, "<redacted>")
  let assert False = string.contains(reason, tunnel.token(secret, "C1-1.0"))
  let assert False = string.contains(reason, proxy.token(secret, "C1-1.0"))
  let assert False = string.contains(reason, mcp.token(secret, "C1-1.0"))
  let assert "a <redacted> b <redacted> 1" =
    sandbox.redact_output(
      ["--env", "T=secret-one", "--env", "U=secret-one-two", "--env", "N=1"],
      "a secret-one-two b secret-one 1",
    )
}

pub fn a_crush_that_cannot_start_is_rolled_back_test() {
  let dir = tmp("no-binary")
  let calls = process.new_subject()
  let bridge = recording_bridge(dir, calls, fn(_) { Ok("v1") })
  let l =
    launcher.local(
      dir,
      dir <> "/no-such-crush",
      provider.Models("a", "b"),
      bridge,
    )
  let assert Error(reason) = l.launch("C1-3.0")
  let assert True = string.contains(reason, "not an executable")
  let assert ["open C1-3.0", "restore C1-3.0", "close C1-3.0", "revoke C1-3.0"] =
    drain(calls, [])
}

@external(erlang, "crushling_local_ffi", "start")
fn local_start(
  crush: String,
  dial_url: String,
  workdir: String,
  log: String,
  env: List(String),
  pid_file: String,
) -> Result(Int, String)

@external(erlang, "crushling_local_ffi", "stop")
fn local_stop(pid_file: String) -> Result(Nil, String)

@external(erlang, "crushling_local_ffi", "alive")
fn local_alive(os_pid: Int) -> Bool

pub fn a_removed_working_dir_is_an_error_test() {
  let dir = tmp("gone-dir")
  let crush = fake_crush(dir)
  let assert Error(reason) =
    local_start(
      crush,
      "ws://127.0.0.1:1/tunnel/k",
      dir <> "/removed",
      dir <> "/log",
      [],
      dir <> "/server.pid",
    )
  let assert True = string.contains(reason, "working directory")
}

/// A pid file whose identity no longer matches (here, the process was
/// started for another thread's URL) is never signalled.
pub fn stop_checks_the_recorded_identity_test() {
  let dir = tmp("identity")
  let crush = fake_crush(dir)
  let assert Ok(Nil) = mkdir_p(dir <> "/data")
  let pid_file = dir <> "/server.pid"
  let assert Ok(pid) =
    local_start(
      crush,
      "ws://127.0.0.1:1/tunnel/C1-4.0",
      dir,
      dir <> "/log",
      ["CRUSH_GLOBAL_DATA=" <> dir <> "/data"],
      pid_file,
    )
  use <-
    guarded(_, fn() {
      let _ = sh("kill -9 " <> int.to_string(pid))
      Nil
    })
  let assert Ok(recorded) = read_file(pid_file)
  let assert [_, started, _] = string.split(string.trim(recorded), "\n")
  // Same pid and start time, another thread's key: left alone.
  let assert Ok(Nil) =
    write_private(
      pid_file,
      int.to_string(pid)
        <> "\n"
        <> started
        <> "\nws://127.0.0.1:1/tunnel/C1-4.00\n",
    )
  let assert Ok(Nil) = local_stop(pid_file)
  let assert True = local_alive(pid)
  // The real identity stops it.
  let assert Ok(Nil) = write_private(pid_file, recorded)
  let assert Ok(Nil) = local_stop(pid_file)
  let assert False = local_alive(pid)
  let assert False = file_exists(pid_file)
}

/// A thread moving to a key with its workspace in it: the old container
/// is removed, not left running, and the directory moves with it.
pub fn docker_rekey_removes_the_old_container_and_moves_the_directory_test() {
  let dir = tmp("rekey-" <> sys.uuid())
  let #(docker, log) = fake_docker(dir)
  let l = launcher.docker(policy(dir, docker), real_bridge(dir))
  let assert Ok(Nil) = mkdir_p(dir <> "/C1-1.0/work")
  let assert Ok(Nil) = write_private(dir <> "/C1-1.0/work/notes.txt", "kept")
  let assert Ok(Nil) = l.rekey("C1-1.0", "T1-C1-1.0")
  let assert Ok(ran) = read_file(log)
  let assert True = string.contains(ran, "rm --force crushling-C1-1.0")
  let assert True = l.exists("T1-C1-1.0")
  let assert False = l.exists("C1-1.0")
  let assert Ok("kept") = read_file(dir <> "/T1-C1-1.0/work/notes.txt")
  // Nothing left to move is fine.
  let assert Ok(Nil) = l.rekey("C1-1.0", "T1-C1-1.0")
}

pub fn local_rekey_moves_the_directory_test() {
  let dir = tmp("rekey-local-" <> sys.uuid())
  let l =
    launcher.local(dir, "", provider.Models("big", "small"), real_bridge(dir))
  let assert Ok(Nil) = mkdir_p(dir <> "/C2-1.0/work")
  let assert Ok(Nil) = l.rekey("C2-1.0", "T1-C2-1.0")
  let assert True = l.exists("T1-C2-1.0")
  let assert False = l.exists("C2-1.0")
  // A new key that already exists is never overwritten.
  let assert Ok(Nil) = mkdir_p(dir <> "/C3-1.0/work")
  let assert Ok(Nil) = mkdir_p(dir <> "/T1-C3-1.0/work")
  let assert Error(_) = l.rekey("C3-1.0", "T1-C3-1.0")
}

/// Forgetting a thread removes its directory and only that: a key that
/// could reach outside the instance root is refused.
pub fn forget_removes_only_the_threads_dir_test() {
  let dir = tmp("forget")
  let bridge = recording_bridge(dir, process.new_subject(), fn(_) { Ok("") })
  let l =
    launcher.local(dir, "/usr/bin/false", provider.Models("a", "b"), bridge)
  let assert Ok(Nil) = mkdir_p(dir <> "/T1-C1-1.0/work/.home")
  let assert Ok(Nil) = mkdir_p(dir <> "/T1-C2-1.0/work")
  let assert True = l.exists("T1-C1-1.0")
  let assert Ok(Nil) = l.forget("T1-C1-1.0")
  let assert False = l.exists("T1-C1-1.0")
  let assert True = l.exists("T1-C2-1.0")
  // Gone already is fine.
  let assert Ok(Nil) = l.forget("T1-C1-1.0")
  let assert Error(_) = l.forget("../T1-C2-1.0")
  let assert Error(_) = l.forget("..")
  let assert Error(_) = l.forget("")
  let assert True = l.exists("T1-C2-1.0")
}
