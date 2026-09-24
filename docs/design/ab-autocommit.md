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
