# H4 設計 v1 審查 — 審查者 B

**審查對象**:`docs/design/254-h4-harness.md` v1(`harness/254-h4` @ a31489b)
**上層**:P3 `254-p3-impl.md` v7.1(`feat/254-p3` @ dfedd03)§2/§3/§5/§6/§8/附錄 D;先例 `254-h23-harness.md` v14;main 2ecf1cb。
**方法**:整份讀完(不只最新段落)。先從實際使用情境找缺的生命週期路徑與資源,再逐一查證文中的假設:讀原始碼(`file:line`),並在 04 / 02 上跑唯讀指令(`cat`、`ls`、`uci show`(過濾掉 `.key=`)、`bridge`、`iw`、`nft list`、`ps`、`ip`)。沒有改任何節點狀態,沒有連 BLE,沒有改 repo 檔案。
**結論**:**REJECT**,共 2 BLOCKER / 12 MAJOR / 11 MINOR。

---

## 0. 我自己取得的證據(原始輸出節錄)

**E1:改狀態的動詞在 trial 一律 `EBusy`**(`feed/batman-prov/src/node/node.go:200-207`)
```
var stateChanging = map[string]bool{"claim.verify": true, "claim.replay": true, "net.apply": true, "network.leave": true,
	"owner.add": true, "owner.remove": true, "settings.set": true, "root_password.reset": true, "ssh_keys.set": true}
...
	if stateChanging[verb] && n.Sys.IsTrial() {
		return nil, fail(EBusy, "trial slot (updating)")
```
h23 的規則也是這樣:「trial 內不能改狀態(F9)… → trial 內只能 restart 類」(`254-h23-harness.md:255`)。

**E2:prov_test 版的 provd 只存在於 `-wbox` image**(`cmd/batman-provd/testenv_provtest.go:1-5`)
```
//go:build prov_test
// prov_test only (a -wbox image, h23 §4.8.3): the switches batman-provd-test.init read as root from
// /tmp/run/batman-prov-test/provd.env ...
```
release 的 init(`feed/batman-prov/files/batman-provd.init`)沒有讀 env 檔的段落,只掛 `"$PROG" /etc/batman-build /tmp/run/dbus /tmp/run/batman-prov`;`respawn 3600 5 0`。

**E3:wbox 永遠不會被 commit**:h23 §19(`254-h23-harness.md:772-776`)「wbox image 永不自動 commit」;H4 的 F-H9 也這樣寫。

**E4:chain1 的新卡試用是先 release、讓 B 槽 commit 之後才認領**(`scripts/dv/chain1-254.sh:10`、`:296-297`):「`8 claim on B` … `release -> B committed`」。
dead-man 是**固定的** `sleep 1500`,從每次 B 開機起算(`chain1-254.sh:291`):
```
echo '( ping -c 5 $HOSTIP; sleep 1500; sh $BASE/ch1-deadman.sh ) ... # ch1-deadman'
```

**E5:prov lease 的 deadman 契約**(`scripts/node/prov-lease-254.sh:14-18`):「It never touches a slot or p5」。

**E6:04 的 bridge / 防火牆(F-H1 的旁證)**
```
2: eth0 ... master br-ahwlan state forwarding
4: phy1-ap0 ... master br-ahwlan state forwarding
6: bat0 ... master br-ahwlan state forwarding
wireless.default_radio0.*:沒有 isolate 選項(hostapd 預設 ap_isolate=0)
/proc/sys/net/bridge/bridge-nf-call-iptables=1 ; br_netfilter 已載入
chain forward_ahwlan { ... jump accept_to_ahwlan }
chain accept_to_ahwlan { oifname "br-ahwlan" counter packets 146755 ... accept }
iptables -P FORWARD ACCEPT
nft list tables: ip filter / ip nat / ip6 filter / ip6 nat / inet fw4
```

**E7:02 的 eth0 沒有接線;02 只經 mesh 到 04**
```
02: eth0  DOWN  d8:3a:dd:f8:45:d7 <NO-CARRIER,...>   (carrier=0)
04: bridge fdb: d8:3a:dd:f8:45:d7 dev bat0 master br-ahwlan
04: bridge fdb: 10:7c:61:d4:b9:72 dev eth0 master br-ahwlan   (= 桌機 10.41.240.10)
```
chain1 的註解也這樣寫(`chain1-254.sh:5`):「The host reaches 02 only through 04's mesh」。

