# #329 PR 6 計畫 v2 — 第二輪獨立審查 D

審查對象：`docs/design/329-pr6-plan.md` v2（整份）。基準：`329-app-uiux.md` v12.1 + main c4905ed。只讀；證據都是本輪自己查的 `file:line`（路徑相對 repo 根）。

## 第一輪 MAJOR 是否已解

| 第一輪 | 狀態 | 說明 |
|---|---|---|
| A-M1 / B-M3 國家 | ⚠️ 大致解 | Revert 例外寫清楚了；但 join2 **往前**送的國家（netcfg key 5）也不是 app 選的，見 m5 |
| A-M2 / B-M1 代碼形狀 | ✅ 規則逐形狀寫了 | ASCII 段規則有副作用，見 m1 |
| B-M2 測法 | ⚠️ 方向對（fixture），機制沒寫，見 m3 |
| A-M3 英文來源 | ✅ Rust 端列全；Dart 端組的句子沒有測試，見 m4 |
| A-M4 重試半套 AppLink | ✅ 不加重試 |
| A-M5 / B-M6 R-7 | ⚠️ 要求抄進來了，但**做不到**，見 MAJOR-4 |
| A-M6 全隊頁 | ⚠️ 做了，但和凍結設計不符，見 MAJOR-1 |
| B-M4 文字紀錄 | ❌ B 的修法 (a) 明寫「顯示 `NodeLink.mask` 過的 `core.log`」，v2 把 mask 拿掉了，見 MAJOR-2 |
| B-M5 SSH | ✅ 取代語意、規則一致；指紋實作細節見 m6 |

## BLOCKER

無。

## MAJOR

### MAJOR-1　D5 全隊頁和凍結設計不符；N+1「只改一行常數」的契約做不到

- 情境：N+1 把 `WRITE_MESH_ADDR` 改成 true。field 版使用者打開節點頁 → 沒有「全隊」；dev 版進了 TeamPage → 內容停在進頁那一刻，不再更新。
- 證據：
  - 設計的入口在**首頁**「可以做的事」的「看全隊狀態」（329-app-uiux.md:703、:805），不是節點頁。
  - 設計把全隊頁當成和首頁同級的自動讀取頁：T12「首頁、全隊頁或節點頁在最上層…每 60 s 重讀一輪」（:51）、一輪的目標「首頁、全隊頁 = 這支手機的全部節點」（:380）、X27 O0 定義排除全隊頁（:475、:509）、生命週期列（:823）。但 `enum Page { home, node, other }`（app/lib/src/nodelink/core.dart:66）沒有全隊頁；計畫沒加，TeamPage 只能是 `other`（O0：不讀）。
  - D5 把 `teamView` 放在 `SessionProber._hint` 裡。`_hint` 第一行 `if (!hs.wanted(id)) return;`（prober.dart:254），`wanted` = `devTrust && page == node && pageNode == id`（app_link.dart:127-130）。所以 **field 版永遠算不到 team**；dev 版離開節點頁就不算。
  - 「同 updateHint 的生命週期」= `setPage` 換頁就清掉（node_link.dart:153-158），`setHint` 不在節點頁就丟（:114-115）。節點頁 → TeamPage 若呼叫 `setPage(other)`，team 被清，TeamPage 沒資料；若沒呼叫，節點頁的自動讀取繼續跑在 TeamPage 底下。計畫沒寫是哪一個。
  - `_hint` 在 `netId` 空或 `!netKnown` 時直接 return（prober.dart:255-260），舊的 team 留著：節點離開網路後全隊頁仍顯示舊卡片。「缺 / 舊」契約沒寫。
- 修法：照設計做：`Page.team`（或把全隊頁算成 home 的目標集合）、入口在首頁「可以做的事」且 `visible` 才出現；team 的計算不經 dev-only 的 `wanted`（另一個 `wantedTeam`：全隊頁在最上層，所有版本）；寫明離開網路 / 沒讀到時清掉。若要偏離設計（入口放節點頁、不自動讀），那是改凍結設計，要寫進設計並請使用者拍板。測試：field 版（devTrust=false）+ 假 `visible:true` → 首頁有入口、全隊頁在最上層時 60 s 讀一輪、離開網路後卡片消失；負向對照：把 team 放回 `wanted` 之後 → field 版 FAIL。

