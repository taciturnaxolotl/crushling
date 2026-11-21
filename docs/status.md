# Status

What exists, what it assumes, and what is left.

`gleam test` runs the unit tests. The end-to-end tests drive a real
`crush server` and a real model, wired as in production, and are skipped
unless enabled:

    PATH=~/.local/state/crushling-dev:$PATH CRUSHLING_REAL=1 gleam test

The `crush` on `PATH` must have `--dial` and resumable event streams (see
"Sandbox image" below). Inference goes through a real inference proxy with
the org's Hyper key from `CRUSHLING_HYPER_KEY`, else `CRUSH_HYPER_API_KEY`
(environment or `.env`).

They cover queued prompt order, diffs of `bash` edits, history staying
clean, the bridge surviving a server killed mid-run, and the local launcher
end to end: crush dials in through the tunnel and its turn is metered by the
proxy.

The Slack side runs on slackline over Socket Mode. It hasn't been run against
a real workspace yet.

## Running it

    gleam run

Configuration is from the environment or `.env`; see the table at the top of
`src/crushling.gleam`. The minimum for trying it locally:

    SLACK_BOT_TOKEN=xoxb-...
    SLACK_APP_TOKEN=xapp-...
    CRUSHLING_ALLOWED_USERS=U012345
    CRUSHLING_HYPER_KEY=...            # the org's Hyper key; agents never see it
    CRUSHLING_LAUNCHER=local           # unsandboxed: agents run as you

`local` runs `crush server --dial` against the bridge on
`http://127.0.0.1:7469`, the same way a sandbox does, so that `crush` must
have `--dial` (put `~/.local/state/crushling-dev` first on `PATH`, or set
`CRUSHLING_CRUSH`).

The Slack app needs Socket Mode, the `app_mention` and `message.channels`,
`message.groups`, `message.im` events, and the scopes `app_mentions:read`,
`chat:write`, `code_channels:manage`, `files:read`, `files:write`,
`channels:history`, `channels:read`, `groups:history`, `groups:read`,
`im:history`, `users:read`, and the `code_channels` feature;
`docs/slack-manifest.yaml` has it all.

Mention the bot to start a thread; reply in the thread to continue it; reply
`stop` to cancel the current run. A direct message starts a thread too.
`!pause` makes a thread or code channel answer only when the bot is
mentioned; `!resume` (no mention needed) has it follow along again. A paused
agent still catches up on what was said when it is next mentioned.

When the agent clones a repository (`git clone` or `gh repo clone` through
`bash`), the work moves to a code channel opened from the thread: replies go
there, every message in it is a prompt, the context bar shows the repo,
branch and changed files, and the Code tab holds the diff against the
default branch. The channel stays open while the agent sleeps; `!done` archives
it with the last reply as its summary, and a later message in the thread
opens a new one. If Slack will not open a code channel, the work stays in
the thread. Each run's reply then lists the repository's changed files and
attaches its diff.

A run is one message: what the agent says streams into it as it is written,
its steps sit in a plan block in the same message, and the block settles to
"Done · N steps" while the closing line names the files it changed. The
streaming is slackline's `stream` module: the thread hands it the whole
reply so far each flush, and it sends only what is new, carries a long run
on in a new message before Slack's ten-minute and size limits, posts any
text rewritten after it streamed, and falls back to a plan card and plain
messages where Slack won't stream. Slack only streams in a channel to a
named recipient, so each run carries the id of who asked.

A subagent's thread shows what it says between tool calls as it goes, not
only its final answer.

### Slack tools

Each agent gets a `slack` MCP server from the bridge (`crushling/mcp`,
`crushling/slack_tools`): `read_conversation`, `read_channel`,
`list_channels`, `user_info`, `post_message`, and
`open_code_channel`, which lets the agent move its work to a code channel
itself, with a task name for the title. Reading reaches any channel the bot
is in; posting and sharing only reach the conversation the agent is in.

The tools are served on the sandbox server (below), one endpoint per thread
at `/mcp/<thread>`, with a bearer token derived from a secret in
`$CRUSHLING_ROOT/mcp-secret`.

