# #192 — Payload guardian survives an A/B flash

## Problem
The OTS payload guardian init (`batman-ots`, the #156 reconcile owner) lives on the persistent
data partition at `/opt/batdata/deploy/ots/batman-ots.init`, **not** baked into the generic
`feed/batman-provision` image. An A/B `sysupgrade` writes the inactive slot with a fresh squashfs
and a **cleared overlay**, so `/etc/init.d/batman-ots` is gone after every flash. Until this change
it had to be reinstalled from p6 by hand — observed live upgrading manet01 to 1.4.0-wsl.1: each slot
booted with no guardian, OTS only partially came up via docker restart-policy, and the #156 drift
verdict was not published until the guardian was manually `cp`'d from p6 and enabled.

Deliberately keeping the ~4 GB container images + deploy config on p6 (not in a flashable rootfs) is
correct — the gap is only the tiny guardian **init** + its activation, which should self-restore.

## Options considered
1. **Bake `batman-ots.init` into `feed/batman-provision`.** Rejected: it is OTS-specific; baking a
   payload guardian into the *generic* image breaks the platform/payload split (#68), and the deploy
   config still lives on p6 anyway.
2. **One-shot firstboot `uci-default` (`95x-…`) that restores from p6.** Rejected in review (#192):
   a `uci-default` is deleted on `exit 0`, so if `95-batman-storage` transiently fails to mount p6
   this boot, the restore hook no-ops **and deletes itself** → the slot is left permanently without a
   guardian until the next reflash (silent no-guardian). Same trap for "payload deployed / card
   repaired after firstboot."
3. **Fold the restore into the `batdata-mount` init (chosen).** `batdata-mount` is installed by
   `95-batman-storage`, is itself self-restoring on a fresh slot (95 re-runs on firstboot), and runs
   **every boot at START=11 right after it mounts p6**. Restoring there is idempotent, self-heals a
   boot where the mount was not ready (retries next boot), and the mount→restore dependency is
   naturally ordered. Adversarial review verdict: **SOUND** with this move.

## Design (chosen)
In `batdata-mount`'s `boot()`, after the p6 mount succeeds and the once-per-boot marker is set, call
`restore_payload_guardians()`:
- iterate `"$MOUNT"/deploy/*/*.init` (generic: any payload's guardian, feeds #68);
- **safety guard**: only `[ -O "$src" ]` (root-owned) inits are boot-exec'd — see boundary below;
- idempotent: `cmp -s` first, only `cp` + `chmod +x` when missing/changed (no per-boot churn);
- `enable` (creates the S99 rc link so a normal boot's ordered start pass brings it up);
- start-safety: `"$dst" running || "$dst" start` — on the **first** boot, 95 calls `boot()` from a
  uci-default *after* the S99 start pass, so an explicit start is needed; idempotent on normal boots.
- per-step return-code handling; failures are logged (`note`) with a distinct message, not counted as
  success. Because this runs every boot, a failed boot simply retries next boot (no self-deletion).

## Security boundary (p6 → root boot-exec)
This installs and starts an init from p6 **as root, before the network/policy is fully up**. It does
not create a materially new trust boundary: an attacker who can write p6 already controls the docker
images and `run.sh`/compose that the node executes as root. But it widens *what* auto-runs and *when*,
and physical capture is in the threat model (#137/#111/#115). Mitigation for v1.1: restrict to
root-owned inits under the known `deploy/*/*.init` layout. Stronger guarantees (verified boot / signed
payload manifest) are #74 / #97; this file records the boundary as accepted for the v1.1 no-rebuild tier.

## Relation
- Feeds **#162④** (fold deploy into the app-agnostic runtime owner) and **#68** (payload framework);
  the full own-image / payload-runtime-owner answer is v2.0. This is the v1.1 no-rebuild stopgap so
  the fleet survives A/B upgrades unattended.

## Definition of Done
After an A/B `sysupgrade` on an OTS node, once the tryboot slot is up, `/etc/init.d/batman-ots` is
present + enabled + running and `/tmp/batman-ots-drift.json` is published, with zero manual steps —
bench-verified on manet01.

## Test / verification status
- Logic + POSIX-sh syntax validated (outer script + extracted `batdata-mount` init both `sh -n` clean);
  busybox `-O` test, procd `running` action, and `cmp` confirmed available on-node (manet01, 1.4.0).
- **Pending (needs a flashed image):** bake into an image, A/B flash a node, confirm the guardian +
  drift verdict return with no manual step across the tryboot. Deferred to the next image build/flash.
