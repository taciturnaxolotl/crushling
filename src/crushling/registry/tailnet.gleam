//// Tailnet access for threads' sandboxes. Each event about a thread comes
//// here with a view of the thread, and the registry applies the outcome.
//// A sandbox is on the tailnet exactly while its agent runs and its access
//// lasts; `sync` makes that so after every change.

import crushling/meta.{type Card, type Grant}
import crushling/sys
import crushling/tailscale
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import slackline
import slackline/api/chat
import slackline/api/chat/post_ephemeral
import slackline/api/chat/post_message
import slackline/api/chat/update
import slackline/block
import slackline/element
import slackline/element/button
import slackline/httpc

/// What the registry needs to put sandboxes on the tailnet.
pub type Setup {
  Setup(
    api: tailscale.Config,
    /// Run a script in a thread's sandbox, with extra `NAME=value` pairs.
    run: fn(String, List(String), String) -> Result(String, String),
  )
}

pub type Choice {
  Allow(hours: Int)
  Deny
  TurnOff
}

pub type Event {
  /// A card button was pressed, for the thread at `channel` and `thread_ts`.
  Pressed(
    choice: Choice,
    channel: String,
    thread_ts: String,
    user: String,
    card: Card,
  )
  /// The agent asks to join; the reply says whether the card went out.
  Asked(reason: String, reply: Subject(Result(String, String)))
  /// A join finished.
  JoinDone(Result(Nil, String))
  /// Check whether access has ended.
  Tick
}

/// How far a sandbox has got onto the tailnet. `tell` is who the note to
/// the agent comes from, when it should get one.
pub type Link {
  Joining(tell: Option(String))
  Joined
}

pub type Step {
  Join
  Leave(log_out: Bool)
  Stay
}

pub opaque type Tailnets {
  Tailnets(
    setup: Option(Setup),
    client: slackline.Client,
    allowed: Set(String),
    /// Send an event about a thread back after a delay in milliseconds.
    later: fn(String, Event, Int) -> Nil,
    links: Dict(String, Link),
    /// Threads with a card nobody has answered yet.
    asking: Set(String),
  )
}

/// A thread as tailnet access sees it. `home` is the thread's channel and
/// ts; `conversation` is where it talks now.
pub type Thread {
  Thread(
    running: Bool,
    grant: Option(Grant),
    home: #(String, String),
    conversation: #(String, String),
  )
}

pub type Change {
  Unchanged
  Granted(Grant)
  Revoked
}

/// What the registry does after an event: keep `tailnets`, change the
/// thread's grant, and maybe give the agent a note from a user.
pub type Outcome {
  Outcome(tailnets: Tailnets, grant: Change, note: Option(#(String, String)))
}

pub fn new(
  setup: Option(Setup),
  client: slackline.Client,
  allowed: Set(String),
  later: fn(String, Event, Int) -> Nil,
) -> Tailnets {
  Tailnets(
    setup:,
    client:,
    allowed:,
    later:,
    links: dict.new(),
    asking: set.new(),
  )
}

fn keep(tailnets: Tailnets) -> Outcome {
  Outcome(tailnets, Unchanged, None)
}

/// `thread` is the thread for `key`, if the bot knows it.
pub fn handle(
  t: Tailnets,
  key: String,
  thread: Option(Thread),
  event: Event,
) -> Outcome {
  case event, thread {
    Asked(reason:, reply:), Some(thread) if thread.running -> {
      let #(t, asked) = ask(t, key, thread, "", reason)
      process.send(reply, asked)
      keep(t)
    }
    Asked(reply:, ..), _ -> {
      process.send(reply, Error("this thread's agent isn't running"))
      keep(t)
    }
    Pressed(choice:, user:, card:, ..), thread ->
      pressed(t, key, thread, choice, user, card)
    JoinDone(result), thread -> joined(t, key, thread, result)
    Tick, Some(thread) -> check(t, key, thread, None)
    Tick, None -> keep(t)
  }
}

/// Post a card that asks to put the sandbox on the tailnet. `by` is who
/// asked, or "" for the agent. One card at a time.
pub fn ask(
  t: Tailnets,
  key: String,
  thread: Thread,
  by: String,
  reason: String,
) -> #(Tailnets, Result(String, String)) {
  let on = case thread.grant {
    Some(grant) -> grant.until_ms > sys.system_ms()
    None -> False
  }
  case t.setup, on, set.contains(t.asking, key) {
    None, _, _ -> #(t, Error("tailnet access isn't set up here"))
    _, True, _ -> #(t, Error("the sandbox is already on the tailnet"))
    _, _, True -> #(t, Error("a request is already waiting for an answer"))
    Some(setup), False, False -> {
      let client = t.client
      let blocks = ask_blocks(by, reason, key, setup.api.tag, thread.home)
      let #(channel, thread_ts) = thread.conversation
      process.spawn_unlinked(fn() {
        post_card(client, channel, thread_ts, blocks)
      })
      #(
        Tailnets(..t, asking: set.insert(t.asking, key)),
        Ok(
          "Asked in Slack. A message will tell you if someone allows it. Until then, carry on without it.",
        ),
      )
    }
  }
}

