# Review r3-B — `docs/design/329-takeover.md` v3 (branch feat/329-takeover @ 920db89, code = main 99d156a)

Reviewer B, round 3. Emphasis: UI side and callers. Read-only: source, tests, docs and the two logcats were read;
nothing was run, no device touched.

**Verdict: APPROVE-WITH-CHANGES — 0 BLOCKER, 2 MAJOR, 12 MINOR.**

Method and limits (what this review did and did not do):
- Verified against source: every `file:line` cite in §1.1–§1.3, §5 that is named below; all callers of
  `OpSession.once`, `OpenSession.open`, `NodeLink.acquire`, `setPage`; all readers of `warning` / `nodeRowWords`
  in `app/lib`, `app/test`, `app/rust`; both logcats against §0.
- Inferred only (not executed): hero / row heights, the behaviour of the new code paths (hand-traced).
- Not done: `ble_gate.dart:195, 302–309`, `prober.dart`, `owner.dart:570` cites were not re-opened this round;
  r1 / r2 review files were only grepped, not re-read in full; no test or mutation was run.

---

## MAJOR

### M1. §0 row 2 and the §1.1 cost line overclaim: the 25.7 s run had no attempt to take over, and v3 does not change it

- Scenario: node page of 04 → 「手機 Wi-Fi」 while the round has not yet started its connect (the common case right
  after the node tap cancelled an attempt to the *other* node).
- Evidence, `a2-repro-2026-11-20.logcat`, run 3:
  - 11:47:27.134 `round 31 cancelled`, `round 32 full […7d2c]`, and the attempt that was in flight is
    `attempt …5A×…880c connected=1633ms result=noResponse after 2163ms` — an attempt to **02**, not to 04.
  - 11:47:28.144 the 「手機 Wi-Fi」 tap cancels round 32; no `attempt …7d2c` was logged for round 32; the first
    connect to 7d2c is at 11:47:40.775; logged in 11:47:53.851 (25.7 s).
  - So §0's "4 of 4: the attempt in flight is cancelled" is 3 of 4 for "an attempt to this node with its connect
    started", which is the only case 1.1(b) waits for (`_link != null`, `a.id == forNode`).
- Consequence: in the worst run measured, v3 takes the unchanged path (no attempt → no wait → today's `_abort()`
  and login from the start). §1.1 "Cost" says "its remaining time plus about 0.1 s in place of 3.5–25 s"; the
  25 s end of that range is not addressed at all (not only "the 12 s gap", as "Not handled" says). D2 counts only
  taps with a logged `connect()`, so a D2 PASS would silently exclude exactly this case and the user, who is
  remote, would read "fixed".
- Also not in these files: the string `kept link` occurs 0 times in both logcats; the "about 0.1 s" figure comes
  from #366 runs. Say so in §0.
- Fix (text + criterion, no new mechanism):
  1. §0 row 2: "3 of 4 with an attempt to 04 in flight; run 3 (25.7 s) had none (the cancelled attempt was to 02)".
  2. §1.1 cost: "in place of 3.5–6.1 s (3 measured)"; "Not handled": the whole 25.7 s run is unchanged.
  3. D2: report every 「手機 Wi-Fi」 tap of the run — counted and not counted, with its time to logged-in — so the
     uncounted ones are visible; state that uncounted taps are expected to be as slow as today.

### M2. Scope item 2 (the label) has no device check with a pass criterion; D3–D6 have no negative control

- Evidence: D4 "「手機 Wi-Fi」 opened twice: time to logged in from logcat only" has no pass condition and measures
  1.1, not 1.2. The label is deferred to the on-site list because the Wi-Fi page is in `SecureScreen`
  (`settings_pages.dart:182`). But `CountryPage` is **not** inside `SecureScreen` (`settings_pages.dart:290–380`):
  its label can be UI-dumped remotely.
- Why MAJOR: one of the three agreed scope items would ship with widget tests only; the user rule is "a claimed fix
  needs a negative control" and "full validation on the real device". As written the claim is untestable remotely
  although it need not be.
