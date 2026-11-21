//// The inference proxy against a fake Hyper: a local mist server the test
//// drives step by step, so streaming can be watched chunk by chunk, plus a
//// raw TCP one for trailers.
////
//// The real tests, skipped unless `CRUSHLING_REAL=1` and a Hyper key is in
//// `CRUSH_HYPER_API_KEY` (environment or `.env`), check TLS verification,
//// send a request through the proxy to Hyper and then run a whole
//// `crush run` against it.

import crushling/gun
import crushling/proxy
import crushling/proxy/meter.{Cap}
import crushling/proxy/usage
import crushling/sandbox_http
import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import mist

const secret = "test-secret"

const org_key = "org-hyper-key"

// The fake upstream.

pub type Arrival {
  Arrival(
    method: String,
    path: String,
    headers: List(#(String, String)),
    body: String,
    plan: Subject(Plan),
  )
}

pub type Plan {
  Reply(status: Int, headers: List(#(String, String)), body: String)
  Stream(ready: Subject(Subject(Step)))
}

pub type Step {
  Send(String)
  /// Send `count` chunks of `size` bytes, reporting how many have gone out
  /// every 50.
  Flood(count: Int, size: Int, progress: Subject(Int))
  Finish
}

type Socket

@external(erlang, "crushling_proxy_ffi", "socket")
fn socket(connection: mist.Connection) -> Socket

@external(erlang, "crushling_proxy_ffi", "wait_closed")
fn wait_closed(socket: Socket) -> Nil

/// `closed` hears whenever the proxy closes a streamed upstream request.
fn start_upstream(arrivals: Subject(Arrival), closed: Subject(Nil)) -> Int {
  let handler = fn(req: Request(mist.Connection)) {
    let assert Ok(read) = mist.read_body(req, 1_000_000)
    let assert Ok(body) = bit_array.to_string(read.body)
    let plan = process.new_subject()
    let path = case req.query {
      Some(query) -> req.path <> "?" <> query
      None -> req.path
    }
    process.send(
      arrivals,
      Arrival(
        string.inspect(req.method) |> string.lowercase,
        path,
        req.headers,
        body,
        plan,
      ),
    )
    case process.receive(plan, 5000) {
      Ok(Reply(status, headers, body)) ->
        response.Response(
          status:,
          headers:,
          body: mist.Bytes(bytes_tree.from_string(body)),
        )
      Ok(Stream(ready)) -> {
        let sock = socket(req.body)
        process.spawn_unlinked(fn() {
          wait_closed(sock)
          process.send(closed, Nil)
        })
        let steps = process.new_subject()
        let resp =
          mist.chunked(
            req,
            response.new(200)
              |> response.set_header("content-type", "text/event-stream")
              |> response.set_header("x-prism-model-id", "fake"),
            fn(s) { process.send(steps, s) },
            fn(state, step, conn) {
              case step {
                Send(data) -> {
                  let _ = mist.send_chunk(conn, bit_array.from_string(data))
                  mist.ChunkContinue(state)
                }
                Flood(count, size, progress) -> {
                  let chunk =
                    bit_array.from_string(
                      ":" <> string.repeat("x", size - 3) <> "\n\n",
                    )
                  flood(conn, chunk, count, 0, progress)
                  mist.ChunkContinue(state)
                }
                Finish -> mist.ChunkStop
              }
            },
          )
        let assert Ok(s) = process.receive(steps, 0)
        process.send(ready, s)
        resp
      }
      Error(Nil) -> sandbox_http.reply(500, "no plan")
    }
  }
  serve(handler)
}

fn flood(
  conn: mist.Connection,
  chunk: BitArray,
  count: Int,
  sent: Int,
  progress: Subject(Int),
) -> Nil {
  case sent < count {
    False -> Nil
    True ->
      case mist.send_chunk(conn, chunk) {
        Error(Nil) -> Nil
        Ok(Nil) -> {
          case { sent + 1 } % 50 {
            0 -> process.send(progress, sent + 1)
            _ -> Nil
          }
          flood(conn, chunk, count, sent + 1, progress)
        }
      }
  }
}

fn serve(
  handler: fn(Request(mist.Connection)) -> response.Response(mist.ResponseData),
) -> Int {
  let port = process.new_subject()
  let assert Ok(_) =
    mist.new(handler)
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(p, _, _) { process.send(port, p) })
    |> mist.start
  let assert Ok(port) = process.receive(port, 5000)
  port
}

pub type Setup {
  Setup(
    proxy: proxy.Proxy,
    port: Int,
    arrivals: Subject(Arrival),
    closed: Subject(Nil),
  )
}

fn config(upstream: String) -> proxy.Config {
  proxy.Config(
    secret:,
    org_key:,
    upstream:,
    thread_cap: meter.unlimited,
    instance_cap: meter.unlimited,
    max_per_thread: proxy.default_max_per_thread,
    max_uploads: proxy.default_max_uploads,
    upload_timeout_ms: proxy.default_upload_timeout_ms,
  )
}

fn start_proxy(config: proxy.Config) -> #(proxy.Proxy, Int) {
  let assert Ok(p) = proxy.start(config)
  let route = proxy.route(p)
  let port =
    serve(fn(req) { route(req) |> option.unwrap(sandbox_http.reply(404, "")) })
  #(p, port)
}

fn setup_with(change: fn(proxy.Config) -> proxy.Config) -> Setup {
  let arrivals = process.new_subject()
  let closed = process.new_subject()
  let upstream = start_upstream(arrivals, closed)
  let #(p, port) =
    start_proxy(change(config("http://127.0.0.1:" <> int.to_string(upstream))))
  Setup(p, port, arrivals, closed)
}

fn setup() -> Setup {
  setup_with(fn(config) { config })
}

/// A new connection for each request: the proxy closes them after a
/// forwarded response.
fn connect(setup: Setup) -> gun.Conn {
  let assert Ok(conn) = gun.connect_tcp("127.0.0.1", setup.port, False, 2000)
  conn
}

fn auth(key: String) -> #(String, String) {
  #("authorization", "Bearer " <> proxy.token(secret, key))
}

