import crushling/crush/client
import crushling/launcher
import crushling/meta
import crushling/registry
import crushling/registry/incoming as msg
import crushling/registry/tailnet
import crushling/slack
import crushling/snapshot
import crushling/socket
import crushling/tailscale
import crushling/thread
import crushling/venue
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import gleam/string
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
  let assert slack.PauseCommand = slack.command("!pause")
  let assert slack.ResumeCommand = slack.command("!Resume")
  let assert slack.DoneCommand = slack.command("!done")
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
  let assert Ok(msg.Incoming("C1", "10.1", "10.1", "U1", "<@UBOT> hi", True, [])) =
    socket.incoming(mention, "UBOT")

  let in_thread =
    decode_event(
      "{\"type\":\"app_mention\",\"user\":\"U1\",\"text\":\"<@UBOT> hi\",\"ts\":\"11.1\",\"thread_ts\":\"10.1\",\"channel\":\"C1\"}",
    )
  let assert Ok(msg.Incoming(thread_ts: "10.1", ts: "11.1", ..)) =
    socket.incoming(in_thread, "UBOT")
}

pub fn thread_replies_route_test() {
  let reply =
    decode_event(
      "{\"type\":\"message\",\"user\":\"U1\",\"text\":\"more\",\"ts\":\"12.1\",\"thread_ts\":\"10.1\",\"channel\":\"C1\",\"channel_type\":\"channel\"}",
    )
  let assert Ok(msg.Incoming("C1", "10.1", "12.1", "U1", "more", False, [])) =
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
  // Routed in case it is in a code channel; the registry drops it
  // anywhere else.
  let assert Ok(msg.Incoming(thread_ts: "13.1", ts: "13.1", mention: False, ..)) =
    socket.incoming(top_level, "UBOT")

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
  let assert Ok(msg.Incoming("D1", "20.1", "20.1", "U1", "hi", True, [])) =
    socket.incoming(dm, "UBOT")
}

type Launch {
  Launched(String)
  Stopped(String)
}

/// A registry whose launcher always fails, so no agent is ever needed,
/// and whose Slack calls go nowhere.
fn start_registry(launches: process.Subject(Launch)) {
  start_registry_with(launches, None)
}

fn start_registry_with(
  launches: process.Subject(Launch),
  tailnet: Option(tailnet.Setup),
) {
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
      workspace: fn(key) { "/tmp/crushling-registry-test/" <> key },
      attachments: fn(key) {
        #("/tmp/crushling-registry-test/" <> key, ".slack")
      },
      run_in_sandbox: None,
    )
  let assert Ok(r) =
    registry.start(registry.Config(
      launcher: fake,
      client:,
      token: "xoxb-test",
      bot_user: "UBOT",
      team: "T1",
      allowed: set.from_list(["U1"]),
      idle_ms: 50,
      flush_ms: 50,
      mode: client.Sysadmin,
      tailnet:,
    ))
  r
}

fn message(user: String, ts: String, text: String, mention: Bool) {
  registry.Received(msg.Incoming("C1", "10.1", ts, user, text, mention, []))
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
    registry.Received(msg.Incoming("C9", "1.0", "5.0", "U1", "more", False, [])),
  )
  let assert Ok(Launched(key)) = process.receive(launches, 1000)
  let assert True = key == registry.key("C9", "1.0")
  // A reply in a thread with no workspace is still ignored.
  process.send(
    r,
    registry.Received(msg.Incoming("C8", "1.0", "5.0", "U1", "more", False, [])),
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

@external(erlang, "crushling_ffi", "write_private")
fn write_file(path: String, content: String) -> Result(Nil, String)

pub fn follow_mode_test() {
  let launches = process.new_subject()
  let assert Ok(Nil) = mkdir_p("/tmp/crushling-registry-test")
  // C7's thread is on disk, joined partway through: not following.
  let assert Ok(Nil) =
    meta.write(
      "/tmp/crushling-registry-test/" <> registry.key("C7", "1.0") <> ".json",
      meta.Meta(..meta.new(False), cursor: "3.0"),
    )
  let r = start_registry(launches)
  let reply = fn(ts, text, mention) {
    registry.Received(msg.Incoming("C7", "1.0", ts, "U1", text, mention, []))
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
      msg.Incoming("C6", "2.0", "2.0", "U1", "<@UBOT> go", True, []),
    ),
  )
  let assert Ok(Launched(key)) = process.receive(launches, 1000)
  let assert Ok(meta.Meta(follow: True, ..)) =
    meta.read("/tmp/crushling-registry-test/" <> key <> ".json")
  // Mentioned partway into a thread: answers mentions only.
  process.send(
    r,
    registry.Received(
      msg.Incoming("C5", "2.0", "2.5", "U1", "<@UBOT> hi", True, []),
    ),
  )
  let assert Ok(Launched(key)) = process.receive(launches, 1000)
  let assert Ok(meta.Meta(follow: False, ..)) =
    meta.read("/tmp/crushling-registry-test/" <> key <> ".json")
  Nil
}

