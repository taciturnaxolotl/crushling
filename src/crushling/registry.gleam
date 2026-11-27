//// Routes one Slack workspace's messages to its threads' agents.
////
//// A mention starts a thread, whose agent runs in its own sandbox driven by
//// a `thread` actor (`registry/lifecycle`). Messages are prepared into
//// prompts in order (`registry/backlog`), and a quiet agent is stopped while
//// its workspace and `meta` stay, so the next message picks the work up.

import crushling/commands
import crushling/connections
import crushling/conversation.{Conversation}
import crushling/github/route as github_route
import crushling/meta.{type Link, Meta}
import crushling/models
import crushling/registry/accounts.{type HomeAsk, Connect, ShowHome, show_home}
import crushling/registry/backlog.{prepared, pump}
import crushling/registry/code_channel
import crushling/registry/config.{type Config}
import crushling/registry/core.{
  type Event, Deferred, FromThread, GitHubNudgeTo, IdleCheck, JobsUncounted,
  Member, PrSettled, Prepared, RetryStop, ShutdownDeadline, ShutdownFinal,
  ShutdownGiveUp, Started, State, Stopped, Sweep, TailnetLater, ThreadDown,
  apply_tailnet, busy, entry_for, key, put, set_meta,
}
import crushling/registry/entry.{
  type Entry, Asleep, Entry, Live, Starting, Stopping, Turn, already_read,
  map_turn, new as new_entry, tailnet_view,
}
import crushling/registry/gate
import crushling/registry/incoming.{type Incoming, Incoming, is_dm}
import crushling/registry/lifecycle.{
  idle_check, idle_soon, jobs_counted, jobs_uncounted, launch, started,
  stop_agent, stopped, thread_down,
}
import crushling/registry/links
import crushling/registry/say.{announce, whisper}
import crushling/registry/shutdown.{type ShutdownOutcome}
import crushling/registry/sweep
import crushling/registry/tailnet
import crushling/registry/text
import crushling/slack
import crushling/sys
import crushling/thread
import gleam/bool
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set
import gleam/string

pub const default_stop_backoff_ms = config.default_stop_backoff_ms

pub const github_access_ms = accounts.github_access_ms

pub type Message {
  Received(Incoming)
  /// Someone pressed Slack's stop control on the thread's session.
  StopRequested(channel: String, thread_ts: String, user: String)
  /// Drain running turns for `grace_ms`, stop every agent, then reply within `shutdown.budget_ms(grace_ms)`.
  Shutdown(grace_ms: Int, reply: Subject(ShutdownOutcome))
  /// A card press or an agent's request about tailnet access for thread `key`.
  Tailnet(key: String, event: tailnet.Event)
  /// Thread `key`'s actor, if its agent is up, for the agent's own Slack tools.
  Lookup(key: String, reply: Subject(Option(Subject(thread.Message))))
  /// `user` opened the App Home.
  HomeOpened(user: String)
  /// Connect or disconnect `user`'s GitHub account, from the App Home.
  GitHubConnect(user: String)
  GitHubDisconnect(user: String)
  /// A PR card button: open the PR (maybe as a draft) or dismiss it; `respond` answers privately.
  PrPressed(
    user: String,
    card_ts: String,
    choice: String,
    respond: Option(String),
  )
  /// A slash command in a code channel, heard as the `!` command `text` from `user`.
  Slash(channel: String, user: String, text: String)
  /// `user` pressed Connect on the note asking them, in a thread.
  GitHubConnectIn(user: String, place: connections.Place)
  /// Thread `key`'s agent lacked a GitHub connection: ask whoever it works for, now and then.
  GitHubNudge(key: String, want: github_route.Want)
  /// The GitHub token thread `key`'s agent reads with: its requester's, if connected.
  GitHubAccess(key: String, reply: Subject(Result(Option(String), String)))
  /// A pick on a model card; `home` is the thread, since the card may sit elsewhere.
  ModelPicked(
    home: #(String, String),
    pick: models.Pick,
    card: meta.Card,
    user: String,
  )
  /// The registry's own callbacks and timers, which nothing else can send.
  Internal(Internal)
}

/// The registry's own callbacks and timers, which nothing else can send.
pub opaque type Internal {
  Own(Event)
}

/// A notice from thread `key`'s actor, as if it had sent it: for tests.
@internal
pub fn notice(key: String, notice: thread.Notice) -> Message {
  Internal(Own(FromThread(key, notice)))
}

/// The registry's state, as its modules share it.
type State =
  core.State(Message)

const seen_limit = 1000

