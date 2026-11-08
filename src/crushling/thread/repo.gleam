//// A git repository in a thread's workspace. This module finds it, lists its
//// changes, and keeps its code channel's context bar and Code tab up to date.
//// Each command runs in the workspace through `shell`.

import crushling/sink.{type Sink, ContextItem}
import crushling/snapshot.{type RepoInfo, RepoInfo}
import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub type Shell =
  fn(String) -> Result(String, Nil)

/// A repository that a code channel can show. The channel is called `name`
/// unless the agent picks another name.
pub type Found {
  Found(dir: String, info: RepoInfo, name: String)
}

/// Find the repository in workspace directory `dir`. With no `dir`, use the
/// first repository in the workspace.
pub fn find(shell: Shell, dir: String) -> Result(Found, String) {
  let dir = case dir {
    "" ->
      shell(snapshot.list_repos())
      |> result.unwrap("")
      |> string.split("\n")
      |> list.map(string.trim)
      |> list.find(fn(line) { line != "" })
      |> result.unwrap("")
    dir -> dir
  }
  let is_repo =
    dir != ""
    && shell(snapshot.is_repo(dir)) |> result.map(string.trim) == Ok("yes")
  case dir, is_repo {
    "", _ ->
      Error("there is no git repository in the workspace; clone one first")
    dir, False -> Error(dir <> " is not a git repository")
    dir, True -> {
      let info = info(shell, dir)
      let name = case snapshot.repo_name(info.url) {
        "" -> string.replace(dir, "./", "")
        name -> name
      }
      Ok(Found(dir:, info:, name:))
    }
  }
}

pub fn info(shell: Shell, dir: String) -> RepoInfo {
  shell(snapshot.repo_info(dir))
  |> result.map(snapshot.parse_repo_info)
  |> result.unwrap(RepoInfo("", "", ""))
}

/// The files that changed in the repository, compared with its base.
pub fn changes(shell: Shell, dir: String) -> List(snapshot.Change) {
  shell(snapshot.repo_numstat(dir))
  |> result.map(snapshot.parse_numstat)
  |> result.unwrap([])
}

/// Update the code channel's context bar and Code tab.
pub fn show(shell: Shell, sink: Sink, dir: String, info: RepoInfo) -> Nil {
  let changes = changes(shell, dir)
  let web = snapshot.web_url(info.url)
  let link = fn(path) {
    case web {
      "" -> ""
      web -> web <> path
    }
  }
  [
    case snapshot.repo_name(info.url) {
      "" -> Error(Nil)
      name -> Ok(ContextItem("repo", name, "folder", link("")))
    },
    case info.branch {
      "" | "HEAD" -> Error(Nil)
      branch ->
        Ok(ContextItem("branch", branch, "branch", link("/tree/" <> branch)))
    },
    case list.length(changes) {
      0 -> Error(Nil)
      1 -> Ok(ContextItem("changes", "1 file changed", "code", ""))
      many ->
        Ok(ContextItem(
          "changes",
          int.to_string(many) <> " files changed",
          "code",
          "",
        ))
    },
  ]
  |> result.values
  |> sink.context
  case shell(snapshot.repo_diff(dir)) {
    Ok("") | Error(Nil) -> Nil
    Ok(diff) -> sink.code(diff, info.base, info.branch)
  }
}
