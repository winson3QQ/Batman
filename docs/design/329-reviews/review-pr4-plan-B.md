# #329 PR 4 計畫 v1（3a6bf5e）— 審查 B

範圍：只審計畫 §0「本 PR 新做的」與 §2–§7（OpSession、Rust SettingsView、OwnerConsole 新方法、各頁、SwHold 搬家與首頁待辦、D1–D6）。基準（leave v4.1、update v0.4、p3-impl §3.3、PR 3 機制、設計 v12.1）只當契約用，不重審。
方法：從現場（S20 + HaLow 節點、BLE）出發，逐條對原始碼查證；沒有跑 flutter test（計畫審查，沒有新程式）。

## 事實查證

| # | 結果 | 證據 |
|---|---|---|
| P1 | ✅ | nodes.dart:1670、:1694、:1713-1714 |
| P2 | ✅ | owner.rs:656-672（settings_text）、:960-961 |
| P3、P6、P14、P15 | ✅ | member_ui.dart:264-300、:345；owner.rs:416；add_pages.dart:19-31（但見 m5） |
| P4 | ✅ | swupdate.dart:86-104 |
| P5 | ✅ | secure_screen.dart:11 |
| P7 | ✅ | settingsset.go:60-78、:139-141（全是 ASCII，位元組數 = 字元數） |
| P8 | ✅ | settingsset.go:113-124（rec.Net != nil → reason 14；!RadioManaged → reason 20） |
| P9 | ✅ | nodes.dart:1694、:1714 的 `_ask` 不帶 wait（預設 15 s）；provd server.go:23 HelperWait 330 s |
| P10 | ✅ | settingsset.go:150-160 |
| P11 | ⚠️ 行為對，行號錯 | `answer` 臂在 owner_console.dart:278-281；計畫寫的 :265-268 是 `wait` 臂 |
| P12 | ✅ | swupd.rs:43 REBOOT_FOR_MS = 300 s、:45 TRIAL_FOR_MS = 900 s、:1066-1073 |
| P13 | ✅ | node_page.dart:155-160 只有 warning / lagNote / shownWhy |

計畫沒寫、但會影響設計的事實：
- **F-a**：Rust 只在 `network/leave` 的寫出步驟設 `sent`：`OwnerStep { frames: f, sent: verb == LEAVE, .. }`（owner.rs:752）。`SendTrack.unclearNow` 只在 `wrote` 時才回 unclear 句，否則回 `notSentLine`（member_ui.dart:309）。
- **F-b**：provd 會關掉閒置 300 s 的已登入連線：`IdleAuthed = 300 * time.Second`（provd/server.go:31）。關掉後 `OwnerConsole._lost` 會把 `_session` 設成 null（owner_console.dart:315-321），但不會改上一個 `ConsoleReply`。
- **F-c**：`OwnerConsole._lost` 只有在 `_unclear != null` 時才會結束等待中的請求（`_endUnclear`）；否則要等 `_kick` 的計時器到期才結束。軟體更新的 Check / Apply 等 340 s（swupd.rs:25、:660）。
- **F-d**：PR 3 的流程判斷要不要重新登入時看兩個條件：`!m.sessionAlive || !c.alive`（net_run.dart:262）。設計 §9 表「節點閒置逾時把連線關掉（N2）」寫：佔用中不顯示錯誤，下一個請求自己重新登入（T-X17）。

## MAJOR

### M1. 手機 Wi-Fi、國家送出後斷線或逾時，會顯示「還沒有寫入或送出」（實際上已送出）
- **情境**：在 5.6 送出新的 AP 名稱 / 密碼。簽過章的 `settings/set` 已經寫出，節點正在跑 halow-setkey（最長約 230 s）。這時藍牙斷了（人走開、節點的 BLE 掉線），或 360 s 到了。
- **證據**：計畫 §2.2 讓 `setCountry` / `setAp` 帶 unclear 句「結果不明 — 請重新讀取設定」。但 settings/set 的寫出步驟 `sent = false`（F-a，owner.rs:752），所以 `_track.wrote` 一直是 false，`_unclearReply`（owner_console.dart:302，由 `_lost→_endUnclear` 和 `_kick` 呼叫）回的是 `notSentLine`「連線失敗，還沒有寫入或送出，請重試」，種類是 `notSent`。
- **後果**：
  - 使用者被告知「沒送出」，其實節點可能已經換了 AP 密碼或國家。
  - 使用者照指示「重試」：第二個 settings/set 撞上還在跑的第一個，或者再套用一次。
  - 手機連著那個 AP 時，Wi-Fi 會斷，畫面卻說什麼都沒改。

  這正是計畫 §5「失敗模式：其他一律『沒有成功』或『結果不明』」要防的錯。舊控制台不帶 unclear，回的是「15 秒內節點沒有回應（結果不明…）」，至少不會說「沒送出」。