**E8:provd 只要有任何 BLE link 或 session 就撤廣播**(`cmd/batman-provd/bluez.go:771-774`)
```
	case nlinks > 0 || b.srv.Sessions() > 0:
		if advOn { b.withdraw("connect") }
```
另有 `rpa_timeout` 時的 re-register(`:775-777`,換 RPA)。GATT:`rx` = `write-without-response`(AcquireWrite)、`tx` = `notify`(AcquireNotify)、`ctrl` / `status` = `read`(`:233-236`);inbound `MaxFrame = 512`、`OutFrame = 244`(`provd/frame.go:12-17`)。

**E9:既有的 Proxy 傳輸在 pipe 上用 `select()`**(`tests/tools/peer/transport_sock.py:75`)
```
            r, _, _ = select.select([self.p.stdout], [], [], timeout)
```
Windows 的 `select` 只收 socket,不收 pipe。

**E10:peer 的 Python 依賴比 §2.1 / §9-1 列的多**:`peer_core.py:10`、`owner.py:11` 都 `import verify`(`tests/vectors/219-protocol/verify.py`),而 `verify.py:23-36` 會 import `pycddl`、`dissononce`、`cryptography.x509`。

**E11:新卡試用的 overlay 裡只有 overlay 才有的東西**(firstboot 會清掉)
```
/overlay/upper/etc/init.d: batdata-mount  batman-payload-opentakserver
/overlay/upper/etc/rc.d:   S11batdata-mount S80tailscale S99dockerd S99batman-payload-opentakserver ...
/rom/etc/init.d 沒有 batdata-mount
```

**E12:分支上只有設計文件**。`git show --stat a31489b` 只有 `docs/design/254-h4-harness.md`;§2.5 說的逐列對表 `tests/tools/peer/p3-units.tsv` 不存在。

**E13**:現有的 known-failures 先例是「看結構」:`no batman-provd on 04 (...): a pre-P2 image`(`scripts/validation-known-failures.txt:28-35`)。

---

## BLOCKER

### B1. image / 交付方式的規劃與三道產品閘門衝突,§2.5 大半的臂照寫是跑不出來的

**情境**
- §2.5 把 `prov-settings-254` 與 `prov-country-join-254` 放在「新卡試用(wbox `test` + `uci-argv`)」裡,要做認領 → key 20 → key 2 → join。
- upload、settings、update 的接縫負對照都標「(wbox)」。
- `prov-upload-254` 標「release;http(手機)」;`prov-update-254` 要「T 簽的 image 經 app 路徑 → trial → commit → 5」。

**證據與推論**
1. **trial 閘門(E1)**:wbox 一定是 held trial(h23 §4.2、E3),所以在 wbox 上 `claim.verify`、`settings.set`、`owner.*`、`net.apply` 都回 `EBusy "trial slot"`。P3 的新動詞也一樣:P3 §5.1「所有 state-changing:試用中 → P1b 既有對應」,`update.check` 回 reason 1。結果是:wbox 新卡試用連認領都做不了;upload / settings / update 的 Go 接縫負對照,在 wbox 上連要測的路徑都到不了。
2. **wbox 永不 commit(E3)**:chain1 的新卡試用之所以能認領,是因為它先 `release` 讓 B 槽 commit(E4)。wbox 新卡試用沒辦法走這一步。下列斷言都需要「commit 真的發生」,在 wbox 上一律做不出來:
   - autocommit 的「正常 provd → commit」;
   - D-9(試用轉 committed 時存一次);
   - prov-update 的「commit → phase 5」。
3. **T 只被 prov_test 信任(P3 §3.7.1)**:release image 只認 R / K 的簽章,而 YubiKey 還沒測(H4 §1.2 標 NEEDS-PERSON)。所以在 release 上 `update.check` 一定不過、不會有 pending,`bulk.open` 一律回 15,上傳窗開不起來。因此 `prov-upload-254`「release;http」整個單位跑不了,`prov-routes` / `prov-owner` 的 HTTP 半邊也只能靠「停 bluetoothd 5 分鐘進備援」才開得了 HTTP,而 H4 沒寫這條路。P3 §8 的「新卡 key 20 後 `bulk.open ≠ 16`」在沒有 pending 時會拿到 15,這條斷言就成了空斷言(見 M2)。
4. **prov_test 版 provd 只在 wbox(E2)**:provd 端的 Go 接縫(`upload-noowner`、`upload-nosrcip`、`ro-on-ctl`、`healthok-2field`)與 sock 傳輸,要在 committed 槽上跑,必須同時換掉 provd 二進位與 test init。h23 只有 helper 有 `push-helper` / `upper-helper` / `bind`,provd 沒有。