fn next_arrival(setup: Setup) -> Arrival {
  let assert Ok(arrival) = process.receive(setup.arrivals, 5000)
  arrival
}

fn send(
  setup: Setup,
  method: String,
  path: String,
  headers: List(#(String, String)),
) -> Result(gun.Response, String) {
  let conn = connect(setup)
  let assert Ok(method) = http_method(method)
  let response =
    gun.request(
      conn,
      method,
      path,
      [#("content-type", "application/json"), ..headers],
      <<"{\"model\":\"prism\"}">>,
      5000,
    )
  gun.close(conn)
  response
}

fn post(
  setup: Setup,
  path: String,
  headers: List(#(String, String)),
) -> Result(gun.Response, String) {
  send(setup, "POST", path, headers)
}

/// Post in the background; the result arrives on the returned subject.
fn post_later(
  setup: Setup,
  path: String,
  headers: List(#(String, String)),
) -> Subject(Result(gun.Response, String)) {
  let result = process.new_subject()
  process.spawn(fn() { process.send(result, post(setup, path, headers)) })
  result
}

fn completions(key: String) -> String {
  "/proxy/" <> key <> "/v1/chat/completions"
}

@external(erlang, "gleam@http", "parse_method")
fn http_method(name: String) -> Result(a, Nil)

const usage_json =
  "{\"id\":\"x\",\"choices\":[],\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":2,\"total_tokens\":11,\"cost\":{\"usd\":0.25,\"hypercredits\":5}}}"

fn reply_json(arrival: Arrival, status: Int, body: String) -> Nil {
  process.send(
    arrival.plan,
    Reply(status, [#("content-type", "application/json")], body),
  )
}

fn answered(
  result: Subject(Result(gun.Response, String)),
) -> Result(gun.Response, String) {
  let assert Ok(response) = process.receive(result, 5000)
  response
}

// A streamed request, read message by message.

@external(erlang, "crushling_proxy_ffi", "request")
fn stream_request(
  conn: gun.Conn,
  method: String,
  path: String,
  headers: List(#(String, String)),
  body: BitArray,
  flow: Int,
) -> gun.StreamRef

fn open_stream(setup: Setup, key: String) -> #(gun.Conn, gun.StreamRef) {
  let conn = connect(setup)
  let stream =
    stream_request(
      conn,
      "POST",
      completions(key),
      [auth(key), #("content-type", "application/json")],
      <<"{\"stream\":true}">>,
      1_000_000,
    )
  #(conn, stream)
}

fn next_message() -> gun.Message {
  let selector = process.new_selector() |> gun.select(fn(m) { m })
  case process.selector_receive(selector, 5000) {
    // Earlier connections closing.
    Ok(gun.ConnDown(..)) | Ok(gun.Ignored) -> next_message()
    Ok(message) -> message
    Error(Nil) -> panic as "nothing arrived"
  }
}

/// The upstream end of a stream the proxy just opened.
fn upstream_stream(setup: Setup) -> #(Arrival, Subject(Step)) {
  let arrival = next_arrival(setup)
  let ready = process.new_subject()
  process.send(arrival.plan, Stream(ready))
  let assert Ok(steps) = process.receive(ready, 5000)
  #(arrival, steps)
}

/// Body pieces until the stream ends, as one string.
fn rest_of_body(acc: String) -> String {
  case next_message() {
    gun.Data(data:, fin: True, ..) -> acc <> bits(data)
    gun.Data(data:, fin: False, ..) -> rest_of_body(acc <> bits(data))
    gun.StreamEnd(..) -> acc
    other -> panic as { "unexpected " <> string.inspect(other) }
  }
}

fn bits(data: BitArray) -> String {
  let assert Ok(text) = bit_array.to_string(data)
  text
}

const sse_text =
  "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hi\"}}]}\n\n"

const sse_usage =
  "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":20,\"total_tokens\":120,\"cost\":{\"usd\":0.5}}}\n\ndata: [DONE]\n\n"

@external(erlang, "proxy_test_ffi", "raw_exchange")
fn raw_exchange(port: Int, request: String) -> String

@external(erlang, "proxy_test_ffi", "raw_open")
fn raw_open(port: Int, request: String) -> Socket

@external(erlang, "proxy_test_ffi", "raw_close")
fn raw_close(socket: Socket) -> Nil

@external(erlang, "proxy_test_ffi", "trailer_upstream")
fn trailer_upstream(body: String) -> Int

@external(erlang, "proxy_test_ffi", "raw_send")
fn raw_send(socket: Socket, data: String) -> Nil

@external(erlang, "proxy_test_ffi", "raw_read_line")
fn raw_read_line(socket: Socket) -> String

@external(erlang, "proxy_test_ffi", "peer_owner")
fn peer_owner(socket: Socket) -> Pid

@external(erlang, "proxy_test_ffi", "alive")
fn alive(pid: Pid) -> Bool

@external(erlang, "proxy_test_ffi", "max_queue")
fn max_queue(except: Pid) -> Int

fn raw_post(key: String, extra: String) -> String {
  "POST "
  <> completions(key)
  <> " HTTP/1.1\r\nhost: proxy\r\nauthorization: Bearer "
  <> proxy.token(secret, key)
  <> "\r\ncontent-type: application/json\r\n"
  <> extra
}

// Tests.

pub fn bad_token_is_401_test() {
  let setup = setup()
  let assert Ok(gun.Response(status: 401, body:, ..)) =
    post(setup, completions("C1-1.0"), [#("authorization", "Bearer nope")])
  let assert True = string.contains(bits(body), "\"authentication_error\"")
  // Another thread's token doesn't open this one.
  let assert Ok(gun.Response(status: 401, ..)) =
    post(setup, completions("C1-1.0"), [auth("C2-1.0")])
  let assert Ok(gun.Response(status: 401, ..)) =
    post(setup, completions("C1-1.0"), [])
  // Nothing reached upstream.
  let assert Error(Nil) = process.receive(setup.arrivals, 100)
}

pub fn only_crushs_calls_are_served_test() {
  let setup = setup()
  let not_found = fn(method, path) {
    let assert Ok(gun.Response(status: 404, body:, headers:)) =
      send(setup, method, "/proxy/k" <> path, [auth("k")])
    let assert Ok("application/json") = list.key_find(headers, "content-type")
    let assert True =
      bits(body)
      == "{\"error\":{\"message\":\"Not found.\",\"type\":\"invalid_request_error\"}}"
  }
  not_found("POST", "/device/auth")
  not_found("POST", "/token/exchange")
  not_found("POST", "/token/introspect")
  not_found("GET", "/api/v1/teams")
  not_found("DELETE", "/api/v1/keys/1")
  not_found("GET", "/v1/chat/completions")
  not_found("POST", "/v1/credits")
  not_found("POST", "/v1/chat/completions/../../device/auth")
  not_found("POST", "")
  let assert Error(Nil) = process.receive(setup.arrivals, 100)
  // The three that are.
  let ok = fn(method, path) {
    let result = process.new_subject()
    process.spawn(fn() {
      process.send(result, send(setup, method, "/proxy/k" <> path, [auth("k")]))
    })
    let arrival = next_arrival(setup)
    let assert True = arrival.path == path
    reply_json(arrival, 200, "{}")
    let assert Ok(gun.Response(status: 200, ..)) = answered(result)
    Nil
  }
  ok("POST", "/v1/chat/completions")
  ok("GET", "/api/v1/provider/v3")
  ok("GET", "/v1/credits")
}

pub fn auth_is_swapped_and_only_allowed_headers_go_upstream_test() {
  let setup = setup()
  let result =
    post_later(setup, completions("C1-1.0") <> "?beta=1", [
      auth("C1-1.0"),
      #("x-crush-id", "abc"),
      #("user-agent", "OpenAI/Go 1.0"),
      #("x-stainless-lang", "go"),
      #("content-encoding", "br"),
      #("x-hyper-label", "spoofed"),
      #("x-arbitrary", "secret"),
      #("cookie", "a=b"),
      #("connection", "keep-alive, x-private-hop"),
      #("x-private-hop", "1"),
      #("te", "trailers"),
      #("proxy-authorization", "Basic abc"),
      #("accept-encoding", "gzip"),
    ])
  let arrival = next_arrival(setup)
  process.send(
    arrival.plan,
    Reply(
      200,
      [
        #("content-type", "application/json"),
        #("keep-alive", "timeout=9"),
        #("proxy-authenticate", "Basic"),
        #("x-upstream", "yes"),
      ],
      usage_json,
    ),
  )
  let assert "post" = arrival.method
  // The query isn't part of any route, so it isn't sent.
  let assert "/v1/chat/completions" = arrival.path
  let assert Ok("Bearer org-hyper-key") =
    list.key_find(arrival.headers, "authorization")
  let assert ["C1-1.0"] = values(arrival.headers, "x-hyper-label")
  let assert Ok("abc") = list.key_find(arrival.headers, "x-crush-id")
  let assert Ok("OpenAI/Go 1.0") = list.key_find(arrival.headers, "user-agent")
  let assert Ok("go") = list.key_find(arrival.headers, "x-stainless-lang")
  let assert Ok("br") = list.key_find(arrival.headers, "content-encoding")
  let names = list.map(arrival.headers, fn(header) { header.0 })
  list.each(
    [
      "x-arbitrary", "cookie", "x-private-hop", "keep-alive", "te",
      "proxy-authorization", "accept-encoding",
    ],
    fn(name) {
      let assert False = list.contains(names, name)
    },
  )
  let assert "{\"model\":\"prism\"}" = arrival.body
  let assert Ok(gun.Response(status: 200, headers:, ..)) = answered(result)
  // Hop-by-hop response headers are dropped too.
  let assert Error(Nil) = list.key_find(headers, "keep-alive")
  let assert Error(Nil) = list.key_find(headers, "proxy-authenticate")
  let assert Ok("yes") = list.key_find(headers, "x-upstream")
}

fn values(headers: List(#(String, String)), name: String) -> List(String) {
  list.filter_map(headers, fn(header) {
    case header.0 == name {
      True -> Ok(header.1)
      False -> Error(Nil)
    }
  })
}

pub fn json_passes_through_and_is_metered_test() {
  let setup = setup()
  let result = post_later(setup, completions("k"), [auth("k")])
  reply_json(next_arrival(setup), 201, usage_json)
  let assert Ok(gun.Response(status: 201, headers:, body:)) = answered(result)
  let assert True = bits(body) == usage_json
  let assert Ok("application/json") = list.key_find(headers, "content-type")
  let assert meter.Usage(9, 2, 0.25, 1) = proxy.totals(setup.proxy, "k")
  let assert meter.Usage(9, 2, 0.25, 1) = proxy.instance_totals(setup.proxy)
  // Upstream errors pass through as they are.
  let result = post_later(setup, completions("k"), [auth("k")])
  reply_json(
    next_arrival(setup),
    400,
    "{\"error\":{\"message\":\"bad\",\"type\":\"invalid_request_error\"}}",
  )
  let assert Ok(gun.Response(status: 400, body:, ..)) = answered(result)
  let assert True = string.contains(bits(body), "\"bad\"")
}

pub fn chunks_arrive_before_the_stream_ends_and_usage_is_metered_test() {
  let setup = setup()
  let #(_, stream) = open_stream(setup, "k")
  let #(_, steps) = upstream_stream(setup)
  let assert gun.StreamResponse(status: 200, headers:, fin: False, ..) =
    next_message()
  let assert Ok("text/event-stream") = list.key_find(headers, "content-type")
  let assert Ok("fake") = list.key_find(headers, "x-prism-model-id")
  // Upstream has sent one chunk and is holding the rest; it must already
  // be here.
  process.send(steps, Send(sse_text))
  let assert gun.Data(data:, fin: False, stream: s, ..) = next_message()
  let assert True = s == stream
  let assert True = bits(data) == sse_text
  let assert meter.Usage(0, 0, 0.0, 0) = proxy.totals(setup.proxy, "k")
  // The usage chunk split mid-line across two writes.
  let #(first, second) = #(
    string.slice(sse_usage, 0, 40),
    string.drop_start(sse_usage, 40),
  )
  process.send(steps, Send(first))
  let assert gun.Data(data:, ..) = next_message()
  let assert True = bits(data) == first
  process.send(steps, Send(second))
  process.send(steps, Finish)
  let assert True = rest_of_body("") == second
  let assert meter.Usage(100, 20, 0.5, 1) = proxy.totals(setup.proxy, "k")
}

pub fn trailers_end_the_stream_and_are_not_forwarded_test() {
  let upstream = trailer_upstream(sse_usage)
  let #(p, port) =
    start_proxy(config("http://127.0.0.1:" <> int.to_string(upstream)))
  let setup = Setup(p, port, process.new_subject(), process.new_subject())
  let _ = open_stream(setup, "k")
  let assert gun.StreamResponse(status: 200, headers:, ..) = next_message()
  let assert Error(Nil) = list.key_find(headers, "trailer")
  // Upstream keeps its connection open, so only the trailers end this; a
  // forwarded trailer would arrive as gun.Trailers and fail here.
  let assert True = rest_of_body("") == sse_usage
  let assert meter.Usage(100, 20, 0.5, 1) = proxy.totals(p, "k")
}

pub fn over_the_cap_is_429_test() {
  let setup =
    setup_with(fn(config) {
      proxy.Config(..config, thread_cap: Cap(tokens: Some(10), usd: None))
    })
  let result = post_later(setup, completions("k"), [auth("k")])
  reply_json(next_arrival(setup), 200, usage_json)
  let assert Ok(gun.Response(status: 200, ..)) = answered(result)
  let assert Ok(gun.Response(status: 429, headers:, body:)) =
    post(setup, completions("k"), [auth("k")])
  let assert Ok("application/json") = list.key_find(headers, "content-type")
  let assert True =
    bits(body)
    == "{\"error\":{\"message\":\"This thread has reached its inference spending cap.\",\"type\":\"rate_limit_error\"}}"
  // Other threads are under their own caps.
  let result = post_later(setup, completions("j"), [auth("j")])
  reply_json(next_arrival(setup), 200, "{}")
  let assert Ok(gun.Response(status: 200, ..)) = answered(result)
  // A per-thread override lifts it.
  proxy.set_thread_cap(setup.proxy, "k", Some(meter.unlimited))
  let result = post_later(setup, completions("k"), [auth("k")])
  reply_json(next_arrival(setup), 200, "{}")
  let assert Ok(gun.Response(status: 200, ..)) = answered(result)
}

pub fn instance_cap_in_dollars_test() {
  let setup =
    setup_with(fn(config) {
      proxy.Config(..config, instance_cap: Cap(tokens: None, usd: Some(0.2)))
    })
  let result = post_later(setup, completions("a"), [auth("a")])
  reply_json(next_arrival(setup), 200, usage_json)
  let assert Ok(gun.Response(status: 200, ..)) = answered(result)
  let assert Ok(gun.Response(status: 429, body:, ..)) =
    post(setup, completions("b"), [auth("b")])
  let assert True = string.contains(bits(body), "instance")
}

pub fn requests_in_flight_per_thread_are_limited_test() {
  let setup =
    setup_with(fn(config) { proxy.Config(..config, max_per_thread: 1) })
  let _ = open_stream(setup, "k")
  let #(_, steps) = upstream_stream(setup)
  let assert gun.StreamResponse(status: 200, ..) = next_message()
  // The thread's one slot is taken: rejected before reaching upstream.
  let assert Ok(gun.Response(status: 429, body:, ..)) =
    post(setup, completions("k"), [auth("k")])
  let assert True = string.contains(bits(body), "in flight")
  let assert Error(Nil) = process.receive(setup.arrivals, 100)
  // Another thread has its own.
  let result = post_later(setup, completions("j"), [auth("j")])
  reply_json(next_arrival(setup), 200, "{}")
  let assert Ok(gun.Response(status: 200, ..)) = answered(result)
  // Once the stream ends the slot is free again.
  process.send(steps, Finish)
  let _ = rest_of_body("")
  process.sleep(50)
  let result = post_later(setup, completions("k"), [auth("k")])
  reply_json(next_arrival(setup), 200, "{}")
  let assert Ok(gun.Response(status: 200, ..)) = answered(result)
}

pub fn a_stream_crossing_the_cap_is_cut_test() {
  let setup =
    setup_with(fn(config) {
      proxy.Config(..config, thread_cap: Cap(tokens: Some(20), usd: None))
    })
  let _ = open_stream(setup, "k")
  let #(_, steps) = upstream_stream(setup)
  let assert gun.StreamResponse(status: 200, ..) = next_message()
  process.send(steps, Send(sse_text))
  let assert gun.Data(data:, fin: False, ..) = next_message()
  let assert True = bits(data) == sse_text
  // Meanwhile another request from the thread spends past the cap.
  let result = post_later(setup, completions("k"), [auth("k")])
  reply_json(
    next_arrival(setup),
    200,
    "{\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":5}}",
  )
  let assert Ok(gun.Response(status: 200, ..)) = answered(result)
  // The stream's next chunk is replaced by an error event, and it ends.
  // That chunk's usage is still counted.
  process.send(steps, Send(sse_usage))
  let rest = rest_of_body("")
  let assert True =
    rest
    == "data: {\"error\":{\"message\":\"This thread has reached its inference spending cap.\",\"type\":\"rate_limit_error\"}}\n\n"
  let assert meter.Usage(120, 25, 0.5, 2) = proxy.totals(setup.proxy, "k")
  // And upstream is closed.
  let assert Ok(Nil) = process.receive(setup.closed, 2000)
}

pub fn revoke_then_restore_test() {
  let setup = setup()
  proxy.revoke(setup.proxy, "k")
  let assert Ok(gun.Response(status: 403, body:, ..)) =
    post(setup, completions("k"), [auth("k")])
  let assert True = string.contains(bits(body), "\"permission_error\"")
  let assert Error(Nil) = process.receive(setup.arrivals, 100)
  proxy.restore(setup.proxy, "k")
  let result = post_later(setup, completions("k"), [auth("k")])
  reply_json(next_arrival(setup), 200, "{}")
  let assert Ok(gun.Response(status: 200, ..)) = answered(result)
  // Revoking cuts a stream in flight too.
  let _ = open_stream(setup, "k")
  let #(_, steps) = upstream_stream(setup)
  let assert gun.StreamResponse(status: 200, ..) = next_message()
  proxy.revoke(setup.proxy, "k")
  process.send(steps, Send(sse_text))
  let assert True = string.contains(rest_of_body(""), "\"permission_error\"")
}

pub fn a_client_that_goes_away_cancels_upstream_test() {
  let setup = setup()
  let #(conn, _) = open_stream(setup, "k")
  let #(_, steps) = upstream_stream(setup)
  let assert gun.StreamResponse(status: 200, ..) = next_message()
  process.send(steps, Send(sse_text))
  let assert gun.Data(..) = next_message()
  gun.close(conn)
  // Upstream sends nothing more, yet sees its connection close.
  let assert Ok(Nil) = process.receive(setup.closed, 2000)
  // Usage received before the client left is still settled.
  let _ = open_stream(setup, "j")
  let #(_, steps) = upstream_stream(setup)
  let assert gun.StreamResponse(status: 200, ..) = next_message()
  process.send(steps, Send(sse_usage))
  let assert gun.Data(..) = next_message()
}

pub fn a_client_that_goes_away_before_the_answer_cancels_upstream_test() {
  let setup = setup()
  let #(conn, _) = open_stream(setup, "k")
  let #(_, steps) = upstream_stream(setup)
  // The head is held back while upstream "thinks"; the proxy is waiting.
  let _ = steps
  gun.close(conn)
  let assert Ok(Nil) = process.receive(setup.closed, 2000)
}

pub fn a_client_that_goes_away_stops_the_writer_and_upstream_test() {
  let setup = setup()
  let client =
    raw_open(setup.port, raw_post("k", "content-length: 2\r\n\r\n{}"))
  let #(_, steps) = upstream_stream(setup)
  process.send(steps, Send(sse_text))
  process.sleep(200)
  // The writer mist started owns the client's socket by now.
  let writer = peer_owner(client)
  let assert True = alive(writer)
  raw_close(client)
  let assert Ok(Nil) = process.receive(setup.closed, 2000)
  let assert True = gone_within(writer, 2000)
}

fn gone_within(pid: Pid, ms: Int) -> Bool {
  case alive(pid), ms <= 0 {
    False, _ -> True
    True, True -> False
    True, False -> {
      process.sleep(20)
      gone_within(pid, ms - 20)
    }
  }
}

pub fn a_slow_upload_times_out_and_frees_its_slot_test() {
  let setup =
    setup_with(fn(config) {
      proxy.Config(..config, upload_timeout_ms: 300, max_uploads: 1)
    })
  let assert "HTTP/1.1 408 " <> _ =
    raw_exchange(setup.port, raw_post("k", "content-length: 100\r\n\r\n{"))
  let assert Error(Nil) = process.receive(setup.arrivals, 100)
  // The one upload slot is free again.
  let result = post_later(setup, completions("k"), [auth("k")])
  reply_json(next_arrival(setup), 200, "{}")
  let assert Ok(gun.Response(status: 200, ..)) = answered(result)
}

pub fn revoking_during_an_upload_stops_the_request_test() {
  let setup = setup()
  let client = raw_open(setup.port, raw_post("k", "content-length: 2\r\n\r\n{"))
  process.sleep(100)
  proxy.revoke(setup.proxy, "k")
  raw_send(client, "}")
  let assert "HTTP/1.1 403 " <> _ = raw_read_line(client)
  let assert Error(Nil) = process.receive(setup.arrivals, 200)
  raw_close(client)
}

pub fn a_slow_reader_holds_upstream_back_test() {
  let setup = setup()
  let client =
    raw_open(setup.port, raw_post("k", "content-length: 2\r\n\r\n{}"))
  let #(_, steps) = upstream_stream(setup)
  let progress = process.new_subject()
  // 64 MB, far more than every socket buffer on the way can hold.
  process.send(steps, Flood(2000, 32_768, progress))
  process.sleep(1500)
  let sent = last_progress(progress, 0)
  let assert True = sent < 2000
  // Nothing on the way has queued up what the client hasn't read.
  let assert True = max_queue(process.self()) < 50
  // Upstream is stuck, not finished: a second look sees about the same.
  process.sleep(300)
  let assert True = last_progress(progress, sent) - sent <= 50
  raw_close(client)
  let assert Ok(Nil) = process.receive(setup.closed, 3000)
}

fn last_progress(progress: Subject(Int), last: Int) -> Int {
  case process.receive(progress, 0) {
    Ok(n) -> last_progress(progress, n)
    Error(Nil) -> last
  }
}

pub fn request_bodies_are_bounded_test() {
  let setup = setup()
  let assert "HTTP/1.1 411 Length Required" =
    raw_exchange(
      setup.port,
      raw_post("k", "transfer-encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n"),
    )
  let assert "HTTP/1.1 413 Payload Too Large" =
    raw_exchange(
      setup.port,
      raw_post("k", "content-length: 64000001\r\n\r\n{}"),
    )
  let assert Error(Nil) = process.receive(setup.arrivals, 100)
}

pub fn uploads_at_once_are_limited_test() {
  let setup = setup_with(fn(config) { proxy.Config(..config, max_uploads: 1) })
  // A body that never finishes arriving holds the one upload slot.
  let stalled =
    raw_open(setup.port, raw_post("a", "content-length: 1000\r\n\r\n{"))
  process.sleep(100)
  let assert Ok(gun.Response(status: 429, body:, ..)) =
    post(setup, completions("b"), [auth("b")])
  let assert True = string.contains(bits(body), "busy")
  raw_close(stalled)
}

pub fn upstream_must_be_https_test() {
  let assert Error(reason) = proxy.start(config("http://hyper.example.com"))
  let assert False = string.contains(reason, "example")
  let assert Error(_) = proxy.start(config("ftp://hyper.example.com"))
  let assert Error(_) = proxy.start(config("hyper.example.com"))
  let assert Ok(_) = proxy.start(config("https://hyper.example.com"))
  let assert Ok(_) = proxy.start(config("http://127.0.0.1:1"))
  let assert Ok(_) = proxy.start(config("http://localhost:1"))
  let assert Ok(_) = proxy.start(config("http://127.1.2.3:1"))
  let assert Ok(_) = proxy.start(config("http://[::1]:1"))
  // Names that only look like loopback addresses.
  let assert Error(_) = proxy.start(config("http://127.evil.com"))
  let assert Error(_) = proxy.start(config("http://127.0.0.1.nip.io"))
  let assert Error(_) = proxy.start(config("http://localhost.evil.com"))
  let assert Error(_) = proxy.start(config("http://10.0.0.1"))
}

pub fn unreachable_upstream_is_a_fixed_502_test() {
  let #(_, port) = start_proxy(config("http://127.0.0.1:1"))
  let setup = Setup(..setup(), port:)
  let assert Ok(gun.Response(status: 502, body:, ..)) =
    post(setup, completions("k"), [auth("k")])
  let assert True =
    bits(body)
    == "{\"error\":{\"message\":\"Could not reach Hyper.\",\"type\":\"server_error\"}}"
  // Paths outside /proxy are left for other routes.
  let assert Ok(gun.Response(status: 404, body:, ..)) =
    post(setup, "/mcp/k", [auth("k")])
  let assert "" = bits(body)
}

pub fn env_and_caps_test() {
  let assert ["CRUSHLING_PROXY_TOKEN=" <> t] = proxy.env(secret, "C1-1.0")
  let assert True = t == proxy.token(secret, "C1-1.0")
  let assert [
    "HYPER_URL=http://10.0.0.1:7469/proxy/C1-1.0",
    "HYPER_API_KEY=" <> t2,
  ] = proxy.crush_env("http://10.0.0.1:7469/", secret, "C1-1.0")
  let assert True = t2 == t
  let assert Ok(Cap(None, None)) = proxy.parse_cap("", "")
  let assert Ok(Cap(Some(1000), Some(2.5))) = proxy.parse_cap("1000", "2.5")
  let assert Ok(Cap(None, Some(3.0))) = proxy.parse_cap("", "3")
  let assert Error(proxy.BadTokens) = proxy.parse_cap("lots", "")
  let assert Error(proxy.BadUsd) = proxy.parse_cap("", "$5")
}

pub fn usage_scanner_test() {
  let scanner =
    usage.new("text/event-stream; charset=utf-8")
    |> usage.feed(<<"data: {\"usage\":{\"prompt_tok":utf8>>)
    |> usage.feed(<<
      "ens\":3,\"completion_tokens\":4,\"cost\":{\"usd\":1}}}\n":utf8,
    >>)
  let assert Some(meter.Usage(3, 4, 1.0, 1)) = usage.finish(scanner)
  let assert Some(meter.Usage(5, 6, 0.0, 1)) =
    usage.parse_usage("{\"usage\":{\"input_tokens\":5,\"output_tokens\":6}}")
  let assert None = usage.parse_usage("{\"choices\":[]}")
  let assert None =
    usage.new("text/plain") |> usage.feed(<<"x">>) |> usage.finish
}

// Real Hyper.

@external(erlang, "real_server_ffi", "enabled")
fn enabled() -> Bool

@external(erlang, "real_server_ffi", "api_key")
fn api_key(name: String) -> Result(String, Nil)

@external(erlang, "real_server_ffi", "env")
fn env(name: String, default: String) -> String

@external(erlang, "real_server_ffi", "expand_home")
fn expand_home(path: String) -> String

@external(erlang, "real_server_ffi", "timeout")
fn with_timeout(seconds: Int, body: fn() -> Nil) -> Dynamic

@external(erlang, "proxy_test_ffi", "run")
fn run(
  program: String,
  args: List(String),
  env: List(String),
  cwd: String,
  timeout_ms: Int,
) -> #(Int, String)

@external(erlang, "proxy_test_ffi", "tmp_dir")
fn tmp_dir() -> String

@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(a: a) -> Dynamic

pub fn real_proxy_test_() -> Dynamic {
  case enabled(), api_key("CRUSH_HYPER_API_KEY") {
    True, Ok(key) ->
      to_dynamic([
        with_timeout(60, real_tls_is_verified),
        with_timeout(120, fn() { real_stream(key) }),
        with_timeout(300, fn() { real_crush_run(key) }),
      ])
    _, _ -> to_dynamic([])
  }
}

fn real_proxy(key: String) -> #(proxy.Proxy, Int) {
  let assert Ok(p) =
    proxy.start(proxy.Config(
      secret:,
      org_key: key,
      upstream: env("CRUSHLING_PROXY_UPSTREAM", proxy.default_upstream),
      thread_cap: meter.unlimited,
      instance_cap: meter.unlimited,
      max_per_thread: proxy.default_max_per_thread,
      max_uploads: proxy.default_max_uploads,
      upload_timeout_ms: proxy.default_upload_timeout_ms,
    ))
  let route = proxy.route(p)
  let port =
    serve(fn(req) { route(req) |> option.unwrap(sandbox_http.reply(404, "")) })
  #(p, port)
}

/// gun refuses certificates that don't verify or don't match the host.
fn real_tls_is_verified() -> Nil {
  let assert Error(_) =
    gun.connect_tcp("self-signed.badssl.com", 443, True, 10_000)
  let assert Error(_) = gun.connect_tcp("expired.badssl.com", 443, True, 10_000)
  let assert Error(_) =
    gun.connect_tcp("wrong.host.badssl.com", 443, True, 10_000)
  let assert Ok(conn) = gun.connect_tcp("hyper.charm.land", 443, True, 10_000)
  gun.close(conn)
}

fn real_stream(key: String) -> Nil {
  let #(p, port) = real_proxy(key)
  let assert Ok(conn) = gun.connect_tcp("127.0.0.1", port, False, 2000)
  let _ =
    stream_request(
      conn,
      "POST",
      "/proxy/real/v1/chat/completions",
      [auth("real"), #("content-type", "application/json")],
      bit_array.from_string(
        "{\"model\":\""
        <> env("CRUSHLING_TEST_SMALL", "prism-flash")
        <> "\",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the word pong.\"}]}",
      ),
      1_000_000,
    )
  let selector = process.new_selector() |> gun.select(fn(m) { m })
  let assert gun.StreamResponse(status: 200, ..) = real_next(selector)
  let body = real_body(selector, "")
  let assert True = string.contains(body, "\"usage\"")
  let totals = proxy.totals(p, "real")
  let assert True = totals.input_tokens > 0
  let assert True = totals.output_tokens > 0
  let assert 1 = totals.requests
  Nil
}

fn real_body(selector, acc: String) -> String {
  case process.selector_receive(selector, 60_000) {
    Ok(gun.Data(data:, fin: True, ..)) -> acc <> bits(data)
    Ok(gun.Data(data:, fin: False, ..)) ->
      real_body(selector, acc <> bits(data))
    other -> panic as { "unexpected " <> string.inspect(other) }
  }
}

fn real_next(selector) -> gun.Message {
  case process.selector_receive(selector, 60_000) {
    // Earlier connections closing.
    Ok(gun.ConnDown(..)) | Ok(gun.Ignored) -> real_next(selector)
    Ok(message) -> message
    Error(Nil) -> panic as "Hyper went quiet"
  }
}

/// A whole `crush run` with the proxy as its Hyper.
fn real_crush_run(key: String) -> Nil {
  let #(p, port) = real_proxy(key)
  let home = tmp_dir()
  let crush =
    expand_home(env(
      "CRUSHLING_TEST_CRUSH",
      "~/.local/state/crushling-dev/crush",
    ))
  let #(status, output) =
    run(
      crush,
      [
        "run",
        "--quiet",
        "-m",
        "hyper/" <> env("CRUSHLING_TEST_SMALL", "prism-flash"),
        "--small-model",
        "hyper/" <> env("CRUSHLING_TEST_SMALL", "prism-flash"),
        "Reply with just the word pong and nothing else.",
      ],
      list.append(
        proxy.crush_env(
          "http://127.0.0.1:" <> int.to_string(port),
          secret,
          "crush",
        ),
        [
          "CRUSH_CLIENT_SERVER=0",
          "CRUSH_GLOBAL_CONFIG=" <> home <> "/config",
          "CRUSH_GLOBAL_DATA=" <> home <> "/data",
          "CRUSH_DISABLE_PROVIDER_AUTO_UPDATE=",
          // crush lets CRUSH_<NAME> override <NAME>.
          "CRUSH_HYPER_API_KEY=",
          "CRUSH_HYPER_URL=",
          "ANTHROPIC_API_KEY=",
          "OPENAI_API_KEY=",
          "HONCHO_API_KEY=",
        ],
      ),
      home,
      240_000,
    )
  case status {
    0 -> Nil
    _ -> {
      io.println_error(output)
      panic as { "crush run failed: " <> output }
    }
  }
  let assert True = string.contains(string.lowercase(output), "pong")
  let totals = proxy.totals(p, "crush")
  let assert True = totals.requests >= 1
  let assert True = totals.input_tokens > 0
  Nil
}
