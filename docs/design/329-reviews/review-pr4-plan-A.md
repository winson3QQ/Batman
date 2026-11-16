# #329 PR 4 計畫 v1（3a6bf5e）— 審查 A

審查範圍：計畫 §0「本 PR 新做的」與 §2–§7（OpSession、Rust SettingsView、OwnerConsole 新方法、5.6 / 5.7 / 5.8 / 離開 / 更新頁、SwHold 搬家與首頁待辦、D1–D6）。基準（leave v4.1、update v0.4、p3-impl §3.3、PR 3 機制、329-app-uiux v12.1）只當契約用，不重審。
方法：逐條對原始碼查證計畫的事實與每個新介面；從現場（S20 + HaLow 節點、BLE）走生命週期。只讀程式碼，沒有跑 flutter / adb。

## 事實查核（P1–P15）

| # | 結果 | 證據 |
|---|---|---|
| P2 | ✅ settings 回答只有 `settings_text`；get / set 走通用 `Outcome::Ok` 臂 | app/rust/bridge/src/api/owner.rs:656-674、:957-961 |
| P3 / P14 | ✅ | member_ui.dart:264-279；owner.rs:416 |
| P4 / F27 | ✅ | swupdate.dart:86-104；nodes.dart:1585-1640 |
| P5 | ✅，但見 m1（SecureScreen 失敗時整個 child 不顯示） | secure_screen.dart:41-46 |
| P7 | ✅ 字元集與長度正確；**漏了** passphrase ≠ `CHANGE-ME-NOW`（m2） | settingsset.go:60-78、:139-141；254-p3-impl.md:211 |
| P8 | ✅ reason 14 / 20；「regdb 有這個國家」對 TW **沒有查證**（m4） | settingsset.go:113-124；254-p3-impl.md:210 |
| P9 | ✅ 230 s / 300 s / 330 s；舊按鈕不帶 wait | 254-p3-impl.md:149、:189、:246；nodes.dart:1672、:1694、:1714 |
| P10 | ✅；另外 settings/get 可能回 `E_BUSY`（快取還沒讀到） | settings.go:125-140 |
| P11 | ✅ answer 臂只看 pollLink / sendUpdate | owner_console.dart:278-281 |
| P12 | ✅（路徑是 app/rust/batman-proto/src/swupd.rs，計畫少了 `app/`） | swupd.rs:848-855、:1066-1073 |
| P13 | ✅ | node_page.dart:151-156 |
| P15 | ❌ **不完整**：`NickPage._save` 存完會 push `AddedPage`（3.5 / 3.6「已加入這支手機 / 下一步建立網路」），不是回上一頁 → MAJOR-3 | add_pages.dart:41-57 |
| （計畫隱含）owner-op 寫出後會被 `SendTrack` 記成「可能已送出」 | ❌ **只有 network/leave 會**：`sent: verb == LEAVE` → MAJOR-1 | owner.rs:752；owner.rs:2790 的測試「only the write carrying network/leave is marked sent」；member_ui.dart:296-310 |

## 發現

### MAJOR-1 設定請求送出後斷線 / 逾時，畫面說「還沒有寫入或送出」（實際可能已套用）

- 情境：5.6 送出新的名稱 / 密碼。op/nonce → 簽章 → `settings/set` 已寫出，節點的 setkey 開始跑（最長約 230 s，拿著 `n.mu`）。這時藍牙斷了（走遠、節點 provd 重啟、手機藍牙被關），或 helper 卡住到 360 s 逾時。
- 計畫 §2.2 讓 `setAp` / `setCountry` 帶 `unclear: '[REQ_FAIL] 結果不明 — 請重新讀取設定'`。但 `OwnerConsole._unclearReply` 會經過 `SendTrack.unclearNow(unclear)`：只有 `wrote == true` 才回 unclear 句，否則回 **`notSentLine`「連線失敗，還沒有寫入或送出，請重試」，kind 是 `ReplyKind.notSent`**（owner_console.dart:302-305、member_ui.dart:309）。`wrote` 只在 PersistNet 或 Rust 步驟 `sent == true` 時成立，而 Rust 只對 network/leave 設 `sent`（owner.rs:752；owner.rs:2790 的測試鎖住這件事）。結果是設定請求**任何一次**斷線或逾時都會顯示「還沒送出」。
- 現場後果：使用者以為沒改成，換一組密碼再送，或拿舊密碼去連，結果連不上節點 AP。國家也一樣。這和設計 :842「操作送出後斷線 → 結果不明 … 重新讀取設定」以及計畫 §3.2 的 fail-closed 說法相反。舊控制台沒有這個問題：它不帶 unclear，逾時句本身就是「結果不明」。
- 修法：Rust 在 `signed` 寫出 owner-op 時，`settings/set` 也設 `sent`（或一般化成：簽章後送出 owner-op 的那一次寫出都設 `sent`，leave 照舊）。這是第二個 Rust 介面變更，§2.1「唯一的 Rust 介面變更」要改寫。另一個做法是頁面把 `notSent` 也當成「結果不明」，但這樣在 op/nonce 之前就斷線（真的沒送出）時也會說結果不明，比較差。
- 負對照：Rust 測試「settings/set 的寫出 `sent == true`，op/nonce 的寫出是 `false`」（拿掉旗標就 FAIL）；Dart 測試「setAp 簽章寫出後 link state 變成 false → 回覆是 unclear、文字是『結果不明 — 請重新讀取設定』」（現在的程式碼得到 `notSentLine`，FAIL）。

