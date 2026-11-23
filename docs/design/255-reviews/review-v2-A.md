# Review v2-A (security) of `255-threat-model.md` (v1) + `255-key-authority.md` (design v2)

Reviewer A, round 2, independent (had not seen v1 or v2 before). Base: worktree `C:/src/Batman-255`, main 4eba26d plus the
untracked design files. Method: `docs/design/REVIEW.md` first; then both documents in full; own view formed and the
source read (`feed/batman-prov/src/`, `app/rust/`, `app/android/`) before opening `255-reviews/v2-changes.md`.
Read-only: no node, no network, no build. Baseline (QR claim + CheckMac, the Noise channel, `wtxn`, A/B) is not
re-litigated; only its interaction with the new design is.

Summary: the direction (anchor-only trust list, fixed chain shape, in-session entry / bearer update, no unit-wide key)
is sound and most round-1 findings are really closed. What is not sound is concentrated in the three mechanisms v2
added to close round-1 findings: (1) revocation floors carried by an issuer-signed node certificate, (2) the NET verb
that hands the network password back, (3) the QR-derived PSK. Each of them opens a hole that the v1 baseline did not
have. Most fixes below remove or narrow; none needs a new object type.

Counts: **1 BLOCKER, 8 MAJOR, 14 MINOR.** Verdict: **REJECT** (one more revision; the changes are local to §3.2–§3.6, §4
and the threat-model tables).

---

## Findings

### BLOCKER

**B1. The floor mechanism is self-referential and the node-certificate acceptance rule is undefined; under every
reading either a revoked issuer stays usable on a freshly enrolled node (R6 not met), or a compromised issuer can lock
nodes until a physical factory reset (T6 escalates from V2 to the cost of V1).**

Evidence: §3.5 "節點證書裡寫著發證當下**各**撤銷清單的版本與最低世代。節點只接受不低於這些下限的清單"; §3.5 "節點沒有有效節點
證書時不接受任何鏈，只接受 PRIMARY 本人"; §3.3 rule 3 (an issuer may issue node certificates); §5.2 "節點證書 … 誰送得到：任何連
得上的人；靠簽章擋"; §6.2 "入庫 … 之後才收節點證書". Nowhere stated: (i) how the node certificate itself is verified when
the node has no valid node certificate yet (it arrives as a chain root → issuer → node cert, which the rule just quoted
says is refused); (ii) which floors apply while verifying it; (iii) whether a second node certificate with the same
counter value replaces the first, and whether its floors may be lower; (iv) what makes an installed node certificate
"invalid" other than a counter mismatch (issuer revoked? generation raised? PRIMARY replaced?).

Scenarios:

- *(a) Revoked issuer on a fresh node.* T6 copies issuer key I. The root revokes I (root list v5). A node is
  legitimately factory-reset and re-enrolled (it now holds the trust list, no node certificate, no lists). Before the
  legitimate node certificate arrives, the attacker — who has the body QR (ex-administrator; the QR-PSK candidate is
  always on, §3.6/A7) or the node's identification key from the roster T6 read — sends a node certificate signed by I
  with the current counter value and "root list floor = v4", plus the genuine root list v4. The only statement of the
  root-list floor is inside an object signed by the very issuer that list is supposed to revoke. Every I-issued NET
  certificate is now valid on that node: R6's negative control ("恢復出廠 + 重新入庫後，用已撤銷的證書") passes for a
  revoked leaf, fails for a revoked issuer.
- *(b) Floor poisoning.* T6 signs node certificates (counter is a small integer; sign one per candidate value) with
  "root list floor = 2^64−1" and delivers them (roster gives every identification key; ICS sync can also hand them to
  honest phones). If a replacement node certificate is accepted and floors only rise (the only reading consistent with
  R6 "不能被舊資料蓋回去"), the node refuses every issuer chain forever: no root list can reach the floor, and PRIMARY in a
  squad is an offline root that cannot lower it. Recovery = physical factory reset of each node, i.e. the consequence
  the threat model reserves for a root leak (V1), reached from the daily host (V2). Threat model §6 item 5 says T6 "可發
  NET 證書，直到被發現並由根撤銷" — that understates it.
