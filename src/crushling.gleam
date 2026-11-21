//// crushling: a Crush agent per Slack thread.
////
////     gleam run
////
//// Settings come from the environment or `./.env`:
////
//// | Variable | Meaning |
//// |---|---|
//// | `SLACK_BOT_TOKEN` | `xoxb-` token for the Web API |
//// | `SLACK_SIGNING_SECRET` | the app's signing secret; set it to take events over HTTP at `/slack/events` |
//// | `CRUSHLING_EVENTS_BIND`, `CRUSHLING_EVENTS_PORT` | where that endpoint listens; default `127.0.0.1:7470` |
//// | `SLACK_APP_TOKEN` | `xapp-` token for Socket Mode; with both set, events are taken both ways |
//// | `CRUSHLING_ALLOWED_USERS` | comma-separated Slack user ids who may use it |
//// | `CRUSHLING_HYPER_KEY` | required: the org's Charm Hyper API key. Agents use Hyper through the bridge's inference proxy at `/proxy/<thread>` and never see the key |
//// | `CRUSHLING_LARGE`, `CRUSHLING_SMALL` | Hyper models; default `deepseek-v4.1-flash` and `prism-flash` |
//// | `CRUSHLING_MODE` | `sysadmin` (default: no permission prompts and no blocked commands) or `yolo` |
//// | `CRUSHLING_LAUNCHER` | `docker` (default) or `local`, which runs agents unsandboxed as you |
//// | `CRUSHLING_ROOT` | where thread workspaces live; default `~/.local/state/crushling/threads`. The tunnels' unix sockets live under it too, so it must be at most 79 bytes |
//// | `CRUSHLING_IDLE_MINUTES` | idle time before a thread's agent is stopped; default 15 |
//// | `CRUSHLING_SHUTDOWN_GRACE_SECONDS` | on SIGTERM, how long running turns get to finish before they are cancelled; default 60 |
//// | `CRUSHLING_CRUSH` | a `crush` with `--dial` to run instead of the default. For `docker`, a static linux binary on this machine to mount into each sandbox instead of the image's own; replacing the file (rename over it) gives new sandboxes the new one. For `local`, a binary for this machine instead of the `crush` on `PATH` |
//// | `CRUSHLING_DNS` | for `docker`, comma-separated nameservers for the sandboxes, since docker's DNS doesn't answer gVisor on a custom network; default `1.1.1.1,9.9.9.9`, or `off` for docker's own |
//// | `HONCHO_API_KEY`, `HONCHO_URL`, `HONCHO_WORKSPACE`, `HONCHO_PEER_NAME`, `HONCHO_AI_PEER` | passed into every sandbox, so agents remember across threads with Honcho |
//// | `CRUSHLING_IMAGE`, `CRUSHLING_RUNTIME`, `CRUSHLING_NETWORK` | for `docker`; defaults `crushling-sandbox:latest`, `runsc`, `sbx-egress` |
//// | `CRUSHLING_BRIDGE_PORT`, `CRUSHLING_BRIDGE_BIND` | where the sandbox server listens: the one port agents reach the bridge on, for their tunnels, the inference proxy and their Slack tools; default `7469` on `127.0.0.1`. `CRUSHLING_MCP_PORT` and `CRUSHLING_MCP_BIND` are the old names, still read |
//// | `CRUSHLING_BRIDGE_URL` | how an agent reaches that port; default `http://127.0.0.1:<port>` for `local`, required for `docker` (an address the sandbox network may reach, such as its gateway). `CRUSHLING_MCP_URL` is the old name, still read |
//// | `CRUSHLING_SANDBOX_CPUS`, `CRUSHLING_SANDBOX_MEMORY` | each docker sandbox's CPU and memory caps, as docker's `--cpus` and `--memory` take them; default `2` and `4g` |
//// | `CRUSHLING_HELLO_TIMEOUT_SECONDS` | how long a starting agent gets to dial in before it is stopped; default 30 |
//// | `CRUSHLING_TAILSCALE_CLIENT_ID`, `CRUSHLING_TAILSCALE_CLIENT_SECRET` | an OAuth client with the `auth_keys` scope that owns the tag; with it, people can put a thread's sandbox on the tailnet for a while |
//// | `CRUSHLING_TAILSCALE_API_KEY` | an API access token, instead of the OAuth client |
//// | `CRUSHLING_TAILSCALE_TAG` | the tag sandboxes join with; default `tag:crushling` |
//// | `CRUSHLING_TAILSCALE_TAILNET` | the tailnet's name; default `-`, the credential's own |
//// | `CRUSHLING_PROXY_UPSTREAM` | where the proxy sends requests; default `https://hyper.charm.land` |
//// | `CRUSHLING_PROXY_THREAD_CAP_USD`, `CRUSHLING_PROXY_THREAD_CAP_TOKENS` | what one thread may spend through the proxy, in US dollars and/or tokens; unset is unlimited |
//// | `CRUSHLING_PROXY_INSTANCE_CAP_USD`, `CRUSHLING_PROXY_INSTANCE_CAP_TOKENS` | the same for all threads together |

