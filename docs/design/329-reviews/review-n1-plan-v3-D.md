# Review D — `329-n1-plan.md` v3（整份重審）

審查者：D（獨立，未與另一位協調）。日期 2026-11-18。
方法：只讀原始碼（`C:\src\Batman-b8` worktree、WSL 內 kernel 6.6.138 / BlueZ 5.72 原始碼）。沒有跑任何程式、沒有碰節點或手機、沒有跑 `go test`。

**結論：APPROVE-WITH-CHANGES**（0 BLOCKER / 3 MAJOR / 9 MINOR）。
產品端的改動（§3）本身我找不到錯：一張 map、30 s、`Close` 規則兩種事件順序都對、沒有別的讀者。三個 MAJOR 都在測試 / harness 那一半與一句範圍敘述，改文字與測法即可，不需要新機制。

---

## 1. 從現場看（先於作者的清單）

| 現場情況 | v3 處理嗎 | 我的判斷 |
|---|---|---|
| 手機連上、沒開 session 就走出範圍 / 藍牙堆疊卡住（F1 的原始症狀） | 是，約 33–50 s 後回到廣播 | ✅ 走過程式碼，見 §3(a) |
| 掃描類 app（nRF Connect 之類）連上只讀 STATUS、停著不動 | 是，30 s 後被切，之後每 30 s 可再連一次 | ✅；重連循環列在「不處理」，合理（未認證的對端今天就能永久佔住，這次只會變好） |
| 掃描類 app 連上後訂閱 TX（AcquireNotify → `link()` → 有 session） | 走 `IdleAnon` 30 s → `Close` → Disconnect，約 32 s | ✅ 今天就有的路徑，不變 |
| 更新頁開著（`OpenSession`），手機走遠 | **不處理**：session 300 s 閒置後才輪到這條規則 | ⚠️ 計畫的敘述有誤，見 MAJOR-3 |
| 認領頁 `_find` 逐台連附近每一台 provd 節點讀 STATUS | 不是自己的那台 `conn.cancel()`（`app/lib/claim.dart:382`），正常幾秒內放開 | ✅ 不會撞到 30 s |
| 手機慢（connect 15 s timeout + 讀 STATUS + MTU + Keystore 簽章）才寫 msg1 | 計時從 BlueZ `Connected=true` 起算，不含連線前等待；實測 < 9 s（F9） | ⚠️ 只有 S20 一支手機的數字；Windows provclient 未量（計畫自己標了 ⚠️） |
| bluetoothd 卡死、Disconnect 無效 | 不處理，不升級 | 可接受，但 §3.4 的「限速 log」說法不成立，見 MINOR-1 |

漏掉的生命週期路徑：沒有找到。升級 / 降級（map 只在記憶體）、provd 被殺（新 provd 的 `staleLinks`）、bluetoothd / dbus 重啟、SockOnly（F11）都有列且與原始碼一致。

---

## 2. 發現

### MAJOR-1　§5.2 新 arm 的判定「25 s ≤ GONE 時的連線年齡 ≤ 55 s」照寫的做不出來

- **情境**：harness PR 要在舊 image 上 FAIL、rc 上 PASS，並用下界 25 s 證明「不是一連上就被切」。
- **證據**：
  - `scripts/node/prov-p2-central-254.sh:168-175` `watch` 印的是**從 watch 開始**起算的秒數（`t0=$(up)`），不是連線年齡。
  - `:155-167` `hold` 不印連上的時間；它 `connect` 後 `sleep 6` 再輪詢最多 10 s，最多試 3 次。F10 說的「回來時 6–16 s」是**從下 connect 指令起算的上界**，實際 `Connected=true` 可能在那之後 0–8 s 才發生，第 2、3 次重試更不確定。
  - 所以「年齡」= 未知的 hold 內偏移 + SSH 往返 + watch 秒數，誤差本身就有 ±8 s 以上；30 s 的 grace 加 5 s tick 的真值落在 30–50 s，下界 25 s 只留 5 s 餘裕。照寫的做，rc 上會有假 FAIL 或者下界形同虛設。
