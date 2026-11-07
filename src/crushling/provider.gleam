//// Which provider the agents use, and the configuration a container gets
//// for it. With a login, the container's crush.json holds a managed token
//// that `credentials` keeps fresh; with a key, it holds the key itself.

import crushling/credentials
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

pub type Backend {
  /// A Claude subscription, through crush's Claude Code fingerprinting.
  /// `version` is the Claude Code version crush presents; it is signed into
  /// every request, so it must stay at or above what Anthropic accepts.
  Claude(login: String, version: String, large: String, small: String)
  /// A Charm Hyper login.
  Hyper(login: String, large: String, small: String)
  /// A Charm Hyper API key. Simplest, but the long-lived key sits in every
  /// container.
  HyperKey(key: String, large: String, small: String)
}

/// The login `credentials` should keep fresh, if any.
pub fn login(backend: Backend) -> Option(credentials.Login) {
  case backend {
    Claude(login:, version:, ..) -> Some(credentials.claude(login, version))
    Hyper(login:, ..) -> Some(credentials.hyper(login))
    HyperKey(..) -> None
  }
}

/// Environment for the container's `crush server`.
pub fn env(backend: Backend) -> List(String) {
  env_for(backend, [])
}

/// The provider id a backend has in crush.json.
pub fn id(backend: Backend) -> String {
  case backend {
    Claude(..) -> "anthropic"
    Hyper(..) | HyperKey(..) -> "hyper"
  }
}

/// Extra backends whose provider the main one doesn't already supply.
fn others(main: Backend, extras: List(Backend)) -> List(Backend) {
  list.filter(extras, fn(extra) { id(extra) != id(main) })
  |> list.unique
}

/// The logins to keep fresh: the main backend's, and any extra one's.
pub fn logins(main: Backend, extras: List(Backend)) -> List(credentials.Login) {
  [main, ..others(main, extras)]
  |> list.filter_map(fn(backend) { option.to_result(login(backend), Nil) })
}

/// Environment for the server, for the main backend and the extras.
pub fn env_for(main: Backend, extras: List(Backend)) -> List(String) {
  [main, ..others(main, extras)]
  |> list.flat_map(fn(backend) {
    case backend {
      Claude(version:, ..) -> ["CRUSH_CLAUDE_VERSION=" <> version]
      Hyper(..) | HyperKey(..) -> []
    }
  })
  |> list.unique
}

/// The container's global crush.json: one provider and the models to use.
/// For a login, `credentials.watch` adds the managed token to this file.
pub fn config(backend: Backend) -> String {
  config_with(backend, "")
}

/// The agent's crush.json, with crushling's Slack tools served from
/// `mcp_url` (none when it is ""). The thread and its token come from the
/// server's environment, so one file serves every thread.
pub fn config_with(backend: Backend, mcp_url: String) -> String {
  config_for(backend, [], mcp_url)
}

fn entry(backend: Backend) -> #(String, json.Json) {
  case backend {
    HyperKey(key:, ..) -> #(
      "hyper",
      json.object([#("api_key", json.string(key))]),
    )
    other -> #(id(other), json.object([]))
  }
}

/// The agent's crush.json with `extras` configured too: providers whose
/// models the agent can pick for its subagents, while its own models come
/// from `backend`.
pub fn config_for(
  backend: Backend,
  extras: List(Backend),
  mcp_url: String,
) -> String {
  let #(provider, _, large, small) = case backend {
    Claude(large:, small:, ..) -> #("anthropic", [], large, small)
    Hyper(large:, small:, ..) -> #("hyper", [], large, small)
    HyperKey(key:, large:, small:) -> #(
      "hyper",
      [#("api_key", json.string(key))],
      large,
      small,
    )
  }
  let pick = fn(model) {
    json.object([
      #("provider", json.string(provider)),
      #("model", json.string(model)),
    ])
  }
  json.object([
    #(
      "providers",
      json.object(list.map([backend, ..others(backend, extras)], entry)),
    ),
    #("models", json.object([#("large", pick(large)), #("small", pick(small))])),
    // The agent runs interactively so it can dispatch subagents that
    // report back later, but nobody is at a terminal to answer its
    // multiple-choice questions.
    #(
      "options",
      json.object([#("disabled_tools", json.array(["question"], json.string))]),
    ),
    ..case mcp_url {
      "" -> []
      url -> [
        #(
          "mcp",
          json.object([
            #(
              "slack",
              json.object([
                #("type", json.string("http")),
                #("url", json.string(url <> "/mcp/$CRUSHLING_THREAD")),
                #(
                  "headers",
                  json.object([
                    #(
                      "Authorization",
                      json.string("Bearer $CRUSHLING_MCP_TOKEN"),
                    ),
                  ]),
                ),
              ]),
            ),
          ]),
        ),
      ]
    }
  ])
  |> json.to_string
}
