# Review v2-B of `docs/design/security-architecture.md` (#423, v2)

Reviewer B, independent, L3, round 2. Read-only: documents and source at 7069f67. No node was touched. I did not
read review-v1-A.md or review-v2-A.md. The scope cut (foundation only; trust model stays open in §10) is a user
decision and is not questioned; "problem X is not designed" is not reported when X is listed in §10.

## Summary and verdict

**APPROVE-WITH-CHANGES — 0 BLOCKER / 3 MAJOR / 10 MINOR.**

v2 removes every mechanism round 1 rejected and replaces them with the shipped rules, named as invariants. I walked
my round-1 B1 scenario (replay after reset / after a card swap) against the shipped code: it is refused, because a
node that is not in a network only joins through `ownerOpVerb` → `verifyOwnerOp` with a one-time helper nonce bound
to the session (`node/node.go:691-740, 770-790, 1106-1117`), and `netUpdate` refuses when there is no network
(`:1152-1155`). The platform statements (P1, P2, O-18, V3, V4, Q-F) are now no stronger than the platform.

I looked hard for things fixed in v2.0 that the trust model would force to be redone (chip, card layout, record,
provisioning). I found none that needs a v2.0 change, with one condition (M1): the change-over rule in §6 needs one
more sentence or the first conversion can lock nodes out. Details in "Rework check" below.

The three MAJORs are: the new §6 has a lock-out path and its recovery sentence does not work with the shipped helper;
several "met in v2.0 / shipped" statements are stronger than the source; and #13 (a v2.0 ticket) is left waiting on two
open problems without saying what that does to v2.0.

## Findings

### MAJOR

**M1. §6 rule 5: after a conversion, a fall-back to the old image leaves a node nobody can log into or update; "要管理
就再升級回新版" cannot be done through the helper. §6 rules 3 and 5, §8 contract row "紀錄的版本欄", §9 row "試用失敗退回、
退回到 LKG".**
- Scenario. New-model image is committed; the owner converts the record (allowed "after commit", rule 3). Days later
  #401's observation period counts K abnormal boots and switches back to the LKG slot, which still holds the old
  image — nobody chose this. The old helper reads `v=2`: `provstore.Decode` → `ErrTooNew` (`provstore.go:126-129`,
  `:316-317`), boot verdict `unknown(too-new)` (`boot/boot.go:270-271`). §6 says "it refuses all management; upgrade
  again". But `dispatch` refuses **every** verb except `nonce` when the record does not load
  (`node.go:277-280`: "no usable provisioning record") — including `update.prepare` / `update.apply`, `psks.get`
  (provd then has no session keys) and `sign.*` (no identity proof for the app). The owner's signature cannot even
  be checked, because the owner list is inside the record the old helper cannot read. So the app cannot log in and
  cannot push the newer image. A production build has no shell (U7, K23). Recovery is a card reflash, which also
  drops the owner record (§8 row 3) — the outcome §6 exists to prevent. The same happens if the owner installs an
  older image that `release-min-serial` still allows.
- A second gap in the same rule: #13 adds "no valid network configuration → no mesh" (§7). A v2.0 image that falls
  back onto a record it cannot read has no valid configuration it can see. §6 rule 5 says the mesh stays up; §7 says
  it does not start. Which one wins is not stated, and K13 ("仍在網路") depends on it.
- Smallest fix (a condition, no new mechanism): rule 3 becomes "conversion is allowed only when the image in the
  **other** slot can also read the new record version" (the helper already knows the other slot's version for the
  update flow), and the conversion screen says a later manual downgrade below that version needs a reflash. State in
  §7 that #13's rule is judged from the wireless state the helper last applied (placeholder key = no mesh), not from
  whether the record parses. Add the negative test: conversion refused while the other slot holds an old-model image.

**M2. Statements in §3.2, §5, §15 and §16 that are stronger than the source or than the baseline documents.**
The regression tests of v2.0 will be written from these tables, so they have to be exact.
- **K20 "met in v2.0".** The baseline itself lists two departures: `verify_offline` has no on-the-spot proof
  ("#255 沒有當場證明，是 K20 的一個偏離", `255-608b-impl.md` §3.2, removed only in v2.5), and a chip node reflashed
  with a file image generates a software identity ("違反 K20 … 不支援", impl §7, §10 Q3). Move K20 to "partly" with
  both.
