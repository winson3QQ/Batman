# H4 harness 設計 v8 — 審查 A(第 8 輪)

- 對象:`docs/design/254-h4-harness.md` v8(`harness/254-h4` @ 3b2aa32),整份審。
- 對照:P3 `254-p3-impl.md` v7.1(`feat/254-p3` @ dfedd03);main 2ecf1cb 的 `feed/batman-prov/src/{node/node.go, provd/server.go, provd/session.go}`、`scripts/node/{ble-lib-254.sh, prov-lease-254.sh, tmp-trust-280.sh, bt-uart-305.sh}`、`scripts/dv/prov-ac-forge-254.sh`。
- 節點:只對 04 做兩次唯讀 ssh(busybox 版本、各行程的 argv0、`/proc/<pid>/stat` 的 pgid / sid)。沒有建介面 / namespace、沒有改 uci、沒有重啟服務、沒有連 BLE、沒有執行 `start-stop-daemon`。
- WSL:一個 busybox `start-stop-daemon` 比對行為的實驗,在 `mktemp -d` 裡做,做完已刪(輸出最後一行是刪除後的確認)。沒有改 repo,只寫這份報告。

**結論先講**:第 7 輪共同的 MAJOR(UD8b 到不了 worker)解了:UD8b 拆成 pre 與 race 兩臂,race 用 `upd-open-pause` 讓 harness 能在 prepare 檢查之後、worker 開檔之前換檔,`upd-open-block` 當 S;兩個名字都進了 §5.1,也就是 P3 的接縫清單。對照 P3 `:327`、`:353`、`:403`、`:456`,這兩臂現在都打得到它們要打的那道防線。第 7 輪 A、B 的 MINOR 大多也處理了。整份重看,沒有新的 BLOCKER / MAJOR;剩下 12 條 MINOR,都是實作時會造成假 FAIL / INVALID,或某個佐證少了正向對照,改法都是局部的。

**判決:APPROVE-WITH-CHANGES(0 BLOCKER / 0 MAJOR / 12 MINOR)**。已收斂。

---

## 0. 證據(原始輸出節錄)

```
# (1) WSL busybox(1.36.1,Ubuntu 套件):start-stop-daemon -S 會先找「已在跑」的行程
== -x /bin/sh (a /bin/sh process is running)
/bin/sh is already running
rc=1                                    <- 沒有執行
== -n unique -a /bin/sh (NB pattern)
RAN-n
rc=0
ls: cannot access '/tmp/tmp.OGagwPqf3D': No such file or directory   <- 實驗目錄已刪

# (2) 04 唯讀
BusyBox v1.36.1 (2025-06-23 20:40:36 UTC)          <- 與 (1) 同版本號
argv0 統計:   8 /bin/sh   8 sleep   5 /sbin/ujail ...   <- 隨時都有 argv0 = /bin/sh 的行程
me=9565 pgid=9564 sid=9564 ppid=9564               <- ssh 指令的 shell:pgid = 這條連線的 dropbear 子行程
dropbear 9564 pgid=9564 ppid=3193
dropbear 3193 pgid=1 ppid=1                         <- 監聽中的主行程 pgid = 1

# (3) main 既有的 uid 切換寫法
scripts/node/tmp-trust-280.sh:19  NB(){ start-stop-daemon -S -c nobody -n tmptrust280 -a /bin/sh -- -c "$1"; }
scripts/node/bt-uart-305.sh:36    同上,並在 :160 斷言 id -u = 65534
scripts/dv/prov-ac-forge-254.sh:36 -x /usr/bin/id -- -u,並斷言輸出 = 65534

# (4) P3 v7.1
:327  update.prepare … 上傳檔存在且大小 = key 3;啟動 worker,立刻回 phase 2 | … reason 15
:347  update.status(ro)只讀快取
:353  worker 1. 先以 O_RDONLY|O_NOFOLLOW|O_NONBLOCK 開上傳檔 … 之後才關上傳窗 … fstat:regular、link 1、uid 471、大小 = key 3
      (fstat 不符時回哪個 reason:步驟 1 沒寫;:358 只列「內容 / 讀回不符 11」)
:388  net/http:IdleTimeout 30 s(→ 真 session 的 TCP 連線不會在回應後立刻被 server 關)
:401  /tmp/run/batman-provd-bulk:專屬 tmpfs、0700 provd:provd、size= 2 × 本板目前的 release payload 大小
:403  helper 刪上傳檔的條件:worker 結束、bulk.close、窗到期且沒有 worker、helper 啟動時
:147  ctl 只給 poll:health.get、info.state、info.boot_id、info.owners

# (5) main 2ecf1cb
node/node.go:179-187   readOnlyVerbs 在 n.mu.Lock() 之前處理(→ ro 不會被 worker / ops 卡住)
node/node.go:236, 259-290  nonce {1: h}:h 由呼叫者給,nonce 綁 h
node/node.go:672-690   owner-op:對這個 h 的每個 nonce 都試、每試必消耗
provd/server.go:126-144 logLimited:每個 key 60 s 滑動窗,只算「有寫出」的行
provd/session.go:234, 337  key "session":`session ended: %v`(只在錯誤時)、`disconnect after the response`
ble-lib-254.sh:127-134 pg_kill:isint 檢查後 `kill -TERM -$1`
ble-lib-254.sh:327-340 cmd_dm_fire:拿不到鎖 → kill_run_groups;之後 kill_run_groups → role_fire_restore
```

