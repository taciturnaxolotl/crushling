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
import gleam/float
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
  /// The thread posted a reply; its last message is `ts`.
  Replied(key: String, ts: String)
  /// The thread's work moved to code channel `channel`, for the repository
  /// in workspace directory `repo`.
  Moved(
    key: String,
    channel: String,
    repo: String,
    opened_ts: String,
    reply: Subject(Nil),
  )
  /// Stop taking messages, let running turns finish for up to `grace_ms`,
  /// cancel what is left, stop every agent, then reply.
  Shutdown(grace_ms: Int, reply: Subject(Nil))
  /// The grace period is over.
  ShutdownDeadline
  /// Cancelled turns have had their chance to wind down.
  ShutdownFinal
  IdleCheck(key: String, generation: Int)
  ThreadDown(process.Down)
  /// The thread actor for `key`, if its agent is up: for the agent's own
  /// Slack tools.
  Lookup(key: String, reply: Subject(Option(Subject(thread.Message))))
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
    /// The last reply posted, to keep as a code channel's summary when it
    /// is archived.
    summary_ts: String,
  )
}

type CodeChannel {
  CodeChannel(origin: #(String, String), opened_ts: String)
}

type State {
  State(
    config: Config,
    self: Subject(Message),
    threads: Dict(String, Entry),
    /// Code channels, each to the thread (channel and ts) whose work it
    /// holds, and when it was opened.
    code_channels: Dict(String, CodeChannel),
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

@external(erlang, "crushling_ffi", "system_ms")
fn system_ms() -> Int

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
      code_channels: dict.new(),
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
    Replied(key, ts) -> actor.continue(replied(state, key, ts))
    Moved(key, channel, repo, opened_ts, reply) -> {
      let state = moved(state, key, channel, repo, opened_ts)
      process.send(reply, Nil)
      actor.continue(state)
    }
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
    Lookup(key, reply) -> {
      process.send(reply, case dict.get(state.threads, key) {
        Ok(Entry(agent: Live(thread:, ..), ..)) -> Some(thread)
        _ -> None
      })
      actor.continue(state)
    }
  }
}

/// The thread's entry: in memory, or rebuilt from its `meta` on disk for a
/// thread the bot was in before a restart or an idle stop.
fn entry_for(
  state: State,
  key: String,
  channel: String,
  thread_ts: String,
) -> Option(Entry) {
  case dict.get(state.threads, key) {
    Ok(entry) -> Some(entry)
    Error(Nil) -> {
      let launcher = state.config.launcher
      case launcher.exists(key) {
        False -> None
        True ->
          Some(new_entry(
            channel,
            thread_ts,
            meta.read(launcher.meta_path(key))
              // A workspace without meta predates follow mode, when every
              // reply was a prompt.
              |> result.unwrap(meta.new(True)),
          ))
      }
    }
  }
}

fn new_entry(channel: String, thread_ts: String, meta: Meta) -> Entry {
  Entry(
    channel:,
    thread_ts:,
    generation: 0,
    agent: Starting,
    meta:,
    in_flight: 0,
    backlog: [],
    preparing: False,
    summary_ts: "",
  )
}

/// Where a code channel's own `meta` lives: it names the thread the channel
/// belongs to, so its messages still find that thread after a restart.
fn code_channel_key(channel: String) -> String {
  key(channel, "code")
}

/// The thread a code channel holds the work of, if `channel` is one.
fn code_channel_origin(
  state: State,
  channel: String,
) -> #(State, Option(#(String, String))) {
  let #(state, found) = code_channel(state, channel)
  #(state, option.map(found, fn(code) { code.origin }))
}

fn code_channel(
  state: State,
  channel: String,
) -> #(State, Option(CodeChannel)) {
  case dict.get(state.code_channels, channel) {
    Ok(code) -> #(state, Some(code))
    Error(Nil) -> {
      let path = state.config.launcher.meta_path(code_channel_key(channel))
      case meta.read(path) {
        // A code channel's meta keeps when it was opened as its cursor.
        Ok(Meta(origin_channel:, origin_ts:, cursor:, ..))
          if origin_channel != ""
        -> {
          let code = CodeChannel(#(origin_channel, origin_ts), cursor)
          let code_channels = dict.insert(state.code_channels, channel, code)
          #(State(..state, code_channels:), Some(code))
        }
        _ -> #(state, None)
      }
    }
  }
}

