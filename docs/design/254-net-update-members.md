# #254 S6 移除成員的前置:節點 `network/update` 對齊 CDDL(v4.1,FROZEN)

狀態:**FROZEN v4.1**(2026-11-10)。第 4 輪兩位審查皆 APPROVE-WITH-CHANGES、0 BLOCKER / 0 MAJOR(A 8 m、B 7 m),MINOR 全部收進 v4.1(§11),依規則不必再審。實作在 Batman-p3 `feat/254-p3`,隨 **wsl.25** 出(與 p3-owner 一起),之後跑延後的完整 validation。
上游決定(使用者):
- #254 留言 6766306237:**改節點對齊 CDDL**(每一步帶 members-sign1,秘密只在最後一步);順手補 update 的國碼檢查;換密碼的切換 = (a) 接受暫時分裂(app 設計)。
- 2026-11-10 第 1 輪審查後:**成員清單不存、不跨次比對**(取代「wsl.24 節點寬鬆」:沒有存就沒有寬鬆與嚴格之分);**落後太多版 → 照 CDDL,app 先算大小,超過就走離開 + 重新入網**;harness PR 與 wsl.25 一起合(先 harness)。
- 2026-11-10 第 3 輪審查後:**移除共同網主先標為不支援**(app 一個網路只有一位網主,這情況還不會發生)。

v1 → v2:第 1 輪 A(1 B / 3 M / 10 m)、B(1 B / 2 M / 8 m),見 §8。v2 → v3:第 2 輪 A(0 B / 3 M / 10 m)、B(0 B / 2 M / 9 m),主要在 §3 契約與測試;節點端 §2 只改「形狀錯的錯誤碼」與國碼缺 key 的分支,見 §9。v3 → v4:第 3 輪 A(0 B / 1 M / 7 m)、B(0 B / 2 M / 8 m),MAJOR 全在 v3 新加的「app 判斷成功」規則;v4 把它移出本文件(app 怎麼判斷結果屬 app 移除成員設計,本文件只給節點的事實),members 檢查縮成必要的三項,見 §10。

## 0. 範圍

做:
1. `network/update` body 改成 CDDL 形狀 `{1: [+ {1: netcfg-sign1, 2: members-sign1, ?3: secrets-sign1}]}`(`219-protocol.cddl:231-237`)。
2. 每一步驗 members-sign1:網主簽章、net_id、版本 = 該步 net_config 的版本。**不存、不比 prev_hash、不檢查內容結構**。這三項是**對齊 219 / CDDL 的一致性檢查,不是安全防線**:節點不存也不讀 members(F3),換掉它對節點沒有任何後果(第 4 輪 A m4、B m2)。
3. 每一步的 net_config 驗 net_id = 已存的 net_id。
4. **net_secrets 綁版本(第 1 輪兩位都抓到的 BLOCKER,wsl.24 既有漏洞)**:secrets payload 的 net_id、版本必須等於這一版 net_config 的 net_id、版本。join 與 update 共用 `parseNet`,一處修好兩邊。
5. 國碼:任何一步的 net_config key 5 ≠ 已存 net_config 的 key 5 → `E_REJECTED{14}`,什麼都不寫(254-p3-impl D9 的 update 那半)。

不做(原因):
- 存成員清單 / 跨請求比對 prev_hash:使用者決定(§8 A-M3、A-m2、A-m3、B-M2、B-m5、B-m8 都因此消失)。節點上沒有讀者用成員清單(F3)。`Record.Members` 維持今天的樣子(永遠 nil)。
- `network/join` 的國碼檢查(D9 join 那半):會改到 S1–S3 已真機跑通的入網路徑;已在 #254 checklist(留言 6767159567)。
- join 帶的 members(key 2):維持忽略(F2)。
- 舊形狀 `{1:[netcfg…], 2: secrets}`:除了 provclient 與 Go 測試沒有人送(F4),不保留 → `E_BAD_OBJECT`。
- **app 怎麼判斷 update 是否成功、怎麼偵測分叉**:屬 app 移除成員設計(之後另寫、另審);本文件 §3 只列節點會給 app 的事實,與 app 設計必須處理的事。
- **移除共同網主**:使用者決定先不支援(§5、§7)。
- 分叉(219 §7.5「雜湊較小者勝、看到勝出的鏈就切換」):節點今天就不實作,本變更不改。已套用落敗那支的節點之後每一版的 prev_hash 都接不上(`E_STALE_VERSION`),恢復 = 離開 + 重新入網。app 不得產生分叉(單一網主 app 時不會發生)。
- 冪等快取(219 §4.2):provd 沒有實作(F11),本變更不加;契約照實際行為寫(§3)。
- net_config 的未知 key 拒絕(§7.1)、中間步 `adminsOf` 不檢查 65 B / ≤ 4 把:今天就是這樣(F12),不在本變更;進 #254 checklist。

## 1. 事實(Batman-p3 e5c89a1;04 上跑的 image 版本字串 `1.5.14-wsl.24+e5c89a1.fw7ce6e80` 即此 commit(scratchpad `toa24.log:3`);provstore 與 main 832fbf8 無差異)

