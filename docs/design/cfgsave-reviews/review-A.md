# Review A — cfgsave-stage-enospc (design v1 + commit 6d65ecd)

審查者 A(獨立、對抗式)。範圍:`git diff 4eba26d 6d65ecd`(`batman-config-save` feed/deploy 兩份 byte 相同 ✅ `cmp` 通過;設計 `docs/design/cfgsave-stage-enospc.md`;測試 `tests/prov-p1/cfgsave-stage-enospc.sh`;CI / stubs 接線)。程式碼唯讀;實驗在 WSL Ubuntu-24.04(kernel 6.6.114.1-microsoft-standard-WSL2,busybox 1.36.1)fresh clone `<home>/rev-cfgA`(HEAD 6d65ecd)以 root 執行。沒有碰任何節點。實驗腳本在 session scratchpad(`r1.sh` `r3.sh` `exp-tail.sh` `r6.sh` `r7.sh`)。

**Verdict: APPROVE-WITH-CHANGES**(2 MAJOR 須在合併前處理,其餘 MINOR 可列入原 issue checklist)。

核心修法(staging 每步檢查、publish 只剩 rename、rc 15、快取不記錄失敗)方向正確,負向對照成立,主要的 ENOSPC 症狀確實消失。但「I/O 錯誤時不會說 saved」這個宣稱只對「metadata 也寫不進去 → journal abort」的情況成立;**只有資料區塊寫失敗**時仍然印 `saved` rc 0、p5 上留下全 0 的身分檔(F1)。另外 `--check` 的 staging 失敗由舊的 rc 5(擋 OTA)變成 rc 1,而 `batman-slot` 對 rc 1 是 fail-open(F2)。

---

## 我跑過的東西(證據)

| # | 內容 | 結果 |
|---|---|---|
| R1 | 新測試 × 修正版,fresh clone,第 1 次 | ❌ `PASS=60 FAIL=1`(49 s)— `--on-join EIO (all I/O)`:`0-byte:[./.stage.54405/identity/…]`,見 F3 |
| R1b | 同上再跑 3 次 | ✅ `PASS=61 FAIL=0` ×3 |
| R2 | 新測試 × 4eba26d 的腳本(負向對照) | ✅ `PASS=10 FAIL=51`(45 s),與設計 §8 一致;K=1–10 皆 `saved rc=0` + 0-byte |
| E3 | `--check`,RUNDIR 所在 tmpfs 滿(256 KiB tmpfs 填滿) | 新:`rc=1 p5 error staging`;舊:`rc=5 p5 stale: …` — 見 F2 |
| E4 | 只有「seed 之後的空閒區塊」寫入失敗(dm 多段表:空閒區段 `flakey … error_writes`,其餘 `linear`;journal、inode table、既有檔案正常) | 新腳本 `--save rc=0 saved`、`--on-join rc=0 saved`;重新掛載後 `overrides.uci size=462` 全為 NUL、`identity/shadow-root` 44 B 全 NUL、`authorized_keys` 75 B 全 NUL;on-join 的 `lkg/overrides.uci` 也全 NUL;dmesg `ext4_end_bio: I/O error 10 writing to inode 35 starting block 1823`。加 `-o data_err=abort` 也一樣 rc 0 — 見 F1 |
| E5 | 一個 uci 值含換行(hostname = `line1\nline2`),p5 有空間 | 新:`--check rc=1 p5 error staging`、`--save rc=15 … staging failed (p5 full, read-only or failing? 9992 KiB free)`;舊:`--check rc=5`、`--save rc=0 saved`(overrides 有兩行,reader 退回 lkg)— 見 F5 |
| E6 | 偵測手段(同 E4 的壞區設定,不含產品程式) | `busybox sync` rc 0;`busybox sync -f MNT` rc 0;PR 的建檔探針 rc 0;`busybox sync FILE`(fsync)**rc 1**;`dd iflag=direct` 讀回比對 **rc 1**(0 non-NUL bytes) |
| flip | F3 的翻轉:EIO hook 前加 `sleep 6`(讓 journal commit 落在 staging 與 I/O 錯誤之間),其他不變 | `sleep=0`:兩個模式 `0-byte:[]`;`sleep=6`:兩個模式都 `0-byte:[./.stage.<pid>/…]` → F3 的 FAIL 歸因成立 |
| R7 | `scripts/test-prov-p1-stubs.sh`(root,修正版 clone) | 見文末 |

