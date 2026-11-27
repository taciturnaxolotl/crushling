//// The registry's state, shared by its modules, and the events it sends
//// itself.

import crushling/connections
import crushling/github/route as github_route
import crushling/key as thread_key
import crushling/meta.{type Meta, Meta}
import crushling/pr
import crushling/registry/config.{type Config}
import crushling/registry/entry.{
  type Entry, Asleep, Entry, Live, Starting, Stopping, Turn, map_turn,
  new as new_entry,
}
import crushling/registry/gate.{type Gate}
import crushling/registry/incoming.{type Incoming}
import crushling/registry/links.{type Links}
import crushling/registry/shutdown
import crushling/registry/tailnet
import crushling/store
import crushling/sys
import crushling/thread
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}

/// What the registry sends itself: its helper processes' answers, and its timers.
pub type Event {
  /// Held while a code channel opens, since it may be the request's copy there.
  Deferred(incoming: Incoming, attempts: Int)
  Started(
    key: String,
    launch: Int,
    result: Result(Subject(thread.Message), String),
  )
  Stopped(key: String, result: Result(Nil, String))
  RetryStop(key: String)
  /// A prompt is ready to send: `ts` is the message it came from.
  Prepared(key: String, ts: String, prompt: thread.Message)
  FromThread(key: String, notice: thread.Notice)
  /// The grace period is over.
  ShutdownDeadline
  /// Cancelled turns have had their chance to wind down.
  ShutdownFinal
  /// Launches and stops in flight at shutdown took too long.
  ShutdownGiveUp
  IdleCheck(key: String, token: Int)
  /// The thread didn't count its jobs for the idle check `token` in time.
  JobsUncounted(key: String, token: Int)
  ThreadDown(process.Down)
  Member(gate.Answer)
  /// Hourly: archive quiet code channels and clear out old workspaces.
  Sweep
  /// A PR card was opened; forget it.
  PrSettled(card_ts: String)
  /// Who to ask, for `GitHubNudge`.
  GitHubNudgeTo(key: String, user: String, want: github_route.Want)
  /// A join finishing, or a grant's timer, for thread `key`.
  TailnetLater(key: String, event: tailnet.Event)
}

pub type State(msg) {
  State(
    config: Config,
    self: Subject(msg),
    /// Wraps an event as a message to the registry.
    wrap: fn(Event) -> msg,
    threads: Dict(String, Entry),
    /// Links from code channels to their threads.
    code_channels: Links,
    /// Threads opening a code channel: until they finish, an unknown channel may be a new one.
    opening: Set(String),
    /// Recently handled message ids, so a redelivery is not run twice.
    seen: List(String),
    /// Numbers each launch, so a superseded one is recognised.
    launches: Int,
    /// Numbers each idle check, so a stale one is recognised.
    ticks: Int,
    lifecycle: shutdown.Lifecycle,
    /// Agents the launcher couldn't stop: their sandboxes may still run, so shutdown reports them.
    abandoned: List(String),
    /// Threads that can't be loaded, and were said to be.
    broken: Set(String),
    tailnets: tailnet.Tailnets,
    /// Who may drive agents, and what waits on a membership lookup.
    gate: Gate(msg),
    /// The workspace's GitHub connections and App Homes.
    connections: Subject(connections.Message),
    /// When each person was last asked to connect GitHub, by thread, user and want, in monotonic ms.
    nudged: Dict(#(String, String, String), Int),
    /// PR cards awaiting a press, by ts; lost on restart, when `/pr` posts a new one.
    proposals: Dict(String, #(String, pr.Proposal)),
  )
}

/// Sends events to the registry from any process, without copying the state there.
pub fn teller(state: State(msg)) -> fn(Event) -> Nil {
  let self = state.self
  let wrap = state.wrap
  fn(event) { process.send(self, wrap(event)) }
}

pub fn tell_after(state: State(msg), ms: Int, event: Event) -> Nil {
  process.send_after(state.self, ms, state.wrap(event))
  Nil
}

/// Keep `entry` as thread `key`'s.
pub fn put(state: State(msg), key: String, entry: Entry) -> State(msg) {
  State(..state, threads: dict.insert(state.threads, key, entry))
}

/// A thread's key in workspace `team`.
pub fn key(team: String, channel: String, thread_ts: String) -> String {
  thread_key.new(team, channel, thread_ts) |> thread_key.to_string
}

/// The thread's entry, in memory or rebuilt from the store; an error means it can't be loaded.
pub fn entry_for(
  state: State(msg),
  key: String,
  channel: String,
  thread_ts: String,
) -> Result(Option(Entry), String) {
  case dict.get(state.threads, key) {
    Ok(entry) -> Ok(Some(entry))
    Error(Nil) -> {
      let config = state.config
      use _ <- result.try(case set.contains(config.stranded, key) {
        True -> Error("its old workspace couldn't be moved")
        False -> Ok(Nil)
      })
      // A row that can't be read is refused, not overwritten.
      use saved <- result.map(store.thread(config.store, key))
      case config.launcher.exists(key) {
        False -> None
        True ->
          Some(new_entry(
            channel,
            thread_ts,
            saved
              |> option.map(fn(thread) { thread.meta })
              // A workspace without meta predates follow mode, when every reply was a prompt.
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

/// A thread's entry, awake or read back from the store.
pub fn known_entry(state: State(msg), key: String) -> Option(Entry) {
  case dict.get(state.threads, key) {
    Ok(entry) -> Some(entry)
    Error(Nil) ->
      saved_thread(state.config, key)
      |> option.map(fn(saved) {
        new_entry(saved.channel, saved.thread_ts, saved.meta)
      })
  }
}

/// Change a thread's meta, from memory or, if its agent stopped meanwhile, the store.
pub fn update_meta(
  state: State(msg),
  key: String,
  change: fn(Meta) -> Meta,
) -> State(msg) {
  case known_entry(state, key) {
    Some(entry) -> set_meta(state, key, entry, change(entry.meta))
    None -> state
  }
}

/// All thread meta is written here, whether the agent is running or asleep.
pub fn set_meta(
  state: State(msg),
  key: String,
  entry: Entry,
  meta: Meta,
) -> State(msg) {
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
  case entry.agent {
    Asleep -> state
    _ -> put(state, key, Entry(..entry, meta:))
  }
}

/// Keep a tailnet outcome: the new grant, and any note for the agent.
pub fn apply_tailnet(
  state: State(msg),
  key: String,
  entry: Option(Entry),
  outcome: tailnet.Outcome,
) -> State(msg) {
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
      let entry =
        map_turn(entry, fn(turn) { Turn(..turn, in_flight: turn.in_flight + 1) })
      put(state, key, entry)
    }
    _, _ -> state
  }
}

/// Whether any agent is running a prompt, which shutdown waits for.
pub fn busy(state: State(msg)) -> Bool {
  dict.values(state.threads)
  |> list.any(fn(entry) {
    case entry.agent {
      Live(turn:, ..) -> turn.in_flight > 0
      Asleep | Starting(..) | Stopping(..) -> False
    }
  })
}
