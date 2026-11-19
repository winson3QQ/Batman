# Review B — `329-ux-speed-plan.md` plan v1 (N1 / N3 / A1 / A2 / N2)

審查者 B(獨立、對抗式)。2026-11-18。只讀原始碼與文件;沒有碰任何節點、手機,沒有 adb / ssh。
基準(lease / OpSession / OpenSession / LoginFor、provd session 協定、Slots=2)不重審,只審計畫改動的部分與它對基準的影響。

## 結論(verdict): REJECT(整份 v1);N1 單獨拆出後可 APPROVE-WITH-CHANGES

- N1 是使用者第二個抱怨(04 消失 40 分鐘)的正確方向,但它的關鍵假設(`Device1.Disconnect` 能清掉 F5 那種狀態)沒有證據,且「失敗就繼續暗」等於沒修。
- N3 建立在一個沒驗過、而且 kernel 原始碼顯示很可能不成立的前提上(連線後廣播仍在空中)。
- A1 照寫的樣子與 app 現有的單一擁有者結構(一條 link、一個 lease)互相矛盾,§4 的擁有者說不通,而且改了已審過的基準卻沒有列出來。
- 建議的最小範圍在 §「範圍建議」。

證據分級:✅ = 我對原始碼 file:line 讀過;⚠️ = 推論或未驗證;❌ = 沒做。

---

## 對 brief 各問題的直接回答

**Q1. F5:是 links / devConn / Sessions() 哪一個讓廣播關著?**
✅ 是 `devConn`,單獨它。
- `provd: connection ble` 只在 `Server.Accept` 印(`server.go:816`,經 `logLimited`);`Accept` 只由 `bleSide.link()` 呼叫(`bluez.go:308`);`link()` 只在第一次 RX WriteValue / AcquireWrite / AcquireNotify 時建立 `links` 條目(`bluez.go:294-313`)。
- CTRL / STATUS 的 `ReadValue`(`bluez.go:121-134`)與 MTU 交換不建立 `links`,也不建立 session。所以 GATT 連線可以存在而沒有 `connection ble`。
- F5 的 log 在 `withdrawn reason=connect` 之後沒有 `connection ble` ⇒ 那次 withdraw 來自 `converge`(`bluez.go:733` `nlinks = len(b.links)+len(b.devConn)`、`:772-776`),不是 `link()` 的 `:307`。`links` 空、`Sessions()` 0,只有 `devConn` 一筆。
- ⚠️ 唯一保留:`logLimited` 每 key 每分鐘 10 行(`server.go:137-156`),那一分鐘內若已滿 10 行會吃掉 `connection ble`;F5 當時沒人在用,可能性低,但計畫應附 04 當時前一分鐘的 log 行數排除它。

**Q2. N1 的條件抓得到 F5 嗎?** ✅ 抓得到(devConn 有、links 無、無 session)。但見 M-1(「no session」必須是每裝置)與 B-1(Disconnect 是否有效)。

**Q3. GATT 已開始後才半開的 link(有 `links` 條目、裝置已不在)今天怎麼結束?**
✅ 兩條路,都不保證:
1. fd HUP:`watch()` 讀到 err/0 → `l.Close()`(`bluez.go:322-334`)。只有 BlueZ 自己知道斷線才會關 fd;F5 正是 BlueZ 不知道的情況。
2. session idle:`expired()`(`session.go:282-297`)HandshakeMax 10 s / IdleAnon 30 s / IdleAuthed 300 s → `Kill` → `bleLink.Close()`(`bluez.go:394-420`)刪 `links` 條目,並以 `go ... Call` 非同步送 `Device1.Disconnect`、**結果丟掉**(`bluez.go:417`)。helper 請求進行中(`inflight`,`session.go:125`)不計時。
- 之後 `devConn` 是否清掉完全看 BlueZ 有沒有發 `Connected=false`。沒發 ⇒ 今天一樣永遠暗。N1 會在 15 s 後再試一次 Disconnect,所以 N1 **需要也確實會**涵蓋這個情況,但計畫的生命週期表沒有這一列,也沒有測試(見 M-2)。

