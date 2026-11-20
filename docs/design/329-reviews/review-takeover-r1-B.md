# 329-takeover v1 — 設計審查 r1-B

對象:`docs/design/329-takeover.md` v1(main 99d156a)整份。獨立審查,未讀其他審查者檔案。
方法:只讀原始碼對照(`app/lib/src/nodelink/*`、`app/lib/src/flows/op_session.dart`、`app/lib/ui/*`、`rust/batman-proto/src/statuspage.rs`)。未跑測試、未碰任何裝置。
標示:✅ = 我在原始碼看到的;⚠️ = 推論,未執行驗證。路徑省略前綴 `app/`(Rust 除外)。

---

## §1.1 接手進行中的 attempt

### F1 — MAJOR:`acquire` 先取消 round 才等 attempt,接手到的讀取結果會被丟掉;park 是否仍成立設計沒講

- 情境:節點頁 round 的 attempt 正在登入 → 使用者點「手機 Wi-Fi」→ `acquire`。
- 證據 ✅:`lib/src/nodelink/node_link.dart:360` `core.acquireLease(now())` 在 `:369` `_abort()` 之前;`lib/src/nodelink/core.dart:285-290` `acquireLease` 先 `_cancel` round 再設 lease。新的「等 attempt」若放在現在 `_abort()` 的位置,body 回來時 `_round == null`:
  - `core.result`(`core.dart:523`)round 為 null 回 false;
  - `core.keptRead`(`core.dart:603-625`)需要 `_round?.t[id]`,同樣回 false → 狀態、isY、lastSeen 都不記;
  - 現行 park 條件(`node_link.dart:1051`)含 `!accepted` → 連線被銷毀。
- 後果:若 park 仍看 accepted,§0 的主場景(點子頁)完全沒有被修到,T3 不可能過;若 park 不看 accepted,則 park 了一條「讀取結果被丟掉」的連線(狀態頁沒更新、`readWall` 沒寫),§3 契約「false: nothing recorded」與「link parked」兩句互相矛盾。
- 修法(擇一並寫明):(a) 把「等 attempt」移到 `core.acquireLease` 之前(round 還在,`core.result` 正常接受,park 走現行路徑,不需新分支);或 (b) 明文「park 與 taken 無關,只看 `wanted` + keep」,並說明丟掉的 body 何時補讀。建議 (a),改動最少。T3 必須斷言「狀態有記 + 連線被借出」兩件事;負對照 = 等待放在 `acquireLease` 之後時 T3 FAIL。

### F2 — MAJOR:兩個 `acquire` 同時等同一個 attempt(Wi-Fi → 返回 → 國家)

- 情境:點「手機 Wi-Fi」(`WifiPage.initState` → `_read` → `OpSession.once`)→ 0.5 s 內返回 → 點「國家」。兩個 `acquire` 都卡在新的 ≤8 s 等待。
- 證據 ✅:忙碌檢查 `if (reg.current != null) return null`(`node_link.dart:359`)在所有 await 之前,等待期間 lease 還沒登記,第二個 `acquire` 不會被擋。`OpSession.once`(`lib/src/flows/op_session.dart:92-134`)只在 acquire 前與 login 後(`:112`)檢查 `gone()`。
- 後果 ⚠️:先 resume 的是已 dispose 的 Wi-Fi 頁 → 它拿到 lease、用掉 park 的連線做 login,然後才發現 gone 放掉;國家頁 `reg.acquire`(`lib/src/nodelink/lease.dart:135-140`)回 null → 顯示「另一個操作還在進行:手機 Wi-Fi」。今天這個視窗只有 `_dropAll` 的短暫等待,新設計把它拉長到 8 s,而且正好落在任務指定的快點路徑上。§4 矩陣沒有這一列,§7 沒有測試。
- 修法:`acquire` 入口設「等待中」旗標(第二個呼叫直接回 busy 或排在後面,二擇一寫明);並在 `OpSession.once` acquire 回來後重查 `gone()`,gone 就立即 release 不 login。加測試:兩個 acquire 交錯,後到且仍 mounted 的頁面拿到連線或得到正確的 busy 文案;負對照 = 沒有旗標時後到者 busy、連線被 gone 的頁面用掉。

### F3 — MAJOR:「最多 8 s(msg2,attempt 自己的預算)」不是 attempt 的上界

