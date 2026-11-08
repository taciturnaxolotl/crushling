//// One actor per Slack thread. It owns a `crush server` workspace and
//// session, turns each Slack message into a prompt with its own run, and
//// streams progress back through a `Sink` until the run completes.
////
//// Prompts are queued here and sent one at a time. Crush starts every
//// prompt it receives on its own goroutine, so two sent close together race
//// for the session and may run in either order; and its messages carry no
//// run id, so output could not be attributed to the right prompt.
////
//// The thread's `Venue` says where its work is. That is the Slack thread, or a
//// code channel after the agent clones a repository. Only this actor changes
//// the venue, and it changes the sink at the same time. It tells the registry
//// about each change through `notify`.

import crushling/crush/client
import crushling/crush/event
import crushling/gun
import crushling/render
import crushling/run.{type Run}
import crushling/sink.{type Reply, type Sink}
import crushling/snapshot
import crushling/sys
import crushling/thread/conn.{type Connection}
import crushling/thread/repo
import crushling/thread/subagents.{type Subagents}
import crushling/venue.{type Venue}
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string

pub type Finished {
  Finished(
    /// Whether this was a prompt the bridge sent, rather than a turn crush
    /// started by itself to read a subagent's report.
    solicited: Bool,
    run_id: String,
    outcome: run.Outcome,
    /// The reply as posted, joined across messages.
    text: String,
    /// The last message of the reply, or "" when nothing was posted.
    reply_ts: String,
    changes: List(snapshot.Change),
    patch: String,
  )
}

/// Messages from the thread to the registry.
pub type Notice {
  /// A run ended, and its reply is posted.
  RunEnded(Finished)
  /// Sent when the thread becomes busy or idle. It is busy while a run, a
  /// queued prompt or a subagent is still going.
  Activity(busy: Bool)
  /// Sent just before the thread asks Slack for a code channel. A `Moved`
  /// always follows.
  Opening
  /// The work moved to `venue`. For a new code channel, `opened_ts` is when it
  /// opened, so the registry can skip the copy of the request that Slack posts
  /// there. Otherwise it is "".
  Moved(venue: Venue, opened_ts: String)
}

pub type Config {
  Config(
    socket: String,
    /// The workspace path as the server sees it, inside the sandbox.
    root: String,
    title: String,
    /// Where the work starts. `sink` must post there.
    venue: Venue,
    sink: Sink,
    /// How often an in-progress message is re-rendered, in milliseconds.
    flush_ms: Int,
    /// Yolo skips permission prompts; sysadmin also lifts crush's block
    /// list of dangerous commands.
    mode: client.PermissionMode,
    notify: fn(Notice) -> Nil,
  )
}

/// The conversation the thread posts to now, and the workspace path that the
/// agent sees.
pub type Location {
  Location(conversation: sink.Conversation, root: String)
}

pub type Message {
  /// A prompt for the agent. `attachments` are files the model should see
  /// directly, such as images. `from` is the user who asked, or "" if not
  /// known, because Slack streams each reply to one person.
  Prompt(text: String, attachments: List(client.Attachment), from: String)
  Where(reply: Subject(Location))
  /// Post a message in the thread's current conversation, and reply with its
  /// ts. The agent's Slack tools use this.
  Say(text: String, reply: Subject(Result(String, String)))
  /// Move the work to a code channel. The agent's Slack tools use this.
  OpenCodeChannel(
    name: String,
    repo: String,
    reply: Subject(Result(String, String)),
  )
  /// Cancel the running turn and drop any queued prompts. When `note` is given,
  /// the run ends with it instead of "stopped".
  Cancel(note: Option(String))
  Stop
  Setup
  Flush
  /// Periodic check that the active run is still making progress.
  Watchdog
  Reconnect
  Gun(gun.Message)
}

type Queued {
  Queued(text: String, attachments: List(client.Attachment), from: String)
}

