# 254-app-remove-member.md v1 — 審查 A(正確性 / 介面 / 生命週期 / 現場)

審查對象:WSL /home/yello/Batman-app docs/design/254-app-remove-member.md v1(app feat/254-app-s1 @ 6574ca4);節點 Batman-p3 fbc01ae(NU v4.1)。唯讀,未上機。

## 0. 事實核對(R1–R19)

| # | 結果 | 備註 |
|---|---|---|
| R1 | ✅ | netrec.rs:1-11、:183-252;k9 = 第一台節點的 secrets,只有 joinflow.rs:288 的 resend(pending 紀錄)讀它 |
| R2 | ✅ | netrec.rs:47-58、:265-278 |
| R3 | ✅ | netrec.rs:281-283(v1_members 讀 k8) |
| R4 | ✅ | store.rs:1-11(回滾 ⚠️ 註明為已知缺口)、:34 CAS 鎖 |
| R5 | ✅ | Keys.kt sign() 經 SignAllowList;ADMIN_LABELS 五個(SignAllowList.kt:11、:25);簽章不需使用者驗證 |
| R6 | ✅ | mrec.rs:1-8、:80-124 |
| R7 | ✅ | approve.rs:304-324(existing:+1 版、TooOld、SameVersionDifferent) |
| R8 | ✅ | approve.rs:156-157、:204-216、:281-286 |
| R9 | ✅ | cose.rs:~110-136,key 5–7 寫死空陣列 |
| R10 | ✅ | netrec.rs:38-44;invite.rs:217-221、:283 |
| R11 | ✅ | invite.rs:143-153 |
| R12 | ✅ | netrec.rs:20 |
| R13 | ✅(補充) | app 分塊 max_msg = conn.rs:12 `MAX_MESSAGE = 8192`,與 provd MaxMsg 相同,所以用 app 分塊器算 8 塊是對的;provd MaxChunks = 8(session.go:94、:531) |
| R14 | ✅ | noise.rs:3-4 只有 owner / replay PSK |
| R15 | ✅ | provd/session.go:79-82:RoleOwner 與 RoleMember 都允許 network/update |
| R16 | ✅ | 219-protocol.md:368 |
| R17 | ✅ | mrec k7 單一;approve.rs:319-323 另一個 DAC → 新項取代 |
| R18 | ✅ | bridge/src/api/owner.rs:119-141(「不會撤銷這台已拿到的網路金鑰」) |
| R19 | ✅ | member-join.md:107;leave.md:70 |

另核對的行為(設計依賴但未列為 R):
- 節點 `netJoin` 接受任何版本的 net_config,只要由它自己的 admins 簽(node.go:1035-1052 adminsOf;parseNet 只要求 version ≠ 0,:986)→ 換密碼後的新邀請 / join2 / 隊員模式加入以 v2 入網可行。✅
- owner session 會 pin 節點紀錄裡的 DAC(loginflow.rs:1-5、End::CertRejected)→ NU §3「所有成員 session 要 pin DAC」在只用 owner session 的本設計下自然滿足。設計沒寫出這個推論(MINOR-14)。
- `flow::join_state`(flow.rs:132-150)只看 key 10 / 11,**不看 key 9**(MINOR-6)。
- 舊版 decode 忽略未知 key:netrec::decode 只 get 已知 key(:213-252)、member_of 只讀 1-6/8/9(:167-180)、MNet::decode 只讀 1-8(mrec.rs:108-124)→ §5 降級列的「打得開」✅;encode 只寫已知 key → 寫回即丟 k13/k14/k10 ✅。

## 1. NU §3「app 必須處理」逐項對表

