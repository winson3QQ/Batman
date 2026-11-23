# Review v8 (reviewer B) — `docs/design/254-v16-ud.md` at c518df7

I read the whole document again, with the device evidence:
- `v16ud-ud36-h0diag.log`: `state=member gen=15`; four 65-byte points, fingerprints `69c294e5…`, `5f70ebc4…`,
  `031b0159…` ×2; H0 `e487a55c…`; `H0-IN-RECORD=no`;
- `v16ud-ud36-diag.log`.

I looked first at lifecycle while 04 is claimed by H0. Then at the restore (record, p5, shadow, p6), the owner-op guard,
the accepted start states, and security.

Source checked:
- `node.go:560-607` (`claimVerify`), `:703-745` (owner-op verifier);
- `peers.go:592-601`;
- `boot/boot.go:205-235`;
- `cmd/batman-provhelper/main.go:500-548, 600-615`;
- `prov-254.sh` at c518df7 (`:487-502, 523-524, 746-770, 896-924`);
- `prov-base-254.sh:36, 72-90, 100-104, 145-157, 273-275, 332-336`;
- `prov-p9-254.sh` at c518df7 (`:84-127`);
- `tests/tools/provclient/main.go:6-8, 470-496, 533-539, 631, 655`.

Read-only: no node, no ssh.

## Premise #12 and the owner decision

The diagnosis is sound. The verifier tries only `rec.Owners` (`node.go:703-745`). H0 is not in 04's record (h0diag), and
the offline `ownerop_test.go` reproduces code 3 for a non-owner. Option 1 (temporary ownership by H0, restored from the
snapshot) uses only existing harness paths:
- `pr_make_legacy` after the snapshot (`prov-254.sh:747, 758-770`);
- a claim proven by `pk_proof` first (`:896-907`);
- `PR_FINAL=1 pr_restore` from the pre-claim snapshot.

## Lifecycle with 04 claimed by H0 (what state 04 is left in)

| Event | State of 04 | Recovery | Verdict |
|---|---|---|---|
| Reboot inside an arm (UD10b, the sysrq cut, the trials, `back_to_a`) | `claimed`, `Owners=[H0]`. p5 carries the claimed record, so the helper's boot on A, and on a fresh B slot during a trial, reads it back from p5. | none needed. §4.4-5 re-runs the guard after every reboot, and provclient is re-placed. | sound |
| Abort or unexpected exit with the host alive | — | `pl undo` → `PR_FINAL=1 pr_restore` (p5 dd + overlay tar + STATEFILES, then reboot) → B rewrite → `pr_finish_snap` | sound |
| Host death **after** the claim | claimed by H0, root password random, password login locked (as on the member S0, which was also locked by its own claim). The dead-man never touches p5 or the record (`prov-lease-254.sh:17-21`). | **NEEDS-PERSON:** §7.1 step 2 restores the snapshot record. Stated in §7. | sound, but see MINOR-1 / MINOR-4 |
| Host death **between `pr_make_legacy` and the claim** | **legacy**: no owner, claimable over BLE by anyone holding the claim QR (`claimVerify` accepts Legacy, `node.go:566`). Password login stays as it was: the helper's legacy boot changes no lock (`main.go:523` only completes locks for claimed / member). | §7.1 step 2 | MINOR-4: state it |
| Power loss during `pr_make_legacy` (p5 stripped, overlay record still there) | the helper's boot repairs p5 from the overlay or comes up legacy (`boot.go:205-235`). The dirty flag was written at `snap` (`prov-base-254.sh:157`), before `make_legacy`. | §7.1 step 2 restores from the snapshot either way | sound |
| Host death during the final restore | half-restored | existing `PR_RESTORING` → NEEDS-PERSON; the snapshot is kept, so §7.1 step 2 can run the restore again | sound |
| The B slot after trials under the H0 record | B's overlay may hold the claimed record | the slot write's `clear_root` and `pr_brewrite`'s `sysupgrade -n` give B a fresh overlay; p5 is the member again by then | sound |

**Is any path left where 04 stays owned by H0?** Only a host death after the claim with no person running §7.1. That is
fail-closed and NEEDS-PERSON, as the owner chose. It is printed by P9 and documented in §7. While 04 is in that state,
the phone app's owners cannot manage it.

**Does the restore bring the original back byte for byte?**
- **p5:** `p5-restore` writes the snapshot image back with dd and verifies its sha uncached.
- **Overlay** (prov record, `prov.meta`, `/etc/shadow`, uci dropbear): the overlay restore copies the tar back, deletes
  extras, and the compare uses a sha per regular file (`tree_manifest`, `prov-base-254.sh:72-90`).
- **p6 state:** `prov-state` (written by `SetLastKnown` at the claim), `lock-status`, `prov-counters` and
  `update-last` are all in `STATEFILES`.
- **Generation:** it returns to 15 in both p5 and the overlay, so no anti-rollback mismatch arises between them.
- **Identity:** the claim does not rotate `claim.secret` or the identity keys (`node.go:589-597`).
- **Peer table:** reset in memory only (`peers.go:592-601`).
- **New check:** v8's scan compare of meta, sha and owner multiset against `ud-s0/<RUN>.txt` makes the record check
  explicit.

