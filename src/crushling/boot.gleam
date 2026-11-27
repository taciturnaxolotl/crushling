//// Start the bridge from a `config.Config`: every service, spawn and side
//// effect (the `id -u` lookups included) happens here, none while parsing.

import crushling/agent/backend
import crushling/agent/spec
import crushling/agents
import crushling/config.{type Config}
import crushling/events
import crushling/files/route as files_route
import crushling/github
import crushling/github/app as github_app
import crushling/github/broker
import crushling/github/http as github_http
import crushling/github/route as github_route
import crushling/install
import crushling/instance
import crushling/launcher
import crushling/mcp
import crushling/proxy
import crushling/proxy/meter
import crushling/registry/shutdown
import crushling/registry/tailnet
import crushling/sandbox
import crushling/sandbox_http
import crushling/slack/router
import crushling/slack/socket_mode
import crushling/store
import crushling/store/legacy_import
import crushling/store/schema
import crushling/store/teams
import crushling/store/usage
import crushling/sys
import crushling/tailscale
import crushling/tools
import crushling/tunnel
import crushling/usage as usage_cap
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import slackline
import slackline/app

@external(erlang, "crushling_ffi", "exec")
fn exec(
  program: String,
  args: List(String),
  timeout_ms: Int,
) -> Result(#(Int, String), String)

@external(erlang, "crushling_signal", "install")
fn install_sigterm(subject: process.Subject(Nil)) -> Result(Nil, String)

/// Run the bridge until SIGTERM, then shut down; the exit code says
/// whether every agent stopped in time.
///
/// The store and the GitHub App's keeper are linked to this process, so if
/// either dies the bridge exits. Everything after them runs under one
/// supervisor, rest-for-one, in order: the proxy's meter, the tunnels, the
/// lifecycle owner, the workspaces and the sandbox server. Each is reached
/// by name, so a restart is invisible to its users, and a restart of one
/// restarts everything after it: a new lifecycle owner stops the sandboxes
/// it doesn't know, and new registries start from nothing running.
///
/// Slack events are only taken once the stored workspaces have started, so
/// none arrives for a workspace that isn't there yet; the self-host one
/// failing to start fails the boot.
pub fn run(config: Config) -> Result(Int, String) {
  let root = config.root
  use secret <- result.try(mcp_secret(root))
  use store <- result.try(open_store(config.store_key, root))
  let local = case config.sandbox {
    config.Local(..) -> True
    config.Docker(..) -> False
  }
  use github <- result.try(start_github(config.github))
  // Sandboxes reach GitHub through the bridge; a local agent uses the
  // host's own git and gh.
  let github_reads = github != option.None && !local
  let bridge_url = config.bridge.url
  // Self-host: the workspace of SLACK_BOT_TOKEN, seeded into the store.
  use env_team <- result.try(seed_env_team(config.slack.env_team, store, root))
  let own_team = case env_team {
    option.Some(seeded) -> seeded.team.id
    option.None -> ""
  }

  let proxy_config = proxy_config(config.proxy, secret, store)
  log_caps(config.proxy)
  use proxy <- result.try(
    proxy.new(proxy_config)
    |> result.map_error(fn(reason) {
      "the proxy upstream (CRUSHLING_PROXY_UPSTREAM or HYPER_URL) " <> reason
    }),
  )
  let tunnel_config =
    tunnel.Config(..tunnel.config(secret, root), on_event: log_tunnel_event)
  use _ <- result.try(tunnel.check_root(root))
  let tunnels_name = process.new_name("crushling_tunnels")
  let tunnels = tunnel.named(tunnel_config, tunnels_name)
  let settings =
    spec.Settings(
      bridge_url:,
      secret:,
      github: github_reads,
      models: config.models,
      env: [],
      own_team:,
      own_env: case config.sandbox {
        // The Honcho settings are the operator's own memory, so only the
        // self-host workspace's sandboxes get them.
        config.Docker(docker) -> docker.honcho
        // The local launcher passes no Honcho settings: only the docker
        // settings read them, and a local agent shares the operator's home.
        config.Local(..) -> []
      },
    )
  use backend <- result.try(backend(config, settings))
  let launcher =
    launcher.new(
      launcher.Wiring(
        tunnels:,
        proxy:,
        spec: settings,
        hello_timeout_ms: config.limits.hello_timeout_ms,
      ),
      backend,
    )
  let agents_name = process.new_name("crushling_agents")
  let owner = agents.named(launcher, agents_name)
  let tailnet = tailnet(config.tailnet, launcher)
  let teams_name = process.new_name("crushling_teams")
  let teams = instance.named(teams_name)
  let shared =
    instance.Shared(
      agents: owner,
      store:,
      root:,
      mode: config.mode,
      idle_ms: config.limits.idle_ms,
      flush_ms: 1000,
      env_team: option.map(env_team, fn(seeded) { seeded.env }),
      tailnet:,
      client: slackline.new,
      github:,
      default_model: config.models.large,
    )

  let context =
    instance.tools_context(
      teams,
      store,
      tools.Features(tailnet: tailnet != option.None),
    )
  // Every agent reaches the bridge here: its tunnel, its inference, its
  // Slack tools and its files.
  let config.Address(bind:, port:) = config.bridge.address
  let routes = [
    tunnel.route(tunnels),
    proxy.route(proxy),
    mcp.route_with(
      secret,
      tools.tools(context.features),
      fn(key, name, arguments) { tools.call(context, key, name, arguments) },
      case github_reads {
        True -> github_route.instructions
        False -> ""
      },
    ),
    files_route.route(secret, root, fn(key, name, contents, comment) {
      tools.share(context, key, name, contents, comment)
    }),
    ..case github_reads {
      True -> [
        github_route.route(github_route.Setup(
          secret:,
          access: instance.github_access(teams, store),
          web: github_route.github(),
          api: github_route.github_api(),
          bridge_url:,
          wait_ms: github_route.default_wait_ms,
          // Containers keep their env across wakes, so epochs wait for per-create tokens.
          epoch: fn(_) { option.None },
        )),
      ]
      False -> []
    }
  ]
  use _ <- result.try(
    supervisor.new(supervisor.RestForOne)
    |> supervisor.add(
      supervision.worker(fn() { proxy.start_meter(proxy_config) }),
    )
    |> supervisor.add(tunnel.supervised(tunnel_config, tunnels_name))
    |> supervisor.add(agents.supervised(launcher, backend.running, agents_name))
    // Its teams actor starts every active workspace in the store.
    |> supervisor.add(instance.supervised(shared, teams_name))
    |> supervisor.add(sandbox_http.supervised(bind, port, routes))
    |> supervisor.start
    |> result.map_error(fn(error) {
      "could not start the bridge (is "
      <> bind
      <> ":"
      <> int.to_string(port)
      <> " free?): "
      <> string.inspect(error)
    }),
  )
  io.println(
    "crushling: sandbox server at "
    <> bind
    <> ":"
    <> int.to_string(port)
    <> ", reached by agents at "
    <> bridge_url,
  )
  use _ <- result.try(workspaces_started(teams, own_team))

  let find = instance.finder(teams)
  let install =
    option.map(config.slack.install, fn(settings: config.Install) {
      install.Config(
        client_id: settings.client_id,
        client_secret: settings.client_secret,
        public_url: settings.public_url,
        secret:,
        store:,
        slack: slackline.anonymous(),
        on_installed: fn(team) {
          instance.start_team(teams, team) |> result.replace(Nil)
        },
        env_team: option.map(env_team, fn(seeded) { seeded.team.id }),
      )
    })
  // Slack sends each event one way, so taking both while the app moves
  // from Socket Mode to HTTP loses nothing, and the registry drops repeats.
  // The install is served on the same server.
  use _ <- result.try(case config.slack.signing_secret, install {
    option.None, option.None -> Ok(Nil)
    signing_secret, install -> {
      let config.Address(bind:, port:) = config.slack.events
      let router =
        option.map(signing_secret, fn(signing_secret) {
          router.router(app.new(signing_secret), find)
        })
      use _ <- result.map(events.start(bind, port, router, install))
      case router {
        option.Some(_) ->
          io.println(
            "crushling: taking events at "
            <> bind
            <> ":"
            <> int.to_string(port)
            <> "/slack/events",
          )
        option.None -> Nil
      }
      case install {
        option.Some(config) ->
          io.println(
            "crushling: installs start at "
            <> config.public_url
            <> "/slack/install",
          )
        option.None -> Nil
      }
    }
  })
  let socket =
    option.map(config.slack.socket_mode, fn(app_token) {
      let router = router.router(app.unverified(), find)
      io.println("crushling: taking events over Socket Mode")
      process.spawn_unlinked(fn() { socket_mode.run(app_token, router) })
    })

  let terminate = process.new_subject()
  use _ <- result.try(install_sigterm(terminate))
  let _ = process.receive_forever(terminate)

  // Take no new work, give running turns their grace period, then stop
  // every agent before exiting.
  io.println("crushling: shutting down")
  // Over HTTP the registries ignore new messages once they are draining.
  option.map(socket, process.kill)
  // One deadline for all of it, from the registries' own timers.
  let outcome = instance.shutdown(teams, config.limits.shutdown_grace_ms)
  // Turns that finished during the grace period spent too.
  case proxy.flush(proxy) {
    Ok(Nil) -> Nil
    Error(reason) -> sys.warn("crushling: saving spend failed: " <> reason)
  }
  case outcome {
    shutdown.Clean -> {
      io.println("crushling: stopped")
      Ok(0)
    }
    shutdown.TimedOut -> {
      io.println_error("crushling: shutdown timed out")
      Ok(1)
    }
    outcome -> {
      io.println_error(
        "crushling: shutdown incomplete: " <> string.inspect(outcome),
      )
      Ok(1)
    }
  }
}

/// Wait for the teams actor to start every stored workspace. The self-host
/// one must be up; others that failed were logged and can be installed
/// again.
fn workspaces_started(
  teams: instance.Teams,
  own_team: String,
) -> Result(Nil, String) {
  use failed <- result.try(
    instance.started(teams, workspaces_timeout_ms)
    |> result.map_error(fn(reason) { "starting workspaces: " <> reason }),
  )
  case own_team, list.key_find(failed, own_team) {
    "", _ -> Ok(Nil)
    _, Ok(reason) -> Error("starting workspace " <> own_team <> ": " <> reason)
    _, Error(Nil) ->
      case instance.find(teams, own_team) {
        option.Some(_) -> Ok(Nil)
        option.None ->
          Error("workspace " <> own_team <> " didn't start with the bridge")
      }
  }
}

const workspaces_timeout_ms = 300_000

/// Say once what the spend caps count, since that changed with the store.
fn log_caps(settings: config.Proxy) -> Nil {
  case settings.thread_cap == usage_cap.unlimited {
    True -> Nil
    False ->
      io.println(
        "crushling: the thread cap counts all a thread has spent, across restarts",
      )
  }
  case settings.instance_cap == usage_cap.unlimited {
    True -> Nil
    False ->
      io.println(
        "crushling: CRUSHLING_PROXY_INSTANCE_CAP_* caps each workspace on its own, over its last 30 days",
      )
  }
}

/// The store, with its key from `CRUSHLING_STORE_KEY` or `<root>/store-key`.
fn open_store(
  key: option.Option(String),
  root: String,
) -> Result(store.Store, String) {
  use #(key, made) <- result.try(store.load_key(
    option.to_result(key, Nil),
    root,
  ))
  case made {
    True ->
      io.println(
        "crushling: made a store key at "
        <> root
        <> "/store-key; back it up, or set CRUSHLING_STORE_KEY, since stored bot tokens can't be read without it",
      )
    False -> Nil
  }
  schema.open(root <> "/crushling.db", key)
}

