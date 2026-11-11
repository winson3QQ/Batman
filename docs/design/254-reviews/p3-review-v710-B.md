# 254-p3-impl v7.10(11ade69)審查 B — 安全優先(S5 整份)

範圍:§3.7、§3.8、§3.11、§12(含 §12.5 負對照表、§12.5.18)、附錄 E–L,以及 §4 / §5 / §6 / §7 / §8 / §10 / §11 用到的列。只讀:沒有改任何 repo,也沒有上節點。原始碼版本:Batman-p3 @ 11ade69、firmware-2710 @ 02f0913d。target busybox 取自 `build_dir/target-aarch64_cortex-a72_musl/root-bcm27xx/`,用 qemu-aarch64-static 執行。本輪腳本與輸出放在 scratchpad `s5/flt710/`(`run.sh`、`writer.sh`、`holder.sh`、`out.txt`)。

## 0. 先更正我上一輪的說法

B15-MAJOR-1 寫的是「每一次試用都不會 commit」。**這句話誇大了**。重讀 `batman-autocommit:549-553`:`:550` 的 `slot_writer_alive` 只在 `if ! claim; then` 裡面被呼叫,也就是 claim 拿不到的時候。拿不到時,它要嘛 `exit 0`,要嘛 `continue`。`:213` 與 `:226` 在 watchdog / 退回的路徑上,那條路接著跑的是 `batman-slot reboot committed`,不開 fd 9。

所以照 v7.9 的大括號寫法,真正會出事的是這個情況:main 碰到一次殘留的 claim(例如 main 在 commit 中途被 restart),之後同一個 shell 再去 `batman-slot commit`,就會一直 rc 14,直到期限到了退回。一般的更新流程不受影響。這仍然是 bug,而且已經修了;但嚴重度應該是 MINOR 到偏輕的 MAJOR,不是「所有更新都失敗」。請在附錄 L 那列補註這一點。

## 1. 本輪自己查證的事實

| # | 事實 | 證據 |
|---|---|---|
| W1 | 照 v7.10 §3.7.3 字面寫的讀者 `[ -e "$F" ] && ( exec 8<"$F" && flock -s -n 8 )`,之後同一個 shell 跑寫者 → **rc 0**;拿 v7.9 的大括號版當對照 → rc 14 | `flt710/out.txt`:`MODE=v710 same-shell writer rc=0 after 0s`、`MODE=v79 … rc=14 after 4s` |
| W2 | 寫者照 v7.10 的寫法(`command -v` → `umask 077` → `exec 9>>` → 最多試 4 次,每次間隔 `sleep 1`):試 4 次、共約 3 s;對方持鎖 3 s → 拿到;持鎖 4 s → rc 14;建出來的鎖檔是 0600 | `out.txt`:`try 1..4 @72830.68…72833.71`、`hold3 rc=0`、`hold4 rc=14`、`writer created lock: 600` |
| W3 | 這個讀者式子的 rc **分不出「沒有鎖檔」和「忙」**:兩者都是 1 | `out.txt`:`MODE=busy reader rc=1`、`MODE=nofile reader rc=1` |
| W4 | `exec 8<` 開檔失敗(權限)只會讓 subshell 結束,rc 1,呼叫端的 shell 照常執行 | `out.txt`:`MODE=noperm reader rc=1`、`caller shell still alive: yes` |
| W5 | target busybox 沒有 `usleep`,`sleep 2.5` 也會直接失敗(`CONFIG_FLOAT_DURATION` 沒開)。上一版 `run.sh` 裡用 `sleep 2.5` 持鎖的 holder 一啟動就結束了 → §12.5「另一個持鎖 2.5 s」這一列不能用 target 上的 sleep 來做 | `ls root-bcm27xx/bin/usleep` → 不存在;第一次執行時 `hold25` 那一臂的輸出 |
| W6 | **`build-firmware.yml` 沒有呼叫 `gate-rootfs.sh`**:它自己用 `unsquashfs4` 解開,然後直接跑 `check-prov-test-gate.sh`(`:224-230`)。只有 `fast-build.yml:189` 呼叫 `gate-rootfs.sh --normal`。`local-ab-tar.sh:73`(`wsl-build.sh` 與 `build-board.sh` 第 8 步會走到)呼叫的是**沒有** `--normal` 的版本。`build-board.sh:206` 第 7 步只用 `--extract`,gate 另外呼叫 | `grep gate-rootfs` 的結果 |
| W7 | CI 的 stamp 呼叫 `sh scripts/stamp-batman-build.sh "${{ inputs.board }}"`,前面有 `if: inputs.board == 'ekh-bcm2711' \|\| …` 擋著 → 從 workflow input 塞不進 `--bench`。所以 CI 要做出 bench,只能改 workflow 本身 | `build-firmware.yml:134-138` |
| W8 | `wsl-build.sh` 只跑 `make` 加 `local-ab-tar.sh`,**不跑 stamp**。前一次 bench build 留在 `files/` 的 T 與 stamp 會一起被沿用 → 做出來的是一份「一致的」bench image(stamp 也寫著 bench),不是「沒標示的一般 image 帶著 T」 | `wsl-build.sh:20-34` |
| W9 | `batman-slot` 的持鎖動詞在 `umask 077` 下會建的檔案有:`$RUNDIR/shutdown.reason`(`:737`)、第一次建立的 `ota-trace.log`(`otatrace.sh:34`)、目標 FAT 的掛載(vfat 的權限來自掛載時的 umask,讀它的只有 root 的 `bootinfo`)。背景的 `openmanetd start`(`:781`)雖然會繼承 umask,但 daemon 是 procd 起的,用的是 procd 自己的 umask;init 腳本本身不建檔。**找不到非 root 的讀者** → umask 077 沒有副作用 | `batman-slot:737,781`、`openmanetd.init`、`otatrace.sh:26-35` |
| W10 | `otaBusy` 在 helper(root)裡(`node/wtxn.go:451`);Go 的 `os.Open` 帶 `O_CLOEXEC` | 原始碼 |
| W11 | 目前的 p6 寫者判斷掛載點,用的是 `grep " /opt/batdata " /proc/mounts`(`otatrace.sh:33`)。設計給 update-last 用的是另一條規則:`st_dev ≠ /` | 原始碼、§3.7.4 |

