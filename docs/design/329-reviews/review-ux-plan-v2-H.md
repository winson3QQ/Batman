# Review H — `329-ux-speed-plan.md` v2（可實作性 / 併發）

審查者：H（獨立；實際做了原型）。日期 2026-11-18。
範圍：整份 v2。已審過的基準（lease registry、one-link gate、prober、core scheduler）不重審，只看 §3 改到的與計畫會悄悄弄壞的。
限制：沒有碰手機、模擬器、節點；沒有 adb / ssh。worktree 只新增這一個檔。

## 結論

**APPROVE-WITH-CHANGES**（0 BLOCKER、6 MAJOR、7 MINOR）。

方向可行：照 §4 做出的最小原型讓 T1/T2/T3/T5 通過，既有 2080 個測試沒有一個行為回歸。但計畫「照字面」做不出來 —— 4.1.1 與 4.4 缺少介面、4.4 不是可選項、Rust session 的殘留狀態與「借出中不可 dispose」沒寫。MAJOR 還開著，依規則 v3 要整份再審一次。

---

## 1. 原型結果

環境：Flutter 可跑（`/c/src/flutter/bin/flutter`）。兩份副本都在 worktree 外：

- `C:\Users\yello\AppData\Local\Temp\claude\ux-v2-H\app` = 原型
- `C:\Users\yello\AppData\Local\Temp\claude\ux-v2-H\base` = 未修改 + 只加新測試檔與 base shim
- 補丁腳本 `...\ux-v2-H\patch_nl.py`，測試 `...\ux-v2-H\t\kept_link_test.dart`

### ✅ 驗過（附原始輸出）

基準（base，加新測試前）`flutter test test/nodelink test/flows`：

```
+464: All tests passed!
```

原型整套 `flutter test`（含新測試）：

```
01:05 +2090: All tests passed!
```

原型 `flutter test test/nodelink/kept_link_test.dart`：

```
00:00 +1: T2: T1, then OpSession.once on that node -> connect count stays 1, answered, parked again
00:00 +2: T3: no kept link; two OpSession.once in a row on the open node page -> 1 connect
00:00 +3: T2b: no kept reader (4.4 absent): the round 6 s after the op closes the parked link and connects again
00:00 +4: T4: kept reader: the rounds (6 s after the op, then every 60 s) read on the kept link, no scan, no connect
00:00 +5..+9: T5 ×5 (setPage home / other / node 另一個 id / background / record removed)
00:00 +10: All tests passed!
```

負向對照（同一個測試檔在 base）：

```
T1 [E]  Expected: <1>  Actual: <0>     B2: the read of the open node page keeps its link
T2 [E]  Expected: <1>  Actual: <2>     no second connect: the kept link was lent      (kept_link_test.dart:191)
T3 [E]  Expected: <1>  Actual: <2>                                                     (kept_link_test.dart:206)
00:00 +0 ~7 -3: Some tests failed.     (T2b/T4/T5 在 base 為 skip：base 沒有這些 API)
```

T1–T3 在未修改的程式上失敗、在原型上通過 → 負向對照成立。

### ⚠️ 只做到模擬 / 部分

- **4.1.1 與 4.4 沒有接到真的 `SessionProber`**。原型只在 NodeLink 側加了載體（`Outcome.keep`）與介面（`KeptReader`），用假 prober 驅動。真的 prober 仍然 dispose 自己的 session（`prober.dart:255-268`）。所以「既有測試全過」不代表 §3 的 B2/B3 改完後還全過 —— 斷言「讀完後 `gate.links == 0`」的既有測試，等真 prober 留住 session 才會被碰到，**哪幾條會變我沒測出來**。
- T4 用的是假 `KeptReader`（直接回 `Res.body`），沒有驗 `owner.rs` 在既有 session 上再讀一次狀態的行為（見 M5）。
- 4.3 的「console 關閉 → 停回」只驗了乾淨結束；`_chain` 逾時、`_answer` 未決的分支沒寫測試。

