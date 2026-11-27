//// Staged pull requests. The agent pushes a `crushling/…` branch; `/pr`
//// (or the agent's `propose_pr`) posts a card for it in the conversation,
//// and a person opens the PR from the card, as themselves. Nothing opens
//// a PR without someone pressing the button.

import crushling/github
import crushling/github/http
import crushling/github/repo.{type Repo}
import crushling/github/route
import crushling/slack/blocks
import crushling/snapshot
import gleam/dynamic/decode
import gleam/http as gleam_http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string
import slackline/block
import slackline/element
import slackline/element/button
import slackline/interaction

/// A PR to open, as the card shows it.
pub type Proposal {
  Proposal(
    repo: Repo,
    /// The branch on GitHub, like `crushling/fix-flaky-test`.
    head: String,
    base: String,
    title: String,
    body: String,
    commits: Int,
    files: Int,
    added: Int,
    removed: Int,
  )
}

/// Prints what a proposal needs, for the repository in `dir`, in sections:
/// the origin URL, the branch it tracks on GitHub, how many commits aren't
/// pushed, the nearest remote branch it was made from, the default branch,
/// then (after `--commits`) the subjects of its commits since that base,
/// and (after `--files`) its numstat against it.
pub fn facts(dir: String) -> String {
  "cd '" <> string.replace(dir, "'", "'\\''") <> "' || exit 1
u=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
git remote get-url origin 2>/dev/null
echo \"$u\"
[ -n \"$u\" ] && git rev-list --count '@{u}..HEAD' 2>/dev/null || echo
d=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
base=$(for r in $(git for-each-ref --format='%(refname:short)' refs/remotes/origin); do
  [ \"$r\" = origin/HEAD ] || [ \"$r\" = origin ] || [ \"$r\" = \"$u\" ] && continue
  git merge-base --is-ancestor \"$r\" HEAD 2>/dev/null || continue
  echo \"$(git rev-list --count \"$r..HEAD\") $r\"
done | sort -n | head -n 1 | cut -d' ' -f2)
[ -n \"$base\" ] || base=$d
echo \"$base\"
echo \"$d\"
echo --commits
[ -n \"$base\" ] && git log --format=%s \"$base..HEAD\" 2>/dev/null
echo --files
[ -n \"$base\" ] && git diff --numstat \"$base...HEAD\" 2>/dev/null
true"
}

/// A proposal from `facts`' output, titled `title` (else after its last
/// commit), or why there's nothing to propose.
pub fn from_facts(
  output: String,
  title: String,
  body: String,
) -> Result(Proposal, String) {
  let #(head, rest) = case string.split_once(output, "\n--commits\n") {
    Ok(pair) -> pair
    Error(Nil) -> #(output, "")
  }
  let #(commits, files) = case string.split_once(rest, "--files\n") {
    Ok(pair) -> pair
    Error(Nil) -> #(rest, "")
  }
  let lines = string.split(head, "\n") |> list.map(string.trim)
  let at = fn(i) { list.drop(lines, i) |> list.first |> result.unwrap("") }
  let subjects =
    string.split(commits, "\n")
    |> list.map(string.trim)
    |> list.filter(fn(line) { line != "" && line != "--files" })
  let changes = snapshot.parse_numstat(files)
  use repo <- result.try(
    repo.parse_remote(at(0))
    |> result.replace_error("this repository isn't on GitHub"),
  )
  // The same branches the bridge lets the agent push.
  let ours = "origin/" <> string.replace(route.branch_prefix, "refs/heads/", "")
  let upstream = at(1)
  use head <- result.try(
    case string.starts_with(upstream, ours) && upstream != ours, upstream {
      True, _ -> Ok(string.drop_start(upstream, string.length("origin/")))
      False, "origin/" <> branch ->
        Error(
          "the branch `"
          <> branch
          <> "` isn't one crushling pushed: push it as `crushling/<what>` first",
        )
      False, "" ->
        Error(
          "the branch isn't on GitHub yet: push it first, like `git push -u origin HEAD:crushling/<what>`",
        )
      False, other ->
        Error("the branch tracks `" <> other <> "`, not a branch on origin")
    },
  )
  use <- guard(
    int.parse(at(2)) |> result.unwrap(0) > 0,
    "some commits aren't pushed yet: push first",
  )
  let base = case at(3) {
    "origin/" <> branch -> branch
    "" -> string.replace(at(4), "origin/", "")
    other -> other
  }
  use <- guard(base == "", "couldn't tell which branch this was made from")
  use <- guard(
    subjects == [],
    "`" <> head <> "` has no commits on `" <> base <> "`",
  )
  let title = case string.trim(title), list.last(subjects) {
    "", Ok(first) -> first
    "", Error(Nil) -> head
    title, _ -> title
  }
  let body = case string.trim(body) {
    "" ->
      list.map(list.reverse(subjects), fn(s) { "- " <> s }) |> string.join("\n")
    body -> body
  }
  Ok(Proposal(
    repo:,
    head:,
    base:,
    title:,
    body:,
    commits: list.length(subjects),
    files: list.length(changes),
    added: list.fold(changes, 0, fn(n, c) { n + result.unwrap(c.added, 0) }),
    removed: list.fold(changes, 0, fn(n, c) { n + result.unwrap(c.removed, 0) }),
  ))
}

fn guard(
  bad: Bool,
  why: String,
  next: fn() -> Result(a, String),
) -> Result(a, String) {
  case bad {
    True -> Error(why)
    False -> next()
  }
}

// The card -----------------------------------------------------------------

pub const open_action = "crushling_pr_open"

pub const draft_action = "crushling_pr_draft"

pub const dismiss_action = "crushling_pr_dismiss"

pub fn actions() -> List(String) {
  [open_action, draft_action, dismiss_action]
}

/// A press on a PR card: who, the card, what they chose (`open`, `draft`
/// or `dismiss`), and where to answer them privately.
pub type Pressed {
  Pressed(
    user: String,
    card_ts: String,
    choice: String,
    respond: Option(String),
  )
}

/// A press on a PR card's buttons.
pub fn decode(
  action: interaction.BlockAction,
  payload: interaction.BlockActionsPayload,
) -> Result(Pressed, Nil) {
  case action, payload.container {
    interaction.ButtonAction(value: Some(choice), ..),
      Some(interaction.MessageContainer(message_ts: Some(card_ts), ..))
    ->
      Ok(Pressed(
        user: payload.user.id,
        card_ts:,
        choice:,
        respond: payload.response_url,
      ))
    _, _ -> Error(Nil)
  }
}

fn summary(p: Proposal) -> String {
  blocks.count(p.commits, "commit", "commits")
  <> " · "
  <> blocks.count(p.files, "file", "files")
  <> ", +"
  <> int.to_string(p.added)
  <> " −"
  <> int.to_string(p.removed)
}

fn heading(p: Proposal) -> String {
  "*"
  <> p.title
  <> "*\n`"
  <> p.head
  <> "` → `"
  <> p.base
  <> "` in "
  <> repo.full(p.repo)
}

/// The card proposing `p`: its buttons open it as whoever presses.
pub fn card(p: Proposal) -> #(String, List(block.Block)) {
  let text = "Pull request ready: " <> p.title
  #(text, [
    blocks.markdown(heading(p)),
    blocks.context(summary(p) <> " · opens as whoever presses"),
    block.actions(
      elements: [
        element.button(text: "Open PR", action_id: open_action, with: [
          button.style(block.Primary),
          button.value("open"),
        ]),
        element.button(text: "Open as draft", action_id: draft_action, with: [
          button.value("draft"),
        ]),
        element.button(text: "Dismiss", action_id: dismiss_action, with: [
          button.value("dismiss"),
        ]),
      ],
      with: [],
    ),
  ])
}

