# Review v2-A: #423 security architecture (`security-architecture.md` v2, commit 7069f67)

Reviewer A, independent, read-only. Whole document reviewed again, plus `423-reviews/v1-changes.md` and the
new section of `docs/threat-model.md`. No node or device was touched; nothing was run except `git`, `grep`,
`sed`, `gh issue view`. Everything below marked "read" was opened in the worktree; nothing was executed on
a node or in a test harness, so statements about what the shipped helper *does* are from reading the source
and are marked where a test is still needed.

## Summary and verdict

v2 is a much better document. The mechanisms that failed in round 1 are gone, the trust model is kept as
open problems with the traps written down (and the traps are stated correctly), the platform table no
longer over-claims S-C, and the idea of naming the shipped protections as invariants (§5) is the right
foundation. The scope cut is a user decision and I do not contest it.

What is left are errors in the three things v2 newly **decides**: the change-over contract (§6) contradicts
what the shipped helper does with an unreadable record and with the per-slot overlay copy; the reset table
(§8) changes #402's written design and drops a shipped fail-closed behaviour without saying so; and the
"shipped / met" lists (§5, §7, §15) say more than the source supports in a few places, one of which would
strand legacy nodes if #13 were built as written. None of these needs a new mechanism; all are fixed by
narrowing or correcting text and adding one rule.

**Verdict: APPROVE-WITH-CHANGES** (by the project rule, open MAJORs mean one more whole-document pass).

**Counts: 0 BLOCKER / 7 MAJOR / 11 MINOR**

---

## Findings

### M1 (MAJOR) — §6 rules 5 and 6, §8 contract row "record version": not what the shipped image in the other slot does

The contract says: after conversion, an older image "refuses all management actions", and "does not use the
pre-conversion list". Read against the source:

1. `boot/boot.go:270-271`: a too-new record gives `unknown(too-new)`, action none (no write — good, the
   wireless part of rule 5 holds).
2. `node/node.go:251-252, 257-263`: an `unknown` verdict blocks only the verbs in `stateChanging`.
   `update.prepare`, `update.apply`, `diag.bundle`, `bulk.open/close` are owner-op verbs that are **not** in
   that map.
3. `node/node.go:796-797` with `node/wtxn.go:262-273`: when the p5 record does not decode, `resolve()`
   fails and the owner-op verb continues "on the overlay". The overlay is per slot (`254-stage1-impl.md`
   L5: an OTA starts the new slot with a fresh overlay and copies the record in), so the old slot still
   holds the **pre-conversion v1 record with its old owner list**.

