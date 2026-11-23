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
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import slackline/block
import slackline/block/actions
import slackline/element
import slackline/element/static_select

pub type Model {
  Model(id: String, name: String, input: Float, output: Float, kind: Kind)
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

/// What someone picked on a card. A reasoning pick names the model the card
/// showed, so it can't land on a model that changed since.
pub type Pick {
  ModelPick(id: String)
  ReasoningPick(model: String, reasoning: Reasoning)
}

/// The provider id the agents use.
pub const provider = "hyper"

pub const model_action = "crushling_model"

pub const reasoning_action = "crushling_reasoning"

/// Slack's limit on options in one menu.
const max_options = 100

/// Slack's limit on an option's text.
const max_label = 75

// Reading crush ----------------------------------------------------------------

fn model_decoder() -> Decoder(Model) {
  use id <- decode.field("id", decode.string)
  use name <- decode.optional_field("name", id, decode.string)
  use #(input, output) <- decode.optional_field("pricing", #(0.0, 0.0), {
    use input <- decode.optional_field("input", 0.0, number())
    use output <- decode.optional_field("output", 0.0, number())
    decode.success(#(input, output))
  })
  use kind <- decode.optional_field("reasoning", NoReasoning, kind_decoder())
  decode.success(Model(id:, name:, input:, output:, kind:))
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

/// JSON numbers may come without a fraction.
fn number() -> Decoder(Float) {
  decode.one_of(decode.float, [decode.map(decode.int, int.to_float)])
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

/// What a pick on a card asks for. A reasoning pick for a model the session
/// no longer runs is refused, with the reason.
pub fn choose(current: Current, pick: Pick) -> Result(ModelChoice, String) {
  case pick {
    ModelPick(id:) -> Ok(ModelChoice(model: id, reasoning: DefaultReasoning))
    ReasoningPick(model:, reasoning:) if model == current.model.id ->
      Ok(ModelChoice(model:, reasoning:))
    ReasoningPick(..) ->
      Error(
        "the thread switched to " <> current.model.name <> " since this card",
      )
  }
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

/// Dollars, with cents only when there are any.
pub fn dollars(amount: Float) -> String {
  let cents = float.round(amount *. 100.0)
  let whole = int.to_string(cents / 100)
  case cents % 100 {
    0 -> "$" <> whole
    rest -> "$" <> whole <> "." <> string.pad_start(int.to_string(rest), 2, "0")
  }
}

/// The model, its price, and how it reasons, in words.
pub fn summary(current: Current) -> String {
  let model = current.model
  "*"
  <> model.name
  <> "* · "
  <> dollars(model.input)
  <> " in / "
  <> dollars(model.output)
  <> " out per 1M tokens"
  <> case reasoning_label(model.kind, current.reasoning) {
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

/// The block id that carries the thread the card belongs to.
pub fn block_id(home: #(String, String)) -> String {
  "crushling_model|" <> home.0 <> "|" <> home.1
}

/// The thread a card's block id names.
pub fn read_block_id(block_id: String) -> Result(#(String, String), Nil) {
  case string.split(block_id, "|") {
    ["crushling_model", channel, thread_ts] -> Ok(#(channel, thread_ts))
    _ -> Error(Nil)
  }
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

/// Read a menu pick from its action id and the chosen option's value.
pub fn read_pick(action_id: String, value: String) -> Result(Pick, Nil) {
  case action_id == model_action, action_id == reasoning_action {
    True, _ -> Ok(ModelPick(value))
    _, True ->
      case string.split_once(value, "|") {
        Ok(#(model, "effort:" <> level)) ->
          Ok(ReasoningPick(model, Effort(level)))
        Ok(#(model, "think:on")) -> Ok(ReasoningPick(model, Thinking(True)))
        Ok(#(model, "think:off")) -> Ok(ReasoningPick(model, Thinking(False)))
        _ -> Error(Nil)
      }
    _, _ -> Error(Nil)
  }
}

fn fit(text: String, room: Int) -> String {
  case string.length(text) > room {
    True -> string.slice(text, 0, room - 1) <> "…"
    False -> text
  }
}

fn option_label(model: Model) -> String {
  let price = " · " <> dollars(model.input) <> "/" <> dollars(model.output)
  fit(model.name, max_label - string.length(price)) <> price
}

/// The models the menu offers: the catalog, up to Slack's limit, with the
/// current model kept in when the catalog has it.
fn offered(catalog: List(Model), current: Model) -> List(Model) {
  let listed = list.any(catalog, fn(model) { model.id == current.id })
  case list.length(catalog) > max_options, listed {
    False, _ -> catalog
    True, False -> list.take(catalog, max_options)
    True, True -> {
      let rest = list.filter(catalog, fn(model) { model.id != current.id })
      [current, ..list.take(rest, max_options - 1)]
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

/// The card: the session's model and reasoning, a menu of models, and a menu
/// of reasoning when the model takes any. `note` goes under them, or nowhere
/// when it is "". `home` is the thread the card belongs to.
pub fn card(
  current: Current,
  catalog: List(Model),
  home: #(String, String),
  note: String,
) -> List(block.Block) {
  let model = current.model
  let model_options =
    offered(catalog, model)
    |> list.map(fn(model) { block.option(option_label(model), model.id) })
  let model_menu =
    element.static_select(action_id: model_action, with: [
      static_select.options(model_options),
      static_select.placeholder("Pick a model"),
      ..selected(model_options, model.id)
    ])
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
        element.static_select(action_id: reasoning_action, with: [
          static_select.options(options),
          static_select.placeholder("Reasoning"),
          ..selected(options, reasoning_value(model.id, current.reasoning))
        ]),
      ]
    }
  }
  [
    block.section(text: block.mrkdwn("Model: " <> summary(current)), with: []),
    block.actions(elements: [model_menu, ..reasoning_menu], with: [
      actions.block_id(block_id(home)),
    ]),
    ..case note {
      "" -> []
      note -> [block.context(elements: [block.context_mrkdwn(note)], with: [])]
    }
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