## Workspaces and the store

One bridge serves any number of Slack workspaces. Each one has an
instance (`crushling/instance`): its own registry, and a Slack client with
its own bot token. The rest is shared, one per bridge: the launcher, the
tunnels, the inference proxy, the sandbox server, the store and the
instance secret (`$CRUSHLING_ROOT/mcp-secret`).

Events arrive over Socket Mode (one app-level token serves every workspace
the app is in) and/or HTTP, and both go through one slackline `app.App`.
slackline hands each event handler the envelope's `team_id`,
`enterprise_id` and `authorizations`, and each block action its payload's
`team`, so routing stays in crushling: the router takes the workspace the
event was delivered to from the first authorization (in a Slack Connect
channel `team_id` is the workspace the message was posted in, which may
not be ours), else `team_id`, and passes the event to that instance's
registry. Slack Connect routing hasn't been tried against real shared
channels yet. An event for a workspace the bridge doesn't serve is
dropped with a log line. slackline has no per-workspace token lookup (like
Bolt's `authorize`), so the Slack tools, files and tailnet flow find a
thread's workspace from its key and use that instance's client; such a hook
would let one client follow the event's workspace.

Thread keys carry the workspace: `T…-C…-<ts>` (`sandbox.key`), at most 64
characters of `[A-Za-z0-9_.-]`. Every thread's directory, container
(`crushling-<key>`), tunnel, proxy and Slack tool tokens are named by it,
so two workspaces never share any of them.

Each registry is started by the teams actor without a link and monitored:
a crash in one workspace leaves the others running, and its registry is
started again a second later (from the store, so with its latest token),
with a log line. Shutdown stops them for good.

Honcho memory (`HONCHO_*`) is the operator's own, so only the self-host
workspace's sandboxes get those settings; other workspaces get no memory
until they have settings of their own (later, from `team_settings`). The
`local` launcher passes no Honcho settings to any agent.

### The store

State is one SQLite file, `$CRUSHLING_ROOT/crushling.db`, in WAL mode with
foreign keys on and a busy timeout, behind `crushling/store`: one actor
owns the connection, so writes are serialized. The schema is versioned with
`PRAGMA user_version` and migrated on start. Tables:

- `teams`: `team_id` (key), `bot_token_enc`, `bot_user`, `enterprise_id`
  (null unless on Enterprise Grid), `installed_by`, `installed_at` (unix
  seconds), `active`;
- `team_settings`: `team_id`, `name`, `value`, a plain key/value list.
  `allowed_users` and `admins` (comma-separated user ids) are read today;
- `threads`: `key` (key), `team_id`, `channel`, `thread_ts`, and the meta:
  `follow`, `paused`, `cursor`, `venue` (JSON), `tailnet` (JSON or null),
  `updated_at`;
- `links`: `team_id`, `channel` (together the key), `origin_channel`,
  `origin_ts`, `opened_ts`;
- `bridge`: the bridge's own notes, such as that the old files were
  imported.

Bot tokens are encrypted with AES-256-GCM, a fresh nonce per value and the
team id as associated data, under `CRUSHLING_STORE_KEY` (32 bytes, base64).
Without it, the bridge makes `$CRUSHLING_ROOT/store-key` (mode 0600) on
first start and says so; back it up, since stored tokens can't be read
without it.

A workspace's allowlist and admins come from its `team_settings`. The
self-host workspace, the one of `SLACK_BOT_TOKEN`, falls back to
`CRUSHLING_ALLOWED_USERS` and `CRUSHLING_ADMINS`; an installed one starts
with whoever installed it. Admins approve tailnet access (everyone allowed
does when there are none), and only the self-host workspace gets tailnet
access at all, since the Tailscale credential is the operator's.

On start, self-host puts the `SLACK_BOT_TOKEN` workspace in the store (from
auth.test), starts its instance, then one for every other active workspace
in the store.

### Moving from files

Before the store, meta was `<root>/<key>/crushling.json` and links
`<root>/<channel>-code/crushling.json`. The first start with
`SLACK_BOT_TOKEN` imports them all for that workspace, logs what it
imported and each directory it skipped (and why), and never reads them
again; the files stay where they are.

Threads from before keys carried the workspace keep their old key,
`C…-<ts>`, until they are next looked up. Only the self-host workspace
moves such threads (another workspace never had them). When the new key is
missing its row or its directory, the registry finishes the move from the
old key, step by step, so a move cut short by a crash completes on the
next lookup:

- the directory, if the old one exists and the new one doesn't: the
  launcher's `rekey` removes the old container (`docker rm --force`, "no
  such container" is fine; the local launcher stops the old server by its
  pid file) and renames `<root>/<old key>` to `<root>/<new key>`;
