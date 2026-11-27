//// A thread's model, as data: the catalog and current model as the
//// thread's `crush server` reports them, and checking a choice against the
//// catalog.
////
//// It all comes from the agent's own crush, so the menu only offers models
//// it can run, and the card shows the model a session really uses (crush
//// falls back to the provider's default for a model not in its catalog).
//// The reasoning rules follow crush's (`agent_dispatch_model.go`): a model
//// takes effort levels, or a thinking toggle, or neither.

import crushling/meta.{
  type ModelChoice, type Reasoning, DefaultReasoning, Effort, ModelChoice,
  Thinking,
}
import crushling/provider
import gleam/dynamic/decode.{type Decoder}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Model {
  Model(id: String, name: String, kind: Kind)
}

/// How a model can reason.
pub type Kind {
  /// Effort levels as value and label, and the one used when none is
  /// picked.
  Levels(levels: List(#(String, String)), default: String)
  /// Thinking on or off, off unless picked.
  Toggle
  NoReasoning
}

/// The model a session runs, and how it reasons now.
pub type Current {
  Current(model: Model, reasoning: Reasoning)
}

// Reading crush ----------------------------------------------------------------

fn model_decoder() -> Decoder(Model) {
  use id <- decode.field("id", decode.string)
  use name <- decode.optional_field("name", id, decode.string)
  use kind <- decode.optional_field("reasoning", NoReasoning, kind_decoder())
  decode.success(Model(id:, name:, kind:))
}

/// As catwalk's `ReasoningEffortLevels` and `CanReason`: levels win, then a
/// toggle.
fn kind_decoder() -> Decoder(Kind) {
  use thinking <- decode.optional_field("thinking", "", decode.string)
  use levels <- decode.optional_field(
    "effort_levels",
    [],
    decode.list({
      use value <- decode.field("value", decode.string)
      use display <- decode.optional_field("display", value, decode.string)
      decode.success(#(value, display))
    }),
  )
  use default <- decode.optional_field(
    "default_effort_level",
    "",
    decode.string,
  )
  decode.success(case levels, thinking {
    [first, ..], _ -> {
      let default = case list.key_find(levels, default) {
        Ok(_) -> default
        Error(Nil) -> first.0
      }
      Levels(levels:, default:)
    }
    [], "toggleable" -> Toggle
    [], _ -> NoReasoning
  })
}

/// The agents' provider's models, from crush's `/providers`. A provider
/// that is missing or lists no models is an error: there'd be nothing to
/// pick from.
pub fn parse_catalog(body: String) -> Result(List(Model), Nil) {
  let decoder =
    decode.list({
      use id <- decode.field("id", decode.string)
      use models <- decode.optional_field(
        "models",
        [],
        decode.list(model_decoder()),
      )
      decode.success(#(id, models))
    })
  use providers <- result.try(
    json.parse(body, decoder) |> result.replace_error(Nil),
  )
  case list.key_find(providers, provider.id) {
    Ok([_, ..] as models) -> Ok(models)
    _ -> Error(Nil)
  }
}

/// The session's model and reasoning, from crush's session endpoint. crush
/// reports an empty model when the session's pin can't be built; that is an
/// error too.
pub fn parse_current(body: String) -> Result(Current, Nil) {
  let decoder = {
    use model <- decode.field("model", model_decoder())
    use #(effort, think) <- decode.optional_field("model_cfg", #("", False), {
      use effort <- decode.optional_field("reasoning_effort", "", decode.string)
      use think <- decode.optional_field("think", False, decode.bool)
      decode.success(#(effort, think))
    })
    decode.success(Current(
      model:,
      reasoning: settled(model.kind, effort, think),
    ))
  }
  case json.parse(body, decoder) {
    Ok(Current(model: Model(id: "", ..), ..)) | Error(_) -> Error(Nil)
    Ok(current) -> Ok(current)
  }
}

/// The reasoning a session runs with, as crush settles it
/// (`effectiveReasoningEffort`): a level it doesn't take means its default.
fn settled(kind: Kind, effort: String, think: Bool) -> Reasoning {
  case kind {
    Levels(levels:, default:) ->
      case list.key_find(levels, effort) {
        Ok(_) -> Effort(effort)
        Error(Nil) -> Effort(default)
      }
    Toggle -> Thinking(think)
    NoReasoning -> DefaultReasoning
  }
}

// Choosing ---------------------------------------------------------------------

pub fn find(catalog: List(Model), id: String) -> Result(Model, String) {
  list.find(catalog, fn(model) { model.id == id })
  |> result.replace_error("there's no model called `" <> id <> "`")
}

/// Check `choice` against the catalog: the model is there and takes the
/// reasoning. Errors say what's wrong in words for the thread.
pub fn check(
  catalog: List(Model),
  choice: ModelChoice,
) -> Result(Model, String) {
  use model <- result.try(find(catalog, choice.model))
  case fits(model, choice.reasoning) {
    True -> Ok(model)
    False -> Error(takes(model))
  }
}

/// Whether `model` takes `reasoning`. Every model takes the default.
pub fn fits(model: Model, reasoning: Reasoning) -> Bool {
  case reasoning, model.kind {
    DefaultReasoning, _ -> True
    Effort(level), Levels(levels:, ..) ->
      result.is_ok(list.key_find(levels, level))
    Thinking(_), Toggle -> True
    _, _ -> False
  }
}

fn takes(model: Model) -> String {
  "`"
  <> model.id
  <> "` "
  <> case model.kind {
    Levels(levels:, ..) ->
      "takes " <> string.join(list.map(levels, fn(level) { level.0 }), ", ")
    Toggle -> "takes on or off"
    NoReasoning -> "doesn't take a reasoning level"
  }
}

/// What the session runs once `choice` is pinned, worked out from the
/// catalog rather than asked of crush again.
pub fn after(model: Model, choice: ModelChoice) -> Current {
  let reasoning = case choice.reasoning, model.kind {
    DefaultReasoning, Levels(default:, ..) -> Effort(default)
    DefaultReasoning, Toggle -> Thinking(False)
    reasoning, _ -> reasoning
  }
  Current(model:, reasoning:)
}

/// What `!model` asks for. `default` puts the thread back on the bridge's
/// default model.
pub type Request {
  ShowCard
  UseDefault
  Choose(ModelChoice)
}

/// `!model`'s argument: nothing, `default`, a model id, or an id and a
/// reasoning level (an effort level, or `on`/`off` for thinking). Which
/// one a model takes is checked against the catalog later.
pub fn parse_argument(argument: String) -> Result(Request, Nil) {
  case
    string.split(string.trim(argument), " ")
    |> list.filter(fn(word) { word != "" })
  {
    [] -> Ok(ShowCard)
    [word] ->
      case string.lowercase(word) {
        "default" -> Ok(UseDefault)
        _ -> Ok(Choose(ModelChoice(model: word, reasoning: DefaultReasoning)))
      }
    [model, level] ->
      Ok(Choose(ModelChoice(model:, reasoning: reasoning_word(level))))
    _ -> Error(Nil)
  }
}

fn reasoning_word(word: String) -> Reasoning {
  case string.lowercase(word) {
    "on" -> Thinking(True)
    "off" -> Thinking(False)
    level -> Effort(level)
  }
}

// In words ---------------------------------------------------------------------

/// The model and how it reasons, in words.
pub fn summary(current: Current) -> String {
  "*"
  <> current.model.name
  <> "*"
  <> case reasoning_label(current.model.kind, current.reasoning) {
    Some(label) -> " · reasoning " <> label
    None -> ""
  }
}

/// How `current` reasons, in words for a card: "`high` reasoning",
/// "thinking on", or "" for the model's default.
pub fn reasoning_words(current: Current) -> String {
  case current.model.kind, current.reasoning {
    Levels(..), Effort(level) -> "`" <> level <> "` reasoning"
    Toggle, Thinking(True) -> "thinking on"
    Toggle, Thinking(False) -> "thinking off"
    _, _ -> ""
  }
}

fn reasoning_label(kind: Kind, reasoning: Reasoning) -> Option(String) {
  case kind, reasoning {
    Levels(levels:, ..), Effort(level) ->
      Some(list.key_find(levels, level) |> result.unwrap(level))
    Toggle, Thinking(True) -> Some("on")
    Toggle, Thinking(False) -> Some("off")
    _, _ -> None
  }
}
