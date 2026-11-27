//// Whose GitHub credentials a request uses, one broker per workspace.
////
//// A request from a thread's sandbox goes as the person whose prompt the
//// agent is on, when they've connected, or as whoever connected from that
//// thread's ask instead; a read nobody connected for goes
//// with the app's own token on a public repo, else with none. Pushes and
//// opening pull requests only ever go as a person. What's missing comes
//// back as a `Need`, which the caller can ask for and `await`.
////
//// The broker keeps people's tokens fresh. A token about to expire is
//// refreshed by one process per person while everyone asking for it waits,
//// and a refresh GitHub refuses ends the connection.

import crushling/github.{type Tokens}
import crushling/github/app.{type App}
import crushling/github/connect
import crushling/github/repo.{type Repo}
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

/// The GitHub App people connect through, and its own key when known.
pub type GitHub {
  GitHub(config: github.Config, app: Option(App))
}

/// What a credential is for.
pub type Purpose {
  Read
  Push
  OpenPr
}

pub type Credential {
  AsPerson(login: String, token: String)
  /// The app's installation token, only ever for a public repo.
  AsApp(token: String)
  Anonymous
}

/// What stands between a request and GitHub.
pub type Need {
  /// The person's GitHub connection, to reach `repo` (if known) as them.
  Connect(repo: Option(Repo))
  /// The GitHub App on the account `repo` belongs to.
  Install(repo: Repo)
  /// Nothing anyone can give: a token couldn't be had just now.
  Unavailable(reason: String)
}

pub type Setup {
  Setup(
    store: Store,
    team: String,
    github: Option(GitHub),
    /// Told when a connection lapses, and told of every change.
    connect: Subject(connect.Message),
    /// The Slack user thread `key`'s agent works for, "" for nobody.
    requester: fn(String) -> Result(String, String),
    /// Ask `user`, in thread `key`, for what a request needs.
    ask: fn(String, String, Need) -> Nil,
    /// Thread `key`'s `need` was met: its ask has done its job.
    met: fn(String, Need) -> Nil,
    /// How often an awaited install is looked for.
    install_poll_ms: Int,
  )
}

pub opaque type Broker {
  Broker(subject: Subject(Message), setup: Setup)
}

/// What a request from one thread can get, bound to the person it works
/// for at the time: functions, so the route can be tested without a broker.
pub type Access {
  Access(
    credential: fn(Option(Repo), Purpose) -> Result(Credential, Need),
    /// When GitHub refused a request made with a credential for want of
    /// access, what would help, if anything; else GitHub's answer stands.
    refused: fn(Credential, Option(Repo)) -> Option(Need),
    ask: fn(Need) -> Nil,
    /// Wait up to the given ms for a need to be met.
    await: fn(Need, Int) -> Bool,
  )
}

pub const default_install_poll_ms = 2000

/// How long a token may take, a refresh with GitHub included.
const person_ms = 30_000

