//// One workspace's GitHub connections and App Home, as an actor apart from
//// the registry. The registry decides who may do what and which threads
//// are someone's; this module does the rest:
////
//// - Connecting runs GitHub's device flow in a poller process per person.
////   Each flow has an id, and the actor monitors its poller: an answer from
////   a flow that is no longer current (disconnected, replaced, or the actor
////   restarted) is dropped, and a poller that dies says so.
//// - Only the actor writes a person's account, so a disconnect and a late
////   grant can't land in the wrong order.
//// - Homes are drawn and published by one process per workspace, in the
////   order asked, so an older view never covers a newer one.

import crushling/github.{type Tokens}
import crushling/home
import crushling/proxy/meter
import crushling/slack
import crushling/store.{type Store}
import crushling/store/github as accounts
import crushling/store/usage
import crushling/sys
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import slackline
import slackline/api/chat
import slackline/api/views
import slackline/httpc

pub type Setup {
  Setup(
    client: slackline.Client,
    store: Store,
    team: String,
    github: Option(github.Config),
    default_model: String,
  )
}

/// A thread of someone's whose agent is running, as the registry knows it.
pub type Thread {
  Thread(key: String, channel: String, thread_ts: String, model: String)
}

/// Where to answer about a connect: privately, in this thread. `respond`
/// is the `response_url` of the message asking them to connect, when they
/// pressed its button: answers then replace that message, so the ask, the
/// code and the outcome are one message.
pub type Place {
  Place(channel: String, thread_ts: String, respond: Option(String))
}

pub type Message {
  /// Draw `user`'s Home. `threads` is None for someone who may not use
  /// crushling.
  Show(user: String, threads: Option(List(Thread)))
  /// Connect `user`'s account. The registry has checked they may.
  Connect(user: String, from: Option(Place))
  /// Forget `user`'s account.
  Disconnect(user: String, from: Option(Place))
  /// `user`'s GitHub access token, refreshed first when it's about to
  /// expire; None when they haven't connected (or their connection lapsed).
  Access(user: String, reply: Subject(Result(Option(String), String)))
  // From pollers and workers.
  CodeIssued(user: String, flow: Int, code: github.DeviceCode)
  Granted(user: String, flow: Int, tokens: Tokens, login: String)
  Failed(user: String, flow: Int, reason: String)
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
    id: Int,
    pid: process.Pid,
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
    publisher: Subject(Publish),
    flows: Dict(String, Flow),
    next_flow: Int,
    /// Each person's threads as of their last `Show`, for drawing their Home
    /// again after a connect or disconnect.
    threads: Dict(String, Option(List(Thread))),
    /// Said once under the GitHub section, then dropped.
    notes: Dict(String, String),
  )
}

pub fn start(setup: Setup) -> Result(Subject(Message), actor.StartError) {
  actor.new_with_initialiser(1000, fn(self) {
    let publisher = start_publisher(setup)
    State(
      setup:,
      self:,
      publisher:,
      flows: dict.new(),
      next_flow: 1,
      threads: dict.new(),
      notes: dict.new(),
    )
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
    Show(user, threads) ->
      State(..state, threads: dict.insert(state.threads, user, threads))
      |> publish(user)
    Connect(user, from) -> connect(state, user, from)
    Disconnect(user, from) -> disconnect(state, user, from)
    Access(user, reply) -> {
      let #(state, answer) = access(state, user)
      process.send(reply, answer)
      state
    }
    CodeIssued(user, flow, code) ->
      case current(state, user, flow) {
        Some(found) -> {
          reply(state, found.from, user, code_note(code))
          let found =
            Flow(..found, code: Some(code), until: now() + code.expires_in)
          State(..state, flows: dict.insert(state.flows, user, found))
          |> publish(user)
        }
        None -> state
      }
    Granted(user, flow, tokens, login) ->
      granted(state, user, flow, tokens, login)
    Failed(user, flow, reason) ->
      case current(state, user, flow) {
        Some(found) -> {
          reply(
            state,
            found.from,
            user,
            "_Couldn't connect GitHub: " <> reason <> "._",
          )
          end_flow(state, user)
          |> note(user, "Couldn't connect: " <> reason <> ".")
          |> publish(user)
        }
        None -> state
      }
    PollerDown(process.ProcessDown(pid:, reason:, ..)) ->
      // A poller that answered has already ended its flow; one that died
      // without answering ends it here.
      case
        list.find(dict.to_list(state.flows), fn(pair) { { pair.1 }.pid == pid })
      {
        Ok(#(user, found)) -> {
          sys.warn(
            "crushling: connecting GitHub for "
            <> user
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
            user,
            "_Connecting GitHub stopped unexpectedly._",
          )
          end_flow(state, user)
          |> note(user, "Connecting stopped unexpectedly; try again.")
          |> publish(user)
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
          "GitHub disconnected here, but revoking it on GitHub failed; revoke crushling in your GitHub settings."
        }
      }
      reply(state, from, user, "_" <> said <> "_")
      note(state, user, said) |> publish(user)
    }
  })
}

