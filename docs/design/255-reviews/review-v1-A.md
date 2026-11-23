# Review v1-A of `docs/design/255-key-authority.md` (design v1)

Reviewer A, independent. Base: worktree `C:/src/Batman-255`, main 4eba26d + the design file. Method: whole document
read; every §1 fact and §8 assumption that cites this repo checked by reading the cited source; attacks walked per
actor (REVIEW.md item 5). Nothing was run on a node, nothing built. ICS is not in this worktree, so every ICS statement
is unverified (listed at the end). Go paths are under `feed/batman-prov/src/`, Rust under `app/rust/batman-proto/src/`.

Baseline not re-litigated: QR claim + CheckMac, the Noise channel, the SAS three-step join, `wtxn.go`, A/B update. They
appear below only where the new design changes what they rest on.

Direction (D1 one mechanism / two deployments, D4, D5, D12 walking skeleton first) is sound. The findings are about
trust rules and formats that phase 1 freezes.

## Findings

### BLOCKER

**B1. A registrar (ENROL chain) may sign `trust`, so one branch registrar can replace the agency root on every node, and
the root can never undo it.**

(a) Scenario: the equipment officer of branch A (registrar certificate, ENROL) — or whoever steals that phone or that
ICS account — signs a `trust` object with a higher version whose only OWN entry is a key of their own, and walks it
past nodes (any branch: all nodes of the agency trust the same root, S6). Each node accepts it. From then on the root's
`crl` revoking that registrar no longer "chains to a trust anchor" on those nodes (§3.3 `crl` row), so §7.1's remedy
"根可撤登記員" does not work exactly where it is needed. Recovery is §7.4 step 3 (physical factory reset of every node):
a registrar compromise costs the same as a root compromise.

(b) Evidence: §0 D3 (ENROL = "入庫、改信任錨、恢復出廠"); §3.2 last bullet ("由現有 OWN 信任錨（或其 ENROL 證書鏈）簽");
§3.3 `trust` row; §7.1 "被入侵的登記員" row, which claims the damage is limited to "替自己分隊發假證書".

(c) Fix: `trust` is accepted only when signed by an OWN anchor key itself, never through a chain. ENROL on a certificate
is limited to (i) first enrolment of an unclaimed node (already gated by the QR secret) and (ii) issuing leaf
certificates. Remote factory reset by certificate is dropped or made anchor-only. Negative control: registrar signs
`trust` -> refused.

**B2. The chain rule has no issuer constraint: "≤3 levels + permissions ⊆ parent" lets any certificate issued directly by
an anchor issue further certificates.**

(a) Scenario (phase 1, family): the parent phone is the anchor and issues a NET certificate to a family member (§3.1
row 4, §3.4). That is a 2-level chain. The family member signs a certificate for a third key with NET ⊆ NET: 3 levels,
every signature valid, subset holds -> every node accepts the third key as a network admin. The same works in a squad
for any person certificate the root issued directly, and for a captured node that uses its secure element as a signing
oracle when its node certificate was issued directly by the anchor (family: always). Q1's recommended answer
("現場不能任命新管理員") is therefore not enforced by the stated rule. The sub-issuer also becomes a `crl` issuer of its
own (§3.3: "發證者（各管自己發的）").

(b) Evidence: §3.3 `cert` row. The acceptance column, which is what the node enforces, lists only: levels, signatures,
subset, not revoked, not expired. The "簽的人" column says who is supposed to sign; nothing makes the node check it.

(c) Fix: put it in the rule and in the format now. A certificate is an acceptable issuer only if its type is
"registrar", it holds ENROL, and its own issuer is an anchor (fixed shape: anchor -> [registrar] -> leaf; a leaf type —
person, node, guest — never issues). A registrar must not be able to hand out ENROL or MAINT unless the root said so
in the registrar certificate. Spell out the scope rule too: §7.1 says a registrar is "限本分隊", but a certificate's
scope is only "全部或指定網路" + "單位 id", and a node has no notion of which branch it belongs to (it stores only the
agency root), so that limit is not enforceable as written. Either give nodes a branch id at enrolment and check it, or
delete the claim. Negative controls: person certificate as issuer, node certificate as issuer, registrar issuing
ENROL, 4-level chain.

