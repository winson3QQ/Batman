# Batman image versioning

How image version numbers are assigned and how they map to the SoT roadmap (#75).
See also #160 (image provenance), `usr/bin/batman-version`, `/etc/batman-build`.

## Version string

```
batman <MAJOR>.<MINOR>.<PATCH>-<channel>.<build>+<feed7>.fw<fw7>
example: 1.3.0-wsl.1+b93040f.fw1f997e7
```

- **MAJOR.MINOR.PATCH** — see policy below.
- **channel** — `wsl` (hand-built on the dev box, not audited) · `ci` (built by CI, auditable) · `rel` (a shipped release). Dev builds always carry `-wsl.N`/`-ci.N`; a shipped `MAJOR.MINOR.PATCH` drops the suffix.
- **build** — the Nth build within that channel/version.
- **+<feed7>.fw<fw7>** — SemVer build metadata: the two source commits an image is built from — `feed7` = winson3QQ/**Batman** short SHA (our packages/feed), `fw<fw7>` = winson3QQ/**firmware** short SHA (the OpenMANET build tree fork: kernel patch, board config, `.config`, feed pins). Both are needed to reproduce; the version alone traces back to git.

Stamped at build time into `/etc/batman-build` (KEY=VALUE); a node self-reports with `batman-version`, and it is appended to the login banner.

### Version comparison (#254 P3)

A node updated through the app compares its running `BATMAN_VERSION` with the signed release's version (S key 1) by
this rule (`docs/design/254-p3-impl.md` §3.7.1; code `feed/batman-prov/src/release/release.go` `ParseVersion` /
`Compare` / `Decide`):

- Grammar `REL[-CH.N][+meta]`:
  `^([0-9]+)\.([0-9]+)\.([0-9]+)(-(wsl|ci|rel)\.([0-9]+))?(\+[0-9A-Za-z.-]+)?$`.
  - REL = `X.Y.Z`; CH is `wsl` / `ci` / `rel`; N is counted per channel.
  - `+meta` (including `.dirty`, `.bench`, `.wbox-*`) is ignored.
  - The shipped form without a suffix is accepted.
  - A version that does not parse → reason 11.

| running → new | result |
| --- | --- |
| REL differs | compare REL numerically: higher = upgrade; lower = downgrade, allowed only when S key 6 lists the running version (without `+meta`) |
| same REL, same CH | compare N: higher = upgrade; equal = reinstall (allowed); lower = downgrade (as above) |
| same REL, one side has no suffix | the shipped form is newer than any `-CH.N`; shipped → dev only when key 6 lists the running version |
| same REL, different CH | no order (N is per channel): allowed only when key 6 lists the running version |

- A refused downgrade or channel change → reason 6.
- `min_from` (S key 7) is compared by the same rule. When the running version is older than it, or has no order with it, the node refuses with reason 4 (fail-closed).
- Limit: `+meta` is ignored, so a wbox build equals the clean build of the same number. A wbox build is never committed, so installing one only runs a trial and then reverts.

### One tree, every board (#209 S5, 2026-10-02)

- Since 1.5.0, every board (`ekh-bcm2711` Pi 4, `ekh-bcm2710` Pi 3A+) is built from the **same firmware-fork commit** (`build-3aplus`). One version number = one pair of source commits, whatever the board.
- 2026-11-17: the Pi 3A+ variant is excluded from the product; only the `ekh-bcm2711` image is released. The tree still builds `ekh-bcm2710` until that is removed separately.
- The board is a separate field: `BATMAN_BOARD` in the stamp, and the board name in every artifact file name.
- `/etc/batman-build` is **generated at build time** by the firmware fork's `scripts/stamp-batman-build.sh`, never hand-edited.
  - The script reads the real `feeds/batman` HEAD and asserts it equals the feeds.conf pin.
  - It writes the firmware HEAD, and sets `BATMAN_DIRTY=1` when the tree has local changes.
  - `scripts/build-board.sh` checks the stamp inside the built rootfs.
  - A dirty build is never a release.
- 1.4.14's hand-written stamp named the wrong commits (`6763ed8`/`c19763a`; the build was really feed `8685c5a` + firmware `397e313`). That is the reason the stamp is generated now.
- See `docs/boards-and-builds.md`.

## Policy — MAJOR maps to the #75 milestone that has been REACHED

`MAJOR` tracks the #75 milestone **whose gate has actually been met/shipped** — it is conservative, not aspirational:

| MAJOR | #75 milestone | meaning |
| --- | --- | --- |
| 1.x | v1.1 DEV golden *(closed 2026-11-17)*; v1.6 階段 1 穩定版 | the 1.x line; started as the prebuilt OpenMANET image + our files, self-built since 1.3; 1.6 = App provisioning (#254) on the software identity |
| 2.x | v2.0 硬體信任鏈 — 608B、簽章、驗證開機、加密、RTC(Pi 4 + WM1302) | **the hardware trust chain on the Pi 4**: 608B (#255) and mesh admission by its identity (#13), signing pipeline without OTP (#405), verified boot / immutable rootfs (#74, #41), LUKS (#111), RTC (#174), plus the CI-reproduced build (#108, #113, #73) |
| 3.x | v3.0 新 HAT 組裝驗證 + 第一個對外版本 | first release handed to others: HAT v2 assembled and verified (#419, #256), enclosure, factory flow, compliance |
| 4.x | v4.0 全隊管理與進階安全 | fleet management, fleet OTA, advanced security, TAK/ICS interop |

Milestones were regrouped again on 2026-11-25 (`docs/roadmap.md` § Roadmap v5). **The milestones v2.1–v2.5 are not image versions**: v2.1 (OpenVLM), v2.2 (hardware validation on jumpers / eval boards), v2.3 (CM4 + IO board) and v2.4 (HAT v2 design freeze) are hardware-validation and design gates that ship no image of their own; v2.5 (the hardware-independent software line, started after #255) ships as ordinary 2.x MINOR releases. So a `2.N.0` image number does **not** mean the `v2.N` milestone was reached — only MAJOR is tied to a milestone.

Earlier names: on 2026-11-17 (§ Roadmap v4) the milestones were `v2.0 內部試用 — 自編映像(Pi 4)+ 階段 1/2` and `v3.0 第一個對外版本 — 新 HAT、外殼、PTT、可鎖`; before that `v2.0 Build gate — own image, both boards`, `v3.0 PROD — trusted, OTA, lockable` and `v4.0 Fleet & HW security`. The Pi 3A+ variant was excluded on 2026-11-17.

- **+1 to MAJOR only when that milestone's full #75 gate checklist is met** and cut via CI — not when work on it merely starts. E.g. `2.0.0` waits for the security architecture (#423), the 608B (#255, #196), mesh admission (#13), the signing pipeline (#405), verified boot / immutable rootfs (#74, #41), LUKS (#111), #108 (CI reproduce build, Pi 4) + #109 + #110 + #113 (HIL) + the #73 gates, and the rest of the v2.0 milestone.
- **MINOR** — a significant capability added within the current MAJOR line. **PATCH** — fixes/rebuilds.
- A build's **target** milestone (what it is working toward) is recorded in `/etc/batman-build`'s `BATMAN_MILESTONE` field, so aspiration is captured without claiming the number early. Example: `1.3.0` carries `targets v2.0 Build-gate` because docker-in-image (#159) is build-gated, but the v2.0 gate is not yet met, so it stays on the 1.x line.

## Number ↔ release-tag map (legacy option A)

Existing GitHub release tags were named ad-hoc (by content/date) and do **not** match the milestone-aligned numbers. Rather than re-tag shipped releases (which would break existing links), the old tags are kept as **legacy** and mapped here; **new releases use the aligned number.**

| Aligned version | Content | Legacy GitHub tag | Base |
| --- | --- | --- | --- |
| 1.0.0 | HaLow mesh node (flash-and-go) | `v1.0.0` | OpenMANET 1.7.0 |
| 1.1.0 | Self-provisioning golden (single-slot) | `v2.0.0` *(mis-numbered; is DEV-golden, not the Build gate)* | OpenMANET 1.8.0 |
| 1.2.0 | A/B dual-image OTA payload | `v1.1.0-ab-ota` (pre-release) | OpenMANET 1.8.0 |
| 1.3.0 | **docker-in-image A/B card (#159)** | *(WSL dev; stored in Batman-P release `batman-1.3.0-wsl`, Batman-P#1)* | OpenMANET 1.8.0 |
| 1.4.14 | flash-and-go rework (#216), Pi 4 only | *(WSL dev, Batman-P)* — stamp names wrong commits, real = feed `8685c5a` fw `397e313` | OpenMANET 1.8.0 |
| 1.5.0 | **Pi 3A+ A/B (#209) + one tree for both boards**; Pi 4 gets the #209 shared A/B hardening + gpu-fw 1.20250915 | *(in validation, S5)* | OpenMANET 1.8.0 |
| 1.5.11 | OTS EUD gateway (#289) + one validation set (#290) + guardian/A-B/provisioning fixes; validated on Pi 4 only | [`v1.5.11`](https://github.com/winson3QQ/Batman/releases/tag/v1.5.11) | OpenMANET 1.8.0 |
| 2.0.0 | *(reserved)* v2.0 硬體信任鏈 milestone reached | — | — |

Refs #75 (SoT), #160 (provenance), #73 (dev-infra).

## Retention (what goes to Batman-P)

Not every build is promoted. WSL `bin/targets/` holds every build (transient, overwritten). A build is **promoted** to a Batman-P pre-release only when it is **validated** (on-node / `ab-selftest`) and worth keeping/flashing. Keep **one current good build per version line**; prune superseded ones (e.g. `batman-ab-docker-v2` was retired when `batman-1.3.0-wsl` landed). Each promoted release carries the full-card `.img.gz`, the OTA `ab-payload` tar, and the `<image>.manifest.txt`.

## RC builds and the shipped number (2026-10-08, #274)

- **A version number only goes up.** A fix (or a batch of fixes) that ships bumps PATCH. Its validation builds
  are rc's of THAT number: `<next PATCH>-wsl.N` from the issue's branch (a local firmware branch pinning the
  unmerged Batman commit). After merge, the firmware pin-bump PR builds the shipped image as the next `-wsl.N`
  of the same number (the feed SHA changes on squash-merge, so it is a rebuild; its content is the last
  validated rc plus test/CI-only commits).
- **Never ship a number lower than an rc already built.** 1.5.5-wsl.1..5 were rc's of #275/#263 that shipped as
  1.5.4-wsl.2 — the shipped number was lower than its own rc's. Those five rc numbers are retired: never flash
  or ship them. #274's rc's are 1.5.5-wsl.6.. and it ships as the next 1.5.5-wsl.N.
- **No rebuild when nothing in the image changed (#305, 2026-10-25).** 1.5.13-wsl.1 (#305) ships as built: the firmware
  merge (firmware#23 `081e7be1`) has a 0-line diff to the rc's commit `1524084e`, and the feed pin `0328e83` was
  already a main commit with 0 files changed under `feed/` up to main `a98a82c` (the merges after it were
  harness/docs only). The rc IS the shipped artifact, validated by the full suite (107 PASS / 0 FAIL).
  1.5.12-wsl.16 and 1.5.12-wsl.17 were local #305 spikes (kernel patch drafts on wsl.15): retired numbers, never ship them.
