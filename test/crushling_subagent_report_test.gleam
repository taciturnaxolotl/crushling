import crushling/slack/mrkdwn
import crushling/thread/say
import gleam/list
import gleam/option
import gleam/string
import slackline/block

pub fn markdown_becomes_mrkdwn_test() {
  let assert "*Findings*\n• *Client ID*: <https://x.dev/a|the CLI's>\n  • `**kept**`" =
    mrkdwn.from_markdown(
      "## Findings\n- **Client ID**: [the CLI's](https://x.dev/a)\n  * `**kept**`",
    )
  // Code blocks are left as they are.
  let assert "```\n# not a heading\n- not a bullet\n```" =
    mrkdwn.from_markdown("```\n# not a heading\n- not a bullet\n```")
  // Not a heading, not a link.
  let assert "#hashtag and [brackets] (x)" =
    mrkdwn.from_markdown("#hashtag and [brackets] (x)")
}

pub fn a_report_is_a_collapsed_box_test() {
  let #(text, blocks) =
    say.subagent_report(
      "Jan",
      "Gemini research",
      False,
      "Done · 29 steps · 4m",
      "# Found\n**yes**",
      "https://slack.com/archives/C1/p1",
    )
  let assert "Report from Jan: Gemini research" = text
  let assert [block.Container(box)] = blocks
  let assert option.Some(True) = box.default_collapsed
  let shown = string.inspect(box.child_blocks)
  let assert True = string.contains(shown, "*Found*\\n*yes*")
  let assert True = string.contains(shown, "Open thread")
  // A long report keeps to the container's ten blocks.
  let long = string.repeat(string.repeat("word ", 500) <> "\n\n", 30)
  let #(_, blocks) =
    say.subagent_report("Jan", "x", False, "Done", long, "https://l")
  let assert [block.Container(box)] = blocks
  let assert True = list.length(box.child_blocks) <= 10
  // A stopped one says so in its title.
  let #(text, _) = say.subagent_report("Jan", "x", True, "Stopped", "", "")
  let assert "Jan stopped: x" = text
}
