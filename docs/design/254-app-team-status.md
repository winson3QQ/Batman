# #254 app S4 — 全隊狀態（設計 v1，審查中）

**v1（2026-11-13）審查中。** 範圍：S4「看狀態」的**全隊**那一半（219-field-provisioning.md:128、:165）。節點與 app 都要改；本文件不含程式碼。
來源：使用者決定（2026-11-13，綁定）+ 本文 §1 事實。順序：**本設計審過 → 在 04 + 02 組成的 mesh 上擷取真實輸出（§9）→ 依擷取寫完 parser → 上機測試（§10.3）**。§9 的 ⚠️ 項目沒擷取前，parser 不寫死任何格式。

## 0. 決定（使用者 2026-11-13，綁定）與本文的取捨

| # | 決定 |
|---|---|
| U1 | **成員**（不只網主）看得到每位隊員的：在線與否、「N 分鐘前看到」、訊號 / 連線品質 |
| U2 | 「最後看到」存在 **RAM**（節點重開就歸零），不寫 flash |
| U3 | 卡片 = 名稱 + 在線狀態 + 多久前看到 + 訊號 / 連線品質；**電量、軟體版本這版不做** |
| U4 | 沿用現有畫面（UI/UX 重做 #329 延後）；只做必要的修改；能拿掉機制就拿掉 |

本文的取捨（技術細節由我定，理由在各節）：

| # | 取捨 |
|---|---|
| T1 | **不做節點對節點查詢、不開新的 mesh 埠**：手機自己的節點在既有 `status`（scope 0）回答裡附上「它在 mesh 上看到的節點」清單；app 自己對成員名單。協定原本的 `scope = team`（節點經 mesh 去問別台，219-protocol.md:215、cddl :248-250、:258）不實作，`status` key 7 / `team-entry` 退役：節點不知道成員名單（node.go:1167），產不出 key 7 要的 `dac_pub_hash` / 名稱；CDDL 規定 key 不重用（cddl :7-8），所以用新 key |
| T2 | 位址 → 成員的對應**只放在網主簽章的成員名單**（新的選填欄位）；**不做**節點 DAC 簽的「我的 mesh 位址」聲明，也就沒有新的簽章標籤（理由 §5.3） |
| T3 | 「最後看到」表放在 helper 的**行程記憶體**（不是 tmpfs 檔案）：一個擁有者、沒有檔案契約、沒有路徑可被攻擊；helper 重啟也歸零（少見，等同重開）。若使用者要「helper 重啟不歸零」，才改成 `/var/run` 下 root-only 檔（§12 Q3） |
| T4 | 取樣在背景**一直跑**（每 15 s），不只在「有人問的 10 分鐘」內（status.go:116-120 的做法）：否則「2 小時前看到」根本記不到 — batman 約 200 s 就把離開的節點刪掉（254-app-status-page.md:15 F4） |
| T5 | 全隊資料放在 scope 0 的回答裡（新 key），不另開一次 scope 1 請求：provd 的 status 額度是每連線 1 次 / 秒（session.go:867-875，scope 1 若實作也走同一個 `statusAt`），兩次請求會互撞 E_RATE；一次回答也讓「新節點 / 舊節點」只靠 key 在不在就分得出來 |

## 1. 事實

設計文件：

| # | 事實 | 證據 |
|---|---|---|
| F1 | S4 原設計：「附近」BLE 直接看、「全隊」經 mesh 查詢、每台顯示最後看到時間；首頁卡片含電量（U3 拿掉） | 219-field-provisioning.md:128、:165 |
| F2 | `GET /v1/status` 原設計：全隊經 mesh 查詢；擁有者 / 同網成員可讀 | 219-field-provisioning.md:312；219-protocol.md:215 |
| F3 | 原設計的成員偵測（§6.6）：對 mesh 鄰居表每個鄰居發 `peers/challenge` 要 DAC 簽章；**誠實界線：只擋不小心的人**（偽造 MAC 又拒答的人和斷線的機台分不出） | 219-field-provisioning.md:408-412 |
| F4 | 診斷包裡的鄰居 MAC、IP 視為「包含裝置名稱與位址」，分享前提示 | 219-field-provisioning.md:477 |
| F5 | CDDL：`status-req` scope 0 self / 1 team；`status-resp` key 7 = `[* team-entry]`；`team-entry` = {1 dac_pub_hash, 2 name, 3 verdict, 4 seen-ago 秒, ?5 battery} | 219-protocol.cddl:248-250、:258、:282-288 |
| F6 | CDDL 規則：同一個 key 不重用為別的意思；新選填欄位用新 key；回應本體的未知 key 忽略；**簽章物件裡的未知 key 拒收** | 219-protocol.cddl:7-11 |
| F7 | `member` = {1 dac_pub_hash, 2 ecdh_pub, 3 名稱, 4 owner_pub, 5 owner_enc_pub, ?6 lora_pkc_pub} — 沒有 MAC / IP；`join-request` = {1..6}（key 2 = 節點 cert，由加入者的 app 從自己的節點經 BLE 取） | 219-protocol.cddl:403-410、:444-451 |
| F8 | P3 決定 D7：`status` 只做 self；team 進 checklist；`scope = 1` → `E_UNSUPPORTED{1: typ, 2: 7}` | 254-p3-impl.md:23、:44、:272、:776 |
| F9 | 狀態頁 v8.1 凍結：只讀 `status` / `info`、節點零改動；節點給的字串一律 `display_name` + 截 64 字 | 254-app-status-page.md:5、:33 |
| F10 | batman 約 200 s 才移除鄰居；802.11s plink 不逾時，已離開的站台可能一直在 station dump 裡 | 254-app-status-page.md:15（F4） |
| F11 | provd 的 8095 在 IP 層只收手機 AP port 進來的封包，mesh `bat0` / `wlh0` 來的都丟 → **節點之間不能互叫 provd** | 254-p3-impl.md:464-465 |
| F12 | 階段 1 只限內部開發、不可出貨 | 219-field-provisioning.md:559 |

