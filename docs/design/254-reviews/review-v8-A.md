# Review A(第 8 輪)— `254-stage1-impl.md` v8(含 v4–v7 中標「同 vN」的各節)

審查對象:Batman `design/254-stage1-impl` @ de8d3c5(`docs/design/254-stage1-impl.md` v8 + `254-reviews/254-stage1-impl-v{4,5,6,7}.md`)。
原始碼:main f2f2bf6(= branch)`feed/batman-provision/files/`、`feed/batman-payload-host/files/`;firmware `/home/yello/firmware-2710` 的 fstools `2024.07.14~408c2cc4`、procd `2026.03.14~c59f2d80`。
節點:04(10.41.1.3)、02(10.41.1.1),**只讀**(mount、ls、which、grep log、`--help`)。沒有寫入、沒有重開。

## 0. 總評

- v7 的 MAJOR(F3 結果不確定仍撤銷)在 **F3 呼叫的那一刻**已經收好:rc 0/10/11 三態、rc 11 / 逾時 / crash 都當作已提交,不刪哨兵。
- 但「p5 可能有意圖時,不能撤銷」這條規則只套在 F3 的回傳值上,**沒有套到 helper 重啟判斷表和 `factory_reset.cancel`**:
  - 走 rc 11 那條路時,F4 照設計清掉 overlay(哨兵跟著消失),重開。
  - 下一次開機 p5 如果讀不到,helper 判斷表裡沒有「讀不到」這一格(只有「有/無」),marker 也不看 step,結果是 `resetting-pending`。
  - 這個狀態開放 cancel。cancel 把 tenant 拉回來,使用者以為重置取消了。等 p5 哪天又讀得到,W1/W2 就把 p6 清掉。
  - 這和 v7 的 M1 是同一類問題(掉資料),只是從另一個刪除者進來。→ **A8-M1(MAJOR)**。
- 其餘新增的部分(Wt、batdata-mount 上鎖、`reset-p6-wiped`、sysupgrade 程序判定、解析器、p6 沒掛 fail-closed)方向都對。剩下的都是 MINOR:實作細節、文件殘留,和兩個 field regression(joinwatch、終態上鎖)。

**判定:REJECT(窄)** — 0 BLOCKER / 1 MAJOR / 12 MINOR。A8-M1 的修法很小(用 marker 已有的 `step` 欄位,不加新機制)。修完重審整份文件,預期可以 APPROVE-WITH-CHANGES。

---

## 1. 先補:缺的矩陣列、缺的資源

| 缺的列 / 資源 | v8 現況 | 對應 |
|---|---|---|
| rc 11 → F4(哨兵被清掉)→ 重開 → **p5 讀不到**的那次開機 | helper 判斷表沒有「讀不到」這一格 → `resetting-pending` → 開放 cancel | **M1** |
| F0 重新發起(reset-uncertain)時,p5 已經有**舊 nonce 的意圖**,這次 F3 回 rc 10 | rc 10 →「撤銷」→ 刪哨兵,但 p5 上的舊意圖還在 | **M1** |
| F3 中 helper crash,孤兒 config-save 還在跑 | 新 helper 讀到「無」→ `resetting-pending` → cancel → 孤兒稍後 rename | **M1** |
| F3 的 `sync` 之後、`umount` 之前斷電(journal 已 commit,還沒 checkpoint) | 用 `ro,noload` 的讀者(96、`--prov-get`、`node_checks`)看不到意圖 | m2 |
| 降版或 `-F` 到不懂意圖的 image,意圖還留著 | 沒有這一列;之後升級回意圖槽時,W1/W2 會突然把 p6 清掉 | m10 |
| W2 成功之後、W3 補清 overlay 之前斷電 | 意圖已經消失,W3 不會再跑 → 終態是「unclaimed、上鎖、沒有 key」 | m5 |
| 96 在 fresh overlay 上鎖(W1 失敗那次開機) | 沒有 touch `/etc/batman-reset.locked` → W3 不補清 | m5 |
| p6 壞掉的現場節點(跟重置無關) | joinwatch 從此不啟動(新的「p6 不是 mountpoint → 不啟動」) | m6 |
| 資源:`/etc/batman-reset.locked`、`state/reset-p6-wiped` | §3 擁有權表沒有;鎖定欄位實際有 3 個寫者(96、batdata-mount、helper),§3 只列 2 個 | m8 |
| 資源:marker 的 flock | marker 是 0644,放在 0755 的 `state/` 底下 → 非 root 程序可以搶 flock | m7 |

---

## 2. Findings

### MAJOR

**A8-M1. 「p5 可能有意圖 → 不能撤銷」只套在 F3 的 rc 上,沒有套到 helper 重啟判斷表、`factory_reset.cancel` 和 F0 重新發起;marker 的 `step` 沒被用上。結果:使用者按了取消,之後 p6 還是被清掉。**

