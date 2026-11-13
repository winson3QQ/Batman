# 254-p3-impl v7.11(8f9eab6)抽查 B — 安全優先

範圍:v7.10 的 18 項 MINOR(A16-m1..m11、B16-m1..m7)逐項對**正文**(§1–§12,不看附錄 M);攻擊 v7.11 的改動(`git diff 11ade69 8f9eab6`);S5 其他地方看到的 BLOCKER / MAJOR 照報。只讀:沒有改任何 repo,沒有上節點。原始碼:Batman-p3 @ 8f9eab6、firmware-2710 @ 02f0913d。qemu 腳本與輸出:scratchpad `s5/flt711/`(`run.sh`、`writer.sh`、`holder.sh`、`out.txt`)。

## 0. 更正我上一輪的紀錄

v7.10 那一輪(`s5/flt710/`)的 shell 是 target busybox,但 `flock` 在 qemu-user 下**解析到 host 的 util-linux flock**,不是 target 的 busybox applet。證據:同樣的呼叫方式下,`flock` 無參數印出 `flock: not enough arguments / Try 'flock --help'`(util-linux 的訊息)。kernel flock 的語意相同,所以結論不變。不過「以 target busybox 驗證」這句話上一輪不成立。本輪改用 wrapper,強制走 `qemu-aarch64-static -L root-bcm27xx bin/busybox flock`,輸出第一行是 `BusyBox v1.36.1 (2025-06-23 20:40:36 UTC) multi-call binary.`,全部重跑一次(見 §2.1)。

## 1. v7.10 的 18 項 MINOR(看正文)

| 項目 | v7.11 正文 | 判定 |
|---|---|---|
| A16-m1 / B16-m5:disarm tick 的先後 | §3.7.4 `:402`「**先 TryLock `slotMu`**…拿到之後才讀 update-last」;§12.5 `:884` 有負對照 | ✅ 關閉 |
| A16-m2:`n.mu` 加進鎖的順序 | §3.7.4 `:390` 寫了 `n.mu` → `slotMu` → `updMu`,並規定「worker 與所有 tick 永遠不拿 `n.mu`」。但「不等 worker」仍然只限「持 `updMu` 時」。`owner/remove` 在 `n.mu` 裡中止 worker(`:390` 括號、`:441`),沒有禁止它在 `n.mu` 內等 worker 結束 | ⚠️ 部分 → m3 |
| A16-m3:拿掉 `umask 077` | §3.7.3 `:368` 寫「不改 umask」;§5.3 `:618` 是 0644,保護來自 RunDir 0700。qemu:子程序的 umask 是 0022,鎖檔 644(§2.1) | ✅ 關閉。新的依賴 → m2 |
| A16-m4 / B16-m2:`slot_busy` 完整函式與負對照 | §3.7.3 `:368` 有完整函式;§12.5 `:883` 有負對照。qemu 照字面跑過,全部符合(§2.1) | ✅ 關閉 |
| A16-m5:prepare 的孤兒判斷 | §3.7.4 prepare 列 `:397`;§3.7.3 rc 14 列 `:383`;§5.1 `:572`;§3.7.5-4 改成引用;§12.5 `:885` | ✅ 關閉 |
| A16-m6 / B16-m1:gate 只有一個入口 | §3.7.2 `:343`、§7 `:687`、§10 `:757` 三處說法一致了;§10 檔案清單裡「Batman `scripts/check-release-key-gate.sh`」已經刪掉;有結構測試 `:886`。**還沒做到的**:`build-board.sh` 第 7 步用的是 `gate-rootfs.sh --extract`(`build-board.sh:206`),這個模式不跑任何 gate,而 `--card-only` 會跳過第 8 步(`local-ab-tar`);`--ci` 與 `--normal` 的關係沒有定義;沒有 stamp 的 image(fast-build)要怎麼判,沒寫;轉賣清單由誰寫入,沒寫 | ⚠️ 部分 → m1 |
| A16-m7:拿掉多餘機制 | 正文已經找不到 `batman-release.env` 檢查、`wbox_env_reset`、釘死的 T 指紋(只剩附錄);§12.5 `:909`、`:917` 也改了 | ✅ 關閉。拿掉之後的安全性見 §2.3 |
| A16-m8 / B16-m3:`trust`、一行、FIFO | §3.7.1 `:315`:`none` / `bad` 的定義、「一行」可以有結尾 `\n`、`O_NONBLOCK`、≤ 256 B、`fstatfs` = squashfs;§5.3 `:619-621` 加了三列(含 `release-root.fpr` 是 64 個小寫 hex);§12.5 `:887` 有 FIFO 負對照 | ✅ 關閉(§3.7.4 `:427` 的列舉少了「不是 squashfs」,只是措辭 → m5) |
| A16-m9:版本正規式 | §3.7.1 `:328` 寫出了正規式,`+meta` 允許 `-` | ✅ 關閉 |
| A16-m10:§6「p6 沒掛上」 | §6 `:651` | ✅ 關閉 |
| A16-m11:harness UD18、rundir-paths | §10 `:758` | ✅ 關閉 |
| B16-m4:update-last 怎麼判斷掛載點 | §3.7.4 `:401`:看 mountinfo、確認「來源是 p6」、`state` 以 `O_NOFOLLOW` 開;§6、§12.5 `:888` | ✅ 關閉(「p6」用什麼判斷沒寫 → m4) |
| B16-m6:app 計數漏了 409 / 0 + 11 | §3.11-5 `:509` 加了 0 + 11 的文字;§3.11-12 `:516` 的計數算進 409 與 0 + 11 | ✅ 關閉(「換密碼後仍失敗 → 重燒」這句沒加,算 nit → m5) |
| B16-m7:文字與 `sleep 2.5` | §5.1 `:572`、§3.7.3 `:383`;§12.5 `:913` 改成 host 端 flock 持鎖;附錄 M 補了 B15-MAJOR-1 的更正 | ✅ 關閉 |