type Active {
  Active(
    run: Run,
    /// The reply, once there is something to show.
    reply: Option(Reply),
    /// What the run said in the thread before it moved to a code channel. The
    /// reply in the channel starts after this text.
    said_before: String,
    /// The workspace snapshot taken just before the prompt was sent.
    base: Option(String),
    /// When the session was last marked as working. Slack clears that after an
    /// hour, so a long run marks it again.
    working_since_ms: Int,
    last_event_ms: Int,
    /// Whether the stall note has been posted for this run.
    stalled: Bool,
    /// Said in place of "stopped" when the run was cancelled for a reason.
    cancel_note: Option(String),
    /// False for a turn crush started on its own to read a subagent report.
    solicited: Bool,
    /// Who the reply is for.
    from: String,
  )
}

type State {
  State(
    config: Config,
    self: Subject(Message),
    target: conn.Target,
    connection: Option(Connection),
    /// Kept across reconnects. Sessions are stored in the sandbox's database,
    /// so a new actor for the same workspace finds the latest one.
    session_id: Option(String),
    venue: Venue,
    sink: Sink,
    waiting: List(Queued),
    /// Who sent the latest prompt, for turns crush starts on its own.
    requester: String,
    active: Option(Active),
    known: run.Known,
    flushing: Bool,
    subs: Subagents,
    retries: Int,
    /// Whether the Slack session has its title.
    titled: Bool,
    /// The busy state last sent to the registry.
    reported_busy: Bool,
  )
}

const max_retries = 8

/// With no event from the agent for this long, say so in the thread.
const stall_ms = 600_000

const watchdog_ms = 60_000

/// Slack drops a session out of working after an hour; mark it again well
/// before.
const rework_ms = 1_800_000

/// A patch bigger than this is not attached; Slack won't preview it, and a
/// change that size is better read in the workspace.
const max_patch_bytes = 400_000

/// Make a session title from the first line of a prompt, cut to 60 characters.
fn session_title(prompt: String) -> String {
  let line = case string.split_once(string.trim(prompt), "\n") {
    Ok(#(first, _)) -> first
    Error(Nil) -> string.trim(prompt)
  }
  case string.length(line) > 60 {
    True -> string.slice(line, 0, 59) <> "…"
    False -> line
  }
}

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
      target: conn.Target(
        socket: config.socket,
        root: config.root,
        title: config.title,
        mode: config.mode,
        client_id: sys.uuid(),
        scratch: sys.uuid(),
      ),
      connection: None,
      session_id: None,
      venue: config.venue,
      sink: config.sink,
      waiting: [],
      requester: "",
      active: None,
      known: dict.new(),
      flushing: False,
      subs: subagents.new(),
      retries: 0,
      titled: False,
      reported_busy: False,
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
    Stop -> {
      case state.active {
        Some(active) ->
          close_reply(state.sink, state.config.root, active, "_stopped._")
        None -> Nil
      }
      case state.connection {
        Some(connection) -> conn.retire(connection, state.target)
        None -> Nil
      }
      actor.stop()
    }
    _ -> actor.continue(step(state, message) |> report)
  }
}

fn step(state: State, message: Message) -> State {
  case message {
    Setup | Reconnect -> connect(state)
    Prompt(text, attachments, from) ->
      State(
        ..state,
        waiting: list.append(state.waiting, [Queued(text, attachments, from)]),
      )
      |> send_next
    Where(reply) -> {
      process.send(reply, Location(state.sink.conversation, state.config.root))
      state
    }
    Say(text, reply) -> {
      process.send(reply, state.sink.post(text))
      state
    }
    OpenCodeChannel(name, dir, reply) -> {
      let #(state, result) = move(state, dir, name)
      process.send(reply, result)
      state
    }
    Cancel(note) -> cancel(state, note)
    Flush -> flush(State(..state, flushing: False))
    Watchdog -> watchdog(state)
    Gun(message) -> on_gun(state, message)
    Stop -> state
  }
}

/// Tell the registry when the thread starts or stops being busy.
fn report(state: State) -> State {
  let busy =
    state.active != None || state.waiting != [] || subagents.running(state.subs)
  case busy == state.reported_busy {
    True -> state
    False -> {
      state.config.notify(Activity(busy))
      State(..state, reported_busy: busy)
    }
  }
}

