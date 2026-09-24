# Design: first-boot grow-to-fill for a pre-made data partition (#201)

Status: DRAFT (for adversarial review)
Parent: #88 (storage) · caused by #89 (A/B OTA never touches partitions) · relates #106/#133/#159
SoT: #75

## Problem (recap)

`feed/batman-provision/files/etc/uci-defaults/95-batman-storage` grows the data area to
fill the card **only in the "partition does not exist yet" branch** (`[ ! -b "$PART" ]`,
`parted mkpart ... 100%`).

- **Golden / interim MBR `.img`**: data partition (p3) is stripped at image-capture, so first
  boot *creates* it → expand-to-fill → full card. ✅ (this is why single-slot works)
- **v2 A/B `.img`** (`ab-fleet.img.gz`): p6 (data) is **pre-made and small** (200 MiB in the
  distributable). First boot sees it already exists → **mounts, never grows** → p6 locked at
  200 MiB on any size card. ❌ = #201.

Because a deployed node only ever receives A/B OTA payloads (`sysupgrade -n` → `batman-slot
apply` writes the *inactive rootfs slot only*, never p5/p6/the partition table), **the size p6
has at first boot is its size forever** — a one-way door. Must be fixed before any A/B `.img`
is used to provision production units.

## Goal

At first boot, if the data partition exists but does **not** reach the end of the disk, grow
the partition *and* its filesystem to fill the card. Idempotent, grow-only, fail-open,
tier-aware (plain ext4 civilian; LUKS tactical). Correct after an A/B slot flip.

## Scope / non-goals

- In scope: the pre-made **GPT last partition** (p6 data). This is the #201 case.
- Out of scope: the MBR interim p3 path — it is *created* at 100% every time, so it is already
  full; the grow step is a no-op there and we do **not** add an MBR-resize code path (untested,
  higher risk, no need).
- Out of scope: shrinking (never), moving a non-last partition (never), re-imaging.

## Design

New **step 1b** in `95-batman-storage`, run *after* step 1 (create-if-absent) and *before*
LUKS open / mkfs / mount. Plain-ext4 filesystem grow runs *after* the fs is confirmed
(extends step 3); LUKS mapper resize is tier-gated.

### Preconditions / interlocks (refuse = log + skip, fail-open)

1. `DISK=/dev/mmcblk0` and `PART` block device exists.
2. Partition table is **GPT** (`sgdisk -p "$DISK"` succeeds). MBR → skip (p3 already full).
3. `PART` is the **last** partition: no partition has a higher number *and* no partition
   starts at a sector ≥ `PART` end. (Growing a non-last partition would overwrite its
   neighbour — the single most dangerous failure; assert hard.)
4. Free tail exists: `last_usable_sector - part_end_sector > THRESHOLD` (THRESHOLD = 16 MiB
   worth of sectors = 32768). Below threshold → already-full → no-op (idempotent).

### Partition-table grow (offline, table-only — never touches fs bytes)

1. `sgdisk -e "$DISK"` — relocate the GPT **backup header** to the true end of the (larger)
   disk. A dd'd small image leaves the backup header at the old (small) end; every GPT tool
   then reports the old disk size and a resize refuses or mis-sizes. Must run first.
2. Read p6's current **start sector**, **GUID**, **type**, **name** (`sgdisk -i 6`).
3. `sgdisk -d 6` then `sgdisk -n 6:<start>:0 -t 6:8300 -c 6:data -u 6:<same GUID> "$DISK"`
   — delete and recreate the last partition with the **identical start sector** and the same
   GUID/type/name, new end = `0` (= disk end). Recreating the table entry does **not** move or
   alter the filesystem that already sits at `<start>`; only the entry's end grows. (Chosen over
   `parted resizepart` — parted's GPT resizepart is interactive/older-version-fragile; the
   delete+recreate-same-start is deterministic and version-independent.)
4. `partprobe "$DISK"` (+ `sync; sleep 1`). If the kernel still shows the old size (device
   busy), `exit 1` so OpenWrt re-runs the uci-default next boot (same retry idiom step 1 uses).
   At first boot p6 is not yet mounted, so this should not happen; the retry is a belt.

### Filesystem grow (after the table is grown)

- **Plain ext4** (civilian): after step 3 confirms `has_fs "$DEV"`, run `resize2fs "$DEV"`
  on the **unmounted** partition (grows to the new partition size; no argument = fill).
  `e2fsck -pf "$DEV"` first (clean pre-made fs; -p auto-fixes, -f forces) so resize2fs never
  refuses on "fs not clean".