## 2. v7.9 的發現逐條確認(看原文,不看附錄 L 的說法)

| 發現 | v7.10 原文 | 判定 |
|---|---|---|
| **B15-MAJOR-1** 讀者把鎖留在 shell 裡 | §3.7.3:改成 subshell,並寫明原因;Go 開檔、拿鎖之後立刻 `Close`、不快取 fd;lint 規定 `exec N<` 只能出現在 `( … )` 裡;§12.5 加了同一個 shell 的負對照(target busybox) | ✅ 關閉(W1)。式子本身的 rc 有歧義 → m2 |
| B15-m1 舊文字 | §5.3:共享鎖、0600(umask 077)✅;§3.7.3:4 次約 3 s ✅(W2);§3.7.2:draft ✅;§7 加了「CI 遇 bench 一律 FAIL」,但寫的機制是 `gate-rootfs.sh --normal`,而 `build-firmware.yml` 根本沒有呼叫它(W6) | ⚠️ → m1 |
| B15-m2 鑰匙檔的狀態一律 24 | §3.7.1、§5.1、§12.5 都改成 24 ✅ | ✅;`trust` 的對應前後不一致 → m3 |
| B15-m3 stamp 改收參數、T 指紋釘死 | §3.7.2 ✅;§12.5 有兩個負對照 ✅ | ✅(另見 §3.2) |
| B15-m4 所有上傳路徑都要過 gate | 文字寫「併進 `gate-rootfs.sh --normal`,一個入口涵蓋所有會上傳 image / payload 的路徑」。實際程式不是這樣(W6);轉賣清單「拒收 bench」沒寫怎麼做 | ❌ 只關一半 → m1 |
| B15-m5 `/rom` 開檔方式 | §3.7.1:`O_NOFOLLOW`、regular、`st_dev` ✅ | ✅;FIFO、大小上限、更簡單的判法 → m3 |
| B15-m6 指紋的定義 | sha256(65 B 的點);status 只顯示前 8 bytes ✅ | ✅;`release-root.fpr` 的檔案編碼沒寫 → m3 |
| B15-m7 DoS 的出路 | §3.11-12、§7 都寫了「換 AP 密碼」✅;一次性 bearer 不做(理由:不必要) | ✅;計數漏了兩種情況 → m6 |
| A15-m1 鎖的順序 | §3.7.4 ✅ | ✅;disarm tick 的讀取時機 → m5 |
| A15-m2 app 計數含 status 0 + 15 | §3.11-12 ✅ | ✅ |
| A15-m3 寫者重試、`exec` 失敗、0644 | ✅(W2);`exec` 失敗 → rc 1 → reason 21,文件有寫 | ✅ |
| A15-m4 §5.3 的 flock 列 | ✅ | ✅ |
| A15-m5 / m6 / m7 | 24 ✅;版本文法以本文件為準 ✅(A 建議的正規式沒有寫出來,由 A 判斷);`.bench` 的位置 ✅ | ✅ |
| A15-m8 孤兒 boot 目錄改在 prepare 同步處理 | §3.7.5-4 ✅;**§5.1 的 `update.prepare` `E_BUSY` 列與 §3.7.3 rc 14 列(還寫著「新 worker 建 boot 目錄前」)沒有跟著改** | ⚠️ → m7 |
| A15-m9 update-last 不寫進 overlay | §3.7.4 ✅ | ✅;用來判斷的規則 → m4 |
| A15-m10 / m11 | ✅ | ✅ |

