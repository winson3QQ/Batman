# Design set v6/v4 → v7/v5 (608B config v7, phase-1 implementation v5)

Round on v6/v4: Reviewer A (review-v6set-A.md) = 0 / 2 / 15; Reviewer B (review-v6set-B.md) = 0 / 4 / 16. Both APPROVE-WITH-CHANGES for E4, PR D, H0 (B) and the set as a whole.
Author spot-checked: `node.go:570-576` (CheckMac → EForbidden), `node.go:620-636` (replay failure counter), `prov-bench-s0-254.sh:335-352` (fourth SIGN loop), `scripts/node/prov-p2-254.sh` (log line). No config byte changes.

| Finding | Handling |
|---|---|
| A-M1 / B-M1 cert does not fit 416 B | Profile trimmed (no subject serialNumber, no BasicConstraints, short issuer CN, short OID); CI asserts the worst-case size ≤ 416 in PR D; fallback slot 8 + 9 decided at PR D with a config revision (impl §3.1) |
| A-M2 CheckMac bool swallows chip errors | `CheckMac` → `(bool, error)` in PR 2; claimVerify and claim.replay map chip errors to a retryable code, not counted; H1 case with mutant (impl §2.1, §4.2) |
| B-M2 PR 2 chip-node scope | Units needing provd / app marked "cannot run on the PR 2 chip node"; PSK case restated at helper level; stated as a temporary PR 2 → PR 3 gap, not a cut (impl §4.2) |
| B-M3 fourth SIGN loop, hang, node list | Four loops listed; CI lint SIGN ⇒ MAC; 30 s provclient timeout = FAIL; node list keyed by node name; sn fetched with the secret (impl §4.1) |
| B-M4 per-unit table | prov-chain0 made discriminating; prov-p1 mode asserts; prov-wbox bind allow-list; prov-p2 log line (impl §4.2) |
| B fact: dtparam location | I2C row in §2.8 (shared distroconfig.txt; ⚠️ firmware repo not checked) |
| A: decryptSecrets callers | Listed incl. netRoot and finishWantsRadio (impl §2.4) |
| A / B: foreign backend only in chip build | identSum shared by both builds; backend-mismatch = no retry, no socket (impl §2.3) |
| A: se-burn cert checks p5 too | Config §5.2 |
| A: CRC independent recompute proves nothing | Image recompute kept; CRC left to se-burn, chip refuses a wrong CRC (config §4) |
| A: S3 resume driver | `se-sign resume` (config §5.1) |
| A: compare rule 84–85, 0–15 | 84–85 not compared; revision and serial checked (config §4) |
| A / B: lifecycle rows | Generate power cut (temp dir + rename), first persist power cut, `sysupgrade -n`, p5 unreadable (impl §7) |
| A: supply-chain actor | Impl §8 |
| A: text | §8.0 gate; E12 read-back; E10 fallback chip; E0b wake check |
| B: one glitch in trial reverts | Retry the sequence once before withdrawing provd-stable (impl §2.4) |
| B: copyDir loads keystore | CLI modes read cache files only (impl §2.3) |
| B: one mutant per H1 case; dv-sbx prov_se build | Impl §4.2, §2.8 |
| B: Q8 HAT / HaLow assignment | Added to Q8 |
| A: PR-level details (p5 writes in retry, psks.get polling rate, ECDH peer point check) | Left to PR 2 code review and tests, as the reviewer marked them |
