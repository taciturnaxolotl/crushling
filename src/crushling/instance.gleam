//// One instance per Slack workspace the bridge serves, under a supervisor:
//// `team_id -> Instance`.
////
//// An instance is the workspace's registry and its Slack client (with that
//// workspace's bot token). Everything else is shared by every instance, one
//// each per bridge: the lifecycle owner, the tunnels and the proxy behind it
//// (thread keys carry the team, so they never collide), the sandbox server,
//// the store and the instance secret.
////
//// Each registry is a child of a factory supervisor, registered under a
//// name of its own: a crash in one workspace leaves the others running, and
//// the supervisor starts it again (from the store, so with its latest
//// token) under the same name. The teams actor beside it only remembers the
//// names, so the two restart together (one-for-all): a teams actor that
//// forgot its names never meets registries it can't see, and starts every
//// stored workspace afresh, the self-host one first. Who may use a workspace
//// is `people.settled` over its settings.

import crushling/agents.{type Agents}
import crushling/crush/client
import crushling/github/broker
import crushling/key as thread_key
import crushling/people.{type People}
import crushling/registry
import crushling/registry/config as registry_config
import crushling/registry/legacy
import crushling/registry/shutdown
import crushling/registry/tailnet
import crushling/slack/workspace.{type Outbox, type Workspace}
import crushling/store.{type Store}
import crushling/store/teams
import crushling/store/threads
import crushling/sys
import crushling/tools
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import gleam/set.{type Set}
import gleam/string
import slackline
import slackline/api/auth
import slackline/httpc

/// What every instance shares, and how to make each one's parts.
pub type Shared {
  Shared(
    agents: Agents,
    store: Store,
    root: String,
    mode: client.PermissionMode,
    idle_ms: Int,
    flush_ms: Int,
    /// The workspace from `SLACK_BOT_TOKEN`, if any, and its settings from
    /// the environment, used where its `team_settings` have none.
    env_team: Option(EnvTeam),
    /// Tailnet access. Only the environment's workspace gets it: the
    /// Tailscale credential is the operator's own.
    tailnet: Option(tailnet.Setup),
    /// A Slack client for a bot token; `slackline.new` but in tests.
    client: fn(String) -> slackline.Client,
    /// The GitHub App people connect their accounts through, if set up.
    github: Option(broker.GitHub),
    default_model: String,
  )
}

pub type EnvTeam {
  EnvTeam(id: String, allowed: People, admins: Set(String))
}

/// A running workspace: its Slack handle and its registry.
pub type Instance {
  Instance(workspace: Workspace, registry: Subject(registry.Message))
}

pub opaque type Teams {
  Teams(subject: Subject(Message))
}

