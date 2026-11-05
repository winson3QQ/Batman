# H4 harness 設計 v8 — 審查 B(第 8 輪)

- 對象:`docs/design/254-h4-harness.md` v8(`harness/254-h4` @ 3b2aa32),整份審,重點在 v8 的改動(附錄 G)。
- 對照:P3 `254-p3-impl.md` v7.1(§3.1、§3.7.4–§3.8.2、§4、§5.1、§7、§8);main 2ecf1cb:`scripts/node/ble-lib-254.sh`、`feed/batman-prov/src/{provd/frame.go,provd/helper.go,node/node.go}`、`deploy/provisioning/halow-setkey`、`tests/tools/provclient/main.go`、`scripts/node/tmp-trust-280.sh`;219 §4.2。
- 節點:**沒有連 04 / 02**(本輪需要的事實都在原始碼與前幾輪的唯讀輸出裡)。
- WSL:一個非 root 的 pivot_root 實驗,全部在 `mktemp -d /tmp/h4v8b.XXXXXX` 底下,腳本放在 Windows scratchpad,以 `wsl --exec bash <script>` 執行;結束時刪除,最後一行是刪除後的 `cannot access`(§0-6)。
- 沒有改 repo,只寫這份報告。

**結論先講**:第 7 輪的 MAJOR(UD8b 到不了 worker)解了:UD8b 拆成 pre / race,race 用 `upd-open-pause` 讓 harness 能插進「prepare 檢查之後、worker 開檔之前」那個窗,`upd-open-block` 當 S,兩個名字都進了 §5.1(= 交給 P3 的接縫清單)。第 7 輪 B 的 9 條 MINOR 大多解了。整份重看,沒有新的 BLOCKER / MAJOR;有 9 條 MINOR,都是實作時會變成假 FAIL / 假 INVALID、或讓某個斷言弱掉的局部問題,其中 m1(UD20)與 m2(deadman 的 STOP/TERM/CONT 與既有 `pg_kill` 的配合)建議在凍結前一起改。

**判決:APPROVE-WITH-CHANGES(0 BLOCKER / 0 MAJOR / 9 MINOR)。已收斂。**

---

## 0. 證據(原始輸出節錄)

```
# (1) P3 v7.1 —— prepare / worker / status
:181  update/check | ops | owner-op:不要(擁有者角色)
:182  update/prepare | ops | 要;body 帶 sha256(SHA256SUMS)
:187  唯讀動詞不跑子程序:只讀 helper 記憶體裡的快取
:327  update.prepare:sha = pending key 4;上傳檔存在且大小 = key 3;啟動 worker,立刻回 phase 2 | 不符 → 15
:347  update.status(ro)只讀快取
:353  worker 1. 先以 O_RDONLY|O_NOFOLLOW|O_NONBLOCK 開上傳檔 … 之後才關上傳窗 … `updating` 從開檔起為真
:385  表不在 / 沒有 http.2 → 不 bind,已 bind 的關掉,≤ 8 s;這對備援與上傳窗都成立
:390-393  什麼時候聽:備援、上傳窗;都不是 → 不 bind
:456  上傳檔:helper 刪(… prepare 發現不符)
:469  所有 owner-op:缺 / 錯 → E_FORBIDDEN;:486 prepare sha 不符 → 15(沒有規定兩者的先後)
:492  HTTP NX / psk_replay:與 fake path 等長回應後關
:568  被入侵的 provd | 偷換 pending 版本 | prepare / apply body 帶 sha,由 owner-op 綁 | 負測試:Go

# (2) main —— owner-op 驗證(node.go:651-690)
args_hash 由 helper 從 body 算;對每個符合 h 的 nonce 都 takeHelperNonce;
不論是簽章不符、args_hash 不符、或 nonce 過期 / 不存在,都回同一個 fail(EForbidden, "owner-op signature / nonce")
node.go:259  nonces:一次性、60 s、綁 h、每個 h ≤ 4 個

# (3) main —— deadman(ble-lib-254.sh)
:53-59   lim:"$@" & → wait;watchdog 子 shell sleep 後 lim_kill
:127-134 pg_kill:kill -TERM -pg,然後輪詢 /proc/*/stat 的 pgid 最多 10 s,還在就 return 1   ← 沒有 CONT
:330-338 cmd_dm_fire:拿不到鎖 → kill_run_groups;lease 檢查後再 kill_run_groups → role_fire_restore
:357     kill_run_groups:對 $BT/<run>/*.pg 逐一 pg_kill
:359-365 bg_start:setsid … 9>&- &,pgid 寫成 $BT/<run>/<n>.pg

# (4) main —— halow-setkey(deploy/provisioning/halow-setkey)
:132-134 自己的鎖 = exec 9>"$RUNDIR/halow-setkey.lock" + flock -n 輪詢
整個檔案沒有 `trap`(grep "trap" 0 筆)→ 被 TERM 時不會 rollback

# (5) main —— framing(provd/frame.go:8-11)
flags(1) ‖ seq(2 BE) ‖ data;bit0 = start、bit1 = end   ← 橋不解 Noise 也能數「msg1 結束之後」的 frame ✔
# provclient(tests/tools/provclient/main.go:7-10, :429)
自己降到 uid/gid 471;cl.call("nonce", {1: h});owner 簽章經 stdin("SIG <hex>")讀回,同一條連線 ✔

# (6) WSL 非 root:在宿主 cwd 執行 pivot_root(v8 §8.2 的新順序)
[yes] host canary now: orig        ← 有 cd /:相對路徑寫不到宿主
[no]  host canary now: pwn         ← 沒有 cd /:寫到宿主(對照有鑑別力)
ls: cannot access '/tmp/h4v8b.c3Rmb2': No such file or directory   ← 實驗目錄已刪
(另有 "rmdir /old failed"、"/dev/null: No such file":是我的實驗 rootfs 沒有 /dev/null,
 2>/dev/null 的轉向失敗所以 rmdir 沒執行;與設計無關,設計有 bind /dev/null)
```

