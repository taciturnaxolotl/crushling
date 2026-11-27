//// People's GitHub accounts and App Homes, as the registry sees them:
//// what their Home shows, PR card presses that open PRs as them, nudges to
//// connect, and the token an agent reads GitHub with.

import crushling/connections
import crushling/conversation.{Conversation}
import crushling/github/route as github_route
import crushling/home
import crushling/pr
import crushling/registry/core.{type State, GitHubNudgeTo, PrSettled, State}
import crushling/registry/entry.{Entry, Live}
import crushling/registry/say
import crushling/registry/text
import crushling/slack
import crushling/sys
import crushling/thread
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import slackline/api/chat
import slackline/api/chat/update
import slackline/httpc

/// Asked to connect GitHub at most this often per person and thread.
const nudge_every_ms = 600_000

/// How long a token may take, a refresh with GitHub included.
pub const github_access_ms = 30_000

/// What someone asked of the App Home or `!github`.
pub type HomeAsk {
  ShowHome
  Connect(from: Option(connections.Place))
}

/// Do what `user` asked of their Home, and show it, with their threads if they may use crushling.
pub fn show_home(
  state: State(msg),
  user: String,
  ask: HomeAsk,
  allowed: Bool,
) -> State(msg) {
  case ask, allowed {
    Connect(from:), True ->
      process.send(state.connections, connections.Connect(user, from))
    Connect(from: Some(connections.Place(channel:, thread_ts:, ..))), False ->
      say.privately(
        state.config.client,
        conversation.from_slack(channel, thread_ts),
        user,
        text.cant_use,
      )
    _, _ -> Nil
  }
  // Either way their Home shows where they stand.
  process.send(
    state.connections,
    connections.Show(user, case allowed {
      True -> Some(threads_of(state, user))
      False -> None
    }),
  )
  state
}

/// What a press on a PR card answers with, privately, through `respond`.
pub fn responder(respond: Option(String)) -> fn(String) -> Nil {
  fn(text) {
    case respond {
      Some(url) -> {
        process.spawn_unlinked(fn() { slack.reply_ephemeral(url, text) })
        Nil
      }
      None -> Nil
    }
  }
}

