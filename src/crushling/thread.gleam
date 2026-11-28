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
//// the venue, and its sink always follows from it. It tells the registry
//// about each change through `notify`.
////
//// Anything slow (connecting, scanning the workspace's repositories,
//// reading their diffs) runs in a process of its own and reports back with
//// an `Internal` message, so the actor stays free to answer.

import crushling/agent/post_mortem.{type PostMortem}
import crushling/conversation.{type Conversation}
import crushling/crush/catalog
import crushling/crush/client
import crushling/crush/event
import crushling/git
import crushling/gun
import crushling/meta.{type ModelChoice}
import crushling/pr
import crushling/run
import crushling/sink.{type Sink, type Surface}
import crushling/slack/model_card
import crushling/sys
import crushling/thread/channel
import crushling/thread/conn.{type Connection}
import crushling/thread/link.{type Link}
import crushling/thread/model
import crushling/thread/progress
import crushling/thread/resume
import crushling/thread/say
import crushling/thread/subagents.{type Subagents}
import crushling/thread/turn.{type Turn}
import crushling/thread/workspace
import crushling/venue.{type Venue}
import gleam/erlang/process.{type Subject, type Timer}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result

pub type Finished {
  Finished(
    /// Whether this was a prompt the bridge sent, rather than a turn crush
    /// started by itself to read a subagent's report.
    solicited: Bool,
    /// The last message of the reply, or "" when nothing was posted.
    reply_ts: String,
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
  /// The thread's model choice changed: `Some` for a model someone picked,
  /// `None` for the default. The registry saves it, so a new actor for the
  /// thread starts with it.
  ModelChosen(choice: Option(ModelChoice))
  /// How many background jobs the agent has running, for the registry's
  /// idle check of `generation`.
  JobsRunning(generation: Int, running: Int)
  /// A card proposing `proposal` was posted in `channel` at `card_ts`; its
  /// buttons come to the registry.
  Proposed(card_ts: String, channel: String, proposal: pr.Proposal)
  /// The agent is gone (its sandbox died, say of running out of memory) and
  /// reconnecting gave up. The registry stops what's left of it, so the
  /// next message starts a new one.
  Lost
}

pub type Config {
  Config(
    socket: String,
    /// The workspace path as the server sees it, inside the sandbox.
    root: String,
    title: String,
    /// Where the work starts.
    venue: Venue,
    /// The sink for each venue (`slack/sink.surface`): the thread posts through
    /// the one for where its work is now.
    sink: Surface,
    /// How often an in-progress message is re-rendered, in milliseconds.
    flush_ms: Int,
    /// Yolo skips permission prompts; sysadmin also lifts crush's block
    /// list of dangerous commands.
    mode: client.PermissionMode,
    notify: fn(Notice) -> Nil,
    /// Called with the event stream's connection each time it attaches. Tests
    /// use it to drop the connection; elsewhere it does nothing.
    on_connect: fn(gun.Conn) -> Nil,
    /// The model picked for the thread, if any. crush keeps a session's model
    /// only in memory, so it is pinned again on every connect.
    model: Option(ModelChoice),
    /// The thread's own channel and ts, for its `!model` cards.
    home: #(String, String),
    /// Why the agent went quiet, asked once reconnecting gives up and
    /// before the agent is stopped, for the note ending the run.
    post_mortem: fn() -> PostMortem,
  )
}

/// The conversation the thread posts to now, and the workspace path that the
/// agent sees.
pub type Location {
  Location(conversation: Conversation, root: String)
}

pub type Message {
  /// A prompt for the agent. `attachments` are files the model should see
  /// directly, such as images. `from` is the user who asked, or "" if not
  /// known, because Slack streams each reply to one person.
  Prompt(text: String, attachments: List(client.Attachment), from: String)
  Where(reply: Subject(Location))
  /// Who sent the prompt being worked on, or the last one: whose GitHub
  /// the agent uses. "" before anyone has.
  Requester(reply: Subject(String))
  /// Where the work stands, for `!info`: a few lines of Slack markdown.
  Info(reply: Subject(String))
  /// Post a card proposing a PR for the pushed branch (`/pr`, or the
  /// agent's `propose_pr`). `answer` gets what was done, or why not.
  Propose(
    title: String,
    body: String,
    answer: fn(Result(String, String)) -> Nil,
  )
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
  /// `!model`, with or without a model to switch to.
  ModelCommand(request: catalog.Request, user: String)
  /// Someone picked on the card posted as `card_ts`.
  CardPicked(pick: model_card.Pick, card_ts: String, user: String)
  /// Count the agent's running background jobs for the registry's idle
  /// check of `generation`; answered with `JobsRunning`.
  CountJobs(generation: Int)
  /// What the thread's own helper processes report back.
  Internal(Inner)
}

pub opaque type Inner {
  /// A connection attempt made off the actor ended.
  Connected(Result(Connection, String))
  /// Cancel the run once the connection is back.
  Recancel
  /// A scan for a repository the agent changed ended, with what it found.
  Scanned(Result(git.Found, Nil))
}

/// The scan for a changed repository, run off the actor. Changes that come
/// in while one runs are looked at by one more scan, not one each.
type Scan {
  Idle
  Scanning(again: Bool)
}

type Queued {
  Queued(
    text: String,
    attachments: List(client.Attachment),
    from: String,
    /// When it reached the thread, in monotonic ms.
    at_ms: Int,
  )
}

type State {
  State(
    config: Config,
    self: Subject(Message),
    target: conn.Target,
    link: Link,
    resume: resume.Resume,
    venue: Venue,
    waiting: List(Queued),
    /// Who sent the latest prompt, for turns crush starts on its own.
    requester: String,
    turn: Option(Turn),
    /// Messages that need the connection, held while it comes up; newest
    /// first.
    deferred: List(Message),
    scan: Scan,
    /// The pending re-render, if one is scheduled.
    flush: Option(Timer),
    subs: Subagents,
    /// Whether the Slack session has its title.
    titled: Bool,
    /// What the thread is about, as crush titled its session: a code
    /// channel opened without a name is named after it.
    topic: String,
    /// The busy state last sent to the registry.
    reported_busy: Bool,
    /// Where the session is shown as working, if anywhere.
    working_in: Option(Sink),
    /// The model picked for the thread, pinned on every connect.
    model: Option(ModelChoice),
    /// The connected server's model catalog, once fetched.
    catalog: Option(List(catalog.Model)),
  )
}

const watchdog_ms = 60_000

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
      link: link.new(),
      resume: resume.fresh(),
      venue: config.venue,
      waiting: [],
      requester: "",
      turn: None,
      deferred: [],
      scan: Idle,
      flush: None,
      subs: subagents.new(),
      titled: False,
      topic: "",
      reported_busy: False,
      working_in: None,
      model: config.model,
      catalog: None,
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
      case state.turn {
        Some(turn) -> close_reply(state, turn, "")
        None -> Nil
      }
      let _ = show_working(state, False)
      // An attempt still under way closes itself once it finds the actor gone.
      case connection(state) {
        Some(connection) -> conn.retire(connection, state.target)
        None -> Nil
      }
      actor.stop()
    }
    _ -> actor.continue(step(state, message) |> report)
  }
}

