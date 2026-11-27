//// One request from a sandbox, sent on to an upstream over gun, its
//// response streamed back chunk by chunk under gun's flow control: a slow
//// reader slows the upstream down rather than filling memory, and a client
//// that goes away cancels the upstream request.
////
//// The relay runs in a process of its own, started before the request body
//// is read, so a caller can count it (the inference proxy admits it with
//// its meter) and kill it if the body never comes. What differs between
//// callers comes in as `Hooks`: whether to go on, what to scan the body
//// for, and how to answer.

import crushling/gun
import gleam/bytes_tree
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mist

pub type Upstream {
  Upstream(host: String, port: Int, tls: Bool)
}

/// The request as it goes upstream; the body is sent once read.
pub type Outgoing {
  Outgoing(method: String, path: String, headers: List(#(String, String)))
}

/// What a caller decides along the way. `scan` is fed every body chunk.
pub type Hooks(scan) {
  Hooks(
    /// Whether to go on: asked once the body is in, after connecting, and
    /// before each chunk of the response is passed on.
    check: fn() -> Result(Nil, Stop),
    /// A scanner for a response of this content type.
    scan: fn(String) -> scan,
    feed: fn(scan, BitArray) -> scan,
    /// Once the response has ended or been cut, before its last piece goes
    /// out, so whatever it settles is current by the time the client sees
    /// the end.
    finish: fn(scan) -> Nil,
    /// The response head as the client should see it, or another answer in
    /// its place, upstream's body dropped.
    head: fn(Int, List(#(String, String))) ->
      Result(List(#(String, String)), Response(mist.ResponseData)),
    /// The answer when upstream couldn't be reached (502) or was too slow
    /// (504); the details go to `log`.
    failed: fn(Int) -> Response(mist.ResponseData),
    log: fn(String) -> Nil,
  )
}

/// Why `check` stopped a request.
pub type Stop {
  Stop(
    /// The answer, when the response hasn't started.
    answer: Response(mist.ResponseData),
    /// Said at the end of a body already under way, given its content type.
    tail: fn(String) -> BitArray,
  )
}

pub opaque type Relay {
  Relay(pid: Pid, go: Subject(BitArray), reply: Subject(Head), head_ms: Int)
}

/// How long upstream may take to answer, and to send each next chunk.
pub const default_head_timeout_ms = 600_000

pub const default_idle_timeout_ms = 300_000

/// Body messages gun may deliver ahead of what has been written out.
const flow_window = 8

/// Start relaying `req` to `upstream` as `outgoing`, once `send` gives it
/// the body.
pub fn start(
  upstream: Upstream,
  outgoing: Outgoing,
  req: Request(mist.Connection),
  hooks: Hooks(scan),
) -> Relay {
  start_with(
    upstream,
    outgoing,
    req,
    hooks,
    default_head_timeout_ms,
    default_idle_timeout_ms,
  )
}

pub fn start_with(
  upstream: Upstream,
  outgoing: Outgoing,
  req: Request(mist.Connection),
  hooks: Hooks(scan),
  head_ms: Int,
  idle_ms: Int,
) -> Relay {
  let job =
    Job(
      upstream:,
      outgoing:,
      hooks:,
      handler: process.self(),
      socket: socket(req.body),
      head_ms:,
      idle_ms:,
    )
  let started = process.new_subject()
  let reply = process.new_subject()
  let pid = process.spawn_unlinked(fn() { relay(job, started, reply) })
  let assert Ok(go) = process.receive(started, 5000)
  Relay(pid:, go:, reply:, head_ms:)
}

/// The relay's process, for counting it.
pub fn pid(relay: Relay) -> Pid {
  relay.pid
}

/// Give up on a relay whose body won't be sent.
pub fn cancel(relay: Relay) -> Nil {
  process.kill(relay.pid)
}

/// Send `body` upstream and answer with the response.
pub fn send(
  relay: Relay,
  req: Request(mist.Connection),
  body: BitArray,
  hooks: Hooks(scan),
) -> Response(mist.ResponseData) {
  process.send(relay.go, body)
  case respond(relay, req, hooks, fn(_) { None }) {
    Answered(resp) -> resp
    UpstreamRefused(why:, ..) -> why
  }
}

/// How an `attempt` went.
pub type Attempt(why) {
  Answered(Response(mist.ResponseData))
  /// `deny` turned down upstream's answer, dropped unread, for `why`.
  UpstreamRefused(status: Int, why: why)
}

/// Send `body` upstream, like `send`, but first let `deny` look at the
/// response status: a caller that would rather try again some other way
/// gets that instead of the response.
pub fn attempt(
  relay: Relay,
  req: Request(mist.Connection),
  body: BitArray,
  hooks: Hooks(scan),
  deny: fn(Int) -> Option(why),
) -> Attempt(why) {
  process.send(relay.go, body)
  respond(relay, req, hooks, deny)
}

pub type ReadFailure {
  TooSlow
  Unreadable
}

/// Read a request body of at most `max` bytes, within `timeout_ms`.
pub fn read_body(
  req: Request(mist.Connection),
  max: Int,
  timeout_ms: Int,
) -> Result(BitArray, ReadFailure) {
  let done = process.new_subject()
  let reader =
    process.spawn_unlinked(fn() {
      process.send(
        done,
        mist.read_body(req, max) |> result.map(fn(read) { read.body }),
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

/// Close the connection after this response: its request may not have been
/// read in full, or the client-close watcher has used the socket.
pub fn closing(resp: Response(a)) -> Response(a) {
  response.set_header(resp, "connection", "close")
}

const hop_by_hop = [
  "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
  "proxy-connection", "te", "trailer", "trailers", "transfer-encoding",
  "upgrade",
]

/// Headers without hop-by-hop ones (including any `Connection` names) or
/// any in `drop`.
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

/// What the relay tells the request handler once upstream answers.
type Head {
  Head(status: Int, headers: List(#(String, String)), body: Option(Body))
  Failed(status: Int)
  /// Stopped by the time the request was ready to go.
  Refused(stop: Stop)
}

/// Where the handler sends the writer it started, and where the writer
/// acknowledges each chunk.
type Body {
  Body(writer_to: Subject(Subject(Piece)), ack: Subject(Nil))
}

/// A piece of the response body, for the process writing it out.
type Piece {
  Piece(data: BitArray, fin: Bool)
  /// Stopped: say `tail`, then stop.
  Cut(tail: BitArray)
  Broken
  /// The client has gone; stop.
  Gone
}

type Socket

@external(erlang, "crushling_proxy_ffi", "socket")
fn socket(connection: mist.Connection) -> Socket

@external(erlang, "crushling_proxy_ffi", "wait_closed")
fn wait_closed(socket: Socket) -> Nil

type Job(scan) {
  Job(
    upstream: Upstream,
    outgoing: Outgoing,
    hooks: Hooks(scan),
    handler: Pid,
    socket: Socket,
    head_ms: Int,
    idle_ms: Int,
  )
}

fn respond(
  relay: Relay,
  req: Request(mist.Connection),
  hooks: Hooks(scan),
  deny: fn(Int) -> Option(why),
) -> Attempt(why) {
  case process.receive(relay.reply, relay.head_ms + 15_000) {
    Error(Nil) -> {
      process.kill(relay.pid)
      Answered(hooks.failed(504))
    }
    Ok(Failed(status)) -> Answered(hooks.failed(status))
    Ok(Refused(stop)) -> Answered(stop.answer)
    Ok(Head(status:, headers:, body:)) ->
      case deny(status) {
        Some(why) -> {
          process.kill(relay.pid)
          UpstreamRefused(status:, why:)
        }
        None -> Answered(passed(relay, req, hooks, status, headers, body))
      }
  }
}

/// The response as `hooks.head` has it.
fn passed(
  relay: Relay,
  req: Request(mist.Connection),
  hooks: Hooks(scan),
  status: Int,
  headers: List(#(String, String)),
  body: Option(Body),
) -> Response(mist.ResponseData) {
  case hooks.head(status, end_to_end(headers, ["content-length"])) {
    Error(answer) -> {
      process.kill(relay.pid)
      answer |> closing
    }
    Ok(headers) ->
      case body {
        None ->
          response.Response(
            status:,
            headers:,
            body: mist.Bytes(bytes_tree.new()),
          )
          |> closing
        Some(body) -> stream(relay, req, status, headers, body)
      }
  }
}

fn stream(
  relay: Relay,
  req: Request(mist.Connection),
  status: Int,
  headers: List(#(String, String)),
  body: Body,
) -> Response(mist.ResponseData) {
  let writer = process.new_subject()
  let resp =
    mist.chunked(
      req,
      response.Response(status:, headers:, body: Nil),
      fn(pieces) {
        process.send(writer, pieces)
        body.ack
      },
      write,
    )
  // The body may only flow once mist has handed the socket to the writer,
  // or a short body could finish before that.
  case process.receive(writer, 0) {
    Ok(pieces) -> process.send(body.writer_to, pieces)
    Error(Nil) -> process.kill(relay.pid)
  }
  resp
}

fn write(
  ack: Subject(Nil),
  piece: Piece,
  conn: mist.Connection,
) -> mist.ChunkNext(Subject(Nil)) {
  case piece {
    // No final chunk, so the client sees a truncated body, not an end.
    Broken -> mist.ChunkAbort("upstream broke off")
    // Stopping closes the socket the writer owns.
    Gone -> mist.ChunkStop
    Cut(tail) -> {
      let _ = case tail {
        <<>> -> Ok(Nil)
        tail -> mist.send_chunk(conn, tail)
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
          process.send(ack, Nil)
          mist.ChunkContinue(ack)
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

/// Wait for the request body, make the upstream request, report the
/// response head, then pass body pieces to the writer one flow window at a
/// time.
fn relay(
  job: Job(scan),
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
  case process.selector_receive(waiting, job.head_ms) {
    Ok(Go(body)) -> {
      // The body has been read, so the socket is quiet until the client
      // closes it.
      let gone = process.new_subject()
      let watcher =
        process.spawn(fn() {
          wait_closed(job.socket)
          process.send(gone, Nil)
        })
      // A stop may have come while the body was arriving.
      case job.hooks.check() {
        Error(stop) -> process.send(reply, Refused(stop))
        Ok(Nil) -> run(job, body, reply, handler, gone)
      }
      process.unlink(watcher)
      process.kill(watcher)
    }
    _ -> Nil
  }
}

fn run(
  job: Job(scan),
  body: BitArray,
  reply: Subject(Head),
  handler: process.Monitor,
  gone: Subject(Nil),
) -> Nil {
  let upstream = job.upstream
  case gun.connect_tcp(upstream.host, upstream.port, upstream.tls, 15_000) {
    Error(reason) -> {
      job.hooks.log("could not connect: " <> reason)
      process.send(reply, Failed(502))
    }
    Ok(conn) ->
      // Check again after the connect: the client may have left, or the
      // request been stopped, meanwhile.
      case process.receive(gone, 0), job.hooks.check() {
        Ok(Nil), _ -> {
          process.send(reply, Failed(502))
          gun.close(conn)
        }
        Error(Nil), Error(stop) -> {
          process.send(reply, Refused(stop))
          gun.close(conn)
        }
        Error(Nil), Ok(Nil) -> dispatch(job, conn, body, reply, handler, gone)
      }
  }
}

fn dispatch(
  job: Job(scan),
  conn: gun.Conn,
  body: BitArray,
  reply: Subject(Head),
  handler: process.Monitor,
  gone: Subject(Nil),
) -> Nil {
  let out = job.outgoing
  let stream =
    upstream_request(conn, out.method, out.path, out.headers, body, flow_window)
  let base =
    process.new_selector()
    |> gun.select(FromGun)
    |> process.select_map(gone, fn(_) { ClientGone })
  let before =
    base
    |> process.select_specific_monitor(handler, fn(_) { DownstreamDown })
  case await_head(job, before, conn, stream) {
    Error(#(status, reason)) -> {
      job.hooks.log(reason)
      process.send(reply, Failed(status))
    }
    Ok(#(status, headers, True)) ->
      process.send(reply, Head(status, headers, None))
    Ok(#(status, headers, False)) -> {
      let writer_to = process.new_subject()
      let ack = process.new_subject()
      process.send(reply, Head(status, headers, Some(Body(writer_to, ack))))
      // Body messages wait in the mailbox (at most a flow window of them)
      // until the writer is ready.
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
          let content_type =
            list.find_map(headers, fn(header) {
              case string.lowercase(header.0) {
                "content-type" -> Ok(header.1)
                _ -> Error(Nil)
              }
            })
            |> result.unwrap("")
          let pump =
            Pump(job:, selector: after, conn:, stream:, pieces:, content_type:)
          let #(scanner, last) = pump_on(pump, job.hooks.scan(content_type))
          job.hooks.finish(scanner)
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
  job: Job(scan),
  selector: process.Selector(Relayed),
  conn: gun.Conn,
  stream: gun.StreamRef,
) -> Result(#(Int, List(#(String, String)), Bool), #(Int, String)) {
  case process.selector_receive(selector, job.head_ms) {
    Error(Nil) -> Error(#(504, "upstream did not answer in time"))
    Ok(ClientGone) | Ok(DownstreamDown) ->
      Error(#(502, "client went away before upstream answered"))
    Ok(FromGun(gun.StreamResponse(conn: c, stream: s, status:, headers:, fin:)))
      if c == conn && s == stream
    ->
      case status < 200 {
        // An informational response; the real one follows.
        True -> await_head(job, selector, conn, stream)
        False -> Ok(#(status, headers, fin))
      }
    Ok(FromGun(gun.StreamError(conn: c, stream: s, reason:)))
      if c == conn && s == stream
    -> Error(#(502, "upstream request failed: " <> reason))
    Ok(FromGun(gun.ConnDown(conn: c, reason:))) if c == conn ->
      Error(#(502, "upstream connection closed: " <> reason))
    Ok(_) -> await_head(job, selector, conn, stream)
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

type Pump(scan) {
  Pump(
    job: Job(scan),
    selector: process.Selector(Relayed),
    conn: gun.Conn,
    stream: gun.StreamRef,
    pieces: Subject(Piece),
    content_type: String,
  )
}

/// Pass body pieces on until the stream ends. Returns what was scanned and
/// the last piece to send once `finish` has run, if any.
fn pump_on(pump: Pump(scan), scanner: scan) -> #(scan, Option(Piece)) {
  let hooks = pump.job.hooks
  let #(conn, stream) = #(pump.conn, pump.stream)
  case process.selector_receive(pump.selector, pump.job.idle_ms) {
    Error(Nil) -> {
      hooks.log("upstream went quiet")
      #(scanner, Some(Broken))
    }
    Ok(ClientGone) -> #(scanner, Some(Gone))
    // The writer is already gone.
    Ok(DownstreamDown) -> #(scanner, None)
    Ok(Written) -> {
      update_flow(conn, stream, 1)
      pump_on(pump, scanner)
    }
    Ok(FromGun(gun.Data(conn: c, stream: s, data:, fin:)))
      if c == conn && s == stream
    -> {
      // Scan first, so what has arrived is counted even if the stream is
      // cut here.
      let scanner = hooks.feed(scanner, data)
      case hooks.check(), fin {
        Error(stop), _ -> #(scanner, Some(Cut(stop.tail(pump.content_type))))
        Ok(Nil), True -> #(scanner, Some(Piece(data, True)))
        Ok(Nil), False -> {
          process.send(pump.pieces, Piece(data, False))
          pump_on(pump, scanner)
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
      hooks.log("upstream stream failed: " <> reason)
      #(scanner, Some(Broken))
    }
    Ok(FromGun(gun.ConnDown(conn: c, reason:))) if c == conn -> {
      hooks.log("upstream connection closed: " <> reason)
      #(scanner, Some(Broken))
    }
    Ok(_) -> pump_on(pump, scanner)
  }
}
