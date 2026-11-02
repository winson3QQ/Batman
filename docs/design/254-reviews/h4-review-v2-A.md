# H4 harness 設計 v2 — 審查 A(第 2 輪)

- 審查對象:`docs/design/254-h4-harness.md` v2(branch `harness/254-h4` @ d5cf7ed),**整份**,不是只看差異。
- 上層:P3 `254-p3-impl.md` v7.1(`feat/254-p3` @ dfedd03)§2、§3、§5、§6、§7、§8、附錄 D;h23 `254-h23-harness.md`;程式 = `/home/yello/Batman` main 2ecf1cb。
- 審查者:A(獨立、對抗式),2026-11-02。
- 方法:先讀第 1 輪 A / B 報告,逐條核對 v2 是否真的解掉;再從「實際怎麼跑」出發,把 §2 每種載具、§3 S0、§4.4 / §4.5 / §5 / §7 / §8.1 的每個機制對回原始碼或 04 的唯讀輸出;最後逐列對附錄 A ↔ P3 §6 / §8 / 附錄 D,並逐列檢查 W / S / P。
- 節點只做唯讀:04 = 10.41.1.3(`cat /etc/batman-build`、`/proc/cmdline`、`/proc/mounts`、`/sys/block/loop0/loop/*`、`bridge link`、`ip -d link`、`uci show firewall|wireless|dhcp`(濾掉 key)、`nft list chain inet fw4 input`、`nft list tables`、`sysctl`、`lsmod`、`busybox` 小工具清單、`free`)。沒有改任何節點狀態,沒有改 repo 檔案(只寫本報告)。

**結論:REJECT — 1 BLOCKER / 9 MAJOR / 22 MINOR。設計尚未收斂。**

v2 的骨架(載具分類、S0 + 金鑰庫、核心在 WSL、可續期的新卡 dead-man、逐列附錄 A)方向正確,第 1 輪兩個 BLOCKER 的主體(wbox 試用跑不出改狀態的動詞、新卡停在試用)都已處理。但有一個新的結構性矛盾:**S0 與 `s0_assert` 本身就要用 P3 的動詞**,所以在 wsl.22 上不可能成立,而附錄 A 的 W 型負對照全部要在 wsl.22 上跑 → H4 PR 附不出任何 W 證據(B1)。其餘 MAJOR 多半是「這一臂在真機上做不到 / 分不出對錯」,都有唯讀證據。

---

## 0. 我取得的證據(原始輸出節錄)

**E1 — overlay 是每個槽各自的**(04,唯讀):
```
/dev/loop0 /overlay f2fs rw,...
overlayfs:/overlay / overlay rw,noatime,lowerdir=/,upperdir=/overlay/upper,...
$ cat /sys/block/loop0/loop/backing_file ; cat /sys/block/loop0/loop/offset
/mmcblk0p2
116391936
cmdline: ... panic=10 root=PARTUUID=3276af79-0000-4000-8000-000000000002 batman_slot=A
```
→ 槽 A 的 overlay 在 p2 的 squashfs 之後;槽 B 的在 p4。`upper-helper` 寫進的是**目前槽**的 upper。

**E2 — 04 的 busybox `nc` 沒有 listen / timeout,也沒有 `timeout`、`ss`**:
```
$ nc --help
BusyBox v1.36.1 (2025-06-23 20:40:36 UTC) multi-call binary.
Usage: nc [IPADDR PORT]
Open a pipe to IP:PORT
$ ls /bin /usr/bin /sbin /usr/sbin | grep -x -E "timeout|socat|...|ss|netstat"
dropbear iperf lua netstat openssl ping tcpdump uhttpd wget
$ cat /proc/sys/net/ipv4/tcp_syn_retries
6
```

**E3 — `br-ots`(docker)zone 的 input 已經是 DROP**:
```
firewall.ots_zone.device='br-ots'
firewall.ots_zone.input='DROP'
chain input { ... policy drop; ... iifname "br-ots" jump input_dockert ... }
firewall.@zone[2].name='ahwlan' / input='ACCEPT'
```

**E4 — `br-ahwlan` 的 MAC 是設定值(加 port 不會變)、vlan_filtering 0、rp_filter 0**:
```
/sys/class/net/br-ahwlan/addr_assign_type = 3
br-ahwlan: mtu 1460 ... vlan_filtering 0 ...
net.ipv4.conf.default.rp_filter = 0 ; all.rp_filter = 0 ; devconf_inherit_init_net = 0
lsmod: br_netfilter, veth
dhcp.ahwlan.start='100' limit='150'   (10.41.250.x 不在 DHCP 範圍內)
```

**E5 — BLE 廣播只有 UUID,RPA 約 15–17 分換一次**(`cmd/batman-provd/bluez.go:268-270`、`:37`、`:597`、`:771-779`):
```go
ap := map[string]*prop.Prop{"Type": {Value: "peripheral"}, "ServiceUUIDs": {Value: []string{SvcUUID}}, "Discoverable": {Value: false}}
rpaBase   = 900 * time.Second
b.advOn, b.nextRPA, b.advAt = true, time.Now().Add(rpaBase+jitter(30, 120)), time.Now()
case nlinks > 0 || b.srv.Sessions() > 0: ... b.withdraw("connect")
```

**E6 — provd 的 ops 一次只跑一個,在跑時新的直接 `ErrBusy`**(`provd/server.go:182-184`):
```go
// opsCall: one request on ops. ErrBusy = another one is in flight. ...
```

