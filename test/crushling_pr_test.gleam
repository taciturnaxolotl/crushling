//// Staged pull requests: what a proposal is made from, its card, and
//// opening it on GitHub as whoever pressed.

import crushling/commands
import crushling/github
import crushling/github/repo
import crushling/pr
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import test_fs

fn facts(upstream: String, ahead: String, base: String) -> String {
  "https://github.com/charmbracelet/hyper.git\n"
  <> upstream
  <> "\n"
  <> ahead
  <> "\n"
  <> base
  <> "\norigin/main\n--commits\nfix: keep canceled plans canceled\nadd a test\n--files\n10\t2\tdatastore/users.go\n5\t0\tdatastore/users_test.go\n"
}

pub fn proposal_test() {
  let assert Ok(p) =
    pr.from_facts(
      facts("origin/crushling/fix-restore", "0", "origin/fix/cancel"),
      "",
      "",
    )
  let assert "charmbracelet/hyper" = repo.full(p.repo)
  let assert pr.Proposal(
    head: "crushling/fix-restore",
    // Stacked on the branch it was made from, not main.
    base: "fix/cancel",
    commits: 2,
    files: 2,
    added: 15,
    removed: 2,
    ..,
  ) = p
  // Titled after its first commit, the body listing them oldest first.
  let assert "add a test" = p.title
  let assert "- add a test\n- fix: keep canceled plans canceled" = p.body
  let assert Ok(p) =
    pr.from_facts(facts("origin/crushling/x", "0", ""), "Fix it", "Because.")
  let assert pr.Proposal(base: "main", title: "Fix it", body: "Because.", ..) =
    p
}

pub fn nothing_to_propose_test() {
  let assert Error(why) = pr.from_facts(facts("", "", "origin/main"), "", "")
  let assert True = string.contains(why, "push it first")
  let assert Error(why) =
    pr.from_facts(facts("origin/crushling/x", "2", "origin/main"), "", "")
  let assert True = string.contains(why, "aren't pushed")
  let assert Error(why) =
    pr.from_facts(
      "https://example.com/x.git\norigin/crushling/x\n0\norigin/main\norigin/main\n--commits\na\n--files\n",
      "",
      "",
    )
  let assert True = string.contains(why, "isn't on GitHub")
  let assert Error(why) =
    pr.from_facts(
      "git@github.com:o/r.git\norigin/crushling/x\n0\norigin/main\norigin/main\n--commits\n--files\n",
      "",
      "",
    )
  let assert True = string.contains(why, "has no commits")
  let assert Error(why) =
    pr.from_facts(facts("origin/main", "0", "origin/main"), "", "")
  let assert True = string.contains(why, "isn't one crushling pushed")
  // The prefix alone names no branch.
  let assert Error(_) =
    pr.from_facts(facts("origin/crushling/", "0", "origin/main"), "", "")
}

pub fn github_repo_test() {
  let full = fn(url) { repo.parse_remote(url) |> result.map(repo.full) }
  let assert Ok("o/r") = full("https://github.com/o/r.git")
  let assert Ok("o/r") = full("git@github.com:o/r")
  let assert Ok("o/r") = full("ssh://git@github.com/o/r.git")
  let assert Error(Nil) = full("https://gitlab.com/o/r.git")
  let assert Error(Nil) = full("https://github.com/o")
  // Only a trailing .git goes, and odd names never get in.
  let assert Ok("o/r.github.io") = full("https://github.com/o/r.github.io.git")
  let assert Error(Nil) = full("https://github.com/o/..")
  let assert Error(Nil) = full("https://github.com/o/.git")
  let assert Error(Nil) = full("https://github.com/o/r%2F")
  // One key for every spelling.
  let assert Ok(a) = repo.parse_path("Octo", "Hyper.git")
  let assert Ok(b) = repo.from_api_segments("octo", "hyper")
  let assert True = repo.key(a) == repo.key(b)
}

