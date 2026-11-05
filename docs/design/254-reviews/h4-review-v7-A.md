# H4 harness 設計 v7 — 審查 A(第 7 輪)

- 對象:`docs/design/254-h4-harness.md` v7(`harness/254-h4` @ c9dac70),整份審。
- 上層對照:P3 `254-p3-impl.md` v7.1(`/home/yello/Batman-p3`);h23 v14;`219-protocol.md` v0.7 + `.cddl`。程式:`/home/yello/Batman` main 2ecf1cb。
- 節點:只對 04 做唯讀 ssh(列出 busybox / uid 切換工具、`/etc/passwd` 的 provd 行)。沒有建介面 / namespace、沒有改 uci、沒有重啟服務、沒有連 BLE。
- WSL:非 root 沙箱實驗與 ash fd 實驗,都在 `mktemp -d` 裡做,做完已刪(輸出最後的 `No such file or directory` 是刪除後的確認)。沒有改 repo,只寫這份報告。

**結論先講**:第 6 輪的兩條 MAJOR(A-M1 認目標佐證、A-M2 舊根沒卸)都解了。M2 我用 wsl.22 同源的 aarch64 rootfs 實跑:用新根的 busybox(經 qemu binfmt)`umount -l /old` 成功、`/old` 不在、mountinfo 只剩 6 筆;「不卸舊根」的對照確實會寫到宿主(`old=pwn-old`),有鑑別力。第 6 輪 A、B 的 MINOR 大多已處理。

v7 新寫的 UD8b(上傳檔換成 FIFO)和 P3 的實際流程對不上:P3 的 `update.prepare` 會先檢查上傳檔大小,FIFO 的大小是 0,所以在 worker 開檔之前就被 reason 15 擋下。照 v7 的寫法,這一臂在正確的 P3 上會 FAIL;如果實作的人把預期改成 15 來「修」它,`O_NONBLOCK` 這道防線就永遠沒人測。要修,得在 P3 的接縫清單加一個點,所以列 MAJOR。其餘都是 MINOR。

**判決:APPROVE-WITH-CHANGES(0 BLOCKER / 1 MAJOR / 12 MINOR)**。已收斂。

---

## 0. 證據(原始輸出節錄)

