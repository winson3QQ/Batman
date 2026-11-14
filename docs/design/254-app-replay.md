# 254-app-replay — 把 claim REPLAY 接進 app(v3,待審)

對應:#254;凍結設計 `254-app-s1.md` §5.1 / §5.2 / §5.3、`254-app-claim-noover.md` v2.1。v2 被兩位審查者 REJECT,本版整份重寫;
對照表在 §13。行號 = `feat/254-app-replay` @ eb9d07b(程式碼與 main f0138bd 相同)。節點路徑省略前綴 `feed/batman-prov/src/`,
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
| N3 | psk_replay 只在**恰好一位擁有者**時存在;握手用的 state 與 PSK 集合是快取:state 在下一次輪詢更新(PollEvery 4 s + CtlWait 10 s),PSK 在 ops 空閒時重拉 → 剛認領完的節點有一小段時間對 psk_replay 回假 msg2 | node/node.go:438;provd/server.go:21-22, 454-481, 710-719 |
| N4 | 角色表:RoleReacquire = {info, claim/begin, op/nonce, claim/replay};**RoleOwner 沒有 claim/begin、claim/finish、claim/replay** → 回 3,不計數、不斷線 | provd/session.go:75-84, 650-651 |
| N5 | claim/finish 的 OK / 13 都讓 session 成 owner;9 **只**在這裡產生(helper 拒絕);無 begin / 逾 55 s → 3;ops 忙 / helper 逾時 330 s / 斷 → 7 | provd/session.go:777-821, 609-628;provd/server.go:23, 28 |
| N6 | op/nonce 在 RoleReacquire 不經 helper:只回 OK 或 3(無 begin / 逾 55 s),3 不計數 | provd/session.go:757-766 |
| N7 | claim/replay:nonce 不論結果都作廢;ops 錯 → 7;OK / 13 → 成 owner 並 `killOthers`;其他 → 照 mapHelper;helper 拒絕(3)在同一連線累計 3 次 → 回覆後斷線 | provd/session.go:678-701, 577-582, 586-600 |
| N8 | `killOthers` 砍掉**所有**其他 session:未認證的、member 的、HTTP 的都算 | provd/server.go:848-860 |
| N9 | helper 的 claim.replay:先看失敗數,近一小時 ≥ 10 → 12(**正確的 replay 也被擋**);失敗計數只在記憶體;擁有者 ≠ 1 / 信封壞 / owner-op / CheckMac 失敗 → 計一次;成功必定產生新 root 密碼;13 只來自 setPassword 失敗,不計數 | node/node.go:126, 617-631, 632-657, 661-665, 496-534 |
| N10 | 已認領的 STATUS 不帶末四碼;有任何 BLE 連線時節點**收回廣播** | provd/server.go:599-615;cmd/batman-provd/bluez.go:772-776 |

所以 claim/replay 不可能回 9;4 與 10 只會經 mapHelper 轉傳(claimReplay 本身不產生;⚠️ helper 的 dispatch 層沒有逐行排除)。

**app(✅ 讀碼)**
- `rust/batman-proto/src/replayflow.rs`:`Replay::start(pending, frame_limit)` → Ecdh → `ecdh_done(z)` 產生 msg1 → claim/begin → op/nonce →
  Sign → claim/replay;結局 `Replayed(Recovered|Reconnect|RateLimited|Refused|Unknown)/Msg2Undecryptable/CertRejected/Refused{verb,outcome}/Broken`
  (l.63-66, 73-92, 130-151;flow.rs:87-95)。bridge、Dart 都沒接。
- `claimflow.rs`:claim/finish 的 frame 在 `on_begin` 交出(l.188-191);`End::Broken` 在交出前後都可能出現,**現在分不出來**。
- `lib/claim.dart`:`_find`(l.116-164)逐台連線讀 STATUS,只回「未認領且末四碼相符」,只記 `d.id`、不記 RSSI,60 s(l.36);`_held`
  (l.170-203)在任何 BLE 之前比 K(l.188,只在「只有 pending」時);`_claim` 等 90 s(l.300);`_ClaimPageState` **沒有 `dispose()`**。
- `flutter_reactive_ble` 5.6.0 的掃描結果帶 `rssi`(reactive_ble_platform_interface `discovered_device.dart:43`)。
- Kotlin `ecdh` = owner_enc 私鑰 × peer(Keys.kt:103-106),**只有 dev 版開放**(EcdhPeer.kt:39-40;MainActivity.kt:121-127)。
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
- **K 在哪裡比**:`ClaimRecovery` 開始時從磁碟重讀 pending、開封、`pending_matches_qr`(claim.rs:124-129),T1 / T2 都做;不同或讀不到 →
  不 replay。(`_held` 的比對只涵蓋「只有 pending」,nodeAndPending 沒比過。)
