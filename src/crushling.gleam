//// crushling: a Crush agent per Slack thread.
////
////     gleam run
////
//// Settings come from the environment or `./.env`:
////
//// | Variable | Meaning |
//// |---|---|
//// | `SLACK_BOT_TOKEN` | `xoxb-` token for the Web API |
//// | `SLACK_APP_TOKEN` | `xapp-` token for Socket Mode |
//// | `CRUSHLING_ALLOWED_USERS` | comma-separated Slack user ids who may use it |
//// | `CRUSHLING_BACKEND` | `claude` (default), `hyper`, or `hyper-key` |
//// | `CRUSHLING_LOGIN` | the backend's login crush.json; default `~/.local/state/crushling/<claude\|hyper>/crush.json` |
//// | `CRUSH_HYPER_API_KEY` | the key, for `hyper-key` |
//// | `CRUSHLING_LARGE`, `CRUSHLING_SMALL` | models |
//// | `CRUSHLING_CLAUDE_VERSION` | Claude Code version to present; default the installed `claude`, else crush's floor |
//// | `CRUSHLING_MODE` | `sysadmin` (default: no permission prompts and no blocked commands) or `yolo` |
//// | `CRUSHLING_LAUNCHER` | `docker` (default) or `local`, which runs agents unsandboxed as you |
//// | `CRUSHLING_ROOT` | where thread workspaces live; default `~/.local/state/crushling/threads` |
//// | `CRUSHLING_IDLE_MINUTES` | idle time before a thread's agent is stopped; default 15 |
//// | `CRUSHLING_IMAGE`, `CRUSHLING_RUNTIME`, `CRUSHLING_NETWORK` | for `docker`; defaults `crushling-sandbox:latest`, `runsc-uds`, `sbx-egress` |

import crushling/credentials
import crushling/crush/client
import crushling/launcher
import crushling/provider
import crushling/registry
import crushling/sandbox
import crushling/socket
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import gleam/string
import slackline
import slackline/api/auth
import slackline/httpc