---

## 1. 第 7 輪意見的處理(對附錄 G 逐條核對)

| 意見 | 結果 |
|---|---|
| A-M1 / B-M1 UD8b 到不了 worker | ✅ UD8b(pre)預期 15、FIFO 被刪,與 P3 `:327`、`:456` 一致。UD8b-race 用 `upd-open-pause`:暫停發生在 worker 裡(prepare 已回 phase 2),上傳窗在 worker 開檔之後才關(`:353`),helper 只在「沒有 worker」時刪窗外的檔(`:403`),所以暫停的 30 s 內 FIFO 不會被 helper 刪掉,換檔做得到;`upd-open-block` 與正向只差一個變數(flip 規則成立)。殘留:S 的預期結果寫錯、正向缺時限(m2);fstat 不符的 reason 不在 P3(m3) |
| A-m1 §5.7 正常情況 | ✅ (i)(ii) 兩種情況,與 `ble-lib-254.sh:314-316, 327-340` 一致 |
| A-m2 / B-m2 等子工具時 host 沒被凍結 | ✅ 先 STOP host 的 shell、等子工具、再 TERM + CONT。殘留:子 shell 本身沒被 STOP(m5);pgid 的驗證(m6) |
| A-m3 pg_kill 殺不掉沒有測試 | ⚠️ 改成 `test-h4-lib.sh` 以 stub 測(白箱誘發,可以接受),但沒有寫負對照(m7) |
| A-m4 / B-m8 「不聽」的臂缺 LISTEN 前提 | ⚠️ HT12、HT15、HT23 已加;HT14、HT18、HT19、HT21 沒有(m4) |
| A-m5 / B-m4 UD20 | ✅ 資料路徑、順序(UD20b → 負向 → P)、每臂前重新上傳、§13 的覆寫 B 都寫了。殘留:負向的拒絕碼(m9) |
| A-m6 uid 471 | ⚠️ 寫了 `start-stop-daemon -S -c 471:471 -x <工具>`,但 `-x` 會撞上「已在跑」的比對(m1) |
| A-m7 沙箱 cwd 對照 | ✅ 從宿主 cwd 執行 `pivot_root "$R" "$R/old"`,與第 7 輪實測一致 |
| A-m8 frame 計數器的負對照 | ✅ 有了;用詞有一處不一致(m12) |
| A-m9 fake path 限流額度 | ⚠️ 沿用 v7,沒有說明為什麼不數前 60 s 的行(m10) |
| A-m10 ro 計數契約 | ⚠️ 定義了 `ro_served`,但 SD3 沒有用它(m11) |
| A-m11 undo log 不記秘密 | ✅ §5.7 第 3 步 |
| A-m12 / B-m9 文字 | ✅ |
| B-m1 HTTP fake path 佐證 | ✅ 改看 04 主動送的 FIN,方向對(P3 `:388` 的 keep-alive 讓真 session 不會被立刻關)。殘留:要求 relay 保持連線、加正向對照(m8) |
| B-m3 release 失敗的主流程 | ✅ §5.7 第 5 步 |
| B-m5 UD8c 長度 | ✅ gzip `FEXTRA` / `FCOMMENT`。另有一個新發現的 tmpfs 空間問題,寫在 m3 的附註 |
| B-m6 mountinfo 白名單 | ✅ 6 筆,與第 7 輪實測 n = 6 相符 |
| B-m7 背景行程 `9>&-` | ✅ §4.5 |

