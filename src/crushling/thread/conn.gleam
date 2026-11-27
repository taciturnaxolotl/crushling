//// A thread's connection to its `crush server`: a workspace, its event
//// stream and a session. HTTP/1.1 can't send requests on a connection
//// that is streaming a response, so there are two connections: one for
//// the event stream and one for requests.

import crushling/crush/client
import crushling/gun
import crushling/sys
import crushling/thread/resume.{type Resume}
import gleam/erlang/process.{type Pid}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Connection {
  Connection(
    requests: gun.Conn,
    events: gun.Conn,
    stream: gun.StreamRef,
    workspace_id: String,
    session_id: String,
    /// Whether the event stream was opened with a `Last-Event-ID`. The
    /// server then replays what was missed, or starts with a resync event.
    resumed: Bool,
    /// Whether the workspace joined before was still on the server: the
    /// same server, with everything it held in memory.
    reused: Bool,
  )
}

/// The server to connect to, and how the thread shows itself to it.
pub type Target {
  Target(
    socket: String,
    /// The workspace path as the server sees it.
    root: String,
    /// The title for a new session.
    title: String,
    mode: client.PermissionMode,
    client_id: String,
    /// A session id that never exists, for shell commands whose output
    /// should not be saved into the agent's history.
    scratch: String,
  )
}

const ready_poll_ms = 200

const ready_attempts = 150

const attach_timeout_ms = 15_000

/// `open` in a process of its own, so a slow server never holds up the thread
/// actor `owner`; `deliver` gets the result there. The process then stays to
/// pass the event stream's messages on to `owner`, as gun sends them to the
/// process that opened the stream.
pub fn open_apart(
  target: Target,
  from: Resume,
  owner: Pid,
  deliver: fn(Result(Connection, String)) -> Nil,
) -> Nil {
  process.spawn_unlinked(fn() {
    let opened = open(target, from)
    deliver(opened)
    case opened {
      Ok(connection) -> relay(owner, [connection.requests, connection.events])
      Error(_) -> Nil
    }
  })
  Nil
}

@external(erlang, "crushling_relay_ffi", "relay")
fn relay(owner: Pid, conns: List(gun.Conn)) -> Nil

/// Connect to the server, join the workspace and open the event stream. Then
/// use the session `from` names if any, else the latest session, else a
/// new one.
///
/// A workspace the server still has is reused as it is: the agent is
/// already set up and the session is kept. Otherwise the workspace is
/// created (or joined, as workspaces are deduplicated by path) and its agent
/// initialised. Either way the event stream resumes after the last event
/// handled, and a workspace the server re-created answers that with a resync.
///
/// Returns only once the event stream is attached (its response was 200), so
/// the connection is ready for prompts. Checking that a workspace exists does
/// not hold it, so it can be gone by the time the stream attaches; the stream
/// then answers 404, and the workspace is set up again in the same attempt.
pub fn open(target: Target, from: Resume) -> Result(Connection, String) {
  let session_id = from.session_id
  let last_event_id = resume.last(from.cursor)
  use requests <- result.try(gun.connect_unix(target.socket, 5000))
  use events <- result.try(
    gun.connect_unix(target.socket, 5000)
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
  let attached = {
    use #(workspace_id, reused) <- result.try(join(
      requests,
      target,
      from.workspace_id,
    ))
    case attach(events, target, workspace_id, last_event_id), reused {
      Ok(stream), _ -> Ok(#(workspace_id, reused, stream))
      Error(client.Status(404, _)), True -> {
        use #(workspace_id, reused) <- result.try(join(requests, target, None))
        use stream <- result.try(attach(
          events,
          target,
          workspace_id,
          last_event_id,
        ))
        Ok(#(workspace_id, reused, stream))
      }
      Error(error), _ -> Error(error)
    }
  }
  use #(workspace_id, reused, stream) <- result.try(
    attached |> result.map_error(fail),
  )
  let connection =
    Connection(
      requests:,
      events:,
      stream:,
      workspace_id:,
      session_id: "",
      resumed: option.is_some(last_event_id),
      reused:,
    )
  let session = case reused, session_id {
    True, Some(id) -> Ok(id)
    _, _ -> {
      use _ <- result.try(call(
        connection,
        client.init_agent(workspace_id, True),
      ))
      use _ <- result.try(wait_ready(connection, ready_attempts))
      case session_id {
        Some(id) -> Ok(id)
        None ->
          case call(connection, client.latest_session(workspace_id)) {
            Ok(Some(id)) -> Ok(id)
            _ ->
              call(
                connection,
                client.create_session(workspace_id, target.title),
              )
          }
      }
    }
  }
  case session {
    Ok(session_id) -> Ok(Connection(..connection, session_id:))
    Error(error) -> Error(fail(error))
  }
}

