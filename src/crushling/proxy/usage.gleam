//// Pulls Hyper's `usage` out of a response as it passes through, without
//// holding any of it back.
////
//// Hyper speaks OpenAI chat completions. A streamed response is SSE with
//// one `data: {chunk}` per event and a final usage chunk (crush sets
//// `stream_options.include_usage`; without it Hyper puts usage on the
//// finish chunk instead), then `data: [DONE]`. A plain response is one JSON
//// object. Either way the block looks like
////
////     "usage": {"prompt_tokens": 9, "completion_tokens": 2,
////               "total_tokens": 11, "cost": {"usd": 0.0001, ...}}
////
//// Anthropic-style `input_tokens`/`output_tokens` are understood too.

import crushling/proxy/meter.{type Usage, Usage}
import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Plain bodies longer than this are passed through but not metered.
const max_json = 16_000_000

pub opaque type Scanner {
  Sse(partial: BitArray, found: Option(Usage))
  Json(body: BitArray, size: Int)
  Other
}

/// A scanner for a response with this content type.
pub fn new(content_type: String) -> Scanner {
  let content_type = string.lowercase(content_type)
  case
    string.contains(content_type, "text/event-stream"),
    string.contains(content_type, "json")
  {
    True, _ -> Sse(<<>>, None)
    _, True -> Json(<<>>, 0)
    _, _ -> Other
  }
}

/// Look at the next piece of the body.
pub fn feed(scanner: Scanner, data: BitArray) -> Scanner {
  case scanner {
    Other -> Other
    Json(body, size) -> {
      let size = size + bit_array.byte_size(data)
      case size > max_json {
        True -> Other
        False -> Json(bit_array.append(body, data), size)
      }
    }
    Sse(partial, found) -> {
      let #(lines, rest) = split_lines(bit_array.append(partial, data))
      let found =
        list.fold(lines, found, fn(found, line) {
          case line_usage(line) {
            Some(usage) -> Some(usage)
            None -> found
          }
        })
      Sse(rest, found)
    }
  }
}

/// The usage reported by the whole body, once it has all been fed.
pub fn finish(scanner: Scanner) -> Option(Usage) {
  case scanner {
    Other -> None
    Json(body, _) ->
      case bit_array.to_string(body) {
        Ok(text) -> parse_usage(text)
        Error(Nil) -> None
      }
    Sse(partial, found) ->
      case line_usage(partial) {
        Some(usage) -> Some(usage)
        None -> found
      }
  }
}

/// Complete lines, and whatever follows the last newline. Works on bytes,
/// since a chunk may end inside a multibyte character.
@external(erlang, "crushling_proxy_ffi", "split_lines")
fn split_lines(data: BitArray) -> #(List(BitArray), BitArray)

fn line_usage(line: BitArray) -> Option(Usage) {
  case bit_array.to_string(line) {
    Error(Nil) -> None
    Ok(line) ->
      case string.trim(line) {
        "data:" <> payload ->
          case string.contains(payload, "\"usage\"") {
            True -> parse_usage(string.trim(payload))
            False -> None
          }
        _ -> None
      }
  }
}

/// The `usage` block of one JSON object, if it has one.
pub fn parse_usage(text: String) -> Option(Usage) {
  let count = fn(names: List(String)) {
    decode.one_of(
      decode.at([list.first(names) |> unwrap_name], decode.int),
      list.map(list.drop(names, 1), fn(name) { decode.at([name], decode.int) }),
    )
    |> decode.optional
    |> decode.map(option.unwrap(_, 0))
  }
  let number =
    decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
  let usage = {
    use input <- decode.then(count(["prompt_tokens", "input_tokens"]))
    use output <- decode.then(count(["completion_tokens", "output_tokens"]))
    use cost <- decode.optional_field(
      "cost",
      0.0,
      decode.optional_field("usd", 0.0, number, decode.success),
    )
    decode.success(Usage(input, output, cost, 1))
  }
  let decoder = {
    use usage <- decode.optional_field("usage", None, decode.optional(usage))
    decode.success(usage)
  }
  case json.parse(text, decoder) {
    Ok(found) -> found
    Error(_) -> None
  }
}

fn unwrap_name(name: Result(String, Nil)) -> String {
  case name {
    Ok(name) -> name
    Error(Nil) -> ""
  }
}