**Q4. F9 的 300 s 與「每 60 s 讀一次 status」成立嗎?節點成本?**
✅ 成立,成本可忽略。
- 300 s 只適用 Owner / Member 角色(`session.go:290-292`);Anon / Candidate 是 30 s。
- status 請求:每 session 1 次/s 上限(`statusAt` → ERate),再 `roCall("status.get")`(`session.go:876`)。helper 端 ro 配額全域 10/s burst 40、每連線 5/s burst 20,另有 status 專用桶(`node/readonly.go:7-8, 24-25, 58-60, 104`);helper 的 status 來自背景快取(`cmd/batman-provhelper/status.go:4`)。2 支手機 × 1 次/60 s 遠低於任何上限。
- 真正的成本不在節點而在手機與「永遠佔著 2 個槽」(見 B-3、M-5)。

**Q5. session 撐得過流程需要的事嗎?**
✅ 撐不過這幾個,計畫只提了 rekey:
- rekey:`rekey_send.dart:112` 與 `:139` 是兩次 `OpSession.once`,第二次必須是新登入。
- leave / remove owner:provd `reconcile`(`server.go:638-679`)砍掉 key 不在 owners 裡的 owner session(owner-removed)、psk 變更砍 member session(psk-rotated)。
- claim / replay:`killOthers`(`server.go:848-860`)砍其他 session。
- 設定套用後節點重開、軟體更新重開:link 斷。
這些在 A1 下每一個都是「保留的 session 被節點端殺掉」,需要一列生命週期與測試(M-4)。

**Q6. prober 多常讀、每輪是否登入、lease 下是否暫停?**
✅ 每次 attempt 都開節點紀錄(Keystore,`prober.dart:208`)、要 MTU 517(`:215`)、讀 ctrl(`:217`)、完整 OwnerSession 登入、讀 status、然後丟掉 session(`:265`;檔頭 `:4-5` 明寫紀錄只為這次 attempt 打開)。home / team 頁每 60 s 一輪讀每一筆紀錄(`core.dart:74-77`)。lease 被持有時 NodeLink 的 token 失效(`lease.dart:131`),`acquire` 取消該輪並丟掉所有 link(`node_link.dart:253-270`)。

---

## BLOCKER

### B-1 N1 的關鍵假設沒有證據:`Device1.Disconnect` 能清掉 F5 的狀態嗎?失敗時節點仍然永遠暗

- **情境**:F5 重演。BlueZ 說 `Connected: yes`,手機端 ACL 早已 teardown,持續 40 分鐘,遠超過任何 supervision timeout。這不是「一條活著但沒人用的 link」,而是 bluetoothd / kernel / 控制器之間某一層狀態卡住,原因計畫自己標 ❓。N1 在 15 s 後呼叫 `Device1.Disconnect`。若 kernel 已無該 hci_conn(或控制器不回 Disconnection Complete),BlueZ 可能回錯或永不發 `Connected=false`;`devConn` 留著。計畫 §4:「If Disconnect fails, the next converge tries again; advertising stays off meanwhile, as today」⇒ 節點照樣永遠暗,使用者的抱怨沒修。
- **證據**:計畫 F5 最後一行(原因不明);`staleLinks()` 本身每輪等 5 s、3 輪後放棄(`bluez.go:518-567`);`bleLink.Close` 的 Disconnect 結果被丟掉(`bluez.go:417`)。沒有任何一處顯示在 F5 狀態下 Disconnect 有效。
- **測試不是重現**:§5 的真機測試「02 開一條 link 然後放著」造出的是**活的**無 session link(今天 02 一斷就恢復),不是 F5 的殭屍。依專案規則,bug 要先在真機重現才修;這個測試通過不代表 F5 修好。
- **修法**(三件都要):
  1. 設計前唯讀探查:若 04 還在那個狀態(或下次再發生),收 `hcitool con` / `btmgmt con` / `/sys/kernel/debug/bluetooth/hci0/` 對照 BlueZ 的 `Connected`,確定卡在哪一層;再經使用者同意做一次 `Disconnect`,記錄它有沒有清掉。這就是 N1 的證據。
  2. **廣播決策不要依賴無 session 的 `devConn`**:寬限期(15 s)過後,沒有 `links` 條目的 `devConn` 不再計入「有連線」;即使 Disconnect 失敗,provd 仍 withdraw→register 重新廣播。這樣節點的恢復不取決於那個不明原因。若此時 `RegisterAdvertisement` 或空中廣播仍失敗(控制器真的以為有 link),升級到下一層(例如經 helper 重啟 bluetoothd,今天 `reason=bluetoothd` 路徑已存在),並寫明升級條件與上限。
  3. 重現方法要能造出「BlueZ 以為連著、對端已走」:例如 02 當 central 連上後直接把 02 的 hci 拔電 / `hciconfig down` 或進遮蔽,而不是正常 disconnect;若仍造不出 F5,計畫要老實寫「未重現,修法依據為原始碼推論」並先問使用者。