fn current(state: State, user: String, flow: Int) -> Option(Flow) {
  case dict.get(state.flows, user) {
    Ok(found) if found.id == flow -> Some(found)
    _ -> None
  }
}

fn end_flow(state: State, user: String) -> State {
  State(..state, flows: dict.delete(state.flows, user))
}

fn note(state: State, user: String, text: String) -> State {
  State(..state, notes: dict.insert(state.notes, user, text))
}

fn connect(state: State, user: String, from: Option(Place)) -> State {
  case state.setup.github, dict.get(state.flows, user) {
    None, _ -> {
      reply(state, from, user, "_GitHub isn't set up for this crushling._")
      state
    }
    // Under way: answer here too, with the code if there is one.
    Some(_), Ok(found) -> {
      case found.code, from {
        Some(code), Some(_) -> reply(state, from, user, code_note(code))
        _, _ -> Nil
      }
      let found = Flow(..found, from: option.or(from, found.from))
      State(..state, flows: dict.insert(state.flows, user, found))
      |> publish(user)
    }
    Some(config), Error(Nil) -> {
      let id = state.next_flow
      let self = state.self
      let pid =
        process.spawn_unlinked(fn() {
          process.send(self, poll(config, user, id, self))
        })
      let _ = process.monitor(pid)
      let found = Flow(id:, pid:, code: None, until: 0, from:)
      State(
        ..state,
        flows: dict.insert(state.flows, user, found),
        next_flow: id + 1,
      )
      |> publish(user)
    }
  }
}