---

## 1. 第 7 輪意見的處理(對附錄 G 逐條核對)

| 意見 | 結果 |
|---|---|
| A-M1 / B-M1 UD8b 到不了 worker | ✅ pre 臂預期 15、FIFO 被刪(`:327`、`:456`);race 臂用 `upd-open-pause` 插進 prepare 與開檔之間,符合 `:353` 的順序;S = `upd-open-block`。兩個名字在 §5.1。S 的「症狀」寫錯、正向的時限沒寫(**m3**) |
| A-m1 §5.7 正常情況 | ✅ (i)(ii) 與 `:314-316`、`:330-338` 一致 |
| A-m2 / B-m2 等 setkey 時 host 沒被凍結 | ⚠️ 加了 SIGSTOP → 等 → TERM → CONT,host 的 pgid 不登記(符合 `:333`、`:338`)。但「TERM 之後補 CONT」若照既有 `pg_kill` 寫,CONT 會在 10 s 輪詢**之後**才送,一律落到「殺不掉」(**m2**)。B-m2 的第二半(單位以 `bg_start` 起的 setkey 被 `kill_run_groups` 先殺)沒有處理(**m9**) |
| A-m3 pg_kill 失敗的測試 | ✅ stub |
| A-m4 / B-m8 LISTEN 前提 | ⚠️ HT12、HT15、HT23 加了;HT14、HT19 同樣斷言「不聽」卻沒有加(**m4**) |
| A-m5 / B-m4 UD20 | ⚠️ 資料路徑、順序、§13 都寫了;但負向臂的預期碼仍取決於 P3 沒規定的檢查順序,而且沒有模擬真正的攻擊路徑(**m1**) |
| A-m6 uid 471 | ✅ busybox `start-stop-daemon -c` 可用(provclient 本身也會降到 471,`main.go:7`)。寫法建議見 m8 |
| A-m7 沙箱 cwd 對照 | ✅ 我實跑:在宿主 cwd 執行 pivot_root,有 `cd /` → 宿主不變;沒有 → 被改(§0-6) |
| A-m8 frame 計數負對照 | ⚠️ 加了,但負對照注入的是「假後端」送的 frame,不是 peer 送的(**m6**) |
| A-m9 fake path 額度 | ✅ |
| A-m10 ro 計數契約 | ⚠️ 定義了 `ro_served`,但 SD3 那一列沒有用到它(**m7**) |
| A-m11 undo log 不記秘密 | ✅ |
| B-m1 HTTP fake path 佐證 | ⚠️ 改看 server 的 FIN,方向對;要寫 relay 的連線方式與同臂的正向對照(**m5**) |
| B-m3 release 失敗的主流程 | ✅ §5.7 第 5 步 |
| B-m5 UD8c 長度 | ✅ Go `compress/gzip` 讀 FEXTRA / FCOMMENT;補一句「mutant 比原檔長時怎麼辦」(m8) |
| B-m6 mountinfo 白名單 | ✅ 與 v7-A 實跑的 6 筆一致 |
| B-m7 背景行程 `9>&-` | ✅ §4.5 |
| A-m12 / B-m9 文字 | ✅ 審查清單有 7;frame 計數定義在 msg1 之後,frame 有 end bit(`frame.go:8-11`),橋數得出來 |