## 3. 攻擊 v7.10(整份 S5)

### 3.1 subshell 讀者與 Go 的 Close

- shell:W1 / W4 證實讀者不會留下鎖,開檔失敗也不會讓呼叫端結束。剩下的問題是 rc 的歧義(W3)。設計的文字寫了「不存在 = 不忙」,但給的式子在檔案不存在時回 1,和「忙」一樣。
  - 試用開機時 RunDir 是新的 tmpfs,在 commit 之前沒有任何持鎖動詞跑過 → 鎖檔在這時一定不存在。
  - 實作者如果把整個式子取反來當 `slot_writer_alive`,檔案不存在就會被當成「有寫者」:`:213` 永遠不接手殘留的 claim(要等 30 分);`:226` 每次退回都延後 `DEFER_MAX`;`:550` 在 claim 拿不到時 `exit 0`。一般 commit 不受影響,但這三條處理例外的路都會壞掉。§12.5 沒有「沒有鎖檔」的負對照 → m2。
- Go:`Open` → `Flock(LOCK_SH|LOCK_NB)` → `Close`。另一個 goroutine 剛好 fork 時,子程序在 exec 之前會短暫持有同一個 OFD,但 `O_CLOEXEC` 讓它在 exec 時就關掉;這段時間由寫者的 3 s 重試吸收 ✅。`otaBusy` 在 root 的 helper 裡(W10),非 root 碰不到 RunDir ✅。

### 3.2 bench 旗標只從 stamp 參數來;gate 釘死 T 的指紋

- CI 不能經 input 注入 `--bench`(W7)✅。直接執行 stamp 或設環境變數,都只會做出一般 build ✅。
- 釘死 T 指紋的實際價值要寫清楚。gate 腳本與 `T.pub` 在**同一個** repo(Batman),而且執行的都是 `feeds/batman/` 裡的那份。所以 feed 被改的時候,兩者可以一起被改:釘選擋的是「T.pub 被有意或無意重新產生並 commit,gate 卻沒改」這一類我們自己的錯,不是被改過的 feed(那種情況照樣只會變 DIRTY)。§3.7.2 寫的理由(「feed 被改只會變 DIRTY」)套在釘選本身也一樣成立。建議文字改成「擋 T 被換掉卻沒人發現」,不必加機制 → 併入 m1。
- `wsl-build.sh` 會沿用上一次 bench 留下的 `files/`(W8)。做出來的 image 標示一致(stamp 寫著 bench、`trust` = T),不會變成「沒有標示的一般 image」✅。

### 3.3 `gate-rootfs.sh --normal` 有沒有涵蓋每一條上傳 image / payload 的路

