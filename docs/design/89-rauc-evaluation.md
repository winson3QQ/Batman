# Evaluation: RAUC (+ the Rtone Raspberry Pi backend) as our updater (#89)

Status: **evaluation complete — recommendation below**
Executes the standing instruction in `docs/field-resilience.md:64`: *"evaluate RAUC + the Rtone Raspberry Pi backend **before writing an updater**"*. That instruction had never been executed; it surfaced again in the #209 v2 design review, which pointed out we are now about to hand-write the same slot state machine a third time.
Relates: #89 · #209 · #133 · #211 · #74 / #13 (signing, anti-rollback)

## 0. One-line answer

**RAUC does not supply the thing we are missing.** In every RAUC backend the boot-attempt counting and the automatic fallback live **in the bootloader**, not in RAUC; RAUC's own interface only asks "which slot is primary" and "is this slot good or bad". So on a Pi 3 — which has no bootloader that can count — RAUC leaves the #209 gap exactly where it is. **Recommendation: do not adopt RAUC now; adopt its *interface shape* so that adopting it later is an adapter, not a rewrite.**

## 1. What we checked, and how

| Question | Answer | Evidence |
|---|---|---|
| Which bootloader backends does RAUC support? | barebox (bootchooser), U-Boot, GRUB, EFI, **custom** | RAUC integration docs |
| Where does the attempt counting live? | **In the bootloader, in every case** — barebox `remaining_attempts`, U-Boot `BOOT_<x>_LEFT`, GRUB `<x>_TRY`, EFI = boot-entry order (no counting at all) | 同上 |
| What does the **custom** backend interface consist of? | `get-primary` · `set-primary <slot>` · `get-state <slot>` → `good`/`bad` · `set-state <slot> <state>` · `get-current` (optional). Exit 0 = success | 同上 |
| Does the Rtone Raspberry Pi backend work on a Pi 3? | ❌ **No.** It parses/updates `autoboot.txt` and uses `vcmailbox` to set the one-shot flag — i.e. it **depends on the Pi 4/CM4 EEPROM bootloader's tryboot**. Pi 3 has neither | Rtone repo (LGPL-2.1+, active 2024–2025) |
| Is RAUC packaged for OpenWrt? | ❌ **No** — not in our pinned `packages` feed, and **not in openwrt/packages upstream today either** (searched: 0 hits, `utils/rauc` → 404). We would package and maintain it | local feed search + GitHub API |
| Dependencies? | GLib ≥2.45.8 + OpenSSL mandatory; libcurl/json-glib optional; **D-Bus not mandatory** | RAUC docs |
| Cost of GLib on the civilian tier? | `glib2` **Installed-Size 3,952,640 B ≈ 3.8 MiB** (deps libffi/libattr/libpcre2/zlib mostly already present) against a **134 MiB** bcm2710 image ≈ **+2.8 %** | the built ipk's own control file |
| casync (delta bundles)? | not in our feeds | local feed search |

## 2. The decisive finding

`docs/field-resilience.md:47` calls RAUC + the Rtone backend *"the leading candidate for #89 instead of a home-grown updater."* That framing is **half right and, for the Pi 3, wrong**:

- For **Pi 4** it is right in substance: the Rtone backend does exactly what our `batman-slot` does — read/write `autoboot.txt`, poke `vcmailbox`. It is the same mechanism, in someone else's repo, under LGPL-2.1+.
- For **Pi 3** it does not apply at all. And RAUC cannot fill in for it, because RAUC never counts boot attempts itself — that is the bootloader's job in all five backends. `get-state`/`set-state` is a *record* of a verdict someone else reached, not a retry mechanism.

**Therefore #209's hard problem is untouched by this evaluation.** Whether or not we adopt RAUC, something below Linux on the Pi 3 has to count attempts and fall back — a chainloader (A2), or our own early-userspace counter (A1). RAUC would sit *above* that, not instead of it.

## 3. What RAUC would genuinely buy, honestly