### B-2 N3 的前提(第一支手機連著時廣播仍在空中)沒驗過,kernel 原始碼顯示很可能不成立

- **情境**:手機 A 連上 04。N3 下 provd 不 withdraw,`advOn=true`、BlueZ `ActiveInstances=1`。手機 B 掃描 04:掃不到。計畫的「a connected node stays visible to another phone」不成立,而且 provd 以為自己在廣播,log 與 status 都說謊。
- **證據** ✅(kernel 6.6.138,`firmware-2710/build_dir/.../linux-6.6.138/net/bluetooth`):
  - `hci_event.c:5636-5640`:LE 連線完成時「All controllers implicitly stop advertising in the event of a connection」→ 清 `HCI_LE_ADV`。
  - `hci_event.c:3412-3424`:重新開廣播只在 **disconnect complete** 處理裡做。連線期間 kernel 不會自己重開。
  - 要在連線中再開,只能靠新的 register(今天 `rpa_timeout` 那條,最長約 900+rand s 之後),而且要過 `is_advertising_allowed`(`hci_sync.c:1007-1040`):有 peripheral 連線時 connectable 廣播需要 `le_states` bit 38 與 bit 21,否則 `-EINVAL` / `-EPERM`(`:1874`、`:1404`)。
  - `254-p2-impl.md:64`(F-P41)這一點對 BCM4345C0 仍標 ⚠️ 未量測;`:337` 設計假設為「不允許」;`:105` 寫明「BLE 空中實際同時只有 1 條,第 2 槽實務上只有 sock 用得到」。
  - F6 的證據不具鑑別力:當時那條 link 是 F5 的殭屍(kernel 可能根本沒有 hci_conn ⇒ `hci_conn_num==0` 直接放行),而且計畫自己寫「not checked on air」。
  - ⚠️ BCM4345C0 走 legacy 還是 extended advertising 未查(F4 也這麼寫);extended 路徑的行為我沒有逐行驗。
- **修法**:
  1. N3 動手前先做一個唯讀 + 一次授權的真機探查:手機 A **活的** link(有 session)在 04 上,02 當第二個 central 掃描並連線;同時讀 04 的 `le_states`(`btmgmt info` / debugfs)。結果寫回 F-P41。
  2. 若控制器支援:N3 必須在每次連線建立後明確 withdraw→register(不是「advert stays」),並定義 `RegisterAdvertisement` 失敗時的行為(退回今天的 withdraw,log 一行)。
  3. 若不支援:N3 整個刪掉,A1 必須縮小(見範圍建議),因為「保留 link」就等於「別的手機看不到這台」。
  4. 無論哪種:`staleLinks()` 在每次 `register()` 都跑(`bluez.go:590`),會斷掉所有 Connected 但不在 `links` 的裝置;N3 讓 register 在有人連著時發生,剛連上還沒寫 RX 的第二支手機、或只讀 STATUS 的 central 會被踢。要先把 `staleLinks` 改成只踢「超過寬限期」的裝置。

### B-3 A1 與 app 的單一擁有者結構矛盾;§4 的擁有者說不通;改了已審基準卻沒列

