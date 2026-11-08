//// The only process that refreshes a login. Containers get a managed copy:
//// the access token with an empty refresh token, written into their
//// crush.json. crush adopts a newer token from disk before every turn and
//// on a 401, so keeping those files fresh is all it takes; crush never
//// needs to refresh on its own.
////
//// Tokens are renewed at half their lifetime, well before crush's own
//// refresh window (the last fifth of the lifetime) could open.
////
//// A login is a crush.json seeded once with
////
////     CRUSH_GLOBAL_DATA=<dir> crush login claude    # or hyper
////
//// It must be a login only crushling uses: refresh tokens are single use,
//// so two processes refreshing the same login revoke each other.

import crushling/gun
import crushling/sys
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string

pub type Grant {
  Grant(access_token: String, refresh_token: String, expires_in: Int)
}

pub type Login {
  Login(
    /// The provider id in crush.json: "anthropic" or "hyper".
    provider: String,
    /// The crush.json holding the login.
    path: String,
    refresh: fn(String) -> Result(Grant, String),
  )
}

pub type Message {
  /// Keep the managed token in this crush.json fresh, writing it now.
  Watch(path: String, reply: Subject(Result(Nil, String)))
  Unwatch(path: String)
  Renew
}

pub type Token {
  Token(access: String, refresh: String, expires_at: Int, expires_in: Int)
}

type State {
  State(
    login: Login,
    self: Subject(Message),
    token: Result(Token, String),
    watched: List(String),
  )
}

/// After a failed refresh, try again this often, so a revoked login doesn't
/// hammer the token endpoint and a passing outage heals by itself.
const retry_ms = 60_000

@external(erlang, "crushling_token_ffi", "read_login")
fn read_login(path: String, provider: String) -> Result(Token, String)

@external(erlang, "crushling_token_ffi", "write_login")
fn write_login(
  path: String,
  provider: String,
  access: String,
  refresh: String,
  expires_at: Int,
  expires_in: Int,
) -> Result(Nil, String)

@external(erlang, "crushling_token_ffi", "write_managed")
fn write_managed(
  path: String,
  provider: String,
  access: String,
  expires_at: Int,
  expires_in: Int,
) -> Result(Nil, String)

@external(erlang, "crushling_token_ffi", "decode_grant")
fn decode_grant(body: BitArray) -> Result(Grant, Nil)

@external(erlang, "os", "system_time")
fn system_time(unit: SecondUnit) -> Int

type SecondUnit {
  Second
}

fn now() -> Int {
  system_time(Second)
}

