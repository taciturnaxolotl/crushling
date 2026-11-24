//// The inference proxy: how a sandbox reaches Hyper without holding a key.
////
//// Each thread's crush is pointed at `http://<bridge>/proxy/<key>` as its
//// Hyper URL, with a per-thread token (`token`) as its API key. Only the
//// three calls crush makes in a turn are served:
////
//// | Request | Purpose |
//// |---|---|
//// | `POST /v1/chat/completions` | inference |
//// | `GET /api/v1/provider/v3` | the model catalog |
//// | `GET /v1/credits` | the balance |
////
//// Anything else (login, token exchange, team management) is a 404. A
//// request is checked against the thread's token, admitted by the meter,
//// and sent to Hyper with the org's real key, an `X-Hyper-Label: <key>`
//// header and a short allowlist of crush's own headers. The response
//// streams back chunk by chunk under gun's flow control, so a slow reader
//// slows Hyper down rather than filling memory, and a client that goes
//// away cancels the upstream request.
////
//// On the way through, the `usage` Hyper reports is added to the thread's
//// and the instance's totals (`proxy/meter`). Past a cap, new requests get
//// a 429 and a stream in flight is cut at its next chunk; a revoked thread
//// gets a 403 the same way. Caps are soft limits kept in one process: see
//// `proxy/meter` for what that allows.
////
//// crush ignores a configured `base_url` for Hyper and derives every URL
//// (catalog, credits, inference) from `$HYPER_URL`, so the sandbox needs
//// `crush_env`: `HYPER_URL` and `HYPER_API_KEY`. crush lets `CRUSH_<NAME>`
//// override `<NAME>`, so a sandbox must not also get `CRUSH_HYPER_API_KEY`
//// or `CRUSH_HYPER_URL`.

import crushling/proxy/meter.{type Cap, type Usage}
import crushling/proxy/usage
import crushling/relay
import crushling/sandbox_http
import crushling/sys
import crushling/token as bearer
import gleam/bit_array
import gleam/bool

import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mist

/// Hyper's own address, crush's default, and where the proxy sends
/// requests when nothing says otherwise.
pub const default_upstream = "https://hyper.charm.land"

/// The settings that name the upstream, in order of precedence; the first
/// one set wins, else `default_upstream`. `HYPER_URL` is crush's own name
/// for it.
pub const upstream_settings = ["CRUSHLING_PROXY_UPSTREAM", "HYPER_URL"]

/// The settings that hold the org's Hyper key, in order of precedence.
/// `HYPER_API_KEY` is crush's own name for it; `CRUSH_HYPER_API_KEY` is
/// read last so older `.env` files keep working.
pub const org_key_settings = [
  "CRUSHLING_HYPER_KEY", "HYPER_API_KEY", "CRUSH_HYPER_API_KEY",
]

/// The upstream from the bridge's settings, `lookup` reading one by name.
/// These are the bridge's own: a sandbox only ever gets `crush_env`.
pub fn upstream_from(lookup: fn(String) -> Result(String, Nil)) -> String {
  first_set(upstream_settings, lookup) |> result.unwrap(default_upstream)
}

/// The org's key from the bridge's settings, `lookup` reading one by name.
pub fn org_key_from(
  lookup: fn(String) -> Result(String, Nil),
) -> Result(String, Nil) {
  first_set(org_key_settings, lookup)
}

fn first_set(
  names: List(String),
  lookup: fn(String) -> Result(String, Nil),
) -> Result(String, Nil) {
  list.find_map(names, fn(name) {
    case lookup(name) {
      Ok(value) if value != "" -> Ok(value)
      _ -> Error(Nil)
    }
  })
}

/// Requests one thread may have in flight at once.
pub const default_max_per_thread = 4

/// Request bodies the proxy reads at once, across every thread.
pub const default_max_uploads = 16

/// How long a client gets to send its whole request body.
pub const default_upload_timeout_ms = 60_000

pub type Config {
  Config(
    /// The instance secret thread tokens are derived from.
    secret: String,
    /// The org's Hyper API key, the only one that leaves the bridge.
    org_key: String,
    /// Where requests go; usually `upstream_from` the settings. Must be https unless
    /// the host is a loopback address.
    upstream: String,
    thread_cap: Cap,
    instance_cap: Cap,
    max_per_thread: Int,
    max_uploads: Int,
    upload_timeout_ms: Int,
  )
}