- the row, if the old one exists (of this workspace, or imported without
  one) and the new one doesn't, in one transaction.

If a step fails, the registry doesn't start a fresh thread under the new
key, which would hide the old work: it posts once in the thread that an
admin should check the logs, drops the message, and tries again on the
next one. Its tokens are derived
from the key, so they change with it; nothing keeps the old ones, and the
next launch makes a new container with the new key's environment.

### Installing in a workspace

With `SLACK_CLIENT_ID`, `SLACK_CLIENT_SECRET` and `CRUSHLING_PUBLIC_URL`
all set, the events server (`CRUSHLING_EVENTS_BIND`:`PORT`, not the sandbox
port) also serves:

- `GET /slack/install`, which redirects to Slack's authorize page with the
  manifest's bot scopes, the redirect URI
  `<CRUSHLING_PUBLIC_URL>/slack/oauth/callback` and a state signed with the
  instance secret, good for ten minutes;
- `GET /slack/oauth/callback`, which checks the state, exchanges the code
  with `oauth.v2.access`, stores the workspace with its token encrypted,
  starts its instance and shows a plain page.

A new workspace starts with its installer as its allowlist and admins. A
reinstall stores the new token and keeps the workspace's settings and its
first installer; installing into the self-host workspace never writes
people, which come from the environment. If the new instance won't start,
the workspace is marked inactive and the page says so. Org-wide
(Enterprise Grid) installs are refused, since the app isn't set up for
org deployment (`org_deploy_enabled: false`).

The state is signed and expires, but isn't tied to the browser that
started the install (no nonce cookie), so it doesn't stop login CSRF; that
is a follow-up.

Add the redirect URL under "OAuth & Permissions" in the app's settings.
Until "public distribution" is turned on there ("Manage Distribution"),
only the app's own workspace can complete the install, which is enough to
try it. No Marketplace listing is needed either way: with public
distribution on, any workspace can install from the link, still unlisted.

With the install on, `SLACK_BOT_TOKEN` is optional. Events still need
Socket Mode or HTTP delivery set up as above.

## The sandbox server

Agents reach the bridge on one port, `CRUSHLING_BRIDGE_BIND`:
`CRUSHLING_BRIDGE_PORT` (default `127.0.0.1:7469`; the old names
`CRUSHLING_MCP_BIND` and `CRUSHLING_MCP_PORT` still work), at
`CRUSHLING_BRIDGE_URL` (old name `CRUSHLING_MCP_URL`). It always runs, and
serves four things, each with its own per-thread token:

- `/tunnel/<thread>`: the thread's `crush server --dial` connects here
  (`crushling/tunnel`). The bridge reaches that server through a unix
  socket shim at `$CRUSHLING_ROOT/s/<hash of thread>.sock`, so the thread's
  HTTP client is the same as for a listening server.
- `/proxy/<thread>`: the inference proxy (`crushling/proxy`), which swaps
  the thread's token for the org's Hyper key, meters usage and enforces the
  caps.
- `/mcp/<thread>`: the Slack tools.
- `/files/<thread>`: Slack attachments and shared files (`crushling/files`,
  see Files below), with the Slack tools' token.

