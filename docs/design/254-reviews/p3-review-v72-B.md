# 254-p3-impl v7.2(65e6e19)審查 B — 安全優先(S5:§3.7 / §3.8 / §3.11 / §12)

- 審查者:B(安全優先)。範圍:§3.7、§3.8、§3.11、§12,加上它們引用的 §1.3 / §4 / §5 / §6 / §7 / §8 / §9 / 附錄 D 各列。
- 方法:對照 `/home/yello/Batman-p3`(fbc01ae + 65e6e19 文件)、`/home/yello/firmware-2710` 的 kernel 6.6.138 原始碼與 `.config`。只讀,沒有改任何 repo,沒有連節點。`facts-check.md` 拿來當線索,下面用到的點都自己重新查過(標 ✅);沒有重查的標 ⚠️。
- **結論:APPROVE-WITH-CHANGES。0 BLOCKER、2 MAJOR、12 MINOR。**

---

## 0. 自己查證的事實(✅ 附出處)

| # | 事實 | 證據 |
|---|---|---|
| V1 | `bootConfigOK` 在鎖外以 `mount -t vfat -o ro /dev/mmcblk0p3` 掛載(路徑寫死)。`Tick` 每 15 s 判斷 `poweredFor >= 600 && Committed() && ConfigOK()`,而且 ble-ok 寫好之後仍然每次都跑 → §12.2-1 的前提成立 | `cmd/batman-provhelper/main.go:716-724`;`health/health.go:222-223,233-245` |
| V2 | `die` 一律 `exit ${DIE_RC:-1}` → §12.2-2 成立 | `batman-slot:40-44` |
| V3 | EXIT trap 只刪 MBR 快取、`.busy`、鎖,**不會卸載** `tboot_open` 掛的 rw FAT(`/mnt/slotboot.$$`);沒有 TERM trap | `batman-slot:157`、`:409-416` |
| V4 | helper 子程序逾時時,先對整個 process group 送 SIGTERM,**10 s 後送 SIGKILL** | `provstore/exec.go:27-45` |
| V5 | `otaBusy()` 只做 `Lstat(batman-slot.busy)`,不檢查持有者還在不在;它會擋 `net.apply`、`network.leave`、`settings.set` | `node/wtxn.go:450-454`;`node/node.go:247` |
| V6 | `sock.peerUID` 只回 uid,pid 被丟掉 | `sock/sock.go:178-194` |
| V7 | provd 的 `Config.Board` 去掉了 `ekh-` | `cmd/batman-provd/main.go:81` |
| V8 | 現行 boot 複製是**白名單類別**:`kernel8.img start*.elf fixup*.dat *.dtb overlays/*`;驗證時跳過 `bootcode.bin autoboot.txt cmdline.txt config.txt distroconfig.txt` | `batman-slot:677-683`、`:697` |
| V9 | 串流 rootfs 的讀回:讀 `metadata size=`(未簽)個 bytes,和 `SHA256SUMS` 的 `RSUM` 比對。`size=` 被竄改只會讓雜湊不符,所以 fail-closed,§3.7.5-7 成立 | `batman-slot:619-628`、`:693-694` |
| V10 | `VerifySign1`:protected header 必須正好是 `{1:-7, 3:ct}`;unprotected 必須為空;sig 64 B;最多試 4 把公鑰 | `cose/cose.go:36-76` |
| V11 | **kernel 6.6:持有 CAP_NET_RAW 或 CAP_NET_ADMIN 的行程就能設 `SO_MARK`** | linux-6.6.138 `net/core/sock.c:1388-1395` |
| V12 | 跨 netns 時,`skb_scrub_packet(xnet)` 會清掉 `skb->mark`(veth 進 host 時,bridge 網路容器的 mark 被清掉) | `net/core/skbuff.c:5876-5895` |
| V13 | `CONFIG_USER_NS=y`、`CONFIG_VETH=m`、`CONFIG_MACVLAN=m`、`CONFIG_NF_TABLES_BRIDGE=m`、`CONFIG_BRIDGE_NETFILTER=m` | bcm2711 `.config:180,1029,1325,2030,2042` |
| V14 | payload tenant 用具名的 bridge 網路(不是 host);但 repo 裡有 `--network host` 的 OTS 雛形 | `payload-run:292`;`deploy/ots/footprint-spike.sh:22,27,32` |
| V15 | `platform-ab.sh` 只看 `batman-slot` 的 rc ≠ 0,不看特定碼 → §12.2-2 新增結束碼不影響 sysupgrade | `platform-ab.sh:184,364-366,377-379` |
| V16 | `tests/keys/README.md` 寫「T is trusted only by `prov_test` builds」,和 §12.2-5(DEV 通道也信任 T)**矛盾** | `tests/keys/README.md` 末段 |
| V17 | `signrel.py`:key 9 = 所有 `boot/` 一般檔的大小總和(含沒列在 SUMS 的);key 8 空時省略;key 5 = `[E,S]`;key 3 = `.tar.gz` 大小 | `tests/tools/peer/signrel.py:62-140` |
| V18 | prov_test 的 init 已有 rw 掛載的前例(先檢查 symlink);產品 init 與 test init 是**兩個檔** | `batman-provd-test.init:20,34,48`;`files/` 列表 |