fn show(t: Tailnets, card: Card, blocks: List(block.Block)) -> Nil {
  let client = t.client
  process.spawn_unlinked(fn() { update_card(client, card, blocks) })
  Nil
}

fn pressed(
  t: Tailnets,
  key: String,
  thread: Option(Thread),
  choice: Choice,
  user: String,
  card: Card,
) -> Outcome {
  let t = Tailnets(..t, asking: set.delete(t.asking, key))
  case set.contains(t.allowed, user), thread, choice {
    False, _, _ -> {
      let client = t.client
      process.spawn_unlinked(fn() {
        let _ =
          chat.post_ephemeral(
            channel: card.channel,
            user:,
            text: "Only the people this agent works for can change its access.",
          )
          |> post_ephemeral.thread_ts(card.thread_ts)
          |> httpc.send(client)
        Nil
      })
      keep(t)
    }
    True, None, _ -> {
      show(t, card, done_blocks("_This thread is gone._"))
      keep(t)
    }
    True, Some(_), Deny -> {
      show(
        t,
        card,
        done_blocks("_<@" <> user <> "> kept the sandbox off the tailnet._"),
      )
      keep(t)
    }
    True, Some(thread), TurnOff -> {
      let text = "_<@" <> user <> "> took the sandbox off the tailnet._"
      case thread.grant {
        Some(_) -> end(t, key, thread, text)
        None -> {
          show(t, card, done_blocks(text))
          keep(t)
        }
      }
    }
    True, Some(thread), Allow(hours) -> {
      let until_ms = sys.system_ms() + hours * 3_600_000
      show(t, card, on_blocks(until_ms, user, thread.home))
      let grant = meta.Grant(until_ms:, card:)
      Outcome(
        ..check(t, key, Thread(..thread, grant: Some(grant)), Some(user)),
        grant: Granted(grant),
      )
    }
  }
}

/// End access that has run out, or wait for it to, and sync.
pub fn check(
  t: Tailnets,
  key: String,
  thread: Thread,
  tell: Option(String),
) -> Outcome {
  case thread.grant {
    Some(grant) ->
      case grant.until_ms - sys.system_ms() {
        left if left > 0 -> {
          t.later(key, Tick, left)
          keep(sync(t, key, thread.running, thread.grant, tell))
        }
        _ -> end(t, key, thread, "_The sandbox's tailnet access ended._")
      }
    None -> keep(sync(t, key, thread.running, None, tell))
  }
}

/// End a thread's access, and say why on its card.
pub fn end(t: Tailnets, key: String, thread: Thread, text: String) -> Outcome {
  case thread.grant {
    None -> keep(t)
    Some(grant) -> {
      show(t, grant.card, done_blocks(text))
      Outcome(sync(t, key, thread.running, None, None), Revoked, None)
    }
  }
}

/// Forget a sandbox whose container stopped.
pub fn stopped(t: Tailnets, key: String) -> Tailnets {
  sync(t, key, False, None, None)
}