- 證據 ✅:
  - 連線前 `_makeRoom` 最多 60×100 ms = 6 s(`node_link.dart:716-735`);
  - `due` 計時只管到 msg2:`lib/src/nodelink/prober.dart:130-132` `!gotMsg2` 才給 noResponse;msg2 之後另有 `answerMax` 20 s(`prober.dart:233`)+ hint/team 2 s(`_answered`);
  - 結束時 `await mine?.close()` 最多 5 s(`node_link.dart:1034`,`lib/src/nodelink/ble_gate.dart:123-148`)。
  - 所以 attempt 最壞 ≈ 6 + 8 + 20 + 2 + 5 s,不是 8 s。§5「1.5–4.5 s 結束」只是順利路徑。
- 後果:(1) `acquire` 的等待必須是自己的計時器(從 acquire 呼叫起算 8 s),設計寫成「attempt 自己的預算」會被實作成等 attempt 結束 → 最壞 ~40 s 卡在「確認中」。(2) attempt 還在 `_makeRoom`(尚未 connect)時等 8 s 是純損失,比今天慢。(3) `_pump` 分離後 `_attempt != null` 期間不開新 attempt、不做 kept read(`node_link.dart:911, 928`)→ 新頁面的 round 最壞被卡 ~30 s(今天是立刻 abort)。
- 修法:寫明 acquire 的等待是獨立的 8 s 上限、逾時即 `_abort()` 走今天的路;只有「已開始 connect」的 attempt 才等/分離,還在 `_makeRoom` 的照舊 abort;分離的 attempt 給一個總時限(例如 msg2 後沿用 `answerMax`,明寫數字)逾時 abort。測試:msg2 後節點不答 → acquire 在 8 s 回來且 attempt 被 abort;`_makeRoom` 階段 acquire → 不等。

### F4 — MINOR:`_pump:900` 不只在換頁時觸發,分離範圍比設計說的大

- 證據 ✅:`node_link.dart:900` `if (a != null && !identical(core.running, a)) _abort();` 也會在 cap 截斷(`core.dart:640-665`,`r.running = null`)與 `refresh` 取消 early round(`core.dart:337-343`)時成立。
- 後果 ⚠️:這兩種情況下 attempt 也會改成分離而不是 abort;cap 截斷的「不算試過」記帳與 90 s cap 的意義會變。
- 修法:分離只限 `setPage` 造成的取消(由 `setPage` 傳旗標),其餘維持 abort;或明文接受並各加一個測試。

### F5 — MINOR:attempt 結束的通知必須涵蓋 `_run` 的每個出口

- 證據 ✅:`_run` 有提早 return(`node_link.dart:999` `_makeRoom` 後)與被取代 return(`:1036`),`_abort`(`:1060-1069`)也會結束 attempt。§3 只寫「`_run` completes」。
- 後果:任何一個出口沒 complete,`acquire` 就白等 8 s。
- 修法:用 `try/finally` 完成 completer,`_abort` 也完成;T7 加上這兩個出口。

### F6 — MINOR:分離 attempt 的非 body 結果與「不 keep 的 body」未定義

- 證據 ✅:`keptRead` 支援 errorCode(`core.dart:603-625`);keep 只在 `Res.body && keepFor(id)`(`prober.dart:182-186`);`keepFor`(`node_link.dart:113-120`)在已有 kept 或滿 `keptMax=2`(`:619`)時為 false。
- 修法:寫明 errorCode / refused 在分離時是丟掉還是記錄;body 但不 keep(T13)時 body 是否仍記(建議記,連線照舊關閉)。

### F7 — MINOR:`wanted` 沒含 lease 狀態;紀錄被移除後不會立刻收掉

- 證據 ✅:`released` 的 `:865-873` 分支 `setRecords` 後不 `_pump`;分離 attempt 的紀錄若此時被移除,要到 `_run` 結束才因 `wanted` 為 false 被丟。可接受,但矩陣「record removed」列應寫明「attempt 跑完才丟,不 park」,並說明 lease 持有期間(update/claim)分離 attempt 結束時不得 park(`core.blocked`/lease 檢查)。T10 要涵蓋 lease 持有中結束的情況。

---

## §1.2 SettingsMemo

### F8 — MAJOR:把舊的 AP 名稱預填進可編輯欄位,讀取失敗時會被原樣送回節點

