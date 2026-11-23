# Review of `docs/design/255-key-authority.md` v1 — Reviewer B

Base: worktree `C:/src/Batman-255`, main 4eba26d + the design file. Read-only review: no device contacted, nothing built.
Node paths are relative to `feed/batman-prov/src/`, app paths to `app/`. "Doc" = the design under review.
Marks: [src] = I read the cited source; [est] = my own estimate, not measured.

Method: REVIEW.md first (ownership, contracts, lifecycle, assumptions, security), then each field scenario walked step by
step against what each party holds at that step, then the phase plan. The baseline (QR claim / CheckMac, the Noise
channel, the SAS three-step join, `wtxn.go`, A/B, the #329 pages) is not re-reviewed; only the new design's
interaction with it.

Summary: the direction (trust anchor + certificate chain, any NET holder may sign, self-contained state instead of a
+1 chain) is sound and answers U1. The document is not yet a safe basis for per-phase designs: three decisions that
later phases cannot cheaply change are either missing or contradict the source (freshness of the new bearer objects;
how a second administrator gets the network's secrets; what happens to the shipped authorisation path that D11 says
is "kept untouched"). Several scenarios in §2 do not work with what the parties hold.

---

## BLOCKER

### B1. The new signed objects are bearer objects with incomplete freshness: replay of an old `net_state`, any `inhibit`, and an old `trust`

(a) Scenario 1 (old network replayed). Monday: admin A builds network X (v3, password P) on nodes 1–8. Tuesday node 8
is stolen; X is rekeyed to v4 without node 8. Later the nodes drop X: `inhibit` ("清除指定網路設定", §3.3), the
"清舊網路紀錄" item of phase 3/4, eviction from the D10 slots, or factory reset + re-enrolment under the same root.
The only replay rule is "版本 > 已存版本" (§3.3, §7.2 M1) and the stored version for X is now gone. The thief (node 8
holds the signed X v3 object, P, and the unit identification key) sends X v3 to nodes 1–7 over BLE or bat0. A's
certificate is still valid, every node is in the list and can decrypt its share: accepted. Whether it becomes the
active network is undefined (§3.3 / D10 do not say who activates a newly received net id), so the outcome is between
"a poisoned stored network one tap away" and "the squad moves to a password the thief has".

Scenario 2 (`inhibit`). `inhibit` = {target node id, net id or all} (§3.3): no version, nonce or counter. It is
forwarded in the clear over the mesh (§5.3). Anyone who once saw an inhibit for node N (any mesh member, any AP
client that can reach the forwarder, a captured node) can replay it for as long as the signer's certificate is
unrevoked: N loses its network again every time it is re-added.

Scenario 3 (`trust`). Root rotation (§6.1) produces a root-signed `trust` v5 = {old root, new root}. After the old
root is removed (v6) a node is factory-reset and re-enrolled (stored trust version restarts). The v5 object is a
unit-wide bearer object (§3.3 gives it no target node and no session binding) and 5 > stored: the retired (possibly
compromised — that is why it was rotated) root is back in the node's OWN list.

(b) Evidence. Today the first application of a network to a node is session-bound: `network/join` needs an owner-op
over the handshake hash and a one-time helper nonce (`proto/proto.go:90-103`, `node/node.go:705-746`, `:774-787`),
and only updates of the network the node already holds travel without one (`node/node.go:778-779`), protected by
net id + contiguous version + prev hash (`:1200-1206`). The doc turns join, leave-by-inhibit and trust changes into
objects that "轉送方不需要被信任" (§5.3) and that any forwarder may deliver (§5.2 "任何能連上節點的人都能送").
§7.2 M1 claims "所有物件版本只增，節點落地最高版本" but `inhibit` has no version and high-water marks do not survive
the removal paths the doc itself adds.

(c) Fix (decide in this document, it shapes every object):
- A node accepts a `net_state` for a net id it does not currently hold only inside an authenticated session as a
  session-bound `op` (exactly today's rule); forwarding and courier delivery are limited to the net id(s) the node
  holds. State who activates a stored network and that activation is always a session-bound `op`.
- Removing a network leaves a tombstone {net id, last version} in the record (bounded, with a stated eviction rule),
  or net ids carry a per-anchor monotonic epoch the node keeps.
- `inhibit` carries {net id, "applies while stored version <= v"} or a per-node counter kept across removal; state
  whether it may be forwarded at all (see M3).
- `trust` is per node (target device id) or delivered only as a session-bound `op`; the trust version survives factory
  reset, or the reset path is stated as a replay boundary with its mitigation.
- §10 gains the negative controls: replay of a removed network, replay of an inhibit after re-add, replay of an older
  trust object after factory reset.

### B2. D4 ("any holder of NET may sign") does not say how a second administrator obtains what a `net_state` must contain

(a) Scenario S4, the scenario D4 exists for. Leader A builds the network; A is evacuated. Communications officer B
(valid NET certificate) must add one node, or remove one. To sign v+1 B's phone needs (1) the current SAE password
and net_root, unless every change by another admin is a full rekey, (2) the full member list, (3) every remaining
node's ECDH public key. `net_state` wraps the password "給每台成員節點" only (§3.3); the secrets otherwise live in
"管理員手機的加密紀錄" (§3.1) — A's phone. B holds none of the three. The same gap hits S2 (a new phone after
recovery), a second family phone, and "two administrators at opposite ends of a partitioned mesh".

The three possible answers have very different security and stability cost and none is chosen:
1. every change by a different admin is a rekey — every add/remove becomes a mesh-wide password change (stability
   regression against U2, see M8);
2. a node hands the secrets to any NET holder on request — a new export of the SAE password / net_root out of the
   helper, reachable by every NET certificate in the agency (today net_root never leaves the helper:
   `node/node.go:433`, `:996-1003`);
3. `net_state` also wraps the secrets for administrators — but the admin set is open by design ("任何持有 NET 權限").

For (2)/(3) the object must also carry each member's ECDH public key (+65 B, or 33 B compressed, per node), or B
depends on an inventory copy that only ICS (squad) or the lost phone (family) owns (§5.1).

(b) Evidence. Today the code refuses exactly this situation instead of solving it: the admin list holds only the
creator (`rust/batman-proto/src/joinflow.rs:157`) and rekey refuses when the admins are not exactly this phone
(`rust/batman-proto/src/rekey.rs:102`); the secrets are in the admin phone's net record keys 5/6
(`rust/batman-proto/src/netrec.rs:1-3`). Doc §1 fact 4 cites the same lines but §3–§4 never close the gap. §4 "建網"
covers only the first build ("逐台登入、讀節點證書取得 ECDH 公鑰").

(c) Fix: choose one mechanism here and put its cost in §7 (new secret export and who may call it, or rekey-per-change
and its mesh impact). State that `net_state` is self-sufficient for the next signer: member entry = {device id, ECDH
public key, wrapped secret}, and state how the ECDH key is bound to the node identity (today a separate proof signed
by the DAC, `node/node.go:403-411`; the node certificate in §3.3 names only "對象公鑰").

### B3. D11 ("the SAS three-step join is kept untouched") contradicts §3.2/§3.3, and phase 1 cannot be merged as scoped without deciding what happens to the shipped authorisation path

(a) Scenario. Phase 1 "信任清單取代 key 6 / 8" and introduces `net_state`. On that image:
- The shipped member join makes the joiner's own phone apply the leader's self-signed `net_config` + `net_secrets` to
  its own node with an owner-op; later updates from the leader are accepted through the admin chain stored in key 8
  (`node/node.go:1106-1123`, `:1167`, `:1192`; `docs/design/254-app-member-join.md` R3/R5/R21). With key 8 gone and
  "節點只認信任錨", a `net_state` signed by the leader (no common anchor — the only case D11 is for) is rejected by
  the joiner's node. The joiner would have to re-sign the state with its own key, and every later rekey by the leader
  needs a manual hand-over again — or the leader's key is added as NET_ONLY (the S8 mechanism). Either is a redesign
  of the SAS path, not "不變" (§4 last row).
- Remove-member / update bundle / leave (shipped, in the regular validation suite) are built on `net_config`,
  `member_list`, `network/update` and key 8. "移除 / 換密碼走 net_state" is phase 3. Between the phase 1 merge and
  phase 3 either both authorisation systems run in the helper — including the self-authorising admin chain D4 is
  meant to remove, now as a second way into the same network record (two writers, REVIEW.md item 1) — or shipped
  features regress and their tests are cut, which the project rules forbid.

(b) Evidence: as cited; doc D11, §3.3 "與今天的差別", §9 rows 1 and 3. `network/update` today needs no owner-op and is
accepted from any member-role session (`provd/session.go:82`, `node/node.go:778-779`).

(c) Fix: state per shipped flow (join2, member join, remove member, update bundle, leave, claim/replay) whether it is
kept on the old objects, re-implemented on `net_state`, or removed, in which phase, and what the node does with an
old-style object after the conversion. If both paths coexist for a time, name the single owner of the network record
per node state (a node is governed by exactly one of the two models, chosen at conversion, never both).

---

## MAJOR

### M1. The "+16" version window strands a node that was powered off, and contradicts the stated benefit of `net_state`

(a) A node is off for three months (a spare, a repair). The station's network had 17 or more changes meanwhile (each
add / remove / rekey is a version). The node holds v3 and is offered v21: outside (3, 19], rejected, forever —
intermediate versions are kept by nobody (the node "不需要簽章鏈", phones keep only the current one). §3.3 says the
opposite two lines earlier: "漏掉幾版的節點拿到最新一版就能追上".

