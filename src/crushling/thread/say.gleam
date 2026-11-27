//// What a thread says in Slack, as mrkdwn and blocks. Everything here is
//// pure; the thread decides when to say it.

import crushling/agent/post_mortem.{type PostMortem}
import crushling/crush/catalog.{type Current}
import crushling/git.{type PushState, type RepoInfo}
import crushling/render
import crushling/slack/blocks
import crushling/snapshot.{type Change}
import crushling/text
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import slackline/block

/// A line in italics, as the bridge's own remarks are.
pub fn aside(line: String) -> String {
  "_" <> line <> "_"
}

/// A session's title, from the first line of the prompt that started it.
pub fn session_title(prompt: String) -> String {
  let line = case string.split_once(string.trim(prompt), "\n") {
    Ok(#(first, _)) -> first
    Error(Nil) -> prompt
  }
  text.clip(line, 60)
}

pub const stalled =
  "_no word from the agent in 10 minutes; it may be stuck. Reply `!stop` to stop it._"

/// The note ending a run whose agent went away, saying why as best the
/// backend could tell, with crush's last complaint quoted when there is one.
pub fn lost(why: PostMortem) -> String {
  let #(cause, words) = case why {
    post_mortem.StillRunning(last_words:) -> #(
      "The connection to the agent's sandbox dropped and couldn't be restored",
      last_words,
    )
    post_mortem.Vanished -> #("The agent's sandbox was deleted", "")
    post_mortem.OutOfMemory(limit: "") -> #(
      "The agent's sandbox ran out of memory and was killed",
      "",
    )
    post_mortem.OutOfMemory(limit:) -> #(
      "The agent's sandbox ran out of memory (its limit is "
        <> memory(limit)
        <> ") and was killed",
      "",
    )
    post_mortem.Exited(code: Some(137), last_words:) -> #(
      "The agent's sandbox was killed (exit code 137)",
      last_words,
    )
    post_mortem.Exited(code: Some(0), last_words:) -> #(
      "The agent quit mid-run (exit code 0)",
      last_words,
    )
    post_mortem.Exited(code: Some(code), last_words:) -> #(
      "The agent crashed (exit code " <> int.to_string(code) <> ")",
      last_words,
    )
    post_mortem.Exited(code: None, last_words:) -> #(
      "The agent crashed",
      last_words,
    )
    post_mortem.Unknown(reason:) -> #(
      "The agent stopped for an unknown reason",
      reason,
    )
  }
  aside(
    cause
    <> ", so this run is over. Send a message to start it again; the workspace is kept.",
  )
  <> case words {
    "" -> ""
    words -> "\n> `" <> text.clip(words, 300) <> "`"
  }
}

/// A docker memory size, such as `4g`, in words: "4 GB".
fn memory(limit: String) -> String {
  let lower = string.lowercase(string.trim(limit))
  let unit = fn(suffix, name) {
    case string.ends_with(lower, suffix) {
      True -> Ok(string.drop_end(lower, 1) <> " " <> name)
      False -> Error(Nil)
    }
  }
  unit("g", "GB")
  |> result.lazy_or(fn() { unit("m", "MB") })
  |> result.lazy_or(fn() { unit("k", "KB") })
  |> result.unwrap(limit)
}

pub const no_repo = "_No repository here yet._"

pub const asleep =
  "_The agent is asleep; send a message to wake it, then ask again._"

pub const not_connected =
  "_the agent isn't connected right now; try again in a moment._"

pub fn not_sent(reason: String) -> String {
  aside("couldn't send that to the agent: " <> reason)
}

/// Said in the thread when the work moves to a code channel.
pub fn moved(repo: String, channel: String) -> String {
  aside("working on `" <> repo <> "` in <#" <> channel <> ">")
}

/// The answer to `propose_pr` once its card is up.
pub fn proposed(head: String, base: String) -> String {
  "Posted a card proposing `"
  <> head
  <> "` → `"
  <> base
  <> "`; a person opens the PR from it."
}

