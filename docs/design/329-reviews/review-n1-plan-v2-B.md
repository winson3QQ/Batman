# 審查 B:`329-n1-plan.md` v2(provd 切掉連上卻不開 session 的裝置)

審查對象:`docs/design/329-n1-plan.md`(未追蹤,worktree `C:\src\Batman-b8` @ 6760b78)整份。
方式:只讀原始碼(provd、harness、app、kernel 6.6.138、BlueZ 5.72);沒有上機、沒有 ssh/adb、沒有跑任何測試。
標記:✅ = 我對原始碼逐行核對過;⚠️ = 由原始碼推論,未在真機證實;❌ = 沒查 / 查不到。

**結論:APPROVE-WITH-CHANGES。** 0 BLOCKER、3 MAJOR、9 MINOR。機制本身(年齡判定 + 沿用既有 `register()` → `staleLinks()`)是最小且正確的改法,不需要再加機制;MAJOR 都是計畫文字 / 生命週期表 / harness 的洞,改計畫即可,改完請整份再審一次。

---

## 0. 從現場看:這個改動救得回 11-18 的事故嗎

事故(F1):04 上 BlueZ 認為 S20 `Connected: yes`,provd 沒有 session(log 沒有 `connection ble`),`links` 空、`devConn` 有一筆 → `converge` 永遠不廣播。

改動後的路徑(✅ 對照 `bluez.go`):`devConn` 那筆超過 30 s 且不在 `links` → `liveLinks` 不計 → `n == 0 && Sessions() == 0` → `!advOn` → `register()`(`:583`)→ `staleLinks()`(`:590`)對它叫 `Device1.Disconnect` → `RegisterAdvertisement`。

- `Device1.Disconnect` 清得掉嗎:F7 有一次真機觀察(我無法核對該 log ⚠️)。我另外從原始碼補了證據 ⚠️:
  - kernel 還有這條連線時:`mgmt.c:3103-3125 disconnect_sync` → `hci_abort_conn`;`hci_sync.c:5650-5701 hci_abort_conn_sync` 在 `hci_disconnect_sync`(等 `HCI_EV_DISCONN_COMPLETE`,逾時 `HCI_CMD_TIMEOUT` 2 s)之後,若連線還在 hash 就走 `hci_conn_failed`(`hci_conn.c:1230`)強制清掉,並經 `mgmt_connect_failed`(`mgmt.c:9813`)送 device-disconnected、`hci_enable_advertising`。也就是 controller 不回應時,kernel 仍會在約 2 s 內自己清。
  - kernel 已經沒有這條連線(只剩 BlueZ 以為連著):`disconnect_sync` 回 `-ENOTCONN`;BlueZ `src/adapter.c:8496-8519 disconnect_complete` 對 NOT_CONNECTED 只警告、照樣 `dev_disconnected()` → `Connected` 變 false。
  - BlueZ 端 `src/device.c:1839-1898 device_request_disconnect`:先關 att_io,2 s 計時後 `disconnect_all`。
  - 只有 bluetoothd 本身卡死時 Disconnect 才會掛住;那時 `staleLinks` 的 5 s context(3 輪)會放棄,`register()` 仍往下叫 `RegisterAdvertisement`(也會失敗),每 5 s tick 重試。這是既有行為,可接受。
- 所以:**救得回,而且不依賴「為什麼沒收到斷線」的答案**。但「Disconnect 沒清掉仍能廣播」那條退路依賴 F-P41(見 MAJOR-2)。

---

## 1. 事實核對