### MAJOR-2 OpSession 只看「上一次回覆的 sessionAlive」決定要不要重新登入；節點閒置 300 s 斷線後，下一次按鈕會失敗

- 情境：打開 5.6，`settings()` 讀到目前名稱（回覆 `sessionAlive = true`）。使用者去想或去查一組 12–63 字的密碼，過了 5 分鐘才按送出。節點上已登入的 session 閒置上限是 300 s（provd/server.go:31 `IdleAuthed`、session.go:280-297），時間到 session 結束，`bleLink.Close()` 要 BlueZ 斷線（cmd/batman-provd/bluez.go:393-421）。手機那邊 `OwnerConsole._lost()` 把 `_session` 設成 null，但因為沒有請求在等，不會產生任何回覆。
- 計畫 §2.0 第 2 步是「沒有 console、或上一次回覆 `sessionAlive == false` → 重新登入」。上一次回覆是 true，所以不重新登入，直接執行 `op`。`_ask` 回 `notSent` / `askNoLink`「沒有連上節點，沒有送出 — 請靠近一點再按一次」（owner_console.dart:332）。§2.4 又規定送出前**先清空密碼欄**，所以使用者要重打密碼，看到的原因（「靠近一點」）也是錯的。更新頁同樣會遇到：停在「套用並重開」等使用者超過 5 分鐘，第一次 ask 變成 `sw.lost`，多跑一輪。
- 這違反基準設計 329-app-uiux.md:839（N2，T-X17）：「佔用中：不顯示錯誤，下一個請求自己重新登入（現況 `_ask` 的行為）」。舊的 `_askSw` 看的也是實際的 `_session == null`（nodes.dart:1593）。
- 修法：第 2 步改成 `console == null || !console.alive`（owner_console.dart:167 的 `alive` 已經涵蓋 `_lost`、ended、unclear 三種情況），不要看上一次回覆。
- 負對照：測試「`settings()` 成功 → link state 送出 false（沒有請求在等）→ 下一次 `run` 呼叫了 `loginFor`，請求送到新的 session」（照計畫的規則會回 askNoLink，FAIL）。

### MAJOR-3 5.7「改暱稱」重用 `NickPage`，存完會跳到「已加入這支手機 / 下一步：建立網路」

- 情境：節點頁 → 更多 → 改暱稱 → 儲存。
- `NickPage._save` 存完後會 `push(AddedPage(...))`（add_pages.dart:51-56）。`AddedPage` 是 3.5 / 3.6：標題「新增節點」，內容「X 已加入這支手機」，主按鈕是「建立網路 / 加入網路」（add_pages.dart:116-146）。`NickPage` 本身的標題是「幫節點取名」，StatusHero 寫「已加入這支手機：後四碼 …」（:62-64）。計畫 P15 只寫了「預設值是目前暱稱」，沒有寫存完之後會發生什麼。
- 現場後果：一台已經在網路裡的節點，改完名字卻被帶到新增節點的下一步，主按鈕邀請使用者「建立網路」，按下去就進 4.1 建網流程。
- 修法：`NickPage` 加一個改名模式（例如 `rename: true`）：標題改成「改暱稱」、不顯示「已加入」的 StatusHero、存完直接 `pop()`；欄位旁的說明照設計 :762。或者另寫一個小頁面。
- 負對照：widget 測試「從 5.7 進入、儲存 → 回到 5.7，堆疊上沒有 `AddedPage`」（用現在的 `NickPage` 會 FAIL）。

### MAJOR-4 OpSession 沒有寫明「頁面不在了就不開始新的請求」；登入期間離開頁面，登入完成後請求仍會送出

