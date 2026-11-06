import crushling/crush/client
import gleam/http
import gleam/json
import gleam/option.{None, Some}

pub fn create_workspace_call_test() {
  let call =
    client.create_workspace(
      path: "/workspace",
      client_id: "c-1",
      mode: client.Yolo,
      env: ["A=1"],
    )
  let assert http.Post = call.method
  let assert "/v1/workspaces" = call.path
  let assert 200 = call.expect
  let assert Some(body) = call.body
  let assert "{\"path\":\"/workspace\",\"client_id\":\"c-1\",\"permission_mode\":\"yolo\",\"env\":[\"A=1\"]}" =
    json.to_string(body)
  let assert Ok("w-9") = call.parse("{\"id\":\"w-9\",\"path\":\"/workspace\"}")
  let assert Error(Nil) = call.parse("")
}

pub fn send_prompt_call_test() {
  let call =
    client.send_prompt(
      workspace_id: "w",
      session_id: "s",
      run_id: "r",
      prompt: "fix \"it\"",
    )
  let assert "/v1/workspaces/w/agent" = call.path
  let assert 202 = call.expect
  let assert Some(body) = call.body
  let assert "{\"session_id\":\"s\",\"run_id\":\"r\",\"prompt\":\"fix \\\"it\\\"\"}" =
    json.to_string(body)
  let assert Ok(Nil) = call.parse("")
}

pub fn send_prompt_with_attachments_test() {
  let call =
    client.send_prompt_with(
      workspace_id: "w",
      session_id: "s",
      run_id: "r",
      prompt: "look",
      attachments: [
        client.Attachment(
          path: ".slack/1.0/a.png",
          name: "a.png",
          mime_type: "image/png",
          content: <<"hi":utf8>>,
        ),
      ],
    )
  let assert Some(body) = call.body
  let assert "{\"session_id\":\"s\",\"run_id\":\"r\",\"prompt\":\"look\",\"attachments\":[{\"file_path\":\".slack/1.0/a.png\",\"file_name\":\"a.png\",\"mime_type\":\"image/png\",\"content\":\"aGk=\"}]}" =
    json.to_string(body)
}

pub fn agent_ready_call_test() {
  let call = client.agent_ready("w")
  let assert http.Get = call.method
  let assert Ok(True) = call.parse("{\"is_busy\":false,\"is_ready\":true}")
  let assert Ok(False) = call.parse("{}")
}

pub fn session_paths_test() {
  let assert "/v1/workspaces/w/agent/sessions/s/cancel" =
    client.cancel("w", "s").path
  let assert "/v1/workspaces/w/agent/sessions/s/prompts/clear" =
    client.clear_queue("w", "s").path
  let assert "/v1/workspaces/w/events?client_id=c%201" =
    client.events_path("w", "c 1")
  let assert None = client.retire_client("c").body
}

pub fn error_message_test() {
  let assert "agent busy" = client.error_message("{\"message\":\"agent busy\"}")
  let assert "oops" = client.error_message("oops")
}

pub fn latest_session_call_test() {
  let call = client.latest_session("w")
  let assert "/v1/workspaces/w/sessions" = call.path
  let assert Ok(Some("b")) =
    call.parse(
      "[{\"id\":\"a\",\"updated_at\":5},{\"id\":\"b\",\"updated_at\":9},{\"id\":\"child\",\"parent_session_id\":\"b\",\"updated_at\":20}]",
    )
  let assert Ok(None) = call.parse("[]")
}