| # | 結果 | 說明 |
|---|---|---|
| F1 | ⚠️ 無法核對 | session 觀察。漏了關鍵一句:當時 provd log **沒有 `connection ble`**(= 沒有 session、`links` 空)。v1-A 已要求寫明,v2 沒寫。見 MINOR-1 |
| F2 | ✅ | `bluez.go:733` 計數、`:772-776` 分支 |
| F3 | ✅ 但不完整 | `:691` sender 檢查、`:694-702`/`:721` 設/刪。另有 `:491`(`refreshOwner`)整個重設 `devConn`,F3 寫「only from signals」不精確(§3.1 有提到 `:491`)。MINOR-2 |
| F4 | ✅ | `link()` `:294-313`、`Close` 內 `delete` `:412`、`ReadValue` `:121-134` 不建 link |
| F5 | ✅ | `register()` `:583-600`,`staleLinks()` 在 `:590`;`staleLinks` `:518-567`,3 輪 × 5 s、不持 `b.mu`。另一個呼叫點 `:743`(`registerApp` 前)計畫沒列,無影響 |
| F6 | ✅ | `:656-681`,5 s tick |
| F7 | ⚠️ 無法核對 | 一次觀察;我在 §0 補了原始碼面的佐證 |
| F8 | 原始碼 ✅ / 量測 ⚠️ | `claim.dart:335-370`、`:497-530` 屬實,之後 `subscribeToCharacteristic`(AcquireNotify → `links`)與 RX 寫入,中間沒有使用者步驟;`app/android` 找不到金鑰的生物辨識/使用者驗證設定。`ux/m1.log` 在別的 session scratchpad,我看不到 |
| F9 | ✅ 但清單不完整 | `hold02` 在 `prov-provd-254.sh:68-69`,使用處 `:99-106`、`:125-137`、`:192-200` 屬實。**漏了 `read`**:它本身就是約 23–26 s 的無 session 連線。見 MAJOR-3 |
| §4「provd already calls `Device1.Disconnect`」 | ✅ | `staleLinks` 以及 `bleLink.Close` `:416-418` |
| §4「`Sessions()`」隱含只算 BLE | ✅ 但要寫明 | `provd/server.go:835-845` 算所有非 `"http"` session(BLE + sock);`cmd/batman-provd/main.go:88-100` 中 sock 與 BLE 互斥(sock 只在 `prov_test` build 且 SOCK_ONLY)。所以 BLE build 裡等於只算 BLE,HTTP 永不計。這正好關掉 v1 B-M-1,計畫應寫一句 |

---

## 2. 發現

### MAJOR-1:生命週期表有一列寫錯、少一條路徑,§2 的時間上限因此不成立

**情境。** (a) 表中「session ended, phone keeps the link | Today: dark until the phone lets go」。實際上今天 session 一結束 provd 就主動斷線:`bluez.go:416-418` `go c.Object(bluez, l.dev).Call("org.bluez.Device1.Disconnect", 0)`(錯誤被忽略)。所以今天不是「等手機放手」,而是「Close 時切一次,那次失敗才會永遠黑」。
(b) 因此 §3.1「link 移除時把 `devSince` 設為 now,讓手機在 session 後有新的寬限」理由不對:正常情況那個裝置 2 s 內就被 Close 的 Disconnect 切掉;這條規則的實際效果是「Close 的 Disconnect 失敗時,30 s 後才由 `staleLinks` 再切一次」。行為可以接受(也可以不重設、直接在下一輪 converge 再切,更快),但要照實寫。
(c) 缺一列:**session 進行中手機消失而節點沒聽到斷線**(就是 F1 的成因發生在 session 中)。這時要先等 session idle(`provd/server.go:30-31`:`IdleAnon` 30 s / `IdleAuthed` 300 s)→ `Close` → Disconnect →(若失敗)再 30 s 寬限 → tick ≤ 5 s → `staleLinks`。最壞約 300 + 30 + 5 + 斷線時間 ≈ 340 s。§2「at most the grace time plus one disconnect」對這條路徑不成立。

**證據。** ✅ `bluez.go:394-420`、`provd/server.go:30-31`、`provd/session.go:290-294`。

**修法(只改文字與一個 unit 列,不加機制)。**
- 修正該列的 Today 欄;§3.1 的理由改寫為實際效果,或拿掉重設並說明為什麼。
- 加一列「session 中途連線無聲消失」,寫出上限(已認證 ≈ 5.5 分鐘,由既有 `IdleAuthed` 決定,本次不改),§2 的上限句改成分情況。
- unit 表加一列對應 (b) 的選擇。

### MAJOR-2:沒有重現紀錄;時間上限寫短了;退路依賴的 F-P41 仍未驗證(v1 A-M2 / B-B-1 只解了一半)