/// The card once something happened to it: `outcome` says what.
pub fn settled(p: Proposal, outcome: String) -> #(String, List(block.Block)) {
  #(p.title, [blocks.markdown(heading(p)), blocks.context(outcome)])
}

// Opening it ----------------------------------------------------------------

/// Open `p` on GitHub with `token` (the presser's). Its number and URL, or
/// why not, in words for the card.
pub fn open(
  config: github.Config,
  token: String,
  p: Proposal,
  draft: Bool,
) -> Result(#(Int, String), String) {
  let sent =
    http.api(
      gleam_http.Post,
      "/repos/" <> repo.full(p.repo) <> "/pulls",
      http.Bearer(token),
    )
    |> http.with_json(
      json.object([
        #("title", json.string(p.title)),
        #("head", json.string(p.head)),
        #("base", json.string(p.base)),
        #("body", json.string(p.body)),
        #("draft", json.bool(draft)),
      ]),
    )
    |> config.send
  case sent {
    Error(_) -> Error("couldn't reach GitHub; try again")
    Ok(resp) if resp.status == 201 ->
      json.parse(resp.body, {
        use number <- decode.field("number", decode.int)
        use url <- decode.field("html_url", decode.string)
        decode.success(#(number, url))
      })
      |> result.replace_error(
        "GitHub opened it, but its answer didn't make sense",
      )
    Ok(resp) -> Error(refusal(resp.status, resp.body))
  }
}

/// GitHub's reason, in words: its `message` and first error, which never
/// hold a token.
fn refusal(status: Int, body: String) -> String {
  let said =
    json.parse(body, {
      use message <- decode.optional_field("message", "", decode.string)
      use errors <- decode.optional_field(
        "errors",
        [],
        decode.list({
          use message <- decode.optional_field("message", "", decode.string)
          decode.success(message)
        }),
      )
      decode.success(#(message, errors))
    })
  case status, said {
    403, _ | 404, _ -> "your GitHub account can't open pull requests there"
    _, Ok(#(_, [detail, ..])) if detail != "" -> "GitHub said: " <> detail
    _, Ok(#(message, _)) if message != "" -> "GitHub said: " <> message
    _, _ -> "GitHub answered " <> int.to_string(status)
  }
}
