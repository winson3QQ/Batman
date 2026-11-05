# H4 harness 設計 v1 — 審查 A

- 審查對象:`docs/design/254-h4-harness.md`(branch `harness/254-h4`,a31489b)
- 上層:P3 `254-p3-impl.md` v7.1(`feat/254-p3` dfedd03)§5、§6、§8、附錄 D;h23 `254-h23-harness.md`(main 2ecf1cb)
- 審查者:A(獨立、對抗式)。2026-11-02。
- 方法:整份讀完;P3 §8 每一列、附錄 D-1..D-17 逐條對 H4 §2.5;H4 §1.3 每條事實回源碼或節點查。節點只做唯讀(04 = 10.41.1.3:`cat /etc/batman-build`、`uci show wireless`、`bridge link`、`iw dev`、`ip -br addr`、`uci show dhcp`;02 = 10.41.1.1:`bridge link`、`ip -br link`、`command -v`)。沒有改任何節點狀態,沒有改 repo 檔案(只寫本報告)。

**結論:REJECT — 2 BLOCKER / 8 MAJOR / 15 MINOR。**

主要問題:H4 拿來執行測試的方式(`-wbox` 的 held 試用、chain1 式新卡試用),和產品現在的硬規則衝突。規則一:試用中所有會改狀態的動詞都回 `E_BUSY`。規則二:`-wbox` image 永遠不會被 commit。規則三:held 試用有 600 s 期限。結果是 P3 §8 大半的正向臂與負對照,照這份設計根本跑不起來。另外,P3 §8 與附錄 D 的逐列對表放在一個還不存在的 TSV 裡,覆蓋率無從驗證。

---

## BLOCKER

### B1 — 負對照用 `-wbox` held 試用執行:會改狀態的動詞全部被擋;T 簽章沒有可信任它的 committed 底座;「會被 commit」這個觀察點不存在

**情境**
H4 §2.4、§2.5 規定所有 Go 接縫的負對照都在 `-wbox` 試用上跑。這包括 `upload-noowner`、`upload-nosrcip`、`upload-nobusy`、`p5-autosave-off`、`http-nofw`、`healthok-2field`、`ro-on-ctl`,以及 `uci-argv`、`autocommit-*`。這條路有三個問題。

1. **試用中會改狀態的動詞一律 `E_BUSY`。**
   - `node.go:206-207`:`if stateChanging[verb] && n.Sys.IsTrial() { return nil, fail(EBusy, "trial slot (updating)") }`。
   - `stateChanging` 清單(`node.go:199-200`)含 `claim.verify`、`net.apply`、`owner.add`、`owner.remove`、`settings.set`。
   - P3 §3.7.4 的 `update.check` 在試用中回 reason 1,P3 §5.1 也寫「所有 state-changing:試用中 → P1b 既有對應」。
   - h23 §4.4 自己也寫「trial 內不能改狀態(F9)」(`254-h23-harness.md:255`)。

   所以下面這些在 wbox 試用裡都不可能發生:
   - `prov-upload` 的三個 Go 接縫:`bulk.open` 要先有 pending,pending 要靠 `update.check`,而 `update.check` 在試用中回 reason 1;
   - `prov-update` 升級臂的 `p5-autosave-off`;
   - `prov-settings`、`prov-country-join` 的認領、key 20、join(B2 另述)。
2. **T(測試根鑰匙)只有 prov_test image 信任**(P3 §3.7.1)。prov_test image 只能以 wbox 試用的形式存在,不能 commit。
   - P3 §8 的 `prov-update` 主臂「T 簽的 image 經 app 路徑 → trial → commit → 5」需要一個**已 commit、又信任 T** 的底座。H4 沒有提供。
   - release 底座不信任 T;wbox 底座在試用中,`update.check` 回 reason 1。
   - 結論:主臂、惡意 tar 四包、FIFO、簽章錯、serial、降級、min_from 等**全部進不了 worker**。
3. **wbox 永遠不 commit**(`batman-autocommit:485-530`,`WBOX-NOCOMMIT`)。
   - H4 寫的負對照是 `autocommit-noprov`「壞 provd 被 commit」、`p5-autosave-off`「升級臂 stale」(D-9 要的是試用轉 committed 那一刻)。這兩個觀察點在 wbox 上不會出現。
   - H4 §1.4 說 autocommit 接縫做成 wbox 是「照 h23 §17 的 misc 變體先例」。**這是引用錯誤**:h23 §17.2(`254-h23-harness.md:706-718`)的 misc 變體正好相反,是「只在 dry-run 裡用、在 committed 槽 bind `/usr/bin/batman-autocommit`、以 `DRYRUN decision: COMMIT` 判定」,明文**不在試用裡用**。

