//// Connecting people's GitHub accounts, one workspace's worth, through
//// GitHub's device flow.
////
//// - Each connect runs in a poller process of its own, and the flow is
////   known by that poller's pid: an answer from a poller that is no longer
////   current (disconnected, replaced, or the actor restarted) is dropped,
////   and a poller that dies without answering says so.
//// - Only this actor connects or disconnects an account, so a disconnect
////   and a late grant can't land in the wrong order.
//// - Every change is told to subscribers (`ConnectionChanged`): the Home
////   redraws, and the broker wakes requests waiting for a connection.

import crushling/conversation
import crushling/github.{type Tokens}
import crushling/slack/workspace.{type Workspace}
import crushling/store.{type Store}
import crushling/store/github as accounts
import crushling/sys
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string

pub type Setup {
  Setup(
    /// The Slack workspace whose people connect here.
    workspace: Workspace,
    store: Store,
    github: Option(github.Config),
  )
}

/// Where to answer about a connect: privately, in this thread. `respond`
/// is the `response_url` of the message asking them to connect, when they
/// pressed its button: answers then replace that message, so the ask, the
/// code and the outcome are one message.
pub type Place {
  Place(channel: String, thread_ts: String, respond: Option(String))
}

/// Where a person's connect stands.
pub type Status {
  /// No connect under way: they are connected or not, as the store says.
  Idle
  /// Asked GitHub for a code; none yet.
  Asking
  /// Waiting for them to enter `code` at `url`, until `until` (Unix
  /// seconds).
  ShowingCode(code: String, url: String, until: Int)
}

pub type Event {
  /// `user`'s connection or connect changed; `note` is said once.
  ConnectionChanged(user: String, status: Status, note: Option(String))
}

pub type Message {
  /// Connect `user`'s account. The caller has checked they may.
  Connect(user: String, from: Option(Place))
  /// Forget `user`'s account.
  Disconnect(user: String, from: Option(Place))
  /// Tell `subscriber` about every change from now on.
  Subscribe(subscriber: Subject(Event))
  /// GitHub stopped honouring `user`'s connection, which is already gone.
  Lapsed(user: String)
  // From pollers and workers.
  CodeIssued(poller: Pid, code: github.DeviceCode)
  Granted(poller: Pid, tokens: Tokens, login: String)
  Failed(poller: Pid, reason: String)
  PollerDown(process.Down)
  Revoked(user: String, from: Option(Place), outcome: Revoke)
}

/// How revoking a disconnected token on GitHub went.
pub type Revoke {
  /// Nothing was connected.
  NothingToRevoke
  RevokedOnGitHub
  /// No client secret, so only forgotten here.
  OnlyForgotten
  RevokeFailed(reason: String)
}

type Flow {
  Flow(
    user: String,
    code: Option(github.DeviceCode),
    /// When the code stops working, Unix seconds.
    until: Int,
    from: Option(Place),
  )
}

type State {
  State(
    setup: Setup,
    self: Subject(Message),
    /// Each connect under way, by its poller.
    flows: Dict(Pid, Flow),
    subscribers: List(Subject(Event)),
  )
}