- F1 今天的 update:`node/node.go:1072-1112` 讀 `body[1]` = net_config 陣列、`body[2]` = 最後一版的 secrets;每版以前一版的 admins 驗(`:1093`),版本 +1 且 prev_hash = 前一版 OBJECT_HASH(`:1101`);已存 net_config 用 `Sign1Payload` 取雜湊、不重驗(`:1083-1086`);最後一版 secrets 以 `adminsOfPrev` 驗(`:1107-1108`, `:1115`);然後 `applyNet`(`:1126`)。
- F2 join 忽略 key 2:`netJoin :1024-1041` 只讀 key 1、3。
- F3 `Record.Members` 從未被寫成非 nil:唯一的寫是 leave 清 nil(`node.go:1206`);`applyNet` 的 `next := *rec`(`:1145`)原樣帶著它。
- F4 送 update 的:`tests/tools/provclient/net.go:237-251`(`--update`);Go 測試 `node/wtxn_test.go:112-113`(`rig.applyUpdate`,呼叫者含 `wtxn_test.go:448,455`、`wtxn_v8_test.go:24`)、`provd/route_test.go:372-546`。app 還沒送 update。用 provclient `--update` 的 harness 單元:`prov-netupdate-254.sh`、`prov-powerloss-254.sh`、`prov-country-join-254.sh`。
- F5 update 的路由:`node.go:756-758` 在 owner-op 驗證之前分流到 `netUpdate`(不帶 owner-op,219 §5.3);provd 允許 owner 與 member session 送(`provd/session.go:79, 82`)。信任只來自 admins 簽章。
- F6 update 沒檢查 net_id:`parseNet` 只驗長度(`node.go:970-972`)。
- F7 D9 國碼檢查兩半都沒實作(`grep ReasonCountryJoin` 只在 `settingsset.go:21,123`)。harness CJ2(`prov-country-join-254.sh:3-6`)期待 update 改國碼 → `E_REJECTED{14}`。
- F8 錯誤碼:helper `EReject = 24`(`node.go:53`)+ reason → provd `hEReject 24`(`provd/helper.go:26`)→ `E_REJECTED` 帶 reason(同 `settings.set`,`settingsset.go:123`)。
- F9 大小:provd 分塊上限 `MaxChunks = 8`、`MaxReassembled = 65400`(`provd/session.go:92-97`),每則訊息 `MaxMsg = 8192`(`provd/frame.go:15`);**實際先卡住的是 8 塊**:每塊是一整個信封(≤ 8176 B 明文),body 切片後 8 塊最多約 65 1xx B(第 2 輪 A 以節點 CBOR 算 65 112–65 144),不到 65400。超過(第 9 塊或重組 > 65400)時 `chunk()` 回 error(`:531, :548`)→ `onEnvelope` 回 error(`:477-479`)→ 該 session 結束(`:326-328`),**沒有錯誤碼**,每次重送都一樣。helper 請求上限 65536(`sock/sock.go:25`)。app 的分塊器只知道 1 MiB 上限(`envelope.rs:13`),不知道 8 塊。
- F10 secrets 未綁版本:`decryptSecrets`(`node/wtxn.go:126-152`)只比 target_dac_hash;net_id / 版本取自 secrets 自己的 payload、拿去當 KDF context(`:133-140`),從不和 net_config 比。兩位審查在 /tmp 複本實測:`v2 cfg + v1 secrets -> code 0, wl=sae-v1-pass/m2/36, ver=2`;`v3 cfg + other-net secrets -> code 0`。
- F11 沒有冪等快取:`provd/session.go:616-620` 請求帶 key 7 一律回 `E_UNSUPPORTED{1:"idem"}`(秘密類回 `E_FORBIDDEN`)。helper 逾時 → `E_BUSY{3:"outcome unknown — re-read info"}`;helper 連線斷 / 忙 → `E_BUSY`(無 detail)(`session.go:589-611`)。
- F15 錯誤碼對應 `mapHelper`(`provd/session.go:567-582`):helper 的 `EForbidden / EBadObject / EStaleVersion / EBusy / EStorage / ERate` 原樣;`EApply / EState` → `E_REJECTED{}`(無 reason);**`ESchema` → `E_REJECTED{}` 並記一行 CRIT「a provd bug」**;協定沒有 `E_SCHEMA` 這個碼。帶 reason 的 `EReject` 走 settings 那條(F8),到 app 是 `E_REJECTED{2: 14}`。
- F16 `info` 的 key 9 = net 版本、key 10 = net_id、key 11 = **unfinished**(`.txn` 還在)(`provd/server.go:555-569` ← helper `info.net` `node/readonly.go:136-142`)。Left 不在 `info`。
- F17 重送已套用的版本:簽章檢查(`node.go:1093`)在版本檢查(`:1101`)之前 → admins 有換的那一版重送時,第一步的簽章對不上目前的 `rec.Admins` → `E_BAD_OBJECT`,不是 `E_STALE_VERSION`(第 2 輪 A 探針 `resend v2 after handover -> 4`)。
- F18 分叉:同一版本兩個都由網主簽的物件(被移除的共同網主搶先、或 app 對同一版號重簽),節點先收到哪個就套哪個,之後正版的下一版 prev_hash 接不上;`info` 沒有 net_config 雜湊,app 看版本號分不出(第 2 輪 B 探針:`fork apply -> 0`、`legit v3 apply -> 4 (version now 3, wl=attacker-sae/m2/36)`)。secrets 只綁 (net_id, 版本),不綁哪一份 net_config(`splice fork cfg + legit v3 secrets -> 0`)。
- F19 app 一個網路的成員上限 `MAX_MEMBERS = 16`(`netrec.rs:20`)。
- F20 PSK 與 session:節點的 `psk_member` = HKDF(已存 secrets 的 net_root, 已存的 net_id, 已存的版本)(`node.go:426-432`,`proto.PskMember`):**每一版都換 psk**;但手上有舊 net_root 的人(被移除的手機)能算出**任何一版**的 psk,只要那一版沒換 net_root。所以移除成員的那一版必須換 net_root(§3);update 成功後 provd 只設 `needPSK`,由 500 ms tick 在 ops 空閒時重抓,ERate / 忙碌時「the old set keeps serving」(`provd/server.go:434-470`);用舊 psk 的成員 session 被 `psk-rotated` 直接斷線(`server.go:650`);psk 對不上 → 假 msg2(`provd/noise.go:89-96`),app 看到的與其他失敗一樣;握手限速在驗 PSK 之前,任何未認證 BLE 對端都能耗用。
- F21 `.txn` 留著(info key 11 = true)時,下一個會改狀態的動詞先 Finish 再做(`node.go:250-255`);沒有這樣的動詞時(例如 SaveTxn 失敗後沒人再送),`.txn` 一直留到下次開機的 Finish。
- F22 helper 沒有任何 `recover()`(`grep -rn "recover()"` 非 vendor 為空):解析 body 時 panic = helper 程序結束、由 procd 重啟;任何 member session 都能送任意 body。
- F23 `info` key 4 = 韌體版本字串(`provd/server.go:549`,例如 `1.5.14-wsl.24+e5c89a1.fw7ce6e80`);OTA / 試用中改狀態的動詞回 `E_BUSY`(`node.go:239, 248`)。
- F24 `node/wtxn.go:125` 的註解寫 decryptSecrets 做「net_id / version binding」,實際沒有(F10);實作時一併更正註解。
- F12 net_config 的未知 key 今天不拒絕;中間步只經 `VerifySign1` + `adminsOf`(`node.go:1043-1070`,不檢查 65 B / 數量),最後一步經 `parseNet`(檢查 65 B、1–4 把)。
- F13 app 產的 secrets 一律用 net_config 的 net_id / 版本:`approve.rs:215`、`join2flow.rs:366`、`joinflow.rs:220`(v1)→ §2.2-5 不影響 S1–S3。
- F14 已存 net_config 的 key 5:app 產的 net_config 一律有 key 5(`netrec.rs:103` 必填讀取);Go 測試 rig 的 `mkNet` 沒有 key 5(`wtxn_test.go:73-80`)。