**情境。**
1. 通用規則要求「修之前在真機重現,重現不出要寫試過什麼並先問」。計畫只說成因 ❓,沒有任何「試過哪些方式想重現殭屍連線」的紀錄,也沒寫這點已向使用者說明。§2 觸發 1 列的「out of range / Bluetooth off / app killed」是沒驗證的猜測:這三種正常都會由 supervision timeout 或 LL terminate 處理掉。
2. 用 `hold` 當替身可以,但它是**活的**連線,證明的是「Disconnect 切得掉活連線」,不是「切得掉 BlueZ 以為連著而 controller 已經沒有的連線」。後者目前的證據只有 F7 一次 + 我在 §0 的原始碼推論。計畫應把這個落差寫在「Not tested」,並把 §0 的原始碼路徑列為假設的證據。
3. §3 末段「Disconnect 沒清掉仍 `RegisterAdvertisement`」:`docs/design/254-p2-impl.md:64`(F-P41)記載有 peripheral 連線時可連線廣播需要 `le_states` bit 38/21,否則 `is_advertising_allowed`(`hci_sync.c:1007-1041`)拒絕 → `-EINVAL`/`-EPERM`;該項在 `254-p2-impl.md:337`、`:406` 仍是「le_states 實測」未做 ⚠️。也就是這條退路在 BCM43455 上會不會成功沒有證據。計畫要引用 F-P41 並寫明:被拒時每個 5 s tick 會重跑 `register()` → `staleLinks()`(等於每 5 s 重試一次 Disconnect,`logLimit` 去重),這就是實際的重試機制。
4. 時間上限:30 s 寬限 + ≤ 5 s tick + `staleLinks` 最多 3 輪 × 5 s = **最壞約 50 s**,不是表裡的「30–40 s」。新測項「等 50 s 再判」剛好壓在最壞值上。

**修法。**
- 加一段「重現」:試過什麼(或沒試)、為什麼用 `hold` 替代、這點請使用者知情。若有便宜的唯讀/無害做法能做出「節點沒聽到斷線」(例如把 02 的 central 斷電/拔 USB 藍牙、或讓 S20 進飛航後觀察),列為實機場次的一項;做不出來就標 ❓ 寫明。這不是加機制。
- 表與 §2 的時間改為「正常 ≈ 30–37 s,最壞 ≈ 50 s」;測項的判定時間用量到的 n(見 MAJOR-3 第 5 點)。
- 退路段落引用 F-P41,標 ⚠️ 未驗證;rc 上機時順手讀一次 `le_states`(`btmgmt info` / debugfs,唯讀)把那個殘項收掉。

### MAJOR-3:harness(#290)— 既有測項會被新規則影響,而且步驟順序做不出「舊版 FAIL + rc PASS」