**E7 — 現行 provd 的 `p3Types`**(`provd/session.go:68-70`):`owner/add`、`owner/remove`、`settings/get`、`settings/set`、`status`、…、`bulk/open` 全部在內 → wsl.22 上這些都是 `E_UNSUPPORTED`。

**E8 — 最後一位擁有者**(`node/node.go:890`):`return nil, fail(EForbidden, "cannot remove the last owner (reflash to transfer)")`。

**E9 — `prov-wbox-254.sh` 的封閉清單**:bind 目標只有 `provhelper / autocommit / halow-setkey / batman-config-save / banner / identity/node.key / dropbear/authorized_keys`,註解寫「never batman-slot (review r2 A-m5)」(`:64-67`);killpoint 名字只收 `txn-[1-5]|claim-after-persist|claim-before-shadow`(`:50`);provd 的 log 是 `batman-provd[1]`(jail 的 pid namespace,`:149`)。

**E10 — lease dead-man 做的事**(`scripts/node/prov-lease-254.sh:14-18`、`role_fire_restore`):unbind-all、刪 `/tmp/run/batman-prov-test`、還原 upper 裡的 helper、`provd_restart`、`radio_restore`、啟動 joinwatch / openmanetd / tailscaled。**不碰防火牆、bridge port、uci 暫存、AP**。staged 檔在 tmpfs(`/tmp/run/batman-dv/bt/<run>/`),重開就沒了。

**E11 — chain1 的新卡 dead-man**(`scripts/dv/chain1-254.sh:291` 附近):寫在 B 的 `/etc/rc.local`(B 的 overlay)+ 一個 `setsid sleep 1500`;前提「A committed $V」且 payload 版本 = V(`:186-196`)。

**E12 — WSL 沒有 aarch64 binfmt / qemu**:`/proc/sys/fs/binfmt_misc/` 只有 `WSLInterop`、`llvm-18-runtime.binfmt`、`python3.12`;`which qemu-aarch64-static` 無輸出。

**E13 — autocommit 的 dry-run 不重設 PATH**(`batman-autocommit` 全檔無 `PATH=`;`:26-27`、`:69`、`:323` 為 DRYRUN / FORCE_TRIAL)。

---

## 1. 第 1 輪意見是否真的解掉

| 第 1 輪 | v2 的處理 | 判定 |
|---|---|---|
| A-B1 / B-B1 wbox 試用跑不出改狀態動詞 | §2 R / RB / RD / T / W / F / L / C | ✅ 主體解掉;但 RB / T 跨重開的部分仍有洞(M1) |
| A-B2 新卡停在試用 | §4.4 涵蓋步驟 6、可續期 dead-man | ⚠️ 期限格式與 firstboot 會破壞它(M2) |
| B-B2 / A-M6 S0 與擁有者 | §3 | ❌ S0 在 pre-P3 上建不起來,連帶 W 全部做不到(B1) |
| A-M1 / B-M10 對表 | 附錄 A | ⚠️ 大致齊全;P3 §6 有幾列漏或沒寫清楚(M8),R 上「T 簽的被拒」被丟進 NEEDS-PERSON(M7) |
| A-M2 HTTP 怎麼開 | 每臂標 RB / R | ✅ |
| A-M3 / B-M4 手機 | §4.3、H4-U4 | ✅(preflight 5、同路徑正向、MAC、行動數據) |
| A-M4 / B-M7 發送端 | §4.5 ethsim | ⚠️ 04 上的工具做不到設計寫的事(M3) |
| A-M5 / B-M9 D-17 / fw-badinclude | §8.3 | ✅ 主體;「斷網」條件沒寫(m) |
| A-M7 探針 | §7 | ⚠️ 用到 04 沒有的 `nc -l`;基準 sha 會被計數器改掉(M3、m) |
| A-M8 副作用 / kernel 壞掉 | §13、§8.1 壞 rootfs | ⚠️ 截斷不保證觸發 panic(M9);dead-man 不還原防火牆類狀態(M2) |
| B-M1 接縫契約 | §5 | ⚠️ provd 的「本次 pid armed 行」做不到(m);P3 列的 `provd-id-pid` 漏掉、被換成放錯元件的 `ac-id-pid`(M5) |
| B-M2 / A-m4 鑑別 | §6.2 W / S / P | ⚠️ 多列 W 在 wsl.22 上只會 INVALID、或只在「動詞不存在」那一步 FAIL(M6);有幾列 S / P 分不出對錯(M4) |
| B-M3 pre-P3 | §6.1 結構判斷 | ✅(建議改用 BATMAN_FEATURES,m) |
| B-M5 Windows | 核心在 WSL | ✅;但「秘密不經 Windows」的說法要修正(m) |
| B-M6 BLE | §4.2;SD3 只掃描 | ❌ 只掃描分不出是 04 還是 02 的廣播(M4) |
| B-M8 dead-man / lease | §4.4、§11 | ⚠️(M2) |
| B-M11 成本 | §14 | ✅(使用者決定) |
| B-M12 / A-m8 生命週期 | §11 | ⚠️ 缺「主機死在防火牆停掉的窗口」等(M2) |
| 其餘 MINOR | 附錄 B | ✅ 大致都處理;個別見下 |

---

## BLOCKER

### B1 — S0 與 `s0_assert` 依賴 P3 的動詞:在 wsl.22 上建不起來、斷言不會成立 → 每個單位在 wsl.22 上都 INVALID,附錄 A 的 W 型負對照一條都收不到

