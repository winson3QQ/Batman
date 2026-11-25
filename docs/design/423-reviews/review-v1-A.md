# Review v1-A: #423 security architecture (`security-architecture.md` v1)

Reviewer A, independent, read-only. Checked against branch `design/423-security-architecture` at f73def8.
No node or device was touched. Nothing was run except `git`, `grep`, `gh issue view`.

## Summary and verdict

The document gets the big separations right and they agree with the baseline: five trust roots that cannot
stand in for each other, roles kept out of the node certificate, TAK kept apart, release signature and owner
consent as two separate keys, and an honest table of what each platform state can claim. The #255 PR 3 is not
blocked by it (no new certificate field). The trouble is in the two mechanisms the document adds on top:
**how revocation persists** (a "generation floor" in a chip counter plus a list in a place that does not exist)
and **how objects are ordered** (per-signer sequence numbers). Both are stated as satisfying K4 and K6 in §12,
and for both I can build a counter-example from the document's own text and the repo's own fact file. Several
questions the baseline handed to #423 (§5-2, §5-4, §5-12, §5-13, Q2, Q5) are passed on to the downstream
issues, which in turn list them as inputs they need from #423. This is the same pattern that failed
key-authority v1 and v2: the new mechanisms are where the holes are.

**Verdict: REJECT** (revise §4.2 ordering, §5.1, §5.3, §9.3 keep/clear, then review the whole document again).

**Counts: 2 BLOCKER / 11 MAJOR / 12 MINOR**

Disagreement with the baseline (one line, not a finding): none that I want to re-open.

---

## Findings

### B1 (BLOCKER) — §5.3, §7.2, §9.3, §12 K6, §16 V1: the revocation floor and list have no working home; K6 is asserted, not met

What the document says: the unit generation floor goes into the 608B monotonic counter; the per-key list
goes "outside p5, somewhere factory reset does not touch"; a missing list is "treated as empty"; generation
may only go up by one; "to lock a node you must first get A1".

Scenarios and evidence:

1. **Any bus master can push the counter, and it cannot be undone.** `255-reviews/608b-facts.md:254-258`:
   two counters, max 2,097,151, "There is no way to reset the counters", and "No authorisation parameter
   exists for Counter ... any host on the I2C bus can increment either counter (and so can exhaust it)"
   (marked INFERRED there). So any root process on the node (a maintenance-role holder with a shell, a
   helper bug, the holder of an S-A/S-B node) can push the floor above the unit's generation. The node then
   refuses every management action, and no reflash, card swap or factory reset brings it back, because the
   counter is in the chip. This is the exact trap of key-authority §5-1 ("pushed to the maximum, node
   locked"), moved from the issuing station to anyone with root. The claim "要鎖死節點得先拿到 A1" (§5.3
   last bullet) is false.
2. **Power loss can lock a node by itself.** Same file, line 256: "In some power loss conditions, the counter
   may increment by a value of more than one". The document's rule is "generation goes up by exactly one,
   node rejects a skip". A power cut during the increment leaves the chip floor at N+2 while the unit is at
   N+1: every authorization is now "below the floor". Recovery needs A1 to burn a generation for the whole
   unit and re-issue everybody.
3. **§16 V1 is wrong about what is known.** It says the counter's use and limits "were never read". They were
   read and recorded in `608b-facts.md` §7, and they are unfavourable. The ⚠️ item is load-bearing for K6,
   for §7.2 "floor: only moves forward", for §9.3 "keep", for the §11 "reflash" row and for negative test 4.