**情境與證據(✅ 讀 `scripts/node/prov-p2-central-254.sh`、`scripts/dv/prov-provd-254.sh`)。**
1. **清單漏了 `read`。** `read_one` = connect、`sleep 8`、list-attributes、`sleep 2`、讀 STATUS(1+2 s)、讀 CTRL(1+8 s)、quit,再 `info_of`(最多 4 次)與 `drop`(disconnect、`sleep 3`):連線約 23–26 s 且從不寫 RX → 離 30 s 只剩約 5 s。使用者:boot-provd、sec-dbus、rpa unit、`prov-netjoin-254.sh:63`、`chain1-254.sh:168`、`prov-provd-wbox-254.sh`,以及 `hold` 內的 `pick`。02 的 bluetoothctl 有重試/segfault 重跑時會更長。§5.3 只講 `hold02`,要把 `read` 也列入並在 wsl.26 量最壞值;超過 25 s 的要縮短(例如 CTRL 讀後的 8 s),不是只「重排斷言」。
2. **L80 對照組會撞到。** `:125-137` 對照組:`hold02` 後 `c02 watch "$a" 15` 必須 STILL。`hold` 自己最多 3 次 ×(connect 6 s + 輪詢 ≤ 10 s),到 watch 結束時連線年齡約 24 s 以上,餘裕約 5 s;一超過 30 s 對照組就變 GONE → INVALID/FAIL。這是 v1-A 已點名的,v2 的 §5.3「先斷言」解不了(斷言本身就是 15 s 的 watch)。修法:對照組的 watch 縮到能留 ≥ 10 s 餘裕,或在 HELD 之後才起算且把 `hold` 的重試上限算進去;用 wsl.26 + rc 各量一次附上。
3. **L80 第二組失去鑑別力。** 它判「kill provd 後 15 s 內 GONE,且 `disconnected N stale link` 計數增加」。改動後就算 kill 沒成功,N1 自己也會在 watch 30 s 內把連線切掉並印同一行 → 假 PASS。這也是 v1-A 點名過的。修法:該組加一條「自 hmark 起新的 `link without session` 行數沒有增加」(或 provd pid 已換),否則 INVALID。這是 #290 規則下必須跟著改的既有判定,要附舊版/新版各一次結果。
4. **步驟順序。** §6「harness PR(附 wsl.26 FAIL)→ provd 改動」:harness PR 一合併,main 的 daily-validation 對現在出貨的 image 就是紅的,直到產品 PR 合併;而「rc PASS」在 harness PR 當下又拿不出來(rc 還沒 build)。計畫要二選一寫清楚:(a) 先從未合併的產品分支 build rc,harness PR 同時附 wsl.26 FAIL 與 rc PASS,兩個 PR 緊接著合;或 (b) harness PR 帶一筆 `scripts/validation-known-failures.txt` 條目(單號 + 到期日),產品 PR 合併後移除。
5. **新測項的判定要更實。** 「等 50 s 後看狀態」分不出「30 s 才切」與「一連上就切」。請用既有的 `watch <addr> <s>` 量 GONE 的秒數 n,判一個區間:下限(例如 n ≥ 20,證明寬限存在、合法 client 不會被秒切)與上限(證明時間宣告);以 central 端看到的斷線為準(v1-B 的要求)。「04 上 `Connected: no`」要接受 BlueZ 已把臨時裝置物件移除(`info` 查無此裝置也算)。另外要寫明新測項放在哪個 unit(boot-provd / respawn 哪一個),並更新 `254-p2-impl.md` §4.4 的 log 契約(`:227`)加上新行。
6. 負向測試「non-owner central」:02 的 `hold` 本來就沒有擁有者金鑰,寫明這點即可,不必另做。

### MINOR

1. **F1 補一句**「當時沒有 `connection ble`(沒有 session)」;這是整個診斷的關鍵證據。
2. **F3 用詞**:加上 `:491` 的重設。
3. **兩張 map 可以合成一張(更少程式、少一個契約)。** `devConn map[path]bool` + `devSince map[path]time.Time` 會有不同步的可能,而「缺時間 = 當作 now」這條 fail-open 一旦真的發生(某個新增 `devConn` 的地方忘了寫 `devSince`),就**靜悄悄地回到永遠不廣播**,而且每次 converge 都是「now」,永遠不會過期。把 `devConn` 改成 `map[path]time.Time`(值 = 開始計時的時刻)就沒有「缺」這個狀態。若保留兩張,契約要寫成「缺 = 在那一刻補寫時間」,不是每次都當 now,並加 unit 列。
4. **log 文字與時機。** 「…, dropping」在「另有活 session 所以暫不處理」時也會印,但其實沒切。改成在真的要切時才印,或文字改成不含 dropping。「每個裝置一次」需要的狀態要跟著 `devConn` 條目一起刪(MINOR-3 合併後可放在同一個值裡)。
5. **Disconnect 失敗後的殘留。** 殭屍條目留在 `devConn`、時間是舊的;同一個 path 的手機真的重連時 BlueZ 不會再發 `Connected=true`(本來就是 true),所以它在寫 RX 之前不被計數,期間若遇到 `rpa` 分支(`:777-779`)的 `register()` 會被 `staleLinks` 切掉。極端情況、手機會重連,寫進「不處理」即可。
6. **邊界競態。** 裝置剛滿 30 s 時才寫 RX:可能先 `adv registered` 馬上又 `adv withdrawn reason=connect`,或剛好被切。F8 說 app < 9 s,餘裕足夠;寫一句即可。`staleLinks` 對「剛連上、訊號還在佇列」的裝置的既有競態不是這次的增量。
7. **unit 測試的範圍要照實寫。** `liveLinks` 是純函式,可行 ✅:`testenv_release.go`(`!prov_test`)與 `testenv_provtest.go`(`prov_test`)各自成立,`bluez_test.go` 放 `package main` 兩種 tag 都編得過;CI 會跑到(`.github/workflows/ci.yml:141` `go test ./...`,`:147` `-tags prov_test`)✅。但它**測不到** `converge` → `register()` → `staleLinks()` 這段,也測不到 v1-B 要的「Disconnect 回錯 / `Connected` 一直不變 false 時仍會嘗試廣播」。計畫要寫明這段只由實機測項涵蓋(而且只涵蓋活連線),不要讓 §5.1 看起來像涵蓋了整條路徑。§5.1 的負向對照「把年齡規則拿掉重跑」要附實際輸出。
8. **寫明 sock/BLE 互斥**(`main.go:88-100`),關掉 v1 B-M-1。
9. **合法 client。** 除了 dev raw console 之外,harness 的 `read`/`hold` 也是「連上 > 20 s 不寫 RX」的 client(MAJOR-3);app 端我查到的流程都在 30 s 內寫 RX 或訂閱 ✅。Android 配對/權限對話框若卡在 connect 與第一次寫入之間超過 30 s 會被切,app 既有的重連會處理 ⚠️(未實測),列入「Not tested」。