**情境**
1. §3.1 S0 要:每台兩位擁有者(H0 + H0b,`owner/add`)、手機 AP = C0(**key 20**)。§3.1 的 `s0_assert` 要 `settings.get` 的 SSID = C0。
2. 這三個動詞在 wsl.22 都還沒有:`owner/add`、`settings/get`、`settings/set` 都在 `p3Types`(E7)→ `E_UNSUPPORTED`。
3. 新卡在 wsl.22 上認領之後,手機 AP 仍被 keyguard 關著(P3 F74;chain1 步驟 5 斷言 `ap=0`),而打開它的唯一產品路徑就是 key 20(P3 §3.11-6)。所以 wsl.22 的 S0 連「手機在 04 的 AP 上」都做不到。
4. §6.2:W =「wsl.22 上這條斷言 FAIL(`--pre-p3-full`)」,而且是 **H4 PR 要附的 ✅ 原始輸出**(§6.2 表、§14「`--pre-p3-full` 只在 H4 PR 做一次,約 6 小時」、§15 第 5 步)。
5. 每個單位開頭都是 `s0_assert`,不成立就 INVALID(§3.1、§11 第 1 列)。在 wsl.22 上它**一定**不成立(第 1–3 點)→ 所有單位 INVALID → 沒有任何 FAIL 行可以當 W 證據。
6. §15 的順序也互相矛盾:第 6 步「D20 重燒、`prov-bench-s0-254 provision`」排在 harness PR merge(第 7 步)之前,而 P3 D1 規定 H4 先 merge、P3 才開始實作 → S0 provision 時節點上還沒有 P3,做不出來。
7. F 載具上的 wsl.22 基準(§6.2「F 載具在 wsl.22 上跑一次」)也照 chain1 的前提「A committed $V,payload 版本 = V」(E11):如果 bench 那時已是 P3 rc,A ≠ wsl.22,前提不成立;設計沒寫 F 怎麼支援「V ≠ A 的版本」以及 restore 時 B 要寫回什麼。

**證據**:E7;P3 §3.11-6、F74;chain1 `:186-196`、步驟 5 的 `ap=0`;H4 `:142-146`、`:420`、`:426`、`:599`、`:615-616`。

**修法**(要先決定再寫,列給使用者):
- 分兩個基準:**S0w**(pre-P3:H0 單一擁有者、N0、AP 由 root 以 uci 開成 C0 並記錄)與 **S0**(P3);`s0_assert` 依 §6.1 的 build 判斷選版本,pre-P3 版只用 P2 有的東西(`auth/owner`、STATUS、root 讀 uci / hostapd)。
- 或者:W 證據改在 D20 **之前**、對現在的 legacy wsl.22 節點收(L 型 S0w),並把每列 W 對到它在 legacy 上會 FAIL 的那一行。
- §15 改寫:S0(P3 版)在第一個 P3 rc 出來後才建;H4 PR 只附 S0w 上的 W 與 C 載具的結果,其餘標 ❌ 並列為 P3 PR 的閘門。
- F 的 lib 支援 `V ≠ A`(wsl.22 新卡在 P3 bench 上),寫明 restore 後 B 的內容。

---

## MAJOR

### M1 — 要跨重開的接縫做不到:bind 與 `/tmp` fault 檔重開就沒了,`upper-helper` 只影響**目前槽**;UD16(D-9)與 UD12 的 S 負對照沒有載具

**情境**
- UD16(D-9「試用轉 committed 時存一次」)的負對照寫「`p5-autosave-off`,在 T 之前以 `upper-helper` 放進去,撐過重開」(`:767`)。
  - T 的試用開在**另一個槽**。overlay 是每槽各自的(E1:A 的 overlay = p2 上 offset 116 MB 的 loop),A 的 upper 不會出現在 B 的試用裡。
  - 就算 helper 二進位跟過去,`p5-autosave-off` 是 Go fault,要 `/tmp/run/batman-prov-test/fault.helper`(§5.1),在 tmpfs,重開就消失。
  - 結果:試用裡跑的是 V 的 release helper、沒有 fault → 負對照永遠看到「已存」→ 這列的 S 不存在。
- UD12(升級臂)的 S 同樣是 `p5-autosave-off`(`:763`):「存一次」發生在 sysupgrade 之後**第一次非試用開機**的 helper 啟動時(P3 §3.3)。那次開機的 helper 是新槽的 release helper,fault 檔不在 → 一樣做不到。等到之後再 `push-helper` 時,release helper 已經存過了,p5 已 fresh,看不到 stale。
- §2 RB 的「不能做什麼」欄寫「用 update-last 或 `upper-helper`」,把 `upper-helper` 當成跨槽可用,這個前提不成立。

**證據**:E1;`prov-wbox-254.sh` 的 `upper-helper` 寫 `/usr/bin/batman-provhelper` 並檢查 `/overlay/upper/...`(只對目前槽);P3 §3.3「helper 在非試用的開機時…」;H4 `:116`、`:763`、`:767`。

**修法**:二選一,寫進 §5 契約交給 P3:
- (a) prov_test helper 另讀一個 **p6** 上的 fault 檔(例如 `/opt/batdata/state/prov-test-fault`,root 0600、帶 boot 次數上限、dead-man 與 P9 都檢查),而 T 的 V 是 **prov_test 版 payload**(不是 `-wbox` 戳記,否則不會 commit,見 `batman-autocommit:485-530`);這要寫明 release gate 怎麼證明 release 不讀它。
- (b) 承認 D-9 與升級臂的負對照只在 Go 單元測試,節點上只有正向;寫進附錄 A 並請使用者決定。

