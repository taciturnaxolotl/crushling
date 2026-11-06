import crushling/crush/event
import crushling/mcp
import crushling/run
import crushling/slack_tools
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/string

fn tools() {
  slack_tools.tools()
}

fn fake(key, name, arguments) {
  case name {
    "post_message" -> {
      let assert Ok(text) =
        decode.run(arguments, decode.at(["text"], decode.string))
      Ok(key <> " posted " <> text)
    }
    _ -> Error("nope")
  }
}

pub fn initialize_and_list_test() {
  let assert Some(reply) =
    mcp.respond(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\"}}",
      "k",
      tools(),
      fake,
    )
  let assert True = string.contains(reply, "\"protocolVersion\":\"2025-03-26\"")
  let assert True = string.contains(reply, "\"id\":1")
  let assert None =
    mcp.respond(
      "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
      "k",
      tools(),
      fake,
    )
  let assert Some(listed) =
    mcp.respond(
      "{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"method\":\"tools/list\"}",
      "k",
      tools(),
      fake,
    )
  let assert True = string.contains(listed, "\"open_code_channel\"")
  let assert True = string.contains(listed, "\"id\":\"a\"")
}

pub fn tool_calls_test() {
  let assert Some(reply) =
    mcp.respond(
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"post_message\",\"arguments\":{\"text\":\"hi\"}}}",
      "k",
      tools(),
      fake,
    )
  let assert True = string.contains(reply, "k posted hi")
  let assert True = string.contains(reply, "\"isError\":false")
  let assert Some(failed) =
    mcp.respond(
      "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"list_channels\"}}",
      "k",
      tools(),
      fake,
    )
  let assert True = string.contains(failed, "\"isError\":true")
  let assert Some(unknown) =
    mcp.respond(
      "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"rm_rf\"}}",
      "k",
      tools(),
      fake,
    )
  let assert True = string.contains(unknown, "-32602")
  let assert Some(garbage) = mcp.respond("{", "k", tools(), fake)
  let assert True = string.contains(garbage, "-32700")
}

pub fn tokens_are_per_thread_test() {
  let token = mcp.token("s", "C1-1.0")
  let assert True = mcp.authorized("s", "C1-1.0", "Bearer " <> token)
  let assert False = mcp.authorized("s", "C2-1.0", "Bearer " <> token)
  let assert False = mcp.authorized("other", "C1-1.0", "Bearer " <> token)
  let assert False = mcp.authorized("s", "C1-1.0", "")
  let assert [_, "CRUSHLING_MCP_TOKEN=" <> t] = mcp.env("s", "C1-1.0")
  let assert True = t == token
}

pub fn workspace_paths_stay_inside_test() {
  let assert Ok("shot.png") =
    slack_tools.workspace_path("/workspace", "shot.png")
  let assert Ok("a/b.txt") =
    slack_tools.workspace_path("/workspace", "/workspace/a/./b.txt")
  let assert Error(Nil) =
    slack_tools.workspace_path("/workspace", "/etc/passwd")
  let assert Error(Nil) = slack_tools.workspace_path("/workspace", "a/../../x")
  let assert Error(Nil) = slack_tools.workspace_path("/workspace", "")
}

fn assistant(id: String, text: String) -> event.Event {
  let assert Ok(e) =
    json.parse(
      "{\"type\":\"message\",\"payload\":{\"type\":\"updated\",\"payload\":{\"id\":\""
        <> id
        <> "\",\"session_id\":\"s\",\"role\":\"assistant\",\"parts\":[{\"type\":\"text\",\"data\":{\"text\":\""
        <> text
        <> "\"}}]}}}",
      event.decoder(),
    )
  e
}

pub fn settled_messages_test() {
  let r = run.new("s", "r")
  let r = run.apply(r, dict.new(), assistant("m1", "looking around"))
  // The only message may still grow.
  let assert [] = run.messages(r, False)
  let r = run.apply(r, dict.new(), assistant("m2", "found it"))
  let assert [#("m1", "looking around")] = run.messages(r, False)
  let assert [_, #("m2", "found it")] = run.messages(r, True)
}
