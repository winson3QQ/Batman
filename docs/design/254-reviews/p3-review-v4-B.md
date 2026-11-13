# #254 PR-P3 設計 v4 審查(審查者 B)

對象:`docs/design/254-p3-impl.md` v4(feat/254-p3 @ 5d5ebfd,base main 2ecf1cb)。審整份,不只 v3 → v4 差異;§12–§14 的「已處理」逐條對源碼 / 04 核對。
方法:讀 `feed/batman-prov/src`、`feed/batman-provision/files`、firmware-2710 的 kernel / netfilter 打包;04(1.5.14-wsl.22,Pi 4,legacy)只跑唯讀指令(`uci show/get`、`nft list tables`、`cat`/`sed` 系統檔、`/proc`)。沒有寫任何檔、沒 uci set、沒重啟、沒載模組。repo 未改、未 push、GitHub 未留言。

**判定:REJECT(範圍很窄,已接近收斂)。0 BLOCKER、2 MAJOR、11 MINOR。**
依使用者規則「有 MAJOR 未關就改設計、整份再審」,所以不能給 APPROVE-WITH-CHANGES。不過兩個 MAJOR 都是局部修正(各幾行),不需要新的子系統。v3 的 M1–M5 方向都正確,逐條核過(文末 ✅)。
- **M1**:D19 的 nft bridge 表沒有指名載入者;`fw4 flush`(= `/etc/init.d/firewall stop`)會刪掉它,成了第二個寫者。表不在時 8095 對整個 mesh 開放,這是 fail-open,但 §5.3 寫的是 fail-closed。
- **M2**:B3-m6 的修法(「p5 沒有、live = `/rom` 預設 → fresh」)在真機上不成立:`/rom/etc/config/wireless` 不存在,SSID 也是由 hostname 推出來的。結果升到 P3 後,未入網的節點 `--check` 一直是 stale,app 更新和 ssh sysupgrade 都被擋。§6 還留著 v3 的另一套機制,兩處互相矛盾。

---

## MAJOR

### M1. nft bridge 表 `batman_http` 的擁有權 / 生命週期沒寫:載入者未指名,`fw4 flush` 會刪掉它;表不在 = 8095 對整個 mesh 開放(fail-open),跟 §5.3「空 → 全丟(fail-closed)」不符
- **事實**:
  - 04 `/etc/init.d/firewall`:`stop_service() { fw4 flush }`。04 `/sbin/fw4` 的 `flush()` 會 `nft list tables | while …; nft delete table "$family" "$table"`,也就是刪掉**所有**表,包括 bridge 表。`fw4 restart` / `reload` 只重建 `inet fw4`(`ruleset.uc`:`table inet fw4` / `flush table inet fw4`),不會把別的表建回來。
  - `ahwlan` zone 的 input 是 ACCEPT(F9),所以 fw4 本身不擋 mesh 進 8095;bridge 表是唯一的門。
  - §4 只寫「表:image(開機載入)」,沒說是誰載(init script?fw4 include?),也沒說不在時怎麼辦。§5.3 只定義了「set 空」。
  - 04 現在只有 `ip filter / ip nat / ip6 * / inet fw4`(`nft list tables`),bridge family 從沒被用過;04 kernel `CONFIG_NF_TABLES_BRIDGE=m`、`CONFIG_NFT_BRIDGE_META/REJECT` 是 not set;firmware `.config` 是 `# CONFIG_PACKAGE_kmod-nft-bridge is not set`(§9-8 已標 ⚠️)。
- **情境**:操作員除錯時跑 `service firewall stop; service firewall start`(或某次 build 的 kmod / 規則語法錯,開機載入失敗)→ 表消失、沒有任何訊號。之後 BLE 不健康 5 分鐘 → provd 開備援 → mesh 上任何主機又能耗光 2 個 HTTP 槽和 10 次交握/分。B3-M1 / A2-M5 的原情境回來了,而且是靜默的。
- **修法**(小):
  1. 載入者指名為 **fw4**:用 `/usr/share/nftables.d/ruleset-post/` 的 include。每次 fw4 start / reload 都會把表重建回來;include 不寫 set 的元素,元素的唯一寫者仍是 helper(下一個 5 s 週期補上,這段期間 set 是空的,fail-closed)。§4 改成:表 = fw4(include);set 元素 = helper;`fw4 flush` = 操作員動作,寫進擁有權表。
  2. **helper 每次刷新 `@ap_ports` 時,用 `nft -j list table bridge batman_http` 確認表 + 鏈 + 規則都在**。不在 → poll 回覆**不給 `http.2`**。provd 沒有 `http.2` 就關掉 listener、不 bind(備援也一樣,因為備援的位址本來就從 `http.2` 來,§3.8.1)。這樣「表不在」也是 fail-closed。§5.3 新增一列。
  3. §6 依賴重啟加一列「firewall stop / start / reload」。