**B3. `net_state` is a bearer object that also performs the first join, so anyone holding an old signed `net_state` can
put a node back into an old network.**

(a) Scenario: node X belonged to network N at version 3. Later X leaves N, or is cleared by `inhibit`, or is factory
reset and re-enrolled under the same anchor, or (D10) N is evicted from its stored set. X now has no stored version for
N, so the rule "version in (stored, stored+16]" has nothing to compare against. A removed member, or the holder of a
captured node (it received every relayed `net_state`, §5.3, and has the unit identification key), connects over BLE and
replays the v3 `net_state`: valid chain, X is in its member list, X can decrypt its own secret (same ECDH key). X joins
the old mesh with a password the attacker knows: X is cut off from its team and its traffic is on the attacker's mesh.
No key is needed, only the object. Today this is not possible: the first version needs a fresh owner-op
(`node/node.go:1106-1117`, "the owner-op (already verified) is the trust anchor"; `node.go:778` exempts only
`network/update`).

(b) Evidence: §3.3 `net_state` row; §5.2 ("任何能連上節點的人都能送；靠簽章擋"); §3.3 `inhibit` ("清除指定網路設定");
§6.1 destroy row. §7.2 M1 says "節點落地最高版本" but nothing says the floor outlives the network record.

(c) Fix (decide now; it shapes the object and the store): a `net_state` for a net id the node does not currently store
is accepted only inside an authenticated session together with a fresh `op` (session hash + node nonce) from a
currently valid NET holder. The relay path and replays can then only *update* networks a node is in. In addition keep
per-net-id tombstones (net id -> minimum version) across leave and `inhibit`. Negative control: replay of a pre-leave
`net_state` after leave / inhibit / reset + re-enrol is refused.

### MAJOR

**M1. Revocation floors do not survive enrolment or factory reset, and the missing-CRL fail-open makes a revoked
credential fully valid on every fresh or reset node.**

(a) Scenario (S4/S5): an admin phone is stolen; ICS revokes it; CRL v8 reaches the deployed nodes. Next week a spare
node is enrolled, or a node is factory reset and re-enrolled. It has "no list = empty list" (§5.2). The thief's
certificate verifies on it; the thief has NET there until an honest admin happens to log in to that very node. The
compensation in §5.2 ("管理員 app 每次登入都會推") is a race the attacker can win, and "版本只增" protects nothing when the
stored version is absent. Also unbounded: nodes have no clock (D7), so revoked serials can never be pruned; the CRL
lives in `prov.cbor` (§5.1), which is capped at 64 KiB (`provstore/provstore.go:66`) together with the multi-network
state; nothing says what the node does when it no longer fits.

(b) Evidence: §5.2 `crl` row, §6.1 destroy row, §6.2 enrolment row; `provstore.go:66`.

(c) Fix: the stated reason for fail-open ("a new node must be usable when enrolled in the field") only needs the
*enroller* to carry the lists. Make enrolment install them: the enrolment / `trust` object carries, per issuer, the
minimum CRL version the node must hold (a floor signed by the anchor), and the node refuses chains from an issuer whose
CRL it holds below that floor (fail-closed above an explicit floor; fail-open only for issuers with floor 0). State the
CRL size bound and the behaviour at the bound (fail-closed for that issuer). Negative control: reset + re-enrol, then
the revoked key is still refused.

**M2. The version window "(current, current+16]" contradicts the catch-up property it is introduced with, bounds
nothing, and gives a stolen key a way to strand nodes.**

(a) Scenarios.
1. §3.3 says a node that missed several versions "拿到最新一版就能追上". A node that sat in a store room through 17
   changes rejects the latest state forever; the admin has to mint bridging states, which the app flow (§4) does not
   have.
