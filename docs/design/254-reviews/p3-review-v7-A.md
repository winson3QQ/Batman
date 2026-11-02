# #254 PR-P3 設計 v7(bfb6703)— 審查 A

**判定:APPROVE-WITH-CHANGES。0 BLOCKER、0 MAJOR、11 MINOR。設計已收斂,可以凍結。** v6 的三個 MAJOR(A6-M1 VLAN、B6-M1 國家頻道、B6-M2 SIGPIPE)我都對照原始碼與節點查過,已修好。這輪新找到的問題都是局部的:兩個「別的程式怎麼運作」的說法證據不完整(m1 `.busy`、m2 tmpfs 退化),其餘是一致性與硬化。每一項都可以在實作 PR 附測試修掉。

**方法**:整份 v7 從頭讀到尾,沒有只看差異。對照 Batman-p3 原始碼、firmware-2710 build_dir(kernel 6.6.138 bridge / netfilter、procd 2026.03.14、busybox 1.36.1 ash)與 v6 兩份審查。04(10.41.1.3)、02(10.41.1.1)只跑唯讀指令(`nft list`、`ip rule`、`bridge link`、`uci show`、`cat /sys`、`strings`),沒有寫入任何東西,`/tmp` 也沒寫。

---

## 已核實 ✅(附證據)

- **F75 + 新規則的正向前提(mark 從 bridge 帶到 IP 層)。** F75 證明了三件事:規則載入得了、mesh 與 lo 來源被丟、刪表後完全回到原狀。它**不能**證明 AP client 會通過:一條「全部丟」的規則也會通過同一個探針,所以正向一定要另外測。我用原始碼補上證據:
  - `net/bridge/br_input.c:59-72`:`br_pass_frame_up` 先設 `indev = skb->dev`,再 `NF_HOOK(NFPROTO_BRIDGE, NF_BR_LOCAL_IN, …, indev, …, br_netif_receive_skb)`。所以 mark 在 bridge LOCAL_IN 打上,然後才進 `br_netif_receive_skb` → `netif_receive_skb`(`:27-31`)→ IP 堆疊。
  - 這條路徑上 `net/bridge/*.c`、`net/core/dev.c`、`net/ipv4/ip_input.c` 都沒有清掉 `skb->mark` 的地方(grep `->mark =` 沒有命中)。veth 跨 netns 的 `skb_scrub_packet` 會清 mark,所以容器設 SO_MARK 也帶不過來。
  - 推論:AP client 的封包在 inet input 會帶著那個 bit。⚠️ 這仍然是原始碼推論,§9-4 的正向實測還是要做。
- **02 已回到基準**:`nft list tables` 只有 ip filter/nat、ip6 filter/nat、inet fw4。`br_netfilter` 已載入、`bridge-nf-call-iptables=1`,F75 是在這個條件下量的,所以結論涵蓋 docker 會載入 br_netfilter 的節點。
- **mark 衝突**:04 的 `nft list ruleset` 裡沒有任何 `mark`;`ip rule` / `ip -6 rule` 只有 local / main / default;`tcp_fwmark_accept = 0`;batman-adv `isolation_mark = 0x00000000/0x00000000`(另見 m8)。
- **B6-M2 修法的前提**:`provstore/exec.go:27` 有 `Setpgid: true`,`:38`、`:42` 逾時時只對子程序自己的 group 送 TERM / KILL。procd `service/instance.c:898,916` 只 `kill(in->proc.pid, SIGTERM)`,不送 process group → helper 被 procd 停掉時,setkey 不會收到信號。再加上 `trap '' PIPE` 後,「setkey 拿著鎖跑完並自己 `--rollback`」成立。halow-setkey 沒有 `set -e`(`:1`),所以 echo 回 EPIPE 不會讓它中止。
- **B6-M1 修法**:`halow-setkey:89-99` 驗證 `--channel` 時用的是 uci 裡**現在的** country → key 2 先改國家、join 再驗頻道,這個順序成立。另外查了會不會再卡死在別處:`applyNet`(`node.go:1110-1118`)只在目前的 key **不是** placeholder 時才跑 `CheckRestorable`;`desired()`(`wtxn.go:178-180`)看到 placeholder 的快照就走 forget。所以新卡改成 DE 之後(頻道還停在 40),入網的事前檢查與失敗還原都**不會**拿 ch 40 去問 `--check-only`。
- **chanfix / keyguard 與 key 2、key 20 的互動**:`99-batman-chanfix` 只在新槽第一次開機跑,而且要等 `wlh0`,radio1 被封鎖時等不到(`:39`);`halow-keyguard:22-46` 逐項封鎖 / 解除,key 20 寫入真的 AP key 後,下次開機不會再封鎖 AP。
- **autocommit 不看 p5**(grep 沒有 `config-save`)→ P2→P3 升級時 p5 stale 不會讓試用被退回;bad-slot 在 commit 時刪除(`batman-autocommit:554`)。
- **DHCP**:每台都在 ahwlan 開 dnsmasq(04 / 02 `dhcp.ahwlan`),所以連上 AP 的手機拿得到 10.41/16 的位址,連得到 `bulk/open` 給的 IP。
- **v6 修法沒有退化**:F11 provd 身分(PPid / uid / exe)、F69、F70 / F59、唯讀動詞不拿 `n.mu`、96 的 `valid_batch` 都和 v6 審查時一樣成立。

