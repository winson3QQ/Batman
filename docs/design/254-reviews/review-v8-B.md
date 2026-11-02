# #254 階段 1 實作設計 v8 — 獨立審查 B(第 8 輪,對抗式)

審查對象:`docs/design/254-stage1-impl.md` v8(branch `design/254-stage1-impl` @ de8d3c5),加上 v4–v7 中標「同 vN」的小節,以及第 7 輪的 `review-v7-{A,B}.md`。原始碼 = main f2f2bf6;firmware `/home/yello/firmware-2710`(fstools 2024.07.14 的 `mount_root.c`、`libfstools/rootdisk.c`、`libfstools/common.c`)。

全部唯讀:讀檔;`ssh root@10.41.1.3` 只跑 `mount`、`ls`、`command -v`、`readlink`、`grep /proc`、`docker ps/inspect`、`uci get/show`、`mountpoint -q`、`batman-slot active/is-trial`。沒有寫入、沒有重開、沒有跑 bluetoothctl。

## 0. 結論

**判定:REJECT(窄)— 0 BLOCKER / 1 MAJOR / 12 MINOR。**

- v7 的 MAJOR **在 F3 這條路上已經關掉**:rc 11 不撤銷、不刪哨兵,繼續 F4–F5。下一次開機讀得到意圖就走 W1/W2;F4 沒做成就走 W0。兩條我都對過 fstools 的 PENDING 語意,成立。
- **但同一條不變量從另一個入口又被打破(B8-M1)**。rc 11 之後的 F4 用 jffs2reset 把哨兵一起刪掉。下一次開機如果 p5 讀不到(同一張正在老化的卡),會發生三件事:
  - helper 啟動表沒有「讀不到」這一欄;
  - `reset-uncertain` 的條件裡有「哨兵在」,不成立;
  - 所以這台會落到 `resetting-pending`,而依 §4.1,`resetting-pending` 可以 `factory_reset.cancel`。

  使用者取消之後,tenant 恢復、繼續記資料;等哪一次卡又讀得到,意圖還在,W1/W2 就把 p6 清掉。這和 v7 M1 是同一種錯:使用者被告知「已取消」之後丟資料。該寫成規則的不只是「不刪哨兵」,而是「**p5 可能有意圖時,不准解凍(撤銷或取消)**」。修法是局部的。
- 新加的部分大致可行,我在 04 對過:
  - batdata-mount 在 S11 上鎖:dropbear 是 S19(04 rom 實測),來得及;
  - `batman-slot reboot committed`:K90 hook 在 rom 裡(04 實測);
  - `mountpoint`、`/proc/<pid>/ns/pid`、`tr`、`head` 在 04 都有;容器不在主機的 pid namespace。
- 缺的是幾個邊角:
  - `.locked` 只有 batdata-mount 會建。A7-m7 的原始情境是「fresh 開機 W1 失敗、由 96 上鎖」,這個情境沒有修到(m1);
  - W0 取的 `cfgsave.lock` 會被 config-save 接管,不構成互斥(m2);
  - rc 10/11 有兩格沒歸類(m3、m4)。

## 1. 先補:缺的生命週期列與資源

| 缺的路徑 / 資源 | v8 的行為 | 對應 |
|---|---|---|
| F3 rc 11 → F4 已刪哨兵 → 下一次開機 p5 `unreadable` | 啟動表沒有這一欄;`reset-uncertain` 要求「哨兵在」→ 落到 `resetting-pending` → 可以 cancel | **M1** |
| F3 rc 11、意圖其實沒落盤、p5 可讀 | 96 從 p5 還原原擁有者的 prov(claimed、上鎖);helper 看到「marker 在、無意圖」→ `resetting-pending`。結果安全,但 §4.5 寫的「哨兵仍在 → reset-uncertain」是錯的(F4 已刪哨兵);app 這時顯示什麼也沒有定義 | M1 / m12 |
| fresh 開機 W1 失敗(96 上鎖)→ 下一次非 fresh 開機 W1/W2 成功 | 96 不建 `/etc/batman-reset.locked` → W3 不會再清一次 → 終態「unclaimed、上鎖、沒有 key」 | m1 |
| batdata-mount 讀 p5 得到 `unreadable`,helper 在 S89 卻讀到意圖(卡片時好時壞) | helper「從 F4 續做 → F5」;每次開機都重來一次,沒有上限 | m5 |
| 資源:`/etc/batman-reset.locked`、`state/reset-p6-wiped`、「F3 曾回 11」的紀錄、batdata-mount 寫的鎖定欄位 | §3 擁有權表沒有列 | m8 |
| p6 沒掛時,helper 去讀 marker | 讀到的是 overlay 上的掛載點目錄 → 判成「marker 不在」→ 走「W1 已清過」那一格 | m9 |
| ext4 overlay(fstools 在 `use_f2fs` 為假時改建 ext4) | Wt 判成「不是 f2fs」→ 卡住 | m11 |
| 每次開機都在 S11 以 ro 掛 p5(以前非 fresh 開機不碰 p5) | p5 掛載卡住 → S11 永久停住(R71:開機階段沒有逾時) | m6 |

