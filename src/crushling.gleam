//// crushling: a Crush agent per Slack thread.
////
////     gleam run
////
//// Settings come from the environment or `./.env`:
////
//// | Variable | Meaning |
//// |---|---|
//// | `SLACK_BOT_TOKEN` | self-host: the `xoxb-` token of your workspace. On start it is put in the store as that workspace (from auth.test), and the meta and link files from before the store are imported once. Required unless the OAuth install is on |
//// | `SLACK_SIGNING_SECRET` | the app's signing secret; set it to take events over HTTP at `/slack/events` |
//// | `CRUSHLING_EVENTS_BIND`, `CRUSHLING_EVENTS_PORT` | where that endpoint, and the OAuth install, listen; default `127.0.0.1:7470` |
//// | `SLACK_APP_TOKEN` | `xapp-` token for Socket Mode; with both set, events are taken both ways. One app-level token serves every workspace the app is installed in |
//// | `CRUSHLING_ALLOWED_USERS` | comma-separated Slack user ids who may use it, in the `SLACK_BOT_TOKEN` workspace; required with that token. `*` (alone or among ids) means everyone in the workspace: full members only, checked with users.info and kept 10 minutes, so not guests, people from other workspaces in shared channels, bots or deactivated accounts. A workspace's `allowed_users` setting in the store wins, and takes `*` too |
//// | `CRUSHLING_ADMINS` | comma-separated Slack user ids who may approve tailnet access in that workspace; `*` is refused. Default: the ids in `CRUSHLING_ALLOWED_USERS`, or nobody when that is `*`. A workspace's `admins` setting in the store wins |
//// | `SLACK_CLIENT_ID`, `SLACK_CLIENT_SECRET`, `CRUSHLING_PUBLIC_URL` | the OAuth install, on only when all three are set: `<public url>/slack/install` starts it and Slack returns to `<public url>/slack/oauth/callback` (add that redirect URL in the app's settings). Both are served on the events server. Until the app's public distribution is on, only its own workspace can install it |
//// | `CRUSHLING_STORE_KEY` | 32 bytes, base64: the key bot tokens are encrypted with in the store, `<root>/crushling.db`. Unset, one is made at `<root>/store-key` (mode 0600), like `<root>/mcp-secret`; back it up, since stored tokens can't be read without it |
//// | `CRUSHLING_HYPER_KEY` | required: the org's Charm Hyper API key; else `HYPER_API_KEY`, else `CRUSH_HYPER_API_KEY`. Agents use Hyper through the bridge's inference proxy at `/proxy/<thread>` and never see the key, nor the bridge's own `HYPER_*` settings |
//// | `CRUSHLING_LARGE`, `CRUSHLING_SMALL` | Hyper models; default `deepseek-v4.1-flash` and `prism-flash` |
//// | `CRUSHLING_MODE` | `sysadmin` (default: no permission prompts and no blocked commands) or `yolo` |
//// | `CRUSHLING_LAUNCHER` | `docker` (default) or `local`, which runs agents unsandboxed as you |
//// | `CRUSHLING_ROOT` | where thread workspaces live, one directory per thread key (`<team>-<channel>-<ts>`), beside the store `crushling.db`; default `~/.local/state/crushling/threads`. The tunnels' unix sockets live under it too, so it must be at most 79 bytes |
//// | `CRUSHLING_IDLE_MINUTES` | idle time before a thread's agent is stopped; default 15 |
//// | `CRUSHLING_SHUTDOWN_GRACE_SECONDS` | on SIGTERM, how long running turns get to finish before they are cancelled; default 60 |
//// | `CRUSHLING_CRUSH` | a `crush` with `--dial` to run instead of the default. For `docker`, a static linux binary on this machine to mount into each sandbox instead of the image's own; replacing the file (rename over it) gives new sandboxes the new one. For `local`, a binary for this machine instead of the `crush` on `PATH` |
//// | `CRUSHLING_DNS` | for `docker`, comma-separated nameservers for the sandboxes, since docker's DNS doesn't answer gVisor on a custom network; default `1.1.1.1,9.9.9.9`, or `off` for docker's own |
//// | `HONCHO_API_KEY`, `HONCHO_URL`, `HONCHO_WORKSPACE`, `HONCHO_PEER_NAME`, `HONCHO_AI_PEER` | passed into the sandboxes of the `SLACK_BOT_TOKEN` workspace only, so its agents remember across threads with Honcho; other workspaces get no memory settings yet |
//// | `CRUSHLING_IMAGE`, `CRUSHLING_RUNTIME`, `CRUSHLING_NETWORK` | for `docker`; defaults `crushling-sandbox:latest`, `runsc`, `sbx-egress` |
//// | `CRUSHLING_BRIDGE_PORT`, `CRUSHLING_BRIDGE_BIND` | where the sandbox server listens: the one port agents reach the bridge on, for their tunnels, the inference proxy and their Slack tools; default `7469` on `127.0.0.1`. `CRUSHLING_MCP_PORT` and `CRUSHLING_MCP_BIND` are the old names, still read |
//// | `CRUSHLING_BRIDGE_URL` | how an agent reaches that port; default `http://127.0.0.1:<port>` for `local`, required for `docker` (an address the sandbox network may reach, such as its gateway). `CRUSHLING_MCP_URL` is the old name, still read |
//// | `CRUSHLING_SANDBOX_CPUS`, `CRUSHLING_SANDBOX_MEMORY` | each docker sandbox's CPU and memory caps, as docker's `--cpus` and `--memory` take them; default `2` and `4g` |
//// | `CRUSHLING_HELLO_TIMEOUT_SECONDS` | how long a starting agent gets to dial in before it is stopped; default 30 |
//// | `CRUSHLING_TAILSCALE_CLIENT_ID`, `CRUSHLING_TAILSCALE_CLIENT_SECRET` | an OAuth client with the `auth_keys` scope that owns the tag; with it, people can put a thread's sandbox on the tailnet for a while |
//// | `CRUSHLING_TAILSCALE_API_KEY` | an API access token, instead of the OAuth client |
//// | `CRUSHLING_TAILSCALE_TAG` | the tag sandboxes join with; default `tag:crushling` |
//// | `CRUSHLING_TAILSCALE_TAILNET` | the tailnet's name; default `-`, the credential's own |
//// | `CRUSHLING_PROXY_UPSTREAM` | where the proxy sends requests; else `HYPER_URL`, else `https://hyper.charm.land` |
//// | `CRUSHLING_PROXY_THREAD_CAP_USD`, `CRUSHLING_PROXY_THREAD_CAP_TOKENS` | what one thread may spend through the proxy, in US dollars and/or tokens; unset is unlimited |
//// | `CRUSHLING_PROXY_INSTANCE_CAP_USD`, `CRUSHLING_PROXY_INSTANCE_CAP_TOKENS` | the same for all threads together |

