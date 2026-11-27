//// Picking a thread's model: reading crush's catalog and session, checking
//// choices, the card, `!model`, a thread pinning models on a fake `crush
//// server` (test/fake_crush_ffi.erl), and the registry waking and putting
//// to sleep a thread that only got `!model`.

import crushling/agent/post_mortem
import crushling/commands
import crushling/conversation
import crushling/crush/catalog
import crushling/crush/client
import crushling/key
import crushling/launcher
import crushling/meta.{DefaultReasoning, Effort, ModelChoice, Thinking}
import crushling/people
import crushling/registry
import crushling/registry/config as registry_config
import crushling/registry/incoming as msg
import crushling/sink
import crushling/slack/action_ref
import crushling/slack/model_card
import crushling/slack/workspace
import crushling/store
import crushling/store/schema
import crushling/store/threads
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

fn catalog() -> List(catalog.Model) {
  let assert Ok(catalog) = catalog.parse_catalog(catalog_json)
  catalog
}

fn model(id: String) -> catalog.Model {
  let assert Ok(model) = catalog.find(catalog(), id)
  model
}

// Reading crush.

pub fn catalog_reads_the_hyper_models_test() {
  let assert ["alpha", "beta", "gamma"] =
    list.map(catalog(), fn(model) { model.id })
  let assert catalog.Model(
    name: "Alpha",
    kind: catalog.Levels([#("low", "Low"), #("high", "High")], "high"),
    ..,
  ) = model("alpha")
  let assert catalog.Toggle = model("beta").kind
  let assert catalog.NoReasoning = model("gamma").kind
  // Nothing to pick from is an error.
  let assert Error(Nil) = catalog.parse_catalog("[{\"id\":\"openai\"}]")
  let assert Error(Nil) =
    catalog.parse_catalog("[{\"id\":\"hyper\",\"models\":[]}]")
}

pub fn a_default_level_outside_the_levels_falls_back_test() {
  let assert Ok([catalog.Model(kind: catalog.Levels(default: "low", ..), ..)]) =
    catalog.parse_catalog(
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
  let assert Ok(catalog.Current(reasoning: Effort("high"), ..)) =
    catalog.parse_current(session(alpha, "{}"))
  let assert Ok(catalog.Current(reasoning: Effort("low"), ..)) =
    catalog.parse_current(session(alpha, "{\"reasoning_effort\":\"low\"}"))
  // A level the model doesn't take falls back, as crush does.
  let assert Ok(catalog.Current(reasoning: Effort("high"), ..)) =
    catalog.parse_current(session(alpha, "{\"reasoning_effort\":\"max\"}"))
  let assert Ok(catalog.Current(reasoning: Thinking(True), ..)) =
    catalog.parse_current(session(beta, "{\"think\":true}"))
  let assert Ok(catalog.Current(reasoning: Thinking(False), ..)) =
    catalog.parse_current(session(beta, "{}"))
  let assert Error(Nil) = catalog.parse_current("{\"is_busy\":false}")
  // crush reports an empty model when the pin can't be built.
  let assert Error(Nil) = catalog.parse_current(session("{\"id\":\"\"}", "{}"))
}

// Choosing.

pub fn check_test() {
  let catalog = catalog()
  let ok = fn(choice) {
    let assert Ok(_) = catalog.check(catalog, choice)
    Nil
  }
  ok(ModelChoice("alpha", DefaultReasoning))
  ok(ModelChoice("alpha", Effort("low")))
  ok(ModelChoice("beta", Thinking(True)))
  ok(ModelChoice("beta", DefaultReasoning))
  ok(ModelChoice("gamma", DefaultReasoning))
  let assert Error("`alpha` takes low, high") =
    catalog.check(catalog, ModelChoice("alpha", Effort("max")))
  let assert Error("`alpha` takes low, high") =
    catalog.check(catalog, ModelChoice("alpha", Thinking(True)))
  let assert Error("`beta` takes on or off") =
    catalog.check(catalog, ModelChoice("beta", Effort("high")))
  let assert Error("`gamma` doesn't take a reasoning level") =
    catalog.check(catalog, ModelChoice("gamma", Effort("high")))
  let assert Error("there's no model called `nope`") =
    catalog.check(catalog, ModelChoice("nope", DefaultReasoning))
}

pub fn after_mirrors_crush_test() {
  // As crush: nothing picked means the default level, and thinking off.
  let assert catalog.Current(reasoning: Effort("high"), ..) =
    catalog.after(model("alpha"), ModelChoice("alpha", DefaultReasoning))
  let assert catalog.Current(reasoning: Thinking(False), ..) =
    catalog.after(model("beta"), ModelChoice("beta", DefaultReasoning))
  let assert catalog.Current(reasoning: DefaultReasoning, ..) =
    catalog.after(model("gamma"), ModelChoice("gamma", DefaultReasoning))
  let assert catalog.Current(reasoning: Effort("low"), ..) =
    catalog.after(model("alpha"), ModelChoice("alpha", Effort("low")))
}

pub fn argument_test() {
  let assert Ok(catalog.ShowCard) = catalog.parse_argument("")
  let assert Ok(catalog.UseDefault) = catalog.parse_argument(" Default ")
  let assert Ok(catalog.Choose(ModelChoice("kimi-k3", DefaultReasoning))) =
    catalog.parse_argument("kimi-k3")
  let assert Ok(catalog.Choose(ModelChoice("alpha", Effort("low")))) =
    catalog.parse_argument("  alpha   low ")
  let assert Ok(catalog.Choose(ModelChoice("beta", Thinking(False)))) =
    catalog.parse_argument("beta OFF")
  let assert Error(Nil) = catalog.parse_argument("a b c")
}

pub fn command_test() {
  let assert commands.ModelCommand("") = commands.parse("!model")
  let assert commands.ModelCommand("") = commands.parse(" !Model ")
  let assert commands.ModelCommand("kimi-k3 high") =
    commands.parse("!model  kimi-k3 high")
  // The argument keeps its case; the command doesn't care about it.
  let assert commands.ModelCommand("Org/Model-X") =
    commands.parse("!MODEL Org/Model-X")
  let assert commands.NotACommand = commands.parse("!models")
  let assert True = string.contains(commands.help(), "`!model`")
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

/// The menus on a card, from its input blocks, in order.
fn menus(blocks: List(block.Block)) -> List(block.StaticSelectElement) {
  list.filter_map(blocks, fn(block) {
    case block {
      block.Input(block.InputBlock(element: block.StaticSelect(menu), ..)) ->
        Ok(menu)
      _ -> Error(Nil)
    }
  })
}

fn initial(menu: block.StaticSelectElement) -> String {
  let assert Some(option) = menu.initial_option
  option.value
}

fn card(current: catalog.Current, catalog, note) {
  model_card.card(current, current, catalog, #("C1", "1.5"), note)
}

fn header(blocks: List(block.Block)) -> String {
  let assert [block.Section(block.SectionBlock(text: Some(text), ..)), ..] =
    blocks
  string.inspect(text)
}

pub fn card_test() {
  let blocks =
    card(catalog.Current(model("alpha"), Effort("low")), catalog(), "")
  // The model and reasoning in words; no prices.
  let assert True = string.contains(header(blocks), "*Alpha* · reasoning Low")
  let assert False = string.contains(header(blocks), "$")
  let assert [_, block.Input(m), block.Input(_), block.Actions(confirm)] =
    blocks
  // The model menu dispatches on change, so the reasoning menu can follow;
  // Confirm names the thread.
  let assert Some(True) = m.dispatch_action
  let assert Some(id) = confirm.block_id
  let assert Ok(action_ref.CardRef(_, "C1", "1.5", _)) = action_ref.decode(id)
  let assert [block.Button(button)] = confirm.elements
  let assert Some(block.Primary) = button.style
  let assert [menu, reasoning] = menus(blocks)
  let assert Some(options) = menu.options
  let assert ["alpha", "beta", "gamma"] =
    list.map(options, fn(option) { option.value })
  let assert "alpha" = initial(menu)
  let assert Ok(action_ref.ReasoningOption("alpha", Effort("low"))) =
    action_ref.decode(initial(reasoning))
  // A toggle model offers on and off.
  let blocks =
    card(catalog.Current(model("beta"), Thinking(False)), catalog(), "")
  let assert [_, reasoning] = menus(blocks)
  let assert Ok(action_ref.ReasoningOption("beta", Thinking(False))) =
    action_ref.decode(initial(reasoning))
  // A model that doesn't reason has no second menu; a note goes under.
  let blocks =
    card(
      catalog.Current(model("gamma"), DefaultReasoning),
      catalog(),
      "couldn't",
    )
  let assert [_, _, block.Actions(_), block.Context(_)] = blocks
  let assert [_] = menus(blocks)
}

pub fn a_preview_shows_another_model_under_the_current_one_test() {
  let current = catalog.Current(model("alpha"), Effort("high"))
  let shown = catalog.Current(model("beta"), Thinking(False))
  let blocks = model_card.card(current, shown, catalog(), #("C1", "1.5"), "")
  let assert True = string.contains(header(blocks), "*Alpha*")
  let assert [menu, reasoning] = menus(blocks)
  let assert "beta" = initial(menu)
  let assert Ok(action_ref.ReasoningOption("beta", Thinking(False))) =
    action_ref.decode(initial(reasoning))
}

pub fn card_menus_stay_inside_slacks_limits_test() {
  // 150 models with long names: the menu holds 100, including the current
  // model, and every label fits in 75 characters.
  let many =
    int.range(from: 150, to: 0, with: [], run: list.prepend)
    |> list.map(fn(i) {
      catalog.Model(
        id: "m" <> int.to_string(i),
        name: string.repeat("Long name ", 20),
        kind: catalog.NoReasoning,
      )
    })
  let assert Ok(current) = list.last(many)
  let blocks = card(catalog.Current(current, DefaultReasoning), many, "")
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
    card(catalog.Current(model("beta"), Thinking(True)), catalog(), "")
  let encoded = json.to_string(json.array(blocks, block.block_to_json))
  let confirm =
    action_ref.encode(action_ref.CardRef(
      action_ref.ConfirmButton,
      "C1",
      "1.5",
      "beta",
    ))
  let assert True = string.contains(encoded, confirm)
  let assert True = string.contains(encoded, "\"crushling_reasoning\"")
}

pub fn read_confirm_test() {
  let assert Ok(model_card.Confirm(ModelChoice("beta", Thinking(True)))) =
    model_card.read_confirm(Some("beta"), Some("beta|think:on"))
  // A reasoning value left over from another model means the default.
  let assert Ok(model_card.Confirm(ModelChoice("beta", DefaultReasoning))) =
    model_card.read_confirm(Some("beta"), Some("alpha|effort:low"))
  let assert Ok(model_card.Confirm(ModelChoice("gamma", DefaultReasoning))) =
    model_card.read_confirm(Some("gamma"), None)
  let assert Error(Nil) = model_card.read_confirm(None, Some("beta|think:on"))
  let assert Error(Nil) = action_ref.decode("other|C1|1.5")
  let assert Error(Nil) = action_ref.decode("crushling_model|C1")
  // Cards posted before refs had a version still name their thread.
  let assert Ok(action_ref.CardRef(action_ref.ModelMenu, "C1", "1.5", "alpha")) =
    action_ref.decode("crushling_model|C1|1.5|alpha")
}

fn payload(action: String, state: String) -> String {
  "{\"type\":\"block_actions\",
  \"user\":{\"id\":\"U1\",\"username\":\"k\",\"team_id\":\"T1\"},
  \"api_app_id\":\"A1\",\"token\":\"x\",\"trigger_id\":\"t\",
  \"team\":{\"id\":\"T1\",\"domain\":\"d\"},
  \"container\":{\"type\":\"message\",\"message_ts\":\"9.9\",\"channel_id\":\"CCODE\",\"is_ephemeral\":false},
  \"channel\":{\"id\":\"CCODE\",\"name\":\"code\"},
  \"state\":{\"values\":" <> state <> "},
  \"actions\":[" <> action <> "]}"
}

/// Confirm on a card at the top of a code channel, for the thread C1/1.5,
/// with the menus' state as Slack sends it.
const confirm_action =
  "{\"type\":\"button\",\"action_id\":\"crushling_confirm\",
  \"block_id\":\"crushling_confirm|C1|1.5|alpha\",\"action_ts\":\"9.91\",
  \"text\":{\"type\":\"plain_text\",\"text\":\"Confirm\"}}"

const menu_state =
  "{
  \"crushling_model|C1|1.5|alpha\":{\"crushling_model\":{\"type\":\"static_select\",
    \"selected_option\":{\"text\":{\"type\":\"plain_text\",\"text\":\"Alpha\"},\"value\":\"alpha\"}}},
  \"crushling_reasoning|alpha\":{\"crushling_reasoning\":{\"type\":\"static_select\",
    \"selected_option\":{\"text\":{\"type\":\"plain_text\",\"text\":\"Low\"},\"value\":\"alpha|effort:low\"}}}}"

const change_action =
  "{\"type\":\"static_select\",\"action_id\":\"crushling_model\",
  \"block_id\":\"crushling_model|C1|1.5|alpha\",\"action_ts\":\"9.91\",
  \"selected_option\":{\"text\":{\"type\":\"plain_text\",\"text\":\"Beta\"},\"value\":\"beta\"}}"

fn picked(action: String) {
  let assert Ok(payload) =
    json.parse(
      payload(action, menu_state),
      interaction.block_actions_payload_decoder(),
    )
  let assert Some([action]) = payload.actions
  model_card.decode(action, payload)
}

pub fn socket_reads_card_actions_test() {
  let card = meta.Card(channel: "CCODE", ts: "9.9", thread_ts: "")
  let assert Ok(model_card.Picked(
    home: #("C1", "1.5"),
    pick: model_card.Confirm(ModelChoice("alpha", Effort("low"))),
    card: c,
    user: "U1",
  )) = picked(confirm_action)
  let assert True = c == card
  let assert Ok(model_card.Picked(
    home: #("C1", "1.5"),
    pick: model_card.Preview("beta"),
    ..,
  )) = picked(change_action)
  // With no menu state at all, Confirm falls back to the model it was drawn
  // for.
  let assert Ok(payload) =
    json.parse(
      payload(confirm_action, "{}"),
      interaction.block_actions_payload_decoder(),
    )
  let assert Some([action]) = payload.actions
  let assert Ok(model_card.Picked(
    pick: model_card.Confirm(ModelChoice("alpha", DefaultReasoning)),
    ..,
  )) = model_card.decode(action, payload)
}

// A thread against the fake server.

type Server

@external(erlang, "fake_crush_ffi", "start")
fn start_server(path: String) -> Server

@external(erlang, "fake_crush_ffi", "stop")
fn stop_server(server: Server) -> Nil

@external(erlang, "fake_crush_ffi", "set_jobs")
fn set_jobs(server: Server, jobs: Int) -> Nil

@external(erlang, "fake_crush_ffi", "next")
fn next_request(timeout_ms: Int) -> Result(#(String, dynamic.Dynamic), Nil)

@external(erlang, "erlang", "unique_integer")
fn unique() -> Int

type Seen {
  Posted(String)
  Card(List(block.Block))
  CardUpdated(ts: String, blocks: List(block.Block))
  Deleted(ts: String)
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
  let sink =
    sink.Sink(
      conversation: conversation.Conversation("C", Some("1.0")),
      post: fn(text) {
        process.send(seen, Posted(text))
        Ok("ts")
      },
      post_blocks: fn(_, blocks) {
        process.send(seen, Card(blocks))
        Ok("card")
      },
      update_blocks: fn(ts, _, blocks) {
        process.send(seen, CardUpdated(ts, blocks))
        Ok(Nil)
      },
      delete: fn(ts) {
        process.send(seen, Deleted(ts))
        Ok(Nil)
      },
      reply: fn(_) {
        sink.Reply(show: fn(_, _, _) { Nil }, finish: fn(_) { [] })
      },
      upload: fn(_, _) { Ok(Nil) },
      branch: fn(_, _, _) { Error("no") },
      session: None,
      code_view: None,
      open_code_channel: None,
    )
  let assert Ok(t) =
    thread.start(
      thread.Config(
        socket:,
        root: "/work",
        title: "test",
        venue: venue.Thread,
        sink: fn(_) { sink },
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
        post_mortem: fn() { post_mortem.Unknown("test") },
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
  let assert True = string.contains(text, "`broken` failed to start")
  let assert Chosen(None) = receive(seen)
  process.send(t, thread.Stop)
  stop_server(server)
}

pub fn card_shows_and_switches_test() {
  let #(server, t, seen) = start("card", None)
  let _ = expect("events")
  process.send(t, thread.ModelCommand(catalog.ShowCard, "U1"))
  let assert Card(blocks) = receive(seen)
  let assert [menu, reasoning] = menus(blocks)
  let assert "alpha" = initial(menu)
  let assert Ok(action_ref.ReasoningOption("alpha", Effort("high"))) =
    action_ref.decode(initial(reasoning))
  // Changing the model menu only redraws the card for it...
  process.send(t, thread.CardPicked(model_card.Preview("beta"), "card", "U1"))
  let assert CardUpdated("card", blocks) = receive(seen)
  let assert True = string.contains(header(blocks), "*Alpha*")
  let assert [menu, reasoning] = menus(blocks)
  let assert "beta" = initial(menu)
  let assert Ok(action_ref.ReasoningOption("beta", Thinking(False))) =
    action_ref.decode(initial(reasoning))
  no("model")
  // ...and Confirm switches: thinking stays off, as in crush.
  process.send(
    t,
    thread.CardPicked(
      model_card.Confirm(ModelChoice("beta", DefaultReasoning)),
      "card",
      "U1",
    ),
  )
  let fields = pinned(expect("model"))
  let assert Ok("beta") = dict.get(fields, "model")
  let assert Error(Nil) = dict.get(fields, "think")
  // The card has done its job and goes.
  let assert Deleted("card") = receive(seen)
  let assert Chosen(Some(ModelChoice("beta", DefaultReasoning))) = receive(seen)
  // Then its reasoning.
  process.send(
    t,
    thread.CardPicked(
      model_card.Confirm(ModelChoice("beta", Thinking(True))),
      "card",
      "U1",
    ),
  )
  let assert Ok("True") = dict.get(pinned(expect("model")), "think")
  let assert Deleted("card") = receive(seen)
  let assert Chosen(Some(ModelChoice("beta", Thinking(True)))) = receive(seen)
  process.send(t, thread.Stop)
  stop_server(server)
}

pub fn a_refused_confirm_puts_the_card_back_test() {
  let #(server, t, seen) = start("refused", None)
  let _ = expect("events")
  // `alpha` doesn't take thinking on: refused before crush hears of it.
  process.send(
    t,
    thread.CardPicked(
      model_card.Confirm(ModelChoice("alpha", Thinking(True))),
      "card",
      "U1",
    ),
  )
  let assert CardUpdated("card", blocks) = receive(seen)
  let assert [_, _, _, _, block.Context(note)] = blocks
  let assert True =
    string.contains(string.inspect(note), "`alpha` takes low, high")
  let assert [menu, reasoning] = menus(blocks)
  let assert "alpha" = initial(menu)
  let assert Ok(action_ref.ReasoningOption("alpha", Effort("high"))) =
    action_ref.decode(initial(reasoning))
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
      catalog.Choose(ModelChoice("alpha", Effort("low"))),
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
      catalog.Choose(ModelChoice("nope", DefaultReasoning)),
      "U1",
    ),
  )
  let assert Posted(text) = receive(seen)
  let assert True = string.contains(text, "no model called `nope`")
  no("model")
  // `!model default` pins crush's default and forgets the choice.
  process.send(t, thread.ModelCommand(catalog.UseDefault, "U1"))
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

/// Drop what earlier tests' fakes said: tests share one mailbox.
fn drain() -> Nil {
  case next_request(0) {
    Ok(_) -> drain()
    Error(Nil) -> Nil
  }
}

fn start_woken_registry(name: String) {
  drain()
  let socket = socket_path(name)
  let server = start_server(socket)
  let launches = process.new_subject()
  let fake =
    launcher.Launcher(
      launch: fn(key) {
        process.send(launches, Launched(key))
        Ok(
          launcher.Launched(socket:, root: "/work", post_mortem: fn() {
            post_mortem.Unknown("test")
          }),
        )
      },
      stop: fn(key) {
        process.send(launches, Stopped(key))
        Ok(Nil)
      },
      exists: fn(_) { True },
      forget: fn(_) { Ok(Nil) },
      rekey: fn(_, _) { Ok(Nil) },
      run_in_sandbox: None,
    )
  let assert Ok(key) = store.parse_key(test_key)
  let assert Ok(s) = schema.open(":memory:", key)
  let thread_key = thread_key("T1", "C1", "1.0")
  let assert Ok(Nil) =
    threads.put_thread(
      s,
      threads.Thread(thread_key, "T1", "C1", "1.0", meta.new(True)),
    )
  let assert Ok(client) =
    slackline.new("xoxb-test")
    |> slackline.with_base_url("http://127.0.0.1:1/api")
  let assert Ok(r) =
    registry.start(registry_config.Config(
      launcher: fake,
      workspace: workspace.new(
        team: "T1",
        bot_user: "UBOT",
        client:,
        token: "xoxb-test",
      ),
      allowed: people.only(["U1"]),
      admins: set.new(),
      store: s,
      stranded: set.new(),
      idle_ms: 300,
      flush_ms: 50,
      mode: client.Sysadmin,
      tailnet: None,
      stop_backoff_ms: registry.default_stop_backoff_ms,
      root: "/tmp/crushling-model-test",
      github: None,
      default_model: "prism",
    ))
  // `!model` on an asleep thread wakes it to show the card.
  process.send(
    r,
    registry.Received(
      msg.Incoming("C1", "1.0", "2.0", "U1", "!model", False, []),
    ),
  )
  let assert Ok(Launched(_)) = process.receive(launches, 2000)
  #(server, launches, thread_key)
}

pub fn a_thread_woken_for_model_goes_back_to_sleep_test() {
  let #(server, launches, thread_key) = start_woken_registry("wake")
  // The card's reads reached the woken agent's crush...
  let _ = expect("providers")
  let _ = expect("busy")
  // ...and, with no prompt to run, it is stopped again once idle. (The
  // thread first spends a few seconds retrying the card's post to this
  // test's dead Slack.)
  let assert Ok(Stopped(stopped)) = process.receive(launches, 15_000)
  let assert True = stopped == thread_key
  stop_server(server)
}

pub fn an_idle_agent_with_background_jobs_is_kept_test() {
  let #(server, launches, thread_key) = start_woken_registry("jobs")
  set_jobs(server, 1)
  // The idle check finds a job running, twice over, and keeps the agent.
  let assert 1 = count_jobs()
  let assert 1 = count_jobs()
  let assert Error(Nil) = process.receive(launches, 0)
  // Once the job is done, the next check stops it.
  set_jobs(server, 0)
  let assert Ok(Stopped(stopped)) = process.receive(launches, 15_000)
  let assert True = stopped == thread_key
  stop_server(server)
}

/// The count the next idle check got. The first comes late: the thread
/// spends a few seconds retrying the card's post to this test's dead Slack.
fn count_jobs() -> Int {
  case next_request(15_000) {
    Ok(#("jobs", count)) -> {
      let assert Ok(count) = decode.run(count, decode.int)
      count
    }
    Ok(_) -> count_jobs()
    Error(Nil) -> panic as "no job count"
  }
}

fn thread_key(team: String, channel: String, ts: String) -> String {
  key.new(team, channel, ts) |> key.to_string
}
