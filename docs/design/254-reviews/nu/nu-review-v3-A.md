# 審查 A 第 3 輪(正確性 / 介面 / 生命週期,整份):254-net-update-members.md v3 DRAFT

審查者 A,2026-11-10。先自己從頭審整份(從實際使用出發:網主手機對多台送、成員手機轉送、落後節點、wsl.24 升上來的節點、共用 `parseNet` 的 S1/S2/S3 入網),最後才讀 v1/v2 四份審查核對。對照:Batman-p3 `feat/254-p3` @ e5c89a1(工作樹只多這份未追蹤設計檔)、219-protocol.md / .cddl、provd / node 原始碼、provclient、harness 單元、向量 gen.py、Batman-app `batman-proto/src` @ 6574ca4。兩個 repo 全程唯讀,未碰裝置。基準測試在 WSL `/tmp/nurA3`(`git archive HEAD` 整棵複本)跑,跑完已刪(`ls /tmp | grep -c nurA3` → 0;`git status --short` → 只有 `?? docs/design/254-net-update-members.md`)。

**結論:APPROVE-WITH-CHANGES — 0 BLOCKER、1 MAJOR、7 MINOR。** 節點端 §2.1–§2.3 可以照做。唯一的 MAJOR 在 §3 規則 3:app 依它判「分叉 → 離開 + 重新入網」,但這個握手失敗的訊號不只來自分叉,而且整條路徑沒有任何測試。修法是改契約文字加一個測試,不需要新機制。依規則,修完要整份再審。

---

## ✅ 我自己驗過的事實

- **基準**(修改前,複本):
  ```
  ok  	batman-prov/node	26.005s
  ok  	batman-prov/provd	12.417s
  ok  	batman-prov/cose	0.004s
  ok  	batman-prov/proto	0.004s
  ```
- F1 行號:`netUpdate` `node.go:1072`;`ESchema "version chain"` `:1079`(設計寫 `:1080`,差一行);`VerifySign1` `:1093`;連續性 `:1101`;`parseNet(last, sec, adminsOfPrev)` `:1108`;`applyNet` 定義 `:1126`,`next := *rec` `:1145`。F2 `:1024-1041`、F3 `:1206`、F5 `:756-758`、F6 `:970-972`、F12 `adminsOf :1043-1070` ✅。
- F8 / F15:`mapHelperR`(`session.go:899-912`)先處理 `hEReject` / `hEInput` / `hEApply+reason` → `E_REJECTED{2: reason}`,其餘交給 `mapHelper`(`:567-582`):`hESchema` → CRIT + `E_REJECTED{}` ✅。設計用 `failR(EReject, 14)` 到 app 是 `E_REJECTED{2:14}` ✅(與 `settingsset.go:123` 同一條)。
- F9:`MaxChunks = 8`、`MaxReassembled = 65400`、`maxPlain = MaxMsg-16`(`session.go:92-97`);`total > MaxChunks` → `"chunk part"`(`:529-531`),而且**在第 1 塊就斷**(因為 `total` 欄位已經是 9);`MaxMsg = 8192`(`frame.go:15`);`MaxRequest = 65536`(`sock.go:25`)✅。
- F11 `session.go:613-621`、F16 helper `readonly.go:142` `{1 nid, 2 ver, 3 Left, 4 TxnPresent}` → provd `server.go:556-568` 只把 9/10/11 放進 info(Left 不出去)✅。
- F10 的成因在原始碼上成立:`decryptSecrets`(`wtxn.go:126-152`)的 KDF `other` 取自 secrets 自己的 payload;`openStoredSecrets` 的註解(`:116-117`)說「net_id / version binding stay」,實際上只綁 secrets 自己 ✅(PoC 數字沿用 v2 兩位審查的探針,我沒有重跑)。
- F13:`approve.rs:206-215`、`join2flow.rs:363-366`、`joinflow.rs:216-220`(v1)都以 net_config 的 net_id / 版本產 secrets ✅ → §2.2-5 不影響 S1–S3。provclient `netObjects` 也是同一個 `ver`(`net.go:189-197`)✅。
- F14:`netrec.rs:103` 必填國碼;rig `mkNet` 無 key 5(`wtxn_test.go:73-76`)✅。F19 `netrec.rs:20` ✅。`envelope.rs:13` 1 MiB ✅。
- §1 版本字串:scratchpad `toa24.log:3` = `payload version 1.5.14-wsl.24+e5c89a1.fw7ce6e80` ✅;`git diff --stat 832fbf8 e5c89a1 -- .../provstore` 空 ✅。
- wsl.24 收到新形狀:步是 map、不是 tag 18 → `VerifySign1` 失敗 → `E_BAD_OBJECT "chain link"`(`node.go:1093-1095`)✅,與 §3 表一致。
- 規則 3 用到的推導鏈在原始碼上存在:`psks()` → `PskMember(netRoot(rec), rec.Net.NetID, rec.Net.Version)`(`node.go:428-432`)→ provd `opsLoop` `psks.get`(`server.go:434-470`)→ `handshakeParams` 第 5 個候選(`:711`)→ `roleOfPSK(4) = RoleMember`(`:722-731`)。app 有 `kdf::psk_member`(`kdf.rs:39`)和任意 psk 的 NXpsk0(`noise.rs:71-92`)。**所以握手「做得到」**。但見 M1:沒有任何測試跑過這條路(`grep PskMember *_test.go` 只有 `proto_test.go:133` 的 KDF 向量;`realhelper_*_test.go` 沒有 join / update 之後的 member 握手)。
- 被移除者的舊 session:更新成功 → provd `invalidate()`(`session.go:656`)→ 下次 `psks.get` 後 `reconcile()` 對 `RoleMember` 比值不同就 `Kill("psk-rotated")`(`server.go:647-651`)✅。

