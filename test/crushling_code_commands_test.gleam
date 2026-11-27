//// Code channel commands: what's offered, what they mean, and `!info`'s
//// answer from the repository.

import crushling/sink
import crushling/slack
import crushling/thread/repo
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import test_fs

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

@external(erlang, "proxy_test_ffi", "run")
fn run(
  program: String,
  args: List(String),
  env: List(String),
  cwd: String,
  timeout_ms: Int,
) -> #(Int, String)

@external(erlang, "proxy_test_ffi", "tmp_dir")
fn tmp_dir() -> String

/// A shell in `dir`, as the thread's sandbox is.
fn real_shell(dir: String) -> repo.Shell {
  fn(script) {
    test_fs.write(dir <> "/.script.sh", script)
    case run("sh", [dir <> "/.script.sh"], [], dir, 20_000) {
      #(0, out) -> Ok(out)
      _ -> Error(Nil)
    }
  }
}

fn sink_recording(code: process.Subject(#(String, String))) -> sink.Sink {
  sink.Sink(
    conversation: sink.Conversation("C", None),
    working: fn(_) { Nil },
    title: fn(_) { Nil },
    post: fn(_) { Ok("1") },
    post_blocks: fn(_, _) { Ok("1") },
    update_blocks: fn(_, _, _) { Ok(Nil) },
    delete: fn(_) { Ok(Nil) },
    post_plan: fn(_) { Ok("1") },
    update_plan: fn(_, _) { Ok(Nil) },
    reply: fn(_) { sink.Reply(show: fn(_, _, _) { Nil }, finish: fn(_) { [] }) },
    upload: fn(_, _) { Ok(Nil) },
    branch: fn(_, _, _) { Error("no") },
    open_code_channel: fn(_) { Error("no") },
    context: fn(_) { Nil },
    code: fn(diff, base, _) { process.send(code, #(diff, base)) },
  )
}

/// The Code tab shows every repository the agent changed, each path saying
/// which, and is emptied once nothing is changed.
pub fn code_tab_covers_every_changed_repo_test() {
  let dir = tmp_dir()
  let git = "git -c user.name=t -c user.email=t@t"
  let setup =
    "set -e; for r in wish uv; do git init -q -b main origin-$r.git --bare; git clone -q origin-$r.git work/$r 2>/dev/null; cd work/$r; echo one > a.txt; git add .; "
    <> git
    <> " commit -qm init; git push -q origin main; git remote set-head origin main; cd ../..; done"
  let assert Ok(_) = real_shell(dir)(setup)
  let work = dir <> "/work"
  let code = process.new_subject()
  let tab = sink_recording(code)
  let shell = real_shell(work)
  let info = repo.info(shell, "./wish")
  // Only the channel's own repository changed: plain paths, its base.
  test_fs.write(work <> "/wish/a.txt", "two\n")
  repo.show(shell, tab, "./wish", info)
  let assert Ok(#(diff, "main")) = process.receive(code, 1000)
  let assert True = string.contains(diff, "+++ b/a.txt")
  // Another one too: both, each under its directory.
  test_fs.write(work <> "/uv/fuzz_test.go", "package uv\n")
  repo.show(shell, tab, "./wish", info)
  let assert Ok(#(diff, _)) = process.receive(code, 1000)
  let assert True = string.contains(diff, "+++ b/wish/a.txt")
  let assert True = string.contains(diff, "+++ b/uv/fuzz_test.go")
  // Only the other one: still shown.
  let assert Ok(_) = shell("cd wish && git checkout -q a.txt")
  repo.show(shell, tab, "./wish", info)
  let assert Ok(#(diff, _)) = process.receive(code, 1000)
  let assert False = string.contains(diff, "a.txt")
  let assert True = string.contains(diff, "uv/fuzz_test.go")
  // Nothing: emptied, not left showing the last diff.
  let assert Ok(_) = shell("rm uv/fuzz_test.go")
  repo.show(shell, tab, "./wish", info)
  let assert Ok(#("", _)) = process.receive(code, 1000)
}