- **T3 的問題**:「沒找到未認領的這台。手機裡有它一次沒完成的認領,可以試著恢復:恢復會更換這台節點的 root 密碼,並中斷它目前
  所有的連線(包含隊友手機的)。如果它在『我的節點』還能用,不需要恢復。要恢復嗎?」這時 R7 的「重新認領」已經問過一次;兩次問的是
  不同的事(R7 = 用新認領取代紀錄;T3 = 對可能正常運作的節點換密碼),R7 文字不改。
- T1 不問:能走到 finish 表示節點剛才以 NX 應答 = 未認領,舊 node 紀錄的憑證已無效(noover F13)。沒有 node 紀錄也不問:這支手機
  從沒拿到憑證 → 沒人能讓這台加入網路(network/join 只有 owner,session.go:78)→ 被 N8 砍的只會是未認證連線。⚠️ 例外未驗:
  node 紀錄若被手動「忘記」過(本版沒有這個 UI)。

## 3. 一次恢復(`ClaimRecovery`,一次「認領」最多一個)

1. 讀 pending(§2)、解碼(§5)。dev 版才繼續(`devTrust`);`ecdh(pending.ecdh_pub)` **在任何連線之前做一次**,z 交給 bridge 的
   `ReplaySession` 保存(Rust 記憶體,結束時清零),Dart 那份立刻 `fillRange(0)`。失敗 / field 版 → 「這個版本的 app 還不能恢復中斷的
   認領(紀錄先保留)」,不連線。
2. 每一台:連線(逾時 15 s)→ MTU → CTRL → `ReplaySession.begin(frame_limit)`(內部 `Replay::start` + `ecdh_done(z)`,batman-proto 不改)
   → 寫 msg1 → 依 §4。**每台上限 45 s**(< nonce 55 s,N6),到時斷線、視為「沒有回覆」。
3. 節拍:同時 1 條;兩次握手的開始相隔 ≥ 10 s(= s1 §5.3 的 6 次/分)。
4. **T1 的一輪** = 對那一台試一次。**T2 的一輪** = 掃描 6 s(不讀 STATUS)→ 依 RSSI 取前 6 台 → 逐台試,直到有一台的 msg2 解得開;
   每輪重新掃描(N10:有人連著的節點不廣播 → 下一輪才看得到)。一旦某台解得開且 DAC 相符,它就是對象:之後的輪次只試它。
   最多 3 輪,輪與輪相隔 ≥ 15 s。超過 6 台 → 提示把手機貼近節點。
5. **總時限 300 s**:過了就不再開始新的一台(進行中的做完,所以最長 345 s)。
6. **進度**:每台一行「恢復中:第 r/3 輪,第 i/n 台」;恢復期間「認領」鈕換成「停止恢復」。
7. **取消**(按「停止恢復」、離開頁面 = 新增的 `dispose()`):設旗標。還沒寫出 claim/replay → 立即斷線結束;已寫出 → 等這一台的回覆
   (最多到 45 s 上限)再結束,拿到憑證照樣寫紀錄(節點已換密碼,丟掉回覆只會多一次輪替)。寫紀錄不需要頁面還在。
   app 進背景:不另外處理,計時照走;⚠️ 背景下 BLE 是否延遲未驗。被系統殺掉 → pending 還在 → 下次按「認領」走 T2。

## 4. 結果表(`replay_next(步驟, 結果) → 動作`,全函式;沒列到的一律「停止」)

