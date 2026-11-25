# Review v4-A: #423 security architecture (`security-architecture.md` v4, commit 2978d94)

Reviewer A, independent, read-only. Read the diff `e4c9930..2978d94`, `423-reviews/v3-changes.md`, then
the whole document once more for consistency. No node or device touched; nothing executed except `git`,
`grep`, `sed`. Statements about shipped code come from reading the source in the worktree.

## Verdict

**APPROVE** — 0 BLOCKER / 0 MAJOR / 3 MINOR (new, for the register).

No further round is needed from my side. What is approved is the document as a foundation for v2.0: the
trust model itself stays open (§10) by user decision and is not covered by this approval.

## 1. My round-3 M1 (§6) — closed

- "v2.0 tickets do not change the record key set" is now a stated rule, with the check that #255 and the
  two reset actions need no new key. I agree with that check for the reset rows: row 1 ends in the existing
  `Claimed` state via the shipped leave transaction (`node.go:1312-1322`; key 12 `Left` already exists),
  row 2 ends in the existing `Unclaimed` state.
- If a ticket must change the key set, conditions 2–4 and 7 apply to the first write and it gets its own
  L3 review. That closes hole (a).
- Condition 7 (the helper refuses to install an image that cannot read the current record version, for
  updates and allowed downgrades) closes hole (b). The note that the helper has no way today to know what
  the other slot reads, and that a one-line file in the image is enough, is correct and honest.
- Negative controls are present: install refused when the record is newer than the image can read; the
  v2.0 regression "a record written by a v2.0 image is readable by a v1.6 image".

## 2. Reviewer B's MAJOR (§8 row 1 trigger) — sound, no conflict with shipped code

- The requirement is now testable: nobody can *request* a reset through anything provd can reach (root-only
  channel, not a `helper.sock` verb); failures a peer can cause do not count towards level 4.
- It matches the source: the shipped health check does require neighbours in some states
  (`batman-autocommit:451-464`: `member`, and `claimed` with the placeholder key when p6 says the node has
  been in a mesh), so excluding neighbour-dependent items is a real constraint, not a formality.
- It reverses one line of #402 as written ("count non-power abnormal boots"); §13 lists that change. Good.
- The remainder is stated as a residual risk with its consequence (a temporary disturbance can become a
  lasting off-network state until the owner's phone arrives). That is the honest cost of the user's
  decision and it is written where #402 will read it.
- Reusing the leave transaction is consistent with the health check: leave removes the `mesh-joined` /
  `mesh-expected` markers, so after the reset the node is not judged "lost its key, neighbours required".
- Nothing here conflicts with shipped behaviour: level 4 does not exist yet, and the automatic paths that
  do exist (`boot.go` rc 7/9/10/13) are unchanged and described correctly in rows 3 and 4.

## 3. MINOR fixes — no new contradiction found

All sixteen register items are applied as `v3-changes.md` says. One register item is marked OPEN by the
author ("BLE health only warns" — not checked against source); I did not check it either.

## New MINORs (register)

1. **I-7 citation offset.** `node.go:571-576` is the state check and the nonce; the claim proof that also
   applies to legacy nodes is the `CheckMac` call just below it (about `:580-582`), before the
   "legacy safety gate". The statement is right; move the line numbers.
2. **§8 fail-open row 3 wording.** "The state-changing ones are still frozen by I-10" is true only when
   the boot verdict is unknown. When p5 is unreadable but the slot has an overlay copy (fail-open row 2,
   `boot.go:263-267`), the verdict is the overlay's state and state-changing verbs are stopped by the p5
   commit failing, not by I-10. Say "frozen by I-10 or stopped at the commit".
3. **§7 step 3 "refuse, count attempts".** I-7 now says the attempt limit exists only on `claim.replay`;
   the §7 cell still says "計次". Drop the word or point it at `claim.replay`.

## Citations checked this round

| Citation | Result |
|---|---|
| `node.go:1312-1322` (leave transaction) | Holds |
| `boot/boot.go:190-232` (no identity and no record on p5 → unclaimed / legacy record) | Holds (rc 7 and rc 9 branches) |
| `feed/batman-provision/files/usr/bin/batman-autocommit:451-464` (health check requires neighbours in some states) | Holds |
| `feed/batman-provision/files/etc/uci-defaults/96-batman-config-migrate:84-93` (`/etc/batman-dev-open` keeps the node open) | Holds |
| `254-stage1-impl.md:137` (prov-state: `99zz` on a fresh early boot, the helper from S89) | Holds |
| `node.go:571-576` (legacy nodes also need the claim proof) | Fact holds; line range is a few lines early (minor 1) |
| `release.go:162` (`onlyKeys`) | Holds |
| All citations checked in rounds 1–3 and unchanged in v4 | Not re-opened |