- **負測試**:備援開著時 `nft delete table bridge batman_http` → 一個 poll 週期內 provd 不再 listen,mesh 主機連 8095 被拒;`fw4 reload` 後表回來、set 在 5 s 內補回。負對照 = v4 的寫法:表刪掉後 mesh 主機可以完成 TCP 握手。

### M2. 新 PRESERVE key 的升級處理(B3-m6 的修法)在真機上不成立 → 升到 P3 後,未入網的節點 p5 一直 stale,app 更新(主路徑)和 ssh sysupgrade 都被擋;§3.3 和 §6 寫了兩套不同的機制
- **事實**:
  - `--check` 拿整份 `overrides.uci` 逐 byte 比(`batman-config-save:440-494`:`stage_overrides` + `p5_matches` 的 `cmp -s`)。只要有一個非空的 PRESERVE key 不在 p5 → stale(rc 5)。
  - 04:`/rom/etc/config/` 裡**沒有** `wireless`(`ls: /rom/etc/config/wireless: No such file`,也沒有 `system`)→「live 值 = `/rom` 預設」這個條件沒有東西可以比。
  - SSID 不是 image 預設值:新卡上 `99-halow-identity:19-21` 把它設成 hostname;A/B 換槽時又跳過不設(`:7`,p5 restored)。04 `default_radio0.ssid='BCM2711-6c89'` = hostname。
  - 會自動 `--save` 的只有 joinwatch 的 `--on-join`(`joinwatch:150`,只在 JOINED 時)和 setkey(`halow-setkey:165`)。
  - stale 時 `batman-slot` 拒絕 OTA(`batman-slot:446-514`),sysupgrade 的 stage 1 也一樣。
  - 協定沒有「p5 stale」的 reason-code,只有 2「p5 not seeded」和 12「.txn」(`219-protocol.cddl:120-131`);§5.1 也沒有把 stale 對應到任何碼。
  - §6「升級到 P3 第一次開機」那一列還是寫「helper `--boot` 看到版本變了執行一次 `--save`」,也就是 v3 的機制,跟 §3.3 互相矛盾。
- **情境**:節點經 ssh sysupgrade 從 P2 升到 P3。已入網的節點下一個 joinwatch tick 就存好了,沒事。**未入網的節點**(bench、還在等國家設定的新節點(D15)、入不了網的節點)就不行:p5 沒有 ssid、live 有 → `--check` stale → `update/check` 被拒,而且沒有對應的碼(實作多半會回 2「p5 未 seed」,誤導);操作員的 sysupgrade 也要 `allow-stale-p5` 才能過。`settings/set` 寫同一個值時是「直接回」(§5.2),不會觸發 `--save` → app 沒有辦法自救。
- **修法**(擇一,都不需要新資源):
  - (a) **用既有的 `schema_version`**:新 PRESERVE key 標成 schema 2。`--check` 對 p5 `schema_version` < 2 的情況,忽略「p5 沒有」的 schema-2 key(其他照舊逐 byte 比);下一次真的 `--save` 時寫成 schema 2。96 的 `schema_migrate` 本來就是為這種情況設計的(additive)。
  - (b) helper 開機時:`--check` 說 stale,**而且 stale 的 key 全部都是 p5 `overrides.uci` 裡沒有的那幾個新 key**(可以從 `--check` 輸出的 key 名 + grep p5 判斷,不用記版本)、沒有 `.txn`、不在試用中 → 執行一次 `--save`。
  - 另外:§5.1 / CDDL 把 non-txn 的 p5 stale 對應到明確的碼(新增一個 reason,或在 E_REJECTED 的 detail 裡帶 key 名),並刪掉 §6 那一列舊的 `--boot --save` 寫法。
- **負測試**:P2 節點(未入網、p5 已 seed)sysupgrade 到 P3 → 第一次開機後 `batman-config-save --check` = fresh、`update/check` 不因 p5 被拒。負對照 = v4 的寫法:rc 5 `p5 stale: wireless.default_radio0.ssid`。

---

## MINOR