### M2 — dead-man 的涵蓋範圍與續期格式:主機死在「防火牆被停 / 規則被改」的窗口時,04 會一直沒有防火牆;新卡的期限用 uptime 不帶 boot_id;LR1 的 firstboot 會清掉 B 上的 dead-man

**情境(使用者遠端、主機在單位中途死掉 / 睡眠 / Windows 更新重開)**
1. **防火牆類狀態沒人還原。** lease dead-man 只做 unbind、刪 fault、服務重啟、radio 還原(E10);§11 第 3 列只再加「fault 關閉、ethsim 刪除」。下列臂改的狀態都不在其中:
   - HT14 `/etc/init.d/firewall stop`:fw4 與 docker 的 nft 表全刪(F-H17),fw4 input `policy drop` 也沒了(E3 的 chain 整條消失)→ 04 在 mesh 上**所有埠**都開著(dropbear、uhttpd、OTS)直到有人回來;
   - HT18 `auto_includes = 0`(若有 commit,重開後仍在);
   - HT19 外來的 bit-24 規則;HT20 更早優先序的打 bit 規則;
   - HT21 `ip link set phy1-ap0 nomaster`(手機 AP 上所有 EUD 斷網);
   - ST13 `/tmp/.uci/wireless` 暫存(之後所有 key 2 / 20 都 `E_BUSY`);
   - ST11 持鎖 15 s 的 `flock`(若以 setsid 起);
   - §7 探針載入的 v6 / v7 表、`nc`(或替代)listener、暫時改成 C0 的 04 AP。
   
   「下一個 run 看到 dirty → 印 restore」只對下一個 run 有用,遠端時節點會在無防火牆的狀態下放著 → 違反 fail-secure 預設(全域規則 5)。
2. **`fresh-deadline` = `<run> <uptime 秒>`**(`:287`、`:515`)。uptime 每次開機歸零,但 F 載具內會重開(步驟 6 的 reservation reboot、LR1 的 firstboot 重開、`prov-update` 等)。重開之後舊的期限值變成「新開機後的 N 秒」→ 主機剛好在重開前死掉時,dead-man 要等「舊 uptime + 30 分」才觸發;反過來也可能立刻觸發。
3. **LR1(`prov-luci-reset`,只在 F 的 B 上做)會跑 `firstboot -r -y`,清掉 B 的 overlay**,而 dead-man 的觸發點就是 B overlay 裡的 `/etc/rc.local` 加一個 setsid 迴圈(§4.4、E11)。重開後 rc.local 那行沒了、迴圈也沒了,p6 的期限檔沒人讀 → 04 停在新卡 B、離開 mesh。
4. **兩個 dead-man 同時在 B 上**:F 內如果重新 acquire prov lease,lease dead-man(啟動 joinwatch / openmanetd、`provd_restart`)與新卡 dead-man(停 openmanetd、`p5-restore`、rollback、重開)可能同時觸發 → openmanetd 與 p5 兩個寫者。chain1 的 snap 是以 `KEEP_JOINWATCH_STOPPED=1` 做的,lease dead-man 把 joinwatch 啟動起來也會在新卡上動 p5。§9 擁有權表兩個都列了,但沒有先後。

**證據**:E3、E10、E11;F-H17;H4 `:287`、`:515`、`:525`、§13 的 HT14 列。

**修法**:
- 每一個改防火牆 / bridge / uci 暫存 / AP 的臂,先在節點上寫一個 **還原記錄**(root 0600、p6 或 tmpfs,依需不需要撐過重開),lease dead-man 讀它並還原(`firewall start` → `dockerd restart` → 斷言 `nft list tables` 與基準相同;`ip link set phy1-ap0 master br-ahwlan`;`uci revert wireless`;刪外來規則;`auto_includes` 改回)。lease 契約的擴充寫成一條清單,並給每一項一個「dead-man 臂」測試(不續 lease → 等 dead-man → 斷言還原)。
- HT14 的窗口要短(≤ 60 s 即 `firewall start`),並在 EXIT trap 之外加一個節點端的 `setsid sleep N; firewall start` 保險。
- `fresh-deadline` 改為 `<run> <boot_id> <uptime>`:boot_id 不同 → 以「本次開機 + 剩餘時間」或直接觸發(寫明哪個,fail-secure);每次 B 開機後主機要重新斷言 rc.local 那一行與迴圈存在(LR1 之後一定要重種,並把它寫成 LR1 的步驟)。
- 新卡期間的 lease dead-man 讀 `fresh-deadline` / dirty flag:是這個 run 的新卡就只做 unbind / fault,不動服務(或由新卡 dead-man 設 h23 的 `restoring` 標記)。

### M3 — 04 上沒有設計寫的工具:`nc` 不能 listen、沒有 `-w`、沒有 `timeout`、沒有 `ss`;50 conn/s 的洪流會在 04 上堆出數千個卡住的行程

**情境**
- §7 第 2 步「探針在 04 上起 `nc -lk -p 8095`(busybox)」:04 的 busybox `nc` 只有 `nc [IPADDR PORT]`(E2),沒有 server 模式。**§7(H4 凍結的閘門)第 2–3 步照寫做不了。**
- §4.5 mesh 臂「netns 內 busybox `nc` 迴圈連 `<04>:8095`(50 conn/s × 10 分)」:這個 `nc` 沒有 `-w`,04 也沒有 `timeout`(E2)。被丟掉的 SYN 會讓每個 `nc` 等到 kernel 放棄(`tcp_syn_retries = 6` ≈ 127 s)。50/s × 127 s ≈ **6,000 個同時卡住的行程**在 DUT 上(OTS 也在跑)。設計也沒寫怎麼把「timeout(丟棄)」與「refused」分開(§4.3 的分類只在手機 relay 上)。
- P 的定義與 HT12 / HT15 用 `ss -ltn`(`:422`、`:722`):04 沒有 `ss`,只有 busybox `netstat`。
- lo 臂「04 本機 `nc 127.0.0.1 8095`」同樣會卡 127 s。

