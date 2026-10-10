# #274 — payload tenant converges on its config; clean stop, fast start

Status: design **v8.2** (2026-10-09) — **approved**: the v8.1 reviews (A and B) found no BLOCKER/MAJOR; their MINORs are folded in. **§12 supersedes §11** (v5 REJECTED, #274 comment 6072340146; v6 and v7 each APPROVE-WITH-CHANGES ×2 with open MAJORs, all resolved in v8 — §12.12) and overrides everything earlier where they differ. Before that: design v5. §11 superseded §10 (v4 was REJECTED; its BLOCKER was confirmed on 04) and overrides §2 T3/T5, §4 and §5 where they differ. Earlier: v1 REJECTED (B1–B3, M1–M9), v2 REJECTED (N1–N10); §7 maps every finding
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

## 12. v8.2 (2026-10-09, approved): one owner, nothing in the OTA path

**History of this section.** v5 (§11) was REJECTED (#274 comment 6072340146). v6 (commit fdf9291) kept v5's
direction and dropped its OTA mechanics; its two independent reviews both returned APPROVE-WITH-CHANGES with open
MAJORs (A: 5, B: 6). v7 (1bdaff1) resolved them; its re-reviews again returned APPROVE-WITH-CHANGES (A: 2 MAJOR /
10 MINOR; B: 4 MAJOR / 8 MINOR). **v8 resolves those in place** (the D7-x names are kept for continuity) and
records the user's decision on crashes during a trial (12.13). 12.12 maps every finding of every round to where
it is resolved. Where §12 differs from anything earlier in this document, §12 wins. §11's evidence table
(E1–E11) still holds.

The idea in one paragraph: on an OTA, dockerd's own shutdown already stops the whole tenant gracefully, in
< 1 s, 16 s before stage 2 kills anything (E14). What goes wrong is the *next boot*: dockerd revives all six
containers at once because of `unless-stopped` (E6/E15). With restart policy `no` nothing revives itself; the
guardian is the only component that starts or restarts a tenant container, in order, on every boot and after
every crash, and it keeps a crash record that autocommit can trust.

This section is written against `docs/design/REVIEW.md` and #280's root-only run dir (merged, c792b10).

### 12.0 What v8.2 does not touch

- **procd's sysupgrade path:** no wrap, no marker, no `term_timeout` change, no hook in stage 1 or stage 2.
  procd's blocked window (validate + `sleep(max term_timeout)`, E13) is exactly today's: v8.2 adds 0 s.
- **The stock dockerd init** (no firmware patch). Only our uci-defaults change (D7-2).
- **The K09 stop path** (`pstop_final`) and the OTS images.

### 12.1 New evidence (reality check 2026-10-09, fleet on 1.5.7-wsl.3+c792b10)

| # | fact | evidence |
|---|---|---|
| E12 | `validate_firmware_image` of the real OTA payload takes **14–16 s on a Pi 4** (02, 04) and **21–25 s on a Pi 3** (03). In a real OTA procd's own call took 14 s (04) and 22 s (03). | `/usr/libexec/validate_firmware_image /opt/batdata/ota.tar.gz` ×2 per node, timed with `/proc/uptime`. ota-trace: S1 CHECK (stage 1) → S1 CHECK `caller=/sbin/procd`: 04 02:38:07→02:38:21; 03 22:14:23→22:14:45. |
| E13 | **procd sends no watchdog pings while it validates and while it sleeps in `service_stop_all`.** `validate_firmware_image_call` forks and then reads the pipe synchronously in procd's main loop; the pings are a uloop timer. The bcm2835 driver sets `max_hw_heartbeat_ms`, so the kernel keeps the hardware alive until 30 s after the last userspace ping. So an OTA stalls procd for validate + 5 s: **≈ 19 s on a Pi 4, ≈ 27 s on a Pi 3**, plus up to 5 s since the last ping. The Pi 3 margin to 30 s is ≈ −2…+3 s (27 s blocked + 0–5 s since the last ping, against 30 s). This is **today's** budget; v8 adds nothing to it (12.0). A reset there loses the OTA attempt (nothing has been written yet; the node boots its old slot). | procd `system.c:643-693` (fork + `vjson_parse(fds[0])`), `watchdog.c:44-48`; kernel `drivers/watchdog/bcm2835_wdt.c:161`; `ubus call system watchdog` = `timeout 30, frequency 5` on 02/03/04. |
| E14 | **Today's OTA stop is already graceful.** Same-build OTA on 04 (A→B, 2026-10-09). procd validation ended 02:38:21; at 02:38:21.8 opentakserver got SIGINT (`KeyboardInterrupt`), ots-db `fast shutdown request` 02:38:22.04 → `database system is shut down` 02:38:22.35, rabbitmq closed its vhost and stores by 02:38:22.39. Stage 2 began 02:38:38 (its `kill_remaining TERM` / +4 s `KILL`, `stage2:157-159`, come later still). Next boot postgres: `database system was shut down at 02:38:22` (no recovery). | container logs on p6 (`docker logs -t`, old-boot window); ota-trace S2 BEGIN. |
| E15 | **The symptom, same OTA:** new boot `RestartCount` opentakserver=1, ots_cot_parser=1, the other four 0; the first guardian verdict was `DRIFT` (`container opentakserver restarted 1x since the last check`, `ots_cot_parser` likewise). This run is the negative baseline for ota-start-274 (12.7). | `docker inspect`, `$RUNDIR/batman-payload-opentakserver-verify.log`, syslog `confinement DRIFT detected` 61 s after boot. |
| E16 | Stock dockerd init: no `respawn` (`/etc/init.d/dockerd:231-241`); `reload_service` = re-render daemon.json + SIGHUP (`:244-247`); the uci trigger on `dockerd` is a reload, not a restart (`:249-251`); `stop_service` = `service_stop /usr/bin/dockerd`. | read on 02 |
| E17 | Start mode's phase B relies on the restart policy when phase A fails ("their restart policy backs off until the services are up"). | `payload-run:312-317` |
| E18 | firstload's incomplete branch (tars remain) starts the stack itself with `payload-run --start-only` while the guardian stays disabled for that boot. | `batman-ots-firstload:146-153` |
| E19 | The guardian exits when PRIMARY is not running (procd respawns it, `respawn 30 15 0`); its crash accounting (`RC_STATE`) is rebuilt from scratch on every start. | `payload-guardian.sh:94,101,133,135` |
| E20 | **`lora-rx` on 04:** image `meshtastic-cli:arm64`, `--network host`, `/opt/batdata` mounted **RW** at `/data`, root, policy `no`, `Exited (0) 11 days ago`. No image, manifest or script in this repo creates it (dev residue of the LoRa W10 work). #280 handed "a container with p6 RW is a p6 writer" to #274 (`280-tmp-trust.md:553`). | `docker ps -a`, `docker inspect lora-rx`; repo grep |
| E21 | The OTS containers mount only docker volumes under `/opt/batdata/docker/volumes/` (RW) and `apps/opentakserver/rabbitmq-extra.conf` (RO). No tenant container mounts the apps dir RW. | `docker inspect` mounts, 04 |
| E22 | halow-status already reads the run-dir verdict (#280), so v5's "wrong drift file" MINOR is closed; it does not check the verdict's age (D7-8 adds that). | `halow-status:90-96` |
| E23 | The cleanstop-274 negative-control seam `fault.274-rmstop-once` lives on p6 (`/opt/batdata/state/`), i.e. writable by any container with p6 RW (E20). | `payload-stop.sh:98-103`, `daily-validation.sh:1123` |
| E24 | `dockerd-restart.sh` recorded a 1.5.2 baseline where an `unless-stopped` container came back `exited` after `/etc/init.d/dockerd restart`, while after an OTA they are revived (E6/E15). Unexplained; v6 does not depend on either behaviour (policy `no` everywhere). | `scripts/node/dockerd-restart.sh:5,25` |
| E25 | dockerd's shutdown: `Shutdown()` returns early under live-restore; otherwise every running container goes through `shutdownContainer` → `containerStop` (its StopSignal, then StopTimeout). The API is closed before `Shutdown`, so nothing can start a container during it. | `dockerd-27.3.1/daemon/daemon.go:1343-1350` and `cmd/dockerd` (reviewer A) |
| E26 | `docker kill` sets `HasBeenManuallyStopped=true`, so a killed container is NOT restarted by a restart policy: `docker kill` does not model a crash. | `daemon/kill.go:89-90` (reviewer A) |
| E27 | dockerd keeps events in an in-memory ring of 256; every health-gate `docker exec` adds 3 events, canary runs add more (04: 44 events at +761 s). | `daemon/events/events.go:12` (reviewer A); 04 |
| E28 | procd's halt: `kill(-1,SIGTERM)`, `sleep(1)`, `kill(-1,SIGKILL)`. dockerd has no `STOP=`, so no K link: at shutdown, whatever K08/K09 did not stop dies in that sequence. | procd `state.c:186-196`; `/etc/rc.d` on 04 (K08 prestop, K09 guardian, S95 firstload, S99 guardian, S99 dockerd) |
| E29 | **The guardian's tick executes p6 files as root every 30 s:** `sh $DIR/reconcile-resources.sh` (`payload-guardian.sh:102`), which *sources* `*.hardening.env` (`reconcile-resources.sh:52`); `$DIR/verify-profile-*.sh` by glob (`:125-127`), which runs `$HERE/verify-profile.sh` (`verify-profile-ots.sh:12`), which sources the env file (`verify-profile.sh:30`). `verify-profile.sh` is on p6 but **not** in the golden set (`.golden-files` on 04 lists 10 files without it), so the boot-time refresh never restores it. A glob also picks up *new* attacker-named files, which the refresh never touches. `restore_payload_guardians` installs any root-owned `apps/*/*.init` into `/etc/init.d` (`95-batman-storage:556-559`). | code; 04 |
| E30 | Start mode's `walk prep` does `chown`/`chmod 0400` on `apps/<t>/secrets/*` after only `[ -f ]` — busybox chown follows symlinks. | `payload-run:235-236` |
| E31 | The health gate's `docker exec` has no timeout: a hung exec holds the tenant lock forever. | `payload-run:134` |
| E32 | autocommit commits after `NEED=3` healthy polls 10 s apart, with a drift file younger than 1 min and the pre-commit canary. | `batman-autocommit:29-30,443-452,479-499` |
| E33 | `batman-prestop-payload start` is a no-op; its `stop` sets `.stopping` for every tenant; the guardian's `start_service` clears `.stopping` unconditionally. | `batman-prestop-payload:10-22`, `payload-guardian.sh:42` |
| E34 | Harness F2 removes `rabbitmq` (container and image), reloads the image and runs a manual `payload-run <t>` rebuild. | `fault-injection.sh:153-158` |
| E35 | `docker update --restart <p>` changes neither the `batman.cfg` label nor the cfg hash (the hash is computed from the manifest render). | §5; `payload-run:256` |
| E36 | Tenant containers run non-root (1000:1024, 999, rabbitmq); daemon.json has no userns-remap, so a root container writes root-owned files on the host. `/opt/batdata/{apps,state,log}` are root 755. | 04 (reviewer B) |
| E37 | The autocommit deadline is an absolute uptime, `max(600, start+300)` on a Pi 4 (`DEF=600` unless bcm2837); a real commit happens at ≈ +87–90 s (04: `SLOT COMMITTED … up=89`). A **hold-commit** only blocks the commit — "the deadline revert stays armed" (`:274`); `release` then leads into the normal gate, which needs drift OK (`:153-163`). What stops the deadline revert is a **revert hold**: `held()` = a root-owned `/tmp/batman-autocommit.hold`, a consumed `autocommit-hold-once` on p6, or this boot's HOLDC (`:93-105`), checked at the deadline (`:232`); and a slot that is no longer a real tryboot is not reverted (`:233`), so a manual `batman-slot commit` before the deadline stands. | `batman-autocommit:93-105,153-163,232-233,274,376-380`; ota-trace on 04 |
| E38 | The 1.5.7 golden refresh (run by `/etc/init.d/batdata-mount` every boot) prunes every regular file listed in the previous `.golden-files` that its own golden lacks (`batdata-mount:170-185`), and the 1.5.7 `verify-profile-ots.sh` exits 2 without `$HERE/verify-profile.sh`. So *adding* a file to the golden set that an older image needs on p6 breaks the older image after a revert. | 04 (reviewer B) |
| E39 | The guardian's own start-up runs `for f in "$DIR"/*.fw4.uci; do sh "$f"` on the p6 dir, separately from payload-run's `apply_fw4`. | `payload-guardian.sh:72` (reviewer A) |
| E40 | A killed `docker exec` client leaves the exec'd process running inside the container. | reviewer A/B (to be measured on 04 before the PR, 12.8) |
| E41 | `docker start` resets `RestartCount` to 0. | moby `start.go:158-160` → `container.go:636` (reviewer A) |
| E42 | K08's client half alone took 7.9 s on 04 (idle); one K script has 15 s before procd TERMs it. | `payload-stop.log`; procd |
| E43 | rcS runs each `S*` link by path; a link removed before its turn is not run, which is how firstload's `disable` keeps S99 from starting the guardian in a hold. 03 (Pi 3) carries `K08batman-prestop-payload`, `payload-guardian.sh` and `payload-stop.sh` but no tenant. | procd `rcS.c`; 03 (reviewer B) |
| E44 | OTS manifest `HARDEN`/`MOUNT`/`SECRET` values are plain basenames joined to the tenant dir (`payload-run:163,212-229`); `VOLUME` names docker named volumes. Nothing checks for `/` or `..`. | `deploy/ots/ots.manifest`; `payload-run` |

### 12.2 Design

**D7-1 Restart policy `no`; the guardian is the only automatic starter, and it enforces the policy.**
- `payload-run` always renders `--restart no` after `$HARDEN_FLAGS` (so a hardening file cannot override it; the
  CI hardening-file check also rejects `--restart` there). A manifest `RESTART` other than `no` (header or per
  container) is ignored with a WARN. `profile.yaml` (ots, dummy-nginx, dummy-nginx-b) say `restart: "no"`,
  `profile-to-manifest.py` defaults to `no`, manifests are re-rendered, CI fails on any other value.
- The rendered argv is in the cfg hash: the first boot on v8 converges by one rebuild (T6 path). A downgrade
  rebuilds once the other way.
- **Runtime enforcement (A1):** the policy can be changed after creation (`docker update`, E35), which no label
  shows. **After the start-up converge** and on every 30 s tick, the guardian reads
  `{{.HostConfig.RestartPolicy.Name}}`, `{{.RestartCount}}`, `{{.Id}}` and `{{.State.StartedAt}}` of each manifest
  container. The policy is reset (`docker update --restart no <c>`, logged `restart policy of <c> was <p> — reset
  to no`) on **every** container with our tenant label, old config included (v8.1, A-3). The ledger record and
  the trial judgement apply only to containers **whose `batman.cfg` label equals the current hash** (v8, B-N1:
  containers revived from an older image before the converge — the first OTA into v8, L-OTA1 — are rebuilt by
  that converge and never judged): policy ≠ `no` there → ledger record `policy`. `RestartCount` > 0 → ledger record `policy` once per (container ID, StartedAt),
  deduplicated against the ledger itself, not memory (`docker start` resets the count, E41; a respawn must not
  record it twice — A-6, B-n8). The guardian is thereby the single owner of the runtime policy.
- Operator starts remain and are serialized by the tenant lock: `payload-run <t>` (rebuild), `--renet`, and
  the guardian's own converge. They are listed in 12.3.

**D7-2 live-restore stays off; the config says so; a violation is a host alarm.**
- `99-batman-payload-docker` stops setting `live_restore` and `no_new_privileges` (the stock init maps neither,
  E1) and deletes both keys; `patches/0004-*` (never applied) is deleted.
- Why off: with policy `no` dockerd's shutdown is what stops the tenant on every sysupgrade path (CLI, LuCI, raw
  ubus, `-F`), gracefully and in < 1 s (E14, E25). With live-restore the containers would outlive dockerd and
  meet stage 2's TERM/KILL. Price: a dockerd restart stops the tenant; the guardian restarts it in order.
- The guardian checks `LiveRestoreEnabled` at start; `true` goes to the **host alarm** (D7-5), not the tenant
  verdict: it is a node-wide condition that an OTA cannot fix, so it must not make every OTA revert (A3, B-M3).
- Per-container `no-new-privileges` is unchanged; the daemon-wide default is a leftover (12.10).

**D7-3 The guardian restarts crashed containers quickly, on whatever config they carry, and keeps a record
autocommit can trust.** (A4, B-M1, B-M2, B-M5, B-m1, B-m2, B-m9, A9)
- **Detection every 5 s.** The guardian loop polls liveness with one call,
  `docker ps -a --filter label=batman.tenant=<t> --format '{{.Names}} {{.State}}'`, every 5 s; the full verify
  (verify-profile, cfg, policy, mounts) keeps its 30 s cadence. One CLI call per 5 s (measured cost to be
  recorded on both boards before the PR; a Pi 3 carries no tenant).
- **Restart = start the existing containers, never rebuild.** New mode `payload-run --restart-exited <t>`:
  for each manifest container in state `exited|created|dead` that carries `batman.tenant=<t>`, `docker start`
  it **on whatever config it has** (current or old cfg label alike, B-M1/A4a), final tier first and gated if
  any final-tier container is down, then the rest. No `all_match`, no rebuild, no `*.fw4.uci`, no `walk prep`,
  no network change. It honours `.stopping` and the shutdown marker (exit 4). A container under a manifest
  name *without* our tenant label is never started (bypass, T7) → DRIFT. A container the D7-6 check classes as
  dangerous (possible for one created before v8, which never passed that preflight) is never started either →
  DRIFT (B-n7).
- **The poll classifies by manifest name (v8.1, A-2b):** for each manifest container name, `docker inspect`
  gives one of: *running*; *exited/created/dead with our tenant label* → restart path; *exists without our
  label* (T7 bypass) → DRIFT `container <c> is not ours`, never started, no respawn; *absent* → missing path.
- **A missing container** (`docker rm`, prune, harness F2 E34) cannot be started: unless `.stopping` or the
  shutdown marker exists (then nothing — A-2a: the RMSTOP seam removes containers inside a stop), the guardian
  writes a ledger record `missing <c>` and exits for respawn, so procd restarts it and its start-up converge
  rebuilds (the preflighted path) — today's recovery, kept. At most once per 600 s; otherwise DRIFT
  `container <c> missing`.
- **Backoff (B-m1, B-M5)** on `/proc/uptime`: attempt k after the crash is made at once for k = 1, then after
  min(10·2^(k−2), 60) s since the previous attempt (0, 10, 20, 40, 60, 60, …); k resets after 600 s with no
  attempt. Worst case one restart per 60 s, like docker's own cap.
- **Ledger** `$R/batman-payload-<t>-restarts` (root-only run dir, per boot): a line
  `<uptime> <kind> <names> [id=<12 hex> started=<StartedAt>]` (kind = `crash|missing|policy|respawn`; the
  `id`/`started` fields on `policy` records are the dedupe key, B-R4) is appended **before** each action. If the
  append fails (e.g. `/tmp` full), the tenant is DRIFT `ledger unwritable` and the in-memory backoff applies
  (B-m2). A busy tenant lock makes payload-run exit **5** (new code): not ledgered, retried at the next poll.
- **Bounded gates (B-m9, A-3, B-n1, E40):** the health command runs *inside* the container under
  `timeout 8` (`docker exec c timeout 8 sh -c "$HEALTH"`), so a hung check is killed where it runs; the CLI is
  also killed after 10 s as a backstop. payload-run's preflight checks that each gated image has `timeout`
  (all three OTS images are Debian/Ubuntu based — to be confirmed per image before the PR); without it the
  gate falls back to the CLI kill and logs a WARN.
- **Verdict (B-M2):** `DRIFT` while the ledger has any record in the last **600 s**, or a manifest container is
  not running at the end of a tick, or the cfg / verify-profile / policy / tenant-mount / golden-file rules
  fire. drift.json `status` stays `OK`/`DRIFT`; the verify log names the reason.
- **What that means for an OTA trial — the user's decision (12.13, 2026-10-09):** a trial ends at an absolute
  uptime (≈ 600 s on a Pi 4, E37), so **any crash of a current-config container after the start-up converge
  during a trial reverts the OTA.** A crash is a bug to be fixed; the trial is the gate a new image must pass, so
  a new image that crashes in it is not committed. Consequences, stated, not hidden:
  - an external cause (a malformed CoT from the mesh, a start-up race) also reverts the OTA — the old slot would
    crash the same way, so the revert does not fix it, it only blocks the upgrade;
  - **the remedy is manual (v8.1, corrected — B-R1; v7 and v8 named a hold-commit + `release`, which does not
    stop the deadline revert, E37):** (a) after checking the crash, `batman-slot commit` before the deadline —
    the watchdog then stands down; or (b) a **revert hold** set before the OTA (`autocommit-hold-once` on p6, or
    a root-owned `/tmp/batman-autocommit.hold` during the trial), then `batman-slot commit` by hand;
  - a crash *after* the commit (≈ +90 s, E37) cannot revert anything: it is DRIFT for 10 min (halow-status) and
    recorded. A slow crash loop whose first crash comes after the commit is therefore committed — inherent to
    autocommit's short dwell, the same today; stated in 12.10.
  This policy is written into `docs/design/ab-autocommit.md`.
- **What does not count:** containers revived from an older image before the start-up converge (L-OTA1); the
  start-up converge itself — precisely (v8.2, A8.1-2 / B-P5; no wall clock involved): an exit counts as a
  `crash` only if **that container ID was seen `running` by a 5 s poll after `converge done`**; a container never
  seen running after the converge is a converge failure (FAILED=1 → DRIFT), not a crash record. Unit test with
  a stepped clock; such an exit makes the converge itself fail (FAILED=1 → DRIFT for
  that converge, B-R8) but is not a `crash` record; a busy lock (exit 5); and any exit while `.stopping` or the
  shutdown marker exists — the guardian checks both **before** writing a record or acting (B-R3, A-2a). Ledger kinds that count: `crash`, `missing`, `policy`,
  `respawn`.
- **PRIMARY** is restarted like any other container; the PRIMARY exit is removed (E19).
- **Respawn accounting (A9, B-m3):** `$R/batman-payload-<t>.up` is created after the first converge of a
  guardian instance and **removed by `start_service`**. A guardian process that finds it at start was respawned
  by procd (not started by an operator or at boot) and ledgers the starts of its converge as `respawn`.
- **RestartCount as DRIFT rule and `RC_STATE` are removed** (replaced by D7-1's enforcement and the ledger).

**D7-4 Shutdown, stop and firstload never undo each other.** (A5, B-M4, B-m4, B-m5)
- **Shutdown marker.** `batman-prestop-payload` gets a `shutdown()` handler (rc.common calls `K* shutdown` at
  system shutdown; an operator `stop` calls `stop()`): it writes `$R/batman-shutdown` (per boot, never removed),
  then does what `stop()` does. While the marker exists: the guardian's `start_service` refuses (returns 1,
  logs), payload-run refuses every mode (exit 4, like `.stopping`), and the firstload loader does not call
  `start`.
- **Reboot during the firstload hold.** The hold `disable`s the guardian, which also removes its K09 link; K08
  then stopped only the clients and procd's halt KILLed postgres after 1 s (E28). v8 (instead of v7's "K08 does
  both halves", which would not fit one 15 s budget, E42 — A-9, B-n2): firstload removes **only the guardian's
  S link** (`rm -f /etc/rc.d/S??batman-payload-<t>`) — enough to keep S99 from starting it this boot (E43) — and
  keeps its K09 link, so a shutdown during the hold runs the normal two-half stop (K08 clients, K09
  `pstop_final`). `enable` later restores both links as today.
- **The boot after a hold (v8.1, A-5):** rcS took its S list before S11 re-created the S99 link, so S99 does not
  start the guardian on that boot. firstload's S95 `boot()` therefore starts (after the marker check) the
  guardian of a tenant that has **no** tars left **and whose `S??batman-payload-<t>` link was missing** (B-P4: on
  a normal boot S99 starts it, so S95 does nothing); tenants with tars are held as above. Host test: S link
  present → no start from S95; absent → started.
- **firstload incomplete branch** starts the guardian (`/etc/init.d/batman-payload-<t> start`, not `enable`)
  instead of the stack, after checking the shutdown marker (and `start_service` checks it again). Every
  container start now goes through the guardian. The complete branch gets the same check.
- **`.stopping` that sticks (B-m5):** `batman-prestop-payload start` clears `.stopping`/`.stop0` for tenants
  whose guardian is running, unless the shutdown marker exists.

**D7-5 Host alarms are not the tenant verdict.** (A3, B-M3) A new run-dir file
`$R/batman-payload-host-alarm` (writer: the guardian; one line per condition, rewritten each tick) carries
node-wide conditions that an OTA cannot cause or fix: foreign containers (D7-6), live-restore on (D7-2),
p6 files in a golden tenant dir that are not from the image (D7-7; inert, never executed — A-5, B-N3), a
non-golden tenant dir (D7-7). halow-status shows each as WARN; each new line is logged to
syslog once. autocommit does not read it, so a pre-existing condition cannot make every OTA revert.

**D7-6 Dangerous containers are detected (foreign) or refused (ours).** (A2, B-M6)
- **An allowlist, not a denylist (v8, A-4, B-N4).** A container is *acceptable* only if everything it has is on
  this list; anything else makes it *dangerous*:
  - network: a user-defined bridge (the tenant's own, for tenants) or `none`;
  - mounts: named volumes of the `local` driver **without driver options** (a `-o type=none,o=bind,device=…`
    volume is a disguised bind), and read-only binds of a file inside that tenant's own dir;
  - no `--device`, no `--privileged`, no `--volumes-from`, no host pid/ipc/uts/userns/cgroupns, no
    `seccomp=unconfined` / `apparmor=unconfined`;
  - added capabilities only from a fixed list (today: none for OTS; the list lives in payload-run and is the
    same one verify-profile uses), and `no-new-privileges` set;
  - no bind of `docker.sock`.
- **Foreign** containers (no `batman.tenant` label of an installed tenant) that are dangerous → host alarm, any
  state (a stopped one can be started). There is no exclusion. **Our own helper containers are made to pass
  the allowlist** (v8.1, A-1, B-R2 — today they would not): the autocommit canary (`batman-autocommit:136`) and
  payload-run's prechown vehicle (`payload-run:153`) run with `--network none --security-opt no-new-privileges`
  (the vehicle keeps `--user 0` and its named volume, both allowed); the harness `dv-*` containers likewise,
  where what they test needs otherwise: `dv-web` in the load soak (`soak-node.sh:19`, `--network host`),
  `dv-decoy` (`daily-validation.sh:281`, default bridge) and the container-lifecycle suite (default networking)
  raise host-alarm lines while they run — expected, reported by those suites as known-transient, no exemption in
  the guardian (B-P3, A8.1-3). host-alarm-274's "no alarm line" assertion covers only the canary and the
  prechown vehicle.
  host-alarm-274 asserts that a canary run and a rebuild raise no alarm line (negative: today's canary would).
- **Tenant** containers are checked on the 30 s tick against the same list → tenant DRIFT.
- **payload-run's preflight** applies the same allowlist to what it would create → a rebuild that violates it is
  refused (the existing REFUSED path: old containers that pass the allowlist keep running on their old config,
  DRIFT; a dangerous old one is not started, D7-3).
- **Manifest values are basenames (B-N4, E44):** `HARDEN`, `MOUNT` sources and `SECRET` names must match
  `[A-Za-z0-9._-]+` and must not be `.` or `..`; anything else is a preflight problem. Absolute MOUNT sources are
  refused (A-11: this also stops an RO mount of host secrets such as `/etc/config/wireless`).
- The cleanstop seam `fault.274-rmstop-once` moves to `$RUNDIR/`, read with `batman_opf` (E23).
- **Secrets (A2):** `walk prep` refuses a symlinked or multiply-linked secret (`[ -L ]`, link count) before the
  chown/chmod and reports it as a preflight problem.

**D7-7 For a golden tenant, root never executes a p6 copy.** (B-M6, E29, A-2)
- **Every root exec site over a tenant dir, before → after:**
  - `payload-guardian.sh:72` — the guardian's own start-up `*.fw4.uci` loop (E39): **removed**; fw4 rules are
    applied only by payload-run's `apply_fw4` (start mode / rebuild), which uses the golden copy. With policy
    `no` every boot's start-up converge runs start mode (nothing is running yet), so a fresh A/B slot still gets
    the rules at boot (#206); a guardian restarted mid-boot with the stack running needs none (they are in uci);
  - `payload-run:276-277` `apply_fw4` — `*.fw4.uci`: golden copy;
  - `payload-guardian.sh:102` `reconcile-resources.sh` (sources `*.hardening.env`, `:52`): golden copy, `HERE` =
    golden dir;
  - `payload-guardian.sh:125-127` `verify-profile-*.sh` → `verify-profile.sh` (sources the env): golden copy;
    the helper `verify-profile.sh` ships in the image at `/usr/lib/batman/verify-profile.sh` and the v8 golden
    wrapper looks there first. It is **not** added to the golden set (B-N2, E38): a 1.5.7 refresh after a
    revert would otherwise prune the p6 copy its own wrapper needs. Rule: the golden set may only gain files no
    older image needs on p6.
  - `payload-run` HARDEN parsing (not sourcing) — read from the golden dir, and the cfg hash covers the bytes
    actually used (the golden copy), not the p6 copy (v8.1, B-R6: else a p6-only edit would change the hash and
    rebuild the whole stack for nothing, twice);
  - `95-batman-storage:556-559` `restore_payload_guardians` — installs `apps/*/*.init` (and `deploy/*/*.init`)
    into `/etc/init.d`: v8 **generates** the guardian stub instead of copying a p6 file (B-N4). v8.1 (A-4, B-R5):
    the template ships in the image and is **byte-identical to today's golden
    `batman-payload-opentakserver.init` with the tenant name substituted** (`#!/bin/sh /etc/rc.common`,
    `START=99`, `STOP=09`, `USE_PROCD=1`, `PAYLOAD_TENANT=<t>`, `. /usr/lib/batman/payload-guardian.sh`), so
    `enable` creates S99 and K09 as today; it is generated only for a dir whose name matches `[a-z0-9-]+` **and
    that holds a `*.manifest`** (fault-injection F1's `apps/faulttest/` has none → no guardian); the
    `deploy/*/*.init` path is dropped (a file there is a host alarm: a legacy `batman-ots.init` would bring back
    the double guardian `chk_167g` guards against). No p6 `.init` is executed. Proofs: a host test (stub content,
    S99 + K09 after restore, no stub without a manifest, `deploy/` ignored) and guardian-192 (overlay clear +
    reboot restores a working guardian).
  The executed copies live on the read-only squashfs: no TOCTOU.
- **Comparison:** on each tick the guardian `cmp`s every golden file's p6 copy with the image's; a difference is
  **tenant DRIFT** (the boot-time refresh made them equal, so a mid-boot difference means a writer since boot).
  A p6 file in the tenant dir that is **not** from the image (leftovers like 04's old `EudHandler-264.py`, or a
  planted one) is never executed and goes to the **host alarm**, not the verdict (A-5, B-N3: otherwise a leftover
  file would revert every OTA).
- The manifest is still read from p6 (converge-274 changes it on purpose); what it can request is bounded by
  D7-6 (allowlist, basenames).
- **Non-golden (operator-installed) tenant dirs** still have their scripts executed by root (their guardian stub
  is generated, their `fw4.uci`/`verify-profile-*.sh` come from p6) and are listed in the host alarm. **A root
  container with p6 RW is host root, whatever D7-7 does** (it can plant such a tenant, edit `state/` flags or
  `docker/` container configs) — the only prevention is that no such container exists (D7-6 alarm; only root can
  create one). Stated in 12.6 and 12.10.
- p6 edits of a golden tenant's `*.hardening.env` no longer take effect mid-boot (they never survived a boot:
  the refresh restores them) and are now DRIFT; resource tuning stays `docker update` under the reconcile pause
  (`reconcile-resources.sh:14-31`), unchanged (B-n6).

**D7-8 Operator view (A10).** halow-status shows a verdict older than 90 s as WARN `payload <t>: verdict stale`
(the guardian is stuck, respawning or dockerd is down), and its DRIFT text says "degraded — see verify log"
instead of "no longer matches its hardened profile" (DRIFT now also means a recent crash).

**D7-9 Correct the wrong statements** (E11 + A12): `payload-guardian.sh:10-21,83/92`, `payload-run:26-27,316`,
`payload-stop.sh:10-11`, `batman-autocommit:8`, `profile.yaml:128-132`, `167-payload-manager.md:403,473`,
`99-batman-payload-docker:21-26`, `test-payload-run.sh:101`, `daily-validation.sh:312-327,885`, and §1 item 1 /
§2 T2,T3,T5,T12 / §5 of this document (12.9).

### 12.3 Ownership

| resource | owner (may change it) | others |
|---|---|---|
| tenant container started | **guardian** (start-up converge, D7-3 restarts); operator `payload-run <t>` / `--renet` (serialized by the tenant lock) | autocommit, halow-status, tests (read) |
| tenant container stopped | `payload-stop.sh` (K08/K09, operator `stop`); payload-run `remove_stack` (a rebuild stops the whole stack, postgres included — also on the L-RM path); dockerd's own shutdown (OTA, dockerd stop/restart); procd's halt for anything left (E28) | — |
| container existence / config (create, rm) | payload-run (guardian converge, operator rebuild/renet) | guardian (cfg hash) |
| restart policy (creation and runtime) | payload-run renders `no`; the guardian resets any other value | `docker update` by anyone else = corrected + ledgered |
| golden tenant files on p6 | golden refresh (boot) | guardian/payload-run *compare*; execution uses the image copy |
| non-golden tenant files on p6 | operator install | payload-run, guardian (execute) |
| the rest of p6 (`state/`, `log/`, `docker/`) | root host components (as today) | no container may mount any of it RW (D7-6) |
| dockerd process | procd via the stock init | everyone |
| daemon config | stock init from uci (we set data_root, iptables) | guardian (live-restore check) |
| ledger, `.up` | guardian | tests |
| host alarm file | guardian | halow-status, tests |
| shutdown marker `$R/batman-shutdown` | prestop `shutdown()` (create; never removed this boot) | guardian start_service, payload-run, firstload loader |
| `.stopping`, `.stop0` | set: payload-stop. Clear: guardian `start_service`, firstload S95, prestop `start` — each only when the shutdown marker is absent | payload-run, guardian loop |
| `.converging` | guardian | autocommit |
| drift.json | guardian | autocommit, halow-status, tests |
| tenant lock / pid | payload-run wrapper | payload-stop (`pstop_kill`) |
| `fault.274-rmstop-once` | harness (root, ssh) | payload-stop (consumes once) |
| `fault.274-window60`, `fault.274-health-<c>`, `fault.274-leftover-drift` (run dir) | harness (root, ssh; removed by its trap; gone at reboot) | guardian / payload-run (each use logged) |
| firstload latch | firstload | autocommit |
| procd's blocked window during sysupgrade (watchdog budget) | procd / platform_check_image; **v8.2 adds 0 s** | — |
| guardian S link during a firstload hold | firstload (removes the S link only); `enable` restores | rcS |
| golden set (`.golden-files` content) | the image's golden dir; rule: never add a file an older image needs on p6 (E38) | refresh/prune of every image version |
| `payload-stop.log` | `pstop_final` | tests |

### 12.4 Contracts

- **Ledger** `$R/batman-payload-<t>-restarts`: lines `<uptime int> <crash|missing|policy|respawn> <names…>
  [id=<12 hex> started=<StartedAt>]`;
  per boot; missing = none this boot. Appended before acting; a failed append is DRIFT (`ledger unwritable`).
  Malformed lines are counted as a record (fail-closed for the verdict). Root-only dir.
- **`.up`**: present = this guardian instance (or one before it since the last `start_service`) completed its
  start-up converge. Created by the guardian, removed by `start_service`. Missing at a respawn → that respawn's
  starts are not ledgered (fail-open, one converge; stated).
- **Shutdown marker** `$R/batman-shutdown`: written by prestop `shutdown()`. Missing → no shutdown in progress.
  Its absence during a real shutdown (prestop not installed) = today's behaviour.
- **Host alarm** `$R/batman-payload-host-alarm`: lines `<kind> <detail>`; rewritten every tick; missing = no
  alarm; read by halow-status only.
- **payload-run exit codes:** 0 ok · 1 failure · 2 usage · 3 `--start-only`: config changed · 4 being stopped or
  shutting down · **5 tenant lock busy (new)**. The guardian's restart path: 0 → nothing; 1 → DRIFT, backoff;
  4 → nothing; 5 → retry next poll, not ledgered; anything else = 1.
- **`payload-run --restart-exited <t>`** (new mode): starts existing labelled containers only, no other effect.
- **Env inputs:** `PAYLOAD_LOCK_WAIT` (existing) is set only by root callers (the guardian under procd); no new
  env var (v6's `PAYLOAD_SKIP_FW4` is replaced by the mode).
- **drift.json `status`**: `OK`/`DRIFT` (unchanged); autocommit requires `OK` and < 1 min old.
- **Manifest `RESTART`**: only `no` is meaningful; other values ignored with a WARN.
- **Test seams (root-only run dir, read with `batman_opf`, consumed or removed by the test's trap):**
  `fault.274-rmstop-once` (cleanstop negative), `fault.274-window60` (the guardian uses a 60 s ledger window —
  crash-274 step 4 negative), `fault.274-health-<c>` (its content replaces container `<c>`'s HEALTH command —
  crash-274 step 10). A non-root process cannot create them (0700 root dir); a stale one only shortens the
  window or changes one gate until the next boot (tmpfs), logged at every use.
- **Manifest `HARDEN` / `MOUNT` source / `SECRET`**: basenames `[A-Za-z0-9._-]+`, not `.`/`..`; else refused.
- **Generated guardian stub**: `/etc/init.d/batman-payload-<t>` for `<t>` matching `[a-z0-9-]+`, written by
  `restore_payload_guardians` from a template in the image; a p6 `.init` is never copied.
- **uci `dockerd.globals.live_restore` / `no_new_privileges`**: deleted; the live-restore check is the backstop.
- **Guardian syslog lines tests parse:** `restart: <kind> <names> (attempt <k>)`, `restart policy of <c> was
  <p> — reset to no`, `host alarm: <kind> <detail>`, `p6 file <f> …`. Every test that expects such a line
  FAILs when it finds none.

### 12.5 Lifecycle matrix (today → v8.2; proof)

| path | today | v8.2 | proof |
|---|---|---|---|
| L-FIRST first boot, firstload complete | firstload loads, guardian rebuilds | same, `no` | flashgo-159, payload-config-golden (wants `no`) |
| L-FIRST2 firstload incomplete (≤ 3 boots) | stack started by firstload, guardian down, docker restarts crashes; after an OTA/power loss `unless-stopped` keeps the old stack up during the load | guardian started (not enabled), supervises, restarts on old config, DRIFT. **The tenant is dark while the loader works** (up to `LOAD_TIMEOUT` 600 s per tar, on each of ≤ 3 boots) on every boot type, since nothing revives it (B-R7) — stated | flashgo-159 extension: a tar `docker load` rejects; assert guardian running + stack up, print the dark window (first container start − boot); negative: old loader leaves the guardian stopped |
| L-HOLD-REBOOT reboot during the hold | K08 stops clients only; postgres SIGKILLed by halt (E28) | firstload removes only the S link; K09 runs `pstop_final` as on any shutdown | **hold-reboot-274**: hold the guardian exactly as the v8 loader does (S link removed), reboot; the discriminating check is the **stop record** (k08 and k09 halves, each < 15 s); postgres `shut down at` reported; negative: holding it as today (`disable`) → no k09 record (B-n3: the postgres check alone is racy) |
| L-LATE-START firstload loader `start` while shutting down | `--start-only` honours `.stopping`; complete branch can restart the guardian mid-shutdown | marker → refused | host test (`scripts/test-payload-run.sh` + a guardian/loader stub): marker present → start_service rc 1, payload-run rc 4, loader skips; negative: without the marker the start runs |
| L-BOOT boot after a clean stop | ordered start | same | cleanstop-274 (start-event count by container ID replaces RestartCount) |
| L-STOP clean shutdown / reboot / revert / poweroff | K08/K09 graceful | same + shutdown marker | cleanstop-274 |
| L-PRESTOP-OP operator `batman-prestop-payload stop/restart` | `.stopping` sticks for the boot (E33) | `start` clears it (no marker) | host test |
| L-OTA OTA (CLI, LuCI, ubus, `-F`) | graceful stop (E14); revival of all 6 at once; 2 crash-restarts; false DRIFT (E15) | stop unchanged; ordered start; 0 restarts; first verdict OK | **ota-start-274**; negative = E15 |
| L-OTA1 first OTA into v8 | — | revival by the old policy once (old containers crash once, E15); the start-up converge rebuilds with `no`; D7-1/D7-3 judge only current-label containers after that converge, so nothing is ledgered and the trial commits | **first-ota-274** (once per rc, recorded in the PR; on every OTS node at rollout): OTA 1.5.7 → rc must COMMIT with an empty ledger; negative control: a build with the D7-1 check placed before the converge reverts (B-N1) |
| L-OTA-REV revert of that OTA | — | K08/K09 stop; old golden's `unless-stopped`; old guardian rebuilds; the old `verify-profile-ots.sh` still finds p6 `verify-profile.sh` (not pruned: v8 does not add it to the golden set, E38) | fi-r1/r3/r4 revert legs + on the reverted slot `verify-profile-ots.sh` exits 0 (B-N2). Negative (A-6; the golden set is image content, so no run-dir seam can model it): on the reverted slot, the same check with p6 `verify-profile.sh` moved aside must exit 2 — showing the dependency the rule protects; the file is put back |
| L-TRIAL-CRASH a current-config container crashes during a trial (user decision 12.13) | DRIFT one tick, then commit | DRIFT 600 s → the trial reverts; manual remedy `batman-slot commit` (or a revert hold + manual commit) | **trial-crash-274** (v8.1, B-R1/R9, destructive, two real OTA trials): (i) same-build OTA with a hold-commit armed beforehand (it blocks only the commit, E37, so the crash can be injected before any commit); after the start-up converge a client crash is injected, then `batman-autocommit release` → the trial must REVERT at the deadline (`TRIAL-REVERTED … drift not OK`); (ii) same, then `batman-slot commit` by hand before the deadline → asserted on facts (B-P2): no `TRIAL-REVERTED`, boot_id unchanged after deadline + DEFER_MAX, `batman-slot is-trial` = 1, active slot = the new one; and autocommit main, seeing `is-trial` = 1 at its end, logs `COMMITTED-BY-OPERATOR` instead of `NOT committed … watchdog reverts` (`batman-autocommit:507`) so halow-status / fleet tooling do not report a failed OTA; negative for (i): the run-dir seam `fault.274-window60` → the trial commits after release. Plus crash-274 step 4: on a **committed** boot (the dry-run is not side-effect free, A-7), one crash, then an `AUTOCOMMIT_DRYRUN=1` run must print the positive line `NOT committed … payload <t>: drift not OK` (absence of a COMMIT line is not enough); negative: with the window set to v6's 60 s (test seam in the run dir) the dry-run prints `DRYRUN decision: COMMIT` |
| L-EXECFAIL `upgraded` exec fails after `service_stop_all` | procd returns with every service deleted, nothing reboots; dockerd stopped → tenant down | same (upstream; v8 does not touch it) | stated, not induced |
| L-AC autocommit commit/revert | gates on OK | same contract; a crash keeps DRIFT 10 min, i.e. a crash in a trial reverts it (12.13) | fi-r4 (no `drift not OK` after its OTA); crash-274 step 4 |
| L-PWR power loss / watchdog / panic | revival of all 6; postgres crash recovery | ordered start; postgres crash recovery unchanged | **unclean-boot-274** (`reboot -f`); negative: today revives all 6 at once |
| L-GRD guardian restart / respawn | converge | same; respawn's starts ledgered (`.up`) | crash-274 step 6 |
| L-DOCKERD dockerd stop/start/restart (operator, harness `restore_node`) | all stop; revival or not (E24) | all stop gracefully; guardian restarts in order | **dockerd-restart-274** |
| L-DOCKERD-KILL dockerd SIGKILL | containers keep running headless; nothing restarts dockerd | same; the verdict goes stale → halow-status WARN (D7-8) | stated; leftover |
| L-RELOAD uci reload | SIGHUP | same | — |
| L-NET network / fw4 restart | rules persist in uci | same | confinement-98 |
| L-CRASH container crash | docker restarts in ≈ 1 s; DRIFT one tick | guardian restarts ≤ 5 s; DRIFT 10 min | **crash-274** (crash = `kill -9` of the container's PID from the host, E26). Discriminating check: a new `start` event for the container **with `RestartCount` still 0 and policy `no`** — only an API `docker start` (the guardian) can produce that; on today's image the policy restart increments RestartCount (B-n3) |
| L-PRIMARY PRIMARY crash | guardian exits/respawns, accounting lost | restarted, guardian keeps running | crash-274 |
| L-LOOP fast crash loop | DRIFT via RestartCount | DRIFT; attempts 0, 10, 20, 40, 60 s | crash-274 |
| L-SLOWLOOP crash every ~2 min | committed by autocommit if the first crash falls in the trial (B-M2) | DRIFT continuously; a crash in the trial reverts it; a loop whose first crash comes after the commit (≈ +90 s) is committed and shown as DRIFT (inherent, 12.10) | crash-274 step 4 (positive `NOT committed` line) |
| L-OLDCFG crash while running on an old config (converge refused, L-FIRST2, operator image reload) | docker restarts it | restarted on its old config, DRIFT stays | crash-274 step: comment line in the p6 manifest (cfg changes), crash a client → restarted, DRIFT `config changed`; negative: v6's `--start-only` leaves it down |
| L-RM container removed (`docker rm`, prune, F2) | PRIMARY: guardian converge; others: DRIFT forever | respawn → converge rebuild (≤ 1 per 600 s); the rebuild stops and recreates the **whole** stack, postgres included (graceful `docker stop -t 10`) | crash-274 step: `docker rm -f ots_eud_handler_ssl` → back ≤ 180 s; F2 unchanged |
| L-POLICY `docker update --restart …` | hidden second owner | reset to `no`, ledgered, DRIFT | crash-274 step; negative: v6/today no reset |
| L-OPSTOP operator `docker stop <c>` | stays down, DRIFT | restarted as a crash, ledgered | crash-274 |
| L-OPRUN `docker run` bypass (T7) | cfg hash → converge | same; a bypass container is never *restarted* by the restart path | drift-detect-156 |
| L-OPSVC `/etc/init.d/batman-payload-<t> stop/start/restart` | tiered stop / converge | same; `.up` removed by start, so no false crash records | cleanstop-274, payload-mgr-167, converge-274 |
| L-OPOFF operator wants a tenant off across reboots (`disable`) | not possible: `restore_payload_guardians` re-enables every guardian each boot (`95-batman-storage:572`) | same (pre-existing; stated, A8.1-4): the way to keep a tenant off is to remove its manifest; S95 starts a guardian only when its S link is missing *and* restore re-created it this boot | stated; leftover (an explicit "tenant off" marker) |
| L-T6 golden config change | converge rebuild | same | payload-config-golden |
| L-FOREIGN dangerous foreign container | unnoticed | host alarm; tenant verdict unaffected | **host-alarm-274**: create (never start) containers with, in turn, `-v /opt/batdata/state:/s`, `-v /var/run/docker.sock:/s`, `--device /dev/mmcblk0p6`, `--network host`, a bind-disguised local volume; one alarm line each within 35 s, drift status still OK; trap removes them; negative: today no alarm |
| L-GOLDEN-TAMPER p6 copy of a golden script changed / new script planted | executed as root every tick / at guardian start | image copy executed; a changed golden file is DRIFT; a planted file is a host alarm and never runs | **golden-exec-274**: plant `verify-profile-zz.sh` and `zz.fw4.uci` (each touches a run-dir file when run) and append a line to p6 `reconcile-resources.sh`; then two ticks **and a guardian restart**: no file created, DRIFT names the changed file, the alarm names the planted ones; cleanup; negative: today the planted scripts run (A-2) |
| L-LEFTOVER a non-image file already in the tenant dir before the OTA (04: `EudHandler-264.py`) | ignored | host alarm only; the trial commits | first-ota-274 runs with such a file present (B-N3); negative: v7's rule (tenant DRIFT) reverts |
| L-TENANT-PLANT a new non-golden tenant dir planted on p6 | its `.init` installed and run as root at boot | the guardian stub is generated (no p6 `.init` executed), the dir is in the host alarm; its scripts still run (non-golden residual) | golden-exec-274 step: plant `apps/zz/zz.init` + manifest; after a reboot `/etc/init.d/batman-payload-zz` is the generated stub (cmp), alarm line present; negative: today the planted init is installed |
| L-ARBITER arbiter refusal / run dir unusable | dockerd's revival keeps the tenant serving | tenant stays down (fail-closed), DRIFT/log | stated (intended: a colliding or unverifiable tenant should not run) |
| L-REMOTE crash input from the mesh | ≈ 1 s restart + app start | ≤ 5 s + app start; ≤ 1 restart/60 s in a loop; DRIFT blocks OTA commit while it lasts | crash-274 timings; stated (12.6) |
| L-DOWN downgrade to ≤ 1.5.7 | — | older golden + guardian rebuild once; older OTA behaviour | one manual downgrade before the PR (recorded) |
| L-CLOCK wall-clock step | — | all windows on `/proc/uptime` | crash-274 on 04 (2025 clock) |
| L-PI3 bcm2710 (no tenant) | dockerd only; prestop (K08), `payload-guardian.sh`, `payload-stop.sh` installed, no tenant (E43) | uci keys deleted; prestop `shutdown()` writes the marker and finds no tenant; nothing else | ab-selftest on 03 (a reboot: shutdown log has the prestop line, no error), hold-261; both boards built |
| L-BOARDS | — | no board-specific code | build both; ab-card-invariants both SoCs |

### 12.6 Security

**Assets.** Host root (guardian, payload-run and K scripts run as root and act on p6); tenant availability and
DB integrity; OS commit/revert (autocommit reads the verdict); the OTA path (untouched).

**Actual root-exec / root-write paths over p6** (E29, E30, E39), before → after (full list in D7-7):
- `*.fw4.uci`: guardian start-up loop (`payload-guardian.sh:72`) removed; payload-run `apply_fw4` → golden copy.
- `reconcile-resources.sh`, `verify-profile-*.sh` (every 30 s) and the env files they source → golden copies;
  `verify-profile.sh` → `/usr/lib/batman/`; a changed golden file is DRIFT, an extra file a host alarm; neither runs.
- `apps/*/*.init` restore at boot → a generated stub; no p6 `.init` is executed.
- HARDEN/MOUNT/SECRET → basenames only; secrets chown/chmod refused for symlinks/hardlinks.
- Non-golden tenant dirs: their `fw4.uci`/`verify-profile-*.sh` still run from p6 (residual, host alarm).
- **A root container with p6 RW is host root** whatever the above does (non-golden tenant dirs, `state/` flags,
  `docker/` container configs). The only prevention is that no such container exists; D7-6 reports one within a
  tick. Stated, not hidden.

**Attack-surface delta.** New: ledger, `.up`, host alarm, shutdown marker, the four test seams (root-only run
dir; `fault.274-health-<c>`'s content is executed — inside container `<c>` only, as its health command, never on
the host); the `--restart-exited`
mode and exit code 5 (root callers only); the 5 s `docker ps` poll (local socket). Removed: RC_STATE, the PRIMARY
exit, the p6 test seam, execution of p6 copies for golden tenants. No new port, CGI, uci key, env var or mesh
message.

**Actors.**
- *Remote over mesh/WiFi* and *a compromised tenant*: an input that crashes an OTS process: today ≈ 1 s; v8
  ≤ 5 s detection, then restart; a loop is capped at one restart per 60 s; every crash keeps the tenant DRIFT for
  10 min, so **one crash per trial makes every OTA on that node revert** (12.13, the user's decision: a crash in
  the trial is not committed), including an OTA that would fix the crash. Remedy: an operator checks and runs
  `batman-slot commit` before the deadline, or sets a revert hold before the OTA and commits by hand (E37;
  a hold-commit + `release` does not stop the revert). Stated.
- *Remote over LoRa RF:* the `lora-rx` path (root container, p6 RW) is removed from 04 (done 2026-10-09) and
  any such container raises a host alarm.
- *Local non-root process:* cannot write the run dir (0700 root) or p6 (root 755); cannot use the docker socket
  (root:docker 0660; only member: system user `docker`, `/bin/false`, no processes — 04). It *can* fill `/tmp`
  (tmpfs): ledger append fails → DRIFT, in-memory backoff (fail-closed for commit, restarts continue).
- *Compromised tenant container* (non-root inside, E36): can crash itself (bounded by the backoff, always
  DRIFT); cannot write p6 apps (no such mount, refused by preflight, checked each tick); can hang a health check —
  killed inside the container after 8 s (D7-3).
- *Compromised dangerous container (root, p6 RW):* host root (above). For a golden tenant nothing it writes in
  `apps/<t>/` is executed; it can still plant a non-golden tenant, write `state/` flags (`autocommit-skip-once`,
  …), `docker/` (another container's hostconfig, used at the next dockerd start) and logs. Detection only (host
  alarm within one tick). Residual, stated.
- *Physical capture / supply chain:* unchanged; no new package, no firmware patch.
- *Our own mistakes:* a stuck guardian → stale verdict → halow-status WARN and autocommit fail-closed; a restart
  storm is capped; `--restart-exited` cannot rebuild or run scripts.

**Privilege.** No new root path reads a non-root-writable location. **Failure mode:** fail-closed for commit
(any doubt = DRIFT); fail-safe for availability (restarts continue). Fail-opens: `.up` missing at a respawn (one
converge not ledgered).

**Verification (negative tests).** golden-exec-274, host-alarm-274, crash-274 policy step; the new run-dir names
go into `scripts/rundir-paths.txt`, so check-tmp-trust and tmp-trust-280's N8 sweep (non-root pre-creation) cover
them.

### 12.7 Tests (daily-validation; destructive ones in the destructive tier)

- **ota-start-274** (OTS node, destructive). Precondition: the node already runs a v8 image (else FAIL "not
  measurable on the first OTA into v8" — that leg is first-ota-274). One same-build `sysupgrade -n`, then:
  1. each manifest container's *current* ID has exactly one `start` event since dockerd started; the oldest
     event returned must predate the first container start (else FAIL "event buffer wrapped", E27); the boot
     epoch (`date` − uptime) must not move during the test (else FAIL "clock stepped");
  2. two-phase order and a `start mode` line this boot;
  3. no DRIFT this boot until commit; the commit trace has no `drift not OK`;
  4. postgres last start `was shut down at`;
  5. the ledger is empty;
  6. the OTA boot is the new slot via `S2 END rc=0` and boot-reasons `SYSUPGRADE-REBOOT` (no watchdog reset).
  Negative: today's image fails 1 and 3 (E15; re-run once on the old image before the PR). Run once before the
  PR **under CoT load** (the #264 generator) and record the stop timeline (E14 is an idle sample).
- **unclean-boot-274** (destructive): `reboot -f`, then checks 1, 2, 5, and 3 until OK; also reports whether a
  fw-override (EEPROM partition misread) happened this boot. Negative: today's image.
- **first-ota-274** (once per rc, before the PR; then at rollout on each OTS node): OTA 1.5.7 → rc with a
  leftover non-image file in the tenant dir (L-LEFTOVER): the trial must COMMIT, the ledger must be empty, the
  host alarm must name the leftover file. Then the revert leg (fi-r1 style) back to 1.5.7: the old slot's
  `verify-profile-ots.sh` must exit 0 (L-OTA-REV). Negatives on the rc itself via run-dir seams (A-6):
  `fault.274-leftover-drift` (a non-image file is tenant DRIFT, v7's rule; read on the ticks before the commit
  at ≈ +90 s, so it can be armed after ssh is up) must make the trial revert. The D7-1 ordering ("judge only
  current-label containers after the converge") **cannot** be armed in time on a real node — the converge takes
  the tenant lock as soon as dockerd answers (≈ +31 s), before ssh (≥ +49 s) (v8.1 review B-P1) — so its
  discriminating negative is the guardian unit test (stub docker: the same revived-old-container state with the
  check moved before the converge must produce a `policy` record). No `fault.274-policy-early` seam.
- **trial-crash-274** (destructive): L-TRIAL-CRASH (two real OTA trials, 12.5).
- **crash-274** (destructive, OTS node, committed boot). Crashes are `kill -9 <State.Pid>` from the host (E26).
  Steps: (1) client crash → a new `start` event ≤ 10 s with `RestartCount` 0 and policy `no`, ledger `crash`,
  DRIFT for ≥ 590 s then OK; (2) PRIMARY crash → back, guardian PID unchanged; (3) fast loop: 5 crashes as each
  comes back → spacing ≥ 0/10/20/40/60 s (±6 s); (4) trial policy: after one crash an `AUTOCOMMIT_DRYRUN=1` run
  prints `NOT committed … drift not OK` (positive line), negative with the run-dir seam
  `fault.274-window60` (window 60 s) → `DRYRUN decision: COMMIT`; (5) old config: a comment line in the p6
  manifest, crash a client → restarted, DRIFT `config changed`, line removed; (6) `kill` the guardian's shell
  while a client is down → respawn ledgered once (not twice); (7) `docker rm -f` a client → back ≤ 180 s via
  converge; (8) `docker update --restart always` → reset to `no` ≤ 35 s, ledger `policy` once; (9) `docker stop`
  a client → restarted; (10) a health command that hangs (seam: a HEALTH override in the run dir) → no leftover
  process in the container after the gate (E40). Negatives: today's image (RestartCount increments, no ledger,
  PRIMARY respawn, policy not reset); v6's `--start-only` for step 5.
- **dockerd-restart-274** (destructive): `/etc/init.d/dockerd restart` → all 6 back ≤ 180 s in order, ledger,
  postgres `shut down at`, LiveRestoreEnabled false.
- **hold-reboot-274** (destructive): L-HOLD-REBOOT.
- **host-alarm-274**, **golden-exec-274**: L-FOREIGN, L-GOLDEN-TAMPER, L-TENANT-PLANT (each with a trap that
  removes what it created).
- **Order in the run (A-8, B-n4):** every step that writes a ledger record (crash-274, dockerd-restart-274,
  unclean-boot-274 is clean by design, fault-injection's `restore_node`) leaves the tenant DRIFT for 600 s. These
  suites run **last** in the destructive tier; any later suite that asserts drift OK first waits for the
  window to expire (bounded, waited time printed). The harness prints the ledger at each such wait.
- **cleanstop-274**: RestartCount check → start-event count; `DV_TEST_274_NOSTOP` now must FAIL checks 1 and 2
  (no stop record; postgres SIGKILLed by halt), no longer 4; `DV_TEST_274_RMSTOP` uses the run-dir flag.
- **payload-config-golden**: `no`.
- **flashgo-159**: L-FIRST2 extension.
- Host: `scripts/test-payload-run.sh` (RESTART ignored, `--restart no` after HARDEN_FLAGS, preflight refusals of
  dangerous mounts/flags, symlinked secret refused, `--restart-exited` starts old-config containers and never
  rebuilds, never starts a dangerous container, exit 5, marker → 4, basename rule for HARDEN/MOUNT/SECRET incl.
  `../x` and absolute paths refused, the allowlist incl. a bind-disguised volume); a guardian unit test with a stub
  `docker` (backoff sequence, ledger window, append failure, `.up`, marker in `start_service`, D7-1 only on
  current-label containers after the converge, RestartCount dedupe across a respawn); a host test of the
  generated `.init` stub and the tenant-name rule; halow-status stale-verdict test.
- fi-r4 (existing): no `drift not OK` after its OTA.

### 12.8 Measurements before the PR (recorded in the PR)

- CPU cost of the 5 s poll on 04 (Pi 4) — reviewer A measured ≈ 56 ms CPU per call (≈ 1 % of a core at 5 s);
  re-measured over 10 min with and without, on the rc.
- ota-start-274 under CoT load (stop timeline, postgres).
- One downgrade OTA to 1.5.7-wsl.3 and back.
- E40 (a killed `docker exec` client leaves its process) and `timeout` present in each OTS image.
- K08/K09 elapsed during hold-reboot-274, idle and under CoT load (each < 15 s).

### 12.9 §1/§2/§5 corrected

- §1 item 1, §2 T2/T3: the revival is `unless-stopped`, not live-restore (never on, E1). v8: nothing revives.
- §2 T3: procd's `service_stop_all` TERMs dockerd, which stops every container gracefully (E14, E25).
- §2 T5: a dockerd restart stops the tenant; the guardian restarts it.
- §2 T12 disappears.
- §5's "an OTA is not a graceful stop" is wrong for the stop; what an OTA lacked was the ordered start.

### 12.10 Limits and leftovers (to be written into #274 as a checklist)

- **Pi 3 OTA watchdog margin −2…+3 s (E13), pre-existing; v8 adds nothing.** Direction: procd's second full
  validate could reuse stage 1's verdict; an OTA-path change for its own design review.
- dockerd SIGKILL/crash: no respawn in the stock init; containers keep serving headless; stale verdict now
  visible (D7-8).
- Daemon-wide `no-new-privileges` not in effect (per-container is).
- **A root container with p6 RW is host root**; for non-golden tenant dirs and `state/`, `docker/`, `log/`
  there is detection only (host alarm). Closing it needs p6 content verified against the image for everything
  root reads, or userns-remap — its own design.
- One crash per trial reverts the OTA (user decision); during a crash attack no OTA commits automatically
  (manual `batman-slot commit`).
- A slow crash loop whose first crash comes after the commit (≈ +90 s) is committed; it shows as DRIFT.
- `upgraded` exec failure leaves the node without services until a reboot (upstream).
- Power loss still costs one postgres crash recovery.

### 12.11 Alternatives

- **v5's dockerd wrap / stage-1 pre-stop:** unnecessary (E14), and the wrap added to the watchdog window.
- **Keep `unless-stopped` + a start-up grace:** two owners; the crash-restarts stay.
- **live-restore on:** every OTA would kill the tenant instead of stopping it.
- **Event-driven restart (`docker events --filter event=die`)** (B-M5's suggestion): a long-lived `docker events`
  reader in busybox sh needs reconnect handling across dockerd restarts and a second process to supervise; the
  5 s poll gives the same order of latency with one stateless call. Chosen: poll.
- **Gate the commit on foreign containers:** makes a pre-existing condition revert every OTA. Rejected (D7-5).
- **Tolerate one recovered crash in a trial** (DRIFT only for ≥ 2 records in 600 s, or 1 in the last 60 s):
  avoids reverting on an external crash, but commits an image that crashed in its trial. **Rejected by the user**
  (12.13): a crash is a bug; the trial is the gate.
- **K08 runs both stop halves during a firstload hold** (v7): does not fit one 15 s K budget (E42). Replaced by
  keeping the K09 link (D7-4).
- **Add `verify-profile.sh` to the golden set** (v7): breaks a reverted 1.5.7 slot (E38). Replaced by shipping it
  in `/usr/lib/batman/`.

### 12.12 Findings → resolution

| finding | resolution |
|---|---|
| v5 B1 watchdog | no OTA-path change (12.0); Pi 3 margin measured, leftover; ota-start check 6 |
| v5 B2 /tmp control files | all state in the #280 run dir |
| v5 wrap fallback KILLs postgres | no wrap, live-restore off (D7-2) |
| v5 stale marker / `.stopping` sticks | no marker; D7-4 (shutdown marker, prestop `start`) |
| v5 dockerd no respawn | not relied on; leftover; stale-verdict WARN |
| v5 PRIMARY crash loop | D7-3 (PRIMARY exit removed, ledger) |
| v5 firstload hold unsupervised / K90 | D7-4, L-FIRST2, L-HOLD-REBOOT; K90 = L-DOCKERD |
| v5 RESTART contract | D7-1 |
| v5 vacuous RestartCount proofs | start-event count; ledger |
| v5 autocommit STARTING/RECOVERED | no new status; policy change written into ab-autocommit.md |
| v5 halow-status stale file | E22; D7-8 |
| v5 /proc/uptime | D7-3 |
| v5 p6 fault flag | D7-6 |
| v5 restart reruns start mode | `--restart-exited` (D7-3) |
| v5 missing rows | 12.5 |
| A1 RestartCount tripwire | D7-1 runtime enforcement, crash-274 step 8 |
| A2 p6 writers, secrets chown | D7-6, D7-7, 12.6 |
| A3 / B-M3 gate on foreign | D7-5 host alarm |
| A4 / B-M1 restart dead ends | `--restart-exited` on old config; missing → respawn converge |
| A5 / B-M4 / B-m4 firstload, late start, hold reboot | D7-4 |
| A6 / B-m7 events ring, L-OTA1, clock | 12.7 ota-start check 1 + precondition |
| A7 `docker kill` | crashes via PID kill |
| A8 NOSTOP control | 12.7 cleanstop |
| A9 / B-m3 `.up`, lock busy | D7-3 (`start_service` removes `.up`; exit 5) |
| A10 halow-status | D7-8 |
| A11 rows | L-EXECFAIL, L-RM, L-DOCKERD (`restore_node`), L-HOLD-REBOOT |
| A12 inaccuracies | env (12.4), prep (D7-3 no prep), "after HARDEN_FLAGS", E13 margin, D7-9 list |
| A13 resolution table, watchdog check, load sample | 12.12, ota-start check 6, 12.8 |
| B-M2 slow loop committed | 600 s DRIFT window (D7-3); crash-274 step 4 |
| B-M5 remote DoS / latency | 5 s poll, cap 60 s; 12.6 |
| B-M6 security section | 12.6 rewritten; D7-6, D7-7 |
| B-m1 backoff | gap doubling from the last attempt, reset after 600 s |
| B-m2 ledger fail-open | append failure = DRIFT |
| B-m5 `.stopping` sticks | prestop `start` |
| B-m6 ownership | 12.3 |
| B-m8 load sample, fw-override | 12.8; unclean-boot report |
| B-m9 exec hang | bounded exec |
| B-m10 arbiter/run-dir outage | L-ARBITER (fail-closed, stated) |
| **v7 review A** | |
| A-1 600 s window = revert; wrong remedy | user decision 12.13; D7-3 states it; remedy `batman-slot commit` / hold-commit (E37); L-TRIAL-CRASH; 12.6, 12.10 |
| A-2 guardian fw4 exec site | E39; D7-7 exec-site list (loop removed); golden-exec-274 plants `zz.fw4.uci` + guardian restart |
| A-3 exec kill leaves the process | `timeout` inside the container (D7-3); crash-274 step 10; 12.8 |
| A-4 dangerous list, disguised volume, canary label | D7-6 allowlist, volume driver options, no canary exclusion |
| A-5 extra p6 file gates commit | host alarm (D7-5, D7-7); L-LEFTOVER |
| A-6 RestartCount dedupe | (ID, StartedAt) against the ledger (D7-1) |
| A-7 step 4 absence-based, dry-run side effects | positive line, committed boot, seam negative |
| A-8 harness order | 12.7 order |
| A-9 K08 budget | K09 link kept in the hold (D7-4); 12.8 |
| A-10 L-RM cost, ownership | L-RM row; 12.3 stopped row |
| A-11 RO absolute mounts | basenames only, absolute refused (D7-6) |
| A-12 E22 wording | E22 |
| **v7 review B** | |
| B-N1 window = revert; first OTA into v8 | 12.13; D7-1 after converge, current label only; first-ota-274 + negative |
| B-N2 golden set breaks a reverted 1.5.7 | E38; `verify-profile.sh` in `/usr/lib/batman/`; golden-set rule (12.3); L-OTA-REV check |
| B-N3 leftover p6 files revert | host alarm; L-LEFTOVER in first-ota-274 |
| B-N4 allowlist, traversal, non-golden `.init`, statement | D7-6 allowlist + basenames; generated `.init` stub (D7-7); "root container with p6 RW = host root" (12.6, 12.10); L-TENANT-PLANT |
| B-n1 exec leak | as A-3 |
| B-n2 K08 budget | as A-9 |
| B-n3 non-discriminating controls | crash-274 uses start event + RestartCount 0; hold-reboot discriminates on the stop record |
| B-n4 harness order | as A-8 |
| B-n5 L-PI3 row | corrected; ab-selftest reboot check |
| B-n6 hardening edits | D7-7 last bullet |
| B-n7 restart of a dangerous old container; canary label | D7-3 (never started); D7-6 (no exclusion) |
| B-n8 RestartCount record after respawn | as A-6 |
| **v8 review A** (no MAJOR) | |
| A8-1 own helper containers fail the allowlist | canary + prechown vehicle + `dv-*` run `--network none --security-opt no-new-privileges` (D7-6); host-alarm-274 asserts no alarm |
| A8-2 missing path vs `.stopping`; bypass looks missing | poll classifies by name (D7-3); `.stopping`/marker checked first |
| A8-3 policy reset only on current-label containers | reset on every tenant-labelled container; record/judgement current-label only (D7-1) |
| A8-4 stub spec, `deploy/` glob | byte-identical template, manifest required, `deploy/` dropped; host test + guardian-192 (D7-7) |
| A8-5 boot after a hold does not start the guardian | firstload S95 starts guardians of tenants without tars (D7-4) |
| A8-6 negatives need special builds | run-dir seams `fault.274-policy-early`, `fault.274-leftover-drift`; L-OTA-REV negative by moving the p6 file aside |
| A8-7 seams in ownership / attack surface | 12.3 row; 12.6 delta |
| A8-8 E13 wording | E13 |
| **v8 review B** | |
| B-R1 (MAJOR) hold-commit + release does not stop the revert | E37 corrected; remedy = manual `batman-slot commit` or a revert hold + manual commit (D7-3, 12.6); trial-crash-274 with two real trials |
| B-R2 own containers fail the allowlist | as A8-1 |
| B-R3 ledger records during an intended stop | `.stopping`/marker checked before recording (D7-3) |
| B-R4 ledger has no dedupe field | `id=`/`started=` on `policy` records (D7-3, 12.4) |
| B-R5 stub for dirs without a manifest; `deploy/` | as A8-4 |
| B-R6 cfg hash over the p6 HARDEN copy | hash the golden bytes (D7-7) |
| B-R7 dark window during a hold | L-FIRST2 states it; flashgo-159 prints it |
| B-R8 converge boundary | `FinishedAt` before `converge done` (D7-3) |
| B-R9 no end-to-end trial test | trial-crash-274 |
| **v8.1 review B** (no MAJOR) | |
| B-P1 policy-early seam cannot be armed in time | seam dropped; guardian unit test is the negative |
| B-P2 manual-commit assertion; misleading log | factual assertions; `COMMITTED-BY-OPERATOR` log |
| B-P3 `dv-web` host net | stated as expected alarm during the soak |
| B-P4 S95 start on every boot | only when the S link was missing; host test |
| B-P5 `FinishedAt` across a clock step | crash = ID seen running by a poll after `converge done`; stepped-clock unit test |
| **v8.1 review A** (no MAJOR) | |
| A8.1-1 policy-early seam | as B-P1 |
| A8.1-2 boundary on the wall clock | as B-P5 |
| A8.1-3 harness containers and the alarm | named list, known-transient; host-alarm-274 scope |
| A8.1-4 operator `disable` | L-OPOFF row; leftover |
| A8.1-5 log after a manual commit | as B-P2 (`COMMITTED-BY-OPERATOR`) |
| A8.1-6 stale labels | section relabelled v8.2 |

### 12.13 User decisions

1. `lora-rx` on 04: **removed 2026-10-09** (user approved; container only — image, scripts and logs kept).
2. Pi 3 watchdog margin: leftover in #274 (12.10), not scheduled now; scheduling is the user's call.
3. **A crash during an OTA trial reverts the OTA (2026-10-09).** The user's reasoning: a crash is a bug to be
   fixed, so a new image that crashes in its trial is not committed. Excluded: the one-time revival crash of the
   old containers on the first OTA into v8 (that is the symptom #274 removes, not the new image's). Accepted
   consequence: an external crash cause also reverts; the remedy is a manual `batman-slot commit`.

### 12.14 Implementation notes (b0ad503 and after) — where the code differs from the text above

Recorded so a reader of the code and of this section see the same thing; none changes a reviewed property.
- **Host alarm file is per tenant** (`$RUNDIR/batman-payload-<t>-host-alarm`), not one shared file: one writer per
  file (each tenant's guardian); halow-status reads the glob. Node-wide lines (foreign containers, live-restore)
  appear in every tenant's file.
- **No S95 guardian start after a hold boot** (12.2 D7-4 last bullet, B-P4): `restore_payload_guardians` already
  runs `running || start` for every generated stub at S11 on every boot (`95-batman-storage`), before firstload's
  S95 hold, so the guardian is started on the boot after a hold without any firstload change.
- **What counts as a crash** (12.2 D7-3 "What does not count"): implemented as "every restart the guardian performs
  after its start-up converge is a record" — the restart path only runs after the converge, so an exit during the
  converge is handled by the converge itself (start mode's FAILED → the converge reports it) and a container that
  exits after it is restarted and recorded. No `FinishedAt` and no wall clock are involved; revived containers of an
  older image are rebuilt by the converge before the loop starts and are never judged (L-OTA1).
- **Generated stub:** only for a tenant dir whose manifest has at least one `CONTAINER` line (fault-injection R2's
  decoy dir has a manifest without one; a stub would respawn forever).
- **Test seams (env, root callers only; procd sets none):** `PAYLOAD_LIB`, `PAYLOAD_GOLDEN_ROOT`, `PAYLOAD_RUN`,
  `PAYLOAD_UPTIME_FILE`, `PAYLOAD_POLL`, `PAYLOAD_INTERVAL` — used by `scripts/test-payload-run.sh` and
  `scripts/test-payload-guardian.sh`.
- **halow-status stale threshold** is "older than ~2 min" (`find -mmin -2`), not 90 s.
- **hold-reboot-274 and L-FIRST2 are one suite (`hold-274`)** using the real firstload (a tar `docker load`
  rejects), not a simulated hold. **unclean-boot-274 also carries L-TENANT-PLANT** (a planted tenant dir with its own
  `.init`; after `reboot -f` the stub must be the generated one and the planted init must never have run).
- **Bugs the new guardian unit test found before any node run:** the verdict variable was overwritten by the policy
  check (it would have published garbage as `status`), and the ledger reader lost the first record (awk array
  indexed by an uninitialised counter). Both fixed in b0ad503.
- **Immediate DRIFT on a down container (found by fi-c1 on 1.5.8-wsl.1).** The verdict was published only at the 30 s
  tick, and autocommit accepts a verdict up to 1 min old: a crash at +100 s of a trial was committed at +121 s on
  a still-OK verdict (ota-trace boot d482f24e: RELEASED up=104, COMMITTED up=121). The guardian now publishes DRIFT
  in the 5 s poll as soon as a manifest container is not running (the tick then recomputes the full verdict; the
  ledger keeps it DRIFT for 600 s). Remaining race: a crash in the ≤ 5 s between a poll and autocommit's third
  healthy read. Unit test 14 (no tick possible) passes; against bc56b71's guardian it FAILs (negative control).
- **Harness fixes from the same run:** crash-274 counted ledger records wrongly (`grep -c || echo 0` printed two
  lines), checked "running" right after the kill (race), and ran on hold-274's held boot (firstload latch = the
  tenant is non-gating, so the dry-run committed — ota-trace boot 8d9302f7, firstload.log 05:00:48); hold-274 now
  ends with a clean reboot and asserts no latch remains; crash-274 step 4 FAILs its precondition if a latch exists;
  unclean-boot-274 waits up to 120 s for the first verdict.
\n
- **A hung service health check holds the restart path (rc 1.5.8-wsl.2, crash-274 step 10).** The gate is bounded
  (60 tries, each ≤ 10 s, 2 s apart ≈ 12 min). While it runs, the guardian is inside `payload-run`: dependent clients
  stay down, no other crash is handled, and the verdict file is not refreshed — autocommit fails closed on the stale
  verdict and halow-status shows it stale. Measured: rabbitmq's check hung via the test seam at 07:37, cot_parser
  was started only after the gate timed out at 07:48 (cot_parser.log / StartedAt on 04). This is the designed bound;
  its availability cost is stated here and in #274's leftovers (a shorter restart-path gate is an extension idea).
  The test seam is now re-read on every try, so removing it ends a simulated hang at once (the test removed it
  after 20 s, but payload-run had read it once and kept the hang for the full bound).
- **Re-run evidence for the harness attributions (wsl.2):** fi-c1 PASS (the immediate-DRIFT fix), unclean-boot-274
  PASS (the 120 s wait), crash-274 steps 1/4/10 PASS (`--until` 2 s ahead; no latch; seam waited for),
  cleanstop-274 PASS twice — its one early-CoT loss on wsl.2 did not reproduce and stays unattributed (❓).
\n
- **CPU cost, measured (04, Pi 4, rc 1.5.8-wsl.3, 2026-10-10) — corrects the "≈ 1 %" estimate in 12.8 (that counted the
  5 s poll only).** Guardian process tree over 600 s: 140.8 s CPU = **23.6 % of one core**. Per part (3 runs each):

  | part | per run | of one core | new in v8.2? |
  |---|---|---|---|
  | verify-profile-ots.sh (30 s tick) | 4 200 ms | 14 % | no (#156) |
  | reconcile-resources.sh (30 s tick) | 1 093 ms | 3.6 % | no |
  | payload-run --cfg-hash (30 s tick) | 346 ms | 1.2 % | no |
  | label check, 6 inspects (30 s tick) | 260 ms | 0.9 % | no (rewritten) |
  | container allowlist, 6 containers (30 s tick) | 953 ms | 3.2 % | yes |
  | restart-policy check (30 s tick) | 306 ms | 1.0 % | yes |
  | foreign scan + golden cmp + live-restore (30 s tick) | ≈ 110 ms | 0.4 % | yes |
  | liveness poll, docker ps + docker info (5 s) | 93 ms | 1.9 % | yes |

  Pre-existing ≈ 20 % of a core (verify-profile alone 14 %) — never measured before; handed to #171 (OTS resource
  budget). Added by v8.2 ≈ 6.5 % of a core (≈ 1.6 % of the 4-core Pi 4). User decision 2026-10-10: accepted for this
  PR; reducing it (drop the per-poll `docker info`, run the allowlist/foreign scan less often) is a #274 leftover.
- **Second "missing" within 600 s:** measured on 04 — with only the guardian acting, a container removed 6 min after
  an earlier missing record came back after 300 s (the once-per-600 s limit on the respawn converge). Stated limit;
  #274 leftover (rare in the field: only an operator `docker rm` / prune removes a container).
- **fi-f2 in the full run (wsl.3)** failed once (OTS not 6/6 within 200 s); re-run twice (a manual repro: 6/6 at +82 s;
  the harness case after the 600 s window: PASS). Not reproduced: unattributed (❓).
- **Cosmetic, pre-existing:** remove_stack logs "removing orphan container … (no longer in the manifest)" for containers
  that are in the manifest (NAMES is newline-separated, the check matches spaces). Behaviour is right; #274 leftover.
- **OTA under CoT load (04, wsl.3, 2026-10-10):** 02 sent CoT to 04 (soak-node cotgen) while fi-s1 ran a same-build
  OTA. PASS: one start per container, two-phase order, no DRIFT, empty ledger. Stop timeline of the old boot (node
  clock): procd validation ended 14:37:28; opentakserver KeyboardInterrupt 14:37:28.46; ots-db "fast shutdown request"
  14:37:28.49 → "database system is shut down" 14:37:29.08; rabbitmq stores stopped by 14:37:29.06; S2 BEGIN 14:37:45.
  Next start: "database system was shut down at … 14:37:28" (clean, no recovery). dockerd's own shutdown stops the
  stack gracefully under load in < 1 s, as E14 measured idle.
