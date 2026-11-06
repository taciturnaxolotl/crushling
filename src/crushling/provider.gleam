//// Which provider the agents use, and the configuration a container gets
//// for it. With a login, the container's crush.json holds a managed token
//// that `credentials` keeps fresh; with a key, it holds the key itself.

import crushling/credentials
import gleam/json
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
  case backend {
    Claude(version:, ..) -> ["CRUSH_CLAUDE_VERSION=" <> version]
    Hyper(..) | HyperKey(..) -> []
  }
}

/// The container's global crush.json: one provider and the models to use.
/// For a login, `credentials.watch` adds the managed token to this file.
pub fn config(backend: Backend) -> String {
  let #(provider, entry, large, small) = case backend {
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
    #("providers", json.object([#(provider, json.object(entry))])),
    #("models", json.object([#("large", pick(large)), #("small", pick(small))])),
  ])
  |> json.to_string
}
