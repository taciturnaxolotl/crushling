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

import crushling/gun
import crushling/proxy/meter.{type Cap, type Usage}
import crushling/proxy/usage
import crushling/sandbox_http
import crushling/sys
import crushling/token as bearer
import gleam/bit_array
import gleam/bool
import gleam/bytes_tree
import gleam/erlang/process.{type Pid, type Subject}
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

/// How long upstream may take to answer, and to send each next chunk.
const head_timeout_ms = 600_000

const idle_timeout_ms = 300_000

/// Body messages gun may deliver ahead of what has been written out.
const flow_window = 8

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
      |> closing,
  )
  let length =
    request.get_header(req, "content-length")
    |> result.try(int.parse)
    |> result.unwrap(0)
  use <- bool.guard(
    length > max_body,
    error_reply(413, "invalid_request_error", "Request too large.") |> closing,
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

/// Close the connection after this response: its request may not have been
/// read in full, or the client-close watcher has used the socket.
fn closing(resp: Response(a)) -> Response(a) {
  response.set_header(resp, "connection", "close")
}

const hop_by_hop = [
  "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
  "proxy-connection", "te", "trailer", "trailers", "transfer-encoding",
  "upgrade",
]

/// Headers without hop-by-hop ones (including any `Connection` names) or
/// any in `drop`. Used on responses.
pub fn end_to_end(
  headers: List(#(String, String)),
  drop: List(String),
) -> List(#(String, String)) {
  let named =
    list.flat_map(headers, fn(header) {
      case string.lowercase(header.0) {
        "connection" ->
          string.split(header.1, ",")
          |> list.map(fn(name) { string.lowercase(string.trim(name)) })
        _ -> []
      }
    })
  let dropped = list.flatten([hop_by_hop, named, drop])
  list.filter(headers, fn(header) {
    !list.contains(dropped, string.lowercase(header.0))
  })
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

/// What the relay tells the request handler once upstream answers.
type Head {
  Head(status: Int, headers: List(#(String, String)), body: Option(Body))
  Failed(status: Int)
  /// Revoked or over a cap by the time the request was ready to go.
  Refused(denial: meter.Denial)
}

/// Where the handler sends the writer it started, and where the writer
/// acknowledges each chunk.
type Body {
  Body(writer_to: Subject(Subject(Piece)), ack: Subject(Nil))
}

/// A piece of the response body, for the process writing it out.
type Piece {
  Piece(data: BitArray, fin: Bool)
  Cut(denial: meter.Denial)
  Broken
  /// The client has gone; stop.
  Gone
}

type Socket

@external(erlang, "crushling_proxy_ffi", "socket")
fn socket(connection: mist.Connection) -> Socket

@external(erlang, "crushling_proxy_ffi", "wait_closed")
fn wait_closed(socket: Socket) -> Nil

type Job {
  Job(
    upstream: Upstream,
    meter: Subject(meter.Message),
    org_key: String,
    key: String,
    method: String,
    path: String,
    headers: List(#(String, String)),
    handler: Pid,
    socket: Socket,
  )
}

fn forward(
  proxy: Proxy,
  req: Request(mist.Connection),
  key: String,
  path: String,
) -> Response(mist.ResponseData) {
  let job =
    Job(
      upstream: proxy.upstream,
      meter: proxy.meter,
      org_key: proxy.org_key,
      key:,
      method: http.method_to_string(req.method),
      path: proxy.upstream.prefix <> path,
      headers: upstream_headers(req.headers, proxy.org_key, key),
      handler: process.self(),
      socket: socket(req.body),
    )
  let started = process.new_subject()
  let reply = process.new_subject()
  // The relay holds the request's admission until it exits.
  let relay = process.spawn_unlinked(fn() { relay(job, started, reply) })
  let assert Ok(go) = process.receive(started, 5000)
  case meter.admit(proxy.meter, key, relay) {
    Error(denial) -> {
      process.kill(relay)
      denied(denial)
    }
    Ok(Nil) ->
      // The relay holds the upload slot, so it is only killed once the read
      // has stopped.
      case read_body(req, proxy.upload_timeout_ms) {
        Error(TooSlow) -> {
          process.kill(relay)
          error_reply(
            408,
            "invalid_request_error",
            "The request body was too slow.",
          )
          |> closing
        }
        Error(Unreadable) -> {
          process.kill(relay)
          error_reply(400, "invalid_request_error", "Could not read the body.")
          |> closing
        }
        Ok(body) -> {
          meter.uploaded(proxy.meter, relay)
          process.send(go, body)
          respond(req, relay, reply)
        }
      }
  }
}

type ReadFailure {
  TooSlow
  Unreadable
}

/// Read the request body within `timeout_ms` in all. The read runs in its
/// own process, which is killed at the deadline; this returns only once it
/// has stopped.
fn read_body(
  req: Request(mist.Connection),
  timeout_ms: Int,
) -> Result(BitArray, ReadFailure) {
  let done = process.new_subject()
  let reader =
    process.spawn_unlinked(fn() {
      process.send(
        done,
        mist.read_body(req, max_body) |> result.map(fn(read) { read.body }),
      )
    })
  let monitor = process.monitor(reader)
  case process.receive(done, timeout_ms) {
    Ok(Ok(body)) -> {
      process.demonitor_process(monitor)
      Ok(body)
    }
    Ok(Error(_)) -> {
      process.demonitor_process(monitor)
      Error(Unreadable)
    }
    Error(Nil) -> {
      process.kill(reader)
      let _ =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(_) { Nil })
        |> process.selector_receive(5000)
      Error(TooSlow)
    }
  }
}

fn respond(
  req: Request(mist.Connection),
  relay: Pid,
  reply: Subject(Head),
) -> Response(mist.ResponseData) {
  case process.receive(reply, head_timeout_ms + 15_000) {
    Error(Nil) -> {
      process.kill(relay)
      failed(504)
    }
    Ok(Failed(status)) -> failed(status)
    Ok(Refused(denial)) -> denied(denial)
    Ok(Head(status:, headers:, body: None)) ->
      response.Response(
        status:,
        headers: end_to_end(headers, ["content-length"]),
        body: mist.Bytes(bytes_tree.new()),
      )
      |> closing
    Ok(Head(status:, headers:, body: Some(body))) -> {
      let headers = end_to_end(headers, ["content-length"])
      let content_type =
        list.key_find(headers, "content-type") |> result.unwrap("")
      let writer = process.new_subject()
      let resp =
        mist.chunked(
          req,
          response.Response(status:, headers:, body: Nil),
          fn(pieces) {
            process.send(writer, pieces)
            Writing(
              ack: body.ack,
              sse: string.contains(content_type, "text/event-stream"),
            )
          },
          write,
        )
      // The body may only flow once mist has handed the socket to the
      // writer, or a short body could finish before that.
      case process.receive(writer, 0) {
        Ok(pieces) -> process.send(body.writer_to, pieces)
        Error(Nil) -> process.kill(relay)
      }
      resp
    }
  }
}

/// A fixed answer for upstream trouble; the details are in the bridge's
/// log.
fn failed(status: Int) -> Response(mist.ResponseData) {
  case status {
    504 -> error_reply(504, "server_error", "Hyper did not answer in time.")
    _ -> error_reply(502, "server_error", "Could not reach Hyper.")
  }
  |> closing
}

type Writing {
  Writing(ack: Subject(Nil), sse: Bool)
}

fn write(
  state: Writing,
  piece: Piece,
  conn: mist.Connection,
) -> mist.ChunkNext(Writing) {
  case piece {
    // No final chunk, so the client sees a truncated body, not an end.
    Broken -> mist.ChunkAbort("upstream broke off")
    // Stopping closes the socket the writer owns.
    Gone -> mist.ChunkStop
    Cut(denial) -> {
      // Tell crush why, in the shape Hyper uses for errors in the middle of
      // a stream.
      case state.sse {
        True -> {
          let #(_, kind, message) = describe(denial)
          let _ =
            mist.send_chunk(
              conn,
              bit_array.from_string(
                "data: " <> error_body(kind, message) <> "\n\n",
              ),
            )
          Nil
        }
        False -> Nil
      }
      mist.ChunkStop
    }
    Piece(data:, fin:) -> {
      let sent = case data {
        <<>> -> Ok(Nil)
        _ -> mist.send_chunk(conn, data)
      }
      case sent, fin {
        Error(Nil), _ -> mist.ChunkStop
        Ok(Nil), True -> mist.ChunkStop
        Ok(Nil), False -> {
          process.send(state.ack, Nil)
          mist.ChunkContinue(state)
        }
      }
    }
  }
}

@external(erlang, "crushling_proxy_ffi", "request")
fn upstream_request(
  conn: gun.Conn,
  method: String,
  path: String,
  headers: List(#(String, String)),
  body: BitArray,
  flow: Int,
) -> gun.StreamRef

@external(erlang, "crushling_proxy_ffi", "update_flow")
fn update_flow(conn: gun.Conn, stream: gun.StreamRef, flow: Int) -> Nil

type Relayed {
  Go(body: BitArray)
  FromGun(gun.Message)
  ClientGone
  DownstreamDown
  WriterReady(Subject(Piece))
  Written
}

/// Runs in its own process, which holds the request's admission: waits for
/// the request body, makes the upstream request, reports the response head,
/// then passes body pieces to the writer one flow window at a time, and
/// records usage when upstream finishes or the client goes away.
fn relay(
  job: Job,
  started: Subject(Subject(BitArray)),
  reply: Subject(Head),
) -> Nil {
  let go = process.new_subject()
  process.send(started, go)
  let handler = process.monitor(job.handler)
  let waiting =
    process.new_selector()
    |> process.select_map(go, Go)
    |> process.select_specific_monitor(handler, fn(_) { DownstreamDown })
  case process.selector_receive(waiting, head_timeout_ms) {
    Ok(Go(body)) -> {
      // The body has been read, so the socket is quiet until the client
      // closes it.
      let gone = process.new_subject()
      let watcher =
        process.spawn(fn() {
          wait_closed(job.socket)
          process.send(gone, Nil)
        })
      // Revocation or a cap may have come while the body was arriving.
      case meter.check_key(job.meter, job.key) {
        Error(denial) -> process.send(reply, Refused(denial))
        Ok(Nil) -> run(job, body, reply, handler, gone)
      }
      process.unlink(watcher)
      process.kill(watcher)
    }
    _ -> Nil
  }
}

fn run(
  job: Job,
  body: BitArray,
  reply: Subject(Head),
  handler: process.Monitor,
  gone: Subject(Nil),
) -> Nil {
  let upstream = job.upstream
  case gun.connect_tcp(upstream.host, upstream.port, upstream.tls, 15_000) {
    Error(reason) -> {
      log(job, "could not connect: " <> reason)
      process.send(reply, Failed(502))
    }
    Ok(conn) ->
      // Check again after the connect: the client may have left, or the
      // thread been revoked, meanwhile.
      case process.receive(gone, 0), meter.check_key(job.meter, job.key) {
        Ok(Nil), _ -> {
          process.send(reply, Failed(502))
          gun.close(conn)
        }
        Error(Nil), Error(denial) -> {
          process.send(reply, Refused(denial))
          gun.close(conn)
        }
        Error(Nil), Ok(Nil) -> dispatch(job, conn, body, reply, handler, gone)
      }
  }
}

fn dispatch(
  job: Job,
  conn: gun.Conn,
  body: BitArray,
  reply: Subject(Head),
  handler: process.Monitor,
  gone: Subject(Nil),
) -> Nil {
  let stream =
    upstream_request(conn, job.method, job.path, job.headers, body, flow_window)
  let base =
    process.new_selector()
    |> gun.select(FromGun)
    |> process.select_map(gone, fn(_) { ClientGone })
  let before =
    base
    |> process.select_specific_monitor(handler, fn(_) { DownstreamDown })
  case await_head(before, conn, stream) {
    Error(#(status, reason)) -> {
      log(job, reason)
      process.send(reply, Failed(status))
    }
    Ok(#(status, headers, True)) ->
      process.send(reply, Head(status, headers, None))
    Ok(#(status, headers, False)) -> {
      let writer_to = process.new_subject()
      let ack = process.new_subject()
      process.send(reply, Head(status, headers, Some(Body(writer_to, ack))))
      // Body messages wait in the mailbox (at most a flow window of
      // them) until the writer is ready.
      let ready =
        process.new_selector()
        |> process.select_map(writer_to, WriterReady)
        |> process.select_map(gone, fn(_) { ClientGone })
        |> process.select_specific_monitor(handler, fn(_) { DownstreamDown })
      case await_writer(ready, False) {
        Error(Nil) -> Nil
        Ok(pieces) -> {
          process.demonitor_process(handler)
          let after = case process.subject_owner(pieces) {
            Ok(writer) ->
              base
              |> process.select_specific_monitor(process.monitor(writer), fn(_) {
                DownstreamDown
              })
            Error(Nil) -> base
          }
          let after = after |> process.select_map(ack, fn(_) { Written })
          let #(scanner, last) =
            pump(
              after,
              job,
              conn,
              stream,
              pieces,
              usage.new(
                list.key_find(headers, "content-type") |> result.unwrap(""),
              ),
            )
          // Settle before the last piece goes out, so the totals are
          // current by the time the client sees the end.
          case usage.finish(scanner) {
            Some(found) -> meter.record(job.meter, job.key, found)
            None -> Nil
          }
          case last {
            Some(piece) -> process.send(pieces, piece)
            None -> Nil
          }
        }
      }
    }
  }
  gun.close(conn)
}

fn await_head(
  selector: process.Selector(Relayed),
  conn: gun.Conn,
  stream: gun.StreamRef,
) -> Result(#(Int, List(#(String, String)), Bool), #(Int, String)) {
  case process.selector_receive(selector, head_timeout_ms) {
    Error(Nil) -> Error(#(504, "upstream did not answer in time"))
    Ok(ClientGone) | Ok(DownstreamDown) ->
      Error(#(502, "client went away before upstream answered"))
    Ok(FromGun(gun.StreamResponse(conn: c, stream: s, status:, headers:, fin:)))
      if c == conn && s == stream
    ->
      case status < 200 {
        // An informational response; the real one follows.
        True -> await_head(selector, conn, stream)
        False -> Ok(#(status, headers, fin))
      }
    Ok(FromGun(gun.StreamError(conn: c, stream: s, reason:)))
      if c == conn && s == stream
    -> Error(#(502, "upstream request failed: " <> reason))
    Ok(FromGun(gun.ConnDown(conn: c, reason:))) if c == conn ->
      Error(#(502, "upstream connection closed: " <> reason))
    Ok(_) -> await_head(selector, conn, stream)
  }
}

/// Wait for the writer mist started. If the client goes away meanwhile,
/// keep waiting for the writer anyway, to stop it.
fn await_writer(
  selector: process.Selector(Relayed),
  client_gone: Bool,
) -> Result(Subject(Piece), Nil) {
  case process.selector_receive(selector, 15_000) {
    Ok(WriterReady(pieces)) if client_gone -> {
      process.send(pieces, Gone)
      Error(Nil)
    }
    Ok(WriterReady(pieces)) -> Ok(pieces)
    Ok(ClientGone) -> await_writer(selector, True)
    Ok(FromGun(_)) | Ok(Written) | Ok(Go(_)) ->
      await_writer(selector, client_gone)
    Ok(DownstreamDown) | Error(Nil) -> Error(Nil)
  }
}

/// Pass body pieces on until the stream ends. Returns what was scanned and
/// the last piece to send once usage is settled, if any.
fn pump(
  selector: process.Selector(Relayed),
  job: Job,
  conn: gun.Conn,
  stream: gun.StreamRef,
  pieces: Subject(Piece),
  scanner: usage.Scanner,
) -> #(usage.Scanner, Option(Piece)) {
  let next = fn(scanner) { pump(selector, job, conn, stream, pieces, scanner) }
  case process.selector_receive(selector, idle_timeout_ms) {
    Error(Nil) -> {
      log(job, "upstream went quiet")
      #(scanner, Some(Broken))
    }
    Ok(ClientGone) -> #(scanner, Some(Gone))
    // The writer is already gone.
    Ok(DownstreamDown) -> #(scanner, None)
    Ok(Written) -> {
      update_flow(conn, stream, 1)
      next(scanner)
    }
    Ok(FromGun(gun.Data(conn: c, stream: s, data:, fin:)))
      if c == conn && s == stream
    -> {
      // Scan first, so usage that has arrived is recorded even if the
      // stream is cut here.
      let scanner = usage.feed(scanner, data)
      case meter.check_key(job.meter, job.key), fin {
        Error(denial), _ -> #(scanner, Some(Cut(denial)))
        Ok(Nil), True -> #(scanner, Some(Piece(data, True)))
        Ok(Nil), False -> {
          process.send(pieces, Piece(data, False))
          next(scanner)
        }
      }
    }
    // Trailers end the stream; they are not passed on.
    Ok(FromGun(gun.Trailers(conn: c, stream: s, ..)))
      if c == conn && s == stream
    -> #(scanner, Some(Piece(<<>>, True)))
    Ok(FromGun(gun.StreamError(conn: c, stream: s, reason:)))
      if c == conn && s == stream
    -> {
      log(job, "upstream stream failed: " <> reason)
      #(scanner, Some(Broken))
    }
    Ok(FromGun(gun.ConnDown(conn: c, reason:))) if c == conn -> {
      log(job, "upstream connection closed: " <> reason)
      #(scanner, Some(Broken))
    }
    Ok(_) -> next(scanner)
  }
}

/// Log upstream trouble on the bridge, never with the org's key in it.
fn log(job: Job, what: String) -> Nil {
  let what = case job.org_key {
    "" -> what
    key -> string.replace(what, key, "<org key>")
  }
  sys.warn("crushling: proxy for " <> job.key <> ": " <> what)
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
