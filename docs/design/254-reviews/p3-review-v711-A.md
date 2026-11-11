# P3 設計 v7.11 抽查 — 審查者 A(正確性)

範圍:`/home/yello/Batman-p3/docs/design/254-p3-impl.md` @ 8f9eab6(v7.11)。核對 v7.10 的 18 項 MINOR(A16-m1..m11、B16-m1..m7),只看正文 §1–§12,不採信附錄 M。另外看 `git diff 11ade69 8f9eab6` 有沒有帶進新的矛盾。
只讀:沒有改任何 repo,也沒有上節點。原始碼:Batman-p3 @ 8f9eab6、firmware-2710 @ 02f0913d。target busybox 取自 `build_dir/target-aarch64_cortex-a72_musl/root-bcm27xx/bin/busybox`,用 qemu-aarch64-static 執行。本輪腳本與輸出在 scratchpad `s5/a17/`(`q711.sh`、`writer711.sh`、`q711.out`、`f1–f3.sh`、`b1–b3.sh`、`d711.md`、`diff.txt`)。

**結論:0 BLOCKER / 0 MAJOR / 5 MINOR → APPROVE-WITH-CHANGES。**
- 18 項裡 13 項關閉,5 項只關一半:A16-m2、A16-m6 / B16-m1、B16-m4、B16-m6。
- 新 MINOR 有 3 項是 v7.11 自己的修法帶進來的:gate 入口(m1)、掛載來源(m2)、409 計數(m3)。
- 5 項都只要改文字。其中有兩項不改的話,實作會照字面寫錯:m1(card-only 路徑沒有 gate)與 m2(LUKS 模式下永遠 `E_STORAGE`)。

---

## 1. 實測(✅,原始輸出)

### V1 `slot_busy` 逐字照 §3.7.3:368,在 target busybox 上跑(`q711.sh`)
```
nofile: rc=1 (want 1)
free: rc=1 (want 1)
held(host flock -x): rc=0 (want 0)
held(target busybox fd): rc=0 (want 0)
sh: .../case.sh: line 6: can't open .../batman-slot.flock: Permission denied
noperm(non-root): rc=0 (want 0) caller alive
noflock: rc=0 (want 0)
same: reader rc=1
same-shell writer after slot_busy rc=0 after 0s (want 0, 0s)
another reader holds shared: rc=1 (want 1 = not busy)
writer: lock mode=644 child umask=0022
host-hold 2.5s: writer rc=0 after 3066 ms
host-hold 4s: writer rc=14 after 3061 ms
```
- 函式的四種結果都對:沒有鎖檔 → 1;空閒 → 1;被持有 → 0;開不了 / 沒有 flock → 0。
- 同一個 shell 先跑讀者、再跑寫者:寫者 rc 0,沒有把鎖留在 shell 裡。
- 兩個讀者同時拿共享鎖不互擋。
- 拿掉 umask 之後,子程序的 umask 是呼叫者的 0022,鎖檔是 0644。
- 寫者重試的實測:對方持鎖 2.5 s → 第 4 次拿到(約 3.07 s);持鎖 4 s → rc 14。持鎖的一方用 host 端 flock,是 §12.5:902 的新做法。
- 唯一的小瑕疵:subshell 沒有 `2>/dev/null`,開檔失敗時 stderr 會多一行(併入 m4)。

### V2 其他實測與核對
- **鎖的順序**:`node/node.go:221-222` 確實是 `n.mu.Lock(); defer n.mu.Unlock()` 包住整個 `dispatch`。另一處 `n.mu.Lock()` 在 `wtxn.go:417` `BootFinish`(開機時在背景持有),不是 tick,也不碰 `slotMu`。
  - helper 裡沒有任何 tick 拿 `n.mu`,所以「worker 與 tick 永不拿 `n.mu`」跟現有程式碼不衝突。