pub fn code_channel_messages_reach_their_thread_test() {
  let launches = process.new_subject()
  let assert Ok(Nil) = mkdir_p("/tmp/crushling-registry-test")
  // CCODE holds the work of C9's thread, which is on disk.
  let assert Ok(Nil) =
    meta.write_link(
      "/tmp/crushling-registry-test/"
        <> registry.key("CCODE", "code")
        <> ".json",
      meta.Link(origin_channel: "C9", origin_ts: "1.0", opened_ts: ""),
    )
  let r = start_registry(launches)
  // Top-level chatter in another channel reaches nobody.
  process.send(
    r,
    registry.Received(
      msg.Incoming("C4", "8.0", "8.0", "U1", "hello all", False, []),
    ),
  )
  let assert Error(Nil) = process.receive(launches, 100)
  // In the code channel, an unmentioned top-level message is a prompt for
  // the thread that moved there.
  process.send(
    r,
    registry.Received(
      msg.Incoming("CCODE", "9.0", "9.0", "U1", "now the tests", False, []),
    ),
  )
  let assert Ok(Launched(key)) = process.receive(launches, 1000)
  let assert True = key == registry.key("C9", "1.0")
}

pub fn native_stop_in_a_code_channel_test() {
  let registry = process.new_subject()
  let router = socket.router(registry, "UBOT")
  let frame =
    "{\"envelope_id\":\"e3\",\"type\":\"events_api\",\"accepts_response_payload\":false,\"retry_attempt\":0,\"retry_reason\":\"\",\"payload\":{\"token\":\"t\",\"team_id\":\"T1\",\"api_app_id\":\"A1\",\"type\":\"event_callback\",\"event_id\":\"Ev2\",\"event_time\":1,\"event\":{\"type\":\"agent_session_stopped\",\"channel\":\"CCODE\",\"user\":\"U1\",\"streaming_message_ts\":[],\"event_ts\":\"12.0\"}}}"
  let assert app.Send(after:, ..) = app.handle_socket(router, frame)
  after()
  let assert Ok(registry.StopRequested("CCODE", "", "U1")) =
    process.receive(registry, 1000)
}

pub fn repo_helpers_test() {
  let assert True = snapshot.is_clone("cd /w && git clone https://x/y.git")
  let assert True = snapshot.is_clone("gh repo clone owner/repo")
  let assert False = snapshot.is_clone("git status")
  let assert "owner/repo" =
    snapshot.repo_name("https://github.com/owner/repo.git")
  let assert "owner/repo" = snapshot.repo_name("git@github.com:owner/repo.git")
  let assert "https://github.com/owner/repo" =
    snapshot.web_url("git@github.com:owner/repo.git")
  let assert "https://github.com/owner/repo" =
    snapshot.web_url("https://github.com/owner/repo.git")
  let assert "https://github.com/owner/repo" =
    snapshot.web_url("ssh://git@github.com/owner/repo.git")
  // tangled: the owner is a DID and the knot serves no page there.
  let tangled = "git@knot.dunkirk.sh:did:plc:krxbvxvis5skq7jj6eot23ul/crushling"
  let assert "crushling" = snapshot.repo_name(tangled)
  let assert "" = snapshot.web_url(tangled)
  let assert "source" = snapshot.repo_name("/tmp/x/source")
  let assert snapshot.RepoInfo(
    url: "https://github.com/owner/repo",
    branch: "fix",
    base: "main",
  ) = snapshot.parse_repo_info("https://github.com/owner/repo\nfix\nmain\n")
}

