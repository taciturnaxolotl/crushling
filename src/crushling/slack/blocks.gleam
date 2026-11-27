//// Block Kit pieces the bridge's cards share, and the words they use for
//// counts and money.

import gleam/float
import gleam/int
import gleam/string
import slackline/block
import slackline/block/section
import slackline/element
import slackline/element/button

/// A section of mrkdwn.
pub fn text(markdown: String) -> block.Block {
  block.section(text: block.mrkdwn(markdown), with: [])
}

/// A line of small mrkdwn under a card.
pub fn context(markdown: String) -> block.Block {
  block.context(elements: [block.context_mrkdwn(markdown)], with: [])
}

/// A markdown block, which renders full Slack markdown.
pub fn markdown(markdown: String) -> block.Block {
  block.markdown(markdown, [])
}

/// A section of mrkdwn with `button` beside it.
pub fn with_button(markdown: String, button: block.Element) -> block.Block {
  block.section(text: block.mrkdwn(markdown), with: [
    section.accessory(button),
  ])
}

/// A section of mrkdwn with a styled button beside it.
pub fn button_section(
  markdown: String,
  label: String,
  action_id: String,
  style: block.ButtonStyle,
) -> block.Block {
  with_button(
    markdown,
    element.button(text: label, action_id:, with: [button.style(style)]),
  )
}

/// `n` and the word for one or many of them: "1 file", "3 files".
pub fn count(n: Int, one: String, many: String) -> String {
  int.to_string(n)
  <> " "
  <> case n {
    1 -> one
    _ -> many
  }
}

/// `count` for a word made plural with an s.
pub fn plural(n: Int, word: String) -> String {
  count(n, word, word <> "s")
}

/// Dollars to the cent.
pub fn dollars(amount: Float) -> String {
  let cents = float.round(amount *. 100.0)
  "$"
  <> int.to_string(cents / 100)
  <> "."
  <> string.pad_start(int.to_string(cents % 100), 2, "0")
}