- **修法**（不加機制，只改量法，二選一）：
  1. 用 04 自己的 log 當尺：`adv withdrawn reason=connect`（`link()` 沒被呼叫時改用 `Connected=true` 那一刻——注意沒有 session 的連線**不會**印 `withdrawn reason=connect`，因為那是 `link()` 印的）→ 所以實際可用的是 `logread -t` 時間戳下的 `provd: link without session for 30 s` 與其後的 `adv registered`；下界改成「02 `hold` 回 HELD 之後至少 N 秒仍 STILL」（N 由 hold 最壞 16 s 推出：30−16=14 s 以內不得 GONE），上界用 hold 開始到 GONE ≤ 16+50 s。
  2. 或讓 `hold` 在看到 `Connected: yes` 時印出 02 的 uptime，`watch` 印 GONE 時的 uptime，兩者相減（同一台機器的單調時鐘）。這要動 central 腳本的輸出格式，`scripts/test-dv-ble-254.sh` 的離線檢查要一起過。
  不管哪一種，計畫要寫出算式與每一項的來源。

### MAJOR-2　縮短 `read`（`read_one` 的 sleep）沒有必要，而且會動到別的 arm 靠它成立的東西

- **情境**：§5 要把 `read` 的 sleep 砍到總長 ≤ 20 s，理由是避免 23–26 s 的 `read` 接近 30 s。
- **證據**：
  - `prov-p2-central-254.sh:112-124`：8+2+1+2+1+8+1 = 23 s。`:116-117` 的註解寫明 CTRL 之後那 8 s 是實測出來的：「04 wbox, 2026-11-01: with 2 s the error line never came」（加密讀被拒時要跑 SMP + 重試）。
  - `scripts/dv/prov-provd-wbox-254.sh:215-245` `gatt_wb` 用 `c02 read` + `GATT_ENCRYPT_CTRL=1`，靠那 8 s 之後的 `ERRS` / `ERRLINES` 判定。這個 arm 只在 prov_test（wbox）image 上跑；計畫的步驟（§6）沒有說要在 wbox image 上重跑它。
  - 另兩個使用者 `prov-netjoin-254.sh:63`、`chain1-254.sh:168` 也走同一個 `read_one`。
  - 就算 `read` 真的超過 30 s 被 provd 切掉，各 arm 斷言的 `adv registered reason=disconnect` 仍然成立（`Connected=false` 訊號照來）；會壞的只有「讀到一半被切」，而 23–26 s < 30 s，讀在第 ~13 s 就做完了。
- **為什麼是 MAJOR**：這是「不必要的修改」加上「改掉一個有實測依據的數值卻不重跑依賴它的測試」。照使用者規則，動到既有判定要附證據。
- **修法**：`read` 不動。在計畫裡寫一句：`read` 的連線最長 23 s + connect 等待，讀在 30 s 前完成；若 rc 上任何 `read` arm 出現 `link without session` log 行就判 INVALID（跟 L80 control 同一條規則）。如果作者堅持要縮，必須指名砍哪一個 sleep（不能是 CTRL 後那 8 s），並在 wbox image 上重跑 `gatt_wb` 與它的反向對照。

### MAJOR-3　§2「今天的 app 每個 session 幾秒內就關」不對；上界 350 s 也少算一段

- **情境**：審查題 (b)。這句話是把「session 中靜默」排除在範圍外的唯一理由。
- **證據**：
  - `app/lib/src/flows/op_session.dart:135-200` `OpenSession`：軟體更新頁開著的整段時間都握著 lease，console `_c` 在兩次請求之間**不關**（`run()` 只在 `c == null || !c.alive` 時重登），到 `pageGone()` 才關。`app/lib/ui/update_route.dart:28,45` 是它唯一的使用者。
  - 其餘頁面（`join_pages.dart:117,721`、`settings_pages.dart`、`more_pages.dart:258`、`dev_pages.dart`、`remove_pages.dart:102`、`rekey_send.dart:112,139`）都是 `OpSession.once`，`finally` 裡關 console（`op_session.dart:126-131`）——這部分計畫說得對。加入等待頁（`MyRequestPage`）是在 `joinreq` 的 `once` 結束後才開，不握 session。
  - 上界：`session.go:287-289` `inflight` 時永不過期；`:611-615` 請求結束後 `lastActive = now` 才重新起算 300 s；`server.go:23` `HelperWait = 330 s`。所以最壞是 330 + 300 + 5 + 15 ≈ **650 s**，不是 350 s。一般情況（沒有卡住的 helper 請求）才是 ≈ 320–350 s。
- **判斷**：排除在範圍外**仍然站得住**——更新頁握著 owner session 是設計如此，節點無從分辨「頁面開著但人沒動」與「手機走了」，要處理就得動 idle 上限，那是另一個決定（計畫已說歸 app keep-open 的那張單）。而且今天的行為（永遠黑）在這次之後變成有上界。但理由與數字要寫對，否則使用者會以為「現在很少見」。
- **修法**：§2 與 §4 生命週期表第 69 行改成：「今天只有軟體更新頁會讓 session 開著（`OpenSession`）；手機在更新頁上走遠 → 最多約 320 s（請求卡在 helper 時最多約 650 s）後回到廣播。其他頁面每次操作關 session。」交付時在 PR「不處理」清單照寫。