## 2. MAJOR

### B8-M1 — `reset-uncertain` 以「哨兵在」判定,但 rc 11 之後的 F4 正是刪哨兵的那一步;啟動表沒有 `unreadable` 欄;`resetting-pending` 又允許 cancel → p5 讀不到時節點可以被「取消」,之後意圖重新出現,p6 被清掉

**情境**(擁有者要轉賣;卡片開始老化):

1. F0–F2b 正常。到了 F3:rename 成功,sync 回 EIO → rc 11。helper 照表「當作已提交」,繼續 F4。F4 的 `jffs2reset -y` 刪掉整個 upper,**哨兵也在裡面**。接著 F5 重開。
2. 下一次開機的 S11:`reset-intent.sh` 掛 p5 失敗 → `unreadable` → 走今天的流程,掛舊 p6(marker 在、`apps.reset/` 在)。overlay 是 fresh → 96 讀不到 p5 → 依 `prov-state` 的 last_known_state 上鎖。到這裡都對。
3. S89 helper 啟動:
   - marker 在;
   - p5 意圖 = `unreadable`,但表上只有「無 / 有」兩欄;
   - `reset-uncertain` 的定義是「**哨兵在**、marker 在或不在、p5 讀不到或沒有意圖、且 F3 曾回 11」→ 哨兵不在,所以不成立;
   - 「F3 曾回 11」記在哪裡也沒有定義。overlay 已清,只可能記在 p6 marker,但 marker 格式 `<nonce> <step> <reason>` 沒有這個值。

   實作者最可能對到的是「marker 在 | 無 → `resetting-pending`」那一格。
4. §4.1 規定 `factory_reset.cancel` 在 `resetting-pending` 可用。擁有者看到 pending,按了取消 → 撤銷:`apps.reset → apps`、刪 marker、啟動 dockerd / guardian / joinwatch。OTS 恢復,隊伍繼續記任務。
5. 之後某一次開機,卡又讀得到:意圖在、slot 相符、哨兵不在 → W1 mkfs p6(OTS DB、volumes、log)→ W2 mkfs p5。**取消之後記下的任務資料全部消失。**

**為什麼是 MAJOR**:
- 照文件實作會丟資料,而且是在系統已經告訴使用者「已取消」之後。
- 後果和 v7 M1 一樣,只是入口從「F3 rc 1 → 撤銷」換成「rc 11 → F4 → 讀不到 → cancel」。
- 觸發條件是同一張卡先寫壞、再讀不到、之後又讀得到。這三件事高度相關,不是三個獨立故障。
- v7 兩位 reviewer 對 M1 的「p5 正在壞」情境都評 MAJOR,同一個嚴重度標準在這裡也適用。