| NU §3 項目 | 設計 | 判定 |
|---|---|---|
| 成員 session pin DAC | 只用 owner session(已 pin) | ✅(要寫出推論) |
| 不能只靠錯誤碼 / 版本號判斷(F17/F18) | 一律重讀 info;但只看 k9,沒說明為何單一網主下版本號足夠 | ⚠️ → MAJOR-3 |
| 轉送後 session 被斷、2 槽位 | 不用 member session | ✅ 不適用(要寫) |
| info 分支:沒有 9/10、10 非本網、11 長時間 true、送前版本卻回 STALE/BAD、**k9 > 目標** | 前幾項有;**k9 > 目標沒有** | ❌ → MAJOR-3 |
| 換 SAE + net_root(LoRa PSK 若有) | SAE、net_root 有;LoRa 沒提 | ⚠️ MINOR-12 |
| 審核加入申請時擋 removed 名單 | **沒有;§0 反而說被移除者可重新邀請** | ❌ → MAJOR-2 |
| 先寫紀錄再送;同版只簽一次 | 有(k14) | ✅ |
| **新版號 = max(紀錄, 各節點 info k9) + 1** | **用紀錄版本** | ❌ → MAJOR-3 |
| 不帶 key 7 | 有 | ✅ |
| 提示改手機 AP 密碼 | 有(§6) | ✅ |
| > 8 塊不送 | 有 | ✅ |
| 保存歷代;member_list_payload 帶 removed | k13 / mnet k9;§2.4 key 5 | ✅(cose.rs 要加參數,寫進實作清單) |
| approve.rs 同版 admins | 本單不換 admins → 寫明 | ✅ |
| 畫面列出停在舊版的節點 | 只有自己的節點(誠實寫出) | ✅(但「結束」後見 MAJOR-5) |
| **網路裡還有 wsl.24 節點時不得開始** | 只在回 E_BAD_OBJECT 後提示 | ❌ → MAJOR-4 |
| update 也用於改頻道 / 名稱 | 範圍外,寫明 | ✅ |
| 絕不改國碼 | 有 | ✅ |

## 2. 發現

### BLOCKER-1 成員漏掉一份更新包之後沒有任何恢復路徑
- 情境:網主為 C 產包 → 複製 → §3.3 立刻把 C 各節點項的 k10 設為目標 v2。C 沒收到(剪貼簿被覆蓋、訊息沒送達、C 晚了好幾天才處理而且弄丟)。網主之後按「結束」再移除 D(v3)。為 C 產的包鏈從 k10 = v2 的下一版起,只含 v3;C 的 mnet 在 v1 → §3.4「你的資料太舊,請網主給你從 v2 起的更新包」。但網主沒有任何地方能指定起點:「重新產生更新包」也是「用 k13 與該項 k10」(§3.3 末),仍從 v3 起。
- 退路也不存在:C 改走「重新邀請」→ 新邀請的 netcfg 是 v3,C 的 mnet 是 v1 → approve.rs:313-314 `TooOld`;app 沒有刪 mnet 的動作(leave.md §4「mnet 一律不寫」)。C 的節點可以 leave,但手機紀錄永遠卡住,只能重裝 app(連帶失去他名下節點的擁有者紀錄)。
- 根因:k10 的意義是「已複製」(推定),卻被當成「成員已知版本」(事實)使用。設計自己在 §3.3 寫了「已複製 ≠ 已換好」,仍用它推進 k10。
- 修法(只改語意,不加機制):k10 只在**能證明**成員拿到時設定 —— 也就是同意時那一版;產包一律從 k10 的下一版到目標,成員端 §3.4 已會「去掉已有的部分」。鏈只到手機,不受節點 8 塊上限;剪貼簿沒有大小問題,QR 大小本來就交給相機那案。若要縮小,最多讓網主選「從 v… 起」,但不要在複製時推進 k10。
- 測試:T8 加一臂「網主曾為 C 產過 v2 包但 C 仍在 v1」→ v3 包含 v2、v3,匯入成功;負對照:舊語意(複製時推 k10)→ 匯入拒絕且網主產不出可用的包。另把「mnet 落後 ≥ 2 版的人再被邀請 → TooOld」寫進誠實界線。

### MAJOR-1 換密碼前發出的未用邀請沒有作廢;網主端照樣同意並佔一個名額
- 情境:網主在 v1 發邀請給 E(k12 unused)。換到 v2。E 送來加入申請 → 網主端 check_joinreq(approve.rs:69-86)只看 k12 的 hash / used、DAC 是否已在清單,**不知道邀請是哪一版發的**,照樣通過;ApproveFlow 用目前的 k8(v2)與 v2 secrets 簽,把 E 寫成 approved、邀請標 used(approve.rs:156-184)。E 匯入時 bind() 用 mpend 的 netcfg(v1)驗 → same_net 版本不符(approve.rs:261-262)→ 拒。
- 結果:網主看到「已同意」,E 看到錯誤;網主清單多了一個永遠不會加入的 approved 項 —— 它算進 16 人上限(invite.rs:190),而且依 §2.4 會被列進**下一版**的已簽成員名單、並排進 k14 等更新包。設計 §3.6 說「同意時 bind() 會失敗 → 顯示已失效」,但 bind() 在加入者那邊,網主那邊沒有任何失敗。
- 修法:換密碼的那次紀錄寫入同時把 k12 所有 unused 項標成 used(或刪掉);check_joinreq 因此回 InviteUsed,網主端顯示「這張邀請在換密碼前發出,已失效,請重新邀請」。不需要新欄位。加入者端 `another net_id / version` 也對應到同一句。
- 測試:v1 發邀請 → 換到 v2 → check_joinreq 回 InviteUsed、紀錄不變;負對照:不標 used → ApproveFlow 產出同意、E 的 import 失敗、清單多一項。