**證據**:上列 `file:line`;`prov-wbox-254.sh:1-21`(既有的 `bind`、`push-helper`、`set-provd-env` 都是在 committed 槽上做的機制);`batman-provd-test.init:1-60`(provd 的測試開關只在 prov_test image 的 init 裡)。

**建議修法**:改寫 §2.4、§2.5 的「執行載具」。每個接縫、每一臂要寫明下面其中一種:

- **(a) helper 的 Go 接縫**:用 h23 的 `push-helper` 在 **committed release 槽**上 bind prov_test helper,再 restart。契約要規定 **T 的信任編進 prov_test helper 的二進位**(build tag),而不是 image 上的檔案;否則 bind 後的 helper 仍不信任 T。這要寫進給 P3 的接縫契約,讓 release gate 照樣能斷言。
- **(b) provd 的 Go 接縫**:目前只有 prov_test init 能讀 `provd.env`。要嘛提供「在 committed 槽 bind prov_test 的 provd 與 test init」的機制(列出 jail 掛載、procd 重新載入的證據),要嘛承認這些臂只能做「在試用裡也做得到的動作」,並逐臂重新設計:
  - `upload-*` 三個:窗擁有者、來源 IP、`otaBusy` 都要先有 pending → 試用中做不到 → 必須用 (b) 或另想辦法;
  - `healthok-2field`、`http-nofw`、`ro-on-ctl`:唯讀與 HTTP 監聽在試用裡做得到,但要配合下面 B2 提到的 600 s 期限。
- **(c) autocommit 接縫**:照 h23 §17 用 dry-run bind,以 `DRYRUN decision: COMMIT` / `REVERT` 判定;不要做 wbox 試用。
- **(d) 真試用(V hold → release)**:正向臂一律用 release V。
- 「wbox 試用」只留給「試用本身就是被測物」的臂(例如 D-17 的 `fw-badinclude`,見 M5)。判定看 `WBOX-NOCOMMIT` / `TRIAL-REVERTED`,不看 commit。

### B2 — 新卡臂(settings / country-join / bundle-gate unclaimed)放在 held 試用裡:跑不完、狀態改不了、手機連不上

**情境**
H4 §2.3 從 chain1 抽出「步驟 1–5 與 9」做 `fresh-254.sh`,並在 §2.5 規定 `prov-settings-254` 用「新卡試用(wbox `test` + `uci-argv`)」,約 120 分;country-join 同一輪。

1. **步驟 1–5 結束時是 held 試用。** chain1 自己寫「well inside the 600 s deadline of a held trial」(`chain1-254.sh:275`)。認領、key 20、join 都是在**步驟 6 release → B committed**(`chain1-254.sh:280-296`)與步驟 8(`PH=s8.2`,`:340`)之後才做的。
   - H4 沒抽步驟 6,所以新卡停在試用中:
     - 認領(`claim.verify`)回 `E_BUSY`(B1-1);
     - 約 10 分鐘後 deadline revert。
   - 改用 wbox `test` 也一樣:wbox 永遠不 commit,所以新卡不可能變成 committed。
   - 所以 `prov-settings` 的「新卡 → 認領 → key 20 → 不重開 → 30 s 內 AP 起來 → p5 有新值」、`prov-country-join` 的 join / 14、D-5 / D-6 / D-7 / D-11 / D-13 全部做不到。
2. **dead-man**:chain1 的 dead-man 是在步驟 6 才種在 B 上的(`chain1-254.sh:291`,`sleep 1500`)。H4 寫「步驟 1–5 與 9 + dead-man」,但 dead-man 的種法屬於步驟 6。
   - 25 分鐘的單發 dead-man 會在 120 分鐘的單位中途觸發(p5-restore + rollback)。
   - H4 沒寫怎麼延長 / 取消 / 續期。
3. **§2.3 最後一句「手機仍然經 eth0 → bridge 到得了(F-H1)」不成立。** 新卡的手機 AP 被 keyguard 關著(P3 F49、F74;chain1 步驟 5 斷言 `ap=0`,`chain1-254.sh:268`)。
   - key 20 之前,手機不在 04 上,也不在 phone.conf 記的 IP。
   - 新卡的 04 位址也會變(chain1 的 `find04` 要掃 10.41.254 / 10.41.1)。
