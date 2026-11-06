import crushling/diff
import gleam/int
import gleam/list
import gleam/string

fn apply(edits: List(diff.Edit)) -> #(List(String), List(String)) {
  let old =
    list.filter_map(edits, fn(e) {
      case e {
        diff.Insert(_) -> Error(Nil)
        diff.Keep(l) | diff.Delete(l) -> Ok(l)
      }
    })
  let new =
    list.filter_map(edits, fn(e) {
      case e {
        diff.Delete(_) -> Error(Nil)
        diff.Keep(l) | diff.Insert(l) -> Ok(l)
      }
    })
  #(old, new)
}

pub fn edits_reconstruct_both_sides_test() {
  let cases = [
    #([], []),
    #(["a"], []),
    #([], ["a"]),
    #(["a", "b", "c"], ["a", "b", "c"]),
    #(["a", "b", "c", "a", "b", "b", "a"], ["c", "b", "a", "b", "a", "c"]),
    #(["x", "y"], ["y", "x"]),
    #(["1", "2", "3", "4", "5"], ["0", "1", "3", "5", "6"]),
  ]
  list.each(cases, fn(pair) {
    let #(old, new) = pair
    let assert True = apply(diff.edits(old, new)) == #(old, new)
  })
}

pub fn edits_are_minimal_test() {
  let edits =
    diff.edits(["a", "b", "c", "a", "b", "b", "a"], [
      "c", "b", "a", "b", "a", "c",
    ])
  let changes =
    list.count(edits, fn(e) {
      case e {
        diff.Keep(_) -> False
        _ -> True
      }
    })
  let assert 5 = changes
}

pub fn lines_test() {
  let assert [] = diff.lines("")
  let assert ["a", "b"] = diff.lines("a\nb\n")
  let assert ["a", "b"] = diff.lines("a\nb")
  let assert ["a", ""] = diff.lines("a\n\n")
}

pub fn unified_single_change_test() {
  let old = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n"
  let new = "one\ntwo\nthree\nfour\nFIVE\nsix\nseven\neight\n"
  let assert "--- a/f.txt\n+++ b/f.txt\n@@ -2,7 +2,7 @@\n two\n three\n four\n-five\n+FIVE\n six\n seven\n eight\n" =
    diff.unified("f.txt", old, new)
}

pub fn unified_new_file_test() {
  let assert "--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1,2 @@\n+a\n+b\n" =
    diff.unified("n.txt", "", "a\nb\n")
}

pub fn unified_no_change_test() {
  let assert "" = diff.unified("f", "a\nb\n", "a\nb\n")
}

pub fn unified_separate_hunks_test() {
  let old =
    int.range(from: 20, to: 0, with: [], run: fn(acc, i) {
      ["l" <> int.to_string(i), ..acc]
    })
  let new =
    list.map(old, fn(l) {
      case l {
        "l2" -> "L2"
        "l19" -> "L19"
        other -> other
      }
    })
  let out =
    diff.unified(
      "f",
      string.join(old, "\n") <> "\n",
      string.join(new, "\n") <> "\n",
    )
  let assert 2 = list.length(string.split(out, "@@ -")) - 1
  let assert True = string.contains(out, "@@ -1,5 +1,5 @@\n l1\n-l2\n+L2\n")
  let assert True = string.contains(out, "@@ -16,5 +16,5 @@\n")
}