實驗後 `losetup -a` / `dmsetup ls` 皆空 ✅(E4 第一版我自己的腳本 dm 表寫錯,裝置停在 SUSPENDED,已 resume、中止並清掉;重跑的版本才是上表數字)。

---

## Findings

### F1 — MAJOR:只有資料寫入失敗(metadata 正常)時仍說 `saved` rc 0,p5 上的 overrides / shadow-root / authorized_keys 變成全 0

- **情境**:SD 卡局部壞(寫某些 LBA 失敗、journal 區正常)— 這正是設計 §1 說「同一條沒檢查的路徑也是 SD 卡 I/O 錯誤的路徑」所要保護的情境。staging 的 `cp` / `printf >` 寫進 page cache(delalloc 只保留空間,不寫碟)→ `cmp` 讀回的是 page cache → 通過;rename 是 metadata、進 journal → 成功;`sync` 時資料 writeback 回 EIO,但 ext4 預設 `data_err=ignore`,journal 不 abort,`busybox sync` rc 0;探針 `printf '' > .wprobe` 只需 inode + 目錄項 → 成功 → `saved` rc 0。
- **證據**:E4(上表)。下一次 96:`overrides.uci` 全 NUL 被 `valid_batch` 擋 → 退 lkg(`--save` 情形是更舊的 OLD;`--on-join` 情形 lkg 也是全 NUL,awk 把 NUL 行當空行 → 空 fragment → image 預設:mesh key 遺失)。Lane A(`96-batman-config-migrate:176-183`)只看 `[ -s ]` 就 `cp -a` → 全 NUL 的 `authorized_keys` 蓋掉 operator key;`shadow-root` 全 NUL → 「not a valid hash — skipped」。這就是原 issue 的傷害,換了一個觸發。
- **為什麼測試沒抓到**:`eiow` 案例的 hook 用 `dmsetup suspend --noflush`,`--noflush` 只影響 dm 佇列;沒有 `--nolockfs`,suspend 會凍結檔案系統並先把 dirty data 寫完(⚠️ 依 dmsetup(8) 對 `--nolockfs` 的說明推論,沒有單獨量測;與 flip 的 `sleep=0` 觀察相容),所以錯誤開始時 stage 資料早已安全落碟,只剩 metadata 失敗 → journal abort → 探針抓到。設計 §6 的「writeback EIO 後 … 下一次建立檔案 EROFS」證據只涵蓋這種情形。
- **修法**(建議;⚠️ 節點未驗證):在第一個 rename **之前**對每個 stage 檔做 `fsync`(韌體 `.config`:`CONFIG_BUSYBOX_DEFAULT_FSYNC=y`;`FEATURE_SYNC_FANCY` 未設,所以節點上**沒有** `sync FILE` / `sync -f`),失敗 → `not_saved … "p5 is unchanged"`(此時確實還沒 publish)。另一個選擇是 `sync` 後以 `dd iflag=direct`(`FEATURE_DD_IBS_OBS=y`,產品已在 `pi3_factory_check` 使用)讀回比對每個已發佈檔。E6 顯示兩者在 WSL 都會回報錯誤(用 `busybox sync FILE` 代替 `fsync` applet,同一個 syscall)。`data_err=abort` **不夠**(E4 實測仍 rc 0)。測試加一個「只有空閒區塊寫失敗」的案例(E4 的 dm 多段表;load 在 mount 之前,與 freeze 無關),並在 hook 案例用 `--nolockfs` 的變體。
- 設計 §0 / §3 / §6 / §8 的「EIO 不會 saved」需改寫成實際涵蓋範圍。

### F2 — MAJOR:`--check` staging 失敗從 rc 5(擋 OTA)變成 rc 1,`batman-slot` 對 rc 1 是 fail-open

