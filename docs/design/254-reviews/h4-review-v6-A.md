# H4 harness 設計 v6 — 審查 A(第 6 輪)

- 對象:`docs/design/254-h4-harness.md` v6(`harness/254-h4` @ 1181c75),整份審。
- 上層對照:P3 `254-p3-impl.md` v7.1;h23 v14;`219-protocol.md` v0.7 + `.cddl`。程式:`/home/yello/Batman` main 2ecf1cb。
- 節點:只對 04 做一次唯讀 ssh(印出 ssh 指令自己的 pid / pgid / 父行程)。WSL:非 root 沙箱實驗,在 `mktemp -d` 裡做,做完已刪(輸出最後一行 `No such file or directory` 是刪除後的確認)。沒有改 repo,只寫這份報告。

**結論先講**:第 5 輪的三條 MAJOR(A-M1、B-M1、B-M2)的**主體**都解了:我對過 `session.go:234/305`、`server.go:126-144/639`、`bluez.go:772-781`、`ble-lib-254.sh:314-340`,也重跑了沙箱實驗,cwd 與 fd 兩條對照確實有鑑別力。不過 v6 新寫進去的判定依據,有兩處和實際程式或實際行為對不上,會讓檢查**假 PASS**:
- 認目標負對照的「helper 請求計數」,在 S0-pre(wsl.22)上不存在,在 P3 也還沒定義;
- 沙箱的逃脫負測試,偵測不到「舊根沒有卸掉」。

另外有幾處判定會**假 FAIL**(UD20 的 P、§5.7 的 host 正常臂、UD8c),列為 MINOR。

**判決:APPROVE-WITH-CHANGES(0 BLOCKER / 2 MAJOR / 10 MINOR)**。已收斂:兩條 MAJOR 都是局部修改(換判定依據、多一條負測試),不需要新機制。

---

## 0. 證據(原始輸出節錄)

```
# (1) fake path 佐證 —— provd/session.go, server.go, frame.go
session.go:300-306  onMessage: if fake { return errors.New("message on the fake path") }
session.go:232-235  onMessage 回錯 → ss.logLimited("provd: session ended: %v", err)   (errKill 除外)
session.go:252      Session.logLimited → srv.logLimited("session", …)    ← 所有 "session ended: …" 與
session.go:337        "disconnect after the response" 共用同一個 key "session"
server.go:126-144   logLimited:每個 key 每分鐘 10 行
session.go:199-212  ReadFrame / Reassembler.Push 出錯 → in <- {err} → return(不寫 log)
frame.go:29-52      Push:len<3、flag 非法、非 start 卻沒有 active、seq 不對 → ErrFrame(靜默)
server.go:28        HandshakeMax = 10 s;session.go:268-270 recv==nil(含 fake)時從連線起 10 s 到期 → 靜默結束
P3 :492             HTTP 交握 NX / psk_replay → 「連線關閉(與 fake path 等長回應後關)」

# (2) OW3
server.go:638-641   reconcile:for … s.logf("provd: session revoked reason=%s")   ← logf,不限流 ✔
bluez.go:772-781    nlinks>0 || Sessions()>0 → withdraw("connect"), reason="disconnect";!advOn → register(reason)
P3 §3.8.1 :375      HTTP 池 2 槽;撤 BLE 廣播只看 BLE 的 link / session

# (3) helper 計數
grep 計數/counter P3 v7.1:沒有「helper 請求計數」或「ro 計數」;只有 H4 §1.4-2 向 P3 要
P3 F65 :117         helper 4 條連線的 SO_PEERCRED 都是 uid 471,分不出 ctl / ops / provclient
session.go:66-69    wsl.22:status、settings/get 等都在 p3Types → provd 直接回 E_UNSUPPORTED,不碰 helper
session.go:633-634  wsl.22:info 由 provd 自己回(擁有者 / 成員多一個 ctl info.net)

# (4) lease / dead-man —— scripts/node/ble-lib-254.sh
:314-316  cmd_release: lock 30 → lease_valid_for || die "lease is not ours or expired"   ← lease 過期就取消不了 dead-man
:327-330  cmd_dm_fire: sleep "$2"(= lease 秒數 + 5)→ 之後才開始等鎖,最多 20×lock 30
:334      lease 未過期 → exit;已過期 → kill_run_groups → role_fire_restore
→ 「dm-fire 在等鎖」只會發生在 lease 已過期之後;這時 host 的 release 一定 die

# (5) 04 唯讀:ssh 指令的行程群組
self=15033
15033 15032 15032 15032          # pid ppid pgrp session
15032 (dropbear) 3193 15032 15032 # 每條連線的 dropbear 子行程 = 群組長
3193 (dropbear) 1 1 1             # 主 dropbear
→ undo 執行器的 pgid = 該條 ssh 連線的 dropbear 子行程

# (6) owner-op —— node/node.go
:652-692  verifyOwnerOp:args_hash = SHA-256(body 去掉 key 31);每個符合 h 的 nonce_helper 試一次
:672      "try every unexpired one issued for this h (each attempt consumes)"
:310-319  takeHelperNonce:v.helperUsed = true; delete(n.nonces, k)   ← 驗章失敗一樣消耗

# (7) WSL 非 root 沙箱(6.6.114.1-microsoft-standard-WSL2;static busybox 當新根)
#    env -i → unshare --user --map-root-user --mount --pid --fork --net --uts --ipc
#    → bind R → cd R → bind /dev/{null,zero,urandom} → pivot_root . old → [cd /] → umount -l /old → mount proc
== docd=1 closefd=1: canary=orig cwd=orig fd=orig        # v6 的做法:三條都擋住
== docd=0 closefd=1: canary=orig cwd=pwn-cwd fd=orig     # 對照:沒有 cd / → cwd 逃脫 ✔(有鑑別力)
== docd=1 closefd=0: canary=orig cwd=orig fd=pwn-fd      # 對照:沒有關 fd → fd 逃脫 ✔(有鑑別力)
-- without umount:
== docd=1 closefd=1: canary=pwn-old cwd=orig fd=orig     # 舊根沒卸:寫 /old$H/canary 成功
   sh: can't create /tmp/…/host/canary: nonexistent directory   # ← 同時,v6 的「絕對路徑」負測試照樣 PASS
# 第一次執行時,pivot_root 之後用的是宿主的 umount(PATH 指到 /usr/bin),回 "umount: command not found",
# 舊根就這樣靜默留在 /old —— 這是實作時很容易犯的錯
/dev 內:crw-rw-rw- 65534 65534 1,3 null …                      # bind 的裝置檔可用,不再建出一般檔 ✔
fd: l-wx------ 2 -> /tmp/…/host/stdout.log                     # fd 0–2 不關;寫 /proc/self/fd/1 會截斷宿主上的 log
```

