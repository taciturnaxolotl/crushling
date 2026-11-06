//// One actor per Slack thread. It owns a `crush server` workspace and
//// session, turns each Slack message into a prompt with its own run, and
//// streams progress back through a `Sink` until the run completes.
////
//// Prompts are queued here and sent one at a time. Crush starts every
//// prompt it receives on its own goroutine, so two sent close together race
//// for the session and may run in either order; and its messages carry no
//// run id, so output could not be attributed to the right prompt.
////
//// HTTP/1.1 can't send requests on a connection that is streaming a
//// response, so the actor keeps two connections: one for the event stream
//// and one for requests.

import crushling/crush/client
import crushling/crush/event
import crushling/gun
import crushling/render
import crushling/run.{type Run}
import crushling/snapshot
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string

/// Where replies go. Implemented over the Slack Web API in production and
/// by a test double in tests.
pub type Sink {
  Sink(
    /// Show a working status on the thread, or clear it with "".
    status: fn(String) -> Nil,
    /// Post the plan card, returning its id (Slack's `ts`).
    post_plan: fn(render.Plan) -> Result(String, String),
    update_plan: fn(String, render.Plan) -> Result(Nil, String),
    /// Post a markdown message.
    post: fn(String) -> Result(String, String),
    /// Post the controls for a run (a Stop button), returning their id.
    post_controls: fn(String) -> Result(String, String),
    delete: fn(String) -> Nil,
    /// Attach a file to the thread: name, then contents.
    upload: fn(String, String) -> Result(Nil, String),
    /// Called once per run after its reply is posted.
    finished: fn(Finished) -> Nil,
  )
}

pub type Finished {
  Finished(
    run_id: String,
    outcome: run.Outcome,
    /// The reply as posted, joined across messages.
    text: String,
    changes: List(snapshot.Change),
    patch: String,
  )
}

pub type Config {
  Config(
    socket: String,
    /// The workspace path as the server sees it, inside the sandbox.
    root: String,
    title: String,
    sink: Sink,
    /// How often an in-progress message is re-rendered, in milliseconds.
    flush_ms: Int,
  )
}

pub type Message {
  Prompt(text: String)
  Cancel
  Stop
  Setup
  Flush
  Reconnect
  Gun(gun.Message)
}

type Active {
  Active(
    run: Run,
    /// The plan card, once posted, and what it last showed.
    plan_ts: Option(String),
    shown: Option(render.Plan),
    /// The Stop button message.
    controls_ts: Option(String),
    /// The workspace snapshot taken just before the prompt was sent.
    base: Option(String),
  )
}

type Conns {
  Conns(requests: gun.Conn, events: gun.Conn, stream: gun.StreamRef)
}

type Ready {
  Ready(workspace_id: String, session_id: String)
}

type State {
  State(
    config: Config,
    self: Subject(Message),
    client_id: String,
    /// A session id that never exists, for shell commands whose output
    /// should not be saved into the agent's history.
    scratch: String,
    conns: Option(Conns),
    ready: Option(Ready),
    /// Kept across reconnects; sessions live in the sandbox's database, so
    /// a fresh actor for the same workspace picks up the latest one.
    session_id: Option(String),
    /// Prompts not yet sent, oldest first.
    waiting: List(String),
    active: Option(Active),
    known: run.Known,
    flushing: Bool,
    retries: Int,
  )
}

const max_retries = 8

const ready_poll_ms = 200

const ready_attempts = 150

@external(erlang, "crushling_ffi", "uuid_v4")
pub fn uuid() -> String

@external(erlang, "crushling_ffi", "log_warning")
fn warn(text: String) -> Nil

