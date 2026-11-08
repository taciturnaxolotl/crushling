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
//// | `CRUSHLING_EXTRA_BACKENDS` | comma-separated extra backends (`claude`, `hyper`, `hyper-key`) whose models agents can pick for subagents; each login lives at its default path |
//// | `CRUSHLING_CLAUDE_VERSION` | Claude Code version to present; default the installed `claude`, else crush's floor |
//// | `CRUSHLING_MODE` | `sysadmin` (default: no permission prompts and no blocked commands) or `yolo` |
//// | `CRUSHLING_LAUNCHER` | `docker` (default) or `local`, which runs agents unsandboxed as you |
//// | `CRUSHLING_ROOT` | where thread workspaces live; default `~/.local/state/crushling/threads` |
//// | `CRUSHLING_IDLE_MINUTES` | idle time before a thread's agent is stopped; default 15 |
//// | `CRUSHLING_SHUTDOWN_GRACE_SECONDS` | on SIGTERM, how long running turns get to finish before they are cancelled; default 60 |
//// | `CRUSHLING_IMAGE`, `CRUSHLING_RUNTIME`, `CRUSHLING_NETWORK` | for `docker`; defaults `crushling-sandbox:latest`, `runsc-uds`, `sbx-egress` |
//// | `CRUSHLING_MCP_PORT`, `CRUSHLING_MCP_BIND` | where the agents' Slack tools are served; default `7469` on `127.0.0.1` |
//// | `CRUSHLING_TAILSCALE_CLIENT_ID`, `CRUSHLING_TAILSCALE_CLIENT_SECRET` | an OAuth client with the `auth_keys` scope that owns the tag; with it, people can put a thread's sandbox on the tailnet for a while |
//// | `CRUSHLING_TAILSCALE_API_KEY` | an API access token, instead of the OAuth client |
//// | `CRUSHLING_TAILSCALE_TAG` | the tag sandboxes join with; default `tag:crushling` |
//// | `CRUSHLING_TAILSCALE_TAILNET` | the tailnet's name; default `-`, the credential's own |
//// | `CRUSHLING_MCP_URL` | how an agent reaches them; default `http://127.0.0.1:<port>` for `local`, none for `docker` (set it to an address the sandbox network may reach, or `off`) |