---

## 1. 第 5 輪意見的處理(對附錄 E 逐條核對)

| 意見 | 結果 |
|---|---|
| A-M1 provd log 不存在 / 被限流 | ✅ 主體解了:`session ended: message on the fake path` 確實在 fake session 再收到一則**完整的訊息**之後出現(`session.go:300-306` → `:234`);`session revoked` 不限流(`server.go:639`);`adv registered reason=disconnect` 存在(`bluez.go:776-781`)。殘留:限流 key 是共用的、「一個 frame」要寫清楚、HTTP 走不同的路(m4);請求計數在 pre-P3 不存在(**M1**) |
| B-M1 undo 重疊時序 | ✅ 主體解了:deadman 走「拿不到鎖」那一支時,殺掉卡住的 host 執行器、做完兩段,符合 `cmd_dm_fire` 的實際時序。殘留:「host 正常」那一臂的預期與 `cmd_release` 矛盾(m1);殺 pgid 的範圍與時機(m6) |
| B-M2 沙箱 cwd / fd | ✅ 實測:`cd /`、關 fd ≥ 3 都有效,兩條對照有鑑別力(§0-7)。新洞:舊根沒卸掉偵測不到(**M2**);fd 0–2(m7) |
| A-m1 / B-m netobj | ✅ |
| A-m2 子命令 | ✅ `renew`、新 `undo`、最後 `release` |
| A-m3 重疊時的寫者 | ✅(同一時間一個執行器) |
| A-m4 `fresh-spent` 初值 | ✅ |
| A-m5 / B-m14 E-H13 前置 | ✅ |
| A-m6 沙箱 sanity 列 | ✅ |
| A-m7 `rs` | ✅ |
| A-m8 P3 上重建 S0 | ✅ |
| B-m3 HTTP / sock 驗 DAC | ✅ |
| B-m4 SCAN 過濾 UUID | ✅ |
| B-m5 UD8c | ⚠️ 方向對,但缺「長度相同」的條件(m3);UD8b 的子項沒有處理(m10) |
| B-m6 偷換 pending 版本 | ⚠️ 新增 UD20,但 P 對照照原文做不出來(m2) |
| B-m7 p6 綁定 | ✅ |
| B-m8 文字 / 擁有權 | ⚠️ §9 已改;§1.2 的檔名仍是 `prov-undo-254.sh`,與 §5.7 的 `prov-undo-lib-254.sh` 不一致(m9) |
| B-m9 EXIT trap 時 lease 已過期 | ✅ |
| B-m10 `ble-recover` | ⚠️ 只寫「與 deadman 相同」,沒寫要處理哪些 run(m9) |
| B-m11 `phy9h4` 殘留 | ✅ HT23 有 P3 §3.8.1 的依據;與 §4.5 的文字矛盾(m8) |
| B-m12 02 拔線 | ✅ |
| B-m13 VLAN filter / loop 驗收 | ✅ |