**修法**
- 照 h23 §4.5 / `:255` 的分類,替每一臂標上 **[bind / restart / upper / wbox-B]**,並加三欄:「需要改狀態?」「需要 commit?」「需要 pending(T)?」。
- T 簽的臂:用 `upper-helper` / `bind` 把 prov_test helper(信任 T)放到 **committed 的 release 槽**。
- provd 的 Go 接縫:定義「在 committed 槽 bind prov_test provd 與 `batman-provd-test.init`」的步驟,並照 h23 #13 斷言「provd 本次 pid 的 environ」。
- 新卡試用只用 release V(與 chain1 相同,先 release → commit),要接縫時在 commit 之後 bind。
- wbox held trial 只拿來做「不改狀態」的判定類負對照(autocommit verdict、HELD 對 revert)。
- D-9 的負對照要另找做法(例如 commit 轉換那一刻由 bind 的 helper 提供接縫),或明寫「只在 Go 單元測、節點上只有正向」,並請使用者決定。

### B2. bench 的身分 / 基準狀態(S0)沒有定義,也沒有擁有者;擁有者金鑰每個 run 結束就刪

**情境**
- D20 重燒之後,02 / 04 是新卡,要由 harness 認領(app 還不存在)、建網、配對 AP。
- §2.1 寫「每個 run 用一個新目錄,run 結束時刪除」擁有者金鑰、PSK 輸入、tag key。
- 但認領紀錄留在 p5,F-H10 說回到 Unclaimed 的唯一路是 p5 mkfs。

所以第一個 run 結束後,04 被一把已經刪掉的金鑰擁有,下一個 run 的 release 臂(擁有者、候選、成員)全部做不了。

**同一缺口的其他面**
- 成員角色要 `net_config` 與 psk_member,也就是 bench 網路的 mesh key。這是 02 / 04 現役 mesh 的 key,真的秘密。
- key 20 要「改回原值」,但原 AP 密碼由誰設、存在哪裡,文件沒寫。`settings.get` 不回密碼;`bulk.open` 要先有 pending,而 pending 在 release 上做不出來(B1)。
- `owner/add` 重送會輪替 tag key,`owner/remove` 會輪替 `adv_owner_key`,這兩個都會改節點狀態。如果 run 在「節點已經改了、主機的 state 還沒寫」之間死掉,harness 就被鎖在外面,沒有寫入順序 / 先寫日誌的規則。
- 「04 / 02 在每個單位開始時應該是什麼狀態」,§2.5 只寫了「h23 既有」。h23 的 `pr_begin` 會快照 p5 並在 `pr_end` 還原,但 H4 沒說基準是 unclaimed、claimed 還是 member,也沒說基準由誰的金鑰擁有。
- §3 擁有權、§4 契約、§5 生命週期(首次 / D20 之後)、§7 秘密(mesh key、擁有者私鑰放在哪、保留多久、要不要備份)都缺這一塊。

**修法**
1. 定義 S0。例如:04 由持久的 harness 擁有者 H0 認領,與 02 組成 bench 網路 N0,AP = 配對值 C0。
2. 持久的金鑰庫:位置、ACL、備份、輪替與重建程序;H0 遺失時的出路是新卡試用或重燒,先列給使用者。
3. 每個單位走 h23 的「snap p5 → 動作 → 還原到 S0」,並斷言結束時是 S0。會改主機端秘密的動作先寫意圖再寫節點,中斷可以復原。
4. 把「D20 之後的 bench provisioning」做成一個 harness 單位(含負對照:S0 不成立 → 所有單位 INVALID)。
5. N0 的 mesh key 與 C0 的處理放進 §7。

---

## MAJOR

### M1. 接縫契約(§2.4)漏了「行程裡的狀態」、中途切換,以及整類「注入故障」的接縫

