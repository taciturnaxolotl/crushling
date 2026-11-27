//// A GitHub repository, checked once where it comes in (a git path, a
//// remote URL, an API path) so everything after can trust its parts.

import gleam/list
import gleam/result
import gleam/string

pub opaque type Repo {
  Repo(owner: String, name: String)
}

pub fn owner(repo: Repo) -> String {
  repo.owner
}

pub fn name(repo: Repo) -> String {
  repo.name
}

/// `owner/name`, as GitHub shows it.
pub fn full(repo: Repo) -> String {
  repo.owner <> "/" <> repo.name
}

/// The same for every spelling of one repo: GitHub ignores case in names.
pub fn key(repo: Repo) -> String {
  string.lowercase(full(repo))
}

/// From a git path's `/<owner>/<name>`, where git may add `.git`.
pub fn parse_path(owner: String, name: String) -> Result(Repo, Nil) {
  new(owner, strip_git(name))
}

/// From the `repos/<owner>/<name>` of an API path, taken as it is.
pub fn from_api_segments(owner: String, name: String) -> Result(Repo, Nil) {
  new(owner, name)
}

/// From a GitHub remote URL, https or ssh.
pub fn parse_remote(url: String) -> Result(Repo, Nil) {
  let path = case string.trim(url) {
    "https://github.com/" <> path | "http://github.com/" <> path -> Ok(path)
    "git@github.com:" <> path | "ssh://git@github.com/" <> path -> Ok(path)
    _ -> Error(Nil)
  }
  use path <- result.try(path)
  case string.split(path, "/") {
    [owner, name] -> parse_path(owner, name)
    _ -> Error(Nil)
  }
}

fn new(owner: String, name: String) -> Result(Repo, Nil) {
  case valid(owner) && valid(name) {
    True -> Ok(Repo(owner:, name:))
    False -> Error(Nil)
  }
}

fn strip_git(name: String) -> String {
  case string.ends_with(name, ".git") {
    True -> string.drop_end(name, 4)
    False -> name
  }
}

/// GitHub's characters for owners and names, and never a path step.
fn valid(part: String) -> Bool {
  part != ""
  && part != "."
  && part != ".."
  && string.to_graphemes(part)
  |> list.all(fn(c) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.",
      c,
    )
  })
}