---

## 2. BLOCKER

無。

## 3. MAJOR

無。

---

## 4. MINOR

### m1. UD20 的負向臂沒有模擬真正的攻擊,而且結果取決於 P3 沒規定的檢查順序;`E_FORBIDDEN` 也分不出是 args_hash 不符還是 nonce 出錯

**情境**:v8 的 UD20 = pending 是 X、owner-op 簽 X、body 的 sha 換成 Y → 預期 `E_FORBIDDEN`。

**證據**:
- 這個請求同時違反兩條:owner-op 不符(`:469`,`E_FORBIDDEN`)與 sha ≠ pending(`:486`,15)。v8 自己在 UD20 列寫了「P3 沒規定 helper 先驗 owner-op 還是先比 sha」,但預期仍只寫 `E_FORBIDDEN`。若 P3 先比 sha → 正確的 P3 回 15 → 假 FAIL;最順手的「修法」是改成接受 15,那樣這一臂就只測到 sha 比對,沒測到 owner-op 的綁定(UD20b 已經測 sha 比對)。
- 真正的攻擊路徑(P3 `:568`「偷換 pending 版本」):`update.check` **不需要 owner-op**(`:181`),被入侵的 provd 可以自己送 `update.check {manifest Y}`(Y 是另一個合法簽章的版本)把 pending 換成 Y,也可以自己把上傳檔寫成 Y;擁有者的 owner-op 是對 X 簽的。這時「sha = pending」**會通過**,唯一擋住的就是 owner-op 的 `args_hash` 綁定。v8 沒有這一臂。
- `verifyOwnerOp`(`node.go:651-690`)對簽章不符、args_hash 不符、nonce 過期 / 不存在都回同一個訊息。負向臂若因資料路徑出錯(nonce 60 s 過期、h 不符)而 `E_FORBIDDEN`,也會 PASS;v8 的 P(另一次、新 nonce、對 X 簽)證明不了「負向那一次」的 nonce 是有效的。

**為什麼是 MINOR**:P3 `:568` 把這一條的負測試指定為 Go 單元測試,產品的防線另有 Go 測試證明;H4 的這一臂是補充的實機臂。

**修法**:改成單一變數的 flip:
1. provclient(uid 471)送 `update.check {manifest Y}` → pending = Y(P:`update.status` / pending 檔的 key 4 = Y);上傳 Y。
2. 正向:WSL 對 **Y** 簽 owner-op、body = Y → worker 啟動(phase 2)。
3. 負向:**同樣的流程、同樣的時序**,WSL 對 **X** 簽、body = Y → `E_FORBIDDEN`、沒有 worker、上傳檔的處理符合 `:456`。兩次只差被簽的 sha。
4. UD20b 保留(owner-op 對 Y、pending X → 15)。
5. 每一次 nonce 取得到送出要 < 60 s(`node.go:259`),在 provclient 的同一條連線裡完成(`main.go:10` 已經是 stdin 簽章通道)。

### m2. deadman 的「SIGSTOP → 等 → TERM → CONT」:若沿用既有 `pg_kill`,CONT 會晚到,一律落到「殺不掉 → NEEDS-PERSON」

**證據**:`pg_kill`(`ble-lib-254.sh:127-134`)送 TERM 之後就在同一個函式裡輪詢最多 10 s,還有成員就 return 1。對已停住的行程,TERM 會被擱著,直到收到 CONT。v8 寫「`TERM` 整個群組,接著補送 `CONT`」,又寫「`pg_kill` 殺不掉 → 只做段 1」。如果實作是 `pg_kill; kill -CONT`,停住的 shell 在那 10 s 內一定還活著 → 永遠 NEEDS-PERSON、段 2 不做。這是 fail-closed,`test-h4-undo.sh` 的「host 卡住」臂會抓到,所以是 MINOR,但最好在設計裡寫死。