import crushling/crush/client
import crushling/events
import crushling/files
import crushling/install
import crushling/instance
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
import crushling/store
import crushling/sys
import crushling/tailscale
import crushling/tunnel
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import slackline
import slackline/app

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
  use delivery <- result.try(delivery())
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
  use store <- result.try(open_store(root))
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
  // Self-host: the workspace of SLACK_BOT_TOKEN, seeded into the store.
  use env_team <- result.try(seed_env_team(store, root))
  let own_team = case env_team {
    option.Some(seeded) -> seeded.team.id
    option.None -> ""
  }
  use launcher <- result.try(launcher_for(root, models(), bridge, own_team))
  let tailnet = tailnet(launcher)

  use install_on <- result.try(install_settings())
  use _ <- result.try(case env_team, install_on {
    option.None, False ->
      Error(
        "SLACK_BOT_TOKEN is not set; set it, or SLACK_CLIENT_ID, SLACK_CLIENT_SECRET and CRUSHLING_PUBLIC_URL to install the app in workspaces",
      )
    _, _ -> Ok(Nil)
  })

  use teams <- result.try(
    instance.start(instance.Shared(
      launcher:,
      store:,
      root:,
      mode:,
      idle_ms: idle_minutes * 60_000,
      flush_ms: 1000,
      env_team: option.map(env_team, fn(seeded) { seeded.env }),
      tailnet:,
      client: slackline.new,
    )),
  )
  use _ <- result.try(case env_team {
    option.None -> Ok(Nil)
    option.Some(seeded) ->
      instance.start_team(teams, seeded.team) |> result.replace(Nil)
  })
  // Every other workspace that installed the app.
  use failed <- result.try(instance.start_stored(teams, store))
  list.each(failed, fn(failure) {
    io.println_error(
      "crushling: couldn't start workspace " <> failure.0 <> ": " <> failure.1,
    )
  })

  let context = instance.tools_context(teams, store)
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
  let find = instance.finder(teams)
  let install = case install_on {
    False -> option.None
    True ->
      option.Some(install.Config(
        client_id: setting("SLACK_CLIENT_ID", ""),
        client_secret: setting("SLACK_CLIENT_SECRET", ""),
        public_url: setting("CRUSHLING_PUBLIC_URL", ""),
        secret:,
        store:,
        slack: slackline.anonymous(),
        on_installed: fn(team) {
          instance.start_team(teams, team) |> result.replace(Nil)
        },
        env_team: option.map(env_team, fn(seeded) { seeded.team.id }),
      ))
  }
  // Slack sends each event one way, so taking both while the app moves
  // from Socket Mode to HTTP loses nothing, and the registry drops repeats.
  // The install is served on the same server.
  use _ <- result.try(case delivery.http, install {
    option.None, option.None -> Ok(Nil)
    http, install -> {
      let #(bind, port) = events_address(http)
      let router =
        option.map(http, fn(http: Http) {
          socket.router(app.new(http.signing_secret), find)
        })
      use port <- result.try(port)
      use _ <- result.map(events.start(bind, port, router, install))
      case router {
        option.Some(_) ->
          io.println(
            "crushling: taking events at "
            <> bind
            <> ":"
            <> int.to_string(port)
            <> "/slack/events",
          )
        option.None -> Nil
      }
      case install {
        option.Some(config) ->
          io.println(
            "crushling: installs start at "
            <> config.public_url
            <> "/slack/install",
          )
        option.None -> Nil
      }
    }
  })
  let socket =
    option.map(delivery.socket_mode, fn(app_token) {
      let router = socket.router(app.unverified(), find)
      io.println("crushling: taking events over Socket Mode")
      process.spawn_unlinked(fn() { socket.run(app_token, router) })
    })

  let terminate = process.new_subject()
  use _ <- result.try(install_sigterm(terminate))
  let _ = process.receive_forever(terminate)

  // Take no new work, give running turns their grace period, then stop
  // every agent before exiting.
  io.println("crushling: shutting down")
  // Over HTTP the registries ignore new messages once they are draining.
  option.map(socket, process.kill)
  // One deadline for all of it, from the registries' own timers.
  case instance.shutdown(teams, grace_s * 1000) {
    registry.Clean -> {
      io.println("crushling: stopped")
      halt(0)
    }
    registry.TimedOut -> {
      io.println_error("crushling: shutdown timed out")
      halt(1)
    }
    outcome -> {
      io.println_error(
        "crushling: shutdown incomplete: " <> string.inspect(outcome),
      )
      halt(1)
    }
  }
  Ok(Nil)
}

