//// GitHub reads through the bridge, so a sandbox never holds a token.
////
//// The sandbox's git sends every `https://github.com/` URL here, as
//// `/git/<owner>/<repo>/...` (see `env`), and its `gh` talks to
//// `api.github.com` here over a unix socket the image forwards to the
//// bridge. Both carry the thread's `bound` token, which names the thread.
//// The bridge looks up whose GitHub the thread's agent works with (the
//// person whose prompt it's on) and sends the request on with their token,
//// or with none when they haven't connected, which still reads public
//// repos.
////
//// Only reads go through:
////
//// - git: fetches and clones (`git-upload-pack`); pushes and LFS are
////   refused.
//// - the API: GET and HEAD, and GraphQL queries; any other method, and any
////   GraphQL mutation or subscription, is refused.
////
//// Responses stream back through `relay`. A git error is answered in
//// words git shows the agent, so it can say what to do.

import crushling/relay
import crushling/sandbox_http
import crushling/sys
import crushling/token
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
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
    /// The GitHub token thread `key`'s agent reads with: None when whoever
    /// it works for hasn't connected.
    access: fn(String) -> Result(Option(String), String),
    /// Where git and the API go: github.com and api.github.com, or fakes.
    web: relay.Upstream,
    api: relay.Upstream,
    /// How sandboxes reach the bridge, for redirects.
    bridge_url: String,
    /// The app's own token for reading `owner/repo`, when nobody connected:
    /// only for a public repo (`github/app`). None without the app's key.
    app_token: fn(String, String) -> Option(String),
    /// Whether the GitHub App is installed where `owner/repo` is: None
    /// when unknown (no app key, or GitHub didn't say).
    installed: fn(String, String) -> Option(Bool),
    /// Ask whoever thread `key`'s agent works for, in its thread, for what
    /// a read is missing.
    ask: fn(String, Want) -> Nil,
    /// How long a read waits for them, and how often it looks.
    wait_ms: Int,
    poll_ms: Int,
  )
}

/// What a read is missing.
pub type Want {
  /// The person's GitHub connection, to read `repo` (if known) as them.
  Connection(repo: Option(String))
  /// The GitHub App on `owner`, to read `owner/repo` at all.
  Install(owner: String, repo: String)
}

/// How long a read waits for someone to connect or install: a little under
/// the fifteen minutes GitHub's device code lasts.
pub const default_wait_ms = 600_000

pub const default_poll_ms = 2000

pub fn github() -> relay.Upstream {
  relay.Upstream("github.com", 443, True)
}

pub fn github_api() -> relay.Upstream {
  relay.Upstream("api.github.com", 443, True)
}

/// What a thread's sandbox needs: git sends GitHub URLs, https and ssh, to
/// the bridge with the thread's token, and gh (through the image's wrapper)
/// uses the token as its own.
pub fn env(bridge_url: String, secret: String, key: String) -> List(String) {
  let base = git_base(bridge_url)
  let bound = token.bound(secret, token.GitHub, key)
  let config = [
    #("url." <> base <> ".insteadOf", "https://github.com/"),
    #("url." <> base <> ".insteadOf", "git@github.com:"),
    #("url." <> base <> ".insteadOf", "ssh://git@github.com/"),
    #("http." <> base <> ".extraHeader", "Authorization: Bearer " <> bound),
  ]
  [
    "GH_TOKEN=" <> bound,
    "GIT_CONFIG_COUNT=" <> int.to_string(list.length(config)),
    ..list.index_map(config, fn(pair, i) {
      let n = int.to_string(i)
      [
        "GIT_CONFIG_KEY_" <> n <> "=" <> pair.0,
        "GIT_CONFIG_VALUE_" <> n <> "=" <> pair.1,
      ]
    })
    |> list.flatten
  ]
}

fn git_base(bridge_url: String) -> String {
  case string.ends_with(bridge_url, "/") {
    True -> bridge_url <> "git/"
    False -> bridge_url <> "/git/"
  }
}

