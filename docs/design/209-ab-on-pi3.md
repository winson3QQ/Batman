# Design: A/B on Pi 3 (bcm2710) —— 讓救援者待在受測槽之外 (#209)

Status: **DRAFT v3.1(v3 已過一輪對抗式 review = APPROVE-WITH-CHANGES,本版已吸收全部 MUST-FIX;待 E0 實機閘門)**
Parent: #209 · 父單 #203 / #89 · 姊妹 #133(Pi 4 A/B)· 前置修正 `fix/209-prereq-brick-paths`(`51ace51`,未 merge)
版本史:v1(U-Boot chainloader)= NEEDS-REWORK → v2(A1:寫後驗證 + preinit 計數器)未經 review → v3(A0:firmware 一次性分割槽開機)→ **v3.1:依 review 拆成 A0-auto(主案,若 E0f 過)/ A0-prefix(次案),補齊 sysupgrade 流程、槽選擇、編號推導與 p1 寫入風險**。
SoT: #75

## 0. 一句話

Pi 3 **有** firmware 層的一次性機制:**`reboot N`**(kernel 把 N 寫進 `PM_RSTS` 分割槽位元;NOOBS 在 Pi 1–3 就靠它)。任何**不帶參數**的重開(panic、一般 reboot、斷電)都回到預設分割槽。本設計用它做 trial —— 救援者是 firmware,不在受測槽裡,語意同 Pi 4 `tryboot`。
預設槽怎麼記:**若 Pi 3 的 `bootcode.bin` 支援 `autoboot.txt boot_partition`(E0f)→ A0-auto,版面與 `batman-slot` 幾乎全部沿用 Pi 4**;否則 A0-prefix(p1 `os_prefix`)。**E0 全過之前不得實作。**

## 1. Reality check(2026-09-30)

### 1.1 v2 的結構性缺陷:救援者住在受測槽裡

v2(A1)由**新槽自己的** `preinit` 鉤子遞減 `attempts_left`。新槽在 preinit 之前壞掉(kernel 缺 squashfs/mmc 驅動、`root=` 錯、壞 DT、preinit 鉤子本身 bug)→ 計數器永遠不動 → `panic=10` 無限迴圈。這類正是 OTA 最典型的失敗形態,且 v2 §5.1 的逐 byte 驗證擋不住(位元都對,是邏輯錯)。v2 §4 自己也把 ③ 標 ❌。→ v2 降為退路(§9)。

### 1.2 已查證的 firmware / kernel 事實

| 事實 | 來源 | 信心 |
|---|---|---|
| restart handler:`data && sscanf(data,"%lu",&val) && val < 63` 才設 partition,否則 **0**;寫入前先 `PM_RSTS_PARTITION_CLR` | rpi `drivers/watchdog/bcm2835_wdt.c`(rpi-6.6.y) | 高(讀碼) |
| OpenWrt 24.10 bcm27xx 帶此 downstream patch:`patches-6.6/950-0073-watchdog-bcm2835-Support-setting-reboot-partition.patch`、`950-0258`;bcm2710 `CONFIG_BCM2835_WDT=y` | OpenWrt tree | 高(review 查證) |
| `bcm2835_wdt_start` 只寫 `PM_WDOG`/`PM_RSTC`,不碰 `PM_RSTS` | 同上 | 高 |
| `partition` = 「requested partition number (`sudo reboot N`) or … `PM_RSTS`」 | 官方 `config_txt/conditional.adoc:252` | 高 |
| `config.txt` 的 `[partition=N]` = 「currently, Raspberry Pi 5 onwards」;`boot_arg1`/`boot_count` Pi 5+、`bootvar0` Pi 4+ | 同上 | 高 → **不依賴任何 config.txt 條件式** |
| NOOBS:`bootcode.bin` 讀 `autoboot.txt` 後直接切到指定分割槽;`start.elf` 從目標分割槽載入,可用 logical 分割號 | NOOBS wiki「NOOBS partitioning explained」 | 文件高 / 3A+ 適用性中(**E0f**) |
| `autoboot.txt boot_partition`:「unless the partition number was already specified as a parameter to the `reboot` command」,無機型限制標註 | 官方 `autoboot.adoc` | 高(文件)/ 未實測 |
| `os_prefix` 目錄缺 `overlays/README` → overlays 改從根目錄載入;前綴目錄缺 kernel → 有 viability fallback 讀根目錄 | 官方 `boot.adoc`(`os_prefix` 段) | 高(文件)/ 未實測 |
| panic 經 `emergency_restart` 傳 NULL;procd 一般 reboot 不帶參數 | 推論 | 中高 |