- **情境 1**(p5 卡片正在壞,使用者情境「p5 會死的節點」):
  1. F3:rename + sync 完成,ro 重掛讀回 EIO → rc 11。helper 照 v8 繼續做 F4:dot sweep + `jffs2reset -y`,哨兵(非 dot)被刪,marker step=4。接著 F5 重開。
  2. 下一次開機 parser 回 `unreadable` → 走今天的流程:mount 舊 p6(marker 還在、`apps.reset/` 還在)。96 在 fresh overlay 上依 `last_known_state` 上鎖。
  3. helper 啟動,查判斷表:marker 在,p5 意圖「無」。這張表只有「有/無」兩格,parser 的 `unreadable`、`bad` 沒有對應的列。結果是 `resetting-pending`。
     - `reset-uncertain` 的條件是「哨兵在 … 且 F3 曾回 11」:哨兵已經被 F4 清掉;「曾回 11」也沒有寫在任何持久的地方。所以 reset-uncertain 不會成立。
  4. §1.4 和 §4.1 規定 `resetting-pending` 開放 `factory_reset.cancel`。擁有者取消後,撤銷流程跑完:`mv -T apps.reset apps`、刪 marker、啟動 dockerd/guardian。app 回到「正常」,使用者以為資料都保住了。
  5. 之後某次開機 p5 讀得到 → 意圖在、slot 相符、哨兵不在 → W1 mkfs p6(OTS DB、docker、tenant 資料,04 實測都在 p6)→ W2 mkfs p5。沒有任何提示,因為 marker 已經在第 4 步被刪了。
- **情境 2**(reset-uncertain 的重新發起):
  - §4.5 允許「`factory_reset` 重新發起,從 F0 冪等」。F0/F1 會用新 nonce 改寫 marker(step 回到 1)和哨兵。
  - 這時 p5 上可能已經有上一次的意圖(只是剛才讀不到)。新的 F3 只要回 rc 10,例如 `cfgsave.lock` 忙或 rw 掛不起(這正是 p5 讀不到的時候最可能的結果),就會撤銷並刪掉哨兵。
  - 下一次開機 p5 讀得到 → 舊意圖在、哨兵不在 → W1/W2 在**沒清過的 overlay** 上執行 = v7 M1 的原樣(半套重置 + 掉 p6)。
  - 根本原因:rc 10 的定義是「這一次呼叫沒寫」,不是「p5 上沒有意圖」。
- **情境 3**(helper 在 F3 中 crash):
  - procd respawn helper。原本的 `batman-config-save --reset-intent` 是孤兒,還在跑(SD 慢的時候可能好幾秒)。
  - 新 helper 讀到「無」→ `resetting-pending` → 擁有者取消 → 撤銷刪掉哨兵和 marker → 孤兒接著 rename 成功 → 回到 v7 M1。
  - v8 只寫了「helper crash → 視為 rc 11」,但這條規則只有原本那個 helper 行程知道,新的 helper 不知道。
- **證據**:
  - §4.5 helper 啟動判斷表只有「有/無」兩欄(`254-stage1-impl.md:215-220`);parser 有 4 種輸出(`:226` none/intent/bad/unreadable)。
  - §4.5 reset-uncertain 的定義(`:209`)要求「哨兵在 … 且 F3 曾回 11」,但 F4(`:196`)會清掉哨兵;marker 格式是 `<nonce> <step> <reason>`(`:115`),裡面沒有「曾回 11」。
  - §4.1(`:135`)與 §1.4(`:76`):`resetting-pending` 放行 cancel。
  - §3 哨兵列(`:116`)只約束「哨兵」的刪除者。撤銷時一起刪掉的 marker 和 `apps.reset → apps`,沒有同等的約束。
  - 讀者用 `ro,noload` 掛 p5 時,不會重播 journal → 看不到剛 commit 的 rename:96 `:89`、config-save `--check`/`--prov-get` 的 ro 掛載 `batman-config-save:254`、`batman-slot` `node_checks` `:540`。這讓「讀不到 / 看不到」比想像中常見(見 m2)。
