# H4 harness 設計 v3 — 審查 A(第 3 輪)

- 審查對象:`docs/design/254-h4-harness.md` v3(branch `harness/254-h4` @ 282b48b),**整份**。
- 上層:P3 `254-p3-impl.md` v7.1(`feat/254-p3` @ dfedd03)§2/§3/§5/§6/§7/§8/附錄 D;h23;程式 = `/home/yello/Batman` main 2ecf1cb。
- 方法:先逐條核對 v2 兩份報告(A 1/9/22、B 1/10/19)在附錄 C 的處理是否真的成立;再從實際使用出發(使用者常不在、一次現場、S20、Windows + WSL + bleak)把 §2–§8 每個機制對回原始碼與 04/02 的唯讀輸出;最後逐列看附錄 A 的 W/S/P/G。
- 節點只做唯讀(`cat`、`ls`、`uci show` 濾 key、`ip -br`、`nft list tables`、`wget --help`、`/proc/cmdline`)。沒有改節點、沒有連 BLE、沒有改 repo(只寫本報告)。
  - 自我更正:我有一次指令誤夾了 `ip netns add`(會改狀態),被權限系統擋下、**沒有執行**;之後的指令都只做讀取。

**結論:REJECT — 0 BLOCKER / 4 MAJOR / 17 MINOR。**
**收斂判斷:骨架已收斂**(載具、S0-pre/S0、undo journal、W/S/P/G 制度、附錄 A 都站得住,v2 的 BLOCKER 已解)。這 4 條 MAJOR 都是局部的事實錯誤或契約缺口,各自一兩段就能修好,不需要重寫。修完後依規則要整份再審一次。預期下一輪可以核准。

---

## 0. 我取得的證據(原始輸出節錄)

**E1 — fresh 卡沒有 mesh;02 的 eth0 沒接;claim secret 只在節點上**
```
# 02(唯讀)
$ cat /sys/class/net/eth0/carrier /sys/class/net/eth0/operstate
0
down
$ ls -l /etc/batman-prov/identity/
-rw-------  root root  32 Oct 19 23:18 claim.secret
...
# chain1-254.sh:265  新卡(unclaimed)試用的斷言:"ap=0" "mesh=0" "meta=unclaimed"
# provclient/main.go:512-517  claim 讀節點上的 /etc/batman-prov/identity/claim.secret(root 0600)
# node.go:520-522  claim.verify 以 KS.CheckMac(... ) 驗 → 沒有 claim.secret 就認領不了
```

**E2 — `batman-slot apply` 寫入前先檢查 squashfs magic**(`batman-slot:616`)
```
[ "$(hexdump -n4 -e '4/1 "%c"' "$SQ" 2>/dev/null)" = hsqs ] || die "payload rootfs is not a squashfs"
```
另外 `:36`:`CMDLINE_COMMON="… rootfstype=squashfs,ext4 rootwait=20 panic=10"`;`:378`:無效槽本來就用「不存在的 PARTUUID + panic=10」→ panic 後回預設槽(既有機制)。

**E3 — `dv-sbx.sh` 拒絕在非 CI 執行,隔離只防意外**(`scripts/dv-sbx.sh:3-10, 44`)
```
# ONLY on a throw-away CI runner (ubuntu-24.04-arm; GITHUB_ACTIONS set) — refused anywhere else, a developer machine
# included (§4.10; review 2026-10-28 A-M4: it had been run as root in WSL).
# WHAT THE ISOLATION IS (review B-M2): accident isolation, not containment. ... keep CAP_SYS_ADMIN in the initial user namespace
[ "${GITHUB_ACTIONS:-}" = true ] || { echo "FAIL dv-sbx runs only on a throw-away CI runner ..."; exit 2; }
```
`--base` 也必須等於 `tests/prov-p1/sbx/base.env` 釘死的 sha(`:62`),所以不能直接換成 wsl.22 / wsl.9 的 rootfs。

**E4 — P3 §3.8.1 的兩條規則沒有 `counter`**(`254-p3-impl.md:379-380`)
```
bridge batman_http, input:  iifname "phy*" meta mark set meta mark | 0x01000000
inet batman_http_in, input prio −10:  tcp dport 8095 meta mark & 0x01000000 == 0 drop
```
nft 規則不寫 `counter` 就沒有計數。

