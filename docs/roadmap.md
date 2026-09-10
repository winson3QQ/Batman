# Roadmap v1 — 韌性與去中心化（Resilience & Decentralization）

> 第一版 roadmap。列出「目前系統缺什麼」，之後的工作照這裡的優先序做。
> 每一項都對應一張 GitHub issue（見下表）。GPS/PTT 與供電擴充是**另一條**線，見
> [`expansion-gps-ptt.md`](expansion-gps-ptt.md)。

## 心智模型（先建立整個畫面）

把網路想成**一群背著無線電、彼此接力傳話的哨站**。每台 Pi = 一個哨站。

```
        哨站A )))  無線電接力  ((( 哨站B ))) ((( 哨站C
         |                        |
      有線網路孔(eth0)          有線網路孔(eth0)
```

- **mesh（網狀網路）**：沒有基地台、沒有總機，哨站平等互傳。
- **batman-adv**：每台裡的「送信大腦」，自動決定接力路徑；哪台倒了自動繞路（自癒）。
- 傳話分層：① 無線電波通不通（射頻）② 哨站怎麼認得彼此、訊息怎麼接力（batman）
  ③ 每台的門牌 IP ④ 實際應用（對講、管理）。

## 貫穿全表的核心原則

**把「送信」和「管理」分開**（電信業做法：NOC 停機、網路不停）：

| | 是什麼 | 規則 |
|---|---|---|
| **資料面** | 哨站接力送信 | **必須永遠自己運作**，管理系統掛掉也照傳 |
| **控制面** | 看儀表板、改設定 | 可有可無；它掛了只是「看不到」，網路照跑 |

→ 只要守住「**管理系統絕不能變成送信的必要條件**」，就同時拿到韌性與可管理性。

---

## 現況盤點：已有 vs 缺什麼

實機查證日期 2026-08-13（manet01 / batman-adv 2025.4-openwrt）。

### 概念一：新哨站自動加入（門牌 + 參數）
- ✅ 名字 + SSH 金鑰**已**自動從 MAC 衍生（首開 hook `99-halow-identity`）
- ✅ 每台靜態門牌，mesh 幹線不撞、無中央發號單點
- ❌ **門牌（IP）不會自己算** → 燒新卡都撞 `10.41.1.1`，要手動改
- ❌ 無線電參數每台手動跑 `setup-node2.sh`（可改成映像烤一次、燒卡繼承）
- ❌ 沒有 DAD（宣告門牌前確認不撞）
- ⚠️ client 門牌靠單一節點 dnsmasq 發號（潛在單點）

### 概念二：抗干擾 + 防內部塞爆
- ✅ batman 自癒、天生防典型「繞圈無限繁殖」
- ❓ **BLA（防繞圈開關）是否開啟未確認** — eth0 已橋進 `br-ahwlan`、STP 關 → **最急的未知引信**
- ❌ 廣播沒有「節流管理員」（IGMP querier）→ 吵設備喊話吃頻寬
- ❌ 無線電只有單一頻道、不會自動換頻躲蓋台
- ❌ 沒有把大廣播域切小 / 隔離 client 的機制

### 概念三：去中心化管理
- ✅ 積木都在：avahi（自報家門）、collectd（記數據）、rpcd/ubus（管理 API）、meshtest（任一台可跑）
- ❌ 沒有「登入任一台就當場彙整全網」的聚合層
- ❌ 沒有簽章配置擴散（統一改設定又防假配置）

### 貫穿全部的共同大洞：成員認證
- ❌ 「有密碼就能進」，沒有「每台哨站自己的身分」；公開 image + 公開預設 key `CHANGE-ME-NOW` 是洞
- ❌ WireGuard 沒裝（要端到端加密 / 節點身分時用）

---

## 優先序 & Issue 對照