**⚠️ 沒查的**:F69 / F48(firmware 原始碼,樹未變);F75 / F76 / D-1 / D-2(只能上機);04 的權限與 pid(§12.3 是作者的實測輸出,我沒有獨立驗證)。

---

## 1. 資產 × 行為者總覽

| 行為者 | 能碰到的新輸入 | 設計的擋法 | 判定 |
|---|---|---|---|
| mesh 上的遠端攻擊者 | 8095(只在上傳窗 / 備援時開) | bridge port 標記 + inet drop(F75) | ✅ 原則對;⚠️ AP client 正向與 VLAN 臂仍待 §9-4 |
| 手機 AP 上的裝置(知道 AP 密碼) | 8095、`X-Batman-Session` 明文 | Noise、PUT 綁 session 與來源 IP、內容靠簽章 | DoS 界線已寫;bearer 的規格不足(m5) |
| 本機非特權行程 | 搶占 8095 埠;在 host netns 以 SO_MARK 打標記 | 「lo 被丟」 | **主張不完全成立**(M-無 → m2、m3) |
| docker tenant(bridge 網路) | veth → docker0 | 跨 netns 清 mark(V12)、`phy*` port 前提 | ✅ |
| 被入侵的 provd(uid 471) | 上傳檔、`update.check`(非 owner-op)、tmpfs | Go 白名單、先驗簽、讀回以 helper 的 SUMS 為準、tmpfs `size=` | 大致 ✅;inode 數、DEV 下 `update.check` 會搶鎖(m6、m9) |
| 被移除的擁有者 | 已在跑的 worker | `owner/remove` 清窗與 pending | worker 不中止(m8) |
| 成員 | — | 沒有任何 update / bulk 權限 | ✅ |
| 實體奪取(節點 / SD 卡) | rootfs 的 `release-root.pub` 可以換 | 沒有 secure boot(既有) | 誠實界線,§7 要寫(m10) |
| 供應鏈 | **公開的 T**(§12.2-5) | 「DEV 只在 bench」 | 後果與出口沒寫完整(m1) |
| 我們自己的錯 | 簽了帶 `autoboot.txt` / `config.txt` 的 payload;殺掉的 `write` | — | **M1、M2** |

---

## 2. Findings

### MAJOR

**M1. 「複製 boot 檔只複製 `SHA256SUMS` 列出的」會讓帶簽章的 payload 覆寫 `autoboot.txt` / `config.txt` / `cmdline.txt`,退路就沒了**