fn parent(state: State) -> subagents.Parent {
  subagents.Parent(
    session_id: option.unwrap(state.session_id, ""),
    sink: state.sink,
    root: state.config.root,
    known: state.known,
  )
}

fn cancel(state: State, note: Option(String)) -> State {
  subagents.close(state.subs, case note {
    Some(note) -> "_" <> note <> "_"
    None -> "_stopped._"
  })
  case state.connection, state.active {
    Some(connection), Some(active) -> {
      let _ =
        conn.call(
          connection,
          client.cancel(connection.workspace_id, connection.session_id),
        )
      let active = Active(..active, cancel_note: note)
      State(..state, waiting: [], active: Some(active))
    }
    _, _ -> State(..state, waiting: [])
  }
}

/// Connect (or reconnect) to the server, join the workspace, open the event
/// stream, and get a session.
fn connect(state: State) -> State {
  close_connection(state)
  let state = State(..state, connection: None)
  case conn.open(state.target, state.session_id) {
    Ok(connection) ->
      State(
        ..state,
        connection: Some(connection),
        session_id: Some(connection.session_id),
        retries: 0,
      )
      |> settle_orphan(connection)
      |> send_next
    Error(reason) -> {
      sys.warn("crushling: connect failed: " <> reason)
      case state.retries >= max_retries {
        True -> fail_everything(state, "could not reach the agent: " <> reason)
        False -> {
          process.send_after(state.self, conn.backoff(state.retries), Reconnect)
          State(..state, retries: state.retries + 1)
        }
      }
    }
  }
}