**E5 — 04 的 `wget` 是 uclient-fetch,不是 busybox**
```
$ busybox wget --help
wget: applet not found
$ ls -l $(which wget)
/usr/bin/wget -> /bin/uclient-fetch
$ wget --help
	--timeout=N | -T N		Set connect/request timeout to N seconds
```

**E6 — lease dead-man 等鎖 10 分後不拿鎖照做**(`ble-lib-254.sh:327-331`)
```
got=0; n=0; while [ $n -lt 20 ]; do lock 30 && { got=1; break; }; n=$((n + 1)); done
if [ $got = 0 ]; then dm_log "$run" "deadman: lock stuck 10 min — killing run $run groups, restoring without the lock"; ...
```
鎖是一個指令一把(`held()`/`unlock()`,`:313`、`:101`),不會跨整個主機端的 EXIT trap 一直持有。

**E7 — P2 的 `halow-setkey --ap` 把值放 argv、沒有 `--ap-ssid`;會解除 keyguard 對 AP 的封鎖並 `--save`**(`halow-setkey:45-48, 280-302, 165`);RadioManaged 節點只印 WARN 照樣套用(`:68-70`)。
→ S0-pre 在 04 上用 root `halow-setkey --ap` 設 C0 **可行** ✅。

**E8 — 其他已核對成立的事實**
- `network/join` 不在 `p3Types`,owner 可用(`session.go:61-79`)✅;
- `provclient … sock-as <uid> -- proxy` 存在(`main.go:485`、`:544`)✅;
- `batman_opf` 只認 root 擁有、單一 link 的 regular file,其他記 TAMPER(`rundir.sh:44-50`)✅;
- `/tmp/run` = `drwxr-xr-x root`(UP11 的前提)✅;
- 04 的 nft 表:`ip filter`、`ip nat`、`ip6 filter`、`ip6 nat`、`inet fw4`;docker0 DOWN;`firewall.docker.input=ACCEPT`、`ots_zone.input=DROP`(F-H26)✅;
- 04 的 `/proc/cmdline` 含 `rootfstype=squashfs,ext4 rootwait=20 panic=10`(F-H16)✅;
- `/home/yello/out/1.5.12-wsl.9+f2f2bf6.fw07f2063` 在本機 ✅(CI 沒有)。

---

## 1. v2 意見的處理(抽查附錄 C)

| v2 意見 | v3 是否解決 |
|---|---|
| A-B1 / B-B1 S0 在 pre-P3 建不起來 | ✅ 04 那一半:S0-pre 只用 P2 動詞 + root setkey(E7、E8)。**02 那一半做不到**(M1) |
| A-M2 / B-M6 / B-M7 dead-man | ✅ 主體(undo journal、HT14 保險、boot_id 期限、LR1 排最後)。殘留:互斥的說法與程式不符(m3)、保險不可取消(m4)、重開迴圈(m6) |
| A-M3 / B-M1 工具 | ✅ 大致。殘留:`wget` 是 uclient-fetch(m1) |
| A-M4 / B-M8 判定 | ✅ 廣播改在 04 端、SD3 改 peer 計數、UD19 走 provclient。新問題:判定靠的 counter 在 P3 規則裡不存在(M4) |
| A-M5 / B-M4 autocommit | ✅ |
| A-M6 W 太粗 | ✅(W 寫出 FAIL 行;只在動詞層 FAIL 的另加 P) |
| A-M7 / A-M8 / B-M9 漏列 | ✅(UD-T1、UD11、UD3b、UD12b、UD10b、HT16b/c、UP11、HT8 IP + ARP) |
| A-M9 / B-m8 壞 rootfs | ❌ 改法(破壞 magic)會被 `batman-slot` 先擋下(M2) |
| B-M10-2 / A-m14 E-H16 | ❌ 「先唯讀確認 dv-sbx 在 WSL 能不能用」:原始碼已經回答「不准」,而且這是先前明文的安全決定(M3) |
| A-m2 serial < min | ⚠️ 寫成「prov_test image 的 `release-min-serial` = 2」,但 RB 是 release image + bind 的 helper(m8) |
| 其餘 MINOR | ✅ 抽查都有落實(片語 ID、C0 QR、手機 IP、known-failures ERE、`nft -s`、靜態 neighbor、`provd[1]`、test init lint、pending-del、秘密原值 grep) |