**證據**:E2。

**修法**:
- listener 改用 04 現有的東西並先唯讀實測:例如 `iperf -s -p 8095`、`openssl s_server -accept 8095`,或 `uhttpd -p`;斷言改看 listener 端的接受紀錄 + nft counter。
- 發送端:在 netns 裡 `sysctl -w net.ipv4.tcp_syn_retries=1`(netns 自己的值,不影響 04 本體),並以 `(nc …) & sleep 2; kill $!` 的方式限時;並發數設上限並在臂內斷言行程數 ≤ 上限。
- 或推一個靜態 aarch64 小工具(sha 釘死、只放 tmpfs、EXIT trap + dead-man 刪除),列入供應鏈與 P9。
- 所有 `ss -ltn` 改 `netstat -ltn`(或 `/proc/net/tcp` 解析)。
- 這些在 E-H15 實測時一起驗。

### M4 — 幾個判定在真機上分不出對錯(或一定 INVALID)

1. **SD3 / HT8(b)「BLE 廣播在」以桌機掃描判斷**:廣播只有服務 UUID(E5),02 廣播同一個 UUID,位址是 RPA 且約 15–17 分換一次。桌機掃到 UUID 不能證明是 04 的。P3 正要改的就是「撤廣播只看 BLE」(`bluez.go:772`,現在 HTTP session 也會讓它撤);如果 P3 rc 把這點做錯,04 撤廣播、02 仍在 → 這條斷言照樣 PASS。
   修法:在 04 端判:provd log 的 `withdraw` / `register` 行在臂內的次數、或 root 讀 BlueZ 的 `ActiveInstances`;或者臂前以 STATUS 驗證過的連線取得 04 目前的 RPA,臂內只認那個位址,遇到 rpa_timeout 就重驗。
2. **SD3 的 P「helper 的 ro 計數 ≥ 5000」**:P3 §2 的 ro 連線是每連線 5/s(超過只回 `E_RATE` 給 app)。10 分鐘最多約 3,000 次到達 helper,5,000 **永遠達不到** → 這臂一定 INVALID。修法:P 改成「provd 收到的 app 請求 ≥ 5,000,且 helper 的 ro 約 5/s 飽和(例如 ≥ 2,700)」。
3. **UD19(D-12 `update.check` 不拿 `n.mu`)**:provd 的 ops 一次只跑一個,在跑時新的直接 `ErrBusy`(E6)。`settings.set` 佔著 ops 時送 `update.check`,provd 在送到 helper 之前就回 `E_BUSY` → 不管 helper 有沒有拿 `n.mu` 都一樣 → 不鑑別。修法:改成 Go 單元測試(helper 層),或經 provclient 第 4 條連線直接打 helper(遵守 §2 的「不與 app 讀取並行」),並把 W 改成 S(拿 `n.mu` 的 helper 變體)。
4. **HT3 的 S「`healthok-2field` → 不同的開啟時點,只在 RB 上」**:
   - HT3 本身在 R,S 在 RB → 換了載具(provd 二進位不同),違反 §2 的 flip 規則;
   - 停 bluetoothd 時,兩欄版與完整版都會判不健康 → 開啟時點一樣 → 分不出來。這個 fault 的鑑別在 HT4(`sc_file`),HT3 應該只標 P。
5. **HT11 docker 臂「被丟」**:`br-ots` 的 fw4 zone input 本來就是 DROP(E3)→ 沒有 P3 也被丟。要鑑別就必須斷言 `inet batman_http_in` 的 drop counter 增加(它在 priority −10,先於 fw4),否則這臂沒有資訊量。P3 §8 另外要求「docker0 容器送 **VLAN 封裝**的 SYN」,HT11 沒有 VLAN(見 m)。

### M5 — autocommit 臂的接縫放錯元件;P3 列的 `provd-id-pid` 漏掉

**情境**
- P3 §3.7.6(b):**helper** 以 SO_PEERCRED 的 PPid = ujail instance pid、uid 471、exe 辨識 provd,連續 60 s 才寫 `$RUNDIR/provd-stable`;autocommit 只讀那個檔。P3 §8 的接縫表因此列 `provd-id-pid`(「provd 辨識改回 peer pid = instance pid」),是 helper 的 Go 接縫。
- H4 §5.1 的 helper fault 清單沒有 `provd-id-pid`;§5.5 改成 autocommit 變體 `ac-id-pid`(`:404`),AC4、AC5 的 S 都用它(`:779-780`)。autocommit 的變體改不到 helper 的辨識邏輯 → 這兩列的 S 不存在。
- 在 RD(committed 槽)上,本次開機的 `provd-stable` 早就被 release helper 寫好了。就算改成 helper fault 並 `push-helper` 重啟,P3 沒說 helper 啟動時會刪掉它 → dry-run 照樣看到檔 → COMMIT → 不鑑別。
- AC6(provd 被停用 → 只 WARN)的 S 用 `ac-helperoff-err`(那是 D-16「helper 被停用」的變體)→ 對錯了對象;AC6 需要的是「不看 provd `enabled`」的變體。

**證據**:P3 §3.7.6、§8 接縫表;H4 `:404`、`:779-781`。

