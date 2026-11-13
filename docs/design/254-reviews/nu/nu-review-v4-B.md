# 審查 B 第 4 輪(安全優先,整份):`254-net-update-members.md` v4 DRAFT

審查者 B,2026-11-10。對象:WSL `/home/yello/Batman-p3/docs/design/254-net-update-members.md` v4(261 行);Batman-p3 `feat/254-p3` @ e5c89a1。
對照原始碼:`node/node.go`(netUpdate / netJoin / parseNet / applyNet / psks / dispatch log)、`node/wtxn.go`(decryptSecrets / openStoredSecrets)、`node/readonly.go`、`provd/session.go`(角色表 / 分塊 / mapHelper / mapHelperR / forward)、`provd/server.go`(opsLoop / reconcile / info)、`provd/noise.go`、`cose/cose.go`(VerifySign1)、`proto/proto.go`、`219-protocol.md §7.1`、`219-protocol.cddl:231-237, 358-372`、`tests/tools/provclient/net.go`;app `batman-proto/src/{kdf,approve,join2flow,loginflow,nodecert,netrec}.rs`。
兩個 repo 全程唯讀,沒碰裝置。**本輪沒有跑探針**(⚠️ 下面所有結論是讀原始碼得出;F10 / F18 的 PoC 數字沿用前幾輪的探針,我沒重跑)。
順序:先自己審整份,最後才讀 v1–v3 的 A / B 核對處理狀況。

**結論:APPROVE-WITH-CHANGES — 0 BLOCKER / 0 MAJOR / 7 MINOR。**
- 節點端 §2 的安全性成立:secrets 綁 (net_id, 版本)、每步 net_id、國碼、members 的三項檢查都 fail-closed,沒有新的持久狀態、新的路徑或新的特權動作。
- 使用者的決定(members 只驗網主簽章 / net_id / 版本、不存;移除共同網主先不支援)我找不到不安全的地方(見「members 三項檢查夠不夠」)。
- MINOR 主要是:幾處安全事實寫得不精確(F20、members 檢查的效果),以及「app 移除成員設計必須處理的事」漏了三項安全相關的事。都只改文字或補測試,不需要再整份審一輪。

---

## members 三項檢查夠不夠(使用者要求重查)

逐一攻擊,結論是**沒有攻擊面**,理由很簡單:節點不存也不讀 members(F3:`Record.Members` 唯一的寫是 leave 清 nil,`node.go:1206`;`applyNet` 不寫它)。所以塞進什麼 members 都不會改變節點的任何狀態或行為。

| 手法 | 結果 |
|---|---|
| 拿同網、同版本、另一條鏈的 members(拼接) | 要網主簽才做得出來 = F18 的分叉情境;對節點沒有效果(不讀) |
| 被移除者的手機拿自己以前收過的 members 塞進來 | 版本必須 = 該步 net_config 版本;舊版的過不了。就算過了,節點也不讀 |
| 別種網主簽章物件冒充 members | `VerifySign1` 把 content type 綁在 protected header、label 綁在 external_aad(`cose.go:56-60`),`batman/members` + `batman-members-v1`(`cose.go:22`、`proto.go:31`)與 netcfg / secrets 分開 ✅ |
| 用大量合法步數耗 CPU | 每步多一次 ES256(最多 4 把),但只有網主簽的鏈才會走到;垃圾鏈在第一步簽章就停 ✅ |
| 結構錯的 members(缺 removed 等) | 節點不讀;結構正確是 app 的責任(§3 已列) |

所以這個決定是安全的。但要照實寫:這三項是 **CDDL / 219 一致性**,不是節點上的安全防線(見 m2)。

---

## MINOR

### m1. F20 寫錯:`psk_member` 不是「只看 secrets」,版本與 net_id 取自 net_config;所以每一版都會換 psk,而知道舊 net_root 的人算得出之後每一版的 psk
- **證據**:`node.go:431` `proto.PskMember(root, rec.Net.NetID, uint32(rec.Net.Version))`;`root` 來自已存 secrets(`netRoot`,`node.go:926-932`),`rec.Net.NetID / Version` 來自 `applyNet` 的 `p.netID / p.version`,也就是 **net_config** 的 key 1 / 2(`parseNet` `node.go:969-977`)。app 端同一個式子:`kdf.rs:38-39` `HKDF(net_root, ‖ net_id ‖ u32be(version))`。
- **影響**:
  - 修正後(§2.2-5)secrets 與 net_config 的 (net_id, 版本) 必相等,所以 §5「握手偵測不到拼接」的結論不變。
  - 但 F20 的說法會讓讀者以為「不換 net_root 就不換 psk」。實際是:每一版都換 psk;**被移除的成員手機持有舊 net_root(member_secrets `{2: net_root}`,`approve.rs:383-384`),能自己算出任何一版的 `psk_member`**,只要那一版沒換 net_root。§3 已要求移除那一版換 net_root,這條事實正是它的理由,要寫進去。
