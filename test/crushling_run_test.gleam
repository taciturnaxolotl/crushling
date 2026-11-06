import crushling/crush/event
import crushling/render
import crushling/run
import gleam/dict
import gleam/list
import gleam/option.{Some}
import gleam/string

fn assistant(id: String, text: String, calls: List(event.ToolCall)) {
  event.MessageEvent(
    "updated",
    event.Message(id, "s1", event.Assistant, text, calls, []),
  )
}

fn tool_result(call_id: String, is_error: Bool) {
  event.MessageEvent(
    "created",
    event.Message("t" <> call_id, "s1", event.Tool, "", [], [
      event.ToolResult(call_id, "bash", "out", is_error),
    ]),
  )
}

fn file(path: String, content: String, version: Int) {
  event.FileEvent(event.FileVersion("s1", path, content, version))
}

fn done(text: String, error: String, cancelled: Bool) {
  event.RunCompleteEvent(event.RunComplete(
    "s1",
    "r1",
    "m",
    text,
    error,
    cancelled,
  ))
}

fn feed(events: List(event.Event)) -> run.Run {
  feed_known(dict.new(), events)
}

fn feed_known(known: run.Known, events: List(event.Event)) -> run.Run {
  list.fold(events, run.new("s1", "r1"), fn(r, e) { run.apply(r, known, e) })
}

pub fn text_accumulates_across_messages_test() {
  let r =
    feed([
      assistant("m1", "Look", []),
      assistant("m1", "Looking at it.", []),
      assistant("m2", "Fixed.", []),
      assistant("m1", "Looking at it.", []),
    ])
  let assert "Looking at it.\n\nFixed." = run.text(r)
}

pub fn other_sessions_and_runs_ignored_test() {
  let foreign =
    event.MessageEvent(
      "updated",
      event.Message("x", "s2", event.Assistant, "nope", [], []),
    )
  let other_run =
    event.RunCompleteEvent(event.RunComplete("s1", "r0", "m", "", "", False))
  let r = feed([foreign, other_run])
  let assert "" = run.text(r)
  let assert False = run.is_done(r)
}

pub fn tools_track_status_test() {
  let call =
    event.ToolCall("c1", "bash", "{\"command\":\"go test ./...\"}", True)
  let call2 =
    event.ToolCall("c2", "view", "{\"file_path\":\"/workspace/a.go\"}", True)
  let r =
    feed([
      assistant("m1", "", [call]),
      tool_result("c1", False),
      assistant("m2", "", [call2]),
      tool_result("c2", True),
    ])
  let assert [
    run.Tool("c1", "bash", "go test ./...", run.Succeeded),
    run.Tool("c2", "view", "/workspace/a.go", run.Failed),
  ] = r.tools
}

pub fn summarize_input_test() {
  let assert "ls" = run.summarize_input("{\"command\":\"ls\",\"path\":\"x\"}")
  let assert "echo a …" =
    run.summarize_input("{\"command\":\"echo a\\necho b\"}")
  let assert "" = run.summarize_input("not json")
  let assert "" = run.summarize_input("{\"n\":1}")
  let long = string.repeat("x", 200)
  let assert 80 =
    string.length(run.summarize_input("{\"command\":\"" <> long <> "\"}"))
}

pub fn outcomes_test() {
  let assert Some(run.Completed("hi")) = feed([done("hi", "", False)]).outcome
  let assert Some(run.Errored("boom")) = feed([done("", "boom", False)]).outcome
  let assert Some(run.Cancelled) = feed([done("", "", True)]).outcome
}

pub fn file_changes_test() {
  let r =
    feed([
      file("/workspace/a.txt", "one\n", 0),
      file("/workspace/a.txt", "two\n", 1),
      file("/workspace/same.txt", "x\n", 0),
      file("/workspace/b.txt", "new\n", 3),
    ])
  let assert [
    run.Changed(
      "a.txt",
      "--- a/a.txt\n+++ b/a.txt\n@@ -1,1 +1,1 @@\n-one\n+two\n",
    ),
    run.Unknown("b.txt"),
  ] = run.changes(r, "/workspace")
}

pub fn known_baseline_carries_between_runs_test() {
  let first =
    feed([
      file("/workspace/a.txt", "one\n", 0),
      file("/workspace/a.txt", "two\n", 1),
    ])
  let known = run.remember(dict.new(), first)
  let second = feed_known(known, [file("/workspace/a.txt", "three\n", 2)])
  let assert [run.Changed("a.txt", _)] = run.changes(second, "/workspace")
  let assert True =
    string.contains(run.patch(second, "/workspace"), "-two\n+three\n")
}

pub fn progress_render_test() {
  let calls =
    list.map(["1", "2", "3", "4", "5"], fn(i) {
      event.ToolCall(
        "c" <> i,
        "bash",
        "{\"command\":\"step " <> i <> "\"}",
        True,
      )
    })
  let r =
    feed([assistant("m1", "Working on it.", calls), tool_result("c5", False)])
  let assert "Working on it.\n\n_2 earlier tool calls_\n> ▸ bash `step 3`\n> ▸ bash `step 4`\n> ✓ bash `step 5`" =
    render.progress(r, 1000)
  let assert "_thinking…_" = render.progress(feed([]), 1000)
}

pub fn progress_tail_reopens_fence_test() {
  let text = "intro\n```\n" <> string.repeat("code line\n", 50) <> "more"
  let r = feed([assistant("m1", text, [])])
  let out = render.progress(r, 120)
  let assert True = string.length(out) <= 120
  let assert True = string.starts_with(out, "…\n```\n")
}

pub fn final_render_test() {
  let r =
    feed([
      assistant("m1", "All done.", [event.ToolCall("c1", "edit", "{}", True)]),
      file("/workspace/a.txt", "one\n", 0),
      file("/workspace/a.txt", "two\n", 1),
      done("All done.", "", False),
    ])
  let assert ["All done.\n\n_1 tool call · changed `a.txt`_"] =
    render.final(r, ["a.txt"])
  let assert ["oops\n\n:warning: run failed: boom"] =
    render.final(
      feed([assistant("m", "oops", []), done("", "boom", False)]),
      [],
    )
  let assert ["_no reply_"] = render.final(feed([done("", "", False)]), [])
  let assert ["fallback"] =
    render.final(feed([done("fallback", "", False)]), [])
}

pub fn chunk_test() {
  let assert ["short"] = render.chunk("short", 100)
  let para = string.repeat("word ", 15)
  let text = para <> "\n\n" <> para <> "\n\n" <> para
  let chunks = render.chunk(text, 100)
  let assert True = list.all(chunks, fn(c) { string.length(c) <= 100 })
  let assert 3 = list.length(chunks)
}

pub fn chunk_keeps_fences_balanced_test() {
  let text = "```\n" <> string.repeat("let x = 1\n", 40) <> "```\nafter"
  let chunks = render.chunk(text, 120)
  let assert True = list.length(chunks) > 1
  list.each(chunks, fn(c) {
    let fences =
      string.split(c, "\n")
      |> list.count(fn(l) { string.starts_with(l, "```") })
    let assert 0 = fences % 2
    let assert True = string.length(c) <= 120
  })
}