### ❌ 沒做

- T6–T13；真機；第二支手機；撤銷（420 s）時借出中的測試（只讀碼 + 原型採「只忘記不 dispose」）。
- base 的整套 2080 個沒跑（只跑了 nodelink + flows 的 464）。

### 照字面能做 / 不能做

| 段 | 結果 |
|---|---|
| 4.2 `loginFor` 快路徑、4.3 `close({reusable})` hook、4.5 關閉條件、`BleGate.pass` | 能做，但要補 m1/m2/M4/M6 的細節 |
| 4.1.1 讀取留住 session | **不能照字面做**（M1） |
| 4.4 `core.keptRead` | **不能照字面做**（M2），而且不是可選（M3） |
| §6「用既有的 `Rig` / `Fx`」寫 T2/T3 | **不能**（m5） |

### 既有測試的破壞

| 位置 | 原因 | 性質 |
|---|---|---|
| `app/test/flows/net_run_test.dart:148` `_FakeHandoff.close()` | `LoginHandoff.close` 多了 `{reusable}`，override 簽章不符，**編譯失敗**（整個 flows 目錄載不起來） | 預期的介面變更，不是回歸；修法＝加 `{bool reusable = false}` |
| `implements GateLink` 的假件（`test/flows/retest_p_console_close_test.dart:15`、`test/ui/join_pages_test.dart:146`） | `token` 改可空、加 `up` getter 後仍可編譯並通過 | 無破壞 |
| 其餘 2080 個 | 全過 | 見上面 ⚠️：真 prober 未改，B2/B3 的基準變更還沒被碰到 |

---

## 2. Findings

### MAJOR

**M1 — 4.1.1 沒有載體：prober 無法把 session 交給 NodeLink。**
- 情境：節點頁的讀取要「留住 session」。
- 證據：`node_link.dart:39-41` `Prober.probe` 只回 `Outcome`；`prober.dart:175` `Outcome(Res.body, v.color, v)` 的 `extra` 已被 `StatusView` 佔用；`prober.dart:255-268` 收尾一律 dispose；取消路徑 `prober.dart:131` 也回 `read`。prober 不知道現在開的是哪一頁，誰決定「留」沒寫。
- 修法：計畫要寫明（a）`Outcome` 加一欄（原型用 `keep`）或改 `Prober` 介面；（b）由 NodeLink 決定留不留（prober 一律交出，NodeLink 不留就 `destroy`）；（c）取消 / 過期的 outcome 帶著 session 回來時必須銷毀；（d）哪些既有測試的 `links == 0` 斷言因此改變，逐條列在 §3。

**M2 — 4.4 需要一個計畫沒有的 prober 入口，且 `_pump` 順序要改。**
- 證據：`node_link.dart:531-533` `_pump` 一有 round 就先開 scan，connect 還要 `gate.links == 0`（`:352`）；`ble_gate.dart:239-242` 有 link 時拒絕 connect。「在既有 session 上讀一次狀態」（含 `_afterRead` 的 hint / team、`node_link.dart:639-649` 的 `readWall` / `teams` 記帳）現在沒有函式。逾時值沒寫（必須 < 30 s 的 round window；原型用 20 s）。「reading」期間 `acquire` 怎麼辦只有一句。
- 修法：寫出介面（原型：`KeptReader.read(h, cancelled)`）、逾時值、`_pump` 的新分支（kept 忙時不 scan、不 connect）、round 的 targets 不只這一台時怎麼辦（原型：關掉 kept，走原路）、讀完的記帳由誰做。