- *(c) If instead a replacement node certificate may lower floors*, (a) works on every node, not only fresh ones.
- *(d) Issuer revocation / yearly generation bump freezes management.* If an installed node certificate stops being
  "valid" when its issuer is revoked or when the issuer's minimum generation rises (the node certificate has a
  generation field, §3.3), then the defender's own remedy for T6 — revoke I — and the planned yearly bump (§6.1) put
  every node of the unit into "只接受 PRIMARY 本人" (offline root) until each one is hand-fed a new node certificate — at
  exactly the moment administrators need to re-key. If it does *not* become invalid, say so.
- *(e) New issuer.* After I is replaced by I2, a node has no floor for I2's list (its node certificate predates I2).
  "手上沒有達標的清單時拒絕" then either rejects all I2 chains (needs a new node certificate, see (i)) or accepts any I2
  list (no floor). Unstated.

Fix (narrowing, no new object):
1. A floor for a list may only be set by (α) the enrolment session itself, or (β) accepting a newer list signed by
   *that list's own signer*. Nothing signed by an issuer ever states a floor for the root's list.
2. Drop the separate root revocation list: put "revoked issuer key ids / minimum issuer generation" into the trust
   list, which is root-signed, versioned, already delivered inside the claim transaction and already "higher version
   only". One object fewer; the root-level floor is then exactly the trust-list version the enroller supplied.
3. Define enrolment as complete only when the node certificate is installed, and accept the *first* node certificate
   only inside a session authorised by the enroller's transient key (§3.6 already keeps that key for `claim/replay`)
   or signed by PRIMARY. This removes the "any bearer may install it" input and the chicken-and-egg in (i).
4. State: an installed node certificate is a record of "this enrolment, these initial floors"; it is checked for
   counter equality and for a signature chain valid under the current trust list, and is *not* subject to generation
   floors or issuer-list entries. A replacement (same counter) must verify under the stored floors and floors become
   max(stored, new). An issuer can then only raise its own list's floor; the recovery from that is "root revokes I,
   certifies I2", with no physical step.
5. Negative controls to add to threat model §7: revoked-issuer node certificate on a fresh node; node certificate
   with lower floors; node certificate delivered outside the enrolment session; poisoned floor then issuer rotation
   recovers without factory reset.

### MAJOR

**M1. The new NET verb returns the network password "re-wrapped to this connection": a compromised provd (T8) obtains
the mesh password. R17 / the provd trust boundary is broken by a v2 addition.**