fn sync(
  t: Tailnets,
  key: String,
  running: Bool,
  grant: Option(Grant),
  tell: Option(String),
) -> Tailnets {
  let wanted = case grant {
    Some(grant) -> running && grant.until_ms > sys.system_ms()
    None -> False
  }
  let link = dict.get(t.links, key) |> option.from_result
  case t.setup, step(wanted, link, running) {
    None, _ | _, Stay -> t
    Some(setup), Join -> {
      let later = t.later
      process.spawn_unlinked(fn() { later(key, JoinDone(join(setup, key)), 0) })
      Tailnets(..t, links: dict.insert(t.links, key, Joining(tell)))
    }
    // A stopped container has taken its ephemeral node with it.
    Some(setup), Leave(log_out:) -> {
      case log_out {
        True -> {
          process.spawn_unlinked(fn() { leave(setup, key) })
          Nil
        }
        False -> Nil
      }
      Tailnets(..t, links: dict.delete(t.links, key))
    }
  }
}

fn joined(
  t: Tailnets,
  key: String,
  thread: Option(Thread),
  result: Result(Nil, String),
) -> Outcome {
  let tell = case dict.get(t.links, key) {
    Ok(Joining(tell:)) -> tell
    _ -> None
  }
  let gone = Tailnets(..t, links: dict.delete(t.links, key))
  case result, thread {
    Ok(Nil), Some(thread) if thread.running -> {
      let t = Tailnets(..t, links: dict.insert(t.links, key, Joined))
      let note = case tell, thread.grant {
        Some(user), Some(grant) ->
          Some(#(joined_note(grant.until_ms - sys.system_ms()), user))
        _, _ -> None
      }
      Outcome(sync(t, key, True, thread.grant, None), Unchanged, note)
    }
    Error(reason), Some(thread) if thread.running -> {
      sys.warn("crushling: " <> key <> " couldn't join the tailnet: " <> reason)
      end(
        gone,
        key,
        thread,
        "_couldn't put the sandbox on the tailnet: " <> reason <> "_",
      )
    }
    // The agent stopped while it joined; its access waits for the next one.
    _, _ -> keep(gone)
  }
}

/// What to do so the sandbox is on the tailnet exactly when it is `wanted`.
/// A join in flight finishes before anything else happens.
pub fn step(wanted: Bool, link: Option(Link), running: Bool) -> Step {
  case wanted, link {
    True, None -> Join
    False, Some(Joined) -> Leave(log_out: running)
    _, _ -> Stay
  }
}

pub fn join(setup: Setup, key: String) -> Result(Nil, String) {
  use auth_key <- result.try(tailscale.new_auth_key(setup.api))
  setup.run(
    key,
    ["TS_AUTHKEY=" <> auth_key, "TS_HOSTNAME=" <> tailscale.hostname(key)],
    tailscale.join_script(),
  )
  |> result.replace(Nil)
}

pub fn leave(setup: Setup, key: String) -> Nil {
  let _ = setup.run(key, [], tailscale.leave_script())
  Nil
}

const allow_action = "tailnet_allow_"

const deny_action = "tailnet_deny"

const off_action = "tailnet_off"

/// The hours each "allow" button offers.
const offers = [1, 8]

/// Every button's action id. Slack wants them unique within a block, so each
/// "allow" button carries its hours in its id.
pub fn action_ids() -> List(String) {
  [
    deny_action,
    off_action,
    ..list.map(offers, fn(hours) { allow_action <> int.to_string(hours) })
  ]
}

/// Read a pressed button: what it asks for, and the thread's channel and ts
/// from its value.
pub fn read_button(
  action_id: String,
  value: String,
) -> Result(#(Choice, String, String), Nil) {
  use #(channel, thread_ts) <- result.try(string.split_once(value, "|"))
  use choice <- result.map(case action_id {
    "tailnet_allow_" <> hours ->
      case int.parse(hours) {
        Ok(hours) ->
          case list.contains(offers, hours) {
            True -> Ok(Allow(hours))
            False -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
    "tailnet_deny" -> Ok(Deny)
    "tailnet_off" -> Ok(TurnOff)
    _ -> Error(Nil)
  })
  #(choice, channel, thread_ts)
}

/// The card a press came from, when it came from a message.
pub fn card(
  channel: Option(String),
  ts: Option(String),
  thread_ts: Option(String),
) -> Result(Card, Nil) {
  case channel, ts {
    Some(channel), Some(ts) ->
      Ok(meta.Card(channel:, ts:, thread_ts: option.unwrap(thread_ts, "")))
    _, _ -> Error(Nil)
  }
}

fn lasts(hours: Int) -> String {
  case hours {
    1 -> "1 hour"
    hours -> int.to_string(hours) <> " hours"
  }
}

/// Time left, in words: whole hours, or minutes under an hour.
pub fn remaining(ms: Int) -> String {
  case ms < 3_600_000 {
    True ->
      case int.max({ ms + 30_000 } / 60_000, 1) {
        1 -> "1 minute"
        minutes -> int.to_string(minutes) <> " minutes"
      }
    False -> lasts({ ms + 1_800_000 } / 3_600_000)
  }
}

/// What the agent is told once its sandbox is on the tailnet.
pub fn joined_note(left_ms: Int) -> String {
  "[crushling] This sandbox is now on the tailnet for "
  <> remaining(left_ms)
  <> ". ssh reaches tailnet machines by name or 100.x address and goes through Tailscale by itself. For HTTP and other TCP, use the proxy: `curl --proxy socks5h://localhost:"
  <> int.to_string(tailscale.socks_port)
  <> " http://<machine>:<port>/`, or `http_proxy=http://localhost:"
  <> int.to_string(tailscale.http_port)
  <> "`. The tailnet's access rules decide which machines answer. Access ends by itself, or when someone in Slack turns it off. Carry on with what you were doing."
}

/// A Slack date in each reader's own time zone.
fn when(ms: Int) -> String {
  "<!date^"
  <> int.to_string(ms / 1000)
  <> "^{date_short_pretty} at {time}|soon>"
}

fn button(
  text: String,
  action_id: String,
  thread: #(String, String),
  style: List(block.Attr(block.ButtonElement)),
) -> block.Element {
  element.button(text:, action_id:, with: [
    button.value(thread.0 <> "|" <> thread.1),
    ..style
  ])
}

/// The card that asks to put the sandbox on the tailnet. `by` is who asked,
/// or "" for the agent. `thread` is the thread's channel and ts.
pub fn ask_blocks(
  by: String,
  reason: String,
  key: String,
  tag: String,
  thread: #(String, String),
) -> List(block.Block) {
  let who = case by {
    "" -> "The agent wants"
    user -> "<@" <> user <> "> wants"
  }
  let why = case string.trim(reason) {
    "" -> ""
    reason ->
      string.split(reason, "\n")
      |> list.map(fn(line) { "\n> " <> line })
      |> string.concat
  }
  let allow =
    list.map(offers, fn(hours) {
      button(
        "Allow for " <> lasts(hours),
        allow_action <> int.to_string(hours),
        thread,
        [],
      )
    })
  [
    block.markdown(
      who
        <> " this sandbox on the tailnet."
        <> why
        <> "\nIt would join as `"
        <> tailscale.hostname(key)
        <> "`, tagged `"
        <> tag
        <> "`. The tailnet's access rules decide which machines it can reach.",
      [],
    ),
    block.actions(
      elements: list.append(allow, [button("Deny", deny_action, thread, [])]),
      with: [],
    ),
  ]
}

/// The card while access is on, with a button that turns it off.
pub fn on_blocks(
  until_ms: Int,
  by: String,
  thread: #(String, String),
) -> List(block.Block) {
  [
    block.markdown(
      "The sandbox is on the tailnet until "
        <> when(until_ms)
        <> ". <@"
        <> by
        <> "> allowed it.",
      [],
    ),
    block.actions(
      elements: [
        button("Turn off", off_action, thread, [button.style(block.Danger)]),
      ],
      with: [],
    ),
  ]
}

/// A card with nothing left to press.
pub fn done_blocks(text: String) -> List(block.Block) {
  [block.markdown(text, [])]
}

pub fn post_card(
  client: slackline.Client,
  channel: String,
  thread_ts: String,
  blocks: List(block.Block),
) -> Nil {
  let call =
    chat.post_message(channel:, text: "Tailnet access")
    |> post_message.blocks(blocks)
  let _ =
    case thread_ts {
      "" -> call
      ts -> post_message.thread_ts(call, ts)
    }
    |> httpc.send(client)
  Nil
}

pub fn update_card(
  client: slackline.Client,
  card: Card,
  blocks: List(block.Block),
) -> Nil {
  let _ =
    chat.update(channel: card.channel, ts: card.ts)
    |> update.text("Tailnet access")
    |> update.blocks(blocks)
    |> httpc.send(client)
  Nil
}