- **情境**:`--check` 在 `$RUNDIR`(`/tmp/run/batman`,/tmp tmpfs)staging。/tmp 滿時(sysupgrade 把映像放在 /tmp 是最可能的時機,正好是 OTA precheck 跑的時候),舊版:`cp` / `printf >>` 留下 0 B → 與 p5 不同 → rc 5 stale → OTA 被擋(意外的 fail-closed)。新版:`stage_overrides` 回 1 → `say "p5 error staging"; exit 1`。
- **證據**:E3(新 rc 1、舊 rc 5)。`batman-slot:581-588`:rc 落在 `*)`,只有 `cfgsave-mount.failed` 或 `cfgsave-lock.busy` 存在才擋,否則 `p5_verdict_write "skip:error"; warn "… not blocking"`;`p5_verdict_gate`(`batman-slot:540-548`)對非 `stale:*` 回 0 → stage 2 也放行。⚠️ 這段我只讀 source,沒有實際跑 `batman-slot`。
- 設計 §3 寫「`batman-slot` 的 `*)` 分支對 rc 1 的處理不變」— 字面正確,但沒說那是 fail-open;依 owner 規則,fail-open 需寫出理由。
- **修法**:`--check` 的 staging 失敗回 rc 5 並給可辨識文字(如 `p5 stale: unverifiable (staging failed in the run dir)`),或讓 `batman-slot` 把 `p5 error staging` 當成擋。加回歸測試:滿的 RUNDIR → `--check` rc 5(E3 的設定即可:`mount -t tmpfs -o size=256k,mode=755`)。

### F3 — MAJOR(測試):新測試會間歇性 FAIL(EIO 案例的 0-byte 檢查沒排除留在壞裝置上的 `.stage.<pid>`)

- **情境 / 證據**:R1 第一次跑就 `FAIL --on-join EIO (all I/O) before publish: not-saved rc=15 :: 0-byte:[./.stage.54405/…]`,後 3 次 PASS(4 次中 1 次)。測試對 `ro`/`eio`/`eiow` 的 `h1` 已經排除 `.stage.`(「that leftover is reported, not judged」),但 `zero=` 的 `find` 沒排除。翻轉(上表 flip):只改 hook 前的 `sleep`,`sleep=6` 兩個模式都穩定出現 `.stage.<pid>` 內的 0-byte 檔,`sleep=0` 沒有 → 原因是 staging 與裝置壞掉之間有沒有一次 jbd2 commit(stage 的 inode / 目錄先落碟、資料沒落)。產品行為正確(rc 15、p5 其餘不變、reader 不看 `.stage.*`)。
- **影響**:CI prov-p1 job 與 daily-validation 的 `prov-p1-stubs` 會出現無法重現的紅燈 — 依 owner 規則每次都得歸因。
- **修法**:`zero` 的 `find` 對 `ro`/`eio*` 加 `-path './.stage.*' -prune`,或(更好)把 `.stage.*` 留存另外回報;並加一個 `sleep 6` 的 EIO 案例讓這條路徑每次都被走到。

### F4 — MINOR:持續失敗時 `--on-join` 每個 tick(15 s)都 rw 掛載 p5、寫 stage、記一行 `daemon.err`

- **情境**:p5 真的滿 / 壞 / 唯讀時,rc 15 不快取(刻意)、`WRITES` 計數只在成功時加、`MNTFAIL` 的 5 分鐘退避只對掛載失敗。joinwatch `POLL=15`(`joinwatch:36`)→ 每天約 5760 次 rw mount + 最多 K 個區塊的 stage 寫入 + 刪除,以及 5760 行 syslog err(logread 環形緩衝會把其他紀錄擠掉)。對一張已經在壞的卡,這是額外磨損。舊版在 ro 情形(rc 1)也一樣每 tick 重試,所以不是全新的行為,但 ENOSPC 現在也走這條。
- **修法**:失敗時寫一個與 `MNTFAIL` 同形的 `cfgsave-save.failed`(`<uptime> <step>`),`--on-join` 退避 5 分鐘;任何其他寫入模式或成功時清除。syslog 也只在第一次 / 退避到期時記。

### F5 — MINOR:含換行的 uci 值現在讓整次存檔失敗並被誤報為「p5 滿」,`--check` 變 rc 1