- **RunDir**:`batman-slot:64`、`batman-autocommit:43` 的 RUNDIR 從環境變數來。`scripts/rundir-paths.txt:1` 寫明它是 root-only 的 `/tmp/run/batman`;F53 記錄這個目錄是 root 0700。
  - 所以拿掉 `umask 077` 之後,非 root 程序仍然進不了這個目錄,開不了鎖檔,也就不能靠拿共享鎖把寫者卡住 ✅。
- **版本正規式**:stamp 產生的是 `VER="$REL-$CH.N+$F7.fw$W7"[.dirty][.wbox-$WBOX]`,wbox 名字只能是 `[a-z0-9-]`(firmware `stamp-batman-build.sh` 的 `case "$WBOX"` 與 `lib-wbox.sh:51`)。§3.7.1:327 的 `\+[0-9A-Za-z.-]+` 全部涵蓋,`.bench` 也在內。
  - `prov-254.sh:161` 取的是 `${sv##*.wbox-}`,所以 `.bench` 放在 `.wbox-` 前面不影響它 ✅。
- **`T.pub`**:131 B;firmware 的 `feeds/batman/tests/keys/T.pub` 存在,而且與 repo 那份一樣(`cmp` → same)。所以「bench 的鑰匙 = feed 的 `T.pub`」做得到 ✅。
- **gate 入口**(firmware,`f1.sh`、`f2.sh`):
  - `gate-rootfs.sh` 目前只有三種用法:`<sq>`、`<sq> --normal`、`--extract <sq> <dir>`(`:4-9`、`:27-33`)。
  - `build-board.sh:206` 第 7 步只用 `--extract`,其他 gate 是自己接著呼叫的(`:207-214`)。註解寫明「`--card-only` 會跳過第 8 步,這是 card 唯一的 gate」(`:204-205`)。
  - `local-ab-tar.sh:73` 用預設模式;`fast-build.yml:189` 用 `--normal`。
  - `build-firmware.yml:224-230` 自己解開 squashfs,跑 `check-prov-test-gate.sh witness-root`,不傳 WBOX,也就是一律套用一般 build 的規則。
  - `build-release.yml:250-251` 只下載 artifact 再發布,本身不 build;`repro-108.yml`、`build-pr-*.yml` 都 `uses: build-firmware.yml`。
- **update-last 的掛載判斷**:
  - `otatrace.sh:33` 實際寫的是 `grep -q " /opt/batdata " /proc/mounts`:用的是 `/proc/mounts`,而且只確認它是掛載點,不看來源裝置。`batman-slot:433` 也一樣。
  - `95-batman-storage:116-117`:LUKS 模式下 `DEV=/dev/mapper/batdata_crypt`。`docs/storage-architecture.md:26`:p6 在 Secure tiers 是 **LUKS**。

---

## 2. v7.10 的 18 項 MINOR(照正文)