(b) §3.3 acceptance rule vs §3.3 "與今天的差別" first bullet. The stated reason (a stolen key exhausting the version
number) is weak: the version space is 32 bit (`node/node.go:1057`), and an attacker who can sign states can do worse
with a new net id.

(c) Drop the cap and make exhaustion recoverable (a new net id through the session-bound path of B1), or keep the
cap only for forwarded objects and let a session-bound `op` jump any distance. Add the "node off for N months" row
to §6.2 with its test.

### M2. What revocation (and expiry on nodes with a clock) does to objects that are already stored or in flight is undefined

(a) S4 exactly: A built the network (current `net_state` v1 signed by A). A's phone is lost mid-incident, ICS revokes
A, the `crl` floods the mesh (§5.3). "節點每次驗證都查，不快取驗證結果" (D6) can be read two ways: (1) stored state
is re-verified (at boot, at provd/helper restart, when forwarding) — then every node drops or refuses the running
network the moment the CRL arrives, or after its next reboot, in the middle of the incident; (2) it is not — then a
node that rejoins late receives the CRL first and can never accept v1 (signer revoked), so the network is
undeliverable until someone re-signs it. The same question for expiry on nodes with trusted time (D7): a state signed
by a certificate valid then and expired now, offered to a lagging node; and 1-year personnel certificates with the
issuing station down at renewal time.