For `local` the URL defaults to `http://127.0.0.1:<port>`. For `docker` it
is required: an address of this machine the sandbox network may reach on
that port, such as its gateway with the bridge bound there (see
`docs/sandbox.md`).

A launch opens the thread's tunnel, restores its proxy token, starts the
sandbox, and waits up to `CRUSHLING_HELLO_TIMEOUT_SECONDS` (default 30) for
crush to dial in. Any failure along the way undoes every step so far,
including stopping the container. A stop tells crush to exit, stops the
sandbox, closes the tunnel and revokes the proxy token. The token is the
same on every launch, since it's derived from the thread's key, and it
only ever lives in that thread's own sandbox and workspace. So restoring
it on resume is fine. The `local` launcher stops its servers by the pid it
recorded in `<root>/<thread>/server.pid`.

A thread's launch and stop never overlap. While an agent is stopping, its
thread is `Stopping`, and new messages wait until the stop finishes, then
start the agent again. A stop that fails is retried after 1, 5 and 15
seconds, with messages still waiting; if every try fails the registry logs
an error, posts one notice in the thread and gives up on that agent.
Shutdown waits for launches in flight, stops what they started, and only
then exits. It has one deadline, `registry.shutdown_budget_ms`: the grace
period, 10s for cancelled turns, 120s for launches and stops, and a 5s
margin. The bridge exits 0 when every agent stopped and 1 (with a log
line) when shutdown timed out or a stop failed.

The `local` launcher records each server's pid, start time and dial URL
(which names the thread) in `<root>/<thread>/server.pid`, and only signals a
process that still matches all three, checked before TERM, before KILL and
at every poll.

### Files

The bridge and a sandbox share no filesystem, so files cross over HTTP on
the same port (`crushling/files`). Every Slack attachment is kept on the
bridge at `$CRUSHLING_ROOT/<thread>/files/<file_id>-<name>`. Downloads from
Slack are capped at 64 MiB as they are read, whatever size Slack claims; a
bigger file is named in the prompt as "too large to fetch" and not kept.
Images up to 5 MiB (by type, or by their first bytes when the type is
generic) are also sent with the prompt for the model to see, and text up to
64 KiB (`text/*`, JSON, YAML, and source code by name when the type is
generic) is pasted into it, unless it has NUL bytes or isn't UTF-8. The
prompt names every file with the command that fetches it. The agent shares
a file into its conversation with `crushling-share`; the bot posts it in
the thread, as `share_file` used to.

- `GET /files/<thread>/<file_id>` serves a kept file;
- `POST /files/<thread>?name=<name>&comment=<text>` needs a Content-Length
  of at most 64 MiB (411 when chunked or missing, 413 when too long), keeps
  the file, posts it in the thread's conversation, and answers
  `{"id": ..., "message": ...}`. At most 2 uploads per thread and 8 in all
  run at once; more get 429. A file Slack wouldn't take isn't kept.

Both take the thread's MCP token. A file id only resolves inside its own
thread's directory. Kept files stay with the thread's directory, as saved
attachments stayed in its workspace before; nothing deletes a thread's
directory yet.

#### The sandbox helpers

The `share_file` tool is gone, so an agent can only share files, and only
fetch attachments that aren't inline, with the two helpers in `sandbox/bin`.
**They must ship in the same rollout as this bridge**, on the sandbox's
`PATH`, along with `curl` (7.55 or later, for `-H @-`), `od`, `sed`,
`mktemp` and a POSIX `sh`:

- `crushling-fetch <file_id> [dest]` downloads into `.slack/<name>` by
  default, or into a directory given with a trailing `/`, or to a file path.
  It refuses a symlinked `.slack` or target, and a target that is a
  directory.
- `crushling-share <path> [comment]` uploads into the conversation.

They read `CRUSHLING_BRIDGE_URL`, `CRUSHLING_THREAD` and
`CRUSHLING_MCP_TOKEN`, which the bridge sets in every sandbox's
environment (`CRUSHLING_BRIDGE_URL` is the bridge's own setting of that
name); the token reaches curl on stdin, not in its arguments.