import crushling/crush/client
import crushling/events
import crushling/files
import crushling/launcher
import crushling/mcp
import crushling/provider
import crushling/proxy
import crushling/registry
import crushling/registry/tailnet
import crushling/sandbox
import crushling/sandbox_http
import crushling/slack_tools
import crushling/socket
import crushling/sys
import crushling/tailscale
import crushling/tunnel
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
import slackline/app
import slackline/httpc

@external(erlang, "crushling_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "crushling_ffi", "expand_home")
fn expand_home(path: String) -> String

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
  use delivery <- result.try(delivery())
  use allowed <- result.try(allowed_users())
  use mode <- result.try(case setting("CRUSHLING_MODE", "sysadmin") {
    "sysadmin" -> Ok(client.Sysadmin)
    "yolo" -> Ok(client.Yolo)
    other -> Error("CRUSHLING_MODE is " <> other <> "; use sysadmin or yolo")
  })
  use idle_minutes <- result.try(
    int.parse(setting("CRUSHLING_IDLE_MINUTES", "15"))
    |> result.replace_error("CRUSHLING_IDLE_MINUTES is not a number"),
  )

  let root =
    expand_home(setting("CRUSHLING_ROOT", "~/.local/state/crushling/threads"))
  use _ <- result.try(
    tunnel.check_root(root)
    |> result.map_error(fn(reason) { "CRUSHLING_ROOT: " <> reason }),
  )
  use secret <- result.try(mcp_secret(root))
  use proxy <- result.try(proxy_from_settings(secret))
  use tunnels <- result.try(tunnel.start(
    tunnel.Config(..tunnel.config(secret, root), on_event: log_tunnel_event),
  ))
  use port <- result.try(
    int.parse(fallback("CRUSHLING_BRIDGE_PORT", "CRUSHLING_MCP_PORT", "7469"))
    |> result.replace_error("CRUSHLING_BRIDGE_PORT is not a number"),
  )
  let local = setting("CRUSHLING_LAUNCHER", "docker") == "local"
  use bridge_url <- result.try(bridge_url(local, port))
  use hello_s <- result.try(
    int.parse(setting("CRUSHLING_HELLO_TIMEOUT_SECONDS", "30"))
    |> result.replace_error("CRUSHLING_HELLO_TIMEOUT_SECONDS is not a number"),
  )
  let bridge =
    launcher.bridge(
      url: bridge_url,
      secret:,
      tunnels:,
      proxy:,
      hello_timeout_ms: hello_s * 1000,
    )
  use launcher <- result.try(launcher_for(root, models(), bridge))
  let tailnet = tailnet(launcher)

  let client = slackline.new(bot_token)
  use me <- result.try(
    auth.test_()
    |> httpc.send(client)
    |> result.map_error(fn(error) {
      "auth.test: " <> slackline.describe_error(error)
    }),
  )

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
      stop_backoff_ms: registry.default_stop_backoff_ms,
      root:,
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
  let context =
    slack_tools.Context(
      client:,
      bot_user: me.user_id,
      lookup: fn(key) { process.call(registry, 5000, registry.Lookup(key, _)) },
      ask_tailnet: fn(key, reason) {
        process.call(registry, 5000, fn(reply) {
          registry.Tailnet(key, tailnet.Asked(reason, reply))
        })
      },
    )
  // Every agent reaches the bridge here: its tunnel, its inference, its
  // Slack tools and its files.
  let bind =
    fallback("CRUSHLING_BRIDGE_BIND", "CRUSHLING_MCP_BIND", "127.0.0.1")
  use _ <- result.try(
    sandbox_http.start(bind, port, [
      tunnel.route(tunnels),
      proxy.route(proxy),
      mcp.route(
        secret,
        slack_tools.tools(tailnet: tailnet != option.None),
        fn(key, name, arguments) {
          slack_tools.call(context, key, name, arguments)
        },
      ),
      files.route(secret, root, fn(key, name, contents, comment) {
        slack_tools.share(context, key, name, contents, comment)
      }),
    ]),
  )
  io.println(
    "crushling: sandbox server at "
    <> bind
    <> ":"
    <> int.to_string(port)
    <> ", reached by agents at "
    <> bridge_url,
  )

  let grace_s =
    int.parse(setting("CRUSHLING_SHUTDOWN_GRACE_SECONDS", "60"))
    |> result.unwrap(60)
  // Slack sends each event one way, so taking both while the app moves
  // from Socket Mode to HTTP loses nothing, and the registry drops repeats.
  use _ <- result.try(case delivery.http {
    option.None -> Ok(Nil)
    option.Some(Http(signing_secret:, bind:, port:)) -> {
      let router = socket.router(app.new(signing_secret), registry, me.user_id)
      use _ <- result.map(events.start(bind, port, router))
      io.println(
        "crushling: taking events at "
        <> bind
        <> ":"
        <> int.to_string(port)
        <> "/slack/events",
      )
    }
  })
  let socket =
    option.map(delivery.socket_mode, fn(app_token) {
      let router = socket.router(app.unverified(), registry, me.user_id)
      io.println("crushling: taking events over Socket Mode")
      process.spawn_unlinked(fn() { socket.run(app_token, router) })
    })

  let terminate = process.new_subject()
  use _ <- result.try(install_sigterm(terminate))
  let _ = process.receive_forever(terminate)

  // Take no new work, give running turns their grace period, then stop
  // every agent before exiting.
  io.println("crushling: shutting down")
  // Over HTTP the registry ignores new messages once it is draining.
  option.map(socket, process.kill)
  let done = process.new_subject()
  let grace_ms = grace_s * 1000
  process.send(registry, registry.Shutdown(grace_ms, done))
  // One deadline for all of it, from the registry's own timers.
  case process.receive(done, registry.shutdown_budget_ms(grace_ms)) {
    Ok(registry.Clean) -> {
      io.println("crushling: stopped")
      halt(0)
    }
    Ok(outcome) -> {
      io.println_error(
        "crushling: shutdown incomplete: " <> string.inspect(outcome),
      )
      halt(1)
    }
    Error(Nil) -> {
      io.println_error("crushling: shutdown timed out")
      halt(1)
    }
  }
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

/// A setting under its current name, else its old one.
fn fallback(name: String, old: String, default: String) -> String {
  case getenv(name) {
    Ok(value) -> value
    Error(Nil) -> setting(old, default)
  }
}

fn models() -> provider.Models {
  provider.Models(
    large: setting("CRUSHLING_LARGE", provider.default_large),
    small: setting("CRUSHLING_SMALL", provider.default_small),
  )
}

/// How agents reach the sandbox server. Sandboxes can't reach the host's
/// loopback, so docker has no default.
fn bridge_url(local: Bool, port: Int) -> Result(String, String) {
  let url = case getenv("CRUSHLING_BRIDGE_URL"), getenv("CRUSHLING_MCP_URL") {
    Ok(url), _ | Error(Nil), Ok(url) -> url
    Error(Nil), Error(Nil) -> ""
  }
  let url = case string.ends_with(url, "/") {
    True -> string.drop_end(url, 1)
    False -> url
  }
  case url, local {
    "off", _ ->
      Error(
        "CRUSHLING_BRIDGE_URL can no longer be off: agents dial the bridge there",
      )
    "", True -> Ok("http://127.0.0.1:" <> int.to_string(port))
    "", False ->
      Error(
        "CRUSHLING_BRIDGE_URL is not set; set it to an address of this machine the sandbox network may reach on the bridge port",
      )
    url, _ -> Ok(url)
  }
}

/// Whether a thread's crush is connected only matters to its launch, which
/// waits for it; the rest is for the log.
fn log_tunnel_event(event: tunnel.Event) -> Nil {
  case event {
    tunnel.Dialed(key) -> sys.info("crushling: " <> key <> " dialed in")
    tunnel.Undialed(key) -> sys.info("crushling: " <> key <> " hung up")
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
  models: provider.Models,
  bridge: launcher.Bridge,
) -> Result(launcher.Launcher, String) {
  let crush = setting("CRUSHLING_CRUSH", "")
  case setting("CRUSHLING_LAUNCHER", "docker") {
    "local" -> {
      io.println(
        "crushling: local launcher, agents run unsandboxed with your access",
      )
      Ok(launcher.local(root, crush, models, bridge))
    }
    "docker" -> {
      use uid <- result.try(id("-u"))
      use gid <- result.try(id("-g"))
      let policy =
        sandbox.Policy(
          docker: "docker",
          image: setting("CRUSHLING_IMAGE", "crushling-sandbox:latest"),
          runtime: setting("CRUSHLING_RUNTIME", "runsc"),
          network: setting("CRUSHLING_NETWORK", "sbx-egress"),
          cpus: setting("CRUSHLING_SANDBOX_CPUS", "2"),
          memory: setting("CRUSHLING_SANDBOX_MEMORY", "4g"),
          pids: 1024,
          uid:,
          gid:,
          root:,
          env: honcho_env(),
          crush_config: provider.config(models, bridge.url),
          crush:,
          dns: case setting("CRUSHLING_DNS", "1.1.1.1,9.9.9.9") {
            "off" -> []
            servers ->
              string.split(servers, ",")
              |> list.map(string.trim)
              |> list.filter(fn(server) { server != "" })
          },
          bridge_url: bridge.url,
        )
      Ok(launcher.docker(policy, bridge))
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

/// How Slack's events arrive.
/// How Slack's events arrive: over Socket Mode with an app-level token,
/// posted over HTTP and signed with the app's signing secret, or both.
type Delivery {
  Delivery(socket_mode: option.Option(String), http: option.Option(Http))
}

type Http {
  Http(signing_secret: String, bind: String, port: Int)
}

fn delivery() -> Result(Delivery, String) {
  use http <- result.try(case getenv("SLACK_SIGNING_SECRET") {
    Error(Nil) -> Ok(option.None)
    Ok(signing_secret) ->
      int.parse(setting("CRUSHLING_EVENTS_PORT", "7470"))
      |> result.replace_error("CRUSHLING_EVENTS_PORT is not a number")
      |> result.map(fn(port) {
        option.Some(Http(
          signing_secret:,
          bind: setting("CRUSHLING_EVENTS_BIND", "127.0.0.1"),
          port:,
        ))
      })
  })
  case getenv("SLACK_APP_TOKEN"), http {
    Error(Nil), option.None ->
      Error(
        "set SLACK_SIGNING_SECRET to take events over HTTP, or SLACK_APP_TOKEN for Socket Mode",
      )
    app_token, http -> Ok(Delivery(option.from_result(app_token), http))
  }
}

/// Honcho settings handed to every sandbox, so agents share one memory.
const honcho_settings = [
  "HONCHO_API_KEY", "HONCHO_URL", "HONCHO_WORKSPACE", "HONCHO_PEER_NAME",
  "HONCHO_AI_PEER",
]

fn honcho_env() -> List(String) {
  list.filter_map(honcho_settings, fn(name) {
    getenv(name) |> result.map(fn(value) { name <> "=" <> value })
  })
}

/// The inference proxy, with the org's key from `CRUSHLING_HYPER_KEY`.
/// Errors name the setting, never its value.
fn proxy_from_settings(secret: String) -> Result(proxy.Proxy, String) {
  use org_key <- result.try(case getenv("CRUSHLING_HYPER_KEY") {
    Ok(key) if key != "" -> Ok(key)
    _ ->
      Error(
        "CRUSHLING_HYPER_KEY is not set; agents use Hyper through the bridge with the org's key",
      )
  })
  let cap = fn(scope) {
    let name = fn(unit) { "CRUSHLING_PROXY_" <> scope <> "_CAP_" <> unit }
    proxy.parse_cap(setting(name("TOKENS"), ""), setting(name("USD"), ""))
    |> result.map_error(fn(error) {
      case error {
        proxy.BadTokens -> name("TOKENS") <> " is not a whole number"
        proxy.BadUsd -> name("USD") <> " is not a dollar amount"
      }
    })
  }
  use thread_cap <- result.try(cap("THREAD"))
  use instance_cap <- result.try(cap("INSTANCE"))
  proxy.start(proxy.Config(
    secret:,
    org_key:,
    upstream: setting("CRUSHLING_PROXY_UPSTREAM", proxy.default_upstream),
    thread_cap:,
    instance_cap:,
    max_per_thread: proxy.default_max_per_thread,
    max_uploads: proxy.default_max_uploads,
    upload_timeout_ms: proxy.default_upload_timeout_ms,
  ))
  |> result.map_error(fn(reason) { "CRUSHLING_PROXY_UPSTREAM " <> reason })
}