## 2. 設計

### 2.1 body
`netUpdate(rec, body)`:
- `rec.Net == nil` → `E_STALE_VERSION`(不變)。
- `body[1]` 必須是非空陣列,每一項是 map;否則 `EBadObject "update shape"`(舊形狀的元素是 tag 18 → 同)。
- 每一步:key 1、key 2 必填;key 3 只在最後一步、且必填(CDDL 寫的是 `? 3`;節點**刻意收緊**為最後一步必填,因為沒有 secrets 就無法套用;CDDL 更正進 checklist);缺、或前面的步帶了 key 3 → `EBadObject "update shape"`。步內其他 key 忽略(CDDL `* uint => any`)。body 的其他 key 忽略(同今天)。
- **形狀錯一律 `EBadObject`,不用 `ESchema`**:body 來自轉送者(任何 member session,含被移除者的手機),`ESchema` 會變成 `E_REJECTED{}` 並記 CRIT「provd bug」(F15),既和套用失敗撞碼,又讓任何成員能灌 CRIT。今天的 `ESchema "version chain"`(`node.go:1079`)一併改成 `EBadObject`。

### 2.2 每一步的檢查(依序;第一個失敗就回;全部在 `applyNet` 之前,失敗時什麼都沒寫)
`signers` = 前一版的 admins(第一步 = `rec.Admins`),`prevCfgHash` / `prevVer` 同今天(F1);`storedCC` = 已存 net_config payload 的 key 5(`Sign1Payload`,不重驗,同 `:1083-1086`)。
1. net_config:`VerifySign1(cfg, CTNetcfg, LabelNetcfg, signers)` 失敗 → `E_BAD_OBJECT "chain link"`(不變);版本 ≠ prevVer+1 或 prev_hash ≠ prevCfgHash → `E_STALE_VERSION`(不變);**net_id ≠ `rec.Net.NetID` → `E_BAD_OBJECT "net_id"`**(新)。
2. **國碼(新)**:該步 key 5 與 `storedCC` 都存在、都是 tstr 且逐位元組相等 → 通過;其他(任一邊缺、型別不同、值不同)→ `failR(EReject, 14)`,到 app 是 `E_REJECTED{2: 14}`。每一步都比。Go 測試 rig 的 `mkNet` 補上 key 5(F14),不為它留分支;真實網路的 net_config 都有 key 5(app `netrec.rs:103`、provclient `net.go:194`)。
3. **member_list(新)**:`VerifySign1(members, CTMembers, LabelMembers, signers)`(與同一步 net_config 同一組 signers,§7.1);payload key 1 = `rec.Net.NetID`、key 2 = 這一步 net_config 的版本。任一不符 → `E_BAD_OBJECT "member_list"`。其他欄位(prev_hash、成員、removed、invites)節點不檢查:它不存也不讀(F3),結構正確與否是 app 的責任。這是一致性檢查(對齊 CDDL「每一步帶該版的 member_list」),不是安全防線。
4. signers ← 這一步 net_config 的 admins(不變)。

