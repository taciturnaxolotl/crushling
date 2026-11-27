//// Draws and publishes one workspace's App Homes, in the order asked, so an
//// older view never covers a newer one. A Home is drawn when its person
//// opens it, and again whenever their GitHub connection changes.

import crushling/github
import crushling/github/connect
import crushling/home
import crushling/slack/workspace.{type Workspace}
import crushling/store.{type Store}
import crushling/store/github as accounts
import crushling/store/usage
import crushling/sys
import crushling/usage as spend
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
    workspace: Workspace,
    store: Store,
    /// Whether people can connect GitHub here at all.
    github: Bool,
    /// Where the GitHub App is installed, asked when a Home shows a
    /// connection.
    accounts: fn() -> Option(github.Accounts),
    default_model: String,
  )
}

/// A thread of someone's whose agent is running, as the registry knows it.
pub type Thread {
  Thread(key: String, channel: String, thread_ts: String, model: String)
}

pub type Message {
  /// Draw `user`'s Home. `threads` is None for someone who may not use
  /// crushling.
  Show(user: String, threads: Option(List(Thread)))
  Changed(connect.Event)
}

type State {
  State(
    setup: Setup,
    /// Each person's threads as of their last `Show`, for drawing their Home
    /// again after a connection changes.
    threads: Dict(String, Option(List(Thread))),
    statuses: Dict(String, connect.Status),
  )
}

/// Start the publisher, drawing again on every change `connect` tells of.
pub fn start(
  setup: Setup,
  connect: Subject(connect.Message),
) -> Result(Subject(Message), actor.StartError) {
  actor.new_with_initialiser(1000, fn(self) {
    let changes = process.new_subject()
    process.send(connect, connect.Subscribe(changes))
    State(setup:, threads: dict.new(), statuses: dict.new())
    |> actor.initialised
    |> actor.selecting(
      process.new_selector()
      |> process.select(self)
      |> process.select_map(changes, Changed),
    )
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(fn(state, message) {
    actor.continue(case message {
      Show(user, threads) -> {
        let state =
          State(..state, threads: dict.insert(state.threads, user, threads))
        publish(state, user, None)
        state
      }
      Changed(connect.ConnectionChanged(user:, status:, note:)) -> {
        let state =
          State(..state, statuses: dict.insert(state.statuses, user, status))
        publish(state, user, note)
        state
      }
    })
  })
  |> actor.start
  |> result.map(fn(started) { started.data })
}

fn publish(state: State, user: String, note: Option(String)) -> Nil {
  let setup = state.setup
  let threads = dict.get(state.threads, user) |> result.unwrap(Some([]))
  let status = dict.get(state.statuses, user) |> result.unwrap(connect.Idle)
  let view =
    home.view(draw(setup, threads, github_of(setup, user, status, note)))
  case
    views.publish(user_id: user, view:)
    |> httpc.send(workspace.client(setup.workspace))
  {
    Ok(_) -> Nil
    Error(error) ->
      sys.warn(
        "crushling: publishing the Home for "
        <> user
        <> ": "
        <> slackline.describe_error(error),
      )
  }
}

fn github_of(
  setup: Setup,
  user: String,
  status: connect.Status,
  note: Option(String),
) -> home.GitHub {
  case setup.github, status {
    False, _ -> home.Unavailable
    True, connect.Asking -> home.Asking
    True, connect.ShowingCode(code:, url:, until:) ->
      home.Connecting(code:, url:, minutes: { until - sys.now() + 59 } / 60)
    True, connect.Idle ->
      case accounts.get(setup.store, workspace.team(setup.workspace), user) {
        Ok(Some(account)) ->
          home.Connected(
            login: account.login,
            note:,
            accounts: setup.accounts(),
          )
        Ok(None) -> home.NotConnected(note:)
        Error(reason) -> {
          sys.warn("crushling: reading GitHub for " <> user <> ": " <> reason)
          home.NotConnected(note: Some("Couldn't read your connection."))
        }
      }
  }
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
        usage.team_total(setup.store, workspace.team(setup.workspace), since)
        |> or_zero("the workspace's spend")
      }
      home.Home(
        github:,
        threads: list.take(threads, home.max_threads)
          |> list.map(fn(thread) {
            home.Thread(
              channel: thread.channel,
              link: permalink(setup, thread),
              model: thread.model,
              spent: usage.thread_total(setup.store, thread.key, usage.Ever)
                |> or_zero("the spend of " <> thread.key),
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

fn permalink(setup: Setup, thread: Thread) -> Option(String) {
  case
    chat.get_permalink(channel: thread.channel, message_ts: thread.thread_ts)
    |> httpc.send(workspace.client(setup.workspace))
  {
    Ok(found) -> Some(found.permalink)
    Error(error) -> {
      sys.warn(
        "crushling: linking "
        <> thread.key
        <> " on the Home: "
        <> slackline.describe_error(error),
      )
      None
    }
  }
}

/// Spend shown as nothing rather than not at all, said in the log.
fn or_zero(found: Result(spend.Usage, String), what: String) -> spend.Usage {
  case found {
    Ok(usage) -> usage
    Error(reason) -> {
      sys.warn("crushling: reading " <> what <> " for the Home: " <> reason)
      spend.zero
    }
  }
}