---

## MAJOR

### M1. §3 規則 3「新 `psk_member` 握手失敗 = 分叉 → 這台只能離開 + 重新入網」:失敗的訊號不只來自分叉,一失敗就判分叉會讓 app 叫使用者把正常的節點重新入網;而且這條判準沒有測試
- **情境**:網主 app 對節點 L 送 v+1,收到 0、`E_BUSY outcome unknown` 或沒有回應 → 依規則 1 重連讀 info → key 11 = false、key 9 = 目標 → 依規則 3 立刻用 `psk_member(v+1)` 開 member session。
- **證據(原始碼,⚠️ 沒有實際跑)**:
  1. **provd 的 PSK 集合在更新後要等一會兒才換新**:`route` 在回應前呼叫 `invalidate()`,只設 `needPSK`(`server.go:598-601`)。新集合要等 `opsLoop` 下一個 500 ms tick,而且只在 ops 空閒時才去拿(`:434-440`)。`ERate`、忙碌或錯誤時「`the old set keeps serving`」(`:469`)。在這段時間裡,`handshakeParams`(`:690-719`)給 Respond 的還是**舊的** member psk。另一支手機對同一台送的請求只要讓 ops 一直忙,這段時間就會延長。
  2. **psk 對不上時,節點回的是假 msg2**:`Respond` 找不到 psk → `fakeMsg2`(`noise.go:89-96`),provd 照樣送出,然後等握手逾時(`session.go:404-412`)。app 看到的是 msg2 解不開。這和「節點的 net_root 不是我發的」(真分叉)在線上**完全一樣**。
  3. 其他同樣會讓握手失敗的情況:全域握手速率 20/min(`session.go:392-394`)、provd not ready(`:395-398`),以及連到假冒同名廣播的裝置(假冒者解不開任何 psk,對 app 來說也是「握手失敗」)。
  4. 規則 3 的「成功」也不完整:`psks()` 只從 secrets 導出(net_root + net_id + 版本),不看 net_config。所以拼接(F18 / v2-B m3:分叉的 cfg 配合法的 secrets)會讓握手**成功**,app 會判成「確實換上了新秘密」,但節點的 admins 已在對方手上。§5 寫「app 以 §3 規則 3 偵測」分叉與拼接,這對拼接是過度宣稱。
  5. 這是 app 要照著實作的判準,但目前節點端沒有任何測試證明「update 之後,用 psk_member(目標) 能開 member session;用 psk_member(舊版) 或別的 net_root 不能」。這是設計依賴的行為,卻沒有證據(全域規則第 4 項)。
