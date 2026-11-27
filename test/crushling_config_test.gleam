//// The bridge's settings: defaults, every error at once, and the old
//// names still read.

import crushling/config
import crushling/crush/client
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn env(pairs: List(#(String, String))) -> fn(String) -> Result(String, Nil) {
  let settings = dict.from_list(pairs)
  fn(name) { dict.get(settings, name) }
}

/// The least a docker self-host needs.
const minimal = [
  #("HOME", "/home/op"),
  #("SLACK_APP_TOKEN", "xapp-1"),
  #("SLACK_BOT_TOKEN", "xoxb-1"),
  #("CRUSHLING_ALLOWED_USERS", "U1"),
  #("CRUSHLING_HYPER_KEY", "hyper"),
  #("CRUSHLING_BRIDGE_URL", "http://172.30.0.1:7469/"),
]

fn with(pairs: List(#(String, String))) -> fn(String) -> Result(String, Nil) {
  env(list.append(pairs, minimal))
}

pub fn defaults_test() {
  let assert Ok(c) = config.parse(env(minimal))
  let assert client.Sysadmin = c.mode
  let assert "prism" = c.models.large
  let assert "prism-flash" = c.models.small
  let assert "/home/op/.local/state/crushling/threads" = c.root
  let assert None = c.store_key
  let assert config.Docker(docker) = c.sandbox
  let assert "crushling-sandbox:latest" = docker.image
  let assert "runsc" = docker.runtime
  let assert "sbx-egress" = docker.network
  let assert "2" = docker.cpus
  let assert "4g" = docker.memory
  let assert ["1.1.1.1", "9.9.9.9"] = docker.dns
  let assert [] = docker.honcho
  let assert config.Bridge(
    address: config.Address("127.0.0.1", 7469),
    url: "http://172.30.0.1:7469",
  ) = c.bridge
  let assert config.Address("127.0.0.1", 7470) = c.slack.events
  let assert Some("xapp-1") = c.slack.socket_mode
  let assert None = c.slack.signing_secret
  let assert None = c.slack.install
  let assert "https://hyper.charm.land" = c.proxy.upstream
  let assert None = c.github
  let assert None = c.tailnet
  let assert config.Limits(
    idle_ms: 900_000,
    shutdown_grace_ms: 60_000,
    hello_timeout_ms: 30_000,
  ) = c.limits
}

pub fn local_needs_no_bridge_url_test() {
  let assert Ok(c) =
    config.parse(
      env([
        #("CRUSHLING_LAUNCHER", "local"),
        #("CRUSHLING_BRIDGE_PORT", "9000"),
        ..list.filter(minimal, fn(pair) { pair.0 != "CRUSHLING_BRIDGE_URL" })
      ]),
    )
  let assert config.Local(crush: "") = c.sandbox
  let assert "http://127.0.0.1:9000" = c.bridge.url
}

/// Everything wrong is said at once, not one per restart.
pub fn every_error_at_once_test() {
  let assert Error(reasons) =
    config.parse(
      env([
        #("HOME", "/home/op"),
        #("CRUSHLING_MODE", "careful"),
        #("CRUSHLING_LAUNCHER", "podman"),
        #("CRUSHLING_IDLE_MINUTES", "soon"),
        #("CRUSHLING_EVENTS_PORT", "http"),
        #("SLACK_CLIENT_ID", "id"),
        #("CRUSHLING_PROXY_THREAD_CAP_USD", "lots"),
        #("CRUSHLING_STORE_KEY", "short"),
      ]),
    )
  let expect = [
    "set SLACK_SIGNING_SECRET",
    "CRUSHLING_EVENTS_PORT is not a number",
    "set all of SLACK_CLIENT_ID",
    "CRUSHLING_MODE is careful",
    "CRUSHLING_STORE_KEY ",
    "CRUSHLING_LAUNCHER is podman",
    "CRUSHLING_HYPER_KEY (or HYPER_API_KEY) is not set",
    "CRUSHLING_PROXY_THREAD_CAP_USD is not a dollar amount",
    "CRUSHLING_IDLE_MINUTES is not a number",
  ]
  list.each(expect, fn(start) {
    let assert True =
      list.any(reasons, fn(reason) { string.starts_with(reason, start) })
  })
  let assert True = list.length(reasons) == list.length(expect)
}

/// A number that is set but isn't one is an error, the shutdown grace too.
pub fn bad_number_errors_test() {
  let assert Error(["CRUSHLING_SHUTDOWN_GRACE_SECONDS is not a number"]) =
    config.parse(with([#("CRUSHLING_SHUTDOWN_GRACE_SECONDS", "a minute")]))
  let assert Error(["CRUSHLING_HELLO_TIMEOUT_SECONDS is not a number"]) =
    config.parse(with([#("CRUSHLING_HELLO_TIMEOUT_SECONDS", "x")]))
  let assert Error(["CRUSHLING_MCP_PORT is not a number"]) =
    config.parse(with([#("CRUSHLING_MCP_PORT", "x")]))
}

pub fn legacy_names_test() {
  let assert Ok(c) =
    config.parse(
      env([
        #("CRUSHLING_MCP_PORT", "8000"),
        #("CRUSHLING_MCP_BIND", "0.0.0.0"),
        #("CRUSHLING_MCP_URL", "http://gw:8000"),
        #("HYPER_API_KEY", "old-key"),
        #("HYPER_URL", "https://hyper.test"),
        ..list.filter(minimal, fn(pair) {
          pair.0 != "CRUSHLING_BRIDGE_URL" && pair.0 != "CRUSHLING_HYPER_KEY"
        })
      ]),
    )
  let assert config.Bridge(config.Address("0.0.0.0", 8000), "http://gw:8000") =
    c.bridge
  let assert "old-key" = c.proxy.org_key
  let assert "https://hyper.test" = c.proxy.upstream
  // The current names win over the old.
  let assert Ok(c) =
    config.parse(
      with([
        #("CRUSHLING_BRIDGE_PORT", "7000"),
        #("CRUSHLING_MCP_PORT", "8000"),
        #("CRUSH_HYPER_API_KEY", "oldest"),
      ]),
    )
  let assert 7000 = c.bridge.address.port
  let assert "hyper" = c.proxy.org_key
}

fn without_bot(
  pairs: List(#(String, String)),
) -> fn(String) -> Result(String, Nil) {
  env(list.append(
    pairs,
    list.filter(minimal, fn(pair) {
      pair.0 != "SLACK_BOT_TOKEN" && pair.0 != "CRUSHLING_ALLOWED_USERS"
    }),
  ))
}

/// A bridge serves the env team, installed workspaces, or both; never
/// neither.
pub fn env_team_or_install_test() {
  let install = [
    #("SLACK_CLIENT_ID", "id"),
    #("SLACK_CLIENT_SECRET", "secret"),
    #("CRUSHLING_PUBLIC_URL", "https://c.example"),
  ]
  let assert Error([reason]) = config.parse(without_bot([]))
  let assert True = string.starts_with(reason, "SLACK_BOT_TOKEN is not set")
  let assert Ok(c) = config.parse(without_bot(install))
  let assert None = c.slack.env_team
  let assert Some(config.Install("id", "secret", "https://c.example")) =
    c.slack.install
  let assert Ok(c) = config.parse(with(install))
  let assert Some(config.EnvTeam(bot_token: "xoxb-1", ..)) = c.slack.env_team
  let assert Some(_) = c.slack.install
  // The env team needs its allowlist; admins can't be everyone.
  let assert Error([reason]) =
    config.parse(
      env(
        list.filter(minimal, fn(pair) { pair.0 != "CRUSHLING_ALLOWED_USERS" }),
      ),
    )
  let assert True = string.starts_with(reason, "CRUSHLING_ALLOWED_USERS")
  let assert Error([reason]) = config.parse(with([#("CRUSHLING_ADMINS", "*")]))
  let assert True = string.starts_with(reason, "CRUSHLING_ADMINS")
  // Without the bot token its allowlist isn't needed.
  let assert Ok(_) = config.parse(without_bot(install))
}

pub fn optional_sections_test() {
  let assert Ok(c) =
    config.parse(
      with([
        #("CRUSHLING_TAILSCALE_API_KEY", "tskey"),
        #("CRUSHLING_GITHUB_CLIENT_ID", "Iv1"),
        #("CRUSHLING_DNS", "off"),
        #("HONCHO_URL", "https://honcho"),
      ]),
    )
  let assert Some(config.Tailnet(_, "tag:crushling", "-")) = c.tailnet
  let assert Some(config.GitHub("Iv1", None, None)) = c.github
  let assert config.Docker(docker) = c.sandbox
  let assert [] = docker.dns
  let assert ["HONCHO_URL=https://honcho"] = docker.honcho
  let assert Error([reason]) =
    config.parse(
      with([
        #("CRUSHLING_GITHUB_CLIENT_ID", "Iv1"),
        #("CRUSHLING_GITHUB_PRIVATE_KEY", "nope"),
      ]),
    )
  let assert True = string.starts_with(reason, "CRUSHLING_GITHUB_PRIVATE_KEY")
}

pub fn empty_github_settings_are_unset_test() {
  let assert Ok(c) =
    config.parse(
      with([
        #("CRUSHLING_GITHUB_CLIENT_ID", ""),
        #("CRUSHLING_GITHUB_PRIVATE_KEY", ""),
      ]),
    )
  let assert None = c.github
  let assert Ok(c) =
    config.parse(
      with([
        #("CRUSHLING_GITHUB_CLIENT_ID", "Iv1"),
        #("CRUSHLING_GITHUB_CLIENT_SECRET", ""),
        #("CRUSHLING_GITHUB_PRIVATE_KEY", ""),
      ]),
    )
  let assert Some(config.GitHub("Iv1", None, None)) = c.github
}

pub fn root_tilde_test() {
  let assert Ok(c) = config.parse(with([#("CRUSHLING_ROOT", "~")]))
  let assert "/home/op" = c.root
  let no_home = list.filter(minimal, fn(pair) { pair.0 != "HOME" })
  let assert Error(errors) =
    config.parse(env([#("CRUSHLING_ROOT", "~/x"), ..no_home]))
  let assert True = list.any(errors, string.contains(_, "HOME is not set"))
}
