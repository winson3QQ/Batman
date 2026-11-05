# H4 harness 設計 v6 — 審查 B(第 6 輪)

**審查對象**:`docs/design/254-h4-harness.md` v6(`harness/254-h4` @ 1181c75),整份。
**對照**:P3 `254-p3-impl.md` v7.1;main 2ecf1cb 原始碼(`scripts/node/ble-lib-254.sh`、`scripts/node/prov-lease-254.sh`、`scripts/dv/prov-254.sh`、`feed/batman-prov/src/provd/{session,server,noise}.go`、`cmd/batman-provd/bluez.go`、`node/{wtxn,node}.go`、`cose/cose.go`);04 唯讀。
**方法**:先逐條核對附錄 E(v5 意見),再從實際流程走整份,重點放在 v6 新寫的 undo 執行器、peer 端分類與 fake path 佐證、UD20。節點上只做一次唯讀讀取(ssh 指令自己的 `/proc/$$/stat` 與 dropbear 行程的 pgid)。**這一輪沒有重跑 WSL 沙箱實驗**(v5-B 已做過;v6 的修法照我上一輪建議的寫,但本輪 ⚠️ 未實跑)。沒有改 repo(本報告除外)。

**結論先講**:**0 BLOCKER / 0 MAJOR / 8 MINOR → APPROVE-WITH-CHANGES**。v5 的兩條 MAJOR 都解了。v6 新寫的機制裡有幾個地方跟程式碼的實際時序或狀態對不上,但失敗方向都是「測試 FAIL / INVALID」或可用性,不是假 PASS、不是暴露,所以列 MINOR。

---

## 0. 證據(原始輸出節錄)

```
# 04 唯讀:ssh 指令的行程群組
self=31461
31461 31460 31460 31460          # pid ppid pgid sid:指令的 pgid = 該連線的 dropbear 子行程
31460 (dropbear) S 3193 31460 31460
3193 (dropbear) S 1 1 1          # 監聽的 dropbear 主行程 pgid 不同 → 殺指令的 pgid 不會殺掉 sshd
# harness 不用 ControlMaster(grep 0 筆)→ 每條 ssh 各自一個 pgid

# ble-lib-254.sh
:97-101  lock(): exec 9>>$BT/lock;flock -n 重試
:306-311 cmd_arm(= renew):lock 30 + lease_valid_for,否則 die
:313     held():同上
:314-323 cmd_release:lock 30 → lease_valid_for 不成立就 die "lease is not ours or expired"
:327-342 cmd_dm_fire:sleep → 20×lock 30 → 拿不到:dm_log + kill_run_groups,不拿鎖照做
         → lease 是本 run、已過期、dm 記錄是我 → kill_run_groups → role_fire_restore → provd_start → rm lease
:345-355 cmd_recover:role_fire_restore recover;RUN_ID=recover gc_rundirs
:295-304 gc_rundirs:刪掉沒有 lease、沒有活 deadman 的 $BT/<run>/
:127-134 pg_kill:TERM 整個群組,最多等 10 s,沒走完 return 1
:53-59   lim:"$@" & + 看門狗子 shell
# prov-254.sh:50  q(){ timeout "${QT:-120}" ssh ... }   ← 主機端預設 120 s

# provd
session.go:232-235 onMessage 回錯 → ss.logLimited("provd: session ended: %v")(errKill 除外)
session.go:252     logLimited 的 key 一律是 "session"
session.go:298-300 fake → errors.New("message on the fake path")
session.go:337     "provd: disconnect after the response"  ← 同一個 "session" key
session.go:388-390 "global handshake rate (20/min)"        ← 同一個 key
session.go:279     recv == nil(含 fake)→ 從連線起 HandshakeMax = 10 s(server.go:28)就結束
server.go:126-144  logLimited:每 key 每分鐘 10 行
server.go:639      "session revoked reason=%s" 用 logf,不限流 ✅
bluez.go:599/614   "adv registered/withdrawn reason=%s" 用 logf ✅
server.go:768      logLimited("conn", "provd: connection %s")

# net_secrets
wtxn.go:126-142  target = SHA-256(DACPub) 比對;other = net_id ‖ u32be(ver);cose.Decrypt(enc, LabelSecrets, dacHash, other, ECDH)
cose.go:193      KDF ctx = [24, [nil,nil,nil], [partyV,nil,nil], [256, rprot, other]]
cose.go:201      aad = ["Encrypt", prot, label]
node.go:916      net_secrets 由 VerifySign1(CTSecrets, LabelSecrets, admins) 驗;admins = net_config key 8(node.go:1020-1046)

# owner-op(UD20 依賴)
node.go:668-670  args_hash 算不出 → EForbidden
node.go:672-690  對每個未過期 nonce:takeHelperNonce(h, nonce) 一律消耗,簽章不符 → EForbidden "owner-op signature / nonce"
P3 :327 / :486   prepare 的 sha 不符 pending → E_REJECTED{2: 15}
```

