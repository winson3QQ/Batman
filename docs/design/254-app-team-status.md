# #254 app S4 — 全隊狀態（設計 v2.1，FROZEN）

**凍結 v2.1（2026-11-13）。** 審查 2 輪，每輪兩位：v1 A 3 MAJOR / 6 MINOR、B 3 MAJOR / 5 MINOR（附錄 R1）；v2 A APPROVE-WITH-CHANGES 0 MAJOR / 6 MINOR、B APPROVE 0 MAJOR / 2 MINOR（附錄 R2，v2.1 已處理）。
範圍：S4「看狀態」的**全隊**那一半（219-field-provisioning.md:128、:165）。節點與 app 都要改；本文件不含程式碼。
順序：**本設計凍結 → 依文件格式先寫 parser，fixture 一律放在標明 `.provisional` 的檔案 → §9 擷取（先做 04 單台就能做的，再做 04 + 02 mesh 的）→ 用擷取替換 provisional fixture、不符就改 parser → 上機測試（§10.3）**。§9 的停止條件成立就停下回報。

## 0. 決定與取捨

使用者決定（2026-11-13，綁定）：

| # | 決定 |
|---|---|
| U1 | **成員**（不只網主）看得到每位隊員的：在線與否、「N 分鐘前看到」、訊號 / 速度；**由此推得出位置也接受** |
| U2 | 「最後看到」存在 **RAM**（節點重開就歸零），不寫 flash |
| U3 | 卡片 = 名稱 + 在線狀態 + 多久前看到 + 訊號 / 連線品質；**電量、軟體版本這版不做** |
| U4 | 沿用現有畫面（UI/UX 重做 #329 延後）；只做必要的修改；能拿掉機制就拿掉 |
| U5 | 全隊畫面上的身分是**參考資訊、可被假冒**（有 mesh 密碼的人、自己節點有 root 的成員）— 接受，畫面標「僅供參考」 |
| U6 | 卡片用中性字眼（「在線」），**不用「已確認」** |

本文的取捨（技術細節由我定）：

| # | 取捨 |
|---|---|
| T1 | **不做節點對節點查詢、不開新的 mesh 埠**：手機自己的節點在既有 `status`（scope 0）回答裡附上「它在 mesh 上看到的節點」；app 自己對成員名單。原協定的 `scope = team`（219-protocol.md:215、cddl :248-250、:258）不實作；`status` key 7 / `team-entry` 退役：節點不知道成員名單（node.go:1167），產不出 key 7 要的 `dac_pub_hash` / 名稱；CDDL 規定 key 不重用（cddl :7-8） |
| T2 | 位址 → 成員的對應**只放在網主簽章的成員名單**（新的選填欄位）；**不做**節點 DAC 簽的「我的 mesh 位址」聲明、不加簽章標籤（§5.3） |
| T3 | 「最後看到」表放在 helper 的**行程記憶體**：一個擁有者、沒有檔案契約；helper 重啟也歸零（少見，等同重開）（§12 Q1） |
| T4 | 取樣在背景**一直跑**（每 15 s），不只在「有人問的 10 分鐘」內（status.go:116-120 的做法）：否則「2 小時前看到」記不到 — batman 約 200 s 就刪掉離開的節點（254-app-status-page.md:15 F4） |
| T5 | 全隊資料放在 scope 0 的回答裡（新 key），不另開 scope 1 請求：status 額度是每連線 1 次 / 秒（session.go:867-875，scope 1 若實作也走同一個 `statusAt`），兩次請求會互撞 E_RATE；也讓「新 / 舊節點」只靠 key 在不在就分得出來 |
| T6 | **app 分兩版上線**（§4.3）：版本 N（本設計）只「收」名單 / 申請裡的 key 7、從不寫；版本 N+1 才寫。避免新舊 app 混用時互相拒收 |

## 1. 事實

設計文件：

| # | 事實 | 證據 |
|---|---|---|
| F1 | S4 原設計：「附近」BLE 直接看、「全隊」經 mesh 查詢、每台顯示最後看到時間；首頁卡片含電量（U3 拿掉） | 219-field-provisioning.md:128、:165 |
| F2 | `GET /v1/status` 原設計：全隊經 mesh 查詢；擁有者 / 同網成員可讀 | 219-field-provisioning.md:312；219-protocol.md:215 |
| F3 | 原設計的成員偵測（§6.6）：對 mesh 鄰居發 `peers/challenge` 要 DAC 簽章；**誠實界線：只擋不小心的人**（偽造 MAC 又拒答的人和斷線的機台分不出） | 219-field-provisioning.md:408-412 |
| F4 | 診斷包裡的鄰居 MAC、IP 視為「包含裝置名稱與位址」，分享前提示 | 219-field-provisioning.md:477 |
| F5 | CDDL：`status-req` scope 0 self / 1 team；`status-resp` key 7 = `[* team-entry]`；`team-entry` = {1 dac_pub_hash, 2 name, 3 verdict, 4 seen-ago 秒, ?5 battery} | 219-protocol.cddl:248-250、:258、:282-288 |
| F6 | CDDL 規則：key 不重用；新選填欄位用新 key；回應本體的未知 key 忽略；**簽章物件裡的未知 key 拒收** | 219-protocol.cddl:7-11 |
| F7 | `member` = {1 dac_pub_hash, 2 ecdh_pub, 3 名稱, 4 owner_pub, 5 owner_enc_pub, ?6 lora_pkc_pub} — 沒有 MAC / IP；`join-request` = {1..6}（key 2 = 節點 cert，由加入者的 app 從自己的節點經 BLE 取） | 219-protocol.cddl:403-410、:444-451 |
| F8 | P3 決定 D7：`status` 只做 self；team 進 checklist；`scope = 1` → `E_UNSUPPORTED{1: typ, 2: 7}` | 254-p3-impl.md:23、:44、:272、:776 |
| F9 | 狀態頁 v8.1 凍結：只讀 `status` / `info`；節點給的字串一律 `display_name` + 截 64 字 | 254-app-status-page.md:5、:33 |
| F10 | batman 約 200 s 才移除鄰居；802.11s plink 不逾時，已離開的站台可能一直在 station dump 裡 | 254-app-status-page.md:15（F4） |
| F11 | provd 的 8095 在 IP 層只收手機 AP port 進來的封包，mesh 來的都丟 → **節點之間不能互叫 provd** | 254-p3-impl.md:464-465 |
| F12 | 階段 1 只限內部開發、不可出貨 | 219-field-provisioning.md:559 |

節點原始碼（feat/254-claim-noover 6c721e4，`feed/batman-prov/src/`）：