- **修法**(不需要新機制,marker 已經有 `step` 欄位):
  1. **marker `step ≥ 3` = 「可能已提交」,而且這個值不會往下降**:
     - helper 啟動時,只要 step ≥ 3,而 parser 不是 `intent`(也就是 none、bad 或 unreadable),一律判成 `reset-uncertain`,**不判 `resetting-pending`**。
     - 從 reset-uncertain 用 F0 重新發起時,marker 的 step 要保留 ≥3 的記號(例如加一個 `committed-maybe` 旗標),不能被改寫回 1。
  2. **撤銷(包含 F3 rc 10 之後的撤銷,以及 cancel)的共同前提**:
     - marker step ≤ 2(或沒有 committed-maybe 旗標);
     - **而且**在持有 `cfgsave.lock` 的情況下(確定沒有活著的 config-save),parser 正面讀回 `none`。
     - 任一條件不成立 → 不撤銷,回 `E_RESET(uncertain)`,節點留在 reset-uncertain。
  3. rc 10 的定義改成「本次呼叫結束時,p5 上**沒有**意圖」:`--reset-intent` 在拿到鎖、rw 掛上之後,先看有沒有既有的意圖。有既有意圖(不論 nonce 是不是同一個)時,只要 rename 沒有成功,就回 11,不回 10。
  4. 判斷表要對 parser 的 4 種輸出、marker {在(step ≤2 / ≥3)、不在、p6 沒掛} 逐格寫清楚。p5 `unreadable` 時,helper 不得補 persist overlay 身分(v4 rc 7 的規則要排除這種情況)。
  5. 文件明說:reset-uncertain 而 p5 讀不到時,重新發起和撤銷**都不能做**(F0 的前置條件要求「p5 ro 掛得起」)→ 狀態顯示「需要 bench / 換卡,請勿使用」。不要宣稱「有人接手」。
- **負對照**:
  - 白箱 seam:F3 rc 11 → F4/F5 → 下一次開機讓 parser 回 `unreadable`(seam)→ 斷言 cancel 被拒、status 是 `reset-uncertain`、`apps.reset/` 還在。照 v8 字面:cancel 被接受(FAIL)。
  - 情境 3:F3 時 `kill -9` helper,讓孤兒 config-save 晚 5 s 才 rename(seam)→ 斷言新 helper 在 cfgsave.lock 釋放前不判 pending,之後判 `intent` → 從 F4 續做。

### MINOR

**A8-m1. rc 10/11 的界線寫成「寫任何 p5 位元組之前 / rename 之後」,中間有空檔,和 config-save 的實際步驟對不上** — **PR-P1 必帶**
- rw mount 一成功,就已經寫了 ext4 superblock(mount count、state)。所以「任何位元組」這個說法不成立。真正有意義的界線是「意圖檔名的 rename(2) 有沒有發出」。
- 「rw 掛上 → 寫 tmp → fsync tmp → rename」中間這一段失敗(ENOSPC、EIO)該回幾,沒有寫。在沒有既有意圖的前提下(見 M1 修法 3),這一段失敗回 10 是安全的,因為檔名沒有被碰到。
- tmp 檔必須和意圖檔在**同一個 p5 目錄**,用 rename:
  - busybox `mv` 跨檔案系統時會退回成「複製 + 刪除」,不是原子的,目的檔名下可能出現半個檔 → 判成 `bad` → Wb 永久卡住;
  - 比照 config-save 現有做法,把 STAGE 放在 `$MNT` 裡(`batman-config-save:351,391`)。
- **rename 之前要 fsync tmp 檔**(`/bin/fsync` 在 02/04 都有)。ext4 的 `auto_da_alloc` 只保護「rename 蓋掉既有檔」;新建的檔案 rename 之後斷電,可能留下 0 byte 的檔 → Wb。W0 改寫 attempts 也照這個做(tmp + fsync + rename + fsync 目錄)。
- 留在 p5 上的 tmp 檔:解析器只比對正確的檔名;下一次 `--reset-intent` 或 W2 要清掉它。
- 負對照:白箱 seam 讓 tmp 寫入失敗 → rc 10,p5 上沒有 `.factory-reset`;F3 rename 之後立刻斷電(seam `reboot -f`)→ 下一次開機 parser 回 `intent`,不是 `bad`。

**A8-m2. 讀 p5 意圖的掛載選項沒有規定;現行的讀者有的用 `noload`,有的會和 F3 的 rw 互卡** — **PR-P1 必帶**
- **noload**:
  - 用 `ro,noload` 掛時不會重播 journal,F3 `sync` 之後、`umount` 之前斷電所留下的 rename 會看不到。
  - 現行的 96 `:89`、config-save ro 分支 `:254`、`node_checks` `:540` 都用 noload。
  - §4.3 說 `--prov-get` 見意圖 → rc 15,可是它的掛載是 noload,和「所有讀者共用 parser」的說法矛盾。
  - 要求:所有意圖讀者都經過 `reset-intent.sh`,而且**不用 noload**。替代做法是看到 `needs_recovery` 就回 `unreadable`。
  - 寫明 S11 的第一個讀者會重播 journal(這是一次寫入,而且只會發生在開機的時候)。