## 1. 附錄 E(v5 意見)逐條核對

| v5 意見 | v6 處理 | 核對 |
|---|---|---|
| A-M1 provd log 不存在 / 限流 | peer 分類 + 多送一個訊息觸發 fake path 行 + helper 計數 | ✅ 機制對:`session.go:298-300` 的行確實會出現,key = "session"。殘留見 m4(訊息與時窗)、m3(helper 計數在 wsl.22 上不存在) |
| B-M1 undo 重疊 | 一次一個執行器;卡住就殺 pgid;每個動作 `lim`;`9>&-` | ✅ 主幹解了。pgid 實查 = ssh 連線的 dropbear 子行程,不會殺到監聽的 dropbear(§0)。殘留見 m1(「host 正常」那一臂的預期跟 `cmd_release` 對不上)、m2(殺不掉時的規則) |
| B-M2 沙箱 cwd / fd | `cd /`、關 fd ≥ 3、`env -i`、bind `/dev/*`、兩條附對照的負測試、只看 canary 內容 | ✅ 文字完整,對照的設計有鑑別力。⚠️ 本輪沒重跑 |
| netobj KDF / AAD | PartyV = target、AAD = 標籤、`other` = net_id ‖ ver | ✅ 對上 `cose.go:193, 201`。小補:寫明 `other` 是放在 SuppPubInfo 的第 3 欄、net_secrets 的簽者要在 net_config key 8(m8) |
| `renew` / `undo` 子命令 | §5.7 | ✅ `prov-lease-254.sh:86` |
| `fresh-spent` 初值 | §4.4 | ✅ |
| E-H13 前置 / `shutdown.reason` | §8.1 | ✅ |
| `rs` 參照、P3 上先設 key 2 | §4.1 | ✅ |
| static key 舊說法 | §1.1、§12、§15、§17 | ✅ 全改了 |
| HTTP / sock 也驗 `node_cert` | §4.2 | ✅ |
| SCAN 過濾 UUID | §4.2 | ✅(⚠️ bleak WinRT 的過濾方式未實查;橋自己看廣播的 service UUID 也行) |
| UD8c 改成合法 tar.gz | A.9 | ✅ 有鑑別力 |
| P3 §7 偷換 pending | UD20 | ⚠️ 加了,但 P 對照會被 nonce 消耗擋下,見 m5 |
| p6 綁定語意 | §5.7 | ✅ overlay→槽、p5 不綁、只有 tmpfs 類綁 boot_id |
| P9 只讀 | §5.7、§9 | ✅ |
| EXIT trap 時 lease 已過期 / `ble-recover` | §5.7 | ⚠️ 前者 ✅;recover 要掃哪些 run 沒寫,見 m6 |
| `phy9h4` 殘留 | HT23 | ✅ 沒有 `http-nofw` 下直接證明,S 對照成立 |
| `s0_assert` 02 carrier | §3.1 第 6 項 | ✅ |
| VLAN filter、loop 驗收非 root | §4.5、§8.1 | ✅ |

## 2. BLOCKER

無。

## 3. MAJOR

無。

## 4. MINOR

