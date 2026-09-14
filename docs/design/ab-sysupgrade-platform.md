# Design v2: A/B `sysupgrade` via a `batman-slot` helper (#89)

Status: REVISED after adversarial review (2026-09-13). v1 verdict was APPROVE-WITH-CHANGES; this
version resolves the 3 must-fix items + secondaries and adopts the reviewer's `batman-slot` helper
architecture. Ground-truth citations kept from v1.

## Why (unchanged)

The GPT A/B card ships the **stock** bcm27xx `/lib/upgrade/platform.sh`; its `export_bootdevice`
FAILS on our layout (`Unable to determine upgrade device`), and it is single-slot/whole-disk. So an
OS update is a hand-rolled `dd` — and this session's entire "Build #2 slot-B failed" saga was a
hand-rolled `dd` that skipped clearing the inactive slot's f2fs overlay (stale superblock at
`round_up(squashfs,64KiB)` → `mount_root` tmpfs fallback → degraded boot → p5/p6 mount fail,
unreachable). `sysupgrade` on a real platform.sh clears the overlay for us. This makes `sysupgrade`
the mechanism.

## Architecture decision (from review §5): one audited helper, thin platform.sh

All slot-critical logic lives in **`/usr/sbin/batman-slot`** (baked by the feed), shared with
`ab-selftest.sh` and unit-tested by `tests/ab-card-invariants.sh`. `platform.sh` is a thin adapter
that calls it. This keeps the firmware-index derivation and the p1 atomic-rename in ONE place, not
spread across four overridden OpenWrt functions.

```
batman-slot active                 # echo A|B  (from /proc/cmdline batman_slot=)
batman-slot target                 # echo the inactive slot letter
batman-slot fw-part A|B            # firmware FAT boot index, derived ON-NODE (no sgdisk/blkid)
batman-slot apply <payload-dir>    # clear+write inactive ROOT overlay+squashfs, write inactive BOOT
                                   #   payload, set inactive cmdline.txt, arm one-shot tryboot. NEVER
                                   #   touches the running slot or [all] in autoboot.txt.
batman-slot commit                 # atomic autoboot.txt [all]<->[tryboot] swap to the trial slot
batman-slot rollback               # atomic swap back (operator escape)
```

## Must-fix resolutions

### MF1 — atomic autoboot.txt, and boot-payload write never touches it (the only brick path)
`autoboot.txt` is the single file the firmware reads to choose a slot for **both** slots, and it lives
only on bootA/p1 (`build-gpt-ab-card.sh:125,148-149`; invariant `ab-card-invariants.sh:60-61`). When
the running slot is B, `target=A`, so `apply` writes p1's boot payload AND (for `commit`) edits p1's
`autoboot.txt`. Rules that make this brick-proof:
- **`autoboot.txt` is NEVER edited in place.** Every change: write `/boot/.autoboot.$$`, `sync`,
  `rename()` over `autoboot.txt`, `sync`. `rename` within one FAT dir is the closest to atomic FAT
  offers; the corrupt window is one metadata flush, not a truncate-in-place.
- **`apply`'s boot-payload write to p1 excludes `autoboot.txt` entirely.** It copies ONLY
  kernel8.img + dtbs + overlays/ + the firmware blobs (start4*.elf, fixup4*.dat) into the target
  boot FAT, and writes that FAT's own `cmdline.txt`. `autoboot.txt` is only ever written by
  `commit`/`rollback`, never by `apply`. So a power loss during `apply` cannot damage `autoboot.txt`.
- **Recovery anchor:** keep a known-good copy at `/boot/ab.good` (already present on the card).
  `commit` refreshes it *after* a successful atomic swap, so a corrupt `autoboot.txt` can be restored
  from `ab.good` by preinit/a repair hook. (Repair hook is a follow-up; the anchor is maintained now.)

### MF2 — dedicated A/B image target; resolve REQUIRE_IMAGE_METADATA vs files-only
Do NOT parse the stock DOS/MBR whole-disk `.img` in busybox. The firmware build (fork) adds a
**dedicated A/B image target** whose artifact is a small tarball/dir `payload/` = `{root.squashfs,
boot/{kernel8.img,*.dtb,overlays/…,start4*.elf,fixup4*.dat}, metadata}`. Benefits: no MBR-parse, no
FAT-filtering, correct sysupgrade metadata by construction (fixes Q4). `platform_check_image`
validates the metadata trailer + board tag against this target. Interim (until the build target
lands): `batman-slot apply` accepts a `payload-dir` produced by a documented extraction step, so the
helper + tests can be built and validated before the image-build change. **`apply` never imports the
stock boot FAT's `cmdline.txt`/`config.txt`** (they hard-code `root=/dev/mmcblk0p2`, single-slot);
it writes the per-slot `cmdline.txt` itself and keeps the card's existing `config.txt`.

