//// Start the bridge from a `config.Config`: every service, spawn and side
//// effect (the `id -u` lookups included) happens here, none while parsing.

import crushling/config.{type Config}
import crushling/events
import crushling/files
import crushling/github
import crushling/github/app as github_app
import crushling/github/route as github_route
import crushling/install
import crushling/instance
import crushling/launcher
import crushling/mcp
import crushling/provider
import crushling/proxy
import crushling/registry
import crushling/registry/tailnet
import crushling/sandbox
import crushling/sandbox_http
import crushling/slack_tools
import crushling/socket
import crushling/store
import crushling/store/usage
import crushling/sys
import crushling/tailscale
import crushling/tunnel
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option
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
pub fn run(config: Config) -> Result(Int, String) {
  let root = config.root
  use secret <- result.try(mcp_secret(root))
  use store <- result.try(open_store(config.store_key, root))
  use proxy <- result.try(start_proxy(config.proxy, secret))
  keep_spend(proxy, store)
  use tunnels <- result.try(tunnel.start(
    tunnel.Config(..tunnel.config(secret, root), on_event: log_tunnel_event),
  ))
  let local = case config.sandbox {
    config.Local(..) -> True
    config.Docker(..) -> False
  }
  use #(github, app) <- result.try(start_github(config.github))
  // Sandboxes reach GitHub through the bridge; a local agent uses the
  // host's own git and gh.
  let github_reads = github != option.None && !local
  let bridge_url = config.bridge.url
  let bridge =
    launcher.bridge(
      url: bridge_url,
      secret:,
      tunnels:,
      proxy:,
      github: github_reads,
      hello_timeout_ms: config.limits.hello_timeout_ms,
    )
  // Self-host: the workspace of SLACK_BOT_TOKEN, seeded into the store.
  use env_team <- result.try(seed_env_team(config.slack.env_team, store, root))
  let own_team = case env_team {
    option.Some(seeded) -> seeded.team.id
    option.None -> ""
  }
  use launcher <- result.try(start_launcher(config, bridge, own_team))
  let tailnet = tailnet(config.tailnet, launcher)

  use teams <- result.try(
    instance.start(instance.Shared(
      launcher:,
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
    )),
  )
  use _ <- result.try(case env_team {
    option.None -> Ok(Nil)
    option.Some(seeded) ->
      instance.start_team(teams, seeded.team) |> result.replace(Nil)
  })
  // Every other workspace that installed the app.
  use failed <- result.try(instance.start_stored(teams, store))
  list.each(failed, fn(failure) {
    io.println_error(
      "crushling: couldn't start workspace " <> failure.0 <> ": " <> failure.1,
    )
  })

  let context = instance.tools_context(teams, store)
  // Every agent reaches the bridge here: its tunnel, its inference, its
  // Slack tools and its files.
  let config.Address(bind:, port:) = config.bridge.address
  use _ <- result.try(
    sandbox_http.start(bind, port, [
      tunnel.route(tunnels),
      proxy.route(proxy),
      mcp.route_with(
        secret,
        slack_tools.tools(tailnet: tailnet != option.None),
        fn(key, name, arguments) {
          slack_tools.call(context, key, name, arguments)
        },
        case github_reads {
          True -> github_route.instructions
          False -> ""
        },
      ),
      files.route(secret, root, fn(key, name, contents, comment) {
        slack_tools.share(context, key, name, contents, comment)
      }),
      ..case github_reads {
        True -> [
          github_route.route(github_route.Setup(
            secret:,
            access: instance.github_access(teams, store),
            web: github_route.github(),
            api: github_route.github_api(),
            bridge_url:,
            app_token: fn(owner, repo) {
              option.then(app, github_app.token(_, owner, repo))
            },
            installed: fn(owner, repo) {
              option.then(app, github_app.installed(_, owner, repo))
            },
            ask: instance.github_ask(teams, store),
            wait_ms: github_route.default_wait_ms,
            poll_ms: github_route.default_poll_ms,
          )),
        ]
        False -> []
      }
    ]),
  )
  io.println(
    "crushling: sandbox server at "
    <> bind
    <> ":"
    <> int.to_string(port)
    <> ", reached by agents at "
    <> bridge_url,
  )

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
          socket.router(app.new(signing_secret), find)
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
      let router = socket.router(app.unverified(), find)
      io.println("crushling: taking events over Socket Mode")
      process.spawn_unlinked(fn() { socket.run(app_token, router) })
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
  save_spend(proxy, store)
  case outcome {
    registry.Clean -> {
      io.println("crushling: stopped")
      Ok(0)
    }
    registry.TimedOut -> {
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
  store.start(root <> "/crushling.db", key)
}

/// The workspace of `SLACK_BOT_TOKEN`, from auth.test.
type Seeded {
  Seeded(team: store.Team, env: instance.EnvTeam)
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
      use imported <- result.map(store.import_files(store, root, me.team_id))
      case imported {
        store.AlreadyImported -> Nil
        store.Imported(threads:, links:, skipped:) -> {
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

/// Every `spend_flush_ms`, move what the proxy counted into the store, so
/// spend outlives the bridge.
fn keep_spend(proxy: proxy.Proxy, store: store.Store) -> Nil {
  process.spawn_unlinked(fn() { flush_spend_forever(proxy, store) })
  Nil
}

const spend_flush_ms = 10_000

fn flush_spend_forever(proxy: proxy.Proxy, store: store.Store) -> Nil {
  process.sleep(spend_flush_ms)
  save_spend(proxy, store)
  flush_spend_forever(proxy, store)
}

fn save_spend(proxy: proxy.Proxy, store: store.Store) -> Nil {
  case proxy.drain(proxy) {
    [] -> Nil
    spent ->
      case usage.record(store, spent) {
        Ok(Nil) -> Nil
        Error(reason) ->
          sys.warn("crushling: saving spend failed, dropped: " <> reason)
      }
  }
}

/// The GitHub App people connect their accounts through. With its private
/// key, the app's own token reads public repos nobody connected for, and
/// the bridge knows where the app is installed, which the config's
/// `accounts` asks.
fn start_github(
  settings: option.Option(config.GitHub),
) -> Result(
  #(option.Option(github.Config), option.Option(github_app.App)),
  String,
) {
  case settings {
    option.None -> Ok(#(option.None, option.None))
    option.Some(config.GitHub(client_id:, client_secret:, private_key:)) -> {
      let config =
        github.Config(
          client_id:,
          client_secret:,
          send: github.http,
          accounts: github.no_accounts,
        )
      case private_key {
        option.None -> Ok(#(option.Some(config), option.None))
        option.Some(key) -> {
          use app <- result.map(
            github_app.start(config, key)
            |> result.replace_error("couldn't start the GitHub App's keeper"),
          )
          log_github_installs(app)
          #(
            option.Some(
              github.Config(..config, accounts: fn() {
                github_app.accounts(app)
              }),
            ),
            option.Some(app),
          )
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

fn start_launcher(
  config: Config,
  bridge: launcher.Bridge,
  own_team: String,
) -> Result(launcher.Launcher, String) {
  let root = config.root
  let models = config.models
  case config.sandbox {
    config.Local(crush:) -> {
      io.println(
        "crushling: local launcher, agents run unsandboxed with your access",
      )
      Ok(launcher.local(root, crush, models, bridge))
    }
    config.Docker(docker) -> {
      use uid <- result.try(id("-u"))
      use gid <- result.try(id("-g"))
      let policy =
        sandbox.Policy(
          docker: "docker",
          image: docker.image,
          runtime: docker.runtime,
          network: docker.network,
          cpus: docker.cpus,
          memory: docker.memory,
          pids: 1024,
          uid:,
          gid:,
          root:,
          env: [],
          // The Honcho settings are the operator's own memory, so only the
          // self-host workspace's sandboxes get them. Other workspaces get
          // none until they have memory settings of their own.
          own_team:,
          own_env: docker.honcho,
          crush_config: provider.config(models, bridge.url),
          crush: docker.crush,
          dns: docker.dns,
          bridge_url: bridge.url,
        )
      prune_images(policy)
      Ok(launcher.docker(policy, bridge))
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

/// The inference proxy, with the org's key.
fn start_proxy(
  settings: config.Proxy,
  secret: String,
) -> Result(proxy.Proxy, String) {
  proxy.start(proxy.Config(
    secret:,
    org_key: settings.org_key,
    upstream: settings.upstream,
    thread_cap: settings.thread_cap,
    instance_cap: settings.instance_cap,
    max_per_thread: proxy.default_max_per_thread,
    max_uploads: proxy.default_max_uploads,
    upload_timeout_ms: proxy.default_upload_timeout_ms,
  ))
  |> result.map_error(fn(reason) {
    "the proxy upstream (CRUSHLING_PROXY_UPSTREAM or HYPER_URL) " <> reason
  })
}