```
# (1) WSL 非 root 沙箱(aarch64 rootfs = firmware-2710 root-bcm27xx 的副本;binfmt qemu-aarch64 flags POF)
### v7 順序 A(pivot 前掛 proc)
  abs-write: refused
  old-write: refused
  mounts: / /dev/null /dev/zero /dev/urandom /tmp /proc (n=6)
  /old absent
  uname -m in sbx: aarch64
== docd=1 umount=1 proc=before => canary=orig cwd=orig old=orig
### v7 順序 B(卸舊根之後才掛 proc)— 一樣成功
  mounts: / /dev/null /dev/zero /dev/urandom /tmp /proc (n=6)
== docd=1 umount=1 proc=after => canary=orig cwd=orig old=orig
### 負對照:不卸舊根
  abs-write: refused                      <- 「絕對路徑」那條照樣 PASS
  mounts: /old /old/init /old/dev ... (n=43)
  /old exists
== docd=1 umount=0 proc=before => canary=orig cwd=orig old=pwn-old   <- 寫到宿主,有鑑別力
### 「不 cd /」:先 `cd $R; pivot_root . old`
== docd=0 umount=1 proc=before => canary=orig cwd=orig old=orig      <- cwd 對照沒有被改(見 m7)
### 「不 cd /」:從宿主 cwd 執行 `pivot_root "$R" "$R/old"`,之後 umount -l /old
== pivot_root R R/old from host cwd, cd/=0, umount -l done => host canary-cwd=pwn-cwd   <- lazy umount 不會收回 cwd
== pivot_root R R/old from host cwd, cd/=1, umount -l done => host canary-cwd=orig
ls: cannot access '/tmp/sbxA7.…': No such file or directory

# (2) busybox ash(WSL 的 busybox,⚠️ 不是 04 那一版):fd 9 的繼承
subshell (..) 9>&- : 0 lock fds
function f 9>&- &  : 1 lock fds (in bg subshell pid)        <- §5.7「一律用子 shell」正確

# (3) 04 唯讀
start-stop-daemon / chroot 在 PATH 上;/sbin/ujail -U <name>「user to run jailed process」
沒有 su / setpriv / chpst / setuidgid;/usr/bin/mkfifo 在
provd:x:471:471:provd:/var/run/provd:/bin/false

# (4) provd(main 2ecf1cb)
server.go:529-533  info(): cbor.M(1, s.c.deviceID, …)       <- info key 1 = device_id(§4.2 (b))
session.go:78      RoleCandidate: {"info", "auth/owner"}     <- psk_owner 交握後可以送 info
session.go:633-634 case "info": okEnv(id, ss.srv.info(role)) <- wsl.22 上由 provd 自己回,不經 helper
bluez.go:599 / 614 b.logf("provd: adv registered/withdrawn reason=%s")  <- logf,不限流
server.go:639      s.logf("provd: session revoked reason=%s")             <- 不限流(OW3)

# (5) P3 v7.1 的 update 流程
:327  update.prepare … 上傳檔存在且大小 = key 3;啟動 worker … | … 上傳不完整 → reason 15
:402  上傳完成:… app 接著 update/prepare … prepare 自己檢查大小(§3.7.4)
:456  上傳檔 … helper 刪(… prepare 發現不符)
:353  worker 1. 先以 O_RDONLY|O_NOFOLLOW|O_NONBLOCK 開上傳檔 … fstat:regular、link 1、uid 471、大小 = key 3
:359  7. 上傳檔被 provd 中途改寫:… 讀回都以 SHA256SUMS 為準 → 不符就 invalidate_slot、不 arm
```

---

## 1. 第 6 輪意見的處理(對附錄 F 逐條核對)

| 意見 | 結果 |
|---|---|
| A-M1 / B-m3 認目標負對照的佐證 | ✅ (a)(b) 改用 blebridge 記的「msg2 之後送出的 frame 數」、`info` 的 key 1(§0-4 確認 = device_id,psk_owner 角色可以送)、兩台的 adv withdrawn / registered(logf,不限流)。這些在 wsl.22 上都拿得到。小缺口:frame 計數器本身沒有負對照(m8) |
| A-M2 舊根沒卸掉 | ✅ 實跑(§0-1):新根的 busybox 經 qemu 卸得掉,`/old` 不在,只剩 6 個掛載點;不卸舊根的對照 `old=pwn-old`,有鑑別力。proc 在卸舊根之前或之後掛都可以 |
| A-m1 / B-m1 host 正常那一臂 | ✅ 測試拆成兩臂(§5.7 測試第 3、4 條)。殘留:正文 `:549` 的「正常情況」還是舊說法(m1) |
| A-m2 / B-m5 UD20 | ✅ P 改用新的 nonce,另拆出 UD20b。殘留:資料怎麼傳、UD20 與 UD20b 的順序、P 會真的跑 worker(m5) |
| A-m3 UD8c 長度 | ✅ 同長度、保留 magic,也對得上 prepare 的大小檢查與 worker 的 fstat(uid 471 以 rename 換檔 → link 1、uid 471)|
| A-m4 / B-m4 fake path 細節 | ✅ 完整的單 frame 訊息、10 s 內、HTTP 改用 tcpdump + counter。殘留:限流額度的算法(m9) |
| A-m5 OW3 | ✅ 時序、slot、`adv registered` 的時限都寫了;用到的 log 行經 §0-4 確認 |
| A-m6 / B-m2 deadman 殺 pgid | ⚠️ 加了「先等子工具結束」與「殺不掉 → 只做段 1 + NEEDS-PERSON」。新的競態見 m2;殺不掉那條沒有測試臂(m3) |
| A-m7 fd 0–2 | ✅ |
| A-m8 HT23 / §4.5 | ✅ §4.5 寫明例外;`status` 斷言拿掉 |
| A-m9 / B-m6 / B-m7 | ✅ 檔名、recover 掃兩個目錄、journal 不放 `$BT/<run>/`、逾時 = 預算 + 60 s、三種模式都寫 log |
| A-m10 UD8b | ⚠️ FIFO 改由 uid 471 建立 ✅;但整條臂到不了 worker(**M1**) |
| B-m8 文字 | ✅;`( … ) 9>&-` 的行為實測正確(§0-2) |

