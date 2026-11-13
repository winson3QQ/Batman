# 審查 B 第 3 輪(安全優先,全文):`254-net-update-members.md` v3 DRAFT

審查者 B,2026-11-10。對象:WSL `/home/yello/Batman-p3/docs/design/254-net-update-members.md` v3(232 行);Batman-p3 `feat/254-p3` @ e5c89a1。
對照:`node/node.go`、`node/wtxn.go`、`node/readonly.go`、`node/settingsset.go`、`provd/session.go`、`provd/server.go`、`provd/noise.go`、`sock/sock.go`、`219-protocol.md/.cddl`、`tests/tools/provclient/net.go`、`scripts/dv/prov-netupdate-254.sh`;app `batman-proto/src/{cose,kdf,approve,netrec,envelope,nodecert,loginflow}.rs`。
探針:把整個 repo 複製到 WSL `/tmp/nurb3`,在複本上(1)把 §2.2-5 的 secrets 綁定照設計補進 `parseNet`,(2)加一個測試檔,(3)跑 `go test ./node -run TestProbe` 和 `go test ./node/ ./provd/`。跑完已刪除(腳本最後一行 `rm -rf $D`)。repo 沒動,也沒碰裝置。腳本在 scratchpad `app/rb3/`。
順序:先做自己的審查,最後才讀第 1、2 輪 A / B,逐項核對處理狀況。

**結論:APPROVE-WITH-CHANGES — 0 BLOCKER / 2 MAJOR / 8 MINOR。**
- 節點端 §2 可以照做:secrets 綁版本、net_id、國碼、members 的檢查都正確;形狀錯改成 `EBadObject` 沒有副作用(見 §「形狀錯改 EBadObject 的副作用」)。
- 兩個 MAJOR 都在 §3 / §5 的 **app 契約**:
  - 規則 3 的「新 psk_member 握手」不能偵測拼接分叉,但 §5 宣稱能;
  - 規則 1–3 在最常見的 member session(轉送)情境下無法照做,而且「握手失敗」沒有定義,會導致誤判分叉、走離開 + 重新入網。
- 依規則,MAJOR 改完後要再整份審一次。

---

## MAJOR

### M1. §3 規則 3 + §5「app 以規則 3 偵測分叉」不成立:拼接分叉(分叉的 net_config 配上合法的 secrets)握手照樣成功,節點已被另一位網主接管,app 卻判「已換上新秘密」

**情境**:移除共同網主 B(§5 自己列的正常情境)。
- v1 的 admins = {A, B}。A 發 v2:admins = {A},新 SAE,新 net_root R2。
- B 仍在 v1 的 admins 裡,他自己簽一份 v2':admins = {B},ssid / channel 由 B 決定。
- B 再把 A 給這台節點的**合法 v2 secrets** 接在 v2' 後面送出。
- B 要拿到那份 secrets 並不難:它是給轉送者的物件,任何經手的人都看得到;只是加密給節點的 DAC,經手的人解不開。

secrets 只綁 (net_id, 版本)(§2.2-5),所以這個拼接會通過。節點的 `psk_member` 只由已存 secrets 裡的 net_root 導出(`node.go:430-431` `proto.PskMember(root, rec.Net.NetID, uint32(rec.Net.Version))`),和 net_config 是哪一份無關。

**探針**(`/tmp/nurb3`,已含 §2.2-5 綁定的補丁):
```
PROBE splice: fork v2 cfg (signed by co-admin b, admins=[b], mesh attacker/36) + legit v2 secrets (root R2) -> code 0, wl=sae-v2-NEW/attacker/36
PROBE node psk_member == psk_member(R2, net_id, 2) the app would test in rule 3: true; stored admins == [b]: true
PROBE legit v3 by a afterwards -> code 4
PROBE binding control: v2 cfg + v1 secrets -> code 4 (4 = rejected by the probe patch)
ok  batman-prov/node / ok batman-prov/provd   (補丁後全套 go test 仍過)
```

**後果**:
- 依 §3 規則 3,app 判定「這台確實換上了新秘密」,顯示成功。
- 實際上這台節點從此只聽 B 的(admins = [B]),A 的 v3 永遠回 4。
- B 知道節點的 ecdh_pub(在 node_cert 裡),所以 v3 起可以自己產這台的 secrets,把節點帶進 B 的網路。
- §7 checklist 的對策是「移除網主時先發一版只改 admins 的版本並確認全網套用」,但「確認」用的正是規則 3,同樣會被騙。那一版通常不換 net_root,B 也就知道 psk_member(v+1),連拼接都不需要。