---

### MINOR-1　§3.4「限速 log」在 Disconnect 無效 + kernel 拒絕廣播時不成立
`bluez.go:617-625` `logLimit` 只跟**上一行**（`lastWhy`）比。每個 tick 會交替出現 `link without session`／`staleLinks` 的行（`:565` 根本不走 `logLimit`）與 `register` 失敗行（`:593`），兩者互相把對方「洗掉」，結果每 ~20 s 各印一次、不會被壓住。計畫靠 `devEnt.logged` 讓新行只印一次是對的，但 `:565`、`:593` 那兩行仍會一直印。這條路徑計畫自己標 ❌ 未測。修法：把「rate-limited log」改成實際行為（「每輪約 20 s 各一行，syslog 是 ring buffer」），不要為它加機制。

### MINOR-2　unit 名稱是 `boot-provd`，沒有叫 `boot` 的 unit
`scripts/dv/prov-provd-254.sh` 的 unit 是 `boot-provd|respawn|dep-restart|sec-dbus|rpa`；`daily-validation.sh:310` 的 suite 名是 `prov-boot-provd-254`。known-failures 的 suite 欄要寫 `prov-boot-provd-254`。同一個 harness PR 也要更新 `:310`（與 `:311` 若 L80 文字改了）的 suite 說明。

### MINOR-3　known-failures 條目可行，但計畫沒寫出它的三個條件
`scripts/dv/known-failures.sh`：suite 只有在**每一行** `FAIL` 都對得上未過期條目時才是 KNOWN；`NEVER_KNOWN`（`restore|cleanup|CONNECTION-LOST|CONNLOST|reboot did not happen|unreadable|not verified|rc=3 without|NEEDS-PERSON|blocked: DNODE`）的字出現就永遠是新失敗；KNOWN 不會變綠（exit 仍 1）；issue 關了條目就失效。所以：(1) 新 arm 在舊 image 上必須**只印一行**固定字樣的 FAIL（例如 `pre-N1 image: link without session not dropped`），不能是好幾個 `no`；(2) 字樣避開上面那些字；(3) #329 在產品 PR 進 main、pin bump 之前不能關。§5.4 的 14 天到期合乎檔案格式（`expires=YYYY-MM-DD`）。✅ 機制存在且這支腳本用得上（題 (e)）。

### MINOR-4　L80 control `watch 15` → `watch 8`：可以，但要說明少掉的覆蓋
`254-p2-impl.md:294,:545` 的 L80 是「新 provd ≤ 15 s 切掉舊連線」；control 用 15 s 是為了對齊同一個窗口（不殺 provd 時 15 s 內不會自己掉）。改 8 s 後 control 只證明前 8 s。kill arm 另外要求 `disconnected N stale link` 計數上升（`prov-provd-254.sh:129-134`），所以鑑別力還在：連線若在 8–15 s 自己掉，計數不會上升 → FAIL。安全（題 (f)），但請在計畫寫出這個理由。另一個不必改數字的做法：control 維持 `watch 15`，改成在 `hold02` 一回來就立刻 watch，並把 INVALID 規則（出現新 log 行）當護欄——連線年齡最壞 16+15+SSH ≈ 33 s 會越線，所以 `watch 8` 確實是較穩的選擇；我接受 v3 的做法。

### MINOR-5　新 arm 加進 `boot-provd` 後的 lease 預算沒算
`prov-provd-254.sh:80` `lease 1500`。新 arm 至少多 hold 16 s + 等 55 s + 收 log。❌ 我沒有量現行 unit 的耗時；計畫要附 rc 上這個 unit 的實際總秒數，確認離 1500 s 還有餘裕。

### MINOR-6　§5.1「`link()` 的 map insert」——測試不能呼叫 `link()` 本身
`bluez.go:294-313` `link()` 會呼叫 `srv.Accept` 與 `withdraw("connect")`；沒有 bus 的 `bleSide` 上要直接寫 `links` map（計畫是這個意思，✅ 可行：`Close` 在 `conn == nil` 時跳過 D-Bus，`:414-418`；`deviceChanged` 只需要 `bluezName`，`:691`）。請在 T 表上寫明「直接插入，不呼叫 `link()`」，並把 `:491` 的 reset 抽成小函式這件事列進 §3 的改動清單（它是產品碼的改動，不只是測試）。

