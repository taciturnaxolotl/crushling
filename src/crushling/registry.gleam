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

import crushling/crush/client
import crushling/launcher.{type Launcher}
import crushling/meta.{type Link, type Meta, Link, Meta}
import crushling/registry/entry.{
  type Entry, Entry, Live, Starting, Stopping, already_read, is_quiet,
  new as new_entry, tailnet_view,
}
import crushling/registry/incoming.{type Incoming, Incoming, is_dm}
import crushling/registry/links.{type Links}
import crushling/registry/prompt
import crushling/registry/tailnet
import crushling/sandbox
import crushling/slack
import crushling/store.{type Store}
import crushling/sys
import crushling/thread
import crushling/venue
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import gleam/string
import slackline

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
    /// Slack user ids allowed to drive agents.
    allowed: Set(String),
    /// Slack user ids who may approve tailnet access; when empty, everyone
    /// allowed may.
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
  )
}

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
        approvers(config),
        fn(key, event, after_ms) {
          process.send_after(self, after_ms, Tailnet(key, event))
          Nil
        },
      ),
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

/// Who may approve tailnet access.
fn approvers(config: Config) -> Set(String) {
  case set.is_empty(config.admins) {
    True -> config.allowed
    False -> config.admins
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
    ThreadDown(down) -> actor.continue(thread_down(state, down))
    Tailnet(key, event) -> actor.continue(on_tailnet(state, key, event))
    Lookup(key, reply) -> {
      process.send(reply, case dict.get(state.threads, key) {
        Ok(Entry(agent: Live(thread:, ..), ..)) -> Some(thread)
        _ -> None
      })
      actor.continue(state)
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
    set.contains(config.allowed, incoming.user)
  {
    True, _, _ -> state
    // Thread chatter the agent isn't following: the next turn catches up.
    _, False, _ -> state
    False, True, False -> {
      sys.warn(
        "crushling: ignoring " <> incoming.user <> ", not on the allowlist",
      )
      remember(state, id)
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
    slack.PauseCommand, None
    | slack.ResumeCommand, None
    | slack.DoneCommand, None
    | slack.TailnetCommand(..), None
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
  case known {
    Some(entry) -> {
      let entry =
        Entry(..entry, backlog: list.append(entry.backlog, [incoming]))
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
        )
      launch(state, route.key, entry)
    }
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
        venue.CodeChannel(channel: code, ..) ->
          slack.sink(config.client, config.team, code, slack.InCodeChannel)
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
          let entry = Entry(..entry, agent: Live(thread:, monitor:))
          State(..state, threads: dict.insert(state.threads, key, entry))
          |> pump(key)
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
  case set.contains(config.allowed, user), dict.get(state.threads, key) {
    True, Ok(Entry(agent: Live(thread:, ..), ..) as entry)
      if entry.in_flight > 0 || entry.working
    -> process.send(thread, thread.Cancel(None))
    False, _ ->
      whisper(
        config,
        incoming,
        "_only the people this agent works for can stop it._",
      )
    // Nothing running here, so the session shouldn't say it is.
    True, _ -> {
      let client = config.client
      process.spawn_unlinked(fn() {
        slack.session_done(client, channel, thread_ts)
      })
      Nil
    }
  }
  state
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
      case entry.backlog, state.finishing {
        [_, ..], False ->
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
  let entry = Entry(..entry, generation:)
  State(..state, generation:, threads: dict.insert(state.threads, key, entry))
}

fn idle_check(state: State, key: String, generation: Int) -> State {
  case dict.get(state.threads, key) {
    Ok(Entry(agent: Live(..), ..) as entry) if entry.generation == generation ->
      case is_quiet(entry) {
        False -> state
        True -> {
          sys.info("crushling: " <> key <> " is idle; stopping its agent")
          // A code channel stays open: going quiet isn't the work being
          // done. `!done` archives it.
          stop_agent(state, key)
        }
      }
    _ -> state
  }
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
