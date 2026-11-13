# 審查 A 第 2 輪(正確性 / 介面 / 生命週期,整份):254-net-update-members.md v2 DRAFT

審查者 A,2026-11-10。先自己從頭審整份,最後才讀第 1 輪 A/B 對照處理情形。對照:Batman-p3 `feat/254-p3` @ e5c89a1(工作樹只多這份未追蹤設計檔)、219-protocol.md / .cddl、provd / node 原始碼、provclient、harness 單元、Batman-app `batman-proto/src` @ 6574ca4。repo 全程唯讀、未碰裝置。探針都在 WSL `/tmp/nurA`(`git archive HEAD` 整棵樹複本)跑,跑完已刪(`ls /tmp | grep -c nurA` → 0;`git status --short` 只剩 `?? docs/design/254-net-update-members.md`)。

**結論:APPROVE-WITH-CHANGES — 0 BLOCKER、3 MAJOR、10 MINOR。** 設計的核心修改是對的:secrets 綁版本這一行我實作後跑過,PoC 從 0 翻成被拒,join / update 既有的 Go 測試全數照過;members / 國碼 / net_id 檢查的位置與 signers 也都對。三個 MAJOR 全部出在 **§3 契約表和程式實際回的東西對不上**,而 §3 正是 app 要照著實作的那張表。依規則,MAJOR 修完要整份再審一次。

---

## 我自己驗過的事實(✅ 附輸出)

- **F10 重現(修正前)**,複本加測試檔、`go test -run TestZZ -v ./node/`:
  ```
  zz_probe_test.go:12: v2 cfg + v1 secrets -> code 0 wl=sae-v1-pass/m2/36 ver=2
  zz_probe_test.go:16: v3 cfg + other-net secrets -> code 0 wl=sae-other-pass/m3/36
  ```
- **§2.2-5 的負對照(套上綁定之後)**:在 `parseNet` 的 `openSecrets` 之後加「secrets payload key1 == p.netID && key2 == p.version」:
  ```
  zz_probe_test.go:12: v2 cfg + v1 secrets -> code 4 wl=sae-v1-pass/m1/28 ver=1
  ok  	batman-prov/node	25.579s      (整包,含所有 join / update / handover / seam 測試)
  ok  	batman-prov/provd	12.467s
  ```
  → 綁定擋住 PoC,而且**沒有任何既有測試壞掉**(基準:修改前 `node 24.989s ok / provd 12.392s ok / cose ok`)。這也代表今天沒有任何測試涵蓋綁定,U11 / U12 是必要的。
- **app 的 join 路徑不受 §2.2-5 影響**:`approve.rs:206-215`(secrets 用 `cfg.net_id, cfg.version`)、`join2flow.rs:357-366`、`joinflow.rs:216-220`(新網路 v1,`net_config_payload(&net_id, 1, …)` `:148`);joiner 端 `approve.rs:276-286` 另外要求 approval 的 netcfg = 邀請的 netcfg、secrets 的 net_id / 版本 = 它(`same_net :247-261`),所以節點收到的 join 一定是綁好的。provclient `--first / --join / --update` 都用 cfg 的版本產 secrets(`net.go:203-216, 270-281`)。向量 `gen.py:328-342` NETCFG / MEMBERS / SECRETS 同一個 `NET_VERSION`。
- F1(`node.go:1072-1112`、`:1093`、`:1101`、`:1083-1086`、`:1107-1108`、`:1115`、`:1126`)、F2(`:1024-1041`)、F3(`:1206`、`:1145`;`provstore.go:214` 只有 decode)、F5(`node.go:756`;`session.go:79,82`)、F6(`:970-972`)、F7、F8、F11(`session.go:613-621`、`:589-611`)、F12(`:1043-1070`)、F13、F14(`netrec.rs:103`、`wtxn_test.go:73-80`)✅。
- wsl.24 收新形狀:`VerifySign1` 第一行 `item.(cbor.Tag)` 對 map 失敗 → `E_BAD_OBJECT "chain link"` ✅(`cose.go:36-39`、`node.go:1093-1095`)。
- 成員 session 在換版後被斷:`psk_member = PskMember(root, NetID, Version)`(`node.go:431`)→ provd `reconcile()` 對 `RoleMember` 比 `psks.member`,不同就 `Kill("psk-rotated")`(`server.go:618-655`)✅。
- members 的 signers 與 net_config 同一組符合 219 §7.1「第 v+1 版的簽章一律以第 v 版 admins 驗」✅;換網主的兩步鏈 [v2(交給 b), v3(b 簽)]:step1 signers=rec.Admins、step2 signers=adminsOf(v2)=b、secrets 用 `adminsOfPrev` = b,members 跟著同一組,一致 ✅。
- app `member_list_payload` 一律帶 key 5/6/7(空陣列)(`cose.rs:112-134`),所以 §2.2-3「key 4–7 是陣列」不會打壞 app ✅。

