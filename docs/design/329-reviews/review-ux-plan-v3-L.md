# Review L of `329-ux-speed-plan.md` v3 (built as a prototype)

Reviewer L, 2026-11-19. Whole document reviewed against `C:\src\Batman-b8` (read-only). Nothing in any worktree was changed except this file. No phone, emulator, node, adb, gradle or ssh was used.

Legend: ✅ verified by a run or by reading the source line; ⚠️ inferred / partly built; ❌ not done.

## 1. What was built

| Item | Where |
|---|---|
| Unchanged copy of `app/` (baseline) | `C:\Users\yello\AppData\Local\Temp\claude\ux-v3-L\base` |
| Prototype of §4.1–4.7 | `C:\Users\yello\AppData\Local\Temp\claude\ux-v3-L\app` |
| Diff base → prototype (1538 lines; 6 `lib` files, 521 changed lines; 1 existing test file; 1 new test file) | `C:\Users\yello\AppData\Local\Temp\claude\ux-v3-L\v3.diff` |
| New tests T1–T18 (35 cases) with the combined rig (real `NodeLink`, `BleGate`, `LeaseRegistry`, `SessionProber`, `HandoffProber`, `OwnerConsole`, `OpSession.once`; fake radio, fake Rust session, fake clock) | `...\ux-v3-L\app\test\nodelink\kept_link_v3_test.dart` |
| Control logs, one per control | `...\ux-v3-L\ctrl\<name>.log` |
| Suite logs | `...\ux-v3-L\base-suite.log`, `...\ux-v3-L\proto-suite2.log` |

Files changed in `lib/src`: `nodelink/core.dart` (`Outcome.keep`, `roundId`, `keptOnly`, `keptNeeds`, `keptRead`), `nodelink/ble_gate.dart` (nullable token, `up`, `pass`, 120 s timer), `nodelink/handoff.dart` (`hook`, `again`, `close({reusable})`, `destroy`), `nodelink/prober.dart` (`KeptReader`, `keepFor`, `read`, the `fresh` rule), `nodelink/node_link.dart` (states, park / lend / give back / kept read, events), `flows/owner_console.dart` (allow-list, `reusable`).

Controls are switches in the prototype (`protoOff` in `core.dart`, read from the environment variable `CTRL` by the test file), one per line the plan names. Run one with `CTRL=<name> flutter test test/nodelink/kept_link_v3_test.dart` in the prototype directory.

❌ Not built: 4.8 (A2, needs a phone), the Rust unit test of §6, `test-all.sh`, `cargo test`, the device pass.

## 2. Raw results

| Run | Result |
|---|---|
| ✅ `flutter test` in `base` | `+2080: All tests passed!` |
| ✅ `flutter test` in the prototype (with the new file) | `01:14 +2115: All tests passed!` (2080 existing + 35 new), no `[E]` line |
| ✅ `flutter analyze lib test` in the prototype | `No issues found! (ran in 39.6s)` |
| ✅ new file alone, no control | `00:00 +35: All tests passed!` |
| ⚠️ `flutter analyze` on the whole project | 115 errors in `rust_builder/cargokit`, the same in `base` (not from the prototype); only `lib test` was analysed |

**Existing tests (task 3).** No existing test failed with the prototype. The only change needed was the one the plan names: `test/flows/net_run_test.dart` `_FakeHandoff.close({bool reusable = false})`. The plan's list "tests that assert no link after a read with the real prober on `Page.node`" is empty: no existing test asserts that. The rule "no other assertion may change" holds with zero assertion changes.

## 3. Control table

"Fails" = the row's test failed with that one line switched off. Names of the failing tests are in the control's log.