小計:14 項關閉,4 項部分關閉(A16-m2、A16-m6 / B16-m1,另外兩項是 nit),沒有完全沒關的。附錄 M 說「全部處理」,實際上有兩處只做了一半。

## 2. 攻擊 v7.11 的改動

### 2.1 `slot_busy` 與寫者(qemu + target busybox 1.36.1 的 flock applet)

照 v7.11 §3.7.3 的字面寫:

```
slot_busy(){ [ -e "$LOCKF" ] || return 1; command -v flock >/dev/null || return 0;
             ( exec 8<"$LOCKF" && flock -s -n 8 ) && return 1; return 0; }
```

寫者照「沒有 umask;`command -v`;`exec 9>>`;最多試 4 次,每次 `sleep 1`」來寫。`s5/flt711/out.txt` 的原始輸出:

```
flock used: /tmp/tmp.KunIrBMbUg/bin/flock -> BusyBox v1.36.1 (2025-06-23 20:40:36 UTC) multi-call binary.
MODE=nofile slot_busy=1 (want 1)
MODE=idle slot_busy=1 (want 1)
MODE=busy slot_busy=0 (want 0)
MODE=sameshell slot_busy=1 then writer rc=0 after 0s (want 1, 0, 0s)
MODE=noflock slot_busy=0 (want 0)
sh: .../case.sh: line 5: can't open .../batman-slot.flock: Permission denied
MODE=noperm(non-root) slot_busy=0 (want 0) caller alive
  try 1 fail @73922.98
  try 2 fail @73924.02
MODE=hold3 (busybox holder.sh exclusive 3s, writer starts at +1s) writer rc=0 after 2s
  try 1..4 fail @73926.14 .. 73929.22
MODE=hold4 (busybox holder.sh exclusive 5s, writer starts at +1s) writer rc=14 after 3s
  writer child umask: 0022
MODE=mode lock file: 644 (umask 022)
```