**M3 — 4.4 不是「有空再做」：沒有它，kept link 最多活 6 秒。**
- 情境：操作結束 → lease 放掉 → `afterLease` 6 s 後一定有 round（之後每 60 s）→ round 要 connect → 一條 link 的規則逼它先關掉 parked link。
- 證據：原型 T2b（✅ 通過）：沒有 kept reader 時 trace 剛好一條 `kept link closed: round`，`connects` 從 1 變 2。有 reader 的 T4：130 s 內 `connects` 維持 1、scan 次數不變。
- 修法：4.4 列為必做，T4 列為必過；或明寫「沒有 4.4 就不出」。

**M4 — 借出中遇到撤銷 / 關閉條件：只能忘記，不能 dispose。**
- 情境：console 持有 link（lent），420 s 撤銷、或頁面切走、或背景。計畫 4.2「否則先關掉 kept link」與 4.5 的清單沒有排除 lent 狀態。
- 證據：console 還在用同一個 Rust `OwnerSession`（`owner_console.dart:675-693` 的 `_close` 之後才還）；NodeLink 此時 dispose = 正在跑的 console 用到已釋放的 session。
- 修法：寫明狀態表 —— lent 時 NodeLink 對 4.5 的每個條件都只「忘記」（清自己的指標與計時器），由持有者關；hook 回來時發現不是自己的就 `destroy`。原型這樣做，T5 通過。補一個測試：lent 中 `setPage(home)` → session 未 dispose、console 結束後 link 關閉、不停回。

**M5 — console 用過的 Rust session 帶著殘留狀態回到 prober。**
- 情境：console 做了 leave → session 停回 → 下一輪 kept read 在同一個 session 上讀狀態。
- 證據：`app/rust/bridge/src/api/owner.rs` `after_left`（:345 附近，leave 成功時設，下一次狀態頁回答時 `page_cut_once = take(after_left)`）→ 那次讀取被切一次；`page_status` / `page_info` / `page_fresh` / `page_rate` 都留在 session 上，E_RATE 回答會把先前的讀取當 RATE_NOTE 顯示，與今天「每次新 session」的行為不同；`addr_pending` 同理。計畫 §4.3 的 `reusable` 條件只看 `alive && _answer == null`。
- 修法：寫一條規則並測試 —— 最小的做法：console 做過任何會改節點狀態的動作（leave / join / make / remove）就 `reusable: false`；只有唯讀動作才停回。或列出每個殘留欄位並說明為何無害（附 `owner.rs` 行號）。

**M6 — 4.2「立刻回傳」會跳過 `keysOk` 與 `core.blocked`。**
- 證據：`node_link.dart:317-326` 在 login 前檢查 key 能力與 blocked（設計 §4.1「每次 login 前」）。快路徑若放在這之前，key 被撤 / 藍牙關掉時仍把舊 session 借出去。4.5 的關閉清單也沒有這兩項。
- 修法：快路徑放在這兩個檢查之後（原型如此）；`keysOk == false` 與藍牙關閉列入 4.5。這是安全性項目（fail-secure）：加負向測試「keysOk 變 false → loginFor 不借、kept link 被關」。

### MINOR

**m1 — `LoginHandoff` 是一次性的。** `handoff.dart:74-92` `_closed` 設了就不能再用；「kept link = 一個 LoginHandoff」做不到再借出。原型每次借出新建一個 handoff 包同一組 link / inbox / session / sub。計畫寫明其一。

**m2 — `BleGate` 要改的比計畫寫的多。** `ble_gate.dart:62` `final Token token` → 可空且可換；`:86-88` `_usable` 要拒絕 null token（這正是 parked 時 GATT 被擋的機制，T1 有驗）；`_down` 是私有的，NodeLink 需要公開的 `up`。`node_link.dart:664-675` `_dropAll` 在 `gate.links > 0` 時用真的 `Future.delayed` 等 100 ms × 50 —— 不扣掉 parked link，每次 `acquire` 白等 5 秒真實時間。

**m3 — kept read 進行中被 `acquire`：切掉 vs 等。** 計畫是切掉走慢路徑。kept read 剛好發生在每次操作後約 6 s，第二次點擊很容易撞上，撞上就是今天的慢路徑。較小的替代：等這次短讀取（有界）再借。至少加一條測試量這個視窗。

