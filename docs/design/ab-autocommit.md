# Design: health-gated auto-commit of an A/B trial slot (#211)

## Problem

`sysupgrade -n <ab-payload>` writes + tryboots the INACTIVE slot as a one-shot **trial**:
`autoboot.txt [all]` still points at the OLD slot. The trial slot runs, but a reboot reverts to the
old slot. That is correct auto-rollback safety for a bad image, but for a SUCCESSFUL upgrade it means
the operator must run `batman-slot commit` by hand — otherwise a power-cycle silently rolls back.
This breaks true zero-touch field reflash: a node reflashed and then power-cycled before commit reverts.

(Found delivering PR #210: after reflashing manet01/02, every cycle needed a manual `batman-slot commit`
or `ab-selftest` FAILs "autoboot [all]=1 but booted partition 2 — fallback never repaired, #133".)

## Goal

After a trial slot boots and proves the new image is FUNCTIONAL, auto-commit it (zero-touch). If it does
NOT prove healthy within a timeout, do nothing — the next reboot reverts to the old slot (keep the
rollback safety). Never commit a slot that could be bricked.

## Design

New procd one-shot service `batman-autocommit` (in `batman-provision`), `START=99` (after dockerd S99,
the payload guardian, joinwatch S98 — so payload + radio have a chance to come up). Command
`/usr/bin/batman-autocommit run`:

1. **Trial detection (no-op on a normal committed boot).** Use a new `batman-slot is-trial`
   subcommand (review m4 — the authoritative autoboot parser lives in batman-slot, not re-implemented
   here): it returns 0 (trial) when `[all] != fw_part(active)`, 1 (committed) otherwise. On committed →
   log "already committed" → exit 0. This also means a #133 stale-fallback boot ([all] disagrees with
   the booted slot) is treated as a trial and gets committed to the actually-booted slot — a benign
   repair that satisfies the ab-selftest #133 assertion.

2. **Health gate — "the NEW rootfs booted a functional userland", NOT peer/key-dependent, NOT fooled by
   shared-p6 docker state** (review B1/M1/M2). Poll every 10 s up to `TIMEOUT` (default 600 s), and
   require **N=3 consecutive healthy polls** (a ~30 s dwell) before committing so we don't catch a
   transient "all up" during the guardian's rebuild window (review M2). Healthy iff:
   - **core services (the real proof the new rootfs works):** `halow-status json` has **no CRIT in the
     `svc` category** (mesh11sd / openmanetd / wpad running — `halow-status:84`) and **no CRIT in
     `power`** (undervoltage). We reuse halow-status's own roll-up and **tolerate `mesh` CRIT**
     (`halow-status:65/66/69` = keyguard-blocked / key-not-set / not-joined) and battery/thermal — those
     are key/peer/environment states, not image defects; gating on them would make a healthy lone or
     not-yet-keyed node never commit (review M1). Container liveness is NOT used as the primary signal:
     `unless-stopped` containers on the shared p6 docker-root come up under ANY rootfs, so "containers
     Running" does not prove the NEW rootfs is good (review B1).
   - **payload (if provisioned):** for the OTS tenant, `/tmp/batman-payload-opentakserver-drift.json`
     exists with `"status":"OK"`. `/tmp` is tmpfs (wiped each boot), so its presence means the guardian
     **on this boot's rootfs** completed a full bring-up and verify (`payload-guardian.sh` writes OK only
     after PRIMARY is up and verify-profile passes) — this is the "this boot" + "guardian finished"
     requirement of review M2, and unlike raw container liveness it reflects the NEW rootfs's guardian.
   - defense-in-depth: `/etc/batman-build` is present + non-empty (the trial rootfs stamp is readable).
   Trial detection already proves we run the NEW slot's squashfs (per-slot cmdline `batman_slot=$T`,
   `batman-slot:169`), so "am I the new rootfs" is settled; the gate adds "…and it works".

3. **Commit on health:** `batman-slot commit`; log `autocommit: slot $A committed (healthy)`; exit 0.

