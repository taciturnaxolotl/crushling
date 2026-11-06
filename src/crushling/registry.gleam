//// Routes Slack messages to thread actors.
////
//// A mention starts a thread: the launcher brings up its agent and a
//// `thread` actor drives it. A thread started by a mention in its first
//// message (or in a DM) follows along, so every reply is a prompt; one
//// joined partway through only answers when mentioned. Each prompt is
//// prepared in order before it reaches the agent: what was said in the
//// thread since the agent last looked, and any attached files, saved into
//// the workspace. `!stop` (or Slack's Stop) cancels the current run.
////
//// A thread with nothing running for `idle_ms` has its agent stopped; its
//// workspace, session and `meta` stay, so the next message, even after a
//// restart, picks the conversation up again.

import crushling/crush/client
import crushling/launcher.{type Launcher}
import crushling/meta.{type Meta, Meta}
import crushling/sandbox
import crushling/slack
import crushling/thread
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
    /// Slack user ids allowed to drive agents.
    allowed: Set(String),
    idle_ms: Int,
    flush_ms: Int,
    mode: client.PermissionMode,
  )
}

/// A Slack message, reduced to what routing needs.
pub type Incoming {
  Incoming(
    channel: String,
    /// The thread's root; the message's own ts when it starts a thread.
    thread_ts: String,
    ts: String,
    user: String,
    text: String,
    /// Whether the bot was mentioned (or messaged directly), which may
    /// start a thread and always reaches the agent.
    mention: Bool,
    files: List(slack.Attachment),
  )
}

pub type Message {
  Received(Incoming)
  /// Someone pressed Slack's stop control on the thread's session.
  StopRequested(channel: String, thread_ts: String, user: String)
  Started(
    key: String,
    generation: Int,
    result: Result(Subject(thread.Message), String),
  )
  /// A prompt is ready to send: `ts` is the message it came from.
  Prepared(key: String, ts: String, prompt: String)
  RunFinished(key: String)
  /// Stop taking messages, let running turns finish for up to `grace_ms`,
  /// cancel what is left, stop every agent, then reply.
  Shutdown(grace_ms: Int, reply: Subject(Nil))
  /// The grace period is over.
  ShutdownDeadline
  /// Cancelled turns have had their chance to wind down.
  ShutdownFinal
  IdleCheck(key: String, generation: Int)
  ThreadDown(process.Down)
}

type Agent {
  /// The agent is launching.
  Starting
  Live(thread: Subject(thread.Message), monitor: process.Monitor)
}

type Entry {
  Entry(
    channel: String,
    thread_ts: String,
    generation: Int,
    agent: Agent,
    meta: Meta,
    /// Prompts sent and not yet finished.
    in_flight: Int,
    /// Messages waiting to be prepared, oldest first.
    backlog: List(Incoming),
    /// Whether one is being prepared now; they are prepared one at a time
    /// so each catches up from where the last left off.
    preparing: Bool,
  )
}

type State {
  State(
    config: Config,
    self: Subject(Message),
    threads: Dict(String, Entry),
    /// Recently handled message ids, so a redelivery is not run twice.
    seen: List(String),
    generation: Int,
    /// Set once shutdown begins: who to tell when it is done.
    stopping: Option(Subject(Nil)),
  )
}

/// After cancelling, how long turns get to post their closing note.
const cancel_wait_ms = 10_000

const restart_note =
  "crushling restarted, so this run was stopped. Send a follow-up to carry on."

const seen_limit = 1000

/// How many earlier thread messages a prompt carries at most.
const catch_up_limit = 10

@external(erlang, "crushling_ffi", "log_warning")
fn warn(text: String) -> Nil

@external(erlang, "crushling_ffi", "log_info")
fn info(text: String) -> Nil

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
      seen: [],
      generation: 0,
      stopping: None,
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

pub fn key(channel: String, thread_ts: String) -> String {
  sandbox.key(channel, thread_ts)
}