---

## 2. BLOCKER / MAJOR

無。

---

## 3. MINOR

1. **「以 uid 471」的 `start-stop-daemon -S -c 471:471 -x <工具>` 會被「已在跑」的比對擋下**(§2)。busybox `start-stop-daemon -S` 在執行之前,會先找 exe 或 argv0 等於 `-x` 的行程,找到就印 `… is already running`、rc 1、**不執行**(§0-1 實測)。04 上隨時有 8 個 argv0 = `/bin/sh` 的行程(§0-2),而換檔要做 `mkfifo` + `mv` 兩步,實作的人最可能寫 `-x /bin/sh -- -c '…'`,結果什麼都沒做。UD8b 的 P(檔案是 FIFO、擁有者 471)會抓到,所以只是假 INVALID。**修法**:沿用 main 既有的 `NB()` 寫法(`tmp-trust-280.sh:19`、`bt-uart-305.sh:36`:`-n <獨一的名字> -a /bin/sh -- -c "…"`),並照 `bt-uart-305.sh:160` 先斷言 `id -u` = 471;E-H15 驗的就是這個寫法。UD5、UD8c、UP5 共用。

2. **UD8b-race 的 S 預期結果與 P3 不符;正向缺時限**。P3 `:347` 規定 `update.status` 只讀快取,main 的 ro 動詞也在 `n.mu` 之外處理(`node.go:179-187`)。所以 worker 卡在 `open()` 時,`update.status` 照樣會回應(phase 2),**不會逾時**。這一點 v7-B M1 修法第 2 項已經講過。目前的寫法:
   - 正向的「沒有卡住 = 下一個 `update.status` ≤ 5 s 回應」沒有鑑別力;
   - S 寫「`update.status` 逾時」,照寫實作 → S 臂等不到逾時 → 在 P3 PR 閘門上假 FAIL。
   
   真正有鑑別力的是 phase 0 + 11,但正向沒有寫時限。**修法**:正向改成「暫停結束後 ≤ 10 s 內 phase 0 + `3: 11`、helper pid 不變、B 沒有 `BATMAN-BAD`(還沒到 `begin_write`)」;S 改成「同一時限過後仍是 phase 2」,還原時順便以 root 開 FIFO 的寫端或重啟 helper(段 1)。

3. **P3 沒有規定「fstat 不符」回哪個 reason**。UD8b-race 斷言 11,但 P3 `:353` 第 1 步只列檢查項,`:358` 的對應表只寫「內容 / 讀回不符 11」。實作者回 1 或 11 都說得通,回 1 就是假 FAIL。**修法**:§1.4 加一條給 P3 的文字:「worker 第 1 步的 open / fstat 失敗 → reason 11」。
   - **附註(UD8c 的空間)**:bulk tmpfs 的 `size=` 是「2 × 本板目前的 release payload 大小」(P3 `:401`),而 UD8c 要在同一個 tmpfs 裡先寫好同長度的 mutant 再 rename(rename 不能跨檔案系統)。原檔 + mutant 剛好 2 × V 的大小;tmpfs 以頁計,兩個檔各自進位,可能比 `size=` 多一頁;受測 rc 的 payload 也可能比目前的 release 大 → ENOSPC → 假 INVALID。改成先以 uid 471 刪掉原檔、再寫 mutant(prepare 之前,窗還開著,不違反任何前提;結果仍是 regular、link 1、uid 471、大小相同)。

