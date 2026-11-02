# #254 PR-P3 設計 v3 審查(審查者 B)

對象:`docs/design/254-p3-impl.md` v3(feat/254-p3 @ 6433520,base main 2ecf1cb)。審整份,不只 v2 → v3 差異。
方法:對照 `feed/batman-prov/src`、`feed/batman-provision/files`、`scripts/`;04(1.5.14-wsl.22,Pi 4,prov legacy)只跑唯讀指令(沒寫任何檔、沒 uci set、沒重啟)。repo 未改、未 push、GitHub 未留言。

**判定:REJECT(範圍窄,接近收斂)**。0 BLOCKER、5 MAJOR、13 MINOR。
v2 的 M1(HTTP 角色)、M2(備援觸發 = provd `HealthOK`)、M5(reload 後讀回)、gzip / 目錄成員、FIFO、VERIFIED / phase 3 重建、legacy 的處理方向都對,逐條核過(見文末 ✅)。
剩下的 MAJOR 都在「新加的門實際上擋不擋得住 / 回不回得去」:
- D16 的 accept 檢查用 IP→MAC,mesh 上可偽造(M1);
- 新唯讀動詞與 per-accept 查詢全擠在 provd 唯一一條 ctl / ops 連線上,沒有容量契約(M2);
- key 20 / key 2 的「讀回 + 失敗還原」在**剛認領、未入網**的節點(正是它們要服務的情境)走不通(M3、M4);
- app OTA 成為主路徑後,provd / helper 壞掉的版本會被 autocommit 收下(M5)。

這些都是局部修正(M1 是**換**一個機制,不是加),沒有需要新子系統的項目 → 再一輪應可收斂。

---

## MAJOR

### M1. D16「accept 時只收本 AP client」用 IP→MAC(`ip neigh` + `hostapd get_clients`)判斷,mesh 上任何能送 L2 frame 的主機都能偽造;D16 要解決的「mesh 耗光 HTTP」沒有被擋住
- **情境**:`br-ahwlan` 把 `eth0`、`phy1-ap0`、`bat0` 橋在一起(04 `bridge link show`:三個 port 都在 br-ahwlan)。各節點 AP / eth 上的 client MAC 由 batman-adv TT 廣播到整個 mesh(04 `batctl tl` 列出本地 client `10:7c:61:d4:b9:72`,peer 的 `batctl tg` 就看得到)。任何一台節點 eth0 上的筆電(或任何 mesh 成員)可以:
  - 以手機的 MAC 當 source 送 frame → 04 的 bridge FDB 把手機 MAC 重學到 `bat0` port → 回包送到攻擊者;或
  - 送 ARP 讓 `ip neigh` 把某 IP 對到手機 MAC。
  兩種都讓 §3.8.1 的三個條件(MAC 在 `get_clients`、`ip neigh` 在 br-ahwlan 上對到該 MAC)成立 → 通過 accept 檢查 → 2 槽 / 10 交握/分 又能被耗光(v2 A2-M5 / B2-M3 原情境)。§3.8.1「ARP 偽造只能讓真正的 client 被拒」不成立:偽造 source MAC 的人拿得到回包。
- **證據**:04 `bridge link show`、`batctl tl`;設計 §3.8.1 判斷方式。
- **修法**:檢查**進來的 bridge port**(L2),不是 IP→MAC:
  - nft bridge family `input` 鏈:`tcp dport 8095 iifname != <AP ifname> drop`。04 `CONFIG_NF_TABLES_BRIDGE=m`,但 module 沒裝(`/lib/modules/6.6.138` 沒有 nf_tables bridge 相關 .ko)→ image 要加 `kmod-nft-bridge`(⚠️ 先在 04 確認);或
  - `xt_physdev`(04 有 `/lib/modules/6.6.138/xt_physdev.ko`)+ `br_netfilter`(04 已載入、`bridge-nf-call-iptables=1`,但 refcount 0,看起來是 docker 帶起來的;沒有 OTS 的節點要確認)。
  - AP ifname 會漂移(F52):規則由 helper 依 `network.wireless status` 維護(單一寫者寫進 ownership 表),或用 nft set。
  - `get_clients` 檢查可留作第二層,但不能是唯一的門。