/// Where the work in a repository stands, for `!info`: its branch and base,
/// what changed, and whether it's on GitHub.
pub fn status(
  info: RepoInfo,
  changes: List(Change),
  push: PushState,
) -> String {
  let #(added, removed) =
    list.fold(changes, #(0, 0), fn(sum, change) {
      #(
        sum.0 + result.unwrap(change.added, 0),
        sum.1 + result.unwrap(change.removed, 0),
      )
    })
  let changed = case changes {
    [] -> "nothing yet"
    _ ->
      blocks.count(list.length(changes), "file", "files")
      <> ", +"
      <> int.to_string(added)
      <> " −"
      <> int.to_string(removed)
  }
  let github = case push.upstream, push.ahead {
    "", _ -> "not pushed"
    upstream, Ok(0) -> "pushed to `" <> upstream <> "`, up to date"
    upstream, Ok(ahead) ->
      blocks.count(ahead, "commit", "commits")
      <> " not pushed yet (`"
      <> upstream
      <> "`)"
    upstream, Error(Nil) -> "tracking `" <> upstream <> "`"
  }
  let github = case push.uncommitted {
    0 -> github
    n -> github <> "; " <> blocks.count(n, "file", "files") <> " not committed"
  }
  let branch = case info.branch, info.base {
    "", _ -> "unknown"
    branch, "" -> "`" <> branch <> "`"
    branch, base -> "`" <> branch <> "` (from `" <> base <> "`)"
  }
  "*Branch* " <> branch <> "\n*Changed* " <> changed <> "\n*GitHub* " <> github
}

// Models ----------------------------------------------------------------------

pub fn model_gone(model: String) -> String {
  aside(
    "this thread was set to `"
    <> model
    <> "`, which isn't offered anymore, so it's back on the default model.",
  )
}

pub fn reasoning_dropped(model: String) -> String {
  aside(
    "`"
    <> model
    <> "` doesn't take the reasoning level this thread had anymore, so it's on the model's own default.",
  )
}

pub fn model_refused(model: String, reason: String) -> String {
  aside(
    "crush wouldn't run `"
    <> model
    <> "` ("
    <> reason
    <> "), so this thread is back on the default model.",
  )
}

pub fn no_model_card(reason: String) -> String {
  aside("couldn't show the model: " <> reason <> ".")
}

pub fn not_switched(reason: String) -> String {
  aside("couldn't switch the model: " <> reason <> ".")
}

/// The note on a model card whose Confirm was refused.
pub fn refused_note(reason: String) -> String {
  "couldn't switch: " <> reason <> "."
}

pub fn switched(user: String, current: Current) -> String {
  aside(
    "<@"
    <> user
    <> "> switched the model to "
    <> catalog.summary(current)
    <> ". It applies from the next turn.",
  )
}

/// The fallback text of a model card.
pub fn model_card_text(current: Current) -> String {
  "Model: " <> current.model.name
}

// Subagents -------------------------------------------------------------------

/// A subagent's first message in the channel: who, what, and how it's
/// going.
pub fn subagent_card(
  who: String,
  scope: String,
  status: String,
) -> #(String, List(block.Block)) {
  let line = "*" <> who <> "* · " <> scope
  #(line, [blocks.text(line), blocks.context(status)])
}

pub const subagent_working = "Subagent · working"

/// How a finished subagent went, in a few words: "Done · 5 steps · 1m 12s".
pub fn subagent_outcome(
  status: render.TaskStatus,
  stopped: Bool,
  steps: Int,
  took_ms: Int,
) -> String {
  let how = case status, stopped {
    render.Failed, True -> "Stopped"
    render.Failed, False -> "Ran into trouble"
    _, _ -> "Done"
  }
  how <> " · " <> render.steps(steps) <> " · " <> took(took_ms)
}

fn took(ms: Int) -> String {
  let s = ms / 1000
  case s < 60 {
    True -> int.to_string(int.max(s, 1)) <> "s"
    False ->
      int.to_string(s / 60)
      <> "m"
      <> case s % 60 {
        0 -> ""
        rest -> " " <> int.to_string(rest) <> "s"
      }
  }
}

/// The note in the parent's conversation when a subagent finishes, linking
/// to its thread.
pub fn subagent_done(
  who: String,
  scope: String,
  failed: Bool,
  status: String,
  link: String,
) -> #(String, List(block.Block)) {
  let verb = case failed {
    True -> "stopped on"
    False -> "finished"
  }
  let line = "*" <> who <> "* " <> verb <> " " <> scope
  #(line, [
    blocks.text(line <> " · <" <> link <> "|open its thread>"),
    blocks.context(status),
  ])
}
