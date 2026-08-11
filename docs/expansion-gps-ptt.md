# 硬體擴充規劃：GPS + PTT（沿用現有 K頭配件）

節點硬體：Raspberry Pi 4B + Seeed WM1302 HAT + Wio-WM6108（HaLow SPI），跑 OpenMANET。
目標：讓節點能**收 GPS**、並用**按鈕按下即傳語音（PTT）**，且**沿用現有無線電的 K頭耳麥/托咪**。

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

現有配件是 **K頭（Kenwood 2-pin：3.5mm 喇叭 + 2.5mm 麥克風/PTT）**，本來插無線電。K頭有 4 條訊號：**喇叭、麥克風、PTT、地**。

### ⚠️ 關鍵特性：PTT 靠「把 MIC 線接地」來 key（多數 Kenwood/Baofeng）
不是獨立 PTT 線。直接拉進 GPIO 會誤觸/雜訊，需一顆電晶體/光耦把「MIC 被接地」轉成乾淨 GPIO 訊號，同時 MIC 音訊經耦合電容照進音效卡。

### 要加的硬體
| # | 東西 | 作用 |
|---|---|---|
| 1 | USB 音效卡（CM108） | mic 輸入 + 喇叭輸出 |
| 2 | **K頭母座** | 接受配件的 K 公頭。最省事：買「K 公轉母延長線」剪下母頭端當母座取 4 線；或蝦皮「K頭母座」 |
| 3 | **PTT 分離電路**（1 電晶體/光耦 + 幾顆電阻） | 偵測 MIC 接地 → GPIO；MIC 音訊經耦合電容進音效卡 |
| 4 | **磁環（ferrite）** | 套音訊線，防 HaLow TX 干擾（ham 圈常見雷） |

### 接線
| K頭訊號 | → | Pi |
|---|---|---|
| 喇叭（3.5mm） | → | 音效卡耳機輸出 |
| MIC（2.5mm tip） | → | 耦合電容 → 音效卡 mic 輸入 |
| PTT（按下把 MIC 接地） | → | 電晶體偵測接地 → GPIO（如 GPIO6） |
| GND | → | 共地 |

### 🔧 待辦：先量 PTT 型（三用電表）
- **獨立 PTT 接點** → 直接進 GPIO，**免電晶體**（最簡單）。
- **接地 MIC 型**（多數）→ 需上述電晶體電路。
> 量出來後才定電路。多數有大 PTT 按鈕的托咪/耳麥其實兩者都有可能，務必實測。

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

**PTT 音訊**
- CM108 USB 音效卡：Amazon `https://www.amazon.com/Adapter-External-Portable-Speaker-Earphone/dp/B0CNRZY6Y2` ／ Adafruit 教學 `https://learn.adafruit.com/usb-audio-cards-with-a-raspberry-pi/cm108-type`

**K頭 / PTT 介面**
- K 公轉母延長線（剪母頭端）：CommGear `https://www.commgearsupply.com/products/kenwood-male-to-kenwood-female-adapter`
- K頭 2-pin 接腳定義：Wildtalk `https://www.wildtalk.com/knowledge-base/kenwood-2-pin-wiring-data/`
- PTT 分離電路實例（Baofeng↔Pi）：APRS-Box `http://elafargue.github.io/aprs-box/hardware/` ／ Sunny He `https://sunnyhe.org/projects-baofenginterface.html` ／ gist `https://gist.github.com/tymarbut/d802e43ab306b4b9f2ba`

---

## 6. 下一步
1. 決定 GPS 走 USB 還是 UART。
2. **量 K頭 PTT 是獨立線還是接地 MIC 型**（決定要不要電晶體）。
3. 我據此給：確切電路圖（含電阻值）+ gpsd 設定指令 + 「讀 GPIO PTT + arecord/aplay 走 mesh 多播」的腳本。
4. 先各買一組（VK-172 + CM108 + 按鈕 + K 母座）插 manet01 驗證整條流程，再定野外/量產版（M8N 外接天線 + 防水按鈕），最後預裝進 v2.0 image。
