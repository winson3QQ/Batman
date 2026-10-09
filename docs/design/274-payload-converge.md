# #274 — payload tenant converges on its config; clean stop, fast start

Status: design **v6** (2026-10-09). **§12 supersedes §11 (v5 REJECTED by two reviewers, #274 comment 6072340146)** and overrides everything earlier where they differ. Before that: design v5. §11 superseded §10 (v4 was REJECTED; its BLOCKER was confirmed on 04) and overrides §2 T3/T5, §4 and §5 where they differ. Earlier: v1 REJECTED (B1–B3, M1–M9), v2 REJECTED (N1–N10); §7 maps every finding
to its resolution. Issue: winson3QQ/Batman#274.

## 1. Problem (measured)

1. **No convergence.** dockerd runs with `live_restore=1`, OTS containers are `--restart unless-stopped`, data
   on p6. After an OTA (or any boot) dockerd revives the *old* containers; the guardian only calls `payload-run`
   when a container is not running. A manifest / MOUNT / hardening / image change delivered by the golden
   refresh never reaches the containers (04, 2026-10-07, both directions: 1.5.4 kept pre-OTA containers; a
   downgrade rc5 → 1.5.4 kept rc5's).
2. **Stop is a no-op.** `stop_service` reads `$_DIR/$_T.manifest` (= `opentakserver.manifest`); the file is
   `ots.manifest`.
3. **The first fix (feat/264) made boot slow → fi-f1 FAIL.** stop = `docker stop` + `docker rm`, so every boot
   rebuilds the whole stack.

Measured on 04 (Pi 4, OTS, 2026-10-08; times are uptime seconds unless stated):

| path | stack ready (6 running + pg_isready + `/api/health`) | notes |
|---|---|---|
| control 1.5.4: no stop, dockerd revives (T2-like) | 6 running at +63 (db/rabbit/eud +32..34; ots/parser +61..63 after 1 crash-restart each) | dockerd ready ≈ +31 |
| stop + rebuild at boot (≈ feat/264) | +94 | waits up to 15 s for procd respawn after dockerd, then 48 s rebuild |
| steady state: `docker start` in manifest order + health gates | 37 s from first start, 0 restarts | → expected ≈ +31 + 37 ≈ **+68..75** at boot |
| steady state: `docker start` all at once | 43 s, ots + parser 1 crash-restart each | |
| graceful stop, sequential `docker stop -t 20` × 6 (idle) | 11 s (≈ 2 s each) | procd: a K script gets 15 s, then TERM, +10 s, KILL |
| graceful stop, one parallel `docker stop` (idle) | 6 s | |

Note on fi-f1: its single sample is at ssh-up + 25 s of the *new* boot (ssh-up observed +49 and +78), so
shutdown length does not move it; the rebuild path (+94) misses it, the start path (≈ +70) should, with a thin
margin. **fi-f1 is NOT changed** (v2's D9 widened its effective deadline = trimming; withdrawn). If it fails
at the margin, the start path gets faster — the test does not get looser. A separate, explicit boot SLO is
added in cleanstop-274 (§6): ≤ 90 s uptime (control's +63 plus margin), value printed every run.

## 2. Field triggers

| # | trigger | K scripts? | containers at next boot |
|---|---|---|---|
| T1 | clean `reboot` / batman-slot reboot / autocommit revert by reboot / batpower low-battery poweroff | yes | what stop left |
| T2 | power loss, hardware watchdog, panic, `reboot -f` | no | dockerd revives (restart policy) |
| T3 | OTA (`sysupgrade -n`): stage2 `ubus service delete` + `kill_remaining TERM`, 4 s, KILL | **no** | dockerd (of the NEW image) revives |
| T4 | operator `/etc/init.d/batman-payload-<t> restart|stop` | stop_service | stopped |
| T5 | dockerd crash/respawn (live-restore keeps containers) | n/a | running; API briefly down |
| T6 | golden refresh changed manifest / mounted file / hardening / secret; image re-loaded with a new ID | n/a | old config |
| T7 | hand-made container under a manifest name (bypass, #156) | n/a | no/foreign label |
| T8 | downgrade / rollback to an image WITHOUT this fix (≤ 1.5.4) | depends | legacy guardian, no label check |
| T9 | MOUNT source / image missing (golden gap, `docker rmi`, partial load) | n/a | — |
| T10 | concurrent orchestrators: guardian converge vs stop_service; manual `payload-run`; F2/firstload | — | — |
| T11 | firstload holds the guardian stopped+disabled (tars remain, retried next boot, ≤ 3 boots) | — | — |
| T12 | tenant with `RESTART on-failure:N` (dummy-nginx*) | — | dockerd revives non-zero exits regardless of manual stop |
| T13 | manifest drops a container / changes SUBNET | — | orphan keeps its static IP / network subnet stale |

## 3. Design

**D1 fingerprint = what is rendered.** `payload-run` gets a *render* mode that runs the exact same manifest
parse and argv assembly as a real bring-up but executes nothing. It has no side effects: the SECRET chown is
skipped, and HARDEN files are no longer *sourced* anywhere — payload-run *parses* the single
`HARDEN_FLAGS="…"` line (CI §4c enforces that a hardening file is only comments + that one line), so neither
the 30 s tick nor a bring-up executes tenant-supplied shell. `payload-run --cfg-hash <t>` = sha256 over:
`cfg-v2` · the manifest bytes (header + comments, so a test can change the hash harmlessly) · per container
the full rendered `docker run` argv (minus the labels) · that IMAGE's local image ID (missing → `MISSING`) ·
the **content** sha256 of every *relative* file source (HARDEN, MOUNT src, SECRET; missing → `MISSING`) · an
*absolute* MOUNT source by path + type only (a live file must not cause eternal drift).
Owner/mode are NOT hashed (v2 hashed them and fought payload-run's own secret chown → rebuild loop on
dummy-nginx-b, N2). Instead the desired secret owner/mode (`chown <uid>; chmod 0400`) is **enforced** in both
start mode and rebuild, before the container starts. Relative MOUNT/HARDEN files are never chowned by
payload-run, so nothing to enforce there.
Every container gets `--label batman.cfg=<hash>` and `--label batman.tenant=<t>`.

**D2 one owner, one lock (busybox).** busybox `flock` has only `-sxun` and there is no `timeout` applet, so the
lock is `exec 9>/tmp/batman-payload-<t>.lock` + a `flock -n 9` poll (1 s steps). payload-run writes its PID to
`/tmp/batman-payload-<t>.pid` once it holds the lock. Docker CLI children are started with fd 9 closed
(`9>&-`): the lock belongs to the payload-run process only, so killing it frees the lock at once.
Modes:
- `payload-run <t>` — rebuild (bench/manual; unchanged meaning). Lock wait ≤ 600 s, then exit 1 ("busy").
- `payload-run --converge <t>` — guardian: every manifest container exists AND label == hash → **start
  mode**; else **rebuild**. The ONLY mode that honours `/tmp/batman-payload-<t>.stopping` (checked before and
  again after taking the lock, and before each container), and it logs loudly when it does.
- `payload-run --start-only <t>` — firstload (T11): start mode if labels match, else do nothing (exit 3);
  ignores `.stopping`.
- `--cfg-hash` takes no lock (read-only).

**Start mode**: header pass + network check + fw4 apply as today; secret owner/mode enforced; then in manifest
order: `docker start` unless already running (a restarting one is just waited on), then that container's HEALTH
gate (same 120 s budget as rebuild). No rm, no prechown. A container whose `docker start` fails is skipped and
the rest are still started and gated; at the end, if any failed → rebuild (behind the preflight). If that
preflight fails, whatever start mode brought up stays up (verdict DRIFT). A health-gate timeout → exit 1, no
rebuild (a rebuild does not cure a slow app and would destroy a working one).

**Rebuild**:
1. **preflight — one rule: any problem refuses the WHOLE rebuild before anything is touched** (exit 1 with the
   reason; the running stack, if any, is left as it is; verdict DRIFT): an IMAGE not present locally; a relative
   MOUNT source not a regular file; a HARDEN file missing, unreadable or not in the one-line format (today a
   missing one silently runs the container *unhardened* — a #156 confinement hole, closed here for both modes);
   the network exists with a different SUBNET or bridge name (**not** auto-recreated: a foreign endpoint or the
   arbiter's `.net.alloc` could strand the stack — operator action, reason logged). This replaces feat/264's
   "skip only the container with a bad MOUNT": CI §4a guarantees every mounted file is in the golden, so a
   missing one is a broken install, and refusing before removal keeps a running stack running.
2. graceful removal: `docker stop -t 10` of all manifest containers + all containers labelled
   `batman.tenant=<t>` that the manifest no longer lists (T13 orphans), then `docker rm` (never `-v`: anonymous
   volumes and named volumes are kept; containers from before this fix carry no tenant label and are not
   collected). No `rm -f` on a running container anywhere (postgres is never SIGKILLed by a rebuild).
3. per container as today (conditional prechown kept from feat/264, `--mount` per D5, labels per D1).

**D3 guardian.**
- bring-up: `_need` if any container is not (`running`, `Restarting false`, label == hash) → `payload-run
  --converge` (converging latch for batman-autocommit kept).
- waits for dockerd inside the instance (poll 2 s, ≤ 90 s) before exiting for respawn (removes the 15 s
  respawn quantum).
- keepalive/reconcile loop tolerates the API being down (T5): `docker info` failing → sleep and retry for up to
  120 s, never exit merely because dockerd restarts; exit for respawn only when docker is up and PRIMARY is
  absent or not running.
- tick (alarm-only, #156 Phase 1): (a) `RestartCount` grew vs the previous tick for the same container ID →
  DRIFT "restarted n×" (baseline taken at the first tick after bring-up and whenever the ID changes, so a boot
  revival's crash-restart never blips the autocommit gate); (b) label != current hash → DRIFT "config changed
  since start — restart the guardian to apply". (b) can only fire on a mid-run operator edit: the golden
  refresh runs at S11, before the guardian converges.

**D4 stop = graceful, two-phase, no rm, recorded, raced safely.**
- touch `/tmp/batman-payload-<t>.stopping`; if `/tmp/batman-payload-<t>.pid` names a live payload-run: TERM its
  direct children (`pgrep -P`, i.e. in-flight docker CLIs) and it, wait ≤ 1 s, KILL what is left. No lock
  wait (fd 9 is not inherited, so the lock dies with the process). dockerd finishes or aborts any request the
  killed CLI had sent; whatever that request started is caught by the final sweep below.
- **phase 1** — clients: `docker stop -t 3` (parallel) of the containers WITHOUT a HEALTH line. **phase 2** —
  services: `docker stop -t 10` (parallel) of the containers WITH a HEALTH line. Contract (documented in
  167-payload-manager.md): a container that others depend on declares HEALTH — it already must, to gate their
  bring-up. A tenant with no HEALTH at all gets one phase with `-t 10`. OTS: phase 1 = parser, eud, eud_ssl;
  phase 2 = opentakserver, rabbitmq, ots-db.
- **final sweep**: any manifest container still running (started by an in-flight request) → `docker stop -t 3`.
- Budget: ≤ 1 + 3 + 10 + overhead ≈ 14.5 s < procd's 15 s in the worst case; postgres gets 10 s. Measured
  under CoT load before shipping (§6). If the measurement shows phase 2 needs more, the stop is split into two
  K scripts (each gets its own 15 s) — decided on data, not guessed.
- record (only if docker is reachable and p6 mounted): one line `boot_id tenant elapsed name=ExitCode …`
  appended to `/opt/batdata/log/payload-stop.log` AND sent to `logger -t batman-payload-<t>` (so it is in the
  `shutdown_*.log` that K10batdata-mount captures). Docker unreachable → no record (firstload's S95 stop runs
  before dockerd and writes nothing).
- `start_service` removes the `.stopping` flag (it is in /tmp: a crash/reboot clears it too).
- Guardian stub `STOP=09` (was 10): runs BEFORE `K10batdata-mount` captures the shutdown log/marker
  (batman-faketime uses 09 for the same reason; K09batman-faketime sorts before K09batman-payload).
  `restore_payload_guardians` removes every `S??/K??batman-payload-<t>` link whose number differs from the
  stub's START/STOP before `enable` (rc.common `enable` never removes old links). A legacy image re-adding K10
  → stop runs twice; the second finds nothing running and writes no record.

With `unless-stopped` (OTS), `docker stop` sets the manual-stop flag so dockerd does not revive at the next
boot; the guardian's start mode does, ordered and gated. With `on-failure` (T12) dockerd may revive a
non-zero exit itself; start mode then just waits on it (start on a running container is a no-op). The model
does not depend on which.

**D5 MOUNT via `--mount type=bind`** (kept): `-v` silently creates a missing source as an empty root-owned
directory, which also blocks the golden refresh. 95-batman-storage removes such a stray empty directory
(`rmdir` only).

**D6 golden prune — only what golden installed, never the identity files.** The refresh records the golden
file list in `$dst/.golden-files` (written to a tmp + `mv`). On a later refresh a file is removed only if it
is in the OLD list, absent from the new golden, a regular file, not under `secrets/`, and not `*.manifest` /
`*.init`; and only when the new golden itself contains a `*.manifest`. A trial slot's prune is undone by a
revert: the old slot's refresh re-copies every golden file missing on p6 (manifest/init are never pruned, so
the refresh gate still opens). No list yet → prune nothing: files left by images before this fix (e.g. 04's
`EudHandler-264.py`) stay — inert (not mounted by any manifest, not executed by any glob). Why prune at all: the
guardian executes `*.fw4.uci`, `verify-profile-*.sh`, `reconcile-resources.sh` by glob, so a stale one is not
inert. Known residue: rules a pruned `*.fw4.uci` once committed stay in `/etc/config/firewall` until the slot's
overlay is reset by the next A/B flash (fw4 rules are per tenant zone; no prune of uci state here).

**D7 CI.** `check-payload-manifest.sh` §4a: every relative MOUNT source in a committed manifest is installed
into the payload golden by the Makefile; `payload-manifest-sync` workflow triggers on `payload-run` and the
guardian. Offline white-box `scripts/test-payload-run.sh` (docker stub on PATH, run in that workflow):
start mode vs rebuild decisions, start failure → others still started then rebuild, preflight failure (image /
mount / hardening / network) → nothing removed, rebuild never issues `rm -f` on a running container, secret
*content* changes the hash and a payload-run secret chown does NOT (N2 regression test, dummy-nginx-b
shape), an absolute MOUNT source's content does not, `-v` never used for MOUNT, orphan removal by tenant label
without `-v`, lock exclusion, `.stopping` honoured only by `--converge`, CLI children started with fd 9
closed. §4c: every `*.hardening.env` in deploy/ is comments + exactly one `HARDEN_FLAGS="…"` line.

**D8 firstload (T11).** When tars remain and the guardian stays down, firstload runs `payload-run
--start-only <t>` (which ignores the `.stopping` flag firstload's own `stop` just set): an unchanged stack
comes back (as dockerd's revival did before), a changed one waits for the guardian as today.

(v2's D9 — loosening fi-f1 — is withdrawn; see §1.)

## 4. Behaviour per trigger

| trigger | result |
|---|---|
| T1 | two-phase graceful stop (recorded, before the shutdown capture) → boot: start mode, no rebuild |
| T2 / T3 unchanged config | dockerd revives in parallel; guardian sees running + label → nothing, or start mode waits |
| T3 changed config | old labels → preflight → graceful rebuild once (autocommit revert deferred by the latch) |
| T4 | lock-safe stop → start mode |
| T5 | instance survives the API gap; containers untouched |
| T6 | next guardian start → rebuild; while running, DRIFT "config changed" |
| T7 | no/foreign label → rebuild (anti-bypass kept; a forged label needs root, out of scope) |
| T9 | preflight fails → running stack untouched, DRIFT with the reason |
| T10 | payload-runs serialized by the lock; stop kills an in-flight one (and its CLI children), then stops + sweeps |
| T11 | `--start-only` brings an unchanged stack back |
| T12 | revived or started — either way running, label checked |
| T13 | orphans removed by tenant label (no `-v`); a SUBNET/bridge change is refused by preflight (operator action, logged) |

## 5. Limits (stated, not hidden)

- **T8 downgrade below this fix**: the legacy guardian never compares config and its stop is a no-op. After a
  T1 reboot *from a fixed image* the containers are stopped, so the legacy guardian (rebuilds anything not
  running) converges them. After T2/T3 into a legacy image they are revived and stay newer-config until an
  operator runs `payload-run <tenant>`. Legacy code cannot be changed; the window closes once nothing below
  this version can be booted.
- **T3 OTA is not a graceful stop**: stage2 bypasses K scripts and runs `platform_pre_upgrade` only after
  `kill_remaining` (stage2:157–166). Stage-1 `platform_check_image` also runs for `sysupgrade -T` / LuCI
  validation, so stopping there would leave the tenant down after an aborted upgrade. The only clean option is
  a batman OTA wrapper that stops tenants before `sysupgrade` and restarts them if it fails — there is no
  single OTA entry point today (host scripts, LuCI, manual). Postgres does WAL crash recovery after an OTA
  (designed-safe). Recorded on #274 as an explicit decision.
- `docker update` on a running container does not change its label; resources are `reconcile-resources.sh`'s.

## 6. Validation (daily-validation + measurements before the PR)

- `payload-conform` (non-destructive): every container running, not restarting, labels batman.cfg == hash and
  batman.tenant == t; every MOUNT present with source + RO/RW as declared, source a regular file; no container
  labelled for the tenant outside the manifest.
- `cleanstop-274` (destructive tier, OTS node): record container IDs → plain reboot → assert: (1) a
  `payload-stop.log` record for the previous boot_id, every ExitCode ∈ {0, 130, 143}, elapsed ≤ 15 s, and the
  record is in that boot's `shutdown_*.log`; (2) ots-db "shut down at" (no recovery); (3) same container IDs
  (not recreated); (4) the guardian logged "start mode" this boot and StartedAt is non-decreasing in manifest
  order; (5) boot-to-ready (6 running + pg + api) ≤ 90 s uptime (control: 6 running at +63), value printed.
  Negative controls: `DV_TEST_274_NOSTOP=1` (K link removed) must FAIL (1)/(4); `DV_TEST_274_RMSTOP=1`
  (stop that also removes, feat/264-style, injected via a one-shot flag the stop honours only under test) must
  FAIL (3).
- `converge-274` (destructive tier, no reboot): guardian restart with no change → same IDs; append a comment
  to the p6 manifest → restart → all recreated, new label, verdict OK; append a comment to the mounted
  `rabbitmq-extra.conf` (real MOUNT-content case) → restart → recreated; restore both from golden → restart →
  recreated with the original label; ots-db log shows no recovery across all rebuilds (graceful rebuild, M1).
- Stop budget under load: cleanstop-274 is run once with the CoT generator running against 8088 during the
  reboot; ExitCodes and elapsed recorded in the PR.
- Offline `scripts/test-payload-run.sh` in CI; fi-f1 unchanged, must PASS.

## 7. Review v2 → v3

| finding | resolution |
|---|---|
| N1 busybox flock has no `-w`, no `timeout` | D2 `flock -n` poll; payload-run lock wait ≤ 600 s → exit 1; stop takes no lock at all |
| N1b stuck/long holder blocks stop | D2 CLI children run with fd 9 closed; D4 TERM children (`pgrep -P`) + payload-run, ≤ 1 s, KILL, final sweep |
| N2 secret owner/mode in hash → rebuild loop | D1 content only; owner/mode enforced in both modes; regression test in D7 |
| N3 stop > 15 s; postgres 6 s; HEALTH heuristic | D4: no lock wait; phase 1 `-t 3` clients (no HEALTH), phase 2 `-t 10` services (HEALTH) = documented contract; ≈ 14.5 s; split into two K scripts if load data says so |
| N4 `--start-only` dead (flag) | D2: only `--converge` honours `.stopping`; manual and `--start-only` ignore it; early exit logged |
| N5 network recreate strands stack | D2 preflight refuses a SUBNET/bridge change — no auto-recreate |
| N6 D9 loosens fi-f1 | withdrawn; fi-f1 unchanged; separate SLO ≤ 90 s in cleanstop-274 (stricter than v2's 120) |
| N7 preflight inconsistent; HARDEN missing runs unhardened; start-mode partial | D2: one rule (refuse whole rebuild), HARDEN checked; start mode starts all it can before falling through |
| N8 orphan rm data | D2 step 2: no `-v`; unlabelled pre-fix containers not collected (stated) |
| N9 stale K links | D4: remove every mismatching S??/K?? link; double stop harmless |
| N10 render sources HARDEN | D1: HARDEN parsed, never sourced; CI §4c format check |
| M4 gap: record not in shutdown log | D4: also `logger` |
| B3 residue fw4 rules | D6 known residue stated |

## 7a. Review v1 → v2

| finding | resolution |
|---|---|
| B1 fi-f1 | §1 note (sample is relative to the new boot's ssh-up), estimate +68..75; D9 explicit SLO poll |
| B2 stop vs converge race, concurrency | D2 lock + `.stopping` flag; D4 TERM payload-run, `flock -w 8`, then stop |
| B3 prune deprovisions | D6: never manifest/init, only with a manifest in the new golden, atomic list, revert-safe; motivating stale file explicitly NOT pruned (inert) |
| M1 rebuild SIGKILLs postgres | D2 rebuild step 2: `docker stop` before `rm`, never `rm -f` on running |
| M2 rebuild without preflight | D2 rebuild step 1 |
| M3 hash ≠ rendering; owner/mode; absolute sources; orphans | D1 render mode; owner/mode; absolute = path+type; `batman.tenant` label + orphan removal |
| M4 K ordering | D4 STOP=09 + stale K10 cleanup |
| M5 stop budget under load; dependents first | D4 two phases; §6 load measurement |
| M6 firstload dark stack; bogus stop records | D8 `--start-only`; D4 record only when docker reachable |
| M7 on-failure tenants | D4 last paragraph; T12 |
| M8 tests don't discriminate | §6: ExitCode, container IDs, start-mode log + order, RMSTOP control, real MOUNT case |
| M9 T5 row wrong | D3 keepalive tolerates API gap |
| minor RestartCount reset / gate blip | D3(a) baseline per ID, first tick after bring-up |
| minor D3(b) feeds autocommit | D3(b): only mid-run operator edits can fire it — accepted, it IS drift |
| minor T3 wrapper alternative | §5 |
| minor SUBNET change | D2 rebuild step 3 |
| minor start mode header/fw4; conditional prechown | D2 start mode; rebuild step 4 |
| minor low-battery stop length | T1 includes it; bounded ≈ 11 s by D4 |

## 8. v3.1 — review v3 verdict APPROVE-WITH-CHANGES; these override §3 where they differ

| finding | change |
|---|---|
| P1 `--start-only`/manual ignore `.stopping` → can undo a shutdown stop | **every** mode honours `.stopping` (before/after lock, before each container). firstload removes the flag *synchronously in its S95 `boot()`*, right after its own `stop` — never later — so a shutdown that sets it afterwards is honoured by its loader too. Only `start_service` (and firstload's S95) clear it. |
| P2 stale pid file / PID reuse; grandchildren | stop kills only if the lock is HELD (`flock -n` fails) AND `/proc/$pid/cmdline` contains `payload-run` and the tenant; kills the whole tree (recursive `pgrep -P`), waits ≤ 1 s for the PIDs to be gone, then the sweep runs last. |
| P3 HEALTH ≠ service (opentakserver is a DB client) | explicit `STOPTIER <n>` per container in the manifest, from `stop_tier:` in profile.yaml (profile-to-manifest.py; CI sync check). Default (absent) = the final tier. OTS: tier 1 = parser, eud, eud_ssl; tier 2 = opentakserver; tier 3 = rabbitmq, ots-db. dummy-nginx*: single container, final tier. Test criterion: ExitCode 137/255 on a **final-tier** container = FAIL; on earlier tiers = reported, not failed. |
| P4 no budget margin | split the stop over two K scripts, each with procd's own 15 s: new image-baked `batman-payload-prestop` (STOP=08, plain rc.common, iterates every provisioned tenant): sets `.stopping`, kills an in-flight payload-run tree, stops all tiers except the final one (each tier parallel, `-t 5`). Guardian stub K09: final tier `docker stop -t 12`, sweep `-t 1`, then ONE batched `docker inspect` for the ExitCodes, record (`payload-stop.log` + `logger`). Each script ≤ ~13 s. T4 operator `stop` runs the full sequence itself (no procd deadline there). |
| P5 preflight refusal after T1 leaves tenant dark | `--converge`: if preflight refuses and the manifest containers exist → start mode on the OLD config, verdict DRIFT with the reason ("converge refused: …"). A SUBNET/bridge change is applied only by the explicit `payload-run --renet <t>`, which refuses while any non-tenant endpoint is attached or the subnet differs from `*.net.alloc`. |
| P6 lock fd hygiene | payload-run's lock holder is a thin wrapper: it takes the lock and runs the worker (`payload-run --worker …`) with fd 9 closed, then waits; killing the wrapper's tree frees the lock immediately. |
| P7 | as P1: only `start_service` / firstload-S95 clear `.stopping`. |
| HARDEN parse vs `verify-profile.sh` source | both use the same quote stripping; test-payload-run compares the parsed value to a sourced one for every committed hardening file. Rationale for parse = determinism (the guardian still runs tenant `*.fw4.uci`/verify scripts by design). |

## 9. v3.2 — start mode in two phases (D2'), after the rc's full validation

**Why.** rc 1.5.5-wsl.6 full validation: fi-f1 still FAIL. Start mode (D2: manifest order, every container
behind its gate) put the three CoT clients behind the opentakserver API gate; "converge done" at +76 s, and F1
samples `docker ps ≥ 6` at ssh-up + 25 s (~+70..75). Measured on 04 (steady state, twice):

| start order | 6 running | API ready | restarts |
|---|---|---|---|
| D2: one by one, each gated | 37 s | 37 s | 0 |
| **D2': final tier parallel + gated, then the rest at once** | **20 s** | 38 s | 0 |

**D2'.** Start mode = phase A: `docker start` every final-stop-tier container (no STOPTIER) in parallel
(each in the background, every exit status collected with `wait <pid>`), then their HEALTH gates; re-check
`.stopping`; phase B: start all the rest at once, then their gates. Rebuild is unchanged (strict order).
A phase-A failure (start or gate) still runs phase B — skipping it guarantees an outage, while the clients'
restart policy backs off until the services are up (what dockerd's own revival did) — with FAILED=1 (DRIFT);
a start failure then falls through to the preflighted rebuild. Contract: 167-payload-manager.md §4.5
(final tier = independent stateful services; everything else depends only on them; intermediate stop tiers
order the stop only).

**Review (4th round, APPROVE-WITH-CHANGES) → done:**

| finding | resolution |
|---|---|
| C1 the "clients don't need the API" claim rests on 2 samples | cleanstop-274 check 6: RestartCount 0 for all six, and a peer sends one CoT the moment 8088 accepts after the reboot — must be stored; reports whether it was before the API gate. Run ≥ 5 times before merge. |
| C2 phase-A failure unspecified | phase B still runs, FAILED=1, start failure → preflighted rebuild; offline test 17 (service gate timeout → rest started, rc 1, nothing removed) |
| C3 tier meaning | 167 §4.5: intermediate tiers order the stop only |
| C4 busybox parallelism | background starts + `wait <pid>` per container; `.stopping` re-checked between phases; the stop's tree kill covers the background jobs (children of the worker) |
| C5 F1 counted restarting containers | fault-injection `ots_up` counts `status=running` only (stricter) |
| C6 dwait | not back within 300 s → FAIL, not SKIP |
| C7 27.9 s stop record | that boot was fi-r1's runc-broken trial (docker cannot stop cleanly without runc); the record now carries k08= / k09= per script, cleanstop asserts each < 15 s |

## 10. v4 (2026-10-09, #274 reopened): ordered start after an OTA too — stop the tenant gracefully in stage 2

### 10.0 Reality check (04, 1.5.6-wsl.2)

On every OTA boot, opentakserver and ots_cot_parser **crash-restart once** (RestartCount=1).

Evidence:
- the opentakserver log has a `pika.BlockingConnection` traceback;
- the verify log of a captured held trial: `container opentakserver restarted 1x`, `ots_cot_parser restarted 1x`.

Why:
1. sysupgrade never stops the containers (§5 T3).
2. On the new slot, dockerd (`unless-stopped`) revives all six at once, before the guardian runs.
3. The ordered two-phase start (§D2') never happens; the apps race rabbitmq.

Effects:
- a false `confinement DRIFT detected` alarm on every OTA;
- commit delayed by one guardian tick (30–40 s);
- post-OTA healthy-window tests become timing-sensitive (#265 canonical fi-r4 FAIL, 2026-10-08).

A normal reboot is unaffected: K08/K09 stop the tenant and the guardian's start mode runs.

### 10.1 What §5 missed

`lib/upgrade/stage2` line 18 runs `include /lib/upgrade`, which sources every `/lib/upgrade/*.sh` of the OLD image's rootfs. That happens **before** the `ubus call service delete` loop (line 150) and before `kill_remaining`.

Top-level code in a file there therefore runs while dockerd and the tenant are still alive, and only on the real upgrade path:
- stage 1 (`sysupgrade -T`, LuCI validation) runs `/sbin/sysupgrade`, which does not run stage2;
- stage2 runs only after `ubus call system sysupgrade` has committed to the upgrade.

So the objection in §5, "stopping in stage 1 leaves the tenant down after an aborted upgrade", does not apply.

### 10.2 Design

**D10a — the stop hook.** New `/lib/upgrade/zz-batman-payload-stop.sh` (installed by the feed; no clash with a base file). At include time, it acts only when **all** of these hold:
- `[ "${0##*/}" = stage2 ]`;
- `$IMAGE` is set;
- `/usr/lib/batman/payload-stop.sh` is readable.

It then runs, for every tenant with a manifest, the same path as a clean reboot:
- `pstop_early` (client tiers, `-t 5`);
- then `pstop_final` (services, `-t 10`, sweep).

This sets docker's manual-stop flag, so the new slot's dockerd does **not** revive them. The guardian's start mode then starts the stack ordered and gated, and postgres starts from a clean shutdown (this also closes §5 T3).

The stop record line gets `via=stage2`.

**Bounded:**
- each `docker stop` has its own `-t`;
- the whole hook runs under a watchdog subshell that kills it after 40 s;
- the upgrade then continues regardless. A hook that misbehaves never blocks an OTA; at worst we are back to today's behaviour.

**Failure of the upgrade after the stop.**
- stage2 never returns to the old system; it always ends in `reboot -f`.
- On an apply failure, the node reboots onto its untouched committed slot. Containers stopped with the manual-stop flag are then started by the guardian's start mode, which is the same as after a clean reboot.
- Nothing is left down.

**D10b — guardian: first-tick restarts after boot are start-up, not drift.**
- For containers that dockerd revived **with no stop record for this boot** (an OTA from an image without D10a, or an unclean boot), the RestartCount baseline is taken from the first tick *after* converge, not from the container's age.
  - Today the baseline is empty on the first tick, so the restart is counted only on the second tick. The crash itself happened before the first tick.
- **Not changed:** a crash loop **after** the first tick still alarms (D3a).
- The verdict on the first tick stays honest:
  - a container that is down → DRIFT;
  - restarts that happened before the guardian started → logged as `start-up restarts N (revived by dockerd, no ordered start)` in the verify log;
  - those restarts are not a DRIFT verdict.

**D10c — daily-validation.**
- `ota-start-274` runs on the OTS host: a hold-commit OTA of the same build. It asserts:
  1. a stop record with `via=stage2`, written by the OLD slot before the reboot;
  2. on the trial, `start mode:` in the log (not dockerd revival);
  3. RestartCount=0 for all six containers;
  4. no `confinement DRIFT detected` this boot;
  5. postgres `database system was shut down at`.
- It then releases the trial.
- **Negative control:** with the hook file renamed (`DV_TEST_274_NOHOOK=1`), checks 1–3 must FAIL.

### 10.3 Alternatives
- **Restart policy `no` + guardian owns every start:** this removes dockerd revival entirely, but then the guardian has to restart every crashed non-primary container itself. That is a larger change of the supervision model; it remains an option if D10a fails.
- **A batman OTA wrapper:** there is no single entry point (§5); D10a sits under every entry point.
- **Only D10b (cosmetic):** the crash and the WAL recovery stay. Rejected as the fix; kept as defence for OTAs from images without D10a.

### 10.4 Risks
- `include /lib/upgrade` also happens in other contexts that source the upgrade libs (e.g. `/sbin/sysupgrade` itself, `fwtool`). The `$0 = stage2` + `$IMAGE` guard limits the hook to the real stage 2. Proof: a grep of every `include /lib/upgrade` / `. /lib/upgrade` caller in the image, plus a negative check that `sysupgrade -T` leaves the tenant up.
- **Order with the other `/lib/upgrade/*.sh`:** `zz-` sorts last. Our `platform.sh` override only defines functions, so the hook does not depend on it.
- **Time budget:** stage 2 has no procd 15 s limit (it is not a K script). The hook's 40 s cap plus the existing stop budgets (K08 ≈6 s, K09 ≈2.5 s measured) apply.

## 11. v5 (2026-10-09): one owner for the tenant lifecycle; stop it before procd's service_stop_all

**v4 (§10) is REJECTED and superseded.** Review v4's finding 1 (BLOCKER) was confirmed on 04 by a stage-2 probe. The probe also found a bigger, older error. §1, §2 T3/T5, §5, and three places in code and docs all rest on it.

This section is written against `docs/design/REVIEW.md`. The reviewer reviews the WHOLE document. Where §11 differs from §2, §4, §5 or §10, §11 wins.

### 11.0 Evidence (reality check, all on 04 = Pi 4, 1.5.6-wsl.2, OTS tenant)

| # | fact | evidence |
|---|---|---|
| E1 | **live-restore has never been on.**<br>• `uci dockerd.globals.live_restore='1'` is set (`99-batman-payload-docker:39`), but the stock `/etc/init.d/dockerd` does not map it.<br>• The init maps only these options into `/tmp/dockerd/daemon.json`: data_root, log_level, iptables, ip6tables, log_driver, bip, registry_mirrors, hosts, dns, ipv6, ip, fixed_cidr(_v6), proxies, storage_driver.<br>• It also supports `alt_config_file`. | `docker info` → `Live Restore Enabled: false`. The generated daemon.json is `{data-root, log-level, iptables:false, ip6tables:false}`. Source: `/etc/init.d/dockerd:166-217`. |
| E2 | procd handles `ubus call system sysupgrade` in this order:<br>1. `validate_firmware_image_call(path)`;<br>2. reject if the image is invalid and not forced;<br>3. `service_stop_all()`;<br>4. `sysupgrade_exec_upgraded()`. | procd `system.c` (2026.03.14~c59f2d80), sysupgrade handler, about l.785–823 |
| E3 | `service_stop_all()` sends `instance_stop(halt)` (SIGTERM) to every instance of every service at once. It then calls `sleep(max term_timeout)`: an unconditional sleep for the LARGEST `term_timeout` of any instance (default 5 s, `instance.c:1621`). The KILL timer never fires, because procd is blocked in `sleep()` and then execs `upgraded`. | `service/service.c:677-702` |
| E4 | `validate_firmware_image` `include`s `/lib/upgrade` and calls `platform_check_image "$1"`. That function is ours (`platform-ab.sh:49`, installed as `/lib/upgrade/platform.sh`).<br>It runs as a separate process with `$0=/usr/libexec/validate_firmware_image`. It is called from stage 1 (`/sbin/sysupgrade`) and from procd (E2), so it runs on EVERY path into a sysupgrade, including a direct `ubus call system sysupgrade` and `--force`. | `/usr/libexec/validate_firmware_image` on 04; E2 |
| E5 | Probe at the stage-2 `include /lib/upgrade` (B→A OTA):<br>• the dockerd pid is still present, but the API is dead (`docker info rc=1`);<br>• procd is gone (0 ubus objects);<br>• postgres has already exited, and rabbitmq got SIGTERM at that same instant (container logs, 14:49:43.795).<br>`Commencing upgrade` was 14 s earlier. | #274 comment 6071717554 |
| E6 | Without live-restore, dockerd's own shutdown (on procd's TERM) stops every container at once, in no order. It does NOT set the manual-stop flag. So `unless-stopped` revives all six together when the next dockerd starts, and `opentakserver` + `ots_cot_parser` each crash once (pika connects before rabbitmq is up).<br>Reproduced on both OTAs of 2026-10-09. | `docker inspect` after each OTA: `RestartCount` = 1 on those two, 0 on the other four |
| E7 | The guardian's DRIFT rule ("RestartCount grew since the previous tick") turns E6 into a false DRIFT on the first verdict after every OTA boot. autocommit gates steady-state tenants on drift (`batman-autocommit:12-15`). | fi-r4 printed `@121s drift=DRIFT why=[payload opentakserver: drift not OK]` (canonical run #2 log) |
| E8 | A clean stop (T1: K08/K09) uses `docker stop`, which sets the manual-stop flag. The next boot's dockerd therefore does NOT revive the containers; the guardian's ordered start does, with 0 restarts. So the ordered start already works whenever the stop went through us. | §8/§9, cleanstop-274 |
| E9 | Docker's own guidance: don't combine container restart policies with a host-level process manager for the same container, because they conflict. Today both dockerd (`unless-stopped`) and the guardian start the containers.<br>`unless-stopped` was chosen in #206 because `on-failure:5` gave up during the reflash dependency race. The guardian's gated start (§9) has since removed that race. | Docker docs "Start containers automatically"; `deploy/ots/profile.yaml:128-132` |
| E10 | The node has no `docker compose` (`docker: 'compose' is not a docker command`). Pi 3 (03) also runs dockerd, with no tenant. | 04, 03 |
| E11 | Statements that are wrong and must be corrected:<br>• `payload-guardian.sh:83`: "live-restore keeps the containers";<br>• §1 item 1 and §2 T5 of this doc;<br>• `167-payload-manager.md:473`: "OTS survived via live_restore=true" (it was the restart policy);<br>• `payload-run:26`;<br>• `payload-stop.sh:10-11`;<br>• `batman-autocommit:8`: "unless-stopped containers … come up under ANY rootfs" (true today, false after D5-1). | grep |

### 11.1 Ownership (who may change what)

**Container running/stopped state**
- Owner today: the guardian, AND dockerd (`unless-stopped`), AND dockerd's shutdown.
- Owner in v5: **the guardian only**, with restart policy `no`. The guardian acts through start mode, restart-on-exit and stop_service. Two other stop paths share its code through `payload-stop.sh`: K08 prestop and the dockerd wrap (D5-3).
- Readers: autocommit, halow-status, tests.

**Container existence and config (create / rm)**
- Owner: `payload-run`, called only by the guardian, firstload and the operator. Unchanged.
- Reader: the guardian (cfg hash).

**Tenant manifest on p6**
- Owner: the image golden (the 95-batman-storage refresh). Unchanged, except that the RESTART line changes.
- Readers: payload-run, payload-stop, the guardian.

**The dockerd process**
- Owner: procd, through `/etc/init.d/dockerd`. In v5 procd runs it through the wrap (D5-3).
- Readers: everyone.

**dockerd config (daemon.json)**
- Owner: `/etc/init.d/dockerd`, built from uci `dockerd.globals`.
- Today the uci `live_restore` value is silently dropped. In v5 the init maps `live_restore` (D5-2), and the guardian verifies that the value is actually in effect.
- Reader: dockerd.

**"An upgrade is imminent"**
- Doesn't exist today. In v5, `platform_check_image` (ours) writes it as the D5-3 marker.
- Reader: the dockerd wrap.

**Drift verdict**
- Owner: the guardian. In v5 it follows the D5-4 semantics.
- Readers: autocommit, halow-status, fi-r4.

### 11.2 Design

**D5-1 Restart policy `no` for every tenant container; only the guardian starts one.**
- The OTS manifest gets `RESTART no`: profile.yaml says `restart: "no"`, rendered by profile-to-manifest. The dummy-nginx tenants change the same way, so T12 disappears: no restart policy can override a manual stop any more.
- The policy is part of the rendered argv, so the cfg hash changes. That means one rebuild on the first v5 boot, through the T6 path that is already supported.
- A downgrade costs one more rebuild, because the older golden writes its own RESTART line back (T8).

Effects:
- After T2 (power loss) and T3 (OTA), no container comes up by itself. The guardian's start mode brings them up services-first and gated (§9). The E6 race is gone by construction, not suppressed.
- A crashed container stays exited until the guardian restarts it (D5-4).

**D5-2 live-restore made real, and verified.**
- Patch the dockerd init (`feeds/packages/utils/dockerd/files/dockerd.init`, in the firmware board patches for both boards). The patch maps `config_get_bool live_restore globals live_restore 0` to `json_add_boolean "live-restore"`. It is small and could go upstream.
- With it, a dockerd restart or crash (T5) leaves the containers running, and the new dockerd re-attaches to them.
- The guardian checks at every start that `docker info -f '{{.LiveRestoreEnabled}}'` equals the uci value. If not, it publishes DRIFT `dockerd live-restore not effective`, so E1 can never come back silently.
- No path in §11.3 depends on live-restore for correctness. It only removes an outage on T5.

**D5-3 Stop the tenant at the last moment dockerd is fully alive: a procd wrap around dockerd.**

The marker:
- `platform_check_image` (E4) writes a marker `upgrade-imminent` containing `<uptime>`. It writes it on entry, whatever its verdict, so `--force` is covered.
- The marker goes into the root-only run dir (`/tmp/run/batman`, 0700 root), which is the #280 design. #274 lands a minimal `usr/lib/batman/rundir.sh` and #280 then extends it, so there is ONE definition.

The wrap:
- The dockerd procd instance command becomes `/usr/lib/batman/dockerd-wrap /usr/bin/dockerd <args>`, with `procd_set_param term_timeout 45`. Both changes are in the same init patch as D5-2.
- The wrap starts dockerd as its child and forwards HUP, INT and QUIT.
- On TERM it decides between two cases:
  - **The marker exists, passes the opf checks, and is ≤ 30 s old.** The opf checks are: root-owned, a regular file, not a symlink, link count 1, inside a 0700 root dir. This is a sysupgrade, so the wrap:
    1. runs `pstop_all`, which is new in payload-stop.sh:
       - it stops every tenant that K08 would stop, using the same selection as K08 (review v4 #7);
       - each tenant's tiers are stopped as today, and tenants are stopped in PARALLEL;
       - the whole stop is capped at 35 s;
    2. KILLs whatever is left of that process tree and `wait`s for it (review v4 #3);
    3. logs one line, `via=sysupgrade`, to syslog and `payload-stop.log`;
    4. runs `sync`;
    5. TERMs dockerd and waits for it.
  - **Anything else** (plain stop or restart, the shutdown K path where K08/K09 already ran, an opkg upgrade): TERM dockerd only.

Why this point:
- It is the only moment on EVERY sysupgrade path (CLI, LuCI/rpcd, direct ubus, `--force`) at which dockerd still answers (E2, E3, E5).
- procd waits for it, because it sleeps for the largest term_timeout (E3).

Cost:
- Every sysupgrade takes at least 45 s longer, because procd sleeps the full term_timeout even when everything has already exited (E3).
- Accepted: an OTA takes about 120–150 s today. Stated in §5.

Manual-stop flag:
- The stop uses `docker stop`, so the manual-stop flag is set. With D5-1 that doesn't matter.
- It is harmless for a downgrade target that still uses `unless-stopped`: that image does not revive the containers, and its guardian starts the stack.

**D5-4 The guardian restarts exited containers and owns the crash accounting.**

Restarting:
- Each tick, the guardian looks for manifest containers that are exited while the tenant is not being stopped (`.stopping` absent). For those it runs `payload-run --converge` in start mode, which starts what is down, services first, gated.
- Backoff is per tenant: 30 s, then 60, 120, capped at 300 s. It resets after 10 min without a crash.

Counting:
- The count lives in the guardian loop's memory: the restarts it performed in the last 10 min. There is no file, so no new /tmp input (§11.5).
- Docker's RestartCount is no longer used. With policy `no` it only grows if someone re-enables a restart policy, and the cfg hash already reports that as config drift.

Verdict:
- `STARTING`: from guardian start until the start-mode gates pass, or for at most 300 s.
- `OK`.
- `RECOVERED`: for 10 min after a single successful restart. Logged, not DRIFT.
- `DRIFT`, when any of these hold:
  - a container is still down after a restart attempt;
  - ≥ 3 restarts within 10 min (crash loop);
  - cfg drift;
  - a verify-profile failure;
  - a D5-2 mismatch.

autocommit:
- `STARTING` means "not yet healthy": autocommit keeps polling, bounded by the existing converging deferral (DEFER_MAX).
- `RECOVERED` counts as healthy.
- A real crash loop still becomes DRIFT within ≤ 3 restarts, so a broken new image is still reverted. Nothing is hidden by a baseline trick (review v4 #2).

**D5-5 Correct the wrong text and comments (E11).** §2 T3/T5 and §5 are rewritten below.

### 11.3 Lifecycle matrix (today → v5; the test that proves it)

**L1 First boot / firstload**
- Today: firstload loads the images, and the guardian rebuilds.
- v5: the same, with containers created with policy `no`.
- Proof: flashgo-159, payload-config-golden.

**L2 Boot after a clean stop (T1)**
- Today: the guardian's ordered start, 0 restarts.
- v5: the same.
- Proof: cleanstop-274.

**L3 Reboot / batman-slot reboot / autocommit revert / batpower poweroff**
- Today: K08/K09 graceful stop.
- v5: the same. The wrap sees no marker, so it sends a plain TERM.
- Proof: cleanstop-274; the revert legs of fi-r1, fi-r3 and fi-r4.

**L4 OTA via `sysupgrade` (CLI / LuCI / ubus / `--force`)**
- Today:
  - dockerd's shutdown stops every container at once;
  - the new dockerd revives them all at once;
  - 2 crash-restarts;
  - a false DRIFT.
- v5:
  - the wrap stops the tenant gracefully, tier by tier, before dockerd exits;
  - on the new boot, the guardian does an ordered start with 0 restarts;
  - the first verdict goes STARTING → OK.
- Proof: **ota-start-274** (new). After a same-build OTA:
  - Gate 1: the stop record says `via=sysupgrade`, and every ExitCode is 0 or 143 (none is 137).
  - Gate 2: the first post-boot verdict is never DRIFT, and RestartCount is 0 for every container.
  - Reported as info: postgres logs "shut down" (not crash recovery); the stop's elapsed time.
  - Negative control: a one-shot fault flag on p6 makes the wrap skip the stop, and gate 1 must then FAIL.
  - fi-r4 must show no `drift not OK` after the OTA.

**L5 sysupgrade aborted after service_stop_all (`upgraded` fails)**
- Today: the node reboots (`upgraded.c`) and dockerd revives the containers.
- v5: the node reboots and the guardian's start mode brings the stack up.
- Proof: covered by the boot path in L3; not induced.

**L6 `sysupgrade -T` / validation only (no flash)**
- Today: nothing happens.
- v5: the marker is written but no TERM follows, so it expires after 30 s. A dockerd restart inside those 30 s would stop the tenant once, and the guardian restarts it.
- Proof: a unit test of the wrap's decision (host, stubbed).

**L7 Power loss / watchdog / panic (T2)**
- Today: dockerd revives every container at once, with crash-restarts.
- v5: nothing revives by itself, and the guardian does an ordered start. postgres still crash-recovers once (unchanged).
- Proof: crash-blackbox-173 and guardian-192 (destructive) assert an ordered start with 0 restarts.

**L8 dockerd restart (init restart, opkg, uci reload) (T5)**
- Today: every container stops and is revived, because there is no live-restore.
- v5: the containers keep running (D5-2). The guardian waits up to 120 s for the API.
- Proof: **dockerd-restart-274** (new).
  - Restart dockerd, then assert that each container's StartedAt is unchanged and that the verdict is never DRIFT.
  - Negative control: with live_restore=0, StartedAt changes.

**L9 dockerd crash (SIGKILL)**
- Today and v5: as L8 (procd respawns dockerd).
- Proof: the same suite, with a kill -9 variant.

**L10 One container crashes**
- Today: docker restarts it at once, and the next tick reports DRIFT.
- v5: the guardian restarts it within ≤ 30 s, and the verdict is RECOVERED.
- Proof: **crash-274** (new). `docker kill` cot_parser; it must be back within 60 s, with the verdict RECOVERED, not DRIFT.

**L11 Crash loop**
- Today: DRIFT, from RestartCount.
- v5: DRIFT after ≤ 3 restarts, with backoff.
- Proof: the crash-274 loop variant (an entrypoint that exits).

**L12 Guardian restart / respawn**
- Today and v5: converge if needed.
- Proof: guardian-192.

**L13 Operator `docker stop <c>`**
- Today: the container stays stopped (manual-stop flag) and the guardian reports DRIFT.
- v5: treated as a crash, so it is restarted and logged. The supported way to stop a tenant is `/etc/init.d/batman-payload-<t> stop`.
- Proof: crash-274.

**L14 Operator `docker run` bypass (T7)**
- Today and v5: the cfg hash catches it and the guardian converges.
- Proof: drift-detect-156.

**L15 Config change via the golden (T6)**
- Today and v5: a converge rebuild.
- Proof: payload-config-golden.

**L16 Downgrade to ≤ 1.5.6 (T8)**
- The older golden rewrites the RESTART line. Its guardian then rebuilds: a converge rebuild on 1.5.5/1.5.6, the legacy rebuild on ≤ 1.5.4.
- Its dockerd has no wrap, so the old OTA behaviour returns.
- The manual-stop flag from our stop is harmless there, because its guardian starts the stack.
- Proof: one manual downgrade run before the PR (recorded), not daily.

**L17 Pi 3 (no tenant)**
- Today: dockerd runs, with no tenant.
- v5: the wrap is installed and `pstop_all` is a no-op. The marker is harmless.
- Proof: ab-selftest on 03; hold-261 on the Pi 3.

**L18 Both boards**
- v5: the init patch goes into both boards' patch sets.
- Proof: build both boards; ab-card-invariants on both.

### 11.4 Interface contracts

**`$RUNDIR/upgrade-imminent`** (one line: the uptime)
- Writer → reader: platform_check_image → dockerd-wrap.
- Valid when: a root-owned regular file, not a symlink, link count 1, inside a 0700 root dir, and ≤ 30 s old.
- Missing or bad: treated as absent, so the wrap sends a plain TERM. A failure means the old OTA behaviour, never a stuck OTA.

**wrap ↔ procd**
- procd sends TERM to the wrap; `term_timeout` is 45.
- If the wrap has a bug, dockerd won't be running. autocommit's docker-engine canary then fails, and the node reverts.

**`pstop_all` result**
- The wrap writes one `via=sysupgrade` line per tenant to `payload-stop.log`.
- If the line is missing, the test FAILs (L4 gate 1).

**drift.json `status`**
- Writer → readers: the guardian → autocommit, halow-status.
- Valid values: STARTING / OK / RECOVERED / DRIFT.
- An unknown value is treated as DRIFT by autocommit (fail-closed).

**uci `dockerd.globals.live_restore`**
- Path: 99-batman-payload-docker → the init → daemon.json.
- Valid when the init patch is present.
- If it isn't in effect, the guardian reports DRIFT `live-restore not effective`.

**Manifest `RESTART`**
- Writer → reader: the golden → payload-run.
- Valid value: `no`.
- Any other value changes the cfg hash, so the guardian converges. The guardian still owns restarts.

### 11.5 Security

**Assets**
- Tenant availability and DB integrity.
- The OTA path. The wrap can delay `upgraded` by up to 45 s but cannot block it, because procd's sleep is fixed (E3).
- Root code in the wrap.

**New inputs**
- The marker. It lives in the root-only dir, so a non-root process cannot create or replace it. The trust boundary is the #280 run dir, never `/tmp`.
- procd's signals. Only procd or root can signal the wrap.
- No new network input and no new tenant-controlled input. The wrap reads only the manifests the guardian already trusts.

**Actors**
- **Remote over the mesh:** no new surface.
- **Local non-root process:** cannot forge the marker, because it cannot make a root-owned file in a 0700 root dir. Cannot signal a root process.
- **Compromised tenant container:** can crash itself. The guardian restarts it with backoff and reports DRIFT on a loop, so CPU and IO use are bounded and there is no escalation. It cannot reach dockerd (the socket is not mounted; verify-profile checks this).
- **Physical capture:** unchanged.
- **Supply chain:** the init patch is ours, reviewed, and in the firmware repo.
- **Our own mistakes:** every failure of the wrap falls back to today's behaviour (a plain TERM). autocommit's engine canary catches a dockerd that won't start.

**Privilege**
- The wrap runs as root because dockerd must; it adds no capability.
- The crash counters live in the guardian's memory. There is no new file that anyone else could write.

**Open: probe before implementation, and record on #280 if real**
- Stage 1 installs `upgraded` into `/tmp/root` (`RAM_ROOT`). If a non-root process can pre-create `/tmp/root`, that is a root-exec TOCTOU in upstream OpenWrt sysupgrade, independent of this design.
- v5 deliberately does not use `/tmp/root` as a signal.

**Verification**
- The unit test of the wrap's decision includes four bad markers: one owned by nobody, a symlink, a hardlink, and a stale one. All four must give a plain TERM.

### 11.6 Alternatives considered

- **v4 stage-2 hook:** impossible (E5).
- **Stage-1 hook (override `install_bin` in /lib/upgrade):**
  - misses a direct `ubus call system sysupgrade`, which has no stage 1;
  - needs a restore timer for the case where procd then rejects the image.

  The wrap covers every path (E2/E4).
- **Our own OTA entry command that stops the tenant, then calls sysupgrade:** it only covers callers that use it, so LuCI, ubus and manual use would still need the wrap. Dropped, so there is one mechanism, not two.
- **Keep `unless-stopped`, only add a start-up grace to the DRIFT rule:** this hides the symptom. dockerd keeps racing the guardian on T2/T3 (two owners, E9), and the 2 crash-restarts per OTA remain.
- **Client tiers `no`, services `unless-stopped` (review v4 alt C):** still two owners, and dockerd would revive the services without gates. Rejected in favour of one rule for all containers.
- **docker compose / Quadlet:** not available on the node (E10). The guardian already is the reconciler (#156).

### 11.7 Risks and limits (these replace §5's T3 statement)

- An OTA takes at least 45 s longer (E3).
- Recovering a crashed container goes from about 1 s (docker) to up to 30 s (one guardian tick), plus backoff. This is stated and accepted, as the price of one owner and an ordered start.
- Power loss (L7) still means one postgres crash recovery. No software can stop a container on power loss.
- The 30 s marker window can stop a tenant once, if dockerd restarts right after a `sysupgrade -T`. The guardian restarts it. Benign, and logged.
- A downgrade to ≤ 1.5.6 brings back that version's behaviour (L16) and costs one rebuild each way.
- v5 depends on #280's run dir. #274 introduces `rundir.sh`, and #280 rebases on it.

## 12. v6 (2026-10-09): one owner, nothing in the OTA path

**v5 (§11) is REJECTED and superseded** (#274 comment 6072340146: two reviewers, two BLOCKERs, eight MAJORs).
v6 keeps v5's direction — one owner of the tenant lifecycle, restart policy `no` — and drops its mechanics
(the dockerd wrap, the upgrade marker, `term_timeout 45`, live-restore). A new measurement (E14) shows they
were never needed: on an OTA, dockerd's own shutdown already stops the whole tenant gracefully, in < 1 s,
16 s before stage 2 kills anything. The one thing that goes wrong is the *next boot*: dockerd revives all six
containers at once (E6). With policy `no` nothing revives itself, and the guardian's ordered start runs on
every boot, OTA included.

This section is written against `docs/design/REVIEW.md` and #280's root-only run dir (merged, c792b10).
The reviewer reviews the WHOLE document. Where §12 differs from anything earlier, §12 wins. §11's evidence
table (E1–E11) still holds and is referred to below.

### 12.0 What v6 does not touch (and why that matters)

- **procd's sysupgrade path is unchanged:** no wrap, no marker, no `term_timeout` change, no hook in stage 1
  or stage 2. procd's blocked window (validate + `sleep(max term_timeout)`, E13) is exactly today's.
- **The stock dockerd init is unchanged** (no firmware patch). Only our uci-defaults change (D6-2).
- **K08/K09 (clean stop) are unchanged** (E8).

### 12.1 New evidence (reality check 2026-10-09, fleet on 1.5.7-wsl.3+c792b10)

| # | fact | evidence |
|---|---|---|
| E12 | `validate_firmware_image` of the real OTA payload takes **14–16 s on a Pi 4** (02, 04) and **21–25 s on a Pi 3** (03). In a real OTA procd's own call took 14 s (04) and 22 s (03). | `/usr/libexec/validate_firmware_image /opt/batdata/ota.tar.gz` ×2 per node, timed with `/proc/uptime`. ota-trace: S1 CHECK (stage 1) → S1 CHECK `caller=/sbin/procd`: 04 02:38:07→02:38:21; 03 22:14:23→22:14:45. |
| E13 | **procd sends no watchdog pings while it validates and while it sleeps in `service_stop_all`.** `validate_firmware_image_call` forks and then reads the pipe synchronously in procd's main loop; the pings are a uloop timer. The bcm2835 driver sets `max_hw_heartbeat_ms`, so the kernel keeps the hardware alive until 30 s after the last userspace ping. So an OTA stalls procd for validate + 5 s: **≈ 19 s on a Pi 4, ≈ 27 s on a Pi 3**, plus up to 5 s since the last ping. The Pi 3 margin to 30 s is ≈ 0–3 s. This is **today's** budget; v6 adds nothing to it (12.0). A reset there loses the OTA attempt (nothing has been written yet; the node boots its old slot). | procd `system.c:643-693` (fork + `vjson_parse(fds[0])`), `watchdog.c:44-48`; kernel `drivers/watchdog/bcm2835_wdt.c:161`; `ubus call system watchdog` = `timeout 30, frequency 5` on 02/03/04. |
| E14 | **Today's OTA stop is already graceful.** Same-build OTA on 04 (A→B, 2026-10-09). procd validation ended 02:38:21; at 02:38:21.8 opentakserver got SIGINT (`KeyboardInterrupt`), ots-db `fast shutdown request` 02:38:22.04 → `database system is shut down` 02:38:22.35, rabbitmq closed its vhost and stores by 02:38:22.39. Stage 2 began 02:38:38 (its `kill_remaining TERM` / +4 s `KILL`, `stage2:157-159`, come later still). Next boot postgres: `database system was shut down at 02:38:22` (no recovery). | container logs on p6 (`docker logs -t`, old-boot window); ota-trace S2 BEGIN. |
| E15 | **The symptom, same OTA:** new boot `RestartCount` opentakserver=1, ots_cot_parser=1, the other four 0; the first guardian verdict was `DRIFT` (`container opentakserver restarted 1x since the last check`, `ots_cot_parser` likewise). This run is the negative baseline for ota-start-274 (12.7). | `docker inspect`, `$RUNDIR/batman-payload-opentakserver-verify.log`, syslog `confinement DRIFT detected` 61 s after boot. |
| E16 | Stock dockerd init: no `respawn` (`/etc/init.d/dockerd:231-241`); `reload_service` = re-render daemon.json + SIGHUP (`:244-247`); the uci trigger on `dockerd` is a reload, not a restart (`:249-251`); `stop_service` = `service_stop /usr/bin/dockerd`. | read on 02 |
| E17 | Start mode's phase B relies on the restart policy when phase A fails ("their restart policy backs off until the services are up"). | `payload-run:312-317` |
| E18 | firstload's incomplete branch (tars remain) starts the stack itself with `payload-run --start-only` while the guardian stays disabled for that boot. | `batman-ots-firstload:146-153` |
| E19 | The guardian exits when PRIMARY is not running (procd respawns it, `respawn 30 15 0`); its crash accounting (`RC_STATE`) is rebuilt from scratch on every start. | `payload-guardian.sh:94,101,133,135` |
| E20 | **`lora-rx` on 04:** image `meshtastic-cli:arm64`, `--network host`, `/opt/batdata` mounted **RW** at `/data`, root, policy `no`, `Exited (0) 11 days ago`. No image, manifest or script in this repo creates it (dev residue of the LoRa W10 work). #280 handed "a container with p6 RW is a p6 writer" to #274 (`280-tmp-trust.md:553`). | `docker ps -a`, `docker inspect lora-rx`; repo grep |
| E21 | The OTS containers mount only docker volumes under `/opt/batdata/docker/volumes/` (RW) and `apps/opentakserver/rabbitmq-extra.conf` (RO). No tenant container mounts the apps dir RW. | `docker inspect` mounts, 04 |
| E22 | halow-status already reads the run-dir verdict (#280); review v5 MINOR "stale drift file" is closed. | `halow-status:90-96` |
| E23 | The cleanstop-274 negative-control seam `fault.274-rmstop-once` lives on p6 (`/opt/batdata/state/`), i.e. writable by any container with p6 RW (E20). | `payload-stop.sh:98-103`, `daily-validation.sh:1123` |
| E24 | `dockerd-restart.sh` recorded a 1.5.2 baseline where an `unless-stopped` container came back `exited` after `/etc/init.d/dockerd restart`, while after an OTA they are revived (E6/E15). Unexplained; v6 does not depend on either behaviour (policy `no` everywhere). | `scripts/node/dockerd-restart.sh:5,25` |

### 12.2 Design

**D6-1 Restart policy `no` for every tenant container; the guardian is the only starter.**
- `payload-run` always renders `--restart no`. A manifest `RESTART` value other than `no` (tenant header or
  per container) is ignored with a WARN line (`manifest RESTART <v> ignored — the guardian is the only
  restarter (#274)`). `--restart` is placed after `$HARDEN_FLAGS` (as today), so a hardening file cannot
  override it; the CI hardening-file check also rejects `--restart` there.
- `profile.yaml` of ots / dummy-nginx / dummy-nginx-b say `restart: "no"`; `profile-to-manifest.py` defaults to
  `no`; the manifests are re-rendered. CI (the existing manifest consistency check) fails on any `RESTART` ≠ `no`.
- The rendered argv is in the cfg hash, so the first boot on v6 converges by one rebuild (T6 path, already
  supported). A downgrade costs one rebuild the other way (L-DOWN).
- Effect: after a power loss (T2) and after an OTA (T3) no container comes up by itself; the guardian's start
  mode brings the stack up services first, gated (§9). The E6/E15 race is gone by construction.

**D6-2 live-restore stays off, and the config says so.**
- `99-batman-payload-docker` stops setting `live_restore` and `no_new_privileges` (the stock init maps
  neither, E1) and deletes both keys (a keep-config upgrade would otherwise carry them). `patches/0004-*`
  (never applied, §11 review MINOR) is deleted.
- Why off: with policy `no`, *someone* must stop the containers on every sysupgrade path. Without
  live-restore dockerd does it, gracefully and in < 1 s (E14), on every path (CLI, LuCI, raw ubus, `-F`).
  With live-restore the containers would outlive dockerd and be TERM/KILLed by stage 2 (v5's MAJOR). The
  price: a dockerd restart stops the tenant; the guardian restarts it in order (D6-3, L-DOCKERD).
- The guardian checks `docker info -f '{{.LiveRestoreEnabled}}'` at every start; `true` is published as
  DRIFT `dockerd live-restore is on — an OTA would kill the tenant instead of stopping it (#274)`.
- `no-new-privileges` per container is unchanged (payload-run renders it, verify-profile checks it). The
  daemon-wide default is not in effect today and stays so — recorded as a leftover (12.9).

**D6-3 The guardian restarts exited containers and owns the crash record.**
- Each tick, after the docker API answers and only while `$R/batman-payload-<t>.stopping` is absent: the
  manifest containers whose status is `exited`, `created` or `dead` are restarted with
  `PAYLOAD_LOCK_WAIT=5 PAYLOAD_SKIP_FW4=1 payload-run --start-only <t>` — start mode only: services first and
  gated, the already-running ones skipped, **never a rebuild**, and **no `*.fw4.uci` execution** (the rules are
  already in uci from this boot's start; re-running a p6 script mid-boot would execute a file the golden
  refresh has not re-checked since boot, see D6-5) (rc 3 = config changed → no action, DRIFT stays; rc 4 =
  being stopped → no action; rc 1 = start or gate failed → DRIFT, retried with backoff).
- **Ledger** `$R/batman-payload-<t>-restarts`: one line `<uptime_s> <names…>` appended *before* each attempt.
  It is in the root-only run dir (#280), per boot (tmpfs), and survives a guardian respawn.
- **Backoff** from the ledger, on `/proc/uptime` (04's wall clock jumps): with n attempts in the last 600 s,
  the next attempt waits until `last + min(30·2^(n−1), 300)` s. First restart ≤ one tick (30 s) after the exit.
- **Verdict** (drift.json `status` stays `OK`/`DRIFT`, no new value, so autocommit is unchanged):
  `DRIFT` if a manifest container is not running at the end of the tick, or the ledger has an attempt in the
  last 60 s (`container <c> restarted by the guardian at +<n> s`), or the existing cfg / verify-profile /
  D6-2 / D6-5 rules fire. A crash therefore shows DRIFT for one to two ticks (today: one tick, E15's rule);
  a crash loop shows DRIFT on every tick (down between restarts, or a fresh attempt).
- The **RestartCount rule and `RC_STATE` are removed** (vacuous under policy `no`; a re-enabled restart
  policy changes the cfg hash and is caught by D3(b)).
- **The PRIMARY exit is removed** (E19): PRIMARY is restarted like any other container, so the guardian
  keeps running and the ledger keeps counting. The guardian still exits for respawn when the docker API is
  down > 120 s (unchanged).
- **Respawn marker** `$R/batman-payload-<t>.up` (created after the first converge of this boot): a guardian
  that finds it at start is a respawn, and the containers its start-up converge starts are written to the
  ledger too — so a crash cannot be hidden by a guardian respawn.

**D6-4 firstload no longer starts containers itself.** In the incomplete branch (E18) the loader runs
`/etc/init.d/batman-payload-<t> start` (not `enable`) instead of `payload-run --start-only`. The guardian
converges whatever is loadable (a stack on its old config is published as DRIFT, exactly as today's converge
REFUSED path), and supervises it for the rest of the boot. It stays disabled, so the next boot's S95 firstload
holds it again until the tars are loaded or quarantined (#216 self-healing unchanged). The complete branch
is unchanged (enable + start). Now every container start goes through the guardian.

**D6-5 p6 has one writer.** The tenant config on p6 (`/opt/batdata/apps/`) is written by the golden refresh
(95-batman-storage) and read by payload-run and the guardian as root, which *execute* `*.fw4.uci` and parse
manifests and hardening files. A container that mounts p6 RW (E20) is therefore a path from that container's
root to host root.
- **Detective:** each tick the guardian lists every container (any state) without a `batman.tenant` label and
  publishes DRIFT `foreign container <c> mounts <src> RW (p6 writer)` when one has a RW mount whose source is
  `/`, `/opt`, `/opt/batdata` or `/opt/batdata/apps` (or below apps). Tenant containers are already bounded by
  their manifest (E21; verify-profile).
- **Preventive (manifest side):** payload-run's preflight refuses a manifest MOUNT/volume whose source is one
  of those paths (any mode RW).
- **The test seam moves off p6:** `fault.274-rmstop-once` becomes `$RUNDIR/fault.274-rmstop-once`, read with
  `batman_opf` (root-owned, regular, single link, in the 0700 dir).
- **04's `lora-rx`** is removed before the rc goes on 04 (print first; user decision, 12.10). Until then the
  new rule would rightly report DRIFT on 04.

**D6-6 Correct the wrong statements** (E11): `payload-guardian.sh:10-21,83/92`, `payload-run:26-27,316`,
`payload-stop.sh:10-11`, `batman-autocommit:8`, `profile.yaml:128-132`, `167-payload-manager.md:473`,
`99-batman-payload-docker:21-26`, and §1 item 1 / §2 T2,T3,T5,T12 / §5 of this document (12.8 replaces them).

### 12.3 Ownership

| resource | owner (may change it) | others (read-only) |
|---|---|---|
| tenant container running/stopped | **guardian** (start-up converge, D6-3 restarts); stops: `payload-stop.sh` (K08/K09/operator `stop`), dockerd's own shutdown (OTA, `dockerd stop/restart`) — a stop is never a start, so one starter | autocommit, halow-status, tests |
| container existence / config (create, rm) | payload-run, called by the guardian (converge) and by the operator (rebuild/renet) | guardian (cfg hash) |
| per-container restart policy | payload-run's renderer (always `no`) | cfg hash |
| tenant config on p6 (`apps/<t>/`) | golden refresh (95-batman-storage) | payload-run, guardian, payload-stop; **no container** (D6-5) |
| dockerd process | procd via the stock init | everyone |
| daemon config (`/tmp/dockerd/daemon.json`) | stock init from uci `dockerd.globals` (we set data_root, iptables) | dockerd; guardian checks live-restore |
| restart ledger, `.up` marker | guardian | tests |
| `.stopping`, `.stop0` | payload-stop (set), guardian `start_service` and firstload S95 (clear) — unchanged | payload-run, guardian loop |
| `.converging` | guardian | autocommit |
| drift.json | guardian | autocommit, halow-status, tests |
| tenant lock / pid | payload-run wrapper | payload-stop (`pstop_kill`) |
| `fault.274-rmstop-once` | harness (root over ssh) | payload-stop (consumes once) |
| firstload latch | firstload | autocommit |
| procd's blocked window during sysupgrade (validate + `sleep(max term_timeout)`) = the watchdog budget | procd / platform_check_image (#209/#280); **v6 adds 0 s** | — |
| `payload-stop.log` | `pstop_final` (only appender) | tests |

### 12.4 Contracts

- **Ledger** `$R/batman-payload-<t>-restarts` — writer guardian, readers guardian (backoff, verdict) and
  tests. Format: lines `<uptime seconds, integer> <name>[ <name>…]`. Valid for the current boot (tmpfs).
  Missing = no attempts this boot. A malformed line is skipped (awk on integers); it cannot hide an attempt
  because the guardian appends before acting. Path in the root-only run dir: no non-root writer.
- **`.up`** — writer guardian, reader guardian. Present = a guardian already completed a start-up converge
  this boot. Missing = first start (fail-open is safe: at worst one start-up converge is not recorded as a
  restart, the same as today).
- **payload-run exit codes** to the restart path: 0 ok · 1 start/gate failed (DRIFT, backoff) · 3 config
  changed, nothing done (DRIFT via D3(b), no rebuild from the tick) · 4 being stopped (nothing). Any other
  code = 1.
- **drift.json `status`** — unchanged: `OK` / `DRIFT`; autocommit requires `OK` and fresh (< 1 min).
- **Manifest `RESTART`** — writer golden/profile-to-manifest; reader payload-run. Only `no` is valid; other
  values are ignored with a WARN (not refused: the restart policy is not a security property, and refusing
  would leave an operator-installed tenant down after the upgrade).
- **uci `dockerd.globals.live_restore` / `no_new_privileges`** — no longer written; deleted. If an operator
  sets them, the stock init still ignores them (E1); the guardian's LiveRestoreEnabled check is the backstop.
- **Guardian syslog lines tests parse:** `restart: <names> (attempt <n> in 600 s)`, `restart: rc=<rc>`,
  `foreign container <c> mounts <src> RW`. Each test that parses one also asserts it found ≥ 1 line where it
  expects one (an empty parse is a FAIL).

### 12.5 Lifecycle matrix (today → v6; proof)

| path | today | v6 | proof |
|---|---|---|---|
| L-FIRST first boot, firstload complete | firstload loads, guardian rebuilds | same, containers created with `no` | flashgo-159, payload-config-golden (now wants `no`) |
| L-FIRST2 firstload incomplete (≤ 3 boots) | stack started by firstload, guardian down, crashes restarted by docker | guardian started (not enabled), supervises; DRIFT if on old config | new node check in flashgo-159: plant one unloadable tar (sha mismatch → quarantine path is too fast, so a tar that `docker load` rejects), reboot, assert guardian running + stack up + `firstload: … guardian started` line; negative control: the old firstload leaves the guardian stopped |
| L-BOOT boot after a clean stop | ordered start, 0 restarts | same | cleanstop-274 (RestartCount check 6 replaced by: each container has exactly one `start` event since dockerd started, `docker events --since <dockerd start> --until now`) |
| L-STOP clean shutdown / reboot / autocommit revert / batpower poweroff | K08/K09 graceful, recorded | same | cleanstop-274 |
| L-OTA OTA, every entry (CLI, LuCI, ubus, `-F`) | dockerd stops all gracefully (E14); next boot revives all at once, 2 crash-restarts, false DRIFT (E15) | stop unchanged; next boot nothing revives, guardian ordered start, 0 restarts, first verdict OK | **ota-start-274** (new, 12.7); negative = E15 (today's image) |
| L-OTA1 first OTA *into* v6 (old containers `unless-stopped`) | — | dockerd revives the old containers once; guardian sees the new cfg hash and rebuilds with `no`; no RestartCount rule, so no false DRIFT | ota-start-274 run on the rc (recorded once: rebuild line + verdict OK) |
| L-OTA-REV revert leg of that OTA (autocommit revert to ≤ 1.5.7) | — | K08/K09 stop (manual-stop flag); the old image's golden writes `unless-stopped`, its guardian rebuilds | fi-r1/r3/r4 revert legs (unchanged suites) |
| L-AC autocommit commit/revert | gates on drift OK | same contract; fewer false DRIFTs | fi-r4 must not show `drift not OK` after the OTA |
| L-PWR power loss / hardware watchdog / panic | dockerd revives all at once (crash-restarts), postgres crash recovery | nothing revives, guardian ordered start; postgres crash recovery unchanged (nothing can stop it) | **unclean-boot-274** (new, OTS node, destructive): `reboot -f` (no K scripts, containers die with the kernel, as on power loss), then the ota-start-274 checks 1, 2, 5 (and 3 until the verdict is OK); negative control: today's image revives all six at once (check 1 FAIL, as E15) |
| L-GRD guardian restart (operator `restart`, respawn after API-down) | converge if needed | same; a respawn records its starts in the ledger (`.up`) | crash-274 step 4 (kill the guardian's shell, assert ledger line on the re-start of a container stopped meanwhile) |
| L-DOCKERD `dockerd restart` / `stop`+`start` (operator) | all stop; revived by policy (or not, E24) | all stop gracefully; guardian restarts the stack in order (≤ 30 s + start) | **dockerd-restart-274** (new, OTS node, destructive): all 6 back ≤ 180 s, ledger line, postgres `shut down at`, LiveRestoreEnabled=false |
| L-DOCKERD-KILL dockerd SIGKILL | containers keep running under their shims; nothing restarts dockerd (E16) | same (unchanged; leftover 12.9) | not induced; stated |
| L-RELOAD `uci commit dockerd` / init reload | SIGHUP, no restart (E16) | same | — |
| L-NET network / netifd / fw4 restart | fw4 rules for dockert persist in uci | same | existing confinement-98 |
| L-CRASH one container crashes | docker restarts it ≈ 1 s; DRIFT next tick | guardian restarts it ≤ 30 s; DRIFT 1–2 ticks; then OK | **crash-274** (new): `docker kill -s KILL ots_cot_parser` → running again ≤ 60 s, ledger line, guardian PID unchanged, verdict back to OK ≤ 120 s; negative control: today's image has no ledger line (FAIL) |
| L-PRIMARY PRIMARY (opentakserver) crashes | guardian exits, respawns, accounting lost | restarted like any other, guardian keeps running | crash-274 step 2 (guardian PID unchanged; negative: today's PID changes) |
| L-LOOP crash loop | DRIFT via RestartCount | DRIFT every tick, attempts back off 30/60/120…300 s | crash-274 step 3: kill the container each time it comes back, 4 times; assert attempt spacing ≥ 30, 60, 120 s (−5 s tolerance) and DRIFT on every tick in between |
| L-OPSTOP operator `docker stop <c>` | stays down (manual-stop), DRIFT | restarted as a crash, logged | crash-274 |
| L-OPRUN operator `docker run` bypass (T7) | cfg hash → converge | same | drift-detect-156 |
| L-OPSVC `/etc/init.d/batman-payload-<t> stop/start` | tiered stop / converge | same (`.stopping` blocks restarts during the stop) | cleanstop-274; payload-mgr-167 |
| L-T6 config change via the golden | converge rebuild | same | payload-config-golden |
| L-FOREIGN container with p6 RW (E20) | unnoticed | DRIFT `foreign container … p6 writer` | **p6-writer-274** (new, any tenant node): create an unlabelled `--network none` container `-v /opt/batdata/apps:/x` (created, never started), assert DRIFT line within 2 ticks, remove it, assert OK; negative control: today's guardian stays OK |
| L-DOWN downgrade to ≤ 1.5.7 | — | older golden writes its RESTART; older guardian rebuilds once; older OTA behaviour returns | one manual downgrade OTA before the PR (recorded) |
| L-CLOCK wall-clock step (04 boots in 2025) | — | backoff and windows on `/proc/uptime` | crash-274 runs on 04 |
| L-PI3 bcm2710 (no tenant, #209 D6) | dockerd, no guardian | uci-defaults change applies (keys deleted); nothing else | ab-selftest on 03, hold-261; build both boards |
| L-BOARDS both boards | — | no board-specific code | build both; ab-card-invariants both SoCs |

### 12.6 Security

**Assets.** Host root (payload-run and the guardian run as root and execute p6 files); tenant availability;
DB integrity; the OTA path (untouched, 12.0).

**Attack-surface delta.**
- New run-dir files (ledger, `.up`): root-only dir (#280), no non-root writer; reader is root code that only
  parses integers and names compared against the manifest list.
- `fault.274-rmstop-once` moves from p6 to the run dir: removes a container-writable trigger (E23).
- The guardian reads every container's mounts (`docker inspect`, root, local socket): read-only, no new input
  from the network.
- Removed: the RestartCount state file, the PRIMARY exit.
- No new port, CGI, uci key, env var or mesh message.

**Actors.**
- *Remote (mesh/WiFi/LoRa RF):* no new surface. The LoRa RF path into a p6-RW container (E20) is closed by
  removing `lora-rx` and detected by D6-5 if one reappears.
- *Local non-root process:* cannot write the run dir (0700 root) nor p6 apps (`/opt/batdata`, `apps/`,
  `apps/opentakserver/` and its files are root-owned, 755/644/755, measured on 04); cannot reach the docker
  socket (`srw-rw---- root docker`; the docker group's only member is the system user `docker`, uid 32768,
  shell `/bin/false`, no processes — measured on 04).
- *Compromised tenant container:* can crash itself — restarts are bounded by the backoff (≤ 1 per 300 s after
  the 4th) so it cannot make the host spin; every crash is DRIFT, so it cannot hide. It cannot write p6 apps
  (E21, preflight refuses such mounts, D6-5 detects foreign ones). It cannot reach dockerd (no socket mount;
  verify-profile).
- *Compromised unmanaged container with p6 RW:* today a host-root path (it can rewrite `*.fw4.uci`, which
  root executes at the next start mode). After v6: removed from 04, and any such container is reported as
  DRIFT within one tick. **Detection is not prevention:** a write made before anyone acts on the DRIFT is
  still executed at the next start mode. The prevention is "no unmanaged container mounts p6", and only
  root can create one (docker socket). Stated as a residual risk; a stronger fix (p6 config verified against
  the image before execution) is outside #274.
- *Physical capture:* unchanged.
- *Supply chain:* no new package, no firmware patch (0004 deleted).
- *Our own mistakes:* a guardian bug that stops restarting shows as DRIFT (container not running);
  a restart storm is bounded by the backoff; `--start-only` can never rebuild.

**Privilege.** No new root code path reads a non-root-writable location. The golden refresh rewrites every
golden file on p6 at each boot (`95-batman-storage` refresh, cmp + atomic cp), so the boot-time start mode
executes the image's `*.fw4.uci`. The D6-3 restart path runs mid-boot and therefore does **not** execute
`*.fw4.uci` (`PAYLOAD_SKIP_FW4=1`); it only parses the manifest and runs `docker start`. Today the PRIMARY
exit → respawn → guardian start re-ran `*.fw4.uci` mid-boot; v6 removes that path (E19), so v6 narrows the
exposure rather than widening it. One mid-boot execution remains, unchanged from today: a guardian respawn
after the docker API was down > 120 s (or an operator `restart` of the guardian) runs the start-up path,
`*.fw4.uci` included.

**Failure mode.** Fail-visible: every degraded state is DRIFT. The one fail-open is `.up` missing → a respawn
converge not logged as a restart (stated in 12.4; it equals today's behaviour).

**Verification (negative tests).** p6-writer-274 (foreign RW mount detected); crash-274 (no hidden crash, no
PRIMARY respawn); run-dir names added to `scripts/rundir-paths.txt`, so tmp-trust-280's N8 sweep and
check-tmp-trust cover them as a non-root writer.

### 12.7 Tests (all in daily-validation; destructive ones in the destructive tier)

- **ota-start-274** (new, OTS node, destructive): one same-build `sysupgrade -n` (the fault-injection OTA
  helper), then on the new boot:
  1. every manifest container has exactly **one** `start` event since this dockerd started
     (`docker events --since 0 --until <now> --filter event=start`, counted for the manifest names only —
     the autocommit canary's random-named containers also appear) — independent of the guardian's own record.
     Evidence that it discriminates: on 04 after the E15 OTA it printed the six names once, then
     `opentakserver` and `ots_cot_parser` a second time. A check that finds 0 events for a name FAILs;
  2. two-phase order (final tier's StartedAt ≤ every other container's) and a `start mode` line this boot;
  3. no `confinement DRIFT detected` line this boot until autocommit commits, and the commit trace has no
     `drift not OK`;
  4. postgres last start `database system was shut down at` (graceful, E14);
  5. the ledger is empty.
  **Negative control:** today's image (E15) fails 1 (two start events for opentakserver and ots_cot_parser)
  and 3 — recorded from the 2026-10-09 run, and re-run once on the old image before the PR.
- **crash-274** (new, OTS node, destructive): L-CRASH, L-PRIMARY, L-LOOP, L-GRD steps. Negative control: on
  today's image the ledger check fails (no ledger) and the PRIMARY step fails (guardian PID changes).
- **dockerd-restart-274** (new, OTS node, destructive): L-DOCKERD.
- **p6-writer-274** (new, OTS node): L-FOREIGN with its negative control.
- **cleanstop-274**: RestartCount check replaced by the start-event count; `DV_TEST_274_RMSTOP` uses the run-dir
  flag.
- **payload-config-golden**: wants `no`.
- **unclean-boot-274** (new, OTS node, destructive): L-PWR.
- **flashgo-159**: adds the L-FIRST2 incomplete-branch check (12.5).
- **dockerd-restart-247**: unchanged (non-tenant nodes); its comment points at E24.
- Host: `scripts/test-payload-run.sh` — RESTART ignored + WARN, `--restart no` rendered last, preflight refuses a
  p6 MOUNT; a guardian unit test with a stub `docker` for the ledger/backoff arithmetic and the `.up` rule.
- fi-r4 (existing) is the field regression: no `drift not OK` after its OTA.

### 12.8 §1/§2/§5 corrected

- §1 item 1, §2 T2/T3: dockerd does not revive because of live-restore (it was never on, E1); it revives
  because of `unless-stopped`. v6: nothing revives.
- §2 T3: stage 2 does not stop the tenant — procd's `service_stop_all` TERMs dockerd, and dockerd stops every
  container gracefully (E14).
- §2 T5: a dockerd restart stops the tenant (no live-restore); the guardian restarts it.
- §2 T12 disappears (no restart policy can override a stop).
- §5's "an OTA is not a graceful stop" is wrong for the stop (E14); what an OTA lacks is the *ordered start*,
  which v6 gives every boot.

### 12.9 Limits and leftovers (to be written into #274 as a checklist)

- **Pi 3 OTA watchdog margin ≈ 0–3 s (E13), pre-existing.** v6 neither causes nor worsens it. Fix direction:
  stage 2 re-verifies the image anyway, so procd's second full validate could use stage 1's verdict (cached in
  the run dir keyed by inode/size/mtime) — an OTA-path change for its own design review.
- dockerd SIGKILL / crash: no respawn in the stock init (E16); containers keep serving headless, the verdict
  goes stale. Unchanged by v6.
- Daemon-wide `no-new-privileges` is not in effect (per-container flag is).
- Recovery from a container crash: ≈ 1 s (docker) → ≤ 30 s + backoff (guardian). Accepted as the price of one
  owner and an ordered start.
- Power loss still costs one postgres crash recovery.
- The first OTA into v6 still shows one revival + one rebuild (L-OTA1), no false DRIFT.

### 12.10 Alternatives

- **v5 wrap around dockerd** (stop before `service_stop_all`): rejected — adds to procd's blocked window (E13,
  BLOCKER), needed live-restore which turns stage 2 into a KILL, and is unnecessary: the stop is already
  graceful (E14).
- **Stage-1 pre-stop:** unnecessary for the same reason, and misses raw ubus.
- **Keep `unless-stopped`, add a start-up grace to the DRIFT rule:** two owners remain; the crash-restarts remain;
  the symptom is hidden, not removed.
- **live-restore on:** a dockerd restart would keep the tenant up, but every OTA would kill it instead of
  stopping it (stage 2 KILL). Rejected: OTAs are routine, operator dockerd restarts are not.
- **Patch the stock init (respawn, live-restore, no-new-privileges):** not needed for #274; a firmware patch to
  a stock package for availability-only gains. Leftover.

### 12.11 User decisions

1. **Remove the `lora-rx` container from 04** (dev residue, E20; the image and `/opt/batdata` stay). Needed before
   the rc reaches 04, or D6-5 reports DRIFT there.
2. The Pi 3 watchdog margin (12.9) stays a leftover in #274 unless you want it handled now.
