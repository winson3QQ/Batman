# #254 階段 1 實作設計 v13 — 審查 B(第 13 輪)

審查對象:`design/254-stage1-impl` @ ad35e32 `docs/design/254-stage1-impl.md`(v13)。
全程唯讀。repo 與 firmware 樹只讀;WSL build rootfs `root-bcm27xx` 只用 grep/sed。04 與 02 上只跑 cat、ls、uci show、`vcgencmd bootloader_config`、`/rom/sbin/persistent_vars_storage.sh READ`(本身唯讀)和 sysfs 讀取。沒有寫入,沒有重開。

**判定:REJECT(窄)— 0 BLOCKER / 1 MAJOR / 9 MINOR。**

唯一的 MAJOR 是轉賣流程漏了一個不在 SD 卡上、而且確實會撐過重燒的元件:04 上用 USB 接著的 RAK4631(Meshtastic)。修法只動 §4.5 說明頁、§8 一列和 L16 斷言,不碰任何共享狀態。修好之後,或者使用者明確把它定為誠實界線,我預期可以 APPROVE-WITH-CHANGES。

v13 自己的掃描(F21–F24)我逐項重做了一遍,結論成立。

## 0. 我重做的掃描(✅ 附原始證據)

| 項 | 結果 | 證據 |
|---|---|---|
| EEPROM persistent var 的讀者 | **F21 列的 9 個是完整的**:`31_dropbear_persistent_storage`、`31_password`、`morse-wireless-defaults`(經 95 呼叫)、`lib/netifd/wireless/morse.sh`、`etc/diag_override.sh`、`usr/share/rpcd/ucode/morse-mode`、LuCI `header.htm`、`luci-i18n-base-zz-lang-autodetect`、`etc/boot-defaults/01-region-restriction`。rootfs 裡沒有任何檔案引用 `boot-defaults`,所以同意它「沒人執行」。`save_dropbear_setup.sh` 只寫不讀。沒有人呼叫 `READALL`。 | rootfs 跑 `grep -rIl -e persistent_vars_storage -e bootloader_config -e READALL`。另用 `grep -rla` 掃 ELF:只有 `usr/bin/openmanetd` 命中。它的原始碼 `openmanetd-1.3.10/internal/network/uci_system.go:108` 讀的是 **uci** 的 `system.default_wifi_key`(`morse-wireless-defaults:23` 寫的副本),只給 setup wizard 用,不碰 EEPROM |
| 其他 `vcgencmd bootloader_config` 的使用 | `95-batman-storage:418` 只把 `BOOT_ORDER`/`PARTITION_WALK` 寫進 log,讀的不是 persistent var | rootfs grep |
| OTP | `otpset`、`raspinfo` 在 image 裡,但沒有任何開機路徑呼叫它們。MAC(來自 OTP)決定 hostname,這是既有殘項 | rootfs grep `otp_dump` |
| F23「AP 預設是開的」 | 成立。`/etc/init.d/boot:53-56` 的順序是 `config_generate` → `wifi config` → `uci_apply_defaults`。board.json 沒有 wlan defaults 時,`lib/wifi/mac80211.uc:107-114` 產生 radio `disabled=1`、AP `OpenWrt`/`none`。`morse-wireless-defaults:138-157` 對這個狀態設 `psk2`、刪 `disabled`、key = `default_wifi_key`;EEPROM 是空的,所以走 `:21` 的隨機 8 字元 `[A-Za-z0-9]`。rootfs 沒有內建 `/etc/config/wireless` | rootfs 原始碼 |
| keyguard | `halow-keyguard:30-38` 對 key 等於 `CHANGE-ME-NOW` 的 `mode=ap` 設 `disabled=1`,**而且有 `uci commit`**,所以之後 99-chanfix 的 `wifi reload` 不會把 AP 叫回來 ✅。START=18:在 S10 之後、network S20 之前 ✅ | rootfs |
| uci-defaults 的順序 | 94 < 95-batman-storage < 95-morse-wireless-defaults < 96 < … < 99_morse_radio_defaults < `99zz…`。99zz **之後還有** `luci-i18n-*`(只設語言)。所以 D5「99zz 排最後」字面上不對,但無害(m2) | rootfs `ls etc/uci-defaults` |
| F24 | 04:`BOOT_UART=0 WAKE_ON_GPIO=1 POWER_OFF_ON_HALT=0 NET_INSTALL_AT_POWER_ON=1`。02:只有前三項。兩台跑 `/rom/sbin/persistent_vars_storage.sh READ default_wifi_key` 都回 rc=1 和「doesn't exist in bootloader config」 | 本次在 04/02 唯讀取得的輸出 |
| shim 的放法 | 成立。`package/Makefile:119` 和 `include/image.mk:396` 都執行 `prepare_rootfs … $(TOPDIR)/files`,時間在套件安裝之後,所以會蓋過 `persistent-vars-storage-bcm2711` 的同名檔。sysupgrade payload 由同一個 rootfs 產生。`firmware-allowlist-*.sha256` 只列開機韌體 blob,shim 不會讓它誤報 | firmware 樹 |
| shim 會不會弄壞合法的使用者 | 不會。02/04 今天就讀到空(見上一列)。bcf 由 `99_morse_radio_defaults` 依 board 設定,不靠 `mm_sku`;region 來自 uci `country`。唯一的行為差別是 Morse 的 EEPROM 區域鎖失效,v13 已經寫明 | rootfs + 節點 |
| SD 卡以外、會撐過重燒的東西 | Pi EEPROM(已涵蓋);**RAK4631 的 flash(未涵蓋 → M1)**;GPS 模組 BBR、HAT ID EEPROM、OTP(m9) | 04:`/sys/bus/usb/devices/1-1.3 239a:8029 WisCore RAK4631 Board`、`/dev/ttyACM0` 存在;`/proc/device-tree/hat` 不存在;沒有 `/dev/rtc*` |

