# #329 PR 6：刪掉的舊控制台測試 → 對應 / 移植（plan §7「既有」，code review A-1）

來源：stream Y1（94146c7）的對照、整合 commit（61d9549、229490d）、Y2（669cefb）的移植。行號是 Y1 當時（94146c7）的位置；之後的 commit 可能讓行號移動幾行，以測試名稱為準。

## 測試庫

- `test/nodes_update_send_test.dart` 的假節點庫搬到 `test/support/fake_node.dart`，10 個檔的 import 改過去。

## nodes_update_send_test 自己的測試（刪除）

| 原測試 | 處理 | 對應 |
|---|---|---|
| S3 / T-N2（只有 mnet、沒有網路紀錄、mpend、只有 net、兩者都有 ×2） | 已有對應 | join_choice_test.dart:7、:11；net_index_test.dart:61；net_form_member_test.dart:110、:121、:131 |
| PR3-1 consolePaths（每一列） | 已有對應；防漂移表劃掉（plan §3 I2） | flows/owner_console_test.dart:242 |
| r3 E-M1（我的節點在登入中被關 → 之後登入成功要丟掉連線） | 已有對應 | flows/net_run_test.dart:307、:318；op_session_test 的 gone 系列 |
| T30（匯入更新包後不自動送） | 已有對應 | ui/join_pages_test.dart:480（:501「T30: no send without the yes」）；flows/rekey_send_test.dart:199（原始碼檢查） |
| T30（狀態頁那一臂） | 已有對應 | ui/node_team_test.dart:91（R17） |
| T19（移除隊員後不自動送） | 已有對應 | ui/team_pages_test.dart:378（P19 → 8.4）+ rekey_send_test.dart:199 |

## nodes_zero_test（2 條，S20 上真的發生過的 z 歸零）→ 移植

- join_pages_test 的假 ECDH 改回 `asUnmodifiableView()`（和 S20 一樣唯讀 buffer）；:398（同意碼匯入）、:480（更新包匯入）斷言 z 歸零。新路徑本來就用 `ownCopy`，沒有 bug。負向對照：拿掉 `ownCopy` → 4 條 FAIL（`Actual: [7, 7, 7, ...]`）。

## pop 類（nodes_pop、nodes_paste_pop、nodes_persist_pop）→ 移植到 ClaimPage

- claim_flow_test.dart:383「pop ported」：認領中按返回，之後的紀錄寫入都在原始佔用下。負向對照：`rawUse => null`、`pageGone` 立刻釋放 → 都 FAIL（`Expected: contains 'write node/...:新增節點' Actual: []`；沒有佔用時認領整個停掉）。
- ⚠️ 「按返回後不再送」不適用 ClaimPage（設計上按返回後工作照常跑）；session 頁面的對應：net_run_test:307 / :318、op_session_test。

## key_gate_test（整個檔依賴 NodesPage）→ 刪除，拆成

- pr6_dev_test.dart「key gate ported」（:507）：`makeNetworkRefusal` 即時讀 keyLevels，句子同舊的，不問 publicKeys / signAdmin；含全部符合的對照組。負向對照：回 null → 3 條 FAIL。
- 已有對應：owner_console_test.dart:400（拒絕 → notSent）、:383（Kotlin 拒絕 signAdmin → keyError，不寫紀錄）。

## key_abilities_test

- :338（舊版控制台那一列）刪除（T6-1 取代）；:633（NodesPage 的登入閘門）刪除 → 已有對應 nodelink/login_for_test.dart:179。
- 啟動頁的斷言改成 D1 規則（沒有「我的節點」、「附近的節點」只在 devTrust）。

## pages_test:275 → 改寫成 T6-1

## member_ui_test（刪除的部分）

| 原測試 | 處理 | 對應 |
|---|---|---|
| T8 狀態頁版面 / 重新整理 / E_RATE / 讀取中再按 | 已有對應 | more_pages_test.dart:90、:101；pages_test.dart:340；home_logic_test.dart:173；nodelink/core2_test.dart:388（X2）；core_test.dart:195（2'） |
| ReadClock / readTime | 跟程式一起刪 | 新首頁時間 = D9 `heroTime`（T6-7） |
| S6 離開網路 widget（7 條） | 已有對應 | more_pages_test.dart:111、:196、:229、:253、:264、:276 |
| 「連按兩下只開一個對話框」 | ⚠️ 沒有直接對應 | 新頁面靠 `_running` 與佔用（op_session_test.dart:101 第二個要求回 busy） |
| T9 版面 | 已有對應 | layout_test.dart:233（T-C2） |
| S6 移除隊員的送出按鈕 | 已有對應 | node_team_test.dart:91 |
| team section 兩條（隱藏 / 卡片位置、未加入那一行） | Y2 移植 | team_status_page_test.dart :69、:92 |
| T-A9 全隊不進紀錄（兩條，含負向對照） | Y2 移植 | team_status_page_test.dart:154 |

純函式測試（leaveFlow、stepFrames、SendTrack 等）保留在 member_ui_test。

## rekey_send_test / member_ui_test 的 nodes.dart 掃描排除

- 拿掉（檔案已不存在）。