---

## MAJOR

### M1 — 02 重燒後只剩 BLE 一條路,而認領需要只存在節點上的 `claim.secret`:S0-pre 的 02 那一半照 §3.1 / H4-U7 做不出來

**情境**:H4-U7 現場順序是「重燒 02 / 04 → harness 認領並建 bench 網路(S0-pre)」。§3.1 的設定者是「`peer.py`:BLE 認領 + `network/join`」;02 的 AP C0' 是「root 在節點上 `halow-setkey --ap`」。

**證據**:
- 新卡(unclaimed)沒有 mesh:`mesh=0`(E1,chain1 `:265`);
- 02 的 eth0 沒接(E1,carrier 0;F-H14);
- 新卡的 AP 也被 keyguard 封鎖(`halow-keyguard:29-39`),而且桌機的 Wi-Fi 拿去上網(F-H2);
- 所以重燒後的 02 **沒有任何 IP 路徑**。
- 認領要在客戶端算 `CheckMac(claim.secret, …)`(`node.go:520`;`owner.py:52`;provclient 讀 `/etc/batman-prov/identity/claim.secret`,`main.go:512-517`)。這把秘密是新卡首次開機時產生、root 0600,只有 root 讀得到。
- 結果:WSL 端的 `peer.py` 拿不到 02 的 claim secret → BLE 認領做不了 → `network/join` 做不了 → root `halow-setkey --ap` 也做不了(沒有 ssh)。

**影響**:
- 唯一一次現場的第 2 步卡住;
- 少了 02,S0-pre 不成立 → 所有單位 INVALID → `--pre-p3-full` 的 W 證據、country-join、02 的 `fw-badinclude` 全部拿不到。
- 之後只要 02 離開 mesh(例如 F 期間 02 的 mesh 臂失誤),也沒有遠端復原路徑。

**修法**:
1. H4-U7 加一步(使用者在場):「02 的 eth0 暫時接到實驗室交換器(或接序列 console),到 02 以 N0 入網、ssh 經 bat0 通了為止」。§3.3 寫明 02 的 S0-pre 走 ssh root 讀 claim secret(經 stdin 傳給 peer,不進 argv),之後才拔線。
2. §3.3 / §11 加一列「02 離開 mesh」:沒有遠端復原 → NEEDS-PERSON,並寫出哪些臂可能讓 02 離開 mesh(country-join 的 02 那一半、`fw-badinclude`)。
3. 順帶:`provgen.py` 不在 repo,也不在 §1.2 的檔案清單;net_config 的產生目前只有 Go 的 `provclient net-apply`(`net.go:211-230`)。請把 net_config 的產生者寫進 §1.2(放進 `peer.py`,或沿用 provclient)。

### M2 — 「破壞 squashfs magic」會在寫入前被 `batman-slot` 擋下:E-H13(現場)與 UD4 都得不到 panic

**情境**:§8.1 的壞 rootfs 是「破壞 superblock 前 4 bytes(magic)、SHA256SUMS 用破壞後的 sha」。§15-6 的 E-H13 在 wsl.22 上用 ssh `batman-slot apply` 寫入。

**證據**:`batman-slot:616` 在 precheck 階段先比 `hsqs`,不符就 `die "payload rootfs is not a squashfs"`(E2),在 `begin_write` 之前。所以 E-H13 會在**現場**直接失敗,不會寫槽、不會 arm、不會 panic。

P3 的 app 路徑走新的 `batman-slot write <dir>`(`254-p3-impl.md:357`)。它很可能沿用同一個 precheck,或在串流時自己檢查 magic。若是如此,UD4 會在 prepare 被拒,拿到 11 / 12,而不是 6 + 18,UD4 就驗不到「新版沒開機成功」。

另外,P3 §8 指定的注入是「目標槽 **kernel** 壞掉」;H4 改成 rootfs,但沒有寫理由,也沒有回報 P3。改成 rootfs 本身是對的:`batman-slot:391` 寫明壞掉的開機檔會讓 Pi **卡住**而不是 panic。