- 情境：離開網路頁，按確認 → 拿佔用 → `loginFor`（最多 60 s 掃描，再加連線時間）。§2.7 只說「送出到回答期間」設 `PopScope(canPop: false)`，沒有寫清楚登入期間算不算。使用者等不及按了返回（一般人會以為這就是取消）→ dispose → `pageGone()`。這時 lease 還在 `hold` 中，所以不會放（lease.dart:73-83）。登入成功後 `run` 照 §2.0 第 3 步繼續執行 `op`，結果是 **network/leave 在使用者已經離開頁面之後才送出**，而且沒有任何地方顯示結果。5.6 / 5.8 也一樣：設定被改了，畫面上卻看不到結果。
- PR 3 對同一個情況有明確規則：`run.pageGone()` 之後「nothing starts after the request in progress」（net_pages.dart:736，§3.2 T-R1(c)）。OpSession 是四個頁面共用的新類別，這條規則要寫在它的契約裡，不能只靠每一頁 PopScope 涵蓋的範圍。
- 修法：OpSession 加 `_gone` 旗標，由 `pageGone()` 設定；`run` 在 `loginFor` 回來之後、執行 `op` 之前檢查，若已 gone 就關掉 handoff，回 `OpReply.gone`（什麼都沒送出）；已經在跑的請求照舊跑完。同時把各頁 PopScope 的範圍寫清楚：從按下確認到結果出來，包含登入。
- 負對照：測試「`loginFor` 還沒完成時呼叫 `pageGone()`，等 `loginFor` 回 ok 之後檢查：leave 的 frame 沒有寫出、handoff 已關閉、lease 已釋放」（照 §2.0 寫的話 leave 會寫出，FAIL）。

### MINOR

- **m1 SecureScreen 包住整頁，和設計不一致**：設計 :874 說設不了 FLAG_SECURE 的手機上「Wi-Fi 密碼欄不能切換成顯示」，頁面本身仍然可以用。但 `SecureScreen` 一失敗就把整個 child 換成一句話（secure_screen.dart:41-45）。§2.4 包住整頁，等於這種手機完全不能設定手機 Wi-Fi，而 §4 也沒有把它列為偏離。建議只包密碼欄（或依 `_on` 隱藏切換鈕），不然就列成 D7 並寫理由。
- **m2 app 端驗證漏了 `CHANGE-ME-NOW`**：這個值字元和長度都合格，但節點會拒收（254-p3-impl.md:211）。D1 既然寫「照節點的規則」，就要包含這一條；T-W1 加一列。
- **m3 密碼切換成顯示之後**：`obscureText` 關掉時可以長按複製，輸入法也可能學習。建議加上 `enableInteractiveSelection: false` 和 `keyboardType: TextInputType.visiblePassword`。§5 寫的「沒有剪貼簿」要有測試支撐，不然就改寫。
- **m4 國家選項 TW 沒有證據**：P8 說節點會檢查「regdb 有這個國家」，但計畫沒有查 TW 在不在節點的 regdb（feed 的 fixture 只有 US 兩列，settings_test.go:13-16；F79 說 ch 40 只在 US / AU / NZ / SG）。另外，加入網路時節點的國家會被改成 netcfg 的國家（建網固定 `COUNTRY = "US"`，joinflow.rs:17；join2flow.rs:8-11 的 ConfirmCountry），而未入網節點的 radio1 本來就被封鎖（p3-impl F74）。所以 5.8 改成 TW 之後，下次加入網路時會被問要不要改回來。確認對話框那一行影響說明應該講這件事。§7 真機測試要先證實節點接受 TW（看 `settings/get` 或 regdb）。另外 `view == null`（還沒讀到）時選單該怎麼顯示也要定下來，建議停用並顯示「讀取中」。
- **m5 swAnswer 的競爭**：套用之後節點立刻重開，回答的 frame 已經排進 `_chain`，但 `_lost` 可能先把 `_session` 設成 null，OpSession 就沒有 session 可以呼叫 `swAnswer`。舊程式碼有同樣的競爭（nodes.dart:1621 `identical(_session, s)`），所以只列 MINOR。建議在 console 的 answer 臂收到 `st.sw` 時就同步呼叫 `s.swAnswer(sw, now)`（owner.rs:1605），把 `SwAction` 放進回覆。
- **m6 最長 360 s 的請求期間要讓螢幕保持亮著**：設計的 S 列（:145）量到螢幕關掉之後計時器延遲了上千秒；PR 3 的 NetRunPage 有 keepScreenOn（net_pages.dart:8）。5.6、5.8 和離開頁在請求期間也應該照做。
- **m7 `AppLink.sw` 的生命週期**：
  - (a) 在 5.7「從這支手機移除」之後，要一併移除那台的 hold，否則首頁待辦會指向一台已經不在手機上的節點。
  - (b) 按「放棄這個上傳」或取消之後，`last.kind` 不是 done，`uris` 卻不是空的，待辦就會一直留著。待辦的條件應該看 Rust 的狀態（已準備、還沒套用），不要看 `uris`。
  - (c) 舊控制台和新頁面對同一台節點各有一份 SwHold，兩邊可能都顯示「準備好了」。至少要在 §3.1 寫明。
