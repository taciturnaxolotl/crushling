//// The App Home: what a person sees in crushling's Home tab. Their GitHub
//// connection with Connect or Disconnect, their threads whose agent is
//// running, and what the workspace has spent. Built fresh from `Home` each
//// time; pure, so the view is easy to test.

import crushling/github
import crushling/slack/blocks.{button_section, context, dollars, plural, text}
import crushling/usage.{type Usage}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import slackline/block
import slackline/interaction
import slackline/view

pub const connect_action = "crushling_github_connect"

pub const disconnect_action = "crushling_github_disconnect"

/// Slack allows 100 blocks in a Home; the threads listed are kept well
/// inside it.
pub const max_threads = 20

pub type Home {
  /// Someone who may use crushling.
  Home(
    github: GitHub,
    /// Their threads with a running agent, up to `max_threads`.
    threads: List(Thread),
    /// How many there are in all.
    thread_count: Int,
    /// What the workspace spent today and over the last 30 days.
    today: Usage,
    month: Usage,
    default_model: String,
  )
  /// Someone who may not.
  NotAllowed
}

/// A person's GitHub connection, as the Home shows it.
pub type GitHub {
  /// The bridge has no GitHub App set up.
  Unavailable
  NotConnected(note: Option(String))
  /// Asked GitHub for a code; none yet.
  Asking
  /// Waiting for them to enter `code` at `url`, for `minutes` more at most.
  Connecting(code: String, url: String, minutes: Int)
  /// `accounts`: where crushling's GitHub App is, when known; their token
  /// only reaches repos there.
  Connected(
    login: String,
    note: Option(String),
    accounts: Option(github.Accounts),
  )
}

/// A thread whose agent is running.
pub type Thread {
  Thread(
    channel: String,
    /// A link to the thread, when Slack gave one.
    link: Option(String),
    model: String,
    spent: Usage,
  )
}

pub fn view(home: Home) -> view.View {
  view.home(blocks: blocks(home), with: [])
}

fn blocks(home: Home) -> List(block.Block) {
  case home {
    NotAllowed -> [
      text("You can't use crushling in this workspace."),
    ]
    Home(github: state, threads:, thread_count:, today:, month:, default_model:) ->
      list.flatten([
        [block.header(text: "GitHub", with: [])],
        github(state),
        [block.divider(with: []), block.header(text: "Your agents", with: [])],
        running(threads, thread_count),
        [block.divider(with: []), block.header(text: "Workspace", with: [])],
        [
          text(
            "Spent today *"
            <> dollars(today.cost_usd)
            <> "* over "
            <> plural(today.requests, "request")
            <> " · last 30 days *"
            <> dollars(month.cost_usd)
            <> "*",
          ),
          context(
            "Agents start on *"
            <> default_model
            <> "*. `!model` in a thread changes it.",
          ),
        ],
      ])
  }
}

fn github(state: GitHub) -> List(block.Block) {
  case state {
    Unavailable -> [text("GitHub isn't set up for this crushling yet.")]
    NotConnected(note:) -> [
      button_section(
        "Connect your GitHub account so agents can read your private repos and push branches as you. They never get more access than you have.",
        "Connect",
        connect_action,
        block.Primary,
      ),
      ..note_block(note)
    ]
    Asking -> [text("Asking GitHub for a code…")]
    Connecting(code:, url:, minutes:) -> [
      text(
        "Enter *`"
        <> code
        <> "`* at <"
        <> url
        <> "|"
        <> strip(url)
        <> "> to connect.",
      ),
      context(
        "This page updates once GitHub says yes. The code works for "
        <> plural(minutes, "more minute")
        <> ".",
      ),
    ]
    Connected(login:, note:, accounts:) -> [
      button_section(
        "Connected as *<https://github.com/"
          <> login
          <> "|@"
          <> login
          <> ">*. Agents working for you use this account.",
        "Disconnect",
        disconnect_action,
        block.Danger,
      ),
      ..list.append(installed(accounts), note_block(note))
    ]
  }
}

fn running(threads: List(Thread), count: Int) -> List(block.Block) {
  case threads {
    [] -> [text("None of your threads has an agent running.")]
    threads -> {
      let lines =
        list.map(threads, fn(thread) {
          let place = case thread.link {
            Some(link) ->
              "<" <> link <> "|a thread> in <#" <> thread.channel <> ">"
            None -> "a thread in <#" <> thread.channel <> ">"
          }
          "• "
          <> place
          <> " · "
          <> thread.model
          <> " · "
          <> dollars(thread.spent.cost_usd)
        })
      let more = count - list.length(threads)
      [
        text(string.join(lines, "\n")),
        ..case more > 0 {
          True -> [context("…and " <> int.to_string(more) <> " more.")]
          False -> []
        }
      ]
    }
  }
}

/// Where agents can read, and the link to add crushling elsewhere.
fn installed(accounts: Option(github.Accounts)) -> List(block.Block) {
  case accounts {
    None -> []
    Some(github.Accounts(logins: [], install_url:)) -> [
      context(
        "crushling isn't on any GitHub account yet, so agents can only read public repos. <"
        <> install_url
        <> "|Add it to an account>",
      ),
    ]
    Some(github.Accounts(logins:, install_url:)) -> [
      context(
        "Agents can read repos on "
        <> string.join(
          list.map(logins, fn(login) { "*" <> login <> "*" }),
          ", ",
        )
        <> ". <"
        <> install_url
        <> "|Add crushling to another account>",
      ),
    ]
  }
}

fn note_block(note: Option(String)) -> List(block.Block) {
  case note {
    Some(note) -> [context(note)]
    None -> []
  }
}

/// What a press on the Home's buttons asks for.
pub type Pressed {
  Connect(user: String)
  Disconnect(user: String)
}

pub fn actions() -> List(String) {
  [connect_action, disconnect_action]
}

/// A press on the Home's buttons.
pub fn decode(
  action: interaction.BlockAction,
  payload: interaction.BlockActionsPayload,
) -> Result(Pressed, Nil) {
  case action {
    interaction.ButtonAction(action_id:, ..) if action_id == connect_action ->
      Ok(Connect(payload.user.id))
    interaction.ButtonAction(action_id:, ..) if action_id == disconnect_action ->
      Ok(Disconnect(payload.user.id))
    _ -> Error(Nil)
  }
}

fn strip(url: String) -> String {
  case url {
    "https://" <> rest -> rest
    rest -> rest
  }
}