**Owner-op guard.** It checks `state=claimed`, `owners=1` and `H0-IN-RECORD=yes` before every owner-op and after every
reboot. A failure makes the arm's owner-op rows INVALID "H0 not an owner"; a code 3 while the guard holds stays a FAIL.
That is the right split.

**Start states.** member / claimed / legacy are accepted; `make_legacy` is a no-op for legacy and refuses anything else.
unclaimed → INVALID with the reason (an unclaimed claim would make the radio app-managed, `node.go:591`). The end state
is checked against the start state by `pr_finish_snap` and the scan. Sound for the unit itself; not yet for §7.1
(MINOR-1).

## Findings

### MINOR-1 — §7.1 step 2 and step 3 still assume a `member` start; v8 accepts `claimed` and `legacy` too

The printed block (`prov-p9-254.sh:118` at c518df7, and §7.1) hard-codes `PR_BASE=member PR_S0_STATE=member`. Step 3's
comment expects `state=member`.

After a host death in a run that started `claimed` or `legacy`, which v8 now explicitly supports, `pr_finish_snap`
compares against the wrong state. It does one more final restore and then ends in NEEDS-PERSON "prov state … also after
a second restore" (`prov-254.sh:528-540`), although the restore was right. This is not destructive, but it is a wrong
instruction for exactly the re-run case the owner asked for.

Fix:
- P9 reads the S0 state from the dead run's snapshot. The prov meta is inside the snapshot dir
  (`/opt/batdata/dv-prov/<run>/snap/…`), or `ud-s0/<RUN>.txt` on the host.
- Validate it against `legacy|claimed|member`, and substitute it as `@S0@`. `PR_BASE` stays irrelevant under
  `PR_FINAL=1`.
- Step 3's comment says "state = @S0@ and the same owners".
- Add a dry-run case with a `claimed` S0.

### MINOR-2 — the design text and the code differ for step 0b2; v7's review has no disposition

`prov-p9-254.sh:103` at c518df7 correctly uses `kill -TERM "-$p"` with a group wait (B v7 m1). The §7.1 block in the
document (line 665) and §19's row still show `kill -TERM -- -$p`, the form that busybox refuses (E25,
`ble-lib-254.sh:129-131`). The doc says the printed text is the code, so bring the doc in line. Also add a §20 row
dispositioning both v7 reviews.

### MINOR-3 — §8 overstates "the harness never reads `claim.secret`", and leaves out what holding H0 allows

**The claim secret.**
- The harness's own node-side tool reads it: provclient runs as root, reads
  `/etc/batman-prov/identity/claim.secret` into memory (`main.go:533-539`), uses it only for the CheckMac
  (`:631, 655`), then drops to 471 with dumpable = 0 (`:470-496`). It is never printed or sent.
- The §8 bullet itself describes exactly this, so its lead-in ("the harness never reads") contradicts its own text.
- Word it as "read in memory by the harness's root-started provclient only; never printed, logged or copied; not
  dumpable".

**What H0 can do while it owns 04.** The exposure bullet should name it: `root_password.reset` (the new password is
returned to the owner in clear), `ssh_keys.set`, and `network.leave` — root on 04 for whoever holds H0.
- That window lasts for the arm **and**, after a host death, until §7.1 runs.
- H0 lives on the WSL host next to the lab ssh key, which already gives root on 04, so the trust level is unchanged.
  Acceptable on the bench.

### MINOR-4 — state the legacy window and make P9 say "owners not restored"

**The window.** Between `pr_make_legacy` and the claim, 04 has no owner. A host death there leaves it legacy until a
person acts, and any holder of 04's claim QR can claim it over BLE (`node.go:566`).
- Add that row to §7.
- Keep the claim immediately after `make_legacy`, with no long step in between. The design does this; say so.

**P9.** When the dirty flag names a `pupdate254…` run, have P9 also print a one-line read-only fact before the block:
current `state` / `owners` count vs the snapshot's. Then the person sees at once "04 is claimed by the bench key, the
phone owners are locked out" — the user-visible consequence the owner cares about.

## Owner's provisional answers

- **Q14 (keep H0): agree.**
  - Every row already signs with `h0.pem` (§1.1).
  - H0 sits on the same WSL host as the lab key.
  - After a host death, H0 (unlike a per-run key whose WSL copy is deleted by `pr_keys_drop` at the end) still lets
    the bench operator act as owner while recovering.
  - The extra exposure is stated in MINOR-3.
- **Q15 (the member-only `meshjoin_radio_up` gate not covered): agree.**
  - The §4.4 table shows, with source, that the update and bulk verbs are state-free.
  - Both states need 02 to commit, so no assertion changes.
  - Only `batman-autocommit:564-565` is member-specific.
  - It is stated in §11. A checklist line on #254 ("app-path trial on a member node: the radio gate") would keep it from
    being forgotten.

## Verdict

**APPROVE-WITH-CHANGES.** 0 BLOCKER, 0 MAJOR, 4 MINOR.

The temporary-ownership design is sound from the source:
- every path that leaves 04 claimed by H0, or legacy, is fail-closed and NEEDS-PERSON, with a documented recovery;
- the restore brings back the record, p5, the shadow and p6 byte for byte, and the scan compare checks it;
- the guard turns "not an owner" into INVALID;
- the start-state rules are right for the unit.

The four MINORs are text and §7.1 / P9 fixes that can be made during implementation. MINOR-1 is the one that matters
for the owner's "re-runnable from any start state".
