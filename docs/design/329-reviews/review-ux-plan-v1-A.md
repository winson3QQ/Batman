# #329 UX speed plan v1 — 審查 A(獨立對抗式審查)

對象:`docs/design/329-ux-speed-plan.md`(plan v1,123 行,整份)。
方法:只讀原始碼(worktree `C:\src\Batman-b8`、WSL `firmware-2710` 的 kernel 6.6.138 與 BlueZ 設計文件)。沒有碰任何節點、手機,沒有跑 adb / ssh。
基準(不重審):lease / OpSession / OpenSession / LoginFor、provd session 協定、Slots=2。只審 N1、N3、A1、A2、N2。

標記:✅ = 我對原始碼驗過(附 file:line);⚠️ = 由原始碼推論,沒有真機證據;❌ = 沒做。

## 判定:REJECT(整份 v1)

- N1 單獨拿出來,照 M1–M3 修改後可以 APPROVE-WITH-CHANGES。
- N3 與 A1 各有 BLOCKER:N3 照文字做出來,節點在第一支手機連上後實際上仍不在空中廣播,而補上重新註冊又會切掉正在連線的手機;A1 與它宣稱「不變」的 lease / BleGate 基準直接衝突,照現有規則做不出來。
- 使用者的兩個抱怨有更小的修法(見「最小修改」一節)。

---

## BLOCKER

### B1. N3:不 withdraw 不等於還在廣播。連線後控制器自己停廣播,kernel 只在斷線時重開

- 情境:手機甲連上 04。provd 照 N3 不呼叫 `withdraw("connect")`,`advOn` 仍為 true,BlueZ 的 instance 還在。但空中沒有廣播。手機乙掃不到 04,直到下一次 `rpa_timeout` 重新註冊(900 s + 30..120 s,最長約 17 分鐘)。「第二支手機看得到」這個目標沒有達成,而 unit test 全綠。
- 證據:
  - ✅ `linux-6.6.138/net/bluetooth/hci_event.c:5637-5640`:「All controllers implicitly stop advertising in the event of a connection」→ `hci_dev_clear_flag(hdev, HCI_LE_ADV)`。
  - ✅ `hci_event.c:3412-3425`:只有 LE peripheral 連線的 disconnect-complete 才重新開廣播。
  - ✅ `docs/design/254-p2-impl.md:40`(F-P17)已記錄同一件事。
  - ✅ `bluez.go:777-781`:`advOn` 為 true 時 `converge` 只會在 `rpa_timeout` 到期才重新註冊。
  - ⚠️ F6 的探針是「連線中另外註冊一個新的 advert」,證明的是 `is_advertising_allowed`(`hci_sync.c:1007-1044`)放行,不是「原本那個 instance 在連線後還在廣播」。而且那條 link 是半開的,空中也沒看。
  - ⚠️ 若 kernel 對 BCM43455 用 extended advertising,行為可能不同;F4 自己寫了「未檢查」。
- 修法:N3 必須明寫「每次有新連線後重新註冊 advert」,並先解 B2。設計凍結前要有下列真機證據(F6 目前不夠):
  1. 手機甲有一條活的、已登入、有流量的 session;此時第二個 central(02)在空中掃得到 04 的 advert 並連上(btmon 兩端都要有 advertising report / connection complete)。
  2. 兩條 session 同時各做一次 request 都成功(`254-p2-impl.md:105` 寫明 BLE 空中實際只跑過 1 條,兩條並存從未上機驗過)。
  3. 甲斷線後 advert 的狀態;連線中跨過一次 `rpa_timeout` 後甲的 link 還活著。
  4. 在 bcm2711(量產 CM4 的板系)上做,並記下 kernel 用 legacy 還是 extended advertising。

### B2. N3:重新註冊會切掉剛連上、還沒碰 RX/TX 的手機

- 情境:B1 的修法(連線後重新註冊)與 plan 明寫的「`rpa_timeout` re-register keeps running while connected」都走 `register()`。`register()` 第一步是 `staleLinks()`,它把所有 `Connected==true` 但不在 `b.links` 的裝置全部斷線,沒有年齡條件。手機在連上後 1.5–5 s(F1)才第一次寫 RX,期間只在 `devConn`。結果:
  - 手機乙剛連上(`devConn` 有、`links` 沒有)→ 被切。
  - 只讀 STATUS / CTRL 的 central(claim 頁掃描、`scan.dart`)永遠不會進 `links` → 每次重新註冊都被切。