| 路徑 | 現在 | v7.10 文字 | 落差 |
|---|---|---|---|
| `build-firmware.yml`(PR / release / repro) | 自己解開 squashfs,直接跑 `check-prov-test-gate.sh`(W6) | §3.7.2:在 `:227-230` 加 `check-release-key-gate.sh`;§7:「CI(`gate-rootfs.sh --normal`)遇 bench 一律 FAIL」 | 兩處說法不同。`check-release-key-gate.sh` 怎麼知道自己在 CI、遇到 bench 要 FAIL,沒有寫(參數?環境變數?)。§12.5「`build-firmware.yml` 以 bench 建 → FAIL」在 CI 上做不出來(W7),只能離線用一份 bench squashfs 測 |
| `fast-build.yml` | `gate-rootfs.sh --normal`(`:189`),排在上傳之前 | 鑰匙規則併進 `--normal` | ✅(實作照寫即可) |
| `local-ab-tar.sh`(`wsl-build.sh`、`build-board.sh` 第 8 步) | `gate-rootfs.sh`,不帶 `--normal`,variant 取自 image 自己的 stamp | 沒提到 | 非 normal 模式要不要檢查鑰匙,沒有寫 |
| `build-board.sh` 第 7 步 | `--extract` 之後各個 gate 分開呼叫 | 呼叫 `check-release-key-gate.sh` | ✅ |
| 轉賣工具清單 | — | 「拒收 bench」 | 由誰、在哪一步、用什麼判斷,都沒寫 |

結論:「一個入口」這個說法和程式碼不符 → m1。修法是讓它真的變成一個入口,不必加新東西。

### 3.4 `/rom`:`O_NOFOLLOW` + regular + `st_dev`

- `O_NOFOLLOW` 只管最後一段路徑。中間的目錄如果是 symlink(例如 `/rom/usr/share/batman` → `/etc/x`),絕對路徑的 symlink 會從程序的 `/` 解析,落在 overlay → `st_dev` 不同 → 被拒 ✅。所以 `st_dev` 這一道是必要的,而且足夠。
- squashfs 裡可以放 FIFO。`O_RDONLY` 開一個沒有寫者的 FIFO 會一直卡住。status 每次都要算 `trust`,卡住就等於 helper 的 status / check 全部卡死。gate 雖然要求 squashfs 裡是 regular file,但執行端應該照 worker 的做法加 `O_NONBLOCK`,並限制只讀 ≤ 256 B → m3。
- 更簡單、拿掉一個依賴的判法:對開好的 fd 做 `fstatfs`,要求 `f_type == SQUASHFS_MAGIC`(0x73717368),取代「`stat("/rom")` 再比 `st_dev`」。這樣不用另外 stat `/rom`,在任何掛載模式下都直接確認「這份資料來自 squashfs」→ m3(可選)。

### 3.5 鑰匙檔的狀態 → reason 24 與 `trust`

- reason 一律 24 ✅,只在 `update.check` 第 1 步、寫任何東西之前判斷 ✅。
- `trust` 的對應前後不一致:
  - §3.7.1:「`/rom` 不存在、不是 regular、symlink → **當作沒有鑰匙**」(讀起來是 `none`);
  - §3.7.4 與 §12.5:「symlink、不是 regular = `bad`」;
  - `/rom` 不存在、`st_dev` 不符時是哪一個,沒寫。
  
  → m3。
- §5.3 的介面表沒有鑰匙檔與 `trust` 這兩列(寫者 = stamp,讀者 = helper 經 `/rom`、格式、缺 / 壞 → 24、`none` / `bad`)→ m3。

### 3.6 umask 077

W9:找不到會被它影響的非 root 讀者,FAT 的權限也與它無關 → ✅,沒有發現問題。這是為了讓契約寫對而多加的一行,影響範圍只在 `batman-slot` 這個程序。

### 3.7 update-last 的 `st_dev` 檢查

