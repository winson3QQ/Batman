# Review v3-B of `docs/design/security-architecture.md` (#423, v3)

Reviewer B, independent, L3, round 3. Read-only: documents and source at e4c9930. No node was touched. I did not read
any review-*-A.md. The two user decisions of 2026-11-25 (an automatic reset keeps the owner; revocation and rekey
delivery of #13 move to v2.5) are baseline and are only checked for consistency.

## Verdict

**APPROVE-WITH-CHANGES — 0 BLOCKER / 1 MAJOR / 12 MINOR.**

The whole document was read again. The new citations in §5 (I-7 … I-13), §6 and §8 were opened; all but one hold
(MINOR 1). The single MAJOR is a requirement the document places on #402 that #402's own trigger list cannot meet;
the fix is wording plus one sync row, no design change.

## Round-2 MAJORs

| Round 2 | Status |
|---|---|
| M1 §6 lock-out after convert + fall-back | **Closed.** §6 is now conditions for a later design; condition 4 removes the case. (Correction to my round-2 text: the overlay copy is per slot, so the old slot usually still has an old readable copy — the failure is "old owner list is used", as v3 says, rather than "nothing loads". Condition 4 covers both.) |
| M2 claims stronger than the source | **Closed.** §3.2 A2, P4, I-5, I-6, §15, §16 now say what the code does |
| M3 #13 waiting on open problems | **Closed** by the user decision; §7, §10, §12, §13, §14 are consistent with it; #402 has already been edited to match row 1 |

## Finding

### MAJOR

**M1. §8 row 1 / §16 / test 9 require that the automatic reset "cannot be triggered from radio peers"; with #402's
trigger list that is not achievable, and the document does not say what follows.**
- Scenario. #402 counts two things towards its levels: "健康檢查失敗" and "非斷電異常" (panic, watchdog, hung task).
  A radio peer that can crash the node — the project has had such bugs (mm6108 skb ownership #263, the stress-reboot
  work) — produces abnormal boots at will. Levels 1–3 (restart service, other slot, LKG config) do not cure a crash
  that comes from the air, so the count reaches level 4. Row 1 then clears the network configuration and password.
  The attacker leaves; the node is now permanently out of its network until the owner's phone is physically next to
  it (I-1). A transient denial of service has become a lasting one, node by node, with no key and no password.
  The health gate can also depend on the radio: the shipped check requires neighbours in some states
  (`batman-autocommit:451-464`, "neighbours required (fail-closed)"); if #402 reuses it, jamming or simply operating
  alone counts as failure.
- Evidence. #402 body, "觸發條件" line; §8 row 1 "不能由無線對端 … 觸發"; §16 "第 1 列的觸發不能從無線或非 root 程式
  到達"; test 9. As written, the second half of test 9 has no finite form ("cannot be triggered from the mesh"), so
  it would end up as a check that no verb exists.
- Smallest fix (text only). (a) Replace the sentence by what can be met and tested: no peer, phone-Wi-Fi client or
  non-root process can **request** a reset (no verb on `helper.sock`, which provd can reach; no network listener);
  and failures that a peer can cause — abnormal boots, and any health item that depends on neighbours or radio
  traffic — do **not** count towards level 4. (b) State the residual if #402 cannot guarantee (a) fully. (c) Add
  #402's trigger list to §13 as a row to change. (d) Test 9 becomes: K induced panics / K boots without neighbours do
  not reach level 4; a provd-uid process cannot request it.

### MINOR (for the register)

1. **§8 fail-open table, row 4 is not what the code does.** A legacy node is claimed only after the claim proof
   passes; the legacy gate comes after `CheckMac` (`node.go:571-585`, comment "only after CheckMac passed"). What is
   relaxed for legacy is the radio handling (`:590`) and the SSH-key / dev-open gate. Correct or drop the row.
2. **§8 row 3 holds for a record that is present but damaged, not for one that is absent.** With the record missing
   on p5 and on this slot's overlay the shipped code creates a fresh `unclaimed` (rc 7) or `legacy` (rc 9) record
   (`boot/boot.go:190-232`), which is claimable. That needs root or the card, so it belongs with row 4; say so.
3. **F1 and conditions 2–4.** A version bump made in v2.0 is itself a format change; say that conditions 2–4 apply
   to it (the image keeps writing the old version until an explicit step, and the other slot must read the new one).
   Precedent to avoid: key 12 was added under `v=1` (`provstore.go:122`). `255-608b-impl.md` adds no record key (the
   identity cache is separate files), and rows 1 and 2 of the reset table need none, so nothing is forced today.
4. **Condition 4, "永遠不會".** Also needed: after a conversion, `update.prepare` refuses an image that cannot read
   the current record version (a downgrade inside `release-min-serial`). Checkability: the helper has no call today
   that tells which record versions the other slot's image reads; a one-line file in the image is enough — note it
   as work for the conversion ticket.
5. **§8 row 2 (factory reset for resale).** Say whether "其餘全部" includes p6 (tenant data, OTS database, logs) and
   the TAK CA / server keys on p5; a resale needs them gone. On S-A/S-B deleted files remain readable (O-15).
6. **§8 row 1 channel.** "由 helper 執行" must not be a verb on the socket provd uses; name the channel as root-only
   (covered by M1 (a) if adopted).
7. **K14 list.** Other shipped relaxations not in the table: the dev-open marker (`/etc/batman-dev-open`), the BLE
   health gate being warn-only (`batman-autocommit:566-575`), creation of an `unclaimed` record on rc 7 (item 2).
8. **§11 V7** still says "何時查：#13"; delivery moved to #52.
9. **§9 row "成員離開、節點遺失"** lists "#13 回歸測試" as verification; I-5 is a development-app flow and the node
   side is only I-2. Point it at #52 / #95.
10. **§8 "v2.0 的卡都是 bench 卡，重燒可以接受".** True for hardware; the bench role rule ("deployed role = sysupgrade
    only") makes a reflash a step that needs the user's consent each time. One clause.
11. **§15 K4.** Add the S-A/S-B residual: writing back an old image of the card rolls the whole record back (P1
    covers it in general; K4 is where a reader looks).
12. **Citation `release.go:161`** is one line off (`onlyKeys` starts at 162; the refusal is `:262-263`, which is
    right).

## Rework check (v3 as written)

| Fixed in v2.0 | Will the trust model or CM4 force a redo? |
|---|---|
| 608B configuration | No. Bench only; production chip is #426; counter question correctly handed over (O-17) |
| Node certificate | No. Identity only; fields match `255-608b-impl.md` §3.1 |
| QR / claim secret | No for v2.0. Permanent-secret and factory-retention traps are recorded (O-3, #256) |
| Record format | No, given F1 / F2 and conditions 1–6, plus MINOR 3 and 4. v1.6 images already answer "too new" (`boot.go:270-271`) |
| Partition layout | The §8 argument holds: slot state is already outside the encrypted area (`autoboot.txt`, first FAT partition, `storage-architecture.md:21`); a reset does not reformat p5; bench cards can be reflashed (MINOR 10); production is CM4 eMMC with the #413 layout and nothing ships before S-D (U8) |
| Boot signing key | No. CI uses a development key; the production key and OTP are v2.3; Q-F is asked before the burn |
| Provisioning steps | No. Bench burn only; production station is #256 |
| Factory-reset verb (#255) | No. It is one owner-signed verb in the current model and is replaced with the model like every other verb; needs no new record key. See MINOR 5 for its extent |
| Automatic-reset behaviour | Not a rework risk; M1 is about its trigger |
| Phone keys | Recorded in O-7 ("decide before the first enrolment outside the team"). Correct |

## §6 against the code

- F1: correct. Strict parse and exact key count (`provstore.go:112-131`); "too new" needs `v > 1` in the record or
  the meta (`:126-129`, `:316-317`); anything else is "corrupt" and takes the rc 10 path (`boot.go:236-246`).
- F2: correct for the release object (`release.go:262-263`).
- Condition 4 reason: correct. `resolve()` fails when the p5 record does not decode (`wtxn.go:262-273`); the owner
  verb then continues on the overlay copy (`node.go:796-797`); state-changing verbs are frozen by the verdict
  (`node.go:260-262`) but `update.*`, `diag.bundle`, `bulk.*` are not in that list (`:251-252`).
- Conditions 1–3, 5, 6: consistent with I-4 and K13; nothing in them conflicts with shipped A/B behaviour.

## §8 reset table against the code

- Row 1: consistent with a `leave`-like transaction (`node.go:1316-1340`: state back to claimed, network cleared,
  owners kept); a claimed node refuses a claim (`:566-568`). Trigger: M1.
- Row 2: no such verb exists today (confirmed: no reset verb in `dispatch`, `node.go:308` comment). Assigned to #255.
- Row 3: matches `boot.go:236-246` for a damaged record; lock kept through p6 (`254-stage1-impl.md:95, 244`).
  Boundary in MINOR 2.
- Row 4: matches rc 7 (`boot.go:190-212`).

## §15 "met in v2.0" — counter-examples tried

| Rule | Result |
|---|---|
| K4 | Holds against replay (owner-op with a one-time nonce; `netUpdate` refuses without a network). Residuals: card image written back on S-A/S-B (MINOR 11); record absent → unclaimed (MINOR 2) |
| K16 | Holds (slot 1 internal-sign only; certificate signed after read-back; `se-sign` refuses a duplicate key) |
| K19 | Holds as worded (no key that authorises another node; the network password caveat is stated) |
| K21 | Design of #255 (root-only bus, flock); not implemented yet — the cell says "(#255)", acceptable |
| K22 | Holds for enrolled nodes: an update needs the owner (I-6); the release root is read from the image only. The retained claim secret concerns un-enrolled nodes and is in O-3 |

Nothing in the "partly" row is stated more strongly than the source.

## Field walk-through

Unchanged from round 2 for v2.0 (owner model): family set-up works; lost node / lost phone / split admins are stated
as unchanged and open; spare card → unclaimed, same QR (row 4); a month off → shipped chain; resale → row 2 once #255
adds the verb (until then: reflash); repair → factory reset first; trial failure → record untouched. New in this
round: a crash loop caused from the air → M1.

## Citations checked

| Item | Result |
|---|---|
| I-1 `node.go:705-740`, `:781-790`, `:1106-1117`, `:1152-1155` | held |
| I-2 `node.go:1190-1202` | held |
| I-3 `wtxn.go:121-140`; I-4 `node.go:1242-1311`, `:256-259` | held |
| I-6 `node.go:776-777` | held |
| I-7 `node.go:566-568`; counter `:592` | held |
| I-8 `node.go:654-661` | held |
| I-9 `node.go:788-800` | held |
| I-10 `node.go:251-263`; `boot.go:236-271` | held |
| I-11 `254-stage1-impl.md:95, 244` | held |
| I-12 `halow-keyguard.init:4-14` | held |
| I-13 `255-608b-impl.md` §2.3, and the two departures (§3.2, §7) | held (not implemented yet, as stated) |
| A2 `node.go:443-447`, `:609, 672` | held |
| §2 `release.go:110-111` (root read from the image) | held |
| §6 `provstore.go:112-131`, `release.go:262-263`, `wtxn.go:262-273`, `node.go:796-797` | held (`release.go:161` one line off) |
| §8 `provstore.go:1-3`, `storage-architecture.md:21`, `:357-359`, `boot.go:263-267` | held |
| §8 fail-open row 4 `node.go:566-568, 590` | **did not hold** (MINOR 1) |
| §7 legacy `node.go:590`, `boot.go:225-229` | held |
| #402 body edited to match row 1; trigger list unchanged | checked (`gh issue view 402`) |
| V3, V4 | still unverified, marked so |