pub fn pause_and_resume_test() {
  let launches = process.new_subject()
  let assert Ok(Nil) = mkdir_p("/tmp/crushling-registry-test")
  let path =
    "/tmp/crushling-registry-test/" <> registry.key("C9", "1.0") <> ".json"
  let assert Ok(Nil) = meta.write(path, meta.new(True))
  let r = start_registry(launches)
  let say = fn(ts, text, mention) {
    registry.Received(msg.Incoming("C9", "1.0", ts, "U1", text, mention, []))
  }
  // Pausing a thread that is asleep only changes what it listens to.
  process.send(r, say("2.0", "!pause", False))
  process.sleep(50)
  let assert Error(Nil) = process.receive(launches, 50)
  let assert Ok(meta.Meta(paused: True, ..)) = meta.read(path)
  // Paused, a plain reply is chatter...
  process.send(r, say("3.0", "keep going", False))
  let assert Error(Nil) = process.receive(launches, 100)
  // ...but a mention still reaches the agent.
  process.send(r, say("4.0", "<@UBOT> one thing", True))
  let assert Ok(Launched(_)) = process.receive(launches, 1000)
  // `!resume` needs no mention.
  process.send(r, say("5.0", "!resume", False))
  process.sleep(50)
  let assert Ok(meta.Meta(paused: False, follow: True, ..)) = meta.read(path)
  process.send(r, say("6.0", "carry on", False))
  let assert Ok(Launched(_)) = process.receive(launches, 1000)
  Nil
}

pub fn paused_code_channels_need_a_mention_test() {
  let launches = process.new_subject()
  let assert Ok(Nil) = mkdir_p("/tmp/crushling-registry-test")
  let assert Ok(Nil) =
    meta.write_link(
      "/tmp/crushling-registry-test/"
        <> registry.key("CPAUSE", "code")
        <> ".json",
      meta.Link(origin_channel: "C7", origin_ts: "1.0", opened_ts: ""),
    )
  let assert Ok(Nil) =
    meta.write(
      "/tmp/crushling-registry-test/" <> registry.key("C7", "1.0") <> ".json",
      meta.Meta(
        ..meta.new(True),
        paused: True,
        venue: venue.CodeChannel("CPAUSE", "./demo"),
      ),
    )
  let r = start_registry(launches)
  process.send(
    r,
    registry.Received(
      msg.Incoming("CPAUSE", "9.0", "9.0", "U1", "hey", False, []),
    ),
  )
  let assert Error(Nil) = process.receive(launches, 100)
  process.send(
    r,
    registry.Received(
      msg.Incoming("CPAUSE", "9.1", "9.1", "U1", "<@UBOT> hey", True, []),
    ),
  )
  let assert Ok(Launched(_)) = process.receive(launches, 1000)
  Nil
}

pub fn the_seeded_request_is_not_run_twice_test() {
  let launches = process.new_subject()
  let assert Ok(Nil) = mkdir_p("/tmp/crushling-registry-test")
  // CSEED was opened at 100.0 for C9's thread.
  let assert Ok(Nil) =
    meta.write_link(
      "/tmp/crushling-registry-test/"
        <> registry.key("CSEED", "code")
        <> ".json",
      meta.Link(origin_channel: "C9", origin_ts: "1.0", opened_ts: "100.0"),
    )
  let r = start_registry(launches)
  let say = fn(ts, text, mention) {
    registry.Received(msg.Incoming("CSEED", ts, ts, "U1", text, mention, []))
  }
  // Slack's copy of the request, mention and all.
  process.send(r, say("100.5", "<@UBOT> fix it", True))
  let assert Error(Nil) = process.receive(launches, 100)
  process.send(r, say("130.0", "and the tests", False))
  let assert Ok(Launched(key)) = process.receive(launches, 1000)
  let assert True = key == registry.key("C9", "1.0")
}

pub fn shared_files_route_like_messages_test() {
  // A reply with an image, in a thread.
  let in_thread =
    decode_event(
      "{\"type\":\"message\",\"subtype\":\"file_share\",\"user\":\"U1\",\"text\":\"look\",\"ts\":\"15.1\",\"thread_ts\":\"10.1\",\"channel\":\"C1\",\"channel_type\":\"channel\",\"files\":[{\"id\":\"F1\",\"name\":\"image.png\",\"mimetype\":\"image/png\",\"size\":10,\"url_private\":\"https://files.slack.com/x\"}]}",
    )
  let assert Ok(msg.Incoming(
    thread_ts: "10.1",
    ts: "15.1",
    mention: False,
    files: [slack.Attachment(name: "image.png", ..)],
    ..,
  )) = socket.incoming(in_thread, "UBOT")
  // At the top of a channel, as in a code channel.
  let top =
    decode_event(
      "{\"type\":\"message\",\"subtype\":\"file_share\",\"user\":\"U1\",\"text\":\"\",\"ts\":\"16.1\",\"channel\":\"CCODE\",\"channel_type\":\"channel\",\"files\":[]}",
    )
  let assert Ok(msg.Incoming(thread_ts: "16.1", mention: False, ..)) =
    socket.incoming(top, "UBOT")
}

