# #254 PR-P2 `batman-provd` 設計 v3 — 對抗式審查 A(第 3 輪,整份重審)

審查者 A,2026-10-31。對象:`scratchpad/254-p2-impl.md` v3 全文 §0–§14。方法:從現場出發(認領、10 台一隊、路人、被攻陷的 provd、root 操作員),§13 / §14「已修」不採信,逐條對原始碼重核;重點 = v2 BLOCKER 的修法(多連線 helper)在 `sock.go` / `node.go` 上是否真的成立、新引入的並行面、generation 失效、nonce 對、錯誤碼、矩陣、安全。

**環境誠實界線**:04(10.41.1.3)ssh `Connection timed out`(1 次,ConnectTimeout 6 s;WSL 第一次呼叫還撞 0x8007274c)→ 本輪**沒有任何 04 實機輸出**;F-P1 / F-P4 / F-P5 / F-P23 等實機事實沿用 v1 兩位審查員核過的。我核的是原始碼:repo main `34f216d`(P1b 已合),`feed/batman-prov/src`、`tests/tools/provclient`、`docs/design/{219-protocol.md,219-protocol.cddl,254-wireless-txn.md,254-stage1-impl.md}`。

## 0. 我自己核過的事(✅ 原始碼;⚠️ 推論 / 沿用;❌ 沒驗到)