---

## MAJOR

### M1. §3「已套用後重送 → `E_STALE_VERSION`」在網主組有變的版本不成立:回的是 `E_BAD_OBJECT`,而 app 依表會判成「請求壞了 / 請升級節點」
- **情境(正是 S6 會發生的)**:移除共同網主或換網主 = v+1 改了 admins。app 送 v+1,節點套用成功,回應在 BLE 上遺失(或 `E_BUSY outcome unknown`)。app 依 §3 重送同一串 → 節點的 signers 現在是 v+1 的 admins,而 v+1 的 net_config 是 v 的 admins 簽的 → `VerifySign1` 先失敗。節點 ahead of chain(app 用舊的 key 9 組鏈)且中間換過網主時也一樣。
- **證據**(複本探針 `TestZZHandoverResend`,以 `TestHandoverThenCrashAfterV2` 的 v2 為底):
  ```
  zz_probe2_test.go:13: apply v2 (handover) -> 0
  zz_probe2_test.go:15: resend v2 after handover -> 4 (EStale=5 EBadObject=4)
  ```
  原因:`node.go:1093` 簽章檢查在 `:1101` 版本連續檢查之前。§3 的 `E_BAD_OBJECT` 列叫 app「不重送同一份;fw_version 是 wsl.24 以前 → 請先升級」,對一台 wsl.25、其實已經成功的節點是錯的結論。U14 只測了同一組網主,抓不到。
- **修法(擇一,都不加機制)**:
  - (a,只改契約)§3 改成:**任何非 0 回應(`E_STALE_VERSION`、`E_BAD_OBJECT`、`E_BUSY`、`E_REJECTED`)app 都先讀 `info` key 9 / 11**;key 11 = false 且 key 9 ≥ 目標版本 → 已成功;之後才依碼分流。U14 加「換網主那版套用後原樣重送 → 非 0、紀錄不變,info key 9 = 目標」。
  - (b,改順序)第一步先比版本(`ver ≤ rec.Net.Version` → `E_STALE_VERSION`)再驗簽章。版本號 owner / member session 本來就能從 `info` key 9 讀到,不洩漏新東西;但這是改既有檢查順序,要加 mutant。
  我建議 (a):不動程式,而且也同時涵蓋 M2 的 `E_REJECTED` 情況。