- **負測試**:另一台節點 eth0 上的主機以手機 MAC + 手機 IP(及 ARP 毒化變體)連 8095 → 被丟;負對照 = v3 的 IP→MAC 版本放行。

### M2. 所有新唯讀動詞、AP-client 查詢、`bulk.done` 都擠在 provd 唯一的 ctl / ops 連線上,設計沒有容量契約;per-accept 查詢讓 mesh 上的人可以把 poll 擠到 ERate → `HealthOK` 失效 → BLE 撤廣播
- **事實**:
  - helper 唯讀額度:每連線 5/s burst 20、全 helper 10/s burst 40,超過回 ERate(`node/readonly.go:7`、`:21-24`)。
  - provd 只有**一條** ctl 連線(`ctlMu` 序列化,`provd/server.go:163-166`);poll 每 4 s 打 3–4 個 ctl 動詞(`server.go:20`、`:343-397`)。ERate 連續 > 120 s → `HealthOK=false`(`server.go:26`、`:484`)→ 撤廣播。
  - ops 也只有一條,而且整個 provd 同時只能一個請求(`provd/helper.go:29-30`、`:185-194`),BLE 與 HTTP 的 session 共用;`HelperWait` 330 s(`server.go:22`)。helper 呼叫 `halow-setkey` 的上限是 300 s(`cmd/batman-provhelper/main.go:84-85`)。
- **情境**:
  1. HTTP 在聽的時候(備援或上傳窗),mesh 主機每秒開大量 TCP 連線到 8095。每個 accept 都要 provd 以唯讀動詞查 helper;查不到還要求「立刻刷新」。ctl 的 5/s 被吃掉 → poll 的 `health.get` 拿到 ERate → 120 s 後 `HealthOK=false` → BLE 撤廣播。在備援模式下,它還會讓「BLE 不健康」自己延續下去。這正是 v1 B1(mesh 讓 BLE 失效)換條路回來。
  2. app 下載 2 MiB 診斷包 ≈ 43 次 `diag.read`,再加上 `status` / `update.status` 輪詢,都和 poll 共用每連線 5/s。
  3. key 20 失敗時:setkey 一次 ≤ 300 s,還原再一次 ≤ 300 s,合計 > `HelperWait` 330 s → app 拿到「outcome unknown」,但還原還在跑;這期間 ops 被佔住 → 其他 session 的 `bulk.done`、`peers/challenge`、`network/update` 都回 `E_BUSY`。`bulk.done` 遺失就會「窗到期時 helper 當 fail」→ 126 MB 的上傳作廢。
- **修法**(都是局部):
  - (a) accept 判斷不呼叫 helper。M1 的 L2 規則做完後,provd 就不需要 per-accept 查詢;如果保留第二層,AP-client 集合由 helper 自己的計時器刷新,放在 poll 回覆裡推給 provd,provd 在記憶體比對。
  - (b) 寫下 ctl 預算:poll 動詞保留額度(例如給 poll 自己的 bucket,或 app 唯讀動詞走第二條連線),並給出每個新唯讀動詞的上限。
  - (c) 拿掉 `bulk.done`:`update.prepare` 自己 fstat 上傳檔(大小 = key 3)。worker 本來就全部驗過,少一個介面。如果保留,要寫明重試語意。
  - (d) key 20 / key 2 的時間預算 ≤ `HelperWait`(helper 呼叫 setkey 時把 LOCKWAIT / READBACK 縮短,或把還原放進同一次 setkey 呼叫)。
- **負測試**:HTTP 在聽時,mesh 主機以 50 conn/s 連 10 分鐘 → poll 沒有 ERate、廣播還在;owner 在 BLE 上做 key 20 失敗臂的同時,另一個 session 的 `bulk.done` / prepare 成功。

