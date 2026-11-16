# #329 PR 4 計畫 v2（1022df5）— 審查 C（第二輪）

範圍：整份 v2 計畫的新部分（§0「本 PR 新做的」、§2–§7：OpSession `once` / `open`、兩個 Rust 變更、OwnerConsole 新方法、5.6 / 5.7 / 5.8 / 離開 / 更新頁、SwHold 搬家與首頁待辦、D1–D7），並逐條確認第一輪的修法有沒有真的關掉問題、有沒有開出新洞。基準（leave v4.1、update v0.4、p3-impl §3.3、PR 3 機制、329-app-uiux v12.1）只當契約用，不重審。
方法：從現場（S20、HaLow 節點、BLE）出發，逐條對原始碼查證。只讀程式碼與 git；沒有跑 flutter / adb / gradle（計畫審查，還沒有新程式）。

## 事實查核（只列 v2 新增或第一輪沒查到的）

| # | 結果 | 證據 |
|---|---|---|
| §2.1 (a) Rust 只對 LEAVE 設 `sent` | ✅ | app/rust/bridge/src/api/owner.rs:752；Dart 唯一的讀者是 `stepFrames`（lib/member_ui.dart:236）→ `SendTrack.unclearNow`（:309） |
| §2.1 (a)「舊控制台行為不變」 | ✅ 舊 `_ask` 的設定按鈕不帶 unclear、預設 `retry: true`，重送分支不看 `wrote`（nodes.dart:546-569、:1694、:1714），所以 `sent` 變了也不影響 | nodes.dart:546-569 |
| settings/set 是 op/nonce → Sign → 簽章後寫出 | ✅ 序列 `[false, true]` 可行 | owner.rs:796-806（owner_op）、:744-753（signed） |
| A1 TW 不在 regdb 時的後果 | ✅ 安全：halow-setkey 在動任何東西之前先查 regdb，不在 → rc 2 → reason 13，節點狀態不變 | feed/batman-provision/files/usr/bin/halow-setkey:211、:239；settingsset.go:28-31 |
| 國家只能在 radio 被封鎖時改 | ✅（補充）：除了 `rec.Net == nil`，setkey 還要求 `wireless.$R.disabled = 1`，不然是 rc 2 → reason 13「節點不接受這個值」 | halow-setkey:241；settingsset.go:118-124 |
| D7「NodeLink 最多約 60–90 s 前的讀取」 | ❌ NodeLink 的「新鮮」是 **300 s** 內 | lib/src/nodelink/core.dart:15、:155-158 |
| `keepScreenOn` 是一個 window flag，沒有計數 | ⚠️ 計畫沒寫到 → MAJOR-1 | android/.../swupd/SwUpload.kt:77-83；lib/ui/net_pages.dart:42-44；lib/swupdate.dart:119、:131-137 |
| update 設計 D9 的契約 | 「更新頁開著時 `true`，離開時 `false`」 | docs/design/254-app-update.md:114、:435 |
| Dart 的 OwnerConsole 測試用假的 Rust session（`sent` 由假物件決定） | ✅ → 影響 T-W3 的負對照（m2） | test/flows/owner_console_test.dart:1-4、:86；test/nodes_update_send_test.dart `FakeSession` |
| `sw_answer` 要 `&mut SwUpdate` | ✅ console 要在送出時記住那個 `sw`，才能在 `_run` 的 answer 臂裡算 | owner.rs:1604-1609 |
| Rust 對 Conn 狀態的傳輸錯誤：只有 leave 有自己的結果句，其他（含 settings/set）一律 `Ended`「連線出錯」 | ✅ → m3 | owner.rs:973-982 |
| 節點不在手機上時節點頁不會壞 | ✅ 顯示「這台節點已經不在這支手機上。」 | lib/ui/node_page.dart:141-143 |

## 第一輪修法的確認