**修法**:
1. 保留 magic,改破壞讓 kernel 一定拒掛的欄位,例如 `s_major`(offset 28,u16)改成 0,或 `block_log` 與 `block_size` 不一致。驗收:
   - `unsquashfs -s` 失敗;
   - payload 的 offset 1080 不是 ext4 magic `0xEF53`(否則 `rootfstype=…,ext4` 可能誤認)。
2. 寫明依賴 E2 的既有機制(tryboot 一次性 + `panic=10` 回預設槽,`batman-slot:378`)。
3. §1.4 回報 P3 兩件事:
   - `batman-slot write` 的 precheck 只檢查 magic → H4 的注入不碰 magic;
   - §8 的「kernel 壞掉」改為「rootfs superblock 壞掉」及其理由。
4. E-H13 做完後,B 槽是「已驗證」的壞 rootfs(cmdline 是真的、沒有 BAD 標記)。下一個 F / T 使用 B 之前必須 brewrite。寫進 §13,並在 §15-6 加還原步驟與 `s0_assert`。

### M3 — §8.2 的 eeprom-hooks 隔離「沿用 dv-sbx.sh 的 setup 在 WSL 跑」違反既有的明文安全決定;E-H16 寫成「未知、先唯讀確認」,但原始碼早已回答

**證據**(E3):
- `dv-sbx.sh` 只准在丟棄式 CI runner 跑。理由寫在 `254-p1-impl §4.10` 與 2026-10-28 審查 A-M4:「它曾以 root 在 WSL 跑過」。
- 它的隔離是「accident isolation, not containment」,保留初始 user namespace 的 `CAP_SYS_ADMIN`。
- `--base` 必須等於釘死的 1.5.11 sha,換不成 wsl.22 / wsl.9。

**影響**:照 §8.2,EE1 會在開發機上以真 root + `CAP_SYS_ADMIN` 執行兩個 image(含 PR-F 之前的 1.5.12-wsl.9)整串 `/etc/uci-defaults/*`,其中包括 `95-batman-storage` 這類會動分割 / 掛載的腳本。這等於悄悄推翻先前的安全決定;而且照字面去做,`dv-sbx.sh` 會直接 FAIL 退出。

**修法**(二選一,寫進設計並由使用者拍板):
- (a)**WSL rootless**:`unshare --user --map-root-user --mount --pid --fork --net --uts --ipc` + chroot。qemu-user-static 的 binfmt 有 `F` 旗標,chroot 內可用,但要附 `/proc/sys/fs/binfmt_misc/qemu-aarch64` 的 flags 輸出作證據。這樣沒有真 root,也不需要 `dv-sbx.sh`。斷言前先跑一個「escape」負測試:在沙箱裡 `reboot` / `mount /dev/sdX` 必須失敗。
- (b)**CI**:擴充 dv-sbx,讓它接受一份釘死的 base 清單(wsl.22、wsl.9 的 rootfs sha),base 要先發布到 CI 拿得到的位置。

E-H16 改成上面所選方案的實測,不要再寫「先唯讀確認」。

### M4 — prov-http 的主要判定靠 nft counter,但 P3 §3.8.1 的規則沒有 `counter`

**情境**:這些判定都寫成「`inet batman_http_in` 的 drop counter 增加」或「`bridge batman_http` 那條規則的 counter 增加」:
- HT8a、HT8b、HT9、HT10、HT11、HT20(附錄 A.7);
- §4.5「判定都在 04 端」;
- §7 第 4、5 步(含 D-2 的「mark 計數器」)。

**證據**:P3 規則原文沒有 `counter`(E4)。§1.4 回報給 P3 的五點裡也沒有這一項。P3 rc 照凍結的文字實作的話,`nft list` 看不到任何計數。依 H4 自己的規則(缺了 → INVALID),這些臂在 P3 rc 上一律 INVALID,P3 PR 的閘門卡死。或者實作時有人改成只看 tcpdump,但沒有重新審查。