另外兩個細節:
- 「等它正在跑的 setkey / config-save 結束」要等的是 runner 的**直接子行程**(那個 `( lim … ) 9>&-` 子 shell),不是只看工具的 pid:子 shell 不會被 SIGSTOP 停住,若同一個動作裡還有下一條指令,它會繼續執行。
- 子 shell 結束後會變成 zombie(父 shell 停著不會 reap);用 `/proc/*/stat` 的 pgid 判斷存活時(`pg_kill` 的做法),zombie 會被算成「還活著」,直到 CONT 讓父 shell 收到 TERM 結束為止。

**修法**:§5.7 寫明新函式 `pg_kill_stopped <pgid>`:`kill -TERM -pg; kill -CONT -pg`,**然後**才輪詢;等待條件 = runner 的直接子行程都已結束(狀態為 Z 或不存在),上限 = 該動作的 `lim` 預算。`test-h4-lib.sh` 加一臂:對一個 SIGSTOP 中的 shell 群組呼叫 → 10 s 內清空;負對照:先 TERM 輪詢、後 CONT → 判定為殺不掉。

### m3. UD8b-race:S 的症狀寫錯;「沒有卡住」的判定沒有鑑別力;正向缺時限

**證據**:`update.status` 是 ro,只讀快取(`:187`、`:347`)。worker 卡在 `open()` 時,`update.status` 仍會立刻回 phase 2,不會逾時。所以:
- S 欄「`update.status` 逾時」不是 mutant 的實際行為;
- 「下一個 `update.status` ≤ 5 s 回應、helper pid 不變」在正確與 mutant 上都成立。

S 仍然有鑑別力的唯一原因,是正向斷言「phase 0 + 11」——但列內沒有寫時限。

**修法**:正向 = 放 FIFO 之後、暫停結束起 ≤ 10 s 內 `update.status` = phase 0 + `3: 11`;FIFO 已被刪(`:353`、步驟 6);B **不是** BAD(還沒到 `begin_write`);之後 `settings.set`(同值)不是 `E_BUSY`(`updating` 已清)。S 的症狀改成「≥ 30 s 仍是 phase 2、同值 `settings.set` 回 `E_BUSY`」;還原 = 段 1 刪 fault + helper 重啟。

### m4. HT14、HT19 也斷言「不聽」,但沒有 T 窗與 LISTEN 前提(第 7 輪 A-m4 / B-m8 只改了三列)

**證據**:8095 只在備援或上傳窗時聽(`:390-393`)。HT14(`firewall stop` → ≤ 8 s 不聽)與 HT19(D-3 → 不聽)的載具是 RB,沒有開窗。沒開窗的話,「不聽」無條件成立,S(`http-nofw`)也一樣不聽 → S 臂在 P3 PR 上會顯示「mutant 下沒有 FAIL」。這會在 P3 閘門被發現,不會假 PASS 出貨,所以是 MINOR。

**修法**:HT14、HT19 改成 RB(T 窗)+「誘發前 8095 LISTEN」的 P。HT14 的窗口要涵蓋 ≤ 60 s 的無防火牆時間。HT18 / HT21 若是看 `http.2`(不是看 LISTEN),寫明 harness 從哪裡讀到 `http.2`。

### m5. HTTP fake path 的 FIN 佐證:要寫 relay 的連線方式與同臂正向對照;第二個 `/msg` 的預期沒有定義

**證據**:P3 `:388` 有 `IdleTimeout 30 s`,也就是真的 session 由 server 保持連線。但 relay 若每個請求都帶 `Connection: close`(或每次新開連線再由 client 關),server 在**每一個**回應之後都會送 FIN,「04 主動送 FIN」就沒有鑑別力。「對同一個 session 再送一次 `/msg` → 連線已關」:FIN 之後只能開新連線;P3 / 219 §4.2 沒有定義「未知 session 的 `/msg`」回什麼。

**修法**:§4.3 的 relay 寫明:HTTP/1.1 持久連線、不送 `Connection: close`、`/session` 與後續 `/msg` 走同一條 TCP。同一臂內的正向:先做一次已認證的 HTTP 交握 → 回應後 N s 內沒有 server FIN;負向 → 回應後 ≤ 1 s 有 server FIN。第二個 `/msg` 只當記錄,或請 P3 定義它的回應後再斷言。

### m6. frame 計數器的負對照注入錯了一邊

