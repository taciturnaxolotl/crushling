//// What the bridge saves between restarts. For each thread, it saves whether
//// the thread answers every reply, how far it has read, and where its work is.
//// For each code channel, it saves the thread the channel belongs to.
////
//// This lives in the store (`crushling/store`). The files the bridge used to
//// keep, `<root>/<key>/crushling.json`, are only read once, when the store
//// imports them on its first start; `write` and `write_link` remain to make
//// such files in tests.

import crushling/venue.{type Venue}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Meta {
  Meta(
    /// Answer every reply in the thread, not just mentions. Set when the
    /// bot was mentioned in the thread's first message, or in a DM.
    follow: Bool,
    /// Set by `!pause`. Until `!resume`, only mentions reach the agent, even
    /// where it would otherwise answer everything.
    paused: Bool,
    /// The ts of the last message sent to the agent; later messages are
    /// new to it. "" when it has read nothing.
    cursor: String,
    venue: Venue,
    /// Tailnet access someone allowed, while it lasts.
    tailnet: Option(Grant),
    /// The model someone picked with `!model`, applied to the agent's
    /// session every time it connects. None runs the bridge's default.
    model: Option(ModelChoice),
  )
}

/// A Hyper model id and how it should reason.
pub type ModelChoice {
  ModelChoice(model: String, reasoning: Reasoning)
}

/// How a model reasons, as picked. Which of these a model takes depends on
/// the model: effort levels, a thinking toggle, or neither.
pub type Reasoning {
  /// Whatever crush does when nothing is picked: the model's default effort
  /// level, and thinking off.
  DefaultReasoning
  Effort(level: String)
  Thinking(on: Bool)
}

pub fn model_choice_to_json(choice: ModelChoice) -> json.Json {
  json.object([
    #("model", json.string(choice.model)),
    ..case choice.reasoning {
      DefaultReasoning -> []
      Effort(level) -> [#("effort", json.string(level))]
      Thinking(on) -> [#("think", json.bool(on))]
    }
  ])
}

pub fn model_choice_decoder() -> decode.Decoder(ModelChoice) {
  use model <- decode.field("model", decode.string)
  use effort <- decode.optional_field(
    "effort",
    None,
    decode.map(decode.string, Some),
  )
  use think <- decode.optional_field(
    "think",
    None,
    decode.map(decode.bool, Some),
  )
  let reasoning = case effort, think {
    Some(""), _ | None, None -> DefaultReasoning
    Some(level), _ -> Effort(level)
    None, Some(on) -> Thinking(on)
  }
  decode.success(ModelChoice(model:, reasoning:))
}

/// Tailnet access someone allowed: until when, in milliseconds since the
/// epoch, and the card that shows it.
pub type Grant {
  Grant(until_ms: Int, card: Card)
}

/// A posted Slack message, kept so it can be updated.
pub type Card {
  Card(channel: String, ts: String, thread_ts: String)
}

pub fn new(follow: Bool) -> Meta {
  Meta(
    follow:,
    paused: False,
    cursor: "",
    venue: venue.Thread,
    tailnet: None,
    model: None,
  )
}

/// Where a code channel came from: the thread that opened it, and when.
pub type Link {
  Link(origin_channel: String, origin_ts: String, opened_ts: String)
}

@external(erlang, "crushling_ffi", "read_file")
fn read_file(path: String) -> Result(String, Nil)

@external(erlang, "crushling_ffi", "write_private")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "crushling_ffi", "mkdir_p")
fn mkdir_p(path: String) -> Result(Nil, String)

/// Write a file whole, making its directory first: a new thread's meta is
/// saved before its launch creates the thread's directory.
fn write_private(path: String, content: String) -> Result(Nil, String) {
  use _ <- result.try(mkdir_p(filepath_dir(path)))
  write_file(path, content)
}

fn filepath_dir(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [_, ..rest] -> list.reverse(rest) |> string.join("/")
    [] -> "."
  }
}

pub fn read(path: String) -> Result(Meta, Nil) {
  use text <- result.try(read_file(path))
  json.parse(text, {
    use follow <- decode.optional_field("follow", False, decode.bool)
    use paused <- decode.optional_field("paused", False, decode.bool)
    use cursor <- decode.optional_field("cursor", "", decode.string)
    use stored <- decode.optional_field(
      "venue",
      None,
      decode.map(venue.decoder(), Some),
    )
    // Files from before the venue kept a code channel and its repository.
    use code_channel <- decode.optional_field("code_channel", "", decode.string)
    use repo <- decode.optional_field("repo", "", decode.string)
    use tailnet <- decode.optional_field(
      "tailnet",
      None,
      decode.optional(grant_decoder()),
    )
    decode.success(Meta(
      follow:,
      paused:,
      cursor:,
      venue: legacy_venue(stored, code_channel, repo),
      tailnet:,
      model: None,
    ))
  })
  |> result.replace_error(Nil)
}

/// A tailnet grant as JSON, as files and the store keep it.
pub fn grant_to_json(grant: Grant) -> json.Json {
  json.object([
    #("until_ms", json.int(grant.until_ms)),
    #("card_channel", json.string(grant.card.channel)),
    #("card_ts", json.string(grant.card.ts)),
    #("card_thread_ts", json.string(grant.card.thread_ts)),
  ])
}

pub fn grant_decoder() -> decode.Decoder(Grant) {
  use until_ms <- decode.field("until_ms", decode.int)
  use channel <- decode.field("card_channel", decode.string)
  use ts <- decode.field("card_ts", decode.string)
  use thread_ts <- decode.field("card_thread_ts", decode.string)
  decode.success(Grant(until_ms:, card: Card(channel:, ts:, thread_ts:)))
}

fn legacy_venue(stored: Option(Venue), channel: String, repo: String) -> Venue {
  case stored, channel, repo {
    Some(venue), _, _ -> venue
    None, "", "" -> venue.Thread
    None, "", repo -> venue.Archived(repo)
    None, channel, repo -> venue.CodeChannel(channel, repo)
  }
}

/// Write a thread's meta as the bridge used to, for tests of the import.
pub fn write(path: String, meta: Meta) -> Result(Nil, String) {
  json.object([
    #("follow", json.bool(meta.follow)),
    #("paused", json.bool(meta.paused)),
    #("cursor", json.string(meta.cursor)),
    #("venue", venue.to_json(meta.venue)),
    #("tailnet", json.nullable(meta.tailnet, grant_to_json)),
  ])
  |> json.to_string
  |> write_private(path, _)
}

pub fn read_link(path: String) -> Result(Link, Nil) {
  use text <- result.try(read_file(path))
  json.parse(text, {
    use origin_channel <- decode.field("origin_channel", decode.string)
    use origin_ts <- decode.field("origin_ts", decode.string)
    // Older files kept the opening time as `cursor`.
    use cursor <- decode.optional_field("cursor", "", decode.string)
    use opened_ts <- decode.optional_field("opened_ts", cursor, decode.string)
    decode.success(Link(origin_channel:, origin_ts:, opened_ts:))
  })
  |> result.replace_error(Nil)
}

/// Write a code channel's link as the bridge used to, for tests of the
/// import.
pub fn write_link(path: String, link: Link) -> Result(Nil, String) {
  json.object([
    #("origin_channel", json.string(link.origin_channel)),
    #("origin_ts", json.string(link.origin_ts)),
    #("opened_ts", json.string(link.opened_ts)),
  ])
  |> json.to_string
  |> write_private(path, _)
}