pub fn start(config: Config) -> Result(Subject(Message), actor.StartError) {
  actor.new_with_initialiser(1000, fn(self) {
    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select_monitors(fn(down) { Internal(Own(ThreadDown(down))) })
    // The first sweep a minute in, once the bridge has settled.
    process.send_after(self, 60_000, Internal(Own(Sweep)))
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
      wrap: fn(event) { Internal(Own(event)) },
      threads: dict.new(),
      code_channels: links.new(config.store, config.team),
      opening: set.new(),
      seen: [],
      launches: 0,
      ticks: 0,
      lifecycle: shutdown.Serving,
      abandoned: [],
      broken: set.new(),
      tailnets: tailnet.new(
        config.tailnet,
        config.client,
        gate.approvers(config.allowed, config.admins),
        fn(key, event, after_ms) {
          process.send_after(
            self,
            after_ms,
            Internal(Own(TailnetLater(key, event))),
          )
          Nil
        },
      ),
      gate: gate.new(config.allowed, config.client, config.team, fn(answer, ms) {
        process.send_after(self, ms, Internal(Own(Member(answer))))
        Nil
      }),
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

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Internal(Own(event)) -> own(state, event)
    Shutdown(grace_ms, reply) -> {
      let state = State(..state, lifecycle: shutdown.Draining(reply))
      case busy(state) {
        False -> finish_shutdown(state)
        True -> {
          sys.info("crushling: shutting down; waiting for running turns")
          core.tell_after(state, grace_ms, ShutdownDeadline)
          actor.continue(state)
        }
      }
    }
    _ -> actor.continue(serve(state, message))
  }
}

/// The registry's own events.
fn own(state: State, event: Event) -> actor.Next(State, Message) {
  case event {
    Deferred(incoming, attempts) ->
      case shutdown.is_serving(state.lifecycle) {
        True -> actor.continue(received(state, incoming, attempts))
        False -> actor.continue(state)
      }
    Started(key, launch, result) ->
      started(state, key, launch, result) |> continue_or_finish
    Stopped(key, result) -> stopped(state, key, result) |> continue_or_finish
    RetryStop(key) -> {
      lifecycle.retry_stop(state, key)
      actor.continue(state)
    }
    Prepared(key, ts, prompt) ->
      actor.continue(prepared(state, key, ts, prompt))
    FromThread(key, notice) -> {
      let state = from_thread(state, key, notice)
      case shutdown.is_serving(state.lifecycle) || busy(state) {
        False -> finish_shutdown(state)
        True -> actor.continue(state)
      }
    }
    ShutdownDeadline -> {
      dict.each(state.threads, fn(_, entry) {
        case entry.agent {
          Live(thread:, turn:, ..) if turn.in_flight > 0 ->
            process.send(thread, thread.Cancel(Some(text.restart_note)))
          _ -> Nil
        }
      })
      core.tell_after(state, shutdown.cancel_wait_ms, ShutdownFinal)
      actor.continue(state)
    }
    ShutdownFinal -> finish_shutdown(state)
    ShutdownGiveUp -> {
      sys.warn(
        "crushling: shutting down with "
        <> int.to_string(dict.size(state.threads))
        <> " agents still starting or stopping",
      )
      done_shutting_down(state, shutdown.TimedOut)
    }
    IdleCheck(key, token) -> actor.continue(idle_check(state, key, token))
    Sweep -> {
      core.tell_after(state, sweep.every_ms, Sweep)
      actor.continue(sweep.run(state))
    }
    PrSettled(card_ts) ->
      actor.continue(
        State(..state, proposals: dict.delete(state.proposals, card_ts)),
      )
    GitHubNudgeTo(key, user, want) ->
      actor.continue(accounts.nudge(state, key, user, want))
    JobsUncounted(key, token) ->
      actor.continue(jobs_uncounted(state, key, token))
    ThreadDown(down) -> actor.continue(thread_down(state, down))
    Member(answer) -> {
      let #(gate, waiting) = gate.answered(state.gate, answer)
      let state = list.fold(waiting, State(..state, gate:), serve)
      actor.continue(
        State(..state, gate: gate.forget_failed(state.gate, answer)),
      )
    }
    TailnetLater(key, event) -> actor.continue(on_tailnet(state, key, event))
  }
}

/// Whether `message` is from someone in Slack and turned away while shutting down; a stop is still heard while turns drain.
fn from_user(message: Message, lifecycle: shutdown.Lifecycle) -> Bool {
  case lifecycle, message {
    shutdown.Serving, _ -> False
    shutdown.Draining(..), StopRequested(..) -> False
    _, Received(..)
    | _, StopRequested(..)
    | _, Slash(..)
    | _, ModelPicked(..)
    | _, Tailnet(event: tailnet.Pressed(..), ..)
    | _, HomeOpened(..)
    | _, GitHubConnect(..)
    | _, GitHubConnectIn(..)
    | _, GitHubDisconnect(..)
    | _, PrPressed(..)
    -> True
    _, _ -> False
  }
}

/// Requests from Slack and the agents, including ones that waited on a membership lookup.
fn serve(state: State, message: Message) -> State {
  // New work would be cut off; the next turn catches up from the thread.
  use <- bool.guard(from_user(message, state.lifecycle), state)
  case message {
    Received(incoming) -> received(state, incoming, 0)
    StopRequested(channel, thread_ts, user) ->
      stop_requested(state, channel, thread_ts, user)
    HomeOpened(user) -> home_ask(state, message, user, ShowHome)
    GitHubConnect(user) -> home_ask(state, message, user, Connect(None))
    GitHubConnectIn(user, place) ->
      home_ask(state, message, user, Connect(Some(place)))
    GitHubDisconnect(user) -> {
      process.send(state.connections, connections.Disconnect(user, None))
      state
    }
    PrPressed(user:, card_ts:, choice:, respond:) -> {
      let say = accounts.responder(respond)
      use card <- accounts.with_proposal(state, card_ts, say)
      use <- admit(state, user, message, fn() {
        say(text.cant_use)
        state
      })
      accounts.press(state, user, card_ts, choice, card, say)
    }
    Slash(channel:, user:, text:) -> {
      // Said at the top of the channel, now, and heard as if mentioned.
      let ms = sys.system_ms()
      let ts =
        int.to_string(ms / 1000)
        <> "."
        <> string.pad_start(int.to_string(ms % 1000 * 1000), 6, "0")
      received(state, Incoming(channel, "", ts, user, text, True, []), 0)
    }
    GitHubNudge(key, want) -> {
      accounts.nudge_who(state, key, want)
      state
    }
    // Joins and timers come only from the registry itself.
    Tailnet(event: tailnet.JoinDone(..), ..)
    | Tailnet(event: tailnet.Tick, ..) -> state
    Tailnet(key, event) -> on_tailnet(state, key, event)
    Lookup(key, reply) -> {
      process.send(reply, case dict.get(state.threads, key) {
        Ok(Entry(agent: Live(thread:, ..), ..)) -> Some(thread)
        _ -> None
      })
      state
    }
    GitHubAccess(key, reply) -> {
      accounts.github_access(state, key, reply)
      state
    }
    ModelPicked(home, pick, card, user) ->
      model_picked(state, home, pick, card, user)
    Shutdown(..) | Internal(..) -> state
  }
}

/// Go on if `user` may drive agents; an unknown member's `message` waits for the lookup and comes back through `serve`.
fn admit(
  state: State,
  user: String,
  message: Message,
  denied: fn() -> State,
  next: fn() -> State,
) -> State {
  case gate.check(state.gate, user, message) {
    gate.Allowed -> next()
    gate.Denied -> denied()
    gate.Waiting(gate) -> State(..state, gate:)
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
    Ok(known) -> {
      use <- code_channel.hold(state, incoming, known, attempts)
      route(state, incoming, code, origin, key, known)
    }
    Error(_) -> broken(state, key, incoming)
  }
}

/// A thread that can't be loaded is said so once, since a fresh one would hide its old work.
fn broken(state: State, key: String, incoming: Incoming) -> State {
  case set.contains(state.broken, key) {
    True -> state
    False -> {
      say.post(
        state.config.client,
        conversation.from_slack(incoming.channel, incoming.thread_ts),
        text.broken_thread,
      )
      State(..state, broken: set.insert(state.broken, key))
    }
  }
}

/// A message addressed to a thread; `known` is its entry if the bot already works there.
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
  let command = commands.parse(prompt)
  // In a code channel everyone talks to the agent; a paused agent hears only mentions and `!resume`.
  let addressed = case known, origin {
    _, _ if incoming.mention -> True
    Some(_), _ if command == commands.ResumeCommand -> True
    Some(Entry(meta: Meta(paused: True, ..), ..)), _ -> False
    Some(_), Some(_) -> True
    Some(entry), None -> entry.meta.follow
    None, _ -> False
  }
  case
    list.contains(state.seen, id)
    || links.is_seed(code, incoming.ts)
    || already_read(known, incoming.ts),
    addressed
  {
    True, _ -> state
    // Thread chatter the agent isn't following: the next turn catches up.
    _, False -> state
    False, True -> {
      use <- admit(state, incoming.user, Received(incoming), fn() {
        sys.warn(
          "crushling: ignoring " <> incoming.user <> ", not on the allowlist",
        )
        remember(state, id)
      })
      Route(incoming:, origin:, key:, known:, prompt:)
      |> act(state, _, command)
      |> remember(id)
    }
  }
}

