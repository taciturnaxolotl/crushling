//// GitHub through the bridge, so a sandbox never holds a token.
////
//// The sandbox's git sends every `https://github.com/` URL here, as
//// `/git/<owner>/<repo>/...` (see `env`), and its `gh` talks to
//// `api.github.com` here over a unix socket the image forwards to the
//// bridge. Both carry the thread's `bound` token, which names the thread.
////
//// This module is HTTP policy only: what may go through, checked before
//// anyone's token is looked up. Whose token a request goes with is the
//// workspace's broker's call (`github/broker`).
////
//// - git: fetches and clones (`git-upload-pack`), and pushes
////   (`git-receive-pack`) that only touch `crushling/…` branches; LFS is
////   refused.
//// - the API: GET and HEAD, and GraphQL queries; any other method, and any
////   GraphQL mutation or subscription, is refused.
////
//// Responses stream back through `relay`. A git error is answered in
//// words git shows the agent, so it can say what to do.

import crushling/github/broker.{
  type Access, type Credential, type Need, type Purpose, Anonymous, AsApp,
  AsPerson, Connect, Install, OpenPr, Push, Read, Unavailable,
}
import crushling/github/repo.{type Repo}
import crushling/relay
import crushling/sandbox_http
import crushling/sys
import crushling/token
import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mist

pub type Setup {
  Setup(
    /// The instance secret thread tokens are derived from.
    secret: String,
    /// What thread `key` can get from its workspace's broker.
    access: fn(String) -> Result(Access, String),
    /// Where git and the API go: github.com and api.github.com, or fakes.
    web: relay.Upstream,
    api: relay.Upstream,
    /// How sandboxes reach the bridge, for redirects.
    bridge_url: String,
    /// How long a request waits for someone to connect or install.
    wait_ms: Int,
    /// The epoch of thread `key`'s running sandbox, when known: then only
    /// a token minted for it (`env_at`) gets through. None takes any.
    epoch: fn(String) -> Option(Int),
  )
}

/// How long a read waits for someone to connect or install: a little under
/// the fifteen minutes GitHub's device code lasts.
pub const default_wait_ms = 600_000

pub fn github() -> relay.Upstream {
  relay.Upstream("github.com", 443, True)
}

pub fn github_api() -> relay.Upstream {
  relay.Upstream("api.github.com", 443, True)
}

/// What a thread's sandbox needs: git sends GitHub URLs, https and ssh, to
/// the bridge with the thread's token, and gh (through the image's wrapper)
/// uses the token as its own.
///
/// The git settings go in `GIT_CONFIG_PARAMETERS`, the variable `git -c`
/// uses, not `GIT_CONFIG_COUNT`/`KEY_n`: crush's shell sets those for its
/// own gpg wrapper and would replace ours, sending git straight to GitHub.
pub fn env(bridge_url: String, secret: String, key: String) -> List(String) {
  env_with(bridge_url, token.bound(secret, token.GitHub, key))
}

/// `env` for the sandbox started at `epoch`: its token stops working once
/// `Setup.epoch` says a newer sandbox runs.
pub fn env_at(
  bridge_url: String,
  secret: String,
  key: String,
  epoch: Int,
) -> List(String) {
  env_with(bridge_url, token.bound_at(secret, token.GitHub, key, epoch))
}

fn env_with(bridge_url: String, bound: String) -> List(String) {
  let base = git_base(bridge_url)
  let config = [
    #("url." <> base <> ".insteadOf", "https://github.com/"),
    #("url." <> base <> ".insteadOf", "git@github.com:"),
    #("url." <> base <> ".insteadOf", "ssh://git@github.com/"),
    #("http." <> base <> ".extraHeader", "Authorization: Bearer " <> bound),
  ]
  [
    "GH_TOKEN=" <> bound,
    "GIT_CONFIG_PARAMETERS="
      <> list.map(config, fn(pair) { quote(pair.0) <> "=" <> quote(pair.1) })
    |> string.join(" "),
  ]
}

/// Quoted the way git reads `GIT_CONFIG_PARAMETERS`: in single quotes, a
/// quote inside as `'\''`.
fn quote(text: String) -> String {
  "'" <> string.replace(text, "'", "'\\''") <> "'"
}

fn git_base(bridge_url: String) -> String {
  case string.ends_with(bridge_url, "/") {
    True -> bridge_url <> "git/"
    False -> bridge_url <> "/git/"
  }
}