### MAJOR-2 被移除者「之後由你重新邀請」的路徑沒有設計,三處會壞;與 NU「擋 removed 名單」矛盾
- NU §3:「之後審核加入申請時擋 member_list 的 removed 名單(節點擋不了)」。設計 §2.4 把被移除者的 DAC 放進 removed(每版繼承),但 §0 / §3.1 對話框說「被移除的人之後要重新加入,要由你重新邀請」,check_joinreq 也沒有檢查 removed。要擇一並寫清楚:
  - (a) removed = 永久名單 → check_joinreq 擋 removed 裡的 DAC,對話框改成「這幾台節點之後不能再加入」;
  - (b) 可以重新邀請 → 再同意時把該 DAC 從下一版 removed 拿掉(app 自己的紀錄規則,節點不讀),並寫明 removed 只是紀錄。
- 不論選哪個,重新加入本身會壞:
  1. 被移除者的節點**沒有離開**網路(仍在 v1),network/join 回 E_STALE_VERSION「already in a network」(node.go:1036-1038);隊員模式加入對回 5 用 join_state 判斷,而 join_state 只看 key 10(flow.rs:138-142)→ 顯示「已套用」,實際停在舊 SAE。要先 leave,畫面要說。
  2. 被移除者手機的 mnet 停在 v1:新邀請是 v2 → existing() 視為 +1 版接受(沿用舊 me);是 ≥ v3 → TooOld,沒有刪 mnet 的動作 → 卡死(同 BLOCKER-1 的退路問題)。
  3. 被移除者的手機永遠不知道自己被移除(§3.7 只在他匯入別人的包時才顯示),狀態頁一直顯示「已加入網路」。
- 修法:寫出「重新加入」的完整步驟(先離開 → 舊 mnet 怎麼處理:例如匯入新邀請時若 mnet 落後且使用者確認,允許新邀請取代舊 mnet —— 這是 existing() 的一條規則,不是新機制),或明說本版不支援、要重裝。並決定 removed 的語意。
- 測試:依決定,(a) removed 裡的 DAC 申請 → 拒,負對照:不檢查 → 通過;(b) 再同意後下一版 removed 不含它。加 TooOld 臂。

### MAJOR-3 新版號沒有取 max(紀錄, 節點 k9)+1;k9 > 目標沒有分支;「只看版本號」的理由沒寫
- NU §3 明列:「新版號取 max(app 紀錄的版本, 各節點 info key 9)+ 1」與「key 9 > 目標時不可無限追」。設計 §2.4 用「v = 紀錄的目前版本」,§3.2 只有 k9 = 目標 / k9 < 目標兩支。
- 情境:store.rs:8-11 自己註明回滾到舊檔仍打得開。紀錄若倒退,app 會重簽一份不同的 v(n),自己的節點(已在 v(n))回 E_STALE_VERSION / E_BAD_OBJECT,§3.2 顯示「沒有換成功,可再試」,使用者一直重試;成員節點先收到哪份就套哪份(F18)。
- 修法:§3.1 開始前用擁有者連線讀自己(可連上的)節點的 info k9,取 max;任一台 k9 > 紀錄版本 → 不開始並告警(不自動處理)。§3.2 加 k9 > 目標 分支(告警、不重送)。並在 §3.2 寫明:owner session pin DAC、網主只有一位、同版只簽一次 → k9 = 目標足以判定(F18 的拼接需要第二位簽署者,本單不支援共同網主)—— 這就是 NU「不能只靠版本號」在本設計下可接受的理由。
- 測試:自己的節點 info k9 = 紀錄 + 1 → 不開始、0 次簽章;負對照:用紀錄版本 → 產出 v(n) 並送出。k9 > 目標 → 告警不送。