---

## 2. BLOCKER

無。

---

## 3. MAJOR

### M1. 認目標負對照 (a)、(b) 的節點端佐證「helper 請求計數」:在它被安排執行的載具(S0-pre = wsl.22)上不存在,P3 也還沒定義;結果只剩 peer 自己的紀錄

**情境**:§4.2 的負對照 (a)、(b) 寫的是「在 S0-pre 上」,佐證是「兩台 helper 的請求計數(§1.4-2 的 ro 計數,在 `info.state`)」。§15-4 的 F 預演、現場的 S0-pre 建立,都在 wsl.22 上跑。之後的 claim 與 `network/join` 會改 02 / 04 的狀態,而這些動作都依賴認目標。

**證據**(§0-3)
1. P3 v7.1 沒有任何「helper 請求計數 / ro 計數」。這是 H4 §1.4-2 才向 P3 提的要求,而且只有一句「`info.state` 的一個欄位」:沒寫數哪些動詞,也沒寫 helper 重啟時會歸零。
2. P3 F65:helper 從 SO_PEERCRED 分不出 ctl / ro / ops / provclient,所以「ro 計數」只能依**動詞類別**來數。這時要求「認證後送的第一個請求」必須是 ro 類動詞,但設計沒寫。
3. wsl.22 上,`status`、`settings/get` 在 `p3Types` 裡,provd 直接回 `E_UNSUPPORTED`,根本到不了 helper(`session.go:66-69`)。`info` 由 provd 自己回(`:633-634`)。所以在 S0-pre 上,任何請求都不會讓 helper 的任何計數變動,即使那個計數存在也一樣。

**後果**:照字面實作,(a)、(b) 在 S0-pre 上的佐證永遠等不到,只能 INVALID;否則實作者只好退回只看 peer 自己的 transcript。後者正是 v5-A M1 指出的自我證明:peer 若有「不符的連線上仍送出請求」的 bug,它自己的紀錄也可能一起錯,負對照就會假 PASS。這是 v4 BLOCKER 修法唯一的實機證明,而且現場就要靠它去改兩台的狀態。

**修法**(換判定依據,不加新機制):
- **pre-P3(S0-pre、F 預演)**:
  - (b) 被接受的那一台:認證後送 `info`,斷言回應的 key 1(device_id)= 庫裡 04 的 device_id。這個回應在 Noise session 裡,由節點自己簽出來,可以當節點端證據。
  - 被放掉的那一台:以該台 provd log 的 `adv withdrawn reason=connect` / `adv registered reason=disconnect` 時間戳,證明確實連上過。
  - (a):兩台都只有 withdrawn / registered 這一對,peer transcript 沒有送出任何 envelope;另外跑一次 selftest 的對照:故意關掉 DAC 比對 → 會送出 `info` → FAIL。
- **P3 之後**:要用 helper 計數,就在 §1.4-2 把它寫成契約:欄位名、計哪些動詞(例如 `settings.get` / `status.get` / `diag.*` / `update.status`)、單調遞增、helper 重啟歸零 → 該臂 INVALID。並寫明認證後要送的動詞是 `status`。
- §6.2 / 附錄 A:identify 兩臂分別標出 W 載具與 P3 載具各用哪一種佐證。

### M2. 沙箱的逃脫負測試偵測不到「舊根沒有卸掉」;實測這條路可以寫宿主,而 v6 的「絕對路徑」負測試照樣 PASS