- **情境**:擁有者有 6 台節點在範圍內,app 在前景。A1 要 NodeLink 對 4 台各保留一條已登入 session。使用者點 04 的 Wi-Fi 頁。
- **證據** ✅:
  - `BleGate` 全 app 最多一條 link:檔頭 `ble_gate.dart:1-4`「One scan and one link at most」;已有 link 時 `connect` 丟 `Refused('a link is already open')`(`:239-242`)。4 條保留 link 直接違反。
  - `LeaseRegistry` 只有一個 lease(`lease.dart:111, 135-140`);有 lease 時 NodeLink 的 token 為 null(`:131`),`GateLink._usable` 要 token 有效(`ble_gate.dart:86-88`),`released` 會關掉該 token 的 link(`:262-266`)。
  - `NodeLink.acquire` 在交出 lease 前取消該輪並丟掉所有 link(`node_link.dart:253-270`);`loginFor` 要求 `gate.links == 0`(`:352`)。
  - 所以「NodeLink 保留 session」+「The lease still serialises them」+ §4「A1 holds the session lease while a node page session is open, and the prober pauses」三句不能同時成立:
    - 保留的 link 屬於 NodeLink 的 token ⇒ 任何流程拿 lease 的瞬間它就被關掉,「0 new logins」不成立。
    - 若改成頁面開著就一直握 lease ⇒ 其他所有操作(claim、join、別台節點的頁、home 狀態輪詢)在整個停留期間都拿不到 lease,home 的其他節點狀態停止更新;這比今天更糟。
    - 若 link 在 NodeLink 與 lease 持有者之間交接 ⇒ 同一資源兩個寫入者(誰關、誰重開、token 換手後 `_usable` 的判定),正是 §4 該回答而沒回答的。
  - §4 Owners 完全沒寫:保留的 `GateLink` / `OwnerSession` / 已解封的節點紀錄(key)誰擁有、誰可以關、誰決定重開、cap 4 滿了誰決定踢哪一台。brief 明列這三個問題,計畫都沒答。
  - 已審基準被改而未列:gate「一條 link」、lease 與 NodeLink token 的互斥、prober「紀錄只為這次 attempt 打開、session 結束即丟」(`prober.dart:4-5, 265`)。依專案規則,計畫要先列基準與新範圍。
- **修法**:採用「範圍建議」的小 A1(不動 gate 的一條 link、不動 lease 語意),或者把 A1 當成對基準的改版,另寫一節逐條列出要改的基準不變量、每個資源的唯一擁有者與交接規則,再審。v1 的寫法不能實作。

---

## MAJOR

### M-1 N1 的「no session」沒定義成每裝置;15 s 計時狀態與 `staleLinks` 重用都有洞
- **情境 a**:harness 的 sock session 或另一支手機的 session 在;04 上有一筆殭屍 `devConn`。若 N1 用全域 `Sessions()` 判斷(§4 Contracts 寫的正是「reads `devConn`, `links` and `Sessions()`」;`Sessions()` 連 sock 都算,`server.go:835-845`),殭屍永遠不被清。
- **情境 b**:`staleLinks()` 照現狀會斷掉**所有** Connected 且不在 `links` 的裝置(`bluez.go:518-567`)。一筆裝置滿 15 s 觸發 sweep 時,1 秒前剛連上、還在做 MTU / 讀 CTRL 的另一支手機一起被踢。A1 + N3 下這是常態(兩支手機)。
- **情境 c**:「for 15 s」需要每裝置的首次看到時間;這是 `bleSide` 的新狀態,擁有者沒問題但計畫沒寫,也沒寫 provd 重啟 / bluetoothd 重啟後計時從哪裡起算(`devConn` 重建時)。
- **修法**:條件寫成「`devConn[dev]` 存在、`links[dev]` 不存在,持續 ≥15 s(以 provd 第一次看到該裝置 Connected 起算,單調時鐘)」;sweep 只斷符合條件的那幾台;不看全域 `Sessions()`。單元測試三個負向對照:有 sock session 時殭屍仍被清;剛連上 1 s 的裝置不被踢;有 `links` 條目的裝置不被踢。

