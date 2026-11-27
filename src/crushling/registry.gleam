//// Routes Slack messages to thread actors.
////
//// A mention starts a thread: the launcher brings up its agent and a
//// `thread` actor drives it. A thread started by a mention in its first
//// message (or in a DM) follows along, so every reply is a prompt; one
//// joined partway through only answers when mentioned. Each prompt is
//// prepared in order before it reaches the agent: what was said in the
//// thread since the agent last looked, and any attached files, kept on
//// the bridge for the agent to fetch. `!stop` (or Slack's Stop) cancels
//// the current run.
////
//// A thread with nothing running for `idle_ms` has its agent stopped; its
//// workspace, session and `meta` (in the store) stay, so the next message,
//// even after a restart, picks the conversation up again.
////
//// One registry serves one Slack workspace (`Config.team`), and its thread
//// keys carry the team (`sandbox.key`). A thread from before keys did,
//// under its old `channel-ts` key, is moved to its new key the first time
//// it is looked up (`migrate_legacy`).
////
//// A thread's launch and stop never overlap: while its agent is stopping
//// the entry stays, `Stopping`, and messages wait in its backlog until the
//// stop has finished and the agent can start again. Shutdown waits for
//// launches in flight and stops what they started.

import crushling/connections
import crushling/crush/client
import crushling/github
import crushling/github/route as github_route
import crushling/home
import crushling/launcher.{type Launcher}
import crushling/meta.{type Link, type Meta, Link, Meta}
import crushling/models
import crushling/people.{type People}
import crushling/pr
import crushling/registry/entry.{
  type Entry, Entry, Live, Starting, Stopping, already_read, has_waiting,
  is_quiet, new as new_entry, tailnet_view,
}
import crushling/registry/incoming.{type Incoming, Incoming, is_dm}
import crushling/registry/links.{type Links}
import crushling/registry/prompt
import crushling/registry/sweep
import crushling/registry/tailnet
import crushling/sandbox
import crushling/slack
import crushling/store.{type Store}
import crushling/sys
import crushling/thread
import crushling/venue
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import gleam/string
import slackline
import slackline/api/chat
import slackline/api/chat/update
import slackline/httpc

pub type Config {
  Config(
    launcher: Launcher,
    client: slackline.Client,
    /// The bot token, for downloading attachments.
    token: String,
    /// The bot's own user id, so mentions of it can be stripped.
    bot_user: String,
    /// The workspace's id.
    team: String,
    /// Who may drive agents: listed Slack user ids, and maybe every
    /// member of the workspace.
    allowed: People,
    /// Slack user ids who may approve tailnet access; when empty, the ids
    /// allowed may (nobody, when everyone is allowed).
    admins: Set(String),
    /// Where thread meta and code-channel links are kept.
    store: Store,
    /// Whether threads from before keys carried the workspace may be
    /// moved to their new key: only for the workspace the bridge served
    /// then, the one of `SLACK_BOT_TOKEN`.
    migrate_legacy: Bool,
    idle_ms: Int,
    flush_ms: Int,
    mode: client.PermissionMode,
    /// How to put sandboxes on the tailnet, if anyone may.
    tailnet: Option(tailnet.Setup),
    /// How long to wait before each retry of a stop that failed; once they
    /// are used up the registry gives up on that agent.
    stop_backoff_ms: List(Int),
    /// The instance root: each thread's attachments are kept under
    /// `<root>/<key>/files`.
    root: String,
    /// The GitHub App people connect their accounts through, if set up.
    github: Option(github.Config),
    /// The model agents start on, for the App Home.
    default_model: String,
  )
}

/// Retries of a failed stop: after 1, 5 and 15 seconds.
pub const default_stop_backoff_ms = [1000, 5000, 15_000]

/// How shutdown went.
pub type ShutdownOutcome {
  /// Every agent was stopped.
  Clean
  /// Launches or stops were still in flight when the time ran out.
  TimedOut
  /// The launcher couldn't stop these threads' agents.
  Incomplete(failed: List(String))
}

pub type Message {
  Received(Incoming)
  /// A message that waits while a code channel opens, because it may be the
  /// copy of the request that Slack posts in the new channel. `attempts` counts
  /// how often it was tried.
  Deferred(incoming: Incoming, attempts: Int)
  /// Someone pressed Slack's stop control on the thread's session.
  StopRequested(channel: String, thread_ts: String, user: String)
  Started(
    key: String,
    generation: Int,
    result: Result(Subject(thread.Message), String),
  )
  /// The launcher has finished stopping the agent for `key`.
  Stopped(key: String, result: Result(Nil, String))
  /// Try a failed stop again.
  RetryStop(key: String)
  /// A prompt is ready to send: `ts` is the message it came from.
  Prepared(key: String, ts: String, prompt: thread.Message)
  /// A notice from the thread actor for `key`.
  FromThread(key: String, notice: thread.Notice)
  /// Stop taking messages, let running turns finish for up to `grace_ms`,
  /// cancel what is left, stop every agent, then reply.
  /// The whole of it takes at most `shutdown_budget_ms(grace_ms)`.
  Shutdown(grace_ms: Int, reply: Subject(ShutdownOutcome))
  /// The grace period is over.
  ShutdownDeadline
  /// Cancelled turns have had their chance to wind down.
  ShutdownFinal
  /// Launches and stops in flight at shutdown took too long.
  ShutdownGiveUp
  IdleCheck(key: String, generation: Int)
  ThreadDown(process.Down)
  /// Something about tailnet access for the thread `key`.
  Tailnet(key: String, event: tailnet.Event)
  /// The thread actor for `key`, if its agent is up: for the agent's own
  /// Slack tools.
  Lookup(key: String, reply: Subject(Option(Subject(thread.Message))))
  /// Whether `user` is a member of the workspace, from lookup `id`.
  Member(user: String, id: Int, result: Result(Bool, String))
  /// `user` opened the App Home.
  HomeOpened(user: String)
  /// Connect or disconnect `user`'s GitHub account, from the App Home.
  GitHubConnect(user: String)
  GitHubDisconnect(user: String)
  /// Someone pressed a PR card's button: open it (as a draft or not), or
  /// dismiss it. `respond` answers them privately.
  PrPressed(
    user: String,
    card_ts: String,
    choice: String,
    respond: Option(String),
  )
  /// Archive quiet code channels and clear out long-quiet workspaces;
  /// hourly.
  Sweep
  /// A PR card was opened; forget it.
  PrSettled(card_ts: String)
  /// A slash command in a code channel, as the `!` command `text` from
  /// `user`. Answered there, privately where it says anything.
  Slash(channel: String, user: String, text: String)
  /// `user` pressed Connect on the note asking them, in a thread.
  GitHubConnectIn(user: String, place: connections.Place)
  /// Thread `key`'s agent couldn't read GitHub for want of a connection:
  /// ask whoever it works for, in the thread, now and then.
  GitHubNudge(key: String, want: github_route.Want)
  /// Who to ask, for `GitHubNudge`.
  GitHubNudgeTo(key: String, user: String, want: github_route.Want)
  /// The GitHub access token the agent of thread `key` reads with: that of
  /// whoever it's working for. None when they haven't connected, or the
  /// thread has no agent running.
  GitHubAccess(key: String, reply: Subject(Result(Option(String), String)))
  /// The thread didn't count its jobs for the idle check of `generation` in
  /// time.
  JobsUncounted(key: String, generation: Int)
  /// Someone picked on a thread's model card. `home` is the thread's
  /// channel and ts; the card may be elsewhere, such as at the top of a
  /// code channel.
  ModelPicked(
    home: #(String, String),
    pick: models.Pick,
    card: meta.Card,
    user: String,
  )
}

/// Something from a user whose membership is being looked up, waiting for
/// the answer.
type Waiting {
  WaitingMessage(Incoming)
  WaitingStop(channel: String, thread_ts: String, user: String)
  WaitingHome(user: String, ask: HomeAsk)
  WaitingPick(
    home: #(String, String),
    pick: models.Pick,
    card: meta.Card,
    user: String,
  )
}