---

## 2. BLOCKER

無。

---

## 3. MAJOR

### M1. UD8b(上傳檔換成 FIFO)到不了 worker:prepare 的大小檢查會先以 reason 15 擋下;`O_NONBLOCK` 這道防線沒有任何臂測得到

**情境**:UD8b 寫的是「以 uid 471 把上傳檔換成 FIFO → worker 以 `O_NONBLOCK` 開檔、fstat 不是 regular → 11」。換檔只能在 `update.prepare` 之前或之後做:
- **之前**:P3 `:327` 規定 prepare「上傳檔存在且大小 = key 3」,不符就是 reason 15;`:402` 又寫「prepare 自己檢查大小」;`:456` 寫「prepare 發現不符 → helper 刪上傳檔」。FIFO 的 stat 大小是 0,所以 prepare 回 `E_REJECTED{15}`、不啟動 worker、FIFO 被刪。實際結果是 15,不是 11,這一臂在正確的 P3 上會 **FAIL**。
- **之後**:prepare「啟動 worker,立刻回 phase 2」,worker 第一步就開檔(`:353`)。prepare 的大小檢查和 worker 開檔之間只有微秒級的窗口,harness 沒有辦法穩定地插進去。§5.2 的 killpoint(`upd-write-mid`、`upd-before-arm`、`upd-after-arm`)都在開檔之後。

**後果**:
1. 照寫實作 → 假 FAIL,浪費一輪 rc。
2. 實作的人很可能把預期改成「15」,讓它 PASS。這樣這一臂只證明了 prepare 的大小檢查,P3 §3.7.5-1 的 `O_NONBLOCK` 就沒人測。可是**被入侵的 provd 正好能贏這個競態**:prepare 就是經 provd 轉送的,它可以在轉送的同時換檔,時間由它決定。所以那一個窗口才是 P3 §8「上傳檔換成 FIFO」這一條要防的情境。少了 `O_NONBLOCK`,worker 會卡在 open,`updating` 一直為真,之後的 OTA 全部被擋(可用性攻擊)。這一條在 harness 裡沒有負對照,和規則「每個宣稱的檢查都要有負對照」衝突。
3. G 只准用在 UD12、UD16(H4-U8),所以不能直接改標 G。

**修法**(兩擇一,第一個不需要使用者決定):
- (a) 在 §5.1 / §5.2 加一個接縫,並寫進 §1.4-2 給 P3 的契約:
  - Go fault `upd-open-pause`:worker 在「prepare 檢查通過 → 開檔」之間停 N 秒,並記 `fault upd-open-pause: armed`。
  - UD8b 改成兩臂:
    - **UD8b-pre**:prepare 之前換成 FIFO → 斷言 `E_REJECTED{15}`、FIFO 被刪、worker 沒有啟動(W + P);
    - **UD8b-race**:帶 `upd-open-pause`,在停住的那幾秒裡由 uid 471 換成 FIFO → 斷言 11、≤ N + 5 s 內 phase 0、`updating` 清掉、helper pid 沒變。
  - S 對照:另一個 fault `upd-open-block`(開檔不帶 `O_NONBLOCK`)→ 同樣的操作 → worker 卡住(phase 2 超過 N + 30 s)→ 證明這一臂有鑑別力。
