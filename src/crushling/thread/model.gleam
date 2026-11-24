//// The thread actor's side of `!model`: reading the session's model and
//// the catalog from its `crush server`, pinning a choice, and keeping the
//// card in Slack true to what the session runs.
////
//// crush keeps a session's pinned model in memory only, so the thread pins
//// its saved choice again whenever it reaches a server that may be new
//// (`restore`).
////
//// Each step is a call or two to crush on the thread's request connection.
//// The catalog doesn't change while a server runs, so it is fetched once per
//// server and handed back in `Done` for the thread to keep.

import crushling/crush/client
import crushling/meta.{type ModelChoice, DefaultReasoning, ModelChoice}
import crushling/models.{type Current, type Model}
import crushling/sink.{type Sink}
import crushling/sys
import crushling/thread/conn.{type Connection}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result

pub type Context {
  Context(
    connection: Connection,
    sink: Sink,
    /// The thread's channel and ts, which cards carry.
    home: #(String, String),
    catalog: Option(List(Model)),
  )
}

/// How a step changed the thread's choice.
pub type Change {
  Keep
  Picked(ModelChoice)
  /// Back on crush's default model.
  BackToDefault
}

/// What a step did: the catalog to keep, and the change to the choice.
pub type Done {
  Done(catalog: Option(List(Model)), change: Change)
}

/// Run `step` on the thread's connection, or say there isn't one.
pub fn run(
  connection: Option(Connection),
  sink: Sink,
  home: #(String, String),
  catalog: Option(List(Model)),
  step: fn(Context) -> Done,
) -> Done {
  case connection {
    Some(connection) -> step(Context(connection:, sink:, home:, catalog:))
    None -> {
      let _ =
        sink.post(
          "_the agent isn't connected right now; try again in a moment._",
        )
      Done(catalog:, change: Keep)
    }
  }
}

/// The thread's choice after `change`.
pub fn apply(
  change: Change,
  choice: Option(ModelChoice),
) -> Option(ModelChoice) {
  case change {
    Keep -> choice
    Picked(choice) -> Some(choice)
    BackToDefault -> None
  }
}

/// Run `step` with the catalog, fetched if the thread doesn't have it yet.
/// Whatever the step does, the catalog is handed back. If it can't be had,
/// `failed` says why in the thread.
fn with_catalog(
  context: Context,
  failed: fn(String) -> Nil,
  step: fn(Context, List(Model)) -> Change,
) -> Done {
  let fetched = case context.catalog {
    Some(catalog) -> Ok(catalog)
    None -> {
      use body <- result.try(call(
        context,
        client.providers(context.connection.workspace_id),
      ))
      models.parse_catalog(body)
      |> result.replace_error("crush offered no models")
    }
  }
  case fetched {
    Ok(catalog) -> {
      let context = Context(..context, catalog: Some(catalog))
      Done(catalog: Some(catalog), change: step(context, catalog))
    }
    Error(reason) -> {
      failed(reason)
      Done(catalog: None, change: Keep)
    }
  }
}

fn current(context: Context) -> Result(Current, String) {
  let connection = context.connection
  use body <- result.try(call(
    context,
    client.session_info(connection.workspace_id, connection.session_id),
  ))
  models.parse_current(body)
  |> result.replace_error("crush didn't say which model the session runs")
}

/// The model crush runs a session on when nothing is pinned.
fn default(context: Context) -> Result(ModelChoice, String) {
  use body <- result.try(call(
    context,
    client.workspace_config(context.connection.workspace_id),
  ))
  json.parse(body, decode.at(["models", "large", "model"], decode.string))
  |> result.map(fn(model) { ModelChoice(model:, reasoning: DefaultReasoning) })
  |> result.replace_error("crush didn't say what its default model is")
}

fn call(context: Context, call: client.Call(a)) -> Result(a, String) {
  conn.call(context.connection, call)
  |> result.map_error(fn(error) {
    case error {
      client.Status(_, message) -> message
      other -> conn.describe(other)
    }
  })
}

/// Why a pin didn't happen.
type PinError {
  /// The catalog doesn't have the model, or the model doesn't take the
  /// reasoning.
  NotTaken(String)
  /// crush refused it: it can't build the model.
  Refused(String)
  /// crush couldn't be asked.
  Unreachable(String)
}

fn describe(error: PinError) -> String {
  case error {
    NotTaken(reason) | Refused(reason) | Unreachable(reason) -> reason
  }
}

/// Pin `choice` and say what the session runs now.
fn pin(
  context: Context,
  catalog: List(Model),
  choice: ModelChoice,
) -> Result(Current, PinError) {
  use model <- result.try(
    models.check(catalog, choice) |> result.map_error(NotTaken),
  )
  let connection = context.connection
  let pinned =
    conn.call(
      connection,
      client.set_session_model(
        workspace_id: connection.workspace_id,
        session_id: connection.session_id,
        provider: models.provider,
        choice:,
      ),
    )
  case pinned {
    Ok(Nil) -> Ok(models.after(model, choice))
    Error(client.Status(_, reason)) -> Error(Refused(reason))
    Error(other) -> Error(Unreachable(conn.describe(other)))
  }
}