- **修法**:F20 改成「`psk_member` = HKDF(已存 secrets 的 net_root, net_config 的 net_id, 版本)」;§3「移除成員的那一版必須換 SAE 與 net_root」後面加一句理由(舊 root 的持有者能算出任何版本的 psk_member)。

### m2. §0-2、§2.2-3、§5 把 members 檢查寫成安全理由,但它擋下的東西對節點沒有效果
- §0-2「只做擋住轉送者換物件所需的三項」、§2.2-3「這三項已足以讓轉送者無法把別版、別網或未經網主簽的清單塞進來」、§5「跨步或跨版本交換 members → …擋」。
- 這些話本身沒錯,但節點不讀 members(F3),所以「換了」也沒有任何後果。v3-A m3 已提醒「不能寫成安全理由」。
- **修法**:改寫成「三項是對齊 219 §7.1 / CDDL 的一致性檢查;節點不讀 members,所以換掉它對節點沒有效果。members 內容的安全意義全在 app(§3)」。§5 那一條移到「不是新的面」或刪掉。

### m3. app 清單漏了:**任何轉送都要 pin 目標 DAC**,不只「新 psk 握手當證據」時;`psk_member` 是全網共用,不是每台一把
- **情境**:分裂期間,留下的成員手機用 `psk_member(v)` 轉送 v+1 給落後節點 L。被移除的節點 X(或被移除者的手機)也持有 `psk_member(v)`,而且 member psk 不含裝置識別(`kdf.rs:39`,對照 owner psk 含 device_id,`node.go:421`)。X 可以假冒 L 的廣播,用自己的 DAC 回 msg2,握手照樣成功(`noise.go` NXpsk0:psk 對上就過,節點身份只靠 msg2 裡的 node_cert)。
- **後果**:
  - X 收下整包 update:net_config v+1(新 ssid / channel)與新 members(全體成員的裝置名、公鑰)。secrets 是用 L 的 DAC ECDH 加密(`wtxn.go:142` `cose.Decrypt(..., dacHash, ..., n.KS.ECDH)`),X 解不開 ✅。
  - X 可以回假的 `0 {1: v+1}`,讓 L 留在舊 SAE,被移除者繼續和 L 同網。
  - 如果 app 依 §3 的新 psk 證據判斷(新 root X 沒有),最後會發現;但在那之前 app 已顯示成功。
- **證據 app 目前沒有 member-session 流程**:DAC pin 只在 `loginflow.rs:166` / `replayflow.rs:176`(owner / replay),`psk_member` 只出現在 `kdf.rs`。member_list 每位成員帶 `dac_pub_hash`(CDDL `:368`),所以 pin 做得到。
- **修法**:§3 app 清單第 1、2 條改成「**所有** member session(轉送、讀 info、新 psk 證據)都要驗 node_cert,並比對 SHA-256(DAC) = member_list 裡目標的 `dac_pub_hash`;`psk_member` 全網共用,任何持有舊版 psk 的節點 / 手機都能替落後節點完成握手」。§5 補一句「轉送者與冒充者讀不到 secrets(以目標 DAC 加密)」——這是重要的安全事實,目前文件沒寫。

### m4. app 清單漏了「各節點手機 AP 密碼」的處置(v3-B m6 只處理了一半)
- v4 §5 照實縮小了範圍(「進不了 mesh」只指 HaLow),這部分 ✅。
- 但 v3-B m6 的修法還有一半:「由 app 的移除流程提示擁有者更換」。§3 app 清單沒有這一條。
- 現場(OTS 情境:每人一節點、手機用 Wi-Fi 連自己節點)裡,被移除者只要知道任何一台留下節點的 AP 密碼,就能從 IP 層進到整個 mesh(TAK server 等),等於移除沒有生效。
- **修法**:§3 清單加「移除成員後,提示知道其 AP 密碼的節點擁有者改密碼(`settings/set` key 20);節點不會自動處理」。

### m5. app 清單漏了「我們自己的錯」造成的分叉:app 紀錄還原 / 重裝後重簽同一個版號
- §3 有「先把新版本寫進 app 紀錄再送;同一個版號只簽一次」,這擋得住 crash。
- 擋不住:手機從備份還原、或 app 資料回到較舊的狀態,app 以為最新是 v,重新簽一份 v+1,而有些節點已經套用了舊的那份 v+1。這正是 F18 的同版號分叉,而且單一網主也會發生,與「只有一位網主所以不會分叉」的前提相衝。
- **修法**:§3 清單加「簽新版之前,版號取 max(app 紀錄, 能連到的節點 `info` key 9)+1;app 紀錄還原後,在確認版號前不簽新版」。§0「app 不得產生分叉(單一網主 app 時不會發生)」要加「前提是 app 紀錄不倒退」。