/// The workspace of `SLACK_BOT_TOKEN`, from auth.test.
type Seeded {
  Seeded(team: teams.Team, env: instance.EnvTeam)
}

/// Self-host: put the workspace of `SLACK_BOT_TOKEN` in the store, with
/// its settings from the environment, and import the files the bridge kept
/// before the store, once.
fn seed_env_team(
  env_team: option.Option(config.EnvTeam),
  store: store.Store,
  root: String,
) -> Result(option.Option(Seeded), String) {
  case env_team {
    option.None -> Ok(option.None)
    option.Some(config.EnvTeam(bot_token:, allowed:, admins:)) -> {
      case allowed.everyone {
        True ->
          io.println(
            "crushling: everyone in the workspace may use it (members only, no guests or other workspaces)",
          )
        False -> Nil
      }
      use #(team, me) <- result.try(instance.seed(
        store,
        slackline.new(bot_token),
        bot_token,
      ))
      io.println(
        "crushling: connected as "
        <> me.user
        <> " ("
        <> me.user_id
        <> ") in "
        <> me.team
        <> " ("
        <> me.team_id
        <> ")",
      )
      use imported <- result.map(legacy_import.import_files(
        store,
        root,
        me.team_id,
      ))
      case imported {
        legacy_import.AlreadyImported -> Nil
        legacy_import.Imported(threads:, links:, skipped:) -> {
          list.each(skipped, fn(skip) {
            io.println(
              "crushling: not importing "
              <> root
              <> "/"
              <> skip.0
              <> ": "
              <> skip.1,
            )
          })
          io.println(
            "crushling: imported "
            <> int.to_string(list.length(threads))
            <> " threads and "
            <> int.to_string(list.length(links))
            <> " code channel links into the store"
            <> case threads, links {
              [], [] -> ""
              _, _ ->
                " ("
                <> string.join(list.append(threads, links), ", ")
                <> "); their files are no longer read"
            },
          )
        }
      }
      option.Some(Seeded(
        team:,
        env: instance.EnvTeam(id: me.team_id, allowed:, admins:),
      ))
    }
  }
}