**情境與證據**
1. **刪檔不等於解除**。Go 接縫只在啟動時讀(§2.4「讀完不刪、持續整個行程」),§3 寫「EXIT trap 刪除」,P9 也只檢查檔案殘留。檔刪了,helper / provd 仍然 armed,直到下次重啟。下一個單位(或 daily-validation)就會在一道防線被關掉的 provd 上判 PASS。
   修法:還原一定要「刪檔 + 重啟該 daemon + 斷言本次 pid 的 log 或 environ 沒有 `fault … armed`」;P9 也檢查執行中行程的狀態,不只看檔案(h23 #13 的 `/proc/<pid>/environ` 先例)。
2. **中途切換要重啟,重啟的副作用沒列**。helper 重啟會重跑開機邏輯(P3 F42)、清 `diag/`、刪上傳檔、關上傳窗;provd 重啟會切斷 BLE / HTTP session,並撤廣播再重新廣播。每換一個 upload 接縫就要重開窗、重傳 126 MB。這些都沒有寫進單位流程與成本。
3. **arm 了要先證明**。單位判定前必須斷言本次 pid 有 `fault <name>: armed`,否則屬於「沒生效卻 PASS」。§2.4 只說了會記這行,沒說單位要檢查。
4. **不認得的名字 → 拒絕啟動 → crash loop**。provd 是 `respawn 3600 5 0`(E2)。如果這發生在 committed 的 04 上,helper / provd 會在 crash loop 中撤廣播。harness 端要先驗證名字,節點端的拒絕只當最後一道防線,並寫出還原步驟。
5. **只有「關防線」的接縫,沒有「造故障」的接縫**。P3 §8 的正向臂需要先讓故障發生,H4 沒有定義:
   - 「新卡配對注入失敗 / 已配對節點注入失敗」:要讓 setkey 套用或讀回失敗的注入點(`setkey-readback-skip` 是負對照,不是注入);
   - D-6「還原也驗證失敗」;
   - 「在 commit 與讀回之間殺 helper」:需要一個能確定停在那一刻的暫停點,否則是賽跑;
   - prov-update 的「prepare 中斷電 / arm 前斷電 / arm 後重開前」:killpoint 的名字是封閉清單,`seam_provtest.go` 的 `names` 目前只有 txn / claim,P3 要新增哪些名字,H4 要寫進契約;
   - 「目標槽 kernel 壞掉」的注入方法與還原;
   - D-14「write 被 TERM」;
   - autocommit 的「試用 image 的 provd 壞掉」「helper 不在」兩個 trial image,§2.4 的 wbox 表裡沒有。

### M2. `--pre-p3-full` 的鑑別標準太弱;有斷言在 wsl.22 上是空著通過的

**情境**
- §2.6:「每個單位都要至少有一條 FAIL 才算有鑑別力」。一個 50 條斷言的單位,只要一條 FAIL 就合格,其他 49 條有沒有鑑別力都不知道。
- 在 wsl.22 上,下列斷言會空著 PASS:
  - prov-http 的「平常不聽」「mesh 連不上」「lo 被丟」「VLAN 被丟」「刪表 ≤ 8 s 不聽」:wsl.22 根本沒有在聽;
  - prov-status-diag 的「poll 無 ERate」「cfgsave-lock.busy 不出現」:動詞直接回 `E_UNSUPPORTED`,負載根本沒進 helper;
  - prov-status-diag 的「bundle 不含秘密」:沒有 bundle 可以檢查;
  - prov-upload 的「窗外的上傳檔一個 poll 週期內被刪」:根本沒有檔;
  - P3 §8 的「`bulk.open ≠ 16`」:沒有 pending 時回 15 一樣成立。
- 文中說這些改由接縫證明,但接縫要到 P3 實作才存在。H4 PR 附的負對照,其實沒有覆蓋這些安全斷言。

**修法**
- 改成**逐條斷言**:每條要嘛在 wsl.22 上 FAIL,要嘛標出接縫負對照,並寫明「這條的負對照在 P3 PR 才附上」(列為 P3 PR 的閘門)。
- 每條「連不上 / 不存在」類的斷言都要附前提證據,缺了判 INVALID / FAIL(全域規則:沒東西可檢查就要 FAIL):
  - 同一時段 8095 確實在聽(正向連得上,或 `ss -ltn`);
  - 逾時(drop)與 RST(沒在聽)要分開;
  - 被丟的封包要有 nft 計數器或 trace 增加的證據;
  - bundle 非空且解得開;
  - 上傳檔先證明存在。
- flip 測試只能改一個變數:「release 上的正向」對「wbox 上加接縫的負向」同時改了 image 與接縫兩件事。每組都要「同一個 image、同一種交付方式,只差接縫」。

### M3. 用行為判斷 pre-P3,會讓 P3 的回歸被 known-failures 吞掉

**情境**:§2.6 用「`settings/get` 回 `E_UNSUPPORTED`」判定 pre-P3,印 `FAIL <unit>: pre-P3 image`,並列進 known-failures。如果某個 P3 rc 的路由壞了(`p3Types` 沒清空,或 `settings/get` 沒接上),它的輸出跟 pre-P3 一樣,會被 known-failures 判成 KNOWN,直到條目過期都沒人發現。
**證據**:pre-P2 的先例是看結構,「`no batman-provd on 04`」(E13),不是看產品的回應。
**修法**:用 build 的特徵判斷,例如 `/etc/batman-build` 的版本早於第一個 P3 版本,或 image 裡沒有 `ruleset-post/batman-http.nft`。在 P3 build 上回 `E_UNSUPPORTED` 一律是一般的 FAIL。

### M4. 手機路徑:有幾項假設是錯的,有幾項沒驗證

1. **MAC 是每個 SSID 各一個**。§2.2 自己也這樣寫,但 key 20 臂用 preflight 的第 2、3 項(固定的 MAC 出現在新 AP 上)證明「新帳密可連」。手機連 `batman-h4-alt` 時用的是另一個隨機 MAC,這一臂會判錯。
   修法:`discover` 兩個網路都記,或在手機上把這兩個網路設成用裝置 MAC。
2. **Android 的路由**。Wi-Fi 沒有網際網路、行動數據又開著時,沒有綁網路的 socket 會走預設網路(行動數據)。P3 §3.11-3 自己就要求 app 綁 Wi-Fi(`bindProcessToNetwork`),但 Termux 的 Python relay 做不到。⚠️ 未實測。preflight 的四項裡沒有「relay → node-ip:port 的 TCP 連線」。
   修法:preflight 加第 5 項(relay 實際 connect node-ip:port);E-H8 在行動數據開、關兩種狀態各測一次;設定步驟寫明關行動數據,或選「保持連線」。
3. **網路選擇**。04 的 AP 換帳密、或還原之後,Android 可能自動改連已存、而且有網際網路的家用 Wi-Fi(桌機的上網就是走家用 Wi-Fi,F-H2,表示它就在附近),手機就離開 04 了,之後所有手機臂都 INVALID;還原後也不一定回到原網路。⚠️ E-H10 要把「家用 Wi-Fi 在範圍內」與「還原後回到原網路」都納入。修法:跑測試時停用其他已存網路的自動連線。
4. **手機 IP**。§2.2 把手機 IP 存在 `phone.conf`,但 IP 是 DHCP 給的(04 有 `dhcp.ahwlan`,而 L2 跨整個 mesh),會變。修法:每個 run 從 04 的 ARP / fdb 依 MAC 找。
5. **Samsung 的耗電管理**會殺掉 Termux(睡眠應用程式),手機重開後 sshd 也不會自己起來。人不在現場時這兩件都救不回來。設定步驟要加 `termux-wake-lock`、設成永不睡眠、Termux:Boot。
6. **ssh 主機金鑰沒有釘住**。同一台 AP 上知道 AP 密碼的人,可以搶到手機的 IP 冒充 relay。Noise 保護內容,但 TCP 層的斷言(「連得上 8095」「連不上」)可以被偽造。要用專屬的 known_hosts 加 `StrictHostKeyChecking=yes`。
7. **Q1「手機上不放任何秘密」不成立**。手機存著 04 現役 AP 的密碼,和 alt 的測試值。

### M5. `peer.py` 在 Windows 上跑的前提不成立(Q2)

1. **既有的 `transport_sock.Proxy` 在 Windows 上跑不起來**。它在 pipe 上用 `select()`(E9),Windows 不支援。同樣的寫法套到 HTTP relay 的子程序也一樣。要改成用執行緒讀取,而 Windows 的路徑在 CI 上沒有測試。
2. **依賴清單不完整**(E10):少了 `pycddl`、`dissononce`(以及它們的依賴)。§9-1 請使用者同意的清單是錯的。⚠️ `pycddl`(Rust 擴充)有沒有 Windows / py3.13 的 wheel 未確認,沒有的話要 Rust 工具鏈。
3. **權限位元與 ACL**。`owner.py:75,84` 的 `os.open(..., 0o600)` 在 Windows 上沒有作用。§2.1 說 `%LOCALAPPDATA%` 的 ACL「只有使用者本人」,沒有證據:預設 SYSTEM 與 Administrators 也有完整權限,要附 `icacls` 輸出。
4. **用哪支 ssh、哪把 key**。§7 說手機私鑰只在 WSL 的 `~/.ssh`,但 `peer.py --via http` 是在 Windows 上起 `ssh` 子程序,要用 Windows OpenSSH、MSYS ssh 還是 `wsl.exe ssh`,沒有寫。
5. **可以考慮的替代架構**:`peer.py` 的核心放在 WSL(0600 有效,select 可用),Windows 端只放一個薄的 bleak frame 橋接(stdin / stdout 一行一個 frame,與 provclient proxy 相同),secrets 都不經 Windows。設計要比較這兩種做法並說明選哪個。

### M6. BLE 傳輸還沒驗證;認目標的方法會碰到 02,並和斷言互相衝突

1. **E-H9 還沒做**,但整個 Q2 / Q3 都建立在它上面(依規則,沒驗證的假設要在核准前以唯讀方式探過)。要測的內容:
   - connect 與讀 `STATUS`;
   - CCCD 寫入與 notify(AcquireNotify);
   - write-without-response 的節流;
   - 一則 9 KiB 訊息的分段與重組;
   - 連線維持 230 s(`settings.set` 最長的時間)。
2. **認目標要先連線**。廣播只有 UUID(F-H4),讀 `STATUS` 必須連上,所以會連到 02,而且沒拿 02 central 鎖。任何 BLE link 都會讓那台撤廣播(E8),會干擾另一個持有 02 鎖的 session 正在跑的測試。provd 在 `rpa_timeout` 時會重新註冊並換 RPA,連線前後位址可能不同,要有「重新掃描 → 驗證 → 重連」的規則。
3. **frame 大小**。Windows 的 ATT MTU 可能談到 517,`max_write_without_response_size` = 514 會超過 provd 的 `MaxFrame = 512`(E8),provd 會斷線。所以 frame 大小一律取 `min(CTRL key 3 / 244, max_write_without_response_size)`。bleak 在 Windows 上剛連線時可能先回報 20,要等 MTU 談完。
4. **Wi-Fi / BT 共存**。key 20 臂在 Wi-Fi reload 時,BLE 可能斷線(P3 §9-8)。回應遺失 = outcome unknown,這時應重讀 `settings.get`,不能判 FAIL 或 INVALID。
5. **斷言與傳輸衝突**。P3 §8 的 `prov-status-diag`「ro 10/s × 10 分鐘 … BLE 廣播在」,而 §2.5 寫「release;ble」。harness 自己一連上 BLE,節點就撤廣播(E8),這條斷言不可能成立。mesh 臂的「BLE 廣播在」也是一樣。這兩臂的負載要走 HTTP 或 sock,並由第三方(02 或桌機)掃描確認廣播在。
6. **另一個選項**:02 當 BLE central(h23 的 `ble-central-254.sh`,chain1 第 5 步已經實證過)。但新卡試用期間 02 連不到(E7),所以新卡臂仍然只能用桌機。設計要寫出這個取捨。

### M7. prov-http 的發送端在實體上不存在

**證據**(E7)
- 02 的 eth0 是 NO-CARRIER。02 的流量從 04 的 **bat0** 進來,而不是 eth0。
- 04 的 eth0 段上只有桌機(10:7c:61… 在 eth0)。

**影響**
- §2.5 的「02 的 eth0 / docker0 / bat0」與 §7.1「MAC 偽造只在 02 的 eth0」都跑不起來,E-H11 在 02 eth0 上建的 VLAN 也送不出任何封包(而且那一步已經改了節點狀態)。
- D-1 的 VID 0 雙層標籤要從 **04 的 eth0** 進來,所以要一台接在 lab 段、能送原始 L2 frame 的機器。WSL2 預設是 NAT,做不到;Windows 的網卡驅動會自己處理 802.1Q。
- docker0 臂依 F58 是 **04 自己的容器**,不是 02 的。
- 02 在自己的 `br-ahwlan` 上偽造手機 MAC,04 的 fdb 會把手機 MAC 學到 bat0 上:手機斷線、relay 斷線,一直到 fdb 老化(預設 300 s)或手機重新送出封包。這要列成副作用並寫出還原,也不能與手機臂重疊。

**修法**:列出每一臂的發送端(哪台、哪個介面、用什麼工具送),以及它要不要使用者到場(例如把 02 的 eth0 接到 lab 交換器、或用 USB 網卡加 usbipd 接進 WSL)。

### M8. dead-man / lease 的交互作用

1. **chain1 的 dead-man 是固定的 25 分鐘**(E4)。H4 的一輪新卡試用要依序跑 settings(約 120 分)、country-join、bundle-gate,dead-man 會在中途觸發:還原 p5、rollback、重開。`fresh-254.sh` 要改成可以續約的期限(以 p6 上的 deadline 檔作 heartbeat),而且要在 chain1 回歸裡證明續約有效、主機死掉時仍會觸發。
2. **擴充 lease deadman 要先改它的契約**。「deadman 從 `wireless` 快照還原 AP 帳密」違反了既有契約「never touches … p5」(E5)。還要處理:
   - 和還在跑的 setkey(最長 230 s)搶 `halow-setkey.lock`:兩個寫者;
   - key 20 已經 `--save` 進 p5,只還原 uci 會讓 p5 stale,OTA 被 reason 17 擋住;
   - keyguard 的 `disabled` / MARK 狀態;
   - `restoring` marker。
   修法:deadman 改用 `halow-setkey`(取同一把鎖)把值寫回並 persist,讀回驗證 hostapd;在單位開始時記下 p5 sha,結束時比對。

### M9. 破壞性副作用沒列完整;`fw-badinclude` / D-17 的安排自相矛盾

- **`firewall stop` 臂**:`fw4 flush` 會刪掉所有 nft 表,包括 docker 的 `ip filter` / `ip nat`(E6 的 `nft list tables`)。docker / OTS 的網路會一直壞到 dockerd 重啟。§7.1 沒有列。
- **`prov-luci-reset` 的 firstboot**:會清掉只存在 overlay 裡的東西(E11):OTS payload 的 init、dockerd / tailscale 的開機啟用,等等。要先寫出快照與 overlay-restore 的流程(chain1 已有),或者改在新卡試用 commit 後的 B 槽上做,A 槽完全不動。
- **`fw-badinclude`**:§2.5 寫「只在非 DUT、斷網」,但「斷網」沒定義。主機只能經 04 的 mesh 連到 02(E7),02 沒有防火牆時又整台暴露在 mesh 上。同時,D-17(autocommit 看 `inet fw4`)被放在 04 的 `prov-autocommit-p3-254`,而它的負對照正是 `fw-badinclude`,這與「只在非 DUT」矛盾。要定一個:在 02 上做 wbox trial(持 02 central 鎖,寫出隔離與還原),或者經使用者同意改在 04 的 held trial 上做。

### M10. 單位表不是逐列對表;對表檔不存在;有漏項

**證據**:`p3-units.tsv` 不存在(E12)。§2.5 用「P3 §8 該列全部」帶過,審查者沒辦法逐列核對(使用者的規則:範圍從規格逐列推)。我自己對照之後發現下列沒有對應到單位,或位置錯了:

| 來源 | 項目 | H4 現況 |
|---|---|---|
| P3 §6 | provd crash / crash loop →「`prov-http-254` kill 臂」 | 沒列 |
| P3 §6 | 依賴重啟:hostapd / `wifi reload` → `prov-http-254` | 沒列 |
| P3 §6 | `firewall stop` → ≤ 8 s 不聽 | 只寫「刪表」,沒有寫出 flush 的副作用(M9) |
| P3 §3.8.1 | `auto_includes = 0` → 不給 `http.2` | 沒列 |
| P3 §8 country-join | `network/update` 的國家不符 → 14 | §2.5 只寫「國家不符」,看不出 update 那一臂有沒有 |
| P3 §6 / §8 update | 「P2 未入網節點 sysupgrade 到 P3 → `--check` fresh」要的 image 鏈(wsl.22 新卡 → 認領 → sysupgrade) | 沒有設計 |
| D-12 | `update.check` 不拿 `n.mu`(可測:`settings.set` 進行中時 `update.check` 不被卡住) | 沒列 |
| D-13 | AP iface 是 `br-ahwlan` 的 port 才給 `http.2` | 放在 settings,應該屬於 prov-http |
| P3 §8 fw-boot | 「每次開機後」 | 沒有接進其他單位重開後的掛鉤(M11 的成本也沒算) |

**修法**:`p3-units.tsv` 要附在設計 PR 裡(P3 §5.1、§6、§8、附錄 D 逐列一行:斷言 → 單位 / 臂 → image / 交付 → 負對照 → 鑑別方式),作為審查對象,並以 lint 對 P3 原文做內容比對,不是只比列數。

### M11. 成本估計不實際(§7.2)

h23 的實測先例:hold 型單位約 47 分;30 個單位加 8 個 held-trial 負對照約 22–23 小時(`254-h23-harness.md:441-442`)。H4 還要另外付:
- autocommit 至少 6 臂,加上 2 個接縫、D-16 / D-17,每一臂一次 trial(revert 型約 37 分 + 600 s);
- prov-update 多次重開與 brewrite(每次約 14 分);
- upload 每換一個接縫就要重啟並重傳 126 MB;
- 備援要等 5 分鐘,每個臂好幾次;mesh 洪流 10 分鐘 × 2 臂(D-4);
- `--pre-p3-full` 在 wsl.22 上還要一次新卡試用;
- D20 重燒。

8–9 小時很可能少估了一倍以上。修法:逐單位、逐臂估時,列出試用與重開次數,交給使用者決定(使用者的規則:不要浪費錢)。

### M12. harness 自己的生命週期矩陣(§5)缺路徑

缺的路徑:
- 首次 / D20 之後(B2);
- 桌機睡眠或 Modern Standby:BLE 與 ssh 同時斷,單位怎麼收尾;
- H4 與 P3 的版本不一致(用舊的 tsv 對新的 rc);
- 02 重開或離開 mesh(country-join、prov-http 正在用 02 時);
- 手機切到別的網路(M4-3);
- Windows 藍牙服務或驅動重啟;
- 中途換接縫(M1-2);
- 新卡試用時 04 的 IP 變了,手機要跟著換 node-ip。

每條都要寫「行為 + 測法」,或寫明不適用的理由。

---

## MINOR

- **m1 F-H1**:我的唯讀證據(E6)支持 F-H1:沒有 `isolate`、`accept_to_ahwlan` 的計數器在跑、iptables FORWARD 是 ACCEPT、br_netfilter 有載。請把這些證據附進 F-H1,但 E-H8 仍然要做。
- **m2 手機 sshd 的曝露面**:它在 04 的 AP、整個 mesh LAN(bridge)、家用 Wi-Fi 與行動網路(若有公網 IPv6)上都聽得到。建議:`authorized_keys` 加 `no-port-forwarding,no-agent-forwarding`;不要跑 `termux-setup-storage`(否則 shell 可以讀使用者的檔案);只在跑測試時起 sshd。
- **m3 `uci-argv` 的 log 會記下所有 uci argv**,包括其他元件在 argv 帶的秘密(mesh key 等)。只在節點上 grep,只輸出計數或 `short()`,臂結束就刪,絕不複製到主機或 PR。
- **m4 失敗時保留 `state.json`**:檔裡有 04 擁有者的私鑰,要定保留期限與刪除時機。
- **m5 `p3-expect.tsv` 的 lint**:「列數與 §5.1 一致」定義不清。§5.1 有一列帶多個碼(例如 `1 / 2 / 3 / 4 / 5 / 6 / 8 / 11 / 12 / 17`),應改成比內容(動詞、情況、碼的組合)。
- **m6 eeprom-hooks 的負對照要釘死 build 與 sha**:`/home/yello/out` 有 1.5.12-wsl.2…17 共十幾個 build,哪一版還沒有 shim 要寫明。在 WSL 跑 fresh overlay 要 arm64 qemu binfmt,也要寫明。
- **m7 key 20 的「30 s 內新帳密可連」要拆開**:節點端 AP 起來(≤ 30 s,P3 的要求)和 Android 連上(手機的行為)分成兩條,否則 Android 的 PNO 掃描延遲會被誤算成產品 FAIL。
- **m8 §2.3 說新卡試用期間「手機仍然到得了」不對**:新卡的 AP 在 key 20 之前被 keyguard 關著。
- **m9 `prov-fw-boot-254`「每次開機後」**要寫成單位框架裡的掛鉤(prov-update 等重開之後也要跑)。
- **m10 wsl.22 的基準要另外跑新卡**:需要 `RadioManaged = true` 狀態的臂(key 2 / key 20 / country-join),在 legacy 的 04 上只會走到 reason 20 那條路,wsl.22 的基準要用新卡試用另跑;成本也要算進去。
- **m11 E-H11 的結果沒有參考價值**(02 eth0 沒有載波),請從證據表拿掉,改由 M7 的發送端方案重做。

---

## 附:各單位鑑別力摘要(wsl.22 上會不會 FAIL)

| 單位 | wsl.22 上有鑑別力的斷言 | 只能靠接縫(P3 PR 才有)或空著通過的斷言 |
|---|---|---|
| prov-p3-routes | 碼精確比對 → 全部 FAIL | — |
| prov-owner | add / remove 的碼 | 「session 被切」:wsl.22 根本沒有 session 可切,要有前提證據 |
| prov-settings | key 20 / key 2 不存在 → FAIL | rollback、讀回、trap、cmdline:只有接縫或注入點(M1-5) |
| prov-country-join | join 不擋國家 → FAIL | — |
| prov-status-diag | status 的碼 | no-ERate、廣播在、bundle 不含秘密 → 空著通過(M2、M6-5) |
| prov-bundle-gate | claimed → 403 FAIL | `status` 200(本來就成立) |
| prov-http | 正向 FAIL | 所有「丟 / 不聽」的斷言 → 空著通過,要前提證據與接縫 |
| prov-upload | ENOSPC 等 | 刪檔、非擁有者 → 要前提證據 |
| prov-update | 碼 | 接縫在 B1 的交付方式下跑不了 |
| prov-autocommit-p3 | provd 壞掉 → revert(wsl.22 不 revert) | 正向「commit」在 wbox 上不可能(B1) |

## Verdict:**REJECT**

B1 與 B2 會讓大部分單位寫不出來,或跑出空的 PASS。M1–M12 每一項都需要改設計,不只是改文字。改完請送整份重審,不是只審增量。