### M-2 生命週期表缺列
缺的路徑(每列要有今天 / 之後 / 測試):
- GATT 開始後才半開(Q3)。
- Disconnect 失敗(B-1)。
- provd 重啟時已有手機連著(`devConn` 由 inventory 重建,`254-p2-impl.md:224-227`;N3 下重啟後要不要踢?今天是 register 前全踢)。
- 降級到沒有這個改動的 provd(A1 app + 舊節點:保留 link = 該節點對別人全暗,只要 app 在前景;計畫表寫「both work; old node lacks only N1」是錯的,舊節點缺 N3 時 A1 會讓它對第二支手機消失,比今天糟)。
- 節點端殺掉保留的 session:rekey、leave、remove owner、claim `killOthers`、psk 變更(Q5)。
- 設定套用後節點重開、軟體更新(update 頁已有自己的 `OpenSession`,`update_route.dart:28`;與保留 session 是同一條還是兩條?)。
- 6 台在範圍、cap 4:誰被踢、踢的規則、被踢的那台 home 狀態怎麼讀(回到今天的每輪登入?那 gate 的一條 link 又衝突)。
- 擁有者手機 + 成員手機在同一節點(M-5)。
- 手機鎖屏(`lifecycle` paused/hidden/detached = background,`node_link.dart:228-237`):30 s 計時器在 Android 背景是否會跑沒有保證;app 被系統殺掉時不會有任何關閉動作 ⇒ 完全依賴 N1 / IdleAuthed 300 s。要寫明「不依賴 app 端計時器」並測。
- 藍牙關→開、手機 RPA 輪換 / 節點 RPA 輪換(保留 link 以位址為鍵;重連要重新掃描,gate 掃描上限 4 次 / 30 s;重連風暴對 provd `handshakeAllowed` 20/min,`server.go:682-698`)。
- 走出範圍再回來(goneMax 420 s / rawGoneMax 900 s 與「quietly reopened」的互動)。

### M-3 N3 的計數公式沒定義,照字面會重複計算
- 「BLE links + sessions reach `Slots`」:一支手機今天 = 1 `devConn` + 1 `links` + 1 session = 3。照字面一支手機就滿了。
- **修法**:定義為「不同裝置數(`devConn` ∪ `links` 的 key)+ sock session 數 ≥ Slots」,並說清楚寬限期後的無 session `devConn` 是否計入(依 B-1 修法 2:不計)。單元測試覆蓋:1 手機、1 手機 + 1 sock、2 手機、1 手機 + 1 殭屍。

### M-4 N3 改掉的書面契約與測試沒列;harness 改動必須另開 PR 先進 main
會變的契約 ✅:
- `254-p2-impl.md` §4.4 `:224-227`(「有連線建立 → 撤銷;所有連線結束 → 重新註冊」、RPA「provd 無連線時每 900+rand s」、log 契約 `adv registered reason=<start|disconnect|rpa_timeout|health|helper|bluetoothd>` / `adv withdrawn reason=<health|helper|connect|stop|bluetoothd>`)、`:95`、`:105`、`:133`(adv instance 的兩個寫入者)、L80 `:294`、`:337`。
- `reason=connect` 的語意從「有任何連線」變成「槽滿」;`reason=disconnect` 從「最後一條走了」變成「從滿變不滿」。

會壞的 harness(先開 harness PR,附舊版 FAIL / 新版 PASS):
1. `scripts/dv/prov-provd-254.sh`:`:85-90`(02 讀 STATUS 必須 log `adv withdrawn reason=connect`)、`:99-105`(握住 link → `withdrawn reason=connect`、0 instances;放掉 → `registered reason=disconnect`)、`:129-133`(L80 `disconnected N stale link(s)`,N1 會多出這行)、`:229-255`(RPA 段期待 `reason=disconnect` 註冊);註解 `:10-11, :15, :35`。
2. `scripts/dv/prov-netjoin-254.sh:62-64`(以 `adv withdrawn reason=connect` 的次數當作 02 連到 04 的證明 — N3 後永遠是 0,這個測試會變成找不到東西;必須改用別的證據,而且不能靜默通過)。
3. `scripts/node/prov-p2-254.sh` 的 `adv_instances` 相關段(原因字串不變,但「連線中 instances = 0」的斷言要查)。⚠️ 我沒有逐行讀完。
4. `scripts/node/prov-p2-central-254.sh`、`scripts/node/ble-central-254.sh`(central 工具;計畫要用它造「開了就放著」的 link,N1 的 15 s 會打斷任何握住無 session link 超過 15 s 的既有段)。❌ 這兩支我沒讀。
5. `docs/design/254-h4-harness.md`、`scripts/dv/data/p3-units.tsv:11`、`docs/validation/p3-manual-rows.md:24`(OW3)。
6. `cmd/batman-provd/` 今天沒有任何 Go 單元測試(只有 `bluez.go`、`main.go`、`testenv_*.go`)。計畫的「provd unit test with a fake bus」需要先在 `bleSide` 開一個 bus / 時鐘的接縫;這是新東西,要寫進計畫與工作量。