4. 新卡期間主機只能經 04 的 mesh 到 02(`chain1-254.sh:3-5` 的註解)。04 新卡離開 mesh 時,country-join 的「+ 02」那一半如何協調、02 的 central 鎖怎麼拿,都沒寫。

**證據**:上列行號;`node.go:206-207`;P3 F49、F74;h23 §4.4。

**建議修法**:
- `fresh-254.sh` 要涵蓋步驟 6:release → commit → reservation reboot → 重新找到 04。之後就是 committed、unclaimed 的 release V,可以認領、改狀態。
- dead-man 改成可續期:由 lease 驅動,或每次 renew 重設 `sleep`。寫明單位最長時間與續期規則。
- D-11 的 `uci-argv` 改用 `bind`(在 committed 新卡上把 shim bind 到 `/sbin/uci`,單位結束 unbind),不要 wbox。
- 手機臂的前置改成:「key 20 之後才要求手機在 04 上」,key 20 之前手機臂一律 INVALID。新卡的 IP 由 `fresh_ip` 傳給 relay 的 argv。
- 寫明新卡期間 02 怎麼處理。

---

## MAJOR

### M1 — P3 §8 與附錄 D 的逐列覆蓋表放在不存在的 `p3-units.tsv`;多個 D 項只有標籤,沒有誘發方法,也沒有負對照

**情境**:H4 §2.5 的「主要臂」欄大多寫「P3 §8 該列全部 + D-x」,逐列對表指向 `tests/tools/peer/p3-units.tsv`。這個檔不在 a31489b(`git diff --stat main..HEAD` 只有設計文件一個檔)。審查者無法驗證「每一列都有鑑別性斷言 + 負對照」。逐條對下來:

| 項目 | H4 寫了什麼 | 缺什麼 |
|---|---|---|
| D-3 | 「D-3 lint」 | helper 的「ruleset 裡有別人寫 bit 24 → 不給 `http.2`」這一臂:在 04 加一條外來的 `meta mark set … 0x01000000` 規則 → 斷言 8 s 內不聽;負對照沒寫 |
| D-5 | 只有標籤 | settle 逾時、run dir 不能用、`.txn` 存在三種情況怎麼誘發(沒有接縫;`.txn` 可以由 root 建,另外兩種要接縫或 chmod),以及各自期望的結束碼(5 / 12) |
| D-6 | 只有標籤 | 「還原也驗證失敗」**沒有對應的接縫**。`setkey-readback-skip` 的效果正好相反。需要例如 `setkey-rollback-readback-fail` 讓 rollback 的讀回失敗,才看得到 rc 6 + 封鎖 + CRIT |
| D-7 | 只有標籤 | 前置(root 以 uci 設含 `'` 的 SSID、不經 setkey)→ key 2 → 斷言成功、不還原;負對照(把 rc 6 當失敗的 helper → 被還原)沒寫 |
| D-8 | 「D-8(bit 先清)」 | 怎麼讓非 `phy*` port 的 frame 先帶 bit 24(例如在 bridge 更早的優先序加一條從 eth0 打 bit 的規則)、從哪個來源送、負對照(沒有清 bit 的規則 → 放行) |
| D-10 | 只有標籤 | 「`reboot committed` 失敗時 disarm」要有接縫讓 `batman-slot reboot committed` 失敗;沒有列 |
| D-13 | 放在 `prov-settings` | 這是 helper 的 HTTP 前提,應該在 `prov-http`:例如 `ip link set phy1-ap0 nomaster` → 斷言 `http.2` 消失、`status` 有回報;還原與負對照沒寫 |
| D-15 | 只有標籤 | 怎麼讓 bulk tmpfs 掛不上(例如預先在掛載點放一個非目錄),斷言 helper 不開窗(reason?)、沒有退化成一般目錄 |
| D-17 | 見 M5 | |
| P3 §8 legacy 臂 | 沒寫 | 「legacy key 2 / 20 → 20」「legacy 無旗標 → 403」「legacy + dev-open → 200」:D20 重燒後 fleet 沒有 legacy 節點,要用 h23 `prov-legacy-upgrade-254` 的 `strip-p5-prov` 這類方式造出 legacy 的 P3 節點。H4 沒寫載具 |
| P3 §8 update | 「P3 §8 該列全部」 | 「新版沒開機成功(注入:目標槽 kernel 壞掉)」的誘發方式與安全性(見 M8);T 簽章工具(`release-sign.sh` 是 YubiKey 用的,T 要軟體簽章器)沒列在本 PR 的範圍 |

