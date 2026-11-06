//// Workspace snapshots in a private git repository under `.crush/`, so a
//// run's diff covers every change however it was made, `bash` included,
//// without touching the workspace's own repository. The commands run
//// through the server's shell endpoint, on the agent's side of any sandbox.
////
//// Every snapshot is written from a fresh index, so the workspace's
//// `.gitignore` always applies: a build output ignored after it first
//// appeared is not carried along. Binary files are listed but their
//// contents are left out of the patch.

import gleam/int
import gleam/list
import gleam/result
import gleam/string

const dir = ".crush/crushling-snap"

fn git(args: String) -> String {
  "GIT_DIR=" <> dir <> " GIT_WORK_TREE=. git " <> args
}

/// Prints the tree id of the workspace as it is now.
pub fn take() -> String {
  let index = "GIT_INDEX_FILE=" <> dir <> "/snapshot-index "
  "{ [ -d "
  <> dir
  <> " ] || git init -q --bare "
  <> dir
  <> "; } && mkdir -p "
  <> dir
  <> "/info && printf '/.crush/\\n/.home/\\n/.slack/\\n' > "
  <> dir
  <> "/info/exclude && rm -f "
  <> dir
  <> "/snapshot-index && "
  <> index
  <> git("add -A >/dev/null")
  <> " && "
  <> index
  <> git("write-tree")
}

pub fn parse_tree(output: String) -> Result(String, Nil) {
  let tree = string.trim(output)
  case string.length(tree) >= 40 && is_hex(tree) {
    True -> Ok(tree)
    False -> Error(Nil)
  }
}

fn is_hex(text: String) -> Bool {
  string.to_graphemes(text)
  |> list.all(fn(g) { string.contains("0123456789abcdef", g) })
}

pub fn diff(from: String, to: String) -> String {
  git("diff --no-color --no-ext-diff " <> from <> " " <> to)
}

pub fn numstat(from: String, to: String) -> String {
  git("diff --numstat --no-color " <> from <> " " <> to)
}

pub type Change {
  /// Lines added and removed; both errors for a binary file.
  Change(path: String, added: Result(Int, Nil), removed: Result(Int, Nil))
}

/// Parse `git diff --numstat`: `added<TAB>removed<TAB>path`, with `-` for
/// binary files.
pub fn parse_numstat(output: String) -> List(Change) {
  string.split(output, "\n")
  |> list.filter_map(fn(line) {
    case string.split(line, "\t") {
      [added, removed, first, ..rest] ->
        Ok(Change(
          path: string.join([first, ..rest], "\t"),
          added: int.parse(added),
          removed: int.parse(removed),
        ))
      _ -> Error(Nil)
    }
  })
}

pub fn is_binary(change: Change) -> Bool {
  result.is_error(change.added)
}

/// Prints the repositories in the workspace, one directory per line,
/// relative to it: what an agent cloned.
pub fn list_repos() -> String {
  "for d in $(find . -mindepth 2 -maxdepth 4 -name .git -not -path './.crush/*' -not -path './.home/*' -not -path './.slack/*' 2>/dev/null); do dirname \"$d\"; done"
}

fn quote(text: String) -> String {
  "'" <> string.replace(text, "'", "'\\''") <> "'"
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

pub type RepoInfo {
  RepoInfo(url: String, branch: String, base: String)
}

pub fn parse_repo_info(output: String) -> RepoInfo {
  let lines = string.split(output, "\n") |> list.map(string.trim)
  let at = fn(i) { list.drop(lines, i) |> list.first |> result.unwrap("") }
  RepoInfo(url: at(0), branch: at(1), base: at(2))
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

pub fn repo_numstat(dir: String) -> String {
  against_base(dir, "--numstat")
}

/// The host and path of a clone URL, without a trailing `.git`: from
/// `https://host/path`, `ssh://git@host/path`, `git@host:path`, or a local
/// path (host "").
fn host_and_path(url: String) -> #(String, String) {
  let url = string.trim(url)
  let #(host, path) = case string.split_once(url, "://") {
    Ok(#(_, rest)) ->
      case string.split_once(rest, "/") {
        Ok(#(host, path)) -> #(host, path)
        Error(Nil) -> #(rest, "")
      }
    Error(Nil) ->
      case string.starts_with(url, "/") || string.starts_with(url, ".") {
        True -> #("", url)
        False ->
          case string.split_once(url, ":") {
            Ok(#(host, path)) -> #(host, path)
            Error(Nil) -> #("", url)
          }
      }
  }
  let host = case string.split_once(host, "@") {
    Ok(#(_, host)) -> host
    Error(Nil) -> host
  }
  let path = case string.ends_with(path, ".git") {
    True -> string.drop_end(path, 4)
    False -> path
  }
  #(string.lowercase(host), path)
}

fn segments(path: String) -> List(String) {
  string.split(path, "/") |> list.filter(fn(part) { part != "" })
}

/// A short name for a clone URL, for titles and the context bar:
/// "owner/repo", or just "repo" when the owner isn't readable (a local
/// path, or a DID as on tangled).
pub fn repo_name(url: String) -> String {
  let #(host, path) = host_and_path(url)
  case list.reverse(segments(path)) {
    [] -> ""
    [repo, owner, ..] if host != "" ->
      case string.contains(owner, ":") {
        True -> repo
        False -> owner <> "/" <> repo
      }
    [repo, ..] -> repo
  }
}

/// Hosts that serve a repository's page at `https://host/owner/repo`.
const browsable_hosts = [
  "github.com", "gitlab.com", "codeberg.org", "bitbucket.org",
]

/// A browsable URL for a clone URL, when the host is one known to serve
/// repositories at their path; "" otherwise.
pub fn web_url(url: String) -> String {
  let #(host, path) = host_and_path(url)
  case list.contains(browsable_hosts, host), segments(path) {
    True, [_, _, ..] as parts ->
      "https://" <> host <> "/" <> string.join(parts, "/")
    _, _ -> ""
  }
}

/// Whether a shell command clones a repository.
pub fn is_clone(command: String) -> Bool {
  string.contains(command, "git clone ")
  || string.contains(command, "gh repo clone ")
}
