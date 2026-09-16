# Design: Payload framework — declarative, app-agnostic payload deployment

Status: **draft v2 — review R1 addressed (PASS-WITH-CHANGES); needs re-review** ·
Parent epic: **#68** (generic payload host)
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
builds a bridge (resolves R1-Q2). `apiVersion: batman.payload/v1` is carried; the manager
**rejects unknown apiVersion**, and fleet (#116) gates on a node min-version.

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
     procd** (it has START/STOP priority + respawn, no readiness gating). Use
     **docker-compose (with `ports:` omitted — fw4 publishes) + healthchecks** run *under*
     that single procd service, or a small ordering wrapper. procd guards; compose orders.
6. **Swap** (#151, unchanged scope = a hardened swap wrapper) — signed-image verify +
   state-aware rollback, mirroring the A/B pattern (#89). **Atomicity fix (R1-F3):** the
   commit-journal transaction boundary must cover **all** generated artifacts
   (descriptor + images + fw4 uci-default + procd unit + `hardening.env` + tenant state),
   not just image+state — otherwise a half-applied swap (new zone installed, old container
   still up) cannot roll back.

Container↔container name resolution uses docker's embedded 127.0.0.11 resolver.

## Trust (#97) — we consume ONE of three directions

#97 defines **mutual** trust in three directions. This framework **only consumes
direction-1** (node→app admission). The other two are **out of scope here and currently
unowned**:
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
  arbitrary tenants. **Open a new issue.** (Also: unify the state-path convention — #151
  and the FTS profile use `apps/<tenant>/`; this design must pick one and not drift to
  bare `/opt/batdata`.)
- **Secrets *delivery* mechanism.** `values.secrets` is *declared* in the merged schema,
  but how an air-gapped container actually receives its TLS cert / DB cred / rabbitmq
  cookie has **no owner** (OTS `eud_handler_ssl` crashed for a missing cert). **Own it**
  (ties #13/#47 at-rest), don't scatter it in `init_once`.
- **The port/subnet/zone arbiter** (step 2) needs a home — likely the same new issue.
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
- **New issue** — own generic N-tenant state layout + teardown + the port/subnet/zone
  arbiter + secrets-delivery (the gaps above); #119 is closed/FTS-specific.

## Open questions for re-review
1. compose-under-procd vs a thin ordering wrapper for `lifecycle.order/health` — which is
   simpler to keep hardened and reboot-safe?
2. Does the `peer_allow` L3 model need to become identity-based (#97 dir-3) before any
   two-payload deployment, or is L3 + baked policy enough for the first "things" tenant?
3. Where does the port/subnet/zone arbiter live — a uci config the manager reads, or
   derived deterministically from tenant name?