| 第一輪 | v2 的修法 | 結果 |
|---|---|---|
| A M1 = B M1（設定送出後斷線說成沒送出） | Rust `settings/set` 設 `sent` | ✅ 關掉。殘留兩點：Rust 的 `Ended` 路徑（m3）；T-W3 的負對照在 Dart 做不到（m2） |
| A M2 = B M2（只看 `sessionAlive`） | `console == null \|\| !console.alive \|\| !sessionAlive` | ✅ `open` 關掉；`once` 每次都新登入，不會遇到。但這條規則的適用範圍要寫清楚（m4） |
| A M3（NickPage 進 AddedPage） | `rename` 模式 + T-N4 | ✅ |
| A M4（頁面不在了才送出） | `_gone` + PopScope 含登入 + T-P5 | ✅ |
| A m6 = B m9（keepScreenOn） | 放進 OpSession 的通用規則 | ❌ **開出新洞**：`open` 用法會把更新頁的 D9 旗標關掉 → MAJOR-1 |
| A m8 = B m4（閒著持有佔用） | `once` | ✅；但 `goWifi` 的交接出現新的競爭（m1） |
| A m1（SecureScreen 整頁） | 不改，理由「設計原文是整頁」 | ⚠️ 設計 §8 的表（329-app-uiux.md 安全表「旁邊看螢幕」列）寫的是「Wi-Fi 密碼欄不能切換成顯示」，兩處設計不一致；計畫選了比較嚴的那個，應列成偏離（m7） |

## MAJOR

### MAJOR-1 `OpSession` 在請求結束時關掉 keepScreenOn，把更新頁整頁的「螢幕保持亮著」也關了

- **情境**：S20 開更新頁 → `SwUpdatePage.initState` 呼叫 `keepScreenOn(true)`（swupdate.dart:119），照 update D9「更新頁開著時 `true`」（254-app-update.md:114、:435）。接著流程第一次 `ask` 走 `OpSession.open` 的 `run`。§2.0 規定「請求在跑的期間 `keepScreenOn`」，照 PR 3 的寫法（net_pages.dart:513-515）就是開始時 `true`、結束時 `false`。
- **證據**：`keepScreenOn` 在 Kotlin 端只是 `FLAG_KEEP_SCREEN_ON` 的 add / clear，沒有計數（SwUpload.kt:77-83）；PR 3 的 `keepScreen` 也打同一個 channel、同一個方法（net_pages.dart:42-44）。所以第一個請求一結束，旗標就被清掉，之後整個更新頁都沒有旗標了。
- **現場後果**：更新流程有一長段是「頁面在等、沒有 BLE 請求在跑」：上傳（Kotlin PUT，`_progress` 計時器）、套用後每 10 s 重登一次、等 5 分鐘重開、讀試用最長 15 分鐘（swupd.rs:41-45）。手機 30 s–1 分鐘就熄螢幕。設計 :145 量過，螢幕關掉之後計時器會延遲上千秒；判定又是依時間（P12，swupd.rs:1066-1073）。所以下一次讀取可能在 `REBOOT_FOR_MS` / `TRIAL_FOR_MS` 之後才發生，流程直接收在 `T_LATER`（「稍後再看」），但節點其實早就回來了；上傳中熄螢幕則會中斷，要從頭重傳（update F11）。這是 PR 4 搬家之後才有的退步：舊控制台的 `_askSw` 不碰 keepScreen（nodes.dart:1589-1625）。
- **修法**（擇一）：
  - (a) `OpSession` 只在 `once` 時管 keepScreen；`open` 不碰，由更新頁照 D9 自己管整頁。
  - (b) 把 keepScreen 改成 Dart 端單一擁有者的計數器（例如 `ScreenOn.hold()` 回傳 release），更新頁、`OpSession`、NetRunPage 都從它拿。

  §3.1 擁有權表要加一列「螢幕保持亮著（window flag）」，寫明唯一的寫入者。
- **負對照**：widget 測試：更新頁打開，跑完一次 `ask`，斷言 channel 收到的最後一個 `keepScreenOn` 是 `true`（照 §2.0 現在的寫法會是 `false`，FAIL）；頁面 dispose 後才是 `false`。