Evidence: §3.4 table, last row; threat model §2 "節點 provd … 只有 helper 導出的 PSK … 假設可能被入侵", R17. provd is the
Noise endpoint: it holds both cipher states and encrypts every reply (`provd/noise.go:36-41, 97-104`,
`provd/session.go:392`). Today the SAE password never passes through provd in clear: the phone wraps it to the node's
ECDH key and only the helper opens it (`node/node.go:1045-1103` `parseNet`, `keystore.go:60-61`). The certificate
format (§3.3 "對象公鑰") carries one signing key and no encryption key, so "this connection" can only mean the Noise
session or an unauthenticated key the phone (or provd) supplies in the request.
Scenario: T8 waits for any administrator to use the verb, or rewrites the request's wrapping key if that key is not
covered by `args_hash`; it now holds V5 for every network this node is in and for every later re-key.
Fix: prefer removal (see M2). If the verb stays: person certificates carry an encryption public key signed together
with the signing key (today's `owner_enc_pub` + `LabelOwnerEnc`, `node.go:577-578`, is the precedent) and the helper
wraps to that certified key only. That is a certificate-format field and must be decided in this document.

**M2. With the same verb, a re-key no longer excludes a revoked administrator unless the revocation list has reached
every node first. The baseline needed nothing delivered: a removed party simply never received the new password
(fact 12). v2 makes every node a password oracle for any chain it still believes.**

Evidence: §3.4 new verb; §3.5 "撤銷只影響之後的驗證 … 撤銷一位管理員之後應接著換密碼"; §3.6 delivery (phones forward `net_state`;
nothing binds a revocation list to it); threat model §6 item 1.
Scenario (S11): Bob's NET certificate is revoked; an administrator re-keys; phones carry the new `net_state` to all
nodes. One node has the new state but not the new list (the phone that served it had not synced with ICS — S9 allows
that). Bob still has that node's identification key (rotation is "標記待換"), logs in with his revoked chain, calls the
verb, and reads the *new* password. The re-key that §3.5 prescribes as the remedy is void.
Also: §7.2 says a stolen unlocked NET phone can "讀手機裡存的網路密碼"; with this verb it can read the password of any
network of the unit from any member node it can get near. The blast radius of T4 is every network in the unit.
Fix (removal first): a second administrator does not need the old password to take over — NET may sign a new
`net_state` with a fresh password, and the member list with ECDH keys is in the signed state readable with VIEW (§3.6).
The verb is only an optimisation for "add one node without re-keying". Options, in order of preference: (a) remove the
verb; adding a node by an administrator who does not hold the password = re-key; (b) keep it but have the helper wrap
the password only to the ECDH key of a node listed in a NET-signed request (the phone never sees it); (c) keep as is
and write into threat model §6 that re-key effectiveness now depends on revocation delivery, and add the negative
control. (c) is a regression against the baseline and should be the user's explicit choice.

**M3. R12 ("the legitimate authority can always take control back by signing a higher version") is false at the top of
the version space, and honest phones spread the attacker's object; the same holds for the trust-list version against
RECOVERY. Round-1 A-M2 / B-M1 / B-M3 are only partly closed.**

Evidence: §3.4 "版本（64 位元）… 先比版本號，相同再比物件雜湊，大的贏 … 被盜金鑰把版本推高時，合法管理員簽更高的即可"; §3.6 "其他節點由
任何一支有權登入它的手機自動補送 … 手機從 … 任何一台已更新的節點（VIEW 即可讀）"; §3.2 "節點只接受更高版本"; §7.2;
`v2-changes.md` B-M3 "reach = nodes the thief can get near".
Scenario: T4 (unlocked NET phone, or T2 before revocation lands) signs a `net_state` for network X with version
2^64−1, a member list whose entries are garbage or a password only the attacker knows, and a hash ground to have, say,
40 leading one-bits. It is injected into *one* node. Every honest phone that later reads "the latest state" from that
node forwards it to the rest: the thief does not need to walk anywhere. The legitimate administrator cannot sign a
higher version; winning the hash tie-break needs 2^40 signatures, then the attacker (if still unrevoked anywhere)
raises it again. Revocation does not help: "已套用的網路狀態不動" and a legitimate update still has to exceed the stored
order. Network X is frozen for good; recovery is leave + in-session join under a new net id on every node — which is
not a bearer object, so S10 ("送最新一版即可") no longer holds for those nodes.
Same shape for the trust list (home): a thief holding PRIMARY signs trust list version = max; RECOVERY's "replace
PRIMARY" can never be higher on nodes that received it; recovery = factory reset.
Fix (no new mechanism): (1) state the bound honestly — R12 holds below the maximum; the escape for a burnt net id is
a new net id by in-session ops, for a burnt trust-list version a factory reset — and add both to threat model §6;
(2) narrow the spread: a phone forwards a state only if its signer chain verifies against the newest lists the phone
has, and never forwards a state it merely read from a node unless it is the one it would have chosen itself; (3) say
what the app does when it sees a version jump larger than it has ever issued (warn, do not auto-forward). (1) is the
required part; the negative control in §7 for R12 must include the maximum-version case.

**M4. The QR-derived PSK contradicts §4, the one section that cannot be changed after the configuration zone is
locked.**

Evidence: §3.6 "掃機身 QR，用認領秘密導出的 PSK 做交握"; A7 "QR 復原 1" (a permanent candidate); §4 "認領秘密 | 不可讀；只能
CheckMac（219 P9）". A slot that only answers CheckMac cannot give the helper a value derived from K, and provd needs
that value before msg1 can be opened (`provd/server.go:738-768`: candidates come from the helper's poll). Today an
unclaimed node uses NX with no PSK (`server.go:746-748`) and K is used only inside `CheckMac`
(`keystore.go:63-66`), so nothing in the baseline needs a derivation.
Consequence: either the slot must allow a MAC/KDF use (a slot-configuration decision, irreversible, and it turns the
chip into a derivation oracle for whoever can drive the bus), or the derived value lives in a file on p5 (then it does
not survive the SD re-flash that phase 1 promises: "重燒 SD 身分還在、同一張 QR 有效"), or it sits in a readable data slot
(one of the "預留" slots, to be decided now).
Fix: decide in §4. Simplest: at factory provisioning write a second 32-byte value `HKDF(K, "recovery-psk")` into a
data slot readable only through the helper, K's slot stays CheckMac-only; the QR content is unchanged (the phone
derives it). Or drop the QR-PSK path (see M5) and the conflict disappears.

**M5. The QR-PSK candidate is a permanent, non-rotatable identification key. R14 is not met against anyone who has
ever seen a body QR, and threat-model V7 is mis-stated.**

Evidence: R14 "節點的藍牙識別金鑰每台不同，可由 NET 持有者更換；剩下的風險：T2 曾拿到的那幾台，在更換前可被辨認"; V7 "未入庫或已恢復出廠時：把節點
入庫到自己名下"; §3.6, A7; §4 (claim secret not writable).
Scenario: in a squad every enrolment goes through an administrator's phone, so every administrator who enrols sees
QRs; T7 photographs them (the label is on the body). A successful NXpsk0 msg1 under the QR-PSK is a yes/no oracle
"this advertiser is device X" (`noise.go:76-86`), and it reveals the node's signed static key in msg2. Rotating the
per-node identification key changes nothing for these parties; the claim secret cannot be rotated. So the residual
is "forever", not "until replaced", and V7 has value on an *enrolled* node too.
Also unstated: what a session opened with the QR-PSK may do before any login. "只是讓交握能開始" needs to be a rule:
role = no verb except login and the RECOVERY-signed trust list; and a negative control.
Fix (narrowing): offer the QR-PSK candidate only while the trust list has a RECOVERY entry (home). A squad has no
RECOVERY (§3.2) and S2 does not apply to it; a squad node whose identification key was lost is factory-reset
(physical) and re-enrolled. For home, write the residual into threat model §6 and correct V7. If the user wants the
QR path for squads as well, that is an explicit acceptance that R14 does not hold against QR holders.

**M6. "Replace PRIMARY" is under-specified in ways that fix formats: what the unit id is afterwards, and what happens
to each network's recorded authority. As written, S2 ends with networks nobody can re-key.**

Evidence: §3.2 "單位 id（信任錨公鑰的雜湊）"; §3.4 "節點記下這個網路的授權者 = 鏈最上層的那把信任錨 … 更新：最上層 = 該網路記下的授權者";
R11 "只有那個授權者的鏈能更新或移除它"; §6.1 換根 row (lists node certificate and person certificates, not networks);
§7.3 step 5.
Scenario (S2, the headline home scenario): the parent's phone is lost; the new phone uses the recovery card and
installs PRIMARY = B. Every stored network records authority = A. By R11 neither B nor anything B issues can update or
leave those networks — and the lost phone knows the password, so a re-key is exactly what is needed. The same happens
in a planned squad root roll-over.
Second gap: if unit id = hash(PRIMARY public key), it changes on replacement; then the "replace PRIMARY" list itself,
every `net_state` ("單位 id") and the R4 binding refer to an id that no longer matches, and it is not stated which id a
node accepts a trust list for. If it does not change, "信任錨公鑰的雜湊" is wrong and the id needs another definition.
Fix (narrowing): record a network's authority as the trust-list *entry class* (PRIMARY, or the key id of a NET_ONLY
entry), not as a key — then replacement needs no migration step; define unit id as fixed at enrolment (hash of the
first PRIMARY, or random), carried unchanged by later trust lists; state which entries a RECOVERY-signed list may
differ in (PRIMARY only). Add the negative controls: after replacement the old PRIMARY cannot update a network; the
new one can.

