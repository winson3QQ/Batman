# Spec: 供裝協定 —— 安全通道與訊息協定(#219 B11 / #254)

Status: **DRAFT v0.7(#254 階段 1 實作設計 v19 回寫:`batman-owner-op-v1` 逐動詞授權、首版 `network/join` 需擁有者授權、`device_id` 公式與開發版自簽憑證、`psk_replay` 與固定試 6 次、`claim/replay`、`reset` 改回 `E_UNSUPPORTED`;向量 195 項全部通過)**;v0.6 為上一版
Parent: #254(階段 1)· 上位設計:`docs/design/219-field-provisioning.md`(PR #253)§3.3、§3.4、§5、§6.5
範圍:手機 app 與節點 `batman-provd` 之間的**安全通道**、**傳輸分段**、**訊息格式**,以及可以轉送的**簽章物件**。民用版;戰術版沿用同一層,只換成員提供者(上位設計 F2)。

## 0. 一句話

標準的 **Noise 交握**(`NX` / `NXpsk0`,25519)建立加密通道;節點身分由 **608B 的 P-256 簽章**放在交握 payload 裡證明(libp2p 的做法);擁有者身分在交握完成後以 **P-256 簽章綁定交握雜湊**;應用訊息用 **CBOR**;可轉送的簽章物件用 **COSE**。

## 1. 為什麼這樣選

| 決定 | 理由 |
|---|---|
| 用 Noise,不自己設計交握 | 成熟、被大量分析(WireGuard、WhatsApp、Lightning、libp2p) |
| `NX` 而不是 `XX` | 手機不需要 Noise 靜態金鑰:擁有者金鑰是 P-256(放在 Secure Enclave / Keystore),不能當 25519 靜態金鑰;用持久的靜態金鑰又會變成追蹤識別碼。手機身分改在交握後證明(§3.5)【依 v0.1 review】 |
| DH 用 25519 | Noise 官方只定義 25519 與 448【事實,Noise 規格】 |
| 節點身分用 608B 的 P-256 簽章放 payload | 608B 只支援 P-256;簽章不在 DH 路徑上;libp2p 以身分金鑰簽 Noise 靜態金鑰是已有做法【事實】 |
| ChaChaPoly | 3A+(Cortex-A53)沒有 ARMv8 AES 指令 |
| CBOR(RFC 8949 §4.2.1 core deterministic encoding:map key 依**編碼後的位元組**排序;收到非 deterministic 編碼的簽章物件一律拒絕)、COSE(RFC 9052 / 9053) | 小、標準、ES256 與 ECDH-ES 對上 608B |
| 實作:Rust `snow`(節點與手機共用) | 已查證:`snow` 有 `set_psk`、`get_handshake_hash`,超過 65535 B 會回錯;Go `flynn/noise` 有 `PresharedKey`、`ChannelBinding()`,可作替代。**Dart 的 `noise_protocol_framework` 只有 KNpsk0 / NKpsk0,沒有 XX / NX 與 25519,不可用**【事實,依 v0.1 review 查證】 |

## 2. 分層

```
應用訊息(CBOR 信封,§5)            ← 建網、加入、狀態、更新…
簽章物件(COSE,§7)                  ← 可經成員轉送、離線驗證
Noise 傳輸訊息(§3)                 ← 加密、防竄改、防重放
分段 / 傳輸(§4)                    ← BLE GATT(主)或 HTTP(備援)
```

## 3. 安全通道

### 3.1 模式

| 機台狀態 | Noise 協定名稱 | 誰能完成交握 |
|---|---|---|
| 未認領、legacy(v0.7) | `Noise_NX_25519_ChaChaPoly_SHA256` | 任何人 |
| 已認領 / 成員 | `Noise_NXpsk0_25519_ChaChaPoly_SHA256` | 只有持 PSK 的人(`psk_owner` 或目前版本的 `psk_member`) |

- 發起方 = 手機(只有臨時金鑰 `e`),回應方 = 節點(臨時 `e` + 靜態 `s_node`)。**第 1 則訊息的 payload 一律為空**;第 2 則的 payload = `node_cert`。
- **已認領的節點一律拒絕沒有 PSK 的 `NX`**(防止降級)。
- **手機選模式**:對自己的機台,依手機本機紀錄的狀態選,**不依廣播旗標**(廣播未經認證);對未知機台才看廣播。

### 3.2 Prologue

```
prologue = "batman-prov/1" ‖ 0x00 ‖ transport ‖ 0x00 ‖ device_hint
transport   = "ble" | "http"
device_hint = 未認領:QR / 廣播上的 device_id(ASCII);已認領:空字串
```
`"batman-prov-dev/1"` 保留給之後以開發根簽發的 608B 開發機(§9);**階段 1(v0.7)用正式 prologue**,開發機的隔離靠 `dev:` 憑證(§3.3、§9)。
legacy 節點(v0.7)的 `device_hint` 與未認領相同:廣播 / QR 上的 `device_id`。

### 3.3 節點身分(`node_cert`)

- 節點每次開機產生 25519 靜態金鑰 `s_node`(只在記憶體)與 16 B 隨機 `boot_id`,開機時請 608B 簽**兩個**帶標籤的證明:
  ```
  sig_static = ES256_DAC( "batman-node-static-v1" ‖ s_node_pub(32B) ‖ boot_id(16B) )
  sig_ecdh   = ES256_DAC( "batman-node-ecdh-v1"   ‖ ecdh_pub(65B, SEC1 未壓縮) )
  ```
  `ecdh_pub` 是 608B 裡 ECDH 槽的公鑰(§7 的加密對象);`sig_ecdh` 讓網主不會被騙去加密給攻擊者的金鑰【依 v0.1 review】。
- `node_cert`(CBOR map)放在交握第 2 則訊息的 payload:
  ```
  { 1: dac_chain [ bstr X.509 DER, … ],   ; 葉憑證在前,中繼憑證在後;**不放根憑證**(app 內建),節省 QR 空間
    2: s_node_pub (32 B),  3: boot_id (16 B),
    4: ecdh_pub (65 B),     5: sig_static (64 B, raw r‖s),  6: sig_ecdh (64 B),
    7: sn (9 B;608B 序號,或 file 後端 SHA-256(dac_pub)[:9],見下) }
  ```
- **手機的驗證**(全部通過才繼續):
  1. DAC 鏈驗到內建根(正式版只信正式根,§9);**開發版**(鏈長 1、自簽、CN 以 `dev:` 開頭)改為認領時 TOFU pin(§9);
  2. `sig_static` 對上 Noise 交握裡實際的 `s_node`;
  3. `sn` 與 DAC 憑證一致(`sn` 本身未被簽章)。**DAC 憑證的對應方式**:subject `CN` = `device_id`(file 後端為 `"dev:" + device_id`),subject `serialNumber` = `sn` 的小寫十六進位字串;
  4. **DAC 等於預期的目標**:未認領 = 與 QR 的 `device_id` 一致;已認領 = 等於手機本機紀錄的那台 DAC,或封包 / 指令的目標 DAC。**只驗憑證鏈不夠**,否則任何持有 `psk_member` 的成員機台都能冒充別台【依 v0.1 review,MUST】。
- **`sn` 與 `device_id`(v0.7)**:608B 後端 `sn` = 晶片序號;file 後端(階段 1)`sn = SHA-256(dac_pub 的 SEC1 未壓縮 65 B)[:9]`。一律 `device_id = sn` 的小寫十六進位(18 字元)。未認領 / legacy 節點的廣播帶 `device_id` 末 4 字元;已認領 / 成員不帶。file 後端的 DAC 是**自簽**憑證:subject `CN = "dev:" + device_id`、`serialNumber = hex(sn)`、有效期 2020-01-01 → 2120-01-01,`node_cert` 的 `dac_chain` 只有這一張(向量 `identity_file`)。
- **正式版 app 在每個看到 `node_cert` 或 DAC 的地方都拒絕 `dev:` 憑證**(交握第 2 則、加入申請、`peers/challenge` 的目標、`net_secrets` 的加密對象)。
- **開發版 TOFU 的前提(v0.7,MUST)**:app 在 pin 之前必須確認 `device_id == hex(SHA-256(該憑證公鑰的 SEC1 65 B)[:9])` **且**等於 QR 上的 `device_id`;只比 CN / serialNumber 不夠,任何看過 QR 的人都能自簽一張同 CN 的憑證(向量 `identity_file.forged_dev_cert_der` 必須被拒)。
- 608B 每次開機只簽兩次;`node_cert` 不過期 → 送出換密碼封包前,手機另做一次新鮮的 `peers/challenge`(§5.3)。
- 限制:拿到 root 的人能讀 `s_node`,在這次開機期間冒充節點;民用威脅模型已涵蓋。

### 3.4 PSK 模式的細節

- 已認領的節點收到第 1 則訊息時,以**常數時間**試**所有擁有者的 `psk_owner`(最多 4 把)、目前版本的 `psk_member` 與 `psk_replay`(§6)**:**固定試 6 次**(不足 6 把時以假 PSK 補足),不論是否已經成功。
- **全部失敗**:用**真的新臨時金鑰**組出一則格式正確的第 2 則訊息(payload 為等長隨機資料),並做與真交握相同次數的 DH;送出後**和真 session 一樣等到逾時才斷線**。隨機 32 B 不是合法的 X25519 公鑰格式(最高位元)、假訊息不做 DH、送完立刻斷線,三者都能被分辨【依第二輪 review,MUST】。
- 節點**只接受自己目前版本的 `psk_member`**,不接受舊版(否則被移除的成員還能連進來)。還沒更新的節點仍在舊版本,手機用**當時那一版**的 `psk_member` 連它 → 成員 app 保留各版 `psk_member`,依序試最近幾版(由新到舊,受 §8 全域限速)。**廣播不帶明文版本號**(會把同網節點串在一起、跨 RPA 關聯)【依第二輪 review】。

### 3.5 交握完成後:角色

Noise 完成後雙方取得交握雜湊 `h`(32 B)。session 的角色:

| 角色 | 條件 | 允許的訊息 |
|---|---|---|
| 匿名 | 未認領或 legacy 機台上的 `NX` 交握 | `info`、`claim/begin`、`claim/finish`(legacy 另需防呆門,§5.3) |
| 擁有者候選 | 用 `psk_owner` 完成交握 | 只有 `info`、`auth/owner` |
| 擁有者 | `auth/owner` 驗證通過;或在本 session 內 `claim/finish` 成功 | 擁有者的全部訊息 |
| 成員 | 用 `psk_member` 完成交握 | `status`(狀態部分)、`peers/challenge`、`network/update`(轉送) |
| 擁有者重取(v0.7) | 用 `psk_replay` 完成交握(節點已認領、**恰好一位擁有者**) | 只有 `info`、`claim/begin`(`owner_pub` **必須等於已存的那把**,否則 `E_FORBIDDEN`)、`op/nonce`、`claim/replay`;`claim/replay` 成功後升為擁有者 |

- `auth/owner`:`sig = ES256_owner( "batman-owner-auth-v1" ‖ h ‖ owner_key_id )`;節點比對 p5 裡的擁有者公鑰。
- 角色只會從「匿名 / 擁有者候選 / 擁有者重取」升到「擁有者」,不會降;要換角色就重新交握。
- **擁有者角色本身不足以改變節點**:每個改變節點的請求另外帶 owner-op(§5.7),節點以該擁有者公鑰驗證。

### 3.6 用途標籤

每種用途一個標籤;被簽 / 被 MAC 的內容一律以標籤開頭,且包含節點自己產生的 nonce 或 `h`。**節點絕不直接簽對方提供的值。**

| 標籤 | 用途 | 金鑰 |
|---|---|---|
| `batman-node-static-v1` | `s_node` 證明 | DAC |
| `batman-node-ecdh-v1` | ECDH 公鑰證明 | DAC |
| `batman-peer-v1` | `peers/challenge` | DAC |
| `batman-owner-auth-v1` | 擁有者 session 認證 | 擁有者 |
| `batman-owner-op-v1` | 逐動詞授權(owner-op,§5.7) | 擁有者 |
| `batman-psk-replay-v1` | `psk_replay` 導出(HKDF info,§6) | — |
| `batman-claim-v1` | 認領挑戰(CheckMac 的 ClientChal,§5.4) | 認領秘密 |
| `batman-netcfg-v1` | `net_config`(COSE) | 網主 |
| `batman-members-v1` | `member_list`(COSE) | 網主 |
| `batman-secrets-v1` | `net_secrets`(COSE) | 網主 |
| `batman-msecrets-v1` | `member_secrets`(COSE) | 網主 |
| `batman-owner-enc-v1` | 擁有者加密公鑰證明 | 擁有者 |
| `batman-invite-v1` | `invite`(COSE) | 網主 |
| `batman-joinreq-v1` | 加入申請(COSE) | 加入者的擁有者簽章金鑰 |
| `batman-sas-v1` | 確認碼 | — |

`-dev` 後綴的標籤保留給之後的 608B 開發機(§9);階段 1 用本表的正式標籤。

### 3.7 傳輸階段

- Noise 傳輸的 nonce 是 64 位元計數器,兩個方向各一把金鑰(`Split()`)。
- **任何一次 AEAD 失敗即中止連線**,不嘗試恢復。
- Noise 訊息最大 65535 B,扣掉 16 B tag,每則明文最多 65519 B。
- 重新交握:節點重開機、連線中斷、或累計 2^20 則訊息。

## 4. 分段與傳輸

### 4.1 BLE GATT

- 服務:Batman service UUID(128-bit,§12 Q1)。
- 特徵值:`RX`(手機 → 節點,Write Without Response)、`TX`(節點 → 手機,Notify)、`CTRL`(Read,不加密;CDDL `ctrl` = `{1: proto_major, 2: proto_minor, 3: max_frame, 4: max_msg}`)、**`STATUS`(Read,不加密,v0.7)**= `status/public`:CDDL `status-public`(格式版本、能力、`state`、`updating`;`device_id` 末 4 字元**只在** `state` ∈ {未認領 0、legacy 3} 時帶)。任何附近的人都讀得到:它暴露「這台是否已認領 / 正在更新」與能力;已認領 / 成員不帶任何識別。
- 框架:

  | 欄位 | 大小 | 說明 |
  |---|---|---|
  | flags | 1 B | bit0 = 開頭、bit1 = 結尾 |
  | seq | 2 B(大端) | **每則 Noise 訊息從 0 起算**,同一則訊息的框架遞增;下一則訊息重新從 0 開始 |
  | data | ≤ 框架上限 − 3 | 一則 Noise 訊息的片段 |

- 框架上限:手機端以 iOS `maximumWriteValueLength(.withoutResponse)` / Android 協商後的 MTU − 3 為準。
- 重組:收到「結尾」才交給 Noise;序號不連續、或累計長度超過 `max_msg`(`CTRL` 4,預設 65535;階段 1 BLE 為 8192)→ 中止連線。
- **中止**一律由「斷開 BLE 連線」表示,不設未經認證的中止旗標【依 v0.1 review】。
- 流量控制:手機等 `peripheralIsReady` / 寫入回呼;節點端用 BlueZ 的 `AcquireNotify` socket,佇列滿時暫停(D-Bus 的 notify 沒有回壓)【依 review】。

### 4.2 HTTP(備援:大量傳輸通道、開發)

> **v0.7 冪等規則**(取代下文舊清單):冪等鍵 `7: idem_key`(16 B 隨機)只用在**帶 owner-op 的請求**(§5.3)與 `network/update`;快取以 `(擁有者 owner_key_id 或轉送者 session、idem_key)` 為鍵,**只回給同一位擁有者已認證的 session**;節點**先查快取、命中就直接回上次結果,不再驗 owner-op**(否則重送會因 `nonce_helper` 已用掉而失敗),未命中才驗。**回應帶秘密的請求一律不快取、也不得帶冪等鍵**(帶了即 `E_FORBIDDEN`,CDDL 亦拒絕):`claim/finish`、`claim/replay`、`root_password/reset`、`owner/add`(回 `owner_tag_key`)、`bulk/open`(回一次性 PSK)。回應遺失時:`claim/replay`;重新 `root_password/reset`(新密碼);對同一把 `owner_pub` 重送 `owner/add` 會輪替該擁有者的 `owner_tag_key` 並回新值;重新 `bulk/open` 會關掉舊通道、發新 PSK。`reset` 已不在清單。

- `POST /batman/v1/session`:body = 交握訊息;回應 = 交握訊息 + header `X-Batman-Session`(128-bit 隨機,base64url **不加 padding**)。
- `POST /batman/v1/msg`:body = 一則 Noise 傳輸訊息;**每個 session 一次只能有一個未完成的請求**;回應遺失時,手機以同一個冪等鍵重送(依上方 v0.7 規則)。節點保留最近 32 筆、10 分鐘;快取項記 `(type, args_hash)`,**冪等鍵相同但 type 或 `args_hash` 不同 → `E_FORBIDDEN`**,不回別的請求的結果。
- HTTP 裡一律跑完整的 §3,不依賴 TLS。

## 5. 應用訊息

### 5.1 信封(CBOR,deterministic encoding)

請求:`{ 0: proto_ver [major, minor], 1: id (uint), 2: type (tstr), 3: body (map), 6: part? }`
回應:`{ 1: id, 4: status (uint, 0 = ok), 3: body / 5: error, 6: part? }`

- `id`:手機產生,單一 session 內遞增;節點拒絕**完整訊息**的重複或倒退 `id`。成功回應帶 `3: body`,錯誤回應帶 `5: error`,**兩者互斥**。
- **分塊**(請求與回應都可以):整則訊息編碼後超過 `max_msg − 16` B(`CTRL` 4;預設 65535 − 16 = 65519)時分塊,**每個分塊的整個信封**(含 key 0/1/2/3/6/7)編碼後都必須 ≤ `max_msg − 16`(向量 `chunk_boundary`:8192 時最壞情況 body 片段上限);把**編碼後的 body map** 切成多段;每段是一則訊息,`3` = 該段的 **bstr**,`6 = {1: n, 2: total}`,**所有分塊共用同一個 `id`**(與同一個冪等鍵);收到重複的 `(id, n)` 即拒絕;收齊後依序串接再解碼,總大小上限 1 MB。訊息類型與 body 的對應見 CDDL 的 `whole-request`。
- `7: idem_key`(16 B):見 §4.2 的 v0.7 冪等規則。
- 版本:`major` 不同 → `E_VERSION`,手機只允許 `info`、`status`,並提示「更新 app,或用轉賣工具重燒卡」(階段 1 沒有 `reset`,v0.7);未知 `type` → `E_UNKNOWN_TYPE`;**body 的未知欄位忽略**(簽章物件除外,§7)。

### 5.2 錯誤碼

| 碼 | 名稱 | 何時 |
|---|---|---|
| 1 | `E_VERSION` | 主版本不相容 |
| 2 | `E_UNKNOWN_TYPE` | 不認得的訊息類型 |
| 3 | `E_FORBIDDEN` | 角色不允許 |
| 4 | `E_BAD_OBJECT` | 簽章物件驗證失敗(不說明是哪一項) |
| 5 | `E_STALE_VERSION` | 版本鏈不完整或不連續 |
| 6 | `E_UNSUPPORTED` | 沒有這項能力 / 參數不支援(附 `capability`、`reason`) |
| 7 | `E_BUSY` | 正在進行另一項操作 |
| 8 | `E_CLAIM_WINDOW` | 認領窗口沒開 |
| 9 | `E_CLAIM_FAILED` | 認領失敗(不說明原因) |
| 10 | `E_STORAGE` | 寫入 p5 失敗 |
| 11 | `E_REJECTED` | 更新被拒(附原因) |
| 12 | `E_RATE` | 超過限速 |

### 5.3 訊息目錄(階段 1 範圍)

| type | 角色 | 請求 | 回應 |
|---|---|---|---|
| `status/public`(v0.7) | **不是訊息**:未加密的 GATT `STATUS` 特徵值(§4.1),交握前即可讀 | — | CDDL `status-public` |
| `info` | 全部 | — | `device_id`、`model`、`board`、`fw_version`、`proto_ver`、`capabilities[]`、`state`、`claim_window`、`net_version`(成員以上才有) |
| `claim/begin` | 匿名、擁有者重取 | `owner_pub`(65 B) | `nonce`(32 B) |
| `claim/finish` | 匿名 | `response`(32 B,§5.4)、`owner_enc_pub` + `sig_enc`(§6) | `owner_tag_key`(32 B,**每位擁有者各一把**)、`adv_owner_key`、`root_password`;session 升為擁有者 |
| `op/nonce`(v0.7) | 擁有者、擁有者重取 | — | `nonce_helper`(32 B,一次性、60 秒、綁本 session 的 `h`) |
| `claim/replay`(v0.7) | 擁有者重取 | `response`(32 B,§5.4,以**已存的** `owner_pub` 重算)、owner-op(`claim/replay`) | 同 `claim/finish`(`root_password` 為新產生);session 升為擁有者 |
| `auth/owner` | 擁有者候選 | `owner_key_id`(32 B = SHA-256(owner_pub 65 B))、`sig` | 目前的 `adv_owner_key` |
| `owner/add` | 擁有者(v0.7:對已存在的 `owner_pub` 重送 = 輪替**該**擁有者的 `owner_tag_key`,新值回給發出請求的擁有者;擁有者彼此對等,任一位本來就能移除另一位,故非新權限;`adv_owner_key` 不變,只在 `owner/remove` 輪替) | 新擁有者的 `owner_pub`、`owner_enc_pub`、`sig_enc` | 新擁有者的 `owner_tag_key`(由現任擁有者的 app 轉交) |
| `owner/remove` | 擁有者 | `owner_key_id` | —(被移除者的 `owner_tag_key` 與其 `psk_owner` 一併刪除;**廣播用的 `adv_owner_key` 輪替**,其他擁有者下次 `auth/owner` 時取得新值)【依 review】 |
| `settings/get` / `settings/set` | 擁有者 | 依能力分組 | 目前值 |
| `network/join` | 擁有者 | `net_config`、`member_list`、`net_secrets`(本機那份)、選填 `invite_id` | `joined` / `pending` |
| `network/update` | 擁有者、成員(轉送) | 版本鏈(§7.5) | 套用後的版本 |
| `network/leave` | 擁有者 | — | — |
| `status` | 擁有者、成員 | `scope`(self / team) | #131 的 status + 入網失敗原因 + `p5_saved`;成員只得到狀態摘要 |
| `peers/challenge` | 成員 | `nonce_app`(32 B) | `nonce_node`(32 B)、`sig = ES256_DAC("batman-peer-v1" ‖ nonce_app ‖ nonce_node ‖ h)` |
| `diag/summary`、`diag/bundle` | 擁有者 | — | 摘要 / 分塊回應 |
| `update/check` | 擁有者 | `manifest` | `ok` 或 `E_REJECTED` + 原因、所需 RAM |
| `bulk/open` / `bulk/close` | 擁有者 | `purpose` | `ssid`、`psk`(一次性)、`ip`、`port`、`expires_in`(相對秒數) |
| `update/prepare` / `apply` / `status` | 擁有者 | — | 進度 |
| `ssh_keys/set`(v0.7) | 擁有者 | `keys`(0–8 行;每行**整行**符合 `ssh-ed25519 [A-Za-z0-9+/=]{1,200}( [ -~]{0,40})?`、不得含 CR / LF、≤ 256 B)、owner-op | — |
| `root_password/reset`(v0.7) | 擁有者 | owner-op | 新 `root_password`(24 字元,只回一次) |
| `reset` | 擁有者 | — | **階段 1 一律 `E_UNSUPPORTED`**(`capability` = `reset`、`reason` = 9「用轉賣工具重燒卡」);恢復出廠在 #255 重新設計(v0.7) |

**owner-op(v0.7)**:`network/join`、`network/leave`、`owner/add`、`owner/remove`、`settings/set`、`diag/bundle`、`ssh_keys/set`、`root_password/reset`、`claim/replay`、`update/prepare`、`update/apply`、`bulk/open`、`bulk/close` 的 body 必須在 key 31 帶 owner-op(§5.7);缺少或驗不過 → `E_FORBIDDEN`。(`update/*`、`bulk/*` 階段 1 不實作;實作時 MUST 帶 owner-op。)

**legacy(v0.7)**:`info.state` = 3;以 `NX` 認領,`claim/finish` 另要求節點已有可用的 SSH 公鑰或開發旗標(否則操作員會被自己鎖在外),不符回 `E_UNSUPPORTED`(`capability` = `claim`,`reason` = 10)。**這道門在 CheckMac 驗證通過之後才判斷**,否則沒有認領秘密的人也能探出「這台沒有 SSH key」。

**沒有網路時的 `network/update`**:回 `E_STALE_VERSION`;第 1 版只能經 `network/join`(§7.1)。`network/update` 是轉送,以版本鏈的 `admins` 驗證(§7.1),不帶 owner-op。

### 5.4 認領挑戰(對齊 608B CheckMac)

608B 的 `CheckMac` 不是 HMAC。mode 0 的運算是【事實,依 review 查證 Microchip 文件與 cryptoauthlib `atcah_check_mac`】:

```
response = SHA-256( K(32) ‖ ClientChal(32) ‖ OtherData[0:4] ‖ 0x00×8 ‖ OtherData[4:7]
                    ‖ SN[8] ‖ OtherData[7:11] ‖ SN[0:2] ‖ OtherData[11:13] )      ; 共 88 B
```

本協定的定義:
- `K` = 認領秘密(QR 上的 32 B)。
- `ClientChal` = `SHA-256( "batman-claim-v1" ‖ nonce ‖ h ‖ SHA-256(DAC 憑證 DER) ‖ owner_pub )`。
- `OtherData` = `08 00 00 00 00 00 00 00 00 00 00 00 00`(mode 0,其餘為零;與槽位配置無關,已定案)。
- `SN` = `node_cert` 裡的 608B 序號(不是秘密)。
- **階段 1 起就用這個格式**(軟體計算同樣的 SHA-256),階段 2 換成 608B 時線上格式不變【依 review,MUST】。
- **節點自己重算 `ClientChal`(v0.7)**:用自己發給本 session 的 `nonce`、本 session 的 `h`、自己的 DAC、以及**即將寫入的** `owner_pub`(`claim/finish`:本 session `claim/begin` 送來的那把;`claim/replay`:已存的那把);不接受任何外部提供的挑戰值或雜湊。節點內部若分成非 root 的協定行程與 root 的 helper,由 helper 重算(#254),協定行程被攻陷也換不了擁有者。
- **app 的義務(v0.7)**:送出 `claim/finish` **之前**,先持久化 `node_cert`(含 `ecdh_pub`)與 `claim-pending{device_id, owner_pub}`;回應遺失時才算得出 `psk_replay`(§6)並以 `claim/replay` 取回金鑰;`claim/replay` 也要認領秘密 K,app 要嘛連 K 一起持久化(存在 keystore 保護的儲存),要嘛請使用者重掃 QR。若節點其實沒有提交(`status/public` / `info` 仍是未認領),app 改走一般的 `NX` 認領。

### 5.5 確認碼(SAS)

```
sas = 補零到 6 位( int_big_endian( SHA-256( "batman-sas-v1" ‖ OBJECT_HASH(邀請) ‖ OBJECT_HASH(申請) ) ) mod 10^6 )
```
- `OBJECT_HASH` 見 §7.1。涵蓋**整個邀請**(`net_id`、`admins`、`invite_id`)與**整個申請**(加入者 DAC、`ecdh_pub`、擁有者公鑰、`owner_enc_pub`)。只涵蓋 `invite_id` 與 DAC 時,攻擊者可以**替換申請圖片裡的擁有者公鑰**(把 `member_secrets` 騙到自己手上),或**替換邀請圖片**(讓加入者加入攻擊者的網路),SAS 卻仍一致【依第二輪 review,MUST】。
- **SAS 必須經另一條管道核對**:當面看兩支手機,或打電話;不能用傳圖片的同一個聊天。
- 6 位數的強度可接受,前提是攻擊者無法大量取得合法 DAC(DAC 只能由 608B 產生、經出廠簽發)。

### 5.6 CBOR 整數 key 表

**完整定義在 `docs/design/219-protocol.cddl`(CDDL,RFC 8610)**:每個訊息 body、`node_cert`、所有 COSE payload、QR 物件都有整數 key、型別、是否必填。原則:
- 0–15 保留給信封;各訊息 body 從 1 起編;新增欄位只能用新的 key,不重用。
- 訊息 body 的未知 key 忽略;**簽章物件的未知 key 拒絕**。
- 內嵌的 COSE 物件一律以**巢狀 CBOR 項目**(tagged 18 / 96)內嵌,不包成 bstr。
- `OtherData`(§5.4)= `08 00 00 00 00 00 00 00 00 00 00 00 00`(mode 0,其餘為零)。
- content type 用短字串:`batman/netcfg`、`batman/members`、`batman/secrets`、`batman/msecrets`、`batman/invite`、`batman/joinreq`。

### 5.7 逐動詞授權(owner-op,v0.7)

```
owner_op  = { 1: verb (tstr, 1–255 B ASCII), 2: sig (64 B raw r‖s, low-s) }      ; 放在請求 body 的 key 31
sig       = ES256_owner( "batman-owner-op-v1" ‖ h(32) ‖ nonce_helper(32) ‖ u8(len(verb)) ‖ verb ‖ args_hash(32) )
args_hash = SHA-256( deterministic CBOR(請求 body,去掉 key 31) )
```
- `verb` **必須等於**信封的 `type`;節點**以信封的 `type` 組簽章輸入**(不信任 `verb` 欄位本身),不等即 `E_FORBIDDEN`(否則被攻陷的協定行程能把擁有者簽好的 `network/join` 改成 `network/leave` 送出)。
- 節點驗證時以**收到的原始 body** 解碼(拒絕重複 key 與非 deterministic 編碼),去掉 key 31 後重新編碼計算 `args_hash`,並**只依這份解碼結果**執行(#254:root helper 收原始 body,不收協定行程拆好的欄位)。
- `nonce_helper` 由 `op/nonce` 取得:一次性(**任何一次驗證嘗試都會消耗它**)、60 秒、綁本 session 的 `h`;每個 owner-op 用一個新的。
- 驗證金鑰:這台節點已存的擁有者公鑰(最多 4 把,逐一嘗試);`claim/replay` 只用已存的那一把。
- 因為 `args_hash` 涵蓋整個 body,轉送者或協定行程無法在擁有者簽章之後增減欄位(向量 `owner_op` 的負向測試)。
- `batman-owner-auth-v1`(§3.5)只用在 session 角色升級,格式不變;一個標籤一種格式。

## 6. 金鑰與導出

| 金鑰 | 產生 | 存放 | 用途 |
|---|---|---|---|
| 認領秘密 `K`(32 B) | 出廠 | 608B(只能 CheckMac);QR | 認領 |
| DAC(P-256) | 出廠,608B 內產生 | 608B | §3.3、`peers/challenge` |
| ECDH 金鑰(P-256) | 出廠,608B 內產生 | 608B | §7 的加密對象 |
| `s_node`(25519) | 每次開機 | 記憶體 | Noise 靜態金鑰 |
| 擁有者簽章金鑰(P-256) | app | 手機 keystore(ECDSA) | `auth/owner`、`sig_enc` |
| 擁有者加密金鑰(P-256) | app | 手機 keystore(ECDH;Android 12 / API 31 以上的 `PURPOSE_AGREE_KEY`、iOS `SecureEnclave.P256.KeyAgreement`)。**Android 11 以下**:以軟體金鑰,私鑰用 keystore 的 AES 金鑰加密後存放 | §7.4 的加密對象;公鑰由簽章金鑰簽證 `sig_enc = ES256_owner("batman-owner-enc-v1" ‖ owner_enc_pub)`。**一把金鑰不兼兩種用途**【依第二輪 review】 |
| `owner_tag_key`(32 B,每位擁有者一把) | 認領時、新增擁有者時 | p5 + 該擁有者的 app | 該擁有者的 `psk_owner` |
| `adv_owner_key`(32 B,每台一把) | 認領時;移除擁有者時輪替 | p5 + 所有擁有者 app | 廣播的擁有者標記 |
| `net_root`(32 B) | 建網、換密碼時 | 成員節點(§7.3)、成員 app(§7.4) | `psk_member`、廣播摘要金鑰 |
| 網主金鑰組(P-256,可多把) | 網主 app、備用管理手機 | 手機 keystore;公鑰列在 `net_config` | 簽 COSE 物件 |

**導出**(HKDF-SHA256,salt 為空,輸出 32 B):
```
psk_owner  = HKDF( owner_tag_key, "batman-psk-owner-v1" ‖ device_id )
psk_member = HKDF( net_root,      "batman-psk-member-v1" ‖ net_id(16 B) ‖ u32BE(net_version) )
adv_owner  = HKDF( adv_owner_key, "batman-adv-owner-v1" ‖ device_id )
adv_member = HKDF( net_root,      "batman-adv-member-v1" ‖ net_id ‖ u32BE(net_version) )
psk_replay = HKDF( z,             "batman-psk-replay-v1" ‖ device_id )      ; v0.7
             z = ECDH(node_ecdh_priv, owner_enc_pub) 的 x 座標(32 B)= app 端 ECDH(owner_enc_priv, node_cert.ecdh_pub)

- `device_id` 一律以 ASCII 編碼、放在 info 的最後一欄(長度不固定)。
- 節點以常數時間試所有擁有者的 `psk_owner`、目前的 `psk_member` 與 `psk_replay`,固定 6 次(擁有者數量上限 4)。
- `psk_replay` 只在節點**恰好有一位擁有者**時存在(否則以假 PSK 補位);只看過 QR 的人(前任、修理行)沒有擁有者加密私鑰,算不出它,探測不到已認領的節點。608B 的 ECDH 槽本來就能輸出共享秘密給主機(§7.3),file 後端由 helper 以 `ecdh.key` 計算。
```

**誠實界線**:`psk_member` 是全網共用的。任何一台成員節點的 SD 卡或任何一支成員手機外流,就等於拿到全網的成員權限,而且無法單獨撤銷某一個人,只能換密碼(`net_version` +1)。這是民用版「共用密碼」模型的固有限制(上位設計 P6)【依 review】。

## 7. 簽章物件(COSE)

### 7.1 通則

- 一律 `COSE_Sign1`(tagged 18),演算法 ES256,簽章值 raw r‖s(64 B),**s 必須 ≤ n/2(low-s),否則拒絕**;**unprotected header 必須為空 `{}`,否則拒絕**。手機 keystore 輸出的 DER 簽章要轉換並正規化為 low-s。
- protected header 帶 `content type` = 物件種類(`batman/netcfg`、`batman/members`、`batman/secrets`、`batman/msecrets`、`batman/invite`、`batman/joinreq`),`external_aad` = 該物件的標籤(§3.6)→ 物件之間不會混用。
- **物件雜湊(OBJECT_HASH)** = `SHA-256( cbor(["Signature1", protected, external_aad, payload]) )`,也就是對 Sig_structure 取雜湊,**不含簽章與 unprotected header**。`prev_hash`、SAS、加入申請的邀請雜湊一律用它;直接雜湊整個 Sign1 時,把 s 換成 n−s 或塞 unprotected 欄位都能改變雜湊,轉送者可藉此弄斷版本鏈或製造假分叉【依一致性 review,MUST】。
- payload 一律 deterministic CBOR;**簽章物件的未知欄位不忽略:拒絕**。
- **第 v+1 版的簽章,一律以第 v 版 `net_config` 的 `admins` 驗證**(逐一嘗試,最多 4 把;不加 `kid`);物件自己那一版的 `admins` 只對下一版生效。第 1 版由建立者自簽,手機與節點記下 `net_id` 與建立者公鑰【依第二輪 review,MUST:否則任何人都能發一版把自己列為網主】。**節點在沒有任何網路時(第 1 版),只在 `network/join` 帶有這台節點擁有者的 owner-op(§5.7,`args_hash` 涵蓋整個 body)時才記下**(v0.7):否則任何能對節點送請求的人(含被攻陷的協定行程)都能塞一個自己建的網路。
- COSE 一律用 **tagged** 形式(`COSE_Sign1` tag 18、`COSE_Encrypt` tag 96);content type 用 tstr。
- **雜湊的輸入**:`dac_pub_hash`、`target_dac_hash`、SAS 中的公鑰一律為 `SHA-256(SEC1 未壓縮 65 B 公鑰)`;`prev_hash` = 上一版的 OBJECT_HASH。

### 7.2 `net_config`(公開設定)
```
{ net_id(16 B), net_version(u32), prev_hash(32 B,上一版 net_config 的 SHA-256), name,
  country, halow: { ssid, channel, bandwidth }, lora: { channel_name, preset }?,
  admins: [ admin_pub, … ] }
```
**不含任何秘密**。

### 7.3 `net_secrets`(給某一台節點的秘密)
```
COSE_Sign1( payload = {
    net_id, net_version, target_dac_hash(32 B),
    enc: COSE_Encrypt( plaintext = { sae_password, net_root, lora_psk?, team_ap_psk },
                       content alg = ChaCha20/Poly1305 (alg 24),
                       recipient = ECDH-ES + HKDF-256 (alg −25),臨時公鑰以 COSE_Key 放在 recipient 標頭 −1(EC2,crv P-256,x / y 各 32 B),
                                   對 target 的 ecdh_pub(由 sig_ecdh 證明),
                                   KDF context:AlgorithmID = 24,keyDataLength = 256,PartyU = nil,
                                   PartyV.identity = target_dac_hash,
                                   SuppPubInfo.other = net_id ‖ u32BE(net_version) )
}, external_aad = "batman-secrets-v1" )

COSE_Encrypt 的固定參數:body protected `{1: 24}`、unprotected `{5: IV(12 B 隨機)}`、Enc_structure 的 external_aad = 物件標籤;recipient protected `{1: -25}`、unprotected `{-1: 臨時 COSE_Key(EC2,P-256,x / y 各 32 B)}`;HKDF salt 為空、L = 32;KDF context 的 keyDataLength = 256(bits)。
```
- **密文在網主簽章的 payload 裡面**,所以轉送的人換不掉密碼欄位(ECDH-ES 的發送方是匿名的)【依 review,MUST】。
- 每台節點一份;網主加密前一律驗 `sig_ecdh`。
- 608B 這端:ECDH 指令可以輸出共享秘密給主機(或以 IO protection key 加密輸出),主機再做 HKDF【事實,依 review 查證】;`ECDHPROT` 與 IO protection key 的存放在 B1 決定。

### 7.4 `member_secrets`(給成員 app 的秘密)
與 §7.3 相同結構,標籤 `batman-msecrets-v1`,對象是**成員的擁有者加密金鑰** `owner_enc_pub`(須先驗 `sig_enc`);KDF context 的 PartyV.identity = `SHA-256(owner_enc_pub)`;plaintext = `{ 2: net_root }`(成員 app 用來導出 `psk_member`、`adv_member`)。網主同意加入時、以及每次換密碼時,發給每位成員的 app【依 review,MUST:原設計成員 app 拿不到 `net_root`】。

### 7.5 `member_list` 與版本鏈
```
member_list = { net_id, net_version, prev_hash,
                members: [ { dac_pub_hash, ecdh_pub, name, owner_pub, lora_pkc_pub? } ],
                removed: [ dac_pub_hash ],
                used_invites: [ invite_id ], revoked_invites: [ invite_id ] }
```
- `network/update` 帶從節點目前版本 `v` 到最新的每一版公開物件(`net_config`、`member_list`),每版的 `prev_hash` 要等於上一版的 OBJECT_HASH;**`net_secrets` 只帶最新一版**;**不接受跳號**。
- **分叉**(同一版本出現兩個不同的物件,例如兩位網主同時修改):以**雜湊值較小者**為準(確定性規則);已套用另一支的節點在看到勝出的鏈時切換;下一版的 `prev_hash` 一律指向勝出者;app 告警網主。民用版接受「共同網主可以故意製造分叉干擾」這個限制。
- **轉送給落後的節點**:落後節點需要的是從它的版本到最新版的公開物件鏈(`net_config`、`member_list`),加上**最新一版**它自己的 `net_secrets`;網主 app 把各成員節點最新的 `net_secrets`(已對各節點加密,轉送無害)同步給所有成員 app。

### 7.6 邀請
| 種類 | 內容 | 秘密如何送達 | 「一次性」怎麼保證 |
|---|---|---|---|
| **當面**(QR 只顯示在網主螢幕) | `{ net_id, invite_id, kind: in_person, net_config(公開), sae_password, admin_pub }` | **QR 內含 SAE 密碼**(等同當面告訴對方密碼),加入者的節點先入網,經 mesh 把**申請**送到網主的節點,網主節點再經 BLE 交給網主 app | **兩支手機同時顯示 SAS,網主核對後按一下同意**(不自動同意);同一個 `invite_id` 出現第二個申請時告警並拒絕【依第二輪 review,MUST:自動同意等於沒人比對 SAS,拍到 QR 的人可搶先】 |
| **遠端**(QR 圖片) | `{ net_id, invite_id, kind: remote, net_config(公開), admin_pub }`,**不含秘密**;`admin_pub` 必須屬於 `net_config.admins` | 加入者 app 產生一張**加入申請圖片**(CDDL `join-request`:邀請的 OBJECT_HASH、加入機台的 `node_cert`、擁有者簽章公鑰與加密公鑰 + `sig_enc`、機台名稱;由加入者的擁有者簽章金鑰簽,標籤 `batman-joinreq-v1`),經同一個聊天管道傳回網主;網主核對 SAS 後同意,回傳一張**同意圖片**(該節點的 `net_secrets` + 成員 app 的 `member_secrets`) | 網主只對自己發出、尚未使用的 `invite_id` 同意 |
| **加入碼**(只能講話) | 能還原 `net_config` 公開部分 + SAE 密碼 | 等同告訴對方密碼 | 網主收到申請時以 SAS 核對 |

> **使用者決定 (a)(2026-10-06)**:遠端加入採雙向傳圖片(邀請 → 申請 → 同意)。民用版只靠共用密碼,**拿到 SAE 密碼就能進網**,所以遠端圖片不帶密碼,「同意」才真正有效。上位設計 §2.2 已改為朋友 4 步、網主 2 + 2 步(v2.8)。
>
> 圖片格式:三種圖片都是 QR(`qr-object`,CDDL),內容為 deterministic CBOR,用**二進位模式**(不用 base45)。同意圖片**不重複帶 `net_config`**(加入者已從邀請取得)。測試向量的實測大小:邀請 428 B、加入申請 957 B、同意 1050 B,**都在 QR version 25-L(1273 B)以內**,一個 QR 放得下;超過時才用 `qr-fragment` 拆片。申請圖片帶加入者 app 的擁有者公鑰與加密公鑰,讓網主把 `member_secrets` 加密給它。

## 8. 限制與逾時

| 項目 | 值(初稿) |
|---|---|
| 交握逾時 | 10 秒 |
| 每個 BLE 連線同時進行的交握 | 1 |
| **全域**交握次數(所有連線合計) | 每分鐘 20 次 |
| 未認證 / 擁有者候選 session 的閒置逾時 | 30 秒,且可被新的連線擠掉 |
| 已認證 session 的閒置逾時 | 5 分鐘 |
| 認領失敗(每個連線) | 3 次後斷線(只存在記憶體) |
| `peers/challenge`(608B 簽章,約 100 ms,與 INA226 / RTC 共用 I2C) | 全域每秒 2 次 |
| 單則應用訊息(分塊後) | 1 MB |
| 單則 Noise 訊息(階段 1 BLE,v0.7) | 8192 B(`CTRL` 4 `max_msg`;明文超過 `max_msg − 16` 走 §5.1 分塊) |
| 同時 BLE 連線(v0.7) | 2 |
| `claim/replay` 失敗(v0.7,節點全域) | 每次開機每小時 10 次 |
| 未用的 `nonce_helper`(v0.7) | 每個 session 最多 4 個;超過時最舊的作廢 |

## 9. 開發版與正式版的隔離

| 項目 | 正式版 | 開發版(階段 1) |
|---|---|---|
| DAC | 608B 內,正式根簽發 | P-256 私鑰在 SD 卡檔案,**自簽**(`CN = dev:<device_id>`,§3.3;v0.7 不再有開發根:公開 repo 裡的 CA 私鑰等於假的信任根) |
| 認領秘密 | 608B(CheckMac) | 檔案,軟體算同樣的 §5.4 格式 |
| ECDH 金鑰 | 608B | 檔案 |
| prologue | `batman-prov/1` | `batman-prov-dev/1`(**保留給之後以開發根簽發的 608B 開發機**;v0.7:階段 1 的 file 後端用正式 prologue) |
| 標籤 | 如 §3.6 | 一律加 `-dev`(同上;階段 1 用正式標籤,向量即為階段 1 的格式) |
| app | 只內建正式根,**拒絕鏈長 1 或 CN 以 `dev:` 開頭的憑證,沒有切換開關** | 認領時 TOFU pin 該台的自簽憑證(與 QR 的 `device_id` 一致),之後只認同一張;畫面標「開發機」 |

協定、訊息、物件結構完全相同。v0.6 的「兩邊永遠無法互通」靠 prologue 與標籤;**v0.7 階段 1 改靠憑證**(下句)【依 review】。**階段 1(v0.7)的隔離靠憑證**:正式版 app 在第 2 則訊息驗 `node_cert` 時就拒絕自簽 `dev:` 憑證,**在送出任何秘密之前**;開發版 app 走 TOFU(§3.3 前提)。

## 10. 實作

- **v0.7(#254 U2)**:不做共用函式庫。**節點用 Go**(`batman-provd` 非 root 跑協定、`batman-provhelper` root 持有秘密;Noise 用 `flynn/noise`,
  CBOR / COSE 用 Go 實作),**app 用 Rust**(`batman-proto`,sans-IO,`snow`;Flutter + `flutter_rust_bridge` v2)。
- 兩份實作的**裁判是測試向量與對手實作**(§11):`verify.py` 以另一套函式庫逐項重算;節點與 app 都要逐位元組通過向量,並與 `verify.py`
  做對手交握(PR-H1)。
- 簽章與 ECDH 一律在平台側(手機 Secure Enclave / Keystore;節點的 helper 或 608B),協定程式只拿到「要簽的內容」由 helper 自己組好的結果(#254 §4.1)。
- Go 工具鏈已在 firmware(#252,`go1.26.4`,vendoring);Rust 只在 app 端,不進 OpenWrt。

## 11. 測試向量

**已完成**:`tests/vectors/219-protocol/`(`vectors.json`、`gen.py`、`verify.py`、`README.md`)。
- `gen.py` 以固定金鑰與決定性 ECDSA(RFC 6979)產生,**可逐位元組重現**。
- `verify.py` 以**另一份實作**逐項驗證,共 **195 項**(v0.6 為 119 項)(含負向測試:錯的 PSK / prologue、換標籤、high-s、竄改密文、簽章物件內的未知 key、訊息類型與 body 不符、版本鏈以錯誤的網主組驗證):Noise 用 `dissononce` 重跑 `NX` 與 `NXpsk0` 交握(位元組必須與 `noiseprotocol` 產生的完全相同)、ECDSA / ECDH 用 `python-ecdsa`、HKDF 用標準庫 `hmac`、所有物件以 `pycddl` 對 CDDL 驗證結構。
- 涵蓋:測試根憑證與 DAC、`node_cert`、HKDF、兩種 Noise 交握、`auth/owner`、認領 CheckMac(88 B)、`sig_enc`、`peers/challenge`、全部 COSE 物件(含 ECDH 共享秘密、KDF context、CEK)、SAS、QR 大小、GATT 框架、CBOR 信封。
- **v0.7 新增**:file 後端身分(`sn` / `device_id` 公式、自簽 `dev:` 憑證)、`psk_replay`(節點端與 app 端 ECDH 相等、HKDF、以它跑的 `NXpsk0` 交握且 `psk_owner` 打不開)、owner-op(`args_hash`、簽章輸入、換 verb / 換 `h` / 換 nonce / 簽後增減 body 欄位 / 他人金鑰 / high-s 一律驗不過、缺 key 31 的 `network/join` CDDL 拒絕)、`op/nonce`、`claim/replay`(以 replay session 的 `h` 與已存 `owner_pub` 重算 CheckMac;擁有者 session 的 owner-op 在 replay session 驗不過)、`reset` 的 `E_UNSUPPORTED` reason 9、`ssh_keys/set` 行數與格式;審查後補:偽造的 `dev:` 憑證被 TOFU 前提擋下、`type ≠ verb` 被拒、非擁有者金鑰被拒、`claim/replay` 回應、legacy(`state` = 3、reason 10)、`update/*` / `bulk/*` / `network/leave` / `diag/bundle` / `root_password/reset` 缺 owner-op 被 CDDL 拒絕。測試向量的 `device_id` 改為 `hex(sn)`。`gen.py` 與 `verify.py` 都以 RFC 8949 位元組序編碼(`det_dumps`;換掉 cbor2 長度優先後所有既有向量位元組不變)。第 2 輪補:參考節點規則 `node_accepts`(以信封 type 簽、`type ≠ verb` 向量 `request_type_mismatch` 必須被拒)、`STATUS` 三例(含成員洩漏末碼被拒)、帶秘密回應的請求帶冪等鍵被拒、`ssh-ed25519` 整行規則。**pycddl 0.6 的限制**:group choice 裡帶可選成員的替代項、以及 type choice(例如 `status-public = open / closed`)會誤收;封閉 map 本身會正確拒絕多出的 key。→ 冪等鍵規則(`idem_ok`)與 `STATUS` 規則(`status_ok`:末碼只在 0 / 3、key 只限 1–5)由 `verify.py` 以 Python 另驗,並對向量裡**所有**請求範例執行;規範 CDDL 照實寫。**節點與 app 的實作必須在程式碼裡檢查這兩條規則**,不能只靠 CDDL 驗證器。`deterministic()` 以 RFC 8949 位元組序比對(`{24:0, -1:0}` 正向 / 長度優先負向)。
- **尚未**:PR-H1 的 Go / Rust 驗證器直接以**規範** CDDL(不放寬)當第二份裁判;`flynn/noise`(Go)交叉驗證(PR-H1 / PR-P2,firmware 已有 Go 工具鏈;§12 Q8)、開發版(`-dev`)向量、608B 實機的 CheckMac 交叉驗證(B1)。

## 12. 待決

| # | 項目 |
|---|---|
| Q1 | Batman service UUID(自訂 128-bit,或申請 16-bit 以節省廣播空間,上位設計 B16) |
| Q2 | 診斷包分塊大小與 BLE 實際傳輸時間 |
| ~~Q3~~ | ~~Rust 工具鏈與 FFI~~ → **v0.7:節點用 Go**(§10),Rust 只在 app |
| Q4 | B1:`ECDHPROT`、IO protection key 存放(`OtherData` 已定案,§5.4) |
| ~~Q5~~ | 遠端加入流程 → **已決定 (a) 雙向傳圖片**(§7.6) |
| Q7 | QR 大小已實測(最大 1050 B,在 version 25-L 以內);**仍待實測**經 LINE / WhatsApp 壓縮後的掃描成功率 |
| Q8 | 608B 簽章耗時(§8 估 100 ms)與 `NXpsk0` 互通性,在 B1 / 測試向量時以 `flynn/noise` 交叉驗證 |
| Q6 | 同意圖片的大小與 QR 拆分方式(加密的密碼 + `member_secrets` + COSE 簽章,估計 1–2 KB) |

## 13. Review 紀錄

**v0.1 review(2026-10-06):安全 NEEDS-REWORK、可行性 APPROVE-WITH-CHANGES。** v0.2 的處理:

| 來源 | 問題 | 處理 |
|---|---|---|
| 安全 1 | 已認領模式沒有綁定節點身分,成員機台可冒充別台 | §3.3:手機一律比對預期的目標 DAC |
| 安全 2、可行性 1 | 608B CheckMac 不是 HMAC;階段 1 換階段 2 時線上格式會變 | §5.4 逐位元組對齊 CheckMac,階段 1 起就用 |
| 安全 3、可行性 2 | Encrypt0 不能接 ECDH-ES;密文不在網主簽章內;ECDH 公鑰未認證 | §7.3:COSE_Encrypt + ECDH-ES+HKDF-256、KDF context、密文包在 Sign1 內、`sig_ecdh` |
| 安全 4 | 成員 app 拿不到 `net_root`;匿名轉送與 PSK 模式矛盾;版本 PSK | §7.4 `member_secrets`;轉送限成員;節點只收目前版本 PSK、手機保留各版、廣播帶版本 |
| 安全 5 | 邀請流程自相矛盾;一次性有競態;SAS | §7.6 重新定義三種邀請;§5.5 SAS;Q5 交由使用者決定 |
| 安全 6 | 兩種物件共用標籤;沒有 prev_hash;網主金鑰組與分叉 | §3.6 各自標籤;§7.1 content type;§7.5 prev_hash、分叉處理;`admins` |
| 安全 7 | 手機在 XX 的靜態金鑰未定義 | 改用 `NX` / `NXpsk0`,手機沒有靜態金鑰 |
| 可行性 3 | Dart Noise 套件不可行 | §1、§10 刪除 |
| 可行性 4 | 編碼未定義 | DER 憑證鏈、raw r‖s、SEC1 未壓縮、固定長度 nonce / boot_id、u32BE、HKDF L=32、deterministic CBOR |

SHOULD-FIX 已併入:拒絕無 PSK 的交握、手機不依廣播選模式;PSK 失敗回等長假訊息並常數時間嘗試;`owner/remove` 輪替 `owner_tag_key`;角色表;`node_cert` 不過期 → 送封包前做新鮮挑戰;AEAD 失敗即中止、HTTP session id 與一次一個請求、請求也能分塊、中止只靠斷線;全域限速與 608B 限速;開發 / 正式隔離(prologue、標籤、app 不給開關);`psk_member` 共用的誠實界線;sans-IO 與簽章回呼;Rust vendoring;明文上限 65519;`AcquireNotify` 與 iOS 寫入長度。

**v0.3 review(2026-10-06,第二輪):安全 APPROVE-WITH-CHANGES、可行性 APPROVE-WITH-CHANGES。** 第一輪項目:安全 4 解決 / 3 部分,可行性 2 解決 / 2 部分。v0.4 的處理:

| 來源 | 問題 | 處理 |
|---|---|---|
| 安全 1 | SAS 只涵蓋 `invite_id` 與 DAC → 可替換申請裡的擁有者公鑰、或替換邀請 | §5.5 SAS 涵蓋完整邀請與申請;必須經另一條管道核對 |
| 安全 2 | 網主簽章依哪一版 `admins` 驗證不明 | §7.1 第 v+1 版以第 v 版驗證 |
| 安全 3 | 當面邀請自動同意 = 沒人比對 SAS;申請如何送達未定義 | §7.6 經 mesh → 網主節點 → BLE 送達;兩支手機顯示 SAS,網主按同意;重複申請告警 |
| 安全 4 | 假第 2 則訊息分辨得出 | §3.4 真臨時金鑰、假 DH、等到逾時才斷線 |
| 可行性 1 | 內容加密演算法未定 | §7.3 ChaCha20/Poly1305(alg 24),KDF context 寫明 |
| 可行性 2、安全(部分) | 雜湊輸入、prev_hash 未定義 | §7.1 SEC1 65 B;完整 tagged Sign1 |
| 可行性 3、安全(部分) | 擁有者金鑰兼做 ECDSA 與 ECDH;Android 11 以下沒有硬體 ECDH | §6 分出擁有者加密金鑰 + `sig_enc`;Android 11 以下用 keystore 包住的軟體金鑰 |
| 可行性 4 | CBOR 整數 key 未定義 | §5.6 原則與 CDDL 檔;**完整 key 表為定稿前的工作**;`OtherData` 現在定案 |

SHOULD-FIX 已併入:`sn` 比對 DAC;HTTP 冪等鍵;每位擁有者各自的 `owner_tag_key` 與輪替的 `adv_owner_key`;`member_secrets` 自己的標籤;分叉的確定性規則;落後節點的轉送內容;廣播不帶明文版本號;6 位數 SAS 的前提;`device_id` 放 info 最後;COSE tagged;Q7(QR 格式)、Q8(608B 耗時、NXpsk0 交叉驗證)。

**v0.5(2026-10-06)**:補齊 §5.6 的 CBOR 整數 key 表(`219-protocol.cddl`)與 §11 的測試向量(v0.5 時 92 項、v0.6 擴充為 119 項獨立驗證全部通過)。產生向量時發現並修正:`node_cert` 不再帶根憑證、同意圖片不再重複帶 `net_config`、content type 改短字串、內嵌 COSE 物件一律為巢狀項目(CDDL 驗證抓到與產生器不一致);新增 `batman-joinreq-v1` 標籤。三種 QR 都縮到 1273 B 以內。

**v0.5 一致性 review(2026-10-06):APPROVE-WITH-CHANGES。** v0.6 的處理:

| # | 問題 | 處理 |
|---|---|---|
| 1 | `prev_hash` / SAS 雜湊整個 Sign1,可被 n−s 與 unprotected 欄位改動 | §7.1 OBJECT_HASH(對 Sig_structure 取雜湊);強制 low-s 與空 unprotected;向量與負向測試 |
| 2 | SAS 規格寫「前 6 位」、程式是 mod 10^6 | §5.5 寫成明確公式 |
| 3 | content type 兩處不一致 | §7.1 改為 `batman/*` |
| 4 | 分塊在線上無法表達、與 `id` 去重衝突 | §5.1 與 CDDL:分塊的 `3` 為 bstr 片段,共用 `id`,以 `(id, n)` 去重 |
| 5 | GATT `seq` 範圍、`CTRL` 格式 | §4.1:每則訊息從 0 起算;CDDL `ctrl` |
| 6 | DAC 與 `sn` / `device_id` 的對應只在程式裡 | §3.3 寫明 CN 與 serialNumber |
| 7 | CDDL 的 request 不設防 | CDDL `whole-request` 以 group choice 綁定訊息類型與 body;body 加 `* uint => any`;簽章物件 `sign1<>` 帶型別、unprotected 為 `{}` |
| 8 | 規格內部矛盾(PSK 次數、`net_secrets` 帶法、`owner/add`、`OtherData`) | §3.4、§7.5、§5.3、§5.4、Q4 統一 |

SHOULD-FIX 已併入:`verify.py` 從標籤重組簽章輸入、以 pycose 交叉驗證 Sign1 與 KDF context、加入負向測試與版本鏈(v1→v2→v3,含換網主)向量、deterministic 編碼以位元組序檢查;第 1 則訊息 payload 為空;COSE_Encrypt 固定參數寫入內文;`member_secrets` 的 PartyV;網主金鑰逐一嘗試;邀請的 `admin_pub` 屬於 `admins`;加入申請內容回寫 §7.6;冪等鍵清單;base64url 不加 padding;回應的 body 與 error 互斥。
**驗證工具的已知限制**:pycddl 0.6 在陣列內的 `.cbor` 會誤判 / panic、type choice 會誤接受,`verify.py` 以寬鬆版 CDDL 驗外層、逐一驗內層與各選項替代。
**定稿前仍待**:`flynn/noise`(Go)交叉驗證、開發版(`-dev`)向量、608B 實機的 CheckMac 交叉驗證(B1)、Q1 / Q2 / Q3 / Q4 / Q6 / Q7 / Q8。

**v0.7(2026-10-19,#254 階段 1)**:把 `docs/design/254-stage1-impl.md` v19(兩位審查者核准)與本規格不同之處寫回:

| 項目 | 處理 |
|---|---|
| 擁有者角色足以改節點 → 被攻陷的協定行程可換擁有者 / 塞網路 | §5.7 owner-op(`batman-owner-op-v1`,`args_hash` 涵蓋整個 body);§5.3 列出需要它的請求;CDDL key 31 必填 |
| 第 1 版網路由誰記下 | §7.1:需要該節點擁有者的 owner-op `network/join` |
| `device_id` 沒有公式;開發根在公開 repo | §3.3 `device_id = hex(sn)`、file 後端 `sn = SHA-256(dac_pub)[:9]`、自簽 `dev:` 憑證;§9 app TOFU pin、正式版拒絕 |
| 認領回應遺失時擁有者拿不回金鑰 | §6 `psk_replay`(ECDH(owner_enc))、§3.4 固定試 6 次、§3.5 擁有者重取角色、§5.3 `claim/replay`;§5.4 app 先持久化 `node_cert` 與 claim-pending |
| `ClientChal` 由誰算 | §5.4 節點自己重算,不收外部值 |
| 恢復出廠 | 階段 1 不做(U8:轉賣 = 轉賣工具重燒卡);`reset` 回 `E_UNSUPPORTED` reason 9;`E_VERSION` 逃生口只剩 `info` / `status`;CDDL 移除 `reset-level` |
| 共用 Rust 函式庫 | §10 節點 Go、app Rust,向量與對手實作當裁判 |
| 新增訊息 | `op/nonce`、`claim/replay`、`ssh_keys/set`、`root_password/reset` |

**v0.7 第 1 輪審查(A:0 / 3 / 8;B:0 / 5 / 9,皆 REJECT 窄;`254-reviews/review-docs-v07-{A,B}.md`)**:verb 未綁 type(§5.7 改以信封 type 簽)、開發版 TOFU 可被同 CN 自簽憑證頂替(§3.3 MUST 前提 + 負向向量)、階段 1 用哪套 prologue / 標籤(§9:正式,隔離靠憑證)、HTTP 冪等快取跨 session 回傳秘密(§4.2 v0.7 規則)、`args_hash` 兩種定義(§5.7 原始 body;254 §4.1 同步)、沒有 legacy 狀態(`state` 3、NX、reason 10)、`update/*` / `bulk/*` 不帶 owner-op(改為必帶);MINOR:CDDL 孤兒行、`claim/begin` 角色與已存 `owner_pub`、app 持久化 K、沒有網路的 `network/update`、`ssh_keys/set` 格式、§8 上限、向量缺項;field-provisioning 殘留舊文字。

**v0.7 第 2 輪審查(A:REJECT 窄 0 / 1 / 8;B:APPROVE-WITH-CHANGES 0 / 0 / 8;`254-reviews/review-docs-v07-r2-{A,B}.md`)**:
`status/public` 沒有線上定義 → §4.1 `STATUS` 未加密 GATT 特徵值 + CDDL `status-public`(末碼只在 0 / 3);`type ≠ verb` 的檢查是恆真式 → `node_accepts` 參考規則 + 負向向量;
冪等:帶秘密回應的請求(含 `owner/add`、`bulk/open`)不得帶冪等鍵(CDDL `idem` 群組)、快取記 `(type, args_hash)`、舊清單刪除;`ssh-ed25519` 整行比對;
legacy `device_hint`、防呆門在 CheckMac 之後;開發 / 正式隔離句改寫、正式版 app 處處拒絕 `dev:`;`max_msg`(`CTRL` 4)統一分塊門檻與重組上限;
RFC 8949 位元組序編碼;254 §4.1 所有 owner-op 動詞收原始 body;項數更正。

**v0.7 第 3 輪審查(A:APPROVE-WITH-CHANGES 0 / 0 / 6;B 窄複查:APPROVE-WITH-CHANGES 0 / 0 / 4;`254-reviews/review-docs-v07-r3-A.md`、`-r3-B-delta.md`)**:
MINOR 已收:`deterministic()` 改位元組序(+ `{24:0,-1:0}` 正 / 負案例)、`idem_ok` 對所有請求範例執行、`request_reset_with_idem` 改為 `negative_reset_with_idem`、
`chunk` 只對 `idem-type` 允許 key 7(+ 分塊 `claim/finish` 負例)、分塊以整個信封 ≤ `max_msg − 16` 為準(+ `chunk_boundary` 向量)、`status_ok` 限定 key 1–5
(+ 多帶完整 `device_id` 的負例)、pycddl 限制的描述更正並寫明實作必須在程式碼裡檢查、§5.3 `ssh-ed25519` 整行規則與 `owner/add` 輪替語意。
