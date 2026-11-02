# #254 docs PR 審查 — 審查者 B — 協定 v0.7 + CDDL + 向量 + field-provisioning v2.9(baf1a21,基於 8682f57)

**判定:REJECT(窄)** — 0 BLOCKER / 5 MAJOR / 9 MINOR。

v0.7 大致忠實寫回了 254-stage1-impl v19。owner-op、`psk_replay`、`claim/replay`、首版需要 owner-op 這幾個機制的方向都對,向量也確實有鑑別力(§3 的竄改實驗)。

擋下的原因有三類:
- **簽章輸入的綁定有缺口**:M1 是 verb 與 type 沒有綁在一起,M5 是兩份文件對 `args_hash` 的定義不同;
- **開發版身分有一條 TOFU 中間人的路徑**,而且「階段 1 節點到底用哪一套標籤」沒有定論(M2、M3);
- **HTTP 冪等快取會跨 session 回傳秘密**,與 stage-1「不快取」的決定相反(M4)。

範圍:`git diff 8682f57 baf1a21` 全部,並整份讀了 `219-protocol.md` v0.7。只在 WSL 操作:跑了 verify / gen、做了竄改實驗、用 pycddl 實測 CDDL。沒有連任何節點、沒有 commit;除了這份報告,唯一的寫入是 `/tmp` 下的臨時檔,用完已刪。

---

## 1. 從實際使用出發逐一走過

| 情境 | 結果 |
|---|---|
| app 認領節點 | NX → `claim/begin` → `claim/finish`;節點自己重算 `ClientChal`(§5.4)✅。開發版第一次接觸的綁定有洞,見 **M2** |
| 認領回應遺失 | `psk_replay` 交握 → `claim/begin`(?)→ `op/nonce` → `claim/replay`。整體可行,但 app 要持久化的東西少了認領秘密 K,也沒寫「節點其實沒提交」時 app 怎麼退回(m3);`claim/begin` 的角色兩處寫得不一樣(m2) |
| 新增第二位擁有者 | `owner/add`(owner-op)✅。之後擁有者 > 1,`psk_replay` 消失,以假 PSK 補位,固定試 6 次仍然成立 ✅ |
| 轉送者送 `network/update` | 用 admins 鏈驗證,不帶 owner-op ✅。但「節點還沒有網路時要拒絕 update」沒有明寫(m7) |
| 前任擁有者手上有 QR | 已認領的節點拒絕 NX;`psk_replay` 需要擁有者的加密私鑰,所以前任探測不到 ✅ |
| 轉賣後的節點 | 重燒卡 → 新身分、新 QR ✅(v2.9 §6.1 新加的那一條) |
| 開發版遇到正式版 app | 正式版 app 會以「鏈長 1 / CN `dev:`」拒絕。但 prologue 和標籤是否真的不同取決於 **M3**:向量全部用正式版標籤,節點又被要求逐位元組通過向量 |

## 2. MAJOR

### M1 owner-op 的 `verb` 沒有和請求的 `type` 綁在一起,向量也沒測「verb ≠ type」

**情境。** 被攻陷的 provd(或轉送者)手上有擁有者剛簽好的 `network/join` 請求。它把信封的 `type` 改成 `network/leave`,body 與 owner-op 原封不動。
- §5.7 只寫「節點比對 `verb == type`」。如果實作者用 owner-op 裡的 `verb` 重建簽章輸入,簽章照樣通過;
- `args_hash` 只涵蓋 body,不涵蓋 `type`;
- CDDL 的 `network/leave` = `op-only-req`,而它接受未知 key。

結果是擁有者授權的「加入」被拿去執行「離開」(其他 verb 組合同理)。

**實測 ✅**:我把向量 `owner_op.request_network_join` 的信封 `type` 改成 `network/leave`,其餘不動,重新編碼後跑 `verify.py` → **rc 0,156 項全過**。也就是說,一個漏掉 `verb == type` 的實作照樣能通過全部向量。

**修法:**
- 規格改成**節點一律用信封的 `type` 組簽章輸入**(不用 owner-op 裡的 `verb`),`verb` 只做一致性檢查;
- 加負向向量:type 與 verb 不同時必須拒絕。

stage-1 的 helper 是依自己被呼叫的動詞決定 verb,本身不受影響,但 Go 實作的 provd 與 app 只有向量這一個裁判。

### M2 開發版 TOFU:規格沒有要求 app 驗 `device_id == hex(SHA-256(dac_pub)[:9])`,第一次接觸可以被中間人頂替,之後 `net_secrets` 會外洩

**情境。** 附近的攻擊者廣播同樣的 `device_id` 末 4 碼,出示一張自簽憑證,`CN = "dev:<QR 上的 device_id>"`、`serialNumber = sn`(這兩個欄位都可以任意填)。

§3.3 的驗證步驟 3 只比對 CN 與 serialNumber;§9 的 TOFU 只寫「與 QR 的 `device_id` 一致」。照字面實作,app 會 pin 攻擊者的憑證:
- `claim/finish` 被送到攻擊者那邊。攻擊者拿不到 K,但 app 以為認領成功;
- 之後建網時,app 把 `net_secrets` 加密給攻擊者的 `ecdh_pub` → **SAE 密碼與 `net_root` 外洩**。