- **m1 「host 正常的一臂」的預期跟 `cmd_release` 對不上**(§5.7 測試第 3 條)。臂寫的是「host 拿著鎖時 lease 到期 → dm-fire 在等鎖 → host 做完 `release` → dead-man 沒有執行任何動作」。但 lease 一過期,`cmd_release` 就因 `lease_valid_for` 不成立而 die(`ble-lib-254.sh:316`)。dm-fire 拿到鎖之後,看到 lease 是本 run、已過期、記錄是自己 → 照樣跑 `role_fire_restore`(段 2 全部 `done` 跳過),接著 `provd_start`、`radio_restore`、啟動服務、刪 lease。這是無害的,但照寫的預期,這一臂一定 FAIL,而且主機會把 release 失敗當錯誤。**修法**:預期改成「dm-fire 執行、段 2 每一項都因 `done` 跳過(journal 每項只有一次 `done`)、`release` 回 "lease is not ours or expired",主機看到 dv-undo log 已完成就當作正常」。另寫明:預算內做完才是「dead-man 不動作」的情況,那一條另做一臂(lease 未過期 → `release` 成功 → dm 群組被取消)。
- **m2 「同一時間只有一個執行器」靠 `pg_kill` 成功**。`pg_kill` 最多等 10 s,沒走完 return 1(`:127-134`);卡在 D 狀態(sync、卡住的掛載)的行程收不到 TERM。§5.7 沒寫殺不掉時怎麼辦;照字面,deadman 會接著做段 2,那就是兩個寫者。**修法**:`pg_kill` 失敗 → 只做段 1、記 NEEDS-PERSON、段 2 不做;`test-h4-undo.sh` 加一臂(用 SIGSTOP 不夠,因為 TERM 對 stopped 行程會在 CONT 後送達;可以用一個忽略 TERM 的測試動作模擬)。
- **m3 認目標負對照的「helper 請求計數」在 wsl.22 上不存在**。§4.2 負對照 (a)(b) 的佐證是 §1.4-2 的 P3 新計數,但這兩臂要在 §15-2 / §15-4 的 pre-P3 預演就跑(wsl.22 的 `info.state` 沒有這個欄位,`node/readonly.go:121`)。照規則會一律 INVALID,預演就判不了。**修法**:pre-P3 的佐證改成 (i) blebridge 自己記的「msg2 之後送出的 frame 數 = 0」(橋是獨立的行程,可當見證),(ii) 02 的 `provd: connection ble`(`server.go:768`,conn key)證明 (b) 真的連到 02;P3 rc 上再加 helper 計數。
- **m4 fake path 佐證的細節**:
  - 多送的必須是一個**完整的訊息**(reassembly 完成才會進 `onMessage`,`session.go:208-214`),不是任意一個 frame;
  - 要在連線後 10 s(`HandshakeMax`)內送,否則 session 先因逾時結束、不寫 log(`:279`);
  - "session" 這個 key 還有 `disconnect after the response`、`global handshake rate`、AEAD failure 共用(`:337`、`:388-390`)。同一分鐘內其他臂的這些行會吃掉額度。「每分鐘最多 5 次」的估算要改成「該分鐘內 session key 的總行數 < 10」,超過就 INVALID(不是 FAIL)。
- **m5 UD20 的 P 對照會被 nonce 消耗擋下**。`verifyOwnerOp` 對每個符合 h 的 nonce 一律 `takeHelperNonce`,不論簽章對不對(`node.go:672-690`)。負向那一次(sha 換成 Y)已經把 nonce 用掉,「同一個 owner-op 搭配原 sha X → 成功」一定回 `E_FORBIDDEN`,P 會假 FAIL。**修法**:P 用一個**新的** owner-op(新 nonce),對 X 簽,證明「sha X 的請求是被接受的」;負向那一臂另外斷言 helper 沒有啟動 worker(`update.status` 仍 phase 1 / 沒有 `updating`)。另外寫明預期碼:owner-op 不符 → `E_FORBIDDEN`(`node.go:690`);owner-op 對、但 sha ≠ pending → `E_REJECTED{15}`(P3 `:327`)。兩種都應該各有一臂,因為 P3 §7 的「偷換」可以是兩種形式之一。
- **m6 tmpfs journal 的位置與 `ble-recover` 的範圍沒寫**。`cmd_release` 會 `rm -rf $BT/$RUN_ID`,`gc_rundirs`(每次 `acquire`、`recover`)會刪掉沒有 lease 的 run 目錄(`:295-304`)。如果 tmpfs journal 放在 `$BT/<run>/`,deadman 沒做完的項目會在下一次 `acquire` 時連同證據一起被刪,P9 看不到。**修法**:tmpfs journal 放在 `$BT/<run>/` 以外(例如 `$H/dv-undo/<run>/`),或讓 `gc_rundirs` 跳過有未 `done` 項目的目錄;`undo_run <run> recover` 寫明掃描所有 run 的 tmpfs 與 p6 journal。
- **m7 主機端 ssh 逾時與 undo 的輸出**:`q()` 預設 `timeout 120`(`prov-254.sh:50`),host 模式的 undo 預算是 20 分。照現在的 helper 呼叫,主機 120 s 就砍掉 ssh,undo 靠 `trap '' HUP PIPE` 會繼續跑,但主機會以為失敗並可能去跑別的步驟。寫明 host 模式以 `QT=<預算+60>` 呼叫,或改成「啟動後輪詢 dv-undo log」。另外 log 檔要寫明三種模式都寫(dm-fire 的 stdout 是 /dev/null,`:146`)。
- **m8 文字**:
  - §4.1 netobj:`other` 放在 KDF context 的 SuppPubInfo(`[256, rprot, other]`),寫明;net_secrets 的 Sign1 簽者必須在 net_config 的 admins(key 8)裡(`node.go:916, 1038`);
  - §5.7 的 `9>&-`:在 ash 裡對函式呼叫做 `9>&-`,父 shell 會把 fd 9 另存成高號碼的 CLOEXEC fd,fork 出來不 exec 的子 shell(`lim` 的看門狗、以 shell 函式實作的動作)仍然握著鎖。它們都在同一個 pgid,殺 pgid 會一起收掉,所以結論不變;建議寫一句,避免實作的人以為 `9>&-` 本身就足夠;
  - §5.7 寫明 `undo_run` 是 `role_fire_restore` 的**第一步**(在既有的 unbind-all 之前),殺掉卡住的 host 之後才動任何東西。