4. **Baseline conflict.** `255-608b-config.md` v4 removed counters after review (version table, "拿掉晶片背書
   與計數器"); `255-608b-impl.md` §2.2 lists Counter under "不實作" for the product driver. Using the counter
   re-opens both reviewed documents.
5. **The floor is a bare number with no unit attached (Q-D), and this is not an edge case.** §9.3 clears the
   anchor on a level-4 reset but keeps the floor. §5.5 (family phone lost) re-enrols every node under a new
   phone; every bench node gets re-claimed; a node moves from one unit to another. In all of these the kept
   floor belongs to a unit the node no longer knows. Q-D is listed as "transfer between units", but the
   document's own §5.5 recovery path already depends on it.
6. **The floor can be set by an issuer.** §5.3: on first enrolment "the floor is taken from the enrolment
   object's generation"; §4.2: an enrolment object may be signed by a designated issuer. So a compromised
   issuing station sets the floor of every node it enrols to any value. This contradicts "only A1 moves the
   generation" and is K6's second half (v2-A B1) again.
7. **The list has no location.** `docs/storage-architecture.md:21-26`: p1/p3 boot (slot-owned), p2/p4 rootfs,
   p5 config, p6 data. There is no "A/B-shared, not cleared by factory reset, not p5" area. In S-A/S-B
   "factory reset" is a reflash (§5.5), which wipes any card location. The document admits a new card loses
   the list, so in every state before S-C a per-key revocation of an administrator does not survive the
   reset, and the only revocation that does is an A1 generation bump, which for a squad is an offline root
   ceremony plus re-issuing every remaining credential (cost not stated, K15).
8. **"Missing list = empty" is an undeclared fail-open.** §7.2 says there is exactly one fail-open (audit
   log). Deleting or corrupting one file un-revokes every individually revoked key (K14 requires each
   exception to be listed with a reason). The "list full" case is also undefined: with A1 offline, what
   happens to the next revocation during an incident?

Negative control missing: none of the above has a test; negative test 4 (§17) cannot be written until the
storage exists.

Smallest fix (prefer removing): drop the chip counter and the +1 rule. State plainly, per platform state,
what K6 can and cannot claim: S-A/S-B — a holder who reflashes loses the node's memory of revocations
(already residual risk §10-1/§10-14 of the threat model); what protects the unit is the rekey (§5.2), not
the node's memory. Keep the floor and the anchor pin together in one record that level-4 reset does **not**
clear (clear only network material), so "reset then re-enrol to the same unit" never loses them and Q-D
becomes "an A1-signed release, or a full reflash". Only the anchor may set or raise the floor, never an
enrolment object signed by an issuer. Leave "survives a reflash" to S-C, where a signed image owns the
storage, and put the hardware requirement into #426 as a question, not as a fact.

### B2 (BLOCKER) — §5.1, §4.2, §9.3, §11, §12 K4: object ordering is contradictory and replay after reset is open

1. **Two ordering rules that disagree.** §5.1: "each signer increments its own sequence number; the node
   keeps the highest seen per (signer, type, network or target)". §4.2: the network configuration also
   carries a "network version". §11 (partition row): "same sequence number, different content = conflict".
   With per-signer numbers two administrators can never produce the same number, so the §11 rule cannot
   fire; and per-signer numbers give no order between signers.
   Counter-example to K4: admins X and Y. X removes lost node L in X#6 and rekeys. Y's older Y#3 (still
   listing L) was never delivered to node N (N was off). Anyone who captured Y#3 and its secret packet for
   N replays them: Y#3 > N's stored Y#2, signature and generation are valid, N goes back to the
   configuration with L in it and the old password. "A replayed object restores revoked power" — K4.
   This is trap §5-5 ("quietly overwrite the removal of a lost node").