`st_dev(/opt/batdata) ≠ st_dev(/)` 只能證明「`/opt/batdata` 和 `/` 不在同一個檔案系統」,證明不了「它就是 p6」。如果 `/opt` 本身是另一個掛載(tmpfs、或某個套件、payload 把東西掛在 `/opt`),p6 沒掛上時,`/opt/batdata` 是那個檔案系統上的普通目錄,檢查照樣通過,update-last 就寫到錯的地方。重開之後讀不到 → status 0(A15-m9 要擋的正是這種情況)。現有程式用的是 `/proc/mounts` 的完整比對(W11)→ m4。

### 3.8 DoS 的出路(換 AP 密碼)

- 換 AP 密碼確實趕得走知道舊密碼的鄰居;`settings.set` 只有在 worker 跑的時候才回 `E_BUSY`,開窗期間可以換 ✅。
- app 的計數只算 15。另外兩種干擾不會進到這個計數:
  - (a) 鄰居先開一個慢速 PUT,佔住唯一的 PUT 槽 → 擁有者收到 409「已有一個 PUT 在進行」,一直重試;
  - (b) 擁有者的 PUT 回 200 之後、prepare 之前,鄰居用同一個 bearer 寫一份大小相同的垃圾(`O_TRUNC`)→ worker 第一遍驗不過 → status 0 + 11。§3.11-5 沒有 0 + 11 的文字。
  
  兩種都只造成 DoS,但 app 會一直重傳,出路文字永遠出不來 → m6。
- 本機非 root 讀得到 AP 密碼(§7,0644,現況如此)。所以如果是節點上的程序在洩漏密碼,換密碼也沒用;這已經列在現有的界線裡,出路文字可以加一句「仍失敗 → 節點本身可能有問題,請重燒」。

### 3.9 行為者總覽

| 行為者 | 結果 |
|---|---|
| mesh 遠端 | 8095 被 bridge mark 加 iifname 擋;更新只走 Noise 擁有者 session ✅ |
| 手機 AP 上的裝置(知道 AP 密碼) | 只造成 DoS;內容由 pending S 綁 sha 把關(T 是公開的,但它換不掉 S);計數漏了 → m6 |
| 本機非特權 / docker / host-net 容器 | 碰不到 RunDir、鎖、`/rom`、bulk tmpfs;`SO_MARK` 被 iifname 擋 ✅;讀得到 AP 密碼(既有界線) |
| 被入侵的 provd(uid 471,jail) | 租約、unlink、fchown、第一遍完整驗證 ✅;DoS 重開後恢復 |
| 被移除的擁有者 / 成員 | 與 v7.9 相同 ✅ |
| 實體奪取 | secure boot 之前的界線 ✅ |
| 供應鏈 / 維護者 / CI | CI 結構上建不出 bench(W7)✅;gate 的入口說法與程式不符、轉賣清單沒有機制 → m1 |
| 我們自己的錯 | 讀者 rc 歧義(m2)、`trust` 對應(m3)、掛載點判斷(m4)、tick 的讀取時機(m5)、文字不一致(m7) |

## 4. Findings

0 BLOCKER / 0 MAJOR / 7 MINOR。

### MINOR

**m1 「一個入口」與程式碼不符;CI 判斷 bench 的方式沒寫;轉賣清單沒有機制**
- **證據**:W6(`build-firmware.yml` 不呼叫 `gate-rootfs.sh`;`local-ab-tar.sh` 不帶 `--normal`)、W7。§3.7.2 說 CI 用 `check-release-key-gate.sh`;§7 說 CI 用 `gate-rootfs.sh --normal`。
- **修法**(讓它真的只有一個入口):
  - `gate-rootfs.sh` 在兩種模式下都對解開的樹跑 `check-release-key-gate.sh`:非 normal 模式依 image 自己的 stamp 判斷(bench 只收釘死的 T;一般 build 不得有任何鑰匙;`rel` 只收 R 的釘選);`--normal` 另外拒絕 bench 與 wbox。
  - `build-firmware.yml:224-230` 改成呼叫 `gate-rootfs.sh "$SQ" --normal`,取代自己解開再跑 gate 的寫法。
  - 結構測試照 `test-prov-test-gate.sh:227-236` 的做法,確認 `build-firmware.yml` 與 `fast-build.yml` 都在 Upload 之前呼叫它。
  - §12.5「`build-firmware.yml` 以 bench 建 → FAIL」改成:離線對一份 bench squashfs 跑 `gate-rootfs.sh --normal` → FAIL,再加上述結構測試。
  - 轉賣清單:只收 `release-sign.sh` 簽過的 `rel` payload / image 的 sha,由 `release-sign.sh` 同一步寫入(它本來就會拒簽 bench)。
  - §7 那一列改成與 §3.7.2 同一種說法。
  - 釘死 T 指紋的理由改成「擋 T 被換掉卻沒人發現」(§3.2)。

