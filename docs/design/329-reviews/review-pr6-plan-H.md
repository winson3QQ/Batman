# #329 PR 6 計畫 v4 — 第四輪獨立審查 H

審查對象：`docs/design/329-pr6-plan.md` v4（worktree C:/src/Batman-329pr6，main c4905ed）。整份審，不只看 v3→v4 的差異。基準（設計 v12.1、PR 1–5、#349）不重審。
依據：原始碼與設計逐條自己對過（file:line 都是本輪實際讀到的）；設計畫布（artifact 8c2uwdGfQtZdz9MQLcnckv）的 6.1–6.3 畫板**沒有看**（⚠️），全隊頁版面只對照 §5.6 文字與 254-app-team-status v2.4。

## 前幾輪 MAJOR 是否解掉

| 前輪 | 狀態 | 說明 |
|---|---|---|
| A-M1 / B-M3 / C-M4 國家 | ✅ | D11 的三種來源與 Revert（join2flow.rs:8-15、:482-484）屬實；settings_pages.dart:32 的 askCountry 恆 false 也對得上 |
| A-M2 / B-M1 / C-M1 / C-M2 / E-M1 代碼與英文 | ✅（方法改了） | U+001F 分隔字元 + 字面量掃描取代括號解析；節點字串經 `shown`→`display_name`（statuspage.rs:188）會濾掉控制字元，所以節點注入不了分隔字元 |
| A-M4 重試半套 AppLink | ✅ | D1 不加重試 |
| A-M6 / C-M3 / D-M1 全隊頁存在、N+1 一行打開 | ✅ | `team_enabled()` 注入、不經 `wanted`、`Page.team` |
| E-M2 / F-M2 / F-M3 全隊資料契約 | ⚠️ 一半 | 分組鍵、移除後晚到、cancel 已寫；**新鮮度借用 status 的 `core.fresh` 有洞（本輪 MAJOR-1）**；「netId 空 → 清掉」「紀錄打不開 → 不更新」偏離 254 已審的狀態（本輪 MAJOR-2）；後四碼偏離已列 |
| E-M3 prober 預算 | ✅ | 同一 2 s、同一 `openNet`、每個 await 後檢查 `stop()`（prober.dart:160-166、:252-273 的既有模式） |
| D-M2 文字紀錄遮罩 | ✅ | `NodeLink.mask`（node_link.dart:78-80） |
| D-M3 / F-M4 孤兒加入項目 | ✅ | D4a 帶回 `forgetNotice(offerExclude)` 與排除入口 |
| F-M1 被刪測試 | ⚠️ | 作法（實作時 `git grep` 逐條對照）可行；已知清單漏一個安全回歸測試（MINOR-4） |
| D-M4 / F-M5 R-7 | ⚠️ | 時機、OTA 不重開、拔電、結束狀態都寫了；但 02 的起點狀態寫錯（本輪 MAJOR-3） |

## BLOCKER

無。

## MAJOR

### MAJOR-1　全隊頁的「新鮮」用 status 的 `core.fresh(id)`，但 team 資料可以比 status 舊：舊的「🟢 在線」會被當成新鮮顯示

**情境**（N+1，或任何 `teamEnabled()` 為 true 的 build）：第 1 輪讀到 04，team = V1（隊員 X 🟢 在線）。之後每一輪 status 都讀到（`Res.body` → `core.states[04]` 更新 `readAt`），但 `_afterRead` 沒有更新 team——D5(b) 明寫三種情況「不更新、保留舊值」：超過 2 s 預算、紀錄打不開（`openNet` 回 null / 例外）、`cancel` 在 openNet 之後。D5(c) 又寫「新鮮度不另計時：顯示時用 `core.fresh(id, now)`」。結果：`core.fresh(04)` 一直是 true（status 每 60 s 都新），TeamPage 照新鮮樣式顯示 V1 的「🟢『X』在線」，就算 X 半小時前已經關機。這正好是 T12 / §4.3.1「掉線要看得到」要防的事，而且 254 §6 標題的「讀取於 HH:MM:SS」（R7-2）在這個做法下也會是 status 的時間、不是 team 的時間。

觸發不罕見：D5(h) 自己說每台每輪多一次 `openNet`（Keystore 解密），而 Keystore 解密在 S20 上慢一次、或 BLE 慢一次超過 2 s 就會發生；紀錄打不開（例如 `net/` 被別的流程改寫中、Keystore 暫時拒絕）則每一輪都會發生，舊值就永遠「新鮮」。

**證據**：plan D5(b)「超過 2 s → 這一輪不更新 team（保留舊值，照新鮮規則變舊）」、「紀錄打不開 → 不更新」；D5(c)「新鮮度不另計時：顯示時用 `core.fresh(id, now)`」；core.dart:155-158（`fresh` 只看 `states[id]` 的 `readAt` / `stale`）；prober.dart:157-167（`read = o` 在算 hint/team 之前就定了，所以 status 一定算讀到）。