- **為什麼是 MAJOR**:結論帶出的是破壞性動作(離開 + 重新入網,要擁有者在場、重新核對),而觸發它的訊號在正常操作裡就會出現(更新後馬上握手)。反方向,拼接會被判成功。
- **修法(只改契約 + 一個測試,不加機制)**:
  1. 規則 3 改成:握手失敗 → **不是結論**。等待(至少數秒,超過 provd 的 PSK 重抓週期)後再讀 info(key 11 = false、key 9 仍是目標),再試。只有在**同一次連線裡先用擁有者 session 證明對方是這台節點**(node_cert / DAC 對得上),而且新 psk_member 在數次重試後仍失敗時,才判定「這台的秘密不是 app 發的」。之後告警、讓使用者決定,不自動走離開。
  2. 規則 3 的成功只證明「秘密 = app 發的那份」,不證明 net_config。§5 的「偵測」要改寫:拼接偵測不到,這是 219 §7.1 的固有限制,前提是共同網主還在 v 版 admins 裡,而且要有轉送者把合法 secrets 交給他。
  3. 新增 **U16**(provd 層,真 helper):join v1 → update v2 → 等 PSK 重抓 → `psk_member(net_root_v2, v2)` 握手成功、role = Member;`psk_member(v1)` 與錯誤 net_root 的 psk 都拿到假 msg2(負對照)。這就是 app 判準在節點端的依據。

---

## MINOR

1. **§2.1 與 §4 / U5 互相矛盾**:§2.1 說「形狀錯一律 `EBadObject`,不用 `ESchema`」(U15 也這樣斷言),但 §4 升級列寫「舊形狀 → `E_SCHEMA`」,U5 寫「secrets 在非最後一步、最後一步缺 secrets、缺 members、步不是 map(舊形狀)→ 各自 `E_SCHEMA`」。這是 v2 → v3 沒改乾淨的地方;照 U5 實作會寫出和 §2.1 相反的斷言。修法:§4 與 U5 改成 `E_BAD_OBJECT`。另外 F1 的 `:1080` 應為 `:1079`。

2. **規則 2 沒有涵蓋「key 9 = 送出前的版本,卻回 `E_STALE_VERSION`」**(v2-A m5 只解了一半):起點版本號對、prev_hash 接不上 = 節點在同版號的另一支上(或 app 自己組錯起點)。app 依規則 2 找不到這個碼,只能重送、無限循環。同一位置的 `E_BAD_OBJECT` 也可能是分叉(節點的 `rec.Admins` 已經是對方的),不只是「需要更新軟體」。修法(用既有機制):規則 2 對 `E_STALE_VERSION` / `E_BAD_OBJECT` 先用 `psk_member(key 9 那一版)` 做一次 M1 的握手。成功 = 節點和 app 在同一支上,問題出在請求(或 wsl.24),照現在的處理。失敗(依 M1 的重試條件)= 節點在別支上,告警。

3. **§2.2-3 的嚴格度沒有讀者**(使用者「只做必要的修改」):members 不存(§2.3、F3),節點上沒有任何讀者;§2.2-3 卻要求 key 1–7 全部必填、拒絕未知 key、key 4–7 是陣列、第二步起 prev 鏈接得上,各帶一個 mutant。反過來,net_config **會被存、會被讀**,它的未知 key 卻不拒絕(F12,延到 checklist)。嚴格度剛好用反了。修法(請使用者決定):保留「網主簽、net_id、版本 = 該步」(這三項讓轉送者不能換步、換版),其餘結構檢查可以拿掉;或者保留,但要明寫理由(219 §7.1「簽章物件的未知欄位拒絕」的 MUST 一致性),不能寫成安全理由。