- **修法（最小）**：Rust 的同一行改成 `sent: verb == LEAVE || verb == "settings/set"`，並加 Rust 測試，照 owner.rs:2790 的寫法：set_ap / set_country 的 sent 序列是 `[false, true]`。Dart 再加一個 T-W3 變體：簽章寫出後斷線 → `ReplyKind.unclear` + 「結果不明 — 請重新讀取設定」；op/nonce 階段斷線 → notSent。
- **負對照**：把 Rust 改回只認 LEAVE，T-W3 變體就 FAIL。

### M2. OpSession 只看上一個回覆的 `sessionAlive`：節點閒置 300 s 關線後，下一個請求變成「沒有送出」
- **情境 1（5.6 / 5.8）**：打開頁面時登入並 `settings()`（回覆 alive = true）。使用者花了超過 5 分鐘想、打 12 個字元以上的密碼，節點就把閒置連線關掉（F-b）。之後按送出，OpSession 看上一個回覆還是 alive，就沿用這個 console。`_ask` 第一行（owner_console.dart:332）`if (_closed || s == null) return _reply(ReplyKind.notSent, askNoLink, alive: false)` → 「沒有連上節點，沒有送出 — 請靠近一點再按一次」。使用者人就在節點旁邊。
- **情境 2（更新頁）**：「選擇更新檔」之後停在 Show 畫面（等使用者按「開始傳送」），超過 5 分鐘。按下去 → notSent → `sw.lost`，流程走錯誤分支。舊 `_askSw` 遇到 `_session == null` 會先 `_login`（nodes.dart:1592），所以這是相對基準的退步。
- **情境 3（套用後）**：apply 的回答 alive = true，節點接著重開、連線斷。下一個 ask 沿用死掉的 console，白白丟一次 lost。判定看時間，所以不致命，但會多一輪。
- **證據**：F-b、F-d；計畫 §2.0 第 2 步只寫「上一次回覆 `sessionAlive == false`」。設計 §9 N2 / T-X17 明寫「下一個請求自己重新登入」。
- **修法**：條件改成 `console == null || !last.sessionAlive || !console.alive`，和 net_run.dart:262 一樣；`OwnerConsole.alive` 已經有了（owner_console.dart:167）。
- **測試**：T-P4 加一列：console 閒著的時候把 link state 推成 down，下一個 `run` 會先 `loginFor`，結果是 answer，不是 notSent。
- **負對照**：只看 `sessionAlive` 時，這個測試要 FAIL。

## MINOR

- **m1 askSw 要帶 unclear 記號**：舊 `_askSw` 設了 `_unclear = _swUnanswered`（nodes.dart:1598），斷線時立刻結束。計畫 §2.2 的 askSw 那列 unclear 寫「—」，照 F-c，Check / Apply 時斷線要等滿 340 s 才 `lost`，而且期間 PopScope 擋著。請帶一個記號 unclear（回 notSent 或 unclear 都對應到 `sw.lost`），並加測試：送出後斷線 → 1 秒內 `lost`。負對照：不帶 unclear 就逾時。
- **m2 `swAnswer` / `statusView` 要從回答的那個 session 取**：計畫寫回覆之後再呼叫 `session.swAnswer(sw, now)`。但 `_lost` 可能在回答之後、呼叫之前把 `_session` 設成 null（套用後節點馬上重開，正是這種情況）。建議：在 `_run` 的 `answer when st.sw` 臂裡，用當下的區域變數 `s` 呼叫 `s.swAnswer(...)`，把 `SwAction` 放進 `ConsoleReply`。`statusPage()` 的 `statusView` 也一樣處理。另外，離開後的 `reread` 只能用同一個 console：console 死了就回 null（stale），**不要**重新登入，否則新 session 沒有 `after_left`，截斷就不見了。這和計畫 §2.7「同一個 Rust session」的說法要一致，搭配 M2 的修法時要特別寫明。
- **m3 `OpSession.pageGone` 會在請求進行中關掉 console**：`close()` 會立刻把等待中的回答設成 unclear，並斷掉連線（owner_console.dart:485-500）。PR 3 的做法是頁面離開時不打斷進行中的請求（net_run.dart:119-122、net_pages.dart:525-527）。請改成：閒著的時候才 close；有 hold 的話，等那次 `run` 結束再 close 再放。
- **m4 5.6 / 5.8 開著就一直佔著**：頁面打開就拿佔用並登入，直到 dispose。使用者把手機停在這頁時，所有節點都不自動讀，還留著一條 BLE session。這和 D6 要修的「閒著的頁面佔著佔用」（PR 3 安全審查 LOW 3）是同一類，但只修了離開網路那頁。建議：讀完目前值就放；送出時再拿佔用、再登入。如果維持現狀，請在 D 表寫明理由。
- **m5 改暱稱不能直接沿用 `NickPage`**：這頁的標題區寫「已加入這支手機」，存檔後會 push `AddedPage`（3.5 / 3.6「建立網路 / 再加一台」）（add_pages.dart:41-57、:66）。從「更多 → 改暱稱」進去會跑出新增節點的後續畫面。需要一個模式參數，或另寫一頁；說明文字照設計 §5.5。
- **m6 `AppLink.sw` 的擁有權**：
  - 誰建立 hold（舊做法在呼叫端 `_softwareUpdate`）、誰在完成後移除（計畫 §2.8 說「關頁後」，看起來是節點頁）都要寫清楚。
  - 「從這支手機移除這台節點」（node_page.dart `_remove`）也要清掉那台的 hold，不然首頁待辦會指向一台已經不在的節點。

  請寫成單一寫入者，並加測試。
