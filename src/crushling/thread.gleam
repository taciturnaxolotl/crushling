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
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string

/// Where replies go. Implemented over the Slack Web API in production and
/// by a test double in tests.
pub type Sink {
  Sink(
    /// Mark the thread's agent session as working (Slack shows "Working…"
    /// and its Stop control) or as ready for the next prompt.
    working: fn(Bool) -> Nil,
    /// Name the session, from the prompt that started it.
    title: fn(String) -> Nil,
    /// Post the plan card, returning its id (Slack's `ts`).
    post_plan: fn(render.Plan) -> Result(String, String),
    update_plan: fn(String, render.Plan) -> Result(Nil, String),
    /// Start a streamed message showing `chunks`, and return its id
    /// (Slack's `ts`).
    start_stream: fn(List(render.Chunk)) -> Result(String, String),
    /// Add to a streamed message.
    append_stream: fn(String, List(render.Chunk)) -> Result(Nil, String),
    /// Finish a streamed message with its last pieces.
    stop_stream: fn(String, List(render.Chunk)) -> Result(Nil, String),
    /// Post a markdown message.
    post: fn(String) -> Result(String, String),
    /// Attach a file to the thread: name, then contents.
    upload: fn(String, String) -> Result(Nil, String),
    /// Called once per run after its reply is posted.
    finished: fn(Finished) -> Nil,
    /// Start a new top-level thread with `intro` as its first message and
    /// `title` as its session's name, for a subagent to work in. Returns a
    /// sink for that thread and a link to it.
    branch: fn(String, String) -> Result(#(Sink, String), String),
    /// Move the work to a code channel named `name`, for the repository in
    /// workspace directory `repo`. Returns the channel's sink and id. Only
    /// a thread can move; a code channel answers with an error.
    open_code_channel: fn(String, String) -> Result(#(Sink, String), String),
    /// Set the code channel's context bar. A thread ignores it.
    context: fn(List(ContextItem)) -> Nil,
    /// Set the code channel's Code tab: a unified diff, the base branch and
    /// the head branch. A thread ignores it.
    code: fn(String, String, String) -> Nil,
    /// The channel posts go to, and the thread's ts ("" for a code
    /// channel's top level).
    conversation: #(String, String),
  )
}

pub type ContextItem {
  ContextItem(key: String, label: String, icon: String, url: String)
}

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

pub type Config {
  Config(
    socket: String,
    /// The workspace path as the server sees it, inside the sandbox.
    root: String,
    title: String,
    sink: Sink,
    /// How often an in-progress message is re-rendered, in milliseconds.
    flush_ms: Int,
    /// Yolo skips permission prompts; sysadmin also lifts crush's block
    /// list of dangerous commands.
    mode: client.PermissionMode,
    /// The repository the thread works on, once it moved to a code
    /// channel: its directory in the workspace. "" for a plain thread.
    repo: String,
    /// Whether `sink` is the repository's code channel. A thread with a
    /// `repo` that isn't has had its channel archived, and moves to a new
    /// one with its next prompt.
    in_code_channel: Bool,
  )
}

pub type Message {
  Prompt(text: String)
  /// A prompt with files the model should see directly, such as images.
  PromptWith(text: String, attachments: List(client.Attachment))
  /// Where the thread is talking now: the channel, the thread's ts ("" in
  /// a code channel), and the workspace path as the agent sees it.
  Where(reply: Subject(#(String, String, String)))
  /// Post a message where the thread is talking, for the agent's own
  /// tools; replies with the message's ts.
  Say(text: String, reply: Subject(Result(String, String)))
  /// Move the work to a code channel, for the agent's own tools.
  OpenCodeChannel(
    name: String,
    repo: String,
    reply: Subject(Result(String, String)),
  )
  Cancel
  /// Cancel the running turn and anything queued, closing the run with
  /// `note` rather than the usual "stopped".
  CancelFor(note: String)
  Stop
  Setup
  Flush
  /// Periodic check that the active run is still making progress.
  Watchdog
  /// Whether anything is going on: a run, a queued prompt, or a subagent
  /// still working.
  Busy(reply: Subject(Bool))
  Reconnect
  Gun(gun.Message)
}

type Active {
  Active(
    run: Run,
    /// The plan card, once posted, and what it last showed.
    plan_ts: Option(String),
    shown: Option(render.Plan),
    /// Where the run is being shown.
    display: Display,
    /// The workspace snapshot taken just before the prompt was sent.
    base: Option(String),
    /// When the session was last marked working: Slack lets it lapse after
    /// an hour, so a long run marks it again.
    working_since_ms: Int,
    last_event_ms: Int,
    /// Whether the stall note has been posted for this run.
    stalled: Bool,
    /// Said in place of "stopped" when the run was cancelled for a reason.
    cancel_note: Option(String),
    /// False for a turn crush started on its own to read a subagent report.
    solicited: Bool,
  )
}

/// A subagent, shown in a Slack thread of its own.
type Sub {
  Sub(
    /// The tool call that started it, its key in `subs`.
    key: String,
    /// The name crush gave a dispatched one, like "madeline-crush-server-api".
    label: String,
    /// What crush titled its session.
    title: String,
    run: Run,
    /// Its thread, once opened, and the link to it.
    sink: Option(Sink),
    link: String,
    plan_ts: Option(String),
    shown: Option(render.Plan),
    /// The ids of its messages already posted in its thread.
    posted: List(String),
    /// Set when its report arrives.
    done: Bool,
  )
}

type Conns {
  Conns(requests: gun.Conn, events: gun.Conn, stream: gun.StreamRef)
}

type Ready {
  Ready(workspace_id: String, session_id: String, resumed: Bool)
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
    waiting: List(#(String, List(client.Attachment))),
    active: Option(Active),
    known: run.Known,
    flushing: Bool,
    /// Subagents the agent dispatched, by their session id.
    subs: dict.Dict(String, Sub),
    /// The repository directory once the work is in a code channel.
    repo: Option(String),
    /// Move to a new code channel with the next prompt.
    reopen: Bool,
    retries: Int,
    /// Whether the Slack session has its title: set for a session crushling
    /// created, and for one found in place after a restart.
    titled: Bool,
  )
}

const max_retries = 8

/// With no event from the agent for this long, say so in the thread.
const stall_ms = 600_000

const watchdog_ms = 60_000

/// Slack drops a session out of working after an hour; mark it again well
/// before.
const rework_ms = 1_800_000

/// A session title from the first prompt: its first line, kept short.
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

@external(erlang, "crushling_ffi", "monotonic_ms")
fn now_ms() -> Int

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
      subs: dict.new(),
      repo: case config.repo, config.in_code_channel {
        "", _ | _, False -> None
        repo, True -> Some(repo)
      },
      reopen: config.repo != "" && !config.in_code_channel,
      retries: 0,
      titled: False,
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
      State(..state, waiting: list.append(state.waiting, [#(text, [])]))
      |> send_next
      |> actor.continue
    PromptWith(text, attachments) ->
      State(
        ..state,
        waiting: list.append(state.waiting, [#(text, attachments)]),
      )
      |> send_next
      |> actor.continue
    Where(reply) -> {
      let #(channel, thread_ts) = state.config.sink.conversation
      process.send(reply, #(channel, thread_ts, state.config.root))
      actor.continue(state)
    }
    Say(text, reply) -> {
      process.send(reply, state.config.sink.post(text))
      actor.continue(state)
    }
    OpenCodeChannel(name, repo, reply) -> {
      let #(state, result) = move_to(state, repo, name)
      process.send(reply, result)
      actor.continue(state)
    }
    Cancel -> actor.continue(cancel(state, None))
    CancelFor(note) -> actor.continue(cancel(state, Some(note)))
    Flush -> actor.continue(flush(State(..state, flushing: False)))
    Watchdog -> actor.continue(watchdog(state))
    Busy(reply) -> {
      process.send(reply, is_busy(state))
      actor.continue(state)
    }
    Gun(message) -> actor.continue(on_gun(state, message))
    Stop -> {
      shutdown(state)
      actor.stop()
    }
  }
}

fn cancel(state: State, note: Option(String)) -> State {
  case state.ready, state.conns, state.active {
    Some(ready), Some(conns), Some(active) -> {
      let _ = call(conns, client.cancel(ready.workspace_id, ready.session_id))
      let active = Active(..active, cancel_note: note)
      State(..state, waiting: [], active: Some(active))
    }
    _, _, _ -> State(..state, waiting: [])
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
      client.create_workspace(config.root, state.client_id, config.mode, []),
    )
    |> result.map_error(fail),
  )
  let stream =
    gun.stream(events, client.events_path(workspace_id, state.client_id), [])
  let conns = Conns(requests:, events:, stream:)
  let setup = {
    use _ <- result.try(call(conns, client.init_agent(workspace_id, True)))
    use _ <- result.try(wait_ready(conns, workspace_id, ready_attempts))
    case state.session_id {
      Some(id) -> Ok(#(id, True))
      None ->
        case call(conns, client.latest_session(workspace_id)) {
          Ok(Some(id)) -> Ok(#(id, True))
          _ ->
            call(conns, client.create_session(workspace_id, config.title))
            |> result.map(fn(id) { #(id, False) })
        }
    }
  }
  case setup {
    Ok(#(session_id, resumed)) ->
      Ok(#(conns, Ready(workspace_id:, session_id:, resumed:)))
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
    None, Some(ready), Some(conns), [#(text, attachments), ..rest] ->
      send_prompt(
        State(..state, waiting: rest),
        conns,
        ready,
        text,
        attachments,
      )
    _, _, _, _ -> state
  }
}

fn send_prompt(
  state: State,
  conns: Conns,
  ready: Ready,
  text: String,
  attachments: List(client.Attachment),
) -> State {
  let run_id = uuid()
  let base = take_snapshot(state, conns, ready)
  case
    call(
      conns,
      client.send_prompt_with(
        workspace_id: ready.workspace_id,
        session_id: ready.session_id,
        run_id:,
        prompt: text,
        attachments:,
      ),
    )
  {
    Ok(Nil) -> {
      state.config.sink.working(True)
      case state.titled {
        True -> Nil
        False -> state.config.sink.title(session_title(text))
      }
      let state = State(..state, titled: True)
      process.send_after(state.self, watchdog_ms, Watchdog)
      let run = run.new(ready.session_id, run_id)
      let now = now_ms()
      let active =
        Active(
          run:,
          plan_ts: None,
          shown: None,
          display: Unshown,
          base:,
          working_since_ms: now,
          last_event_ms: now,
          stalled: False,
          cancel_note: None,
          solicited: True,
        )
      let state = State(..state, active: Some(active))
      case state.reopen {
        True -> move_to_code_channel(State(..state, reopen: False))
        False -> state
      }
    }
    Error(client.Transport(_)) -> {
      process.send(state.self, Reconnect)
      State(..state, waiting: [#(text, attachments), ..state.waiting])
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
  let state = state |> track_subs(event) |> adopt_report_turn(event)
  let state = case state.active {
    None -> state
    Some(active) -> {
      let run = run.apply(active.run, state.known, event)
      let active = Active(..active, run:, last_event_ms: now_ms())
      State(..state, active: Some(active))
      |> move_on_clone(event)
      |> finish_if_done
    }
  }
  case state.active != None || has_running_subs(state), state.flushing {
    False, _ | _, True -> state
    True, False -> {
      process.send_after(state.self, state.config.flush_ms, Flush)
      State(..state, flushing: True)
    }
  }
}

/// When a bash call that cloned a repository succeeds in a plain thread,
/// move the work to a code channel for that repository.
fn move_on_clone(state: State, event: event.Event) -> State {
  case state.repo, state.active, event {
    None, Some(active), event.MessageEvent(message:, ..)
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
        True -> move_to_code_channel(state)
        False -> state
      }
    }
    _, _, _ -> state
  }
}

fn shell_now(state: State, command: String) -> Result(String, Nil) {
  case state.conns, state.ready {
    Some(conns), Some(ready) -> shell(state, conns, ready, command)
    _, _ -> Error(Nil)
  }
}

fn move_to_code_channel(state: State) -> State {
  move_to(state, "", "").0
}

/// Move the work to a code channel for the repository in workspace
/// directory `repo`, named `name`. With no `repo` the first repository in
/// the workspace is used, and with no `name` the channel is named after
/// the repository. Returns the channel's id.
fn move_to(
  state: State,
  repo: String,
  name: String,
) -> #(State, Result(String, String)) {
  let repo = case repo {
    "" ->
      shell_now(state, snapshot.list_repos())
      |> result.unwrap("")
      |> string.split("\n")
      |> list.map(string.trim)
      |> list.find(fn(line) { line != "" })
      |> result.unwrap("")
    repo -> repo
  }
  let is_repo =
    repo != ""
    && shell_now(state, snapshot.is_repo(repo)) |> result.map(string.trim)
    == Ok("yes")
  case state.repo, is_repo {
    Some(_), _ -> #(state, Error("the work is already in a code channel"))
    None, False -> #(
      state,
      Error(case repo {
        "" -> "there is no git repository in the workspace; clone one first"
        repo -> repo <> " is not a git repository"
      }),
    )
    None, True -> {
      let info =
        shell_now(state, snapshot.repo_info(repo))
        |> result.map(snapshot.parse_repo_info)
        |> result.unwrap(snapshot.RepoInfo("", "", ""))
      let repo_name = case snapshot.repo_name(info.url) {
        "" -> string.replace(repo, "./", "")
        name -> name
      }
      let name = case string.trim(name) {
        "" -> repo_name
        name -> name
      }
      let old = state.config.sink
      case old.open_code_channel(name, repo) {
        Error(reason) -> {
          warn("crushling: staying in the thread: " <> reason)
          // Don't try again for every later clone in this thread.
          #(State(..state, repo: Some(repo)), Error(reason))
        }
        Ok(#(channel_sink, channel)) -> {
          let _ =
            old.post(
              "_working on `" <> repo_name <> "` in <#" <> channel <> ">_",
            )
          let working = state.active != None
          old.working(False)
          channel_sink.working(working)
          let config = Config(..state.config, sink: channel_sink)
          let state = State(..state, config:, repo: Some(repo))
          // The plan card starts over in the channel.
          let active =
            option.map(state.active, fn(active) {
              case active.plan_ts, render.plan(active.run, config.root) {
                Some(ts), Some(plan) -> {
                  let _ =
                    old.update_plan(
                      ts,
                      render.Plan(..plan, title: "Moved to the code channel"),
                    )
                  Nil
                }
                _, _ -> Nil
              }
              Active(..active, plan_ts: None, shown: None, display: PlanCard)
            })
          let state = State(..state, active:)
          update_code_view(state, info)
          #(state, Ok(channel))
        }
      }
    }
  }
}

/// Refresh the code channel's context bar and Code tab from the repo.
fn update_code_view(state: State, info: snapshot.RepoInfo) -> Nil {
  case state.repo {
    None -> Nil
    Some(repo) -> {
      let sink = state.config.sink
      let changes =
        shell_now(state, snapshot.repo_numstat(repo))
        |> result.map(snapshot.parse_numstat)
        |> result.unwrap([])
      let web = snapshot.web_url(info.url)
      let link = fn(path) {
        case web {
          "" -> ""
          web -> web <> path
        }
      }
      let items =
        [
          case snapshot.repo_name(info.url) {
            "" -> Error(Nil)
            name -> Ok(ContextItem("repo", name, "folder", link("")))
          },
          case info.branch {
            "" | "HEAD" -> Error(Nil)
            branch ->
              Ok(ContextItem(
                "branch",
                branch,
                "branch",
                link("/tree/" <> branch),
              ))
          },
          case changes {
            [] -> Error(Nil)
            [_] -> Ok(ContextItem("changes", "1 file changed", "code", ""))
            many ->
              Ok(ContextItem(
                "changes",
                int.to_string(list.length(many)) <> " files changed",
                "code",
                "",
              ))
          },
        ]
        |> result.values
      sink.context(items)
      case shell_now(state, snapshot.repo_diff(repo)) {
        Ok("") | Error(Nil) -> Nil
        Ok(diff) -> sink.code(diff, info.base, info.branch)
      }
    }
  }
}

fn is_busy(state: State) -> Bool {
  state.active != None || state.waiting != [] || has_running_subs(state)
}

fn has_running_subs(state: State) -> Bool {
  dict.values(state.subs) |> list.any(fn(sub) { !sub.done })
}

fn session_id(state: State) -> String {
  option.unwrap(state.session_id, "")
}

/// Crush wakes the parent with a turn of its own when a subagent reports
/// and nothing is running. That turn carries no run id of ours, so adopt it
/// as an unsolicited run when its report message appears.
fn adopt_report_turn(state: State, event: event.Event) -> State {
  let parent = session_id(state)
  case state.active, event {
    None, event.MessageEvent(op: "created", message:)
      if message.session_id == parent && message.reports != []
    -> {
      state.config.sink.working(True)
      process.send_after(state.self, watchdog_ms, Watchdog)
      let now = now_ms()
      let active =
        Active(
          run: run.new(message.session_id, ""),
          plan_ts: None,
          shown: None,
          display: Unshown,
          base: None,
          working_since_ms: now,
          last_event_ms: now,
          stalled: False,
          cancel_note: None,
          solicited: False,
        )
      State(..state, active: Some(active))
    }
    _, _ -> state
  }
}

/// The label crush gave a dispatched subagent, from the tool's result:
/// `Started subagent "madeline-crush-server-api". …`
fn started_label(content: String) -> Result(String, Nil) {
  case string.split_once(content, "Started subagent \"") {
    Ok(#(_, rest)) ->
      case string.split_once(rest, "\"") {
        Ok(#(label, _)) -> Ok(label)
        Error(Nil) -> Error(Nil)
      }
    Error(Nil) -> Error(Nil)
  }
}

/// Follow subagents. Each runs in a child session, `<message id>$$<tool
/// call id>`, whether started with `agent` (the parent waits) or
/// `agent_dispatch` (it reports back later). Session events give it a
/// title, a dispatch result gives it a name, its own messages are its
/// progress, and its own run_complete finishes it.
fn track_subs(state: State, event: event.Event) -> State {
  let parent = session_id(state)
  case event {
    event.SessionEvent(id:, parent_session_id:, title:)
      if parent_session_id == parent && parent != ""
    ->
      case call_id(id) {
        Ok(call) ->
          upsert_sub(state, call, id, fn(sub) {
            case title {
              "" | "New Agent Session" -> sub
              title -> Sub(..sub, title:)
            }
          })
        Error(Nil) -> state
      }
    event.MessageEvent(message:, ..) if message.session_id == parent ->
      list.fold(message.tool_results, state, fn(state, result) {
        case result.name, started_label(result.content) {
          "agent_dispatch", Ok(label) ->
            case dict.get(state.subs, result.tool_call_id) {
              Ok(sub) ->
                State(
                  ..state,
                  subs: dict.insert(
                    state.subs,
                    result.tool_call_id,
                    Sub(..sub, label:),
                  ),
                )
              Error(Nil) -> state
            }
          _, _ -> state
        }
      })
    event.MessageEvent(message: event.Message(session_id: child, ..), ..)
    | event.FileEvent(event.FileVersion(session_id: child, ..)) ->
      case dict.get(state.subs, call_id(child) |> result.unwrap("")) {
        Ok(sub) -> {
          let sub = Sub(..sub, run: run.apply(sub.run, state.known, event))
          State(..state, subs: dict.insert(state.subs, sub.key, sub))
        }
        Error(Nil) -> state
      }
    event.RunCompleteEvent(done) ->
      case dict.get(state.subs, call_id(done.session_id) |> result.unwrap("")) {
        Ok(sub) if !sub.done -> {
          let sub = Sub(..sub, run: run.apply(sub.run, state.known, event))
          let sub = case run.is_done(sub.run) {
            True -> finish_sub(state.config, Sub(..sub, done: True))
            False -> sub
          }
          State(..state, subs: dict.insert(state.subs, sub.key, sub))
        }
        _ -> state
      }
    _ -> state
  }
}

fn call_id(session_id: String) -> Result(String, Nil) {
  case string.split_once(session_id, "$$") {
    Ok(#(_, call)) -> Ok(call)
    Error(Nil) -> Error(Nil)
  }
}

fn upsert_sub(
  state: State,
  call: String,
  session_id: String,
  update: fn(Sub) -> Sub,
) -> State {
  let sub = case dict.get(state.subs, call) {
    Ok(sub) -> sub
    Error(Nil) ->
      Sub(
        key: call,
        label: "",
        title: "",
        run: run.new(session_id, ""),
        sink: None,
        link: "",
        plan_ts: None,
        shown: None,
        posted: [],
        done: False,
      )
  }
  State(..state, subs: dict.insert(state.subs, call, update(sub)))
}

fn finish_sub(config: Config, sub: Sub) -> Sub {
  let sub = show_sub(config, sub)
  let streamed = run.messages(sub.run, True)
  let sub = post_sub_messages(sub, True)
  report_back(config, sub, streamed)
  sub
}

const names = [
  "Ada", "Grace", "Alan", "Edsger", "Barbara", "Margaret", "Linus", "Radia",
  "Ken", "Dennis", "Frances", "Donald", "Leslie", "Hedy", "Niklaus", "Katherine",
]

/// What to call a subagent: the first name crush gave a dispatched one
/// ("madeline-crush-server-api" is Madeline), otherwise one picked from its
/// call id so it stays the same. And what it is working on.
fn sub_name(sub: Sub) -> #(String, String) {
  let scope = case sub.title {
    "" -> "a task"
    title -> title
  }
  case string.split_once(sub.label, "-") {
    Ok(#(first, rest)) -> #(string.capitalise(first), case sub.title {
      "" -> rest
      title -> title
    })
    Error(Nil) -> {
      let hash =
        string.to_utf_codepoints(sub.key)
        |> list.fold(0, fn(acc, cp) {
          acc * 31 + string.utf_codepoint_to_int(cp)
        })
      let index = int.absolute_value(hash) % list.length(names)
      let name = list.drop(names, index) |> list.first |> result.unwrap("Ada")
      #(name, scope)
    }
  }
}

/// Open the subagent's thread if needed, keep its plan card current, and
/// once it is done post what it found.
fn show_sub(config: Config, sub: Sub) -> Sub {
  // A thread opens once there is a step to show; a subagent that answers
  // without any tools reports back without one.
  let sub = case sub.sink, render.plan(sub.run, config.root) {
    None, Some(_) -> {
      let #(name, scope) = sub_name(sub)
      case
        config.sink.branch(
          "*" <> name <> "* is working on _" <> scope <> "_",
          name <> ": " <> scope,
        )
      {
        Ok(#(branch, link)) -> {
          branch.working(True)
          Sub(..sub, sink: Some(branch), link:)
        }
        Error(reason) -> {
          warn("crushling: couldn't open a subagent thread: " <> reason)
          sub
        }
      }
    }
    _, _ -> sub
  }
  let sub = case sub.sink, render.plan(sub.run, config.root) {
    Some(branch), Some(plan) if Some(plan) != sub.shown ->
      case sub.plan_ts {
        Some(ts) ->
          case branch.update_plan(ts, plan) {
            Ok(Nil) -> Sub(..sub, shown: Some(plan))
            Error(_) -> sub
          }
        None ->
          case branch.post_plan(plan) {
            Ok(ts) -> Sub(..sub, plan_ts: Some(ts), shown: Some(plan))
            Error(_) -> sub
          }
      }
    _, _ -> sub
  }
  post_sub_messages(sub, sub.done)
}

/// Post what the subagent said between its tool calls in its thread, each
/// message once it is complete, so the thread reads as its working notes.
fn post_sub_messages(sub: Sub, done: Bool) -> Sub {
  case sub.sink {
    None -> sub
    Some(branch) -> {
      let fresh =
        run.messages(sub.run, done)
        |> list.filter(fn(message) { !list.contains(sub.posted, message.0) })
      list.fold(fresh, sub, fn(sub, message) {
        let #(id, text) = message
        list.each(render.chunk(text, render.message_limit), fn(chunk) {
          let _ = branch.post(chunk)
          Nil
        })
        Sub(..sub, posted: [id, ..sub.posted])
      })
    }
  }
}

/// Post the subagent's answer in its own thread, and a short note with a
/// link in the main one.
fn report_back(
  config: Config,
  sub: Sub,
  streamed: List(#(String, String)),
) -> Nil {
  let #(name, scope) = sub_name(sub)
  // Its messages are already in its thread; what is left to post there is
  // an error, or a final answer that never streamed.
  let #(failed, output, extra) = case sub.run.outcome, list.last(streamed) {
    Some(run.Errored(error)), _ -> #(True, error, error)
    Some(run.Cancelled), _ -> #(True, "stopped", "stopped")
    _, Ok(#(_, last)) -> #(False, last, "")
    _, Error(Nil) -> {
      let answer = render.answer(sub.run) |> string.join("\n\n")
      #(False, answer, answer)
    }
  }
  case sub.sink {
    Some(branch) -> {
      list.each(render.chunk(extra, render.message_limit), fn(chunk) {
        case string.trim(chunk) {
          "" -> Nil
          _ -> {
            let _ = branch.post(chunk)
            Nil
          }
        }
      })
      branch.working(False)
    }
    None -> Nil
  }
  let verb = case failed {
    True -> "ran into trouble with"
    False -> "finished"
  }
  let where = case sub.link {
    "" -> ""
    link -> " · <" <> link <> "|see its thread>"
  }
  let summary =
    string.split(string.trim(output), "\n")
    |> list.filter(fn(line) { string.trim(line) != "" })
    |> list.take(3)
    |> list.map(fn(line) { "> " <> line })
    |> string.join("\n")
  let _ =
    config.sink.post(
      "*"
      <> name
      <> "* "
      <> verb
      <> " _"
      <> scope
      <> "_"
      <> where
      <> "\n"
      <> summary,
    )
  Nil
}

/// Re-render the in-progress run if it changed since it was last shown.
fn flush(state: State) -> State {
  let subs =
    dict.map_values(state.subs, fn(_, sub) {
      case sub.done {
        True -> sub
        False -> show_sub(state.config, sub)
      }
    })
  let state = State(..state, subs:)
  let state = case state.active {
    Some(active) ->
      State(..state, active: Some(show_progress(state.config, active)))
    None -> state
  }
  // Keep flushing while subagents work after the main run has ended.
  case state.active == None && has_running_subs(state) {
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
      let now = now_ms()
      case !active.stalled && now - active.last_event_ms > stall_ms {
        False ->
          case !active.stalled && now - active.working_since_ms > rework_ms {
            True -> {
              state.config.sink.working(True)
              State(
                ..state,
                active: Some(Active(..active, working_since_ms: now)),
              )
            }
            False -> state
          }
        True -> {
          let _ =
            state.config.sink.post(
              "_no word from the agent in 10 minutes; it may be stuck. Reply `!stop` to stop it._",
            )
          state.config.sink.working(False)
          State(..state, active: Some(Active(..active, stalled: True)))
        }
      }
    }
  }
}

/// Show the run moving: one streamed message with the agent's text as it
/// arrives and its steps in a plan block, or the plan card where Slack
/// won't stream.
/// Where a run is being shown: nowhere yet, one streamed message, or the
/// plan card where Slack won't stream.
type Display {
  Unshown
  Streaming(ts: String, shown: render.Shown)
  PlanCard
}

fn show_progress(config: Config, active: Active) -> Active {
  case active.display {
    PlanCard -> show_plan(config, active)
    _ -> show_stream(config, active)
  }
}

fn show_stream(config: Config, active: Active) -> Active {
  let sink = config.sink
  case active.display {
    Streaming(ts, shown) -> {
      let pending = render.pending(active.run, config.root, shown)
      case pending.chunks {
        [] -> active
        chunks ->
          case sink.append_stream(ts, chunks) {
            Ok(Nil) -> Active(..active, display: Streaming(ts, pending.shown))
            Error(reason) -> {
              warn("crushling: stream update failed: " <> reason)
              active
            }
          }
      }
    }
    _ -> {
      let pending =
        render.pending(active.run, config.root, render.empty_shown())
      case pending.chunks {
        [] -> active
        chunks ->
          case sink.start_stream(chunks) {
            Ok(ts) -> Active(..active, display: Streaming(ts, pending.shown))
            Error(reason) -> {
              warn("crushling: streaming not available: " <> reason)
              show_plan(config, Active(..active, display: PlanCard))
            }
          }
      }
    }
  }
}

fn show_plan(config: Config, active: Active) -> Active {
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
            Ok(ts) -> Active(..active, plan_ts: Some(ts), shown: Some(plan))
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
  case state.repo {
    // In a code channel the repository's own history is the reference:
    // the Code tab holds the diff, so nothing is attached.
    Some(repo) -> {
      let numstat =
        shell_now(state, snapshot.repo_numstat(repo))
        |> result.map(snapshot.parse_numstat)
        |> result.unwrap([])
      #(numstat, "")
    }
    None -> workspace_changes(state, active)
  }
}

fn workspace_changes(
  state: State,
  active: Active,
) -> #(List(snapshot.Change), String) {
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
  case state.repo {
    Some(repo) ->
      update_code_view(
        state,
        shell_now(state, snapshot.repo_info(repo))
          |> result.map(snapshot.parse_repo_info)
          |> result.unwrap(snapshot.RepoInfo("", "", "")),
      )
    None -> Nil
  }

  let answer = render.answer(active.run)
  let answered = answer != []
  let closing =
    [
      // A code channel's Code tab already lists what changed.
      case config.in_code_channel {
        True -> None
        False -> render.changes(changes)
      },
      case active.run.outcome, active.cancel_note {
        Some(run.Cancelled), Some(note) -> Some("_" <> note <> "_")
        _, _ -> render.note(active.run, answered)
      },
    ]
    |> option.values
  // A run ends in one message: the streamed one settles with what the agent
  // said, its steps and the line naming the files it changed. Without a
  // stream, the plan card settles and the answer is posted after it.
  let reply_ts = case active.display {
    Streaming(ts, shown) -> settle_stream(config, active, ts, shown, closing)
    _ -> settle_card(config, active, answer, closing)
  }
  sink.working(False)

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
    solicited: active.solicited,
    run_id: active.run.run_id,
    outcome: option.unwrap(active.run.outcome, run.Cancelled),
    text: string.join(answer, "\n\n"),
    reply_ts:,
    changes:,
    patch:,
  ))
}

/// Finish the streamed message: its last pieces, then whatever didn't fit.
fn settle_stream(
  config: Config,
  active: Active,
  ts: String,
  shown: render.Shown,
  closing: List(String),
) -> String {
  let sink = config.sink
  let pending = render.pending(active.run, config.root, shown)
  let tail = case string.join(closing, "\n\n") {
    "" -> []
    text -> [render.ChunkText("\n\n" <> text)]
  }
  case sink.stop_stream(ts, list.append(pending.chunks, tail)) {
    Ok(Nil) -> {
      let rest = render.remainder(render.reply(active.run), pending.shown.text)
      last_ts(post_texts(sink, render.chunk(rest, render.message_limit)), ts)
    }
    // Nothing could settle the stream; say it again in the thread rather
    // than leave it half written.
    Error(reason) -> {
      warn("crushling: finishing the stream failed: " <> reason)
      settle_card(config, active, render.answer(active.run), closing)
    }
  }
}

/// Post the answer and settle the plan card.
fn settle_card(
  config: Config,
  active: Active,
  answer: List(String),
  closing: List(String),
) -> String {
  let sink = config.sink
  case active.plan_ts, render.plan(active.run, config.root) {
    Some(ts), Some(plan) ->
      case sink.update_plan(ts, plan) {
        Ok(Nil) -> Nil
        Error(reason) -> warn("crushling: plan update failed: " <> reason)
      }
    _, _ -> Nil
  }
  // The file summary and any note ride on the last answer message when
  // there is one, so a run ends in a single message.
  let messages = case list.reverse(answer), closing {
    [], [] -> []
    [], closing -> [string.join(closing, "\n")]
    [last, ..earlier], [] -> list.reverse([last, ..earlier])
    [last, ..earlier], closing ->
      list.reverse([last <> "\n\n" <> string.join(closing, "\n"), ..earlier])
  }
  last_ts(post_texts(sink, messages), "")
}

/// The part of `reply` a stream hasn't shown yet.
/// Post each piece, keeping the ids of the ones that went out.
fn post_texts(sink: Sink, texts: List(String)) -> List(String) {
  list.fold(texts, [], fn(posted, text) {
    case text {
      "" -> posted
      text ->
        case sink.post(text) {
          Ok(ts) -> list.append(posted, [ts])
          Error(reason) -> {
            warn("crushling: post failed: " <> reason)
            posted
          }
        }
    }
  })
}

fn last_ts(posted: List(String), fallback: String) -> String {
  list.last(posted) |> result.unwrap(fallback)
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
