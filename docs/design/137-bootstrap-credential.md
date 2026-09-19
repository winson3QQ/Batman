# Design: close the bootstrap-credential window (#137)

**Status:** IMPLEMENTED (v4 spec + 4 reviews FLAWED×3 → SOUND-WITH-CAVEATS, caveats applied) — the p5-seed lockdown mechanism is coded (folded into `96` per Decision C, both trees) + logic-tested; **live bench-flash validation + prod key-only remain hard-gated on #105 serial**. · **SoT:** #75 · **Parent:** #74 · **Label:** dev-now
**Refs:** #88/#89 (p5 config partition — the channel) · `deploy/provisioning/{batman-config-save, uci-defaults/96-batman-config-migrate}` · #13 (PKI) · #54 (enrolment) · #110 (dev-prod switch) · #105 (serial, hw-gated) · #111/#47 (LUKS p5) · #74/#115 (secure boot)

## 1. The hole (reality-checked, manet01, 2026-09-19) — TWO parallel unauthenticated-root paths
```
network:  /etc/shadow root=EMPTY  +  dropbear PasswordAuth=on RootPasswordAuth=on enable=1 :22  +  authorized_keys: none
serial:   ttyAMA0/ttyUSB0 askfirst -> /usr/libexec/login.sh ; system.ttylogin UNSET -> `login -f root` = PASSWORDLESS root shell
          (a set/locked root password does NOTHING on serial until ttylogin=1)
```
A fielded/demo/RMA card, or network reach, yields root with no auth — on *either* path. Doc redaction (#136) doesn't change the artifact.

## 2. The channel — p5 seed (verified), and the honest provisioning model
The prior "flash-time injection" idea was wrong: `scripts/flash-card.sh` writes the read-only squashfs and **zeroes the overlay** (where shadow / dropbear / authorized_keys live), then instructs the operator to *boot and SSH in to plant the key* — through this very hole.

**The channel that exists = p5 (`#88/#89`), VERIFIED in the code:**
- `batman-config-save --seed` captures identity to p5, including **`authorized_keys`** (batman-config-save L63) and host keys; plus `overrides.uci` (per-node scalars: hostname, mesh id/key, channel/country, reserved IP, openmanetd flags).
- `96-batman-config-migrate` restores host keys + **`authorized_keys`** from a `.seeded` p5 **before dropbear (S19)** (96 L78-85, `.seeded` gate L76), then applies `overrides.uci` for its allow-listed packages.

**Honest provisioning model (review F5):** `batman-config-save` runs **on the node** (reads live `/etc/dropbear`, `/etc/shadow`, `uci`). You cannot seed an inert card at the flash station — you **boot the fresh card (through the open bootstrap window), plant the operator key + set the per-node password, run `--seed`, then reboot** — and only on that reboot does the lockdown arm. So **provisioning boot #1 is open by construction**; #137's guarantee is "**provision on a trusted bench**, then the node ships locked." This is a residual window, not offline injection — state it plainly.

## 3. Decision A — what gets sealed onto p5 (per-node, no shared baked secret)
Seed writes, per card: the operator's **public** SSH key → `authorized_keys`; a **per-node root password hash** → `identity/shadow-root` (NEW capture, §6); and the existing per-node `overrides.uci` scalars. The SSH **private** key stays on the provisioning station. **Key-custody honesty:** if one operator key is seeded fleet-wide, that key's station is a fleet-SSH single point — "no shared secret" then means no secret *baked into the image*, not the operator credential. Per-node distinct keys avoid it at N-key management cost; per-operator now, per-node cert under #13 later.

## 4. Decision B — serial: `ttylogin=1` + per-node password; never `*`-lock
`login.sh` = `[ ttylogin=1 ] || exec /bin/login -f root`. Prod must set **`system.ttylogin=1`** (→ `/bin/login` → consults shadow) AND a **per-node non-empty root password** (NOT `*`-locked — `*` makes `/bin/login` reject on serial too = brick, R1's original finding). Then serial requires the per-node password and stays recoverable.

## 5. Decision C — the lock is emitted LOCALLY, gated on what was actually restored (not via overrides.uci); persisted in uci, re-derived on each fresh overlay
The dropbear/ttylogin lockdown **cannot** ride `overrides.uci`: `batman-config-save` never captures those keys (its PRESERVE list is per-node scalars only), and `96`'s `ALLOWED_PKGS` excludes `dropbear` with **whole-file fail-closed** validation, so a dropbear line would **discard the entire restore**. And static `overrides.uci` lines apply *unconditionally* → they'd lock a node whose key restore silently failed → **brick** (F1). So the lock is emitted **locally** (a local `uci set`, not p5-sourced → no `ALLOWED_PKGS` concern; a hostile/corrupt p5 can't push dropbear settings).

**Where:** at the **tail of `96` itself**, after Lane A (identity/shadow restore) + Lane B (overrides) — so it reads the just-restored `/etc/dropbear/authorized_keys` and `/etc/shadow` with no cross-hook marker hand-off. (A separate hook is possible but **must NOT be named `97-*` — `97-batman-landing` already ships**; it would have to sort after `96` and after the identity restore it depends on, e.g. `96z-batman-lockdown`. Folding into `96` avoids the collision and the marker plumbing.)

**Logic (creds-derived):**
1. `[ -s /etc/dropbear/authorized_keys ]` (Lane A restored a non-empty key), **AND**
2. root's `/etc/shadow` field is a **valid non-empty, non-locked hash** (`^\$[1568y]\$…`),
3. → `uci set dropbear.@dropbear[0].PasswordAuth='off' RootPasswordAuth='off'; uci set system.@system[0].ttylogin='1'; uci commit`; write `lock-status=LOCKED` (persistent marker on p6).
4. **Else → do NOT lock.** Leave open/recoverable; write `lock-status=UNPROVISIONED`.

**Lifecycle (corrected per review — the prior "re-derived each boot" was wrong):** OpenWrt `uci-defaults` run **once per fresh overlay** (first flash / factory-reset), in filename order within `S10boot`, **then self-delete** — NOT every boot (the repo's own `97-batman-landing` and `96` both rely on this; `96` `exit 1`s to stay armed, `exit 0`s to self-delete). So:
- The lock **persists via the committed uci config** (`dropbear.PasswordAuth=off` lives in the overlay `/etc/config`), so it holds across normal reboots even though the hook is gone. "dropbear at S19 picks up the lock this boot / no one-boot open window" is true **on the provisioning reboot and post-factory-reset boots** (when the hook runs); on normal reboots it is vacuously true (the lock is already persisted).
- **Factory-reset / overlay-wipe fail-safe:** a wipe resets uci to image defaults (`PasswordAuth=on` = open) **and** re-exposes `96` → it re-runs on the fresh overlay: p5 creds still present → re-restore + re-lock; creds gone → no key/shadow → stays open + `UNPROVISIONED`. So it never re-locks into a keyless brick — **because overlay-wipe both reopens uci and restores the hook, not because the hook fires every boot.**
- **Honest residual (see §8 F8):** if the restored creds are lost **without** a full overlay wipe (e.g. `authorized_keys` deleted/corrupted while `/etc/config/dropbear` survives), the persisted uci lock stays `PasswordAuth=off` with no key and the hook is gone → not auto-reopened. Recoverable only by serial password or SD-reflash, not a true brick.

## 6. Decision D — per-node root password via p5, boot-safe (F2)
`96`/`batman-config-save` don't touch `/etc/shadow` today. Add:
- **Capture:** `batman-config-save --seed` copies root's `/etc/shadow` line hash into `identity/shadow-root`.
- **Restore (in `96` Lane A, or `97` pre-lock):** **validate first** (`^\$[1568y]\$`, non-empty, non-`*`/`!`); **surgically replace only root's line** in `/etc/shadow` (in-place edit, NOT `cp -a` of the whole file — that would clobber image system accounts like dnsmasq/nobody); on any validation failure, **skip shadow AND skip the lock** (stay recoverable). Never write an empty or locked root line while arming.
Base-tier (plain-ext4 p5): the seeded key/hash sit in **cleartext on p5**, readable on SD-pull — consistent with §7; a LUKS p5 is #47/#111.

## 7. Honest limit (matches threat-model.md)
Closes **remote/network unauthenticated root** and **casual-handler (non-disassembly) access** — today's real, high-frequency exposure. Does NOT resist **SD-pull**: no LUKS (#111) → p5 key/hash/mesh material read in cleartext; no secure boot/dm-verity (#74/#115) → attacker rewrites the card (re-add authorized_keys / re-enable password-auth / drop a bypass marker) → **reverses the closure**. Also does not close **provisioning boot #1** (§2, bench-only). Necessary-not-sufficient; sequence before/with #111/#74.

## 8. Failure modes
- **F1 keyless brick** — RESOLVED by Decision C (lock derived from key-present + valid-shadow each boot; never from static p5 lines). `--seed` also refuses when `authorized_keys` is empty.
- **F2 bad-shadow brick / hole-reopen** — RESOLVED by Decision D (hash validation; surgical root-line edit; skip-shadow-and-lock on failure; never empty/locked while arming).
- **F3 serial recovery unproven** — **HARD PRECONDITION:** prod key-only (`PasswordAuth=off`) MUST NOT ship until serial-shadow break-glass is **bench-validated on the image** (#105 hw-gated); interim recovery = documented pull-SD-and-reflash.
- **F4 provisioning-boot-#1 open** — accepted, bench-only (§2); the process control is "provision on a trusted bench; never field an un-seeded card."
- **F5 DEV_OPEN marker attacker-settable** — precedent: `96` honors `batman_bypass=1` from the FAT `autoboot.txt` (SD-writable). So DEV_OPEN must be **build-time baked provenance**, not a runtime/FAT/overlay file; do not claim a droppable marker as a control.
- **F6 UNPROVISIONED is detective, not preventive** — the `lock-status` marker surfaced by halow-status only helps via the #14 console; the real control is the provisioning/build gate (F4). Defense-in-depth signal, not posture.
- **F7 SD-pull reverses** — §7; #111/#74. Includes: a hostile p5 can seed an **attacker-known** root password hash (it passes the `root:$…$` validation and is installed verbatim → serial root) and could craft a shadow-root value with awk `-v` backslash escapes; both require write access to p5 (= physical/SD access), so they fall under the §7 SD-pull boundary (plain-ext4 p5; LUKS is #47/#111). The lockdown's uci/dropbear settings are still local-only (never p5-sourced), so this is limited to the shadow line.
- **F8 creds lost without an overlay wipe** — if `authorized_keys` is deleted/corrupted while the committed `dropbear.PasswordAuth=off` survives (no full overlay wipe → the `96` hook is not re-exposed), the node is network-keyless-locked and does not auto-reopen. Not a true brick (serial per-node password + SD-reflash recover), but the honest limit of "persist the lock in uci": it reopens only on a full factory-reset, not on partial credential loss.

## 9. Definition of Done — and the HONEST build scope (review F3)
**Build set (not "one new capability") — and it must land in BOTH the `deploy/provisioning/...` and the image-built `feed/batman-provision/files/...` trees, which already diverge today (the two `96` copies differ — reconcile them as part of this):**
1. `batman-config-save` (both copies): capture root shadow hash → `identity/shadow-root`; refuse `--seed` if `authorized_keys` empty.
2. `96-batman-config-migrate` (both copies): restore shadow root line with validation + surgical in-place edit (F2); then the creds-gated local lock at its tail (Decision C — folded into `96`, or a `96z-batman-lockdown`; **NOT `97-*`, which collides with the shipping `97-batman-landing`**); write the `lock-status` marker (LOCKED / UNPROVISIONED) on p6.
3. `halow-status` (the shipping feed copy): read `lock-status` → surface `UNPROVISIONED — NOT SECURE` (F6).
4. DEV_OPEN as **build-time** provenance (F5), not a runtime/FAT marker.
5. The image ships the **feed** tree — verify every edit is in `feed/...`, not only `deploy/...`.

**Now-deliverable DoD (bench-verified on manet01):** a **bench-seeded** card → no empty-root network login, network key-only works, serial requires the per-node password (`ttylogin=1`); an **un-seeded** card → recoverable + `UNPROVISIONED` (NOT silently key-locked); a **factory-reset** of a seeded card whose p5 still holds creds → re-restores and re-locks; whose creds are gone → stays recoverable, not bricked.
**Hard precondition before prod key-only ships:** serial break-glass **bench-validated** (#105).
**Deferred (M2):** runtime re-enrolment/rotation over an authenticated channel (#54/#13); LUKS p5 (#47/#111); the full #110 selector; verify the S10-before-S19 restore ordering on target (`p5-config-partition.md` open-q #1 — currently unverified).

## 10. Review disposition (three rounds, 2026-09-19)
- **R1 [BLOCKING] `*`-lock ↔ serial brick** → Decision B. RESOLVED (login.sh mechanism verified).
- **R1 [BLOCKING] DoD on unbuilt #54/#13** → two-tier DoD; p5 removes the runtime-enrolment dependency.
- **R2 [CRITICAL] flash-time injection doesn't exist** → p5 seed (verified). Fixed.
- **R2 [HIGH] self-lock bricks on factory reset** → Decision C: derive-each-boot, no persisted flag.
- **R3 [CRITICAL/F1] lock via static overrides.uci bricks; ALLOWED_PKGS/PRESERVE reject dropbear** → Decision C: `97` emits the lock **locally**, creds-gated (not via p5 overrides.uci). Fixed.
- **R3 [CRITICAL/F2] shadow restore not boot-safe** → Decision D: validate + surgical + skip-and-stay-recoverable.
- **R3 [HIGH/F3] scope undercount** → §9 honest build set incl the feed/ copy.
- **R3 [MED/F4-F6] UNPROVISIONED detective / bench-boot-#1 open / DEV_OPEN droppable** → §7/§8 reframed; process gate is the real control.
- **R4 [HIGH] "re-derived each boot / no persisted flag" false** (uci-defaults are one-shot self-deleting) → §5 corrected: lock persists in committed uci; factory-reset re-derives via overlay-wipe restoring the hook; F8 adds the partial-cred-loss residual. **RESOLVED (mechanism was already correct; wording fixed).**
- **R4 [HIGH] hook name `97-batman-lockdown` collides with shipping `97-batman-landing`** → §5/§9: fold into `96` tail (or `96z-*`), never `97-*`. RESOLVED.
- **R4 verdict SOUND-WITH-CAVEATS:** mechanism correct (lock lands before dropbear, creds-gated, no secret brick); shadow surgical edit + partial-success gating confirmed sound; §7 honesty confirmed accurate.

## 11. Scope boundary
#137 = *a bench-seeded prod node ships no unauthenticated network or serial root and no shared baked secret, recoverably.* NOT the runtime enrolment tool (#54), the #110 selector, PKI issuance (#13), LUKS p5 (#47/#111), physical-capture resistance (#74/#111/#115), or provisioning-boot-#1. An un-seeded card is explicitly UNPROVISIONED. Dev (baked opt-out) is untouched.