| 步驟 | 結果 | 動作 | 節點計失敗? |
|---|---|---|---|
| 連線 / msg2 | 連不上、逾時、沒有 msg2 | 下一台(T1:下一輪) | 否 |
| msg2 | 解不開(不是這台、未認領、N3 的快取空窗、擁有者 ≠ 1、重燒) | **立即斷線**,下一台(T1:下一輪) | 否 |
| msg2 | CertRejected(解得開但 DAC ≠ pending) | 全部停止:「節點身分與認領紀錄不符」 | 否 |
| claim/begin、op/nonce | 7、10;op/nonce 的 3(N6) | 斷線,下一輪再試這台 | 否 |
| claim/begin、op/nonce | 其他(含 claim/begin 的 3 / 4、6、11) | 停止(中性文字) | 否 |
| 任何 | claim/replay **寫出前** Broken / 斷線 | 下一輪再試這台 | 否 |
| claim/replay | 寫出後沒有回覆(斷線、45 s) | 下一輪再試這台(節點可能已換密碼;之後成功拿到的是最新的) | 不明 |
| claim/replay | OK + 憑證 | §5 寫紀錄,結束:「已恢復;root 密碼已更換,先前抄下的密碼失效」 | — |
| claim/replay | OK 但沒有可用憑證 | 停止:「節點回覆無法辨識,紀錄先保留」(再試只會再換密碼) | — |
| claim/replay | 13 | 斷線 → 15 s → 新連線再 replay;連續 ≤ 5 次,之後停:「節點上鎖尚未完成,請稍後再試」 | 否(N9) |
| claim/replay | 12 | 停止:「恢復被擋 — 可能有人在附近干擾,請換地點或稍後再試」(s1:247 原文) | — |
| claim/replay | 7、10 | 下一輪再試這台(7 可能是「結果不明」,同「沒有回覆」) | 否 / 不明 |
| claim/replay | 3、其他(4、6、11、1、2、未知碼) | **停止,不重試**(中性文字) | 3 與 11(信封)會 |

- 一次「認領」最多造成 1 次確定被計的失敗(第一次被拒就停)+ 至多 2 次「沒有回覆」的不明結果;N7 的同一連線第 3 次拒絕斷線因此碰不到。
- 3 輪或 300 s 用完沒有結果:T1 且 finish 回的是 9 → s1 §5.1 的「QR 不符,或認領仍在收尾 — 請確認 QR 後稍後再試」;其他 → s1 §5.2 的
  「找不到這台或還無法恢復:請把手機貼近節點、確認節點開機後再試(節點也可能已重燒或被他人認領)」。pending 一律保留。
- claim.rs:271 的「節點已被別人認領」不符 s1 §5.2 的中性要求 → 改成上面 §5.1 那句;claim.rs:371 的斷言一起改。

## 5. 紀錄

- pending 解碼(bridge):輸入 = 開封後的明文;只收 key 1–7、長度固定、**device_id 必須等於路徑上的 id**;不合 → 不 replay、pending 不動。
- Recovered → 現有的 `ClaimRecords.claimed()`(claim_records.dart:77-87):舊 node 紀錄複製到一旁、寫新紀錄(key 1–9 與認領相同,
  claim.rs:242-253)、再刪 pending。複製失敗仍寫(新密碼是唯一有效的)。
- 其他結局:不寫 node 紀錄、pending 不動。

## 6. 擁有權

| 資源 | 唯一寫入者 | 其他 |
|---|---|---|
| `claim-pending/<id>`、`node/<id>`、`forgotten-*` | `ClaimRecords`(認領與恢復共用) | `ClaimRecovery` 只讀 pending;nodes 頁唯讀 |
| 認領頁的 BLE 連線與掃描 | `_ClaimPageState`(`_busy` 期間;`_find` 與認領的連線結束後,才由它建立的 `ClaimRecovery` 接手) | nodes 頁是另一個 route(main.dart:124-128),⚠️ 推論:不會同時握手 |
| 候選清單(id、RSSI)、輪數、節拍、時限、取消旗標 | `ClaimRecovery`(記憶體) | 頁面只設取消旗標、讀進度 |
| z、psk_replay、K 的明文 | bridge `ReplaySession`(Rust 記憶體,drop 時清零) | Dart 只經手 z 一次 |
| root 密碼、失敗計數、session、PSK 集合 | 節點 | app 只從回應碼得知 |

## 7. 契約

| 介面 | 寫 / 讀 | 何時有效 | 缺 / 壞 / 過期 | 誰寫得到 |
|---|---|---|---|---|
| `ClaimSession.replay_due()` | bridge / claim.dart | 認領以任何方式結束之後 | 例外 → 當 false(不 replay;下次 T2) | 只有 app 自己 |
| pending 紀錄 | ClaimRecords / ClaimRecovery | 落盤後 | §5:不合 → 不 replay(fail-closed) | app 私有目錄 + Keystore 封存 |
| `ReplaySession`:`prepare(pending 明文, 路徑 id) → peer`、`set_z`、`begin(frame_limit) → frames`、`on_frame`、`signed` → 步驟(寫 / 簽 / 結束(列舉 + 文字)/ Recovered(node 紀錄)) | bridge / ClaimRecovery | 一次恢復 | 結束文字不含 z / K / psk / 密碼(測項掃字串);未知結局 → 停止 | 只有 app 自己 |
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
| 恢復中離開頁面 / 按停止 / app 被殺 | — | §3-7 | D6 |
| 藍牙關 / 沒權限 | claim.dart:228 擋 | 不變(在 replay 之前) | 現有 |
| app 升版 / 降版 | — | pending 與 node 紀錄格式都不變;降回沒有 replay 的版本 = 現在的行為 | R3(round-trip) |
| field 版 | — | 「還不能恢復」,不連線 | D7 |
| 節點升級 / 回滾、iOS | — | 不適用:節點不改;iOS 不在 S1 | — |