QR 和那把自簽公鑰之間唯一的綁定,就是 `sn = SHA-256(dac_pub)[:9]`(72 bit)。向量 `verify.py` 有驗這條公式,但**規格的 app 驗證步驟裡沒有**。

**修法:**
- §3.3 / §9 規定:file 後端(鏈長 1、`dev:`)時,app 必須以 `sn == SHA-256(憑證公鑰 SEC1 65 B)[:9]` 且 `hex(sn) == QR 的 device_id` 作為 TOFU 的前提;
- 加負向向量:CN 與 serialNumber 正確、但金鑰不同 → 拒絕。

### M3 階段 1 的節點到底用哪一套 prologue / 標籤,規格、向量、stage-1 三方不一致

- §9:開發版(DAC 在 SD 卡檔案 = 階段 1 的 file 後端)用 `batman-prov-dev/1` 與 `-dev` 標籤,而且「兩邊永遠無法互通」。
- §10:節點與 app 都要逐位元組通過向量;README 寫明「向量使用**正式版**的標籤與 prologue,`-dev` 之後另外產生」。
- stage-1 v19 完全沒提 dev prologue / 標籤。

**結果:**
- 如果階段 1 節點用正式版標籤:§9 的「永遠無法互通」對階段 1 不成立,正式版 app 只靠憑證規則擋(而這條規則有 M2 的問題);
- 如果用 `-dev`:**實際部署的設定沒有任何向量涵蓋**。

**修法:** 二選一並寫進三份文件——(a) 階段 1 用 `-dev`,並在本 PR 產生 dev 向量(至少 prologue、owner-op、claim、psk_replay);或 (b) 明寫階段 1 用正式版標籤,刪掉 §9 的「永遠無法互通」對階段 1 的適用。

附帶(m6):`-dev` 是後綴,所以正式版標籤是 dev 標籤的前綴(`batman-owner-op-v1` 是 `batman-owner-op-v1-dev` 的前綴)。

### M4 HTTP 冪等快取「跨 session 有效」,包含 `claim/finish` 的回應(其中有秘密),與 stage-1「不快取」相反

- §4.2:`claim/finish` 在必須帶冪等鍵的清單上,節點保留結果 10 分鐘、**跨 session**,重複的請求直接回傳上次的結果。`claim/finish` 的回應裡有 `owner_tag_key`、`adv_owner_key`、`root_password`。
- stage-1 §6.1 第 5 步寫明「**不快取**(回應遺失走 `claim/replay`,每次換新密碼)」。v0.7 現在同時有兩套「回應遺失」機制。
- 而且冪等快取沒有規定要綁角色 / 擁有者:另一個匿名 session 只要帶同一個 idem key,就能拿到秘密。
- 另外:
  - v0.7 新增的改狀態動詞(`claim/replay`、`ssh_keys/set`、`root_password/reset`)不在冪等清單上;
  - 已經一律回 `E_UNSUPPORTED` 的 `reset` 還留在清單上;
  - 冪等鍵(信封 key 7)不在 §5.1 的信封定義裡,也不在 `args_hash` 涵蓋範圍內——我改動向量請求的最後一個位元組(就是 idem key)仍然全過,這本身符合設計,但規格要寫清楚。

**修法:**
- `claim/finish`、`claim/replay`、`root_password/reset` 的回應不進快取(回應遺失一律走 `claim/replay`);
- 快取以 (擁有者 key id 或角色, type, idem key) 為鍵;
- 更新冪等清單;§5.1 的信封加上 key 7。

### M5 兩份文件的 `args_hash` 定義不同

- 本 PR 把 254-stage1 的 `owner_op` 列改成 `args_hash = SHA-256(deterministic CBOR(body 去掉 key 31))`;
- 但同一張表的 `net.apply` 列仍寫 `args_hash = H(net_config ‖ net_secrets)`,漏了 `member_list`、`invite_id`、`idem`(body 裡其他欄位),連串接方式都不同。

照 stage-1 實作的 helper 會驗不過 app 依協定產生的簽章(fail-closed,功能壞掉)。更糟的情況是:如果 helper 只驗 `net_config ‖ net_secrets`,被攻陷的 provd 就能換掉 `member_list`。

**修法:** `net.apply` 列改成引用協定 §5.7。helper 收的是完整 body 的位元組,自己解碼並自己算 `args_hash`。

## 3. 向量與驗證器(✅ 實跑)

```
verify.py vectors.json → "156 checks: ALL PASSED"(rc 0)
gen.py > tmp; cmp tmp vectors.json → GEN_IDENTICAL
```

我自己做的竄改實驗(複製 vectors.json 到 /tmp 後修改,每項重跑 verify.py):