/// Open the event stream and wait for its response. Anything but 200 is a
/// `Status` error.
fn attach(
  events: gun.Conn,
  target: Target,
  workspace_id: String,
  last_event_id: Option(String),
) -> Result(gun.StreamRef, client.Error) {
  let stream =
    gun.resume_stream(
      events,
      client.events_path(workspace_id, target.client_id),
      [#("host", "api.crush.localhost")],
      last_event_id,
    )
  case gun.await_stream(events, stream, attach_timeout_ms) {
    Ok(200) -> Ok(stream)
    Ok(status) -> Error(client.Status(status, "event stream refused"))
    Error(reason) -> Error(client.Transport(reason))
  }
}

/// The workspace to use, and whether it is `known`, still on the server.
fn join(
  requests: gun.Conn,
  target: Target,
  known: Option(String),
) -> Result(#(String, Bool), client.Error) {
  let create = fn() {
    client.perform(
      requests,
      client.create_workspace(target.root, target.client_id, target.mode, []),
    )
    |> result.map(fn(id) { #(id, False) })
  }
  case known {
    None -> create()
    Some(id) ->
      case client.perform(requests, client.get_workspace(id)) {
        Ok(Nil) -> Ok(#(id, True))
        Error(client.Transport(reason)) -> Error(client.Transport(reason))
        // Gone (404) or unreadable: create it again.
        Error(_) -> create()
      }
  }
}

fn wait_ready(
  connection: Connection,
  attempts: Int,
) -> Result(Nil, client.Error) {
  case call(connection, client.agent_ready(connection.workspace_id)) {
    Ok(True) -> Ok(Nil)
    Ok(False) if attempts > 0 -> {
      process.sleep(ready_poll_ms)
      wait_ready(connection, attempts - 1)
    }
    Ok(False) -> Error(client.BadResponse("agent never became ready"))
    Error(error) -> Error(error)
  }
}

pub fn call(
  connection: Connection,
  call: client.Call(a),
) -> Result(a, client.Error) {
  client.perform(connection.requests, call)
}

/// How many background jobs the agent has running; unknown counts as none,
/// as the agent is idle as far as anyone can tell.
pub fn running_jobs(connection: Connection) -> Int {
  call(
    connection,
    client.running_jobs(connection.workspace_id, connection.session_id),
  )
  |> result.unwrap(0)
}

/// Send a prompt to the session, to run as `run_id`.
pub fn prompt(
  connection: Connection,
  run_id: String,
  text: String,
  attachments: List(client.Attachment),
) -> Result(Nil, client.Error) {
  call(
    connection,
    client.send_prompt_with(
      workspace_id: connection.workspace_id,
      session_id: connection.session_id,
      run_id:,
      prompt: text,
      attachments:,
    ),
  )
}

/// Ask crush to cancel the session's run.
pub fn cancel(connection: Connection) -> Nil {
  let _ =
    call(
      connection,
      client.cancel(connection.workspace_id, connection.session_id),
    )
  Nil
}

/// Whether the session is still running something; an error if crush can't
/// say.
pub fn busy(connection: Connection) -> Result(Bool, client.Error) {
  call(
    connection,
    client.session_busy(connection.workspace_id, connection.session_id),
  )
}

pub fn describe(error: client.Error) -> String {
  case error {
    client.Transport(reason) -> "transport: " <> reason
    client.Status(status, message) ->
      "status " <> string.inspect(status) <> ": " <> message
    client.BadResponse(body) -> "bad response: " <> body
  }
}

/// Run a shell command in the workspace without adding it to the agent's
/// history. Returns the output if the command succeeds.
pub fn shell(
  connection: Connection,
  target: Target,
  command: String,
) -> Result(String, Nil) {
  run_shell(connection.requests, connection.workspace_id, target, command)
}

/// Run `job` in a process of its own, with a shell like `shell` on a
/// connection of its own: slow commands then hold up neither the actor nor
/// the requests it makes meanwhile.
pub fn apart(
  connection: Connection,
  target: Target,
  job: fn(fn(String) -> Result(String, Nil)) -> Nil,
) -> Nil {
  let workspace_id = connection.workspace_id
  process.spawn_unlinked(fn() {
    case gun.connect_unix(target.socket, 5000) {
      Ok(requests) -> {
        job(run_shell(requests, workspace_id, target, _))
        gun.close(requests)
      }
      Error(reason) -> {
        sys.warn("crushling: no connection for shell work: " <> reason)
        job(fn(_) { Error(Nil) })
      }
    }
  })
  Nil
}

fn run_shell(
  requests: gun.Conn,
  workspace_id: String,
  target: Target,
  command: String,
) -> Result(String, Nil) {
  let ran =
    client.perform(
      requests,
      client.shell(workspace_id:, scratch_session: target.scratch, command:),
    )
  case ran {
    Ok(#(0, output)) -> Ok(output)
    Ok(#(status, output)) -> {
      sys.warn(
        "crushling: shell exited "
        <> string.inspect(status)
        <> ": "
        <> string.slice(output, 0, 500),
      )
      Error(Nil)
    }
    Error(error) -> {
      sys.warn("crushling: shell failed: " <> describe(error))
      Error(Nil)
    }
  }
}

pub fn close(connection: Connection) -> Nil {
  gun.close(connection.events)
  gun.close(connection.requests)
}

/// Leave the workspace, then close both connections.
pub fn retire(connection: Connection, target: Target) -> Nil {
  let _ = call(connection, client.retire_client(target.client_id))
  close(connection)
}

/// How long to wait before the next connection attempt.
pub fn backoff(retries: Int) -> Int {
  case retries {
    0 -> 100
    1 -> 250
    2 -> 500
    3 -> 1000
    _ -> 2000
  }
}