fn is_dm(channel: String) -> Bool {
  string.starts_with(channel, "D")
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Received(incoming) ->
      case state.stopping {
        // Draining: a new message would start work that is about to be
        // cut off. It is still in the thread, so the next turn catches up
        // on it.
        Some(_) -> actor.continue(state)
        None -> actor.continue(received(state, incoming))
      }
    Started(key, generation, result) ->
      actor.continue(started(state, key, generation, result))
    Prepared(key, ts, prompt) ->
      actor.continue(prepared(state, key, ts, prompt))
    StopRequested(channel, thread_ts, user) ->
      actor.continue(stop_requested(state, channel, thread_ts, user))
    RunFinished(key) -> {
      let state = run_finished(state, key)
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
          info("crushling: shutting down; waiting for running turns")
          process.send_after(state.self, grace_ms, ShutdownDeadline)
          actor.continue(state)
        }
      }
    }
    ShutdownDeadline -> {
      dict.each(state.threads, fn(_, entry) {
        case entry.agent, entry.in_flight > 0 {
          Live(thread:, ..), True ->
            process.send(thread, thread.CancelFor(restart_note))
          _, _ -> Nil
        }
      })
      process.send_after(state.self, cancel_wait_ms, ShutdownFinal)
      actor.continue(state)
    }
    ShutdownFinal -> finish_shutdown(state)
    IdleCheck(key, generation) ->
      actor.continue(idle_check(state, key, generation))
    ThreadDown(down) -> actor.continue(thread_down(state, down))
  }
}

/// The thread's entry: in memory, or rebuilt from its `meta` on disk for a
/// thread the bot was in before a restart or an idle stop.
fn entry_for(state: State, key: String, incoming: Incoming) -> Option(Entry) {
  case dict.get(state.threads, key) {
    Ok(entry) -> Some(entry)
    Error(Nil) -> {
      let launcher = state.config.launcher
      case launcher.exists(key) {
        False -> None
        True ->
          Some(new_entry(
            incoming,
            meta.read(launcher.meta_path(key))
              // A workspace without meta predates follow mode, when every
              // reply was a prompt.
              |> result.unwrap(Meta(follow: True, cursor: "")),
          ))
      }
    }
  }
}

fn new_entry(incoming: Incoming, meta: Meta) -> Entry {
  Entry(
    channel: incoming.channel,
    thread_ts: incoming.thread_ts,
    generation: 0,
    agent: Starting,
    meta:,
    in_flight: 0,
    backlog: [],
    preparing: False,
  )
}

