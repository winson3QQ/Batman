# Field app lifecycle / re-roleable node (design)

**Issue:** #151. **SoT:** #75. Status: design (reviewed once, down-scoped).

## Problem
Pre-deploy, an SD card is burned and the node has a fixed role — fine. **Post-deploy, in the field, we sometimes need to change the apps a node runs** — update an app, add/remove one, or re-role the node — *safely* and *within the node's hardware envelope*, **without reflashing**. Today it is manual and unsigned: build the image off-node in CI → scp a tar over a borrowed NAT or the mesh → `docker load` → `run.sh`.

## Non-goals
OS/firmware A/B OTA (done, #89). The verified-boot chain itself (#74 — this *consumes* its trust anchor, does not build it). The pre-deploy SD burn.

## What already exists (do not rebuild)
- **Tenant layout (#119):** `apps/<tenant>/` isolated state, images shared in `docker/`, one repo declaration per app (`deploy/<name>/`).
- **docker runtime** on the p6 data partition; `run.sh` the single start path; per-app `functional-test.sh`.
- **A/B OS OTA (#89)** — the *pattern* (write-inactive → trial → health-gate → commit/rollback) to mirror at the app layer, **with one correction below (state).**

## Direction (after review — this is the key decision)
**Do NOT build a bespoke fleet "reconcile agent". Build a hardened `run.sh` for a *safe local app swap* — and treat that as possibly the terminus.** A declarative manifest + on-node daemon is only justified past a concrete scale trigger (e.g. >20 nodes, or weekly change cadence); at a handful of nodes it solves a problem we don't have. If that trigger ever fires, **evaluate podman + systemd Quadlets / systemd-sysext before writing a daemon** — "desired state on disk + systemd notices" is most of the agent with no bespoke code to own.

The change spectrum — **update** an app / **add** a tenant / **re-role** — is *not* one uniform operation: update/add are additive; **remove/re-role is destruction and needs its own path** (see below).

## P1 — safe local app swap (buildable now, no new hardware, manual delivery)
A wrapper around `run.sh` that makes changing/adding/updating a tenant *safe*:

1. **Signed-image verification before run.** Verify image signature + digest before starting it. **Honest value:** integrity / anti-corruption / provenance / forces key discipline early. **It does NOT deliver authenticated-remote-code-execution safety** — the verifier and any trust anchor sit on an *unverified* rootfs today, so a root-capable adversary bypasses it (the "scp a file and it runs" hole). **Auth-RCE safety is gated on verified boot #74.** Do not claim P1 closes the trust pillar.
2. **cgroup-enforced budgets.** Apply real `--memory`/`--cpus` per tenant **and reserve a system slice** for the mesh daemon (batman) + OS. Admission refuses if `Σ(tenant budgets) + system reserve > local profile`. A static profile only *checks nameplate*; enforcement (real cgroup limits + a protected system reserve) is the half that actually prevents OOM/starvation.
3. **State-aware keep-last-good / rollback (the crux — the #88 "state survives rollback" trap).** Apply vX→vY, health-gate, and on failure roll back **image + `apps/<tenant>/` state together, atomically** — snapshot the tenant dir before apply (FTS's SQLite/config specifically). Rolling only the *image* back onto a forward-migrated DB **bricks the tenant** — worse than no rollback. Alternative: forbid in-place forward migration during the trial window until commit.
4. **Crash-safe apply.** Nodes hard-power-off mid-apply and have **no RTC**: an on-disk commit journal (intent → staged → committed) replayed on boot; decide the winner by a **monotonic epoch**, never wall-clock.
5. **Minimal local board profile.** A static file (RAM/storage/CPU, tier) for the admission check in (2). Does not wait on the full #110 machinery.

**Definition of Done (P1):** verifies image signature+digest → admits against the local profile (Σ-budget + system reserve) → snapshots tenant state → applies with cgroup limits → health-gates (per-app functional test) → commits or rolls back **image+state atomically**, crash-safe. Verified on manet02 with FTS: an update *and* a forced-fail rollback that leaves the DB intact.

## Re-role / remove a tenant — a separate (destructive) path
Removal is not "the same op minus a diff": stop/rm containers, release ports, and make an **operator-chosen archive vs zeroize** of `apps/<tenant>/` + secrets (#70), with **cert/workload-identity revocation** (#97). Data remanence matters on a device that may be captured and never revisited.

## Delivery (out of P1 — #116)
690 MB (FTS) over ~Mbps HaLow is not realistic, and a base rebase (e.g. bookworm→trixie) invalidates every layer above it, so "ship only changed layers" evaporates exactly on major updates. **USB is the honest path for full images and rebases; mesh delivery is viable only for small apps / same-base tag bumps.** A gateway cache/reseed is a P3 open question, not a banked mitigation. **#74 must land before any remote delivery path** — mesh delivery is when the unauthenticated-RCE path becomes remotely reachable. All of this stays in #116.

## Signing key custody (prerequisite for a manifest / P2 — #13/#70)
Offline signer / hardware token; an on-node **trusted-key list** (multiple keys, so one can be dropped) rather than a single anchor; **revocation via a monotonic manifest epoch** (reject ≤ last-committed) because offline + no-RTC means no CRL/OCSP and no trustworthy "now".

## Alternatives (why not a custom agent / heavyweight orchestration)
- **k3s / KubeEdge / fleet** — heavy for Pi-4/Zero-2W mesh nodes, assumes connectivity patterns we lack offline. Overkill.
- **balena / Greengrass / Azure IoT Edge** — cloud-dependent + third-party trust; not offline-mesh-native (sovereignty). Rejected.
- **podman + systemd Quadlets / systemd-sysext** — declarative, no bespoke daemon, native to init, signed/atomic (sysext) — the first thing to evaluate *if* a reconcile layer is ever needed.
- **Bespoke reconcile agent** — only past a real scale trigger, and only if it beats Quadlets. Not now.

## Phasing
- **P1** (above) — independently valuable; possibly the terminus. Closes *locally*: integrity, budget-enforcement, state-aware rollback, crash-safety. Does **not** close auth-RCE (that's #74).
- **P2** (conditional on scale) — signed declarative manifest + reconcile, only after evaluating Quadlets/sysext.
- **P3** (#116) — mesh/gateway delivery; gated on #74; USB-honest for large images.

## Failure modes
| risk | mitigation |
|---|---|
| unsigned/rogue image = RCE | signature verify (P1) + **#74** for the real guarantee; #74 before remote delivery |
| bad app version bricks tenant on rollback (state) | **snapshot apps/<tenant>/ + roll image+state together** (P1.3) |
| app OOMs / starves the mesh daemon | cgroup limits applied + protected system reserve; Σ-budget admission (P1.2) |
| large image swamps HaLow | USB for full images; mesh only small/same-base (#116) |
| mid-apply hard power-off, no RTC | on-disk commit journal + monotonic epoch, replay on boot (P1.4) |
| key on a laptop / offline revocation | trusted-key list + monotonic epoch + offline signer (#13/#70) |
| re-role leaves state/certs behind | explicit archive/zeroize + identity revocation (#70/#97) |
| scope creep into a mini-Kubernetes | P1 is a hardened run.sh; agent is conditional; delivery stays #116 |

## Ties
#119 (tenant layout) · #116 (delivery) · #110 (board profile) · #97 (admission/identity) · #81 (budget) · #74/#13 (verified boot / PKI, trust anchor + key custody) · #89 (A/B pattern) · #70 (lifecycle / zeroize / key rotation) · #14/#65 (state reporting).