**修法**:§5.1 加 helper fault `provd-id-pid`;AC1 / AC4 / AC5 的流程寫明「先刪 `$RUNDIR/provd-stable` → 重啟 helper(帶或不帶 fault)→ 等 ≥ 60 s → dry-run」;AC6 換成正確的變體(例如 `ac-provd-required`)。同時把「helper 重啟時是否重算 `provd-stable`」列為 P3 要寫明的契約。

### M6 — W 的分類太粗:HTTP 類的 W 在 wsl.22 上只會 INVALID;多數 W 只在「動詞不存在」那一步 FAIL,真正要鑑別的子斷言沒有前提證據

**情境**
1. **RT2(key 20 經 HTTP)、HT6(psk_owner → 候選)、HT7(NX / psk_replay 被拒)標 W**(`:634`、`:716-717`):wsl.22 沒有 HTTP 監聽,也沒有 `bulk.open` 可以開窗 → 這三臂連 session 都建不起來 → 依 §3 / §6 的規則是 **INVALID**,不是 FAIL。H4 PR 要附的 W 證據不存在。修法:HT7 用 S(例如 provd fault「HTTP 收 NX」);RT2 / HT6 改「—(wsl.22 無 HTTP)」並明列由 S 或 P3 PR 補。
2. **只在 `E_UNSUPPORTED` FAIL 的 W**:例如 UD5「之前退回同一槽的 bad-slot 不造成假 6」、UD10「helper 重啟後 phase 3 重建」、ST16「同值 set 在 stale 時存檔」、ST13「暫存 → `E_BUSY` + `status` 回報」、SD2「成員只拿摘要」、UD13「SSID 含 `'`」。在 wsl.22 上,第一個呼叫就 `E_UNSUPPORTED`,後面的子斷言(bad-slot 標記真的在、helper 真的重啟、p5 真的 stale、`/tmp/.uci/wireless` 真的非空、session 角色真的是成員、SSID 真的含 `'`)從沒被評估過。到了 P3 上,如果前提沒造出來(例如 bad-slot 標記沒寫成),這些斷言會空著 PASS。
   修法:附錄 A 每列 W 寫出「wsl.22 上預期 FAIL 的那一行」;凡是 W 只在動詞層 FAIL 的,一律加 P(同臂先證明前提)。全域規則:「沒東西可檢查就要 FAIL」。

### M7 — release(R)上「T 簽的 manifest 被拒」沒有排進常規,被丟進 YubiKey 的 NEEDS-PERSON

**情境**
- P3 §8 `prov-update` 的 bench 臂:「YubiKey K 簽、release 設定節點、**T 簽的被拒**」。H4 UD15 把整列寫成 NEEDS-PERSON(`:766`)。
- 「T 簽的被拒」不需要 YubiKey:在 R(release helper)上送 T 簽的 manifest → 期望 `update.check` reason 11。這是整個 T 方案唯一的安全閘:T 的私鑰公開在 repo(§8.1),而 H4 要求「T 的信任以 build tag 編進 prov_test helper」(§1.4)。build tag 一旦漏進 release,任何拿到擁有者 session 的人都能推任意 image,而現在沒有任何常規臂會發現。
- 同時,它是 RB 的單變數 S:同一個 manifest,R → 11、RB → 通過。

**修法**:新增 UD-T1(R 載具,常規,每個 rc):T 簽 → reason 11;負對照 S = 同一個 manifest 在 RB 上通過。release gate 的「release 不含 T」也以這個行為判斷,不是只 grep 金鑰位元組。

### M8 — 生命週期與 P3 §6 對不起來的幾列

1. **降級到沒有 P3 的版本(P3 §6)**:UD11「回滾臂 | T | 回到舊槽;舊槽的 P3 狀態 | W」(`:762`)。P3 §6 要的是:舊槽**沒有 P3 動詞**、`.txn` 格式相容、舊版整檔比對判 stale 直到它下一次 `--save` / `--on-join`、p5 多出的 ssid 行被舊版 96 照樣套用、update-last 留在 p6 無人讀。H4 沒寫怎麼讓另一槽是 wsl.22(T 的 V 是 P3)、也沒有這些斷言;「W」對這一列沒有意義。
2. **helper 在 apply 之後、重開之前掛掉 → 同一次開機重啟時 disarm、報 3**(P3 §3.7.4 狀態表 B6 那一列):附錄 A 沒有。UD3 / killpoint 用的是 sysrq 重開(= 斷電),不是同一次開機的 helper crash。這一列擋的是「tryboot 旗標留著,下一次無關的重開才進試用」,是安全相關的。修法:`UpdAfterArm` 之外加一個「arm 後 kill -9 helper(不重開)」的臂,斷言 `batman-slot` 的 tryboot 旗標被清、phase 3。
3. **升級到 P3 的「已入網」那一半**(下一個 joinwatch tick 存 p5):UD12 只做未入網。
4. 其他漏或不清楚:provd **正常停止**(P3 §6「停止 → HTTP 關,上傳檔由 helper 在窗到期或下次啟動時刪」;HT16 只有 kill);provd **crash loop**(`respawn 3600 5 0` 用完後);**重開 → pending 消失**(P3 §6「重開」列)。

### M9 — 「壞 rootfs」用截斷不保證會 panic,結果取決於 B 分割上原本留著什麼