**m2 讀者式子的 rc 分不出「沒有鎖檔」和「忙」,也沒有負對照**
- **證據**:W3;試用開機時鎖檔一定不存在(§3.1)。
- **修法**:§3.7.3 直接寫出完整函式,例如:`slot_busy(){ [ -e "$F" ] || return 1; ( exec 8<"$F" && flock -s -n 8 ) 2>/dev/null && return 1; return 0; }`(rc 0 = 忙)。§12.5 加一列:「RunDir 沒有鎖檔 → `slot_writer_alive` 為假、殘留的 claim 被接手」;負對照是把式子直接取反。

**m3 鑰匙檔:`trust` 的對應、FIFO / 大小、介面表**
- **對應**:寫成一張表:`/rom` 可用而且兩個檔都 `ENOENT` → `none`;其他所有情況(只缺一個、格式錯、symlink、不是 regular、`st_dev` 或 fs 不符、`/rom` 不可用)→ `bad`;reason 一律 24。§3.7.1「當作沒有鑰匙」改成「reason 24、`trust` = `bad`」。
- **開檔**:加 `O_NONBLOCK`,最多讀 256 B。可選:用 `fstatfs(fd).f_type == SQUASHFS_MAGIC` 取代 `st_dev` 比對(拿掉對 `stat("/rom")` 的依賴)。
- **負測試**:squashfs 裡放一個 FIFO 當 `release-root.pub` → check 立刻回 24、status 照常回應。
- **介面表**:§5.3 加兩列,`release-root.pub` / `release-min-serial`(stamp → helper 經 `/rom`)與 status 的 `trust`。`release-root.fpr` 的檔案格式寫死(一行、64 個小寫 hex、結尾一個換行)。

**m4 update-last 判斷掛載點的規則不夠**
- **證據**:§3.7、W11。
- **修法**:比 `/opt/batdata` 與它的父目錄 `/opt` 的 `st_dev`(標準的掛載點判斷),或照 `otatrace.sh:33` 用 mountinfo 確認 `/opt/batdata` 是掛載點,兩邊用同一條規則。`state` 以 dirfd 加 `O_DIRECTORY|O_NOFOLLOW` 開,並要求它的 `st_dev` 等於 `/opt/batdata` 的。
- **負測試**:`/opt` 掛一個 tmpfs、p6 沒掛上 → `E_STORAGE`。

**m5 disarm tick 必須在拿到 `slotMu` 之後才讀 update-last**
- **情境**:tick 先讀到 `{apply_boot_id = 本次, rebooting: false}`(apply 正在 arm),接著 apply 寫好 `rebooting: true` 並放掉 `slotMu`;tick 這時 TryLock 成功,拿著舊的讀值去 disarm → 擁有者的 apply 被取消,2 s 後一般重開 → status 23。時間窗很小,結果是 fail-safe(只是更新失敗),但它違反了「tick 不會取消擁有者的 apply」這個說法。
- **修法**:tick 的順序寫死為 TryLock `slotMu` → 在 `updMu` 內讀 update-last、判斷 → disarm → 在 `updMu` 內清除。這也符合 slotMu → updMu 的順序。
- **測試**:接縫讓 tick 在讀與 TryLock 之間停 1 s,同時 apply 成功 → tryboot 旗標仍是 1。

**m6 app 出路的計數漏了 409 與 0 + 11**
- **證據**:§3.8.2(只有一個 PUT 槽、`O_TRUNC`)、§3.11-5 / -12。
- **修法**:§3.11-12 的「合計 3 次」也算進「409 已有 PUT 在進行,而且不是自己在傳」與「worker 的 0 + 11」;§3.11-5 加 0 + 11 的文字(「上傳的檔案與簽章不符,請重新上傳」)。出路文字最後加一句「換密碼後仍失敗 → 請重燒節點」。