最後一步再經 `parseNet`(不變的部分:簽章、admins、ssid、channel、SAE ≥ 8),加:
5. **secrets 綁版本(新,join 與 update 共用)**:secrets payload key 1 必須等於 net_config 的 net_id、key 2 必須等於 net_config 的版本,否則 `E_BAD_OBJECT "net_secrets"`。`openSecrets` 改成連同已驗過的 Sign1 payload 一起回傳,比對用的就是 `decryptSecrets` 拿去當 KDF context 的同一份值(不重新解碼)。第 2 輪 A 在 /tmp 複本實作此比對:F10 的 PoC 由 code 0 變 code 4、紀錄停在 v1,`go test ./node/ ./provd/` 全過。

錯誤碼只是提示(F17:重送已套用的版本也可能回 `E_BAD_OBJECT`);app 怎麼判斷結果見 §3 交給 app 設計的事項。

### 2.3 存
不變:`applyNet` 照今天寫 Net / Admins;`Members` 不寫(永遠 nil,F3)。`.txn`、commit 點、Finish 都不變。

## 3. 擁有權 / 契約

| 資源 | 唯一寫者 | 讀者 |
|---|---|---|
| `prov.cbor` 的 Net / Admins(不變) | helper `applyNet` 經 `commitTxn`;leave 清 | helper |
| `network/update` body | 寫:owner app、成員 app(轉送)、provclient(harness);provd 原樣轉給 helper | helper `netUpdate` |

本變更不新增任何持久狀態。

`network/update` 對 app 的介面(節點的事實;app 怎麼用它判斷結果屬 app 移除成員設計)。

**回應碼**(實際會到 app 的,F15):

| 回應 | 何時 |
|---|---|
| `0 {1: 新版本}` | 套用成功 |
| `E_STALE_VERSION` | 節點沒有網路;鏈的起點不是節點目前版本 |
| `E_BAD_OBJECT` | 形狀錯、簽章 / net_id / 版本綁定 / members / secrets 不符;**也可能是已套用後重送**(F17);wsl.24 收到新形狀 |
| `E_REJECTED{2: 14}` | 國碼不同 |
| `E_REJECTED{}` | 套用失敗(HaLow 被手動關、setkey 失敗、狀態不對),**或**之前未完成的變更 Finish 失敗 / verdict 未定 —— 後兩者**不保證已退回原狀**,要讀 `info` key 11 |
| `E_STORAGE` | 存檔失敗 |
| `E_BUSY{3: "outcome unknown…"}` | helper 逾時,結果不明 |
| `E_BUSY`(無 detail) | 另一個動作進行中 / helper 連線斷 / OTA 寫入或試用中(F23);未送達或結果不明 |
| `E_UNSUPPORTED{1: "idem"}` | 請求帶了冪等鍵 key 7(F11) |
| (沒有回應,session 結束) | 請求超過 8 塊(F9);或轉送成功後該成員 session 因 `psk-rotated` 被斷(F20),回應可能送不到;或 helper 程序結束(F22) |

**節點給 app 的狀態**:`info` key 9 版本、key 10 net_id、key 11 unfinished(F16;`info.net` 被限速時 9–11 整組不回);key 11 為 true 時下一個改狀態的動作會先 Finish(F21),所以等一段時間後重送是安全的;換新秘密後 `psk_member` 由新 net_root 導出,但 provd 換 PSK 集合有空窗(F20)。