fn step(state: State, message: Message) -> State {
  case needs_link(message) && link.awaiting(state.link) {
    True -> State(..state, deferred: [message, ..state.deferred])
    False -> dispatch(state, message)
  }
}

/// Whether a message is about the agent, so it waits for the connection
/// instead of failing while one is coming up.
fn needs_link(message: Message) -> Bool {
  case message {
    Info(_)
    | Propose(..)
    | OpenCodeChannel(..)
    | ModelCommand(..)
    | CardPicked(..)
    | CountJobs(_)
    | Internal(Recancel) -> True
    _ -> False
  }
}

/// Handle what was held for the connection, oldest first.
fn replay(state: State) -> State {
  list.fold(list.reverse(state.deferred), State(..state, deferred: []), step)
}

fn dispatch(state: State, message: Message) -> State {
  case message {
    Setup | Reconnect -> connect(state)
    Internal(Connected(result)) -> connected(state, result)
    Internal(Recancel) -> {
      case connection(state), state.turn {
        Some(connection), Some(_) -> conn.cancel(connection)
        _, _ -> Nil
      }
      state
    }
    Internal(Scanned(found)) -> scanned(state, found)
    Prompt(text, attachments, from) ->
      State(
        ..state,
        waiting: list.append(state.waiting, [
          Queued(text, attachments, from, sys.monotonic_ms()),
        ]),
      )
      // Shown as working now, so a send that fails is shown as done again.
      |> report
      |> send_next
    Where(reply) -> {
      process.send(reply, Location(here(state).conversation, state.config.root))
      state
    }
    Info(reply) -> {
      info(state, reply)
      state
    }
    Propose(title:, body:, answer:) -> {
      answer(propose(state, title, body))
      state
    }
    Requester(reply) -> {
      process.send(reply, reader(state))
      state
    }
    // A progress update mid-run goes after the reply so far, which ends
    // there; what the run does next starts a new reply below it, so the
    // thread reads in order.
    Say(text, reply) -> {
      let current = case state.turn {
        Some(current) ->
          case turn.reply(current) {
            Some(_) -> {
              close_reply(state, current, "")
              Some(turn.split(current))
            }
            None -> Some(current)
          }
        None -> None
      }
      process.send(reply, here(state).post(text))
      State(..state, turn: current)
    }
    OpenCodeChannel(name, dir, reply) -> {
      let #(state, result) = move(state, dir, name)
      process.send(reply, result)
      state
    }
    Cancel(note) -> cancel(state, note)
    Flush -> flush(State(..state, flush: None))
    Watchdog -> watchdog(state)
    Gun(message) -> on_gun(state, message)
    ModelCommand(request, user) ->
      with_model(state, model.command(_, request, user))
    CardPicked(pick, card_ts, user) ->
      with_model(state, model.pick(_, pick, card_ts, user))
    CountJobs(generation) -> {
      let running =
        connection(state) |> option.map(conn.running_jobs) |> option.unwrap(0)
      state.config.notify(JobsRunning(generation:, running:))
      state
    }
    Stop -> state
  }
}