各項的意思:

- 沒有鎖檔、或有鎖檔但閒置 → 不忙。
- 被持有、找不到 flock、開檔失敗 → 忙,而且呼叫端的 shell 照常執行(fail-closed)。
- 同一個 shell 先跑 `slot_busy`,接著寫者 → rc 0,鎖沒有留下。
- 寫者試 4 次、約 3 s,之後回 rc 14。
- 拿掉 umask 之後,子程序的 umask 是 0022,鎖檔是 0644。

✅ 函式本身正確。

一個測試細節:target busybox 的 `flock -x FILE sleep N` 在 qemu-user 下,exec 子程序會因為找不到 `ld-musl` 而失敗。所以 §12.5 `:913` 寫「host 端 flock 持鎖」是對的做法,不要改回 target 的 `flock -x … sleep`。

### 2.2 拿掉 `umask 077`(0644 鎖檔)

- **有沒有非 root 的讀者或持有者?** RunDir 是 `/tmp/run/batman`。它的父目錄 `/tmp/run` 由 procd 以 root 0755 建立,比任何非 root 程序都早(`rundir.sh:9-11`)。`batman_rundir` 用 `mkdir -m 700` 建立,並驗證 owner、不是 symlink、模式等於 `drwx------`(`rundir.sh:23-33`)。sysupgrade 的 ramfs 裡,`/tmp` 會跨過 supivot,`rundir.sh` 也在 `RAMFS_COPY_DATA` 裡(`platform-ab.sh:40`)。stage 2 的 `batman-slot` 會重跑同樣的驗證(`batman-slot:62-63`)。讀者都是 root:Go helper,以及 autocommit。provd 在 jail 裡看不到 RunDir。結論:在 RunDir 驗證通過的前提下,非 root 開不到這個鎖檔 ✅。
- **但 v7.11 讓 0700 變成唯一的一道保護**,而設計沒有要求先驗證 RunDir 再開鎖。現行的 `slot_lock` 第一行是 `need_rundir`(`batman-slot:65,85`)。v7.11 的寫法是「每個動詞開頭 `exec 9>>$RUNDIR/batman-slot.flock`」,其中包括以前不寫入的 `bootinfo` 和 `precheck-node`,而文字裡沒有 `need_rundir`。`batman_rundir` 失敗時 `RUNDIR` 仍然是 `/tmp/run/batman`(`rundir.sh:19` 無條件設定)。所以 RunDir 不是 0700 的時候(例如某個 root 腳本用 `mkdir -p` 先建了它),`exec 9>>` 照樣會建出 0644 的鎖檔。這時任何非 root 程序都能 `open(O_RDONLY)` 再 `flock(LOCK_SH)`,而且可以一直持有。結果是所有寫者 rc 14、`otaBusy` 一直為忙、autocommit 一直延後。以前有 umask 077 時,鎖檔是 0600,這種情況擋得住 → m2。

### 2.3 拿掉釘死的 T 指紋與 `batman-release.env` 檢查

- stamp 從 `batman-release.env` 只讀固定的幾個 key(`stamp-batman-build.sh:22-24`,`get()` 一次一行、`head -1`)。這些值寫進 stamp 時一個 key 一行,沒有辦法藉換行注入一行 `BATMAN_BENCH_TRUST=`。拿掉那個檢查是安全的 ✅。
- 有沒有一般 image 會帶著 T?
  - stamp 先 `rm -f` 再放;
  - `wsl-build.sh` 不跑 stamp,會沿用上一次 stamp 的結果,但 stamp 和鑰匙是一致的(上一輪 W8);
  - 有人把 T commit 進 firmware 的 `files/`,或 feed 套件自己帶一份 `release-root.pub`:gate 檢查的是解開的 rootfs,一般 build「不得有 `release-root.pub`」→ FAIL。
  
  ✅,前提是每一條路徑都真的跑了 gate(m1)。
