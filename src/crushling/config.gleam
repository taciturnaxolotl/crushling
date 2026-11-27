//// The bridge's settings, read once from the environment into a typed
//// `Config`. Parsing is pure and reports every problem at once; starting
//// anything is `crushling/boot`'s job. See docs/configuration.md.

import crushling/crush/client
import crushling/github/app as github_app
import crushling/people
import crushling/provider
import crushling/proxy
import crushling/store
import crushling/tailscale
import crushling/tunnel
import crushling/usage
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string

pub type Config {
  Config(
    slack: Slack,
    mode: client.PermissionMode,
    models: provider.Models,
    /// Where thread workspaces, the store and the tunnels' sockets live.
    root: String,
    /// `CRUSHLING_STORE_KEY`, already checked; None makes or reads
    /// `<root>/store-key`.
    store_key: Option(String),
    sandbox: Sandbox,
    bridge: Bridge,
    proxy: Proxy,
    github: Option(GitHub),
    tailnet: Option(Tailnet),
    limits: Limits,
  )
}

/// How Slack reaches the bridge, and which workspaces it serves.
pub type Slack {
  Slack(
    /// The app-level token for Socket Mode.
    socket_mode: Option(String),
    /// The signing secret, to take events over HTTP.
    signing_secret: Option(String),
    /// Where the events endpoint and the OAuth install listen.
    events: Address,
    env_team: Option(EnvTeam),
    install: Option(Install),
  )
}

pub type Address {
  Address(bind: String, port: Int)
}

/// Self-host: the workspace of `SLACK_BOT_TOKEN`.
pub type EnvTeam {
  EnvTeam(bot_token: String, allowed: people.People, admins: Set(String))
}

/// The OAuth install, on when all three of its settings are.
pub type Install {
  Install(client_id: String, client_secret: String, public_url: String)
}

pub type Sandbox {
  Docker(DockerSandbox)
  /// Agents run unsandboxed, as whoever runs the bridge.
  Local(crush: String)
}

pub type DockerSandbox {
  DockerSandbox(
    image: String,
    runtime: String,
    network: String,
    cpus: String,
    memory: String,
    /// Nameservers for the sandboxes, or [] for docker's own.
    dns: List(String),
    /// A `crush` binary to mount in place of the image's own, or "".
    crush: String,
    /// `NAME=value` Honcho settings for the self-host workspace's sandboxes.
    honcho: List(String),
  )
}

/// The sandbox server agents reach the bridge on.
pub type Bridge {
  Bridge(address: Address, url: String)
}

pub type Proxy {
  Proxy(
    org_key: String,
    upstream: String,
    thread_cap: usage.Cap,
    instance_cap: usage.Cap,
  )
}

pub type GitHub {
  GitHub(
    client_id: String,
    client_secret: Option(String),
    private_key: Option(github_app.Key),
  )
}

pub type Tailnet {
  Tailnet(credential: tailscale.Credential, tag: String, tailnet: String)
}

pub type Limits {
  Limits(idle_ms: Int, shutdown_grace_ms: Int, hello_timeout_ms: Int)
}

type Getenv =
  fn(String) -> Result(String, Nil)

type Parsed(a) =
  Result(a, List(String))

/// The config from `getenv`, or every reason it isn't one.
pub fn parse(getenv: Getenv) -> Result(Config, List(String)) {
  let slack = slack(getenv)
  let mode = mode(getenv)
  let models =
    provider.Models(
      large: setting(getenv, "CRUSHLING_LARGE", provider.default_large),
      small: setting(getenv, "CRUSHLING_SMALL", provider.default_small),
    )
  let root = root(getenv)
  let store_key = store_key(getenv)
  let sandbox = sandbox(getenv)
  let bridge = bridge(getenv, result.map(sandbox, is_local))
  let proxy = proxy_settings(getenv)
  let github = github(getenv)
  let tailnet = tailnet(getenv)
  let limits = limits(getenv)
  case slack, mode, root, store_key, sandbox, bridge, proxy, github, limits {
    Ok(slack),
      Ok(mode),
      Ok(root),
      Ok(store_key),
      Ok(sandbox),
      Ok(bridge),
      Ok(proxy),
      Ok(github),
      Ok(limits)
    ->
      Ok(Config(
        slack:,
        mode:,
        models:,
        root:,
        store_key:,
        sandbox:,
        bridge:,
        proxy:,
        github:,
        tailnet:,
        limits:,
      ))
    _, _, _, _, _, _, _, _, _ ->
      Error(
        list.flatten([
          errors(slack),
          errors(mode),
          errors(root),
          errors(store_key),
          errors(sandbox),
          errors(bridge),
          errors(proxy),
          errors(github),
          errors(limits),
        ]),
      )
  }
}

