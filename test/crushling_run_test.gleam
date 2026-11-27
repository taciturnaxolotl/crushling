import crushling/crush/event
import crushling/render
import crushling/run
import crushling/snapshot
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

fn done(text: String, error: String, cancelled: Bool) {
  event.RunCompleteEvent(event.RunComplete("s1", "r1", text, error, cancelled))
}

fn feed(events: List(event.Event)) -> run.Run {
  list.fold(events, run.new("s1", "r1"), run.apply)
}

pub fn text_accumulates_across_messages_test() {
  let r =
    feed([
      assistant("m1", "Look", []),
      assistant("m1", "Looking at it.", []),
      assistant("m2", "Fixed.", []),
      assistant("m1", "Looking at it.", []),
    ])
  // While the run goes, the latest message waits: it may be narration.
  let assert "Looking at it." = run.text(r)
  let r = run.apply(r, done("Fixed.", "", False))
  let assert "Looking at it.\n\nFixed." = run.text(r)
}

/// What the agent says while it calls tools is its status, not its reply.
pub fn narration_is_status_not_reply_test() {
  let call = event.ToolCall("c1", "bash", "{\"command\":\"ls\"}")
  let r =
    feed([
      assistant("m1", "Building crush from source first.", [call]),
      tool_result("c1", False),
    ])
  let assert "Building crush from source first." = run.narration(r)
  let assert "Building crush from source first." = render.progress_title(r)
  let assert "" = run.text(r)
  let r =
    run.apply(
      r,
      assistant(
        "m2",
        "Crush starts in 2s; most of it waits on the network.",
        [],
      ),
    )
  // Not shown until the run ends: a tool call could still follow.
  let assert "" = run.text(r)
  let r = run.apply(r, done("", "", False))
  let assert "Crush starts in 2s; most of it waits on the network." =
    run.text(r)
  let assert "" = run.narration(r)
  let assert True = string.starts_with(render.progress_title(r), "Done")
}

pub fn other_sessions_and_runs_ignored_test() {
  let foreign =
    event.MessageEvent(
      "updated",
      event.Message("x", "s2", event.Assistant, "nope", [], [], []),
    )
  let other_run =
    event.RunCompleteEvent(event.RunComplete("s1", "r0", "", "", False))
  let r = feed([foreign, other_run])
  let assert "" = run.text(r)
  let assert False = run.is_done(r)
}

