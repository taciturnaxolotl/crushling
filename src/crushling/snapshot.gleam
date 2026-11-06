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