## MINOR

- **m1 `goWifi` 交接的競爭：5.6 一打開就會說「另一個操作還在進行：軟體更新」**
  - 情境：更新頁按「去設定手機 Wi-Fi」→ `pop(goWifi)` → dispose → `OpSession.pageGone()`：閒著，所以先 `close()` 再放佔用（§2.0）。`close()` 會等 `_chain`（最多 10 s）和斷線完成（owner_console.dart:485-503、handoff.dart `close`）。節點頁收到 `goWifi` 後立刻開 5.6，5.6 的 `initState` 馬上 `once` 讀 settings → `NodeLink.acquire` 看到 `reg.current != null`，回 null（node_link.dart:177-185）。
  - 後果：使用者照更新頁的指示來設 Wi-Fi，第一個畫面卻是「另一個操作還在進行：軟體更新」，要按「重新讀取」才行。PR 3 的 D9 接受的是使用者自己按「開始」時的空檔；這裡是流程自動帶過去的路徑（T-U5），而且每次都會撞到。
  - 修法：節點頁等更新頁 `OpSession` 的關閉（一個 `released` future）完成之後才 push 5.6；或者 `once` 在 acquire 被拒、而且持有者是正在放的那個佔用時，最多等 5 s 再試一次。T-U5 的假物件要讓 `close()` 真的花時間（不然測不到）。

- **m2 T-W3 的負對照在 Dart 做不到**：OwnerConsole 的 Dart 測試用的是假的 Rust session，`sent` 由假物件給（owner_console_test.dart:86 `step(..., sent: true)`）。所以「Rust 不設 `sent` → T-W3 FAIL」實際上不會發生，Dart 測試只會照假物件的設定通過。這正是「stub 要照真工具輸出」那一類的坑。
  - 修法：守衛在 Rust 測試（`[false, true]` 序列；負對照是只認 LEAVE）。Dart 的 settings 假物件要照那個序列寫，並在註解指出 Rust 測試的名稱。Dart 這邊的負對照改成「假物件給 `sent: false` → 回覆是 notSent」，證明 Dart 確實依 `sent` 決定。
  - §6 第 4 步 T-W3 的負對照文字要改。

- **m3 Rust 回 `Ended` 時（簽章寫出之後的傳輸錯誤），設定頁沒有對應的結果**：Conn 狀態下 `conn.on_frame` 回 `Err` → `St::Over` + `Ended("連線出錯…")`。只有 leave 會換成自己的「結果不明」句（owner.rs:973-982）。console 會回 `ReplyKind.ended`（owner_console.dart:282-286）。§2.4 的結果清單沒有 `ended`、`refused`、`leaseLost`。
  - 如果頁面把 `ended` 當成「沒有成功」，就和 MAJOR-1（第一輪）同一類：節點可能已經換了 AP。
  - 修法：`setAp` / `setCountry` 的回覆是 `ended` 而且 `_track.wrote` 時，當成 unclear（「結果不明 — 請重新讀取設定」）；`wrote` 為 false 時當成「還沒有送出」。在 console 裡用 `SendTrack` 判斷，不在頁面解析文字。加測試，負對照是拿掉這個對應。

- **m4 重新登入的規則只適用於 `open.run`，要寫明**：§2.0 第 3 點寫的是「每一個請求之前」都看 `console.alive` 決定要不要重新登入。照字面套到 `once` 的 `ops(c)`，離開之後的 `statusPage` 遇到 console 已斷，就會重新登入；新的 session 沒有 `after_left`，重讀會顯示沒截斷的「請按加入網路」句，違反 leave v4.1 §2。§2.7 寫了「不重新登入」，但兩節互相矛盾。
  - 修法：§2.0 寫明 `once` 只在開始時登入一次，`ops` 之間不重新登入（console 死了 = 後面的請求回 notSent）；重新登入只發生在 `open.run`。
  - 測試：T-L2 加一列，負對照是讓 `once` 在 ops 之間重新登入。