| 項目 | 正文 | 判定 |
|---|---|---|
| A16-m1 disarm tick 先後 | §3.7.4:403「**先 TryLock `slotMu`** …拿到之後才讀 update-last」,啟動時同規則 | ✅ 關閉 |
| A16-m2 `n.mu` 不在順序裡 | §3.7.4:390「`n.mu` → `slotMu` → `updMu`;worker 與所有 tick 永遠不拿 `n.mu`」 | ⚠️ 一半:原建議的「持 `n.mu` 時不等 worker 結束」沒寫 → m5 |
| A16-m3 umask | §3.7.3:368 拿掉,寫明理由;§5.3:618 改成 0644 | ✅ 關閉(V1、V2 RunDir) |
| A16-m4 讀者回傳值 | §3.7.3:368 完整函式 `slot_busy`;§12.5:883 有負對照 | ✅ 關閉(V1)。命名與 stderr → m4 |
| A16-m5 prepare 孤兒判斷 | §3.7.4:396 prepare 列、§3.7.3:379 rc 14 列、§5.1:565、§3.7.5-4 指回 §3.7.4、§12.5:885 | ✅ 關閉 |
| A16-m6 gate 入口 | §3.7.2:343 改成 firmware 的腳本,由 `gate-rootfs.sh`「兩種模式」呼叫 | ⚠️ 一半:第 7 步用的是 `--extract`;`--ci` 的語意沒定義 → m1 |
| A16-m7 多餘機制 | §3.7.2:341 拿掉 release.env 檢查與 `wbox_env_reset`;:345 改成比 feed 的 `T.pub`;§12.5:904、:913 跟著改 | ✅ 關閉 |
| A16-m8 `trust` / 一行 / FIFO | §3.7.1:315(none / bad 的定義、一行 = 可選結尾 `\n`、`O_NONBLOCK`、≤ 256 B、`fstatfs`);§5.3:619-620;§12.5:887 | ✅ 關閉 |
| A16-m9 版本正規式 | §3.7.1:327 | ✅ 關閉(V2)。建議的 selftest 三案沒列進 §12.5,可在實作 PR 補 |
| A16-m10 §6 沒掛上 | §6:653 | ✅ 關閉 |
| A16-m11 UD18、rundir-paths | §10:758 | ✅ 關閉 |
| B16-m1 一個入口 / CI 判 bench / 轉賣清單 | 同 A16-m6;§12.5:905 仍寫「`build-firmware.yml` 以 bench 建 → FAIL」;轉賣清單只寫「只收 `release-sign.sh` 簽過的 `rel`」 | ⚠️ 一半 → m1 |
| B16-m2 讀者 rc | 同 A16-m4 | ✅ 關閉 |
| B16-m3 鑰匙檔 | §3.7.1:315、§5.3:619-621 | ✅ 關閉。`/rom/usr/share/batman` 不存在時對應 `none`,採的是 A 的建議;B 建議 `bad`。reason 都是 24,可以接受 |
| B16-m4 掛載判斷 | §3.7.4:401 mountinfo + `O_NOFOLLOW` | ⚠️ 一半:「來源是 p6」沒定義,引用的出處也不符 → m2 |
| B16-m5 tick 先後 | 同 A16-m1 | ✅ 關閉 |
| B16-m6 計數漏 409 / 0 + 11 | §3.11-5:509、§3.11-12:516 | ⚠️ 一半:改法和同一段的「10 s 內 409 一律重試」衝突 → m3 |
| B16-m7 文字 / `sleep 2.5` | §5.1:565、§3.7.3:379、§12.5:902 | ✅ 關閉 |

---

## 3. BLOCKER / MAJOR

無。

逐一檢查了 diff 動到的介面,沒有找到會造成資料遺失、毀掉退路或死鎖的新路徑:
- 鎖的順序:check、prepare、apply、owner/remove、worker、disarm tick、刪檔 tick 全部依 `n.mu → slotMu → updMu`,而且 tick 只用 TryLock。
- prepare 的孤兒判斷:檢查「鎖被持有」到刪目錄之間能拿鎖的,只有 helper 自己的 `bootinfo` 與外部 `batman-slot`,兩者都不讀 `update/boot/`。
- disarm tick 改成先拿鎖再讀 update-last。

---

## 4. MINOR

**m1 gate 入口:第 7 步與 card-only 不會跑鑰匙 gate;`--ci` 沒定義;結構測試的對象沒寫清楚(A16-m6 / B16-m1 一半)**
- **情境 1:card-only 沒有 gate。** §3.7.2:343 說 `check-release-key-gate.sh` 「由 `gate-rootfs.sh` 的兩種模式呼叫」,又把「`build-board.sh` 第 7 步」列為經 `gate-rootfs.sh` 的路徑。
  - 但第 7 步只呼叫 `--extract`(`build-board.sh:206`),而 `--extract` 只做解開與完整性檢查(`gate-rootfs.sh:8-9`、`:28`),之後的 gate 都是 `build-board.sh` 自己一個個呼叫(`:207-214`)。
  - 照字面實作:`--card-only` 做出來的 card(`build-board.sh:204-205` 自己寫「這是 card 唯一的 gate」)永遠不會跑鑰匙 gate。在一般 build 上,第 8 步 `local-ab-tar.sh:73` 會補到 payload,card 則沒有。
  - §10:757 的 firmware 清單也沒有列 `build-board.sh`。這比 v7.10 退步了:v7.10 明寫第 7 步會呼叫它。
