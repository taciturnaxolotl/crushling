# kloe sandboxing, mapped for crushling

Source: read-only survey of ~/code/personal/kloe and ~/dots. Citations are file:line.

## Gaps to close before reuse

1. Network: kloe uses the unfiltered `bridge` network. Sandboxes reach the internet, the
   tailnet (SNAT'd as prattle), campus 10.40/16 and 163.11/16 via gp-gateway, the LAN, and
   prattle's own open ports via 172.17.0.1. Nothing on prattle filters container egress.
2. Secrets: kloe passes no env into containers. crush server needs provider keys, which is
   a new trust decision.
3. Unix socket: gVisor blocks host UDS through mounts by default. Needs a runtime entry with
   `--host-uds=create` (or `all`). kloe never does this. Verify against packaged gvisor.

## Launch (kloe/src/executor.ts:631-646)

Docker (not podman), driven over `DOCKER_HOST=ssh://kloe@prattle` from terebithia.
crushling should run on prattle directly so the socket is local.

```
docker run -d --name kloe-sbx-<key> --label kloe-sandbox=1 --label kloe-policy=<hash> \
  --runtime runsc --network bridge \
  --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add FSETID \
  --cap-add SETGID --cap-add SETUID --security-opt no-new-privileges \
  --cpus 1 --memory 512m --pids-limit 512 --workdir /workspace \
  -v /storage/kloe/workspaces/<key>:/workspace <image> sh -c '... exec tail -f /dev/null'
```

- runsc registered at dots/machines/prattle/default.nix:679-689 (time-namespaces = false).
- Container runs as root; no userns. Socket needs a chmod for the host user.
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

Preferred: host-side LLM proxy reached over a second mounted socket; crush gets a dummy key
and a base_url. Keys never enter the sandbox. Fallback: `--env-file` with a spend-capped key.

## dots wiring

- mkService at dots/modules/lib/mkService.nix:24-41; example kloe.nix:42-89.
  Auto-imported by import-tree, so modules/nixos/services/crushling.nix is picked up.
- ProtectSystem=strict: add ReadWritePaths for /storage/crushling and the socket dir;
  docker-client on the unit path.
- Pin uid/gid (prattle:222-232), add docker group (root-equivalent), caddy.enable = false
  (Socket Mode needs no vhost), RequiresMountsFor = /storage.
- tmpfiles: `d /storage/crushling 0755 root root -`, `d /storage/crushling/workspaces 0711 root root -`.
- autoPrune: add `"--filter" "label!=crushling-sandbox=1"` (prattle:711-714).
- Backup: atelier.backup.services.crushling.paths = [ "/storage/crushling/workspaces" ].
- Agenix: secrets.nix entry, age.secrets.crushling with owner, secretsFile.
- Stale comment at prattle:214 says kata; it's gVisor.