- (b) 請使用者把這一條加進 H4-U8 的 G 範圍(Go 單元測試:worker 遇到 FIFO 不會卡住),UD8b 本身只保留「pre」那一臂。

另外,「以 uid 471」要寫明用什麼做:04 上沒有 `su`、`setpriv`,provd 的 shell 是 `/bin/false`;`start-stop-daemon -c provd` 或 `ujail -U provd` 可以用(§0-3)。UD5、UD8c 也一樣。

---

## 4. MINOR

1. **§5.7 正文 `:549` 的「正常情況」還是舊說法**:「host 拿著鎖時,`dm-fire` 會等鎖 … host 做完會 `release`,dead-man 被取消,根本不會執行」。`dm-fire` 要等 lease 過期才開始等鎖,而 lease 一過期 `release` 就會 die(F-H48),所以這句只在「lease 還有效時 host 已做完」才成立,和下面的兩臂測試矛盾。改成兩種情況分開寫。另外寫明:主機遇到 `release` 回 "lease is not ours or expired",而 `dv-undo-<run>.log` 顯示已完成時,算正常結束,不判失敗(v6-B m1 的後半)。

2. **deadman「先等子工具結束、再殺群組」有競態**:deadman 在等 `halow-setkey` 結束的時候,host 執行器沒有被凍結。setkey 一結束,host 可能立刻開始下一個動作(例如另一個 `ap-restore` 或 `p5-save`),deadman 的 TERM 就剛好打在它剛開始的時候,這正是 v6 A-m6 想避免的「寫到一半被殺」。修法:先對 host 執行器的 **shell 本身**(`undo-doing` 記的 pid,不是整個群組)送 `SIGSTOP`,讓它不能再 fork 新動作;等目前的子工具結束;再對群組送 TERM + CONT。被打斷的動作沒有標 `done`,deadman 的段 2 會重做,而每個動作都是冪等的,所以結果一致。

3. **「`pg_kill` 殺不掉 → 只做段 1 + NEEDS-PERSON」沒有測試臂**(v6-B m2 要求的那一臂)。`test-h4-undo.sh` 加一臂:測試用動作在自己的子 shell 裡 `trap '' TERM` 並且一直不結束 → 斷言 deadman 沒有做段 2、記了 NEEDS-PERSON、journal 的段 2 項目仍未標 `done`。負對照:拿掉這條規則 → 段 2 被執行(兩個寫者)。

4. **HT23(以及 HT12、HT14、HT18、HT19、HT21)要寫明「誘發之前 8095 在聽」**:HT23 寫的是 RB(沒有 `http-nofw`),沒有寫 T 窗或備援。HTTP 本來就沒在聽的話,「8095 不聽」一定成立,斷言就失去意義。§6.2 的「兩邊都先斷言 8095 在 LISTEN」只寫給「換規則型的 S」。建議把這條寫成每個「≤ 8 s 不聽」臂的共通 P:誘發前 `netstat` 有 8095,而且有 `http.2`(provd log 或 poll 的值);載具寫成 RB(T 窗)。

5. **UD20 / UD20b 的細節**:
   - 資料怎麼傳沒寫(v6-A m2 的後半):peer 經 provd 的 session 取得 `op/nonce`(綁這條 session 的 h)→ peer 輸出 h 與簽好的 owner-op → 節點上的 provclient 以 uid 471 把 `update.prepare`(body 的 sha = Y)連同 h、owner-op 直接送給 helper。這段 owner-op 不能經 provd 送出,否則 nonce 會先被消耗掉。
   - UD20 的 P(新 nonce、sha X)會**真的啟動 worker**,覆寫 B、刪掉上傳檔、跑好幾分鐘。§13 沒有列這一項;UD20b 也要排在它前面,或等 worker 結束再做(worker 在跑的時候,prepare 的回應沒有定義)。
   - 建議順序:UD20 負向 → UD20b → UD20 的 P,之後依 §13 的 prov-update 列還原。

