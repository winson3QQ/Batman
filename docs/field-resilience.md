# Field resilience — how a node never becomes a mystery brick (#106 / #89 / #88 / #61)

Design note, 2026-09-11. The two field failures we refuse to accept, the layered defence
against them, the industry standards the layers map to, and the decisions this implies for
the storage layout (#106), the OTA flow (#89) and the recovery-image question.

## The two nightmares (requirements, stated as the operator sees them)

**N1 — "It booted in the field and never joined the mesh, and nobody knows why."**
Requirements: (a) the node must *tell* why on the spot (LED + a local diagnosis a laptop on
the M12/Ethernet port can read); (b) it must keep trying without making things worse (no
reboot loops, no radio flapping, no writes); (c) it must remain reachable through a door that
does not depend on the mesh (Ethernet, and the onboarding AP when its key is set); (d) every
attempt must leave a record that survives power loss.

**N2 — "It joined, then dropped for an unknown reason, and afterwards it cannot boot or
boot-loops and never rejoins."**
Requirements: (a) a bad slot must never cost the node — bounded retries, then fall back;
(b) a bad *config* must never cost the node — bounded retries, then reset config and
re-provision; (c) a hang or crash must self-recover (watchdog) *and* leave its last minutes
behind; (d) the sequence "drop → reboot → boot loop" must be reconstructable afterwards from
what the node kept.

## Layered defence (what catches what)

| layer | catches | status |
|---|---|---|
| hardware watchdog (bcm2835-wdt, fed by procd) | pure hang → automatic reset | ✅ stock |
| **boot-reasons + crash/ + ramoops console + flightrec** (#61/#105) | every reboot names its cause; a hang leaves its last console; a panic its backtrace | ✅ v1.1 |
| **zero steady-state SD writes** (#104) + tenants isolated on the data partition (#88) | power-cut corruption of the system partition; a full tenant partition cannot take the OS down | ✅ v1.1 |
| **battery watchdog → graceful shutdown** (#122) | the normal end (battery) stops being an abrupt cut | software ✅, INA226 pending |
| **key guard + Ethernet door** (#103) | a card with the placeholder key never goes on air, but can always be reached | ✅ v1.1 |
| **A/B slots + one-shot tryboot + health-gated commit + retry counter** (#89, layout v2) | a bad OS image → automatic return to the last known good | v3.0 |
| **read-only verity rootfs, config on its own partition** (#74/#88) | OS file corruption or tampering; config survives an image swap | v3.0 |
| **boot-loop detection → config reset → re-provision** (new, #89) | a bad *config* that makes every slot fail health | v3.0 |
| **join watchdog + local join diagnosis** (new, #14/#53) | N1: the node explains "radio up / peers seen / key mismatch / channel / no batman" itself | v1.1 leaf |
| EMS collector, store-and-forward (#65) | history survives the node; fleet-wide view of drops | v4.0 |
| USB-UART serial console (#105 hw) | the hang that dies before it can log | hardware pending |

## Standards and prior art this maps to

| standard / system | what we take from it |
|---|---|
| **NIST SP 800-193** Platform Firmware Resiliency — *Protection / Detection / Recovery* | the three-pillar frame: signed updates only (protection, #73/#74), verify before use (detection: verity, health check), and an *automatic* recovery path to a known-good state that does not need a human (recovery: A/B fallback, config reset). "Recovery" is a first-class requirement, not a nice-to-have. |
| **IETF RFC 9019** (SUIT firmware-update architecture) | a device needs a *recovery strategy* when the new image fails to boot: either multiple images on the device or a recovery image; **rollback attacks must be prevented** (an old-but-valid image must not be re-installable once revoked). We choose *multiple images* (A/B) and add anti-rollback to the OTA manifest (#89/#13). |
| **Android A/B "seamless" updates** | the slot state machine we adopt verbatim: each slot has `successful` and `retry_count` (start at 3); a boot that does not reach "healthy" decrements the counter; at 0 the slot is marked *unbootable* and the bootloader selects the other slot that is `successful`; marking `successful` is an explicit act after the health check, never implicit. Android's *Rescue Party* is the model for our boot-loop → config-reset escalation. |
| **RAUC / barebox bootchooser** (embedded Linux) | the same idea in the Linux-appliance world: boot targets with priority and `remaining_attempts`; `rauc status mark-good` after the health check resets the counter. RAUC also gives signed bundles, slot hooks and a **Raspberry Pi firmware bootloader backend** (Rtone) — the leading candidate for #89 instead of a home-grown updater. |
| **Raspberry Pi bootloader** (`autoboot.txt`, one-shot `tryboot`, `tryboot_a_b`) | the mechanism on Pi 4/CM4: `boot_partition` = default, `reboot "0 tryboot"` boots the `[tryboot]` partition **once** (the flag clears itself), commit = rewrite `boot_partition`. EEPROM support since 2020-10 (tryboot) / 2022-10 (`tryboot_a_b`); GPT + hybrid MBR since 2020-09 (flagged experimental in the notes). Known trap: an EEPROM update file placed on an A/B boot partition together with `autoboot.txt` on the first partition **fails to boot** (rpi-eeprom #499) → EEPROM updates only ever via the first partition, and only deliberately (#89 domain 3). |
| Pi Zero 2 W (no EEPROM bootloader) | only the file-level `tryboot.txt` switch on the single boot partition → A/B of the rootfs and of the kernel files (`os_prefix=`), never of the boot partition itself. Accepted for the relay/expendable role (productization.md). |

## Decisions

1. **Slot policy (Android semantics, RAUC-style marking):** retry_count 3 per slot; health check = `batdata` mounted + radio up + at least one 802.11s plink or (on a lone node) radio beaconing + key services up (FTS where deployed); **mark-good** only after that; a slot is never overwritten by the next update until it has been `successful` for ≥ N boots/days ("last known good" — the hole a plain A/B leaves, see below).
2. **Boot-loop → config reset:** if *both* slots exhaust their retries, the node resets the config partition to the golden defaults (keeping identity where possible) and re-runs first-boot provisioning; that is the "Rescue Party". It is the only path that re-arms the node without a human.
3. **No dedicated recovery image in v3.0.** Beyond what A/B + last-known-good + config-reset already cover, a rescue slot only adds protection for "both slots latent-broken", costs a third image to build/test, and is itself untested code most of the time. The layout **reserves 300 MB** for a mesh+SSH-only rescue slot for high-value unattended Pi 4 nodes; whether to fill it is decided on evidence from #114 (power-pull) and the first OTA cycles. Pi Zero's single boot partition is the one real unrecoverable point — mitigated by never writing it except the few-byte `os_prefix` switch, and by its expendable role. **The practical field rescue is a spare pre-flashed golden card.**
4. **Join watchdog (N1, #127 — `joinwatch`):** users who cannot connect power-cycle the node repeatedly, so the diagnosis is written **early**: at 60 s not joined a SHORT line, at 5 min a FULL line — radio state, mesh mode, channel/country, mesh id, key SET/PLACEHOLDER, keyguard, plinks, stations heard, batman neighbours, mesh11sd, address stage, previous boot reason, plus a one-phrase verdict — to `log/join.log` (survives power loss), and a `JOINED` line closing the episode (also one left open by an earlier boot the user power-cycled out of — otherwise "consecutive unjoined boots" would never reset). Timers run from the first unjoined poll, so a node that drops after hours of service is diagnosed the same way. Nothing is written on a node that joins normally. The node never changes its radio config on its own. Automatic reboot: only after 60 min into the episode, **only when the verdict is something a reboot can fix** — a placeholder key, a disabled radio, or a lone node that hears nobody are not (decision 1's "lone node beaconing = healthy" applies; the first node switched on at a site is not a fault), **never when ≥ 3 consecutive boots did not join** (a human is already power-cycling — adding our own reboot only destroys evidence), and at least 5 boots after the previous automatic one. Known trade-off: "peers seen but no plink" is treated as reboot-helpable (a stuck SAE/plink state is exactly what a reboot fixes), so on a two-node mesh a healthy node whose *only* peer carries a wrong key will also take one reboot after 60 min — bounded by the gap rule, and the peer's own join.log says which side is wrong. **The node has no RTC and no NTP in the field, so none of this uses wall-clock time — boot ids/counts (boot-reasons.log) and uptime deltas only**; timestamps in the logs are decoration. (`iw scan` in mesh mode returns nothing on this driver, so "peers heard" = stations seen by the mesh interface.)
4b. **Field status without hardware (the phone is always there):** the node serves a **verdict-first** page at `http://<node-ip>/` (root landing → this node / whole mesh / LuCI) — a green/amber/red banner + one "what to do" line, engineer detail collapsed — plus `?json` for machines and `/cgi-bin/bundle` (the attachment). `<hostname>.lan` does not resolve; the mDNS name `<hostname>.local` does. This is the minimum a person in the field needs to *report* a node — the two Pi LEDs are not visible through the V3 enclosure until a light pipe / panel LED is added (#128).
4c. **One node shows the whole mesh (#14 L1, decentralised):** `/cgi-bin/mesh` on any node enumerates every node (batman `bat-hosts`), fetches each one's `?json` over mDNS, and renders a per-node health roll-up. No fixed NOC; pure read; a node that can't be reached shows UNKNOWN and never blocks the page — **the control plane never becomes a dependency of the data plane** (management can be entirely down and the mesh still forwards). The health model is four categories — mesh / RF (SNR) / power+thermal / software+boot — each collapsing to CRIT/WARN/OK so a field operator sees "this node is fine / weak signal / not working" instead of a metric dump. (The RF category is what surfaced the noise-floor asymmetry between two bench nodes that plink/batman/ping all reported as "up".)
5. **Evidence is a requirement, not a debug aid:** boot-reasons (every boot), crash/ (panic + console on unclean boots), join.log (N1), shutdown dumps (clean), and — when the hardware arrives — the serial console. All written only at boot/shutdown/failure, never steadily (#104).
6. **Anti-rollback + signed bundles** ride on #73/#13 (cosign now; manifest/TUF-style versioning in the OTA bundle, #89).

## What this changes elsewhere
- **storage-architecture.md** layout v2: bootA/rootA/bootB/rootB/config/data (+ 300 MB reserved rescue), Zero profile, min 16 GB, migration from v1.1 p1/p2/p3.
- **#89:** evaluate RAUC + the Rtone Raspberry Pi backend before writing an updater; slot policy and boot-loop reset are its acceptance criteria; EEPROM updates never via the A/B partitions.
- **#14/#53:** the join diagnosis + LED pattern is the N1 deliverable (new leaf).
- **#114:** the power-pull jig must also exercise the retry/fallback path (cut power during a tryboot boot).

Sources: [NIST SP 800-193](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-193.pdf) · [RFC 9019](https://www.rfc-editor.org/info/rfc9019/) · [Android A/B updates](https://source.android.com/docs/core/ota/ab) · [Android A/B implementation (slot retry)](https://source.android.com/docs/core/ota/ab/ab_implement) · [RAUC integration](https://rauc.readthedocs.io/en/latest/integration.html) · [barebox bootchooser](https://www.barebox.org/doc/latest/user/bootchooser.html) · [Raspberry Pi autoboot.txt / tryboot](https://github.com/raspberrypi/documentation/blob/master/documentation/asciidoc/computers/config_txt/autoboot.adoc) · [rpi-eeprom 2711 release notes](https://github.com/raspberrypi/rpi-eeprom/blob/master/firmware-2711/release-notes.md) · [rpi-eeprom issue #499](https://github.com/raspberrypi/rpi-eeprom/issues/499) · [RAUC Raspberry Pi firmware backend (Rtone)](https://github.com/Rtone/raspberrypi-firmware-rauc-bootloader-backend)