| # | 事實 | 證據 |
|---|---|---|
| V1 ✅ | `Serve` = `for { AcceptUnix(); s.serveConn(c, h) }` 同步;`serveConn` 先 `peerUID` 必須 == 471 否則關,再 `Read(30 s deadline) → h(m) → Write(30 s deadline)` 同步迴圈。改成 `go s.serveConn(...)` 是結構上可行的一行改動;cap 4 的計數要在 goroutine 內、PeerUID 拒絕的連線不能佔名額(實作點) | `sock.go:107-116, 136-170` |
| V2 ✅ | `Handle` 進門 `n.mu.Lock()`;`dispatch` 對非 stateChanging 動詞只做 `LoadOverlay`(無 `IsTrial` / `otaBusy` / `finishGated`)→ 「唯讀動詞不取鎖」只需 `Handle` 在 Lock **之前**分支;lock-free 路徑碰到的共享狀態只有 `n.KS`(唯讀複本)、`n.BootID`、`n.Log`、檔案 | `node.go:157-159, 183-212, 213-247` |
| V3 ✅ | `nonces` / `signLog` / `replayF` 只被取鎖動詞(`nonce`、`sign.*`、`claim.*`、owner-op)碰 → 多連線不新增 nonce map 競態 | `node.go:95-105, 213-262, 270-346, 570-590` |
| V4 ✅ | **helper 錯誤回應不帶 reason**:`Handle` 失敗回 `{1: id, 2: code, 3: {}}`,`err.Reason` 只進 log | `node.go:170-173` |
| V5 ✅ | `claim.verify` 回 6 的來源:`dispatch` 無 record(只有撕裂讀會發生,但 `claim.verify` 持鎖、寫者也全部持鎖 → 持鎖路徑永遠讀不到撕裂)、`no-ssh-key`(CheckMac 之後)→ 在持鎖動詞上 6 ⇒ no-ssh-key 可**推論** | `node.go:204-209, 534-540`;寫者:`commitTxn` / `boot.Run` / `BootFinish` / `resolve` 全在鎖內或 Listen 前 |
| V6 ✅ | `applyNet`:step 3 `commitTxn`(overlay gen+1、state=Member)之後還有 step 4 `SaveTxn`(≤ 300 s)→ 無鎖 `info.state` 在動詞結束前就看到新 generation;`psks.get` 取鎖 → 排在同一動詞後面 | `node.go:1131-1178`;`provstore.go:458` |
| V7 ✅ | generation 可以**往下**:`resolve` 以 p5 重寫 overlay(p5.gen > ov.gen 才寫,但 boot.go 多處寫 `Generation: 1` 新 record)→ 失效判定必須是 `!=` 不是 `>` | `wtxn.go:270-276`;`boot.go:145, 179-211` |
| V8 ✅ | nonce 對生命週期:`newNonce` 同 h ≤ 4 對、60 s;`takeNodeNonce` = 最新未用;`verifyOwnerOp` 以 map 順序逐對 `takeHelperNonce`(刪 entry、**不 break**,錯的那對刪了繼續試下一對);`claimReplay` 先 `takeNodeNonce` 再 `verifyOwnerOp`;替 10 失敗/h 計數 `replayF`(`ERate`)。設計 §4.3 的「begin → op/nonce(快取對)→ replay;回應後清對」與此一致;兩次 begin(P1, P2)後 op/nonce 回 P2.helper、replay 取 P2.node,也一致 | `node.go:270-332, 570-590, 612-619, 686-703` |
| V9 ✅ | `BootFinish` 在 `Listen` 之前取鎖、goroutine 內放;`boot.Run` 在它之前已寫 overlay → L1 / L70 的「ctl 不取鎖可讀」成立 | `main.go:579-623`;`wtxn.go:413-426` |
| V10 ✅ | `LoadOverlay` 讀 meta 再 record,SHA / state / gen 交叉驗;`WriteOverlay` record 先 meta 後 → 無鎖讀者可見撕裂(F-P25 ✅);重讀 ≤ 3 次合理 | `provstore.go:349-407` |
| V11 ✅ | `realSys.IsTrial()` 每次 fork `batman-slot is-trial`(`run` 60 s 逾時);health `Committed()` 也各自 fork 同一指令 | `main.go:80-87, 138, 598` |
| V12 ✅ | health `ReadInfo` 每次新開 mgmt socket、`SO_RCVTIMEO 2 s`、最多讀 8 事件;`Tick` 寫檔 + `poweredFor` → `health.get` 要用抽出的 `compute()`(設計已寫) | `health.go:55-87, 129-159` |
| V13 ✅ | `sign` 額度 = 每秒第 3 次才拒 → 連簽 2 次合法(F-P24 ✅) | `node.go:333-346` |
| V14 ✅ | `provclient` 在 `tests/tools/provclient/main.go`,`sock-as <uid>` 以 `Setuid` 降權再連;`PROVCLIENT_TIMEOUT_S` 預設 30 s;root 直接連會被 `peerUID` 拒(= F-P34 的 10 個單位都走 `sock-as 471`) | `provclient/main.go:355-370, 429-483`;`sock.go:138-141` |
| V15 ✅ | CDDL `error-detail`:1 capability(tstr)、2 reason-code(uint)、3 自由文字;協定 §5.2 reason 10 = legacy 無 SSH key、9 = reset | `219-protocol.cddl:114-122`;`219-protocol.md:182, 216, 220` |
| V16 ✅ | 協定 §8:交握 10 s、未認證閒置 30 s、已認證 300 s、同時 BLE 連線 2、未用 nonce_helper ≤ 4 / session | `219-protocol.md:370-385` |
| V17 ⚠️ | 改網動詞最壞 ≈ 960 s(F-P32)、假 msg2 711、RPA 900 s、autocommit 只 WARN:沿用 v1 / v2 審查員核過的,本輪未重算 | v2 B RB2-15 等 |
| V18 ❌ | 04 任何現況 | ssh timeout |

## 1. v2 BLOCKER / MAJOR 的實際修復狀態(逐項重驗,不看 §14)