2. The stated purpose is to stop a stolen admin key exhausting the version number. It does not: every accepted state
   moves `current`, so the thief sends v+16, v+32, ... (one signature each).
3. It is an attack tool: the thief pushes node A forward by 16·k in k messages. Whatever the honest admin signs next
   must be above A's version, so it is more than 16 above every other node and they all reject it; the mesh stays
   split until someone steps each lagging node by hand.
4. "Same version, different content -> keep and report" is first-writer-wins per node: after two admins act
   concurrently, different nodes legitimately hold different version-n passwords. The "report" has no reader: §5.2
   has no contract for it.

(b) Evidence: §3.3 bullets 1-2 after the table; §7.1 stolen-phone row ("版本最多推進 16"); §7.2 M2.

(c) Fix: drop the window; use a 64-bit version and accept any higher version (complete-state catch-up then really
holds; exhausting a u64 is not a threat; recovery from a hostile jump is "sign higher"). Make the order total and
deterministic so nodes converge without a human: compare (version, object hash) and take the greater, or define
another tie-break. Define the conflict report as an interface (who reads it, what the app does). Add the stranded-node
case to the two-admin bench test.

**M3. Networks are not bound to the authority that created them, and `inhibit` is unversioned and can exceed the
signer's scope.**

(a) Scenarios.
1. S8: a club member's node has OWN = the member's keys and NET_ONLY = the club key (§3.2). A trust entry's scope is
   only OWN / NET_ONLY, so the club key "持 NET 且範圍涵蓋此網路" for *any* net id, including the member's home network:
   the club admin can sign the next version of the home network (re-keying it under the club's control, or dropping
   the home nodes) and can send `inhibit` "全部".
2. `inhibit` has a target and a net id but no version, nonce or session binding, and it is relayed over the mesh
   (§5.3). Anyone who once saw one (every member node did) can replay it after the node was legitimately re-added: a
   permanent, keyless off-switch for that node.
3. `inhibit` "全部" lets a NET holder whose certificate is scoped to one network wipe every stored network (D10:
   including interop networks).

(b) Evidence: §3.2 (entry = `{公鑰, 範圍}`), §3.3 `net_state` and `inhibit` rows, §5.3 first bullet.

(c) Fix: each stored network records the anchor it was created under; only a chain to that anchor, with a scope that
covers the net id, may update or inhibit it. `inhibit` names one net id ("all" only when the signer is OWN) and carries
a version in the same number space as that network's `net_state`, so it is one-shot and ordered against re-adds.
Negative controls: NET_ONLY key updates a network created under OWN -> refused; replayed `inhibit` after re-add ->
refused; scoped NET sends "all" -> refused.

**M4. D11 says the SAS three-step join is "kept unchanged", but it rests on the admin list this design removes; the
authority over a network on a node with no common anchor is undefined (same gap for S7).**

(a) Scenario: a node joins a foreign team by SAS. Today its later updates are authorised by the admin keys copied from
the config into key 8 (`node/node.go:1167` `admins := rec.Admins`, `:1192`, `:1266` `next.Admins = p.admins`). §3.2
replaces key 8 by the trust list and §3.3 replaces the +1 chain by "signed by a NET holder under a trust anchor". The
foreign admin is under no anchor of this node, so after the join either nobody can ever re-key that network on this
node (a removed member can never be locked out of it), or the join silently adds the foreign key as NET_ONLY (cap 2,
and then M3 applies). The document does not say which. S7's "各自載入互通網路設定" has the same hole: one `net_state` has
one signer and one chain, the nodes of two agencies trust different roots, and a state relayed from the other agency
will not verify.

(b) Evidence: D11; §3.2 first line; §3.3 "與今天的差別"; §4 last two rows; source lines above.

(c) Fix: decide it here, because it fixes the object format. For example: a network has exactly one authority key set,
recorded at first join (anchor-derived for own networks; the foreign admin key for a SAS or interop join, authorised
by a fresh local `op`), and only that authority updates it. For S7 state whether an interop network is N parallel
per-agency states sharing a secret (then say how a re-key is coordinated) or one state signed by a guest authority.