(b) The current code met this already and decided: "the STORED config is not re-verified … made every later update
fail" (`node/node.go:1169-1171`). The doc does not carry that decision over. §6.2 row "provd / helper 重啟" says
only "重啟後被撤銷者仍被拒".

(c) State: revocation and expiry gate acceptance of new objects only; stored active state is never re-verified.
"回報遺失 (人員)" lists every `net_state` whose signer is the revoked key and has a surviving admin re-sign it —
and say whether that must be a rekey (it should: the lost phone holds the password). Give the order (CRL first or
state first) and the test. For expiry: the app warns, never blocks (see m3).

### M3. One NET certificate now reaches every node of the agency, partly without being near them; the doc's threat row understates it

(a) Root is at agency level (D2) and S6 wants "直接勾選對方的節點", so a NET certificate from station 1 is valid on
station 2's nodes. A stolen, unlocked admin phone (keys need no user authentication, doc §1 fact 3) can therefore
change or wipe the network of any node in the bureau, not only of the leader's own network as today. With §5.3 it
does not have to walk to them: one `net_state` (or `inhibit` with "全部") handed to one node is forwarded by honest
nodes across the mesh. `inhibit`-all on every node of an incident is recoverable only by visiting each node with a
phone. §7.1 lists for this actor "移進移出、換密碼" and neither inhibit nor the bureau-wide scope.

§7.1 also claims the thief "**不能**加入外來節點（節點必須有本單位的節點證書）": nodes do not check each other's
certificates (the mesh is one SAE password, §7.3); the signer chooses the password and may wrap it for any ECDH key.
The check exists only in an honest app. The claim should be deleted.

(b) §3.3 `inhibit` row ("持 NET 的金鑰（本單位）"), §5.3, §7.1 row 3, D2.