1. **A standard bundle format** with signing, verification and slot/install hooks. We already sign with cosign (#73/#13), so this overlaps rather than adds.
2. **A tested slot state machine** — but see §2: only where a supported bootloader provides the counting.
3. **Delta/incremental updates** via casync — real value on a mesh-only backhaul (~9 Mbps aggregate, half-duplex), but casync is not in our feeds either, so that is a second packaging job.
4. **Less bespoke code to own.** This is the strongest argument, and it is the one the #209 reviewer actually made: we have a Pi 4 mechanism, we are about to write a Pi 3 mechanism, and the health/marking state machine is a third. Three hand-written state machines is a maintenance smell.
5. **A recognised name for the compliance posture** (#93): "RAUC + signed bundles" is easier to evidence than "our own updater".

## 4. What it would cost

1. **Package and maintain `rauc` ourselves** — it is not in OpenWrt upstream (verified), so this is the same class of commitment as the `uboot-bcm27xx` package that the #209 v1 review flagged as a cost against A2. Plus **+3.8 MiB installed** for GLib on the 512 MB civilian tier.
2. **Rewrite a path that is already hardware-validated.** `batman-slot` + `platform-ab.sh` + `batman-autocommit` + the payload manager are proven on hardware (#133 18/18 destructive selftest, #211/#212 auto-commit, 8/8 zero-touch reflashes, #216 flash-and-go). RAUC's install model is not OpenWrt's `sysupgrade` model; our A/B rides *inside* sysupgrade (`platform_check_image`/`platform_do_upgrade`), which is how OpenWrt images are delivered and how our CI produces them.
3. **It still does not solve #209**, so the Pi 3 mechanism gets written either way.

## 5. Decision

**Do not adopt RAUC for #89 now.** The one thing it was nominated for — sparing us from hand-writing an updater — it cannot do for the board that needs it, and adopting it for Pi 4 alone would replace a validated path with a packaging project.

### 5.1 But take three things from it

1. **Adopt the per-slot state semantics properly** — `{successful, retry_count}` per slot, `retry_count` 3, explicit mark-good after the health check, a slot at 0 marked *unbootable*, and never pick a slot that is not `successful`. This is already `field-resilience.md` decision 1 (from Android), it is what RAUC implements, and it is exactly the #209 v2 review's **M3** fix. Our current design carries a single global "unproven" flag, which cannot express "B is bad, A is good" and therefore ping-pongs.
2. **Shape `batman-slot`'s verbs to RAUC's custom-backend interface.** Today: `active` / `target` / `apply` / `commit` / `rollback` / `is-trial`. RAUC's custom backend wants: `get-primary` / `set-primary` / `get-state` / `set-state` / `get-current`. These are near-isomorphic. If the Pi 3 backend is written to that shape (and `commit`/`rollback` become thin wrappers over `set-state`/`set-primary`), then **adopting RAUC later is a ~50-line adapter script, not a rewrite** — and we would gain its bundle/signing/hook layer without touching the mechanism. This costs nothing now and is the main actionable output of this evaluation.
3. **Keep the Rtone backend on file as prior art for the Pi 4 side** (LGPL-2.1+, active). If we ever do adopt RAUC, that is the Pi 4 half, already written.

### 5.2 Revisit when

- casync + rauc both land in OpenWrt upstream (removes the packaging commitment), **or**
- delta updates become necessary because full-image OTA over the mesh is too slow in the field, **or**
- #74's signed-bundle / anti-rollback work grows to the point where we would be re-implementing RAUC's bundle format anyway.

## 6. Correction to an existing document

`docs/field-resilience.md:47` and `:64` present "RAUC + the Rtone Raspberry Pi backend" as the leading candidate for #89 without noting that **the Rtone backend is Pi 4/CM4-only** (it requires the EEPROM tryboot + `autoboot.txt`) and that **RAUC never supplies boot-attempt counting itself**. Both lines should be amended, and `:64`'s instruction marked as executed by this document.

## 參考

- RAUC bootloader-backend documentation (backends, custom-backend interface, dependencies)
- `Rtone/raspberrypi-firmware-rauc-bootloader-backend` (LGPL-2.1+; `autoboot.txt` + `vcmailbox`; Pi 4/CM4 only)
- `docs/field-resilience.md`(decisions 1–6;`:47` `:64` 見 §6)· `docs/design/209-ab-on-pi3.md` · `docs/design/ab-sysupgrade-platform.md` · `docs/design/ab-autocommit.md`
- #89 · #209 · #133 · #211 · #74 · #13 · #93