pub opaque type Proxy {
  Proxy(
    meter: Subject(meter.Message),
    secret: String,
    org_key: String,
    upstream: Upstream,
    upload_timeout_ms: Int,
  )
}

type Upstream {
  Upstream(host: String, port: Int, tls: Bool, prefix: String)
}

/// Start the proxy. Errors describe the problem without repeating any
/// setting's value.
pub fn start(config: Config) -> Result(Proxy, String) {
  use upstream <- result.try(parse_upstream(config.upstream))
  use meter <- result.map(
    meter.start(meter.Limits(
      thread_cap: config.thread_cap,
      instance_cap: config.instance_cap,
      max_per_thread: config.max_per_thread,
      max_uploads: config.max_uploads,
    ))
    |> result.replace_error("the proxy's meter could not start"),
  )
  Proxy(
    meter:,
    secret: config.secret,
    org_key: config.org_key,
    upstream:,
    upload_timeout_ms: config.upload_timeout_ms,
  )
}

fn parse_upstream(url: String) -> Result(Upstream, String) {
  let bad = "must be an https URL (or http on a loopback address)"
  use parsed <- result.try(uri.parse(url) |> result.replace_error(bad))
  use host <- result.try(case parsed.host {
    Some(host) if host != "" -> Ok(host)
    _ -> Error(bad)
  })
  use tls <- result.map(case parsed.scheme {
    Some("https") -> Ok(True)
    Some("http") ->
      case loopback(host) {
        True -> Ok(False)
        False -> Error(bad)
      }
    _ -> Error(bad)
  })
  let port =
    option.unwrap(parsed.port, case tls {
      True -> 443
      False -> 80
    })
  let prefix = case string.ends_with(parsed.path, "/") {
    True -> string.drop_end(parsed.path, 1)
    False -> parsed.path
  }
  Upstream(host:, port:, tls:, prefix:)
}

/// `localhost`, or an address in 127.0.0.0/8 or ::1. Only parsed addresses
/// count: a name like `127.example.com` is not loopback.
@external(erlang, "crushling_proxy_ffi", "loopback")
fn loopback(host: String) -> Bool

/// The token a thread presents as its Hyper API key.
pub fn token(secret: String, key: String) -> String {
  bearer.mint(secret, bearer.Proxy, key)
}

/// The thread's proxy token, as environment.
pub fn env(secret: String, key: String) -> List(String) {
  ["CRUSHLING_PROXY_TOKEN=" <> token(secret, key)]
}

/// What a thread's crush needs to use the proxy as Hyper: `bridge_url` is
/// how the sandbox reaches the sandbox server, e.g. `http://10.0.0.1:7469`.
pub fn crush_env(
  bridge_url: String,
  secret: String,
  key: String,
) -> List(String) {
  [
    "HYPER_URL=" <> base_url(bridge_url, key),
    "HYPER_API_KEY=" <> token(secret, key),
  ]
}

/// The Hyper base URL for a thread.
pub fn base_url(bridge_url: String, key: String) -> String {
  let bridge = case string.ends_with(bridge_url, "/") {
    True -> string.drop_end(bridge_url, 1)
    False -> bridge_url
  }
  bridge <> "/proxy/" <> key
}

/// Stop `key`'s token from working, from its next request or chunk on.
pub fn revoke(proxy: Proxy, key: String) -> Nil {
  meter.revoke(proxy.meter, key)
}

/// Undo `revoke`, for a thread that resumes.
pub fn restore(proxy: Proxy, key: String) -> Nil {
  meter.restore(proxy.meter, key)
}

/// Hold one thread to its own cap, or back to the default with `None`.
pub fn set_thread_cap(proxy: Proxy, key: String, cap: Option(Cap)) -> Nil {
  meter.set_thread_cap(proxy.meter, key, cap)
}

/// What `key` has spent since the bridge started.
pub fn totals(proxy: Proxy, key: String) -> Usage {
  meter.totals(proxy.meter, key)
}

/// What each thread spent since the last call, for keeping elsewhere.
pub fn drain(proxy: Proxy) -> List(#(String, Usage)) {
  meter.drain(proxy.meter)
}

/// What every thread together has spent since the bridge started.
pub fn instance_totals(proxy: Proxy) -> Usage {
  meter.instance_totals(proxy.meter)
}