| # | 事實 | 證據 |
|---|---|---|
| F13 | `status` scope 1 → `E_UNSUPPORTED{1: "status", 2: 7}` | provd/session.go:862-863 |
| F14 | 成員角色允許：info、network/update、status；擁有者有 `ssh_keys/set`、`root_password/reset` | provd/session.go:79-82 |
| F15 | provd 轉送 helper 回答的所有整數 key，只擋非擁有者的 key 15 → 新 key 8、9 不必改 provd | provd/session.go:890-896 |
| F16 | `peers/challenge`、`diag/*`、`owner/*` 仍是 p3Types（E_UNSUPPORTED）；沒有逐台查詢的動詞 | provd/session.go:68-69、:644-646 |
| F17 | helper `status.get`：`halow-status json` 快取，「有人問過的 10 分鐘內」每 15 s 刷新，超過 30 s 算過期；請求路徑不跑子行程；成員角色只拿 key 1–5（過期時只有 key 1） | node/status.go:3-12、:21-31、:116-120、:182-188 |
| F18 | `halow-status`：`join.peers` = `/tmp/bat-hosts` 裡的主機名；`snr_db` = station dump 裡**最強那一台**；batctl 只拿來計數 | feed/batman-provision/files/usr/bin/halow-status:37-41、:164 |
| F19 | 節點不存也不讀成員名單（network/update 只做簽章與版本一致性檢查） | node/node.go:1167-1178 |
| F20 | 單一訊息上限 8192 B（節點 `MaxMsg`、app `MAX_MESSAGE`） | provd/frame.go:15；app/rust/batman-proto/src/conn.rs:11-12 |
| F21 | 既有簽章標籤 11 個 | proto/proto.go:21-33 |
| F22 | device_id = hex(SHA-256(cert pub)[:9])（file backend）— 和 mesh MAC 無關 | keystore/keystore.go:147 |
| F23 | provd = uid 471 + ujail；helper = root | 254-p3-impl.md:136-138 |

App 原始碼（`app/rust/`）：

| # | 事實 | 證據 |
|---|---|---|
| F24 | 網主 `net/` key 11 與成員 `mnet/` key 4 都有**完整**成員名單；key 11 每項 keys 1–5 = members v1 的 keys，另有 6、8、9、10（**7 沒用過**） | batman-proto/src/netrec.rs:1-16；mrec.rs:6-12 |
| F25 | **現行 app 拒收成員項目裡的未知 key**（核准時、匯入更新時兩處）；加入申請 `exact_keys(p, &[1..6], &[])` | approve.rs:52、:311；mupdate.rs:133；cose.rs:333-339 |
| F26 | app 自訂成員上限 16 | netrec.rs:27 |
| F27 | 狀態頁用 `Answer::Body(&Value)` 依 key 取值（推論：未知 key 不影響判定 — **⚠️ 由 T-A4 證明**） | bridge/src/api/owner.rs:2026-2032；batman-proto/src/statuspage.rs:105 |

實機與舊擷取：

| # | 事實 | 證據 |
|---|---|---|
| F28 | 04（10.41.84.148，已認領、**不在 mesh**）：batctl 2024.3；`batctl o` / `n` / `if` 都空 | 唯讀探針 2026-11-13 |
| F29 | 04：bat0 MAC `be:5e:79:bb:31:38` 隨機，和裝置 MAC `88:a2:9e:b5:6c:89` 無關 | 同上 |
| F30 | `/tmp/bat-hosts` 由 alfred-bat-hosts 每 5 分鐘產生、**未簽章**，例：`# Node 88:a2:9e:b5:6c:89`、`be:5e:79:bb:31:38 BCM2711-6c89_bat0` | 同上 |
| F31 | 04（radio1 disabled、uptime 5:57）：`/sys/class/ieee80211/phy0/macaddress` = `a8:dd:9f:4d:c6:10`，driver `morse_spi`（HaLow 晶片）— **HaLow radio 關著也讀得到**；入網前**沒有 mesh netdev**（netdev：bat0 `be:5e:…`、br-ahwlan / eth0 `88:a2:…`、morse0 `12:00:00:00:00:00`、phy1-ap0 …） | 唯讀探針 2026-11-13 |
| F32 | 04：`uci network.bat0.routing_algo = 'BATMAN_V'` → **沒有 TQ**，metric 是 throughput | 同上 |
| F33 | 舊擷取（batman-adv 2025.4、較舊 image、mesh iface `wlan1`）：`MainIF/MAC: wlan1/a8:dd:9f:4d:c7:60 (bat0/02:d7:46:62:c2:a1 BATMAN_V)`；表頭 `Neighbor last-seen speed IF`；一列 `a8:dd:9f:4d:c6:d3 0.420s ( 14.9) [ wlan1]` → **鄰居**是 HaLow 晶片 MAC（a8:dd:9f…），primary hard-if 的 MAC 也是；有 last-seen 與 speed（Mbit/s），沒有 TQ。**originator 表在這份擷取裡沒有** → originator 位址是哪個 MAC 仍待 C2（A2-m5） | Batman/docs/data/soak-12h-final-state.txt:57-59 |

**仍 ⚠️（今天的 image、batman 2024.3）**：mesh iface 的 MAC 是否等於 phy0 macaddress、是否為 primary hard-if、`-n` / JSON 輸出長什麼樣 — §9。

## 2. 設計概要

```
隊員節點 B ─(batman OGM,已有)─┐
隊員節點 C ─(batman OGM,已有)─┤
                              ▼
自己的節點 A: helper 每 15 s 讀 `batctl -n` / JSON 的 originator 表 + mesh iface 的 station dump
              → RAM 表 {mesh 位址 → 最後看到、throughput、直接連線時的 signal}
              → status(scope 0)回答多兩個 key:8 = 自己的 mesh 位址、9 = 看到的節點清單
                              │ BLE(既有 session,擁有者或成員角色)
                              ▼
手機:key 9 的位址 對 成員名單 member key 7(網主簽章)→ 名稱(僅供參考)
```

沒有新動詞、沒有新埠、沒有節點對節點流量、節點不讀成員名單（F19 不變）、provd 不改（F15）。

## 3. 擁有權（每個資源只有一個寫入者）

