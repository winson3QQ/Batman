# Review v1-B of `docs/design/security-architecture.md` (#423, v1)

Reviewer B, independent, L3. Read-only: documents and source at f73def8 (main dfac71f + design/255-key-authority
563fb80). No node was touched. I did not read any other review of this document.
Baseline (U1–U9, D1–D7, K1–K25, threat model v2.2, 608B config v7 / impl v5, shipped behaviour) is not re-argued.

## Summary and verdict

**REJECT — 2 BLOCKER / 10 MAJOR / 11 MINOR.**

The parts that only restate the baseline are sound: five separate trust roots, role and network kept out of the node
certificate, the two-key update rule (already how `update.*` works today: owner-op + release signature), no clock,
random unit id, the honest v2.0 boundary in §6, and the S-A/S-B rows that say "the holder is a member until the rekey".
The source citations I opened all hold.

What fails is what the document adds on the revocation / ordering side. It repeats three things earlier rounds already
rejected: (1) a stored, replayable object performs the join (v1-A B3, v1-B B1); (2) a floor mechanism that can be pushed
up by someone below the anchor and locks the node for good (v2-A B1(b), v3-B C-B1), built on a chip counter that
608B config v4 removed and the driver deliberately does not implement; (3) a "generation" escape that re-issues the
whole unit (v2-B M10). Seven of the fifteen §5 problems that `255-key-authority.md` §6 assigns to #423 are deferred or
not mentioned, so #13, #52, #54 and #95 cannot be designed from this document without coming back.

Most fixes are removals: drop the chip counter, drop the admin-set-with-majority, drop the WireGuard "count", keep the
shipped "first join is signed on the spot".

## Findings

### BLOCKER

**B1. A join is a stored bearer object, and everything that would stop its replay is erased by a reset or a card swap
(K4 is false). §5.1, §6 steps 3–4, §9.3, §11 rows "加入網路", "重燒卡 / 換卡", "當機 / 開機迴圈".**
- Scenario. Squad network v7 has members X and Z. X is lost; the admin signs v8 without X and rekeys. X's holder (or
  a removed admin, or anyone who was ever a relay: provd forwards every object) kept three objects addressed to Z:
  the enrolment object, net config v7, secret pack v7. Later Z is reset — by its owner, by a dead SD card replaced with
  a spare (#404), or **automatically** by #402 level 4 (p5 damage → "回到可認領"). §9.3 keeps the chip, the floor, the
  list, the enrolment count and the log; it clears the anchor and (not listed, so cleared, and on a new card certainly
  gone) the per-signer sequence memory of §5.1. Whoever knows Z's QR (every past enroller; N4 never rotates) answers
  the CheckMac freshly, replays the enrolment object (anchor signature valid, no sequence memory, generation unchanged
  because an ordinary removal does not bump it, §5.2), then replays config v7 + pack v7. Step 4 passes: chain to the
  anchor, generation ≥ floor, "sequence larger" than nothing, Z is in the member list, the pack opens (N3 never
  rotates, §3.1). Z is now in a network it is not in, on a password the removed party knows.
- Evidence. Today the first join needs the owner's signature made on the spot (`node/node.go:774-790` verifyOwnerOp
  over the session; `:1106-1117` netJoin; fact 4 of `255-key-authority.md` §2). §11 replaces that with "步驟 4", which
  has no freshness. K4 text: "不能讓節點進入一個它目前不在的網路". Same class as review v1-A B3 and v1-B B1.
- Smallest fix (narrowing, no new object). Keep the shipped rule: a node that is not currently in network N accepts a
  config for N only inside a session where an authorised key signs a nonce the node just gave (first join, and re-join
  after any reset). Stored objects alone may only move a node forward inside a network it is already in. Same for
  enrolment: the enrolment object must cover a node nonce. Add both negative controls (replay after reset; replay
  after card swap).