**修法**（擇一，寫進 D5 並加測試）：
- (a) `teams[id]` 存 `(netId, view, readAt)`，`readAt` 是那次 status 讀取的單調時間；顯示時新鮮 = `core.fresh(id, now) && teams[id].readAt == core.states[id].readAt`（同一次讀取才算），否則整段 unk +「上次讀取 <team 自己的 readWall>」；或
- (b) 只要這一輪 status 是 `Res.body` 且 `teamEnabled()`，就**一定**寫 `teams[id]`：算得出來寫新的，算不出來（逾時 / 打不開 / cancel）寫「這次沒有」（清掉或標成 unk），不保留舊值當新的。

**測試 / 負向對照**：T6-13 加一條「第 1 輪 team V1；第 2 輪 status 讀到但 `openNet` 回 null（另一條：`openNet` 延遲 3 s）→ TeamPage 那一段不是新鮮樣式、沒有 🟢」；對照 = 照 v4（只看 `core.fresh`）→ 顯示 V1 的 🟢 → FAIL。現有的 (d)「改用固定 300 s → 背景回來那條 FAIL」抓不到這個洞。

### MAJOR-2　「netId 空 → 清掉」「紀錄打不開 / 手機沒有這個網路 → 不更新」偏離已審過的 254 v2.4 狀態，而且不在 §8 偏離清單

**情境**：使用者決定全隊頁「照凍結設計做」。254 v2.4 §6（R6-3 / R6-7、R7-1）與已審的實作 nodes.dart:1165-1176 規定：status 讀到就**一定**算 team：
- netId 空 → `team_view(None, …)` → `Names::NoNet` →「這台不在你建立或加入的網路裡，看不到隊員」（卡片的不明節點小字也是這句）；
- 有 netId、手機沒有紀錄或解不開 → `Names::NoList` →「這支手機沒有這個網路的名單，看不到隊員名稱」（fail-closed，全部不明節點）；
- info 讀取失敗（status 讀到）→ `Names::NoInfo` →「讀不到這台的網路資訊，請按『重新整理』」（code review A-m2：絕不說「不在你的網路」）。

（teamview.rs:250-277、:306-345；owner.rs:1361-1367 的 `team_view(record_plain: None, …)` 正是為這三種情況設計的。）

v4 的 D5(b) 改成：netId 空 → `onTeam(id, null)` 清掉（該段消失）；`netKnown` 為 false → 根本不開紀錄、也沒寫要不要呼叫 `teamView`；紀錄打不開 → 不更新。D5(e) 入口又要求 netId 不空。後果：
1. 一台剛離開網路（或被排除後 leave）的節點，在全隊頁上**整段無聲消失**，而不是 254 的那一句；
2. info 讀取暫時失敗時 `v.netId` 也是空（prober.dart:255-257 自己的註解：「otherwise (info not read)」，`nodeState` 才分得出來），v4 會把那台的整段清掉——254 A-m2 正是要避免把 info 失敗講成「不在網路」，v4 更進一步把它講成「沒有這一段」；
3. 手機沒有紀錄的網路（重裝後、legacy）看不到「不明節點 + 這支手機沒有這個網路的名單」，而這是 254 §8 生命週期矩陣的一列（T-A11 / T-A12）；
4. 和 MAJOR-1 疊加：不更新 = 舊值被當新鮮。

**修法**：照 nodes.dart:1165-1176 的已審行為：`teamEnabled()` 且 status 是 `Res.body` → 先 `team = session.teamView(recordPlain: null, member: false)`；netId 不空且 `netKnown` 才開紀錄（net 先、mnet 後），開到就用它重算；逾時 / cancel 才是「這一輪沒算到」（照 MAJOR-1 處理）。`onTeam` 永遠帶 view（`NoNet` / `NoList` / `NoInfo` 都是合法的段）；入口 (e) 改成「任何一台 `teams[id].view.visible`」（不要求 netId 不空）。若刻意要偏離（例如不在網路的節點不列段），寫進 §8 與 #329 checklist 並說理由。
**測試 / 負向對照**：T6-13(a) 把「netId 空 → `onTeam(id, null)`」改成「netId 空 → 那一段是 `ONLY_NO_NET`」、加「netKnown false → `ONLY_NO_LIST`」「nodeState ≠ 1 且 netId 空（info 失敗）→ `NO_INFO`，不是 NO_NET」；對照 = v4 的清掉 → FAIL。

### MAJOR-3　R-7 的起點「02（未在網路）」與最新的節點紀錄矛盾；照 v4 的順序第 2、3 步會撞 reason 14 與 `AlreadyMember`

