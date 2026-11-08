//// A thread's connection to its `crush server`: a workspace, its event
//// stream and a session. HTTP/1.1 can't send requests on a connection
//// that is streaming a response, so there are two connections: one for
//// the event stream and one for requests.

import crushling/crush/client
import crushling/gun
import crushling/sys
import gleam/erlang/process
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

/// Connect to the server, join the workspace and open the event stream. Then
/// use `session_id` if given, else the latest session, else a new one.
pub fn open(
  target: Target,
  session_id: Option(String),
) -> Result(Connection, String) {
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
  use workspace_id <- result.try(
    client.perform(
      requests,
      client.create_workspace(target.root, target.client_id, target.mode, []),
    )
    |> result.map_error(fail),
  )
  let stream =
    gun.stream(events, client.events_path(workspace_id, target.client_id), [])
  let connection =
    Connection(requests:, events:, stream:, workspace_id:, session_id: "")
  let session = {
    use _ <- result.try(call(connection, client.init_agent(workspace_id, True)))
    use _ <- result.try(wait_ready(connection, ready_attempts))
    case session_id {
      Some(id) -> Ok(id)
      None ->
        case call(connection, client.latest_session(workspace_id)) {
          Ok(Some(id)) -> Ok(id)
          _ ->
            call(connection, client.create_session(workspace_id, target.title))
        }
    }
  }
  case session {
    Ok(session_id) -> Ok(Connection(..connection, session_id:))
    Error(error) -> Error(fail(error))
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
  let ran =
    call(
      connection,
      client.shell(
        workspace_id: connection.workspace_id,
        scratch_session: target.scratch,
        command:,
      ),
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