- **讀錯誤**:`[ -f ]` 通過,但 `head` 讀到 EIO → 要回 `unreadable`,不要回 `bad`。
- **T11**:任何 ro 讀者(autocommit `:394` 每次評估都會掛 p5、precheck-node、helper 自己的 parser)正好在 F3 的時候持有 p5,config-save 的 rw mount 就會「came up read-only」(`batman-config-save:236-249`)。v8 把這種情況歸成「其他 10 → 撤銷 + 請換卡」,誤報了,而且會讓使用者白白換卡。修法有兩種:
  - 「rw 掛起來是 ro」歸成可重試(和鎖忙一樣,重試到 60 s);
  - 或讓 parser 也取 `cfgsave.lock`。
  helper 呼叫 F3 之前,要先放掉自己的 p5 掛載。

**A8-m3. `reset-intent.sh` 的比對規格無法照字面實作** — **PR-P1 必帶**
- 文件寫「用 `case` 比對 `… nonce=[0-9a-f]{16} …`」。ash 的 `case` 是 glob,`{16}` 會被當成字面字元 → 每一份合法的意圖都判成 `bad` → 每一次重置都卡在 Wb(fail-secure,但整個功能不能用)。要寫成 16 個 `[0-9a-f]`,或改用 `grep -Eqx`。
- `head -c 64` 之後只讀第一行,第二行之後的垃圾、或超過 64 byte 的內容會被忽略。A7-m5 原本要求「多行或超長 → bad」,v8 沒有寫進去。要求:整個檔案剛好是一行,長度 ≤ 52 byte(含換行),而且整行完全符合格式。
- 負對照:合法意圖 → `intent`;多一行 → `bad`;長度 65 → `bad`;FIFO / symlink → `bad`,而且不會卡住。

**A8-m4. W0 的「取 `cfgsave.lock`」實際上擋不住 config-save** — **PR-P1 必帶**
- config-save 的 `lock_try`(`batman-config-save:115-122`)只認 cmdline 含 `batman-config-save` 的持有者;其他持有者會被當成 stale 直接接管。batdata-mount 的 cmdline 是 `/bin/sh /etc/init.d/batdata-mount boot`,所以 W0 拿著這把鎖,config-save 照樣接管。
- 現在 W 只在 `boot()` 跑,和 config-save 同時執行的機率很低。但文件宣稱有互斥,實際上沒有。
- 修法:W0 改成呼叫 config-save 的一個新模式(`--reset-attempt <nonce>`,A7-m6 的原案)。這樣 p5 的寫入程式仍然只有 config-save 一支,也不必另外寫 tmp + rename(m1)。
- F3 讀回時只比對 nonce 和 slot。

**A8-m5. 終態「unclaimed 但上鎖、沒有 key」仍有兩條路會走到;W2 被斷電打斷時節點是開放的** — **PR-P1 必帶**(Q5:04 遠端救不回)
- **路 1**:W1 在 fresh 開機失敗,96 上鎖(§4.3)。但 L 段只寫了 batdata-mount 會 touch `/etc/batman-reset.locked`,96 沒有。下一次(非 fresh)開機,W1/W2 成功,W3 看不到旗標 → 不補清 overlay。
- **路 2**:W3 的補清排在 W2 **之後**,而 W2(mkfs p5)就是完成紀錄。W2 之後、W3 的 jffs2reset 之前斷電,意圖已經消失,W 不會再跑,也就沒有東西會補清。
- **W2 被斷電打斷**(B7-m4 殘留):p5 magic 不是 ext4 → parser 回 `unreadable` → 96 `:71` → p6 剛被 W1 清掉,沒有 prov-state → 4b → image 預設的空密碼。
  - mke2fs 預設會先 discard,前任秘密暴露有限;但文件寫的「W2 失敗 → 上鎖」在斷電這種情況不成立。
- 修法:
  - 96 上鎖時也 touch 這個旗標;
  - W1 成功後,在新 p6 寫 `reset-p6-wiped` 的同時,如果 overlay 被鎖過,就記下來,讓 W3 的「補清 + 重開」排在 W2 之前做,或讓 W3 不看意圖、只看 p6 的旗標;
  - 96 看到 p6 上有 `reset-p6-wiped` 而 p5 讀不到 → 上鎖(B7-m4 原案)。
  - 都不採用的話,就把這三個終態照實寫進 Q5 的後果和殘項。
- 證據:§4.5 W3(`:237`)、L(`:239`)、§4.3 96 上鎖清單(`:164-170`)。

