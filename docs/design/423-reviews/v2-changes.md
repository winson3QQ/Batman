# #423 security architecture: v2 reviews -> v3

Round 2: Reviewer A (review-v2-A.md) APPROVE-WITH-CHANGES 0 / 7 / 11; Reviewer B (review-v2-B.md)
APPROVE-WITH-CHANGES 0 / 3 / 10. Both round-1 BLOCKERs are closed; B found nothing fixed in v2.0 that the trust
model would force to be redone.

User decisions after round 2 (2026-11-25):
- an AUTOMATIC config reset keeps the owner record (the node stays the owner's); resale = an owner-ordered factory
  reset;
- the revocation and rekey-delivery parts of #13 move to v2.5 (#95, #52); #13 can close in v2.0 and `2.0.0` does
  not wait for the trust model.

| Finding | Handling in v3 |
|---|---|
| A-M1 / B-M1 §6 rules 5, 6 do not match the helper; lock-out after convert + fall-back; key change under the same `v`; two version fields | §6 rewritten as conditions for a later design, not a designed verb. Condition 4: conversion only when the other slot also reads the new record (with the reason from `node.go:796-797`). F1: any key-set change bumps `v` in `prov.cbor` and `prov.meta`. F2: strict formats get a new version or content type, never a new key (A-m5) |
| A-M2 / B-m3 §8 reset table: contradicts #402 and field-resilience; "p5 damaged" merged with "card swapped"; resources and performer missing; unauthenticated transition | Row 1 is now a user decision; rows 3 and 4 are split and row 3 keeps the shipped behaviour (repair from the overlay copy when provable, else frozen and locked); ownership table adds the overlay copy, p6 prov-state, root password / lock, `batman-config-save`, `96-batman-config-migrate`; resets are performed by the helper; the trigger of row 1 must not be reachable from radio peers or non-root code; rows 1 and 2 are named as new transitions owned by #402 and #255; §13 lists #402 and field-resilience |
| A-M3 / B-m1 shipped protections missing from §5 | I-7 to I-12 added (owned node cannot be re-claimed, claim.replay needs both halves, signer must be an owner in the p5 record, unknown verdict freezes and nothing overwrites a newer record, claimed node stays locked, the placeholder-key guard); release root read from the image only is in §2 |
| A-M4 "shipped" over-claims; legacy nodes stranded | I-5 says development app only; §7 says the on-the-spot proof is #255 PR 3; legacy nodes keep working until enrolled; the placeholder-key guard is recorded as already shipped (I-12) |
| A-M5 / B-M3 #13 waits for open problems; not put to the user | User decided: those two parts move to v2.5. §7, §10 (O-1 -> #95, O-4 -> #52), §12, §13, §14 updated |
| A-M6 / B-M2 claims stronger than source: K20, K12, K14, K10, A2 / P4, I-6 | §15 rewritten: 5 rules met, 8 partly with the gap written, 11 wait. A2 says what `owner_enc_pub` is used for today and that the root password crosses provd in clear; P4 reworded; I-6 limited to the app path; §8 lists four fail-opens with reasons |
| A-M7 layout: no slot-independent pre-unlock area | §8: slot state is in `autoboot.txt` on the first FAT partition today; v2.0 cards are bench cards and may be reflashed; production is CM4 eMMC with the #413 layout; a config reset does not reformat p5 (B's condition) |
| A-m1 / B-m2 citations (I-1, I-7, I-8) | Corrected |
| A-m3 phone keys without user authentication or attestation | O-7 trap added ("decide before the first enrolment outside the team") |
| A-m4 claim secret kept at the factory | O-3 trap added (K22, #256) |
| A-m6 / B-m6 leftovers in docs/threat-model.md | Fixed in this commit |
| B-m4 mixed old/new nodes in one network | O-20 |
| B-m5 missing §10 rows | O-21 audit record, O-22 roster and root-backup custody, O-23 zeroize; O-19 adds workload identity |
| B-m7 N3 never rotates | Rule P5 |
| B-m8 "not added to a production network" is an app-side check | §2 and §9 reworded |
| B-m9 missing negative controls | §16 tests 8–15 |
| B-m10 ROM / bootloader wording | §2 T5 |
| A-m7 … A-m12, B remaining minors | Wording fixed where the text still exists; the rest refer to text removed in v3 |
