# kloe sandboxing, mapped for crushling

Source: read-only survey of ~/code/personal/kloe and ~/dots. Citations are file:line.

## Gaps to close before reuse

1. Network: kloe uses the unfiltered `bridge` network. Sandboxes reach the internet, the
   tailnet (SNAT'd as prattle), campus 10.40/16 and 163.11/16 via gp-gateway, the LAN, and
   prattle's own open ports via 172.17.0.1. Nothing on prattle filters container egress.
2. Secrets: kloe passes no env into containers. crush server needs provider keys, which is
   a new trust decision. (Settled: inference goes through the bridge's proxy and the
   sandbox only holds a per-thread token; see `docs/sandbox.md`.)
3. Unix socket: gVisor blocks host UDS through mounts by default, and needs a runtime
   entry with `--host-uds=create`. (No longer needed: crush now dials out to the bridge
   with `crush server --dial`, so plain `runsc` and no socket mount; see
   `docs/sandbox.md`.)

## Launch (kloe/src/executor.ts:631-646)

Docker (not podman), driven over `DOCKER_HOST=ssh://kloe@prattle` from terebithia.
crushling runs on prattle directly, next to the docker it drives.

```
docker run -d --name kloe-sbx-<key> --label kloe-sandbox=1 --label kloe-policy=<hash> \
  --runtime runsc --network bridge \
  --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add FSETID \
  --cap-add SETGID --cap-add SETUID --security-opt no-new-privileges \
  --cpus 1 --memory 512m --pids-limit 512 --workdir /workspace \
  -v /storage/kloe/workspaces/<key>:/workspace <image> sh -c '... exec tail -f /dev/null'
```

- runsc registered at dots/machines/prattle/default.nix:679-689 (time-namespaces = false).
- Container runs as root; no userns. (crushling runs it as the bridge's uid instead.)
- Image is a Docker Hub tag (buildpack-deps:bookworm-scm), not a Nix derivation.
- Policy label hash: mismatch forces rm and recreate (executor.ts:437-446).

## Lifecycle

| Tier | State | Trigger |
|---|---|---|
| hot | running | first use |
| warm | `docker stop -t 2` | idle 10 min (evictIdle :738, sweepUnclaimed :490) |
| cold | `docker rm -f`, workspace kept | stopped 30 d, or > 50 dormant |
| reaped | workspace deleted | hourly sweep, mtime > ttl and no container |

60 s unref'd interval drives the sweeps (:405-411).

## Proposed egress filter (iptables, not nftables: docker owns iptables)

Dedicated network `sbx-egress` (172.30.0.0/24, bridge `br-sbx`), created by a oneshot
(pattern from modules/nixos/services/cap.nix:122-126). Then:

```
iptables -I nixos-fw 1 -i br-sbx -j nixos-fw-refuse
iptables -N SBX-EGRESS || iptables -F SBX-EGRESS
iptables -A SBX-EGRESS -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 \
           163.11.0.0/16 127.0.0.0/8 224.0.0.0/4; do
  iptables -A SBX-EGRESS -d $net -j REJECT
done
iptables -A SBX-EGRESS -o tailscale0 -j REJECT
iptables -A SBX-EGRESS -p udp --dport 53 -j RETURN
iptables -A SBX-EGRESS -p tcp -m multiport --dports 53,80,443 -j RETURN
iptables -A SBX-EGRESS -j REJECT
iptables -I DOCKER-USER 1 -i br-sbx -j SBX-EGRESS
```

Untested caveats: DOCKER-USER ordering vs nixos-fw start (maybe a oneshot After=docker),
embedded DNS 127.0.0.11 behavior, IPv6. kloe can adopt the same network via
`sandbox.dockerNetwork`.

## Secrets

Done as a host-side LLM proxy on the bridge's sandbox port (`/proxy/<thread>`): crush gets
`HYPER_URL` and a per-thread token as `HYPER_API_KEY`, and the org's key never enters the
sandbox.

## dots wiring

- mkService at dots/modules/lib/mkService.nix:24-41; example kloe.nix:42-89.
  Auto-imported by import-tree, so modules/nixos/services/crushling.nix is picked up.
- ProtectSystem=strict: add ReadWritePaths for /storage/crushling (the tunnels' sockets
  live under it); docker-client on the unit path.
- Pin uid/gid (prattle:222-232), add docker group (root-equivalent), caddy.enable = false
  (Socket Mode needs no vhost), RequiresMountsFor = /storage.
- tmpfiles: `d /storage/crushling 0755 root root -`, `d /storage/crushling/workspaces 0711 root root -`.
- autoPrune: add `"--filter" "label!=crushling-sandbox=1"` (prattle:711-714).
- Backup: atelier.backup.services.crushling.paths = [ "/storage/crushling/workspaces" ].
- Agenix: secrets.nix entry, age.secrets.crushling with owner, secretsFile.
- Stale comment at prattle:214 says kata; it's gVisor.

## crushling's sandbox port

The bridge serves everything a sandbox needs on one port: the tunnel its crush dials, the
inference proxy, and the Slack tools. To let sandboxes reach it and nothing else on the
host, bind the bridge to the network's gateway and allow only that port, ahead of the
refuse rule:

    iptables -I nixos-fw 1 -i br-sbx -d 172.30.0.1 -p tcp --dport 7469 -j nixos-fw-accept

with `CRUSHLING_BRIDGE_BIND=172.30.0.1` and
`CRUSHLING_BRIDGE_URL=http://172.30.0.1:7469`. Each thread's endpoints need that
thread's tokens, so one sandbox can't act for another.