### MAJOR-4 wsl.24 節點:NU 說「不得開始」,設計只在失敗後提示
- NU §3:網路裡還有 wsl.24 節點時不得開始(info key 4)。wsl.24 有 F10:secrets 不綁版本,被移除者能在它身上用舊 secrets 配新的 net_config —— 新版 netcfg / members 是公開物件,剪貼簿 / 聊天裡就有。後果:wsl.24 節點回報 k9 = 目標但 SAE 是舊的,§3.2 / §3.4 的「k9 = 目標 → 已確認」在 wsl.24 上**會被騙**。
- 網主看不到別人的節點,所以「全網沒有 wsl.24」這個前提在使用者決定的轉交模式下無法完整檢查 —— 要明說。
- 修法(最小):(1) §3.1 開始前,網主自己可連上的節點若是 wsl.24 → 不開始;(2) 產包與匯入畫面提示「節點軟體要先更新到 wsl.25 以後」;(3) §3.2 / §3.4 **送之前**讀 info k4,wsl.24 以前 → 不送;(4) k4 的解析規則(格式 `1.5.14-wsl.24+…`,解不出 / 缺 → 不送,fail-closed)寫清楚;(5) 誠實界線:別人的節點是否已升級,網主無法得知。
- 測試:k4 = `1.5.14-wsl.24+…` → 不送;`…wsl.25…` → 送;`xyz` / 缺 → 不送。負對照:只在 E_BAD_OBJECT 後看 k4 → 送出。

### MAJOR-5 「結束」之後,自己落後的節點沒有路徑;而第二次移除強迫先結束
- 情境:網主有兩台節點(一台在車上關機)。§3.1 前置 3:有 k14 就不能開始下一次移除,所以要移除第二個人就必須先「結束」清 k14。§3.3 說結束後只能對**成員**「重新產生更新包」;自己那台關機節點之後開機,沒有任何畫面會送它。成員端有「把新密碼送給節點」(§3.4),網主端沒有對應的。
- 修法:把「節點 k9 < 紀錄版本 → 狀態頁顯示『把新密碼送給節點』」做成一般規則,網主與成員同一條(網主用 k13 組鏈、k5/k6 產 secrets;成員用 mnet k9),與 k14 無關;k14 只留「本次要給誰產包」的清單,k14 key 4(自己的節點子表)可刪。
- 測試:結束後自己的節點 k9 < 紀錄 → 按鈕出現、送出後消失;負對照:沒有這條規則 → 沒有按鈕。

## 3. MINOR

