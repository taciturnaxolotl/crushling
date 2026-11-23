//// Picking a thread's model: reading crush's catalog and session, checking
//// choices, the card, `!model`, a thread pinning models on a fake `crush
//// server` (test/fake_crush_ffi.erl), and the registry waking and putting
//// to sleep a thread that only got `!model`.

import crushling/crush/client
import crushling/launcher
import crushling/meta.{DefaultReasoning, Effort, ModelChoice, Thinking}
import crushling/models
import crushling/people
import crushling/registry
import crushling/registry/incoming as msg
import crushling/render
import crushling/sink
import crushling/slack
import crushling/socket
import crushling/store
import crushling/thread
import crushling/venue
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import slackline
import slackline/block
import slackline/interaction

const catalog_json =
  "[{\"id\":\"openai\",\"models\":[{\"id\":\"gpt\"}]},{\"id\":\"hyper\",\"models\":[
  {\"id\":\"alpha\",\"name\":\"Alpha\",\"pricing\":{\"input\":1,\"output\":2.5},
   \"reasoning\":{\"thinking\":\"toggleable\",\"default_effort_level\":\"high\",
     \"effort_levels\":[{\"value\":\"low\",\"display\":\"Low\"},{\"value\":\"high\",\"display\":\"High\"}]}},
  {\"id\":\"beta\",\"name\":\"Beta\",\"pricing\":{\"input\":0.5,\"output\":1.5},
   \"reasoning\":{\"thinking\":\"toggleable\"}},
  {\"id\":\"gamma\",\"name\":\"Gamma\",\"reasoning\":{\"thinking\":\"never\"}}]}]"

fn catalog() -> List(models.Model) {
  let assert Ok(catalog) = models.parse_catalog(catalog_json)
  catalog
}

fn model(id: String) -> models.Model {
  let assert Ok(model) = models.find(catalog(), id)
  model
}

// Reading crush.

pub fn catalog_reads_the_hyper_models_test() {
  let assert ["alpha", "beta", "gamma"] =
    list.map(catalog(), fn(model) { model.id })
  let assert models.Model(
    name: "Alpha",
    input: 1.0,
    output: 2.5,
    kind: models.Levels([#("low", "Low"), #("high", "High")], "high"),
    ..,
  ) = model("alpha")
  let assert models.Toggle = model("beta").kind
  let assert models.NoReasoning = model("gamma").kind
  // Nothing to pick from is an error.
  let assert Error(Nil) = models.parse_catalog("[{\"id\":\"openai\"}]")
  let assert Error(Nil) =
    models.parse_catalog("[{\"id\":\"hyper\",\"models\":[]}]")
}

pub fn a_default_level_outside_the_levels_falls_back_test() {
  let assert Ok([models.Model(kind: models.Levels(default: "low", ..), ..)]) =
    models.parse_catalog(
      "[{\"id\":\"hyper\",\"models\":[{\"id\":\"x\",\"reasoning\":{\"default_effort_level\":\"max\",\"effort_levels\":[{\"value\":\"low\"}]}}]}]",
    )
}

pub fn current_settles_the_reasoning_test() {
  let session = fn(model, cfg) {
    "{\"is_busy\":false,\"model\":" <> model <> ",\"model_cfg\":" <> cfg <> "}"
  }
  let alpha =
    "{\"id\":\"alpha\",\"reasoning\":{\"thinking\":\"toggleable\",\"default_effort_level\":\"high\",\"effort_levels\":[{\"value\":\"low\"},{\"value\":\"high\"}]}}"
  let beta = "{\"id\":\"beta\",\"reasoning\":{\"thinking\":\"toggleable\"}}"
  // No effort picked: the model's default.
  let assert Ok(models.Current(reasoning: Effort("high"), ..)) =
    models.parse_current(session(alpha, "{}"))
  let assert Ok(models.Current(reasoning: Effort("low"), ..)) =
    models.parse_current(session(alpha, "{\"reasoning_effort\":\"low\"}"))
  // A level the model doesn't take falls back, as crush does.
  let assert Ok(models.Current(reasoning: Effort("high"), ..)) =
    models.parse_current(session(alpha, "{\"reasoning_effort\":\"max\"}"))
  let assert Ok(models.Current(reasoning: Thinking(True), ..)) =
    models.parse_current(session(beta, "{\"think\":true}"))
  let assert Ok(models.Current(reasoning: Thinking(False), ..)) =
    models.parse_current(session(beta, "{}"))
  let assert Error(Nil) = models.parse_current("{\"is_busy\":false}")
  // crush reports an empty model when the pin can't be built.
  let assert Error(Nil) = models.parse_current(session("{\"id\":\"\"}", "{}"))
}

// Choosing.

pub fn check_test() {
  let catalog = catalog()
  let ok = fn(choice) {
    let assert Ok(_) = models.check(catalog, choice)
    Nil
  }
  ok(ModelChoice("alpha", DefaultReasoning))
  ok(ModelChoice("alpha", Effort("low")))
  ok(ModelChoice("beta", Thinking(True)))
  ok(ModelChoice("beta", DefaultReasoning))
  ok(ModelChoice("gamma", DefaultReasoning))
  let assert Error("`alpha` takes low, high") =
    models.check(catalog, ModelChoice("alpha", Effort("max")))
  let assert Error("`alpha` takes low, high") =
    models.check(catalog, ModelChoice("alpha", Thinking(True)))
  let assert Error("`beta` takes on or off") =
    models.check(catalog, ModelChoice("beta", Effort("high")))
  let assert Error("`gamma` doesn't take a reasoning level") =
    models.check(catalog, ModelChoice("gamma", Effort("high")))
  let assert Error("there's no model called `nope`") =
    models.check(catalog, ModelChoice("nope", DefaultReasoning))
}

pub fn after_mirrors_crush_test() {
  // As crush: nothing picked means the default level, and thinking off.
  let assert models.Current(reasoning: Effort("high"), ..) =
    models.after(model("alpha"), ModelChoice("alpha", DefaultReasoning))
  let assert models.Current(reasoning: Thinking(False), ..) =
    models.after(model("beta"), ModelChoice("beta", DefaultReasoning))
  let assert models.Current(reasoning: DefaultReasoning, ..) =
    models.after(model("gamma"), ModelChoice("gamma", DefaultReasoning))
  let assert models.Current(reasoning: Effort("low"), ..) =
    models.after(model("alpha"), ModelChoice("alpha", Effort("low")))
}

pub fn choose_test() {
  let current = models.Current(model("alpha"), Effort("high"))
  let assert Ok(ModelChoice("beta", DefaultReasoning)) =
    models.choose(current, models.ModelPick("beta"))
  let assert Ok(ModelChoice("alpha", Effort("low"))) =
    models.choose(current, models.ReasoningPick("alpha", Effort("low")))
  // A reasoning pick from a card for another model is refused.
  let assert Error("the thread switched to Alpha since this card") =
    models.choose(current, models.ReasoningPick("beta", Thinking(True)))
}

pub fn argument_test() {
  let assert Ok(models.ShowCard) = models.parse_argument("")
  let assert Ok(models.UseDefault) = models.parse_argument(" Default ")
  let assert Ok(models.Choose(ModelChoice("kimi-k3", DefaultReasoning))) =
    models.parse_argument("kimi-k3")
  let assert Ok(models.Choose(ModelChoice("alpha", Effort("low")))) =
    models.parse_argument("  alpha   low ")
  let assert Ok(models.Choose(ModelChoice("beta", Thinking(False)))) =
    models.parse_argument("beta OFF")
  let assert Error(Nil) = models.parse_argument("a b c")
}

pub fn command_test() {
  let assert slack.ModelCommand("") = slack.command("!model")
  let assert slack.ModelCommand("") = slack.command(" !Model ")
  let assert slack.ModelCommand("kimi-k3 high") =
    slack.command("!model  kimi-k3 high")
  // The argument keeps its case; the command doesn't care about it.
  let assert slack.ModelCommand("Org/Model-X") =
    slack.command("!MODEL Org/Model-X")
  let assert slack.NotACommand = slack.command("!models")
  let assert True = string.contains(slack.help, "`!model`")
}

pub fn dollars_test() {
  let assert "$1" = models.dollars(1.0)
  let assert "$2.50" = models.dollars(2.5)
  let assert "$0.05" = models.dollars(0.05)
  let assert "$11" = models.dollars(11.0)
}

pub fn choice_survives_the_store_json_test() {
  let round = fn(choice) {
    let text = json.to_string(meta.model_choice_to_json(choice))
    let assert Ok(back) = json.parse(text, meta.model_choice_decoder())
    back
  }
  let assert ModelChoice("a", DefaultReasoning) =
    round(ModelChoice("a", DefaultReasoning))
  let assert ModelChoice("a", Effort("low")) =
    round(ModelChoice("a", Effort("low")))
  let assert ModelChoice("a", Thinking(False)) =
    round(ModelChoice("a", Thinking(False)))
}

// The card.

/// The menus on a card's actions block.
fn menus(blocks: List(block.Block)) -> List(block.StaticSelectElement) {
  let assert Ok(block.Actions(actions)) =
    list.find(blocks, fn(block) {
      case block {
        block.Actions(_) -> True
        _ -> False
      }
    })
  list.map(actions.elements, fn(element) {
    let assert block.StaticSelect(menu) = element
    menu
  })
}

fn initial(menu: block.StaticSelectElement) -> String {
  let assert Some(option) = menu.initial_option
  option.value
}

fn card(current: models.Current, catalog, note) {
  models.card(current, catalog, #("C1", "1.5"), note)
}

pub fn card_test() {
  let blocks =
    card(models.Current(model("alpha"), Effort("low")), catalog(), "")
  let assert [block.Section(section), block.Actions(actions)] = blocks
  let assert Some(text) = section.text
  let assert True =
    string.contains(
      string.inspect(text),
      "*Alpha* · $1 in / $2.50 out per 1M tokens · reasoning Low",
    )
  let assert Some(id) = actions.block_id
  let assert Ok(#("C1", "1.5")) = models.read_block_id(id)
  let assert [menu, reasoning] = menus(blocks)
  let assert Some(options) = menu.options
  let assert ["alpha", "beta", "gamma"] =
    list.map(options, fn(option) { option.value })
  let assert "alpha" = initial(menu)
  // Reasoning options name the model they're for.
  let assert "alpha|effort:low" = initial(reasoning)
  let assert Ok(models.ReasoningPick("alpha", Effort("low"))) =
    models.read_pick(models.reasoning_action, initial(reasoning))
  // A toggle model offers on and off.
  let blocks =
    card(models.Current(model("beta"), Thinking(False)), catalog(), "")
  let assert [_, reasoning] = menus(blocks)
  let assert "beta|think:off" = initial(reasoning)
  // A model that doesn't reason has no second menu; a note goes under.
  let blocks =
    card(
      models.Current(model("gamma"), DefaultReasoning),
      catalog(),
      "switched",
    )
  let assert [_, _, block.Context(_)] = blocks
  let assert [_] = menus(blocks)
}

pub fn card_menus_stay_inside_slacks_limits_test() {
  // 150 models with long names: the menu holds 100, including the current
  // model, and every label fits in 75 characters.
  let many =
    int.range(from: 150, to: 0, with: [], run: list.prepend)
    |> list.map(fn(i) {
      models.Model(
        id: "m" <> int.to_string(i),
        name: string.repeat("Long name ", 20),
        input: 1.0,
        output: 2.0,
        kind: models.NoReasoning,
      )
    })
  let assert Ok(current) = list.last(many)
  let blocks = card(models.Current(current, DefaultReasoning), many, "")
  let assert [menu] = menus(blocks)
  let assert Some(options) = menu.options
  let assert 100 = list.length(options)
  let assert "m150" = initial(menu)
  let assert True =
    list.all(options, fn(option) {
      case option.text {
        block.PlainTextObject(text) -> string.length(text.text) <= 75
        _ -> False
      }
    })
}

pub fn card_survives_json_test() {
  let blocks =
    card(models.Current(model("beta"), Thinking(True)), catalog(), "")
  let encoded = json.to_string(json.array(blocks, block.block_to_json))
  let assert True = string.contains(encoded, "crushling_model|C1|1.5")
  let assert True = string.contains(encoded, "\"crushling_reasoning\"")
}

pub fn read_pick_test() {
  let assert Ok(models.ModelPick("beta")) =
    models.read_pick(models.model_action, "beta")
  let assert Ok(models.ReasoningPick("beta", Thinking(True))) =
    models.read_pick(models.reasoning_action, "beta|think:on")
  let assert Error(Nil) = models.read_pick(models.reasoning_action, "low")
  let assert Error(Nil) = models.read_pick("tailnet_deny", "x")
  let assert Error(Nil) = models.read_block_id("crushling_model|C1")
  let assert Error(Nil) = models.read_block_id("other|C1|1.5")
}

/// A `block_actions` payload as Slack sends it for a pick on a card posted
/// at the top of a code channel, for the thread C1/1.5.
const picked_payload =
  "{\"type\":\"block_actions\",
  \"user\":{\"id\":\"U1\",\"username\":\"k\",\"team_id\":\"T1\"},
  \"api_app_id\":\"A1\",\"token\":\"x\",\"trigger_id\":\"t\",
  \"team\":{\"id\":\"T1\",\"domain\":\"d\"},
  \"container\":{\"type\":\"message\",\"message_ts\":\"9.9\",\"channel_id\":\"CCODE\",\"is_ephemeral\":false},
  \"channel\":{\"id\":\"CCODE\",\"name\":\"code\"},
  \"actions\":[{\"type\":\"static_select\",\"action_id\":\"crushling_reasoning\",
    \"block_id\":\"crushling_model|C1|1.5\",\"action_ts\":\"9.91\",
    \"selected_option\":{\"text\":{\"type\":\"plain_text\",\"text\":\"Low\"},\"value\":\"alpha|effort:low\"}}]}"

pub fn socket_reads_a_pick_test() {
  let assert Ok(payload) =
    json.parse(picked_payload, interaction.block_actions_payload_decoder())
  let assert Some([action]) = payload.actions
  let assert Ok(registry.ModelPicked(
    home: #("C1", "1.5"),
    pick: models.ReasoningPick("alpha", Effort("low")),
    card: meta.Card(channel: "CCODE", ts: "9.9", thread_ts: ""),
    user: "U1",
  )) = socket.picked(action, payload)
}

// A thread against the fake server.

type Server

@external(erlang, "fake_crush_ffi", "start")
fn start_server(path: String) -> Server

@external(erlang, "fake_crush_ffi", "stop")
fn stop_server(server: Server) -> Nil

@external(erlang, "fake_crush_ffi", "next")
fn next_request(timeout_ms: Int) -> Result(#(String, dynamic.Dynamic), Nil)

@external(erlang, "erlang", "unique_integer")
fn unique() -> Int

type Seen {
  Posted(String)
  Card(List(block.Block))
  CardUpdated(ts: String, blocks: List(block.Block))
  Chosen(option.Option(meta.ModelChoice))
}

fn socket_path(name: String) -> String {
  "/tmp/crushling-model-"
  <> name
  <> "-"
  <> int.to_string(int.absolute_value(unique()))
  <> ".sock"
}

fn start(
  name: String,
  saved: option.Option(meta.ModelChoice),
) -> #(Server, Subject(thread.Message), Subject(Seen)) {
  let socket = socket_path(name)
  let server = start_server(socket)
  let seen = process.new_subject()
  let post = fn(text) {
    process.send(seen, Posted(text))
    Ok("ts")
  }
  let sink =
    sink.Sink(
      conversation: sink.Conversation("C", Some("1.0")),
      working: fn(_) { Nil },
      title: fn(_) { Nil },
      post:,
      post_blocks: fn(_, blocks) {
        process.send(seen, Card(blocks))
        Ok("card")
      },
      update_blocks: fn(ts, _, blocks) {
        process.send(seen, CardUpdated(ts, blocks))
        Ok(Nil)
      },
      post_plan: fn(plan) { post(render.plan_markdown(plan)) },
      update_plan: fn(_, _) { Ok(Nil) },
      reply: fn(_) {
        sink.Reply(show: fn(_, _, _) { Nil }, finish: fn(_) { [] })
      },
      upload: fn(_, _) { Ok(Nil) },
      branch: fn(_, _) { Error("no") },
      open_code_channel: fn(_) { Error("no") },
      context: fn(_) { Nil },
      code: fn(_, _, _) { Nil },
    )
  let assert Ok(t) =
    thread.start(
      thread.Config(
        socket:,
        root: "/work",
        title: "test",
        venue: venue.Thread,
        sink:,
        flush_ms: 60_000,
        mode: client.Yolo,
        notify: fn(notice) {
          case notice {
            thread.ModelChosen(choice) -> process.send(seen, Chosen(choice))
            _ -> Nil
          }
        },
        on_connect: fn(_) { Nil },
        model: saved,
        home: #("C", "1.0"),
      ),
    )
  #(server, t, seen)
}

/// The next request of `kind`, skipping others.
fn expect(kind: String) -> dynamic.Dynamic {
  case next_request(5000) {
    Ok(#(got, value)) if got == kind -> value
    Ok(_) -> expect(kind)
    Error(Nil) -> panic as { "no " <> kind <> " request" }
  }
}

/// No `kind` request within a moment.
fn no(kind: String) -> Nil {
  case next_request(300) {
    Ok(#(got, _)) if got == kind -> panic as { "unexpected " <> kind }
    Ok(_) -> no(kind)
    Error(Nil) -> Nil
  }
}

/// A pinned selection's fields, as text.
fn pinned(value: dynamic.Dynamic) -> dict.Dict(String, String) {
  let assert Ok(fields) =
    decode.run(value, decode.dict(decode.string, decode.dynamic))
  dict.map_values(fields, fn(_, value) {
    case decode.run(value, decode.string) {
      Ok(text) -> text
      Error(_) -> string.inspect(value)
    }
  })
}

fn receive(seen: Subject(Seen)) -> Seen {
  let assert Ok(seen) = process.receive(seen, 5000)
  seen
}

pub fn saved_model_is_pinned_on_connect_test() {
  let #(server, t, _) =
    start("saved", Some(ModelChoice("beta", Thinking(True))))
  let fields = pinned(expect("model"))
  let assert Ok("beta") = dict.get(fields, "model")
  let assert Ok("hyper") = dict.get(fields, "provider")
  let assert Ok("True") = dict.get(fields, "think")
  process.send(t, thread.Stop)
  stop_server(server)
}

pub fn no_saved_model_pins_nothing_test() {
  let #(server, t, _) = start("default", None)
  let _ = expect("events")
  no("model")
  process.send(t, thread.Stop)
  stop_server(server)
}

pub fn a_saved_model_that_left_the_catalog_is_dropped_test() {
  let #(server, t, seen) =
    start("stale", Some(ModelChoice("gone", DefaultReasoning)))
  let assert Posted(text) = receive(seen)
  let assert True = string.contains(text, "`gone`")
  let assert True = string.contains(text, "back on the default model")
  let assert Chosen(None) = receive(seen)
  no("model")
  process.send(t, thread.Stop)
  stop_server(server)
}

pub fn a_saved_level_the_model_dropped_keeps_the_model_test() {
  // `beta` only toggles thinking now; the saved effort level is dropped,
  // the model kept.
  let #(server, t, seen) =
    start("level", Some(ModelChoice("beta", Effort("max"))))
  let assert Posted(text) = receive(seen)
  let assert True =
    string.contains(text, "`beta` doesn't take the reasoning level")
  let assert Chosen(Some(ModelChoice("beta", DefaultReasoning))) = receive(seen)
  let fields = pinned(expect("model"))
  let assert Ok("beta") = dict.get(fields, "model")
  let assert Error(Nil) = dict.get(fields, "think")
  process.send(t, thread.Stop)
  stop_server(server)
}

pub fn a_saved_model_crush_refuses_goes_back_to_the_default_test() {
  let #(server, t, seen) =
    start("broken", Some(ModelChoice("broken", DefaultReasoning)))
  let assert Posted(text) = receive(seen)
  let assert True = string.contains(text, "crush wouldn't run `broken`")
  let assert Chosen(None) = receive(seen)
  process.send(t, thread.Stop)
  stop_server(server)
}

pub fn card_shows_and_switches_test() {
  let #(server, t, seen) = start("card", None)
  let _ = expect("events")
  process.send(t, thread.ModelCommand(models.ShowCard, "U1"))
  let assert Card(blocks) = receive(seen)
  let assert [menu, reasoning] = menus(blocks)
  let assert "alpha" = initial(menu)
  let assert "alpha|effort:high" = initial(reasoning)
  // Pick another model on the card: thinking stays off, as in crush.
  process.send(t, thread.CardPicked(models.ModelPick("beta"), "card", "U1"))
  let fields = pinned(expect("model"))
  let assert Ok("beta") = dict.get(fields, "model")
  let assert Error(Nil) = dict.get(fields, "think")
  let assert CardUpdated("card", blocks) = receive(seen)
  let assert [_, _, block.Context(_)] = blocks
  let assert [menu, reasoning] = menus(blocks)
  let assert "beta" = initial(menu)
  let assert "beta|think:off" = initial(reasoning)
  let assert Chosen(Some(ModelChoice("beta", DefaultReasoning))) = receive(seen)
  // Then its reasoning.
  process.send(
    t,
    thread.CardPicked(
      models.ReasoningPick("beta", Thinking(True)),
      "card",
      "U1",
    ),
  )
  let assert Ok("True") = dict.get(pinned(expect("model")), "think")
  let assert CardUpdated(_, blocks) = receive(seen)
  let assert [_, reasoning] = menus(blocks)
  let assert "beta|think:on" = initial(reasoning)
  let assert Chosen(Some(ModelChoice("beta", Thinking(True)))) = receive(seen)
  process.send(t, thread.Stop)
  stop_server(server)
}

pub fn a_refused_pick_puts_the_card_back_test() {
  let #(server, t, seen) = start("stale-card", None)
  let _ = expect("events")
  // A reasoning pick from a card for a model the session doesn't run.
  process.send(
    t,
    thread.CardPicked(
      models.ReasoningPick("beta", Thinking(True)),
      "card",
      "U1",
    ),
  )
  let assert CardUpdated("card", blocks) = receive(seen)
  let assert [_, _, block.Context(note)] = blocks
  let assert True =
    string.contains(string.inspect(note), "switched to Alpha since this card")
  let assert [menu, _] = menus(blocks)
  let assert "alpha" = initial(menu)
  no("model")
  process.send(t, thread.Stop)
  stop_server(server)
}

pub fn command_switches_refuses_and_resets_test() {
  let #(server, t, seen) = start("command", None)
  let _ = expect("events")
  process.send(
    t,
    thread.ModelCommand(
      models.Choose(ModelChoice("alpha", Effort("low"))),
      "U1",
    ),
  )
  let assert Ok("low") = dict.get(pinned(expect("model")), "reasoning_effort")
  let assert Posted(text) = receive(seen)
  let assert True = string.contains(text, "*Alpha*")
  let assert True = string.contains(text, "reasoning Low")
  let assert Chosen(Some(ModelChoice("alpha", Effort("low")))) = receive(seen)
  // A model that isn't there is refused before crush hears of it.
  process.send(
    t,
    thread.ModelCommand(
      models.Choose(ModelChoice("nope", DefaultReasoning)),
      "U1",
    ),
  )
  let assert Posted(text) = receive(seen)
  let assert True = string.contains(text, "no model called `nope`")
  no("model")
  // `!model default` pins crush's default and forgets the choice.
  process.send(t, thread.ModelCommand(models.UseDefault, "U1"))
  let fields = pinned(expect("model"))
  let assert Ok("alpha") = dict.get(fields, "model")
  let assert Error(Nil) = dict.get(fields, "reasoning_effort")
  let assert Posted(_) = receive(seen)
  let assert Chosen(None) = receive(seen)
  process.send(t, thread.Stop)
  stop_server(server)
}

// The registry.

type Launch {
  Launched(String)
  Stopped(String)
}

const test_key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="

pub fn a_thread_woken_for_model_goes_back_to_sleep_test() {
  let socket = socket_path("wake")
  let server = start_server(socket)
  let launches = process.new_subject()
  let fake =
    launcher.Launcher(
      launch: fn(key) {
        process.send(launches, Launched(key))
        Ok(launcher.Launched(socket:, root: "/work"))
      },
      stop: fn(key) {
        process.send(launches, Stopped(key))
        Ok(Nil)
      },
      exists: fn(_) { True },
      rekey: fn(_, _) { Ok(Nil) },
      run_in_sandbox: None,
    )
  let assert Ok(key) = store.parse_key(test_key)
  let assert Ok(s) = store.start(":memory:", key)
  let thread_key = registry.key("T1", "C1", "1.0")
  let assert Ok(Nil) =
    store.put_thread(
      s,
      store.Thread(thread_key, "T1", "C1", "1.0", meta.new(True)),
    )
  let assert Ok(client) =
    slackline.new("xoxb-test")
    |> slackline.with_base_url("http://127.0.0.1:1/api")
  let assert Ok(r) =
    registry.start(registry.Config(
      launcher: fake,
      client:,
      token: "xoxb-test",
      bot_user: "UBOT",
      team: "T1",
      allowed: people.only(["U1"]),
      admins: set.new(),
      store: s,
      migrate_legacy: False,
      idle_ms: 300,
      flush_ms: 50,
      mode: client.Sysadmin,
      tailnet: None,
      stop_backoff_ms: registry.default_stop_backoff_ms,
      root: "/tmp/crushling-model-test",
    ))
  // `!model` on an asleep thread wakes it to show the card...
  process.send(
    r,
    registry.Received(
      msg.Incoming("C1", "1.0", "2.0", "U1", "!model", False, []),
    ),
  )
  let assert Ok(Launched(_)) = process.receive(launches, 2000)
  // The card's reads reached the woken agent's crush...
  let _ = expect("providers")
  let _ = expect("busy")
  // ...and, with no prompt to run, it is stopped again once idle.
  let assert Ok(Stopped(stopped)) = process.receive(launches, 3000)
  let assert True = stopped == thread_key
  stop_server(server)
}
