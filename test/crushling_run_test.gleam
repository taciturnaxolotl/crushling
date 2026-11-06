import crushling/crush/event
import crushling/render
import crushling/run
import crushling/snapshot
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn assistant(id: String, text: String, calls: List(event.ToolCall)) {
  event.MessageEvent(
    "updated",
    event.Message(id, "s1", event.Assistant, text, calls, [], []),
  )
}

fn tool_result(call_id: String, is_error: Bool) {
  event.MessageEvent(
    "created",
    event.Message(
      "t" <> call_id,
      "s1",
      event.Tool,
      "",
      [],
      [event.ToolResult(call_id, "bash", "out", is_error)],
      [],
    ),
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
      event.Message("x", "s2", event.Assistant, "nope", [], [], []),
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
    run.Tool("c1", "bash", _, "go test ./...", "", run.Succeeded, "out"),
    run.Tool("c2", "view", _, "/workspace/a.go", "", run.Failed, "out"),
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

pub fn plan_render_test() {
  let calls =
    list.map(["1", "2"], fn(i) {
      event.ToolCall(
        "c" <> i,
        "bash",
        "{\"command\":\"step " <> i <> "\"}",
        True,
      )
    })
  let edit =
    event.ToolCall(
      "c3",
      "edit",
      "{\"file_path\":\"/workspace/src/a.go\"}",
      True,
    )
  let r =
    feed([
      assistant("m1", "Working on it.", list.append(calls, [edit])),
      tool_result("c1", False),
      tool_result("c3", False),
    ])
  let assert Some(render.Plan("Working", [one, two, three])) =
    render.plan(r, "/workspace")
  // Successful output stays out of the card.
  let assert render.Task(
    "c1",
    "Running a command",
    render.Complete,
    "step 1",
    "",
  ) = one
  let assert render.Task(status: render.InProgress, output: "", ..) = two
  // File tools don't echo their boilerplate result, and paths are relative.
  let assert render.Task(
    "c3",
    "Editing a file",
    render.Complete,
    "src/a.go",
    "",
  ) = three
  let assert None = render.plan(feed([assistant("m", "hi", [])]), "/w")

  let completed = run.apply(r, dict.new(), done("Working on it.", "", False))
  let assert Some(render.Plan("Done · 3 steps", [_, two, _])) =
    render.plan(completed, "/workspace")
  let assert render.Task(status: render.Complete, ..) = two
  let failed = run.apply(r, dict.new(), done("", "boom", False))
  let assert Some(render.Plan(
    "Failed · 3 steps",
    [_, render.Task(status: render.Failed, ..), _],
  )) = render.plan(failed, "/workspace")
}

pub fn plan_folds_many_steps_test() {
  let calls =
    int.range(from: 50, to: 0, with: [], run: fn(acc, i) {
      [event.ToolCall("c" <> int.to_string(i), "ls", "{}", True), ..acc]
    })
  let assert Some(render.Plan(_, tasks)) =
    render.plan(feed([assistant("m", "", calls)]), "/w")
  let assert 40 = list.length(tasks)
  let assert [render.Task("earlier", _, _, _, "11 earlier steps"), ..] = tasks
}

pub fn descriptions_test() {
  let call =
    event.ToolCall(
      "c1",
      "bash",
      "{\"command\":\"go test ./...\",\"description\":\"Run the tests\"}",
      True,
    )
  let r = feed([assistant("m1", "", [call])])
  let assert [tool] = r.tools
  let assert "Run the tests" = tool.description
  let assert Some(render.Plan(
    _,
    [render.Task(title: "Run the tests", details: "", ..)],
  )) = render.plan(r, "/w")
}

pub fn titles_test() {
  let assert "Reading a file" = render.title("view")
  let assert "Asking the language server" = render.title("lsp_definition")
  let assert "Linear save issue" = render.title("mcp_linear_save_issue")
  let assert "Some new tool" = render.title("some_new_tool")
}

pub fn answer_and_note_test() {
  let assert ["All done."] =
    render.answer(
      feed([assistant("m1", "All done.", []), done("x", "", False)]),
    )
  let assert ["fallback"] = render.answer(feed([done("fallback", "", False)]))
  let assert [] = render.answer(feed([done("", "", False)]))

  let assert Some("_no reply._") =
    render.note(feed([done("", "", False)]), False)
  let assert None = render.note(feed([done("hi", "", False)]), True)
  let assert Some("_stopped._") = render.note(feed([done("", "", True)]), True)
  let assert Some(limited) =
    render.note(feed([done("", "429 rate_limit_error", False)]), False)
  let assert True =
    string.starts_with(limited, "_The model provider is rate limiting us.")
  let assert True = string.ends_with(limited, "> `429 rate_limit_error`")
  let partial =
    render.note(
      feed([assistant("m", "half", []), done("", "boom", False)]),
      True,
    )
  let assert Some(text) = partial
  let assert True = string.contains(text, "may be partial")
}

pub fn changes_line_test() {
  let assert None = render.changes([])
  let assert Some("_changed `a.go` +3 −1, `bin/x` (binary)_") =
    render.changes([
      snapshot.Change("a.go", Ok(3), Ok(1)),
      snapshot.Change("bin/x", Error(Nil), Error(Nil)),
    ])
}

pub fn numstat_test() {
  let assert [
    snapshot.Change("a.go", Ok(3), Ok(1)),
    snapshot.Change("bin/x", Error(Nil), Error(Nil)),
    snapshot.Change("tab\tname", Ok(1), Ok(0)),
  ] = snapshot.parse_numstat("3\t1\ta.go\n-\t-\tbin/x\n1\t0\ttab\tname\n")
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

pub fn explain_test() {
  let cause = fn(reason) { render.explain(reason).0 }
  let assert "The conversation got too long for the model" =
    cause(
      "bad request: 400 {\"message\":\"prompt is too long: 241668 tokens > 200000 maximum\"}",
    )
  let assert "The model provider rejected crushling's login" =
    cause("unauthorized: authentication failed")
  let assert "The model provider is rate limiting us" =
    cause("429 Too Many Requests: rate_limit_error")
  let assert "The model provider is having trouble" =
    cause("529 overloaded_error")
  let assert "The model provider refused the request" =
    cause(
      "bad request: 400 max_tokens: 128000 > 64000, which is the maximum allowed",
    )
  let assert "Lost touch with the agent partway through" =
    cause("lost the connection mid-run")
  let assert "Something went wrong" = cause("boom")
}