- **情境 2:`--ci` 沒定義。** 文件說 `build-firmware.yml` 改呼叫 `gate-rootfs.sh --ci`,而 `fast-build.yml` 仍是 `--normal`。
  - `gate-rootfs.sh` 目前不認得 `--ci`(`:31` 遇到未知參數就 FAIL)。`--ci` 和 `--normal` 是什麼關係沒寫。
  - 現行 CI 一律用一般 build 的規則(`build-firmware.yml:229` 不傳 WBOX)。如果 `--ci` 不包含 `--normal`,variant 就改從 image 自己的 stamp 取(`gate-rootfs.sh:35`),CI 對 wbox image 會變寬鬆。
  - 反過來,`--normal`(fast-build)遇到 bench 要不要 FAIL,也沒寫。
- **情境 3:結構測試對象不清楚。** 「每個上傳 image / payload 的 workflow 步驟之前都有 `gate-rootfs.sh`」:`build-release.yml:250-251` 發布 image,但本身不 build,照字面這個結構測試會 FAIL,或被迫在那裡多解一次。
- **§12.5:905** 仍寫「`build-firmware.yml` 以 bench 建 → FAIL」。W7 已證明 workflow input 塞不進 `--bench`,所以這個測試做不出來。
- **轉賣清單**:`release-sign.sh` 簽的是 payload,轉賣工具燒的是 card image。「簽過的 `rel`」怎麼對到 image 的 sha、由哪一步寫進清單,仍然沒寫(§3.9:496 只寫「發行流程加更新清單一步」)。
- **修法**(只改字):
  - (a) `build-board.sh` 第 7 步在 `$WR/r` 上直接呼叫 `check-release-key-gate.sh`(和 `check-prov-test-gate.sh` 並列),或規定 `--extract` 之後由呼叫者負責;§10 列入。
  - (b) 寫明 `--ci` = `--normal` + bench 一律 FAIL,或直接讓 `--normal` 帶 bench FAIL,只留一個旗標。
  - (c) 結構測試的對象限定為「build 並上傳 artifact 的 job」(`build-firmware.yml`、`fast-build.yml`)。
  - (d) §12.5:905 改成「離線對 bench squashfs 跑 `gate-rootfs.sh --ci` → FAIL」。
  - (e) 清單項目 = `release-sign.sh` 在同一步寫入 `rel` image 的 sha。

**m2 update-last 的「來源是 p6」沒定義,引用的出處不符;LUKS 模式下會永遠 `E_STORAGE`(B16-m4 一半)**
- §3.7.4:401 寫「從 `/proc/self/mountinfo` 確認 `/opt/batdata` 是掛載點且來源是 p6(照 `otatrace.sh:33`)」。
  - 但 `otatrace.sh:33` 是 `grep -q " /opt/batdata " /proc/mounts`:只確認它是掛載點,不看來源(`batman-slot:433` 相同)。
  - 「來源是 p6」怎麼比,沒寫:`/dev/mmcblk0p6`?major:minor?GPT 名字 `data`?
- 若照字面比 `/dev/mmcblk0p6`:LUKS 模式下掛載來源是 `/dev/mapper/batdata_crypt`(`95-batman-storage:116-117`),而 `storage-architecture.md:26` 規定 Secure tiers 的 p6 是 LUKS。
  - 結果:這類節點的 prepare / apply 永遠 `E_STORAGE`,永遠不能經 app 更新。現在 image 還沒有 dm-crypt,所以這是潛在問題。