**app 移除成員設計必須處理的事**(本文件不設計;進 #254 checklist,第 3 輪兩位審查的 MAJOR 原樣帶過去):
- **所有成員 session 都要 pin 目標節點的 DAC**(`psk_member` 全網共用、不含裝置識別:被移除的節點拿舊 psk 就能冒充落後節點,吞下轉送的 update、回假的成功;它解不開 secrets,因為 secrets 以目標 DAC 加密)。
- 判斷 update 結果不能靠錯誤碼(F17)也不能只靠版本號(F18 分叉);用新 `psk_member` 握手當證據時:握手失敗要區分「否定」(AEAD 失敗)與「未定」(空窗、限速、斷線、逾時)、要有重試與門檻、判定可疑時只告警由使用者決定,不自動要求離開;握手成功**也不證明 net_config 是 app 發的**(拼接,F18)。
- 轉送情境:成功後成員 session 會被斷(F20),要用新 psk(pin DAC)重連、不行再用舊 psk 讀 `info`;成員與擁有者 session 搶 provd 的 2 個槽位,先關擁有者 session。
- `info` 的分支:沒有 key 9 / 10、key 10 不是本網、key 11 長時間為 true;key 9 = 送出前版本卻回 `E_STALE_VERSION` / `E_BAD_OBJECT`(可能是同版號分叉);key 9 > 目標時不可無限追。
- 移除成員的那一版必須換 SAE 與 net_root(LoRa PSK 若有也換)——換 net_root 是因為舊 net_root 能算出任何一版的 psk_member(F20);被移除的節點與手機拿不到新版 secrets / member_secrets;之後審核加入申請時擋 member_list 的 removed 名單(節點擋不了)。
- 先把新版本寫進 app 紀錄再送;**同一個版號只簽一次**,重送用已存的那份;新版號取 max(app 紀錄的版本, 各節點 `info` key 9)+ 1(app 紀錄還原或倒退後重簽同一版號,只有一位網主也會造成分叉)。
- 不帶冪等鍵 key 7(F11;219 §4.2 寫允許,與節點不符 → 219 更正進 checklist)。
- 移除成員後提示擁有者改各節點的手機 AP 密碼:手機 AP 不隨 mesh 換密碼,被移除者仍可能從手機 AP 經 IP 層進到整個 mesh。不實作 219 §7.5「雜湊較小者勝」(任何網主都能磨出較小雜湊)。
- 送之前用 app 分塊器算塊數,**> 8 塊不送**,走離開 + 重新入網。
- 保存歷代 net_config / member_list;`member_list_payload` 要能帶 removed / used / revoked;member_list 的結構正確由 app 負責(節點不檢查)。
- `approve.rs:281-285` 用同一版 admins 驗 members / secrets,節點與 219 §7.1 用前一版:換 admins 的那一版要對齊。
- 畫面列出停在舊版的節點(暫時分裂,決定 (a))。
- **網路裡還有 wsl.24 節點時不得開始移除成員**(以 `info` key 4 認出,F23):wsl.24 收不到新形狀,而且有 F10 漏洞,被移除者能在它身上用舊 secrets 配新設定;要先全部升級。wsl.24 時期若被灌過 F10 那種紀錄,升級後下一次合法 update 會整個覆蓋(secrets 與 net_config 都換成新版)。
- update 也是全網改頻道 / 名稱的路(net_config 的其他欄位),同一套流程。
- 國碼:app 絕不產生改國碼的版本。

大小:每一步 ≈ net_config(300–560 B,1–4 位網主)+ member_list(≈ 300 B + 每位成員 ≈ 290 B + 每筆 removed 32 B / invite 16 B);最後一步再加 secrets(≈ 250 B)。⚠️ 估算:app 上限 16 位成員(F19)時每步 ≈ 5.5 KB → 約 11 版;10 位 ≈ 17 版。實作時以真物件量測(U13),量測值寫回這裡。

## 4. 生命週期

| 路徑 | 今天 | 之後 | 證明 |
|---|---|---|---|
| 首次 / 沒有網路 | update → `E_STALE_VERSION` | 不變 | 既有 `route_test` |
| start / clean stop / restart | 請求內完成,無新狀態 | 不變 | — |
| 斷電 / crash 在 update 中 | `.txn` + p5 commit 點,Finish | 不變(沒有新狀態) | U9(新增經 `netUpdate` 的 seam 測試) |
| 回應遺失 / 網路斷 | 沒有冪等快取(F11),重送 → `E_STALE_VERSION`,換 admins 的版本則 `E_BAD_OBJECT`(F17) | 不變;app 讀 `info`(§3) | U14 |
| 升級 wsl.24 → wsl.25 | — | 紀錄不變;新形狀可用;舊形狀 → `E_BAD_OBJECT` | U5 |
| 混合版本車隊(部分節點仍 wsl.24) | — | wsl.24 節點對新形狀回 `E_BAD_OBJECT`,移除成員在它身上不生效,要先升級;它仍保有舊 SAE,與已換新的節點分屬兩邊(暫時分裂) | §3 交給 app |
| 降級 wsl.25 → wsl.24 | — | 紀錄不變(本變更沒動紀錄);wsl.24 對新形狀回 `E_BAD_OBJECT`(app 處理見 §3);**降級後 F10 的漏洞重新存在**(wsl.24 本來就有) | §3 |
| provd 重啟 | 連線斷 | 不變 | 既有 |
| helper 重啟 / crash loop | procd 重啟 helper;沒有 `recover()`(F22) | 新解析碼一律用帶 ok 的型別斷言、不做未檢查的索引,任意 body 不 panic | U17 |
| HaLow 驅動重啟 / setkey 失敗 | `applyNet` 失敗 → Finish 退回 | 不變 | 既有 wtxn 測試 |
| 平台 bcm2711 / bcm2710 | 同一份 Go | 同 | 兩板 build;Pi3 暫不支援(2026-10-23),只編譯 |

## 5. 安全

- 資產:節點的 mesh 秘密(SAE、net_root)、它加入哪個網路;移除成員的目標 = 被移除的節點與手機拿不到新秘密、進不了 mesh。
- **成員 session / 被攻陷的 provd / 分裂期間被移除者的手機**(能送任意 body;被移除者的舊 `psk_member` 對落後節點仍開得了 member session):
  - 新版設定配舊版或別網的 secrets(F10)→ §2.2-5 擋(`E_BAD_OBJECT`),這是本變更的 BLOCKER 修正;
  - 重送舊鏈 → 版本不連續(既有);換 net_id → §2.2-1;改國碼 → 要網主簽且 §2.2-2 擋;
  - 跨步或跨版本交換 members → members 綁該步版本與 net_id、要網主簽;
  - 持續送垃圾 update 佔住 helper,讓其他人拿到 `E_BUSY`、拉長分裂期:既有行為(ops 一次一個),不在本變更;
  - 超大請求 → 8 塊上限、session 被關(F9),不影響節點狀態;
  - 冒充落後節點(被移除的節點拿舊 psk 接下轉送)→ 拿得到 body 但解不開 secrets(以目標 DAC 加密);app 以 pin DAC 擋(§3);
  - 讓 helper panic → 新解析碼不 panic(U17);
  - 它能做到的只有「不送」或「送舊的」,節點停在舊版——與今天相同,不是新的面。
- **分叉與拼接**(F18):secrets 只綁 (net_id, 版本),不綁哪一份 net_config;同版本兩份都由網主簽的物件可以互換,而且 `psk_member` 只由 secrets 導出(F20),所以**握手成功也偵測不到拼接**(第 3 輪 B 探針:`splice ... -> code 0`、`psk_member == psk_member(R2,..): true; stored admins == [b]: true`)。這只有網主(或被移除但仍在 v 版 admins 裡的共同網主)做得到,是 219 §7.1 的固有限制;今天沒有偵測手段。
- **移除一位共同網主**:被移除的網主仍在 v 版 admins 裡,可以搶先簽 v+1(保留舊 SAE 或另起分叉),節點與 app 都無從分辨。**使用者決定:先標為不支援**(app 一個網路只有一位網主,這情況還不會發生);要支援時再設計(例如 info 回已存 net_config 的雜湊),進 #254 checklist。
- **移除成員的範圍**:「進不了 mesh」只指 HaLow mesh(SAE)。各節點手機 AP 的密碼由擁有者自設;LoRa PSK / team AP 的 key 節點目前不使用。被移除者之後重新申請加入,要由 app 審核時擋(member_list 的 removed),節點擋不了。
- 遠端未認證:到不了 update(provd 角色表)。本機非特權程序:到不了 helper socket(既有)。實體取得:不變(prov.cbor 0600)。
- 新輸入:每一步的 key 2 / key 3 位置;CBOR 解碼走既有 `cbor.Decode`。特權:helper 以 root 跑(既有),新程式只讀請求內資料與已存紀錄,不碰路徑。
- 秘密:不新增;log 只寫錯誤原因字串,不寫物件內容。
- 失敗模式:全部 fail-closed。members 只做一致性檢查(§2.2-3),不是安全防線。

## 6. 測試

Go 單元(`node/`;`rig.applyUpdate` 與其呼叫者 F4 改新形狀;每項斷言 code,失敗項另斷言紀錄 / `.txn` / setkey 呼叫次數未變):
- U1 一步新形狀 → 0;setkey 收到新 SAE;紀錄版本 = 新版。
- U2 兩步鏈 → 0。
- U3 members 由非網主簽 → `E_BAD_OBJECT`。
- U4 members 版本 ≠ 該步 net_config 版本;members net_id ≠ 已存;net_config net_id ≠ 已存 → 各自 `E_BAD_OBJECT`。構造:net_config net_id 不符那一項,secrets 的 net_id 要與**該 net_config** 一致(否則 §2.2-5 先擋、§2.2-1 的 mutant 會活);另一項錯在兩步鏈的**中間步**。
- U4b 換網主的那一步:該步 members 由**新** admins 簽(不是前一版 admins)→ `E_BAD_OBJECT`;由前一版 admins 簽 → 0(殺掉「改用這一步 admins 驗」的 mutant)。
- U5 secrets 在非最後一步、最後一步缺 secrets、缺 members、步不是 map(舊形狀)→ 各自 `E_BAD_OBJECT`。
- U7 國碼:兩步鏈**中間步** key 5 ≠ 已存、最後一步同國碼 → `EReject` reason 14(provd 層 `E_REJECTED{2: 14}`;證明每一步都比);同國碼 → 0;新的缺 key 5 → 14;已存的缺 key 5 → 14。
- U15 形狀錯(非陣列、步不是 map、缺 key、secrets 位置錯)經 provd → `E_BAD_OBJECT`,且 provd log 沒有 CRIT 行。
- U8 provd `route_test` 的 update 改新形狀;member session 轉送照樣通(只證明路由,假 helper 碰不到 `netUpdate`)。
- U9 **新增**經 `netUpdate` 的斷電 seam 測試(既有 seam 測試只走 join):在 txn2 / txn3 停 → Finish → 退回時紀錄是舊版、無線是舊值;txn4 停 → Finish → 前進,紀錄與無線都是新版。
- **U11 新版 net_config + 這台節點的舊版 secrets → `E_BAD_OBJECT "net_secrets"`**,紀錄 / `.txn` / setkey 不變(這是兩位審查 PoC 的反轉:修正前 code 0)。
- **U12 別的 net_id 的 secrets(同網主、目標是這台)→ 拒絕**;join 帶版本不符的 secrets → 拒絕(`parseNet` 共用)。
- U13 大小(provd 層、真分塊、MaxMsg 8192):16 位成員的真物件鏈,剛好 8 塊 → 0;多一步變 9 塊 → session 結束、紀錄不變;量測每步大小,回填 §3。
- U14 套用後原樣重送 → `E_STALE_VERSION`、紀錄不變;換 admins 的版本套用後重送 → `E_BAD_OBJECT`、紀錄不變(F17,固定行為)。
- U16(provd + 真 helper,給 app 設計用的事實):v1 與 v2 用**不同的 net_root**(rig 預設固定 `make32(9)`,要改);update 到 v2 後,等 provd 重抓 PSK,用 `psk_member(v2)` 開成員 session → 成功;用 `psk_member(v1)` 或錯的 root → 假 msg2(負對照)。
- U17 不 panic:表格 + Go fuzz(`FuzzNetUpdate`,種子 = 各 U 的 body):任意 CBOR body 經 `netUpdate` 只回錯誤碼、不 panic;負對照 = 拿掉一個 ok 檢查的 mutant 會 panic。
- 換網主後再 update(以 `TestHandoverStoredObjectsNotReverified` 為底):v2 交給新網主 → v3 由新網主簽 → 0(國碼比對用 `Sign1Payload` 不重驗)。
- 負對照(mutation,每個 mutant 新的 GOCACHE):§2.2-1 net_id、§2.2-2 國碼(含缺 key、只比最後一步)、§2.2-3 members 的簽章 / net_id / 版本各一、members 改用這一步 admins 驗、§2.1 秘密位置與形狀錯的錯誤碼、**§2.2-5 secrets 的 net_id 與版本各一**、國碼取值改成 `VerifySign1` → 各自至少一個 U 失敗。

跨語言:`tests/vectors/219-protocol/gen.py` 已是 CDDL 形狀(第 1 輪 A 查證);加一個「update 一步」的完整向量:先 join v1、再 update 到 v2 的一步(cfg v2、members v2、secrets v2);向量內含一把**僅供測試**的節點 DAC / ECDH 私鑰,Go 測試用它建 fake keystore 並套用(Python 產、Go 讀)。現有的 `_upd_body` 只是分塊用的向量,不是可套用的 update。provclient 的 objectHash label 表補上 members。

Harness(#290 測項只有一套;依使用者決定 A,與 wsl.25 一起合、先合 harness):`provclient --update` 改送新形狀(每步附 members-sign1,版本 = net_config 版本;secrets 用同一版),並加 `--update-stale-secrets`(新版 net_config 配一份**新產、但版本 = 目前版本**的 secrets;provclient 拿不到節點上存的那份,這樣構造等價);`prov-netupdate-254` 加一臂斷言它回 `E_BAD_OBJECT`、版本與無線都沒變:證明出貨 image 拒絕它(硬體上沒有修正前的對照;修正前會接受的證據是第 1–3 輪審查在 /tmp 複本的探針與 U11 的 mutant)。真機只在 wsl.25 上跑 `prov-netupdate-254`(含這一臂)、`prov-powerloss-254`、`prov-country-join-254`(CJ2 + P)。
時序(條件):**harness PR 只在 wsl.25 rc 已燒到 04 / 02 之後才合**;完整 validation 在那之後、PR 合併之前跑(驗證產物 = 出貨產物),所以合併時節點已是 wsl.25,每日全套不會對著 wsl.24 跑這幾個單元。若 rc 還沒上機就要合,先問使用者。
誠實界線:這些硬體單元只證明 wsl.25 上新形狀的正向路徑與國碼拒絕(CJ2);§2.2 各項檢查的負對照只有 Go mutant。wsl.24 不跑(決定 A),它只會證明「舊版拒絕新形狀」,沒有判別力。

## 7. 使用者決定(2026-11-10)
- **A**:harness PR 與 wsl.25 產品 PR 一起合併,先合 harness;兩者之間不在 wsl.24 上跑那三個單元(§6 時序)。
- 成員清單不存、不跨次比對。
- 落後太多版:照 CDDL,app 先算大小,超過走離開 + 重新入網。
- D9 join 國碼:本次不做,在 #254 checklist。
- 移除共同網主:先標為不支援。

新增進 #254 checklist(本變更不做):
- net_config 未知 key 拒絕、中間步 admins 的 65 B / ≤ 4 檢查(F12)。
- app 移除成員設計:§3「app 移除成員設計必須處理的事」全部。
- 219 §8 寫 1 MB 上限、app 分塊器也只知道 1 MiB(`envelope.rs:13`),與 provd 的 8 塊不符 → 219 §8 要更正。
- 219 §4.2 允許 update 帶冪等鍵、provd 不支援 → 219 更正。
- CDDL `update-step` 的 key 3:改成「最後一步必填、其他步不得出現」。
- 移除共同網主(不支援;要做時再設計,例如 info 回已存 net_config 的雜湊)。

## 8. 第 1 輪審查處理

(§8–§10 是歷史紀錄:裡面指到的「§3 規則 1–4」、「七個 key 必填」、U6 等已在後面幾輪移除或改寫,以本文 §0–§7 為準。)

| 項目 | 處理 |
|---|---|
| A-B1 / B-B1 secrets 未綁版本 | §0-4、§2.2-5、U11、U12、mutant;§5 改寫 |
| A-M1 冪等快取不存在 | F11;§3 表照實際行為;§4 改列;U14 |
| A-M2 / B-M1 大小上限 | F9;§3 表與大小;使用者決定 app 預算 + 重新入網;U13 |
| A-M3 已存 members 不重驗 | 不存了,消失;國碼取值明寫不重驗 + 換網主測試 + mutant |
| B-M2 降級殘留 Members | 不存了,消失(§4 降級列) |
| A-m1 行號 / F4 呼叫者 / prov.meta | F1、F4 更正;§3 不再提 prov.meta |
| A-m2 寬鬆範圍超出決定 | 使用者改成不存、不比 |
| A-m3 降級殘留 | 同 B-M2 |
| A-m4 / B-m7 錯誤碼 | §2.1、§2.2 逐項錯誤碼 + 取捨;§3 表 |
| A-m5 / B-m3 國碼語意 | §2.2-2 規則;§3 app 契約 |
| A-m6 MaxRecord 在 setkey 後才失敗 | 紀錄大小不變(不存 members),不再適用 |
| A-m7 / B-m4 硬體負對照 | §6 誠實界線 |
| A-m8 / B-m5 provclient 前一版 members | 不跨次比對,不需要 |
| A-m9 mutant 缺項 | §6 補齊 |
| A-m10 舊節點偵測、分叉 | §3 表 fw_version;§0 分叉 |
| B-m1 分叉拼接 | §0 分叉;不存 members,拼接無持久影響 |
| B-m2 移除共同網主 | §5 限制 + checklist |
| B-m6 未知 key 不一致 | §0 刻意不對稱 + checklist |
| B-m8 已存 members 的意義 | 不存了,消失 |

## 9. 第 2 輪審查處理

| 項目 | 處理 |
|---|---|
| A-M1 已套用後重送可能回 `E_BAD_OBJECT` | F17;§2.2 尾「錯誤碼只是提示」;§3 規則 1–4 一律讀 `info`;U14 |
| A-M2 / B-M2 沒有 `E_SCHEMA`、撞碼、CRIT;表缺列;key 11 | F15、F16;§2.1 形狀錯改 `EBadObject`(含既有 `node.go:1080`);§3 回應碼表補齊;U15 |
| A-M3 大小上限是 8 塊不是 65400 | F9 改寫;§3 前提「> 8 塊不送」;U13 改 provd 層真分塊 |
| B-M1 用版本號判成功會被分叉騙 | F18;§3 規則 3 用新 psk_member 握手;前提:換 net_root、同版號只簽一次 |
| A 國碼兩邊缺 key 的分支 | 拿掉,`mkNet` 補 key 5 |
| A U8 / U9 沒判別力 | U8 寫明只證路由;U9 改為新增經 `netUpdate` 的 seam 測試 |
| A F9 引錯、e5c89a1 無證據 | F9 改 `sock.go:25`;§1 標題附 04 版本字串 |
| A 分叉時 app 無出口 | §3 規則 3:停、告警、離開 + 重新入網 |
| A fw_version 格式 | 不判版本字串,§3 規則 2 一律提示更新 |
| A 跨語言向量 keystore | §6 向量帶測試私鑰 |
| A `openSecrets` 回傳 payload | §2.2-5 |
| A members 七個 key 必填 | §2.2-3 |
| A app 保存歷代物件、member_list_payload 參數 | §3 前提 + §7 checklist |
| B m1 真上限與 16 位成員 | F9、F19、§3 大小 |
| B m2 key 11 = unfinished | F16、§3 規則 1 |
| B m3 secrets 不綁 net_config、雜湊較小者勝可被搶 | F18、§5 分叉、§3 前提 |
| B m4 approve.rs admins 版本 | §3 前提 + checklist |
| B m5 每日全套在 wsl.24 上 FAIL | §6 時序:合併前節點已是 wsl.25 |
| B m6 `--update-stale-secrets` 黑箱單元 | §6 Harness |
| B m7 app 端移除成員前提 | §3 前提 |
| B m8 降級重開 F10 | §4 降級列 |
| B m9 objectHash label 表、比對同一份 payload | §6、§2.2-5 |

## 10. 第 3 輪審查處理

| 項目 | 處理 |
|---|---|
| A-M1 / B-M2 規則 3 太寬、轉送情境做不了、失敗沒定義 | 規則 1–4 移出本文件;§3 改列節點事實(F20、F21)與 app 設計必須處理的事(含 pin DAC、否定 / 未定、門檻、只告警不自動離開、轉送重連、槽位) |
| B-M1 拼接分叉握手也通過、§5 過度宣稱 | §5 改寫為「今天沒有偵測手段」;移除共同網主依使用者決定先不支援 |
| A m1 / B m1 `E_SCHEMA` 殘留、`:1080` | §0、§4、U5 改 `E_BAD_OBJECT`;`:1079` |
| A m2 / B m4 key 9 = 送出前版本的分叉、無限追 | §3 交給 app 的事項 |
| A m3 members 嚴格度反了 | §2.2-3 縮成簽章 / net_id / 版本(只做必要的修改);U2、U5、U6、mutant 同步 |
| A m4 槽位 | §3 交給 app 的事項 |
| A m5 新向量的版本、`_upd_body` | §6 |
| A m6 決定 A 時序要寫成條件 | §6 時序(條件) |
| A m7 混合版本車隊 | §4 新列 |
| B m2 pin DAC | §3 交給 app 的事項 |
| B m3 info 分支、key 11 長時間 true | F21;§3 節點狀態與交給 app 的事項 |
| B m5 垃圾 update 佔 helper | §5 |
| B m6 「進不了 mesh」的範圍 | §5 移除成員的範圍 |
| B m7 拒絕重新加入靠 app | §5、§3 交給 app 的事項 |
| B m8 `--update-stale-secrets` 的說法 | §6 收斂 |
| A U16 新 psk 握手沒有測試 | §6 U16(provd + 真 helper,含負對照) |

## 11. 第 4 輪審查處理(v4.1)

| 項目 | 處理 |
|---|---|
| B m1 F20 寫錯(psk 綁 net_id / 版本) | F20 改寫;§3「換 net_root」寫明理由 |
| A m4 / B m2 members 檢查被寫成安全理由 | §0-2、§2.2-3、§5 改為一致性檢查;維持三項(使用者原決定「對齊 CDDL」) |
| B m3 pin DAC 擴大到所有成員 session | §3 第一項;§5 冒充落後節點 |
| B m4 手機 AP 密碼 | §3 |
| B m5 app 紀錄倒退重簽同版號 | §3 新版號規則 |
| B m6 / A m5 換網主那一步的 members、中間步錯誤、構造 | U4 構造、U4b、U7 中間步;mutant |
| B m7 / A m6 混合車隊、wsl.24 辨識、F10 污染恢復、update 也改頻道 | F23;§3 不得在有 wsl.24 時移除、污染由下次合法 update 覆蓋、改頻道同路 |
| A m1 crash loop / 不 panic / helper、驅動重啟 | F22;§4 兩列;§5;U17 |
| A m2 回應碼表 | `E_REJECTED{}` 不保證退回、OTA `E_BUSY`、`E_UNSUPPORTED{idem}`;§3 不帶 key 7;checklist 更正 219 |
| A m3 CDDL key 3 | §2.1 刻意收緊;checklist 更正 CDDL |
| A m7 舊文字矛盾 | §5 改 8 塊;F21 改寫;F24 註解;§8 前加歷史說明 |
| A m8 測試構造 | `--update-stale-secrets` 構造;U16 不同 net_root |
