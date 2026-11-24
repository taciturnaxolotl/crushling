//// The App Home: what a person sees in crushling's Home tab. Their GitHub
//// connection with Connect or Disconnect, their threads whose agent is
//// running, and what the workspace has spent. Built fresh from `Home` each
//// time; pure, so the view is easy to test.

import crushling/proxy/meter.{type Usage}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import slackline/block
import slackline/block/section
import slackline/element
import slackline/element/button
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
  Connected(login: String, note: Option(String))
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
      text("You can't use crushling in this workspace. Ask whoever runs it."),
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
    Connected(login:, note:) -> [
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
      ..note_block(note)
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

fn note_block(note: Option(String)) -> List(block.Block) {
  case note {
    Some(note) -> [context(note)]
    None -> []
  }
}

fn text(markdown: String) -> block.Block {
  block.section(text: block.mrkdwn(markdown), with: [])
}

fn context(markdown: String) -> block.Block {
  block.context(elements: [block.context_mrkdwn(markdown)], with: [])
}

fn button_section(
  markdown: String,
  label: String,
  action_id: String,
  style: block.ButtonStyle,
) -> block.Block {
  block.section(text: block.mrkdwn(markdown), with: [
    section.accessory(
      element.button(text: label, action_id:, with: [button.style(style)]),
    ),
  ])
}

fn strip(url: String) -> String {
  case url {
    "https://" <> rest -> rest
    rest -> rest
  }
}

fn plural(n: Int, word: String) -> String {
  int.to_string(n)
  <> " "
  <> word
  <> case n {
    1 -> ""
    _ -> "s"
  }
}

/// Dollars to the cent.
pub fn dollars(amount: Float) -> String {
  let cents = float.round(amount *. 100.0)
  "$"
  <> int.to_string(cents / 100)
  <> "."
  <> string.pad_start(int.to_string(cents % 100), 2, "0")
}