/// Every thread's totals.
pub fn all_totals(proxy: Proxy) -> List(#(String, Usage)) {
  meter.all_totals(proxy.meter)
}

/// The requests that are served, as method and path; the path is also the
/// upstream path.
const routes = [
  #(http.Post, "/v1/chat/completions"),
  #(http.Get, "/api/v1/provider/v3"),
  #(http.Get, "/v1/credits"),
]

/// Request headers passed on to Hyper: what crush and the OpenAI SDK under
/// it send. Authorization and X-Hyper-Label are set by the proxy.
const forwarded_headers = [
  "accept", "content-type", "content-encoding", "user-agent", "x-crush-id",
  "if-none-match", "x-stainless-arch", "x-stainless-lang", "x-stainless-os",
  "x-stainless-package-version", "x-stainless-retry-count",
  "x-stainless-runtime", "x-stainless-runtime-version", "x-stainless-timeout",
]

/// The route that serves `/proxy/<key>/...`.
pub fn route(proxy: Proxy) -> sandbox_http.Route {
  fn(req: Request(mist.Connection)) {
    case req.path {
      "/proxy/" <> rest -> {
        let #(key, path) = case string.split_once(rest, "/") {
          Ok(#(key, path)) -> #(key, "/" <> path)
          Error(Nil) -> #(rest, "/")
        }
        Some(serve(proxy, req, key, path))
      }
      _ -> None
    }
  }
}

const max_body = 64_000_000

fn serve(
  proxy: Proxy,
  req: Request(mist.Connection),
  key: String,
  path: String,
) -> Response(mist.ResponseData) {
  let auth = request.get_header(req, "authorization") |> result.unwrap("")
  use <- bool.guard(
    !bearer.authorized(proxy.secret, bearer.Proxy, key, auth),
    error_reply(401, "authentication_error", "Invalid crushling proxy token."),
  )
  use <- bool.guard(
    !list.contains(routes, #(req.method, path)),
    error_reply(404, "invalid_request_error", "Not found."),
  )
  let chunked =
    request.get_header(req, "transfer-encoding")
    |> result.map(fn(value) {
      string.contains(string.lowercase(value), "chunked")
    })
    |> result.unwrap(False)
  // crush always sends a Content-Length, so a chunked body is refused
  // rather than read without knowing its size.
  use <- bool.guard(
    chunked,
    error_reply(411, "invalid_request_error", "Send a Content-Length.")
      |> relay.closing,
  )
  let length =
    request.get_header(req, "content-length")
    |> result.try(int.parse)
    |> result.unwrap(0)
  use <- bool.guard(
    length > max_body,
    error_reply(413, "invalid_request_error", "Request too large.")
      |> relay.closing,
  )
  forward(proxy, req, key, path)
}

fn denied(denial: meter.Denial) -> Response(mist.ResponseData) {
  let #(status, kind, message) = describe(denial)
  error_reply(status, kind, message)
  |> response.set_header("x-should-retry", "false")
}

fn describe(denial: meter.Denial) -> #(Int, String, String) {
  case denial {
    meter.Revoked -> #(
      403,
      "permission_error",
      "This thread's access to inference has been revoked.",
    )
    meter.ThreadCap -> #(
      429,
      "rate_limit_error",
      "This thread has reached its inference spending cap.",
    )
    meter.InstanceCap -> #(
      429,
      "rate_limit_error",
      "This crushling instance has reached its inference spending cap.",
    )
    meter.ThreadBusy -> #(
      429,
      "rate_limit_error",
      "This thread has too many inference requests in flight.",
    )
    meter.InstanceBusy -> #(
      429,
      "rate_limit_error",
      "The inference proxy is busy; try again shortly.",
    )
  }
}

/// A body in Hyper's (OpenAI's) error envelope.
fn error_body(kind: String, message: String) -> String {
  json.object([
    #(
      "error",
      json.object([
        #("message", json.string(message)),
        #("type", json.string(kind)),
      ]),
    ),
  ])
  |> json.to_string
}

fn error_reply(
  status: Int,
  kind: String,
  message: String,
) -> Response(mist.ResponseData) {
  sandbox_http.reply(status, error_body(kind, message))
  |> response.set_header("content-type", "application/json")
}

