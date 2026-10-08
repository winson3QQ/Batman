# #274 — payload tenant converges on its config; clean stop, fast start

Status: design **v3** (2026-10-08) — v1 REJECTED (B1–B3, M1–M9), v2 REJECTED (N1–N10); §7 maps every finding
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