**證據**:
- v8 §4.5 F3 三態表 rc 11 那一列:「繼續 F4–F5;下次開機……讀不到 → 今天的流程,**哨兵仍在** → helper 判 `reset-uncertain`」。但 F4 = `jffs2reset -y`,而哨兵是 overlay 上的非 dot 檔,一定會被刪:§3 哨兵列自己就寫了「非 dot → fstools 會刪」,F4 的步驟也沒有因為 rc 11 而改變。
- v8 §4.5 helper 啟動表只有「p5 意圖:無 / 有」兩欄,可是解析器明定有 4 種結果(`none` / `intent` / `bad` / `unreadable`)。
- v8 §4.1:「`factory_reset.cancel(owner_op)`:只在 `resetting-pending`(F1–F2)可用」。§4.5 只在 `reset-uncertain` 裡加了「只有 p5 確定可讀且沒有意圖時才可撤銷」。
- 規則「p5 可能有意圖時,絕不刪哨兵」守住的是哨兵本身。cancel 不需要刪哨兵(這時哨兵已經不在),照樣能把節點解凍。

**修法**(局部,不加機制):
1. 不變量改寫成:**解凍(撤銷、cancel)之前,在本次呼叫裡用解析器重讀一次 p5,結果必須是 `none`;`unreadable`、`bad`、`intent` 一律拒絕,回 `E_PRECOND(p5-unreadable)`。** F3 rc 10 的撤銷也要套這條,和 m3 一起看。
2. F3 的結果持久化在 **p6 marker**,例如 step 欄寫 `3u`(rc 11)或 `3c`(rc 0)。`reset-uncertain` 改用「marker step ∈ {3u, 4},且 p5 不是 `intent`」判定,不再看哨兵。
3. helper 啟動表加一欄 `unreadable`:凍結,只開 `status/public`,顯示「設定區讀不到;重置可能已開始,請勿使用;換卡前先重開一次,或送 bench」。不續做、不准 cancel、不准重新發起(前置條件本來就要求 p5 能 ro 掛起來)。
4. §4.1 cancel 的條件從「狀態 = resetting-pending」改成「第 1 點的重讀結果 = `none`」。
5. **負對照**:
   - 白箱讓 marker = step 3u,p5 以 seam 回 `unreadable` → 送 cancel → 斷言被拒、`apps.reset/` 還在、marker 還在。照 v8 字面:cancel 成功(FAIL)。
   - 正對照:p5 回 `none` → cancel 成功、tenant 回來。

## 3. MINOR

**m1 — `/etc/batman-reset.locked` 只有 batdata-mount 會建;A7-m7 的原始情境是 96 在 fresh 開機上鎖,那種情況下 W3 不會再清一次** — PR-P1 必帶
- **情境**:
  1. F4 成功 → 下一次開機是 fresh overlay → 95(uci-default)→ `boot()` → W1 失敗 → crit、不掛 p6。
  2. 96 看到意圖 → 上鎖。§4.5 L 的非 fresh 清單是「W0 卡住、Wb、Wt、W2 失敗」,不含這個情況;96 那一段也沒寫要 touch `.locked`。
  3. 再下一次開機(非 fresh,overlay 保留下來)W1/W2 成功 → W3 找不到 `.locked` → 不再清 → 終態是 unclaimed、`root:!`、`PasswordAuth=off`、沒有 `authorized_keys`。A7-m7 要修的正是這個終態。
- **後果(Q5)**:04 只要 W1 失敗過一次,就算之後重置成功,遠端也救不回。
- **修法**:
  - 96 因為意圖而上鎖時,也 touch `.locked`;
  - 或者把 W3 的條件改成「這一次是**非 fresh 開機**完成了 W2」(更簡單,不需要另外記);
  - W3 重開之後要 `return`(和 W0 一樣),不要再跑 `refresh_payload_config` / `restore_payload_guardians`。
- **負對照**:白箱讓 fresh 開機的 W1 失敗一次,下一次成功 → 斷言終態是 image 預設(`root:::`、沒有 `.locked`)。照 v8 字面:上鎖、沒有 key(FAIL)。

**m2 — W0「取 `cfgsave.lock`」實際上不互斥**
- **證據**:
  - `batman-config-save:118-124` 的 `lock_try`:持有者活著、但 cmdline 不含 `batman-config-save` → 印出「taking over a stale lock」→ `rm -rf "$LOCK"` 後自己拿走。
  - cleanup 時同樣 `rm -rf "$LOCK"`(`:83`)。
  - W0 的持有者是 batdata-mount(cmdline `/bin/sh /etc/rc.d/S11batdata-mount boot`),任何 config-save 都會接管它。這和 R73(helper 不可能持有 `slot_lock`)是同一種情況。