/// Whether a message is the copy of the request Slack seeds a new code
/// channel with: anything there older than the channel's opening.
fn is_seed(code: Option(CodeChannel), ts: String) -> Bool {
  case code {
    Some(CodeChannel(opened_ts:, ..)) if opened_ts != "" ->
      slack.ts_value(ts) <=. slack.ts_value(opened_ts) +. 1.0
    _ -> False
  }
}

fn received(state: State, incoming: Incoming) -> State {
  let config = state.config
  let id = incoming.channel <> ":" <> incoming.ts
  // A message in a code channel belongs to the thread that moved there.
  let #(state, code) = code_channel(state, incoming.channel)
  let origin = option.map(code, fn(code) { code.origin })
  let #(channel, thread_ts) =
    option.unwrap(origin, #(incoming.channel, incoming.thread_ts))
  let key = key(channel, thread_ts)
  let prompt = slack.prompt_text(incoming.text, config.bot_user)
  let known = entry_for(state, key, channel, thread_ts)
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
    list.contains(state.seen, id) || is_seed(code, incoming.ts),
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
      case command, known {
        slack.SideComment, _ -> remember(state, id)
        slack.PauseCommand, Some(entry) -> {
          let state =
            set_meta(state, key, entry, Meta(..entry.meta, paused: True))
          announce(
            config,
            incoming,
            origin,
            "_paused: I'll only answer when mentioned. `!resume` to have me follow along again._",
          )
          remember(state, id)
        }
        slack.ResumeCommand, Some(entry) -> {
          let state =
            set_meta(
              state,
              key,
              entry,
              Meta(..entry.meta, paused: False, follow: True),
            )
          announce(
            config,
            incoming,
            origin,
            "_following along again: every message here reaches me._",
          )
          remember(state, id)
        }
        slack.PauseCommand, None | slack.ResumeCommand, None -> {
          whisper(config, incoming, "_I'm not working in this thread._")
          remember(state, id)
        }
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
            Entry(
              ..new_entry(
                incoming.channel,
                incoming.thread_ts,
                meta.new(follow),
              ),
              backlog: [incoming],
            )
          remember(launch(state, key, entry), id)
        }
      }
  }
}