**A8-m6. 「`/opt/batdata` 不是 mountpoint → 不啟動」把 joinwatch 也包進去,對 p6 壞掉的現場節點是回歸;p6 的寫者沒有跟著改** — **PR-P1 必帶**
- joinwatch 本來就設計成 p6 沒掛也能跑:`joinwatch:23,42,93`(「batdata not mounted — diagnosis kept in syslog」),而且 `:162` 在 p6 沒掛時本來就不會自動重開。
- joinwatch 負責 `--on-join`(讓 p5 跟上即時設定)和 `$RUNDIR/joinwatch.state`(halow-status、autocommit 的 `lastjoined` 會讀)。新規則一上線,任何 p6 壞掉的節點(跟重置無關)p5 就不再跟著即時設定更新,member 的入網判斷也會跟著失準。
- 卡住狀態下,joinwatch 呼叫 `--on-join` 本來就會被 config-save 自己擋下(見意圖 → rc 1,§4.3)。所以 joinwatch 不需要 mountpoint 這條規則,只保留 marker 檢查就好。
- A7-m9 要求的「96(`lock-status`)、99zz(prov-state)、helper(health、ble-ok)寫 p6 之前先確認 p6 有掛」,v8 沒有寫。96 `:154` 的 `mkdir -p /opt/batdata/state; echo … > lock-status` 在 p6 沒掛時會寫進 overlay 的掛載點目錄。

**A8-m7. marker flock:非 root 程序可以讓重置或取消卡住** — **PR-P1 必帶**
- 04 實測:`/opt/batdata/state` 是 `drwxr-xr-x root`、umask 0022 → marker 會是 0644。Linux 的 `flock(LOCK_EX)` 只要能讀就能拿,所以任何本機非 root 程序(或被攻陷的 provd)都能開啟 marker 並一直拿著鎖:
  - helper 的 F 步驟會被卡住;如果卡在 F3 和 F4 之間,節點就停在「tenant 已停、沒有重開」的狀態;
  - cancel 永遠回 `E_BUSY`。