| Row | Control (plan) | Switch | Row fails? |
|---|---|---|---|
| T1, T2, T4 | main | `keep` (`keepFor` always false = today's read) ⚠️ | ✅ fails (T1, T2, all five T4 cases) |
| T3 | main | `lendSlow` (slow-path handoff without the hook = today) ⚠️ | ✅ fails |
| T2 | `_dropAll` exception removed | `dropAll` | ✅ fails (and 9 other cases) |
| T4 hung answer | 5 s limit removed | `limit` | ✅ fails |
| T4 `fresh == false` | rule removed | `fresh` | ✅ fails |
| T4 new round during the read | round check removed | `roundCheck` | ✅ fails (see m3: built with radio off / on, not `refresh`) |
| T4 errorCode | — | none built ❌ | — |
| T5 ×6 | that event's line | `setPage`, `background`, `record`, `dispose` | ✅ each fails its own case |
| T6 | listener removed | `listener` | ✅ fails (both cases) |
| T7 | handler removed | `frame` | ✅ fails |
| **T8** | hook's lease check removed | `hookLease` | **does not fail**; also not with `hookLease,releaseForget` together |
| T9 | `reusable` forced true | `reusableTrue` | ✅ fails |
| T10 raw / other id | that line | `raw`, `otherId` | ✅ each fails |
| T11 read in time | wait removed | `wait` | ✅ fails |
| T11 read hangs | limit removed | `waitCap` | ✅ fails (`Actual: <4800>`, expected ≤ 1700 ms) |
| **T12 page changed / background** | hook condition removed | `hookPage` | **does not fail**; fails only with `hookPage,forget` together |
| T12 key unusable | hook condition removed | `hookKeys` | ✅ fails |
| T12 `core.blocked` (added by L) | hook condition removed | `hookBlocked` | ✅ fails |
| T13 | — | — | source check, passes |
| T14 | gate timer removed | `gateTimer` | ✅ fails |
| T15 | fast path before the checks | `fastFirst` | ✅ fails (both cases) |
| T16 | "forget" replaced by "close" | `forget` | ✅ fails |
| T17 | allow-list removed | `allowList` | ✅ fails |
| **T18** | identity check removed | `identity` | **does not fail** |

⚠️ "main" rows: the new test file does not compile on `base` (the new types do not exist there), so "fails on main" was shown with two switches that restore today's behaviour, not on the unchanged tree.

## 4. Facts F1–F13

| Fact | Result |
|---|---|
| F1 | ❌ not checked (a device measurement in a scratchpad I did not read) |
| F2, F4, F5, F6, F9, F10, F13 | ✅ lines match |
| F3 | ✅ content right; `core.dart:218` is `setPage` (the round starts further down); cleanup is `prober.dart:258-269` |
| F7 | ⚠️ content right, path wrong: the files are `app/lib/ui/…`, not under `app/lib/src/`. `team_status_page.dart:62` sets `Page.team`; app settings (`Page.other`) is `home_page.dart:340` |
| F8 | ✅ `server.go:31` `IdleAuthed = 300 s`, `:35` `Slots = 2`; `bluez.go:772-776`; `session.go:868-874` (1 s rate) |
| F11 | ⚠️ the recognition is `prober.dart:256-257`, not `:253-255` |
| F12 | ✅ `owner.rs:894`, `:949-964`; ⚠️ `:1390` is `flow_busy`; `addr_pending` is at `:353`, `:1077-1083`, `:1383` |

## 5. Findings

### BLOCKER

None.

### MAJOR

**M1. "Session lease acquired while reading → waits ≤ 1.5 s" cannot work as written: `acquire` closes the reading link before `loginFor` runs.**
Scenario: an operation ends, the round 6 s later reads on the kept link (state reading, NodeLink's token), the owner taps the next sub-page in that moment (also at every 60 s read).
Evidence: `OpSession.once` calls `acquire` first (`flows/op_session.dart:91`), `loginFor` later (`:104`). `acquire` runs `core.acquireLease`, `_dropAll()` and `gate.revoked(mine)` (`nodelink/node_link.dart:264-267`, `:664-675`); `revoked` closes every link with NodeLink's token (`ble_gate.dart:252-259`), which is the reading link. 4.6's `_dropAll` exception names only a *parked* link, so `_dropAll` also waits up to 5 s of real time for it. ✅ Built: with the plan taken literally (control `acquireReading`) T11 "read ends in time" fails: `Expected: <1> Actual: <2>` connects.
What I had to decide to make T11 pass: in `acquire` the token is set to null before `revoked`, and `_dropAll` ignores a reading link too. ⚠️ That is still not right on a real node: the status read is two writes (status, then info: `owner.rs:949-970`), and the second write is refused once the token is null or the registry's token has changed (`reg.acquire` replaces it). My fake session answers in one frame, so the test does not show this.
Smallest fix: move the wait from `loginFor` to `acquire`: for a session lease in state reading, wait for the read (≤ 1.5 s) **before** `core.acquireLease`; then parked "stays" as the table says, or the link is closed. Drop the "reading" bullet from 4.2. Or simpler still: reading + session lease = close, slow path (costs one reconnect in that moment).

**M2. Three rows' controls cannot fail (T8, T12 page / background, T18); §6 promises a failing control for every row.**
Evidence (✅ runs in §3):
- T8: after the lease is taken back, `gate.revoked(token)` has closed the link, so the hook stops at "link up"; removing the lease check, and also the forget on release, changes nothing.
- T12 page / background: `setPage` and `background()` already forget the lent link (4.5), so the hook stops at "this handoff is the current lent one"; the page / foreground conditions of the hook are reached only if the forget is also removed.
- T18: the old object's `_closed` is one-shot and a new object is made for each lending, so no old object can reach the hook's identity check.
Smallest fix: for each, either remove the redundant condition (the hook then needs: `reusable`, current lent one, link up, `keysOk()`, `core.blocked == null`) or keep it as a second guard and write the real control in §6 (T8: "link closed by `gate.revoked`"; T12 page / background: "the forget **and** the hook condition removed"; T18: "none — unreachable while `_closed` is one-shot"). A control column that says "fails" for a row that cannot fail is the thing the project's rules forbid.

### MINOR

**m1. 4.3 asks for `keysOk()` and `gate.pass(link, null)` "in one synchronous step"; `keysOk` is a `Future`** (`node_link.dart:317-324`). Built as: await `keysOk()`, then check everything else again and `pass` in one synchronous step. Say so in 4.3.

**m2. Interfaces I had to invent** (each one line in the plan would settle it):
- how `keepFor` gets set (the prober is built before NodeLink): NodeLink's constructor sets it when the prober is a `KeptReader`;
- how NodeLink's hook gets onto a handoff the `HandoffProber` made: a copy (`LoginHandoff.again(hook:)`), which is also the "new object for each lending";
- "link up": a new `GateLink.up`; whether `pass` throws or returns (throws `Refused`);
- `core.keptRead` needs a round id and "targets are exactly `{id}`, no body and no error yet" from the core (`roundId`, `keptOnly`, `keptNeeds`);
- `Outcome.keep` typed `LoginHandoff?` would make `core.dart` import a bridge type (`handoff.dart` imports the Rust API); built as `Object?`, like `extra`;
- the console's allow-list ("every request was a read") and "alive at the call": `_close` sets `_session = null` before `h.close()` (`owner_console.dart:692-693`), so `reusable` has to be computed before that line;
- "forget on lease release": done in NodeLink's `released`;
- closing in state reading: the read is cancelled first, then the session disposed (else the hint / team step may call into a disposed session; `prober.dart:253` has the same guard for `probe`).

**m3. T4 "`refresh` during the read → nothing recorded in the new round" cannot happen through `refresh`.** `core.refresh` returns when a full round is running (`core.dart:314-315`); only early rounds are cancelled, and a kept read never runs in one that follows a `notFound`. Built instead with radio off / on (`setRadio` starts a new round); its control fails. Reword the sub-case.

**m4. T2 "no 5 s wait in `acquire` (fake clock)"**: `_dropAll` waits with a real `Future.delayed` (`node_link.dart:672-674`), which a fake clock does not see. Built with a real `Stopwatch`. Reword, or inject the wait.

**m5. Leave page, small window** ⚠️ (inferred from source, not built): the re-read after a leave (`ui/more_pages.dart:271`) is a `statusPage` on the same session. If the leave is sent on a lent link less than 1 s after a kept read and the node answers inside that second, the node answers `E_RATE` (`session.go:868-874`), Rust keeps the page from before the leave with `fresh = false` (`owner.rs:953-956`), and the leave page shows it (as not fresh). Today the session is new, so this cannot happen. Fix if wanted: the console treats a `statusPage` view with `fresh == false` as no value in `reread` (then `stale: true`, today's text).

**m6. A session lease whose flow never calls `loginFor` leaves the parked link** until the gate's 120 s timer (no round runs under a lease). Fail-closed, covered by T14; one line in 4.5 would make it a stated path.

**m7. A send on a silently dead parked link** (out of range, no disconnect event yet) ends "outcome unknown" after the console's wait, where today the login fails with "not sent". Not unsafe (unknown is the honest answer); worth one line in §5 next to "a silent link".

**m8. `OpSession.once`'s `gone()` and lease-lost paths call `h.close()` without `reusable`** (`op_session.dart:109-115`): a sub-page left before its read starts destroys the kept link. Fail-closed; say it is intended.

**m9. errorCode on the kept link**: no scan and no connect for the rest of the 30 s window, and `2'` is shown only after the second round (181 s in the test). Matches 4.4; noted because the T4 text "2' shown, still parked" reads as immediate.

**m10. Over-design candidates**: the hook's lease, page and foreground conditions (M2) and `keysOk()` at give-back (the next `loginFor` checks it before lending, T15). None is harmful.

## 6. Whole-design walk

| Path | Result |
|---|---|
| open node page, sub-page read, second read | ✅ T1, T2 (1 connect, parked again) |
| send | ✅ T17 (link closed after it) |
| 60 s / 130 s on the page | ✅ T4 (same link, no scan, no connect) |
| background / leave page / record removed / dispose | ✅ T5, T16 |
| node reboot, link down, frame while parked | ✅ T6, T7 |
| lease taken back at 420 s | ✅ T8 (but see M2) |
| two flows in a row, the second during a read | M1 |
| `dispose()` while the first read is in flight | ✅ by reading: the attempt is cancelled and `_run` destroys the `keep` |
| two writers | none found: token only through `pass` from `node_link.dart` (T13); `core.keptRead` is the core's |
| leaks | none found: every `keep` is parked or destroyed; a lent handoff is parked or destroyed by the hook; the gate timer covers the rest (T14) |
| security | ✅ a parked link refuses every GATT call (T1); lending runs after the three checks (T15); the owner key is not bound to user authentication (no `setUserAuthenticationRequired` in `app/android`), so a kept session gives a person holding the unlocked phone nothing a new login would not; a frame from the node while parked is not parsed (T7) |

## 7. Verdict

**APPROVE-WITH-CHANGES.** The design can be built: 35 new tests pass and the existing 2080 pass with no assertion changed. Before implementation: fix M1 (the wait belongs in `acquire`, or drop it) and M2 (controls that can fail, or the conditions removed); the MINOR items are wording.
