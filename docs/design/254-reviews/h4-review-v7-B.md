# H4 harness 設計 v7 — 審查 B(第 7 輪)

- 對象:`docs/design/254-h4-harness.md` v7(`harness/254-h4` @ c9dac70),整份審。
- 對照:P3 `254-p3-impl.md` v7.1(§3.7.4–§3.8.2、§5.1、§6、§7、§8);main 2ecf1cb:`scripts/node/ble-lib-254.sh`、`prov-lease-254.sh`、`feed/batman-prov/src/provd/{session,server}.go`、`node/node.go`。
- 節點:04 只做兩次唯讀 ssh(`command -v`、`start-stop-daemon --help`、`/etc/passwd` 的 provd 行)。WSL:一個 busybox ash 的 fd 9 繼承實驗,在 `mktemp -d` 裡做,做完已刪(輸出最後一行是刪除後的 `cannot access`)。
- **我自己的錯,記錄在此**:第一次做 WSL 實驗時,`wsl -- bash -c '…'` 的 `$d` 被外層展開成空字串,`cd ""` 沒有切換目錄,結果在 `/home/yello/` 與 `C:\Users\yello\Desktop\Batman\` 各留下 `lock`(0 B)與一個測試腳本,在 WSL `/tmp` 留下兩個空的 `tmp.*` 目錄。四個檔案與兩個目錄都是我在 00:24–00:25 建的(時間戳已核對),已經刪掉並確認不在。之後改成 `wsl --exec bash <script>`。沒有碰到其他檔案。
- 沒有改 repo,只寫這份報告。

**結論先講**:第 6 輪的 2 條 MAJOR(A-M1 認目標的佐證、A-M2 舊根沒卸)都解了,MINOR 大多也解了(逐條見 §1)。整份重看之後,有一條新的 MAJOR:**UD8b(上傳檔換成 FIFO)照 v7 的寫法到不了它要測的防線**。P3 的 `update.prepare` 會先檢查「上傳檔大小 = key 3」,FIFO 的大小是 0,所以會在 prepare 這一步就回 `E_REJECTED{15}`,worker 根本不會開檔,`O_NONBLOCK` 與「fstat 必須是 regular」都沒被測到。修法需要在 §5.2 加一個 killpoint,這是給 P3 的接縫契約,所以要在 H4 凍結前定下來。其餘 9 條 MINOR 都是局部修改。

**判決:APPROVE-WITH-CHANGES(0 BLOCKER / 1 MAJOR / 9 MINOR)**。已收斂。

---

## 0. 證據(原始輸出節錄)

```
# (1) P3 v7.1 —— update.prepare 與 worker 的順序
:327  update.prepare {1: sha} | sha = pending 的 key 4;呼叫者 = 上傳窗擁有者;上傳檔存在且大小 = key 3;啟動 worker …
      | 無 pending / sha 不符 / 上傳不完整 → reason 15
:353  worker 1. 先以 O_RDONLY|O_NOFOLLOW|O_NONBLOCK 開上傳檔 … fstat:regular、link count 1、uid 471、大小 = key 3
:355  2. Go compress/gzip + archive/tar 白名單解析 … sha256(SHA256SUMS) = key 4,否則 reason 11
:357  4. … root.squashfs(tar header 大小 = metadata size= …)
:359  7. 上傳檔被 provd 中途改寫:… 讀回以步驟 2 驗過的 SHA256SUMS 為準 → 不符就 invalidate_slot、不 arm
:456  上傳檔 | … helper 刪(bulk.close、窗到期且沒有 worker、prepare 發現不符)
:492  HTTP 交握 | NX / psk_replay | 連線關閉(與 fake path 等長回應後關)
→ FIFO 的 st_size = 0 ≠ key 3 → prepare 自己就回 15,worker 不會啟動

# (2) main 2ecf1cb —— provd info(認目標 (b) 的佐證)
server.go:529-533  info(role): cbor.M(1, s.c.deviceID, 2, Model, …)       ← key 1 = device_id ✔
session.go:623-633 p3Types → E_UNSUPPORTED;"info" 不在 p3Types,任何角色都可呼叫 ✔(wsl.22 上可用)

