# Spec: 供裝協定 —— 安全通道與訊息協定(#219 B11 / #254)

Status: **DRAFT v0.5(補齊 CBOR 整數 key 表 `219-protocol.cddl` 與測試向量 `tests/vectors/219-protocol/`;待一輪一致性 review 後定稿)**
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
| CBOR(RFC 8949 deterministic encoding)、COSE(RFC 9052 / 9053) | 小、標準、ES256 與 ECDH-ES 對上 608B |
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
| 未認領 | `Noise_NX_25519_ChaChaPoly_SHA256` | 任何人 |
| 已認領 / 成員 | `Noise_NXpsk0_25519_ChaChaPoly_SHA256` | 只有持 PSK 的人(`psk_owner` 或目前版本的 `psk_member`) |

- 發起方 = 手機(只有臨時金鑰 `e`),回應方 = 節點(臨時 `e` + 靜態 `s_node`)。
- **已認領的節點一律拒絕沒有 PSK 的 `NX`**(防止降級)。
- **手機選模式**:對自己的機台,依手機本機紀錄的狀態選,**不依廣播旗標**(廣播未經認證);對未知機台才看廣播。

### 3.2 Prologue

```
prologue = "batman-prov/1" ‖ 0x00 ‖ transport ‖ 0x00 ‖ device_hint
transport   = "ble" | "http"
device_hint = 未認領:QR / 廣播上的 device_id(ASCII);已認領:空字串
```
**開發版**用 `"batman-prov-dev/1"`(§9),與正式版的交握永遠無法互通。

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
    7: sn (9 B, 608B 序號) }
  ```
- **手機的驗證**(全部通過才繼續):
  1. DAC 鏈驗到內建根(正式版只信正式根,§9);
  2. `sig_static` 對上 Noise 交握裡實際的 `s_node`;
  3. `sn` 與 DAC 憑證內的序號一致(`sn` 本身未被簽章);
  4. **DAC 等於預期的目標**:未認領 = 與 QR 的 `device_id` 一致;已認領 = 等於手機本機紀錄的那台 DAC,或封包 / 指令的目標 DAC。**只驗憑證鏈不夠**,否則任何持有 `psk_member` 的成員機台都能冒充別台【依 v0.1 review,MUST】。
- 608B 每次開機只簽兩次;`node_cert` 不過期 → 送出換密碼封包前,手機另做一次新鮮的 `peers/challenge`(§5.3)。
- 限制:拿到 root 的人能讀 `s_node`,在這次開機期間冒充節點;民用威脅模型已涵蓋。

### 3.4 PSK 模式的細節

- 已認領的節點收到第 1 則訊息時,以**常數時間**試 `psk_owner` 與目前版本的 `psk_member`(固定兩次解密,不論第一次是否成功)。
- **兩把都失敗**:用**真的新臨時金鑰**組出一則格式正確的第 2 則訊息(payload 為等長隨機資料),並做與真交握相同次數的 DH;送出後**和真 session 一樣等到逾時才斷線**。隨機 32 B 不是合法的 X25519 公鑰格式(最高位元)、假訊息不做 DH、送完立刻斷線,三者都能被分辨【依第二輪 review,MUST】。
- 節點**只接受自己目前版本的 `psk_member`**,不接受舊版(否則被移除的成員還能連進來)。還沒更新的節點仍在舊版本,手機用**當時那一版**的 `psk_member` 連它 → 成員 app 保留各版 `psk_member`,依序試最近幾版(由新到舊,受 §8 全域限速)。**廣播不帶明文版本號**(會把同網節點串在一起、跨 RPA 關聯)【依第二輪 review】。

### 3.5 交握完成後:角色

Noise 完成後雙方取得交握雜湊 `h`(32 B)。session 的角色:

| 角色 | 條件 | 允許的訊息 |
|---|---|---|
| 匿名 | 未認領機台上的 `NX` 交握 | `info`、`claim/*` |
| 擁有者候選 | 用 `psk_owner` 完成交握 | 只有 `info`、`auth/owner` |
| 擁有者 | `auth/owner` 驗證通過;或在本 session 內 `claim/finish` 成功 | 擁有者的全部訊息 |
| 成員 | 用 `psk_member` 完成交握 | `status`(狀態部分)、`peers/challenge`、`network/update`(轉送) |

- `auth/owner`:`sig = ES256_owner( "batman-owner-auth-v1" ‖ h ‖ owner_key_id )`;節點比對 p5 裡的擁有者公鑰。
- 角色只會從「匿名 / 擁有者候選」升到「擁有者」,不會降;要換角色就重新交握。

### 3.6 用途標籤

每種用途一個標籤;被簽 / 被 MAC 的內容一律以標籤開頭,且包含節點自己產生的 nonce 或 `h`。**節點絕不直接簽對方提供的值。**

| 標籤 | 用途 | 金鑰 |
|---|---|---|
| `batman-node-static-v1` | `s_node` 證明 | DAC |
| `batman-node-ecdh-v1` | ECDH 公鑰證明 | DAC |
| `batman-peer-v1` | `peers/challenge` | DAC |
| `batman-owner-auth-v1` | 擁有者 session 認證 | 擁有者 |
| `batman-claim-v1` | 認領挑戰(CheckMac 的 ClientChal,§5.4) | 認領秘密 |
| `batman-netcfg-v1` | `net_config`(COSE) | 網主 |
| `batman-members-v1` | `member_list`(COSE) | 網主 |
| `batman-secrets-v1` | `net_secrets`(COSE) | 網主 |
| `batman-msecrets-v1` | `member_secrets`(COSE) | 網主 |
| `batman-owner-enc-v1` | 擁有者加密公鑰證明 | 擁有者 |
| `batman-invite-v1` | `invite`(COSE) | 網主 |
| `batman-joinreq-v1` | 加入申請(COSE) | 加入者的擁有者簽章金鑰 |
| `batman-sas-v1` | 確認碼 | — |

開發版的標籤一律加 `-dev` 後綴(§9)。

### 3.7 傳輸階段

- Noise 傳輸的 nonce 是 64 位元計數器,兩個方向各一把金鑰(`Split()`)。
- **任何一次 AEAD 失敗即中止連線**,不嘗試恢復。
- Noise 訊息最大 65535 B,扣掉 16 B tag,每則明文最多 65519 B。
- 重新交握:節點重開機、連線中斷、或累計 2^20 則訊息。

## 4. 分段與傳輸

### 4.1 BLE GATT

- 服務:Batman service UUID(128-bit,§12 Q1)。
- 特徵值:`RX`(手機 → 節點,Write Without Response)、`TX`(節點 → 手機,Notify)、`CTRL`(Read,只回 `{proto_major, proto_minor, max_frame}`,不加密)。
- 框架:

  | 欄位 | 大小 | 說明 |
  |---|---|---|
  | flags | 1 B | bit0 = 開頭、bit1 = 結尾 |
  | seq | 2 B(大端) | 該方向的框架序號,遞增、溢位歸零 |
  | data | ≤ 框架上限 − 3 | 一則 Noise 訊息的片段 |

- 框架上限:手機端以 iOS `maximumWriteValueLength(.withoutResponse)` / Android 協商後的 MTU − 3 為準。
- 重組:收到「結尾」才交給 Noise;序號不連續、或累計長度超過 65535 → 中止連線。
- **中止**一律由「斷開 BLE 連線」表示,不設未經認證的中止旗標【依 v0.1 review】。
- 流量控制:手機等 `peripheralIsReady` / 寫入回呼;節點端用 BlueZ 的 `AcquireNotify` socket,佇列滿時暫停(D-Bus 的 notify 沒有回壓)【依 review】。

### 4.2 HTTP(備援:大量傳輸通道、開發)

- `POST /batman/v1/session`:body = 交握訊息;回應 = 交握訊息 + header `X-Batman-Session`(128-bit 隨機,base64url)。
- `POST /batman/v1/msg`:body = 一則 Noise 傳輸訊息;**每個 session 一次只能有一個未完成的請求**;回應遺失時,手機**以同一個冪等鍵**重送:每個會改變狀態的請求帶 `7: idem_key`(16 B 隨機),節點保留最近 32 個冪等鍵與其結果 10 分鐘,跨 session 有效,重複的請求直接回傳上次的結果,不重複執行(例如 `owner/remove` 不會輪替兩次)【依第二輪 review】。
- HTTP 裡一律跑完整的 §3,不依賴 TLS。

## 5. 應用訊息

### 5.1 信封(CBOR,deterministic encoding)

請求:`{ 0: proto_ver [major, minor], 1: id (uint), 2: type (tstr), 3: body (map), 6: part? }`
回應:`{ 1: id, 4: status (uint, 0 = ok), 3: body / 5: error, 6: part? }`

- `id`:手機產生,單一 session 內遞增;節點拒絕重複或倒退的 `id`。
- **分塊**(請求與回應都可以):超過 65519 B 的訊息拆成多則,`6: { n: 第幾塊, total: 總塊數 }`,每塊各自加密;收齊才處理,總大小上限 1 MB。
- 版本:`major` 不同 → `E_VERSION`,手機只允許 `info`、`status`、`reset`;未知 `type` → `E_UNKNOWN_TYPE`;**body 的未知欄位忽略**(簽章物件除外,§7)。

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
| `info` | 全部 | — | `device_id`、`model`、`board`、`fw_version`、`proto_ver`、`capabilities[]`、`state`、`claim_window`、`net_version`(成員以上才有) |
| `claim/begin` | 匿名 | `owner_pub`(65 B) | `nonce`(32 B) |
| `claim/finish` | 匿名 | `response`(32 B,§5.4)、`owner_enc_pub` + `sig_enc`(§6) | `owner_tag_key`(32 B,**每位擁有者各一把**)、`adv_owner_key`、`root_password`;session 升為擁有者 |
| `auth/owner` | 擁有者候選 | `owner_key_id`(32 B = SHA-256(owner_pub 65 B))、`sig` | 目前的 `adv_owner_key` |
| `owner/add` | 擁有者 | `owner_pub` | — |
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
| `reset` | 擁有者 | `level`(leave / factory;`zeroize` 民用回 `E_UNSUPPORTED`) | — |

### 5.4 認領挑戰(對齊 608B CheckMac)

608B 的 `CheckMac` 不是 HMAC。mode 0 的運算是【事實,依 review 查證 Microchip 文件與 cryptoauthlib `atcah_check_mac`】:

```
response = SHA-256( K(32) ‖ ClientChal(32) ‖ OtherData[0:4] ‖ 0x00×8 ‖ OtherData[4:7]
                    ‖ SN[8] ‖ OtherData[7:11] ‖ SN[0:2] ‖ OtherData[11:13] )      ; 共 88 B
```

本協定的定義:
- `K` = 認領秘密(QR 上的 32 B)。
- `ClientChal` = `SHA-256( "batman-claim-v1" ‖ nonce ‖ h ‖ SHA-256(DAC 憑證 DER) ‖ owner_pub )`。
- `OtherData` = 固定 13 B 常數(實際值在 B1 槽位實驗時定案,寫入規格與測試向量)。
- `SN` = `node_cert` 裡的 608B 序號(不是秘密)。
- **階段 1 起就用這個格式**(軟體計算同樣的 SHA-256),階段 2 換成 608B 時線上格式不變【依 review,MUST】。

### 5.5 確認碼(SAS)

```
sas = 前 6 位十進位數字( SHA-256( "batman-sas-v1" ‖ SHA-256(完整邀請物件) ‖ SHA-256(完整申請物件) ) )
```
- 涵蓋**整個邀請**(`net_id`、`admins`、`invite_id`)與**整個申請**(加入者 DAC、`ecdh_pub`、擁有者公鑰、`owner_enc_pub`)。只涵蓋 `invite_id` 與 DAC 時,攻擊者可以**替換申請圖片裡的擁有者公鑰**(把 `member_secrets` 騙到自己手上),或**替換邀請圖片**(讓加入者加入攻擊者的網路),SAS 卻仍一致【依第二輪 review,MUST】。
- **SAS 必須經另一條管道核對**:當面看兩支手機,或打電話;不能用傳圖片的同一個聊天。
- 6 位數的強度可接受,前提是攻擊者無法大量取得合法 DAC(DAC 只能由 608B 產生、經出廠簽發)。

### 5.6 CBOR 整數 key 表

**完整定義在 `docs/design/219-protocol.cddl`(CDDL,RFC 8610)**:每個訊息 body、`node_cert`、所有 COSE payload、QR 物件都有整數 key、型別、是否必填。原則:
- 0–15 保留給信封;各訊息 body 從 1 起編;新增欄位只能用新的 key,不重用。
- 訊息 body 的未知 key 忽略;**簽章物件的未知 key 拒絕**。
- 內嵌的 COSE 物件一律以**巢狀 CBOR 項目**(tagged 18 / 96)內嵌,不包成 bstr。
- `OtherData`(§5.4)= `08 00 00 00 00 00 00 00 00 00 00 00 00`(mode 0,其餘為零)。
- content type 用短字串:`batman/netcfg`、`batman/members`、`batman/secrets`、`batman/msecrets`、`batman/invite`、`batman/joinreq`。

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

- `device_id` 一律以 ASCII 編碼、放在 info 的最後一欄(長度不固定)。
- 節點以常數時間試所有擁有者的 `psk_owner` 與目前的 `psk_member`(擁有者數量上限 4)。
```

**誠實界線**:`psk_member` 是全網共用的。任何一台成員節點的 SD 卡或任何一支成員手機外流,就等於拿到全網的成員權限,而且無法單獨撤銷某一個人,只能換密碼(`net_version` +1)。這是民用版「共用密碼」模型的固有限制(上位設計 P6)【依 review】。

## 7. 簽章物件(COSE)

### 7.1 通則

- 一律 `COSE_Sign1`,演算法 ES256,簽章值 raw r‖s(64 B)。手機 keystore 輸出的 DER 簽章要轉換。
- protected header 帶 `content type` = 物件種類(`application/batman-netcfg+cbor` 等),`external_aad` = 該物件的標籤(§3.6)→ 物件之間不會混用【依 review】。
- payload 一律 deterministic CBOR;**簽章物件的未知欄位不忽略:拒絕**。
- **第 v+1 版的簽章,一律以第 v 版 `net_config` 的 `admins` 驗證**;物件自己那一版的 `admins` 只對下一版生效。第 1 版由建立者自簽,手機與節點記下 `net_id` 與建立者公鑰【依第二輪 review,MUST:否則任何人都能發一版把自己列為網主】。
- COSE 一律用 **tagged** 形式(`COSE_Sign1` tag 18、`COSE_Encrypt` tag 96);content type 用 tstr。
- **雜湊的輸入**:`dac_pub_hash`、`target_dac_hash`、SAS 中的公鑰一律為 `SHA-256(SEC1 未壓縮 65 B 公鑰)`;`prev_hash` = 上一版**完整 tagged COSE_Sign1 編碼**的 SHA-256。

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
```
- **密文在網主簽章的 payload 裡面**,所以轉送的人換不掉密碼欄位(ECDH-ES 的發送方是匿名的)【依 review,MUST】。
- 每台節點一份;網主加密前一律驗 `sig_ecdh`。
- 608B 這端:ECDH 指令可以輸出共享秘密給主機(或以 IO protection key 加密輸出),主機再做 HKDF【事實,依 review 查證】;`ECDHPROT` 與 IO protection key 的存放在 B1 決定。

### 7.4 `member_secrets`(給成員 app 的秘密)
與 §7.3 相同結構,標籤 `batman-msecrets-v1`,對象是**成員的擁有者加密金鑰** `owner_enc_pub`(須先驗 `sig_enc`);plaintext = `{ net_root }`(成員 app 用來導出 `psk_member`、`adv_member`)。網主同意加入時、以及每次換密碼時,發給每位成員的 app【依 review,MUST:原設計成員 app 拿不到 `net_root`】。

### 7.5 `member_list` 與版本鏈
```
member_list = { net_id, net_version, prev_hash,
                members: [ { dac_pub_hash, ecdh_pub, name, owner_pub, lora_pkc_pub? } ],
                removed: [ dac_pub_hash ],
                used_invites: [ invite_id ], revoked_invites: [ invite_id ] }
```
- `network/update` 帶從節點目前版本 `v` 到最新的每一版(`net_config`、`member_list`、該節點的 `net_secrets`),每版的 `prev_hash` 要等於上一版的雜湊;**不接受跳號**。
- **分叉**(同一版本出現兩個不同的物件,例如兩位網主同時修改):以**雜湊值較小者**為準(確定性規則);已套用另一支的節點在看到勝出的鏈時切換;下一版的 `prev_hash` 一律指向勝出者;app 告警網主。民用版接受「共同網主可以故意製造分叉干擾」這個限制。
- **轉送給落後的節點**:落後節點需要的是從它的版本到最新版的公開物件鏈(`net_config`、`member_list`),加上**最新一版**它自己的 `net_secrets`;網主 app 把各成員節點最新的 `net_secrets`(已對各節點加密,轉送無害)同步給所有成員 app。

### 7.6 邀請
| 種類 | 內容 | 秘密如何送達 | 「一次性」怎麼保證 |
|---|---|---|---|
| **當面**(QR 只顯示在網主螢幕) | `{ net_id, invite_id, kind: in_person, net_config(公開), sae_password, admin_pub }` | **QR 內含 SAE 密碼**(等同當面告訴對方密碼),加入者的節點先入網,經 mesh 把**申請**送到網主的節點,網主節點再經 BLE 交給網主 app | **兩支手機同時顯示 SAS,網主核對後按一下同意**(不自動同意);同一個 `invite_id` 出現第二個申請時告警並拒絕【依第二輪 review,MUST:自動同意等於沒人比對 SAS,拍到 QR 的人可搶先】 |
| **遠端**(QR 圖片) | `{ net_id, invite_id, kind: remote, net_config(公開), admin_pub }`,**不含秘密** | 加入者 app 產生一張**加入申請圖片**(加入者的 DAC 憑證、`ecdh_pub` + `sig_ecdh`、擁有者公鑰、`invite_id`),經同一個聊天管道傳回網主;網主核對 SAS 後同意,回傳一張**同意圖片**(該節點的 `net_secrets` + 成員 app 的 `member_secrets`) | 網主只對自己發出、尚未使用的 `invite_id` 同意 |
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

## 9. 開發版與正式版的隔離

| 項目 | 正式版 | 開發版(階段 1) |
|---|---|---|
| DAC | 608B 內,正式根簽發 | P-256 私鑰在 SD 卡檔案,**開發根**簽發 |
| 認領秘密 | 608B(CheckMac) | 檔案,軟體算同樣的 §5.4 格式 |
| ECDH 金鑰 | 608B | 檔案 |
| prologue | `batman-prov/1` | `batman-prov-dev/1` |
| 標籤 | 如 §3.6 | 一律加 `-dev` |
| app | 只內建正式根,**拒絕開發根,沒有切換開關** | 只內建開發根 |

協定、訊息、物件結構完全相同;兩邊永遠無法互通,開發機不會混入正式網路【依 review】。

## 10. 實作

- **共用 Rust 函式庫 `batman-proto`**:Noise(`snow`)、CBOR、COSE、框架與重組、訊息型別。
  - **sans-IO**:不自己做 I/O;**簽章與 ECDH 由外部回呼提供**(手機的 Secure Enclave / Keystore、節點的 608B 都不在 Rust 裡)。流程是「函式庫交出要簽的內容 → 平台簽 → 交回」【依 review】。
  - 節點:`batman-provd`(Rust)經 FFI 呼叫 cryptoauthlib。
  - 手機:Flutter + `flutter_rust_bridge` v2。
- **Rust 工具鏈**:OpenWrt packages feed 有 `lang/rust`(`rust-package.mk`)【事實】;本 repo 目前沒有 Rust 或 Go 套件。host 端要從原始碼建 rustc(很重);cargo 會在 build 時抓 crate → **必須 vendoring**,否則會重演 #252 的不可重現問題。二進位大小估計 1–3 MB,要在 B15 實測。
- 替代:節點用 Go(`flynn/noise`)。**Dart 版 Noise 不可行**(見 §1)。

## 11. 測試向量

**已完成**:`tests/vectors/219-protocol/`(`vectors.json`、`gen.py`、`verify.py`、`README.md`)。
- `gen.py` 以固定金鑰與決定性 ECDSA(RFC 6979)產生,**可逐位元組重現**。
- `verify.py` 以**另一份實作**逐項驗證,共 92 項:Noise 用 `dissononce` 重跑 `NX` 與 `NXpsk0` 交握(位元組必須與 `noiseprotocol` 產生的完全相同)、ECDSA / ECDH 用 `python-ecdsa`、HKDF 用標準庫 `hmac`、所有物件以 `pycddl` 對 CDDL 驗證結構。
- 涵蓋:測試根憑證與 DAC、`node_cert`、HKDF、兩種 Noise 交握、`auth/owner`、認領 CheckMac(88 B)、`sig_enc`、`peers/challenge`、全部 COSE 物件(含 ECDH 共享秘密、KDF context、CEK)、SAS、QR 大小、GATT 框架、CBOR 信封。
- **尚未**:`flynn/noise`(Go)交叉驗證(這台開發機沒有 Go;§12 Q8)、開發版(`-dev`)向量、608B 實機的 CheckMac 交叉驗證(B1)。

## 12. 待決

| # | 項目 |
|---|---|
| Q1 | Batman service UUID(自訂 128-bit,或申請 16-bit 以節省廣播空間,上位設計 B16) |
| Q2 | 診斷包分塊大小與 BLE 實際傳輸時間 |
| Q3 | Rust 工具鏈、vendoring 與 FFI 可行性(§10,併入 B15) |
| Q4 | B1:`OtherData` 常數、`ECDHPROT`、IO protection key 存放 |
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

**v0.5(2026-10-06)**:補齊 §5.6 的 CBOR 整數 key 表(`219-protocol.cddl`)與 §11 的測試向量(92 項獨立驗證全部通過)。產生向量時發現並修正:`node_cert` 不再帶根憑證、同意圖片不再重複帶 `net_config`、content type 改短字串、內嵌 COSE 物件一律為巢狀項目(CDDL 驗證抓到與產生器不一致);新增 `batman-joinreq-v1` 標籤。三種 QR 都縮到 1273 B 以內。
