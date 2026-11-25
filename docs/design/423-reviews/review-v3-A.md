# Review v3-A: #423 security architecture (`security-architecture.md` v3, commit e4c9930)

Reviewer A, independent, read-only. Whole document read again, with `423-reviews/v2-changes.md` and
`docs/threat-model.md`. No node or device was touched; nothing was executed except `git`, `grep`, `sed`,
`gh issue view`. Statements about what shipped code does come from reading the source in the worktree, not
from running it.

The two user decisions of 2026-11-25 (automatic reset keeps the owner; revocation and rekey delivery leave
#13 for v2.5) are taken as baseline. The document implements both consistently (§7, §8 row 1, §10 O-1/O-4,
§12, §13, §14); I found no place that still contradicts them except the two stale cells listed under Minor.

## Summary and verdict

v3 is sound as a foundation. The invariant list (§5) now matches the source, with limits written next to
each item; §15 no longer claims more than the code supports; the reset table keeps the shipped fail-closed
behaviour for a damaged record; the layout question is answered by an explicit acceptance. One thing in §6
is still wrong in a way v2.0 work could act on, and it needs two sentences to fix.

**Verdict: APPROVE-WITH-CHANGES**

**Counts: 0 BLOCKER / 1 MAJOR / 10 MINOR**

If the author applies the M1 fix as written below (it removes a hole, adds no mechanism), I do not need to
see the whole document again for my part; a diff of §6 is enough.

---

## MAJOR

### M1 — §6 F1 and condition 4: the rule that protects the fall-back is not applied to v2.0's own version bump, and it does not cover an image installed afterwards

Two holes in the same place.

**(a) F1 tells v2.0 tickets to do, ungated, what conditions 2–4 forbid later.** F1: "if #255 or #13 adds a
key, bump `v`". The first record a v2.0 image writes with `v=2` is, for the image in the other slot, exactly
the "record it cannot read" of condition 4:

- other slot = v1.6 (always the case on the first v2.0 update): `provstore.Decode` → `ErrTooNew`
  (`provstore.go:124-129`), boot verdict `unknown(too-new)` (`boot/boot.go:270-271`);
- state-changing verbs are frozen (`node.go:257-263`) — the owner cannot leave, join, change owners or
  reset the root password until the node is updated again;
- `update.*`, `diag.bundle`, `bulk.*` are checked against that slot's old overlay list
  (`node.go:796-797`, `wtxn.go:262-273`) — the document's own argument in condition 4.

Scenario: node updates v1.6 → first v2.0 image, commits, the owner removes a co-owner or changes anything
(record now `v=2`), then #401's observation period or a later bad boot falls back to the v1.6 slot with
nobody present. Result: K13 ("still manageable after a fall-back") does not hold in v2.0, and the "v2.0
does no conversion, so nothing changes" cells in §9 and §15 are true only if no v2.0 ticket changes the
key set. The document does not say whether #255 (including the new factory-reset verb of §8 row 2) or #13
will; `219-field-provisioning.md:3` records the earlier intent "p5 schema stays 1".

**(b) Condition 4 checks the other slot only at conversion time.** Its last sentence — "with this
condition an automatic fall-back never meets a record it cannot read" — is false after the next install:
an update or an allowed downgrade (release key 6) can later put an older image into the other slot.
Nothing in the conditions makes the helper refuse to install an image that cannot read the record it
currently holds.

Smallest fix (text only):
1. Add to F1: "v2.0 tickets do not change the key set of `prov.cbor`. If one must, the first write of the
   new version is subject to conditions 2–4 (not before commit; only when the other slot's image reads it)."
2. Add to condition 4: "…and from then on the helper refuses to install an image that cannot read the
   current record version (an older release object that does not state it counts as 'reads v1 only')."
3. Negative controls: v2 record + v1-only image in the other slot → conversion / first v2 write refused;
   v2 record held → `update.apply` of a v1-only image refused.

---

## MINOR (for the register)

1. **§8 fail-open table, row 4 is not what the source does.** "A legacy node can be enrolled without a claim
   proof." `claimVerify` runs `CheckMac` for both states before anything else (`node.go:572-575`); the
   legacy-only code after it is an *extra* gate ("legacy safety gate — only after CheckMac passed",
   `:579-585`). `:590` is about keeping the operator's radio. Delete the row (and it then agrees with
   negative test 8). Leaving it invites someone to "preserve" a bypass that does not exist.