/// The store, with its key from `CRUSHLING_STORE_KEY` or `<root>/store-key`.
fn open_store(root: String) -> Result(store.Store, String) {
  use #(key, made) <- result.try(store.load_key(
    getenv("CRUSHLING_STORE_KEY"),
    root,
  ))
  case made {
    True ->
      io.println(
        "crushling: made a store key at "
        <> root
        <> "/store-key; back it up, or set CRUSHLING_STORE_KEY, since stored bot tokens can't be read without it",
      )
    False -> Nil
  }
  store.start(root <> "/crushling.db", key)
}

/// The workspace of `SLACK_BOT_TOKEN`, from auth.test.
type Seeded {
  Seeded(team: store.Team, env: instance.EnvTeam)
}

/// Self-host: put the workspace of `SLACK_BOT_TOKEN` in the store, with
/// its settings from the environment, and import the files the bridge kept
/// before the store, once.
fn seed_env_team(
  store: store.Store,
  root: String,
) -> Result(option.Option(Seeded), String) {
  case getenv("SLACK_BOT_TOKEN") {
    Error(Nil) -> Ok(option.None)
    Ok(bot_token) -> {
      use #(allowed, admins) <- result.try(instance.env_people(
        setting("CRUSHLING_ALLOWED_USERS", ""),
        setting("CRUSHLING_ADMINS", ""),
      ))
      case allowed.everyone {
        True ->
          io.println(
            "crushling: everyone in the workspace may use it (members only, no guests or other workspaces)",
          )
        False -> Nil
      }
      use #(team, me) <- result.try(instance.seed(
        store,
        slackline.new(bot_token),
        bot_token,
      ))
      io.println(
        "crushling: connected as "
        <> me.user
        <> " ("
        <> me.user_id
        <> ") in "
        <> me.team
        <> " ("
        <> me.team_id
        <> ")",
      )
      use imported <- result.map(store.import_files(store, root, me.team_id))
      case imported {
        store.AlreadyImported -> Nil
        store.Imported(threads:, links:, skipped:) -> {
          list.each(skipped, fn(skip) {
            io.println(
              "crushling: not importing "
              <> root
              <> "/"
              <> skip.0
              <> ": "
              <> skip.1,
            )
          })
          io.println(
            "crushling: imported "
            <> int.to_string(list.length(threads))
            <> " threads and "
            <> int.to_string(list.length(links))
            <> " code channel links into the store"
            <> case threads, links {
              [], [] -> ""
              _, _ ->
                " ("
                <> string.join(list.append(threads, links), ", ")
                <> "); their files are no longer read"
            },
          )
        }
      }
      option.Some(Seeded(
        team:,
        env: instance.EnvTeam(id: me.team_id, allowed:, admins:),
      ))
    }
  }
}