/// After a reconnect, a run whose `run_complete` may have been missed is
/// finished with what was seen, unless the session is still busy.
fn settle_orphan(state: State, connection: Connection) -> State {
  case state.active {
    None -> state
    Some(active) ->
      case
        conn.call(
          connection,
          client.session_busy(connection.workspace_id, connection.session_id),
        )
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
  let note = "_" <> reason <> "_"
  case state.waiting, state.active {
    [], None -> Nil
    // An open reply ends with the note instead.
    _, Some(Active(reply: Some(_), ..) as active) ->
      close_reply(state.sink, state.config.root, active, note)
    _, _ -> {
      let _ = state.sink.post(note)
      Nil
    }
  }
  State(..state, waiting: [], active: None)
}

fn send_next(state: State) -> State {
  case state.active, state.connection, state.waiting {
    None, Some(connection), [next, ..rest] ->
      send_prompt(State(..state, waiting: rest), connection, next)
    _, _, _ -> state
  }
}

fn send_prompt(state: State, connection: Connection, next: Queued) -> State {
  let run_id = sys.uuid()
  let base = take_snapshot(state)
  let sent =
    conn.call(
      connection,
      client.send_prompt_with(
        workspace_id: connection.workspace_id,
        session_id: connection.session_id,
        run_id:,
        prompt: next.text,
        attachments: next.attachments,
      ),
    )
  case sent {
    Ok(Nil) -> {
      state.sink.working(True)
      case state.titled {
        True -> Nil
        False -> state.sink.title(session_title(next.text))
      }
      process.send_after(state.self, watchdog_ms, Watchdog)
      let active =
        Active(
          ..new_active(run.new(connection.session_id, run_id), next.from, True),
          base:,
        )
      let state =
        State(..state, titled: True, requester: next.from, active: Some(active))
      // `!done` archived the last code channel. Open a new one for the same
      // repository.
      case state.venue {
        venue.Archived(repo: dir) -> move(state, dir, "").0
        _ -> state
      }
    }
    Error(client.Transport(_)) -> {
      process.send(state.self, Reconnect)
      State(..state, waiting: [next, ..state.waiting])
    }
    Error(error) -> {
      let _ =
        state.sink.post(
          "_couldn't send that to the agent: " <> conn.describe(error) <> "_",
        )
      send_next(state)
    }
  }
}

fn new_active(run: Run, from: String, solicited: Bool) -> Active {
  let now = sys.monotonic_ms()
  Active(
    run:,
    reply: None,
    said_before: "",
    base: None,
    working_since_ms: now,
    last_event_ms: now,
    stalled: False,
    cancel_note: None,
    solicited:,
    from:,
  )
}

fn shell(state: State) -> repo.Shell {
  fn(command) {
    case state.connection {
      Some(connection) -> conn.shell(connection, state.target, command)
      None -> Error(Nil)
    }
  }
}

fn take_snapshot(state: State) -> Option(String) {
  shell(state)(snapshot.take())
  |> result.try(snapshot.parse_tree)
  |> option.from_result
}

fn on_gun(state: State, message: gun.Message) -> State {
  case state.connection {
    None -> state
    Some(connection) ->
      case message {
        gun.Event(stream:, event: sse, ..) if stream == connection.stream ->
          case event.parse(sse.data) {
            Ok(parsed) -> on_event(state, parsed)
            Error(_) -> state
          }
        gun.StreamResponse(stream:, status:, ..)
          if stream == connection.stream && status != 200
        -> {
          sys.warn(
            "crushling: event stream refused: " <> string.inspect(status),
          )
          reconnect_soon(state)
        }
        gun.StreamEnd(stream:, ..)
          | gun.StreamError(stream:, ..)
          if stream == connection.stream
        -> reconnect_soon(state)
        gun.ConnDown(conn:, reason:)
          if conn == connection.events || conn == connection.requests
        -> {
          sys.warn("crushling: connection down: " <> reason)
          reconnect_soon(state)
        }
        _ -> state
      }
  }
}

fn reconnect_soon(state: State) -> State {
  close_connection(state)
  process.send(state.self, Reconnect)
  State(..state, connection: None)
}

fn on_event(state: State, event: event.Event) -> State {
  let state =
    State(..state, subs: subagents.track(state.subs, parent(state), event))
    |> adopt_report_turn(event)
  let state = case state.active {
    None -> state
    Some(active) -> {
      let run = run.apply(active.run, state.known, event)
      let active = Active(..active, run:, last_event_ms: sys.monotonic_ms())
      State(..state, active: Some(active))
      |> move_on_clone(event)
      |> finish_if_done
    }
  }
  case state.active != None || subagents.running(state.subs), state.flushing {
    False, _ | _, True -> state
    True, False -> {
      process.send_after(state.self, state.config.flush_ms, Flush)
      State(..state, flushing: True)
    }
  }
}

/// Crush wakes the parent with a turn of its own when a subagent reports
/// and nothing is running. That turn carries no run id of ours, so adopt it
/// as an unsolicited run when its report message appears.
fn adopt_report_turn(state: State, event: event.Event) -> State {
  let parent = option.unwrap(state.session_id, "")
  case state.active, event {
    None, event.MessageEvent(op: "created", message:)
      if message.session_id == parent && message.reports != []
    -> {
      state.sink.working(True)
      process.send_after(state.self, watchdog_ms, Watchdog)
      let run = run.new(message.session_id, "")
      State(..state, active: Some(new_active(run, state.requester, False)))
    }
    _, _ -> state
  }
}

/// When a bash call that cloned a repository succeeds in a plain thread,
/// move the work to a code channel for that repository.
fn move_on_clone(state: State, event: event.Event) -> State {
  case state.venue, state.active, event {
    venue.Thread, Some(active), event.MessageEvent(message:, ..)
      if message.role == event.Tool
    -> {
      let cloned =
        list.any(message.tool_results, fn(result) {
          !result.is_error
          && list.any(active.run.tools, fn(tool) {
            tool.id == result.tool_call_id
            && tool.name == "bash"
            && snapshot.is_clone(tool.input)
          })
        })
      case cloned {
        True -> move(state, "", "").0
        False -> state
      }
    }
    _, _, _ -> state
  }
}

/// Move the work to a code channel for the repository in workspace
/// directory `dir`, named `name`. With no `dir` the first repository in
/// the workspace is used, and with no `name` the channel is named after
/// the repository. Returns the channel's id.
fn move(
  state: State,
  dir: String,
  name: String,
) -> #(State, Result(String, String)) {
  case state.venue, repo.find(shell(state), dir) {
    venue.CodeChannel(..), _ -> #(
      state,
      Error("the work is already in a code channel"),
    )
    _, Error(reason) -> #(state, Error(reason))
    _, Ok(found) -> open_code_channel(state, found, name)
  }
}