- 證據:
  - ✅ `bluez.go:583-600`:`register(why)` 於 `:590` 呼叫 `b.staleLinks()`。
  - ✅ `bluez.go:516-567`:`staleLinks()` 對每個不在 `b.links` 的 Connected 裝置呼叫 `Device1.Disconnect`,最多 3 輪 × 5 s。
  - ✅ `bluez.go:121-134`:ctrl / status 的 `ReadValue` 不呼叫 `link()`;`:136-195` 只有 WriteValue / AcquireWrite / AcquireNotify 會。
  - ✅ plan 的 F5 寫「`staleLinks()` runs only when the GATT app is re-registered」與原始碼不符:每次 advert 註冊都會跑。這個錯誤前提正是 N3 沒看到這個衝突的原因。
- 修法:`register()` 內的清掃必須與 N1 共用同一個「每裝置、有年齡」的判定(見 M1);app 重新註冊(`converge:742-747`)那一條可以維持全清。負向對照:裝置 A 已有 session,裝置 B `Connected=true` 才 1 s,觸發重新註冊 → B 不得被斷;現行 `staleLinks` 會斷它。

### B3. A1:「每個已知節點一條保留的登入 session(上限 4)」在基準規則下做不出來

- 情境與證據(全部 ✅):
  1. `BleGate` 同時只允許一條 link:`ble_gate.dart:1-4` 檔頭、`:237-247` `connect` 在 `_links.isNotEmpty` 時拒絕。4 條並存需要改 gate。
  2. link 綁 token,任何 lease 取得都會關掉 NodeLink 的 link:`node_link.dart:253-270`(`acquire` → `_dropAll()` → `gate.revoked(mine)`)、`ble_gate.dart:251-266`。所以使用者一按任何動作(12 個 `OpSession.once` 呼叫點:`rekey_send.dart:112,139`、`dev_pages.dart:153,244`、`join_pages.dart:117,721`、`more_pages.dart:258`、`remove_pages.dart:102`、`settings_pages.dart:122,144,291,336`),全部保留 session 立刻被關。
  3. 全 app 只有一個 lease(`lease.dart:135-140`),lease 被持有時 NodeLink 沒有 token(`lease.dart:131`)、prober 不合格(`core.dart:196`)。所以某頁持有 lease 時,其他 3 個節點的 60 s 保活讀不能跑,300 s(`IdleAuthed`)後被節點踢掉。
  4. plan 自相矛盾:§3 說「prober 在保留 session 上讀」「lease 仍然串行」;§4 說「A1 在節點頁 session 開著時持有 session lease,prober 暫停」。兩者不能同時成立。
  5. 一個 `OwnerConsole` 一次只能一個 request(`owner_console.dart:420` 第二個直接 throw)。同一條 session 上 prober 的讀與使用者的動作誰先、誰等,plan 沒寫。lease 不能回答,因為 prober 不持有 lease。
  6. 舊頁走 raw lease、自己開 BLE 連線(`claim.dart:353`、`claim_recovery.dart:99`、`scan.dart:170`、`raw_use.dart`)。若同一節點還有保留 session,兩套程式共用一條 ACL / GATT,frame 會混。
- 這不是「lease 不變」,是改 lease / BleGate / NodeLink 的擁有權模型。基準已審過,要改就要明講並重審那一塊,而不是寫「The lease still serialises them」。
- 修法(建議):A1 縮成「節點頁生命期內用現有的 `OpenSession`」——一個節點、一條 link、頁面持有 lease、prober 暫停,完全符合現有 gate 與 lease 規則,`update_route.dart:28` 已經這樣跑。這就解掉「每按一次等一次重連」。4 節點 session 池、背景重開、60 s 保活都拿掉。若使用者堅持「像一般藍牙裝置一樣一直連著」,那是一份獨立的設計,要寫清:保留 session 的唯一擁有者、交給 `OpSession` / raw 頁的交接契約、每 session 的 request 佇列、gate 多 link 的規則。