/// The sink for where the work is now.
fn here(state: State) -> Sink {
  state.config.sink(state.venue)
}

/// Who the agent works for: whoever asked for the turn under way, else
/// whoever asked last.
fn reader(state: State) -> String {
  option.then(state.turn, turn.asker) |> option.unwrap(state.requester)
}

/// Tell the registry when the thread starts or stops being busy, and show
/// the session as working exactly while it is.
fn report(state: State) -> State {
  let busy =
    state.turn != None || state.waiting != [] || subagents.running(state.subs)
  let state = case busy == state.reported_busy {
    True -> state
    False -> {
      state.config.notify(Activity(busy))
      State(..state, reported_busy: busy)
    }
  }
  show_working(state, busy)
}

fn show_working(state: State, busy: Bool) -> State {
  State(..state, working_in: sink.mark(state.working_in, here(state), busy))
}

/// Mark the session working again on the next report: Slack drops the mark
/// after an hour.
fn remark(state: State) -> State {
  State(..state, working_in: None)
}

fn parent(state: State) -> subagents.Parent {
  subagents.Parent(
    session_id: option.unwrap(state.resume.session_id, ""),
    sink: here(state),
    root: state.config.root,
    threads: case state.venue {
      venue.CodeChannel(..) -> True
      _ -> False
    },
  )
}

fn cancel(state: State, note: Option(String)) -> State {
  subagents.close(state.subs, option.map(note, say.aside) |> option.unwrap(""))
  case state.turn {
    Some(turn) ->
      State(
        ..state,
        waiting: [],
        turn: Some(turn.Turn(..turn, stop_note: note)),
      )
      |> step(Internal(Recancel))
    None -> State(..state, waiting: [])
  }
}

// Connection ------------------------------------------------------------------

fn connection(state: State) -> Option(Connection) {
  link.connection(state.link)
}

/// Connect (or reconnect) to the server, join the workspace, open the event
/// stream, and get a session, all off the actor; `connected` takes it from
/// there.
fn connect(state: State) -> State {
  let self = state.self
  let link =
    link.connect(state.link, state.target, state.resume, fn(result) {
      process.send(self, Internal(Connected(result)))
    })
  State(..state, link:)
}

/// A connection attempt ended.
///
/// A reconnect rejoins the same workspace when the server still has it, and
/// resumes the event stream after the last event handled. The server then
/// replays what was missed, so a run that went on, or even ended, while the
/// stream was down carries on as if nothing happened. If it can't, the stream
/// starts with a resync, and `on_sse` settles the run. Without an event to
/// resume from, the run is settled at once.
///
/// `conn.open` returns once the event stream is attached, so queued prompts
/// are only sent, and an orphaned run only settled, on a ready connection.
fn connected(state: State, result: Result(Connection, String)) -> State {
  let #(link, attempted) = link.attempted(state.link, result)
  let state = State(..state, link:)
  case attempted {
    link.Joined(connection) -> {
      state.config.on_connect(connection.events)
      let resume =
        resume.joined(
          state.resume,
          connection.workspace_id,
          connection.session_id,
        )
      let state = State(..state, resume:)
      // Reaching a server that may be new (the workspace wasn't still on
      // it), the catalog may differ and any pin is gone: pin the thread's
      // choice again. The same server still has both.
      let state = case connection.reused {
        True -> state
        False ->
          State(..state, catalog: None)
          |> with_model(model.restore(_, state.model))
      }
      case connection.resumed {
        True -> state
        False -> settle_orphan(state, connection)
      }
      |> replay
      |> send_next
    }
    link.Retry(after_ms:) -> {
      process.send_after(state.self, after_ms, Reconnect)
      state
    }
    link.GaveUp -> {
      // Asked first: the registry stops what's left once it hears.
      let why = state.config.post_mortem()
      state.config.notify(Lost)
      replay(state) |> fail_everything(say.lost(why))
    }
    link.Stale -> state
  }
}