- 另外,marker 在取消或 W1 時會被刪掉或重寫。如果實作是 tmp + rename,flock 就鎖在舊的 inode 上,互斥失效。
- 修法:鎖改用 `$RUNDIR`(0700,#280)裡一個固定的鎖檔;marker 改成 0600。
- 負對照:非 root 程序對 marker 下 flock → 斷言 F 步驟和 cancel 都不受影響。

**A8-m8. 擁有權表(§3)沒跟上 v8 的新資源**
- 鎖定欄位現在有 3 個寫者:fresh S10 的 96、非 fresh S11 的 batdata-mount(L)、S89 之後的 helper;§3 `:118` 只列 2 個。
- `/etc/batman-reset.locked`:寫者(batdata-mount;依 m5 還有 96)、讀者(W3)、刪除者(jffs2reset)都沒有登記。
- `state/reset-p6-wiped <nonce>`:寫者 W1、讀者 W1、生命週期(之後由誰刪,還是留著)都沒有寫。
- W1 要讀這個檔,就必須在 W1 之前先掛 p6(要寫明用 `ro,noload` 另外掛、讀完卸載)。這和「W 在 mount p6 之前」的說法要一起寫清楚。

**A8-m9. 文件殘留和矛盾**(實作時照錯的那一份做,就是 bug)
- §6.4 `:290` 還寫「`pgrep -f ^/bin/sh /sbin/sysupgrade` 或等價」,和 §4.5 `:183`、D27 `:291` 的「uid 0 + 主機 pid ns + argv[1] 精確比對」矛盾。
- §4.3 `:168`「helper 判 `unknown` 時只改第 2、1 欄」還在(第 4 欄 verdict 也要寫;A7-m11 已經指出,§13 說改了,實際沒改)。
- cancel 的時段:§4.1 `:135` 寫「F1–F2」,v7 寫「F3 之前」(含 F2b),§4.5 撤銷 `:211` 寫「F3 之前」。三處要統一。
- R43「任何層級的 dot 項目都不刪」不精確(A7-m11):不刪的是 dot **目錄**,dot 檔會被刪。
- reset-uncertain 宣稱「有人接手」,但 p5 讀不到時,重新發起和撤銷都做不了(見 M1 修法 5)。

**A8-m10. 生命週期矩陣缺的列和證據**
- **降版或 `-F` 到不懂意圖的 image**:舊 image 不認得意圖 → 照常 commit → 意圖永久留在 p5。之後升級回意圖槽(fresh overlay,沒有哨兵)→ W1/W2 會在幾個月後把 p6 清掉。
  - 修法:新 image 的 precheck-node 見到意圖就拒絕(已有);在文件裡寫明 `-F` 和降版的後果;另外考慮讓 W 要求「marker 在,或 `reset-p6-wiped` 同 nonce」才動手(p6 上都沒有 → crit `stale-intent`,不清,上鎖)。
- **W0/W3 在 S11 呼叫 `batman-slot reboot committed`**:這條路要經過 procd 的 shutdown。現有的先例 `fw_override_check` 用的是直接的 `/usr/sbin/batman-reboot`,而且會先 remount overlay ro(`95:476-479`),兩者不同。
  - 我讀了 procd 原始碼:`procd_shutdown` 在 init 階段也會切到 SHUTDOWN(`state.c:223-231`)。`rcS()` 對 shutdown 會 `runqueue_init(&q)` 重設佇列(`rcS.c:197-203`),排隊中的 S12+ 不會再跑,所以 dropbear 不會在 jffs2reset 後用 rom 的空密碼起來。這是**推論**,不是實測。
  - K90batman-reboot 在 rom ✅(04、02 都有 `/rom/etc/rc.d/K90batman-reboot`)。
  - 要求:補一條 D 列;L16 斷言 W0/W3 重開的那段時間裡 22 埠沒有開。
  - 另外,K10batdata-mount 在 upper,會被 jffs2reset 刪掉 → 沒有 shutdown.marker → 下一次 boot-reasons 會記成 UNCLEAN(只是判讀上的雜訊)。比照 fw_override 先寫 marker。

**A8-m11. sysupgrade 程序判定的漏判與測試**
- 只認 argv[1] 剛好等於 `/sbin/sysupgrade`:用 `cd /sbin; ./sysupgrade`、`sh sysupgrade` 呼叫時會漏判。後果有限,因為 install_bin 之後還有 `upgraded` 這道檢查。修法:argv[1] 以 `/proc/<pid>/cwd` 解析成絕對路徑後再比對。
- 負對照 (n) 加上「容器內 root(另一個 pid ns)偽造」這一項;docker 預設沒有 userns,容器 root 在主機上就是 uid 0,只靠 ns 那條擋。

**A8-m12. 誠實界線補一條:對「有 root 的前任」,重置不構成保護**
- 有 root 的前任在 F1 之後讀得到 marker 的 nonce,可以預先放一個 `state/reset-p6-wiped <nonce>` 讓 W1 跳過。他也可以改本槽的 squashfs(重置不會重刷本槽)。
- W0 卡住(`reset-stuck overlay`)的節點,前任的 `authorized_keys` 仍然有效(上鎖後 key 登入照樣可用,U3)。
- 這些都屬於「前任有 root」的範圍,本來就擋不住。寫進 §4.5 誠實界線和買家須知:「轉賣請重燒卡;狀態顯示 reset-stuck 或 reset-uncertain 的節點不要收」。

**PR-P1 必帶**:M1 + m1、m2、m3、m4、m5、m6、m7。m8–m12 可以在實作和程式碼審查時補。

---

## 3. 指定重點逐項

| 項 | 結論 |
|---|---|
| rc 0/10/11 切分 | F3 這一刻 ✅。「寫任何位元組之前」不是 config-save 能判斷的界線(rw mount 本身就寫了 superblock);正確的界線是「rename 發出之前,而且沒有既有意圖」(m1、M1-3)。rename 失敗歸 11 ✅ |
| 部分 rename / `mv` vs rename | ext4 的 rename 對檔名是原子的;busybox `mv` 只有在同一個檔案系統時才是 rename。新檔案在 rename 前沒有 fsync,斷電後可能變成 0 byte → Wb(m1)。D36 要加上「同目錄」和「先 fsync」的條件 |
| `reset-uncertain` | 進入條件靠一個沒有持久化的「F3 曾回 11」和一個 F4 會清掉的哨兵 → 實際上幾乎進不去;p5 讀不到時它提供的兩個動作都做不了(M1) |
| 「p5 可能有意圖時絕不刪哨兵」對每個刪除者 | F4/W0 ✅;F3 rc 10 撤銷 ✗(F0 重新發起時可能有既有意圖);cancel ✗(只看狀態,不看 step);marker 和 `apps.reset` 的還原沒有被這條規則保護(M1) |
| helper 啟動判斷表 | 少了 unreadable、bad、p6 沒掛、step 這幾個維度;F3 中 crash 時,新 helper 沒有等孤兒 config-save(M1) |
| batdata-mount 非 fresh 上鎖 | 方向 ✅;96 沒有 touch 旗標、W3 排在完成紀錄之後(m5);擁有權表沒更新(m8) |
| `/etc/batman-reset.locked` + W3 補清 | 見 m5;W3 重開走 procd shutdown 的證據見 m10 |
| `state/reset-p6-wiped` | 解決了 W1 每次重清的問題 ✅;要在 W1 前另外掛 p6(m8);root 前任可以預放(m12) |
| Wt tmpfs 檢查 | ✅。04、02 的 `/overlay` 都是 f2fs(`/mmcblk0p4 on /overlay type f2fs`);fstools `mount_root.c` 的 FS_NONE/FS_DEADCODE → `ramoverlay()` 對得上;Wa 排在 Wt 前面,不影響 trial |
| sysupgrade 程序判定 | uid 0 + ns + argv[1] ✅(`/proc/1/ns/pid` 在 04 可讀);§6.4 還留著 pgrep(m9);相對路徑會漏判(m11) |
| `reset-intent.sh` | 檔案型別、`head -c`、不 eval ✅;`case {16}` 無法照字面實作、多行和長度沒規定(m3);掛載選項和讀錯誤的處理(m2) |
| p6 沒掛 fail-closed | guardian、firstload、dockerd ✅;joinwatch 是回歸(m6) |
| W 只在 `boot()` | 方向 ✅;現行是 `start(){ boot; }`(`95:728`),實作必須把 W 從 boot 拆開,start 不經過 W——要寫成 PR-P1 的明確要求 |

## 4. 逐 actor

- **BLE 路人 / 只看過 QR 的人 / 買家 BLE 很弱 / 擁有者回應遺失**:v8 沒改這部分;psk_replay 與 app 契約同 v7 ✅。
- **本機非 root 程序**:搶 marker 的 flock(m7);偽造 sysupgrade cmdline 已擋 ✅;`state/`、`/etc` 寫不進 ✅。
- **被攻陷的 tenant**:容器 root 會被 pid ns 擋下 ✅(負測試要補,m11);沒有掛到 `state/` 的 volume → 種不了 `reset-p6-wiped`。
- **被攻陷的 provd**:cancel 和重置都要 owner_op ✅;它可以讀 marker 的 nonce,但用不上(寫不了 p6)✅;flock DoS(m7)。
- **前任擁有者**:成功路徑 ✅;M1 路徑在使用者取消之後掉資料;有 root 的前任不在保護範圍內(m12)。
- **實體 SD**:放壞意圖 → Wb 上鎖、不掛 p6(等同重燒卡)✅;放 `reset-p6-wiped` → 等同改卡,已在誠實界線內。
- **供應鏈**:無新增。
- **我們自己**:`case {16}`(m3)、noload(m2)、沒 fsync(m1)、§6.4 和 §4.3 的殘留(m9)、W0 的鎖只是名義上的(m4)。

## 5. v7 發現核對(一條一行)

| v7 | 狀態 | 說明 |
|---|---|---|
| A7-M1 | **partial** | F3 三態 ✅;helper 判斷表、cancel、F0 重新發起仍會在 p5 可能有意圖時撤銷(M1) |
| A7-m1 | addressed | 前置條件 f2fs + Wt;建議哨兵檢查直接看 `/overlay/upper/etc/…`,文件沒寫(小) |
| A7-m2 | addressed | 判斷表「marker + 意圖 + slot → F4 續做」✅ |
| A7-m3 | addressed | autocommit 見意圖不 commit、node_checks 拒絕;但 autocommit 遇到 `unreadable` 怎麼做要寫明(不要讓 p5 死掉的節點永遠不 commit) |
| A7-m4 | addressed | uid + ns + argv[1];§6.4 殘留(m9)、相對路徑(m11) |
| A7-m5 | partial | 型別和 eval ✅;多行、長度、`case {16}`、noload、W0 tmp+rename 沒寫(m1、m2、m3) |
| A7-m6 | partial | 寫了「取鎖」,但 config-save 會接管這把鎖(m4) |
| A7-m7 | partial | batdata-mount 上鎖 + W3 ✅;96 沒有旗標、W3 在完成紀錄之後(m5) |
| A7-m8 | addressed | `reset-p6-wiped` + W2 失敗時掛新 p6 + 上鎖 |
| A7-m9 | partial | guardian、firstload、dockerd ✅;joinwatch 回歸、p6 寫者沒處理(m6) |
| A7-m10 | partial | rc 表 ✅;T11 的 ro 讀者被歸成「換卡」(m2) |
| A7-m11 | partial | 大多已修;§4.3 `:168` 殘留、R43 未改(m9) |
| A7-m12 | addressed | L52–L57 |
| A7-m13 | addressed | 寫明不改,理由成立 |
| B7-M1 | **partial** | 同 A7-M1 |
| B7-m1 | partial | tmpfs ✅;「哨兵在、意圖不在」靠 reset-uncertain,但它的條件幾乎不成立(M1) |
| B7-m2 | addressed | 有比對 slot;選擇重做 F4(冪等),可接受 |
| B7-m3 | addressed | Wb 在 Wa 前、autocommit、node_checks |
| B7-m4 | partial | 「W2 回錯誤」那次開機有上鎖;「W2 被斷電打斷」仍是開放(m5) |
| B7-m5 | addressed | `batman-slot reboot committed`;K90 在 rom ✅(04/02 實測)。shutdown 路徑的證據見 m10 |
| B7-m6 | addressed | 同 A7-m4 |
| B7-m7 | partial | 同 A7-m5 |
| B7-m8 | partial | rc 表、v5 §6.4 欄位 ✅;§6.4 pgrep、§4.3 殘留(m9) |
| B7-m9 | partial | start/restart 不跑 W ✅(實作要拆 `start(){ boot; }`);joinwatch(m6) |
| B7-m10 | partial | 有 flock、`ota-residue` ✅;flock 可被非 root 搶走(m7) |
| B7-m11 | addressed | EEPROM、serial 窗口 |

## 6. 使用者已定案事項的後果(不重開,只列)

- **U4 全清含身分 + Q5(L16 在 04)**:
  - m5 的三個終態(fresh 開機 W1 失敗、W2/W3 之間斷電、W2 被斷電打斷),都會讓 04 不是「image 預設空密碼可從乙太網進去」:前兩者是上鎖沒 key(遠端救不回,要到現場),第三者是開放。
  - L16 之前要把 m5 修掉,否則副作用清單要寫明「可能需要到現場」。
  - M1 的修法會讓「p5 讀不到」的節點停在 reset-uncertain、不能取消 → 04 的 p6 資料(OTS DB、dv289 備份)一定要在按恢復出廠**之前**先搬到主機(Q5 已經這樣規劃 ✅)。
- **U3 擁有權和 SSH 脫鉤**:reset-stuck 的節點仍接受前任的 key 登入(m12),買家須知要寫。
- **U6(3A+ 延後)**:Wt 和 f2fs 的判斷只在 bcm2711 實測過;bcm2710 的 overlay 型別未測。

## 7. 本輪唯讀探針(原始輸出摘要)

- 04 `mount`:`/mmcblk0p4 on /overlay type f2fs (rw,…,nodiscard,…)`;`/dev/mmcblk0p6 on /opt/batdata type ext4 (rw,relatime)`;cmdline `batman_slot=B`;`batman-slot active` = `B`,`is-trial` rc=1。
- 02 `mount`:`/overlay` f2fs、`/opt/batdata` ext4;`/rom/etc/rc.d/K90batman-reboot` 存在。
- 04 `ls -la /rom/etc/rc.d`:`K90batman-reboot -> ../init.d/batman-reboot` 在 rom。`/overlay/upper/etc/rc.d` 有 `S11batdata-mount`、`K10batdata-mount`,`S99batman-payload-opentakserver`(會被 jffs2reset 刪掉 → 依賴 95 重跑,符合 §4.5)。
- 04 `which`:`/sbin/jffs2reset`、`/usr/sbin/mkfs.ext4`、`/usr/sbin/blkid`、`/usr/bin/sgdisk`、`/usr/bin/hexdump`、`/usr/bin/pgrep`、`/bin/fsync`、`/usr/bin/flock`、`/usr/bin/mountpoint`;沒有 `stat`、`timeout`。`head --help`:`-c [-]N[bkm]`;`mv --help`:有 `-T`。
- 04 `ls -ld /opt/batdata/state` = `drwxr-xr-x root`;02 umask `0022`(→ m7)。
- 04 `/proc/1/ns/pid` → `pid:[4026531836]`,和 `/proc/self/ns/pid` 相同(root 讀得到,m11 的判定可行)。
- 04 p6 shutdown log:5 次開機都是 `mount_root: switching to f2fs overlay`,沒有出現 `temporary tmpfs overlay`。
- 04 `autocommit.log`:3 行 `FW-OVERRIDE … correcting restart to p2`(S11 重開的先例存在,但機制是直接 `batman-reboot`,見 m10)。
- 原始碼:fstools `jffs2reset.c:44-55`(掛載中 → PENDING + overlay_delete,沒有 `-r` 就不重開)、`mount_root.c` FS_NONE/FS_DEADCODE → `ramoverlay()`;procd `state.c:223-231`、`rcS.c:197-203`(shutdown 重設佇列)、`rcS.c:161`(只有 stop/shutdown 有 15 s 逾時,S 腳本沒有,R71 ✅);config-save `:115-122`(鎖接管條件)、`:236-249`(T11)、`:254`(ro,noload);96 `:89`(ro,noload)、`:154`(lock-status);`batman-slot:540`(ro,noload);joinwatch `:23,42,93,162`;95 `:476-479`(fw_override 的重開方式)、`:728`(`start(){ boot; }`)。

## 8. 判定

**REJECT(窄)**:0 BLOCKER / 1 MAJOR / 12 MINOR。

A8-M1 只要把 marker 已有的 `step` 當成「可能已提交、不會往下降」的記號,並讓撤銷和 cancel 都以「持鎖狀態下 parser 正面讀回 none」為前提,就能收掉,不需要新機制。修完後請重審整份文件;m1–m7 列為 PR-P1 必帶。