---

## MAJOR

### M1. N1:「走現有 `staleLinks` 路徑」會切到合法手機;「在 `b.mu` 下」是錯的

- 情境:半開的甲滿 15 s 觸發清掃;同一時刻手機乙剛連上 1 s(N3 之後這是常態;今天在 withdraw 與實際連線之間的競爭窗也有)。`staleLinks()` 沒有年齡、不分裝置,乙一起被斷。另一例:`claim.dart:353` 的掃描對目標未認領節點保留 `conn`,只讀 STATUS,等使用者確認才開 claim session——超過 15 s 沒碰 RX/TX 就會被 N1 切,這是合法手機在連線途中被切。
- 證據:✅ `bluez.go:516-567`(無年齡);✅ `bluez.go:54` `devConn map[dbus.ObjectPath]bool` 沒有時間戳;✅ `staleLinks` 只短暫拿 `b.mu`,D-Bus 呼叫不在鎖內——plan §4「runs in converge under b.mu, as staleLinks does」不符事實。若真的持鎖 5–15 s 等斷線,會卡住活著那支手機的 GATT 回呼(`link()`、`Close()` 都要 `b.mu`)。
- 修法:
  - `devConn` 記首次看到的時間;N1 只對「該裝置自己」滿 15 s、不在 `links` 的那一個呼叫 `Device1.Disconnect`,判定按裝置,不用全域 `Sessions()`(sock session 不該讓 BLE 半開 link 免清)。
  - D-Bus 呼叫不持 `b.mu`,非同步,不阻塞 `converge`。
  - claim 掃描頁:要嘛 15 s 夠(寫出量到的數字),要嘛那一頁在使用者確認前不保留連線。現在兩者都沒寫。
  - 負向對照:裝置 B 連上 1 s,裝置 A 到期 → 只有 A 被斷;用未加年齡的 `staleLinks` 這個測試 FAIL。

### M2. N1 的療效沒有證據:F5 是「控制器沒回報斷線」,`Device1.Disconnect` 能不能清掉它沒人看過

- ✅ 條件面相符:F5 的 log 有 `adv withdrawn reason=connect` 而沒有 `connection ble`,表示 withdraw 來自 `converge:772-776` 的 `devConn` 分支,`link()` 沒被呼叫 → 「在 `devConn`、不在 `links`、沒有 session」會抓到 F5。這一點不是 BLOCKER。(註:`connection ble` 走 `logLimited` 每分鐘 10 行,`server.go:137-152,816`;F5 當時無人使用,缺行可信,但 plan 該寫明。)
- ⚠️ 療效面:kernel `hci_event.c:2674-2712`(`hci_cs_disconnect`,錯誤狀態也會清 conn 並重開廣播)從原始碼看支持「下 Disconnect 就清得掉」,前提是控制器有回應。這是推論,不是 04 上的輸出。
- plan 的真機測試(02 開了 link 再丟下)是一條活的 link,不是 F5 的殭屍狀態;而且 F5 只看過一次、沒有重現。plan 的失敗路徑「Disconnect 失敗就下一輪再試,廣播繼續關著,as today」就是 F5 本身。
- 修法:
  - 動手前先重現 F5 類狀態並收證據(例如手機在連上後、第一次 GATT 存取前強制關藍牙 / 飛航 / 殺 app,看 04 的 `Connected` 是否殘留);重現不出來要照規則明講並問使用者。
  - 若 04 目前還卡在那個狀態,經使用者同意後對那個裝置下一次 `Device1.Disconnect` 並記錄結果,是最直接的證據。
  - 加上界:連續 N 次 Disconnect 無效 → 升級處置(例如 `Adapter1.RemoveDevice`,或經 health 路徑重啟 bluetoothd)並記一行 log。否則 N1 不能宣稱「修好 F5」,只能說「多一個可能有效的嘗試」。

### M3. N3 的計數規則沒定義