(c) Decide the default scope of an ordinary admin certificate (own station) and how a node knows its station (it
needs its own node certificate or a station id in the record — see M10); cross-station work then uses an explicit
grant. Make `inhibit` session-bound (not forwarded), or require more than NET for "全部". Put the residual blast
radius in §7.1 in numbers (nodes reachable per stolen key, with and without proximity).

### M4. ENROL includes "改信任錨": a compromised registrar can take its nodes away from the root for good

(a) A registrar key (per station, possibly a phone, §3.1) signs a `trust` object replacing the agency root with its
own key on every node it can reach ("改信任清單 = 由現有 OWN 信任錨（或其 ENROL 證書鏈）簽", §3.2). From then on the
root's CRL no longer chains to those nodes' anchor, so "根可撤登記員（其下全部失效）" (§7.1) has no effect on them;
recovery is the physical factory reset of §7.4. That makes the offline root with two FIDO2 keys only as strong as the
weakest registrar phone.

(b) §3.2 last two bullets, D3, §7.1 "被入侵的登記員". Also: enrolling an unclaimed node needs no certificate at all
from the node's point of view — the node accepts whoever passes CheckMac (`node/node.go:566-576`) — so ENROL is not
needed on the node for first enrolment.

(c) Changing an existing trust list requires the OWN anchor's own signature (root for a squad); ENROL covers issuing
node certificates and, if wanted, factory reset. State how a node enforces "限本分隊" for any ENROL action it does
accept.

### M5. The unit identification key: rotation cannot be carried out, a missed rotation locks nodes and phones out, and it does not fit the existing limits

(a) Rotation "隨信任清單更新一起換（例如有人離隊後）" (§3.5) means a root-signed trust update on every node of the
agency plus the new key to every phone, each time someone leaves. Nodes that are off or at another station keep the
old key. A node that missed one rotation is covered by "舊金鑰保留到下一次更新"; the other direction is not covered:
a phone that already holds only the new key can neither recognise the advert of a node still on the old key nor
complete NXpsk0 with it (a claimed node answers only in PSK mode, `provd/noise.go:53-97`). The three-months-off node
is then invisible to every phone and reachable only by factory reset. A phone that missed two rotations is locked
out of every node until it visits the issuing station.

(b) Limits in the code: the handshake tries exactly 6 PSK candidates, fixed for timing (`provd/noise.go:20-21`,
`:74-75`). The doc needs per anchor current + previous unit key; the trust list allows up to 4 anchors (§3.2), i.e.
up to 8, plus member and replay. The advert has room for one 3-byte tag (`cmd/batman-provd/bluez.go:41`; 10 B
left of 31, `docs/design/329-rotating-id-plan.md` F9), so a club member's node (family anchor + club anchor, S8) or a
node during rotation can be recognised under one key only. The tag key is derived per device id
(`proto/proto.go:161-163`, `:171-176`): a phone that does not already know the device id (an admin from another
station, a recovered phone, no inventory) cannot resolve the tag at all. A10 says only "位元組預算要重算".

(c) Decide: the unit key is long-lived and treated as semi-public (then say so in §7.3 and drop the rotation
promise), or phones keep every past unit key and the advert carries a key generation. Fix the candidate budget
(which keys occupy the 6 slots) and the advert rule for a node with more than one anchor. State the derivation for a
phone that does not know the device id.

### M6. S2 (family phone lost → new phone scans the recovery card, nodes untouched) does not work with what the card holds; and claim/replay breaks

(a) Step by step: new phone, fresh install, scans the card = the recovery private key (§3.1 "紙本 QR，含私鑰").
To talk to a node it needs the unit identification key (§3.5: PSK of the handshake and the advert key) — it was only
in the lost phone and in the nodes. Without it the phone cannot find or open a session with any claimed node. Next it
needs the inventory (which nodes, their ECDH keys) and the network secrets — "家長手機的紀錄" (§5.1), lost. Root
passwords of the nodes (returned once at claim, `node/node.go:587-609`) — lost. The recovery key itself is now a
software key in app memory on a phone whose policy is hardware-only keys (doc §1 fact 3); the doc does not say it is
replaced after use.

Second, §3.5 says "成員 PSK 與 replay PSK 不變". The replay PSK and `claim/replay` (the recovery of an interrupted
claim, `E_LOCK_INCOMPLETE`) require exactly one owner and that owner's ECDH public key
(`node/node.go:444-448`, `:639`, `:653-672`). The trust list entry is `{公鑰, 範圍}` (§3.2) with two OWN entries for a
family and a root signing key for a squad: neither has an owner_enc_pub, and "exactly one" is false. An interrupted
enrolment then has no recovery path.

