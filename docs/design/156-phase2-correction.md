# Design: #156 Phase 2 — destructive drift correction

**Status:** DRAFT for adversarial review · **SoT:** #75 · **Depends on:** #156 Phase 1 (alarm-only reconciler, PR #188, merged) · **Milestone:** v1.1 DEV golden (dev-now)
**Parent design:** `docs/design/156-runtime-owner.md` (Phase 1/2 split, hybrid policy, review disposition).

Phase 1 detects drift and alarms; it never touches a container. Phase 2 adds **correction**: the reconciler brings a drifted container back to its profile. This is the destructive half every earlier review flagged, so it ships only behind the prerequisites below and its own review.

## 0. Verified facts feeding this design (manet01, 2026-09-18/19)
- Node is **cgroup v2 (unified)**.
- **`docker update --cpus X --memory Y --pids-limit Z` mutates a running container in place** — verified: NanoCpus 1e9→5e8, Memory 536870912→268435456, PidsLimit 512→256, `State.StartedAt` **unchanged** (no restart), container stays running. So the resource axes are genuinely correctable without downtime.
- **`run.sh` today rebuilds ALL 6 containers unconditionally** (`docker rm -f` each, then recreate) — there is no single-container path. This is why an unqualified `run.sh` is forbidden as a corrective (it re-inflicts the session-10g rabbitmq→CoT-0 outage on every event).
- Session-10g lesson: **recreating rabbitmq alone dropped CoT to 0** — the app containers' AMQP connections/topology broke and did not silently recover. So "surgical single-container" is safe for *app* containers but NOT for the *broker* without bouncing its dependents.

## 1. Prerequisites (build + verify before any correction ships)
1. ✅ **`docker update` live-mutation verified** (§0).
2. **`run.sh --only <container>` — dependency-aware surgical reconcile** (§2).
3. **keepalive ↔ procd-respawn race fix** (§3).
4. **`run.sh` health-gate returns non-zero on failure** (§4) — today its health waits `break` on timeout and it always exits 0, so the reconciler cannot tell a re-assert failed.

Only once 2–4 exist does the correction policy (§5) turn on.

## 2. `run.sh --only <container>` — surgical, dependency-aware
The corrective must rebuild the *minimum* set that restores the drifted container to profile without breaking the stack.

**Dependency model (from `profile.yaml` lifecycle.order + co_scheduled_with):**
- **App containers** — `opentakserver`, `ots_cot_parser`, `ots_eud_handler`, `ots_eud_handler_ssl`. They are AMQP/DB *clients*. Rebuilding one reconnects it to the existing broker/DB; the others are unaffected. → `--only <app>` rebuilds exactly that one.
- **Infra containers** — `rabbitmq` (broker), `ots-db` (postgres). They are depended upon. Rebuilding one drops every dependent's connection/topology.
  - `--only rabbitmq` = rebuild rabbitmq **then bounce the 4 app containers** (ordered: broker up + healthy → recreate apps) so they re-declare exchanges/queues. NOT the whole stack (ots-db is untouched — it has no dependency on the broker).
  - `--only ots-db` = rebuild ots-db **then bounce the app containers** that hold DB connections (broker can stay; it has no DB dependency). Postgres data is on a volume, so no data loss.

**Design decision A — where does the "minimum set" live?** Encode it as a small dependency table in `run.sh` (`app→{self}`, `rabbitmq→{rabbitmq}+apps`, `ots-db→{ots-db}+apps`), derived from `profile.yaml`'s `lifecycle.order`/`co_scheduled_with`. Alternative: a full topological reconcile engine — rejected as over-engineering for a 6-container fixed stack. Verdict: static table, generated/checked against the profile by CI (same pattern as `check-hardening-env.sh`).

**Design decision B — refactor `run.sh` vs a new `reconcile-one.sh`?** `run.sh` already has the per-container `docker run` blocks with `$HARDEN_FLAGS`. Factoring each into a function `up_<container>()` and adding a dispatcher (`--only X` calls the needed `up_*` in order + health-gates) reuses the exact hardened launch (single source of the flags). A separate script would duplicate the launch specs and drift. Verdict: refactor `run.sh` into functions + an `--only` dispatcher; the no-arg path still brings up all 6 in order (unchanged behavior).

## 3. keepalive ↔ procd-respawn race fix
Phase 1's reconcile loop lives inside `while docker inspect opentakserver Running; do …`. A Phase-2 corrective that does `docker rm -f opentakserver` (tier-1 on the API container) makes that `while` exit → the procd instance exits → procd respawns the whole init → its bring-up sees opentakserver down → fires a **second** `run.sh` concurrent with the in-flight corrective (F1 rebuild storm).

