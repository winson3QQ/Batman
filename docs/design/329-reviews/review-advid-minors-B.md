# Code review B — commit f5b6b2d (rotating identifier: MINORs left from #362 / #363)

- Reviewed: `f5b6b2d` on `fix/329-advid-minors` (worktree `C:\src\Batman-advm`), against the findings of
  `review-advid-app-code-A.md` (M-1..M-6) and `review-advid-app-code-B.md` (MINOR-1..4), design
  `329-rotating-id-plan.md` §8.
- Reviewer B (independent of A). Only this file was written. Dart tests were run on this Windows host; Rust was not
  built (as instructed), so the Rust claims are checked by reading only.

## Verdict

**APPROVE-WITH-CHANGES** — 0 BLOCKER, 0 MAJOR, 6 MINOR. Every earlier finding is fixed, or was already fixed on
main with evidence. No regression found: the full Dart suite passes, and nothing in the repo parses the old trace line.
The MINORs concern how honestly the tests and the records describe themselves. None of them is a defect in the
product.

## Status of the earlier findings

| Finding | Status | Evidence |
|---|---|---|
| A M-1 (decoded CBOR not wiped) | ✅ fixed in this commit (read only, not built) | `owner.rs:209-222` `wipe_value` covers Bytes/Text/Array/Map (keys too)/Tag. The only other variants are Uint/Nint/Bool/Null (`batman-proto/src/cbor.rs:13-26`). `new` now has no `continue` after a successful decode, so `wipe_value(&mut v)` runs for every decoded record (`owner.rs:237-245`). `id.to_string()` copies the id before the wipe. The borrow of `v` ends with the `if let` scope, so it should compile (the commit says 99 passed in WSL; not rerun here). Out of scope: `parse_record` (`owner.rs:182-189`) still drops an unwiped tree. That is baseline, and A said so. |
| A M-2 / B MINOR-1 (keys left to the GC) | ✅ already on main | `git show origin/main:…/node_link.dart`: `_close(r)` for a late or discarded build (:163), `_close(old)` on replace (:169), `_close(_resolve); _resolve = null` in dispose (:1156-1157). App passes `r.dispose` (`app_link.dart:195`). |
| A M-3 / B MINOR-3 (like log not rate-bound) | ✅ already on main | `origin/main:core.dart:139,380` (round) and `:806,832` (LoginFor): one log line per address via `likeLogged`. `onScan` still returns true on each flip. That matches B's suggested fix (the plan is redone; the log is bounded). Test: `adv_hint_test.dart:154`. |
| A M-4 (S5 conclusion) | ✅ fixed | New test `adv_hint_test.dart` "S5: after two silences…": exact list `['B@3','B@11','C@30']` and `k1 == k0`, non-null. A version that stops the look-around after the cap would drop `C@30` and fail. I checked this by reading; I did not run that mutant. See MINOR-6. |
| A M-5 (S4 golden comparison) | ✅ for what A asked; ⚠️ see MINOR-1 | New test `adv_hint_link_test.dart` "S4: …". A also asked that the §3.4 second consequence and the phone build time (D2) be listed under "not tested" in the PR body. The PR is not written yet, so this stays on the PR checklist. |
| A M-6 (record held two runs) | ✅ already on main | `git show origin/main:…/adv-id-app-negative-controls.txt \| grep -c "not discriminating"` → `1`. `adv-id-app-nc.py:93,97` write with `'w'`. |
| B MINOR-2 (trace hides how many opened) | ✅ fixed | `node_link.dart:174` `adv resolver $n: ${r.opened ?? '?'} of ${ids.length} record(s) opened, … ms`. App: `plains.length` (`app_link.dart:195`) = the records that opened (`app_link.dart` buildResolver). Test: `adv_hint_link_test.dart:249-256`. |
| B MINOR-4 (R2 control mislabelled) | ✅ fixed in the script; ⚠️ the record is stale | `adv-id-app-nc.py:77-79` renamed to "R1". The record still says `## R1/R2: keyed by the device id only` (`adv-id-app-negative-controls.txt:103`). See MINOR-4. |

