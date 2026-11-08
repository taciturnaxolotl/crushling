# Status

What exists, what it assumes, and what is left.

`gleam test` runs the unit tests. The end-to-end tests drive a real
`crush server` and a real model, wired as in production, and are skipped
unless enabled:

    CRUSHLING_REAL=1 gleam test                                     # hyper key from .env
    CRUSHLING_REAL=1 CRUSHLING_TEST_BACKEND=claude gleam test       # Claude login
    CRUSHLING_REAL=1 CRUSHLING_TEST_BACKEND=hyper-login gleam test  # Hyper login

They cover queued prompt order, diffs of `bash` edits, history staying
clean, and the bridge surviving a server killed mid-run.

The Slack side runs on slackline over Socket Mode. It hasn't been run against
a real workspace yet.

## Running it

    gleam run

Configuration is from the environment or `.env`; see the table at the top of
`src/crushling.gleam`. The minimum for trying it locally:

    SLACK_BOT_TOKEN=xoxb-...
    SLACK_APP_TOKEN=xapp-...
    CRUSHLING_ALLOWED_USERS=U012345
    CRUSHLING_BACKEND=hyper-key        # or claude / hyper with a seeded login
    CRUSHLING_LAUNCHER=local           # unsandboxed: agents run as you

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
`list_channels`, `user_info`, `post_message`, `share_file`, and
`open_code_channel`, which lets the agent move its work to a code channel
itself, with a task name for the title. Reading reaches any channel the bot
is in; posting and sharing only reach the conversation the agent is in.

The tools are served over HTTP on `CRUSHLING_MCP_BIND`:`CRUSHLING_MCP_PORT`
(default `127.0.0.1:7469`), one endpoint per thread, with a bearer token
derived from a secret in `$CRUSHLING_ROOT/mcp-secret`. The `local` launcher
uses them by default. A `docker` sandbox can't reach the host through the
egress filter, so they are off until `CRUSHLING_MCP_URL` names an address it
can, such as the `sbx-egress` gateway with the bridge bound there and the
port let through (see `docs/kloe-sandbox.md`).

## Providers

Agents use a Claude subscription or Charm Hyper (`crushling/provider`), from
a login or, for Hyper, a plain key.

A login is a crush.json that only crushling uses, seeded once:

    CRUSH_GLOBAL_DATA=~/.local/state/crushling/claude crush login claude
    CRUSH_GLOBAL_DATA=~/.local/state/crushling/hyper crush login hyper

`crushling/credentials` is the only process that refreshes it. Each
container's crush.json gets a managed copy: the access token with an empty
refresh token. crush adopts a newer token from disk before every turn and
on a 401, so `credentials` renews at half the token's life and rewrites
every container's file, and crush never refreshes on its own. No crush
changes and no proxy: containers talk to the provider directly, with crush's
own Claude Code fingerprinting (`CRUSH_CLAUDE_VERSION` is set, so no
`claude` binary is needed).

What a container can leak is an access token (hours), never the refresh
token. With a Hyper key, the key itself sits in the container.

`CRUSHLING_EXTRA_BACKENDS` adds more providers to every agent's crush.json,
so it can run subagents on their models while it runs on its own:
`CRUSHLING_BACKEND=hyper-key CRUSHLING_EXTRA_BACKENDS=claude` gives a Hyper
agent Claude subagents. Each extra login gets its own `credentials` process,
and they share the container's file under a lock.

    CRUSHLING_REAL=1 CRUSHLING_TEST_EXTRA=claude gleam test   # also checks this

Never give crushling the login your own crush uses: refresh tokens are
single use, so the two would revoke each other.

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
| `crushling/meta` | What the bridge saves for each thread (follow, pause, cursor, venue) and each code channel (its thread). Files are replaced whole. |
| `crushling/snapshot` | Shell commands that snapshot the workspace into a private bare repo under `.crush/` and diff two snapshots. |
| `crushling/provider` | Claude, Hyper login, or Hyper key: the container's crush.json, env, and login. |
| `crushling/credentials` | The one refresher of a login; keeps a managed token fresh in every watched container config. |
| `crushling` | Entry point: reads the settings, starts credentials, the registry and Socket Mode. |
| `crushling/socket` | Socket Mode on stratus, reconnecting on request or drop; turns events into `Incoming`. |
| `crushling/registry` | Maps thread keys to actors. Handles the allowlist, duplicate events, commands, lazy launch and idle shutdown, and writes all thread meta. |
| `crushling/registry/links` | Links code channels to their threads, in memory and on disk. |
| `crushling/slack` | The `Sink` over chat.postMessage/update and slackline's `stream` for run replies, with markdown and plan blocks and file uploads; prompt text cleanup. |
| `crushling/launcher` | Where an agent runs: `docker` (gVisor sandbox) or `local` (on this machine, dev only). |
| `crushling/sandbox` | `docker run` arguments, a policy fingerprint label, adopt/start/recreate, stop (warm) and remove (cold). |

## Decisions worth knowing

- Two connections per thread: an HTTP/1.1 connection streaming SSE can't
  carry other requests.
- The bridge queues prompts and sends the next only after `run_complete`.
  Found against the real server: crush starts each prompt on its own
  goroutine, so two sent together race and can run out of order, and
  messages carry no run id to tell their output apart.
- The container runs as the service uid (`--user`), not root like kloe, so
  the host can connect to the socket and owns the workspace files.
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
- A runtime entry with `--host-uds=create` lets a gVisor container listen on
  a socket in a bind mount that the host can connect to.
- Two sessions in one workspace stream in parallel (irrelevant with one
  workspace per container, which is the plan).

## Left

1. Try it in a real workspace, with `CRUSHLING_LAUNCHER=local` first.
2. The sandbox image (Nix, with `crush` in it) and the `~/dots` module:
   `runsc-uds` runtime, `sbx-egress` network and firewall rules, prune
   filter, service user with a pinned uid. Check that a socket in a bind
   mount works under gVisor with `--host-uds=create`.
3. Run the Claude and Hyper-login end-to-end tests once crushling logins are
   seeded.
4. Smaller things: a cold tier that removes long-idle containers; a prompt
   the thread actor fails to send never counts as finished, so that thread
   never idles; a Cancel button in addition to replying `stop`.