### M3. key 20「失敗以舊值經同一扇門還原」在剛認領的節點走不通:舊值是 placeholder,setkey 拒收;而且 keyguard 的封鎖已經先解掉了 → 失敗後 AP 是開著的、帶著未驗證的新帳密,不是「之前的狀態」
- **事實**:
  - 未認領節點第一次開機時,AP key 被設成 placeholder(`cmd/batman-provhelper/main.go:460-468`)→ keyguard 把 AP 關掉(`etc/init.d/halow-keyguard:30-38`)。
  - `halow-setkey` 的 `validate()` 拒絕 placeholder(`usr/bin/halow-setkey:83`)。
  - 解除封鎖(刪 `disabled`、改 MARK)發生在 commit / reload **之前**(`:290-303`、`:307-309`)。
- **情境**:新卡 → 認領 → key 20 → hostapd 起不來(§8 自己列的 wbox 注入臂)→ 設計要求「以舊 ssid / key 再呼叫 setkey」→ 舊 key = `CHANGE-ME-NOW` → rc 2。結果 uci 留著新值、`disabled` 已刪、MARK 已清,AP 處於「沒驗證過的狀態」。§8「舊值回來、p5 不變」在新卡上必定 FAIL。
- **修法**:
  - 先定義「之前的狀態」:舊 key 是 placeholder 時 = 封鎖(placeholder + `disabled=1` + MARK)。
  - 給 setkey 一個對應 `--forget-mesh` 的 AP 模式(stage + 一次 commit + 驗證 AP 已 down),失敗時走它。舊 key 不是 placeholder 時,照 v3 的寫法以舊值重送。
  - 另外,PSK 照既有慣例走 stdin(`--ap -`)。helper 對 mesh key 已經這樣做(`main.go:154`;`halow-setkey:64-65`:「helper never puts a secret on a command line」);v3 寫成 `--ap <psk>`,會出現在 `/proc/<pid>/cmdline`。
- **負測試**:新卡認領 → key 20 注入失敗 → AP 不在空中(`iw dev` 沒有 AP iface)、`disabled=1`、MARK 列有該 iface、p5 不變;負對照 = v3 版本的 AP 開著。

### M4. key 2(國家)的讀回「兩個 radio 都 up、morse 回報的國家相符」在 D9 / D15 唯一允許改國家的節點(未入網)上永遠不成立 → 必定還原 → 非 US 網路永遠入不了網
- **事實**:
  - 新卡的 mesh key 是 placeholder(`254-stage1-impl.md:56` F23:`meshpoint-1.8.0` 把 mesh key 設成 `CHANGE-ME-NOW`)→ keyguard 把 morse radio 關掉(`halow-keyguard:22-27`)。
  - 未入網的節點 radio1 是被封鎖的;radio0(AP)在 key 20 配對前也是被封鎖的(M3)。
  - setkey 自己的讀回只在 `ENABLED=1` 時才等 radio up(`halow-setkey:306`、`:330`)。
- **情境**:app 照 D15 先 `settings/set` key 2 = `TW` 再 join → radio1 不會 up → 讀回 FAIL → 寫回 US → reason 13 / `E_STORAGE`。之後 join 帶 `TW` → reason 14,沒有出路。§8「改了以後 morse 真的換表」在被封鎖的 radio 上也量不到。
- **修法**:
  - 被封鎖 / disabled 的 radio:讀回 = uci 值 + regdb 驗證(頻道在新國家合法),不要求 up。
  - 晶片端的真驗證放在 join:setkey `--mesh/--channel` 的既有讀回,以 `morse_cli` 的 Operating Frequency 對 regdb centre(`halow-setkey:349-374`)。這時 radio 第一次以新國家起來,讀回就涵蓋了國家。寫明這一點。
  - radio 是 up 的節點(不應出現,因為已入網 → reason 14)照 v3。
  - §9-6 的 04 實測要在「被封鎖 → join」的順序下做。
- **負測試**:新卡認領 → key 2 = 另一國 → 成功(uci 已改、p5 已存)→ 同國 net_config join → morse 頻率 = 該國 regdb;負對照 = v3 版本 key 2 被還原。