| v2 發現 | v3 宣稱 | 我的核對 |
|---|---|---|
| A2-B1 / B2-B1 單連線序列化 | helper `Serve` 每連線 goroutine、cap 4;provd `ctl` + `ops` | ✅ **成立**:`Serve` 改 `go serveConn` 後每條連線獨立 `Read → h → Write`;`ctl` 上只有不取鎖動詞(V2:`dispatch` 對它們只 `LoadOverlay`),所以 `ops` 上的 `net.apply` 持 `n.mu` 時 `ctl` 的 `health.get` / `info.state` 真的不等鎖、不等連線。L70 / L71 / §4.4「最壞 ≈ 5 s + 往返」在這個模型下成立(但見 m7 的時間預算)。負對照(單連線 helper → 30 s)寫對 |
| A2-M1 / B2-M1 `provclient` 連不上 | 第 3、4 條留給 provclient;L78 | ✅ 成立(V1、V14);cap 4 的「殭屍」例外見 m4 |
| A2-M2 / B2-M2 快取失效 / 撕裂讀 | `Generation` 變 → 重拉;錯 = 暫態保留快取;helper 重讀 ≤ 3 | ⚠️ 方向對(V7、V10),但「重拉中舊快取是否繼續服務」沒寫 → **M2**;比較要寫成 `!=`(V7)→ m1 |
| A2-M3 / B2-M4 lock-free 動詞額度、`IsTrial` exec | 每連線 5/s 突發 20;trial 快取 ≤ 5 s | ✅ 契約對;快取的同步 / single-flight 沒寫 → m8 |
| A2-M4 nonce 對消耗後未清 | 回應後(任何碼)清;之後 op/nonce → `E_FORBIDDEN` | ✅ 與 `node.go:612-619, 686-703` 一致(V8);快取對的 60 s 到期沒跟 → m2 |
| B2-M3 HELPER_WAIT 關連線 | 到期不關、`E_BUSY` + detail 3、id 丟棄 | ✅ 契約對;ops 進行中的 keepalive 行為沒寫 → m3 |

## 2. BLOCKER

無。

## 3. MAJOR

**M1. §4.3 錯誤碼表引用的「helper reason 文字」在 socket 上不存在。**
- 情境:legacy 節點沒有 SSH key,操作員用 app 認領 → helper `claim.verify` 回 `EUnsupported`(`node.go:537-540`)→ 設計要 provd 回 `E_UNSUPPORTED{capability:"claim", reason:10}`,條件寫成「`EUnsupported` reason 含 `no-ssh-key`」;`21 / 22 → 11 E_REJECTED(error-detail{3: <helper reason 文字>})`。但 helper 的錯誤回應是 `{1: id, 2: code, 3: {}}`,`Reason` 只進 log(V4)。provd 拿不到任何文字 → 要嘛實作者發現後自己發明一個 helper 欄位(契約外),要嘛 reason 10 永遠不會被送出、app 顯示不出「這台沒 SSH key」(協定 §5.2 v0.7 明文要求 reason 10,`219-protocol.md:220`)。
- 證據:`node.go:170-173`;設計 §4.3 錯誤碼表、`claim/finish` 列;`219-protocol.cddl:119-121`。
- 修(二擇一,寫明):(a) **不改 helper**:在持鎖動詞上 6 只能是 `no-ssh-key`(V5:`dispatch` 的「無 record」6 在持鎖路徑讀不到撕裂、開機後 record 一定存在)→ 表改寫為「`claim.verify` 回 6 ⇒ reason 10(推論,附 V5 理由)」;21 / 22 → 11 **不帶** detail 3(或固定文字 `"helper rejected"`),log 由 helper 自己印。(b) helper 錯誤回應 key 3 加 `{1: reason tstr}`(秘密絕不進 reason — 現有 Reason 格式含 `%v` 錯誤文字,要先審一遍 `fail(...)` 的字串有沒有帶 key / 密碼;`node.go` 的 setkey / save 錯誤只帶 rc 與 lastLine)→ 列進 §2 helper 改動 + Go 單元。單元:fake helper 回 6 → provd 信封含 `{1:"claim", 2:10}`(mutant:拿掉推論 → 缺 2 → FAIL)。