type State {
  State(
    config: Config,
    self: Subject(Message),
    threads: Dict(String, Entry),
    /// Links from code channels to their threads.
    code_channels: Links,
    /// Threads that are opening a code channel now. Until they finish, a
    /// message from an unknown channel may be the copy of a request in a new
    /// channel.
    opening: Set(String),
    /// Recently handled message ids, so a redelivery is not run twice.
    seen: List(String),
    generation: Int,
    /// Set once shutdown begins: who to tell when it is done.
    stopping: Option(Subject(ShutdownOutcome)),
    /// Set once shutdown is stopping agents: it ends when no thread is
    /// left starting, running or stopping.
    finishing: Bool,
    /// Threads whose agent the launcher couldn't stop, even with retries.
    failed_stops: List(String),
    /// Threads under their old key that couldn't be moved, and were said
    /// to be.
    broken: Set(String),
    tailnets: tailnet.Tailnets,
    /// Who is a member of the workspace, as far as users.info said lately.
    members: people.Cache,
    /// Lookups in flight, by user: the lookup's id and what waits for it,
    /// oldest first.
    looking_up: Dict(String, #(Int, List(Waiting))),
    /// The workspace's GitHub connections and App Homes.
    connections: Subject(connections.Message),
    /// When each person was last asked to connect GitHub in each thread,
    /// by thread and user, in monotonic ms.
    nudged: Dict(#(String, String, String), Int),
    /// PR cards waiting for a press, by their message ts: in which channel,
    /// and what they propose. Lost on restart; `/pr` posts a new one.
    proposals: Dict(String, #(String, pr.Proposal)),
  )
}

/// Asked to connect GitHub at most this often per person and thread.
const nudge_every_ms = 600_000

/// How long a membership lookup gets before what waits for it is turned
/// away.
const member_timeout_ms = 15_000

/// After cancelling, how long turns get to post their closing note.
const cancel_wait_ms = 10_000

const restart_note =
  "crushling restarted, so this run was stopped. Send a follow-up to carry on."

const seen_limit = 1000

/// How long a held-back message waits before it is tried again, and the most
/// tries it gets.
const defer_ms = 250

const defer_attempts = 40

pub fn start(config: Config) -> Result(Subject(Message), actor.StartError) {
  actor.new_with_initialiser(1000, fn(self) {
    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select_monitors(ThreadDown)
    // The first sweep a minute in, once the bridge has settled.
    process.send_after(self, 60_000, Sweep)
    // Linked: it goes down with the registry, and comes back with it.
    use connections <- result.try(
      connections.start(connections.Setup(
        client: config.client,
        store: config.store,
        team: config.team,
        github: config.github,
        default_model: config.default_model,
      ))
      |> result.replace_error("the App Home could not start"),
    )
    State(
      config:,
      self:,
      threads: dict.new(),
      code_channels: links.new(config.store, config.team),
      opening: set.new(),
      seen: [],
      generation: 0,
      stopping: None,
      finishing: False,
      failed_stops: [],
      broken: set.new(),
      tailnets: tailnet.new(
        config.tailnet,
        config.client,
        approvers(config.allowed, config.admins),
        fn(key, event, after_ms) {
          process.send_after(self, after_ms, Tailnet(key, event))
          Nil
        },
      ),
      members: people.new_cache(people.cache_ms),
      looking_up: dict.new(),
      connections:,
      nudged: dict.new(),
      proposals: dict.new(),
    )
    |> actor.initialised
    |> actor.selecting(selector)
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

/// A thread's key in workspace `team`.
pub fn key(team: String, channel: String, thread_ts: String) -> String {
  sandbox.key(team, channel, thread_ts)
}

/// Who may approve tailnet access: the admins, else the ids allowed. An
/// allowlist of everyone makes nobody an approver: being in the workspace
/// isn't enough to put a sandbox on the operator's tailnet.
pub fn approvers(allowed: People, admins: Set(String)) -> People {
  case set.is_empty(admins), allowed.everyone {
    False, _ -> people.People(everyone: False, ids: admins)
    True, True -> people.nobody()
    True, False -> allowed
  }
}

/// Whether `user` may drive agents here, as far as is known now. Someone
/// who needs a lookup that hasn't happened yet may not.
fn may_use(state: State, user: String) -> Bool {
  people.allows(state.config.allowed, user, fn(user) {
    people.cached(state.members, user, sys.monotonic_ms()) == Some(True)
  })
}

/// Whether `user`'s membership must be looked up before `may_use` can say.
fn unknown(state: State, user: String) -> Bool {
  people.needs_lookup(state.config.allowed, user)
  && people.cached(state.members, user, sys.monotonic_ms()) == None
}

/// Hold `waiting` until `user`'s membership is known, and look it up unless
/// a lookup is already under way. The lookup runs on its own process, so
/// the registry keeps serving other threads meanwhile.
fn wait_for_member(state: State, user: String, waiting: Waiting) -> State {
  case dict.get(state.looking_up, user) {
    Ok(#(id, queue)) ->
      State(
        ..state,
        looking_up: dict.insert(state.looking_up, user, #(
          id,
          list.append(queue, [waiting]),
        )),
      )
    Error(Nil) -> {
      let id = state.generation + 1
      let self = state.self
      let client = state.config.client
      let team = state.config.team
      process.spawn_unlinked(fn() {
        process.send(self, Member(user, id, people.lookup(client, team, user)))
      })
      process.send_after(
        self,
        member_timeout_ms,
        Member(user, id, Error("users.info took too long")),
      )
      State(
        ..state,
        generation: id,
        looking_up: dict.insert(state.looking_up, user, #(id, [waiting])),
      )
    }
  }
}

/// A membership lookup finished: keep the answer, then deal with what
/// waited for it. A failed lookup turns those away and isn't kept, so the
/// next message asks again.
fn member_known(
  state: State,
  user: String,
  id: Int,
  result: Result(Bool, String),
) -> State {
  let now = sys.monotonic_ms()
  case dict.get(state.looking_up, user) {
    Ok(#(current, queue)) if current == id -> {
      let state =
        State(
          ..state,
          looking_up: dict.delete(state.looking_up, user),
          members: people.remember(
            state.members,
            user,
            result.unwrap(result, False),
            now,
          ),
        )
      case result {
        Ok(_) -> Nil
        Error(reason) ->
          sys.warn(
            "crushling: couldn't tell whether "
            <> user
            <> " is a member of "
            <> state.config.team
            <> ", so ignoring them for now: "
            <> reason,
          )
      }
      let state =
        list.fold(queue, state, fn(state, waiting) {
          case waiting, state.stopping {
            _, Some(_) -> state
            WaitingMessage(incoming), None -> received(state, incoming, 0)
            WaitingStop(channel, thread_ts, user), None ->
              stop_requested(state, channel, thread_ts, user)
            WaitingPick(home, pick, card, user), None ->
              model_picked(state, home, pick, card, user)
            WaitingHome(user, ask), None -> home_ask(state, user, ask)
          }
        })
      case result {
        Ok(_) -> state
        Error(_) -> State(..state, members: people.forget(state.members, user))
      }
    }
    // A late answer to a lookup that timed out is still good to keep.
    _ ->
      case result {
        Ok(member) ->
          State(
            ..state,
            members: people.remember(state.members, user, member, now),
          )
        Error(_) -> state
      }
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Received(incoming) ->
      case state.stopping {
        // Draining: a new message would start work that is about to be
        // cut off. It is still in the thread, so the next turn catches up
        // on it.
        Some(_) -> actor.continue(state)
        None -> actor.continue(received(state, incoming, 0))
      }
    Deferred(incoming, attempts) ->
      case state.stopping {
        Some(_) -> actor.continue(state)
        None -> actor.continue(received(state, incoming, attempts))
      }
    Started(key, generation, result) ->
      started(state, key, generation, result) |> continue_or_finish
    Stopped(key, result) -> stopped(state, key, result) |> continue_or_finish
    RetryStop(key) ->
      case dict.get(state.threads, key) {
        Ok(Entry(agent: Stopping(..), ..)) -> {
          run_stop(state, key)
          actor.continue(state)
        }
        _ -> actor.continue(state)
      }
    Prepared(key, ts, prompt) ->
      actor.continue(prepared(state, key, ts, prompt))
    StopRequested(channel, thread_ts, user) ->
      actor.continue(stop_requested(state, channel, thread_ts, user))
    FromThread(key, notice) -> {
      let state = from_thread(state, key, notice)
      case state.stopping, busy(state) {
        Some(_), False -> finish_shutdown(state)
        _, _ -> actor.continue(state)
      }
    }
    Shutdown(grace_ms, reply) -> {
      let state = State(..state, stopping: Some(reply))
      case busy(state) {
        False -> finish_shutdown(state)
        True -> {
          sys.info("crushling: shutting down; waiting for running turns")
          process.send_after(state.self, grace_ms, ShutdownDeadline)
          actor.continue(state)
        }
      }
    }
    ShutdownDeadline -> {
      dict.each(state.threads, fn(_, entry) {
        case entry.agent, entry.in_flight > 0 {
          Live(thread:, ..), True ->
            process.send(thread, thread.Cancel(Some(restart_note)))
          _, _ -> Nil
        }
      })
      process.send_after(state.self, cancel_wait_ms, ShutdownFinal)
      actor.continue(state)
    }
    ShutdownFinal -> finish_shutdown(state)
    ShutdownGiveUp -> {
      sys.warn(
        "crushling: shutting down with "
        <> int.to_string(dict.size(state.threads))
        <> " agents still starting or stopping",
      )
      done_shutting_down(state, TimedOut)
    }
    IdleCheck(key, generation) ->
      actor.continue(idle_check(state, key, generation))
    HomeOpened(user) -> actor.continue(home_ask(state, user, ShowHome))
    GitHubConnect(user) -> actor.continue(home_ask(state, user, Connect(None)))
    PrPressed(user:, card_ts:, choice:, respond:) ->
      actor.continue(pr_pressed(state, user, card_ts, choice, respond))
    Sweep -> {
      process.send_after(state.self, sweep.every_ms, Sweep)
      actor.continue(sweep_quiet(state))
    }
    PrSettled(card_ts) ->
      actor.continue(
        State(..state, proposals: dict.delete(state.proposals, card_ts)),
      )
    Slash(channel:, user:, text:) -> {
      // Said at the top of the channel, now, and heard as if mentioned.
      let ms = sys.system_ms()
      let ts =
        int.to_string(ms / 1000)
        <> "."
        <> string.pad_start(int.to_string(ms % 1000 * 1000), 6, "0")
      actor.continue(received(
        state,
        Incoming(channel, "", ts, user, text, True, []),
        0,
      ))
    }
    GitHubConnectIn(user, place) ->
      actor.continue(home_ask(state, user, Connect(Some(place))))
    GitHubNudge(key, want) -> {
      nudge_who(state, key, want)
      actor.continue(state)
    }
    GitHubNudgeTo(key, user, want) ->
      actor.continue(nudge(state, key, user, want))
    GitHubDisconnect(user) -> {
      process.send(state.connections, connections.Disconnect(user, None))
      actor.continue(state)
    }
    JobsUncounted(key, generation) ->
      case dict.get(state.threads, key) {
        Ok(Entry(counting: True, ..) as entry)
          if entry.generation == generation && entry.agent != Starting
        -> {
          sys.warn(
            "crushling: " <> key <> " didn't count its background jobs in time",
          )
          actor.continue(jobs_counted(state, key, entry, generation, 0))
        }
        _ -> actor.continue(state)
      }
    ThreadDown(down) -> actor.continue(thread_down(state, down))
    Tailnet(key, event) -> actor.continue(on_tailnet(state, key, event))
    Lookup(key, reply) -> {
      process.send(reply, case dict.get(state.threads, key) {
        Ok(Entry(agent: Live(thread:, ..), ..)) -> Some(thread)
        _ -> None
      })
      actor.continue(state)
    }
    Member(user, id, result) ->
      actor.continue(member_known(state, user, id, result))
    GitHubAccess(key, reply) -> {
      github_access(state, key, reply)
      actor.continue(state)
    }
    ModelPicked(home, pick, card, user) ->
      case state.stopping {
        Some(_) -> actor.continue(state)
        None -> actor.continue(model_picked(state, home, pick, card, user))
      }
  }
}

/// The thread's entry: in memory, or rebuilt from its `meta` in the store
/// for a thread the bot was in before a restart or an idle stop. An error
/// says the thread lives under its old key and couldn't be moved.
fn entry_for(
  state: State,
  key: String,
  channel: String,
  thread_ts: String,
) -> Result(Option(Entry), String) {
  case dict.get(state.threads, key) {
    Ok(entry) -> Ok(Some(entry))
    Error(Nil) -> {
      let config = state.config
      let launcher = config.launcher
      let saved = saved_thread(config, key)
      let exists = launcher.exists(key)
      // Half of it may be under the new key already, from a move that
      // stopped partway: finish it.
      use #(saved, exists) <- result.map(case saved, exists {
        Some(_), True -> Ok(#(saved, exists))
        _, _ ->
          case migrate_legacy(config, key, channel, thread_ts) {
            Error(reason) -> Error(reason)
            Ok(False) -> Ok(#(saved, exists))
            Ok(True) -> Ok(#(saved_thread(config, key), launcher.exists(key)))
          }
      })
      case exists {
        False -> None
        True ->
          Some(new_entry(
            channel,
            thread_ts,
            saved
              |> option.map(fn(thread) { thread.meta })
              // A workspace without meta predates follow mode, when every
              // reply was a prompt.
              |> option.unwrap(meta.new(True)),
          ))
      }
    }
  }
}

fn saved_thread(config: Config, key: String) -> Option(store.Thread) {
  case store.thread(config.store, key) {
    Ok(found) -> found
    Error(reason) -> {
      sys.warn("crushling: reading " <> key <> " failed: " <> reason)
      None
    }
  }
}

/// A thread from before keys carried the team lives under its old key,
/// `channel-ts`: its row in the store, its directory under the root, and
/// maybe its container. Only the workspace the bridge served before
/// (`Config.migrate_legacy`) has such threads. Move what is still under the
/// old key to `key`: the row, unless the new key has one; the directory
/// (and the old container goes), unless the new key has one. Each step is
/// safe to repeat, so a move cut short finishes on the next lookup. True
/// when something moved; an error when a step failed.
pub fn migrate_legacy(
  config: Config,
  key: String,
  channel: String,
  thread_ts: String,
) -> Result(Bool, String) {
  let old = sandbox.legacy_key(channel, thread_ts)
  let launcher = config.launcher
  case config.migrate_legacy && old != key {
    False -> Ok(False)
    True -> {
      // An old row of another workspace (a channel shared with it) isn't
      // this one's to take.
      use old_row <- result.try(case store.thread(config.store, old) {
        Ok(Some(thread)) -> Ok(thread.team == "" || thread.team == config.team)
        Ok(None) -> Ok(False)
        Error(reason) -> Error("reading " <> old <> ": " <> reason)
      })
      use new_row <- result.try(
        store.thread(config.store, key)
        |> result.map(option.is_some)
        |> result.map_error(fn(reason) { "reading " <> key <> ": " <> reason }),
      )
      let move_row = old_row && !new_row
      let move_dir = launcher.exists(old) && !launcher.exists(key)
      case move_row || move_dir {
        False -> Ok(False)
        True -> {
          sys.info("crushling: moving " <> old <> " to " <> key)
          let moved = {
            use _ <- result.try(case move_dir {
              True -> launcher.rekey(old, key)
              False -> Ok(Nil)
            })
            case move_row {
              True ->
                store.rename_thread(
                  config.store,
                  old:,
                  new: key,
                  team: config.team,
                )
                |> result.replace(Nil)
              False -> Ok(Nil)
            }
          }
          case moved {
            Ok(Nil) -> Ok(True)
            Error(reason) -> {
              sys.warn(
                "crushling: moving "
                <> old
                <> " to "
                <> key
                <> " failed: "
                <> reason,
              )
              Error(reason)
            }
          }
        }
      }
    }
  }
}

fn received(state: State, incoming: Incoming, attempts: Int) -> State {
  // A message in a code channel belongs to the thread that moved there.
  let #(code_channels, code) = links.find(state.code_channels, incoming.channel)
  let state = State(..state, code_channels:)
  let origin = option.map(code, links.origin)
  let #(channel, thread_ts) =
    option.unwrap(origin, #(incoming.channel, incoming.thread_ts))
  let key = key(state.config.team, channel, thread_ts)
  case entry_for(state, key, channel, thread_ts) {
    Ok(known) ->
      received_known(state, incoming, code, origin, key, known, attempts)
    Error(_) -> broken(state, key, incoming)
  }
}

/// The thread is under its old key and couldn't be moved: starting a fresh
/// one under the new key would hide its old work, so say so once and drop
/// the message.
fn broken(state: State, key: String, incoming: Incoming) -> State {
  case set.contains(state.broken, key) {
    True -> state
    False -> {
      let client = state.config.client
      process.spawn_unlinked(fn() {
        slack.say(
          client,
          incoming.channel,
          incoming.thread_ts,
          "_couldn't move this thread's old workspace; an admin should check the logs._",
        )
      })
      State(..state, broken: set.insert(state.broken, key))
    }
  }
}

fn received_known(
  state: State,
  incoming: Incoming,
  code: Option(Link),
  origin: Option(#(String, String)),
  key: String,
  known: Option(Entry),
  attempts: Int,
) -> State {
  // Slack can post the copy of the request in a new code channel before the
  // thread says which channel it opened. Hold new messages until it does.
  case known, set.is_empty(state.opening), attempts < defer_attempts {
    None, False, True -> {
      process.send_after(state.self, defer_ms, Deferred(incoming, attempts + 1))
      state
    }
    _, _, _ -> route(state, incoming, code, origin, key, known)
  }
}

/// A message addressed to a thread. `known` is the thread's entry if the bot
/// already works there.
type Route {
  Route(
    incoming: Incoming,
    /// The thread a code channel belongs to, when the message is in one.
    origin: Option(#(String, String)),
    key: String,
    known: Option(Entry),
    /// The message without its mention of the bot.
    prompt: String,
  )
}

fn route(
  state: State,
  incoming: Incoming,
  code: Option(Link),
  origin: Option(#(String, String)),
  key: String,
  known: Option(Entry),
) -> State {
  let config = state.config
  let id = incoming.channel <> ":" <> incoming.ts
  let prompt = slack.prompt_text(incoming.text, config.bot_user)
  let command = slack.command(prompt)
  // Whether this message is for the agent at all. In a code channel people
  // are talking to the agent, mentioned or not; a paused agent hears only
  // mentions, and `!resume`.
  let addressed = case known, origin {
    _, _ if incoming.mention -> True
    Some(_), _ if command == slack.ResumeCommand -> True
    Some(Entry(meta: Meta(paused: True, ..), ..)), _ -> False
    Some(_), Some(_) -> True
    Some(entry), None -> entry.meta.follow
    None, _ -> False
  }
  case
    list.contains(state.seen, id)
    || links.is_seed(code, incoming.ts)
    || already_read(known, incoming.ts),
    addressed,
    may_use(state, incoming.user)
  {
    True, _, _ -> state
    // Thread chatter the agent isn't following: the next turn catches up.
    _, False, _ -> state
    False, True, False ->
      case unknown(state, incoming.user) {
        // Everyone may use it, but is this a member? Ask, then come back.
        True -> wait_for_member(state, incoming.user, WaitingMessage(incoming))
        False -> {
          sys.warn(
            "crushling: ignoring " <> incoming.user <> ", not on the allowlist",
          )
          remember(state, id)
        }
      }
    False, True, True ->
      Route(incoming:, origin:, key:, known:, prompt:)
      |> act(state, _, command)
      |> remember(id)
  }
}

/// Do what a message asks for.
fn act(state: State, route: Route, command: slack.Command) -> State {
  let config = state.config
  case command, route.known {
    slack.SideComment, _ -> state
    // Works anywhere the bot hears it, with or without an agent.
    slack.GitHubCommand(connect:), _ -> {
      let user = route.incoming.user
      let from =
        Some(connections.Place(
          route.incoming.channel,
          route.incoming.thread_ts,
          None,
        ))
      case connect {
        True -> home_ask(state, user, Connect(from))
        False -> {
          process.send(state.connections, connections.Disconnect(user, from))
          state
        }
      }
    }
    slack.HelpCommand, _ -> {
      whisper(config, route.incoming, slack.help)
      state
    }
    slack.PauseCommand, Some(entry) -> {
      announce(
        config,
        route.incoming,
        route.origin,
        "_paused: I'll only answer when mentioned. `!resume` to have me follow along again._",
      )
      set_meta(state, route.key, entry, Meta(..entry.meta, paused: True))
    }
    slack.ResumeCommand, Some(entry) -> {
      announce(
        config,
        route.incoming,
        route.origin,
        "_following along again: every message here reaches me._",
      )
      let meta = Meta(..entry.meta, paused: False, follow: True)
      set_meta(state, route.key, entry, meta)
    }
    slack.DoneCommand, Some(entry) -> done(state, route, entry)
    slack.PrCommand(title), Some(entry) -> {
      let incoming = route.incoming
      deliver(
        state,
        route.key,
        entry,
        thread.Propose(title, "", fn(result) {
          case result {
            Ok(_) -> Nil
            Error(why) ->
              whisper(config, incoming, "_No PR card: " <> why <> "._")
          }
        }),
      )
    }
    slack.InfoCommand, Some(Entry(agent: Live(thread:, ..), ..)) -> {
      let incoming = route.incoming
      process.spawn_unlinked(fn() {
        let asked = process.new_subject()
        process.send(thread, thread.Info(asked))
        let text =
          process.receive(asked, 15_000)
          |> result.unwrap("_The agent didn't answer in time._")
        whisper(config, incoming, text)
      })
      state
    }
    slack.InfoCommand, Some(_) -> {
      whisper(
        config,
        route.incoming,
        "_The agent is asleep; send a message to wake it, then ask again._",
      )
      state
    }
    slack.StopCommand, Some(Entry(agent: Live(thread:, ..), ..) as entry)
      if entry.in_flight > 0 || entry.working
    -> {
      process.send(thread, thread.Cancel(None))
      state
    }
    slack.StopCommand, _ -> {
      whisper(config, route.incoming, "_nothing is running in this thread._")
      state
    }
    slack.TailnetCommand(on: True), Some(entry) -> {
      let #(tailnets, asked) =
        tailnet.ask(
          state.tailnets,
          route.key,
          tailnet_view(entry),
          route.incoming.user,
          "",
        )
      let state = State(..state, tailnets:)
      case asked {
        Ok(_) -> Nil
        Error(reason) -> whisper(config, route.incoming, "_" <> reason <> "._")
      }
      state
    }
    slack.TailnetCommand(on: False), Some(entry) ->
      tailnet.end(
        state.tailnets,
        route.key,
        tailnet_view(entry),
        "_<@" <> route.incoming.user <> "> took the sandbox off the tailnet._",
      )
      |> apply_tailnet(state, route.key, Some(entry), _)
    slack.ModelCommand(argument), Some(entry) ->
      case models.parse_argument(argument) {
        Ok(request) ->
          deliver(
            state,
            route.key,
            entry,
            thread.ModelCommand(request, route.incoming.user),
          )
        Error(Nil) -> {
          whisper(
            config,
            route.incoming,
            "_`!model` shows the model; `!model <id> [level]` switches, and `!model default` goes back to the default._",
          )
          state
        }
      }
    slack.PauseCommand, None
    | slack.ResumeCommand, None
    | slack.DoneCommand, None
    | slack.InfoCommand, None
    | slack.PrCommand(..), None
    | slack.TailnetCommand(..), None
    | slack.ModelCommand(..), None
    -> {
      whisper(config, route.incoming, "_I'm not working in this thread._")
      state
    }
    // A bare mention with nothing attached has nothing to say.
    slack.NotACommand, _ if route.prompt == "" && route.incoming.files == [] ->
      state
    slack.NotACommand, known -> queue(state, route, known)
  }
}

/// Queue a prompt, and wake or start the thread's agent.
fn queue(state: State, route: Route, known: Option(Entry)) -> State {
  let incoming = route.incoming
  // "Working…" now, not once the agent is up and the prompt is ready.
  let client = state.config.client
  let #(channel, thread_ts) = case known {
    Some(Entry(meta: Meta(venue: venue.CodeChannel(channel:, ..), ..), ..)) -> #(
      channel,
      None,
    )
    Some(entry) -> #(entry.channel, Some(entry.thread_ts))
    None -> #(incoming.channel, Some(incoming.thread_ts))
  }
  process.spawn_unlinked(fn() { slack.mark_working(client, channel, thread_ts) })
  case known {
    Some(entry) -> {
      let entry =
        Entry(
          ..entry,
          backlog: list.append(entry.backlog, [incoming]),
          people: set.insert(entry.people, incoming.user),
        )
      case dict.has_key(state.threads, route.key) {
        True ->
          State(..state, threads: dict.insert(state.threads, route.key, entry))
        // Known from disk but asleep: wake its agent.
        False -> launch(state, route.key, entry)
      }
      |> pump(route.key)
    }
    None -> {
      let follow = incoming.ts == incoming.thread_ts || is_dm(incoming.channel)
      let entry =
        Entry(
          ..new_entry(incoming.channel, incoming.thread_ts, meta.new(follow)),
          backlog: [incoming],
          people: set.from_list([incoming.user]),
        )
      launch(state, route.key, entry)
    }
  }
}

/// Hand the thread actor a message: now if its agent is up, once it is if
/// it is starting or stopping, and after waking it if it is asleep.
fn deliver(
  state: State,
  key: String,
  entry: Entry,
  message: thread.Message,
) -> State {
  case dict.has_key(state.threads, key), entry.agent {
    True, Live(thread:, ..) -> {
      process.send(thread, message)
      state
    }
    True, _ -> {
      let entry = Entry(..entry, pending: list.append(entry.pending, [message]))
      State(..state, threads: dict.insert(state.threads, key, entry))
    }
    False, _ -> launch(state, key, Entry(..entry, pending: [message]))
  }
}

/// A pick on a model card. Slack already shows the pick in the menu, so a
/// refusal is said privately to whoever picked.
fn model_picked(
  state: State,
  home: #(String, String),
  pick: models.Pick,
  card: meta.Card,
  user: String,
) -> State {
  let #(channel, thread_ts) = home
  let key = key(state.config.team, channel, thread_ts)
  let refuse = fn(text) {
    let client = state.config.client
    process.spawn_unlinked(fn() {
      slack.whisper(client, card.channel, card.thread_ts, user, text)
    })
    state
  }
  case may_use(state, user), unknown(state, user) {
    // Everyone may use it, but is this a member? Ask, then come back.
    False, True ->
      wait_for_member(state, user, WaitingPick(home, pick, card, user))
    False, False -> refuse("_you can't change this thread's model._")
    True, _ ->
      case entry_for(state, key, channel, thread_ts) {
        Ok(Some(entry)) ->
          deliver(state, key, entry, thread.CardPicked(pick, card.ts, user))
        _ -> refuse("_I'm not working in that thread anymore._")
      }
  }
}

// The App Home and GitHub ------------------------------------------------------

/// What someone asked of the App Home or `!github`, waiting on whether they
/// may use crushling.
type HomeAsk {
  ShowHome
  Connect(from: Option(connections.Place))
}

/// Do what `user` asked once it's known whether they may use crushling.
/// Disconnecting needs no permission: anyone may forget their own account.
fn home_ask(state: State, user: String, ask: HomeAsk) -> State {
  case may_use(state, user), unknown(state, user) {
    False, True -> wait_for_member(state, user, WaitingHome(user, ask))
    allowed, _ -> {
      case ask, allowed {
        Connect(from:), True ->
          process.send(state.connections, connections.Connect(user, from))
        Connect(from: Some(connections.Place(channel:, thread_ts:, ..))), False
        -> {
          let client = state.config.client
          process.spawn_unlinked(fn() {
            slack.whisper(
              client,
              channel,
              thread_ts,
              user,
              "_You can't use crushling here._",
            )
          })
          Nil
        }
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
  }
}

/// Archive code channels quiet for a week and forget workspaces quiet for
/// a month (`registry/sweep`). Slack and the disk are touched off the
/// registry; the thread's meta changes here.
fn sweep_quiet(state: State) -> State {
  let config = state.config
  let now = sys.system_ms() / 1000
  case
    store.quiet_threads(config.store, config.team, now - sweep.archive_after_s)
  {
    Error(reason) -> {
      sys.warn("crushling: sweeping quiet threads: " <> reason)
      state
    }
    Ok(threads) -> {
      let busy = fn(key) {
        case dict.get(state.threads, key) {
          Ok(Entry(agent: Live(..), ..))
          | Ok(Entry(agent: Starting, ..))
          | Ok(Entry(agent: Stopping(..), ..)) -> True
          _ -> False
        }
      }
      sweep.plan(threads, now, busy, config.launcher.exists)
      |> list.fold(state, fn(state, action) {
        case action {
          sweep.Archive(key:, channel:, repo:) -> {
            sys.info("crushling: archiving quiet code channel " <> channel)
            let client = config.client
            process.spawn_unlinked(fn() {
              slack.say(client, channel, "", sweep.archive_note)
              case slack.archive_code_channel(client, channel, "") {
                Ok(Nil) -> Nil
                Error(reason) ->
                  sys.warn(
                    "crushling: archiving " <> channel <> " failed: " <> reason,
                  )
              }
            })
            update_meta(state, key, fn(meta) {
              Meta(..meta, venue: venue.Archived(repo), tailnet: None)
            })
          }
          sweep.Forget(key) -> {
            sys.info("crushling: clearing out " <> key <> ", quiet for a month")
            let forget = config.launcher.forget
            process.spawn_unlinked(fn() {
              case forget(key) {
                Ok(Nil) -> Nil
                Error(reason) ->
                  sys.warn("crushling: clearing out " <> key <> ": " <> reason)
              }
            })
            state
          }
        }
      })
    }
  }
}

/// A press on a PR card. Only someone who may use crushling may press;
/// the PR opens as them, with their GitHub connection.
fn pr_pressed(
  state: State,
  user: String,
  card_ts: String,
  choice: String,
  respond: Option(String),
) -> State {
  let say = fn(text) {
    case respond {
      Some(url) -> {
        process.spawn_unlinked(fn() { slack.reply_ephemeral(url, text) })
        Nil
      }
      None -> Nil
    }
  }
  case
    dict.get(state.proposals, card_ts),
    may_use(state, user),
    state.config.github
  {
    Error(Nil), _, _ -> {
      say("_This card has expired; `/pr` posts a new one._")
      state
    }
    _, False, _ -> {
      say("_You can't use crushling here._")
      state
    }
    _, _, None -> {
      say("_GitHub isn't set up for this crushling._")
      state
    }
    Ok(#(channel, proposal)), True, Some(config) -> {
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
          process.spawn_unlinked(fn() {
            settle("Dismissed by <@" <> user <> ">")
          })
          State(..state, proposals: dict.delete(state.proposals, card_ts))
        }
        _ -> {
          let connections = state.connections
          let draft = choice == "draft"
          let self = state.self
          process.spawn_unlinked(fn() {
            let asked = process.new_subject()
            process.send(connections, connections.Access(user, asked))
            case process.receive(asked, github_access_ms) {
              Ok(Ok(Some(token))) ->
                case pr.open(config, token, proposal, draft) {
                  Ok(#(number, url)) -> {
                    settle(
                      "<@"
                      <> user
                      <> "> opened <"
                      <> url
                      <> "|#"
                      <> int.to_string(number)
                      <> ">"
                      <> case draft {
                        True -> " as a draft"
                        False -> ""
                      },
                    )
                    process.send(self, PrSettled(card_ts))
                  }
                  Error(why) -> say("_Couldn't open the PR: " <> why <> "._")
                }
              Ok(Ok(None)) ->
                say(
                  "_Connect your GitHub account first, from crushling's Home tab or with `!github`, then press again: the PR opens as you._",
                )
              _ -> say("_Couldn't get your GitHub connection; try again._")
            }
          })
          state
        }
      }
    }
  }
}

/// Find out, off the registry, whose agent it is.
fn nudge_who(state: State, key: String, want: github_route.Want) -> Nil {
  case dict.get(state.threads, key) {
    Ok(Entry(agent: Live(thread:, ..), ..)) -> {
      let self = state.self
      process.spawn_unlinked(fn() {
        let asked = process.new_subject()
        process.send(thread, thread.Requester(asked))
        case process.receive(asked, 5000) {
          Ok("") | Error(Nil) -> Nil
          Ok(user) -> process.send(self, GitHubNudgeTo(key, user, want))
        }
      })
      Nil
    }
    _ -> Nil
  }
}

fn nudge(
  state: State,
  key: String,
  user: String,
  want: github_route.Want,
) -> State {
  let now = sys.monotonic_ms()
  // Asked once a while per thread, person, and what for: a connect and
  // then an install are both asked.
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
            slack.whisper_blocks(client, channel, thread_ts, user, text, blocks)
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

/// Answer `GitHubAccess` off the registry: asking the thread and the
/// connections actor (which may refresh with GitHub) takes a while.
fn github_access(
  state: State,
  key: String,
  reply: Subject(Result(Option(String), String)),
) -> Nil {
  case dict.get(state.threads, key) {
    Ok(Entry(agent: Live(thread:, ..), ..)) -> {
      let connections = state.connections
      process.spawn_unlinked(fn() {
        process.send(reply, {
          // Sent and received rather than called, so a thread or actor
          // that has gone is a timeout here, not a crash.
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

/// How long a token may take, a refresh with GitHub included.
pub const github_access_ms = 30_000

/// `user`'s threads with a running agent: ones they've sent a prompt in.
fn threads_of(state: State, user: String) -> List(connections.Thread) {
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

/// Change a thread's meta, from its entry in memory or, for a thread whose
/// agent was stopped meanwhile, its row in the store.
fn update_meta(state: State, key: String, change: fn(Meta) -> Meta) -> State {
  let entry = case dict.get(state.threads, key) {
    Ok(entry) -> Some(entry)
    Error(Nil) ->
      saved_thread(state.config, key)
      |> option.map(fn(saved) {
        new_entry(saved.channel, saved.thread_ts, saved.meta)
      })
  }
  case entry {
    Some(entry) -> set_meta(state, key, entry, change(entry.meta))
    None -> state
  }
}

/// Save a thread's meta, whether its agent is running or asleep. All thread
/// meta is written here.
fn set_meta(state: State, key: String, entry: Entry, meta: Meta) -> State {
  let thread =
    store.Thread(
      key:,
      team: state.config.team,
      channel: entry.channel,
      thread_ts: entry.thread_ts,
      meta:,
    )
  case store.put_thread(state.config.store, thread) {
    Ok(Nil) -> Nil
    Error(reason) ->
      sys.warn("crushling: saving " <> key <> " failed: " <> reason)
  }
  case dict.has_key(state.threads, key) {
    True ->
      State(
        ..state,
        threads: dict.insert(state.threads, key, Entry(..entry, meta:)),
      )
    False -> state
  }
}

/// Say something everyone in the conversation should see: in the thread,
/// or at the top of a code channel.
fn announce(
  config: Config,
  incoming: Incoming,
  origin: Option(#(String, String)),
  text: String,
) -> Nil {
  let client = config.client
  let thread_ts = case origin, incoming.ts == incoming.thread_ts {
    Some(_), True -> ""
    _, _ -> incoming.thread_ts
  }
  process.spawn_unlinked(fn() {
    slack.say(client, incoming.channel, thread_ts, text)
  })
  Nil
}

fn whisper(config: Config, incoming: Incoming, text: String) -> Nil {
  let client = config.client
  process.spawn_unlinked(fn() {
    slack.whisper(
      client,
      incoming.channel,
      incoming.thread_ts,
      incoming.user,
      text,
    )
  })
  Nil
}

fn remember(state: State, id: String) -> State {
  State(..state, seen: list.take([id, ..state.seen], seen_limit))
}

fn launch(state: State, key: String, entry: Entry) -> State {
  sys.info("crushling: starting an agent for " <> key)
  let generation = state.generation + 1
  let config = state.config
  let self = state.self
  let channel = entry.channel
  let thread_ts = entry.thread_ts
  let meta = entry.meta
  let state = set_meta(state, key, entry, meta)
  process.spawn_unlinked(fn() {
    // If the thread actor can't start, the agent is stopped again, since
    // nothing would drive it.
    let result = {
      use launched <- launcher.launch_then(config.launcher, key)
      let sink = case meta.venue {
        venue.CodeChannel(channel: code, ..) -> {
          // Channels opened before commands existed get them now.
          slack.set_code_commands(config.client, code)
          slack.sink(config.client, config.team, code, slack.InCodeChannel)
        }
        _ ->
          slack.sink(
            config.client,
            config.team,
            channel,
            slack.InThread(thread_ts),
          )
      }
      thread.start(
        thread.Config(
          socket: launched.socket,
          root: launched.root,
          title: "slack " <> channel <> " " <> thread_ts,
          venue: meta.venue,
          sink:,
          flush_ms: config.flush_ms,
          mode: config.mode,
          notify: fn(notice) { process.send(self, FromThread(key, notice)) },
          on_connect: fn(_) { Nil },
          model: meta.model,
          home: #(channel, thread_ts),
        ),
      )
      |> result.map_error(fn(error) { "thread: " <> string.inspect(error) })
    }
    process.send(self, Started(key, generation, result))
  })
  let entry = Entry(..entry, generation:, agent: Starting)
  State(..state, generation:, threads: dict.insert(state.threads, key, entry))
}

fn started(
  state: State,
  key: String,
  generation: Int,
  result: Result(Subject(thread.Message), String),
) -> State {
  case dict.get(state.threads, key), result {
    Ok(Entry(agent: Starting, ..) as entry), _
      if entry.generation == generation
    ->
      case result {
        Error(reason) -> {
          sys.warn("crushling: could not start " <> key <> ": " <> reason)
          let client = state.config.client
          process.spawn_unlinked(fn() {
            slack.say(
              client,
              entry.channel,
              entry.thread_ts,
              "_couldn't start an agent for this thread: " <> reason <> "_",
            )
          })
          State(..state, threads: dict.delete(state.threads, key))
        }
        Ok(thread) if state.finishing -> {
          // Shutdown already stopped everything else; this one started
          // after, so stop it too.
          let assert Ok(pid) = process.subject_owner(thread)
          let monitor = process.monitor(pid)
          let entry = Entry(..entry, agent: Live(thread:, monitor:))
          State(..state, threads: dict.insert(state.threads, key, entry))
          |> stop_agent(key)
        }
        Ok(thread) -> {
          let assert Ok(pid) = process.subject_owner(thread)
          let monitor = process.monitor(pid)
          list.each(entry.pending, process.send(thread, _))
          let entry =
            Entry(..entry, agent: Live(thread:, monitor:), pending: [])
          State(..state, threads: dict.insert(state.threads, key, entry))
          |> pump(key)
          // Not every launch brings a prompt (`!model` wakes a thread too),
          // so start the idle timer; a prompt being prepared keeps it from
          // firing.
          |> fn(state) {
            case dict.get(state.threads, key) {
              Ok(entry) -> idle_soon(state, key, entry)
              Error(Nil) -> state
            }
          }
          |> fn(state) {
            tailnet.check(state.tailnets, key, tailnet_view(entry), None)
            |> apply_tailnet(state, key, Some(entry), _)
          }
        }
      }
    _, Ok(thread) -> {
      // Superseded while starting; nobody will use this one.
      process.send(thread, thread.Stop)
      state
    }
    _, Error(_) -> state
  }
}

/// Prepare the next waiting message, if the agent is up and nothing else
/// is being prepared. Preparing talks to Slack, so it runs on its own
/// process and reports back with `Prepared`.
fn pump(state: State, key: String) -> State {
  case dict.get(state.threads, key) {
    // Caught up on by an earlier prompt while it waited.
    Ok(Entry(preparing: False, backlog: [next, ..rest], ..) as entry) ->
      case already_read(Some(entry), next.ts) {
        True -> {
          let entry = Entry(..entry, backlog: rest)
          State(..state, threads: dict.insert(state.threads, key, entry))
          |> pump(key)
        }
        False -> prepare_next(state, key, entry, next, rest)
      }
    _ -> state
  }
}

fn prepare_next(
  state: State,
  key: String,
  entry: Entry,
  next: Incoming,
  rest: List(Incoming),
) -> State {
  case entry.agent {
    Live(..) -> {
      let config = state.config
      let self = state.self
      let cursor = entry.meta.cursor
      // A code channel is caught up on as a whole, not by thread.
      let catch_up = case next.channel == entry.channel {
        True -> next.thread_ts
        False -> ""
      }
      process.spawn_unlinked(fn() {
        let source =
          prompt.Source(
            config.client,
            config.token,
            config.bot_user,
            slack.Keep(config.root, key),
          )
        let prompt = prompt.build(source, next, cursor, catch_up)
        process.send(self, Prepared(key, next.ts, prompt))
      })
      let entry = Entry(..entry, backlog: rest, preparing: True)
      State(..state, threads: dict.insert(state.threads, key, entry))
    }
    Starting | Stopping(..) -> state
  }
}

/// The prompt for `incoming`: what was said since `cursor`, who is asking,
/// the request, and any attached files. `catch_up` is the thread to catch
/// up on, or "" for the whole of a code channel.
fn prepared(
  state: State,
  key: String,
  ts: String,
  prompt: thread.Message,
) -> State {
  case dict.get(state.threads, key) {
    Ok(Entry(agent: Live(thread:, ..), ..) as entry) -> {
      // How long the person waited for their message to reach the agent.
      let waited = sys.system_ms() - float.round(slack.ts_value(ts) *. 1000.0)
      sys.info(
        "crushling: "
        <> key
        <> " prompt ready "
        <> int.to_string(waited)
        <> "ms after it was sent",
      )
      process.send(thread, prompt)
      let entry =
        Entry(..entry, in_flight: entry.in_flight + 1, preparing: False)
      State(..state, threads: dict.insert(state.threads, key, entry))
      |> set_meta(key, entry, Meta(..entry.meta, cursor: ts))
      |> pump(key)
    }
    _ -> state
  }
}

fn stop_requested(
  state: State,
  channel: String,
  thread_ts: String,
  user: String,
) -> State {
  let config = state.config
  let incoming = Incoming(channel, thread_ts, thread_ts, user, "", False, [])
  // A code channel's session has no thread.
  let #(state, origin) = case thread_ts {
    "" -> {
      let #(code_channels, code) = links.find(state.code_channels, channel)
      #(State(..state, code_channels:), option.map(code, links.origin))
    }
    _ -> #(state, None)
  }
  let key = case origin {
    Some(#(origin_channel, origin_ts)) ->
      key(config.team, origin_channel, origin_ts)
    None -> key(config.team, channel, thread_ts)
  }
  case may_use(state, user), dict.get(state.threads, key) {
    True, Ok(Entry(agent: Live(thread:, ..), ..) as entry)
      if entry.in_flight > 0 || entry.working
    -> {
      process.send(thread, thread.Cancel(None))
      state
    }
    False, _ ->
      case unknown(state, user) {
        True ->
          wait_for_member(state, user, WaitingStop(channel, thread_ts, user))
        False -> {
          whisper(
            config,
            incoming,
            "_only the people this agent works for can stop it._",
          )
          state
        }
      }
    // Nothing running here, so the session shouldn't say it is.
    True, _ -> {
      let client = config.client
      process.spawn_unlinked(fn() {
        slack.session_done(client, channel, thread_ts)
      })
      state
    }
  }
}

fn busy(state: State) -> Bool {
  dict.values(state.threads)
  |> list.any(fn(entry) { entry.in_flight > 0 })
}

/// Stop every thread and its agent, then let the caller know. Launches in
/// flight are waited for, and what they start is stopped too, so no
/// sandbox outlives shutdown.
fn finish_shutdown(state: State) -> actor.Next(State, Message) {
  case state.finishing {
    True -> continue_or_finish(state)
    False -> {
      process.send_after(state.self, give_up_ms, ShutdownGiveUp)
      let state = State(..state, finishing: True)
      // Agents stop in parallel. A stopped sandbox's ephemeral node leaves
      // the tailnet with it.
      dict.keys(state.threads)
      |> list.fold(state, stop_agent)
      |> continue_or_finish
    }
  }
}

/// How long shutdown waits for launches and stops in flight, retries
/// included.
const give_up_ms = 120_000

/// Slack for the caller on top of the registry's own timers.
const shutdown_margin_ms = 5000

/// The longest a `Shutdown` with `grace_ms` takes to reply: the grace
/// period, the wait after cancelling, the wait for launches and stops, and
/// a margin. The caller waits this long and no longer.
pub fn shutdown_budget_ms(grace_ms: Int) -> Int {
  grace_ms + cancel_wait_ms + give_up_ms + shutdown_margin_ms
}

/// While shutdown is stopping agents, end once nothing is left.
fn continue_or_finish(state: State) -> actor.Next(State, Message) {
  case state.finishing && dict.is_empty(state.threads) {
    True ->
      done_shutting_down(state, case state.failed_stops {
        [] -> Clean
        failed -> Incomplete(list.unique(failed))
      })
    False -> actor.continue(state)
  }
}

fn done_shutting_down(
  state: State,
  outcome: ShutdownOutcome,
) -> actor.Next(State, Message) {
  case outcome {
    Clean -> sys.info("crushling: stopped every agent")
    _ -> sys.warn("crushling: shutdown incomplete: " <> string.inspect(outcome))
  }
  case state.stopping {
    Some(reply) -> process.send(reply, outcome)
    None -> Nil
  }
  actor.stop()
}

/// The launcher has stopped the thread's agent, or failed to. Messages
/// that came in meanwhile start it again, unless the bridge is shutting
/// down. A failed stop is retried after each of `stop_backoff_ms`, with the
/// entry left `Stopping` so messages keep waiting; when the retries are
/// used up the registry gives up on the agent, says so in the thread, and
/// shutdown reports it.
fn stopped(state: State, key: String, result: Result(Nil, String)) -> State {
  case dict.get(state.threads, key), result {
    Ok(Entry(agent: Stopping(..), ..) as entry), Ok(Nil) ->
      case has_waiting(entry), state.finishing {
        True, False ->
          launch(
            state,
            key,
            Entry(..entry, in_flight: 0, preparing: False, working: False),
          )
        _, _ -> State(..state, threads: dict.delete(state.threads, key))
      }
    Ok(Entry(agent: Stopping(attempt:), ..) as entry), Error(reason) ->
      case list.drop(state.config.stop_backoff_ms, attempt) {
        [delay, ..] -> {
          sys.warn(
            "crushling: stopping "
            <> key
            <> " failed, retrying in "
            <> int.to_string(delay)
            <> "ms: "
            <> reason,
          )
          process.send_after(state.self, delay, RetryStop(key))
          let entry = Entry(..entry, agent: Stopping(attempt + 1))
          State(..state, threads: dict.insert(state.threads, key, entry))
        }
        [] -> {
          sys.warn(
            "crushling: error: giving up stopping "
            <> key
            <> " after "
            <> int.to_string(attempt + 1)
            <> " tries: "
            <> reason,
          )
          let client = state.config.client
          let #(channel, thread_ts) = entry.conversation(entry)
          process.spawn_unlinked(fn() {
            slack.say(
              client,
              channel,
              thread_ts,
              "_couldn't stop this thread's agent, so its sandbox may still be running. Send a follow-up to start it again._",
            )
          })
          State(
            ..state,
            threads: dict.delete(state.threads, key),
            failed_stops: [key, ..state.failed_stops],
          )
        }
      }
    _, _ -> state
  }
}

/// Run the launcher's stop for `key` on its own process, which reports
/// back with `Stopped`.
fn run_stop(state: State, key: String) -> Nil {
  let stop = state.config.launcher.stop
  let self = state.self
  process.spawn_unlinked(fn() { process.send(self, Stopped(key, stop(key))) })
  Nil
}

fn from_thread(state: State, key: String, notice: thread.Notice) -> State {
  case notice, dict.get(state.threads, key) {
    thread.Opening, _ -> State(..state, opening: set.insert(state.opening, key))
    thread.Moved(venue:, opened_ts:), found -> {
      let state = State(..state, opening: set.delete(state.opening, key))
      case found {
        Ok(entry) -> moved(state, key, entry, venue, opened_ts)
        Error(Nil) -> state
      }
    }
    thread.RunEnded(finished), Ok(entry) -> {
      let entry = case finished.reply_ts {
        "" -> entry
        ts -> Entry(..entry, summary_ts: ts)
      }
      // Crush starts its own turns to read subagent reports. Those turns were
      // never counted in `in_flight`.
      let entry = case finished.solicited {
        True -> Entry(..entry, in_flight: int.max(entry.in_flight - 1, 0))
        False -> entry
      }
      idle_soon(state, key, entry)
    }
    thread.Activity(busy:), Ok(entry) ->
      idle_soon(state, key, Entry(..entry, working: busy))
    thread.JobsRunning(generation:, running:), Ok(entry) ->
      jobs_counted(state, key, entry, generation, running)
    thread.Proposed(card_ts:, channel:, proposal:), _ ->
      State(
        ..state,
        proposals: dict.insert(state.proposals, card_ts, #(channel, proposal)),
      )
    thread.Lost, Ok(_) -> {
      sys.warn("crushling: lost the agent of " <> key <> "; stopping it")
      stop_agent(state, key)
    }
    // The agent may have been stopped while it switched: the choice still
    // counts.
    thread.ModelChosen(choice), _ ->
      update_meta(state, key, fn(meta) { Meta(..meta, model: choice) })
    _, Error(Nil) -> state
  }
}

/// Store the entry. If the thread is now quiet, start its idle timer. A later
/// change to the generation cancels the timer.
fn idle_soon(state: State, key: String, entry: Entry) -> State {
  let generation = state.generation + 1
  case is_quiet(entry) {
    True -> {
      process.send_after(
        state.self,
        state.config.idle_ms,
        IdleCheck(key, generation),
      )
      Nil
    }
    False -> Nil
  }
  // Work since the last check starts the job hold over.
  let held_since = case is_quiet(entry) {
    True -> entry.held_since
    False -> None
  }
  let entry = Entry(..entry, generation:, held_since:)
  State(..state, generation:, threads: dict.insert(state.threads, key, entry))
}

/// A quiet thread's idle time is up. Its agent may still have background
/// jobs running (a build, a server, a login waiting on someone), which crush
/// doesn't count as busy: ask the thread, and decide in `jobs_counted`.
fn idle_check(state: State, key: String, generation: Int) -> State {
  case dict.get(state.threads, key) {
    Ok(Entry(agent: Live(thread:, ..), ..) as entry)
      if entry.generation == generation
    ->
      case is_quiet(entry) {
        False -> state
        True -> {
          process.send(thread, thread.CountJobs(generation))
          // A thread busy on a slow call answers late; a wedged one never
          // does, and mustn't keep its sandbox for it.
          process.send_after(
            state.self,
            job_count_timeout_ms,
            JobsUncounted(key, generation),
          )
          let entry = Entry(..entry, counting: True)
          State(..state, threads: dict.insert(state.threads, key, entry))
        }
      }
    _ -> state
  }
}

/// The longest a quiet thread's agent is kept for its background jobs, so a
/// forgotten dev server can't hold a sandbox forever.
const max_job_hold_ms = 7_200_000

/// How long the thread gets to count its jobs before the idle stop goes ahead
/// without the count.
const job_count_timeout_ms = 30_000

/// The thread counted its running background jobs for the idle check of
/// `generation`. None: stop the agent. Some: keep it and check again later,
/// up to `max_job_hold_ms` from the first time.
fn jobs_counted(
  state: State,
  key: String,
  entry: Entry,
  generation: Int,
  running: Int,
) -> State {
  let entry = Entry(..entry, counting: False)
  let state = State(..state, threads: dict.insert(state.threads, key, entry))
  let now = sys.monotonic_ms()
  let held_since = option.unwrap(entry.held_since, now)
  case entry.generation == generation && is_quiet(entry), running {
    // Something happened since the check: its own idle timer decides.
    False, _ -> state
    True, 0 -> stop_idle(state, key, "is idle")
    True, _ if now - held_since >= max_job_hold_ms ->
      stop_idle(state, key, "has been idle with background jobs too long")
    True, _ -> {
      sys.info(
        "crushling: "
        <> key
        <> " is idle but has "
        <> int.to_string(running)
        <> " background jobs running; keeping its agent",
      )
      process.send_after(
        state.self,
        state.config.idle_ms,
        IdleCheck(key, generation),
      )
      let entry = Entry(..entry, held_since: Some(held_since))
      State(..state, threads: dict.insert(state.threads, key, entry))
    }
  }
}

fn stop_idle(state: State, key: String, why: String) -> State {
  sys.info("crushling: " <> key <> " " <> why <> "; stopping its agent")
  // A code channel stays open: going quiet isn't the work being done.
  // `!done` archives it.
  stop_agent(state, key)
}

/// Save the thread's new venue. For a new code channel, also link the channel
/// to the thread.
fn moved(
  state: State,
  key: String,
  entry: Entry,
  to: venue.Venue,
  opened_ts: String,
) -> State {
  let state = set_meta(state, key, entry, Meta(..entry.meta, venue: to))
  case to {
    venue.CodeChannel(channel:, ..) -> {
      let link =
        Link(
          origin_channel: entry.channel,
          origin_ts: entry.thread_ts,
          opened_ts:,
        )
      let threads =
        dict.upsert(state.threads, key, fn(found) {
          let entry = option.unwrap(found, entry)
          Entry(..entry, summary_ts: "")
        })
      State(
        ..state,
        threads:,
        code_channels: links.add(state.code_channels, channel, link),
      )
    }
    _ -> state
  }
}

/// Handle `!done`. Archive the code channel with the last reply as its summary,
/// and stop the agent. A later message in the thread opens a new channel.
fn done(state: State, route: Route, entry: Entry) -> State {
  let Route(incoming:, origin:, key:, ..) = route
  case entry.meta.venue, is_quiet(entry) {
    venue.CodeChannel(channel: code, repo:), True -> {
      announce(
        state.config,
        incoming,
        origin,
        "_wrapping up; this channel will be archived. Mention me in the original thread to pick the work up again._",
      )
      sys.info("crushling: archiving code channel " <> code)
      let client = state.config.client
      let summary_ts = entry.summary_ts
      process.spawn_unlinked(fn() {
        case slack.archive_code_channel(client, code, summary_ts) {
          Ok(Nil) -> Nil
          Error(reason) ->
            sys.warn("crushling: archiving " <> code <> " failed: " <> reason)
        }
      })
      // Its sink posts to the old channel. The next message starts a new
      // agent in a new channel.
      tailnet.end(
        state.tailnets,
        key,
        tailnet_view(entry),
        "_The tailnet access ended with the channel._",
      )
      |> apply_tailnet(state, key, Some(entry), _)
      |> set_meta(
        key,
        entry,
        Meta(..entry.meta, venue: venue.Archived(repo), tailnet: None),
      )
      |> stop_agent(key)
    }
    venue.CodeChannel(..), False -> {
      whisper(
        state.config,
        incoming,
        "_still working; `!stop` first, or wait for this turn to finish._",
      )
      state
    }
    _, _ -> {
      whisper(state.config, incoming, "_there's no code channel to wrap up._")
      state
    }
  }
}

fn thread_down(state: State, down: process.Down) -> State {
  let gone =
    dict.filter(state.threads, fn(_, entry) {
      case entry.agent, down {
        Live(monitor:, ..), process.ProcessDown(monitor: m, ..) -> monitor == m
        _, _ -> False
      }
    })
  dict.each(gone, fn(key, entry) {
    sys.warn("crushling: thread " <> key <> " stopped unexpectedly")
    let client = state.config.client
    process.spawn_unlinked(fn() {
      slack.say(
        client,
        entry.channel,
        entry.thread_ts,
        "_the agent for this thread stopped unexpectedly. Send a follow-up to start it again._",
      )
    })
  })
  // Nothing will clear "Working…" for a thread that died mid-run.
  dict.each(gone, fn(_, dead) {
    let client = state.config.client
    let #(channel, thread_ts) = entry.conversation(dead)
    process.spawn_unlinked(fn() {
      slack.session_done(client, channel, thread_ts)
    })
  })
  // Its container may still be running, and on the tailnet.
  dict.fold(gone, state, fn(state, key, _) { stop_agent(state, key) })
}

/// Stop a running agent and its container, keeping its workspace. The
/// entry stays, `Stopping`, until the launcher has finished; a thread still
/// starting is left to `started`, which stops it during shutdown.
fn stop_agent(state: State, key: String) -> State {
  case dict.get(state.threads, key) {
    Ok(Entry(agent: Live(thread:, monitor:), ..) as entry) -> {
      process.demonitor_process(monitor)
      process.send(thread, thread.Stop)
      run_stop(state, key)
      let tailnets = tailnet.stopped(state.tailnets, key)
      // A new generation cancels the old agent's idle timer.
      let generation = state.generation + 1
      // Nothing runs while it stops; turns it had are over.
      let entry =
        Entry(
          ..entry,
          agent: Stopping(0),
          generation:,
          in_flight: 0,
          preparing: False,
          working: False,
        )
      State(
        ..state,
        threads: dict.insert(state.threads, key, entry),
        tailnets:,
        generation:,
      )
    }
    _ -> state
  }
}

fn on_tailnet(state: State, key: String, event: tailnet.Event) -> State {
  let entry = case event {
    tailnet.Pressed(channel:, thread_ts:, ..) ->
      entry_for(state, key, channel, thread_ts) |> result.unwrap(None)
    _ -> dict.get(state.threads, key) |> option.from_result
  }
  tailnet.handle(state.tailnets, key, option.map(entry, tailnet_view), event)
  |> apply_tailnet(state, key, entry, _)
}

fn apply_tailnet(
  state: State,
  key: String,
  entry: Option(Entry),
  outcome: tailnet.Outcome,
) -> State {
  let state = State(..state, tailnets: outcome.tailnets)
  let state = case outcome.grant, entry {
    tailnet.Granted(grant), Some(entry) ->
      set_meta(state, key, entry, Meta(..entry.meta, tailnet: Some(grant)))
    tailnet.Revoked, Some(entry) ->
      set_meta(state, key, entry, Meta(..entry.meta, tailnet: None))
    _, _ -> state
  }
  case outcome.note, dict.get(state.threads, key) {
    Some(#(text, from)), Ok(Entry(agent: Live(thread:, ..), ..) as entry) -> {
      process.send(thread, thread.Prompt(text, [], from))
      let entry = Entry(..entry, in_flight: entry.in_flight + 1)
      State(..state, threads: dict.insert(state.threads, key, entry))
    }
    _, _ -> state
  }
}