### MAJOR-2　D4 文字紀錄沒遮罩：原始 `core.log` 有完整節點 ID 與藍牙位址；設計的事件也不在裡面

- 情境：維修人員在 dev 版按「複製」把紀錄貼到聊天軟體。
- 證據：
  - `core.log` 的行：`'$a -> ...'`，`Attempt.toString()` = `'$addr×$id'`（core.dart:56、:434、:695），還有 `round … ${targets}`（:343）、`end {id: …}`（:578）、`loginFor $id`（:637）——**完整藍牙位址與完整節點 ID**。
  - 現有 logcat 轉送一律先過 `NodeLink.mask`（node_link.dart:78-80、:91），把 ≥ 8 位 hex 與 MAC 改成「…後四碼」；設計資源表寫「`NodeLink` 自己新增的行只有時間、種類、後四碼」（329-app-uiux.md:342、:887）。
  - B-M4 的修法 (a) 原文就是「顯示 `NodeLink.mask` 過的 `core.log`」；v2 D4 寫「內容只有時間、節點 ID、結論種類…不含秘密」，事實不對，T6-12 / D4 的「不含 ≥ 32 hex」也抓不到 12–18 字元的 ID 與 MAC。
  - 設計要求寫進文字紀錄的安全事件：身分不符（:411）、420 s 收回佔用（:576）、寫入失敗（:607）。只有身分不符會以 `-> certRejected` 出現在 `core.log`；佔用收回（registry）與 RecordWriter 寫入失敗都不經 `core._log`（`grep _log( app/lib` 只有 core.dart）。
- 修法：頁面與複製都經 `NodeLink.mask`；測試：假 log 行含完整 ID + MAC → 畫面與剪貼簿只有「…後四碼」，負向對照拿掉 mask → FAIL。佔用收回與寫入失敗：要嘛接進 `core.log`（一行，經同一個 mask），要嘛把「本版文字紀錄不含這兩類」寫進 #329 checklist 並說明。

### MAJOR-3　刪 NodesPage 會丟掉「忘記加入中的節點」的唯一出路（設計 10.2 的項目也漏了）

- 情境：節點 X 在建網 / 加入時中斷（net 紀錄裡它是 joining），之後 X 壞掉，使用者用 T17「從這支手機移除這台節點」刪掉 `node/X`。net 紀錄裡 X 的 joining 項目永遠留著。
- 證據：
  - 新 UI 的待辦 / 「放棄這次加入」只列 `mine.contains(m.deviceId)` 的項目（app/lib/src/flows/net_index.dart:213-221），T17 只刪 `node/<id>`、不碰 net 紀錄（app/lib/ui/more_pages.dart:82-102）→ 這個項目在新 UI 沒有任何入口。
  - 舊控制台 `_forgetJoiningBody` 對**所有**網路裡所有 `forgettable` 的項目都能忘記，不看手機有沒有 `node/<id>`（app/lib/nodes.dart:1251-1296），dev 版還多「排除這台（換密碼）」。
  - 設計 10.2 開發者選項明列「忘記加入中的隊員」（329-app-uiux.md:634、:790）。計畫 F2 說「舊控制台的功能在新畫面都有，除了 SSH / 原始設定 / 全隊」——不成立。
- 修法：開發者選項加「忘記加入中的節點」頁：列所有 net 紀錄裡 `forgettable` 的項目（不限 `mine`），走現有的 `forgetJoining`（owner_console.dart:679）在 session 佔用下；dev 版保留「排除這台」入口（接 remove_pages 的排除）。測試：net 紀錄有 joining 項目但沒有 `node/<id>` → 頁面列得到、按忘記後紀錄裡沒有；負向對照：加回 `mine` 篩選 → FAIL。同時把 F2 改正。

### MAJOR-4　R-7 真機計畫照現況做不到

