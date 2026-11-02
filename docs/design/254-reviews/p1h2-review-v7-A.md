# 審查 A 第 7 輪:#254 PR-P1 + PR-H2(整份設計、第 6 輪修正、E1c 探針)

審查者 A,2026-10-21。

**判定:REJECT**:0 BLOCKER / 7 MAJOR / 11 MINOR。
- E1c 照現稿**不可在 04 上跑**:M1–M5 都是 E1c 的問題。
- 產品碼有 2 個 MAJOR:M6、M7。

**讀了哪些東西**:
- 設計:`254-p1-impl.md`,全文,含 §13.2 / §13.3。
- 第 6 輪的兩份報告。
- `Batman-p1` @ c1e1c72,以及 58dbb7b、c392443、b482268、c1e1c72 的 diff。
- `Batman-h2`:`prov-base-254.sh`,sha `738a3347…`,與 scratchpad 那份相同。
- `e1c.sh`,以及草稿 `prov-claim-254.sh`。

**真機**:只做唯讀 ssh(02、04):cat、ls、blkid、sysctl、`batman-slot active/is-trial`。沒有寫入、沒有重開;也沒有印出任何秘密。

**本機實跑**:
- WSL root 跑 config-save 的 sanity,HEAD 與修正前各一次;
- Go 單元測試;
- 兩個 mutant。

工具在 `scratchpad/h2/revA7/`。

## 0. 本輪證據

| # | 事實 | 證據 |
|---|---|---|
| ✅ V1 | 04 現況:slot A committed,**版本 wsl.10**(`1.5.12-wsl.10+de782bf.fw52a8796`)。兩槽的 `.protected` 都是 wsl.10,沒有 `bad-slot`。p6 上有 `ota-wsl11.tar.gz` | `slot=A trial_rc=1 ver=1.5.12-wsl.10+de782bf…`;`cat slot-*.protected` |
| ✅ V2 | 02 現況:slot A committed,**wsl.11**,兩槽都是 wsl.11 → 目前 fleet 混版 | `slot=A trial_rc=1 ver=1.5.12-wsl.11+c1e1c72.fw3db3f36` |
| ✅ V3 | 04 的 p5:`LABEL="batconfig" TYPE="ext4"`,1048576 個 sector = **512 MiB**。p6 還有 18.7G 可用 | `blkid`;`/sys/class/block/mmcblk0p5/size`;`df` |
| ✅ V4 | 04 的 harness 實際是以 **`none`** 登入。publickey 也能登入(`authorized_keys` 有 1 行) | `ssh -v` → `Authenticated to 10.41.1.3 … using "none"`;`PreferredAuthentications=publickey` → `PUBKEY-OK` |
| ✅ V5 | `fs.protected_symlinks = 1`、`protected_regular = 2`;`/etc/rc.local` 是預設內容;`S95done` 存在;`/opt/batdata/dv-prov` 目前是 0755(snap 會改成 0700) | 04 唯讀 |
| ✅ V6 | config-save 凍住時的寫入防護有鑑別力:<br>HEAD:`PASS=8 FAIL=0`。<br>c392443^(修正前):`PASS=4 FAIL=4`:`--on-join` rc 4 `saved (--on-join)`、`--save` rc 0、`--prov-only idZ` rc 0 `prov saved gen=2`、`identity-missing` 沒報 | `revA7/run.sh` 的輸出 |
| ✅ V7 | 拿掉 `E_STATE` 那段檢查 → `FAIL batman-prov/node`。rc 13 的 mutant(條件放寬回「`ovIdent` 就寫」)→ `TestRc13…` FAIL。HEAD 的 `go test ./...` 全部 ok(**go1.26.4**,不是 F13 寫的 1.22) | `revA7/mut.sh`、`mut2.sh` |
| ✅ V8 | stage 2 的 ramfs 內建 `wc grep awk sed cut sort tail`;`head` 與 `sha256sum` 由 `RAMFS_COPY_BIN` 帶進去;`prov-lock.sh` 已加進 `RAMFS_COPY_DATA`(`platform-ab.sh:40`) | 04 `/lib/upgrade/stage2:38-51` |
| ✅ V9 | `MeshExpect("claimed", "")` = `"0"`;placeholder → `"0"`;真的 key → `"today"` | `revA7/mut.sh` 中的臨時測試 |
| ✅ V10 | `--on-join` 的快取只收 rc 0 / 4 / 6(`batman-config-save:291`)。rw 掛載在 `:306-330`,identity 檢查在**掛載之後**(`:377`)。joinwatch 的 `POLL=15`(`joinwatch:36`),每個 JOINED tick 都呼叫一次(`:147`) | 讀檔 |

