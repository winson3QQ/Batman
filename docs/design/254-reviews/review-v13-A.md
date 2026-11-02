# #254 階段 1 設計 v13 — 審查 A(第 13 輪)

**判定:APPROVE-WITH-CHANGES — 0 BLOCKER / 0 MAJOR / 11 MINOR**
對象:`design/254-stage1-impl` @ ad35e32 `docs/design/254-stage1-impl.md`(v13)。全程唯讀:WSL build rootfs `root-bcm27xx`(feat/254-ble a5e181b7 的 build)、Batman repo、`flash-card.ps1`;04/02 只跑 `uci show`、`vcgencmd bootloader_config/otp_dump`、`ls`、`cat`、`ubus list`。

## 0. 結論
- v13 的 shim 做法**可行,而且方向對**。我獨立重掃 build rootfs:讀 `persistent_vars_storage.sh` 的程式就是 F21 列的 9 個,寫者只有 `save_dropbear_setup.sh`,沒有漏。另外唯一直接呼叫 `vcgencmd bootloader_config` 的是 `95-batman-storage:418`,它只把 `BOOT_ORDER|PARTITION_WALK` 寫進 log,無害(F21 沒列,見 m11)。
- shim 的「READ 一律 rc 1、無輸出」**和 02/04 今天的實際行為完全一樣**:key 不存在時,原腳本本來就是 stdout 空、rc 1(`sbin/persistent_vars_storage.sh` 的 READ 分支);而 02/04 的 EEPROM 沒有任何 persistent var。我重跑確認過:04 = `BOOT_UART=0 WAKE_ON_GPIO=1 POWER_OFF_ON_HALT=0 NET_INSTALL_AT_POWER_ON=1`;02 = 前三項。
- **BCF 不受影響**:`morse.sh:135-143` 只在 uci 的 `bcf` 為空時才看 `mm_sku`;`99_morse_radio_defaults` 依 board 把 bcf 寫死(`bcm2711,mm6108-spi → bcf_fgh100mhaamd.bin`)。04 實際值 `wireless.radio1.bcf='bcf_fgh100mhaamd.bin'`。
- **區域鎖**:shim 之後,`morse.sh:471-476` 的 EEPROM 區域鎖永遠不生效。今天它也不生效(EEPROM 是空的),所以不算回歸;但要不要區域鎖是產品法規的決定(m4)。`01-region-restriction` 確實沒有程式會執行它:rootfs 裡提到 `boot-defaults` 的只有 `morse-bundle.list`。
- **files/ overlay 可行**:`package/Makefile:119` 與 `include/image.mk:396` 都會呼叫 `prepare_rootfs(..., $(TOPDIR)/files)`。`include/rootfs.mk` 的 `prepare_rootfs` 先做 `file_copy files/.`,之後才跑 postinst,所以會蓋過套件裡的同名檔。pick-rootfs 用的 squashfs 走 image.mk 那條,卡與 payload 都會帶到 shim。問題是 `files/` 目前**完全沒進 git**(`git ls-files files` 沒有輸出)→ m3。
- **99zz 的 AP placeholder**:執行順序是對的。`/etc/init.d/boot` 依序跑 `config_generate` → `wifi config` → `uci_apply_defaults`(依 `ls` 排序);uci-defaults 的順序是 95-morse-wireless-defaults → 96 → 97/98/99-* → 99_morse… → 99zz;S18 keyguard 在 S19 wpad 與 S20 network 之前。keyguard 確實會把 `mode='ap'` 且 key == `CHANGE-ME-NOW` 的 AP 關掉(`etc/init.d/halow-keyguard`)。**但「p5 未 seed、無 prov」這個條件,沒涵蓋 unclaimed 節點的第二個 fresh overlay**(m1)。
- F23 正確。`meshpoint-1.8.0` 只改 morse 的 `default_$RADIO`(改成 mesh、key `CHANGE-ME-NOW`),對 AP 只改 `network=ahwlan`。`mac80211.uc:107-115` 產生 `ssid OpenWrt / encryption none` 的 AP;接著 `morse-wireless-defaults:140-158` 把它改成 psk2、key 設為 `default_wifi_key`,並刪掉 `disabled`。這把 key 由 `tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8` 產生(`:19-22`)。
- 沒有找到會丟資料、讓節點保持開放、或讓任何 actor 得利的問題,所以沒有 MAJOR。

## 1. v12 / v11 發現的去向

