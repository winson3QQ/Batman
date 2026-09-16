# Design: Payload framework — declarative, app-agnostic payload deployment

Status: **PASS-WITH-CHANGES (review R2)** — design approved modulo the on-node proofs in
*Implementation gate* (prove at first build on manet01). · Parent epic: **#68** (generic payload host)
Relates: #97 (admission/trust), #98 (runtime hardening), #151 (safe app swap),
#153 (per-tenant profile spec, CLOSED — mechanism merged as PR #155 + `docs/security-profiles.md`),
#156 (runtime owner), #81 (resource budget), #116 (fleet OTA), #159 (docker-in-image),
#162 (OpenTAKServer = app #1). Date: 2026-09-16

## Why this doc exists

#68 sets the vision: the node is a **generic payload host** (HaLow+batman transport +
pluggable payload services; TAK is one tenant, "things" — drone/camera/SDR — next). The
user has confirmed **"different apps later."** The enabling pieces are real but scattered —
a profile *spec* (#153, merged as PR #155), a profile→flags *emitter*
(`scripts/profile-to-flags.py`), a runtime-owner *gap* (#156), a swap *operation* (#151),
an admission *layer* (#97), and an **on-node-validated networking design** for OTS
(`docs/design/ots-networking.md`, #164/#165).

This doc defines the one thing that must not be app-specific: a declarative **payload
descriptor** (grown *in place* on the existing profile schema) + an on-node **assembly of
existing tools** that turns any descriptor into a running, hardened, network-confined,
reboot/reflash-surviving payload. "Different app later" = **write a descriptor**.

This is the mechanism layer *under* #68 — it does not redefine #68's vision, and it
**consumes** #97's admission verdict rather than redefining it.

## The payload descriptor — extend the existing profile IN PLACE (not a new file)

**Load-bearing constraint (verified against merged code):** `profile-to-flags.py` reads
**only** the nested `values:` block (`values.user.run_as`, `values.caps.drop`,
`values.rootfs.read_only`, `values.resources.*`, and the existing `values.network.mode`
and `values.secrets` axes); `check-hardening-env.sh` is a regenerate-and-diff gate that
**ignores unknown top-level keys**. Therefore extending the existing
`deploy/<app>/profile.yaml` in place is **safe for the emitter** and is adopted (resolves
R1-Q1) — we do **not** introduce a separate `payload.yaml`.

The descriptor keeps the merged top-level keys (`tenant / archetype / co_scheduled_with /
values / assessment / exceptions / target`) and the nested `values:` unchanged, and adds
**operational** sibling sections (`images / network / lifecycle / volumes`) that the
emitter ignores and the manager consumes:

```yaml
tenant: opentakserver              # existing
archetype: network-service         # existing
values:                            # existing — emitter reads ONLY this
  user: { run_as: 1024 }
  caps: { drop: [ALL] }
  rootfs: { read_only: false }
  resources: { cpus: 1.0, memory: 512m, pids: 512 }
  network: { mode: bridged }       # existing security axis (NIST 800-190)
  secrets:                         # existing axis (F5) — declared here, delivery below
    - { name: eud-ssl-cert, delivery: file, exposure: mount }
assessment: { ... }                # existing
exceptions: [ ... ]                # existing
target: { ... }                    # existing
# --- new operational siblings (manager-consumed, emitter-ignored) ---
images:
  - { ref: batman/ots@sha256:…, roles: [api, cot_parser, eud_handler, eud_handler_ssl] }
  - { ref: imresamu/postgis@sha256:… }
  - { ref: docker.io/library/rabbitmq@sha256:… }   # --user rabbitmq
network:                           # generates the validated fw4-native rules
  bridge: { name: br-ots, subnet: 172.20.0.0/24 }   # subnet/name from the node arbiter (below)
  publish:
    - { src_zone: ahwlan, host_port: 8088, to: eud_handler:8088, proto: tcp }
    - { src_zone: ahwlan, host_port: 8089, to: eud_handler:8089, proto: tcp }
    - { src_zone: ahwlan, host_port: 8443, to: nginx:443,        proto: tcp }
  isolation: { input: DROP, forward: intra-zone, egress: none }
  peer_allow: []                   # explicit app-A↔app-B allows (e.g. camera→tak), default none
lifecycle:
  order:  [ots-db, rabbitmq, ots, workers]
  health: { ots: "curl -f localhost:8081/api/health" }
  init_once: ["flask … db upgrade", "ots create-ca"]
  restart: on-failure-backoff
volumes:
  - { name: ots-appdata, path: /app/ots, chown: 1024 }   # under the tenant state root (below)
```

**Invariant (admission-checked):** `network.bridge` present ⇒ `values.network.mode:
bridged`. This prevents a profile that *claims* host-net while the operational section
builds a bridge (resolves R1-Q2). **Reverse branch (R2-N3):** `values.network.mode: host`
with **no** top-level `network:` (the FTS-style case) means the manager (i) builds no zone,
(ii) runs `--network host`, (iii) still registers that app's host ports with the arbiter
(host-net apps collide with each other too). Note `profile-to-flags.py` does **not** read
`values.network` at all — it emits no `--network`; `mode` is **declarative** (the
orchestrator sets the netns), so changing `mode` alone does not change the actual network.
`apiVersion: batman.payload/v1` is carried; the manager **rejects unknown apiVersion**, and
fleet (#116) gates on a node min-version.

## The mechanism — an ASSEMBLY of existing tools, not a new daemon

Explicitly **no new resident reconcile daemon** — that keeps us inside #151's review-set
scale-gate (a bespoke reconcile agent is *conditional* on >~20 nodes / weekly cadence, not
now). The mechanism is the existing tools wired in a fixed order:

1. **Admit** (#97, **direction-1 only** — see Trust below) — verify image **digest +
   signature** against the baked publisher key(s); check this payload is authorized for
   this node class (baked allowlist, #69/#52). **Honesty (from #151):** signature verify is
   *provenance*, **not** authenticated-RCE safety — the key and scripts sit on an
   unverified rootfs, so this is only sound once **verified boot (#74)** lands; until then
   it is best-effort and must be labeled so. Revocation = monotonic **epoch** + a
   multi-key trusted list on-node (no CRL/clock on air-gap) — per #97/#151, not an open
   question.
2. **Arbitrate** (new, small — see Gaps) — a node-level **registry** of allocated host
   ports / bridge subnets / fw4 zone names; admission **refuses** a descriptor that
   collides (the Σ-check analogue of #81's budget, for the network namespace).
3. **Network** — generate the fw4-native rules from `network:` (the validated OTS design,
   parameterized): `dockerd iptables=0`, a per-app bridge, DNAT publish, a per-app fw4
   zone (`input=DROP`, intra-zone forward, no mesh forward), the narrow `src_zone→dport`
   allow, plus any `peer_allow`. Installed as a uci-default (survives reboot/reflash; no
   post-docker `fw4 reload` needed — fw4 `iifname` is name-matched, proven on manet01).
4. **Harden** (PR #155 emitter / #98) — `profile-to-flags.py` emits `<app>.hardening.env`
   from `values:`; enforced at run.
5. **Guard, not orchestrate** (#156 vs orchestration — split, per R1-F6):
   - **#156's actual DoD is narrow = guardianship / anti-bypass**: a generated **procd**
     service brings the stack up on every boot with the hardened flags, so a hand-run
     `docker run` can't silently bypass the profile; `verify-profile.sh` is the drift alarm.
     procd does this well.
   - **Intra-stack ordering + health-gating** (`lifecycle.order`/`health`) is **beyond
     procd** (START/STOP priority + respawn only, no readiness gating). **Chosen: a small
     ordering wrapper** run under the procd service — sequential `docker run` (keeping the
     `$HARDEN_FLAGS` string and `--network br-ots`) + healthcheck polling between steps.
     **docker-compose is rejected as the default** for two concrete reasons (R2):
     - *(N1)* compose builds a project-scoped network whose kernel bridge is a random
       `br-<hash>`, **not** `br-ots` → the fw4 `iifname "br-ots"` rules (publish, east-west,
       blast-radius) would **silently match nothing** — no error, ATAK can't connect,
       isolation off. Compose is only usable with an **external** network pinned via
       `-o com.docker.network.bridge.name=br-ots`.
     - *(N2)* the #155 emitter produces a **`docker run` flag string** (`$HARDEN_FLAGS`);
       compose needs YAML keys (`cap_drop:`/`read_only:`/`user:`/`pids_limit:`…). Using
       compose reopens the merged emitter contract (needs a new `values→compose` renderer)
       or hardening silently doesn't apply. The wrapper consumes `$HARDEN_FLAGS` directly.
     - **Restart caveat (N5):** neither procd, the wrapper, nor compose `depends_on` re-gate
       dependents when rabbitmq/postgis *crash-restart* — the ots-networking restart-storm
       question stays open; the wrapper must add crash-restart backoff/health re-gating.
6. **Swap** (#151, unchanged scope = a hardened swap wrapper) — signed-image verify +
   state-aware rollback, mirroring the A/B pattern (#89). **Atomicity — mechanism, not just
   requirement (R2-N4):** there is **no cross-subsystem 2PC** on this platform (docker
   image store / uci-default / procd unit / tenant state are four separate subsystems).
   Achievable model = **a single monotonic-epoch commit marker** as the one commit point +
   **each artifact applied/rolled-back idempotently** + **boot-time replay** of the marker.
   Intra-swap ordering matters (esp. if the bridge subnet changes vX→vY, so does the DNAT
   target IP): **start new container → health-gate → re-point DNAT → retire old**. This
   lands in #151 (its journal widened to cover all artifacts listed above), not a new daemon.

Container↔container name resolution uses docker's embedded 127.0.0.11 resolver.

## Trust (#97) — we consume ONE of three directions

#97 defines **mutual** trust in three directions. This framework **only consumes
direction-1** (node→app admission). The other two stay **in #97's scope but are unscheduled
and not consumed here** (R2-N6):
- **direction-2** app→node remote attestation — not addressed.
- **direction-3** app↔app workload identity / mTLS (SPIFFE-style) — not addressed, yet it
  is exactly the "two payloads distrust each other" case (#68 camera→TAK). The descriptor
  has **no per-workload identity axis** today; `network.peer_allow` gives only L3 reach,
  not identity. Flagged as a gap, not silently claimed as unified.

## Delivery fronts sit ON TOP (delivery-agnostic; decide per need)

All hand a descriptor + images to the same mechanism; "baked-in" is **just a descriptor +
images shipped in the image**, read at boot — one code path, not two:
- **Baked into the payload-host image** (#159) — for a *required* capability (TAK): flash
  & go, update via A/B OTA.
- **On-device management UI** — for optional user apps; OpenWrt-native option is a
  `luci-app-dockerman`-style page, **curated to descriptors** (verify + profile), not raw
  container management.
- **Fleet OTA push** (#116) — controller pushes descriptors/images (balena / IoT-Edge
  pattern), canary→staged; carries the apiVersion min-version gate.

## OTS as instance #1 (#162)

OTS's descriptor = the validated networking (br-ots, iptables=0 fw4-native, DNAT
8088/8089/8443, `dockert` input=DROP) + a `network-service` `values:` block + the
volume-chown / rabbitmq `--user` details, and `values.secrets` naming the EUD SSL cert
(whose crash in the spike is exactly the secrets-delivery gap below). Delivered baked-in.

## Gaps this design surfaces (need owners) — the "different apps later" tail

- **Generic N-tenant state layout + teardown.** #119 (tenant layout) is **CLOSED and
  FTS-specific**; #151 punts archive/zeroize to a "separate path." No open issue owns a
  generic `apps/<tenant>/` (or p6) layout, quota, and secure **removal/zeroize** for
  arbitrary tenants. Owned by #167. (Also: unify the state-path convention — #151
  and the FTS profile use `apps/<tenant>/`; this design must pick one and not drift to
  bare `/opt/batdata`.)
- **Secrets *delivery* mechanism.** `values.secrets` is *declared* in the merged schema,
  but how an air-gapped container actually receives its TLS cert / DB cred / rabbitmq
  cookie has **no owner** (OTS `eud_handler_ssl` crashed for a missing cert). Owned by #167
  (ties #13/#47 at-rest), don't scatter it in `init_once`.
- **The port/subnet/zone arbiter** (step 2) needs a home — #167.
- **payload↔payload isolation at N>1** — per-app bridge+zone+inter-zone DROP gives **L3**
  isolation; this must be **tested at N=2 on manet01** (the "one auditable `nft table`"
  claim is only proven at N=1 and degrades as zones/DNAT sets grow).

## Alternatives considered

- **Turnkey framework (balena / k3s).** Heavy for a Pi4 mesh node + a control-plane
  dependency unwanted on an air-gapped tactical device. Rejected as a wholesale dep;
  pattern (declarative descriptor → init-owned run) reused.
- **podman instead of docker.** podman does **not** require systemd/Quadlets (`podman run`
  / pods / `kube play` can be procd-managed), and #151/#156 both ask to evaluate it; its
  rootless/daemonless model is a genuine plus for a security node. **Rejected only because
  #159 already baked docker into the image** (engine-swap cost) + OpenWrt docker-package
  maturity — not because "it needs systemd." Revisit if the image is re-cut.
- **Per-app bespoke deploys.** Rejected — the user will have different apps.
- **Fold networking into #98.** Rejected — networking is per-app, so it belongs in the
  per-app descriptor next to security.

## Boundaries / non-goals
- Not a new epic (#68); not a resident reconcile daemon (stays in #151's scale-gate); not
  re-specifying #97 (only direction-1 consumed); not choosing the delivery UI/fleet now.

## Coherence across the issue set (the "validate together" deliverable)

Broadly **coherent**, and this is the correct mechanism layer under #68. Extend-in-place
does **not** break the merged #155 emitter (given the descriptor keeps `values:` intact).
Three scope clarifications are required:
- **#97** — record that this framework consumes only direction-1; directions 2 (attest)
  and 3 (app↔app identity) are unowned and matter for multi-tenant.
- **#151** — keep its "hardened swap wrapper" scope (no monolithic daemon); widen its
  commit-journal to cover all generated artifacts.
- **#167** — owns generic N-tenant state layout + teardown + the port/subnet/zone
  arbiter + secrets-delivery (the gaps above); #119 is closed/FTS-specific.

## Open questions for re-review
1. compose-under-procd vs a thin ordering wrapper for `lifecycle.order/health` — which is
   simpler to keep hardened and reboot-safe?
2. Does the `peer_allow` L3 model need to become identity-based (#97 dir-3) before any
   two-payload deployment, or is L3 + baked policy enough for the first "things" tenant?
3. Where does the port/subnet/zone arbiter live — a uci config the manager reads, or
   derived deterministically from tenant name?

## Implementation gate — prove on manet01 at first build (R2, approvable modulo these)

The design is approved; these must be demonstrated when the framework is first implemented
(all are small, recoverable on-node experiments):

1. **Orchestrator × iptables=0 × fixed `br-ots`** — the chosen ordering-wrapper brings the
   stack up on the **exact kernel bridge name `br-ots`** so the fw4 `iifname "br-ots"` rules
   actually match (N1). (If compose is ever used: external fixed-name network + no `ports:`.)
2. **Hardening actually applied** — `verify-profile.sh` passes: `$HARDEN_FLAGS`
   (cap-drop/read-only/user/cpus/pids) is on every container under the wrapper (N2).
3. **N=2 isolation** — two payloads, two bridges/zones, inter-zone DROP proven (A can't
   reach B except via `peer_allow`), and `nft list table inet fw4` is still one auditable
   table (F8 / #167).
4. **Arbiter refusal** — two descriptors contending for host `:8443` (or a subnet/zone-name
   clash): admission refuses the second (F7 / #167).
5. **Swap atomicity + crash-safe** — force a failure at "new zone installed, container not
   healthy": image+state+fw4+procd+descriptor all roll back per the epoch marker; power-cut
   then boot-replay leaves the DB intact (N4 / F3 / #151).
