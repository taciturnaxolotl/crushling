# Configuration

crushling reads its settings from the environment, else from `./.env`, once at start (`src/crushling/config.gleam`). Every problem is reported at once, and a number that is set but not a number is always an error.

| Variable | Meaning |
|---|---|
| `SLACK_BOT_TOKEN` | self-host: the `xoxb-` token of your workspace. On start it is put in the store as that workspace (from auth.test), and the meta and link files from before the store are imported once. Required unless the OAuth install is on |
| `SLACK_SIGNING_SECRET` | the app's signing secret; set it to take events over HTTP at `/slack/events` |
| `CRUSHLING_EVENTS_BIND`, `CRUSHLING_EVENTS_PORT` | where that endpoint, and the OAuth install, listen; default `127.0.0.1:7470` |
| `SLACK_APP_TOKEN` | `xapp-` token for Socket Mode; with both set, events are taken both ways. One app-level token serves every workspace the app is installed in |
| `CRUSHLING_ALLOWED_USERS` | comma-separated Slack user ids who may use it, in the `SLACK_BOT_TOKEN` workspace; required with that token. `*` (alone or among ids) means everyone in the workspace: full members only, checked with users.info and kept 10 minutes, so not guests, people from other workspaces in shared channels, bots or deactivated accounts. A workspace's `allowed_users` setting in the store wins, and takes `*` too |
| `CRUSHLING_ADMINS` | comma-separated Slack user ids who may approve tailnet access in that workspace; `*` is refused. Default: the ids in `CRUSHLING_ALLOWED_USERS`, or nobody when that is `*`. A workspace's `admins` setting in the store wins |
| `SLACK_CLIENT_ID`, `SLACK_CLIENT_SECRET`, `CRUSHLING_PUBLIC_URL` | the OAuth install, on only when all three are set: `<public url>/slack/install` starts it and Slack returns to `<public url>/slack/oauth/callback` (add that redirect URL in the app's settings). Both are served on the events server. Until the app's public distribution is on, only its own workspace can install it |
| `CRUSHLING_STORE_KEY` | 32 bytes, base64: the key bot tokens are encrypted with in the store, `<root>/crushling.db`. Unset, one is made at `<root>/store-key` (mode 0600), like `<root>/mcp-secret`; back it up, since stored tokens can't be read without it |
| `CRUSHLING_HYPER_KEY` | required: the org's Charm Hyper API key; else `HYPER_API_KEY`, else `CRUSH_HYPER_API_KEY`. Agents use Hyper through the bridge's inference proxy at `/proxy/<thread>` and never see the key, nor the bridge's own `HYPER_*` settings |
| `CRUSHLING_GITHUB_CLIENT_ID` | the client id of the GitHub App people connect their GitHub accounts through (in the App Home, or with `!github connect`); unset turns GitHub off. The app needs device flow on. With the docker launcher, sandboxes' git and gh then read GitHub through the bridge at `/git/...` and as `api.github.com`, as the person the agent works for (`crushling/github/route`) |
| `CRUSHLING_GITHUB_CLIENT_SECRET` | optional: lets a disconnect revoke the token on GitHub too |
| `CRUSHLING_GITHUB_PRIVATE_KEY` | optional: the GitHub App's private key, PEM or base64 of it. Reads of public repos nobody connected for then use the app's token rather than none (`crushling/github/app`) |
| `CRUSHLING_LARGE`, `CRUSHLING_SMALL` | Hyper models; default `prism` and `prism-flash` |
| `CRUSHLING_MODE` | `sysadmin` (default: no permission prompts and no blocked commands) or `yolo` |
| `CRUSHLING_LAUNCHER` | `docker` (default) or `local`, which runs agents unsandboxed as you |
| `CRUSHLING_ROOT` | where thread workspaces live, one directory per thread key (`<team>-<channel>-<ts>`), beside the store `crushling.db`; default `~/.local/state/crushling/threads`. The tunnels' unix sockets live under it too, so it must be at most 79 bytes |
| `CRUSHLING_IDLE_MINUTES` | idle time before a thread's agent is stopped; default 15 |
| `CRUSHLING_SHUTDOWN_GRACE_SECONDS` | on SIGTERM, how long running turns get to finish before they are cancelled; default 60 |
| `CRUSHLING_CRUSH` | a `crush` with `--dial` to run instead of the default. For `docker`, a static linux binary on this machine to mount into each sandbox instead of the image's own; replacing the file (rename over it) gives new sandboxes the new one. For `local`, a binary for this machine instead of the `crush` on `PATH` |
| `CRUSHLING_DNS` | for `docker`, comma-separated nameservers for the sandboxes, since docker's DNS doesn't answer gVisor on a custom network; default `1.1.1.1,9.9.9.9`, or `off` for docker's own |
| `HONCHO_API_KEY`, `HONCHO_URL`, `HONCHO_WORKSPACE`, `HONCHO_PEER_NAME`, `HONCHO_AI_PEER` | passed into the sandboxes of the `SLACK_BOT_TOKEN` workspace only, so its agents remember across threads with Honcho; other workspaces get no memory settings yet |
| `CRUSHLING_IMAGE`, `CRUSHLING_RUNTIME`, `CRUSHLING_NETWORK` | for `docker`; defaults `crushling-sandbox:latest`, `runsc`, `sbx-egress` |
| `CRUSHLING_BRIDGE_PORT`, `CRUSHLING_BRIDGE_BIND` | where the sandbox server listens: the one port agents reach the bridge on, for their tunnels, the inference proxy and their Slack tools; default `7469` on `127.0.0.1`. `CRUSHLING_MCP_PORT` and `CRUSHLING_MCP_BIND` are the old names, still read |
| `CRUSHLING_BRIDGE_URL` | how an agent reaches that port; default `http://127.0.0.1:<port>` for `local`, required for `docker` (an address the sandbox network may reach, such as its gateway). `CRUSHLING_MCP_URL` is the old name, still read |
| `CRUSHLING_SANDBOX_CPUS`, `CRUSHLING_SANDBOX_MEMORY` | each docker sandbox's CPU and memory caps, as docker's `--cpus` and `--memory` take them; default `2` and `4g`. A value the bridge can't read stops it at start |
| `DOCKER_HOST` | read only as `unix://<path>`: the Docker Engine's socket; default `/var/run/docker.sock` |
| `CRUSHLING_HELLO_TIMEOUT_SECONDS` | how long a starting agent gets to dial in before it is stopped; default 30 |
| `CRUSHLING_TAILSCALE_CLIENT_ID`, `CRUSHLING_TAILSCALE_CLIENT_SECRET` | an OAuth client with the `auth_keys` scope that owns the tag; with it, people can put a thread's sandbox on the tailnet for a while |
| `CRUSHLING_TAILSCALE_API_KEY` | an API access token, instead of the OAuth client |
| `CRUSHLING_TAILSCALE_TAG` | the tag sandboxes join with; default `tag:crushling` |
| `CRUSHLING_TAILSCALE_TAILNET` | the tailnet's name; default `-`, the credential's own |
| `CRUSHLING_PROXY_UPSTREAM` | where the proxy sends requests; else `HYPER_URL`, else `https://hyper.charm.land` |
| `CRUSHLING_PROXY_THREAD_CAP_USD`, `CRUSHLING_PROXY_THREAD_CAP_TOKENS` | what one thread may spend through the proxy, in US dollars and/or tokens; unset is unlimited |
| `CRUSHLING_PROXY_INSTANCE_CAP_USD`, `CRUSHLING_PROXY_INSTANCE_CAP_TOKENS` | the same for each workspace's threads together, over the last 30 days; one workspace at its cap leaves the others alone. The thread cap counts everything the thread ever spent. Both count what the store kept, so they survive restarts |

## Upgrading from before the store-backed caps

The cap settings kept their names but count differently now:

- `CRUSHLING_PROXY_THREAD_CAP_*` used to count spend since the bridge last started. It now counts everything the thread ever spent, so a long-lived thread already past the cap is refused on its first request after the upgrade.
- `CRUSHLING_PROXY_INSTANCE_CAP_*` used to be one total for the whole bridge since it started. It is now per workspace, over the last 30 days.

Raise the caps before upgrading if old threads should keep working.

Empty settings (`NAME=`) count as unset for the GitHub settings, as they did before.