## 9. 安全

- **資產**:節點控制權(root 密碼、owner session)、K、z、psk_replay。
- **附近 / 遠端攻擊者,以及手機上其他 app(都能假冒廣播)**:沒有 owner_enc 私鑰算不出 psk_replay → msg2 解不開 → 我們只送過 msg1
  (臨時公鑰 + tag;⚠️ 依 Noise 規格,不含身分)。能做的只有拖延:用強訊號佔滿每輪 6 個名額。上限 = §3 的 345 s 與 3 輪;不能造成
  節點計失敗(§4)。這個拖延擋不掉,明寫為已知限制。
- **被攻陷 / 別人的節點**:握不到 psk_replay → 同上;DAC 不符 → CertRejected。
- **我們自己的錯**:無聲換密碼、砍隊友連線(N8)→ T3;把節點推到 12(N9)→ 第一次被拒就停;對錯的裝置 replay → T1 只對同一個 id。
- **新增的輸入**:掃描結果(id、RSSI,只用來排序)、msg2 與回應(§4 全表)、磁碟上的 pending(§5 嚴格解碼)。沒有新權限、新連接埠。
- **權限**:app 自己的沙箱;沒有提權的程式碼。
- **祕密**:K、z、psk、root 密碼、tag key 不進 log、例外字串、畫面、argv;新密碼只進封存的 node 紀錄。z 在 Kotlin 回傳後清零
  (MainActivity.kt:127)、Dart 交出後清零、Rust drop 時清零。
- **失敗方向**:一律 fail-secure — 不明結果不寫 node 紀錄、不刪 pending、不重試被拒的請求。
- **負向測試**:§10 的 S1–S3。

## 10. 測試與負對照(每項的負對照 = 拿掉括號裡的東西就 FAIL)

假節點(`tests/replayflow.rs`)改成照 N1–N9:未認領 → 假 msg2,長度斷言 = cert + 96(現在 l.113 是 cert + 112,多 16 B);成功每次回
不同密碼;成功或 13 之後同一 session 的 claim/replay、claim/begin → 3(不是 13);nonce 用一次就作廢;失敗計數跨連線、到 10 連正確的也
回 12;同一連線第 3 次拒絕後斷線。每個行為在測試裡註明 N 編號。

| # | 測項 | 層 | 負對照 |
|---|---|---|---|
| R1 | `replay_due` 全表:finish 交出前後 × 每個結局 / 每個碼 | Rust | (「已交出」旗標)→ 交出前的 Broken 也觸發;(排除 7)→ 7 觸發 |
| R2 | `replay_next` 全表:§4 每列 + 未知碼 → 停止 | Rust | (預設停止)→ 未知碼變成重試 |
| R3 | pending 解碼:key 多 / 少、長度錯、id ≠ 路徑;`pending_record()` 的產物 round-trip | Rust | (id 檢查)→ 別台的 pending 被接受 |
| R4 | 假節點快取空窗:第 1 輪解不開、第 2 輪 Recovered | Rust | (下一輪)→ 第 1 輪就結束 |
| D1 | T1 只連認領用的那個 id,旁邊有另一台「已認領」的假裝置 | Dart 假 BLE | (只對同一 id)→ 連到另一台 |
| D2 | T2:不讀 STATUS、依 RSSI、每輪 ≤ 6、每輪重掃、解得開後只試那台;全部解不開 → 中性文字 | Dart | (排序 / 上限 / 重掃)各一 |
| D3 | 症狀:節點已認領、手機只有 pending → node 紀錄存在,且用它存的 tag key 與最後一次的密碼能登入假節點 | Dart | (replay)→ 60 s NOT_FOUND、沒有 node 紀錄 |
| D4 | T3:有 node 紀錄才問;取消 → 零連線、紀錄不變 | Dart | (T3)→ 直接連線 |
| D5 | 第一次被拒就停;13 最多 5 次;12 的文字 | Dart 假時鐘 | (停止規則)→ 第 2 次 replay 被送出 |
| D6 | 總時限、進度行、停止 / dispose:寫出前立即斷,寫出後等回覆並寫紀錄 | Dart 假時鐘 | (旗標)→ 繼續連下一台 |
| D7 | field 版(`devTrust` false):零連線 | Dart | (檢查)→ 有連線 |
| S1 | 10 台假裝置回亂數 msg2:每台只收到 msg1 就被斷線,每輪 ≤ 6 次握手 | Dart | (立即斷線)→ 連線留著 |
| S2 | DAC 不符 → 停止,之後零寫入 | Rust(現有 l.313-328) | 已有 |
| S3 | 所有結束文字與 log 掃不到 K / z / psk / 密碼的 hex 與原文 | Rust + Dart | 故意把密碼放進文字 → FAIL |