/// The GitHub App people connect their accounts through. With its private
/// key, the app's own token reads public repos nobody connected for, and
/// the bridge knows where the app is installed.
fn start_github(
  settings: option.Option(config.GitHub),
) -> Result(option.Option(broker.GitHub), String) {
  case settings {
    option.None -> Ok(option.None)
    option.Some(config.GitHub(client_id:, client_secret:, private_key:)) -> {
      let config =
        github.Config(client_id:, client_secret:, send: github_http.send)
      case private_key {
        option.None -> Ok(option.Some(broker.GitHub(config, option.None)))
        option.Some(key) -> {
          use app <- result.map(
            github_app.start(config, key)
            |> result.replace_error("couldn't start the GitHub App's keeper"),
          )
          log_github_installs(app)
          option.Some(broker.GitHub(config, option.Some(app)))
        }
      }
    }
  }
}

/// Say where the GitHub App is installed, or how to install it, once.
fn log_github_installs(app: github_app.App) -> Nil {
  process.spawn_unlinked(fn() {
    case github_app.accounts(app) {
      option.Some(github.Accounts(logins: [], install_url:)) ->
        io.println_error(
          "crushling: the GitHub App isn't installed anywhere, so connected people can read no private repos; install it at "
          <> install_url,
        )
      option.Some(github.Accounts(logins:, ..)) ->
        io.println(
          "crushling: the GitHub App is installed on "
          <> string.join(logins, ", "),
        )
      option.None ->
        io.println_error(
          "crushling: couldn't ask GitHub about the GitHub App; is CRUSHLING_GITHUB_PRIVATE_KEY the app's key?",
        )
    }
  })
  Nil
}

