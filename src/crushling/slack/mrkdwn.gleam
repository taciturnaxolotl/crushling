//// Markdown as the agent writes it, turned into Slack's older mrkdwn, for
//// the places that only take mrkdwn: sections, and what goes in a
//// container. Code is left alone; headings become bold lines, `**bold**`
//// single stars, list markers bullets, and `[text](url)` Slack links.

import gleam/list
import gleam/string

pub fn from_markdown(markdown: String) -> String {
  string.split(markdown, "\n")
  |> list.map_fold(False, fn(in_code, line) {
    case string.starts_with(string.trim_start(line), "```") {
      True -> #(!in_code, line)
      False ->
        case in_code {
          True -> #(in_code, line)
          False -> #(in_code, convert_line(line))
        }
    }
  })
  |> fn(pair) { pair.1 }
  |> string.join("\n")
}

fn convert_line(line: String) -> String {
  let trimmed = string.trim_start(line)
  let indent = string.drop_end(line, string.length(trimmed))
  case heading(trimmed) {
    Ok(title) -> "*" <> string.replace(inline(title), "*", "") <> "*"
    Error(Nil) ->
      case trimmed {
        "- " <> rest | "* " <> rest -> indent <> "• " <> inline(rest)
        _ -> indent <> inline(trimmed)
      }
  }
}

fn heading(line: String) -> Result(String, Nil) {
  case line {
    "#" <> rest ->
      case string.trim_start(string.drop_start(rest, count_hashes(rest))) {
        "" -> Error(Nil)
        title ->
          case
            string.starts_with(string.drop_start(rest, count_hashes(rest)), " ")
          {
            True -> Ok(title)
            False -> Error(Nil)
          }
      }
    _ -> Error(Nil)
  }
}

fn count_hashes(text: String) -> Int {
  case text {
    "#" <> rest -> 1 + count_hashes(rest)
    _ -> 0
  }
}

/// Bold and links in one line, outside inline code.
fn inline(line: String) -> String {
  string.split(line, "`")
  |> list.index_map(fn(part, i) {
    case i % 2 {
      0 -> links(string.replace(part, "**", "*"))
      _ -> part
    }
  })
  |> string.join("`")
}

/// `[text](url)` as `<url|text>`.
fn links(text: String) -> String {
  case string.split_once(text, "[") {
    Error(Nil) -> text
    Ok(#(before, rest)) ->
      case string.split_once(rest, "](") {
        Error(Nil) -> before <> "[" <> links(rest)
        Ok(#(label, after)) ->
          case string.split_once(after, ")") {
            Ok(#(url, tail)) if url != "" ->
              case string.contains(url, " ") || string.contains(label, "]") {
                True -> before <> "[" <> links(rest)
                False ->
                  before <> "<" <> url <> "|" <> label <> ">" <> links(tail)
              }
            _ -> before <> "[" <> links(rest)
          }
      }
  }
}
