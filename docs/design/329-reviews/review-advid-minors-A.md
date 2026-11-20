# Review A — commit f5b6b2d (rotating identifier: code-review MINORs left from #362 / #363)

Reviewer: independent, adversarial, read-only (only this report written). Base: `fix/329-advid-minors` at f5b6b2d.
Inputs: `git show f5b6b2d`, `review-advid-app-code-A.md` (M-1, M-4, M-5), `review-advid-app-code-B.md` (MINOR-2, -4),
`329-rotating-id-plan.md` (§3.3, F20), and the source around every changed line.

## Verdict: APPROVE-WITH-CHANGES

No BLOCKER, no MAJOR. Each of the five targeted findings is addressed, and the four claimed Dart negative controls
reproduce (raw output below). Three MINORs below are cheap to fix. None of them is a product defect: two are test
gaps that let a plausible regression through, and one is a raw NUL byte in a Rust source file.

## What holds (checked)

1. **`wipe_value` is sound.** `owner.rs:207-222`. `str::as_bytes_mut` is unsafe because the caller must leave valid
   UTF-8 when the borrow ends. A run of 0x00 bytes is valid UTF-8, so the SAFETY comment is right. There is no
   aliasing: `&mut Value` is exclusive, and `t` is a fresh `&mut String` from the match. The `Value` tree
   (`batman-proto/src/cbor.rs:13-26`) has Uint, Nint, Bytes, Text, Array, Map, Tag, Bool and Null, and every
   variant that holds heap data is covered. Map keys are wiped too. Recursion depth is bounded by the decoder's
   `MAX_DEPTH` (`cbor.rs` `item`). The decoder allocates exact-length buffers (`take(n)?.to_vec()`, then
   `String::from_utf8` reuses that Vec), so no unwiped spare capacity holds old bytes.
2. **Every successfully decoded record is wiped.** `owner.rs:236-245`: the `if let` no longer `continue`s before
   the wipe, so a record with no key 1, no key 6, or a key 6 that is not 32 bytes still reaches
   `wipe_value(&mut v)`. The borrows `id` and `key` from `v.get(..)` live only inside the `if let`. `id.to_string()`
   copies before the wipe, and the borrow checker would reject any use after the wipe anyway. The kept `id` string
   is the device id, which the resolver must hold by design, so it is not a secret.
3. **`Resolver.opened`.** `node_link.dart:70-76`: an optional third positional field on a `const` constructor. All
   constructors compile and keep their meaning (callers: `app_link.dart:195`, `adv_hint_link_test.dart:19, 252,
   259`; the suite of 24 passes). `opened` is `plains.length`, and `plains` holds only the records whose `open`
   returned non-null (`app_link.dart:50-58`). So it counts the records that opened, not the ones asked for. With no
   value the trace prints `?`, which is honest.
4. **The trace carries no id or address.** `node_link.dart:174` prints a build number, two counts and ms. The failure
   path still prints only `runtimeType`.
5. **S5 (`adv_hint_test.dart` `roundEnd`)** is pure core on explicit times, so it is not timing-fragile. It asserts the
   exact attempt list (`B@3, B@11, C@30`), the no-hint world, and an equal non-null conclusion for Y. That covers
   both halves of A M-4.
6. **The rename in `adv-id-app-nc.py:77-79` is correct.** Under the zero-key mutant, the R2 test's first assertion
   (`owner.rs:1973`, old record vs. the advert under the new key gives None) still passes, and the test fails on its
   positive line `:1974`. So the mutant shows R1 only, as the new comment says.

## Findings

### MINOR-1 — S4 would pass if NodeLink never installed or never consulted the resolver
- Scenario: a regression drops the built resolver (for example `_resolve = r` lost, or `_hint` returning null
  before calling `resolve`). Then both runs of S4 feed identical null hints and S4 passes. The test is meant to show
  that a resolver giving no hint changes nothing, yet nothing in it shows that a resolver was there and was asked.
- Evidence: `adv_hint_link_test.dart:99-120`. `withResolver` and `without` are compared only with each other. The
  S7 tests catch the "never installed" case elsewhere, but S4 on its own does not discriminate it.
- Fix: in the `withResolver` run, assert that the trace has `adv resolver 1:` and that `resolve` was called for `B`
  (wrap `byFirstByte` with a call counter).