Scenario: owner O2 is removed, the node is converted, later the node falls back to the old slot (LKG #401
does this without a person, possibly weeks later; or a key-6 downgrade). On the old image O2's owner-op
for `update.apply` or `diag.bundle` is checked against the old overlay list and passes. Rule 6 ("revoked
power does not come back", K13) is broken for exactly those verbs. The same path is also why "upgrade again
to manage" works at all — if the old image really refused everything, the app could not send the update
and the only way out would be a reflash. The document cannot have both sentences.
(Source read only; add a sandbox unit test: v=2 record on p5, v1 overlay, each owner-op verb.)

Also not covered:
- **Schema change without a version change.** `provstore.Decode` wants the exact key set
  (`provstore.go:112-131`); key 12 was once added under `v=1` (`provstore.go:60, 122`). If #255 or #13 adds
  a key under `v=1`, the old slot reports "corrupt", not "too new", and takes the rc-10 path
  (`boot.go` "p5 record corrupt ... re-persisted the overlay one" when generations allow). §6 says "#255
  and #13 will both change the record" but gives no rule for it.
- **Two version fields.** `prov.meta` has its own `v=` (`provstore.go:316-317`); rule 1 names one field.

Smallest fix: (a) rule 5 says what is true: state-changing verbs are refused; say which verbs remain and on
which record; (b) add: conversion is allowed only when the **other slot also holds an image that reads the
new record** (the helper already reads the other slot's build info for updates) — then automatic fall-back
never meets rule 5 and rule 6 needs no argument; (c) add: any change to the record's key set bumps `v` in
both `prov.cbor` and `prov.meta`; (d) the conversion (or the first boot that sees a newer p5 record)
must make the old overlay copy unusable for authorization — or state as a requirement that owner-op verbs
never fall back to the overlay when p5 says "too new". Negative control: removed owner, converted, fall
back, `update.apply` signed by the removed owner → refused.

### M2 (MAJOR) — §8 reset table: changes #402 as written, drops a shipped fail-closed behaviour, and leaves resources out

1. **Conflict with the issue text, not listed in §13.** #402 design point 4: "reset to golden defaults,
   keep the identity in the secure element, **return to the claimable state**". The table's first row
   keeps the owner record instead. I think the table is the safer choice (a boot loop nobody authorized
   must not make a node claimable by any QR holder) and that a security architecture may decide it — but
   it is a change to #402's design and to `docs/field-resilience.md:54`, so it must be in §13 and the user
   should see it (it changes what a field person does after a level-4 reset: the owner's phone is needed,
   the QR alone no longer works).
2. **"p5 damaged" is put in the same row as "card swapped" → unclaimed.** Today a claimed node whose p5
   cannot be read stays locked and refuses state changes: `254-stage1-impl.md:95, 244` (p6
   `last_known_state` ∈ {claimed, member} → locked), `boot.go` rc 10/13/1/8 ("fail-closed: no write",
   "a rolled-back older slot must not replace a claimed record"), `node.go:261`. Row 3 turns that into
   "unclaimed, re-enrol with the QR" (as #402's acceptance test also wants). That is exactly what row 1
   says must not happen without authorization, and it removes shipped behaviour that is not in the §5
   list. A card swap is a physical act and cannot be prevented; in-place p5 damage is not the same event.
   Decide it explicitly: either p5 damage on a node that p6 says was claimed stays fail-closed (owner must
   reflash or swap the card), or the weakening is accepted by the user and written as such.
3. **Resources missing from the table and from the §8 ownership table**: the overlay copy of the record
   (per slot), p6 `prov-state` (`last_known_state`, written by the helper and by `99zz`), the root
   password / shadow and the prov lock, the `96-batman-config-migrate` copy step, `batman-config-save`
   (the program that actually writes p5). "helper, transactional" is not the only writer today. For each
   reset row: what happens to each of these, and who performs the reset (it must be the helper, or there
   are two writers on `prov.cbor`).
4. **New unauthenticated transition.** "Automatic reset: member → claimed, network removed" is a state
   change with no signature. §16 says the document adds only the "convert" verb; it also adds this and the
   owner-ordered factory reset (no such verb exists in `node.go:773-777`). State the constraint #402 must
   keep: the trigger must not be something a radio peer or a non-root process can cause (otherwise anyone
   can make a node drop its network until the owner walks to it), and name the ticket that owns each verb.

Negative test 9 is right; add: p5 damaged on a claimed node → (whatever is decided); automatic reset cannot
be triggered from the mesh or phone Wi-Fi.

### M3 (MAJOR) — §5: shipped protections that §6 and §8 rely on are missing from the invariant list

The list exists so that later work cannot silently remove something. Missing, all read in source:

| Missing | Source | Why it matters here |
|---|---|---|
| A node that has an owner cannot be claimed again with the QR alone | `node.go:566-568` (state must be Legacy / Unclaimed) | The whole §8 argument and "a leaked QR does not affect enrolled nodes" (§3.1 N4) rest on it; it is only a cell in §7 step 3 |
| An unknown boot verdict freezes state changes; a too-new or damaged record is never overwritten; an older slot never replaces a newer p5 record | `node.go:261`; `boot.go:236-262, 270-271` | §6 rules 4–6, K13 |
| The signer of an owner action must be an owner in the record p5 confirms, not only in the overlay | `node.go:788-800` | Removed co-owner; §6 rule 6 |
| An owner signature is bound to verb, arguments, session and a node nonce | `node.go:703-720` (`verifyOwnerOp`) | K5 for today's model; I-1 names only the nonce |
| The release trust keys are read from the image's squashfs only | `release/release.go:110-111` | K22 / T4: a file placed at run time must not add a root |
| A claimed node is locked even when p5 is unreadable | `254-stage1-impl.md:95, 244` | M2.2 |
| `claim.replay` needs both the owner's signature and the claim proof | `node.go:654-661` | Recovery path; a later change could relax either half |

Fix: add them as I-9 … (or fold into I-1 / I-7) with their regression tests named.

### M4 (MAJOR) — §7 and I-5 call things "shipped" that are not; the #13 rule as written strands legacy nodes

1. §7: "secrets are sent only to nodes that passed the on-the-spot proof … already shipped; #13 adds
   regression tests". The on-the-spot proof (`id/prove`) is #255 PR 3 and does not exist yet
   (`255-608b-impl.md` §2.6, §3.2). So this part of #13 is new work that depends on #255, not a regression
   test.
2. I-5 / §7: removal with rekey exists only in the dev-trust build of the app
   (`254-net-update-members.md:18, 34, 168`; key-authority fact 12), and the node is told nothing
   (fact 9). "Shipped" should read "exists in the development app; the node-side part is the version
   chain (I-2)".
3. "#13: no valid network configuration → no mesh". The record has a `Legacy` state for nodes whose radio
   was set by the operator and is deliberately left alone (`node.go:590` "legacy claim keeps the
   operator's radio"; `boot.go:225-229`). §9 says an upgrade from v1.6 "leaves file-identity nodes as they
   are". Both cannot hold: built as §7 says, the first v2.0 image takes every legacy node off the mesh (a
   remote node is then reachable only by hand). Say which wins: e.g. the rule applies to
   `RadioManaged` nodes and to the image default key only, and legacy nodes keep working until claimed —
   or legacy support ends in v2.0 and that is a user decision with the bench impact stated.

### M5 (MAJOR) — §13, §14: #13 is a v2.0 ticket that now waits for problems designed after v2.0's bench work; the consequence is not put to the user

§14: #13 "still waits for O-1 (revocation), O-4 (delivery)". `255-key-authority.md` §6 puts "#13 (including
the implementation of §5-1 and §5-4)" in v2.0, and §10 says these are designed only after the 608B works
on the bench. So either #13 closes in v2.0 without those parts (the project rule says an issue is not split
into phases), or #13 stays open past v2.0, or v2.0 slips. That is a milestone decision for the user and it
is not in §12; §13 lists the v2.5 tickets' start conditions but not #13's scope, nor the lines of
`255-key-authority.md` §6 that still say "#423 = the design of all of §5, then a red-team test" and
"v2.5 = implementation of §5". Fix: one row in §12 (what #13 delivers in v2.0, with §7's "cannot do" list
as the stated limit) and two rows in §13.

### M6 (MAJOR) — §15 and §16: four "met in v2.0" claims have counter-examples in the baseline itself

| Claim | Counter-example |
|---|---|
| K20 met | `255-608b-impl.md` §3.2: the three-step join (`verify_offline`) has no on-the-spot proof and is recorded as "a deviation from K20; #423's design removes this path". v2 neither removes it nor lists it (my round-1 M11). → "partly: `verify_offline` remains until Q5 is decided" |
| K12 met ("single decision point") | In v2.0 the owner gets the root password at claim (`node.go:609`), SSH and the web admin are open in the dev build, and a removed owner keeps the password and keys (fact 9, already under K17). Management by root login never passes the helper. Also `netUpdate` is a second path with no owner signature (`node.go:778-780`), so §4.2 point 3 ("only this one place changes") is two places. → "met for the provisioning protocol only" |
| K14 met; "only one fail-open" (§8, §16) | Shipped exceptions not listed: p5 unreadable (rc 1/8) keeps the overlay verdict (`boot.go:263-266`); an owner action continues on the overlay when p5 cannot be resolved (`node.go:796-797`); the legacy claim gate. Each may be right, but K14 requires them listed with a reason |
| §16 "secrets do not pass provd in plaintext (I-3, P4)"; §3.2 A2 "provd cannot see the plaintext" | Key-authority fact 5: provd terminates the channel and sees reply plaintext, including the root password; `node.go:609, 672` return it unencrypted from the helper. §15 itself limits K10 to "admin → node"; §16 and A2 must say the same |

### M7 (MAJOR) — layout: v2.0 fixes the partitions (#111, #41) but the document reserves no place for state that must be readable before unlock and must not belong to a slot

§8 says the slot / LKG state must be readable before LUKS unlock (so not p5, not p6) and §10 O-1 / O-17
record that "there is no region a reset does not clear". `docs/storage-architecture.md:21-26`: p1/p3 are
slot-owned boot partitions, p2/p4 rootfs, p5/p6 the encrypted ones, plus 300 MB left unallocated. #111 and
#41 implement this layout in v2.0; changing a partition table later means re-provisioning every card (the
project already has one such one-way door, #201). This is the kind of rework the user asked to avoid, and
it is cheap to avoid now: decide that a small unencrypted, slot-independent area exists (inside the
reserved 300 MB or a file on the first FAT partition with a named single writer), what may go there (no
secrets; integrity only from S-C), and that #401's state and any later "only forward" record use it — or
write plainly that a layout change by reflash is accepted for every node built before S-D. Either is fine;
leaving it unsaid is not.

### Minor

- **m1 §5 I-1 citation**: `node.go:654-659` is inside `claim.replay`, not the join path; the join path is
  `ownerOpVerb` `:781-787` → `netJoin` `:1106-1117`. `:703-705` is the comment above `verifyOwnerOp`.
- **m2 §5 I-8 citation**: "no software identity" is `255-608b-impl.md` §2.3 (`identSum`, `Generate`,
  `backend-mismatch`); §2.4 is chip failure.
- **m3 §10 O-7, missing trap**: the phone keys are created without user authentication and without key
  attestation (`Keys.kt:64-98`). Android cannot add either to an existing key, so turning them on later
  means new keys and re-enrolling every node (S12 today = reflash). Record it; it is a "decide before the
  first real enrolment" item.
- **m4 §10 O-3, missing trap**: on the bench the claim secret is generated and **kept** on the developer
  computer (`255-608b-config.md` v4 note; impl §2.5). If production provisioning (#256) does the same, the
  factory can enrol any node that becomes unclaimed (§8 rows 2, 3) — a K22 question for #256.
- **m5 format evolution**: the release object refuses unknown keys (`release.go:161, 262-263`), like
  `prov.cbor`. Anything the trust model later needs in a release object (for example "needs record
  version ≥ n", which M1(b) could use) cannot be added without old helpers refusing the update. State
  the rule for strict parsers once: new meaning = new content type / new version, never a new key.
- **m6 `docs/threat-model.md`**: the new section is correct, but the same file still says, in the table
  above it, "L3 / admission ✅ Yes — PKI admission + attribution, #13 per-node certs" and, below it, "client
  certificates issued by the mesh/FTS CA". Both contradict §2 / §7 (v2.0 admission is a shared password;
  nodes verify no certificates; TAK CA is separate; FTS is replaced by OTS).
- **m7 §13**: missing rows — #402 issue text and `field-resilience.md:54` (M2.1); `255-key-authority.md`
  §6 (M5); `255-608b-impl.md` §3.2 / Q5 (M6, K20).
- **m8 §9 "owner-ordered factory reset"**: on S-A/S-B deleting files does not remove secrets from the card
  (threat-model F11; the document says it only under O-15). Say it in the §8 row too, since the §9 repair
  row tells people to rely on it before handing a node over.
- **m9 §9 "mixed dev / production"**: "the production app refuses dev-root nodes, so they are never added to
  a production network" holds only for networks managed by the production app; a dev app can add a
  production-root node to a bench network. Harmless, but say "refused by the production app" only.
- **m10 §3.1 N4**: "QR leaked: an unenrolled node can be enrolled first" — with §8 rows 2 and 3 "unenrolled"
  includes after every card swap and factory reset; say so in the cell.
- **m11 §14 #401/#402/#404 row**: "waits for O-18" only. They also wait for M2 (reset table) and M7 (where
  the state lives).

### Questions

- q1: Does the old image's `96-batman-config-migrate` copy a p5 record it cannot parse into a fresh overlay
  (raw copy, `255-608b-impl.md` §2.8 says it copies by file list)? If yes, M1 needs one more row.
- q2: I-6 — is there any update path on a production image that does not pass `update.apply` (sysupgrade
  from a root shell is one in dev builds)? If a production image will have none, say that I-6 covers
  "every update path in the production build".

---

## §5 invariants checked against source

| # | In source as stated? | After config reset | After card swap |
|---|---|---|---|
| I-1 | Yes: `ownerOpVerb` verifies the owner's signature (verb, args, session, helper nonce) before `netJoin` (`node.go:781-787, 1106-1117`) | Holds if the owner record is kept (§8 row 1): join needs that owner | "Owner" is whoever claims with the QR; holds only as far as N4 is secret (stated in §8) |
| I-2 | Yes (`node.go:1190-1202`): next version, previous hash, previous admins | Network cleared → falls under I-1 | same |
| I-3 | Yes (`wtxn.go:121-140`): target = hash of the node key, net id + version in the KDF | n/a | n/a |
| I-4 | Yes (`node.go:1242-1311`, `:258-259`) | n/a | n/a |
| I-5 | Dev-trust app only; node receives nothing (M4.2) | n/a | n/a |
| I-6 | Yes (`node.go:776-777` in the owner-op table; `release.go`); see M1 for which record the owner is checked against after a fall-back | Owner kept → holds | No owner → no update through the app until claimed |
| I-7 | Yes (`node.go:566-576, 589`; counter in `prov.cbor` key 5) | Count kept | Count lost (stated) |
| I-8 | Design only (#255 PR 2), cited section should be §2.3 | — | — |

## My round-1 BLOCKER / MAJOR findings

| Round 1 | v2 | Safe for v2.0? |
|---|---|---|
| B1 revocation floor in the chip counter | Mechanism removed; O-1 with correct traps; O-17 to #426 | Yes, with M7 (reserve the place now) and M5 (#13 scope) |
| B2 per-signer ordering, replay after reset | Mechanism removed; shipped I-1 / I-2 kept and named | Yes — closed. I could not build a replay against I-1 / I-2 |
| M1 issuer issues maintenance role | Removed; O-14 | Yes |
| M2 two sources for "admin"; K2 | Removed; O-12 | Yes |
| M3 nodes verify without a key | Closed in §2; O-16 | Yes |
| M4 §5-2 / §5-4 not designed | Moved to O-2, O-4 (user scope decision) | Only with M5: #13 is v2.0 and depends on O-4 |
| M5 change-over missing | New §6 | Not closed — M1 |
| M6 field-credential bound | O-13 | Yes |
| M7 S-C over-claimed | Closed: P2, O-18, V3, V4, Q-F | Yes |
| M8 co-anchor | Removed; O-3 | Yes |
| M9 maintenance entry | O-14 | Yes |
| M10 take back one role | O-12 / #52 | Yes |
| M11 hand-offs (verify_offline / Q5, Q2, Q6, §5-9, §5-11) | Q2–Q6 left with key-authority §7; §5-9, §5-11 → O-9, O-11 | Mostly; K20 is still claimed "met" while `verify_offline` stands — M6 |

## Citations checked (v2)

| Citation | Result |
|---|---|
| `provstore.go:6` (owner key, `owner_enc_pub`), `:6-8` | Holds |
| `release/release.go:1-4`, `:2` | Holds |
| `release.go:110-114` (`release-min-serial`, checked at install) | Holds (`LoadTrust`, read from the squashfs) |
| `255-608b-impl.md` §3.2 `trust_gate` (app-side) | Holds |
| `255-608b-config.md` §2 (nodes do not verify the root; no root key in the image) | Holds (line 46) |
| `node/wtxn.go:121-135`, `:121-140` | Holds |
| `KeyPolicy.kt:64-66`, `Keys.kt:64-98` | Hold (as in round 1) |
| `node.go:770-787` verb table; `:776-777` update verbs | Hold |
| `node.go:654-659, 703-705, 784-790` for I-1 | First range is `claim.replay` (m1); the others hold |
| `node.go:1106-1117` `netJoin` | Holds |
| `node.go:1190-1202` | Holds |
| `node.go:1242-1311, 258-259` | Hold |
| `keystore.go:78-98` | Holds |
| `provstore.go:112-131` strict parsing | Holds; also shows the key-count special case (M1) |
| `prov.cbor` key 1 `v=1`, key 5 `claimed_counter` | Hold (`provstore.go:5`) |
| `608b-facts.md` §7 | Holds |
| `254-net-update-members.md` as "shipped rekey flow" | Exists; dev-trust build only (M4) |
| `255-608b-impl.md` §2.4 for I-8 | Wrong section (m2) |
| `255-608b-impl.md` §7, §3.3, §2.2, §2.1, §3.1 | §2.1, §2.2, §3.1, §3.3 hold; §7 not opened |
| `docs/threat-model.md` section replaced in this commit | Holds; stale neighbours (m6) |
| #58 TAK no CRL, hat-v2-spec A19 / A26 | Not checked by me; both are marked unverified by the author (V6, V3) |
