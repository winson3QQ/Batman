# #329 UX speed plan v2 — 審查 G(獨立對抗式審查,整份文件)

對象:`docs/design/329-ux-speed-plan.md`(plan v2),對照 worktree `C:\src\Batman-b8`(HEAD 6760b78)。
方法:只讀原始碼(app Dart / Rust bridge / 節點 provd Go);沒有碰手機、模擬器、節點,沒有跑 adb / ssh,沒有改任何程式。沒有跑 `flutter test`(本輪全部是讀碼)。

## 判定:APPROVE-WITH-CHANGES(有 5 個 MAJOR,依規則要出 v3 再整份審一次;沒有 BLOCKER)

一句話:「node 頁開著時留一條已登入的連線」這個方向成立,也找不到更小又達得到 §2 目標的設計(見「最小修改評估」)。但 v2 把最危險的幾個介面留白:(1) 沒有 token 的 parked 連線在 BleGate 裡失去了現有的安全網;(2) `loginFor` 的快路徑繞過今天每次登入都做的金鑰 / 前置條件檢查;(3) §4.5 的關閉清單沒有分狀態,照字面會在操作進行中切掉借出去的連線(軟體更新中鎖螢幕);(4) §4.1 / §4.4 需要的 Prober 介面完全沒定義;(5) 13 個測項有 8 個沒有負向對照。這些修法都小,不需要換設計。

---

## BLOCKER

無。

## MAJOR

### M1. parked 連線(token = none)在 gate 裡沒有任何安全網;`dispose` 與 radio 前置條件失效不在 §4.5

情境(我們自己的錯,actor = our own mistakes):NodeLink 任何一條路漏關 parked 連線(例如 `dispose()`、hook 在 `pass(link, null)` 之後丟例外、240 s 計時器被 `_timer?.call()` 取消)。之後整個 app 再也連不上任何節點,直到 app 被殺;節點那邊最多 300 s 不廣播。

證據:
- ✅ `ble_gate.dart:62` `final Token token;`(不可為 null、不可變);`:86-88` `_usable` 只看 `gate.reg.valid(token)`。B1 要改這裡,但 plan 沒寫 null 時 `_usable` 的定義。
- ✅ `ble_gate.dart:252-259` `revoked(Token t)` 用 `identical(l.token, t)` 找連線;`:262-266` `released` 的註解明寫「anything left open by mistake is closed here, so the next holder never finds the gate busy」。token 為 null 的連線兩條路都比不到 → 這張基準安全網對 parked 連線不存在。
- ✅ `ble_gate.dart:239-242`:`_links.isNotEmpty` → Refused;`node_link.dart:533` `_pump` 要 `gate.links == 0` 才開下一個 attempt;`:366` `loginFor` 在 `gate.links > 0` 時每 100 ms 空轉;`:664-675` `_dropAll` 等到 0 或 5 s。漏掉一條 parked 連線 = 這四處全部卡住。
- ✅ `node_link.dart:677-686` `dispose()` 只呼叫 `_dropAll()`(`_abort` 只關 `_link`);§4.5 的清單沒有 dispose。
- ✅ `node_link.dart` `radio(...)` → `core.setRadio`(`core.dart:321-333`)在 `keyOk:false` / `permission:false` 時取消 round 與進行中的 login;§4.5 沒有這一列,所以金鑰不可用時已登入的 session 繼續留著(藍牙關掉會讓 link down,那條有涵蓋)。

修法(都在 plan 裡寫明):
1. gate 自己擁有 parked 的期限:`pass(link, null, {required Duration max})`,到期 gate 自己 `close()`;NodeLink 的 240 s 只是較早的那一道。這樣「沒人擁有的連線一定會消失」不依賴 NodeLink 沒寫錯。
2. `_usable`:token 為 null → 一律 Refused(寫進契約與 T1)。
3. §4.5 加兩列:`dispose()`;`radio()` 使 `bt && perm && keys` 變 false。
4. 測試:T14「parked 後 NodeLink 不再做任何事(模擬漏關),gate 期限到 → 0 links,下一個 `gate.connect` 成功」;負向對照 = 拿掉 gate 期限 → 連線永遠 Refused。

### M2. `loginFor` 快路徑跳過今天每次登入必做的檢查(未列在 §3 的基準變更)