節點原始碼（feat/254-claim-noover 6c721e4，`feed/batman-prov/src/`）：

| # | 事實 | 證據 |
|---|---|---|
| F13 | `status` scope 1 → `E_UNSUPPORTED{1: "status", 2: 7}` | provd/session.go:862-863 |
| F14 | 成員角色（`RoleMember`）允許的動詞：info、network/update、status；擁有者有 `ssh_keys/set`、`root_password/reset` | provd/session.go:79-82 |
| F15 | provd 轉送 helper 回答的所有整數 key，只擋非擁有者的 key 15；**其他 key（含未來的 8、9）provd 不擋** → 誰拿得到什麼由 helper 決定 | provd/session.go:890-896 |
| F16 | `peers/challenge`、`diag/*`、`owner/*` 仍是 p3Types（回 E_UNSUPPORTED）；沒有任何逐台查詢的動詞 | provd/session.go:68-69、:644-646 |
| F17 | helper `status.get`：`halow-status json` 快取，「有人問過的 10 分鐘內」每 15 s 刷新，超過 30 s 算過期；請求路徑不跑子行程；成員角色只拿 key 1–5（過期時只有 key 1） | node/status.go:3-12、:21-31、:116-120、:182-188 |
| F18 | `halow-status`：`join.peers` = `/tmp/bat-hosts` 裡 `_wlh0` 結尾的主機名；`snr_db` = station dump 裡**最強那一台**；batctl 只拿來計數 | feed/batman-provision/files/usr/bin/halow-status:37-41、:164 |
| F19 | 節點不存也不讀成員名單（network/update 只做簽章與版本一致性檢查） | node/node.go:1167-1178 |
| F20 | 單一訊息上限 8192 B（節點 `MaxMsg`、app `MAX_MESSAGE`） | provd/frame.go:15；app/rust/batman-proto/src/conn.rs:11-12 |
| F21 | 既有簽章標籤 11 個（含 `batman-peer-v1`、`batman-members-v1`） | proto/proto.go:21-33 |
| F22 | device_id = hex(SHA-256(cert pub)[:9])（file backend）— 和任何 mesh MAC 無關 | keystore/keystore.go:147 |
| F23 | provd = uid 471 + ujail；helper = root | 254-p3-impl.md:136-138 |

App 原始碼（`app/rust/`）：

| # | 事實 | 證據 |
|---|---|---|
| F24 | 網主手機 `net/` key 11 與成員手機 `mnet/` key 4 都有**完整**成員名單；key 11 每項 keys 1–5 = members v1 的 keys，另有 6、8、9、10（**7 沒用過**） | batman-proto/src/netrec.rs:1-16；mrec.rs:6-12 |
| F25 | **舊 app 拒收成員項目裡的未知 key**：`exact_keys(m, &[1..5], &[6])`（核准時與匯入更新時兩處）；加入申請 `exact_keys(p, &[1..6], &[])` | approve.rs:52、:311；mupdate.rs:133；cose.rs:333-339 |
| F26 | app 自訂成員上限 16 | netrec.rs:27 |
| F27 | 狀態頁用 `Answer::Body(&Value)` 依 key 取值（推論：未知 key 不影響判定 — **⚠️ 以 T-A4 測試證明**，不是只看程式） | bridge/src/api/owner.rs:2026-2032；batman-proto/src/statuspage.rs:105 |

04 實機唯讀探針（2026-11-13，04 = 10.41.84.148，已被手機認領、**不在 mesh**）：

