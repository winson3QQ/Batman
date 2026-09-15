# #98 — Container runtime hardening (app-agnostic, profile-driven)

SoT #75. Consumes #153 (per-tenant profile) + #81 (budgets). Independent adversarial design review: **PASS-WITH-CHANGES** (v1 REVISE→v2 PASS-WITH-CHANGES; findings folded in — see "Review" below). FTS is a **swappable example tenant**; the mechanism must not couple to it.

## Principle
FTS may be replaced (OpenTAKServer / taky, #59/#68). Confinement is therefore **generic + declarative**, driven by each app's `deploy/<app>/profile.yaml`; FTS-specifics (write paths, uid, ports, volumes, behavioural smoke test) stay in FTS's own files. Swapping the app = new profile.yaml + thin per-app run bits; the hardening machinery + drift-check are unchanged. **Thin — a flags emitter, not a payload framework.**

## Mechanism (2 generic pieces + per-app data)
- `scripts/profile-to-flags.py` (dev/CI): reads `deploy/<app>/profile.yaml` `values` → writes `deploy/<app>/<app>.hardening.env` (`HARDEN_FLAGS="…"`). **No YAML on the node.** `values` = what is actually applied (staging is operational, not encoded here); only confinement flags are emitted (app-specifics stay in run.sh).
- `scripts/check-hardening-env.sh` + `.github/workflows/hardening-env-sync.yml`: **hard CI gate** — the committed env must equal the regenerated one (`diff` exit-code) and every profile.yaml must be valid YAML. Prevents a stale env from running flags that don't match the SoT while verify still passes.
- `scripts/verify-profile.sh <app>` (node, busybox): generic drift-check — `docker inspect` must reflect the committed env, container `State.Running`, seccomp not unconfined, not privileged, no socket. Only axes present in `HARDEN_FLAGS` are asserted.
- Per-app `run.sh` sources its env and passes `$HARDEN_FLAGS`; `functional-test.sh --hardened` sources the **same** env so the behavioural test runs the real hardened runtime (its behavioural probes are inherently per-app; only the drift-check is generic).

## Staged execution (each stage a small reversible increment; verify between; old run.sh = rollback)
```
Stage 0  mechanism + reconciled numbers + verify + CI gate + cmdline-into-golden design   [no node] — THIS PR
Stage 1  enable memcg: LOCATE cgroup_disable=memory on-node first (upstream OpenMANET, not our repo yet —
         single-slot golden edit = bench expedient, wiped on reflash; A/B nodes via batman-slot CMDLINE_COMMON;
         our own image #108 bakes it), edit + REBOOT manet02 (attended, dev-node STA rescue staged) → verify
         memcg in cgroup.controllers + mesh rejoin + FTS up on old run.sh.  NO --memory cap.
Stage 1.5 record memory.current under representative client load (the input Stage 5 needs — else the cap defers forever)
Stage 2  fts low-risk axes (keep ROOT): cap-drop=ALL + no-new-priv + read-only+sized-tmpfs + --cpus + --pids
         → verify-profile.sh + functional-test --hardened + State.Running
Stage 3  fts non-root: rm -f → chown volume → --user <numeric uid> → verify. getpwuid breaks → keep root, mark planned.
Stage 4  fts-ui: cap-drop/no-new-priv/cpus/pids (+ non-root Stage 3-style); read-only after enumerating cwd write paths (own iteration)
Stage 5  set --memory cap from Stage-1.5 data
```
Destructive/restart bits = staged one-liners for the user's Git Bash. Stage 1 reboot = the one attend-required, irreversible-on-failure step.

## Honest scope (per review)
- **Part 2 (memory) is half-delivered until Stage 5**: memcg enabled + measurable ≠ an enforcing `--memory` cap. Profile `resources.memory` axis = `blocked:needs-load-measure`, not a number presented as a budget (a cap from idle data would OOM-kill FTS under first load).
- **`--network host` stays a documented exception** (mesh port binding; compensating nftables not built here).
- **fts-ui API token in env** is admin-equivalent and untouched by this issue — a named exception, not "hardened".
- Nothing is marked `implemented` until `verify-profile.sh` passes on-node AND the CI env↔profile gate is green.
- Numbers: fts `cpus=1.0/pids=512`, fts-ui `cpus=0.5/pids=128` (reconciled across run.sh/profile.yaml/#81; ~5× idle headroom, leaves ≥3 of 4 cores for batman/OS). memory deferred.

## Review (folded in)
v1 blockers: numbers↔profile drift (B1), functional-test ran an unhardened throwaway (B2), `--memory` from idle data = OOM (B3). v1 majors: cmdline durability on a reflashed golden (M1), tmpfs coverage/size (M2), staging granularity (M3). v2: hard env↔profile gate (C1), numeric uid + full tmpfs spec in the SoT not emitter-invented (C2/C6), reconcile files (C3), explicit Stage-1.5 measurement (C4), honest "half until Stage 5" wording (C5), only drift-check generic (C7), `--hardened` sources the same env (C8).