**證據**:§4.2 (a) 的計數是「msg1 之後、**由 peer 送出**的 frame 數」,但 selftest 的負對照寫「**假後端**在 msg2 之後送出一個 frame → 計數 = 1」。後端(節點那一側)送的 frame 不是 peer 送的,正確的計數器在這個注入下仍是 0,負對照不會 FAIL;反而是「把兩個方向都算進去」的錯誤計數器會讓它通過。

**修法**:負對照改成「selftest 的 peer 端在 msg2 之後寫出一個 frame → 計數 = 1 → 斷言 FAIL」;另加「後端在 msg2 之後送一個 frame → 計數仍是 0」,證明只算 peer 方向。

### m7. `ro_served` 定義了,但 SD3 那一列沒有用它;讀它的那一次算不算也沒有定義

**證據**:§4.2 說 `ro_served` 只留給 SD3;附錄 A 的 SD3 斷言是「沒有 `cfgsave-lock.busy`、沒有 ERate、廣播在」,S 是 `ro-on-ctl`,P 是 ok / E_RATE 的數量,沒有 `ro_served`。`ro-on-ctl` 讓 app 的讀取改走 ctl,上面那幾個斷言不一定會因此失敗;最直接的鑑別是 `ro_served` 沒有增加。

**修法**:SD3 的斷言加「Δ`ro_served` ≥ peer 計到的 ok 數」;寫明 harness 怎麼讀 `info.state`(provclient 直連 helper 時走哪一種連線),以及讀取本身算不算進去(建議:讀取走的連線不算,或在前後各讀一次再扣掉 1)。

### m8. 文字與小處

- §1.4-2 寫「Go fault 17 個」,§5.1 現在是 19 個(加了 `upd-open-pause`、`upd-open-block`)。另外 `upd-open-block` 是會讓 worker 卡住的削弱型 fault,P3 第一個 commit 的 `/security-review` 清單要點名它只在 prov_test build。
- §2 的「以 uid 471」:repo 裡已驗過的寫法是 `start-stop-daemon -S -c <user> -n <唯一名字> -a /bin/sh -- -c '…'`(`tmp-trust-280.sh:19`、`bt-uart-305.sh:36`),並以 `id -u` 斷言真的切過去(`tmp-trust-280.sh:56`)。建議照抄,並在 E-H15 斷言 `id -u` = 471。
- UD8c:改過的 `root.squashfs` 壓縮後可能比原檔**長**,這時 FEXTRA / FCOMMENT 補不回來。寫明先讓 mutant 變短(例如把一個資料區塊清零,壓縮後必然變短),再補到同長。
- 附錄 G 的 A-m2 / B-m2 一列只寫了 host 執行器,沒有寫 B-m2 的第二半(見 m9)。

### m9. 單位以 `bg_start` 起的 setkey / config-save 會在 undo 之前被 `kill_run_groups` TERM 掉,而 setkey 沒有 TERM trap

**證據**:`cmd_dm_fire` 在 `role_fire_restore` 之前對 `$BT/<run>/*.pg` 執行 `kill_run_groups`(`:333`、`:338`、`:357`)。`halow-setkey` 整份沒有 `trap`(§0-4),被 TERM 時停在哪就是哪(可能在 uci commit 與 wifi reload 之間)。段 2 的 `ap-restore` / `uci-revert` 之後會重做,所以結果通常可以恢復,但這是靠運氣,不是設計寫明的契約。

**修法**:§5.7 寫明規則「`halow-setkey`、`batman-config-save` 一律不經 `bg_start` 起(不登記 `.pg`)」,並加一條 lint;或者規定這類臂一定登記 `ap-restore` / `uci-revert`,而且 undo 的段 2 會在它們之後跑。

---

## 5. 附錄 A 逐列核對(對 P3 §6 / §7 / §8 / D-1…D-17,W / S / P / G)

