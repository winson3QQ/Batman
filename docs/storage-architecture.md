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

**p5 sub-layout v1 (in the golden since 2026-09-11, `95-batman-storage`):** the data partition
is mounted at `/opt/batdata` by the `batdata-mount` init (**S11**, before logd S12, so every
consumer finds it mounted) with two fixed directories:

| Dir | Written when | Content |
|---|---|---|
| `crash/` | boot, only if pstore has records | kernel-panic dmesg moved off the volatile ramoops region (`<ts>_<bootid>_dmesg-ramoops-N`) |
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

### B1 — GPT (resolved)
Pi-4 bootloader is `2023/01/11` → supports GPT. **Decision: GPT** (5 partitions exceed MBR's
4 primaries). Boot partition stays FAT for the Pi firmware. Verify the signed-boot chain (#74)
reads GPT on the target bootloader before locking it in.

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