第 2 輪 B m3 已經指出拼接(`splice fork cfg + legit v3 secrets -> 0`),要求 §5「照實寫」。v3 卻把規則 3 寫成了偵測手段,這是 overclaim。

**修法(二選一,由使用者決定)**:
- (a) **只改文件**:
  - 規則 3 的判準改寫成「證明這台持有 app 發出的這一版 net_root / SAE」,**不證明 net_config 是 app 那一份**;
  - §5 刪掉「app 以規則 3 偵測」;
  - 寫明:移除共同網主的流程目前**無法驗證**,在 checklist 標成阻擋項。
  - 單一網主的「移除成員」不受影響:v 版 admins 只有自己,不會有分叉。
- (b) **小型唯讀補強**(我建議):
  - `info.net` 多回已存 net_config 的 OBJECT_HASH(`readonly.go:136-142` 加一個欄位);provd `info` 對 owner / member 角色加 key 12(`server.go:562-569`);CDDL `info-resp` 加 `? 12 => sha256`。
  - 規則 3 改成「握手成功 **且** key 12 = app 存的那一版 net_config 的 OBJECT_HASH」。
  - 這不新增狀態,也不新增寫入者,能同時關掉拼接、重簽(我們自己的錯)和共同網主分叉的偵測漏洞。
  - 負向測試:上面的探針改成 Go 測試,拼接後 `info.net` 的 hash ≠ 合法 v2 → app 判分叉;mutant:hash 改成回 secrets 的 hash → 測試失敗。

### M2. §3 規則 1–3 在 member session(轉送)情境下無法照做,而且「握手失敗」沒有定義;更新後的 PSK 更新空窗與握手限速,都會被判成「分叉 → 只能離開 + 重新入網」

對別人的節點,網主 / 成員 app 只能用 `psk_member` 連(219 §3.5 角色表),這是移除成員時最常見的路徑。節點實際的行為如下:

1. **更新成功後,舊 psk 的 session 會被撤銷,回應可能送不到**:
   - 轉送成功後,provd 呼叫 `invalidate()`(`session.go:656`),接著 `opsLoop` 每 500 ms 檢查一次,在 ops 空閒時重抓 `psks.get`(`server.go:434-460`);helper 對 `psks.get` 限速 1 次/秒(`node.go:276-277`)。
   - 重抓之後 `reconcile` 把仍用舊 `psk_member` 的 session 全部斷掉:`"psk-rotated"`(`server.go:650-652`),`Kill` 直接關傳輸層(`session.go:168-177`)。
   - 因此「送 update 的那條 session 在成功後被斷」是**正常結果**。BLE 上的回應可能還沒送完就被斷,app 看到的是「沒有回應」。
2. **規則 1「重連,讀 `info`」用舊 psk 做不到**:
   - 節點只試**目前版本**的 `psk_member`(`server.go:711`;219 §3.4)。已套用的節點對舊 psk 回假的 msg2(`noise.go:84-90`),app 會 AEAD 失敗,讀不到 info。
   - 規則 1–4 沒有這條分支。
3. **規則 3「失敗 = 分叉」沒有定義什麼叫失敗**:
   - (i) commit 之後、psk 重抓之前(≥ 0–1.5 s;如果 ops 一直忙或 `psks.get` 回 ERate,舊集合會繼續生效,`server.go:458` 的註解「the old set keeps serving」),用新 psk 握手會收到**假 msg2**。這和「真分叉」的訊號完全相同。
   - (ii) 全域握手限速 20 次/分鐘,在檢查 PSK **之前**就執行(`session.go:392`)。任何未認證的 BLE 對端都能耗光額度,app 看到的是斷線。
   - (iii) `info.net` 遇到 ERate 時,key 9–11 整組不回(`server.go:555-560`)。
   - 規則 3 把「失敗」直接對應到「停止、告警、這台只能離開 + 重新入網」。(i) 會讓我們自己的節點被誤判;(ii) 會讓一個未認證的攻擊者誘發一個需要到場的復原動作(不過要 app 把斷線也算成失敗才會成立,這取決於規則 3 的寫法)。

