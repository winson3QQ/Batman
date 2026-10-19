# Review B(第 12 輪)— v12 @ ee9cc50

> **註**:審查者 B 的完整報告寫入中途被中斷,檔案沒有產生。本檔是作者依審查者交回的摘要整理的紀錄,內容只包含審查者回報的要點,作者補上的查證另行標明。

**判定:REJECT(窄)— 0 BLOCKER / 2 MAJOR / 8 MINOR**
全程唯讀:只讀 repo 與 firmware 樹;在 04 / 02 上只跑 cat、grep、uci show、ls、vcgencmd bootloader_config。

## MAJOR

- **B12-M1:image 裡還有 EEPROM 讀者,§3「image 內沒有讀者」不成立。** `/rom/etc/uci-defaults/95-morse-wireless-defaults` → `/morse/scripts/morse-wireless-defaults:19-22` 讀 `default_wifi_key`,用來當新卡第一次開機的 onboarding AP(radio0)PSK;觸發條件是 mac80211 預設 AP(`mac80211.uc:107-115`)。這把 key 不是 `CHANGE-ME-NOW`,`halow-keyguard` 不擋,AP 會開 → §1.4「unclaimed:AP placeholder → keyguard 關」不對,L1 的「AP 關」斷言會 FAIL;前任在 EEPROM 預寫的值撐過重燒,變成重燒後 unclaimed 節點的 AP 金鑰。⚠️ 依原始碼推論,沒在新燒的卡上實跑。修法:PR-F 以 shim 取代 `/sbin/persistent_vars_storage.sh`(READ 一律回空 + WARN),一次關掉所有讀者;讓 unclaimed 的 AP 真的維持關閉。負對照:shim 讓 `vcgencmd bootloader_config` 回 `default_wifi_key` → 修正後 image 不採用、AP 不開;1.5.12 會採用。
- **B12-M2:轉賣工具沒有最低版本閘。** 只檢查 GPT 分割名 → 1.5.x A/B image 會被接受,而舊 image 還帶 `31_*` hook,B11-M2 從這裡回來。§4.5「用舊版 image 重燒能開機與認領、OTA 走 L44」也錯:舊 image 沒有 provd,#202 閘在舊程式裡也還會擋。修法:工具要求 image 版本 ≥ 階段 1、驗發行簽章 / sha;改掉那段文字。

## MINOR

1. **m1(WSL)**:WSL 看得到卡要 usbipd-win + `modprobe usb-storage`;WSL kernel 6.6.114 有 `CONFIG_USB_STORAGE=m`,這台主機沒裝 usbipd-win;`blkdiscard` 在 WSL 有(util-linux 2.39.3);Linux 原生 SD 槽(mmcblk)`removable=0` 會被工具拒絕。
2. **m2(Windows)**:`BusType=USB` ≠ 讀卡機(USB 外接硬碟也會過),缺大小上限;diskpart `clean all` 沒有進度,與契約第 6 點衝突,建議 PowerShell 寫零迴圈;「#208 出廠卡規則」不在 repo,設計不自足。
3. **m3(L16 測試)**:loop 裝置 `removable=0`,測試需要 override 模式,並附「非可移除裝置被拒」負測試。
4. **m4**:「6 個分割」會拒絕 bcm2710 image(多 p7 batfw);board / SoC 相符的資料來源沒寫。
5. **m5**:誠實界線少了 EEPROM 的 BOOT_ORDER / 網路開機(04 有 `NET_INSTALL_AT_POWER_ON=1`);買家說明應寫「一律重設 EEPROM」。
6. **m6**:其他 EEPROM 讀者:`mm_region` / `mm_sku`(`lib/netifd/wireless/morse.sh`、`01-region-restriction`,可鎖區域 → HaLow 起不來、改 BCF);`mm_mode`(`diag_override.sh` / rpcd `morse-mode`)。用 M1 的 shim 一起處理。
7. **m7**:L12 降級到 1.5.12 時 fresh overlay 會重跑 `31_*`,矩陣要補。
8. **m8**:PR-F 怎麼移除 `31_*` 沒寫(屬 morse-bundle 套件 files);`docs/upgrade-1.8.0.md` 要同步。

## v11 發現去向

- addressed:A11-M1(設計層)、A11-m1~m9、B11-m1~m4、B11-m6;A11-m9 在 04 讀 ota-trace 第 1514–1515 行與 F8 一致 ✅。
- partial:B11-M1(可行性,見 m1–m3)、B11-M2(見 M1 / M2 / m5)、B11-m5(見 M2)。

## PR 要求(審查者建議)

M1 / M2 / m6 / m8 → PR-F + PR-P3;m1–m4 → PR-P3 / PR-H1;m5、m7 → v13 文字。

## 作者查證(2026-10-20,04 唯讀)

- `grep -l persistent_vars_storage` 命中:`/rom/lib/netifd/wireless/morse.sh`、`/rom/etc/uci-defaults/31_dropbear_persistent_storage`、`31_password`、`luci-i18n-base-zz-lang-autodetect`、`/rom/morse/scripts/morse-wireless-defaults`、`/rom/morse/scripts/save_dropbear_setup.sh`。
- `morse-wireless-defaults:19-22` 讀 `default_wifi_key`(沒有就隨機 8 字元)並寫進 `system.@system[0].default_wifi_key`;同檔讀 `mm_region`。
- 04 `vcgencmd bootloader_config`:`NET_INSTALL_AT_POWER_ON=1`。