### M2. §3 的錯誤碼欄和線上實際的碼對不上:協定沒有 `E_SCHEMA`,helper 的 ESchema 會變成 `E_REJECTED`(無 reason)+ 一行 CRIT「provd bug」;apply 失敗的列整個漏掉;key 11 標錯
- **證據**:
  - 協定錯誤碼只有 1–13(`provd/session.go:36-50`,219 §5.2),沒有 E_SCHEMA。`mapHelper`:`case hESchema: ss.logf("CRIT provd: the helper rejected a request schema (%s) — a provd bug", typ); return errEnv(id, ERejected, nil)`(`session.go:578-580`)。`node.go:50-52` 的註解也寫明 ESchema 的語意是「provd 送錯格式」,不是對端的輸入。
  - 所以 §2.1 新增的每一條 `E_SCHEMA`(舊形狀、secrets 位置錯、缺 members、步不是 map)在 app 看來都是 `E_REJECTED`、沒有 reason;任何 member session(含分裂期間被移除者的手機)每送一筆就在節點留一行 CRIT。
  - 同一個 `E_REJECTED`(無 reason)也是 `applyNet` 所有失敗的回應:radio 被手動關(`node.go:1129-1131`)、snapshot 不可還原、setkey 失敗後 Finish(`:1170-1177`)、commit 失敗 → `EApply` → `mapHelper` `hEApply → ERejected`(`session.go:574-575`)。§3 叫 app 對 E_SCHEMA「app 的錯,不重送」,對 apply 失敗卻應該「節點回到前一狀態,讀 info、稍後再送」— app 在線上分不出這兩種。`E_STORAGE`(EStorage 10 直通)也沒有列。
  - §3 第 3 列寫「key 11(Left)」:`info` key 11 是 **unfinished**(= `.txn` 還在),不是 Left(CDDL `219-protocol.cddl:172-173`;helper `readonly.go:142` `4, provstore.TxnPresent(n.P)` → provd `server.go:563-568` 放到 key 11)。Left 根本沒有在 info 裡。依現在的表,app 會把「交易未完成」讀成「已離開」。
- **修法**:
  1. `netUpdate` 的形狀錯誤改回 `E_BAD_OBJECT`(和「物件不符」同類:對端組錯、不重送),不用 ESchema。今天 `version chain` 不是陣列也是 ESchema → 一起改(只影響這一個 fail,`grep ESchema node/*_test.go` 沒有測試依賴 update 的 ESchema)。
  2. §3 加列:`E_REJECTED`(無 reason)= 節點套用失敗、已回到前一狀態或待 Finish → 讀 info(等 key 11 = false)、稍後重送;`E_STORAGE` 同;`E_BUSY`(無 detail)= 另一個請求進行中。
  3. key 11 改成「unfinished:true 時等它變 false 再看 key 9」。
  4. U5 的斷言改成實際的碼;provd 層加一個 update 形狀錯誤 → 線上碼 的測試(現在 U8 用假 helper,碰不到)。

### M3. 大小上限寫成 65400 B 是錯的:在 max_msg = 8192 時,真正綁住的是 8 個分塊,約 65 112–65 144 B;app 照 §3 預算會在邊界送出 9 塊 → session 被關、沒有錯誤碼、每次重試都一樣
- **證據**:
  - BLE 單則上限 `MaxMsg = 8192`(`provd/frame.go:15`,CTRL key 4 也廣播 8192,`server.go:574`),每塊明文 ≤ `maxPlain = MaxMsg − 16 = 8176`(`session.go:96`);`MaxChunks = 8`(`:94`),`total > MaxChunks` → `"chunk part"` error → session 結束(`:530-532`)。
  - 我在複本用節點自己的 `cbor.Encode` 算分塊信封 `{0:[1,0],1:id,2:"network/update",3:slice,6:{1:8,2:8}}` 的開銷:
    ```
    id 1 overhead 33 max slice 8143 x8 = 65144
    id 4294967295 overhead 37 max slice 8139 x8 = 65112
    ```
    → body 在 (≈65 112, 65 400] 之間就要 9 塊。app 的分塊器(`envelope.rs:50-93` `split_request`)只依 max_msg 切,不知道 8 塊的上限;219 §4.1 寫的總上限是 1 MB(`219-protocol.md:169`),8 塊這個數字協定裡沒有,app 只能從這份設計得知。
  - F9 只寫 65400 與 `chunk()`;U13 在 node 層「≤ 65400 B → 0」也碰不到 provd 的塊數限制。
- **為什麼是 MAJOR**:使用者決定的退路(app 先算大小、超過走離開 + 重新入網)整個靠這個數字;算錯的那一段會變成「永遠 session 被關、沒有碼」的死循環。
- **修法(只改文件與測試)**:§3 寫成「body ≤ min(65 400, 8 × (max_msg − 16 − 分塊信封開銷));max_msg = 8192 時 ≈ 65 112 B(id 取最壞 2^32−1)」;F9 補 `frame.go:15` 與 `session.go:530-532`;U13 改在 provd 層用真分塊跑:8 塊剛好塞滿 → 0;需要 9 塊 → session 結束且節點紀錄不變。