| 資源 | 唯一寫入者 | 唯讀者 | 備註 |
|---|---|---|---|
| RAM「看到的節點」表 | helper 的取樣 goroutine | helper `status.get`（取鎖讀快照） | 行程記憶體；helper 重啟 / 節點重開 = 歸零 |
| `status` key 8 / 9 | helper `status.get` | provd（原樣轉送）、app | 擁有者與成員角色都給（A-m1） |
| 成員名單 `member` key 7 | 網主 app（版本 N+1 起，簽 members Sign1 時） | 成員 app（`mnet/` key 4）、網主 app（`net/` key 11） | 節點不讀 |
| `net/` key 11 項目的 key 7 | 網主 app | 網主 app | 來源：網主是擁有者時讀節點 key 8；否則來自申請 key 7 |
| `join-request` key 7 | 加入者的 app（版本 N+1 起，擁有者金鑰簽） | 網主 app（核准時） | 來源：加入者 app 讀自己節點的 key 8 |
| batman originator 表、station 表、phy macaddress | kernel | helper（固定路徑、固定參數） | 我們不寫 |

## 4. 介面契約

### 4.1 `status` 回答新 key（CDDL 增補）

```
bytes6 = bstr .size 6
status-resp = {
  ...                        ; 1-6, 15 unchanged
  ? 7 => [* team-entry],     ; RETIRED (254-app-team-status T1): never sent; the key is not reused
  ? 8 => bytes6,             ; this node's own mesh address: the permanent MAC of the HaLow phy (§4.1 key 8)
  ? 9 => [* peer-entry],     ; mesh nodes this node has seen since its helper started; at most 32 entries.
                             ; Present only when the last peer sample succeeded within 60 s; absent = unknown.
  ...
}
peer-entry = {
  1 => bytes6,               ; the peer's originator address (batctl -n / JSON, never bat-hosts-translated)
  2 => uint,                 ; seconds since this node last saw it (monotonic clock; no wall time on the node)
  ? 3 => uint,               ; BATMAN_V throughput toward it, kbit/s (unit fixed at capture C1), last sample present
  ? 4 => int,                ; signal avg (dBm), only when it is a direct 802.11s station active in the last sample
  * uint => any,             ; unknown keys ignored (§5.1)
}
```

| 項目 | 契約 |
|---|---|
| 寫入 / 讀取 | helper 寫 → provd 原樣轉送 → app 讀；**兩個角色都拿得到 key 8、9**（自己的位址本來就會出現在別台的 key 9 裡） |
| key 8 來源 | `/sys/class/ieee80211/<phy>/macaddress`，`<phy>` 依 **driver** 選（`<phy>/device/driver` 的名稱以 `morse_` 開頭；不依 `phy0` 這種名稱）；剛好一個 → 送；零個或多個 → 不送。radio 關著也讀得到（F31）— 網主入網**前**簽名單時要用。**⚠️ 前提：它等於入網後的 originator 位址**（C2）；不成立 → §9 停止條件 S1 與備案。**執行期自我檢查（A2-m1）**：已入網時，取樣讀到的 primary hard-if MAC（originators 表頭的 `MainIF/MAC`）≠ phy MAC → **不送 key 8**，log 一次（只寫「withheld」，不寫位址），之後只計數 |
| key 9 有效條件 | 最近一次成功取樣 ≤ 60 s；否則整個 key 9 不送（不把舊資料當現在，同 status.go:182-188）。沒入網 = `/sys/class/net/bat0` 不在或沒有 `lower_*`（沒有 hard-if）→ 不跑 batctl，這次取樣成功、`[]`（⚠️ C7：lower_* 是否確實代表 hard-if） |
| 取樣的輸入（B-M1） | **只用不翻譯的文字輸出**：`/usr/sbin/batctl meshif bat0 originators -n`，固定 meshif `bat0`，絕對路徑執行、不經 shell。選文字不選 JSON：表頭的 `MainIF/MAC` 是自我檢查要的（JSON 沒有表頭）。只認 BATMAN_V 表頭；每一列的位址必須符合 `^[0-9a-f]{2}(:[0-9a-f]{2}){5}$`；**壞列丟掉、其他列照用**；表頭讀不懂 → 整次取樣失敗。只用最佳路徑（`*`）那一列；nexthop == originator → 直接連線。station dump（`/usr/sbin/iw dev <MainIF> station dump`）同樣規則 |
| 子行程 | 逾時 5 s → 殺整個 process group，這次取樣失敗；輸出只讀 64 KiB，超過 → 這次取樣失敗 |
| 「看到」 | 某次取樣時它在 originator 表裡 → 最後看到 = 取樣時間 − batman 回報的 last-seen；key 3 = 該次的 throughput |
| 自己 | key 9 不含自己的位址（= key 8） |
| 上限與淘汰（B-m2） | 表最多 32 筆；滿了丟「最後看到」最舊的；同時間的依位址位元組由大到小先丟（決定性）。**誠實界線：mesh 內灌大量假 originator 可以把一個還在線的隊員擠出表** → 該隊員顯示「這台節點開機後還沒看到」直到下一次取樣重新看到（灌包持續就一直看不到） |
| 長度 | 每筆約 ≤ 24 B → key 9 ≤ 32 × 24 + 3 ≈ 771 B；加上最大的 key 15 必須 ≤ 8192 B（F20）→ T-N4 |
| log | helper / provd / app **不把任何 mesh 位址寫進 log**（F4）；錯誤只記數量（例如「dropped 2 rows」） |
| 缺 / 壞（app 端） | key 9 不在 → 全隊區「看不到全隊狀態」那一句；key 9 型別錯、筆數 > 32、位址不是 6 B、key 2 不是 uint → **整個 key 9 當壞的**，全隊區同一句、**狀態頁其他部分照常**；只有 key 3 / key 4 型別錯 → 只丟那一欄；key 8 不是 6 B → 當作沒有 |
| 誰能寫 | 只有 helper（root）；但位址與數值來自 mesh 上**任何有 mesh 金鑰的人**送的 OGM（§7） |

### 4.2 成員名單 `member` key 7、`net/` key 11 的 key 7、`join-request` key 7

```
member = {
  1..5 unchanged, ? 6 => x25519-pub,
  ? 7 => bytes6,             ; the node's mesh address (254-app-team-status §4.2), read from the node over BLE
}
join-request = {
  1..6 unchanged,
  ? 7 => bytes6,             ; the joining node's mesh address, read by the joining owner's app from its own node
}
```

