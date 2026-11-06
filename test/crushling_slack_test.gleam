import crushling/crush/client
import crushling/launcher
import crushling/registry
import crushling/slack
import crushling/socket
import gleam/erlang/process
import gleam/json
import gleam/set
import slackline
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
  let assert Ok(registry.Incoming("C1", "10.1", "12.1", "U1", "more", False)) =
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
  let assert Ok(registry.Incoming("D1", "20.1", "20.1", "U1", "hi", True)) =
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
    )
  let assert Ok(r) =
    registry.start(registry.Config(
      launcher: fake,
      client:,
      bot_user: "UBOT",
      allowed: set.from_list(["U1"]),
      idle_ms: 50,
      flush_ms: 50,
      mode: client.Sysadmin,
    ))
  r
}

fn message(user: String, ts: String, text: String, mention: Bool) {
  registry.Received(registry.Incoming("C1", "10.1", ts, user, text, mention))
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