**情境**
- §8.1:root.squashfs 截斷、`SHA256SUMS` 用截斷後的 sha。squashfs 的 inode 表、目錄表、fragment 表、id 表都放在**檔案尾端**,superblock 記的 `bytes_used` 仍是原值;分割比檔案大(1.5 GB),所以 mount 時 superblock 檢查會過,讀尾端的表時讀到的是**分割上原本留著的位元組**。
- `batman-slot write` 只 dd 截斷後的長度,不清後面。§13 寫「B 留著 V(brewrite)」:B 上原本就是同一個 V → 被截掉的尾端在分割上原封不動 → 照常開機 → 不 panic → UD4 走不到要測的路。B 上若是別的 image,才會讀到垃圾而 panic。
- UD4 有 P(要看到 panic 行),所以不會假 PASS,但每次結果取決於前一個單位留下的 B → 不確定、浪費使用者在場的那一次(E-H13)。

**證據**:squashfs 格式(表在尾端、superblock 的 `bytes_used`);04 `/proc/partitions`(p2 / p4 = 1,572,864 KiB);H4 `:465-467`、§13 prov-update 列。

**修法**:改成「長度不變、破壞 superblock 的 magic(前 4 bytes)」,`SHA256SUMS` 用破壞後的 sha → mount 一定失敗 → `VFS: Unable to mount root fs` → `panic=10`(F-H16 已驗)。這樣與 B 原本的內容無關。E-H13 的第一次仍要使用者在場。

---

## MINOR

1. **T 載具的 V 沒定義。** V 是哪個 build、版本規則怎麼過(建議 V = 受測 rc 本身、走「同版本重裝」)、做完 commit 之後 04 停在 B 上的 V,之後的單位跑的是哪個 image。`s0_assert` 要加「目前槽 + `BATMAN_VERSION` = 受測 image」,否則 T 單位之後的結果會記到別的 build 上。
2. **UD2「同版本重試退回」怎麼讓試用退回**沒寫(hold 不 release 等 600 s 期限?);UD7「serial < min」要 prov_test image 的 `min-serial ≥ 2`,否則 serial 0 會先因 CDDL(uint ≥ 1)以別的原因被拒。
3. **bind 封閉清單要擴充**,並寫明理由:`/usr/bin/batman-provd`、`/etc/init.d/batman-provd`(§5.3)、`/sbin/uci`(§5.5)、UD18 的 `batman-slot` 變體(與 h23 r2 A-m5「never batman-slot」衝突,E9);killpoint 的名字清單(`:50`)也要加 `UpdWriteMid` 等,並統一命名格式。`uci-argv` shim 要呼叫 `/rom/sbin/uci`(bind 不影響 lower),寫明。
4. **provd 的「本次 pid 的 `armed` 行」做不到**:provd 在 jail 的 pid namespace 裡記 `batman-provd[1]`(E9 `:149`)。改照 `set-provd-env` 的做法:新 pid 的 environ + 「新出現」的 armed 行計數。`unbind-all` 解 provd bind 時也要重啟 provd 並斷言(現在只在 helper 被 bind 時重啟)。
5. **§7 第 1 / 6 步用 `nft list ruleset | sha256sum` 當基準**:fw4 與 docker 的計數器一直在變(第 1 輪 B E6:`accept_to_ahwlan` counter 146755 …)→ 一定對不上。改用 `nft -s list ruleset`(stateless)或只比表名與規則文字。
6. **VLAN 臂的機制沒寫完**:`q0.0` 要 IP 與靜態 neighbor(04 回的 ARP 是不帶標籤的、送到 `h4v1`,不會到 `q0.0`);SYN-ACK 也是不帶標籤回 `h4v1`。04 的 rp_filter 是 0(E4),新 netns 的預設也要寫明並斷言。§7 第 5 步「v6 → 放行」的證據要是「SYN 到了 inet input(counter)+ listener 收到」,不能只看 nc。
7. **D-4 / P3 §8 的 mesh 臂要「手機 MAC + IP(含 ARP 毒化)」**:HT8(a) 只偽造 MAC,netns 用的是 10.41.250.x。補上手機 IP;ARP 毒化可以由 netns 以手機 IP 為來源送出的 ARP 請求自然達成(寫明)。
8. **P3 §8 VLAN 臂要「eth0 **與 docker0 容器**」**:H4 只有 br-ahwlan 那一路;br-ots 那路要 VLAN 雙層 + counter(見 M4-5)。
9. **`fw-badinclude` 的「斷網」**:P3 §6 的條件是「非 DUT、使用者同意、**斷開對外網路**」。02 經 04 的 mesh 可以出網,§8.3 只寫「只在實驗室的 mesh 上」→ 與 P3 不符,要寫明怎麼斷(例如那段時間 04 FORWARD 擋 02 的來源),或列給使用者決定。
10. **金鑰庫的信任邊界寫得太強**:§3.2 / §4.1 說「WSL 0600 有效、秘密不經 Windows」;但同一個 Windows 使用者的任何行程都能經 `\\wsl.localhost\Ubuntu-24.04\home\yello\…` 讀到這些檔(9P 以預設 WSL 使用者身分存取),Windows 備份目錄的 ACL「只限目前使用者」也一樣。對 bench 測試值可以接受,但要照實寫成誠實界線(行為者:同一 Windows 使用者下的本機行程)。
11. **C0 怎麼交給使用者輸入手機**:§7 寫「密碼不進對話」,但手機要存 C0 只能人輸入(Termux 沒 root 加不了 Wi-Fi 網路)。寫明交付方式(例如只在桌機本地畫面顯示 QR)。
12. **手機 IP 的找法**:`ip neigh` 只有 04 跟手機說過話才有;DHCP 可能由別的節點發。加上讀 DHCP lease 檔的路徑。
13. **供應鏈**:Windows 端的 bleak / winrt、Termux 的 python、要安裝的 qemu-user-static 都沒有版本 / hash 釘選(WSL venv 有,H4-U6)。
14. **E-H16 現況是「沒有」**(E12)。`prov-eeprom-hooks` 照設計會 FAIL 到使用者同意安裝為止;可以考慮改用既有的 CI arm64 沙箱(F-H22)跑 uci-defaults,免動主機。
15. **OW4 的順序與期望值**:§3.2 寫「H0b、H0、Hx」,A.2 寫「H0b、Hx 後再 H0」;期望值寫「依既有規則」。依 `node.go:890`(E8)最後一位一律 `E_FORBIDDEN`,請寫成精確的碼,順序統一;並寫明主機在「H0b 已刪」時死掉的復原(journal)。
16. **ST4 沒有負對照**(只有 P):加一個 S(讓 setkey 走 `wifi` 全重啟的變體 → `connected time` 歸零),證明量測抓得到斷線。
17. **ST7、ST19、UP10 的 S 是「不注入 → 正常」**:那是前提對照,不是負對照(沒有證明「少了處理就會 FAIL」)。至少改標 P,並說明真正的負對照在 Go 或沒有。
18. **UP7 的 S(`upload-nobusy`)會讓 `network/update` 真的套用**:那一刻 04 的網路設定被改、mesh reload。寫明送的是與現值相同的 `net_config`,並列進副作用。HT8 的 S(`http-nofw` + 不載表)那段時間 HTTP 對整個 mesh 開著,也列進副作用。
19. **D-17 的假 `nft` 靠 PATH**:autocommit 不重設 PATH(E13),今天可行;但要寫進 §5 契約「P3 的 `inet fw4` 檢查以 PATH 呼叫 `nft`」,否則 P3 寫成 `/usr/sbin/nft` 這臂就失效。也可改成 bind 一個假 `nft`(加入封閉清單)。
20. **pre-P3 判斷**:「沒有 `batman-http.nft` 且沒有 `release-root.pub`」在 P3 rc 打包漏檔時會被誤判成 pre-P3、被 known-failures 吞掉。建議改看 `BATMAN_FEATURES` 的 P3 標記(04 現在就有這一欄,例如 `provd-p2(#254)`)。
21. **對表 lint 的「片語 ID」沒有定義**:P3 文件沒有 ID;A.11 的「D-12 → `ST*`」也不是列號。定義 ID 的產生方式(例如 P3 §8 每格以 `;` 切開後的正規化雜湊),並讓 D-12 對到具體列(ST13 + 「SSID 無法保存」的 `status` 回報 + UD19 的替代)。
22. **F 載具的細節**:F 由誰認領(臨時擁有者 HF,狀態放 run 目錄,不寫進 bench 庫)、blebridge 認目標要用新卡的**新序號末 4 碼**(p5 mkfs 後身分是新的,chain1 的 `L4N`)、新卡在認領前 root 是 `none` 登入(chain1 `:33-40` 的註解)→ 這段時間 lab LAN 上任何人都是 root,列進副作用。

