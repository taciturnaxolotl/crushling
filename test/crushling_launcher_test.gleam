//// The launch and stop written once against a backend: what a crush is
//// given, and what a launch, a failed launch and a stop do with the real
//// tunnel and proxy. A recording backend stands in for docker; the local
//// backend runs a stand-in crush.

import crushling/agent/backend
import crushling/agent/post_mortem
import crushling/agent/spec
import crushling/gun
import crushling/launcher
import crushling/mcp
import crushling/provider
import crushling/proxy
import crushling/sandbox
import crushling/sandbox_http
import crushling/sys
import crushling/tunnel
import crushling/usage as spend
import gleam/erlang/charlist
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import stratus

const secret = "launcher-test-secret"

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

fn n() -> Int {
  int.absolute_value(unique()) % 1_000_000
}

fn tmp(name: String) -> String {
  let dir = "/tmp/crushling-launcher-" <> name <> "-" <> int.to_string(n())
  let assert Ok(Nil) = mkdir_p(dir)
  dir
}

/// The real tunnels and proxy, served on a port of their own.
type Bridge {
  Bridge(root: String, url: String, port: Int, wiring: launcher.Wiring)
}

fn settings(url: String) -> spec.Settings {
  spec.Settings(
    bridge_url: url,
    secret:,
    github: False,
    models: provider.Models("big", "small"),
    env: ["HONCHO_URL=https://honcho.example"],
    own_team: "",
    own_env: [],
  )
}

fn bridge(name: String) -> Bridge {
  let root = tmp(name)
  let assert Ok(tunnels) = tunnel.start(tunnel.config(secret, root))
  let assert Ok(p) =
    proxy.start(
      proxy.named(proxy.Config(
        secret:,
        org_key: "org-key",
        // Nothing listens there: an allowed request fails upstream (502),
        // a disallowed one never leaves (403).
        upstream: "http://127.0.0.1:1",
        thread_cap: spend.unlimited,
        team_cap: spend.unlimited,
        max_per_thread: proxy.default_max_per_thread,
        max_uploads: proxy.default_max_uploads,
        upload_timeout_ms: proxy.default_upload_timeout_ms,
        keeper: None,
        name: None,
      )),
    )
  let port = 40_000 + n() % 4000
  let assert Ok(Nil) =
    sandbox_http.start("127.0.0.1", port, [
      tunnel.route(tunnels),
      proxy.route(p),
    ])
  let url = "http://127.0.0.1:" <> int.to_string(port)
  Bridge(
    root:,
    url:,
    port:,
    wiring: launcher.Wiring(
      tunnels:,
      proxy: p,
      spec: settings(url),
      hello_timeout_ms: 1000,
    ),
  )
}

/// Whether the proxy lets `key`'s token through.
fn allowed(b: Bridge, key: String) -> Bool {
  let assert Ok(conn) = gun.connect_tcp("127.0.0.1", b.port, False, 2000)
  let assert Ok(response) =
    gun.request(
      conn,
      http.Post,
      "/proxy/" <> key <> "/v1/chat/completions",
      [
        #("authorization", "Bearer " <> proxy.token(secret, key)),
        #("content-type", "application/json"),
        #("content-length", "2"),
      ],
      <<"{}":utf8>>,
      5000,
    )
  gun.close(conn)
  response.status != 403
}

/// Dial `key`'s tunnel and say hello, as crush does.
fn dial_in(b: Bridge, key: String) -> Nil {
  let assert Ok(req) = request.to(b.url <> "/tunnel/" <> key <> "/control")
  let req =
    request.set_header(
      req,
      "authorization",
      "Bearer " <> tunnel.token(secret, key),
    )
  let assert Ok(started) =
    stratus.new(req, Nil)
    |> stratus.on_message(fn(state, message, conn) {
      case message {
        stratus.User(text) -> {
          let assert Ok(Nil) = stratus.send_text_message(conn, text)
          Nil
        }
        _ -> Nil
      }
      stratus.continue(state)
    })
    |> stratus.start
  let hello =
    json.object([
      #("op", json.string("hello")),
      #("v", json.int(1)),
      #("crush", json.string("fake")),
    ])
  process.send(started.data, stratus.to_user_message(json.to_string(hello)))
}