/// What the agent is told about GitHub, with its Slack tools.
pub const instructions =
  "GitHub: `git` and `gh` work as usual. crushling sends them to GitHub as the person whose message you're working on, with their access and no more; the sandbox holds no token, so don't log in or set one. Reads go through: clone, fetch, `gh pr view`/`diff`/`checks`, `gh issue view`, `gh api` GETs and GraphQL queries. You may push, but only to branches named `crushling/<what>`, like `git push origin HEAD:crushling/fix-flaky-test`; force-pushing such a branch is fine, deleting one or pushing anywhere else is refused. Opening PRs, commenting and other writes through `gh` are refused for now; push a branch and say so, with what you changed and the branch name. If a read needs them to connect GitHub, or to add crushling's GitHub App to an account, crushling asks them in the thread and the command waits until they do (it may move to the background; wait for it). If a read is still refused, the error says why."

/// The route for `/git/...` and for requests to `api.github.com`.
pub fn route(setup: Setup) -> sandbox_http.Route {
  fn(req: Request(mist.Connection)) {
    case request.path_segments(req), host(req) {
      ["git", ..rest], _ ->
        Some(
          authorized(setup, req, fn(thread) { git(setup, req, rest, thread) }),
        )
      _, "api.github.com" ->
        Some(authorized(setup, req, fn(thread) { api(setup, req, thread) }))
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

/// Find the thread from its token, and whose GitHub it reads with.
fn authorized(
  setup: Setup,
  req: Request(mist.Connection),
  next: fn(Thread) -> Response(mist.ResponseData),
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
  case token.opened(setup.secret, token.GitHub, presented) {
    Error(Nil) -> plain(401, "crushling: not a thread's GitHub token")
    Ok(key) ->
      case setup.access(key) {
        Error(reason) -> {
          sys.warn("crushling: GitHub for " <> key <> ": " <> reason)
          plain(503, "crushling: couldn't get a GitHub token; try again")
        }
        Ok(access) -> next(Thread(key:, access:))
      }
  }
}

type Thread {
  Thread(key: String, access: Option(String))
}

// git ----------------------------------------------------------------------

/// Packs are big, and negotiation for a big repo can be too.
const max_git_body = 64_000_000

const git_headers = [
  "accept", "accept-encoding", "content-type", "content-encoding",
  "git-protocol", "user-agent",
]

fn git(
  setup: Setup,
  req: Request(mist.Connection),
  rest: List(String),
  thread: Thread,
) -> Response(mist.ResponseData) {
  let service = case req.query {
    Some("service=" <> service) -> service
    _ -> ""
  }
  case rest, req.method, service {
    [owner, repo, "info", "refs"], http.Get, "git-upload-pack"
    | [owner, repo, "git-upload-pack"], http.Post, _
    ->
      case valid(owner) && valid(repo) {
        False -> plain(404, "crushling: that isn't a GitHub repository")
        True -> fetch(setup, req, thread, owner, repo)
      }
    [owner, repo, "info", "refs"], http.Get, "git-receive-pack" ->
      case valid(owner) && valid(repo) {
        False -> plain(404, "crushling: that isn't a GitHub repository")
        True -> fetch(setup, req, thread, owner, repo)
      }
    [owner, repo, "git-receive-pack"], http.Post, _ ->
      case valid(owner) && valid(repo) {
        False -> plain(404, "crushling: that isn't a GitHub repository")
        True -> push(setup, req, thread, owner, repo)
      }
    _, _, _ ->
      plain(
        404,
        "crushling: only cloning, fetching and pushing go through to GitHub (no LFS)",
      )
  }
}

fn valid(name: String) -> Bool {
  name != ""
  && name != "."
  && name != ".."
  && string.to_graphemes(name)
  |> list.all(fn(c) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.",
      c,
    )
  })
}

fn fetch(
  setup: Setup,
  req: Request(mist.Connection),
  thread: Thread,
  owner: String,
  repo: String,
) -> Response(mist.ResponseData) {
  use body <- read(req, max_git_body)
  forward_git(setup, req, thread, owner, repo, body, False)
}

/// Pushes as the person, only to `crushling/…` branches, the bridge
/// reading the push's ref updates before any of it reaches GitHub.
/// Overwriting such a branch is fine; deleting one, or touching any other
/// ref, is refused.
fn push(
  setup: Setup,
  req: Request(mist.Connection),
  thread: Thread,
  owner: String,
  repo: String,
) -> Response(mist.ResponseData) {
  use body <- read(req, max_push_body)
  case pushable(option.unwrap(body, <<>>)) {
    Error(why) -> plain(403, "crushling: " <> why)
    Ok(Nil) -> forward_git(setup, req, thread, owner, repo, body, True)
  }
}

/// Packs pushed can be large; a pack past this goes in pieces.
const max_push_body = 256_000_000

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

/// Send a git request on as the person, or, for a read nobody connected
/// for, with the app's token on a public repo or none. `writes` (a push)
/// only ever goes as the person.
fn forward_git(
  setup: Setup,
  req: Request(mist.Connection),
  thread: Thread,
  owner: String,
  repo: String,
  body: Option(BitArray),
  writes: Bool,
) -> Response(mist.ResponseData) {
  let repo = string.replace(repo, ".git", "")
  let name = owner <> "/" <> repo
  let path =
    string.drop_start(req.path, string.length("/git"))
    <> option.map(req.query, fn(q) { "?" <> q }) |> option.unwrap("")
  let method = http.method_to_string(req.method)
  let first = case thread.access, writes {
    Some(access), _ -> Some(access)
    None, True -> None
    None, False -> setup.app_token(owner, repo)
  }
  let say = fn(missing) {
    plain(
      403,
      "crushling: "
        <> case writes, missing {
        True, NoAccess ->
          "the GitHub account of the person you're working for can't push to "
          <> name
          <> ". They may not have write access to it."
        True, NotConnected ->
          "pushing to "
          <> name
          <> " needs the GitHub account of the person you're working for, and they haven't connected it. crushling asked them in this thread and waited, but they didn't connect in time. Tell them; it works once they connect."
        _, missing -> refused(missing, name)
      },
    )
  }
  use token, refuse <- reading(setup, thread, Some(#(owner, repo)), first, say)
  let auth = case token {
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
    hooks(thread, fn(status, headers) {
      case status {
        _ if status >= 300 && status < 400 ->
          Ok(list.map(headers, redirect(setup, _)))
        401 | 403 | 404 -> Error(refuse())
        _ if status >= 400 ->
          Error(plain(
            502,
            "crushling: GitHub answered "
              <> int.to_string(status)
              <> " for "
              <> name,
          ))
        _ -> Ok(headers)
      }
    })
  send(setup.web, req, method, path, headers, body, hooks)
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

/// What the agent is told when a read is refused for good.
fn refused(missing: Missing, what: String) -> String {
  case missing {
    NotConnected ->
      what
      <> " isn't public, and the person you're working for hasn't connected their GitHub account. crushling asked them in this thread and waited, but they didn't connect in time. Tell them what you were trying to read; it works once they connect."
    NotInstalled(owner) ->
      "crushling's GitHub App isn't installed on "
      <> owner
      <> ", so "
      <> what
      <> " can't be read, even as the person you're working for. crushling asked them in this thread to add it and waited; if they don't own "
      <> owner
      <> ", one of its owners has to approve it. Tell them; it works once it's installed."
    NoAccess ->
      what
      <> " can't be read with the GitHub account of the person you're working for: it may not exist, or they don't have access to it."
  }
}

type Missing {
  NotConnected
  NotInstalled(owner: String)
  NoAccess
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
  thread: Thread,
) -> Response(mist.ResponseData) {
  case req.method, req.path {
    http.Get, _ | http.Head, _ -> api_forward(setup, req, thread, None)
    http.Post, "/graphql" ->
      case relay.read_body(req, max_graphql_body, 60_000) {
        Error(_) -> api_error(400, "crushling couldn't read the query")
        Ok(body) ->
          case only_reads(body) {
            True -> api_forward(setup, req, thread, Some(body))
            False -> read_only()
          }
      }
    _, _ -> read_only()
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
  thread: Thread,
  body: Option(BitArray),
) -> Response(mist.ResponseData) {
  let path =
    req.path <> option.map(req.query, fn(q) { "?" <> q }) |> option.unwrap("")
  let #(repo, first) = case request.path_segments(req) {
    ["repos", owner, repo, ..] -> #(
      Some(#(owner, repo)),
      option.lazy_or(thread.access, fn() { setup.app_token(owner, repo) }),
    )
    _ -> #(None, thread.access)
  }
  let what = case repo {
    Some(#(owner, repo)) -> owner <> "/" <> repo
    None -> "That"
  }
  let say = fn(missing) { api_error(404, refused(missing, what)) }
  let method = http.method_to_string(req.method)
  use token, refuse <- reading(setup, thread, repo, first, say)
  let auth = case token {
    Some(token) -> [#("authorization", "Bearer " <> token)]
    None -> []
  }
  let headers =
    relay.end_to_end(req.headers, api_dropped)
    |> list.append(auth, _)
  let hooks =
    hooks(thread, fn(status, headers) {
      case status {
        401 | 403 | 404 -> Error(refuse())
        _ -> Ok(headers)
      }
    })
  send(setup.api, req, method, path, headers, body, hooks)
}

/// Read with `first`. If GitHub refuses for want of the person's
/// connection, or of the app on the repo's account, ask them in the thread
/// and wait, then read again: the agent's command takes longer rather than
/// failing and having to be run again. `attempt` makes the request with a
/// token, calling `refuse` when GitHub said no for want of access.
fn reading(
  setup: Setup,
  thread: Thread,
  repo: Option(#(String, String)),
  first: Option(String),
  say: fn(Missing) -> Response(mist.ResponseData),
  attempt: fn(Option(String), fn() -> Response(mist.ResponseData)) ->
    Response(mist.ResponseData),
) -> Response(mist.ResponseData) {
  // `attempt` calls `refuse` when GitHub said no for want of access; its
  // answer is then replaced by what follows.
  let try = fn(token) {
    let refused = process.new_subject()
    let answer =
      attempt(token, fn() {
        process.send(refused, Nil)
        say(NoAccess)
      })
    case process.receive(refused, 0) {
      Ok(Nil) -> Error(Nil)
      Error(Nil) -> Ok(answer)
    }
  }
  let name = option.map(repo, fn(repo) { repo.0 <> "/" <> repo.1 })
  // As the person; when that's refused where the app isn't installed, ask
  // for it, wait, and try once more.
  let as_them = fn(token) {
    case try(Some(token)), repo {
      Ok(answer), _ -> answer
      Error(Nil), Some(#(owner, name)) ->
        case setup.installed(owner, name) {
          Some(False) -> {
            setup.ask(thread.key, Install(owner, name))
            let installed =
              wait(setup, fn() {
                case setup.installed(owner, name) {
                  Some(True) -> Some(Nil)
                  _ -> None
                }
              })
            case installed {
              Some(Nil) -> try(Some(token)) |> result.unwrap(say(NoAccess))
              None -> say(NotInstalled(owner))
            }
          }
          _ -> say(NoAccess)
        }
      Error(Nil), None -> say(NoAccess)
    }
  }
  case thread.access {
    Some(token) -> as_them(token)
    None ->
      case try(first) {
        Ok(answer) -> answer
        Error(Nil) -> {
          setup.ask(thread.key, Connection(name))
          let token =
            wait(setup, fn() {
              case setup.access(thread.key) {
                Ok(Some(token)) -> Some(token)
                _ -> None
              }
            })
          case token {
            Some(token) -> as_them(token)
            None -> say(NotConnected)
          }
        }
      }
  }
}

/// Look every `poll_ms` until `check` finds something, for `wait_ms`.
fn wait(setup: Setup, check: fn() -> Option(a)) -> Option(a) {
  wait_until(setup, check, sys.monotonic_ms() + setup.wait_ms)
}

fn wait_until(setup: Setup, check: fn() -> Option(a), until: Int) -> Option(a) {
  case sys.monotonic_ms() > until {
    True -> None
    False -> {
      process.sleep(setup.poll_ms)
      case check() {
        Some(found) -> Some(found)
        None -> wait_until(setup, check, until)
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

fn send(
  upstream: relay.Upstream,
  req: Request(mist.Connection),
  method: String,
  path: String,
  headers: List(#(String, String)),
  body: Option(BitArray),
  hooks: relay.Hooks(Nil),
) -> Response(mist.ResponseData) {
  let relay =
    relay.start(upstream, relay.Outgoing(method, path, headers), req, hooks)
  relay.send(relay, req, option.unwrap(body, <<>>), hooks)
}

fn hooks(
  thread: Thread,
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
    log: fn(what) {
      sys.warn("crushling: GitHub for " <> thread.key <> ": " <> what)
    },
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
