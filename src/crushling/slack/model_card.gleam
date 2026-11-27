//// The `!model` card: what the session runs, menus to pick a model and how
//// it reasons, and a Confirm button; and reading what someone picked on it.

import crushling/crush/catalog.{
  type Current, type Model, Levels, NoReasoning, Toggle,
}
import crushling/meta.{
  type ModelChoice, type Reasoning, DefaultReasoning, Effort, ModelChoice,
  Thinking,
}
import crushling/registry/tailnet
import crushling/slack/action_ref.{
  CardRef, ConfirmButton, ModelMenu, ReasoningMenu, ReasoningOption,
}
import crushling/slack/blocks
import gleam/dict
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
import slackline/interaction
import slackline/view

/// What someone did on a card.
pub type Pick {
  /// The model menu changed: show that model's reasoning, switch nothing.
  Preview(model: String)
  /// Confirm, with the menus as they were.
  Confirm(ModelChoice)
}

pub const model_action = "crushling_model"

pub const reasoning_action = "crushling_reasoning"

pub const confirm_action = "crushling_confirm"

/// The actions a press on a card arrives with; the reasoning menu sends
/// none of its own, its value arrives with Confirm.
pub fn actions() -> List(String) {
  [model_action, confirm_action]
}

/// Slack's limit on options in one menu.
const max_options = 100

/// Slack's limit on an option's text.
const max_label = 75

/// A pick on a card: the thread it belongs to, which may not be where the
/// card is (a code channel's card sits at the top of the channel), what
/// was picked, the card, and who picked.
pub type Picked {
  Picked(home: #(String, String), pick: Pick, card: meta.Card, user: String)
}

/// An action on a card.
pub fn decode(
  action: interaction.BlockAction,
  payload: interaction.BlockActionsPayload,
) -> Result(Picked, Nil) {
  use #(block_id, pick) <- result.try(case action {
    // The model menu changed.
    interaction.StaticSelectAction(
      action_id:,
      block_id: Some(block_id),
      selected_option: Some(option),
      ..,
    )
      if action_id == model_action
    -> Ok(#(block_id, Preview(option.value)))
    // Confirm: what the menus hold now is in the payload's state.
    interaction.ButtonAction(action_id:, block_id: Some(block_id), ..)
      if action_id == confirm_action
    -> {
      let value = fn(of) { menu_value(payload.state, of) }
      let model = option.or(value(model_action), confirm_model(block_id))
      use pick <- result.map(read_confirm(model, value(reasoning_action)))
      #(block_id, pick)
    }
    _ -> Error(Nil)
  })
  use home <- result.try(case action_ref.decode(block_id) {
    Ok(CardRef(channel:, thread_ts:, ..)) -> Ok(#(channel, thread_ts))
    _ -> Error(Nil)
  })
  use card <- result.map(tailnet.card_of(payload))
  Picked(home:, pick:, card:, user: payload.user.id)
}

/// The value picked in the card's menu `action_id`, whichever block it is in.
fn menu_value(
  state: Option(view.ViewState),
  action_id: String,
) -> Option(String) {
  case state {
    None -> None
    Some(state) ->
      dict.values(state.values)
      |> list.find_map(fn(block) {
        case dict.get(block, action_id) {
          Ok(view.StateStaticSelect(selected_option: Some(option))) ->
            Ok(option.value)
          _ -> Error(Nil)
        }
      })
      |> option.from_result
  }
}

/// The model a card's Confirm button was drawn for, from its block id.
fn confirm_model(block_id: String) -> Option(String) {
  case action_ref.decode(block_id) {
    Ok(CardRef(part: ConfirmButton, model:, ..)) if model != "" -> Some(model)
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
  let reasoning = case option.map(reasoning, action_ref.decode) {
    Some(Ok(ReasoningOption(model: for, reasoning:))) if for == model ->
      reasoning
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

fn reasoning_value(model: String, reasoning: Reasoning) -> String {
  action_ref.encode(ReasoningOption(model:, reasoning:))
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
  let card_ref = fn(part) {
    action_ref.encode(CardRef(
      part:,
      channel: home.0,
      thread_ts: home.1,
      model: model.id,
    ))
  }
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
      with: [input.block_id(card_ref(ModelMenu)), input.dispatch_action(True)],
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
          with: [input.block_id(action_ref.encode(ReasoningMenu(model.id)))],
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
      with: [actions.block_id(card_ref(ConfirmButton))],
    )
  [
    blocks.text("Model: " <> catalog.summary(current)),
    model_menu,
    ..list.flatten([
      reasoning_menu,
      [confirm],
      case note {
        "" -> []
        note -> [blocks.context(note)]
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
