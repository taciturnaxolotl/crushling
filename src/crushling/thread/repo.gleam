//// A code channel's view of the repositories the agent works on: its
//// context bar and Code tab, and `!info`'s answer. Each command runs in the
//// workspace through `shell`.

import crushling/git.{type RepoInfo, type Shell}
import crushling/repo_url
import crushling/sink.{type CodeView, ContextItem}
import crushling/thread/say
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// Where the work in `dir` stands, in a few lines of Slack markdown.
pub fn status(shell: Shell, dir: String) -> String {
  say.status(
    git.info(shell, dir),
    git.changes(shell, dir),
    git.push_state(shell, dir),
  )
}

/// Update the code channel's context bar and Code tab.
pub fn show(shell: Shell, view: CodeView, dir: String, info: RepoInfo) -> Nil {
  // Every repository in the workspace with changes, the channel's own
  // first: an agent often works across several (a review that clones a
  // few). With more than one, each path says which.
  let others = git.repos(shell) |> list.filter(fn(other) { other != dir })
  let changed =
    [dir, ..others]
    |> list.map(fn(repo) { #(repo, git.changes(shell, repo)) })
    |> list.filter(fn(pair) { pair.1 != [] })
  let changes = list.flat_map(changed, fn(pair) { pair.1 })
  let web = repo_url.web(info.url)
  let link = fn(path) {
    case web {
      "" -> ""
      web -> web <> path
    }
  }
  [
    case repo_url.name(info.url) {
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
  |> view.context
  let diff = case changed {
    [] -> Ok("")
    [#(only, _)] if only == dir -> shell(git.repo_diff(dir))
    changed ->
      list.try_map(changed, fn(pair) { shell(git.repo_diff_prefixed(pair.0)) })
      |> result.map(string.join(_, ""))
  }
  case diff, changed {
    Error(Nil), _ -> Nil
    // Nothing changed (any more): an empty Code tab, not the last diff.
    Ok(diff), [#(only, _)] if only == dir ->
      view.code(diff, info.base, info.branch)
    Ok(diff), _ -> view.code(diff, "", "")
  }
}