4. **HT14、HT18、HT19、HT21 還是缺「誘發前 8095 在聽」的前提**(v7-A m4 的其餘部分)。HT14 的載具是「RB(H4-U11)」,沒有 T 窗,也沒有前提;HT18 / HT19 / HT21 也一樣。HTTP 本來就沒在聽時,「不聽 / 不給 `http.2`」無條件成立;S(`http-nofw`)也一樣不聽,所以 S 臂在 P3 閘門上會顯示「沒有差別」而假 FAIL。**修法**:這四臂的載具都改成 RB(T 窗),並加 P「誘發前 `netstat` 有 8095 LISTEN、helper 給了 `http.2`」;最簡單是寫成 §6.2 的通則:「斷言『不聽』的臂一律先斷言在聽」。

5. **STOP 只停 host 的 shell,子 shell 沒停**(§5.7)。§5.7 規定段 2 的每個動作都在子 shell `( … ) 9>&-` 裡執行。子 shell 是另一個行程,不會因為父 shell 收到 SIGSTOP 而停下:子工具結束後,子 shell 會繼續執行它剩下的指令。如果子 shell 裡不只一個工具(例如 `( lim 60 halow-setkey …; batman-config-save --save )`,或在子 shell 裡標 `done`),TERM 仍可能打在下一個寫入的中間,或在 deadman 重做之前先標了 `done`。**修法**:§5.7 寫明「每個子 shell 只包一個工具呼叫;`done` 標記只由父 shell 在子 shell 回來之後寫」。這樣 STOP 父 shell 就足夠,deadman 會重做沒有標 `done` 的那一項(冪等)。

6. **kill 群組之前要驗 pgid**(§5.7 卡住的 host)。`undo-doing.<run>` 記的是 `<pid> <pgid> <boot_id>`,`pg_kill` 只檢查 `isint` 就送 `kill -TERM -$pgid`(`ble-lib-254.sh:127-134`)。04 上監聽中的 dropbear 主行程 pgid = 1(§0-2),而 root 對 `-1` 送 TERM 等於殺掉所有行程。正常情況下 host 執行器的 pgid 是這條 ssh 連線的 dropbear 子行程(§0-2 實測,與 v6-B 一致),但記錄檔寫壞、或日後有人從 procd / rc.local 叫 `undo`,就可能記到 1 或 deadman 自己的群組。**修法**:殺之前從 `/proc/<pid>/stat` 重新讀 pgid,要求「等於記錄值、> 1、≠ deadman 自己的 pgid、這個 pgid 裡有 cmdline 是 undo 執行器的行程」,不符 → 只做段 1 + NEEDS-PERSON。`test-h4-lib.sh` 加一個 pgid = 1 的負測試(stub `kill`,斷言沒有送出)。

7. **`pg_kill` 失敗那一臂沒有負對照**。`test-h4-lib.sh` 以 stub 的 `pg_kill` 回失敗,斷言「只做段 1、記 NEEDS-PERSON、段 2 的項目未標 `done`」。依規則,這一條要附「拿掉這條規則 → 段 2 被執行」的對照,證明斷言有鑑別力。補一句即可。

8. **HTTP fake path 的 FIN 佐證要有前提與正向對照**(§4.2)。FIN 有鑑別力的前提是:真 session 的 TCP 連線在回應之後**不會**被 server 關。P3 `:388` 的 `IdleTimeout` 30 s 讓這一點在 server 端成立,但只要 relay 送 `Connection: close`(例如用 `urllib.request`,它每個請求都帶這個 header),server 每次回應後都會送 FIN,佐證就失去鑑別力。**修法**:
   - relay 規定用 `http.client.HTTPConnection` 保持連線,不送 `Connection: close`;
   - 每個 HTTP fake path 臂,同一臂內先在一條**真的** session 上送一次請求,斷言回應後 5 s 內 04 **沒有**送 FIN(正向對照);
   - 「對同一個 session 再送一次 `/msg` → 連線已關」要寫清楚:是在原 TCP 連線上送(預期連線已關),不是開新連線(新連線會連得上,而 P3 沒有規定未知 session 的回應)。