pub fn done_archives_the_code_channel_test() {
  let launches = process.new_subject()
  let assert Ok(Nil) = mkdir_p("/tmp/crushling-registry-test")
  let thread_path =
    "/tmp/crushling-registry-test/" <> registry.key("C9", "1.0") <> ".json"
  let assert Ok(Nil) =
    meta.write_link(
      "/tmp/crushling-registry-test/"
        <> registry.key("CDONE", "code")
        <> ".json",
      meta.Link(origin_channel: "C9", origin_ts: "1.0", opened_ts: ""),
    )
  let assert Ok(Nil) =
    meta.write(
      thread_path,
      meta.Meta(..meta.new(True), venue: venue.CodeChannel("CDONE", "./demo")),
    )
  let r = start_registry(launches)
  process.send(
    r,
    registry.Received(
      msg.Incoming("CDONE", "50.0", "50.0", "U1", "!done", False, []),
    ),
  )
  process.sleep(100)
  let assert Error(Nil) = process.receive(launches, 50)
  let assert Ok(meta.Meta(venue: venue.Archived("./demo"), ..)) =
    meta.read(thread_path)
  Nil
}

pub fn late_deliveries_are_not_run_again_test() {
  let launches = process.new_subject()
  let assert Ok(Nil) = mkdir_p("/tmp/crushling-registry-test")
  // The agent's last prompt was the message at 5.0, so it has read 4.0.
  let assert Ok(Nil) =
    meta.write(
      "/tmp/crushling-registry-test/" <> registry.key("C9", "1.0") <> ".json",
      meta.Meta(..meta.new(True), cursor: "5.0"),
    )
  let r = start_registry(launches)
  let say = fn(ts) {
    registry.Received(
      msg.Incoming("C9", "1.0", ts, "U1", "<@UBOT> again?", True, []),
    )
  }
  process.send(r, say("4.0"))
  let assert Error(Nil) = process.receive(launches, 100)
  process.send(r, say("6.0"))
  let assert Ok(Launched(_)) = process.receive(launches, 1000)
  // Other tests share C9's thread.
  let assert Ok(Nil) =
    meta.write(
      "/tmp/crushling-registry-test/" <> registry.key("C9", "1.0") <> ".json",
      meta.new(True),
    )
  Nil
}

pub fn messages_wait_while_a_code_channel_opens_test() {
  let launches = process.new_subject()
  let r = start_registry(launches)
  let opener = registry.key("C3", "1.0")
  process.send(r, registry.FromThread(opener, thread.Opening))
  // Possibly the new channel's seed: held until the thread says where it
  // went.
  process.send(
    r,
    registry.Received(
      msg.Incoming("CNEW", "5.0", "5.0", "U1", "<@UBOT> go", True, []),
    ),
  )
  let assert Error(Nil) = process.receive(launches, 400)
  process.send(
    r,
    registry.FromThread(opener, thread.Moved(venue.ThreadOnly("./demo"), "")),
  )
  let assert Ok(Launched(key)) = process.receive(launches, 1000)
  let assert True = key == registry.key("CNEW", "5.0")
}

pub fn meta_keeps_the_venue_test() {
  let assert Ok(Nil) = mkdir_p("/tmp/crushling-registry-test")
  let path = "/tmp/crushling-registry-test/venue.json"
  let venues = [
    venue.Thread,
    venue.ThreadOnly("./demo"),
    venue.CodeChannel("CCODE", "./demo"),
    venue.Archived("./demo"),
  ]
  list.each(venues, fn(venue) {
    let saved =
      meta.Meta(
        ..meta.new(True),
        cursor: "4.0",
        venue:,
        tailnet: Some(meta.Grant(
          until_ms: 1_800_000_000_000,
          card: meta.Card("C9", "2.0", "1.0"),
        )),
      )
    let assert Ok(Nil) = meta.write(path, saved)
    let assert Ok(read) = meta.read(path)
    let assert True = read == saved
  })
  // Files from before the venue kept the channel and repository instead.
  let assert Ok(Nil) =
    write_file(
      path,
      "{\"follow\":true,\"code_channel\":\"\",\"repo\":\"./old\"}",
    )
  let assert Ok(meta.Meta(venue: venue.Archived("./old"), ..)) = meta.read(path)
}

