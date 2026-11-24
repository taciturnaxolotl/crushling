//// Talking to GitHub as crushling's GitHub App, for one person: the device
//// flow that connects their account, refreshing their token, and asking
//// who they are. The calls are built and read here; `send` does the HTTP,
//// so tests can answer for GitHub.
////
//// Device flow and refresh need only the app's client id, not its secret.
//// Revoking a token on GitHub needs the secret too; without one a
//// disconnect just forgets the token, and the person can revoke it in
//// their GitHub settings.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

/// A user access token and when it expires, and the refresh token. Times
/// are Unix seconds; 0 means it doesn't expire.
pub type Tokens {
  Tokens(
    access: String,
    expires_at: Int,
    refresh: String,
    refresh_expires_at: Int,
  )
}

pub type Config {
  Config(
    /// The GitHub App's client id (`Iv1…` or `Iv23…`), not its app id.
    client_id: String,
    /// Only to revoke tokens on disconnect.
    client_secret: Option(String),
    send: fn(Request(String)) -> Result(Response(String), String),
  )
}

/// Send with gleam_httpc.
pub fn http(req: Request(String)) -> Result(Response(String), String) {
  httpc.send(req) |> result.map_error(string.inspect)
}

const web = "https://github.com"

const api = "https://api.github.com"

/// The code a person enters at `verification_uri`, and how to poll for
/// their answer.
pub type DeviceCode {
  DeviceCode(
    device_code: String,
    user_code: String,
    verification_uri: String,
    /// Seconds.
    expires_in: Int,
    interval: Int,
  )
}

/// What a poll for the person's answer found.
pub type Poll {
  Granted(Tokens)
  Pending
  /// Poll less often: every `interval` seconds from now on, or, when GitHub
  /// didn't say, five seconds less often than now (RFC 8628).
  SlowDown(interval: Option(Int))
  /// The person cancelled, the code expired, or the app is misconfigured.
  Failed(reason: String)
}

