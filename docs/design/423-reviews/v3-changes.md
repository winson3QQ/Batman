# #423 security architecture: v3 reviews -> v4, and the MINOR register

Round 3: Reviewer A (review-v3-A.md) APPROVE-WITH-CHANGES 0 / 1 / 10; Reviewer B (review-v3-B.md)
APPROVE-WITH-CHANGES 0 / 1 / 12. All round-2 MAJORs closed except A's §6 item (below). B's rework check: nothing
v2.0 fixes (chip configuration, certificate, QR, record format, partition layout, boot signing key, provisioning
steps, the factory-reset verb, the automatic-reset behaviour) has to be redone for the trust model or the CM4.

## MAJOR

| Finding | Handling in v4 |
|---|---|
| A-M1 F1 lets a v2.0 ticket write a record the other slot cannot read; condition 4 is checked only at conversion time | §6: v2.0 tickets do not change the key set (checked: #255 and the two reset actions need no new key); if one must, conditions 2–4 and 7 apply to the first write. New condition 7: once the record has the new version the helper refuses to install an image that cannot read it. Two negative controls added |
| B-M1 "automatic reset cannot be triggered by a radio peer" cannot be met with #402's trigger list; consequence not stated | §8: the requirement is now checkable (no peer or non-root code can REQUEST a reset; failures a peer can cause — abnormal boots, health items that need neighbours — do not count towards level 4); the rest is written as a residual risk (a temporary disturbance can become a lasting off-network state until the owner's phone arrives); §13 has a row to change #402's trigger list; test 9 rewritten |

## MINOR register (from round 3 on, MINORs do not force another full round)

| # | Finding | Status |
|---|---|---|
| A-m1 / B-m1 | fail-open row "legacy nodes are enrolled without the claim proof" is wrong (`node.go:571-576`) | Fixed: row removed; I-7 says legacy nodes need the proof too |
| A-m2 | fail-open row 3 narrower than the source | Fixed |
| A-m3 / B-m6 | "performed by the helper": which channel | Fixed: helper binary incl. boot-time mode, root-only channel, reuse the shipped leave transaction |
| A-m4 | other slot's overlay keeps the old wireless settings after an automatic reset | Fixed: requirement and test 9 |
| A-m5 | I-7 "limit on attempts" exists only for claim.replay | Fixed |
| A-m6 | negative test 7 contradicts the legacy rule | Fixed |
| A-m7 / B-m8 / B-m9 | stale #13 cells (V7, "member leaves") | Fixed |
| A-m8 | two writers listed for p6 prov-state and for the lock | Fixed: the separating rule is cited |
| A-m9 / B-m11 | K4 should name the overlay exception and the S-A/S-B card-image rollback | Fixed |
| A-m10 / B-m5 | factory reset: what it cannot erase; p6 tenant data and TAK keys | Fixed in row 2; the p6 decision is left to #255's design |
| B-m2 | row 3 holds only while the record exists; both missing = row 4 | Fixed |
| B-m3 | a version bump is itself a format change | Fixed with A-M1 |
| B-m4 | the helper has no way today to know what the other slot can read | Fixed: stated; a one-line file in the image, added by the ticket that implements conversion |
| B-m7 | K14 list missing: dev-open marker, rc 7 creates unclaimed | Fixed (two rows). "BLE health only warns" — OPEN: not checked against source in this round; goes to #13's regression work |
| B-m10 | reflashing bench cards needs the user's consent (deployed-role rule) | Fixed: stated in §8 |
| B-m12 | `release.go:161` off by one | Fixed (162) |
