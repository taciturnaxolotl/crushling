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
////
//// The actor only keeps answers. Asking GitHub happens in a worker per
//// question, so a slow GitHub holds up only those waiting on that same
//// question, and everyone asking it at once shares one worker.

import crushling/github
import crushling/github/http.{AppJwt, Bearer}
import crushling/github/repo.{type Repo}
import crushling/sys
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http as gleam_http
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

/// GitHub couldn't be asked, or didn't answer in time: neither yes nor no.
pub type Unknown {
  Unknown(reason: String)
}

/// How the app is installed on an account.
pub type Selection {
  All
  Selected
  NotInstalled
}

/// What a worker asks GitHub.
type Question {
  IsPublic(Repo)
  IsInstalled(Repo)
  ListAccounts
  InstallationToken
}

type Answer {
  Flag(Result(Bool, Unknown))
  Found(Result(github.Accounts, Unknown))
  Token(Result(String, Unknown))
}

pub opaque type Message {
  Ask(question: Question, reply: Subject(Answer))
  /// A worker's answer, believed until `until` (Unix seconds; 0 not at all).
  Answered(question: Question, answer: Answer, until: Int)
  WorkerDown(process.Down)
}

type State {
  State(
    config: github.Config,
    key: Key,
    self: Subject(Message),
    /// Answers by question, and until when each is believed.
    known: Dict(String, #(Answer, Int)),
    /// Who waits on the question a worker is asking.
    waiting: Dict(String, List(Subject(Answer))),
    workers: Dict(Pid, Question),
  )
}

/// How long a repo's visibility is believed: a repo made private stops
/// being read with the app's token within this.
const believed_s = 600

/// Believed this long: an install shows up within `not_installed_s`, which
/// is what someone waiting for one waits on.
const installed_s = 600

const not_installed_s = 15

/// After failing to get an installation token, when to try again.
const token_retry_s = 300

const ask_ms = 20_000

pub fn start(config: github.Config, key: Key) -> Result(App, actor.StartError) {
  actor.new_with_initialiser(1000, fn(self) {
    State(
      config:,
      key:,
      self:,
      known: dict.new(),
      waiting: dict.new(),
      workers: dict.new(),
    )
    |> actor.initialised
    |> actor.selecting(
      process.new_selector()
      |> process.select(self)
      |> process.select_monitors(WorkerDown),
    )
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

/// The app's token, if it may be used to read `repo`: the repo is public.
/// None otherwise, or when GitHub can't be asked.
pub fn token(app: App, repo: Repo) -> Option(String) {
  case ask(app, InstallationToken), public(app, repo) {
    Token(Ok(token)), Ok(True) -> Some(token)
    _, _ -> None
  }
}

/// Whether GitHub says `repo` is public.
pub fn public(app: App, repo: Repo) -> Result(Bool, Unknown) {
  case ask(app, IsPublic(repo)) {
    Flag(flag) -> flag
    _ -> Error(Unknown("an odd answer"))
  }
}

/// Whether the app is installed on the account `repo` belongs to, with that
/// repo selected.
pub fn installed(app: App, repo: Repo) -> Result(Bool, Unknown) {
  case ask(app, IsInstalled(repo)) {
    Flag(flag) -> flag
    _ -> Error(Unknown("an odd answer"))
  }
}

/// Where the app is installed, and how to install it elsewhere.
pub fn accounts(app: App) -> Option(github.Accounts) {
  case ask(app, ListAccounts) {
    Found(Ok(accounts)) -> Some(accounts)
    _ -> None
  }
}

fn ask(app: App, question: Question) -> Answer {
  let reply = process.new_subject()
  process.send(app, Ask(question, reply))
  case process.receive(reply, ask_ms) {
    Ok(answer) -> answer
    Error(Nil) -> unknown(question, "GitHub took too long")
  }
}

fn unknown(question: Question, reason: String) -> Answer {
  case question {
    IsPublic(_) | IsInstalled(_) -> Flag(Error(Unknown(reason)))
    ListAccounts -> Found(Error(Unknown(reason)))
    InstallationToken -> Token(Error(Unknown(reason)))
  }
}

fn name(question: Question) -> String {
  case question {
    IsPublic(repo) -> "public:" <> repo.key(repo)
    IsInstalled(repo) -> "installed:" <> repo.key(repo)
    ListAccounts -> "accounts"
    InstallationToken -> "token"
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  actor.continue(case message {
    Ask(question, reply) -> {
      let now = sys.now()
      let named = name(question)
      case dict.get(state.known, named), dict.get(state.waiting, named) {
        Ok(#(answer, until)), _ if until > now -> {
          process.send(reply, answer)
          state
        }
        _, Ok(waiting) ->
          State(
            ..state,
            waiting: dict.insert(state.waiting, named, [reply, ..waiting]),
          )
        _, Error(Nil) -> {
          let worker = work(state, question)
          let _ = process.monitor(worker)
          State(
            ..state,
            waiting: dict.insert(state.waiting, named, [reply]),
            workers: dict.insert(state.workers, worker, question),
          )
        }
      }
    }
    Answered(question, answer, until) -> {
      let state = case until > 0 {
        True -> remember(state, name(question), answer, until)
        False -> state
      }
      settle(state, question, answer)
    }
    WorkerDown(process.ProcessDown(pid:, reason:, ..)) ->
      case dict.get(state.workers, pid) {
        Ok(question) -> {
          let state = State(..state, workers: dict.delete(state.workers, pid))
          case reason {
            // Its answer came first, and settled those waiting.
            process.Normal -> state
            _ -> {
              sys.warn(
                "crushling: asking GitHub about the app ("
                <> name(question)
                <> ") crashed",
              )
              settle(
                state,
                question,
                unknown(question, "asking GitHub crashed"),
              )
            }
          }
        }
        Error(Nil) -> state
      }
    WorkerDown(_) -> state
  })
}

/// Answer everyone waiting on `question`.
fn settle(state: State, question: Question, answer: Answer) -> State {
  let named = name(question)
  dict.get(state.waiting, named)
  |> result.unwrap([])
  |> list.each(process.send(_, answer))
  State(..state, waiting: dict.delete(state.waiting, named))
}

fn remember(state: State, named: String, answer: Answer, until: Int) -> State {
  let now = sys.now()
  let kept = case dict.size(state.known) > 5000 {
    True -> dict.filter(state.known, fn(_, entry) { entry.1 > now })
    False -> state.known
  }
  State(..state, known: dict.insert(kept, named, #(answer, until)))
}

/// Ask GitHub off the actor; the worker sends its answer back.
fn work(state: State, question: Question) -> Pid {
  let State(config:, key:, self:, ..) = state
  process.spawn_unlinked(fn() {
    let now = sys.now()
    let jwt = AppJwt(jwt(config.client_id, key, now))
    let #(answer, until) = case question {
      InstallationToken ->
        case new_token(config, jwt, now) {
          Ok(#(token, expires)) -> #(Token(Ok(token)), expires - 300)
          Error(reason) -> {
            sys.warn(
              "crushling: the GitHub App's own token: "
              <> reason
              <> "; trying again in 5 minutes",
            )
            #(Token(Error(Unknown(reason))), now + token_retry_s)
          }
        }
      IsPublic(repo) ->
        case ask(self, InstallationToken) {
          Token(Ok(token)) ->
            case is_public(config, token, repo) {
              Ok(public) -> #(Flag(Ok(public)), now + believed_s)
              Error(unknown) -> #(Flag(Error(unknown)), 0)
            }
          // Without a token, nothing is read with it, so "not public".
          _ -> #(Flag(Ok(False)), 0)
        }
      IsInstalled(repo) ->
        case installed_on(config, jwt, repo) {
          Ok(True) -> #(Flag(Ok(True)), now + installed_s)
          Ok(False) -> #(Flag(Ok(False)), now + not_installed_s)
          Error(unknown) -> #(Flag(Error(unknown)), 0)
        }
      ListAccounts ->
        case list_accounts(config, jwt) {
          Ok(accounts) -> #(Found(Ok(accounts)), now + 60)
          Error(unknown) -> #(Found(Error(unknown)), 0)
        }
    }
    process.send(self, Answered(question, answer, until))
  })
}

/// GitHub says 404 both for a repo the app can't see and for one that
/// doesn't exist. Installed on the whole account, it's the latter: nothing
/// to install.
fn installed_on(
  config: github.Config,
  jwt: http.Auth,
  repo: Repo,
) -> Result(Bool, Unknown) {
  let path = "/repos/" <> repo.full(repo) <> "/installation"
  case config.send(http.api(gleam_http.Get, path, jwt)) {
    Ok(resp) if resp.status == 200 -> Ok(True)
    Ok(resp) if resp.status == 404 ->
      account_selection(config, repo.owner(repo), jwt)
      |> result.map(fn(selection) { selection == All })
    Ok(resp) -> Error(Unknown("GitHub answered " <> int.to_string(resp.status)))
    Error(reason) -> Error(Unknown(reason))
  }
}

fn list_accounts(
  config: github.Config,
  jwt: http.Auth,
) -> Result(github.Accounts, Unknown) {
  use slug <- result.try(
    call(config, "/app", jwt)
    |> result.try(fn(text) {
      json.parse(text, decode.at(["slug"], decode.string))
      |> result.replace_error("couldn't read the app")
    })
    |> result.map_error(Unknown),
  )
  use logins <- result.map(
    call(config, "/app/installations", jwt)
    |> result.try(fn(text) {
      json.parse(
        text,
        decode.list(decode.at(["account", "login"], decode.string)),
      )
      |> result.replace_error("couldn't read the installations")
    })
    |> result.map_error(Unknown),
  )
  github.Accounts(logins:, install_url: install_url(slug))
}

pub fn install_url(slug: String) -> String {
  "https://github.com/apps/" <> slug <> "/installations/new"
}

fn new_token(
  config: github.Config,
  jwt: http.Auth,
  now: Int,
) -> Result(#(String, Int), String) {
  use text <- result.try(call(config, "/app/installations", jwt))
  use ids <- result.try(
    json.parse(text, decode.list(decode.at(["id"], decode.int)))
    |> result.replace_error("couldn't read the app's installations"),
  )
  use id <- result.try(
    list.first(ids) |> result.replace_error("the app isn't installed anywhere"),
  )
  use text <- result.try(http.body(
    config.send,
    http.api(
      gleam_http.Post,
      "/app/installations/" <> int.to_string(id) <> "/access_tokens",
      jwt,
    ),
    "asking for an installation token",
  ))
  json.parse(text, decode.at(["token"], decode.string))
  |> result.replace_error("couldn't read the installation token")
  // Installation tokens last an hour.
  |> result.map(fn(token) { #(token, now + 3600) })
}

/// Private and missing are both "not public"; only no answer is unknown.
fn is_public(
  config: github.Config,
  token: String,
  repo: Repo,
) -> Result(Bool, Unknown) {
  let req =
    http.api(gleam_http.Get, "/repos/" <> repo.full(repo), Bearer(token))
  case config.send(req) {
    Error(reason) -> Error(Unknown(reason))
    Ok(resp) if resp.status == 200 ->
      case json.parse(resp.body, decode.at(["private"], decode.bool)) {
        Ok(private) -> Ok(!private)
        Error(_) -> Error(Unknown("couldn't read the repository"))
      }
    Ok(resp) if resp.status == 404 || resp.status == 403 -> Ok(False)
    Ok(resp) -> Error(Unknown("GitHub answered " <> int.to_string(resp.status)))
  }
}

/// How the app is installed on account `owner`, asked as a user and then
/// as an organization.
fn account_selection(
  config: github.Config,
  owner: String,
  jwt: http.Auth,
) -> Result(Selection, Unknown) {
  let ask = fn(path) {
    case config.send(http.api(gleam_http.Get, path, jwt)) {
      Error(reason) -> Error(Unknown(reason))
      Ok(resp) if resp.status == 404 -> Ok(None)
      Ok(resp) if resp.status == 200 ->
        case
          json.parse(
            resp.body,
            decode.at(["repository_selection"], decode.string),
          )
        {
          Ok("all") -> Ok(Some(All))
          Ok(_) -> Ok(Some(Selected))
          Error(_) -> Error(Unknown("couldn't read the installation"))
        }
      Ok(resp) ->
        Error(Unknown("GitHub answered " <> int.to_string(resp.status)))
    }
  }
  use as_user <- result.try(ask("/users/" <> owner <> "/installation"))
  case as_user {
    Some(selection) -> Ok(selection)
    None ->
      ask("/orgs/" <> owner <> "/installation")
      |> result.map(option.unwrap(_, NotInstalled))
  }
}

fn call(
  config: github.Config,
  path: String,
  auth: http.Auth,
) -> Result(String, String) {
  http.body(
    config.send,
    http.api(gleam_http.Get, path, auth),
    "asking " <> path,
  )
}