6. **ST9 / UD5 / UD8b / UD8c 的「以 uid 471」怎麼做**:見 M1 最後一段。補進 §5.5 或 §4.5,加一個 E-H 項,在 04 上先驗證 `start-stop-daemon -c provd` 建出來的檔,擁有者確實是 471。

7. **§8.2 的 cwd 對照要寫明 pivot 的寫法**(§0-1 實測):
   - 實作者常寫 `cd "$R"; pivot_root . old`。這樣 cwd 本來就在新根裡,「拿掉 `cd /`」的對照不會改到宿主(`cwd=orig`)。照 §8.2 的「任一條不成立 → FAIL」,單位就會永遠假 FAIL。
   - 改成寫明「從宿主的 canary 目錄直接執行 `pivot_root "$R" "$R/old"`,不先 cd 進 `$R`」。我實測過這個寫法下,沒有 `cd /` 的話,即使 `umount -l /old` 已經做完,還是會寫到宿主(lazy umount 不會收回 cwd),所以 `cd /` 是必要的,對照也有鑑別力。
   - mountinfo 那條建議斷言「正好」是 `/`、`/dev/null`、`/dev/zero`、`/dev/urandom`、`/tmp`、`/proc` 這 6 筆(實測 n = 6)。只寫「沒有舊根那一筆」的話,要靠實作的人去猜哪一筆算舊根。

8. **identify 的 selftest 缺 frame 計數器自己的負對照**(v6-A M1 修法第 3 點):blebridge 的「msg2 之後送出的 frame 數」是 (a)(b) 唯一的獨立見證。selftest 要加一個對照:故意關掉 DAC 比對 → peer 會送出 `info` → 計數 > 0 → 判 FAIL。否則計數器本身壞掉(例如永遠回 0)時,(a)(b) 會假 PASS。

9. **fake path 的限流額度**(v6-A m4 的前半):v7 寫的是「fake path 臂之間至少隔 10 s、每分鐘最多 5 次、臂期間不做其他會產生 session-end 的動作」。但限流看的是**前 60 s 的所有** `session` key 行,包括上一臂留下的(例如 RT1 矩陣被拒的格子會產生 `disconnect after the response`)。改成:送出之前,先數這台最近 60 s 的 `provd: session ended` 與 `disconnect after` 行,加起來 ≥ 9 就等;等過頭判 INVALID,不判 FAIL。

10. **§1.4-2 / §4.2 的 helper ro 計數契約還太模糊**:只寫了「`info.state` 加一個『ro 動詞處理次數』欄位」,沒有寫欄位的 key、計哪些動詞、是否單調遞增、helper 重啟會不會歸零(歸零 → 該臂 INVALID)。A.5 的 SD3 那一列也沒有用到它。要嘛在 SD3 寫明怎麼用(例如 S `ro-on-ctl` 下計數不變、正常時增量 ≈ ok 數),要嘛從 §1.4-2 拿掉,免得 P3 多做一個沒人用的欄位。

11. **undo 的 log 不能記 C0**(v6-A §6 的意見還沒處理):`dv-undo-<run>.log` 在 `ap-restore` 時只記 SSID 與 passphrase 的 sha;拷回主機前,先在節點上以原值 grep 一次(同 §4.1)。§5.7 補一句。

12. **編輯**:
    - 狀態列下的「審查報告在 `h4-review-v{1,2,3,4,5}`」改成 `v{1..7}`;
    - 附錄 F 的列沒有把 v6-B 的每一條 m 編號都對應出來(例如 B-m6 / B-m7 合在 A-m9 那一列);建議逐條列,方便下一輪核對。

---

## 5. 附錄 A 逐列核對(W / S / P / G;只寫有變動或有問題的)