- **情境**:§3.7.3 把現行的「白名單類別 glob」(V8)改成「只複製 SUMS 列出的」;§3.7.5-4 helper 的名字正規式 `^boot/[A-Za-z0-9._-]+$` 也允許 `boot/autoboot.txt`、`boot/config.txt`、`boot/cmdline.txt`、`boot/bootcode.bin`。
  - 只要 build 腳本出錯(我們自己的錯),或在 DEV 上有人用公開的 T 簽(m1),把這些檔放進 SUMS,照字面實作就會把它們複製到目標 FAT。
  - 目標 = A 時,目標 FAT 就是 p1,上面放著**全域的 `autoboot.txt`**(`batman-slot:33` 註解)。覆寫它會改掉韌體選槽,兩個槽都可能受影響 → A/B 退路失效。
  - 覆寫 `config.txt` 等於繞過 key 8 的「開機設定相容」語意(F56:payload 本來就不帶它)。
  - 現行程式註解寫著「NEVER bootcode.bin … NEVER autoboot.txt」(`batman-slot:672-675`)。設計的字面寫法會讓這個保證退化。
- **證據**:V8;`batman-slot:672-683,697`;§3.7.3「共同修改」;§3.7.5-4 的正規式。
- **修法**:
  1. 複製的集合 = 「SUMS 列出的」∩「現行類別白名單」(kernel*、start*.elf、fixup*.dat、*.dtb、overlays/*.dtbo)。
  2. helper 的白名單與 `batman-slot` **兩邊**都明確拒絕 `autoboot.txt`、`config.txt`、`distroconfig.txt`、`cmdline.txt`、`bootcode.bin`、`BATMAN-*`。出現就 reason 11 / rc 13,不要默默略過。
  3. **SUMS 的每一列**(不是只有 tar 成員)都要符合同一個正規式;含 `..`、`/` 開頭、其他字元的 → 拒絕。`batman-slot` 的 copy / verify 迴圈直接用 SUMS 的名字組路徑(`$BM/${f#boot/}`)。
  4. 測試(`prov-update-254` 惡意 tar 臂 + sysupgrade 臂):做一個**有效簽章**的 payload,SUMS 列 `boot/autoboot.txt`、`boot/config.txt`、`boot/../x` → 拒絕;p1 的 `autoboot.txt` sha 前後相同。
  5. 負對照:接縫「只照 SUMS 複製、不交集」→ `autoboot.txt` 被改(FAIL)。

**M2. §12.2-8 / D-14 留了「只加 `trap 'exit 143' TERM`」這個選項,但 helper 自己的期限會升級成 SIGKILL → `.busy` 與 rw FAT 掛載會殘留到下次開機**

- **情境**:
  - §3.7.5-6 給 `batman-slot write` 600 s 期限。逾時後 `provstore.Exec` 對整個 process group 送 SIGTERM,10 s 後送 SIGKILL(V4)。
  - dd 在 `conv=fsync` 卡在 SD 卡的 D-state 時,10 s 內不一定結束 → SIGKILL → trap 不會跑。
  - 結果:`$RUNDIR/batman-slot.busy` 留著,`otaBusy()` 只做 `Lstat`(V5)→ `settings.set`、`network/*` 回 `E_BUSY`,**直到重開**;autocommit 看到 `.busy` 會延後退回最多 600 s(`batman-autocommit:226`)。
  - 另外 `tboot_open` 的 `/mnt/slotboot.$$` rw 掛載不會被卸載(V3,連 TERM trap 那條路也不卸載)。之後 helper 的 `bootConfigOK` ro 掛 p3 會 EBUSY(§12.2-1 的另一面),`ble-ok` 不會更新。
  - app 對節點的管理會卡死,只能斷電。§6「helper crash」那一列寫的「槽保持 BAD、lock 由 pid 回收」只說了鎖,**沒有涵蓋 `.busy` 與掛載**。
- **證據**:V3、V4、V5;§12.2-8「做法照附錄 D-14」(D-14 列了兩個選項)。
- **修法**:
  1. 定案採用「`.busy` 帶 pid,並和鎖一樣檢查 cmdline」(`otaBusy()` 與 autocommit 都改成檢查持有者還活著;持有者死了 = 不忙)。TERM trap 可以另外加,但不能取代這一步。
  2. EXIT / TERM 路徑呼叫 `tboot_close`。或者 `batman-slot` 啟動時,把 `/proc/mounts` 裡殘留的 `/mnt/slotboot.<死掉的 pid>` 卸載。
  3. 測試:以接縫讓 `write` 卡住超過期限並收到 SIGKILL → 之後 `settings.set` 不是 `E_BUSY`、沒有殘留的 `/mnt/slotboot.*`。負對照:只有 TERM trap 的版本 → `E_BUSY` 一直到重開(FAIL)。

### MINOR

**m1. 公開的 T 被 DEV image 信任(使用者決定):後果與出口沒寫完整**

使用者的決定照收。但有四點要補:

- (a) **TCB 變大**:T 是公開的,DEV 節點的安全等於「app 從哪裡拿到 payload 與 manifest」。擁有者在 app 上同意的是「那份檔的 sha」,下載來源被換掉(GitHub release、雲端硬碟、手機存檔),擁有者就會同意一份惡意 image。§12.2-5 只寫了「任何人都能簽」,要把「下載路徑 / 手機存檔是 DEV 節點的信任根」寫進 §7 的行為者表。
  - 另一個做法(請使用者選):在使用者自己的機器產生一把**不公開的開發根鑰匙 R_dev**,代替公開的 T。這不需要 YubiKey,工作量和現在差不多,但不再是「任何人都能簽」。T 仍只給 prov_test。
- (b) **出口(生命週期)**:DEV 節點換到 R 只有兩條路 — 一份 **T 簽、內建 R** 的過渡版,或 ssh sysupgrade / 重燒。§6 的升級列要寫明。02 / 04 這類「模擬已部署」的節點目前都是 wsl 通道。
- (c) **release gate 要改成正向**:目前寫「`BATMAN_CHANNEL ≠ wsl` 且含 T → 不出貨」。應改為「`release-root.pub` 必須等於釘死的 R 指紋;`min-serial` 檔存在且 ≥ 1」。否則一個帶了錯誤 / 測試 K 公鑰、或根本沒有根鑰匙的 `rel` image 也能過 gate。要附一個 build 層的負測試:rel 通道 + T → gate FAIL。
- (d) `tests/keys/README.md` 和 §12.2-5 矛盾(V16),要改。版本解析忽略 `+` 之後的部分 → `.wbox-` 帶 Go 接縫的 image 與同號的乾淨版「相等」,可以經 app 用 T 簽裝到 DEV 節點。這屬於同一條界線,但要寫明。

**m2. 「本機行程(lo)被丟」不成立:有 CAP_NET_RAW 的 host netns 行程可以用 `SO_MARK=0x01000000` 打標記**

- **情境**:§3.8.1 與 §7 的 lo 那一列主張 inet input「只收帶標記的封包」,並且「拿掉 v6 的 lo 可佔 HTTP 槽界線」。
  - kernel 允許 CAP_NET_RAW 設 `SO_MARK`(V11)。本機產生的封包經 lo 時,mark 原樣帶到 input hook。
  - Docker 預設的 capability 含 NET_RAW。`--network host` 的容器(repo 裡的 OTS 雛形,V14)或任何 host 上帶 NET_RAW 的服務,都能連到 8095,吃掉 HTTP 的 2 槽與每分鐘 10 次的交握額度 → 上傳窗或 BLE 壞掉時的備援入口被 DoS。
  - bridge 網路的 tenant 不受影響(V12)。
- **修法**:inet 規則再加一個條件:`tcp dport 8095 meta iifname != "br-ahwlan" drop`(本機產生的封包 iif = lo)。§7 那一列改寫。
- **測試**:`prov-http-254` 的 lo 臂加一個子項 — 以 root(或帶 `cap_net_raw` 的 shim)開 `SO_MARK=0x01000000` 的 socket 連 8095 → 被丟。負對照:只用 mark 的規則 → 連得上。

**m3. 本機非特權行程可以搶先 bind 8095**

- provd 只在需要時才 bind。在那之前,任何本機行程都能 bind `br-ahwlan IP:8095`(埠 > 1024,不需要權限)。之後 AP client 的連線(防火牆照樣放行)會進到搶占者手上。
- Noise 擋住了冒充,但上傳與備援會被 DoS,而且搶占者拿得到明文的 bearer。
- **修法**:provd bind 失敗(EADDRINUSE)→ 經 poll 回報,`status` key 15 帶 `http_bind_failed`,app 顯示;§7 列為誠實界線。或者在開機時就 bind、平常不 accept(由防火牆擋),讓埠一直被 provd 佔著。
- **測試**:先用一般使用者佔住 8095,再 `bulk.open` → `status` 回報。

**m4. 「其他 rc → reason 11」會把基礎設施錯誤報成「內容與簽章不符」**

§12.2-2 的表把 rundir 不能用、mount 失敗、EBUSY、被 SIGKILL(rc 137/143)都對應到 reason 11。使用者會以為 payload 被竄改(或反過來,把真正的竄改當成雜訊)。建議新增「內部錯誤」碼(或用 `E_STORAGE`),reason 11 只留給雜湊 / 簽章不符(rc 13)。每個 rc 的測試照 §12.2-2。

**m5. `X-Batman-Session` bearer 的規格沒寫**

要寫明以下幾點,並把 bearer 加進 §8 `prov-settings-254` / `prov-http-254` 的「不在 log / 診斷包」斷言(現在只列了 passphrase):

- 由 provd 產生 ≥ 128 bit 的隨機值,和 Noise 的任何金鑰 / 雜湊都無關;
- 以 constant-time 比對;
- 不進 log、錯誤字串與診斷包;
- 只對 `PUT /bulk/0` 有效。

另外,如果 `/msg` 也用同一個 header 路由:AP 上的旁聽者可以送一份偽造的 `/msg`。AEAD 失敗時應**丟掉那個請求**,不要中止 session(否則旁聽者能隨時踢掉擁有者)。不然就把這點寫進 DoS 界線。

**m6. bulk tmpfs 要限制 inode 數;刪檔要用固定名字**

- 被入侵的 provd 可以在 tmpfs 建大量的小檔 / FIFO(預設 `nr_inodes` 很大,吃的是不可回收的記憶體)。掛載加 `nr_inodes=16`。
- helper 刪檔只做 `unlinkat(dirfd, "payload")`(不要 `RemoveAll`、不要跟隨 symlink);其他名字的東西整個目錄由 helper 以 dirfd + `O_NOFOLLOW` 列舉後刪除。
- tmpfs 要**同時**加在 `batman-provd.init` 與 `batman-provd-test.init`(V18),否則 prov_test 上測不到產品的掛載。
- D-15(掛不上不得退化成一般目錄)照做。

**m7. tar 解析的白名單要寫死幾個邊角**

- 只接受 `Typeflag == TypeReg`(拒絕 `TypeRegA`、PAX global `g`、GNU sparse `S`、long-name 以外的特殊型別);
- `root.squashfs` 之後 `tr.Next()` 必須是 `io.EOF`(否則 reason 11);
- 成員數上限 = SUMS 列數 + 2;
- gzip 讀完之後不接受多段串流 / 尾端資料(或明定忽略);
- 解壓的總 bytes ≤ 64 KiB × 2 + key 9 + 目標槽大小 + header。

每項附一包惡意 tar(§8 的「四包」要擴充成逐項)。

**m8. `owner/remove` 不中止已在跑的 worker**

- 被移除的擁有者在被移除前做的 prepare 會繼續覆寫另一槽(原本的退路)。pending 被清掉 → 走不到 apply,但退路已經沒了。
- **建議**:`owner/remove` 時若 worker 屬於該擁有者 → 中止 worker(槽保持 BAD,與失敗相同)。或者在 §3.7.5 的界線寫明這一點。

**m9. DEV 上被入侵的 provd 可以用 T 簽的 manifest 反覆呼叫 `update.check`,搶 `batman-slot.lock`**

- `update.check` 不需要 owner-op。驗簽通過後會跑 `precheck-node` 與 `bootcfg-sum`(拿鎖),頻率 1 / 10 s。
- 和操作員的 sysupgrade 撞上時,sysupgrade 會 die(「another batman-slot」)。
- 這只在 DEV(T 公開)時可行,屬可用性問題。§7 加一列,或讓 `bootcfg-sum` 只在 pending 內容改變時才跑。

**m10. 實體奪取 / 換 rootfs 上的 `release-root.pub`:沒有 secure boot 前沒有意義,§7 要寫成誠實界線**

另外要寫明:`release-root.pub` 或 `release-min-serial` 缺少、損壞、不只一行 → 一律拒絕(fail-closed,不能把 min-serial 預設成 0)。附 Go 測試。

**m11. 寫好但沒 arm 的槽(phase 3 / pending 過期後)是可以開機的有效槽**

- `write` 成功後,寫好真正的 cmdline、拿掉 BAD(與 `apply` 前半段相同,`batman-slot:701-711`)。pending 過期後槽仍然留著 VERIFIED。
- 韌體的 #133 stale fallback 可能在沒有 apply 的情況下開進它(autocommit 不會 commit stale fallback,`:361`)。
- 擁有者在 prepare 已經同意,所以不算越權,但要寫進 §3.7.5 的界線,並說明 app 的 phase 判讀在這種情況下會報什麼。

**m12. 缺少的負測試**(安全性質 → 目前沒有對應測試)

| 性質 | 狀態 |
|---|---|
| release image 拒絕 T 簽 | bench 臂延到 #255;要先補 build 層的 gate 負測(m1c) |
| SUMS 列 `autoboot.txt` / `config.txt` / 穿越名字 | 無(M1) |
| SIGKILL 之後 `.busy` / 掛載殘留 | 無(M2) |
| `SO_MARK` 的本機連線 | 無(m2) |
| 8095 被搶占 | 無(m3) |
| bearer 不在 log | 無(m5) |
| tmpfs inode 耗盡 | 無(m6) |
| tar typeflag / 尾端成員 | 無(m7) |
| `release-root.pub` 缺 / 壞 | 無(m10) |
| `owner/remove` 期間 worker 的行為 | 無(m8) |

---

## 3. 確認沒問題的部分(✅)

- **先驗簽、才寫任何東西**:VerifySign1 的形狀很嚴格(V10)。E / S 的 content type 與 label 各自分開,不會互相混淆。
- **被入侵的 provd 在上傳中改檔**:SUMS 用 helper 驗過的那份;boot 檔先複製到 root 0700 目錄、再雜湊;rootfs 讀回以 RSUM 比對,未簽的 `size=` 改不了結果(V9)→ fail-closed。
- **開檔**:`O_NOFOLLOW | O_NONBLOCK` + fstat(一般檔、link count 1、uid 471)可以擋 symlink、FIFO、目錄、hardlink;tmpfs 是 nodev,provd 沒有 CAP_MKNOD。
- **prepare / apply 用 owner-op 綁 sha** → 被入侵的 provd 或 AP 上的旁聽者不能換版本。
- bridge 網路的 tenant 跨 netns 時 mark 被清掉(V12),veth 的名字不是 `phy*`;helper 檢查所有 bridge 的 `phy*` port。
- `ruleset-post` 壞掉 = 沒有防火牆 → 有 rc 的 `nft -c` 閘門、開機斷言、D-17(autocommit 要求 `inet fw4` 在)三道關,合理。
- §12.2-1(a)(b)、§12.2-2、§12.2-3、§12.2-4 的事實都成立(V1、V2、V6、V7、V15)。做法方向正確;剩下 sysupgrade 的毫秒窗口:stage 2 時 helper 已被殺,實際上碰不到。

---

## 4. 判定

**APPROVE-WITH-CHANGES**。M1、M2 在 S5 第一個 commit 前寫進 §3.7.3 / §12.2-8(都是小改動,附負對照)。m1(T 的後果與 gate)要讓使用者知道並確認;其餘 MINOR 進附錄 D,每項附測試。沒有 BLOCKER。
