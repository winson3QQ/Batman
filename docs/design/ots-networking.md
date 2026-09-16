# Design: OpenTAKServer deployment networking on the node

Status: **draft v2 — addresses review R1 (needs re-review before implementation)** · Issue: #162 · relates: #98, #81
Date: 2026-09-16

## Context

Deploying a TAK server is a required capability; OpenTAKServer (OTS) replaces the
retired FTS. OTS is a **multi-service** stack (API, cot_parser, eud_handler ×2,
rabbitmq, postgis, optional nginx/webui/mediamtx). The footprint spike proved it runs
on an 8 GB Pi4 (~620 MiB idle) but exposed **networking** as the deployment blocker.
This document decides how OTS's containers network on our OpenWrt mesh node.

### On-node facts (measured 2026-09-16, manet01 = release + docker + memcg)

- Firewall is **fw4 (nftables)**: `table inet fw4`. Zones: **lan, wan, ahwlan** (ahwlan
  = HaLow mesh AP, `br-ahwlan`, `input=ACCEPT` per `meshpoint-1.8.0.sh`). Docker's chains
  live in **separate** nft tables (`ip filter`, `ip nat` via iptables-nft) created by
  dockerd — they run at the **same hooks** as `inet fw4` and adjudicate every packet
  independently. A `drop` in *any* table at a hook is final.
- **Why bridge traffic is dropped today:** `kmod-br-netfilter` is installed on purpose
  (`feed/batman-payload-host/Makefile:63`). With `bridge-nf-call-iptables=1`, intra-bridge
  L2 frames are pushed through the fw4 **FORWARD** hook; the docker bridge is in no fw4
  zone → fw4's default `drop` kills them. (Empirically: postgis/rabbitmq/eud all refused.)
