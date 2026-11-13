# 審查 B 第 2 輪(安全優先,全文):`254-net-update-members.md` v2 DRAFT

審查者 B,2026-11-10。對象:WSL `/home/yello/Batman-p3/docs/design/254-net-update-members.md` v2;Batman-p3 `feat/254-p3` @ e5c89a1(工作樹只多這份未追蹤設計檔)。對照 `node/node.go`、`node/wtxn.go`、`cose/cose.go`、`provd/session.go`、`provd/server.go`、`provd/frame.go`、`provd/helper.go`、`219-protocol.md/.cddl`、`tests/tools/provclient/net.go`、`scripts/dv/*`、app `batman-proto/src/{approve,join2flow,joinflow,invite,kdf}.rs`。
探針:把 `feed/batman-prov/src` 複製到 WSL `/tmp/nurB2`,加一個測試檔跑 `go test ./node -run TestProbe`;跑完已刪除(`ls /tmp | grep nurB2` → 無)。repo 沒動,沒碰裝置。
先做自己的審查,最後才讀第 1 輪 A / B 並核對處理。

**結論:APPROVE-WITH-CHANGES — 0 BLOCKER / 2 MAJOR / 9 MINOR。** 第 1 輪的 BLOCKER(secrets 未綁版本)的修法正確,我逐項推過:§2.2-5 能擋住 F10 的兩個 PoC。兩個 MAJOR 都是 §3 的 **app 契約寫錯**:app 是照這張表實作的。修法都是改文件或改錯誤碼,不需要新機制。依規則,MAJOR 修完後要再整份審一次。

---

## MAJOR