---

## MINOR

1. **國碼「兩者都沒有 key 5 → 通過」只為 Go 測試 rig 存在**(F14 自己寫的)。真實路徑(app、provclient)一律帶 key 5,CDDL 也必填。這是為測試多開的一條寬鬆分支,還要多一個 mutant。修法:`mkNet` 的 payload 加 `5, "TW"`(一行),規則只剩「兩邊都是 tstr 且相等 → 通過,其他 → 14」。
2. **U9 / U8 沒有判別力**:seam 測試(`seam_points_test.go:102-133`)只驅動 `r.join()` 和直接呼叫 `applyNet`,從不經過 `netUpdate`;`route_test.go:372-375` 用假 helper,body 形狀無關。說「在新形狀下照跑」等於什麼都沒證明。照實寫:update 的寫入路徑 = 不變的 `applyNet`,斷電覆蓋靠既有 join 的 seam 測試 + 硬體 `prov-powerloss-254`;U8 若保留,要改成真 helper(`realhelper_*`)送一次新形狀。
3. **F9 引錯一處**:`provd/helper.go:132-135` 是 provd 讀 **helper 回應** 的 buffer,不是 helper 的請求上限;helper 的請求上限是 `sock/sock.go:25, 225`(`MaxRequest = 65536`)。另補 `frame.go:15`(見 M3)。
4. **「e5c89a1 = wsl.24 的 commit」沒有證據**:repo 沒有 tag(`git tag --points-at e5c89a1` 空),log 也找不到 wsl.24 字樣。附建置證據(image 的 `/etc/batman-build` `BATMAN_VERSION` 或 build log 的 commit),或標 ⚠️。
5. **分叉的 app 契約沒寫**:§0 說落敗分支的節點之後都 `E_STALE_VERSION`。但 app 依 §3 讀 key 9 → 等於它以為的版本 → 重組同一串 → 又 `E_STALE_VERSION`,無限循環(info 不帶雜湊,app 分不出)。§3 加一句:重讀 info 後 key 9 = 鏈起點 − 1、key 11 = false 仍 `E_STALE_VERSION` → 視為分叉 / 鏈不相容 → 走離開 + 重新入網並告警。若中間換過網主,回的是 `E_BAD_OBJECT`(同 M1)。
6. **fw_version 判斷沒有格式**:info key 4 = `/etc/batman-build` 的 `BATMAN_VERSION` 原字串(`cmd/batman-provd/main.go:81`、`server.go:549`)。「wsl.24 以前」怎麼比(字串格式、怎麼解析 `wsl.N`、wbox 版本)要寫,附一個真機上的值當證據;否則 app 只能猜。
7. **跨語言向量「Go 讀並套用」怎麼做沒寫**:node 測試 rig 用隨機 keystore,沒有任何 node 測試讀 vectors(只有 cose / proto / cbor / keystore / provd noise 讀)。要套用 Python 產的 secrets,得把向量的 node ECDH / DAC 金鑰放進 rig 的 keystore。寫明作法,或把 Go 端縮成 cose 層:驗向量那一步的 members 簽章 + 綁定 + 解密。
8. **§2.2-5「比 payload 即可」的實作入口**:`openSecrets` 今天只回解密後的明文 map(`wtxn.go:93-103`),拿不到 payload。寫明讓它一併回已驗過的 `*cose.Sign1`(不要另外再 decode 一次未驗的物件),mutant 才打得到同一個值。
9. **§2.2-3 key 存在性模糊**:CDDL 的 member-list 七個 key 全部必填(`219-protocol.cddl:358-366`);設計只說「只含 1–7」「4–7 是陣列」。寫明「缺任一 → `E_BAD_OBJECT`」,U5 加「缺 key 5」。
10. **app 端的前提沒進 checklist**:(a) 網主 app 與轉送的成員 app 要保存從最落後節點起每一版的 net_config + member_list(否則組不出鏈);(b) app 的 `member_list_payload` 現在沒有 removed / used / revoked 參數(`cose.rs:112-134` 一律空陣列),移除成員一定要改。兩行加進 §7 checklist。