**修法(只改契約,不加機制)**:把規則 1–3 改寫成下面的流程,並進 #254 checklist(app):
1. 任何非 0 或沒有回應 → 等 ≥ 2 s,再用**目標版本**的 `psk_member` 連線(必須 pin 目標 DAC,見 m2)。
   - msg2 解得開 → 讀 info:key 11 = false 且 key 9 = 目標(若採用 M1-b,再比對 key 12)→ **成功**。
2. 解不開 → 改用**送出前版本**的 `psk_member` 連線 → 讀 info → 依規則 2 / 4 處理。owner 改用 `psk_owner`,它不受網路版本影響。
3. **只有**「msg2 AEAD 失敗」才算一次否定。斷線、逾時、not ready、info 缺 key 9 都算**未定**,只能稍後重試。
4. 「分叉」的判定要有門檻:兩把 psk 在 ≥ 30 s 內、≥ 3 次都 AEAD 失敗,或 M1-b 的 hash 不符。判定後**只告警並交給使用者決定**,app 不自動要求離開。
5. 寫明:成功的轉送會讓該 session 以 `psk-rotated` 結束,這是預期行為,不是錯誤。

**測試**:
- provd 層測試把行為釘住:更新後、重抓之前,用新 psk 握手 → 得到 fake;重抓之後 → 成功;舊 psk 的 session 被斷,理由是 `psk-rotated`。
- app 端單元測試:把上述每一種訊號餵給判定函式,斷言只有 AEAD 失敗會累積成否定。

---

## MINOR

1. **E_SCHEMA 殘留,與 §2.1 / U15 矛盾**:
   - §0(第 23 行)「舊形狀 → `E_SCHEMA`」、§4 升級列(第 124 行)、**U5(第 152 行)「各自 `E_SCHEMA`」**,都和 §2.1「形狀錯一律 `EBadObject`」、U15 衝突。照 U5 實作就會把 CRIT 灌爆的問題帶回來。三處都要改成 `E_BAD_OBJECT`。
   - 另外,`ESchema "version chain"` 實際在 `node.go:1079`,設計寫 1080。
2. **規則 3 的握手必須 pin 目標 DAC**:
   - 所有留下的成員節點和成員手機都有新的 net_root:節點透過 net_secrets,手機透過 `member_secrets`(219 §7.4)。所以任何一個都能導出 `psk_member(v+1)`,替目標節點完成握手。這種情況發生在 BLE 位址混淆、HTTP 走 mesh 轉送、或對端已被攻陷時。
   - 219 §6(第 74 行)已經是 MUST,但 app 目前沒有 member-session 流程:`psk_member` 只在 `kdf.rs:39` 出現,DAC pin 只在 `loginflow.rs`(owner)。
   - 規則 3 要明寫:驗 node_cert,而且 SHA-256(DAC pub) = member_list 裡該成員的 `dac_pub_hash`。
3. **規則 1 缺分支**:
   - info 沒有 key 9 / 10:節點已離開,或 `info.net` 被限速(`server.go:555-560`)。
   - key 10 ≠ app 的 net_id。
   - key 11 長時間為 true:`SaveTxn` 失敗時 `.txn` 會保留到下次開機(`node.go:1186-1188`)。只等待會等到天荒地老。要寫明:等一段時間後,重送同一份是安全的,因為任何改狀態的 verb 都會先 Finish(`node.go:253-256`),然後依規則 1 再讀一次。
4. **規則 4「key 9 > 目標 → 先同步」**:如果是攻擊者把分叉往後延伸,app 手上沒有那條鏈可以同步,會無限循環。要比照 M1 / M2 的判準:用目標 psk 握手(以及 hash)都不符 → 分叉告警。
5. **§5「它能做到的只有不送或送舊的」不完整**:成員 session(包括分裂期間被移除者的手機)可以持續送垃圾 update,佔住 helper 的 `n.mu` 和 provd ops 的單一執行緒(其他人會收到 `E_BUSY`),拖長分裂期;每次被拒還會寫一行(非 CRIT)log(`node.go:224`)。這是既有行為,本變更沒有變差;但 §5 要照實寫。CRIT:本變更之後由轉送 body 觸發的 CRIT 確實沒有了(見下一節)。
6. **「進不了 mesh」的範圍要寫清楚**:
   - 本變更只處理 HaLow mesh,也就是 SAE 和 psk_member。
   - 手機 AP 的密碼由每台節點的擁有者自己設定(`settingsset.go:4-5`,key 20)。net_secrets 的 key 3 / 4(LoRa PSK / team AP)節點目前不使用(`grep` 不到任何讀取)。被移除者的手機如果知道某台節點的 AP 密碼,仍能從 IP 層進入網路。
   - §3 前提的「LoRa PSK 若有也換」要加一句:team AP / 各節點 AP 不在範圍內,由 app 的移除流程提示擁有者更換。