**M5. The unit identification key is one symmetric key for the whole agency, has no workable rotation, and undoes an
earlier decision.**

(a) Scenarios.
1. The key is per trust anchor (§3.5) = per agency root (D2), stored on every node and every member phone (VIEW
   included). One captured node or one departed member has it. Rotation rides on a `trust` update, which only OWN can
   sign: for a squad that is the offline root, for every node of the agency. The "回報遺失" flow (§4) does not include
   it. So after the first loss the key is known outside for good, and whoever holds it can recognise (track) every
   node of the agency from its BLE adverts. Today the advert key is per node (`329-rotating-id-plan.md:51` F18). For
   the tactical tier this is a location leak, not only "outsiders reach the certificate check" (§3.5).
2. One key for both the advert identifier and the Noise PSK means provd must hold it. The frozen decision is that a
   compromised provd must not get advert keys (`node/node.go:433-436`; `329-rotating-id-plan.md:55` F22).
3. provd tries exactly 6 PSK candidates and maps the index to a role (`provd/noise.go:17-21`,
   `provd/server.go:738-781`). New + old unit key per trust entry (up to 4 entries), a member PSK per stored network
   (D10) and replay do not fit in 6; changing the count changes handshake cost and the role mapping.
4. "舊金鑰保留到下一次更新" leaves a phone that missed two rotations with no way in; not stated.

(b) Evidence: §3.5, §3.1 last row, §5.1 row 1, files cited above.

(c) Fix: keep the raw key in the helper only. Derive per-node values (`HKDF(unit_key, label ‖ device_id)`, as
`proto.PskOwner` does today, `proto/proto.go:158-160`) with different labels for the advert key and the PSK; provd
gets only the derived PSK. State who rotates the key and when: it must be doable by something less than the offline
root, or be documented honestly as "not rotated; assume public after the first loss", with the tracking consequence
in §7.3. State the PSK candidate budget.

**M6. MAINT is root on the node, which makes the five-permission lattice weaker than the document presents.**

(a) Scenario: a maintenance technician's certificate (MAINT), or that stolen phone, sets an SSH key or resets the root
password (`ssh_keys/set`, `root_password/reset`: owner verbs today, `provd/session.go:78-81`, `node/node.go:774-777`).
Root on the node reads `prov.cbor` (all network passwords, the unit key) and can rewrite the trust list file directly;
there is no secure boot (219 P5). So a MAINT certificate is OWN on every node it can reach, without ever holding
ENROL, and it is agency-wide unless scoped.

(b) Evidence: D3; §3.4 "維修" row; §7.1 has no row for a MAINT holder.

(c) Fix: say so in §7.1 / §7.3 and restrict accordingly: MAINT is issued like ENROL (root / sysadmin only), is scoped
to named node ids, and gets a short life where the node has trusted time. Check DEV the same way (which
`settings/set` keys can lead to code execution or open an interface).

**M7. The squad root is a software key derived on the issuing host, on the same master as everything else in ICS; U1
("the root does not go to the field") is not shown to hold.**

(a) Scenario: U4 makes ICS_COMMAND the issuing station; registration, "report lost" and CRL signing are daily
operations. If the root is derived from the ICS master in that host's memory (§3.1 row 1; §7.1 admits ICS unlocks once
at start today), any compromise of that host — possibly the machine that goes to the command post — is a root
compromise, at the §7.4 price (every node physically reset). Because the Batman root, and by D9 the TAK CA, are HKDF
labels on one master, D9's separation is nominal against this actor, and "根換代" by a new label does not recover from
a master leak.

(b) Evidence: §3.1 row 1; §7.1 "被入侵的 ICS 主機" row (⚠️); §7.4 item 5; A8. None of the ICS facts can be checked in this
worktree.