### MINOR-2 — the Rust test checks `wipe_value`, not that `AdvResolver::new` calls it
- Scenario: someone deletes the `wipe_value(&mut v)` call at `owner.rs:243`, or moves it into the `if let` so that a
  record with no 32-byte key 6 is no longer wiped. `a_decoded_record_is_wiped_nested_ones_included` (`:1986-2001`)
  still passes, because it builds a `Value` by hand and calls `wipe_value` directly. The commit's control ("texts
  or bytes not wiped fail the Rust test") is true of the helper only, not of A M-1's fix at the call site.
- Fix (small): move the per-record body into a helper, for example `fn key_of(v: &mut Value) -> Option<(String,
  [u8;32])>`, that wipes before returning. Then test that helper on a decoded record with a key, one without key 6,
  and one with a 16-byte key 6, asserting the tree is zeroed afterwards. Or at least state the limit in the control
  list.

### MINOR-3 — raw NUL bytes in `owner.rs` turn the file "binary" for tools
- Evidence: bytes 0x00 inside the string literals at `owner.rs:1996` (`Value::Text("<NUL>".repeat(18))`) and `:1998`.
  A Python scan found exactly these two lines, and the parent commit has none. Effect seen during this review:
  `grep -n ... owner.rs` now prints `Binary file app/rust/bridge/src/api/owner.rs matches` and no lines. The same
  happens to ripgrep, editors and review UIs that sniff for NUL. rustc accepts the bytes (the commit reports 99
  passing in WSL, which I did not rerun).
- Fix: write `"\0".repeat(18)` and `"\0".into()`.

### Notes (not findings, nothing asked)
- `cbor::decode` error paths (`cbor.rs:115-121`, for example `TrailingBytes` after a full item) drop a partially or
  fully decoded tree unwiped. The records are this phone's own authenticated sealed records, so only corrupt
  storage reaches this. The map-key copies `kb` / `prev` are small integer keys and not secret.
- `fill(0)` right before a drop can in principle be removed by LLVM dead-store elimination. The codebase uses the
  same plain-`fill` pattern everywhere (`AdvResolver::wipe`, `plain.fill(0)`), `zeroize` is only a transitive
  dependency (`bridge/Cargo.lock:1567`), and changing this is beyond the findings being fixed.
- `opened` counts records that opened, not records that yielded a key. By F20 (`329-rotating-id-plan.md:53`) every
  record carries key 6, so the two are equal in practice.

## Negative controls rerun (Dart)

To avoid touching the shared worktree, I ran them on an exported copy (`git archive f5b6b2d app` into my
scratchpad; `flutter pub get --offline`). Baseline: `adv_hint_test.dart` + `adv_hint_link_test.dart` give
`00:00 +24: All tests passed!`. I restored each mutant afterwards, and `cmp` against the saved originals reported
`restored`.

| Mutant | Test | Result |
|---|---|---|
| `_hint`: `r.resolve(mfr) ?? 'Y1'` | S4 | FAIL: `at location [1] is '2.6   B like Y1' instead of '2.6   B×Y1 -> body green'` |
| `_hint`: `r.resolve(mfr) ?? ''` (extra) | S4 | FAIL: `'2.6   B like '` |
| trace prints `${ids.length} of` | opened count | FAIL: `Expected: an object with length of <1> Which: has length of <0>` |
| `_candidates`: return `like` only once `likeTried[id]` is non-empty | S5 | FAIL: `Expected: ['B@3', 'B@11', 'C@30'] Which: ... is ['B@3', 'B@11'] which shorter than expected` |
| `result`: like-retry while `count < perAddr + 1` (extra) | S5 | passes. Equivalent mutant: `_canTry` already caps per-address attempts. The old S5 covers "no third B". |

The Rust controls were not run (no C compiler on this host, as the brief says).

## Process note (interference in the shared worktree)

My first attempt at the controls targeted `C:\src\Batman-advm` directly. `git status` showed `node_link.dart` and
`core.dart` already modified by another agent running its own mutants in the same tree (`hint ??= 'Y1'` in
`core.dart:370`, `?? 'Y1'` in `node_link.dart:192`). I read the file while it held that agent's mutant, and I wrote
the same content back once. That is a no-op for the other agent, but those two runs of mine are void and are not
used above. When I finished, `git status --short` in the worktree was empty. Recommendation: parallel reviewers
should run mutants on a copy, not on the shared worktree.

## Summary for the caller
- ✅ Verified: `wipe_value` soundness and coverage of every decoded path; the `opened` semantics and constructor
  compatibility; the trace carries no id; the four Dart controls (above, with output); the nc.py rename.
- ⚠️ Inferred: rustc acceptance of the NUL bytes and the Rust test result (taken from the commit; not rebuilt here).
- ❌ Not done: the Rust negative controls.