## 5. 附錄 A 逐列核對摘要

- **§8 每個片語**:逐段對過,v6 沒有刪列;新增 UD20 對上 P3 §7「偷換 pending 版本」(`:568`),HT23 對上 §3.8.1 `phy*` 前提。
- **§6、§7**:每一列都對得到;§7 那一列的 G 改成黑箱 W + P(H4-U8 不需要擴大)。
- **D-1…D-17**:D 對照表正確。
- **G**:只有 UD12、UD16。
- **「—」**:ST17、ST22、BG4 都附了理由。
- **OW3**:改用 `session revoked reason=`(`server.go:639`,logf)與 `adv registered reason=disconnect`(`bluez.go:599`,logf),兩行都不受限流 ✅。

## 6. 安全(逐 actor,只寫 v6 新增或改變的)

- **遠端 / mesh 上任何人、AP 上其他 client**:沒有新入口。
- **本機非 root(節點)**:`undo-doing.<run>` 在 `$BT`(root 0700)底下;deadman 殺 pgid 之前驗 cmdline + boot_id,pid 重用打不進來。pgid 實查是 dropbear 連線子行程,不會殺到監聽的 sshd(§0),遠端存取不會因此斷掉。
- **被入侵的 provd**:UD20 的方向對;對照的寫法見 m5。
- **被入侵的手機**:HTTP 也驗 DAC,relay 轉向別台會被放掉 ✅。
- **成員節點(持有 `psk_member`)**:DAC 釘選擋下冒充 ✅。
- **供應鏈 / 我們自己的錯**:沙箱修法完整(⚠️ 本輪沒重跑);undo 的兩個寫者只剩 m2 那個角落。
- **失敗模式**:本輪的 MINOR 全部是 fail-closed(FAIL / INVALID / NEEDS-PERSON),沒有假 PASS。

## 7. 判決

**APPROVE-WITH-CHANGES**(0 BLOCKER / 0 MAJOR / 8 MINOR)。

**收斂狀態**:已收斂。v5 兩條 MAJOR 經原始碼與 04 唯讀核對確實解了。剩下的 MINOR 都是局部文字或個別臂的預期值修正(m1、m5 會讓測試在第一次跑時假 FAIL,實作前要改),不需要再一輪全面審查;建議修完後由作者自己對照本報告逐條勾掉,在 §15-3 的 `test-h4-undo.sh` 第一次實跑時驗證 m1、m2。

**本輪的誠實界線**:
- ✅ 驗過:ble-lib / prov-lease 逐行、provd log 行與 key、netobj 對 cose.go、owner-op nonce 行為、04 的 ssh pgid(§0 原始輸出)。
- ⚠️ 沒有實跑:沙箱逃脫負測試(沿用 v5-B 的實驗)、bleak WinRT 的 UUID 過濾。
- ❌ 沒做:任何改節點的實驗(依規則不做)。