| 竄改 | 結果 |
|---|---|
| `identity_file.sn` | FAIL ×3 ✅ |
| `identity_file.dev_cert_der` | FAIL(自簽驗不過)✅ |
| `psk_replay.psk_replay` / `ecdh_z` | FAIL ✅ |
| `noise_nxpsk0_replay.msg2` | rc 1 ✅ |
| `owner_op.args_hash` / `input` / `nonce_helper` | FAIL ✅ |
| 請求內 owner-op 簽章翻 1 bit | FAIL ✅ |
| 簽章後在 body 加欄位 | FAIL ×3 ✅ |
| owner-op verb 改成 `network/leave` | FAIL ✅ |
| **信封 type 改成 `network/leave`(verb 不動)** | **rc 0 全過 ❌ → M1** |
| `claim_replay.response` / `client_chal` / `nonce_helper` / 簽章 / 加欄位 | FAIL ✅ |
| `op_nonce.response` | FAIL ✅ |
| 請求最後一個位元組(= 信封 idem key) | 全過(符合設計;M4 要寫明) |

**CDDL 實測(pycddl 0.6)**:`root = bulk-open-resp` 時,**整數 `2` 被接受**、`3` 被拒 → 見 m1。

## 4. MINOR

- **m1. CDDL 留下一行孤兒。** 移除 `reset-level` 時漏刪了 `/ 2 ; zeroize (tactical only…)`,它接到前一條規則上,變成 `bulk-open-resp = {…} / 2`(上面的 pycddl 實測)。刪掉這一行,並加一條負向檢查。
- **m2. `claim/begin` 的角色兩處矛盾。** §3.5 的擁有者重取角色允許 `claim/begin`,§5.3 卻寫 `claim/begin` 只給「匿名」。另外,重取 session 裡 `claim/begin` 帶的 `owner_pub` 必須等於已存的那把,否則拒絕——這點沒有寫。
- **m3. app 的持久化義務不完整。**
  - §5.4 只要求持久化 `node_cert` 與 `claim-pending`。`claim/replay` 需要 K:要嘛持久化 K(用 keystore 包住),要嘛寫明重新掃 QR;
  - 節點其實沒提交(仍是 unclaimed)時,`psk_replay` 交握會失敗,app 要退回 NX 重新認領;
  - stage-1 L34 寫「app 被殺後重開仍可 replay」,和這裡對不上。
- **m4. field-provisioning v2.9 還有與 v0.7 衝突的舊文字。**
  - §5「擁有者身分驗證:每個請求附…`batman-owner-v1` ‖ 交握雜湊 ‖ 方法 ‖ 路徑 ‖ body 雜湊 ‖ nonce」——這是另一套逐請求授權,應改成引用協定 §5.7 的 owner-op;
  - §6.1 第 4 步仍寫「app 回 `HMAC(認領秘密, c)`」,與協定 §5.4 的 CheckMac 不同;
  - F2 的「簽章」列仍用 `batman-hs-v1`、`batman-net-v1` 這些舊標籤。
- **m5. §3.3 步驟 3 的 CN 規則沒處理開發版。** 寫的是「CN = `device_id`」,但開發版的 CN 是 `dev:` + `device_id`。要分開寫(連同 M2)。
- **m6. `-dev` 後綴讓正式版標籤成為開發版標籤的前綴。** 要讓兩者混淆,得把 `h` 的前 4 個位元組湊成 `-dev`,約需 2^32 次嘗試,而且兩邊通常不是同一把擁有者金鑰,實際風險低。仍建議改成在中間插入(例如 `batman-dev-owner-op-v1`),或簽章輸入加長度前綴。
- **m7. 首版與 `network/update` 的邊界沒寫清楚。**
  - 節點沒有網路時,`network/update` 必須拒絕——現在只寫了「只有 join + owner-op 能記下第 1 版」;
  - CDDL 的 `network-join-req` 把 key 31 設成一律必填,註解卻寫「required for the first version」;
  - stage-1 `net.apply` 寫「net 為空才需要 owner-op」。三處要統一(建議:join 一律需要)。
- **m8. 規格、CDDL 與 stage-1 的其他小落差。**
  - CDDL 的 `ssh-keys-set-req` 每行只限長度,沒有 stage-1 的 `^ssh-ed25519 …` 格式;
  - `claim/replay` 的失敗限速(stage-1 是每次開機每小時 10 次)沒寫進 §8;
  - §11 寫「`claim/replay`(以 replay session 的 h …)」,但向量沒有驗 `claim/replay` 的回應(`claim-finish-resp`)。
- **m9. verify.py 缺的負向測試**(除了 M1):
  - 「`claim/replay` 帶的 owner-op 用了不是已存的那把擁有者金鑰」;
  - 「擁有者有 2 位時 `psk_replay` 不得成立」只能在實作層測,要寫進 PR-H1 的清單。

## 5. 結論

v0.7 / v2.9 的大方向忠實於 stage-1 v19,向量可以重現,而且大部分欄位的竄改都會被抓到。

要先修 M1–M5,再整份複查。這五項都只需要改文件或補向量:
- 把 verb 與 type 綁在一起;
- 開發版 TOFU 要驗 sn 的公式;
- 決定階段 1 的標籤並補 dev 向量;
- 冪等快取不放秘密;
- 統一 `args_hash` 的定義。