pub fn start(config: Config) -> Result(Subject(Message), actor.StartError) {
  actor.new_with_initialiser(1000, fn(self) {
    process.send(self, Setup)
    let selector =
      process.new_selector()
      |> process.select(self)
      |> gun.select(Gun)
    State(
      config:,
      self:,
      client_id: uuid(),
      scratch: uuid(),
      conns: None,
      ready: None,
      session_id: None,
      waiting: [],
      active: None,
      known: dict.new(),
      flushing: False,
      retries: 0,
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
    Setup | Reconnect -> actor.continue(connect(state))
    Prompt(text) ->
      State(..state, waiting: list.append(state.waiting, [text]))
      |> send_next
      |> actor.continue
    Cancel -> {
      case state.ready, state.conns, state.active {
        Some(ready), Some(conns), Some(_) -> {
          let _ =
            call(conns, client.cancel(ready.workspace_id, ready.session_id))
          Nil
        }
        _, _, _ -> Nil
      }
      actor.continue(State(..state, waiting: []))
    }
    Flush -> actor.continue(flush(State(..state, flushing: False)))
    Gun(message) -> actor.continue(on_gun(state, message))
    Stop -> {
      shutdown(state)
      actor.stop()
    }
  }
}

fn call(conns: Conns, call: client.Call(a)) -> Result(a, client.Error) {
  client.perform(conns.requests, call)
}

fn describe(error: client.Error) -> String {
  case error {
    client.Transport(reason) -> "transport: " <> reason
    client.Status(status, message) ->
      "status " <> string.inspect(status) <> ": " <> message
    client.BadResponse(body) -> "bad response: " <> body
  }
}

/// Connect (or reconnect) to the server, join the workspace, open the event
/// stream, and get a session.
fn connect(state: State) -> State {
  close_conns(state)
  let state = State(..state, conns: None, ready: None)
  case establish(state) {
    Ok(#(conns, ready)) ->
      State(
        ..state,
        conns: Some(conns),
        ready: Some(ready),
        session_id: Some(ready.session_id),
        retries: 0,
      )
      |> settle_orphan(conns, ready)
      |> send_next
    Error(reason) -> {
      warn("crushling: connect failed: " <> reason)
      case state.retries >= max_retries {
        True -> fail_everything(state, "could not reach the agent: " <> reason)
        False -> {
          process.send_after(state.self, backoff(state.retries), Reconnect)
          State(..state, retries: state.retries + 1)
        }
      }
    }
  }
}

fn backoff(retries: Int) -> Int {
  case retries {
    0 -> 100
    1 -> 250
    2 -> 500
    3 -> 1000
    _ -> 2000
  }
}

fn establish(state: State) -> Result(#(Conns, Ready), String) {
  let config = state.config
  use requests <- result.try(gun.connect_unix(config.socket, 5000))
  use events <- result.try(
    gun.connect_unix(config.socket, 5000)
    |> result.map_error(fn(reason) {
      gun.close(requests)
      reason
    }),
  )
  let fail = fn(error: client.Error) {
    gun.close(requests)
    gun.close(events)
    describe(error)
  }
  use workspace_id <- result.try(
    client.perform(
      requests,
      client.create_workspace(config.root, state.client_id, client.Yolo, []),
    )
    |> result.map_error(fail),
  )
  let stream =
    gun.stream(events, client.events_path(workspace_id, state.client_id), [])
  let conns = Conns(requests:, events:, stream:)
  let setup = {
    use _ <- result.try(call(conns, client.init_agent(workspace_id, False)))
    use _ <- result.try(wait_ready(conns, workspace_id, ready_attempts))
    case state.session_id {
      Some(id) -> Ok(id)
      None ->
        case call(conns, client.latest_session(workspace_id)) {
          Ok(Some(id)) -> Ok(id)
          _ -> call(conns, client.create_session(workspace_id, config.title))
        }
    }
  }
  case setup {
    Ok(session_id) -> Ok(#(conns, Ready(workspace_id:, session_id:)))
    Error(error) -> Error(fail(error))
  }
}

fn wait_ready(
  conns: Conns,
  workspace_id: String,
  attempts: Int,
) -> Result(Nil, client.Error) {
  case call(conns, client.agent_ready(workspace_id)) {
    Ok(True) -> Ok(Nil)
    Ok(False) if attempts > 0 -> {
      process.sleep(ready_poll_ms)
      wait_ready(conns, workspace_id, attempts - 1)
    }
    Ok(False) -> Error(client.BadResponse("agent never became ready"))
    Error(error) -> Error(error)
  }
}

/// After a reconnect, a run whose `run_complete` may have been missed is
/// finished with what was seen, unless the session is still busy.
fn settle_orphan(state: State, conns: Conns, ready: Ready) -> State {
  case state.active {
    None -> state
    Some(active) ->
      case
        call(conns, client.session_busy(ready.workspace_id, ready.session_id))
      {
        Ok(True) -> state
        _ -> {
          let outcome = run.Errored("lost the connection mid-run")
          let run = run.Run(..active.run, outcome: Some(outcome))
          finish_if_done(State(..state, active: Some(Active(..active, run:))))
        }
      }
  }
}

fn fail_everything(state: State, reason: String) -> State {
  let _ = case state.waiting, state.active {
    [], None -> Ok("")
    _, _ -> state.config.sink.post("_" <> reason <> "_")
  }
  State(..state, waiting: [], active: None)
}

fn send_next(state: State) -> State {
  case state.active, state.ready, state.conns, state.waiting {
    None, Some(ready), Some(conns), [text, ..rest] ->
      send_prompt(State(..state, waiting: rest), conns, ready, text)
    _, _, _, _ -> state
  }
}

fn send_prompt(
  state: State,
  conns: Conns,
  ready: Ready,
  text: String,
) -> State {
  let run_id = uuid()
  let base = take_snapshot(state, conns, ready)
  case
    call(
      conns,
      client.send_prompt(
        workspace_id: ready.workspace_id,
        session_id: ready.session_id,
        run_id:,
        prompt: text,
      ),
    )
  {
    Ok(Nil) -> {
      state.config.sink.status("is thinking")
      let run = run.new(ready.session_id, run_id)
      let active =
        Active(run:, plan_ts: None, shown: None, controls_ts: None, base:)
      State(..state, active: Some(active))
    }
    Error(client.Transport(_)) -> {
      process.send(state.self, Reconnect)
      State(..state, waiting: [text, ..state.waiting])
    }
    Error(error) -> {
      let _ =
        state.config.sink.post(
          "_couldn't send that to the agent: " <> describe(error) <> "_",
        )
      send_next(state)
    }
  }
}

fn shell(
  state: State,
  conns: Conns,
  ready: Ready,
  command: String,
) -> Result(String, Nil) {
  case
    call(
      conns,
      client.shell(
        workspace_id: ready.workspace_id,
        scratch_session: state.scratch,
        command:,
      ),
    )
  {
    Ok(#(0, output)) -> Ok(output)
    Ok(#(status, output)) -> {
      warn(
        "crushling: shell exited "
        <> string.inspect(status)
        <> ": "
        <> string.slice(output, 0, 500),
      )
      Error(Nil)
    }
    Error(error) -> {
      warn("crushling: shell failed: " <> describe(error))
      Error(Nil)
    }
  }
}

fn take_snapshot(state: State, conns: Conns, ready: Ready) -> Option(String) {
  shell(state, conns, ready, snapshot.take())
  |> result.try(snapshot.parse_tree)
  |> option.from_result
}

fn on_gun(state: State, message: gun.Message) -> State {
  case state.conns {
    None -> state
    Some(conns) ->
      case message {
        gun.Event(stream:, event: sse, ..) if stream == conns.stream ->
          case event.parse(sse.data) {
            Ok(parsed) -> on_event(state, parsed)
            Error(_) -> state
          }
        gun.StreamResponse(stream:, status:, ..)
          if stream == conns.stream && status != 200
        -> {
          warn("crushling: event stream refused: " <> string.inspect(status))
          reconnect_soon(state)
        }
        gun.StreamEnd(stream:, ..)
          | gun.StreamError(stream:, ..)
          if stream == conns.stream
        -> reconnect_soon(state)
        gun.ConnDown(conn:, reason:)
          if conn == conns.events || conn == conns.requests
        -> {
          warn("crushling: connection down: " <> reason)
          reconnect_soon(state)
        }
        _ -> state
      }
  }
}

fn reconnect_soon(state: State) -> State {
  close_conns(state)
  process.send(state.self, Reconnect)
  State(..state, conns: None, ready: None)
}

fn on_event(state: State, event: event.Event) -> State {
  case state.active {
    None -> state
    Some(active) -> {
      let run = run.apply(active.run, state.known, event)
      let state =
        finish_if_done(State(..state, active: Some(Active(..active, run:))))
      case state.active, state.flushing {
        None, _ | _, True -> state
        Some(_), False -> {
          process.send_after(state.self, state.config.flush_ms, Flush)
          State(..state, flushing: True)
        }
      }
    }
  }
}

/// Re-render the in-progress run if it changed since it was last shown.
fn flush(state: State) -> State {
  case state.active {
    Some(active) ->
      State(..state, active: Some(show_progress(state.config, active)))
    None -> state
  }
}

/// Post or update the plan card. The first time it appears, the Stop button
/// goes up with it. Posting a message clears the thread's status, so it is
/// set again while the run carries on.
fn show_progress(config: Config, active: Active) -> Active {
  let sink = config.sink
  case render.plan(active.run, config.root) {
    None -> active
    Some(plan) if Some(plan) == active.shown -> active
    Some(plan) ->
      case active.plan_ts {
        Some(ts) ->
          case sink.update_plan(ts, plan) {
            Ok(Nil) -> Active(..active, shown: Some(plan))
            Error(reason) -> {
              warn("crushling: plan update failed: " <> reason)
              active
            }
          }
        None ->
          case sink.post_plan(plan) {
            Ok(ts) -> {
              let controls_ts = case sink.post_controls(active.run.run_id) {
                Ok(ts) -> Some(ts)
                Error(reason) -> {
                  warn("crushling: controls failed: " <> reason)
                  None
                }
              }
              sink.status("is working")
              Active(
                ..active,
                plan_ts: Some(ts),
                shown: Some(plan),
                controls_ts:,
              )
            }
            Error(reason) -> {
              warn("crushling: plan post failed: " <> reason)
              active
            }
          }
      }
  }
}

fn finish_if_done(state: State) -> State {
  case state.active {
    Some(active) ->
      case run.is_done(active.run) {
        True -> {
          finish(state, active)
          State(
            ..state,
            active: None,
            known: run.remember(state.known, active.run),
          )
          |> send_next
        }
        False -> state
      }
    None -> state
  }
}

/// A patch bigger than this is not attached; Slack won't preview it, and a
/// change that size is better read in the workspace.
const max_patch_bytes = 400_000

/// The run's changes: from workspace snapshots when they work, so edits
/// made through `bash` are included, otherwise from the file events.
fn changes(state: State, active: Active) -> #(List(snapshot.Change), String) {
  let from_snapshots = case active.base, state.conns, state.ready {
    Some(base), Some(conns), Some(ready) -> {
      use after <- result.try(
        take_snapshot(state, conns, ready) |> option.to_result(Nil),
      )
      use numstat <- result.try(shell(
        state,
        conns,
        ready,
        snapshot.numstat(base, after),
      ))
      use patch <- result.try(shell(
        state,
        conns,
        ready,
        snapshot.diff(base, after),
      ))
      Ok(#(snapshot.parse_numstat(numstat), patch))
    }
    _, _, _ -> Error(Nil)
  }
  case from_snapshots {
    Ok(found) -> found
    Error(Nil) -> {
      let root = state.config.root
      let changes =
        run.changes(active.run, root)
        |> list.map(fn(change) {
          snapshot.Change(change.path, Error(Nil), Error(Nil))
        })
      #(changes, run.patch(active.run, root))
    }
  }
}

fn finish(state: State, active: Active) -> Nil {
  let config = state.config
  let sink = config.sink
  let #(changes, patch) = changes(state, active)

  // The plan card settles into its final state, and the Stop button goes.
  case active.plan_ts, render.plan(active.run, config.root) {
    Some(ts), Some(plan) ->
      case sink.update_plan(ts, plan) {
        Ok(Nil) -> Nil
        Error(reason) -> warn("crushling: plan update failed: " <> reason)
      }
    _, _ -> Nil
  }
  case active.controls_ts {
    Some(ts) -> sink.delete(ts)
    None -> Nil
  }

  let answer = render.answer(active.run)
  let answered = answer != []
  let closing =
    [render.changes(changes), render.note(active.run, answered)]
    |> option.values
  // The file summary and any note ride on the last answer message when
  // there is one, so a run ends in a single message.
  let messages = case list.reverse(answer), closing {
    [], [] -> []
    [], closing -> [string.join(closing, "\n")]
    [last, ..earlier], [] -> list.reverse([last, ..earlier])
    [last, ..earlier], closing ->
      list.reverse([last <> "\n\n" <> string.join(closing, "\n"), ..earlier])
  }
  list.each(messages, fn(text) {
    case sink.post(text) {
      Ok(_) -> Nil
      Error(reason) -> warn("crushling: post failed: " <> reason)
    }
  })
  sink.status("")

  case patch, string.byte_size(patch) > max_patch_bytes {
    "", _ -> Nil
    _, True ->
      warn("crushling: patch too large to attach: " <> active.run.run_id)
    patch, False ->
      case
        sink.upload(string.slice(active.run.run_id, 0, 8) <> ".diff", patch)
      {
        Ok(Nil) -> Nil
        Error(reason) -> warn("crushling: upload failed: " <> reason)
      }
  }
  sink.finished(Finished(
    run_id: active.run.run_id,
    outcome: option.unwrap(active.run.outcome, run.Cancelled),
    text: string.join(messages, "\n"),
    changes:,
    patch:,
  ))
}

fn close_conns(state: State) -> Nil {
  case state.conns {
    Some(conns) -> {
      gun.close(conns.events)
      gun.close(conns.requests)
    }
    None -> Nil
  }
}

fn shutdown(state: State) -> Nil {
  case state.conns {
    Some(conns) -> {
      let _ = call(conns, client.retire_client(state.client_id))
      Nil
    }
    None -> Nil
  }
  close_conns(state)
}