(c) Fix: decide here (it sets the chain shape, which B2 fixes at exactly one intermediate level): the root signs only
registrar certificates, root CRLs and `trust`, in a session or on a machine that is not the daily ICS; daily ICS
operations use a registrar-level issuing key. State where ICS_COMMAND physically runs. If ICS cannot do this, U1 needs
a different custody (for example the root on a hardware token; P-256 signing is available there). That last choice is
a product-direction point for the user.

**M8. The downgrade / automatic-revert row is left open, and the source already answers A6: the old image refuses the
new record.**

(a) Scenario: an OTA installs the image with this change; the first boot migrates key 6 / 8 / 9 into the new format on
p5 (§6.2 OTA row). The trial then fails and the A/B mechanism reverts on its own. The old helper decodes strictly:
exactly 11 or 12 keys and `v == 1`, otherwise a schema error or `ErrTooNew` (`provstore/provstore.go:112-131`), and
`resolve()` refuses to finish anything against a record that does not decode (`node/wtxn.go:270-274`). The node comes
back on the old slot with an unreadable provisioning record: not manageable from the phone, and a pending wireless
transaction stays unfinished. This is not an operator-chosen downgrade; it is the normal revert path.

(b) Evidence: §6.2 "回退" row (⚠️ "需決定"); A6 (❓ "未查"); files above.

(c) Fix: decide in this document. Either no in-place migration before the new slot is committed (the new helper reads
the old format and writes the new one only after autocommit), or the new data lives in a separate p5 file the old
image ignores while `prov.cbor` stays v1-valid. State the security side as well: after a revert the old image
re-authorises whatever is in key 6 / 8, so a key removed under the new model must also be removed there. Mark A6 ✅
with the citation. Rows REVIEW.md requires and §6.2 lacks: OTA stage 1 / stage 2 separately; crash loop of helper or
provd while a `trust` or `crl` write is in flight; power loss during a `trust` / unit-key change (is the key change
atomic with the list?); restart of each dependency (bluetoothd; bat0 / network for the relay listener); clean
shutdown (not applicable — say why).

**M9. Root roll-over and anchor replacement are not workable as written.**

(a) Scenarios.
1. §6.1 roll-over is "old root adds new root -> both -> new root removes old". The family list is already full (OWN
   cap 2 = parent + recovery, §3.2), so S2 (new phone after a loss) cannot add-then-remove; it needs a one-step
   replace, which is not described.
2. When the old anchor is removed, every certificate under it stops verifying: registrar, person and node
   certificates, with their CRLs. Node certificates have to be re-issued and re-delivered to every node. Nothing owns
   the node certificate on the node (it is missing from §5.1), and `trust` is not among the relayed objects (§5.3),
   so this is a visit to every node, twice.
3. Both OWN entries are equal. A thief with the unlocked parent phone (the keys need no user authentication:
   `Keys.kt:93-98` sets none, and no `setUserAuthentication*` call exists under `app/android`) can remove the recovery
   key before the family uses it; §7.4's "用復原金鑰把外洩的那把移除" is a race the thief can win.
4. Serial numbers are allocated by "the issuer" (§5.1), but a root restored from the mnemonic, or a recovery key
   taking over, has no serial counter: serials repeat, and a serial-set CRL then revokes the wrong certificate or
   misses the right one.

(b) Evidence: §3.2, §5.1, §5.3, §6.1 "更換根", §7.4 item 5.

(c) Fix: define "replace" as one `trust` step and the order of re-issuing; add the node certificate (and the node's
branch id if B2 keeps one) to §5.1 with its owner and delivery path; give the recovery key precedence (for example:
removing the recovery entry needs the recovery key's own signature); revoke by key id or certificate hash, or use
random 128-bit serials, so no counter has to survive a restore.

**M10. Resources and lifecycles missing from §5.1 / §6.**

(a) Each of these has no named owner, or two possible writers: the node certificate (written at enrolment, re-written
on roll-over); the stored-network set and its eviction (a stolen NET key can fill the slots with junk networks); the
active-network selector (which permission may switch it; does a relayed `net_state` for a non-active or new network
ever activate it); CRL bodies (only "已存版本" is listed); the previous unit key; relay de-duplication and rate-limit
state in provd; the conflict report. Phone and station lifecycles are absent although the design moves authority
there: app reinstall or data clear (Keystore keys gone — what is revoked, by whom); phone replacement; the admin
phone's encrypted record of network passwords (a stolen unlocked admin phone also reads the current SAE password —
not in the §7.1 row); ICS restore from backup (inventory and CRL versions roll back: a restored ICS signs a CRL with a
version nodes have already passed, and nodes ignore it).