pub fn start(setup: Setup) -> Result(Subject(Message), actor.StartError) {
  actor.new_with_initialiser(1000, fn(self) {
    State(setup:, self:, flows: dict.new(), subscribers: [])
    |> actor.initialised
    |> actor.selecting(
      process.new_selector()
      |> process.select(self)
      |> process.select_monitors(PollerDown),
    )
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  actor.continue(case message {
    Subscribe(subscriber) ->
      State(..state, subscribers: [subscriber, ..state.subscribers])
    Connect(user, from) -> connect(state, user, from)
    Disconnect(user, from) -> disconnect(state, user, from)
    Lapsed(user) -> {
      emit(state, user, Some("Your GitHub connection expired; connect again."))
      state
    }
    CodeIssued(poller, code) ->
      case dict.get(state.flows, poller) {
        Ok(found) -> {
          reply(state, found.from, found.user, code_note(code))
          let found =
            Flow(..found, code: Some(code), until: sys.now() + code.expires_in)
          let state =
            State(..state, flows: dict.insert(state.flows, poller, found))
          emit(state, found.user, None)
          state
        }
        Error(Nil) -> state
      }
    Granted(poller, tokens, login) -> granted(state, poller, tokens, login)
    Failed(poller, reason) ->
      case dict.get(state.flows, poller) {
        Ok(found) -> {
          reply(
            state,
            found.from,
            found.user,
            "_Failed to connect GitHub: " <> reason <> "._",
          )
          let state = end_flow(state, poller)
          emit(state, found.user, Some("Failed to connect: " <> reason <> "."))
          state
        }
        Error(Nil) -> state
      }
    PollerDown(process.ProcessDown(pid:, reason:, ..)) ->
      // A poller that answered has already ended its flow; one that died
      // without answering ends it here.
      case dict.get(state.flows, pid) {
        Ok(found) -> {
          sys.warn(
            "crushling: connecting GitHub for "
            <> found.user
            <> " stopped: "
            // Not the reason itself: a crash's term may hold a token.
            <> case reason {
              process.Normal -> "it ended"
              process.Killed -> "it was killed"
              process.Abnormal(_) -> "it crashed"
            },
          )
          reply(
            state,
            found.from,
            found.user,
            "_The GitHub connection flow crashed. Try again._",
          )
          let state = end_flow(state, pid)
          emit(
            state,
            found.user,
            Some("The connection flow crashed. Try again."),
          )
          state
        }
        Error(Nil) -> state
      }
    PollerDown(_) -> state
    Revoked(user, from, outcome) -> {
      let said = case outcome {
        NothingToRevoke -> "GitHub wasn't connected."
        RevokedOnGitHub -> "GitHub disconnected."
        OnlyForgotten ->
          "GitHub disconnected here. GitHub still lists crushling under your authorized apps until you revoke it there."
        RevokeFailed(reason) -> {
          sys.warn("crushling: revoking GitHub for " <> user <> ": " <> reason)
          "GitHub disconnected here, but revoking it on GitHub failed. Revoke crushling in your GitHub settings."
        }
      }
      reply(state, from, user, "_" <> said <> "_")
      emit(state, user, Some(said))
      state
    }
  })
}

/// The connect under way for `user`, and its poller.
fn flow_of(state: State, user: String) -> Result(#(Pid, Flow), Nil) {
  dict.to_list(state.flows) |> list.find(fn(pair) { { pair.1 }.user == user })
}

fn end_flow(state: State, poller: Pid) -> State {
  State(..state, flows: dict.delete(state.flows, poller))
}

/// Tell subscribers where `user` stands now.
fn emit(state: State, user: String, note: Option(String)) -> Nil {
  let status = case flow_of(state, user) {
    Error(Nil) -> Idle
    Ok(#(_, Flow(code: None, ..))) -> Asking
    Ok(#(_, Flow(code: Some(code), until:, ..))) ->
      ShowingCode(code: code.user_code, url: code.verification_uri, until:)
  }
  let event = ConnectionChanged(user:, status:, note:)
  list.each(state.subscribers, process.send(_, event))
}

fn connect(state: State, user: String, from: Option(Place)) -> State {
  case state.setup.github, flow_of(state, user) {
    None, _ -> {
      reply(state, from, user, "_GitHub isn't set up for this crushling._")
      state
    }
    // Under way: answer here too, with the code if there is one.
    Some(_), Ok(#(poller, found)) -> {
      case found.code, from {
        Some(code), Some(_) -> reply(state, from, user, code_note(code))
        _, _ -> Nil
      }
      let found = Flow(..found, from: option.or(from, found.from))
      let state = State(..state, flows: dict.insert(state.flows, poller, found))
      emit(state, user, None)
      state
    }
    Some(config), Error(Nil) -> {
      let self = state.self
      let poller =
        process.spawn_unlinked(fn() { process.send(self, poll(config, self)) })
      let _ = process.monitor(poller)
      let found = Flow(user:, code: None, until: 0, from:)
      let state = State(..state, flows: dict.insert(state.flows, poller, found))
      emit(state, user, None)
      state
    }
  }
}

/// The poller: get a code, wait for the person, find out who they are.
/// Returns the message that ends the flow.
fn poll(config: github.Config, self: Subject(Message)) -> Message {
  let me = process.self()
  let result = {
    use code <- result.try(github.device_code(config))
    process.send(self, CodeIssued(me, code))
    use tokens <- result.try(github.wait(
      config,
      code,
      sys.now() + code.expires_in,
      sys.now,
    ))
    use login <- result.map(github.login(config, tokens))
    #(tokens, login)
  }
  case result {
    Ok(#(tokens, login)) -> Granted(me, tokens, login)
    Error(reason) -> Failed(me, reason)
  }
}

fn granted(state: State, poller: Pid, tokens: Tokens, login: String) -> State {
  case dict.get(state.flows, poller), state.setup.github {
    Ok(found), _ -> {
      let user = found.user
      let account =
        accounts.Account(
          team: workspace.team(state.setup.workspace),
          user:,
          login:,
          tokens:,
          connected_at: sys.now(),
        )
      let state = end_flow(state, poller)
      case accounts.put(state.setup.store, account) {
        Ok(Nil) -> {
          reply(
            state,
            found.from,
            user,
            "_GitHub connected as @" <> login <> "._",
          )
          emit(state, user, None)
        }
        Error(reason) -> {
          reply(
            state,
            found.from,
            user,
            "_Failed to save the GitHub connection. Try again._",
          )
          sys.warn("crushling: saving GitHub for " <> user <> ": " <> reason)
          emit(state, user, Some("Failed to save the connection. Try again."))
        }
      }
      state
    }
    // A flow that ended meanwhile: don't keep what it got.
    Error(Nil), Some(config) -> {
      process.spawn_unlinked(fn() {
        case github.revoke(config, tokens) {
          Error(reason) ->
            sys.warn(
              "crushling: revoking a GitHub grant that came too late: "
              <> reason,
            )
          Ok(_) -> Nil
        }
      })
      state
    }
    Error(Nil), None -> state
  }
}

/// Forget the account at once, here, then revoke it on GitHub off the
/// actor. A connect under way is ended too.
fn disconnect(state: State, user: String, from: Option(Place)) -> State {
  let state = case flow_of(state, user) {
    Ok(#(poller, _)) -> {
      process.kill(poller)
      end_flow(state, poller)
    }
    Error(Nil) -> state
  }
  let setup = state.setup
  let found = accounts.get(setup.store, workspace.team(setup.workspace), user)
  let forgot =
    accounts.delete(setup.store, workspace.team(setup.workspace), user)
  let self = state.self
  case found, forgot {
    Error(reason), _ | _, Error(reason) -> {
      sys.warn("crushling: disconnecting GitHub for " <> user <> ": " <> reason)
      reply(state, from, user, "_Failed to disconnect GitHub. Try again._")
      emit(state, user, Some("Failed to disconnect. Try again."))
    }
    Ok(None), Ok(Nil) ->
      process.send(self, Revoked(user, from, NothingToRevoke))
    Ok(Some(account)), Ok(Nil) -> {
      process.spawn_unlinked(fn() {
        process.send(
          self,
          Revoked(user, from, revoke(setup.github, account.tokens)),
        )
      })
      Nil
    }
  }
  state
}

/// Revoke on GitHub, refreshing first if the token has expired: GitHub
/// revokes by access token.
fn revoke(config: Option(github.Config), tokens: Tokens) -> Revoke {
  case config {
    None -> OnlyForgotten
    Some(config) -> {
      let tokens = case github.stale(tokens, sys.now()) {
        True ->
          github.refresh(config, tokens, sys.now()) |> result.unwrap(tokens)
        False -> tokens
      }
      case github.revoke(config, tokens) {
        Ok(True) -> RevokedOnGitHub
        Ok(False) -> OnlyForgotten
        Error(reason) -> RevokeFailed(reason)
      }
    }
  }
}

fn code_note(code: github.DeviceCode) -> String {
  "Enter *`"
  <> code.user_code
  <> "`* at <"
  <> code.verification_uri
  <> "|"
  <> string.replace(code.verification_uri, "https://", "")
  <> "> to connect your GitHub account."
}

/// Answer privately where a `!github` command or an ask's Connect was
/// given: never in place of the ask, which others may still need.
fn reply(state: State, from: Option(Place), user: String, text: String) -> Nil {
  let workspace = state.setup.workspace
  case from {
    Some(Place(respond: Some(url), ..)) ->
      workspace.respond_later(workspace, url, text, False)
    Some(Place(channel:, thread_ts:, respond: None)) ->
      workspace.whisper_later(
        workspace,
        conversation.from_slack(channel, thread_ts),
        user,
        workspace.Message(text, []),
      )
    None -> Nil
  }
}