### M-5 兩個槽被保留 session 長期佔滿:擁有者被鎖在外面
- **情境**:成員的手機開著 app 放在桌上(螢幕常亮或充電中),對 04 保留一條 Member session,每 60 s 一次 status 保活。另一位成員也一樣。擁有者要改設定:兩槽都滿,廣播被 withdraw(N3),擁有者連掃都掃不到,只能去找人關 app。同樣地,dev harness 的 sock session 也會被擠掉(sock 與 BLE 共用 `Slots`,`server.go:804, 835-845`)。
- **證據** ✅:`Accept` 槽滿時只踢最舊的**未驗證** session;`evictable` 不含 Owner / Member(`session.go:155-169`)。今天 session 壽命是秒級,這個規則夠用;A1 把它變成小時級。計畫說「In the field this needs owner + member + a third phone」把它當罕見,但一人一節點 + 隊員手機都連自己節點的現場模式下,兩支常駐手機佔滿一台是常態設定。
- **被入侵的成員手機**:同一路徑就是對擁有者的持續鎖定,成本是一支有 psk 的手機。今天做不到(每次只佔幾秒),這是 A1 新增的攻擊面,§Security 沒列。
- **修法**:小 A1(只有開著節點頁才保留)把佔用時間縮回「人正在看」;另外要嘛保留 session 在 app 端有上限(例如無操作 N 分鐘就放掉),要嘛節點端讓 Owner 登入可以擠掉最舊的閒置 Member。後者改 session 協定基準,不建議這輪做。

### M-6 A1 的安全差異沒寫全
- **金鑰與 session 在記憶體的時間**:今天節點紀錄只在一次 attempt 內解封(`prober.dart:4-5, 208`),session key 用完即丟。A1 讓最多 4 台的 session key(以及是否連已解封的紀錄)在前景期間常駐。計畫 §Security 說「same keys and the same node-side limits」,沒有說記憶體裡留什麼、app 進背景 / 被 dump 時怎麼清。
- **偷走的已解鎖手機**:今天每個動作都重新開紀錄 → 經 Keystore gate(`keyError` → X26,`app_link.dart` 的 `keyErrorToRadio`)。A1 下動作走保留的 session,**不再經過 Keystore**;若 key gate 帶使用者驗證時效或金鑰被撤(X26),保留的 session 仍可下指令。要寫明每個會改狀態的動作是否仍重新過 key gate;建議:讀取用保留 session,改狀態的動作前仍做一次 key 使用檢查,或 key gate 拒絕時立刻關掉所有保留 session(並測)。
- **遠端 BLE 對端**:N3 下握一槽的匿名對端只能握 10 / 30 s(HandshakeMax / IdleAnon),可接受;兩個殭屍 / 兩條 link 仍讓節點全暗;每 15 s 重連仍是 DoS(計畫已承認,沒變糟)。新增的是「連線中仍廣播」讓被動觀察者把節點的 RPA 與一條進行中的連線關聯起來,且 `rpa_timeout` 在連線中重註冊時位址是否真的換(連線中換 random address 需要關廣播,`hci_sync.c:1886-1892` 一帶)未驗證 ⚠️ — F8 說「does the same without a disconnect」沒有證據。
- **節點上的本地行程**:`deviceChanged` 的 sender 檢查不變(`bluez.go:691`,計畫寫 `:683` 行號有誤)。N1 新增的動作是 Disconnect,只由 BlueZ 的狀態驅動;本地非 root 行程做不到。✅ 沒有新輸入。
- **失敗模式**:N1 Disconnect 失敗 = 繼續暗(fail-closed 對可用性是錯的方向,見 B-1);N3 register 失敗的行為未定義。
- **每項要有負向測試**:key gate 拒絕後動作被擋;成員 session 被 psk 輪換砍掉後 app 不會用舊 session 再送;非 root 行程送假的 `PropertiesChanged` 不觸發 Disconnect(既有 sender 檢查的測試若沒有,補上)。