fn open_code_channel(
  state: State,
  found: repo.Found,
  name: String,
) -> #(State, Result(String, String)) {
  let name = case string.trim(name) {
    "" -> found.name
    name -> name
  }
  state.config.notify(Opening)
  case state.sink.open_code_channel(name) {
    Error(reason) -> {
      sys.warn("crushling: staying in the thread: " <> reason)
      // Later clones in this thread do not try again. Each run lists the
      // repository's changes in the thread and attaches its diff.
      let venue = venue.ThreadOnly(repo: found.dir)
      state.config.notify(Moved(venue, ""))
      #(State(..state, venue:), Error(reason))
    }
    Ok(#(channel_sink, channel)) -> {
      let opened_ts = float.to_string(int.to_float(sys.system_ms()) /. 1000.0)
      let to = venue.CodeChannel(channel:, repo: found.dir)
      state.config.notify(Moved(to, opened_ts))
      let thread = state.sink
      // End the reply in the thread. The rest of the run goes to the channel,
      // starting after what was already said.
      let active =
        option.map(state.active, fn(active) {
          close_reply(
            thread,
            state.config.root,
            active,
            "_continued in <#" <> channel <> ">_",
          )
          Active(..active, reply: None, said_before: render.reply(active.run))
        })
      let _ =
        thread.post(
          "_working on `" <> found.name <> "` in <#" <> channel <> ">_",
        )
      thread.working(False)
      channel_sink.working(active != None)
      let state = State(..state, venue: to, sink: channel_sink, active:)
      repo.show(shell(state), channel_sink, found.dir, found.info)
      #(state, Ok(channel))
    }
  }
}

/// Re-render the in-progress run if it changed since it was last shown.
fn flush(state: State) -> State {
  let state = State(..state, subs: subagents.show(state.subs, parent(state)))
  let state = case state.active {
    Some(active) ->
      State(
        ..state,
        active: Some(show_progress(state.sink, state.config.root, active)),
      )
    None -> state
  }
  // Keep flushing while subagents work after the main run has ended.
  case state.active == None && subagents.running(state.subs) {
    True -> {
      process.send_after(state.self, state.config.flush_ms * 2, Flush)
      State(..state, flushing: True)
    }
    False -> state
  }
}

fn watchdog(state: State) -> State {
  case state.active {
    None -> state
    Some(active) -> {
      process.send_after(state.self, watchdog_ms, Watchdog)
      let now = sys.monotonic_ms()
      case active.stalled {
        True -> state
        False ->
          case
            now - active.last_event_ms > stall_ms,
            now - active.working_since_ms > rework_ms
          {
            True, _ -> {
              let _ =
                state.sink.post(
                  "_no word from the agent in 10 minutes; it may be stuck. Reply `!stop` to stop it._",
                )
              state.sink.working(False)
              State(..state, active: Some(Active(..active, stalled: True)))
            }
            False, True -> {
              state.sink.working(True)
              let active = Active(..active, working_since_ms: now)
              State(..state, active: Some(active))
            }
            False, False -> state
          }
      }
    }
  }
}

/// Show the run as it goes: what the agent has said, and its steps.
fn show_progress(sink: Sink, root: String, active: Active) -> Active {
  let text = said_since(render.reply(active.run), active.said_before)
  let steps = render.all_tasks(active.run, root)
  case active.reply, text, steps {
    None, "", [] -> active
    _, _, _ -> {
      let reply = case active.reply {
        Some(reply) -> reply
        None -> sink.reply(active.from)
      }
      let title = case steps {
        [] -> ""
        _ -> render.progress_title(active.run)
      }
      reply.show(text, steps, title)
      Active(..active, reply: Some(reply))
    }
  }
}