(b) As cited; §3.1, §3.2, §3.5, §5.1.

(c) Define the card's contents (recovery key + unit key, or a seed both derive from; say what is deliberately not on
it) and the steps after the scan: new hardware key installed by a recovery-signed `trust`, recovery key rotated and a
new card issued, inventory rebuilt from which source, mandatory rekey, root passwords reset. Redesign claim/replay
for the trust list (who may replay an interrupted enrolment, with which key) or state that it is removed and what
replaces it.

### M7. OTA and downgrade: A6 is answerable from the source today, the answer is "the old image rejects it", and converting during the trial boot breaks the A/B revert

(a) p5 `prov.cbor` is shared by both slots. The doc converts key 6/8/9 "一次性…寫在 p5 交易內" at the OTA (§6.2).
If that happens before the slot is committed and autocommit reverts (the normal A/B safety path), the old helper
reads the record: any added key fails the exact-key-count check, a bumped version is `ErrTooNew`, and both end as a
verdict `unknown(...)` — the node keeps its mesh but can no longer be managed from the app, and the fix is a bench
visit. The doc's fallback idea "新欄位另存、舊欄位保留" cannot be an extra key in `prov.cbor` for the same reason.
After the commit, a manual rollback puts an image in charge that ignores the trust list and every revocation, and
whose key 9 holds a password the node may no longer be using.

(b) [src] `provstore/provstore.go:112-131` (strict: 11 or 12 keys, v == 1), `:255-256`; `boot/boot.go:270-271`
(`unknown(too-new)`); `keystore/keystore.go:266-267` (a non-`file` backend marker is refused);
`feed/batman-provision/files/usr/bin/batman-config-save:17-20` (`--prov-only` writes exactly record + meta +
identity) and `:435-436` ("identities are written once"). The doc marks A6 "未查 ❓"; REVIEW.md item 4 requires
unverified assumptions to be checked before approval, and this one needs only reading.

(c) Decide here: where the new state lives (a second p5 file with its own meta that an old slot never opens), when the
conversion happens (not before the slot is committed), what the v1 record contains after the first new-model change
(and that an old image then fails closed in a stated way), and the downgrade row's honest result ("revocations are
not enforced by an older image" belongs in §7.3). Include the app's records (`net/<id>`, `node/<id>`,
`rust/batman-proto/src/netrec.rs:1-17`): §6 has no migration row for them at all, nor for an app downgrade.

### M8. Automatic delivery of a new password over the mesh can split the mesh; A5 is unprobed and the fallback is the manual path the design set out to remove

(a) Eight nodes in a building, multi-hop. Node lost → rekey (S5). Default design (§5.3, A5 unsupported): "收到即轉送
再切換". Any node that misses the object before its only neighbour switches is on the old password with nobody to
hear it; everything behind it is cut off too. Recovery is a phone walking to each stranded node — during the
incident. Today's flow is slow, but it never by itself takes a node off a working mesh while leaving its neighbours
behind. There is no acknowledgement, no pending/commit step and no hop-aware delay in the decision; "延遲一小段" is
not a bound.

Also new: provd gets a listener on bat0 (A9). Clients on a node's AP can already reach provd's HTTP port in its
windows (the source reasons about "anyone on the AP", `provd/http.go:45-47`), so "只接受目前網路內的來源" (§5.3) is
not a property an L2 mesh can give; the reachable set is every IP host bridged into the mesh. The listener must also
survive bat0 going down and up at every password change (a row missing from §6.2).

(b) §5.3, A5 "❓ 無", A9; REVIEW.md item 4. [est] mesh-mode SAE in wpa_supplicant takes one password per mesh
network block; I know of no dual-password mesh support, so A5 is likely false.

(c) Probe A5 before approval. If false, the decision needs a convergence rule (store as pending → confirm reach →
switch, with a stated upper bound and what a node does when it finds itself alone after a switch), and §2 S5 must say
"automatic when every node is reachable at that moment; otherwise by phone" instead of "密碼自動送達". State the
listener's reachable set and its limits (object size, per-source rate, total rate) as contract values.

