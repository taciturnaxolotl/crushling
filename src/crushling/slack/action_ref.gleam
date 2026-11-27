//// What a button, menu option or block carries so a press can be traced
//// back: written into a card's `value` or `block_id`, read from the
//// payload Slack sends when someone presses it.
////
//// Every ref is `<version>|<kind>|<fields…>`. Cards stay in Slack long
//// after the bridge that posted them, so `decode` also reads the formats
//// from before refs had a version, and a change of format gets a new
//// version rather than changing an old one.

import crushling/meta.{type Reasoning, DefaultReasoning, Effort, Thinking}
import gleam/list
import gleam/result
import gleam/string

pub type Ref {
  /// A thread, by its channel and root ts.
  ThreadRef(channel: String, thread_ts: String)
  /// A part of a model card (`ModelMenu` or `ConfirmButton`) for the thread
  /// at `channel` and `thread_ts`, drawn for `model`.
  CardRef(part: CardPart, channel: String, thread_ts: String, model: String)
  /// A model card's reasoning menu, drawn for `model`.
  ReasoningMenu(model: String)
  /// A reasoning menu's option: the model it's for, and the reasoning.
  ReasoningOption(model: String, reasoning: Reasoning)
}

pub type CardPart {
  ModelMenu
  ConfirmButton
}

const version = "1"

const separator = "|"

pub fn encode(ref: Ref) -> String {
  let #(kind, fields) = case ref {
    ThreadRef(channel:, thread_ts:) -> #("thread", [channel, thread_ts])
    CardRef(part:, channel:, thread_ts:, model:) -> #(
      case part {
        ModelMenu -> "model"
        ConfirmButton -> "confirm"
      },
      [channel, thread_ts, model],
    )
    ReasoningMenu(model:) -> #("reasoning", [model])
    ReasoningOption(model:, reasoning:) -> #("option", [
      reasoning_word(reasoning),
      model,
    ])
  }
  string.join([version, kind, ..fields], separator)
}

pub fn decode(value: String) -> Result(Ref, Nil) {
  case string.split(value, separator) {
    ["1", "thread", channel, thread_ts] -> Ok(ThreadRef(channel, thread_ts))
    ["1", "model", channel, thread_ts, ..model] ->
      card(ModelMenu, channel, thread_ts, model)
    ["1", "confirm", channel, thread_ts, ..model] ->
      card(ConfirmButton, channel, thread_ts, model)
    ["1", "reasoning", ..model] -> named(model) |> result.map(ReasoningMenu)
    ["1", "option", word, ..model] -> {
      use reasoning <- result.try(read_reasoning(word))
      use model <- result.map(named(model))
      ReasoningOption(model, reasoning)
    }
    other -> legacy(other)
  }
}

/// Model ids may hold the separator, so a model is always the last field.
fn named(parts: List(String)) -> Result(String, Nil) {
  case string.join(parts, separator) {
    "" -> Error(Nil)
    model -> Ok(model)
  }
}

fn card(
  part: CardPart,
  channel: String,
  thread_ts: String,
  model: List(String),
) -> Result(Ref, Nil) {
  Ok(CardRef(part, channel, thread_ts, string.join(model, separator)))
}

fn reasoning_word(reasoning: Reasoning) -> String {
  case reasoning {
    Effort(level) -> "effort:" <> level
    Thinking(True) -> "think:on"
    Thinking(False) -> "think:off"
    DefaultReasoning -> "default"
  }
}

fn read_reasoning(word: String) -> Result(Reasoning, Nil) {
  case word {
    "effort:" <> level -> Ok(Effort(level))
    "think:on" -> Ok(Thinking(True))
    "think:off" -> Ok(Thinking(False))
    _ -> Error(Nil)
  }
}

/// The formats from before refs had a version: `channel|ts` on buttons,
/// `crushling_model|channel|ts|model` and `crushling_confirm|…` on model
/// cards, `crushling_reasoning|model`, and `model|effort:level` options.
fn legacy(parts: List(String)) -> Result(Ref, Nil) {
  case parts {
    ["crushling_model", channel, thread_ts, ..model] ->
      card(ModelMenu, channel, thread_ts, model)
    ["crushling_confirm", channel, thread_ts, ..model] ->
      card(ConfirmButton, channel, thread_ts, model)
    ["crushling_reasoning", ..model] ->
      named(model) |> result.map(ReasoningMenu)
    [first, ..rest] ->
      case list.last(rest) |> result.try(read_reasoning) {
        Ok(reasoning) ->
          named([first, ..list.take(rest, list.length(rest) - 1)])
          |> result.map(ReasoningOption(_, reasoning))
        Error(Nil) ->
          case rest, string.starts_with(first, "crushling_") {
            [thread_ts], False -> Ok(ThreadRef(first, thread_ts))
            _, _ -> Error(Nil)
          }
      }
    [] -> Error(Nil)
  }
}