---

## MAJOR

無。

---

## MINOR(都可以在實作 PR 附測試修)

### m1. `batman-slot` 在逾時時被 TERM 殺掉,`batman-slot.busy` 會留下來 → P3 擴大後的 `otaBusy()` 會擋到下次重開(§3.7.5 步驟 6「由既有的 pid 檢查回收」只對了一半)
- **情境**:SD 卡變慢,`batman-slot write` 超過 600 s → `provstore.Exec` 對整個 group 送 SIGTERM(`exec.go:38`)。
- **證據**:busybox ash 1.36.1 `shell/ash.c:3707-3742` `setsignal`:非互動 shell 的 SIGTERM 是 `S_DFL`,shell 直接死掉,**EXIT trap 不會執行**。`batman-slot:157` 只有 EXIT trap 會刪 `$BUSY` 與鎖。鎖有 pid 回收(`:86-95`),`.busy` 沒有。helper 的 `otaBusy()` 只做 `Lstat`(`node/wtxn.go:448-451`)。
- **影響**:這次開機剩下的時間,`settings.set`、`update.check`、`network/join`、`network/update`、`network/leave` 全部回 `E_BUSY`,app 沒有出路,只能重開(fail-closed,舊槽仍在用,沒有失去狀態)。
- **修法**:`batman-slot` 加 `trap 'exit 143' TERM INT HUP`,讓 EXIT trap 會跑;或者 `.busy` 寫入持有者的 pid,`otaBusy()` 照 `slot_lock` 的規則檢查持有者是否還活著。
- **測試**:接縫 `/tmp/batman-fault.write-stall` + 把 write 的期限縮短 → 逾時後斷言 `.busy` 不在、`settings.set` 不是 `E_BUSY`。負對照 = 現在的 `batman-slot`。

### m2. bulk tmpfs 掛不上時會退化成 `/tmp` 底下的一般目錄 → 失去 `size=` 上限(§7「專屬 tmpfs `size=` 上限」)
- **情境**:init 的 `mount -t tmpfs` 失敗(例如 ENOMEM),或「已掛載」的檢查判斷錯了,但目錄已經存在。ujail 照樣把這個一般目錄 rw bind 進 jail。被入侵的 provd 就可以把 `/tmp`(RAM)寫到滿。
- **修法**:init 只在 `/proc/mounts` 裡這個路徑確實是 `tmpfs`、而且 `size=` 符合時才加上 rw 掛載(否則 provd 照常啟動,只是沒有上傳功能);`bulk.open` 的前提再檢查一次(不符 → `E_STORAGE`)。
- **測試**:注入 mount 失敗 → provd 能起來、BLE 正常、`bulk.open` 被拒、`/tmp` 用量不變。
- **同一處的小事**:helper 算上傳進度的 stat 要用 `lstat` / `fstatat(AT_SYMLINK_NOFOLLOW)`。boot 成員的名字除了正規式,還要明確拒絕 `.` 與 `..`(`^boot/[A-Za-z0-9._-]+$` 會吃下 `boot/..`;SHA256SUMS 有簽章,所以只防我們自己的錯)。

