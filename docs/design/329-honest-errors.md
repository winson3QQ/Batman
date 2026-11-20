# #329 A1 — honest error messages (design v3.1, frozen)

Base: main 5999dae. App only (Dart + the Rust text table). No node change, no protocol change, no harness change.

Scope rule: every item changes what the app **says** (or where it draws it) from facts the app already has. No new
state is stored, no new request is sent, no timing changes. Ownership / contracts / lifecycle: nothing shared is
touched (no file, flag, record, link rule or node resource), so §1–3 of the review rules reduce to this sentence;
§4 (evidence) and §5 (security) are below.

## 1. Facts (checked 2026-11-20, phone S20 + nodes 04 / 02, wsl.32)

| # | Item (#329 line) | Reproduced | Evidence |
|---|---|---|---|
| F1 | 229: home says 「02：節點回報異常（可能是手機 Wi-Fi 還沒設定）— 設好仍然如此請找維修人員」 while 02's row is green 「已連上隊伍網路」 | ✅ device | screenshot `a1-home1.png` 10:32; on 02 `halow-status`: `HEALTH [CRIT] NOT WORKING — on-air blocked by keyguard — set the mesh/AP key`, `wireless.default_radio0.disabled='1'`, join `JOINED … plinks=1 batman=1`, `reason_code:1`. So the only cause here is the phone Wi-Fi (AP) key not set. |
| F2 | same: status cannot tell this cause from another CRIT | ✅ source | node sends key 5 (reason code) only when not JOINED (`feed/batman-prov/src/node/status.go:201-207`); key 2 is the level only. `statuspage.rs:314-336` therefore guesses. |
| F3 | 233: the status area changes height after the read; the rows below move | ✅ device | `a1-wake1.png` (before the read): 「我的節點」 at y≈735, 「新增節點」 at y≈1490; `a1-home1.png` (after): y≈1070 and y≈1815 (900-px-wide image). `StatusHero` (`widgets.dart:94-141`) has no minimum height; time row and button appear after the read. |
| F4 | 232: a login that connected but got no answer says 「60 秒內沒有找到這台節點」 | ⚠️ source + old device log (not re-triggered today: needs a silent node = a node action) | `_lfAttempt` returns `Res.noResponse` for link-not-up, no msg2, refused, exception (`node_link.dart:546-589`); `LoginFor.tick` ends everything as `notFound` (`core.dart:914-919`); `loginLine` prints one text (`net_run.dart:50-56`). Device log in #329 line 232: `noResponse` with `connected=…ms`. A unit test on the rig reproduces it (to be written first, as the negative control). |
| F5 | 232, second half 「old address stuck → look again with a new address」 | already done | `core.dart:907-909`: two silences on the known address drop its memo; baseline, not changed. |
| F6 | 228: a reverted update always says 「這個更新檔不要再重試，請找維修人員」 | ⚠️ source (an OTA is not run for this) | node answers phase 6 with reason 18 or none (`swupd.rs:1085-1086`); the node's reason text (`TRIAL-REVERTED … mesh not joined/reachable (0/3 samples…)`, `batman-autocommit:539`) is only in the node's log and is not in `update-progress` (CDDL `219-protocol.cddl:350-357`). The app cannot know why. |
| F7 | 260: 「設定 SSH 金鑰」 with ≥ 1 line sends at once; only the 0-line case asks | ✅ source + test | `dev_pages.dart:130-147` (dialog only when empty), `:153`; `pr6_dev_test.dart:180-199`. The node replaces the lines it added before (`node.go:839-880`). The app cannot read the installed keys (no verb). |
| F8 | Bluetooth off: login waits 60 s | ❌ not a bug in source: `poweredOff` / `unauthorized` end a login at once (`core.dart:347-363`, `login_for_test.dart:163`). | Device check needs a phone setting change → on-site list. `unknown` / `locationServicesDisabled` do not block (`app_link.dart:253-258`): not reproduced, **not changed here**. |

## 2. Changes

v3.1. Rounds 1–3 are in `docs/design/329-reviews/review-honest-errors-r1.md` / `-r2.md` / `-r3.md`. Round 3: both
APPROVE-WITH-CHANGES, one MAJOR (C1, one clause), applied here; frozen. Every sentence below is narrowed to what is true in
every state where it is shown.

### C1 (229) — the joined-but-CRIT warning keeps its neutral lead and adds what to do
JOINED + CRIT also comes from a critical battery, a core service down, or the mesh key (`halow-status:72-91`); the
neutral lead was a reviewed decision (`254-app-status-page.md` T4). So only the action is added. `WARN_JOINED_CRIT`
(`statuspage.rs:125`):

> 節點回報異常，可能是手機 Wi-Fi 還沒設定 — 還沒設定的話，請到這台節點的「手機 Wi-Fi」設定；已設好仍然如此請找維修人員

The action is conditional: with the phone Wi-Fi already set (battery or service CRIT) the user must not be sent to
set it again (that drops the phones on it).