/// The PR card pressed: its channel and proposal, or say it has expired.
pub fn with_proposal(
  state: State(msg),
  card_ts: String,
  say: fn(String) -> Nil,
  next: fn(#(String, pr.Proposal)) -> State(msg),
) -> State(msg) {
  case dict.get(state.proposals, card_ts) {
    Ok(found) -> next(found)
    Error(Nil) -> {
      say(text.card_expired)
      state
    }
  }
}

/// Open the PR as the presser, with their GitHub connection, or dismiss it.
pub fn press(
  state: State(msg),
  user: String,
  card_ts: String,
  choice: String,
  card: #(String, pr.Proposal),
  say: fn(String) -> Nil,
) -> State(msg) {
  let #(channel, proposal) = card
  case state.config.github {
    None -> {
      say(text.github_not_set_up)
      state
    }
    Some(config) -> {
      let client = state.config.client
      let settle = fn(outcome) {
        let #(text, blocks) = pr.settled(proposal, outcome)
        let _ =
          chat.update(channel:, ts: card_ts)
          |> update.text(text)
          |> update.blocks(blocks)
          |> httpc.send(client)
        Nil
      }
      case choice {
        "dismiss" -> {
          process.spawn_unlinked(fn() { settle(text.pr_dismissed(user)) })
          State(..state, proposals: dict.delete(state.proposals, card_ts))
        }
        _ -> {
          let connections = state.connections
          let draft = choice == "draft"
          let tell = core.teller(state)
          process.spawn_unlinked(fn() {
            let asked = process.new_subject()
            process.send(connections, connections.Access(user, asked))
            case process.receive(asked, github_access_ms) {
              Ok(Ok(Some(token))) ->
                case pr.open(config, token, proposal, draft) {
                  Ok(#(number, url)) -> {
                    settle(text.pr_opened(user, url, number, draft))
                    tell(PrSettled(card_ts))
                  }
                  Error(why) -> say(text.could_not_open_pr(why))
                }
              Ok(Ok(None)) -> say(text.connect_first)
              _ -> say(text.no_connection)
            }
          })
          state
        }
      }
    }
  }
}

/// Find out, off the registry, whose agent it is.
pub fn nudge_who(
  state: State(msg),
  key: String,
  want: github_route.Want,
) -> Nil {
  case dict.get(state.threads, key) {
    Ok(Entry(agent: Live(thread:, ..), ..)) -> {
      let tell = core.teller(state)
      process.spawn_unlinked(fn() {
        let asked = process.new_subject()
        process.send(thread, thread.Requester(asked))
        case process.receive(asked, 5000) {
          Ok("") | Error(Nil) -> Nil
          Ok(user) -> tell(GitHubNudgeTo(key, user, want))
        }
      })
      Nil
    }
    _ -> Nil
  }
}

/// Ask `user` to connect GitHub or install the App, at most every `nudge_every_ms` per thread and want.
pub fn nudge(
  state: State(msg),
  key: String,
  user: String,
  want: github_route.Want,
) -> State(msg) {
  let now = sys.monotonic_ms()
  // A connect and then an install are both asked.
  let asked = #(key, user, case want {
    github_route.Connection(..) -> "connect"
    github_route.Install(owner:, ..) -> "install:" <> string.lowercase(owner)
  })
  let recently = case dict.get(state.nudged, asked) {
    Ok(at) -> now - at < nudge_every_ms
    Error(Nil) -> False
  }
  case recently, dict.get(state.threads, key) {
    False, Ok(entry) -> {
      let client = state.config.client
      let github = state.config.github
      let #(channel, thread_ts) = #(entry.channel, entry.thread_ts)
      process.spawn_unlinked(fn() {
        let ask = case want {
          github_route.Connection(repo:) ->
            Some(home.ask_connect(channel, thread_ts, repo))
          github_route.Install(owner:, repo:) ->
            github
            |> option.then(fn(config) { config.accounts() })
            |> option.map(fn(accounts) {
              home.ask_install(owner, repo, accounts.install_url)
            })
        }
        case ask {
          Some(#(text, blocks)) ->
            slack.whisper_blocks(
              client,
              Conversation(channel, Some(thread_ts)),
              user,
              text,
              blocks,
            )
          None -> Nil
        }
      })
      let nudged =
        dict.filter(state.nudged, fn(_, at) { now - at < nudge_every_ms })
        |> dict.insert(asked, now)
      State(..state, nudged:)
    }
    _, _ -> state
  }
}

/// Answered off the registry, since asking the thread and connections (which may refresh) is slow.
pub fn github_access(
  state: State(msg),
  key: String,
  reply: Subject(Result(Option(String), String)),
) -> Nil {
  case dict.get(state.threads, key) {
    Ok(Entry(agent: Live(thread:, ..), ..)) -> {
      let connections = state.connections
      process.spawn_unlinked(fn() {
        process.send(reply, {
          // Sent and received rather than called, so a gone thread or actor is a timeout, not a crash.
          let asked = process.new_subject()
          process.send(thread, thread.Requester(asked))
          case process.receive(asked, 5000) {
            Error(Nil) -> Error("the thread didn't say whose it is")
            Ok("") -> Ok(None)
            Ok(user) -> {
              let answer = process.new_subject()
              process.send(connections, connections.Access(user, answer))
              process.receive(answer, github_access_ms)
              |> result.unwrap(Error("GitHub took too long"))
            }
          }
        })
      })
      Nil
    }
    _ -> process.send(reply, Ok(None))
  }
}

/// `user`'s threads with a running agent: ones they've sent a prompt in.
fn threads_of(state: State(msg), user: String) -> List(connections.Thread) {
  dict.to_list(state.threads)
  |> list.filter_map(fn(pair) {
    let #(key, entry) = pair
    case entry.agent, set.contains(entry.people, user) {
      Live(..), True ->
        Ok(
          connections.Thread(
            key:,
            channel: entry.channel,
            thread_ts: entry.thread_ts,
            model: case entry.meta.model {
              Some(choice) -> choice.model
              None -> state.config.default_model
            },
          ),
        )
      _, _ -> Error(Nil)
    }
  })
}