- **實際風險很低**:S11 是序列執行(rcS `max_running_tasks=1`,A7 讀過原始碼),而且 W 只在 `boot()` 跑。但文件寫「同 config-save 的 mkdir 鎖」,讀者會以為真的互斥。
- **修法**:W0 改呼叫 `batman-config-save --reset-attempt <nonce>`(同一把鎖、同一個寫入路徑,也符合「p5 只有一個寫者」);或者刪掉這句,改寫成「靠 S11 序列執行」。

**m3 — `--reset-intent` 的 rc 10/11 有兩格沒歸類** — PR-P1 必帶
- **(a) 開始時 `.factory-reset` 已經存在**:rc 10 的意思是「這次呼叫沒寫」,不等於「p5 沒有意圖」。要寫死:
  - 已存在、nonce 相同 → 讀回 → rc 0;
  - 已存在、nonce 不同 → rc 11(或新增一個「conflict」);
  - **絕不回 10**。

  「`reset-uncertain` 允許從 F0 重新發起」這條路就會遇到這種情況。
- **(b) rw 掛上之後、rename 之前的失敗**(寫 tmp、fsync tmp)沒有列。rc 表一邊說「寫任何 p5 位元組之前 = 10」,一邊說「rename 之後 = 11」,中間這段兩邊都不算。判準應該寫成「還沒呼叫 rename(2) = 10」。掛 rw 本身就會寫 superblock 和 journal,所以「任何位元組」這個說法不精確。
- **回答「config-save 能不能知道」**:能,前提是判準是「本程序還沒呼叫 rename」,並且依 (a) 確認了開始時沒有意圖。