7. **重新入網的防線在 app**:被移除的 DAC 只要拿不到新 secrets 就進不來(target_dac_hash,`wtxn.go:128-131`)。但 app 審核加入申請時,必須拒絕出現在 member_list key 5(removed)裡的 DAC,節點無法替它擋。這一條要進 checklist。
8. **§6 誠實界線再補一句**:`--update-stale-secrets` 在 wsl.25 上只證明「出貨的 image 會拒絕」。它沒有「修正前會通過」的硬體對照(wsl.24 根本不認得新形狀),修正前的對照只有 Go 的 PoC 反轉(U11)。目前文件寫的是「BLOCKER 修正的黑箱證明」,這個說法要收斂。

---

## 形狀錯改 `EBadObject` 的副作用(使用者要求查)

我查到的結果是:**沒有不良副作用**。
- provd 端:`mapHelperR` 把 `hEBadObject` 原樣送給 app(`session.go:568-570`);不計失敗次數(`failOnce` 只用在 claim / replay,`session.go:660`);不斷線,也不寫 CRIT。
- 由轉送 body 觸發 ESchema 的其他路徑:
  - `decodeEnvelope` 的 ESchema(`node.go:657-678`)碰不到,因為 provd 會以嚴格 CBOR 重新編碼整個信封(`session.go:503-509`)。
  - `bytesArg` 的參數由 provd 自己組。
  - 所以 `node.go:1079` 是唯一一處,改掉之後成員就灌不了 CRIT。
- 對 app 的影響:原本 `E_REJECTED{}`(可重送)會變成 `E_BAD_OBJECT`(不重送 + 提示更新)。對「形狀錯」來說這才正確。
- 測試面:`route_test.go:372-375` 用的是假 helper,不受影響;現有測試裡沒有斷言 `version chain` → ESchema 的(`grep` 無結果)。
- 唯一的問題是 m1 的文件矛盾。

## 規則 3 能不能被轉送者或被移除者冒充(使用者要求查)
- **被移除的成員(手機 / 節點)**:只有舊的 net_root,導不出 `psk_member(新 root, v+1)`。NXpsk0 的 psk0 在第一則訊息就混入(`noise.go:56-90`),沒有 psk 就做不出能解開的 msg2。**偽造不了 ✅**(前提是移除的那一版有換 net_root,§3 前提已寫)。
- **轉送者 / 其他留下的成員**:持有新的 net_root,如果 app 沒有 pin DAC 就**能偽造**(m2)。
- **被移除的共同網主**:用拼接可以讓規則 3 通過(M1,有探針)。
- **被攻陷的 provd**:握手本身就由 provd 回應。它可以拿到 helper 給的 `psk_member`(`psks.get`),所以能回報「成功」。但被攻陷的 provd 本來就能讓這台節點做任何事,這不是新的面,不過 §5 應該寫一句。

## 逐 actor

| actor / 手法 | 結果 |
|---|---|
| 遠端未認證 | 角色表沒有 update(`session.go:76`)✅;能耗光握手額度(`session.go:392`),進而誘發規則 3 的「失敗」→ M2 |
| 本機非特權程序 | 不新增 socket / 路徑 ✅ |
| 成員 session / 被移除者的手機 | 舊版或別網 secrets 配新 cfg → §2.2-5 擋(探針 code 4)✅;重送 / 換步 / 跨網 / 換 members → 版本連續性、net_id、members 綁定都擋 ✅;CRIT 灌爆 → 已解 ✅;佔住 helper → m5 |
| 被攻陷的 provd | 能扣住不送,也能對規則 3 謊報;都是既有能力 ✅(§5 補一句) |
| 被移除 / 被攻陷的共同網主 | 拼接分叉通過規則 3 → M1 |
| 實體取得 | 不變(prov.cbor 0600)✅ |
| 供應鏈 | 不變 |
| 我們自己的錯 | 同版號重簽(前提已禁止,但 M1-b 才偵測得到);U5 的 E_SCHEMA(m1);PSK 更新空窗誤判(M2) |
| 資源耗盡 | 8 塊上限、每一步第一個失敗就停 ✅ |
| 被移除者重新進入 | secrets 綁 DAC 目標 ✅;app 審核端 → m7 |