- Fix:
  - D4 → "「國家」 opened, Back, opened again: a dump taken before the second read ends shows
    `<國家>（確認中…）`; after the read, the value without the mark. Negative control: the same dump on main shows
    「讀取中…」." Keep the Wi-Fi label on the on-site list.
  - D3: add the negative control (main's screenshot: yellow hero with the full sentence) and the criterion "no
    「一切正常」, no 「現在沒有需要你處理的事」 in the dump".
  - D5: negative control = today's snackbar 「另一個操作還在進行：手機 Wi-Fi」 on main (or state that it does not
    reproduce on main and why). Say what counts when the taken-over attempt fails (the gone Wi-Fi call then holds
    the lease only until it sees `gone()`, see m1).
  - D6: "a later round ends" needs a bound (for example: a `round N` end line within 120 s of the return).

---

## MINOR

### m1. A waiter whose page is gone still runs the whole `acquire` on wake

- §1.1(b) "on wake: return null if replaced or disposed; … then today's code unchanged". If the Wi-Fi page was
  closed during the wait and nobody replaced the waiter, the wake runs `core.acquireLease`, `_abort()`,
  `_dropAll()`, `reg.acquire`, and only then `OpSession.once` releases (O2). Between those lines a caller without
  `forNode` tapped after Back (「軟體更新」 `update_route.dart:28`, 「移除節點」 `more_pages.dart:84`) can lose
  `reg.acquire` and print busy with the name of a page that is no longer open; the node page's round is cancelled
  for nothing.
- Same class exists today (a gone login holds the lease), hence MINOR.
- Fix: on wake, `if (gone?.call() ?? false) return null` before the repeated `reg.current` check; O2 then covers
  only "gone between the lease and the login".

### m2. `refresh` (or the cap) while an attempt is *already detached* is not in the matrix; T14 does not cover it

- §4 row "Round cap / `refresh` … abort (not detached: only `setPage` detaches)" and T14 cover the round's own
  attempt. For an attempt detached earlier, `_pump` (`node_link.dart:900` as changed) does not abort it
  (`identical(_det, a) && wanted(a)` still holds on the node page); `core.refresh` (`core.dart:337`) starts a new
  round with the same target, nothing else starts (`:911, :928`), and the body is taken by `keptRead` into the new
  round. Benign (the user asked for a read and gets one that started a few seconds earlier), but it is a path with
  no row and no test, and it contradicts the summary line §3 "A7, B4".
- Fix: add the row and T14b: "refresh while detached: not aborted, one connect, body recorded in the new round".

### m3. Wrong cites (each checked against 99d156a)

| Design | Actual |
|---|---|
| `gate.connect`, `node_link.dart:1009` | `:1008` |
| `settings_pages.dart:334` (country changes on join) | `:326` |
| `statuspage.rs:332` | the `WARN_JOINED_CRIT` return is `:333` (condition `:332`) |
| `busyName` at `team_deps.dart:25`; §5 "through … `team_deps.dart:24`" | `team_deps.dart:24–25` builds **`OfflineDeps`**, not `OpDeps`; the only `OpDeps.busyName` is `settings_pages.dart:27` (reached via `op: opDeps(a)` at `team_deps.dart:42, 113`) |
| `member_ui.dart:186, 205` under `ui/` implied by the table | file is `app/lib/member_ui.dart` (`:186` is the field declaration; `:205` not re-checked) |

`OfflineOp` passes no `forNode`, so changing `OfflineDeps.busyName` is not needed; drop it or say why.

### m4. Interface changes not stated

- `OpDeps.acquire` is `Future<Lease?> Function(String name)` (`op_session.dart`); passing `forNode` / `gone` changes
  this typedef and every test fake that builds an `OpDeps`. Name the new signature and the fakes.
- `NodeRow` (`widgets.dart:162–205`) has `look, name, line, meta` only. "`home_page.dart` prints it as one small
  line under the row's sentence" needs a new `NodeRow` parameter; `widgets.dart` is not named and `NodeRow` is also
  used by the team / pick lists (state that they pass nothing).
- Where the `SettingsMemo` object lives ("created with the app's dependencies": `AppLink`? `UiState`?) and how the
  widget tests inject it.

