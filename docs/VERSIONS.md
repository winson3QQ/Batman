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

## Policy — MAJOR maps to the #75 milestone that has been REACHED

`MAJOR` tracks the #75 milestone **whose gate has actually been met/shipped** — it is conservative, not aspirational:

| MAJOR | #75 milestone | meaning |
| --- | --- | --- |
| 1.x | v1.1 DEV golden | adopt the prebuilt OpenMANET image + our files/packages; self-forming, observable; **no self-build** |
| 2.x | v2.0 Build gate | **we build the image ourselves** (own OpenMANET build, both boards, CI-reproduced) |
| 3.x | v3.0 PROD | verified boot, immutable rootfs, OTA domains, lockable |
| 4.x | v4.0 Fleet | fleet EMS |

- **+1 to MAJOR only when that milestone's full #75 gate checklist is met** and cut via CI — not when work on it merely starts. E.g. `2.0.0` waits for #108 (CI reproduce build, both boards) + #109 (kernel-config) + #110 + #113 (HIL) + the #73 gates.
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
| 2.0.0 | *(reserved)* v2.0 Build-gate reached | — | — |

Refs #75 (SoT), #160 (provenance), #73 (dev-infra).

## Retention (what goes to Batman-P)

Not every build is promoted. WSL `bin/targets/` holds every build (transient, overwritten). A build is **promoted** to a Batman-P pre-release only when it is **validated** (on-node / `ab-selftest`) and worth keeping/flashing. Keep **one current good build per version line**; prune superseded ones (e.g. `batman-ab-docker-v2` was retired when `batman-1.3.0-wsl` landed). Each promoted release carries the full-card `.img.gz`, the OTA `ab-payload` tar, and the `<image>.manifest.txt`.
