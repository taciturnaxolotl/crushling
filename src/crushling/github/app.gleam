//// The GitHub App acting as itself, for reads nobody has connected for.
////
//// A thread whose person hasn't connected would otherwise go to GitHub
//// with no token: 60 requests an hour, shared by the whole machine. With
//// the app's private key, those reads use an installation token instead.
//// An installation token can also read the private repos of whoever
//// installed the app, so it is only used on a repo GitHub says is public,
//// asked with that same token and remembered for a while.
////
//// The JWT names the app by its client id, which GitHub accepts as `iss`,
//// so no app id is needed.

import crushling/github
import crushling/sys
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string

pub type Key

@external(erlang, "crushling_ffi", "rsa_key")
fn rsa_key(pem: String) -> Result(Key, Nil)

@external(erlang, "crushling_ffi", "rs256")
fn rs256(data: BitArray, key: Key) -> BitArray

/// The app's private key, from a PEM, or a PEM in base64 (an env file
/// holds one line), or a PEM with its newlines written `\n`.
pub fn parse_key(text: String) -> Result(Key, Nil) {
  let text = string.trim(text)
  let pem = case string.starts_with(text, "-----BEGIN") {
    True -> string.replace(text, "\\n", "\n")
    False ->
      bit_array.base64_decode(text)
      |> result.try(bit_array.to_string)
      |> result.unwrap("")
  }
  rsa_key(pem)
}