**m4 — 「rw 掛上來卻是 ro」被歸成不可重試的 10,結果誤報「請換卡」** — PR-P1 必帶
- **證據**:`batman-config-save:226-240`:同一個 ext4 上有 ro 讀者時,rw mount 會成功,但共用唯讀的 superblock(#202 T11),重試 5 次之後失敗。v8 新增了好幾個 ro 讀者:`node_checks`(`batman-slot:540`)、autocommit、解析器本身。
- v8 F3 表只把「`cfgsave.lock` 忙 / 已掛載」列為可重試;「rw 掛載失敗或不是 rw」→ 撤銷,並顯示「請換卡」。
- **修法**:「came up read-only」也歸成可重試(60 s);解析器的 ro 掛載要短,讀完立刻 umount。

**m5 — helper「從 F4 續做」沒有上限** — PR-P1 必帶
- **情境**:p5 時好時壞。S11 解析器得到 `unreadable` → 走今天的流程、掛舊 p6;S89 helper 卻讀到意圖(marker 在、slot 相符)→ F4 → F5 → 下一次開機又一樣。每次開機都 jffs2reset 加重開,沒有上限。W0 的 attempts 上限管不到這條。
- **修法**:
  - 續做次數記在 marker(或與 W0 共用 attempts),超過 3 次 → `reset-stuck`,上鎖,不再重開;
  - 或者規定「batdata-mount 這次開機判了 `unreadable` → helper 不續做」(判決記在 RUNDIR)。
- **負對照**:seam 讓 S11 回 `unreadable`、helper 讀得到 → 斷言第 4 次開機就停住。

**m6 — 解析器掛 p5 的語意:journal、掛載點、逾時** — PR-P1 必帶
- **journal**:
  - v8 寫的掛載選項是 `ro,nosuid,nodev,noexec`,沒有 `noload`。ext4 在 ro 掛載時若有 needs_recovery,仍然會重放 journal,所以 S11 看得到已 commit、還沒 checkpoint 的 rename。這是對的,而且必須這樣:如果斷電剛好在 F3 的 rename 之後,用 `noload` 掛就看不到意圖。
  - 但 96(`96:89` `ro,noload`)和 config-save 的 ro 路徑(`:250` `ro,noload`)都用 `noload`。兩邊一致的前提是「S11 的解析器先跑、先重放過」;S11 回 `unreadable` 時,這個前提不成立。
  - 要寫明:所有意圖讀者都不用 `noload`,或者都只透過 `reset-intent.sh` 來掛。
- **掛載點**要寫明(RUNDIR 下的私有目錄)。B7-m7 要求過,v8 沒寫。
- **新增的開機期依賴**:
  - 以前非 fresh 開機不碰 p5,現在每次開機都在 S11 掛 p5。p5 掛載卡在 D-state → 開機永遠停在 S11(R71),連從沒做過重置的節點也一樣。v8 沒有提到這點。
  - 至少寫進殘項。
  - 可選的緩解:只在本地有跡象時才讀 p5(overlay 有哨兵或 `.locked`,或 p6 有 marker 或 `reset-p6-wiped`)。代價是實體 SD 放進來的意圖會被忽略,而這本來就等同重燒卡。

**m7 — sysupgrade 程序判定:§6.4 的文字沒跟上;argv[1] 精確比對會漏掉相對路徑**
- §6.4 第一段仍寫「`pgrep -f ^/bin/sh /sbin/sysupgrade` 或等價」,和 §4.5 的「不用 `pgrep -f`」以及 D27 矛盾。要統一成同一個判定函式,放在共用的 sh lib。
- `cd /sbin; ./sysupgrade` 或 `sh sysupgrade` 會讓 argv[1] ≠ `/sbin/sysupgrade` → F1 看不到真正在跑的 sysupgrade。後果有限:
  - marker 寫入之後,sysupgrade 的 platform_check_image 會被 `precheck-node` 擋下;
  - 如果它在 F1 之前就已經驗過,stage 2 寫入另一槽之後是 trial → Wa → autocommit 不 commit → revert。

  寫成殘項即可。
- 04 實測:`/proc/1/ns/pid = pid:[4026531836]`;OTS 容器的 `PidMode` 是空的(不是 host)、`Privileged=false`;`tr`、`readlink`、`head` 都有 → 這個判定在 busybox 上可以實作 ✅。

**m8 — §3 擁有權表沒有跟上新增的資源**
- 鎖定欄位現在有第三個寫者:batdata-mount 在 S11(非 fresh 開機)。§3 只列了 96 和 helper。三者依時段分開,不衝突,寫進表裡即可。
- 沒有列的新資源:
  - `/etc/batman-reset.locked`:寫者 = batdata-mount 的 L(修 m1 之後加上 96);刪除者 = overlay 清除;
  - p6 `state/reset-p6-wiped`:寫者 = W1;隨 W2 之後的 p6 生命週期消失;
  - 「F3 的結果」:M1 第 2 點,記在 marker 裡;
  - `lock-status` 在非 fresh 開機的寫者。

**m9 — p6 沒掛時,只修了「啟動者」,沒修「寫者」和 helper 的推論**(A7-m9 / B7-m9 的另一半)
- v8 讓 guardian、firstload、dockerd、joinwatch 在「marker 在,或 `/opt/batdata` 不是 mountpoint」時不啟動 ✅。04 實測:`mountpoint -q /opt/batdata` 回 0,不存在的路徑回 1。
- 但下列寫者仍會寫進 overlay 上的掛載點目錄:99zz 的 `prov-state`;helper 的 `prov-state`、`ble-ok`、health;96 的 verdict;L 的 `lock-status`。otatrace 已經有這個防護(`otatrace.sh:33`),可以照抄。
- helper 啟動表把 p6 沒掛時的「讀不到 marker」當成「marker 不在」,於是走「p6 已被 W1 清過」那一格。結果是 `resetting`,安全,但推論是錯的。要加一欄「p6 未掛 = marker 未知 → 凍結、不續做」。

**m10 — `reset-p6-wiped` 的可信度與讀取時機**
- W1 要知道「p6 上有沒有 `reset-p6-wiped <nonce>`」,就得在 W1 **之前**先掛 p6。W1 還沒跑過時,掛上的是**舊的** p6。這一步用 ro 還是 rw、掛不起來怎麼辦,文件都沒寫。
- 前任在重置前是 root,也看得到 nonce,可以先在舊 p6 種一個 `state/reset-p6-wiped <nonce>` → W1 被略過 → `apps.reset/`、docker image、volumes 跨過重置留給買家。
- 前任本來就是 root,能改 rootfs(階段 1 沒有 secure boot),所以這屬於誠實界線。但有一個便宜的強化:
  - W1 mkfs 之後,把新 p6 的 fs UUID 寫回 p5 的意圖行(和 W0 寫 attempts 走同一個寫入路徑);
  - 「略過 W1」的條件改成 `blkid` 讀到的 UUID 相同。

  這樣也不用在 W1 之前掛舊 p6。
- 不採用的話,§4.5 的誠實界線要加一行。

**m11 — Wt 用「不是 f2fs」判斷,會把 ext4 overlay 也擋掉**
- **證據**:fstools `libfstools/common.c` 的 `block_volume_format`:`use_f2fs()` 為假時改跑 `mkfs.ext4 -L rootfs_data`;`mount_root.c:78-83` 對 FS_EXT4 一樣走 `mount_overlay`。04 現在是 f2fs(`/mmcblk0p4 on /overlay type f2fs`)。
- **修法**:改成正面判斷「overlay 是持久的」:`/overlay` 的 fstype ∈ {f2fs, ext4},且不是 tmpfs。前置條件同樣修改。Pi 4 現在不受影響,3A+ 上線前要改。

**m12 — 矩陣與 app 契約缺 rc 11 的結果**
- 要加的 L 列:
  - 「rc 11、意圖沒落盤」:下一次開機是原擁有者 claimed、凍結、可以 cancel;
  - 「rc 11、p5 讀不到」:見 M1;
  - 「rc 11、意圖已落盤」:走 W1/W2。
- app 在 rc 11 時要顯示什麼沒有定義。建議文字:「重置已送出,節點會重開;回來之後若仍顯示原擁有者,請重新發起。**交付前務必確認節點顯示 unclaimed**。」

## 4. v7 發現 → v8 核對(一條一行)

| v7 | 判定 | 說明 |
|---|---|---|
| A7-M1 F3 非 0 ≠ 沒寫 | partial | F3 路徑已關(rc 11 不撤銷);同一條不變量經「F4 刪哨兵 → `unreadable` → cancel」又被打破(M1) |
| A7-m1 tmpfs overlay | addressed | 前置條件 + Wt;ext4 會被誤擋(m11) |
| A7-m2 jffs2reset 後 respawn | partial | 續做不看哨兵 ✅;續做沒有上限(m5);p6 未掛時的推論(m9) |
| A7-m3 Wa 與 trial | addressed | autocommit 不 commit、node_checks 擋、Wb 排在 Wa 前 |
| A7-m4 pgrep 可偽造 | partial | §4.5 / D27 ✅;§6.4 文字仍寫 pgrep(m7) |
| A7-m5 解析器強化 | partial | 形狀 ✅;journal、掛載點、逾時沒寫(m6) |
| A7-m6 W0 取鎖 | partial | 寫了取鎖,但 config-save 會接管(m2) |
| A7-m7 非 fresh 上鎖 / 終態 | partial | 非 fresh 由 batdata-mount 上鎖 ✅;96 不建 `.locked`,原始情境沒修到(m1) |
| A7-m8 W2 失敗 / W1 重清 | addressed | `reset-p6-wiped`;可信度與讀取時機見 m10 |
| A7-m9 p6 未掛 fail-open | partial | 啟動者 ✅;寫者、helper 推論沒修(m9) |
| A7-m10 rc 語意 | partial | 0/10/11 ✅;意圖已存在、rename 前的中間段、ro 共用沒歸類(m3、m4) |
| A7-m11 文件矛盾 | addressed | §4.3 格式、BATMAN_FIRSTBOOT、D35、L16 都已修;§6.4 pgrep 殘留見 m7 |
| A7-m12 矩陣缺列 | addressed | L52–L57;rc 11 的三種結果見 m12 |
| A7-m13 procd 整體 invalid | addressed | 不改,理由成立(boot_id + slot 綁定) |
| B7-M1 撤銷刪哨兵 | partial | 同 A7-M1 |
| B7-m1 tmpfs / 哨兵在、意圖不在 | addressed | `reset-uncertain` 的判定條件見 M1 |
| B7-m2 啟動表缺格 | partial | 補了哨兵那一格;少 `unreadable` 和「p6 未掛」兩欄(M1、m9) |
| B7-m3 Wa / autocommit / 順序 | addressed | |
| B7-m4 W2 被打斷 | addressed | batdata-mount 自己上鎖 + `reset-p6-wiped` |
| B7-m5 plain reboot | addressed | 改用 `batman-slot reboot committed`;04 rom 有 `K90batman-reboot`(實測);條件不成立時退回 plain reboot |
| B7-m6 sysupgrade 判定 | partial | 同 A7-m4(m7) |
| B7-m7 解析器契約 | partial | 同 A7-m5(m6) |
| B7-m8 文件不一致 | addressed | `expected_in_mesh` 改讀第 4、6 欄 ✅ |
| B7-m9 p6 未掛 / start-restart | partial | W 只在 `boot()` 跑 ✅;寫者沒修(m9) |
| B7-m10 cancel 互斥 / ota-residue | addressed | |
| B7-m11 誠實界線 | addressed | |

## 5. 指定重點逐項

- **rc 0/10/11**:可以實作。判準要寫成「本程序還沒呼叫 rename,且開始時 p5 沒有意圖」(m3);「came up ro」要可以重試(m4)。被逾時殺掉或 crash 都當成 11 ✅。
- **`reset-uncertain`**:判定條件錯了(依賴哨兵),cancel 的閘門也放錯地方(M1)。
- **「p5 可能有意圖時絕不刪哨兵」,逐一對照每個刪除者**:
  - F4 / W0 的 overlay 清除只在「已提交」之後發生 ✅;
  - rc 10 的撤銷要加上 m3(a) 的條件 ✅;
  - cancel 不刪哨兵,但會解凍 → 規則要升級成「不准解凍」(M1)。
- **helper 啟動表**:「續做不看哨兵」✅;缺 `unreadable`(M1)和「p6 未掛」(m9)兩欄;續做沒有上限(m5)。
- **batdata-mount 在非 fresh 開機上鎖**:
  - S11 的 `uci set` / commit 早於 S19 dropbear(04 rom `S19dropbear` 實測)✅;
  - `root:!` 改的是 overlay 上的 shadow ✅;
  - network 在 S20 之後才起 ✅;
  - 擁有權表要加這個寫者(m8)。
- **`.locked` + W3 再清一次**:
  - 不會迴圈 ✅:W3 只在 W 階段進行中才跑;W2 成功後意圖就消失,下一次是 fresh overlay,沒有 `.locked`。jffs2reset 失敗也只是停在上鎖,不會重開;
  - 缺 96 那一條;W3 要 `return`(m1)。
- **`state/reset-p6-wiped`**:能防止 p6 被重清 ✅;讀取時機與可信度見 m10。
- **Wt**:tmpfs 判斷 ✅;ext4 誤擋(m11)。fstools 遇到 FS_NONE / DEADCODE 會走 `ramoverlay()`(`mount_root.c:65-76`)。
- **sysupgrade 程序判定**:busybox 上可以實作(見 m7 的實測)✅;§6.4 文字與相對路徑(m7)。
- **`reset-intent.sh`**:形狀 ✅;journal、掛載點、開機期逾時(m6)。
- **p6 未掛時 fail-closed(`mountpoint`)**:04 實測 rc 0/1 正確 ✅;寫者那一半沒做(m9)。
- **S11 的 `batman-slot reboot committed`**:
  - `cmd_reboot`(`batman-slot:752-776`)要求:bootfacts 可用、tryboot flag = 0、`[all]` 讀得到、`/etc/rc.d/K90batman-reboot` 存在(04 rom 有)、RDOK。任一條不成立就退回 plain reboot,不會 die ✅;
  - W0 是在 jffs2reset **之後**才呼叫它;K90 連結在 rom、不在 overlay,所以不受影響 ✅;
  - `otalog_k` 在 p6 沒掛時只寫 kmsg(`otatrace.sh:33`)✅;
  - `exec reboot` 是在子程序裡執行,batdata-mount 接著 `return` ✅。

## 6. 逐 actor

- **BLE 路人 / 只看過 QR 的人**:本輪沒有變化 ✅。
- **本機非 root 程序**:
  - `/etc`、RUNDIR、p6 `state/` 都只有 root 能寫,種不了 `.locked`、哨兵或 `reset-p6-wiped` ✅;
  - 偽造 sysupgrade 的 cmdline 已被 uid 0 + pid ns 檢查擋住 ✅,負對照 (n) 成立。
- **被入侵的 tenant**:容器不在主機的 pid ns(04 實測)✅;碰不到 marker 和哨兵 ✅。
- **被入侵的 provd**:cancel 和重新發起都要 owner-op ✅。M1 的 cancel 是擁有者本人按的,不是 provd 偽造的。
- **前任擁有者**:成功路徑全清 ✅;M1 的後果是資料丟失,不是前任資料殘留;種 `reset-p6-wiped` 見 m10(屬誠實界線)。
- **實體 SD**:
  - 壞意圖 → Wb 凍結並上鎖(等於 DoS,和重燒卡同級)✅;
  - FIFO / symlink 由解析器擋下 ✅;
  - p5 掛載卡住會讓 S11 停住(m6)。
- **供應鏈**:沒有新的依賴(04 實測工具都在)✅。
- **我們自己**:
  - M1:兩條規則各自正確,合起來有洞;
  - m2:鎖的語意和文字不符;
  - m8:擁有權表沒跟上。

## 7. PR-P1 必要條件

**M1** + **m1、m3、m4、m5、m6、m9、m11**,各附負對照。m2、m7、m8、m10、m12 是文件修正,實作時一併處理即可。

## 8. 使用者決策的後果(不重開,只列)

- **Q5(L16 在 04)**:
  - m1 沒修的話,04 只要 fresh 開機的 W1 失敗過一次,就算之後重置成功,也會停在「上鎖、沒有 key」,遠端救不回;
  - M1 的修法會讓「p5 讀不到」的 04 停在凍結狀態,要到現場處理;
  - 排 L16 之前,這兩點要列進副作用清單。
- **U4 全清含身分**:rc 11 而意圖沒落盤時,節點回來仍屬於原擁有者(m12)。交付前要確認節點顯示 unclaimed。
- **U3 與 SSH 脫鉤**:沒有新的後果。
- **U6 3A+**:Wt 的 f2fs 判斷(m11)和 PARTNAME 守門(A7 已列)都要在 3A+ 上線前處理。

## 9. 本輪唯讀探針(原始輸出摘要)

```
04 mount: /dev/mmcblk0p4 on /rom type squashfs; /mmcblk0p4 on /overlay type f2fs (rw,...);
          overlayfs:/overlay on / type overlay (upperdir=/overlay/upper); /dev/mmcblk0p6 on /opt/batdata type ext4
04 /rom/etc/rc.d: K90batman-reboot -> ../init.d/batman-reboot; S10boot; S11fstab; S11sysctl; S19dropbear; S99dockerd; S99batman-autocommit; S99ttyd
04 command -v: tr mountpoint head readlink fsync flock pgrep mkfs.ext4 jffs2reset sgdisk blkid 都有;od 沒有
04 mountpoint -q /opt/batdata -> 0;mountpoint -q /nonexist -> 1
04 readlink /proc/1/ns/pid = pid:[4026531836];docker inspect:5 個 OTS 容器 PidMode='' Privileged=false
04 batman-slot active = B;is-trial rc=1;ttyd enable='0';system.ttylogin=0
fstools mount_root.c:65-76 FS_NONE/FS_DEADCODE -> ramoverlay();:78-83 EXT4/F2FS -> mount_overlay
fstools common.c block_volume_format: use_f2fs() ? mkfs.f2fs : mkfs.ext4 -L rootfs_data
batman-config-save:118-124 lock_try 會接管 cmdline 不含 batman-config-save 的持有者;:226-240 rw 掛載「came up read-only」重試 5 次後 exit 1
96-batman-config-migrate:89 p5 以 ro,noload 掛
95 INITBODY boot():p6 mount → resize → :632 閂 → pstore → boot-reasons → fw_override_check → restore_payload_guardians
batman-slot:752-776 cmd_reboot:任一條件不成立就退回 plain reboot;otatrace.sh:33 p6 未掛時不寫檔
```