/// Change a thread's meta, whether its agent is up or asleep on disk.
fn set_meta(state: State, key: String, entry: Entry, meta: Meta) -> State {
  let _ = meta.write(state.config.launcher.meta_path(key), meta)
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
  info("crushling: starting an agent for " <> key)
  let generation = state.generation + 1
  let config = state.config
  let self = state.self
  let channel = entry.channel
  let thread_ts = entry.thread_ts
  let meta = entry.meta
  let _ = meta.write(config.launcher.meta_path(key), meta)
  process.spawn_unlinked(fn() {
    let result = {
      use launched <- result.try(config.launcher.launch(key))
      let hooks =
        slack.Hooks(
          finished: fn(finished) {
            case finished.reply_ts {
              "" -> Nil
              ts -> process.send(self, Replied(key, ts))
            }
            // Turns crush starts itself, to read a subagent's report, were
            // never counted in.
            case finished.solicited {
              True -> process.send(self, RunFinished(key))
              False -> process.send(self, IdleCheck(key, -1))
            }
          },
          moved: fn(code, repo) {
            // Slack seeds a new code channel with a copy of the request;
            // anything there from before now is that copy. Waiting for the
            // registry makes sure it knows the channel before the copy's
            // event arrives.
            let opened_ts = float.to_string(int.to_float(system_ms()) /. 1000.0)
            let reply = process.new_subject()
            process.send(self, Moved(key, code, repo, opened_ts, reply))
            let _ = process.receive(reply, 5000)
            Nil
          },
        )
      let sink = case meta.code_channel {
        "" ->
          slack.sink(config.client, channel, slack.InThread(thread_ts), hooks)
        code -> slack.sink(config.client, code, slack.InCodeChannel, hooks)
      }
      thread.start(thread.Config(
        socket: launched.socket,
        root: launched.root,
        title: "slack " <> channel <> " " <> thread_ts,
        sink:,
        flush_ms: config.flush_ms,
        mode: config.mode,
        repo: meta.repo,
        in_code_channel: meta.code_channel != "",
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
      // A code channel is caught up on as a whole, not by thread.
      let catch_up = case next.channel == entry.channel {
        True -> next.thread_ts
        False -> ""
      }
      process.spawn_unlinked(fn() {
        process.send(
          self,
          Prepared(key, next.ts, prepare(config, key, next, cursor, catch_up)),
        )
      })
      let entry = Entry(..entry, backlog: rest, preparing: True)
      State(..state, threads: dict.insert(state.threads, key, entry))
    }
    _ -> state
  }
}

/// The prompt for `incoming`: what was said since `cursor`, who is asking,
/// the request, and any attached files. `catch_up` is the thread to catch
/// up on, or "" for the whole of a code channel.
fn prepare(
  config: Config,
  key: String,
  incoming: Incoming,
  cursor: String,
  catch_up: String,
) -> String {
  let request = slack.prompt_text(incoming.text, config.bot_user)
  let first =
    catch_up != "" && incoming.ts == incoming.thread_ts && cursor == ""
  let context = case first {
    // The thread's first message: nothing came before.
    True -> ""
    False ->
      slack.catch_up(
        config.client,
        incoming.channel,
        catch_up,
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
  // A code channel's session has no thread.
  let #(state, origin) = case thread_ts {
    "" -> code_channel_origin(state, channel)
    _ -> #(state, None)
  }
  let key = case origin {
    Some(#(origin_channel, origin_ts)) -> key(origin_channel, origin_ts)
    None -> key(channel, thread_ts)
  }
  case set.contains(config.allowed, user), dict.get(state.threads, key) {
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
              archive(state, key, entry)
              |> fn(state) {
                State(..state, threads: dict.delete(state.threads, key))
              }
            }
          }
      }
    _ -> state
  }
}

fn replied(state: State, key: String, ts: String) -> State {
  case dict.get(state.threads, key) {
    Ok(entry) -> {
      let entry = Entry(..entry, summary_ts: ts)
      State(..state, threads: dict.insert(state.threads, key, entry))
    }
    Error(Nil) -> state
  }
}

fn moved(
  state: State,
  key: String,
  channel: String,
  repo: String,
  opened_ts: String,
) -> State {
  case dict.get(state.threads, key) {
    Ok(entry) -> {
      let launcher = state.config.launcher
      let meta = Meta(..entry.meta, code_channel: channel, repo:)
      let _ = meta.write(launcher.meta_path(key), meta)
      let _ =
        meta.write(
          launcher.meta_path(code_channel_key(channel)),
          Meta(
            ..meta.new(True),
            cursor: opened_ts,
            origin_channel: entry.channel,
            origin_ts: entry.thread_ts,
          ),
        )
      let entry = Entry(..entry, meta:, summary_ts: "")
      State(
        ..state,
        threads: dict.insert(state.threads, key, entry),
        code_channels: dict.insert(
          state.code_channels,
          channel,
          CodeChannel(#(entry.channel, entry.thread_ts), opened_ts),
        ),
      )
    }
    Error(Nil) -> state
  }
}

/// Archive the thread's code channel, if it has one: its work is done for
/// now. A later message in the thread picks it up in a new channel.
fn archive(state: State, key: String, entry: Entry) -> State {
  case entry.meta.code_channel {
    "" -> state
    code -> {
      info("crushling: archiving code channel " <> code)
      let client = state.config.client
      let summary_ts = entry.summary_ts
      process.spawn_unlinked(fn() {
        case slack.archive_code_channel(client, code, summary_ts) {
          Ok(Nil) -> Nil
          Error(reason) ->
            warn("crushling: archiving " <> code <> " failed: " <> reason)
        }
      })
      let meta = Meta(..entry.meta, code_channel: "")
      let _ = meta.write(state.config.launcher.meta_path(key), meta)
      State(..state, code_channels: dict.delete(state.code_channels, code))
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