| 項目 | 契約 |
|---|---|
| 寫入（N+1 起） | 網主 app 簽名單時填。來源只有兩種：(a) 網主 app 是這台節點的擁有者（S1 建網、join2 自己的節點）→ 簽之前讀這台節點的 `status` key 8；(b) 其他人的節點 → 用申請的 key 7 |
| 多一次 status 讀（A-m4） | 位置：S1 簽 members v1 之前、join2 把自己的節點加進名單之前、加入者 app 產生申請之前 — 都在**已有的擁有者 session** 裡、送 scope 0。E_RATE → 等 1 s 重試一次；再 E_RATE、E_BUSY、其他錯誤、key 8 不在 / 不合格 → **不填 key 7、流程照常**（不擋加入），之後該成員顯示「沒有登記網路位址」 |
| 驗證（網主 app 核准 / 簽之前） | 6 B、不是全 0、unicast（第一個 byte 的 bit 0 = 0）。不合 → 不填 |
| 重複（B-M2） | 新的 key 7 等於名單裡另一項的 key 7 → **兩項都不填 key 7**（這次簽的名單兩項都沒有），核准畫面加一行「這台的網路位址和『X』相同，兩台都沒有登記 — 全隊狀態會顯示『沒有登記網路位址』」。**讀名單的一方**也一樣：名單裡 key 7 重複 → 那幾項都當沒有 key 7 |
| 缺 | 舊項目、讀不到、不合格、重複 → 沒有 key 7 → 該成員顯示「沒有登記網路位址」 |
| 壞（app 匯入時） | key 7 不是 6 B → **整份名單拒收**（簽章物件嚴格，F6；和既有 key 6 一樣） |
| 節點 | 不讀（F19）；節點新舊版都不受影響 |
| 既有網路 | 舊項目沒有 key 7，不另做補登流程；該節點離開再加入就會帶上（U4） |

### 4.3 app 分兩版上線（A-M2）

現行 app（版本 N−1，F25）拒收含 key 7 的名單與申請。若新舊混用就寫 key 7：新加入者 × 舊網主 → 申請被拒；舊成員 × 含 key 7 的更新（例如移除成員換密碼）→ 舊成員拒收 → **它的節點拿不到新密碼、掉出 mesh**。所以：

| 版本 | 內容 |
|---|---|
| **N（本設計出貨的版本）** | 節點全部變更（key 8、9）；app：`exact_keys` 收 key 7、讀名單 key 7（含重複規則）、全隊區的程式、寫 key 7 的程式；**寫 key 7 與全隊區都由同一個編譯期常數關著**（`WRITE_MESH_ADDR = false`，A2-m2 選項 1）→ 版本 N 從不寫 key 7、**也不顯示全隊區**（不給使用者一個全是「不明」的半成品）。N 的網主收到 N+1 加入者帶 key 7 的申請 → 核准照常，但**丟掉 key 7**（N 不寫）→ 該成員在 N+1 畫面上是「沒有登記網路位址」（A2-m3，矩陣列、T-A6(c)） |
| **N+1** | 只把常數改成 true 的一行 PR（同時打開寫入與全隊區），加上刪掉 §10.2 T-A10「N 必須關著」那個測試 — 刪測試會出現在 diff 裡，不能悄悄拿掉（B2-m1） |

**N+1 的閘門（A2-m4、B2-m1）**：app 自己**沒有顯示可分辨版本的資訊** — 啟動檢查只印 `batman_bridge` 的 crate 版本（app/lib/main.dart:57-58；固定 `0.1.0`，bridge/Cargo.toml:3、simple.rs:14），pubspec 是 `1.0.0+1`（app/pubspec.yaml:19）從沒改過；狀態頁的「軟體版本」是**節點**的（member_ui.dart:447）。所以閘門的輸入是**安裝紀錄**：每支手機的 `adb shell pm path <package>` → 取回 `base.apk` 算 sha256，對照 N（或之後）建置的 APK sha256 清單。**誠實界線：閘門是人工的**（使用者逐支確認），app 不會自己擋；N 建置的 APK sha256 與 commit 寫進 PR 的測試結果段。N 的「常數關著」由 T-A10 綁在 N 的 commit 上：發佈前在 N 的 commit 執行 `git show <N commit>:app/rust/batman-proto/src/teamview.rs | grep -c "WRITE_MESH_ADDR: bool = false"` = 1。

### 4.4 不新增的介面

- 不加簽章標籤、不加動詞、不開埠；`scope = 1` 維持 E_UNSUPPORTED reason 7（F13）；provd 不改。
- 不讀 `/tmp/bat-hosts`、主機名、alfred 決定名稱或位址（未簽章，F30）；batctl 一律 `-n` / JSON。

## 5. 方案比較；為什麼不要節點簽章

### 5.1 取得「誰在線」
| 方案 | 結論 |
|---|---|
| A. 節點經 mesh 問別台的 provd（原 scope team） | 否：8095 在 mesh 上被擋（F11），要開 mesh 埠 = 新攻擊面 + 新流量 |
| B. 每台用 alfred 廣播 DAC 簽章的狀態 | 否：新機制、新格式、新簽章；仍只是信任發送者 |
| **C. 自己的節點報它看到的 originator + RAM 表（採用）** | OGM 本來就在交換，零新流量；節點不需知道名單 |

### 5.2 位址 → 成員
| 方案 | 結論 |
|---|---|
| bat-hosts / 主機名 | 否：未簽章、任何人可設（F30） |
| **網主簽章名單裡的選填欄位（採用）** | 名單本來就到每支手機（F24）、本來就由網主簽 |
| 再加節點 DAC 簽的「我的位址」聲明 | 否，5.3 |

### 5.3 節點簽章聲明擋不了要擋的人
威脅：成員 M 在申請裡填**別台**節點 V 的位址，讓 V 顯示成 M 的名稱。
1. **觀察端本來就不可信**：originator 位址沒有驗證；有 mesh 金鑰的人改 MAC 就能出現在別人的表裡。
2. **擁有者拿得到自己節點的 DAC**：擁有者有 `root_password/reset`、`ssh_keys/set`（F14）→ root → file backend 的 DAC 在卡上（F22）；608B 私鑰拿不出來，但 root 可以叫晶片簽任何內容。
3. 它只擋得住「app 被改、節點沒動過」的人，這種人改 MAC 更容易。

→ 換不到安全性，不做；使用者已接受身分僅供參考（U5）。有用的只有 §4.2 的重複規則（擋填錯、擋同一位址兩個名字）。

## 6. 使用者看到的（沿用現有「節點狀態」頁）

（版本 N 不顯示，§4.3；以下是 N+1 起的畫面。）加在既有 `StatusPageView`（app/lib/member_ui.dart:316）**最下面**、「技術資訊」摺疊之前，一個「全隊」區；網主與成員手機一樣（U1）。節點清單頁不改。句型照狀態頁：顏色 + 一句白話；字眼中性（U6）。

**標題**：「全隊（僅供參考；由『<自己節點名稱>』看到，讀取於 HH:MM:SS）」— 換到另一台自己的節點時跟著換。

**卡片**（名稱一律 `display_name` + 截 64 字）：