---

## 3. 安全

- 新輸入:無 ✅。`Connected` 仍只收 sender 檢查過的 BlueZ 訊號(`bluez.go:691`);本機非特權程序無法偽造系統匯流排上 `org.bluez` 擁有者的訊號。
- 遠端無線對手:從「連一次永遠黑」變成「每 30 s 要重連一次」,計畫已誠實寫明不處理;用輪換位址重連造成的 log 量被 `logLimit` 壓住,可忽略。沒有新增可被對手觸發的特權動作(`Device1.Disconnect` 既有)。
- 被攻陷的對端:開 session 的走既有 session 規則,不變。
- 自己的錯:主要風險是 MINOR-3(缺時間 → 靜默回到舊 bug)與 MAJOR-3(測項假 PASS)。
- fail mode:「缺時間就計數」是往「不可用」的方向失敗(不是往不安全),理由成立,但見 MINOR-3。

## 4. v1 審查的 N1 發現是否真的解了

| v1 發現 | 狀態 |
|---|---|
| A-M1 逐裝置年齡、不要直接用沒過濾的 `staleLinks` | 解了:只有在沒有任何「新鮮」裝置被計數時才會到 `register()`,所以 `staleLinks` 切到的都已過期。計畫應明寫這個不變式,並加 v1-A 要的負向對照「1 s 的 B 不會被切」(unit 可做:A 過期 + B 新鮮 → n = 1 → 不到 register) |
| A-M1 不可持 `b.mu` 斷線 | 解了(沿用既有、鎖外) |
| A-M2 / B-B-1 沒有證據 Disconnect 清得掉;先重現;要有上限;廣播恢復不可依賴 Disconnect 成功 | 一半:有 F7 與「照樣 register」退路;沒有重現紀錄、退路依賴未驗證的 F-P41、上限寫短 → MAJOR-2 |
| A:F5 log 沒有 `connection ble` 要寫明 | 沒解 → MINOR-1 |
| A:L80 `watch 15` 會撞、`disconnected N stale link` 失去鑑別力 | 沒解 → MAJOR-3 第 2、3 點 |
| B-M-1 全域 `Sessions()` 含 sock | 實際上不成立(互斥),計畫沒寫 → MINOR-8 |
| B-m-3 要有可分辨的 log 行 | 解了(新行),但見 MINOR-4 |
| B 的測試表(fake bus:Disconnect 失敗仍廣播) | 沒涵蓋,且計畫沒說明 → MINOR-7 |

## 5. 我沒做的

- ❌ 沒上機:F1、F7、`ux/m1.log`、`le_states`、各 harness 測項的實際秒數都沒量。
- ❌ 沒跑 `go test` / harness。
- ⚠️ kernel / BlueZ 的斷線行為是讀原始碼推得,不是實測。

## 6. 判定

**APPROVE-WITH-CHANGES。** 改完 MAJOR-1/2/3 後整份再審。不要因為這份審查加新機制:需要的只有文字更正、生命週期表補列、harness 既有測項的時間/鑑別力調整,以及(可選)把兩張 map 併成一張。