- 證據與情境：
  1. **dev3 不是 repo 裡的 flavor**：android/app/build.gradle.kts:57-77 只有 dev / dev2 / field；記憶寫 dev3 是「臨時 flavor，只在一次性 worktree 建，未 commit」。計畫要 dev3 跑 PR 6 的隊員端（情境 2 / 3 / 6）和新 SSH 頁還原 02，等於要用一個沒進 PR 的 gradle 改動另外 build——驗證的產物不是 PR 的產物，計畫沒寫。
  2. **情境 2「當面」= QR 互掃**（設計 :801），dev 與 dev3 在同一支手機上無法互掃；顯示碼的頁面禁止截圖（設計 :802 T10），也不能把 QR 丟到電腦上顯示。計畫的情境 2 實際只能走文字，和情境 3 相同，沒有標 ⚠️ / ❌。
  3. **「每條各做一次節點重開」**（設計 :980）× 8 條情境：誰、怎麼重開（拔電要使用者在場；SSH reboot 要 lab key，02 目前沒有）不在「副作用 + 還原」清單裡。
  4. **順序**：情境 8「02 國家設 US」要節點不在網路（reason 14，owner.rs:1777 測試字串）；排在情境 2 / 3（02 已加入 04）之後、沒有先離開就會被拒。情境 3「先讓 02 離開再走一次」靠 `replaces_approved`（approve.rs:126-131）才不會 `AlreadyMember`，計畫沒寫預期會看到的確認畫面。
- 修法：(a) 02 的 lab key **現在**就用 dev3 已裝的舊 build（67e7a83，還有舊控制台）加回，刪舊控制台前完成，R-7 不再依賴 dev3 的新 SSH 頁；(b) 隊員端改用 repo 裡的 dev2：要嘛讓 dev2 認領一台（需重燒，使用者決定），要嘛明寫「dev3 + 臨時 flavor，產物差異只有 gradle 一段」並附 diff；(c) 情境 2 的 QR 段標 ⚠️「單手機做不到，只走文字」或請使用者準備第二支手機；(d) 寫出場次順序表（2 → 3 → 6 → 02 離開 → 8 → 9 → 7），每條的「節點重開」方式列進副作用清單一次取得同意；(e) 「正在連到節點…」秒數的證據來源（BMAPP logcat 時間戳）寫明。

## MINOR

