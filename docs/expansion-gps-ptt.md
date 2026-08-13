# 硬體擴充規劃：GPS + PTT（沿用現有 K頭配件）

節點硬體：Raspberry Pi 4B + Seeed WM1302 HAT + Wio-WM6108（HaLow SPI），跑 OpenMANET。
目標：讓節點能**收 GPS**、並用**按鈕按下即傳語音（PTT）**，且**沿用現有無線電的 K頭耳麥/托咪**。

---

## ⭐ 2026-08-13 更新：PTT 別自己造，OpenMANET 已內建 comms

實機挖 `openmanetd`（Go app，:8080/8081/8087）確認：**OpenMANET 本身就有完整 PTT 語音子系統**，下面原本的 DIY CM108 計畫其實有官方成品化版（OpenVLM），保留當參考。

**內建 comms 規格**（`/etc/openmanetd/config.yml` 的 `comms` 段，現為 `enable: false`）：
- 編碼 **Opus 48kHz 單聲道 32kbps / 20ms 幀 / adaptive FEC**
- 傳輸 **RTP over 多播 UDP，MTU 1400**（對上 WireGuard 的 MTU=1400、#12 保留的 `239.41.0.0/16`）
- **talk group**（每組一多播位址/埠）、**每組半雙工**（按下講、放開聽）
- **控制源 `controlSource`**：`web`（瀏覽器）/ `openvlm`（USB HID dongle）/ `nanoptt` / 另有 `PttBluetoothInputDevice`（藍牙 PTT 鍵配對到**節點**）
- **API**：`/api/ptt`（PTTEvent）、`/ws/opus`、`/webrtc/ws/opus`、Protobuf；另有 `/api/whisper/*`（STT）

### 兩條實現路線
- **Path A（手機端）**：手機連節點 5GHz AP（`halow-setup`）→ 打 `web`/WebRTC comms API。手機≈web client，甚至可能不用寫 app（瀏覽器開 comms 頁就有 PTT）。要硬體鍵再包薄 app。
- **Path B（節點端硬體，推薦）**：USB 音訊+HID PTT 插節點，`controlSource=openvlm`，零 app、沿用 K頭。

### ⭐ OpenVLM VLM-KW = 「K頭 → USB」（本文原 CM108 DIY 的成品化版）
- 基於 **CM108B USB 音效 + 93C46 EEPROM + GPIO1 strap**（讓 openmanetd 認出「這是 OpenVLM」）；**GPIO3 = K頭 PTT**，走 USB-HID。
- 一端 USB 插節點、一端 **K頭母座（Kenwood 2-pin）** → **你現有 K頭托咪/耳麥直接插**。
- 開源硬體（CERN OHL），repo `PCB/` 有 gerber + Fusion360（批次 `VLMKW0100` 省了音量鍵 + ESD）。

### 兩個 use case → 都收斂到 VLM-KW
| Case | 首選 | 可靠度 |
|---|---|---|
| **#1 一般人 PTT 托咪** | VLM-KW + K頭 speaker-mic → 節點 | ★★★ 有線、無電池、免配對 |
| **#2 戰術小隊 耳麥+PTT** | 每人一節點 + VLM-KW + K頭隱蔽耳機 + 指環 PTT | ★★★ 無 BT/無 WiFi 跳/無手機依賴 |

- 可靠度序：**有線到節點(VLM-KW) > 有線到手機(USB-C PoC，如 RAM RSM-A07) > 藍牙**。
- 藍牙 gotcha：耳麥雙向走 **HFP**（單聲道 ~8–16kHz + 切換破音 + 延遲），比 mesh 的 Opus 48k 差 → 只建議休閒。
- ⚠️ VLM-PT1 外殼官方註明「**非軍規** K頭多數可用」；軍規頭（Nexus/U-174）不能直插，走 Disco32。

