//// A thread's model, as data: the catalog and current model as the
//// thread's `crush server` reports them, checking a choice against the
//// catalog, the `!model` card, and reading what someone picked on it.
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
import gleam/dynamic/decode.{type Decoder}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import slackline/block
import slackline/block/actions
import slackline/block/input
import slackline/element
import slackline/element/button
import slackline/element/static_select

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

/// What someone did on a card.
pub type Pick {
  /// The model menu changed: show that model's reasoning, switch nothing.
  Preview(model: String)
  /// Confirm, with the menus as they were.
  Confirm(ModelChoice)
}

/// The provider id the agents use.
pub const provider = "hyper"

pub const model_action = "crushling_model"

pub const reasoning_action = "crushling_reasoning"

pub const confirm_action = "crushling_confirm"

/// Slack's limit on options in one menu.
const max_options = 100

/// Slack's limit on an option's text.
const max_label = 75

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
  case list.key_find(providers, provider) {
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

// The card ---------------------------------------------------------------------

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

fn reasoning_label(kind: Kind, reasoning: Reasoning) -> Option(String) {
  case kind, reasoning {
    Levels(levels:, ..), Effort(level) ->
      Some(list.key_find(levels, level) |> result.unwrap(level))
    Toggle, Thinking(True) -> Some("on")
    Toggle, Thinking(False) -> Some("off")
    _, _ -> None
  }
}

/// The thread a card's model menu or confirm button names: `<what>|channel|
/// ts`, with more after it on the model menu.
pub fn read_block_id(block_id: String) -> Result(#(String, String), Nil) {
  case string.split(block_id, "|") {
    ["crushling_model", channel, thread_ts, ..]
    | ["crushling_confirm", channel, thread_ts, ..] -> Ok(#(channel, thread_ts))
    _ -> Error(Nil)
  }
}

fn home_id(prefix: String, home: #(String, String)) -> String {
  prefix <> "|" <> home.0 <> "|" <> home.1
}

/// A reasoning option's value: the model it's for, and the reasoning.
fn reasoning_value(model: String, reasoning: Reasoning) -> String {
  model
  <> "|"
  <> case reasoning {
    Effort(level) -> "effort:" <> level
    Thinking(True) -> "think:on"
    Thinking(False) -> "think:off"
    DefaultReasoning -> "default"
  }
}

fn read_reasoning(value: String) -> Result(#(String, Reasoning), Nil) {
  case string.split_once(value, "|") {
    Ok(#(model, "effort:" <> level)) -> Ok(#(model, Effort(level)))
    Ok(#(model, "think:on")) -> Ok(#(model, Thinking(True)))
    Ok(#(model, "think:off")) -> Ok(#(model, Thinking(False)))
    _ -> Error(Nil)
  }
}

/// The model a card's Confirm button was drawn for, from its block id.
pub fn confirm_model(block_id: String) -> Option(String) {
  case string.split(block_id, "|") {
    ["crushling_confirm", _, _, model, ..] -> Some(model)
    _ -> None
  }
}

/// What Confirm asks for, from the card's menus: the model menu's value, and
/// the reasoning menu's if it has one. A reasoning value for another model
/// (left over from before the model menu changed) means the new model's
/// default.
pub fn read_confirm(
  model: Option(String),
  reasoning: Option(String),
) -> Result(Pick, Nil) {
  use model <- result.map(option.to_result(model, Nil))
  let reasoning = case option.map(reasoning, read_reasoning) {
    Some(Ok(#(for, reasoning))) if for == model -> reasoning
    _ -> DefaultReasoning
  }
  Confirm(ModelChoice(model:, reasoning:))
}

fn fit(text: String, room: Int) -> String {
  case string.length(text) > room {
    True -> string.slice(text, 0, room - 1) <> "…"
    False -> text
  }
}

/// The models the menu offers: the catalog, up to Slack's limit, with the
/// shown model kept in when the catalog has it.
fn offered(catalog: List(Model), shown: Model) -> List(Model) {
  let listed = list.any(catalog, fn(model) { model.id == shown.id })
  case list.length(catalog) > max_options, listed {
    False, _ -> catalog
    True, False -> list.take(catalog, max_options)
    True, True -> {
      let rest = list.filter(catalog, fn(model) { model.id != shown.id })
      [shown, ..list.take(rest, max_options - 1)]
    }
  }
}

fn reasoning_options(model: Model) -> List(#(String, Reasoning)) {
  case model.kind {
    Levels(levels:, ..) ->
      list.map(levels, fn(level) { #(level.1, Effort(level.0)) })
    Toggle -> [
      #("Thinking on", Thinking(True)),
      #("Thinking off", Thinking(False)),
    ]
    NoReasoning -> []
  }
}

/// The card: what the session runs, full-width menus set to `shown`, and a
/// Confirm button. `shown` is `current` unless someone changed the model menu
/// and hasn't confirmed. `note` goes under, or nowhere when it is "". `home`
/// is the thread the card belongs to.
///
/// Slack keeps what someone picked in an input across updates of a block
/// with the same id, so each menu's block id names the model it was drawn
/// for: a redraw for another model starts clean.
pub fn card(
  current: Current,
  shown: Current,
  catalog: List(Model),
  home: #(String, String),
  note: String,
) -> List(block.Block) {
  let model = shown.model
  let model_options =
    offered(catalog, model)
    |> list.map(fn(model) { block.option(fit(model.name, max_label), model.id) })
  let model_menu =
    block.input(
      label: "Model",
      element: element.static_select(action_id: model_action, with: [
        static_select.options(model_options),
        static_select.placeholder("Pick a model"),
        ..selected(model_options, model.id)
      ]),
      with: [
        input.block_id(home_id("crushling_model", home) <> "|" <> model.id),
        input.dispatch_action(True),
      ],
    )
  let reasoning_menu = case reasoning_options(model) {
    [] -> []
    choices -> {
      let options =
        list.map(choices, fn(choice) {
          block.option(
            fit(choice.0, max_label),
            reasoning_value(model.id, choice.1),
          )
        })
      [
        block.input(
          label: "Reasoning",
          element: element.static_select(action_id: reasoning_action, with: [
            static_select.options(options),
            static_select.placeholder("Reasoning"),
            ..selected(options, reasoning_value(model.id, shown.reasoning))
          ]),
          with: [input.block_id("crushling_reasoning|" <> model.id)],
        ),
      ]
    }
  }
  let confirm =
    block.actions(
      elements: [
        element.button(text: "Confirm", action_id: confirm_action, with: [
          button.style(block.Primary),
        ]),
      ],
      // The model shown, in case Slack leaves an untouched menu out of the
      // state it sends.
      with: [
        actions.block_id(home_id("crushling_confirm", home) <> "|" <> model.id),
      ],
    )
  [
    block.section(text: block.mrkdwn("Model: " <> summary(current)), with: []),
    model_menu,
    ..list.flatten([
      reasoning_menu,
      [confirm],
      case note {
        "" -> []
        note -> [
          block.context(elements: [block.context_mrkdwn(note)], with: []),
        ]
      },
    ])
  ]
}

fn selected(
  options: List(block.SelectOption),
  value: String,
) -> List(block.Attr(block.StaticSelectElement)) {
  case list.find(options, fn(option) { option.value == value }) {
    Ok(option) -> [static_select.initial_option(option)]
    Error(Nil) -> []
  }
}
