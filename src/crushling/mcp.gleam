//// A small MCP server over Streamable HTTP, so each thread's agent can use
//// crushling's Slack tools.
////
//// Every thread has its own endpoint, `/mcp/<key>`, guarded by a bearer
//// token derived from a secret only the bridge knows. The agent gets its
//// key and token through its environment (`env`), and its crush.json
//// points at the endpoint (`provider.config_with`). Requests are answered
//// with plain JSON; there is no server-initiated stream.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mist

pub type Tool {
  Tool(name: String, description: String, input_schema: Json)
}

/// Runs a tool for a thread: the thread's key, the tool's name, and its
/// arguments. The text is the tool's result; an error is shown to the
/// agent as a failed call.
pub type Call =
  fn(String, String, Dynamic) -> Result(String, String)

@external(erlang, "crushling_ffi", "sha256_hex")
fn sha256_hex(data: String) -> String

@external(erlang, "crushling_ffi", "log_warning")
fn warn(text: String) -> Nil

/// The token a thread presents.
pub fn token(secret: String, key: String) -> String {
  sha256_hex(secret <> "\u{0}" <> key)
}

/// The environment a thread's agent needs to reach its endpoint.
pub fn env(secret: String, key: String) -> List(String) {
  ["CRUSHLING_THREAD=" <> key, "CRUSHLING_MCP_TOKEN=" <> token(secret, key)]
}

const protocol_version = "2025-06-18"

const instructions =
  "These tools reach the Slack conversation you are working in. Read it, look around the workspace's channels, post an update, share a file, or move the work into a code channel when it involves changing a repository."

/// Answer one JSON-RPC message. Notifications and responses get nothing
/// back.
pub fn respond(
  body: String,
  key: String,
  tools: List(Tool),
  call: Call,
) -> Option(String) {
  let id_decoder =
    decode.one_of(decode.int |> decode.map(json.int), [
      decode.string |> decode.map(json.string),
    ])
  let message = {
    use id <- decode.optional_field("id", None, decode.optional(id_decoder))
    use method <- decode.optional_field("method", "", decode.string)
    use params <- decode.optional_field("params", dynamic.nil(), decode.dynamic)
    decode.success(#(id, method, params))
  }
  case json.parse(body, message) {
    Error(_) -> Some(error_reply(json.null(), -32_700, "parse error"))
    Ok(#(None, _, _)) -> None
    Ok(#(Some(id), method, params)) ->
      Some(case method {
        "initialize" -> {
          let version =
            decode.run(params, decode.at(["protocolVersion"], decode.string))
            |> result.unwrap(protocol_version)
          ok_reply(
            id,
            json.object([
              #("protocolVersion", json.string(version)),
              #(
                "capabilities",
                json.object([
                  #("tools", json.object([#("listChanged", json.bool(False))])),
                ]),
              ),
              #(
                "serverInfo",
                json.object([
                  #("name", json.string("crushling-slack")),
                  #("version", json.string("0.1.0")),
                ]),
              ),
              #("instructions", json.string(instructions)),
            ]),
          )
        }
        "ping" -> ok_reply(id, json.object([]))
        "tools/list" ->
          ok_reply(
            id,
            json.object([
              #(
                "tools",
                json.array(tools, fn(tool) {
                  json.object([
                    #("name", json.string(tool.name)),
                    #("description", json.string(tool.description)),
                    #("inputSchema", tool.input_schema),
                  ])
                }),
              ),
            ]),
          )
        "tools/call" -> {
          let request = {
            use name <- decode.field("name", decode.string)
            use arguments <- decode.optional_field(
              "arguments",
              dynamic.properties([]),
              decode.dynamic,
            )
            decode.success(#(name, arguments))
          }
          case decode.run(params, request) {
            Error(_) -> error_reply(id, -32_602, "tools/call needs a name")
            Ok(#(name, arguments)) ->
              case list.any(tools, fn(tool) { tool.name == name }) {
                False -> error_reply(id, -32_602, "no tool named " <> name)
                True -> {
                  let #(text, failed) = case call(key, name, arguments) {
                    Ok(text) -> #(text, False)
                    Error(reason) -> #(reason, True)
                  }
                  ok_reply(
                    id,
                    json.object([
                      #(
                        "content",
                        json.preprocessed_array([
                          json.object([
                            #("type", json.string("text")),
                            #("text", json.string(text)),
                          ]),
                        ]),
                      ),
                      #("isError", json.bool(failed)),
                    ]),
                  )
                }
              }
          }
        }
        method -> error_reply(id, -32_601, "unknown method " <> method)
      })
  }
}

fn ok_reply(id: Json, result: Json) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", id),
    #("result", result),
  ])
  |> json.to_string
}

fn error_reply(id: Json, code: Int, message: String) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", id),
    #(
      "error",
      json.object([
        #("code", json.int(code)),
        #("message", json.string(message)),
      ]),
    ),
  ])
  |> json.to_string
}

/// Whether a request carries the thread's token.
pub fn authorized(secret: String, key: String, header: String) -> Bool {
  key != "" && header == "Bearer " <> token(secret, key)
}

const max_body = 1_000_000

/// Serve the tools on `bind`:`port`.
pub fn start(
  bind: String,
  port: Int,
  secret: String,
  tools: List(Tool),
  call: Call,
) -> Result(Nil, String) {
  let handler = fn(req: Request(mist.Connection)) -> Response(mist.ResponseData) {
    case request.path_segments(req) {
      ["mcp", key] -> {
        let auth = request.get_header(req, "authorization") |> result.unwrap("")
        case authorized(secret, key, auth), req.method {
          False, _ -> reply(401, "")
          True, http.Post ->
            case mist.read_body(req, max_body) {
              Error(_) -> reply(413, "")
              Ok(req) ->
                case bit_array.to_string(req.body) {
                  Error(Nil) -> reply(400, "")
                  Ok(body) ->
                    case respond(body, key, tools, call) {
                      None -> reply(202, "")
                      Some(json) ->
                        reply(200, json)
                        |> response.set_header(
                          "content-type",
                          "application/json",
                        )
                    }
                }
            }
          // No server-initiated stream.
          True, http.Get ->
            reply(405, "") |> response.set_header("allow", "POST")
          True, http.Delete -> reply(200, "")
          True, _ -> reply(405, "")
        }
      }
      _ -> reply(404, "")
    }
  }
  mist.new(handler)
  |> mist.bind(bind)
  |> mist.port(port)
  |> mist.after_start(fn(_, _, _) { Nil })
  |> mist.start
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(error) {
    warn("crushling: tool server: " <> string.inspect(error))
    "could not serve the Slack tools on "
    <> bind
    <> ":"
    <> string.inspect(port)
    <> ": "
    <> string.inspect(error)
  })
}

fn reply(status: Int, body: String) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}
