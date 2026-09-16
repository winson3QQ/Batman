# Design: OpenTAKServer deployment networking on the node

Status: **PASS-WITH-CHANGES (review R2)** — design decided; implementation gated on the
on-node evidence below (prototype on manet01) · Issue: #162 · relates: #98, #81
Date: 2026-09-16

## Context

Deploying a TAK server is a required capability; OpenTAKServer (OTS) replaces the
retired FTS. OTS is a **multi-service** stack (API, cot_parser, eud_handler ×2,
rabbitmq, postgis, optional nginx/webui/mediamtx). The footprint spike proved it runs
on an 8 GB Pi4 (~620 MiB idle) but exposed **networking** as the deployment blocker.
This document decides how OTS's containers network on our OpenWrt mesh node.

### On-node facts (measured 2026-09-16, manet01 = release + docker + memcg)

- Firewall is **fw4 (nftables)**: `table inet fw4`. Zones: **lan, wan, ahwlan** (ahwlan
  = HaLow mesh AP, `br-ahwlan`, `input=ACCEPT`). Docker's chains live in **separate** nft
  tables (`ip filter`, `ip nat`) created by dockerd, running at the **same hooks** as
  `inet fw4` and adjudicating every packet independently; a `drop` in *any* table at a
  hook is final.
- **Datapath / zones:** `batmesh0 → bat0 → br-ahwlan`. **`bat0` is a bridge-port of
  `br-ahwlan`** with no L3 identity and no zone of its own — so mesh peers, HaLow-AP
  clients, and wired clients **all present to fw4 as source zone `ahwlan`.** There is no
  separate "bat0 source".
- **Why bridge traffic is dropped today:** `kmod-br-netfilter` is installed on purpose
  (`feed/batman-payload-host/Makefile:63`); with `bridge-nf-call-iptables=1`, intra-bridge
  L2 frames traverse the fw4 FORWARD hook, and the docker bridge is in no zone → default
  `drop`. (Empirically all cross-container TCP was refused.)
- **Host ports taken:** openmanetd 8080/8081/8087; uhttpd 80/443. **Free:** 8088/8089/8443/8446/8883.
- OTS API 8081 is **container-loopback-only** upstream (nginx fronts it).
- **In-repo precedents:** FTS runs `--network host` **with remapped ports**
  (`deploy/fts/run.sh`: 18087/8089/8443/19023/5000) — host-net works via remap, rejected
  below on isolation grounds. `meshpoint-1.8.0.sh:131-144` creates the `ahwlan` zone via
  `uci add firewall zone` (idempotent, committed) — the pattern the docker zone follows.

## Requirements

1. OTS's 6+ containers reach each other (API↔postgis↔rabbitmq↔parsers).
2. **ATAK/iTAK clients reach the EUD CoT listeners** (TCP 8088, SSL 8089). Clients arrive
   via the **ahwlan zone** (wired, HaLow-AP, or batman mesh — all fold into `br-ahwlan`).
3. Admin web UI reachable on a non-colliding host port.
4. **Blast-radius:** a compromised payload container must not reach the host control plane
   (openmanetd 8081/8080/8087, dropbear:22, uhttpd) or the mesh; the docker subnet must
   not leak into the mesh.
5. Survive cold reboot and our provisioning/sysupgrade.
6. Preserve per-service netns for the hardening line (#98).

## Alternatives

### A. host networking (what FTS does)
All containers share the host netns; remap colliding ports (FTS proves this works).
**Rejected on isolation grounds:** it collapses every OTS service into the host netns →
no per-service network isolation → weakens #98. (Port collisions are secondary; the
"do all `ots_*` bind 8081?" question is settled by the `ss -ltnp` evidence below.)

