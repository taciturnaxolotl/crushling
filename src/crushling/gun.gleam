//// HTTP over a unix socket, plus a streaming server-sent events client, on
//// top of `gun`. Built for talking to `crush server` from a thread actor.
////
//// Requests are blocking and run in the calling process. Streams deliver
//// their events as messages to the process that opened them, so the actor
//// that owns a connection adds `select` to its selector.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Selector}
import gleam/http.{type Method}
import gleam/option.{type Option}

pub type Conn

pub type StreamRef

pub type Response {
  Response(status: Int, headers: List(#(String, String)), body: BitArray)
}

pub type SseEvent {
  SseEvent(event: String, id: Option(String), data: String)
}

/// Every message gun can send to the owning process, decoded. `conn` is
/// included so one actor can own several connections.
pub type Message {
  Event(conn: Conn, stream: StreamRef, event: SseEvent)
  /// Response headers for a stream. A non-2xx status means the body will
  /// arrive as `Data`, not as events.
  StreamResponse(
    conn: Conn,
    stream: StreamRef,
    status: Int,
    headers: List(#(String, String)),
    fin: Bool,
  )
  Data(conn: Conn, stream: StreamRef, data: BitArray, fin: Bool)
  StreamEnd(conn: Conn, stream: StreamRef)
  StreamError(conn: Conn, stream: StreamRef, reason: String)
  ConnDown(conn: Conn, reason: String)
  Ignored
}

@external(erlang, "crushling_gun_ffi", "connect_unix")
pub fn connect_unix(path: String, timeout_ms: Int) -> Result(Conn, String)

/// Connect over TCP, with TLS verified against the system trust store when
/// `tls` is set.
@external(erlang, "crushling_gun_ffi", "connect_tcp")
pub fn connect_tcp(
  host: String,
  port: Int,
  tls: Bool,
  timeout_ms: Int,
) -> Result(Conn, String)

pub fn request(
  conn: Conn,
  method: Method,
  path: String,
  headers: List(#(String, String)),
  body: BitArray,
  timeout_ms: Int,
) -> Result(Response, String) {
  case
    do_request(
      conn,
      http.method_to_string(method),
      path,
      headers,
      body,
      timeout_ms,
    )
  {
    Ok(#(status, headers, body)) -> Ok(Response(status:, headers:, body:))
    Error(reason) -> Error(reason)
  }
}

@external(erlang, "crushling_gun_ffi", "request")
fn do_request(
  conn: Conn,
  method: String,
  path: String,
  headers: List(#(String, String)),
  body: BitArray,
  timeout_ms: Int,
) -> Result(#(Int, List(#(String, String)), BitArray), String)

/// Open a GET stream. The calling process receives its messages.
@external(erlang, "crushling_gun_ffi", "stream")
pub fn stream(
  conn: Conn,
  path: String,
  headers: List(#(String, String)),
) -> StreamRef

@external(erlang, "crushling_gun_ffi", "cancel")
pub fn cancel(conn: Conn, stream: StreamRef) -> Nil

@external(erlang, "crushling_gun_ffi", "close")
pub fn close(conn: Conn) -> Nil

/// Add handlers for every gun message to a selector.
pub fn select(selector: Selector(a), mapping: fn(Message) -> a) -> Selector(a) {
  let handle = fn(message) { mapping(decode_message(message)) }
  selector
  |> process.select_record(atom.create("gun_sse"), 3, handle)
  |> process.select_record(atom.create("gun_response"), 5, handle)
  |> process.select_record(atom.create("gun_data"), 4, handle)
  |> process.select_record(atom.create("gun_error"), 3, handle)
  |> process.select_record(atom.create("gun_error"), 2, handle)
  |> process.select_record(atom.create("gun_down"), 4, handle)
}

@external(erlang, "crushling_gun_ffi", "decode_message")
fn decode_message(message: Dynamic) -> Message
