//// How a registry is set up.

import crushling/crush/client
import crushling/github/broker
import crushling/launcher.{type Launcher}
import crushling/people.{type People}
import crushling/registry/tailnet
import crushling/slack/workspace.{type Workspace}
import crushling/store.{type Store}
import gleam/option.{type Option}
import gleam/set.{type Set}

pub type Config {
  Config(
    launcher: Launcher,
    /// The Slack workspace it serves.
    workspace: Workspace,
    /// Who may drive agents: listed ids, and maybe every workspace member.
    allowed: People,
    /// Who may approve tailnet access; when empty, the ids allowed (nobody when that's everyone).
    admins: Set(String),
    /// Where thread meta and code-channel links are kept.
    store: Store,
    /// Threads whose old workspace couldn't be moved to their key at start; they take no messages.
    stranded: Set(String),
    idle_ms: Int,
    flush_ms: Int,
    mode: client.PermissionMode,
    /// How to put sandboxes on the tailnet, if anyone may.
    tailnet: Option(tailnet.Setup),
    /// Waits before each retry of a failed stop; then the registry gives up on that agent.
    stop_backoff_ms: List(Int),
    /// Each thread's attachments are kept under `<root>/<key>/files`.
    root: String,
    /// The GitHub App people connect their accounts through, if set up.
    github: Option(broker.GitHub),
    /// The model agents start on, for the App Home.
    default_model: String,
  )
}

/// Retries of a failed stop: after 1, 5 and 15 seconds.
pub const default_stop_backoff_ms = [1000, 5000, 15_000]
