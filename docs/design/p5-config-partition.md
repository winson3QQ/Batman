# Design Review — p5 shared config partition (#88 / #89) — **v3**

Status: **REVIEW PASSED (round 5: APPROVE-WITH-CHANGES; the two prescribed fixes applied)**,
2026-09-12. Five rounds of independent adversarial review; every finding resolved. Cleared to run
the boot-critical fresh-overlay reboot test (procedure below). Boot-critical; no serial console
(#105); manet01 risk accepted with the golden card as fallback.

**Seeding — primary path is AUTO (N5r3):** `build-gpt-ab-card.sh` ext4-formats p5 at card build,
so `joinwatch` runs `batman-config-save --if-healthy` on the **first boot that reaches a halow-status
OK verdict** and seeds p5 then (writes `.seeded` last). Manual `batman-config-save --seed` is only
needed to seed before the first OK boot (e.g. in the bench test). The save skips (exit 3, keeps
retrying) while health is merely WARN, so a marginal node keeps trying until genuinely OK.

## round-5 fixes (applied)
| finding | fix |
|---|---|
| N5r2 WARN node never seeds | `--if-healthy` not-OK skip now `exit 3` (non-zero) so joinwatch's `&&` guard does not latch; retries until OK. |
| N5r1 marker written without identity | `/tmp/p5-restored` gated on `[ -n "$idfp" ]` — if no host key was restored, 99 personalises rather than leaving the golden sentinel hostname/IP colliding. |
| N5r4 no-p5 busy retry | joinwatch skips the saver cheaply (`[ ! -b /dev/mmcblk0p5 ]`) on cards without p5. |
| N5r3 doc | auto-seed documented as the primary path (above). |

## v5 changes (round-4 fixes)
| finding | fix in v5 |
|---|---|
| N-R1 not built into image | depersonalise installs `96` + `/usr/bin/batman-config-save` (check-loop + install block). **Seed is a per-card deployment step** (`batman-config-save --seed`, ties #54), NOT baked into the image — the reference node has no p5. |
| N-R2 `99` undoes the restore | `96` drops `/tmp/p5-restored` after restoring identity; `99-halow-identity` exits early on that marker, skipping host-key deletion / hostname / IP / dhcpconfigured reset. |
| N-R3 openmanetd re-address gate | **verify-on-test** (a test assertion, not code): restored `dhcpconfigured=1`+`roipconfigured` must suppress the two-stage reboot; assert no "Rebooting system to apply new network settings" in logread. |
| N-R4 95 LUKS wipes p6 | `luksFormat` now refused when the partition already `has_fs`. |
| N-R5 marker to overlay / parted guard | `96` warns to kmsg if `/opt/batdata` is not a mountpoint; `95` moved the parted guard inside the create branch so a pre-made p6 mounts without parted. |
| N-R6 lossy value round-trip | `batman-config-save` single-quotes values (spaces survive) and refuses embedded quotes/metacharacters. |
| N-R7 reader allow-list loose | `96` ALLOWED_PKGS trimmed to what the saver writes (`system wireless network openmanetd mesh11sd`); no `dhcp`/`firewall`. |
| N-R8 lkg not last-known-good | lkg rotated only on `--seed` (baseline) and `--if-healthy` (proven); `--save` leaves the last proven lkg. |
| N5 saver owner | joinwatch calls `batman-config-save --if-healthy` once per healthy boot (tmpfs once-guard). |
| N-R9 lock/health-regex | once-per-boot guard added; flock + halow-status HEALTH-line format still to confirm on target (pre-production). |

## v4 changes (round-3 fixes)
| finding | fix in v4 |
|---|---|
| V3-1 export-vs-batch | fragment is a **uci batch** end to end (`batman-config-save` writes `set` lines; `valid_batch` + `uci batch` consume them). Doc drift removed. |
| V3-2 identity gated behind Lane-B | `96` copies identity **first and unconditionally**, before fragment selection (`96` step 3 precedes step 4). |
| V3-3 rollback discards identity | identity copy is before the schema gate; a too-new-schema p5 falls back to `lkg/` for Lane-B and never drops identity. |
| V3-4 p6 marker / `95` broken on v2 | `95` is now layout-aware (uses the pre-made p6 on the GPT card), so `/opt/batdata` mounts and the marker persists. |
| V3-5 bypass one-way trap | bypass `exit 1` keeps the uci-default armed; removing the cmdline flag re-arms migration. |
| V3-6 partial commit on error | on `uci batch` failure, `uci revert` every allow-listed package before returning — nothing partial reaches the trailing commit. |
| V3-7 valid_batch too permissive | package allow-list + no coarse `delete` (≥3 path segments) in `valid_batch`; `batman-config-save` also refuses unsafe values. |
| V3-8 dirty ext4 ro / shebang | `mount -o ro,noload`; `#!/bin/sh` added. |
| V3-9 unseeded test card | `batman-config-save --seed` is the seed step the test now runs first. |
| N5 saver owner | `batman-config-save --if-healthy` written; called from joinwatch on an OK verdict (integration point noted below). |

## Problem (unchanged)
A/B OS OTA (#89) must preserve config + identity across a rootfs slot switch. p5 (512 MB,
#88) is reserved but unwired; a slot switch boots bare stock (#133).

## Why v3 (what the round-2 review killed)
- **N1 (critical):** a fresh/OTA'd slot has **no dropbear host keys yet** at preinit; the v2
  hook's `[ -e target ] || continue` skipped the bind on exactly that case → dropbear
  regenerated keys → identity changed. The feature was inert on the only case it exists for.
- **N2:** `/etc` overlay may not be writable at the `82` preinit stage (mount_root pivot timing).
- **N3:** `storage-architecture.md` specifies p5 as **LUKS** (Secure tiers); the ext4 hook
  silently no-ops on a LUKS p5.
- **N4:** leaving p5 ro-mounted across preinit→procd is fragile (fstab/block may unmount it).
- Reviewer recommendation (Q2): **copy identity in the first-boot migration, not a live bind.**

## Scope (N3) — decided
v3 targets a **plain-ext4 p5** (Base / interim tier). A **LUKS p5 (Secure tier)** needs an
initramfs `cryptsetup open` stage before rootfs, key release gated on attestation, and the
dm-crypt kernel rebuild (#47/#111) — **out of scope here**. `storage-architecture.md` must gain
a note that the config-survival *mechanism* below is the plain-ext4 path; LUKS is a later
superset. (Action: reconcile the two docs in the implementing PR.)

## Content model (DR-4) — unchanged, two lanes
- **Lane A — identity, verbatim (freeze is correct):** `/etc/dropbear/dropbear_ed25519_host_key`,
  `dropbear_rsa_host_key`, `authorized_keys`; `/etc/openmanet*/config.yml` only if it differs
  from the image default. `openmanetd.*.db` excluded (regenerable).
- **Lane B — uci overrides, merge not freeze:** a versioned uci fragment (hostname, wireless
  mesh_id/key, network.ahwlan reserved ip+proto + batman/bridge, openmanetd dhcpconfigured,
  mesh11sd, ahwlan dhcp/firewall). New-image default wins unless a key is on the list.

## Mechanism — v3 (no preinit hook)
Everything runs in **one first-boot migration**, ordered before services read config.

`/etc/uci-defaults/96-batman-config-migrate` (uci-defaults run in `S10 boot` /
`uci_apply_defaults`, **before** dropbear S19, wpad S20, network — so copying host keys and
applying uci here lands before anything reads them). Runs **once per fresh slot overlay**
(uci-defaults self-delete on success), i.e. exactly after an OTA flash. Steps:
1. **Bypass (N6/F3):** `grep -q batman_bypass=1 /proc/cmdline` → log + exit 0, leaving pure
   image defaults. This is the console-free recovery floor: edit `autoboot.txt` / cmdline on the
   FAT boot partition (no serial needed) to disarm p5.
2. Mount p5 **ro** at its own mountpoint (`/mnt/cfgpart`), fsck-free (ext4 journal replays on a
   rw mount; for ro we validate content, not the fs). Require `/.seeded`; else exit 0 (nothing
   to restore — a first-ever provisioning boot). Unmount + exit 0 on any mount failure.
3. **Validate (F10/V3-7):** `overrides.uci` is a **uci batch** (a list of `set` commands, not a
   `uci export`). `valid_batch` requires every line to be an allow-listed uci verb over an
   allow-listed package with no coarse `delete` and no shell metacharacters; on failure fall back
   to `lkg/overrides.uci`, then to image defaults; record which.
4. **Lane A copy (N1/N2):** copy the identity files into `/etc/dropbear` (create as needed);
   `/etc/openmanet*/config.yml` if present. `/etc` is the writable overlay at this stage. This is
   a copy, not a bind (N4) — nothing stays mounted.
5. **Lane B apply (N7):** run the schema migration map from `overrides.uci`'s `schema_version`
   to the image's current version (explicit per-version transforms; additive-only versions apply
   verbatim under new-default-wins), then `uci import`/batch the (migrated) fragment and `uci
   commit`.
6. **Marker (F8):** write an apply-result line (ok / fell-back-to-lkg / bypassed / failed +
   schema versions + host-key fingerprint) to `/opt/batdata/log/config-migrate.log` (p6, persists)
   so a spurious "healthy" boot with wrong identity is detectable.
7. **Unmount p5.** Return 0 (never loop uci-defaults; failure is recorded, slot runs on safe
   image defaults + fell-back config).

## Save (N5) — `batman-config-save`
Writing p5 is **not** a boot-path or per-commit action (avoids the #104 steady writer).
- **Seed:** one-time at provisioning — write `identity/`, `overrides.uci` (a **uci batch** of
  `set` commands for the per-node delta), `schema_version`, a copy in `lkg/`, then `/.seeded` last.
  The preserve set is small and per-node — the golden image bakes the mesh *structure*; p5 holds
  only hostname, mesh id/key, channel/country, reserved IP, openmanetd flags (all scalars).
- **save-on-healthy:** `batman-config-save --if-healthy` is invoked **by joinwatch (#127) on an
  OK verdict** (joined + neighbours + services): mount p5 rw, atomically (`temp + rename + sync`)
  refresh `overrides.uci` + identity from the running config, rotate `lkg/` to the just-proven
  config, unmount, drop to ro. Once per healthy boot, bounded, owned.

## p5 layout (canonical — N8)
```
/.seeded                      sentinel, written LAST
/schema_version               integer
/identity/dropbear/dropbear_ed25519_host_key
/identity/dropbear/dropbear_rsa_host_key
/identity/dropbear/authorized_keys
/identity/openmanet/config.yml        (only if customised)
/overrides.uci                uci export of the Lane-B preserve-list
/lkg/overrides.uci            last-known-good, rotated on healthy boot
```

## How every finding is resolved
| id | resolution |
|----|------------|
| DR-1 | no format on any boot path; format is seed-only |
| DR-2 | `/.seeded` last; migration no-ops without it |
| DR-3 | test re-scoped: **fresh/wiped overlay** slot; assert SSH fingerprint == seeded keys and dropbear did NOT regenerate |
| DR-4 | two-lane preserve-list |
| F1 | no whole-dir bind; copy + uci merge |
| F2 | real dropbear filenames |
| F3 | LKG + console-free `batman_bypass=1` cmdline floor |
| F4 | reservation in Lane-B uci; config.yml Lane-A; db excluded |
| F5 | single migration in uci-defaults, ordered before services, idempotent, self-deletes per slot |
| F6/N6 | bypass is a cmdline flag (console-free), not console failsafe |
| F7/N4 | migration mounts p5 itself and unmounts; nothing left mounted across boundaries |
| F8 | persisted apply-result marker on p6 |
| F10 | fragment validated into a scratch uci tree before apply |
| N1 | copy creates the keys the fresh slot lacks — the case v2 skipped |
| N2 | runs in uci-defaults where `/etc` is the writable overlay |
| N3 | scoped to plain-ext4; LUKS is a separate superset |
| N5 | `batman-config-save --if-healthy`, joinwatch-owned, atomic, bounded |
| N7 | explicit `from→to` schema transform map, owned in-repo |
| N8 | canonical p5 layout above; seed writes the exact `identity/` prefix |

## Open questions for round-3 review
1. uci-defaults ordering guarantee: is `96` really before dropbear S19 **and** before openmanetd
   on this image? (verify the `boot` S10 → `uci_apply_defaults` timeline on target.)
2. Does copying host keys into the overlay on a fresh slot beat dropbear's first-start keygen
   deterministically, or is there a race if dropbear is socket-activated? (verify.)
3. `batman-config-save --if-healthy` writing p5 rw while the same slot's config is live — any
   torn-read risk for a concurrent reader? (atomic rename should cover it — confirm.)
4. Test rig: the reboot test must use a fresh/wiped overlay on manet01's A/B card (or a spare),
   with the golden card in hand. Acceptable, or wait for a spare card?

## Artifacts (v4)
- `deploy/provisioning/uci-defaults/96-batman-config-migrate` — the first-boot migration.
- `deploy/provisioning/batman-config-save` — seed (`--seed`) + save-on-healthy (`--if-healthy`).
- `deploy/provisioning/uci-defaults/95-batman-storage` — patched to mount p6 on the v2 GPT card.
- `deploy/provisioning/preinit/82_batman_config` **removed** (v3 dropped the preinit hook).
- **Integration point (to wire in the implementing PR):** joinwatch (#127) calls
  `batman-config-save --if-healthy` once on reaching an OK verdict, so the shared config tracks the
  last configuration that actually joined the mesh. depersonalise installs `96`, `batman-config-save`
  (to `/usr/bin`), and seeds p5 with `batman-config-save --seed`.