| 發現 | 狀態 | 說明 |
|---|---|---|
| B12-M1 EEPROM 讀者 / AP 金鑰 | **addressed**(shim);AP 部分 **partial** | shim 一次關掉 9 個讀者 ✅;但 unclaimed 節點的 AP 只在第一個 overlay 是關的,OTA 或清 overlay 之後會開(m1) |
| B12-M2 轉賣工具收舊 image | addressed | 工具內建 sha256 清單;§4.5 講舊 image 的那段已刪 |
| B12-m1 WSL / mmcblk | addressed | |
| B12-m2 Windows 判斷 / 進度 / #208 | addressed;實作細節見 m7 | 自寫的寫零迴圈要先卸載卷 |
| B12-m3 loop override | addressed | `--test-target-file` + 負測試 |
| B12-m4 7 個分割 / board 來源 | addressed | |
| B12-m5 EEPROM 開機設定 | addressed;延伸見 m5、m6 | |
| B12-m6 其他讀者 | addressed | 我重掃確認 |
| B12-m7 L12 | addressed | |
| B12-m8 機制 / docs | addressed;落地細節見 m3 | |
| A11-M1 / B11-M1(重燒不清 p6 尾端) | **closed(設計層)** | 全卡寫零 + 抽樣讀回 + loop 負對照;節點層 L16 仍 ⚠️ 待現場 |
| B11-M2(前任經 EEPROM 保留 SSH) | **closed** | shim 讓 `31_dropbear_persistent_storage` / `31_password` 讀到空;另有買家自己重燒 + 重設 EEPROM |

## 2. MINOR(PR 要求已標)

### A13-m1 — 99zz 的條件沒涵蓋「已有 prov 的 unclaimed」,OTA 或清 overlay 後 AP 會用隨機金鑰開啟【PR-P1 要求】
- **情境**:新卡開機(L1)時,helper 產生身分,並用 `--prov-only` 把 `prov{unclaimed}` 寫進 p5(不寫 `.seeded`,§4.3)。之後做 L44 的 `sysupgrade -n`,或 L60 清 overlay。新 overlay 第一次開機時:
  1. 96 在 `:93` 之前把 prov 抄進 overlay,然後在 `:93` 因為未 seed 而退出;
  2. 95 早已把 AP 設成 psk2 + 隨機 8 字元;
  3. **99zz 看到「有 prov」就不動**;
  4. keyguard 因為 key 不是 placeholder 而不擋 → AP 開啟。

  這違反 §1.4「unclaimed:AP 關」與 219 §6.2。
- **影響**:金鑰空間 62^8、完全隨機、沒有人知道,實務上沒有人能得利,所以是 MINOR。但 L1 的不變式到第二個槽就不成立了,而且目前沒有測試抓得到(L44 / L60 的測試都沒斷言 AP)。
- **修法**:99zz 的條件改成「fresh overlay **且** 96 verdict=`unseeded` **且**(overlay 無 prov **或** overlay `prov.meta` 的 state=unclaimed)」。L44、L60 各加一條斷言「`iw dev` 沒有 AP 介面」;負對照 = 用 v13 原條件跑 → AP 在。

### A13-m2 — 99zz 的輸入與寫入契約前後不一致【PR-P1 要求】
- **哪裡不一致**:
  - §3 說 `/etc/.batman-prov-restore` 的唯讀者只有 helper,§4.2 說它「不影響判斷」;但 99zz 要知道「p5 未 seed」只能讀這個檔(96 已經卸載 p5)。
  - §4.4 步驟 8 說 `--firstboot`(99zz)「不碰 uci」,§3 / §4.5 又要 99zz 改 AP key。
- **要寫明的事**:
  - 99zz 的輸入 = verdict 檔 + overlay 的 `prov.meta`。
  - verdict 不是 `unseeded`(mount 失敗、bypass、非 ext4…)→ 不動 AP。這和今天相同:96 沒還原時,AP 本來就是沒人知道的隨機 key。
  - uci 由 99zz 的 shell 部分寫;helper `--firstboot` 只寫 prov-state。
  - commit 是靠 `uci_apply_defaults` 結尾的 `uci commit`,還是 99zz 自己 commit。
- **D5 的字要改**:「99zz 排最後」不精確。依 `ls` 排序,`luci-i18n-*` 排在 `99zz` 之後(見 rootfs `etc/uci-defaults/` 清單)。它們不碰 wireless,無害,改字即可。

### A13-m3 — shim 落地細節【PR-F 要求】
- **進 git**:`files/` 目前完全沒進 firmware git(`git ls-files files` 沒有輸出;`.gitignore:39-40` 只忽略兩個 build 產生的檔)。PR-F 必須真的 `git add files/sbin/persistent_vars_storage.sh`,否則換一台機器 build 就沒有 shim。
- **斷言每次 build 都跑**:放進 `scripts/check-image-manifest.sh`(build-board.sh 步驟 6),並對 pick-rootfs 的 squashfs 檢查,不要只當 PR-F 一次性的測試。斷言內容:
  - 檔案 sha 等於 repo 版本;
  - 對 `all_keys` 加上 `mm_sku` / `mm_region_unlocked` 逐一 `READ`,全部 rc 1、無 stdout。