/// After a reconnect that could not replay what was missed, a run whose
/// `run_complete` may have been missed is finished with what was seen, unless
/// the session is still busy.
fn settle_orphan(state: State, connection: Connection) -> State {
  case state.turn {
    None -> state
    Some(current) ->
      case conn.busy(connection) {
        Ok(True) -> state
        _ -> {
          let outcome = run.Errored("lost the connection mid-run")
          let run = run.Run(..current.run, outcome: Some(outcome))
          State(..state, turn: Some(turn.Turn(..current, run:)))
          |> finish_if_done
        }
      }
  }
}

fn on_gun(state: State, message: gun.Message) -> State {
  case link.hear(state.link, message), connection(state) {
    link.Event(sse), Some(connection) -> on_sse(state, connection, sse)
    link.Dropped, _ -> {
      process.send(state.self, Reconnect)
      State(..state, link: link.drop(state.link))
    }
    _, _ -> state
  }
}

/// Handle an event from the stream, once. An event with an id that was
/// already handled, before a drop or earlier in a replay, is skipped.
fn on_sse(state: State, connection: Connection, sse: gun.SseEvent) -> State {
  case event.parse(sse.data) {
    Ok(event.Resync(reason:, ..)) -> {
      sys.warn("crushling: event stream could not resume: " <> reason)
      let cursor = resume.resynced(state.resume.cursor, sse.id)
      State(..state, resume: resume.Resume(..state.resume, cursor:))
      |> settle_orphan(connection)
    }
    parsed -> {
      let #(fresh, cursor) = resume.admit(state.resume.cursor, sse.id)
      let state = State(..state, resume: resume.Resume(..state.resume, cursor:))
      case fresh, parsed {
        True, Ok(parsed) -> on_event(state, parsed)
        _, _ -> state
      }
    }
  }
}

// Models ----------------------------------------------------------------------

/// Run a `thread/model` step on the connection, then keep what it found and
/// tell the registry about a changed choice.
fn with_model(state: State, step: fn(model.Context) -> model.Done) -> State {
  let #(catalog, model, changed) =
    model.choose(
      connection(state),
      here(state),
      state.config.home,
      state.catalog,
      state.model,
      step,
    )
  case changed {
    True -> state.config.notify(ModelChosen(model))
    False -> Nil
  }
  State(..state, catalog:, model:)
}

// Turns -----------------------------------------------------------------------

/// End every run with `note`, already mrkdwn.
fn fail_everything(state: State, note: String) -> State {
  let open =
    option.then(state.turn, fn(current) {
      turn.reply(current) |> option.map(fn(_) { current })
    })
  case state.waiting, state.turn, open {
    [], None, _ -> Nil
    // An open reply ends with the note instead.
    _, _, Some(current) -> close_reply(state, current, note)
    _, _, None -> {
      let _ = here(state).post(note)
      Nil
    }
  }
  State(..state, waiting: [], turn: None)
}

fn send_next(state: State) -> State {
  case state.turn, connection(state), state.waiting {
    None, Some(connection), [next, ..rest] ->
      send_prompt(State(..state, waiting: rest), connection, next)
    _, _, _ -> state
  }
}

fn send_prompt(state: State, connection: Connection, next: Queued) -> State {
  let run_id = sys.uuid()
  let base = workspace.snapshot(shell(state))
  let prepared = sys.monotonic_ms()
  case conn.prompt(connection, run_id, next.text, next.attachments) {
    Ok(Nil) -> {
      case state.titled {
        True -> Nil
        False -> sink.title(here(state), say.session_title(next.text))
      }
      process.send_after(state.self, watchdog_ms, Watchdog)
      let run = run.new(connection.session_id, run_id)
      let sent_ms = sys.monotonic_ms()
      let started =
        turn.asked(run, next.from, base, next.at_ms, prepared, sent_ms)
      let state =
        State(..state, titled: True, requester: next.from, turn: Some(started))
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
      let _ = here(state).post(say.not_sent(conn.describe(error)))
      send_next(state)
    }
  }
}