- 情境:另一支手機把節點 A 的 Wi-Fi 名稱改了;本機 memo 還是舊名。進「手機 Wi-Fi」→ 預填舊名 → 這次讀取失敗(節點暫時連不到)→ 使用者只改密碼按送出(稍後連上)。
- 證據 ✅:`lib/ui/settings_pages.dart:133` `if (_ssid.text.isEmpty) _ssid.text = v.apSsid` — 欄位非空就不會被新讀值覆蓋;`_ssidEdited`(`:99, :195`)只在使用者打字時設。今天讀取失敗後仍可送出,但名稱是使用者自己打的;預填後變成 App 自己放進去的舊值。即使讀取成功,`:133` 也不會用新值換掉預填的舊值。
- 後果:舊名稱靜默覆蓋別人剛改的名稱(全隊手機要重連 Wi-Fi)。這是設計自己列的「錯值風險」,但 W 測試沒有蓋到。
- 修法:memo 只用來「顯示」(標「確認中」的唯讀文字),不寫進 `_ssid` controller;新讀值到了才填欄位。或:預填時記 `_fromMemo`,新讀值到且 `!_ssidEdited` 一律覆蓋,讀取未成功前送出鈕不可用。加測試 + 負對照(memo 舊值、讀到新值 → 欄位是新值;讀取失敗 → 不能把 memo 值送出)。

### F9 — MINOR:memo 有兩個寫入者,且 NodeLink 要認識 UI 的快取

- 證據:§2 寫「pages write」,§1.2 又寫「NodeLink 的紀錄檢查時丟掉條目」。兩個寫入者;NodeLink 反向依賴 UI 層。
- 修法:讀取時檢查 `core.states.containsKey(id)`(唯讀),不存在就當沒有;NodeLink 不碰 memo。擁有者 = 設定頁,一個。

### F10 — MINOR:必要性沒有數字

- 1.1 做完後,子頁第一次讀取走借出的 kept link,應接近 0.1 s + 一次讀取。§0 的重現數字是 1.1 之前的。依「只做必要的修改」:先實作 1.1、量子頁「確認中」的時間,仍明顯才加 1.2;或在設計裡給 1.1 之後的預估並說明為何仍不夠。
- 另:國家頁 `_blocked()`(`settings_pages.dart:307-314`)以 `_cc != null` 當閘;memo 絕不可寫進 `_cc`(W3 有,保留並附負對照)。memo 含 AP SSID,`WifiPage` 是 SecureScreen、`CountryPage` 不是 → 寫明 memo 的 SSID 只在 WifiPage 讀。

---

## §1.3 `Verdict.note`

### F11 — MAJOR:首頁文字叫使用者「點進去看」,但那一列沒有動作、多台時未定義、過期讀取未設閘

- 證據 ✅:`lib/ui/home_logic.dart:171-172` row 14 = `Look.ok`、`HomeAction.none`;row 12(`:155-160`)今天靠 `warning.isNotEmpty` 抓到這種情況並給動作。`nodeRowWords`(`:179-217`)回 (look, sentence, meta),沒有放小字的位置。`lib/ui/node_page.dart:210-217` 只在 `n.fresh` 時顯示 `v.warning`。
- 缺口:(1) H 規則換了 row 14 文字卻沒說 action → 文字說可點、實際不能點;(2) 兩台以上、其中一台/多台有 note 時 hero 文字與指向哪台未定義;(3) 列上小字與 hero 是否只看 fresh 的讀取沒寫 → 過期的 note 會一直掛在首頁;(4) 列的資料結構要加欄位沒寫。
- 修法:規則寫成「所有 fresh 節點都 ok 且至少一台 fresh 的 note 非空 → Look.ok、文字 X、action = 開該節點(多台 → 第一台/列表)」;列小字只在 `fresh`;寫出 `nodeRowWords` 的新回傳欄位。測試:H 加「多台」「note 但讀取過期 → 不顯示」「action 可點」;負對照 = 沒有 fresh 閘時過期測試 FAIL。

### F12 — MINOR:`warning` 的讀者與釘住舊行為的地方沒列全

✅ grep 結果,設計需逐項列入改動清單:
- 讀者:`lib/ui/home_logic.dart:155,158`;`lib/ui/node_page.dart:213`;`lib/ui/more_pages.dart:192,211`(`⚠️ ${f.warning}`);`lib/ui/member_ui.dart:186`(`StatusFields.warning`,需要對應的 `note`);Rust 橋 `rust/src/api/owner.rs:461, 2579`;產生碼 `frb_generated.rs:3250, 4000`、`lib/src/rust/api/owner.dart:663, 701`。
- 釘住舊行為的測試:`rust/batman-proto/tests/statuspage.rs:390`(斷言 `warning == Some(WARN_JOINED_CRIT)`)、`rust/src/api/owner.rs:2792`。
- `StatusView` 加 required 欄位 → 約 20 個 Dart 測試檔的建構式要補(`test/ui/home_logic_test.dart:9,135,172-174`、`more_pages_test.dart`、`retest_p_uistate_lock_test.dart:135`、`kept_link_test.dart:90`、`fake_node.dart:111` 等)。建議在 Dart 包一層預設值或明列這是機械改動。
- 文件:`docs/design/254-app-status-page.md`、`docs/design/329-honest-errors.md` 釘了舊文字與 row;D 項要點名這兩份。
- ✅ §5「App 以外沒有東西解析 warning 文字 — 待查」:我 grep「節點回報異常」只出現在 `statuspage.rs`、其測試、上述兩份文件;harness/Dart 測試沒有。這條假設成立,請把證據回填。