fn form(path: String, fields: List(#(String, String))) -> Request(String) {
  let assert Ok(req) = request.to(web <> path)
  req
  |> request.set_method(http.Post)
  |> request.set_header("accept", "application/json")
  |> request.set_header("content-type", "application/x-www-form-urlencoded")
  |> request.set_body(uri.query_to_string(fields))
}

fn body(
  config: Config,
  req: Request(String),
  what: String,
) -> Result(String, String) {
  case config.send(req) {
    Error(reason) -> Error(what <> ": " <> reason)
    Ok(response) if response.status >= 200 && response.status < 300 ->
      Ok(response.body)
    Ok(response) ->
      Error(what <> ": GitHub answered " <> int.to_string(response.status))
  }
}

/// Start connecting an account.
pub fn device_code(config: Config) -> Result(DeviceCode, String) {
  use text <- result.try(body(
    config,
    form("/login/device/code", [#("client_id", config.client_id)]),
    "asking GitHub for a code",
  ))
  let decoder = {
    use device_code <- decode.field("device_code", decode.string)
    use user_code <- decode.field("user_code", decode.string)
    use verification_uri <- decode.field("verification_uri", decode.string)
    use expires_in <- decode.optional_field("expires_in", 900, decode.int)
    use interval <- decode.optional_field("interval", 5, decode.int)
    decode.success(DeviceCode(
      device_code:,
      user_code:,
      verification_uri:,
      expires_in:,
      interval:,
    ))
  }
  json.parse(text, decoder) |> result.map_error(fn(_) { refused(text) })
}

/// Ask whether the person has entered `code` yet. `now` is Unix seconds.
pub fn poll(config: Config, code: DeviceCode, now: Int) -> Poll {
  let req =
    form("/login/oauth/access_token", [
      #("client_id", config.client_id),
      #("device_code", code.device_code),
      #("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
    ])
  case body(config, req, "polling GitHub") {
    Error(reason) -> Failed(reason)
    Ok(text) ->
      case json.parse(text, tokens_decoder(now)) {
        Ok(tokens) -> Granted(tokens)
        Error(_) ->
          case json.parse(text, error_decoder()) {
            Ok(#("authorization_pending", _)) -> Pending
            Ok(#("slow_down", interval)) -> SlowDown(interval)
            Ok(#("expired_token", _)) -> Failed("the code expired")
            Ok(#("access_denied", _)) -> Failed("it was cancelled on GitHub")
            Ok(#("device_flow_disabled", _)) ->
              Failed("the GitHub App doesn't have device flow turned on")
            Ok(#(error, _)) -> Failed("GitHub said " <> error)
            Error(_) -> Failed(refused(text))
          }
      }
  }
}

/// Poll until the person answers or `deadline` (Unix seconds) passes,
/// sleeping between polls in the calling process. GitHub's interval is held
/// to 1 to 60 seconds, so a bad one can neither spin nor stall.
pub fn wait(
  config: Config,
  code: DeviceCode,
  deadline: Int,
  now: fn() -> Int,
) -> Result(Tokens, String) {
  wait_loop(config, code, deadline, now, code.interval)
}

fn wait_loop(
  config: Config,
  code: DeviceCode,
  deadline: Int,
  now: fn() -> Int,
  interval: Int,
) -> Result(Tokens, String) {
  let interval = int.clamp(interval, min: 1, max: 60)
  sleep(interval * 1000)
  case now() > deadline, poll(config, code, now()) {
    _, Granted(tokens) -> Ok(tokens)
    True, _ -> Error("the code expired")
    False, Pending -> wait_loop(config, code, deadline, now, interval)
    False, SlowDown(Some(slower)) ->
      wait_loop(config, code, deadline, now, slower)
    False, SlowDown(None) ->
      wait_loop(config, code, deadline, now, interval + 5)
    False, Failed(reason) -> Error(reason)
  }
}

@external(erlang, "timer", "sleep")
fn sleep(ms: Int) -> Nil

/// Swap a refresh token for new tokens. `now` is Unix seconds.
pub fn refresh(
  config: Config,
  tokens: Tokens,
  now: Int,
) -> Result(Tokens, String) {
  use text <- result.try(body(
    config,
    form("/login/oauth/access_token", [
      #("client_id", config.client_id),
      #("grant_type", "refresh_token"),
      #("refresh_token", tokens.refresh),
    ]),
    "refreshing the GitHub token",
  ))
  json.parse(text, tokens_decoder(now))
  |> result.map_error(fn(_) {
    case json.parse(text, error_decoder()) {
      Ok(#(error, _)) -> "GitHub refused the refresh (" <> error <> ")"
      Error(_) -> refused(text)
    }
  })
}

/// Whether `tokens` should be refreshed before use: the access token
/// expires within five minutes. `now` is Unix seconds.
pub fn stale(tokens: Tokens, now: Int) -> Bool {
  tokens.expires_at != 0 && tokens.expires_at - now < 300
}

/// The login of the person a token belongs to.
pub fn login(config: Config, tokens: Tokens) -> Result(String, String) {
  let assert Ok(req) = request.to(api <> "/user")
  use text <- result.try(body(
    config,
    req
      |> request.set_header("accept", "application/vnd.github+json")
      |> request.set_header("authorization", "Bearer " <> tokens.access)
      |> request.set_header("user-agent", "crushling"),
    "asking GitHub who this is",
  ))
  json.parse(text, decode.at(["login"], decode.string))
  |> result.map_error(fn(_) { refused(text) })
}

/// Revoke the person's grant on GitHub, if the app's secret is known. Ok
/// with False when it isn't, so the caller can say so.
pub fn revoke(config: Config, tokens: Tokens) -> Result(Bool, String) {
  case config.client_secret {
    None -> Ok(False)
    Some(secret) -> {
      let assert Ok(req) =
        request.to(api <> "/applications/" <> config.client_id <> "/grant")
      let basic =
        bit_array.from_string(config.client_id <> ":" <> secret)
        |> bit_array.base64_encode(True)
      req
      |> request.set_method(http.Delete)
      |> request.set_header("accept", "application/vnd.github+json")
      |> request.set_header("authorization", "Basic " <> basic)
      |> request.set_header("user-agent", "crushling")
      |> request.set_header("content-type", "application/json")
      |> request.set_body(
        json.to_string(
          json.object([#("access_token", json.string(tokens.access))]),
        ),
      )
      |> body(config, _, "revoking the GitHub token")
      |> result.replace(True)
    }
  }
}

fn tokens_decoder(now: Int) -> decode.Decoder(Tokens) {
  use access <- decode.field("access_token", decode.string)
  use expires_in <- decode.optional_field("expires_in", 0, decode.int)
  use refresh <- decode.optional_field("refresh_token", "", decode.string)
  use refresh_expires_in <- decode.optional_field(
    "refresh_token_expires_in",
    0,
    decode.int,
  )
  let at = fn(seconds) {
    case seconds {
      0 -> 0
      seconds -> now + seconds
    }
  }
  decode.success(Tokens(
    access:,
    expires_at: at(expires_in),
    refresh:,
    refresh_expires_at: at(refresh_expires_in),
  ))
}

fn error_decoder() -> decode.Decoder(#(String, Option(Int))) {
  use error <- decode.field("error", decode.string)
  use interval <- decode.optional_field(
    "interval",
    None,
    decode.map(decode.int, Some),
  )
  decode.success(#(error, interval))
}

/// An answer GitHub shouldn't have given, without echoing it: it may hold a
/// token.
fn refused(text: String) -> String {
  "GitHub's answer didn't make sense ("
  <> int.to_string(string.byte_size(text))
  <> " bytes)"
}