- **m8 5.6 / 5.8 一打開就一直拿著佔用**：使用者停在頁面上（打字中，或手機放進口袋）時，NodeLink 對所有節點都停止讀取，而且沒有上限（goneMax 要等 pageGone 之後才開始算）。這和 D6 的理由（PR 3 LOW 3）是同一類問題。建議讀完 `settings()` 就放掉佔用，按送出時再拿；這樣 MAJOR-2 的閒置斷線也就不會發生。
- **m9 離開的確認對話框用的是 NodeLink 的 view**：那份資料可能是一分鐘前讀的，甚至是上次執行留下的。舊控制台用的是同一個 session 剛讀到的狀態頁（nodes.dart:1146-1152、:1186-1188）。節點才是權威，所以不會造成危害；但在 `n.fresh == false` 時，建議登入後先 `statusPage` 再顯示對話框，或在對話框裡寫出讀取時間。
- **m10 `leaveFlow.reread` 的型別是 `Future<StatusFields?>`**（member_ui.dart:268），計畫寫的卻是 `statusPage(...)` 回 `StatusView?`。兩者怎麼轉換要寫清楚（membership 句、`_netNames` 提供的名稱）。`AppLink.nets`（NetIndex）已經有 applied 和 members，可以考慮直接用它，不必再從舊控制台抽出 `_netNames`。
- **m11 D6 放掉佔用之前先 `close()` console**：§4.4 要求「先等斷線完成」，ble_gate.dart:251-254 只是事後補救。另外 `run` 遇到已經失效的 lease 時，`hold()` 會丟 StateError（lease.dart:61），要對應成 `leaseLost`。
- **m12 換手機 AP 的影響**：正連著這台節點 Wi-Fi 的手機（包含用 TAK 的）會斷線，要用新密碼重連。5.6 送出前加一行說明。
- **m13 路徑**：計畫裡的 `owner.rs` 實際位置是 app/rust/bridge/src/api/owner.rs；`rust/batman-proto/...` 少了 `app/` 前綴。

## 生命週期矩陣：計畫沒寫到的列

- 節點的 provd / helper 在 `settings/set` 期間重啟 → 斷線 → 走 MAJOR-1 的路徑。
- 佔用中節點閒置 300 s 斷線 → MAJOR-2；設計的 T-X17 要有對應測試。
- 佔用中藍牙被關或權限被收回 → 設計 :837 要求流程頁顯示「開啟藍牙設定」；計畫只寫了 `loginLine(end)`，要寫明 `precondition` 時顯示哪一句。
- 螢幕關掉期間的長請求 → m6。
- 登入期間離開頁面 → MAJOR-4。

## 安全

- 密碼的流向（欄位 → 區域變數 → frb → Rust 的加密請求）和 Rust 的契約一致（owner.rs:779-786；錯誤句 `error_text` 不含輸入的值，owner.rs:649-654）。OwnerConsole 的 log 不含回答內容。T-W5 的負對照可以接受。
- 有缺口的地方是 m1（不能防截圖的手機）和 m3（顯示狀態下的剪貼簿與輸入法）。被入侵的節點和同一支手機上的其他 app 都沒有新增的攻擊面。
- 失敗模式：MAJOR-1 修好之前，§5「其他一律『沒有成功』或『結果不明』」這句**不成立**，因為設定請求的斷線會被說成「沒有送出」，這是 fail-open 的錯誤訊息。

## 結論

**APPROVE-WITH-CHANGES**。有 4 個 MAJOR，每一個都有明確的修法和負對照：

1. MAJOR-1：設定送出後斷線，被說成「沒有送出」。
2. MAJOR-2：閒置斷線後不會重新登入。
3. MAJOR-3：改暱稱用的 NickPage 會跳進新增節點流程。
4. MAJOR-4：離開頁面後，請求仍然會送出。

修正後請重審整份計畫。MINOR 可以在實作時處理，或寫進 #329 的 checklist。