**情境**：v4 §7 寫「節點現況（記憶 2026-11-18 10:00）：…02 是 dev3 的 7C31（未在網路）」。記憶 project_dut_access_state.md 第 2732 行（2026-11-18 08:40 段，最近一次記 02 的網路）寫的是「02 = dev3 認領的 7C31…**在 dev3 自己的網路**」，dev3 的網路是 `bm-50c1fae753ae`（:2731）；10:00 段（:21）只寫「02 = dev3 的 7C31（還原需 lab key）」，沒有任何「離開網路」的紀錄。「未在網路」這三個字沒有證據。

若 02 確實在 dev3 的網路：第 2 步「02（不在網路）國家設 US」→ 節點回 reason 14（國家只能在不在網路時改，plan 自己第 147 行講的）；第 3 步「02 加入 04 的網路」→ `AlreadyMember`。而且 dev3 手機持有 `net/`（它自己建的網路），首頁第 6 列「net 勝過 mnet」（home_logic.dart:35、:93）會把 dev3 導向 join2 而不是隊員加入——R-7 必須寫明從隊伍頁（team_hub.dart:40 的 `NetMode.member`）進。

**修法**：§7 開頭加「第 0 步（唯讀）」：用 dev3 首頁 / 節點頁讀 02 的狀態（或 lab key 加回後 SSH 唯讀 `uci`/status），把結果附進 PR。若在 `bm-50c1fae753ae`：在第 1 步（SSH）之後、第 2 步之前加「dev3 讓 02 離開網路」，列副作用（dev3 手機的 `net/` 紀錄留著；02 變未入網）與還原（不還原；結束狀態本來就是 04 網路的隊員）。第 3 / 6 步寫明隊員加入的入口。把「未在網路」從 F 表 / §7 改成實測結果。

## MINOR

1. **home ↔ team 換頁要整個是 no-op**：`NodeLinkCore.setPage`（core.dart:186-201）除了 `_cancel`，還會清 `earlyDue` / `fullDue` 再重算；只拿掉 `_cancel` 的話，首頁剛排好的「提前再讀」（10 s，兩輪規則）在切到全隊頁時被丟掉、延到 60 s。D5(d) 寫明「home ↔ team 只改 `page`，其餘不動」，T6-13(e) 加「有 earlyDue 時 home→team → 10 s 後照常提前再讀」。
2. **段標題偏離 §5.6 / 254 §6 而沒列**：§5.6 明寫「全隊頁用的是節點回報的名稱，不是暱稱」；254 §6 / R7-2 的標題是 Rust 的「全隊（僅供參考；由『…』看到）」+ Dart 接「，讀取於 HH:MM:SS」。v4 的段標題「從 <暱稱或節點 XXXX> 看到的全隊」用暱稱、而且 (f) 列的版面元素沒有 `title`——「僅供參考」（U5）只剩在小字 note。要嘛顯示 Rust `title` + 讀取時間（可以在下面加一行暱稱 / 後四碼方便辨認），要嘛把這條列進 §8 偏離。
3. **TeamPage 的重繪與卡片第二行**：`teams` 改變要 `_changed.add`（node_link.dart:101-103 的 `changed`），寫進 D5(c)；卡片的 `\n` 第二行是小字（member_ui.dart:496-501 的既有渲染），D5(f)「Rust 組好的句子原樣」要帶上這條。
4. **被刪測試的已知清單漏了 `test/key_gate_test.dart`**（:146 pump `NodesPage`）：它是金鑰閘門的安全回歸（「建立網路」先即時讀金鑰等級、Kotlin `keyLevel` 拒絕時畫面要說）。新路徑 owner_console_test.dart:197-204、:384 有部分對應，對照表要逐條確認「建立網路時 makeNetwork 不允許 → 不呼叫 publicKeys / signAdmin」在 NetFormPage 路徑上也有。另 `rekey_send_test.dart:167`、`:203` 的 nodes.dart 排除拿掉後要確認掃描仍找得到檔案（掃到 0 個 = FAIL）。
5. **R-7 秒數來源**：「按鈕按下時佔用登記的行」不存在（lease.dart 沒有任何 log；`RecordWriter` 只有 refused 一行）。可用的是 core.dart:637 的 `loginFor <id>`（開始）與 :695 的 `loginFor … -> <res>`（結束），經 trace 進 logcat（app_link.dart:153）。X4 情況下前面還有「正在結束上一個讀取…」≤ 5 s，要寫明算不算進「正在連到節點…」。
6. **R-7 第 7 步 SSH 變體沒有還原**：「SSH 關 02 的 HaLow 介面」之後 02 不會「自己回來」，要列還原命令（`wifi up` / `ifup` 或 `reboot`）、用 link-local 位址、執行前印出命令；並寫明 SSH 連線本身不走 HaLow（否則關掉後連不回去）。
7. **X13 / X14「和 main 的 app 做同一步比對」怎麼裝 main 的 APK 沒寫**：同 applicationId 的較舊版本需要 `adb install -r -d`；換回 PR 6 再 `install -r`。依記憶規則只准 `install -r`（不解除安裝），計畫要寫明順序、版本碼、以及「失敗就停、絕不 uninstall」。
8. **dev3 重建**：舊 dev3 的 flavor 只在已刪的 worktree（記憶 :2738），沒有 commit。重建時 `applicationIdSuffix` 必須和手機上那個一模一樣、簽章（本機 debug keystore）相同，否則 `install -r` 失敗（安全）或變成另一個 app（7C31 的擁有者金鑰不在它那裡，第 1 步做不到）。先 `adb shell pm list packages | grep batman` 與 `dumpsys package` 對簽章再裝。
9. **D9 第 4 列（身分不符）不要接「當時正常」**：第 4 列有 `node`（home_logic.dart:83-84），照 D9 會變成「X 的身分和這支手機記錄的不同」+「上次讀取 10:02，當時正常」——對安全警告是錯誤的安心句。身分不符的列只顯示時間、不接 `was`。
10. **T6-5 的白名單沒有負向對照**：只有「拿掉 soft 警告 → FAIL」。加「複製內容放進完整 device id / netId → FAIL」（掃 ≥ 8 hex 的連續字串）。
11. **SSH 取代語意的警告只放在 0 行**：node.go:862-873 是「`SSHKeysAdded` 裡的每一行都從檔案拿掉」，所以只要 app 加過一把節點上原本就有的金鑰（例如 R-7 第 1 步的 lab key 若 02 上本來就有），之後任何一次**非 0 行**的取代也會把它一起拿掉。說明句放在兩種按鈕上，不只 danger 那顆。
12. **D7a 掃描與 `const SEP`**：規則是「同一個字面量裡前面有 `\u{1F}`」；若實作用常數插值（`format!("{main}{SEP}代碼 {c}")`），字面量 `"{main}{SEP}代碼 {c}"` 裡沒有 `\u{1F}` → 誤報。規則寫明二選一（只准字面量 `\u{1F}`，或掃描器認 `{SEP}`）。

