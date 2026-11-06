# Status

What exists, what it assumes, and what is left.

`gleam test` runs the pure tests. The end-to-end tests drive a real
`crush server` and a real model, and are skipped unless enabled:

    CRUSHLING_REAL=1 gleam test    # key from .env: CRUSH_HYPER_API_KEY

They start their own server with an isolated global config (one provider,
default hyper with `deepseek-v4.1-flash` large and `prism-flash` small) and
cover queued prompt order, diffs of `bash` edits, history staying clean, and
the bridge surviving a server killed mid-run. Never give the test server a
copy of an OAuth login: refresh tokens are single use, so a copy that
refreshes revokes the real one.

`HYPER_URL` is passed through to the test server, so the key has to belong
to whichever deployment it names. With a production key and `HYPER_URL`
exported in the shell, run `env -u HYPER_URL gleam test`.

Nothing has talked to Slack yet.

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
4. Provider keys through a host-side proxy rather than `--env`.
5. Optional: a small transport interface on the thread actor, tested with
   event sequences recorded from a real server, for edge cases the gated
   tests can't trigger on cue.