1. **`kmod-nft-bridge` 可能不需要(only-necessary)**:bridge 的 filter 鏈型別在 `nft_chain_filter.c:229`(`#if IS_ENABLED(CONFIG_NF_TABLES_BRIDGE)`),編進 `nf_tables.ko`,而 04 是 `CONFIG_NF_TABLES_BRIDGE=m`。§3.8.1 的規則(`iifname`、`tcp dport`)只用到核心的 meta / payload。`kmod-nft-bridge` 的檔案是 `nft_meta_bridge` / `nft_reject_bridge` / `nf_conntrack_bridge`(`include/netfilter.mk:332-334`),這幾個 04 kernel 都是 not set → 選了這個 kmod 會改 kernel config。修法:先在 bench 節點(不是 04)試 `nft add table bridge t; nft add chain bridge t i '{type filter hook input priority 0;}'`,能過就不加 kmod。結果寫進 F 表。
2. **`provd-stable` 怎麼認出「provd 的 ctl 連線」**:helper socket 的每條連線 SO_PEERCRED 都是 uid 471(`sock/sock.go:1-6`),ctl / ops / ro / provclient 從憑證上分不出來。測試用的 provclient 掛著 60 s 也會寫出 `provd-stable`。修法:以 peer pid = procd `batman-provd` instance 的 pid 判斷(provd 沒有 pid ns,`batman-provd.init` 沒有 `-p`),或由 ctl 的第一個請求表明身分。
3. **ro 的容量算式要寫全**:helper 還有**全 helper** 10/s burst 40 的唯讀額度(`node/readonly.go:7`、`:22-23`),跟每連線的 5/s 是兩層。ro 5/s + ctl ≈ 1/s = 6/s < 10/s 才成立。另外 `MaxConns = 4`(`sock.go:28`)= ctl + ops + ro + 1 個 provclient。H4 若同時開兩個 provclient,或 provclient 同時在讀,就會被拒 / 吃掉全 helper 額度、讓 poll 拿到 ERate。把算式和「provclient 最多 1 條、不與 app 讀取並行」寫進 §2。
4. **`settings.get` 不跑子程序,那資料從哪來沒寫**:它要 hostname / country / ssid。要嘛 helper 自己 parse `/etc/config/{system,wireless}`,要嘛用有時間戳的背景快取(openmanetd / 操作員改了以後多久看得到)。寫進 §3.3 / §5.3。
5. **國家的另一個寫者**:04 `strings /usr/bin/openmanetd` 有 `SetupCountry`、`validateMeshCountry`、`currentMorseCountry` → openmanetd 的設定 UI 也會寫國家。§4 的國家列只寫了 setkey + ssh;要像 hostname 列一樣列出 openmanetd(最後寫的贏,app 以 `settings.get` 為準)。
6. **`radio0.country` 是否必要**:D15 管的是 HaLow(`net_config` key 5 對 `radio1.country`)。04 radio0 是 5 GHz ch36 VHT80,沒有設 country,全域 regdomain 是 `00`;morse 是 self-managed(`iw reg get` 的 `phy#2 (self-managed) country US`)。在 key 2 一起改 radio0,會多一個失敗點:brcmfmac / hostapd 對新國家起不來 → 整個 key 2 還原 → 依 D15 入不了網。要嘛寫出需要它的理由(5 GHz 合規),並讓 radio0 失敗不阻擋 radio1 的國家;要嘛 key 2 只改 radio1,radio0 country 不進 PRESERVE。
7. **setkey `--rollback` 的 300 s 預算沒有證據**:`halow-setkey:36-39` 的 LOCKWAIT 90 + SETTLE 30 + READBACK 60(順向),再加上還原的 SETTLE 30 + READBACK 60(或 FORGET 30),再加兩次 config-save `--save`,在鎖被佔用時會超過 helper 的 300 s(`main.go:84-85`)→ helper 在**還原到一半**時殺掉 setkey → 既不是新的也不是舊的狀態(違反「失敗就回到之前的狀態」)。修法:helper 呼叫時縮短 LOCKWAIT(例如 20 s),或 setkey 用總期限、為還原預留時間;並寫明 helper 遇到 RCTimeout 時怎麼收尾(例如再跑一次 `--rollback`)。
8. **沒有 `batman-slot disarm` 動詞**:§3.7.3 說「`batman-slot` 既有的 disarm 路徑」,但 `disarm_tryboot` 只是內部函式(`batman-slot:392`),CLI 動詞只有 `active / target / … / is-trial / verify / precheck-node / verdict-gate`(`:900-917`)。要新增 `disarm`(兩板共用),列進 §3.7.4 / §10 和 ab-card 測試。
9. **上傳中被 AP reload 打斷**:上傳窗開著時,`otaBusy()` 只在 worker 跑的時候擋(§3.1.5)。成員的 `network/update`(→ net.apply → `network reload`,F51)、另一個擁有者的 key 20 / key 2 都會重啟 AP → 126 MB 的上傳斷掉,只能重傳(沒有續傳)。要嘛上傳窗開著時也讓這些動詞回 `E_BUSY`,要嘛寫成誠實界線 + app 重試。
10. **bulk tmpfs 的 `size=` 由正在跑的 image 決定**:下一版的 payload 只要比 `size=` 大,就永遠不能經 app 裝(reason 8),只能 ssh sysupgrade。tmpfs 只在寫入時佔 RAM,`size=` 要留餘裕(例如 2 × 目前的 payload);真正的限制交給 RAM 預算檢查(§3.7.3)。
11. **文件前後不一致(實作時會照錯的那份寫)**:
    - §6「provd crash」列寫「上傳檔下次 provd 啟動刪」,跟 §4 清理表「helper 是唯一刪除者、provd 重啟不刪」衝突。
    - §6「換 IP」列的「允許清單更新」是 v3 的機制(D19 已拿掉)。
    - §6「正常停止」沒寫 helper 什麼時候刪(ctl 斷線?到期?)。
    - §7「經 mesh → 403」、§8 `prov-upload-254`「經 mesh → 17」,但 §5.1 寫的是 L2 直接丟棄,到不了 provd → 測試的預期應該是「連不上(沒有 SYN-ACK)」。reason 17 從來不會被送出 → 要嘛刪掉,要嘛只寫成 app 端的文字。
    - §3.7.3 步驟 3 寫「key 8 對本機 p1」,§3.7.1 寫「目標槽」(Pi 4 跑在 B 槽時目標是 p1,跑在 A 槽時是 p3)。
    - arm 之後、重開之前斷電:tryboot 旗標不會留下來 → 開回舊槽 → update-last 判讀成 6「已退回」,但其實從來沒有試用過。可以接受,但 app 的文字要寫成「沒有更新」而不是「試用失敗」。