### M5. autocommit 的健康條件不含 provd / helper;P3 讓 app OTA 成為擁有者的主路徑後,一個 provd 或 helper 起不來的版本會被自動 commit,擁有者永久失去 app 管理通道(違反「失敗就回到之前的狀態」)
- **事實**:`health_ok` 只看 `mesh11sd`、`openmanetd`、`wpad`(`usr/bin/batman-autocommit:452`);BLE 只 WARN(`:506-511`,D6′)。
- **情境**:新版的 `batman-provd.init` 加了 bulk tmpfs 掛載與 rw jail mount(§3.8.2)。一個 init / jail 錯誤 → provd respawn 5 次後放棄(`batman-provd.init:15`)→ mesh 正常 → autocommit commit → BLE 與 HTTP 備援都死(兩者都在 provd 裡)。之後只剩 ssh / LuCI(要管理密碼 + 有線)或重燒。
- **與 D6′ 的關係**:D6′ 讓 **BLE 無線電健康**維持 WARN,理由是 P-U5 的 Pi 4 BT UART wedge。「provd / helper 的 procd instance 在跑、helper ctl 有回應」與 BT UART 無關,不受 P-U5 影響。**這是提醒,不推翻決策**:請使用者決定要不要把這兩個行程納入 `health_ok`(BLE 無線電仍只 WARN)。
- **負測試**:trial image 的 provd binary 壞掉 → revert;負對照 = 現行 autocommit commit。

---

## MINOR

1. **遺失手機與 AP 密碼**:D14 把 AP 密碼存在手機。`owner/remove` 切 session / psk,但 AP 密碼不變 → 撿到手機的人可以連 AP → 進 br-ahwlan → 整個 mesh LAN(TAK)。§7「遺失手機」列與 §3.11 要加:移除遺失的擁有者後,app 以 key 20 換 AP 密碼。
2. **時間來源**:pending 30 分、上傳窗 15 分、diag 10 分、autocommit 的 `ts ≤ 60 s` 都要用單調時間(uptime)。證據:04 `date` = 2025-07-28,實際是 2026-11-02(無 RTC);health 行的 `ts` 本來就是 uptime(`health/health.go:196` `e.Uptime()`)。
3. **D15 的兩條死路**:
   - (a) legacy:key 2 回 `E_UNSUPPORTED{7}`,但 join 仍比對國家 → 國家不同的 legacy 節點無法從 app 入網(只能 ssh `halow-setkey --country`)。
   - (b) P2 時已入網的成員(P2 不處理國家,F29),或國家被操作員 / openmanetd 改過的成員:每個 `network/update` 都回 14,key 2 也因「已入網」回 14 → 卡在舊版本,收不到換鑰。
   - 修法:`network/update` 拿新國家和**已存的 net_config 國家**比(只拒絕「改國家」);join 拿來和 radio 比;legacy 未入網時允許 key 2。