1. **D7 ASCII 段規則會藏掉使用者資訊**：`（{c} MHz）`（owner.rs:684）、`（v{stored}）`（member.rs:262）、`操作（{v}）`（owner.rs:637）整組被移走。巢狀括號（join_pages.dart:629 把 Rust detail 包在 Dart 的「（…）」裡）、多行（join_pages.dart:642 `\n` 串兩句）規則沒定義。修法：ASCII 段只在含「代碼 / 原因」的括號裡才移；巢狀由內而外；多行逐行。語料加這三種。
2. **T-C4c-src 有漏洞**：`plain(s) => screenText(s)`（net_pages.dart:42）這類包裝、以及先 `_line = screenText(...)` 再 `Text(_line)` 的寫法，grep `screenText(` 抓不到；member_ui.dart:27、:519 仍在新畫面用（more_pages / team_pages import），計畫的允許清單沒有它。修法：把 `screenText` 改成只有 say.dart 內部用（library-private 或 lint），測試改成「新畫面所有顯示 Rust 句子的 Text 都是 SayLine」的 widget 斷言。
3. **D7a 語料機制沒寫**：句子函式大多是模組私有（`settings_text` owner.rs:674、`error_text`、`replay_next` pub(crate)），分在 bridge 與 batman-proto 兩個 crate；`test-all.sh` 用 field 與 dev-trust 兩種 feature 各跑一次（app-tests.yml:3-4），若有 feature 相關的句子，兩次輸出不同、必有一次 FAIL；`UPDATE_CORPUS=1` 與平行測試同寫一檔會互蓋。路徑用 `env!("CARGO_MANIFEST_DIR")` 而不是 cwd。完整性：只有「改一句沒更新 → FAIL」，**新增**一句不會被要求進語料——加一條 Rust 測試掃原始碼裡含「代碼」的 `format!`/字面量，數量對不上語料就 FAIL。
4. **Dart 端組的句子沒有測試**：claim.dart:172、:236、:306、:496、net_run.dart:217、:384、offline_op.dart:181、join_pages.dart:103 等 D8 要改的 Dart 字串不在 Rust 語料裡。每類各一條 widget 測試（丟例外 → 主畫面沒有英文、技術資訊有）。
5. **D11 的保證還差一條**：join2 往前送的國家是 netcfg key 5（join2flow.rs:8-11、:427；netrec.rs:136 只檢查是文字），來自隊長簽的紀錄，沒有限定 US。被入侵或舊版的隊長 → 隊員節點被改成非 US（使用者會看到確認，但不知道不對）。修法：join2 對 key 5 ≠ "US" fail-closed，或把這條寫進保證的例外。另外 Revert 送 `prev_country` 已有測試（app/rust/batman-proto/tests/join2flow.rs:618、:658 JP），「加一條」可改成引用它。
6. **D2 指紋**：Dart 沒有 sha256 / base64 套件（app/pubspec.yaml 只有 flutter_rust_bridge、flutter_reactive_ble）；放在 Rust（batman-proto 已有 `sha2 =0.11.1`）避免新相依。節點 regex 收的 base64 不一定解得開（長度 / padding），寫明解不開 = 不送（比節點嚴）。
7. **D9 非某台那一列**：取「最新的 readWall」但有不新鮮的就寫「上次讀取」，可能把一個新鮮的時間標成「上次讀取」。改成「全部新鮮 → 讀取於 最新；否則 → 上次讀取 最舊的那台不新鮮讀取」，T6-7 加這一例。
8. **T6-5 負向對照不夠**：只有拿掉 soft 警告。加「複製內容多一個非白名單欄位（完整 ID / netId）→ FAIL」。
9. **舊啟動頁失去後備**：field 版在 `NodeLink` 起不來時原本有「我的節點」（main.dart:313-316）。`start` 只做 `listNodes`（app_link.dart:143），啟動檢查剛剛才成功列過同一個目錄（main.dart:125-128），所以多半是暫時性；把這個推論寫進 D1 當證據即可。
10. **全隊頁真機路徑**：本版 `visible` 永遠 false，T6-13 只有假資料；PR 說明要標 ⚠️「真機不可達」。
11. **R-7 與 main 對照的安裝方式**：main 的 dev build 與 PR 6 的 dev build 同一個 applicationId，換裝要 `adb install -r`（版本較低要 `-d`），寫明不准用 flutter install（記憶規則）；情境 7 的 OTA image 從哪裡來寫明。
12. **D3 名稱**：`settings_text`（owner.rs:674-691）是四個欄位的摘要，不是原始內容；頁名「查看原始設定」會讓維修人員以為是全部。改「查看節點設定（摘要）」或在頁面寫明只有這四項。

## 查過、沒有問題

- `StatusView.tech`（statuspage.rs:427-497）：沒有密碼或金鑰；`uci_staged` 只是設定檔名（status.go:222；p3review_test.go:114），節點字串都過 `shown`。D6 白名單可行。
- `settings_text` 不含 AP 密碼（節點不回）。
- SSH 規則與節點一致（node.go:752、:839-872）。
- `requestSetCountry` 的 Dart 呼叫點只剩 `OwnerConsole.setCountry`（owner_console.dart:572）一處，閘門放那裡夠。
- 首頁時間現況與 F7 描述相符（home_page.dart:283-286、:315；home_logic.dart:146-160）。
- 舊控制台其他功能在新 UI 都有對應（更新包貼上 = join_pages.dart:597-751；檢查網路、把新密碼送給節點、再顯示申請、T17），除了 MAJOR-3。

## 計數與判定

BLOCKER 0 / MAJOR 4 / MINOR 12

**APPROVE-WITH-CHANGES**——方向對、第一輪多數已解；MAJOR-1（全隊頁偏離設計、N+1 契約做不到）、MAJOR-2（紀錄頁沒遮罩，B-M4 的修法被拿掉）、MAJOR-3（刪舊控制台丟掉忘記孤兒 joining 項目的出路、10.2 漏項）、MAJOR-4（R-7 依賴未 commit 的 dev3、單手機做不到 QR、重開方式與順序未列）修完後整份再審一輪。