---

## 生命週期 / 資源檢查(我自己掃的)

| 路徑 | 判斷 |
|---|---|
| 首次 / 沒網路 | ✅ `rec.Net == nil → E_STALE_VERSION`(`node.go:1073-1075`)不變 |
| start / stop / restart | ✅ 無新狀態 |
| 斷電 / crash | ✅ 寫入只在不變的 `applyNet`;但 U9 的說法要改(m2) |
| 回應遺失 | ⚠️ M1(換網主的版本)、M2(key 11) |
| 升級 / 降級 / A/B 回滾 | ✅ 紀錄格式不變;wsl.24 回 `E_BAD_OBJECT "chain link"` 已驗;fw_version 判斷見 m6 |
| 混合韌體車隊 | ⚠️ 未提:wsl.24 節點在升級前收不到任何 update(=換密碼時一定被分出去)。目前 app 還不送 update(F4,`vectors.rs:44` 標 pending),沒有既有使用者受害;§4 加一行即可 |
| provd / helper 重啟 | ✅ 既有(`E_BUSY`) |
| 兩支手機同時送 | ✅ helper 序列化;第二支 `E_BUSY`(無 detail)或 `E_STALE_VERSION`,§3 要有 `E_BUSY` 無 detail 的列(M2) |
| 平台 | ✅ 同一份 Go |
| 資源 | ✅ 不新增持久狀態;`Members` 永遠 nil(只有 decode 讀) |

安全面:被移除者的手機 / member session 能做的仍只有「不送」或「送網主簽過的物件」;綁定修好之後,配舊 / 別網 secrets 被擋(上面負對照)。新的可觸及面只有 M2 的 CRIT log(每筆畸形 update 一行)— 改成 `E_BAD_OBJECT` 一併消失。

---

## 第 1 輪項目是否真的解決

| 項目 | 狀態 |
|---|---|
| A-B1 / B-B1 secrets 綁版本 | ✅ 已解(我實作 + 負對照,見上) |
| A-M1 冪等快取 | ⚠️ 部分:F11 正確;但 §3 把 key 11 寫成 Left,且換網主版本的重送回 `E_BAD_OBJECT`(M1、M2) |
| A-M2 / B-M1 大小 | ⚠️ 部分:有寫上限與退路,但數字錯(M3) |
| A-M3、B-M2、A-m2、A-m3、A-m6、A-m8、B-m5、B-m8 | ✅ 因「不存 members」而消失,確認 `Members` 沒有新寫者 |
| A-m1 行號 | ✅(F9 另有一處引錯,m3) |
| A-m4 / B-m7 錯誤碼 | ⚠️ 表有了,但 E_SCHEMA 線上不存在(M2) |
| A-m5 / B-m3 國碼 | ✅ 規則與 app 契約都寫了(m1 建議去掉 rig 專用分支) |
| A-m7 / B-m4 硬體負對照 | ✅ 誠實界線已寫 |
| A-m9 mutant | ✅ 補齊 |
| A-m10 / B-m1 舊節點、分叉 | ⚠️ §0 / §3 有寫;app 的分叉偵測與 fw_version 格式未寫(m5、m6) |
| B-m2 移除共同網主 | ✅ 限制 + checklist |
| B-m6 未知 key 不對稱 | ✅ 寫明刻意 + checklist |

## 判定:APPROVE-WITH-CHANGES
程式面的設計(§2.1–§2.3)可以照做,只多一處:形狀錯誤用 `E_BAD_OBJECT` 而不是 ESchema(M2-1)。M1–M3 是 §3 契約與 F9 / U13 的修正,必須在 app 依這張表實作之前改好;依規則改完要整份再審。MINOR 同一輪一起收。