**M2. generation 失效後的「重拉中」行為沒定義;§4.3 / L71 的「逾時一次」在 `network/update` 情境是錯的。**
- 情境 A(= L75,擁有者自己的 join):`net.apply` 在 step 3 commit 後 overlay 已是 gen+1 / Member,step 4 `SaveTxn` 還要 ≤ 300 s(V6)。`ctl` 5 s 內看到 generation 變 → 依 §4.3 要 `psks.get`(`ops`)重拉 → `psks.get` 取 `n.mu`(`node.go:252-256`)→ 排在這個 `net.apply` 後面(最壞 ≈ 960 s)。手機此時斷線重連(L75 本來就是這條)→ NXpsk0 交握需要 PSK 集合:若實作在「失效」時**清掉**快取 → 6 把全是隨機補的 → 假 msg2 → 擁有者被自己的 join 鎖在外面直到動詞結束(不是「一次」);若**保留舊集合**直到新集合到手 → `psk_owner` 不隨 join 變(`TagKey` 不變,`node.go:393-396`)→ 重連成功。設計兩種都沒寫。
- 情境 B(成員 `network/update`):`psk_member` 綁 `Net.Version`(`node.go:408-411`)。update commit 後版本 +1,成員 app 已拿新版本 → 用新 `psk_member` 交握;provd 舊集合只有舊版 → 全部成員手機在 `net.apply` 結束前(最壞 960 s)都走假路徑,**不是「逾時一次」**。這是 10 台一隊現場會發生的事(網主推 update → 隊員馬上重連看狀態)。
- 證據:V6;`node.go:393-411`;設計 §3 唯讀快取列(失效條件)、§4.3 快取段「可能逾時一次」、L71、L75。
- 修:§3 / §4.3 寫明 **「失效 = 標記待重拉,舊集合繼續服務到新集合成功回來」**(single-flight 已有);誠實界線改寫:「`net.apply` 進行中 generation 已變 → `psk_member` 新版本的交握要等該動詞結束(≤ 180 s 常態、最壞 ≈ 960 s,F-P32),`psk_owner` / `psk_replay` 不受影響」;L75 加斷言「join 送出後立刻斷線、重連以 `psk_owner` 交握成功(負對照:清快取 → 假 msg2)」;L71 的「新 NXpsk0 連線只逾時一次」刪掉。可選的真修(寫成殘項即可):`psks.get` 改為不取鎖(它只讀 record + `KS.ECDH`;608B 後要 keystore 自己的鎖,§10 已列)。

**M3. `prov-sec-adv-len-254` 臂 2 是會讓節點 panic 的破壞性動作,沒有前置閘。**
- 情境:harness 在 `-wbox` 上跑 `btmgmt add-adv -d <31 B> 1`。這正是 F-P10 讓 04 panic 的動作;唯一的差別是 kernel 有沒有 patch(§4.8,D3 **待決**、commit id ⚠️ 未查)。若 D3 延後、或 wbox image 是舊 pin、或 bcm2710 板的 patch 沒進(L13 ❌ 未測),這個單位 = 可重現的 kernel panic + 重開機,而且在全套中間、沒有歸因(F-P10 當時就是這樣丟了一段 logread)。使用者 2026-10-18 的規則:動節點狀態的測試先列副作用與前置。
- 證據:F-P10;設計 §4.8、§9「新單位 `prov-sec-adv-len-254`(臂 2 kernel patch 正向)」;D3 狀態「待決」。
- 修:臂 2 前置 = 在節點上證明 patch 在(例:`/proc/version` 的 build id 對應 pin、或 image 內 `/etc/batman-build` 加 `KPATCH_254_ADV=1` 由 firmware PR 寫入)→ 不在就 **SKIP 並 FAIL 單位**(「找不到可檢查的東西 = FAIL」規則),絕不執行 `add-adv`;副作用清單(panic → reboot → 遺失 logread)寫進單位 header;只在 `-wbox` 且 `BATMAN_PROV_TEST=1` 跑。

