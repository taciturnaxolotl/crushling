//// Code channel commands: what's offered, what they mean, and `!info`'s
//// answer from the repository.

import crushling/slack
import crushling/thread/repo
import gleam/list
import gleam/string

pub fn info_is_a_command_test() {
  let assert slack.InfoCommand = slack.command("!info")
  let assert slack.InfoCommand = slack.command(" !INFO ")
  let assert True = string.contains(slack.help, "`/info`")
}

/// Slack refuses the whole set if one name is its own, or too long.
pub fn offered_commands_are_ours_to_offer_test() {
  let builtins = [
    "status", "archive", "away", "active", "invite", "leave", "remind", "topic",
    "who", "msg", "dm", "dnd", "feed", "giphy", "join", "mute", "open", "search",
    "shortcuts", "collapse", "expand", "apps", "call", "me", "shrug", "rename",
    "remove", "kick", "prefs", "help",
  ]
  let names = list.map(slack.code_commands, fn(command) { command.0 })
  let assert True = list.length(names) <= 10
  list.each(slack.code_commands, fn(command) {
    let #(name, description, _) = command
    let assert False = list.contains(builtins, name)
    let assert True = string.length(name) >= 1 && string.length(name) <= 31
    let assert False = string.starts_with(name, "/")
    let assert True = description != ""
    // Each stands for a `!` command.
    let assert False = slack.command("!" <> name) == slack.NotACommand
  })
  let assert True = list.unique(names) == names
}

/// A shell that answers each script by what it asks.
fn shell(push_state: String, numstat: String) -> repo.Shell {
  fn(script) {
    case
      string.contains(script, "rev-parse --abbrev-ref HEAD"),
      string.contains(script, "@{u}"),
      string.contains(script, "--numstat")
    {
      True, _, _ ->
        Ok("https://github.com/octo/repo.git\ncrushling/fix\nmain\n")
      _, True, _ -> Ok(push_state)
      _, _, True -> Ok(numstat)
      _, _, _ -> Error(Nil)
    }
  }
}

pub fn info_test() {
  let text = repo.status(shell("0\n\n\n", "3\t1\ta.go\n2\t0\tb.go\n"), "/w/r")
  let assert True =
    string.contains(text, "*Branch* `crushling/fix` (from `main`)")
  let assert True = string.contains(text, "*Changed* 2 files, +5 −1")
  let assert True = string.contains(text, "*GitHub* not pushed")
  let text =
    repo.status(shell("2\norigin/crushling/fix\n3\n", "3\t1\ta.go\n"), "/w/r")
  let assert True =
    string.contains(text, "3 commits not pushed yet (`origin/crushling/fix`)")
  let assert True = string.contains(text, "2 files not committed")
  let text = repo.status(shell("0\norigin/crushling/fix\n0\n", ""), "/w/r")
  let assert True =
    string.contains(text, "pushed to `origin/crushling/fix`, up to date")
  let assert True = string.contains(text, "*Changed* nothing yet")
}
