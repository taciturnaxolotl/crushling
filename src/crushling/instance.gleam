//// One instance per Slack workspace the bridge serves, and the actor that
//// keeps them: `team_id -> Instance`.
////
//// An instance is the workspace's registry and its Slack client (with that
//// workspace's bot token). Everything else is shared by every instance, one
//// each per bridge: the launcher, the tunnels and the proxy behind it (thread
//// keys carry the team, so they never collide), the sandbox server, the
//// store and the instance secret.
////
//// Each workspace's allowlist and admins come from its `team_settings`; the
//// workspace seeded from the environment (self-host) falls back to
//// `CRUSHLING_ALLOWED_USERS` and `CRUSHLING_ADMINS`.

import crushling/crush/client
import crushling/github
import crushling/launcher.{type Launcher}
import crushling/people.{type People}
import crushling/registry
import crushling/registry/tailnet
import crushling/sandbox
import crushling/slack_tools
import crushling/socket
import crushling/store.{type Store}
import crushling/sys
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import gleam/string
import slackline
import slackline/api/auth
import slackline/httpc

/// What every instance shares, and how to make each one's parts.
pub type Shared {
  Shared(
    launcher: Launcher,
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
    github: Option(github.Config),
    default_model: String,
  )
}

pub type EnvTeam {
  EnvTeam(id: String, allowed: People, admins: Set(String))
}

/// A running workspace.
pub type Instance {
  Instance(
    team: String,
    bot_user: String,
    client: slackline.Client,
    registry: Subject(registry.Message),
  )
}

pub opaque type Teams {
  Teams(subject: Subject(Message))
}

type Message {
  Start(team: store.Team, reply: Subject(Result(Instance, String)))
  Find(team: String, reply: Subject(Option(Instance)))
  All(reply: Subject(List(Instance)))
  /// Shutdown is under way: stop restarting registries, and reply with
  /// every instance.
  Drain(reply: Subject(List(Instance)))
  /// A registry stopped.
  RegistryDown(process.Down)
  /// Start a team's registry again after it crashed.
  Restart(team: String)
}

type Running {
  Running(instance: Instance, monitor: process.Monitor)
}

type State {
  State(
    shared: Shared,
    self: Subject(Message),
    running: Dict(String, Running),
    draining: Bool,
  )
}

const timeout_ms = 10_000

/// How long after a crash a team's registry is started again.
const restart_ms = 1000

/// Each team's registry is started by this actor but not linked to it, and
/// monitored instead: one team's crash leaves the others, and this actor,
/// alone, and the crashed registry is started again.
pub fn start(shared: Shared) -> Result(Teams, String) {
  actor.new_with_initialiser(timeout_ms, fn(self) {
    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select_monitors(RegistryDown)
    State(shared:, self:, running: dict.new(), draining: False)
    |> actor.initialised
    |> actor.selecting(selector)
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { Teams(started.data) })
  |> result.map_error(fn(error) { "teams: " <> string.inspect(error) })
}

fn instances(state: State) -> List(Instance) {
  dict.values(state.running) |> list.map(fn(running) { running.instance })
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Find(team, reply) -> {
      process.send(
        reply,
        dict.get(state.running, team)
          |> option.from_result
          |> option.map(fn(running) { running.instance }),
      )
      actor.continue(state)
    }
    All(reply) -> {
      process.send(reply, instances(state))
      actor.continue(state)
    }
    Drain(reply) -> {
      process.send(reply, instances(state))
      actor.continue(State(..state, draining: True))
    }
    Start(team, reply) ->
      case dict.get(state.running, team.id) {
        // A reinstall keeps the running instance; its new token is in the
        // store for the next start.
        Ok(running) -> {
          process.send(reply, Ok(running.instance))
          actor.continue(state)
        }
        Error(Nil) -> {
          let #(state, started) = launch(state, team)
          process.send(reply, started)
          actor.continue(state)
        }
      }
    RegistryDown(process.ProcessDown(monitor:, reason:, ..)) -> {
      let gone =
        dict.filter(state.running, fn(_, running) { running.monitor == monitor })
        |> dict.keys
      let state = State(..state, running: dict.drop(state.running, gone))
      case reason, state.draining {
        // Stopped at shutdown.
        process.Normal, _ | _, True -> Nil
        _, False ->
          list.each(gone, fn(team) {
            sys.warn(
              "crushling: the registry for workspace "
              <> team
              <> " crashed ("
              <> string.inspect(reason)
              <> "); starting it again",
            )
            process.send_after(state.self, restart_ms, Restart(team))
            Nil
          })
      }
      actor.continue(state)
    }
    RegistryDown(_) -> actor.continue(state)
    Restart(team) ->
      case state.draining, dict.has_key(state.running, team) {
        False, False ->
          // From the store, so it starts with the team's latest token.
          case store.team(state.shared.store, team) {
            Ok(Some(found)) if found.active -> {
              let #(state, started) = launch(state, found)
              case started {
                Ok(_) -> Nil
                Error(reason) ->
                  sys.warn(
                    "crushling: restarting workspace "
                    <> team
                    <> " failed: "
                    <> reason,
                  )
              }
              actor.continue(state)
            }
            _ -> actor.continue(state)
          }
        _, _ -> actor.continue(state)
      }
  }
}