### M9. "隊員 0 步" (S3) is not true as written, and the member's view depends on things nobody delivers

(a) Walk a member through a turnout. Before: the member's phone must have been enrolled at ICS (certificate + unit
key) — counted elsewhere, but it makes ICS availability a precondition for a new member (ICS down for a week = no new
members, no VIEW). At the scene: (1) which of the 8 advertising unit nodes is the one on the member's belt? Nothing
binds a person to a node; the member must pick it. (2) The phone must join that node's Wi-Fi AP to use TAK — the
reason the node exists. The AP password is a DEV setting, and `settings/get` never returns a password
(`node/settings.go:4-6`); a VIEW certificate can neither read nor set it. Today each member owns their node and sets
it. (3) Status: the member role today comes from the member PSK derived from net_root (`provd/session.go:82`,
`proto/proto.go:178-180`); members no longer hold net_root (it is wrapped for nodes only), so "成員 PSK 不變" keeps a
credential no member has. Status then needs the VIEW certificate path, which phase 1 (family, one phone) never
exercises.

(b) §2 S3, §3.4, §3.5, §4.

(c) Count the member's real steps (pick node, get onto its AP) and decide who provides the AP credentials (the admin
at build time? a per-network value inside `net_state`?). Say what the member PSK is for after the change, or remove
it from the candidate list (it frees a slot for M5).

### M10. Resources and lifecycle rows missing from §5 and §6 (REVIEW.md items 1–3)

Resources with no owner / contract row:
- the node's own certificate (where stored, who may replace it, what a node does without one — M3/M4 depend on it);
- the node's root password and SSH keys (MAINT): the password is generated at claim and returned once
  (`node/node.go:587-609`); for a squad it lands in ICS or a registrar phone — a secret store the §3.1 table omits;
- the previous unit identification key and its lifetime; per-net-id version marks after a network is removed (B1);
- CRL storage: sets only grow (no clock, so nothing expires), inside a 64 KiB record that also holds several stored
  networks (`provstore/provstore.go:66`, `feed/batman-provision/files/usr/lib/batman/prov-lock.sh:8`); the root's
  CRL must name certificates issued by registrars, whose serials are per issuer;
- record `state` (legacy / unclaimed / claimed / member, `provstore/provstore.go:28-33`, mirrored in `prov.meta`, p6
  `last_known_state` and `prov-lock.sh`): which state an enrolled node with several stored networks and none active
  is in;
- the update / bulk work keyed to the owner key that started it (`node/node.go:832-838`, `:990`): which key owns an
  update started by admin A when B continues;
- the mesh-expected / mesh-joined markers that autocommit reads
  (`feed/batman-provision/files/usr/sbin/batman-slot:554`) under `inhibit` and network switch;
- the inventory has two writers as soon as a registrar phone enrols at the scene (§4 row 2) while "清冊：小隊 ICS"
  (§5.1).

Lifecycle rows missing in §6.2: clean shutdown; restart of dependencies (bluetoothd, network / wifi reload — the bat0
listener); crash loop of provd with the new listener; power loss during a trust-list or CRL write and during
factory reset; switching the active network; node off for months (M1, M5); file identity → 608B identity (M11);
phone replaced / app reinstalled / app downgrade (Keystore keys die with the install); phone clock wrong; ICS
unreachable. §6.2's row "回退" has no behaviour (M7).

### M11. Phase plan: phase 1 is not self-contained, and phase 2 is not "only a backend swap"

(a) Phase 1 lists "信任清單取代 key 6 / 8；證書鏈驗證；net_state" for a family with one phone and two nodes.
- Replacing key 6 removes the per-owner tag key the login PSK is derived from (`node/node.go:437-442`), so phase 1
  must also deliver §3.5 (unit key, new `auth`, the advert key change A10). §9 row 1 does not list it.
- A family has no certificates (the anchor signs directly). Chain verification, permission bits, scope and CRL lookup
  would be merged with no product path using them — the project rule is to build the product path, not checks for
  features that do not exist yet. Either a certificate user is in phase 1 (a second family phone with VIEW or NET) or
  chain verification moves to the phase that first needs it.
- S1 says "多一步存復原卡" and §4 puts it in "建立我的家", but the recovery card is phase 3. Phase 1 as listed gives
  OWN = 1 key and a lost phone still means reflash; say so, or move the card.
- B3: the shipped flows between phase 1 and phase 3.

