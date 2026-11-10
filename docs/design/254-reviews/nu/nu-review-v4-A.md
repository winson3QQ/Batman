# 審查 A 第 4 輪(正確性 / 介面 / 生命週期,整份):254-net-update-members.md v4 DRAFT

審查者 A,2026-11-10。先自己從頭審整份(網主手機對多台送、成員手機轉送、落後節點、wsl.24 升上來的節點、共用 `parseNet` 的 S1/S2/S3 入網、harness 三個單元),最後才讀 v1–v3 六份審查核對。v4-B 沒有讀(保持獨立)。
對照:Batman-p3 `feat/254-p3` @ e5c89a1(`git status` 只多 `?? docs/design/254-net-update-members.md`)、219-protocol.md / .cddl、node / provd / cose 原始碼、provclient、harness `scripts/dv/*`、Batman-app `batman-proto/src` @ 6574ca4。兩個 repo 唯讀;探針在 WSL `mktemp -d /tmp/nr4a.XXXX` 的複本跑,跑完 `rm -rf`。

**結論:APPROVE-WITH-CHANGES — 0 BLOCKER、0 MAJOR、8 MINOR。** 節點端 §2 可以照做;MINOR 都是文件 / 契約表 / 測試寫法,不需要新機制。

---

## ✅ 自己驗過的事實(附輸出)

- **F10 今天成立**(複本 + rig 探針):
  ```
  zz_probe_test.go:12: v2 cfg + v1 secrets -> 0 ver=2 wl=sae-v1-pass/m2/36
  zz_probe_test.go:14: resend v2 same admins -> 5      (EStaleVersion;admins 沒換 → F17 的另一半)
  zz_probe_test.go:16: empty chain -> 20               (今天的 ESchema "version chain",§2.1 改 EBadObject)
  ```
- **基準**:原樹 `go test ./provd/` → `ok batman-prov/provd 12.448s`。(我的複本只拷了 `feed/batman-prov/src`,7 個 provd 測試因 `../../../../tests/vectors/219-protocol/vectors.json: no such file` 失敗;flip:同一指令在原樹全過 → 歸因為我的複本少了 vectors,不是產品。)
- F1:`netUpdate :1072`、`ESchema "version chain" :1079`、`"chain link" :1095`、`"chain not contiguous" :1102`、`parseNet(last, sec, adminsOfPrev) :1108`、`applyNet :1112`、`adminsOfPrev :1115`、`next := *rec :1145` ✅(F1 寫簽章 `:1093`,實際 `VerifySign1` 在 `:1094`,差一行,無所謂)。F2 `netJoin :1024-1040` 只讀 key 1/3 ✅。F3 `:1206` 唯一寫 Members ✅。F5 `:756-758`、`session.go:79,82` ✅。F6 `parseNet :963-` 只驗 nid 長度 ✅。F12 `adminsOf :1043-1070` ✅。
- F8 / F15:`mapHelper :567-582`;`mapHelperR :896-907` 把 `hEReject` + reason → `E_REJECTED{2: reason}`,不分角色(成員轉送也一樣)✅。
- F9:`MaxChunks 8 / MaxReassembled 65400 / maxPlain = MaxMsg-16`(`session.go:92-96`);`total > MaxChunks` 在第 1 塊就回 `"chunk part"`;`onEnvelope` error → session 結束(`:325-328`);`MaxMsg 8192`(`frame.go:15`);`MaxRequest 65536`(`sock.go:24`);app `MAX_REASSEMBLED = 1 << 20`(`envelope.rs:13`)✅。
- F10 原始碼:`decryptSecrets wtxn.go:126-152` 的 KDF `other` 取自 secrets 自己的 payload;`openSecrets node.go:934-944`、`openStoredSecrets wtxn.go:113-123`;`parseNet` 是 `openSecrets` 唯一呼叫者(`:1007`),`openStoredSecrets` 只被 `netRoot :927` 與 `wtxn.go:87` 用 → §2.2-5 改 `openSecrets` 不碰 Finish / psks 路徑 ✅。
- F11:`route` 帶 key 7 → `E_UNSUPPORTED{1:"idem"}`(秘密類 `E_FORBIDDEN`)✅。
- F13:`approve.rs:215`、`join2flow.rs:366`、`joinflow.rs:220` 都以 net_config 的 net_id / 版本產 secrets ✅;app joiner 端 `bind()` 本來就對 secrets 做 `same_net`(`approve.rs:281-285`),所以 S2 遠端入網也不會被 §2.2-5 擋。provclient `netObjects / netSecrets`(`net.go:189-208`)同一個 `ver` ✅。
- F14:rig `mkNet`(`wtxn_test.go:67-100`)沒有 key 5;provclient `net.go:194` 一律帶 `in.country`(預設 `"TW"`,`:56`)✅。F19 `netrec.rs:20` ✅。
- F16:`info.net`(`readonly.go:133-142`)→ provd `server.go:555-569` 只放 9/10/11,`ctlCall` 失敗整組不回 ✅。
- F20:`opsLoop`(`server.go:434-470`)、`invalidate()` 設 `needPSK`(`:598-601`)、`reconcile` 的 `psk-rotated`(`:650`)、`fakeMsg2`(`noise.go:89-96`)✅。
- F21:`node.go:250-255` ✅(但見 m7 文字矛盾)。
- CDDL `network-update-req`(`219-protocol.cddl:231-237`)、member-list(`:358-366`)、219 §7.1「v+1 用 v 的 admins 驗」、§7.5「net_secrets 只帶最新一版」✅,§2.2-3 用與 net_config 同一組 signers 正確。
- 其他送 update 的:`grep -rln "network/update\|--update"`(排除 vendor/.git/docs)= F4 列的檔案 + `prov-254.sh:742`(只存 NETCFG)、`p3-units.tsv:78` UP7(未實作的單元)、`gen.py`/`verify.py`(分塊向量)、`peer/selftest.py:94`(owner-op 簽章自測,body 無關)。沒有 F4 漏掉的真正送件者 ✅。

