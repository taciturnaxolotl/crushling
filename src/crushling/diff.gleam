//// Unified line diffs, computed in-process with Myers' algorithm.
////
//// The bridge builds diffs from the file versions in the event stream rather
//// than running `git diff` against the workspace, because git on the host
//// would honour repo-controlled config such as fsmonitor or diff drivers.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/string

pub type Edit {
  Keep(String)
  Delete(String)
  Insert(String)
}

/// Above this many differences the diff gives up and reports the file as
/// replaced, which keeps a pathological pair of files from stalling an actor.
const max_distance = 4000

type Lines

@external(erlang, "erlang", "list_to_tuple")
fn to_lines(lines: List(String)) -> Lines

@external(erlang, "crushling_ffi", "line_at")
fn line_at(lines: Lines, index: Int) -> String

pub fn lines(content: String) -> List(String) {
  case content {
    "" -> []
    _ -> {
      let parts = string.split(content, "\n")
      case string.ends_with(content, "\n") {
        True -> list.take(parts, list.length(parts) - 1)
        False -> parts
      }
    }
  }
}

pub fn edits(old: List(String), new: List(String)) -> List(Edit) {
  let n = list.length(old)
  let m = list.length(new)
  let a = to_lines(old)
  let b = to_lines(new)
  case forward(a, b, n, m, 0, dict.from_list([#(1, 0)]), []) {
    Ok(trace) -> backtrack(a, b, n, m, trace, list.length(trace) - 1, [])
    Error(Nil) -> list.append(list.map(old, Delete), list.map(new, Insert))
  }
}

fn get(v: Dict(Int, Int), k: Int) -> Int {
  case dict.get(v, k) {
    Ok(x) -> x
    Error(Nil) -> 0
  }
}

/// Returns the V snapshots taken at the start of each round, newest first, ready for backtracking.
fn forward(
  a: Lines,
  b: Lines,
  n: Int,
  m: Int,
  d: Int,
  v: Dict(Int, Int),
  trace: List(Dict(Int, Int)),
) -> Result(List(Dict(Int, Int)), Nil) {
  case d > n + m || d > max_distance {
    True -> Error(Nil)
    False -> {
      let trace = [v, ..trace]
      case round(a, b, n, m, d, -d, v) {
        Ok(Nil) -> Ok(trace)
        Error(v) -> forward(a, b, n, m, d + 1, v, trace)
      }
    }
  }
}

/// Ok when the end was reached, otherwise the updated V for the next round.
fn round(
  a: Lines,
  b: Lines,
  n: Int,
  m: Int,
  d: Int,
  k: Int,
  v: Dict(Int, Int),
) -> Result(Nil, Dict(Int, Int)) {
  case k > d {
    True -> Error(v)
    False -> {
      let x = case k == -d || { k != d && get(v, k - 1) < get(v, k + 1) } {
        True -> get(v, k + 1)
        False -> get(v, k - 1) + 1
      }
      let x = snake(a, b, n, m, x, x - k)
      let v = dict.insert(v, k, x)
      case x >= n && x - k >= m {
        True -> Ok(Nil)
        False -> round(a, b, n, m, d, k + 2, v)
      }
    }
  }
}

fn snake(a: Lines, b: Lines, n: Int, m: Int, x: Int, y: Int) -> Int {
  case x < n && y < m && line_at(a, x) == line_at(b, y) {
    True -> snake(a, b, n, m, x + 1, y + 1)
    False -> x
  }
}

fn backtrack(
  a: Lines,
  b: Lines,
  x: Int,
  y: Int,
  trace: List(Dict(Int, Int)),
  d: Int,
  acc: List(Edit),
) -> List(Edit) {
  case trace {
    [] -> acc
    [v, ..rest] -> {
      let k = x - y
      let prev_k = case k == -d || { k != d && get(v, k - 1) < get(v, k + 1) } {
        True -> k + 1
        False -> k - 1
      }
      let prev_x = get(v, prev_k)
      let prev_y = prev_x - prev_k
      let #(x, y, acc) = diagonal(a, x, y, prev_x, prev_y, acc)
      let acc = case d > 0 {
        False -> acc
        True ->
          case x == prev_x {
            True -> [Insert(line_at(b, y - 1)), ..acc]
            False -> [Delete(line_at(a, x - 1)), ..acc]
          }
      }
      backtrack(a, b, prev_x, prev_y, rest, d - 1, acc)
    }
  }
}

fn diagonal(
  a: Lines,
  x: Int,
  y: Int,
  prev_x: Int,
  prev_y: Int,
  acc: List(Edit),
) -> #(Int, Int, List(Edit)) {
  case x > prev_x && y > prev_y {
    True ->
      diagonal(a, x - 1, y - 1, prev_x, prev_y, [Keep(line_at(a, x - 1)), ..acc])
    False -> #(x, y, acc)
  }
}

type Numbered {
  Numbered(edit: Edit, old: Int, new: Int)
}

/// A unified diff with three lines of context, or "" when nothing changed.
pub fn unified(path: String, old: String, new: String) -> String {
  let old_lines = lines(old)
  let header = case old {
    "" -> "--- /dev/null\n+++ b/" <> path <> "\n"
    _ -> "--- a/" <> path <> "\n+++ b/" <> path <> "\n"
  }
  let numbered = number(edits(old_lines, lines(new)), 1, 1, [])
  case hunks(numbered, 3) {
    [] -> ""
    found -> header <> string.join(list.map(found, render_hunk), "")
  }
}

fn number(edits: List(Edit), old: Int, new: Int, acc: List(Numbered)) {
  case edits {
    [] -> list.reverse(acc)
    [edit, ..rest] -> {
      let item = Numbered(edit, old, new)
      case edit {
        Keep(_) -> number(rest, old + 1, new + 1, [item, ..acc])
        Delete(_) -> number(rest, old + 1, new, [item, ..acc])
        Insert(_) -> number(rest, old, new + 1, [item, ..acc])
      }
    }
  }
}

fn is_change(item: Numbered) -> Bool {
  case item.edit {
    Keep(_) -> False
    _ -> True
  }
}

/// Split into runs of edits where every change has `context` lines around it
/// and changes closer than twice the context share a hunk.
fn hunks(items: List(Numbered), context: Int) -> List(List(Numbered)) {
  let indexed = list.index_map(items, fn(item, i) { #(i, item) })
  let changes =
    list.filter_map(indexed, fn(pair) {
      case is_change(pair.1) {
        True -> Ok(pair.0)
        False -> Error(Nil)
      }
    })
  let last = list.length(items) - 1
  let ranges =
    list.fold(changes, [], fn(ranges, i) {
      let start = int.max(0, i - context)
      let stop = int.min(last, i + context)
      case ranges {
        [#(s, e), ..rest] if start <= e + 1 -> [#(s, int.max(e, stop)), ..rest]
        _ -> [#(start, stop), ..ranges]
      }
    })
    |> list.reverse
  list.map(ranges, fn(range) {
    indexed
    |> list.filter(fn(pair) { pair.0 >= range.0 && pair.0 <= range.1 })
    |> list.map(fn(pair) { pair.1 })
  })
}

fn render_hunk(hunk: List(Numbered)) -> String {
  let assert [first, ..] = hunk
  let old_count =
    list.count(hunk, fn(item) {
      case item.edit {
        Insert(_) -> False
        _ -> True
      }
    })
  let new_count =
    list.count(hunk, fn(item) {
      case item.edit {
        Delete(_) -> False
        _ -> True
      }
    })
  let start = fn(line, count) {
    case count {
      0 -> line - 1
      _ -> line
    }
  }
  let header =
    "@@ -"
    <> int.to_string(start(first.old, old_count))
    <> ","
    <> int.to_string(old_count)
    <> " +"
    <> int.to_string(start(first.new, new_count))
    <> ","
    <> int.to_string(new_count)
    <> " @@\n"
  header
  <> string.concat(
    list.map(hunk, fn(item) {
      case item.edit {
        Keep(line) -> " " <> line <> "\n"
        Delete(line) -> "-" <> line <> "\n"
        Insert(line) -> "+" <> line <> "\n"
      }
    }),
  )
}