pub fn tools_track_status_test() {
  let call = event.ToolCall("c1", "bash", "{\"command\":\"go test ./...\"}")
  let call2 =
    event.ToolCall("c2", "view", "{\"file_path\":\"/workspace/a.go\"}")
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

pub fn plan_render_test() {
  let calls =
    list.map(["1", "2"], fn(i) {
      event.ToolCall("c" <> i, "bash", "{\"command\":\"step " <> i <> "\"}")
    })
  let edit =
    event.ToolCall("c3", "edit", "{\"file_path\":\"/workspace/src/a.go\"}")
  let r =
    feed([
      assistant("m1", "Working on it.", list.append(calls, [edit])),
      tool_result("c1", False),
      tool_result("c3", False),
    ])
  // Its narration is the card's title.
  let assert Some(render.Plan("Working on it.", [one, two, three])) =
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

  let completed = run.apply(r, done("Working on it.", "", False))
  let assert Some(render.Plan("Done · 3 steps", [_, two, _])) =
    render.plan(completed, "/workspace")
  let assert render.Task(status: render.Complete, ..) = two
  let failed = run.apply(r, done("", "boom", False))
  let assert Some(render.Plan(
    "Failed · 3 steps",
    [_, render.Task(status: render.Failed, ..), _],
  )) = render.plan(failed, "/workspace")
}

pub fn streamed_text_test() {
  // Crush sends the same message again as it grows; the view keeps one
  // entry per message, in order, trimmed and without empties.
  let r =
    feed([
      assistant("m1", "Look", []),
      assistant("m1", "Looking at it.", []),
      assistant("m2", "  ", []),
      assistant("m3", "Fixed.", []),
    ])
  let assert [#("m1", "Looking at it."), #("m3", "Fixed.")] =
    run.messages(r, True)
  // The latest message is the status until the run ends.
  let assert "Fixed." = render.progress_title(r)
  let assert "Looking at it." = render.reply(r)
  let r = run.apply(r, done("", "", False))
  let assert "Looking at it.\n\nFixed." = render.reply(r)
  let assert ["Looking at it.\n\nFixed."] = render.answer(r)
}

pub fn done_title_test() {
  let r =
    feed([
      assistant("m1", "On it.", []),
      event.MessageEvent(
        "created",
        event.Message(
          "t1",
          "s1",
          event.Tool,
          "",
          [],
          [event.ToolResult("c1", "bash", "out", False)],
          [],
        ),
      ),
    ])
  let assert "On it." = render.progress_title(r)
  let assert "Working" = render.progress_title(feed([]))
  let assert "Done · 0 steps" =
    render.progress_title(run.apply(r, done("On it.", "", False)))
  let assert "Stopped · 0 steps" =
    render.progress_title(run.apply(r, done("", "", True)))
}

pub fn a_failure_worked_around_is_not_a_badge_test() {
  let call = event.ToolCall("c1", "bash", "{\"command\":\"false\"}")
  let r = feed([assistant("m1", "On it.", [call]), tool_result("c1", True)])
  // While it runs, a failed command is shown as one.
  let assert Some(render.Plan(_, [render.Task(status: render.Failed, ..)])) =
    render.plan(r, "/w")
  // The agent carried on and finished, so the card doesn't keep Slack's
  // warning badge for the whole run.
  let finished = run.apply(r, done("On it.", "", False))
  let assert Some(render.Plan(
    "Done · 1 step",
    [render.Task(status: render.Complete, ..)],
  )) = render.plan(finished, "/w")
  // A run that ends badly still says so, and so does one the user stopped:
  // the failure is the thing to look at.
  let failed = run.apply(r, done("", "boom", False))
  let assert Some(render.Plan(_, [render.Task(status: render.Failed, ..)])) =
    render.plan(failed, "/w")
  let stopped = run.apply(r, done("", "", True))
  let assert Some(render.Plan(_, [render.Task(status: render.Failed, ..)])) =
    render.plan(stopped, "/w")
}

pub fn plan_folds_many_steps_test() {
  let calls =
    int.range(from: 50, to: 0, with: [], run: fn(acc, i) {
      [event.ToolCall("c" <> int.to_string(i), "ls", "{}"), ..acc]
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
  // Whoever stopped a run knows; it gets no note.
  let assert None = render.note(feed([done("", "", True)]), True)
  let assert Some(limited) =
    render.note(feed([done("", "429 rate_limit_error", False)]), False)
  let assert True =
    string.starts_with(limited, "_The model provider rate-limited the request.")
  let partial =
    render.note(
      feed([assistant("m", "half", []), done("", "boom", False)]),
      True,
    )
  let assert Some(text) = partial
  let assert True = string.contains(text, "may be partial")
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
  let cause = fn(reason) { render.explain(reason).cause }
  let assert "The conversation exceeded the model's context window" =
    cause(
      "bad request: 400 {\"message\":\"prompt is too long: 241668 tokens > 200000 maximum\"}",
    )
  let assert "The model provider rejected crushling's API key" =
    cause("unauthorized: authentication failed")
  // Operator fixes go to whoever runs crushling, not the thread.
  let assert False =
    string.contains(render.explain("401 invalid api key").advice, "CRUSHLING_")
  // No Claude login or version advice is left.
  let assert "The run failed with an unrecognized error" =
    cause("claude_code_version_too_old")
  let assert "The model provider rate-limited the request" =
    cause("429 Too Many Requests: rate_limit_error")
  let assert "The model provider returned a server error" =
    cause("529 overloaded_error")
  let assert "The model provider rejected the request as invalid" =
    cause(
      "bad request: 400 max_tokens: 128000 > 64000, which is the maximum allowed",
    )
  let assert "The connection to the agent dropped mid-run" =
    cause("lost the connection mid-run")
  let assert "The run failed with an unrecognized error" = cause("boom")
}

pub fn explain_matches_statuses_as_whole_words_test() {
  let cause = fn(reason) { render.explain(reason).cause }
  // A number that merely contains 401 or 500 is no status.
  let assert "The run failed with an unrecognized error" =
    cause("used 140123 tokens, 25001 cached")
  let assert "The model provider rejected crushling's API key" =
    cause("status 401")
  let assert "The model provider returned a server error" =
    cause("upstream said 502")
  // "eof" counts only as a word.
  let assert "The run failed with an unrecognized error" =
    cause("the cause thereof is unclear")
  let assert "The connection to the model provider dropped" =
    cause("unexpected EOF")
}

pub fn explain_prefers_phrases_to_statuses_test() {
  let cause = fn(reason) { render.explain(reason).cause }
  let assert "The model provider account is out of credits" =
    cause("400 Bad Request: your credit balance is too low")
  let assert "The model provider rate-limited the request" =
    cause("400 rate_limit_error")
  // "credit" alone is not a billing problem.
  let assert "The model provider rejected the request as invalid" =
    cause("400 bad request: field credit_note is unknown")
}

pub fn notes_quote_only_errors_worth_reading_test() {
  let assert Some(limited) =
    render.note(feed([done("", "429 rate_limit_error", False)]), False)
  let assert False = string.contains(limited, "\n>")
  let assert Some(odd) = render.note(feed([done("", "boom", False)]), False)
  let assert True = string.ends_with(odd, "\n> `boom`")
  // "Send a follow-up" is said once, at the end.
  let assert True =
    limited
    == "_The model provider rate-limited the request. Wait a minute. Send a follow-up to try again._"
  let assert Some(long) =
    render.note(feed([done("", "prompt is too long", False)]), False)
  let assert False = string.contains(long, "follow-up")
}

pub fn tool_running_test() {
  let call = event.ToolCall("c1", "bash", "{\"command\":\"sleep 900\"}")
  let r = feed([assistant("m1", "Waiting on it.", [call])])
  let assert True = run.tool_running(r)
  let r = run.apply(r, tool_result("c1", False))
  let assert False = run.tool_running(r)
}