- **WARN 的寫法**:「每次開機每個 key 記一次 WARN」如果用 `/tmp` 標記檔,就是 root 寫入可預測的檔名,非 root 程序可以先建 symlink(違反 tmp-trust 規則)。改成只用 `logger`(不去重),或把標記放在 root 0700 的 `$RUNDIR`。
- **READALL**:shim 也要處理,回空、rc 1。

### A13-m4 — 區域鎖機制消失是產品 / 法規決定,要列給使用者
- shim 之後,HaLow 的國家只由 uci / `halow-setkey --channel` 決定,不再有任何硬體層的區域鎖(`morse.sh:471-476` 失效)。
- 今天 EEPROM 是空的,本來也沒有鎖,所以不是回歸。但商業 SKU 如果要賣到不同法規區,原本可以用的 Morse EEPROM 區域鎖就沒了。
- 修法:§12 加一題給使用者決定(例如之後由 608B 或簽章的 SKU 設定處理)。不擋階段 1。

### A13-m5 — 不是只有「實體接觸」才寫得到 EEPROM:遠端 root 也能經 boot 分割讓 bootloader 自我更新
- **機制**(⚠️ 依 Raspberry Pi 文件推論;受唯讀限制,未實測):
  - root 把 `recovery.bin` + `pieeprom.upd` 放到 p1 再重開,bootloader 就會改寫 EEPROM,包括 `BOOT_ORDER` 與 HTTP / 網路開機。
  - image 內有 `vcmailbox`(`RAMFS_COPY_BIN` 也帶著),能寫 OTP;搭配 EEPROM 的 secure-boot 設定,可以把板子永久鎖成只開某把金鑰簽過的 image。
  - `otpset` 雖然在 image 內,但 image 沒有 python3,用不了。