### MINOR-7　F10 的「6–16 s」寫法
見 MAJOR-1：那是上界、而且是從 connect 指令起算。改成「回來時連線年齡 0–16 s」。

### MINOR-8　F9 的檔名
F9 引的是 `app/lib/claim.dart`（✅ `:335-370` 是 `_find`、`:497-530` 是 STATUS 之後到 msg1 之前），不是 `app/lib/src/…`。寫完整路徑。`:528-529` 有 Keystore `signOwner`：⚠️ 我沒有查它會不會跳生物辨識；若會，那就是連線後的一個「人的步驟」，但實測 < 9 s 顯示目前不會。

### MINOR-9　對端在 `Accept` 回 nil 時反覆寫 RX
`link()` 在 `Accept` 失敗時走 `l.Close()`，依 §3 規則會給現有 entry 新的 grace → 對端每 <30 s 寫一次 RX 就能一直不被這條規則切。但 `Close` 本身就會呼叫 `Device1.Disconnect`，所以連線還是被切。無害，請在 §4 安全段記一句，免得下一位審查者再查。

---

## 3. 指定要查的六題

**(a)「約 50 s」**　✅ 對 §2 列的每條路徑都成立（上界），走法：`deviceChanged` 記 `since` → 30 s 後 `liveLinks` 不再算 → 下一個 tick ≤ 5 s（`bluez.go:656-681`）→ `converge` `!advOn`（`:780-781`）→ `register()` → `staleLinks()` 最多 3 輪 × 5 s（`:526,:557`）→ `RegisterAdvertisement`。活著的連線 Disconnect 立刻生效，實際約 31–36 s；殭屍連線由 kernel 2 s 逾時清掉（F8），約 33–40 s；50 s 是 Disconnect 三輪都沒清掉的上界。沒算進去的只有 `converge` 自己的 D-Bus 呼叫（`HealthOK` / `adapterOK` / `KernelInstances`）與 3 次 `GetManagedObjects`，正常是毫秒級。⚠️ 純讀碼，沒有實測。

**(b) session 中靜默排除在外**　站得住，但理由句與上界要改——MAJOR-3。

**(c) `bleLink.Close` 規則**　✅ 兩種順序都對：
- `Connected=false` 先到 → entry 已刪 → `Close` 找不到 entry、不寫 → 沒有孤兒時間戳（v2 A-M1 的洞補上了）。
- `Close` 先到 → 刷新 `since` → 隨後 `Connected=false` 刪掉。
- `Close` 後連線沒斷 → 再 30 s 後由 `staleLinks` 切。
- 刷新是必要的：session 存活超過 30 s 的連線若不刷新，`Close` 到 BlueZ 回報斷線之間（最多 2 s）會立刻被當成「沒有 session 的連線」而印一行假的 log。

**(d) `devConn` 的其他讀者**　✅ 沒有。全樹 `.go` 檔 grep，只在 `bluez.go`（宣告 `:54`、初始化 `:64`、reset `:491`、`deviceChanged` `:694-721`、`converge` `:733`、`staleLinks`）。`testenv_*.go` 不碰它。腳本只讀 log 字樣。`scripts/dv/data/p3-units.tsv:11`（OW3）引用 `bluez.go:776-781` 的行號——型別改動會讓行號位移，請在產品 PR 一併更新那一格。

**(e) #290 順序**　✅ 可執行；三個條件見 MINOR-3，unit / suite 名稱見 MINOR-2。

**(f) 動既有 arm**　`watch 15`→`watch 8`：安全，見 MINOR-4。縮短 `read`：不安全也不必要，見 MAJOR-2。

---

## 4. 事實查核 F1–F11