pub fn card_test() {
  let assert Ok(p) =
    pr.from_facts(facts("origin/crushling/x", "0", "origin/main"), "Fix", "")
  let #(text, blocks) = pr.card(p)
  let assert True = string.contains(text, "Fix")
  let shown = string.inspect(blocks)
  let assert True = string.contains(shown, "`crushling/x` → `main`")
  let assert True = string.contains(shown, "2 commits · 2 files, +15 −2")
  list.each(pr.actions(), fn(action) {
    let assert True = string.contains(shown, action)
  })
  let #(line, settled) =
    pr.opened(p, "U1", "https://github.com/o/r/pull/7", 7, True)
  let assert True =
    string.starts_with(line, "<@U1> opened <https://github.com/o/r/pull/7|#7 ")
  let assert True = string.ends_with(line, "> as a draft")
  let assert False = string.contains(string.inspect(settled), pr.open_action)
}

pub fn pr_command_test() {
  let assert commands.PrCommand("") = commands.parse("!pr")
  let assert commands.PrCommand("Fix the thing") =
    commands.parse("!pr Fix the thing")
}

fn github(
  status: Int,
  body: String,
  seen: process.Subject(request.Request(String)),
) -> github.Config {
  github.Config(client_id: "Iv1.test", client_secret: None, send: fn(req) {
    process.send(seen, req)
    Ok(response.new(status) |> response.set_body(body))
  })
}

pub fn open_test() {
  let assert Ok(p) =
    pr.from_facts(
      facts("origin/crushling/x", "0", "origin/main"),
      "Fix",
      "Why.",
    )
  let seen = process.new_subject()
  let config =
    github(
      201,
      "{\"number\":7,\"html_url\":\"https://github.com/o/r/pull/7\"}",
      seen,
    )
  let assert Ok(#(7, "https://github.com/o/r/pull/7")) =
    pr.open(config, "ghu_presser", p, True)
  let assert Ok(req) = process.receive(seen, 0)
  let assert http.Post = req.method
  let assert "/repos/charmbracelet/hyper/pulls" = req.path
  let assert Ok("Bearer ghu_presser") = request.get_header(req, "authorization")
  let assert True = string.contains(req.body, "\"draft\":true")
  let assert True = string.contains(req.body, "\"head\":\"crushling/x\"")
  // GitHub's reason comes through, in words.
  let config =
    github(
      422,
      "{\"message\":\"Validation Failed\",\"errors\":[{\"message\":\"A pull request already exists for o:crushling/x.\"}]}",
      process.new_subject(),
    )
  let assert Error(
    "GitHub said: A pull request already exists for o:crushling/x.",
  ) = pr.open(config, "t", p, False)
  let config = github(403, "{}", process.new_subject())
  let assert Error(why) = pr.open(config, "t", p, False)
  let assert True = string.contains(why, "can't open pull requests")
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

/// Run a script from a file: the harness quotes arguments naively.
fn sh(dir: String, script: String) -> #(Int, String) {
  test_fs.write(dir <> "/script.sh", script)
  run("sh", [dir <> "/script.sh"], [], dir, 20_000)
}

fn facts_in(dir: String) -> #(Int, String) {
  sh(dir, pr.facts(dir <> "/w"))
}

/// The script, against real git: a branch stacked on another, pushed.
pub fn facts_from_real_git_test() {
  let dir = tmp_dir()
  let git = "git -c user.name=t -c user.email=t@t"
  let assert #(0, _) =
    sh(
      dir,
      "set -e; git init -q --bare -b main origin.git; git clone -q origin.git w 2>/dev/null; cd w; "
        <> git
        <> " commit -q --allow-empty -m init; git push -q origin main; git checkout -q -b fix/cancel; echo a > a; git add a; "
        <> git
        <> " commit -qm 'fix cancel'; git push -q origin fix/cancel; git checkout -q -b crushling/fix-restore; echo b > b; git add b; "
        <> git
        <> " commit -qm 'keep plans'; git push -q -u origin HEAD:crushling/fix-restore 2>/dev/null; git remote set-url origin https://github.com/o/r.git",
    )
  let assert #(0, out) = facts_in(dir)
  let assert Ok(pr.Proposal(
    head: "crushling/fix-restore",
    base: "fix/cancel",
    title: "keep plans",
    commits: 1,
    ..,
  )) = pr.from_facts(out, "", "")
  // Not pushed yet: says so.
  let assert #(0, _) =
    sh(dir, "cd w && echo c > c && git add c && " <> git <> " commit -qm more")
  let assert #(0, out) = facts_in(dir)
  let assert Error(why) = pr.from_facts(out, "", "")
  let assert True = string.contains(why, "aren't pushed")
}