- **K10 / §16 "秘密不以明文經過 provd" / §3.2 A2 / P4.** `owner_enc_pub` exists (`provstore.go:6`) but its only use
  is the replay PSK (`node.go:443-447`); the node does not encrypt anything to the phone with it. The root password
  goes back through provd in clear (`node.go:609` `cbor.M(1, tag, 2, adv, 3, pw)`; fact 5 of `255-key-authority.md`).
  So A2's "節點把秘密加密給這支手機，provd 看不到明文" and P4's "今天已有的結構" describe a key that exists, not a
  protection that exists. Say: the key pair exists; node→phone secrets cross provd in clear today; K10 is met only
  for admin→node network secrets.
- **I-5 "已出貨".** Fact 12: the member, invite and remove flows exist only in the development build, and fact 9: a
  removal sends nothing to the node. I-5 is an app-side flow of the dev build; say so, and say which secrets it
  changes (mesh password; phone Wi-Fi password?).
- **I-6 "主人同意就能裝別人做的映像" is blocked.** Only on the app path. The owner receives the root password at claim
  and can run `sysupgrade` over SSH / the web UI with any image until the maintenance entry is closed (K23, open).
  Narrow the "what it blocks" cell to the app path.
- **K12 "單一判斷點".** Owner-signed verbs are judged in the helper every time (true). Read-only and member-level
  access is admitted by provd from PSKs it fetched and keeps (`psks.get`, `readonly.go`). Say "management verbs".
- **K4 / I-1.** True against replay. On S-A/S-B a holder who images the card and writes the image back later rolls
  the whole record back, removed owners included (P1; threat model T-SE7). One line under K4.
- **K19.** Holding a node gives the mesh password (layer 1 on every other node) and, for a family node running OTS,
  the TAK CA key (§3.1 N8). "No management power over other nodes" is the claim that holds.
- Fix: correct the cells; no design change.

**M3. #13 is a v2.0 ticket and §14 leaves it waiting on O-1, O-4 and V7; what that does to v2.0 is not stated, and
three documents that now disagree are not in the §13 sync list.**
- `255-key-authority.md` §6 puts "#13（含 §5-1、§5-4 的實作）" in v2.0. §10 schedules O-1 and O-4 "after the 608B
  works on the bench" with no version, and the closing paragraph of §10 speaks only of v2.5. Under the project rule
  (an issue is not split; leftovers stay as a checklist in the issue) #13 then stays open past v2.0, or v2.0 waits
  for two trust-model designs. Either is a schedule decision for the user; the document should ask it in §12 instead
  of leaving it implicit. The same applies to #423 itself ("完成後做一次紅隊測試" is in v2.0).