2. **§8 fail-open row 3 is narrower than the source.** On a failed `resolve()` every owner-op verb
   continues on the overlay (`node.go:796-797`), not only `update.*` / `diag.bundle` / `bulk.*`; the
   state-changing ones are stopped elsewhere (unknown verdict, or the p5 commit failing). Say that, so the
   regression test covers the rc 1/8 case too (verdict not "unknown", overlay list in use).
3. **§8 "any reset is performed by the helper".** A level-4 reset happens when the system is unhealthy; say
   "by the helper binary (daemon or its boot-time command mode) under the same lock", otherwise #402 may
   find the daemon is exactly what is not running. Also name the shipped transaction row 1 should reuse:
   it is `network.leave` without the owner signature (`node.go:1312-1322`: claimed, placeholder key, radio
   blocked) plus clearing SSH material — not a new kind of record.
4. **§8 row 1 and the other slot.** After an automatic reset on one slot, the other slot's overlay still
   holds the old record and the old wireless settings. The record is rebuilt from p5 when generations
   differ (`wtxn.go:279-283`); the document should require the same for the wireless settings, or a
   fall-back puts the node back on the network it was just taken out of without the owner (I-1). One line
   for #402 plus a negative test.
5. **I-7 "with a limit on attempts"**: I found a limit only for `claim.replay` (10 per hour,
   `node.go:627-634`) and the nonce quota; none in `claimVerify`. Cite the line or drop the words.
6. **Negative test 7** ("a node without a valid network configuration does not bring up the mesh")
   contradicts §7 and test 14 for legacy nodes. Word it as I-12 does: placeholder key → radio and AP off.
7. **Stale after the user decision**: §11 V7 "checked in #13" and §9 row "member leaves / node lost … #13
   regression test" — rekey delivery is now #52 and I-5 exists only in the development app.
8. **§8 ownership, two writers on p6 `prov-state` and on root password / lock**: both are listed honestly;
   add the rule that separates them (`254-stage1-impl.md:137`: `99zz` on a fresh first boot, the helper
   afterwards) so it reads as a contract, not as an open conflict.
9. **§15 K4 "met"**: true for the join and version-chain paths. The overlay fall-back for `update.*`
   (fail-open row 3) lets a removed co-owner act when p5 cannot be decoded; it is listed under K14 and
   I-9, so cross-reference it from K4 rather than leave K4 unqualified.
10. **§13 row for #255**: the factory-reset verb is a new owner-signed, state-clearing verb; add that its
    design must state what it cannot erase on S-A/S-B (O-15) — the §9 repair row tells people to rely on it.

---

## My round-2 MAJOR findings