### m3. autocommit (a)「helper 在跑」沒有「停用」的例外
§3.7.6 給 provd 被停用時的例外(只 WARN,B5-m8),helper 卻沒有同樣的例外。操作員停用 `batman-provhelper` 的節點,每一次升級(包括 ssh sysupgrade)都會被退回。修法:比照 (b),`/etc/init.d/batman-provhelper enabled` 為 false → 只 WARN。測試:helper 停用 → commit + WARN。

### m4. 重裝同一版本又失敗時會報成 6 + 18(A6-m5 的前半沒有處理)
`bad-slot` 的內容是 `slot=X version=V`(`batman-autocommit:244`),只有 commit 時才刪(`:554`)。上一次失敗之後沒有 commit 過,這次重試同一版本又被退回 → 內容和 `bad_slot_at_apply` 相同 → 落到「`rebooting` + 沒有新的 bad-slot」那一列 → 報「新版沒有開機成功(18)」,實際上是「開機了、不健康、被退回」。附錄 C 對 A6-m5 只回應了 disarm / `rebooting`。修法:update-last 記 apply 時 `autocommit.log` 的大小(或最後一行 TRIAL-REVERTED 的 boot id);apply 之後出現新的 `TRIAL-REVERTED … slot=<to_slot>` 才報 6(不帶 18)。這只讀 autocommit 的 log,不新增寫者。測試:§8「之前退回過同一槽」那一臂改成「同版本連續失敗兩次 → 第二次是 6、不是 6 + 18」。

### m5. `batman-slot reboot committed` 失敗時,tryboot 旗標會留著
§3.7.4:寫完 `rebooting: true` 就呼叫 reboot。如果它回非 0 又沒有重開,旗標還 arm 著,下一次跟這次無關的重開就會進試用。現有的 disarm 規則只在 helper **重啟**時生效。修法:reboot 指令回來(不論 rc)→ helper 自己 `batman-slot disarm`、改寫 `rebooting: false`、記 phase 0 + reason。測試:接縫讓 reboot 回 1 → disarm,旗標清掉。

### m6. setkey 新旗標的結束碼漏了 settle gate
`halow-setkey:150-151`(netifd 30 s 內沒有穩定下來)與 `:129-131`(run dir 不能用)現在都是 rc 2 = 「值不合法」→ helper 會對應成 reason 13,app 就會說 SSID / 密碼不合法。新旗標的對應裡,這兩種都要回 **5**(→ `E_BUSY`);§3.3 的結束碼表要把它們列進去。測試:另一個程序讓 netifd 一直 pending → `E_BUSY`,不是 13。

### m7. 文件不一致(機制本身沒問題)
- §4 擁有權、§5.3 介面只寫 `bridge batman_http`,漏了 `inet batman_http_in`(§3.8.1 寫的是兩張表都要在)。
- §6「firewall reload」那一列與 §10 還寫「先 flush 自己的表」;§3.8.1 已改成「先刪再建」(B6-m14)。
- §5.1 `update.apply` arm 失敗只列 11 / 12 / 1 / 5,§3.7.4 已加 17。
- §3.8.1 說 rc 驗收在兩板都跑 `nft -c`,但 §6 寫 bcm2710 只有 CI 沙箱,而 `nft -c` 需要真的 kernel。應該寫成:bcm2710 image 在 Pi 3 bench 跑過 `nft -c` 之前不發行(Pi 3 目前不支援,與 CM4 決策一致)。
- §7「被入侵的 provd 自己聽 HTTP … 防火牆仍只收手機 AP port」:防火牆只管 8095,其他埠照現況(ahwlan input ACCEPT)。用詞要改準。