- **修法**:
  - 規則寫成「mountinfo 裡 mount point 剛好是 `/opt/batdata`」,和 otatrace / batman-slot 用同一條規則。這已足以擋住「`/opt` 另有掛載」的情況,因為那時 `/opt/batdata` 不是 mount point。
  - 若要比來源,定義為「95 判定出來的 data 裝置(GPT 名字 `data`,或它的 dm mapper)」。
  - 出處改成 `otatrace.sh:33`(用 `/proc/mounts`,只確認是 mount point)。
  - §12.5:888 再加一案:LUKS / mapper 來源 → 照常寫入。

**m3 409 計數和「10 s 內 409 一律重試」衝突(B16-m6 一半)**
- §3.11-12:516 規定「prepare 回 15、status 0 + 15 / 0 + 11、PUT 回 409 合計連續 3 次 → 節點拒絕…請重開節點」。同一段又規定「`bulk/open` 之後 10 s 內的連線拒絕或 409 一律重試(間隔 1 s)」。
- §3.8.2:487 的 409 也包含「窗的剩餘時間不夠 → app 先延長再 PUT」與「worker 在跑」。這兩種都是正常流程或 app 自己造成的。
- 照字面實作:provd 還沒經 poll 拿到窗時,連續 3 次 1 s 間隔的 409 只要約 3 s 就會跳出「請重開節點」。
- **修法**:計數只算「10 s 寬限之後、status 顯示窗開著、而且自己沒有 PUT 在傳時的 409」(B16-m6 原本的條件),寬限期內的重試與「剩餘時間不夠」不算。

**m4 名稱沒有統一,讀者 stderr 有雜訊**
- §3.8:448 與 §12.5:909 仍叫 `slot_writer_alive`,§3.7.3:368、§5.3:618、§12.5:883 叫 `slot_busy`。兩者回傳值的意思相同(0 = 有寫者),但實作者可能寫成兩支函式。
- `slot_busy` 的 subshell 沒有 `2>/dev/null`,開檔失敗時 stderr 會多一行(V1)。§3.7.3 要求的是「忙 + log」,這行並不是 log。
- **修法**:統一成 `slot_busy`,寫明 autocommit 的 `slot_writer_alive` 改叫它;subshell 加 `2>/dev/null`,在 `return 0` 前由呼叫者 log。

**m5 「持 `n.mu` 時不等 worker 結束」沒寫(A16-m2 一半)**
- §3.7.4:390 只禁止「持 `updMu` 時等 worker」。`owner/remove` 在 `n.mu` 內(`node.go:221-222`)中止 worker(§3.7.5-9:441)。
- 實作若寫成同步等 worker 結束:worker 的 `write` 子程序卡在 D 狀態時(§6:「子程序卡在 D 狀態」那列),`cmd.Wait` 永遠不會回來,`n.mu` 就永遠不放。所有非唯讀動詞,包括 `sign.peer`、`settings.set`,都會停住,只有重開才會恢復。
- 這一點 A16-m2 原本就建議了,v7.11 只採用了一半。
- **修法**:§3.7.4 加一句「持 `n.mu` 或 `updMu` 時只送 TERM,不等 worker 結束」。§12.5「鎖的順序」那列加一案:worker 的子程序不理 TERM 也不理 KILL(用接縫模擬)時,`owner/remove` 在 1 s 內回應,其他動詞照常。

---

## 5. 判定

**APPROVE-WITH-CHANGES**:0 BLOCKER / 0 MAJOR / 5 MINOR。
- m1、m2 在實作 S5 的 firmware 與 helper 之前必須先改文字,否則會照字面寫錯。
- m3–m5 可以在同一次修文字時一起改。
- 5 項都不必加新機制,不必再整份重審;作者改完後抽查這 5 處即可。