**B2. The revocation floor (K6) is not designed, and the one defence the document states for it does not hold.
§5.3, §7.2, §9.3, §15 Q-D, §16 V1.**
- (a) The lock-out claim is wrong at the chip. §5.3: "世代一次只能加一 … 所以要鎖死節點得先拿到 A1". The floor lives in
  a 608B monotonic counter. `255-reviews/608b-facts.md` §7 (the project's own fact sheet): two counters, maximum
  2,097,151, "There is no way to reset", **no authorisation parameter exists for the Counter command** (any bus master
  can increment), and "in some power loss conditions the counter may increment by more than one". My own knowledge of
  the ATECC608 Counter command agrees (confidence about 85 % on "no authorisation"; it is not verified on a chip, E11
  was never run). So: any code that reaches root on the node once, the helper itself after a bug, or anyone who clips
  onto the I2C bus (S-A/S-B, HAT in hand), can run the counter up. The node's floor is then above every generation the
  unit will ever sign; §7.2 says the node then refuses every management action; nothing can lower it; the only cure is
  a new chip = a new node id. That is a permanent, remote-reachable loss from one root-level slip — the same shape as
  review v3-B C-B1 and v2-A B1(b), and a K8 violation by something below the anchor. A plain power cut during an
  increment can do a milder version by itself (floor ahead of the unit's generation until A1 bumps).
- (b) It contradicts the reviewed baseline. 608B config v4 "拿掉晶片背書與計數器"; v7 §4 says bytes 52–67 "不碰";
  `255-608b-impl.md` §2.2 lists Counter under "不實作"; the `Identity` interface (§2.1) has no counter method, yet §13
  silently makes "單調計數器" a requirement on the production chip (#426).
- (c) The model itself is open. One counter per chip, one generation per unit: Q-D admits a node moved to another
  unit cannot work, and a first enrolment into a unit at generation g needs g increments. The candidate in Q-D (floor
  on disk, counter counts enrolments) means the floor does not survive a card swap, so K6 is then not met on S-A/S-B.
  Q-D is put to the user, but it is a technical question, not money / hardware / direction.
- (d) Where the list and floor live "outside p5, untouched by reset" is not stated. `storage-architecture.md:21-26`
  has no such region; a new one changes the partition layout, which is a one-way decision at provisioning.
- (e) §16 V1 says the counter's limits "都沒讀過"; they are in 608b-facts §7 and they answer V1 with "no".
- Smallest fix. Remove the chip counter from the architecture. Say what is true per platform state: on S-A/S-B the
  holder of a node has root, so a floor adds nothing against him and the floor is a file (kept across a config reset,
  lost with the card — residual, already §10-14 class). For S-C state the requirement on #426 as "storage that only an
  authorised host can advance" and leave the mechanism to #426/#414. Then §12 K6 must say "met from S-C; on S-A/S-B
  only against people without the node".

### MAJOR

**M1. The sequence number is scoped so that honest people lock each other out, and it cannot order network configs.
§4.2 outer fields, §5.1.**
- Scenario 1. The issuing station signs eight member grants, sequence 1–8, same signer / type / network. Grants are
  presented by their holders. Member 8 connects to a node first; the node stores "max seen = 8" for (signer, type,
  network) and "只收更大的"; members 1–7 are refused on that node. The outer header has no subject field, so the node
  cannot keep the mark per grantee.
- Scenario 2. Admin A's config (A's sequence 6, made before the removal of lost node X, never delivered to node Z)
  arrives at Z after admin B's config that removed X (B's sequence 3). Per-signer marks: 6 > A's last seen → accepted;
  X is back. This is the pitfall of §5-5 / Appendix B5 ("悄悄把移除遺失節點這個動作蓋掉").
- §11 "網路中斷 / 分割" speaks of "序號相同內容不同", which has no meaning with per-signer sequences; the config also
  has a "網路版本" in its body that §6 step 4 never checks. Two orders, neither defined.
- Fix. One order per object kind, stated in the document: grants ordered per (signer, subject); network state ordered
  by the network's own version, and say what stops a single signer jumping the version to the maximum (K8, K18). Add
  the subject to the outer header now — it is a format field v2.5 cannot add later without redoing v2.0 objects.

**M2. Two admins on two sides of a split: "節點都不收" cannot happen. §11.**
Each half already applied its own side's config (and its own new password) while split; the halves no longer meet by
radio. "要管理員明確選一份重簽" does not say with which version, who may, how the losing half is reached (BLE to each
node?), or what happens to a removal made on the losing side. Appendix B5 lists exactly these. Deferring to #52 leaves
the order rule (a format matter) undecided. Fix: decide the rule here or mark S16 as not solved and list it for the
user as a residual; do not claim a behaviour that the radio makes impossible.

**M3. The "admin set inside the network config, changed by a majority" is a second source of authority and should be
removed. §4.2, §12 K18.**
- It contradicts D2 (settings are no longer authorised by admins the config lists itself). Who is an admin is already
  decided by role grants from A1 / the issuer (§6 step 8), and K2 already stops an admin from making admins.
- Set of 2: one phone lost → no majority → the set can only be changed by A1, the offline root (S5 regresses). Set of 3
  with two phones in the same lost vehicle: same. COSE_Sign1 (D3) carries one signature; a majority needs a new
  multi-signature format and a collection round in the field (K15).
- It does not deliver K18: an admin with unit scope signs a config for a new network id with himself as the only
  admin and moves the nodes; or signs a rekey whose packs go to nobody.
- A node that was off needs the chain of set changes to judge the latest signer (Appendix B4: "must need only the
  latest state").
- Fix: delete the set and the majority rule. K18 is then met by construction (only A1 / issuer grants and withdraws
  the role); say so, and list what one admin can still do (rekey, remove nodes) as accepted, with the audit record.

**M4. K11 and K10 are asserted, not shown; the hierarchy has no encryption key for people. §3.2, §5.2, §12.**
- §5.2 argues only about nodes that have not yet received the new password. The gap is a node that has the new
  password but not yet the revocation (separate objects, separate delivery). The revoked member connects by BLE with
  his still-accepted grant and asks for "自己那台的手機 Wi-Fi 設定" (A4) — the new phone Wi-Fi password, which is on the
  same bridge as the mesh (fact 10). Same for a revoked admin if any verb returns the network password (§5-2). This
  is review v2-A M2.
- "新密碼只加密給沒被撤銷的節點（N3）與人": people have only signing keys in §3.2. Today the phone has a separate
  agreement key (`Keys.kt` OWNER_ENC; `provstore.go:6` `owner_enc_pub`). The grant has no field for it, and without it
  anything a node gives a phone crosses provd in clear (fact 5), so K10 is met for admin→node only.
- §5-2 (second admin obtains password and member list) is not answered anywhere.
- Fix: state that a rekey object carries (or names the minimum sequence of) the revocation it enforces, so a node
  cannot have one without the other; add the holder's encryption public key to the grant fields; answer §5-2 or mark
  it open with the K-rules it blocks.

**M5. K3 has a counter-example, and three sections disagree on who signs a maintenance authorisation. §3.2 A5, §4.2,
§8.3.**
- §4.2: the maintenance role may be granted "由發證者授予但要 A1 的指定物件明確允許". Once A1 has signed that
  designation, the issuing station alone issues root-equivalent credentials from then on; a compromised station mints
  one for its own key. K3 says "不能由發證站單獨發出"; review v2-A M8 raised the same shape. §8.3 also relies on the
  role being pre-issued to field phones, i.e. a standing root-equivalent credential on a phone with no user
  authentication (`Keys.kt:64-98`) — the pitfall listed under §5-8.
- §3.2 A5 says the authorisation is signed by **A3** (an admin); §4.2 says by a key with the maintenance role; §8.3
  the latter. A5 as written lets any admin open a shell.
- Fix: maintenance role granted by A1 only, per named node set; delete the "issuer if allowed" branch; correct A5.
  State the cost (squad: a root ceremony to appoint maintainers) for the user.

**M6. The generation is the only revocation that survives, so ordinary revocations become unit-wide re-issues; its
effect on stored state is undefined. §5.3.**
- §5.3 itself says important revocations (issuer, admin) must use a generation bump because the list is lost on a
  card swap and has a cap. A bump rejects everything issued below it. For a squad that is: offline-root ceremony,
  re-designate the issuer, re-issue every grant, re-sign every network config, re-enrol? (the enrolment object carries
  a generation too) — for one lost admin phone. Review v2-B M10 and Appendix B1 ("a generation escape re-issues every
  person and visits every node").
- Not stated: whether a node re-checks what it already stored (its enrolment, its network config) against the new
  floor. If yes, every node drops its network at the bump (Appendix B1(d)); if no, say so. Review v1-B M2.
- "節點拒絕跳號": a node off for a month across two bumps needs both bump objects in order; who keeps and carries
  them is not stated. The list cap and what happens when it is full before A1 acts are not stated. A squad root
  restored from backup does not know its own last sequence (Appendix B1, last bullet).
- Fix: say plainly that stored state is not re-judged by a bump; give the list cap and the full-list behaviour; say
  that a bump object must be self-contained for sleepers (floor = value in the newest A1-signed statement, no
  "one step" rule — with B2 fixed nothing below A1 can raise it).

**M7. Problems assigned to this document are deferred or missing; four issues cannot be designed from it.**
`255-key-authority.md` §6: #423 = "§5 全部題目的設計". Status: §5-2 not mentioned; §5-4 sent back to #13 (which asks
this document for it); §5-5 see M2; §5-9 (issuing station as a live signing tool: limits, audit, two-person) not
mentioned beyond "not on the same host as A1"; §5-10 (member finds own node / gets Wi-Fi settings without the station)
not mentioned; §5-11 deferred to §14; §5-12 (old and new authorisation must never both manage a node; what the first
new-model image does to a v1.6-claimed node; what the old image in the other slot does with the new record after an
LKG fall-back — `provstore` parses strictly, fact 7) not mentioned — reviews v1-A M8, v1-B M7, v2-B M7 each raised
this; §5-13 only as Q-E. Also missing: which fields the v2.0 objects (#13's network config, #255 PR 3's enrolment)
must already carry (unit, generation, signer, subject) so v2.5 does not redo them.
Fix: for each, either a decision or an explicit "open, blocks #N" line; add the v2.0 / v2.5 format cut-line table.

**M8. §9.3 and §10 claim more for S-C than the platform gives.**
- "授權值只有開了簽過映像的這顆 CM4 算得出來 … 簽得出來 = 這台開的是我們簽過的映像". On a Pi the device secret is an OTP
  value the running OS reads (or asks firmware to use). Any root code inside a signed image — including the
  maintenance shell of §8.3 — can use it, and unless the read lock of #414 A19 exists and works on CM4 (unverified,
  V3) can copy it out for good. The honest claim is "a signed image was booted on this CM4, and no root code in any
  signed image has leaked the secret".
- "Signed" includes every image we ever signed. p1–p4 are not encrypted; a holder writes an old signed image there.
  §9.3 says the version floor stops this, but the floor that exists (`254-p3-impl.md` §3.7) is checked by the helper
  when an update is installed, not by the ROM / bootloader at boot, and before LUKS unlock there is no trusted place
  to keep it. To my knowledge BCM2711 has no rollback counter for `boot.img` (confidence about 75 %).
- §3.3 M3: the "revocation bit" I know of on Pi 4 / CM4 revokes the Raspberry Pi development key, not the customer
  key; there is one customer key hash in OTP and no rotation (confidence about 75 %, not checked against current
  docs). If so, a leaked boot signing key is permanent for every shipped CM4 — a risk-acceptance item for the user,
  not a detail for #115. §2 T4 "由 R 另行背書" has no effect on what the ROM accepts.
- Fix: narrow the two S-C rows to the claim above; move "old signed image" to the residual list with §10-14; put the
  boot-key-leak consequence in §15.

**M9. WireGuard binding (#16): the verifying key has no source, and the "count" breaks on a card swap. §4.3, §6 step 5.**
- A peer must check an N2 signature. N2 is bound to the node id only by the T1 signature on the certificate, and the
  baseline says nodes do not hold or check the root (`255-608b-config.md` §2, "節點不驗開發根的簽章 … 映像裡不必有開發根
  公鑰"). §17 test 1 ("量產節點都拒絕") assumes the opposite. Not decided.
- "計數" in the binding lives on the card. Card stolen or copied (S-A) then replaced by a spare: the new binding
  starts at 1; peers either refuse the honest node (lower count) or, if they accept lower, accept the thief's old
  binding. The node id cannot change, so there is no way out.
- "輪替：多久換一次、離線的節點回來時怎麼辦" (#16 input) is answered only by "可隨時重產".
- Fix: member-list entries carry each node's N2 public key (the admin's app already verified the certificate when it
  encrypted the pack); the binding covers network id + network version instead of a count, and is re-made at each
  rekey. Both remove something.

**M10. Lifecycle paths and resources that are missing. §7.1, §11.**
- #402 level 4 runs by itself (p5 damage / boot loop) and §9.3 has it clear the anchor: an event nobody authorised
  turns an enrolled node into one any QR holder can enrol. Who may trigger a reset, and whether an automatic one may
  drop the anchor, is not stated (threat model §8.1-8).
- Upgrade from v1.6 (owner-key record) to the first image with this model; downgrade / LKG fall-back to it (see M7).
- S-B → S-C on the same unit of hardware (placeholder LUKS key → derived key), and networks that mix bench (dev-root)
  and production nodes during the transition.
- CM4 replaced (S-C: chip bound to the old host). Only "換 HAT" has a row.
- "共同錨" (§5.5, second family phone): not a field anywhere; can either one bump the generation or replace the other?
  two bumps to the same generation with different content is a fork at the top.
- Repair: what is wiped before hand-over (§5-15 pitfall: on S-A the shop reads p5 — anchor record, log, and for a
  family the TAK CA key) and what is checked on return (pitfall: "用舊身分直接回網").
- Dependency restarts: only helper / provd / OTS. Missing: the #16 service (peer table when the helper is down),
  wpa_supplicant / hostapd, the chip not answering at the moment a floor must be read.
- Platform column: most rows are not split Pi 4 / CM4.

### MINOR

- **m1 (§8.2).** "This connection is BLE" is reported to the helper by provd, the non-root radio-facing process; a
  compromised provd or a live relay through another node defeats the proximity half. Say that presence proves a fresh
  signature by an authorised key and nothing about distance once provd is compromised.
- **m2 (§7.2, §12 K14).** "fail-open 只有一處" — the table has two more: revocation list missing → treated as empty;
  slot state missing → today's behaviour. List them with reasons.
- **m3 (§17).** Protections with no negative control: K3 (issuer-granted maintenance refused), K5 (object of another
  type / unit / network / node refused — four tests), K7 (anchor change, then old anchor refused), K10 (nothing
  secret readable at provd), K11, K13 (trial fail and LKG fall-back do not bring back a withdrawn key), K23 (shell
  closed after reboot; unreachable from mesh / Wi-Fi), generation skip / floor unreadable, presence (replay and relay
  over mesh), update authorisation for another node or another hash, WireGuard (no binding, non-member, removed
  member), state proof from a dev-root node not accepted as S-C, reset keep / clear table, replay after reset and
  after card swap (B1), audit write failure does not block.
- **m4 (§4.2 vs §5.4; §6 step 3).** "單位 = 信任錨公鑰的識別碼" against "單位 id 隨機、和錨金鑰無關". Step 3 checks "簽章者是
  它聲稱的錨" although §4.2 lets an issuer sign the enrolment (then the designation chain must be checked too).
- **m5 (§9.3).** The log and the list are kept across reset and therefore across a change of unit: the next unit's
  admin reads the previous unit's credential ids and actions (K24 "只有管理員" of which unit?). Where the log lives is
  not stated (#393 input "紀錄放哪").
- **m6 (§4.4, §8.1).** Family TAK CA key on the node's p5: on S-A/S-B any holder of that node can mint client
  certificates; account disable does not undo that. #52's input asks for one decision shared by "主控台、TAK、BLE、
  CLI"; §8.1 takes TAK out — fine under D5, but say it is a deliberate departure from the bullet.
- **m7 (§15).** Decisions that are the user's but are made in passing: Q2 (no new admin in the field) and Q5 from
  `255-key-authority.md` §7 are not carried over; a counter as a requirement on the #426 chip; a new reset-proof
  storage region; standing maintenance credentials on field phones; the boot-key-leak consequence (M8). Q-D is asked
  of the user although it is technical.
- **m8 (§8.3, §3.2 A5).** "自己結束": a root shell can leave anything behind on p5 / overlay; tmpfs only removes the
  key we installed. Say what K17 covers after a maintenance session (S-C with read-only rootfs: p5 contents).
- **m9 (§5.4).** Old anchor leaked rather than lost: attacker and owner each sign "new anchor" at generation + 1; the
  first to reach a node wins and nodes diverge. Baseline residual for a root leak, but the section reads as if
  rotation recovers from it.
- **m10 (§5.5, Q-C).** The single-phone family recovery is exactly the listed pitfall of §5-3 and of #95's input
  ("不能靠機身 QR 導出的永久秘密"). It may be the right trade under U9, but Q-C should say the bullet is not met.
- **m11 (§4.3 vs baseline).** N2 gains two new signing purposes (WireGuard binding, state proof) beyond the single
  `Session` purpose of `255-608b-impl.md` §2.1. Fine as a list, but it is a change to a reviewed interface and should
  be listed as such for #255 PR 3.

Disagreements with baseline decisions: none.

## Field walk-through

| Scenario | Result |
|---|---|
| Fire squad, 8 nodes, ICS as issuing station | Gap: grants lock each other out (M1); members finding their node / Wi-Fi not covered (M7, §5-10); station limits not covered (§5-9) |
| Family, 4 nodes, one parent phone | Works for set-up (A1 = admin). Second phone as "共同錨" undefined (M10) |
| Node lost in the field | Partly: new config + rekey (§5.2); delivery and "how long until every node knows" not given (M7); holder is a member until then (stated honestly, §17) |
| Admin phone lost | Gap: only A1 / issuer can revoke; with the station unreachable the finder's grant stays valid and the phone key has no user authentication; set-of-2 deadlock (M3); K11 gap (M4); durable revocation = unit-wide bump (M6) |
| SD card dies, spare card | Gap: same node id, unenrolled; sequence memory and list gone → replay (B1); WireGuard count (M9); floor per B2; squad cannot re-enrol in the field (Q-E) |
| Off for a month, password changed twice | Partly: latest config + pack suffice only if M1 is fixed; admin-set chain (M3) and bump chain (M6) need history |
| Sold to another unit | Gap: Q-D unresolved (B2); previous unit's log and list travel with it (m5); seller knows the QR for ever (U9, accepted) |
| Sent for repair | Partly: removed from lists + rekey (§11); what to wipe before, what to check after not stated (M10) |
| Two admins on two sides of a split | Gap: described behaviour cannot occur (M2, M1) |
| OTA fails trial, rolls back | Works in steady state (state in p5, shared by both slots; helper refuses changes in trial, `node.go:258-259`). Gap for the first image that carries this model (M7) |

## Input bullets

| Issue | Bullet | Result |
|---|---|---|
| #13 | what admission checks; which root | Covered (§4.1, §6, §2); node-to-node verification key open (M9) |
| #13 | which layer; split with #16 | Covered (§6 step 5 and boundary) |
| #13 | revocation offline; latest time to know; survives reset | **Not covered**: no bound; floor open (B2) |
| #13 | password change delivery incl. powered-off; who starts it | Who: covered. Delivery: **not covered** (sent back to #13) |
| #13 | replace `CHANGE-ME-NOW`, fail-closed | Covered (§6, §17-7) |
| #13 | chip-independent | Covered (§4.1), except the counter (B2) |
| #16 | where the WireGuard key lives, who reads it | Covered (§3.1 N6) |
| #16 | binding to identity; re-key flow | Partly (M9) |
| #16 | peer list source; removal on revocation | Covered (§6, §7.1) subject to M9 |
| #16 | rotation; returning nodes | **Not covered** |
| #16 | traffic outside WireGuard (PTT) | Covered as a stated residual (§6) |
| #52 | where roles and attributes live | Covered (§4.2) |
| #52 | admin set; K18; §5-2; §5-5 | **Not covered** (M3, M4, M2) |
| #52 | clubs | Not covered (§14, deferred) |
| #52 | one node, several networks | Covered at field level (§4.2) |
| #52 | one decision point incl. TAK | Covered except TAK (m6) |
| #52 | withdraw one role only | **Not covered**: revocation names a key or node id; re-issue needs per-subject order (M1) |
| #54 | issuing station limits (§5-9) | **Not covered** |
| #54 | field without the station; ceiling; Q4 | Partly (Q-E); "how long" has no expression |
| #54 | TAK CA separate | Covered (§2, §4.4, §0) |
| #54 | enrolling a new node: evidence, signer | Covered (§6 step 3), see m4, B1 |
| #54 | member finds own node (§5-10) | **Not covered** |
| #54 | zeroize; revoke client | Revoke: covered (unverified V6). Zeroize: **not covered** |
| #95 | lost = revoke + re-issue; node id continuity | Covered (§3 principle, §9.3) |
| #95 | root backup: shares, where, who | Partly (Q3 only) |
| #95 | phone lost without permanent QR secret | Not met for one-phone family (m10) |
| #95 | inventory; time until revocation is effective | **Not covered** |
| #95 | repair and scrapping | Partly (M10) |
| #95 | factory reset vs recoverable loss | Covered (§9.3 vs §5) |
| #97 | what attestation proves, per platform | Covered (§10); S-C overstated (M8) |
| #97 | workload identity: which branch issues it | **Not covered** (publisher key only; allow-list type and role are not in §4.2) |
| #97 | image signing key vs publisher key | Covered (M5 key separate) |
| #97 | key release bound to attestation (#47) | Partly (N7 only) |
| #97 | cross-agency | Not covered (U5, deferred) |
| #393 | authorisation + presence field | Covered (§4.2, §8.2) |
| #393 | presence method | Covered, with m1 |
| #393 | update authorisation vs image key | Covered (§9.1) |
| #393 | maintenance shell | Partly (M5, m8) |
| #393 | refused actions logged: where, who reads | Partly (owner yes, place no) |
| #196 | slot → key | Covered (§3.1; matches config §2–§3) |
| #196 | TAK mTLS key not in the chip | Covered (§4.4) |
| #196 | dev root vs production root | Covered (§2, §17-1) |
| #196 | burning and signing | Covered (§6 step 1, §11) |

## K1–K25

Real: K1, K2, K5 (given M1's subject field), K7 (mechanism sound; note m9), K9, K12, K14 (with m2), K16, K20, K21, K22.
Counter-example found: **K3** (M5), **K4** (B1, M1), **K6** (B2), **K8** (B2(a); also one admin sending each node a
different password leaves every node reachable only by BLE, which the document does not list), **K11** (M4),
**K13** for the transition image (M7), **K18** (M3).
Asserted only: K10 (M4), K17 (m8), K23 (no test, m3), K24 / K25 (place of the log not given).
K19: no counter-example beyond the shared layer-1 password, which §6 states. K15: correctly deferred to measurement.

## Citations and facts checked

| Item | Result |
|---|---|
| `release/release.go:1-4` (R endorses K, K signs; test root T in bench build) | held |
| `node/wtxn.go:121-135` (COSE-signed secrets, target = hash of node key, net id / version as KDF context) | held |
| `node/node.go:1242-1311` (wireless transaction, back to previous state) | held |
| `node/node.go:258-259` (trial slot refuses state changes) | held |
| `provstore/provstore.go:9` (one `net` per record) | held |
| `keystore/keystore.go:78-98` (fixed signing purposes only) | held |
| `storage-architecture.md:21-26` (p1–p6) | held; no reset-proof region outside p5 / p6 exists |
| `KeyPolicy.kt:64-66` (hardware level required) / `Keys.kt:64-98` (no user authentication) | held |
| `255-608b-config.md` §2–§3 (slots 0 / 1 / 2 / 5 / 8) | held |
| `255-608b-config.md` §4 "counters exist, unused" | held — and v4 removed the counter on purpose; impl §2.2 excludes the Counter command |
| `255-608b-impl.md` §2.2 (flock on `/dev/i2c-N`), §3.1 (≤ 416 bytes), §3.2 (`trust_gate`) | held |
| `docs/threat-model.md` "one PKI, two populations" exists and predates D5 | held (line 36) |
| 608B counter: 2 counters, max 2,097,151, usable after lock, no reset | held (608b-facts §7; my confidence high) |
| 608B counter increment needs no authorisation | held as documented inference (608b-facts §7, U11); my confidence about 85 %; not tested on a chip |
| 608B counter may jump by more than one on power loss | held (608b-facts §7) |
| WireGuard authenticates peers by static Curve25519 keys; a signed out-of-band binding is workable; no multicast inside | held (general knowledge, high confidence); the key source for verifying the binding is not defined (M9) |
| SAE mesh password is shared; batman-adv does not authenticate OGMs; any device with the password joins layer 1 | held |
| Pi 4 / CM4: OTP holds a hash of the customer boot key, irreversible; no measured boot | held (high confidence) |
| Pi 4 / CM4: customer boot key can be revoked / more than one key | could not verify; I believe no (about 75 %) |
| CM4: device secret usable only by a signed image; read lock; `rpifwcrypto` on CM4 | could not verify (V3 open); root inside a signed image can use it in any case |
| `254-p3-impl.md` §3.7 version floor | section exists; I did not re-read its mechanism in full — the claim that it is checked at install, not at boot, is from the helper code path (`update.*` verbs), not from a boot-script read |
| TAK does not check CRLs | could not verify (V6) |
