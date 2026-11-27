//// Slack pieces the tests share.

import crushling/instance.{type Instance, Instance}
import crushling/registry
import crushling/slack/workspace
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import slackline

/// A workspace whose Slack is nowhere, so every call fails at once.
pub fn workspace(team: String, bot_user: String) -> workspace.Workspace {
  let assert Ok(client) =
    slackline.new("xoxb-test")
    |> slackline.with_base_url("http://127.0.0.1:1/api")
  workspace.new(team:, bot_user:, client:, token: "xoxb-test")
}

/// A router's lookup that knows one workspace, `team`, served by `registry`.
pub fn only(
  team: String,
  bot_user: String,
  registry: Subject(registry.Message),
) -> fn(Option(String), Option(String)) -> Result(Instance, Nil) {
  let found = Instance(workspace: workspace(team, bot_user), registry:)
  fn(asked, enterprise) {
    case asked, enterprise {
      Some(asked), _ if asked == team -> Ok(found)
      None, Some(enterprise) if enterprise == team -> Ok(found)
      _, _ -> Error(Nil)
    }
  }
}