fn errors(parsed: Parsed(a)) -> List(String) {
  case parsed {
    Ok(_) -> []
    Error(reasons) -> reasons
  }
}

fn setting(getenv: Getenv, name: String, default: String) -> String {
  getenv(name) |> result.unwrap(default)
}

/// A setting under its current name, else its old one, with the name it
/// was found under.
fn either(
  getenv: Getenv,
  name: String,
  old: String,
) -> Result(#(String, String), Nil) {
  case getenv(name) {
    Ok(value) -> Ok(#(name, value))
    Error(Nil) -> getenv(old) |> result.map(fn(value) { #(old, value) })
  }
}

/// A whole number, `default` when unset; set but not a number is an error.
fn number(found: Result(#(String, String), Nil), default: Int) -> Parsed(Int) {
  case found {
    Error(Nil) -> Ok(default)
    Ok(#(name, text)) ->
      int.parse(text) |> result.replace_error([name <> " is not a number"])
  }
}

fn named(getenv: Getenv, name: String) -> Result(#(String, String), Nil) {
  getenv(name) |> result.map(fn(value) { #(name, value) })
}

fn slack(getenv: Getenv) -> Parsed(Slack) {
  let signing_secret = option.from_result(getenv("SLACK_SIGNING_SECRET"))
  let socket_mode = option.from_result(getenv("SLACK_APP_TOKEN"))
  let delivery = case signing_secret, socket_mode {
    None, None -> [
      "set SLACK_SIGNING_SECRET to take events over HTTP, or SLACK_APP_TOKEN for Socket Mode",
    ]
    _, _ -> []
  }
  let bind = setting(getenv, "CRUSHLING_EVENTS_BIND", "127.0.0.1")
  let port = number(named(getenv, "CRUSHLING_EVENTS_PORT"), 7470)
  let env_team = env_team(getenv)
  let install = install(getenv)
  let workspaces = case env_team, install {
    Ok(None), Ok(None) -> [
      "SLACK_BOT_TOKEN is not set; set it, or SLACK_CLIENT_ID, SLACK_CLIENT_SECRET and CRUSHLING_PUBLIC_URL to install the app in workspaces",
    ]
    _, _ -> []
  }
  case delivery, port, env_team, install, workspaces {
    [], Ok(port), Ok(env_team), Ok(install), [] ->
      Ok(Slack(
        socket_mode:,
        signing_secret:,
        events: Address(bind:, port:),
        env_team:,
        install:,
      ))
    _, _, _, _, _ ->
      Error(
        list.flatten([
          delivery,
          errors(port),
          errors(env_team),
          errors(install),
          workspaces,
        ]),
      )
  }
}

fn env_team(getenv: Getenv) -> Parsed(Option(EnvTeam)) {
  case getenv("SLACK_BOT_TOKEN") {
    Error(Nil) -> Ok(None)
    Ok(bot_token) ->
      people.env_people(
        setting(getenv, "CRUSHLING_ALLOWED_USERS", ""),
        setting(getenv, "CRUSHLING_ADMINS", ""),
      )
      |> result.map(fn(people) {
        Some(EnvTeam(bot_token:, allowed: people.0, admins: people.1))
      })
      |> result.map_error(list.wrap)
  }
}

fn install(getenv: Getenv) -> Parsed(Option(Install)) {
  case
    getenv("SLACK_CLIENT_ID"),
    getenv("SLACK_CLIENT_SECRET"),
    getenv("CRUSHLING_PUBLIC_URL")
  {
    Ok(client_id), Ok(client_secret), Ok(public_url) ->
      Ok(Some(Install(client_id:, client_secret:, public_url:)))
    Error(Nil), Error(Nil), Error(Nil) -> Ok(None)
    _, _, _ ->
      Error([
        "set all of SLACK_CLIENT_ID, SLACK_CLIENT_SECRET and CRUSHLING_PUBLIC_URL to install the app, or none",
      ])
  }
}

fn mode(getenv: Getenv) -> Parsed(client.PermissionMode) {
  case setting(getenv, "CRUSHLING_MODE", "sysadmin") {
    "sysadmin" -> Ok(client.Sysadmin)
    "yolo" -> Ok(client.Yolo)
    other -> Error(["CRUSHLING_MODE is " <> other <> "; use sysadmin or yolo"])
  }
}

fn root(getenv: Getenv) -> Parsed(String) {
  let raw =
    setting(getenv, "CRUSHLING_ROOT", "~/.local/state/crushling/threads")
  let home = filled(getenv, "HOME")
  use root <- result.try(case raw, home {
    "~", Some(home) -> Ok(home)
    "~/" <> rest, Some(home) -> Ok(home <> "/" <> rest)
    "~" <> _, None ->
      Error(["CRUSHLING_ROOT starts with ~ but HOME is not set"])
    root, _ -> Ok(root)
  })
  tunnel.check_root(root)
  |> result.replace(root)
  |> result.map_error(fn(reason) { ["CRUSHLING_ROOT: " <> reason] })
}

fn store_key(getenv: Getenv) -> Parsed(Option(String)) {
  case getenv("CRUSHLING_STORE_KEY") {
    Error(Nil) -> Ok(None)
    Ok(text) ->
      case store.parse_key(text) {
        Ok(_) -> Ok(Some(text))
        Error(reason) -> Error(["CRUSHLING_STORE_KEY " <> reason])
      }
  }
}

fn is_local(sandbox: Sandbox) -> Bool {
  case sandbox {
    Local(..) -> True
    Docker(..) -> False
  }
}

fn sandbox(getenv: Getenv) -> Parsed(Sandbox) {
  let crush = setting(getenv, "CRUSHLING_CRUSH", "")
  case setting(getenv, "CRUSHLING_LAUNCHER", "docker") {
    "local" -> Ok(Local(crush:))
    "docker" ->
      Ok(
        Docker(DockerSandbox(
          image: setting(getenv, "CRUSHLING_IMAGE", "crushling-sandbox:latest"),
          runtime: setting(getenv, "CRUSHLING_RUNTIME", "runsc"),
          network: setting(getenv, "CRUSHLING_NETWORK", "sbx-egress"),
          cpus: setting(getenv, "CRUSHLING_SANDBOX_CPUS", "2"),
          memory: setting(getenv, "CRUSHLING_SANDBOX_MEMORY", "4g"),
          dns: case setting(getenv, "CRUSHLING_DNS", "1.1.1.1,9.9.9.9") {
            "off" -> []
            servers ->
              string.split(servers, ",")
              |> list.map(string.trim)
              |> list.filter(fn(server) { server != "" })
          },
          crush:,
          honcho: list.filter_map(honcho_settings, fn(name) {
            getenv(name) |> result.map(fn(value) { name <> "=" <> value })
          }),
        )),
      )
    other ->
      Error(["CRUSHLING_LAUNCHER is " <> other <> "; use docker or local"])
  }
}

/// The operator's Honcho memory settings, for the self-host workspace's
/// sandboxes only.
const honcho_settings = [
  "HONCHO_API_KEY", "HONCHO_URL", "HONCHO_WORKSPACE", "HONCHO_PEER_NAME",
  "HONCHO_AI_PEER",
]

/// The sandbox server. `local` is whether agents run on this machine, or
/// an error when the launcher is bad, so the URL can't be judged.
fn bridge(getenv: Getenv, local: Result(Bool, a)) -> Parsed(Bridge) {
  let port =
    number(either(getenv, "CRUSHLING_BRIDGE_PORT", "CRUSHLING_MCP_PORT"), 7469)
  let bind =
    either(getenv, "CRUSHLING_BRIDGE_BIND", "CRUSHLING_MCP_BIND")
    |> result.map(fn(found) { found.1 })
    |> result.unwrap("127.0.0.1")
  let url =
    either(getenv, "CRUSHLING_BRIDGE_URL", "CRUSHLING_MCP_URL")
    |> result.map(fn(found) { found.1 })
    |> result.unwrap("")
  let url = case string.ends_with(url, "/") {
    True -> string.drop_end(url, 1)
    False -> url
  }
  // Sandboxes can't reach the host's loopback, so docker has no default.
  let url = case url, local, port {
    "off", _, _ ->
      Error([
        "CRUSHLING_BRIDGE_URL can no longer be off: agents dial the bridge there",
      ])
    "", Ok(True), Ok(port) -> Ok("http://127.0.0.1:" <> int.to_string(port))
    "", Ok(False), _ ->
      Error([
        "CRUSHLING_BRIDGE_URL is not set; set it to an address of this machine the sandbox network may reach on the bridge port",
      ])
    "", _, _ -> Error([])
    url, _, _ -> Ok(url)
  }
  case port, url {
    Ok(port), Ok(url) -> Ok(Bridge(address: Address(bind:, port:), url:))
    _, _ -> Error(list.append(errors(port), errors(url)))
  }
}

/// The inference proxy's settings. Errors name the setting, never its
/// value.
fn proxy_settings(getenv: Getenv) -> Parsed(Proxy) {
  let org_key =
    proxy.org_key_from(getenv)
    |> result.replace_error([
      "CRUSHLING_HYPER_KEY (or HYPER_API_KEY) is not set; agents use Hyper through the bridge with the org's key",
    ])
  let upstream = proxy.upstream_from(getenv)
  let cap = fn(scope) {
    let name = fn(unit) { "CRUSHLING_PROXY_" <> scope <> "_CAP_" <> unit }
    proxy.parse_cap(
      setting(getenv, name("TOKENS"), ""),
      setting(getenv, name("USD"), ""),
    )
    |> result.map_error(fn(error) {
      case error {
        proxy.BadTokens -> [name("TOKENS") <> " is not a whole number"]
        proxy.BadUsd -> [name("USD") <> " is not a dollar amount"]
      }
    })
  }
  let thread_cap = cap("THREAD")
  let instance_cap = cap("INSTANCE")
  case org_key, thread_cap, instance_cap {
    Ok(org_key), Ok(thread_cap), Ok(instance_cap) ->
      Ok(Proxy(org_key:, upstream:, thread_cap:, instance_cap:))
    _, _, _ ->
      Error(
        list.flatten([errors(org_key), errors(thread_cap), errors(instance_cap)]),
      )
  }
}

/// The GitHub App people connect their accounts through: on when
/// `CRUSHLING_GITHUB_CLIENT_ID` is set.
fn github(getenv: Getenv) -> Parsed(Option(GitHub)) {
  case filled(getenv, "CRUSHLING_GITHUB_CLIENT_ID") {
    None -> Ok(None)
    Some(client_id) -> {
      let client_secret = filled(getenv, "CRUSHLING_GITHUB_CLIENT_SECRET")
      case filled(getenv, "CRUSHLING_GITHUB_PRIVATE_KEY") {
        None -> Ok(Some(GitHub(client_id:, client_secret:, private_key: None)))
        Some(pem) ->
          case github_app.parse_key(pem) {
            Ok(key) ->
              Ok(
                Some(GitHub(client_id:, client_secret:, private_key: Some(key))),
              )
            Error(Nil) ->
              Error([
                "CRUSHLING_GITHUB_PRIVATE_KEY is not an RSA private key in PEM (or base64 of one)",
              ])
          }
      }
    }
  }
}

/// A setting's value, with set-but-empty counted as unset as env files often leave them.
fn filled(getenv: Getenv, name: String) -> Option(String) {
  case getenv(name) {
    Ok("") | Error(Nil) -> None
    Ok(value) -> Some(value)
  }
}

/// Tailnet access, when a Tailscale credential is set. It also needs agents
/// in sandboxes, which boot checks.
fn tailnet(getenv: Getenv) -> Option(Tailnet) {
  let credential = case
    getenv("CRUSHLING_TAILSCALE_CLIENT_ID"),
    getenv("CRUSHLING_TAILSCALE_CLIENT_SECRET"),
    getenv("CRUSHLING_TAILSCALE_API_KEY")
  {
    Ok(id), Ok(secret), _ -> Ok(tailscale.OAuthClient(id:, secret:))
    _, _, Ok(key) -> Ok(tailscale.ApiKey(key))
    _, _, _ -> Error(Nil)
  }
  let tag = setting(getenv, "CRUSHLING_TAILSCALE_TAG", "tag:crushling")
  let tailnet = setting(getenv, "CRUSHLING_TAILSCALE_TAILNET", "-")
  credential
  |> result.map(fn(credential) { Tailnet(credential:, tag:, tailnet:) })
  |> option.from_result
}

fn limits(getenv: Getenv) -> Parsed(Limits) {
  let idle = number(named(getenv, "CRUSHLING_IDLE_MINUTES"), 15)
  let grace = number(named(getenv, "CRUSHLING_SHUTDOWN_GRACE_SECONDS"), 60)
  let hello = number(named(getenv, "CRUSHLING_HELLO_TIMEOUT_SECONDS"), 30)
  case idle, grace, hello {
    Ok(idle), Ok(grace), Ok(hello) ->
      Ok(Limits(
        idle_ms: idle * 60_000,
        shutdown_grace_ms: grace * 1000,
        hello_timeout_ms: hello * 1000,
      ))
    _, _, _ -> Error(list.flatten([errors(idle), errors(grace), errors(hello)]))
  }
}