9. **UD20 負向的拒絕碼**(v7-B m4 的第二點,v8 只寫了理由、沒改斷言)。負向同時有兩個拒絕條件:`args_hash` 不符(`E_FORBIDDEN`)與 sha ≠ pending(15)。v8 的 UD20 列自己寫了「P3 沒規定 helper 先驗 owner-op 還是先比 sha」,但斷言仍只有 `E_FORBIDDEN`。helper 若先比 sha,會回 15 → 假 FAIL;而且那樣 owner-op 的 `args_hash` 綁定根本沒被 UD20 測到。**修法**:二擇一並寫進 §1.4:(a) 規定 `update.prepare` 先驗 owner-op(與 main 的 `ownerOpVerb` 一致),UD20 斷言 `E_FORBIDDEN`;或 (b) 負向改成 body 的 sha **= pending X**、但 owner-op 是對 Y 簽的 → 只剩 `args_hash` 這一個拒絕條件 → `E_FORBIDDEN`。(b) 不需要改 P3,而且直接測到「provd 換掉擁有者簽的版本」這件事。另外寫明 nonce 的 `h`:provclient 自己產生一個 32 B 的 h,`nonce {1: h}` 與 `update.prepare` 用同一個 h(`node.go:236, 259-290`),peer 也對這個 h 簽。

10. **fake path 的限流額度**(v7-A m9,v8 沿用 v7 而沒有說明)。`logLimited` 是 60 s 滑動窗,只算有寫出的行(`server.go:126-144`);`session` 這個 key 還包含 `disconnect after the response`(`session.go:337`),RT1 矩陣等臂被拒的格子都會寫。「臂期間不做其他會產生 session-end 的動作」管不到**上一臂**在 60 s 內留下的行。後果是佐證行被吃掉 → 假 FAIL。**修法**:送出 fake msg1 之前,數 04 最近 60 s 的 `provd: session ended` 與 `provd: disconnect after` 行,≥ 9 就等;等超過 70 s 判 INVALID。

11. **`ro_served` 定義了,但沒有人用**(§1.4-2、§4.2、A.5 SD3)。SD3 的斷言與 P(`ok + E_RATE ≥ 5400、ok ≥ 2500`)沒有用到它;`ro-on-ctl` 的鑑別力其實來自 ctl 的每連線 5/s 額度(P3 `:147-148`)讓 ok 數掉到 2500 以下。依「只做必要的修改」,建議從 §1.4-2 與 §4.2 拿掉 `ro_served`,不要讓 P3 多做一個欄位。如果要留,就在 SD3 寫明怎麼用(例如「`ro_served` 的增量 ≥ ok 數」),並寫明欄位的 CBOR key、讀法(provclient 經第 4 條連線讀 `info.state`)、helper 重啟後歸零 → 該臂 INVALID。

12. **編輯**:
    - §1.4-2 寫「Go fault 17 個」,§5.1 的表現在是 19 個(v8 加了 `upd-open-pause`、`upd-open-block`)。這份清單就是交給 P3 的接縫契約,數字要對;
    - §4.2 (a) 的計數器定義是「msg1 之後、由 **peer** 送出的 frame 數」,但它的 selftest 負對照寫成「**假後端**在 msg2 之後送出一個 frame」。後端送的 frame 不算 peer 送的。改成「關掉 DAC 比對的 peer 在 msg1 之後送出 `info` → 計數 = 1 → 斷言 FAIL」;
    - 附錄 G 的 B-m5 那一列可以補上 m3 附註的空間問題。

---

## 4. 附錄 A 逐列核對(W / S / P / G;只寫有變動或有問題的)

- **W**:UD8b(pre)、UD20、UD20b 的 W(E_U)成立。UD8b-race 沒有 W,只有 S;它依賴 P3 的 Go fault,pre-P3 本來就做不到,符合 §6.2。
- **S**:
  - UD8b-race:`upd-open-pause` vs `upd-open-pause + upd-open-block`,只差一個變數 ✅;預期結果的寫法見 m2。
  - HT14、HT18、HT19、HT21 的 S(`http-nofw`)缺 LISTEN 前提就沒有鑑別力(m4)。
  - SD3 的 S(`ro-on-ctl`)靠 P 的 ok 門檻判,成立;`ro_served` 用不到(m11)。