- 「BLE links + sessions reach Slots」:一支手機同時是 `devConn` 一筆、`links` 一筆、`Sessions()` 一個,照字面加起來一支手機就是 3 ≥ 2。現行 `converge:733` 的 `nlinks = len(b.links)+len(b.devConn)` 也會重複算同一裝置。sock session 佔不佔 BLE 的額度也沒說。
- 修法:定義為「`links` 與 `devConn` 取聯集後的不同裝置數 + 非 BLE 的 session 數 ≥ Slots」,寫進契約並各寫一個 unit 案例(一支手機三處都有 → 仍廣播)。

### M4. Slots 被閒置的保留 session 佔滿;「第三支手機看到 busy」不成立

- ✅ `server.go:35` Slots = 2 是 BLE + sock 合計;`:774-819` 滿了踢最舊的 evictable,否則拒絕;`session.go:154-168` 已登入的 owner / member session 永不 evictable。
- 情境 1:擁有者手機 + 成員手機都開著 app → 該節點兩槽長期全滿。節點本機 sock 工具(`provclient node info`、harness 幾乎每個測項)得到 `connection refused (2 slots in use)`。今天一次操作只佔幾秒。
- 情境 2:同一擁有者兩支手機 + 成員 = 3 支。第三支在 advert 被收掉後根本掃不到節點,60 s 後是 notFound,不是 plan 寫的「existing busy sentence」。
- 情境 3:擁有者手機只為了首頁狀態,就長期佔住最多 4 個成員節點各一槽。
- 修法:採 B3 的縮小版(只有開著的節點頁持有 session)這三個情境大多消失;否則要寫明 sock 的保留額度與第三支手機實際看到的文字,並各有測試。

### M5. harness 依賴「連線 ⇒ 不廣播」與「無 session 的 link 可久留」,必須另開 harness PR 先進 main

N3 會讓下列判定翻紅(✅ 逐行讀過):

- `scripts/dv/prov-provd-254.sh:85, :90`:用 `adv withdrawn reason=connect` 的行數當「02 的讀到了 04」的證明。
- `scripts/dv/prov-provd-254.sh:99-105`:`reason=connect`、`0 advertising instances on 04 while connected`(:103)、`adv registered reason=disconnect`(:104-105)。
- `scripts/dv/prov-provd-254.sh:229, :241, :255`:rpa 測項要有一筆 `reason=disconnect` 註冊,並假設 rpa_timeout 間隔 930–1020 s;檔頭註解 :10-15、:35。
- `scripts/dv/prov-netjoin-254.sh:62-64`:STATUS 讀前後數 `adv withdrawn reason=connect`。
- `scripts/dv/prov-http-254.sh:59, :126`:advertising instance 數的前置條件。

N1 會影響的:

- `scripts/node/prov-p2-central-254.sh` 的 `hold`(:16, :155):維持一條沒有 session 的 link。`prov-provd-254.sh` respawn 段的 L80 對照「provd 沒動時 02 的 link 撐 15 s」(`c02 watch "$a" 15` → 期望 `STILL`)正好撞上 N1 的 15 s → 翻紅或變 flaky。同段數 `disconnected [0-9]* stale link` 當作「新 provd 清掉的」證明,N1 也印同一行 → 判定失去鑑別力。
- `prov-provd-254.sh:186-202`(471 `Device1.Disconnect` 測項)hold 後查 `bluetoothctl devices Connected`,時間夠短應該沒事,但要確認。
- `scripts/dv/data/p3-units.tsv:11`(OW3)。
- log 契約(`254-p2-impl.md` 的 `adv registered reason=…` / `adv withdrawn reason=…` 清單)要更新;N1 建議用不同的 reason 或不同的 log 行,讓 L80 與 N1 分得開。

plan §6 的順序沒有這一步。規則是測項只有一套、harness 改動先獨立進 main,新判定要附「舊版 FAIL + 新版 PASS」。

### M6. 360 s 的 request 遇到 app 進背景

