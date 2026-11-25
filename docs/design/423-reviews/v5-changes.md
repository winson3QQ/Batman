# #423 security architecture: the §10 amendment (v4 → v5) and its targeted review

The user asked (2026-11-25) whether the parts of the trust model that do NOT need the 608B should be marked as
such. v4's §10 said, as one blanket statement, that the trust model is designed "after the 608B works on the
bench". Problem by problem that is wrong, so §10 now classifies all 23.

Targeted check, not a new round: Reviewer A (review-v5-A.md) APPROVE-WITH-CHANGES 0 / 0 / 7; Reviewer B
(review-v5-B.md) APPROVE-WITH-CHANGES 0 / 1 / 6. Both confirmed the core: no "A" row depends on a chip fact, on
the RTC, or on #255's implementation — only on #255's already reviewed design (node id, the N2 / N3 public keys,
`Identity.ECDH`, the claim proof). Every finding was a wording or scoping fix.

| Finding | Handling |
|---|---|
| B-M1 (and A-m5) O-4 is not "no hardware": two SAE passwords side by side on the HaLow mesh was never probed (threat model appendix B4), and it decides which delivery designs are possible at all | New class **A′**: design now, but probe or measure on the existing nodes before that part is approved (bench nodes, no 608B; touches nodes, so after v1.6). O-4 and O-16's measurement are A′. New row V9 in §11 |
| A-m2 line 4 still said the trust model waits for the 608B (U6) | Rewritten to point at §10's classification |
| A-m1 / B-m1 §13 said the tickets were already changed; they are not | §13 now says **待改**, waiting for the user to confirm the classification |
| A-m3 / B-m3 "only 1 of 23 needs a 608B fact" disagrees with the table | Reworded: no problem waits for a *newly scheduled* 608B experiment, and class B was dropped — O-3's bench answer is already fixed by the reviewed slot-5 configuration, which #255's own E8 / E13 / E17 only confirm |
| A-m4 / B-m3 O-3 is not a pure B row | Split: the recovery protocol is A; "may the claim secret be replaceable on the production chip, does the factory keep it" is C (#426, #256) |
| A-m6 / B-m6 O-13's D pointer would not answer it — the RTC is settable by whoever holds the node | Split: scope is A; duration is a residual risk. The field table of the authorisation object states now that there is no time field and that trusted time, if it ever arrives, comes as a new object version |
| B-m2 "the 15 A rows are part of the one joint design" contradicted handing O-16 to #16 / #383 | Now: the others sit in #52; O-16 is in the #16 / #383 joint design and waits for #52's fields and ordering |
| A-m6 / B-m6 O-9 / O-10 / O-22 depend on the ICS side (Q6 still unanswered) | §10 lists Q2, Q3, Q4, Q6 as questions to put to the user early in the design (they do not block starting) |
| A-m7 / B-m5 the baseline: K15 says "before the v2.5 implementation", not v1.6; V7 says 8 nodes but the bench has two, and the rekey flow exists only in the development app | §10 states v1.6 as *our choice* and the stricter one, and that what the two bench nodes can measure must be written down with the rest marked as extrapolation; 8 nodes is a purchase decision for the user |
| A-m7 / B-m4 E11 gaps | Config doc v7.1: E11 is in the order line (after E8, before E17); "nothing can lower it" is replaced by two concrete attempts (write config bytes 52–67 after the lock; UpdateExtra's decrement mode, NOT FOUND for the 608); why Counter[0] and Counter Match are untouched; the power-loss jump stays a datasheet statement E11 does not test; and E11 settles only the bench use and the trap record, not O-1 / O-17 |
| A-m7 the reviewed v7 config doc gained a row with no version entry | v7.1 row added |
| A suggestion: say what K6 can claim if no certified chip offers that storage | Added to the "cannot close" paragraph |
| B-m6 O-14's "what a root shell leaves behind" depends on the platform state | That half is listed under D |

Not contradicted, per both reviewers: "one joint design hosted by #52, not 23"; the §13 / §14 changes; writing the
class-C storage as an interface contract marked ⚠️.

Still unverified after this amendment, as the document says: V3, V4 (CM4), V7 and the new V9 (both measured on the
existing nodes after v1.6), and E11's own outcome.
