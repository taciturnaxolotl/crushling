# GitHub access and the App Home

Steps 1 and 2 are built (see Order of work). It lets people delegate
GitHub work to the agent: read private repos, push branches, and stage pull requests that a person
opens from Slack. It also adds an App Home where each person manages their
connection and sees what crushling is doing.

## Decisions

- **The agent acts as the person who asked.** Each person connects their
  GitHub account once. The agent uses their token, so it can never reach
  more than they can, and GitHub shows the work as "<person> via crushling".
  Without a connection, requests go to GitHub with no token, which reads
  public repos (and REST data) but not GraphQL. A token for the app itself
  (`crushling[bot]`) could fill that gap later.
- **Grants are standing.** A connected person's threads use their
  connection without asking each time. That is safe because the token is
  theirs: "standing" means "the agent can do what you could do", never more.
- **The sandbox never holds a token.** Git and `gh` go through the bridge,
  which adds the token. Nothing in the sandbox can read it or send it
  elsewhere.
- **Pushes are fenced.** The bridge refuses pushes to anything but
  `crushling/*` branches, and deleting those. Force-pushing one is fine: an
  agent reworks its own branch. `main` and everyone's other branches can't
  be touched, even by a misbehaving agent.
- **The agent stages pull requests; a person opens them.** The agent proposes
  a PR. A card in the thread shows it, and someone presses **Open PR** or
  **Open as draft**. The PR is opened as that person.

## Connecting a GitHub account

GitHub's device flow, which needs no public URL (Charm's VM has none):

1. Someone runs `!github connect`, presses Connect in the App Home, or
   presses the button on the agent's first request that needs it.
2. The bridge asks GitHub for a device code and shows it **only to that
   person**: an ephemeral message, or in their App Home.
3. They approve it on github.com. The bridge polls, gets the token and its
   refresh token, and stores both encrypted in the store (the same key as the
   Slack tokens), keyed by workspace and Slack user.
4. App user tokens expire after 8 hours. The bridge refreshes them as needed.
   A refresh that fails (revoked on GitHub) marks the connection gone and
   says so in the App Home.

`!github disconnect` or the App Home button revokes the token with GitHub and
deletes it.

## Which token a thread uses

The token of the person whose message the agent is working on: the sender
of the current turn's prompt. A turn crush starts by itself (a subagent
report) keeps the last sender. If a read is refused for want of access, the bridge asks that person, in
the thread, in one private message that changes as things move on, and
holds the agent's command until they act (up to 10 minutes):

- **Not connected**: "crushling would like private access to `owner/repo`.
  Would you like to connect crushling to your GitHub account?" Connect
  turns the message into the device code, then into "Connected as @login".
  The read is sent again as them.
- **Connected, but the app isn't installed on `owner`**: "crushling would
  like access to `owner/repo`, but it isn't set up on owner yet…", with a
  button to GitHub's install page. The bridge watches for the installation
  (which may wait on an org owner's approval) and sends the read again.

Only if they don't act in time does the agent get an error, which says
what's missing. Public repos read without asking: with the app's own
token when its key is set, else with none. The App Home lists the
accounts the app is on, with a link to add another.

## Git through the bridge

Each sandbox gets git settings in its environment (`GIT_CONFIG_*`), so
`https://github.com/`, `git@github.com:` and `ssh://git@github.com/` all go
to the bridge's `/git/<owner>/<repo>/...`, with the thread's token in an
`Authorization` header. The token names the thread (`<key>.<mac>`), so the
bridge knows whose GitHub to use. It forwards to GitHub with that person's
token:

- **upload-pack** (clone, fetch): streamed through as is.
- **receive-pack** (push): the bridge reads the pkt-line command list at
  the start of the request before any of it reaches GitHub. Every ref must
  be `refs/heads/crushling/<something>` and none a deletion, or the whole
  push is refused, with words git shows the agent. A push only ever goes as
  the person: without a connection it waits for one, like a read.
- **LFS**: refused.
- A redirect to another GitHub URL (a renamed repo) is rewritten to stay
  on the bridge. An error is answered in plain text, which git shows the
  agent after `remote:`.

## `gh` through the bridge

The image's `gh` is a wrapper ahead of the real one. It sets gh's
`http_unix_socket` to a socket that socat forwards to the bridge, and the
thread's token is `GH_TOKEN`. gh then speaks plain HTTP to the bridge with
`Host: api.github.com`, and the bridge sends it on with the person's token.
Only reads go through: GET and HEAD, and GraphQL queries (no `mutation` or
`subscription` outside strings and comments). Anything else is refused with
a JSON `message` gh prints. This alone would have made the #hyper review of
a private PR work.

## Staging pull requests

A new tool for the agent, next to its Slack tools:

    propose_pr(repo, head, base, title, body)

It opens nothing. The bridge checks that `head` is a `crushling/*` branch it
pushed, then posts a card in the thread:

- the title and body, and the base and head branches
- the commits and a diff summary (files changed, + and −)
- **Open PR**, **Open as draft**, **Dismiss**

A press opens the PR **as the person who pressed it**, if they're connected.
The card then links to the PR, and the agent is told it was opened (or
dismissed). Only people allowed to use the bot can press.

## The App Home

`app_home_opened` publishes a Home view for the person who opened it:

- **GitHub**: connected as `@login` with Disconnect, or a Connect button that
  shows the device code right there.
- **Your threads**: their threads with a running agent, each linked, with its
  model and what it has spent.
- **crushling**: sandboxes running now (and the limit), spend today across
  the workspace, the default model.
- **Later, MCP servers**: a person adds their own MCP servers (URL plus OAuth
  or a token), stored like GitHub tokens, and their threads' agents get them
  through the bridge, the same way the Slack tools work. The bridge holds the
  credential. The sandbox only ever sees the bridge.

The Home is rebuilt on each open, and pushed again when the person connects
or disconnects. Spend is kept in memory by the proxy today and resets when
the bridge restarts. Keeping it across restarts means a small table in the
store.

## Setup

One GitHub App in the charmbracelet org, made by an org admin:

- device flow on; no callback URL needed
- user authorization with expiring tokens
- repository permissions: contents read/write, pull requests read/write,
  metadata read
- installed on the repos the agent may work in

The bridge gets `CRUSHLING_GITHUB_CLIENT_ID` (and optionally
`CRUSHLING_GITHUB_CLIENT_SECRET`, to revoke on disconnect). An app token
for unconnected GraphQL reads would add `CRUSHLING_GITHUB_APP_ID` and
`CRUSHLING_GITHUB_PRIVATE_KEY`. Sandboxes need the image's `gh` wrapper and
socat. The Slack app's
manifest turns on `home_tab_enabled`.

## Order of work

Each step is usable on its own:

1. **App Home and connecting.** Done. The Home (GitHub section and stats), device
   flow, token storage and refresh, `!github connect`/`disconnect`.
2. **Reads through the bridge.** Done: the git proxy's upload-pack, the
   read-only `gh` wrapper. Private clones and PR reviews work.
3. **Fenced pushes.** Done: receive-pack with the ref checks.
4. **Staged PRs.** `propose_pr` and the card.
5. **Later: MCP servers** in the App Home.

## Open questions

- Should a connection have an optional expiry (say 30 days, then reconnect)?
- Should a repo's maintainers be able to turn the agent off for that repo,
  beyond uninstalling the app?
- Is `crushling/*` the right branch prefix, or `crushling/<user>/*`?