---

## BLOCKER
無。

## MAJOR
無。節點端的五項改動(新形狀、members 三項、net_id、secrets 綁版本、國碼)在原始碼上都有落點,不碰持久狀態、`.txn`、Finish、psks 路徑;S1–S3 入網不受 §2.2-5 影響(F13 + app `bind()`)。

---

## MINOR

### m1. §4 生命週期缺「crash loop」與「各依賴重啟」列
- **情境**:任何 member session(含分裂期間被移除者的手機、被攻陷的 provd)都能送任意 body 到 `netUpdate`;§2.1 新增的步內解析就在這條路上。helper 沒有 `recover()`(`grep -rn "recover()" --include=*.go`,排除 vendor 只有測試檔)。新程式若有任何未檢查的型別斷言,一個成員就能讓 helper 反覆崩潰(procd 重啟 → 再送 → crash loop),同時卡住其他動詞。
- **證據**:上面的 grep;現有 `netUpdate` 都是 `x, ok :=` 形式,新程式要維持。
- **修法**:§4 加一列「crash / crash loop:惡意 body → 不 panic(全部 ok 形式斷言)」,證明 = 一個 Go fuzz / 表格測試(`netUpdate` 餵亂形狀 body,不 panic、回 `EBadObject`、紀錄不變),可併入 U15。另補「helper 重啟」「setkey / HaLow 驅動重啟」兩列(不變,引既有測試)與「送件端 BLE 在分塊中斷線」(分塊狀態屬 session,丟棄,無節點狀態)。

### m2. §3 回應碼表不完整;app 清單缺「不要帶冪等鍵」
- `E_REJECTED{}` 不只 apply 失敗:`node.go:240-255` 的 boot verdict 未定(`EState`)與「先前的 `.txn` Finish 不了」(`EState`)也是它,這兩種情況下「節點已退回原狀」**不成立**(前一個變更還沒收尾,key 11 = true)。
- `E_BUSY`(無 detail)也包括 OTA 寫入中(`node.go:244-246`,`otaBusy`)。
- 缺 `E_UNSUPPORTED{1: "idem"}`(帶 key 7,F11)與 `E_UNSUPPORTED{1: typ}`(無紀錄,`node.go:258`)。
- **219 §4.2 v0.7 明文說冪等鍵用在 `network/update`**(219-protocol.md:155),照規格實作的 app 每次都會拿到 `E_UNSUPPORTED`。§3「app 必須處理的事」要加一行「不帶 key 7」,§7 checklist 加「219 §4.2 更正(provd 無冪等快取)」,與已列的 §8 1 MB 更正併在一起。

### m3. 節點比 CDDL 嚴:最後一步的 key 3 在 CDDL 是 `? 3`,§2.1 要求必填
- 要求必填是對的(沒有 secrets 就無法綁版本,也沒有新 SAE),但這是對 CDDL 的收緊,文件沒說。
- **修法**:§2.1 註明「刻意比 CDDL 嚴:最後一步必帶本機 secrets」,§7 checklist 加「CDDL / 219 §7.5 改寫成最後一步必帶」;§3 app 清單加「最後一步一定要帶目標節點那一版的 secrets(成員轉送時也一樣)」。

