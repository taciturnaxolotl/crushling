//// Asks in a thread when its agent needs GitHub access nobody has given:
//// Connect, answered privately with the code, or adding crushling's GitHub
//// App to an account. Public cards anyone who may use crushling can
//// press; they go once the need is met.

import crushling/github/connect
import crushling/github/repo.{type Repo}
import crushling/home
import crushling/slack/action_ref.{ThreadRef}
import crushling/slack/blocks
import gleam/option.{type Option, Some}
import slackline/block
import slackline/element
import slackline/element/button
import slackline/interaction

/// Connect, on the ask in a thread; its value names the thread.
pub const connect_action = "crushling_github_connect_in"

/// Add the App to an account; a link, with the account in its value.
pub const install_action = "crushling_github_install"

pub fn actions() -> List(String) {
  [connect_action, install_action]
}

/// What a press on an ask asks for.
pub type Pressed {
  /// Connect `user`, answering in the thread the ask was in.
  ConnectHere(user: String, place: connect.Place)
  /// GitHub opened in the browser; say in place of the ask what comes next.
  Installing(respond: String, text: String)
}

/// A press on an ask. Asks posted before they had an action of their own
/// carry the Home's Connect action with the thread in its value.
pub fn decode(
  action: interaction.BlockAction,
  payload: interaction.BlockActionsPayload,
) -> Result(Pressed, Nil) {
  case action, payload.response_url {
    interaction.ButtonAction(action_id:, value: Some(owner), ..), Some(url)
      if action_id == install_action
    -> Ok(Installing(url, installing(owner)))
    interaction.ButtonAction(action_id:, value: Some(value), ..), respond
      if action_id == connect_action || action_id == home.connect_action
    ->
      case action_ref.decode(value) {
        Ok(ThreadRef(channel:, thread_ts:)) ->
          Ok(ConnectHere(
            payload.user.id,
            connect.Place(channel, thread_ts, respond),
          ))
        _ -> Error(Nil)
      }
    _, _ -> Error(Nil)
  }
}

/// Asked in a thread when its agent couldn't reach `repo` on GitHub for
/// want of a connection: whoever presses Connect gets the code, and the
/// agent works as them once they're in. The text, and the blocks.
pub fn ask_connect(
  channel: String,
  thread_ts: String,
  on: Option(Repo),
) -> #(String, List(block.Block)) {
  let text = case on {
    Some(target) ->
      "The agent needs GitHub access to reach `" <> repo.full(target) <> "`."
    option.None ->
      "The agent needs GitHub access to reach a private repository."
  }
  #(text, [
    blocks.card(
      blocks.Card(
        ..blocks.new_card(block.IconKey, "*Connect GitHub*"),
        subtitle: case on {
          Some(target) -> repo.full(target)
          option.None -> ""
        },
        body: text,
        actions: [
          element.button(
            text: "Connect GitHub",
            action_id: connect_action,
            with: [
              button.style(block.Primary),
              button.value(action_ref.encode(ThreadRef(channel, thread_ts))),
            ],
          ),
        ],
      ),
    ),
  ])
}

/// Asked when the agent works as someone connected but crushling's GitHub
/// App isn't on the account `target` belongs to: the button opens GitHub's
/// page to add it.
pub fn ask_install(
  target: Repo,
  install_url: String,
) -> #(String, List(block.Block)) {
  let owner = repo.owner(target)
  let text =
    "crushling's GitHub App isn't on *"
    <> owner
    <> "*, so the agent can't reach `"
    <> repo.full(target)
    <> "`."
  #(text, [
    blocks.card(
      blocks.Card(
        ..blocks.new_card(block.IconLink, "*Add crushling to " <> owner <> "*"),
        subtitle: repo.full(target),
        body: text,
        actions: [
          element.button(
            text: "Add to " <> owner,
            action_id: install_action,
            with: [
              button.style(block.Primary),
              button.url(install_url),
              button.value(owner),
            ],
          ),
        ],
      ),
    ),
  ])
}

/// Said in place of the install ask once its button is pressed.
pub fn installing(owner: String) -> String {
  "_Waiting for crushling to be added to *"
  <> owner
  <> "*. The agent carries on by itself once it is, for up to 10 minutes._"
}
