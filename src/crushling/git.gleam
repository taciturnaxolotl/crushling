//// The repositories an agent clones into its workspace: shell scripts that
//// find and inspect them, and readers for what the scripts print. Each runs
//// in the workspace through a `Shell`.

import crushling/repo_url
import crushling/snapshot.{type Change}
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// Runs a script in the workspace; its output if it succeeds.
pub type Shell =
  fn(String) -> Result(String, Nil)

pub type RepoInfo {
  RepoInfo(url: String, branch: String, base: String)
}

/// A repository that a code channel can show. The channel is called `name`
/// unless the agent picks another name.
pub type Found {
  Found(dir: String, info: RepoInfo, name: String)
}

/// Whether the work is committed and pushed.
pub type PushState {
  PushState(
    /// Files not committed.
    uncommitted: Int,
    /// The branch it tracks, or "".
    upstream: String,
    /// Commits ahead of `upstream`, when that could be counted.
    ahead: Result(Int, Nil),
  )
}

/// Find the repository in workspace directory `dir`. With no `dir`, use the
/// first repository in the workspace.
pub fn find(shell: Shell, dir: String) -> Result(Found, String) {
  let dir = case dir {
    "" -> repos(shell) |> list.first |> result.unwrap("")
    dir -> dir
  }
  let is_repo =
    dir != "" && shell(is_repo(dir)) |> result.map(string.trim) == Ok("yes")
  case dir, is_repo {
    "", _ ->
      Error("there is no git repository in the workspace; clone one first")
    dir, False -> Error(dir <> " is not a git repository")
    dir, True -> {
      let info = info(shell, dir)
      let name = case repo_url.name(info.url) {
        "" -> string.replace(dir, "./", "")
        name -> name
      }
      Ok(Found(dir:, info:, name:))
    }
  }
}

/// The repositories in the workspace, as directories relative to it.
pub fn repos(shell: Shell) -> List(String) {
  shell(list_repos())
  |> result.unwrap("")
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(fn(line) { line != "" })
}

/// The first repository in the workspace with work of the agent's in it.
pub fn changed(shell: Shell) -> Result(String, Nil) {
  case shell(changed_repo()) |> result.map(string.trim) {
    Ok("") | Error(Nil) -> Error(Nil)
    Ok(dir) -> Ok(dir)
  }
}

pub fn info(shell: Shell, dir: String) -> RepoInfo {
  shell(repo_info(dir))
  |> result.map(parse_repo_info)
  |> result.unwrap(RepoInfo("", "", ""))
}

/// The files that changed in the repository, compared with its base.
pub fn changes(shell: Shell, dir: String) -> List(Change) {
  shell(repo_numstat(dir))
  |> result.map(snapshot.parse_numstat)
  |> result.unwrap([])
}

pub fn push_state(shell: Shell, dir: String) -> PushState {
  let lines =
    shell(push_state_script(dir))
    |> result.unwrap("")
    |> string.split("\n")
    |> list.map(string.trim)
  let at = fn(i) { list.drop(lines, i) |> list.first |> result.unwrap("") }
  PushState(
    uncommitted: int.parse(at(0)) |> result.unwrap(0),
    upstream: at(1),
    ahead: int.parse(at(2)),
  )
}

/// Prints the repositories in the workspace, one directory per line,
/// relative to it: what an agent cloned.
pub fn list_repos() -> String {
  "for d in $(find . -mindepth 2 -maxdepth 4 -name .git -not -path './.crush/*' -not -path './.home/*' -not -path './.slack/*' 2>/dev/null); do dirname \"$d\"; done"
}

fn quote(text: String) -> String {
  "'" <> string.replace(text, "'", "'\\''") <> "'"
}

/// Prints the first repository in the workspace with work of the agent's
/// in it: files changed, or commits that aren't on any remote branch.
pub fn changed_repo() -> String {
  list_repos()
  <> " | while read -r d; do if [ -n \"$(git -C \"$d\" status --porcelain 2>/dev/null | head -n 1)\" ] || [ \"$(git -C \"$d\" rev-list --count HEAD --not --remotes 2>/dev/null)\" != 0 ]; then echo \"$d\"; break; fi; done"
}

/// Prints "yes" when `dir` is the top of a git repository.
pub fn is_repo(dir: String) -> String {
  "cd "
  <> quote(dir)
  <> " 2>/dev/null && [ \"$(git rev-parse --show-toplevel 2>/dev/null)\" = \"$(pwd -P)\" ] && echo yes"
}

/// Prints, one per line: the origin URL, the current branch, and the
/// default branch, for the repository in `dir`.
pub fn repo_info(dir: String) -> String {
  "cd "
  <> quote(dir)
  <> " && git remote get-url origin 2>/dev/null; git rev-parse --abbrev-ref HEAD 2>/dev/null; git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||'"
}

pub fn parse_repo_info(output: String) -> RepoInfo {
  let lines = string.split(output, "\n") |> list.map(string.trim)
  let at = fn(i) { list.drop(lines, i) |> list.first |> result.unwrap("") }
  RepoInfo(url: at(0), branch: at(1), base: at(2))
}

/// Prints, one per line, for the repository in `dir`: how many files
/// aren't committed, the branch it tracks (or nothing), and how many
/// commits it is ahead of it.
fn push_state_script(dir: String) -> String {
  "cd "
  <> quote(dir)
  <> " && git status --porcelain 2>/dev/null | wc -l; u=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); echo \"$u\"; [ -n \"$u\" ] && git rev-list --count '@{u}..HEAD' 2>/dev/null || echo"
}

/// The repository's changes against its default branch: commits made on
/// top of it and the working tree, untracked files included. A scratch
/// index keeps the repository's own index untouched.
fn against_base(dir: String, diff_args: String) -> String {
  "cd "
  <> quote(dir)
  <> " && idx=$(mktemp) && cp .git/index \"$idx\" 2>/dev/null; GIT_INDEX_FILE=\"$idx\" git add -N -A >/dev/null 2>&1; base=$(git merge-base HEAD \"$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo HEAD)\" 2>/dev/null || echo HEAD); GIT_INDEX_FILE=\"$idx\" git diff --no-color --no-ext-diff "
  <> diff_args
  <> " \"$base\"; rm -f \"$idx\""
}

pub fn repo_diff(dir: String) -> String {
  against_base(dir, "")
}

/// `repo_diff`, with the repository's directory before every path, for
/// showing several repositories' changes as one diff.
pub fn repo_diff_prefixed(dir: String) -> String {
  let prefix = case string.starts_with(dir, "./") {
    True -> string.drop_start(dir, 2)
    False -> dir
  }
  against_base(
    dir,
    "--src-prefix="
      <> quote("a/" <> prefix <> "/")
      <> " --dst-prefix="
      <> quote("b/" <> prefix <> "/"),
  )
}

pub fn repo_numstat(dir: String) -> String {
  against_base(dir, "--numstat")
}