---

## MAJOR

### M1. E1c:dead-man 在「找到 fresh trial、ssh 種下去」之後才武裝,而且種成功與否沒有驗證。P1 約 95–105 s 就會自行 commit unclaimed 的 B,失敗訊息又假設它會 revert → 04 可能 committed 在位址不明、沒有 dead-man 的 B 上

**情境**:
- `e1c.sh:59-66`:最多掃 240 s 的 `10.41.254.x`,接著在 B 上種 rc.local 與背景 dead-man。
- 但 P1 對 unclaimed 判 `NEED_MESH=0`(`batman-autocommit:408`),健康判定約 95–105 s(§13 E3)。所以 B 在 trial 中就會被 commit,約 168 s 再被重開到保留位址。

以下三條路徑都會讓 04 停在 **committed B、新位址、沒有 dead-man**:
1. 掃描比較慢,超過約 100 s,而且沒有在約 168 s 之前找到。
2. `macip` 抓到 ARP 快取裡**舊的同 MAC 項目**。E1a 用過 `10.41.254.160`;A 和 B 的 MAC 相同,ARP 比對分不出新舊。
3. `fq` 種植失敗。`:62-66` 的輸出(`planted`、`deadman_in_rclocal=1`)**完全沒有被檢查**。

這時的提示訊息是 `:60`「autocommit reverts at 600 s … wait for A」與 `:76`「autocommit reverts to A」,**都是錯的**:A 不會回來。依 P-U12 這是無人值守的跑法,結果是 04 離開 S0、OTS 停擺、02 被隔離,直到有人來處理。

不會卡死,原因是 unclaimed 的 B 可以 `none` 登入,而且有 eth。

**修正**(擇一):
- (a)**先 hold 再放行**:
  1. 寫 `autocommit-hold-commit` = **payload 的版本**(不是 `:28` 的 `V`,那是 A 的版本);
  2. trial 中斷言 log `mesh join required: 0 (prov=unclaimed` 與 `is healthy and HELD`;
  3. 種下 dead-man,並以新的 ssh 讀回 `deadman_in_rclocal=1`、`slot=B trial_rc=0`;
  4. 執行 `batman-autocommit release` 讓它 commit。
  
  這樣「自己會 commit」改由「HELD 判定 + release 就是 commit 路徑」證明。整段要在約 150 s 前完成,做不完就 `back_to_a`。
- (b)不 hold 也可以,但必須做到:
  - 種植要驗證(讀回 rc.local 與 boot_id);
  - FIP 要以 ssh 回傳 `slot=B trial_rc=0`、而且 boot_id 是新的,才算數;
  - 找不到或種植失敗時,訊息要改成「B 可能已無保護地 commit」,並改走延長搜尋:mDNS 加上整個 /16 的 ARP 掃描 + 推播通知。

### M2. E1c 第 4 步的「找到」判定沒有鑑別力:同一個 MAC、ping 沒回應也取 IP、沒有 ssh / slot 斷言 → 可能誤報 `found=mdns`,然後對錯的主機做 restore

**情境**:
- `:85` 從 `Pinging host [ip]` 這一行取 IP。**即使沒有任何 reply**也會取到。
- `:87-88` 只比 ARP 的 MAC。而 A 與 B 共用同一個 eth MAC(`88-a2-9e-b5-6c-89`),Windows 的 mDNS 或 ARP 快取若還留著 A 的 `10.41.1.3`,MAC 一樣會相符 → `FIP2=10.41.1.3`、`how=mdns`。這正好是 E1c 要回答的第 3 個事實,會被誤判成成立。
- 接下來 `:94-95` 的 `fq` 會靜默失敗(沒有證據),`:99` 也打不到 B。
- 另一種情況:Pi 4 的 EEPROM 在 plain reboot 後可能先走到 p1(A),再由 `95-batman-storage:423-` 的自我檢查修正。這段時間 mDNS 可能解析到 A 本身,`:99` 就會在 **A** 上執行 `sed` 與 dead-man(後者因 `active≠B` 而退出)。之後 `:101-103` 判「A not back」;而 B 的 rc.local 仍保有 dead-man。