4. **Timeout without health:** do NOT commit; log `autocommit: slot $A NOT healthy after ${TIMEOUT}s —
   left as trial (will revert on reboot)`; exit 0. This is the rollback path (a genuinely bad image
   never gets committed).

Idempotent: on any committed boot step 1 exits immediately; the commit itself is idempotent
(`write_autoboot` is atomic). One-shot (no `procd_set_param respawn`) so it runs once per boot.

daily-validation: extend a check (or the ab-selftest inspect that already asserts `[all]` == booted
partition) so a freshly-reflashed-then-rebooted node is asserted COMMITTED. Add `autocommit-211`:
reflash is out of scope for the daily tier, but assert on any node that `[all] == fw_part(active)`
(i.e. no node is left in an uncommitted trial) — cheap, catches a stuck trial.

## Alternatives considered

1. **Commit inside `sysupgrade`/`platform-ab.sh` right after writing the slot.** Wrong: that commits
   BEFORE the trial boots, defeating rollback — a bad image would be committed and brick the node.
   Commit must be gated on a successful *boot* of the new slot. Rejected.
2. **Gate on mesh JOINED.** Peer-dependent: a healthy lone node (peer off) never joins → never commits.
   Rejected in favour of "radio interface present".
3. **Operator commits manually (status quo).** Not zero-touch; a power-cut before commit reverts. This
   is what #211 exists to remove.
4. **uci-defaults one-shot instead of a service.** uci-defaults run early (before dockerd/radio), so a
   payload/radio health gate can't be evaluated there. A late procd service is the right place.

## Failure modes

- **Bad image (won't boot / rootfs broken):** never reaches the service → never commits → firmware
  reverts on reboot. ✓ (rollback preserved.)
- **Image boots but OTS never healthy:** timeout → no commit → reverts. ✓ (Risk: a good image whose
  OTS is merely slow >600 s wrongly reverts. Mitigated by a generous 600 s — OTS reaches 6/6 in ~45 s
  in practice — and by the guardian which keeps trying; the operator can still commit manually.)
- **Lone node, peer off:** radio-present gate passes without join → commits a healthy lone node. ✓
- **Committed boot (normal reboot):** step 1 no-op. ✓
- **Commit races the guardian / other autoboot writers:** `batman-slot` writes autoboot atomically
  (tmp+rename) and is the single audited writer; autocommit calls it, doesn't touch autoboot directly.
- **Service crashes mid-poll:** one-shot, won't respawn; node stays trial (reverts on reboot) — safe
  default, operator can commit. Acceptable.

## Known limitations / behaviours (review R2)

- **Unkeyed / keyguard-disabled node does not auto-commit.** The gate requires the core mesh daemons
  (mesh11sd/openmanetd/wpad) up; on a node whose key is still the placeholder, keyguard disables the
  radio and those daemons don't run, so the gate never passes → no auto-commit. This is SAFE (never a
  wrong commit) but means a not-yet-keyed node stays a trial until keyed (or committed by hand). Our
  fleet is keyed, so unaffected. A future public-golden / boot-then-key flow would want PHY/driver-layer
  radio detection instead.