- **m7 國家頁與離開那一列的前提**：
  - 國家頁沒寫 `settings` 讀不到時（read = false、登入失敗）選單怎麼辦。
  - 也沒寫 `view == null` 或不新鮮時怎麼判斷「在網路裡」。
  - 「離開網路」那一列以 `view.canLeave` 決定，但沒要求 `fresh`。節點連不到時，view 可能是很久以前讀的，對話框的再加入句（以 k10 算）可能和節點現況不符。`network/leave` 不帶網路 id。

  建議：只在新鮮的讀取時顯示；或者登入後先 `statusPage()`，netId 和對話框用的不同時停下來重新確認。
- **m8 5.6 的現場與秘密**：
  - 加一行提醒：連著這個 AP 的手機會斷線，要用新密碼重新連（TAK 會斷）。
  - 密碼欄設 `autofillHints: null`：Flutter TextField 預設參與 Android Autofill，密碼管理器可能提示「儲存密碼」。
  - 顯示密碼時用 `keyboardType: TextInputType.visiblePassword`。

  T-W5 要涵蓋 autofill 設定。
- **m9 360 s 的等待期間要保持螢幕亮著**：設計 §2 的 S 列寫螢幕關掉後計時器與掃描不可靠；PR 3 在工作期間開 `keepScreen`（net_pages.dart:41-42、:512-514）。5.6、5.8、離開那頁送出時也應照做。
- **m10 OpSession 的同時呼叫**：`OwnerConsole._ask` 第二個請求會丟 `StateError`（`_busy`）；`lease.hold()` 在佔用已失效時也會丟例外。OpSession 要嘛排隊、要嘛拒絕，並把例外轉成 `OpReply`，不能讓例外直接冒到頁面。
- **m11 生命週期矩陣缺的列**：
  - 節點閒置關線（N2 / T-X17，見 M2）；
  - 佔用中藍牙關閉或權限被收回（T-X16）；
  - 螢幕關閉（m9）；
  - 有 SwHold 時節點被移除（m6）；
  - `goWifi` 往返：5.6 做完之後怎麼回到更新頁（節點頁的「還沒做完」副標），以及流程停在 ApDone 畫面等使用者按。
- **m12 D6 的順序**：先 `close()` console（等連線斷完）再 `release()`。gate 在放掉時本來就會收拾留下的連線（ble_gate.dart:251-254），但照 §4.4「釋放：先等斷線完成」寫明比較好。
- **m13 P11 行號**：改成 owner_console.dart:278-281。

## 安全（逐 actor）

- **遠端攻擊者**：沒有新的空中介面。owner-op 要簽章，節點會再驗一次（P7 / P8）✅。
- **同一支手機上的其他 app**：沒有新檔案、不用剪貼簿 ✅。Autofill 見 m8。
- **被入侵的節點**：只能控制畫面上的字（SettingsView 的字串、錯誤句），和 PR 3 LOW 1 同類 ✅。M1 修好之後，節點不能讓 app 說「沒送出」；說「已更新」只能靠節點的 Ok 回答，這是本來就有的限制。
- **我們自己的錯**：M1（把「已送出」說成「沒送出」）和 M2（說「沒有連上」）都屬這類。密碼路徑（欄位 → 區域變數 → frb → Rust 加密請求；owner.rs:779-787 不進步驟文字）✅。
- **實體取得手機**：SecureScreen；做不到的時候整頁不顯示（fail-secure）✅。

## 結論

**APPROVE-WITH-CHANGES**：2 個 MAJOR（M1、M2），兩個都是小而局部的修法，各附負對照；另有 13 個 MINOR。M1 需要 Rust 改一行，加測試。