## 1. 先補:缺的列 / 資源

| 路徑 / 資源 | 文件現況 | 實際 | 發現 |
|---|---|---|---|
| 用 USB 接著的 RAK4631(Meshtastic)的非揮發設定:頻道 PSK、owner、node DB(含隊友位置) | §4.5、§8、L16 都沒提 | 04 上就接著一顆。設定撐得過斷電,所以存在 RAK 自己的 flash 裡,不在 SD 卡上,重燒卡碰不到 | **M1** |
| unclaimed 節點 OTA(L44)之後的 AP | §1.4 寫 unclaimed「AP:99zz 設 placeholder」 | 99zz 的條件是「p5 未 seed、**無 prov**」。L44 的新槽裡,96 已經先抄了 `prov{unclaimed}` → 99zz 不動作 → 95 設的隨機 key AP 開著 | m1 |
| 轉賣工具被中斷(拔卡、PC 睡眠) | 沒有這一列 | 卡只清了一半,也沒有分割表;工具不能回報成功 | m3 |

## 2. Findings

### MAJOR

#### B13-M1 — 轉賣流程沒有處理 RAK4631(Meshtastic)的 flash:前任隊伍的 LoRa 頻道金鑰和隊友位置會跟著機器交給買家

**情境(誠實的賣家照 §4.5 做)**
1. 賣家的節點和 04 同配置:Pi 4 + HaLow HAT + USB 接的 RAK4631。使用者 2026-09-26 決定 RAK 接 Pi 的 USB,產品 SKU 也有「LoRa 內建」選項。RAK 上跑 Meshtastic,設好了隊伍的頻道。
2. 賣家照說明頁的 ①②③ 做:`network/leave`、備份 p6、用轉賣工具重燒。工具把 SD 卡全部寫零,再寫 image。
3. RAK 的頻道設定(含 PSK)、owner 和 node DB 存在 RAK 自己的 flash 裡,不在 SD 卡上,完全沒被碰到。
4. 買家拿到機器後,用 Meshtastic app 透過 BLE 連 RAK,或從 Pi 的 `/dev/ttyACM0` 讀,就能取出頻道 URL。之後能解讀、也能注入賣家隊伍的 LoRa 流量(位置、訊息),還看得到 node DB 裡隊友的名稱和最後位置。