| 情況 | 顯示 |
|---|---|
| 對到成員、seen-ago ≤ 60 s | 🟢 『<名稱>』 在線 · 連線 好 / 普通 / 差（約 N Mbit/s）· 直接連線 / 經隊員轉送 |
| 對到成員、seen-ago > 60 s | ⚪ 『<名稱>』 離線 · 最後看到 N 分鐘前（≥ 60 分鐘寫「N 小時前」） |
| 名單有 key 7、開機後沒看過 | ⚪ 『<名稱>』 這台節點開機後還沒看到 |
| 名單沒有 key 7（含重複被拿掉） | ⚪ 『<名稱>』 沒有登記網路位址，看不到狀態 |
| key 9 有、名單對不到 | ❔ 不明節點 · 在線 / 最後看到 N 分鐘前 · 連線 …；下一行小字「可能是剛加入、你的名單還沒更新的隊員」（A-m3）；**沒有名稱**，技術資訊才有位址末 4 碼 |
| 自己 | 不列 |

**連線品質**：用 key 3（throughput）：≥ 4 Mbit/s 好、1–4 普通、< 1 差（暫定；2 MHz HaLow 單向實測約 9.4 Mbit/s，記憶 project_mesh_tput_methodology；上機後再調）；沒有 key 3 → 不寫品質。「直接連線」= 有 key 4；key 4（dBm）只在技術資訊顯示。

**整區只有一句**：key 9 不在或壞 →「看不到全隊狀態（節點軟體太舊，或暫時讀不到 mesh 資料）— 請按『重新整理』；一直如此請找維修人員」；k5 存在（還沒連上網路）→「這台還沒連上網路，看不到隊員」；`status` 失敗 → 不顯示全隊區。

**小字**：「在線 = 這台節點最近 1 分鐘內收得到。離線不一定是關機，也可能是太遠或被擋住。節點重開後『最後看到』會歸零。名稱僅供參考：有網路密碼的人可以假冒別台。」

排序：在線（依名稱）→ 離線（最近看到的在前）→ 開機後沒看到 → 沒有登記網路位址 → 不明節點。

## 7. 安全

**資產**：隊員的在線 / 位置線索、mesh MAC（F4）、狀態頁的可用性。

| Actor | 能做什麼 | 處理 |
|---|---|---|
| 成員手機（成員角色連到別人的節點） | 拿到那台看到的所有 mesh 位址、seen-ago、throughput / signal、該節點自己的位址（**以前只有 key 1–5**）；可推位置 | U1 接受（含位置推論）；同一 mesh 的人有 root 本來就看得到。位址不進 log、不進分享內容；主畫面不顯示，技術資訊只顯示末 4 碼 |
| 被收買的成員（有 mesh 金鑰、自己節點有 root） | (1) 申請填別台位址 → 名字錯掛；(2) 改 MAC 假冒某隊員「在線」；(3) 灌大量假 originator 把在線隊員擠出表 | (1) 重複規則（兩項都不登記）+ U5；(2) U5，畫面「僅供參考」；(3) 上限 32、決定性淘汰 → 最壞某隊員顯示「開機後還沒看到」，不崩、不超過 8192 B（誠實界線，§4.1） |
| 假節點、沒有 DAC / mesh 金鑰 | 進不了 802.11s SAE mesh → 不在 originator 表 | — |
| 假節點、拿到 DAC | 等同被收買的成員 | 同上；移除成員 + 換密碼後進不了 mesh |
| mesh 外的人 | 沒有新埠、沒有新流量 | 攻擊面不變 |
| 我們自己的錯 | bat-hosts 翻譯過的輸出被當位址；parser 讀錯；子行程卡住；輸出巨大；回答 > 8192 B 弄壞整個狀態頁；位址進 log；新舊 app 混用掉出 mesh | `-n` / JSON + 逐列 regex（T-N7）；只照擷取格式寫，讀不懂 → 不送 key 9（T-N1）；逾時殺 group（T-N8）；64 KiB 上限（T-N9）；長度（T-N4）；log 掃描（T-N10、T-A9）；兩版上線（§4.3、T-A6） |

- **攻擊面變化**：(a) helper 讀 `batctl` / `iw` 輸出與 sysfs（固定絕對路徑、固定參數、不經 shell、不帶外部字串）；(b) app 讀 key 8 / 9 / 名單 key 7（§4 的嚴格檢查）。
- **權限**：取樣在 helper（root，F23），因為 batctl 的 netlink 查詢要權限（⚠️ C8）。不寫檔、不碰低權限可寫路徑（sysfs 只有 kernel 能寫）→ 沒有 TOCTOU / symlink 問題。
- **秘密**：無；位址不是秘密但不進 log。
- **帶成員紀錄出手機的路徑（B2-m2）**：(1) 邀請圖片（invite，只有 netcfg 與 invite 欄位，沒有成員項目，cddl :430-442）；(2) 加入申請圖片（join-request，N+1 起帶**自己節點**的 key 7）；(3) 同意圖片（approval bundle，帶整份成員名單 → N+1 起帶**每位成員**的 key 7）；(4) 更新包（update bundle，同 (3)）；(5) 手機備份：紀錄不進備份（`allowBackup=false` + `dataExtractionRules`，254-app-s1.md:82）；(6) 節點的診斷包：節點不存名單（F19），不帶 key 7（它本來就帶鄰居 MAC，F4）。**隱私變化**：N+1 起，(2)–(4) 經聊天 app 傳送時，聊天服務看得到成員節點的 mesh MAC（和名稱一起）— 由 U1 / U5 涵蓋，N+1 的 PR 要寫明。若 §9.3 S1 備案讓 key 8 改成入網後的 originator 位址，帶出的是同一類 MAC，變化相同。T-A9 掃 log 與 (1)–(4) 的輸出：N 裡一律沒有哨兵位址。
- **失敗模式**：取樣失敗 / 過期 → 不送 key 9；名單位址壞 → 拒收整份；重複 → 都不登記。fail-open 只有「畫面身分可被假冒」，使用者已接受（U5）。

## 8. 生命週期矩陣

