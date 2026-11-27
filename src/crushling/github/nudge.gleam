//// Asks in a thread when its agent needs GitHub access the person hasn't
//// given: Connect, answered there with the code, or adding crushling's
//// GitHub App to an account. Only the person asked sees them.

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

/// Asked in a thread when its agent couldn't read `repo` on GitHub for
/// want of the person's connection: Connect answers there, with the code.
/// The text, and the blocks.
pub fn ask_connect(
  channel: String,
  thread_ts: String,
  on: Option(Repo),
) -> #(String, List(block.Block)) {
  let what = case on {
    Some(target) -> "`" <> repo.full(target) <> "`"
    option.None -> "your private repositories"
  }
  let text =
    "crushling would like private access to "
    <> what
    <> ". Would you like to connect crushling to your GitHub account?"
  #(text, [
    blocks.with_button(
      text,
      element.button(text: "Connect GitHub", action_id: connect_action, with: [
        button.style(block.Primary),
        button.value(action_ref.encode(ThreadRef(channel, thread_ts))),
      ]),
    ),
  ])
}

/// Asked when the person is connected but crushling's GitHub App isn't on
/// the account `target` belongs to: the button opens GitHub's page to
/// add it.
pub fn ask_install(
  target: Repo,
  install_url: String,
) -> #(String, List(block.Block)) {
  let owner = repo.owner(target)
  let text =
    "crushling would like access to `"
    <> repo.full(target)
    <> "`, but it isn't set up on *"
    <> owner
    <> "* yet. Would you like to add it? If you don't own "
    <> owner
    <> ", GitHub asks its owners to approve."
  #(text, [
    blocks.with_button(
      text,
      element.button(text: "Add to " <> owner, action_id: install_action, with: [
        button.style(block.Primary),
        button.url(install_url),
        button.value(owner),
      ]),
    ),
  ])
}

/// Said in place of the install ask once its button is pressed.
pub fn installing(owner: String) -> String {
  "Once crushling is on *"
  <> owner
  <> "*, the agent carries on by itself. If an owner has to approve it, the agent waits up to 10 minutes."
}