**證據**
- ✅ 04:`/sys/bus/usb/devices/1-1.3 239a:8029 WisCore RAK4631 Board`,`/dev/ttyACM0` 存在(本次唯讀取得)。
- ✅ 使用者決策(記憶 `project_v3_power_system.md`):「RAK 要接 Pi(USB 資料+供電)」。`project_product_segmentation.md`:LoRa 內建是 SKU 選項之一。
- ⚠️ 推論:我沒有讀 RAK 的內容,因為唯讀規則下不碰 serial 的持有者。依據是:Meshtastic 節點斷電重開後還在原頻道 → 設定存在非揮發 flash。RAK 是獨立的 MCU,重燒 SD 卡不可能清到它。
- §4.5「重燒後的結果」和 U4「全清含身分」都只講到 SD 卡。

**為什麼是 MAJOR**:照文件實作、照指示操作之後,買家仍拿得到前任隊伍的 LoRa 頻道金鑰和隊友位置(actor 得利)。觸發不需要任何故障,也不需要鑑識工具。

**修法(不碰共享狀態)**
- §4.5 賣家步驟加一條:機器有 LoRa(RAK)時,用 Meshtastic app 或 CLI 對 RAK 做 factory reset,清掉頻道和 node DB。
- 買家步驟加一條:自己再對 RAK 做一次 factory reset。理由和自己重燒卡一樣:不能信任賣家。
- §8 加一列:前任 → 買家,RAK flash 殘留 → 說明頁 + 買家自行重置。惡意賣家改過 RAK 韌體這件事擋不住,列為誠實界線;買家可以重燒 RAK 韌體。
- §5 L16 節點層加斷言:重置後讀出的 RAK channel URL ≠ 賣家原本的值。負對照:只重燒 SD 卡 → 頻道仍在。
- 如果使用者決定階段 1 的轉賣不涵蓋 LoRa SKU,就把它寫成誠實界線,並在說明頁明講;這樣這條就算已處置。

### MINOR

1. **B13-m1 — 99zz 用「無 prov」判斷 unclaimed,漏掉 L44(unclaimed 節點 OTA)和 96 不經 `:93` 的出口**(**PR-P1 要求**)
   - 情境:倉庫裡還沒認領的機器先做 OTA(v13 的 L44 明確支援這條路)。
   - 新槽是 fresh overlay。96 在 `:93` 之前已經把 `prov{unclaimed}` 抄進 overlay,所以 99zz 的條件不成立。結果 `morse-wireless-defaults:21,138-157` 設的隨機 key AP 是開著的。這時 root 是 image 預設的空密碼,dropbear 的密碼登入也開著。
   - 沒有別的機制會把它關掉:`batman-config-save` 的 PRESERVE(`:30-40`)不含 `default_radio0.disabled`,而 unclaimed 節點從不跑 `--save`。
   - 96 從 `:64/:67/:71/:89` 出去時(verdict 不是 `unseeded`)也一樣。
   - 不算 MAJOR:key 是 62^8 的隨機值,沒人知道,要離線破解 PMKID 才進得去。
   - 修法:99zz 改成看狀態。fresh overlay 且符合下列任一條件就設 placeholder:overlay 的 prov.state == unclaimed;或者沒有 prov,而且 p5 未 seed 或讀不到。只有 `legacy|claimed|member` 或 p5 已 seed 時才不動。
   - L44 的測試加斷言「`iw dev` 沒有 AP 介面」。負對照:用 v13 字面上的條件 → AP 還在。

2. **B13-m2 — 99zz 的契約自相矛盾,輸入也沒寫**(文件,PR-P1 之前要修)
   - §4.4 步驟 8 說 `--apply-state --firstboot`(由 99zz 呼叫)「不 reload、不 persist、**不碰 uci**」;§3 和 §4.5 卻要 99zz 改 `wireless.*.key`。
   - 99zz 怎麼知道「p5 未 seed」沒寫。§3 列 `/etc/.batman-prov-restore` 的讀者時只有 helper。
   - 請寫明三件事:
     - AP placeholder 由 99zz 的 shell 部分做,不是 helper 的 `--firstboot`;
     - 99zz 讀的是 96 的 verdict + boot_id(或 overlay 的 prov);
     - 把 99zz 加進 `.batman-prov-restore` 的讀者。
   - 順便把 D5「99zz 排最後」改成「排在所有會動 wireless 的 uci-default 之後(之後只剩 `luci-i18n-*`)」。