## 生命週期(我自己掃的,補 §4 沒有的)
- **轉送成功 → session 被 `psk-rotated` 撤銷**:§4 沒有這一列(M2)。
- **SaveTxn 失敗 → key 11 一直是 true,直到下一個改狀態的 verb 或重開**:§4 沒有這一列(m3)。
- **provd / helper 重啟**:`needPSK` 會重抓(`server.go:178-181, 210-213, 398-402`);空窗期內用新 psk 握手會失敗,和 M2 是同一件事。
- 其他各列(首次、斷電、升 / 降級、平台)我核對過,與原始碼一致。

## 查證屬實的事實
- F1 `node.go:1072-1112`(1079 / 1093 / 1101 / 1108 / 1112)、F3(`:1145`、`:1206`)、F9(`session.go:94-95, 531, 547`;`sock.go:25` MaxRequest 65536)、F10(`wtxn.go:126-152`)、F15(`session.go:567-582`)、F16(`server.go:546-569` ← `readonly.go:136-142`)。
- F19 `netrec.rs:20` `MAX_MEMBERS = 16`;`envelope.rs:13` 是 1 MiB;`netrec.rs:103` key 5 必填;`approve.rs:281-285` 用同一版 admins。
- `ReasonCountryJoin` 只出現在 `settingsset.go:21, 123`;app `member_list_payload` 七個 key 都會帶(`cose.rs:125-133`),所以 §2.2-3 的「七個 key 全部必填、不得有其他 key」不會擋掉 app 產的物件 ✅。
- EReject 的 reason 經 `mapHelperR` 送出(`session.go:897-907`)✅。

## 前幾輪處理核對

| 項目 | 狀態 |
|---|---|
| v1 A-B1 / B-B1 secrets 未綁版本 | ✅ §2.2-5;探針:綁定補丁後 `v2 cfg + v1 secrets -> 4`,`go test ./node ./provd` 全過 |
| v1 A-M1 冪等 | ✅ F11 / U14 |
| v1 A-M2 / B-M1 大小 | ✅ F9 / U13 / 「> 8 塊不送」 |
| v1 A-M3、B-M2 及因「存 members」而來的 minor | ✅ 不存了,這些問題都消失(F3) |
| v1 其餘 minor(行號、國碼語意、錯誤碼表、mutant、硬體對照、未知 key、分叉不做) | ✅;MaxRecord(A-m6)不再適用 |
| v2 A-M1 重送回 `E_BAD_OBJECT` | ✅ F17 + 「錯誤碼只是提示」 |
| v2 A-M2 / B-M2 E_SCHEMA / CRIT / 表 / key 11 | ⚠️ §2.1 / §3 / U15 已改;**§0、§4、U5 仍寫 E_SCHEMA(m1)** |
| v2 A-M3 8 塊 | ✅ |
| v2 B-M1 用版本號判成功會被分叉騙 | ⚠️ 改成握手;但拼接分叉照樣能騙(M1),而且 member 路徑照不了、失敗沒有定義(M2) |
| v2 A m1–m10 | ✅(fw_version 已改成「一律提示更新」;U9 改成經 netUpdate;向量 keystore;openSecrets 回傳 payload;七個 key;app checklist) |
| v2 B m1、m2、m4–m9 | ✅;m6 黑箱單元有了,但說法要收斂(m8) |
| v2 B m3 拼接要照實寫 | ❌ 反而寫成「規則 3 能偵測」(M1) |

## 判定
**APPROVE-WITH-CHANGES。**
- 節點端 §2 照做沒有問題。
- M1:規則 3 的保證範圍,要嘛照實縮小,要嘛加唯讀的 net_config hash(使用者決定)。
- M2:規則 1–3 依 member 路徑重寫,並定義什麼才算「失敗」。
- 兩項都只改契約或做唯讀小改,不新增狀態。改完後依規則再整份審一輪。
- m1(U5 的 E_SCHEMA)實作前一定要改。