---

## 其他查證(✅ 成立 / ⚠️ 推論)

- ✅ F-H4(`node.go:198-206`)、F-H5(`batman-autocommit:485-530`)、F-H9(`prov-wbox-254.sh`)、F-H10(dry-run `:26-27`、`:69`、`:323`)、F-H11(`batman-provd-test.init` 的 `_provd_env` 只收數字)、F-H16(`panic=10`)— 原始碼 / 節點輸出如上。
- ✅ 加 veth 到 `br-ahwlan` 不會改 bridge MAC(`addr_assign_type = 3`),MTU 由最小的 port 決定(eth0 / bat0 = 1460),10.41.250.x 不在 DHCP 範圍。`/etc/hotplug.d/net/` 只有 `00-sysctl`、`50-trelay`(trelay 只在 `/var/run/trelay.active` 存在時動作)。helper 的前提檢查只看 `phy*` 名字的 port(P3 §3.8.1),`h4v0` 不影響。⚠️ batman-adv 會把 netns 的 MAC 當成 04 的本地 client 宣告到 mesh(無害,但 E-H15 實測時看一下 `batctl tl`)。
- ⚠️ E-H12(ujail 看得到 bind 後的 provd):ujail 以 `procd_add_jail_mount "$PROG"` 從父 namespace bind 同一路徑,而父 namespace 的路徑已是 bind 後的檔,所以推論成立;仍照設計實測。`/etc/init.d/batman-provd` 的 bind 對 `rc.common` 也成立。
- ⚠️ D-1 經 veth 的 VID 0 雙層:veth 收到的外層標籤在 bridge 前不會被剝(`vlan_do_receive` 找不到 vlan dev → 交給 bridge 的 rx_handler),本機收的路徑在 `br-ahwlan` 上走 `check_vlan_id` 剝掉外層 VID 0 → 與 eth0 的接收路徑一致。推論,未實測(§7 會測)。
- ⚠️ tryboot 一次性:設計依 F-H16 與既有 A/B 文件;我沒有另外查韌體文件。
- ⚠️ chain1 回歸「59 PASS / 0 FAIL」:我沒有找到那份 log,未查。

## 判決

**REJECT。** B1 不改,H4 PR 收不到任何 W 證據,而且 S0 的建立順序與 P3 D1 矛盾。M1–M9 都是「照寫在真機上做不到 / 分不出對錯」,每一項都附了唯讀證據與修法。**設計尚未收斂**:B1 與 M2 會改動 §3、§4.4、§11、§15 的結構,修完請送整份重審。