/// The request headers sent to Hyper.
pub fn upstream_headers(
  headers: List(#(String, String)),
  org_key: String,
  key: String,
) -> List(#(String, String)) {
  [
    #("authorization", "Bearer " <> org_key),
    #("x-hyper-label", key),
    ..list.filter(headers, fn(header) {
      list.contains(forwarded_headers, string.lowercase(header.0))
    })
  ]
}

fn forward(
  proxy: Proxy,
  req: Request(mist.Connection),
  key: String,
  path: String,
) -> Response(mist.ResponseData) {
  let hooks = hooks(proxy, key)
  let upstream = proxy.upstream
  let relay =
    relay.start(
      relay.Upstream(upstream.host, upstream.port, upstream.tls),
      relay.Outgoing(
        method: http.method_to_string(req.method),
        path: upstream.prefix <> path,
        headers: upstream_headers(req.headers, proxy.org_key, key),
      ),
      req,
      hooks,
    )
  // The relay holds the request's admission until it exits.
  case meter.admit(proxy.meter, key, relay.pid(relay)) {
    Error(denial) -> {
      relay.cancel(relay)
      denied(denial)
    }
    Ok(Nil) ->
      // The relay holds the upload slot, so it is only killed once the read
      // has stopped.
      case relay.read_body(req, max_body, proxy.upload_timeout_ms) {
        Error(relay.TooSlow) -> {
          relay.cancel(relay)
          error_reply(
            408,
            "invalid_request_error",
            "The request body was too slow.",
          )
          |> relay.closing
        }
        Error(relay.Unreadable) -> {
          relay.cancel(relay)
          error_reply(400, "invalid_request_error", "Could not read the body.")
          |> relay.closing
        }
        Ok(body) -> {
          meter.uploaded(proxy.meter, relay.pid(relay))
          relay.send(relay, req, body, hooks)
        }
      }
  }
}

/// The meter decides whether a request goes on, and the usage Hyper
/// reports is recorded once the response ends.
fn hooks(proxy: Proxy, key: String) -> relay.Hooks(usage.Scanner) {
  relay.Hooks(
    check: fn() {
      meter.check_key(proxy.meter, key)
      |> result.map_error(fn(denial) {
        relay.Stop(answer: denied(denial), tail: fn(content_type) {
          // Tell crush why, in the shape Hyper uses for errors in the
          // middle of a stream.
          case string.contains(content_type, "text/event-stream") {
            True -> {
              let #(_, kind, message) = describe(denial)
              bit_array.from_string(
                "data: " <> error_body(kind, message) <> "\n\n",
              )
            }
            False -> <<>>
          }
        })
      })
    },
    scan: usage.new,
    feed: usage.feed,
    finish: fn(scanner) {
      case usage.finish(scanner) {
        Some(found) -> meter.record(proxy.meter, key, found)
        None -> Nil
      }
    },
    head: fn(_, headers) { Ok(headers) },
    failed:,
    log: fn(what) { log(proxy.org_key, key, what) },
  )
}

/// A fixed answer for upstream trouble; the details are in the bridge's
/// log.
fn failed(status: Int) -> Response(mist.ResponseData) {
  case status {
    504 -> error_reply(504, "server_error", "Hyper did not answer in time.")
    _ -> error_reply(502, "server_error", "Could not reach Hyper.")
  }
  |> relay.closing
}

/// Log upstream trouble on the bridge, never with the org's key in it.
fn log(org_key: String, key: String, what: String) -> Nil {
  let what = case org_key {
    "" -> what
    org_key -> string.replace(what, org_key, "<org key>")
  }
  sys.warn("crushling: proxy for " <> key <> ": " <> what)
}

pub type CapError {
  BadTokens
  BadUsd
}

/// A cap from settings: a token count and a dollar amount, either empty
/// for no limit.
pub fn parse_cap(tokens: String, usd: String) -> Result(Cap, CapError) {
  use tokens <- result.try(case string.trim(tokens) {
    "" -> Ok(None)
    text ->
      int.parse(text) |> result.map(Some) |> result.replace_error(BadTokens)
  })
  use usd <- result.map(case string.trim(usd) {
    "" -> Ok(None)
    text ->
      float_parse(text) |> result.map(Some) |> result.replace_error(BadUsd)
  })
  meter.Cap(tokens:, usd:)
}

fn float_parse(text: String) -> Result(Float, Nil) {
  case int.parse(text) {
    Ok(whole) -> Ok(int.to_float(whole))
    Error(Nil) -> float.parse(text)
  }
}