The docker image (`crushling-sandbox` in `~/dots`,
`modules/nixos/services/crushling.nix`): its base, `buildpack-deps`, already
has curl. Fetch this repo at the deployed revision and copy the helpers in
with the other tools in `extraCommands`:

```nix
crushlingSrc = pkgs.fetchgit {
  url = "https://tangled.org/dunkirk.sh/crushling";
  rev = "<the deployed commit>";
  hash = "<its hash>";
};
# in image.extraCommands, next to the gh and rg links:
install -m 0755 ${crushlingSrc}/sandbox/bin/crushling-fetch usr/local/bin/
install -m 0755 ${crushlingSrc}/sandbox/bin/crushling-share usr/local/bin/
```

Bump `rev` with each bridge deploy that changes `sandbox/bin`; the image tag
changes with it, so new sandboxes get the new helpers.

The Daytona snapshot: build it from a Dockerfile whose context is a
checkout of this repo at the deployed revision:

```dockerfile
RUN command -v curl || (apt-get update && apt-get install -y --no-install-recommends curl ca-certificates)
COPY --chmod=0755 sandbox/bin/crushling-fetch sandbox/bin/crushling-share /usr/local/bin/
```

Check either image before rolling the bridge out, and whenever a sandbox
starts misbehaving with files:

```sh
docker run --rm --entrypoint sh crushling-sandbox:<tag> -c \
  'command -v crushling-share && command -v crushling-fetch && command -v curl'
```

