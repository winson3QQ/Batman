# 254-app-replay — 把 claim REPLAY 接進 app(v5.1:v5 兩位審查皆 APPROVE;v5.1 = 最終審查的 4 項實作時修正,§16)

對應:#254;凍結設計 `254-app-s1.md` §5.1 / §5.2 / §5.3、`254-app-claim-noover.md` v2.1。v2 被兩位審查者 REJECT → v3 整份重寫;
v3 兩位皆 APPROVE-WITH-CHANGES(0 BLOCKER;A 2 MAJOR、B 4 MAJOR)→ v4;v4 兩位皆 APPROVE-WITH-CHANGES(A 1 MAJOR + 5 MINOR、
B 7 MINOR)→ v5 只收這些意見。對照表在 §13 / §14 / §15。行號 = `feat/254-app-replay` @ eb9d07b(程式碼與 main f0138bd 相同)。節點路徑省略前綴 `feed/batman-prov/src/`,
app 路徑省略 `app/`。標記:✅ = 本版作者讀過該行;⚠️ = 推論或未驗證;❌ = 沒做。**本文件只有設計,沒有改任何程式、沒有碰手機或節點。**

## 0. 重現與現況

**真機重現(#254 留言「2026-11-14 真機重現」)**:04(bench `1.5.14-wsl.29`)+ S20 dev app(main f0138bd)。app 送出 claim/finish
後約 4 秒被 `am force-stop`。結果:節點 STATUS `state=claimed`、lab ssh key 已被拿掉(`Permission denied (publickey)`);手機「我的節點」
沒有這台、只留 pending。main 沒有 replay → 手機救不回。04 現在仍停在這個狀態 = 本功能的真機驗收與負對照(§10)。

**節點(✅ 全部讀碼)**

| # | 事實 | 位置 |
|---|---|---|
| N1 | 已認領節點握手試 6 把 PSK,只收 48 B 的 msg1(e ‖ tag);未認領節點是 NX,只收 32 B → 48 B 的 msg1 得**假 msg2** | provd/noise.go:18-21, 62-63, 73-87, 89-97 |
| N2 | 假 msg2 長度 = 32 + 48 + cert + 16(與真的相同);之後該連線只等 10 s 握手逾時 | provd/noise.go:111-125;provd/server.go:29 |
| N3 | psk_replay 只在**恰好一位擁有者**時存在;握手用的 state 與 PSK 集合是快取:state 在下一次輪詢更新(PollEvery 4 s + CtlWait 10 s),PSK 在 ops 空閒時重拉;PSK 集合在 provd 啟動後第一次拉到之後**只會被換掉、不會變回 nil**(作廢只設 needPSK)→ 剛認領完的節點有一小段時間對 psk_replay 回**解不開的 msg2**(假的),不是「沒有 msg2」(例外:provd 剛啟動、還沒拉過 → not ready) | node/node.go:438;provd/server.go:21-22, 454-487, 502-510, 618-622, 710-719 |
| N4 | 角色表:RoleReacquire = {info, claim/begin, op/nonce, claim/replay};**RoleOwner 沒有 claim/begin、claim/finish、claim/replay** → 回 3,不計數、不斷線 | provd/session.go:75-84, 650-651 |
| N5 | claim/finish 的 OK / 13 都讓 session 成 owner;9 **只**在這裡產生(helper 拒絕);無 begin / 逾 55 s → 3;ops 忙 / helper 逾時 330 s / 斷 → 7(**逾時的 7 可能其實已提交**) | provd/session.go:778-822, 609-628;provd/server.go:23, 28 |
| N6 | op/nonce 在 RoleReacquire 不經 helper:只回 OK 或 3(無 begin / 逾 55 s),3 不計數 | provd/session.go:757-766 |
| N7 | claim/replay:nonce 不論結果都作廢;ops 錯 → 7;OK / 13 → 成 owner 並 `killOthers`;其他 → 照 mapHelper;helper 拒絕(3)在同一連線累計 3 次 → 回覆後斷線 | provd/session.go:678-701, 577-582, 586-600 |
| N8 | `killOthers` 砍掉**所有**其他 session:未認證的、member 的、HTTP 的都算 | provd/server.go:848-860 |
| N9 | helper 的 claim.replay:先看失敗數,近一小時 ≥ 10 → 12(**正確的 replay 也被擋**);失敗計數只在記憶體;擁有者 ≠ 1 / 信封壞 / owner-op / CheckMac 失敗 → 計一次;成功必定產生新 root 密碼;13 只來自 setPassword 失敗,不計數 — **13 時密碼可能已換、也可能沒換**(存檔失敗會還原舊的 shadow 欄位);setPassword 的存檔(batman-config-save)單次上限 300 s、p5 忙時再試一次 | node/node.go:126, 617-631, 632-657, 661-665, 475-482, 496-534;provstore/provstore.go:457-458;cmd/batman-provhelper/main.go:81-87 |
| N10 | 已認領的 STATUS 不帶末四碼;有任何 BLE 連線時節點**收回廣播** | provd/server.go:599-615;cmd/batman-provd/bluez.go:772-776 |
| N11 | 握手還沒完成的連線 10 s 到期;握手後、非 owner / member 的 session(含 RoleReacquire)**閒置 30 s 到期**(每收一個訊息、每次 ops 回來都重算;ops 進行中不算閒置),而且第 3 條連線進來時可被擠掉 | provd/session.go:280-298, 155-168, 332, 394, 611-615;provd/server.go:29-30, 798 |
| N12 | 握手配額全節點共用 20 次/分;第 21 次 → `onMsg1` 回錯誤,**沒有 msg2**(app 看到的是斷線或沒有回覆) | provd/server.go:36, 681-697;provd/session.go:404-410 |
| N13 | claim/begin 也走 ops(取 nonce):ops 通道被別的工作佔住時 `HelperConn.Call` **立即**回 ErrBusy → `ss.ops` 轉成 **7**(不等);節點在 A/B 試用槽時 claim.replay 被 dispatch 擋 → 7 | provd/session.go:731-752, 609-628;provd/helper.go:19, 187-197;node/node.go:251-253 |
| N16 | claim.replay 還會回:**11**(本次開機 verdict 空 / unknown;前一次無線變更收不了尾;信封 schema 錯)與 **6**(沒有可用的紀錄)。計數的 11 = **信封解碼錯,或信封 body 裡的 response 缺 / 長度不對**(`bytesArg(body, 1, 32)`,node.go:642,在 l.625 的計數檢查之後);verdict / 收尾 / 參數格式(onlyKeys、bytesArg(a, …),在計數檢查之前)都不計 | node/node.go:172-182, 251-275, 605-614, 625, 636-645, 671-691;provd/session.go:586-600 |
| N14 | 回 12 時 session 不關(只有 helper 的 3 才計 `failOnce`) | provd/session.go:687-691 |
| N15 | 節點的 BLE 位址(RPA)900 s 才換;900 s 內連線前後、撤回 / 重新註冊廣播都是同一個位址 | `254-p2-impl.md` F-P17(l.40);cmd/batman-provd/bluez.go:37, 772-781 |

所以 claim/replay 不可能回 9;可能的回覆 = OK、3、6、7、10、11、12、13(N7、N9、N13、N16;4 與 10 只經 mapHelper 轉傳)。

**假設(T1 靠它)**:認領後幾十秒內,同一台節點對手機仍是同一個裝置 id(N15)。⚠️ kernel 實際行為沒有量過;RPA 剛好在這段時間到期、
或 Android 給了不同的 id → T1 每輪都「連不上」→ §2 的 T1 → T2 接續。

**app(✅ 讀碼)**
- `rust/batman-proto/src/replayflow.rs`:`Replay::start(pending, frame_limit)` → Ecdh → `ecdh_done(z)` 產生 msg1 → claim/begin → op/nonce →
  Sign → claim/replay;結局 `Replayed(Recovered|Reconnect|RateLimited|Refused|Unknown)/Msg2Undecryptable/CertRejected/Refused{verb,outcome}/Broken`
  (l.63-66, 73-92, 130-151;flow.rs:87-95)。bridge、Dart 都沒接。
- `claimflow.rs`:claim/finish 的 frame 在 `on_begin` 交出(l.188-191);`End::Broken` 在交出前後都可能出現,**現在分不出來**。
- `lib/claim.dart`:`_find`(l.116-164)逐台連線讀 STATUS,只回「未認領且末四碼相符」,只記 `d.id`、不記 RSSI,60 s(l.36);`_held`
  (l.170-203)在任何 BLE 之前比 K(l.188,只在「只有 pending」時);`_claim` 等 90 s(l.300);`_ClaimPageState` **沒有 `dispose()`**。
- `flutter_reactive_ble` 5.6.0 的掃描結果帶 `rssi`(reactive_ble_platform_interface `discovered_device.dart:43`);adapter 狀態有
  `statusStream`(`reactive_ble.dart:51`)與 `status`(l.60)。
- `flow::claim_replay`(flow.rs:87-95)把 7 / 10 / 6 / 11 / 未知碼 / OK 無憑證都歸成 `Unknown`;`ClaimFinish::TryReplay` 的註解寫「3 x 15 s」(flow.rs:47-49)。
- `lib/claim_records.dart` `persistPending`(l.67-73):同一 device_id 換另一張 QR(另一個 K)時,舊 pending 複製到一旁、新的取代它(R4)。
- `lib/nodes.dart` `_forget`(l.409-436,**dev 工具**,長按):直接刪 `node/<id>`(l.431),不經 `ClaimRecords`。
- Kotlin `ecdh` = owner_enc 私鑰 × peer(Keys.kt:103-106),**只有 dev 版開放**(EcdhPeer.kt:39-40;MainActivity.kt:121-127)。
  `keyLevels` channel 回傳 `recover`(MainActivity.kt:89-95);Dart 目前只在啟動時讀一次、只拿來顯示(lib/main.dart:66)。
- `lib/nodes.dart` `_login`(l.341-391)對每個廣播者握手,迴圈(l.366-381)不看 `mounted`、沒有節拍;app 沒有任何共用握手預算。

## 1. 範圍

做:使用者按「認領」之後,同一次動作內接上 replay(T1 / T2)。不做、寫回 #254 checklist(§12):沒有 QR 的「需恢復」入口、
`forgotten-pending/` 當候選、field 版的 replay、`_login` 的節拍與取消、真機測試。

## 2. 觸發(只在使用者按了「認領」之後)

| # | 條件 | 對象 | 動作 |
|---|---|---|---|
| T1 | 這次認領 `replay_due() == true`(下方) | **只有這次認領用的那個 BLE 裝置 id**(`_find` 回的 `id`) | 斷線 → 等 15 s(N3)→ 對它 replay,最多 3 輪 |
| T2 | 手機有 pending、**K 與這張 QR 相同**,且 `_find`(維持 60 s,不改)沒找到未認領的對象 | 重新掃描到的廣播者,RSSI 強的先(§3) | 顯示「沒找到未認領的這台,改試恢復先前的認領」→ replay |
| T3 | 只在 T2、而且手機已有這台的 node 紀錄(`ClaimTarget.nodeAndPending`) | — | replay 前先問(下方);取消 → 不 replay,照現在的 NOT_FOUND 文字(claim.dart:239-246)結束 |

- **`replay_due()`**(bridge `ClaimSession`,Rust 裡算,Dart 不比對文字):`finish 的 frame 已交給 Dart` **且** 結局 ∈ {還沒有結局、
  TryReplay(9)、Committed(13、OK 無憑證)}。所以 90 s 逾時、通知 / 寫入出錯、Broken 都算「還沒有結局」;finish 交出**之前**的任何
  失敗、以及 finish 回 3 / 4 / 6 / 7 / 10 / 11 / 12 / 其他碼,都不觸發(pending 保留;下次按「認領」時節點若已認領 → T2)。「已交出」寧可多報:
  finish 其實沒到節點時,節點仍未認領 → N1 的假 msg2 → 沒有結論、沒有副作用。
  finish 回 7 可能是節點其實已提交(N5)→ 文字改成「節點忙碌或結果不明,請再按一次『認領』」(再按 → 已認領則 T2)。
- **T1 → T2 接續**:T1 的 3 輪**每一輪都是「連不上」**(不是「解不開」)→ 同一次動作內接著做 T2 的掃描(K 已比過;不問 T3,理由同
  下面「T1 不問」;總時限從 T1 開始算)。有任何一輪連上了 → 不接續。
- **頁面已離開**:到 T1 的判斷點時頁面不在(`mounted == false`)→ 不開始;pending 保留,下次按 → T2。`dispose()` 不打斷進行中的
  claim/finish。
- **K 在哪裡比**:`ClaimRecovery` 開始時從磁碟重讀 pending、開封、`pending_matches_qr`(claim.rs:124-129),T1 / T2 都做;不同或讀不到 →
  不 replay。(`_held` 的比對只涵蓋「只有 pending」,nodeAndPending 沒比過。)
- **T3 的問題**:「沒找到未認領的這台。手機裡有它一次沒完成的認領,可以試著恢復:恢復會更換這台節點的 root 密碼,並中斷它目前
  所有的連線(包含隊友手機的)。如果它在『我的節點』還能用,不需要恢復。要恢復嗎?」(恢復要求送出後沒收到回覆而結束時,另加一句:
  「節點可能已更換密碼:『我的節點』仍可登入,但裡面存的 root 密碼可能已失效」— 舊紀錄的 tag key 不變;結果是 13 時同一句也適用,
  因為 13 的密碼可能換了也可能沒換,N9。)這時 R7 的「重新認領」已經問過一次;兩次問的是
  不同的事(R7 = 用新認領取代紀錄;T3 = 對可能正常運作的節點換密碼),R7 文字不改。
- T1 不問:能走到 finish 表示節點剛才以 NX 應答 = 未認領,舊 node 紀錄的憑證已無效(noover F13)。沒有 node 紀錄也不問:這支手機
  從沒拿到憑證 → 沒人能讓這台加入網路(network/join 只有 owner,session.go:78)→ 被 N8 砍的只會是未認證連線。
  **例外(接受)**:dev 版的「忘記節點」(nodes.dart:409-436)刪掉 node 紀錄、但 pending 還在 → T2 不問 T3 就 replay(換 root 密碼 +
  砍其他連線)。使用者既然忘了紀錄又按了認領,就是要找回這台;不另加機制。

## 3. 一次恢復(`ClaimRecovery`,一次「認領」最多一個)

1. **即時讀 `keyLevels['recover']`**(s1 §4.1 l.97、§6 l.246:恢復前即時讀等級);不是 true / 讀取出錯 → 不恢復、不連線,說明原因。
   再讀 pending(§2)、解碼(§5)。`ecdh(pending.ecdh_pub)` **在任何連線之前做一次**,z 交給 bridge 的 `ReplaySession` 保存(Rust 記憶體,
   結束時清零),Dart 那份立刻 `fillRange(0)`。`ecdh` 出錯(field 版沒有這個 channel)→「這個版本的 app 還不能恢復中斷的認領
   (紀錄先保留)」,不連線 = field 版的行為與現在相同。
2. 每一台:連線(逾時 15 s)→ MTU → CTRL → `ReplaySession.begin(frame_limit)`(內部 `Replay::start` + `ecdh_done(z)`,batman-proto 不改)
   → 寫 msg1 → 依 §4。時限:
   - **等 msg2 ≤ 12 s**(節點握手期限 10 s,N11;配額用完時沒有 msg2,N12)→ 到時斷線 =「沒有 msg2」。
   - claim/begin、op/nonce 各等回覆 ≤ 12 s,簽章 ≤ 10 s → 相鄰兩次寫入相隔 ≤ 22 s < 閒置 30 s(N11)。
   - **寫出 claim/replay 之前**每台合計 ≤ 45 s(< nonce 55 s,N6),到時斷線、下一輪再試這台。
   - **寫出 claim/replay 之後**等回覆 ≤ 90 s(與 finish 相同,claim.dart:300;ops 進行中 session 不算閒置,N11)。
     ⚠️ Pi 上 claim/replay 實際要多久沒有量過 → 真機步驟量(§10)。節點那邊可能比 90 s 久(存檔 300 s + 重試、HelperWait 330 s,N9):
     這段時間節點不廣播(N10)、ops 忙(N13)→ 之後的輪次是「連不上」或 7;helper 回來時若成功,`killOthers` 會砍掉我們新開的 session。
     沒有破壞性;現在不改時限,真機量過再看。
3. 節拍:同時 1 條;兩次握手的開始相隔 ≥ 10 s(= s1 §5.3 的 6 次/分)。
4. **T1 的一輪** = 對那一台試一次。**T2 的一輪** = 掃描 6 s(不讀 STATUS)→ 取 6 台 → 逐台試,直到有一台的 msg2 解得開。
   `ClaimRecovery` 在記憶體裡記「這次動作試過、握手沒解開」的裝置 id;每輪取 6 台的順序 = **沒試過的先(依 RSSI),名額有剩才放試過的
   (依 RSSI)**— 試過的仍要能重試(N3 的快取空窗)。每輪重新掃描(N10:有人連著的節點不廣播 → 下一輪才看得到)。一旦某台解得開且
   DAC 相符,它就是對象:之後的輪次只試它。最多 3 輪,輪與輪相隔 ≥ 15 s。3 輪後還有沒試過的 → 提示把手機貼近節點。
   T2 每輪掃描一次、輪距 ≥ 15 s → 每 30 s 最多 2 次,在 s1 §5.3(l.186)的 ≤ 4 次 / 30 s 之內。
   **時間預算**:最壞情況每台 ≈ 15 s(連線逾時)+ 12 s(msg2)= 27 s → 每輪掃描 6 s + 6 台 ≈ 162 s + 輪距 15 s → 300 s 的總時限
   可能在第 2 輪中途用完、第 3 輪不會跑(第 2 輪第一台約在 6 + 162 + 15 + 6 = 189 s 開始;T1 三輪都連不上再接 T2 時約在 279 s,§10 D9)。這是接受的:附近 6 台都連不上 / 不回 msg2 時,再等也沒用;使用者可再按一次。
5. **總時限 300 s**(從 T1 或 T2 開始算):過了就不再開始新的一台、不再重試 13;進行中的做完,所以最長 300 + 45 + 90 = 435 s。
6. **進度**:每台一行「恢復中:第 r/3 輪,第 i/n 台」;恢復期間「認領」鈕換成「停止恢復」。
7. **取消**(按「停止恢復」、離開頁面 = 新增的 `dispose()`):設旗標。還沒寫出 claim/replay → 立即斷線結束;已寫出 → 等這一台的回覆
   (最多 90 s)再結束,拿到憑證照樣寫紀錄(節點已換密碼,丟掉回覆只會多一次輪替)。寫紀錄不需要頁面還在。
   藍牙在恢復中被關掉(`statusStream` 不是 ready)→ 立即停止,pending 保留。
   app 進背景:不另外處理,計時照走;⚠️ 背景下 BLE 是否延遲未驗。被系統殺掉 → pending 還在 → 下次按「認領」走 T2。

## 4. 結果表(`replay_next(步驟, 結果) → 動作`,全函式;沒列到的一律「停止」)

| 步驟 | 結果 | 動作 | 節點計失敗? |
|---|---|---|---|
| 連線 / msg2 | 連不上、逾時、12 s 內沒有 msg2 | 下一台(T1:下一輪;T1 三輪全是「連不上」→ 接 T2,§2) | 否 |
| msg2 | 解不開(不是這台、未認領、N3 的快取空窗、擁有者 ≠ 1、重燒) | **立即斷線**,下一台(T1:下一輪) | 否 |
| msg2 | CertRejected(解得開但 DAC ≠ pending) | 全部停止:「節點身分與認領紀錄不符」 | 否 |
| claim/begin、op/nonce | 7(ops 忙時立即回,N13)、10;op/nonce 的 3(N6) | 斷線,下一輪再試這台 | 否 |
| claim/begin、op/nonce | 其他(含 claim/begin 的 3 / 4、6、11) | 停止(中性文字) | 否 |
| 任何 | claim/replay **寫出前** Broken / 斷線 | 下一輪再試這台 | 否 |
| claim/replay | 寫出後沒有回覆(斷線、90 s) | 下一輪再試這台(節點可能已換密碼;之後成功拿到的是最新的)。節點可能還在做(§3-2):之後的輪次多半是「連不上」或 7 | 不明 |
| claim/replay | 寫出後的回覆壞掉 / 格式不對 / 解不開 | **停止**:「節點回覆無法辨識,紀錄先保留」 | 不明 |
| claim/replay | OK + 憑證 | §5 寫紀錄,結束:「已恢復;root 密碼已更換,先前抄下的密碼失效」 | — |
| claim/replay | OK 但沒有可用憑證 | 停止:「節點回覆無法辨識,紀錄先保留」(再試只會再換密碼) | — |
| claim/replay | 13 | 斷線 → 15 s → 新連線再 replay;**不算輪數**,連續 ≤ 5 次且受總時限限制,之後停:「節點上鎖尚未完成,請稍後再試」。每一次 13 也會砍掉節點上其他所有連線(N7、N8) | 否(N9) |
| claim/replay | 12 | 停止:「恢復被擋 — 可能有人在附近干擾,請換地點或稍後再試」(s1:247 原文) | — |
| claim/replay | 7、10 | 下一輪再試這台(7 可能是「結果不明」,同「沒有回覆」;也可能是節點在 A/B 試用槽,N13) | 否 / 不明 |
| claim/replay | 3、其他(4、6、11、1、2、未知碼) | **停止,不重試**(中性文字) | 3 會;11 只有信封解碼錯、或信封 body 裡的 response 缺 / 長度不對(node.go:642,在 l.625 的計數檢查之後)才會(N16);6 不會 |

- 一次「認領」最多造成 1 次確定被計的失敗(第一次被拒就停)+ 至多 2 次「沒有回覆」的不明結果;N7 的同一連線第 3 次拒絕斷線因此碰不到。
- 「寫出後」由 `ReplaySession` 的 `written` 旗標判定(claim/replay 的 frame 一交給 Dart 就設,§7)。
- 3 輪或 300 s 用完沒有結果:T1 且 finish 回的是 9 → s1 §5.1 的「QR 不符,或認領仍在收尾 — 請確認 QR 後稍後再試」;其他 → s1 §5.2 的
  「找不到這台或還無法恢復:請把手機貼近節點、確認節點開機後再試(節點也可能已重燒或被他人認領)」;這次有寫出過 claim/replay 而沒拿到
  回覆時,再加一句「節點可能還在收尾 — 請等幾分鐘再按一次」。pending 一律保留。
- **實作需要 `flow::ClaimReplay` 加一個變體 `Busy`(7 或 10)**:現在 7 / 10 與 6 / 11 / 未知碼 / OK 無憑證都歸 `Unknown`(flow.rs:87-95),
  分不出「下一輪」與「停止」。其餘維持 `Unknown` → 停止。
- claim.rs:271 的「節點已被別人認領」不符 s1 §5.2 的中性要求 → 改成上面 §5.1 那句;claim.rs:371 的斷言一起改。

## 5. 紀錄

- pending 解碼(bridge):輸入 = 開封後的明文;只收 key 1–7、長度固定、**device_id 必須等於路徑上的 id**;不合 → 不 replay、pending 不動。
- Recovered → 現有的 `ClaimRecords.claimed()`(claim_records.dart:77-87):舊 node 紀錄複製到一旁、寫新紀錄(key 1–9 與認領相同,
  claim.rs:242-253)、再刪 pending。複製失敗仍寫(新密碼是唯一有效的)。
- 其他結局:不寫 node 紀錄、pending 不動。

## 6. 擁有權

| 資源 | 唯一寫入者 | 其他 |
|---|---|---|
| `claim-pending/<id>`、`node/<id>`、`forgotten-*` | `ClaimRecords`(認領與恢復共用) | `ClaimRecovery` 只讀 pending;nodes 頁唯讀,**例外:dev 版 `_forget` 直接刪 `node/<id>`(nodes.dart:431)= 第二個寫入者(只刪、只在 dev、使用者確認後)**,本版不改,後果見 §2 |
| 認領頁的 BLE 連線與掃描 | `_ClaimPageState`(`_busy` 期間;`_find` 與認領的連線結束後,才由它建立的 `ClaimRecovery` 接手) | nodes 頁是另一個 route(main.dart:124-128),⚠️ 推論:不會同時握手 |
| 候選清單(id、RSSI)、「試過沒解開」的 id 集合、輪數、節拍、時限、取消旗標 | `ClaimRecovery`(記憶體,一次動作) | 頁面只設取消旗標、讀進度 |
| z、psk_replay、K 的明文 | bridge `ReplaySession`(Rust 記憶體,drop 時清零) | Dart 只經手 z 一次 |
| root 密碼、失敗計數、session、PSK 集合 | 節點 | app 只從回應碼得知 |

## 7. 契約

| 介面 | 寫 / 讀 | 何時有效 | 缺 / 壞 / 過期 | 誰寫得到 |
|---|---|---|---|---|
| `ClaimSession.replay_due()` | bridge / claim.dart | 認領以任何方式結束之後 | 例外 → 當 false(不 replay;下次 T2) | 只有 app 自己 |
| pending 紀錄 | ClaimRecords / ClaimRecovery | 落盤後 | §5:不合 → 不 replay(fail-closed) | app 私有目錄 + Keystore 封存 |
| `ReplaySession`:`prepare(pending 明文, 路徑 id) → peer`、`set_z`、`begin(frame_limit) → frames`、`on_frame`、`signed` → 步驟(寫 / 簽 / 結束(列舉 + 文字)/ Recovered(node 紀錄));`written()` = claim/replay 的 frame 是否已交出 | bridge / ClaimRecovery | 一次恢復 | 結束文字不含 z / K / psk / 密碼(測項掃字串);未知結局 → 停止 | 只有 app 自己 |
| `keyLevels['recover']` | Kotlin / ClaimRecovery | 每次恢復開始時即時讀 | 不是 true / 出錯 → 不恢復、不連線(fail-closed) | 同程序 |
| `ecdh` channel | Kotlin / Dart → Rust | dev 版 | 錯誤 → 不恢復、不連線 | 同程序;peer 來自 pending 裡驗過 sig_ecdh 的 ecdh_pub(tests/replayflow.rs:237) |
| BLE 掃描結果、msg2、回應碼 | 任何附近裝置 / ClaimRecovery | — | Noise + DAC pin;§4 全表 | **不可信** |

## 8. 生命週期

| 路徑 | 現在 | 之後 | 測 |
|---|---|---|---|
| 第一次認領成功 | CLAIMED | 不變(`replay_due` false) | 現有 + R1 |
| finish 回 9 / 13 / OK 無憑證 / 交出後沒有結局 | 只有文字 | T1 | R1 + D1 |
| finish 交出前失敗、finish 回 7 等 | 只有文字 | 不變;下次按 → 未認領則重來(R3),已認領則 T2 | R1 |
| app 在等 finish 回覆時被殺(§0 的重現) | 60 s 後 NOT_FOUND | 重掃 QR → T2 | D3;真機 ❌ |
| 快取空窗(節點已提交、仍以 NX 應答) | 9,只有文字 | T1:等 15 s,解不開就下一輪 | R4 |
| 有 node 紀錄 + pending | R7 → NOT_FOUND | R7 → T3 → replay | D4 |
| 節點重燒 / 被別人認領 / 擁有者 ≠ 1 | NOT_FOUND | 解不開 → 中性文字 | D2 |
| 恢復中斷線 / 節點斷電 / helper 重啟 | — | §4(下一輪);節點重開後失敗計數歸零(N9) | R2 |
| 恢復中離開頁面 / 按停止 / app 被殺 | — | §3-7;T1 判斷點頁面已離開 → 不開始(§2) | D6 |
| 藍牙關 / 沒權限 | claim.dart:228 擋 | 不變(在 replay 之前) | 現有 |
| 恢復中藍牙被關掉 | — | 立即停止,pending 保留(§3-7) | D6 |
| T1 期間節點換了 BLE 位址 / 裝置 id(N15 的假設不成立) | — | T1 三輪都連不上 → 同一次動作接 T2 | D8 |
| 節點在 A/B 試用槽 | — | claim/replay 回 7(N13)→ 下一輪 → 用完 → 中性文字,可再按 | R2 |
| 節點剛開機還沒廣播(⚠️ s1:165 寫開機收尾 ≤ 120 s;provd 何時開始廣播沒有讀碼確認) | NOT_FOUND | 掃不到 → 中性文字,可再按 | D2 |
| 節點的 ops 通道正在套用無線設定(s1:115 的 ⚠️ 單一 ops 通道;N13) | — | claim/begin **立即**回 7 → 下一輪 → 用完 → 中性文字,可再按 | R2、D11 |
| 寫出 claim/replay 後 90 s 沒回覆,節點還在存檔(N9) | — | 下一輪多半「連不上」/ 7;結束文字加「請等幾分鐘再按」;helper 回來時砍掉新 session(N8),無破壞 | 假節點 + D10 |
| dev 版「忘記節點」後仍有 pending | — | T2 不問 T3 就 replay(§2 例外) | D4 |
| app 升版 / 降版 | — | pending 與 node 紀錄格式都不變;降回沒有 replay 的版本 = 現在的行為 | R3(round-trip) |
| field 版 | NOT_FOUND | 沒有恢復:「還不能恢復」,不連線 = 與現在相同(節點要重燒才救得回,§12) | D7 |
| 節點升級 / 回滾、iOS | — | 不適用:節點不改;iOS 不在 S1 | — |

## 9. 安全

- **資產**:節點控制權(root 密碼、owner session)、K、z、psk_replay。
- **附近 / 遠端攻擊者,以及手機上其他 app(都能假冒廣播)**:沒有 owner_enc 私鑰算不出 psk_replay → msg2 解不開 → 我們只送過 msg1
  (臨時公鑰 + tag;⚠️ 依 Noise 規格,不含身分)。能做的只有拖延:用強訊號佔名額(§3-4 的「沒試過的先」讓同一批假裝置佔不了第二輪)。上限 = §3 的 435 s 與 3 輪;
  不能造成節點計失敗(§4)。這個拖延擋不掉,明寫為已知限制。
- **在 BLE 範圍內的攻擊者還能**:(a) 用掉全節點共用的 20 次/分握手配額(N12),或 (b) 一直連著,讓節點不廣播(N10)→ 他在場時
  恢復做不成;不動任何計數、沒有持續性的鎖定,他離開就恢復(與 254-p2-impl l.105 已接受的界線相同)。(c) 知道 psk_replay 的人才送得出
  被計數的 replay;但失敗滿 10 次後,**正確的 replay 也回 12 一小時**(N9;計數只在記憶體,helper 重啟就清掉)。
- **被攻陷 / 別人的節點**:握不到 psk_replay → 同上;DAC 不符 → CertRejected。
- **我們自己的錯**:無聲換密碼、砍隊友連線(N8)→ T3;把節點推到 12(N9)→ 第一次被拒就停;對錯的裝置 replay → T1 只對同一個 id。
  **已知限制(合法路徑上的錯 K)**:同一 device_id 掃了另一張 QR、使用者選「用這張」(R4)→ 新 pending(K2)取代舊的
  (claim_records.dart:67-73);若碰上快取空窗,finish 回 9 → T1 用 K2 replay → psk_replay 與 K 無關所以握得開,但 CheckMac 失敗 →
  節點計 1 次(node.go:655-656),而原本那張 QR 已對不上 pending。每按一次最多計 1 次;不另加機制。
- **新增的輸入**:掃描結果(id、RSSI,只用來排序)、msg2 與回應(§4 全表)、磁碟上的 pending(§5 嚴格解碼)。沒有新權限、新連接埠。
- **權限**:app 自己的沙箱;沒有提權的程式碼。
- **祕密**:K、z、psk、root 密碼、tag key 不進 log、例外字串、畫面、argv;新密碼只進封存的 node 紀錄。z 在 Kotlin 回傳後清零
  (MainActivity.kt:127)、Dart 交出後清零、Rust drop 時清零。
- **失敗方向**:一律 fail-secure — 不明結果不寫 node 紀錄、不刪 pending、不重試被拒的請求。
- **負向測試**:§10 的 S1–S3。

## 10. 測試與負對照(每項的負對照 = 拿掉括號裡的東西就 FAIL)

假節點(`tests/replayflow.rs`)改成照 N1–N9:未認領 → 假 msg2,長度斷言 = cert + 96(現在 l.113 是 cert + 112,多 16 B);成功每次回
不同密碼;成功或 13 之後同一 session 的 claim/replay、claim/begin → 3(不是 13);nonce 用一次就作廢;失敗計數跨連線、到 10 連正確的也
回 12;同一連線第 3 次拒絕後斷線;**回 12 後 session 不關(N14);快取空窗內 NX 握得開、但 claim/finish 回 9(N3、N5);握手配額
(共用 20 次/分)用完 → 沒有 msg2 直接斷(N12);成功(或 13)後其他 session 全被關(N8)**;快取空窗內對 psk_replay 回的是
**解不開的 msg2**、不是沒有 msg2(N3);ops 忙 → 立即 7(N13);claim/replay 進行中該 session 不回應、節點不廣播、其他連線的 claim/begin
得 7、做完時 killOthers;claim/replay 回 6 / 11(不計數,N16);13 而密碼沒換(N9)。每個行為在測試裡註明 N 編號。

| # | 測項 | 層 | 負對照 |
|---|---|---|---|
| R1 | `replay_due` 全表:finish 交出前後 × 每個結局 / 每個碼 | Rust | (「已交出」旗標)→ 交出前的 Broken 也觸發;(排除 7)→ 7 觸發 |
| R2 | `replay_next` 全表:§4 每列 + 未知碼 → 停止;`claim_replay`:7 / 10 → `Busy`,6 / 11 / OK 無憑證 → `Unknown` | Rust | (預設停止)→ 未知碼變成重試;(`Busy`)→ 7 變成停止 |
| R3 | pending 解碼:key 多 / 少、長度錯、id ≠ 路徑;`pending_record()` 的產物 round-trip | Rust | (id 檢查)→ 別台的 pending 被接受 |
| R4 | 假節點快取空窗:第 1 輪解不開、第 2 輪 Recovered | Rust | (下一輪)→ 第 1 輪就結束 |
| D1 | T1 只連認領用的那個 id,旁邊有另一台「已認領」的假裝置 | Dart 假 BLE | (只對同一 id)→ 連到另一台 |
| D2 | T2:不讀 STATUS、依 RSSI、每輪 ≤ 6、每輪重掃、解得開後只試那台;全部解不開 → 中性文字 | Dart | (排序 / 上限 / 重掃)各一 |
| D3 | 症狀:節點已認領、手機只有 pending → node 紀錄存在,且用它存的 tag key 與最後一次的密碼能登入假節點 | Dart | (replay)→ 60 s NOT_FOUND、沒有 node 紀錄 |
| D4 | T3:有 node 紀錄才問;取消 → 零連線、紀錄不變;node 紀錄被 `_forget` 刪掉、pending 還在 → 不問、直接 replay | Dart | (T3)→ 直接連線 |
| D5 | 第一次被拒就停;13 最多 5 次;12 的文字 | Dart 假時鐘 | (停止規則)→ 第 2 次 replay 被送出 |
| D6 | 總時限、進度行、停止 / dispose / 藍牙被關:寫出前立即斷,寫出後等回覆並寫紀錄;T1 判斷點頁面已離開 → 不開始 | Dart 假時鐘 | (旗標)→ 繼續連下一台 |
| D7 | `keyLevels['recover']` 為 false / 讀取出錯、或 `ecdh` 出錯(field 版):零連線 | Dart | (檢查)→ 有連線 |
| D8 | 假節點在 T1 途中換 id:T1 三輪連不上 → 同一次動作接 T2 → Recovered;有一輪連得上(只是解不開)→ 不接 | Dart | (接續)→ 以中性文字結束、沒有 node 紀錄 |
| D9 | T2 輪序:8 台假裝置,目標的 RSSI 排第 7 → 第 2 輪試到它。跑兩種:每台很快回假 msg2;以及每台接近最壞時間(15 s 連線 + 12 s msg2)→ 證明第 2 輪在 300 s 內排得到目標(含每輪 6 s 掃描:6 + 6 × 27 + 15 + 6 = 189 s 開始試目標,最壞做完 ≈ 216 s),並記下第 3 輪跑不到;再跑「T1 接 T2」:T1 三輪都連不上(15 + 3 × 15 + 2 × 15 = 90 s)後接 T2,第 2 輪第一台約在 90 + 6 + 162 + 15 + 6 = 279 s < 300 s 開始 | Dart 假時鐘 | (「試過」集合)→ 3 輪都沒試到 |
| D10 | 寫出 claim/replay 後假節點 60 s 才回 OK → 寫了 node 紀錄、只送過 1 次 replay | Dart 假時鐘 | (寫出後 90 s;改成 45 s)→ 沒有紀錄、送出第 2 次 replay |
| D11 | 時限:msg2 12 s 沒來 → 斷線換下一台;寫出前每台 45 s;相鄰兩次握手的開始相隔 ≥ 10 s;ops 忙 → claim/begin 立即 7 → 下一輪 | Dart 假時鐘 | (各時限 / 節拍)各一:連線留著 / 兩次握手相隔 < 10 s |
| D12 | pending 的 K ≠ QR(T1 與 T2 各一)→ 零連線、pending 不動 | Dart | (K 比對)→ 有連線 |
| D13 | `replay_due()` 丟例外 → 當 false:零連線、pending 保留 | Dart | (try)→ 例外冒到頁面 |
| D14 | 舊 node 紀錄複製到一旁失敗 → 新 node 紀錄仍寫入、pending 刪除 | Dart | (「仍寫」)→ 沒有 node 紀錄 |
| D15 | 寫出後的回覆被破壞 / 格式不對 / 解不開 → 停止、「節點回覆無法辨識」、不送第 2 次 | Rust + Dart | (該列)→ 重試 |
| D16 | finish 回 7 → 不觸發 T1,文字請使用者再按一次;13 的重試不算輪數、每次新連線 | Rust + Dart | (排除 7,同 R1);(13 不算輪)→ 第 4 次 13 時已停 |
| S1 | 10 台假裝置回亂數 msg2:每台只收到 msg1 就被斷線,每輪 ≤ 6 次握手 | Dart | (立即斷線)→ 連線留著 |
| S2 | DAC 不符 → 停止,之後零寫入 | Rust(現有 l.313-328) | 已有 |
| S3 | 所有結束文字與 log 掃不到 K / z / psk / 密碼的 hex 與原文 | Rust + Dart | 故意把密碼放進文字 → FAIL |

**真機:❌ 全部未做**(需要使用者授權動手機與 04)。計畫:
0. **先看裝的是哪個 flavor**:`adb -s <serial> shell pm list packages dev.batman` → `dev.batman.app.dev` = dev、`dev.batman.app.dev2` =
   dev2、`dev.batman.app` = field(`applicationIdSuffix`,build.gradle.kts:60 / 68,本分支行號)。之後的步驟一律用**同一個 flavor** 的
   APK(換 flavor = 另一個 app,看不到那支手機上的 pending)。
   **安裝規則(步驟 0 與 2 都適用)**:只用 `adb -s <serial> install -r <apk>`。**這支手機上禁止 `flutter install` 與 `flutter run`**:
   `flutter install` 一律先解除安裝(本機 SDK `C:\src\flutter` @ c197ca5199e,flutter_tools `commands/install.dart:104-113`,`bool uninstall = true`),`flutter run` 安裝失敗時
   會解除安裝再裝(`android/android_device.dart:415-423`)。也禁止清除 app 資料、禁止改 applicationId(dev / field 是不同的 app,
   `build.gradle.kts:30, 50, 58`,pending 與 Keystore 不共用)。裝之前比簽署憑證:與已安裝的不同 → **停,絕不解除安裝**(pending 與
   Keystore 金鑰會消失,04 就再也救不回,只能重燒)。裝完先確認 pending 紀錄還在,才往下做。
1. 負對照(先做):04 與 S20 維持 §0 的狀態,用 main f0138bd 的 dev APK、同一張 QR 按「認領」→ 預期 60 s NOT_FOUND、沒有 node 紀錄。
   ⚠️ 這一步目前只由讀碼推得(claim.dart:156);§0 的留言沒有寫到實際再按過一次。
2. 驗收:依步驟 0 換成本功能的 dev APK(⚠️ `install -r` 保住 pending 未驗 → 裝完先查)→ 同一張 QR → T2 →「已恢復」→「我的節點」
   登入成功 → 經 app 放回 lab key。同時量 Pi 上 claim/replay 從寫出到回覆的時間(§3-2 的 90 s 是否足夠)。
   **節點連續 2 次拒絕 replay → 停下來查原因**,不要繼續往 10 次(N9 的 12)推。
3. **T1(在範圍內;s1 §8-7 卡 1 ②、卡 2 ③ 負對照)**:finish 一送出就關掉手機藍牙,約 60 s 後再開 → 預期 T1(或接 T2)→「已恢復」。
   觸發要在**手機上的單一 `adb shell` 迴圈**裡做(主機端輪詢約 4 s,太慢);需要重燒卡 → 每次先問。⚠️ 關藍牙後 app 端 finish 的
   收尾與 `replay_due` 的實際時序未驗。
4. 13、12、快取空窗的真機做法還沒有 → 留在 #254 checklist,PR 內標 ⚠️ 模擬。

## 11. 與凍結設計(254-app-s1)的偏離

| s1 | 本版 | 理由 |
|---|---|---|
| §5.2:每個 device_id 每小時 ≤ 3 次被拒的 replay | 沒有計數器;每按一次「認領」最多 1 次被拒 | 不必存計數;使用者一小時按 10 次仍會到 12(N9),由 12 的文字說明。`flow.rs:75-81` 的註解(「app 的 3 / 小時」、`session.go:653-657` 行號、「3 次斷線」)一起更新 |
| §5.2:結果不明 → 先 NX、再 replay | T1 直接 replay,不先 NX | NX 由下一次按「認領」的 `_find` 承擔;replay 對未認領節點沒有副作用(N1) |
| §5.3:候選 = STATUS ∈ {1, 2} 或讀不到;最近見過的先試;位址 → device_id 快取 | 不讀 STATUS、RSSI 排序、沒有快取 | 讀 STATUS 要每台多連一次;未認領的由假 msg2 排除;app 沒有「最近見過」的資料 |
| §5.3:握手預算與 psk_owner 登入共用 | 只管恢復自己的節拍 | app 裡沒有共用預算(`_login` 沒有節拍);兩者不同頁 |
| §5.3:認領後解不開重試 3 次 / 3 s | T1 等 15 s 再試、輪距 15 s | 15 s 同時涵蓋 state 快取(N3) |
| noover R7 / R7-2 | 文字不改;T2 + node 紀錄時多一次 T3 | §2 |
| §5.1:未認領節點 + 錯的 QR → finish 回 9 後立刻顯示「QR 不符…」 | 先走 T1(15 s + 3 輪,每輪立刻得到假 msg2)→ 約 50 s 後才顯示同一句 | 9 分不出「QR 錯」與「已提交、快取空窗」(N3);期間有進度行、可按停止 |
| §5.2 / §5.3 沒有寫每步時限 | msg2 12 s、寫出前 45 s、寫出後 90 s、總時限 300 s | §3-2 / 5 |

## 12. 寫回 #254 checklist(不開新單)與實作要動的檔

- [ ] field 版不能 replay(`ecdh` 只有 dev 版)→ 設計 field 的 ecdh 開放條件;`EcdhPeer.kt:12-15` 的註解補上第二個用途(replay 的 peer)。
- [ ] `nodes.dart` `_login`:握手節拍、離開頁面時取消;`claim.dart` `_find` 同樣沒有取消。
- [ ] replay 從 `forgotten-pending/` 取候選(noover §9,已在單上);沒有 QR 的「需恢復」入口。
- [ ] 真機:§10 的 0–4(含 T1 與 claim/replay 耗時的量測);**手機上只用 `adb -s <serial> install -r`,禁止 `flutter install` /
  `flutter run`、清資料、改 applicationId**;連續 2 次被拒就停。
- [ ] 真機量到 claim/replay 耗時後,重看寫出後的 90 s(§3-2)。
- 實作會動:bridge `claim.rs`(`replay_due`、文字)、新的 bridge replay API、`claim.dart`(`ClaimRecovery`、`dispose`、停止鈕)、
  `batman-proto` `flow.rs`(`ClaimReplay` 加 `Busy` 變體 + `claim_replay` 對應 7 / 10;註解:`ClaimReplay`、`ClaimFinish::TryReplay`)、
  `replayflow.rs` 開頭註解(「3 次」→ §3-4)、`tests/replayflow.rs`、`tests/flow.rs`(`claim_replay_rows` l.54-56 的迴圈把
  7 / 10 斷言成 `ClaimReplay::Unknown` → 移到 `Busy`;這就是 R2 的負對照)、`EcdhPeer.kt` 註解。`batman-proto` 其餘流程碼、節點、
  Kotlin 邏輯不動。
- 實作時的檔案配置(行為同上,只是放的位置):`ClaimRecovery` 放在新檔 `lib/claim_recovery.dart`(連同 BLE 介面 `RecoveryBle`,
  測試才換得掉藍牙),`claim.dart` 只接 T1 / T2、停止鈕與 `dispose()`;bridge 新檔 `api/replay.rs`;假節點放在
  `batman-proto/tests/support/replay_node.rs`,bridge 的測試以 `#[path]` 共用(宣告在 bridge `lib.rs`,不在 `crate::api` 底下,codegen
  看不到);Dart 測試 `test/claim_recovery_test.dart`、`test/claim_replay_page_test.dart`、共用假物件 `test/replay_fakes.dart`。

## 13. v2 → v3

| 意見 | 處理 |
|---|---|
| A-B1 / B-M1:T1 只對剛用過的裝置 | §2 T1、§10 D1 |
| A-M1:候選沒有擁有者與資料 | §3-4(重掃、RSSI、不讀 STATUS)、§6 |
| A-M2:`_find` 縮成 20 s | §2 T2:維持 60 s |
| A-M3:哪些 finish 結局觸發 T1 | §2 `replay_due`、§10 R1 |
| A-M4 / B-M3:結果表不完整 | §4 全表、§10 R2 |
| B-M2:假節點模型錯 | §0 N1–N9、§10 開頭 |
| B-M4:總時限、進度、取消、dispose / 背景、T3 取消 | §3-5 / 6 / 7、§2 T3、§10 D4 / D6 |
| A 小項:killOthers 連隊友一起砍 | N8、§2 T3 文字 |
| A 小項:node.go:628 → 632,行號重驗 | §0(全部重讀) |
| A 小項:T3 只給 T2 | §2 |
| A / B 小項:3 次/小時的偏離、flow.rs 註解 | §11 |
| A 小項:`start(pending, frame_limit)` 與 ECDH 先於連線 | §3-1 / 2、§7 |
| A 小項:`_login` 沒有取消 | §0、§12 |
| A 小項:K 在哪裡比 | §2 |
| A / B 小項:負對照 | §10 |
| B 小項:msg1 是 48 B | N1 |
| B 小項:12 的文字 | §4(s1:247 原文) |
| B 小項:認領後 PSK 更新落後 | N3、§2 T1、§4「解不開」列、§10 R4 |
| B 小項:field 版不能 replay、EcdhPeer.kt 註解 | §3-1、§12 |
| B 小項:T3 與 R7 重複問、R7-2 文字 | §2、§11 |
| B 小項:Unknown 跳過 NX、RSSI 排序 | §11 |
| B 小項:真機 ❌ | §10 |

與審查意見不同、以原始碼為準的兩點:(1) 回 3 **不一定**斷線 — 角色表的 3 不計數、不斷線(N4),只有 helper 拒絕累計 3 次才斷(N7);
(2) RoleReacquire 的 op/nonce 不經 helper,回不出 7(N6)— §4 仍把它列進表內。

v2 有、v3 刪掉的:T1 的候選清單、「同 session 再 replay 得 13」。(v3 也刪了 `keyLevels.recover`,v4 依 s1 加回,見 §14。)

## 14. v3 → v4

| 意見 | 處理 |
|---|---|
| A-M1:T2 每輪都是同一批前 6 台 | §3-4「試過沒解開」集合、§6、§10 D9 |
| A-M2 / B-M2:時限(msg2 12 s;45 s 只到寫出前、依據含閒置 30 s;寫出後 90 s;總時限與取消) | N11、N12、§3-2 / 5 / 7、§4、§10 D10 / D11、§11 |
| A 小項 1 / B-M1:RPA / 位址改變 | N15 + 假設(§0)、§2「T1 → T2 接續」、§4 第一列、§8、§10 D8 |
| A 小項 2 / B-M3:恢復前即時讀 `keyLevels['recover']` | §0、§3-1、§7、§10 D7;刪掉「ecdh 的錯誤已足夠」 |
| B-M4 / A 小項 4:測項與假節點模型補齊 | §10 開頭(N3 / N5 / N8 / N12 / N14)、D11–D15 |
| 小項:13 不算輪數、每次也砍其他連線 | §4、§3-5、§10 D16 |
| 小項:finish 回 7 可能已提交 | N5、§2、§10 D16 |
| 小項:N5 行號 778-822 | N5 |
| 小項:範圍內攻擊者(握手配額、佔住連線)、10 次錯誤後正確的也回 12 | §9 |
| 小項:T3 路徑寫出後沒有回覆 → 舊紀錄的密碼可能失效 | §2 T3 文字(tag key 不變:node/node.go:665) |
| 小項:dispose 與 T1 判斷點、不打斷 claim/finish | §2、§8、§10 D6 |
| 小項:`replay_next` 列出「寫出後回覆壞掉 → 停止」、`written` 旗標 | §4、§7、§10 D15 |
| 小項:未認領 + 錯的 QR 變成約 50 s | §11 |
| 小項:生命週期(藍牙中途關、A/B 試用槽、開機後還沒廣播、field 版 = 現狀、ops 通道忙) | N13、§8 |
| 小項:真機計畫(步驟 0 比簽章、T1 留在範圍內、量 claim/replay 耗時) | §10 真機 0–4、§12 |

## 15. v4 → v5

| 意見 | 處理 |
|---|---|
| A-M1 真機安裝會解除安裝(`flutter install` / `flutter run`) | §10 真機 0 / 2(只用 `adb install -r`、禁止清資料與改 applicationId、裝完先查 pending、連續 2 次被拒就停)、§12 |
| A-m1 / B-2 ops 忙 → 立即 7(不是等) | N13、§4、§8、§10 D11 |
| B-1 寫出後 90 s 沒回覆時節點可能還在做 | §3-2、§4、§8、結束文字(§4 末) |
| B-3 `ClaimReplay` 分不出 7 / 10 | §4 末(加 `Busy`)、§12、§10 R2 |
| B-4 dispatch 的 ⚠️ → 已驗清單(6、11,只有信封解碼的 11 計數) | N16、§0、§4 計數欄 |
| B-5 13 時密碼可能沒換 | N9、§2 T3 文字 |
| A-m2 dev 版有「忘記節點」 | §0、§2 例外、§6、§8、§10 D4 |
| A-m3 時間預算(第 3 輪可能跑不到) | §3-4、§10 D9 |
| A-m4 合法路徑上的錯 K(R4 換 QR) | §0、§9 |
| A-m5 兩個 ⚠️ 結案(`statusStream`;PSK 集合不會變回 nil) | §0、N3、§3-7、§10 開頭 |
| B-6 假節點補行為 | §10 開頭 |
| B-7 N13 行號、掃描頻率 | N13、§3-4 |

## 16. v5 → v5.1(最終審查的 4 項,實作時一起改)與實作時的解讀

| 意見 | 處理 |
|---|---|
| 1. N16 / §4 計數欄:信封 body 裡的 response 缺 / 長度不對也是計數的 11 | N16、§4 末列(node.go:642 `bytesArg(body, 1, 32)`,在 l.625 的計數檢查之後);假節點 `n16_6_and_11_uncounted_but_a_bad_response_is_11_counted` |
| 2. 真機步驟 0 先看 flavor | §10 真機 0(`pm list packages dev.batman`,用同一個 flavor 的 APK) |
| 3. §12 列出 `tests/flow.rs` | §12 |
| 4. D9 的算式含每輪 6 s 掃描,加「T1 接 T2」 | §3-4、§10 D9 |

實作時的解讀(設計沒寫死、照最保守且最少機制的讀法定案;都有測項):
- T1 三輪都連不上 → T2 **緊接**(不再等輪距 15 s;§2「接著做」),D9 的 279 s 依此算。
- 13 的重試碰到總時限 → 以「節點上鎖尚未完成」結束(不是「找不到」)。
- 「OK 但沒有可用憑證」與「3 以外的其他碼(6、11、未知碼)」都只拿到 `ClaimReplay::Unknown`(batman-proto 不改),文字一律「節點回覆
  無法辨識,紀錄先保留」(中性);3 / 4 =「節點拒絕了這次恢復,已停止、不再重試」。
- 恢復寫出的 node 紀錄與認領同一個產生器(key 1–9,+ dev 版軟體 owner_enc 的 key 10 標記,s1 §4.1),key 9 = 磁碟上那份 pending 明文的
  SHA-256。
- 寫出前 45 s 從開始連線算(含連線),是比「從 claim/begin 起算」更嚴的讀法。