4. **規則 3 開 member session 的連線槽位**:provd 是「BLE + sock 共 2 槽,第三條只驅逐未認證 / candidate session」(`server.go:754-756` 註解)。網主 app 擁有者 session 還開著時,再開 member session,加上旁邊一支成員手機,就會被拒,看起來又像「握手失敗」(M1)。修法:契約寫明「先關擁有者 session 再開 member session」,或歸入 M1 的重試條件。

5. **跨語言向量要說清楚是第幾版**:現有的 `NETCFG` / `MEMBERS` / `SECRETS` 都是 `NET_VERSION = 1`、prev = null(`gen.py:113, 328-336`),既有的 `_upd_body`(`:547`)是 v1 的一步,節點會拒(update 至少要 v2 接在已存的 v1 後面)。新向量要寫明:v2 一步(prev = OBJECT_HASH(v1 NETCFG)、members v2、secrets v2),Go 先以 v1 join 建出已存紀錄再套用。另外,`_upd_body` 只是分塊向量,不是可套用的 update,要加註,免得 app 拿它當正向樣本。

6. **harness 合併時點要寫成條件**:§6 時序的論點(「合併時節點已是 wsl.25」)只在 **harness PR 合併前 rc 已燒到 04 / 02** 時成立。如果 harness 先合、rc 還沒燒,main 的每日全套會在 wsl.24 上跑新 provclient → `code=4` 紅燈(v2-B m5 的情境)。修法:決定 A 的順序寫成「rc 燒上兩台 → 合 harness → 用 main 的 harness 跑全套 → 合產品」。

7. **§4 缺一列「混合版本的車隊」**(v2-A 生命週期表提過,v3 沒加):移除成員時,網路裡的 wsl.24 節點一律收不到 update,會留在舊 SAE,被移除者仍進得去,直到它升級並拿到整串(或因超過 8 塊走重新入網)。§3 前提「畫面列出停在舊版的節點」涵蓋 UI,但 §4 / §5 應照實寫:移除在 wsl.24 節點上**不生效**,直到升級。

---

## 生命週期 / 資源(我自己掃的)

| 路徑 | 判斷 |
|---|---|
| 首次 / 沒網路 | ✅ `rec.Net == nil → E_STALE_VERSION` 不變(`node.go:1073-1075`) |
| start / clean stop / restart | ✅ 無新狀態 |
| 斷電 / crash / crash loop | ✅ 寫入只在不變的 `applyNet` + Finish;U9 新增經 `netUpdate` 的 seam 測試有判別力 |
| 回應遺失 | ⚠️ 規則 1 + key 11 正確;規則 3 的判定見 M1;同版號接不上見 m2 |
| 升級 wsl.24 → 25 | ✅ 紀錄格式不變;但 §4 寫 `E_SCHEMA` 錯(m1) |
| 降級 / A/B 回滾 | ✅ §4 已照實寫 F10 重新存在 |
| provd 重啟 | ✅ `E_BUSY`;PSK 集合重抓(`ctlEpoch` / `opsEpoch` → `needPSK`)— 也是 M1 的窗口之一 |
| helper 重啟 | ✅ `E_BUSY` 無 detail + Finish + key 11 |
| 混合車隊 | ⚠️ m7 |
| 兩支手機同時送同一台 | ✅ helper 序列化 → `E_BUSY`;但會拖延 PSK 重抓(M1) |
| 平台 | ✅ 同一份 Go;Pi3 只編譯(依 2026-10-23 決定) |
| 資源 | ✅ 不新增持久狀態;`Members` 唯一寫者是 leave 清 nil(`node.go:1206`);`.txn` / p5 不變 |

