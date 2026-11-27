//// Requests to GitHub's API, built one way: its accept header, a user agent
//// GitHub requires, and how the request authenticates.

import gleam/bit_array
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/json
import gleam/result
import gleam/string

pub const api_base = "https://api.github.com"

pub const web_base = "https://github.com"

/// How a request authenticates.
pub type Auth {
  /// A person's token or an installation token.
  Bearer(token: String)
  /// The app's client id and secret, for its OAuth endpoints.
  Basic(id: String, secret: String)
  /// A JWT the app signed, for asking about the app itself.
  AppJwt(jwt: String)
}

/// How requests are sent: `send` in the bridge, a fake in tests.
pub type Send =
  fn(Request(String)) -> Result(Response(String), String)

/// Send with gleam_httpc.
pub fn send(req: Request(String)) -> Result(Response(String), String) {
  httpc.send(req) |> result.map_error(string.inspect)
}

/// A request to `api_base <> path`.
pub fn api(method: http.Method, path: String, auth: Auth) -> Request(String) {
  let assert Ok(req) = request.to(api_base <> path)
  req
  |> request.set_method(method)
  |> request.set_header("accept", "application/vnd.github+json")
  |> request.set_header("user-agent", "crushling")
  |> request.set_header("authorization", header(auth))
}

/// The request with `body` as JSON.
pub fn with_json(req: Request(String), body: json.Json) -> Request(String) {
  req
  |> request.set_header("content-type", "application/json")
  |> request.set_body(json.to_string(body))
}

pub fn header(auth: Auth) -> String {
  case auth {
    Bearer(token) | AppJwt(token) -> "Bearer " <> token
    Basic(id, secret) ->
      "Basic "
      <> bit_array.base64_encode(
        bit_array.from_string(id <> ":" <> secret),
        True,
      )
  }
}

/// The body of a 2xx answer, or why there isn't one, prefixed with `what`.
pub fn body(
  send: Send,
  req: Request(String),
  what: String,
) -> Result(String, String) {
  case send(req) {
    Error(reason) -> Error(what <> ": " <> reason)
    Ok(resp) if resp.status >= 200 && resp.status < 300 -> Ok(resp.body)
    Ok(resp) ->
      Error(what <> ": GitHub answered " <> int.to_string(resp.status))
  }
}