pub fn start(login: Login) -> Result(Subject(Message), actor.StartError) {
  actor.new_with_initialiser(1000, fn(self) {
    let state =
      State(
        login:,
        self:,
        token: read_login(login.path, login.provider),
        watched: [],
      )
    process.send(self, Renew)
    state
    |> actor.initialised
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

/// Write the current token into `path` and keep it fresh from now on.
pub fn watch(
  credentials: Subject(Message),
  path: String,
) -> Result(Nil, String) {
  actor.call(credentials, 40_000, Watch(path, _))
}

pub fn unwatch(credentials: Subject(Message), path: String) -> Nil {
  process.send(credentials, Unwatch(path))
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Watch(path, reply) -> {
      let state = renew_if_due(state)
      let written = case state.token {
        Ok(token) -> publish(state.login, token, path)
        Error(reason) -> Error(reason)
      }
      process.send(reply, written)
      let watched = [path, ..list.filter(state.watched, fn(p) { p != path })]
      actor.continue(State(..state, watched:))
    }
    Unwatch(path) ->
      actor.continue(
        State(..state, watched: list.filter(state.watched, fn(p) { p != path })),
      )
    Renew -> {
      let state = renew_if_due(state)
      process.send_after(state.self, next_check_ms(state), Renew)
      actor.continue(state)
    }
  }
}

fn next_check_ms(state: State) -> Int {
  case state.token {
    Error(_) -> retry_ms
    Ok(token) -> int.clamp({ renew_at(token) - now() } * 1000, 1000, 3_600_000)
  }
}

/// Half way through the token's life.
fn renew_at(token: Token) -> Int {
  token.expires_at - token.expires_in / 2
}

fn renew_if_due(state: State) -> State {
  case state.token {
    Ok(token) ->
      case now() >= renew_at(token) {
        True -> renew(state)
        False -> state
      }
    Error(_) -> renew(state)
  }
}

fn renew(state: State) -> State {
  let login = state.login
  // Re-read the login first, so signing in again with `crush login` is
  // picked up without a restart.
  case read_login(login.path, login.provider) {
    Error(reason) -> State(..state, token: Error(reason))
    Ok(token) ->
      case now() < renew_at(token) {
        True -> broadcast(State(..state, token: Ok(token)))
        False -> refresh(state, token)
      }
  }
}

fn refresh(state: State, token: Token) -> State {
  let login = state.login
  case login.refresh(token.refresh) {
    Error(reason) -> {
      let message =
        "the "
        <> login.provider
        <> " login could not be refreshed ("
        <> reason
        <> "); sign in again with CRUSH_GLOBAL_DATA=<dir of "
        <> login.path
        <> "> crush login"
      sys.warn("crushling: " <> message)
      State(..state, token: Error(message))
    }
    Ok(grant) -> {
      // A response without a refresh token leaves the old one in force.
      let refresh_token = case grant.refresh_token {
        "" -> token.refresh
        new -> new
      }
      let fresh =
        Token(
          grant.access_token,
          refresh_token,
          now() + grant.expires_in,
          grant.expires_in,
        )
      case
        write_login(
          login.path,
          login.provider,
          fresh.access,
          fresh.refresh,
          fresh.expires_at,
          fresh.expires_in,
        )
      {
        Ok(Nil) -> Nil
        Error(reason) ->
          // The rotated refresh token now only lives in memory; losing it
          // means signing in again.
          sys.warn("crushling: could not save the refreshed login: " <> reason)
      }
      broadcast(State(..state, token: Ok(fresh)))
    }
  }
}

fn broadcast(state: State) -> State {
  case state.token {
    Ok(token) ->
      list.each(state.watched, fn(path) {
        case publish(state.login, token, path) {
          Ok(Nil) -> Nil
          Error(reason) ->
            sys.warn("crushling: could not update " <> path <> ": " <> reason)
        }
      })
    Error(_) -> Nil
  }
  state
}

fn publish(login: Login, token: Token, path: String) -> Result(Nil, String) {
  write_managed(
    path,
    login.provider,
    token.access,
    token.expires_at,
    token.expires_in,
  )
}

pub const claude_client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

/// Claude Code's subscription scopes, the exact set the token endpoint
/// accepts on a refresh.
pub const claude_scopes =
  "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

/// A Claude subscription login. `version` is the Claude Code version to
/// present to the token endpoint, which throttles unfamiliar user-agents.
pub fn claude(path: String, version: String) -> Login {
  Login("anthropic", path, fn(refresh_token) {
    let body =
      json.object([
        #("grant_type", json.string("refresh_token")),
        #("refresh_token", json.string(refresh_token)),
        #("client_id", json.string(claude_client_id)),
        #("scope", json.string(claude_scopes)),
      ])
    post_grant("platform.claude.com", "/v1/oauth/token", body, [
      #("accept", "application/json, text/plain, */*"),
      #("user-agent", "claude-cli/" <> version <> " (external, cli)"),
    ])
  })
}

/// A Charm Hyper login.
pub fn hyper(path: String) -> Login {
  Login("hyper", path, fn(refresh_token) {
    let body = json.object([#("refresh_token", json.string(refresh_token))])
    post_grant("hyper.charm.land", "/token/exchange", body, [
      #("user-agent", "crush"),
    ])
  })
}

fn post_grant(
  host: String,
  path: String,
  body: json.Json,
  headers: List(#(String, String)),
) -> Result(Grant, String) {
  let body = bit_array.from_string(json.to_string(body))
  let headers = [
    #("host", host),
    #("content-type", "application/json"),
    ..headers
  ]
  use conn <- result.try(gun.connect_tcp(host, 443, True, 10_000))
  let response = gun.request(conn, http.Post, path, headers, body, 30_000)
  gun.close(conn)
  use response <- result.try(response)
  case response.status {
    200 ->
      decode_grant(response.body)
      |> result.replace_error("unreadable token response")
    status ->
      Error(
        "token endpoint answered "
        <> int.to_string(status)
        <> ": "
        <> string.slice(
          bit_array.to_string(response.body) |> result.unwrap(""),
          0,
          300,
        ),
      )
  }
}