**真機:❌ 全部未做**(需要使用者授權動手機與 04)。計畫:
1. 負對照(先做):04 與 S20 維持 §0 的狀態,用 main f0138bd 的 dev APK、同一張 QR 按「認領」→ 預期 60 s NOT_FOUND、沒有 node 紀錄。
   ⚠️ 這一步目前只由讀碼推得(claim.dart:156);§0 的留言沒有寫到實際再按過一次。
2. 驗收:換成本功能的 dev APK(⚠️ 覆蓋安裝要保住 pending,未驗)→ 同一張 QR → T2 →「已恢復」→「我的節點」登入成功 → 經 app 放回 lab key。
3. T1(finish 後斷 BLE)、13、12、快取空窗的真機做法還沒有 → 留在 #254 checklist,PR 內標 ⚠️ 模擬。

## 11. 與凍結設計(254-app-s1)的偏離

| s1 | 本版 | 理由 |
|---|---|---|
| §5.2:每個 device_id 每小時 ≤ 3 次被拒的 replay | 沒有計數器;每按一次「認領」最多 1 次被拒 | 不必存計數;使用者一小時按 10 次仍會到 12(N9),由 12 的文字說明。`flow.rs:75-81` 的註解(「app 的 3 / 小時」、`session.go:653-657` 行號、「3 次斷線」)一起更新 |
| §5.2:結果不明 → 先 NX、再 replay | T1 直接 replay,不先 NX | NX 由下一次按「認領」的 `_find` 承擔;replay 對未認領節點沒有副作用(N1) |
| §5.3:候選 = STATUS ∈ {1, 2} 或讀不到;最近見過的先試;位址 → device_id 快取 | 不讀 STATUS、RSSI 排序、沒有快取 | 讀 STATUS 要每台多連一次;未認領的由假 msg2 排除;app 沒有「最近見過」的資料 |
| §5.3:握手預算與 psk_owner 登入共用 | 只管恢復自己的節拍 | app 裡沒有共用預算(`_login` 沒有節拍);兩者不同頁 |
| §5.3:認領後解不開重試 3 次 / 3 s | T1 等 15 s 再試、輪距 15 s | 15 s 同時涵蓋 state 快取(N3) |
| noover R7 / R7-2 | 文字不改;T2 + node 紀錄時多一次 T3 | §2 |

## 12. 寫回 #254 checklist(不開新單)與實作要動的檔

- [ ] field 版不能 replay(`ecdh` 只有 dev 版)→ 設計 field 的 ecdh 開放條件;`EcdhPeer.kt:12-15` 的註解補上第二個用途(replay 的 peer)。
- [ ] `nodes.dart` `_login`:握手節拍、離開頁面時取消;`claim.dart` `_find` 同樣沒有取消。
- [ ] replay 從 `forgotten-pending/` 取候選(noover §9,已在單上);沒有 QR 的「需恢復」入口。
- [ ] 真機:§10 的 1–3。
- 實作會動:bridge `claim.rs`(`replay_due`、文字)、新的 bridge replay API、`claim.dart`(`ClaimRecovery`、`dispose`、停止鈕)、
  `flow.rs` 註解、`tests/replayflow.rs`、`EcdhPeer.kt` 註解。`batman-proto` 的流程碼、節點、Kotlin 邏輯不動。

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

v2 有、v3 刪掉的:`keyLevels.recover` 契約(`ecdh` 的錯誤已足夠)、T1 的候選清單、「同 session 再 replay 得 13」。