**m7 文字不一致與測試做法**
- §5.1 `update.prepare` 的 `E_BUSY` 列加上「flock 被持有(上一個 helper 的孤兒 `write`)」;§3.7.3 rc 14 列的「新 worker 建 boot 目錄前」改成「`update.prepare` 同步檢查」(A15-m8 只改了 §3.7.5-4)。
- §12.5「寫者重試在 target busybox 上真的等」那一列:持鎖的一方不能用 target 的 `sleep 2.5`(W5)。改成 host 端 `flock -x <file> sleep 2.5`(kernel flock 在 host 與 qemu-user 程序之間有效),或改用整數秒加上寫者的嘗試時間點來判斷。
- 附錄 L 的 B15-MAJOR-1 補一句我上一輪的誇大(§0)。

## 5. 確認沒問題(✅)

- subshell 讀者不會留下鎖、開檔失敗也不會讓呼叫端結束;寫者 4 次約 3 s;鎖檔 0600(W1、W2、W4)。
- Go 讀者 `Close`、`O_CLOEXEC`,在 root 的 helper 裡。
- CI 在結構上做不出 bench(W7);stamp 不讀環境變數;`rm -f` 加上 rootfs 從頭重建。
- 只讀 `/rom`,`O_NOFOLLOW` 加 `st_dev` 擋得住最後一段與中間目錄的 symlink。
- umask 077 沒有副作用(W9)。
- 鎖的順序規則(A15-m1)、prepare 同步處理孤兒目錄、update-last 不建目錄。
- T 是公開的,但 AP 鄰居換不掉擁有者在 Noise 裡送的 S(sha 綁定)。

## 6. 判定

**APPROVE-WITH-CHANGES(0 BLOCKER / 0 MAJOR / 7 MINOR)。**

- v7.9 唯一的 MAJOR 已經依原文關閉,並以 qemu 加 target busybox 重新驗證(W1)。附帶更正:我上一輪對它影響範圍的描述誇大了(§0)。
- 優先改的 MINOR:m1(「一個入口」與程式碼不符,§7 的說法是錯的)、m2(試用開機時一定會碰到「沒有鎖檔」,要有完整函式與負對照)、m3(FIFO 會讓 status 卡住)。
- 沒有 MAJOR,不需要整份再審;MINOR 改完後抽查這幾處即可。

### 附:qemu 實跑原始輸出(`s5/flt710/out.txt`)

```
  reader rc=0
MODE=v710 same-shell writer(commit stand-in) rc=0 after 0s
  reader rc=0
  try 1 fail @72830.68
  try 2 fail @72831.69
  try 3 fail @72832.70
  try 4 fail @72833.71
MODE=v79 same-shell writer(commit stand-in) rc=14 after 4s
MODE=busy reader rc=1 (writer holds; nonzero = busy)
MODE=nofile reader rc=1 (no lock file; same rc as busy => expression alone cannot tell them apart)
sh: /tmp/tmp.uLJVZkh8yA/case.sh: line 3: can't open /tmp/tmp.uLJVZkh8yA/batman-slot.flock: Permission denied
MODE=noperm reader rc=1 (as non-root: open fails inside subshell)
  caller shell still alive: yes
  try 1 fail @72837.22
  try 2 fail @72838.23
  try 3 fail @72839.24
MODE=hold3 writer rc=0 after 3s (holder 3s)
  try 1 fail @72840.62
  try 2 fail @72841.64
  try 3 fail @72842.65
  try 4 fail @72843.66
MODE=hold4 writer rc=14 after 3s (holder 4s)
MODE=mode writer created lock: 600
```
(`busybox` 版本那一行顯示「applet not found」:這是因為呼叫時沒帶 applet 名稱,與結果無關。讀者 = §3.7.3 v7.10 的字面寫法;寫者 = `command -v flock || exit 18; umask 077; exec 9>>"$F" || exit 18; until flock -n 9 … 4 次 … sleep 1`;使用 target busybox,經 `qemu-aarch64-static -L root-bcm27xx`。)
