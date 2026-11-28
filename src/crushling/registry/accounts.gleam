//// People's GitHub accounts and App Homes, as the registry sees them:
//// what their Home shows, PR card presses that open PRs as them, nudges to
//// connect, and who a thread's agent works for.

import crushling/conversation.{Conversation}
import crushling/github/broker
import crushling/github/connect
import crushling/github/nudge
import crushling/github/repo
import crushling/home/publisher
import crushling/pr
import crushling/registry/core.{type State, GitHubAskPosted, PrSettled, State}
import crushling/registry/entry.{Entry, Live}
import crushling/registry/text
import crushling/slack/workspace
import crushling/thread
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set

/// How long the thread may take to say whose it is.
pub const requester_ms = 5000

/// What someone asked of the App Home or `!github`.
pub type HomeAsk {
  ShowHome
  Connect(from: Option(connect.Place))
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
      process.send(state.connect, connect.Connect(user, from))
    Connect(from: Some(connect.Place(channel:, thread_ts:, ..))), False ->
      core.tell_privately(
        state,
        conversation.from_slack(channel, thread_ts),
        user,
        text.cant_use,
      )
    _, _ -> Nil
  }
  // Either way their Home shows where they stand.
  process.send(
    state.home,
    publisher.Show(user, case allowed {
      True -> Some(threads_of(state, user))
      False -> None
    }),
  )
  state
}

/// What a press on a PR card answers with, privately, through `respond`.
pub fn responder(
  state: State(msg),
  respond: Option(String),
) -> fn(String) -> Nil {
  let workspace = state.config.workspace
  fn(text) {
    case respond {
      Some(url) -> workspace.respond_later(workspace, url, text, False)
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
    Some(github) -> {
      let workspace = state.config.workspace
      case choice {
        // Nothing to remember a dismissed card by: it goes.
        "dismiss" -> {
          workspace.delete_later(workspace, channel, card_ts)
          State(..state, proposals: dict.delete(state.proposals, card_ts))
        }
        _ -> {
          let broker = state.broker
          let draft = choice == "draft"
          let tell = core.teller(state)
          process.spawn_unlinked(fn() {
            let credential =
              broker.credential(
                broker,
                card_ts,
                user,
                Some(proposal.repo),
                broker.OpenPr,
              )
            case credential {
              Ok(broker.AsPerson(token:, ..)) ->
                case pr.open(github.config, token, proposal, draft) {
                  Ok(#(number, url)) -> {
                    let #(text, blocks) =
                      pr.opened(proposal, user, url, number, draft)
                    workspace.update_later(
                      workspace,
                      channel,
                      card_ts,
                      workspace.Message(text, blocks),
                    )
                    tell(PrSettled(card_ts))
                  }
                  Error(why) -> say(text.could_not_open_pr(why))
                }
              Error(broker.Unavailable(_)) -> say(text.no_connection)
              _ -> say(text.connect_first)
            }
          })
          state
        }
      }
    }
  }
}

/// Ask in thread `key`, publicly, for what its GitHub request needs: one
/// card per need, which anyone who may use crushling can press, and which
/// goes once the need is met. `user` is whose request it was.
pub fn nudge(
  state: State(msg),
  key: String,
  _user: String,
  need: broker.Need,
) -> State(msg) {
  case need_name(need), dict.get(state.threads, key) {
    Ok(name), Ok(entry) ->
      case dict.has_key(state.asks, #(key, name)) {
        True -> state
        False -> {
          let workspace = state.config.workspace
          let broker = state.broker
          let tell = core.teller(state)
          let #(channel, thread_ts) = #(entry.channel, entry.thread_ts)
          process.spawn_unlinked(fn() {
            let ask = case need {
              broker.Connect(repo:) ->
                Some(nudge.ask_connect(channel, thread_ts, repo))
              broker.Install(repo:) ->
                broker.accounts(broker)
                |> option.map(fn(accounts) {
                  nudge.ask_install(repo, accounts.install_url)
                })
              broker.Unavailable(..) -> None
            }
            let posted = case ask {
              Some(#(text, blocks)) ->
                workspace.post(
                  workspace,
                  Conversation(channel, Some(thread_ts)),
                  workspace.Message(text, blocks),
                )
                |> result.unwrap("")
              None -> ""
            }
            tell(GitHubAskPosted(key, name, channel, posted))
          })
          State(
            ..state,
            asks: dict.insert(state.asks, #(key, name), #(channel, "")),
          )
        }
      }
    _, _ -> state
  }
}

/// A thread's ask went up as `ts` ("" if it couldn't): remember it, or
/// forget it so the next request asks again.
pub fn ask_posted(
  state: State(msg),
  key: String,
  name: String,
  channel: String,
  ts: String,
) -> State(msg) {
  case ts, dict.get(state.asks, #(key, name)) {
    "", _ -> State(..state, asks: dict.delete(state.asks, #(key, name)))
    _, Ok(_) ->
      State(
        ..state,
        asks: dict.insert(state.asks, #(key, name), #(channel, ts)),
      )
    // Met while it posted: it has nothing left to ask.
    _, Error(Nil) -> {
      workspace.delete_later(state.config.workspace, channel, ts)
      state
    }
  }
}

/// Thread `key`'s `need` was met: its card goes. A connection met by a
/// stand-in also clears the thread's install asks it no longer blocks on.
pub fn ask_met(
  state: State(msg),
  key: String,
  need: broker.Need,
) -> State(msg) {
  case need_name(need) {
    Ok(name) -> clear_ask(state, key, name)
    Error(Nil) -> state
  }
}

/// Every ask thread `key` has up goes: its agent stopped.
pub fn clear_asks(state: State(msg), key: String) -> State(msg) {
  dict.keys(state.asks)
  |> list.filter(fn(asked) { asked.0 == key })
  |> list.fold(state, fn(state, asked) { clear_ask(state, key, asked.1) })
}

fn clear_ask(state: State(msg), key: String, name: String) -> State(msg) {
  case dict.get(state.asks, #(key, name)) {
    Ok(#(channel, ts)) if ts != "" ->
      workspace.delete_later(state.config.workspace, channel, ts)
    _ -> Nil
  }
  State(..state, asks: dict.delete(state.asks, #(key, name)))
}

fn need_name(need: broker.Need) -> Result(String, Nil) {
  case need {
    broker.Connect(..) -> Ok("connect")
    broker.Install(repo:) -> Ok("install:" <> repo.key(repo))
    broker.Unavailable(..) -> Error(Nil)
  }
}

/// Who thread `key`'s agent works for, "" for nobody; answered off the
/// registry, since asking the thread may be slow.
pub fn requester(
  state: State(msg),
  key: String,
  reply: Subject(Result(String, String)),
) -> Nil {
  case dict.get(state.threads, key) {
    Ok(Entry(agent: Live(thread:, ..), ..)) -> {
      process.spawn_unlinked(fn() {
        // Sent and received rather than called, so a gone thread is a timeout, not a crash.
        let asked = process.new_subject()
        process.send(thread, thread.Requester(asked))
        process.send(
          reply,
          process.receive(asked, requester_ms)
            |> result.replace_error("the thread didn't say whose it is"),
        )
      })
      Nil
    }
    _ -> process.send(reply, Ok(""))
  }
}

/// `user`'s threads with a running agent: ones they've sent a prompt in.
fn threads_of(state: State(msg), user: String) -> List(publisher.Thread) {
  dict.to_list(state.threads)
  |> list.filter_map(fn(pair) {
    let #(key, entry) = pair
    case entry.agent, set.contains(entry.people, user) {
      Live(..), True ->
        Ok(
          publisher.Thread(
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
