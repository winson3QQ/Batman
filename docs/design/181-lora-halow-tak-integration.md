# HaLow × Meshtastic/LoRa × TAK 整合設計(全集合 superset)

狀態:**REV2 — SOUND-WITH-CHANGES**(2026-09-26,已納對抗式 review + 使用者拍板)。相關單:#181、#219、#162、#54、#89/#116、#95、#48/#13、#177、#174、#92、#170。

---

## 0. 目標與非目標
**目標**:三張網協同 + 單一操作介面。HaLow(~9Mbps)=主資料網(全 SKU 底座);Meshtastic/LoRa(~1kbps,台灣 TW 920–925MHz)=遠距生存/備援層(C2·C3·T2);TAK(OTS+ATAK)=態勢/指揮 overlay(戰術專屬,民用 Pi3A+ 跑不動)。單一 provisioning/操作 app(#219),capability-driven。
**策略**:全集合 superset,先做全功能,SKU 細分之後再考量。
**非目標**:SKU 定價/BOM 最佳化、認證合規(#93)、fleet 規模化。

## 0.1 已拍板決策(2026-09-26)
1. **部署=台灣** → LoRa `region=TW`(920–925MHz);**HaLow 也改 TW 域**(現跑 US=合規缺口 #92)。在台設 US 發射=違法。
2. **RAK 接 Pi(USB 資料+供電)** → 分離節點(舊 A1)出局,**co-site 同頻干擾必須正面解**。
3. **固定 gateway 站 = (a) 也開 HaLow** → **統一拓撲:所有 gateway 都 HaLow+LoRa 同機 = co-site 無所不在,無逃生口**。
4. **A2 outbound mTLS 採用**:橋像 TAK client,帶憑證主動連出 OTS 8089(重用 #170 已通的 SSL CoT),不暴露 broker,訊息帶橋身分。
5. **LoRa 逐台認證採用**:PKC per-node 金鑰 + 橋只轉白名單公鑰 + enrolment 登記。
6. **A3 QR secret 採用**:機殼 QR 帶一次性密鑰,gate enrolment 與 set-key。

## 0.2 頭號風險(命門)+ 主要緩解方向
**台灣合法帶只有 ~5MHz(920–925),HaLow-TW 與 LoRa-TW 都在此段**。co-site 決策 2/3 使兩 radio 必同機。
**緩解 = 切頻 + 切時(使用者定調),HaLow 保 default 4MHz**:
- **切頻**:LoRa 極窄(250kHz)放 5MHz 邊角、HaLow 4MHz 壓另一端(隔 ~1MHz);讓 LoRa 前端可加濾波擋 HaLow(同頻無法濾)。代價:4MHz 只留 ~1MHz 給 LoRa+guard,分離度小→濾波/隔離效果較弱→更靠切時補。
- **切時(HaLow 活動閘控 LoRa)**:HaLow 在發→LoRa 該段當垃圾丟(CRC 自動 fail,免費)且不發;HaLow 空檔→LoRa 才收發。HaLow 保 4MHz。
**物理坑**:HaLow +22dBm 距 LoRa RX(~−130dBm)數十cm → 鄰頻強訊 blocking-desense,不同頻未必全免 → 需 ①切頻 ②LoRa 濾波 ③天線隔離 ④切時 疊加。
**切時的兩個硬現實**:(1)**LoRa 封包慢(LONG_FAST 一包 airtime ~0.5–1.5s)**,HaLow 忙時空檔短→塞不進→LoRa 餓死/高延遲,且撞上本機 HaLow TX 的**入站 LoRa 封包掉包**(best-effort PLI 不重傳);掉包率∝HaLow 忙碌度。(2)**「LoRa 知道 HaLow 在發」非免費**:LoRa listen-before-talk 只聽自己頻率,聽不到別頻 HaLow。
**切時的兩個實作變體**:
- **A. 緊耦合(逐 HaLow 封包即時)**:需**硬體共存線**(HaLow PA 腳位→RAK GPIO)+ 支援外部忙碌輸入的韌體。**MM6108 無 coex/PTA + stock Meshtastic 無外部忙碌輸入**(#181)→ 兩邊改韌體+牽線,工程重。**⚠️ CLI/serial 做不到即時閘控**:HaLow 毫秒級切 vs CLI 一來回數十~數百 ms + `tx_enabled` 是寫 flash(慢+磨損)+ stock API 無即時靜音指令 → 追不上。
- **B. 粗略軟體排程(先試,純軟體)⭐**:**LoRa 生存流量稀疏(PLI ~30s/次),不需連續存取,只需偶爾乾淨窗口** → Pi 定期短暫靜音 HaLow(降 interface/power-save)給 LoRa 窗口。不用改韌體/牽線;代價=週期性小幅打斷 HaLow + LoRa 只週期存取。可行性看:能否乾淨短暫靜音 HaLow(Linux 對 802.11ah 控制粒度)+ 稀疏流量是否夠。
**W10 兩層測(HaLow default 4MHz)**:①**被動層(先)**=切頻+濾波+隔離,量 HaLow 忙時 LoRa 剩餘靈敏度;②**主動層(若被動不夠)**=切時協調,先確認共存訊號來源,量各 HaLow 負載下 LoRa 掉包率/延遲。**仍硬 go/no-go**:四招疊加後 LoRa 仍不可用才回架構層。

---

## 0.3 共存範式:managed cross-radio QoS 調度(不是被動共存)
**兩張網的機器/韌體都是我們的 → 不把 HaLow 當未知干擾被動閃,而是自己訂收發規矩。** 目標函數 = **在滿足語音(PTT)+ 數據體驗門檻下,調度 HaLow/LoRa 收發**。優先級:**①PTT 語音(即時,保護絕不讓路)→ ②互動/大數據(彈性,可被小讓)→ ③LoRa 生存流量(稀疏 PLI~30s + 可容忍延遲,窗口從閒置/大數據空檔切出)**。LoRa 節奏也我們控(PLI 間隔、限約定窗口發)→ 切時 = 排自己已知流量,非反應未知干擾 → **大幅降低對硬體共存線(切時變體 A)的需要**,純軟體策略調度(變體 B)即在排自己的東西。
**殘留**:①切 HaLow 安靜窗口的機制(Linux 佇列層粗略可做;精準需 driver/韌體;TWT 在 mesh vif 死 #181)②連續語音期間 LoRa 多等(可容忍)③入站撞本機 HaLow TX 仍掉包,除非全隊窗口時間同步(#174/#177)——per-node 減輕不全消。

## 0.4 兩網流量模型 + 可調旋鈕(排調度 / 算 airtime 的輸入)
**HaLow idle 也不安靜(週期地板)**:beacon ~1/s + batman **OGM ~1/s** + ELP 次秒級;短、低佔用(~百分之幾 airtime)但**週期性**。加入時另有 auth/assoc/probe。資料層:TAK CoT、**PTT 語音(講話時連續)**、照片/影音。native 規則:CSMA/CA 聽了再發 + **WMM QoS(語音 AC_VO 可優先)**;OGM/ELP 是無 ACK 廣播、洪泛。
**LoRa(本卡實測值)**:PLI `position_broadcast_secs=900`(移動 smart~30s)、NodeInfo 10800s(3h)、telemetry~關、文字零星;**每包 airtime ~0.5–1.5s**;**managed flooding**(hop=3、packet-id 去重、SNR 差者先轉發 → 放大)、發前 CAD、airtime 自限。`rebroadcastMode=ALL`。
**關鍵**:HaLow **週期心跳(~1/s)** vs LoRa **長包(0.5–1.5s)** → **即使 idle、使用者沒傳任何東西,一次 LoRa 收包幾乎必 overlap 1–2 個 beacon/OGM**;會不會壞看被動層(切頻+濾波)能否讓 LoRa 對這些 off-freq 心跳免疫。
**可調旋鈕(我們制定規矩的槓桿)**:
| 旋鈕 | 網 | 作用 |
|---|---|---|
| `beacon_int` / `orig_interval`(OGM) | HaLow | 降週期心跳、拉長乾淨空檔(代價:收斂慢) |
| **WMM AC_VO 保護語音** | HaLow | 語音永遠優先(調度核心) |
| `position_broadcast_secs` / smart | LoRa | 控 LoRa 稀疏度(拉長=更好共存) |
| `hopLimit` / `rebroadcastMode` | LoRa | 限洪泛放大;**gateway 可設不轉發,只收→上橋**(避免一邊 RX 遠方一邊忙轉發) |
| airtime cap | LoRa | 封頂 LoRa 佔用 |

## 1. 架構原則
1. Radio 分工:HaLow=主資料/PTT 語音;LoRa=遠距文字+PLI 生存層;TAK=CoT overlay 匯流。
2. 橋接在 **L3/CoT**,不在 L2。
3. **gateway ≠ OTS host**;但**不靠暴露 broker 達成**,而是 gateway **outbound mTLS 連 OTS 8089**(決策 4)。
4. **三層退化**:Tier 0(server-free,ATAK 外掛手機↔手機 CoT)→ Tier 1(gateway mTLS→OTS)→ HaLow 覆蓋內完整 CoT。**退回機制要具名,不寫「自動」**(ATAK 不會自己切;需明確偵測+重配或人工)。
5. **雙端認證信任鏈**:LoRa 端逐台(PKC 白名單)→ 橋(mTLS 憑證)→ OTS。**誠實界線:RF 層擋不住有 PSK 的流氓發射/jam;認證=信任准入(橋這關擋),非 RF 物理排除。**
6. **可信時間**:TAK X.509 憑證有效期驗證需時鐘;節點無 RTC(#174)→ 信任設計必納 trusted-time(fake-hwclock/GPS/RTC)。
7. capability-driven 介面:app 依裝置能力位元只顯示該有控制。

---

## 2. 工作流(workstreams)

**W1 — Meshtastic 控制基座 → 產品化**(基礎)。容器 CLI 已可控;**要變常駐 service**(非一次性 docker run)+ udev 穩定命名(ttyACM 重插會 re-enum)。依賴:無。

**W10 — co-site 頻段共存 go/no-go**(最先、命門)。目的:量「同機 HaLow+LoRa」LoRa RX 被 HaLow TX 壓多少。**正確認知:HaLow 高工作週期 TX 是加害者,LoRa 敏感 RX 是受害者**(原 txEnabled tier-switch 方向錯)。**測的配置 = 切頻 + 切時,HaLow default 4MHz**(見 §0.2)。**被動層先**:HaLow 4MHz 壓一端 + LoRa 250kHz 放另一端(隔 ~1MHz)+ LoRa 前端濾波 + 天線隔離,量 HaLow 忙時 LoRa 剩餘靈敏度/距離。**主動層(若被動不夠)**:切時。**先試變體 B(純軟體粗略排程:Pi 定期短暫靜音 HaLow 給稀疏 LoRa 窗口,不改韌體)**;不夠再變體 A(硬體共存線 HaLow PA→RAK GPIO + 改韌體)。**CLI/serial 即時閘控不可行(太慢+寫 flash)**。量各 HaLow 負載下 LoRa 掉包率/延遲 + HaLow 被打斷的代價。可掃 HaLow 4/2MHz 看用主網頻寬換 LoRa 空間的取捨。**乾淨 2-radio 無 OTS 節點量(非三重身分 04);可控可重複 RF setup**;含 **airtime 預算分析**(輸入=§0.4 流量模型)。**由下而上基準測**:①**純 idle**(無使用者資料/語音,只有 HaLow beacon+OGM 週期心跳,量 LoRa 收包錯誤率 PER)——idle 就壞=被動層擋不住心跳=最壞信號;②加數據負載;③加 PTT 語音負載。**目標函數(見 §0.3)= 在真實 語音+數據+LoRa 混合負載下,量 PTT 語音延遲 / 數據吞吐 / LoRa 掉包率是否都在體驗門檻內**(不是只量被動共存)。依賴:W1 + 2nd RAK + region=TW。**managed 調度 + 四招疊加後 LoRa 仍不可用 → 回架構層。**

**W4 — Tier 0 server-free 驗證**(獨立)。兩台 Meshtastic + 手機 ATAK+外掛,role TAK/TAK_TRACKER,CoT 手機↔手機。依賴:2nd RAK + region=TW。

**W2 — LoRa→TAK 橋(A2)**。**獨立 gateway 程式**(非 OTS 內建 MQTT=會重新耦合),**outbound mTLS 連 OTS 8089**;**只轉白名單公鑰的訊息**;CoT 蓋 gateway 身分 + 標「經 LoRa」provenance。依賴:W1 + W9-min + W13。~~舊 W3 暴露 broker 已刪除~~。

**W13 — LoRa enrolment & PKC**(新)。每台生成 PKC 金鑰(現 publicKey 空);**公鑰註冊進車隊白名單**;QR secret(A3)gate 登記。餵 W2 白名單 + W7 app。依賴:W9-min。

**W9 — 信任橋接**(提前,不拖尾)。**最小決策提到 Phase 2**:gateway 憑證身分、白名單方案、QR secret、trusted-time(#174→TAK X.509)。完整版(車隊金鑰生命週期、撤銷)後續。依賴:貫穿。

**W6 — Pi BLE(BlueZ)+ 發現**。**不透明廣播**(rotating service UUID,不播能力/身分=OPSEC);能力經**配對後認證 GATT** 讀(iOS 背景本來也讀不到廠商資料)。依賴:build infra #73。

**W8 — HaLow set-key 端點**。onboarding AP 加**認證過**的 set-key(**QR secret gate**,A3);對接 #54/#137。依賴:W6/W13。

**W5 — Meshtastic fleet firmware**。`pio run -e rak4631`→`firmware.uf2`,pin 版本,region=TW 預設。**單槽無 A/B → 分階段 rollout(1 台→soak→fleet)、只在實體接觸時推**(#89/#116)。依賴:無(現韌體可先用)。

**W7 — 統一 app(#219)**。BLE 發現→能力驅動 UI→三域設定 + 角色指派 + enrolment(登記公鑰)。依賴:W6+W8+W1+W13+OTS API。

**W3-footprint — Pi3A+ 512MB 資源閘**(新,MAJOR)。superset 只在 Pi4/04 驗過;**驗 Pi3A+ 能同時扛 batman+HaLow+BlueZ+LoRa gateway+CoT forwarder 的 RAM**。依賴:W2/W6 元件就緒。

**W11 — 固定 LoRa gateway 站(T0+LoRa)**。決策 3=**也開 HaLow → 仍 co-site**(不逃生);價值在「永遠在、不會走」的橋穩定性,非避干擾。依賴:硬體 + W2。

**W12 — 去重 + 迴圈防護**。多 gateway 同封包去重(LoRa packet-id);**另加 CoT↔OTS republish 迴圈防護**(不同層,m3)。依賴:W2 + W7。

---

## 3. 依賴圖 + 實作順序

```
Phase0  W1 產品化 + 採購/provision 2nd RAK + region=TW + HaLow 改 TW
Phase1  W10 co-site go/no-go(乾淨2-radio,含 airtime)  ‖  W4 Tier0 server-free   ← 命門閘,先打
Phase2  W9-min(gateway 憑證/白名單/QR/trusted-time) → W13 enrolment → W2 outbound mTLS+白名單
Phase3  W6(不透明廣播) + W8(QR-gated set-key) + W5(分階段 firmware) + W3-footprint(Pi3A+)
Phase4  W7 統一 app → W12 去重/迴圈防護
Phase5  W11 T0+LoRa 固定站(仍 co-site)
```

**理由**:Phase 1 先打**命門風險**(W10 同機同頻 + W4 生存層獨立)——**W10 no-go 則後面全部無意義**。Phase 2 信任提前(修 review B3 循環)+ 雙端認證橋(A2)。Phase 3 發現/provisioning 地基 + Pi3A+ 現實閘(修 M3)。Phase 4 app。Phase 5 固定站硬體。

---

## 4. 開放決策 / 殘留風險
1. **co-site 命門(W10)**:台灣 5MHz 窄帶 + 無逃生口 → 若不可容忍,需回架構(如犧牲 LoRa 有效距離/嚴格時序/接受手持 co-site 手持而固定站另想辦法)。**這是唯一可能推翻全案的點。**
2. **HaLow 改 TW 域**的實作與相容(#92);與 LoRa 同擠 920–925 的頻率規劃(能拉多開)。
3. **車隊金鑰生命週期/撤銷**(W9 完整版):白名單怎麼更新、撤銷失竊節點公鑰。
4. **Pi3A+ footprint**(W3-footprint)若不足 → 民用線功能要砍或換板。
5. **Tier-0 退回機制**具名(誰偵測 OTS 掛、怎麼重配 ATAK)。
6. **trusted-time** 來源(fake-hwclock vs GPS vs RTC,對接 #174,戰術才有 RTC/SE)。

## 附錄 A：W10 第一步 — idle 被動基準實驗(分頻)
**問題**:分頻後,同機 idle HaLow 心跳(beacon+OGM)還會不會打壞 LoRa 收包?
**判準**:比「HaLow 關」vs「HaLow 開但 idle」下 LoRa 的 PER/SNR;接近=分頻+濾波讓 LoRa 對心跳免疫(過);差很多=心跳就擋不住。
**節點**:U=同機 HaLow+RAK(LoRa RX);L=**第二顆 RAK**(固定距離發序號封包,**硬前置,缺**);H=HaLow 對象(02 或 U 自身 beacon)。
**分頻(TW 920–925)**:LoRa `region=TW` 放上緣(~924.x);HaLow TW 域放下緣;第一輪先窄 HaLow(1–2MHz)拉最大間隔(~2–3MHz)確認概念,再加寬到 4MHz(間隔~0.7MHz)看極限。HaLow 需從 US ch40 切 TW 域(動 mesh,在測試節點做)。
**量測**:Meshtastic **Range Test 模組**(L 發序號、U 記收到序號+SNR/RSSI → PER)。A=HaLow down 參考、B=HaLow idle;Δ=idle co-site 傷害。過了再:縮間隔→加濾波→加數據→加語音。
**單卡 proxy(等第二顆 RAK 前,只有一顆時)**:U 設 region=TW,量 RAK 背景 channelUtilization/噪音底,比 HaLow 關 vs idle;若 idle 抬高=blocking 早期證據。**限制:channelUtilization 是粗略 RX-busy proxy,非 PER;且現 HaLow 在 US ch40 未刻意對 TW 分頻,故只是粗略首探。**

## 附錄 B:進實際設計階段前的特性實驗清單 (P1–P7)
思路 = 建 co-site 特性矩陣;每個實驗解鎖一個設計決策。矩陣維度:HaLow 狀態(off/idle/loaded)× 鏈路餘裕(強/邊緣)× 頻率分離 × HaLow BW × 緩解(切頻/濾波/切時)× 方向(HaLow→LoRa / LoRa→HaLow)。

| # | 實驗 | 解鎖的決策 | 現有平台可跑? |
|---|---|---|---|
| **P1** | **邊緣鏈路 co-site**(降 TX 功率把 SNR 壓到接近門檻,量 off/idle/loaded PER) | **co-located 雙 radio 吃掉多少 LoRa 距離 = 真正的 go/no-go** | **✅ 可**(用降功率模擬邊緣鏈路的電性行為;唯**真實長距野外**需移動節點,現不行,但電性邊緣可模擬) |
| **P2** | 頻率分離掃描 + 前端濾波(LoRa 近/遠 HaLow) | §0.2 切頻計畫 + 濾波器 BOM | ✅ |
| **P3** | 切時排程原型(軟體 HaLow 靜音窗口) | §0.3 切時軟體夠不夠 vs 需硬體共存線 | ✅(純軟體) |
| **P4** | HaLow BW 取捨(4/2/1MHz) | HaLow default BW | ✅ |
| **P5** | 反向 LoRa TX→HaLow(量 HaLow tput/BLER) | 排程要不要雙向 gate | ✅ |
| **P6** | 天線隔離(分離度/朝向) | V3 enclosure 實體佈局 | ⚠️ 需實體移天線 |
| **P7** | 語音(PTT)在 co-site 下延遲 | §0.3 排程驗收門檻 | 需先有 PTT stack |

**判斷「夠進設計」= P1+P2+P3(+P5)**;P4/P6/P7 為細化。**非實驗前置:W5 韌體統一或釘頻率**(否則重開/測試台不穩)。

### 本 session 已取得(2026-09-26,manet04+02,10m,region=TW,override_freq 921.0)
- **idle A/B**:LoRa SNR HaLow-off **+5.78** / idle-on **+4.93**(co-site 溫和,~1dB + 增變異)。
- **loaded 預覽**(iperf 灌 HaLow ~7.6Mbps):LoRa SNR **≈+1**(比 idle 再掉 ~4dB)→ **負載下 co-site 明顯較重**(僅少量樣本,完整 loaded soak 因下述硬體事故中斷)。
- **量測法**:sender 發自訂長度文字(`LLL:SSSSS:`+X padding,可驗內容+序號→真 PER 按序號去重);receiver 抽 `msg=`+`Lora RX len=`;HaLow 端 `iw station dump`(signal/MCS/retries/failed)+`morse_cli stats`(retry 表)+temp。
- **⚠️ 硬體事故 + 教訓**:對 ttyACM0 上程序 **kill -9(打斷 USB 交易)會 wedge RAK 的 USB**(`can't set config, error -110`),host 端 authorized-toggle/unbind-rebind 都救不回 → **需實體重插/RST**。**教訓:控 RAK 的程序用溫和 kill(TERM)或設 timeout,勿 kill -9 於 USB I/O 中;長跑用內建定時而非外部強殺。**
- **遠端救援不可行(本硬體實查)**:中繼 hub = **ganged power switching(不能分埠斷電)**、無 uhubctl / 無 per-port sysfs 斷電、Pi4 內建埠不支援分埠斷電;`authorized` toggle 只邏輯斷線(RAK 仍有電,清不掉僵局)→ **必實體重插/RST**。
- **watchdog 缺口**:nRF52/Meshtastic 有 watchdog 但**只盯主迴圈**;此次主迴圈仍活(照收 LoRa/餵狗),**只 USB 子系統僵** → watchdog 不觸發。需韌體加 **USB-health watchdog**。

### 設計要求(野外韌性,新增):RAK 需「可軟體復原」
現成 kit 沒有;要「節點自我復原、不派人」須擇一/組合:①**支援 PPPS 的 USB hub**(host 可分埠 power-cycle RAK)②**GPIO 控 VBUS 負載開關**(斷 RAK 電重來)③**GPIO 接 RAK RST 腳**(pulse 重置 MCU)④**韌體 USB-health watchdog**。**⚠️ 實測(無電池):遠端軟體無法 power-cycle RAK**。此 hub 宣稱 ganged power switching 但 **kernel port disable 只做邏輯斷線、沒真的切 VBUS**(廉價 hub 通病:宣稱有電源開關卻沒實作)→ RAK 全程有電、韌體從沒重開 → USB-API 僵局清不掉。authorized-toggle / unbind-rebind / ganged 全埠 disable(含 30s)/ 1200bps-touch 全試過都救不回 → **需實體 RST 鍵或拔 USB**。**故野外自癒可靠手段 = GPIO→RST 腳(最直接),或用「真的會切 VBUS 的」電源開關/PPPS hub(本 hub 的軟體電源開關無效),再加韌體 USB-health watchdog。** 對接 V3 enclosure/BOM 與 #67 EMS 自癒。另:大量 serial 擷取**勿寫 /tmp(tmpfs/RAM,會撐爆害 docker 掛)**,要寫 p6 並過濾/rotate。

## 5. 驗證方針
- 每 workstream 黑箱/白箱,能上機就上機(乾淨節點,非三重身分 04),證據附原始輸出。
- 可回歸的併 `daily-validation.sh`(gateway CoT round-trip、co-site tput delta〔需可控 RF〕、白名單拒絕未登記公鑰)。
- W10 是硬 go/no-go:未過不進 Phase 2+。