**建議修法**:把 `p3-units.tsv`(或同等的表)放進設計文件或同一個 commit。每一列寫:P3 §8 原句或 D 編號 → 單位 / 臂 → 載具(B1 的 a–d)→ 誘發方法 → 斷言(確切碼 / 字串)→ 負對照類型(wsl.22 FAIL / 接縫 / 不適用 + 理由)。lint 以 P3 §8 的列數與 D-1..D-17 為基準。

### M2 — HTTP 臂沒有說「HTTP 怎麼開起來」;上傳窗要 pending,pending 要可信任的簽章

**情境**:P3 §3.8.1 規定 provd 只有兩種時候才監聽:備援(`HealthOK` 連續 5 分鐘為 false)或上傳窗(`bulk.open`)。

H4 的 HTTP 臂(`prov-p3-routes` 的 HTTP 半邊與 key 20 → 19、`prov-owner` 的 HTTP session 被切、`prov-upload`、`prov-http` 正向)都沒寫它們用哪一種:
- **上傳窗**:`bulk.open` 要有 pending → pending 要 `update.check` 驗過簽章。release 底座只信任 R(YubiKey,NEEDS-PERSON),T 又沒有可用的 committed 底座(B1)。
- **備援**:要停 bluetoothd ≥ 5 分鐘。這時 BLE 不健康,所以 `prov-owner`「BLE 與 HTTP session 都被切」所需的**同時存在**的 BLE session 做不到。