## 逐項核對（✅ 本輪自己讀過）

- ✅ prober 的結構（prober.dart:152-167、:249-273）：`read = o` 先定、hint 在 `Future.any([.timeout(2 s), cancelled])` 裡、`stop()` 在 `openNet` 之後檢查；v4 的 (b) 照這個模式做是可行的。
- ✅ `team_view` 的輸入是同一個 session 上次 `request_status_page` 讀到的 status + info（owner.rs:1342-1367），`record_plain` 可以是 None——所以 MAJOR-2 的修法不需要改 Rust。
- ✅ `teamView.visible` 在 N 永遠 false、`team-write` 在 release 編不過（teamview.rs:16、:20-21），真機量不到成本（D5(h) 的 ⚠️ 屬實）。
- ✅ T-A9 Dart 端測試在 member_ui_test.dart:602-656，移植對象正確。
- ✅ SSH 規則（node.go:752、:839-872）與 F12 一致；commit 在 `SetAuthorizedKeys` 之前，重送同一組確實等冪。
- ✅ 診斷頁的 `StatusView.tech`（statuspage.rs:426-497）沒有秘密：`uci_staged` 只是套件名（status.go:222、cddl:264），節點字串都經 `shown`。
- ✅ `NodeLink.mask`（node_link.dart:78-80）遮 ≥ 8 hex 與 MAC；core.log 的內容（core.dart:343-695）只有 id、結論、時間。
- ⚠️ 設計畫布 6.1–6.3 的畫板沒有看，「每台一段、不合併」是否符合畫板未驗證；依 254 §8「手機換到另一台自己的節點：各台的表各自獨立」推論可接受。

## 計數與判定

BLOCKER 0 / MAJOR 3 / MINOR 12

**APPROVE-WITH-CHANGES**——前幾輪的大部分 MAJOR 已解，方向正確。要修的三個 MAJOR：
- MAJOR-1：team 資料可以比 status 舊，借用 `core.fresh` 會把舊的「在線」當新鮮顯示；
- MAJOR-2：「netId 空 → 清掉」「紀錄打不開 → 不更新」偏離已審的 254 / nodes.dart 行為（NoNet / NoList / NoInfo 三句消失），沒列為偏離；
- MAJOR-3：R-7 起點「02 未在網路」與最新紀錄（在 dev3 自己的網路）矛盾，第 2、3 步會被節點拒絕。

三個的修法都小（MAJOR-1 / 2 是 D5(b)(c) 幾行加兩三條測試，MAJOR-3 是 R-7 加一個唯讀第 0 步與條件式的離開網路），修完後整份再看一次即可。