**修正**:
- 要求 ping 有 reply(`TTL=`);
- `fq` 要回傳 `slot=B trial_rc=1`,而且 boot_id ≠ `$bB`(證明真的重開過)≠ trial 那次的開機;
- 三個條件都成立才算「找到」,否則繼續找。
- `RESULT` 只依據這個斷言填寫。

### M3. E1c 第 5 步:確認還原完成之前就拆掉 dead-man,而 dead-man 本身在 `timeout 90` 的 ssh 裡同步執行,容易被切斷

**情境**:
- `:99` 先 `sed -i '/e1c-deadman/d' /etc/rc.local`,然後在同一條 `fq`(`timeout 90`)裡同步執行 dead-man。
- `p5-restore` 要依序做:
  1. 讀 512 MiB 驗快照的 sha(`prov-base-254.sh:154`);
  2. `dd … conv=fsync` 寫入 512 MiB(`:158`);
  3. 再以 direct I/O 讀回 512 MiB(`:161`)。
  
  以 SD 卡的速度估計約 60–90 s,⚠️ 這是推估,沒有實測。
- 逾時後本機的 ssh 被殺掉。之後 `batman-slot reboot committed` 的 `echo … >&2`(`batman-slot` 的 `cmd_reboot`)寫到已經斷掉的 pipe,可能因 SIGPIPE 死在 `exec reboot` 之前。
- 另一種情況:`p5-restore` 因為 `lock busy 30 s` 或 `p5 is mounted` 而 die。dead-man 用的是 `&&` 串接(`:40`),後面的 rollback / reboot 就不會跑。

兩種結果都一樣:B 繼續跑、rc.local 已經沒有 dead-man、A 不會回來。最後只能等 joinwatch 在 3600 s 時重開,或由人處理。

**修正**:
- `:99` 改成 `setsid sh $BASE/e1c-deadman.sh </dev/null >>log 2>&1 &`,之後輪詢 A;
- **rc.local 那行保留**:回到 A 之後它被 `active=B` 擋住,不會作用,由 cancel 檔關閉;
- dead-man 改成:`p5-restore` 失敗**仍然** rollback + reboot,並把失敗記在 log。理由:A 搭配任何 p5 都安全。p5 讀不到 → helper 保留 overlay(`boot.go` case 1 / 8);身分不一致 → 凍住;A 有 lab key,仍連得到。

### M4. E1c 的成功判準以 p5 的原始映像 sha 比對;A 開機後的第一個 JOINED tick 一定會 rw 掛載 p5 → 幾乎必定誤判 FAIL

**證據**:
- `:104` 比的是 `dd | sha256sum` 與 `p5.img.sha`。
- 但 F4,以及 V10 讀到的程式碼(`--on-join` 的快取在 tmpfs → 每次開機第一個 tick 都會 rw 掛載,rw 掛載會改 superblock)都說明 sha 一定會變。
- `e1/e1.sh:93` 作者自己也寫了「p5 raw sha may change … by a ro/rw mount of slot A's own joinwatch」。
- §4.5.5 規定比的是 `ro,noload` 的**檔案清單**。

**後果**:E1c 成功了,卻報 FAIL,而且走的是 FAIL 出口:`e1c.cancel` 沒建、`e1c-deadman.sh` 沒刪。

**修正**:改用 `prov-base-254.sh manifest $RUN after` 加上只比 `p5.manifest`。也可以在 A 起來後立刻用 `ro,noload` 做清單比對。

### M5. 設計 §13.3 與 `e1c.sh` 是兩個不同的實驗;最具破壞性的一步(p5 mkfs)與副作用沒有寫進設計

**差異**:

| 項目 | §13.3 | `e1c.sh` |
|---|---|---|
| 寫入方式 | `sysupgrade -n` 寫入 wsl.11 | 直接 `batman-slot apply` + plain `reboot`(`:53-55`) |
| p5 | 沒提 mkfs | `mkfs.ext4` p5(`:50`) |
| 收尾 | rollback + brewrite | dead-man 的 p5-restore |