pub opaque type Message {
  Start(team: teams.Team, reply: Subject(Result(Instance, String)))
  Find(team: String, reply: Subject(Option(Instance)))
  All(reply: Subject(List(Instance)))
  /// Shutdown is under way: reply with every instance, by team, up or not.
  Drain(reply: Subject(List(#(String, Instance))))
  /// Start every active workspace in the store, as the teams actor starts.
  StartStored
  /// Reply with how `StartStored` went, once it has run.
  Started(reply: Subject(Result(List(#(String, String)), String)))
}

/// What the factory needs to start, and restart, a workspace's registry.
type Spawn {
  Spawn(team: String, name: process.Name(registry.Message), outbox: Outbox)
}

type Running {
  Running(instance: Instance, name: process.Name(registry.Message))
}

type State {
  State(
    shared: Shared,
    registries: factory.Supervisor(Spawn, Subject(registry.Message)),
    running: Dict(String, Running),
    /// How starting the stored workspaces went: those that failed, with why.
    started: Result(List(#(String, String)), String),
  )
}

const timeout_ms = 10_000

/// The workspaces as a supervised child: the registries' factory and the
/// teams actor, restarted together. Reach them with `named(name)`.
pub fn supervised(
  shared: Shared,
  name: process.Name(Message),
) -> supervision.ChildSpecification(supervisor.Supervisor) {
  supervision.supervisor(fn() { start_tree(shared, name) })
}

/// The teams registered under `name`.
pub fn named(name: process.Name(Message)) -> Teams {
  Teams(process.named_subject(name))
}

/// The workspaces, linked to the caller, under a fresh name.
pub fn start(shared: Shared) -> Result(Teams, String) {
  let name = process.new_name("crushling_teams")
  start_tree(shared, name)
  |> result.map(fn(_) { named(name) })
  |> result.map_error(fn(error) { "teams: " <> string.inspect(error) })
}

fn start_tree(
  shared: Shared,
  name: process.Name(Message),
) -> actor.StartResult(supervisor.Supervisor) {
  // Only the self-host workspace has threads from before keys carried the
  // workspace. Moved here, once, as moving each can take a docker call.
  let stranded = case shared.env_team {
    Some(env) ->
      legacy.migrate(shared.store, shared.agents, shared.root, env.id)
    None -> set.new()
  }
  let factory_name = process.new_name("crushling_registries")
  let registries =
    factory.worker_child(fn(spawn: Spawn) {
      start_registry(shared, stranded, spawn)
    })
    // A registry that shuts down isn't started again; one that crashes is.
    |> factory.restart_strategy(supervision.Transient)
    |> factory.restart_tolerance(intensity: 5, period: 10)
    |> factory.named(factory_name)
  supervisor.new(supervisor.OneForAll)
  |> supervisor.add(factory.supervised(registries))
  |> supervisor.add(
    supervision.worker(fn() {
      start_teams(shared, factory.get_by_name(factory_name), name)
    }),
  )
  |> supervisor.start
}

fn start_teams(
  shared: Shared,
  registries: factory.Supervisor(Spawn, Subject(registry.Message)),
  name: process.Name(Message),
) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(timeout_ms, fn(self) {
    // After init, so a slow store doesn't hold up the supervisor.
    process.send(self, StartStored)
    State(shared:, registries:, running: dict.new(), started: Ok([]))
    |> actor.initialised
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.named(name)
  |> actor.start
}

/// Whether the registry under `name` is up right now.
fn up(running: Running) -> Bool {
  result.is_ok(process.named(running.name))
}

fn instances(state: State) -> List(Instance) {
  dict.values(state.running)
  |> list.filter(up)
  |> list.map(fn(running) { running.instance })
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Find(team, reply) -> {
      process.send(
        reply,
        dict.get(state.running, team)
          |> result.try(fn(running) {
            case up(running) {
              True -> Ok(running.instance)
              // Being started again; sending now would fail.
              False -> Error(Nil)
            }
          })
          |> option.from_result,
      )
      actor.continue(state)
    }
    All(reply) -> {
      process.send(reply, instances(state))
      actor.continue(state)
    }
    Drain(reply) -> {
      process.send(
        reply,
        dict.to_list(state.running)
          |> list.map(fn(pair) { #(pair.0, { pair.1 }.instance) }),
      )
      actor.continue(state)
    }
    Started(reply) -> {
      process.send(reply, state.started)
      actor.continue(state)
    }
    Start(team, reply) -> {
      let #(state, started) = start_one(state, team)
      process.send(reply, started)
      actor.continue(state)
    }
    StartStored ->
      case teams.active_teams(state.shared.store) {
        Error(reason) -> {
          sys.warn("crushling: listing workspaces: " <> reason)
          actor.continue(State(..state, started: Error(reason)))
        }
        Ok(teams) -> {
          let own = case state.shared.env_team {
            Some(env) -> env.id
            None -> ""
          }
          let #(own, others) =
            list.partition(teams, fn(team) { team.id == own })
          let #(state, failed) =
            list.fold(list.append(own, others), #(state, []), fn(acc, team) {
              let #(state, failed) = acc
              let #(state, started) = start_one(state, team)
              case started {
                Ok(_) -> #(state, failed)
                Error(reason) -> {
                  sys.warn(
                    "crushling: couldn't start workspace "
                    <> team.id
                    <> ": "
                    <> reason,
                  )
                  #(state, [#(team.id, reason), ..failed])
                }
              }
            })
          actor.continue(State(..state, started: Ok(list.reverse(failed))))
        }
      }
  }
}

fn start_one(
  state: State,
  team: teams.Team,
) -> #(State, Result(Instance, String)) {
  case dict.get(state.running, team.id) {
    // A reinstall keeps the running instance; its new token is in the
    // store for the next start.
    Ok(running) -> #(state, Ok(running.instance))
    Error(Nil) -> {
      let name = process.new_name("crushling_registry")
      // One outbox per workspace, kept across restarts of its registry.
      let outbox = workspace.start_outbox()
      let started =
        factory.start_child(state.registries, Spawn(team.id, name, outbox))
        |> result.map_error(fn(error) {
          "registry for " <> team.id <> ": " <> string.inspect(error)
        })
        |> result.map(fn(_) {
          Instance(
            workspace: workspace_of(state.shared, team, outbox),
            registry: process.named_subject(name),
          )
        })
      case started {
        Ok(instance) -> #(
          State(
            ..state,
            running: dict.insert(
              state.running,
              team.id,
              Running(instance:, name:),
            ),
          ),
          started,
        )
        Error(_) -> #(state, started)
      }
    }
  }
}

/// The Slack handle for `team`, as the store has it now, sending through
/// its workspace's `outbox`.
fn workspace_of(shared: Shared, team: teams.Team, outbox: Outbox) -> Workspace {
  workspace.using(
    outbox,
    team: team.id,
    bot_user: team.bot_user,
    client: shared.client(team.bot_token),
    token: team.bot_token,
  )
}

/// A workspace's allowlist and admins: its settings in the store, else the
/// environment's for the environment's own workspace, else nobody.
pub fn people(
  shared: Shared,
  team: String,
) -> Result(#(People, Set(String)), String) {
  use settings <- result.map(teams.settings(shared.store, team))
  let env = case shared.env_team {
    Some(env) if env.id == team -> Some(#(env.allowed, env.admins))
    _ -> None
  }
  people.settled(
    dict.get(settings, teams.allowed_users),
    dict.get(settings, teams.admins),
    env,
    fn() {
      sys.warn(
        "crushling: ignoring `*` in the admins setting of "
        <> team
        <> "; admins must be listed by id",
      )
    },
  )
}

/// Start, or start again, a workspace's registry, from its row in the store.
fn start_registry(
  shared: Shared,
  stranded: Set(String),
  spawn: Spawn,
) -> actor.StartResult(Subject(registry.Message)) {
  let failed = fn(reason) {
    sys.warn("crushling: starting workspace " <> spawn.team <> ": " <> reason)
    Error(actor.InitFailed(reason))
  }
  case teams.team(shared.store, spawn.team) {
    Ok(Some(team)) ->
      case people(shared, team.id) {
        Ok(#(allowed, admins)) ->
          start_instance(shared, stranded, team, allowed, admins, spawn)
        Error(reason) -> failed(reason)
      }
    Ok(None) -> failed("not in the store")
    Error(reason) -> failed(reason)
  }
}

fn start_instance(
  shared: Shared,
  stranded: Set(String),
  team: teams.Team,
  allowed: People,
  admins: Set(String),
  spawn: Spawn,
) -> actor.StartResult(Subject(registry.Message)) {
  let is_env = case shared.env_team {
    Some(env) -> env.id == team.id
    None -> False
  }
  use started <- result.map(registry.start_with(
    registry_config.Config(
      launcher: agents.launcher(shared.agents),
      workspace: workspace_of(shared, team, spawn.outbox),
      allowed:,
      admins:,
      store: shared.store,
      stranded: case is_env {
        True -> stranded
        False -> set.new()
      },
      idle_ms: shared.idle_ms,
      flush_ms: shared.flush_ms,
      mode: shared.mode,
      tailnet: case is_env {
        True -> shared.tailnet
        False -> None
      },
      stop_backoff_ms: registry.default_stop_backoff_ms,
      root: shared.root,
      github: shared.github,
      default_model: shared.default_model,
    ),
    Some(shared.agents),
    Some(spawn.name),
  ))
  sys.info(
    "crushling: serving workspace "
    <> team.id
    <> " as "
    <> team.bot_user
    <> " with "
    <> people.describe(allowed),
  )
  case
    is_env && option.is_some(shared.tailnet),
    allowed.everyone,
    set.is_empty(admins)
  {
    True, True, True ->
      sys.warn(
        "crushling: everyone in "
        <> team.id
        <> " may use crushling and it has no admins, so nobody can approve tailnet access; list approvers in CRUSHLING_ADMINS",
      )
    _, _, _ -> Nil
  }
  started
}

/// Self-host: put the workspace of the bot token in the store, as auth.test
/// names it through `client`, which carries that token. A team already
/// there keeps who installed it and when.
pub fn seed(
  store: Store,
  client: slackline.Client,
  bot_token: String,
) -> Result(#(teams.Team, auth.TestResponse), String) {
  use me <- result.try(
    auth.test_()
    |> httpc.send(client)
    |> result.map_error(fn(error) {
      "auth.test: " <> slackline.describe_error(error)
    }),
  )
  use _ <- result.try(teams.put_team(
    store,
    teams.Team(
      id: me.team_id,
      bot_token:,
      bot_user: me.user_id,
      enterprise_id: me.enterprise_id,
      installed_by: "",
      installed_at: sys.system_ms() / 1000,
      active: True,
    ),
  ))
  use stored <- result.try(teams.team(store, me.team_id))
  use team <- result.map(option.to_result(
    stored,
    "the store lost workspace " <> me.team_id,
  ))
  #(team, me)
}

/// Wait up to `timeout_ms` for the stored workspaces to have started, as
/// the teams actor does on its own when it starts: the ones that failed,
/// with why, or why they couldn't be listed.
pub fn started(
  teams: Teams,
  timeout_ms: Int,
) -> Result(List(#(String, String)), String) {
  guarded(timeout_ms, fn() { process.call(teams.subject, timeout_ms, Started) })
  |> result.flatten
}

/// Run `work` on a process of its own, so a call to something that is
/// down or restarting is an error here rather than a crash.
fn guarded(timeout_ms: Int, work: fn() -> a) -> Result(a, String) {
  let reply = process.new_subject()
  let pid = process.spawn_unlinked(fn() { process.send(reply, work()) })
  let monitor = process.monitor(pid)
  let answer =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(monitor, fn(down) {
      Error(string.inspect(down.reason))
    })
    |> process.selector_receive(timeout_ms + 1000)
  process.demonitor_process(monitor)
  case answer {
    Ok(answer) -> answer
    Error(Nil) -> {
      process.kill(pid)
      Error("no answer in time")
    }
  }
}

/// Start `team`'s instance, or return the one already running.
pub fn start_team(teams: Teams, team: teams.Team) -> Result(Instance, String) {
  process.call(teams.subject, timeout_ms, Start(team, _))
}

/// Start every active team in the store that isn't running yet. Returns
/// the ones that failed, with why.
pub fn start_stored(
  teams: Teams,
  store: Store,
) -> Result(List(#(String, String)), String) {
  use active <- result.map(teams.active_teams(store))
  list.filter_map(active, fn(team) {
    case start_team(teams, team) {
      Ok(_) -> Error(Nil)
      Error(reason) -> Ok(#(team.id, reason))
    }
  })
}

pub fn find(teams: Teams, team: String) -> Option(Instance) {
  process.call(teams.subject, timeout_ms, Find(team, _))
}

pub fn all(teams: Teams) -> List(Instance) {
  process.call(teams.subject, timeout_ms, All)
}

/// How the event router finds a workspace: by `team_id`, else (for an
/// org-wide install) by `enterprise_id`.
pub fn finder(
  teams: Teams,
) -> fn(Option(String), Option(String)) -> Result(Instance, Nil) {
  fn(team, enterprise) {
    case team, enterprise {
      Some(team), _ -> find(teams, team)
      None, Some(enterprise) -> find(teams, enterprise)
      None, None -> None
    }
    |> option.to_result(Nil)
  }
}

/// Shut every instance down with `grace_ms` for running turns, all at
/// once, and wait for all of them: Clean only if every one was.
///
/// Nothing here may crash the caller, which still has to save spend and
/// exit: a workspace that can't be reached is Incomplete with its team.
pub fn shutdown(teams: Teams, grace_ms: Int) -> shutdown.ShutdownOutcome {
  case
    guarded(timeout_ms, fn() { process.call(teams.subject, timeout_ms, Drain) })
  {
    Error(reason) -> {
      sys.warn("crushling: shutting down the workspaces: " <> reason)
      shutdown.Incomplete(["workspaces: " <> reason])
    }
    Ok(instances) -> shutdown_all(instances, grace_ms)
  }
}

fn shutdown_all(
  instances: List(#(String, Instance)),
  grace_ms: Int,
) -> shutdown.ShutdownOutcome {
  let budget = shutdown.budget_ms(grace_ms)
  let deadline = sys.monotonic_ms() + budget
  let replies =
    list.map(instances, fn(pair) {
      let #(team, instance) = pair
      let done = process.new_subject()
      #(
        team,
        send_shutdown(instance.registry, registry.Shutdown(grace_ms, done), 20),
        done,
      )
    })
  list.fold(replies, shutdown.Clean, fn(outcome, sent) {
    let left = int_max(deadline - sys.monotonic_ms(), 0)
    let this = case sent {
      #(team, Error(reason), _) -> {
        sys.warn(
          "crushling: shutting down workspace " <> team <> ": " <> reason,
        )
        shutdown.Incomplete([team])
      }
      #(_, Ok(Nil), done) ->
        case process.receive(done, left) {
          Ok(this) -> this
          Error(Nil) -> shutdown.TimedOut
        }
    }
    case outcome, this {
      shutdown.TimedOut, _ | _, shutdown.TimedOut -> shutdown.TimedOut
      shutdown.Incomplete(a), shutdown.Incomplete(b) ->
        shutdown.Incomplete(list.append(a, b))
      shutdown.Incomplete(a), shutdown.Clean
      | shutdown.Clean, shutdown.Incomplete(a)
      -> shutdown.Incomplete(a)
      shutdown.Clean, shutdown.Clean -> shutdown.Clean
    }
  })
}

/// Send to a registry that may be mid-restart, waiting up to `tries` tenths
/// of a second for it to come back under its name.
fn send_shutdown(
  registry: Subject(registry.Message),
  message: registry.Message,
  tries: Int,
) -> Result(Nil, String) {
  // Sending to a name nobody holds raises, so it is tried off this process.
  case guarded(1000, fn() { process.send(registry, message) }) {
    Ok(Nil) -> Ok(Nil)
    Error(_) if tries > 0 -> {
      process.sleep(100)
      send_shutdown(registry, message, tries - 1)
    }
    Error(_) -> Error("it is down")
  }
}

fn int_max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}

/// What thread `key` can get from its workspace's GitHub broker.
pub fn github_access(
  teams: Teams,
  store: Store,
) -> fn(String) -> Result(broker.Access, String) {
  fn(key) {
    use found <- result.try(instance_of(teams, store, key))
    let reply = process.new_subject()
    process.send(found.registry, registry.GitHubBroker(reply))
    process.receive(reply, timeout_ms)
    |> result.replace_error("the workspace didn't answer in time")
    |> result.try(broker.thread(_, key))
  }
}

/// The instance serving thread `key`: its team is in its key, else in its
/// row in the store.
fn instance_of(
  teams: Teams,
  store: Store,
  key: String,
) -> Result(Instance, String) {
  let team = case thread_key.parse(key) {
    Ok(parsed) -> Ok(thread_key.team(parsed))
    Error(Nil) ->
      case threads.thread(store, key) {
        Ok(Some(thread)) -> Ok(thread.team)
        _ -> Error(Nil)
      }
  }
  team
  |> result.try(fn(team) { find(teams, team) |> option.to_result(Nil) })
  |> result.replace_error("this thread's workspace isn't served here")
}

/// The Slack tools reach each thread's own workspace: its team is in its
/// key, else in its row in the store.
pub fn tools_context(
  teams: Teams,
  store: Store,
  features: tools.Features,
) -> tools.Context {
  let instance_of = instance_of(teams, store, _)
  tools.Context(
    features:,
    workspace: fn(key) {
      use found <- result.map(instance_of(key))
      found.workspace
    },
    lookup: fn(key) {
      case instance_of(key) {
        Ok(found) ->
          process.call(found.registry, timeout_ms, registry.Lookup(key, _))
        Error(_) -> None
      }
    },
    ask_tailnet: fn(key, reason) {
      use found <- result.try(instance_of(key))
      process.call(found.registry, timeout_ms, fn(reply) {
        registry.Tailnet(key, tailnet.Asked(reason, reply))
      })
    },
  )
}