### m6. 缺兩個負向測試:mutant 會活下來
1. **members 的 signers 用錯版本**:§2.2-3 規定 members 用「前一版 admins」驗(219 §7.1)。現有測試裡:
   - 換網主後再 update 的測試,v3 那一步的「前一版 admins」與「這一步 admins」都是新網主,兩者相同;
   - U3 用非網主簽,兩種寫法都會拒。
   所以 mutant「members 用這一步的 admins 驗」不會被任何 U 抓到。這也正是 §3 提到 `approve.rs:281-285` 和節點不一致的那一點,要有測試把節點行為釘住。
   **修法**:加一個換網主那一步本身的測試:v2 的 admins = {B}、由 v1 的 A 簽;v2 的 members 由 A 簽 → 0;只由 B 簽 → `E_BAD_OBJECT "member_list"`。
2. **中間步的 net_id / 國碼**:U4 寫「net_config net_id ≠ 已存」、U7 寫「某一步 key 5 ≠ 已存」,但沒說是哪一步。如果只測最後一步,mutant「只檢查最後一步」(`parseNet` 會碰到的那一步)會活下來。**修法**:U4、U7 各加一個兩步鏈、錯在第 1 步的情況。

### m7. 混合版本車隊:wsl.24 節點上 F10 對被移除者是**可利用**的,不只「移除不生效」
- §4 混合版本列寫「移除成員在它身上不生效,要先升級」。實際比這更糟:
  - 被移除者的手機仍有落後節點的 `psk_member(v)`,能對 wsl.24 節點開 member session 並送舊形狀 update(`session.go:82`)。
  - 只要它拿到 net_config v+1(公開物件;m3 的冒充就拿得到),就能配上該節點的舊 secrets,讓節點顯示 v+1、保留舊 SAE。之後它再用舊 net_root 算出 `psk_member(v+1)`(m1),在那台節點上繼續有 member session。
- 另外,wsl.24 時已經被這樣灌進「新版號 + 舊 secrets」的紀錄,升到 wsl.25 後**不會被偵測**(已存的紀錄不重驗,`openStoredSecrets` 只看 secrets 自己的 payload);要等下一次合法 update 才會修好。
- **修法**:§4 混合版本列與 §3 清單改成「網路裡還有 wsl.24 節點時,**不得開始移除成員**(先全部升級);升級本身不修復已被利用的紀錄,下一版合法 update 才會」。

---

## 其他我核對過、沒有問題的地方

- **秘密不進 log / argv**:helper 拒絕時只寫 `verb %s refused: code %d (%s)` 加原因字串(`node.go:224-225`);新原因("net_id"、"member_list"、"net_secrets"、"update shape")都不含物件內容 ✅。provclient 的 SAE 走 fd 3,不走 argv(`net.go:14, 49-76`)✅;`--update` 的 argv 只有公開的 net_config。實作時要守住:新的 `fail()` 不得用 `%v` 印 payload。
- **錯誤碼對應**:forward 路徑走 `mapHelperR`(`session.go:664`),`hEReject` + reason → `E_REJECTED{2: 14}`(`:905-907`)✅;`EBadObject` 原樣、不計失敗次數、不寫 CRIT ✅。改掉 `node.go:1079` 的 `ESchema` 之後,轉送者灌 CRIT 的路就沒了。
- **角色表**:member 只有 `info`、`network/update`、`status`(`session.go:82`);被移除者的舊 psk 開不到 leave / settings / join ✅。未認證到不了 update ✅。
- **PSK 撤銷**:`reconcile` 對 member session 比值,不同就 `psk-rotated`(`server.go:648-650`);ops 忙時舊集合繼續生效(`:469`)。被移除者能用垃圾 update 拖長這段時間,但這段時間它拿到的只有 member 角色(info / update / status),HaLow 的 SAE 已在 `setkey` 時立刻換掉 ✅(§5 已寫「佔住 helper」是既有行為)。
- **secrets 綁定的修法**:比對 `decryptSecrets` 拿去當 KDF context 的同一份 (net_id, 版本)(`wtxn.go:133-140`),再加上 target_dac_hash(`:127-131`),所以修正後,對這台節點、這一版,只接受網主為這台產的 secrets ✅。app 每次送都重新產 secrets(`join2flow.rs:6`),內容相同,不影響綁定。
- **事實行號**:F1(`:1072`、`:1079`、`:1093`、`:1101`)、F3(`:1145`、`:1206`)、F5(`:756-758`;`session.go:79-82`)、F8 / F15、F9(`session.go:92-97, 531, 548`)、F11(`:613-621`)、F16(`readonly.go:136-142`、`server.go:555-569`)、F19(`netrec.rs:20`)、F21(`node.go:250-255`)都對得上 ✅。
- **生命週期**:我自己再掃一次,首次 / 斷電 / 升降級 / A/B 回滾 / provd 與 helper 重啟 / OTA 進行中(`node.go:247-248` → `E_BUSY`)/ 平台,都和原始碼一致;本變更沒有新狀態,crash loop 不適用的理由成立。唯一要補的是 m7(混合版本)。

