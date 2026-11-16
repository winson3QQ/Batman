# #329 PR 1 第 7 輪程式碼審查(審查者 M)— commit 02eeab3

範圍:`git show 02eeab3`(feat/329-pr1,父 a0f3fbb)。改 `app/rust/batman-proto/src/swupd.rs` 的 `on_status` 三個「讀不到節點的狀態」分支的 `tech` 字串,加測試 `a13_status_unread_names_its_cause_and_nothing_else`。

**Verdict:APPROVE-WITH-CHANGES**(0 BLOCKER / 0 MAJOR / 4 MINOR;MINOR 可在本 PR 一併改或寫進 #329 checklist)

## 從實際使用出發:這個改動在現場做了什麼

S20 + 04/02 在「已認領但沒入網」時,`status` 每次都回 `{15: {stale: true}}`。改動前操作員只看到「讀不到節點的狀態 — 請重新整理」,三種原因(stale、錯誤碼、沒回應)無法分辨。改動後「技術資訊」(收合的 ExpansionTile)會多一行固定字串或 `status: code <十進位數>`。畫面文字、按鈕、重試次數、走到哪個畫面都**沒變**。

注意:這只是**診斷**,不是 A13 的修正。未入網節點 status 永遠 stale → 永遠無法準備更新,這個根因仍在(見 m4)。

## 逐項查核(附出處)

1. **秘密 / 節點內容能不能進畫面?** 不能。
   - `Reply::Err { code, .. }`(swupd.rs:901)丟掉 `detail`,只 `format!("status: code {code}")`;`code` 是 `u64`(swupd.rs:417 `Err { code: u64, detail: Value }`),`{}` 格式化只會產生 ASCII 數字,惡意節點選任何 code 都只能得到最多 20 位數字,無法注入文字或 bidi 字元。
   - `Gate::Unread`(swupd.rs:891)、`_`(swupd.rs:902)是常數字串。
   - `decorate`(swupd.rs:686-691)只會附上 `self.trust`,那是 `gate()` 驗過的 16 位 hex(swupd.rs:318-327),不是新的面。
   - 對照既有的 `tech(code, &detail)`(swupd.rs:1223-1228)本來就把 code 與 reason 數字放進技術資訊,這次暴露的是同一類資訊、更少。
2. **分支行為有沒有變?** 沒有。diff 只動 `screen(...)` 的第二個參數;`Reply::NoLink`(swupd.rs:899)仍在 `Reply::Err` 與 `_` 之前,仍給 `T_NOT_BACK` 與空 tech;`Reply::Err { code: E_RATE, .. } if status_tries < TRIES`(swupd.rs:895)仍在新加的 `Reply::Err { code, .. }` 之前,守衛不變,所以 E_RATE 重試次數不變。`Reply::Ok` 一定走第一臂,`_` 實際只剩 `Reply::Lost`。
3. **E_RATE 重試用完後**:落到 swupd.rs:901,畫面 =「讀不到節點的狀態 — 請重新整理」+ tech `status: code 12`(E_RATE = 12,flow.rs:18)。可以接受(使用者的動作就是重新整理),但測試沒涵蓋(m2)。
4. **NoLink 仍是 T_NOT_BACK**:是(swupd.rs:899,未改)。
5. **field build 是否顯示 tech?** 是。`app/lib/swupdate.dart:347-350`:只要 `a.tech` 非空就出現「技術資訊」ExpansionTile,不分 dev/field。可接受:內容只有固定英文字串與數字,不比既有的「代碼 N,原因 R」多;收合預設不顯示。
6. **Lost 的來源**(本地 actor / 我們自己的錯):bridge 在簽章失敗、request 送不出、nonce 回 Ok 但無 helper 時都給 `Reply::Lost`(bridge/src/api/owner.rs:1602, 1615-1623, 1650)。status 不是 owner-op,所以實務上 status 的 Lost = 等不到回應或連線斷;標成「no answer」大致正確(見 m3 的小誤差)。
7. **D8**:`docs/design/254-app-update.md:113` 的 D8 是「秘密只在需要時經過 Dart、不 debugPrint 步驟文字和例外」。本改動不 log、不顯示 detail,符合。

## 發現

### MINOR

**m1. 「no trust (stale)」對「沒有 key 15 的回答」會貼錯標籤。**
- 情境:`gate()` 在 `trust` 讀不到時一律回 `Gate::Unread`(swupd.rs:316-318),包括 (a) `{15:{stale:true}}`、(b) 根本沒有 key 15(較舊韌體或別的節點實作)、(c) `trust` 不是 text。`Gate` 自己的註解(swupd.rs:309-311)就寫「stale, or an answer without key 15」。技術行卻一律寫「(stale)」,遠端除錯會把 (b)/(c) 誤判成快取沒好,往錯的方向查(這正是這行要解決的事)。
- 修:只有 `status.get(15)` 裡 `stale == true` 時寫 `status: no trust (stale)`,否則寫 `status: no trust`(或 `no key 15`)。仍是固定字串,不帶節點內容。測試多一個無 key 15 的案例。

**m2. 測試沒涵蓋 E_RATE 用完後的行為。**
- 情境:使用者問的「E_RATE 重試後報什麼」正是新 catch-all 臂最可能在現場碰到的路徑(status 頁剛讀過 → E_RATE ×4),但 a13 只測 code 9。若日後有人把 901 行移到 895 之前,E_RATE 就不再重試,現有測試(要看有沒有別的 E_RATE status 測試)可能抓不到。
- 修:a13 加一段:4 次 `Reply::Err{code:12}`(中間 `after`),斷言第 4 次是 `T_STATUS_UNREAD` + `status: code 12`,前 3 次是 `Action::Wait`。

**m3. 技術行格式和既有的不一致。**
- 證據:其它錯誤畫面的 tech 是中文「代碼 N」「代碼 N,原因 R」(swupd.rs:1181, 1223-1228),這裡是英文「status: code N」。同一個「技術資訊」區混兩種格式,遠端讀截圖時要記兩套。另 "no answer" 也涵蓋「連線斷了」,不只逾時。
- 修:擇一統一(例如 `status: 代碼 N`),或在 254-app-update.md §4/§3.1 寫明這三個字串(目前設計文件 docs/design/254-app-update.md:131 只寫畫面文字,沒寫 tech)。

**m4. commit 訊息把它連到 A13,但 A13 的症狀(未入網節點 status 永遠 stale → 無法準備更新)沒有被修。**
- 這個 commit 是必要的診斷,本身沒問題;但交接/issue 不能把 A13 記成已解。需要在 #329 checklist 留一條:節點端「已認領未入網時 status 快取永遠 stale」要另外追(節點 status.go 為何不就緒),或 app 端在這種狀態給可行動的文字。⚠️ 我沒有查節點端原因。

## 負控制

✅ 已驗證。父 commit 的 swupd.rs + 新測試,用**全新** target 目錄:

```
running 1 test
test a13_status_unread_names_its_cause_and_nothing_else ... FAILED
thread 'a13_status_unread_names_its_cause_and_nothing_else' panicked at tests/swupd.rs:1325:5:
assertion `left == right` failed
  left: ("讀不到節點的狀態 — 請重新整理", "")
 right: ("讀不到節點的狀態 — 請重新整理", "status: no trust (stale)")
test result: FAILED. 0 passed; 1 failed; ...
```

⚠️ 審查流程的坑(不是產品問題):我第一次用指示中的共用 `CARGO_TARGET_DIR=$HOME/tgt-rev-a` 先編新版、再編負控制版,負控制**誤報 40/40 PASS**。原因推斷為:兩份 archive 的 crate 相同,負控制的 swupd.rs 是在新版編譯前寫入的,mtime 比產物舊,cargo 當成沒變沒重編。換獨立 target 目錄後才正確失敗。往後負控制請用獨立 target 目錄或 `touch` 被換掉的檔案,否則負控制可能是假的。

## 驗證結果分類

✅ 已驗證(原始輸出)
- 新版 `cargo test -q`(batman-proto 全部,獨立 target `tgt-rev-m-new`):所有 test binary `test result: ok`,其中 swupd `40 passed; 0 failed`,無 FAILED。
- 負控制如上:新測試在父版失敗於第一個斷言(tech 為空)。
- 程式碼出處:swupd.rs:877-904(on_status)、314-338(gate)、415-422(Reply)、673-691(screen/decorate)、1223-1228(tech);flow.rs:18(E_RATE=12);swupdate.dart:347-350;owner.rs:1601-1656。

⚠️ 推斷 / 部分
- 「code 只會是數字」由 Rust `u64` 型別與 `{}` 格式化推得,未另寫 fuzz。
- 「status 不是 owner-op、所以 Lost 只來自逾時/斷線」由 bridge 程式碼推得,未上機。
- m1 中「較舊韌體不帶 key 15」是可能情境,未查節點各版本 status.go。
- 共用 target 誤報的原因(mtime)是推斷。

❌ 未做
- 未跑 clippy(WSL toolchain 1.99.1 沒裝 clippy component)。
- 未跑 Flutter / Dart 測試、未上機(S20 + 04)看技術資訊實際顯示。
- 未查節點端 status 永遠 stale 的根因(m4)。