/// A backend that records what it is asked, under `root`.
fn recording(
  b: Bridge,
  calls: Subject(String),
  start: fn(String) -> Result(Nil, String),
  stop: fn(String) -> Result(Nil, String),
) -> backend.Backend {
  backend.Backend(
    root: b.root,
    home: spec.Contained,
    prepare: fn(s: spec.Spec) {
      process.send(calls, "prepare " <> s.key)
      Ok(Nil)
    },
    start: fn(s: spec.Spec) {
      process.send(calls, "start " <> s.key)
      start(s.key)
    },
    alive: fn(_) { True },
    stop: fn(key) {
      process.send(calls, "stop " <> key)
      stop(key)
    },
    remove: fn(key) {
      process.send(calls, "remove " <> key)
      Ok(Nil)
    },
    exec: None,
    exists: fn(key) { file_exists(b.root <> "/" <> key <> "/work") },
    running: fn() { Ok([]) },
    post_mortem: fn(_) { post_mortem.Unknown("test") },
  )
}

fn drain(calls: Subject(String), acc: List(String)) -> List(String) {
  case process.receive(calls, 0) {
    Ok(call) -> drain(calls, [call, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

fn ok(_: String) -> Result(Nil, String) {
  Ok(Nil)
}

/// The operator's Honcho settings reach only the self-host workspace's
/// agents.
pub fn honcho_settings_reach_only_the_own_workspace_test() {
  let s =
    spec.Settings(..settings("http://x"), own_team: "T1", own_env: [
      "HONCHO_API_KEY=hk-secret",
    ])
  let has = fn(key, home) {
    spec.build(s, "/tmp", key, home).env
    |> list.contains("HONCHO_API_KEY=hk-secret")
  }
  let assert True = has("T1-C1-1.0", spec.Contained)
  let assert True = has("T1-C1-1.0", spec.Beside)
  let assert False = has("T2-C1-1.0", spec.Contained)
  let assert False = has("C1-1.0", spec.Contained)
  let assert [] = spec.team_env(spec.Settings(..s, own_team: ""), "-C1-1.0")
}

pub fn key_env_has_tokens_and_no_crush_hyper_test() {
  let url = "http://172.30.0.1:7469"
  let env = spec.key_env(settings(url), "C1-1.0")
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
    list.contains(env, "CRUSHLING_MCP_TOKEN=" <> mcp.token(secret, "C1-1.0"))
  // The file helpers' bridge URL, exactly once.
  let assert ["CRUSHLING_BRIDGE_URL=" <> bridge_url] =
    list.filter(env, string.starts_with(_, "CRUSHLING_BRIDGE_URL="))
  let assert True = bridge_url == url
  let assert False = list.any(env, string.starts_with(_, "CRUSH_HYPER_"))
  // The org's key never reaches an agent.
  let assert False = list.any(env, string.contains(_, "org-key"))
}

pub fn a_spec_lays_out_each_home_test() {
  let s = settings("http://172.30.0.1:7469")
  let contained = spec.build(s, "/r", "C1-1.0", spec.Contained)
  let assert "/workspace" = contained.workdir
  let assert "/r/C1-1.0/work" = contained.host_work
  let assert True = list.contains(contained.env, "HOME=/workspace/.home")
  let assert [#("/r/C1-1.0/work/.home/.local/share/crush/crush.json", _)] =
    contained.files
  let beside = spec.build(s, "/r", "C1-1.0", spec.Beside)
  let assert "/r/C1-1.0/work" = beside.workdir
  let assert False = list.any(beside.env, string.starts_with(_, "HOME="))
  let assert True =
    list.contains(beside.env, "CRUSH_GLOBAL_DATA=/r/C1-1.0/home/data")
  let assert "ws://172.30.0.1:7469/tunnel/C1-1.0" = beside.dial_url
}

pub fn a_launch_opens_allows_and_waits_for_hello_test() {
  let b = bridge("launch")
  let calls = process.new_subject()
  let key = "C1-" <> int.to_string(n())
  let l =
    launcher.new(
      b.wiring,
      recording(
        b,
        calls,
        fn(key) {
          dial_in(b, key)
          Ok(Nil)
        },
        ok,
      ),
    )
  let assert Ok(launched) = l.launch(key)
  let assert True = launched.socket == tunnel.shim_path(b.root, key)
  let assert "/workspace" = launched.root
  let assert True = tunnel.dialed(b.wiring.tunnels, key)
  let assert True = allowed(b, key)
  let assert ["prepare " <> _, "start " <> _] = drain(calls, [])
  // A stop says bye, stops, closes the tunnel and disallows the token.
  let assert Ok(Nil) = l.stop(key)
  let assert ["stop " <> _] = drain(calls, [])
  let assert False = tunnel.dialed(b.wiring.tunnels, key)
  let assert False = allowed(b, key)
}

pub fn a_hello_timeout_stops_and_cleans_up_test() {
  let b = bridge("timeout")
  let calls = process.new_subject()
  let l = launcher.new(b.wiring, recording(b, calls, ok, ok))
  let assert Error(reason) = l.launch("C1-1.0")
  let assert True = string.contains(reason, "did not dial in within 1000ms")
  let assert ["prepare C1-1.0", "start C1-1.0", "stop C1-1.0"] =
    drain(calls, [])
  let assert Error("no tunnel for C1-1.0") =
    tunnel.await_hello(b.wiring.tunnels, "C1-1.0", 10)
  let assert False = allowed(b, "C1-1.0")
}

pub fn a_failed_prepare_touches_nothing_test() {
  let b = bridge("prepare-fails")
  let calls = process.new_subject()
  let l =
    launcher.new(
      b.wiring,
      backend.Backend(..recording(b, calls, ok, ok), prepare: fn(_) {
        Error("disk full")
      }),
    )
  let assert Error("disk full") = l.launch("C1-1.0")
  let assert [] = drain(calls, [])
  let assert Error("no tunnel for C1-1.0") =
    tunnel.await_hello(b.wiring.tunnels, "C1-1.0", 10)
}

pub fn a_failed_start_still_stops_test() {
  let b = bridge("start-fails")
  let calls = process.new_subject()
  let l =
    launcher.new(
      b.wiring,
      recording(b, calls, fn(_) { Error("timed out talking to docker") }, ok),
    )
  let assert Error(reason) = l.launch("C1-1.0")
  let assert True = string.contains(reason, "timed out talking to docker")
  // A start that failed doesn't prove nothing started.
  let assert ["prepare C1-1.0", "start C1-1.0", "stop C1-1.0"] =
    drain(calls, [])
  let assert False = string.contains(reason, "cleanup failed")
  let assert False = allowed(b, "C1-1.0")
}

pub fn cleanup_failures_are_reported_test() {
  let b = bridge("cleanup-fails")
  let calls = process.new_subject()
  let l =
    launcher.new(
      b.wiring,
      recording(b, calls, fn(_) { Error("no") }, fn(_) {
        Error("cannot reach docker")
      }),
    )
  let assert Error(reason) = l.launch("C1-1.0")
  let assert True =
    string.contains(reason, "cleanup failed: cannot reach docker")
  // The tunnel and token are undone all the same.
  let assert False = allowed(b, "C1-1.0")
  let assert Error(_) = l.stop("C1-1.0")
}

pub fn a_crush_that_exits_fails_the_launch_at_once_test() {
  let b = bridge("exits")
  let calls = process.new_subject()
  let l =
    launcher.new(
      b.wiring,
      backend.Backend(..recording(b, calls, ok, ok), alive: fn(_) { False }),
    )
  let assert Error(reason) = l.launch("C1-1.0")
  let assert True = string.contains(reason, "exited")
}

/// Errors from the docker backend name the trouble, never a token.
pub fn docker_errors_carry_no_tokens_test() {
  let b = bridge("docker")
  let policy =
    sandbox.Policy(
      socket: b.root <> "/no-docker.sock",
      image: "crushling-sandbox:latest",
      runtime: "runsc",
      network: "sbx-egress",
      cpus: "2",
      memory: "4g",
      pids: 1024,
      uid: 970,
      gid: 970,
      root: b.root,
      crush: "",
      dns: [],
      spec: b.wiring.spec,
    )
  let l = launcher.new(b.wiring, backend.docker(policy))
  let assert Error(reason) = l.launch("C1-1.0")
  let assert True = string.contains(reason, "docker is unreachable")
  let assert False = string.contains(reason, tunnel.token(secret, "C1-1.0"))
  let assert False = string.contains(reason, proxy.token(secret, "C1-1.0"))
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

fn wait_for(path: String, tries: Int) -> Result(Nil, String) {
  case file_exists(path), tries {
    True, _ -> {
      // Give the stand-in a moment to finish writing.
      process.sleep(50)
      Ok(Nil)
    }
    False, 0 -> Error("never wrote " <> path)
    False, _ -> {
      process.sleep(50)
      wait_for(path, tries - 1)
    }
  }
}

pub fn local_launch_dials_with_the_thread_env_test() {
  let b = bridge("local")
  let dir = b.root
  let crush = fake_crush(dir)
  let key = "C1-" <> int.to_string(n())
  let data = dir <> "/" <> key <> "/home/data"
  // The stand-in can't dial, so the test does once it has started.
  process.spawn(fn() {
    let assert Ok(Nil) = wait_for(data <> "/env.txt", 100)
    dial_in(b, key)
  })
  let l = launcher.new(b.wiring, backend.local(dir, crush))
  let assert Ok(launched) = l.launch(key)
  // Stopped whatever happens, so a failure leaves no stand-in running.
  use <-
    guarded(_, fn() {
      let _ = l.stop(key)
      Nil
    })
  let assert Ok(pid) = read_file(dir <> "/" <> key <> "/server.pid")
  // Its identity: pid, start time, and the exact dial URL with the key.
  let assert [pid_line, started, dial] = string.split(string.trim(pid), "\n")
  let assert Ok(_) = int.parse(pid_line)
  let assert True = started != ""
  let assert True = dial == tunnel.dial_url(b.url, key)
  let assert True = launched.socket == tunnel.shim_path(dir, key)
  let assert True = launched.root == dir <> "/" <> key <> "/work"
  let assert Ok(args) = read_file(data <> "/args.txt")
  let assert True =
    string.trim(args) == "server --dial " <> tunnel.dial_url(b.url, key)
  let assert Ok(env) = read_file(data <> "/env.txt")
  let env = string.split(env, "\n")
  let assert True =
    list.any(env, string.starts_with(_, "CRUSH_SERVER_DIAL_TOKEN="))
  let assert True =
    list.contains(env, "HYPER_URL=" <> b.url <> "/proxy/" <> key)
  let assert True = list.any(env, string.starts_with(_, "HYPER_API_KEY="))
  let assert True = list.contains(env, "CRUSH_SERVER_IDLE_TIMEOUT=31536000")
  // Even when the bridge itself has them.
  let assert False = list.any(env, string.starts_with(_, "CRUSH_HYPER_"))
  let assert Ok(config) = read_file(data <> "/crush.json")
  let assert False = string.contains(config, "api_key")
  let assert True = allowed(b, key)
  let assert Ok(Nil) = l.stop(key)
  let assert False = allowed(b, key)
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
  let b = bridge("local-exit")
  let l = launcher.new(b.wiring, backend.local(b.root, "/usr/bin/false"))
  let assert Error(reason) = l.launch("C1-2.0")
  let assert True = string.contains(reason, "exited")
  let assert False = allowed(b, "C1-2.0")
}

pub fn a_crush_that_cannot_start_is_rolled_back_test() {
  let b = bridge("no-binary")
  let l =
    launcher.new(b.wiring, backend.local(b.root, b.root <> "/no-such-crush"))
  let assert Error(reason) = l.launch("C1-3.0")
  let assert True = string.contains(reason, "not an executable")
  let assert False = allowed(b, "C1-3.0")
  let assert Error("no tunnel for C1-3.0") =
    tunnel.await_hello(b.wiring.tunnels, "C1-3.0", 10)
}

pub fn crush_config_names_hyper_without_a_key_test() {
  let url = "http://172.30.0.1:7469"
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

/// A thread moving to a key with its workspace in it: whatever ran under
/// the old key is removed, not left running, and the directory moves.
pub fn rekey_removes_the_old_agent_and_moves_the_directory_test() {
  let b = bridge("rekey-" <> sys.uuid())
  let dir = b.root
  let calls = process.new_subject()
  let l = launcher.new(b.wiring, recording(b, calls, ok, ok))
  let assert Ok(Nil) = mkdir_p(dir <> "/C1-1.0/work")
  let assert Ok(Nil) = write_private(dir <> "/C1-1.0/work/notes.txt", "kept")
  let assert Ok(Nil) = l.rekey("C1-1.0", "T1-C1-1.0")
  let assert ["remove C1-1.0"] = drain(calls, [])
  let assert True = l.exists("T1-C1-1.0")
  let assert False = l.exists("C1-1.0")
  let assert Ok("kept") = read_file(dir <> "/T1-C1-1.0/work/notes.txt")
  // Nothing left to move is fine.
  let assert Ok(Nil) = l.rekey("C1-1.0", "T1-C1-1.0")
  // A new key that already exists is never overwritten.
  let assert Ok(Nil) = mkdir_p(dir <> "/C3-1.0/work")
  let assert Ok(Nil) = mkdir_p(dir <> "/T1-C3-1.0/work")
  let assert Error(_) = l.rekey("C3-1.0", "T1-C3-1.0")
}

/// Forgetting a thread removes its directory and only that: a key that
/// could reach outside the instance root is refused.
pub fn forget_removes_only_the_threads_dir_test() {
  let b = bridge("forget")
  let dir = b.root
  let l = launcher.new(b.wiring, backend.local(dir, "/usr/bin/false"))
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
