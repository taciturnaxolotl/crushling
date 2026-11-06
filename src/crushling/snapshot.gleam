//// Workspace snapshots in a private git repository under `.crush/`, so a
//// run's diff covers every change however it was made, `bash` included,
//// without touching the workspace's own repository. The commands run
//// through the server's shell endpoint, inside the sandbox.

import gleam/list
import gleam/string

const dir = ".crush/crushling-snap"

fn git(args: String) -> String {
  "GIT_DIR=" <> dir <> " GIT_WORK_TREE=. git " <> args
}

/// Prints the tree id of the workspace as it is now.
pub fn take() -> String {
  "[ -d "
  <> dir
  <> " ] || { git init -q --bare "
  <> dir
  <> " && printf '/.crush/\\n/.home/\\n' > "
  <> dir
  <> "/info/exclude; } && "
  <> git("add -A >/dev/null")
  <> " && "
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
  git("diff --no-color --no-ext-diff --binary " <> from <> " " <> to)
}

pub fn changed_files(from: String, to: String) -> String {
  git("diff --name-only " <> from <> " " <> to)
}

pub fn parse_files(output: String) -> List(String) {
  string.split(output, "\n")
  |> list.map(string.trim)
  |> list.filter(fn(line) { line != "" })
}