### MF3 — always write the matching kernel; on-node fw-part derivation
- **Kernel is written every upgrade.** Kernel modules live in the new squashfs
  (`/lib/modules/<vermagic>`); a retained mismatched kernel silently fails module load (batman-adv,
  mac80211, mm6108 SPI) → "healthy on the wire, dead on the mesh", the class this project fears
  (`build-gpt-ab-card.sh:134-135`). `apply` always writes kernel+dtbs+overlays matching the rootfs.
  (v1's Q3 "kernel-unchanged is fine because slot B booted on the old p3 kernel" is deleted — it
  worked only because Build #2 did not change the kernel; not a guarantee to design on.)
- **`fw_boot_partition` re-expressed for the node.** The build-host version uses `sgdisk`+`blkid`
  (`build-gpt-ab-card.sh:138-139`), absent on the busybox rootfs (cf. `95-batman-storage:42`,
  `96-...:70` use `hexdump` "blkid/od absent"). On-node derivation, matching `ab-selftest.sh:90,99`:
  read the FAT ordering from the GPT via `hexdump` of the partition entries (or enumerate
  `/sys/class/block/mmcblk0p*` + ext4/f2fs vs FAT via the fs-magic hexdump already used in 95/96),
  count FAT partitions up to the target GPT index. Cross-check against the live
  `/proc/device-tree/chosen/bootloader/partition` for the *current* slot as a sanity assert.

## Secondary fixes (from review §2/§4)
- **`sysupgrade -n` pinned.** `platform_copy_config`/`platform_restore_backup` are no-ops (config
  crosses slots via p5 + `96-batman-config-migrate`); `-n` prevents the harness building
  `/tmp/sysupgrade.tgz` and giving a false "config captured" impression. Documented in the runbook.
- **Clean-shutdown marker before `reboot -f`.** `apply` writes `/tmp/shutdown.reason=
  "sysupgrade-trial (slot <target>)"` so `batdata-mount stop()` / boot-reasons don't log a spurious
  UNCLEAN on the trial slot's first boot (`95-batman-storage:178-193,202-217`).
- **First-boot overlay race** is the intended path and is safe *iff* the clear reformats: `apply`
  uses `ZERO_MB=SQ_MB+64` verbatim (`build-gpt-ab-card.sh:89-99`), the exact fix for `96-...:78-88`.
- **Tests.** Extend `ab-card-invariants.sh` with an *upgrade-over-stale-overlay* case: seed the
  inactive slot with a stale f2fs superblock, run `batman-slot apply`, assert (a) the superblock is
  gone/fresh, (b) the squashfs is exact-bytes, (c) `autoboot.txt` `[all]` is unchanged (apply must
  not commit), (d) tryboot flag armed. Mutation-test as the existing invariants are.

### Commit policy (review §4 + operator decision: auto-commit, but gated)
`commit` is **automatic on a soaked-healthy trial**, not manual, and **decoupled from lkg rotation**:
- A trial slot is committed only after joinwatch reports `OK` AND the slot has survived a soak gate:
  `commit_soak_boots` (default 2) reboots healthy OR `commit_soak_uptime` (default 900s) continuously
  healthy — whichever the operator sets. One health gate, evaluated by joinwatch (it already owns
  health verdicts + boot-count ledger, `joinwatch:` #127).
- **`batman-config-save --if-healthy` (p5 lkg rotation) must NOT fire on the same first-OK that a
  naive auto-commit would.** Today both hang off one OK verdict (`batman-config-save:49-53,87`).
  Fix: hold `lkg` rotation until *after* the commit soak passes, so a subtly-broken trial that is
  rolled back before commit does not overwrite p5's last-known-good with the new image's delta.
- Manual `batman-slot commit` / `rollback` stay as operator overrides.
- **Limbo window documented:** between trial boot and commit, any power-cycle reverts to the old slot
  and discards runtime state on the trial overlay — intended A/B semantics; the runbook says so.

## Failure modes (net, after fixes)
1. Wrong-slot write → guard: refuse if target root == current `root=` device, assert batman_slot A/B.
2. Overlay not cleared → `ZERO_MB=SQ_MB+64`, unit-tested over a stale superblock (MF2/tests).
3. squashfs too big / overshoot → exact-bytes write + `platform_check_image` size check.
4. Trial slot hangs pre-userspace → one-shot tryboot + `rootwait=20 panic=10` auto-return (proven
   #133). Userspace hang after root mount → hardware watchdog only (noted, unsolved).
5. `autoboot.txt` brick → MF1 (atomic rename, apply never touches it, ab.good anchor).
6. Mismatched kernel → MF3 (always write matching kernel).
7. fw-part mis-derivation → MF3 on-node derivation + device-tree cross-check.
8. Config double-handling → `-n` + no-op copy_config.
9. lkg clobber on a to-be-rolled-back trial → decoupled lkg rotation (commit policy).
10. EEPROM on an A/B boot partition → never; `apply` writes only kernel/dtb/overlay/firmware blobs.

## Rollout / validation order
1. `batman-slot` helper + on-node fw-part + atomic commit/rollback → unit test via
   `ab-card-invariants.sh` (loop device, no hardware).
2. Thin `platform.sh` overrides calling the helper; pin `sysupgrade -n` in the runbook.
3. Dedicated A/B image target in the fork build → produces `payload/` + metadata.
4. Bench: `sysupgrade -n <image>` from slot B writes slot A trial → boots A fresh → p5 restore →
   mesh → soak → auto-commit. Fallback drills (corrupt trial root; power-cut mid-apply) per #133.
5. Wire into #89; keep hand-rolled `dd` only as a documented recovery-of-last-resort.

## Verdict
Resolved all 3 must-fix + secondaries; adopted the helper architecture. Remaining genuinely-open item
is the dedicated-image-target build change (MF2 step 3), which is isolated behind the `payload-dir`
interface so the helper + tests land and validate first. Ready to implement the helper + platform.sh;
image-target + on-hardware soak follow.