| # | 項目 | 優先 | Issue |
|---|---|---|---|
| 1 | 確認 **BLA** 有沒有開（30 秒、免裝、防「一插就炸」） | 🔴 最急 | [#10](https://github.com/winson3QQ/Batman/issues/10) |
| 2 | **IP 從 MAC 自算**的首開腳本（+DAD）→ 零介入 onboarding | 🟠 高 CP | [#11](https://github.com/winson3QQ/Batman/issues/11) |
| 3 | **廣播治理**：IGMP querier / snooping + 過濾吵設備 | 🟡 | [#12](https://github.com/winson3QQ/Batman/issues/12) |
| 4 | **成員認證** + 堵預設 key | 🔴 安全 | [#13](https://github.com/winson3QQ/Batman/issues/13) |
| 5 | **去中心化管理**：任一節點當總控台（料都在） | 🟢 好做 | [#14](https://github.com/winson3QQ/Batman/issues/14) |
| 6 | **RF 頻率敏捷**（抗蓋台）— 最難最長期 | ⚪ 長期 | [#15](https://github.com/winson3QQ/Batman/issues/15) |
| — | **WireGuard** 安裝 + 預裝 image（MTU=1400，搭配 #4） | 🔴 安全 | [#16](https://github.com/winson3QQ/Batman/issues/16) |

一句話總結缺口：**「自動取名字」有了但「自動取門牌」沒有；「節點壞掉能自癒」有了但「被蓋台 / 被喊話塞爆 / 被外人混進來」都還沒防；「管理的零件」有了但「還沒組成去中心化的總控台」。**

---

## Roadmap v2 — 商品化與安全強化（2026-09-10）

> v1 聚焦「韌性/去中心化」的初盤。v2 疊上**商品化**視角(安全地基、資料保護、
> 供應鏈、CI)並依**依賴關係**重排。安全架構詳見 [`threat-model.md`](threat-model.md),
> 標準/商品化地圖見 [`productization.md`](productization.md)。

### 這次收斂
- ✅ **#10 BLA** 已確認開啟(v1 的「最急引信」拆彈)。
- ✅ 關閉 **#38**(4MHz 節點對節點上限已量測:TCP 9.2–9.3 / UDP 10.0–10.7 Mbps 雙向)、
  **#35**(RTS 維持 1000)、**#34**(Pi500 RX 缺陷,Pi500 已退場故 obsolete)。
- 🅿️ **#46**(HW 去紅化 / NDAA-Quectel 替代模組)**擱置**——無美國市場計畫前不動。

### 依賴排序待辦

| Tier | Issue | 依賴 / 備註 |
|---|---|---|
| **0 現在做** | **#45** SBOM + CVE CI | 無依賴;掃出 FTS 舊依賴 CVE。建議第一個 |
| 0 進行中 | (soak CPU 剖析報告) | 收工後產出 → 餵 RF 調校三張 |
| **1 地基** | **#13** per-device PKI(根 CA 同簽節點+TAK client) | **keystone**,解鎖 #48/#16/#11/#47/#49。建議第二個 |
| 1 | **#47** 資料加密(LUKS+dm-verity+secure element+USB-C/M12 fill) | 軟體面可先架;SE 選型待硬體 |
| **2 建於 #13** | **#48** TAK mTLS(8089,停用明文 CoT) | 需 #13;關聯 #44 |
| 2 | **#11** zero-touch provisioning + PKI 入網 | 需 #13(v1 的 MAC→IP 是 stage 1) |
| 2 | **#16** WireGuard(標 FIPS) | 需 #13 |
| 2 | **#41** immutable rootfs + A/B OTA + health-gated rollback | 與 #47 分割佈局重疊;野外升級關鍵 |
| **3 監控/韌性** | **#14** 去中心化健檢 console(alfred) | 是 #49 的基礎 |
| 3 | **#49** 節點行為偵測 + quarantine | 需 #14;吃 morse_cli/batctl |
| 3 | **#15** 頻率捷變 | 唯一 PHY 反 jamming(從長期提前) |
| 3 | **#12** 廣播治理 | 觀察項,client 變多再啟用 |
| **RF 調校** | **#40** beacon_int / **#37** A-MPDU / **#39** 8MHz | 等本次 soak 數據;#38 已完成可接 #39 |
| **產品完成度** | **#44** TAK server on manet02 | 留著,待修 DataPackage 8080 撞埠 |

**Critical path:** `#45 → #13 →(分叉)#48 / #11 / #16`,`#41` 平行;`#14→#49`、`#15` 隨後;
RF 三張等 soak 報告。

### 兩條並行 track(工作分組)

兩組性質不同、可並行。**目前順序:先 M1(mesh resilience & RF),後 M2。**

**M1 · Mesh resilience & RF** — 讓 mesh 健康 / 被防禦 / 被調校(**先做**)
- #14 去中心化健檢 console(alfred)
- #49 節點行為偵測 + quarantine
- #15 頻率捷變(反 jamming)
- #12 廣播治理
- #40 / #37 / #39 RF 調校(等本次 soak 報告)

**M2 · Secure node + TAK** — 讓節點可信 / 可交付 / 安全
- #13 per-device PKI(keystone)
- #48 TAK mTLS · #44 TAK server · #11 provisioning · #16 WireGuard/FIPS
- #47 資料加密(LUKS+dm-verity+SE)· #41 immutable+A/B · #45 SBOM/CVE CI

唯一軟連結:**#49 的撤銷(revoke)要用 M2 的 #13 PKI**;但 #49 的偵測靠 #14 可先做
→ M1 除 #49 收尾外可獨立推進,不必等 M2。

---

## 名詞速查

| 術語 | 白話 |
|---|---|
| 節點 / node | 一個哨站（一台 Pi） |
| mesh | 沒有總機、大家平等接力的網 |
| batman-adv | 每台裡的「送信大腦」，會自動繞路 |
| IP 位址 | 門牌號碼 |
| MAC 位址 | 設備出廠的唯一身分證號 |
| DHCP | 中央發門牌的櫃台（去中心化要避免） |
| SPOF | 一垮全垮的單點 |
| DAD | 用門牌前先問「有人用嗎」 |
| SLAAC / ULA | IPv6 自己算門牌 |
| jamming | 外人蓋台，塞滿你的頻率 |
| 頻率敏捷 | 被干擾就自動換頻道 |
| 廣播 / 廣播域 | 對全網喊話 / 喊話能傳到的範圍 |
| 橋接 bridge | 把無線和有線併成一個大房間 |
| 廣播風暴 | 喊話繞圈無限繁殖塞爆全網 |
| STP / BLA | 防繞圈機制（STP 通用 / BLA 是 batman 版） |
| IGMP querier / snooping | 群發訊息的「節流管理員」 |
| mDNS / avahi | 設備自報家門（`xxx.local`） |
| collectd | 記錄健康數據的小工具 |
| gossip / CRDT | 街坊口耳相傳同步 / 讓大家最後一致的結構 |
| 資料面 / 控制面 | 送信（不能停）/ 管理（可有可無） |
| WireGuard | 輕量加密專線（VPN） |
| MTU | 一個封包最大裝多少（此網設 1400） |
| overlay | 疊在現網上的加密層 |
| regdomain | 各國法規允許的頻率 |