type Person =
  Result(Option(#(String, String)), String)

type Waited {
  /// A connection for thread `key`: `user`'s, or a stand-in's.
  ForConnection(key: String, user: String)
  ForInstall(repo: Repo)
}

type Refreshed {
  Fresh(login: String, token: String)
  /// The connection changed meanwhile; look again.
  Moved
  Lapse(why: String, connected_at: Int)
  Trouble(reason: String)
}

type Message {
  PersonOf(user: String, reply: Subject(Person))
  RefreshDone(user: String, outcome: Refreshed)
  RefresherDown(process.Down)
  Wait(waited: Waited, reply: Subject(Nil))
  Unwait(waited: Waited, reply: Subject(Nil))
  Changed(connect.Event)
  InstallSeen(repo: Repo)
  /// `user` pressed Connect on thread `key`'s ask: once connected, the
  /// thread's requests go as them.
  Vouch(key: String, user: String)
  ActingFor(key: String, requester: String, reply: Subject(String))
  Forget(key: String)
}

type State {
  State(
    setup: Setup,
    self: Subject(Message),
    /// Who waits on each person's refresh, and its process.
    refreshing: Dict(String, List(Subject(Person))),
    refreshers: Dict(Pid, String),
    /// Requests awaiting a need, by what they wait on.
    waiters: Dict(String, List(Subject(Nil))),
    /// One process per awaited install, looking for it.
    watchers: Dict(String, Pid),
    /// Who a thread's requests go as instead of its requester, by key.
    stand_ins: Dict(String, String),
    /// Threads each person vouched for, until they are connected.
    vouched: Dict(String, List(String)),
  )
}

pub fn start(setup: Setup) -> Result(Broker, actor.StartError) {
  actor.new_with_initialiser(1000, fn(self) {
    let changes = process.new_subject()
    process.send(setup.connect, connect.Subscribe(changes))
    State(
      setup:,
      self:,
      refreshing: dict.new(),
      refreshers: dict.new(),
      waiters: dict.new(),
      watchers: dict.new(),
      stand_ins: dict.new(),
      vouched: dict.new(),
    )
    |> actor.initialised
    |> actor.selecting(
      process.new_selector()
      |> process.select(self)
      |> process.select_map(changes, Changed)
      |> process.select_monitors(RefresherDown),
    )
    |> actor.returning(Broker(self, setup))
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

/// The credential `requester` (a Slack user, "" for nobody) has for
/// `purpose` on `repo`. `key` names the thread asking, for the log.
pub fn credential(
  broker: Broker,
  key: String,
  requester: String,
  repo: Option(Repo),
  purpose: Purpose,
) -> Result(Credential, Need) {
  use person <- result.try(
    person(broker, requester)
    |> result.map_error(fn(reason) {
      sys.warn("crushling: GitHub for " <> key <> ": " <> reason)
      Unavailable(reason)
    }),
  )
  case person, purpose, repo {
    Some(#(login, token)), _, _ -> Ok(AsPerson(login, token))
    None, Read, Some(repo) ->
      Ok(case app_of(broker) {
        Some(app) ->
          app.token(app, repo) |> option.map(AsApp) |> option.unwrap(Anonymous)
        None -> Anonymous
      })
    None, Read, None -> Ok(Anonymous)
    None, Push, _ | None, OpenPr, _ -> Error(Connect(repo))
  }
}

/// What would help after GitHub refused a request made with `credential`:
/// a connection, unless it was already a person's; then the app, where it
/// isn't installed. None when GitHub's answer is simply so.
pub fn refused(
  broker: Broker,
  credential: Credential,
  repo: Option(Repo),
) -> Option(Need) {
  case credential, repo, app_of(broker) {
    AsPerson(..), Some(repo), Some(app) ->
      case app.installed(app, repo) {
        Ok(False) -> Some(Install(repo))
        _ -> None
      }
    AsPerson(..), _, _ -> None
    _, _, _ -> Some(Connect(repo))
  }
}

/// Wait up to `timeout_ms` for `need` to be met for `requester`: True once
/// it is. Met needs are told by subscription, not looked for.
pub fn await(
  broker: Broker,
  requester: String,
  need: Need,
  timeout_ms: Int,
) -> Bool {
  await_for(broker, "", requester, need, timeout_ms)
}

fn await_for(
  broker: Broker,
  key: String,
  requester: String,
  need: Need,
  timeout_ms: Int,
) -> Bool {
  let waited = case need {
    Connect(_) -> Ok(ForConnection(key, requester))
    Install(repo) -> Ok(ForInstall(repo))
    Unavailable(_) -> Error(Nil)
  }
  case waited {
    Error(Nil) -> False
    Ok(waited) -> {
      let reply = process.new_subject()
      process.send(broker.subject, Wait(waited, reply))
      case process.receive(reply, timeout_ms) {
        Ok(Nil) -> True
        Error(Nil) -> {
          process.send(broker.subject, Unwait(waited, reply))
          False
        }
      }
    }
  }
}

/// Where the app is installed, and how to install it elsewhere.
pub fn accounts(broker: Broker) -> Option(github.Accounts) {
  app_of(broker) |> option.then(app.accounts)
}

/// What thread `key` can get, as the person its agent works for now.
pub fn thread(broker: Broker, key: String) -> Result(Access, String) {
  use requester <- result.map(broker.setup.requester(key))
  Access(
    credential: fn(repo, purpose) {
      credential(broker, key, acting(broker, key, requester), repo, purpose)
    },
    refused: fn(credential, repo) { refused(broker, credential, repo) },
    ask: fn(need) {
      case requester {
        "" -> Nil
        user -> broker.setup.ask(key, user, need)
      }
    },
    await: fn(need, timeout_ms) {
      let met = await_for(broker, key, requester, need, timeout_ms)
      case met {
        True -> broker.setup.met(key, need)
        False -> Nil
      }
      met
    },
  )
}

/// Let `user`, who pressed Connect on thread `key`'s ask, stand in for its
/// requester once they're connected.
pub fn vouch(broker: Broker, key: String, user: String) -> Nil {
  process.send(broker.subject, Vouch(key, user))
}

/// Forget who thread `key` goes as: its agent stopped.
pub fn forget(broker: Broker, key: String) -> Nil {
  process.send(broker.subject, Forget(key))
}

/// Who thread `key`'s requests go as: its stand-in, else `requester`.
fn acting(broker: Broker, key: String, requester: String) -> String {
  let reply = process.new_subject()
  process.send(broker.subject, ActingFor(key, requester, reply))
  process.receive(reply, person_ms) |> result.unwrap(requester)
}

fn app_of(broker: Broker) -> Option(App) {
  broker.setup.github |> option.then(fn(github) { github.app })
}

/// A person's login and current token, None when they haven't connected.
fn person(broker: Broker, user: String) -> Person {
  case user, broker.setup.github {
    "", _ | _, None -> Ok(None)
    user, Some(_) -> {
      let reply = process.new_subject()
      process.send(broker.subject, PersonOf(user, reply))
      process.receive(reply, person_ms)
      |> result.unwrap(Error("GitHub took too long"))
    }
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  actor.continue(case message {
    PersonOf(user, reply) -> person_of(state, user, reply)
    RefreshDone(user, outcome) -> {
      let waiting = dict.get(state.refreshing, user) |> result.unwrap([])
      let state =
        State(..state, refreshing: dict.delete(state.refreshing, user))
      case outcome {
        Fresh(login, token) -> {
          list.each(waiting, process.send(_, Ok(Some(#(login, token)))))
          state
        }
        Trouble(reason) -> {
          list.each(waiting, process.send(_, Error(reason)))
          state
        }
        Lapse(why, connected_at) -> {
          lapse(state, user, why, connected_at)
          list.each(waiting, process.send(_, Ok(None)))
          state
        }
        Moved ->
          list.fold(waiting, state, fn(state, reply) {
            person_of(state, user, reply)
          })
      }
    }
    RefresherDown(process.ProcessDown(pid:, reason:, ..)) ->
      case dict.get(state.refreshers, pid) {
        Error(Nil) -> state
        Ok(user) -> {
          let state =
            State(..state, refreshers: dict.delete(state.refreshers, pid))
          case reason, dict.get(state.refreshing, user) {
            process.Normal, _ | _, Error(Nil) -> state
            _, Ok(waiting) -> {
              sys.warn(
                "crushling: refreshing GitHub for " <> user <> " crashed",
              )
              list.each(waiting, process.send(_, Error("the refresh crashed")))
              State(..state, refreshing: dict.delete(state.refreshing, user))
            }
          }
        }
      }
    RefresherDown(_) -> state
    Wait(waited, reply) -> wait(state, waited, reply)
    Unwait(waited, reply) -> {
      let named = waited_name(waited)
      let left =
        dict.get(state.waiters, named)
        |> result.unwrap([])
        |> list.filter(fn(other) { other != reply })
      settle_waiters(state, named, left)
    }
    Changed(connect.ConnectionChanged(user:, ..)) ->
      case connected(state, user) {
        False -> state
        True -> {
          // Threads they vouched for go as them now.
          let keys = dict.get(state.vouched, user) |> result.unwrap([])
          let state =
            list.fold(
              keys,
              State(..state, vouched: dict.delete(state.vouched, user)),
              fn(state, key) { stand_in(state, key, user) },
            )
          wake_matching(state, fn(waited) {
            case waited {
              ForConnection(user: waiting_on, ..) -> waiting_on == user
              ForInstall(..) -> False
            }
          })
        }
      }
    Vouch(key, user) ->
      case connected(state, user) {
        True -> stand_in(state, key, user)
        False -> {
          let keys = dict.get(state.vouched, user) |> result.unwrap([])
          State(
            ..state,
            vouched: dict.insert(state.vouched, user, [
              key,
              ..list.filter(keys, fn(k) { k != key })
            ]),
          )
        }
      }
    ActingFor(key, requester, reply) -> {
      process.send(
        reply,
        dict.get(state.stand_ins, key) |> result.unwrap(requester),
      )
      state
    }
    Forget(key) ->
      State(
        ..state,
        stand_ins: dict.delete(state.stand_ins, key),
        vouched: dict.map_values(state.vouched, fn(_, keys) {
          list.filter(keys, fn(k) { k != key })
        }),
      )
    InstallSeen(repo) -> {
      let named = waited_name(ForInstall(repo))
      let state = State(..state, watchers: dict.delete(state.watchers, named))
      wake(state, named, dict.get(state.waiters, named) |> result.unwrap([]))
    }
  })
}

fn person_of(state: State, user: String, reply: Subject(Person)) -> State {
  let setup = state.setup
  case dict.get(state.refreshing, user), setup.github {
    Ok(waiting), _ ->
      State(
        ..state,
        refreshing: dict.insert(state.refreshing, user, [reply, ..waiting]),
      )
    _, None -> {
      process.send(reply, Ok(None))
      state
    }
    Error(Nil), Some(github) ->
      case accounts.get(setup.store, setup.team, user) {
        Error(reason) -> {
          process.send(reply, Error(reason))
          state
        }
        Ok(None) -> {
          process.send(reply, Ok(None))
          state
        }
        Ok(Some(account)) -> {
          let now = sys.now()
          case
            github.stale(account.tokens, now),
            github.lapsed(account.tokens, now)
          {
            False, _ -> {
              process.send(
                reply,
                Ok(Some(#(account.login, account.tokens.access))),
              )
              state
            }
            True, True -> {
              lapse(state, user, "it expired", account.connected_at)
              process.send(reply, Ok(None))
              state
            }
            True, False -> {
              let refresher = refresh(state, github.config, account)
              let _ = process.monitor(refresher)
              State(
                ..state,
                refreshing: dict.insert(state.refreshing, user, [reply]),
                refreshers: dict.insert(state.refreshers, refresher, user),
              )
            }
          }
        }
      }
  }
}

/// Refresh off the actor; the store only takes the new tokens if the
/// connection is still the one they came from.
fn refresh(
  state: State,
  config: github.Config,
  account: accounts.Account,
) -> Pid {
  let State(setup:, self:, ..) = state
  process.spawn_unlinked(fn() {
    let outcome = case github.refresh(config, account.tokens, sys.now()) {
      Ok(tokens) -> saved(setup, account, tokens)
      Error(github.Refused(reason)) -> Lapse(reason, account.connected_at)
      Error(github.Unreachable(reason)) -> Trouble(reason)
    }
    process.send(self, RefreshDone(account.user, outcome))
  })
}

fn saved(setup: Setup, account: accounts.Account, tokens: Tokens) -> Refreshed {
  case
    accounts.replace_tokens(
      setup.store,
      setup.team,
      account.user,
      account.connected_at,
      tokens,
    )
  {
    Ok(True) -> Fresh(account.login, tokens.access)
    Ok(False) -> Moved
    Error(reason) -> Trouble(reason)
  }
}

/// Forget a connection GitHub no longer honours, and have the Home say so.
fn lapse(state: State, user: String, why: String, connected_at: Int) -> Nil {
  sys.warn("crushling: GitHub connection of " <> user <> " lapsed: " <> why)
  let setup = state.setup
  case accounts.delete_connection(setup.store, setup.team, user, connected_at) {
    Ok(Nil) -> Nil
    Error(reason) ->
      sys.warn(
        "crushling: forgetting the lapsed GitHub connection of "
        <> user
        <> ": "
        <> reason,
      )
  }
  process.send(setup.connect, connect.Lapsed(user))
}

fn connected(state: State, user: String) -> Bool {
  case accounts.get(state.setup.store, state.setup.team, user) {
    Ok(Some(_)) -> True
    _ -> False
  }
}

fn waited_name(waited: Waited) -> String {
  case waited {
    ForConnection(key:, user:) -> "connect:" <> key <> ":" <> user
    ForInstall(repo) -> "install:" <> repo.key(repo)
  }
}

fn wait(state: State, waited: Waited, reply: Subject(Nil)) -> State {
  let named = waited_name(waited)
  let waiting = dict.get(state.waiters, named) |> result.unwrap([])
  case waited {
    // Connected between being refused and waiting, or someone stood in:
    // nothing to wait for.
    ForConnection(key:, user:) ->
      case connected(state, user) || dict.has_key(state.stand_ins, key) {
        True -> {
          process.send(reply, Nil)
          state
        }
        False ->
          State(
            ..state,
            waiters: dict.insert(state.waiters, named, [reply, ..waiting]),
          )
      }
    ForInstall(repo) -> {
      let watchers = case dict.get(state.watchers, named), app_of_setup(state) {
        Ok(_), _ | _, None -> state.watchers
        Error(Nil), Some(app) ->
          dict.insert(
            state.watchers,
            named,
            watch(app, repo, state.self, state.setup.install_poll_ms),
          )
      }
      State(
        ..state,
        watchers:,
        waiters: dict.insert(state.waiters, named, [reply, ..waiting]),
      )
    }
  }
}

fn app_of_setup(state: State) -> Option(App) {
  state.setup.github |> option.then(fn(github) { github.app })
}

/// Look for an install every `every_ms`; there's no hook to say so.
fn watch(app: App, repo: Repo, broker: Subject(Message), every_ms: Int) -> Pid {
  process.spawn_unlinked(fn() { watching(app, repo, broker, every_ms) })
}

fn watching(app: App, repo: Repo, broker: Subject(Message), every_ms: Int) {
  process.sleep(every_ms)
  case app.installed(app, repo) {
    Ok(True) -> process.send(broker, InstallSeen(repo))
    _ -> watching(app, repo, broker, every_ms)
  }
}

fn wake(state: State, named: String, waiting: List(Subject(Nil))) -> State {
  list.each(waiting, process.send(_, Nil))
  settle_waiters(state, named, [])
}

/// Keep who still waits on `named`; with nobody left, stop looking.
fn settle_waiters(
  state: State,
  named: String,
  left: List(Subject(Nil)),
) -> State {
  case left {
    [] -> {
      case dict.get(state.watchers, named) {
        Ok(watcher) -> process.kill(watcher)
        Error(Nil) -> Nil
      }
      State(
        ..state,
        waiters: dict.delete(state.waiters, named),
        watchers: dict.delete(state.watchers, named),
      )
    }
    left -> State(..state, waiters: dict.insert(state.waiters, named, left))
  }
}

/// Thread `key`'s requests go as `user` from now on; whoever waited on a
/// connection for it goes ahead.
fn stand_in(state: State, key: String, user: String) -> State {
  let state = State(..state, stand_ins: dict.insert(state.stand_ins, key, user))
  wake_matching(state, fn(waited) {
    case waited {
      ForConnection(key: waiting_for, ..) -> waiting_for == key
      ForInstall(..) -> False
    }
  })
}

/// Wake everyone whose wait `matches`.
fn wake_matching(state: State, matches: fn(Waited) -> Bool) -> State {
  dict.fold(state.waiters, state, fn(state, named, waiting) {
    case parse_waited(named) {
      Ok(waited) ->
        case matches(waited) {
          True -> wake(state, named, waiting)
          False -> state
        }
      Error(Nil) -> state
    }
  })
}

/// A connection wait from its name; installs aren't woken this way.
fn parse_waited(named: String) -> Result(Waited, Nil) {
  case named {
    "connect:" <> rest -> {
      use #(key, user) <- result.map(split_last(rest, ":"))
      ForConnection(key:, user:)
    }
    _ -> Error(Nil)
  }
}

fn split_last(text: String, on: String) -> Result(#(String, String), Nil) {
  case string.split(text, on) |> list.reverse {
    [last, ..rest] if rest != [] ->
      Ok(#(string.join(list.reverse(rest), on), last))
    _ -> Error(Nil)
  }
}