### M1. §3「讀 `info` key 9:版本 = 目標 → 已成功」在分叉時會**誤判成功**。移除共同網主是 §5 自己列的正常情境,在那個情境下,app 會把「節點被被移除者控制」顯示成「換密碼完成」
- **情境 1(移除共同網主 C)**:v2 的 admins = {A, C}。A 發出 v3(admins = {A},新 SAE),用來移除 C。C 仍在 v2 的 admins 裡,所以在分裂期間,他能用舊 `psk_member` 對落後節點 L 開 member session,搶先送他自己簽的 v3'(admins = {C},SAE 由 C 決定)。A 的 app 對 L 送 v3 時拿到 `E_BAD_OBJECT`;如果是回應遺失或 `E_BUSY outcome unknown`,app 就去讀 info。依 §3,`E_BAD_OBJECT` 的處理是「不重送 / app 的錯 / 請升級」,讀 info 的結果是 key 9 = 3 = 目標,於是判成「已成功」。實際上 L 在 C 的分叉上,之後每一版都由 C 控制。
- **情境 2(我們自己的錯)**:app 送出 v+1(SAE X)後當掉,重開時沒有存下 v+1,於是重簽一份 v+1(SAE Y)。已經收到 X 的節點,版本 = 目標,被判成功。結果 mesh 永久分裂,app 卻顯示全綠。
- **探針證據**(`/tmp/nurB2`,`memberRig` → v2 admins {A, C} → C 簽 v3' → A 簽 v3):
  ```
  zz_probe_test.go:19: fork apply -> 0
  zz_probe_test.go:20: legit v3 apply -> 4 (version now 3, wl=attacker-sae/m2/36)
  ```
  合法的 v3 回 4(`E_BAD_OBJECT "chain link"`:已存的 admins 已經是 {C}),紀錄版本 = 3,無線電上是攻擊者的 SAE。info 只回 net_version / net_id / unfinished(`provd/server.go:546-569`,CDDL `info-resp` :161-175),沒有 net_config 雜湊,所以 app 從 info 分不出「同一個版本號,不同的物件」。
- **修法(不加機制,只改契約)**:
  1. 「成功」的判準改成:**用新 net_root 導出的 `psk_member(目標版本)` 能對該節點開 member session**。這是既有機制:psk 由節點儲存的 net_root 導出(`node.go:430-431`、`proto.go:163`),走錯分支的節點會讓握手失敗。版本號只是前置條件,不是證明。
  2. 契約要寫明:**每一版換密碼都要換 net_root**(移除成員的版本必須換,否則被移除者的手機仍能導出每一版的 psk_member,見 m7);app **先存下一版再送**,絕不以同一個版本號重簽不同內容。
  3. §3 的 `E_BAD_OBJECT` 列補一句:節點版本已 ≥ 目標時,`E_BAD_OBJECT` 可能代表分叉,不是 app 的錯 → 告警,恢復方式是 leave + 重新入網。
  4. 以上進 #254 checklist(app 那邊)。§6 加一個 Go 測試,釘住「分叉後合法鏈 → 4、版本不變」這個行為,讓 app 的契約有依據。

### M2. §3 / §2.1 的錯誤碼表與實際對應不符:協定裡沒有 `E_SCHEMA`;helper 的 ESchema 到了 app 是 `E_REJECTED{}`(沒有原因),還會記一筆 CRIT「provd bug」。表裡也缺了 apply / 儲存失敗那幾列
- **證據**:
  - `provd/session.go:578-580`:`case hESchema: ss.logf("CRIT provd: the helper rejected a request schema (%s) — a provd bug", typ); return errEnv(id, ERejected, nil)`。
  - 協定錯誤碼(`provd/session.go:36-49`;219 §5.2 表 :180-187)沒有 20。
  - §2.1 / §3 把「舊形狀、secrets 位置錯、缺 members」列為 `E_SCHEMA`,app 實際收到的是 `E_REJECTED`,沒有 key 2。這和下列兩種情況**完全一樣**:
    - `EApply`:無線電被關(`node.go:1131`)、CheckRestorable、`.txn`、setkey 失敗(`:1170-1176`)、stage 失敗(`txn.go:22,27`);
    - `EState`(「record changed; retry」,`txn.go:36`)。
    
    這兩種在 `mapHelper` 裡都是 `E_REJECTED{}`(`session.go:575-576`)。
  - 國碼的回應實際是 `E_REJECTED{2: 14}`(`mapHelperR`,`session.go:905-907`),表裡寫成 `{14}`。
  - 另有兩列缺漏:`EStorage` → `E_STORAGE`(10,`txn.go:42` commit 失敗、Finish 回退),以及 `E_BUSY` 不帶 key 3(helper 連線中斷,`session.go:607-610`)。
- **影響**:
  - app 照表實作,會把「請求組錯,不要重送」和「無線電關著 / setkey 失敗,稍後可重試」當成同一件事。
  - 任何 member session,包括分裂期間被移除者的手機,只要送一個壞形狀,就能讓每台落後節點記一筆 CRIT「provd bug」,造成誤導性告警與 log 灌爆。
  - 既有的 `fail(ESchema, "version chain")`(`node.go:1079`)也有同樣的問題。
- **修法(擇一,都很小)**:
  - (a) `netUpdate` 對**轉送進來的 body** 一律回 `EBadObject`。ESchema 依 `node.go:51-52` 的註解,專指「provd 送錯格式」;body 是不受信任的轉送物件,不是 provd 的格式。§3 的 `E_SCHEMA` 列併入 `E_BAD_OBJECT`。
  - (b) 保留 ESchema,但 §3 照實寫成 `E_REJECTED{}`,並接受 CRIT 噪音。
  
  我建議 (a)。不論選哪個,§3 都要補 `E_REJECTED{}`(apply / state:沒有改變或已由 Finish 回退 → 讀 info,稍後重試)、`E_STORAGE`、`E_BUSY`(無 key 3)三列,並把國碼寫成 `E_REJECTED{2:14}`。U5 要斷言**協定層**的碼(provd `route_test`),不只 helper 碼。

---

## MINOR

1. **大小上限不是 65400**:BLE 單則訊息 `MaxMsg = 8192`(`frame.go:15`)。每一塊的**整個信封**都要 ≤ `max_msg − 16`(219 §5.1 :169;向量 `chunk_boundary`,`gen.py:557`),最多 8 塊(`session.go:528`)。所以 body 實際能送的上限約是 8 ×(8176 − 信封開銷約 40)≈ 65 0xx B,`MaxReassembled = 65400` 永遠碰不到。app 若以 65400 為預算,介於兩者之間的請求會變成 9 塊 → `chunk part` → session 被關,沒有錯誤碼。app 讀 info 後仍是舊版,重組同一份,陷入迴圈。修法:§3 的上限改用「≤ 8 塊,每塊依 chunk_boundary」定義;U13 改成經 provd 真實分塊的邊界測試(剛好 8 塊 → 0;多一位元組 → 9 塊 → session 結束)。另外,app 的成員上限是 16(`invite.rs:179`),「20 位 ≈ 10 版」這個估算用不到,改成 16 位。
2. **§3 把 `info` key 11 寫成 Left**:實際上 key 11 是 `unfinished`(CDDL :172;`server.go:567` 取自 `info.net` key 4)。判斷版本之前要先等 key 11 = false(第 1 輪 A-M1 原本就是這樣寫的,v2 漏掉了)。
3. **secrets 只綁到 (net_id, version),沒有綁到那一份 net_config**。同一版本的兩支分叉可以互換:
   ```
   zz_probe_test.go:29: splice fork cfg + legit v3 secrets -> 0 wl=sae-v3-new/evil/36
   ```
   這表示:C 簽的 v3'(admins = {C})配上 A 給這台的合法 v3 secrets → 節點留在合法 mesh(新 SAE),但未來的版本由 C 控制,是一種隱蔽的持久控制。這需要網主簽的分叉,屬於 §5「移除共同網主」的固有限制;CDDL 的 secrets 也沒有 cfg 雜湊欄位,改它等於改協定。§5 要照實寫出這一點(現在只寫了「保留舊 SAE 或另起分叉」)。另外寫明 219 §7.5 的「雜湊較小者勝、自動切換」**節點和 app 都不得實作**:被移除的共同網主可以暴力找出較小雜湊的 v+1',把已經換好的節點也搶走。
4. **members / secrets 的簽章者,app 與節點不一致**:
   - 219 §7.1 規定「第 v+1 版的簽章以第 v 版的 admins 驗證」,§2.2-3(members)與今天的 secrets(`adminsOfPrev`,`node.go:1107,1115-1120`)都照這條做。
   - app 的 `approve.rs:281-285` 則用**同一版** `cfg.admins` 去驗 members / secrets / msecrets。
   - 在換了 admins 的那一版(移除共同網主、交接),兩邊只能各滿足一邊。
   
   §3 要寫明「第 v+1 步的 members 與 secrets 由第 v 版 admins 裡的一把簽」,並把 approve.rs 是否違反 219 §7.1 進 #254 checklist(app)。
5. **harness 先合、wsl.25 還沒出的這段空窗**:決定 A 說「不在 wsl.24 上跑」,但 main 的每日全套照樣會在 wsl.24 節點上跑那三個單元。新形狀會得到 `code=4`,這是 FAIL,不是 skip。要寫明處理方式:用 `validation-known-failures.txt` 加一條有到期日的項目(版本限定),或比照 `pre-p3-versions.txt` 用版本閘(`prov-p3-verbs-254.sh:53`)。否則就是未歸因的紅燈,或被默默跳過(#290、「不准縮水」)。
6. **BLOCKER 修正沒有出貨產物上的黑箱負對照**:provclient 已經能為任意版本產 secrets(`net.go:186-193 netSecrets(in, netID, ver)`)。加一個 `--update-stale-secrets`(cfg v+1 + 這台的 v secrets),在 `prov-netupdate-254` 加一列「期待 code=4、版本與 wl 不變」。成本很低,而且在 wsl.25 出貨 image 上證明的正是這份設計存在的理由。Go mutant 只證明原始碼,不證明出貨產物(全域規則:出貨物 ≠ 驗證物時要重驗)。
7. **「移除成員」目標的 app 端前提沒有列出**(節點無從檢查):
   - 移除那一版要換 SAE **與 net_root**(以及 LoRa PSK)。不換 net_root 的話,被移除者的手機可以對每一版導出 `psk_member` / `adv_member`(`kdf.rs:39,49`),仍能對所有節點開 member session(info / status / update)。
   - 不得為被移除的節點產 net_secrets;不得把 v+1 的 bundle / msecrets 同步給被移除者的手機(219 §7.5 的「同步給所有成員 app」要排除他)。
   - app 要顯示哪些節點還停在舊版。它們接受舊 SAE / 舊 psk_member,也就是被移除者仍進得去的入口;特別是超過大小預算、又等不到擁有者在場的那些節點。
   
   以上都進 #254 checklist。§5 的「資產 / 目標」目前只寫了節點端。
8. **§4 降級列**:降回 wsl.24 會讓 F10 再度生效(舊 helper 不比對 secrets 的版本)。不只是「紀錄不變」,要照實寫出來。另外,已經在 wsl.24 上被 F10 寫進的紀錄,升級後不會被重驗,恢復方式是 leave + 重新入網(一句話即可)。
9. **實作細節**:
   - provclient `objectHash` 的 label 表只有 netcfg / secrets(`net.go:112`)。單步不需要,但如果以後在 harness 送兩步,要加 members。
   - §2.2-5 的比對要拿 `decryptSecrets` 用來算 KDF 的**同一份** payload 值。CBOR 是嚴格解碼、拒絕重複 key(`cbor.go:3-5,337`),所以重新解碼不會產生差異;這點寫一句即可。

---

## 逐 actor 檢查(我自己推的)

| actor / 手法 | 結果 |
|---|---|
| 遠端未認證(BLE / HTTP) | `allowed[RoleAnon]` 沒有 update(`session.go:76`)✅ |
| 本機非特權程序 | 不新增 socket 或路徑;helper 只讀請求與已存紀錄 ✅ |
| 成員 session / 被移除者的手機(舊 psk_member 對落後節點有效) | 舊版或別網的 secrets 配新 cfg:§2.2-5 擋(推演 F10 兩個 PoC:payload ver / nid ≠ cfg → 拒絕)✅;重送舊鏈:版本連續性擋 ✅;換步、跨網的 cfg:net_id 檢查 ✅;換 members:綁版本 / net_id / 簽章 ✅;壞形狀:會觸發 CRIT log(M2)⚠️ |
| 被攻陷的 provd | 看得到轉送物件(secrets 對節點 DAC 加密,沒有 decrypt verb,`node.go:288`);能做的只有扣住不送 → 節點停在舊版,這是既有能力 ✅ |
| 被移除或被攻陷的共同網主 | 分叉搶先 + 誤判成功(M1);分叉 cfg 配合法 secrets(m3)— 屬固有限制,但要寫清楚,而且 app 的判準不能被騙 |
| 實體取得 | 不變(prov.cbor 0600)✅ |
| 供應鏈 | 不變 |
| 我們自己的錯 | 重簽同一版本(M1-情境 2);預算用錯上限(m1);錯誤碼表(M2) |
| 資源耗盡 | 每一步先驗簽章,第一個失敗就停;helper 序列化(`node.go:221`),無效請求只花一次驗章 ✅ |
| 被移除者重新進入 | 被移除的節點拿不到 v+1 secrets(DAC 目標);leave 後用 v 的舊物件 join → 只回到舊版 v(本來就知道的),拿不到新 SAE ✅ |

## 查證屬實的事實
F1(`node.go:1072-1127`)、F2(`:1024-1041`)、F3(`:1145`、`:1206`)、F5(`:756-758`、`session.go:79,82`)、F6(`:970-972`)、F9(`session.go:92-97,547-548`)、F10(`wtxn.go:126-152`)、F11(`session.go:616-620`)、F12、F13(`approve.rs:205-215`、`join2flow.rs:358-366`、`joinflow.rs:212-220`)、F14(`wtxn_test.go:73-80`),都與原始碼相符。`CTMembers` / `LabelMembers` 已存在(`cose.go:22`、`proto.go:31`)。VerifySign1 會檢查 content type 與 label(`cose.go:52-60`),netcfg 和 members 互換不了 ✅。**F8 只對了一半**:EReject 的對應正確,但 ESchema 的對應見 M2。

## 第 1 輪審查的處理核對
| 項目 | 狀態 |
|---|---|
| A-B1 / B-B1 secrets 綁版本 | ✅ §2.2-5 + U11 / U12 + mutant;推演能擋住兩個 PoC。殘餘的跨分叉互換見 m3 |
| A-M1 冪等 | ✅ F11 / U14;但 key 11 寫錯(m2) |
| A-M2 / B-M1 大小 | ✅ 依使用者決定;但上限數字不對(m1) |
| A-M3、B-M2、A-m2、A-m3、A-m6、A-m8、B-m5、B-m8 | ✅ 不存 members 之後,這些問題都消失了(F3 確認 Members 永遠是 nil) |
| A-m1 行號 / 呼叫者 | ✅ |
| A-m4 / B-m7 錯誤碼 | ⚠️ 表有了,但對應是錯的(M2) |
| A-m5 / B-m3 國碼 | ✅ §2.2-2 規則 + app 契約 |
| A-m7 / B-m4 硬體負對照 | ✅ 誠實界線;但空窗期的每日全套見 m5,出貨物上的黑箱測試見 m6 |
| A-m9 mutant | ✅ |
| A-m10 舊節點偵測 / 分叉 | ✅ fw_version;分叉見 M1 / m3 |
| B-m1 分叉拼接 | ⚠️ members 拼接沒有影響了;但 cfg 和 secrets 仍可以跨分叉互換(m3,有探針) |
| B-m2 移除共同網主 | ✅ 寫進限制;但「成功判準」會被它騙(M1) |
| B-m6 未知 key | ✅ checklist |

## 判定
**APPROVE-WITH-CHANGES**:節點端的設計(§2)可以照做。必須改的是 M1 與 M2:§3 契約的成功判準與錯誤碼表,M2 另外建議把轉送 body 的形狀錯誤改回 `EBadObject`。依流程,這兩項 MAJOR 改完後要整份再審一輪。MINOR 可以在同一版一起收:m1、m2、m5 是事實錯誤或流程漏洞;m3、m4、m7 進 #254 checklist;m6 強烈建議做。
