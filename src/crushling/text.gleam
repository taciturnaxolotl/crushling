//// Cutting text down to fit a line, a title or a code span.

import gleam/string

/// `text` trimmed, and cut to `limit` characters with an ellipsis when it is
/// longer.
pub fn clip(text: String, limit: Int) -> String {
  let text = string.trim(text)
  case string.length(text) > limit {
    True -> string.slice(text, 0, limit - 1) <> "…"
    False -> text
  }
}