## Regression checks

- **Trace format.** `grep -rn "adv resolver"` over the repo (excluding build output) finds the producer
  (`node_link.dart:174,176`), the tests (`adv_hint_link_test.dart:96,191,219,243,255`) and `adv-id-app-nc.py:51-55`,
  which mutates only the *failed* line and is unchanged. No script, harness or log parser reads the success line. The
  line carries a build number, two counts and ms. It has no id and no address (security ✅).
- **`Resolver` constructor.** The new third parameter is optional and positional, so existing calls still compile.
  Call sites: `app_link.dart:195` (passes `plains.length`) and the tests. The full suite compiles and passes (below).
- **`unsafe` in `wipe_value`.** `str::as_bytes_mut` followed by `fill(0)`: a NUL byte is valid one-byte UTF-8, so the
  `String` stays valid. There is no aliasing (`&mut` through the match), and no panic path between the unsafe write and
  the use. Sound.

## Tests run (✅ verified)

```
flutter test test/nodelink/adv_hint_link_test.dart test/nodelink/adv_hint_test.dart
00:00 +24: All tests passed!

flutter test            (whole app suite, clean tree at f5b6b2d)
01:09 +2319: All tests passed!
```

Negative control for S4, the commit's own mutant (`node_link.dart` `_hint`: `return r.resolve(mfr) ?? 'Y1';`):
```
Which: at location [1] is '2.6   B like Y1' instead of '2.6   B×Y1 -> body green'
00:00 +0 -1: Some tests failed.
```
→ ✅ discriminates.

The design's S4 mutant (§8 S4 row: "treat a null hint as 「像」 of the page's target"; here `core.dart` `onScan`:
`hint ??= 'Y1';`), with `git diff --stat` showing only `core.dart | 1 +` before and after the run:
```
00:00 +1: All tests passed!
```
The rest of `test/nodelink` under the same mutant: 10+ failures (`… and 9 more`). → The design's S4 control is caught
by the existing suite, not by the new test. See MINOR-1.

