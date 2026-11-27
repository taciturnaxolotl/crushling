# Sandboxes: runtime, network, image

How a `docker` sandbox is wired, and what the host (prattle, configured in
`~/dots`) must provide. The bridge's side is `crushling/launcher` and
`crushling/sandbox`.

## What a sandbox runs

The bridge drives the Docker Engine API on its unix socket
(`/var/run/docker.sock`, or `DOCKER_HOST=unix://...`), not the docker CLI.
The container it creates is what this would make:

    docker run --detach --name crushling-<thread> \
      --runtime runsc --network <CRUSHLING_NETWORK> --user <uid>:<gid> \
      --cap-drop ALL --security-opt no-new-privileges ... \
      --volume <root>/<thread>/work:/workspace \
      --env CRUSHLING_THREAD=... --env CRUSHLING_MCP_TOKEN=... \
      --env CRUSH_SERVER_DIAL_TOKEN=... \
      --env HYPER_URL=<bridge>/proxy/<thread> --env HYPER_API_KEY=<thread token> \
      <image> crush server --dial ws://<bridge>/tunnel/<thread>

- crush connects out to the bridge; nothing listens in the sandbox and
  nothing but the workspace is mounted (plus `CRUSHLING_CRUSH` and the
  resolv.conf when set). Plain `runsc` will do: the `runsc-uds` runtime with
  `--host-uds=create` is no longer needed.
- `HYPER_API_KEY` is a token for this thread only. The org's key stays on
  the bridge. The sandbox never gets `CRUSH_HYPER_API_KEY` or
  `CRUSH_HYPER_URL`: crush lets `CRUSH_<NAME>` override `<NAME>`, even
  when empty. For the same reason the sandbox image must not define any
  `CRUSH_HYPER_*` variable (no `ENV CRUSH_HYPER_...` in its config), or it
  would take Hyper around the proxy or break it.
- A thread's tokens are derived from its key, so the same token comes back
  each time the thread's agent is launched. The proxy only takes a
  thread's token while its agent is up: a launch allows it, a stop or a
  failed launch disallows it, and after a restart no token works until its
  agent is launched again. That's fine, because the token only ever lives
  inside that thread's own sandbox and workspace.
- Containers carry a fingerprint label of their policy, which now includes
  the dial transport and the bridge URL, so containers made for the old unix
  socket transport are removed and recreated on their next launch.

## Launch and stop