3. **B13-m3 — Windows 工具的契約少了「先釋放 volume」和幾個實作關鍵**(**PR-P3 要求**)
   - (a)釋放 volume:卡上的 p1 是 FAT,Windows 會把它掛成磁碟機。不先釋放就對 `\\.\PhysicalDrive<N>` 寫 p1 的範圍,寫入會被拒絕。現行的 `flash-card.ps1:11` 用 `Clear-Disk -RemoveData -RemoveOEM`,就是為了這件事(移除式媒體不能設成 offline)。§4.5 第 3 點的「不用 `Clear-Disk -RemoveData`」很容易被讀成「完全不呼叫」。請改成:「用 Clear-Disk(或 lock + dismount)釋放 volume,但不靠它清零」。
   - (b)`MediaType` 的來源:`Get-Disk` 沒有這個欄位,要用 `Win32_DiskDrive.MediaType = 'Removable Media'`。另外加檢查 `IsBoot`/`IsSystem` 為 false。
   - (c)執行期間要防止睡眠(`SetThreadExecutionState`)。中斷或任何寫入錯誤都不能回報成功。
   - (d)發行檔是 `.img.gz`(`build-ab-image.sh:224-225`)。要寫明清單的 sha256 算的是哪一份,以及讀回比對要用解壓後的長度。
   - 可行性 ✅:PS 5.1 可以用 `IO.FileStream` 讀寫 `\\.\PhysicalDrive`,`flash-card.ps1:13` 已經這樣用。

4. **B13-m4 — Linux 工具少了「目標沒被掛載、也不是系統碟」的檢查**(**PR-P3 要求**)
   - 在 Pi 或筆電上用 `--internal-sd` 時,`mmcblk0` 可能就是主機自己的系統卡。
   - 要求:目標的所有分割都沒有掛載(桌面環境自動掛載的要先卸載),而且不是 `/` 或 `/boot` 所在的裝置。
   - `dd … conv=fsync` 寫到卡尾時會因 ENOSPC 回非 0。要以「寫入的位元組數 == 裝置大小」判定成功;不能在 `set -e` 下直接當成失敗,也不能忽略錯誤。

5. **B13-m5 — `--test-target-file` 要拒絕一般檔案以外的東西**(**PR-P3 要求**)
   - 這個模式會跳過可移除裝置的檢查。如果傳進 `/dev/sda`(或指向它的 symlink),就會把系統碟寫零(「我們自己」這個 actor)。
   - 要求:`realpath` 之後再 `lstat`,必須是 regular file,否則拒絕。
   - 負測試:對 loop 裝置或 symlink 傳 `--test-target-file` → 被拒。

6. **B13-m6 — shim「每次開機每個 key 記一次 WARN」需要標記檔,標記檔的位置要通過 tmp-trust 檢查**(**PR-F 要求**)
   - shim 會被 LuCI `header.htm` 每一頁呼叫,也會被 `morse.sh` 每次 wifi up 呼叫,所以需要標記才能做到「每次開機一次」。
   - 標記如果放在可預測的 `/tmp/<name>`,就是 #280 那一類問題:root 會經由別人預先放好的 symlink 寫檔。
   - 請放在 root 0700 的目錄裡(要確認 S10 時 `/tmp/run/batman` 是否已經存在),或者乾脆不用檔案、只用 `logger`。
   - 另外寫明 `READALL` 也回 rc 1。

7. **B13-m7 — shim 的斷言要做成 build / 發行的閘門,不能只是一次性測試**(**PR-F / PR-P3 要求**)
   - `files/` 不在 `build-board.sh:77-80` BASE 髒樹檢查的範圍內,也不在 board patch witness 裡。shim 檔被誤刪或沒有 commit 時,build 照樣會過。
   - 轉賣工具的安全前提是「清單裡的每個 image 都有 shim」。所以要把下列檢查放進 `build-board.sh` 的卡片不變式步驟:rootfs 內 `persistent_vars_storage.sh READ <任一 key>` 回 rc 1、沒有輸出,而且檔案 sha == repo 裡的 shim。
   - 產生發行清單的步驟要拒收沒通過這項檢查的 image。

8. **B13-m8 — L1 的負對照(1.5.12 新卡的 AP 是開的)沒辦法用新工具燒**(文件)
   - 新工具會拒收 1.5.12。請寫明負對照用哪種方式燒卡(現行的 `flash-card.ps1` 或 `dd`),否則 L1 的負對照會被跳過,或者用錯工具。

