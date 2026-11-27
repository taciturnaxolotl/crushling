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

/// Where the work in `dir` stands, in a few lines of Slack markdown: its
/// branch and base, what changed, and whether it's on GitHub.
pub fn status(shell: Shell, dir: String) -> String {
  let info = info(shell, dir)
  let changes = changes(shell, dir)
  let #(added, removed) =
    list.fold(changes, #(0, 0), fn(sum, change) {
      #(
        sum.0 + result.unwrap(change.added, 0),
        sum.1 + result.unwrap(change.removed, 0),
      )
    })
  let count = fn(n, one, many) {
    int.to_string(n)
    <> " "
    <> case n {
      1 -> one
      _ -> many
    }
  }
  let changed = case changes {
    [] -> "nothing yet"
    _ ->
      count(list.length(changes), "file", "files")
      <> ", +"
      <> int.to_string(added)
      <> " −"
      <> int.to_string(removed)
  }
  let lines =
    shell(snapshot.push_state(dir))
    |> result.unwrap("")
    |> string.split("\n")
    |> list.map(string.trim)
  let at = fn(i) { list.drop(lines, i) |> list.first |> result.unwrap("") }
  let uncommitted = int.parse(at(0)) |> result.unwrap(0)
  let github = case at(1), int.parse(at(2)) {
    "", _ -> "not pushed"
    upstream, Ok(0) -> "pushed to `" <> upstream <> "`, up to date"
    upstream, Ok(ahead) ->
      count(ahead, "commit", "commits")
      <> " not pushed yet (`"
      <> upstream
      <> "`)"
    upstream, Error(Nil) -> "tracking `" <> upstream <> "`"
  }
  let github = case uncommitted {
    0 -> github
    n -> github <> "; " <> count(n, "file", "files") <> " not committed"
  }
  let branch = case info.branch, info.base {
    "", _ -> "unknown"
    branch, "" -> "`" <> branch <> "`"
    branch, base -> "`" <> branch <> "` (from `" <> base <> "`)"
  }
  "*Branch* " <> branch <> "\n*Changed* " <> changed <> "\n*GitHub* " <> github
}

/// Update the code channel's context bar and Code tab.
pub fn show(shell: Shell, sink: Sink, dir: String, info: RepoInfo) -> Nil {
  // Every repository in the workspace with changes, the channel's own
  // first: an agent often works across several (a review that clones a
  // few). With more than one, each path says which.
  let others =
    shell(snapshot.list_repos())
    |> result.unwrap("")
    |> string.split("\n")
    |> list.map(string.trim)
    |> list.filter(fn(other) { other != "" && other != dir })
  let changed =
    [dir, ..others]
    |> list.map(fn(repo) { #(repo, changes(shell, repo)) })
    |> list.filter(fn(pair) { pair.1 != [] })
  let changes = list.flat_map(changed, fn(pair) { pair.1 })
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
  let diff = case changed {
    [] -> Ok("")
    [#(only, _)] if only == dir -> shell(snapshot.repo_diff(dir))
    changed ->
      list.try_map(changed, fn(pair) {
        shell(snapshot.repo_diff_prefixed(pair.0))
      })
      |> result.map(string.join(_, ""))
  }
  case diff, changed {
    Error(Nil), _ -> Nil
    // Nothing changed (any more): an empty Code tab, not the last diff.
    Ok(diff), [#(only, _)] if only == dir ->
      sink.code(diff, info.base, info.branch)
    Ok(diff), _ -> sink.code(diff, "", "")
  }
}