- CI 能不能做出 bench?
  - stamp 那一步有 `if:` 擋著,參數是固定的(`build-firmware.yml:134-138`);
  - `fast-build.yml` **根本不跑 stamp**(整個檔案找不到 `stamp`),鑰匙檔不會出現;
  - `--ci` 遇到 bench 一律 FAIL。
  
  ✅。比對對象改成 feed 的 `T.pub`:簽章端 `signrel.py` 用的也是同一把,沒有新的洞。

### 2.4 `gate-rootfs.sh` 是不是唯一入口:逐條上傳路徑

| 路徑 | 現況(file:line) | v7.11 | 落差 |
|---|---|---|---|
| `build-firmware.yml`(PR / release / repro 都走它) | 「Stamp in rootfs」那一步自己解 squashfs,跑 `check-prov-test-gate.sh witness-root`(`:224-230`),排在 `Upload build artifacts`(`:285`)之前;只對 bcm2711 / 2710 跑 | 改成 `gate-rootfs.sh --ci` | `gate-rootfs.sh` 現在只有預設、`--normal`、`--extract` 三種模式(`gate-rootfs.sh:4-9,28-31`),`--ci` 是新的。設計沒有說 `--ci` 包含 `--normal` 的「wbox stamp → FAIL」。如果 `--ci` 走的是預設模式(variant 取自 stamp),CI 的 seam gate 反而比現在鬆:現在是一律以 normal 規則檢查 |
| `fast-build.yml` | `gate-rootfs.sh root.squashfs --normal`(`:189`),在上傳(`:191`)之前 | 列成 `--normal` | `--normal` 會不會帶 `--ci` 給 key gate(拒絕 bench),沒寫。fast-build 的 image **沒有 `/etc/batman-build`**(不跑 stamp):key gate 遇到「沒有 stamp」要判成一般 build(不得有鑰匙)還是 FAIL,沒寫 |
| `local-ab-tar.sh:73`(`wsl-build.sh`、`build-board.sh` 第 8 步) | 預設模式 | 列入 | ✅(依 stamp 判斷) |
| `build-board.sh` 第 7 步 | `gate-rootfs.sh --extract`(`:206`),之後另外呼叫 `check-pvs-shim` 和 `check-prov-test-gate`(`:209-211`)。註解寫明:`--card-only` 跳過第 8 步,這裡是卡片唯一的 gate(`:204-205`) | 列為「經 `gate-rootfs.sh`」;v7.10 原本明寫第 7 步呼叫 `check-release-key-gate.sh`,v7.11 刪了 | `--extract` 不跑任何 gate。**`build-board.sh --card-only` 做出的卡片 image(transfer-flash 和重燒用的就是它)沒有經過鑰匙 gate** |
| `build-release.yml` | 下載 build-firmware 的 artifacts,把 `*.img.gz` 附到 draft(`:211,251-262`) | 經由 build-firmware | ✅ |
| `github-release.yml` | 只建一份沒有檔案的 draft(`:20-24`) | — | 不適用 |
| 其他 workflow(kernel / toolchain / tools / push-containers / formal / label*) | 不產生 image | — | 不適用 |
| firmware `scripts/*.sh` | 除了上面幾支,沒有任何會上傳的腳本(`grep 'gh release\|curl -T\|upload\|scp'`) | — | ✅ |
| `release-sign.sh`(Batman) | 新 | 在 payload 上重跑 `check-release-key-gate.sh` | gate 搬到 firmware 之後,Batman 這邊的腳本要從哪棵 firmware 樹、哪個 commit 取得 gate,沒寫(prov-test gate 本來就有同樣的依賴) |

→ m1。

### 2.5 鑰匙檔:`O_NONBLOCK`、≤ 256 B、`fstatfs` = squashfs、`none` / `bad`