9. **B13-m9 — SD 卡以外的其他殘留,誠實界線補一句**(文件)
   - GPS 模組如果有備援電池,BBR 會留著最後的定位(⚠️ 視模組而定)。
   - HAT ID EEPROM 或硬體植入屬於實體 actor,買家沒辦法偵測。
   - 未來的戰術 SKU 如果燒了 secure-boot OTP,買家的「bootloader 還原卡」會失敗。說明頁加一句:「EEPROM 還原失敗,就不要信任這台」。

## 3. 前輪發現的去向

| 發現 | 狀態 | 說明 |
|---|---|---|
| B12-M1 EEPROM 讀者 / `default_wifi_key` 成為新卡的 AP 金鑰 | EEPROM 部分 **addressed**;AP 部分 partial(→ m1) | shim 一次關掉 9 個讀者,我重掃沒有遺漏。新卡第一次開機的 AP placeholder 是對的。沒涵蓋到的是 OTA 中的 unclaimed 節點和 96 的其他出口(m1) |
| B12-M2 工具接受舊 Batman image | **addressed** | 內建發行清單 + sha256。前提是清單裡的 image 真的都有 shim(m7) |
| B12-m1 WSL / mmcblk | addressed | 但 `--internal-sd` 需要加「非系統碟」檢查(m4) |
| B12-m2 Windows 判斷 / `clean all` / #208 | addressed / partial | `BusType=USB` + 可移除 + ≤ 512 GB ✅;MediaType 的來源和 volume 釋放還沒寫(m3) |
| B12-m3 loop 測試的 override | addressed | 要加 regular-file 限制(m5) |
| B12-m4 7 個分割 / board 來源 | addressed | |
| B12-m5 EEPROM 開機設定 | addressed | §4.5 誠實界線 + §8 一列。我核對過 F24 的預設值:買家重設 EEPROM 不會影響 A/B,因為 02/04 都沒有自訂 BOOT_ORDER / PARTITION_WALK |
| B12-m6 其他讀者 | addressed | 併入 shim |
| B12-m7 L12 降級 | addressed | L12 已補註 |
| B12-m8 PR-F 機制 / docs | addressed | `files/` overlay 的機制我在 firmware 樹證實了(§0);建置閘見 m7 |
| A11-M1 重燒不清 p6 尾端 | **closed(設計層)** | 工具全卡寫零 + 抽樣驗證 + L16 工具層負對照(只寫 image → 特徵字串仍在)。實跑 ⚠️ 等 PR-P3 |
| B11-M1 同上(可行性) | **closed(設計層)** | Windows / Linux 的契約都可實作;m3/m4/m5 是實作要求 |
| B11-M2 EEPROM 裡的 key / 密碼撐過重燒 | **closed** | shim + 買家自行重燒 + 重設 EEPROM;`prov-eeprom-hooks-254` 有負對照 |

## 4. 逐 actor(只列 v13 改動到的面)

- **前任擁有者(惡意)**
  - EEPROM persistent var → shim 擋住 ✅。
  - EEPROM 開機設定 / bootloader → 買家用還原卡處理。Pi 4 的 boot ROM 會先讀 SD 卡上的 recovery.bin,所以惡意 bootloader 擋不住還原 ✅。
  - **RAK flash → 未處理(M1)**。
  - HAT / 硬體植入 → 擋不住(m9)。
- **買家(讀賣家的資料)**:SD 卡 → 工具寫零 ✅;**RAK → M1**。
- **BLE / 無線路人**:unclaimed 新卡的 AP 是關的 ✅;unclaimed 節點 OTA 之後,AP 用隨機 key 開著(m1)。
- **本機非 root**:shim 的標記檔(m6)。
- **攻陷的 provd**:v13 沒有改 helper 介面,前輪的結論不變。
- **供應鏈**:發行清單 + sha256 ✅;清單只能收有 shim 的 image(m7)。
- **我們自己**:`--test-target-file` / `--internal-sd` 可能誤清系統碟(m4/m5)。

## 5. PR 要求彙整

- PR-F:m6、m7(shim 的標記檔、建置閘)。
- PR-P1:m1、m2(99zz 的條件和契約;L44 斷言)。
- PR-P3:M1(說明頁 + L16 節點層斷言)、m3、m4、m5、m7(產生清單時的閘)、m8、m9。