/// Whether a thread's crush is connected only matters to its launch, which
/// waits for it; the rest is for the log.
fn log_tunnel_event(event: tunnel.Event) -> Nil {
  case event {
    tunnel.Dialed(key) -> sys.info("crushling: " <> key <> " dialed in")
    tunnel.Undialed(key) -> sys.info("crushling: " <> key <> " hung up")
  }
}

/// The secret every thread's tool token is derived from, kept beside the
/// threads so tokens survive a restart.
fn mcp_secret(root: String) -> Result(String, String) {
  let path = root <> "/mcp-secret"
  case sys.read_file(path) {
    Ok(secret) if secret != "" -> Ok(string.trim(secret))
    _ -> {
      let secret = sys.uuid() <> sys.uuid()
      use _ <- result.try(sys.mkdir_p(root))
      use _ <- result.map(sys.write_private(path, secret))
      secret
    }
  }
}

/// Where agents run, from the settings.
fn backend(
  config: Config,
  settings: spec.Settings,
) -> Result(backend.Backend, String) {
  let root = config.root
  case config.sandbox {
    config.Local(crush:) -> {
      io.println(
        "crushling: local launcher, agents run unsandboxed with your access",
      )
      Ok(backend.local(root, crush))
    }
    config.Docker(docker) -> {
      use uid <- result.try(id("-u"))
      use gid <- result.try(id("-g"))
      let policy =
        sandbox.Policy(
          socket: docker_socket(),
          image: docker.image,
          runtime: docker.runtime,
          network: docker.network,
          cpus: docker.cpus,
          memory: docker.memory,
          pids: 1024,
          uid:,
          gid:,
          root:,
          crush: docker.crush,
          dns: docker.dns,
          spec: settings,
        )
      use _ <- result.try(
        sandbox.check(policy) |> result.map_error(sandbox.describe),
      )
      prune_images(policy)
      Ok(backend.docker(policy))
    }
  }
}