⚠️ Note on the run: after one restore, `node_link.dart` still held the `_hint` mutant. The most likely cause is my
backup in a shared `%TEMP%` path, which reviewer A, working in the same worktree, may also have used. That is
inferred, not proven. I restored the file with `git checkout`, checked that `git status` was clean, and reran the core
mutant and then the full suite on the clean tree (results above). At the end the tree holds only
`review-advid-minors-A.md` (A's) and this file.

## Findings

### MINOR-1 — the new "S4" test checks a different property from the design's S4

- Scenario: §8 S4 says "every existing core simulation with `hint = null` everywhere → traces identical to today's",
  and its negative control is "treat a null hint as 「像」 of the page's target". The new test compares a resolver that
  resolves to none with a build that never completes. In both runs the core sees `hint == null`, so a core change in
  how a null hint is handled moves both runs alike and the test passes. I ran exactly that mutant (above): it passes.
  What the test does prove is the NodeLink side: a resolver that resolves to none feeds the core the same thing as no
  resolver. That is what A M-5 asked for, and it is useful.
  The never-completing builder stands in for "no resolver" only because `Rig` cannot take `build: null`
  (`adv_hint_link_test.dart:59`, `build ?? …`). It is equivalent: `_hint` returns null while `_resolve == null`
  (`node_link.dart:187-189`).
- Evidence: the run above. The commit message's "S4 — … same scheduler log as no resolver" is accurate. Its title "S4:
  no hint = the behaviour without the identifier" reads as the design's S4, which this test does not show.
- Fix: rename the test (e.g. "S4 (NodeLink): a resolver that resolves to none = no resolver"). In the PR body, say
  that the design's S4 control is carried by the existing suite (≥10 failures under the mutant).

### MINOR-2 — raw NUL bytes in `owner.rs`

- Scenario: the new Rust test writes the expected wiped strings as literal NUL characters inside `"…"`
  (`owner.rs:1996` `Value::Text("<NUL>".repeat(18))`, `:1998` `Value::Text("<NUL>".into())`). `git show` renders them
  as blanks, so the test looks as if it expects spaces, which reads as a bug in review. `grep` now treats `owner.rs`
  as a binary file (`Binary file owner.rs matches`), so line-based searches of the file silently stop showing lines.
- Evidence: a Python byte scan found 1 NUL each on lines 1996 and 1998. Before this commit the file had none.
- Fix: write `"\0".repeat(18)` and `"\0".into()`.

### MINOR-3 — the Rust test proves `wipe_value`, not that `new` calls it

- Scenario: a refactor that goes back to `let Ok(v) = … else { continue }` with an early `continue` (the shape
  before this commit), or that drops the `wipe_value(&mut v)` line, keeps
  `a_decoded_record_is_wiped_nested_ones_included` green. The commit's control ("texts or bytes not wiped fail the
  Rust test") mutates the body of `wipe_value` only.
- Evidence: `owner.rs:1985-2001` calls `wipe_value` directly. `new` (`:234-249`) is not covered for this property.
- Fix (small, no new mechanism): move the per-record work into a function that takes the decoded `Value` by `&mut`
  and returns the key. Test that after the call the passed value is zeroed. Or at least state in the control list
  that the call site is covered only by reading.

### MINOR-4 — the negative controls the commit claims are neither in the control script nor in its record

- Scenario: the commit message names four controls (S4 null→Y1, S5 look-around stopped, trace prints the asked count,
  Rust wipe). `adv-id-app-nc.py` has none of them; its S4/S5 entries (`:30-36`) are the older ones. The record
  `adv-id-app-negative-controls.txt` was not regenerated, so it still shows the old label `R1/R2` (`:103`) that this
  commit renamed. The user's rules ask for a negative control on each claimed fix, with output. Right now only the
  prose claims them. I reproduced the S4 one (above). The others I checked by reading only.
- Fix: add the four mutants to `adv-id-app-nc.py` and regenerate the record, so it is one run of the code as
  committed.

### MINOR-5 — stale comment: "Rust's CBOR values are not [zeroed]"

- Evidence: `app_link.dart:45-46` (the `buildResolver` doc) still says the channel's buffer, FRB's message "and
  Rust's CBOR values are not" zeroed. For `AdvResolver::new` the CBOR values now are. A later reader may skip the
  wipe as "known gap".
- Fix: reword to say that `AdvResolver::new` wipes its decoded tree, and that the channel buffer and the FRB message
  are still not zeroed.

### MINOR-6 — test realism and coverage details

- (a) The new S5 `roundEnd` (`adv_hint_test.dart:122`) reports the result at `t + 2 s` but keeps polling `next()` at
  `t + 0.5 s`, `t + 1 s`, …, which is earlier than the result it just gave. The core then sees time go backwards.
  This is deterministic and the expected list is plausible, but the timeline cannot happen in the field. A bug
  that compares `now` against the last result's time could hide. Fix: after a result, move `t` on to the result time.
- (b) `plain.toSet()` (`:133`) drops the order and any repeat. An extra unhinted attempt on the same address in the
  same second would pass. Fix: compare the list.
- (c) The app's `opened` value (`app_link.dart:195`, `plains.length`) has no test. The trace test uses a fake builder
  that passes `1`, so a regression back to `ids.length` in `app_link.dart` would pass. Also, "opened" counts records
  that decrypted, not records that gave a key. A record that opens but has no 32-byte key 6 (all records have one
  since bbd74c6, design F20) would show as opened while giving no hint. Note this in the doc of `Resolver.opened`; no
  code change is needed.

## Not done

- ❌ Rust build and test (not possible on this host by instruction). The A M-1 / MINOR-2 / MINOR-3 statements about
  Rust come from reading the source.
- ❌ The S5 "look-around stopped" mutant and the "asked count" mutant were not run. Both were judged by reading
  (the expected strings make them fail by construction).