- **m5 D7 的時間不對**：NodeLink 的「新鮮」是 300 s（core.dart:15、:155-158），不是 60–90 s。離開對話框的 `netId`、5.7 的離開列、5.8 選單是否可用，都依最多 5 分鐘前的讀取決定。節點會再驗一次（reason 14 / 離開的結果句），所以不會造成危害。請修正 D7 的說法。
  - 另外，`once` 放掉佔用後，NodeLink 6 s 後才開始讀（lease.dart 監聽者、core `afterLease`）。在這段時間裡，5.7 仍然依離開前那次新鮮的讀取顯示「離開網路」。再按一次只會得到節點的錯誤句，可以接受，但要寫進 §3.3。

- **m6 `SettingsView` 的字串要經過 `display_name` + 64 字**：設計 §8 的「被入侵的節點」列寫明節點給的字串一律 `display_name` + 截 64 字。`SettingsView.name / ap_ssid / country` 會顯示在新的主畫面上（5.6 目前名稱、5.8「其他代碼原樣」）。§5 寫「同一類，不新增」，但新的顯示位置要照這條規則。
  - 修法：在 Rust 建 `SettingsView` 時套 `invite::display_name`（batman-proto/src/invite.rs:110）並截斷。
  - 測試：帶 bidi / 換行字元的 ssid 進 → 輸出已清掉。負對照是不套 `display_name`。

- **m7 SecureScreen 整頁和設計 §8 不一致，要列成偏離**：設計 §8 寫「設不了 FLAG_SECURE 時，Wi-Fi 密碼欄不能切換成顯示」，§5.5 寫「這一頁包在 `SecureScreen` 裡」。計畫選擇整頁不顯示，等於這種手機在新 UI 完全不能設手機 AP。PR 6 刪掉舊控制台之後，更新流程的 `setAp` 路徑也會走不通。
  - 實際上這種手機很少（只有 channel 出錯時才會發生）。選比較嚴的做法可以接受，但請列成 D8，寫明理由與這個後果。

- **m8 `AppLink.sw`：`last` 的寫入者與通知、秘密的存活時間**
  - (a) 首頁待辦與節點頁副標讀的是 `hold.last.buttons`，但 `last` 是 `SwUpdatePage._go` 直接改的（swupdate.dart:146），不經過 `SwHolds`，所以不會通知 ChangeNotifier。結果是待辦可能停在舊狀態，要等下一次重建才更新。請讓更新頁 dispose 時呼叫 `SwHolds.touched(id)`，§3.1 也要把 `last` 的寫入者寫進去。
  - (b) hold 裡的 `SwUpdate`（Rust 端握有 bearer 與 AP 認證，`apCredentials()`）原本跟著舊控制台頁面的生命週期，搬到 `AppLink` 之後就活到程序結束；只有 `done` 才會移除。放棄或失敗之後的 hold 也應該移除，至少不能留著 Upload 的 action（`bearerHex`）。這屬於實體取得手機 / 記憶體傾印的情境，風險低。

- **m9 從 5.7「從這支手機移除」成功之後會回到一個空的節點頁**：「程式不變」的 `_remove` 結尾是 `Navigator.pop()`（node_page.dart:96）。搬到 5.7 之後只會 pop 5.7，使用者看到「這台節點已經不在這支手機上。」（node_page.dart:141-143）。不會當掉，但應該直接回首頁（`popUntil` 到節點頁的上一層）。T-N 系列加一列。

- **m10 更新頁打開時拿不到佔用，怎麼辦沒寫**：`open` 在頁面打開時 acquire。被拒時（舊控制台開著、另一個操作在跑），`SwUpdatePage.initState` 還是會 `_go(_f.start())`（swupdate.dart:118-124），第一次 `ask` 會是什麼結果沒有定義。
  - 建議：被拒就不建立 / 不啟動 flow，頁面只顯示「另一個操作還在進行：X」。
  - 另外，`open.run` 遇到 `LoginForEnd.precondition`（藍牙關了）目前對應到 `sw.noLink`。流程會每 10 s 重試，5 分鐘後收在 `T_LATER`，不會像設計 :837 要求的顯示「開啟藍牙設定」。至少要寫進 §3.3。