- **證據**:E5。`batch_ok` 會拒絕換行造成的第二行,於是 `stage_overrides` 回 1 → 寫入模式 rc 15 且訊息是 `(p5 full, read-only or failing? 9992 KiB free)`;`--check` rc 1(走 F2 的 fail-open)。這違反 #202 T4 的「不能存的值要回報(rc 6),其餘照寫」:現在連 mesh key 的變更都存不進去。
- **曝露**:只有 root 用 `uci set` 才放得進換行;app 的 ssid 路徑(`halow-setkey:264` 字元白名單)放不進。所以是 MINOR。
- **修法**:把換行(和 CR)加進 `UNSAFE`(以及 Go 的 `ConfigUnsafe`、`batman-slot` 的提示字),讓它走 `REJECTED` → rc 6 / `--check` stale unpersistable;`batch_ok` 失敗另給自己的訊息(「stage rejected by the reader's check」),不要和 I/O 失敗共用文字。

### F6 — MINOR:呼叫者看到的最後一行常是清理時的 `rm` 錯誤,而不是 `p5 NOT saved` 說明

- **證據**:R1 的失敗行 `err=[rm: can't remove '…/.stage.54405/overrides.uci': Input/output error]`(`tail -1 $W/err`)。`halow-setkey:188` 印的就是 `$(echo "$out" | tail -1)`,所以操作員看到的是 rm 錯誤。
- **修法**:`cleanup()` 的 `rm -rf "$STAGE"` 加 `2>/dev/null`(或在 `not_saved` 裡先清 stage 再印訊息)。

### F7 — MINOR:「PARTLY updated」在第一個 rename 就失敗時不正確

- **證據**:R1b `--save read-only before publish`:訊息 `renaming identity/dropbear/authorized_keys failed … p5 is PARTLY up[dated]`,但同一案例的測試斷言 p5 位元組不變且通過。
- **修法**:記一個 `PUB=0`,每個成功 rename 後設 1;`PUB=0` 時訊息用 `p5 is unchanged`。

### F8 — MINOR:lint 沒比對 `ALLOWED_PKGS`

- `awkof` 用 `sed '1d;$d'` 去掉 `awk -v allowed=…` 這一行,而 `batch_ok` 把清單寫死(`system wireless network openmanetd mesh11sd`),96 用的是 `$ALLOWED_PKGS`(`96-batman-config-migrate:22`)。現在兩者相同 ✅,但 96 增刪一個 package 時 lint 仍是綠的,stage 檢查與 reader 會分歧(多擋 → 永久 rc 15;少擋 → 發佈 reader 不收的檔)。
- **修法**:lint 也比對 `ALLOWED_PKGS=` 的值與 `batch_ok` 的 `-v allowed=`。

### F9 — MINOR:沒人清理舊的 `.stage.<pid>/`;這個修正讓「p5 滿」從無聲錯誤變成永久 rc 15 + OTA 被擋

- 設計 §1 自己說現場唯一會累積的是斷電 / SIGKILL 留下的 `.stage.<pid>/`(約 11 block)。修正後滿的 p5 = 每次存檔 rc 15、`--check` stale、OTA 擋住直到人工處理。機率極低(512 MiB / 44 KiB ≈ 1.1 萬次在 staging 窗口內斷電),但補法很便宜:持鎖、mount 後 `rm -rf "$MNT"/.stage.*`(自己的 pid 之外;`.wprobe.*` 同理)。設計 §9 已列為遺留;建議直接做,因為這次的變更讓它的後果變重。

### F10 — MINOR(判斷,不要求改):空的 `overrides.uci`

- 作者選擇不要求非空。我同意這次不改:它是既有行為,而且在 `--on-join` 時 uci 全部讀不到幾乎不可能(節點正 JOINED)。但後果嚴重(`--on-join` / `--if-healthy` 會把空檔也輪替進 lkg → 兩份都空 → 下次 OTA 丟 mesh key)。建議在原 issue checklist 留一行:輪替 lkg 時要求 `wireless.default_radio1.key` 存在。

---

## 逐項檢查(沒有 finding 的部分)

- **rename-only 不需新 block**:rename 只動目錄項與 inode(journal credits 來自預先配置的 journal);覆蓋既有目標會釋放舊 block。新目錄(`identity/<d>`、`lkg`)由 `mkd` 在第一個 rename 前建立(各配一個目錄 block),新名稱進入的目錄都已存在且只有個位數項目,不會長出新目錄 block。`auto_da_alloc` 在 rename-over 時觸發的配置用的是 write 時已保留的 delalloc 空間。R1/R1b 的 K=0..12 案例沒有任何一個在 rename 階段 ENOSPC ✅。⚠️ 第一次 seed 時根目錄的情形只由 `--seed K=…` 案例間接覆蓋。
- **`: >` → `printf '' >`**:special builtin 的 redirect 失敗會結束 shell,改法正確;stage 函式內已無 `: >` ✅(`grep` 確認)。
- **呼叫者對 rc 15**(全部讀過 source):`halow-setkey:184-189` → `persist: FAILED` RC 3 ✅;`p3_persist` 只看 0/非 0 ✅;`node.go:846` `persisted()` 只認 0/6 ✅;`node.go:477-478` `cfgSaveBusy` 只認 rc 1 + 固定字串 → 不重試 ✅;`wtxn`/`node.go` 的 Finish:rc≠0/6 → `.txn` 保留、下次 app 動作 / 重開再試(不是無限迴圈,不 reboot)— 但 p5 永久滿時 `.txn` 永遠留著,`--check` 會說「unfinished network change」而不是 p5 滿(誤導,與 F4/F9 同源,MINOR,不另列);`status.go:142` `upgradeSave` 只 log ✅;`joinwatch:164` 丟棄 rc → 下個 tick 再試(F4);`batman-slot` 只呼叫 `--check`,不會看到 15 ✅,但見 F2。沒有呼叫者把非 0 當成功、reboot 或變磚。
- **on-join 快取**:`not_saved` 刪 `$ST`;R1b 的 `next-tick-skipped` 斷言通過 ✅。
- **降級**:p5 格式、檔名不變;新暫存名只在同一次執行內存在(crash 時留在 `.stage.<pid>/` 內或 `.wprobe.<pid>`,舊版忽略)✅。
- **安全(本機非特權 / 被攻破的 peer)**:stage 與探針都在 `$RUNDIR`(0700)下私有掛載點裡,非特權程序碰不到;p5 只由 root rw 掛載;沒有新輸入、新路徑、新環境變數。peer 能影響的值經 app 白名單。唯一的非特權影響是填滿 /tmp(F2 的觸發之一,既有)。錯誤訊息不含值 ✅。
- **既有測試的錨點**:sbx `onjoin-prov` mutant 的錨 `mv "$STAGE/schema_version" "$MNT/schema_version"` 原文保留 ✅;`cfgsave-stderr-quiet` 的區塊標記未動(見 R7)。
- **時間成本**:新測試約 45–50 s(R1/R2)。

## R7 — 既有回歸套件

✅ `bash scripts/test-prov-p1-stubs.sh`(root,WSL,fresh clone 6d65ecd):`PROV-P1-STUBS stubs=27 fails=0`,389 s。其中 `cfgsave-txn-save: PASS=59 FAIL=0`、`cfgsave-ssid: PASS=7 FAIL=0`、`cfgsave-identity-freeze: PASS=8 FAIL=0`、`cfgsave-frozen-nomount: M6 RESULT: PASS`、`cfgsave-provget-rc10: RC10 RESULT: PASS`、`cfgsave-stderr-quiet: cases=13 fails=0`、`cfgsave-stage-enospc: PASS=61 FAIL=0`(這次沒碰到 F3)。結束後 `losetup -a` / `dmsetup ls` 空。

❌ 沒跑:`tests/prov-p1/sbx` 的 mutant 案例(需要 sbx 環境)— 只用 `grep` 確認錨點那一行原文仍在;`.github/workflows/ci.yml` 沒在 GitHub runner 上跑(dm-flakey 在 runner 上是否存在未知,沒有時 EIO 案例只印 `note:`)。⚠️ 所有 busybox 行為是 WSL busybox 1.36.1;節點的 OpenWrt busybox 只查了韌體 `.config`(`<home>/firmware-2710/.config`),沒有上機。