- **LUKS** (tactical, `LUKS=1`): after `cryptsetup open`, `cryptsetup resize "$MAPPER"` to
  take the enlarged partition, then `e2fsck -pf` + `resize2fs "/dev/mapper/$MAPPER"`.
  (#111 owns full LUKS-mapper lifecycle; here we only resize an already-opened mapper.)

### Ordering in the script

```
step 1   create-if-absent (unchanged)
step 1b  GPT last-partition grow-to-fill (table only)   <-- NEW, before LUKS
step 2   LUKS open (unchanged)
step 2b  if LUKS and grew: cryptsetup resize $MAPPER    <-- NEW
step 3   ext4 keep/mkfs (unchanged)
step 3b  if grew: e2fsck -pf + resize2fs $DEV           <-- NEW, fs unmounted
step 4   install batdata-mount init (unchanged)
step 5   boot() -> mount (unchanged)
```

A `GREW=1` flag set in 1b gates 2b/3b so we never resize a fs we did not enlarge.

### Idempotency & fail-open

- Re-run / next slot's first boot: precondition 4 sees tail ≤ THRESHOLD → skip. No-op.
- Any `sgdisk`/`resize2fs`/`e2fsck` non-zero → `lg` loud + continue boot (data still mounts at
  its old size; a small p6 is degraded, not bricked). Only `partprobe`-not-visible uses the
  retry `exit 1`.
- Never shrink: end is always `0` (disk end) ≥ current end; THRESHOLD gate stops churn.

## Tooling (image)

`batman-provision` Makefile `DEPENDS` currently: `+parted +e2fsprogs +block-mount +dropbear
+uci +blkid`. Add **`+gdisk`** (`sgdisk`) and **`+resize2fs`** (OpenWrt ships resize2fs as its
own package; `e2fsprogs` alone does not include it). `e2fsck` comes from `e2fsprogs` (present).
Confirm exact package names against the OpenMANET feed at build time.

## Failure modes considered

| # | Failure | Mitigation |
|---|---|---|
| 1 | Grow a non-last partition → clobber neighbour | Hard last-partition assertion (precond 3) |
| 2 | GPT backup header at old small-disk end → tools mis-size | `sgdisk -e` first |
| 3 | resize2fs on a mounted fs → refuse/corrupt | Runs at step 3b, before boot()/mount |
| 4 | Kernel won't re-read table (busy) | partprobe + `exit 1` retry next boot |
| 5 | Power loss mid-grow | Table rewrite is a single sgdisk write; fs at first boot is empty; retry next boot; grow-only never destroys data |
| 6 | Already-full card (idempotent / slot flip) | THRESHOLD gate → no-op |
| 7 | LUKS mapper not resized → fs can't grow | step 2b `cryptsetup resize` before 3b |
| 8 | MBR interim card | precond 2 (GPT-only) → skip; p3 already full |
| 9 | resize2fs present but fs unclean | `e2fsck -pf` before resize2fs |

## Alternatives rejected

- **`parted resizepart N 100%`**: interactive prompt on GPT-needs-fix; older parted refuses
  non-interactively; delete+recreate-same-start is deterministic.
- **`growpart`**: not in the image; another dependency; wraps the same sgdisk logic.
- **Build the `.img` with p6 already filling a 32 GB card**: flashes 32 GB (~1 h), wastes
  smaller cards, not size-portable. First-boot grow is the standard appliance pattern.
- **Recreate p6 fresh every boot (like the golden path)**: destroys deployed data on slot flip.
  Grow-in-place preserves it.

## Validation (DoD)

1. Flash the new 1.4.11 A/B `.img` to the 32 GB card (manet04) → after first boot
   `df /opt/batdata` ≈ full card (~25 GB), p6 end ≈ disk end.
2. A/B slot flip → boot the other slot → still full (no-op, idempotent).
3. Re-run on an already-full card → no-op, no shrink.
4. Both slots report 1.4.11.
5. `daily-validation.sh` new regression `p6-grow-201`: assert data partition ≥ X% of the card.
6. Full daily-validation suite green (no trimming).

---

## Review outcome — adversarial review (SOUND-WITH-CHANGES), all folded in

1. **BLOCKER (alignment moves start → fs loss):** recreate with `sgdisk -a 1` (alignment=1) and
   pin the exact start sector read from sysfs. sgdisk can then never shift the entry.
2. **BLOCKER (`-d` then `-n` = orphan window on power loss):** do delete+recreate+relocate as a
   **single atomic** `sgdisk` invocation: `sgdisk -a 1 -e -d 6 -n 6:<start>:0 -t 6:8300 -u 6:<guid> -c 6:data`.
3. **BLOCKER (stale last-usable reintroduces #201):** gate "room to grow?" on the **physical**
   device size from `/sys/block/mmcblk0/size`, NOT GPT last-usable (stale until `-e`).
4. **MAJOR (last-partition check):** assert by **sector geometry via sysfs** — for every other
   partition N, `start(N)+size(N) <= start(p6)`. Name/number-independent.
5. **MAJOR (silent under-grow):** after `partprobe`, verify `/sys/class/block/mmcblk0p6/size`
   actually increased; if not, `exit 1` to retry next boot (the uci-default is one-shot, so a
   plain continue would delete the hook and never finish — exit 1 is required here).
6. **MAJOR (no blockdev; fragile parse):** all geometry from sysfs; `sgdisk -i 6` used ONLY to
   read the GUID (`sed -n 's/^Partition unique GUID: //p'`); `command -v sgdisk` missing → `exit 0`
   skip (never loop).
7. **MAJOR (e2fsck exit codes):** `e2fsck -pf` returns 1 on "fixed" — treat 0/1 as OK, `>=4` as
   failure (skip resize, fail-open). Capture `$?` explicitly (no `set -e`).
8. **MINOR (plain-ext4 under LUKS image):** civilian image has no dm-crypt (LUKS=0) so N/A on the
   tested path; behaviour stays fail-open.
9. **MINOR (pkgs):** `+sgdisk` (base `package/utils/gdisk`) + `+resize2fs` (from `e2fsprogs`).
   Confirmed present in the build tree; no busybox applet conflict; `partprobe` from parted (already dep).
10. **MINOR:** all arithmetic in **sectors**.

### Divergence from the draft (design decision)
The **filesystem grow is decoupled** from the partition grow: step 3b resizes the fs whenever
`fs_sectors < dev_sectors - THRESHOLD` (fs size read from the ext4 superblock via hexdump; dev
size from sysfs of `$DEV`, which is the mapper under LUKS). This is fully idempotent and makes the
exit-1 retry path correct (a boot that grew the table but could not re-read it: next boot the table
is already full so step 1b skips, and step 3b still completes the fs grow). LUKS: `cryptsetup resize`
runs at the top of 3b (idempotent) before measuring, so the mapper reflects the grown partition.