- **後果**:任何拿到 root 的攻擊(legacy 的 #137、未來的 bug)都能留下**撐過重燒卡**的開機路徑改動;OTP 鎖則會讓板子變成不可逆的磚。
- **修法**(文字 + 一個小偵測):
  - F21 / §8 改成「實體接觸或 root」。
  - `95-batman-storage:418` 已經把 `BOOT_ORDER|PARTITION_WALK` 寫進 log;改成和預期基準比對,不同就 WARN,並在 `halow-status` 顯示。
  - 說明文件加「節點被入侵後的恢復 = 重設 EEPROM + 用轉賣工具重燒」。
  - OTP / secure-boot 鎖寫進誠實界線:重設 EEPROM 也救不回來。

### A13-m6 — 叫買家「用 Imager 重設 EEPROM」,但 bootloader 版本沒有釘【PR-P3 要求】
- Batman A/B 依賴特定的 bootloader 行為:`batman-slot:143-147` 有 2025-08-20 的版本下限,記憶裡也有 2026-09-23 版開錯槽的事件。說明頁叫買家用 Imager 當下附的版本 → 可能裝上沒驗過的 bootloader。
- 修法:說明頁寫明經過驗證的 EEPROM 版本,或由轉賣工具產生釘死版本的 recovery 卡。開機時的 bootloader 版本檢查已經存在,文件引用它即可。

### A13-m7 — Windows 寫零迴圈的前置條件與 image 格式【PR-P3 要求】
- **要先卸載**:Windows 會拒絕對已掛載卷所在磁區的原始寫入;`flash-card.ps1` 用 `Clear-Disk` 正是為了卸載。§4.5 第 3 點只寫「不用 Clear-Disk -RemoveData」,要改成「先移除分割 / 卸載卷(可以用 Clear-Disk,但只當卸載,不當清零),再寫零」。
- **`MediaType` 的來源**:`Get-Disk` 沒有這個屬性。要指明來源(`Win32_DiskDrive.MediaType = "Removable Media"` 或 `Get-PhysicalDisk`),並在實際的讀卡機上確認回傳值(⚠️ 不同讀卡機回傳不一致)。
- **sha 對象**:清單裡的 sha256 是壓縮檔的還是解壓後 raw image 的,要寫明。如果工具接受壓縮檔,就先驗壓縮檔的 sha 再解壓。

### A13-m8 — 轉賣的掃描範圍:SD 卡與 Pi EEPROM 以外的機身狀態
- **我查過、不必處理的**:
  - HAT ID EEPROM:`hat-v1-spec.md §5.7` 已拿掉;04 沒有 `/proc/device-tree/hat`。
  - customer OTP:04 第 36–43 列全為 0;image 內只有 `otpset` 會讀它。
  - HaLow 模組:`morse_cli` 只有讀 OTP 的子命令(board type / country code)。
  - RTC:04 沒有。
- **要補進賣方 / 買家說明**(PR-P3):
  - **RAK4631 Meshtastic 模組**是獨立的、不接 Pi,它自己的 flash 留著賣方的頻道 PSK 與位置設定,轉賣工具清不到 → 說明頁加「Meshtastic 模組要另外做 factory reset」。
  - HAT v1 的 RV-3028(之後的戰術 SKU)有 user EEPROM 與時間,列為殘項。

### A13-m9 — §3 漏列的 live wireless 寫者(目前都不會觸發)
- **漏列的寫者**:
  - `dpp-handler`(S90,ucode):`apply_config` 會寫 uci 並 commit;`ubus call dpp push_button` 可以觸發它(04 的 `ubus list` 有 `dpp`)。
  - `rc.button/wps`:寫 wireless。
  - `rc.button/rfkill`:改 `disabled`。
  - `rc.button/reset_override`:按 <2 s → DPP push;≥10 s → 恢復出廠。
- **目前為何不會觸發**:04 沒有 gpio-keys(`/proc/bus/input/devices` 是空的),按鈕路徑今天不會發生;ubus 路徑需要 root 或 LuCI session。
- **修法**:
  - §3 的「live uci wireless」加一列「inert:dpp-handler / rc.button(沒有按鍵硬體)」。
  - PR-P1 改 `rc.button/reset` 時,一併處理 `reset_override`。
  - 考慮在 image 停用 dpp-handler,讓 member 的 wireless 只有 helper 交易一個寫者。

### A13-m10 — `prov-eeprom-hooks-254` 的負對照在節點上做不到【PR-H1 要求】
- **問題**:「PATH 上的假 `vcgencmd`」必須在 fresh overlay 的 S10 生效,但節點上沒有乾淨的做法:放 overlay 會被清掉,放 /rom 要重新 build。在 shim image 上這個測試一定 PASS(shim 根本不呼叫 vcgencmd);而負對照(1.5.12 會採用 EEPROM 值)沒有地方可以跑。
- **修法**:在 WSL 對解出的 rootfs 跑 31_* 與 morse-wireless-defaults(stub 掉 `uci` / `ubus` / `vcgencmd`,用 `IPKG_INSTROOT` 的方式),同一套對 1.5.12 的 rootfs 跑當負對照。節點上只做「shim 檔 sha + READ rc 1」。

### A13-m11 — 文字
- §4.5 第一段仍寫「image 內建的兩個 uci-default 會從 Pi EEPROM 讀 SSH 公鑰與 root 密碼」→ 改成 9 個讀者(F21)。
- F21 補一句:`95-batman-storage:418` 直接讀 `bootloader_config`,但只 log `BOOT_ORDER|PARTITION_WALK`;shim 不影響它,也不需要影響。

## 3. 生命週期 / 平台檢查(shim 與 99zz)

| 路徑 | 結果 |
|---|---|
| 新卡 | 99zz 設 placeholder → keyguard 關 AP ✅(F23 推論 + 原始碼;⚠️ L1 實卡待做) |
| OTA(legacy) | p5 已 seed → 99zz 不動;96 Lane B 還原 `default_radio0.key`(config-save `:34` 有存這個值)✅ |
| OTA(unclaimed) | ❌ AP 開(m1) |
| OTA(claimed,原本是 unclaimed) | `--save` 把 placeholder AP key 存進 overrides → 96 還原 → keyguard 關 ✅ |
| 清 overlay(L60) | unclaimed ❌(m1);其他狀態同 OTA |
| downgrade | L12 已註明舊 image 會重跑 EEPROM 讀者 ✅ |
| bcm2710 | files/ 兩板共用 → shim 也會進 3A+;U6 未測(既有的 ❌) |
| crash / 斷電 | shim 無狀態;99zz 在 S10 中斷 → 該 uci-default 沒被刪,下次會重跑,而且冪等 ✅ |

## 4. 證據摘錄
- rootfs `grep -rIl -e persistent_vars_storage -e bootloader_config -e vcgencmd`:讀 persistent vars 的就是 F21 的 9 個;其餘的 vcgencmd 用途是 `get_throttled` / `bootloader_version` / `measure_temp`。
- 04:`wireless.radio1.bcf='bcf_fgh100mhaamd.bin'`;`default_radio0.mode='ap'`、`encryption='psk2'`;OTP 36–43 = 0;`ls /proc/device-tree/hat` → 不存在;沒有 `/dev/rtc*`;`/proc/bus/input/devices` 沒有按鍵。
- 02:`vcgencmd bootloader_config` = `BOOT_UART=0 WAKE_ON_GPIO=1 POWER_OFF_ON_HALT=0`。
- firmware:`include/rootfs.mk` 的 `prepare_rootfs` 先 `file_copy $(2)/.`,之後才跑 postinst;`git ls-files files` 沒有輸出。