**M7. Chains topped by a NET_ONLY key are not capped. As written a club's key can obtain USE, MAINT, issuer and node
certificates on a member's own node.**

Evidence: §3.3 rule 1 "最上層的簽章者是信任清單裡的 PRIMARY，或（對該網路）NET_ONLY"; rule 2 "發證者 … 由信任錨直接簽"; rule 3 "發證者只能發
VIEW、USE、NET 與節點證書。MAINT 必須是鏈長 1"; §3.2 table (limits the *key*, not what a chain under it may carry). Whether
NET_ONLY counts as "信任錨" for rules 2–3 is not stated; "對該網路" has no meaning for a non-network action.
Scenario (S13): the club key signs a length-1 MAINT certificate scoped to a member's node (rule 3 satisfied: length
1), or an issuer certificate whose leaf is USE on that node → `ssh_keys/*` / `root_password/*`, or the node's phone
Wi-Fi settings. Or it signs a node certificate and feeds B1.
Also (same rule, opposite direction): R11 literally forbids PRIMARY — the owner of the node — from removing a network
created under NET_ONLY, while §3.2 says PRIMARY can do "一切".
Fix: prefer removal — NET_ONLY is first used in phase 5; reserve the class value and take it out of the phase-2 rules
(an unknown class in a trust list = reject, so adding it later costs nothing). If it stays: a chain whose top is
NET_ONLY has length 1 and carries only NET / VIEW limited to networks whose recorded authority is that entry; PRIMARY
may always make its node leave any network.

