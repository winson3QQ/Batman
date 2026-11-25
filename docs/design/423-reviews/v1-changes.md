# #423 security architecture: v1 reviews -> v2

Round 1: Reviewer A (review-v1-A.md) REJECT 2 / 11 / 12; Reviewer B (review-v1-B.md) REJECT 2 / 10 / 11.
Neither disagreed with a baseline decision; the source citations they opened held.

User decision after round 1 (2026-11-25): narrow the scope. #423 fixes only the foundation (what would have to be
redone later if left open now); the trust model (the 15 problems of `255-key-authority.md` §5) stays as problems
with traps and is designed after the 608B works on the bench (U6).

| Finding | Handling in v2 |
|---|---|
| A-B1 / B-B2 revocation floor in a 608B counter; "+1 only"; no reset-proof region; list missing = empty | Mechanism removed. Recorded as open problem O-1 with these traps; O-17 hands the "only an authorised host can advance" storage question to #426 as an evaluation item |
| A-B2 / B-B1 / B-M1 per-signer sequences; a stored object can perform a join; replay after reset or card swap | Mechanism removed. The shipped rules are kept and named as invariants: I-1 (a join needs the owner's signature made in the session, also after reset / card swap) and I-2 (only the next version, chained by hash). Negative tests 2 and 3 |
| B-M3 / A-M2 admin set with majority; two sources for "who is admin" | Removed. O-12 records why it failed |
| A-M1 / B-M5 issuer can issue the maintenance role; A5 signer inconsistent | Removed; O-14 |
| A-M3 / B-M9 nodes asked to verify other nodes without a root key; WireGuard "count" | Removed. §2 states nodes do not verify certificates today; O-16 records the direction (member list carries N2 public keys; bind to the network version) |
| A-M4 / B-M4 / B-M7 / A-M11 §5-2, §5-4, §5-9 … handed to tickets that ask #423 for them | Not designed (scope). §10 lists each as open with the ticket it blocks; §14 says what each ticket has now and what it still waits for; §13 lists the start conditions to change |
| A-M5 / B-M7 / B-M10 change-over from the shipped owner model; strict parsing after a fall-back | New §6 (seven rules, four negative tests) |
| A-M6 field-credential bound without a clock | O-13 |
| A-M7 / B-M8 S-C claims stronger than the platform; version floor is install-time only; boot key cannot be revoked | §1 rule P2; O-18; V3, V4; Q-F for the user |
| A-M8 / B-M10 "co-anchor" undefined | Removed; O-3 |
| A-M9 maintenance entry | O-14 |
| A-M10 no way to take back one role | Not designed; O-12 / #52 |
| B-M2 split network "nodes accept neither" | Removed; §9 says v2.0 is unchanged; O-5 |
| B-M4 no encryption key for people | §3.2 A2 and rule P4 (the shipped `owner_enc_pub`) |
| B-M6 generation = unit-wide re-issue | Removed with the generation; O-1 |
| B-M10 automatic reset clears the anchor | §8 reset table: an automatic reset keeps the owner record; only an owner-ordered factory reset clears it |
| B-M10 missing lifecycle rows | §9 adds: upgrade from v1.6, S-B -> S-C, CM4 or HAT replaced, mixed dev/production, wpa_supplicant / hostapd / OTS restart, chip not answering; platform column |
| A-m1 / B-m1 "this is BLE" is reported by provd | §8 contract row |
| A-m2 threat-model.md not changed in the branch | Changed in this commit |
| A-m3 / B-m2 more than one fail-open | List-missing is gone with the list; slot state is the one fail-open and is stated with its reason |
| A-m11 "put it on p1" | Removed ("somewhere else"; decided with #426) |
| A-m12 version floor mechanism | §3.2 M2 names `release-min-serial` and that it is checked at install time |
| B-m3 protections without a negative control | §16 list rewritten for what v2 claims; nothing is claimed for the removed mechanisms |
| B-m4 unit id contradiction | Gone with the outer header (not designed) |
| B-m5 log kept across units | Not designed; K24 / K25 listed as waiting for the trust model |
| B-m6 family TAK CA key on p5 | §3.1 N8 |
| B-m7 decisions made in passing | Q-D removed (technical; now O-17); Q2–Q6 stay with `255-key-authority.md` §7; Q-F added |
| B-m8 root shell leaves things behind | O-14 |
| B-m9 leaked old anchor | O-6 |
| B-m10 single-phone family recovery | O-3 |
| B-m11 new N2 signing purposes | §4.3: not defined here; each is added to the list in its own change |
| §12 claimed K-rules as met | §15 states the real status: met in v2.0 / partly / waits for the trust model |
