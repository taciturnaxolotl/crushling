//// A thread's agent from launch to stop: one launch or stop at a time,
//// and an idle stop once it has been quiet for `idle_ms`.

import crushling/conversation.{Conversation}
import crushling/launcher
import crushling/registry/backlog.{pump}
import crushling/registry/core.{
  type State, FromThread, IdleCheck, JobsUncounted, RetryStop, Started, State,
  Stopped, apply_tailnet, put, set_meta,
}
import crushling/registry/entry.{
  type Entry, Asleep, Entry, Live, Starting, Stopping, has_waiting, is_quiet,
  no_turn, tailnet_view,
}
import crushling/registry/idle
import crushling/registry/say
import crushling/registry/shutdown
import crushling/registry/tailnet
import crushling/registry/text
import crushling/slack
import crushling/sys
import crushling/thread
import crushling/venue
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

/// Start thread `key`'s agent, and a thread actor to drive it.
pub fn launch(state: State(msg), key: String, entry: Entry) -> State(msg) {
  sys.info("crushling: starting an agent for " <> key)
  let launch = state.launches + 1
  let config = state.config
  let tell = core.teller(state)
  let channel = entry.channel
  let thread_ts = entry.thread_ts
  let meta = entry.meta
  let state = set_meta(state, key, entry, meta)
  process.spawn_unlinked(fn() {
    // A thread actor that can't start would leave nothing driving the agent, so it is stopped.
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
          notify: fn(notice) { tell(FromThread(key, notice)) },
          on_connect: fn(_) { Nil },
          model: meta.model,
          home: #(channel, thread_ts),
        ),
      )
      |> result.map_error(fn(error) { "thread: " <> string.inspect(error) })
    }
    tell(Started(key, launch, result))
  })
  State(
    ..put(state, key, Entry(..entry, agent: Starting(launch))),
    launches: launch,
  )
}

