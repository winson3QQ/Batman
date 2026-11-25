# Review v5-A: amendment to §10 of the #423 security architecture (commits 0ab2dfe, c0590b2; HEAD 34b9131)

Reviewer A, targeted check of the amendment only (diff `2978d94..HEAD` of `security-architecture.md`,
current §10, §11 V7, §13, §14, and the new E11 row in `255-608b-config.md` §8). Read-only; nothing run on
any node or chip. Issue texts were read with `gh issue view` at the time of this note.

## Verdict

**APPROVE-WITH-CHANGES** for the amendment — 0 BLOCKER / 0 MAJOR / 7 MINOR.

The main point of the amendment is right: most of the open problems are protocol and policy and do not
wait for the 608B, and none of the fifteen "A" rows depends on a chip fact. I found no row whose "A" would
send someone to design against a missing *chip* fact. What needs correcting is narrower: three rows are
classified more simply than they are, the "one of 23" count disagrees with the document's own table, two
"A" rows need measurements on today's nodes before they can be closed, and two status cells say something
is done that is not.

## Findings

1. **§13 says the tickets are already changed; they are not.** §13 row "#75 and #52 … start conditions":
   "已改 (… 同日稍後依 §10 的分類再改一次)" with "not #255 完成". At the time of this check #52's
   start-conditions block and #75 line 145 still read "開始條件：#255 完成（608B 在 bench 上通了）", and #75
   line 32 still says the trust model waits for the 608B. Fix: status = "pending the user's confirmation",
   until the edit is made. (The same applies to "#423 itself … 已改 (同上)" if that edit is also pending.)

2. **The top of the document still says the opposite.** Line 4 ("不定什麼"): "…列在 §10，等 608B 在 bench
   上通了再邊驗證邊設計（使用者決定 U6 的順序）". §10 now calls that statement wrong. U6 itself
   (`255-key-authority.md:21`, "v1.6 → 608B → trust model") is a recorded user decision; the amendment
   changes how it is read. Fix: change line 4 to match §10, and add one line next to U6 in
   `255-key-authority.md` recording the 2026-11-25 refinement, so the two documents do not disagree.

3. **"Only 1 of the 23 needs a 608B fact" does not match the table.** By the document's own classes, O-3
   (B) and O-15 (E = B and C) both wait for 608B experiments, and O-1 / O-17 now point at E11 for the
   measured fact. Fix the sentence to what is true and still makes the point: "none of the 15 A rows needs
   a chip fact; O-3 and part of O-15 wait for 608B experiments; O-1 / O-17 cite E11 only to turn an
   inference into a measurement — their answer for the bench chip does not change the design".

4. **O-3 is not a pure "B" row.** On the bench chip the claim secret cannot be changed by construction
   (slot 5: written before the data-zone lock, never writable after, not lockable — `255-608b-config.md`
   §3, §4); E8 / E13 / E17 confirm a frozen choice, they do not decide anything. What is really open is
   (i) the recovery protocol for a lost owner phone — pure protocol, class A; (ii) whether the production
   chip can replace the claim secret and whether the factory keeps it — class C (#426, #256), already
   named in the row's own trap text. Fix: O-3 → "A for the recovery protocol; C for a replaceable claim
   secret; the 608B experiments only confirm". This also removes the last reason to read §10 as "wait for
   the bench".

5. **Two A rows need measurements on today's nodes before the design can be approved.** No new hardware,
   but not paper-only either:
   - O-4 (delivering a new password): the row's own trap is "old and new passwords side by side —
     untested". Whether a HaLow mesh (wpa_supplicant / the morse driver) can hold two SAE passwords for a
     time is a fact about the radio stack, obtainable only on nodes.
   - O-16 (node-to-node identity / WireGuard): the former V5 (peer-table rebuild time on the real link)
     was folded into this row and is still unmeasured.
   The amendment already says measuring touches nodes and comes after v1.6 is wrapped up; apply the same
   note to these two rows (for example "A — design now; needs a bench measurement before approval") so a
   reader does not take "A" to mean "can be finished now".

6. **O-13 in class D ("wait for the RTC, #174") points at something that will not answer it.** The baseline
   says the RTC can be set by whoever holds the node, so time stays unauthenticated
   (`255-threat-model.md` §10-3). The scope half of O-13 (what a field credential may do) is class A; the
   duration half has no answer from an RTC alone. Fix: split the row that way, and keep "duration" as an
   open residual rather than as "waits for hardware". (A wrong D costs little, but it hides an A item.)
   Related, not a class error: O-9 / O-10 / O-22 need no hardware but do depend on the ICS side, whose
   owner and schedule are still "❓" (key-authority Q6) — say so in the A row.

7. **Baseline note (V7) and E11 — right in substance, two gaps.**
   - K15's baseline is "measured before the trust-model implementation starts", so measuring on v1.6 is
     right. But V7 says "8 nodes" and the bench has two (key-authority fact 12), and the only rekey flow
     that exists is in the development app (I-5). State what will actually be measured (the nodes on
     hand, development app) and that an 8-node figure needs hardware that is not there — a purchase is the
     user's decision. K15 also covers steps and waiting time of the other user flows, not only rekey.
   - E11: the honest statement is made correctly — `608b-facts.md:258` marks "any host can increment" as
     INFERRED, and O-1 / O-17 now say so. The row is correct on the points that matter (consumable chip
     only, irreversible, Counter[1] so no key use is involved, both outcomes recorded, and the burn
     read-back rule already ignores bytes 52–67). Gaps: (a) E11 is not in the experiment **order** line
     (`255-608b-config.md:190`), so it still has no place in the sequence — it must come after the config
     lock (E4); (b) "confirm no command can lower it" cannot be shown by one experiment — name the
     candidates to try (`UpdateExtra` decrement mode, a write to config bytes 52–67 after lock) and record
     each; (c) the "may increment by more than one on power loss" part stays a datasheet statement, E11
     does not test it — say so in O-1; (d) the row was added to a document reviewed at v7 with no entry in
     its version table.

## Not contradicted

- "One joint design, hosted by #52, not 23" is consistent with §13 and §14 as amended, and with the lesson
  recorded from rounds 1–3. Starting that design with the fields and ordering rule of the authorization
  object is the right first item and has no chip dependency.
- "The design can be written and reviewed but cannot be closed until the class-C facts arrive; write the
  storage as an interface contract marked ⚠️" is consistent with what I approved in v4. One addition worth
  making there: the joint design must also say what K6 can claim if **no** certified chip offers
  "only an authorized host can advance" storage, so the contract is not the only branch.
- §14's new cell and the K14 / fail-open wording changes (my round-4 minors) are applied correctly; the
  added fail-open row for the BLE health warning was not checked against source by me
  (`batman-autocommit:566-575`).

## Classification check, row by row

| Row | Class in the amendment | My reading |
|---|---|---|
| O-2, O-5, O-6, O-8, O-11, O-12, O-20, O-21 | A | A |
| O-7 | A | A (phone-keystore facts only; the physical-button option belongs to the v3.0 HAT and is outside it) |
| O-9, O-10, O-22 | A | A for hardware; depend on the ICS side (finding 6) |
| O-14 | A | A for the authorization; what a root shell can leave behind is bounded only from S-C (already in the trap text) |
| O-4, O-16 | A | A, with a bench measurement before approval (finding 5) |
| O-3 | B | A + C; 608B only confirms (finding 4) |
| O-1, O-17, O-23 | C | C |
| O-18, O-19 | D | D |
| O-13 | D | A (scope) + open residual (duration) (finding 6) |
| O-15 | E | E |