**m4 — listener 順序。** gate 的 `released` 監聽先於 NodeLink：`revoked(l.token)` 不會動 token 為 null 的 parked link（原型 T2 通過即證）。但這依賴註冊順序，計畫應寫成契約並加斷言。

**m5 — §6 說用既有假件，但 `Fx` 沒有 NodeLink。** `test/flows/op_session_test.dart:29-65`：`login` 回預先做好的 `rigs[n].h`，每個 `Rig` 自己一套 radio / gate（`owner_console_test.dart:136`，`late final`）。T2/T3 需要新的合併 rig（原型的 `KRig`，約 100 行）。估工時要算進去。

**m6 — 240 s 的 parked 上限是多的。** 60 s 的 round（4.4）+ 節點端 `IdleAuthed = 300 s`（`feed/batman-prov/src/provd/server.go:25-40`）+ link 斷線即關，已經涵蓋。依「只做必要修改」建議拿掉；若留，T8/T9 寫「今天就會過（guard）」＝沒有負向對照。

**m7 — 產品成本要使用者決定，計畫只當技術事實。** 節點頁開著時：節點對其他手機不可見（`feed/batman-prov/src/cmd/batman-provd/bluez.go:772-776`，有 link 就撤廣播）、佔 2 個 slot 中的 1 個（`server.go` `Slots = 2`）；螢幕常亮時無限期。第二支手機的情境沒有測試。計畫引用 `server.go` / `bluez.go` 沒寫目錄。

---

## 3. 事實查核 F1–F10

| | 結果 | 備註 |
|---|---|---|
| F1 | ⚠️ | 只引用 scratchpad 的 log，無法查證 |
| F2 | ✅ | |
| F3 | ✅ | |
| F4 | ✅ | `ble_gate.dart:239-242` |
| F5 | ✅ | |
| F6 | ✅ | |
| F7 | ✅ | `setPage(`：`home_page.dart:208,280,288,295,340`；`net_pages.dart:203,224`；`team_status_page.dart:62` |
| F8 | ✅ | `provd/server.go:25-40`（`IdleAuthed` 300 s、`Slots` 2）；`cmd/batman-provd/bluez.go:408-420,772-776` |
| F9 | ✅ | |
| F10 | ✅ | |

## 4. 併發逐項

| 競爭 | 結果 |
|---|---|
| kept read 中 acquire | ⚠️ 原型：切掉走慢路徑，沒寫專門測試（m3） |
| `released()` 監聽順序 | ✅ T2（m4：要寫成契約） |
| console close → park → release | ✅ T2：lease 放掉後仍 parked、`reg.current == null` |
| 420 s 撤銷時借出中 | ⚠️ 讀碼 + 原型只忘記；無測試（M4） |
| release 後的 `_pump` | ✅ T2b / T4 |
| 借出中進背景 | ⚠️ 原型只忘記；無測試（M4） |
| 借出中斷線 | ⚠️ 原型交給持有者；無測試 |
| 連點兩下 | ✅ 第二次 `acquire` 被 lease 擋（基準行為，未變） |

## 5. 安全

- 遠端 / 第二支手機：沒有新的輸入面。新增的是可用性成本（m7）。
- 本機非特權程序：無新檔案、無新 IPC。
- 自己的錯誤：M4（use-after-dispose）、M6（跳過 key 檢查）、M5（狀態殘留造成錯誤顯示）是實際風險，都要負向測試。
- parked 時 token 為 null → 任何 GATT 被 gate 拒絕（T1 ✅）。parked 期間收到任何 frame / error 即關（原型如此，計畫應寫明）。

## 6. 只做必要的修改

- 可拿掉：240 s 上限（m6）。
- 不能拿掉：4.4（M3）。
- 節點端不用改，維持 app-only ✅。