**M8. R3 (MAINT only by the anchor, node-scoped) + D11 (the squad root exists only in a few ceremonies) + §3.4
(`update/*`, `bulk/*`, `ssh_keys/*`, `root_password/*` = MAINT) cannot all hold in operation. The document defers
the one question that decides it.**

Evidence: §3.4 table "⚠️ 軟體更新歸 MAINT 是否太嚴，第 2 期實作設計決定"; R3; R10 "只在少數幾次儀式中使用"; §3.3 "節點範圍（USE、MAINT 必
填）"; the update content is already authorised by its own chain (`release/release.go:1-4`).
Scenario: a squad needs an OTA. Either every OTA round (and every newly enrolled node, because the scope is an
explicit node list) needs a root ceremony with two custodians — the root is no longer "a few times" — or the ceremony
signs one long-lived MAINT certificate covering all nodes for a maintenance phone, which is a standing root-on-every-
node credential on a field device (T4 → V3 for the whole unit), revocable only by another ceremony.
Why it cannot be deferred: it fixes how often the root key is reconstructed (R10's residual) and whether a fleet-wide
MAINT credential exists (V3's blast radius). Both are threat-model facts, not implementation detail.
Fix: decide here that `update/*` and `bulk/*` are not MAINT (the image is authorised by the release signature; who may
trigger it = NET, or the issuer may issue a dedicated UPDATE permission), leaving MAINT for `ssh_keys/*` and
`root_password/*` only, which are rare. Or, if the user wants updates to stay root-gated, write the ceremony frequency
and the standing-credential risk into the threat model and Q-list.

### MINOR

**m1. Threat model lacks two actors that `REVIEW.md` item 5 makes mandatory — local non-root process and compromised
tenant / container — and the attack-surface delta.** The secure element moves the node's secrets from 0600 files to
an I2C device: whoever can open `/dev/i2c-1` can sign arbitrary digests with the identity key (§4: "只能簽晶片外給的雜湊" —
the purpose labels of `keystore.go:79-97` are enforced by the helper, not the chip), use the ECDH key as a decryption
oracle for the wrapped password in a `net_state`, and increment the enrolment counter (invalidating the node
certificate). The bus is already shared with another root tool (`feed/batman-provision/files/usr/bin/batpower:44-45`,
INA226 on bus 1), which is also missing from §5.1 as a shared resource. State: the device node is root-only, never
passed to a container, the helper is the only process that addresses the chip; negative test as a non-root process.
The helper socket is already peer-credential checked (`sock/sock.go:2, 189`) — cite it for R17.

**m2. Requirements without a negative control in threat model §7:** R5, R10, R13, R19, R20 (the section header promises
one each). Protections claimed in the design with none: QR-PSK session can do nothing before login (§3.6); old
identification key stops working after rotation (R14 lists only cross-node use); trust-list rollback to a lower
version; a RECOVERY-signed list that changes anything other than PRIMARY; a revoked *issuer* certificate (R6 covers
leaf only); VIEW / USE cannot call the NET read verb, NET_ONLY cannot read another network's password; T8 cannot
obtain the password (M1); old slot booted after conversion stays frozen and writes nothing (R19, see m6); factory
reset really invalidates the old identification key and node certificate; non-root cannot reach the chip (m1);
maximum-version `net_state` (M3). R10 is procedural — say so instead of leaving it blank.

**m3. Enrolment "同一個交易" spans the chip counter and p5 files, which cannot be atomic; the order is a security
invariant and is not stated.** If the record is committed before the counter is incremented and power is lost in
between, the pre-reset node certificate still matches the counter and can be replayed with its old floors. State:
increment first; a crash leaves the counter ahead (harmless). Also state the behaviour at counter exhaustion (608B
counters end at 2,097,151): enrolment refused, chip replaced; and that only an enrolment that passed CheckMac may
increment.

**m4. Several independently replaced files in p5 (trust list, lists, node certificate, identification key, network
state, authority record — §5.1, §6.2) where today there is one record with one commit point (`prov.meta` sha,
`node.go:1295`).** Factory reset "clears" six things and enrolment writes three; a power loss in the middle leaves
combinations the document does not define (trust list gone but network and identification key still present; or the
reverse). All of it fits in the existing 64 KiB record (4 keys, ≤128 × 16-byte ids per list, one node certificate).
Fix: keep one record and one commit point; then the "各自原子替換" row and its cross-file cases disappear.

**m5. Format conversion: the document says both "轉換是一次交易" after autocommit (§6.2, with A9 ❓ on whether the hook
exists) and "bench 重新入庫即可，不寫遷移" (§4, §6.2 last line, fact 16).** There are no deployed nodes and phase 1
already forces re-enrolment. Prefer removal: the phase-2 helper reads the old record during the trial, and after
commit a node keeps working under the old rules until it is factory-reset and re-enrolled; no in-place conversion, no
dependency on A9.

**m6. R19 / A6: the cited evidence (`provstore.go:112-131`) shows the old parser returns an error, not what the old
image then does.** I checked: with `v > 1` in `prov.cbor` / `prov.meta` the old image reports `unknown(too-new)`,
writes nothing and keeps the previous lock state (`provstore.go:127-128, 314-317`, `boot/boot.go:270-271, 276-290`);
a v1-shaped record that merely fails the schema gives `unknown(prov-corrupt)` with no write (`boot.go:167-169`). But
the old slot's own overlay copy can be re-persisted over p5 on other paths (`boot.go:227-229, 236-243`). So the
design must state: the new record sets v ≥ 2 in both files (the fail-closed path that exists), and never produces a
v1-parsable record after conversion. Add the negative control (boot the old slot after commit: frozen, p5 unchanged).

**m7. The existing verb set is not fully mapped in §3.4.** Unmapped: `diag/bundle`, `diag/summary`, `reset`,
`peers/challenge`, `update/check`, `update/status`, `owner/add`, `owner/remove`, `auth/owner`, `settings/get`
(`provd/session.go:60-65`). `diag/bundle` returns a diagnostic archive (`node.go:823-826`) and needs a decided class
(MAINT, unless its content is shown to hold no secret).

**m8. Signed-object fields vs R4.** The revocation list (§3.5) lists issuer key id, version, minimum generation, ids —
no unit id and no object type; R4 requires both. The trust list change that needs RECOVERY's consent carries two
signatures, but D9 fixes COSE_Sign1 (one signer): state the shape (for example PRIMARY's Sign1 over a payload that
embeds RECOVERY's Sign1 over the same new entry). The trust list has no tie-break for two different lists with the
same version (PRIMARY update vs RECOVERY replace): give it the same (version, hash) order as `net_state` or state
that RECOVERY wins.

**m9. R16's residual is wrong.** "拍到卡的人可奪走控制權，但家長 … 用卡再換回來": whoever holds a copy of the card holds the
RECOVERY private key, so after replacing PRIMARY they can also replace the RECOVERY entry (both required signatures
are theirs). The parent cannot switch back with the card; recovery is a factory reset of each node. Correct the text
in R16 and §7.3 step 5.

**m10. R5 / R13: nothing proves that a node certificate is issued to a key inside one of our chips, or that the
requester holds the key.** §6.1 specifies challenge + proof of possession for person certificates only. An ICS account
with the enrol right can obtain a unit node certificate for a software key; the R13 app check ("有本單位節點證書") then
passes for a foreign machine. Add proof of possession for node certificates (the node signs the issuer's challenge
under a new fixed purpose label), list "ICS account / enrol right" as an asset, and state the residual under R5.

**m11. Ceremony inputs (D11).** The root signs what the daily host prepared (issuer public key, trust list content,
"last version used"). A T6 present before a ceremony gets its own key certified as a second issuer that nobody knows
to revoke. State the requirement: the ceremony tool shows key fingerprints and versions for the custodians to compare
against an independent record, and keeps a signed log of everything the root signed. No design needed now, only the
requirement, because R10's claim depends on it.

**m12. Identity backend selection.** §9 phase 1 ships "file 與 608B 兩個實作". State that the backend is fixed at factory
provisioning (today's `backend` file, `keystore.go:266-267`) and that a missing or silent chip never falls back to
generating a file identity (R21 covers "no new settings" but not this). On the file backend the counter is a file
beside the identity; say that an SD image restore rolls back both (T5 only) so nobody later treats the file backend
as meeting R6.

**m13. Threat-model consistency.** T4 says an unlocked stolen phone "可用 V4 簽章", R15 requires user authentication on
every use (so the thief also needs the PIN or biometric) — pick one and make §7.2 match. §7.2 must also list what T4
gets from the roster on the phone: every node's identification key (§3.6 "管理員 = 全單位"), i.e. the ability to find
and open a handshake with every node of the unit until each one is rotated by a visit.

**m14. ICS ↔ phone sync carries secrets (identification keys of the whole unit), not only signed objects.** §5.2 says
"app 驗簽章" and leaves the channel to ICS. Add the requirement that the channel is confidential and authenticated to
the individual account, and that identification keys are released per the same rule as §3.6 (administrator = all,
member = assigned). Otherwise R14 is decided here and broken there.

---

## Round-1 BLOCKER / MAJOR findings I consider NOT (fully) closed

| Round-1 | Status | Why |
|---|---|---|
| A-M1 (floors lost on enrolment; fail-open) | **Not closed** | Fail-open is gone, but the replacement is self-referential for issuer revocation and adds a lock-out path → B1 |
| A-M2 / B-M1 (+16 window; exhaustion) | **Partly** | Window removed; exhaustion at the maximum version remains and R12 claims "always" → M3 |
| B-M3 (one NET certificate reaches every node) | **Partly** | "reach = nodes the thief can get near" is not true for bearer updates: honest phones forward them (§3.6) → M3; the read verb widens what it can take → M2 |
| B-B2 (second administrator) | **Closed by a mechanism that opens M1 and M2** | |
| B-M6 (recovery cannot reach nodes) | **Closed by a mechanism that opens M4 and M5** | |
| A-M9 (anchor replacement) | **Partly** | One-step replace is right; unit id and network authority after replacement undefined → M6; card-holder can lock the parent out → m9 |
| A-M6 (MAINT = root) | **Partly** | Stated and anchored, but the open `update/*` question decides ceremony frequency → M8 |
| A-B2 (issuer constraint) | **Closed for PRIMARY**; reopened for NET_ONLY tops → M7 | |
| A-M8 / B-M7 (downgrade, revert) | **Closed in substance**; evidence and the v ≥ 2 rule missing → m6; conversion can be dropped → m5 | |
| A-M10 / B-M10 (resources, lifecycle rows) | **Mostly closed**; I2C bus and multi-file commit missing → m1, m4 | |
| A-B1, A-B3, A-M3, A-M4, A-M5, A-M7, B-B1, B-B3, B-M1, B-M2, B-M4, B-M5, B-M8, B-M9, B-M11, B-M12 | **Closed** | Checked against the v2 text, not only the change table |

## Facts checked

Confirmed against source (line ranges accurate to within a few lines): facts 1, 2, 3 (`Keys.kt:92-98`: no
`setUserAuthenticationRequired`), 4, 5, 6, 7, 8, 9, 10, 12, 13, 14, 15; A4, A6 (with the caveat in m6), A7
(`server.go:771-781`: indexes 0–3 candidate, 4 member, 5 replay).

Wrong or unsupported:

1. **Threat model §2, provd row, and §3.6 "provd 仍只拿到導出值".** `node.go:433-436` only shows that the *poll* gives provd
   HKDF outputs. provd terminates Noise, so every reply passes through it in clear — today that includes the owner
   tag key, the advert key and the root password returned by `claim/finish` and `claim/replay` (`node.go:609, 672`;
   `session.go:72-73` lists them as secret-bearing replies; `session.go:392` encrypts in provd). Under v2 the
   per-node identification key is "在該次連線回傳給入庫者", so T8 sees the key itself. This is baseline behaviour, but the
   trust-boundary table must say it, and it is what makes M1 a real exposure.
2. **Fact 11 "節點端沒有任何時間檢查"** is true for validity periods (`keystore.go:148-168` ignores NotBefore/NotAfter). The
   node does use relative time (replay-failure window `node.go:627-633`, nonce expiry, the 5-minute HTTP fallback
   `http.go:3-6`). Reword to "no wall-clock validity check".
3. **§4 "認領秘密 … 只能 CheckMac" vs §3.6 QR-derived PSK** — internally contradictory (M4).
4. **§3.2 "單位 id（信任錨公鑰的雜湊）"** is unsupported once PRIMARY can be replaced (M6).
5. **`v2-changes.md` B-M3 "reach = nodes the thief can get near"** contradicts §3.6's automatic forwarding (M3).
6. **A1 / §4 608B facts** (counter range, per-slot lock, slot sizes) are correctly marked ⚠️; nothing in the repo can
   confirm them. Phase 1's first step must close them before any lock, as the document says.
7. Fact 16 (`329-app-uiux.md` §2.1) and the ICS statements (A8, §7.4): not verifiable from this worktree; correctly
   marked for ICS, fact 16 I did not confirm beyond the section existing.

## Deferred items: do they force a change to something decided here?

- Mesh relay, remote inhibit, guest certificates, cross-agency interop: no — nothing decided here depends on them.
- Multiple networks per node: yes for NET_ONLY (unusable with one slot) — another reason to defer the class (M7).
- "軟體更新歸 MAINT 是否太嚴": yes (M8).
- "離線的發證端如何查金鑰證明的撤銷" (phase 4): no format impact; acceptable.
- ICS link choice: acceptable with the requirement in m14.
- 608B slot facts: acceptable only because §9 phase 1 gates the lock on a review and a trial chip; M4 must be settled
  before that review.

## Verdict

**REJECT.** One BLOCKER (B1) sits in the mechanism R6 rests on, and M1–M5 are holes introduced by v2's own additions.
The fixes are mostly removals: no root revocation list (fold into the trust list), no bearer installation of the
first node certificate, no password-read verb (or wrap to a node key), QR-PSK only where a RECOVERY entry exists,
NET_ONLY out of phase 2, `update/*` out of MAINT, one record with one commit point, no in-place conversion. After
those, I would expect the next round to be APPROVE-WITH-CHANGES.