/// The poller: get a code, wait for the person, find out who they are.
/// Returns the message that ends the flow.
fn poll(
  config: github.Config,
  user: String,
  flow: Int,
  self: Subject(Message),
) -> Message {
  let result = {
    use code <- result.try(github.device_code(config))
    process.send(self, CodeIssued(user, flow, code))
    use tokens <- result.try(github.wait(
      config,
      code,
      now() + code.expires_in,
      now,
    ))
    use login <- result.map(github.login(config, tokens))
    #(tokens, login)
  }
  case result {
    Ok(#(tokens, login)) -> Granted(user, flow, tokens, login)
    Error(reason) -> Failed(user, flow, reason)
  }
}

fn granted(
  state: State,
  user: String,
  flow: Int,
  tokens: Tokens,
  login: String,
) -> State {
  case current(state, user, flow), state.setup.github {
    Some(found), _ -> {
      let account =
        accounts.Account(
          team: state.setup.team,
          user:,
          login:,
          tokens:,
          connected_at: now(),
        )
      let state = end_flow(state, user)
      case accounts.put(state.setup.store, account) {
        Ok(Nil) -> {
          reply(
            state,
            found.from,
            user,
            "_GitHub connected as @" <> login <> "._",
          )
          publish(state, user)
        }
        Error(reason) -> {
          reply(
            state,
            found.from,
            user,
            "_Couldn't save the GitHub connection._",
          )
          sys.warn("crushling: saving GitHub for " <> user <> ": " <> reason)
          note(state, user, "Couldn't save the connection.") |> publish(user)
        }
      }
    }
    // A flow that ended meanwhile: don't keep what it got.
    None, Some(config) -> {
      process.spawn_unlinked(fn() {
        let _ = github.revoke(config, tokens)
        Nil
      })
      state
    }
    None, None -> state
  }
}

/// Forget the account at once, here, then revoke it on GitHub off the
/// actor. A connect under way is ended too.
fn disconnect(state: State, user: String, from: Option(Place)) -> State {
  let state = case dict.get(state.flows, user) {
    Ok(found) -> {
      process.kill(found.pid)
      end_flow(state, user)
    }
    Error(Nil) -> state
  }
  let setup = state.setup
  let found = accounts.get(setup.store, setup.team, user)
  let forgot = accounts.delete(setup.store, setup.team, user)
  let self = state.self
  case found, forgot {
    Error(reason), _ | _, Error(reason) -> {
      sys.warn("crushling: disconnecting GitHub for " <> user <> ": " <> reason)
      reply(state, from, user, "_Couldn't disconnect GitHub; try again._")
      note(state, user, "Couldn't disconnect; try again.") |> publish(user)
    }
    Ok(None), Ok(Nil) -> {
      process.send(self, Revoked(user, from, NothingToRevoke))
      state
    }
    Ok(Some(account)), Ok(Nil) -> {
      process.spawn_unlinked(fn() {
        process.send(
          self,
          Revoked(user, from, revoke(setup.github, account.tokens)),
        )
      })
      state
    }
  }
}

/// The person's access token. A refresh happens here, in the actor, so two
/// requests at once refresh once and a disconnect can't race the save. It
/// is rare (every few hours a person) and short.
fn access(
  state: State,
  user: String,
) -> #(State, Result(Option(String), String)) {
  let setup = state.setup
  case setup.github, accounts.get(setup.store, setup.team, user) {
    None, _ -> #(state, Ok(None))
    _, Error(reason) -> #(state, Error(reason))
    _, Ok(None) -> #(state, Ok(None))
    Some(config), Ok(Some(account)) ->
      case github.stale(account.tokens, now()) {
        False -> #(state, Ok(Some(account.tokens.access)))
        True ->
          case github.lapsed(account.tokens, now()) {
            True -> lapse(state, user, "it expired")
            False ->
              case github.refresh(config, account.tokens, now()) {
                Ok(tokens) ->
                  case
                    accounts.put(
                      setup.store,
                      accounts.Account(..account, tokens:),
                    )
                  {
                    Ok(Nil) -> #(state, Ok(Some(tokens.access)))
                    Error(reason) -> #(state, Error(reason))
                  }
                Error(github.Refused(reason)) -> lapse(state, user, reason)
                Error(github.Unreachable(reason)) -> #(state, Error(reason))
              }
          }
      }
  }
}

/// Forget a connection GitHub no longer honours, and say so on the Home.
fn lapse(
  state: State,
  user: String,
  why: String,
) -> #(State, Result(Option(String), String)) {
  sys.warn("crushling: GitHub connection of " <> user <> " lapsed: " <> why)
  let _ = accounts.delete(state.setup.store, state.setup.team, user)
  let state =
    note(state, user, "Your GitHub connection expired; connect again.")
    |> publish(user)
  #(state, Ok(None))
}

