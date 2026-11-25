# Review v5-B — targeted check of the §10 amendment (#423)

Reviewer B, independent. Scope: only what `git diff 2978d94 HEAD -- docs/design/security-architecture.md` changes
(§10 classification, O-1 / O-17 wording, V7, §13, §14), the new E11 row in `255-608b-config.md` §8, and anything in
the document they contradict. Read-only; no node touched; no review-*-A.md read.

## Verdict (amendment only)

**APPROVE-WITH-CHANGES — 0 BLOCKER / 1 MAJOR / 6 MINOR.**

The main point of the amendment is right: the trust-model design does not have to wait for the 608B. No class-A row
depends on a 608B experiment, on the RTC, or on #255's implementation being finished (they depend on #255's reviewed
*design*: node id, N2 / N3 public keys, `Identity.ECDH`, the claim proof). O-2 and O-16 are correctly A in that
sense. All fixes below are wording.

## Findings

### MAJOR

**M1. O-4 is not "pure protocol / needs no hardware": it rests on a radio fact nobody has probed. §10 class table,
row A.**
- Threat-model Appendix B4 records it: "dual-password operation of the mesh was assumed and never probed
  [review v1-B M8]", and a forward-then-switch scheme strands the far cluster. Whether the HaLow mesh (Morse driver,
  wpa_supplicant) can hold two SAE passwords during a change, and what a multi-hop mesh does while nodes switch one
  by one, decides which delivery designs are possible at all.
- The hardware is the nodes already on the bench (no 608B needed), so the user's question is still answered "yes,
  start now". But a design written as class A would again be built on the unprobed assumption — the same mistake
  that was rejected in v1 of the key-authority document, and against the project rule that a new surface gets its
  reality check before the design.
- Smallest fix: split class A into "A: no hardware" and "A′: design now, but a probe on the existing nodes is needed
  before that part can be accepted (touches nodes → after v1.6, like V7)". Put O-4 in A′ (SAE password change on a
  multi-hop mesh; two passwords at once). O-16 belongs there too for its measurement (old V5: peer-table rebuild and
  interruption).

### MINOR

1. **§13 says the start conditions are "已改"; #52 still says the opposite.** `gh issue view 52` today: "開始條件：
   #255 完成（608B 在 bench 上通了）；#423 的地基文件已合併". §13's row claims "開始條件是本文件合併（不是 #255 完成）
   … 已改 … 同日稍後依 §10 的分類再改一次". Until the tickets are edited the cell must read "待改（使用者確認後）";
   the same for the §10 sentence "#75 與各單的開始條件已照這樣改".
2. **"A 類的 15 題照樣是那一份聯合設計的一部分" contradicts the paragraph above it**, which gives O-16 to the
   #16 / #383 joint design. It is 14 rows in #52's design plus O-16 elsewhere. O-16 still depends on #52's first item
   (its stated direction is "the member list carries each node's N2 public key"), so say that #16's design starts
   after the field / ordering part of #52's design is reviewed.
3. **O-3 is in class B for the wrong reason, and "only 1 of 23" is not exact.** The bench answer to "can the claim
   secret be changed" is already fixed by the reviewed configuration, not by an experiment: slot 5 is written before
   the data lock and "之後永不可改" (`255-608b-config.md` §3); E8 / E13 / E17 only confirm that it cannot be read,
   derived or locked. What O-3 actually waits for is whether the *production* chip allows rotation (#426, class C);
   its protocol part (recovery after a lost phone) is class A. Also class E (O-15) is defined as "spans B and C", so
   by the table's own definition two rows touch 608B facts, not one. Suggested wording: "no row needs a new 608B
   experiment to start; O-3 and O-15 use 608B facts that are already fixed by the configuration and need #426 for
   the production answer".
4. **O-1 / O-17 wording is honest; E11 needs four additions.** Marking the counter limit as an inference is correct
   (that was my own caveat: about 85 %, not measured). For E11 as written:
   - it is missing from the order line (`255-608b-config.md:190`); place it after E6 (config and data both locked =
     the product state), from a fresh wake with no Nonce / GenDig / CheckMac before it;
   - "確認沒有任何指令能把它降回去" cannot be shown by a test; replace by the two concrete attempts: a Write to
     config bytes 52–67 after the lock (must fail) and UpdateExtra in decrement mode (`608b-facts.md` §7, 608
     behaviour "NOT FOUND") — record what each does;
   - say why Counter[0] and Counter Match are left out: no slot is LimitedUse and byte 18 is `0x00` in this
     configuration (`255-608b-config.md:75`), so Counter[0] behaves like Counter[1]; read it, do not increment it;
   - say that "may jump by more than one on power loss" stays datasheet-only (not testable in a controlled way).
   Note for the reader: E11 settles the trap record and any bench use of the counter (U9 count on the bench chip);
   it does not settle O-1 / O-17, which are class C because the production chip is not a 608B.
5. **Baseline note (V7 / K15).** Right that the baseline must exist before the trust-model implementation starts,
   that measuring touches nodes and so waits for v1.6, and that writing the design does not. Two corrections:
   K15 does not say "on v1.6" — it says "measured before the v2.5 implementation starts"; choosing v1.6 is the
   stricter choice (no chip latency) and should be written as a choice. And V7 says "8 台" while the bench has two
   nodes (fact 12): say what is measured with the nodes on hand and that the 8-node figure needs more hardware or is
   an extrapolation.
6. **Class A rows that also need a decision or a platform fact (for completeness; none blocks starting).**
   Open user decisions the design must ask early: Q2 (O-12, O-2), Q3 (O-6, O-22), Q4 (O-9, O-13), Q6 — who does the
   ICS side, still "❓" (O-9, O-10). O-14: who may authorise is class A; what a root shell can leave behind depends
   on the platform state (read-only rootfs #41, S-C) — class D for that half. O-13 is in D for "how long"; its other
   half ("what a field credential may do") is A, and the first design item (object fields) should state "no time
   field; trusted time, if it ever exists, arrives as a new object version" so D does not hold up the field list.

## Checks asked for

| Check | Result |
|---|---|
| 1. Classification row by row | O-2, O-5 … O-12, O-20, O-21, O-22: A holds. O-4: not A as defined (M1). O-16: A′ and a different design (M1, MINOR 2). O-14, O-13: split (MINOR 6). O-3: reason wrong (MINOR 3). O-1, O-17, O-23 (C), O-18, O-19 (D), O-15 (E): hold |
| O-2 specifically | Uses `Identity.ECDH` (slot 2, plain output) — same primitive the shipped secret pack already needs; its chip fact is E10, which #255 needs anyway. No extra 608B dependency. Its K11 half depends on how revocation is represented (O-1's protocol part, designable now; only O-1's storage is class C) |
| O-16 specifically | Uses one more fixed signing purpose on slot 0 — same primitive as the session proof (E14 / E17). No extra chip fact; needs the node measurement (old V5) |
| 2. "Only one needs a 608B fact" | Not exact; see MINOR 3. The practical conclusion (do not wait for the 608B) holds |
| 3. O-1 / O-17 + E11 | Honest; E11 correct in substance, four additions (MINOR 4) |
| 4. Baseline note | Right, with two corrections (MINOR 5) |
| 5. Contradictions with what I approved | §13 "已改" vs the real ticket (MINOR 1); "15 rows in one design" vs O-16 (MINOR 2). §14 row is consistent. "One joint design, not 23" is kept |

Citations opened: `255-608b-config.md:75, 190, 213`; `255-reviews/608b-facts.md` §7; `255-threat-model.md`
Appendix B4; `255-key-authority.md` §3 K15, §7; issue #52 (start-conditions block).
