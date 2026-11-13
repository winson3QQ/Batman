# 254-p3-impl v7.5(01d7803)審查 B — 安全優先(S5 整份)

範圍:§3.7、§3.8、§3.11、§12、附錄 E–G,以及 §4 / §5 / §6 / §7 / §8 / §10 / §11 / 附錄 D 中 S5 用到的列。只讀;沒改 repo、沒上節點。

## 0. 自己查證的事實(原始碼 file:line)

| # | 事實 | 證據 |
|---|---|---|
| V1 | 節點的 Go = firmware 樹 `staging_dir/hostpkg/lib/go-1.26`(`go1.26.4`);`Unshareflags&CLONE_NEWNS` 時子行程先 `mount("none","/",MS_REC\|MS_PRIVATE)` | `go-1.26/VERSION`;`src/syscall/exec_linux.go:473-478` |
| V2 | kernel 6.6.138:F_RDLCK lease 在 inode 有任何寫入 fd 時回 `-EAGAIN`;open 寫入時 `get_write_access` 計數;tmpfs 沒有自己的 `setlease` → 走 `generic_setlease`;`CONFIG_FILE_LOCKING=y` | `fs/locks.c:1695-1696`、`:1957-1960`;`fs/open.c:895-903`;`mm/shmem.c`(grep `setlease` 無);`.config:6149` |
| V3 | 同一個 bdev 的 superblock 跨 mount namespace 共用;以不同 ro/rw 再掛 → `EBUSY`("would change RO state") | `fs/super.c:1575-1576` |
| V4 | vfat 沒有 `FS_USERNS_MOUNT`(`CONFIG_USER_NS=y` 但非特權 userns 掛不了 FAT) | `fs/fat/*.c` grep 無;`.config:179` |
| V5 | 鎖、`.busy` 在 root-only 的 `$RUNDIR`(`/tmp/run/batman`,#280);現行 `slot_lock` 是 `mkdir` 後**才**寫 pid;`.busy` 現在是 `: >` 空檔 | `batman-slot:56-64`、`:84-96`、`:155-157`、`:595` |
| V6 | `slot_is_bad` / `slot_bad_reason` 若在 `/proc/mounts` 看到該分割就重用掛載,否則自己 ro 掛;呼叫者只有 `commit`(`:758`)與 `rollback`(`:844`),兩者都先 `slot_lock`(`:754`、`:841`) | `batman-slot:364-375` |
| V7 | `92-batman-ramoops-fix` 只改**目前執行槽**自己的 boot FAT(PARTLABEL `boot$slot`),uci-defaults 時期 | `92-batman-ramoops-fix:9-12,17-40` |
| V8 | `flynn/noise` v1.1.0 `Decrypt` 失敗不推進 nonce;現行 provd 在檢查錯誤之前 `msgs++`、`lastActive = now` | `vendor/github.com/flynn/noise/state.go:69-80`;`provd/session.go:314-322` |
| V9 | stamp 只檢查通道非空;`batman-release.env` 目前 `BATMAN_CHANNEL=wsl`,CI 的 `build-firmware.yml:137` 用**同一份**檔 stamp | `stamp-batman-build.sh:23-24`;`batman-release.env`;`build-firmware.yml:137` |
| V10 | `build-release.yml`(tag push / dispatch → `build-firmware.yml` → 發 GitHub release,附 `*.img.gz`)與 `github-release.yml` 都沒有任何通道檢查;CI gate 只在 bcm2711/2710 跑 | `build-release.yml:6-13,20-68,211-259`;`build-firmware.yml:210-230` |
| V11 | `fast-build.yml` 不跑 stamp、不跑 gate(只出 artifact)→ 沒有 `release-root.pub` → `update.check` reason 21(fail-closed) | `fast-build.yml` grep |
| V12 | T 的私鑰由固定名字推導,任何人都能算(`tests/keys/README.md`);README 仍寫「T 只給 prov_test」 | `tests/keys/README.md`;`signrel.py:8,52` |
| V13 | helper socket = 檔案系統 `SOCK_SEQPACKET`,目錄 root 0750 group provd、只收 SO_PEERCRED uid 471 | `sock/sock.go:1-2,178-200`;`provhelper/main.go:621,654` |

## 1. v7.4 發現逐條確認

| 發現 | v7.5 | 判定 |
|---|---|---|
| A10-MAJOR-1 / B10-m8 PUT 綁 IP | 拿掉,bearer 唯一憑證 | ✅ |
| A10-MAJOR-2 / B10-m1 argv[1] | pid + starttime,最後一個 `)` 後第 20 欄 | ✅(取法 / 原子寫入見 m1、m2) |
| A10-MAJOR-3 / B10-m3 CI 沒 gate | 獨立 `check-release-key-gate.sh`,兩邊呼叫 | ✅ build 端;**發布端沒有通道檢查 → MAJOR-2** |
| B10-m2 垃圾 rootfs 毀退路 | 第一遍只驗不寫 | ⚠️ AP 鄰居那條擋住了;B10-m2 要求「被入侵的 provd 保留 fd、兩遍之間改內容 → 寫進 §7」**沒寫**,而且 §3.7.5-1 寫成「截斷不到 worker 正在讀的檔」(錯)→ **MAJOR-1** |
| B10-m4 通道白名單 | §3.7.2 | ✅ |
| B10-m5 release-sign 重跑 gate | §3.7.2 | ✅(§12.5 負對照只列 `wsl`,m7) |
| B10-m6 `armed` | 拿掉,看 `apply_boot_id` + `!rebooting` | ✅ |
| B10-m7 aclog | 欄位整個相等、≤ 1 MiB、`O_NOFOLLOW` | ✅ |
| B10-m9 窗與備援 | 窗開 = 只收擁有者、關成員 session | ✅ |
| B10-m10 per-IP 429 | 拿掉 | ✅ |
| B10-m11 殘留掛載 | 私有 mount ns、major:minor、不卸別人的 | ✅(副作用見 m3) |
| B10-m12 key 7 跨通道 | reason 4 | ✅ |
| B10-m13 文字一致性 | 大部分改了 | ⚠️ 還有舊句 → m7 |
| B10-m14 `slot_is_bad` fail-open | §11 checklist | ✅ |
| A10-m1 … m17 | 附錄 G 逐條 | ✅(A10-m15「刪檔時機統一」:§7 仍寫「窗外每個 poll 週期刪檔」→ m7) |

## 2. 行為者總覽(整份 S5 重看)

| 行為者 | 能做什麼 | 結果 |
|---|---|---|
| mesh 遠端 | 打 8095 | bridge mark + iifname 雙條件丟掉(F75 02 實測);✅ |
| 手機 AP 上的裝置(知道 AP 密碼:擁有者、被移除的擁有者、拿到密碼的人) | 解 WPA2 流量抓 bearer、搶 PUT、截斷擁有者上傳、重放 `/msg` | 只 DoS;內容由簽章 + 第一遍完整驗證把關;重放的 `/msg` AEAD 失敗被丟、不改狀態(V8)✅ |
| 本機非特權行程 / docker tenant / host-net 容器 | 偽造鎖 / `.busy`;掛 boot 分割卡 rc 14;設 `SO_MARK`;佔 8095;連 helper | 鎖在 root-only rundir(V5)、starttime 由 kernel 產生;FAT 非 userns 可掛(V4);iifname 擋 lo;佔 8095 = DoS(已列);helper 只收 uid 471(V13)✅ |
| 被入侵的 provd(uid 471、jail) | 改 tmpfs 上的 payload;**保留寫入 fd**;佔 tmpfs;DoS | 內容完整性 ✅(讀回以 helper 的 SUMS 為準);**退路可用性 ❌ → MAJOR-1**;RAM 佔用到 `size=` → 界線(m6 建議縮小) |
| 被移除的擁有者 | 舊窗 / pending / worker | `owner/remove` 清窗與 pending、中止 worker ✅;仍知 AP 密碼 → 同上「AP 裝置」 |
| 成員 | 不能 `update/*`、`bulk/*`;窗期間 HTTP 不收 psk_member ✅ |
| 實體奪取 | 換 `release-root.pub`、讀 p5 | 誠實界線(無 secure boot);**若出貨 image 信任公開 T,奪取 + 重置 + 認領 = 經 app 裝任意韌體並放回** → MAJOR-2 |
| 供應鏈 / 我們自己的錯 | 用錯通道發布;release-sign 簽錯 | build gate + release-sign 重跑 gate ✅;**發布點沒擋 wsl/ci** → MAJOR-2 |

## 3. Findings

### MAJOR

**MAJOR-1 第一遍 / 第二遍之間,任何仍開著的寫入 fd 都能改 worker 讀的 inode → 被入侵的 provd 照樣能「驗過再換內容」毀掉退路;§3.7.5-1 的保證是錯的**

- **情境**:被入侵的 provd 在窗內以 `O_RDWR` 開 `payload` 並一直持有(或 `mmap(MAP_SHARED)`)。擁有者正常上傳、prepare。worker:open → fstat(大小對、nlink 1)→ unlink(nlink 0)→ 第一遍全部驗過 → provd 透過**它手上的 fd** 把 `root.squashfs` 區段的 1 byte 改掉 → 第二遍 `lseek(0)` 重新解壓 → `begin_write` 把退路槽標 BAD → dd → 讀回不符 → 0 + 22。每次更新都可重複;節點只剩一個可用槽,之後目前槽一壞就變磚。這正是 B10-m2 要擋的後果,只是行為者換成被入侵的 provd(§7 把它列為行為者)。
  - 誠實的 provd 也有一個較小的版本:provd 透過 poll 才知道「worker 在跑」(延遲 ≤ 一個 poll 週期),這段期間 AP 鄰居送來的 PUT 被接受 → `O_WRONLY|O_TRUNC` 打開的是**同一個 inode**(還沒 unlink)→ 第一遍讀到截斷 / 正在寫的內容。結果多半是 reason 11(DoS),但 worker 的步驟 1 只在 unlink **之前** fstat 大小,之後沒有重驗。
- **證據**:unlink 不會撤銷既有 fd(POSIX;inode 在最後一個 fd 關閉前存在);§3.7.5-1「之後 provd 的任何 PUT 都只會建新 inode,截斷不到 worker 正在讀的檔」只對**之後的 open** 成立;§7「被入侵的 provd」列只寫完整性,沒寫退路;B10-m2 修法段要求寫進 §7(沒寫)。
- **修法(約 10 行,kernel 原子保證)**:步驟 1 unlink 之後:
  1. `fchown(fd, 0, 0)`、`fchmod(fd, 0400)` → provd 之後無法經 `/proc/self/fd/N` 以寫入重開(inode 權限檢查);
  2. `fcntl(fd, F_SETLEASE, F_RDLCK)`:kernel 只在**沒有任何寫入 fd / 可寫共享 mmap** 時給(V2);`EAGAIN` → reason 21(或 `E_BUSY` 可重試),**目標槽沒動**;
  3. 再 fstat 一次(regular、nlink 0、大小 = key 3);
  4. lease 持有到第二遍結束(之後不可能再出現寫者;helper 不需處理 lease break,出現 SIGIO 也直接中止)。
  - 契約:provd 的 PUT handler 必須在回 200 **之前**關檔(否則 prepare 緊接而來會 EAGAIN)。
  - ⚠️ 未查:節點 `fs.leases-enable` = 1(預設值;唯讀探針 `cat /proc/sys/fs/leases-enable`)。
  - §3.7.5-1 的括號改寫;§7 加一列。
- **測試**:Go 接縫在第一遍與第二遍之間暫停;一個 uid 471 的行程持有 `O_RDWR` fd → prepare → reason 21、目標槽沒有 `BATMAN-BAD`、cmdline 不變。負對照:拿掉 lease 檢查 → 那個行程翻 1 byte → 目標槽 BAD(0 + 22)。另一臂:fd 在 prepare 前關閉 → 正常完成(lease 不誤擋)。

**MAJOR-2「`wsl` / `ci` 永不出貨」在發布點沒有機制;CI 用的就是提交的 `BATMAN_CHANNEL`(現在 = `wsl`)**

- **情境**:P3 合併後、#255(R)之前,有人照慣例推 tag 跑 `build-release.yml` 發一版(例如 1.6.0)給現場。`build-firmware.yml` 用提交的 `batman-release.env` stamp(V9,`wsl`)→ image 內建 T → `check-release-key-gate.sh` 的 `wsl` 分支**通過**(它只檢查「= T」)→ GitHub release 附上 `.img.gz` 與 payload(V10)。所有燒這版的節點信任**任何人都能算出私鑰的** T(V12)。之後任何能成為擁有者的人(買到 / 撿到 / 搶到節點 → 重置 → 認領)都能經 app 路徑裝任意韌體,再放回車隊;不需要管理密碼。修復只能 ssh / 重燒,現場做不到。
- **證據**:V9、V10、V12;§3.7.2「這兩個通道永不出貨」只是文字;`build-release.yml` 沒有讀 `batman-build.txt`。v1.0.0 已在 GitHub 公開發布過量產 image(記憶),表示這條路真的在用。
- **修法(只加一個檢查,不加機制)**:`build-release.yml`(在建 release 的 job 開頭)與 `github-release.yml` 讀每個板子 artifact 的 `batman-build.txt`,`BATMAN_CHANNEL` ≠ `rel` → FAIL;`check-release-key-gate.sh` 加 `--publish` 模式(只接受 `rel`)供兩處呼叫。§3.7.2 寫明「R 之前不能用 `build-release.yml` 發布」—— **這是使用者要拍板的取捨**:P3 合併到 #255 之間不能發公開 release(或發布前得先把 P3 的 update 動詞關掉)。
- **測試**:workflow lint:`build-release.yml` 沒呼叫 `--publish` → FAIL;腳本層:`wsl` / `ci` 的 `batman-build.txt` + `--publish` → FAIL、`rel` + R 指紋 → PASS。

### MINOR

**m1 鎖與 `.busy` 的內容不是原子寫入 → 讀到空檔 = 「持有者死了」→ 鎖被接手 / helper 判不忙**

- 情境:現行 `slot_lock` 先 `mkdir` 再 `echo $$ > pid`(V5);v7.5 還要先讀 `/proc/$$/stat` 取 starttime(多一個子程序,窗口變寬)。另一個 `batman-slot` 剛好在空窗讀到空 pid → 「不活著」→ `rm -rf` 接手 → 兩個寫者。`.busy` 同理:Go 的 `otaBusy` 讀到空 / 半行;§5.3 表(`:600`)寫「持有者規則不成立 → 不忙」= fail-open。
- 修法:內容一次寫好再出現:`.busy` 寫 tmp 檔後 `mv`(同目錄 rename 原子);鎖改成 `ln -s "<pid> <starttime>" $LOCK`(symlink 建立 = 原子且帶內容,`readlink` 讀),或 mkdir 一個私有 tmp 目錄寫好 pid 後 rename 成鎖名。內容在原子寫入下只可能被 root 竄改 → 格式不對 = 忙 + 記 TAMPER(fail-closed)。
- 測試:接縫在「建鎖」與「寫內容」之間暫停,另一個 `batman-slot write` → rc 14;負對照:現行 mkdir-then-echo → 接手。

**m2 starttime 取法的共用測試向量**

- 規則本身沒問題:pid 與 starttime 由 kernel 產生、在 root-only rundir;pid 要在同一個 10 ms tick 內繞回才會撞(4 核 pid_max 32768 → 需每秒數百萬次 fork,不可能);helper 不 unshare pid ns,讀寫在同一個 pid / time namespace。只剩實作坑:comm 可含 `)`、空白、換行;shell 若逐行處理(`read`、`sed`)遇到換行會錯位。
- 修法:shell 以整檔內容 `${s##*)}` 取、Go 以 `bytes.LastIndexByte`;同一組向量(comm = `a) b`、`x\ny`、15 字元)跑兩邊。

**m3 私有 mount namespace 的副作用要寫進 §6 / §7**

- (a) superblock 跨 namespace 共用(V3):helper 的 `write` 把目標 FAT rw 掛在自己的 ns 時,init ns 裡任何人的 ro 掛載會 `EBUSY`;以前會在 `/proc/mounts` 看到並重用(V6 的模式)。產品端現在只有 `commit` / `rollback` 這樣讀,而它們拿鎖(V6)→ 沒事;harness 的鎖外掛載(§3.7.3 已列 #290)會從「讀到」變成「掛不上」。§3.7.3 寫一句「boot FAT 的讀者一律經 `bootinfo` 或鎖內」。
- (b) rc 14 的 major:minor 檢查只看得到 fork 時從 init ns 複製來的掛載;其他 namespace(特權容器)的掛載看不到。只有 root 等級做得到(V4),同一個 sb 時快取一致;經 loop 裝置另起 sb 時不一致 → 讀回失敗 → fail-closed。列 §7 誠實界線。
- (c) rc 14 不會被非特權行程永久觸發(V4、V5)✅;操作員 / sysupgrade 殘留 → 已在 §6:633。

**m4 bearer 的格式與「沒有窗」時的比對**

- 情境:constant-time 比對空字串 = 相等。provd 若在 poll 給了「窗開」但 bearer 欄位缺 / 空(helper bug、版本不一)時,`X-Batman-Upload:`(空)會通過。
- 修法:provd 只在持有 16 bytes bearer 時接受 PUT;header 必須正好 32 個小寫 hex,否則 401/409,不進比對。poll 的解析錯誤訊息不得帶原始欄位。
- 測試:窗開、bearer 缺 → 空 header PUT 被拒;logread / provd log / 診斷包 grep 不到 bearer(§8 既有的秘密檢查加這個值)。

**m5 第一遍「只驗不寫」與步驟 4「boot 成員寫進 `/tmp/run/batman/update/boot/`」要對齊**

- 步驟 4 用 `O_CREAT|O_EXCL` 寫 boot 檔;步驟 5 說第一遍只驗不寫,步驟 6 又「重新解壓」。照字面,第二遍會再寫 boot 檔 → `EEXIST`;或者第一遍不寫,第二遍才寫 → boot 檔來自第二遍的 bytes。寫明:第一遍把 boot 檔寫進 helper 目錄(「不寫**槽**」),第二遍只串流 `root.squashfs`、跳過 boot 成員(或比對 sha 後丟掉)。有 MAJOR-1 的 lease 後兩遍內容相同,這只是讓實作不歧義。

**m6 tmpfs 沒掛上時誰擋;縮小窗外的常駐 RAM**

- 「掛不上 → 不開上傳」(§3.8.2)沒有指定檢查者:init 失敗後 `/tmp/run/batman-provd-bulk` 是 `/tmp` 上的普通目錄(沒有 `size=`)仍被 rw 掛進 jail。修法:helper 在 `bulk.open` 時對 dirfd `fstatfs` = `TMPFS_MAGIC`,且 `st_dev` ≠ `/tmp/run` 的(是掛載點),否則 reason 21。
- 選配(減少被入侵 provd 的影響、不加新行程):窗外 helper `mount -o remount,size=4k`,`bulk.open` 時改回 2 × payload;remount 縮小在有人佔用時失敗 → 反而成為「provd 保留了檔」的偵測。2 GB TAK 節點常駐 241 MiB 可被佔用的時間從「一直」變成「只有窗內」。

**m7 還沒跟上 v7.5 的文字(會讓實作照舊做)**

- §3.7.5-1 括號「截斷不到 worker 正在讀的檔」→ MAJOR-1 後改寫。
- §4(`:530`)「gate 在 `build-board.sh`」→ 兩處呼叫 + 發布點(MAJOR-2)。
- §7(`:659`)與附錄 B(`:949`)「窗外 helper 每個 poll 週期刪檔」≠ §3.8.2 的刪檔時機(A10-m15 統一後應刪)。
- §12(`:781`)「`BATMAN_CHANNEL` ≠ `wsl` 的 image 若含 T → 不出貨」≠ §3.7.2(`ci` 也信任 T)。
- §5.3(`:600`)`.busy`「持有者規則不成立 → 不忙」→ m1。
- §12.5 負對照(`:850`)release-sign 只列 `wsl`;加 `ci`、`rel` + T、未知通道。
- harness `tests/keys/README.md`、`signrel.py` 的「T 只給 prov_test」(附錄 G 已排進 harness PR,確認有寫進 #254 checklist)。

## 4. 確認沒問題的部分(✅,附證據)

- 鎖 / `.busy` 不能被非特權行程偽造(root-only rundir,V5);starttime 由 kernel 產生,pid 重用擋得住(m2)。
- 私有 mount ns:go1.26.4 會把 `/` 設成 rprivate(V1);`batman-slot` 寫進 `/boot`(p1)與 `/opt/batdata` 仍是同一個 sb;KILL 後掛載隨 ns 消失;產品端唯一的「看到掛載就重用」讀者都在鎖內(V6)。
- 非特權行程掛不了 boot FAT(V4)→ 不能用 rc 14 永久卡住更新。
- `92-batman-ramoops-fix` 只改執行槽自己的 FAT、在 uci-defaults(helper 之前)(V7);key 8 列改前 / 改後 sha 的規則足夠。
- AEAD 失敗丟棄不中止:`Decrypt` 失敗不推進 nonce(V8);要把現行 `session.go:314-322` 的 `msgs++` / `lastActive` 移到成功之後(設計已寫)。
- bearer 經 poll:helper socket 只收 uid 471(V13),poll 路徑沒有新的讀者。
- 不綁 IP:bearer 在 Noise 回應裡;IP 綁定對能偽造 IP 的 AP 鄰居無效;內容由簽章 + 第一遍完整驗證把關。
- 通道白名單、未知通道 stamp 失敗;`fast-build.yml` 不放鑰匙 → reason 21(V11,fail-closed)。
- nft:`iifname != br-ahwlan` + bridge mark 兩道;表不在 = 不聽。
- SUMS 名字規則不允許 `~` → FAT 8.3 短名別名(`DISTRO~1.TXT` 等)碰不到受保護檔;且複製集合是類別白名單。

## 5. 判定

**APPROVE-WITH-CHANGES(0 BLOCKER / 2 MAJOR / 7 MINOR)。**

沒有 BLOCKER:我追過的路徑最後都停在「目前槽可用、目標槽 BAD 或未 arm」,完整性(簽章 → SUMS → 讀回)沒有缺口。

兩個 MAJOR:
- MAJOR-1:v7.5 唯一新增的機制(兩遍)對「被入侵的 provd 保留寫入 fd」不成立,而且設計文字宣稱成立。修法是 kernel 的 F_RDLCK lease,約 10 行,有負對照。
- MAJOR-2:「DEV 通道永不出貨」只有文字,發布 workflow 會照提交的 `wsl` 通道把信任公開 T 的 image 發出去。修法是發布點加一個通道檢查;需要使用者決定「R 之前不發公開 release」。

依規則,MAJOR 改完後整份再審。