---

## 已核實(✅,附出處)

- B3-M1 → D19:以 bridge port 判斷,偽造 MAC / ARP 無效 ✅。04 `bridge link show`:`eth0`、`phy1-ap0`、`bat0` 都在 `br-ahwlan`;`ip -br addr` 沒有其他接到 ahwlan 的 L3 介面;docker0 / br-ots 另有位址,由 fw4 擋(F58)。ifname set 存的是名字,netifd 重建 iface 之後仍然有效。
- B3-M2:ro 連線、拿掉 per-accept 查詢、拿掉 `bulk.done` ✅(算式見 MINOR 3)。
- B3-M3:placeholder → 回到封鎖;passphrase 走 stdin ✅(`halow-setkey:64-65`、`main.go:154` 慣例)。
- B3-M4:被封鎖的 radio 只驗 uci + regdb,晶片端驗證在 join ✅。
- B3-M5 → D18:provd 的 `preflight()` 只檢查廣播長度(`bluez.go:70-80`),BT 硬體壞掉時 `ble.run()` 退避、不結束程序(`bluez.go:629-639`);procd `respawn 3600 5 0` → provd-stable 不受 P-U5(BT UART wedge)影響 ✅。autocommit 會一直 poll 到 deadline、`MIN_WINDOW 300 s`(`batman-autocommit:30-35`、`:470-560`)→ 試用前 60 s 還沒有 provd-stable 只會延後 commit,不會誤退 ✅。
- 新卡認領 → `RadioManaged = true`(`node.go:539`);只有 legacy 是 false ✅。所以 key 20 在新卡上可用。
- 降級:p5 多出的 `wireless.*` 行可以被舊版 96 的 `valid_batch` 接受(package allowlist,`96-batman-config-migrate:33-46`)✅。
- sysupgrade 也經過 `begin_write`(`batman-slot:654,665`;`platform-ab.sh:364,377`)→「begin_write 先刪 VERIFIED」涵蓋所有寫者 ✅。
- joinwatch `verdict()` 的變數不帶秘密(`KEY` = SET / NONE / PLACEHOLDER,`joinwatch:60`)✅。
- uhttpd 以 root 跑(04 `ps`)→ CGI 讀 p6 `prov-state` 可行 ✅;每台節點都在 ahwlan 上跑 dnsmasq(04 `uci show dhcp`)→ 沒入網的節點,手機連上它的 AP 也拿得到位址 ✅。
- fw4 `restart` / `reload` 只動 `inet fw4`;只有 `flush`(= `firewall stop`)會刪別的表 → M1 的觸發條件是確切的 ✅。

## 收斂判斷

剩下兩個 MAJOR 都是局部的:M1 是指名載入者 + helper 先確認表在才給位址;M2 是換一個做得到的 stale 判斷。MINOR 主要是寫清楚算式 / 資料來源、文件一致性,以及兩項 only-necessary(kmod、radio0 country)。沒有新的子系統,也沒有新的安全面。MAJOR 修完、整份再審一輪,應可 APPROVE。
