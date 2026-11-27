//// The agents' provider: Charm Hyper, through the bridge's inference proxy
//// (`crushling/proxy`). The org's key stays on the bridge. Each sandbox
//// gets `proxy.crush_env`: `HYPER_URL` and a thread token as
//// `HYPER_API_KEY`, which crush reads from its environment for Hyper, so
//// crush.json holds the models and no key.

import crushling/agent/env
import gleam/json

/// The models the agents use, by Hyper model id.
pub type Models {
  Models(large: String, small: String)
}

pub const default_large = "prism"

pub const default_small = "prism-flash"

/// The provider id Hyper has in crush.json.
pub const id = "hyper"

/// The agent's crush.json, with crushling's Slack tools served from
/// `bridge_url` (none when it is ""). The thread and its token come from the
/// server's environment, so one file serves every thread.
pub fn config(models: Models, bridge_url: String) -> String {
  let pick = fn(model) {
    json.object([
      #("provider", json.string(id)),
      #("model", json.string(model)),
    ])
  }
  json.object([
    // No api_key or base_url: crush takes both from HYPER_API_KEY and
    // HYPER_URL, which point it at the proxy.
    #("providers", json.object([#(id, json.object([]))])),
    #(
      "models",
      json.object([
        #("large", pick(models.large)),
        #("small", pick(models.small)),
      ]),
    ),
    // The agent runs interactively so it can dispatch subagents that
    // report back later, but nobody is at a terminal to answer its
    // multiple-choice questions.
    #(
      "options",
      json.object([#("disabled_tools", json.array(["question"], json.string))]),
    ),
    ..case bridge_url {
      "" -> []
      url -> [
        #(
          "mcp",
          json.object([
            #(
              "slack",
              json.object([
                #("type", json.string("http")),
                #("url", json.string(url <> "/mcp/$" <> env.thread)),
                #(
                  "headers",
                  json.object([
                    #("Authorization", json.string("Bearer $" <> env.mcp_token)),
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