### m4. members 檢查的理由寫過頭(§0-2、§5)
- §0-2「只做擋住轉送者換物件所需的三項」、§5「跨步或跨版本交換 members → 擋」:節點不存、不讀 members(F3),轉送者換掉 members 對節點**沒有任何效果**,所以這不是安全理由。實際理由只有:使用者決定對齊 CDDL + 219 §7.1 一致性。
- 唯一真實後果反而是耦合:app 若在換網主那一版用新 admins 簽 members(`approve.rs:281-285` 的習慣),節點會拒絕合法 update——這已在 §3 app 清單,但應在 §2.2-3 旁點明「這是此檢查的唯一實際影響」。
- **修法**:改寫兩處理由;若使用者依「只做必要的修改」想更省,可以只檢查 key 2 存在(請使用者決定,不是必要變更)。

### m5. 負對照的判別力要寫進 U4 / U7
- §2.2-1 的 net_id mutant:若 U4 那一步的 secrets 用**已存的** net_id,拿掉 net_id 檢查後仍會被 §2.2-5 擋,mutant 存活。U4 必須讓 secrets 帶與壞 net_config 相同的 net_id(或把壞 net_id 放在**中間步**、最後一步正常),才只有 §2.2-1 抓得到。
- §2.2-2「每一步都比」:U7 要有一個「中間步改國碼、最後一步同國碼」的案例,否則「只比最後一步」的 mutant 存活。
- **修法**:U4 / U7 各寫明這兩個構造。

### m6. §3「app 必須處理的事」漏三件節點事實
1. **wsl.24 節點怎麼認出來**:wsl.24 對新形狀回 `E_BAD_OBJECT "chain link"`,和資料壞分不出;唯一的節點事實是 `info` key 4 fw_version(v1-A m10、v2-A m6 的歷史)。清單「要先升級」旁補「依 info key 4 判斷或一律提示」。
2. **`network/update` 也是改 HaLow 頻道的路**(`settingsset.go:7, 102` 回 `E_UNSUPPORTED` 指向 update):新形狀(每步帶 members)適用 app 所有 update,不只移除成員。清單一行。
3. **v2-B m8 的後半沒寫**:wsl.24 上已被 F10 寫進的紀錄(cfg v2 + secrets v1)升級後不重驗;恢復 = 下一次合法 update(帶 v3 secrets)就修好,不需離開。§4 升級列補一句。

### m7. 舊版本留下、與 v4 矛盾的文字
- §8「A-m10 … §3 表 fw_version」:§3 已無此表。
- §9 多列指向「§3 規則 1–4 / 規則 3 / §3 前提」:v4 已移除;「A members 七個 key 必填 | §2.2-3」與 v4 §2.2-3(不檢查結構)相反。照 §9 實作的人會加回七 key 檢查。建議在 §8 / §9 表頭加一句「歷史紀錄;與 §2 衝突時以 §2 為準」,或逐列加「(v4 已取代)」。
- §10「U2、U5、U6 同步」:§6 沒有 U6(也沒有 U10)。
- §5「超大請求 → 65400 上限」:F9 自己說先卡的是 8 塊。
- F21「SaveTxn 失敗時 `.txn` 會一直留到下次開機」與同一條前半「下一個改狀態的動詞先 Finish」矛盾 → 「留到下一個改狀態的動詞或下次開機」。
- 實作時順手:`wtxn.go:116-117` 註解說 openStoredSecrets 保有「net_id / version binding」,實際只綁 secrets 自己,改註解。

### m8. 兩個測試的構造要說清楚
- `--update-stale-secrets`「這台節點上一版的 secrets」:provclient 拿不到節點上存的那份(每次 `netSecrets` 都新產,`net.go:202-208`)。實際做法應是「為這台產一份版本 = v(舊版)的 secrets」,對綁定檢查等價;照這樣寫,免得實作者去讀 prov.cbor。
- U16:rig 的 `mkNet` 每一版的 net_root 都是 `make32(9)`(`wtxn_test.go:92`)。若照用,`psk_member(v2)` 成功只證明版本變了,不證明新 secrets 生效;U16 每版要用不同的 net_root,並加「舊 root + 新版本號 → 假 msg2」的負對照。

---

## 生命週期(我自己掃的)

