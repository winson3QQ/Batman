# #254 PR-P3 設計 v2 審查(審查者 B)

對象:`docs/design/254-p3-impl.md` v2(feat/254-p3 @ 03963d9,base main 2ecf1cb)。審的是整份,不只看 v1 → v2 的差異。
方法:對照 `feed/batman-prov/src`、`feed/batman-provision/files`、`scripts/`、協定 `219-protocol.md` / `.cddl`;在 04(1.5.14-wsl.22,Pi 4,**prov state = legacy**)上只跑唯讀命令。repo 沒改,沒有 push,GitHub 沒留言。

**判定:REJECT(範圍窄)**。0 BLOCKER、6 MAJOR、15 MINOR。
v1 的 BLOCKER(BLE 與 HTTP 共用槽)、tar 白名單、status 的 `--check`、n.mu、錯誤碼這幾項,v2 的處理方向都對,我逐條核過。
沒過的地方集中在三個介面:
- HTTP 的角色 / 何時聽 / 誰能連(M1–M3);
- 「設定寫入」繞過了現有那扇門:`halow-setkey`、keyguard、config-save 的字元集、P2 txn(M4–M6)。

D1 規定 H4 照本文件的契約先寫,所以這些契約要先定下來,再整份重審。

---

## MAJOR

### M1. HTTP 的角色契約和程式碼對不上:psk_owner 開出來的是「候選」,不是擁有者;照字面實作,擁有者在 HTTP 上永遠拿不到擁有者角色,上傳做不了
- **情境**:§3.1.2 寫「HTTP 只接受擁有者 / 成員的 PSK 交握,所以 HTTP 上的 session 角色只會是擁有者或成員;NX(匿名、擁有者候選)與 psk_replay 只走 BLE」。實際的程式碼:
  - `roleOfPSK`:index 0–3 = `RoleCandidate`、4 = `RoleMember`、5 = `RoleReacquire`(`provd/server.go:706-716`)。
  - 候選只能做 `info`、`auth/owner`(`provd/session.go:78`)。
  - 要再經 `auth/owner` 驗 ES256 簽章,才會變成 `RoleOwner` 並設定 `ownerKID`(`session.go:788-805`)。

  所以 psk_owner 本來就是「擁有者候選」;NX 是匿名(`RoleAnon`)。如果 H4 和實作照字面「拒絕候選」,擁有者在 HTTP 上永遠升不到 Owner,`X-Batman-Session` 也就不可能是「擁有者、owner_key_id = 上傳窗擁有者」的 session(§3.8.2)。D13 的上傳因此做不成,BLE 不健康時的備援也只剩成員能用。
- **修法**:§3.1.2 改寫成「HTTP 接受 psk_owner(→ 候選 → 必須 `auth/owner`)與 psk_member;不接受 NX(Anon)與 psk_replay(Reacquire)」。
  - 測試:HTTP 上 `auth/owner` 成功 → 角色是擁有者;HTTP 上 NX → 關閉。
  - 負對照:BLE-only 的 provd 在 HTTP 上 `auth/owner` 失敗。

### M2. 備援的觸發條件(`bluetoothd`、`hci0_powered`)只是 provd 廣播條件的一部分:BLE 不能用、HTTP 卻不開,擁有者兩條路都進不去
- **情境**:§3.8.1 規定 helper 只在 `bluetoothd≠1` 或 `hci0_powered≠1` 連續 5 分鐘時,才開 HTTP 備援。provd 決定要不要廣播的 `HealthOK()` 看的條件比這多(`provd/server.go:480-499`):
  - `bluetoothd=1`、`hci0_powered=1`;
  - `privacy=1`、`sc=1`、`sc_file=1`、`bondable=0`;
  - health 新鮮(`StaleAfter` 60 s);
  - `readyLocked()`。

  例如 `sc_file` 對不上(bluetoothd 重啟後 batman-sc 的 pid 不符,`health.go:153-168`)、`privacy=0`、或 bondable 被別人打開時,provd 會撤掉廣播。這時 BLE 實際上已經不能用,但這兩個欄位仍然是 1,所以 HTTP 不會開。擁有者在現場兩邊都連不進去,連「移除被偷的手機」都做不了。
  - 04 現在的 health 行:`bluetoothd=1 hci0_powered=1 adv_registered_once=1 privacy=1 sc=1 sc_file=1 bondable=0`,可見這幾個欄位彼此是獨立的。
  - 這是兩個各自正確的元件,對「BLE 不健康」各有一套定義的典型例子。
