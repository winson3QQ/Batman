# Design set v5/v3 → v6/v4 (608B config v6, phase-1 implementation v4)

Round on v5/v3: Reviewer A (review-v5set-A.md) = 0 / 3 / 16, APPROVE-WITH-CHANGES; Reviewer B (review-v5set-B.md) = 1 / 7 / 15, REJECT. Both: E4 APPROVE-WITH-CHANGES; PR D APPROVE-WITH-CHANGES; B: H0 APPROVE-WITH-CHANGES.
Author spot-checked: `replayflow.rs:204`, `approve.rs:520-526`, `node.go:438-455`, `batman-config-save:429-437`, `release.go:262-264`. All as the reviewers said. No config byte changes.

| Finding | Handling |
|---|---|
| B-B1 PR order impossible | P7 reworded: the PR 2 chip image runs on the bench chip node for helper-level units only (harness talks to helper.sock); E0b / F1 / E14 before the PR 2 merge (impl P7, §9) |
| B-M1 cert rewrite freezes | `se-burn cert` only while no identity cache exists; cert change = reflash; rewrite branch removed (config §5.2–5.3; impl §2.3, §7) |
| B-M2 shell changes unplanned | P3 rationale corrected; shell row in §2.8 (PR 2); CI tests and wbox patches in H1 |
| B-M3 per-unit table | chain1, prov-bench-s0, fresh rows corrected; H1 finalises after reading each unit |
| B-M4 H0 claim contract | Secret fetched after each identity generation by scp into a per-user temp dir, trap-deleted; three SIGN loops get a MAC branch; serial from the host record; run-log check; negative control = claim.secret moved aside (impl §4.1) |
| B-M5 v2 data in a product PR | New harness PR H2 before PR 3; H0 has no v2 code (impl §4.3) |
| B-M6 Q8 deferred | Q8 + rig model are preconditions of H1; matrix states nodes and the per-release row per option |
| B-M7 OTA backend field | Dropped; every wrong-backend OTA reverts in the trial (impl §2.8) |
| A-M1 sn / ecdh_pub readers | `Verified.claim_sn` used by claimflow and replayflow; `approve::import` takes ecdh_pub from verify_offline; PR 3 greps and lists every reader; vectors for replay and import (impl §3.2, §3.4) |
| A-M2 chip ECDH failure swallowed | psks.get errors instead of omitting; openSecrets retryable; Finish transient; H1 case (impl §2.4) |
| A-M3 compare rule | Exact rule (config §4); fake chip and tests use it |
| A-m1 E10 key | E10 GenKeys slots 1, 2 first, after E9 |
| A-m2 order | Full order rule (config §8.1) |
| A-m3 E17 sign | Product-style passthrough Nonce + Sign 0x80 |
| A-m4 4-byte writes | E6 pass condition and fallback |
| A-m5 ChipOptions citation | AN3539 default; bit 3 behaviour known by name only |
| A-m6 / B-m5 begin re-run | Reuse pending secret, never overwrite (config §5.1); PR 2 test |
| A-m7 / B-m2 retry writes | Rerun boot.Run with back-off 10 s → 5 min; result replaces; prov-state change-only |
| A-m8 DACPub, PurposePeer | DACPub = slot 1; Peer refused on chip |
| A-m9 provd profile | `info.cert` key 3 = backend |
| A-m10 Cert() bytes | Trimmed to DER length; non-zero padding = not burned |
| A-m11 high-s | Node rejects; app id/prove verifier requires low-s (PR 3); ⚠️ RustCrypto behaviour confirmed by vector |
| A-m12 preflight | Compare the effective value (missing = file) with the node list |
| A-m13 temp dir | Per-user temp dir + trap (H0) |
| A-m14 per-flavor wiring | Dropped; keep startup cross-check; host-build check in H2 |
| A-m15 E8 stop scope | Stop only for MAC rows |
| A-m16 text | C1–C9 in key-authority; QR file location; 65-byte pub with 04 |
| B-m1 --boot | Generate refuses outside the daemon |
| B-m3 trial failure only on use | Stated; H1 case sends a chip request after the fault |
| B-m4 foreign backend on rc 7 / 9 | identSum "present, foreign" → backend-mismatch before the rc switch; tests rc 0 and rc 7 |
| B-m6 "unclaimed" | Replaced by "no identity cache" |
| B-m7 container ENOENT | Accepted |
| B-m8 power cut / variant recompute | Config §8.1, §4 |
| B-m9 dev-root check timing | H2 / PR 3 |
| B-m10 red steps, PR D timing, tags | Stated (impl §2.8, §9) |
| B-m11 BATMAN_VERSION | Same as the file image from the same commit |
| B-m12 fault seam | `se-fail=<N>` via seam.Arm in prov_test builds |
| B-m13 E15 fallback | Changed to "back to design" |
| B-m14 sn format | 18 hex + newline |
| B-m15 matrix vs Q8 | Per-release row per option |