**情境**:`eeprom-sbx-254.sh` 在 `pivot_root` 之後執行 `umount -l` 舊根。pivot 之後,宿主的 `/usr/bin/umount` 已經不在原本的路徑上,用 PATH 去找會回 `command not found`。我第一次實驗就是這樣:舊根靜默留在 `/old`(§0-7)。`umount -l` 之前如果有 `|| true`、`2>/dev/null`,或者在 `set -e` 外面執行,結果也一樣。

**證據**(§0-7):舊根留著時,沙箱內寫 `/old$H/canary` 會成功(宿主 canary = `pwn-old`)。同一次執行裡,v6 的負測試「寫宿主 `$HOME/.batman-dv/sbx-canary` → 路徑在新根裡不存在」照樣成立,所以判 PASS。cwd 與 fd 兩條也照樣 PASS。也就是說,在沙箱實際上已經能寫到宿主時,§8.2 那五條負測試全部會 PASS,這正是 v5-B M2 指出的同一類問題(負測試沒有鑑別力)。資產同樣是 `~/.batman-dv/bench` 與 `~/.ssh` 的 lab key,actor 是供應鏈 / 我們自己的錯(uci-defaults 在沙箱裡是 userns root)。

**修法**:
1. 寫明 `umount -l /old` 用新根裡的 binary(`/bin/busybox umount`)執行,失敗就整個單位 FAIL。之後 `rmdir /old`,要求 `/old` 不存在。
2. 加一條負測試(附對照):沙箱內讀 `/proc/self/mountinfo`,斷言掛載點**正好**是 `/`、`/tmp`、`/proc`、`/dev/{null,zero,urandom}`,沒有別的;再試寫 `/old$HOME/.batman-dv/sbx-canary`,宿主 canary 不變。**對照**:拿掉 `umount -l` 的沙箱 → canary 被改(我的實驗就是這個對照)。mountinfo 這一條同時也涵蓋其他沒卸乾淨的掛載。

---

## 4. MINOR

1. **§5.7「host 正常的一臂」的預期與程式矛盾(假 FAIL)**:這一臂寫「host 拿著鎖時 lease 到期 → dm-fire 在等鎖 → host 做完 `release` → dead-man 沒有執行任何動作」。但 `cmd_dm_fire` 要等 sleep 完(= lease 到期)才開始等鎖(`ble-lib-254.sh:327-330`),而 `cmd_release` 在 lease 過期時會直接 die、取消不了 dead-man(`:314-316`)。所以只要 dm-fire 在等鎖,dead-man 就一定會接著跑。正文那句「host 做完會 release,dead-man 被取消,根本不會執行」也只在 lease 還有效時成立。修法:分成兩臂:
   - (i) lease 有效時 host 做完 → `release` 取消 dead-man → dm-fire 不動作;
   - (ii) lease 在 host 執行中過期 → host 做完、`release` 失敗 → dm-fire 拿到鎖 → `undo_run deadman` 全部跳過(都已 `done`)→ 斷言每一項只執行一次。主機看到 `release` 失敗時,改讀 `dv-undo-<run>.log`(與 EXIT trap 那條路相同)。
