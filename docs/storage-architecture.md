# Storage & partition architecture (#88)

The deliberate, versioned SD layout the platform builds to — baked into the image and
auto-provisioned on first boot, **not** hand-carved per node. Motivated by #85: the shipped
OpenMANET image uses a fixed ~4 GB and leaves the rest of the card unpartitioned, so docker
lived in a 2.4 GB btrfs loop **on** the 4 GB overlay and any non-trivial write drove the
overlay full → btrfs read-only → node down. This spec fixes that by design.

Related: #74 (verified boot / A/B), #47 (encryption), #41 (read-only rootfs), #89 (OTA),
#70 (lifecycle), #68/#81 (payload storage + budget), #61 (crash log), #94 (scale sizing).

## Partition scheme v2 (target, #106 — decided 2026-09-11)

GPT on the SD (Pi 4 EEPROM supports GPT/hybrid MBR since 2020-09; the bench EEPROM is
2026-08-generation). **A/B** so an update writes the inactive slot and can roll back. Because
the Pi 4 bootloader's `tryboot_a_b` switches the **boot partition**, every slot owns its own
boot partition (v1 of this table had a single boot — superseded).

| Part | Role | Size | FS | Encryption | Notes |
|---|---|---|---|---|---|
| p1 | **boot A** | 64 MB | fat | none | kernel + dtb + overlays + cmdline of slot A; `autoboot.txt` lives here (first FAT partition); EEPROM updates **only** here, never on p3 (rpi-eeprom #499) |
| p2 | **rootfs A** | 1.5 GB | squashfs | **dm-verity** (integrity, read-only) | signed image slot; docker/kmods/runtimes baked in (B2) |
| p3 | **boot B** | 64 MB | fat | none | slot B kernel set |
| p4 | **rootfs B** | 1.5 GB | squashfs | **dm-verity** | second slot |
| p5 | **config + identity** | 512 MB | ext4 | **LUKS** (Secure tiers) | OpenWrt overlay (UCI, packages state), node identity, mesh key, SSH host keys, #13 certs — secrecy; survives every update/rollback |
| p6 | **data + payload** | expand-to-fill | ext4 | **LUKS** (Secure tiers) | `crash/ log/ docker/ apps/<tenant>/` (sub-layout v1 below); a full p6 fails tenants, never the OS |
| (reserved) | rescue slot | 300 MB | — | — | left unallocated after p4 for a mesh+SSH-only rescue image (field-resilience.md decision 3); allocated only on evidence |

Fixed part ≈ 4 GB → **minimum supported card 16 GB**; default 32 GB high-endurance; FTS-heavy
or recording tenants 64 GB+ or an external SSD (productization.md sizing).

**Zero 2 W profile:** no EEPROM bootloader → one boot partition (p1) holding both kernel sets
under `os_prefix=A/` and `B/` switched by `tryboot.txt`; p2/p3 = rootfs A/B; p4 config; p5
data; no verity-with-signed-boot guarantee and no LUKS (Base tier). The boot partition is its
single unrecoverable point — written only for the few-byte `os_prefix` switch.

**Migration from v1.1 (p1 boot / p2 root+overlay / p3 data):** a v2 image is a repartition —
it cannot be applied in place by the A/B updater. Path: back up p3 tenant state (`apps/`,
`crash/`, `log/`) and p2's overlay config over the mesh or to a spare card → flash the v2
golden → first boot restores config identity from the backup into p5 and tenant state into p6.
That one-time migration is the last "reflash" a fleet node should ever need; from v2 on,
updates are slot writes.

Rationale: boot plaintext; rootfs verity = integrity not secrecy (the "scp a file and run"
hole dies here, #74); config/identity + data = LUKS secrecy. **A/B updates touch only the
inactive slot pair — p5/p6 (config, identity, data, DBs, logs) are never wiped by an update
or rollback.** Slot policy, boot-loop handling and the recovery-image decision:
[field-resilience.md](field-resilience.md).

### v1 of this table (2026-09-10, superseded)
p1 boot · p2 rootfs A · p3 rootfs B · p4 config · p5 data — one boot partition. Kept for the
record; the tryboot_a_b fact and the Zero 2 W profile made it obsolete.

> Current state (2026-09-11): the golden image now **self-provisions a single data partition**
> (`mmcblk0p3`, expand-to-fill, ext4, mounted at `/opt/batdata`) on first boot — validated on a
> fresh flash. manet02 still runs its earlier hand-made p3 (docker + bind-mounted FTS data).
> Both are the **interim one-data-partition** form of this scheme, not the A/B layout:
> dm-verity rootfs + LUKS + A/B slots are **not yet** in place (they need the one-time kernel
> rebuild: `DM_VERITY`/`DM_CRYPT`).

## What lives where (and the survives-upgrade invariants)

- **rootfs (A/B, verity, read-only):** OS, kernel, the FTS/payload **images**. Replaced
  wholesale by an update. Holds **no** state.
- **p4 config/identity (LUKS):** node identity + keys/certs (trust anchor), OpenWrt UCI
  (`/etc/config` — network, HaLow/wireless, firewall, mesh). **Today these live in the rootfs
  overlay → an A/B swap would wipe them → must relocate to p4.**
- **p5 data (LUKS):** docker data-root, **FTS SQLite DBs**, persistent logs + EMS spool (#65),
  crash artifacts (#61), payload-tenant data.

**Invariants**
1. Config / identity / data / DBs / logs survive an **A/B image swap** (they're on p4/p5,
   not the slot).
2. They survive a **rollback**: config is **schema-versioned** — a new image migrates config
   forward on first boot; the previous image must tolerate/ignore unknown keys on rollback.
   ("Config survives rollback" is the hard part.)
3. Encryption boundary: boot plaintext · rootfs verity (integrity) · p4/p5 LUKS (secrecy),
   key release gated on a good attestation (#47/#97).
4. Factory-reset/zeroize (#70) deliberately wipes p4/p5; a normal update never does.

## Databases (distinct from files)

FTS uses SQLite (FTSDataBase, CoTManagement, Mission, ExCheck + the UI DB). They need more
than raw space:
- **On p5**, never on the rootfs overlay (done reactively via bind-mount 2026-09-10; the
  provisioned layout makes it native).
- **WAL journal mode + tuned `synchronous`** — the shipped default is `delete`, the
  power-loss-corruption-prone mode; on a hard-power-off node (#41) that risks a corrupt DB →
  FTS won't start. Graceful shutdown (#91) is the primary mitigation, WAL the second.
- **Consistent backup**: SQLite `.backup`/snapshot, never a raw cp of a live file (feeds node
  backup + #95 identity restore).
- **Integrity on boot** (`PRAGMA integrity_check`) + restore-from-backup on corruption.
- **Retention + periodic VACUUM** (SQLite doesn't shrink on delete).

## Logs & crash (ties to #61)

**Data-partition sub-layout v1 (in the golden since 2026-09-11, `95-batman-storage`; the
partition is p3 on the v1.1 interim layout and p6 in scheme v2):** it is mounted at
`/opt/batdata` by the `batdata-mount` init (**S11**, before logd S12, so every consumer finds
it mounted) with these fixed directories:

| Dir | Written when | Content |
|---|---|---|
| `crash/` | boot, only after an unclean end | kernel-panic dmesg (`<ts>_<bootid>_dmesg-ramoops-N`) and, on unclean boots only, the last kernel console (`…_console-ramoops-0`, 32 KB, last 5 kept) moved off the volatile ramoops region; a clean boot discards its console record without writing |
| `log/` | boot (one line) + clean shutdown | `boot-reasons.log` — one line per boot saying why the previous life ended (**PANIC / CLEAN: trigger / UNCLEAN** = power loss or hw watchdog); `shutdown_<ts>_<bootid>.log` — the syslog ring dumped at clean shutdown (last 10 kept) |
| `docker/` | payload hosts only | docker data-root (`dockerd.globals.data_root`): all container **images**, shared and layer-deduplicated; rebuildable, replaced by OTA — holds no tenant state |
| `apps/<tenant>/` | by the tenant | **one directory per tenant** (`fts/`, `fts-ui/`, later `video-relay/`, `sdr/`, `mqtt/`…): everything that tenant must keep — mounted straight into its container (`-v /opt/batdata/apps/fts:/opt/fts`), never bind-mounted back to legacy paths |

**Tenant rules (decided 2026-09-11, #119):** images shared, state isolated — backup, wipe,
migrate and quota are all done per `apps/<name>/`; every tenant has one declaration in the
repo (`deploy/<name>/`: Dockerfile + `run.sh` + functional test) and nothing is hand-typed on
the node; quota/retention are tenant attributes (#68/#81 — GB/hour tenants ring-buffer
themselves, hard limits via ext4 project quota or per-tenant subvolume later); a full p3 only
fails that tenant's writes, the OS on the rootfs is unaffected; tenant logs go to the EMS
(#65) or the tenant's own directory, never to the platform `log/`.

**SD-write policy (#41):** zero steady-state writes — the SD is touched only at boot (if a panic
was captured) and at clean shutdown. **Continuous log persistence is deliberately NOT done
here**; that is the EMS collector's store-and-forward job (#65). Hard power-off loses the
unflushed tail by definition (documented in crash-debug.md).

- ramoops/pstore region: reserved and working (the malformed DT `reg` is fixed in the golden's
  `ramoops.dtbo`; see crash-debug.md / `fix-ramoops-dtbo.sh`).
- **Decided (#119):** FTS data/DBs live in `apps/fts/` and `apps/fts-ui/`, the docker data-root
  in `docker/` (table above). The ex-manet02 p3 was migrated in place (same filesystem `mv`)
  and FTS redeployed on it with `deploy/fts/run.sh`.

## Capacity / quota / retention (measured)

Baseline on manet02 (2026-09-10): FTS images ~690 MB (dedup), FTS data **574 KB**, p5 ~1.3 GB
/ 25 GB (5%). Footprint is tiny **now**; the risk is **unbudgeted growth** — FTS DataPackage
file-sharing (→ GBs), payload video/SDR capture (**GB/hour**), image accretion, EMS spool.

Required: **per-tenant quotas** (FTS + each payload get a hard cap — overlay/project quota or
separate mounts on p5); **retention** (DataPackage/logs rotate/cap, payload recordings
ring-buffered, image GC keeps current+rollback); **threshold alerts before full** (#66); a
full p5 **fails gracefully** (tenant write error), never degrades the node. **Structural win
already banked: p5 is separate from rootfs/overlay, so a full data partition can no longer
force the OS read-only** (the failure hit twice this session). Size p5's log/spool for fleet
scale (#94). Ties to the storage half of the resource budget (#81).

## First-boot provisioning (the anti-manual-surgery requirement)

The image ships the scheme; a **firstboot hook** makes it real on the actual card, once, with
no per-node surgery:
1. Detect the card, create p4/p5 in the free space (the scheme's fixed offsets for boot/rootfs
   are baked; p5 is **expand-to-fill** whatever the card size).
2. LUKS-format p4/p5 (key from the secure element / key-fill, #47).
3. Make filesystems; lay out docker data-root, FTS data/DBs, logs on p5; identity/UCI on p4.
4. Mount by LABEL/PARTUUID (persist in the boot/init path, not manual).
5. Idempotent + re-entrant (survives an interrupted first boot); logs to the persistent log.

**Versioned + migratable:** the scheme has a version; when it changes between releases, a
defined migration runs (the reactive p3 move + DB bind-mount is the manual precursor to this).

## Open design decisions (from design review 2026-09-10)

The scheme above is the target; these must be resolved before it's buildable. 🔴 = blocker.

1. **🔴 GPT, not MBR.** The card ships `msdos` (MBR), which allows only **4 primary
   partitions** — the scheme has 5 (p1–p5). Switch to **GPT** (or an extended partition).
   Confirm the Pi 4 bootloader boots GPT with the signed-boot chain (#74). *Decision: GPT.*
2. **🔴 dm-verity read-only rootfs vs the OpenWrt writable overlay.** OpenWrt keeps its config
   + installed packages in a **writable overlay on the rootfs**; dm-verity makes rootfs
   read-only → the overlay model breaks. The overlay/UCI must be relocated to p4, and the
   OpenWrt boot must be taught to mount config from p4 instead of a rootfs overlay. This is a
   real change to how the platform boots. **Owned jointly with #74** (verity is #74's mechanism).
3. **🔴 LUKS key on an unattended node.** p4/p5 are LUKS-encrypted, but a field node
   auto-boots with no operator to enter a passphrase → the key must be available at boot. **If
   the key sits on the same card, a stolen card unlocks trivially → encryption at rest is
   theatre.** Value requires the key **sealed to the secure element / TPM and released only on
   a good measured-boot attestation** (#74/#47/#97). **Owned by #47** (this is its crux).
4. **Minimum card size.** A/B doubles the rootfs (~8 GB) + boot + p4 + p5 → state a supported
   minimum (e.g. ≥16 GB) and the A/B slot size.
5. **Expand-to-fill vs. future partitions.** If p5 consumes all free space on first boot,
   there's no room to add a p6 in a later scheme version → either reserve headroom or accept
   that a layout change is a repartition-migration (versioned; the reactive p3 move is the
   precursor).
6. **Recovery/rescue slot.** No rescue partition — if both A/B slots are bad, field recovery
   means re-flash. Consider a small rescue image slot.
7. **p5 co-tenancy.** docker + FTS DBs + logs + bulk payload share p5; a payload filling it
   affects the DBs/logs. Per-tenant quotas mitigate; consider DBs/identity-critical state on a
   protected partition separate from bulk payload.
8. **"Config survives rollback" is hard.** Forward-migrate on upgrade + backward-tolerate on
   rollback (schema-versioned config) is non-trivial and high-risk; needs its own design.

## Blocker resolutions (design, grounded on manet02 facts 2026-09-10)

### B1 — GPT + the tryboot mechanism (bench-verified 2026-09-11, #106)
The Pi 4 EEPROM release notes list GPT + hybrid-MBR support since **2020-09-14**; the bench
node's EEPROM is **2026-01-09** (`chosen/bootloader/capabilities = 0x7f`). **Decision: GPT**
(six partitions exceed MBR's 4 primaries). Boot partitions stay FAT for the Pi firmware.

**What was proven on the dev node (Pi 4B):**
- **tryboot trigger:** busybox `reboot` does **not** accept the `"0 tryboot"` restart string
  (and there's no gcc/python/perl in the image). Use `vcmailbox 0x00038064 4 4 1` (set reboot
  flags bit0 = tryboot) then a normal `reboot`. `vcmailbox` **is** in the image. → the #89
  apply flow must ship a vcmailbox-based trigger; don't rely on `reboot`.
- **observable / one-shot:** `/proc/device-tree/chosen/bootloader/tryboot` reads 1 after a
  tryboot boot (big-endian), 0 otherwise; `…/partition` reports the booted partition; the
  firmware reboot flag auto-clears after consumption. So a node always knows if it is in a
  trial boot — the hook for health-gated commit / fallback (#89).
- **fallback safety (the key result):** a bootB the firmware **cannot** boot → **automatic,
  clean fall-back to bootA, no brick, no watchdog event** (the fallback is pre-Linux). Held on
  the only remotely-reachable node with no way to power-cycle. This is the safety floor the
  whole A/B design (#89) stands on.

**What is NOT yet proven:** actually *booting* a second boot partition. The bench card was
later read off-node on a card reader (Pi 500, 2026-09-11) and the BPB explanation first
recorded here **did not survive measurement** — corrected below.

> **Correction (2026-09-11).** This section originally said the `dd if=bootA of=bootB` copy
> carried bootA's start LBA in the FAT **BPB `hidden_sectors`**, and that the firmware's FAT
> reader rejected bootB for it. Measured on the bench card itself (p1 start LBA 8192, p4 start
> LBA 62025728):
>
> ```
> p1 (bootA)  OEM='mkfs.fat'  hidden_sectors=0  total_sectors32=131072
> p4 (bootB)  OEM='mkfs.fat'  hidden_sectors=0  total_sectors32=131072
> ```
>
> **Both are 0**, and bootA boots fine with 0 — so `hidden_sectors` cannot be what separated
> them. What the `dd` copy *did* produce: an identical FAT volume id (`6859-BBC4`) and label
> (`boot`) on both partitions, and a `total_sectors32` of 131072 (64 MiB) inside a 307200-sector
> (150 MiB) partition. More decisive: **neither boot partition contained `autoboot.txt` (nor
> `tryboot.txt`)**. Without `tryboot_a_b=1` + `boot_partition=`, the firmware does no
> boot-partition switching at all — so the trial boot simply used the normal partition. "The
> firmware rejected bootB" was never demonstrated; **boot-partition switching had not been
> configured**, which is a sufficient explanation for the observed behaviour on its own.

**The lesson still holds, for a better-grounded reason:** build each boot slot with
**`mkfs.vfat` on its own partition, never `dd`-copy one** — a fresh mkfs gets `hidden_sectors`,
the volume size and a *distinct* volume id right for free, while a `dd` clone duplicates the
volume id/label and describes the source partition's size. And **`autoboot.txt` must be written
explicitly**, on the first FAT partition, or A/B is inert.

`mkfs.vfat` (dosfstools) and `resize2fs` are **not in the image** — so in-place A/B
provisioning needs them added, or the card is built offline. Full GPT six-partition A/B boot +
slot-switch must be **built and boot-tested on a spare card offline** (no USB card reader on
site), not by repartitioning the only remote node. Signed-boot chain (#74) verification rides
on that card. Card build: **done** (below); boot test: **done, passed** (2026-09-11, below).

**The offline card — built and boot-tested 2026-09-11 (#133).** Built on the Pi 500 card
reader by `scripts/build-gpt-ab-card.sh` from the bench card (backed up first), GPT, 29.7 GiB:

| # | Name | Start (s) | Size | FS | Label | PARTUUID suffix |
|---|---|---|---|---|---|---|
| 1 | bootA | 8192 | 64 MiB | fat16 | `BOOTA` | `…-0001` |
| 2 | rootA | 139264 | 1.5 GiB | squashfs | — | `…-0002` |
| 3 | bootB | 3284992 | 64 MiB | fat16 | `BOOTB` | `…-0003` |
| 4 | rootB | 3416064 | 1.5 GiB | squashfs | — | `…-0004` |
| — | *(rescue reserve)* | 6561792 | 300 MiB | *unallocated* | — | — |
| 5 | config | 7176192 | 512 MiB | ext4 | `batconfig` | `…-0005` |
| 6 | data | 8224768 | 25.8 GiB | ext4 | `batdata` | `…-0006` |

Verified after the build: `hidden_sectors` = 8192 (p1) and 3284992 (p3), each matching its own
start LBA; volume ids distinct (`BA71-0001` / `BA71-0003`); `autoboot.txt` present on **bootA
only** (as built: `[all] tryboot_a_b=1, boot_partition=1` / `[tryboot] boot_partition=3` — that
`3` is the GPT index and is **wrong**, see the boot-test result below; the script now derives
it and writes `2`); each slot's
`cmdline.txt` points at its own rootfs PARTUUID and carries a `batman_slot=A|B` marker; both
rootfs slots hold a valid 52.7 MB squashfs with a zeroed tail for fstools to build the overlay
in. PARTUUIDs are deterministic (`3276af79-0000-4000-8000-00000000000N`, prefix = the card's
former MBR id) — readable in logs, but **bench-only**: two such cards in one machine would
collide, so a production build must mint random GUIDs.

The boot test cannot run on the Pi 500 (BCM2712; the card carries only `bcm2711-*.dtb`), so it
was run on the manet01 Pi 4 (EEPROM `build-timestamp` **2026-01-09**, `capabilities=0x7f`).

**Result — the A/B mechanism works end to end (2026-09-11, #133).** Every line below is a
reading off `/proc/device-tree/chosen/bootloader/` and `/proc/cmdline` on that node:

| step | trigger | `batman_slot` | `…/partition` | `…/tryboot` |
|---|---|---|---|---|
| boot slot A | power-on | `A` | 1 | 0 |
| trial-boot B | `vcmailbox 0x00038064 4 4 1` + `reboot` | **`B`** | **2** | **1** |
| trial is one-shot | plain `reboot` | `A` | 1 | 0 |
| commit B | `[all] boot_partition=2`, plain `reboot` | **`B`** | 2 | 0 |
| back to A | `[all] boot_partition=1`, plain `reboot` | `A` | 1 | 0 |

Also confirmed on the way: `root=PARTUUID=` in **full GPT-GUID form** resolves (the kernel has
`CONFIG_EFI_PARTITION=y`), fstools builds its f2fs overlay happily in the 1.5 GiB root slot
(1.4 GiB free), and the reboot flag set by `vcmailbox` **auto-clears** after the firmware
consumes it (read back 0x1 before the reboot, 0x0 after).

**`boot_partition` is the firmware's partition number, NOT the GPT index.** This is the trap,
and the v2 design had it wrong. The firmware counts only the partitions it can boot from — the
FAT ones — so with bootA=gpt1, rootA=gpt2, bootB=gpt3, **bootB is `boot_partition=2`, not 3**;
the squashfs slots are not counted. The first attempt used `boot_partition=3`, which points at
nothing the firmware will boot, and it **cleanly failed over to partition 1** — tryboot mode was
entered (`tryboot`=1) but the slot never switched. That failure mode is silent and looks like
success from userspace unless you read `…/partition`, so **#89's apply flow must verify the slot
it actually landed on, never assume the switch took**. `scripts/build-gpt-ab-card.sh` now writes
`[tryboot] boot_partition=2`.

This also re-confirms the fallback safety floor from the bench work above, this time on a real
A/B card: a `boot_partition` the firmware cannot boot costs one wasted reboot, not a brick.

**The rootfs needed ETHFIX to be reachable.** The card's squashfs came from a stock 1.8.0 image,
whose `etc/board.d/03_openmanet_eth` case list has no `bcm2711,*` entry — so on a Pi 4 eth0 is
left out of every network interface and the node boots fine with no wired L3 at all. Both root
slots were re-squashed with `patches/03_openmanet_eth.1.8.0-ethfix` (and an `authorized_keys`,
since that node's serial console drops characters); eth0 then came up in `br-lan` at
`10.41.254.1`. See the correction in [`golden-image.md`](golden-image.md). Re-squashing changes
the filesystem size, which is why the build script now reads `SQUASH_BYTES` from `unsquashfs -s`
instead of hard-coding it.

**Failure-case matrix (bench-run 2026-09-11, #133).** The happy path above is not the
interesting part; these are. Every row was induced on the real card and observed on the node.

| case | as shipped | after the cmdline fix |
|---|---|---|
| bootB missing `start4.elf` (firmware cannot boot the slot) | 52 s auto-return to A, `tryboot`=1 | — |
| bootB missing `kernel8.img` (fails *after* `start4.elf` loads) | 52 s auto-return to A, **`tryboot`=0** | — |
| rootfs absent (`root=` points at nothing) | **dead hang >5 min, needs a power cycle** | **77 s auto-recovery** |
| rootB squashfs corrupted | **dead hang** | **62 s auto-recovery** |
| `autoboot.txt` truncated mid-write (power cut during commit) | boots partition 1 — **the commit is silently lost** | — |
| `autoboot.txt` absent | boots partition 1; setting the tryboot flag does nothing at all | — |
| committed slot B unbootable *at firmware level* | 52 s auto-return to A, but `autoboot.txt` is **not** rewritten | — |
| committed slot B broken *at kernel level* | **not directly observed** — reasoned below | unchanged — see below |

**The `rootwait` trap — the single most dangerous line in the layout.** A bare `rootwait`
waits for the root device *forever*. When a slot's rootfs is missing or corrupt the kernel
therefore never gives up, procd never starts, `/dev/watchdog` is never opened, and nothing
resets the board. The result is not a boot loop — it is a **silent dead node**, and the
firmware's tryboot fallback does not apply because the firmware already handed off to the
kernel successfully. `rootwait=20 panic=10` bounds the wait and turns the failure into an
automatic return to the other slot. Do **not** simply drop `rootwait`: mmc probes
asynchronously, so a *healthy* slot then races the device and panics too (this was tried and
caught by regression — the "fix" recovered only because it broke every slot equally).
Kernel 6.6.138 accepts the `rootwait=N` form.

**Three ways the mechanism can lie to userspace.** Each of these makes a failed update look
like a successful one, and #89 has to defend against all three:

1. **`chosen/bootloader/tryboot` is not a reliable "the trial failed" signal.** If the
   firmware got as far as loading `start4.elf` from the trial slot, the flag is already
   consumed; the recovery boot is then indistinguishable from an ordinary boot. The apply
   flow must record "I asked for a trial boot" in its own persistent storage (the config
   partition) rather than inferring it.
2. **Commit is not atomic.** `boot_partition` lives in a text file on a FAT partition. A power
   cut mid-rewrite leaves no `boot_partition`, the firmware defaults to partition 1, and the
   node quietly runs the *old* image while the fleet believes it took the update.
3. **Firmware fallback does not repair `autoboot.txt`.** After falling back, the file still
   names the broken slot, so every subsequent boot burns a failed attempt first, and declared
   state and actual state stay diverged. Every boot should compare
   `chosen/bootloader/partition` against the file and reconcile.

**What still has no automatic recovery:** a slot that was *committed* and then fails at kernel
level. This row is **inferred, not measured** — the case was set up on the card (committed to B,
rootB destroyed) but the run was aborted and the card pulled before the loop could be observed,
so treat it accordingly. The inference rests on rows that *were* measured: the firmware only
falls back when it cannot boot the slot itself, and once it hands off it is satisfied; a
kernel-level failure therefore never reaches the fallback path. There is no boot counter anywhere in the Pi boot chain to break the loop,
and the good slot's userspace never gets to run. This is the structural reason #89 must own a
boot-attempt counter itself, and why commit must never happen before the trial slot has proven
itself healthy.

### Keeping this true — the three guards

Everything above was established by hand on one afternoon. Nothing in the repo stopped
somebody putting a bare `rootwait` back, and the failure mode of doing so is a node that boots
fine today and is unrecoverable in the field a year later. Three guards now hold it:

**1. `tests/ab-card-invariants.sh` — every PR, no hardware.** Builds a real card on a loop
device by running `scripts/build-gpt-ab-card.sh` unmodified, then asserts the invariants
against the *artifact*, not the source: autoboot.txt on bootA only, `boot_partition` equal to
the firmware's FAT-partition index rather than the GPT index, a bounded `rootwait=N` plus
`panic=N` and never a bare `rootwait`, distinct FAT volume ids, `hidden_sectors` matching each
start LBA, both root slots identical. Wired into `ci.yml` as the `ab-card` job. It was
mutation-tested when written — reintroducing the bare `rootwait` trips six assertions,
hard-coding the GPT index trips two, and hard-coding a value that happens to be *correct for
today's layout* trips the one source-level assertion that exists for exactly that case.

**2. `scripts/build-gpt-ab-card.sh` derives `boot_partition`.** It counts FAT partitions in
GPT order instead of writing a literal. A hard-coded number survives a layout change silently,
and the symptom — the node boots the *old* slot and reports itself healthy — is invisible to
any health check.

**3. `scripts/ab-selftest.sh <node> [--inspect-only|--destructive]` — the hardware guard.**
The CI job cannot prove the firmware behaves; only a Pi can. Three modes:

| mode | what it does | when |
|---|---|---|
| `--inspect-only` | static invariants over SSH, **no reboots** | scheduled / whenever a bench node is up |
| *(default)* | the above plus tryboot switch + one-shot check, 2 reboots, ~2 min | after touching the layout or the build script |
| `--destructive` | plus both failure classes, 4 reboots, ~6 min | before tagging a release |

`--destructive` breaks the *inactive* slot only, saves what it breaks **on the test host** (the
node's `/tmp` is tmpfs and every case under test reboots it), restores it, and verifies the
restore. It refuses to run against anything whose `/proc/cmdline` lacks a `batman_slot` marker,
and refuses the destructive cases unless the node is currently committed to slot A.

Last full run: 16/16 on the bench card, 2026-09-11.

### B2 — verity vs overlay: the real problem is *what's in the overlay*
Reframed by the facts: OpenWrt **already** runs a read-only squashfs (`/rom`, 52.8 MB) + a
writable f2fs **overlay** unified by overlayfs. So verity doesn't break a "writable rootfs" —
it protects the squashfs. **The real issue:** the squashfs is only 52.8 MB, while the overlay
is 3.9 GB — **docker, kmods, the whole container/FTS infrastructure live in the writable
overlay, not the signed base.** dm-verity on the squashfs would protect ~52 MB and leave
everything that matters mutable → the "only signed code runs" guarantee (#74) is hollow.

**Resolution:** repackage the image so **all code ships inside the verity-protected rootfs**
(docker, kmods, container runtimes baked into the signed A/B slot), leaving the overlay for
**config + data only**. Move that overlay off the A/B slot to **p4** (persistent, survives
swap). In prod, the overlay carries **no trusted executable code** — anything runnable is in
the signed slot or a signed+admitted container (#97). This is a real change to how OpenMANET
is built (a bigger, signed rootfs) — owned jointly with #74.

### B3 — LUKS key on an unattended node: no SE/TPM present → it's a CONOPS choice
Grounded: **Pi 4 has no TPM**, and manet02 has **no crypto secure element** (i2c shows only
non-crypto devices at 0x2d/0x43). So "seal the key to platform state" is not available today.
Honest options, a **threat-model decision (#69) + future hardware (#47):**
- **(a) Auto-unlock** — key in a *future* soldered SE, released to a signed-boot initramfs.
  Unattended (no operator), but only protects against a **stolen SD card** (the key isn't on
  the card); a captured *board* boots itself and unlocks. Needs the SE hardware (#47).
- **(b) Operator key-fill at deploy** — operator loads the key (USB-C/M12 key-fill, #47),
  held in RAM, **zeroized on tamper/power-off**. Protects against **board capture**, but the
  node can't cold-boot unattended (needs a re-fill).
- The choice is per node class / mission (#69): a relay left in the field vs. an operator-
  carried node. **Until an SE is on the board, at-rest encryption's guarantee is limited to
  card-theft (b gives more but costs unattended boot).** Documented so we don't claim more
  than the hardware delivers.

## Validation (spare card — plan)

Flash the image + firstboot hook onto a **spare SD card**, boot it on **manet01's Pi** (its
own card set aside, swapped back after — manet01 is idle), and verify: correct GPT layout,
LUKS unlock via the sealed key, p5 expand-to-fill, data/DB/log on p5, config/identity on p4,
and an A/B slot flip + rollback leaving p4/p5 intact. No third Pi and no risk to manet02.

Prove the firstboot provisioning on a **fresh flash of a spare card / spare Pi** (manet02 is
already hand-carved and can't re-test first boot). Check: correct layout, LUKS unlock, p5
expand-to-fill, data/DB/log on p5, config on p4, A/B slot flip + rollback leave p4/p5 intact.
