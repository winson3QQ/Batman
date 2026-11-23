# Review v10 (reviewer B) — `docs/design/254-v16-ud.md` at 19c07fb

I read the whole document again, with the new E-UD3 log (`v16ud-eud3.log`: `MESH-GROUP` count 3; mesh-id lines only
under `kernel` (1) and `wpa_supplicant_s1g` (6); `encryption=sae`; the key passes `--check-only` rc 0). I looked first
at the v10 changes:
- the join now runs in the trial arm only;
- the post-join reboot is replaced by four pre-row checks;
- the leak checks: the pattern comes from a pipe; the mesh id is grepped in our own tags only;
- the masked restore compare;
- `@S0@` comes from the snapshot's `prov.meta`;
- 02's helper log is captured during the trial arm.

Then I checked the two specific questions (below). Read-only: no node, no ssh.

## v9 findings

| v9 finding | State |
|---|---|
| m1 pattern file | **Fixed.** The patterns come from a pipe (`printf '%s\n' "$k" \| grep -cFf - <file>`). No file is left after a host death. See MINOR-1 for the empty-pattern and lost-mark cases. |
| m2 02 after the join | **Fixed:** 02 must be a neighbour within 180 s, as one of item 5's four checks. The others: `.txn` absent; `--check` rc 0; `prov-state` field 6 = `radio`. On failure → member rows INVALID or NEEDS-PERSON, never a row FAIL. |
| m3 `@S0@` source | **Fixed:** read from the snapshot's `prov.meta`, the same field `pr_begin` judged. |
| m4 key-location wording | **Fixed:** exact ("no file of its own beyond the snapshot"; the product's `.txn`, uci, p5). |
| m5 02 observes only | **Fixed:** 02's helper log is captured read-only over the trial arm. See MINOR-3 on its patterns. |

Join premise: E-UD3 settles `CheckRestorable`'s inputs: `encryption=sae`, and the key passes `--check-only`. The join
is no longer "unproven until the run".

## The two specific questions

**1. Do the refuse / write / kill arms, now claimed-only and never joined, still exercise what their rows claim?**
Yes.
- **Verbs.** The update and bulk verbs need only `Claimed|Member` (`node.go:784-785`), a loadable record and an owner
  signer (`:703-745`). `update.check` runs before `dispatch`; `update.go`, `updwork.go` and `bulk.go` test no `State` /
  `RadioManaged`.
- **The rows of these arms rely on state-free mechanisms:**
  - UD7, UD13 and UD6 (b): config-save, PreSave and joinwatch. joinwatch saves "regardless of lockdown".
  - UD8, UD8c and UD9: the worker and `batman-slot`.
  - UD20, UD20b, UD20c, UD8b: owner-ops behind the claimed guard.
  - UD10b: a plain reboot of a claimed node. The claimed record is reloaded from p5 at boot; nothing else differs.
- **Not exercised in these arms:** the member-only autocommit radio gate. It belongs to the trial arm, where it is now
  covered.
- **No row claims more than this.**

**2. Does the snapshot restore return 04 to member gen = 15 with its phone owners, in every arm and on abort?** Yes.

*Snapshot and restore.*
- The snapshot is taken before `pr_make_legacy`, with the dirty flag written at `snap`.
- `pr_end` and `pr_abort` both use `PR_FINAL=1 pr_restore`:
  - p5 is written back with dd and its sha verified;
  - the overlay tar is put back and extras are deleted, which removes the join's `.txn` and the H0 record;
  - `STATEFILES` restores `prov-state` (fields 3 and 6), `mesh-expected`, `mesh-joined`, `ota-armed.mesh`,
    `lock-status`, `prov-counters` and `update-last`.
- The compare then checks every file by sha, and the `ud_owner_scan` compare checks meta, sha and the owner multiset.

*In the trial arm.*
- B boots and commits under the H0 member record (UD1).
- The record goes back with the A overlay and p5.
- B's overlay is renewed by `pr_brewrite`'s `sysupgrade -n` after the restore, so B's next boot reads the restored p5.

*Rollback check.* The generation returns to 15 in both copies, so the phone app's view is unchanged.

*After a host death.* Recovery is §7.1 step 2, now with a correct `@S0@`.

## Findings

### MAJOR-1 — the masked restore compare prints `sha256[:8]` of secret values, a 64-bit verifier the design itself rules out

**Scenario.** When a wireless restore is not exact, the new masking replaces the value of `key`, `sae*`, `psk*` and
`password` options by `<sha256[:8]>`, and that line goes into the unit log (`pr_restore` echoes the last 20 compare
lines, `prov-254.sh:491`). The unit log is the run evidence that goes into the PR test-results section of a public repo.

The design argues against exactly this:
- §12 (Q9): "The AP key can be human-chosen, so its prefix is an offline verifier: replace it with a length or
  `present`."
- §4.4's own offline assert: the stubbed run output must contain neither the stub key **nor its sha256 prefix**.

A 64-bit prefix of an unsalted sha256 is enough to test guesses of a human-chosen AP passphrase or SAE key offline.
There is also a gap: the failed-restore path, the one that prints these lines, is outside the global key grep, because
that grep looks for the raw key and not for its hash.

**Fix.**
- Print no value-derived output: `<redacted changed>` / `<redacted len=N>` on each side, so "which option changed" stays
  visible.
- If equality across the two sides must be shown, use an HMAC keyed with a per-run random key that lives only in the
  node-side compare's memory and is never written. Unsalted sha prefixes are not acceptable.
- Negative control: a fixture with a changed `key` prints neither the key nor its sha256 prefix (the same rule as the
  offline leak assert). Today's compare prints the key; v10's masking prints the prefix, and the test must catch both.

### MINOR-1 — leak grep: an empty pattern, or a mark lost from the ring, must not give a false result

- **Empty pattern.** If `uci -q get …key` (or the mesh id) returns nothing, `grep -cFf -` receives an empty pattern
  line. That matches every line, so the result is a spurious FAIL with the whole log as "hits". Guard it: an empty value
  → INVALID "pattern unreadable", and no grep.
- **Lost mark.** The trial arm runs about 140 min. If the arm's `logger` mark has rotated out of `logread`'s ring, the
  "since the mark" filter yields nothing, and the count 0 would pass. The rule is that a check that finds nothing to
  check FAILs. Assert that the mark line is present, else INVALID. Also run the logread grep right after the join and
  after each trial boot, not only at the end.
- Offline fixtures for both cases.

### MINOR-2 — item 5's four pre-row checks need their negative fixtures

Each check: `.txn` present; `--check` rc ≠ 0; `prov-state` field 6 ≠ `radio`; no 02 within 180 s. Each must have a
stub fixture showing that it leads to the item-7 path (member rows INVALID "mesh not rejoined", or NEEDS-PERSON) and
that no trial row runs. A presence check is not enough; the fixtures are the negative control for v10's replacement of
the post-join reboot.

### MINOR-3 — 02's helper-log assertion needs exact patterns taken from the source

The design says "no `network/update`, `owner`, `leave`, `join` or record-write line → FAIL". Plain words like `join` or
`owner` also occur in benign helper lines: status and sampling lines, `mesh join required`, "provd stable", and so on.
A pattern list built from words risks a FAIL that is not attributable.

Take the exact `n.Log` / `logf` formats of the state-changing paths from the helper source (the verb refusal / accept
lines, the `peersRecordWritten` / commit lines), list them in the design, and add one fixture per benign line as a
negative control.

## Verdict

**REJECT for this round under the owner's rule (one MAJOR open).** 0 BLOCKER, 1 MAJOR, 3 MINOR.

Everything else is sound:
- the claimed-only arms still test what their rows state;
- the restore returns 04 to member gen 15 with its owners in every arm and on abort;
- the join is now confined to the trial arm and gated by four checks.

MAJOR-1 is a local fix to the compare's masking. Once it is fixed, with its negative control, I expect APPROVE.
