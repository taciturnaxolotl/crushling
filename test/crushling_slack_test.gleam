import crushling/crush/client
import crushling/launcher
import crushling/meta
import crushling/registry
import crushling/slack
import crushling/socket
import gleam/erlang/process
import gleam/json
import gleam/set
import slackline
import slackline/app
import slackline/event

pub fn prompt_text_test() {
  let assert "fix the build" =
    slack.prompt_text("<@UBOT> fix the build", "UBOT")
  let assert "see https://x.dev/a?b=1&c=2 and <@U2>" =
    slack.prompt_text(
      "<@UBOT> see <https://x.dev/a?b=1&amp;c=2|x.dev> and <@U2>",
      "UBOT",
    )
  let assert "if a < b && c > d" =
    slack.prompt_text("if a &lt; b &amp;&amp; c &gt; d", "UBOT")
  let assert "mail mailto:a@b.c in <#C1|general>" =
    slack.prompt_text("mail <mailto:a@b.c|a@b.c> in <#C1|general>", "UBOT")
  let assert "" = slack.prompt_text("  <@UBOT>  ", "UBOT")
}

pub fn command_test() {
  let assert slack.StopCommand = slack.command("!stop")
  let assert slack.StopCommand = slack.command("Cancel")
  let assert slack.HelpCommand = slack.command(" !help ")
  let assert slack.SideComment = slack.command("## not for the bot")
  let assert slack.NotACommand = slack.command("stop the server")
}

fn decode_event(raw: String) -> event.Event {
  let assert Ok(decoded) = json.parse(raw, event.event_decoder())
  decoded
}

pub fn mention_starts_a_thread_test() {
  let mention =
    decode_event(
      "{\"type\":\"app_mention\",\"user\":\"U1\",\"text\":\"<@UBOT> hi\",\"ts\":\"10.1\",\"channel\":\"C1\",\"event_ts\":\"10.1\"}",
    )
  let assert Ok(registry.Incoming(
    "C1",
    "10.1",
    "10.1",
    "U1",
    "<@UBOT> hi",
    True,
    [],
  )) = socket.incoming(mention, "UBOT")

  let in_thread =
    decode_event(
      "{\"type\":\"app_mention\",\"user\":\"U1\",\"text\":\"<@UBOT> hi\",\"ts\":\"11.1\",\"thread_ts\":\"10.1\",\"channel\":\"C1\"}",
    )
  let assert Ok(registry.Incoming(thread_ts: "10.1", ts: "11.1", ..)) =
    socket.incoming(in_thread, "UBOT")
}

pub fn thread_replies_route_test() {
  let reply =
    decode_event(
      "{\"type\":\"message\",\"user\":\"U1\",\"text\":\"more\",\"ts\":\"12.1\",\"thread_ts\":\"10.1\",\"channel\":\"C1\",\"channel_type\":\"channel\"}",
    )
  let assert Ok(registry.Incoming("C1", "10.1", "12.1", "U1", "more", False, [])) =
    socket.incoming(reply, "UBOT")

  // The app_mention for the same message is the one that counts.
  let mentioning =
    decode_event(
      "{\"type\":\"message\",\"user\":\"U1\",\"text\":\"<@UBOT> more\",\"ts\":\"12.2\",\"thread_ts\":\"10.1\",\"channel\":\"C1\",\"channel_type\":\"channel\"}",
    )
  let assert Error(Nil) = socket.incoming(mentioning, "UBOT")

  let top_level =
    decode_event(
      "{\"type\":\"message\",\"user\":\"U1\",\"text\":\"hello all\",\"ts\":\"13.1\",\"channel\":\"C1\",\"channel_type\":\"channel\"}",
    )
  let assert Error(Nil) = socket.incoming(top_level, "UBOT")

  let from_bot =
    decode_event(
      "{\"type\":\"message\",\"user\":\"U9\",\"bot_id\":\"B1\",\"text\":\"echo\",\"ts\":\"14.1\",\"thread_ts\":\"10.1\",\"channel\":\"C1\",\"channel_type\":\"channel\"}",
    )
  let assert Error(Nil) = socket.incoming(from_bot, "UBOT")
}

pub fn direct_messages_start_threads_test() {
  let dm =
    decode_event(
      "{\"type\":\"message\",\"user\":\"U1\",\"text\":\"hi\",\"ts\":\"20.1\",\"channel\":\"D1\",\"channel_type\":\"im\"}",
    )
  let assert Ok(registry.Incoming("D1", "20.1", "20.1", "U1", "hi", True, [])) =
    socket.incoming(dm, "UBOT")
}

type Launch {
  Launched(String)
  Stopped(String)
}

/// A registry whose launcher always fails, so no agent is ever needed,
/// and whose Slack calls go nowhere.
fn start_registry(launches: process.Subject(Launch)) {
  let assert Ok(client) =
    slackline.new("xoxb-test")
    |> slackline.with_base_url("http://127.0.0.1:1/api")
  let fake =
    launcher.Launcher(
      launch: fn(key) {
        process.send(launches, Launched(key))
        Error("no agents in this test")
      },
      stop: fn(key) { process.send(launches, Stopped(key)) },
      exists: fn(key) {
        key == registry.key("C9", "1.0") || key == registry.key("C7", "1.0")
      },
      meta_path: fn(key) { "/tmp/crushling-registry-test/" <> key <> ".json" },
      attachments: fn(key) {
        #("/tmp/crushling-registry-test/" <> key, ".slack")
      },
    )
  let assert Ok(r) =
    registry.start(registry.Config(
      launcher: fake,
      client:,
      token: "xoxb-test",
      bot_user: "UBOT",
      allowed: set.from_list(["U1"]),
      idle_ms: 50,
      flush_ms: 50,
      mode: client.Sysadmin,
    ))
  r
}