連帶的問題:
- §7 的 listener 是 `uhttpd -p <br-ahwlan IP>:8095`;lo 臂是 `wget http://127.0.0.1:8095/`,docker0 臂沒寫目標位址。
- 目標不是 br-ahwlan IP 時,沒有規則也只會收到 RST,「看不到 SYN-ACK」一定成立。
- 所以 counter 才是唯一有鑑別力的證據。

**修法**:
1. §1.4 加第 6 點:兩條規則都帶 `counter`(建議 named counter,例如 `counter name batman_http_mark` / `batman_http_drop`,讀法固定);
2. §7 的 probe 規則照同樣的寫法(D-2 要的 mark 計數器);
3. §4.5 / §7 寫明每條路徑的目標位址一律是 04 的 br-ahwlan IP:8095(lo 臂也連 br-ahwlan IP,本機來源的封包仍走 lo、沒有標記);
4. 每臂判定 = counter 增量 ≥ 送出的 SYN 數 × 下限,**且** tcpdump 沒有 SYN-ACK / RST。

---

## MINOR

1. **F-H15「busybox `wget -T`」**:實際上是 uclient-fetch(E5)。`-T` 是 connect / request timeout,可以用,但它的結束碼與訊息能不能分出 refused / timeout 沒有驗過。E-H15 加這一項;判定本來就在 04 端(counter / tcpdump),relay 的分類只當記錄。

2. **ethsim 的實際速率**:20 並發 × 每條約 2 s 逾時 ≈ 10 conn/s。P3 §8 寫的是 50 conn/s。§4.5 說「實際速率記錄下來」,但沒有寫下限與 P3 的差距怎麼處理。請寫明這是誠實界線(或改成短逾時 + 更高並發,並保持行程數上限)。

3. **undo journal 的互斥說法與程式不符**(§9):鎖是一個指令一把(E6),dead-man 等鎖 10 分後不拿鎖照做。要寫明:
   - 「undo-run」是 lease 的子命令,先 `renew` 到最壞情況的還原時間(`ap-restore` ≤ 230 s + `fw-start` + OTS 健康),全程在 `held` 底下;
   - 每一行執行成功就從 journal 刪掉;
   - 每個動作都要冪等(兩邊都跑也無害)。

4. **HT14 的 60 s 保險不可取消**:臂自己的 `fw-start` 跑完之後,保險在第 60 s 又做一次 `firewall start` + `dockerd restart`,可能與 OTS 健康斷言重疊。保險的 pgid 要登記進 undo(`kill-pg`);`fw-start` 執行前先殺掉保險;保險自己在動作前檢查「`inet fw4` 已在」就跳過 dockerd restart。

5. **undo 的動作清單缺「殺行程」**:§7 的 uhttpd listener 寫「登記 undo `svc`」,但清單裡沒有 `svc`,也沒有殺 pid / pgid 的動作。加 `kill-pg <pgid>`(驗 cmdline 後才殺)。

6. **`fresh-deadline` 在重開迴圈中永遠不觸發**:每次 boot_id 改變都改寫成「本次 uptime + 30 分」。B 若每 < 30 分重開一次(例如 openmanetd 的位址保留重開、panic),dead-man 永不觸發。加一個累計上限,例如開機次數 ≥ 3,或以首次寫入的 wall clock + RTC 不可用時的開機次數為準。

7. **§9 擁有權**:
   - `fresh-deadline` 有兩個寫者(主機續期、B 上的迴圈改寫),寫明兩者都用 tmp + rename,以及誰優先;
   - 漏列的資源:節點上的 `/tmp/run/batman-dv/c0`(何時刪)、HT14 保險行程、`~/.ssh/batman_phone_ed25519` 與 `phone_known_hosts`(誰產生、怎麼輪替)。

8. **`release-min-serial = 2`**:RB 是 release image + bind 的 prov_test helper,讀到的 min-serial 是 release image 的值。UD7 的「serial < min」要嘛把 min-serial 以 build tag 編進 prov_test helper,要嘛把這個檔加進 bind 封閉清單。寫進 §1.4 / §5。

9. **`ap-restore` 只寫回密碼**:key 20 臂改的是 SSID + passphrase(ALT)。P3 上的 `ap-restore` 要用 `--ap - --ap-ssid … --ap-section default_radio0`,並斷言 hostapd 的 SSID / sha 回到 S0。S0-pre(P2 setkey 沒有 `--ap-ssid`)不會跑 key 20 臂,寫明即可。