/// What the agent is told about GitHub, with its Slack tools.
pub const instructions =
  "GitHub: `git` and `gh` work as usual. crushling sends them to GitHub as the person whose message you're working on, with their access and no more; the sandbox holds no token, so never log in, set a token, or ask anyone to enter a GitHub code: that would go around the person's own connection. Reads go through: clone, fetch, `gh pr view`/`diff`/`checks`, `gh issue view`, `gh api` GETs and GraphQL queries. You may push, but only to branches named `crushling/<what>`, like `git push origin HEAD:crushling/fix-flaky-test`; force-pushing such a branch is fine, deleting one or pushing anywhere else is refused. To open a pull request, push the branch, then call the `propose_pr` tool: it posts a card and a person opens the PR from it, as themselves. `gh pr create`, commenting and other writes through `gh` are refused. If a read needs them to connect GitHub, or to add crushling's GitHub App to an account, crushling asks them in the thread and the command waits until they do (it may move to the background; wait for it). If a read is still refused, the error says why."

/// The route for `/git/...` and for requests to `api.github.com`.
pub fn route(setup: Setup) -> sandbox_http.Route {
  fn(req: Request(mist.Connection)) {
    case request.path_segments(req), host(req) {
      ["git", ..rest], _ ->
        Some(authorized(setup, req, fn(key) { git(setup, req, rest, key) }))
      _, "api.github.com" ->
        Some(authorized(setup, req, fn(key) { api(setup, req, key) }))
      _, _ -> None
    }
  }
}