- **修法**:「BLE 不健康」只有一個定義,也只有一個擁有者。
  - 選項 (a):helper 用和 `HealthOK` 完全相同的條件(共用一個函式,或抽到 `health` 套件)。
  - 選項 (b):讓 provd 在 poll 時回報「我現在有沒有在廣播」。
  - 寫進 §5.3 契約表。
  - 負測試:讓 `sc_file` 失效(或 `bondable=1`),5 分鐘後 HTTP 要開。負對照:只看兩個欄位的版本不會開。

### M3. 上傳窗與備援開著的時候,整座 mesh 都能把 HTTP 的 2 個槽和 10 次/分 的額度耗光,擁有者的上傳 session 建不起來;「只收本 AP client」只用在 PUT
- **情境**:
  - provd bind 在 `:8095`,檢查的是 `LocalAddr ∈ br-ahwlan 位址`(§3.8.1)。br-ahwlan 就是整座 mesh(F9;04 `ip -br addr`:`br-ahwlan 10.41.1.3/16`,`bat0` 和 `phy1-ap0` 都在這座橋上;防火牆 `ahwlan` zone 是 input ACCEPT)。
  - 來源 IP 是不是本 AP client,只在 `PUT /bulk/0` 檢查(§3.8.2)。
  - mesh 上任何人都能掃 8095。一旦發現它開了,每 10 s 打 2 個假交握:
    - 假路徑(fake path)要 10 s 才結束,而且不能被擠掉(`session.go:155`);
    - HTTP 全域額度是 10 次/分;
    - 每個 IP 3 次/分,可是在橋接的 /16 上換來源 IP 很容易。

    結果擁有者手機的 `POST /session` 一直被拒。擁有者經 BLE 開了窗,卻傳不上去,15 分鐘後到期。
  - 備援模式更嚴重:BLE 已經不能用,HTTP 又被打滿,擁有者兩邊都沒有路。

  v1 B1 只修了「HTTP 影響 BLE」這一半,沒有處理「mesh 影響 HTTP」。D13 已經決定上傳只來自本 AP,這個限制在連線建立時就能套用,不需要新增機制。
- **修法**:
  - 只有上傳窗(mode bit 2 且沒有 1)時:在 accept 就檢查 `RemoteAddr ∈ 本 AP client 快取`,不是就直接關閉,不佔槽、不扣額度。
  - 備援模式:保留 1 個槽給本 AP client,另 1 個槽給 mesh。
  - AP client 快取在第一個 SYN 時可能還沒更新(每 5 s 才更新一次):「查不到 → 立刻要 helper 刷新一次」,或在 bulk.open 時先刷新。
  - 負測試:mesh 端(或另一台節點的 AP client)以 20 次/分打假交握,同時本 AP 上的擁有者完成上傳。負對照:只在 PUT 檢查的版本 FAIL。