- **Host ports taken:** openmanetd 8080/8081/8087; uhttpd 80/443. **Free:** 8088/8089/8443/8446/8883.
- OTS API 8081 is **container-loopback-only** in upstream compose (nginx fronts it).
- **In-repo precedents (reuse, don't reinvent):**
  - FTS runs on `--network host` **with remapped ports** (`deploy/fts/run.sh`: CoT 18087,
    SSL 8089, HTTPS 8443, REST 19023, UI 5000) to dodge openmanetd — so host-net *is*
    workable via remap; it is rejected below on isolation grounds, not port grounds.
  - `meshpoint-1.8.0.sh:131-144` creates the `ahwlan` fw zone via `uci add firewall zone`
    with an idempotent guard, committed to `/etc/config/firewall` — the pattern the docker
    zone must follow (as a numbered uci-default, cf. `99-batman-payload-docker`).

## Requirements

1. OTS's 6+ containers reach each other (API↔postgis↔rabbitmq↔parsers).
2. **ATAK/iTAK clients (phones on `ahwlan`, and peers over `bat0`) reach the EUD CoT
   listeners** (TCP 8088, SSL 8089). ← the primary externally-reachable surface.
3. Admin web UI reachable on some non-colliding host port.
4. **Blast-radius:** a compromised payload container must not reach the host control
   plane (openmanetd 8081/8080/8087, dropbear, uhttpd) or the mesh (`bat0`/ahwlan peers);
   the docker subnet must not leak into the mesh.
5. Survive cold reboot and our provisioning/sysupgrade.
6. Preserve per-service netns for the hardening line (#98).

## Alternatives

### A. host networking (what FTS does)
All containers share the host netns; talk over `localhost`; remap colliding ports (FTS
proves this works). **Rejected — for the right reason:** it collapses every OTS service
into the host netns, so there is **no per-service network isolation** → directly weakens
#98 (can't give each tenant its own netns / can't scope east-west traffic). Port
collisions are a *secondary* nuisance (and the "all ots_* bind 8081" question is settled
by attaching the spike's `ss -ltnp`, see Evidence). Isolation, not ports, is why A loses.

### B. user-defined bridge, rules authored fw4-native with docker's iptables disabled  ← recommended
Topology = a fixed-name docker bridge `br-ots` (fixed subnet `172.20.0.0/24`), giving
every container its own netns (satisfies #98). **Rule plane = single-table, fw4-native**:
set `"iptables": false` in `daemon.json` so dockerd does **not** create/mutate its own
`ip nat`/`ip filter` tables, and author all of it in `inet fw4`:
- **DNAT (publish) only the external listeners:** EUD 8088→8088, EUD-SSL 8089→8089, web
  443→**8443** (80/443 taken). API 8081 is **not** published (bridge-internal → never
  touches host 8081, so the collision is gone by construction).
- **Masquerade** the br-ots subnet egress that we explicitly allow (none, by default).
- **A dedicated fw4 zone `dockert`** bound to `br-ots` with:
  - `input=DROP` + `ct state established,related accept` — **blocks container→host new
    connections** (protects openmanetd/dropbear/uhttpd); return traffic still flows.
  - `forward` to lan/wan/ahwlan = **DROP** (no docker→mesh leak).
  - **one narrow inbound allow** for reachability: `ahwlan → br-ots` (and `bat0` path,
    see req 2) permitted **only** to dports 8088/8089/8443 — because with pure DNAT the
    client's packet becomes a FORWARD into the zone; without this, ATAK cannot connect.
- **Intra-bridge** container-to-container: set `net.bridge.bridge-nf-call-iptables=0` so
  east-west stays pure L2 and does not traverse fw4 at all (removes the br-netfilter
  drop; container isolation is still enforced by docker's own bridge, and inter-container
  policy—if wanted—can be added later).

**Why this over a plain "add a zone on top of docker's tables":** on a mesh-critical node
the whole security posture must be auditable in **one ruleset** (`nft list table inet
fw4`). Leaving docker to mutate a second `ip nat`/`ip filter` table on every
`docker network`/container event means the node's effective policy is split across tables
that change out-of-band — and the DNAT/masquerade docker inserts can bypass intent. Cost:
three hand-maintained DNAT rules. Worth it here.

### C. plain bridge + fw4 zone layered over docker's live iptables tables
The v1 recommendation. Rejected: docker keeps mutating `ip nat`/`ip filter` at the same
hooks, so the zone is not the whole story, ordering races with docker's chain
re-insertion, and auditability is split. B (iptables=false) dominates it.

### D. hybrid (bridge internal + host-net EUD only)
Rejected: mixed netns model, still needs the bridge rules, and host-net EUD handlers may
re-bind 8081 → same class of problem. No advantage over B.

## Verdict

**Adopt B: `br-ots` bridge for per-netns isolation (satisfies #98), but disable docker's
iptables and express DNAT-publish + zone isolation as fw4-native rules in a single
auditable ruleset.** Publish only 8088/8089/8443; keep API bridge-internal; docker zone
`input=DROP`+established-only; one narrow ahwlan/bat0→dport allow for client reachability;
`bridge-nf-call-iptables=0` for east-west.

Implement the zone + daemon.json + DNAT as a **uci-default** (`99-…`) mirroring
`meshpoint-1.8.0.sh`, and **reassert fw4 after dockerd** (dockerd START=99 > firewall
START=19, so `br-ots` doesn't exist at firewall time): a `hotplug.d`/oneshot that runs
`fw4 reload` once `br-ots` appears. Prototype on **manet01** (recoverable) before manet02.

## Open questions for re-review

1. `userland-proxy`: pin it explicitly. If **on**, published ports are reached via a
   host-INPUT `docker-proxy` listener (interacts with the "free ports" accounting and the
   `input=DROP` zone — the proxy runs in the host/root netns, not the docker zone); if
   **off** (pure DNAT), the ahwlan→dport FORWARD allow above is mandatory. Choose off +
   explicit DNAT for single-table clarity, and verify with a real ATAK/`nc` connect from
   an ahwlan client (not a localhost test).
2. Do CoT clients arrive over `ahwlan` (AP), `bat0` (mesh), or `lan`? The inbound allow
   must name the right source zone(s). Confirm the client attach path.
3. With `iptables=false`, confirm container **egress DNS/NTP/none** needs: a self-contained
   payload needs no egress; if any service needs upstream (it shouldn't on an edge node),
   that's an explicit masq+forward rule, not a default.
4. Container DNS: on a user bridge, containers use docker's 127.0.0.11 embedded resolver —
   confirm it isn't shadowed by the node's dnsmasq/umdns.
5. Settle **which optional services run** (nginx/webui/mediamtx) *before* fixing the rule
   set — mediamtx needs RTP/RTSP/WebRTC port ranges, changing the publish list materially.
6. Restart storm: `postgis`/`rabbitmq` slow first-boot + `restart: unless-stopped` on the
   `ots_*` workers can thunder against mesh bring-up for the Pi4 CPU — gate with
   healthchecks/backoff (cf. `deploy/fts/run.sh`).

## Deferred (non-blocking for this networking decision)
- non-root volume chown to uid 1024 + rabbitmq `--user rabbitmq` cookie — deploy-script
  details, solved in the spike.
- postgis/rabbitmq data volumes on `/opt/batdata` (p6) per storage architecture.
- Baking the OTS arm64 payload into the payload-host image (v2.0, cf. #159).

## Evidence to attach before implementation
- Spike `ss -ltnp` inside each `ots_*` container (settles whether they all bind 8081).
- `nft list ruleset` on the node showing the coexisting base chains (fw4 + docker) before,
  and the single-table result after `iptables=false`.
- A real client connect from an ahwlan device to 8088/8089 through the chosen rules.
