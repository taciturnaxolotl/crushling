//// Slack's HTTP delivery: the Events API and interactivity, both posted to
//// one URL. The router answers at once and does its work after, as Slack
//// wants an answer within three seconds. The same server serves the OAuth
//// install (`crushling/install`) when it is configured.

import crushling/install
import crushling/sys
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mist
import slackline/app

const max_body = 1_000_000

/// Serve `router` at `/slack/events` on `bind`:`port`, if events come over
/// HTTP, and the install at `/slack/install` and `/slack/oauth/callback`,
/// if it is configured.
pub fn start(
  bind: String,
  port: Int,
  router: Option(app.App),
  install: Option(install.Config),
) -> Result(Nil, String) {
  let handler = fn(req: Request(mist.Connection)) -> Response(mist.ResponseData) {
    case option.then(install, install.route(_, req)) {
      Some(response) -> response
      None -> serve(req, router)
    }
  }
  mist.new(handler)
  |> mist.bind(bind)
  |> mist.port(port)
  |> mist.after_start(fn(_, _, _) { Nil })
  |> mist.start
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(error) {
    sys.warn("crushling: events server: " <> string.inspect(error))
    "could not take Slack's events on "
    <> bind
    <> ":"
    <> string.inspect(port)
    <> ": "
    <> string.inspect(error)
  })
}

fn serve(
  req: Request(mist.Connection),
  router: Option(app.App),
) -> Response(mist.ResponseData) {
  case request.path_segments(req), req.method, router {
    ["slack", "events"], http.Post, Some(router) ->
      case mist.read_body(req, max_body) {
        Error(_) -> reply(413, "")
        Ok(req) ->
          case bit_array.to_string(req.body) {
            Error(Nil) -> reply(400, "")
            Ok(body) -> {
              let app.Handled(response:, after:) =
                app.handle(router, request.set_body(req, body))
              process.spawn_unlinked(after)
              response
              |> response.map(fn(body) {
                mist.Bytes(bytes_tree.from_string(body))
              })
            }
          }
      }
    ["health"], http.Get, _ -> reply(200, "ok")
    _, _, _ -> reply(404, "")
  }
}

fn reply(status: Int, body: String) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}
