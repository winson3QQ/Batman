# Design: Payload framework — declarative, app-agnostic payload deployment

Status: **draft for design-review** · Parent epic: **#68** (generic payload host)
Relates: #97 (admission/trust), #98 (runtime hardening), #151 (safe app swap),
#153 (per-tenant profile spec), #155 (profile→flags), #156 (runtime owner),
#81 (resource budget), #119 (tenant layout), #116 (fleet OTA), #159 (docker-in-image),
#162 (OpenTAKServer = app #1). Date: 2026-09-16

## Why this doc exists

#68 sets the vision: the node is a **generic payload host** (HaLow+batman transport +
pluggable payload services; TAK is one tenant, "things" — drone/camera/SDR — come next).
The user has confirmed **"different apps later."** Today the enabling pieces are real but
scattered — a profile *spec* (#153), a profile→flags *emitter* (#155), a runtime-owner
*gap* (#156), a swap *operation* (#151), an admission *layer* (#97), and a freshly
**on-node-validated networking design** for OTS (docs/design/ots-networking.md, #164/#165).

Without a unifying contract, each new app risks a bespoke deploy (the OTS spike used
manual scp + hand-run `docker run` — explicitly *not* how a real app should ship). This
doc defines the **one thing that must not be app-specific**: a declarative **payload
descriptor** + an on-node **payload manager** that turns any descriptor into a running,
hardened, network-confined, reboot/reflash-surviving payload. "Different app later" then =
**write a descriptor**, not rewrite mechanism.

This is the mechanism/contract layer *under* #68 — it does not redefine #68's vision, nor
#97's trust policy (it *consumes* #97's admission verdict).

## The payload descriptor (extends #153's `profile.yaml`)

One declarative file per app, the single source of truth. #153 already owns the
**security** axes; this design adds the **networking** and **lifecycle** axes so one spec
drives everything:

```yaml
apiVersion: batman.payload/v1
name: opentakserver
images:                      # signed OCI refs (verified at admission, #97/#74)
  - ref: batman/ots:1.7.13-arm64        # digest-pinned in practice
    roles: [api, cot_parser, eud_handler, eud_handler_ssl]  # one image, N roles
  - ref: imresamu/postgis:18-3.6
  - ref: rabbitmq:4                      # --user rabbitmq
network:                     # -> generates the validated fw4-native rules (parameterized)
  bridge: { name: br-ots, subnet: 172.20.0.0/24 }
  publish:                   # fw4 DNAT (NO docker -p); source zone + host port -> container
    - { src_zone: ahwlan, host_port: 8088, to: eud_handler:8088, proto: tcp }
    - { src_zone: ahwlan, host_port: 8089, to: eud_handler:8089, proto: tcp }
    - { src_zone: ahwlan, host_port: 8443, to: nginx:443,        proto: tcp }
  isolation: { input: DROP, forward: intra-zone, egress: none }   # blast-radius default
security:                    # #153/#155 axes -> hardening flags
  archetype: network-service
  run_as: 1024
  cap_drop: ALL
  read_only: false           # per-app exceptions recorded here
  cpus: 1.0 ; memory: 512m ; pids: 512
resources: { ... }           # #81 budgets
volumes:                     # chowned to run_as uid on first create
  - { name: ots-appdata, path: /app/ots, chown: 1024 }
lifecycle:                   # init ordering, health, first-boot init, swap policy
  order: [ots-db, rabbitmq, ots, workers]
  init_once: ["flask ... db upgrade", "ots create-ca"]
  health: { ots: "curl -f localhost:8081/api/health" }
  restart: on-failure-backoff
```

## The payload manager (on-node contract)

A single, app-agnostic mechanism. Given a descriptor it runs this pipeline
(idempotent; each stage already has an owner issue):

1. **Admit** (#97) — verify image signatures + that this payload is authorized on this
   node class. On air-gapped nodes the trust anchor is the baked-in publisher key (#74/#13).
2. **Network** — generate the fw4-native rules from `network:` (the validated OTS design,
   parameterized): `dockerd iptables=0`, a per-app bridge, DNAT publish, a per-app fw4
   **zone** (`input=DROP`, intra-zone forward, no mesh forward), the narrow `src_zone→dport`
   allow. Installed as a uci-default (survives reboot/reflash), no post-docker reload
   needed (fw4 `iifname` is name-matched — proven on manet01).
3. **Harden** (#155/#98) — emit `<app>.hardening.env` from `security:`; enforce at run.
4. **Run under init** (#156) — **on OpenWrt the runtime owner is a generated `procd`
   service** (NOT a systemd Quadlet — the node has no systemd), so containers come up on
   boot and a hand-run `docker run` can't silently bypass the profile; `verify-profile.sh`
   is a periodic drift alarm.
5. **Lifecycle** (#151) — safe swap = signed-image verify + state-aware rollback (mirrors
   the A/B pattern, #89); budgets from #81.

Container↔container name resolution uses docker's embedded 127.0.0.11 resolver; volumes
live on `/opt/batdata` (p6).

## Delivery fronts sit ON TOP (decide per need; framework is delivery-agnostic)

All three end by handing a descriptor + images to the same manager:
- **Baked into the payload-host image** (#159) — for a *required* capability (e.g. TAK):
  flash & go, update via A/B OTA. No user deploy step.
- **On-device management UI** — for user-installed optional apps; the OpenWrt-native,
  industry-standard option is `luci-app-dockerman`-style, but curated to descriptors
  (verify + profile), not raw container management.
- **Fleet OTA push** (#116) — central controller pushes descriptors/images to a fleet
  (balena / IoT-Edge pattern), canary→staged, per-node status.

## OTS as instance #1 (#162)

OTS's descriptor = the validated networking (br-ots, iptables=0 fw4-native, DNAT
8088/8089/8443, `dockert` input=DROP) + a `network-service` security profile + the
volume-chown / rabbitmq `--user` / SSL-cert deploy notes. Proves the framework end-to-end;
delivered baked-in (required capability).

## Issue map (what each contributes / gap the framework fills)

| # | Role in framework | State |
|---|---|---|
| #68 | Epic — generic payload host (this doc is its mechanism) | epic, open |
| #153 | Descriptor **security** axes (schema) | merged (extended here with network/lifecycle) |
| #155 | Security → hardening-env emitter (Harden stage) | merged |
| #156 | Runtime owner = generated procd service (Run stage) | open — this design gives it its shape |
| #98 | The hardening flags/targets (feeds Harden) | open |
| #97 | Admission/trust (Admit stage) — prod-lock | open — framework consumes its verdict |
| #151 | Safe swap + rollback (Lifecycle stage) | open — becomes the manager's swap op |
| #81 | Resource budgets (descriptor `resources`) | open |
| #119 | Tenant layout (where per-app state lives) | — |
| #159 | Baked-in delivery front | merged |
| #116 | Fleet delivery front | open |
| #162 | App #1 (OTS) + validated networking | open (recipe/design merged) |

## Alternatives considered

- **Adopt a turnkey framework wholesale (balena / podman-Quadlets / k3s).** Quadlets need
  systemd — the node runs OpenWrt/**procd**, so they don't apply on-node. balena/k3s are
  heavy for a Pi4 mesh node and pull in a control-plane dependency we don't want on an
  air-gapped tactical device. We reuse the *pattern* (declarative descriptor → init-owned
  run) but the on-node owner is procd. **Rejected as a wholesale dependency; adopted as
  inspiration.**
- **Keep per-app bespoke deploys.** Rejected — the user will have different apps; this is
  the exact coupling we set out to avoid.
- **Fold networking into #98 instead of the descriptor.** Rejected — networking is
  per-app (ports/zones differ), so it belongs in the per-app descriptor next to security,
  not in the generic hardening issue.

## Boundaries / non-goals
- Not a new epic (that's #68); not re-specifying #97's trust policy (consumed, not defined).
- Not choosing the delivery UI/fleet now — only guaranteeing the manager is delivery-agnostic.
- Not a cloud control plane.

## Open questions for review
1. Descriptor ownership: extend #153's `profile.yaml` in place, or a new top-level
   `payload.yaml` that *embeds* the security profile? (Back-compat with #155's emitter.)
2. Multi-tenant fw4: N apps = N bridges/zones — does fw4/nftables scale cleanly, and how
   do per-app zones avoid cross-talk? (isolation between two payloads, not just payload↔mesh.)
3. procd vs a thin supervisor: can procd express dependency ordering + health-gated restart
   (lifecycle `order`/`health`) well enough, or is a small supervisor script needed?
4. Admission on air-gap: how does #97's verdict reach the manager with no controller —
   baked policy + publisher key only? What's revocable?
5. Swap atomicity (#151): descriptor+images updated together; how is a half-applied swap
   rolled back (A/B-style two-slot for payloads, or state-aware in place)?
6. Does baking OTS in (delivery front) vs the manager reading a descriptor at boot create
   two code paths, or is "baked-in" just a descriptor shipped in the image?