- FIFO:開檔不會卡住;不是 regular → `bad` ✅。
- 256 B 的上限大於 131 B 加換行,所以多出來的內容一定會被讀到 → 多行或格式錯 → `bad` ✅。
- `fstatfs` 取代 `st_dev` 比對:
  - 中間目錄如果是 symlink,絕對路徑會落到 overlay → 不是 squashfs → `bad`;
  - `/rom` 沒掛上而 overlay 上有 `/rom/usr/share/batman/` → overlay → `bad`;
  - 能另外掛一個帶 T 的 squashfs 到 `/rom/...` 的只有 root,而 root 本來就能直接換掉 helper(誠實界線,§7 的 root 列只宣稱擋「overlay 上放的檔」)。
  
  ✅。
- `none` / `bad` 的定義在 §3.7.1、§5.3、§12.5 一致。§3.7.4 `:427` 的列舉少了「不是 squashfs」、FIFO,只是措辭 → m5。

### 2.6 update-last 的 mountinfo 判斷

- helper 本身在 init namespace(`Unshareflags = CLONE_NEWNS` 只用在 `batman-slot` 子程序,`:364`;Go 原始碼除了 vendor 之外沒有 `Unshare`)。所以 `/proc/self/mountinfo` 看得到 p6 ✅。
- 「來源是 p6」用什麼判斷沒寫:裝置名稱 `mmcblk0p6`?major:minor?還是分割編號?`otatrace.sh:33` 只看掛載點,不看來源。另外,`state` 以 `O_NOFOLLOW` 開之後,tmp 檔、rename、fsync 必須都對那個 dirfd 做(`openat` / `renameat`),否則 rename 會重新解析路徑 → m4(nit)。

### 2.7 S5 其他地方

沒有找到新的 BLOCKER / MAJOR。上一輪確認過的項目都沒被 v7.11 改到:sha 綁定、租約、第一遍完整驗證、iifname、bearer 分離、只讀 `/rom`、stamp 只收參數。

## 3. Findings

**0 BLOCKER / 0 MAJOR / 5 MINOR**

**m1 「所有上傳路徑都經 `gate-rootfs.sh`」還有三個缺口(A16-m6 / B16-m1 只關一半)**
- **情境**:
  - (a) `build-board.sh --card-only` 只跑第 7 步的 `--extract`(`build-board.sh:204-206`)。v7.11 刪掉了第 7 步直接呼叫 key gate 的那句,於是卡片 image 不經鑰匙 gate。帶錯鑰匙的 `rel` 卡片(例如 stamp 的 bug 放了 T)會一路到工廠和 transfer-flash。
  - (b) `--ci` 是 `gate-rootfs.sh` 的新模式,沒有定義它和 `--normal` 的關係。如果它沿用預設模式「variant 取自 stamp」,`build-firmware.yml` 的 seam gate 就從「一律 normal」退成「wbox stamp 也放行」。stamp 的 `BATMAN_WBOX` 仍然從環境變數讀(`stamp:55`)。
  - (c) fast-build 的 image 沒有 stamp,key gate 遇到這種情況怎麼判,沒寫。另外,`--normal` 會不會把 `--ci` 傳給 key gate,也沒寫。
- **證據**:`gate-rootfs.sh:4-9,28-31`、`build-board.sh:204-211`、`fast-build.yml`(沒有 stamp)、`build-firmware.yml:224-230`。
- **修法(只改字)**:
  - 定義 `--ci` = `--normal`(wbox FAIL)加上「key gate 帶 `--ci`」,fast-build 與 build-firmware 都用 `--ci`(或者 `--normal` 本身就帶 `--ci`,只留一個旗標);
  - 沒有 `/etc/batman-build` 時 = 一般 build:不得有任何鑰匙檔;
  - `--extract` 也跑 key gate(依 stamp 判斷),或者第 7 步恢復直接呼叫;
  - 結構測試加 `build-board.sh` 第 7 步;
  - `release-sign.sh` 寫明從哪棵 firmware 樹、哪個 commit 取得 gate;
  - 轉賣清單由 `release-sign.sh` 在同一步寫入。