| 路徑 | 今天 | 改後 | 測試 |
|---|---|---|---|
| 安裝 / 第一次開機 | 無全隊 | 表空；沒入網 → 「這台還沒連上網路」；key 8 已可讀（F31） | T-N5、H1 |
| 啟動 | — | helper 啟動就每 15 s 取樣 | T-N1 |
| 節點重開 / 斷電 | — | 表歸零（U2）；15 s 內重新看到在線的人 | H3 |
| helper 重啟 / crash loop | status 回 E_BUSY 或過期 | 表歸零；crash loop 時狀態頁本來就讀不到 | T-N6 |
| provd 重啟 | — | 表不受影響 | T-N6 |
| batman / wireless 重啟（bat0 重建、設手機 Wi-Fi 時 reload） | — | kernel 表清空；我們的表保留最後看到；取樣失敗那段 key 9 不送（≤ 60 s 恢復） | H4 |
| 成員名單更新 | — | 匯入新名單後下一次讀就用新名稱；被移除 → 「不明節點」 | T-A5 |
| 新的遠端成員剛加入、其他人還沒匯入新名單（A-m3） | — | 其他人看到「不明節點」+「可能是剛加入、你的名單還沒更新的隊員」；匯入後顯示名稱 | T-A5 |
| 節點升級 | — | 重開 → 表歸零 | H3 |
| 節點降級到沒有這功能的版本 | — | key 8 / 9 不在 → 「看不到全隊狀態」；N+1 簽名單時讀不到 key 8 → 不填 | T-A3 |
| 舊 app（N−1）+ 新節點 | — | 舊 app 忽略 key 8 / 9（F27） | T-A4 |
| 新 app + 舊節點 | — | 同「節點降級」 | T-A3、T-A8 |
| N−1 與 N 混用 | — | N 從不寫 key 7 → 互不拒收（和今天一樣） | T-A6 |
| N+1 新加入者 × N−1 網主（A-M2） | — | 申請帶 key 7 → 舊網主拒收（F25）→ **由 §4.3 閘門排除**；萬一發生：加入失敗、沒有東西被改，網主升級後重送申請 | T-A6 |
| N−1 成員 × N+1 網主發的含 key 7 更新（例如移除成員換密碼）（A-M2） | — | 舊成員拒收 → 它的節點拿不到新密碼、掉出 mesh → **由 §4.3 閘門排除**；萬一發生：該成員升級 app 後重新匯入同一份更新 | T-A6 |
| N × N+1 | — | N 收 key 7（exact_keys + 7）→ 正常 | T-A6 |
| N+1 加入者 × N 網主（A2-m3） | — | 申請帶 key 7 → N 收下、核准照常、**簽出的名單沒有 key 7**（N 不寫）→ 該成員顯示「沒有登記網路位址」，直到網主升到 N+1 後它離開再加入 | T-A6(c) |
| app 降級到 N−1（網主已發含 key 7 的名單） | — | 同上一列「N−1 成員」— 誠實界線，階段 1 不降級 | T-A6 |
| 網路分割 | — | 只看得到同一邊；另一邊顯示離線 + 分割時的最後看到 | H2 |
| 手機換到另一台自己的節點 | — | 標題換成那台；各台的表各自獨立 | H5 |
| 隊員走遠 / 關機 | — | ≤ 60 s + 一個取樣週期後變離線；kernel 刪掉後我們的表仍保留 | H2 |
| 平台：bcm2711（Pi4 / CM4） | — | 照上 | H1–H6 在 04 / 02 |
| 平台：bcm2710（Pi3） | — | 不適用：Pi3 暫不支援（量產 CM4，2026-10-23 使用者決定）；程式沒有板別分支 | — |

## 9. ⚠️ 擷取（替換 provisional fixture 之前）

順序：設計凍結 → parser 依文件格式先寫、fixture 標 `.provisional` → 9.1（04 單台，現在就能做，唯讀）→ 9.2（04 + 02 mesh，02 接上網路線後，唯讀）→ 用擷取替換 provisional fixture（stub 一律來自擷取），不符就改 parser → 上機測試。§9 的順序就是 v1 第 1 輪 A 的第 6 個 MINOR（已處理）。

### 9.1 04 單台（不需要 mesh）
| # | 要擷取 | 為什麼 |
|---|---|---|
| C3 | ✅ 已答（F31）：radio 關著時 phy0 macaddress 讀得到、沒有 mesh netdev | key 8 來源 |
| C4a | 04 重開機後 phy0 macaddress 不變；`/sys/class/ieee80211/*/device/driver` 的實際名稱 | 位址穩定；依 driver 選 phy |
| C7 | 沒入網時 `/sys/class/net/bat0/lower_*` 不存在；入網後存在且指向 mesh iface；沒入網時 `batctl meshif bat0 originators -n` 的 exit code / 輸出 | 「沒入網 → `[]`」用 sysfs 判斷是否可靠 |
| C8 | root 與非 root 執行同一指令的差別 | 取樣必須在 helper |
| C1a | batctl 2024.3 的 `meshif bat0 originators -n` 是否可用、BATMAN_V 表頭與欄位格式；`/usr/sbin/batctl`、`/usr/sbin/iw` 的實際路徑 | parser 與絕對路徑 |
| C9a | 每 15 s 取樣的 CPU / 記憶體成本（沒有 peer，下限） | 先看一眼；9.2 再量完整的 |

### 9.2 04 + 02 mesh
| # | 要擷取 | 為什麼 |
|---|---|---|
| C1 | 兩台的 `batctl if`、`originators -n` 原始輸出（含 `*` 最佳路徑、多路徑時的多列）；BATMAN_V 的 throughput 與 last-seen 欄位、單位 | 定 key 3 單位（暫定 kbit/s = 表上 Mbit/s × 1000）、parser |
| C2 | 對方的 originator 位址 == 對方 phy macaddress == 對方 mesh iface MAC？是不是 primary hard-if；`batctl if` 有沒有兩個 hard-if（例如 eth0）、有的話 originator 是哪個（A-m5）；`uci show wireless | grep macaddr`；HaLow phy 上**每一個** vif 的 MAC（`iw phy <phy> info`、`/sys/class/ieee80211/<phy>/device/net/*`）（A2-m1） | key 8 / key 9 / 名單 key 7 必須同一種位址 |
| C4b | sysupgrade 後 phy macaddress 不變（需使用者授權的破壞性步驟，先列步驟）；換 HaLow 模組 → 位址會變（誠實界線） | 名單位址的壽命 |
| C5 | station dump：每台的 MAC、`signal avg`、`inactive time`；離開的站台怎麼變 | key 4 只給活著的直接站台（F10） |
| C6 | 一台關機後對方 last-seen 怎麼長、多久消失 | 60 s 門檻 |
| C9 | 1 小時成本，開 / 關取樣對照 | T4 要有數字 |

### 9.3 停止條件（B-m5；成立就停，回報後改設計再審）
- **S1**：C2 推翻「key 8 == 對方看到的 originator 位址」。備案（要重審；**只適用 N+1**，N 不寫 key 7 所以不受影響，A2-m6）：key 8 改報入網後的 originator 位址（`MainIF/MAC`），沒入網就不送；N+1 的網主在**下一次** network/update 時，替它擁有的節點用當時的 key 8 補上 key 7；遠端成員只能離開再加入。
- **S2**：沒有 `-n` 也沒有 JSON（只剩翻譯過的輸出）。
- **S3**：C4 顯示位址重開機或 sysupgrade 會變。
- **S4**：C9 取樣平均 CPU > 1%（04）或記憶體持續成長。
- **S5**：BATMAN_V 沒有逐 originator 的 throughput → key 3 改來源前先回報。