另外,這些單位被標成 A 類(15 / 10 分);一停 bluetoothd 就是破壞性、要 5 分鐘以上(Pi 4 BT UART 的 #305 風險另見 M8)。

**建議修法**:每個 HTTP 臂寫明開法:
- 上傳窗:配合 B1 的 T 信任方案;
- 或備援:列出停 bluetoothd 的副作用與還原。

另外,`prov-owner`「BLE 與 HTTP 同時」必須走上傳窗。單位類型照實改。

### M3 — 手機 relay 沒處理 Android 的實際行為:預設網路、自動切回家用 Wi-Fi、每個 SSID 一個隨機 MAC、「出現在 station dump」≠「帳密可用」

**情境**(從真實使用出發):

1. **預設網路。** 使用者的設定文件(`Desktop\Batman\S20-termux-setup.md` §4)寫「手機上網會自動改走行動數據」:04 的 AP 沒有網際網路,行動數據開著,預設網路就是行動網路。
   - Android 的 unbound socket 走預設網路。Termux 的 `http.client` 沒有 `bindProcessToNetwork`,P3 §3.11 第 3 項也把這列為 app 必做。
   - 所以 relay 對 10.41.1.3 的連線很可能走行動網路而失敗。
   - 桌機 → 手機的 ssh(進來的連線)照樣通,preflight 1–4 全過,但 relay 連不到。
   - E-H8 會發現這件事,但設計沒有出路。
2. **自動切網。** 手機附近有家用 Wi-Fi(已存、有網際網路)時,Android 會優先連有網際網路的網路:
   - 04 的 AP 換成 `batman-h4-alt` 那一刻,手機極可能回到家用 Wi-Fi,而不是連已存的 alt。
   - 平常也可能自己從 04 的 AP 跳走。
3. **MAC。** Android 的隨機 MAC 是「每個 SSID 一個」。`batman-h4-alt` 的 MAC ≠ phone.conf 記的那一個,所以 §2.2 用「preflight 第 2、3 項(MAC 出現在新 AP 上)」證明新帳密可連,一定判失敗;而改成「任何新 station」又無法證明那是這支手機。
4. **station dump 不是證明。** hostapd 在 association 時就會把 station 列出來,PSK 錯的話 4-way 失敗後才移除。短暫出現就會讓「新帳密可連」誤判 PASS。
5. **經手機的負向斷言沒有正向對照。** 例如「平常不聽」「恢復後不收新連線」:如果手機的流量其實沒走 Wi-Fi,`ERR connect` 會被當成「不聽」→ 假 PASS。另外,`ERR` 只有 `connect|timeout|reset`,分不出 RST(沒有 bind)與被丟棄(防火牆)。

**證據**:`S20-termux-setup.md` §4 第 2 點;04 `uci show wireless`:`default_radio0.encryption='psk2'`、SSID `BCM2711-6c89`;P3 §3.11 第 3 項。

**建議修法**:
- 設定步驟加:
  - 測試期間行動數據關閉,或把 04 的網路設成「保持連線 / 不自動切換」(Samsung 的「切換至行動數據」關掉);
  - 家用 Wi-Fi 關掉自動重新連線;
  - 兩個網路的 MAC 類型都設成「手機 MAC」,或把兩個 MAC 都記在 phone.conf。
- 「新帳密可連」的判定改成三件事同時成立:
  - `hostapd_cli all_sta` 該 MAC 的 flags 含 `AUTHORIZED`;
  - 桌機經新 AP ssh 到手機成功;
  - relay 對 04 uhttpd :80 拿到 200(可以的話再加 Termux:API `termux-wifi-connectioninfo` 的 SSID)。
- 每個經手機的負向斷言,都要在同一臂內先做 relay → 04:80 的正向對照。relay 的錯誤再細分 `refused` / `timeout`,並把期望值寫進 `p3-expect.tsv`。
- 每臂前後各做一次 station 檢查,確認手機沒有跳網。

### M4 — mesh / VLAN / eth0 / docker0 臂的流量從哪裡送,沒有寫;02 沒有可用的工具,02 的 eth0 也沒接線

**情境**:H4 表寫「02 的 eth0 / docker0 / bat0」與「MAC 偽造只在 02 的 eth0 這一臂」。實查結果:

- 02 `eth0: <NO-CARRIER…> state disabled`,`/sys/class/net/eth0/carrier = 0`,eth0 上沒有任何主機;
- `br-ahwlan` 的 MAC = eth0 的 MAC(`d8:3a:dd:f8:45:d7`)。改 eth0 的 MAC 會連帶改 bridge 的 MAC → 02 的 IPv6 / DHCP 身分改變;
- 02 上 `python3=n hping3=n nping=n scapy=n arping=n socat=n`,只有 `nc`、`ip`、`tcpdump`。

所以下面這些都做不出來,至少 H4 沒說怎麼做:
- P3 §8「50 conn/s、手機 MAC + IP(含 ARP 毒化)」;
- D-1 的「VID 0 雙層」SYN;
- 「從 eth0 進 04」:04 的 eth0 對面是桌機 Windows,WSL2 不在同一個 L2,Windows 也做不出 QinQ。

docker0 臂要在 04 起容器,04 的 `docker0` 現在是 DOWN、上面沒有容器。E-H11 也自己承認已經在 02 / 04 做過 `ip link add`(超出唯讀)。

**建議修法**:每一臂寫明:
- 發送端在哪(02 的 netns + veth 接進 `br-ahwlan`?推一個靜態 aarch64 工具上去 → 供應鏈與 sha 釘選?);
- 從 04 的哪一個 ingress port 進來(bat0 / eth0 / veth);
- 怎麼建 VID 0 雙層(`ip link add … type vlan id 0` 疊兩層 + `nc`);
- 改了 02 / 04 的哪些狀態、怎麼還原、怎麼驗證還原;
- 不改 02 的 eth0 MAC,改用 veth 帶偽造的 MAC。

eth0 ingress 的臂如果做不到,就照實標成 NEEDS-PERSON 或誠實界線。

### M5 — D-17 / `fw-badinclude` 前後矛盾;autocommit 負對照的判定方式沒定義

**情境**:
- H4 把 `fw-badinclude` 限定為「只在非 DUT、使用者同意、斷網」(§2.5 `prov-fw-boot`)。但同時把 D-17(autocommit 要求 `inet fw4` 在,`fw-badinclude` 測試)放進 `prov-autocommit-p3-254`,而那個單位在 04(DUT)上跑。兩者矛盾。
- D-17 的負對照語意是「沒有這項檢查 → 帶著壞 include 的 image 會被 commit」。用 wbox 試用永遠觀察不到 commit。

**建議修法**:
- D-17 正向:`fw-badinclude` wbox 試用 → 期望 `TRIAL-REVERTED reason` 含 fw4。地點、斷網方式、時長要寫清楚;如果只能在 02 做,寫明 02 的鎖與還原。
- 負對照:用 h23 §17 的 dry-run bind(沒有 D-17 的 autocommit + 一個人為移除 `inet fw4` 的 committed 槽?注意這也是無防火牆窗口),或判定 `WBOX-NOCOMMIT`(= 健康,會被 commit)。
- 改正 §1.4 對 h23 §17 的引用。

### M6 — 擁有者身分每個 run 刪除 → harness 會被永久鎖在 02 / 04 外面

**情境**:§2.1 規定 owner 私鑰與 PSK 寫進 `%LOCALAPPDATA%\batman-dv\prov-owner\<run>\state.json`,「每個 run 用一個新目錄,run 結束時刪除」。但是:

- D20 之後 02 / 04 是**已認領**的 release 節點,release 臂(routes / owner / status / http / upload / update)都需要它們擁有者的私鑰;
- F-H10:產品裡沒有回到 Unclaimed 的路。

所以只要一個 run 結束時刪掉了認領 02 / 04 的那把鑰匙,之後 harness 再也拿不到擁有者身分,只能重燒(破壞性,要人在現場)。設計也沒寫 D20 重燒後是誰認領、鑰匙放在哪、成員 PSK / net_config 誰持有。

**建議修法**:
- 分成兩類狀態:
  - fleet 擁有者:長期保存、有備份、每個節點加一位備用擁有者(與 D17 一致);
  - 每個 run 自己的臨時狀態:可以刪。
- `prov-owner` 的 remove / 最後一位這類臂,只對臨時加入的擁有者做,並以 prov-base 快照為退路。
- 寫明 Windows 端該目錄的 ACL 由程式設定並驗證(icacls 讀回),不要只是假設。

### M7 — §9-4 探針(D-1 / D-2,也是 H4 的凍結閘門)沒有設計內容

**情境**:§1.2 第 8 項只列了一個檔名 `http-src-probe-254.sh`。P3 D22 規定探針在 **02(非 DUT)**做;D-2 要「bridge 鏈的 mark 計數器有增加」與「AP client 通過」。

H4 沒寫:
- 要在 02 載入哪些臨時表(v7 規則、v6 規則、備案規則)、刪表與比對基準(F75 的做法);
- 怎麼證明 v6 規則**放行** VID 0 雙層(D-1 要求先證明舊規則被繞過);
- 計數器怎麼讀;
- 「AP client 通過」需要手機連 **02 的 AP**:但手機的設定、MAC、phone.conf 都只為 04 設計。而且 02 的 AP 密碼是真實秘密,要怎麼交給使用者?設定文件 §4 寫「熱點的名稱和密碼我到時候再給你」= 秘密會出現在對話紀錄裡;
- 走備案規則時「另做一次短審查」由誰觸發、凍結條件怎麼判。

這個探針會改 02 的 nft 狀態。

**建議修法**:寫成完整的一節:步驟、每一步的期望輸出、負對照(v6 規則放行 → 證明探針有鑑別力)、還原與驗證(`nft list tables` 與基準相同)、手機連 02 的方法(02 的 AP 暫時改成測試帳密,由 harness 經 uci 設、結束還原,不在對話中傳真密碼)、凍結判定。

### M8 — 破壞性副作用與還原不完整;有一個未經證實的「不會變磚」假設

**情境**:§7.1 只列了大項。漏掉的有:

1. **P3 §8「新版沒開機成功(注入:目標槽 kernel 壞掉)」**:Pi 4 的 tryboot 載入壞掉的 kernel 時,是 hang 住還是回到預設槽?沒有證據(需要 watchdog / `panic=` / 韌體行為)。如果 hang 住,04 要人去拔電,遠端的使用者會被卡住。依規則這是「沒有證據的假設」,要先唯讀查證(firmware 文件 + 04 的 `config.txt` / cmdline 的 `panic=`、watchdog 設定),必要時改成「截斷 kernel → 韌體讀檔失敗」並附證據。
2. `/etc/batman-dev-open` 存在期間,legacy 認領的安全閘被放寬(`node.go:529-534`:`DevOpen` 時不要求 ssh key)。這段時間附近的人可以認領。要列出窗口長度、EXIT trap 與 dead-man 的清除方式。
3. key 20 臂讓 04 的 AP 換帳密 → 連在 04 AP 上的其他 EUD(TAK 手機)全部斷線。
4. 停 bluetoothd ≥ 5 分鐘、反覆啟停:Pi 4 的 BT UART 可能卡住(#305,`bt-uart-305.sh`),需要重開才能恢復。
5. 改 p6 `autocommit.timeout` 以延長試用(如果用 B2 的修法):會影響所有 revert 型單位的預算(h23 P9 會印)。
6. 02 的 netns / veth、04 的容器(M4)。
7. `/tmp/batman-fault.*` 留在節點上會讓 setkey 不還原、讓 batman-slot 複製所有 boot 檔。dead-man 也要清,不能只靠 EXIT trap。

**成本**:
- 「8–9 小時」沒有算入:
  - 新增的 wbox / prov_test build(每個 rc 增加的份數);
  - T 簽章的 payload build;
  - 每個 wbox 試用之後的 brewrite;
  - P9 / normalise。
- 依 P-U10,這些都是每次 prov PR 的固定成本。

**建議修法**:§7.1 改成逐單位的副作用 / 還原 / 驗證表(h23 慣例);第 1 項先唯讀查證,附上原始輸出。

---

## MINOR

1. **F-H13 行號錯。** 「key 20 經 HTTP → reason 7」在 P3 `:168`(§3.1 第 2 點),不是 `:183`(`:183` 是轉送表的一列)。
2. **fault 檔的契約。**
   - (a) 一個檔、兩個讀者(helper、provd init)。「不認得的名字 → 拒絕啟動」會讓 helper 遇到 provd 的名字(`ro-on-ctl`)就拒絕啟動。要分元件的封閉清單(各自忽略對方的名字),或乾脆分成兩個檔。
   - (b) §2.4「拒絕啟動」與 §4「壞檔 → 不設 + 記一行」不一致,寫清楚哪種情況 fail-closed、哪種 fail-open、理由是什麼。
   - (c) 單位必須斷言「本次 pid 記了 `fault <name>: armed`」,沒有就 INVALID(照 `push-helper` 的作法)。
   - (d) 開關一個接縫 = 寫檔 + restart + 斷言;寫明 restart helper 會重跑 boot 階段(P3 F42),restart provd 會切斷所有 session。
   - (e) `batman-provd-test.init:26` 的 `_provd_env` 只接受純數字的值,`BATMAN_FAULT=<names>` 會被丟掉。這要列為 P3 要改的地方。
3. **pre-P3 偵測**用 BLE 交握去送 `settings/get`,太重也太脆弱:BLE 或手機不在時只會得到 INVALID,而不是那一行已知失敗。建議改用 ssh 唯讀判斷(例如 helper 的 `--version` 或 `strings` 找新動詞名)。`prov-fw-boot`、`prov-eeprom-hooks`、`prov-transfer-tool` 根本不經 provd,要另外定判斷方式。也要寫明 INVALID 在 daily-validation / known-failures 裡怎麼分類(`kf_classify` 只看 `FAIL` 行;只有 INVALID 的 log 會被歸為「no FAIL lines」→ new)。
4. **`--pre-p3-full` 的標準**「每個單位至少一條 FAIL」太寬。要逐條斷言標出負對照類型(TSV 加一欄),lint 檢查每條都有。
5. **`ro 10/s × 10 分鐘`**:P3 §3.1.9 規定 `status` / `diag/summary` 每連線 1/s、全域 2/s。要寫明用哪些動詞(`settings.get`、`update.status`、`diag.read`?)、經哪個傳輸、送多快,並算出 `ro-on-ctl` 下 ctl 會超過 5/s,證明這個負對照有鑑別力。
6. **秘密欄位清單。** `peer.py` 要明列每個動詞回應裡的秘密欄位(`bulk-open-resp` key 2、`owner/add` 的 tag key、PSK、認領輸出),這些一律只印 `short()`。`uci-argv.log` 在負對照時會含密碼:root 0600、單位結束時刪除、不得拷回主機的 log。
7. **Windows / WSL 的銜接。** `peer.py`(Windows)要用的手機私鑰在 WSL 的 `~/.ssh`,要寫明是經 `wsl ssh` 子程序,以及 stdin / stdout 的編碼。手機 sshd 的 host key 要釘在 phone.conf 裡(手機 IP 來自 DHCP,同一 AP 上的其他裝置可能冒充)。
8. **生命週期缺項。** Windows 睡眠 / 自動更新重開、`wsl --shutdown`、BLE adapter 重置、02 在臂進行中當機、手機系統更新、lease 續期(120 分鐘的單位 > h23 lease 初值 3000 s)、lib 與單位的 EXIT trap 怎麼組合(bash 只有一個 EXIT trap)、「04 非預期重開 → FAIL」沒有測法。
9. **`prov-eeprom-hooks-254` 在 WSL 上的「fresh overlay」**:要寫明執行機制(qemu-aarch64 chroot?跑哪幾支 uci-defaults?假 `vcgencmd` 放在 PATH 的哪裡)與 1.5.12 負對照的實跑方式。
10. **country-join 的入網臂**要指定一個在 ch 40 合法、而且與 US 同頻率的國家(AU / NZ / SG,P3 F79)。`DE` 只能用在「`settings.set` key 2 成功」那一臂,不能拿來入網。
11. **攻擊面漏列。** 手機 sshd 不只家用 Wi-Fi / 04 AP / 行動網路可達:經 `br-ahwlan` ↔ `bat0`,**整個 mesh** 都到得了。請列入。另外,04 AP 的真實密碼不應出現在對話中(設定文件 §4)。
12. **`prov-luci-reset-254` 沒有負對照。** 可以用 wsl.22 的 `flash.js` 舊字串 `Perform reset` 當負對照,證明文字斷言有鑑別力。
13. **接縫負對照在 P3 實作前都跑不了。** H4 PR 的測試結果要把它們列成 ❌(未執行),由 P3 PR 附上證據;不要讓人以為 H4 已經證明了它們。
14. **`SOCK_ONLY=1` 時 provd 的 `HealthOK` 為何?** 如果 BLE 被視為不健康,5 分鐘後 HTTP 備援就會開,干擾 sock 臂。要附證據,或在 sock 臂斷言 8095 沒有在聽。
15. **§2.1「一次一條連線」引用 P3 §2 引錯對象。** P3 §2 的限制是「helper 的第 4 條連線」(provclient → helper),不是 provd 的 BLE / HTTP session。`prov-owner`(BLE + HTTP 同時)與額度臂本來就要並發的 session。請改寫,避免實作時誤加互斥。

---

## §1.3 事實查證

| # | 結果 | 證據 |
|---|---|---|
| F-H1 | ✅ `phy1-ap0`、`eth0`、`bat0` 都在 `br-ahwlan`;SSID `BCM2711-6c89`。**但「新卡試用期間手機仍到得了」不成立**(B2) | 04 `bridge link`、`iw dev`、`uci show wireless` |
| F-H3 | 未查(來源是 issue 留言) | — |
| F-H4 | ✅ 檔案在 `cmd/batman-provd/bluez.go:269`(H4 沒寫目錄) | grep |
| F-H5 | ✅ 除了自己引用自己,沒有呼叫者 | `grep -rn peer.py\|tests/tools/peer`:只有 `verify.py:290` 的註解 |
| F-H6 | ✅ WSL 的 `import noise` → `ModuleNotFoundError`;`requirements.txt:33-35` 有 pin 與 hash | WSL |
| F-H7 | ✅ | `seam/seam_provtest.go`、`points.go` |
| F-H8 | ✅(實際在 `batman-slot:73-75`) | |
| F-H9 | ✅ `batman-autocommit:485-530` | |
| F-H10 | ✅ `node.go:514-539` | |
| F-H11 | ✅ 1.5.12 的輸出目錄存在;`eeprom-hooks` 在 scripts / tests 零命中 | `ls /home/yello/out/1.5.12-wsl.*` |
| F-H12 | ✅ | `testenv_provtest.go:28-30` |
| F-H13 | ⚠️ 矛盾屬實,行號錯(m1) | |
| F-H14 | ✅;另注意 `kf_classify` 只看 `FAIL` 行(m3) | `known-failures.sh` |
| F-H15 | ✅ 409 行;dead-man 是 `sleep 1500`,**種在步驟 6**(B2) | `chain1-254.sh:291` |

## 判決

**REJECT。** B1、B2 不改,P3 §8 大半(upload、update 主臂與惡意臂、settings / country-join 新卡臂、autocommit 負對照、D-9 / D-11)在這份設計下都跑不起來。改法的方向很清楚,各 BLOCKER 已附建議:用 h23 既有的 `push-helper` / `bind` / dry-run 在 committed 槽上執行;新卡 lib 涵蓋步驟 6;T 的信任編進 prov_test helper。修訂後請整份重審,不要只審差異。