2. **UD20 的 P 對照照原文做不出來(假 FAIL)**:owner-op 綁的是 `h`、nonce_helper、`args_hash`,而 helper 驗章時,**每一次嘗試都會消耗**那個 h 的 nonce,失敗也一樣(`node.go:672`、`:310-319`)。所以先送 Y 被拒之後,「同一個 owner-op 搭配原 sha X → 成功」一定是 `E_FORBIDDEN`。修法:P 用另一次 `op/nonce`,以及對 X 新簽的 owner-op。另外寫清楚資料怎麼傳:擁有者的 peer 經 provd 取得 nonce(provd 以這條 session 的 h 向 helper 申請)→ peer 輸出 h 與簽好的 owner-op → 節點上的 provclient 以 `{1: h, 2: raw}` 送 `update.prepare`。這一臂不能讓 peer 經 provd 送出,否則 nonce 會先被用掉。
3. **UD8c 的換檔必須同長度、保留 magic(否則假 FAIL)**:worker 第 1 步就要求 fstat 的大小 = key 3(P3 §3.7.5-1)。重新壓縮的 tar.gz 幾乎一定長度不同,會在 prepare / 開檔時就被拒(reason 15 或 11),那時還沒有 `begin_write`,所以 B **不會**是 BAD。這樣「B 被 invalidate」的斷言就會假 FAIL,也測不到讀回那道防線。修法:mutant 用 gzip stored(level 0)或其他同長度的建法,確保總長度 = key 3、每個 tar header 大小都不變;`root.squashfs` 保留 `hsqs`(串流路徑只檢查 magic,§1.4-7)。P 加上「長度相同」;斷言加「失敗發生在讀回比對」(helper / batman-slot 的 log)。
4. **fake path 佐證的細節**:
   - 限流的 key `session` 是所有 `session ended: …`(AEAD failure、限速、claim failures 的 `disconnect after the response`)共用的(`session.go:252`、`:337`)。「每分鐘 5 次」要改成「送之前,先數這台最近 60 s 所有 `provd: session ended` 與 `disconnect after` 行,加起來 < 9 才送」。RT1 矩陣的格子會產生這類行。
   - 「再送一個 frame」要寫成:一則**完整**的單 frame 訊息(flags `0x03`、seq 0、≥ 1 byte),而且在連線後 10 s 內送(`HandshakeMax`)。否則 `Reassembler` 會回 ErrFrame,或是逾時,兩種都**不寫 log**(`frame.go:29-52`、`session.go:268-270`)。
   - HTTP 的 NX / psk_replay(HT7、RT1h 被拒的格子):P3 `:492` 寫的是「等長回應後關閉」,所以 extra frame 送不出去,也就等不到這一行。HTTP 的負向臂改用 §4.3 的佐證(AP iface 上手機的 SYN + named counter),在 §4.2 註明。
5. **OW3 的傳輸與時序要寫明**:Windows 同一個 adapter 對同一台裝置只能有一條 BLE 連線,所以 Hx 佔了 BLE 之後,H0 執行 remove 只能走 HTTP。P3 的 HTTP 池是 2 槽(`:375`):Hx HTTP + H0 HTTP 就滿了,這一臂裡其他 HTTP 連線(例如同路徑的正向對照)會被拒 → INVALID。另外,`adv registered reason=disconnect` 要等**所有** BLE link / session 都斷了才會出現(`bluez.go:772-781`),要寫明這一行的時間戳必須在兩行 `session revoked` 之後,而且 ≤ 5 s。
6. **deadman 殺 host 執行器的範圍與失敗**:
   - 執行器的 pgid 是那條 ssh 連線的 dropbear 子行程(§0-5),所以 TERM 那個 pgid 也會打到 dropbear。後果不嚴重,但「驗 cmdline」驗的只是 pid。建議 `undo` 一開始先 `setsid` re-exec 自己,讓 pgid 只屬於執行器,並記錄這個 pgid。
   - 殺掉群組時,正在跑的 `halow-setkey`(`ap-restore`)或 `batman-config-save --save`(`p5-save`)會在寫到一半時收到 TERM。要附證據說明這兩個工具在 TERM 下會回到一致的狀態;不然就讓它們在自己的群組裡跑,deadman 只殺執行器、等它們跑完(各自有 `lim`)。
   - `pg_kill` 在 10 s 內殺不掉(D 狀態)時要怎麼做,沒有寫。這時應該**不做段 2**,記 NEEDS-PERSON,否則又回到兩個寫者。
7. **沙箱的 fd 0–2**:fd 0–2 沒有關。實測沙箱內寫 `/proc/self/fd/1` 會截斷宿主上的 log 檔(§0-7)。如果判定或 log 是從那個檔讀的,受測的程式就能改寫它。改成 stdout / stderr 都接 pipe,由沙箱外的父行程寫 log。
8. **HT23 的文字**:
   - §4.5 寫「`phy9h4` 只准在 `http-nofw` 時存在」,但 HT23 刻意在**沒有** `http-nofw` 時建立它,兩處互相矛盾。把 §4.5 改成「除了 HT23 之外」。
   - HT23 斷言「`status` 回報」:P3 §3.8.1 對 `phy*` 前提的例外只寫了不給 `http.2`;「`status` 回報」是 D-13 對「AP iface 不是 port」的規定。要嘛把這一點寫進 §1.4 給 P3 的契約,要嘛從 HT23 的斷言拿掉。
9. **編輯**:
   - §1.2 的 `prov-undo-254.sh`,改成 §5.7 的 `prov-undo-lib-254.sh`(v5-B m8 殘留);
   - `undo_run <run> recover` 要寫明:掃描所有 `undo-doing.*`,以及 tmpfs 與 p6 裡所有 run 的 journal(v5-B m10 殘留);
   - F-H48 的行號:`cmd_release` 在 `:314`,`dm-fire` 在 `:327-340`。