@external(erlang, "crushling_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "crushling_ffi", "expand_home")
fn expand_home(path: String) -> String

@external(erlang, "crushling_ffi", "claude_version")
fn installed_claude_version() -> String

@external(erlang, "crushling_ffi", "exec")
fn exec(
  program: String,
  args: List(String),
  timeout_ms: Int,
) -> Result(#(Int, String), String)

fn setting(name: String, default: String) -> String {
  getenv(name) |> result.unwrap(default)
}

fn required(name: String) -> Result(String, String) {
  getenv(name) |> result.replace_error(name <> " is not set")
}

pub fn main() -> Nil {
  case start() {
    Ok(Nil) -> Nil
    Error(reason) -> {
      io.println_error("crushling: " <> reason)
      halt(1)
    }
  }
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

fn start() -> Result(Nil, String) {
  use bot_token <- result.try(required("SLACK_BOT_TOKEN"))
  use app_token <- result.try(required("SLACK_APP_TOKEN"))
  use allowed <- result.try(allowed_users())
  use backend <- result.try(backend())
  use mode <- result.try(case setting("CRUSHLING_MODE", "sysadmin") {
    "sysadmin" -> Ok(client.Sysadmin)
    "yolo" -> Ok(client.Yolo)
    other -> Error("CRUSHLING_MODE is " <> other <> "; use sysadmin or yolo")
  })
  use idle_minutes <- result.try(
    int.parse(setting("CRUSHLING_IDLE_MINUTES", "15"))
    |> result.replace_error("CRUSHLING_IDLE_MINUTES is not a number"),
  )

  let client = slackline.new(bot_token)
  use me <- result.try(
    auth.test_()
    |> httpc.send(client)
    |> result.map_error(fn(error) {
      "auth.test: " <> slackline.describe_error(error)
    }),
  )

  let creds = case provider.login(backend) {
    Some(login) ->
      credentials.start(login)
      |> result.map(Some)
      |> result.map_error(fn(error) { "credentials: " <> string.inspect(error) })
    None -> Ok(None)
  }
  use creds <- result.try(creds)

  let root =
    expand_home(setting("CRUSHLING_ROOT", "~/.local/state/crushling/threads"))
  use launcher <- result.try(launcher_for(root, backend, creds))

  use registry <- result.try(
    registry.start(registry.Config(
      launcher:,
      client:,
      bot_user: me.user_id,
      allowed:,
      idle_ms: idle_minutes * 60_000,
      flush_ms: 1000,
      mode:,
    ))
    |> result.map_error(fn(error) { "registry: " <> string.inspect(error) }),
  )

  io.println(
    "crushling: connected as "
    <> me.user
    <> " ("
    <> me.user_id
    <> ") in "
    <> me.team
    <> ", "
    <> int.to_string(set.size(allowed))
    <> " allowed users",
  )
  socket.run(app_token, socket.router(registry, me.user_id))
  Ok(Nil)
}

fn allowed_users() -> Result(set.Set(String), String) {
  let users =
    setting("CRUSHLING_ALLOWED_USERS", "")
    |> string.split(",")
    |> list.map(string.trim)
    |> list.filter(fn(user) { user != "" })
  case users {
    // An agent in YOLO mode that anyone in the workspace can drive is not a
    // default worth having.
    [] -> Error("CRUSHLING_ALLOWED_USERS is empty; list the Slack user ids")
    users -> Ok(set.from_list(users))
  }
}

fn login_path(name: String) -> Result(String, String) {
  let path =
    expand_home(setting(
      "CRUSHLING_LOGIN",
      "~/.local/state/crushling/" <> name <> "/crush.json",
    ))
  case sandbox.socket_ready(path) {
    True -> Ok(path)
    False ->
      Error(
        "no "
        <> name
        <> " login at "
        <> path
        <> "; seed one with CRUSH_GLOBAL_DATA=<its dir> crush login "
        <> name,
      )
  }
}

fn backend() -> Result(provider.Backend, String) {
  case setting("CRUSHLING_BACKEND", "claude") {
    "claude" -> {
      use login <- result.try(login_path("claude"))
      Ok(provider.Claude(
        login:,
        version: setting("CRUSHLING_CLAUDE_VERSION", installed_claude_version()),
        large: setting("CRUSHLING_LARGE", "claude-opus-4-8"),
        small: setting("CRUSHLING_SMALL", "claude-haiku-4-5-20251001"),
      ))
    }
    "hyper" -> {
      use login <- result.try(login_path("hyper"))
      Ok(provider.Hyper(
        login:,
        large: setting("CRUSHLING_LARGE", "deepseek-v4.1-flash"),
        small: setting("CRUSHLING_SMALL", "prism-flash"),
      ))
    }
    "hyper-key" -> {
      use key <- result.try(required("CRUSH_HYPER_API_KEY"))
      Ok(provider.HyperKey(
        key:,
        large: setting("CRUSHLING_LARGE", "deepseek-v4.1-flash"),
        small: setting("CRUSHLING_SMALL", "prism-flash"),
      ))
    }
    other ->
      Error(
        "CRUSHLING_BACKEND is " <> other <> "; use claude, hyper, or hyper-key",
      )
  }
}

fn launcher_for(
  root: String,
  backend: provider.Backend,
  creds: option.Option(process.Subject(credentials.Message)),
) -> Result(launcher.Launcher, String) {
  case setting("CRUSHLING_LAUNCHER", "docker") {
    "local" -> {
      io.println(
        "crushling: local launcher, agents run unsandboxed with your access",
      )
      Ok(launcher.local(root, backend, creds))
    }
    "docker" -> {
      use uid <- result.try(id("-u"))
      use gid <- result.try(id("-g"))
      let policy =
        sandbox.Policy(
          docker: "docker",
          image: setting("CRUSHLING_IMAGE", "crushling-sandbox:latest"),
          runtime: setting("CRUSHLING_RUNTIME", "runsc-uds"),
          network: setting("CRUSHLING_NETWORK", "sbx-egress"),
          cpus: "2",
          memory: "4g",
          pids: 1024,
          uid:,
          gid:,
          root:,
          env: provider.env(backend),
          crush_config: provider.config(backend),
        )
      Ok(launcher.docker(policy, creds))
    }
    other -> Error("CRUSHLING_LAUNCHER is " <> other <> "; use docker or local")
  }
}

fn id(flag: String) -> Result(Int, String) {
  case exec("id", [flag], 5000) {
    Ok(#(0, output)) ->
      int.parse(string.trim(output))
      |> result.replace_error("unexpected output from id " <> flag)
    _ -> Error("could not run id " <> flag)
  }
}