pub fn tailscale_basics_test() {
  let assert "crushling-c9-1-0" = tailscale.hostname("C9-1.0")
  let body =
    tailscale.auth_key_request(tailscale.Config(
      tailscale.ApiKey("k"),
      tag: "tag:crushling",
      tailnet: "-",
    ))
  let assert True = string.contains(body, "\"ephemeral\":true")
  let assert True = string.contains(body, "\"reusable\":false")
  let assert True = string.contains(body, "\"tags\":[\"tag:crushling\"]")
  let assert "58 minutes" = tailnet.remaining(3_500_000)
  let assert "1 hour" = tailnet.remaining(3_700_000)
  let assert "8 hours" = tailnet.remaining(8 * 3_600_000 - 10_000)
}

pub fn tailnet_buttons_round_trip_test() {
  let assert Ok(#(tailnet.Allow(8), "C9", "1.0")) =
    tailnet.read_button("tailnet_allow_8", "C9|1.0")
  let assert Ok(#(tailnet.Deny, "C9", "1.0")) =
    tailnet.read_button("tailnet_deny", "C9|1.0")
  let assert Ok(#(tailnet.TurnOff, "C9", "1.0")) =
    tailnet.read_button("tailnet_off", "C9|1.0")
  // Only the hours the card offers.
  let assert Error(Nil) = tailnet.read_button("tailnet_allow_99", "C9|1.0")
  let assert True = list.length(tailnet.action_ids()) == 4
}

pub fn the_sandbox_is_on_the_tailnet_only_while_wanted_test() {
  let assert tailnet.Join = tailnet.step(True, None, True)
  let assert tailnet.Stay = tailnet.step(True, Some(tailnet.Joined), True)
  // A join in flight finishes first, whatever happened meanwhile.
  let assert tailnet.Stay =
    tailnet.step(False, Some(tailnet.Joining(None)), True)
  let assert tailnet.Leave(log_out: True) =
    tailnet.step(False, Some(tailnet.Joined), True)
  // A stopped container took its node with it.
  let assert tailnet.Leave(log_out: False) =
    tailnet.step(False, Some(tailnet.Joined), False)
  let assert tailnet.Stay = tailnet.step(False, None, False)
}

pub fn tailnet_access_follows_the_buttons_test() {
  let launches = process.new_subject()
  let assert Ok(Nil) = mkdir_p("/tmp/crushling-registry-test")
  let path =
    "/tmp/crushling-registry-test/" <> registry.key("C9", "1.0") <> ".json"
  let assert Ok(Nil) = meta.write(path, meta.new(True))
  let setup =
    tailnet.Setup(
      api: tailscale.Config(tailscale.ApiKey("k"), "tag:crushling", "-"),
      run: fn(_, _, _) { Ok("") },
    )
  let r = start_registry_with(launches, Some(setup))
  let card = meta.Card("C9", "2.0", "1.0")
  let press = fn(choice, user) {
    registry.Tailnet(
      registry.key("C9", "1.0"),
      tailnet.Pressed(choice, "C9", "1.0", user, card),
    )
  }
  // Someone not on the allowlist can't allow it.
  process.send(r, press(tailnet.Allow(1), "U2"))
  process.sleep(50)
  let assert Ok(meta.Meta(tailnet: None, ..)) = meta.read(path)
  process.send(r, press(tailnet.Allow(1), "U1"))
  process.sleep(50)
  let assert Ok(meta.Meta(tailnet: Some(meta.Grant(until_ms:, card: saved)), ..)) =
    meta.read(path)
  let assert True = saved == card
  let assert True = until_ms > system_ms() + 3_500_000
  process.send(r, press(tailnet.TurnOff, "U1"))
  process.sleep(50)
  let assert Ok(meta.Meta(tailnet: None, ..)) = meta.read(path)
}

@external(erlang, "crushling_ffi", "system_ms")
fn system_ms() -> Int