### 哪裡買（2026-08-13 現況：都缺貨）
- **VLM-KW 板**：[buildsbyshane.com](https://www.buildsbyshane.com/) $40，**sold out**（限量批），**唯一零售商**。
- **VLM-PT1 外殼**：[sunkworkstec.com/products/sw-vlm-pt1](https://sunkworkstec.com/products/sw-vlm-pt1) $55，**sold out**（僅外殼，不含板/PTT）。
- 其他通路（Tindie/Etsy/eBay）：**無**。
- **DIY**：拿 [OpenVLM repo](https://github.com/OpenMANET/OpenVLM) 的 gerber 去 JLCPCB/PCBWay 打板貼片。想現在就有走這條。

### 驗證計畫（免花錢先做）
在節點開 **comms（web 模式）** + 設一個多播 talk group（用保留的 `239.41.x`）→ 手機瀏覽器連 5GHz AP 實測整條「手機→節點→mesh」語音通不通、延遲可不可接受，再決定買/打板。
> 連動守則：PTT 上線後，#12 的多播過濾器**絕不能**擋到 `239.41.0.0/16`，且 `multicast_mode` 維持泛洪。

---

### （以下為原始 DIY 規劃，保留作參考——OpenVLM 已是其成品化版）

---

## 0. 現況（已在 manet01 查證，軟體大多就緒）

- **GPS**：`gpsd 3.25` 已裝、有 `/etc/config/gpsd`、kernel 有 USB GPS 驅動（dmesg 見 garmin/novatel usbserial 已註冊）。openmanetd 的 GPS 頁直接吃 gpsd。**只差一個 GPS 接收器。**
- **音訊**：`alsa-utils`、`libopus` 已裝；但只有 `bcm2835 Headphones`（**只輸出**），**沒有麥克風輸入**。
- **PTT**：openmanetd 已有瀏覽器 PTT（`https://<node>.local:8081`，需麥克風）。硬體按鈕式要另接。
- 空閒 GPIO（HaLow 佔了 5/8/9/10/11/17/23/24）：**6 / 12 / 13 / 16 / 26 / 27** 可用；UART 14/15（`ttyAMA0`）可給 GPS。

---

## 1. GPS

gpsd 已就緒，只要加接收器 + 在 `/etc/config/gpsd` 指定裝置。

| 選項 | 接法 | 設定 | 適用 |
|---|---|---|---|
| **USB u-blox（首選）** | 插 USB → `/dev/ttyACM0`（或 ttyUSB0），Linux 免驅動 | gpsd device 設該路徑，重啟 gpsd | 測試 / 一般 |
| UART GNSS 模組 | GPIO14/15（`ttyAMA0`） | device 設 `/dev/ttyAMA0`，並關序列 console | 省 USB 埠 |

- 驗證：`gpspipe -r -n 5` 有 NMEA → openmanetd GPS 頁出定位。
- 要**天空視野**（主動天線或近窗）；冷啟動首次定位 30 秒～數分。
- 野外裝殼建議 **NEO-M8N + 外接 SMA 天線**（天線拉到殼頂），比小 puck 的 VK-172 好。

---

## 2. PTT（硬體按鈕 + 語音）

Pi 4 無類比音訊輸入，故：

- **麥克風/喇叭**：加 **USB 音效卡（CM108）**（mic in + 耳機 out），或 USB 手咪/耳麥。
- **按鈕**：輕觸開關接空閒 GPIO（如 GPIO6）對 GND，`gpiod` 讀。
- **傳語音兩條路**：
  1. **接 openmanetd 的 PTT**（若它有節點端硬體 hook；uci 沒看到明確 ptt 段，可能在 openmanetd binary 或 `openmanetargon`）—— 待確認。
  2. **自建 mesh 多播對講**（不靠 openmanetd）：按鈕→`arecord | opusenc | 多播 UDP`；常聽→`多播 | opusdec | aplay`。mesh 是扁平 L2（10.41.0.0/16），serverless 很自然。語音 ~16–24 kbps ≪ mesh ~2.8 Mbps（4 MHz 時 ~4.1 Mbps），每跳 3–4 ms，PTT 綽綽有餘。

---

## 3. ★ 沿用現有 K頭耳麥/托咪（重點）

現有配件是 **K頭（Kenwood 2-pin：3.5mm 喇叭 + 2.5mm 麥克風/PTT）**，本來插無線電。
**已確認：ADI AQ-50 用的就是這個標準 K頭** → 配件可直接沿用，且 AQ-50 的 K 接法就是這些配件的電氣期望值。

### 標準 K頭接法（= AQ-50 = 你的配件）
- **共地**：mic / 喇叭 / PTT 共用一個 GND。
- **喇叭**：3.5mm，無線電送 RX 音出來 → 對應 Pi 音效卡「輸出」。
- **麥克風**：2.5mm 側，**電容麥，由無線電供 bias（phantom power）** → USB 音效卡 mic 輸入本來就供 bias，相容（電壓對得上即可）。
- **PTT**：**「接地即發射」（ground to transmit）**，按下把線接地 → 接 GPIO（內部上拉），按下 = 低電位。

### ✅ 已由照片確認（2026-08-12）：PTT 獨立線，免電晶體
配件 K 公頭照片顯示 **3.5mm 那顆是 3 導體（2 條黑圈，TRS）** → 內含 **MIC 與 PTT 兩條獨立訊號 + 地**；2.5mm 那顆是喇叭。所以 **PTT 是獨立導線，直接進 GPIO，不需電晶體** —— 最省事的版本。（若換到只有 2 導體 3.5mm 的配件才是共線型、才需電晶體，判別法見下。）

### 要加的硬體
| # | 東西 | 作用 |
|---|---|---|
| 1 | USB 音效卡（CM108） | mic 輸入 + 喇叭輸出 |
| 2 | **K頭母座** | 接受配件的 K 公頭。最省事：買「K 公轉母延長線」剪下母頭端當母座取 4 線；或蝦皮「K頭母座」 |
| ~~3~~ | ~~PTT 分離電路（電晶體）~~ **本例不需要** | PTT 是獨立線 → 直接進 GPIO（省掉電晶體） |
| 3 | **免焊 3.5mm 公頭 ×2**（螺絲鎖線，2節或3節） | 音訊線鎖上去 → 插進音效卡兩孔（免焊、卡不用拆） |
| 4 | **夾式磁環（clip-on ferrite）** | 套音訊線，防 HaLow TX 干擾（ham 圈常見雷） |

### 接線
| K頭訊號 | → | Pi |
|---|---|---|
| 喇叭（3.5mm） | → | 音效卡耳機輸出 |
| MIC（2.5mm tip） | → | 耦合電容 → 音效卡 mic 輸入 |
| PTT（接地即發射，獨立線） | → | 直接進 **GPIO（如 GPIO6）**，內部上拉，按下 = 低電位 |
| GND | → | 共地 |

### 判別方法（換不同配件時參考）
- **數 3.5mm 插頭的黑圈**：**2 圈（3 導體）= 有獨立 PTT**（本例，免電晶體）；1 圈（2 導體）= PTT 跟 MIC 共線，才需電晶體。免電表、用看的即可。
- 3.5mm 上「哪條是 MIC、哪條是 PTT」不用猜：接上後 **有聲音那條 = MIC**、**按下把 GPIO 拉低那條 = PTT**；接反了對調兩條線即可，不會燒。
> ADI AQ-50 線上無詳細接腳文件（冷門/台灣品牌），以實測配件/照片為準。

### 實體組裝（免焊，附接線圖）
接線圖檔：**`docs/khead-usb-wiring.svg`**。

⚠️ **不能**把托咪 K 公頭直接插進音效卡的孔：(a) 喇叭是 2.5mm、插不進 3.5mm 孔；(b) 兩插頭在硬塊上、間距對不上音效卡；(c) 插進去後 PTT/地會被孔「吃進」音效卡電路、拉不出來接 GPIO。**必須在插頭「之前」把線拆出來。**

**流程（全程免烙鐵、音效卡不拆不焊）：**
1. 托咪(K公) → 插進 **K母座**（K 公轉母延長線剪一半；或直接剪托咪自己的線，但那條托咪就不能再插無線電）。
2. 母座拉出 4 條線：**Spk / Mic+ / PTT / Gnd**。
3. **Spk + Gnd** → 鎖進一個**免焊 3.5mm 公頭** → 插音效卡**耳機孔**。
4. **Mic+ + Gnd** → 鎖進另一個**免焊 3.5mm 公頭** → 插音效卡 **Mic 孔**。
5. **PTT** → 單獨一條拉到 **Pi GPIO6**；**Gnd** 三邊共地。

**免焊 3.5mm 公頭**：買**公頭**（有插針那個，不是母頭），**2節或3節皆可**（訊號單聲道）。
- 2節：一端子=訊號、一端子=地。
- 3節（端子 `L/R/↓`）：`↓`=地、`L`=訊號、`R` 耳機可接同 Spk 或空、mic 空。不用 4節。

**音效卡選型**：一般 **CM108**（有 mic 3.5mm 孔）最穩。Waveshare「USB TO AUDIO」把喇叭輸出拉成排針(VOLP/VOLN…)、可直接焊線空間大，但**要先確認它有沒有外接 mic 輸入**——只有板載 mic 就不能用托咪的 mic。

---

## 4. 注意事項
- **供電**：多 USB 裝置耗電上升，本專案有欠壓史（電池撐不住 TX 峰值）→ 穩定 **5V/3A+**，否則 meshled 紅燈 5Hz。
- Pi4 有 4 個 USB，GPS + 音訊夠插。
- 電容麥 bias：USB 音效卡 mic 輸入有供電，一般相容；偶爾要加耦合電容/調電阻。
- 阻抗/音量：無線電喇叭驅動力比音效卡強；耳機音量不夠就加小功放或主動喇叭。
- 這些是節點端硬體，之後可把驅動/設定/腳本**預裝進 v2.0 image**（燒卡即用）。

---

## 5. 採購 / 參考連結
（WebSearch 偏美國站；台灣本地搜同型號更快：蝦皮/露天，或 iCShop/DigiKey/Mouser）

**GPS**
- VK-172（u-blox7, USB, ~$10-15, 免驅動 /dev/ttyACM0）：Amazon「Stemedu VK172」`https://www.amazon.com/Stemedu-G-Mouse-GLONASS-Receiver-10/dp/B07QRGK7ZK` ／ eBay `https://www.ebay.com/itm/116444002184`
- 設定教學：TeelSys `https://teelsys.com/vk-172-usb-gps-on-the-raspberry-pi/`
- NEO-M8N USB + SMA 外接天線（野外）：GNSS Store `https://gnss.store/products/elt0084`

**PTT（本例確認要買的三樣 —— PTT 獨立線、免電晶體）**
- ① **USB 音效卡 CM108**（mic in + 喇叭 out）：Amazon `https://www.amazon.com/Adapter-External-Portable-Speaker-Earphone/dp/B0CNRZY6Y2`（蝦皮「CM108 USB 音效卡」）
- **免焊 3.5mm 公頭 ×2**（螺絲鎖線、公頭、2節/3節）：蝦皮搜「3.5mm 免焊 端子 公頭」/「3.5mm 焊接頭 免焊」
- ② **K頭母座**（買 K 公轉母延長線、剪母頭端）：CommGear `https://www.commgearsupply.com/products/kenwood-male-to-kenwood-female-adapter`（蝦皮「K頭 公轉母」/「K頭母座」）
- ③ **夾式磁環**（clip-on ferrite，3.5mm 孔徑）：Amazon `https://www.amazon.com/uxcell-Ferrite-Cores-Suppression-Filter/dp/B07YJYGGP3`（蝦皮「夾式磁環」）
- 參考：CM108 教學 Adafruit `https://learn.adafruit.com/usb-audio-cards-with-a-raspberry-pi/cm108-type`；K頭接腳 Wildtalk `https://www.wildtalk.com/knowledge-base/kenwood-2-pin-wiring-data/`
- （**共線型配件才需要**的 PTT 電晶體電路，本例免；留作參考：APRS-Box `http://elafargue.github.io/aprs-box/hardware/`、Sunny He `https://sunnyhe.org/projects-baofenginterface.html`、gist `https://gist.github.com/tymarbut/d802e43ab306b4b9f2ba`）

---

## 6. 下一步
1. 決定 GPS 走 USB 還是 UART。
2. **量 K頭 PTT 是獨立線還是接地 MIC 型**（決定要不要電晶體）。
3. 我據此給：確切電路圖（含電阻值）+ gpsd 設定指令 + 「讀 GPIO PTT + arecord/aplay 走 mesh 多播」的腳本。
4. 先各買一組（VK-172 + CM108 + 按鈕 + K 母座）插 manet01 驗證整條流程，再定野外/量產版（M8N 外接天線 + 防水按鈕），最後預裝進 v2.0 image。
