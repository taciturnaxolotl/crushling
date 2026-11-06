//// Routes Slack messages to thread actors. A mention starts a thread: the
//// launcher brings up its agent and a `thread` actor drives it. Replies in
//// that thread become prompts, or stop the current run when they say
//// `stop`. A thread with nothing running for `idle_ms` is stopped and its
//// agent put to sleep; its workspace and session stay, so the next message
//// picks the conversation up again.

import crushling/crush/client
import crushling/launcher.{type Launcher}
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
    /// Whether this is an `app_mention`, which may start a thread.
    mention: Bool,
  )
}

pub type Message {
  Received(Incoming)
  /// Someone pressed Slack's stop control on the thread's session.
  StopRequested(channel: String, thread_ts: String, user: String)
  Started(
    key: String,
    generation: Int,
    /// The first prompt as it should be sent, with any thread context.
    first: String,
    result: Result(Subject(thread.Message), String),
  )
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

type Entry {
  /// The agent is launching; prompts wait here, oldest first.
  Starting(
    channel: String,
    thread_ts: String,
    generation: Int,
    pending: List(String),
  )
  Live(
    channel: String,
    thread_ts: String,
    generation: Int,
    thread: Subject(thread.Message),
    monitor: process.Monitor,
    in_flight: Int,
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

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Received(incoming) ->
      case state.stopping {
        // Draining: a new message would start work that is about to be
        // cut off. It is redelivered as context the next time.
        Some(_) -> actor.continue(state)
        None -> actor.continue(received(state, incoming))
      }
    Started(key, generation, first, result) ->
      actor.continue(started(state, key, generation, first, result))
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
        case entry {
          Live(thread:, in_flight:, ..) if in_flight > 0 ->
            process.send(thread, thread.CancelFor(restart_note))
          _ -> Nil
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

fn received(state: State, incoming: Incoming) -> State {
  let config = state.config
  let id = incoming.channel <> ":" <> incoming.ts
  let key = key(incoming.channel, incoming.thread_ts)
  let prompt = slack.prompt_text(incoming.text, config.bot_user)
  let known = dict.get(state.threads, key)
  // A thread the bot is in, even one asleep or from before a restart: its
  // workspace is still on disk.
  let joined = case known {
    Ok(_) -> True
    Error(Nil) -> incoming.mention || config.launcher.exists(key)
  }
  case
    list.contains(state.seen, id),
    set.contains(config.allowed, incoming.user),
    joined
  {
    True, _, _ -> state
    // Plain replies only matter in threads the bot is in.
    _, _, False -> state
    False, False, _ -> {
      warn("crushling: ignoring " <> incoming.user <> ", not on the allowlist")
      remember(state, id)
    }
    False, True, _ if prompt == "" -> remember(state, id)
    False, True, _ ->
      case slack.command(prompt), known {
        slack.SideComment, _ -> remember(state, id)
        slack.HelpCommand, _ -> {
          let client = config.client
          process.spawn_unlinked(fn() {
            slack.whisper(
              client,
              incoming.channel,
              incoming.thread_ts,
              incoming.user,
              slack.help,
            )
          })
          remember(state, id)
        }
        slack.StopCommand, Ok(Live(thread:, in_flight:, ..)) if in_flight > 0 -> {
          process.send(thread, thread.Cancel)
          remember(state, id)
        }
        slack.StopCommand, _ -> {
          let client = config.client
          process.spawn_unlinked(fn() {
            slack.whisper(
              client,
              incoming.channel,
              incoming.thread_ts,
              incoming.user,
              "_nothing is running in this thread._",
            )
          })
          remember(state, id)
        }
        slack.NotACommand, Ok(entry) ->
          remember(deliver(state, key, entry, prompt), id)
        slack.NotACommand, Error(Nil) ->
          remember(launch(state, key, incoming, prompt), id)
      }
  }
}

fn remember(state: State, id: String) -> State {
  State(..state, seen: list.take([id, ..state.seen], seen_limit))
}

fn deliver(state: State, key: String, entry: Entry, prompt: String) -> State {
  let entry = case entry {
    Starting(..) ->
      Starting(..entry, pending: list.append(entry.pending, [prompt]))
    Live(thread:, in_flight:, ..) -> {
      process.send(thread, thread.Prompt(prompt))
      Live(..entry, in_flight: in_flight + 1)
    }
  }
  State(..state, threads: dict.insert(state.threads, key, entry))
}

fn launch(
  state: State,
  key: String,
  incoming: Incoming,
  prompt: String,
) -> State {
  let generation = state.generation + 1
  let config = state.config
  let self = state.self
  let channel = incoming.channel
  let thread_ts = incoming.thread_ts
  process.spawn_unlinked(fn() {
    // Mentioned partway into a thread: what came before is context.
    let first = case incoming.ts == thread_ts {
      True -> prompt
      False ->
        case
          slack.thread_context(
            config.client,
            channel,
            thread_ts,
            incoming.ts,
            config.bot_user,
            10,
          )
        {
          "" -> prompt
          context -> context <> "\n\nThe request:\n" <> prompt
        }
    }
    let result = {
      use launched <- result.try(config.launcher.launch(key))
      let sink =
        slack.sink(config.client, channel, thread_ts, fn(_) {
          process.send(self, RunFinished(key))
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
    process.send(self, Started(key, generation, first, result))
  })
  let entry = Starting(channel:, thread_ts:, generation:, pending: [prompt])
  State(..state, generation:, threads: dict.insert(state.threads, key, entry))
}

fn started(
  state: State,
  key: String,
  generation: Int,
  first: String,
  result: Result(Subject(thread.Message), String),
) -> State {
  case dict.get(state.threads, key), result {
    Ok(Starting(channel:, thread_ts:, pending:, ..) as entry), _
      if entry.generation == generation
    ->
      case result {
        Error(reason) -> {
          warn("crushling: could not start " <> key <> ": " <> reason)
          let client = state.config.client
          process.spawn_unlinked(fn() {
            slack.say(
              client,
              channel,
              thread_ts,
              ":warning: couldn't start an agent for this thread: " <> reason,
            )
          })
          State(..state, threads: dict.delete(state.threads, key))
        }
        Ok(thread) -> {
          let assert Ok(pid) = process.subject_owner(thread)
          let monitor = process.monitor(pid)
          let pending = case pending {
            [_, ..rest] -> [first, ..rest]
            [] -> []
          }
          list.each(pending, fn(prompt) {
            process.send(thread, thread.Prompt(prompt))
          })
          let entry =
            Live(
              channel:,
              thread_ts:,
              generation:,
              thread:,
              monitor:,
              in_flight: list.length(pending),
            )
          State(..state, threads: dict.insert(state.threads, key, entry))
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

fn stop_requested(
  state: State,
  channel: String,
  thread_ts: String,
  user: String,
) -> State {
  let config = state.config
  case
    set.contains(config.allowed, user),
    dict.get(state.threads, key(channel, thread_ts))
  {
    True, Ok(Live(thread:, in_flight:, ..)) if in_flight > 0 ->
      process.send(thread, thread.Cancel)
    False, _ -> {
      let client = config.client
      process.spawn_unlinked(fn() {
        slack.whisper(
          client,
          channel,
          thread_ts,
          user,
          "_only the people this agent works for can stop it._",
        )
      })
      Nil
    }
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
  |> list.any(fn(entry) {
    case entry {
      Live(in_flight:, ..) -> in_flight > 0
      Starting(..) -> False
    }
  })
}

/// Stop every thread and its agent, then let the caller know.
fn finish_shutdown(state: State) -> actor.Next(State, Message) {
  let stop = state.config.launcher.stop
  let stoppers =
    dict.to_list(state.threads)
    |> list.map(fn(pair) {
      let #(key, entry) = pair
      case entry {
        Live(thread:, monitor:, ..) -> {
          process.demonitor_process(monitor)
          process.send(thread, thread.Stop)
        }
        Starting(..) -> Nil
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
    Ok(Live(in_flight:, ..) as entry) -> {
      let in_flight = int.max(in_flight - 1, 0)
      let generation = state.generation + 1
      case in_flight {
        0 -> {
          process.send_after(
            state.self,
            state.config.idle_ms,
            IdleCheck(key, generation),
          )
          Nil
        }
        _ -> Nil
      }
      let entry = Live(..entry, in_flight:, generation:)
      State(
        ..state,
        generation:,
        threads: dict.insert(state.threads, key, entry),
      )
    }
    _ -> state
  }
}

fn idle_check(state: State, key: String, generation: Int) -> State {
  case dict.get(state.threads, key) {
    Ok(Live(thread:, monitor:, in_flight: 0, ..) as entry)
      if entry.generation == generation
    -> {
      info("crushling: " <> key <> " is idle; stopping its agent")
      process.demonitor_process(monitor)
      process.send(thread, thread.Stop)
      let stop = state.config.launcher.stop
      process.spawn_unlinked(fn() { stop(key) })
      State(..state, threads: dict.delete(state.threads, key))
    }
    _ -> state
  }
}

fn thread_down(state: State, down: process.Down) -> State {
  let gone =
    dict.filter(state.threads, fn(_, entry) {
      case entry, down {
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
        ":warning: the agent for this thread stopped unexpectedly; mention me to start it again.",
      )
    })
  })
  State(..state, threads: dict.drop(state.threads, dict.keys(gone)))
}