| # | 事實 |
|---|---|
| F28 | batctl 2024.3；`batctl o`、`batctl n`、`batctl if` 都是空的 |
| F29 | bat0 MAC `be:5e:79:bb:31:38` 是隨機的，和裝置 MAC `88:a2:9e:b5:6c:89` 無關 |
| F30 | `/tmp/bat-hosts` 由 alfred-bat-hosts 每 5 分鐘產生、**未簽章**，例：`# Node 88:a2:9e:b5:6c:89`、`be:5e:79:bb:31:38 BCM2711-6c89_bat0` |

**還沒擷取（02 缺網路線）**：兩台組成 mesh 時 `batctl o` / `batctl n` 的真實輸出、originator 是哪個 MAC（primary hard-if 的 `wlh0` 還是 `bat0`）、TQ / last-seen 欄位、每台站台的 signal — 全部列在 §9，**實作前一定要擷取**。

## 2. 設計概要

```
隊員節點 B ─(batman OGM,已有)─┐
隊員節點 C ─(batman OGM,已有)─┤
                              ▼
自己的節點 A: helper 每 15 s 讀 batman originator 表 + wlh0 station dump
              → RAM 表 {mesh 位址 → 最後看到、TQ、直接連線時的 signal}
              → status(scope 0)回答多兩個 key:8 = 自己的 mesh 位址、9 = 看到的節點清單
                              │ BLE(既有 session,擁有者或成員角色)
                              ▼
手機:key 9 的位址 對 成員名單 member key 7(網主簽章)→ 名稱
      對到 → 「『客廳』 在線 · 訊號 好」;對不到 → 「不明節點」;名單沒有位址 → 「未確認身分」
```

沒有新的動詞、沒有新的埠、沒有節點對節點的流量、節點不讀成員名單（F19 不變）。

## 3. 擁有權（每個資源只有一個寫入者）

| 資源 | 唯一寫入者 | 唯讀者 | 備註 |
|---|---|---|---|
| RAM「看到的節點」表 | helper 的取樣 goroutine | helper `status.get`（取鎖讀快照） | 行程記憶體；helper 重啟 / 節點重開 = 歸零（U2、T3） |
| `status` key 8 / key 9 的內容 | helper `status.get` | provd（轉送，F15）、app | 角色篩選在 helper（key 8 只給擁有者，key 9 給擁有者與成員）；provd 加一行防線：非擁有者丟 key 8（和 key 15 同一處） |
| 成員名單 `member` key 7（mesh 位址） | 網主 app（簽 members Sign1 時） | 成員 app（`mnet/` key 4）、網主 app（`net/` key 11） | 節點不讀（F19） |
| `net/` key 11 項目的 key 7 | 網主 app | 網主 app | 來源：網主是擁有者時自己讀節點 key 8；否則來自加入申請 key 7 |
| `join-request` key 7 | 加入者的 app（擁有者金鑰簽） | 網主 app（核准時） | 來源：加入者 app 從自己的節點讀 key 8 |
| batman originator 表、wlh0 station 表 | kernel（batman-adv、mac80211 / morse） | helper 取樣（`batctl`、`iw`，固定參數） | 我們不寫 |

## 4. 介面契約

### 4.1 `status` 回答新 key（CDDL 增補）

```
bytes6 = bstr .size 6
status-resp = {
  ...                        ; 1-6, 15 unchanged
  ? 7 => [* team-entry],     ; RETIRED (254-app-team-status T1): never sent; the key is not reused
  ? 8 => bytes6,             ; this node's own mesh address (batman originator address). Owner role only.
  ? 9 => [* peer-entry],     ; mesh nodes this node has seen since its helper started; at most 32 entries.
                             ; Present only when the last peer sample succeeded within 60 s; absent = unknown.
  ...
}
peer-entry = {
  1 => bytes6,               ; the peer's mesh address (originator address, as batman reports it)
  2 => uint,                 ; seconds since this node last saw it (monotonic clock; no wall time on the node)
  ? 3 => uint .le 255,       ; batman TQ toward it, from the last sample in which it was present
  ? 4 => int,                ; signal avg (dBm), only when it is a direct 802.11s station active in the last sample
  * uint => any,             ; unknown keys ignored (§5.1)
}
```