- **W**:`--pre-p3-full` 規則不變。identify 的 (a)(b) 在 wsl.22 上拿得到佐證(§0-4)。UD8b、UD20、UD20b 的 W(E_U)成立。
- **S**:
  - HT23 的 S(`http-nofw` → 照樣給 `http.2`)有鑑別力(P3 `:382` 的前提檢查正是 `http-nofw` 關掉的那一段);前提見 m4。
  - UD8b 缺 S,見 M1。
- **P**:
  - OW3 的 P(remove 前兩條都能用)成立;
  - UD8c 的 P(合法 tar、總長相同、`root.squashfs` 的 sha 不同)成立,和 P3 `:327`、`:353`、`:359` 一致;
  - UD8b 的 P(檔案是 FIFO、擁有者 471)成立,但這一臂的本體到不了 worker(M1);
  - UD20 的 P 改用新的 nonce(副作用見 m5)。
- **G**:只出現在 UD12、UD16。M1 的修法 (b) 要擴大範圍,需要使用者決定。
- **「—」**:ST17、ST22、BG4 都附了理由。

---

## 6. 安全(逐個 actor,只寫 v7 新增或改變的)

| actor | 結論 |
|---|---|
| 供應鏈 / 我們自己的錯(沙箱裡的 uci-defaults,userns root) | 舊根、cwd、fd 三條都實測擋住,三條對照都有鑑別力(§0-1)。cwd 對照的寫法見 m7 |
| 被入侵的 provd | UD8c、UD20、UD20b 的本體成立。**FIFO 競態**(provd 控制轉送 prepare 的時間)沒有臂測到(M1) |
| 被竄改的 Windows 橋 / 成員節點冒充 | DAC 釘選 + 橋的獨立 frame 計數 + 節點端的 info device_id;計數器自己的對照見 m8 |
| 本機非 root 行程(節點) | 沒有新入口;`undo-doing` 在 `$BT`(root 0700) |
| 主機斷線 / 睡眠 | host / deadman 交接正確;子工具寫到一半的競態見 m2 |
| 被入侵的手機 | 沒有變;OW3 的 HTTP 兩條 session 都經手機,判定用的是節點端的 log |

**秘密**:見 m11(undo log)。其他沒有新的洩漏面。

---

## 7. 判決

**APPROVE-WITH-CHANGES:0 BLOCKER / 1 MAJOR / 12 MINOR。**

- **M1**:UD8b(FIFO)照 P3 的流程,在 prepare 的大小檢查就以 15 被擋下,到不了 worker。照寫會假 FAIL;改預期就等於沒測 `O_NONBLOCK`,而被入侵的 provd 正好能贏那個競態。修法:加 Go fault `upd-open-pause`(以及 S 用的 `upd-open-block`),寫進 §1.4-2 的契約,UD8b 拆成 pre / race 兩臂;或請使用者把這一條加進 G 範圍。

**收斂了嗎**:收斂了。第 6 輪的兩條 MAJOR 經原始碼與實跑確認都解了。M1 是 v7 新寫的一臂沒對照 P3 的實際流程,修法是局部的(一個接縫、一臂拆兩臂),骨架不用動。MINOR 1–4 會影響第一次實跑(假 FAIL 或斷言失去意義),建議和 M1 一起改。下一輪預期範圍很小,可以只核對 M1 與 m1–m4。

**本輪的誠實界線**:
- ✅ 實跑:WSL 非 root 沙箱(aarch64 rootfs、qemu binfmt、新根的 busybox 卸舊根、舊根 / cwd 對照);ash 的 `( … ) 9>&-`(WSL 的 busybox)。
- ✅ 原始碼:provd 的 `info`、log 行、角色表;P3 的 prepare / worker 流程。
- ✅ 04 唯讀:uid 切換工具、provd 帳號。
- ⚠️ ash 實驗用的是 WSL 的 busybox,不是 04 上那一版;沙箱用的是 firmware-2710 build 樹的 rootfs,不是 sha 釘死的 wsl.22 rootfs。
- ❌ 沒做:任何改節點的實驗(依規則);`start-stop-daemon -c provd` 沒有在 04 上實際執行。