情境:owner 在 node 頁,parked 連線存在。手機的金鑰變成不可用(`KeyAbilities.read(...).login == false`,例如螢幕鎖被移除),或 `core.blocked != null`。今天按任何按鈕 → `LoginForEnd.precondition`,頁面顯示 2.2 / 2.3 / 2.4 的文字。v2 之後 §4.2「return … at once」→ 操作直接在舊 session 上跑(不需要 owner 簽章的請求如 `settings/get`、`info`、status 會成功)。

證據:
- ✅ `node_link.dart:316-324`:`_loginFor` 一進來先 `await keysOk()`,false → `radio(keyOk: false)`;`:325` `!mine()` → noLease;`:326` `core.blocked != null` → precondition。註解:「design §4.1: the keys are read live before each login」。
- ✅ `app_link.dart:160` `keysOk: () async => (await KeyAbilities.read(platform)).login`。
- ✅ plan §4.2 的條件只有三個(parked、id 相同、link up);§3 的 B1–B3 沒有「登入前的即時金鑰檢查不再每次做」。

修法:快路徑放在 `_loginFor` 的 `keysOk` / `mine()` / `core.blocked` 三個檢查**之後**(順序不變,只是省掉 scan + connect + login)。`keysOk` false → 先關 kept link 再回 precondition。測試:T15「T1 之後 `keysOk` 回 false → `loginFor` 回 precondition、0 links」,負向對照 = 快路徑放在檢查之前 → 回 ok。

### M3. §4.5 的關閉清單沒有分狀態:照字面會在操作進行中切掉借出(lent)的連線

情境 A(現場很常見):owner 在 node 頁按「軟體更新」。`OpenSession.open` → `loginFor` 走快路徑,拿到的就是 kept link(lent)。更新進行幾分鐘,owner 鎖螢幕。§4.5:「the app goes to the background (`background()`) … 」+ 開頭的「always: session disposed, link closed」→ 更新的 session 被切。今天不會:`background()` 只取消 round。
情境 B:Wi-Fi 頁按送出後立刻連按兩次返回到首頁 → `home_page.dart:280/288` `setPage(home)` → §4.5「the page changes」→ 送出中的請求被切,結果變成「不確定」。今天請求會跑完。

證據:
- ✅ `node_link.dart:216-219` `background()` = `core.background` + `_pump`;lease 持有者的連線不受影響(連線綁 lease token,`ble_gate.dart:252-266` 只在 revoke / release 時關)。
- ✅ `op_session_test.dart:207` 既有測試「B m3: the page goes during a request: the request is not cut; then the console closes and the lease goes」——這是已審基準。
- ✅ `update_route.dart:28` 更新頁走 `OpenSession.open`(→ `loginFor`),所以會拿到 kept link。
- ⚠️ 推論:plan 的本意大概是「lent 只受 lease 收回與持有者自己 close 管」(§4.5 最後一列與 T12 有這個味道),但文字沒有這樣寫,T5 也只從 parked 狀態測。照字面實作就是上面的回歸。

修法:§4.5 改成一張「事件 × 狀態(parked / reading / lent)」的表。lent 欄只有兩個關閉原因:lease 被收回(gate 既有路徑)與持有者 `close()`;頁面變更 / 背景 / 記錄移除在 lent 時只記下「歸還時不 park」(這正是 §4.3 hook 的條件)。測試:T16「lent 中 `setPage(home)`、`background()` → 連線仍在、進行中的請求有答案;之後 `close(reusable: true)` → 0 links」;負向對照 = 照 v2 字面在 `setPage` 關 → 請求被切。

### M4. §4.1 / §4.4 需要的 Prober 介面沒有定義(誰把 session 交出來、誰 dispose、多久逾時、hint / team 怎麼辦)

這是 v2 最大的一塊留白;B3 只有一句話。逐項:

1. **session 怎麼離開 `probe`。** ✅ `node_link.dart:39-40` `Prober.probe(link, id, {due, cancelled})` 回 `Outcome`;一般讀取的 `Outcome.extra` 已經是 `StatusView`(`prober.dart:175` `Outcome(Res.body, v.color, v)`),不能像 `HandoffProber` 那樣把 handoff 放在 `extra`(`prober.dart:164-165`)。plan 沒說新欄位 / 新方法是什麼。
2. **prober 不知道頁面。** 「`core.page == Page.node` 且 target 是那個節點」要在 `probe` 開始前由 NodeLink 決定並傳入;`probe` 期間頁面變了 → 誰 dispose 交出來的 session?✅ `node_link.dart:627-631`:`_run` 被 abort 時直接 return、`core.result` 回 false 時照常往下——兩條路今天都靠 `probe` 自己的 cleanup 處理 session,交出來之後就沒人處理。契約要寫:「`_run` 沒有 park 的每一條路都 dispose」。
3. **kept read 的逾時。** §4.4「wait as a normal read」= ✅ `prober.dart` 的 `answerMax` 20 s。round 的 window 是 30 s(`core.dart` Params);20 s 等不到 + 關連線(最多 5 s)+ 節點重新廣播 + scan,剩不到 5 s。`core.tick`(`core.dart:547-579`)在 `now-start >= window && running == null && !pending` 時結束 round——kept read 期間 `core.running` 本來就是 null。⚠️ 推論:一次卡住的 kept read 很可能讓這個 round 以「找不到」結束(T4 期望的是「同一個 round 用新連線讀到」)。開著的 session 上實際工作是 0.6 s(F1),逾時應該是 3 s 左右,寫進 plan。
4. **`_pump` 的重入。** kept read 沒有 `Attempt`,`_attempt` 與 `core.running` 都是 null;`_pump` 會被計時器、`setPage`、`refresh` 重複叫進來(`node_link.dart:522-547`)。需要 NodeLink 自己的「kept read 進行中」旗標,否則第二次 `_pump` 會再發一次 status(節點每個 session 1 次/秒,`session.go:868-874` → `ERate`)或照 `:531` 去開 scan(scan 起動計入 4 次/30 s)。
5. **round 被換掉。** ✅ `core.dart:311-319` `refresh` 會取消 early round 再開新的;`send_key.dart:44`、`more_pages.dart:278` 在操作後呼叫。kept read 進行中 round 被換 → 結果落在新 round。`keptRead` 的契約「ignored unless a round is active and id is a target without a body」擋不住這個;要帶 round 的身分(或在 round 取消時切掉 kept read)。
6. **hint 與 team 區塊。** ✅ `prober.dart:176-190` 讀完 status 後在同一個 session 上做 `_afterRead`(最多 2 s),`_run` 再寫 `readWall` 與 `teams`(`node_link.dart:636-644`)。kept read 走不走這段、`keptRead` 之後誰寫 `readWall` / `teams`,plan 沒寫。不做 → node 頁的 team 區塊與 hint 在第一次讀之後不再更新(回歸)。
7. **`Res.errorCode`(row 2')。** §4.4 把它歸在「Anything else → close」。節點回錯誤碼不是連線壞了;今天它是「不變」的一次讀取。關掉重連只會再拿到同一個錯誤碼,每 60 s 多一次 F1。應該照 `core.result` 的 errorCode 處理並繼續 park。
8. **`fresh`。** ✅ `owner.rs:949-957`:同一個 session 上 status 被 `E_RATE` 拒絕時 Rust 保留上一次的讀取、`page_fresh = false`(測試 `owner.rs:2625`);`prober.dart:175` 不看 `v.fresh`,會當成 `Res.body` → `core._read` 把 `readAt` 設成現在。今天每次讀取都是新 session,走不到;kept session 走得到(第 4 點的重入、或 console 的 `statusPage`(`more_pages.dart:271`)之後 1 s 內的 kept read)。資料最多舊 1 s,傷害小,但 kept read 應該要求 `v.fresh`,不 fresh 就當這次沒讀到(不關連線)。

修法:plan 加一節「Prober 介面」:`probe(..., keep: bool)` 的回傳型別、kept read 的方法簽章與 3 s 逾時、上面 1–8 每點的行為;8 個實作 `Prober` 的測試替身(`login_for_test.dart:16`、`node_link_team_test.dart:19`、`node_link_test.dart:78`、`review_pr1_test.dart:20,39,47,664`)要不要改也寫明(建議新方法放在另一個介面,既有替身不用動)。

### M5. 測試:8 個測項沒有負向對照;P4Session 假 session 驗不到 Rust 狀態;壞掉的既有測試沒有列

- ✅ plan §6:T5、T6、T7、T10、T11、T12、T13 的「On main」是「n/a」,T8、T9 是「passes today」。標題卻寫「each fails on main」。這 9 個測的全是「該關的時候有關」——在 main 上因為根本沒有 kept link 所以無從失敗,在新程式上則需要**逐條規則的突變對照**:拿掉 §4.5 的那一條 → 該測項 FAIL。沒有這個,T5 的五個子項只要有一條通用的關閉路徑就全過。plan 要寫明每個測項對應拿掉哪一行。
- T8「passes today (kept as guard)」:今天沒有 hook,這個測項測不到「hook 檢查 lease 仍是 current」。突變對照 = hook 不檢查 lease → 被收回後 `close(reusable: true)` 把一條已關的連線 park 起來(或對新 lease 的 token 生效)。
- ✅ 既有假件 `P4Session` 不是 Rust `OwnerSession`。「prober → console → prober 共用一個 session」的正確性在 Rust 的狀態(`owner.rs:316-353`:`page_status` / `page_fresh` / `after_left` / `page_cut_once` / `made` / `confirm` / `sw_reply`…),flutter 假件全綠也不代表真的可重用。需要一個 Rust 單元測試:同一個 `OwnerSession` 上 status → settings/get → settings/set → status → info → status,每步答案正確、`fresh == true`;以及 `leave` 成功後(`after_left = true`,`owner.rs:894`)下一次 status 的 `JoinButton`(`:964`、`:1359`)是不是想要的。
- 缺的測項:M1–M4 各自的(T14–T16 等);`acquire` 在有 parked 連線時不等 `_dropAll` 的 5 s(`node_link.dart:672-674` 是真實 `Future.delayed`——漏改的話 T2 的「connect 次數 = 1」照樣過,但每次操作慢 5 s);舊 console 在連線被再借出後的遲到寫入被拒;連續借出時 `LoginHandoff` 是新物件(見 m2)。
- 「Existing tests that state B2 … are changed … and listed in the PR」:審查看不到要改哪些。✅ 斷言連線數的既有測試在 `node_link_test.dart`(7 處)、`login_for_test.dart`(8)、`review_pr1_test.dart`(7)、`handoff_test.dart`(2)、`ble_gate_test.dart`(11)、`ui/pages_test.dart`、`ui/retest_p_pr3_test.dart`(4)。⚠️ 我沒有逐一判斷哪些是在 `Page.node` 下跑的;plan 應該先列出來(會改的、不改的各幾個),因為「改既有斷言」本身就是改已審基準。

---

## MINOR

- **m1. F7 不完整。** node 頁可以進「建立 / 加入網路」頁,它開啟時 `setPage(Page.home)`(✅ `net_pages.dart:203`),返回時還原(`:224`)。依 §4.5 這會關掉 kept link,之後的 join 走慢路徑——行為正確,但 F7 寫「pushed pages leave `core.page == Page.node`」沒有列這個例外,§2 的「Handles」也該說 join / 建網不在內。
- **m2. `LoginHandoff` 是一次性的。** ✅ `handoff.dart:74-81` `_closed` 讓 `close()` 只生效一次。「同一個 kept link 借出多次」必須每次包一個新的 `LoginHandoff`(共用 link / inbox / session / sub),hook 綁在那一個物件上;舊物件之後再被 `close(reusable: true)` 不可以影響新的借出。plan 寫「kept link = one LoginHandoff」會被實作成重用同一個物件。
- **m3. `reusable` 的條件少一個。** ✅ `owner_console.dart:233` `alive => _session != null && !_closed`;`_close`(`:676-693`)一開始就設 `_closed = true`,所以「alive at the call」要在那之前取值。另外 Rust 端在流程出錯後是 `St::Over`(`owner.rs:1032` 等),Dart 的 `_session` 可能還不是 null ⚠️(我沒有逐一對過每個 `Ended` 是否都把 `_session` 清掉)。建議 `reusable` 再加一個 Rust 端的查詢(session 仍在 `St::Conn` 且沒有進行中的 op,現成的 `flow_busy`,`owner.rs:1390`),不要只靠 Dart 旗標。
- **m4. 節點不會在 leave / rekey 後自己結束 session。** 生命週期表寫「node ends the session (rekey, leave, remove)」。✅ `session.go:129,348-359`:`closeAfter` 只用在第 3 次 claim 失敗與驗證失敗;我在 provd 裡找不到 leave / rekey / settings 之後關 session 的程式。⚠️ 所以這些操作之後 session 多半還活著,會被 park 並重用——這讓 M5 的 Rust 重用測試更必要(`rekey_send.dart:112,139` 連續兩個 `OpSession.once`,第二個會走快路徑)。表裡那一格請改成有證據的敘述。
- **m5. 讀取進行中按按鈕會變慢。** §4.5「a lease is acquired while a status read is running → cut, slow path」。kept read 加上 hint / team 最多 2.6 s;這段時間按下去 = 關連線 + 等節點重新廣播 + F1(4–8 s),比今天還慢。`acquire` 等這次讀取結束(上限 1 s)再借出比較符合目標;否則請在 §2 寫明這個偶發的慢。
- **m6. 沒有總時間上限。** 手機放著、螢幕恆亮停在 node 頁:每 60 s 一次 kept read,240 s 的 guard 永遠不觸發,那個節點就一直不廣播(✅ `bluez.go:772-776`:`nlinks > 0 || Sessions() > 0` → withdraw)。§2 有老實寫成本;這是產品決定,請使用者明確點頭,或加一個「N 分鐘沒有任何點按就關」的上限。
- **m7. F1 無法查核。** scratchpad `ux/m1.log` 不在 repo,❌ 我沒看到。整個設計的收益建立在「開著的 session 上 0.6 s」這個數字上;PR 的裝置計時(§6)會補上,但 plan 的通過標準「every read after the first is under 1.5 s」應該也包含「送出」的 app 端時間(扣掉節點套用時間)。
- **m8. inbox 交接的一個小洞。** ✅ `handoff.dart:21-45`:沒有 handler 時 frame 進 `_held`,下一個 `handle()` 會收到。console 關閉(`handle(null, null)`)到 park(NodeLink 裝上「任何 frame 就關」的 handler)之間到的 frame → park 當下就關,正確(fail-closed)。但 §4.2 借出時「give the inbox back (no handler)」到新 console 裝 handler 之間到的 frame,會被新 console 的 Rust session 當成它的回應。借出前若 `_held` 非空應該直接關(不借)。
- **m9. A2**(`requestConnectionPriority`)與本設計無關,分開 commit、量了再說,同意。耗電沒有數字(v1 審查 B 的 M-7 仍適用)。

---

## 指定攻擊點的結論

| 點 | 結論 |
|---|---|
| (a) `pass` / null token vs `revoked` / `released` / `_dropAll` / `close` / `_usable` | M1。`GateLink.close()`(`ble_gate.dart:111-131`)不看 token,parked 時可關 ✅;`_dropAll` 會白等 5 s(M5) |
| (b) 讀取中 acquire | `acquire` → `gate.revoked(mine)`(`node_link.dart:267`)會關掉 reading 狀態的連線,與 §4.5 一致 ✅;體感見 m5 |
| (b) `released()` 的 listener 順序 | gate 先於 NodeLink(`ble_gate.dart:136` 在建構時註冊)✅;parked(null)不受影響,lent 被 gate 關;hook 的「檢查 + `pass`」必須同步完成(中間不可 await),請寫進契約 |
| (b) console `close()` park 後 `lease.release()` → `gate.revoked(l.token)` | parked 的 token 已是 null,比不到 → 不會被關 ✅(也正是 M1 的另一面) |
| (b) release 後 `_pump` 而 links == 1 | `_pump` 的 `gate.links == 0` 會擋住一般 attempt;targets 恰為 `{kept}` 走 §4.4,否則 §4.5 先關。需要 M4-4 的旗標 |
| (b) hook park 中同 id 的 `loginFor` | 需要新 lease,而舊 lease 在 `close()` 回來後才 release(`op_session.dart` finally 的順序)→ 只要 hook 同步就沒有洞 ✅ |
| (c) 一個 `OwnerSession` 給 prober → console → prober | M4-8、M5、m3、m4。frame 計數與加密狀態在 Rust `conn` 內連續使用,今天 console 已經這樣做(F9 ✅);inbox handler 見 m8 |
| (d) `keptRead` 沒有 Attempt | M4-3、4、5 |
| (e) node 頁可到的頁面 | 設 `Page.home` 的 join / 建網頁(m1);直接 `acquire(session)` 不登入的:移除節點 `more_pages.dart:84`、`dev_pages.dart:429`、`net_pages.dart:342` → park 保留,移除成功後靠「record removed」關(要在 `released` 的記錄比對裡做,`node_link.dart:471-509`);raw lease 頁只從首頁進 ✅ |
| (f) 節點端會改 / 殺 session 的操作 | m4:provd 不主動殺;軟體更新會重開機 → link down ✅;Wi-Fi / 國家變更 ⚠️ 我沒有在節點上驗 BLE 是否中斷(不准碰節點) |
| (g) 測試 | M5 |
| (h) 安全 | 其他 app:無新通道 ✅。拿到解鎖手機的人:M2(金鑰失效後仍可操作)。被攻陷的節點:parked 時任何 frame → 關(fail-closed),最多逼出重連,與今天相同 ✅;m8。第二支手機:m6。我們自己的錯:M1、M3 |

## 事實查核(F1–F10)

| # | 結果 |
|---|---|
| F1 | ❌ 無法查核(log 不在 repo) |
| F2 | ✅ `op_session.dart:89-131`;`owner_console.dart:672-693`(行號比 plan 寫的 668-695 略有出入,內容相符) |
| F3 | ✅ `core.dart:218-239`(X33 在 `:232`);`node_link.dart:627` `await mine?.close()` |
| F4 | ✅ `ble_gate.dart:239-242`、`:86-88`、`:252-259` |
| F5 | ✅ `node_link.dart:253-270`;`lease.dart:131`;`core.dart:196` `_eligible`、`:259-264` `acquireLease` |
| F6 | ✅ `core.dart:441-465`、`:469-532` |
| F7 | ⚠️ 部分:列出的 `setPage` 呼叫點都對,但漏了「join / 建網頁設 `Page.home`」的後果(m1) |
| F8 | ✅ `server.go:31-32` `IdleAnon 30 s` / `IdleAuthed 300 s`、`:36` `Slots = 2`;檔案是 `feed/batman-prov/src/cmd/batman-provd/bluez.go`(plan 沒寫路徑):`:772-776` withdraw、`:408-420` Close → `Device1.Disconnect` |
| F9 | ✅ `owner_console.dart:233`、`_ask` `:411-468` |
| F10 | ✅ `op_session.dart` `OpenSession`;`update_route.dart:28` |

## 最小修改評估

- **node 頁自己持有一個 `OpenSession`**:不行。它持有 lease → `core.lease = true` → `_eligible` 為 false(`core.dart:196`),node 頁的 60 s 讀取停掉(F6:狀態只能經 round 進 core);每個子頁的 `OpSession.once` → `acquire` 回 null → 「另一個操作還在進行」。要讓它能用就得把 console 傳給每一個子頁、把狀態讀取搬出 core——改的頁面與基準比 v2 多。
- **只做借出、不做歸還(拿掉 §4.3)**:少掉 `reusable`、hook、console 之後的 session 重用風險。但 Wi-Fi 頁「開啟讀一次、送出一次」的第二次仍然是一個 F1(lease 放掉後 6 s 才有 round 把連線建回來),達不到 §2。
- **只做歸還、不做 kept read(拿掉 §4.4)**:lease 放掉 6 s 後的 round(`afterLease`)需要 `gate.links == 0`,會把 kept link 關掉,重用窗口只有 6 s。
- 結論:v2 的三塊(§4.1(1)、§4.3、§4.4)缺一不可,plan 的大小站得住。可以縮的只有 A2(本來就分開)。

## 我沒做的

- ❌ 沒有跑任何測試或原型(全部讀碼)。
- ❌ 沒有在節點 / 手機上驗任何行為(依指示)。F1、Wi-Fi / 國家變更後 BLE 是否中斷、leave / rekey 後 session 是否存活,都是讀碼推論(⚠️)。
- ⚠️ 既有測試沒有逐一判斷哪些會壞,只數了斷言連線數的位置。
- ⚠️ Rust 每個 `OwnerKind::Ended` 路徑是否都讓 Dart `_session = null`,沒有逐一對完(m3)。
