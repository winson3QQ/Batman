# 608B configuration v2 → v3

Round 2 on v2: Reviewer A (review-608b-v2-A.md) = REJECT 1 / 3 / 15; Reviewer B (review-608b-v2-B.md) = REJECT 0 / 8 / 16. Both decoded every value and found none wrong; no configuration byte changes in v3.
User decision between rounds (2026-11-23): the production secure element is not the blank 608B → v3 is scoped to the bench chips; production questions moved out (§10).

| Finding | Handling in v3 |
|---|---|
| A-B1 K16 gate misses other TempKey writers; assumption unstated | Assumption stated in §2; E7 extended with SHA / KDF / ECDH / SHA-HMAC overwrite, 64-byte nonce, message-digest-buffer mode, GenDig in KeyConfig and shared-nonce zones, GenKey 0x10 on slots 0–2, each with a positive control on slot 4; failing E7 means K16 is unachievable by configuration |
| A-M1 phase-1 items missing | §9 items 1–13: peers/challenge → slot 0; per-login proof and "app sends nothing before verifying"; labels for slot-0 signatures; endorsements made at boot, in memory (decided); net_secrets checks the slot-2 endorsement; backend marker |
| A-M2 variant image unwritten; chip count | §8.1 variant image written (slots 3, 4, 6); chip count confirmed by the user: 10 on hand; mounting stated (user solders on U3 + C6 / C7) |
| A-M3 missing tests / controls | E6 adds plain writes to slot 5 and unused slots with a control; E9, E12, E13 controls; E10 encrypted ECDH must be refused; E14 positive external sign on slot 0 |
| A MINORs | per-chip CRC (§4 header); byte 17 stated; OTP zeros so the data CRC is computable; full 36 bytes written; "at most N" (§6); C4 exception stated; ReqRandom purpose stated (§2); rate-limit sentence removed; experiment-chip list replaced by "dev root signs only when read-back equals the image" (§5 step 6); dev root vs 219 v0.7 and K20 vs file backend addressed (§5, §9-5) |
| B-M1 wrong part for production | Scope = bench chips only (header, §10) |
| B-M2 no chip–board binding | Moved to the production-part decision (§10); the unsupported "secure boot covers it" sentence removed |
| B-M3 lifetime-QR cost incomplete | Moved to §10 with the missing half (lost label) |
| B-M4 factory station undefined; second program on the chip | Bench burning is a helper mode (§5, C9); production factory in §10 |
| B-M5 endorsement origin ambiguous | Decided: helper makes them at boot, keeps them in memory (§2) |
| B-M6 per-login chip signature still in §2 | Kept deliberately (C3) and now stated with protocol item §9-3 and cost §9-13 |
| B-M7 trial-commit hole; no test column | §7: chip failure during a trial = trial failure; test column added |
| B-M8 K20 vs dev file backend; missing bring-up work | Chip-identity marker rule (§9-5); boot reconciliation (§9-6); record bound to node id (§9-7); harness (§9-10); driver choice (§9-11) |
| B options with no use | Experiment-chip list removed; OTP version/batch removed (zeros); chip serial not in the QR |