| 項目 | 契約 |
|---|---|
| 寫入 / 讀取 | helper 寫 → provd 轉送 → app 讀 |
| key 8 來源 | primary hard-if 的 MAC（⚠️ C2–C4：是不是 `wlh0`、radio 被 keyguard 關掉時讀不讀得到、重開 / sysupgrade 後會不會變）。讀不到 → **不送 key 8**（不猜） |
| key 9 有效條件 | 最近一次成功取樣 ≤ 60 s；否則整個 key 9 不送（fail-closed：舊資料不當成現在的，同 status.go:182-188 的做法）。節點不在 mesh（`bat0` 不存在）且取樣本身沒錯 → `[]`（⚠️ C7） |
| 「看到」的定義 | 某次取樣時它在 originator 表裡 → 最後看到 = 取樣時間 − batman 回報的 last-seen（⚠️ C1：欄位與單位）；表裡留著直到被擠出（上限） |
| 自己 | key 9 不含自己的位址 |
| 上限 | 表最多 32 筆（名單上限 16 的兩倍，留給不明節點）；滿了丟「最後看到」最舊的那筆。每筆編碼約 ≤ 22 B → key 9 ≤ 32 × 22 + 3 ≈ 707 B。加上現有最大的 key 15 必須 ≤ 8192 B（F20）→ T-N4 以最大值實測編碼長度 |
| 缺 / 壞（app 端） | key 9 不在 → 全隊區顯示「看不到全隊狀態」那一句（§6）；key 9 在但型別錯、筆數 > 32、位址不是 6 B、key 2 不是 uint → **整個 key 9 當作壞的**，全隊區顯示同一句、**狀態頁其他部分照常**（新欄位不能弄壞已凍結的狀態頁）；只有 key 3 > 255 或 key 4 不是 int → 只丟那一欄 |
| 誰能寫 | 只有節點 helper（root）。但表裡的位址與數值來自 mesh 上**任何有 mesh 金鑰的人**送的 OGM（§7） |

### 4.2 成員名單 `member` key 7、`net/` key 11 的 key 7、`join-request` key 7

```
member = {
  1..5 unchanged, ? 6 => x25519-pub,
  ? 7 => bytes6,             ; the node's mesh address (254-app-team-status §4.2), read from the node itself over BLE
}
join-request = {
  1..6 unchanged,
  ? 7 => bytes6,             ; the joining node's mesh address, read by the joining owner's app from its own node
}
```

| 項目 | 契約 |
|---|---|
| 寫入 | 網主 app 簽名單時填。來源只有兩種：(a) 網主 app 是這台節點的擁有者（S1 建網、join2 自己的節點）→ 簽之前從這台節點的 `status` key 8 讀；(b) 其他人的節點 → 用加入申請的 key 7（加入者的擁有者金鑰簽過） |
| 驗證（網主 app 核准 / 簽之前） | 6 B、不是全 0、unicast（第一個 byte 的 bit 0 = 0）、**不等於名單裡任何其他項目的 key 7**。不合 → 這一項不填 key 7、核准照常，核准畫面多一行「這台的網路位址無效或和『X』相同，沒有登記 — 全隊狀態會顯示『未確認身分』」（加入是主功能，全隊狀態不能擋它） |
| 缺 | 舊項目、讀不到 key 8、驗證不過 → 沒有 key 7 → 全隊區該成員顯示「未確認身分」（§6） |
| 壞（app 匯入時） | key 7 不是 6 B → **整份名單拒收**（簽章物件嚴格，F6；和既有 key 6 一樣） |
| 相容 | **舊 app 拒收含 key 7 的名單與申請**（F25）。所以：所有手機要先裝新 app，網主才開始發含 key 7 的名單。階段 1 只限內部（F12）、手機都是我們的 → 接受；舊 app 拒收時顯示的字句由 T-A6 記下來 |
| 節點 | 不讀（F19）；network/join、network/update 照舊只驗簽章與版本 → 節點新舊版都不受影響 |
| 既有網路 | 舊項目沒有 key 7，不另做「補登位址」的流程；該節點離開再加入就會帶上（U4：不為少數既有的開發網路加機制） |

### 4.3 不新增的介面

- 不加簽章標籤、不加動詞、不開埠；`scope = 1` 維持 E_UNSUPPORTED reason 7（F13）。
- 不讀 `/tmp/bat-hosts`、主機名、alfred 來決定名稱（未簽章，F30）。

## 5. 方案比較；為什麼不要節點簽章

### 5.1 取得「誰在線」
| 方案 | 結論 |
|---|---|
| A. 節點經 mesh 問別台的 provd（原設計 scope team） | 否：8095 在 mesh 上被擋（F11），要開 mesh 埠 = 新攻擊面 + 新流量 + 每台都要答 |
| B. 每台用 alfred 廣播 DAC 簽章的狀態 | 否：新機制、新格式、新簽章；仍然只是信任發送者 |
| **C. 自己的節點報它看到的 batman originator + RAM 最後看到表（採用）** | batman 本來就在交換 OGM，零新流量；節點不需知道名單 |