| 路徑 | 判斷 |
|---|---|
| 首次 / 沒網路 | ✅ `rec.Net == nil → E_STALE_VERSION` 在形狀檢查之前,不變 |
| start / stop / restart | ✅ 無新狀態 |
| 斷電 / crash 在 update 中 | ✅ 寫入只在不變的 `applyNet`;U9 經 `netUpdate` 有判別力 |
| crash loop | ⚠️ 缺列(m1) |
| 回應遺失 | ✅ F11 / F17 / U14 |
| 升級 wsl.24 → 25 | ✅ 紀錄格式不變;F10 污染的紀錄見 m6-3 |
| 降級 / A/B 回滾 | ✅ 已寫 F10 重新存在 |
| 混合車隊 | ✅ §4 列;偵測方式見 m6-1 |
| provd 重啟 | ✅ |
| helper / HaLow 驅動重啟 | ⚠️ 未列(m1),行為不變 |
| 兩支手機同時送 | ✅ ops 序列化 → `E_BUSY` |
| 平台 | ✅ 同一份 Go;Pi3 只編譯(2026-10-23 決定) |
| 資源 | ✅ 不新增持久狀態;Members 唯一寫者仍是 leave 清 nil |

逐 actor(只列與本變更有關的):成員 session / 被移除者手機 → 舊或別網 secrets 被 §2.2-5 擋 ✅,CRIT 灌不了(§2.1)✅,crash loop 見 m1;被攻陷的 provd → 能扣住或亂送,既有能力;共同網主 → 拼接 / 分叉為 219 §7.1 固有限制,依使用者決定不支援 ✅;遠端未認證 → 到不了 update(`allowed`)✅;本機非特權 / 實體 / 供應鏈 → 不變 ✅。

---

## 前幾輪項目核對

| 項目 | 狀態 |
|---|---|
| v1 A-B1 / B-B1 secrets 綁版本 | ✅ §2.2-5、U11、U12、mutant、`--update-stale-secrets`(構造見 m8) |
| v1 A-M1 冪等 | ✅ F11、U14;表與 app 清單缺 idem 一行(m2) |
| v1 A-M2 / B-M1、v2 A-M3 大小 | ✅ 8 塊、U13、app 先算 |
| v1 A-M3 / B-M2 與存 members 系列 | ✅ 不存了 |
| v1 A-m6 MaxRecord | ✅ 紀錄大小不變,不適用 |
| v1 A-m10 舊節點偵測 | ⚠️ §8 指向已刪的 §3 表;app 清單沒說怎麼偵測(m6-1、m7) |
| v1 B-m6 未知 key 不對稱 | ✅ §0 + checklist |
| v2 A-M1 重送 `E_BAD_OBJECT` | ✅ F17、U14 |
| v2 A-M2 / B-M2 E_SCHEMA / CRIT / 表 | ✅ §0、§2.1、§4、U5、U15 全改 `E_BAD_OBJECT`;表仍缺幾列(m2) |
| v2 B-M1 分叉誤判 | ✅ 移到 app 設計清單 |
| v2 A m1 國碼缺 key | ✅ `mkNet` 補 key 5,無寬鬆分支 |
| v2 A m9 members 七 key | ✅ v4 依 v3-A m3 縮成三項;§9 舊文字見 m7 |
| v2 B m5 每日全套空窗 | ✅ §6 時序(條件) |
| v2 B m8 降級 F10 | ✅ 降級列;升級後污染紀錄的恢復未寫(m6-3) |
| v3 A-M1 / B-M2 規則 3 | ✅ 移到 app 設計清單(pin DAC、否定 / 未定、門檻、只告警、轉送重連、槽位),U16 加了(構造見 m8) |
| v3 B-M1 拼接過度宣稱 | ✅ §5 改「今天沒有偵測手段」;移除共同網主不支援 |
| v3 A m1 / B m1 E_SCHEMA 殘留 | ✅ |
| v3 A m2 / B m4 key 9 分支、無限追 | ✅ app 清單 |
| v3 A m3 members 嚴格度 | ✅ 縮成三項;理由寫過頭(m4) |
| v3 A m4 槽位、B m2 pin DAC、B m3 info 分支 | ✅ app 清單 |
| v3 A m5 向量版本 | ✅ §6 |
| v3 A m6 時序條件 | ✅ |
| v3 A m7 混合車隊 | ✅ §4 新列 |
| v3 B m5 垃圾 update、m6 範圍、m7 重新加入、m8 說法 | ✅ §5、§6 |

## 判定:APPROVE-WITH-CHANGES

節點端設計正確、完整,可以實作。8 個 MINOR 在實作前同一輪改文件即可:m2 / m3 / m6 是 app 設計會用到的節點事實(表與清單);m5 / m8 決定 mutant 與 U16 有沒有判別力;m1 補生命週期的 crash loop 列與不 panic 測試;m4 / m7 是文字。m4 的「members 只檢查存在」請使用者決定(不改也可以)。
