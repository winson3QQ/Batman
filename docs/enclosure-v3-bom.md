# V3 手持電台外殼 — 完整 BOM（HaLow + LoRa 全配）

外殼機構檔來源：**[ties1887/Mesh-radio-Halow-LoRa](https://github.com/ties1887/Mesh-radio-Halow-LoRa)** 的 **`V3_18-6-2026`**（MIT 授權）。
V3 是「Raspberry Pi 4 + WM1302 HAT + Wio-WM6108」量身版 = **對應本專案節點硬體**。
價格為原表 EU 參考價（€，2026-07 更新），台灣可搜同型號本地買。**此為全配（含 LoRa），非省版。**

- 可列印檔：`V3_18-6-2026/3MF/Assem2.3MF`（含所有殼件，**免支撐**列印）；CAD 原始檔在 `STEP/`、`Solidworks 2023/2025/`。
- 原始完整 BOM（Google Sheet）：<https://docs.google.com/spreadsheets/d/1Nt8EjYsgWTId0Qjl1BAAxPci3bh1FSZ7VQxQRFxyHnk>

---

## HaLow（運算 + 無線）
| 零件 | 數量 | 單價 | 連結 |
|---|---|---|---|
| Raspberry Pi 4 Model B 2GB | 1 | €58.05 | （跑 OpenMANET，見 openmanet.github.io/docs）|
| Wio-WM6108 Wi-Fi HaLow mini-PCIe（902–928MHz，注意法規）| 1 | €14.90 | https://www.seeedstudio.com/Wio-WM6108-Wi-Fi-HaLow-mini-PCIe-Module-p-6394.html |
| WM1302 Raspberry Pi HAT | 1 | €19.90 | https://www.seeedstudio.com/WM1302-Pi-Hat-p-4897.html |

## LoRa（全配，不省）
| 零件 | 數量 | 單價 | 連結 |
|---|---|---|---|
| RAK WisMesh 1W Booster Starter Kit（含 1W 功放的完整 LoRa 節點）| 1 | €39.00 | https://store.rakwireless.com/products/meshtastic-1w-lora-booster-kit-rak3401 |
| RAK12500 WisBlock GNSS（u-blox **ZOE-M8Q**）— GPS，*選配*（或用手機 GPS）| 1 | €19.75 | https://www.tinytronics.nl/nl/communicatie-en-signalen/draadloos/gps/modules/rakwireless-rak12500-wisblock-gnss-gps-locatie-module-zoe-m8q |

## ⭐ 電池與電源（V3 的高峰值電流設計 → 解 TX 欠壓）
| 零件 | 數量 | 單價 | 連結 |
|---|---|---|---|
| **Samsung INR21700-45T 4500mAh 50A**（cell）→ **2S2P** | 4 | €2.79 | https://www.nkon.nl/samsung-inr21700-45t-4500mah-50a.html |
| **2S 10A 8.4V BMS**（藍版，平衡+供電）| 1 | €2.90 | https://nl.aliexpress.com/item/1005003656392591.html |
| **DC-DC Buck 7-24V→5V**（**必須 5V / ≥4A**）| 1 | €6.00 | https://www.tinytronics.nl/nl/power/spanningsconverters/buck-(step-down)-converters/dfrobot-dc-dc-buck-converter-7-24v-naar-5v-4a |

## 散熱
| 零件 | 數量 | 單價 | 連結 |
|---|---|---|---|
| **純銅散熱片 70×70×3mm**（給 HaLow 模組）| 1 | €14.29 | https://nl.aliexpress.com/item/1005004251581428.html |
| Raspberry Pi 4 散熱片組 | 1 | €1.52 | https://nl.aliexpress.com/item/4000266052801.html |

> ⚠️ 後散熱片：3MF/STEP 內附的是**視覺參考**，實際請買上面的金屬版。

## 天線與接頭
| 零件 | 數量 | 單價 | 連結 |
|---|---|---|---|
| GIZONT 玻纖 N-male 全向天線 868/915MHz（HaLow + LoRa 各一）| 2 | €23.59 | https://nl.aliexpress.com/item/1005011946812428.html |
| UFL → SMA pigtail（量好長度）| 2 | €2.71 | 蝦皮/AliExpress 搜「U.FL to SMA pigtail 1.13」|
| UFL → N（選配）| 2 | €3.86 | https://nl.aliexpress.com/item/1005008877279360.html |
| UFL → TNC（選配）| — | — | https://nl.aliexpress.com/item/1005012323556605.html |

## 網路（防水）
| 零件 | 數量 | 單價 | 連結 |
|---|---|---|---|
| 防水乙太轉接 A（8pin A-Female → RJ45）| 1 | €5.69 | https://nl.aliexpress.com/item/1005008753710731.html |
| 防水乙太轉接 B（8pin A-Male → RJ45）| 1 | €5.69 | https://nl.aliexpress.com/item/1005008753710731.html |

## 外殼材料 & 雜項
| 零件 | 數量 | 備註 |
|---|---|---|
| PLA（或更硬材質）列印線材 | — | 主體 |
| TPU / 2mm 橡膠 O-ring（密封，選配）| — | 前後密封槽走 2mm 橡膠條 → **防潑水、非全防水** |
| 線材（**電源用 16–18 AWG**）| — | 正負絞對、降壓降噪 |
| M3 / M4 螺絲 | — | **長度要對，太長會頂到內部電路短路** |

---

## 概算
- **全配（含 LoRa、不含選配 GPS）**：約 **€231.7**
- 加 GPS（RAK12500）：約 **€251.5**
- （未含 PLA 線材、線/螺絲、運費、台灣本地價差）

## 組裝關鍵（作者 README BEFORE BUILD 重點）
1. **螺絲長度要對** —— 太長頂到電路/焊點 → 短路。
2. **PCB 滑入公差極小** —— 慢推、別刮掉小元件；beta 版有些件要打磨修配。
3. **電源正負線成對絞 + 16–18 AWG** —— 降壓降、降發熱。
4. **Buck 降壓板噪訊大 → 接地銅箔膠帶遮蔽**（銅箔勿碰帶電點）。
5. **所有件免支撐列印。**
6. 密封走 2mm 橡膠 O-ring；**防潑水非全防水**。

## 對本專案的意義
V3 的電源鏈（**2S2P Samsung 45T 45A cell + 2S BMS + 5V/4A buck + 16–18AWG 絞線 + 銅箔遮蔽**）正是為了扛 HaLow TX 峰值電流而設計 —— 直接對應本專案的 **TX 欠壓/掉電**問題。照此電源方案做，欠壓大概率可解。GPS 用 ZOE-M8Q（u-blox M8）或 USB u-blox 或手機 GPS 皆可，插上即餵 openmanetd → CoT/ATAK。