10. **UD8b**(v5-B m5 的子項,附錄 E 沒有處理):
    - FIFO 改由 uid 471 建立,情境才是被入侵的 provd;
    - 「helper 沒卡住」的判定,改成「≤ N s 內出現 reason 11,而且 `updating` 已清掉」。`update.status` 只讀快取,用它分辨不出 worker 卡住。

---

## 5. 附錄 A 逐列核對(只寫有變動或有問題的)

- **W**:`--pre-p3-full` 規則與 F-H23 成立。identify 的實機負對照在 W 載具上的佐證見 M1。
- **S**:§5.1 / §5.4 的名字與附錄 A 一一對得上。HT23 的 S(`http-nofw` → 照樣給 `http.2`)有鑑別力(P3 §3.8.1 的前提檢查正是 `http-nofw` 關掉的那一段)。
- **P**:
  - UD20 的 P 做不出來(m2);
  - UD8c 的 P 缺長度條件(m3);
  - OW3 的 P(remove 前兩條都能用)成立,但時序見 m5。
- **G**:只出現在 UD12、UD16(H4-U8)✔。
- **「—」**:ST17、ST22、BG4 都附了理由 ✔。
- **依 fake path 佐證的列**:OW3、OW5 / OW6 的重交握、RT1 被拒的格子,在 BLE 上成立(附 m4 的細節);HT7 / RT1h(HTTP)要改用 tcpdump + counter(m4)。

---

## 6. 安全(逐個 actor,只寫 v6 新增或改變的)

| actor | 結論 |
|---|---|
| 供應鏈 / 我們自己的錯(沙箱裡的 uci-defaults) | cwd / fd 已擋住(實測);舊根沒卸 → **M2**;fd 0–2 → m7 |
| 被竄改的 Windows 橋 / 成員節點冒充 | node_cert + DAC 釘選成立;pre-P3 的負對照佐證 → **M1** |
| 被入侵的 provd | UD20 的負向本體成立(`args_hash` 綁定:`node.go:668-690`);P 見 m2;UD8b / UD8c 見 m10 / m3 |
| 本機非 root 行程(節點) | undo 的 journal 參數驗證、fault 檔信任邊界不變;`undo-doing` 在 `$BT`(root 0700)✔ |
| 主機斷線 / 睡眠 | `trap '' HUP PIPE` + log 檔 ✔;deadman 殺 pgid 時,子工具寫到一半 → m6 |
| 被入侵的手機 | HTTP 負向佐證 = tcpdump + counter,沒有變;OW3 的 HTTP 槽 → m5 |

**秘密**:沒有新的洩漏面。`undo` 的 log 寫在 `/opt/batdata/log/dv-undo-<run>.log`,要寫明不記 C0(`ap-restore` 只記 sha);同 §4.1 的規則,拷回主機前先在節點上以原值 grep 一次。

---

## 7. 判決

**APPROVE-WITH-CHANGES:0 BLOCKER / 2 MAJOR / 10 MINOR。**

- **M1**:認目標負對照的「helper 請求計數」在 S0-pre(wsl.22)不存在,P3 也沒有定義(F65:helper 分不出連線;wsl.22 的 P3 動詞到不了 helper)。只剩 peer 自己的紀錄,可能假 PASS。修法:pre-P3 改用 Noise 內的 `info` device_id 與兩台的 adv withdrawn / registered;P3 的計數寫成 §1.4 的契約。
- **M2**:沙箱負測試偵測不到「舊根沒卸掉」。實測舊根留著時可以寫宿主,而 v6 的五條負測試全部 PASS。修法:用新根的 umount、`rmdir /old`,加一條 mountinfo 加 `/old` canary 的負測試,附「不卸舊根」的對照。

**收斂了嗎**:收斂了。第 5 輪的三條 MAJOR 主體都解了,我都對過原始碼或實跑過。v6 的兩條 MAJOR 都是「新寫的判定依據沒有對著程式或實際行為驗證」,修法只要換判定依據、加一條負測試,不需要新機制,骨架也不需要動。MINOR 1–3 會造成假 FAIL,建議與 MAJOR 一起改,免得實作時才發現。下一輪仍要審整份,預期範圍很小。