- 情境:使用者送出設定(節點端最長等 360 s;`server.go:23` HelperWait 330 s),30 s 時切去看訊息。plan:「背景 30 s 後關 session」→ 進行中的 request 在 60 s 被切,結果不明(節點端可能已套用)。今天的 `OpSession.once` 會撐到 lease `goneMax` 420 s(`lease.dart`)。
- 證據:✅ `session.go:279-298, :611-615`(inflight 不過期,節點不會自己斷);✅ `app_link.dart:228-237` → `node_link.dart:228-237` lifecycle;plan §3 / §4 都沒有 inflight 的例外。
- 修法:有 inflight request 的 session 不受 30 s 規則,沿用現有 `goneMax`;寫進契約並加 flow test(負向對照:沒有例外時 request 被切、結果不明)。同時補:螢幕鎖 / Doze 算不算背景。

### M7. A1 沒寫的生命週期路徑(若仍保留 A1 的任何「保留 session」形式)

- 節點 RPA 每 900–1020 s 換一次(`bluez.go:777-779`):「掉線後安靜重開」需要重新掃描;gate 的掃描額度是 30 s 4 次(`ble_gate.dart:162-163`),範圍外的節點會變成持續掃描(電量)。重試節奏沒寫。
- 上限 4「是哪 4 個」:選擇規則、換出規則沒寫。Android 的 LE 連線數與手機上其他裝置(耳機、手錶)共用,沒有量測。
- 撤銷:✅ `server.go:638-679` `reconcile` 在 owners / psks 集合變動時殺 session;`:847-860` `killOthers` 在 claim / replay 後殺其他 session。長壽 session 讓這條路從「偶爾有用」變成唯一的撤銷點(以前下一次登入就會被擋)。要寫明 `reconcile` 多久跑一次、被移除的成員手上的保留 session 最多還能用多久,並加真機負向測試:移除成員後,他原本的保留 session 下一個 request 必須失敗。
- rekey:`rekey_send.dart:112, :139` 是兩次全新登入,中間有使用者確認;rekey 後成員的 session 被節點殺掉,保留 session 必須用新憑證重登。plan 只有一句「lease owner needs a fresh login (rekey)」。join / claim / remove 也要各一句。
- 未認領節點:沒有保留 session(claim 走 raw)——要明寫,並寫 claim 成功後何時開始保留。
- 缺的列:provd 重啟時有活的保留 session(L80 會切合法手機一次,`254-p2-impl.md:294`);bluetoothd 重啟;同一手機兩個套件(dev / dev2 / dev3)各自保留 session;app 升級 / 回退;節點在套用途中重開(保留 session 斷,回覆不明,和今天一樣但要寫)。

---

## MINOR

1. F5 的 bullet「`staleLinks()` runs only when the GATT app is re-registered」不符原始碼(`bluez.go:590`),請更正(B2 的根源)。
2. plan 引的行號有偏差:`bluez.go:683` 的 sender check 實際在 `:691`;`:771-775` / `:776-778` 實際是 `:772-776` / `:777-779`。
3. `staleLinks` 最多阻塞 `converge` 15 s(3 輪 × 5 s);N1 每 5 s 一輪時對一條清不掉的 link 會持續佔住迴圈並洗 log——加退避與 log 限速。
4. A2:寫出量測準則(F1 的同一份分段計時,前後各 N 次、看中位數)與退回條件;`highPerformance` 在長連線下耗電,若 session 會久留,MTU / 登入完成後應降回 balanced。
5. N2:`main.conf` 在 firmware repo,擁有者與交付路徑(哪個 PR、兩個板系)沒寫;保持最後做、探針先行是對的。
6. N3 隱私:連線中仍廣播讓節點隨時可被掃到。`254-p2-impl.md:95` 已寫明「連線時收廣播」不是隱私防線,所以不算變差,但請在 Security 節寫一句,並確認連線中換 RPA 不影響已建立的 link(列入 B1 的真機證據)。
7. §6 順序建議改為:重現 F5 → harness PR(M5)→ N1 單獨一個 PR(穩定性,使用者最痛)→ A1 縮小版 + A2(app,獨立於節點 OTA)→ N3 等真機證據後另議 → N2。N1 與 N3 綁在一起會讓 N1 被 N3 的未知數拖住。

---

## 安全(逐項)