### 1.3 其他未完成 / 過時事項

| # | 事項 | 處置 |
|---|---|---|
| R1 | `51ace51` 已推但**沒開 PR、沒 merge**;v2 仍寫 `platform-ab.sh:55`「只 WARN」 | 先 merge;v3 以它為前提 |
| R2 | SoC gate 信任 payload 的 `board=`,而它是呼叫端傳入的標籤(`build-ab-payload.sh:31`),不是從 image 推導。目前唯一呼叫端(firmware `scripts/local-ab-tar.sh:16-25`)同時寫死 `BOARD=ekh-bcm2711`、bcm2711 目錄與 mm6108-spi image —— 今天還打不出 bcm2710 payload,但第一個 bcm2710 呼叫端一出現,標籤就是人工抄寫 | S4:`build-ab-payload.sh` 從 `root.squashfs` 的 `/etc/openwrt_release` 讀 `DISTRIB_TARGET` 生成 `board=`,與參數不符即拒 |
| R3 | `51ace51` 的 `95-batman-storage:69-75`:沒有名為 `data` 的分割時,**只要 p6 存在就選 p6**;`assert_not_system`(:89-97)只拒 squashfs / GPT 名稱 / rootfs GUID,**不拒 FAT**。MBR+extended 上若 trial/boot FAT 或 config 落在 p6 → 可能被 `mkfs`/`luksFormat`。且 `sgdisk` 在 MBR 卡上會記憶體內轉換、自動命名,結果不一定是「整段 REFUSE」 | S4:`assert_not_system` 加 **FAT(`0x55AA` + `FAT`/`MSDOS` 標記)硬拒**;用 E0d 定稿的真實版面跑 `tests/ab-card-invariants.sh` |
| R4 | 純 MBR 超過 4 分割需 extended → p4=extended、p5+ = logical;「p4 config / p5 data」字面不可能 | 版面依 E0d 定稿 |
| R5 | #209 issue 勾選框(D1、D7、S1、S2)未勾;S2 檔名與實際 `209-ab-on-pi3.md` 不符 | 更新 issue(未查證其餘內容) |
| R6 | #75 / #209 留言仍寫「先修 #217 R6(mm6108+mm8108)」,但 `917ca48` 與 #217 已以 manifest 證實 mm8108 不在 image | 更新 #75 |
| R7 | `storage-architecture.md:32-38` 仍寫 `tryboot.txt` | 同批改 |
| R8 | `98e598b`(移除 USB WiFi)未編入 image | 已轉 #217,不擋本單 |

## 2. 前提

- `51ace51` 先 merge(SoC gate 硬拒、不猜 data 分割、`is_trial` 內部錯誤回 2)。
- `rootwait=20 panic=10` 已烤進 bcm2710 image(firmware `dc81f7e`)。A0 的「panic → 回預設槽」依賴它。
- `batman-autocommit` 只呼叫 `is-trial` / `active` / `commit`(`batman-autocommit:26,32,108`)→ **不改**。

## 3. 三個動詞

| 動詞 | Pi 4(現況) | **A0-auto**(E0f 過) | A0-prefix(E0f 不過) |
|---|---|---|---|
| 一次性試開 | `vcmailbox` tryboot 旗標 + `autoboot.txt [tryboot]` | **`reboot <FW_other>`**(參數覆蓋 `boot_partition`) | `reboot <FW_T>`,trial 固定在 pT |
| 切換預設 | `write_autoboot()` 改 `[all] boot_partition` | **同 Pi 4,原封沿用 `batman-slot:89`** | p1 `os_prefix=A/`↔`B/` + 把 OS 檔大量寫入 p1(§5.4b) |
| 壞槽回退 | firmware fallback | 不需要:壞槽從不是預設,**無參數重開即回退** | 同左 |
| 版面 | bootA/rootA/bootB/rootB/config/data | **同 Pi 4**(bootA、bootB 各帶 firmware) | p1(A/ B/)+ pT + rootA/rootB + config + data |
| p1 寫入量 | 幾個 byte | **幾個 byte** | 數 MB–數十 MB(風險見 §5.4b) |

`batman-autocommit` 那句 `left as trial (reverts on reboot)` 在兩個變體上都**重新成真**。