/// Revoke on GitHub, refreshing first if the token has expired: GitHub
/// revokes by access token.
fn revoke(config: Option(github.Config), tokens: Tokens) -> Revoke {
  case config {
    None -> OnlyForgotten
    Some(config) -> {
      let tokens = case github.stale(tokens, now()) {
        True -> github.refresh(config, tokens, now()) |> result.unwrap(tokens)
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
  <> "`* at "
  <> code.verification_uri
  <> " to connect your GitHub account."
}

/// Answer privately where a `!github` command was given.
fn reply(state: State, from: Option(Place), user: String, text: String) -> Nil {
  case from {
    Some(Place(respond: Some(url), ..)) -> {
      process.spawn_unlinked(fn() { slack.replace_ephemeral(url, text) })
      Nil
    }
    Some(Place(channel:, thread_ts:, respond: None)) -> {
      let client = state.setup.client
      process.spawn_unlinked(fn() {
        slack.whisper(client, channel, thread_ts, user, text)
      })
      Nil
    }
    None -> Nil
  }
}

// Publishing --------------------------------------------------------------------

/// A Home to draw: who for, their threads, and their GitHub state.
type Publish {
  Publish(user: String, threads: Option(List(Thread)), github: home.GitHub)
}

/// Draw `user`'s Home as things stand, once, and drop the note shown.
fn publish(state: State, user: String) -> State {
  let threads = dict.get(state.threads, user) |> result.unwrap(Some([]))
  let note = dict.get(state.notes, user) |> option.from_result
  let github = case state.setup.github, dict.get(state.flows, user) {
    None, _ -> home.Unavailable
    Some(_), Ok(Flow(code: None, ..)) -> home.Asking
    Some(_), Ok(Flow(code: Some(code), until:, ..)) ->
      home.Connecting(
        code: code.user_code,
        url: code.verification_uri,
        minutes: { until - now() + 59 } / 60,
      )
    Some(_), Error(Nil) ->
      case accounts.get(state.setup.store, state.setup.team, user) {
        // Where the app is, filled in when the Home is drawn.
        Ok(Some(account)) ->
          home.Connected(login: account.login, note:, accounts: None)
        Ok(None) -> home.NotConnected(note:)
        Error(reason) -> {
          sys.warn("crushling: reading GitHub for " <> user <> ": " <> reason)
          home.NotConnected(note: Some("Couldn't read your connection."))
        }
      }
  }
  process.send(state.publisher, Publish(user:, threads:, github:))
  State(..state, notes: dict.delete(state.notes, user))
}

/// One process per workspace draws and publishes Homes in the order asked.
fn start_publisher(setup: Setup) -> Subject(Publish) {
  let ready = process.new_subject()
  process.spawn(fn() {
    let inbox = process.new_subject()
    process.send(ready, inbox)
    publish_forever(setup, inbox)
  })
  let assert Ok(inbox) = process.receive(ready, 1000)
  inbox
}

fn publish_forever(setup: Setup, inbox: Subject(Publish)) -> Nil {
  let Publish(user:, threads:, github:) = process.receive_forever(inbox)
  let github = case github, setup.github {
    home.Connected(..) as connected, Some(config) ->
      home.Connected(..connected, accounts: config.accounts())
    github, _ -> github
  }
  let view = home.view(draw(setup, threads, github))
  case views.publish(user_id: user, view:) |> httpc.send(setup.client) {
    Ok(_) -> Nil
    Error(error) ->
      sys.warn(
        "crushling: publishing the Home for "
        <> user
        <> ": "
        <> slackline.describe_error(error),
      )
  }
  publish_forever(setup, inbox)
}

fn draw(
  setup: Setup,
  threads: Option(List(Thread)),
  github: home.GitHub,
) -> home.Home {
  case threads {
    None -> home.NotAllowed
    Some(threads) -> {
      let total = fn(since) {
        usage.team_total(setup.store, setup.team, since)
        |> result.unwrap(meter.zero)
      }
      home.Home(
        github:,
        threads: list.take(threads, home.max_threads)
          |> list.map(fn(thread) {
            home.Thread(
              channel: thread.channel,
              link: chat.get_permalink(
                channel: thread.channel,
                message_ts: thread.thread_ts,
              )
                |> httpc.send(setup.client)
                |> result.map(fn(found) { found.permalink })
                |> option.from_result,
              model: thread.model,
              spent: usage.thread_total(setup.store, thread.key, usage.Ever)
                |> result.unwrap(meter.zero),
            )
          }),
        thread_count: list.length(threads),
        today: total(usage.Today),
        month: total(usage.Month),
        default_model: setup.default_model,
      )
    }
  }
}

fn now() -> Int {
  sys.system_ms() / 1000
}