fn received(state: State, incoming: Incoming) -> State {
  let config = state.config
  let id = incoming.channel <> ":" <> incoming.ts
  let key = key(incoming.channel, incoming.thread_ts)
  let prompt = slack.prompt_text(incoming.text, config.bot_user)
  let known = entry_for(state, key, incoming)
  // Whether this message is for the agent at all.
  let addressed = case known {
    Some(entry) -> incoming.mention || entry.meta.follow
    None -> incoming.mention
  }
  case
    list.contains(state.seen, id),
    addressed,
    set.contains(config.allowed, incoming.user)
  {
    True, _, _ -> state
    // Thread chatter the agent isn't following: the next turn catches up.
    _, False, _ -> state
    False, True, False -> {
      warn("crushling: ignoring " <> incoming.user <> ", not on the allowlist")
      remember(state, id)
    }
    False, True, True ->
      case slack.command(prompt), known {
        slack.SideComment, _ -> remember(state, id)
        slack.HelpCommand, _ -> {
          whisper(config, incoming, slack.help)
          remember(state, id)
        }
        slack.StopCommand, Some(Entry(agent: Live(thread:, ..), in_flight:, ..))
          if in_flight > 0
        -> {
          process.send(thread, thread.Cancel)
          remember(state, id)
        }
        slack.StopCommand, _ -> {
          whisper(config, incoming, "_nothing is running in this thread._")
          remember(state, id)
        }
        // A bare mention with nothing attached has nothing to say.
        slack.NotACommand, _ if prompt == "" && incoming.files == [] ->
          remember(state, id)
        slack.NotACommand, Some(entry) -> {
          let entry =
            Entry(..entry, backlog: list.append(entry.backlog, [incoming]))
          let state = case dict.has_key(state.threads, key) {
            True ->
              State(..state, threads: dict.insert(state.threads, key, entry))
            // Known from disk but asleep: wake its agent.
            False -> launch(state, key, entry)
          }
          remember(pump(state, key), id)
        }
        slack.NotACommand, None -> {
          let follow =
            incoming.ts == incoming.thread_ts || is_dm(incoming.channel)
          let entry =
            Entry(..new_entry(incoming, Meta(follow:, cursor: "")), backlog: [
              incoming,
            ])
          remember(launch(state, key, entry), id)
        }
      }
  }
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
  info("crushling: starting an agent for " <> key)
  let generation = state.generation + 1
  let config = state.config
  let self = state.self
  let channel = entry.channel
  let thread_ts = entry.thread_ts
  let _ = meta.write(config.launcher.meta_path(key), entry.meta)
  process.spawn_unlinked(fn() {
    let result = {
      use launched <- result.try(config.launcher.launch(key))
      let sink =
        slack.sink(config.client, channel, thread_ts, fn(finished) {
          // Turns crush starts itself, to read a subagent's report, were
          // never counted in.
          case finished.solicited {
            True -> process.send(self, RunFinished(key))
            False -> process.send(self, IdleCheck(key, -1))
          }
        })
      thread.start(thread.Config(
        socket: launched.socket,
        root: launched.root,
        title: "slack " <> channel <> " " <> thread_ts,
        sink:,
        flush_ms: config.flush_ms,
        mode: config.mode,
      ))
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
          warn("crushling: could not start " <> key <> ": " <> reason)
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
        Ok(thread) -> {
          let assert Ok(pid) = process.subject_owner(thread)
          let monitor = process.monitor(pid)
          let entry = Entry(..entry, agent: Live(thread:, monitor:))
          State(..state, threads: dict.insert(state.threads, key, entry))
          |> pump(key)
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
    Ok(
      Entry(agent: Live(..), preparing: False, backlog: [next, ..rest], ..) as entry,
    ) -> {
      let config = state.config
      let self = state.self
      let cursor = entry.meta.cursor
      process.spawn_unlinked(fn() {
        process.send(
          self,
          Prepared(key, next.ts, prepare(config, key, next, cursor)),
        )
      })
      let entry = Entry(..entry, backlog: rest, preparing: True)
      State(..state, threads: dict.insert(state.threads, key, entry))
    }
    _ -> state
  }
}

/// The prompt for `incoming`: what the thread said since `cursor`, who is
/// asking, the request, and any attached files.
fn prepare(
  config: Config,
  key: String,
  incoming: Incoming,
  cursor: String,
) -> String {
  let request = slack.prompt_text(incoming.text, config.bot_user)
  let context = case incoming.ts == incoming.thread_ts && cursor == "" {
    // The thread's first message: nothing came before.
    True -> ""
    False ->
      slack.catch_up(
        config.client,
        incoming.channel,
        incoming.thread_ts,
        cursor,
        incoming.ts,
        config.bot_user,
        catch_up_limit,
      )
  }
  let files =
    slack.save_attachments(
      config.token,
      incoming.files,
      incoming.ts,
      config.launcher.attachments(key),
    )
  let from = case is_dm(incoming.channel) {
    True -> ""
    False -> "From <@" <> incoming.user <> ">:\n"
  }
  [context, from <> request, files]
  |> list.filter(fn(part) { string.trim(part) != "" })
  |> string.join("\n\n")
}

fn prepared(state: State, key: String, ts: String, prompt: String) -> State {
  case dict.get(state.threads, key) {
    Ok(Entry(agent: Live(thread:, ..), ..) as entry) -> {
      process.send(thread, thread.Prompt(prompt))
      let meta = Meta(..entry.meta, cursor: ts)
      let _ = meta.write(state.config.launcher.meta_path(key), meta)
      let entry =
        Entry(..entry, meta:, in_flight: entry.in_flight + 1, preparing: False)
      State(..state, threads: dict.insert(state.threads, key, entry))
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
  case
    set.contains(config.allowed, user),
    dict.get(state.threads, key(channel, thread_ts))
  {
    True, Ok(Entry(agent: Live(thread:, ..), in_flight:, ..)) if in_flight > 0 ->
      process.send(thread, thread.Cancel)
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

/// Stop every thread and its agent, then let the caller know.
fn finish_shutdown(state: State) -> actor.Next(State, Message) {
  let stop = state.config.launcher.stop
  let stoppers =
    dict.to_list(state.threads)
    |> list.map(fn(pair) {
      let #(key, entry) = pair
      case entry.agent {
        Live(thread:, monitor:) -> {
          process.demonitor_process(monitor)
          process.send(thread, thread.Stop)
        }
        Starting -> Nil
      }
      let done = process.new_subject()
      process.spawn_unlinked(fn() {
        stop(key)
        process.send(done, Nil)
      })
      done
    })
  // Agents stop in parallel; each waits for its own process to exit.
  list.each(stoppers, fn(done) {
    let _ = process.receive(done, 30_000)
    Nil
  })
  info(
    "crushling: stopped " <> int.to_string(list.length(stoppers)) <> " agents",
  )
  case state.stopping {
    Some(reply) -> process.send(reply, Nil)
    None -> Nil
  }
  actor.stop()
}

fn run_finished(state: State, key: String) -> State {
  case dict.get(state.threads, key) {
    Ok(entry) -> {
      let in_flight = int.max(entry.in_flight - 1, 0)
      let generation = state.generation + 1
      case in_flight, entry.preparing, entry.backlog {
        0, False, [] -> {
          process.send_after(
            state.self,
            state.config.idle_ms,
            IdleCheck(key, generation),
          )
          Nil
        }
        _, _, _ -> Nil
      }
      let entry = Entry(..entry, in_flight:, generation:)
      State(
        ..state,
        generation:,
        threads: dict.insert(state.threads, key, entry),
      )
    }
    Error(Nil) -> state
  }
}

fn idle_check(state: State, key: String, generation: Int) -> State {
  case dict.get(state.threads, key) {
    Ok(
      Entry(
        agent: Live(thread:, monitor:),
        in_flight: 0,
        preparing: False,
        backlog: [],
        ..,
      ) as entry,
    ) ->
      case generation == -1 {
        // A turn crush started itself has ended: start the idle clock over.
        True -> {
          let generation = state.generation + 1
          process.send_after(
            state.self,
            state.config.idle_ms,
            IdleCheck(key, generation),
          )
          let entry = Entry(..entry, generation:)
          State(
            ..state,
            generation:,
            threads: dict.insert(state.threads, key, entry),
          )
        }
        False if entry.generation != generation -> state
        False ->
          // Subagents may still be working after the last prompt is done.
          case process.call(thread, 5000, thread.Busy) {
            True -> {
              process.send_after(
                state.self,
                state.config.idle_ms,
                IdleCheck(key, generation),
              )
              state
            }
            False -> {
              info("crushling: " <> key <> " is idle; stopping its agent")
              process.demonitor_process(monitor)
              process.send(thread, thread.Stop)
              let stop = state.config.launcher.stop
              process.spawn_unlinked(fn() { stop(key) })
              State(..state, threads: dict.delete(state.threads, key))
            }
          }
      }
    _ -> state
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
    warn("crushling: thread " <> key <> " stopped unexpectedly")
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
  State(..state, threads: dict.drop(state.threads, dict.keys(gone)))
}
