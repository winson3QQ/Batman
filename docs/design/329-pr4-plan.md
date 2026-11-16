# #329 PR 4 實作計畫 v0（骨架：基準、新範圍、事實；做法待寫）

上層設計：`docs/design/329-app-uiux.md`（v12.1）§12 第 4 列、§5.5（節點頁 5.1–5.8）、§4.8、§9 表情境 7 / 9、§4.3.6 X22–X24、:841。main = 4acddf6（PR 3 #341 已合併）。

## 0. 範圍：只做新的部分，已審過的行為照舊

**行為基準（已設計、已審、已合併；本 PR 不重新決定，審查也不重審）**：
- 離開網路：`docs/design/254-app-leave.md`（v4.1）；`leaveFlow` / `sendLeave` / `LeaveResult`（lib/member_ui.dart:246-300）；確認文字 Rust `leave_confirm_text`。
- 軟體更新：`docs/design/254-app-update.md`（v0.4）；`SwFlow` / `RustSwFlow` / `SwHold` / `SwUpdatePage`（lib/swupdate.dart，356 行）；舊控制台的 `_askSw`（nodes.dart:1590-1640）。
- 設定（國家、手機 Wi-Fi）：`docs/design/254-p3-impl.md` §3.3（settings/get、settings/set {2: country}、{20: {1: ssid, 2: passphrase}}）；Rust `request_settings` / `request_set_country` / `request_set_ap`（owner.rs:771-783、:1538-1541）；錯誤句 `error_text`（例：國家要先離開網路，代碼 11 原因 14）。
- PR 3 已合併的機制：`NodeLink.loginFor`、`HandoffProber`、`OwnerConsole`（`ConsoleReply`）、頁面佔用的做法（`openRawPage` 順序、`_pending`、`hold` / `pageGone`）、對話框 `_closeQ`。

**本 PR 新做的（審查範圍）**：
1. 節點頁下半的分組（設計 §5.5）：網路（PR 3 已有）、手機 Wi-Fi、軟體更新、更多。
2. 5.6 手機 Wi-Fi 頁（`SecureScreen`；名稱 1–32 位元組、密碼 8–63 可顯示 ASCII；送出後清空；目前值來自 settings）。
3. 5.8 國家頁（台灣 TW / 美國 US；目前值來自 settings；改變要確認；不改預設，U9）。
4. 5.7 更多：改暱稱（`UiState.setNick`，PR 3 已有）、國家、離開網路、技術資訊、從這支手機移除（PR 2 已有）。
5. 離開網路接到新頁面：新的「離開 controller」（session 佔用，設計 §12 第 4 列唯一新的寫入者）——行為照 leave v4.1。
6. 軟體更新換版面：`SwUpdatePage` 經 `loginFor` + `OwnerConsole`（或同等的 session）在新頁面下跑，整段持有佔用，套用後自己等節點回來（:841、§4.8）；首頁待辦「軟體更新還沒做完」（§4.8）。
7. 設定各頁（設計 §12「設定各頁」——待對設計 §5.x 逐列確認範圍）。

## 1. 事實（main 4acddf6；待補行號與證據）

| # | 事實 | 證據 |
|---|---|---|
| P1 | 舊控制台的設定：查看設定 / 設定國家 / 設定 Wi-Fi 都是 `_ask` 一個請求，回答只是顯示文字 | nodes.dart:1670、:1694、:1714 |
| P2 | Rust 的 settings 回答只有顯示用的句子（`settings_text`），沒有結構化欄位；新頁面要「目前值」就要一個新的 Rust view（新的介面，要審） | owner.rs:656、:960-961、:1716 |
| P3 | 離開網路已抽成 `leaveFlow(ask, askEnd, left, reread)`，舊控制台與隊員頁共用 | member_ui.dart:264-300；nodes.dart:1146-1150 |
| P4 | 軟體更新頁 `SwUpdatePage(hold, ask, onSetAp, channel, specifierText)`：`ask(waitMs)` 是「節點頁 owner session 上的一個請求（含重新登入）」 | swupdate.dart:86-104；nodes.dart:1590-1640 |
| P5 | `SecureScreen` 已存在 | lib/secure_screen.dart:11 |
| P6 | 狀態頁 `StatusPageView` 有 `onLeave` / `onSendUpdate` | member_ui.dart:345；nodes.dart:1125-1134 |

## 2. 做法 — 待寫（下一步：逐項讀基準，寫契約與佔用；先列和基準不同的地方）

## 3. 介面 / 生命週期 — 待寫

## 4. 和設計不同的地方 — 待寫

## 5. 安全 — 待寫（新輸入面：Wi-Fi 名稱 / 密碼、國家；密碼不進 log、不進 argv、送出後清空）

## 6. 步驟 — 待寫

## 7. 真機 — 待寫（離開網路可用目前在 bm-94676ef40105 的 04 / 02）
