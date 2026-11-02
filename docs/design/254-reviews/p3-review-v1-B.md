# #254 PR-P3 設計 v1 審查(審查者 B)

對象:`docs/design/254-p3-impl.md`(feat/254-p3 @ 96a578d,base main 2ecf1cb)。審整份,不是只審增量。
方法:對照 `feed/batman-prov/src`、`feed/batman-provision/files`、`scripts/`、協定 `219-protocol.md` / `.cddl`;04(1.5.14-wsl.22,Pi 4)上只跑唯讀命令(ssh 輸出節錄在各條)。repo 沒改、沒 push、GitHub 沒留言。

**判定:REJECT**(1 BLOCKER、10 MAJOR、16 MINOR)。HTTP 通道和更新管線這兩塊要重寫再整份重審。路由、owner 測試、diag 分頁、autocommit 新鮮度、轉賣工具這幾塊方向對,改的量小。

---

## BLOCKER

### B1. 常駐的 HTTP 通道和 BLE 共用 2 個 session 槽與全域 20 次/分交握額度:mesh 上任何人都能把 BLE 管理通道鎖死
- **情境**:`ahwlan:8095` 一直開著(§3.8.2)。F9 說了 ahwlan 是整座 mesh,再加上每台節點手機 AP 上的每支手機。攻擊者每 10 秒送 2 個隨便的 PSK 交握第 1 則。PSK 全部對不上時,節點依協定 §3.4 走假路徑,**要等到 10 秒逾時才斷**。provd 的實作是:
  - `Slots = 2 // BLE + sock together`(`provd/server.go:34`);
  - 第三條連線只能擠掉「可擠掉」的 session。`evictable()` 對 `ss.handshake || ss.fake` 回 false(`provd/session.go:155`,「mid-handshake (incl. the fake path's 10 s) is never evicted」);
  - 擠不掉就 `connection refused (%d slots in use)`(`server.go:747-756`);
  - 全域額度是 `HandshakesMin = 20`/分(`server.go:35`、`:645-660`)。

  所以每分鐘 12 次假交握,就能讓旁邊的擁有者 BLE 連線永遠被拒。連擁有者「移除一台被入侵成員」的操作都做不了。設計 §7 把「共用全域交握 20/分」當成防線,其實它正是攻擊手段。合法使用也會撞到:兩支成員 app 經 HTTP 輪詢 `status`(已認證 session 閒置 300 s,`server.go:31`),2 個槽就滿了,BLE 進不來。
- **證據**:上面幾處 file:line;協定 §8「同時 BLE 連線 2」「全域交握每分鐘 20 次」;§3.4 假路徑要等逾時。
- **修法**:
  - HTTP 自己一個 session 池(例如 1 槽)和自己的交握額度,另加每個來源 IP 的額度。BLE 的 2 槽和 20/分保留給 BLE,HTTP 永遠吃不到;
  - HTTP 假路徑的 session 可以佔 HTTP 自己的槽,但不能佔 BLE 的;
  - 或者照「只做必要的修改」:ahwlan 監聽平常不開,只在擁有者 owner-op 開窗時才開(像 bulk 一樣有期限)。D6 是使用者的決策,要改得先問;
  - 負測試:mesh 端用腳本每 5 s 打 2 個假交握,同時 BLE 擁有者 `auth/owner` 要成功。拿 P3 前的共用池設計當負對照,它必須失敗。

---

## MAJOR

### M1. 錯誤碼契約對不上協定和 provd:`E_STATE`、`E_SCHEMA` 在協定裡不存在;helper 的 schema 錯會被記成「provd bug」
- **情境**:§3.3、§3.5、§3.7.3、§3.8.1、§5 很多地方回 `E_STATE` / `E_SCHEMA`(例如未入網才能改國家、名稱格式錯、同時帶 key 1 和 2、沒有 pending、handle 過期)。
  - 協定 §5.2 的碼表只有 1–13,**沒有 E_STATE、也沒有 E_SCHEMA**(`219-protocol.md:174-189`)。
  - provd 的 `mapHelper` 把 `hEState` 對成 `ERejected`,把 `hESchema` 對成 `ERejected`,同時 `logf("CRIT provd: the helper rejected a request schema (%s) — a provd bug")`(`provd/session.go:565-579`)。也就是說,使用者打錯名字會產生 CRIT log。
  - `hEUnsupported` 一律回 `{1: typ}`(`:569-570`),做不出設計要的 `E_UNSUPPORTED{capability: "status.team"}` 或 `{capability}`。
- **修法**:§5 補一張「每個動詞 × 每種拒絕 → 線上碼 + detail」的表,只用協定既有的碼(例如輸入不合法用 `E_UNSUPPORTED` + reason,狀態不對用 `E_REJECTED` + reason;或者正式在協定 / CDDL / `mapHelper` 加碼)。使用者輸入的驗證放在 helper,用一個不會觸發 CRIT 的 helper code。H4 斷言的是線上碼,所以這張表要在 H4 動工之前定下來(D1)。

### M2. 不受信任的 payload:helper 以 root 身分、完整 tar 語意解開 provd 給的檔;簽章清單以外的開機檔會被寫進目標槽
- **情境**:被入侵的 provd 是 §7 列出的行為者。§3.7.4 步驟 2「解出除 root.squashfs 以外的成員(同 `platform-ab.sh:325-329`)」,用的是 `tar -xf - -C "$dir" -X "$ex"`(`platform-ab.sh:328`)。這在**驗章之前**,以 root 解一個由 provd 控制的 tar,具備完整的 symlink / hardlink / `..` 語意。原本的 sysupgrade 路徑是 root 操作員給的檔,可以信任;這裡不行。
  - 更直接的問題:`batman-slot` 的 precheck 只驗 SHA256SUMS **列出的** boot 檔(`batman-slot` precheck 的 `for f in $(awk '$2 ~ /^boot\//…' SHA256SUMS)`)。可是 `cmd_apply` 會把目錄裡**所有**的 `boot/kernel8.img start*.elf fixup*.dat *.dtb` 和 `boot/overlays/*` 都 `cp` 到目標 boot FAT(`batman-slot` cmd_apply 的 `for f in "$PAYLOAD"/boot/kernel8.img "$PAYLOAD"/boot/start*.elf …`、`cp -f "$PAYLOAD/boot/overlays/"*`)。讀回驗證也只看列出的檔。
  - 結果:provd 可以在 tar 裡多塞一個沒列出的 `*.dtb` / `overlays/*.dtbo` / `start4x.elf`。簽章和讀回都過,檔案卻寫進要 trial 的槽。例如 payload 沒帶 CM4 的 dtb,攻擊者補一個。§3.7.4 步驟 6 寫「payload 在 dd 前後被改都會讓讀回失敗」,對沒列出的成員不成立。
  - 解出的成員大小沒有上限,一個灌水的 `boot/x` 就能在驗章前塞滿 `/tmp`。
- **修法**:
  - 先用 `tar -xOf payload SHA256SUMS`、`tar -xOf payload metadata` 抽到 stdout(不在檔案系統上建任何東西),SHA256SUMS 驗過簽章之後才繼續;
  - 只對 SHA256SUMS 列出的路徑(字元集 `[A-Za-z0-9._/-]`、不能有 `..`、不能以 `/` 開頭)用 `-O` 抽出,寫進 helper 自己 `O_EXCL` 建的檔,每個檔有大小上限(release payload 簽一個 boot 總大小);
  - tar 裡有沒列出的成員就整包拒絕;
  - 新的 `batman-slot write` 只複製 SHA256SUMS 列出的檔(sysupgrade 路徑也一起改最安全)。
  - 負測試:多一個沒列出的 dtb → 拒絕;tar 裡有 `boot -> /etc` 的 symlink → 拒絕,而且 `/etc` 沒被改到。

### M3. payload 和 RAM 的生命週期沒定;被入侵的 provd 多了一個可以寫 RAM 的地方
- **情境**:
  1. 116 MiB 的上傳檔和解出的目錄,在 prepare 成功、prepare 失敗(reason 11)、helper crash、provd crash、bulk 逾時、使用者放棄時,**由誰刪**,設計沒寫。`/tmp` 是 RAM(04:`tmpfs on /tmp`,沒有 swap)。留下一份 116 MiB,在 3A+ / 1 GB CM4 上下一次更新就塞不下了,而且直到重開之前都在吃 RAM(OTS、mesh 也在用)。
  2. RAM 預算「/tmp 可用 − 32 MiB ≥ payload 大小」漏了解出的 boot 成員。sysupgrade 路徑自己算的是 tar 清單 + 16 MiB(`platform-ab.sh:189-193`)。
  3. 今天 provd 在 jail 裡的掛載全是唯讀(`files/batman-provd.init:18`,`procd_add_jail_mount`)。P3 給它一個 rw 的 `/tmp/run/batman-provd-bulk`。被入侵的 provd 可以無上限地寫 RAM,把整台 OOM 掉,影響從「供裝壞了」擴大到「整台節點和整隊通訊」。
- **修法**:
  - 上傳目錄用專屬的 tmpfs(`size=` 上限 = 最大 payload + 一點餘裕,provd:provd 0700);helper 直接讀它,不 rename,避免跨掛載點的 EXDEV;
  - 加一張「每個結束路徑誰刪什麼」的表:helper 啟動時清 update/、diag/,bulk 關閉時清上傳目錄;
  - 預算把簽章裡的 boot 總大小算進去;
  - 負測試:provd 身分寫超過上限 → ENOSPC,節點其他服務不受影響;helper kill 之後重啟,`/tmp` 回到原本的用量。

### M4. HTTP 監聽位址沒有契約:ahwlan IP 會變、bulk IP 晚到、jail 沒有 netns
- **情境**:§3.8.2 說監聽 `10.41.x.x:8095`。
  - 這個 IP 是 openmanetd 兩段式定址給的,改名後會重保留 / 重開(D15、U5)。
  - `192.168.250.1` 要等 `wifi reload` / 介面起來才有。
  - provd(uid 471,和主機共用網路,F11)怎麼知道現在的位址、什麼時候重綁、位址消失時怎麼辦,都沒寫。
  - 綁 0.0.0.0 會把 docker0 `172.17.0.1`、br-ots `172.20.0.1`、eth0 一起曝露(04 `ip -br addr`)。
  - provd 在 bulk 開著時重啟,不知道要再聽 bulk。
  - app 從哪裡得知 HTTP 端點(IP 還是 `.local`)也沒有定義。
- **修法**:
  - 綁 `:8095` 萬用位址,每條連線接受前檢查 `LocalAddr` 是否在 helper 給的允許清單(br-ahwlan 現在的位址、bulk 位址),清單由 ctl 輪詢更新;
  - 防火牆把 8095 限定在 ahwlan / bulk zone;
  - 在 §5 契約表加這一列,§6 加「改名 / 換 IP」「provd 在 bulk 開著時重啟」兩條生命週期。

### M5. bulk 開關的動作不完整,對 mesh 的影響沒證據;openmanetd 是漏掉的寫者;「回到之前的狀態」少記一個值
- **情境**:
  1. 新增 `network.bulk`、`dhcp.bulk` 之後,只做 `wifi reload` 加 `firewall reload`,介面起不來、dnsmasq 也不會發位址(還要 `ifup bulk` 或 `network reload`、`dnsmasq reload`)。這些 reload 對 br-ahwlan / bat0 / morse 的影響範圍,沒有任何實測。D5 的「mesh 不受影響」是決策,不是證據。
  2. openmanetd 也會寫:`strings /usr/bin/openmanetd`(04)有 `uci set system.@system[0].hostname='%s' && uci commit system`、`Setting DHCP config`、`/etc/init.d/network`。§4 擁有權表沒列它(hostname 也被它寫,所以和 `settings.set` 是兩個寫者)。
  3. `bulk.close` / `batman-bulk-clean`「恢復 `default_radio0.disabled`」:如果操作員原本就關了手機 AP,斷電之後 bulk-clean 不知道原本的值。這違反「失敗就回到之前的狀態」。
  4. `default_radio0` 這個 section 名稱寫死了。
- **修法**:
  - 把完整的動作序列寫出來;核准之前先在 bench 上量一次:bulk 開關期間 morse plink 和 batman 鄰居有沒有斷、斷多久;
  - 開 bulk 之前把原本的 `disabled` 值記在 helper 的 run 檔(和 bulk 一樣在開機時處理);
  - §4 加 openmanetd 的列,寫清楚它什麼時候改 hostname / dhcp / network,會不會刪掉別人的 section。

### M6. 「國家跟 net_config」P2 根本沒實作;txn 快照沒有國家,失敗回不去
- **情境**:§3.3 寫「⚠️ P2 的 netJoin 是否已寫 country,實作時查」。我查了:整個 `feed/batman-prov/src`(vendor 以外)沒有任何 `country`(grep 結果是零行)。所以 D9 是全新的行為。
  - `.txn` 的快照格式只有 `prev <mesh key> <mesh id> <channel>`(`provstore/txn.go:16`),`Finish` 也只把 mesh 的 key / id / channel 還原(`node/wtxn.go:162-192`)。
  - 照設計在 `halow-setkey` 之前 `uci set …country`,入網失敗時國家會留在新值,違反「失敗就回到之前的狀態」。radio0 的國家也一樣。
- **修法**:§3.3 寫清楚 txn 快照的新格式(radio1 / radio0 的 country)、`Finish` 的還原、讀回比對;寫清楚舊版 helper 遇到新 `.txn` 會怎樣(overlay 每槽各一份,寫明理由)。測試:join 時讓 setkey 失敗 → country 回到舊值。

### M7. `status` 的 `p5_saved` 每次呼叫都跑一次 `batman-config-save --check`,成員輪詢就能擋住 p5 存檔和 OTA
- **情境**:成員可以呼叫 `status`(§3.1),走唯讀額度,helper 全域 10/s(`node/readonly.go:23`)。
  - `--check` 會拿 `cfgsave.lock`(最多等 5 s,`batman-config-save:244`)並掛載 p5。
  - `--on-join` 是 `wait=0`:拿不到鎖就跳過這一輪,連續 8 次就寫 `cfgsave-lock.busy`(`:244-258`)。
  - `batman-slot` 的 node_checks 看到 `cfgsave-lock.busy` 就拒絕 OTA(`batman-slot:510-512`)。
  - 04 實測(Pi 4):`--check` 0.56 s、`halow-status json` 0.34 s;3A+ 會更慢。

  幾支成員 app 經 HTTP 輪詢(M4 / B1 也會放大這件事),就能讓 p5 一直不跟著 live、OTA 被擋、寫入者等 10 s 後回 `E_STORAGE`。設計 §3.4 只標 ⚠️「實作時確認」。
- **修法**:`p5_saved` 用快取值(例如 `--on-join` 最近一次的結果檔,或 helper 每 60 s 最多算一次),請求路徑上絕不 spawn `--check`;`status` 對成員另設一個較低的額度。負測試:10/s 的 status 打 10 分鐘,`cfgsave-lock.busy` 不出現、`--on-join` 照常。

### M8. 長動詞和 helper 的 `n.mu`:prepare 期間 nonce / sign / psks 都被卡住;同步還是非同步沒定
- **情境**:非唯讀動詞用的是**阻塞的** `n.mu.Lock()`(`node/node.go:189`)。
  - `update.prepare` 要 dd 加讀回約 116 MiB,`bulk.open` 要做好幾個 reload。設計沒說它們是在鎖裡同步跑,還是在背景跑。如果同步,這段時間 `nonce`(op/nonce)、`sign.peer`、`psks.get` 全部排隊,provd 等 ctl / ops 會逾時。結果是 BLE 斷線後重連、別的擁有者的 owner-op 都失敗。
  - §3.1.4 寫「sign.peer … net.apply 期間回 E_BUSY」:實際上是阻塞,不是 E_BUSY。
  - ops 一次只有一個在飛,HelperWait 330 s(`provd/server.go:22`):3A+ 的寫入時間有沒有落在這裡面,沒有估算。
  - CDDL 有 `update-phase` 2 verifying,看起來預期是非同步,但設計沒寫。
  - `otaBusy()` 只擋 `net.apply` / `network.leave`(`node.go:213-217`)。prepare 期間 `settings.set`(國家要 wifi reload + save)和 `bulk.*` 不會被擋。
- **修法**:prepare 在 helper 的背景 worker 跑,不拿 `n.mu`,透過 `batman-slot` 的鎖和 BUSY 標記互斥。動詞本身立刻回 phase 2,進度由 `update.status` 回報。`otaBusy` 擴大到 `settings.set` 和 `bulk.*`。§4 那個「鎖名實作時查」:就是 `$RUNDIR/batman-slot.lock`(`batman-slot:82-95`),和 sysupgrade stage 2 共用同一把。

### M9. 改名的核心行為(U5)還沒探就放進設計
- **情境**:改名之後 IP 會不會變、openmanetd 會不會重開、`.local` 要多久才解析得到,都是 ⚠️。這也直接影響 M4 的監聽位址、§6 的生命週期、H4 的斷言。依使用者規則「先 reality check,前提沒證據不寫進設計」,而且 D8 還在等使用者回覆。
- **修法**:二選一。(a) U5 在本設計核准前跑完,結果寫回 §3.3、§6;(b) 把改名移出 P3,寫成 #254 checklist 的殘項(只保留 `settings.get` 和國家)。

### M10. 正式鑰匙路徑從來沒在出貨產物上驗過;「channel 不同 → 拒絕」讓現有 fleet 永遠升不到正式版
- **情境**:
  - `docs/VERSIONS.md:9-15`:版號是 `<M.m.p>-<channel>.<build>+…`,channel 有 `wsl` / `ci` / `rel`,**正式版不帶後綴**。依 §3.7.1「channel 不同 → 不可比,拒絕」,現在全是 `-wsl.N` 的節點(04:`1.5.14-wsl.22+2ecf1cb.fwce20a68`)永遠不能經 app 升到 rel,ci 和 rel 之間也不行。
  - 另外,只有 prov_test image 信任 T,rc / wsl build 沒有簽章(§3.7.6)。release image 信任的 R → K(YubiKey)→ 驗章這條鏈,在 H4 和全套裡沒有任何一項會跑到,第一次真正被用是在現場。這違反「出貨產物 ≠ 驗證產物時要重驗」。
- **修法**:
  - 把 channel 規則明確寫出來(例如允許 wsl → ci → rel 往上、不准往下),連同 `+` 之後的 build metadata 要忽略;
  - 加一項 bench 測試:用 YubiKey 的 K(R 背書)簽一個 rc,在 release 設定的節點上走 app 路徑升級,外加負對照(T 簽的 → 拒絕)。

---

## MINOR

1. **bulk SSID 洩漏識別**:`Batman-<sn 末 4>-u` 讓已認領節點廣播一個穩定的識別碼。協定 §4.1 規定已認領 / 成員的廣播不帶任何識別。改成隨機 SSID,經 Noise 回給 app。
2. **bulk passphrase 不只在 Noise 裡**:它會寫進 `/etc/config/wireless`(04:`-rw-r--r--`,在 overlay = flash 上)和 `/tmp/run/hostapd-phy1.conf`(04:`-rw-r--r--`,裡面有 `wpa_passphrase`)。§7「只在 Noise 回應裡」要改成照實寫,並說明為什麼可以接受(一次性、15 分鐘)。04 上有非 root 程序:dnsmasq、logd、network、nobody、ntp、ubus。
3. **`/tmp/run` 不是 root-only**:04 `drwxr-xr-x root root /tmp/run`。§7 最後一列的前提寫錯了。實際上只有 root 能在裡面建項目,所以結論還成立,但要改寫,並規定 init 建目錄時檢查 owner、不是 symlink。
4. **bulk 防火牆規則**:8095 的規則要加 `dest_ip 192.168.250.1`,否則連到 bulk AP 的人也打得到 ahwlan 的監聽位址(input 是依進來的 zone 判斷的)。
5. **重試語意**:冪等快取不做可以接受,但要逐動詞寫出重送會怎樣:`bulk/open` 在開著時再送(協定 §4.2 說要關掉舊的、發新 PSK)、prepare 成功後再送、`owner/remove` 第二次回 `E_FORBIDDEN`(app 要當成功)。HTTP 在切 Wi-Fi 時特別容易掉回應。
6. **`update-pending` 的生命週期互相矛盾**:「`--boot` 看到結果就刪」和「要回報 5 / 6」衝突(commit 是 autocommit 稍後才做的)。pending 要綁目標槽和版本;降級或重燒卡後留下的 pending 要怎麼判斷是舊的。
7. **`diag.read` handle**:helper 不知道 provd 的 session 什麼時候結束;「新的取代舊的」會讓第二位擁有者把第一位下載到一半的 bundle 砍掉。要定義清楚。
8. **psk_replay 能不能走 HTTP 沒說**(`claim/replay` 會回 root_password)。建議和 NX 一樣只走 BLE。
9. **§10 漏了檔案**:`deploy/provisioning/www/bundle` 鏡像和 `scripts/check-provisioning-sync.sh:34` 的同步檢查;`halow-status` 文字輸出裡也有 `report bundle: /cgi-bin/bundle`(`halow-status:183`)。新路徑的 tmp-trust allowlist 要照 #290 走 harness PR。CGI 怎麼讀 `info.state`(沒有現成的 shell 可讀來源)也沒定義。
10. **誠實界線少列了未簽章的更新路徑**:除了 ssh sysupgrade,還有 LuCI 刷韌體,以及 openmanetd 自己的升級功能(strings 有 `start local upgrade`、`staged-firmware.bin`;它在 `:::8080/8081/8087` 監聽,整座 mesh 都連得到)。都需要管理密碼,但要列出來。
11. **§3.10 的證據引用錯了**:「F22」應該是 F23。「`firstboot -r -y` 之後由 96 從 p5 還原、擁有者還在」沒有證據,要補一項測試。
12. **prepare 之後沒 apply,舊的回滾槽就沒了**:在「失敗回到之前的狀態」底下寫明這條界線。隔很久才 arm 的話,只重驗 `BATMAN-VERIFIED`,不重讀 rootfs。
13. **「write = 現在的 apply 到 `:714`」不準確**:串流 rootfs 的路徑其實是 stage-root + 呼叫端串流 + apply(`platform-ab.sh:364-377`)。串流時 `SQ_BYTES` 來自**沒簽章**的 `metadata size=`(batman-slot precheck)。讀回驗證會讓它 fail-closed,但要寫清楚。
14. **`update.check` 不需要 owner-op,每次呼叫都寫 p6**:要有額度,或者內容相同時不重寫。
15. **manifest 和 release payload 的 key 編號不一樣**:CDDL 是 3 = size、4 = sha(`219-protocol.cddl` update-manifest),release payload 是 3 = sha、4 = size。所以「key 1–4、6 必須相同」要改成一張對照表。CDDL 的 key 5 是 `bstr`,不是陣列;key 6 的語意被反過來了,舊版本要事後重簽,這個流程要寫出來。
16. **行為者少了一種**:遺失 / 被偷的手機。有了 HTTP,PSK 從「要在 BLE 範圍內」變成「在 mesh 上任何地方都能用」。§7 加這一列,寫明 remove 之後的時效。另外,量產平台已改成 CM4(2026-10-23 決定),§6 的平台列只有 Pi 4 / bcm2710,CM4(eMMC、無線變體)的列至少要標「不適用 / 待做」並寫理由。

---

## 我確認過、沒有問題的地方
- P2 的 wireless txn 只快照 mesh 的 key / id / channel(`provstore/txn.go:16`),不會把 bulk 段帶回來(這個疑慮可以排除)。
- 04 上的 `/tmp/.uci/*` 全部是 0 bytes,現在沒有被別人暫存、會被一起 commit 的改動。
- health 行本來就有 `boot_id=` 和 `ts=`(uptime),每 15 s 寫一次(`health/health.go:196`、`Run`)。§3.7.5 的 60 s 新鮮度做得到。
- `cose.VerifySign1(item, contentType, label, pubs)` 本來就支援 content type 和 external_aad 標籤(`cose/cose.go:36-70`),只做 ES256 和 low-s。YubiKey PIV 回的是 DER 簽章,要轉成 64 B 的 r‖s,§3.7.2 要寫一句。
- 8095 在 04 上沒被佔用(netstat 只有 22、53、80、443、2947、8080、8081、8087)。

## 判定
**REJECT**:B1 和 M1–M10 改完之後,整份重審。