### m5. "a `finally` around its body" vs "before the `_pump()`"

`_run`'s last statement is the `_pump()` that may start the next attempt. A `finally` around the body runs after
that `_pump()`. Write it as: complete `ended` explicitly before the final `_pump()`, plus the `finally` for the
exception exits (`isCompleted` checked). T17 should fail if the completion is only in the `finally`.

### m6. §0 counts for row 1

`a2-step1-2026-11-20.logcat` has a third matching tap outside the stated 12:22–12:25 window (12:21:13.529,
round 45→46, 7d2c cancelled after 736 ms, body 4.5 s later): "2 of 2" is "3 of 3 in the file". "A third tap"
with 02 in flight: there are three in the file (12:21:48, 12:22:24, 12:24:14). Left-alone attempts: 2907–4802 ms
(the design says 2.9–4.5 s; 4802 ms at 12:21:00). The two quoted lines (1696 ms, 2201 ms) and `round 55 full
[…7d2c]` are correct.

### m7. Join pages can wait

"Who does not wait … `once` whose `forNode` is not the open page's node (… join pages)". The join pages never call
`setPage` (callers: `home_page.dart:208/280/288/295/340`, `net_pages.dart:203/224`, `team_status_page.dart:62`),
so a join flow opened from node X's page for node X (`join_pages.dart:117, 721`) has `_onPage(X)` true and
**will** wait. Harmless (progress line on screen, bound 8 s) but the sentence is wrong; also `rekey_send.dart:112,
139` and `dev_pages.dart:183, 274` are `once` callers that are neither listed as waiting nor as not waiting. List
every `once` caller with "can wait: yes / no".

### m8. Hero height of the rule-14 variant vs honest-errors C4

`home_steady_test.dart` pins that the node list starts at the same y in 「正在找」 / 「還沒讀到」 / 「一切正常」
(C4, `329-honest-errors.md:145`). The variant adds an action (`seeNode` / `showList`) to a steady hero; the list
will sit lower than in the other three, and it will jump every time the node goes stale and comes back
(background → foreground). Today's yellow rule-12 hero for this state already differs, so this is not a
regression, but H7 ("no overflow") does not measure it. Either add the variant to `home_steady_test`'s states or
state that the variant is outside C4, as rule 12 is.

### m9. Tests that pin the old place: two more

- `rust/bridge/src/api/owner.rs:2792` asserts `warning == ""` in a bridge test; "a bridge test that `note` reaches
  `StatusView`" should say whether it is this one extended or a new one.
- `tests/statuspage.rs:307` (`plinks(0)` → `warning` None) needs the matching `note` None assert, else "note only
  when joined-critical" has no negative case in Rust. `:305` and `:390` are listed correctly.

Dart pins checked and **not** affected (they use a real `warning`): `home_logic_test.dart:135, 172–174`,
`retest_p_uistate_lock_test.dart:135`, `more_pages_test.dart:129`, `retest_p_layout_test.dart:54`.

### m10. Docs list: one line missing