## 逐 actor

| actor | 結果 |
|---|---|
| 遠端未認證(BLE) | 到不了 update ✅;能耗握手額度(既有,屬 app 的「未定」判斷,§3 已列) |
| 本機非特權程序 | 不新增 socket / 路徑 / 檔案 ✅ |
| 成員 session / 被移除者的手機(舊 psk) | 舊或別網 secrets → §2.2-5 擋 ✅;換 net_id / 國碼 / members → 擋或無效果 ✅;冒充落後節點吃掉轉送 → m3;wsl.24 節點 → m7 |
| 被攻陷的 provd | 能送任意 body = 同上;能扣住或謊報結果(既有)✅ |
| 共同網主 | 分叉 / 拼接,依使用者決定先不支援;§5 照實寫「沒有偵測手段」✅ |
| 實體取得 | 不變 ✅ |
| 供應鏈 | 不變 ✅ |
| 我們自己的錯 | 紀錄還原後重簽 → m5;mutant 漏網 → m6 |

## 前幾輪處理核對

| 項目 | 狀態 |
|---|---|
| v1 A-B1 / B-B1 secrets 綁版本 | ✅ §2.2-5、U11、U12、mutant |
| v1 其餘(冪等、大小、存 members 系列、行號、國碼、錯誤碼、硬體對照) | ✅ |
| v2 A-M1 重送回 `E_BAD_OBJECT` | ✅ F17、U14 |
| v2 A-M2 / B-M2 E_SCHEMA / CRIT | ✅ §0、§2.1、§4、U5、U15 都改成 `E_BAD_OBJECT`;`:1079` 已更正 |
| v2 A-M3 8 塊 | ✅ F9、U13 |
| v2 B-M1 版本號判成功 | ✅ 移到 app 設計(§3 清單) |
| v3 A-M1 / B-M2 規則 3 太寬、轉送做不了 | ✅ 規則移出;§3 清單帶 pin DAC、否定 / 未定、門檻、只告警、轉送重連、槽位;U16 給節點端依據。pin DAC 的範圍要擴大 → m3 |
| v3 B-M1 拼接 overclaim | ✅ §5 改成「今天沒有偵測手段」;共同網主不支援(使用者決定) |
| v3 A m1 / B m1 E_SCHEMA 殘留 | ✅ |
| v3 A m2 / B m4 同版號分叉、無限追 | ✅ §3 清單 |
| v3 A m3 members 嚴格度 | ✅ 縮成三項;但理由仍寫成安全理由 → m2 |
| v3 A m4 槽位 | ✅ |
| v3 A m5 向量版本 | ✅ §6 |
| v3 A m6 時序條件 | ✅ §6 時序(條件) |
| v3 A m7 混合車隊 | ⚠️ §4 有列,但低估了(m7) |
| v3 B m2 pin DAC | ⚠️ 只套在新 psk 證據,轉送沒有(m3) |
| v3 B m3 info 分支、key 11 | ✅ F21、§3 |
| v3 B m5 垃圾 update 佔 helper | ✅ §5 |
| v3 B m6 「進不了 mesh」的範圍 | ⚠️ 範圍照實寫了 ✅;「提示擁有者換 AP 密碼」沒進清單(m4) |
| v3 B m7 拒絕重新加入靠 app | ✅ §3、§5 |
| v3 B m8 `--update-stale-secrets` 說法 | ✅ §6 已收斂 |
| v3 B「被攻陷的 provd §5 補一句」 | ✅ §5 第一條已含 |

## 判定
**APPROVE-WITH-CHANGES(0 BLOCKER / 0 MAJOR / 7 MINOR)。**
- 節點端 §2 可以照做,安全性沒有問題。
- m1、m2 是安全事實的精確度,改文字就好。
- m3、m4、m5、m7 是 app 移除成員設計必須處理、目前清單沒列的安全項目,加進 §3 清單與 #254 checklist。
- m6 是兩個要補的負向測試(否則 mutant 會活下來)。
- 沒有 BLOCKER / MAJOR,改完不需要再整份審一輪。