/// Whether OAuth install is on: all three of its settings are set.
fn install_settings() -> Result(Bool, String) {
  let names = ["SLACK_CLIENT_ID", "SLACK_CLIENT_SECRET", "CRUSHLING_PUBLIC_URL"]
  let set = list.filter(names, fn(name) { getenv(name) |> result.is_ok })
  case set {
    [] -> Ok(False)
    _ if set == names -> Ok(True)
    _ ->
      Error(
        "set all of SLACK_CLIENT_ID, SLACK_CLIENT_SECRET and CRUSHLING_PUBLIC_URL to install the app, or none",
      )
  }
}

fn events_address(http: option.Option(Http)) -> #(String, Result(Int, String)) {
  case http {
    option.Some(Http(bind:, port:, ..)) -> #(bind, Ok(port))
    option.None -> #(
      setting("CRUSHLING_EVENTS_BIND", "127.0.0.1"),
      int.parse(setting("CRUSHLING_EVENTS_PORT", "7470"))
        |> result.replace_error("CRUSHLING_EVENTS_PORT is not a number"),
    )
  }
}

@external(erlang, "crushling_signal", "install")
fn install_sigterm(subject: process.Subject(Nil)) -> Result(Nil, String)

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
  own_team: String,
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
          env: [],
          // The Honcho settings are the operator's own memory, so only the
          // self-host workspace's sandboxes get them. Other workspaces get
          // none until they have memory settings of their own.
          own_team:,
          own_env: honcho_env(),
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

/// The inference proxy, with the org's key from `CRUSHLING_HYPER_KEY`
/// (or `HYPER_API_KEY`, or `CRUSH_HYPER_API_KEY`). Errors name the
/// setting, never its value.
fn proxy_from_settings(secret: String) -> Result(proxy.Proxy, String) {
  use org_key <- result.try(
    proxy.org_key_from(getenv)
    |> result.replace_error(
      "CRUSHLING_HYPER_KEY (or HYPER_API_KEY) is not set; agents use Hyper through the bridge with the org's key",
    ),
  )
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
    upstream: proxy.upstream_from(getenv),
    thread_cap:,
    instance_cap:,
    max_per_thread: proxy.default_max_per_thread,
    max_uploads: proxy.default_max_uploads,
    upload_timeout_ms: proxy.default_upload_timeout_ms,
  ))
  |> result.map_error(fn(reason) {
    "the proxy upstream (CRUSHLING_PROXY_UPSTREAM or HYPER_URL) " <> reason
  })
}
