import crushling/gun
import gleam/erlang/process
import gleam/option.{None, Some}

@external(erlang, "fake_gun_ffi", "send_all")
fn send_all() -> Nil

pub fn decodes_every_message_test() {
  send_all()
  let selector = process.new_selector() |> gun.select(fn(m) { m })
  let next = fn() {
    let assert Ok(m) = process.selector_receive(selector, 100)
    m
  }
  let assert gun.StreamResponse(status: 200, fin: False, ..) = next()
  let assert gun.Event(event: gun.SseEvent("message", None, "{\"a\":1}"), ..) =
    next()
  let assert gun.Event(event: gun.SseEvent("done", Some("7"), "x"), ..) = next()
  let assert gun.StreamEnd(..) = next()
  let assert gun.Trailers(headers: [#("x-a", "1")], ..) = next()
  let assert gun.StreamError(reason: "timeout", ..) = next()
  let assert gun.ConnDown(reason: "closed", ..) = next()
  let assert Error(Nil) = process.selector_receive(selector, 10)
}

@external(erlang, "fake_gun_ffi", "sse")
fn sse(chunks: List(String)) -> Nil

/// Only a frame with its own `id:` line has an id; gun's own handler would
/// repeat the last one on frames without.
pub fn sse_ids_are_per_frame_test() {
  sse([
    "\u{FEFF}id: e-1\ndata: a\n\n",
    "data: b\n",
    "data: c\r\n\r",
    "\nid: e-1\r",
    "data: d\r\r",
    ": comment\nevent: done\ndata\n\nid: e-2\n\n",
  ])
  let selector = process.new_selector() |> gun.select(fn(m) { m })
  let next = fn() {
    let assert Ok(gun.Event(event:, ..)) =
      process.selector_receive(selector, 100)
    event
  }
  let assert gun.SseEvent("message", Some("e-1"), "a") = next()
  let assert gun.SseEvent("message", None, "b\nc") = next()
  let assert gun.SseEvent("message", Some("e-1"), "d") = next()
  let assert gun.SseEvent("done", None, "") = next()
  let assert gun.SseEvent("message", Some("e-2"), "") = next()
  let assert Error(Nil) = process.selector_receive(selector, 10)
}

@external(erlang, "fake_gun_ffi", "sse_fin")
fn sse_fin(chunks: List(String)) -> Nil

/// A CR ends a line at once, so a final chunk ending in CRs dispatches its
/// event before the stream ends. A CRLF split across chunks is one ending.
pub fn sse_cr_ends_lines_at_once_test() {
  sse_fin(["data: a\r", "\n\r\n", "data: one\r\r"])
  let selector = process.new_selector() |> gun.select(fn(m) { m })
  let next = fn() {
    let assert Ok(m) = process.selector_receive(selector, 100)
    m
  }
  let assert gun.Event(event: gun.SseEvent("message", None, "a"), ..) = next()
  let assert gun.Event(event: gun.SseEvent("message", None, "one"), ..) = next()
  let assert gun.StreamEnd(..) = next()
  let assert Error(Nil) = process.selector_receive(selector, 10)
}

pub fn connect_to_missing_socket_errors_test() {
  let assert Error(_) = gun.connect_unix("/tmp/definitely-not-a-socket", 500)
}