- **P**:
  - UD8b(pre)的 P(FIFO、擁有者 471)成立,uid 切換的寫法見 m1;
  - UD8c 的 P 成立,空間問題見 m3 附註;
  - UD20 的 P(新 nonce、最後做、之後 brewrite)成立;
  - HT12、HT15、HT23 的 LISTEN P 成立。
- **G**:只出現在 UD12、UD16(H4-U8)✅(`grep '| G'` 只有這兩列)。
- **「—」**:ST17、ST22、BG4 都附了理由 ✅。
- **D-1…D-17** 對照表與第 7 輪相同,沒有變動 ✅。

---

## 5. 安全(逐個 actor,只寫 v8 新增或改變的)

| actor | 結論 |
|---|---|
| 被入侵的 provd | FIFO 競態現在有臂(UD8b-race)與 S;UD8c、UD20b 成立;UD20 負向要改成只剩 `args_hash` 一個拒絕條件,才真的測到「換掉擁有者簽的版本」(m9) |
| 被入侵的手機 | HTTP fake path 改看 04 的 FIN;前提是 relay 保持連線,並要有真 session 的正向對照(m8) |
| 被竄改的 Windows 橋 / 成員節點冒充 | 沒有變;計數器的 selftest 用詞見 m12 |
| 本機非 root(節點) | 沒有新入口。`upd-open-pause` / `upd-open-block` 只在 prov_test helper、經 root 0600 的 fault 檔啟用(§5.1),release 不受影響 |
| 我們自己的錯(root 的 kill) | `pg_kill` 對 pgid 只檢查 `isint`;要擋 pgid = 1 與自己的群組(m6) |
| 主機斷線 / 睡眠 | STOP → 等 → TERM + CONT 的順序正確;子 shell 的規則見 m5 |
| 供應鏈 / 我們自己的錯(沙箱) | pivot 寫法、mountinfo 白名單都與第 7 輪實測相符 ✅ |

**失敗模式**:12 條 MINOR 都是 fail-closed(假 FAIL / INVALID),或是某個佐證少了正向對照(m8)。m6 是唯一可能造成實害的一條(對 `-1` 送 TERM),但要先有記錄檔被寫壞或呼叫方式改變才會發生,而且修法只是多一個檢查,所以列 MINOR。

---

## 6. 判決

**APPROVE-WITH-CHANGES:0 BLOCKER / 0 MAJOR / 12 MINOR。**

**收斂了嗎**:收斂了。第 7 輪唯一的 MAJOR,我對照 P3 `:327 / :353 / :403 / :456` 確認已經解了;v8 新加的內容(UD8b 拆兩臂、STOP / TERM / CONT、LISTEN 前提、UD20 的路徑與順序、FIN 佐證、沙箱 pivot 與白名單、`ro_served`、uid 471)都沒有引入新的 BLOCKER / MAJOR。建議實作前一起改 m1–m4、m8、m9:這幾條會在第一次實跑或 P3 閘門上造成假 FAIL,或讓某一臂測不到它宣稱的防線。其餘可以在實作時順手改。下一輪(如果還要)只需要核對這 12 條。

**本輪的誠實界線**:
- ✅ 實跑:WSL busybox 1.36.1 的 `start-stop-daemon -S -x` 比對(§0-1)。
- ✅ 04 唯讀:busybox 版本、argv0 統計、ssh 指令的 pgid / sid 與 dropbear 主行程的 pgid(§0-2)。
- ✅ 原始碼:P3 `:147, :327, :347, :353, :358, :388, :401, :403, :456`;main 的 `node.go`、`server.go`、`session.go`、`ble-lib-254.sh`、`tmp-trust-280.sh`、`bt-uart-305.sh`、`prov-ac-forge-254.sh`(§0-3 到 §0-5)。
- ⚠️ `start-stop-daemon` 的比對行為是在 WSL 的 busybox 上實跑的,04 上沒有執行(依規則不做);兩邊版本號相同(1.36.1),但 build 設定可能不同。
- ⚠️ tmpfs 多一頁的推論(m3 附註)沒有實測。
- ❌ 沒做:任何改節點的實驗;沙箱沒有重跑(沿用第 7 輪的實驗)。
