//// What the thread does in its workspace through the server's shell:
//// snapshots and patches, a code channel's view, `!info`, proposals, and
//// finding the repository the agent changed. The slow parts run in a
//// process of their own (`conn.apart`) and answer through a callback.

import crushling/crush/event
import crushling/git.{type RepoInfo, type Shell}
import crushling/pr
import crushling/run.{type Run}
import crushling/sink.{type CodeView}
import crushling/snapshot
import crushling/sys
import crushling/thread/conn.{type Connection, type Target}
import crushling/thread/repo
import crushling/venue.{type Venue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// A shell on the connection, if there is one; without one every command
/// fails.
pub fn shell(connection: Option(Connection), target: Target) -> Shell {
  fn(command) {
    case connection {
      Some(connection) -> conn.shell(connection, target, command)
      None -> Error(Nil)
    }
  }
}

/// The workspace's snapshot tree as it is now.
pub fn snapshot(shell: Shell) -> Option(String) {
  shell(snapshot.take())
  |> result.try(snapshot.parse_tree)
  |> option.from_result
}

/// The patch for a run outside a code channel. With a repository it comes
/// from the repository's own history; without one, from the snapshot
/// `base` taken before the run, which covers edits made through `bash`.
pub fn patch(
  shell: Shell,
  at: Venue,
  base: Option(String),
  run_id: String,
) -> Option(String) {
  case at {
    venue.ThreadOnly(repo: dir) if dir != "" ->
      shell(git.repo_diff(dir)) |> option.from_result
    _ -> {
      let patch = {
        use base <- result.try(option.to_result(base, Nil))
        use after <- result.try(snapshot(shell) |> option.to_result(Nil))
        shell(snapshot.diff(base, after))
      }
      case patch {
        Ok(patch) -> Some(patch)
        Error(Nil) -> {
          sys.warn(
            "crushling: no workspace snapshot, so no patch for run " <> run_id,
          )
          None
        }
      }
    }
  }
}

/// Update a code channel's context bar and Code tab off the actor: reading
/// every repository's diff can take a while.
pub fn show_code(
  connection: Connection,
  target: Target,
  view: CodeView,
  dir: String,
  info: Option(RepoInfo),
) -> Nil {
  use shell <- conn.apart(connection, target)
  let info = option.lazy_unwrap(info, fn() { git.info(shell, dir) })
  repo.show(shell, view, dir, info)
}

/// `!info`'s answer for the repository in `dir`, worked out off the actor.
pub fn status(
  connection: Connection,
  target: Target,
  dir: String,
  answer: fn(String) -> Nil,
) -> Nil {
  use shell <- conn.apart(connection, target)
  answer(repo.status(shell, dir))
}

/// Find the first repository with work of the agent's in it, off the actor.
pub fn find_changed(
  connection: Connection,
  target: Target,
  answer: fn(Result(git.Found, Nil)) -> Nil,
) -> Nil {
  use shell <- conn.apart(connection, target)
  git.changed(shell)
  |> result.try(fn(dir) { git.find(shell, dir) |> result.replace_error(Nil) })
  |> answer
}

/// Whether a tool message may have changed files: a successful result of a
/// tool that writes.
pub fn may_change(message: event.Message, run: Run) -> Bool {
  message.role == event.Tool
  && list.any(message.tool_results, fn(result) {
    !result.is_error
    && list.any(run.tools, fn(tool) {
      tool.id == result.tool_call_id
      && list.contains(["bash", "edit", "multiedit", "write"], tool.name)
    })
  })
}

/// A PR proposal for the pushed branch of the venue's repository, else the
/// workspace's first.
pub fn proposal(
  shell: Shell,
  at: Venue,
  title: String,
  body: String,
) -> Result(pr.Proposal, String) {
  use dir <- result.try(case venue.repo(at) {
    Some(dir) -> Ok(dir)
    None -> git.find(shell, "") |> result.map(fn(found) { found.dir })
  })
  use facts <- result.try(
    shell(pr.facts(dir))
    |> result.replace_error(
      "failed to read the repository (the agent may be asleep)",
    ),
  )
  pr.from_facts(facts, title, body)
}