### M-7 A1 的電量、Android 連線上限、highPerformance 都沒有數字
- 4 條常駐 link × `highPerformance`(A2,7.5–15 ms 連線間隔)會明顯耗電;Android 文件要求用完後退回 balanced。計畫 A2 只說「before the MTU request」,沒說何時退回。
- Android 每個 app 的 GATT client 上限與整機 LE 連線上限(⚠️ 我沒有查 S20 的實際值;常見為 7 上下)加上手機自己的耳機 / 手錶,cap 4 的依據沒寫。
- 節點端:每台 Pi 的 BCM4345C0 同時當 2 條 peripheral + HaLow / Wi-Fi 共存,沒有量測。
- **修法**:小 A1 只有 1 條 link,這些問題大多消失;A2 在登入完成後退回 `balanced`;留一個前後電流 / 電量的量測項。

---

## MINOR

- **m-1** 行號漂移:計畫引 `bluez.go:731-790 / 516-567 / 771-775 / 776-778 / 683 / 268-270`,實際為 `:731-783 / :518-567 / :772-776 / :777-779 / :691 / :269-270`;`server.go:774-804` 實為 `:776-819`。合併前更新。
- **m-2** 「15 s 是手機開 GATT 所需時間(F1: below 5 s)」:F1 自己另一筆是 8.6 s,其中 connect→link 3.8 s;慢手機 + 第一次配對快取未建時可能更長。建議 20–30 s,或以量測到的最大值 ×3,並寫出依據。被誤踢的後果是使用者看到一次連線失敗,所以寧可長。
- **m-3** N1 的 log 沿用 `disconnected N stale link(s)`,與 L80(bluetoothd 重註冊時)分不出來。加一個原因欄位(例如 `reason=no-session`),否則現場 log 無法歸因,harness 也無法區分。這是新的 log 契約,寫進 §4.4。
- **m-4** A1「使用者只在沒有 link 時按動作才看到『連線中』」:節點重開要 1 分鐘以上,這句等於今天的等待原樣回來;寫清楚這時顯示什麼、等多久放棄(沿用 LoginFor 的 60 s 預算 `core.dart:705`?)。
- **m-5** §5 A1 的負向對照「on main, three actions make three logins」是計數,不是使用者感受;加一個行為斷言:第二個動作從點擊到送出請求之間沒有 scan / connect(以 gate trace 斷言)。
- **m-6** A2 / N2 是量測項,沒問題;每項要有「做了沒變快就拿掉」的門檻數字(例如中位數改善 < 0.3 s 就不合併),避免留下沒效果的程式碼。`requestConnectionPriority` 在 MTU 前呼叫時 Android 兩個 GATT 操作要串行,外掛是否排隊 ⚠️ 未驗。
- **m-7** §6 順序把 N1 與 N3 綁在一起、節點 OTA 一次。N1 與 N3 的風險等級差很多,應分開 PR、分開 OTA(見下)。

---

## 範圍建議(明確建議,不是選項清單)

使用者的兩個抱怨:(1) 每次點都要等;(2) 沒人用的節點消失 40 分鐘。

1. **PR 1 = N1,單獨做,先做。** 它修抱怨 (2),只動 provd 一個元件。條件照 M-1 寫成每裝置;廣播恢復不依賴 Disconnect 成功(B-1 修法 2);先做 B-1 的探查。harness 改動(L80 行、新 log 原因)先開 harness PR。
2. **PR 2 = 小 A1:只對「頁面開著的那一台」保留一條 session。** 進節點頁時連線並登入,該頁與它的子頁(設定、Wi-Fi、國別)的讀取與動作都用這條;離開節點頁、app 進背景、或任何其他流程要拿 lease 之前關掉。實作就是把節點頁改用已存在、已審過的 `OpenSession`(update 頁的做法,`update_route.dart:28`),不動 `BleGate` 的一條 link,不動 lease 語意,擁有者就是該頁的 `OpenSession`(一個擁有者、關與重開都是它,`run` 已有死了就重登)。
   - 給使用者的感受與大 A1 幾乎相同:等待只在進頁那一次(而且可以在點進去的轉場動畫時就開始),頁內每次點擊 0 次重連。home 頁的狀態本來就是背景輪詢,使用者不等它。
   - 代價要明講:頁面開著的期間,home 上其他節點的狀態不更新(與今天 update 頁相同),別的手機在這段期間看不到這台(今天也是,只是時間從幾秒變成「人停在頁上的時間」)。加一個頁內無操作上限(例如 2–3 分鐘無點擊就放掉、下次點擊重連),把最壞情況封頂,同時解掉 M-5 / M-7 / 鎖屏 / 被殺的大部分問題。
   - rekey / leave / remove 仍照今天各自 `OpSession.once`(先關頁面 session、做完再開),不需要新規則。
