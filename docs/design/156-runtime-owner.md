# Design: Runtime owner for payload confinement (#156)

**Status:** Reviewed (2 adversarial passes) · **Phase 1 (alarm-only) IN PROGRESS** · **SoT:** #75 · **Milestone:** v1.1 DEV golden (dev-now)
**Ties:** #98 (defines the confinement flags) · #151 (safe app swap / lifecycle) · #97 (admission, prod-lock, downstream) · #68 (payload framework) · #162 ④ (fold deploy into the runtime owner) · #167 (multi-tenant plumbing)

---

## 1. Problem, in one line

The #98 confinement flags are applied **only at `docker run` time by `run.sh`**. Nothing continuously enforces that the *running* container still matches its profile. A manual/rogue/buggy `docker rm … && docker run …` (without `$HARDEN_FLAGS`) starts the container **unhardened**, and nothing detects or corrects it. Config *correctness* (the CI + `verify-profile` gates the reviews covered) is not config *enforcement*.

This is the runtime / anti-bypass counterpart of drift the earlier reviews DID cover. #156 closes it: an **init-owned reconciler** that keeps the running fleet converged to the profile, on every boot and continuously thereafter.

## 2. Reality check — what already exists (2026-09-18, on-repo + manet01 live)

`deploy/ots/batman-ots.init` **already exists** and is enabled on manet01. It is a procd service (`START=99`, `USE_PROCD=1`, `respawn 30 15 0`) that:

