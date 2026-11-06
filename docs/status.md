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

Nothing has talked to Slack yet.

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
| `crushling/render` | Markdown progress view and final reply, split under Slack's markdown-block limit with code fences kept balanced. |
| `crushling/thread` | One actor per thread. Owns two connections, a workspace and a session; sends prompts with fresh run ids; throttles updates through a `Sink`; reconnects and settles runs stranded by a dropped stream. |
| `crushling/snapshot` | Shell commands that snapshot the workspace into a private bare repo under `.crush/` and diff two snapshots. |
| `crushling/provider` | Claude, Hyper login, or Hyper key: the container's crush.json, env, and login. |
| `crushling/credentials` | The one refresher of a login; keeps a managed token fresh in every watched container config. |
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

1. The Slack `Sink`, on `slackline`: `chat.postMessage` and `chat.update` with
   a markdown block, file upload for patches, and Socket Mode routing
   `app_mention` and thread replies to thread actors.
2. A registry: thread key to actor, `sandbox.ensure` before starting a
   thread, idle timers for the warm and cold tiers, and a user allowlist.
3. The sandbox image (Nix, with `crush` in it) and the `~/dots` module:
   `runsc-uds` runtime, `sbx-egress` network and firewall rules, prune
   filter, service user with a pinned uid.
4. Run the Claude and Hyper-login end-to-end tests once crushling logins
   are seeded. The registry must `credentials.watch` each container's
   `sandbox.host_crush_data(...)/crush.json` before starting it, and
   `unwatch` when it is removed.
5. Optional: a small transport interface on the thread actor, tested with
   event sequences recorded from a real server, for edge cases the gated
   tests can't trigger on cue.