import crushling/credentials
import crushling/crush/client
import crushling/launcher
import crushling/mcp
import crushling/provider
import crushling/registry
import crushling/registry/tailnet
import crushling/sandbox
import crushling/slack_tools
import crushling/socket
import crushling/sys
import crushling/tailscale
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option
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

  use extras <- result.try(extra_backends())
  use creds <- result.try(
    provider.logins(backend, extras)
    |> list.try_map(fn(login) {
      credentials.start(login)
      |> result.map_error(fn(error) { "credentials: " <> string.inspect(error) })
    }),
  )

  let root =
    expand_home(setting("CRUSHLING_ROOT", "~/.local/state/crushling/threads"))
  use secret <- result.try(mcp_secret(root))
  use port <- result.try(
    int.parse(setting("CRUSHLING_MCP_PORT", "7469"))
    |> result.replace_error("CRUSHLING_MCP_PORT is not a number"),
  )
  let local = setting("CRUSHLING_LAUNCHER", "docker") == "local"
  let mcp_url = case getenv("CRUSHLING_MCP_URL"), local {
    Ok("off"), _ -> ""
    Ok(url), _ -> url
    Error(Nil), True -> "http://127.0.0.1:" <> int.to_string(port)
    Error(Nil), False -> ""
  }
  let bridge = case mcp_url {
    "" -> launcher.no_bridge()
    url -> launcher.Bridge(url:, env: fn(key) { mcp.env(secret, key) })
  }
  use launcher <- result.try(launcher_for(root, backend, extras, creds, bridge))
  let tailnet = tailnet(launcher)

  use registry <- result.try(
    registry.start(registry.Config(
      launcher:,
      client:,
      token: bot_token,
      bot_user: me.user_id,
      team: me.team_id,
      allowed:,
      idle_ms: idle_minutes * 60_000,
      flush_ms: 1000,
      mode:,
      tailnet:,
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
  use _ <- result.try(case mcp_url {
    "" -> {
      io.println(
        "crushling: Slack tools off; set CRUSHLING_MCP_URL so agents can reach them",
      )
      Ok(Nil)
    }
    url -> {
      let context =
        slack_tools.Context(
          client:,
          bot_user: me.user_id,
          launcher:,
          lookup: fn(key) {
            process.call(registry, 5000, registry.Lookup(key, _))
          },
          ask_tailnet: fn(key, reason) {
            process.call(registry, 5000, fn(reply) {
              registry.Tailnet(key, tailnet.Asked(reason, reply))
            })
          },
        )
      use _ <- result.map(
        mcp.start(
          setting("CRUSHLING_MCP_BIND", "127.0.0.1"),
          port,
          secret,
          slack_tools.tools(tailnet: tailnet != option.None),
          fn(key, name, arguments) {
            slack_tools.call(context, key, name, arguments)
          },
        ),
      )
      io.println("crushling: Slack tools at " <> url)
    }
  })

  let grace_s =
    int.parse(setting("CRUSHLING_SHUTDOWN_GRACE_SECONDS", "60"))
    |> result.unwrap(60)
  let router = socket.router(registry, me.user_id)
  let socket = process.spawn_unlinked(fn() { socket.run(app_token, router) })

  let terminate = process.new_subject()
  use _ <- result.try(install_sigterm(terminate))
  let _ = process.receive_forever(terminate)

  // Take no new work, give running turns their grace period, then stop
  // every agent before exiting.
  io.println("crushling: shutting down")
  process.kill(socket)
  let done = process.new_subject()
  process.send(registry, registry.Shutdown(grace_s * 1000, done))
  let _ = process.receive(done, grace_s * 1000 + 60_000)
  io.println("crushling: stopped")
  halt(0)
  Ok(Nil)
}

@external(erlang, "crushling_signal", "install")
fn install_sigterm(subject: process.Subject(Nil)) -> Result(Nil, String)

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

fn login_path(name: String, main: Bool) -> Result(String, String) {
  let default = "~/.local/state/crushling/" <> name <> "/crush.json"
  let path =
    expand_home(case main {
      True -> setting("CRUSHLING_LOGIN", default)
      False -> default
    })
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
  backend_named(setting("CRUSHLING_BACKEND", "claude"), True)
}

/// Providers the agents can also pick models from for subagents, from
/// `CRUSHLING_EXTRA_BACKENDS`.
fn extra_backends() -> Result(List(provider.Backend), String) {
  setting("CRUSHLING_EXTRA_BACKENDS", "")
  |> string.split(",")
  |> list.map(string.trim)
  |> list.filter(fn(name) { name != "" })
  |> list.try_map(fn(name) { backend_named(name, False) })
}

/// `main` is whether this is the main backend, which `CRUSHLING_LOGIN` and
/// the model settings apply to.
fn backend_named(name: String, main: Bool) -> Result(provider.Backend, String) {
  let login_path = fn(name) { login_path(name, main) }
  let model = fn(key, default) {
    case main {
      True -> setting(key, default)
      False -> default
    }
  }
  case name {
    "claude" -> {
      use login <- result.try(login_path("claude"))
      Ok(provider.Claude(
        login:,
        version: setting("CRUSHLING_CLAUDE_VERSION", installed_claude_version()),
        large: model("CRUSHLING_LARGE", "claude-opus-4-8"),
        small: model("CRUSHLING_SMALL", "claude-haiku-4-5-20251001"),
      ))
    }
    "hyper" -> {
      use login <- result.try(login_path("hyper"))
      Ok(provider.Hyper(
        login:,
        large: model("CRUSHLING_LARGE", "deepseek-v4.1-flash"),
        small: model("CRUSHLING_SMALL", "prism-flash"),
      ))
    }
    "hyper-key" -> {
      use key <- result.try(required("CRUSH_HYPER_API_KEY"))
      Ok(provider.HyperKey(
        key:,
        large: model("CRUSHLING_LARGE", "deepseek-v4.1-flash"),
        small: model("CRUSHLING_SMALL", "prism-flash"),
      ))
    }
    other ->
      Error(
        "backend " <> other <> " is unknown; use claude, hyper, or hyper-key",
      )
  }
}

@external(erlang, "crushling_ffi", "read_file")
fn read_file(path: String) -> Result(String, Nil)

@external(erlang, "crushling_ffi", "mkdir_p")
fn mkdir_p(path: String) -> Result(Nil, String)

@external(erlang, "crushling_ffi", "write_private")
fn write_private(path: String, content: String) -> Result(Nil, String)

/// The secret every thread's tool token is derived from, kept beside the
/// threads so tokens survive a restart.
fn mcp_secret(root: String) -> Result(String, String) {
  let path = root <> "/mcp-secret"
  case read_file(path) {
    Ok(secret) if secret != "" -> Ok(string.trim(secret))
    _ -> {
      let secret = sys.uuid() <> sys.uuid()
      use _ <- result.try(mkdir_p(root))
      use _ <- result.map(write_private(path, secret))
      secret
    }
  }
}

fn launcher_for(
  root: String,
  backend: provider.Backend,
  extras: List(provider.Backend),
  creds: launcher.Credentials,
  bridge: launcher.Bridge,
) -> Result(launcher.Launcher, String) {
  case setting("CRUSHLING_LAUNCHER", "docker") {
    "local" -> {
      io.println(
        "crushling: local launcher, agents run unsandboxed with your access",
      )
      Ok(launcher.local(root, backend, extras, creds, bridge))
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
          env: provider.env_for(backend, extras),
          crush_config: provider.config_for(backend, extras, bridge.url),
        )
      Ok(launcher.docker(policy, creds, bridge))
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

/// Tailnet access, when a Tailscale credential is set and agents run in
/// sandboxes.
fn tailnet(launcher: launcher.Launcher) -> option.Option(tailnet.Setup) {
  let credential = case
    getenv("CRUSHLING_TAILSCALE_CLIENT_ID"),
    getenv("CRUSHLING_TAILSCALE_CLIENT_SECRET"),
    getenv("CRUSHLING_TAILSCALE_API_KEY")
  {
    Ok(id), Ok(secret), _ -> Ok(tailscale.OAuthClient(id:, secret:))
    _, _, Ok(key) -> Ok(tailscale.ApiKey(key))
    _, _, _ -> Error(Nil)
  }
  case credential, launcher.run_in_sandbox {
    Ok(credential), option.Some(run) ->
      option.Some(tailnet.Setup(
        api: tailscale.Config(
          credential:,
          tag: setting("CRUSHLING_TAILSCALE_TAG", "tag:crushling"),
          tailnet: setting("CRUSHLING_TAILSCALE_TAILNET", "-"),
        ),
        run:,
      ))
    _, _ -> option.None
  }
}