1. **k13 補項要取 k7 實際版本**:§2.1「沒有 k13 = 只有 v1(由 k7/k8 補一項)」—— 降級到舊 app 寫回後 k7 是 v2、k13 不見;照字面會把 v2 物件標成 version 1。改成 version = k7 payload key 2;節點 k9 比 k13 最早一項還舊 → 「落後太多」同一句。T3 / T10 加這臂。
2. **前置要加「紀錄 applied」**(同 invite.rs:182-184):pending 紀錄的 k9 仍被 joinflow resend(joinflow.rs:288)使用。
3. **T4「簽章次數 = 0」與 §3.1 矛盾**:net_secrets / member_secrets 是 Sign1,每次重產都要 SignAdmin;「只簽一次」指 netcfg / members。§3.1 開始時就為每位成員產 secrets 又不存 → 刪掉,只在送 / 產包時產。T4 改為「netcfg / members 不重簽、bytes 與 k13 相同」。
4. **「ECDH 由 Kotlin」只對成員端成立**:網主端加密給 owner_enc_pub 是 Rust cose::encrypt_to(臨時金鑰,approve.rs:212)。§3.1 更正。
5. **成員端 §3.4 邊界**:(a) mnet 沒有 k7(NeedsNewInvite 後)→ 規則 3 必失敗,要一句話;(b) 成員節點從沒入網(k7 joining / approved 未加入)→ 應走隊員模式加入(用 mnet 目前版本,節點接受 v2),畫面要導向它而不是 network/update;(c) 先貼更新包、還沒匯入同意包 → 句子應是「請先匯入網主的同意」;(d) 舊 mnet 沒有 k9 → 「已有的部分」只能比目前版本;(e) 重貼 / 重產的包:鏈全已有、secrets 位元組不同 → 寫明「已有、不寫」或覆蓋 k5;(f) 成員已在目標版本時 kind 4 key 2 為空,違反 `[+ …]` → 改成不產包。
6. **join_state 不看版本**(flow.rs:132-150):換密碼後隊員模式「加入」對舊版節點回 5 → 判「已套用」;狀態頁「已加入網路」也不分版本。隊員模式加入回 5 時應比 k9 與 mnet 版本,不同就導向「把新密碼送給節點」。leave.md:70 明寫「做 network/update 時要重看對話框的隊員句」—— 本設計沒有回應。
7. **被「忘記」的已同意項會在下次換密碼被靜默切掉**:R18 忘記 approved 只刪本機項;那台若其實已入網,下次換密碼不在 key 4、沒人給它包,等於被移除卻不在 removed、也不在確認對話框。忘記或移除的對話框要寫這句。
8. **一個人名下多台節點**:包 key 3 給每台一份,但 mnet 只記一台(k7),另一台沒有存放與轉交路徑 → 卡在舊版。今天 app 本來就只追一台(approve.rs:319-323),寫進誠實界線。
9. **k14 結構**:§3.2 的「略過」不在 k14 key 4 的 0/1 列舉(照 MAJOR-5 刪 key 4 即消失)。
10. **members payload 要寫死用 cose::Member(key 1–5)**:k11 的 member_value 把 device_id 放在 key 6(netrec.rs:144-146),CDDL member key 6 是 lora_pkc_pub,same_net 也放行 key 6(approve.rs:253)—— 誤用會簽出型別錯的 key 6。T1 加「每項恰為 key 1–5」。
11. **規格更正**:qr-kind 4 不在 219-protocol.cddl(:404-406 只有 1/2/3);kind 4 的 CDDL 與向量列進實作清單。
12. **LoRa PSK**:app 的 secrets 沒有 LoRa PSK(approve.rs:207-210),netcfg key 7 也沒設 → 寫一句「不適用」。
13. **219 §3.3**(219-protocol.md:78)「送出換密碼封包前另做一次新鮮的 peers/challenge」—— 階段 1 file 後端、owner session 已 pin DAC;寫一句不做的理由。
14. **寫出 owner session pin DAC 的推論**,以及「不用 member session → 2 槽位、psk-rotated 斷線不適用」。
15. **舊版成員 app 不認 kind 4、舊版加入者 app 不認 v2 邀請**(open_netcfg_v1)→ 升級說明。§5 降級列「舊 app 發不出邀請」不精確:舊 app 會發、會寫 k12,是加入者打不開。
16. **剪貼簿露出整份成員名冊**(名稱、owner_pub、owner_enc_pub、ecdh_pub)給同機其他 app;不是秘密,§6 寫一句。
17. **§3.6「在場 / 遠端邀請都帶 admin_pub」**:app 只有遠端邀請(invite.rs:23、:162),在場邀請未做,刪或標未做。
18. **其他流程寫回紀錄要保留 k13 / k14 / k10**:approve / invite / join2 / forget 都 decode → encode 整份紀錄(approve.rs:184、owner.rs:131);加測試:k14 存在時跑 approve / invite / forget → k13 / k14 / k10 不變。

## 4. 測試計畫

- T13 / T14 只用 04 + 02 就能做出真的負對照,不必靠「測試注入的成員項」(那是進產品程式的測試入口;若保留,只限 dev-trust build):建網(04,dev)→ 邀請 02(dev2)→ **移除 dev2 這個人** → 04 換到 v2、02 停在 v1 → batman 鄰居消失(被移除者真的被擋);再由 dev 重新邀請 02(同時驗 MAJOR-2 的重新加入);「成員轉交」的正向路徑則需要第三人,才用注入。
- §7 mutation 清單加:複製時推進 k10、不作廢未用邀請、用紀錄版本而非 max、wsl.24 只在失敗後看。
- T5 列出 NU §3 回應碼表每一列 × info(k9 <、=、> 目標;k10 缺 / 他網;k11 true;info 被限速 9–11 整組缺)。

## 5. 判定

BLOCKER 1、MAJOR 5、MINOR 18。**REJECT**:BLOCKER-1 與 MAJOR-1/2 在現場會造成永久卡死或幽靈成員;修法都是改語意或加一條檢查,不需要新機制。修完請整份重審。
