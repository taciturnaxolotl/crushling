//// Dial-out tunnels: each thread's `crush server` runs with
//// `--dial ws://<bridge>/tunnel/<key>` and connects to the bridge instead
//// of listening, and the bridge exposes it again as a unix socket (the
//// shim, `<root>/s/<hash of key>.sock`), so the HTTP client is unchanged.
////
//// The pieces: `tunnel/protocol` (frames, dial URL, tokens),
//// `tunnel/endpoint` (each key's state, pure), `tunnel/hub` (the actor
//// that applies it), `tunnel/socket` (the websockets and their keepalive)
//// and `tunnel/shim` (the unix socket side).

import crushling/key as thread_key
import crushling/sandbox_http
import crushling/tunnel/endpoint
import crushling/tunnel/hub
import crushling/tunnel/protocol
import crushling/tunnel/socket
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string

/// A change in whether a thread's crush is connected.
pub type Event {
  /// A control socket said hello.
  Dialed(key: String)
  /// The control socket that said hello has gone.
  Undialed(key: String)
}

pub type Config {
  Config(
    /// The instance secret tokens are derived from.
    secret: String,
    /// The threads' root; each shim is `<root>/s/<hash of key>.sock`.
    root: String,
    /// How often every socket is pinged.
    ping_ms: Int,
    /// Pings in a row without a reply before a socket is closed.
    missed_pongs: Int,
    /// How long a shim connection waits for its data socket.
    data_timeout_ms: Int,
    /// How long a write to a shim connection may block before the
    /// connection is aborted.
    write_timeout_ms: Int,
    /// Told about `Event`s, from the tunnels' actor: it must not block.
    on_event: fn(Event) -> Nil,
  )
}

/// The production settings.
pub fn config(secret: String, root: String) -> Config {
  Config(
    secret:,
    root:,
    ping_ms: 15_000,
    missed_pongs: 2,
    data_timeout_ms: 10_000,
    write_timeout_ms: 30_000,
    on_event: fn(_) { Nil },
  )
}

/// The running tunnels.
pub opaque type Tunnels {
  Tunnels(subject: Subject(hub.Message), config: Config)
}

pub fn token(secret: String, key: String) -> String {
  protocol.token(secret, key)
}

pub fn env(secret: String, key: String) -> List(String) {
  protocol.env(secret, key)
}

pub fn dial_url(base: String, key: String) -> String {
  protocol.dial_url(base, key)
}

pub fn shim_path(root: String, key: String) -> String {
  protocol.shim_path(root, key)
}

/// Whether shims under `root` fit a unix socket path. `start` refuses a
/// root they don't fit.
pub fn check_root(root: String) -> Result(Nil, String) {
  protocol.check_root(root)
}

fn settings(config: Config) -> hub.Settings {
  hub.Settings(
    root: config.root,
    data_timeout_ms: config.data_timeout_ms,
    write_timeout_ms: config.write_timeout_ms,
    on_change: fn(change) {
      config.on_event(case change {
        endpoint.Dialed(key) -> Dialed(key)
        endpoint.Undialed(key) -> Undialed(key)
      })
    },
  )
}

fn start_hub(
  config: Config,
  name: Option(process.Name(hub.Message)),
) -> actor.StartResult(Subject(hub.Message)) {
  case check_root(config.root) {
    Error(reason) -> Error(actor.InitFailed(reason))
    Ok(Nil) -> hub.start(settings(config), name)
  }
}

/// Start the tunnels' actor, linked to the caller. Serve them with
/// `route`. Its listeners and control sockets stop if it does.
pub fn start(config: Config) -> Result(Tunnels, String) {
  use _ <- result.try(check_root(config.root))
  start_hub(config, None)
  |> result.map(fn(started) { Tunnels(subject: started.data, config:) })
  |> result.map_error(fn(error) { "tunnels: " <> string.inspect(error) })
}

/// The tunnels' actor as a supervised child registered under `name`;
/// reach it with `named`.
pub fn supervised(
  config: Config,
  name: process.Name(hub.Message),
) -> supervision.ChildSpecification(Subject(hub.Message)) {
  supervision.worker(fn() { start_hub(config, Some(name)) })
}

/// The tunnels registered under `name`.
pub fn named(config: Config, name: process.Name(hub.Message)) -> Tunnels {
  Tunnels(subject: process.named_subject(name), config:)
}

/// Start a thread's endpoint: listen on its shim and accept its crush.
/// Returns the shim's path. Opening an open endpoint returns the same path.
/// The key must be one path component of `A-Za-z0-9._-`, at most 64 long.
pub fn open(tunnels: Tunnels, key: String) -> Result(String, String) {
  use _ <- result.try(case thread_key.is_valid(key) {
    True -> Ok(Nil)
    False -> Error("not a valid tunnel key: " <> string.inspect(key))
  })
  process.call(tunnels.subject, 10_000, hub.Open(key, _))
}

/// Wait until the thread's crush has dialed in and said hello, returning
/// its version. Returns at once if it already has.
pub fn await_hello(
  tunnels: Tunnels,
  key: String,
  timeout_ms: Int,
) -> Result(String, String) {
  let reply = process.new_subject()
  process.send(tunnels.subject, hub.AwaitHello(key, reply))
  case process.receive(reply, timeout_ms) {
    Ok(result) -> result
    Error(Nil) -> {
      process.send(tunnels.subject, hub.ForgetWaiter(key, reply))
      Error(
        "crush did not dial in within " <> int.to_string(timeout_ms) <> "ms",
      )
    }
  }
}

/// Tell the thread's crush to exit and not redial.
pub fn bye(tunnels: Tunnels, key: String) -> Nil {
  process.send(tunnels.subject, hub.Bye(key))
}

/// Close a thread's endpoint: its shim, its connections and its sockets.
pub fn close(tunnels: Tunnels, key: String) -> Nil {
  process.send(tunnels.subject, hub.Close(key))
}

/// Whether the thread's crush is dialed in and has said hello.
pub fn dialed(tunnels: Tunnels, key: String) -> Bool {
  process.call(tunnels.subject, 5000, hub.IsDialed(key, _))
}

/// The ids of shim connections still waiting for a data socket, for
/// diagnostics and tests.
pub fn pending(tunnels: Tunnels, key: String) -> List(Int) {
  process.call(tunnels.subject, 5000, hub.PendingIds(key, _))
}

/// The route that accepts tunnels at `/tunnel/<key>/...`.
pub fn route(tunnels: Tunnels) -> sandbox_http.Route {
  let config = tunnels.config
  socket.route(
    tunnels.subject,
    socket.Settings(
      secret: config.secret,
      ping_ms: config.ping_ms,
      missed_pongs: config.missed_pongs,
    ),
  )
}
