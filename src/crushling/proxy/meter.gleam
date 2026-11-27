//// The inference proxy's bookkeeping: what each thread and each workspace
//// has spent, the caps they are held to, which threads may spend at all,
//// and which requests are in flight. One actor holds it all, so admission
//// is atomic and a stop or a cap takes effect on the very next request or
//// chunk.
////
//// Spend is counted in tokens (prompt plus completion) and in US dollars, as
//// Hyper reports both in every response's `usage`. A cap may set either or
//// both; a thread is over its cap once it reaches any limit that is set.
//// The thread cap counts everything the thread ever spent; the workspace
//// cap counts the last 30 days of the thread's workspace (from its key), so
//// one workspace reaching its cap leaves the others alone.
////
//// Only threads whose agent is up may spend: the lifecycle owner
//// (`crushling/agents`, through the launcher) allows a thread as it starts
//// and disallows it as it stops. The list starts empty, so after a restart
//// no old token works until its agent is launched again.
////
//// With a `Keeper`, totals start from what the store kept (read the first
//// time a thread or workspace is seen) and new spend is saved there every
//// `every_ms`; a batch the store refuses is kept for the next try, and a
//// flush waits for any save in flight, so nothing is lost at exit. These
//// are still soft limits: usage is only known when a response finishes, so
//// requests already in flight when a cap is reached can overshoot it, each
//// by at most its own cost (and a thread has at most `max_per_thread` in
//// flight).

import crushling/key
import crushling/sys
import crushling/usage.{type Cap, type Usage, add, reached, zero}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}

/// How much may happen at once.
pub type Limits {
  Limits(
    thread_cap: Cap,
    /// Each workspace's cap, over all its threads.
    team_cap: Cap,
    /// Requests one thread may have in flight.
    max_per_thread: Int,
    /// Request bodies being read at once, across every thread.
    max_uploads: Int,
  )
}