Condition unchanged. Update `tests/statuspage.rs:305` and `254-app-status-page.md:28` and `:73`. No generated bridge
file holds the string. The contradiction with the green row stays (the app cannot know the cause, F2) until the node
sends the reason (§5). On home the text is in the title (`home_logic.dart:158`), so the F1 state gets taller.

### C2 (232) — two endings instead of one
`LoginFor` (one per login, `core.dart:781`) gets one set, `near`, changed only in `result()`:

- `Res.refusedOther`, `Res.broken`: the address is added, always (the driver gives these only after the node's
  certificate checked, `core.dart:37-40`).
- `Res.noResponse`: the address is added when, before this result changes any memo, `c.isY[a] == id` or
  `like[a] == id`.
- `Res.undecryptable`, `Res.certRejected`: the address is removed.

`LoginFor.found` = `near` is not empty. `LoginForResult` becomes `(this.end, [this.handoff, this.found = false])`
(a second optional positional; the callers and test fakes that pass `handoff` compile unchanged); `_loginFor` sets it
only on `notFound`. `OpReply` gets a named `found`. `NetRun` / `CheckRun` / `opLine` pass it to
`loginLine(end, found: …)`, which reads it only for `notFound`:

- not found: unchanged 「60 秒內沒有找到這台節點。請確認節點開著、靠近手機，再試一次。」
- found: 「附近有像是這台節點的裝置，但沒有連上，或登入沒有完成。請靠近一點，稍等再試一次（可能另一支手機正在連它）；一直如此，把手機的藍牙關掉再打開，還是不行請找維修人員。」

The line does not tell the user to reboot the node: a node that answers "busy" (`refusedOther`) may be serving
another phone. No change to which address is tried, when, or for how long; nothing new from `_lfAttempt`.
Known limits: (a) a node with no memo and no hint (older firmware) that stays silent still reads 「沒有找到」;
(b) `like` is an unauthenticated advertisement hint (§3); (c) while another link keeps the gate busy for the whole
60 s no address is tried (`node_link.dart:482`) and the line is 「沒有找到」; (d) a reflashed node at its old address
(`undecryptable`) reads 「沒有找到」, as today; (e) the hint of an address is read when its result comes: an address
that was silent while it looked like this node stays counted when its hint later names another node, and one picked
for its hint whose hint is gone when the result comes is not counted (code review B-5; wording only);
(f) the update page drops the login reason (`update_route.dart:45`, as before), so it does not show this line.
Where a page puts a failed read's reason in brackets (`settings_pages.dart`, phone Wi-Fi and country), this line,
which has brackets of its own, follows a full stop instead (`readFailLine`; code review A-6).

### C3 (228) — the reverted update text stops claiming the file is bad
`swNext` (`swupdate.dart:94-95`) gives one line for two node answers; they are split by the text it already tests:

- 「退回」 (phase 6, the node's health check reverted): 「節點仍是原本的版本，可以照常使用。常見原因是重開後連不上其他節點：這台若已加入隊伍網路，請先確認其他節點開著、連得上。可以再更新一次；再退回的話，這個更新檔不要再試，請找維修人員。」
  (revert causes `batman-autocommit:451-554`; the mesh is needed only in a network, `NEED_MESH` `:409-421`).
- 「回到原本的版本」 (reason 18: rebooted, no verdict from the health check, `updwork.go:899-908`):
  「節點仍是原本的版本，可以照常使用。可以再更新一次；再不行請找維修人員。」

The same file can be sent again: `bad-slot` is read only for a boot without a trial (`batman-autocommit:362`), phase
6 offers the file picker when the page is opened again (`swupd.rs:945-948`), the node refuses only a downgrade
(`feed/batman-prov/src/release/release.go:411`). Limit: the line shows only on the result screen of the run
(`SwKind.done`), as today; `swRevertedNext` becomes two constants. A text starting 「更新完成」 never gets either
line (its version string is the node's; as `swHero`, code review B-6).

### C4 (233) — home: the status area keeps its height between "not read yet", "looking" and "all normal"
Opt-in `StatusHero(steady: true)`, set only at `home_page.dart:346`; every other user is untouched. With `steady`:
the `next` slot takes at least two lines of its text style (with the current text scaler) also when `next` is null,
and the time / refresh row always takes the height of its button (48, `widgets.dart:133`) also when there is no time
and no button (busy). The title also takes at least two lines of its style: at 360 dp 「還沒讀到節點 XXXX 的狀態」
is two lines where 「一切正常，可以使用」 is one (found while implementing; v3 had it).

Cost, stated: the normal state is one title line (about 32 dp) taller than today; the home states without a `next`
line (not read yet, the warnings) about 60 dp taller, plus the title line when their title is one line.
Found by the C4 test while implementing (2026-11-20): at text scale 1.3 and 360 dp the "not read yet" title is three
lines, so that one state is one title line (42 dp) lower than the other two; equal at 1.0 (at 2.0 the two differ by
77 dp, code review B-8). Three kept lines would
cost every state another line, not taken. The kept height is two laid-out lines of the style, not a computed number
(a laid-out line is rounded: 2 x 25.6 is 52, which left a 0.8 dp step).
Limits, stated: a title or `next` longer than that (several nodes named, long node names, 「附近有還沒認出來的裝置…」,
text scale above 1.3), a warning (F1: long title and a button), the tech fold, the first-run tip card and
「看全隊狀態」 still add height. The F3 screenshots (home in the F1 state) will still move.
The node page is not changed: reserving there would add blank for good, and what moves is content (membership, hint,
network cards) → §5.

### C5 (260) — setting SSH keys asks first
With ≥ 1 line, before sending, a dialog:

> 設定 SSH 金鑰？
> (`sshReplaceNote`, the text already on the page, with its exception: a key that was on the node before and was
> also sent by the app is removed by any later replacement)
> 這次送出 N 把：(the fingerprints of the N lines)

The content scrolls (8 fingerprints at text scale 1.3); the dialog text and the 「設定」 button have keys.

Buttons: 「設定」 / 取消. Cancel sends nothing. The lines sent are the ones captured before the dialog; the existing
`mounted` check after a dialog is kept. The 0-line dialog is unchanged.

## 3. Security
No new request, privilege or secret. C5 shows fingerprints already on the page (public).
C2: the `found` line can be caused by an unauthenticated advertisement (a `like` hint) or by a device at an
address that holds a 「是 Y」 memo and stays silent; so the line says 「像是這台節點的裝置」, not 「找到了這台節點」. Actor in Bluetooth range
replaying the node's advertisement: today the user reads 「沒有找到」; after, 「附近有像是…沒有連上」 with the advice to
come closer, wait, toggle Bluetooth, then call maintenance. No state changes, no memo is written from the hint
(`core.dart:39-40` unchanged), a failure never becomes a success, `found` is read only with `notFound`. The same
actor can already keep the login from succeeding by jamming.
Compromised node: it can already answer `refusedOther` forever; it now gets the `found` line, which is true.
C1: the action is conditional so that the text cannot send a user to re-set a working phone Wi-Fi.

## 4. Tests
Fail without the change (negative controls):
- C1: Rust `tests/statuspage.rs` literal of the new text (condition tests unchanged; the existing negative control
  against 「可在「手機 Wi-Fi」設定」 at `:306` stays).
- C2 core (`login_for_test`): (b) a 「像 Y」 address, every connect fails → found; (c) a known 「是 Y」 address, no
  msg2, memo dropped after two silences → found; (f) an unknown address with no hint answering `refusedOther` until
  60 s → found.
- C2 up the stack: `op_session_test` (OpReply carries `found`), `net_run_test` (NetRun and CheckRun), and the pages
  (`settings_pages_test`, `more_pages_test`) with a fake returning `found: true` → the new line as `opLine` shows it,
  the old line absent.
- C3: `retest_s_boards_test`: phase 6 → the literal 「常見原因是重開後連不上其他節點」 (`:23` import and `:344`
  constant-equals replaced). Reason 18 → `swupdate_test` (`swNext` on the node's text → the literal
  「可以再更新一次；再不行請找維修人員」 and not the mesh sentence); not a board: a new board needs a contrast exception
  for the Windows rasterizer. The words `swNext` matches on are pinned in Rust `tests/swupd.rs` beside the texts.
- C4: widget test at 360 dp wide, text scale 1.0 and 1.3, one node with a short name: the y of 「我的節點」 is equal
  (`closeTo`) in 「還沒讀到」, 「正在找你的節點」 and 「一切正常」 (tip already seen). Fails today.
- C5 (`pr6_dev_test`): ≥ 1 line → the dialog shows `sshReplaceNote` and exactly the fingerprints of the lines;
  cancel sends nothing; confirm sends those lines once. The three existing taps that send ≥ 1 line (`:173`, `:196`,
  `:331`) go through the dialog.

Guards against counting too much (pass today; each has a mutation that makes it fail, run and listed in the PR):
(a) nothing seen → not found; (d) only an unknown silent device → not found [mutation: count every `noResponse`];
(e) a 「像 Y」 address answering `undecryptable` → not found, and (g) a known address: `noResponse`, then
`undecryptable` → not found [mutation: no removal]. New with the parameter: (h) `found: true` with `refused` /
`identity` / `precondition` → their own texts unchanged [mutation: `loginLine` reads `found` first].
The whole suite is run and reported in the PR (the home size matrices in `layout_test` / `retest_p_layout_test`
meet C4).

Device (S20, `install -r`): C1 text on home (02 is in the F1 state). C4: home cannot show 「一切正常」 while 02 is in
the F1 state → unit test only, device check on the on-site list. C2 / C3 / C5 are not triggered on the device (a
silent node, an OTA, sending SSH keys): unit tests only.

## 5. Not in this change (one line each, into #329)
- The node tells the reason when JOINED-but-CRIT and the revert reason of an update (node change, with the next
  firmware change) — then C1 names the cause (and the green/yellow contradiction goes) and C3 names the cause.
- `locationServicesDisabled` / `unknown` Bluetooth states during a login (F8): on-site check first.
- Claim `_find` (older page) 60 s with Bluetooth off: older page, replaced by the new add flow.
- Home in a warning state, and the node page (membership / hint / network cards), still move after the read.
