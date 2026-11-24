//// Socket Mode stays connected: a connection Slack drops without a close
//// frame is replaced, rather than taking the reconnect loop down with it.

import crushling/socket
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/option.{None}
import mist
import slackline
import slackline/app

/// A Slack whose connections.open hands out a WebSocket on this server.
/// Each connection says so on `connected`, with its handler's pid, and is
/// dropped when that pid is killed.
fn fake_slack(connected: Subject(process.Pid)) -> Int {
  let port = process.new_subject()
  let assert Ok(_) =
    mist.new(fn(req: Request(mist.Connection)) {
      case req.path {
        "/api/apps.connections.open" -> {
          // This server, as the client reached it.
          let assert Ok(host) = request.get_header(req, "host")
          response.new(200)
          |> response.set_header("content-type", "application/json")
          |> response.set_body(
            mist.Bytes(bytes_tree.from_string(
              "{\"ok\":true,\"url\":\"ws://" <> host <> "/ws\"}",
            )),
          )
        }
        "/ws" ->
          mist.websocket(
            request: req,
            on_init: fn(_) {
              process.send(connected, process.self())
              #(Nil, None)
            },
            on_close: fn(_) { Nil },
            handler: fn(state, _, _) { mist.continue(state) },
          )
        _ ->
          response.new(404) |> response.set_body(mist.Bytes(bytes_tree.new()))
      }
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(p, _, _) { process.send(port, p) })
    |> mist.start
  let assert Ok(p) = process.receive(port, 5000)
  p
}

pub fn a_dropped_connection_is_replaced_test() {
  let connected = process.new_subject()
  let port = fake_slack(connected)
  let assert Ok(client) =
    slackline.new("xapp-test")
    |> slackline.with_base_url(
      "http://127.0.0.1:" <> int.to_string(port) <> "/api",
    )
  let loop =
    process.spawn_unlinked(fn() { socket.run_with(client, app.unverified()) })
  let assert Ok(first) = process.receive(connected, 5000)
  // Slack goes away without a close frame.
  process.kill(first)
  let assert Ok(second) = process.receive(connected, 5000)
  // And again: the loop keeps going.
  process.kill(second)
  let assert Ok(_) = process.receive(connected, 5000)
  process.kill(loop)
}
