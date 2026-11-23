# 608B configuration v3 → v4

Round 3 on v3: Reviewer A (review-608b-v3.md) = 0 / 7 / 16; Reviewer B (review-608b-v3-B.md) = 0 / 7 / 12. Both: E4 on the variant chip APPROVE-WITH-CHANGES, final image REJECT.
Phase-1 implementation v1 reviews (review-phase1-A.md, review-phase1-B.md) also raised items against this document; they are mapped here too.
Configuration bytes: unchanged, except ChipMode bit 1, left open in v3, is now fixed at 0.

| Finding | Handling in v4 |
|---|---|
| A-M1 / B-M6 variant lacks controls | §8.1 roles restated (slot 4 = pre-lock PrivWrite control); §8.2 has a control column; structural negatives (AES, DeriveKey target, CheckMac copy) marked "documentation only" and removed from the experiment list; E13 "lock before keygen" removed (the burn never locks before GenKey); E9 control failure = inconclusive, stated; order rule kept; no new bytes |
| A-M2 K16 assumption wrong, ReqRandom rationale false, SourceFlag | Endorsements removed (A-M4), so K16 no longer rests on TempKey flags; ReqRandom rationale withdrawn (§4 note) |
| A-M3 E7 incomplete | E7 moved to §10 (production-part study) |
| A-M4 endorsements have no bench use | Taken: dev-root cert binds slot 1 (subject), slot 0, slot 2, chip serial (§2); C2 restated |
| A-M5 / B-M5 auto fallback to file identity | Removed: build-time backend (phase-1 impl P2/P3); se identity stub on overlay + p5 replaces the p6 marker |
| A-M6 ownership / contracts / lifecycle | §7 resources incl. bus, volatile state, 84/85, image, record, label, lab tool; contracts table; system lifecycle in phase-1 impl §7; trial owner corrected there (helper writes provd-stable) |
| A-M7 / B-M1 claim secret | Host-generated, recorded before sent (stdin), kept as bench exception; harness answers MAC on host (§5.1, §5.4) |
| B-M2 burn contract | §5.1 (CLI mode, chip lock, trial refusal, dev-root round trip by files), §5.2 resumable state table, §5.4 custody |
| B-M3 slot 8 locked with undesigned cert | Slot 8 not slot-locked on the bench (§5.3); cert profile frozen in phase-1 impl §3.1 |
| B-M4 trial mechanism | phase-1 impl §2.4 |
| B-M7 rig / feasibility | §6: dedicated experiment rig (not 02/04), chip budget, E14 on a Pi 4; manual tests listed in phase-1 impl §4.2 |
| A-m1 ChipMode bit 1 | Fixed at 0 (§4) |
| A-m2 / B-m3 scrap unnecessary | S2 regenerates unlocked key slots (§5.2) |
| A-m3 downgrade mechanism | se identity stub (phase-1 impl P3, §7) |
| A-m4 trial retry / definition | phase-1 impl §2.3–2.4 |
| A-m5 / B-m1 E12 | Control = UpdateExtra succeeds; pass = address unchanged after power cycle; run by se-lab |
| A-m6 E10 IO key | Fallback stated in E10 |
| A-m7 cert size | Computed on the dev machine in PR D; fallback if > 416 B (E15) |
| A-m8 / B-m5 counter | Moved to §10; U9 wording flagged for the user there |
| A-m9 / B-m12 lab tool vs C9 | C8 scoped to identity-bearing nodes; §8.0 lab rules |
| A-m10 chip 2 fate | F1 list exact; chip 2 becomes a bench chip |
| A-m11 budget | §6 |
| A-m12 provd oracle | §2 |
| A-m13 ClientChal binds cert | phase-1 impl §3.3 |
| A-m14 message layout | N/A (no internal-sign verifier) |
| A-m15 / B-m8 zero slots | §3 note |
| A-m16 earlier minors | dead chip → "no answer" state (§5.2, phase-1 §2.3); proof type = cert issuer (phase-1 §3.2); node_cert to strangers unchanged (phase 2); batpower refuses 0x60 in code (phase-1 §2.7) |
| B-m2 shipped verifier | N/A (E7 moved out) |
| B-m4 auto-void on mismatch | Freeze, as today (phase-1 §2.3) |
| B-m6 ownership | §7 |
| B-m7 kernel-bound i2c clients | E0 |
| B-m9 K20 scope | Put to the user (phase-1 §10 Q3) |
| B-m10 meaning of dev-root cert | §2 |
| B-m11 EEPROM wear | Login path uses pass-through Nonce only; driver has no random Nonce (phase-1 §2.2); E14 confirms |
| New (author) | Data-lock CRC skips private-key slots (F§1.3), so S1's CRC is computable from known contents; CheckMac after the lock confirms slot 5 |