4. **ctl「唯讀」的說法前後不一致**:§3.8.2 以「ctl 是唯讀的」(A2-m8)把 `bulk.done` 放到 ops;但 poll 請求的 `{healthok}` 會讓 helper 開備援,「session 結束(provd 經 ctl 告知)」會讓 helper 刪 diag,兩者都是經 ctl 改變 helper 狀態。要嘛寫明 ctl 可以帶建議性通知、以及為什麼安全,要嘛統一。另外的簡化:備援的開關其實是 provd 自己的 `HealthOK` 繞 helper 一圈再回來,而且 §7 已承認被入侵的 provd 本來就能自己聽 → 備援可以由 provd 自己決定,只有上傳窗需要 helper(only-necessary)。
5. **F49 / setkey 的事實要修**:keyguard 開機時發現 key 已經手動設好,會自己解除(`halow-keyguard:40-45`),所以 setkey 不是「唯一」解除的門;`--ap` 會寫**每一個** `mode=ap` iface(`halow-setkey:286-288`),PRESERVE 卻只存 `default_radio0` → key 20 要明確指定 section。
6. **「`--boot` 看到版本變了就 `--save` 一次」需要一個沒列出的資源**(上次看到的版本存在哪、誰寫、格式、缺了怎麼辦)。要嘛列進 §4 / §5.3,要嘛改成更簡單的做法(例如由 `update.check` 的 precheck 在 stale 時明確回報,不在開機時自動存)。
7. **helper 在上傳中重啟**:上傳窗只存在 helper 記憶體 → 窗消失;啟動時的清理會刪掉 provd 正在寫的檔 → provd 寫到一個已 unlink 的 inode。§6 少這一列。寫明:fail-closed,擁有者重開窗再傳。
8. **arm 之後、重開之前 helper 掛掉**(或 arm 和寫 update-last 之間):tryboot 仍是 armed,下一次任何原因的重開(watchdog、拔電以外的重開)會在不可預期的時間進 trial,可能在任務中。修法:先寫 update-last 再 arm;helper 啟動時看到 `from_slot` + 同一個 boot_id,就 disarm 或立刻重開,二選一寫死。
9. **update-last 的誤判**:之後操作員再 sysupgrade 換了槽,目前槽 = `from_slot` → 報 6「已退回」。判讀時再比對該槽的 `BATMAN-VERIFIED` / 版本。
10. **新的 tar 順序只對新建的 payload 有效**:Go 解析要求 `SHA256SUMS` 是第一個成員 → app 路徑不能裝任何 P3 之前建的 payload(key 6 降級到舊版也不行)。寫進誠實界線。
11. **CM4 平台列**:必須是有無線的型號(BLE + radio0 AP);沒有無線的 CM4 兩條通道都沒有 → 不支援。寫進 §6 / checklist。
12. **App 需求**:AP 沒有對外網路時,手機系統會把連線走行動網路;app 必須把 socket 綁在 Wi-Fi 網路上(Android `bindProcessToNetwork`、iOS 對應機制),否則備援 / 上傳連不到 10.41.x。
13. **快取的第一次請求**:`halow-status` 快取「有人問才刷新」→ 第一次 `status` 時 key 3 / 5 / 15 怎麼回(省略?等待?)沒寫,也沒有測試。

---

## 已核實(✅,附出處)

- F26:`Slots = 2`(`provd/server.go:34`);撤廣播看 `nlinks > 0 || b.srv.Sessions() > 0`(`cmd/batman-provd/bluez.go:770`,F26 寫的路徑 `bluez.go` 實際在 `cmd/batman-provd/`)。
- F27:apply 用 glob 複製(`batman-slot:679-682`),只驗列名的檔(`:696-699`);tar 順序 `root.squashfs boot metadata SHA256SUMS`(`build-ab-payload.sh:73`);`metadata` 不在 SHA256SUMS(`:72`)。
- F45:`HealthOK` 的條件(`server.go:480-499`)。
- F46:`UNSAFE` 字元集(`batman-config-save:53`)、setkey 也禁止(`halow-setkey:84-86`);applyNet 把 rc 6 當成功(`node.go:1162`)。
- F57:platform-ab 依名字取成員(`platform-ab.sh:207,328,370`)。
- F53:04 上 `/tmp/run/batman` root 0700、`/tmp/run/batman-prov` root:provd 0750;`/tmp/.uci/system` 存在但大小 0(所以「非空」的寫法是對的)。
- F54:04 `prov-state` = `<boot_id> helper legacy legacy - today`;99zz 寫的格式是 `<boot_id> 99zz <state> <state> - <me>`(`main.go:473`)→ 第 3 欄都是 state ✅。
- `begin_write` 不刪 VERIFIED(`batman-slot:423-436`);每槽有自己的 boot 分割(`:103` p1 / p3)→ key 8 比對目標槽 ✅。
- 04 埠:8095 未被佔用;AP 在 5 GHz(`get_clients` freq 5180);`radio0` 沒有 country ✅;MemAvailable 7.1 GB;`/tmp` 3.8 GB。
- 加入網路時把 `RadioManaged` 設成 true(`node.go:1125`)。

## 收斂判斷

剩下的都是局部修正:
- M1 換掉一個機制(L2 port 取代 IP→MAC),不是新增;
- M2 寫下容量 / 時間預算並拿掉 per-accept 查詢和 `bulk.done`(變少);
- M3 / M4 修讀回與還原規則;
- M5 是請使用者決定的一行健康條件。

沒有需要新子系統的項目。修完 MAJOR 後再整份審一輪,應可 APPROVE。