/// Do what a message asks for.
fn act(state: State, route: Route, command: commands.Command) -> State {
  let config = state.config
  case command, route.known {
    commands.SideComment, _ -> state
    // Works anywhere the bot hears it, with or without an agent.
    commands.GitHubCommand(connect:), _ -> {
      let user = route.incoming.user
      let from =
        Some(connections.Place(
          route.incoming.channel,
          route.incoming.thread_ts,
          None,
        ))
      case connect {
        True -> show_home(state, user, Connect(from), True)
        False -> {
          process.send(state.connections, connections.Disconnect(user, from))
          state
        }
      }
    }
    commands.HelpCommand, _ -> {
      whisper(config, route.incoming, commands.help())
      state
    }
    commands.PauseCommand, Some(entry) -> {
      announce(
        config,
        route.incoming,
        route.origin,
        "_paused: I'll only answer when mentioned. `!resume` to have me follow along again._",
      )
      set_meta(state, route.key, entry, Meta(..entry.meta, paused: True))
    }
    commands.ResumeCommand, Some(entry) -> {
      announce(
        config,
        route.incoming,
        route.origin,
        "_following along again: every message here reaches me._",
      )
      let meta = Meta(..entry.meta, paused: False, follow: True)
      set_meta(state, route.key, entry, meta)
    }
    commands.DoneCommand, Some(entry) -> done(state, route, entry)
    commands.PrCommand(title), Some(entry) -> {
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
    commands.InfoCommand, Some(Entry(agent: Live(thread:, ..), ..)) -> {
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
    commands.InfoCommand, Some(_) -> {
      whisper(
        config,
        route.incoming,
        "_The agent is asleep; send a message to wake it, then ask again._",
      )
      state
    }
    commands.StopCommand, Some(Entry(agent: Live(thread:, turn:, ..), ..))
      if turn.in_flight > 0 || turn.working
    -> {
      process.send(thread, thread.Cancel(None))
      state
    }
    commands.StopCommand, _ -> {
      whisper(config, route.incoming, "_nothing is running in this thread._")
      state
    }
    commands.TailnetCommand(on: True), Some(entry) -> {
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
    commands.TailnetCommand(on: False), Some(entry) ->
      tailnet.end(
        state.tailnets,
        route.key,
        tailnet_view(entry),
        "_<@" <> route.incoming.user <> "> took the sandbox off the tailnet._",
      )
      |> apply_tailnet(state, route.key, Some(entry), _)
    commands.ModelCommand(argument), Some(entry) ->
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
    commands.PauseCommand, None
    | commands.ResumeCommand, None
    | commands.DoneCommand, None
    | commands.InfoCommand, None
    | commands.PrCommand(..), None
    | commands.TailnetCommand(..), None
    | commands.ModelCommand(..), None
    -> {
      whisper(config, route.incoming, "_I'm not working in this thread._")
      state
    }
    // A bare mention with nothing attached has nothing to say.
    commands.NotACommand, _
      if route.prompt == "" && route.incoming.files == []
    -> state
    commands.NotACommand, known -> queue(state, route, known)
  }
}

/// Queue a prompt, and wake or start the thread's agent.
fn queue(state: State, route: Route, known: Option(Entry)) -> State {
  let incoming = route.incoming
  // "Working…" now, not once the agent is up and the prompt is ready.
  let client = state.config.client
  let place = case known {
    Some(entry) -> entry.conversation(entry)
    None -> Conversation(incoming.channel, Some(incoming.thread_ts))
  }
  process.spawn_unlinked(fn() { slack.mark_working(client, place) })
  case known {
    Some(entry) -> {
      let entry =
        Entry(
          ..entry,
          backlog: list.append(entry.backlog, [incoming]),
          people: set.insert(entry.people, incoming.user),
        )
      case entry.agent {
        Asleep -> launch(state, route.key, entry)
        _ -> put(state, route.key, entry)
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

/// Hand the thread actor a message now, once it is up, or after waking it.
fn deliver(
  state: State,
  key: String,
  entry: Entry,
  message: thread.Message,
) -> State {
  case entry.agent {
    Live(thread:, ..) -> {
      process.send(thread, message)
      state
    }
    Asleep -> launch(state, key, Entry(..entry, pending: [message]))
    Starting(..) | Stopping(..) -> {
      put(
        state,
        key,
        Entry(..entry, pending: list.append(entry.pending, [message])),
      )
    }
  }
}

/// A model card pick; Slack already shows it in the menu, so a refusal is said privately.
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
    conversation.from_slack(card.channel, card.thread_ts)
    |> say.privately(state.config.client, _, user, text)
    state
  }
  let message = ModelPicked(home, pick, card, user)
  use <- admit(state, user, message, fn() { refuse(text.cant_change_model) })
  case entry_for(state, key, channel, thread_ts) {
    Ok(Some(entry)) ->
      deliver(state, key, entry, thread.CardPicked(pick, card.ts, user))
    _ -> refuse(text.not_working_there)
  }
}

/// Do what `user` asked of the App Home, once it's known whether they may use crushling.
fn home_ask(
  state: State,
  message: Message,
  user: String,
  ask: HomeAsk,
) -> State {
  use <- admit(state, user, message, fn() { show_home(state, user, ask, False) })
  show_home(state, user, ask, True)
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
  use <- admit(state, user, StopRequested(channel, thread_ts, user), fn() {
    whisper(config, incoming, text.cant_stop)
    state
  })
  case dict.get(state.threads, key) {
    Ok(Entry(agent: Live(thread:, turn:, ..), ..))
      if turn.in_flight > 0 || turn.working
    -> {
      process.send(thread, thread.Cancel(None))
      state
    }
    // Nothing running here, so the session shouldn't say it is.
    _ -> {
      say.session_done(
        config.client,
        conversation.from_slack(channel, thread_ts),
      )
      state
    }
  }
}

fn from_thread(state: State, key: String, notice: thread.Notice) -> State {
  case notice, dict.get(state.threads, key) {
    thread.Opening, _ -> code_channel.opening(state, key)
    thread.Moved(venue:, opened_ts:), found ->
      code_channel.moved(state, key, found, venue, opened_ts)
    thread.RunEnded(finished), Ok(entry) -> {
      let entry = case finished.reply_ts {
        "" -> entry
        ts -> Entry(..entry, summary_ts: ts)
      }
      // Crush's own turns for subagent reports were never counted in `in_flight`.
      let entry = case finished.solicited {
        True ->
          map_turn(entry, fn(turn) {
            Turn(..turn, in_flight: int.max(turn.in_flight - 1, 0))
          })
        False -> entry
      }
      idle_soon(state, key, entry)
    }
    thread.Activity(busy:), Ok(entry) ->
      map_turn(entry, fn(turn) { Turn(..turn, working: busy) })
      |> idle_soon(state, key, _)
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
    // The choice counts even if the agent stopped while it switched.
    thread.ModelChosen(choice), _ ->
      core.update_meta(state, key, fn(meta) { Meta(..meta, model: choice) })
    _, Error(Nil) -> state
  }
}

/// Stop every agent, waiting for launches in flight, then let the caller know.
fn finish_shutdown(state: State) -> actor.Next(State, Message) {
  case shutdown.finish(state.lifecycle) {
    None -> continue_or_finish(state)
    Some(lifecycle) -> {
      core.tell_after(state, shutdown.give_up_ms, ShutdownGiveUp)
      // Agents stop in parallel; a stopped sandbox's ephemeral node leaves the tailnet with it.
      dict.keys(state.threads)
      |> list.fold(State(..state, lifecycle:), stop_agent)
      |> continue_or_finish
    }
  }
}

/// While shutdown is stopping agents, end once nothing is left.
fn continue_or_finish(state: State) -> actor.Next(State, Message) {
  let left = !dict.is_empty(state.threads)
  case shutdown.outcome(state.lifecycle, left, state.abandoned) {
    Some(outcome) -> done_shutting_down(state, outcome)
    None -> actor.continue(state)
  }
}

fn done_shutting_down(
  state: State,
  outcome: ShutdownOutcome,
) -> actor.Next(State, Message) {
  shutdown.report(state.lifecycle, outcome)
  actor.stop()
}

fn remember(state: State, id: String) -> State {
  State(..state, seen: list.take([id, ..state.seen], seen_limit))
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

fn done(state: State, route: Route, entry: Entry) -> State {
  code_channel.wrap_up(state, route.incoming, route.origin, route.key, entry)
}