10. **`s0_assert`「目前槽 = 受測 image」**:T 每做一次就換槽(A ↔ B)。斷言應只看 `BATMAN_VERSION`;或由庫記下目前槽,T 之後更新。否則 T 之後的單位會 INVALID。

11. **§6.1 把 pre-P3 寫死成 wsl.22**:P3 實作期間,main 上只要有其他 PR 產生 wsl.23(沒有 `provd-p3`),所有 P3 單位就變成 NEW FAIL,常規全套連續紅燈。建議 ERE 列出「已知的 pre-P3 版本」並隨 pin bump 更新,或改成「沒有 `provd-p3` 且 feed commit 是 P3 merge 之前的祖先」;到期日照舊。

12. **D11 的「fresh-overlay 檢查」沒有對到**(P3 `:27`、`:614`):§8.2 / EE1 只有 1.5.12 的負對照。§6.3 的 lint 會抓到,請現在補上那一臂。

13. **附錄 A 的標記**:
    - UD4 只有 P,可以加 W(E_U `update/check`);
    - AC5 標 S,內容是 G,改標 G;
    - CJ1 的 W 預期行「joined with country mismatch」:wsl.22 的 setkey 會用 radio 的國家(AU)驗 N0 的頻道(`halow-setkey:88-100`)。頻道不在 AU 表裡的話,會得到 `E_APPLY` 而不是入網。請先查 regdb 確認 N0 的頻道在 AU 合法,或把預期行改成「任何非 14 的結果」。

14. **生命週期少一列**:P3 §6「依賴重啟:bluetoothd / dbus」,H4 只做 bluetoothd(HT3)。加一臂 dbus restart(或寫明理由)。

15. **`uci-argv-shim` bind 在 `/sbin/uci` 上,影響全系統每個 uci 呼叫者**:寫明 shim 必須 `exec /rom/sbin/uci "$@"`(argv 原樣、rc 原樣)。shim 有自己的 selftest(含空白、引號、`$` 的參數),在 bind 之前於 04 以 `/rom` 路徑比對輸出。

16. **S0-pre 的 IP 變動**:兩台新卡入網後,openmanetd 會保留位址並重開一次(`99-halow-identity:21-24`),IP 會從 `10.41.254.x` 換掉。§3.3 的 provision 要像 `fresh_ip` 那樣每一步重讀,並等那次重開結束。

17. **§14 / §16**:成本仍然待使用者決定(合理)。§16 的「logs 拷回主機」要寫明拷回之前先在節點上以原值 grep(與 `uci-argv` 同一條規則),避免秘密進 WSL 的 log 目錄。

---

## 附錄 A 逐列抽查摘要

- **W 列**(在 S0-pre 上):除了 CJ1 的預期行(m13),其餘在 wsl.22 都會在第一個 P3 動詞(本體或前置)拿到 E_U → FAIL,與 §3.1 的判法一致。BG1/BG2 的「200」、HT3「not listening after 300 s」、HT13 / FB1「表不在」都與 wsl.22 的現況相符(04 沒有 `ruleset-post` 目錄,`/cgi-bin/bundle` 存在)。
- **S 列**:都在同一載具上只差一個變數。換規則型的 S 兩邊都在 `http-nofw` 底下 + LISTEN ✅;UP3 兩邊都 `http-nofw` + `phy9h4`,只差 `upload-nosrcip` ✅;UD-T1 是同一 manifest 在 R 對 RB ✅。
- **P 列**:多數能證明前提。依賴 counter 的 P / 斷言,見 M4。
- **G 列**:UD3b、UD12、UD16、ST7、ST19、UP10 誠實限縮,並由 H4-U8 背書 ✅。

## 判決

**REJECT**(0 / 4 / 17)。以下四條 MAJOR 修完前不核准:
- **M1**:02 在 S0-pre 拿不到 claim secret(沒有路徑);
- **M2**:壞 rootfs 被 magic 檢查擋下;
- **M3**:EE1 在 WSL 以真 root 跑,違反既有決定;
- **M4**:counter 不存在。

架構已收斂,四條都是局部修正。修完後請整份再送兩位審查。
