# Review v11 (reviewer B) — `docs/design/254-v16-ud.md` at 5bce2c9

I read the whole document again. I looked first at what v11 changes:
- the masked compare;
- the leak-grep hardening: empty pattern, result handling, logread windows;
- the E-UD4 probe (§0.8);
- the six pre-row fixtures;
- 02's record equality and its exact log formats.

Then I checked each claim against the source:
- `boot/boot.go:377-394` (`MeshExpect`); `node/wtxn.go:430-435` (`refreshMeshExpect`);
- `node/txn.go:18-49`; `prov-base-254.sh:72-90, 177-204`; `prov-254.sh:491`;
- `batman-config-save:263`.

Read-only: no node, no ssh. This file holds no local-only product detail.

## v10 findings: fixed in source terms?

| v10 finding | State | Checked |
|---|---|---|
| **M1** masked compare printed `sha256[:8]` of secrets | **Fixed.** `<redacted changed>`, with nothing derived from the value (no hash, prefix or length). Matching is by case-insensitive substring of the option name (`key`, `secret`, `pass`, `psk`, `token`, `sae`, plus `mesh_id`, `ssid`) over `option` **and** `list` lines. Over-masking is harmless. No HMAC is needed: a `DIFF` line already means "changed". There is one fixture per name class, and the negative control fails on both the raw value (today) and the v10 prefix. See MINOR-1 for a neighbouring path. | `prov-base-254.sh:177-204`; `prov-254.sh:491` |
| m1 empty pattern; lost window | **Fixed.** An empty value is guarded **before** the grep → INVALID, no grep. The count must be an integer with rc 0 / 1; anything else is INVALID "leak check did not run", including the global key grep over the `pr_end` / `pr_abort` output. The window start (the mark, or the boot start in the ring) must be present, else INVALID. The busybox `grep -cFf -` premise is ⚠️ until E-UD4 #1 runs, and a failure sends the design back to review. That is honest. See MINOR-2 for one gap in the window coverage. | — |
| m2 pre-row negative fixtures | **Fixed.** Six fixtures, each asserting the item-7 outcome and that no apply or prepare is sent. rc 8 → retried 3 × 5 s (positive and negative cases). The field-6 check now discriminates and has its own control: `MeshExpect` gives `today` for a claimed node with a live key and `radio` only for a member (`boot.go:385-393`), and `refreshMeshExpect` (`wtxn.go:430-435`) is the only path to `radio` here. | as listed |
| m3 02's log patterns | **Fixed, and the primary proof is better than I asked.** 02's `prov.meta` (`gen`, `sha`) plus the absence of `.txn`, equal at the arm's start and end: any record write changes `gen` / `sha` through `commitTxn` (`txn.go:18-49`). The exact formats come with file:line, and the benign lines are fixtures. A successful commit on 02 logs no line (`Persist` success is silent, `txn.go:40-46`), so the equality check is what catches it; the format list is a secondary signal. That is the right order. | `txn.go:30-49` |

v11 breaks nothing else: rows, guards, lints, ownership, lifecycle, §7.1 and the security sections are unchanged and stay
consistent.

## Findings

### MINOR-1 — the compare's manifest `DIFF` lines carry full-file sha256 of files that hold the secrets

- Besides `uci.export`, the compare prints `DIFF upper.manifest ± …` and `DIFF p5.manifest ± …` lines.
- These carry the **sha256 of each differing regular file** (`tree_manifest`, `prov-base-254.sh:83`). Among those files
  are the overlay's wireless config and p5's `overrides.uci`.
- Their other content is largely knowable: section names, the channel, the public mesh id, and the AP key to anyone who
  uses the phone AP. A full-file sha256 of such a file can therefore be used to test guesses of the remaining unknown
  key.
- This is the same class as v10's M1. It is only on the failed-restore path, and it predates this PR, but it is the same
  compare output this PR now masks.

**Fix.**
- For manifest lines whose path is a secret-bearing file, replace the hash by `<redacted changed>` in the same
  redaction pass:
  - the overlay's `etc/config/*`, `etc/shadow` and `etc/batman-prov/*`;
  - p5's `overrides.uci` and `identity/*`.
- Keep the path and the mode.
- Add a fixture for a changed wireless file → no 64-hex hash in the output (negative control: today's output contains
  it).

### MINOR-2 — the logread windows miss each trial boot's ring after landing

The greps run right after the join, at each trial landing over that boot's ring, and at the arm's end. A trial boot ends
in a reboot: UD2's deadline revert, UD4's panic, UD1's `back_to_a`. Everything that trial boot logs **after** its
landing grep is lost at that reboot without being grepped: the hold, the release and commit, the in-trial
`update-check`, the revert.

That is fail-open by omission: a key printed by a helper path that runs only late in a trial would never be seen.

**Fix (either):**
- Grep that boot's ring once more at its last controlled point:
  - UD1: just before `release` and again before `back_to_a`;
  - UD2: in `pr_wait_reverted`'s loop, keeping the last sample taken before the revert line appears.
  - UD4 panics before userspace, so it needs nothing.
- Or state the gap in §11 as not covered, with the reason.

Fixture: a stub trial ring with a key line written after landing must be caught (or the gap must be stated).

## Verdict

**APPROVE-WITH-CHANGES.** 0 BLOCKER, 0 MAJOR, 2 MINOR.

My v10 MAJOR is fixed with the right negative control, and all v10 MINORs of both reviewers are fixed in source terms.
The two remaining MINORs widen the same redaction and leak-window rules to one neighbouring path each. They can be made
during implementation, with their fixtures, without another design round.