/// A launch finished; one superseded meanwhile is stopped again.
pub fn started(
  state: State(msg),
  key: String,
  launch: Int,
  result: Result(Subject(thread.Message), String),
) -> State(msg) {
  case dict.get(state.threads, key), result {
    Ok(Entry(agent: Starting(launch: current), ..) as entry), Error(reason)
      if current == launch
    -> {
      sys.warn("crushling: could not start " <> key <> ": " <> reason)
      say.post(
        state.config.client,
        Conversation(entry.channel, Some(entry.thread_ts)),
        text.could_not_start(reason),
      )
      State(..state, threads: dict.delete(state.threads, key))
    }
    Ok(Entry(agent: Starting(launch: current), ..) as entry), Ok(thread)
      if current == launch
    -> {
      let assert Ok(pid) = process.subject_owner(thread)
      let live =
        Live(
          thread:,
          monitor: process.monitor(pid),
          turn: no_turn,
          idle: idle.Active,
        )
      let state = put(state, key, Entry(..entry, agent: live))
      case shutdown.is_finishing(state.lifecycle) {
        // Shutdown already stopped everything else; this one started after.
        True -> stop_agent(state, key)
        False -> woke(state, key, entry, thread)
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

/// A launched agent is up: hand it what waited; `launched` is its entry while starting.
fn woke(
  state: State(msg),
  key: String,
  launched: Entry,
  thread: Subject(thread.Message),
) -> State(msg) {
  list.each(launched.pending, process.send(thread, _))
  let state = case dict.get(state.threads, key) {
    Ok(entry) -> put(state, key, Entry(..entry, pending: []))
    Error(Nil) -> state
  }
  pump(state, key)
  // `!model` wakes a thread without a prompt, so the idle timer starts here too.
  |> fn(state) {
    case dict.get(state.threads, key) {
      Ok(entry) -> idle_soon(state, key, entry)
      Error(Nil) -> state
    }
  }
  // The live entry, so a thread with a grant rejoins the tailnet as it wakes.
  |> fn(state) {
    case dict.get(state.threads, key) {
      Ok(entry) ->
        tailnet.check(state.tailnets, key, tailnet_view(entry), None)
        |> apply_tailnet(state, key, Some(entry), _)
      Error(Nil) -> state
    }
  }
}

/// Stop a running agent and its container, keeping its workspace.
pub fn stop_agent(state: State(msg), key: String) -> State(msg) {
  case dict.get(state.threads, key) {
    Ok(Entry(agent: Live(thread:, monitor:, ..), ..) as entry) -> {
      process.demonitor_process(monitor)
      process.send(thread, thread.Stop)
      run_stop(state, key)
      let tailnets = tailnet.stopped(state.tailnets, key)
      // Its turn and idle timer go with `Live`.
      let entry = Entry(..entry, agent: Stopping(0))
      State(..put(state, key, entry), tailnets:)
    }
    _ -> state
  }
}

/// Try a failed stop again, if the agent is still stopping.
pub fn retry_stop(state: State(msg), key: String) -> Nil {
  case dict.get(state.threads, key) {
    Ok(Entry(agent: Stopping(..), ..)) -> run_stop(state, key)
    _ -> Nil
  }
}

/// Run the launcher's stop for `key` on its own process.
fn run_stop(state: State(msg), key: String) -> Nil {
  let stop = state.config.launcher.stop
  let tell = core.teller(state)
  process.spawn_unlinked(fn() { tell(Stopped(key, stop(key))) })
  Nil
}

/// Messages that waited restart the agent; a failed stop is retried per `stop_backoff_ms`, then given up.
pub fn stopped(
  state: State(msg),
  key: String,
  result: Result(Nil, String),
) -> State(msg) {
  case dict.get(state.threads, key), result {
    Ok(Entry(agent: Stopping(..), ..) as entry), Ok(Nil) ->
      case has_waiting(entry), shutdown.is_finishing(state.lifecycle) {
        True, False -> launch(state, key, entry)
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
          core.tell_after(state, delay, RetryStop(key))
          put(state, key, Entry(..entry, agent: Stopping(attempt + 1)))
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
          say.post(
            state.config.client,
            entry.conversation(entry),
            text.could_not_stop,
          )
          State(..state, threads: dict.delete(state.threads, key), abandoned: [
            key,
            ..state.abandoned
          ])
        }
      }
    _, _ -> state
  }
}

/// A thread actor died: say so, and stop what's left of its agent.
pub fn thread_down(state: State(msg), down: process.Down) -> State(msg) {
  let gone =
    dict.filter(state.threads, fn(_, entry) {
      case entry.agent, down {
        Live(monitor:, ..), process.ProcessDown(monitor: m, ..) -> monitor == m
        _, _ -> False
      }
    })
  let client = state.config.client
  dict.each(gone, fn(key, dead) {
    sys.warn("crushling: thread " <> key <> " stopped unexpectedly")
    say.post(
      client,
      Conversation(dead.channel, Some(dead.thread_ts)),
      text.stopped_unexpectedly,
    )
  })
  // Nothing will clear "Working…" for a thread that died mid-run.
  dict.each(gone, fn(_, dead) {
    say.session_done(client, entry.conversation(dead))
  })
  // Its container may still be running, and on the tailnet.
  dict.fold(gone, state, fn(state, key, _) { stop_agent(state, key) })
}

/// Store the entry, giving a quiet live thread a new idle check that replaces any due.
pub fn idle_soon(state: State(msg), key: String, entry: Entry) -> State(msg) {
  case entry.agent {
    Live(idle: current, ..) as live -> {
      let token = state.ticks + 1
      let #(next, actions) = idle.settle(current, is_quiet(entry), token)
      let entry = Entry(..entry, agent: Live(..live, idle: next))
      State(..put(state, key, entry), ticks: token)
      |> idle_actions(key, actions)
    }
    Asleep | Starting(..) | Stopping(..) -> put(state, key, entry)
  }
}

/// Crush doesn't count background jobs as busy, so ask the thread before stopping.
pub fn idle_check(state: State(msg), key: String, token: Int) -> State(msg) {
  use entry, current <- with_idle(state, key)
  idle.check(current, is_quiet(entry), token)
}

/// The thread counted its background jobs for the idle check `token`.
pub fn jobs_counted(
  state: State(msg),
  key: String,
  entry: Entry,
  token: Int,
  running: Int,
) -> State(msg) {
  case entry.agent {
    Live(..) -> {
      use entry, current <- with_idle(state, key)
      idle.counted(current, is_quiet(entry), token, running, sys.monotonic_ms())
    }
    Asleep | Starting(..) | Stopping(..) -> state
  }
}

/// The thread didn't count its jobs in time: go ahead as if it had none.
pub fn jobs_uncounted(
  state: State(msg),
  key: String,
  token: Int,
) -> State(msg) {
  case dict.get(state.threads, key) {
    Ok(Entry(agent: Live(idle:, ..), ..) as entry) ->
      case idle.awaits_count(idle, token) {
        True -> {
          sys.warn(
            "crushling: " <> key <> " didn't count its background jobs in time",
          )
          jobs_counted(state, key, entry, token, 0)
        }
        False -> state
      }
    _ -> state
  }
}

/// Change a live thread's idle state, then do what the change calls for.
fn with_idle(
  state: State(msg),
  key: String,
  change: fn(Entry, idle.Idle) -> #(idle.Idle, List(idle.Action)),
) -> State(msg) {
  case dict.get(state.threads, key) {
    Ok(Entry(agent: Live(idle: current, ..) as live, ..) as entry) -> {
      let #(next, actions) = change(entry, current)
      let entry = Entry(..entry, agent: Live(..live, idle: next))
      put(state, key, entry)
      |> idle_actions(key, actions)
    }
    _ -> state
  }
}

fn idle_actions(
  state: State(msg),
  key: String,
  actions: List(idle.Action),
) -> State(msg) {
  use state, action <- list.fold(actions, state)
  case action {
    idle.CheckLater(token) -> {
      core.tell_after(state, state.config.idle_ms, IdleCheck(key, token))
      state
    }
    idle.CountJobs(token) -> {
      case dict.get(state.threads, key) {
        Ok(Entry(agent: Live(thread:, ..), ..)) ->
          process.send(thread, thread.CountJobs(token))
        _ -> Nil
      }
      // A wedged thread never answers, and mustn't keep its sandbox for it.
      core.tell_after(state, idle.count_timeout_ms, JobsUncounted(key, token))
      state
    }
    idle.Keep(running) -> {
      sys.info(
        "crushling: "
        <> key
        <> " is idle but has "
        <> int.to_string(running)
        <> " background jobs running; keeping its agent",
      )
      state
    }
    idle.Stop(why) -> stop_idle(state, key, why)
  }
}

fn stop_idle(state: State(msg), key: String, why: String) -> State(msg) {
  sys.info("crushling: " <> key <> " " <> why <> "; stopping its agent")
  // A code channel stays open: going quiet isn't the work being done.
  stop_agent(state, key)
}