## 10. 測試（每項附負對照）

### 10.1 節點（Go，離線；stub 用 §9 擷取）
| # | 測什麼 | 負對照 |
|---|---|---|
| T-N1 | 注入時鐘 + 擷取輸出 → key 9 的位址、seen-ago、throughput、signal 正確；自己不在清單；表頭讀不懂 → 60 s 後 key 9 不在 | 表頭改壞仍送 key 9 → FAIL |
| T-N2 | (a) 40 個不同時間的 originator → 留 32 筆、丟最舊；(b) **40 筆同時間** → 留下位址最小的 32 筆、每次一樣 | 拿掉上限或拿掉決定性排序 → FAIL |
| T-N3 | 擁有者與成員角色都拿到 key 8、9（helper 單元測試） | helper 對成員不給 key 8 / 9 → FAIL |
| T-N4 | 32 筆最長 peer-entry + 最大的 key 15 編碼 ≤ 8192 B | 上限改 400 → FAIL |
| T-N5 | bat0 沒有 `lower_*`（沒入網）→ 不跑 batctl、key 9 = `[]`；有 hard-if 但 batctl 失敗 → key 9 不在 | 把失敗當 `[]` → FAIL |
| T-N11 | 自我檢查：表頭 `MainIF/MAC` ≠ phy MAC → 不送 key 8、log 一次（之後只計數）；相同 → 送；沒入網 → 送 phy MAC；driver 不是 `morse_` 或有兩個 morse phy → 不送 | 拿掉比較 → FAIL |
| T-N6 | helper 重建 → 表空；provd 重連 → 表不變 | 重建前塞資料，重建後不空 → FAIL |
| T-N7 | (a) 執行的指令列 = `/usr/sbin/batctl meshif bat0 originators -n`，固定 `bat0`、絕對路徑、不經 shell；(b) 餵**翻譯過**的擷取（bat-hosts 裡有一個長得像 MAC 的主機名，例如 `a8:dd:9f:00:00:01`）→ 只要 parser 收到的是 `-n` 輸出，結果裡沒有那個假位址；(c) 一列壞、其他列好 → 好的列照用 | (a) 拿掉 `-n` → FAIL；(b) 用翻譯過的輸出跑 → 出現假位址 → 證明必須 `-n`；(c) 改成「壞一列丟整次」→ FAIL |
| T-N8 | stub 程式睡 30 s 且自己再 fork 一個睡的子行程 → 5 s 內這次取樣失敗、**兩個行程都不在**（查 process group） | 只殺父行程 → 子行程還在 → FAIL |
| T-N9 | stub 輸出 1 MiB → 這次取樣失敗、helper 記憶體沒有跟著長 | 拿掉 64 KiB 上限 → FAIL |
| T-N10 | stub 輸出含哨兵位址 `de:ad:be:ef:00:01`；跑完取樣、壞列、逾時、status.get 各路徑後，掃 helper 與 provd 的 log 輸出 → 沒有哨兵（大小寫、無冒號兩種寫法都掃） | 加一行印位址的 log → FAIL |

### 10.2 App（Rust）
| # | 測什麼 | 負對照 |
|---|---|---|
| T-A1 | 位址對到名單 key 7 → 名稱；對不到 → 不明節點、**沒有名稱**（測試資料在 key 15 `node` 放像主機名的字串） | 改成用 key 15 `node` 當名稱 → FAIL |
| T-A2 | 簽名單時：新 key 7 和既有項目重複 → **兩項都沒有 key 7** 且有那一行提示；全 0、multicast、長度不是 6 → 不填；讀名單：key 7 重複 → 兩項都顯示「沒有登記網路位址」 | 只拿掉新的那一項、或讀的一方不檢查重複 → FAIL |
| T-A3 | key 9 壞（型別錯、33 筆、5 B 位址）或不在 → 全隊區那一句；**狀態頁判定與其他行和沒有 key 9 時逐字相同** | 讓 key 9 解析錯誤往上傳 → FAIL |
| T-A4 | 現有 statuspage 全部測試向量加上 key 8 / 9 → 結果不變（證明 F27） | Answer 解析加嚴格未知 key 檢查 → FAIL |
| T-A5 | 名單沒有 key 7 → 沒有登記；名單更新加上 key 7 → 顯示名稱；被移除 → 不明節點；不明節點有「可能是剛加入…」小字 | 同一組 key 9 只換名單作對照 |
| T-A6 | 兩個方向：(a) N 的 `exact_keys` 收含 key 7 的名單、申請與更新步驟；(b) N−1 的規則（`&[6]` / `&[1..6]`）解析同樣資料 → 拒收（記下舊 app 字句）；(c) `WRITE_MESH_ADDR = false` 時，S1 / join2 / 申請產生的物件都沒有 key 7；N 的網主核准帶 key 7 的申請 → 名單沒有 key 7（A2-m3）；全隊區不顯示 | (b) 本身是舊版對照；(c) 常數打開 → 物件有 key 7 → 測試 FAIL（證明開關有效） |
| T-A7 | 卡片字句：seen-ago 59 / 60 / 61 s、3599 / 3600 s；throughput 999 / 1000 / 3999 / 4000 kbit/s 邊界 | 門檻改掉 → FAIL |
| T-A8 | 多一次 status 讀：stub 回 E_RATE 再 OK → 等一次後拿到 key 8；E_RATE 兩次 / E_BUSY / 沒有 key 8 → 不填 key 7 且流程繼續完成 | 讓錯誤中止加入流程 → FAIL |
| T-A9 | 全隊區、核准、匯入的各路徑跑完後掃 app log（Rust 與 Dart 的 log 輸出）與 §7 的 (1)–(4) 輸出 → N 裡沒有哨兵位址 | 加一行印位址的 log → FAIL |
| T-A10 | `WRITE_MESH_ADDR == false`（N 的版本綁定，B2-m1）；N+1 必須在 diff 裡刪掉它 | 常數改 true → FAIL |

