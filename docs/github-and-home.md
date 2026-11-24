# GitHub access and the App Home

A design, not yet built. It lets people delegate GitHub work to the agent:
read private repos, push branches, and stage pull requests that a person
opens from Slack. It also adds an App Home where each person manages their
connection and sees what crushling is doing.

## Decisions

- **The agent acts as the person who asked.** Each person connects their
  GitHub account once. The agent uses their token, so it can never reach
  more than they can, and GitHub shows the work as "<person> via crushling".
  A token for the app itself (`crushling[bot]`) is only for reading public
  repos when nobody has connected.
- **Grants are standing.** A connected person's threads use their
  connection without asking each time. That is safe because the token is
  theirs: "standing" means "the agent can do what you could do", never more.
- **The sandbox never holds a token.** Git and `gh` go through the bridge,
  which adds the token. Nothing in the sandbox can read it or send it
  elsewhere.
- **Pushes are fenced.** The bridge refuses pushes to anything but
  `crushling/*` branches, branch deletions and force pushes. `main` and other
  people's branches can't be touched, even by a misbehaving agent.
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
report) keeps the last sender. If they haven't connected:

- public repos still clone and read (through the app's own token);
- anything else fails with a clear message to the agent, and the person gets
  an ephemeral "connect GitHub so I can do this" with a button.

## Git through the bridge

The sandbox image sets:

    git config --system url."http://172.30.0.1:7469/git/".insteadOf https://github.com/

so every `git clone/fetch/push` of a GitHub URL goes to the bridge's
`/git/<thread>/...` route, authenticated with the thread's existing bridge
token. The bridge forwards to GitHub with the person's token:

- **upload-pack** (clone, fetch): passed through as is.
- **receive-pack** (push): the bridge reads the pkt-line command list at the
  start of the request, and refuses the push unless every ref is
  `refs/heads/crushling/*`, none is a deletion, and none is a force push (the
  old id must match what GitHub has). Only then is the request streamed on.
- **LFS**: refused at first. Rarely needed by the agent.

## `gh` through the bridge

A `gh` wrapper in the image sends the read-only commands (`pr view`,
`pr diff`, `pr checks`, `issue view`, `repo view`, `api` GETs) through the
bridge's `/github/<thread>/` route, which adds the token. Everything else,
including `gh auth login` and any write, is refused with a pointer to
`propose_pr`. This alone would have made the #hyper review of a private PR
work.

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

The bridge gets `CRUSHLING_GITHUB_CLIENT_ID`, plus `CRUSHLING_GITHUB_APP_ID`
and `CRUSHLING_GITHUB_PRIVATE_KEY` for the app's own token. The Slack app's
manifest turns on `home_tab_enabled`.

## Order of work

Each step is usable on its own:

1. **App Home and connecting.** The Home (GitHub section and stats), device
   flow, token storage and refresh, `!github connect`/`disconnect`.
2. **Reads through the bridge.** The git proxy's upload-pack, the read-only
   `gh` wrapper. Private clones and PR reviews work.
3. **Fenced pushes.** receive-pack with the ref checks.
4. **Staged PRs.** `propose_pr` and the card.
5. **Later: MCP servers** in the App Home.

## Open questions

- Should a connection have an optional expiry (say 30 days, then reconnect)?
- Should a repo's maintainers be able to turn the agent off for that repo,
  beyond uninstalling the app?
- Is `crushling/*` the right branch prefix, or `crushling/<user>/*`?