@external(erlang, "crushling_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

/// The Engine's socket: `DOCKER_HOST` when it names a unix socket, as the
/// docker CLI reads it, else the default.
fn docker_socket() -> String {
  case getenv("DOCKER_HOST") {
    Ok("unix://" <> path) -> path
    Ok("") | Error(Nil) -> sandbox.default_socket
    Ok(other) -> {
      sys.warn(
        "crushling: DOCKER_HOST is "
        <> other
        <> ", but only unix:// sockets are supported; using "
        <> sandbox.default_socket,
      )
      sandbox.default_socket
    }
  }
}

/// Every deploy restarts the bridge: a good time to drop sandbox images
/// nothing uses anymore.
fn prune_images(policy: sandbox.Policy) -> Nil {
  process.spawn_unlinked(fn() {
    case sandbox.prune_images(policy) {
      Ok([]) -> Nil
      Ok(removed) ->
        io.println(
          "crushling: removed unused sandbox images "
          <> string.join(removed, ", "),
        )
      Error(error) ->
        sys.warn("crushling: pruning sandbox images: " <> string.inspect(error))
    }
  })
  Nil
}

fn id(flag: String) -> Result(Int, String) {
  case exec("id", [flag], 5000) {
    Ok(#(0, output)) ->
      int.parse(string.trim(output))
      |> result.replace_error("unexpected output from id " <> flag)
    _ -> Error("could not run id " <> flag)
  }
}

/// Tailnet access, when a Tailscale credential is set and agents run in
/// sandboxes.
fn tailnet(
  settings: option.Option(config.Tailnet),
  launcher: launcher.Launcher,
) -> option.Option(tailnet.Setup) {
  case settings, launcher.run_in_sandbox {
    option.Some(config.Tailnet(credential:, tag:, tailnet:)), option.Some(run)
    ->
      option.Some(tailnet.Setup(
        api: tailscale.Config(credential:, tag:, tailnet:),
        run:,
      ))
    _, _ -> option.None
  }
}

/// The inference proxy's settings, with the org's key, its spend kept in
/// the store so caps survive a restart.
fn proxy_config(
  settings: config.Proxy,
  secret: String,
  store: store.Store,
) -> proxy.Config {
  proxy.Config(
    secret:,
    org_key: settings.org_key,
    upstream: settings.upstream,
    thread_cap: settings.thread_cap,
    // CRUSHLING_PROXY_INSTANCE_CAP_*, now held by each workspace.
    team_cap: settings.instance_cap,
    max_per_thread: proxy.default_max_per_thread,
    max_uploads: proxy.default_max_uploads,
    upload_timeout_ms: proxy.default_upload_timeout_ms,
    keeper: option.Some(meter.Keeper(
      thread_total: usage.thread_total(store, _, usage.Ever),
      team_total: usage.team_total(store, _, usage.Month),
      save: usage.record(store, _),
      every_ms: spend_flush_ms,
    )),
    name: option.Some(process.new_name("crushling_meter")),
  )
}

const spend_flush_ms = 10_000