### 10.3 上機（04 + 02，兩支手機：一支網主、一支成員；N+1 建置）
| # | 測什麼 | 負對照 |
|---|---|---|
| H1 | 兩台組網：兩支手機都看到對方節點「在線」+ 名稱 + 連線品質 | 用 N 建置 → 名稱全是「沒有登記網路位址」；連舊 image 的節點 → 「看不到全隊狀態」 |
| H2 | 02 關機 → 04 那邊 ≤ 75 s 變離線、seen-ago 遞增；開回來 → 在線 | 關機前的「在線」 |
| H3 | 04 重開 → 表歸零、02 在 15 s 內回來；key 8 不變 | 重開前的值 |
| H4 | 04 `network restart` → key 9 短暫不在、之後恢復且 02 的紀錄還在 | — |
| H5 | 手機換連 02 → 標題與內容是 02 看到的 | — |
| H6 | §9 C9 成本 | 取樣關閉的同時段 |

常規全套：「組網後兩台互見、`status` 回答 ≤ 8192 B」的斷言照 #290 規則**另開 harness PR 先進 main**。

## 11. 最小修改清單

節點（`feed/batman-prov/src`）：
1. `node/peers.go`（新）：背景取樣（每 15 s；絕對路徑、不經 shell、5 s 逾時殺 group、64 KiB 上限；`-n` 文字；逐列 regex；自我檢查）+ RAM 表（32、決定性淘汰）+ key 8（依 driver 選 phy）；不 log 位址。
2. `node/status.go`：`status.get` 加 key 8、key 9（兩個角色都給；60 s 新鮮度）。
3. `docs/design/219-protocol.cddl` / `219-protocol.md`：§4.1、§4.2 的增補；key 7 / `team-entry` / scope team 標退役。
4. `docs/design/254-p3-impl.md` §11 checklist：`status` team 改指向本文件。

App（`app/`）：
5. `batman-proto`：`teamview.rs`（新，純函式：key 9 + 名單 → 卡片，含重複規則）；`netrec.rs` / `mrec.rs` 的 key 7；`approve.rs`、`mupdate.rs` 的 `exact_keys` 加 7；S1 / join2 / 申請的 key 8 讀取與寫入（`WRITE_MESH_ADDR = false`）。
6. `bridge`：全隊卡片交給 Dart。
7. `lib/member_ui.dart`：`StatusPageView` 最下面加「全隊」區。
8. N+1：只把 `WRITE_MESH_ADDR` 改成 true（同時打開寫入與全隊區）並刪掉 T-A10（使用者依 §4.3 的安裝紀錄確認手機都 ≥ N 後 merge）。

不改：provd、BLE / Noise、角色表、節點的名單處理、狀態頁 v8.1 判定表、節點清單頁、簽章標籤。

## 12. 只有使用者能決定的問題

1. 「最後看到」在 helper 重啟時也歸零（T3，少見）— 可以嗎？還是要多一個 `/var/run` 檔撐過 helper 重啟？

（v1 的 Q1 成員看得到位址 / 位置、Q2 身分可被假冒，已由 U1、U5 決定。v2 的 B-m3 位置推論同樣由 U1 決定。）

## 附錄 R1. 第 1 輪審查處理（v1 8701e42 → v2）

| # | 發現 | 處理 |
|---|---|---|
| A-M1 | BATMAN_V 沒有 TQ | F32、F33；key 3 = throughput（kbit/s，C1 定單位）；門檻、T-A7、C1、S5 跟著改 |
| A-M2 | 新舊 app 混用：加入雙向失敗、舊成員拒收移除成員更新而掉出 mesh | §4.3 兩版上線（N 只收、N+1 才寫，閘門 = 使用者確認手機都 ≥ N）；矩陣加列；T-A6 兩方向 + 開關 |
| A-M3 | 入網前沒有 mesh netdev | F31；key 8 = 依 driver 選的 phy 永久 MAC；⚠️「== originator」列 C2，推翻 → S1 備案；§9 分 9.1 / 9.2 |
| A-m1 | key 8 兩角色都給、拿掉 provd 改動 | §4.1、§11（provd 不改）；T-N3 簡化成 helper 單元測試 + 自己的負對照 |
| A-m2 / B-m1 | T-N3 層次 | 同上，只剩 helper 一層 |
| A-m3 | 新加入的遠端成員在別人名單裡還沒有 | 矩陣加列；不明節點加小字；T-A5 |
| A-m4 | 多一次 status 讀的位置與錯誤處理 | §4.2「多一次 status 讀」；T-A8 |
| A-m5 | C2 要含 `batctl if` / 兩個 hard-if | C2 |
| B-M1 | 不可 parse bat-hosts 翻譯過的輸出 | §4.1「取樣的輸入」：`-n` / JSON、固定 meshif、逐列 regex、壞列只丟該列；T-N7 |
| B-M2 | 重複位址 | 兩項都不登記（網主重簽）+ 讀的一方也當沒有；T-A2 |
| B-M3 | 逾時、輸出上限、log 無位址的測試 | T-N8、T-N9、T-N10、T-A9（各有負對照） |
| B-m2 | 灌包擠出在線隊員、平手規則 | §4.1 誠實界線 + 位址由大到小先丟；T-N2(b) |
| B-m3 | 位置推論 | 使用者決定 U1（接受） |
| B-m4 | 中性字眼 | U6；「未確認身分」改成「沒有登記網路位址」，標題加「僅供參考」 |
| B-m5 | §9 停止條件 | §9.3 S1–S5 |
| A 的第 6 個 MINOR | §9 的擷取順序 | ✅ 已由 §9.1 / §9.2 的分段處理 |

## 附錄 R2. 第 2 輪審查處理（v2 0871ce4 → v2.1 FROZEN）

| # | 發現 | 處理 |
|---|---|---|
| A2-m1 | 執行期自我檢查；C2 擷取 uci macaddr 與 HaLow phy 上每個 vif | §4.1 key 8 列（MainIF/MAC ≠ phy MAC → 不送、log 一次、之後計數）；C2；T-N11 |
| A2-m2 | N 的半成品全隊區 | 選項 1：全隊區也藏在 `WRITE_MESH_ADDR` 後面；§4.3、§6 開頭、§11-8 |
| A2-m3 | N 網主丟掉 N+1 加入者的 key 7 | §4.3、矩陣「N+1 加入者 × N 網主」、T-A6(c) |
| A2-m4 | N+1 閘門的輸入存不存在 | 不存在（app 沒有可分辨的版本）→ 閘門用安裝紀錄（APK sha256）；§4.3 附行號 |
| A2-m5 | F33 只證明鄰居 / MainIF 是晶片 MAC | F33 改寫；originator 仍待 C2 |
| A2-m6 | S1 備案只對 N+1 | §9.3 S1 |
| B2-m1 | 閘門是人工的；「N 關著」要綁版本 | §4.3 誠實界線 + T-A10 + 發佈前的 `git show` 檢查 |
| B2-m2 | 帶成員紀錄出手機的路徑 | §7 列 (1)–(6) 與隱私變化；T-A9 掃 (1)–(4) |