- §13.3 還留著過期的 ⚠️ 段落(「第 1 步改成 hold」)。
- 前置條件沒有斷言 A 與 payload 的版本:04 現在是 wsl.10(V1)。照現稿跑,會是 A = wsl.10、B = wsl.11 的混版。如果 B 在 commit 之前就被重開回 A,wsl.10 的 config-save 沒有 c392443 的凍住防護,會把 X 的設定寫進 Y 的 p5(之後 p5-restore 會救回來,但這個情境不在計畫裡)。
- 副作用沒有列出(違反使用者「破壞性測試先列副作用」的規則):
  - 02 被隔離:最壞情況約 snap + apply + 240 + 600 + 420 + 420 + 600 s,再加上 dead-man 的 1500 s,可能超過 3600 s → 02 的 joinwatch 會重開;
  - OTS 中斷;
  - A 的 overlay 會寫入 `.dv-prov-mark-$RUN`(header 寫「Slot A's overlay is never written」不正確);
  - DIRTY 旗標留著;
  - `payload-e1c/` 留著;
  - p6 的 `slot-B.protected` 變成 wsl.11;
  - 新資源(`e1c-deadman.sh`、`e1c.cancel`、B 的 rc.local、`$D/ev` 錄製器)沒有進 §3 的擁有權表。

**修正**:
- 依實際要跑的程序改寫 §13.3:逐一列出資源、還原方式與斷言;
- 前置條件斷言 `ver(A) == ver(PAY) == wsl.11`;
- 先讓 04 OTA 到 wsl.11,並在報告裡註明 fleet 版本。

### M6.(產品)凍住的節點每 15 s 就 rw 掛載一次 p5:這是 #263 M0 的回歸

**證據**(V10):
- `identity_mismatch` 的檢查在 rw 掛載**之後**才做(`batman-config-save:306-330` → `:377`);
- rc 1 不進 fp 快取(`:291` 只快取 0 / 4 / 6);
- joinwatch 每個 JOINED tick 都呼叫(`POLL=15`)。

**情境**:P-U6 的凍住在現場可能持續好幾天(等擁有者處理)。這段期間:
- 約每 15 s 一次 rw 掛載、寫一次 superblock,一天約 5760 次;
- 每次都記一行 `daemon.warn refused …`,會洗掉 log ring 裡的證據,也增加 SD 的磨耗。

這正是 #263 M0 用 fp 快取修掉的問題(joinwatch 的註解寫明「a cache hit … mounts nothing」)。

**修正**(擇一):
- 寫入模式先以 `ro,noload` 檢視比對 identity,不一致就不 rw 掛載;
- 或者新增一個 rc(例如 15 = frozen),寫進 `$ST` 的快取,同一次開機內不再掛載。

**測試**:在 `prov-unit-cfgsave` 加一個案例:凍住的節點連續兩次 `--on-join`,第二次不掛載(ext4 的 mount count 不變)。負對照是拿掉快取。

### M7.(產品)c1e1c72 把 mesh_expect 統一在 fail-open 那一邊:claimed 的節點讀不到 mesh key(或沒有 mesh 介面)時被判成「不需鄰居」,蓋過 `expected_in_mesh`

**證據**:
- `boot.MeshExpect`:claimed 且 `k == ""` → `"0"`(V9);
- `meshIface()` 找不到 `mode='mesh'` 時回 `""`(`main.go:93-102`);
- 99zz 改成「預設 0,只有找到真的 key 才是 today」;
- autocommit `:408` 對 `claimed:0` 設 `NEED_MESH=0`,而且這是在 `expected_in_mesh` 之後才覆寫的(`:389-398`:有 `mesh-joined` 就要求鄰居)。

**情境(現場)**:
1. 一台 claimed、沿用 fleet key 的節點(認領 legacy 的 fleet 節點,L18)收到 OTA;
2. 新 image 的 wireless 還原或 migration 有 bug:mesh section 不見、改名,或 key 是空的;
3. 結果 `prov-state` 的 mesh_expect = 0 → autocommit 不需鄰居就 commit;
4. 只靠 mesh 連線的節點(02 沒有 eth)就卡死。

這正是 autocommit 的 mesh 閘要擋的那一類 bug(參考 2026-09-25 掉 brcmfmac、OTA 讓節點卡死的事件)。c1e1c72 之前,99zz 對空 key 是 fail-closed(today);B-m2 只要求三處一致,作者卻統一到不安全的那一邊。

合法流程裡,「claimed 但沒有網路」的 key 一定是 placeholder(F8)。所以只有 placeholder 才是正向證據,改成 fail-closed 不會影響任何合法情境。

**修正**:
- claimed → `0` **只在** key == placeholder;空 key、讀不到、沒有 mesh 介面 → `today`。
- Go 與 99zz 同步修改;多 mesh 介面時的判法也要一致(Go 只看第一個介面,99zz 看任一個)。
- `TestMeshExpect` 翻轉成新判法,99zz 的 stub-uci 案例也翻轉。負對照:舊版空 key → `0` → FAIL。

---

## MINOR

- **m1 E1c 沒有落點斷言**:
  - `:55` 是 plain `reboot` 加上 armed 的 tryboot(F29:EEPROM 在這條路徑可能不切換)。如果落回 A,A 帶的是 mkfs 過的 p5,tryboot 也可能仍是 armed;腳本卻要掃滿 240 s 才判 FAIL。
  - **修正**:重開後若 `10.41.1.3` 以新的 boot_id 回應 → 判「落點落空」→ 依 §4.5.0 先以 vcmailbox disarm 並讀回 → 跑 `p5-restore`。
  - 另外 §5.4 第 4 步要求的「重開前以 `ro` 斷言 p5 仍未 seed」也沒做。
- **m2 dead-man 不是一次性的,也沒有到期**:
  - 觸發之後,它沒有刪掉自己、沒有建 cancel、也沒有移除 B 的 rc.local 那行;快照也還在。之後只要哪一次以這份 B overlay 開機超過 25 min(例如手動 commit B 而沒有重寫),它就會把**舊的 p5 快照**寫回去。
  - 走 FAIL 出口時,都不會建 cancel。
  - **修正**:dead-man 第一步就 rename 自己並移除 rc.local 那行;綁定 `$RUN` 與到期時間(例如 `date` 不可靠,改看 p6 上的 run 標記是否存在);每個 FAIL 出口都印出解除指令。
- **m3 報告的真實性**:
  - `:78` 只要一次 `fq` 失敗(暫時性)就判 `gone` → `rebooted=1`,`:95` 的「prev-boot」可能其實是同一次開機;
  - commit 只看 `trial_rc=1`,沒有斷言 autocommit 的決策行(`mesh join required: 0 (prov=unclaimed`、`COMMITTED`),而這正是事實 1;
  - B-m5 的證據可以再加上 B 正常關機時,`95-batman-storage stop()` 存的 `shutdown_*.log`,這比每 3 s 一次的錄製器更完整。
- **m4 E1c 其他出口**:
  - `:29` 先 `tar -xzf` 才驗 sha → 應該先驗再解;
  - `:51` FAIL mkfs 時沒有印出還原指令;
  - 走 FAIL 出口時,A 的 joinwatch 一直停到下次重開(這段時間 save-on-join 失效);
  - `FRESHO` 對任何回應那個 IP 的主機都送指令(`StrictHostKeyChecking=no`)。實驗室可以接受,但要寫明。
- **m5 B-M4 的驗證計畫前後矛盾**:
  - §13.2 說這個測項是「第 5 步之前、從 committed 的 unclaimed B 做的 OTA」;但 (a) 案第 3 步已經認領,認領的 `--save` 會 seed p5,閘會依 `.seeded` 放行,**不是**走 L44 的例外。
  - 負對照(拿掉 `RAMFS_COPY_DATA` 那一項)要改的是**執行中那一槽**的 `platform-ab.sh`(必須是 `-wbox` 的 B),而設計沒有寫。
  - 原始碼面的證據成立(V8),但沒有真機證據。
  - **修正**:把「unclaimed、未 seed 的 B 執行 `sysupgrade -n` 寫 A」明確排進鏈 1,放在認領之前,並寫出 A 從未 seed 的 p5 建起之後怎麼還原;或者改由 `-wbox` 單元做負對照。
- **m6 cfgsave 測試的覆蓋**:
  - 沒測 `--if-healthy`、`--seed`;
  - 只斷言 rc,沒斷言 p5 的檔案清單不變;
  - 腳本裡標成「negative control」的那一段其實是正向案例。
  
  真正的負對照我跑過了(V6:修正前 4/8 FAIL),請把這個做法寫進 `prov-unit-cfgsave`,另外加上 p5 清單的斷言。
- **m7 §5.4 本文仍是舊的鏈 1 第 7 步**,只由 §13.2 覆蓋:
  - (a) 案結束時,A 由 B 的 p5 建起(身分 Y),restore 必須走同槽重建(`firstboot -y`)。這依賴 E4,而 E4 尚未做;
  - (b) 案的退路也沒有展開。
  
  請把 §5.4 改寫成單一版本。
- **m8 `prov-claim-254.sh` 草稿**:
  - 認領前沒有斷言 `PreferredAuthentications=publickey` 可以登入。04 平常是以 `none` 登入的(V4),認領後就只剩 publickey;目前 key 在,但測項必須自己守住這一點(§5.4 的守門規則同樣適用於 A)。
  - 覆蓋少於 §5.3:沒有 `claim-after-persist` killpoint 與 replay、沒有 `no-ssh-key`、沒有 bind mount 的負對照,也沒有 wsl.9 的負對照。
  - canary 把 `claim.secret` 的 8 位元組前綴帶回主機:應該在節點上比對;而且應該涵蓋 §4.2 的全部秘密,base64 也要掃。
  - `overlay-restore` 與重開分成兩條 ssh,中間有空檔,不符合 §4.5.2「覆蓋到重開之間不可中斷」。
- **m9 F13 已過期**:WSL 實際是 go1.26.4(V7)。這會影響 E5 / `prov-artifact-match` 的「同一個 toolchain」前提。
- **m10 rc 13 判 `identity-lost` 時的提示文字不實**:`batman-config-save:153` 寫「the helper re-persists it at the next boot」,但 sn 不符時,B-M3 的新規則永遠不會補 → 節點永久凍住,OTA 也被擋。請改寫提示,並在 §4.8 補上這條恢復路徑(owner-op 或重燒卡)。
- **m11 目前 fleet 混版**:02 是 wsl.11,04 是 wsl.10(V1 / V2)。這違反 §6「不混 fleet」,P3 也會 FAIL。請在 §13 記錄,並寫明 E1c 之前怎麼把兩台對齊。

---

## 第 6 輪處置的查核

| 第 6 輪 | 處置 | 本輪結論 |
|---|---|---|
| A-M1(fresh trial 會在 openmanetd 重開前 commit) | 改用 (a) 案、E1c | 方向可以,但 E1c 本身有 M1–M5 |
| A-M2 / B-M2(凍住不完整)config-save | c392443 | ✅ 有鑑別力(V6)。但出現新的 M6;`--if-healthy` / `--seed` 沒測(m6) |
| B-M2 helper 動詞回 `E_STATE` | b482268 | ✅ mutant 會 FAIL(V7)。verdict 只在 daemon 啟動時設定,每次重啟都重跑 `boot.Run`,行為一致 |
| B-M3(rc 13 降級) | b482268 | ✅ mutant 會 FAIL(V7)。提示文字見 m10 |
| B-M4(ramfs 沒有 `prov-lock.sh`) | c392443 | ✅ 原始碼與 stage 2 工具清單成立(V8);⚠️ 沒有真機證據,負對照不可行(m5) |
| B-m1(`IsTrial` 無法判定時放行) | `rc != 1` | ✅ 讀碼確認(`main.go:109`) |
| B-m2(三處判法不一致) | c1e1c72 | 一致了,但統一在 fail-open 那一邊 → M7 |
| B-m3(`--check` 漏掉 p5 沒有身分) | `prov-identity-missing` | ✅ HEAD 有報、修正前沒報(V6) |
| A-m6 / B-m4(S0) | 04 已正規化 | ✅ 04 兩槽都是 wsl.10;但 02 已是 wsl.11 → 混版(m11) |

## 判定
**REJECT**。

- **E1c**:修完 M1–M5 之前不要在 04 上跑。其中最關鍵的是:
  - dead-man 必須在 B 有機會 commit 之前武裝並驗證(M1,建議採 hold → `HELD` → 種植 → release);
  - 「找到」要以 ssh 回傳的 slot 與 boot_id 作為身分(M2);
  - restore 要 detached 執行,而且失敗時仍然 rollback(M3);
  - p5 改比檔案清單(M4)。
- **產品**:M6、M7 要修,並附 mutant 或負對照。
- MINOR 依序併入。
- 下一輪請送**整份**設計與新版 `e1c.sh`。
