//// Names and links for a repository's clone URL.

import gleam/list
import gleam/string

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
pub fn name(url: String) -> String {
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
pub fn web(url: String) -> String {
  let #(host, path) = host_and_path(url)
  case list.contains(browsable_hosts, host), segments(path) {
    True, [_, _, ..] as parts ->
      "https://" <> host <> "/" <> string.join(parts, "/")
    _, _ -> ""
  }
}
