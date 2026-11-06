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
  let assert gun.StreamError(reason: "timeout", ..) = next()
  let assert gun.ConnDown(reason: "closed", ..) = next()
  let assert Error(Nil) = process.selector_receive(selector, 10)
}

pub fn connect_to_missing_socket_errors_test() {
  let assert Error(_) = gun.connect_unix("/tmp/definitely-not-a-socket", 500)
}