- ✅ **Boot / crash bring-up:** waits for the docker socket (generously, under respawn — dockerd cold-boot on a Pi4 with data-root on p6 can exceed 2 min), applies `ots.fw4.uci`, and runs `run.sh` if `opentakserver` is not already up. Idempotent, retried by procd until healthy.
- ❌ **Anti-bypass (the actual #156 DoD) — NOT real yet.** The keepalive loop (`batman-ots.init:33`) only tests `.State.Running`. A container that was `docker rm`'d and re-run **unhardened** is still `Running=true` → the guard sees "alive, fine" → **never re-corrects**. The whole gap #156 names is open.
- ❌ **Drift alarm — NOT real yet.** `verify-profile-ots.sh` IS invoked once at boot (`batman-ots.init:31`) but its result is `>/dev/null 2>&1 || true` — **discarded**. It is not periodic, does not alarm, does not re-assert.

**So #156 is not greenfield.** The skeleton (init ownership, boot bring-up, respawn) is done. What is missing is exactly the three things the issue lists: (a) periodic **conformance** check (not liveness), (b) **re-assert** on drift, (c) **alarm**. This design specifies those three and leaves the skeleton in place.

The confinement axes to enforce (from `deploy/ots/ots.hardening.env` + `verify-profile.sh`): `--user`, `--security-opt no-new-privileges`, `--cap-drop=ALL`, `--read-only`, `--tmpfs`, `--cpus`, `--pids-limit`, `--memory`, plus the always-asserted baselines seccomp≠unconfined, privileged=false, docker-socket-not-mounted, bridged network. SoT = `deploy/ots/profile.yaml` → `profile-to-flags.py` → `*.hardening.env`.

---

## 3. Phasing (post-review) — alarm-first, destructive-correction later

Two adversarial reviews (a design pass, then a code pass on the checker) hit the same fault line: **every blocking finding was about the destructive re-assert path**, not detection. So the work is split:

### Phase 1 — detection + ALARM ONLY (this change; no container is ever rm-ed)
Because nothing is torn down, the three design-review BLOCKERS (run.sh full-stack teardown re-inflicting the rabbitmq CoT→0 outage; keepalive↔procd-respawn race; `docker update` unverified) **cannot fire** — they are all destructive-action failures. Phase 1 ships:
- **`scripts/verify-profile.sh` detection hardening** — single authoritative inspect blob (no per-axis re-inspect that reads empty and misjudges); inspect-fail / not-running / too-fresh → UNKNOWN(3), never DRIFT; MIN_UPTIME actually enforced; memory value-compared; added anti-bypass axes: cap-ADD must be empty, `--tmpfs` present, seccomp un-overridden, `no-new-privileges` not `=false`, network **exactly** ots-net.
- **`deploy/ots/verify-profile-ots.sh`** rolls the 6-container verdicts up (drift if any; unknowns skipped, not alarmed).
- **`deploy/ots/batman-ots.init`** keepalive → **reconcile loop**: each tick runs the wrapper, writes `/tmp/batman-ots-drift.json`, `logger`s on drift. No re-assert.

### Phase 2 — destructive correction (deferred; hard prerequisites)
Do NOT build tier-1/tier-2 auto re-assert until these exist, in order:
1. **`run.sh --only <container>`** — a surgical single-container reconcile that preserves the broker + cross-container bindings (the current `run.sh` unconditionally rebuilds all 6 → forbidden as a corrective).
2. **keepalive/respawn race fix** — a lockfile/guard so a *planned* rm during re-assert doesn't read as a crash and trigger a second concurrent `run.sh`.
3. **`docker update` verified on-node + cgroup version pinned** — confirm `--cpus/--memory/--pids-limit` live-mutate on this docker/cgroup config before relying on the "non-destructive resource correction" branch.
4. Then the hybrid tier policy (§Decision C), with N-consecutive debounce before any destructive act.

Also evaluate in Phase 2 (structural alternatives a polling loop doesn't need): **`daemon.json` `no-new-privileges: true`** as a daemon-wide default (removes that axis from policing entirely) and a **docker authorization plugin** that rejects a non-conformant create at admission (no naked window, no rebuild storm; overlaps #97). And **`docker events`**-driven detection (sub-second) with the periodic sweep as backstop, replacing the pure 60s/30s poll.

### Review-findings disposition
| # | Finding (source) | Disposition |
|---|---|---|
| D-B1 | run.sh full-stack teardown re-inflicts CoT→0 (design) | **Phase 2** prereq 1 (`--only`) |
| D-B2 | keepalive↔respawn race on planned rm (design) | **Phase 2** prereq 2 — N/A in Phase 1 (no rm) |
| D-B3 | DoD "auto-correct memory" needs value-check (design) | **fixed** (verify-profile memory value-compare) |
| D-M | MIN_UPTIME print-only; silent-pass axes; docker-update unverified; events/daemon/authz missed | detection ones **fixed**; events/daemon/authz/docker-update → **Phase 2** |
| C-F1 | per-axis re-inspect → false-DRIFT + cap-add/seccomp silent-pass (code) | **fixed** (single inspect blob) |
| C-F2 | `no-new-privileges=false` substring silent-pass (code) | **fixed** (reject disabled form) |
| C-F3 | network passes if ots-net alongside host (code) | **fixed** (exact-match ots-net) |
| C-F4 | busybox `date -D` may be absent → freshness gate off (code) | **RESOLVED on manet01**: busybox `date -D` works (rc=0) → freshness gate active |
| C-F5 | NanoCpus `%d` 32-bit overflow at cpus≥3 (code) | **fixed** (`%.0f`) |
| C-F6 | loose substrings (`/tmp`, sock) (code) | tightened (`/tmp:`); residual noted |
| N-1 | **docker multiline-template map-decode aborts on a nil map (Tmpfs) → a fully UNhardened bypass read as UNKNOWN, not DRIFT** (found ON NODE, worse than any review finding) | **fixed**: dropped the single big template; read per-field with SIMPLE templates (typed decode, safe on nil) bracketed by pre/postflight existence checks (keeps the F1 mid-check-death→UNKNOWN guarantee) |
| — | seccomp false-pos / rabbitmq name / set -e / wrapper rollup | confirmed **non-issues**, unchanged |

**On-node evidence (manet01, live OTS host, 2026-09-18):** the 6 live hardened containers → verify-profile-ots OK (0 drift); a fully-unhardened decoy → DRIFT (read-only/cap-drop/nnp/user/tmpfs/cpus all flagged); a hardened+`--cap-add=SYS_ADMIN` decoy → DRIFT (cap-add flagged); the 6 real containers untouched throughout (alarm-only, zero destructive action). `date -D` freshness gate confirmed working on the node busybox.

---

## Decision A — who OWNS the container at runtime

The issue frames this as **procd (native now)** vs **podman + systemd Quadlet (#151-preferred)**. The user asked for a *full* evaluation of the migration, not a park-it note. Here it is.

### A1 — OpenWrt procd service (native)
The reconciler is a procd init script (evolve the existing `batman-ots.init`). Docker stays the runtime.

- **Cost:** low. The skeleton exists; we add a reconcile step + alarm to the keepalive. No new packages, no runtime swap, no image rebuild.
- **Fit:** native. procd IS the OpenWrt init system; it already supervises the service with respawn/backoff.
- **Enforcement model:** procd owns *the reconciler process*, not the container. Docker owns the container. The reconciler re-asserts by re-running the hardened `run.sh`. Ownership is "a supervised loop that converges," not "init directly holds the container cgroup."
- **Limits:** the guarantee is only as strong as the reconcile interval (a bypass is naked until the next tick). Docker (not procd) remains the thing that could be told to run something unhardened; we detect+correct rather than make it structurally impossible.

### A2 — podman + systemd Quadlet (full migration eval)
Quadlet is a systemd generator: a declarative `*.container` unit (`PodmanArgs=` carrying the profile flags) is expanded into a `systemd .service`, and **systemd owns the container as a first-class unit** — start/stop/restart/ordering/health all native, config drift structurally reduced because there is no imperative `run.sh` to bypass; the unit file *is* the launch definition.

This is genuinely the cleaner target model. But migrating the Batman node to it is a large, multi-issue change:

1. **No systemd on the node.** OpenWrt uses procd/BusyBox init; there is no systemd and adopting it is not realistic (it would replace the entire init system of the distro). Quadlet **requires** systemd as PID-manager — it is a systemd generator with no procd equivalent. So A2 on the *current* OpenWrt node is **not available**: you cannot run Quadlet without systemd, and you cannot add systemd to OpenWrt as a package.
2. **Runtime swap docker→podman.** Even setting systemd aside, podman must replace docker across the whole stack: `#159` bakes **docker** into the image (meta-package `feed/batman-payload-host`, data-root `/opt/batdata/docker`, memcg cmdline); `run.sh`, `ots.fw4.uci` (the `br-ots` fixed-name bridge the fw4 `iifname` rules depend on), the A/B payload, and every `docker inspect` in `verify-profile.sh` are docker-specific. Podman's rootless/netns model and its bridge naming differ; the whole ots-networking design B (#179) would need re-validation.
3. **Where A2 actually lives:** it is only reachable on a **different base OS** (a systemd Linux — e.g. if a future non-Broadcom small node or a Pi-class node ran a systemd distro instead of OpenWrt). That is a productization fork, not a v1.1 node change. It also overlaps #151 (which already lists "evaluate podman + systemd Quadlets" for safe app swap) and #68 (payload framework).

**A2 verdict:** the target model is sound and worth recording as the **v2.0+ / non-OpenWrt direction**, owned jointly by #151 and #68 — but it is **blocked on the node's init system** and cannot be the v1.1 mechanism. Choosing A2 now would mean replacing procd+docker+the #159 image plumbing to close a drift gap that A1 closes with a reconcile loop. That is not proportionate.

### Decision A verdict → **A1 (procd reconciler) for v1.1**, with A2 (podman/Quadlet on a systemd base) recorded as the v2.0+ evolution under #151/#68. The reconciler is written so its *policy* (§Decision C) is runtime-agnostic — if the node later moves to Quadlet, the conformance judgment and drift policy port; only the "re-assert" mechanism changes from "re-run run.sh" to "systemctl restart the unit."

---

## Decision B — conformance judgment (liveness → conformance)

The keepalive must test **conformance to the profile**, not just liveness. `verify-profile.sh` already computes exactly this per-axis (`docker inspect` ↔ `$HARDEN_FLAGS`), returning non-zero on drift. So B is mostly wiring, plus hardening the check itself.

- **Loop:** every `RECONCILE_INTERVAL` (proposal: 60s; today's keepalive sleeps 30s on liveness), run `verify-profile-ots.sh` across all 6 containers. Its exit code is the drift signal (today discarded).
- **Two drift shapes** the check must distinguish:
  1. **Missing / not-running** container → bring-up path (existing behavior, keep).
  2. **Running but non-conformant** container (the bypass case) → the new path, governed by Decision C.
- **Harden the checker against false positives** (a reconciler that fights phantom drift is worse than none — see Failure F3). Known gaps in the current `verify-profile.sh` to close or account for:
  - It only asserts axes **present in `$HARDEN_FLAGS`**. That is correct for "was it applied," but for anti-bypass we ALSO need the **always-true baselines** re-checked every tick: `privileged=false`, `seccomp≠unconfined`, socket-not-mounted, and network attachment = `ots-net`/`br-ots`. It already checks the first three unconditionally; **network is not currently asserted** and a bypass could reattach to host-net — add it.
  - String-parse fragility (`sed` on the flag string) → a benign representation difference must not read as drift. Reviewer: check `--user 1000:1024` vs inspect `1000:1024`, tmpfs, memory unit normalization.
- **Idempotence / debounce:** a single failing tick should not immediately trigger a destructive action — require **N consecutive** non-conformant ticks (proposal N=2) before re-assert, to ride out a container mid-restart (StartedAt < MIN_UPTIME).

---

## Decision C — drift policy = **hybrid (c)** [user-selected]

When the reconciler finds a **running but non-conformant** container, what it does depends on **which axis drifted**. The split is not arbitrary — it maps onto a real Docker capability boundary:

| Axis class | Axes | Can Docker fix it live? | Policy |
|---|---|---|---|
| **Resource** (non-destructive) | `--cpus`, `--memory`, `--pids-limit` | ✅ `docker update` mutates a running container | **auto-correct in place** (no downtime) + log |
| **Security-critical** (destructive to fix) | `--user`, `--cap-drop`, `--read-only`, `--security-opt no-new-privileges`, seccomp, privileged, docker-socket, network attachment | ❌ fixed at create — only `rm`+recreate changes them | **alarm always**; re-assert is **tiered** (below) |

The resource axes being live-mutable and the security axes being create-only is a happy coincidence that makes hybrid clean: the cheap-to-fix drift is also the low-stakes drift, and the expensive-to-fix drift is also the high-stakes drift.

**But "alarm only" on security drift leaves a broken-out container running — which is the exact hole #156 exists to close.** So within the security-critical class we tier by *escape severity*:

- **C-tier-1 "escape-class" drift** — the container has genuinely broken its jail: `privileged=true`, docker-socket mounted, `cap-drop` no longer ALL, running as **root** (`user=0`), or reattached to **host network**. A container in this state is a live blast-radius hole; leaving it up is arguably worse than a brief service blip. → **alarm + re-assert (rm+recreate hardened via run.sh) immediately**, subject to the anti-flap limit (F1). The blip is the cost of closing an active escape.
- **C-tier-2 "hardening-degraded" drift** — still confined but weaker than profile: `read-only` off, `no-new-privileges` off, seccomp default→(still not unconfined). Not an active escape. → **alarm + re-assert on a grace timer** (proposal: re-assert at the next reconcile after a `DRIFT_GRACE` window, default 300s, so a human watching the alarm can intervene / an in-flight operation can drain). Configurable to "alarm-only" per-axis if an operator opts out.

This encodes the session-10g lesson (**do not blindly rebuild live TAK — last time recreating rabbitmq broke the app's exchange bindings, CoT→0**): the reconciler must re-assert **via the ordering-aware `run.sh` path** (broker before app, health-gated), never a bare single-container `docker run`, because the OTS stack has cross-container bindings. A tier-1 re-assert of one infra container = a **stack** reconcile in dependency order, not a surgical single `rm`.

**Open sub-question for the reviewer:** is `read-only off` really tier-2, or does losing rootfs immutability + gaining a writable rootfs constitute enough of an escape vector (drop a binary, tamper) to be tier-1? Defaulted to tier-2 here; flag if wrong.

---

## Decision D — where the alarm goes

The reconciler must surface drift, not just log to procd stdout (which no one reads in the field). Reuse existing plumbing:

- **Primary:** a drift verdict file the health roll-up reads — fold into `/cgi-bin/status` (#130) and the whole-mesh `/cgi-bin/mesh` table (#14), so a phone on the onboarding AP sees "payload confinement: OK / DRIFT". This matches the joinwatch-style verdict pattern (#127) already in the fleet.
- **Secondary:** structured log line (logger tag) for post-hoc audit, feeding the crash/audit story (#61/#104-adjacent).
- **Not in scope:** off-mesh alarm delivery (mesh is the only backhaul) → that's #142.

Proposal: reconciler writes `/tmp/batman-ots-drift.json` (`{status, ts, per_container:[{name, axis, tier, action}]}`); status CGI reads it into the health rollup. tmpfs, so it respects the #104 write budget.

---

## 4. Failure modes (attack surface for the reviewer)

- **F1 — reconcile flap / rebuild storm.** A container that keeps drifting (or a re-assert that keeps failing) → infinite rm/recreate loop → self-inflicted DoS on the payload. **Mitigation:** bounded re-assert — max R re-asserts per container per window (proposal 3 per 30 min), then **latch to alarm-only + escalate** (stop fighting, tell the human). Must reuse/compose with procd's existing `respawn 30 15 0` so the two supervisors don't fight.
- **F2 — re-assert breaks live TAK.** Rebuilding a container drops connected ATAK/iTAK clients and can break cross-container bindings (the rabbitmq→app lesson). **Mitigation:** tier-2 grace window; tier-1 re-assert always via `run.sh` dependency order, never bare single-container run; health-gate after re-assert and if unhealthy, roll to alarm-only rather than loop.
- **F3 — false-positive drift.** `verify-profile` mis-reads a benign representation difference as drift → needless (tier-1: immediate) rebuild. This is the most dangerous failure — it turns the safety mechanism into the outage. **Mitigation:** N-consecutive-tick debounce (Decision B); freeze the flag↔inspect comparison semantics with a unit test on the exact string forms; MIN_UPTIME guard so a mid-restart container isn't judged.
- **F4 — the reconciler itself is the bypass hole.** If an attacker can edit `run.sh` / `*.hardening.env` / `profile.yaml` on the node, the reconciler will faithfully "re-assert" to the *attacker's* weakened profile. **Mitigation:** out of scope for #156 (this is admission / integrity = #97 + signed-image #151 + #137 root-pw + #13/#47 key protection) — but **state it explicitly** so the guarantee isn't oversold: #156 assures "the running container matches the on-disk profile," not "the on-disk profile is trustworthy." Note it in DoD.
- **F5 — reconcile races bring-up on cold boot.** dockerd not ready → conformance check errors → misread as drift. **Mitigation:** the existing "wait for docker socket, exit-for-respawn" gate must run BEFORE any conformance verdict; conformance loop only arms once the stack is first confirmed up.
- **F6 — partial re-assert leaves the stack half-up.** rm the infra container, recreate fails midway → app containers orphaned. **Mitigation:** `run.sh` is already idempotent + health-gated + ordered; re-assert = full ordered reconcile, and a failed step latches alarm-only (don't leave it worse).
- **F7 — clock / audit skew.** drift-event timestamps on a node with no RTC (#174) → misleading audit trail. **Mitigation:** use monotonic uptime for intervals (not wall clock); note wall-clock ts is best-effort (batman-faketime floor).

## 5. Definition of Done (bench-verify on manet02)

1. **Boot:** reboot → all 6 containers return **hardened** with no manual `run.sh` (existing behavior — regression-guard it).
2. **Anti-bypass tier-1 (new, the core):** manually `docker rm opentakserver && docker run --network ots-net … opentakserver` **without** `$HARDEN_FLAGS` (running as root / no cap-drop) → within ≤ (N ticks) the reconciler **alarms** and **re-asserts** it back to hardened via `run.sh`; `verify-profile-ots` returns OK afterward.
3. **Anti-bypass tier-2 (new):** start a container `--read-only`-off → reconciler **alarms immediately**, re-asserts after the grace window (or stays alarm-only if configured).
4. **Resource in-place (new):** `docker update --memory 999m opentakserver` → reconciler **corrects via `docker update`** back to 512m, **no restart**, client stays connected.
5. **Anti-flap:** a container forced to drift repeatedly latches to alarm-only after R attempts instead of looping.
6. **Alarm surfaced:** `/cgi-bin/status` health rollup shows DRIFT during 2–3 and OK after.
7. **F4 stated:** DoD text records that #156 trusts the on-disk profile (integrity = #97/#151/#137).

## 6. Scope boundaries (from the issue, restated)

- **NOT #156:** *which* workloads may run at all / a compromised deployer launching an *unlisted* container → **#97** (admission, prod-lock). #156 guarantees the *approved* container runs *as specified*.
- **NOT #156:** signed-image verify before run → **#151 P1**.
- **NOT #156:** trusting the profile/run.sh on disk → integrity chain (#97/#151/#137/#13/#47). #156's guarantee is scoped to "running ⟷ on-disk profile."
- **Downstream of #156:** #162 ④ (fold the bespoke deploy into this owner) and #68 (generalize the owner across tenants) consume this once the OTS reconciler is proven.

## 7. Proposed change surface (for review, not yet built)

- Evolve `deploy/ots/batman-ots.init`: keepalive → **reconcile loop** (conformance not liveness), calling `verify-profile-ots.sh` each tick; classify drift by axis→tier; act per Decision C; write the drift verdict file.
- Extend `scripts/verify-profile.sh`: assert **network attachment** every tick; expose a machine-readable per-axis result (so the reconciler can tier, not just get a pass/fail rollup); freeze comparison semantics with a unit test.
- `docker update` path for resource axes (new, small helper).
- Status CGI (#130) reads the drift verdict file into the health rollup.
- **No** image rebuild, **no** runtime swap, **no** profile.yaml schema change.

---

## Open questions for the independent reviewer

1. **read-only off = tier-1 or tier-2?** (Decision C sub-question.) Writable rootfs as an escape vector vs. "still confined."
2. **Tier-1 immediate re-assert vs. always-grace:** is *any* automatic destructive rebuild-on-drift acceptable given F2/F3, or should even escape-class drift be alarm-only-until-human on a live node? (User chose hybrid = some auto; reviewer should pressure-test whether tier-1 auto is worth the F3 blast radius.)
3. **Interaction of the reconcile loop with procd's own `respawn`** — two supervisors; is there a cleaner single-owner structure?
4. **Is 60s / N=2 / 300s grace / R=3 the right envelope**, or should intervals be profile-declared?
5. **A1→A2 portability claim** — is the policy really runtime-agnostic, or does something bind it to docker/run.sh in a way that won't survive a Quadlet move?