## 4. MINOR

**m1. generation 比較寫成 `!=`。** V7:`resolve` / `boot.Run` 會以 p5 或 `Generation: 1` 重寫 overlay,數字可往下;§3「變了」要明寫 `!=`,`cache_test` 加「gen 5 → 1」一例。

**m2. provd 快取的 nonce 對沒有到期。** helper 端 60 s(`node.go:296`);provd 回已過期的 `nonce_helper` → `claim/replay` 必敗、計入 helper `replayF` 10/h(`node.go:580-590`)與 provd 3 次 / 連線。provd 以 `nonce(h)` 回應時刻起 55 s 作廢該對,之後的 `op/nonce` 直接 `E_FORBIDDEN`(不計失敗)。

**m3. `ops` 進行中的 keepalive。** helper 在 `h(m)` 內不 `Read`;provd 若照「閒置 ≥ 20 s」送 `info.boot_id`,960 s 內會堆 ~48 則,動詞結束後 helper 一口氣處理 → 撞每連線 5/s 突發 20 → `ERate`。寫明:有請求在飛就不送 keepalive;keepalive 的 `ERate` 忽略。

**m4. 殭屍連線佔名額(矩陣缺列)。** provd 在長動詞進行中 restart / crash:舊 `ops` 的 goroutine 卡在 `h(m)`(或等 `n.mu`)直到動詞結束,連線 fd 已關但名額還在;每次 provd 重啟多留一個(新 provd 的 `sign.static` 排隊等鎖)。respawn 每 5 s + cap 4 → 兩次重啟後 `provclient` 或新 provd 的第 2 條被關。動詞結束就自然釋放。加 L 列(今天:單連線更糟;P2 後:≤ 960 s 內名額不足、之後恢復;測試:白箱 helper 持鎖期間 restart provd ×2 → `provclient` 被拒 → 鎖放開後 ≤ 5 s 成功);provd 連線被拒 → 退避重連(§4.5 已有退避,指明適用)。

**m5. L70「STATUS 可讀」只在 `gatt.sock`。** 期間不廣播(交握要 `node_cert`),BLE 上不可能有連線 → L70 的白箱只能 `SOCK_ONLY`;寫明,免得節點臂拿 BLE 去量。

**m6. 「不新鮮 > 60 s → 不廣播新連線」沒有對應的撤銷 reason。** §4.4 log 契約 `adv withdrawn reason=<health|connect|stop|bluetoothd>` 沒有 `stale`;§4.3 卻說不廣播。定一個(`reason=helper`)並進 `ble-rpa-254` / H3 的 log 解析。

**m7. ≤ 10 s 撤廣播的時間預算。** `health.get` = 兩個 mgmt 命令各 2 s 逾時(V12)+ `/proc` 掃描 + sc 檔;控制器卡住時一次 ≈ 4 s;5 s 輪詢 + 4 s + Unregister 往返 ≈ 9–10 s,剛好貼線。寫出預算,或兩個 mgmt 命令共用一個 socket / 逾時降 1 s。

**m8. helper 內 trial 快取與 `Committed()` 各自 fork。** `info.state` key 5 的 ≤ 5 s 快取由 lock-free goroutine 更新 → 要自己的 mutex / atomic + single-flight(兩條 ctl 類連線同時到期 → 2 個 fork);health `Committed()`(`main.go:598`)也 fork 同一指令,共用同一快取。

**m9. §8「攻陷的 provd 能做的」漏:** 對任何 BLE 對端回 `info.net`(`net_id`)與 `info.owners` → 跨節點串聯一隊(`node.go:238-240` 的註解正是為此只讓 provd 對擁有者轉送)。擋不住、寫明。

