//// Why a thread's agent went away, as far as its backend can tell, for
//// the note that ends the run it was in.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string

pub type PostMortem {
  /// Still running: only the connection to it broke. `last_words` is
  /// crush's last complaint in its log, or "".
  StillRunning(last_words: String)
  /// Nothing is there anymore: removed from outside.
  Vanished
  /// Killed for using more than `limit` of memory ("" when unknown).
  OutOfMemory(limit: String)
  /// crush exited with `code`, when known, after logging `last_words`.
  Exited(code: Option(Int), last_words: String)
  /// The backend couldn't say, for `reason`.
  Unknown(reason: String)
}

type Line {
  Line(level: String, message: String, error: String)
}

/// crush's last complaint in its JSON log: the last error, else the last
/// warning, as "message: error". "" when it logged neither.
pub fn last_words(log: String) -> String {
  let lines =
    string.split(log, "\n")
    |> list.filter_map(fn(line) { json.parse(line, line_decoder()) })
    |> list.reverse
  let at = fn(level) { list.find(lines, fn(line) { line.level == level }) }
  case result.lazy_or(at("ERROR"), fn() { at("WARN") }) {
    Ok(Line(message:, error: "", ..)) -> message
    Ok(Line(message:, error:, ..)) -> message <> ": " <> error
    Error(Nil) -> ""
  }
}

fn line_decoder() -> decode.Decoder(Line) {
  use level <- decode.field("level", decode.string)
  use message <- decode.optional_field("msg", "", decode.string)
  use error <- decode.optional_field("error", "", decode.string)
  decode.success(Line(level:, message:, error:))
}
