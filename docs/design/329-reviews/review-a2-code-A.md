# #329 A2 code review — reviewer A

Reviewed: `git diff 99d156a..7019e1d -- app` (branch `feat/329-takeover`, HEAD 7019e1d), against `docs/design/329-takeover.md` v8 (FROZEN @ eee3ebb). Detached worktree `C:/src/Batman-a2-revA` at 7019e1d (removed at the end).

Note: `C:/src/Batman-a2` had uncommitted edits while I reviewed (`home_logic.dart` uses `fillX(...)`, `settings_pages.dart` **with the country `memo.drop` line removed**, `settings_pages.dart.orig`, test files). They look like the author's mutation runner in progress. I reviewed HEAD only. See m5.

## What I ran (all at 7019e1d)

- ✅ The brief's Dart files (takeover, op_session, settings_pages, home_logic, takeover_note, home_steady, layout): `+627: All tests passed!`
- ✅ Full Flutter suite: `01:24 +2312: All tests passed!`
- ✅ Rust in WSL (own `CARGO_TARGET_DIR`): `batman-proto --test statuspage`: `13 passed; 0 failed`. Bridge `cargo test --lib`: `98 passed; 0 failed`
- Mutations, each reverted afterwards:

| Mutation | Result |
|---|---|
| `_ended = null` without the identity guard | T17 FAIL ✅ |
| a live waiter not refused (`if (false) return null`) | T15b and O3 FAIL ✅ |
| opDeps drops `forNode`/`gone` (`a.link.acquire(name, LeaseKind.session)`) | **full suite passes (2312)** → M1 |
| opDeps drops `memo: a.memo` | **test/ui passes (1127)** → M1 |
| `(det && !_wanted(a))` removed from the park condition | test/nodelink passes (472) → m1 |
| `_det = null` removed from `_abort` | takeover_test passes → m1 |
| `finally { end(); }` removed | test/nodelink passes (472) → m1 |

- FRB: the content hash did not change (`-1473740958` in both generated files). That is correct: FRB 2.13 hashes only the function names (`flutter_rust_bridge_codegen-2.13.0/src/library/codegen/generator/wire/rust/spec_generator/misc/mod.rs:261-271`). In both codecs `note` sits right after `warning` on both sides (Dart `dco_decode_status_view` arr[5]; Rust `into_dart` / `sse_encode` / `sse_decode`), and the arr length is 15. The import reorder in `frb_generated.rs` is codegen noise.

## Real-use walk-through (checked in source, no finding unless numbered)

- **Node page opened while home's attempt to that node is mid-login.** `setPage` (node_link.dart:323–327) detaches only when the attempt is still `_attempt`, the core no longer runs it, `_link != null` and `_wanted`. `_pump` (:940) leaves it alone. At its end `_run` (:1091–1113) sends a body or error code through `core.keptRead` (core.dart:603). `keepFor` gives a keep only for a body (prober.dart:182), so an error code never parks (as the design says). `_park` runs in one synchronous step (:676), so the link is parked before any waiter resumes.
- **「手機 Wi-Fi」 tapped at once.** `OpSession.once` → opDeps → `acquire(forNode, gone)`. The wait is guarded by `ended != null`, `a.id == forNode`, `_link != null`, `_wanted` (:383–398). After the body is parked, the tail `_pump` (:1117) sees `t.body` (`keptNeeds` false, `_candidates` empty), so no new attempt. The waiter then runs today's lease path, and the parked link (gate token null) survives `_dropAll` and `revoked`.
- **Page closed during the wait** (Wi-Fi → back): `gone()` becomes true. On wake (ended or 8 s) the call returns null and nothing is cancelled. **Wi-Fi → back → 國家**: the gone waiter is replaced. On the shared `ended` the old waiter resumes first, sees `_waiter` is the new one, and returns null (T15).
- **Background / Bluetooth off during the wait**: `background()` / `radio()` → `_pump` → `_abort` completes `ended` → the waiter resumes. The page is still alive, so it takes the lease as main would have at once. The login then ends on its precondition as on main (T7b/T8b).
- **dispose during the wait**: `_dropAll` → `_abort` → wake → returns null (T11b).
- **A late end of an aborted attempt**: it returns at `!identical(_attempt, a)` (:1086) before touching `_det`. The identity guard keeps the next attempt's `_ended` (T17, negative control confirmed).
- **No-forNode call during a wait** (raw / 軟體更新): it aborts, the waiter wakes, and both race to `reg.acquire`, as two concurrent acquires do on main. I also checked whether a release (`_releasing`) can slip in during a wait: it cannot, because any other acquire aborts the attempt and wakes the waiter before it holds a lease.
- **SettingsMemo**: `SettingsView` has no passphrase field (owner.dart:575–590). The name is read only inside `SecureScreen` (settings_pages.dart:207), the country page shows only the country, and nothing is logged. The field is never prefilled from the memo, and `_cc` and `can` do not read it. `drop` sits after the page's own `notSent` check and before `setAp` / `setCountry`.
- **Note**: Rust `note()` is `warning(p).is_none() && …` (statuspage.rs:340–342), so it never comes together with a warning. Dart readers of `warning`: home rules 12 (home_logic.dart:165,168, unchanged), node page :213 and `leaveFieldsOf` (both through `lineOf`). `member_ui.StatusFields` is built only in `leaveFieldsOf`. No other Rust consumer (grep `link_verdict`: flow.rs:310 reads `.row` only).
  - A LinkedWeak (yellow) node with CRIT now gives a rule-12 hero showing the weak-link sentence instead of the CRIT text. That follows the design (rule 12 reads `warning` only), and the row hint still shows. This is a note, not a finding.