### 5.2 位址 → 成員
| 方案 | 結論 |
|---|---|
| bat-hosts / 主機名 | 否：未簽章、任何人可設（F30；使用者規則：不從主機名推名稱） |
| **網主簽章名單裡的選填欄位（採用）** | 名單本來就到每支手機（F24）、本來就由網主簽 |
| 再加上節點 DAC 簽的「我的位址」聲明（新標籤） | 否，理由 5.3 |

### 5.3 節點簽章聲明擋不了要擋的人
威脅：成員 M 在申請裡填**別台**節點 V 的位址，讓 V 在全隊區顯示成 M 的名稱、M 自己的節點變成「不明節點」。
1. **觀察端本來就不可信**：batman originator 位址沒有驗證；任何有 mesh 金鑰的人都能把自己的 MAC 改成 V 的位址，直接出現在別人的表裡。名單端簽得再嚴，畫面上「V 在線」仍可被偽造 → 和 F3 原設計同一條誠實界線。
2. **擁有者可以拿到自己節點的 DAC**：擁有者有 `root_password/reset`、`ssh_keys/set`（F14）→ root → file backend 的 DAC 私鑰在卡上（F22）；換成 608B 後私鑰拿不出來，但 root 仍可叫晶片簽任何內容。所以要騙的人照樣簽得出「我的位址是 V」。
3. 它真正擋得住的只有「app 被改、節點沒動過」的人 — 這種人直接改 MAC（第 1 點）更容易。

→ 加一個標籤、一個簽章、一段驗證，換不到安全性；不做（U4）。真正有用的只有 §4.2 的「位址不能重複」檢查（擋填錯、擋同一位址兩個名字）。

## 6. 使用者看到的（沿用現有「節點狀態」頁）

加在既有 `StatusPageView`（app/lib/member_ui.dart:316）**最下面**、「技術資訊」摺疊之前，一個「全隊」區；網主與成員手機一樣（U1）。節點清單頁不改。句型照狀態頁：顏色 + 一句白話。

**標題**：「全隊（由『<自己節點名稱>』看到，讀取於 HH:MM:SS）」— 換到另一台自己的節點時標題跟著換，因為數字是那台看到的。

**每張卡片**（名稱一律 `display_name` + 截 64 字，F9）：

| 情況 | 顯示 |
|---|---|
| 對到成員、seen-ago ≤ 60 s | 🟢 『<名稱>』 在線 · 訊號 好 / 普通 / 差（直接連線 / 經隊員轉送） |
| 對到成員、seen-ago > 60 s | ⚪ 『<名稱>』 離線 · 最後看到 N 分鐘前（≥ 60 分鐘寫「N 小時前」） |
| 名單裡有 key 7、這台開機後沒看過 | ⚪ 『<名稱>』 這台節點開機後還沒看到 |
| 名單裡沒有 key 7 | ⚪ 『<名稱>』 未確認身分（名單裡沒有這台的網路位址，看不到狀態） |
| key 9 裡有、名單對不到 | ❔ 不明節點 · 在線 / 最後看到 N 分鐘前 · 訊號 …（**沒有名稱**；技術資訊裡才有位址末 4 碼） |
| 自己 | 不列（上面的狀態頁就是它） |

**訊號**：直接連線（有 key 4）→ signal ≥ −70 dBm 好、−85 到 −70 普通、< −85 差；不是直接連線 → TQ ≥ 200 好、100–199 普通、< 100 差；都沒有 → 不寫訊號。門檻暫定（同狀態頁 SNR 的寫法），上機後再調。

**整區只有一句的情況**：key 9 不在或壞 →「看不到全隊狀態（節點軟體太舊，或暫時讀不到 mesh 資料）— 請按『重新整理』；一直如此請找維修人員」；狀態 k5 存在（還沒連上網路）→「這台還沒連上網路，看不到隊員」；`status` 本身失敗 → 不顯示全隊區（狀態頁上面已經說了）。

**小字（全隊區最下面）**：「在線 = 這台節點最近 1 分鐘內收得到。離線不一定是關機，也可能是太遠或被擋住。節點重開後『最後看到』會歸零。這是參考資訊：有網路密碼的人可以假冒別台。」

排序：在線（依名稱）→ 離線（最近看到的在前）→ 未確認身分 → 不明節點。電量、軟體版本不顯示（U3）。

## 7. 安全

**資產**：隊員的在線 / 位置線索（誰在範圍內）、mesh MAC（F4 視為敏感）、狀態頁的可用性。