- **§8 片語**:「上傳檔換成 FIFO」→ UD8b(pre:大小檢查)+ UD8b-race(`O_NONBLOCK` / regular,S 有鑑別力,判定見 m3)✔。「上傳後改 payload」→ UD8c ✔(長度見 m8)。HTTP 的 v5 / v6 規則負對照 → HT1 的 S、HT10 / PR1 ✔。
- **§6**:沒有因 v8 改變;「helper 重啟時 setkey 還在跑」→ ST12、「上傳中 helper 重啟」→ UP8、「firewall reload」→ HT13 ✔。
- **§7**:「偷換 pending 版本」→ UD20 / UD20b(P3 指定 Go;H4 的實機臂見 m1)。「佔 RAM」→ UP5、「搶建 bulk 路徑」→ UP11、「lo / VLAN 佔槽」→ HT9 / HT10 / HT11 ✔。
- **D-1…D-17**:附錄 A 的 D 對照表與各列一致 ✔。
- **W**:都 FAIL 在第一個 P3 動詞或已知行為差異上;UD8b-race 沒寫 W,但 S 比 W 強 ✔。
- **S**:§5.1 / §5.2 / §5.4 的名字與附錄 A 一一對得上(包括新的兩個)。HT14、HT19 的 S 在沒開窗時沒有鑑別力(m4)。
- **P**:HT12 / HT15 / HT23 的 LISTEN ✔;SD3 缺 `ro_served`(m7)。
- **G**:只有 UD12、UD16 ✔。
- **「—」**:ST17、ST22、BG4 有理由 ✔。

## 6. 安全(只寫 v8 新增或改變的)

| actor | 結論 |
|---|---|
| 被入侵的 provd | FIFO 競態現在測得到(UD8b-race)✔;「偷換 pending」的實機臂沒有走 owner-less `update.check` 這條真路徑(m1;產品防線另有 Go 測試) |
| 被入侵的手機 | HTTP fake path 的節點端佐證改看 server FIN,方向正確;要排除 relay 自己造成的 FIN(m5) |
| 被竄改的 Windows 橋 / 成員節點 | 認目標的 frame 計數可以靠 frame 的 end bit 算(`frame.go:8-11`)✔;負對照注入方向要改(m6) |
| 本機非 root(節點) | 沒有新的入口;`upd-open-*` 只在 prov_test build(m8 請 security review 點名) |
| 主機斷線 / 卡住 | STOP / TERM / CONT 的順序要與 `pg_kill` 配合(m2);`release` 失敗的主流程 ✔ |
| 供應鏈 / 我們自己的錯(沙箱) | 在宿主 cwd 執行 pivot_root 的 cwd 對照有鑑別力(我實跑,§0-6);mountinfo 白名單 ✔ |
| 我們自己的錯(鎖 / 背景行程) | `9>&-` 擴大到背景行程 ✔;`bg_start` 起的 setkey 被先殺(m9) |

**失敗模式**:9 條 MINOR 都是 fail-closed(假 FAIL、INVALID、NEEDS-PERSON),或是在 P3 閘門上會被 S 臂發現的鑑別力不足;沒有會讓不安全的 rc 假 PASS 出貨的路徑。

## 7. 判決

**APPROVE-WITH-CHANGES:0 BLOCKER / 0 MAJOR / 9 MINOR。**

**收斂了嗎**:收斂了。第 7 輪唯一的 MAJOR(UD8b)已解,我對過 P3 `:327 / :353 / :456`,新的兩個接縫放在 §5.1,也就是 P3 第一個 commit 要實作的清單。v8 的其他改動(deadman 凍結 host、LISTEN 前提、UD20 資料路徑、HTTP FIN、`ro_served`、frame 計數、沙箱 pivot、mountinfo、`start-stop-daemon`)方向都對,剩下的都是局部文字或判定細節。建議 m1、m2、m3、m4 在凍結前一起改(它們會影響第一次實跑的判讀);其餘可在實作時處理。不需要再一輪完整審查;若要確認,只核對 m1–m4 即可。

**本輪的誠實界線**:
- ✅ 原始碼核對:P3 `:181-190, :327, :347, :353-359, :385-403, :456, :469-492, :568`;main `ble-lib-254.sh:53-59, 96-155, 295-365`、`node.go:259, 651-690`、`frame.go:8-11`、`helper.go:70`、`halow-setkey`(沒有 trap)、`provclient/main.go:7-10, 429`、`tmp-trust-280.sh:19, 56`;219 §4.2。
- ✅ WSL 實跑:在宿主 cwd 執行 pivot_root 的 cwd 對照(§0-6),實驗目錄已刪。
- ⚠️ 推論、沒有實跑:SIGSTOP 中的群組收到 TERM 的行為(依 Linux 訊號語意,不是在 04 的 busybox 上實測);busybox `start-stop-daemon -x` 的比對方式(依 repo 既有用法推論,沒有在 04 上執行);Go `compress/gzip` 對 FEXTRA / FCOMMENT 的支援(依標準庫行為,沒有用 P3 的 worker 實跑)。
- ❌ 沒做:任何連到 04 / 02 的動作(本輪不需要,也依規則不做改節點的實驗)。
