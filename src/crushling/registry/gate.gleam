//// Who may drive agents: the ids allowed, and when everyone is, members of
//// the workspace. Membership is looked up off the registry and cached; what
//// a user sent meanwhile waits here and is handed back with the answer.

import crushling/people.{type People}
import crushling/sys
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import slackline

pub opaque type Gate(msg) {
  Gate(
    allowed: People,
    client: slackline.Client,
    team: String,
    /// Sends an answer back to the registry after a delay in milliseconds.
    reply: fn(Answer, Int) -> Nil,
    members: people.Cache,
    /// Lookups in flight by user: the id, and what waits, newest first.
    looking_up: Dict(String, #(Int, List(msg))),
    lookups: Int,
  )
}

/// A membership lookup's answer, for `answered`.
pub opaque type Answer {
  Answer(user: String, id: Int, result: Result(Bool, String))
}

pub type Verdict(msg) {
  Allowed
  Denied
  /// The message waits for a lookup; keep this gate.
  Waiting(Gate(msg))
}

/// How long a lookup gets before what waits for it is turned away.
const timeout_ms = 15_000

pub fn new(
  allowed: People,
  client: slackline.Client,
  team: String,
  reply: fn(Answer, Int) -> Nil,
) -> Gate(msg) {
  Gate(
    allowed:,
    client:,
    team:,
    reply:,
    members: people.new_cache(people.cache_ms),
    looking_up: dict.new(),
    lookups: 0,
  )
}

/// Admins approve tailnet access, else the ids allowed; being in the workspace isn't enough for the operator's tailnet.
pub fn approvers(allowed: People, admins: Set(String)) -> People {
  case set.is_empty(admins), allowed.everyone {
    False, _ -> people.People(everyone: False, ids: admins)
    True, True -> people.nobody()
    True, False -> allowed
  }
}

/// Whether `user` may send `message`; when membership is unknown it is looked up and `message` waits.
pub fn check(gate: Gate(msg), user: String, message: msg) -> Verdict(msg) {
  let now = sys.monotonic_ms()
  let cached = people.cached(gate.members, user, now)
  let allowed =
    people.allows(gate.allowed, user, fn(_) { cached == Some(True) })
  case allowed, people.needs_lookup(gate.allowed, user) && cached == None {
    True, _ -> Allowed
    False, False -> Denied
    False, True -> Waiting(wait(gate, user, message))
  }
}

fn wait(gate: Gate(msg), user: String, message: msg) -> Gate(msg) {
  case dict.get(gate.looking_up, user) {
    Ok(#(id, queue)) ->
      Gate(
        ..gate,
        looking_up: dict.insert(
          gate.looking_up,
          user,
          #(id, [message, ..queue]),
        ),
      )
    Error(Nil) -> {
      let id = gate.lookups + 1
      let Gate(client:, team:, reply:, ..) = gate
      process.spawn_unlinked(fn() {
        reply(Answer(user, id, people.lookup(client, team, user)), 0)
      })
      reply(Answer(user, id, Error("users.info took too long")), timeout_ms)
      Gate(
        ..gate,
        lookups: id,
        looking_up: dict.insert(gate.looking_up, user, #(id, [message])),
      )
    }
  }
}

/// Keep a lookup's answer and hand back what waited, oldest first; call `forget_failed` after re-checking them.
pub fn answered(gate: Gate(msg), answer: Answer) -> #(Gate(msg), List(msg)) {
  let Answer(user:, id:, result:) = answer
  let now = sys.monotonic_ms()
  case dict.get(gate.looking_up, user) {
    Ok(#(current, queue)) if current == id -> {
      case result {
        Ok(_) -> Nil
        Error(reason) ->
          sys.warn(
            "crushling: couldn't tell whether "
            <> user
            <> " is a member of "
            <> gate.team
            <> ", so ignoring them for now: "
            <> reason,
          )
      }
      let members =
        people.remember(gate.members, user, result.unwrap(result, False), now)
      #(
        Gate(..gate, members:, looking_up: dict.delete(gate.looking_up, user)),
        list.reverse(queue),
      )
    }
    // A late answer to a lookup that timed out is still good to keep.
    _ ->
      case result {
        Ok(member) -> #(
          Gate(
            ..gate,
            members: people.remember(gate.members, user, member, now),
          ),
          [],
        )
        Error(_) -> #(gate, [])
      }
  }
}

/// Forget a failed lookup's refusal once what waited is turned away, so the next message asks again.
pub fn forget_failed(gate: Gate(msg), answer: Answer) -> Gate(msg) {
  let refused =
    people.cached(gate.members, answer.user, sys.monotonic_ms()) == Some(False)
  case answer.result, refused {
    Error(_), True ->
      Gate(..gate, members: people.forget(gate.members, answer.user))
    _, _ -> gate
  }
}