### F13 — MINOR:兩個沒寫出來的行為變更

- ✅ `rust/batman-proto/src/statuspage.rs:314-336` `warning()` 是 first-match(POWER → HOT → AP → JOINED_CRIT):今天電源/過熱警告會蓋掉 joined-crit。改成獨立的 `note` 後兩者會同時出現,節點頁 `next` 多一行(`retest_p_layout_test` 類的版面測試要看)。寫明是刻意的,或維持「有 warning 就不出 note」。
- ✅ NOTE 文字把 `WARN_JOINED_CRIT`(`statuspage.rs:122-125`)的「請到這台節點的『手機 Wi-Fi』設定」改成「請用這台節點的…」。這是文案變更,設計沒列;列出或維持原文。
- 「矛盾」措辭(§0:綠色卻說異常)修法方向對;確認 note 文字本身不含「異常」。

---

## 安全

- 分離的 attempt 仍由同一個 probe 完成認證,park 只在 `Res.body` 之後;重放位址的鄰近裝置登入失敗 → 不 park(T12)。✅ 與現行路徑相同,無新增面。
- 被攻陷的節點:`note`/`warning` 是 Rust 內建常數字串;memo 值來自 `SettingsView`(已過 `statuspage::shown`,`lib/src/rust/api/owner.dart:571-574`)。攻陷節點可回報假 AP 名稱 → 配合 F8 會被預填並送回,但只影響它自己。無越權。
- 另一支手機:見 F8(舊值覆蓋)。這是本設計唯一新增的對外寫入風險。
- 自己的錯誤:F2(兩個 acquire)、F5(漏 complete → 卡 8 s)。
- memo 只在記憶體、不落地、不進 log:✅ 設計有寫;加一條測試/lint 確認 memo 值不進 `log?.call`。

## §7 測試缺口(每項都要負對照)

1. T3 依 F1 定義清楚(狀態有記 + 連線借出)。
2. 兩個 acquire 交錯(F2)。
3. msg2 後不回答、`_makeRoom` 階段、attempt 總時限(F3)。
4. cap 截斷 / `refresh` 時的 attempt(F4)。
5. `_run` 各出口都通知等待者(F5)。
6. lease 持有中(update/claim)分離 attempt 結束 → 不 park(F7)。
7. memo 舊值不會被送出;新讀值覆蓋預填(F8)。
8. note:多台、過期讀取、action、與 power/heat warning 並存(F11、F13)。
9. D4「使用者目視」不是測試;改成 widget 測試斷言文字,目視另列為現場確認。
10. 矩陣缺列:背景化發生在 acquire 等待中(`core.fg` false → 結束時不 park,acquire 應立即放棄);藍牙在等待中被關(`core.blocked`);兩台節點其一連不到時分離 attempt 佔住 `_attempt` 對另一台的延遲。

## 基準行為

未發現本設計破壞 `329-link-per-node.md` 的「每台一條連線 / `keptMax=2`」不變式,前提是分離 attempt 的 park 仍走 `node_link.dart:1051` 的所有條件(`_kept.containsKey`、`keptMax`、`core.fg`、`core.blocked`)。⚠️ 這是讀碼推論,沒有執行。`329-honest-errors.md` 的 row 12/14 文字會被 §1.3 改動,需同步(F12)。

## 結論

**REJECT(修訂後整份重審)**

未結 MAJOR:F1、F2、F3、F8、F11。方向(分離取代 abort)可行,且 F1 的修法 (a) 可讓 §1.1 更小;但目前的文字在主場景(點子頁)上自相矛盾,實作者會做出兩種不同結果。建議 v2:§1.1 依 F1(a)/F2/F3 重寫等待的位置、上限與單一等待者;§1.2 先降為「只顯示、不預填」或延後到量測之後;§1.3 補齊 hero/列的規則與讀者清單。

未做 ❌:未執行任何單元測試;未上真機;F2、F4 的後果為讀碼推論(⚠️),未以測試重現。
