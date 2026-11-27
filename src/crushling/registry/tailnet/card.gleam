//// Tailnet access cards: what they say, and their buttons.

import crushling/slack/action_ref.{ThreadRef}
import crushling/slack/blocks
import crushling/tailscale
import gleam/int
import gleam/list
import gleam/string
import slackline/block
import slackline/element
import slackline/element/button

/// The fallback text of every card.
pub const title = "Tailnet access"

pub const allow_action = "tailnet_allow_"

pub const deny_action = "tailnet_deny"

pub const off_action = "tailnet_off"

/// The hours each "allow" button offers.
pub const offers = [1, 8]

fn lasts(hours: Int) -> String {
  blocks.plural(hours, "hour")
}

/// Time left, in words: whole hours, or minutes under an hour.
pub fn remaining(ms: Int) -> String {
  case ms < 3_600_000 {
    True -> blocks.plural(int.max({ ms + 30_000 } / 60_000, 1), "minute")
    False -> lasts({ ms + 1_800_000 } / 3_600_000)
  }
}

/// A Slack date in each reader's own time zone.
fn when(ms: Int) -> String {
  "<!date^"
  <> int.to_string(ms / 1000)
  <> "^{date_short_pretty} at {time}|soon>"
}

fn button(
  text: String,
  action_id: String,
  thread: #(String, String),
  style: List(block.Attr(block.ButtonElement)),
) -> block.Element {
  element.button(text:, action_id:, with: [
    button.value(action_ref.encode(ThreadRef(thread.0, thread.1))),
    ..style
  ])
}

/// The card asking to put the sandbox on the tailnet; `by` is who asked, or "" for the agent.
pub fn ask_blocks(
  _by: String,
  reason: String,
  key: String,
  tag: String,
  thread: #(String, String),
) -> List(block.Block) {
  let allow =
    list.map(offers, fn(hours) {
      button(
        "Allow for " <> lasts(hours),
        allow_action <> int.to_string(hours),
        thread,
        [],
      )
    })
  [
    blocks.card(
      blocks.Card(
        ..blocks.new_card(block.IconGlobe, "*Put the sandbox on the tailnet?*"),
        body: string.replace(string.trim(reason), "\n", " "),
        subtext: "Joins as `"
          <> tailscale.hostname(key)
          <> "`, tagged `"
          <> tag
          <> "`.",
        actions: list.append(allow, [button("Deny", deny_action, thread, [])]),
      ),
    ),
  ]
}

/// The card while access is on, with a button that turns it off.
pub fn on_blocks(
  until_ms: Int,
  by: String,
  key: String,
  tag: String,
  thread: #(String, String),
) -> List(block.Block) {
  [
    blocks.card(
      blocks.Card(
        ..blocks.new_card(block.IconGlobe, "*The sandbox is on the tailnet*"),
        subtitle: "Until " <> when(until_ms),
        body: "Joined as `"
          <> tailscale.hostname(key)
          <> "`, tagged `"
          <> tag
          <> "`.",
        subtext: "Approved by <@" <> by <> ">",
        actions: [
          button("Turn off", off_action, thread, [button.style(block.Danger)]),
        ],
      ),
    ),
  ]
}