**Fix:** a reconcile lock. Before a corrective, the loop writes `/tmp/batman-ots-reconciling` (holding the target container name); the keepalive's liveness `while` treats "opentakserver down **while the lock is held**" as *expected* (do not exit for respawn) and waits for the corrective to finish and clear the lock. Only an *unexpected* down (no lock) exits for respawn. The lock is on tmpfs, self-expiring (holds a timestamp; a stale lock older than a bring-up bound is ignored so a killed corrective can't wedge the loop).

**Alternative considered:** don't watch opentakserver liveness at all; let procd's own respawn own liveness and the loop only do conformance. Rejected: bring-up (run.sh on cold boot) and liveness recovery are the loop's Phase-1 job; splitting owners is a bigger change than a lock.

## 4. `run.sh` health-gate must fail loud
Today each `wait` loop (`while [ i -lt N ]; … break`) falls through on timeout and `run.sh` exits 0 even if a container never became healthy. The corrective needs to know. **Fix:** each `up_<container>()` returns non-zero if its health check doesn't pass within the bound; `--only` propagates that. The reconciler then, on a failed corrective, **latches to alarm-only** for that container (stop trying, escalate) rather than looping — this is the F2/F6 safety valve.

## 5. Correction policy (the hybrid from the parent design, now wired)
Per drift, keyed by axis class (Phase-1 `verify-profile.sh` already reports per-axis):

| Class | Axes | Action |
|---|---|---|
| **Resource** | cpus, memory, pids | `docker update` in place (verified live, no downtime) + log |
| **Security tier-2** (degraded) | read-only off, no-new-privileges off, seccomp overridden | alarm immediately; correct via `--only` after a **grace window** (default 300s); per-axis opt-out to alarm-only |
| **Security tier-1** (escape) | privileged, docker-socket, cap-drop≠ALL, cap-add present, user=root, network≠ots-net | alarm + correct via `--only` **immediately** (subject to debounce + anti-flap) |

**Guards on every destructive correction:**
- **Debounce:** require **N=2 consecutive** conformance-fail ticks (and container age > MIN_UPTIME) before acting — rides out a mid-restart read. (Phase-1 already returns UNKNOWN, not DRIFT, for inspect-error/too-fresh, so debounce only has to cover genuine-but-transient mismatch.)
- **Anti-flap:** at most **R=3** corrections per container per 30-min window; then latch to alarm-only + escalate (a container that keeps drifting is a bug or an attack, not something to fight forever).
- **Ordered + health-gated:** every corrective goes through `run.sh --only` (§2), never a bare `docker run`.
- **Fail-safe:** a corrective that doesn't come back healthy → alarm-only latch, never a retry loop (§4).

**Open sub-question (for review):** is `read-only off` tier-1 or tier-2? A writable rootfs is an escape *enabler* (drop a binary), but not itself an active escape. Defaulted tier-2; challenge if wrong.

## 6. Structural alternatives to evaluate (not necessarily this PR)
- **`docker events` trigger** (`--filter event=start`): correct within sub-second of a bypass create instead of up to one reconcile interval. Adopt as the *trigger* with the periodic sweep as backstop (events can be missed during a respawn gap).
- **`daemon.json` `no-new-privileges: true`**: daemon-wide default removes that axis from policing entirely — cheap, do it regardless.
- **docker authz plugin**: reject a non-conformant create at admission (no naked window, no rebuild). Strictly stronger than detect-then-correct; overlaps #97 (admission). Record as the prod-direction; likely > v1.1.

## 7. Definition of Done (bench-verify on manet02, then manet01)
1. **Resource:** `docker update --memory 999m opentakserver` → reconciler restores 512m via `docker update`, **no restart** (StartedAt unchanged), client stays connected.
2. **Tier-1 app:** `docker rm opentakserver && docker run …` unhardened (user=root) → after debounce, `--only opentakserver` rebuilds just it hardened; rabbitmq/ots-db/other apps **untouched** (StartedAt unchanged); CoT round-trip OK after.
3. **Tier-1 infra:** an unhardened `rabbitmq` → `--only rabbitmq` rebuilds broker + bounces the 4 apps (ordered, health-gated); **ots-db untouched**; CoT round-trip OK after (proves the binding re-declare works — the session-10g failure does NOT recur).
4. **Tier-2:** `--read-only`-off container → alarm immediately, correct after grace (or stay alarm-only if configured).
5. **Anti-flap:** a container forced to keep drifting latches to alarm-only after R attempts.
6. **Race:** a tier-1 correction on opentakserver does NOT trigger a second concurrent `run.sh` (lock works).
7. **Fail-safe:** a corrective that can't get healthy latches alarm-only, no loop.

## 8. Scope boundaries (unchanged from parent)
- NOT which workloads may run (admission) → #97. NOT signed-image verify → #151. NOT trusting the on-disk profile/run.sh (integrity) → #97/#151/#137. Phase 2's guarantee: a drifted *approved* container is returned to its *specified* form, safely.
