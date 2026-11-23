# Design set v4/v2 → v5/v3 (608B config v5, phase-1 implementation v3)

Round on v4/v2: Reviewer A (review-v4set-A.md) = 0 / 4 / 13, APPROVE-WITH-CHANGES; Reviewer B (review-v4set-B.md) = 0 / 7 / 9, REJECT.
Author spot-checked before revising: `server.go:357` (deviceID = hex(sn)), `nodecert.rs:118-121`, `main.go:625-640` (boot order, `select {}`), `prov-lock.sh:7` (6 fixed names), `update.go:311-313` (board only), `96-batman-config-migrate:157-163` (`chmod 644 node.cert` in the chain). All as the reviewers said.

| Finding | Handling |
|---|---|
| A-M1 sn = device_id everywhere | `sn` / field 7 / `SN()` stay the device_id bytes in both profiles; chip serial only inside the chip and in the cert extension; app takes the claim serial from the extension; cert subject carries serialNumber = device_id; vector + fake chip with serial ≠ device_id (impl P3, §2.1, §3.1–3.4; config §2) |
| A-M2 S3 rewrite locks owner out; node-side dev-root key | `se-burn cert` only when unclaimed; rotation procedure; node checks structure only, no dev-root key in images; cache refreshed from slot 8 at load (config §2, §5.3; impl §2.3, §7) |
| A-M3 experiments | E6 = PrivWrite on slot 4 before/after; new E17 (slot-4 GenKey, lock, GenKey refused); E9 targets locked slot 4 and unlocked private slot 0; E12 = byte 85, chip 1 only, not in F1; AES moved into E8 with slot-3 control and byte 13 recorded (config §8) |
| A-M4 K13 at the PR 2 / PR 3 boundary | Chip images not put on nodes before PR 3; PR 3 revert exception put to the user (impl P7, §7, Q7) |
| A-m1 daemon GenKey | Public mode only outside burn; driver refuses create (impl §2.2) |
| A-m2 / B-m3 console branch / marker | `/etc/batman-dev-open` required; stated as a deliberate-step marker, not a control |
| A-m3 / B-m2 se-sign ↔ se-burn | `se-burn status`; expected serial on stdin; S3 re-checks a pending record; `se-sign` refuses duplicate slot-1 key / device_id |
| A-m4 post-burn compare | §4 compare rules (88–89 = `F8 FF`, 84–87 blank, counters skipped) |
| A-m6 ChipOptions bit 3 | Set 0 (`0x0000`); E16 reworded |
| A-m7 cert profile | Profile chosen by signature against pinned dev root; CN/serialNumber rule; alg match; CA:FALSE; unknown critical ext rejected; point validation |
| A-m8 field APK has dev-trust | PR 3 wires flavors; `check-field-build.sh` judges the field APK |
| A-m9 / B-M6c downgrade rows | Sysupgrade → freeze / refuse → revert; reflash → software identity; Q3 widened |
| A-m10 overlay writers | Two sequential writers stated; names kept so the chmod chain works |
| A-m11 lstat check | Dropped; EACCES test kept; E0b records the mode |
| A-m12 MAC oracle, directories, 0600 | Record chosen by node list; separate dirs; WSL ext4 |
| A-m13 E2 / E4 controls | Random captured in E2, compared in E4; E2 control = data write after config lock |
| A fact (E14 evidence) | TFLX/TNG slot 0 cited |
| B-M1 boot order / CLI modes | Today's order kept; chip via `Env.Generate`; identSum without chip read; retry only at the load step; CLI modes chip-free |
| B-M2 cache names | Names kept (`sn`, `node.cert`, `backend`) + `chip_sn`; per-unit table in H1 |
| B-M3 chip units in product PRs | New harness PR H1 before PR 2 |
| B-M4 H0 breaks v1.6 | Missing key = file; prov_se CI and dev-root check moved to H1; file-node secret in a per-run 0600 dir; H0 merges after the v1.6 tag; claim-attacker / -chal / replay covered |
| B-M5 validation matrix | §9 matrix; chip image not released in phase 1; hardware and unit cuts put to the user (Q8) |
| B-M6a OTA by board only | `backend` in release info, compared in `update.go`; H1 unit |
| B-M6b converting 02 / 04 | Lifecycle row with procedure and the role-rule exception |
| B-M6d retry writes | `prov-state` written on change only |
| B-M7 rig OS | Raspberry Pi OS Lite on the rig; E0 split into E0a / E0b; F1 on an A/B chip image |
| B-m1 cert validity | 2020-01-01 start; no time check |
| B-m4 wbox chip image | `build-board.sh --wbox`, `lint-wbox.sh` |
| B-m5 P1 rationale | Corrected |
| B-m6 provd-stable latch | Separate flag; post-commit failure out of scope |
| B-m7 provisional formats | Marker; PR 2 CI fails while present |
| B-m8 se-lab layout | `cmd/se-lab`, `cmd/se-sign` in the same module, not packaged |
| B-m9 two-direction gate | One direction (released file images) |