**m10. root 以 `provclient` 改 record 時 provd 既有 session 的行為。** 匿名 NX session 不斷(只有 provd 自己的認領成功才 Disconnect 其他);它們的 `claim/finish` 之後回 9。`owner.add` 後 ≤ 5 s 內的 `auth/owner` 用舊 owners → `E_FORBIDDEN` 且計入 3 次。兩句寫進 L78。

**m11. lock-free 動詞集合要列舉、不要寫 `info.*`。** `info.counter` 存在(`node.go:230`)但 provd 不用;寫明集合 = `{health.get, info.boot_id, info.cert, info.ecdh_pub, info.state, info.net, info.owners}`,其餘一律取鎖;並註明實作點:`Handle` 在 `n.mu.Lock()` 前分支(`node.go:158`)。

**m12. 壁鐘。** nonce 到期用 `Sys.Now()` = 壁鐘;Pi 無 RTC,開機後 NTP 跳步會讓 60 s 窗瞬間過期 / 延長。P1 既有、不是 P2 引入;寫進殘項(RTC 在戰術 tier)。

**m13. 04 未實查。** 本輪 F-P1 / F-P4 / F-P5 / F-P23 沿用;實作第一步仍要在 04 跑一次目錄 bind / `Acquire*`(設計 §12 已排)。

## 5. 擁有權 / 契約 / 矩陣補充(未列為 finding)

- §3 helper 連線列:加「名額計數在 goroutine 內、PeerUID 拒絕不佔名額、連線關閉即釋放(但 goroutine 仍在 `h(m)` 時名額未釋放,m4)」。
- §3 唯讀快取列:加「舊集合服務到新集合到手」(M2)與 `!=`(m1)。
- §4.3 錯誤碼表:加 ESchema 20 由 `sock.go:158` 以 id 0 回並關連線的情形 → provd 當自己的 bug(CRIT)、該連線上在飛的非冪等請求回 7。
- 矩陣:m4 的殭屍列;L75 加 M2 的斷言;L71 刪「一次」。

## 6. 安全(逐 actor,只寫有變動的)

- **路人**:無新面;msg1 長度檢查走假路徑、等長 711、同 DH 次數 — 沿用 v2 核過。
- **攻陷的 provd**:新面 = 4 條連線 + lock-free 動詞額度(✅ 寫了負測試 mutant);m9 的洩漏補進去;`health.get` 回的行不含秘密(boot_id provd 本來就讀得到)。
- **本機非 root**:socket 0660 root:provd,`peerUID` 強制 471(V1)→ 多連線不擴大;`provclient sock-as` 只有 root 能做(setuid)。
- **root 操作員**:`provclient` 與 provd 並存現在成立;m10 的兩個時序後果要知道。
- **我們自己**:M3(破壞性臂無閘)、M1(契約引用不存在的資料)。

## 7. 判定

**APPROVE-WITH-CHANGES** — 0 BLOCKER / 3 MAJOR / 13 MINOR。

v2 的地基問題真的修掉了:`Serve` 每連線 goroutine + `ctl` 只跑 `dispatch` 不做任何鎖內前置檢查的動詞(V1、V2),所以 `ctl` 的延遲承諾、`provclient` 並存、L70 / L71 的斷言都在原始碼上站得住;nonce 對的生命週期與 `node.go:270-332, 612-619, 686-703` 一致(V8);錯誤碼數字對(V4 除外);多連線沒有引入 nonce map / signLog 競態(V3)。要改的三件:M1 是契約引用了 socket 上不存在的 reason 文字(選 a 不改 helper 就是幾行字);M2 是快取「重拉中」的語意沒定,而且會讓擁有者 / 成員在改網動詞期間被鎖在外面、L71 / L75 的誠實界線寫錯;M3 是一個會重現 F-P10 panic 的 harness 臂沒有前置閘。三件都是文字 + 一條單元 / 前置,不需要再動模型;改完由第二位審查員對 §3 / §4.3 / L71 / L75 / §9 看一遍即可,不必再整份第 4 輪。