**m2 拿掉 umask 077 之後,0700 RunDir 是唯一的保護,但設計沒有要求先驗證再開鎖**
- **情境**:RunDir 驗證失敗時(`RDOK=0`,`RUNDIR` 仍然是 `/tmp/run/batman`),`exec 9>>` 照樣會建出 0644 的鎖檔。在一個不是 0700 的 RunDir 裡,非 root 程序可以 `open(O_RDONLY)` 再 `flock(LOCK_SH)`,而且一直持有 → 所有寫者 rc 14、`otaBusy` 永遠為忙。
- **證據**:`rundir.sh:19,23-33`、`batman-slot:62-65,85`(現行的 `slot_lock` 先 `need_rundir`);v7.11 §3.7.3 `:368` 寫的是「每個動詞開頭 `exec 9>>`」,包括以前不寫入的 `bootinfo` / `precheck-node`。觸發的前提是 root 端先犯錯(把 RunDir 建成 0755),所以是 MINOR。
- **修法**:9 個動詞在 `exec 9>>` 之前都要求 `RDOK=1`,否則以「其他」結束 → reason 21,不建鎖檔。Go 讀者在 open 之前檢查 RunDir(或者只在 `RDOK` 的路徑上開)。
- **負測試**:RunDir 改成 `chmod 755` → 每個動詞都拒絕,而且鎖檔不存在。

**m3 `n.mu` 內等 worker 沒有禁止(A16-m2 只關一半)**
- **情境**:`owner/remove` 在 `n.mu` 內中止 worker,如果它在 `n.mu` 內等 worker 結束,而 `dd` 卡在 D 狀態(SD 卡壞,§6 `:653`),TERM → KILL 之後 `Wait` 永遠不會回來。結果是所有非唯讀動詞(BLE 管理)都卡住,直到重開。
- **證據**:§3.7.4 `:390` 只寫了「持 `updMu` 時……不等 worker」。
- **修法**:加一句「持 `n.mu` 時不等 worker 結束:送出 TERM 就回應,收尾在 worker 自己的 goroutine 裡做」。§12.5 `:910` 的接縫測試加一種情況:worker 的子程序不理會 KILL(用接縫模擬)→ `owner/remove` 在 10 s 內回應。

**m4 update-last「來源是 p6」的判斷方式,以及 dirfd 的用法沒寫(nit)**
- **修法**:寫明 mountinfo 的掛載點欄位要先解 `\040` 等跳脫,再完整比對 `/opt/batdata`;來源用 major:minor 比對開機卡的第 6 個分割(和 `batman-slot` 找分割用同一條規則),不靠裝置名稱。tmp 檔、`renameat`、`fsync` 都對 `O_DIRECTORY|O_NOFOLLOW` 開出來的 dirfd 做。

**m5 措辭(nit)**
- §3.7.4 `:427` 的 `bad` 列舉補上「FIFO、不是 squashfs」,或者直接改成「其他任何異常(§3.7.1)」。
- §3.11-12 的出路文字補一句「換密碼後仍失敗 → 節點本身可能有問題,請重燒」(B16-m6 的建議)。
- 附錄 M 把 A16-m2、A16-m6 標成「全處理」,與正文不符(見上)。

## 4. 判定

**APPROVE-WITH-CHANGES(0 BLOCKER / 0 MAJOR / 5 MINOR)。**

- 18 項裡 14 項關閉、4 項部分關閉,沒有完全沒關的。`slot_busy` 與寫者以 target busybox 的 flock applet 重跑,全部符合(§2.1)。
- v7.11 拿掉機制的三處(umask、release.env 檢查、T 釘選)本身沒有引入可被利用的洞。但 umask 拿掉之後,「先驗證 RunDir 再開鎖」必須寫進契約(m2)。
- m1、m2 在實作 PR 之前要改字,不需要整份再審;m3–m5 可以併進實作 PR 的必做清單。
