import crushling/crush/event

pub fn assistant_message_test() {
  let frame =
    "{\"type\":\"message\",\"payload\":{\"type\":\"updated\",\"payload\":{\"id\":\"m1\",\"role\":\"assistant\",\"session_id\":\"s1\",\"parts\":[{\"type\":\"reasoning\",\"data\":{\"thinking\":\"hm\"}},{\"type\":\"text\",\"data\":{\"text\":\"Hello \"}},{\"type\":\"text\",\"data\":{\"text\":\"secret\",\"hidden\":true}},{\"type\":\"text\",\"data\":{\"text\":\"world\"}},{\"type\":\"tool_call\",\"data\":{\"id\":\"c1\",\"name\":\"bash\",\"input\":\"{\\\"command\\\":\\\"ls\\\"}\",\"finished\":true}},{\"type\":\"finish\",\"data\":{\"reason\":\"tool_use\"}}]}}}"
  let assert Ok(event.MessageEvent(
    op: "updated",
    message: event.Message(
      id: "m1",
      session_id: "s1",
      role: event.Assistant,
      text: "Hello world",
      tool_calls: [event.ToolCall("c1", "bash", "{\"command\":\"ls\"}", True)],
      tool_results: [],
    ),
  )) = event.parse(frame)
}

pub fn tool_result_message_test() {
  let frame =
    "{\"type\":\"message\",\"payload\":{\"type\":\"created\",\"payload\":{\"id\":\"m2\",\"role\":\"tool\",\"session_id\":\"s1\",\"parts\":[{\"type\":\"tool_result\",\"data\":{\"tool_call_id\":\"c1\",\"name\":\"bash\",\"content\":\"README.md\",\"metadata\":\"{}\",\"is_error\":false}}]}}}"
  let assert Ok(event.MessageEvent(
    message: event.Message(role: event.Tool, tool_results: [result], ..),
    ..,
  )) = event.parse(frame)
  let assert event.ToolResult("c1", "bash", "README.md", False) = result
}

pub fn run_complete_test() {
  let frame =
    "{\"type\":\"run_complete\",\"payload\":{\"type\":\"created\",\"payload\":{\"session_id\":\"s1\",\"run_id\":\"r1\",\"message_id\":\"m1\",\"text\":\"done\",\"error\":\"\",\"cancelled\":false}}}"
  let assert Ok(event.RunCompleteEvent(event.RunComplete(
    "s1",
    "r1",
    "m1",
    "done",
    "",
    False,
  ))) = event.parse(frame)
}

pub fn run_complete_with_missing_fields_test() {
  let frame =
    "{\"type\":\"run_complete\",\"payload\":{\"type\":\"created\",\"payload\":{\"session_id\":\"s1\",\"cancelled\":true}}}"
  let assert Ok(event.RunCompleteEvent(event.RunComplete(
    session_id: "s1",
    run_id: "",
    cancelled: True,
    ..,
  ))) = event.parse(frame)
}

pub fn agent_error_test() {
  let frame =
    "{\"type\":\"agent_event\",\"payload\":{\"type\":\"created\",\"payload\":{\"type\":\"error\",\"session_id\":\"s1\",\"run_id\":\"r1\",\"error\":\"rate limited\"}}}"
  let assert Ok(event.AgentError("s1", "r1", "rate limited")) =
    event.parse(frame)
}

pub fn agent_other_test() {
  let frame =
    "{\"type\":\"agent_event\",\"payload\":{\"type\":\"created\",\"payload\":{\"type\":\"agent_finished\"}}}"
  let assert Ok(event.Other("agent_event:agent_finished")) = event.parse(frame)
}

pub fn file_test() {
  let frame =
    "{\"type\":\"file\",\"payload\":{\"type\":\"created\",\"payload\":{\"id\":\"f\",\"session_id\":\"s1\",\"path\":\"/workspace/a.go\",\"content\":\"package a\",\"version\":2}}}"
  let assert Ok(event.FileEvent(event.FileVersion(
    "s1",
    "/workspace/a.go",
    "package a",
    2,
  ))) = event.parse(frame)
}

pub fn unknown_kind_test() {
  let frame =
    "{\"type\":\"host_theme\",\"payload\":{\"type\":\"created\",\"payload\":{\"dark\":true}}}"
  let assert Ok(event.Other("host_theme")) = event.parse(frame)
}

pub fn null_op_test() {
  let frame = "{\"type\":\"client_session\",\"payload\":{\"type\":null}}"
  let assert Ok(event.Other("client_session")) = event.parse(frame)
}
