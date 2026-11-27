//// What a thread's crush is given, in one place: its environment, its
//// crush.json and the directories and files of its home. Backends only map
//// a `Spec` onto how they run crush (a container, or a local process).

import crushling/agent/env
import crushling/github/route as github_route
import crushling/key
import crushling/mcp
import crushling/provider
import crushling/proxy
import crushling/tunnel
import gleam/list

/// Where a sandbox's workspace appears inside it.
pub const workspace = "/workspace"

/// A year: the bridge, not the server, decides when an agent sleeps.
const idle_timeout_s = "31536000"

const detach_grace_s = "120"

/// What every thread's spec is built from.
pub type Settings {
  Settings(
    /// How crush reaches the bridge's sandbox server.
    bridge_url: String,
    /// The instance secret every thread token is derived from.
    secret: String,
    /// Whether git and gh reach GitHub through the bridge.
    github: Bool,
    models: provider.Models,
    /// `NAME=value` pairs for every agent.
    env: List(String),
    /// The workspace whose agents also get `own_env`, or "" for none.
    own_team: String,
    /// `NAME=value` pairs only for `own_team`'s agents, such as the
    /// operator's own Honcho memory settings.
    own_env: List(String),
  )
}

/// How a backend lays out crush's home.
pub type Home {
  /// HOME and the XDG directories live inside the workspace, which crush
  /// sees at `workspace`: a sandbox.
  Contained
  /// crush's config, data and Honcho directories sit beside the workspace,
  /// at their host paths, and HOME stays the user's: a local process.
  Beside
}

pub type Spec {
  Spec(
    key: String,
    /// `<root>/<key>` on the host.
    dir: String,
    /// The workspace on the host.
    host_work: String,
    /// The workspace as crush sees it.
    workdir: String,
    /// `NAME=value` pairs, in order; a later pair for the same name wins.
    env: List(String),
    crush_config: String,
    /// Host directories to make, as the bridge's own user.
    dirs: List(String),
    /// Host files to write, readable only by the bridge's user.
    files: List(#(String, String)),
    /// The tunnel URL crush dials.
    dial_url: String,
  )
}

/// The thread's spec under `root`, laid out for `home`.
pub fn build(
  settings: Settings,
  root: String,
  key: String,
  home: Home,
) -> Spec {
  let dir = root <> "/" <> key
  let host_work = dir <> "/work"
  let config = crush_config(settings)
  let #(workdir, layout, dirs, files) = case home {
    Contained -> {
      let seen = workspace <> "/.home"
      let data = host_work <> "/.home/.local/share/crush"
      #(
        workspace,
        [
          env.pair(env.home, seen),
          env.pair(env.xdg_data_home, seen <> "/.local/share"),
          env.pair(env.xdg_cache_home, seen <> "/.cache"),
          env.pair(env.honcho_config_dir, seen <> "/.honcho"),
        ],
        [host_work, data],
        [#(data <> "/crush.json", config)],
      )
    }
    Beside -> {
      let home = dir <> "/home"
      #(
        host_work,
        [
          env.pair(env.crush_global_config, home <> "/config"),
          env.pair(env.crush_global_data, home <> "/data"),
          // The operator's Honcho sign-in in ~/.honcho would otherwise
          // record every Slack conversation as theirs.
          env.pair(env.honcho_config_dir, home <> "/honcho"),
        ],
        [host_work, home <> "/config", home <> "/data", home <> "/honcho"],
        [#(home <> "/data/crush.json", config)],
      )
    }
  }
  Spec(
    key:,
    dir:,
    host_work:,
    workdir:,
    env: list.flatten([
      layout,
      [
        env.pair(env.idle_timeout, idle_timeout_s),
        env.pair(env.detach_grace, detach_grace_s),
      ],
      settings.env,
      team_env(settings, key),
      key_env(settings, key),
    ]),
    crush_config: config,
    dirs:,
    files:,
    dial_url: tunnel.dial_url(settings.bridge_url, key),
  )
}

/// The agent's crush.json, the same for every thread.
pub fn crush_config(settings: Settings) -> String {
  provider.config(settings.models, settings.bridge_url)
}

/// What a thread gets beyond `settings.env`: `own_env`, in `own_team`.
pub fn team_env(settings: Settings, thread: String) -> List(String) {
  case key.parse(thread) {
    Ok(thread) if settings.own_team != "" ->
      case key.team(thread) == settings.own_team {
        True -> settings.own_env
        False -> []
      }
    _ -> []
  }
}

/// The thread's own tokens: Slack tools, tunnel, proxy and maybe GitHub.
/// They are derived from its key, so the same ones come back each launch.
pub fn key_env(settings: Settings, key: String) -> List(String) {
  let url = settings.bridge_url
  let secret = settings.secret
  list.flatten([
    [env.pair(env.bridge_url, url)],
    mcp.env(secret, key),
    tunnel.env(secret, key),
    proxy.crush_env(url, secret, key),
    case settings.github {
      True -> github_route.env(url, secret, key)
      False -> []
    },
  ])
}