fn on_event(state: State, event: event.Event) -> State {
  let state = case event {
    event.SessionEvent(id:, title:, ..)
      if Some(id) == state.resume.session_id
      && title != ""
      && title != "New Agent Session"
    -> State(..state, topic: title)
    _ -> state
  }
  let state =
    State(..state, subs: subagents.track(state.subs, parent(state), event))
    |> adopt_report_turn(event)
  let state = case state.turn {
    None -> state
    Some(current) ->
      State(
        ..state,
        turn: Some(turn.observe(current, event, sys.monotonic_ms())),
      )
      |> move_on_change(event)
      |> finish_if_done
  }
  case state.turn != None || subagents.running(state.subs), state.flush {
    True, None -> {
      let timer = process.send_after(state.self, state.config.flush_ms, Flush)
      State(..state, flush: Some(timer))
    }
    _, _ -> state
  }
}

/// Crush wakes the parent with a turn of its own when a subagent reports
/// and nothing is running. That turn carries no run id of ours, so adopt it
/// as an unsolicited run when its report message appears.
fn adopt_report_turn(state: State, event: event.Event) -> State {
  let parent = option.unwrap(state.resume.session_id, "")
  case state.turn, event {
    None, event.MessageEvent(op: "created", message:)
      if message.session_id == parent && message.reports != []
    -> {
      process.send_after(state.self, watchdog_ms, Watchdog)
      let run = run.new(message.session_id, "")
      State(..state, turn: Some(turn.report(run, sys.monotonic_ms())))
    }
    _, _ -> state
  }
}

fn finish_if_done(state: State) -> State {
  case state.turn {
    Some(current) ->
      case run.is_done(current.run) {
        True -> {
          finish(state, current)
          State(..state, turn: None)
          |> send_next
        }
        False -> state
      }
    None -> state
  }
}

fn finish(state: State, current: Turn) -> Nil {
  let patch = patch_for(state, current)
  // The reply ends the run. It holds what the agent said and its steps; what
  // changed is in the Code tab, or the patch attached below.
  let reply_ts = progress.end(place(state), current)
  case patch {
    Some(patch) -> progress.attach(here(state), current.run.run_id, patch)
    None -> Nil
  }
  case turn.timings(turn.finished(current, sys.monotonic_ms())) {
    Some(timings) ->
      sys.info("crushling: " <> state.config.title <> ": turn " <> timings)
    None -> Nil
  }
  state.config.notify(
    RunEnded(Finished(solicited: turn.solicited(current), reply_ts:)),
  )
}

/// The patch to attach for the run, if any. A code channel's Code tab shows
/// the diff instead, so it gets none.
fn patch_for(state: State, current: Turn) -> Option(String) {
  case state.venue {
    venue.CodeChannel(repo: dir, ..) -> {
      show_code(state, here(state), dir, None)
      None
    }
    at -> {
      let base = case current.origin {
        turn.Asked(base:, ..) -> base
        turn.ReportTurn -> None
      }
      workspace.patch(shell(state), at, base, current.run.run_id)
    }
  }
}

// Showing the turn ------------------------------------------------------------

/// Re-render the in-progress run if it changed since it was last shown.
fn flush(state: State) -> State {
  let state = State(..state, subs: subagents.show(state.subs, parent(state)))
  let state = case state.turn {
    Some(current) ->
      State(..state, turn: Some(progress.show(place(state), current)))
    None -> state
  }
  // Keep flushing while subagents work after the main run has ended.
  case state.turn == None && subagents.running(state.subs) {
    True -> {
      let timer =
        process.send_after(state.self, state.config.flush_ms * 2, Flush)
      State(..state, flush: Some(timer))
    }
    False -> state
  }
}

fn watchdog(state: State) -> State {
  case state.turn {
    None -> state
    Some(current) -> {
      process.send_after(state.self, watchdog_ms, Watchdog)
      let #(current, tick) = turn.tick(current, sys.monotonic_ms())
      let state = State(..state, turn: Some(current))
      case tick {
        turn.Quiet -> state
        turn.Rework -> remark(state)
        // Still shown as working: the run hasn't ended, and Slack's Stop
        // button is the easiest way to end it.
        turn.Stall -> {
          let _ = here(state).post(say.stalled)
          remark(state)
        }
      }
    }
  }
}