# (3) main —— dead-man 的實際順序(ble-lib-254.sh)
:327-333  cmd_dm_fire: sleep → 20×lock 30 → 拿不到:dm_log + kill_run_groups "$run"   ← 在 role_fire_restore 之前
:338      lease 檢查通過 → kill_run_groups "$run" → role_fire_restore → provd_start
:314-316  cmd_release: lease_valid_for 不成立 → die
:127-134  pg_kill: TERM 整個群組,最多等 10 s
:143      dm_arm: setsid sh … dm-fire … 9>&- &      ← 既有程式在 setsid 時就關 fd 9

# (4) main —— owner-op 驗證(UD20)
node.go:672-690  每個符合 h 的 nonce:takeHelperNonce 一律消耗;簽章不符 → EForbidden "owner-op signature / nonce"

# (5) 04 唯讀
su=none setpriv=none chpst=none runuser=none sudo=none
start-stop-daemon=/sbin/start-stop-daemon(busybox)   -c USER[:[GRP]]  Change user/group
provd:x:471:471:provd:/var/run/provd:/bin/false
→「以 uid 471」可用既有的 start-stop-daemon -c 寫法(tmp-trust-280.sh:19 的 NB())✔

# (6) WSL busybox ash:( … ) 9>&- 的子行程
locked
A sleep pid 956: clean          # ( lim sh -c 'sleep 1' ) 9>&- & 的子行程沒有 fd 9 ✔
B func-subshell: clean
ls: cannot access '/tmp/tmp.s34DJEm3T5': No such file or directory   # 實驗目錄已刪
```

---

## 1. 第 6 輪意見的處理(對附錄 F 逐條核對)

| 意見 | 結果 |
|---|---|
| A-M1 / B-m3 認目標佐證 | ✅ (b) 用 `info` 的 key 1:`server.go:529-533` 確認 key 1 = `deviceID`,而且 `info` 不在 `p3Types`,wsl.22 上可用。「msg2 之後送出的 frame 數」有一處要定義清楚(m9) |
| A-M2 舊根沒卸 | ✅ 用新根的 busybox `umount -l`、`rmdir /old`、加了負測試與對照。mountinfo 只檢查 `/old`(m6) |
| A-m1 / B-m1 host 正常臂 | ✅ 拆成兩臂,符合 `:314-316`、`:327-338`。主流程沒寫 `release` 失敗時主機怎麼做(m3) |
| A-m2 / B-m5 UD20 | ✅ 改用新 nonce,另拆 UD20b。還有順序與上傳檔被刪的問題(m4) |
| A-m3 UD8c 長度 | ⚠️ 加了「同長度」,但「調 tar 的 padding」做不到精確的壓縮後長度(m5) |
| A-m4 / B-m4 fake path 細節 | ✅ BLE 這一半解了。HTTP 改用「回應長度」,但 P3 規定 fake 回應與真回應等長,沒有鑑別力(m1) |
| A-m5 OW3 | ✅ 時序、slot、`adv registered` 時限都寫了 |
| A-m6 / B-m2 殺 pgid | ⚠️ 加了「先等 setkey / config-save」與「殺不掉 → 只做段 1」。等待與殺群組之間有空窗;另外 `kill_run_groups` 在 `undo_run` 之前就執行(m2) |
| A-m7 沙箱 fd 0–2 | ✅ |
| A-m8 HT23 | ✅ §4.5 寫明例外、拿掉 `status` 斷言。缺「8095 本來在聽」的前提(m8) |
| A-m9 / B-m6 / B-m7 檔名、recover、journal 位置、逾時 | ✅ journal 不在 `$BT/<run>/`(我查過,`gc_rundirs` 只刪 `$BT/*/`,其他地方沒有對 `/tmp/run/batman-dv` 整個刪除);recover 掃兩個目錄;`q()` 逾時 = 預算 + 60 s |
| A-m10 UD8b | ⚠️ 改由 uid 471 建 FIFO,但整臂到不了 worker(**M1**) |
| B-m8 文字 | ✅ SuppPubInfo、key 8、子 shell `9>&-`(我在 WSL busybox ash 實跑,子行程確實沒有 fd 9,§0-6;OpenWrt 的 ash 沒有實跑 ⚠️)、`undo_run` 的位置 |

---

## 2. BLOCKER

無。

---

## 3. MAJOR

### M1. UD8b(上傳檔換成 FIFO)會在 `update.prepare` 就被 reason 15 擋下,worker 不會開檔:它要測的 `O_NONBLOCK` 與「fstat 必須是 regular」都沒有被測到

**情境**:UD8b 寫的是:以 uid 471 把上傳檔換成 FIFO → worker 以 `O_NONBLOCK` 開檔、fstat 不是 regular → 11;沒有卡住 = `update.status` ≤ 5 s 回應、helper pid 不變。

**證據**(§0-1):
- P3 `:327`:`update.prepare` 在啟動 worker **之前**要求「上傳檔存在且大小 = key 3」,否則 reason 15。FIFO 的 `st_size` 是 0,key 3 是 payload 大小(約 126 MB),一定不符。
- worker 第 1 步(`:353`)才是 `O_NONBLOCK` 開檔與 fstat 檢查,在 prepare 通過之後。
- prepare 回應後 worker 立刻開檔(`:327`「啟動 worker,立刻回 phase 2」),中間沒有主機可以換檔的空窗。

**後果**:
- 照原文判定(期待 11),第一次執行就 FAIL。
- 實作的人最可能的做法是把預期改成 15。那樣這一臂就會 PASS,但 worker 拿掉 `O_NONBLOCK`、或拿掉 regular 檢查的 mutant 也一樣會 PASS:被測的是 prepare 的大小檢查,不是 §3.7.5-1 的防線。
- 被入侵的 provd 可以在 prepare 檢查之後、worker 開檔之前換檔(真實攻擊者可以在兩次系統呼叫之間換檔,主機做不到)。如果 worker 少了 `O_NONBLOCK`,它會卡在 `open()`,`updating` 一直是真,`otaBusy()` 會一直擋住 OTA 與 `settings.set`,直到 helper 重啟。附錄 A 把 P3 §8 的「上傳檔換成 FIFO」對到 UD8b,但這一列實際上沒有被測。W 載具(wsl.22 回 E_U)與 P(檔案確實是 FIFO)都偵測不到這個落差。
- 修法需要一個新的 Go killpoint,也就是改 P3 第一個 commit 的接縫清單(§1.4-2、§5.2)。這個清單在 H4 merge 之後就凍結,所以必須在這一輪定下來。

**修法**:
1. §5.2 加 killpoint `upd-before-open`:worker 在 §3.7.5 第 1 步之前停住(與既有 killpoint 相同,以檔案放行,或設上限,例如 60 s),同步加進 `prov-wbox-254.sh` 的封閉清單與 §1.4-2。
2. UD8b 改成:prepare(大小正確的真上傳)→ worker 停在 `upd-before-open` → 以 uid 471(`start-stop-daemon -c provd`,§0-5)把上傳檔 rename 成 FIFO → 放行 → 斷言 ≤ N s 內 phase 0 + `3: 11`、`updating` 已清(`update.status` 只讀快取,判定要用 phase 0 + reason,不能只看「有回應」)、helper pid 不變、B 不是 BAD(還沒有 `begin_write`)。
3. **S 對照**:加一個 Go fault `upd-open-block`(worker 開檔時不帶 `O_NONBLOCK`)→ 同一流程中 worker 卡住:N s 內沒有出現 reason 11,`updating` 為真,`settings.set` 回 `E_BUSY`。這樣這一列才有 S 等級的鑑別力。還原:helper 重啟(段 1)。
4. 另外保留一個 P 臂(或寫進 UP4):沒有 killpoint 時,把上傳檔換成 FIFO → prepare 回 15。這證明大小檢查本身有效,不必另外做測試。

---

## 4. MINOR

1. **HTTP fake path 的節點端佐證沒有鑑別力**(§4.2)。v7 寫「HTTP 的 fake path 改用 tcpdump(回應長度)加 named counter」。但 P3 `:492` 規定 NX / psk_replay 的回應**與 fake path 等長**,就是要讓回應長度看不出差別。`batman_http_mark` 只證明封包是從手機 AP 進來的。所以這兩項在真 msg2 與 fake msg2 時的值會一樣。HT7 / RT1h 的鑑別力實際上來自 S 對照(`http-allow-nx`)。**修法**:
   - 節點端佐證改成「回應之後,04 先送出 FIN」(tcpdump 看到 server 端的 FIN / RST 出現在回應之後 ≤ 1 s)。真的 session 不會由 server 主動關閉。
   - 或者在同一個 session id 上再送一次 `POST /msg`,斷言連不上,或是 session 不存在。
   - 在 §4.2 寫明:HTTP 的主要鑑別力來自 S。

2. **deadman「先等 setkey 再殺」有空窗;`kill_run_groups` 先執行**(§5.7)。
   - 卡住的 host 執行器在 setkey 結束後,會立刻開始段 2 的下一個動作,例如 `p5-save`(`batman-config-save --save`)。deadman 看到 setkey 結束、送出 TERM 時,剛好打在下一個寫入的中間。**修法**:先 `kill -STOP <執行器的 shell pid>`(只停父 shell,讓它不能再開新的子行程)→ 等目前的 setkey / config-save 結束 → `pg_kill`。注意:對已停住的行程送 TERM,要等 CONT 之後才會送達,所以在 TERM 之後補一個 `kill -CONT -<pgid>`(不要用 KILL)。
   - `cmd_dm_fire` 在呼叫 `role_fire_restore` 之前,就已經對 `$BT/<run>/*.pg` 執行 `kill_run_groups`(`:333`、`:338`)。單位用 `bg_start` 起的 setkey(例如 ST12 的 `setkey-pause`,「另一個 pgid」)會在「先等 setkey」的規則生效之前就收到 TERM。**修法**:二選一,寫明在 §5.7:
     - 引用 setkey 在 TERM 下的行為證據(它有 trap、會 rollback);
     - 或規定 setkey / config-save 不准登記成 `.pg`。

3. **`release` 在 host 模式成功之後失敗,主機該怎麼做:只寫在測試臂裡,主流程沒有寫**(§5.7 第 5 步)。lease 在 host 執行中過期時,`release` 會 die,dm-fire 隨後會再執行一次 `provd_restart`、`radio_restore` 與啟動服務。主流程應該寫:主機看到 `release` 回 "lease is not ours or expired" → 等 dm-fire 跑完(讀 `dv-undo-<run>.log`,以及 `state` 裡的 lease 消失)→ 才 `s0_assert`、才開始下一個單位。否則下一個單位的開頭可能撞上 dm-fire 重啟 provd(不會有兩個寫者,因為 dm-fire 會檢查 lease 是不是自己 run 的,但會讓下一個單位 INVALID)。

4. **UD20 / UD20b 的順序與副作用**:
   - P3 `:456`:prepare「發現不符」時 helper 會**刪掉上傳檔**。UD20b(`E_REJECTED{15}`)之後,UD20 的 P(新 nonce 對 X → 成功)會因為上傳檔不在而回 15。要寫明順序(先 UD20 的負向 → P 成功;UD20b 在另一次上傳之後做),或在每一臂之前重新上傳。
   - UD20 的負向同時符合兩個拒絕條件:`args_hash` 不符(`E_FORBIDDEN`),以及 sha ≠ pending(15)。回哪一個,取決於 helper 先驗 owner-op 還是先比 sha;P3 `:327`、`:486` 沒有規定順序。**修法**:§1.4 給 P3 的契約寫明「owner-op 先驗」;或者判定接受兩種碼,但都要斷言沒有啟動 worker,而且上傳檔的處理符合 `:456`。
   - UD20 的 P 成功 = worker 真的寫 B(phase 3,沒有 arm)。§13 的 prov-update 列涵蓋「A / B 重寫」,但要寫明這一臂會留下 pending + `BATMAN-VERIFIED`,下一臂開始前要等 pending 到期或重啟 helper。
   - v6-A m2 要求寫出 nonce 的資料路徑(peer 經 provd 以這條 session 的 h 取得 nonce → WSL 簽 → 節點上的 provclient 送 `{1: h, 2: raw}`),v7 只寫了「新的 nonce」。

5. **UD8c 的「同長度」做法不可靠**。「調 tar 的 padding」改的是解壓縮後的長度,gzip 壓縮之後的長度不會跟著精確對齊。**修法**:改用 gzip header 的 `FEXTRA` 或 `FCOMMENT` 欄位補足位元組(Go `compress/gzip` 會接受;原檔 header 沒有這兩個欄位時,補上不影響解析),先讓 mutant 比原檔短,再補到同長度。另一個做法:在 stored deflate block 裡原地改 `root.squashfs` 的位元組,再修正 CRC32。P 的離線驗收(長度相同、`gzip -t`、`tar t`、`root.squashfs` 的 sha 不同)已經寫了,所以這一點只是讓實作一次做對。

6. **沙箱的 mountinfo 只檢查 `/old`**(§8.2)。v6-A M2 的修法是斷言掛載點**正好**是 `/`、`/tmp`、`/proc`、`/dev/{null,zero,urandom}`。這樣以後如果有人在新根裡多 bind 了宿主的目錄,也會被抓到。v7 只寫「沒有舊根那一筆、`/old` 不存在」。建議改成白名單。

7. **HT14 的保險行程(以及任何在 `held` 底下 setsid 起來的行程)要加 `9>&-`**。HT14 的保險是 `setsid sh -c 'sleep 60; …'`。如果它是從持有 lease 鎖的指令裡起來的,它會繼承 fd 9,鎖會被它握住 60 s。既有的 `dm_arm` 就是為了這個原因寫了 `9>&-`(`:143`)。§5.7 的「子 shell 一律 `9>&-`」只寫在 undo 執行器的段 2 裡,要擴大到單位起的背景行程,包括 HT14 的保險、§7 的 uhttpd listener、ethsim 的背景 wget。

8. **HT23 缺「8095 本來在聽」的前提**。HT23 的載具寫 RB(沒有 `http-nofw`),斷言是「`http.2` 消失、8095 不聽」。但 8095 只在備援或上傳窗時才聽(P3 §3.8.1)。沒有開窗的話,8095 本來就不聽,「不聽」這個斷言會無條件成立,S 對照也一樣。**修法**:載具改成 RB(T 窗),並加 P:接上 `phy9h4` 之前,斷言 `netstat` 有 8095,而且 helper 給了 `http.2`。

9. **文字**:
   - 開頭寫「審查報告在 `254-reviews/h4-review-v{1,2,3,4,5}-{A,B}.md`」,要加上 6;狀態列的「v6 在 v5 上做局部修改:…」可以移到歷程表。
   - §4.2 的「msg2 之後送出的 frame 數」:blebridge 不解析 Noise,不知道多 frame 的 msg2 什麼時候結束。改成「peer 送完 msg1 的最後一個 frame 之後,再寫出的 frame 數 = 0」。這是橋自己數得出來的。

---

## 5. 附錄 A 逐列核對(對 P3 §6 / §7 / §8 / D-1…D-17)

- **§8 每個片語**:逐單位對過,沒有遺漏。「上傳檔換成 FIFO」對到 UD8b,但目前到不了 worker(**M1**)。「上傳後改 payload」對到 UD8c,在 worker 第 7 步的讀回比對失敗,有鑑別力(長度做法見 m5)。§8 的 HTTP 負對照「以 v5 的 `phy*-ap*` 規則載入(正向 FAIL)」對到 HT1 的 S,「以 v6 規則載入(VLAN FAIL)」對到 HT10 / PR1 ✔。
- **§6**:每一列都有對應。「helper 重啟時 setkey 還在跑」→ ST12;「上傳中 helper 重啟」→ UP8;「firewall reload」→ HT13;「換 IP」待 U5(P3 本身就標 ⚠️)✔。
- **§7**:「被入侵的 provd 偷換 pending 版本」→ UD20 / UD20b(順序見 m4);「佔 RAM」→ UP5;「搶建 bulk 路徑」→ UP11 ✔。
- **D-1…D-17**:附錄 A 的 D 對照表正確。
- **W**:都在第一個 P3 動詞或已知的行為差異上 FAIL。UD8b 的 W(E_U)不受 M1 影響,但不能代替 S。
- **S**:§5.1 / §5.2 / §5.4 的名字與附錄 A 一一對得上。M1 要加 `upd-before-open`(killpoint)與 `upd-open-block`(fault)。
- **P**:HT23 缺 LISTEN 前提(m8);UD20 的 P 受上傳檔刪除影響(m4)。
- **G**:只有 UD12、UD16(H4-U8)✔。
- **「—」**:ST17、ST22、BG4 都有理由 ✔。

---

## 6. 安全(逐個 actor,只寫 v7 新增或改變的)

| actor | 結論 |
|---|---|
| 被入侵的 provd | UD8b 的 FIFO 防線沒有被測(**M1**);UD20 的負向本體成立(`node.go:672-690`);UD8c 成立 |
| 被入侵的手機 | HTTP 每個交握都驗 DAC ✔;HTTP fake path 的節點端佐證沒有鑑別力,但 S 對照補上了(m1) |
| 成員節點 / 被竄改的 Windows 橋 | 認目標的 (a)、(b) 佐證在 pre-P3 拿得到(`info` key 1、adv 行、橋的計數)✔ |
| 本機非 root(節點) | 沒有新的入口。`undo-doing`、journal 都在 root 0700 目錄;`rm-file` 參數驗證不變 ✔ |
| 主機斷線 / 睡眠 | ssh 逾時、`trap '' HUP PIPE`、log 檔 ✔;`release` 失敗時的主機行為(m3);殺群組的空窗(m2) |
| 供應鏈 / 我們自己的錯(沙箱) | 舊根已處理 ✔;mountinfo 白名單(m6) |
| 我們自己的錯(鎖) | 背景行程繼承 fd 9(m7) |

**失敗模式**:除了 M1(可能被改成一個看起來 PASS、但沒有鑑別力的臂),其他 MINOR 都是 fail-closed:假 FAIL、INVALID,或可用性問題,不會假 PASS、不會造成暴露。

---

## 7. 判決

**APPROVE-WITH-CHANGES:0 BLOCKER / 1 MAJOR / 9 MINOR。**

- **M1**:UD8b 的 FIFO 會在 `update.prepare` 的大小檢查(P3 `:327`,FIFO 的大小是 0)就被 reason 15 擋下,worker 的 `O_NONBLOCK` / regular 檢查(`:353`)沒有被測到。修法:§5.2 加 killpoint `upd-before-open`,在 prepare 之後換成 FIFO;另加 fault `upd-open-block` 當 S 對照。這兩個都要寫進 §1.4-2 給 P3 的接縫清單。

**收斂了嗎**:收斂了。第 6 輪兩條 MAJOR 我都對過原始碼,確實解了。M1 是單一一列的局部修改(一個 killpoint、一個 fault、一列的步驟),不動骨架。之所以列 MAJOR,是因為它要改 P3 的接縫契約,而那份清單在 H4 merge 之後就凍結。MINOR 1、4、8 會造成假 FAIL,或讓斷言無條件成立,建議與 M1 一起改。下一輪仍要審整份,範圍預期很小。

**本輪的誠實界線**:
- ✅ 驗過:P3 `:327 / :353-359 / :456 / :492`;main 的 `ble-lib-254.sh:127-143, 314-338`、`server.go:529-533`、`session.go:623-633`、`node.go:652-690`;04 的 uid 切換工具與 provd uid(§0-5);WSL busybox ash 的 `( … ) 9>&-`(§0-6)。
- ⚠️ 沒有實跑:OpenWrt busybox ash 的同一個實驗(只在 WSL 的 busybox 1.36 上跑);gzip `FEXTRA` 補長度的做法(m5);沙箱(沿用 v6-A 的實驗)。
- ❌ 沒做:任何改節點的實驗(依規則不做)。