- 資產:節點的可用性(BLE 管理通道)、節點控制權(已登入 session)。沒有新的秘密、沒有新的檔案 / 埠 / 設定鍵。
- 遠端 BLE 對手:
  - N1 不給新能力;沒有 session 的 link 從「永久讓節點變暗」降到 15 s 一次。對手每 15 s 重連仍可壓住單槽,與今天相同。✅
  - N3:對手佔兩條 link 才能讓節點變暗;但對手開了 session(未登入)就不被 N1 清,要靠 `HandshakeMax` 10 s / `IdleAnon` 30 s(`server.go:29-31`)。未登入 session 是 evictable(`session.go:154-168`),所以合法手機仍擠得進來。⚠️ 這條推論要一個測試:兩條匿名 link 佔滿時,合法擁有者能登入。
  - A1 之後合法 session 永不 evictable 且長壽 → 兩支合法手機就能把第三方(含 sock)擋在外面(M4)。這是我們自己造成的可用性問題,不是對手造成的。
- 被偷 / 沒鎖的手機:權限與今天相同(前景才有 session)。差別是不再需要重新登入那 4 秒,沒有實質變化。背景 30 s 關閉是對的方向。
- 被撤銷的成員 / 舊擁有者:見 M7,唯一撤銷點變成 `reconcile`,需要時限與負向測試。
- 節點上的非特權本機程序:不能偽造 `Connected`(✅ sender check `bluez.go:691`);N1 沒有新的輸入。但它可以用 sock 佔槽——今天也可以,A1 讓剩餘槽更少(M4)。
- 權限:N1 用 provd 既有的 `Device1.Disconnect` 權限(D-Bus policy 已放行,harness 的 471 測項在驗),沒有新增。
- 失敗模式:N1 失敗 = 節點維持不廣播(對可用性是 fail-closed,對控制權無影響)。可接受,但要有 M2 的上界與升級處置,否則 F5 原樣重現。
- 我們自己的錯:B2 / M1(清掃切到合法手機)是這份設計裡最可能自己打到自己的地方。

---

## 最小修改評估

使用者的抱怨有兩個:節點消失 40 分鐘;每按一次都要等重連。

- 節點消失 → N1(照 M1 / M2 修)。不需要 N3。
- 每次重連 → 節點頁用現有 `OpenSession`(B3 的修法)+ A2。不需要 session 池,也不需要 N3。
- 為了「像一般藍牙裝置」而加的:N3、4 節點保留 session、60 s 保活、背景重開、背景 30 s 關閉。這些各自帶來新的洞(B1、B2、B3、M4、M6、M7),而且要改已審過的基準。建議從這份 plan 拿掉;若使用者仍要這個方向,另寫一份設計並先取得 B1 的真機證據。

## 測試與負向對照

| 項目 | plan 的測試 | 評語 |
|---|---|---|
| N1 unit | 假 bus,15 s 後斷線並重新註冊;main 上 FAIL | 可以,但要加「另一個裝置剛連上不被切」(M1) |
| N1 真機 | 02 開 link 後丟下 | 不是 F5 的狀態(M2);要一個殭屍 link 的重現 |
| N3 unit | 一條 link → advert 留著 | 不是行為測試:假 bus 上「沒呼叫 Unregister」會過,而空中沒有廣播(B1) |
| N3 真機 | S20 連著,02 連得上 | 要寫明 S20 的 session 是活的、有流量;兩邊同時 request;btmon 佐證 |
| A1 flow | main 上三個動作 = 三次登入 | 負向對照成立;缺 prober 讀與使用者動作併發、360 s + 背景、撤銷、lease 取得時保留 session 的去向 |
| A2 / N2 | 分段計時前後比 | 缺次數與判準(MINOR 4) |
| 缺的 | — | 匿名 link 佔滿時合法擁有者能登入;兩槽被保留 session 佔滿時 sock 的行為;provd 重啟時的保留 session |

## 我沒做的

- ❌ 沒有任何真機驗證(受命唯讀):B1 的「連線後空中沒有廣播」、M2 的「Disconnect 清得掉殭屍 link」都是原始碼推論。
- ❌ 沒有讀 BlueZ 5.72 的 `advertising.c` 來確認 F4;沒有確認 kernel 在這塊板子上用 legacy 還是 extended advertising。
- ❌ `prober.dart` 只讀了一部分;`flutter_reactive_ble` 對同一 device id 多次 `connectToDevice` 的行為沒查。