| # | 結果 | 備註 |
|---|---|---|
| F1 | ⚠️ 無法從原始碼查 | 一次現場觀察；v2-B 要的「沒有 `connection ble`」那句已補上 |
| F2 | ✅ | `devConn` `:54/:64`，`converge` `:733`、`:772-781` |
| F3 | ✅ | reset 在 `:491`（`refreshOwner` `:480-495`） |
| F4 | ✅ | `link()` `:294-313`，呼叫者 `:143/:166/:183` |
| F5 | ✅ | `Close` `:394-420`，Disconnect `:416-418` |
| F6 | ✅ | `staleLinks` `:518-567`，3 輪 × 5 s；另在 `:743` 也被呼叫 |
| F7 | ⚠️ 無法查 | #329 的留言 / 原始輸出；計畫說產品 PR 才貼 |
| F8 | ✅ | kernel `hci_sync.c` `hci_abort_conn_sync` 起於 `:5651`，`HCI_CMD_TIMEOUT` 2000 ms（`hci.h:444`）；BlueZ `adapter.c:8496-8519` `MGMT_STATUS_NOT_CONNECTED` 仍走 `dev_disconnected`。兩個 target（bcm2710 / bcm2711）的樹都有同一版 |
| F9 | ✅ 行號對，路徑要寫全 | MINOR-8；`prober.dart` ~`:123` 8 s ✅；`settings_page.dart:1-3` ✅ |
| F10 | ⚠️ 行號 ✅，「6–16 s」的意思不對 | MINOR-7；`hold02` 使用處 `:99-106`、`:124-137`、`:192-200` ✅ |
| F11 | ✅ | `main.go:88-100` |
| 其他 | ✅ | `server.go:30-31`、`ci.yml:141`（`go test ./...`）、`254-p2-impl.md` F-P17 `:40` / F-P41 `:64` / L80 `:294` |

## 5. v2 發現是否真的解決

| v2 | 狀態 |
|---|---|
| A-M1 兩張 map / 孤兒時間戳 | ✅ 一張 `map[path]*devEnt`，`Close` 只動現有 entry |
| A-M2 單元測試只測純函式 | ✅ T1–T8 餵事件到寫入點；可行性見 MINOR-6 |
| A-M3 / B-M3 harness（read、L80 control、kill arm、順序、量 GONE、log 契約） | 部分：順序 ✅、log 契約 ✅、kill arm INVALID 規則 ✅；量法 ❌（MAJOR-1）、`read` ❌（MAJOR-2） |
| B-M1 生命週期列錯 / session 中靜默 / 上界 | 部分：列已更正；理由句與上界仍錯（MAJOR-3） |
| B-M2 沒有重現紀錄 / 50 s / F-P41 | ✅ 文字上：§5.5 有嘗試步驟，未測項目標 ⚠️/❌；重現仍是「替身 central」，計畫誠實標了 |
| A-m1 logLimit | ❌ 說法仍不成立（MINOR-1） |
| A-m2 / m4 / m5、B-minor（F1 句、`:491`、合併 map、log 文字） | ✅ |

## 6. 安全

- 遠端無線對端：攻擊面沒有新增輸入。未認證對端今天可永久佔住連線；之後每次最多 30 s，可重連（列在不處理，連線期間節點不廣播這點不變）。沒有放大。
- 30 s 內合法 client 被切的風險：依 F9；Windows provclient 未量 ⚠️。
- 本機非特權行程：`deviceChanged` 檢查 sender 是 bluez 的 unique name（`:691`），偽造訊號進不來；沒有新檔案、socket、設定鍵。✅
- 被攻陷的對端：見 MINOR-9，無害。
- 失敗模式：切錯 = 一次重連（fail-safe）；log 行不含位址以外的秘密（⚠️ 請確認新 log 行印的是 D-Bus path 還是 MAC——`254-p2-impl.md` 的 log 契約對位址怎麼寫，產品 PR 要對一下）。
- 反向對照：單元測試「29 s 仍算、30 s 不算」＋裝置 arm 舊 image FAIL。前者 ✅ 是真的；後者待 MAJOR-1 修好量法。

## 7. 不必要的東西

- 縮短 `read`（MAJOR-2）——拿掉。
- 其他沒有：`logged` 旗標、`Close` 刷新、單調時鐘都各有必要理由。

## 8. 我沒有做的

- ❌ 沒有跑 `go test`、沒有上機、沒有量任何時間。
- ❌ 沒有讀 #329 issue 與其留言（F1 / F7 / S20 的 4.1 s、8.6 s）。
- ❌ 沒有量 `boot-provd` unit 現行耗時（MINOR-5）。
- ❌ 沒有查 `signOwner` 是否會要求使用者驗證（MINOR-8）。
- ⚠️ 「約 50 s」與 650 s 上界都是讀碼相加，不是實測。

## 9. 裁決

**APPROVE-WITH-CHANGES。** 產品端設計可以照做；動手寫 harness 前先改三處：
1. §5.2 的量法與算式（MAJOR-1）；
2. 拿掉「縮短 `read`」，改成 INVALID 護欄（MAJOR-2）；
3. §2 / §4 的「今天的 app」句與上界（MAJOR-3）。
MINOR 可在同一版一起改。依規則，MAJOR 未關前要改版再審整份。