/// The text after `before`, which is the part a code channel shows.
fn said_since(text: String, before: String) -> String {
  case before, string.starts_with(text, before) {
    "", _ -> text
    _, True -> string.drop_start(text, string.length(before)) |> string.trim
    _, False -> text
  }
}

/// End an open reply with what it has, and `note`.
fn close_reply(sink: Sink, root: String, active: Active, note: String) -> Nil {
  case active.reply {
    Some(_) ->
      case show_progress(sink, root, active).reply {
        Some(reply) -> {
          let _ = reply.finish(note)
          Nil
        }
        None -> Nil
      }
    None -> Nil
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

/// The run's changed files and its patch. When the work has a repository, they
/// come from the repository's own history. In a code channel the Code tab shows
/// the diff, so the patch is empty. Without a repository, they come from
/// workspace snapshots, which include edits made through `bash`. If the
/// snapshots fail, they come from the run's file events.
fn changes(state: State, active: Active) -> #(List(snapshot.Change), String) {
  let shell = shell(state)
  case state.venue {
    venue.CodeChannel(repo: dir, ..) -> {
      repo.show(shell, state.sink, dir, repo.info(shell, dir))
      #(repo.changes(shell, dir), "")
    }
    venue.ThreadOnly(repo: dir) if dir != "" -> #(
      repo.changes(shell, dir),
      shell(snapshot.repo_diff(dir)) |> result.unwrap(""),
    )
    _ -> {
      let from_snapshots = {
        use base <- result.try(option.to_result(active.base, Nil))
        use after <- result.try(take_snapshot(state) |> option.to_result(Nil))
        use numstat <- result.try(shell(snapshot.numstat(base, after)))
        use patch <- result.try(shell(snapshot.diff(base, after)))
        Ok(#(snapshot.parse_numstat(numstat), patch))
      }
      use <- result.lazy_unwrap(from_snapshots)
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
  let sink = state.sink
  let #(changes, patch) = changes(state, active)
  let answer = render.answer(active.run)
  let closing =
    [
      // A code channel's Code tab already lists what changed.
      case state.venue {
        venue.CodeChannel(..) -> None
        _ -> render.changes(changes)
      },
      case active.run.outcome, active.cancel_note {
        Some(run.Cancelled), Some(note) -> Some("_" <> note <> "_")
        _, _ -> render.note(active.run, answer != [])
      },
    ]
    |> option.values
    |> string.join("\n\n")
  // The reply ends the run. It holds what the agent said, its steps, and a line
  // that names the changed files.
  let active = show_progress(sink, state.config.root, active)
  let reply_ts = case active.reply, closing {
    Some(reply), _ -> reply.finish(closing) |> list.last |> result.unwrap("")
    None, "" -> ""
    None, closing -> sink.post(closing) |> result.unwrap("")
  }
  sink.working(False)
  case patch, string.byte_size(patch) > max_patch_bytes {
    "", _ -> Nil
    _, True ->
      sys.warn("crushling: patch too large to attach: " <> active.run.run_id)
    patch, False ->
      case
        sink.upload(string.slice(active.run.run_id, 0, 8) <> ".diff", patch)
      {
        Ok(Nil) -> Nil
        Error(reason) -> sys.warn("crushling: upload failed: " <> reason)
      }
  }
  state.config.notify(
    RunEnded(Finished(
      solicited: active.solicited,
      run_id: active.run.run_id,
      outcome: option.unwrap(active.run.outcome, run.Cancelled),
      text: string.join(answer, "\n\n"),
      reply_ts:,
      changes:,
      patch:,
    )),
  )
}

fn close_connection(state: State) -> Nil {
  case state.connection {
    Some(connection) -> conn.close(connection)
    None -> Nil
  }
}