(b) Evidence: §5.1 table, §6.1, §6.2, §7.1 stolen-phone row.

(c) Fix: add the rows; for each give the single owner and the missing / stale behaviour.

### MINOR

**m1. The signer is not bound into the signed bytes.** The existing envelope has a fixed protected header, an empty
unprotected one, and finds the signer by trying up to 4 keys (`cose/cose.go:37-73`). With chains the signer comes from
an attached certificate. Put the signer key id and the anchor / unit id in the signed payload of `op`, `net_state`,
`crl`, `inhibit`, `trust`, and list each object's content type and label. A4 holds for the envelope only.

**m2. Registration by "phone shows a QR with public key + key attestation" does not work as drawn.** An Android
attestation chain is several certificates (kilobytes), more than a comfortably scannable QR, and an attestation only
means something over a verifier-chosen challenge, which a phone-first QR cannot contain. Verifying it offline also
needs the vendor roots and revocation data on the station. Make the flow station-first (challenge), carry the chain
over BLE, and say what an offline station does about attestation revocation.

**m3. Where `auth` is verified.** §7.2 says provd only passes bytes and everything is verified in the helper, but the
role upgrade is verified in provd today (`provd/session.go:826-848`, "provd's own check"). State that `auth` with a
chain is verified in the helper; provd is the non-root, radio-facing parser and must not own the chain / CRL check.

**m4. "A stolen admin phone cannot add an outside node" is enforced only by the app.** Nodes do not check that the
other members of a `net_state` hold node certificates. Say so in §7.1, or carry the node certificate hash per member
so nodes and other admins' apps can check.

**m5. `net_state` discloses the roster and the new wireless parameters in clear to every node on the old mesh,
including the one being removed** (§3.3 content, §5.3). Encrypt everything a non-member does not need, or accept it
and say so.

**m6. "任務輪次上限" (guest certificates) is undefined:** who counts, where the counter lives, what resets it. On a
clockless node a guest certificate otherwise never ends. Define it or keep it out of the v1 format.

**m7. Phase 1 -> phase 2 changes every node's identity.** The file-backend `device_id` is the hash of the identity
public key (`keystore/keystore.go:42-46`); a 608B has a different key and serial. Member lists, node certificates and
QR labels made in phase 1 do not carry over. "第 2 期只換後端" should say that phase-1 nodes are re-enrolled.

**m8. Relay detail that fixes a contract now.** "先轉給鄰居，延遲再套用" without dual-password support means the only
bridge to a far cluster may switch before the far cluster has the state; the fallback is a person with a phone. State
the expected field behaviour and its test. State also that relayed objects are rate-limited before the signature
check (CPU exhaustion from the mesh by any SAE member, including a captured node).

**m9. §10 lacks negative controls for claimed protections:** registrar signs `trust` (B1); non-registrar issuer and
4-level chain (B2); replay of an old `net_state` / `inhibit` after leave, inhibit or reset (B3, M3); revoked key on a
freshly enrolled node (M1); the stranded-node case (M2); cross-anchor update (M3); update authority on a SAS-joined
node (M4); old unit key refused after the second rotation; relay size and rate limits; relay from a non-member
source; `crl` rollback and `trust` rollback (only `net_state` rollback is listed); software (non-hardware) key refused
NET at registration; chip not answering -> new config refused; migration (old owner key still authorised, a non-owner
still refused); revert to the old image; "格式不認得 = 不降級成未入庫" (listed in §6.2, not in §10).