| Actor | 能做什麼 | 處理 |
|---|---|---|
| 成員手機（成員角色連到別人的節點） | 拿到那台看到的所有 mesh 位址、seen-ago、TQ / signal（**以前只有 key 1–5**） | U1 使用者決定成員可看；同一 mesh 的人有 root 本來就看得到（`batctl o`）。key 8 不給成員角色（用不到）。app 不把位址寫進 log、不放進任何分享出去的內容；主畫面不顯示位址，技術資訊只顯示末 4 碼 |
| 被收買的成員（有 mesh 金鑰、自己節點有 root） | (1) 申請裡填別台的位址 → 名字錯掛；(2) 改 MAC 假冒某隊員「在線」；(3) 灌大量假 originator → 把真隊員的舊紀錄擠出 32 筆表 | (1) §4.2 不可重複 + 誠實界線（§5.3）；(2) 誠實界線，畫面小字明說「參考資訊」；(3) 上限 32、丟最舊 → 最壞是隊員顯示「開機後還沒看到」，不會崩、不會超過 8192 B；batman 本身也擋不住 mesh 內部灌包 |
| 假節點、沒有 DAC | 沒有 mesh 金鑰進不了 802.11s SAE mesh → 不會出現在 originator 表 | — |
| 假節點、拿到 DAC（偷來 / 自己的） | 等同被收買的成員 | 同上；移除成員 + 換密碼（既有 remove-member）後進不了 mesh |
| mesh 外的人 | 看不到 BLE session 內容；沒有新埠、沒有新流量 | 攻擊面不變 |
| 我們自己的錯 | parser 讀錯 → 在線判斷錯；表無上限 → 吃記憶體；回答超過 8192 B → **整個狀態頁壞掉**；新 key 弄壞舊的狀態頁判定 | parser 只照擷取的真實格式寫，讀不懂 → 整個 key 9 不送（fail-closed）；上限 32（T-N2）；長度測試（T-N4）；app 對 key 9 的錯誤隔離（T-A3） |

- **攻擊面變化**：新輸入 = (a) helper 讀 `batctl`、`iw` 的輸出（固定參數，不帶任何外部字串；輸出限制長度，例如 ≤ 64 KiB，超過 → 這次取樣失敗）；(b) app 讀 key 8 / 9 / 名單 key 7（型別、長度依 §4 嚴格檢查）。
- **權限**：取樣跑在 helper（root，F23），因為 batctl 的 netlink 查詢需要權限（⚠️ C8；記憶裡有「非 root batctl 靜默回 []」的線索，擷取時確認）。不寫任何檔案、不碰低權限可寫的路徑 → 沒有 TOCTOU / symlink 問題。子行程每 15 s 兩個，有逾時（例如 5 s），逾時 = 這次取樣失敗。
- **秘密**：無。位址不是秘密，但不進 log（F4 的精神）。
- **失敗模式**：取樣失敗 / 過期 → 不送 key 9；名單位址壞 → 拒收整份（簽章物件規則）；位址重複 → 不登記（顯示未確認身分）。唯一的 fail-open 是「畫面上的在線可被偽造」，理由見 §5.3。
- **負對照**：T-N3（成員角色拿不到 key 8）、T-A2（重複位址不登記）、T-A1（不從主機名推名稱）。

## 8. 生命週期矩陣

| 路徑 | 今天 | 改後 | 測試 |
|---|---|---|---|
| 安裝 / 第一次開機 | 無全隊 | 表空；還沒入網 → 「這台還沒連上網路」 | T-N5、H1 |
| 啟動 | — | helper 啟動就開始每 15 s 取樣 | T-N1 |
| 節點重開 / 斷電 | — | 表歸零（U2）；15 s 內重新看到在線的人；其他人顯示「開機後還沒看到」 | H3 |
| helper 重啟 / crash loop | status 回 E_BUSY 或過期 | 表歸零（同重開，T3）；crash loop 時狀態頁本來就讀不到 | T-N6 |
| provd 重啟 | — | 表不受影響（在 helper） | T-N6 |
| batman 重啟（network restart、bat0 重建） | — | kernel 表清空；我們的表保留最後看到；取樣失敗的那段 key 9 不送（≤ 60 s 後恢復） | H4 |
| 成員名單更新 | — | 手機匯入新名單後下一次讀就用新名稱；被移除的人 → 對不到 → 「不明節點」（換密碼後它離開 mesh → 變離線） | T-A5 |
| 節點升級 | — | 升級會重開 → 表歸零 | H3 |
| 節點降級到沒有這功能的版本 | — | key 8 / 9 不在 → 「看不到全隊狀態（節點軟體太舊…）」 | T-A3（不在的那一臂） |
| 舊 app + 新節點 | — | 舊 app 忽略 key 8 / 9（F27，由 T-A4 證明） | T-A4 |
| 新 app + 舊節點 | — | 沒有 key 9 → 同上那句；讀不到 key 8 → 簽名單時這台不填 key 7 → 未確認身分 | T-A3 |
| app 升級（既有網路） | — | 舊項目沒有 key 7 → 未確認身分，直到該節點離開再加入（§4.2） | T-A5 |
| app 降級（網主已發含 key 7 的名單） | — | **舊 app 拒收之後的名單與申請**（F25）— 誠實界線，階段 1 接受 | T-A6 |
| 網路分割 | — | 自己的節點只看得到同一邊；另一邊顯示離線 + 分割時的最後看到 | H2 |
| 手機換到另一台自己的節點 | — | 標題換成那台；內容是那台看到的（各台的表各自獨立） | H5 |
| 隊員走遠 / 關機 | — | ≤ 60 s + 一個取樣週期後變離線；kernel 約 200 s 刪掉後我們的表仍保留最後看到 | H2 |
| 依賴重啟：BLE / provd / helper / batman / wireless | — | 分別見上；wireless reload（例如設手機 Wi-Fi）= wlh0 短暫消失 → 同 batman 重啟 | H4 |
| 平台：bcm2711（Pi4 / CM4） | — | 照上 | H1–H6 在 04 / 02 |
| 平台：bcm2710（Pi3） | — | 不適用：Pi3 暫不支援（量產 CM4，2026-10-23 使用者決定）；程式沒有板別分支 | — |