/// A JWT for the app, good for nine minutes from `now` (Unix seconds),
/// backdated a minute for clock drift.
pub fn jwt(client_id: String, key: Key, now: Int) -> String {
  let part = fn(object) {
    json.to_string(object)
    |> bit_array.from_string
    |> bit_array.base64_url_encode(False)
  }
  let signed =
    part(
      json.object([#("alg", json.string("RS256")), #("typ", json.string("JWT"))]),
    )
    <> "."
    <> part(
      json.object([
        #("iat", json.int(now - 60)),
        #("exp", json.int(now + 540)),
        #("iss", json.string(client_id)),
      ]),
    )
  signed
  <> "."
  <> bit_array.base64_url_encode(
    rs256(bit_array.from_string(signed), key),
    False,
  )
}

pub type App =
  Subject(Message)

pub opaque type Message {
  Token(owner: String, repo: String, reply: Subject(Option(String)))
  Installed(owner: String, repo: String, reply: Subject(Option(Bool)))
  AccountsOf(reply: Subject(Option(github.Accounts)))
}

type State {
  State(
    config: github.Config,
    key: Key,
    /// An installation token and when it expires (Unix seconds).
    token: Option(#(String, Int)),
    /// After failing to get one, when to try again.
    retry_at: Int,
    /// Whether a repo is public, and until when that's believed.
    public: Dict(String, #(Bool, Int)),
    /// Whether the app is installed where a repo is, and until when.
    installed: Dict(String, #(Bool, Int)),
    /// The app's slug, once known.
    slug: Option(String),
    accounts: Option(#(github.Accounts, Int)),
  )
}

/// How long a repo's visibility is believed: a repo made private stops
/// being read with the app's token within this.
const believed_s = 600

pub fn start(config: github.Config, key: Key) -> Result(App, actor.StartError) {
  actor.new(State(
    config:,
    key:,
    token: None,
    retry_at: 0,
    public: dict.new(),
    installed: dict.new(),
    slug: None,
    accounts: None,
  ))
  |> actor.on_message(fn(state, message) {
    case message {
      Token(owner, repo, reply) -> {
        let #(state, token) = token_for(state, owner, repo)
        process.send(reply, token)
        actor.continue(state)
      }
      Installed(owner, repo, reply) -> {
        let #(state, installed) = installed_for(state, owner, repo)
        process.send(reply, installed)
        actor.continue(state)
      }
      AccountsOf(reply) -> {
        let #(state, accounts) = accounts_for(state)
        process.send(reply, accounts)
        actor.continue(state)
      }
    }
  })
  |> actor.start
  |> result.map(fn(started) { started.data })
}

/// The app's token, if it may be used to read `owner/repo`: the repo is
/// public. None otherwise, or when GitHub can't be asked.
pub fn token(app: App, owner: String, repo: String) -> Option(String) {
  let reply = process.new_subject()
  process.send(app, Token(owner, repo, reply))
  process.receive(reply, 20_000) |> result.unwrap(None)
}

/// Whether the app is installed on the account `owner/repo` belongs to,
/// with that repo selected. None when GitHub can't be asked.
pub fn installed(app: App, owner: String, repo: String) -> Option(Bool) {
  let reply = process.new_subject()
  process.send(app, Installed(owner, repo, reply))
  process.receive(reply, 20_000) |> result.unwrap(None)
}

/// Where the app is installed, and how to install it elsewhere.
pub fn accounts(app: App) -> Option(github.Accounts) {
  let reply = process.new_subject()
  process.send(app, AccountsOf(reply))
  process.receive(reply, 20_000) |> result.unwrap(None)
}

/// Believed this long: an install shows up within `not_installed_s`, which
/// is what someone waiting for one waits on.
const installed_s = 600

const not_installed_s = 15

fn installed_for(
  state: State,
  owner: String,
  repo: String,
) -> #(State, Option(Bool)) {
  let now = now()
  let name = string.lowercase(owner <> "/" <> repo)
  case dict.get(state.installed, name) {
    Ok(#(installed, until)) if until > now -> #(state, Some(installed))
    _ -> {
      let auth = "Bearer " <> jwt(state.config.client_id, state.key, now)
      let path = "/repos/" <> owner <> "/" <> repo <> "/installation"
      // GitHub says 404 both for a repo the app can't see and for one that
      // doesn't exist. Installed on the whole account, it's the latter:
      // nothing to install.
      let installed = case status(state.config, path, auth) {
        Ok(200) -> Some(True)
        Ok(404) ->
          case account_selection(state.config, owner, auth) {
            Ok("all") -> Some(True)
            Ok(_) -> Some(False)
            Error(Nil) -> None
          }
        _ -> None
      }
      case installed {
        Some(True) -> #(
          remember(state, name, True, now + installed_s),
          installed,
        )
        Some(False) -> #(
          remember(state, name, False, now + not_installed_s),
          installed,
        )
        None -> #(state, None)
      }
    }
  }
}

fn remember(state: State, name: String, installed: Bool, until: Int) -> State {
  let now = now()
  let kept = case dict.size(state.installed) > 5000 {
    True -> dict.filter(state.installed, fn(_, entry) { entry.1 > now })
    False -> state.installed
  }
  State(..state, installed: dict.insert(kept, name, #(installed, until)))
}

fn accounts_for(state: State) -> #(State, Option(github.Accounts)) {
  let now = now()
  case state.accounts {
    Some(#(accounts, until)) if until > now -> #(state, Some(accounts))
    _ -> {
      let auth = "Bearer " <> jwt(state.config.client_id, state.key, now)
      let slug = case state.slug {
        Some(slug) -> Ok(slug)
        None ->
          call(state.config, http.Get, "/app", auth)
          |> result.try(fn(text) {
            json.parse(text, decode.at(["slug"], decode.string))
            |> result.replace_error("couldn't read the app")
          })
      }
      let logins =
        call(state.config, http.Get, "/app/installations", auth)
        |> result.try(fn(text) {
          json.parse(
            text,
            decode.list(decode.at(["account", "login"], decode.string)),
          )
          |> result.replace_error("couldn't read the installations")
        })
      case slug, logins {
        Ok(slug), Ok(logins) -> {
          let accounts =
            github.Accounts(logins:, install_url: install_url(slug))
          #(
            State(
              ..state,
              slug: Some(slug),
              accounts: Some(#(accounts, now + 60)),
            ),
            Some(accounts),
          )
        }
        _, _ -> #(state, None)
      }
    }
  }
}

pub fn install_url(slug: String) -> String {
  "https://github.com/apps/" <> slug <> "/installations/new"
}

fn token_for(
  state: State,
  owner: String,
  repo: String,
) -> #(State, Option(String)) {
  let now = now()
  let name = string.lowercase(owner <> "/" <> repo)
  case installation_token(state, now) {
    #(state, None) -> #(state, None)
    #(state, Some(token)) ->
      case dict.get(state.public, name) {
        Ok(#(public, until)) if until > now -> #(state, keep(public, token))
        _ -> {
          let public = is_public(state.config, token, owner, repo)
          let state =
            State(
              ..state,
              public: dict.insert(state.public, name, #(
                  public,
                  now + believed_s,
                ))
                |> prune(now),
            )
          #(state, keep(public, token))
        }
      }
  }
}

fn keep(public: Bool, token: String) -> Option(String) {
  case public {
    True -> Some(token)
    False -> None
  }
}

fn prune(
  public: Dict(String, #(Bool, Int)),
  now: Int,
) -> Dict(String, #(Bool, Int)) {
  case dict.size(public) > 5000 {
    True -> dict.filter(public, fn(_, entry) { entry.1 > now })
    False -> public
  }
}

/// A current installation token, asking GitHub for one when the last is
/// within five minutes of expiring.
fn installation_token(state: State, now: Int) -> #(State, Option(String)) {
  case state.token {
    Some(#(token, expires)) if expires - now > 300 -> #(state, Some(token))
    _ if now < state.retry_at -> #(state, None)
    _ ->
      case new_token(state, now) {
        Ok(#(token, expires)) -> #(
          State(..state, token: Some(#(token, expires))),
          Some(token),
        )
        Error(reason) -> {
          sys.warn(
            "crushling: the GitHub App's own token: "
            <> reason
            <> "; trying again in 5 minutes",
          )
          #(State(..state, retry_at: now + 300), None)
        }
      }
  }
}

fn new_token(state: State, now: Int) -> Result(#(String, Int), String) {
  let auth = "Bearer " <> jwt(state.config.client_id, state.key, now)
  use text <- result.try(call(
    state.config,
    http.Get,
    "/app/installations",
    auth,
  ))
  use ids <- result.try(
    json.parse(text, decode.list(decode.at(["id"], decode.int)))
    |> result.replace_error("couldn't read the app's installations"),
  )
  use id <- result.try(
    list.first(ids) |> result.replace_error("the app isn't installed anywhere"),
  )
  use text <- result.try(call(
    state.config,
    http.Post,
    "/app/installations/" <> int.to_string(id) <> "/access_tokens",
    auth,
  ))
  json.parse(text, decode.at(["token"], decode.string))
  |> result.replace_error("couldn't read the installation token")
  // Installation tokens last an hour.
  |> result.map(fn(token) { #(token, now + 3600) })
}

fn is_public(
  config: github.Config,
  token: String,
  owner: String,
  repo: String,
) -> Bool {
  call(config, http.Get, "/repos/" <> owner <> "/" <> repo, "Bearer " <> token)
  |> result.try(fn(text) {
    json.parse(text, decode.at(["private"], decode.bool))
    |> result.replace_error("")
  })
  // Private, missing, or unknown: not used.
  == Ok(False)
}

/// How the app is installed on account `owner`: "all" repositories,
/// "selected" ones, or "" when it isn't. Error when GitHub can't be asked.
fn account_selection(
  config: github.Config,
  owner: String,
  auth: String,
) -> Result(String, Nil) {
  let ask = fn(path) {
    call(config, http.Get, path, auth)
    |> result.try(fn(text) {
      json.parse(text, decode.at(["repository_selection"], decode.string))
      |> result.replace_error("")
    })
  }
  case ask("/users/" <> owner <> "/installation") {
    Ok(selection) -> Ok(selection)
    Error(_) ->
      case ask("/orgs/" <> owner <> "/installation") {
        Ok(selection) -> Ok(selection)
        Error(_) ->
          case status(config, "/users/" <> owner <> "/installation", auth) {
            Ok(404) -> Ok("")
            _ -> Error(Nil)
          }
      }
  }
}

fn status(
  config: github.Config,
  path: String,
  auth: String,
) -> Result(Int, String) {
  let assert Ok(req) = request.to("https://api.github.com" <> path)
  req
  |> request.set_header("accept", "application/vnd.github+json")
  |> request.set_header("authorization", auth)
  |> request.set_header("user-agent", "crushling")
  |> config.send
  |> result.map(fn(resp) { resp.status })
}

fn call(
  config: github.Config,
  method: http.Method,
  path: String,
  auth: String,
) -> Result(String, String) {
  let assert Ok(req) = request.to("https://api.github.com" <> path)
  let req =
    req
    |> request.set_method(method)
    |> request.set_header("accept", "application/vnd.github+json")
    |> request.set_header("authorization", auth)
    |> request.set_header("user-agent", "crushling")
  case config.send(req) {
    Error(reason) -> Error(reason)
    Ok(resp) if resp.status >= 200 && resp.status < 300 -> Ok(resp.body)
    Ok(resp) ->
      Error("GitHub answered " <> int.to_string(resp.status) <> " for " <> path)
  }
}

fn now() -> Int {
  sys.system_ms() / 1000
}