安全(逐 actor):
- 遠端未認證:到不了 update(`allowed`,`session.go:76-83`)✅。
- 成員 session / 被移除者的手機(分裂期間):只能送網主簽過的物件;配舊或別網的 secrets 由 §2.2-5 擋 ✅。**新增的可觸及面只有 M1**:如果 app 照現在的規則 3 實作,能讓握手失敗的人(搶槽、假冒廣播、讓 ops 一直忙)就能讓 app 叫使用者把好的節點重新入網。這是可用性攻擊,不是秘密外洩。
- 被攻陷的 provd:能送任意 body,也能讓握手失敗,影響同上(只到 app 的判斷);拿不到 net_root(`psks` 只給 HKDF 輸出,`node.go:415-417`)✅。
- 共同網主(被移除中):分叉 / 拼接 = 219 §7.1 固有限制;拼接偵測不到(M1-4)。
- 本機非特權程序、實體取得、供應鏈:不變 ✅。

---

## 前幾輪項目是否真的解決

| 項目 | 狀態 |
|---|---|
| v1 A-B1 / B-B1 secrets 綁版本 | ✅ §2.2-5、U11、U12、mutant、harness `--update-stale-secrets`(provclient 已能為任意版本產 secrets,`net.go:199-207`) |
| v1 A-M1 冪等 | ✅ F11、§3 表、規則 1 |
| v1 A-M2 / B-M1、v2 A-M3 / B-m1 大小 | ✅ 8 塊、F9、U13 在 provd 層 |
| v1 A-M3 / B-M2 等「存 members」系列 | ✅ 不存,`Members` 沒有新寫者 |
| v2 A-M1 換網主後重送 → `E_BAD_OBJECT` | ✅ F17、「錯誤碼只是提示」、規則 1、U14 |
| v2 A-M2 / B-M2 無 `E_SCHEMA`、CRIT、key 11 | ⚠️ §2.1、§3、U15 已改;**§4 與 U5 仍寫 `E_SCHEMA`**(m1) |
| v2 B-M1 分叉誤判成功 | ⚠️ 規則 3 方向對,但失敗訊號太寬、拼接漏掉(M1) |
| v2 A m1 國碼缺 key 分支 | ✅ 拿掉,`mkNet` 補 key 5(§2.2-2)。但 §6 U7 仍有「新的缺 key 5 → 14;已存的缺 key 5 → 14」,這是規則本身的負向測試,不是寬鬆分支,OK |
| v2 A m2 U8/U9 | ✅ |
| v2 A m3/m4 F9 引用、e5c89a1 | ✅(已驗 `toa24.log:3`) |
| v2 A m5 分叉時 app 無出口 | ⚠️ 只解了目標版本那一半(m2) |
| v2 A m6 fw_version | ✅ 改為不判字串 |
| v2 A m7 向量 keystore | ⚠️ 寫了測試私鑰,但版本 / 前置紀錄沒寫(m5) |
| v2 A m8 `openSecrets` 回傳 payload | ✅ §2.2-5 |
| v2 A m9 七個 key 必填 | ✅(但見 m3 是否必要) |
| v2 A m10、B m7 app 前提 | ✅ §3 前提 + §7 checklist |
| v2 B m3 拼接 / 雜湊較小者勝 | ⚠️ 不實作「較小者勝」✅;§5 仍宣稱規則 3 偵測得到拼接(M1-4) |
| v2 B m4 approve.rs admins 版本 | ✅ 進前提 + checklist |
| v2 B m5 每日全套空窗 | ⚠️ 論點成立的條件沒寫(m6) |
| v2 B m6 黑箱負對照 | ✅ |
| v2 B m8 降級 F10 | ✅ |
| v2 B m9 objectHash label、同一份 payload | ✅ |
| v2 A 混合車隊列 | ❌ 沒加(m7) |

## 判定:APPROVE-WITH-CHANGES

節點端程式設計(§2)不用改,可以實作。M1 是 app 依 §3 實作之前必須改的契約(規則 3 的失敗條件與重試、拼接的界線),再加 U16 當它在節點端的依據與負對照。MINOR 同一輪收:m1 是文字矛盾,一定要改;m3 請使用者決定。依規則,M1 修完要整份再審。