fn message(user: String, ts: String, text: String, mention: Bool) {
  registry.Received(
    registry.Incoming("C1", "10.1", ts, user, text, mention, []),
  )
}

pub fn registry_routing_test() {
  let launches = process.new_subject()
  let r = start_registry(launches)
  let expected = registry.key("C1", "10.1")

  // Someone not on the allowlist can't start anything.
  process.send(r, message("U2", "10.1", "<@UBOT> hi", True))
  // A reply in a thread the bot isn't in is ignored.
  process.send(r, message("U1", "10.2", "hello", False))
  // A bare mention has no prompt, and asides and commands start nothing.
  process.send(r, message("U1", "10.3", "<@UBOT>", True))
  process.send(r, message("U1", "10.31", "<@UBOT> ## just us", True))
  process.send(r, message("U1", "10.32", "<@UBOT> !stop", True))
  let assert Error(Nil) = process.receive(launches, 100)

  process.send(r, message("U1", "10.4", "<@UBOT> do it", True))
  let assert Ok(Launched(key)) = process.receive(launches, 1000)
  let assert True = key == expected

  // The launch failed, so the thread is forgotten; a redelivery of the same
  // message is still ignored, and a new mention tries again.
  process.sleep(50)
  process.send(r, message("U1", "10.4", "<@UBOT> do it", True))
  let assert Error(Nil) = process.receive(launches, 100)
  process.send(r, message("U1", "10.5", "<@UBOT> again", True))
  let assert Ok(Launched(_)) = process.receive(launches, 1000)
  let assert Error(Nil) = process.receive(launches, 100)
  Nil
}

pub fn replies_resume_threads_from_before_a_restart_test() {
  let launches = process.new_subject()
  let r = start_registry(launches)
  // C9's thread has a workspace on disk, but this registry never saw it.
  process.send(
    r,
    registry.Received(
      registry.Incoming("C9", "1.0", "5.0", "U1", "more", False, []),
    ),
  )
  let assert Ok(Launched(key)) = process.receive(launches, 1000)
  let assert True = key == registry.key("C9", "1.0")
  // A reply in a thread with no workspace is still ignored.
  process.send(
    r,
    registry.Received(
      registry.Incoming("C8", "1.0", "5.0", "U1", "more", False, []),
    ),
  )
  let assert Error(Nil) = process.receive(launches, 100)
  Nil
}

pub fn shutdown_with_nothing_running_stops_at_once_test() {
  let launches = process.new_subject()
  let r = start_registry(launches)
  let done = process.new_subject()
  process.send(r, registry.Shutdown(60_000, done))
  let assert Ok(Nil) = process.receive(done, 1000)
}

pub fn native_stop_reaches_the_registry_test() {
  let registry = process.new_subject()
  let router = socket.router(registry, "UBOT")
  let frame =
    "{\"envelope_id\":\"e2\",\"type\":\"events_api\",\"accepts_response_payload\":false,\"retry_attempt\":0,\"retry_reason\":\"\",\"payload\":{\"token\":\"t\",\"team_id\":\"T1\",\"api_app_id\":\"A1\",\"type\":\"event_callback\",\"event_id\":\"Ev1\",\"event_time\":1,\"event\":{\"type\":\"agent_session_stopped\",\"channel\":\"C1\",\"user\":\"U1\",\"thread_ts\":\"10.1\",\"streaming_message_ts\":[],\"event_ts\":\"12.0\"}}}"
  let assert app.Send(after:, ..) = app.handle_socket(router, frame)
  after()
  let assert Ok(registry.StopRequested("C1", "10.1", "U1")) =
    process.receive(registry, 1000)
}

@external(erlang, "crushling_ffi", "mkdir_p")
fn mkdir_p(path: String) -> Result(Nil, String)

pub fn follow_mode_test() {
  let launches = process.new_subject()
  let assert Ok(Nil) = mkdir_p("/tmp/crushling-registry-test")
  // C7's thread is on disk, joined partway through: not following.
  let assert Ok(Nil) =
    meta.write(
      "/tmp/crushling-registry-test/" <> registry.key("C7", "1.0") <> ".json",
      meta.Meta(follow: False, cursor: "3.0"),
    )
  let r = start_registry(launches)
  let reply = fn(ts, text, mention) {
    registry.Received(
      registry.Incoming("C7", "1.0", ts, "U1", text, mention, []),
    )
  }
  // A plain reply is chatter for the next turn, not a prompt.
  process.send(r, reply("4.0", "just talking", False))
  let assert Error(Nil) = process.receive(launches, 100)
  // A mention is.
  process.send(r, reply("5.0", "<@UBOT> now you", True))
  let assert Ok(Launched(_)) = process.receive(launches, 1000)

  // A thread started from its first message follows every reply.
  process.send(
    r,
    registry.Received(
      registry.Incoming("C6", "2.0", "2.0", "U1", "<@UBOT> go", True, []),
    ),
  )
  let assert Ok(Launched(key)) = process.receive(launches, 1000)
  let assert Ok(meta.Meta(follow: True, ..)) =
    meta.read("/tmp/crushling-registry-test/" <> key <> ".json")
  // Mentioned partway into a thread: answers mentions only.
  process.send(
    r,
    registry.Received(
      registry.Incoming("C5", "2.0", "2.5", "U1", "<@UBOT> hi", True, []),
    ),
  )
  let assert Ok(Launched(key)) = process.receive(launches, 1000)
  let assert Ok(meta.Meta(follow: False, ..)) =
    meta.read("/tmp/crushling-registry-test/" <> key <> ".json")
  Nil
}