### B. bridge + docker iptables disabled + fw4-native rules  ← recommended
Topology = a fixed-name bridge `br-ots` (subnet `172.20.0.0/24`), each container in its
own netns (satisfies #98). Rule plane = **single, auditable table**: set
`"iptables": false` in `daemon.json` so dockerd creates **no** `ip nat`/`ip filter`
tables, and author everything in `inet fw4`.

- **We do NOT use docker `-p` / compose `ports:`** — publishing is fw4 DNAT only.
  (Under `iptables=false`, `docker-proxy` is never spawned and `userland-proxy` is N/A;
  a compose `ports:` entry would silently do nothing, so it must be omitted.)
- **DNAT-publish only the external listeners:** host `8088→172.20.0.x:8088` (EUD TCP),
  `8089→…:8089` (EUD SSL), `8443→…:443` (web UI; 80/443 are taken). **API 8081 is not
  published** → bridge-internal, never touches host 8081, collision gone by construction.
- **Zone `dockert`** bound to `br-ots`:
  - `input=DROP` + `ct state established,related accept` — blocks container→host **new**
    connections (protects openmanetd/dropbear/uhttpd); returns still flow.
  - `forward` to lan/wan/ahwlan = **DROP** (no docker→mesh leak).
  - **one narrow inbound allow:** `ahwlan → dockert` permitted **only** to dports
    8088/8089/8443. With pure DNAT the client packet becomes a routed **FORWARD** into the
    zone; without this, ATAK cannot connect. (This is the *only* inbound exception.)
- **East-west** container↔container: choose one, validate on-node —
  (i) add an fw4 rule accepting intra-`br-ots` forward and **leave
  `bridge-nf-call-iptables=1`** (avoids touching a global sysctl the mesh bridges share),
  or (ii) set `bridge-nf-call-iptables=0` (removes br-ots east-west from fw4) — but this
  is **global** (also affects `br-ahwlan`/`br-lan`), so it requires (a) confirming no mesh
  bridge rule depends on bridge-level netfilter and (b) reasserting it after `br_netfilter`
  (re)loads. **Prefer (i)** unless (ii) proves necessary.

**Why over layering a zone on docker's own tables (old Alt C):** with `iptables=false`
the node's entire security posture is one `nft list table inet fw4`; nothing docker does
out-of-band mutates a second table, and — importantly — **the R1 reboot-ordering race
disappears**: `fw4 reload` fully owns the ruleset, only bridge *existence* timing remains.

### C. bridge + fw4 zone layered over docker's live iptables tables
v1 recommendation. Rejected: docker keeps mutating `ip nat`/`ip filter` at the same hooks
→ split auditability + ordering races. B dominates.

### D. hybrid (bridge internal + host-net EUD)
Rejected: mixed netns, still needs the bridge rules, host-net EUD may re-bind 8081.

## Verdict

**Adopt B.** Bridge for per-netns isolation (#98); `iptables=false` so docker manages no
nftables; publish 8088/8089/8443 via **fw4 DNAT** (no docker `-p`); API bridge-internal;
zone `dockert` `input=DROP`+established-only with `forward` denied to mesh and one narrow
`ahwlan→dport` allow; east-west via fw4 intra-bridge accept (preferred) or global
`bnf-call=0` (fallback, with the caveats above). Implement as a uci-default (`99-…`)
mirroring `meshpoint-1.8.0.sh`, with a `hotplug.d`/oneshot `fw4 reload` (and any
`bnf-call` reassertion) after `br-ots` appears (dockerd START=99 > firewall START=19).
Prototype on **manet01** (recoverable) before manet02.

## Open questions / to confirm during prototype
1. **Web UI internals:** does OTS's nginx hard-depend on 80/443 internally (Host headers,
   redirects, cert-enrollment 8446) such that host-DNAT to 8443 breaks client URLs?
2. **DNS:** container name resolution uses docker's 127.0.0.11 embedded resolver — confirm
   it isn't shadowed by the node's dnsmasq/umdns.
3. **Optional services:** settle whether nginx/webui/mediamtx run *before* fixing the rule
   set (mediamtx needs RTP/RTSP/WebRTC ranges → changes the publish list).
4. **Restart storm:** postgis/rabbitmq slow first-boot + `restart: unless-stopped` workers
   vs Pi4 CPU during mesh bring-up — gate with healthchecks/backoff.

## Deferred (non-blocking)
- non-root volume chown to uid 1024 + rabbitmq `--user rabbitmq` cookie (solved in spike).
- postgis/rabbitmq data volumes on `/opt/batdata` (p6).
- Baking the OTS arm64 payload into the payload-host image (v2.0, cf. #159).
- `deploy/ots/README.md`: fw3→fw4 wording corrected; its port table still to gain the
  "every `ots_*` role also opens 8081 in-container" note once the `ss -ltnp` evidence lands.

## On-node evidence to clear PASS-WITH-CHANGES (prototype on manet01)
1. `nft list ruleset` before (fw4 + docker `ip nat`/`ip filter`) and after `iptables=false`
   (single `inet fw4` table) — proves auditability + that docker installs no chains.
2. A real ATAK/`nc` connect from an **ahwlan client** to 8088 and 8089 through the
   hand-authored DNAT + FORWARD allow (not a localhost test).
3. `ss -ltnp` inside each `ots_*` container — settles the 8081 question, feeds the README fix.
4. `net.ipv4.ip_forward`=1 and (if used) `net.bridge.bridge-nf-call-iptables`=0 verified
   **after a full cold reboot** (not just `sysctl -w`) — proves survival of module-load order.
5. Negative test: from inside a container, attempt openmanetd `:8081` and dropbear `:22` on
   the host gateway — must be refused by `input=DROP` (proves the blast-radius rule loads).
