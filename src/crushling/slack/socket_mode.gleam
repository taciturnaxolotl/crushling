//// Socket Mode: one WebSocket to Slack, reopened whenever Slack asks or the
//// connection drops, with every frame handed to the router's app.

import crushling/sys
import gleam/erlang/process
import gleam/http/request
import gleam/string
import slackline
import slackline/api/apps
import slackline/app
import slackline/httpc
import stratus

/// Connect and stay connected. Never returns: if the loop itself ever
/// dies, it is started again.
pub fn run(app_token: String, router: app.App) -> Nil {
  run_with(slackline.new(app_token), router)
}

/// `run`, with a client for the app token.
pub fn run_with(client: slackline.Client, router: app.App) -> Nil {
  let loop = process.spawn_unlinked(fn() { reconnect(client, router) })
  let monitor = process.monitor(loop)
  let _ =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive_forever
  sys.warn("crushling: the Socket Mode loop stopped; starting it again")
  process.sleep(1000)
  run_with(client, router)
}

fn reconnect(client: slackline.Client, router: app.App) -> Nil {
  case apps.connections_open() |> httpc.send(client) {
    Error(error) -> {
      sys.warn(
        "crushling: connections.open: " <> slackline.describe_error(error),
      )
      process.sleep(5000)
    }
    Ok(opened) -> {
      let why = session(opened.url, router)
      sys.info(
        "crushling: Socket Mode connection ended (" <> why <> "); reconnecting",
      )
      process.sleep(1000)
    }
  }
  reconnect(client, router)
}

/// One WebSocket session; returns why it ended. It runs in a process of its
/// own: stratus links the connection to whoever starts it and stops
/// abnormally when the socket drops, which would take the caller with it.
fn session(url: String, router: app.App) -> String {
  let ended = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() { process.send(ended, connect(url, router)) })
  let monitor = process.monitor(pid)
  let why =
    process.new_selector()
    |> process.select(ended)
    |> process.select_specific_monitor(monitor, fn(_) {
      "the connection dropped"
    })
    |> process.selector_receive_forever
  process.demonitor_process(monitor)
  process.kill(pid)
  why
}

/// Connect, and return once the connection ends. A drop kills this
/// process, which `session` sees.
fn connect(url: String, router: app.App) -> String {
  let url = case url {
    "wss://" <> rest -> "https://" <> rest
    "ws://" <> rest -> "http://" <> rest
    url -> url
  }
  let done = process.new_subject()
  case request.to(url) {
    Error(Nil) -> "a bad Socket Mode url"
    Ok(req) -> {
      let started =
        stratus.new(request: req, state: Nil)
        |> stratus.on_message(fn(state, message, connection) {
          case message {
            stratus.Text(frame) ->
              case app.handle_socket(router, frame) {
                app.Send(frame: reply, after:) -> {
                  let _ = stratus.send_text_message(connection, reply)
                  process.spawn_unlinked(after)
                  stratus.continue(state)
                }
                app.Reconnect(_) -> {
                  process.send(done, "Slack asked for a new one")
                  stratus.stop()
                }
                app.Ignore -> stratus.continue(state)
              }
            _ -> stratus.continue(state)
          }
        })
        |> stratus.on_close(fn(_, _) { process.send(done, "closed") })
        |> stratus.start
      case started {
        Error(error) -> "couldn't connect: " <> string.inspect(error)
        Ok(started) -> {
          let monitor = process.monitor(started.pid)
          let why =
            process.new_selector()
            |> process.select(done)
            |> process.select_specific_monitor(monitor, fn(_) { "it stopped" })
            |> process.selector_receive_forever
          process.demonitor_process(monitor)
          why
        }
      }
    }
  }
}