| Round 2 | v3 | Closed? |
|---|---|---|
| M1 §6 rules contradict the helper | Rewritten as conditions; condition 4 and F1/F2 added | **Not fully** — see M1 above (v2.0 bump ungated; later install) |
| M2 reset table | Rows split; row 3 keeps shipped behaviour (`boot.go:236-246`); ownership table extended; performer and trigger stated; #402 / field-resilience in §13; row 1 is a user decision | Closed (minors 3, 4) |
| M3 missing invariants | I-7 … I-12 added, release root in §2 | Closed |
| M4 "shipped" over-claims; legacy nodes | I-5 marked development-app only; on-the-spot proof = #255 PR 3; legacy rule in §7; I-12 cited | Closed (minor 6) |
| M5 #13 waits for open problems | User decision; §7, §10, §12, §13, §14 consistent | Closed (minor 7) |
| M6 §15 / §16 over-claims | §15 rewritten; A2, P4, §16 corrected | Closed (minor 9) |
| M7 layout | Slot state is `autoboot.txt` on the first FAT partition; bench cards may be reflashed; production uses the CM4 layout (#413, open) | Closed by explicit acceptance |

## §6 against the helper and boot code

| Item | Result |
|---|---|
| F1 reason (strict key set; "corrupt" vs "too new" take different paths) | Correct: `provstore.go:112-131`, `boot.go:236-246, 270-271` |
| F1 names both version fields | Correct: `prov.cbor` key 1 and `prov.meta` `v=` (`provstore.go:316-317`) |
| F2 release object refuses unknown keys | Correct: `release.go:161, 262-263` |
| Condition 2 (no rewrite at boot) | Compatible: `too-new` → action none |
| Condition 3 (after commit; transaction) | Compatible: `node.go:257-259` refuses state changes in a trial |
| Condition 4 reasoning | Correct as far as it goes; incomplete (M1) |
| Sufficient so v2.0 cannot paint the conversion into a corner? | Yes once M1's first sentence is added. #255's identity-cache change is already handled separately (`255-608b-impl.md` §2.8 OTA row) |

## §15 "met in v2.0" — attempts to break

| Rule | Attempt | Result |
|---|---|---|
| K4 | Replay stored configuration + secrets after auto reset; older / skipped / same-number version to a member; stale overlay after slot change | Refused by `ownerOpVerb` → `verifyOwnerOp` (`node.go:781-787, 705-742`), `netUpdate` (`:1154-1157, 1190-1202`), overlay rebuilt from p5 (`:796-803`). Holds; see minor 9 |
| K16, K21 | — | Design of #255, not implemented yet; the cell says "(#255)". Acceptable |
| K19 | A held node tries to authorize another | No key on a node signs anything another node accepts; it does know the network password (stated) |
| K22 | Factory uses dev root, release key, retained claim secret against an enrolled node | Claim refused on an owned node (`node.go:566-568`); update needs the owner (`:776-777`); trust key from the image only (`release.go:110-111`). Holds for enrolled nodes; the unenrolled case is O-3 |

## Citations checked (new or changed in v3)

| Citation | Result |
|---|---|
| `node.go:443-447` (`owner_enc_pub` used only for the re-claim PSK) | Holds |
| `node.go:609, 672` (root password returned in clear) | Holds |
| `node.go:705-740` `verifyOwnerOp` (verb, args hash, session, nonce) | Holds |
| `node.go:781-790`, `netJoin :1106-1117`, `netUpdate :1152-1155` | Hold (the check is at 1154-1157) |
| `node.go:1190-1202`, `:1242-1311`, `:256-259` | Hold |
| `node.go:566-568` (state must be legacy or unclaimed) | Holds |
| `node.go:654-661` (`claim.replay`: owner signature and claim proof) | Holds |
| `node.go:788-800` (signer must be an owner in the p5 record) | Holds |
| `node.go:251-263`, `boot/boot.go:236-271` (I-10) | Hold |
| `boot.go:263-267` (p5 unreadable keeps the overlay state) | Holds |
| `boot.go:225-229`, `node.go:590` (legacy nodes) | Hold for "legacy keeps the operator's radio"; do **not** support fail-open row 4 (minor 1) |
| `254-stage1-impl.md:95, 244` (lock from p6 `last_known_state`) | Holds |
| `deploy/provisioning/halow-keyguard.init:4-14` (I-12) | Holds; also present in `feed/batman-provision/files/etc/init.d/halow-keyguard` |
| `release/release.go:110-111`, `:161, 262-263` | Hold |
| `provstore.go:1-3` (`batman-config-save` writes p5) | Holds |
| `storage-architecture.md:21` (`autoboot.txt` on p1), `:357-359` (missing / truncated → boots partition 1) | Hold |
| `wtxn.go:262-273` | Holds |
| `219-field-provisioning.md` (no factory reset in stage 1; redesign in #255) | Holds (lines 3, 65, 130, 319) |
| `255-608b-impl.md` §2.3, §2.5, §3.2, §7 | Hold |
| `docs/threat-model.md` leftover rows | Fixed (line 33; no "mesh/FTS CA" left) |
| Scripts named in §8 (`96-batman-config-migrate`, `99zz-batman-prov-state`, `batman-prov-lock`, `batman-config-save`) | Exist in the tree; contents not read line by line |
| #413 (CM4 eMMC layout) | Issue exists, open |