## 9. ⚠️ 必須在 04 + 02 的 mesh 上擷取（實作 parser 之前）

順序：**設計審過 → 下列擷取（唯讀，02 接上網路線後）→ 照擷取寫 parser 與 stub（stub 格式一律來自擷取，不自己編）→ 上機測試**。任何一項推翻本設計的前提（特別是 C2–C4），先回報再改設計。

| # | 要擷取 | 為什麼 |
|---|---|---|
| C1 | 兩台的 `batctl if`、`batctl o`、`batctl n` 原始輸出；`batctl oj` / `batctl nj`（JSON）在 2024.3 有沒有、長什麼樣；TQ 與 last-seen 的欄位與單位 | 有 JSON 就用 JSON（少一個文字 parser） |
| C2 | 對方的 originator 位址 = 對方的 `wlh0` MAC、`bat0` MAC、還是別的（對照兩台的 `/sys/class/net/*/address`） | key 8 / key 9 / 名單 key 7 必須是同一種位址 |
| C3 | 已認領未入網（keyguard 關 radio）時 `wlh0` 在不在；`/sys/class/ieee80211/phy*/macaddress` 與 wlh0 MAC 是否相同；uci 有沒有設 `macaddr` | 網主在入網**前**簽名單（network/join 帶名單）→ key 8 必須在 radio 關著時就讀得到 |
| C4 | wlh0 MAC 在重開機、sysupgrade 後會不會變（換 HaLow 模組另記為誠實界線） | 會變 → 名單裡的位址失效，設計要改 |
| C5 | `iw dev wlh0 station dump`：每台的 MAC、`signal avg`、`inactive time`；離開的站台 inactive 怎麼長 | key 4 只給最近一次取樣裡活著的直接站台（F10） |
| C6 | 一台關機後，對方 originator 的 last-seen 怎麼長、多久消失 | 在線門檻 60 s 是否合理 |
| C7 | `bat0` 不存在時 batctl 的 exit code 與輸出 | 分「沒入網 → `[]`」與「取樣失敗 → 不送」 |
| C8 | root 與非 root 執行 batctl 的差別 | 取樣必須在 helper（root） |
| C9 | 每 15 s 取樣的 CPU / 記憶體成本（04 上 1 小時，開 / 關取樣對照） | T4「一直跑」要有數字 |

## 10. 測試（每項附負對照）

### 10.1 節點（Go，離線；stub 用 §9 擷取的原始輸出）
| # | 測什麼 | 負對照 |
|---|---|---|
| T-N1 | 注入時鐘 + 擷取的 `batctl` / `iw` 輸出 → key 9 的位址、seen-ago、TQ、signal 正確；自己不在清單 | 擷取裡一個欄位改壞 → 這次取樣失敗、60 s 後 key 9 不在（parser 若亂猜就 FAIL） |
| T-N2 | 灌 40 個 originator → 表 32 筆、丟的是最舊的 | 拿掉上限 → FAIL |
| T-N3 | 擁有者拿到 key 8、9；成員角色只拿到 9；provd 也丟成員的 key 8 | 只拿掉 helper 的篩選 → 經 provd 的端到端仍 PASS（provd 防線）；兩層都拿掉 → FAIL |
| T-N4 | 32 筆最長 peer-entry + 最大的 key 15 編碼 ≤ 8192 B | 上限改 400 → FAIL |
| T-N5 | bat0 不存在（C7 的真實輸出）→ key 9 = `[]`；batctl 失敗 / 逾時 → key 9 不在 | 兩種輸出對調 → FAIL |
| T-N6 | helper 重建 → 表空；provd 重連 → 表不變 | 重建前先塞資料，斷言重建後是空的（沒歸零 → FAIL） |