### M4. AP 配對(key 20)繞過 `halow-setkey` 這扇門:keyguard 關掉的 AP 不會打開;字元集和 p5 對不上;不拿 `halow-setkey.lock`
- **情境**(D14 + D13 在現場的實際流程):新卡 / unseeded 的 unclaimed 開機時,helper 會把每個 `mode='ap'` 的 key 設成 `CHANGE-ME-NOW`(`cmd/batman-provhelper/main.go:459-469`)。`halow-keyguard`(S18,每次開機都跑)看到 placeholder,就 `uci set wireless.default_radio0.disabled=1`、寫 `/etc/halow-keyguard.blocked` 並 commit(`etc/init.d/halow-keyguard:21-40`)。認領和 P2 入網都不會設 AP key,所以每台剛認領的節點,手機 AP 都是關著、而且被標記的。
  1. **AP 不會開**:§3.3 的 key 20 直接 `uci batch` 寫 ssid / key,然後 `wifi reload radio0`。可是 `disabled=1` 還在,只有 `halow-setkey`(`:290-303`)或下一次開機的 keyguard(`:41-46`)會解除它。配對「成功」了,AP 卻還是關的;`bulk.open` 檢查「`default_radio0` 未 disabled」(§3.8.2),回 reason 16。結果是:**每一台新節點在重開之前,都無法經 app 更新**。
  2. **字元集對不上**:§3.3 允許 passphrase 是「12–63 個可列印 ASCII」,SSID 是「1–32 個可列印 ASCII」。但 `batman-config-save` 會拒絕含有 `` ` $ ( ) ; | & < > ' `` 的值(`UNSAFE`,`batman-config-save:53,461`):它不寫進 p5,`--save` 回 rc 6,`--check` 回 `stale … unpersistable` exit 5(`:489-490`)。`halow-setkey` 自己也寫明了這個限制(`:30`)。
     - §3.11.5 要 app 產生 ≥ 20 字的隨機密碼。從 95 個可列印字元隨機取,20 個字都不落在這 10 個字元裡的機率是 (85/95)^20 ≈ 11%,所以**約 89% 的配對會以 `E_STORAGE` 失敗**(§3.3 步驟 3 會還原,不會卡死,但使用者看到的是「儲存失敗」)。
  3. **第二個寫者**:`halow-setkey` 自稱「the one supported door」,每個寫入模式都拿 `$RUNDIR/halow-setkey.lock`,`99-batman-chanfix` 每次 reassert 也拿這把鎖(`halow-setkey:2,16-18`)。helper 用私有 savedir 寫同一份 `/etc/config/wireless`、再 `wifi reload`,卻不拿這把鎖。§4 擁有權表也沒有把 halow-setkey、chanfix、keyguard 列成 `default_radio0.*` 的寫者。另外,openmanetd 也有寫 SSID 的介面(04 `strings /usr/bin/openmanetd`:`failed to set ssid: %w`、`SettingsWireless`),同樣沒列。
- **修法**(只做必要的修改):
  - 擴充現有的門:`halow-setkey --ap <psk>` 已經存在(`:5,287`)。加 `--ap-ssid <ssid>`,並把 ssid 列入它的 PRESERVE。helper 呼叫 `halow-setkey --ap … --ap-ssid … --no-persist`,與 P2 的用法相同,這樣就沿用了它的鎖、keyguard 解除、讀回與 persist。
  - 驗證字元集 = `UNSAFE` 的補集,違反時回 reason 13(不要回 `E_STORAGE`);§3.11.5 規定 app 從安全字母表產生密碼。
  - §4 加上 keyguard、chanfix、openmanetd。
  - 負測試:新認領、AP 被 keyguard 擋下的節點,配對後 30 s 內 `hostapd.<ifname>` 出現、`bulk.open` 不回 16;密碼含 `$` → reason 13,p5 不變。

### M5. 「失敗就回到之前的狀態」只在 `--save` 失敗時成立:重新載入後 radio / AP 起不來,不會還原,而且 p5 已經存了壞值
- **情境**:§3.3 的順序是:commit → `--save` 成功 → **回應送出之後**才在背景 reload。reload 後實際狀態如何,沒有任何讀回。
  - key 2(國家)會同時改 `radio0.country`。04 的手機 AP 是 `channel='36'`、`htmode='VHT80'`(`uci show wireless`)。換到 5 GHz 規則不同的國家,hostapd 起不來或被降級。設計只驗「目前頻道在新國家合法」,而且看的是 radio1(S1G)。
  - key 20:M4 的 keyguard 狀況,或 hostapd 拒絕某個值,都會讓 AP 起不來。

  p5 已經存了新值,所以重開、甚至下一次 OTA 都會帶著壞掉的 AP。擁有者手機的 Wi-Fi 斷了,§3.11.1 的更新路徑也跟著斷。BLE 還在,可以手動改回;但這違反使用者的原則,而且是靜默失敗。
- **修法**:比照 `halow-setkey` 的 `READBACK_WAIT`。
  - 改完以後(在 helper 裡,回應之前或用 worker 都可以),等 netifd / hostapd 回報新設定已經起來(AP:`network.wireless status` 的 radio0 up,且 iface 的 ssid 相符;國家:兩個 radio 都 up)。
  - 等不到 → 寫回舊值 + `--save` + reload,回 `E_REJECTED{13}`(或新的 reason)。
  - 國家要對 radio0 目前的頻道 / htmode 也做驗證。
  - 測試:wbox 讓 hostapd 拒絕(例如注入一個非法的 htmode)→ 舊值回來、p5 沒變;負對照:沒有讀回的版本 → AP 停在關閉狀態。

### M6. 國家併進 P2 的 wireless txn 只寫了「第 4 行 + Finish 還原」;txn 的判斷式、成員的期望狀態、`halow-setkey` 的國家來源都沒涵蓋(v1 B-M6 / A-M2 只修了一半)
- **情境**:P2 txn 的決策全靠 `wantWireless{key,id,ch}`(`node/wtxn.go:165-195`):
  - `satisfied()` / `uciIs()` 只比 key / id / ch(`:209-227`);
  - 成員的 `desired` 來自 `storedNet(rec)` 回傳的 id / ch / key(`:166-171`),沒有國家;
  - `CheckRestorable`、`SetKeyNoPersist(meshKey, meshID, channel)`(`node.go:69,76`)都沒有國家參數。

  後果:
  1. 國家已經改了、`halow-setkey` 回 rc 2(什麼都沒變)時,uci 的 key / id / ch 還是舊值,`satisfied()` 回真,Finish 直接短路。國家停在新值,沒有回到之前的狀態。
  2. 成員開機時的修復(`BootFinish`)沒有「國家應該是什麼」的資料。國家被手動或 openmanetd 改掉了,不會被拉回來。
  3. `halow-setkey` 驗證頻道時用的國家,是 `uci -q get wireless.$RADIO.country` 讀出來的值(`halow-setkey:92-96`),也就是預設 savedir 的值。helper 如果先用私有 savedir(`-t`)只 set、不 commit,setkey 會拿**舊國家**驗新頻道。設計沒有定義順序。
  4. 國家沒有在 `halow-setkey.lock` 底下寫(同 M4-3)。
- **修法**,二選一:
  - **(a) 只做必要的修改**:`netJoin` 遇到 `net_config` key 5 ≠ 目前國家 → 整筆拒絕(reason 14 或 13);app 在入網前,先用 `settings/set` key 2 改國家(D9 本來就規定「單台設定只在未入網時可改」)。這樣 P2 txn 完全不用動,`.txn` 也不用加第 4 行。
  - **(b)** 如果一定要在 txn 裡改:`wantWireless` 加 country;`desired` / `satisfied` / `uciIs` / `CheckRestorable` 都要比國家;`halow-setkey` 加 `--country`,讓它在鎖裡驗證、套用、讀回;§6 列出「國家寫了、setkey 前 crash」這條路徑。
  - 負測試:在 setkey 回 rc 2 的情況下,國家要回到舊值。

---

## MINOR

1. **`phy1-ap0` 寫死了**(§3.8.2、F31)。04 的 phy 編號是 phy1(brcmfmac)/ phy2(morse),phy0 已經不存在(`ls /sys/class/ieee80211` → `phy1 phy2`),表示編號在執行期間會漂移;其他板子(3A+ / CM4)的順序也不保證。應該從 `ubus call network.wireless status` 的 `radio0.interfaces[].ifname` 取得(04 上實際回 `phy1-ap0`)。否則 `bulk.open` 會誤判 AP 關著、回 16,永遠無法更新。
2. **`update/check` 被拒時用什麼回應,兩處互相矛盾**。CDDL 的 `update-check-resp = {1: bool, ?2: reason, 3: RAM}`(`219-protocol.cddl` update-check-resp)是「ok-response 帶 false + reason」;§5.1 卻寫 `E_REJECTED{2: …}`,§10 又說 `update-check-resp` 不變。H4 要斷言哪一種?擇一,並改 CDDL / 協定。
3. **tar 的實際格式**:payload 是 `tar -czf`(gzip,`build-ab-payload.sh:73`),而且 `tar … boot …` 會產生 `boot/`、`boot/overlays/` 目錄成員。§3.7.4 步驟 2、4 寫的是「`archive/tar`」與「只收 regular file;……目錄 → reason 11」。照字面實作,每一包合法的 payload 都會被拒。要寫明:先 gzip 解壓;只允許 `boot/`、`boot/overlays/` 兩個目錄成員;key 3 是壓縮後的大小。
4. **helper 的私有暫存放錯地方**:§3.5 / §3.7 / §3.3 把 `update/`、`diag/`、`uci/` 放在 `/tmp/run/batman-prov/`。這個目錄在 04 是 `root:provd 0750`,而且以 ro 方式 bind 進 provd 的 jail(`ujail … -r /tmp/run/batman-prov`;mountinfo `119 … /tmp/run/batman-prov ro`)。只要子目錄是 0700 就讀不到,但沒有必要放在那裡。改放 helper 自己的 `RunDir=/tmp/run/batman`(root 0700,`provstore.go:339`)。
5. **`prov-state` 撞名**:p6 已經有 `/opt/batdata/state/prov-state`(04:`20320ba1-… helper legacy legacy - today`,0600,`main.go:471-473` 寫入),§3.5 又新增一個格式不同的 `/tmp/run/batman/prov-state`。同名不同格式,將來一定會有人讀錯。uhttpd 以 root 跑(04 `ps`),可以直接讀 p6 那份的第 3 欄;或者換個名字。
6. **`verdict()` 改成 `code|句子` 影響範圍比 §10 寫的大**:它同時餵給 `joinwatch status`、`diagline`(join.log / syslog / kmsg)、`halow-status` 的 `not joined: …`、`www/cgi-bin/status` 以字串比對產生的「要做什麼」(`status:22-34`),還有 `deploy/provisioning/{joinwatch,halow-status,README.md}` 的鏡像。只做必要的修改:另加一個 `verdict_code()`,讓 `halow-status json` 多一個欄位,原句子不要動。
7. **改 PRESERVE 在降級 / 再升級時會丟失 SSID**:降回舊槽之後,舊的 `--save` 會把 p5 改寫成沒有 `default_radio0.ssid`。再升到 P3 時,96 還原(`99-halow-identity` 因 `.batman-p5-restored` 而跳過,`:7`),SSID 變回 image 預設值,配對過的手機找不到 AP。另外,現有 fleet 升到 P3 之後,在第一次 `--save` 之前,`--check` 會因為新 PRESERVE 而判定 stale,擋下下一次 OTA。兩條都要寫進 §6 的降級列與升級列。
8. **`bulk-open-resp` key 2 的語意改了,文件沒跟上**:CDDL 寫的是「one-time WPA passphrase」,協定 §4.2 / `:155`、`:212` 也寫「一次性 PSK」「重新 bulk/open 會發新 PSK」。v2 回的是 AP 的永久密碼。§10 要列出這幾處的修改,§5.2 的「`bulk/open` 已開著 → 關舊的、開新的」也要改寫(它不再換 PSK)。
9. **PUT 的 body 不受 Noise 保護**:`X-Batman-Session` 是明文的 128-bit bearer token(`219-protocol.md:157`)。同一台 AP 上其他知道 PSK 的 client 可以解出 WPA2-PSK 流量,拿到 token,從自己的 IP(也是本 AP client)搶先 PUT 垃圾內容,使上傳失敗。內容完整性靠簽章,不會被寫進槽,所以只是 DoS。§7 要照實寫;PUT 的 IP 要和建立 session 的來源 IP 綁在一起。
10. **write 與 arm 拆開之後的兩個細節**:
    - (a) `begin_write`(所有寫者都會經過,包括 sysupgrade 的 stage-root / apply)要先刪除 `BATMAN-VERIFIED`。否則別的寫者覆寫槽之後,舊的 VERIFIED 會讓 app 的 `arm <sha>` 去 arm 一個內容不同的槽。
    - (b) phase 3 只存在 worker 的記憶體裡。helper 重啟後,`update.apply` 會回 15,必須重傳 126 MB;寫明這一點,或者用 pending + `BATMAN-VERIFIED` 重建 phase 3。
11. **key 8 應該檢查目標槽的開機設定,不是「本機 p1」**:payload 不帶 `config.txt`(`build-ab-payload.sh:17-18`),apply 也跳過它(`batman-slot:697`)。04 的 `autoboot.txt` 是 `[all] boot_partition=1` / `[tryboot] boot_partition=2`,韌體讀的是被選中那個分割上的 config.txt。所以 trial 用的是**目標槽**的 config.txt。目前的 slot 是 B 時,p1 正好是目標;是 A 時就不是。
12. **legacy 認領(`RadioManaged=false`,「保留操作員的 radio」,`node.go:539`)**:§3.3 的國家 / AP 寫入沒有說是否尊重這個旗標。04 現在就是 legacy。要寫明:legacy 是否拒絕(`E_UNSUPPORTED`),或是操作員同意讓出。
13. **§7 缺「實體奪取」這個行為者**:D14 把 AP 密碼存在 p5(以前 key 就已經在 p5,現在再加 SSID)。p5 沒有加密,撿到卡的人就能進 AP → br-ahwlan → 整座 mesh 的 LAN(ahwlan input ACCEPT)。這是使用者的決定,我不推翻;但要寫進資產 / 誠實界線,而且這與「秘密不進 p5」的通用規則衝突,要明確標為例外。另外,openmanetd 還有 `PerformFactoryReset`(04 strings),也是未簽章的狀態變更路徑,要和 local upgrade 一起列入 §1.2 / §11。
14. **上傳窗關閉與「同一個 HTTP session 接著做 prepare」互相矛盾**:§3.8.2 寫上傳完成後 helper 關窗、provd 停止監聽,§3.8.2 / §5.2 卻又說 prepare / status 可以走同一個 HTTP session。要定義:窗關了以後,已建立的 session 是不是保留到 worker 結束。也要定義 upload 的 `ReadTimeout` / 最低速率,不然慢速 client 可以長期佔住槽。
15. **小的契約缺口**:
    - poll 的 `http` 欄位沒有 pending 的 key 3(provd 要拿它比 `Content-Length`);
    - 版本字串裡的 `.wbox-` 後綴(`batman-autocommit:492`)這套文法解析不了,要寫明「解析失敗 → 拒絕(reason 11 或 6)」;
    - update-last 在「寫完、2 s 內重開之前 helper 就掛了」的情況(目前版本 = from、boot_id = apply_boot_id)沒有定義,下一次斷電重開會意外進入 trial;
    - `batman-slot` 改成「只複製列出的 boot 檔」會改到出貨中的 sysupgrade 路徑,§8 要有一個 sysupgrade 臂的負對照(沒列出的 dtb 不會被寫進槽)。

---

## §12 的宣稱,我逐條核過的結果
- **A-B1 / B-B1**:槽 / 額度 / 撤廣播分開,這一半成立。「mesh 打 HTTP」的另一半沒處理 → M3。
- **A-B2 / B-M2**:白名單 + 先驗 SHA256SUMS + 只複製列出的檔,方向對。`batman-slot` 的 precheck 本來就會驗列出的 boot 檔(`:607-610`),apply 會複製未列出的檔(`:676-681`),這兩點都屬實。格式細節 → m3、m10、m15。
- **A-M1 / B-M7**:改成背景快取,`--check` 至多每 120 s 一次。成立。
- **A-M2 / B-M6**:只修了一半 → M6。
- **B-M1**:helper 新碼 24 / 25 + reason,只用協定既有的線上碼。成立(CDDL 的 error-detail 本來就有 `2 => reason-code`)。
- **B-M3**:專屬 tmpfs 加 size、清理表。成立。04 上 provd 的 jail 根目錄是 `tmpfs rw mode=755`,屬 root,provd 寫不進去,不構成另一條寫 RAM 的路。
- **B-M4**:LocalAddr 允許清單成立,但它擋不住 mesh(M3)。
- **B-M5 / A-M4**:暫時 AP 拿掉以後,改成 key 20 → M4 / M5 的新問題。
- **B-M8**:改非同步、`otaBusy` 擴大,成立(要補 m10-b、m15)。
- **B-M10**:D12 的規則與 bench 臂成立。
- **B-m3**:F33 屬實(`/tmp/run` `drwxr-xr-x root`)。
- **B-m8**:psk_replay 只走 BLE,成立;但 M1 的措辭把候選也排除了。
- **F 欄位,我在 04 / 原始碼上實際對過**:F9、F11(另外:jail 裡沒有 /proc / /sys,所以 provd 自己查不到介面位址,由 helper 給清單是對的)、F26、F27、F28、F31、F33、F34、F35、F38、F39。平台列:Pi 3 依 2026-10-23 的決定只是殘項,接受。

## 我確認沒有問題的地方
- `platform-ab.sh` 的 sysupgrade 路徑是**依名字**取成員,讀了兩遍(`:328` 用 `-X` 排除;`:368` 用 `-xOf root.squashfs`),所以和 tar 的順序無關。§9-3 的 ⚠️ 可以關。
- `uci -t <path>`(set save path)在 04 的 uci 上存在。
- br-ots 的 zone 是 `input='DROP'`,所以 OTS 容器連不到 8095;docker0 是 ACCEPT,但目前是 DOWN。
- 擁有者 PSK 是每人一把(`realPSK`:`inSet(p.owners, v)`)。`owner/remove` 之後依 PSK 值 reconcile,可以切斷 HTTP session。
- provd 的 poll 每 4 s 一次(`server.go:20`),所以 HTTP 開關最多延遲約 4 s。

## 判定
**REJECT(範圍窄)**:M1–M6 改完之後整份重審。§3.2、§3.4、§3.5(撇開 m4 / m5)、§3.6、§3.7.1–3.7.3、§3.9、§3.10 我核過,沒有阻擋性問題。