## Findings

### BLOCKER
None.

### MAJOR

**M1. The app's wiring of §1.1 (b) and §1.2 has no regression test: the full suite passes with the feature switched off in the app.**
- Scenario: `opDeps` (settings_pages.dart:26–39) is the only place that turns `OpSession.once`'s `forNode`/`gone` into NodeLink's wait, and that hands the pages `AppLink.memo`. Suppose a refactor drops the forwarding (`acquire: (name, {forNode, gone}) => a.link.acquire(name, LeaseKind.session)`) or the `memo: a.memo` line. Then on the phone the wait never happens and the label never shows on a second opening, because each page gets a fresh `SettingsMemo()` (the `OpDeps` default). That is the original symptom of §0 rows 2 and 4, back again.
- Evidence: both mutations above. Forwarding dropped → `flutter test` `+2312: All tests passed!`. Memo dropped → `test/ui` `+1127: All tests passed!`. T3 calls `nl.acquire` directly, O4 checks only the `Fx` fake's `acquire`, O3 builds its own `OpDeps`, and W1–W6 pass their own `deps`.
- Fix: one test through `opDeps(app)` itself. With the `KRig`/`app()` link mid-attempt on the node page, `opDeps(app).acquire('x', forNode: id, gone: () => false)` must wait (`link.waitingName == 'x'`). Then `identical(opDeps(app).memo, opDeps(app).memo)`, or open WifiPage twice with `deps: null` and see 「<名稱>（確認中…）」. Negative control: each mutation above must FAIL it. `busyName: () => opBusyName(...)` in opDeps is equally unpinned (O3 builds its own deps), so pin it in the same test.

### MINOR

**m1. Four defensive lines have no test that fails without them; §6 overstates this for the `finally`.**
- Lines: `finally { end(); }` (node_link.dart:1119–1120), `_det = null` in `_abort` (:1128), `(det && !_wanted(a))` in the park condition (:1107), and `_waiter = null` in `dispose` (:1155). The last is redundant with the `_disposed` check after the wake (:396), by reading.
- Evidence: the mutation table above (test/nodelink stays green for the first three).
  - For the park clause I found no path where `_wanted` turns false without a synchronous `_pump` first (`setPage` / `background` / `radio` / `setRecords` all pump, and `_pump` aborts first). So it is unreachable today, like T13.
  - The early returns that the `finally` was meant for happen only after `_abort`, which has already completed `ended`.
- §6 says: "the per-attempt completer in a `finally` … each have a test that fails without them (T6, T7b, T15, T16, T17)". No test fails without the `finally`.
- Fix: keep the lines as defence, but correct §6 and the PR text to say they are defensive and unreachable today, with no negative control. Do not claim one.

**m2. The bridge's `note` mapping is not pinned for a non-empty note.**
- Evidence: owner.rs:2582 `note: v.note.unwrap_or("").into()`. The only bridge assertion (:2795) is for a state without a note; the Dart tests use a mocked `StatusView`. ⚠️ Inferred from reading, mutation not run.
- Fix: in `member_tests`, one `status_view_of` on a JOINED, plinks 1, k2 = 2 status, asserting `(warning, note) == ("", NOTE_JOINED_CRIT)`.

**m3. During the wait, the node page's software-update hint is not carried** (an answer taken over is not given to the hint step). This is stated in §1.1 "Not handled", so no fix is asked. Listed so the PR's "what this does not do" keeps it.

**m4. `waitingName` can name a waiter whose page is already gone, until it wakes.**
- When: `reg.acquire` returns null with `reg.current` null at the moment `busyName()` is read. That window exists on main too (where it printed '').
- Fix: none needed. Optionally use `w.gone() ? null : w.name` in `waitingName`.

**m5. Process: the author's worktree is not at HEAD.**
- `C:/src/Batman-a2` has uncommitted edits, among them `settings_pages.dart` **without** the country set's `_d.memo.drop(widget.id)`, plus a stray `settings_pages.dart.orig` and a different `home_logic.dart` (`fillX`).
- If this is a mutation run, restore it before any commit (`git status` clean, `.orig` deleted) and re-run the suite on the committed tree. If it is intended work, the dropped `memo.drop` contradicts §1.2 and needs W4's country "answer lost" case. I saw a Wi-Fi case only (settings_pages_test.dart:483); I did not check a country one.

## Verdict

**APPROVE-WITH-CHANGES.** The NodeLink takeover, waiter and memo logic match the frozen design. Every concurrency path I traced (late end of an aborted attempt, second call, gone and replaced waiter, dispose, background, Bluetooth off, a no-forNode call during a wait) behaves as specified, and the named negative controls I re-ran (T17, T15b/O3) fail as claimed. Before the PR: M1 (a test through `opDeps` that fails when the forwarding or the memo wiring is dropped), and the §6 / PR wording in m1. m2 is cheap and recommended. m5 must be clean before commit.