## 4. 失敗類別

| 類別 | A0(兩變體相同) | v2 |
|---|---|---|
| ① trial 寫一半 / 缺檔 | apply 讀回驗證失敗 → 不發 `reboot N` | 讀回驗證 |
| ② 開得起來但功能壞 | 不 commit → 下次任何重開回預設 | 需新 rollback 路徑 + 計數器 |
| ③ `bcm2835_wdt` probe 之後才 panic(VFS 掛不上、init 死) | `panic=10` → handler 寫 partition 0 → 回預設 ✅ 自動 | ❌ 無限 panic |
| ③a **極早期 panic(壞 DTB、wdt probe 前)** | 沒有 restart handler → 卡住直到斷電 → 斷電回預設。**可恢復、非自動**(遠端節點 = 出勤一次) | ❌ 斷電後仍回壞槽 |
| ③b procd 接管 watchdog 後硬當 | **E0c 待驗**(PM_RSTS 是否保留 N) | 同 ③ |
| firmware 開目標分割失敗(缺 `start.elf`/kernel) | **E0b 待驗** | — |
| ④ 已 commit 後才壞 | 不屬 A/B(#216) | 同 |

A0 沒有計數器、沒有 preinit 寫入;trial 從不成為預設,所以兩槽都壞時停在已 commit 的槽,不會無限來回。

## 5. A0 設計

### 5.1 分割號:推導,不寫死

`reboot N` 的 N 與 `boot_partition` 都是 **firmware 分割號**。Pi 4 在 GPT 卡上實測 firmware 分割號 = 第幾個 FAT 分割,不是 GPT index(`build-gpt-ab-card.sh:127-146`,#133)。Pi 3 的 `bootcode.bin` 在 MBR primary / logical / GPT 上怎麼數 → **E0d 逐一記錄**;`batman-slot` 以 `fw_part()` 同樣的方式推導,**禁止寫死**。

### 5.2 apply(sysupgrade 路徑)

**槽選擇(review MUST-FIX 1)**:target = **other(committed)**,不是 other(active)。
- A0-auto:committed = `autoboot.txt [all] boot_partition`(`committed_fw()`,`batman-slot:185`)。
- A0-prefix:committed = p1 `os_prefix`。
- **`is-trial` 回 0(正在 trial)時 apply 硬拒**:否則 target = other(新槽) = 已 commit 的舊槽 → 舊槽 rootfs 被覆寫、p1 仍是舊 kernel → 回到預設時 kernel/rootfs 不搭 → 無限 panic。`batman-slot:134` 的「target is mounted」防線在 ramfs pivot 後已卸載,擋不住。

硬性順序,任一步失敗即中止,**不發 `reboot N`**:

1. 寫 target rootfs。
2. 寫 target 開機 FAT(A0-auto:bootA/bootB;A0-prefix:pT)的 OS 檔 + `cmdline.txt`(`batman_slot=<S> batman_trial=1`)。A0-prefix 另寫 pT 的 `config.txt` = **p1 `config.txt` 去掉 `os_prefix` 那行的逐 byte 複本**(MUST-FIX 7b)。
3. `sync` → **讀回比對 checksum**(rootfs + 每個開機檔)。`md5sum`/`sha256sum` 進 `RAMFS_COPY_BIN`(MUST-FIX 8)。
4. `sync` → **umount target 開機 FAT** → `batman-reboot-part <FW_target>`,**在 `platform_do_upgrade` 內呼叫且不 return**(MUST-FIX 8)。理由:`platform_do_upgrade` return 後 stage2 會自己**無參數** reboot → 回預設 → trial 靜默消失;而直接 reboot 會跳過 stage2 的 `umount -a`,所以 sync/umount 必須自己做。

`batman-reboot-part`:~20 行 C,呼叫 `reboot(LINUX_REBOOT_CMD_RESTART2, "N")`(busybox `reboot` 帶不了參數)。bcm2710 上取代 `vcmailbox`,進 `RAMFS_COPY_BIN`。

apply 不碰已 commit 的開機檔;A0-auto 也不碰 `autoboot.txt`(同 Pi 4 `cmd_apply` 的規矩)。

### 5.3 is-trial / active / assert

- `active`:`/proc/cmdline` 的 `batman_slot=`(不變)。空 → `is-trial` 回 **2**。
- `is-trial`:`batman_trial=1` 且 active ≠ committed → **0**(trial);active == committed → **1**(同一次開機內已 commit,不 die);`batman_trial` 不存在 → 1。
- `assert_fw_sane`:非 trial 時 active 必須 == committed;trial 時 active 必須 == other(committed)。
- trial 中 `batman_trial=1` 留在 cmdline 直到重開,這是預期的(commit 只改預設)。

### 5.4 commit

**5.4a A0-auto**:與 Pi 4 相同 —— `write_autoboot()`(`batman-slot:89`:同目錄 staging → sync → rename → sync → `ab.good` 錨點)把 `[all] boot_partition` 改成現在的槽。另把本槽 `cmdline.txt` 的 `batman_trial=1` 去掉(**寫的是本槽自己的開機 FAT,不是 p1**;斷電 → 下次仍以 trial 標記開機 → `is-trial` 依 active==committed 回 1,無害)。p1 寫入量 = 幾個 byte,符合 `field-resilience.md:55` 的承諾。

**5.4b A0-prefix**:把 pT 的 OS 檔複製到 p1 的非現用目錄 → 讀回比對 pT → flip `os_prefix`(同 `write_autoboot` 手法)。**誠實標示(MUST-FIX 2)**:這是往唯一存放 `bootcode.bin`/`start.elf` 的 p1 寫入數 MB–數十 MB;FAT 表與根目錄是共用 metadata,SD 卡斷電撕裂寫入**不只影響非現用目錄**,與 `field-resilience.md:55` 衝突。若只能走 A0-prefix,必須擇一:
- 非現用目錄採**預先配置、固定大小檔案原地覆寫**(不改 FAT 鏈、不改目錄項),寫入只落在資料區;或
- 明文承認 p1 在 commit 期間有變磚風險,量測 commit 時長,並列為 release 風險。

另:commit 驗證必須斷言 `<dir>/overlays/README` 存在(MUST-FIX 7a;否則 firmware 靜默改用 p1 根目錄的 overlays,commit 的 ≠ 測過的)。

**兩變體共同**:`config.txt` / `autoboot.txt` 損毀時的 firmware 行為 = E0e;A0-prefix 另可刻意利用 `os_prefix` viability fallback(p1 根目錄放一套已知良好 OS 檔當最後防線)。
⚠️ Windows 端絕不可用 `Set-Content` / `>` 寫開機分割的檔案(CRLF,#208)。

### 5.5 rollback

- trial 中:什麼都不寫,無參數 `reboot` 即回預設。
- 已 commit 後:A0-auto = `write_autoboot` 指回另一槽(同 Pi 4 `cmd_rollback`);A0-prefix = flip `os_prefix`。

### 5.6 trial 結果回報(review SHOULD-FIX)

trial 被靜默退回時沒人知道升級失敗(#132 morse SPI 偶發 init 失敗這類 flake 會讓 OTA 靜默失敗)。回到預設槽開機時:若另一槽的開機 FAT 帶 `batman_trial=1` 且版本 ≠ 已 commit 版本 → 在 `log/` 記一筆 `TRIAL-REVERTED <version>` 並上報(沿用 #216 的健康回報通道)。唯讀檢查,零寫入於開機 FAT。

### 5.7 改動面

| 檔案 | A0-auto | A0-prefix |
|---|---|---|
| `batman-slot` | bcm2710 分支:apply 的觸發改 `batman-reboot-part`、is-trial 改 cmdline、槽選擇改 other(committed);commit/rollback/`write_autoboot` **沿用** | 另加 os_prefix 讀寫與 p1 目錄寫入 |
| `platform-ab.sh` | per-SoC `RAMFS_COPY_BIN`(`batman-reboot-part`、`md5sum`);do_upgrade 內 reboot 不 return | 同 |
| `build-ab-payload.sh` | per-SoC 清單(bcm2710:`start.elf`/`fixup.dat` 是否隨 payload,依 E0a 的凍結結論);`board=` 由 squashfs 推導(R2) | 不收 firmware blob |
| 新套件 `batman-reboot-part` | ~20 行 C | 同 |
| 卡 builder | 沿用 `build-gpt-ab-card.sh`,依 E0d 調整分割表型態 | 新 builder |
| `95-batman-storage` | FAT 硬拒 + 真實版面 invariants(R3) | 同 |
| `ab-selftest.sh` / `daily-validation.sh` | board guard;新斷言:trial 可進入、無參數重開回預設、commit 後 committed == active、trial 回報存在 | 同 |
| `batman-autocommit` | **不改** | 不改 |

## 6. 明確不保護 / 尚未知道

- ③a 極早期 panic:可恢復、非自動(斷電)。
- ③b watchdog 重開是否回預設:E0c。
- firmware blob(`bootcode.bin`,A0-prefix 另含 `start.elf`)不受 A/B 保護 —— 對等於 Pi 4 EEPROM;凍結版本 = E0a 實測過的那份。
- A0-prefix 的 commit 期間 p1 風險(§5.4b)。

## 7. 失效矩陣(全部待實測,照 #133 規格)

| 情境 | 期望 | 已驗? |
|---|---|---|
| apply 中斷電 | 預設未動 → 回舊槽 | 🔴 |
| 在 trial 中再跑 sysupgrade | **apply 拒絕**(§5.2) | 🔴 |
| trial kernel 缺失 | E0b | 🔴 |
| trial VFS panic(`root=` 指錯) | `panic=10` → 回預設 | 🔴 |
| trial 壞 DTB(極早期) | 卡住 → 斷電 → 回預設 | 🔴 |
| trial 開得起來但不健康 | 不 commit → 重開回預設 + `TRIAL-REVERTED` 回報 | 🔴 |
| trial 中 watchdog 重開 | E0c | 🔴 |
| trial 中斷電 | 回預設 | 🔴 |
| commit 中斷電 | A0-auto:`ab.good` + 讀回;A0-prefix:§5.4b | 🔴 **必須明確處理** |
| `autoboot.txt` / `config.txt` 損毀 | E0e | 🔴 |
| payload `board=` 與 image 不符 | build 時拒(R2)+ on-node SoC gate | 🔴 |
| `cmdline.txt` 缺 `batman_slot=` | is-trial=2 → 不 commit → 重開回預設 | 🔴 |
| bare `rootwait` 混入 | `ab-selftest.sh:129-131`(加 bcm2710 guard) | 🔴 |
| data 分割辨識在真實版面上 | invariants 通過、FAT 被拒(R3) | 🔴 |

## 8. 實驗(**E0 = 閘門**)

工具取得:**E0f/E0a/E0b 的 firmware 語意可先用 Raspberry Pi OS 卡的 `sudo reboot N` 驗**(kernel 端已由 patch 0073 確認);OpenWrt 上需交叉編譯一支靜態 `batman-reboot-part`(不需重編 image,scp 上去即可)。

| # | 實驗 | 回答 | 失敗時 |
|---|---|---|---|
| **E0f**(先做) | 3A+、兩個開機 FAT:p1 放 `autoboot.txt`(`[all] boot_partition=<FAT2>`),兩者 cmdline 各帶標記。① 開機落在哪;② `reboot <FAT1>` 是否一次性覆蓋;③ 改 `boot_partition` 後是否切換 | A0-auto 是否成立 | 走 A0-prefix |
| **E0a** | `reboot N` 是否從分割 N 開機、`start.elf` 是否從 N 載入;記錄 `bootcode.bin`/`start.elf` 版本、`/proc/device-tree/chosen/bootloader/{partition,rsts}` 是否存在、**`/proc/device-tree/psci` 是否存在**(bcm2710 `CONFIG_ARM_PSCI_FW=y`,PSCI restart handler 可能搶在 wdt 之前) | 一次性試開的基礎 | A0 不成立 → A1(§9) |
| **E0b** | 在 trial 開機後:panic(`echo c > /proc/sysrq-trigger`)/ 一般 reboot / 斷電 → 都回預設?另:trial 缺 kernel、`root=` 指錯(VFS panic)、壞 DTB 三種 | 一次性語意、③/③a | 同上 |
| **E0c** | trial、procd 接管 watchdog 後 `kill -STOP 1` → 回預設還是 trial? | ③b | 接受(斷電可恢復)或 early userspace 清 PM_RSTS |
| **E0d** | 分割表型態:純 MBR(primary / logical)、純 GPT(**Pi 4 卡是純 GPT,`build-gpt-ab-card.sh:65-68` `sgdisk --zap-all`,無 hybrid**)、GPT+hybrid MBR(**hybrid 最多 3 個可見實體 entry**,開機 FAT 必須落在其中)→ 哪些能開、firmware 分割號怎麼數 | §5.1、R3/R4 | 取可行者 |
| **E0e** | `autoboot.txt` / `config.txt` 截斷、清空、不存在;A0-prefix 另測 `os_prefix` viability fallback(前綴目錄缺 kernel 時是否讀根目錄) | commit 的最後防線 | 依結果定 |

E0 全過後:S4 實作(§5.7,`51ace51` 先 merge)→ S5 §7 全項實測 → S6 board guard 與 S4 同批 + daily-validation 新斷言。

## 9. 替代方案(降級順序)

1. **A0-auto**(主案)→ 2. **A0-prefix**(E0f 不過)→ 3. **A1 / v2**(E0a/E0b 不過;已知缺陷 §1.1,需以 build 時 kernel/rootfs 一致性檢查 + bench gate #113 當 release gate)→ 4. **A2 U-Boot**(第二期;v1 review M1–M8 全數適用,原文見 `882f32d` §8,**M6「誰套用 DT overlay」為前提**)。
- initramfs 層 A/B:救援者同樣在 kernel 之後,不解決 §1.1,不再列入。
- RAUC:A0-auto 的動詞集可對映成 RAUC custom bootloader backend,列入 #89 後續評估。

## 10. 連帶要改的文件與 issue

- `docs/storage-architecture.md:32-38`:移除 `tryboot.txt`,改寫為 D1/D7 結論 + E0 定稿的版面。
- `docs/field-resilience.md:55`:Pi Zero → Pi 3A+;A0-auto 仍符合「p1 只寫幾個 byte」,A0-prefix 則需改寫此承諾。
- #209 issue 勾選框與檔名(R5)、#75 樹上 R6 文字。

## 11. v1 的事實錯誤更正(保留)

1. `field-resilience.md` 的 #89 領先候選是 RAUC + Rtone Raspberry Pi firmware bootloader backend。
2. `kernel8.img` 只有檔名兩板共用。
3. Pi 3 版面不是既定的六分割 —— v3.1:A0-auto 反而可能與 Pi 4 相同,由 E0d/E0f 定。
4. `os_prefix` 不能給 chainloader 做 A/B(M4)。
5. initramfs 以 §1.1(救援者位置)排除,不是成本。

## 12. Review 紀錄

**v3 review(獨立 reviewer,2026-09-30):APPROVE-WITH-CHANGES。** 認定 A0 方向成立(救援者移出受測槽)。MUST-FIX 1–8 已於 v3.1 吸收:
1. trial 中 sysupgrade 覆寫已 commit 槽 → §5.2 槽選擇 + 拒絕
2. commit 大量寫 p1 的風險被低估 → §3 拆變體、§5.4b 誠實標示
3. 漏了 Pi 3 `autoboot.txt boot_partition` → A0-auto + E0f
4. N 的編號未定義 → §5.1 推導
5. E0d 前提寫錯(Pi 4 卡是純 GPT)、hybrid 3 entry 限制 → §8
6. R3 不完整 → FAT 硬拒 + 真實版面 invariants
7. 測過的 ≠ commit 的(overlays README、兩份 config.txt)→ §5.2/§5.4b
8. sysupgrade 流程(stage2 無參數 reboot 吃掉 trial、ramfs 工具)→ §5.2

SHOULD-FIX 已吸收:③/③a 分級、trial 結果回報(§5.6)、is-trial 規格、R2 措辭、E0a 記錄 blob 版本與 PSCI、E0e viability fallback、「不需 build」改為「可用 RPi OS 卡 + 靜態工具」。

**Verdict:** _(E0 結果出來後填寫;v3.1 是否需要二輪 review 由 E0f 結果決定 —— 若 A0-auto 成立,設計面大幅縮小,建議針對 §5.2/§5.3 做一次聚焦 review 即可)_

## 參考

- #209(D1/D7)· #203 · #89 · #133 · #217 · #208 · #104 · #113 · #132 · #216
- rpi kernel `drivers/watchdog/bcm2835_wdt.c`(rpi-6.6.y);OpenWrt `target/linux/bcm27xx/patches-6.6/950-0073-*`
- Raspberry Pi docs:`config_txt/conditional.adoc`、`config_txt/autoboot.adoc`、`config_txt/boot.adoc`(`os_prefix`)
- NOOBS wiki「NOOBS partitioning explained」
- `docs/design/ab-sysupgrade-platform.md` · `docs/design/ab-autocommit.md` · `docs/field-resilience.md` · `docs/storage-architecture.md`
