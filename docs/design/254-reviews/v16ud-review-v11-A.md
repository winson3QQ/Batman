# Review v11 — reviewer A — `docs/design/254-v16-ud.md` v11 (5bce2c9)

I read the whole document and checked it against source. Read-only: no node, no ssh, nothing committed. Product
exposure items are only referred to as "local-only item N" (this repository is public).

## 1. Were the v10 findings fixed?

| v10 finding | State in v11 |
|---|---|
| A m1 masking (name set; replacement value) | **Fixed.** Pattern match, case-insensitive substring (`key`, `secret`, `pass`, `psk`, `token`, `sae`) plus `mesh_id` and `ssid`, on both `option` and `list` lines. The replacement is `<redacted changed>`, with nothing derived from the value. The fixture per name class has a negative control that fails on today's raw output and on v10's prefix. |
| A m2 pre-row checks | **Fixed.** rc 8 is retried 3 × 5 s. Six fixtures each assert the item-7 path **and** that no apply / prepare is sent. Fixture 5 (claimed, never joined → field 6 = `today`) is the field-6 check's negative control. Fixture 4 is the positive case. |
| A m3 `grep -cFf -` | **Fixed in the design, pending the probe.** E-UD4 (§0.8) is owed before the device run. Any non-integer count, rc 2, or an empty pattern → INVALID "leak check did not run". The empty-pattern guard runs before the grep, which matters because an empty `-F` pattern matches every line (§0.8 #2). |
| B v10 M1, m1–m3 | **Fixed** as dispositioned: no value-derived output; mark / boot-start asserted in the ring; 02's `prov.meta` (gen, sha) and `.txn` equality as the primary proof. |

## 2. The log-format table (B m3): every file:line checked against the helper source

| Cited | Source line | Match |
|---|---|---|
| `node/txn.go:34` | `n.Log("commit: %s", e.Reason)` | yes |
| `node/txn.go:44` | `n.Log("--prov-only rc=%d but p5 holds generation %d: committed", …)` | yes |
| `node/txn.go:49` | `n.Log("overlay write after a committed p5 write failed: %v", err)` | yes |
| `node/node.go:606` | `n.Log("claim committed, lock / save incomplete (%s): …")` | yes |
| `node/node.go:1347, 1351, 1354` | `network.leave: committed, forgetting the mesh failed` / `network.leave: mesh markers` / `network.leave: save rc=%d … — .txn kept` | yes |
| `node/node.go:1304` | `n.Log("%s: save rc=%d (%s) — .txn kept, the next boot finishes it", verb, …)` | yes |
| `node/wtxn.go:187, 198, 307, 320, 335, 348` | `CRIT finish: …` (×2), `finish (%s): …`, `CRIT finish (%s): …` (×2), `finish (%s): the radio is switched off by hand …` | yes |
| `node/wtxn.go:282-284` | `resolve: overlay rebuild from p5 failed` (282), `resolve: overlay rebuilt from p5 (gen %d)` (284) | yes |
| `node/updwork.go:239, 291-293, 761, 771` | `update.prepare: %s: worker started`; `update worker: … refused` / `… written and verified`; `update.apply: reboot failed`; `update.apply: %s armed, rebooting` | yes |
| `node/node.go:904, 921` | `ssh_keys.set: --save rc=%d …` | yes |
| `node/settingsset.go:55, 59` | `CRIT settings.set %s: halow-setkey rc 6 …` / `rc %d — stopped part-way …` | yes |
| benign: `update.go:269`, `node.go:245`, `cmd/batman-provhelper/status.go:143` | `update.check: refused, reason …`; `verb %s refused: code %d (%s)`; `p5 stale only in keys P3 added: --save rc …` | yes |

The helper's syslog lines carry no prefix after `batman-provhelper[pid]: ` (E-UD1 #24: `… batman-provhelper[4204]: boot
rc=0 verdict=member …`), so the prefix match is right.

## 3. Findings

No BLOCKER, no MAJOR.

### MINOR

1. **The format list is not exhaustive; say it is secondary.** A successful record commit logs nothing at all: `commitTxn`
   logs only its failure, `txn.go:34`. The helper also writes state on other paths not in the table:
   - `%s: the overlay was stale (generation %d -> %d): rebuilt from p5` (`node.go:802`), an overlay record write;
   - `prov-state mesh_expect: …` (`wtxn.go:433`);
   - the `--save` lines at `node.go:484, 521, 537`;
   - `claim: p6 last_known_state not updated` / `claim.replay: …` (`:601, 666`).

   Proof that 02's record is unchanged rests on item 1 (`prov.meta` gen / sha + `.txn`), which is correct. State that the
   log table is a secondary signal and not complete. Add `node.go:802` (a record write by definition) to the table.
   Optionally compare 02's p6 `prov-state` fields 2–6 at the arm's start and end, which catches a `mesh_expect` change.
2. **logread coverage gap inside the B trials.** The B-boot ring is grepped "at landing". It is lost at the revert or
   at `back_to_a`, and in between the trial keeps logging. UD2 is held until its deadline (about 600 s after landing),
   and UD1's in-trial steps (`update-check V`, status polls, the release) run **after** landing. A leak in those lines
   would never be seen, and nothing turns that into an INVALID. Fix:
   - grep the B ring a second time just before the trial ends: in UD2 at the last HELD sample before the deadline; in
     UD1 right before `back_to_a`;
   - if that second grep cannot run (the node already reverted), the window is "lost" → INVALID, as for a missing mark.

   Add a fixture: a stub key line logged after landing → FAIL.

## 4. Verdict: **APPROVE**

0 BLOCKER, 0 MAJOR, 2 MINOR (fixable in implementation).
- Every v10 finding of both reviewers is fixed in source terms.
- Every file:line in the log-format table matches the helper source.
- E-UD4 remains a precondition of the device run, as §0.8 states.