/// Where spend outlives the bridge.
pub type Keeper {
  Keeper(
    /// What a thread spent before this meter started.
    thread_total: fn(String) -> Result(Usage, String),
    /// What a workspace spent before this meter started, over the window
    /// its cap counts.
    team_total: fn(String) -> Result(Usage, String),
    /// Keep a batch of spend, by thread.
    save: fn(List(#(String, Usage))) -> Result(Nil, String),
    /// How often new spend is saved.
    every_ms: Int,
  )
}

/// Why a thread may not spend.
pub type Denial {
  /// Its agent isn't up.
  Revoked
  ThreadCap
  TeamCap
  /// The thread already has `max_per_thread` requests in flight.
  ThreadBusy
  /// `max_uploads` request bodies are already being read.
  InstanceBusy
}

/// Spend taken out of the meter to be kept, until it is settled.
pub type Batch {
  Batch(id: Int, spent: List(#(String, Usage)))
}

pub type Message {
  Admit(key: String, owner: Pid, reply: Subject(Result(Nil, Denial)))
  Uploaded(owner: Pid)
  Check(key: String, reply: Subject(Result(Nil, Denial)))
  Record(key: String, usage: Usage, reply: Subject(Nil))
  Allow(key: String, reply: Subject(Nil))
  Disallow(key: String, reply: Subject(Nil))
  SetThreadCap(key: String, cap: Option(Cap))
  Totals(key: String, reply: Subject(Usage))
  TeamTotals(team: String, reply: Subject(Usage))
  Take(reply: Subject(Batch))
  Settle(id: Int, kept: Bool)
  /// Save what is unsaved now, and say whether it was kept.
  Flush(reply: Subject(Result(Nil, String)))
  /// Time to save, with the keeper.
  FlushTick
  OwnerDown(owner: Pid)
}

/// An admitted request, held until its owner exits.
type Admission {
  Admission(key: String, uploading: Bool, monitor: process.Monitor)
}

type State {
  State(
    self: Subject(Message),
    limits: Limits,
    keeper: Option(Keeper),
    usage: Dict(String, Usage),
    teams: Dict(String, Usage),
    /// Threads and workspaces whose stored totals have been read.
    seeded: Set(#(Bool, String)),
    /// What was recorded since it was last taken, by thread.
    undrained: Dict(String, Usage),
    /// Batches taken and not yet settled.
    taken: Dict(Int, List(#(String, Usage))),
    next_batch: Int,
    /// The keeper's saves running off the actor: batch id to its worker.
    saving: Dict(Int, Pid),
    /// Flushes waiting for those saves to settle first.
    flushing: List(Subject(Result(Nil, String))),
    allowed: Set(String),
    overrides: Dict(String, Cap),
    admitted: Dict(Pid, Admission),
  )
}

/// A meter that keeps nothing beyond the bridge's life.
pub fn start(limits: Limits) -> Result(Subject(Message), actor.StartError) {
  start_with(limits, None, None) |> result.map(fn(started) { started.data })
}

/// A meter, registered under `name` when given, keeping spend with
/// `keeper` when given.
pub fn start_with(
  limits: Limits,
  keeper: Option(Keeper),
  name: Option(process.Name(Message)),
) -> actor.StartResult(Subject(Message)) {
  let builder =
    actor.new_with_initialiser(1000, fn(self) {
      let selector =
        process.new_selector()
        |> process.select(self)
        |> process.select_monitors(fn(down) {
          case down {
            process.ProcessDown(pid:, ..) -> OwnerDown(pid)
            // Only processes are monitored.
            process.PortDown(..) -> OwnerDown(process.self())
          }
        })
      case keeper {
        Some(keeper) -> {
          process.send_after(self, keeper.every_ms, FlushTick)
          Nil
        }
        None -> Nil
      }
      State(
        self:,
        limits:,
        keeper:,
        usage: dict.new(),
        teams: dict.new(),
        seeded: set.new(),
        undrained: dict.new(),
        taken: dict.new(),
        next_batch: 1,
        saving: dict.new(),
        flushing: [],
        allowed: set.new(),
        overrides: dict.new(),
        admitted: dict.new(),
      )
      |> actor.initialised
      |> actor.selecting(selector)
      |> actor.returning(self)
      |> Ok
    })
    |> actor.on_message(handle)
  case name {
    Some(name) -> actor.named(builder, name)
    None -> builder
  }
  |> actor.start
}

fn team_of(thread: String) -> String {
  key.parse(thread) |> result.map(key.team) |> result.unwrap("")
}

/// Read a thread's and its workspace's stored totals the first time either
/// is seen. A read that fails is tried again next time.
fn seed(state: State, thread: String) -> State {
  case state.keeper {
    None -> state
    Some(keeper) -> {
      let state =
        seed_one(state, #(False, thread), keeper.thread_total, fn(state, found) {
          State(..state, usage: dict.insert(state.usage, thread, found))
        })
      let team = team_of(thread)
      seed_one(state, #(True, team), keeper.team_total, fn(state, found) {
        State(..state, teams: dict.insert(state.teams, team, found))
      })
    }
  }
}

fn seed_one(
  state: State,
  which: #(Bool, String),
  read: fn(String) -> Result(Usage, String),
  put: fn(State, Usage) -> State,
) -> State {
  case set.contains(state.seeded, which) {
    True -> state
    False ->
      case read(which.1) {
        Ok(stored) -> {
          let state = State(..state, seeded: set.insert(state.seeded, which))
          let current = case which {
            #(False, thread) -> dict.get(state.usage, thread)
            #(True, team) -> dict.get(state.teams, team)
          }
          put(state, add(stored, result.unwrap(current, zero)))
        }
        Error(reason) -> {
          sys.warn(
            "crushling: reading the spend of " <> which.1 <> ": " <> reason,
          )
          state
        }
      }
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Admit(key, owner, reply) -> {
      let state = seed(state, key)
      let in_flight =
        dict.fold(state.admitted, 0, fn(n, _, admission) {
          case admission.key == key {
            True -> n + 1
            False -> n
          }
        })
      let uploads =
        dict.fold(state.admitted, 0, fn(n, _, admission) {
          case admission.uploading {
            True -> n + 1
            False -> n
          }
        })
      let verdict = case check(state, key) {
        Error(denial) -> Error(denial)
        Ok(Nil) if in_flight >= state.limits.max_per_thread -> Error(ThreadBusy)
        Ok(Nil) if uploads >= state.limits.max_uploads -> Error(InstanceBusy)
        Ok(Nil) -> Ok(Nil)
      }
      process.send(reply, verdict)
      case verdict, dict.has_key(state.admitted, owner) {
        Ok(Nil), False -> {
          let admission = Admission(key, True, process.monitor(owner))
          actor.continue(
            State(
              ..state,
              admitted: dict.insert(state.admitted, owner, admission),
            ),
          )
        }
        _, _ -> actor.continue(state)
      }
    }
    Uploaded(owner) ->
      case dict.get(state.admitted, owner) {
        Ok(admission) ->
          actor.continue(
            State(
              ..state,
              admitted: dict.insert(
                state.admitted,
                owner,
                Admission(..admission, uploading: False),
              ),
            ),
          )
        Error(Nil) -> actor.continue(state)
      }
    OwnerDown(owner) -> {
      let state = State(..state, admitted: dict.delete(state.admitted, owner))
      // A save that died without settling: its batch goes back.
      let lost =
        dict.filter(state.saving, fn(_, worker) { worker == owner })
        |> dict.keys
      list.fold(lost, state, fn(state, id) { settle_batch(state, id, False) })
      |> after_settle
      |> actor.continue
    }
    Check(key, reply) -> {
      let state = seed(state, key)
      process.send(reply, check(state, key))
      actor.continue(state)
    }
    Record(key, spent, reply) -> {
      let state = seed(state, key)
      let team = team_of(key)
      let get = fn(totals, name) {
        dict.get(totals, name) |> result.unwrap(zero)
      }
      process.send(reply, Nil)
      actor.continue(
        State(
          ..state,
          usage: dict.insert(
            state.usage,
            key,
            add(get(state.usage, key), spent),
          ),
          teams: dict.insert(
            state.teams,
            team,
            add(get(state.teams, team), spent),
          ),
          undrained: dict.insert(
            state.undrained,
            key,
            add(get(state.undrained, key), spent),
          ),
        ),
      )
    }
    Allow(key, reply) -> {
      process.send(reply, Nil)
      actor.continue(State(..state, allowed: set.insert(state.allowed, key)))
    }
    Disallow(key, reply) -> {
      process.send(reply, Nil)
      actor.continue(State(..state, allowed: set.delete(state.allowed, key)))
    }
    SetThreadCap(key, Some(cap)) ->
      actor.continue(
        State(..state, overrides: dict.insert(state.overrides, key, cap)),
      )
    SetThreadCap(key, None) ->
      actor.continue(
        State(..state, overrides: dict.delete(state.overrides, key)),
      )
    Totals(key, reply) -> {
      let state = seed(state, key)
      process.send(reply, dict.get(state.usage, key) |> result.unwrap(zero))
      actor.continue(state)
    }
    TeamTotals(team, reply) -> {
      process.send(reply, dict.get(state.teams, team) |> result.unwrap(zero))
      actor.continue(state)
    }
    Take(reply) -> {
      let #(state, batch) = take_batch(state)
      process.send(reply, batch)
      actor.continue(state)
    }
    Settle(id, kept) ->
      settle_batch(state, id, kept) |> after_settle |> actor.continue
    // A batch in flight may yet fail and come back, so wait for it.
    Flush(reply) ->
      case dict.is_empty(state.saving) {
        True -> actor.continue(flush_now(state, [reply]))
        False ->
          actor.continue(State(..state, flushing: [reply, ..state.flushing]))
      }
    FlushTick ->
      case state.keeper {
        None -> actor.continue(state)
        Some(keeper) -> {
          process.send_after(state.self, keeper.every_ms, FlushTick)
          case !dict.is_empty(state.saving) || dict.is_empty(state.undrained) {
            True -> actor.continue(state)
            False -> {
              let #(state, batch) = take_batch(state)
              let self = state.self
              // Off the actor, so a slow store doesn't hold up admission.
              let worker =
                process.spawn_unlinked(fn() {
                  let kept = case keeper.save(batch.spent) {
                    Ok(Nil) -> True
                    Error(reason) -> {
                      sys.warn(
                        "crushling: saving spend failed, keeping it for the next try: "
                        <> reason,
                      )
                      False
                    }
                  }
                  process.send(self, Settle(batch.id, kept))
                })
              process.monitor(worker)
              actor.continue(
                State(
                  ..state,
                  saving: dict.insert(state.saving, batch.id, worker),
                ),
              )
            }
          }
        }
      }
  }
}

fn take_batch(state: State) -> #(State, Batch) {
  let id = state.next_batch
  let spent = dict.to_list(state.undrained)
  #(
    State(
      ..state,
      undrained: dict.new(),
      taken: dict.insert(state.taken, id, spent),
      next_batch: id + 1,
    ),
    Batch(id, spent),
  )
}

/// A batch that wasn't kept goes back, to be taken again.
fn settle_batch(state: State, id: Int, kept: Bool) -> State {
  let spent = dict.get(state.taken, id) |> result.unwrap([])
  let undrained = case kept {
    True -> state.undrained
    False ->
      list.fold(spent, state.undrained, fn(undrained, pair) {
        let #(key, spent) = pair
        dict.insert(
          undrained,
          key,
          add(dict.get(undrained, key) |> result.unwrap(zero), spent),
        )
      })
  }
  State(
    ..state,
    undrained:,
    taken: dict.delete(state.taken, id),
    saving: dict.delete(state.saving, id),
  )
}

/// Run the flushes that waited, once no save is in flight.
fn after_settle(state: State) -> State {
  case dict.is_empty(state.saving), state.flushing {
    True, [_, ..] as waiting -> flush_now(State(..state, flushing: []), waiting)
    _, _ -> state
  }
}

/// Save what is unsaved now, on the actor, and tell each of `replies`.
fn flush_now(
  state: State,
  replies: List(Subject(Result(Nil, String))),
) -> State {
  let #(state, batch) = take_batch(state)
  let saved = case state.keeper, batch.spent {
    _, [] | None, _ -> Ok(Nil)
    Some(keeper), spent -> keeper.save(spent)
  }
  list.each(replies, process.send(_, saved))
  settle_batch(state, batch.id, result.is_ok(saved))
}

/// Whether the thread may spend, and its caps, without the in-flight limits.
fn check(state: State, key: String) -> Result(Nil, Denial) {
  let thread = dict.get(state.usage, key) |> result.unwrap(zero)
  let team = dict.get(state.teams, team_of(key)) |> result.unwrap(zero)
  let cap =
    dict.get(state.overrides, key) |> result.unwrap(state.limits.thread_cap)
  case
    set.contains(state.allowed, key),
    reached(thread, cap),
    reached(team, state.limits.team_cap)
  {
    False, _, _ -> Error(Revoked)
    _, True, _ -> Error(ThreadCap)
    _, _, True -> Error(TeamCap)
    True, False, False -> Ok(Nil)
  }
}

const timeout = 5000

/// Admit a request for `key`, held by `owner` until it exits. The request
/// counts as an upload until `uploaded`.
pub fn admit(
  meter: Subject(Message),
  key: String,
  owner: Pid,
) -> Result(Nil, Denial) {
  process.call(meter, timeout, Admit(key, owner, _))
}

/// `owner` has finished reading its request body.
pub fn uploaded(meter: Subject(Message), owner: Pid) -> Nil {
  process.send(meter, Uploaded(owner))
}

/// Whether `key` may keep spending: allowed and under its caps.
pub fn check_key(meter: Subject(Message), key: String) -> Result(Nil, Denial) {
  process.call(meter, timeout, Check(key, _))
}

/// Add a response's usage to `key`'s and its workspace's totals.
pub fn record(meter: Subject(Message), key: String, usage: Usage) -> Nil {
  process.call(meter, timeout, Record(key, usage, _))
}

/// Let `key` spend, from its next request on.
pub fn allow(meter: Subject(Message), key: String) -> Nil {
  process.call(meter, timeout, Allow(key, _))
}

/// Stop `key` from spending, from its next request or chunk on.
pub fn disallow(meter: Subject(Message), key: String) -> Nil {
  process.call(meter, timeout, Disallow(key, _))
}

/// Hold `key` to `cap` instead of the default thread cap, or back to the
/// default with `None`.
pub fn set_thread_cap(
  meter: Subject(Message),
  key: String,
  cap: Option(Cap),
) -> Nil {
  process.send(meter, SetThreadCap(key, cap))
}

pub fn totals(meter: Subject(Message), key: String) -> Usage {
  process.call(meter, timeout, Totals(key, _))
}

pub fn team_totals(meter: Subject(Message), team: String) -> Usage {
  process.call(meter, timeout, TeamTotals(team, _))
}

/// Take what each thread spent since it was last taken. Settle the batch
/// with whether it was kept: one that wasn't goes back to be taken again.
pub fn take(meter: Subject(Message)) -> Batch {
  process.call(meter, timeout, Take)
}

pub fn settle(meter: Subject(Message), batch: Batch, kept: Bool) -> Nil {
  process.send(meter, Settle(batch.id, kept))
}

/// Take and settle at once, for a caller that can't fail to keep it.
pub fn drain(meter: Subject(Message)) -> List(#(String, Usage)) {
  let batch = take(meter)
  settle(meter, batch, True)
  batch.spent
}

/// Save what is unsaved with the keeper now, as at shutdown.
pub fn flush(meter: Subject(Message)) -> Result(Nil, String) {
  process.call(meter, 30_000, Flush)
}