Phase 2: the device id is SHA-256 of the identity public key (`keystore/keystore.go:42`, `:296-298`) and the 608B
generates its own keys, so moving an enrolled node from the file backend to the chip changes its identity, ECDH key,
claim secret and body QR; p5 refuses a second identity (`batman-config-save:435-436`). Every node enrolled in phase 1
is re-enrolled and every network rebuilt. Acceptable for bench nodes, but it is a lifecycle row and a phase 2 cost,
not "第 2 期只換後端".

(c) Rewrite row 1 with its real contents and its user-visible result; add the file → chip row.

### M12. Squad flows rest on links and an ICS client that are not specified (phase 4), and on a registrar-key decision left open

(a) "節點入庫…小隊在 ICS 或登記員手機上做": ICS enrolling a node means ICS speaks the BLE + Noise provisioning
protocol and scans the body QR — a third client implementation besides the app; A8 lists only "COSE 簽發、P-256 根、
登記員角色". "ICS → 手機的同步包" (§5.2) has a reader and a writer but no link: over the mesh IP network from the
phone's node AP, over station Wi-Fi, or QR in person? That decides whether "回報遺失 → 管理員手機同步後自動帶出去"
can happen during an incident at all. The registrar key is "由 ICS 保管，或其手機 Keystore；實作設計決定" (§3.1):
if ICS keeps it, a brand-new node cannot be enrolled at a scene without connectivity to ICS; if the phone keeps it,
the inventory has a second writer and ICS learns of nodes late. Q1 asks the user about appointing admins in the field
but not about enrolling nodes in the field.

(b) §3.1, §4 rows 2/3/7, §5.1, §5.2, A8.

(c) Decide the registrar key's home now (it fixes the offline-enrolment answer), name the sync link(s), and add
"enrol a node at the scene, ICS unreachable" and "ICS down for a week" to §2 with their honest outcome. Put the ICS
BLE client into A8 and the phase 4 estimate.

---

## MINOR

### m1. Sizes and round trips are not stated (U2: performance)

[est] One member entry ≈ 95 B (device id 9 + AEAD of {SAE 24 chars, net_root 32} with a shared ephemeral key + CBOR),
≈ 160 B if the ECDH public key is included (B2). Fixed part ≈ 230 B, a 2-certificate chain ≈ 360 B.

| nodes | `net_state` + chain | BLE frames at 244 B | note |
|---|---|---|---|
| 8 | 1.4–1.9 KB | 6–8 | one Noise message |
| 30 | 3.4–5.4 KB | 14–23 | one Noise message |
| 100 | 10–17 KB | 42–68 | over `MaxMsg` 8192 (`provd/frame.go:15`) → chunked request |
| ~400–680 | ~65 KB | — | hard cap: `MaxReassembled` 65400 (`provd/session.go:94-98`), helper `MaxRequest` 65536 (`sock/sock.go:25`) |

Three stored 100-node networks ≈ 30–50 KB of the 64 KiB record (`provstore/provstore.go:66`) before CRLs. A QR is
practical to about 1–2 KB, so a `net_state` for more than ~8 nodes cannot be a QR and an "互通設定" QR must be
something smaller. The app's own member cap today is 16 (`MAX_MEMBERS`, `rust/batman-proto/src/netrec.rs`).
"勾選建網" for 8 nodes without an inventory is two BLE sessions per node (read key, then deliver): 16 logins at the
2–8 s each that `329-rotating-id-plan.md` reports, plus one wireless transaction per node. Three taps, but one to
several minutes of standing next to the nodes; say so, and state the member cap as a contract value.

### m2. Key attestation at enrolment needs more than "手機顯示 QR（公鑰 + 金鑰證明）"

Android attestation is produced at key generation with a challenge from the verifier, so the key must be generated
after ICS issues a challenge (two directions, not one QR), the chain is several X.509 certificates (about 2–3 KB
[est], beyond one QR), and verifying it needs Google's roots and revocation status on an offline ICS. The existing
keys are generated at first run without a challenge (`Keys.kt`, `generate`). State the flow shape and that the
enrolled key is a new key.

### m3. Expiry checked only by the app is an availability risk with no security value