**m10. The recovery card is a paper QR holding an OWN private key.** A photo of it is permanent, silent ownership of
every node. State it in §7.1 (actor: someone with a moment's access to the card) and consider letting the card key
only *replace* the primary, not operate, so that its use is visible.

## Facts and citations checked and found wrong or unsupported

1. §8 A9: "今天 provd 只面對藍牙（與上傳用的 HTTP）". Incomplete: the HTTP listener carries the full Noise session
   protocol ("the same sessions and routing as BLE") in fallback mode or during an upload window, port 8095
   (`provd/http.go:3-6`). With a unit-wide PSK that surface is reachable by every unit member over IP.
2. §5.1: "只讀的：provd" for the trust list / unit key in `prov.cbor`. Today no other program parses `prov.cbor`
   (`provstore/provstore.go:1-3`); provd gets only HKDF outputs from the helper (`node/node.go:433-436`,
   `provd/server.go:488`). As written the table gives the non-root daemon read access to the record that holds every
   secret.
3. §8 A6 "未查 / ❓": answerable from source — strict key count and `v == 1` (`provstore/provstore.go:112-131`). See M8.
4. §1 item 3 cites `254-app-remove-member.md:38` for "no user authentication"; that line cites `Keys.kt:70-80`, which
   is the generate / delete code. The claim itself is true (`Keys.kt:93-98`; no `setUserAuthentication*` under
   `app/android`), but the citation should point there.
5. §1 item 9 "沒有任何地方檢查時間 … app 無 `SystemTime`": true for `batman-proto` (no hit) and for certificate validity
   on the node (`keystore/keystore.go:148-168`). The Dart side does read the clock (`app/lib/claim.dart`,
   `app/lib/ui/home_logic.dart`, others; not read in detail), so the sentence is broader than its evidence.
6. §7.1 "被入侵的登記員 … 範圍限本分隊": no mechanism in §3 expresses or enforces a branch (B2).
7. §3.3 "+16 的上限是為了讓被盜的管理員金鑰無法一次把版本號耗盡" and "漏掉幾版的節點拿到最新一版就能追上": inconsistent
   with each other, and the first does not hold (M2).
8. D11 "保留不動": depends on key 8, which §3.2 removes (M4).
9. Unverifiable here (ICS is not in the worktree): `auth/role_enum.py` / `ACCOUNT_MANAGER_ROLES`,
   `docs/security/key-management.md`, "ICS main 8e6c740 只有 X.509 / step-ca", the hash-chain log, "啟動時解鎖一次".
   External and not checked by me: datasheet DS40002239B, `calib_execution.c` timings, CMVP certificate 5371, the C509
   draft version, Matter `RemoveFabric` semantics, the NIST / CISA references. They need captured evidence or a ⚠️.

Checked and found correct (line numbers match within a line or two): §1 items 1, 2, 4, 5, 6, 7, 8, 10, 11, 12 —
`keystore.go:111-131 / 182 / 186 / 202-219 / 266-267`, `nodecert.rs:146-156`, `provstore.go:5-9 / 146-189`,
`session.go:68-69`, `joinflow.rs:157`, `rekey.rs:1-10 / 102`, `updflow.rs:1-13`, `proto.go:54-70 / 90-103 / 158-188`,
`node.go:705-746 / 778 / 1106-1125 / 1192-1215 / 1242-1311`, `noise.go:14-107`, `release.go:1-4 / 110-121 / 245-259`,
`cose.go:35-87`. `wtxn.go:255-299` is `resolve()` (which record is the committed one), not the rollback itself; the
rollback is `finish` from `:299` on — a small citation slip, the claim stands.

## Verdict

**REJECT** — 3 BLOCKER, 10 MAJOR, 10 MINOR. The direction stands. The trust rules (who may sign `trust`, who may
issue, when a bearer `net_state` may create membership), the revocation floor, the version rule and the binding of a
network to its authority must be fixed in this document, because phase 1 freezes them in formats and stored state.
Revise and review the whole document again.
