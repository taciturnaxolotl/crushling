//// The bridge's HTTP server for sandboxes: the one port a sandbox may reach.
////
//// Each feature contributes a route (the Slack tools, the tunnel, the
//// inference proxy); the first route that claims a request answers it.

import crushling/sys
import gleam/bytes_tree
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option}
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import mist

/// Answers a request it owns, or None to let the next route look.
pub type Route =
  fn(Request(mist.Connection)) -> Option(Response(mist.ResponseData))

/// Serve `routes` on `bind`:`port`.
pub fn start(
  bind: String,
  port: Int,
  routes: List(Route),
) -> Result(Nil, String) {
  mist.new(handler(routes))
  |> mist.bind(bind)
  |> mist.port(port)
  |> mist.after_start(fn(_, _, _) { Nil })
  |> mist.start
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(error) {
    sys.warn("crushling: sandbox server: " <> string.inspect(error))
    "could not serve sandboxes on "
    <> bind
    <> ":"
    <> string.inspect(port)
    <> ": "
    <> string.inspect(error)
  })
}

/// `start` as a supervised child; a failure to listen is the
/// supervisor's to report.
pub fn supervised(
  bind: String,
  port: Int,
  routes: List(Route),
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  mist.new(handler(routes))
  |> mist.bind(bind)
  |> mist.port(port)
  |> mist.after_start(fn(_, _, _) { Nil })
  |> mist.supervised
}

fn handler(
  routes: List(Route),
) -> fn(Request(mist.Connection)) -> Response(mist.ResponseData) {
  fn(req: Request(mist.Connection)) {
    list.find_map(routes, fn(route) { option.to_result(route(req), Nil) })
    |> result.unwrap(reply(404, ""))
  }
}

/// A response with a plain body.
pub fn reply(status: Int, body: String) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}