`329-honest-errors.md:14` (F1 row: "home says 「02：節點回報異常…」") and `:34` describe the sentence on home; the
design lists `:158` and (in §5) `:29–41`. Add `:14`, or say F1's row is history. `254-app-status-page.md:28, 60,
73` and `329-app-uiux.md:682, 716, 976` are listed and correct.

### m11. Saved look and the row hint

`UiState` stores each node's last `look` (`ui_state.dart:181–185`) for the "上次讀取…，當時正常" row. With the
note the stored look of a joined-critical node stays what `nodeRowWords` gives today (unchanged function), so
nothing changes; but H4 should assert that the hint is not shown from a stored (not fresh) read after a restart,
which is the case the "fresh only" rule is for.

### m12. Extra login attempt on a silent node (T12)

Stated and asserted; accepted. Add the number to the security section (m-sec below): a device answering the
connect on a node's old address now costs one connect + up to 8 s per node-page entry *and* per sub-page opening.

---

## Checks that passed (evidence)

- Callers: `NodeLink.acquire` — `op_session.dart:94, 150`, `offline_op.dart:118`, `raw_use.dart:74, 88`,
  `dev_pages.dart:459`, `more_pages.dart:84`, `net_pages.dart:271, 342, 917`. `OpSession.once` —
  `settings_pages.dart:126, 148, 295, 340`, `dev_pages.dart:183, 274`, `more_pages.dart:258`,
  `join_pages.dart:117, 721`, `rekey_send.dart:112, 139`, `remove_pages.dart:102`. Matches the design's set except
  m7. Callers that print `reg.current?.name` directly (`more_pages.dart:87`, `net_pages.dart:277, 348, 923`,
  `dev_pages.dart:467`, `update_route.dart:34`, `raw_use.dart:75, 89`) pass no `forNode`; during a wait
  `reg.current` is null and they take today's `_abort()` path, so they never print an empty busy name because of
  the wait. Correct as designed.
- `node_link.dart`: `setPage :303`, `_pump :900, :911, :928`, `_cancel :996`, park `:1051`, `_abort :1060–1069`,
  `_onPage :639`, kept-link lend `:446–452` — as cited. `core.dart:218, 244, 258, 285–290, 603–625` — as cited;
  `keptRead` returns false with no round / target / record.
- §1.2: `drop` fits on the line before `c.setAp` (`settings_pages.dart:156`) and before `c.setCountry` (`:340`,
  the closure becomes a block). The field is filled only from the page's read (`:133`). `_cc` only from the read
  (`:300`), so the menu (`:307–314`) stays disabled on a memo. With an empty field `can` (`:178`) is false, so W5
  holds without a new rule. SSID label only inside `SecureScreen` (`:182`): true. Country page is not secure: the
  country code of a node is not a secret; acceptable.
- §1.3: joined-critical is `code == None && plinks >= 1` → `Row::Linked` / `LinkedWeak`
  (`statuspage.rs` `row_of`), so the colour is green or yellow by SNR and never from `warning`; moving the last
  branch of `warning()` to `note` gives "note only when no warning" by construction (first-match order power,
  heat, AP). Rule 14 text / tip card (`home_logic.dart:171–172`, `home_page.dart:361`), `Look.word`
  (`widgets.dart:30–36, 133`), `HomeAction.seeNode` / `showList` handling in `home_page.dart` `_act`: renderable
  with what exists. `node_page.dart:213`, `more_pages.dart:192, 211, 313`: `lineOf` drops in.
- "Nothing outside the app reads the text": grep of the repo for 「節點回報異常」 gives only `statuspage.rs:125`,
  `tests/statuspage.rs:305`, `254-app-status-page.md`, `329-honest-errors.md` and review files.

## Security (per actor)

- Nearby BLE device replaying / answering on a node's old address: gains no data and no state (nothing parked,
  recorded or shown without the Noise login); cost = delay, at most 8 s per sub-page opening plus one extra
  connect per node-page entry (m12). Bounded, stated. No fail-open.
- Compromised node: chooses between app constants only; `note` vs `warning` is decided in Rust from fields it
  already controlled. It can now hide "joined but critical" no better than before (it could always answer k2 = 1).
- Second phone (another owner / member changing the AP or country): the memo label can be stale; it is marked
  「確認中…」 / 「上次讀到」, never fills a field, never enables the menu or the send button. Verified in source
  as above. A stale 「上次讀到：<名稱>」 after a failed read is the one place a wrong value stays on screen; the
  wording says it is old. Accepted.
- Shoulder-surfer / screenshot: SSID label stays inside `SecureScreen`; no passphrase in the memo; memory only.
- Own mistakes: the main one is M1 / M2 (believing a PASS that excludes the slow case; a scope item with no device
  evidence).
- Residual of scope item 3 (accepted by the user, not reviewed): home is green with a one-line reminder while a
  node reports CRIT.

## Verdict

**APPROVE-WITH-CHANGES.** The mechanism in 1.1 / 1.2 / 1.3 holds against the source; no stuck state or security
regression found by hand-tracing. Before implementation: correct §0 / the cost line and D2's reporting (M1), give
scope item 2 a remote device check and D3–D6 negative controls and bounds (M2). The MINORs are cites, unstated
signatures, two missing matrix rows / asserts and the gone-waiter early return.