2. **Sequence memory is not in the keep list.** §9.3 keeps chip contents, floor, list, enrolment count,
   audit log. The per-signer high-water marks are not there; after a level-4 reset, a card swap (#404) or a
   reflash they are gone. Scenario: node R's card dies, R gets a new card and is re-enrolled to the same
   unit. Before the admin pushes the current configuration, a removed ex-member (or anyone who recorded the
   BLE/HTTP exchange; provd relays these objects) replays last month's configuration and R's old secret
   packet. Generation is unchanged (individual removals do not bump it), so R joins the old network with a
   password the removed party knows. K4: "must not put a node into a network it is not in".
3. **Counters can be pushed.** Nothing limits the sequence number or network version (the +1 rule exists
   only for the generation). One valid administrator signs version 2^64-1; no one can ever supersede it
   (trap §5-5, "version pushed to the maximum").
4. **Restore from backup rewinds the signer's counter.** An issuing station or a squad anchor restored from
   backup (§3.2, Q3) does not know its last sequence number; new objects are silently refused as old, or
   collide with different content. No lifecycle row covers "signer restored".

Shipped behaviour for comparison: updates are accepted only from the previous admin set and only as the next
consecutive version (key-authority fact 4, `node/node.go:1106-1117, 1192-1201`; I did not re-open those
lines). The document replaces this without saying what the new rule is.

Smallest fix: one order per resource, owned by the resource, not by the signer: a network version chained
to the hash of the previous configuration (consecutive only, as shipped), so a fork is detectable and a
gap is refused; say what a reset node accepts first (for example: only a configuration delivered in a
session with a presence proof by a currently authorized key), and add the negative controls: replay of an
older configuration by another signer; replay to a freshly reset node; version jump.

### M1 (MAJOR) — §4.2 "maintenance", §12 K3: the issuing station can issue root-equivalent power alone

"維修角色只能由 A1 直接授予，或由發證者授予但要 A1 的指定物件明確允許". Once A1 has allowed it (and for a
squad it will, because A1 is offline and §8.3 needs maintenance roles issued in advance), a compromised or
merely unlocked issuing station (§5-9) issues the maintenance role to any key by itself. That is K3's
forbidden case. Fix: delete the second branch; maintenance grants are signed by A1 only (they are few and
issued ahead of time anyway). Negative control: issuer-signed maintenance grant with a valid designation
is refused.

### M2 (MAJOR) — §4.2, §3.2 A4, §6 step 4/8: two sources of truth for "who is an administrator"; K2 contradiction

- A role grant (signed by A1 or an issuer) says key K has the network-admin role. The network configuration
  also contains an "admin set" changed by majority or by A1. Which one does step 8 use? If the grant: the
  set is decoration and the K18 majority rule protects nothing (the issuer adds admins at will). If the
  set: a set of 2 needs both signatures, so one lost phone means an A1 ceremony, and D2 ("no longer
  self-authorized by the admins listed in the configuration") is reversed. Two writers on one resource.
- §3.2 A4: member keys are issued by "A3 or A2". §4.2: role grants are signed by "A1 or an issuer". An
  administrator issuing a member credential is an authorized party authorizing another (K2), and the
  baseline's Q2 recommendation is "the field cannot appoint".

Fix: pick one. Smallest: administrators exist only as role grants; the network configuration lists member
nodes, not people; K18 is then met because an administrator cannot sign a role grant at all. State who
issues member credentials (issuer only) and answer §5-10 with a pre-issued, node-targeted member grant.

### M3 (MAJOR) — §6 step 5, §4.3, §17 negative test 1: nodes are asked to verify things they have no key for

§4.3 says other nodes verify the WireGuard binding and the on-the-spot proof (N2 signature). N2's public key
exists only inside the node certificate signed by T1. The baseline says nodes do not verify the root and
the image carries no root public key (`255-608b-config.md:46`). The member list is described as node ids
only (id = hash of the N1 key, which says nothing about N2). So a node cannot check a peer's binding.
Negative test 1 ("production **nodes** refuse a dev-root certificate") and §2 ("bench certificates cannot
enter a production network") have the same gap: today only the app's trust gate does this
(`255-608b-impl.md` §3.2). Fix: say the admin's app is the only verifier of T1, and the signed member list
carries each member's N2 (and N3) public key copied from the verified certificate; drop "production nodes
refuse" from test 1, or add T1 to the image and say so (that changes a reviewed baseline line).

### M4 (MAJOR) — §5.2, §13: §5-2 and §5-4 are not designed; the hand-off is circular

- §5-4 (new password to every node, including ones that are off): the document says "decided in #13". #13's
  input section asks #423 for exactly this. The one concrete sentence ("an already-updated neighbour
  delivers the new configuration") cannot work as written: the updated neighbour is on the new SAE and
  phone-Wi-Fi passwords, the stale node on the old ones, so they share no link — unless both passwords are
  accepted for a time, which is the untested trap named in §5-4.
- §5-2 (second administrator gets the current password and member list): §5.2 says the new password is
  encrypted "to nodes (N3) and to people", but no object, no field for a person's encryption key and no
  delivery path exist in §4.2. #52's input asks for it.

Fix: either design both here (minimum: who may hold the plaintext, the recipient key field in the role
grant, delivery only by an authorized phone over BLE, and the measured cost), or state in §13 that #13 and
#52 cannot start their design from this document for these two points and why.

### M5 (MAJOR) — §11, key-authority §5-12: the change-over from the shipped model is missing from the lifecycle

The shipped node is managed by owner and admin keys in `prov.cbor` (`provstore.go:5-9`). Nothing says how
an already-claimed node becomes "enrolled under an anchor", which parts of §4.2 land in v2.0 with #13
(key-authority §6 puts the §5-1 and §5-4 implementation in v2.0) and which in v2.5, or how "old and new
model never manage the same node at once" (§5-12) is enforced. Concrete risk for K13: `provstore.Decode` is
strict (`provstore.go:112-131`: exact key set, `v != 1` → `ErrTooNew` → `unknown(too-new)`). If the new
image writes a new record and the node later goes back to the older slot (downgrade allowed by release key
6, or LKG #401 after commit), the old helper refuses the record and the node is unmanageable. The trial
window itself is safe only because state-changing verbs are refused during trial (`node.go:258-259`) — the
document must make "no record migration before commit" a rule. Add the rows: upgrade old→new model,
rollback after migration, downgrade to a version without the model.

### M6 (MAJOR) — §13 (#54 row), §15 Q-E: the bound on field credentials (§5-13, R30, R31) is not answered

R31 (`255-threat-model.md:1131`) requires that the document "states how the limit is enforced on a
clockless node". §13 points to Q-E, but Q-E is about enrolling new nodes without the station. "Expiry is
expressed by generation" (§4.2) is the only hint, and a generation bump needs the offline root. #54 cannot
be designed from this. Fix: state the bound as scope only (what a field credential can never do: change
the anchor, designate, grant maintenance, enrol) and say honestly that there is no duration bound before
authenticated time exists; put that to the user as a risk acceptance.

### M7 (MAJOR) — §1 S-C row, §9.3, §10: S-C claims are stated as fact but rest on V3/V4 and on a floor that does not exist at boot

- §9.3: "tampering with the LKG state at most falls back to another signed slot; the version floor stops a
  fall-back to a version with known holes". The shipped anti-downgrade is checked by the helper when an
  update is installed (`254-p3-impl.md` §3.7 keys 6/7), not at boot, and the same section states its own
  limit (line 316: after a downgrade "the revoked K is accepted again"). Nothing at boot compares
  versions. A holder of an S-C node who writes any older signed image to the card boots it; the ROM checks
  the signature only (anti-rollback in EEPROM/OTP is V4, unchecked).
- That older signed image derives N7 like any other (§3.1 N7 is bound to "a signed image", not a version)
  and can produce a valid attestation (§10). So "cannot open own system", "LUKS key cannot be derived" and
  "signed = we booted our image" all reduce to "no image we ever signed has a root hole".
- §10's S-C row depends on V3 (host-authorized chip use, #414 A19/A26 untested).

Fix: mark the S-C rows ⚠️ with the dependency, delete the "version floor stops it" sentence or replace it
with the requirement on #115 (boot-level rollback counter, or key rotation per V4), and add physical
downgrade to an old signed image to the S-C residual risks.

### M8 (MAJOR) — §5.5, §15 Q-C: the "co-anchor" second phone is the recommended default but is not defined

§5.5 relies on "a second phone designated as co-anchor". §3.2 has one A1; §4.2 has no object that names a
second anchor; K1 says only the anchor changes whom the node trusts. With two anchors there are two
writers on the unit generation and on anchor replacement (both sign "generation N+1" with different
content while apart — the S16 problem one level up). Fix: define it in one line as an anchor set
installed by the anchor itself, with a stated rule for conflicting changes, or remove the recommendation
and present Q-C to the user without it.

### M9 (MAJOR) — §8.3, §12 K23: the maintenance entry does not close by itself, and where it listens is not stated

K23: the entry "is opened for that one node and closes by itself". The design closes it on reboot or on an
explicit action. A field node can run for months; a forgotten entry stays open. The document also does not
say on which interfaces sshd listens while open (K23: not reachable from phone Wi-Fi, Ethernet, mesh —
which today are one bridge, key-authority fact 10). D4 forbids trusting the wall clock, not a monotonic
uptime timer or "closes when the authorizing session ends". Also, on S-A/S-B a root shell on a writable
system can leave anything behind; "the key is on tmpfs" does not bound that (say so). Negative controls:
entry gone after the limit without reboot; connection from mesh/Wi-Fi refused while open.

### M10 (MAJOR) — §4.2, §13 (#52 "only take back a role"): no object can take back one role

The revocation object names "a key or a node id". A role grant is a bearer object shown by the caller at
request time (§6 step 8); re-issuing a narrower grant does not stop the holder from showing the old, wider
one to any node, because nodes do not hold other people's grants and the per-signer sequence only works on
a node that has seen the newer one. Fix: let the revocation entry name a grant (signer id + sequence), or
state that taking back a role = revoke the key and issue a new key.

### M11 (MAJOR) — baseline hand-offs to #423 that the document does not pick up

- `255-608b-impl.md` §3.2: the three-step join (`verify_offline`) has no on-the-spot proof, "a deviation
  from K20; #423's design removes this path" (also Q5). The document does not mention it; §12 claims K20.
- Q2 (can the field appoint an administrator) and Q6 are due "at #423" per key-authority §7 and are absent
  from §15.
- §5-9 (issuing station is a live signing tool): only "A1 can bump the generation afterwards". #54 asks for
  limits (issuance cap, audit, two-person). Not present.
- §5-11 (society) is moved to "not in this version" (§14) and to #52, while key-authority §6 assigns all of
  §5 to #423 and #52 lists it as an input.

Fix: one line each — decided, or explicitly returned to the user/issue with the reason.

### Minor

- **m1 §8.2** The "this came over BLE" fact is reported to the root helper by provd (non-root, radio-facing).
  A compromised provd can label a mesh/HTTP request as BLE. Say that presence rests on the signed node
  nonce only and that the transport label is advisory, or have the helper own the nonce and bind the
  session hash. BLE relay is not excluded either; do not call it "near".
- **m2 §0** "This PR changes the 'one PKI, two certificate populations' section of `docs/threat-model.md`":
  the section exists (`docs/threat-model.md:36`) but the branch does not touch that file
  (`git diff --stat main...HEAD -- docs/threat-model.md` is empty).
- **m3 §7.2** "Only one fail-open" is not true as written: missing list = empty (B1), missing slot state =
  today's tryboot behaviour, missing attestation = requester decides. List each with its reason (K14).
- **m4 §5.2/§13** #13 and #95 ask "how late at most does a node learn of a revocation". The honest answer
  (no bound; until an authorized phone reaches it; it is off the mesh from the rekey on) is not written.
- **m5 #95/#54 inputs** The roster (format, owner) and the custody of the root backup shares (where, who)
  are absent; custody is a user decision and belongs in §15. #54 "zeroize" is absent.
- **m6 §4.2** "Presence required" is listed as a field of the signed role attributes and, in the same row,
  "decided by #393's action table, not by the signer". It cannot be both; remove the field.
- **m7 §5.3** After a generation bump, are stored network configurations and enrolment objects signed in the
  old generation still valid? Not stated; "all refused" would drop every node out of management at once.
- **m8 §5.4** A node that was off during an anchor change needs the old-anchor-signed object forever; say who
  keeps the chain. With a leaked (not lost) old anchor the thief can sign the change first; say that
  rotation does not help against a leak (threat model §10-12 covers the leak itself).
- **m9 §7.1** No writer is named for the TAK server key and certificate on a squad node's p5 (ICS issues
  them; who writes the file?). The audit log's location is not named, yet §9.3 keeps it across a reset;
  after re-enrolment by a different unit, who may read the previous unit's log?
- **m10 §4.3** The WireGuard binding has a "count" but no rule for who remembers it; a peer that missed the
  newer binding accepts the old key. State that the binding is only as fresh as the member list version.
- **m11 §9.3/§4.1** "Put it on p1": p1 is slot A's boot partition (`storage-architecture.md:21`), written by
  updates and EEPROM handling. Name the writer or pick another place.
- **m12 §3.3 M2** "Old K is stopped by the version floor": the mechanism is `release-min-serial`
  (`254-p3-impl.md:316`), with the limits written there. Use its words.

Questions (not findings): (q1) Does #402's automatic level-4 reset need to clear the anchor at all? If the
unit pin stayed, power-cycling a node could not un-enrol it and the body QR would matter only at first
enrolment and after a full reflash. (q2) K8: a revoked admin can still rekey a not-yet-updated node off the
mesh; recovery needs BLE range to that node. Is BLE range "physical contact" in K8's sense?

---

## K1–K25 against §12 (hard ones)

| Rule | Claim holds? | Counter-example / note |
|---|---|---|
| K4 | No | B2: replay of another signer's older configuration; replay to a reset node |
| K6 | No | B1: floor pushable by any bus master, issuer-set at enrolment, list has no home, missing list = empty |
| K7 | Partly | Works for a planned rotation; m8 (offline node, leaked anchor); M8 (co-anchor undefined) |
| K8 | Partly | B1.1/B1.2 make a node unrecoverable even with physical contact; q2 |
| K11 | Holds for reading the new password | Depends on M4 (delivery not designed) |
| K13 | Unproven | M5 (strict `prov.cbor`), M7 (no boot-time floor) |
| K18 | Unclear | M2: depends on which source of truth governs |
| K3 | No | M1 |
| K2 | Contradicted | M2 (A4 issued by A3) |
| K14 | Not as written | m3 |
| K20 | Not as written | M11 (`verify_offline`) |
| K23 | Partly | M9 |
| K1, K5, K10, K12, K16, K19, K21, K22 | Hold as design statements | K5: add "version" explicitly once B2 is fixed |

## Inputs of the eight issues

| Issue | Bullet | Result |
|---|---|---|
| #13 | what admission checks, which root | Covered (§4, §6 steps 2–4); node-side root check missing (M3) |
| #13 | which layer, split with #16 | Covered (§6 step 5 and the v2.0 limits) |
| #13 | revocation without network; how late; survives factory reset | **Not covered** (B1, m4) |
| #13 | rekey delivery incl. powered-off nodes; who may start | **Not covered** (M4); "who" covered (§4.2) |
| #13 | replace `CHANGE-ME-NOW`, fail-closed | Covered (§6, test 7) |
| #13 | chip-independent identity | Covered (§4.1, V8 open) |
| #16 | where the WireGuard key lives, who reads it | Covered (§3.1 N6; real protection only from S-C, stated) |
| #16 | binding to identity; key change flow | Partly (§4.3; verifier key missing M3; count rule m10) |
| #16 | peer list source; removal on revocation | Covered (§7.1), subject to B2 |
| #16 | rotation period; node back from offline | **Not covered** ("any time" only) |
| #16 | traffic outside WireGuard (PTT) | Covered as residual (§6) |
| #52 | where roles and attributes live; fixed vs changeable | Covered (§4.2) |
| #52 | admin set; K18; second admin gets password; convergence | **Not covered** (M2, M4, B2) |
| #52 | society | **Not covered** (§14 defers; M11) |
| #52 | one node, several networks | Covered (§4.2) |
| #52 | decision point | Covered (§8.1); TAK excluded and said so |
| #52 | take back only a role | **Not covered** (M10) |
| #54 | issuing station: key location, limits while unlocked | Partly (D6 only; M11) |
| #54 | field credential bound; station offline for days; enrol new node | **Not covered** (M6); Q-E for enrolment |
| #54 | TAK and Batman same CA or not | Covered (§2 T3, §4.4) |
| #54 | enrolling a node: evidence, signer | Covered (§6 steps 2–3) |
| #54 | member finds own node, gets phone Wi-Fi | Partly (A4 row; issuer contradiction M2) |
| #54 | zeroize and client revocation | Partly (TAK account disable, V6 unchecked; zeroize absent m5) |
| #95 | loss = revoke + re-issue; node id continuity | Covered (§3.1, §9.3) |
| #95 | root backup: shares, where, who | Partly (2-of-3 only; m5) |
| #95 | admin/owner phone lost, not via permanent QR secret | Partly (§5.5 falls back to the QR; put to the user as Q-C; M8) |
| #95 | roster; how late revocation takes effect | **Not covered** (m4, m5) |
| #95 | repair and scrapping | Covered (§11) |
| #95 | factory reset vs recoverable loss as two paths | Partly (§9.3 vs §5; B1.5 ties them together) |
| #97 | attestation evidence per platform | Covered (§10); S-C row overstated (M7) |
| #97 | workload identity: which branch signs | Covered, thin (§10, M5 key) |
| #97 | image key (#405) vs publisher key | Covered (§3.3: separate) |
| #97 | key release bound to attestation (#47) | Covered as N7 derivation (V3 open) |
| #97 | cross-agency trust | Deferred (U5) — acceptable, §14 |
| #393 | authorization per action; presence field | Partly (§8.2; m6) |
| #393 | presence method; against a finder of the node | Covered for a found node; found unlocked phone deferred to the user (stated); m1 |
| #393 | update authorization, separate from image key | Covered (§9.1) |
| #393 | maintenance shell: bound to what, how long, how it ends | Partly (M1, M9) |
| #393 | refused actions logged: where, who reads | Partly (owner yes, location no; m9) |
| #196 | slot ↔ key mapping | Covered (§3.1; matches `255-608b-config.md` §3) |
| #196 | TAK mTLS key in chip or not | Covered (§4.4: not) |
| #196 | dev root vs production root | Covered for the app; node side M3 |
| #196 | burning and signing: who, where | Covered for bench (§6 step 1); production = Q-B |

Downstream blocks: #401/#402/#404 get the keep/clear table and "readable before unlock" (but B1.5, B1.7 and
B2.2 change that table); #111/#414 get N7 (V3); #426 gets a requirement list that currently includes the
counter (B1) — fix before #426 uses it; #405/#115 get the key split, V4 open (M7); #174 covered; #74 covered.

## Citations checked

| Citation in the document | Result |
|---|---|
| `release/release.go:1-4` (R endorses K, K signs; test root T) | Holds |
| `node/wtxn.go:121-135` (secrets signed and addressed to the node, net id/version as KDF context) | Holds (the lines are `decryptSecrets`; the signature check is in `openSecrets`) |
| `node/node.go:1242-1311` (transaction and rollback) | Holds (`applyNet`) |
| `provstore/provstore.go:9` (one network per node) | Holds weakly (line 9 is the single `net` schema entry) |
| `keystore/keystore.go:78-98` (fixed purposes only) | Holds |
| `docs/storage-architecture.md:21-26` (p1–p6) | Holds; also shows no shared non-p5 area exists (B1.7) |
| `KeyPolicy.kt:64-66` (hardware keys) | Holds for "hardware level required"; non-exportable is a Keystore property, not on these lines |
| `Keys.kt:64-98` (no user authentication set) | Holds |
| `255-608b-config.md` §3 (slot 1 internal signing only; slots 0/2/5/8) | Holds |
| `255-608b-config.md` §4 (counter bytes 52–67 exist, untouched) | Holds; but `608b-facts.md` §7 already documents the counter's limits, contrary to V1 |
| `255-608b-impl.md` §2.1 (`Identity`), §2.2 (flock on `/dev/i2c-N`), §3.1 (≤ 416 bytes), §3.2 (on-the-spot proof) | Hold |
| `255-608b-impl.md` §3.2 `trust_gate` "dev-root certificate refused by production builds" | Holds for the **app** only (field refuses both styles); not for nodes (M3) |
| `254-p3-impl.md` §3.7 (downgrade protection, K rotation) | Exists; it is an install-time rule plus `release-min-serial`, with limits the document does not carry over (M7, m12) |
| `255-threat-model.md` §10-12, §10-14 | Hold |
| `docs/threat-model.md` L2 row (batman-adv does not authenticate OGMs) | Holds (line 32) |
| `docs/threat-model.md` "one PKI" section changed by this PR | **Does not hold** (m2) |
| iOS 398 days (#170), TAK no CRL (#58) | Not checked by me; the second is marked ⚠️ by the author |
