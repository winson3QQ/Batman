# #255 design v2 — round 2, Reviewer B (field use, lifecycle, feasibility)

Reviewed: `docs/design/255-threat-model.md` (v1) and `docs/design/255-key-authority.md` (v2), whole documents, against
main 4eba26d. Checklist: `docs/design/REVIEW.md`. Read-only; no device contact. Paths below: node code relative to
`feed/batman-prov/src/`, app Rust relative to `app/rust/batman-proto/src/`, unless a full path is given.
I formed my findings before reading `255-reviews/v2-changes.md`, then checked round-1 closure (section "Round-1
findings not closed").

What is sound and should stay: threat model first; fixed chain shape (R2); trust list signed only by the anchor (R1);
fresh in-session op to enter a network (R9, matches `node/node.go:774-787`); no unit-wide symmetric key; no mesh relay
decided here; 608B before the trust model. The §1 facts I re-checked against source are correct (list at the end).

Time and size numbers I give are my own estimates unless a source is cited; none were measured.

---

## BLOCKER

### B1. §4 is not a sufficient or correct input for locking the 608B config zone

Locking is irreversible and §4 is declared to be "the input". Three separate defects.

**(a) The S2 recovery path needs something §4 forbids.**
Scenario: phase 1 locks the chip with the claim secret as "不可讀；只能 CheckMac" (§4 row 3; `219-field-provisioning.md`
§4: `IsSecret=1`, `NoMac=1`, CheckMac only). Phase 3 implements §3.6 "復原路徑": the new phone scans the body QR and
"用認領秘密導出的 PSK 做交握". A claimed node only accepts NXpsk0 and the PSK candidates are values the helper hands to
provd (`provd/server.go:738-767`, `node/node.go:436-456`). The helper therefore has to *compute* a PSK from the claim
secret. With a CheckMac-only slot it cannot: the chip never releases the secret or any function of it other than a
yes/no. The recovery path (and A7's "QR 復原 1" candidate) is unimplementable on chips locked per §4; S2 then falls
back to "全部重燒" plus the SD marker — i.e. today's outcome.
Fix (narrow, no new mechanism on the wire): decide now, before the lock, one of
(i) a second chip slot holding a factory-written value derived from the claim secret (e.g. HKDF(K, "qr-login")),
readable by the host, write-once then slot-locked — the QR stays `{device_id, K}`; or
(ii) permit one derivation command on the claim-secret slot and accept that root on the node can then compute claim
responses for its own chip. (i) keeps the "root never learns K-equivalent claim material" property; state which.

**(b) "Reserved" slots cannot be reserved without choosing their access policy now.**
§4 last row: "≥2 個私鑰槽、≥2 個資料槽 … 可在鎖定資料區後再個別寫入並鎖定". Whether a slot is secret or
host-readable, clear-write / encrypted-write / never-write, which commands may use it, and whether it is individually
lockable are all SlotConfig/KeyConfig bits in the config zone. After the config lock a "reserved" public-read slot can
never become a secret (the stated future use "晶片與板子的綁定" needs a secret usable for MAC/KDF; (a)(i) needs a
readable one). §4 names no policy per reserved slot, so the lock experiment has nothing to lock them to.
Fix: give every slot (used and reserved) a concrete row: key type, readable?, write policy after data-zone lock,
permitted commands, individually lockable. Reserve by policy class (e.g. 2 × "private key, GenKey allowed until
slot-locked", 1 × "secret, never read, MAC/KDF allowed", 1 × "public, write-once, readable").

**(c) Config-zone decisions the later phases depend on are not in §4 at all.**
- ECDH output: clear on the bus, or protected with an IO-protection key (needs its own slot + ChipOptions bits).
  `219-protocol.md` §7.3 and its Q4 leave "`ECDHPROT` 與 IO protection key 的存放在 B1 決定"; §4 is that decision
  point and is silent.
- Claim-secret write policy: "never" means the secret printed on the body can never be rotated (resale; a
  photographed QR, T7). `219-field-provisioning.md` F1 lists "認領秘密輪替" as a later tactical item. Either choice
  is defensible; it must be chosen and written here.
- The second monotonic counter: the 608B has exactly two. §4 uses one. State that the other stays unused and
  unattached to any key-use limit (so a later tier can use it, e.g. as a rollback floor for p5).
- Clock/watchdog mode and I2C address are config-zone bytes; A2 itself marks "預設時脈模式 ❓". They are fixed at
  lock, so the ❓ must be closed before, not "第 1 期第一步實測" after.
- Where the node's identity certificate / public-key commitment lives so that "重燒 SD 身分還在" (see M1).

Evidence for all three: design §3.6, §4, A1, A2, A7; `219-field-provisioning.md` §4 and §8 step 1;
`219-protocol.md` §7.3, §12 Q4; `provd/server.go:738-767`.
The design already says "動手前問" before locking. That is a gate on the action; the content of what gets locked is
what is missing.

### B2. Replacing PRIMARY (S2 recovery, planned root roll-over) orphans every network and every unit-bound object

Scenario (family, S2, the headline of phase 3): the parent's phone is lost. The new phone scans the recovery card and,
node by node, delivers "換掉 PRIMARY". Now on each node:
1. §3.2 defines 單位 id = "信任錨公鑰的雜湊". The anchor key changed, so the unit id changed. Every stored object
   carries the old unit id inside its signature (R4): node certificate, `net_state`, revocation lists.
2. §3.4: the node recorded the network's 授權者 = "鏈最上層的那把信任錨" (the lost key), and an update is accepted
   only if "最上層 = 該網路記下的授權者" (R11). The new PRIMARY is not that key. The existing network can no longer
   be updated or re-keyed by anyone — in exactly the case (lost phone, T4) where a re-key is the required next step.
3. The only way out is `network/leave` + a fresh join of a new network on every node (PRIMARY may do anything), which
   the document neither states nor counts in S2's cost.
Same for the squad: §6.1 "換根" (planned every ≤3 years) lists new node certificates and re-issued person
certificates but says nothing about networks. Worse, roll-over is node by node over weeks: a `net_state` carries one
授權者 key id and one unit id inside the signature, so during the roll-over no single update is acceptable to both
rotated and not-yet-rotated members of the same network. The network cannot be re-keyed for the whole roll-over.
It is also undefined which unit id the "換掉 PRIMARY" list itself carries (old, so the node recognises it, or new).

Evidence: design §3.2 line "單位 id（信任錨公鑰的雜湊）"; §3.4 "進入新網路" / "更新已在的網路"; §6.1 換根 row;
threat model R4, R11.
Why BLOCKER: the unit id and the authority binding are signed format fields — the things this document exists to
fix — and as defined they break both anchor-replacement paths the document promises.
Fix (narrows, adds nothing): (1) unit id = a random identifier fixed when the unit is created, carried in the signed
trust list; "換掉 PRIMARY" keeps it. (2) The network's recorded authority = a *role in the trust list* ("PRIMARY of
this unit", or one specific NET_ONLY key), not a key. Then PRIMARY replacement leaves networks, node certificates'
unit binding and revocation lists untouched; only signatures made by the old anchor (issuer certificate, directly
signed certificates) need re-issuing. State the roll-over order for a squad (issuer certificate re-signed first and
carried with the new trust list, so a rotated node is never left with "no acceptable chain").

---

## MAJOR

### M1. Phase 1 cannot ship with "上層協定與 app 流程不變"; the device_id / QR binding to the chip key is undecided

Scenario: phase 1 node with a 608B, today's app.
- `219-protocol.md` §3.3: "608B 後端 `sn` = 晶片序號". The on-chip CheckMac mixes the chip's own SN bytes
  (`proto/proto.go:54-70`), so the wire `sn` has to be the chip serial for the phone's response to match.
- The app refuses every identity that is not a self-signed `dev:` certificate (`nodecert.rs:147-156`) and its dev rule
  requires `device_id == SHA-256(DAC pub)[:9]` (`nodecert.rs:177-190`). A chip-serial `device_id` fails it. So the
  app's trust rule or the id derivation must change in phase 1 — that is an upper-protocol change.
- More important than the wording: with `device_id` = chip serial, the QR `{device_id, K}` (`254-app-qr.md` §1) no
  longer commits to the identity public key. `219-protocol.md` §3.3 made the hash check a MUST for exactly this
  reason ("任何看過 QR 的人都能自簽一張同 CN 的憑證"). Anyone who has photographed the body QR (T7: repair shop,
  previous owner) can stand next to the buyer, answer as that node with a software key, pass CheckMac (they know K),
  be enrolled, and in phase 2 receive a node certificate and the network password. R5 says the node certificate
  "綁定晶片公鑰" but nothing tells the enrolling phone that the key it sees is the chip's.
- Phase 1 prints body QRs ("開發用出廠燒錄與印 QR") and the document promises "同一張 QR 有效" from then on.

Fix: decide in this document (a) how `device_id` is derived for the 608B backend and (b) what in the QR commits to
the chip's identity key — simplest: keep `device_id = SHA-256(identity pub)[:9]` for both backends and carry the chip
serial bytes CheckMac needs as a separate, unauthenticated field. Then the existing TOFU rule holds unchanged and the
QR format survives. Also say where the self-signed identity certificate is kept so it survives an SD reflash (the
chip signs with a random nonce, so a regenerated certificate has different bytes; `ClientChal` hashes the DER,
`proto/proto.go:48-52`). Reword the phase-1 claim to list the real app/protocol deltas, including the claim-window
prompts if the "曾被入庫" gate lands in phase 1 (see M6).

### M2. "New state reaches every node by phone, nobody copies anything" does not hold with per-node identification keys

Walk of S6 (squad, 8 nodes, node 5 lost). Admin A signs v+1.
- A's phone delivers to nodes it can reach by BLE. For the others §3.6 says "任何一支有權登入它的手機自動補送",
  and that phone gets the state from "管理員手機、ICS 同步、或任何一台已更新的節點（VIEW 即可讀…）".
- A member's phone holds the identification key of its own node only (§3.6: "隊員 = 被指派的那幾台"). Without
  another node's key it cannot even start a handshake with it (`provd/server.go:738-767`), so "任何一台已更新的節點"
  is not reachable for members. ICS sync has no defined link (§5.2 ❓) and S9 allows it to be down. Phone-to-phone
  transfer from the admin is not specified anywhere.
- Result: only administrators can deliver. For 8 nodes one admin walks to 7 firefighters; for 30 nodes, 29. My
  estimate is 20–60 s per node for connect, login, a 2–5 KB transfer and apply, so roughly 5–10 min (8) or 15–30 min
  (30) plus the walking, with the mesh split into "updated" and "not yet" the whole time.
- Today (`rekey.rs:1-10`, `updflow.rs:1-12`): the admin hands each person a bundle over any channel and each person
  presses one button at their own node. That is clumsy but parallel and needs no walking. The new flow is serial and
  administrator-bound unless a phone-to-phone path exists. Against U2 this is a regression that the document presents
  as an improvement.

Fix: `net_state` is already a self-contained replayable object, so no new node mechanism is needed. Decide the
phone-side transport: the state travels as a file/QR/any messenger from an admin phone to member phones (as the
bundle does today) and the member's app delivers it to its own node automatically on next contact. Remove "任何一台
已更新的節點" as a source for members, or say that it applies to administrators only. Put the 8- and 30-node cost and
the split duration in §3.6 as acknowledged numbers.

### M3. S4 is not walkable for members: nobody delivers the identification key and the node-scoped USE certificate at turn-out

Walk: a station holds 8 pooled nodes; the crew grabs radios at the alarm. "隊員：選出自己身上那台（一次）".
To see status and set the phone Wi-Fi the member's phone needs (1) that node's identification key, (2) a USE
certificate whose node scope contains that node (§3.3 rule 4), issued by ICS. Both come "隨清冊同步" from ICS, whose
link is undefined and which S9 says may be down for a week "不受影響". If assignment is static, a member who takes a
different radio today (flat battery, radio in repair) has no access to it. If it is dynamic, every turn-out depends on
ICS being reachable in the minute after the alarm. Either way "打開 app 就看得到" fails in an ordinary case, and S9's
"建網、換密碼不受影響" hides that member access *is* affected.
The administrator-takeover half of S5 has the same dependency: the second administrator can only reach nodes whose
identification keys were in their last sync.

Evidence: design S4, S9, §3.3 rule 4, §3.6 second bullet, §5.2 ICS row.
Fix (prefer removing over adding): choose the assignment model here. Simplest that works offline: USE scope may be
"all nodes of this unit's station/pool" issued once at enrolment of the person, and an administrator hands a node's
identification key to a member phone in person (or the member scans the body QR and uses the QR login path, if B1(a)
is solved). State what a member cannot do when ICS has been down since before their assignment.

### M4. Per-use user authentication on the anchor and NET keys makes ordinary flows harder than today, unacknowledged

R15 / §3.1: the family anchor key and every NET key require user authentication "每次使用". §3.6: after the
handshake "手機金鑰簽交握雜湊並附鏈" — i.e. every login is a use.
- Family, 3 nodes: opening the app to look at status = 3 biometric prompts, again after each BLE drop. Today: none
  (`Keys.kt:93-98`).
- Admin, 8 nodes: 8 prompts to view the team; a re-key = one login + one op per node = 16 prompts; 30 nodes = 60.
- Android side effects not mentioned: a phone with no secure lock screen cannot create such a key at all; enrolling a
  new fingerprint invalidates auth-bound keys by default — for the parent that silently destroys the trust anchor and
  forces the recovery path; for an admin, a new enrolment at ICS.
This is a new cost and two new failure modes against U2, none listed in §7 or A3.

Fix (narrowing): require user authentication only where T4 matters — state-changing op signatures, certificate
issuing, trust-list signing — and let login/status use a separate key with a VIEW-level certificate and no prompt; or
specify a short validity window instead of per-use. Decide the invalidation-on-enrolment setting and the "no lock
screen" behaviour here; they change what S1 looks like on day one.

### M5. The (version, hash) order converges on bytes but lets a stale administrator silently undo a removal, and "sign a higher one" has a ceiling

**(a) Concurrent / stale edits.** Two administrators at two ends of a partitioned mesh, both at v5. A removes lost
node X → 6A. B, unaware, removes Y → 6B (X still listed). After merge every node that receives both keeps the one
with the larger hash. If 6B wins, X — the lost node — is a member again and its entry holds the new password
encrypted to its key. If A then signs v7 from its own view, Y returns. `net_state` is a full state with no link to
the state it was derived from, so nothing detects a stale base; today's chain refuses it (`node/node.go:1200-1202`,
"chain not contiguous"). Also: the two halves hold different SAE passwords, so they do not merge by radio; a person
has to carry the winner to every losing node, and no flow tells either administrator that their edit lost.
v2-changes records this as a MINOR that is "stated"; §5.1 states convergence only, not the security effect.
Fix without a new node mechanism: `net_state` carries the hash of the state it was derived from (informational; the
node ignores it). The admin app refuses to sign unless it has read the current state from a node in this session,
builds the new member list from that state, and on seeing a same-version sibling or an unexpected parent shows "另一位
管理員也改過，請確認名單" before signing the next version. Removal of a lost node is also recorded as a node-
certificate revocation so the other admin's app (R13 check) refuses to list it.

**(b) Ceiling.** §3.4 / R12: "被盜金鑰把版本推高時，合法管理員簽更高的即可"; "合法授權者永遠能…收回控制". T4 signs
version 2^64−1. No higher version exists; the tie-break is the object hash, which the thief can grind as well as the
owner. From then on that network id can never be updated on any node that saw the object. Recovery is leave + fresh
join of a new network id on every node, by an administrator in person (it is not a replayable object, so members'
phones cannot help). R12 and its test row are therefore wrong as worded, and S5 needs this path written down.
Fix: state the recovery (new net id) in §3.4 and §7.2 and correct R12 to "…或改建新網路"; do not add a window.

### M6. Enrolment: the chip counter and the p5 record are not "同一個交易", and two dead-end states follow

§6.2 入庫: "寫信任清單、產生識別金鑰、計數器 +1，同一個交易；之後才收節點證書".
- Today the counter is a field of the record and commits atomically with the claim (`node/node.go:592-595`). In the
  chip it is a separate device write. Power loss between the two leaves either (i) counter bumped, node still
  unenrolled — the counter is also the "曾被入庫" flag (§4), and `219-field-provisioning.md` §6.1 closes the claim
  window on ever-claimed nodes until a button or SD marker; the HATs on hand have no button (219 §8.5 H2). A brand
  new node that lost power once during first enrolment now needs its case opened; or (ii) record committed, counter
  not bumped, and a later bump invalidates the node certificate that was issued in between. Neither order nor
  recovery is stated. Owner of the pair (REVIEW.md item 1) is two devices with no stated reconciliation.
- Squad: after the trust list is written and before the node certificate arrives, the node "只接受 PRIMARY 本人的
  動作" — PRIMARY is the offline root. If the phone loses its ICS link at that moment (S8 conditions), the node is
  enrolled, unmanageable, and it is not stated which verbs still work so that a node certificate and the revocation
  lists can be delivered later (login itself presents a chain, which is refused).
- The same "ever enrolled" gate hits the bench: validation reflashes cards routinely; from phase 1 every reflash of
  a 608B node needs the marker.

Fix: define the order (bump first), make "ever enrolled" derive from "counter > factory value AND no button", and say
what an interrupted first enrolment looks like to the user. State that in the "enrolled, no valid node certificate"
state the node accepts, without a chain, exactly: node certificate, revocation lists, trust list (all self-verifying
objects) and read-only info. Decide whether the claim-window gate is phase 1 or phase 3 (§9 says "第 1、3 期").

### M7. OTA rows: the post-commit hook does not exist, there are two commit paths, and conversion contradicts "no migration"

- A9 checked: `feed/batman-provision/files/usr/bin/batman-autocommit` runs `batman-slot commit`, writes its marker
  and exits (the `if batman-slot commit; then … exit 0` branch, line 621). There is no hook. A commit can also be made by hand (`batman-slot commit`, logged
  as COMMITTED-BY-OPERATOR, same file near the end), which a hook in autocommit would miss. What does exist: the
  helper already asks `batman-slot is-trial` and refuses state-changing verbs during a trial
  (`node/node.go:250-259`; rc 2 = unknown must count as "still trial").
- §6.2 says the new helper converts old → new format after commit; the paragraph under it says the app writes no
  migration and bench nodes re-enrol. These cannot both be the plan: a converted node needs an identification key the
  phone already holds (none was "returned in the enrolment session"), a PRIMARY (the old owner key?), a node
  certificate (nobody issued one → "accepts only PRIMARY"), and an app that speaks both formats across the
  trial/revert boundary.
- During the trial the new helper must not only read the old record but run the old login and status paths, because
  autocommit's health gate needs the helper up and reachable. That keeps the old authorisation code in the new image.
- If instead every node re-enrols at phase 2, a reset path is needed, and factory reset is phase 3. In phase 2 the
  only reset is reflash + SD marker.

Fix (remove, do not add): no in-place conversion. The phase-2 helper reads a v1 record read-only; during the trial it
behaves as today; after commit (detected by `is-trial` = 1 at helper start) a v1 node is reported as "需要重新入庫"
and accepts only enrolment by body QR. R18 holds trivially, R19 becomes "re-enrol", A9 disappears, and §6.2's two
rows and the app paragraph agree. Move the minimal "wipe to unenrolled" action into phase 2 or state the reflash
procedure as the phase-2 reset.

### M8. Secure element not answering, swapped, or blank: rows are missing and R21 contradicts the existing decision

- `254-stage1-impl.md` line 215: "`backend=se` 而 608B 不回應 → helper 拒絕啟動(fail-secure)". R21 / §6.2 say the
  node keeps running and only refuses new settings. One of them must be withdrawn explicitly.
- Walk of R21: the identity proofs are signed by the chip at every boot (`219-protocol.md` §3.3: "每次開機只簽兩
  次"). No chip → no `node_cert` → no login of any kind (`provd/server.go:530-541` needs it). So the node cannot be
  viewed, cannot be given a new password (decryption is chip ECDH, `keystore/keystore.go:60-61`), and drops off the
  mesh at the next re-key. The R21 negative control "晶片不回應時送新設定" passes vacuously: no session exists to
  send it in. What the user sees and the repair path (new HAT = new identity = new enrolment, which for a squad needs
  ICS) are not stated.
- Missing rows: transient I2C failure at boot on a bus shared with other parts (retry or stay unmanageable until
  reboot?); HAT replaced while the SD card keeps trust list, node certificate and network bound to the old chip; SD
  card moved to another node; a blank or config-unlocked chip on first boot; a phase-1 image on a node whose
  `backend` file says "file" and vice versa (`keystore/keystore.go:266-267` refuses the other backend today).

Fix: one row each in §6.2 with the behaviour and the user-visible state; choose between "helper refuses to start" and
"runs, unmanageable" and say why; make the R21 test observable (e.g. chip removed after boot: a new setting is
refused, and after reboot the node still joins its mesh).

### M9. `update/*` and `bulk/*` under MAINT makes squad software updates depend on the offline root

§3.4 maps software update to MAINT; MAINT is node-scoped and "只能由信任錨直接簽" (R3); the squad anchor exists only
in ceremonies (D11). Updating 30 nodes therefore needs a root ceremony that issues node-scoped MAINT certificates to a
maintainer's phone; a new node or a replaced phone needs another ceremony. With no clock these certificates never
expire, so the routine outcome is long-lived root-equivalent certificates on field phones, or nodes that do not get
security updates. Either lowers security. The image is already authenticated by the release chain (fact 15), so
triggering an update does not need root-equivalent authority.
The document defers this ("第 2 期實作設計決定"). That is acceptable only if the right can move without changing a
frozen format; D4 fixes the rights as four.
Fix: decide here that starting an already-signed update is NET (or state that the rights field is an extensible set
and unknown rights are refused, so a later UPDATE right is not a format break). Keep MAINT for SSH keys and root
password only.

### M10. Revocation list capped at 128 per issuer for a whole agency, with an agency-wide re-issue as the overflow path

A squad has one issuing key for everyone (§3.5). S12: every lost phone, replaced phone or reinstalled app is one
revocation. An agency of a few hundred phones will pass 128 within a year at ordinary replacement rates (my
estimate; the document gives no sizing). The overflow path is "世代 +1": every person certificate dies at once on
each node that receives the new list, issuing is "當面" (§6.1), and every node must be visited to deliver the list.
The 129th lost phone triggers a re-report of the whole agency. The yearly bump has the same per-person, per-node cost
and that cost is not stated anywhere. It is also not stated whether node certificates carry a generation and die
with a bump.
Fix: state the design target (people and nodes per issuer), size the cap from it (the 64 KiB record leaves room), say
whether renewal of an existing key can be done without a face-to-face step, and exclude node certificates from the
generation floor explicitly (they are bound to the counter already).

---

## MINOR

- **m1. Capability gap between phase 2 and phase 3.** Phase 2 replaces the update bundle and +1 chain with
  `net_state` and removes the three-step flow; removal and re-key arrive in phase 3. In between there is no way to
  change a network's password. Say so in §9, or move re-key into phase 2.
- **m2. Recovery card.** How a family produces a paper QR holding a private key is not described; the realistic
  outcome is a screenshot in a cloud photo library. Q3's default could be "指定家人手機" (no exportable key).
  Separately, threat model R16's residual "用卡再換回來" is wrong: whoever holds a copy of the card can also sign
  the replacement of RECOVERY (§3.2 requires only RECOVERY's own signature for that), after which the parent's card
  is dead and only a physical reset remains.
- **m3. Verbs without a right.** §3.4's table omits `reset`, `diag/*`, `peers/challenge`, `owner/add`,
  `owner/remove`, `claim/*`, `op/nonce`, `auth/owner` (`provd/session.go:60-66`). In a squad nobody in the field can
  factory-reset a node (PRIMARY only); say that this is intended.
- **m4. Chain bytes per action.** "每次動作都重驗" (R8): say where the chain bytes live during a session (provd
  memory, passed to the helper with each request) so the phone does not resend ~0.5 KB per action over BLE; give the
  login size (handshake + 2 certificates + revocation check) next to the `net_state` sizes.
- **m5. Exposure.** VIEW can read the signed `net_state`, i.e. the full roster and wireless parameters; an
  administrator phone holds the identification keys of every node in the unit, so one stolen admin phone makes all of
  them recognisable until each is visited and rotated. Both follow from the design; list them in the threat model's
  "做不到的" with the rotation cost. Also state that a node keeps old and new identification key during a rotation
  (two of the six candidates) so administrators who have not synced are not locked out.
- **m6. Country.** Today an in-network update that changes the country is refused (`node/node.go:1208-1212`).
  "無線參數" in a replayable `net_state` should keep that rule explicitly.
- **m7. Threat-model §7** has no negative control for R5, R10, R13, R19, R20.
- **m8. App records after phase 1.** Both bench nodes get new ids; the phones keep records and pending items for the
  old ids. One line on how they are cleared (the existing "從這支手機移除這台節點", or reinstall) avoids a stale-
  record surprise during bring-up.

---

## Round-1 findings I consider NOT closed

| Round-1 | Status in v2 |
|---|---|
| B-M6 (recovery card cannot reach nodes) | Reworded, not closed: the new path needs a PSK the chip cannot produce (B1(a)), and after it succeeds the network is orphaned (B2). |
| A-M9 (root roll-over / anchor replacement) | Not closed: one-step replacement is defined, its effect on unit id, networks and stored objects is not (B2). |
| B-M9 (member's view depends on things nobody delivers) | Text corrected, dependency remains (M3). |
| B-M7 / A-M8 (OTA, downgrade, app migration) | Partly: revert is safe; conversion-after-commit is unspecified and contradicts "no migration"; A9 is still ❓ and its answer is "no hook" (M7). |
| A-M2 / B-M1 (+16 window) | Window removed, but the exhaustion case it was guarding is answered with "sign a higher one", which fails at the ceiling (M5(b)). |
| B-M8 (manual path the design set out to remove) | Mesh relay correctly deferred; the replacement "phones carry it" has no phone-to-phone leg, so for members it is less than today's manual path (M2). |
| B-M11 (phase 1 self-contained) | Reordered, but phase 1's "protocol and app unchanged" is not true (M1) and its lock input is incomplete (B1). |
| B-B3 (per shipped flow: kept / re-implemented / removed, in which phase) | Partly: removal is stated; the phase 2→3 gap is not (m1). |
| B-m6 (concurrent admins) | Marked "stated"; the security effect is not (M5(a)). |
| B-B1, B-B2, B-M2, B-M4, B-M5, B-M10, B-M12 and A-B1, A-B2, A-B3, A-M1, A-M3–M7 | Closed as far as I can check from the two documents. |

---

## Wrong or unsupported statements

1. §9 phase 1 "上層協定與 app 流程不變" — contradicted by `nodecert.rs:147-156`, `:177-190` and `219-protocol.md`
   §3.3 (M1).
2. §3.6 "用認領秘密導出的 PSK" together with §4 "只能 CheckMac" — mutually exclusive (B1(a)).
3. §6.2 "…計數器 +1，同一個交易" — a chip write and a file commit are not one transaction (M6).
4. §3.6 "或任何一台已更新的節點（VIEW 即可讀…）" as a source for any phone — members hold no key for other nodes (M2).
5. Threat model R12 "永遠能用簽一個更高的版本收回控制" — false at the maximum version (M5(b)).
6. Threat model R21 / §5.2 "晶片無回應 → 不接受新設定，現有網路照常" — conflicts with `254-stage1-impl.md:215`,
   and its test cannot reach the code it checks (M8).
7. Threat model R16 residual "用卡再換回來" (m2).
8. A9 "未查": answer is in the tree — no post-commit hook; two commit paths; `is-trial` is available to the helper
   (M7).
9. §9 phase 1 "provd 啟動不再白等約 11 秒（7058803985…）" — the reference resolves to nothing in this worktree;
   unverifiable here, mark ⚠️.
10. A2's unknown clock mode is itself a config-zone choice, so it cannot stay ❓ until after the lock (B1(c)).

§1 facts re-checked and found correct: 1 (`keystore/keystore.go:42-46, 111-131, 182`), 2 (`proto/proto.go:54-70`),
3 (`Keys.kt:64-74, 93-98`), 4, 5 (`node/node.go:705-746, 778-779`), 6, 7 (`provd/noise.go:17-21`,
`provd/server.go:738-781`, `proto/proto.go:158-160`), 8 (`node/node.go:444-448, 639, 653-672`), 9, 10
(`provstore/provstore.go:66, 112-131`), 11, 12 (`rekey.rs:1-10`, `updflow.rs:1-12`), 13
(`keystore/keystore.go:68-69, 266-267`), 14 (`node/node.go:587-609`). Fact 15 and the ICS statements not checked.

---

## Scenario walk — where each one stops

| Scenario | Works as written? | Stops at |
|---|---|---|
| S1 family, 3 nodes | Yes, with extra prompts | M4 (lock screen, prompts); m2 (card) |
| S2 parent phone lost | No | B1(a) login PSK; B2 network orphaned; all family certificates re-issued in person (stated) |
| S3 family member's phone | Yes | needs the per-node identification keys handed over in the same meeting (say so) |
| S4 turn-out, 8 nodes, 2 admins | Admin part yes; member part no | M3 |
| S5 admin phone lost mid-incident | Takeover yes if keys were synced | M3 (sync), M5(b), revocation needs ICS + a visit per node (stated) |
| S6 node lost | Yes for the admin | M2 delivery cost; M5(a) if the other admin edits |
| S7 two squads | Yes | per-node fresh join; cost not stated |
| S8, S9 | As stated | S9 understates member access (M3) |
| S10 node off three months | Yes | unless it was removed meanwhile → needs a new version that lists it |
| S11 leaver | Yes | M10 at scale |
| S12 new phone / reinstall | Family parent: as S2. Others: needs ICS | M10 |
| S15 root leak | As stated | needs the physical reset trigger; no button on current HATs |
| Re-key by phones, 8 / 30 nodes | Serial, admin-bound | M2 |
| Two admins, partitioned | Converges on bytes | M5(a) |
| OTA trial / revert / commit | Revert safe; commit path undefined | M7 |
| Chip stops answering | Undefined | M8 |

---

## Verdict

**REJECT** — 2 BLOCKER, 10 MAJOR, 8 MINOR.

The direction and the threat model stand, and v2 is much narrower than v1. The two blockers are both about things
this document freezes: what gets locked into the chip, and how unit id and network authority are defined. Phase 1
must not reach the lock experiment on §4 as written. Most fixes proposed above remove or narrow (random unit id,
authority as a role, no in-place conversion, user authentication only on state-changing signatures, re-key transport
reuses the replayable object); none needs a new node-side mechanism except the one chip slot in B1(a).