/// After reaching a server that may be new: pin the thread's saved choice.
/// A model that has left the catalog, or that crush won't run, puts the
/// thread back on the default; a reasoning level the model no longer takes
/// keeps the model at its own default. Either way the thread is told.
pub fn restore(context: Context, saved: Option(ModelChoice)) -> Done {
  case saved {
    None -> Done(catalog: context.catalog, change: Keep)
    Some(choice) -> {
      let failed = fn(reason) {
        sys.warn("crushling: couldn't pin " <> choice.model <> ": " <> reason)
      }
      use context, catalog <- with_catalog(context, failed)
      case models.find(catalog, choice.model) {
        Error(_) -> {
          say(
            context,
            "_this thread was set to `"
              <> choice.model
              <> "`, which isn't offered anymore, so it's back on the default model._",
          )
          BackToDefault
        }
        Ok(model) -> {
          let #(choice, change) = case models.fits(model, choice.reasoning) {
            True -> #(choice, Keep)
            False -> {
              say(
                context,
                "_`"
                  <> model.id
                  <> "` doesn't take the reasoning level this thread had anymore, so it's on the model's own default._",
              )
              let choice = ModelChoice(..choice, reasoning: DefaultReasoning)
              #(choice, Picked(choice))
            }
          }
          case pin(context, catalog, choice) {
            Ok(_) -> change
            Error(Refused(reason)) | Error(NotTaken(reason)) -> {
              say(
                context,
                "_crush wouldn't run `"
                  <> choice.model
                  <> "` ("
                  <> reason
                  <> "), so this thread is back on the default model._",
              )
              BackToDefault
            }
            // Couldn't ask: keep the choice (as corrected) for the next connect.
            Error(Unreachable(reason)) -> {
              failed(reason)
              change
            }
          }
        }
      }
    }
  }
}

/// `!model`, with or without a model to switch to.
pub fn command(
  context: Context,
  request: models.Request,
  user: String,
) -> Done {
  case request {
    models.ShowCard -> show(context)
    models.Choose(choice) ->
      set(context, user, fn(_) { Ok(#(choice, Picked(choice))) })
    models.UseDefault ->
      set(context, user, fn(context) {
        default(context) |> result.map(fn(choice) { #(choice, BackToDefault) })
      })
  }
}

fn show(context: Context) -> Done {
  let failed = fn(reason) {
    say(context, "_couldn't show the model: " <> reason <> "._")
  }
  use context, catalog <- with_catalog(context, failed)
  let shown = {
    use current <- result.try(current(context))
    context.sink.post_blocks(
      "Model: " <> current.model.name,
      models.card(current, current, catalog, context.home, ""),
    )
  }
  case shown {
    Ok(_) -> Nil
    Error(reason) -> failed(reason)
  }
  Keep
}

/// Switch to what `target` names, and say so in the thread.
fn set(
  context: Context,
  user: String,
  target: fn(Context) -> Result(#(ModelChoice, Change), String),
) -> Done {
  let failed = fn(reason) {
    say(context, "_couldn't switch the model: " <> reason <> "._")
  }
  use context, catalog <- with_catalog(context, failed)
  let switched = {
    use #(choice, change) <- result.try(target(context))
    use after <- result.map(
      pin(context, catalog, choice) |> result.map_error(describe),
    )
    #(after, change)
  }
  case switched {
    Ok(#(after, change)) -> {
      say(context, switched_note(user, after))
      change
    }
    Error(reason) -> {
      failed(reason)
      Keep
    }
  }
}

/// Someone used the card posted as `card_ts`. Changing the model menu only
/// redraws the card for that model; Confirm switches. Whatever happens, the
/// card ends up true: a refused confirm puts the menus back.
pub fn pick(
  context: Context,
  pick: models.Pick,
  card_ts: String,
  user: String,
) -> Done {
  let failed = fn(reason) {
    say(context, "_couldn't switch the model: " <> reason <> "._")
  }
  use context, catalog <- with_catalog(context, failed)
  case current(context) {
    Error(reason) -> {
      failed(reason)
      Keep
    }
    Ok(before) ->
      case pick {
        models.Preview(id) -> {
          let shown =
            models.find(catalog, id)
            |> result.map(fn(model) {
              models.after(model, ModelChoice(id, DefaultReasoning))
            })
            |> result.unwrap(before)
          redraw(context, card_ts, catalog, before, shown, "", "")
          Keep
        }
        models.Confirm(choice) ->
          case pin(context, catalog, choice) |> result.map_error(describe) {
            // The card has done its job. If it can't be deleted (it may
            // be somewhere the sink can't reach), show the new model on it.
            Ok(after) -> {
              case context.sink.delete(card_ts) {
                Ok(Nil) -> Nil
                Error(_) -> {
                  let fallback = switched_note(user, after)
                  redraw(context, card_ts, catalog, after, after, "", fallback)
                }
              }
              Picked(choice)
            }
            Error(reason) -> {
              let note = "couldn't switch: " <> reason <> "."
              let fallback = "_" <> note <> "_"
              redraw(context, card_ts, catalog, before, before, note, fallback)
              Keep
            }
          }
      }
  }
}

/// Redraw the card. The card may be somewhere the thread's sink can't
/// update, such as a conversation the work has left; then `fallback`, if
/// any, goes in the thread instead.
fn redraw(
  context: Context,
  card_ts: String,
  catalog: List(Model),
  current: Current,
  shown: Current,
  note: String,
  fallback: String,
) -> Nil {
  let updated =
    context.sink.update_blocks(
      card_ts,
      "Model: " <> current.model.name,
      models.card(current, shown, catalog, context.home, note),
    )
  case updated, fallback {
    Ok(Nil), _ | Error(_), "" -> Nil
    Error(_), fallback -> say(context, fallback)
  }
}

fn switched_note(user: String, current: Current) -> String {
  "_<@"
  <> user
  <> "> switched the model to "
  <> models.summary(current)
  <> ". It applies from the next turn._"
}

fn say(context: Context, text: String) -> Nil {
  let _ = context.sink.post(text)
  Nil
}
