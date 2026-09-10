# Storage & partition architecture (#88)

The deliberate, versioned SD layout the platform builds to — baked into the image and
auto-provisioned on first boot, **not** hand-carved per node. Motivated by #85: the shipped
OpenMANET image uses a fixed ~4 GB and leaves the rest of the card unpartitioned, so docker
lived in a 2.4 GB btrfs loop **on** the 4 GB overlay and any non-trivial write drove the
overlay full → btrfs read-only → node down. This spec fixes that by design.

Related: #74 (verified boot / A/B), #47 (encryption), #41 (read-only rootfs), #89 (OTA),
#70 (lifecycle), #68/#81 (payload storage + budget), #61 (crash log), #94 (scale sizing).

## Partition scheme (target)

MBR/GPT on the SD; **A/B** so an update writes the inactive slot and can roll back.

| Part | Role | FS | Encryption | Notes |
|---|---|---|---|---|
| p1 | boot / firmware | fat | none | signed boot artifacts (#74); OTP/secure-boot chain |
| p2 | **rootfs A** | squashfs/ext4 | **dm-verity** (integrity, read-only) | signed image slot |
| p3 | **rootfs B** | squashfs/ext4 | **dm-verity** | second slot; A/B flip on update |
| p4 | **config + identity** | ext4 | **LUKS** | node identity, keys/certs, UCI config — secrecy |
| p5 | **data + payload** | ext4 | **LUKS** | docker data-root, FTS DBs, logs, payload tenants — **expand-to-fill** on first boot |

Rationale: boot plaintext; rootfs verity = integrity not secrecy (the "scp a file and run"
hole dies here, #74); config/identity + data = LUKS secrecy. **A/B updates touch only the
inactive rootfs slot — p4/p5 (config, identity, data, DBs, logs) are never wiped by an
update or rollback.**

> Current reactive state (2026-09-10): only the data-root move is done — a single hand-made
> `mmcblk0p3` (27.5 GB ext4) holds docker + (bind-mounted) FTS data. That is the **migration
> precursor**, not this scheme; it must be replaced by the provisioned layout below. dm-verity
> rootfs + LUKS + A/B are **not yet** in place.

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

- Persistent syslog + EMS spool + crash artifacts on **p5**, off the rootfs overlay (today
  the syslog is on `/root` = rootfs → wiped by A/B; must move).
- Reserve a **ramoops/pstore region** so a kernel panic's last output survives a reboot
  (today `/proc/cmdline` has no ramoops → a pure hang leaves no backtrace). See #61.

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

## Validation (spare card — plan)

Flash the image + firstboot hook onto a **spare SD card**, boot it on **manet01's Pi** (its
own card set aside, swapped back after — manet01 is idle), and verify: correct GPT layout,
LUKS unlock via the sealed key, p5 expand-to-fill, data/DB/log on p5, config/identity on p4,
and an A/B slot flip + rollback leaving p4/p5 intact. No third Pi and no risk to manet02.

Prove the firstboot provisioning on a **fresh flash of a spare card / spare Pi** (manet02 is
already hand-carved and can't re-test first boot). Check: correct layout, LUKS unlock, p5
expand-to-fill, data/DB/log on p5, config on p4, A/B slot flip + rollback leave p4/p5 intact.