- Not in §13: `255-key-authority.md` §6 (the #13 row); #402's text ("第 4 級 … 回到可認領／可供裝狀態") and
  `docs/field-resilience.md` Decision 2 ("re-runs first-boot provisioning … the only path that re-arms the node
  without a human"), both contradicted by the new §8 reset table (see m3); `docs/threat-model.md` rows that the
  rewritten section now contradicts (m6).
- Fix: one question in §12 ("#13 closes in v2.0 without revocation-survives-reset and delivery, or v2.0 waits");
  three rows in §13.

### MINOR

- **m1 (§5).** Shipped protections that §6 and the v2.0 storage tickets (#111, #41) lean on but that are not in the
  invariant list, so nothing forces a regression test: (a) an `unknown(*)` boot verdict freezes every state-changing
  verb (`node.go:260-262`) — §6 rule 5 is this; (b) every owner verb is re-checked against the record p5 confirms, so
  a co-owner removed in p5 cannot act through a stale overlay (`node.go:790-802`); (c) a rolled-back or older slot
  never replaces a newer claimed record (`boot/boot.go:235-256`, generation rules); (d) the last owner cannot be
  removed (`node.go:982-984`); (e) the lock state survives an unreadable p5 through p6 `last_known_state`
  (`node.go:598-601`); (f) the release root is read from the image, never the overlay (`release.go:110-112`).
- **m2 (§5 citations).** I-7: `255-608b-impl.md` §3.3 is about the challenge input, not a limit; the limits that
  exist are 3 failures per connection in provd (`provd/session.go:576`) and 10 per hour for `claim.replay`
  (`node.go:631-634`); the "already claimed → refused" half is `node.go:566-568`. I-8: the "never generate" rule is
  impl §2.3 item 2 and §7, not §2.4. I-1: the lines that carry it are `node.go:691-740` and `770-790`.
- **m3 (§8 reset table).** The decision (an automatic reset keeps the owner record) is sound and consistent with the
  code: a claimed node refuses `claim.verify`, and on S-A/S-B a reflash is always the way out. But: (a) it reverses
  #402 and field-resilience Decision 2 — add to §13 and tell the user, since "is a reset node free for anyone" is
  threat-model §8.1-8 ("either answer has a victim"); (b) the table does not name who edits `prov.cbor` during the
  reset, while §8 says the helper is its only writer — say "the reset leaves a marker; the helper performs it as a
  `leave`-like transaction"; (c) "沒有人授權的事件不能把節點變成任何有 QR 的人都能入庫" is not true of row 3 (p5 damage is
  also unauthorised) — word it as "when the record is readable"; (d) trap to add to O-3: on a CM4 with eMMC there is
  no card to swap, so a lost owner phone plus this rule may leave no path back at all.
- **m4 (§6).** Three cases to add to the rules or tests: (a) one network with converted and unconverted nodes — the
  I-2 chain cannot be signed in two formats, so conversion is per network or the network forks; (b) fall-back with a
  stale overlay copy: p5 holds the new record, the overlay still an old `v=1` one; `resolve()` fails on p5 and the old
  helper carries on "on the overlay" (`node.go:795-797`), so the non-state-changing owner verbs (`update.*`,
  `diag.bundle`, `bulk.*`) accept the old owner list — a removed co-owner included (rule 6 says this cannot happen);
  (c) any v2.0 change to the record's key set must take a new `v` in both `prov.cbor` and `prov.meta`: the parser
  checks the exact key count (`provstore.go:122`), so an added key without a new `v` is "corrupt", not "too new".
- **m5 (§10 list).** Open items that §15 or the tickets refer to but that have no row: the audit record (K24 / K25:
  where it lives, what a reset keeps, who reads it — §15 says "waits for the trust model", nothing in §10 says so);
  the inventory and "how long until a reported loss is effective" (#95); zeroize (#54); workload identity (#97);
  phone-key attestation at enrolment (threat model §8.1-27 — keys made in v2.0 cannot be attested afterwards);
  what a node accepts between enrolment and its first organisation credential (§8.1-28). Trap missing under I-2 /
  O-4: a node that was off needs every intermediate step, not the latest state (Appendix B4).
- **m6 (`docs/threat-model.md`).** The rewritten section is correct. Two leftovers in the same file now contradict
  it: the table row "L3 / admission … ✅ Yes — PKI admission + attribution, #13 per-node certs" (v2.0 admission is a
  shared password; nodes verify no certificates, §2, §7), and "client certificates issued by the mesh/FTS CA" (FTS is
  retired; the TAK CA is T3, not a mesh CA).
- **m7 (§3.1 N3, I-3).** New with #255: N3 survives a reflash, so every secret pack ever sent to a node stays
  decryptable by that chip for ever (today a reflash makes new keys). Not a hole — only an owner can make the node
  use one (I-1) — but after a card swap "the owner" is whoever claims with the QR, and he can join the node to an old
  configuration. One line under N3 and in §8 row 3.
- **m8 (§9).** Row "bench 與量產混在同一個網路 … 不會被加進量產網路": the check is in the app only; at layer 1 any
  device with the password is in (§7 says so). Word it as "a production app will not send it a secret pack".
- **m9 (§16 tests).** Missing negative controls for things the document claims: claim without the QR and claim of an
  already-claimed node (I-7); removed member's old password no longer joins after the rekey (I-5); `unknown(*)`
  verdict refuses state changes (m1 a); removed co-owner with a stale overlay (m1 b); M1's "conversion refused".
- **m10 (§2 T5).** Wording: the ROM verifies the bootloader, the bootloader verifies `boot.img`. No effect on the
  design.

## Rework check (will anything fixed in v2.0 have to be redone when the trust model arrives?)

| Thing fixed in v2.0 | Result |
|---|---|
| 608B configuration (slots, lock) | Bench only; production chip is #426. Nothing the trust model needs is burned in. The counter question is handed to #426 (O-17) — correct |
| Node certificate fields | Identity only; verified against `255-608b-impl.md` §3.1. No role / unit / network. No re-burn needed |
| QR content and claim secret | Permanent secret is recorded as a trap (O-3). A rotation would be a production-chip matter, not v2.0 |
| Record `prov.cbor` | Has `v`; old images already answer `ErrTooNew` (source checked). Safe **if** M1's condition and m4 (c) are written down |
| Partition layout | A reset-proof store can be a directory the (file-level) reset skips; the reset table already implies a file-level reset. Say explicitly that a configuration reset never reformats p5, or O-1 will need a layout change later |
| Phone keys | Made without attestation and without user authentication (`Keys.kt:64-98`). If the trust model wants either, phones re-enrol. Bench only, no external deployment — acceptable; list under m5 |
| Network objects (`net_config`, `net_secrets`, member list) | Unchanged in v2.0; replaced through §6 |
| Boot signing key (#405) | CI uses a development key; the production key and the OTP burn are v2.3; Q-F is asked before that. Fine |

## Round-1 findings

| Round 1 | Status in v2 |
|---|---|
| B1 stored object performs a join | **Closed.** Shipped rule kept (I-1); verified in source; tests 2 and 3 |
| B2 revocation floor in a chip counter | **Moved to O-1 / O-17**, traps recorded correctly. Safe for v2.0 only together with M3 (#13's revocation part) |
| M1 sequence scope | Closed (removed); I-2 kept |
| M2 split network | Moved to O-5; v2.0 unchanged and says so. Safe |
| M3 admin set with majority | Removed; O-12. Safe |
| M4 K10 / K11, key for people | Moved to O-2; P4 added, but its "already there" claim is too strong (M2) |
| M5 maintenance role | Moved to O-14. Safe (dev builds keep SSH, U7) |
| M6 generation = unit-wide re-issue | Removed; O-1. Safe |
| M7 deferred problems, change-over | Deferral is now the user's decision. Change-over: new §6 — **not closed** for the fall-back case (M1) |
| M8 S-C claims | **Closed** (P2, O-18, V3, V4, Q-F) |
| M9 WireGuard binding | Moved to O-16 with the direction. Safe (#16 is v2.5) |
| M10 lifecycle gaps | Mostly closed (reset table, new rows); remainder in m3, m4 |

## Field walk-through (what v2.0 gives)

| Scenario | Result |
|---|---|
| Fire squad, 8 nodes, ICS issuing station | Not in v2.0: still the owner model. Stated (O-9, O-10, O-12) |
| Family, 4 nodes, one phone | Works (shipped claim + owner-signed join) |
| Node lost | Remove + rekey from the dev-build flow (I-5, see M2); holder is a member until the rekey reaches every node; time not measured (V7). Stated |
| Owner / admin phone lost | No recovery. Stated (§9, O-2, O-3) |
| SD card dies, spare card | Works: same node id, unclaimed, same QR, owner signs the join; count resets (stated). Old packs still open (m7) |
| Off for a month, two changes | Works with the shipped chain in one update if a phone carries both steps (`node.go:1158-1232`); not mentioned (m5) |
| Sold | Owner-ordered factory reset, new owner claims with the QR; the seller knows the QR for ever (O-3) |
| Repair | "Factory reset before hand-over" is stated for S-A/S-B; remanence in O-15 |
| Two admins, split network | Forks, as today. Stated (O-5) |
| OTA fails its trial | Works: the record is untouched in trial (`node.go:257-259`). After a conversion and an LKG fall-back: lock-out (M1) |

## Citations and facts checked

| Item | Result |
|---|---|
| I-1 `node.go` owner-op with session nonce; `netJoin` only when not in a network | held (`:691-740`, `:770-790`, `:1106-1117`); cited line ranges are loose (m2) |
| I-2 `node.go:1190-1202` next version, previous hash, previous admins | held |
| I-3 `wtxn.go:121-140` | held |
| I-4 `node.go:1242-1311`, `:258-259` | held |
| I-5 "shipped" | held for the dev build only (facts 9, 12) |
| I-6 `node.go:776-777` + `release.go` | held for the app path |
| I-7 `claimed_counter`; limits | counter held (`node.go:592`); limit citation wrong (m2) |
| I-8 | not implemented yet (document says so); section number wrong (m2) |
| `provstore.go:6` `owner_enc_pub` | exists; not used to encrypt to the phone (M2) |
| `provstore.go:112-131` strict parse, `v > 1` → too new | held; verdict `unknown(too-new)` at `boot/boot.go:270-271` |
| "too new → management refused, wireless kept" | held, and stronger than stated: every verb except `nonce` is refused (`node.go:277-280`) |
| `release.go:110-114` `release-min-serial`, install-time | held |
| `KeyPolicy.kt:64-66`, `Keys.kt:64-98` | held |
| `255-608b-config.md` §2 nodes hold no root key | held |
| `255-608b-impl.md` §3.2 `trust_gate` (app-side) | held |
| `608b-facts.md` §7 counter facts quoted in O-1 | held |
| #402 / `field-resilience.md` Decision 2 vs §8 reset table | differ (m3) |
| P2, O-18, V3, V4, Q-F against Pi 4 / CM4 | consistent with what I know; V3 and V4 remain unverified and are marked so |