§7.3 says expiry "只是讓手機 app 不再使用過期證書". A phone whose clock is wrong (ahead) or an ICS that is down at
renewal time locks an administrator out mid-incident, while a thief is not affected. The app should warn, not refuse;
nodes with trusted time (#174) must not make a network unmanageable because one RTC is wrong (state the rule).

### m4. `auth` and the role model in provd

§7.2 says provd "只轉交位元組", but today provd itself verifies the login signature against the owner list and sets
the session role that gates every request type (`provd/session.go:75-83`, `:826-850`). With certificate chains provd
needs either the trust list and CRL (it is the BLE-facing, non-root process) or a new helper verb for the role
decision, and five permissions must map onto session roles. One sentence deciding which is enough.

### m5. Cross-agency interop (S7) trust path

A node accepts a `net_state` only from a signer under its own anchor, so two agencies cannot share one signed
object; each agency's admin must sign its own state for the same net id / password, received how (the bare secret by
QR?) and rekeyed how ("每次任務換")? Phase 5, but "範圍（全部或指定網路）" in the certificate and who owns an interop
net id's version are format decisions made now.

### m6. Concurrent admins, same password, different member lists

Two admins each add a node at v5 on two sides of a partition that still share the password. After the merge the
admin's app reads v5 from one node and signs v6 from that variant: the other side's new node is silently dropped from
the list while still holding the password ("不在清單內 = 不動現有設定"). Require the app to read the stored state from
more than one node, or make the conflict report carry both member lists.

### m7. Revoking a registrar

"其下全部失效" also invalidates every node certificate and every personnel certificate of that station at once. Say
what still works (stored networks, per M2) and what the station must redo.

---

## Facts and citations in the doc I checked

Wrong or unsupported:
1. A6 "未查 ❓": answerable from source — an older image rejects any unknown key or newer version
   (`provstore/provstore.go:112-131`, `boot/boot.go:270-271`). The proposed "新欄位另存" cannot be a new key in
   `prov.cbor`. (M7)
2. §3.5 "成員 PSK（由 net_root 導出）與 replay PSK 不變": unsupported. The replay PSK needs exactly one owner and its
   owner_enc_pub (`node/node.go:444-448`, `:639`); members hold no net_root in the new model. (M6, M9)
3. D11 / §4 last row "保留不動 / 不變": unsupported; the SAS join depends on key 8 and the self-signed admin chain
   that §3.2/§3.3 remove (`node/node.go:1106-1123`, `:1167`, `:1192`). (B3)
4. §3.3 "漏掉幾版的節點拿到最新一版就能追上": contradicted by the +16 rule in the same section. (M1)
5. §7.1 "**不能**加入外來節點": not enforced by any node. (M3)
6. §7.2 "provd … 只轉交位元組": not true of the login today (`provd/session.go:826-850`). (m4)
7. §7.2 M1 "所有物件版本只增": `inhibit` has no version. (B1)
8. §9 "第 2 期只換後端": the identity, device id and ECDH key change (`keystore/keystore.go:42`, `:296-298`). (M11)
9. A10 understates the change: the advert tag key is bound to the device id (`proto/proto.go:161-176`) and the advert
   has one tag. (M5)
10. §1 omits a fact the new model must place: the claim returns the node's root password
    (`node/node.go:587-609`). (M10)

Checked and correct: §1 facts 1, 2, 4, 5, 6, 7, 8, 10, 11 (line ranges are close; `Backend()` is at
`keystore.go:68-69`), fact 3 (`Keys.kt` generate / level read-back; `254-app-remove-member.md:38`), fact 9 (no time
check in the node's certificate check; the app uses the wall clock for display only), fact 12
(`release/release.go:1-4`), A4 (`cose/cose.go:35 ff.`), A7 (`provstore/provstore.go:9`, `node/node.go:1107-1108`).

Not checkable in this worktree: every statement about ICS_COMMAND (§3.1, §3.4, §7.1, §7.5, A8), the 608B timings
(A2), the Android attestation claim (A3), and the §6.2 statement that autocommit decides by membership (not traced).

---

## Verdict

**REJECT** (3 BLOCKER, 12 MAJOR, 7 MINOR). The model in §3.1–§3.2 and the split of roles can stay. What must change
before per-phase designs start: the freshness and delivery rules of the signed objects (B1), how a second
administrator gets the network's content (B2), and the fate of the existing authorisation path and flows (B3); then
the whole document is reviewed again per REVIEW.md.