- **m11 Autofill 的旗標測試證明不了 Android 的實際行為**：`autofillHints: null` 的 widget 斷言只證明 Flutter 參數有設，不證明 Samsung Pass / Google Autofill 不會跳出「儲存密碼」（Android 也會依 inputType 判斷密碼欄）。§7 的 5.6 場次請加一項：在 S20 上輸入新密碼送出，確認沒有跳出儲存提示（⚠️ 到真機之前是推論）。

- **m12 小地方**：
  - settings/set 回 Ok 但 `read = false`（快取讀不到，settingsset.go:153-164）時，畫面只說「已更新」，不顯示名稱，並提供「重新讀取」。
  - 名稱欄要不要 trim（舊控制台有 `.trim()`，nodes.dart:1707；節點拒絕頭尾空白）請寫明，建議不 trim，直接提示。
  - §2.8 的 `swupdate.dart:123` 應該是 :119 / :131。
  - §2.7 的 `askEnd` 欄寫「都是『沒有送出』」，只適用於登入失敗 / 忙 / gone；unclear / ended 是 console 自己的結果句（leaveUnclear、Leave::Unknown）。請把這句寫清楚。

## 生命週期矩陣：缺的列

- 更新頁開著、沒有請求在跑時螢幕熄掉 → MAJOR-1。
- 從更新頁 `goWifi` → 5.6 的交接空檔 → m1。
- 設定送出後 Rust 回 `Ended`（傳輸 / 解密錯誤）→ m3。
- 更新頁打開時佔用被拒；更新中藍牙關閉 → m10。
- 5.7 移除節點之後的導航 → m9。

## 安全（逐 actor）

- **遠端攻擊者（BLE）**：沒有新的空中介面；owner-op 要簽章，節點再驗（settingsset.go:84-147）✅。
- **同一支手機上的其他 app**：沒有新檔案；剪貼簿已關；Autofill 見 m11 ⚠️。
- **被入侵的節點**：`SettingsView` 的字串要經過 `display_name`（m6）；其他同 PR 3 LOW 1。它不能讓 app 說「沒送出」：§2.1 (a) 之後成立；`Ended` 的路徑見 m3。
- **實體取得手機**：SecureScreen 整頁 fail-closed ✅（偏離見 m7）。hold 的存活時間見 m8 (b)。
- **供應鏈**：沒有新的依賴 ✅。
- **我們自己的錯**：MAJOR-1（keepScreen 的兩個寫入者）、m4（規則範圍互相矛盾）。
- **密碼的流向**：欄位 → 區域變數 → frb → Rust 的 `op` 暫存（簽章後就 `take`，owner.rs:739-741）→ 加密請求 → 節點的 setkey 從 stdin 讀（`--ap -`，halow-setkey:9）。不進 argv、不進 log、不進步驟文字 ✅。

## 結論

**APPROVE-WITH-CHANGES**。

第一輪的 4 個 MAJOR 都確實關掉了。但 v2 為了第一輪的 MINOR（keepScreenOn）在 `OpSession` 加的通用規則，和更新頁的 D9 契約互相衝突，開出 **1 個新的 MAJOR**（MAJOR-1：更新期間螢幕會熄，流程可能誤收在「稍後再看」，上傳可能中斷）。修法很小：在 `open` 模式不碰 keepScreen，或者改成計數器；需要附負對照。

12 個 MINOR 可以在實作時處理，或寫進 #329 的 checklist。其中 m1（`goWifi` 交接競爭）、m3（`Ended` 的結果）、m4（重新登入的範圍）建議在計畫裡直接寫明。