fn place(state: State) -> progress.Place {
  progress.Place(here(state), state.config.root, state.subs, reader(state))
}

fn close_reply(state: State, current: Turn, note: String) -> Nil {
  progress.close(place(state), current, note)
}

// The workspace ---------------------------------------------------------------

fn shell(state: State) -> git.Shell {
  workspace.shell(connection(state), state.target)
}

fn show_code(
  state: State,
  sink: Sink,
  dir: String,
  info: Option(git.RepoInfo),
) -> Nil {
  case connection(state), sink.code_view {
    Some(connection), Some(view) ->
      workspace.show_code(connection, state.target, view, dir, info)
    _, _ -> Nil
  }
}

fn info(state: State, reply: Subject(String)) -> Nil {
  case venue.repo(state.venue), connection(state) {
    None, _ -> process.send(reply, say.no_repo)
    _, None -> process.send(reply, say.asleep)
    Some(dir), Some(connection) ->
      workspace.status(connection, state.target, dir, process.send(reply, _))
  }
}

/// When the agent first changes a repository in a plain thread (edits a
/// file in it, or commits), move the work to a code channel for it.
/// Cloning to read, as for a review, keeps the work in the thread.
fn move_on_change(state: State, event: event.Event) -> State {
  case state.venue, state.turn, event {
    venue.Thread, Some(current), event.MessageEvent(message:, ..) ->
      case workspace.may_change(message, current.run), state.scan {
        False, _ -> state
        True, Idle -> scan_repos(state)
        True, Scanning(_) -> State(..state, scan: Scanning(again: True))
      }
    _, _, _ -> state
  }
}

/// Look for a changed repository off the actor; `scanned` gets the answer.
fn scan_repos(state: State) -> State {
  case connection(state) {
    None -> State(..state, scan: Idle)
    Some(connection) -> {
      let self = state.self
      workspace.find_changed(connection, state.target, fn(found) {
        process.send(self, Internal(Scanned(found)))
      })
      State(..state, scan: Scanning(again: False))
    }
  }
}

fn scanned(state: State, found: Result(git.Found, Nil)) -> State {
  case found, state.scan, state.venue {
    Ok(found), _, venue.Thread ->
      open_code_channel(State(..state, scan: Idle), found, "").0
    Error(Nil), Scanning(again: True), venue.Thread -> scan_repos(state)
    _, _, _ -> State(..state, scan: Idle)
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
  case state.venue {
    venue.CodeChannel(..) -> #(
      state,
      Error("the work is already in a code channel"),
    )
    _ ->
      case git.find(shell(state), dir) {
        Error(reason) -> #(state, Error(reason))
        Ok(found) -> open_code_channel(state, found, name)
      }
  }
}

fn open_code_channel(
  state: State,
  found: git.Found,
  name: String,
) -> #(State, Result(String, String)) {
  let name = channel.name(name, state.topic, found)
  let thread = here(state)
  state.config.notify(Opening)
  case channel.open(thread, found, name) {
    channel.Refused(venue:, reason:) -> {
      state.config.notify(Moved(venue, ""))
      #(State(..state, venue:), Error(reason))
    }
    channel.Opened(venue: to, channel:, ts:) -> {
      state.config.notify(Moved(to, ts))
      let note = say.moved(found.name, channel)
      // Said once: as the end of the reply in the thread when a run is under
      // way (the rest of it goes to the channel, starting after what was
      // already said), else on its own.
      let current = case state.turn {
        Some(current) -> {
          close_reply(state, current, note)
          Some(turn.moved(current))
        }
        None -> {
          let _ = thread.post(note)
          None
        }
      }
      let state = State(..state, venue: to, turn: current)
      sink.title(here(state), name)
      show_code(state, here(state), found.dir, Some(found.info))
      #(state, Ok(channel))
    }
  }
}

/// Post a card proposing a PR for the repository's pushed branch.
fn propose(
  state: State,
  title: String,
  body: String,
) -> Result(String, String) {
  let shell = shell(state)
  use proposal <- result.try(workspace.proposal(shell, state.venue, title, body))
  let #(text, blocks) = pr.card(proposal)
  let sink = here(state)
  use ts <- result.map(sink.post_blocks(text, blocks))
  state.config.notify(Proposed(ts, sink.conversation.channel, proposal))
  say.proposed(proposal.head, proposal.base)
}