A launch prepares the thread's directories, opens its tunnel, allows its
proxy token, starts (or adopts) the container and waits for crush to dial
in. If any step after opening the tunnel fails, the launch stops the
container (even when docker reported failure: a timed-out call doesn't
prove the container didn't start), closes the tunnel and disallows the
token. Anything that cleanup couldn't undo is logged and added to the
launch's error. A stop says bye, stops the container, closes the tunnel
and disallows the token. Tokens travel only in request bodies, so docker's
errors never carry them. The launch is written once (`crushling/launcher`)
against a small backend (`crushling/agent/backend`: docker or local), and
what crush is given is built in one place (`crushling/agent/spec`).

One actor (`crushling/agents`) owns every thread's lifecycle: each key is
`Absent`, `Starting`, `Live`, `Stopping` or `Forgetting`, and its
launches, stops, forgets and rekeys run one at a time, in order. Shutdown
waits for launches in flight before it stops their agents. When the bridge
starts, sandboxes a previous bridge left running are stopped rather than
adopted: no registry knows their threads, and the next message starts them
again, warm.

## Network

Everything a sandbox needs from the bridge is on one port, the sandbox
server's (`CRUSHLING_BRIDGE_PORT`, default 7469): its tunnel, the inference
proxy and the Slack tools. So the only rule for traffic from the sandbox
network to the host is "allow that port": bind the bridge to the network's
gateway and let only that port through, ahead of a refuse rule:

    iptables -I nixos-fw 1 -i <bridge-if> -j nixos-fw-refuse
    iptables -I nixos-fw 1 -i <bridge-if> -p tcp --dport 7469 -j nixos-fw-accept

with

    CRUSHLING_BRIDGE_BIND=<gateway>
    CRUSHLING_BRIDGE_URL=http://<gateway>:7469

Forwarded egress (the internet, minus private ranges, the tailnet and
campus) is unchanged: agents still clone repositories and install packages.
Inference no longer needs it, since it goes through the proxy.

## Changes needed in `~/dots`

`modules/nixos/services/crushling.nix` and `machines/prattle/default.nix`
describe the old transport. Not changed from this repository; what has to
change there:

1. Drop the `virtualisation.docker.daemon.settings.runtimes.runsc-uds` block
   and set `CRUSHLING_RUNTIME = "runsc"` (or leave it unset: `runsc` is the
   default). prattle already registers `runsc` for kloe
   (`machines/prattle/default.nix`, the gVisor section).
2. Rename the environment to the new names (the old ones still work):
   `CRUSHLING_MCP_BIND` → `CRUSHLING_BRIDGE_BIND`, `CRUSHLING_MCP_PORT` →
   `CRUSHLING_BRIDGE_PORT`, `CRUSHLING_MCP_URL` → `CRUSHLING_BRIDGE_URL`.
   The values stay the gateway and `cfg.port`.
3. The firewall rules in `networking.firewall.extraCommands` already allow
   only `cfg.port` from `br-crushling` and refuse the rest, which is now
   exactly right: tunnel, proxy and Slack tools share that port. Only their
   comment ("the sandboxes reach the Slack tools and nothing else here")
   should say the bridge port. The `CRUSHLING-EGRESS` chain is unchanged.
4. Secrets (`crushling.age`): add `CRUSHLING_HYPER_KEY` (required, or
   `HYPER_API_KEY`; the bridge won't start without one). The proxy goes to
   `https://hyper.charm.land` unless `CRUSHLING_PROXY_UPSTREAM` or
   `HYPER_URL` says otherwise. Remove `CRUSHLING_BACKEND`,
   `CRUSHLING_LOGIN`, `CRUSHLING_EXTRA_BACKENDS` and
   `CRUSHLING_CLAUDE_VERSION`, which are no longer read.
   (`CRUSH_HYPER_API_KEY` is still read as a last fallback for the key.) Optionally set the
   caps (`CRUSHLING_PROXY_THREAD_CAP_USD`, ...).
5. `data.files` can drop `${cfg.dataDir}/.local/state/crushling`: there are
   no logins any more.
6. `crushBinary` must be a crush with `--dial` and resumable event streams
   (below).
7. Comments that say the bridge must share a filesystem with the sandbox
   because of the unix socket (the module's header and the
   `atelier.services.crushling` comment in `machines/prattle/default.nix`)
   are stale. The bridge drives the local Docker Engine socket, so it stays
   on prattle, and its user needs access to that socket.
8. `threadsDir` (`/storage/crushling/threads`) is well under the 79-byte
   limit the tunnels' socket paths put on `CRUSHLING_ROOT`.

## crush in the image

The sandbox's crush must support `crush server --dial` and resumable event
streams (`Last-Event-ID`). Until upstream releases them, build it from the
megamerge in `~/code/charm/crush-mm`. The dev binary at
`~/.local/state/crushling-dev/crush` is a darwin build, for the `local`
launcher and the real tests only; a sandbox needs a static linux one:

    cd ~/code/charm/crush-mm
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /tmp/crush-linux-amd64 .
    # GOARCH=arm64 for an arm64 host

Then either:

- mount it (what prattle does): copy it to the host and rename it over
  `CRUSHLING_CRUSH` (`crushBinary`, default `<dataDir>/bin/crush`):

      scp /tmp/crush-linux-amd64 prattle:/tmp/crush
      ssh prattle 'sudo install -o crushling -m 0755 /tmp/crush /var/lib/crushling/bin/crush.new &&
                   sudo mv /var/lib/crushling/bin/crush.new /var/lib/crushling/bin/crush'

  (adjust the path to `crushBinary`). A new binary changes the fingerprint,
  so each sandbox is recreated with it on its next launch; or
- bake it into the image as `/usr/local/bin/crush` (e.g. in the
  `extraCommands` of the nix image, from a derivation that builds the same
  source), and leave `CRUSHLING_CRUSH` unset.

Nothing is pushed or published from this repository.