- **`running` uses procd's `/etc/init.d/<svc> running`, not `pgrep`.** pgrep -f substring-matches a
  stray process and could false-positive this commit safety gate; pgrep -x / pidof MISS all three
  daemons (mesh11sd runs as `sh …`, wpad as a ujail'd hostapd). procd's own state is authoritative.
- **Fallback repair.** On a #133 stale-fallback boot ([all] disagrees with the booted slot) is-trial is
  true, so once healthy the node commits the actually-booted slot — repointing `[all]` at reality
  (which also demotes a previously-committed default that could no longer boot). Benign self-heal;
  documented so it isn't surprising.

## Review outcome (R1 design + R2 implementation)

R1 (design): SOUND-WITH-CHANGES — B1 (health gate must reflect the new rootfs, not shared-p6 container
liveness), M1 (don't gate on mesh-joined/wlh0), M2 (dwell + guardian this-boot verdict). All folded in.
R2 (implementation): SOUND-WITH-CHANGES, no BLOCKER/MAJOR — must-fix m1 (use procd `running`, not
pgrep -f) applied; should-fix m2 (drift verdict freshness ≤1 min) applied; limitations documented above.

## Verdict (author)

Sound: commit is gated on a *booted, functional* new image (not peer-dependent), preserves rollback
for a bad image, and is a no-op on a normal boot. Needs independent adversarial review before build.

## v2.1 (#209 v4.3 D9.2 / A5): mesh-join gate + guaranteed revert of an unhealthy trial

### Problem (found in #209 review, confirmed on hardware)

1. **A slot that breaks the mesh but keeps the services up is committed, and a mesh-only node is
   stranded.** v1 only asks "are mesh11sd/openmanetd/wpad running" (R1-M1 deliberately tolerates
   not-joined so a lone node commits). A rootfs whose radio is broken underneath running services — the
   1.4.12 brcmfmac drop that moved morse to radio0, a morse driver that never forms a plink, a broken
   bridge/IP/dropbear — passes and is committed.
2. **"Left as trial (reverts on reboot)" needs something to reboot the node, and nothing does.** The
   watchdog (proven on a Pi 3A+, #209 E0g ⑧) only catches hangs, not a live node without a network.
3. **`batman-slot apply` accepts a running trial** (#209 v3.1 MUST-FIX 1, never implemented): on a
   trial of B, `target` = A = the *committed* slot, so a second OTA run on a trial overwrites the only
   known-good slot.

### Change

**A. When may autocommit reboot?** Only on a *real tryboot* of *this* boot: `is-trial` = 0 **and** DT
`/proc/device-tree/chosen/bootloader/tryboot` = 1 (faithful on Pi 3 and Pi 4, #209 E0/E0g). A #133
stale-fallback boot (`[all]` ≠ booted slot, tryboot = 0) is never rebooted — that would loop, because
the firmware lands on the same slot again (review M1). `is-trial` = 2 (unknown) → never reboot.

**B. The revert is guaranteed by a deadline, not by the poll loop** (review M2). busybox has no
`timeout`, so a detached watchdog subshell is started first: it sleeps until the uptime deadline and
reboots unless the main loop has committed (it removes the watchdog's flag file). A wedged `docker info`
or init script therefore cannot stop the revert. The deadline is uptime-based (not "polls × 10 s").

**C. Before rebooting** (all bounded, then reboot regardless):
- skip if `/tmp/batman-slot.busy` exists (held by `batman-slot apply`/`stage-root`) — re-check every
  10 s, at most +10 min (review M5);
- defer while a `/tmp/batman-firstload-*.latch` tenant still has a `docker load` running, at most +10 min
  (review S4: p6's docker store is shared with the committed slot);
- consume a **persistent one-shot hold** `/opt/batdata/state/autocommit-hold-once` if present (review
  M6): the trial is left uncommitted, no reboot, and the file is deleted so only one OTA is affected.
  An operator or OTA orchestrator creates it *before* the OTA (e.g. a planned mesh-breaking change).
  `/tmp/batman-autocommit.hold` still works for a person already on the trial;
- append `TRIAL-REVERTED boot=<id> slot=<S> version=<batman-build> reason=<last> waited=<s>` to
  `/opt/batdata/log/autocommit.log`, write `/tmp/shutdown.reason` (`autocommit: trial reverted`) so
  boot-reasons records a clean reason (review S5), sync, `reboot` (procd clean shutdown).

**D. Health gate additions** (on top of v1, all only on a trial):
- **p6 must be mounted** (review M3b) — otherwise the payload/docker checks silently skip themselves.
- **Mesh-join requirement** if the node is *expected to be in a mesh*: p5 `.seeded` exists (save-on-join
  or factory seed; the #202 interlock means every node that can be OTA'd has it) **or** the new marker
  `/opt/batdata/state/mesh-joined` exists (written once by joinwatch on its first JOINED). This covers
  the first v2 OTA across today's fleet (review M3a). A bench node that was never seeded and never
  joined keeps the v1 behaviour (R1-M1).
- **Joined is computed by autocommit itself** (review M4), from the same definition joinwatch uses,
  moved into a shared `/usr/lib/batman/meshjoin.sh`: ≥1 ESTAB plink on wlh0 **and** ≥1 batman neighbour
  **on wlh0** (review S1; on the nodes `batctl if` lists only wlh0). Plus `br-ahwlan` has an IPv4
  address and dropbear is running (a reachable node, not just L2). No dependency on joinwatch running.
- **Latched, not dwelled** (review S2): "joined at least once in this trial boot" latches; the 3-poll
  dwell stays on the service/docker checks only, so a flapping edge link does not reset it forever.
- docker canary `docker run` passes once per boot and is then cached (review S3, 512 MB Pi 3A+).

**E. Timeout per SoC** (review S3): uci `batman.autocommit.timeout`, default bcm2711 600 s, bcm2710
900 s, measured from boot (uptime) — to be calibrated in #209 S5 (boot→JOINED and boot→healthy on a
Pi 3A+ with docker + first-load) and set to ≥3× the worst measured case.

**F. Commit failure is retried** until the deadline (review S8; e.g. `batman-slot commit` deferring on
under-voltage) instead of exiting.

**G. `batman-slot apply`/`stage-root` refuse while the running slot is a trial** (`is-trial` = 0), and
hold `/tmp/batman-slot.busy` while running. Override `BATMAN_ALLOW_TRIAL_APPLY=1` for the bench.

### Alternatives considered

- *Always require joined* — breaks the never-provisioned bench node; `.seeded` OR marker is the line.
- *Peers seen in the last N hours* — no trustworthy clock (no RTC).
- *L3 ping of a neighbour* — considered (review S1); deferred: neighbours' addresses are not stable at
  trial boot (bootstrap addressing), and plink + batman-on-wlh0 + own IP + dropbear covers the observed
  failure classes. Revisit if a field case escapes.
- *Rely on joinwatch's state file* — rejected (review M4): joinwatch can be disabled by uci or exhaust
  procd respawns, which would silently turn every OTA into a revert.

### Failure modes

| Situation | v1 | v2.1 |
|---|---|---|
| Trial, broken radio/bridge, services up, node seeded or joined before | **committed → stranded** | not joined → watchdog reverts at the deadline (`TRIAL-REVERTED`) |
| Trial never healthy, any reason, incl. a wedged check | left trial, unreachable | watchdog reverts at the deadline |
| #133 stale-fallback boot (tryboot = 0) | commits when healthy | commits when healthy; **never reboots** (no loop) |
| Never-seeded, never-joined bench node | commits on services | unchanged |
| First v2 OTA on today's fleet (no marker yet) | — | `.seeded` already requires the join |
| p6 not mounted on the trial | commits with checks skipped | unhealthy → revert |
| joinwatch disabled / crashed | — | no effect (autocommit computes joined itself) |
| Second OTA started on a trial | overwrites the committed slot | `apply` refuses; a running apply also blocks the revert-reboot (bounded) |
| Fleet OTA, neighbours rebooting together | commits | neighbours return in ~1 min; if all stay down past the deadline the node reverts and the OTA is retried later (fail-safe). Stagger fleet OTAs. |
| Planned mesh-breaking OTA (protocol/firmware incompatible with the old fleet) | commits | set `autocommit-hold-once` before the OTA, commit by hand |
| Lone node deliberately re-sited out of any mesh | commits | reverts every OTA until the operator sets the hold or commits by hand; `TRIAL-REVERTED` makes it visible |
| Good but slow trial | commits | per-SoC timeout, calibrated in S5 |

### Test plan

On hardware (manet03 Pi 3A+, manet02 Pi 4) with `AUTOCOMMIT_DRYRUN=1` (evaluate, print
`commit`/`revert` + reason, never act) and a short timeout:
(a) seeded + joined → commit; (b) seeded + radio down → revert, reason "not joined";
(c) never seeded/joined + radio down → commit; (d) DT tryboot = 0 with `is-trial` = 0 → no reboot;
(e) a check that hangs (stub a `docker` that sleeps) → watchdog fires at the deadline;
(f) p6 unmounted → revert; (g) `/tmp/batman-slot.busy` present → revert postponed;
(h) `autocommit-hold-once` → no revert, file consumed; (i) `batman-slot apply` on a trial → refused.
End-to-end in #209 S5: a real OTA whose payload breaks the mesh → `TRIAL-REVERTED`, node back on the
old slot with no site visit; and a normal OTA → committed within the per-SoC timeout.

### Review

- **v2 (2026-10-02, independent reviewer): NEEDS-REWORK.** M1 revert loop on a stale-fallback boot →
  A; M2 a hung check defeats the revert → B; M3 fail-open on the first v2 OTA / p6 unmounted → D;
  M4 dependency on joinwatch's file → D; M5 reboot during an apply / apply on a trial → C, G; M6 escape
  hatch unusable before the OTA → C. SHOULD-FIX S1 → D (wlh0, IP, dropbear; L3 ping deferred with
  reason), S2 → D (latch), S3 → D/E, S4 → C, S5 → C, S8 → F, S9 → test plan; S6 (permanent marker on a
  re-sited lone node) → hold file + visibility, no auto-commit after K reverts (judgement: safety
  first); S7 documented in the failure table.
- **v2.1 (second round, same reviewer): APPROVE-WITH-CHANGES.** v2.2 decisions (implemented):
  - **N1 commit ↔ watchdog race** → both sides must win one atomic claim (`mkdir /tmp/autocommit.decided`)
    before acting. The main loop claims only right before `batman-slot commit` and releases the claim if
    the commit fails (so it retries next poll). The watchdog, on losing the claim, waits up to 120 s for
    `/tmp/autocommit.committed`; immediately before rebooting it re-checks `is-trial`=0 **and** DT
    tryboot=1. A Pi 3 p7 sector write is therefore never interrupted by our own reboot.
  - **N2 deadline** → `deadline = max(timeout, start_uptime + 300)` in uptime seconds. Timeout source:
    `/opt/batdata/state/autocommit.timeout` (p6, survives OTA, operator override) else the image default
    per SoC (bcm2711 600 s, bcm2710 900 s); non-numeric → default; clamped to [300, 3600].
  - **N3 hold-once** → consumed (deleted, `HOLD-CONSUMED` logged) at the START of every real tryboot,
    whatever the outcome.
  - **N4 lifecycle** → the watchdog is started with `setsid` (outside procd's instance), guarded by
    `mkdir /tmp/autocommit.wd`, so a `restart` cannot create a second one. `service batman-autocommit stop`
    does NOT cancel the revert; the hold files do.
  - **N5 `.seeded` fail-closed** → `batman-config-save` (`--seed`/`--on-join`) also writes the p6 marker
    `/opt/batdata/state/mesh-expected` when p6 is mounted, so autocommit normally never touches p5. If it
    must look at p5: p5 present but not readable as plain ext4 (LUKS, mount failure, or currently
    mounted rw by a save) → **expected in a mesh**. p5 is mounted read-only only.
  - **N6** → the trial refusal is also in `platform_check_image` (stage 1, before services are killed);
    `/tmp/batman-slot.busy` is removed in batman-slot's single EXIT trap.
  - **N7** → `apply`/`stage-root` refuse only on a **real tryboot** (DT tryboot=1 and `is-trial`=0); a
    #133 stale-fallback boot may still be re-OTA'd (the natural remote repair).
  - **N8** → commit needs ≥3 joined samples in the trial **and** joined within the last 60 s.
  - **N9** → a seeded node that legitimately never has a HaLow peer (e.g. an Ethernet-only standalone)
    reverts every OTA; decision: do not accept "Ethernet carrier" as reachability (a cable to nothing is
    not reachability). Such nodes use the hold files; `TRIAL-REVERTED` is surfaced in `halow-status`.
  - **N10** → daily-validation gets a check that the shared join test passes on a committed, joined node,
    so a renamed interface/daemon is caught before it disables OTAs.
  - **N11** → tests added to the plan above: commit/watchdog race (slow commit stub), deadline already
    past, garbage timeout, hold-once + healthy trial, unreadable p5, double `restart`.