3. **N3 這輪不做。** 它只在大 A1 下才必要;前提未驗(B-2)、要改一整節已審契約與 5 個以上 harness 段(M-4)。把 B-2 的真機探查記成 #329 checklist 的一行;結果是「支援」再談。
4. **A2 併入 PR 2**(一行 + 登入後退回 balanced),有量測數字才留。**N2** 維持「先探查」,在 firmware repo,另計。
5. 「所有已知節點、cap 4、開 app 就連」不建議:它要重寫 gate / lease / prober 三個已審基準,新增至少 12 條生命週期路徑,換到的只是「進節點頁那一次也不用等」。

---

## 每個修法需要的行為負向對照

| 改動 | 測試(行為) | 沒有改動時必須 FAIL |
|---|---|---|
| N1 | fake bus:`Connected=true`、無 GATT 存取 → 寬限期後 Disconnect 被呼叫且廣播重新註冊 | main:廣播保持 withdrawn |
| N1 | fake bus:Disconnect 回錯 / 永不發 `Connected=false` → 廣播仍重新註冊 | 計畫 v1 的寫法:FAIL(這條證明 B-1 修法 2) |
| N1 | 有 sock session 時殭屍仍被清;剛連上 1 s 的裝置不被踢;有 `links` 的裝置不被踢 | 用全域 `Sessions()` / 未過濾 `staleLinks` 的實作 FAIL |
| N1 真機 | 造出「BlueZ 以為連著、對端已走」→ 04 在 N 秒內可被另一個 central 掃到並連上(以 central 端結果判定,不是只看 provd log) | wsl.26:持續暗 |
| 小 A1 | 節點頁內連續三個動作:gate trace 只有 1 次 connect、1 次登入;第 2、3 個動作前沒有 scan | main:3 次 |
| 小 A1 | 節點端殺掉 session(模擬 owner-removed / 重開)→ 下一個動作重登成功或顯示既有句子,不卡住 | — |
| 小 A1 | 離開頁面 / 進背景 / 無操作上限到 → link 關閉、lease 釋放、home 輪詢恢復 | 沒有關閉邏輯時 FAIL |
| A2 | F1 的階段計時前後對照(同一台、同距離、各 ≥10 次,報中位數與最大值) | 沒改善就不合併 |
| N3(若日後做) | 活的第一條 link 存在時,第二個 central **在空中**掃到並連上、登入成功 | main:掃不到 |

---

## 我沒做 / 沒驗的(❌ / ⚠️)

- ❌ 沒有碰任何裝置;F5、F6 的真機狀態都是計畫的陳述,我沒有重看。
- ❌ 沒讀 `scripts/node/prov-p2-central-254.sh`、`scripts/node/ble-central-254.sh`、`docs/design/254-h4-harness.md` 的內文;M-4 的第 3–5 項是 grep 命中,不是逐行確認。
- ⚠️ BCM4345C0 的 `le_states`、legacy / extended advertising、連線中重註冊是否換 RPA:都沒有量測;B-2 是從 kernel legacy 路徑推論。
- ⚠️ Android 的 LE 連線上限、背景計時器行為、`requestConnectionPriority` 與 `requestMtu` 的排隊:一般知識,沒有在 S20 或外掛原始碼驗證。
- ⚠️ `logLimited` 吃掉 F5 的 `connection ble` 的可能性:低,但沒有 log 行數可排除。