### 10.2 App（Rust）
| # | 測什麼 | 負對照 |
|---|---|---|
| T-A1 | 位址對到名單 key 7 → 名稱；對不到 → 不明節點且**沒有名稱**（測試資料在 key 15 `node` 放一個像主機名的字串） | 改成用 key 15 `node` 當名稱 → FAIL |
| T-A2 | 核准 / 簽名單時：key 7 重複、全 0、multicast、長度不是 6 → 不登記且給提示；合法 → 登記 | 拿掉重複檢查 → FAIL |
| T-A3 | key 9 壞（型別錯、33 筆、5 B 位址）或不在 → 全隊區那一句；**狀態頁判定與其他行和沒有 key 9 時逐字相同** | 讓 key 9 的解析錯誤往上傳 → 判定變 → FAIL |
| T-A4 | 現有 statuspage 的全部測試向量加上 key 8 / 9 → 結果不變（證明 F27 =「舊 app + 新節點」） | 在 Answer 解析加嚴格未知 key 檢查 → FAIL |
| T-A5 | 名單沒有 key 7 → 未確認身分；名單更新加上 key 7 → 下一次顯示名稱；被移除 → 不明節點 | 同一組 key 9 只換名單作對照 |
| T-A6 | 新版 `exact_keys` 收 key 7；舊版規則（`&[6]`）解析含 key 7 的名單 / 申請 → 拒收，記下舊 app 的錯誤字句 | 本身即舊版對照 |
| T-A7 | 卡片字句：seen-ago 59 / 60 / 61 s、3599 / 3600 s 邊界；訊號門檻邊界 | 門檻改掉 → FAIL |

### 10.3 上機（04 + 02，兩支手機：一支網主、一支成員）
| # | 測什麼 | 負對照 |
|---|---|---|
| H1 | 兩台組網：兩支手機都看到對方節點「在線」+ 名稱 + 訊號 | 手機連舊 image 的節點 → 「看不到全隊狀態」 |
| H2 | 02 關機 → 04 那邊 ≤ 75 s 變離線，seen-ago 遞增；開回來 → 在線 | 關機前的「在線」作對照 |
| H3 | 04 重開 → 表歸零、02 在 15 s 內回來 | 重開前的 seen-ago 作對照 |
| H4 | 04 `network restart` → key 9 短暫不在、之後恢復且 02 的紀錄還在 | — |
| H5 | 手機換連 02 → 標題換成 02、內容是 02 看到的 | — |
| H6 | §9 C9 的成本數字 | 取樣關閉時同時段的數字 |

常規全套：「組網後兩台互見、`status` 回答 ≤ 8192 B」的斷言照 #290 規則**另開 harness PR 先進 main**，不放在功能 PR。

## 11. 最小修改清單

節點（`feed/batman-prov/src`）：
1. `node/peers.go`（新）：背景取樣（每 15 s、有逾時、輸出限長）+ RAM 表（上限 32）+ 自己的位址；parser 依 §9 擷取。
2. `node/status.go`：`status.get` 加 key 8（只在 full）、key 9（full 與成員都給，60 s 新鮮度）。
3. `provd/session.go`：非擁有者丟 key 8（和 key 15 同一行）。
4. `docs/design/219-protocol.cddl` / `219-protocol.md`：§4.1、§4.2 的增補；key 7 / `team-entry` / scope team 標退役。
5. `docs/design/254-p3-impl.md` §11 checklist：`status` team 改指向本文件。

App（`app/`）：
6. `batman-proto`：`teamview.rs`（新，純函式：key 9 + 名單 → 卡片）；`netrec.rs` / `mrec.rs` 的 key 7；`approve.rs`、`mupdate.rs` 的 `exact_keys` 加 7；建網 / join2 / 加入申請時讀節點 key 8、做 §4.2 驗證、寫進名單 / 申請。
7. `bridge`：把全隊卡片交給 Dart。
8. `lib/member_ui.dart`：`StatusPageView` 最下面加「全隊」區。

不改：BLE / Noise、provd 角色表、節點的名單處理、狀態頁 v8.1 判定表、節點清單頁、簽章標籤。

## 12. 只有使用者能決定的問題

1. **成員手機會拿到 mesh 上所有節點的位址**（含不在名單的）；只在技術資訊顯示末 4 碼、不進 log — 可以嗎？（U1 的直接結果，但 F4 把 MAC 當敏感）
2. **全隊狀態是參考資訊**：有 mesh 密碼的人可以假冒別台「在線」（§5.3），這版不擋 — 接受嗎？
3. 「最後看到」在 helper 重啟時也歸零（T3，少見）— 可以嗎？還是要多一個 `/var/run` 檔撐過 helper 重啟？