fn launch(
  state: State,
  team: store.Team,
) -> #(State, Result(Instance, String)) {
  case start_instance(state.shared, team) {
    Error(reason) -> #(state, Error(reason))
    Ok(instance) -> {
      let assert Ok(pid) = process.subject_owner(instance.registry)
      // actor.start linked it to this actor.
      process.unlink(pid)
      let monitor = process.monitor(pid)
      #(
        State(
          ..state,
          running: dict.insert(
            state.running,
            team.id,
            Running(instance:, monitor:),
          ),
        ),
        Ok(instance),
      )
    }
  }
}

/// The self-host workspace's allowlist and admins, from the values of
/// `CRUSHLING_ALLOWED_USERS` and `CRUSHLING_ADMINS`. The allowlist must not
/// be empty; `*` in it means every member of the workspace. Admins approve
/// tailnet access, so they must be listed by id.
pub fn env_people(
  allowed: String,
  admins: String,
) -> Result(#(People, Set(String)), String) {
  let allowed = people.parse(allowed)
  let admins = people.parse(admins)
  case people.is_empty(allowed), admins.everyone {
    // An agent in sysadmin mode that anyone can drive is not a default
    // worth having: everyone has to be asked for.
    True, _ ->
      Error(
        "CRUSHLING_ALLOWED_USERS is empty; list the Slack user ids, or `*` for everyone in the workspace",
      )
    _, True ->
      Error(
        "CRUSHLING_ADMINS can't be `*`; admins approve tailnet access, so list their Slack user ids",
      )
    False, False -> Ok(#(allowed, admins.ids))
  }
}

/// A workspace's allowlist and admins: its settings in the store, else the
/// environment's for the environment's own workspace, else nobody. Admins
/// are only ever listed ids: a `*` among them is dropped, with a warning.
pub fn people(
  shared: Shared,
  team: String,
) -> Result(#(People, Set(String)), String) {
  use settings <- result.map(store.settings(shared.store, team))
  let env = case shared.env_team {
    Some(env) if env.id == team -> Some(env)
    _ -> None
  }
  let allowed = case dict.get(settings, store.allowed_users), env {
    Ok(value), _ -> people.parse(value)
    Error(Nil), Some(env) -> env.allowed
    Error(Nil), None -> people.nobody()
  }
  let admins = case dict.get(settings, store.admins), env {
    Ok(value), _ -> {
      let admins = people.parse(value)
      case admins.everyone {
        True ->
          sys.warn(
            "crushling: ignoring `*` in the admins setting of "
            <> team
            <> "; admins must be listed by id",
          )
        False -> Nil
      }
      admins.ids
    }
    Error(Nil), Some(env) -> env.admins
    Error(Nil), None -> set.new()
  }
  #(allowed, admins)
}

fn start_instance(
  shared: Shared,
  team: store.Team,
) -> Result(Instance, String) {
  use #(allowed, admins) <- result.try(people(shared, team.id))
  let client = shared.client(team.bot_token)
  let is_env = case shared.env_team {
    Some(env) -> env.id == team.id
    None -> False
  }
  use registry <- result.map(
    registry.start(registry.Config(
      launcher: shared.launcher,
      client:,
      token: team.bot_token,
      bot_user: team.bot_user,
      team: team.id,
      allowed:,
      admins:,
      store: shared.store,
      migrate_legacy: is_env,
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
    ))
    |> result.map_error(fn(error) {
      "registry for " <> team.id <> ": " <> string.inspect(error)
    }),
  )
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
  Instance(team: team.id, bot_user: team.bot_user, client:, registry:)
}

/// Self-host: put the workspace of the bot token in the store, as auth.test
/// names it through `client`, which carries that token. A team already
/// there keeps who installed it and when.
pub fn seed(
  store: Store,
  client: slackline.Client,
  bot_token: String,
) -> Result(#(store.Team, auth.TestResponse), String) {
  use me <- result.try(
    auth.test_()
    |> httpc.send(client)
    |> result.map_error(fn(error) {
      "auth.test: " <> slackline.describe_error(error)
    }),
  )
  use _ <- result.try(store.put_team(
    store,
    store.Team(
      id: me.team_id,
      bot_token:,
      bot_user: me.user_id,
      enterprise_id: me.enterprise_id,
      installed_by: "",
      installed_at: sys.system_ms() / 1000,
      active: True,
    ),
  ))
  use stored <- result.try(store.team(store, me.team_id))
  use team <- result.map(option.to_result(
    stored,
    "the store lost workspace " <> me.team_id,
  ))
  #(team, me)
}

/// Start `team`'s instance, or return the one already running.
pub fn start_team(teams: Teams, team: store.Team) -> Result(Instance, String) {
  process.call(teams.subject, timeout_ms, Start(team, _))
}

/// Start every active team in the store that isn't running yet. Returns
/// the ones that failed, with why.
pub fn start_stored(
  teams: Teams,
  store: Store,
) -> Result(List(#(String, String)), String) {
  use active <- result.map(store.active_teams(store))
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
pub fn finder(teams: Teams) -> socket.Find {
  fn(team, enterprise) {
    let found = case team, enterprise {
      Some(team), _ -> find(teams, team)
      None, Some(enterprise) -> find(teams, enterprise)
      None, None -> None
    }
    case found {
      Some(instance) ->
        Ok(socket.Target(
          team: instance.team,
          bot_user: instance.bot_user,
          registry: instance.registry,
        ))
      None -> Error(Nil)
    }
  }
}

/// Shut every instance down with `grace_ms` for running turns, all at
/// once, and wait for all of them: Clean only if every one was.
pub fn shutdown(teams: Teams, grace_ms: Int) -> registry.ShutdownOutcome {
  let instances = process.call(teams.subject, timeout_ms, Drain)
  let replies =
    list.map(instances, fn(instance) {
      let done = process.new_subject()
      process.send(instance.registry, registry.Shutdown(grace_ms, done))
      done
    })
  let budget = registry.shutdown_budget_ms(grace_ms)
  let deadline = sys.monotonic_ms() + budget
  list.fold(replies, registry.Clean, fn(outcome, done) {
    let left = int_max(deadline - sys.monotonic_ms(), 0)
    let this = case process.receive(done, left) {
      Ok(this) -> this
      Error(Nil) -> registry.TimedOut
    }
    case outcome, this {
      registry.TimedOut, _ | _, registry.TimedOut -> registry.TimedOut
      registry.Incomplete(a), registry.Incomplete(b) ->
        registry.Incomplete(list.append(a, b))
      registry.Incomplete(a), registry.Clean
      | registry.Clean, registry.Incomplete(a)
      -> registry.Incomplete(a)
      registry.Clean, registry.Clean -> registry.Clean
    }
  })
}

fn int_max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}

/// The Slack tools reach each thread's own workspace: its team is in its
/// key, else in its row in the store.
pub fn tools_context(teams: Teams, store: Store) -> slack_tools.Context {
  let instance_of = fn(key) {
    let team = case sandbox.team_of(key) {
      Ok(team) -> Ok(team)
      Error(Nil) ->
        case store.thread(store, key) {
          Ok(Some(thread)) -> Ok(thread.team)
          _ -> Error(Nil)
        }
    }
    team
    |> result.try(fn(team) { find(teams, team) |> option.to_result(Nil) })
    |> result.replace_error("this thread's workspace isn't served here")
  }
  slack_tools.Context(
    workspace: fn(key) {
      use found <- result.map(instance_of(key))
      slack_tools.Workspace(client: found.client, bot_user: found.bot_user)
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