and in a running sandbox (`docker exec crushling-<key> sh -c '...'`, or
Daytona's exec), the same `command -v crushling-share` plus
`test -n "$CRUSHLING_BRIDGE_URL"`.

## Tailnet access

A thread's sandbox can join your tailnet for a while, so the agent can reach
your machines. The agent asks with its `request_tailnet` tool, or someone
says `!tailnet` in the thread. Either way a card appears with buttons to
allow it for 1 or 8 hours, or to deny it. Only people on the allowlist can
press them. Once it is on, the card shows when it ends and a "Turn off"
button, and the agent gets a message that tells it how to connect.
`!tailnet off` also ends it.

Each time, the bridge makes a fresh auth key: single use, ten minutes,
preauthorized, for an ephemeral node tagged `tag:crushling`. Inside the
container, `tailscaled` runs in userspace mode, so gVisor needs no TUN
device and the sandbox reaches Tailscale over HTTPS like anything else. ssh
goes through `tailscale nc` for tailnet hosts, and other traffic can use the
SOCKS5 proxy on `localhost:1055` or the HTTP proxy on `localhost:1056`. The
container never sees the host's own tailnet identity, and the egress filter
keeps blocking the tailnet's addresses.

Access ends when its time is up, on `!tailnet off` or "Turn off", and on
`!done`. Then the node logs out, which removes it. When an agent goes
idle or crashes, its node goes away with the container, and if access hasn't
ended yet, the next container joins again.

To set it up:

1. Put `tailscale` and `tailscaled` in the sandbox image.
2. Add the tag and what it may reach to the tailnet policy, for example:

   ```json
   "tagOwners": { "tag:crushling": ["autogroup:admin"] },
   "grants": [
     { "src": ["tag:crushling"], "dst": ["tag:dev"], "ip": ["22", "80", "443"] }
   ]
   ```

   Give the agent its own user with few rights on each machine, or use
   Tailscale SSH with `check` mode so a person approves each login.
3. Make an OAuth client with the `auth_keys` write scope that owns `tag:crushling`, and set
   `CRUSHLING_TAILSCALE_CLIENT_ID` and `CRUSHLING_TAILSCALE_CLIENT_SECRET`.
   An API access token in `CRUSHLING_TAILSCALE_API_KEY` works too, but it
   expires after 90 days.

The `local` launcher can't do this. Its agents already share your machine's
network.

## Provider

Agents use Charm Hyper, and only through the bridge's inference proxy. The
org's key is `CRUSHLING_HYPER_KEY`, which the bridge requires; it never
leaves the bridge. Each agent's crush gets `HYPER_URL` (the proxy's
`/proxy/<thread>`) and `HYPER_API_KEY` (a token for that thread alone, which
stops working when the thread's agent is stopped). crush.json names the
Hyper models (`CRUSHLING_LARGE`, `CRUSHLING_SMALL`) and holds no key.

crush lets `CRUSH_<NAME>` override `<NAME>`, even when empty, so an agent
must never get `CRUSH_HYPER_API_KEY` or `CRUSH_HYPER_URL`. The local
launcher clears the bridge's environment for the same reason, and the
sandbox image must not define any `CRUSH_HYPER_*` variable.

The Claude and Hyper login backends, and the token refresher they needed,
are gone: `CRUSHLING_BACKEND`, `CRUSHLING_LOGIN`, `CRUSHLING_EXTRA_BACKENDS`
and `CRUSHLING_CLAUDE_VERSION` are no longer read.

## Modules

| Module | Does |
|---|---|
| `crushling/gun` | HTTP and SSE over a unix socket on `gun`. Requests block; stream events arrive as messages, picked up with `gun.select`. |
| `crushling/crush/client` | Each server call as a pure `Call` (method, path, body, parser), run with `perform`. |
| `crushling/crush/event` | Decodes the SSE envelope into `MessageEvent`, `RunCompleteEvent`, `AgentError`, `FileEvent`, or `Other`. |
| `crushling/run` | Pure state for one run: text by message id, tool calls and their status, file baselines and latest contents. |
| `crushling/diff` | Myers line diff and unified hunks, so diffs never need `git` on the host. |
| `crushling/render` | The run as text and steps: plan title, task rows, the reply so far, split under Slack's markdown-block limit with code fences kept balanced. |
| `crushling/thread` | One actor per thread. Sends each prompt with a new run id, shows progress through a `Sink`, and ends runs that a dropped stream left open. Keeps the thread's `Venue`, moves the work to a code channel, and tells the registry what happens through `Notice`s. |
| `crushling/thread/conn` | A thread's two connections to its server, its workspace and session, and shell commands that stay out of the agent's history. |
| `crushling/thread/subagents` | Gives each subagent its own Slack thread with a plan card and notes, and posts its report back to the parent. |
| `crushling/thread/repo` | Finds a repository in the workspace, lists its changes, and updates a code channel's context bar and Code tab. |
| `crushling/venue` | Where a thread's work is. That is the thread, a code channel, an archived channel, or the thread after Slack refused a code channel. |
| `crushling/sink` | The functions a thread uses to post in Slack. `crushling/slack` builds the real one. |
| `crushling/meta` | What the bridge saves for each thread (follow, pause, cursor, venue) and each code channel (its thread), and the old files' format, for their one-time import. |
| `crushling/store` | The SQLite store: workspaces (tokens encrypted), their settings, thread meta and code channel links; migrations and the import of the old files. |
| `crushling/instance` | One instance (registry and Slack client) per workspace, kept by team id; the self-host seed, per-workspace settings, the event router's lookup and the Slack tools' workspace. |
| `crushling/install` | The OAuth install: the authorize redirect with a signed state, and the callback that stores and starts a workspace. |
| `crushling/events` | The HTTP server for `/slack/events` and the install routes. |
| `crushling/snapshot` | Shell commands that snapshot the workspace into a private bare repo under `.crush/` and diff two snapshots. |
| `crushling/provider` | The agent's crush.json: Hyper models and the Slack tools, no key. |
| `crushling/tunnel` | Dial-out tunnels: each thread's `crush server --dial` connects to the bridge, which exposes it as a unix socket shim. |
| `crushling/proxy` | The inference proxy: thread tokens in, the org's Hyper key out, usage metered and capped. |
| `crushling/sandbox_http` | The one port agents reach the bridge on, with the tunnel, proxy and Slack tools routes. |
| `crushling` | Entry point: reads the settings, opens the store, starts the proxy, the tunnels, an instance per workspace, the sandbox server, the events server and Socket Mode. |
| `crushling/socket` | Socket Mode on stratus, reconnecting on request or drop; routes events by workspace and turns them into `Incoming`. |
| `crushling/registry` | One workspace's threads: maps thread keys to actors. Handles the allowlist, duplicate events, commands, lazy launch and idle shutdown, writes all thread meta to the store, and moves threads from their old keys. |
| `crushling/tailscale` | The Tailscale API (auth keys) and the scripts that join and leave the tailnet inside a sandbox. |
| `crushling/registry/tailnet` | Tailnet access for each thread: one rule (on the tailnet while the agent runs and access lasts), the Slack card and its buttons. |
| `crushling/registry/entry`, `incoming`, `prompt` | A thread's entry in the registry, an incoming Slack message, and the prompt built from it. |
| `crushling/registry/links` | Links code channels to their threads, in memory and in the store. |
| `crushling/slack` | The `Sink` over chat.postMessage/update and slackline's `stream` for run replies, with markdown and plan blocks and file uploads; prompt text cleanup. |
| `crushling/launcher` | Where an agent runs: `docker` (gVisor sandbox) or `local` (on this machine, dev only). Either way crush dials the tunnel and uses the proxy. |
| `crushling/sandbox` | `docker run` arguments, a policy fingerprint label, adopt/start/recreate, stop (warm) and remove (cold). |

## Decisions worth knowing

- Two connections per thread: an HTTP/1.1 connection streaming SSE can't
  carry other requests.
- The bridge queues prompts and sends the next only after `run_complete`.
  Found against the real server: crush starts each prompt on its own
  goroutine, so two sent together race and can run out of order, and
  messages carry no run id to tell their output apart.
- The container runs as the service uid (`--user`), not root like kloe, so
  the host owns the workspace files.
- crush dials out to the bridge (`--dial`) instead of listening on a socket
  in a bind mount: no mount, no `--host-uds`, plain `runsc`, and the bridge
  needn't share a filesystem with the sandbox. The old unix socket transport
  is gone rather than kept behind a setting: it needed its own runtime,
  mount and readiness check, and nothing still depends on it.
- `CRUSH_SERVER_IDLE_TIMEOUT` is set to a year inside the container: the
  bridge, not the server, decides when a sandbox sleeps.
- Diffs come from workspace snapshots: a tree written into a private bare
  repo at `.crush/crushling-snap` before and after each run, then `git
  diff`. This runs through the server's shell endpoint, so inside the
  sandbox, and catches edits made with `bash`, which emit no file events.
  The shell calls name a session id that doesn't exist, which makes the
  server skip saving their output into the agent's history. If the
  snapshot fails, the diff falls back to SSE `file` events.

## Assumptions to check against the real thing

- Slack's `markdown` block takes about 12,000 characters (`render.message_limit`).
- crush redials a bridge that restarted soon enough for an adopted
  container to say hello within the launch's wait; otherwise the launch
  stops it and the next one starts it fresh.
- Two sessions in one workspace stream in parallel (irrelevant with one
  workspace per container, which is the plan).

## Left

1. Try it in a real workspace, with `CRUSHLING_LAUNCHER=local` first.
2. Move prattle to the dial-out sandboxes: the `~/dots` changes and the
   crush build in `docs/sandbox.md`, then run the docker path for real.
   `tailscaled` started by `docker exec` outlives the exec (checked by hand
   on prattle).
3. Try a real tailnet join from a sandbox, once the OAuth client exists.
4. Hosted: a nonce cookie for the install's state; per-workspace Honcho
   settings; an App Home tab where a workspace's admins set its settings
   (today they are rows in `team_settings`); a reinstall's new token is
   stored but the running instance keeps the old one until a restart;
   uninstall events (`app_uninstalled`, `tokens_revoked`) don't mark a
   workspace inactive yet; the proxy's caps are per bridge, not per
   workspace.
5. Smaller things: a cold tier that removes long-idle containers; a prompt
   the thread actor fails to send never counts as finished, so that thread
   never idles; a Cancel button in addition to replying `stop`.