### m8. 這個 mark bit 的保養:非 AP 埠要先清掉
inet 規則只看 bit 24 有沒有設,但 bridge 規則只會 OR、從不清除。如果另一個 kernel 功能在 skb 到達 bridge 之前就設了這個 bit(例如 batman-adv 的 `isolation_mark`;04 上是 0/0,但這是操作員可以設定的),mesh 來的封包就會通過。修法:bridge 鏈先 `iifname != "phy*" meta mark set meta mark & 0xfeffffff`,再對 `phy*` OR;helper 的前提檢查順便驗證 bat0 的 `isolation_mark` 遮罩沒有用到 bit 24。另外寫下來:這個 bit 也會跟著被 DNAT 到容器、轉送出去的 AP 流量(現在沒有任何東西讀它),將來的 fwmark 使用者不得用 bit 24(release gate 加 lint)。測試:從 bat0 送帶 bit 24 的 frame(或用 `isolation_mark` 模擬)→ 被丟。

### m9. `phy*` 前提檢查少了 B6-m4(c) 的後半
§3.8.1 要求每個 `phy*` 埠都是 `default_radio0` 的 iface,但沒有要求這個 iface 是 **`br-ahwlan`**(`http.2` 給的就是它的位址)的埠。AP 被放進別的網路、或根本沒有進 bridge 時,provd 會照樣聽,擁有者卻被靜默丟掉(fail-closed,但沒有回報)。修法:加上「`default_radio0` 的 iface ∈ `br-ahwlan` 的埠」;不成立 → 不給 `http.2`,`status` 回報原因。

### m10. 我們自己出錯:簽好的 image 帶著壞掉的 include → 試用沒有防火牆照樣 commit
F70 的結果(整份 fw4 失敗)由 rc 的 `nft -c` 與每次開機的斷言把關,前提是 bench 跑的 image 和出貨的完全相同。autocommit 現在不看防火牆,所以萬一漏掉,試用開機沒有防火牆還是會被 commit,回不到「有防火牆」的狀態。修法(一行,便宜):autocommit 的 `health_ok` 加「`inet fw4` 在」(fw4 本來就由 image 載入,與 HTTP 無關)。測試:`fw-badinclude` 試用 → 被退回(同一個非 DUT、斷網的條件)。

### m11. §9-4 的期限要寫成可以檢查的閘門
「H4 凍結前完成」要寫進 H4 的驗收清單:正向(AP client 連得上 8095)、VLAN 臂(eth0 與 docker0 容器)都要有原始輸出;沒有就不准凍結 H4。不成立時的出路已經寫了(§9-4),可以接受。

---

## §9 延後項的判斷

| # | 判斷 |
|---|---|
| 1 U5 改名 | ✅ key 1 維持 `rename-pending`(`node.go:765` 現行行為),不會帶著沒驗過的改名出貨 |
| 2 YubiKey | ✅ 節點只依賴 ES256 + low-s |
| 3 | 關閉(D21),界線寫得誠實 |
| 4 HTTP 來源規則剩下的實測 | ✅ 有條件接受:正向已有 kernel 原始碼證據(上面),但 F75 本身證明不了正向;要照 m11 寫成 H4 的閘門 |
| 6 tmpfs `size=` | ✅(另見 m2:退化成一般目錄的情況) |
| 7 setkey 旗標 | ✅,另外加 m6 的 settle-gate rc |
| 8 CYW43455 共存 | ✅ 由 H4 量測;BLE 斷掉 = 回應遺失 → §5.2 會重讀 |
| 9 02 / 04 重燒 | ✅ 破壞性,先列步驟(D20) |

## 使用者決策

D1–D22 我沒有發現有害的。D20(legacy 拒絕 key 2 / 20)、D21(不做晶片端國家實測)、D22(02 探針)的界線都寫得誠實。

## 收斂

架構(fw4 載入的 bridge mark + inet drop、helper 才能給 `http.2`、Go 白名單解析、`batman-slot write/arm`、兩層鑰匙、update-last 單一寫者)已經收斂,而且有證據支撐。這一輪沒有 MAJOR。11 個 MINOR 都是局部修正,每一項都有對應的測試與負對照,可以帶進實作 PR。**建議凍結 v7**(連同 m7 的文字修正)。