fn host(req: Request(mist.Connection)) -> String {
  let host = request.get_header(req, "host") |> result.unwrap(req.host)
  case string.split_once(host, ":") {
    Ok(#(name, _)) -> string.lowercase(name)
    Error(Nil) -> string.lowercase(host)
  }
}

/// Find the thread from its token. Whose GitHub it uses is only looked up
/// once the request has passed the route's own checks.
fn authorized(
  setup: Setup,
  req: Request(mist.Connection),
  next: fn(String) -> Response(mist.ResponseData),
) -> Response(mist.ResponseData) {
  let presented = case request.get_header(req, "authorization") {
    Ok("Bearer " <> bound) | Ok("token " <> bound) -> bound
    Ok("Basic " <> basic) ->
      // git, when it was given the token as a password.
      bit_array.base64_decode(basic)
      |> result.try(bit_array.to_string)
      |> result.try(string.split_once(_, ":"))
      |> result.map(fn(pair) { pair.1 })
      |> result.unwrap("")
    _ -> ""
  }
  let current = fn(key, minted) {
    case setup.epoch(key), minted {
      None, _ -> True
      Some(epoch), Some(minted) -> epoch == minted
      Some(_), None -> False
    }
  }
  case token.opened_at(setup.secret, token.GitHub, presented) {
    Ok(#(key, minted)) ->
      case current(key, minted) {
        True -> next(key)
        False -> plain(401, "crushling: that token is from an earlier sandbox")
      }
    Error(Nil) -> plain(401, "crushling: not a thread's GitHub token")
  }
}

/// What thread `key` can get, or a 503 when its workspace can't say.
fn with_access(
  setup: Setup,
  key: String,
  next: fn(Access) -> Response(mist.ResponseData),
) -> Response(mist.ResponseData) {
  case setup.access(key) {
    Ok(access) -> next(access)
    Error(reason) -> unavailable(key, reason)
  }
}

fn unavailable(key: String, reason: String) -> Response(mist.ResponseData) {
  sys.warn("crushling: GitHub for " <> key <> ": " <> reason)
  plain(503, "crushling: couldn't get a GitHub token; try again")
}

// git ----------------------------------------------------------------------

/// Packs are big, and negotiation for a big repo can be too.
const max_git_body = 64_000_000

/// Packs pushed can be large; a pack past this goes in pieces.
const max_push_body = 256_000_000

const git_headers = [
  "accept", "accept-encoding", "content-type", "content-encoding",
  "git-protocol", "user-agent",
]

/// What a git request is: its repo's path parts, what it's for, and whether
/// its body is a push to check.
type GitRequest {
  GitRequest(owner: String, name: String, purpose: Purpose, pushing: Bool)
}

fn git(
  setup: Setup,
  req: Request(mist.Connection),
  rest: List(String),
  key: String,
) -> Response(mist.ResponseData) {
  let service = case req.query {
    Some("service=" <> service) -> service
    _ -> ""
  }
  let wanted = case rest, req.method, service {
    [owner, name, "info", "refs"], http.Get, "git-upload-pack"
    | [owner, name, "git-upload-pack"], http.Post, _
    -> Ok(GitRequest(owner, name, Read, False))
    [owner, name, "info", "refs"], http.Get, "git-receive-pack" ->
      Ok(GitRequest(owner, name, Push, False))
    [owner, name, "git-receive-pack"], http.Post, _ ->
      Ok(GitRequest(owner, name, Push, True))
    _, _, _ -> Error(Nil)
  }
  case wanted {
    Error(Nil) ->
      plain(
        404,
        "crushling: only cloning, fetching and pushing go through to GitHub (no LFS)",
      )
    Ok(GitRequest(owner:, name:, purpose:, pushing:)) ->
      case repo.parse_path(owner, name) {
        Error(Nil) -> plain(404, "crushling: that isn't a GitHub repository")
        Ok(target) -> {
          let max = case pushing {
            True -> max_push_body
            False -> max_git_body
          }
          use body <- read(req, max)
          // The fence comes before anyone's token is looked up.
          case pushing, pushable(option.unwrap(body, <<>>)) {
            True, Error(why) -> plain(403, "crushling: " <> why)
            _, _ -> {
              use access <- with_access(setup, key)
              forward_git(setup, req, key, access, target, body, purpose)
            }
          }
        }
      }
  }
}

pub const branch_prefix = "refs/heads/crushling/"

/// Whether a push only updates `crushling/…` branches: its commands, the
/// pkt-lines before the first flush, each `<old> <new> <ref>`.
@internal
pub fn pushable(body: BitArray) -> Result(Nil, String) {
  use commands <- result.try(
    commands(body, [])
    |> result.replace_error("couldn't read the push"),
  )
  let refused =
    list.filter_map(commands, fn(command) {
      case string.split(command, " ") {
        [_, new, ref] ->
          case string.starts_with(ref, branch_prefix), zero(new) {
            _, True -> Ok(ref <> " (deleting a branch)")
            True, False if ref != branch_prefix -> Error(Nil)
            _, _ -> Ok(ref)
          }
        _ -> Ok(command)
      }
    })
  case commands, refused {
    [], _ -> Error("couldn't read the push")
    _, [] -> Ok(Nil)
    _, refused ->
      Error(
        "agents may only push to branches named crushling/…, and not delete them; refused: "
        <> string.join(refused, ", ")
        <> ". Push to a branch like crushling/fix-the-thing instead, e.g. `git push origin HEAD:crushling/fix-the-thing`.",
      )
  }
}

fn zero(oid: String) -> Bool {
  oid != "" && string.replace(oid, "0", "") == ""
}

/// The commands at the start of a receive-pack request: each pkt-line's
/// text up to its NUL (capabilities) or newline, until a flush. `shallow`
/// lines are skipped; a push certificate isn't understood, so it's refused.
fn commands(body: BitArray, found: List(String)) -> Result(List(String), Nil) {
  case body {
    <<"0000":utf8, _:bits>> -> Ok(list.reverse(found))
    <<length:bytes-size(4), rest:bits>> -> {
      use length <- result.try(
        bit_array.to_string(length) |> result.try(int.base_parse(_, 16)),
      )
      let size = length - 4
      case size > 0, rest {
        True, <<line:bytes-size(size), rest:bits>> -> {
          use line <- result.try(bit_array.to_string(line))
          let line = case string.split_once(line, "\u{0}") {
            Ok(#(command, _)) -> command
            Error(Nil) -> line
          }
          let line = string.trim_end(line)
          case line {
            "shallow " <> _ -> commands(rest, found)
            "push-cert" <> _ -> Error(Nil)
            line -> commands(rest, [line, ..found])
          }
        }
        _, _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

/// Send a git request on with the credential the broker gives for it.
fn forward_git(
  setup: Setup,
  req: Request(mist.Connection),
  key: String,
  access: Access,
  target: Repo,
  body: Option(BitArray),
  purpose: Purpose,
) -> Response(mist.ResponseData) {
  let path =
    string.drop_start(req.path, string.length("/git"))
    <> option.map(req.query, fn(q) { "?" <> q }) |> option.unwrap("")
  let method = http.method_to_string(req.method)
  let answer = fn(text) { plain(403, "crushling: " <> text) }
  use credential, deny <- reading(
    setup,
    key,
    access,
    Some(target),
    purpose,
    answer,
  )
  let auth = case secret_of(credential) {
    Some(token) -> [
      #(
        "authorization",
        "Basic "
          <> bit_array.base64_encode(
          bit_array.from_string("x-access-token:" <> token),
          True,
        ),
      ),
    ]
    None -> []
  }
  let headers = list.append(auth, kept(req.headers, git_headers))
  let hooks =
    hooks(key, fn(status, headers) {
      case status {
        _ if status >= 300 && status < 400 ->
          Ok(list.map(headers, redirect(setup, _)))
        // Not taken over by `deny`: GitHub's own answer stands.
        401 | 403 | 404 -> Ok(headers)
        _ if status >= 400 ->
          Error(plain(
            502,
            "crushling: GitHub answered "
              <> int.to_string(status)
              <> " for "
              <> repo.full(target),
          ))
        _ -> Ok(headers)
      }
    })
  attempt(setup.web, req, method, path, headers, body, hooks, deny)
}

fn secret_of(credential: Credential) -> Option(String) {
  case credential {
    AsPerson(token:, ..) | AsApp(token:) -> Some(token)
    Anonymous -> None
  }
}

/// A redirect to elsewhere on GitHub (a renamed repo) stays on the bridge.
fn redirect(setup: Setup, header: #(String, String)) -> #(String, String) {
  case header {
    #("location", "https://github.com/" <> rest) -> #(
      "location",
      git_base(setup.bridge_url) <> rest,
    )
    other -> other
  }
}

/// What the agent is told when a request is refused for good: for want of
/// `need`, or with None, because the person's own access falls short.
@internal
pub fn refusal(
  purpose: Purpose,
  need: Option(Need),
  on: Option(Repo),
) -> String {
  let what = case on {
    Some(target) -> repo.full(target)
    None -> "That"
  }
  case purpose, need {
    Push, None | OpenPr, None ->
      "the GitHub account of the person you're working for can't push to "
      <> what
      <> ". They may not have write access to it."
    Push, Some(Connect(_)) | OpenPr, Some(Connect(_)) ->
      "pushing to "
      <> what
      <> " needs the GitHub account of the person you're working for, and they haven't connected it. crushling asked them in this thread and waited, but they didn't connect in time. Tell them; it works once they connect."
    Read, Some(Connect(_)) ->
      what
      <> " isn't public, and the person you're working for hasn't connected their GitHub account. crushling asked them in this thread and waited, but they didn't connect in time. Tell them what you were trying to read; it works once they connect."
    _, Some(Install(target)) -> {
      let owner = repo.owner(target)
      "crushling's GitHub App isn't installed on "
      <> owner
      <> ", so "
      <> what
      <> " can't be read, even as the person you're working for. crushling asked them in this thread to add it and waited; if they don't own "
      <> owner
      <> ", one of its owners has to approve it. Tell them; it works once it's installed."
    }
    _, Some(Unavailable(_)) ->
      "couldn't get a GitHub token for " <> what <> "; try again."
    Read, None ->
      what
      <> " can't be read with the GitHub account of the person you're working for: it may not exist, or they don't have access to it."
  }
}

// The API ------------------------------------------------------------------

const max_graphql_body = 1_000_000

/// Request headers not passed on: the bridge sets the token, and gun the
/// host and length.
const api_dropped = [
  "authorization", "host", "cookie", "content-length", "proxy-authorization",
]

fn api(
  setup: Setup,
  req: Request(mist.Connection),
  key: String,
) -> Response(mist.ResponseData) {
  let segments = request.path_segments(req)
  let lowered = string.lowercase(req.path)
  // The raw path: path_segments has already resolved any dot steps.
  let odd =
    list.any(string.split(req.path, "/"), fn(part) {
      part == "." || part == ".."
    })
    || string.contains(lowered, "%2f")
    || string.contains(lowered, "%2e")
  let target = case segments {
    ["repos", owner, name, ..] ->
      repo.from_api_segments(owner, name) |> result.map(Some)
    _ -> Ok(None)
  }
  case odd, target {
    True, _ -> api_error(400, "crushling won't send that path to GitHub")
    _, Error(Nil) -> api_error(404, "That isn't a GitHub repository")
    False, Ok(target) ->
      case req.method, req.path {
        http.Get, _ | http.Head, _ -> {
          use access <- with_access(setup, key)
          api_forward(setup, req, key, access, target, None)
        }
        http.Post, "/graphql" ->
          case relay.read_body(req, max_graphql_body, 60_000) {
            Error(_) -> api_error(400, "crushling couldn't read the query")
            Ok(body) ->
              case only_reads(body) {
                True -> {
                  use access <- with_access(setup, key)
                  api_forward(setup, req, key, access, target, Some(body))
                }
                False -> read_only()
              }
          }
        _, _ -> read_only()
      }
  }
}

fn read_only() -> Response(mist.ResponseData) {
  api_error(
    403,
    "crushling only lets reads through to GitHub for now: GETs and GraphQL queries",
  )
}

fn api_forward(
  setup: Setup,
  req: Request(mist.Connection),
  key: String,
  access: Access,
  target: Option(Repo),
  body: Option(BitArray),
) -> Response(mist.ResponseData) {
  let path =
    req.path <> option.map(req.query, fn(q) { "?" <> q }) |> option.unwrap("")
  let answer = fn(text) { api_error(404, text) }
  let method = http.method_to_string(req.method)
  use credential, deny <- reading(setup, key, access, target, Read, answer)
  let auth = case secret_of(credential) {
    Some(token) -> [#("authorization", "Bearer " <> token)]
    None -> []
  }
  let headers =
    relay.end_to_end(req.headers, api_dropped)
    |> list.append(auth, _)
  let hooks = hooks(key, fn(_, headers) { Ok(headers) })
  attempt(setup.api, req, method, path, headers, body, hooks, deny)
}

/// Make the request with the broker's credential. If GitHub refuses for
/// want of something someone can give (a connection, the app on the repo's
/// account), ask them in the thread and wait, then make it again: the
/// agent's command takes longer rather than failing and having to be run
/// again. `send` makes the request, turning GitHub's answer down with
/// `deny` when it is such a refusal.
fn reading(
  setup: Setup,
  key: String,
  access: Access,
  target: Option(Repo),
  purpose: Purpose,
  answer: fn(String) -> Response(mist.ResponseData),
  send: fn(Credential, fn(Int) -> Option(Need)) -> relay.Attempt(Need),
) -> Response(mist.ResponseData) {
  let refuse = fn(need) { answer(refusal(purpose, need, target)) }
  // Each need is asked for once; met and refused again, the person's own
  // access is what falls short.
  let wait_for = fn(need, asked, again) {
    case list.contains(asked, need) {
      True -> refuse(None)
      False -> {
        access.ask(need)
        case access.await(need, setup.wait_ms) {
          True -> again([need, ..asked])
          False -> refuse(Some(need))
        }
      }
    }
  }
  resolve(key, access, target, purpose, wait_for, send, [])
}

fn resolve(
  key: String,
  access: Access,
  target: Option(Repo),
  purpose: Purpose,
  wait_for: fn(Need, List(Need), fn(List(Need)) -> Response(mist.ResponseData)) ->
    Response(mist.ResponseData),
  send: fn(Credential, fn(Int) -> Option(Need)) -> relay.Attempt(Need),
  asked: List(Need),
) -> Response(mist.ResponseData) {
  let again = resolve(key, access, target, purpose, wait_for, send, _)
  case access.credential(target, purpose) {
    Error(Unavailable(reason)) -> unavailable(key, reason)
    Error(need) -> wait_for(need, asked, again)
    Ok(credential) -> {
      let deny = fn(status) {
        case status {
          401 | 403 | 404 -> access.refused(credential, target)
          _ -> None
        }
      }
      case send(credential, deny) {
        relay.Answered(resp) -> resp
        relay.UpstreamRefused(why: need, ..) -> wait_for(need, asked, again)
      }
    }
  }
}

/// Whether a GraphQL request only reads: no `mutation` or `subscription`
/// anywhere outside strings and comments. GitHub's schema has no field by
/// either name, so the only cost of so blunt a check is refusing an alias
/// called that.
@internal
pub fn only_reads(body: BitArray) -> Bool {
  let query = {
    use text <- result.try(bit_array.to_string(body))
    json.parse(text, decode.at(["query"], decode.string))
    |> result.replace_error(Nil)
  }
  case query {
    Error(Nil) -> False
    Ok(query) ->
      words(string.to_graphemes(query), [])
      |> list.all(fn(word) { word != "mutation" && word != "subscription" })
  }
}

/// The names in a GraphQL document, skipping strings and comments.
fn words(chars: List(String), found: List(String)) -> List(String) {
  case chars {
    [] -> found
    ["#", ..rest] -> words(skip_line(rest), found)
    ["\"", "\"", "\"", ..rest] -> words(skip_block(rest), found)
    ["\"", ..rest] -> words(skip_string(rest), found)
    [c, ..rest] ->
      case is_name(c) {
        True -> name(rest, c, found)
        False -> words(rest, found)
      }
  }
}

fn name(
  chars: List(String),
  word: String,
  found: List(String),
) -> List(String) {
  case chars {
    [c, ..rest] ->
      case is_name(c) {
        True -> name(rest, word <> c, found)
        False -> words(chars, [word, ..found])
      }
    [] -> [word, ..found]
  }
}

fn is_name(c: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_",
    c,
  )
}

fn skip_line(chars: List(String)) -> List(String) {
  case chars {
    [] -> []
    ["\n", ..rest] | ["\r", ..rest] -> rest
    [_, ..rest] -> skip_line(rest)
  }
}

fn skip_string(chars: List(String)) -> List(String) {
  case chars {
    [] -> []
    ["\\", _, ..rest] -> skip_string(rest)
    ["\"", ..rest] -> rest
    [_, ..rest] -> skip_string(rest)
  }
}

fn skip_block(chars: List(String)) -> List(String) {
  case chars {
    [] -> []
    ["\\", "\"", "\"", "\"", ..rest] -> skip_block(rest)
    ["\"", "\"", "\"", ..rest] -> rest
    [_, ..rest] -> skip_block(rest)
  }
}

fn api_error(status: Int, message: String) -> Response(mist.ResponseData) {
  sandbox_http.reply(
    status,
    json.to_string(json.object([#("message", json.string(message))])),
  )
  |> response.set_header("content-type", "application/json; charset=utf-8")
}

// Both ---------------------------------------------------------------------

/// The request body, when there is one, read before anything is sent so
/// a request can be sent again.
fn read(
  req: Request(mist.Connection),
  max: Int,
  next: fn(Option(BitArray)) -> Response(mist.ResponseData),
) -> Response(mist.ResponseData) {
  case req.method {
    http.Get | http.Head -> next(None)
    _ ->
      case relay.read_body(req, max, 60_000) {
        Ok(body) -> next(Some(body))
        Error(_) ->
          plain(400, "crushling: couldn't read the request") |> relay.closing
      }
  }
}

fn attempt(
  upstream: relay.Upstream,
  req: Request(mist.Connection),
  method: String,
  path: String,
  headers: List(#(String, String)),
  body: Option(BitArray),
  hooks: relay.Hooks(Nil),
  deny: fn(Int) -> Option(Need),
) -> relay.Attempt(Need) {
  case
    relay.start(upstream, relay.Outgoing(method, path, headers), req, hooks)
  {
    Ok(relay) ->
      relay.attempt(relay, req, option.unwrap(body, <<>>), hooks, deny)
    Error(Nil) -> relay.Answered(hooks.failed(502))
  }
}

fn hooks(
  key: String,
  head: fn(Int, List(#(String, String))) ->
    Result(List(#(String, String)), Response(mist.ResponseData)),
) -> relay.Hooks(Nil) {
  relay.Hooks(
    check: fn() { Ok(Nil) },
    scan: fn(_) { Nil },
    feed: fn(_, _) { Nil },
    finish: fn(_) { Nil },
    head:,
    failed: fn(status) {
      plain(status, "crushling: couldn't reach GitHub") |> relay.closing
    },
    log: fn(what) { sys.warn("crushling: GitHub for " <> key <> ": " <> what) },
  )
}

/// Only the request headers named in `names`.
fn kept(
  headers: List(#(String, String)),
  names: List(String),
) -> List(#(String, String)) {
  list.filter(headers, fn(header) {
    list.contains(names, string.lowercase(header.0))
  })
}

fn plain(status: Int, text: String) -> Response(mist.ResponseData) {
  sandbox_http.reply(status, text <> "\n")
  |> response.set_header("content-type", "text/plain; charset=utf-8")
}
