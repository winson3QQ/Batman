# Design: A/B on Pi 3 (bcm2710) —— 沿用 Pi 4 設計,只處理差異 (#209)

Status: **DRAFT v4.3(v4 NEEDS-REWORK → v4.1 APPROVE-WITH-CHANGES → v4.2 → 本版併入 E0g 實機結果:p7 版面可行、p7 必須有 `config.txt`、`autoboot.txt` 損壞 = 磚化 → commit 改為單一磁區原始寫入;下一步 S3/S4)**
Parent: #209 · 父單 #203 / #89 · 姊妹 #133(Pi 4 A/B)· 前置 #230(`fix/209-prereq-brick-paths`)
SoT: #75
版本史:v1 U-Boot chainloader(NEEDS-REWORK)→ v2 preinit 計數器(救援者在受測槽內)→ v3/v3.1 A0:firmware `reboot N`(APPROVE-WITH-CHANGES)→ v4:E0 證實 Pi 3 支援 tryboot、hybrid MBR 可開 Pi 4 的 GPT 版面 → 沿用 Pi 4(NEEDS-REWORK)→ **v4.1:補齊 memcg、/tmp、SoC gate、讀回驗證、firmware 白名單、watchdog;bootcode/autoboot 移到獨立 firmware 分割**。v1–v3.1 全文見 git(`882f32d`、`bc62c0e`)。

## 0. 一句話

Pi 3A+ firmware **支援 tryboot**,在 **hybrid MBR** 卡上可以開 Pi 4 的 GPT 六分割版面。所以 Pi 3 **沿用 Pi 4 的動詞與版面**(`batman-slot`、`batman-autocommit`、p5 config、p6 data、tryboot/autoboot)。與 Pi 4 的差異有兩類:(1)**Pi 3 沒有 EEPROM**,ROM 從卡上讀 `bootcode.bin`/`autoboot.txt` → 這兩個檔移到一個 OTA 永遠不寫的**獨立 firmware 分割**;(2)**512 MB、memcg 未開、firmware 版本、SoC gate** 等 Pi 4 沒遇過的限制。本文件只寫差異、處理方式和失效後果。

## 1. 實機證據(manet03 = Pi 3A+;原始紀錄在 #209)

| 實驗 | 結果 | #209 留言 |
|---|---|---|
| E0f:`reboot N` / `autoboot.txt boot_partition`,trial 在 MBR 第 4 格 | 1.20250430 **開不了 MBR 第 4 格**(ACT 閃 7 = kernel not found,不回退,需斷電)= rpi-eeprom#705,修正 `0ea2874060`;換 1.20250915 後 ①–⑦ 全過 | 5913161359(判定已作廢)、5913551696 |
| tryboot(MBR) | `vcmailbox 0x00038064 4 4 1` → trial,DT `tryboot=1`,旗標一次性自動清(GET `0x00030064` 讀回 1→0);trial 中 reboot / panic / 斷電回預設;**手動**改寫 `[all]` 模擬 commit + 反向都過 | 5914187826 |
| E0d:純 GPT | ❌ 完全不開機;拔卡驗內容全對 → **Pi 3 ROM 不讀純 GPT** | 5921015540 |
| E0d:hybrid MBR(`--hybrid=1:3:EE`,`ee` 最後,MBR 1/2 = `0x0c`) | ✅ 開機;Linux 見 6 GPT 分割;#201 p6 200 MB→24.5 GB;tryboot → B、一般 reboot → A | 5921015540 |
| #201 後的 MBR | 三格類型/起點/順序/active 不變,CHS 被正規化為 `fe ff ff`(第 0 磁區 dump 前後對照待貼 #209) | 待補 |

| **E0g**:p7 firmware 分割(hybrid MBR 1=p7 2=bootA 3=bootB 4=`ee`,firmware 1.20250915) | p7 只有 `bootcode.bin`+`autoboot.txt` → **全黑、無燈**(3 MiB 與 64 MiB 皆然,`autoboot.txt` 有無填充皆然);**加一個空的 `config.txt` → 開機**(3 MiB FAT16 `-s 1` @1 MiB 可用 → p7 留在 1–4 MiB 空隙,不佔 rescue gap)。tryboot A↔B ✅;`autoboot.txt` 缺檔 / 截斷 → 全黑恆綠、亂碼 → 閃 4 下,**三者皆永久卡死、只能重燒**;單一磁區原始寫入 commit A→B→A ✅(讀回一致);trial 中 panic / 拔電 → 回預設 ✅;bootB 少 `start_cd.elf` → 仍開機;bootB 無任何 `start*.elf` → 閃 4 下卡住、拔電回預設;**bootB 缺 kernel → tryboot 自動 42 s 回預設(不需斷電)**;watchdog:procd 停止餵狗 → 56 s 重開、kernel panic 且 `kernel.panic=0` → 38 s 重開 ✅ | 見 #209 E0g 留言 |

已知事實:psci absent,restart handler = `bcm2835-wdt`;DT `/chosen/bootloader/{partition,tryboot,rsts}` 存在且忠實;**Pi 3 firmware 依 MBR 格序編號**;`gpu_mem_512=16` → 實際載入 `start_cd.elf`/`fixup_cd.dat`;**cmdline 帶 `cgroup_disable=memory`**(DT bootargs 注入);`/tmp` = 212 MB。
**未解**:E0 期間一次「開機約 7 分鐘後失聯、無 panic/pstore、無 watchdog 重開、只能斷電恢復」(boot `ccf48c0c`)。

## 2. 沿用 Pi 4 的部分(與實證程度)

| 元件 | 在 Pi 3 上已實證 | 未實證(S5 要跑) |
|---|---|---|
| GPT 六分割 + PARTUUID + cmdline | ✅ E0d | — |
| `batman-slot` active / target / fw-part / is-trial | ✅ E0d | fw-part 在 D3 新版面要改(見 D3) |
| `batman-slot apply` / `commit` / `rollback`、`platform-ab.sh` sysupgrade | ❌ **從未在 Pi 3 跑過** | 全部 |
| tryboot 觸發與回退 | ✅ E0 + E0d(reboot);panic/斷電只在 MBR 版面驗過 | hybrid 版面的 panic/斷電 |
| `batman-autocommit` | ❌ | 全部(含 docker gate,見 D6) |
| p5 config seed / #137 / #202 | ❌ | 全部 |
| #201 首次長滿 | ✅ E0d(一次) | D2 的限制條件 |
| boot-reasons / ramoops / flightrec / joinwatch / keyguard | ✅ 3A+ 單槽 image | — |

## 3. 差異清單

### D1. hybrid MBR + 執行期檢查
- **版面**:GPT p1–p6 同 Pi 4,**加 p7 = firmware 分割**(D3)。MBR:**1 = fw(p7)、2 = bootA(p1)、3 = bootB(p3)、4 = `ee`**;1–3 類型 `0x0c`(E0d 實測在 FAT16 上可開;保留實測值,不改 `0x0e`)、1 active。firmware 編號因此是 **fw=1、A=2、B=3**。
- **builder**(`build-ab-image.sh`、`build-gpt-ab-card.sh` 的 bcm2710 分支):建完讀回斷言 MBR 四格的類型與起點 = 對應 GPT 分割起點,**MBR[4] `ee` 只涵蓋 LBA 1..2047、不與 p7 重疊**,`sgdisk -v` 無錯。
- **執行期**(`batman-slot`,bcm2710):在 apply / commit / rollback 之前讀第 0 磁區(不經快取,`dd iflag=direct`),斷言 MBR[1..3] 起點 = `/sys/class/block/mmcblk0p{7,1,3}/start`、MBR[4] = `ee`;`fw_part()` 在 bcm2710 上**直接由 MBR 格序推導**,不再數 GPT 中的 FAT 個數。不符 → 拒絕,不寫任何東西。
- **失效後果**:純 GPT → 不開機;`ee` 放第 1 格 → `boot_partition=1` 指到 `ee` → **不開機**(不是「指錯槽」)。

### D2. #201 首次開機會改寫 MBR
- **事實**:#201 step 1b `sgdisk -e -d 6 -n 6:…` 會重寫第 0 磁區(E0d:hybrid 結構保留)。Pi 3 ROM 只讀 MBR → 寫到一半斷電可能整台不開機。
- **而且不只一次**:`95-batman-storage` 是 uci-default,**每個新槽的首次開機都會跑**(含現場 OTA 後),step 1b 在 p6 未長滿時會重試。
- **處理**:
  1. bcm2710 上,step 1b 只在「卡從未佈建」時執行:p5 可掛載且明確**未** seed;p5 是 LUKS / 掛不起來 / 狀態不明 → 一律**跳過**。「p6 已長滿到碟尾」時也跳過(比 p5 更直接的訊號)。
  2. `sgdisk` 前先把第 0 磁區 512 bytes 備份到 `/tmp`;之後不經快取讀回,斷言 D1 的四格,不對就寫回備份並 `sync`。
  3. **出廠必須先開機一次**:由**佈建腳本**(不是人工清單)驗「p6 已長滿 + MBR 四格正確 + p7 完整」,不過就拒絕 seed。這也涵蓋「第一次長滿失敗、之後 p5 已 seed、p6 永遠停在小尺寸」的情況。
  4. 兩份 `95-batman-storage`(`feed/…` 與 `deploy/provisioning/…`)同步修改(#230 的 `sync` CI 就是這個)。
- **殘餘風險**:SD 卡 FTL 撕裂可能波及未寫入的相鄰磁區(無法驗證),列為已知風險。

### D3. 獨立 firmware 分割(使用者決定,2026-10-01)
- **問題**:Pi 3 ROM 從 MBR 第 1 格讀 `bootcode.bin`,它再讀同分割的 `autoboot.txt`。若這是 bootA,則節點跑在 B、OTA 寫 bootA 時斷電撕裂 FAT → **兩槽都開不了**(Pi 4 的 `bootcode` 在 EEPROM,沒有這一半風險)。v4 的「寫完讀回驗證」不可行(同一 mount 讀到的是 page cache;而且 stage2 無論如何都會重開)。
- **做法**:在 bootA 前方現成的 1–4 MiB 空隙建 **p7 = 3 MiB FAT16(`mkfs.vfat -F 16 -s 1`,約 6100 clusters,builder 斷言 ≥ 4085;不用 FAT12)**,GPT 名稱 `batfw`(不可與 `bootA`/`bootB`/`data` 相同 —— `92-ramoops-fix` 與 #230 靠名稱辨識;invariants 斷言)。**p7 內容固定為三個檔:`bootcode.bin`、`autoboot.txt`、空的 `config.txt`**(E0g:少了 `config.txt` 整台不開機,連 ACT 都不亮),**不放 `start*.elf`**。`config.txt` 保持空檔(E0g 試過在其中放 `gpu_mem_512=16` 無作用)。
  - `autoboot.txt`:`[all] tryboot_a_b=1 / boot_partition=2`、`[tryboot] boot_partition=3`(數字由 D1 推導,不寫死)。
  - **OTA(`apply`)永遠不寫 p7**;只有 commit / rollback 改寫 p7 的 `autoboot.txt`,以及燒卡。**p7 平時不掛載**,只在 commit / rollback / apply 前的讀取時短暫掛載(`noatime`,讀取用 `ro`)。
  - bootA/bootB 照舊放 `start*.elf`/`fixup*.dat`/kernel/dtb/overlays/`config.txt`/`cmdline.txt`;**不再放 `bootcode.bin` 與 `autoboot.txt`**。
  - GPT p1–p6 編號不變 → #201(p6 在最後)、p5/p6、`95-batman-storage`、#230 的 `data` 名稱辨識都不受影響(review 已逐一確認)。
- **A1:p7 上 `autoboot.txt` 損壞 = 磚化(E0g 已實證)**:
  - 官方 `autoboot.adoc` 說預設分割是「第一個含 `start.elf` 的 FAT」,但 **Pi 3 的 `bootcode.bin` 不照做**:`autoboot.txt` 缺檔 / 截斷 → 全黑恆綠;亂碼 → 閃 4 下;三者都永久卡死,斷電也無用,只能重燒。(對照:舊版面 bootA = MBR[1] 時,`autoboot.txt` 壞了會開 bootA。但舊版面的暴露面是「每次 OTA 寫 bootA 的 FAT」,遠大於本版的單一磁區 → 使用者決定維持 p7。)
  - **commit / rollback 改為「單一磁區原始寫入」**(E0g ④ 已實證):`autoboot.txt` 永遠 ≤ 512 bytes,commit 只改 `boot_partition` 的數字(長度不變);由 BPB 與根目錄項算出該檔資料磁區,**p7 不掛載**,`dd bs=512 count=1 conv=notrunc,fsync` 只寫那一個磁區(不動 FAT、不動目錄項、連 mtime 都不更新),`drop_caches` 後讀回比對,不符就重寫一次、仍不符則中止並告警。不採用 v4.2 的「補空白填滿」(E0g 未證實有害,但沒有必要)。
  - **前置條件**:commit 前 `vcgencmd get_throttled` 無欠壓、batpower 不在 warn/crit;不滿足就延後 commit(trial 狀態本身是安全的)。
  - **殘餘風險(release note 必列)**:commit 那一個磁區寫入的瞬間斷電(或 SD FTL 撕裂波及該磁區)→ 節點磚化、需現場重燒。每次 OTA 一次,窗口為毫秒級。
  - Pi 4 的 `ab.good` 錨點在 bcm2710 上**不寫到 p7**(沒有任何修復流程讀它)。
- **A2:所有讀 `autoboot.txt` 的地方都要改為 p7(依版面偵測,不依 SoC 猜)**:`batman-slot` 的 `BOOTMNT`(:21)、apply 的 `[tryboot]` 檢查(:177)、`committed_fw`(:186,驅動 `is-trial` 與 autocommit)、`ab-selftest.sh:101-115`、`tests/ab-card-invariants.sh:59-61,75-84`、`build-ab-image.sh:135`、`build-gpt-ab-card.sh:149`、`platform-ab.sh:60-61`(stage2 需同時能讀 p7)。
  - **版面偵測**:`batfw` 分割存在且 MBR[1] = p7 → Pi 3 版面;否則 Pi 4 版面。偵測結果與執行中的 SoC 不符 → 拒絕(避免同一支 `batman-slot` 把 Pi 4 邏輯套在 Pi 3 卡上)。
  - **`assert_fw_sane`**(:81-83)目前只在 DT `partition` 為 `1|2` 時比對,Pi 3 的值是 `2|3` → B 槽會靜默跳過檢查。改為「允許值 = 目前版面的 `fw_part A/B`」。
- `batman-slot` 在 bcm2710 上的其他改動:`fw_part()` 改由 MBR 推導(D1)、「必須恰好 2 個 FAT」改為版面決定(Pi 3 = 3)。
- **bootA 的其他寫入者**(依 review 清點):`apply`(target=A)、`92-batman-ramoops-fix`(`sed -i` distroconfig)、`ab.good`。這些寫壞 bootA 只會讓 **A 槽**失效,由 tryboot 回退 / `panic=10` 處理,不再是「兩槽全死」。
- **待 E0g 實機**:Pi 3 ROM 從 3 MiB FAT12/16 的 p7 讀 `bootcode.bin`、再依 `autoboot.txt` 切到 MBR 第 2/3 格開機;tryboot 往返;p7 缺 `start.elf` 是否被 bootcode 接受。

### D4. firmware 版本:以 sha256 白名單把關
- **事實**:1.20250430 有 MBR 第 4 格 bug。D3 版面的開機分割在 MBR 第 2/3 格,理論上不受影響,但所有 A/B 實測都用 1.20250915。
- **處理**:以 **sha256 白名單**(tag 1.20250915 的整組 `start*.elf` + `fixup*.dat`,例如 `start_cd.elf` blob `46517c52…`)取代日期判斷(日期也可能出現在不含修正的分支 build 上)。
  - `build-ab-payload.sh`(bcm2710):payload 內的整組必須命中白名單,否則拒絕打包。
  - **節點端 `apply` 也檢查**(payload 可能在節點上手動打包)。
  - 卡片 builder:`bootcode.bin` 也要命中白名單(燒卡後凍結,OTA 不動)。
- **相容性**:`bootcode.bin` 凍結 → 每次 firmware 升版,release 驗證都要跑「燒卡時的 `bootcode.bin` + 新 `start*.elf`」組合(E0f 已證 Apr-2025 bootcode + Aug-2025 start 可開)。
- firmware-2710 `build-3aplus` 的 bump(`c68ddf4`)**在 S4 前必須 push**。

### D5. OTA payload:開機檔清單 + sha256 清單 + 不經快取的讀回驗證
- **開機檔清單**:`build-ab-payload.sh:24` 與 `batman-slot:163` 只列 `start4*`/`fixup4*` → bcm2710 的 firmware 會被**靜默丟掉**。改為「payload 內實際存在的 `start*.elf`/`fixup*.dat` 全拷」,明確排除 `bootcode.bin`;bcm2710 payload 必須含 `start_cd.elf` + `fixup_cd.dat`。
- **清單檔**:payload 附 `SHA256SUMS`(`root.squashfs` + 每個 `boot/` 檔),`metadata` 加 `target=`(D8)。
- **apply 寫入後驗證**(兩 SoC 共用,Pi 4 也受益):寫完 → `sync` → umount 目標開機 FAT → `echo 3 > drop_caches` → 重新 mount 讀回比對 `SHA256SUMS`;rootfs 以 `dd iflag=direct` 讀回同長度比對。**任何不符 → 不發 tryboot,並把目標槽作廢**。這是 release gate。
- **A3:「作廢」的精確定義**:目標槽 `cmdline.txt` 改寫為 `<共用參數> rootwait=20 panic=10 root=PARTUUID=00000000-0000-0000-0000-000000000000 batman_slot=<T>`(**保留 `panic=10`**,誤開時 VFS panic → 10 秒後重開回預設槽;不刪 kernel,避免落入「閃 7 下卡死」),並在該槽開機 FAT 放 `BAD` 標記檔。`commit` / `rollback` 遇到帶 `BAD` 的槽**拒絕**;下一次成功的 apply 才清除。
- **tryboot 發起後讀回**:`vcmailbox 0x00030064` GET 必須回 1,否則 apply 失敗(目前 `batman-slot:180` 是 `|| true`)。
- 注意:apply 失敗後 sysupgrade stage2 仍會**無參數重開** → 回到預設槽(未被改動),這是安全的。

### D6. docker 引擎開放給 bcm2710,OTS 不開;memcg 要先開
- **memcg**:bcm2710 cmdline 帶 `cgroup_disable=memory`(DT bootargs)。Pi 4 靠 firmware fork patch 950-1446 拿掉(**只做了 bcm2711**,見 `feed/batman-payload-host/Makefile:33-35`)。沒有 memcg → docker 無法限記憶體,且 `batman-autocommit:65-66` 在有 tenant 時判「no memcg controller」→ **OTA 永遠不 commit**。
  - 處理:把 950-1446 的做法移植到 bcm2710 DTS;對 bcm2710 kernel config 跑 docker `check-config`(MEMCG、PIDS、overlay、veth、seccomp 等),缺的補上。
- **拆套件**:`batman-payload-host`(`@TARGET_bcm27xx_bcm2711`)拆成「docker 引擎 + payload 管理」(兩 SoC)與「OTS 專屬」(firstload、golden、OTS uci-defaults;僅 bcm2711)。bcm2710 image **不含任何 OTS 內容**。
- **RAM**:記憶體准入屬 #81(resource budget),不是 `payload-arbiter`(#167 只管網路衝突)。bcm2710 上先以文件 + release note 聲明「不支援 OTS 等大型 tenant」,#81 另行處理。
- **待實測**:512 MB 上 dockerd+containerd 常駐、跑小 tenant 的餘裕;autocommit 600 s timeout 內 canary `docker load` 在 3A+ 能否完成。

### D7. `/tmp` 預算:rootfs 串流寫入
- **事實**:`platform-ab.sh:46-47` 把整個 payload 解到 `/tmp/ab-payload`,上傳的原檔也在 `/tmp` → 約 2 × payload。3A+ `/tmp` = 212 MB;含 docker 的 payload 可達 ~120 MB → ENOSPC / OOM(上傳時 dockerd 還在跑)。
- **處理**:`platform_do_upgrade` 只把 `boot/`、`metadata`、`SHA256SUMS` 解到 `/tmp`;`root.squashfs` 直接串流到目標 rootfs。
- **A4:串流不可繞過 apply 的檢查**,順序固定為:
  1. `batman-slot apply --precheck`:MBR 檢查(D1)、`assert_fw_sane`、#202 p5-seeded 互鎖、目標未掛載、大小相容(squashfs 大小取自 `metadata` 新增的 `size=`)、firmware 白名單(D4)、SoC 比對(D8)。任一失敗 → `return 1`。
  2. 清空 overlay 視窗(`ZERO_MB`)→ `get_image | tar -xOf - root.squashfs | dd of=$TROOT`(`get_image` 可重複呼叫,#230 已在 check_image 用過)。
  3. `batman-slot apply --finish`:寫開機檔 → D5 讀回驗證 → 發 tryboot → GET 讀回。
- **stage2 ramfs 工具**:ramfs 只連結部分 busybox applet(`platform-ab.sh:21-29`;先前就缺過 `tr`)。`RAMFS_COPY_BIN` 補齊或確認存在:`sha256sum`、`dd`(且 busybox 有開 `iflag=direct`)、`tar`(`-O`)、`umount`、MBR 檢查用的 `hexdump`、`vcmailbox`。**bench 上以 stage2 log 證明**(同 #89 做法)。
- **`/tmp` 空間檢查**放在 `platform_check_image`(由 tar 清單推算大小)或上傳工具,不放在 do_upgrade(那時上傳早已完成)。

### D8. SoC gate:`-F` 也要擋
- **事實**:#230 把硬拒放在 `platform_check_image`,但 `sysupgrade -F` 會略過失敗的 check 照樣呼叫 `platform_do_upgrade`,而 do_upgrade 裡只印 WARN(`platform-ab.sh:53-55`)。我們自己的流程常用 `-F`。
- **處理**:`board=`/`target=` 由 `root.squashfs` 的 `DISTRIB_TARGET` 在 build 時推導(與參數不符即拒);`platform_do_upgrade` 在 `batman-slot apply` 之前做同樣比對,不符就 `return 1`(stage2 無參數重開 → 回預設槽,安全)。

### D9. 當機 / 失聯的重開路徑(watchdog)
- **事實**:A/B 的「trial 不健康就回退」依賴**有東西讓節點重開**。`batman-autocommit:120` 只是不 commit,從不重開。E0 期間那次失聯既無 panic 也無 watchdog 重開。
- **處理**:
  1. ~~S5 實測~~ **E0g 已驗**:procd 停止餵狗 → 56 s 重開;kernel panic 且 `kernel.panic=0` → 38 s 重開(`kill -STOP 1` 無效:kernel 不會對 PID 1 送 SIGSTOP)。
  2. trial 中「活著但連不上」(mesh 沒起、網路掛)要有重開路徑:autocommit timeout 後,若仍是 trial 且健康閘未過 → **主動 reboot 回預設槽**(Pi 4 也適用;改 `batman-autocommit`,需另過 review)。tryboot 是一次性的,重開後回到已 commit 槽、`is-trial`=1 → no-op,**不會形成重開迴圈**。
  2a. **A5:健康閘要能看見「連不上」**。目前的閘(`batman-autocommit:49`)只看 mesh11sd/openmanetd/wpad 是否在跑,而且刻意容忍未入網 → mesh 壞掉但服務在跑的槽(brcmfmac/radio 對調、morse 驅動卡住)會被 commit,節點就此失聯,根本到不了 timeout。**新增可達性條件**:OTA 前若 p5/p6 記錄節點曾有 mesh peer,trial 必須在 timeout 內看到 peer(或到已知鄰居的 link)才 commit,否則不 commit 並重開。`TIMEOUT` 要在 3A+ + docker + canary `docker load` 下校準;回退原因寫到 p6,讓「慢但正常」的槽不會默默讓整批 OTA 失效。
  3. 那次不明失聯:watchdog 對 hang 有效(上一條),而那次沒有 watchdog 重開 → 判定為「系統活著但網路斷」,不是 hang。release 前要嘗試重現;不能解釋就列在 release note,並由 A5 / S2 處理。
- **建議(未決,另開單)**:已 commit 的槽之後 hang 或失去 mesh(E0 那次失聯)目前沒有自動恢復 —— watchdog 管不到「網路掛了但系統在轉」。評估有上限、有退避的「N 小時無 mesh peer → 重開」,以及外部 watchdog / 定時斷電器。

### D10. 建置與驗證管線
- `tests/ab-card-invariants.sh` 加 bcm2710 變體:D1 的 MBR 四格、p7 內容(`bootcode.bin` 白名單雜湊、`autoboot.txt`)、`start_cd.elf` 佔位、兩槽 `config.txt`/`distroconfig.txt` 相同(OTA 不帶它們)。
- `scripts/ab-selftest.sh`:destructive 改名的檔在 bcm2710 是 `start_cd.elf`;加 D1/D3 的執行期斷言。
- `daily-validation.sh`:依機型分流(OTS suite 在 bcm2710 跳過並說明原因);新 suite:memcg 已開、MBR 四格、p7 完整、tryboot GET 讀回。
- firmware repo:`scripts/local-ab-tar.sh` 參數化 `BOARD`/bin 目錄;CI 的 A/B 步驟放寬到 ekh-bcm2710;`mm6108only_diffconfig` 的 bcm2711 device 名;3A+ 自己的 `files/etc/batman-build` 戳記;**bcm2710 build gate:image manifest 必須含 `kmod-brcmfmac` + 43455 firmware**(缺了 morse 會變 `radio0`,OTA 後節點 stranded —— 1.4.12 事故;autocommit 的服務閘擋不住)。
- `92-batman-ramoops-fix` 在 bcm2710 的 distroconfig(`[pi3] dtoverlay=ramoops,console-size=…`)上 build 時驗證不會被誤改。

### D11. 從現有單槽 3A+ 升級
- 現有 3A+ 是單槽 MBR。**不能 OTA 成 A/B,必須重燒**。實際擋住它的是 `batman-slot` 的 `assert_fw_sane`(cmdline 沒有 `batman_slot=` → 拒絕),不是「版面不同」;S5 要實測這條路徑會乾淨拒絕。注意 `98-batman-sysupgrade` 在單槽節點上也會裝 `platform-ab.sh`。release note 寫清楚「需重燒 + 重新佈建」。

## 4. 失效矩陣(Pi 3 特有或需重驗;其餘繼承 #133)

「需斷電」= 遠端節點需出勤。

| 情境 | 期望 | 已驗? |
|---|---|---|
| trial 中一般 reboot | 回預設 | ✅ E0d(hybrid) |
| trial 中 panic / 斷電 | 回預設 | ✅ MBR 版面(E0 TB3/TB4);🔴 hybrid + p7 版面 |
| trial 的 bootB **缺 `start_cd.elf`** | ? Pi 4 缺 `start4.elf` 由 EEPROM 退回;Pi 3 由 bootcode 決定 | 🔴 **S5 必測**(`ab-selftest --destructive`) |
| trial 的 `start_cd.elf` 在、**kernel/dtb 缺或壞** | E0f 同類:**卡死、ACT 閃 7、不回退、需斷電** | ⚠️ E0f 已見(MBR);🔴 hybrid 版面重驗 |
| `fixup`/`start` 版本不配 | ? | 🔴 S5 |
| trial rootfs 壞(VFS panic) | `panic=10` → 回預設 | 🔴 S5 |
| apply 寫入後讀回不符(D5) | 不發 tryboot、目標 cmdline 作廢、重開回預設 | 🔴 S5(故障注入) |
| tryboot 發起失敗(GET ≠ 1) | apply 失敗 → 回預設 | 🔴 S5 |
| OTA 寫 bootA 中斷電(D3) | 只影響 A;B 照常開 | 🔴 S5 |
| commit(p7 單一磁區原始寫入)A→B→A | 生效、讀回一致 | ✅ E0g ④ |
| commit 那一磁區寫入中斷電 | 舊 / 新 / 撕裂;撕裂 → 下一列(磚化) | ⚠️ 已知殘餘風險(不測) |
| p7 `autoboot.txt` 缺檔 / 截斷 / 亂碼(A1) | ~~跳過 p7 開 bootA~~ → **實測:永久卡死,需重燒** | ✅ E0g ③(負面結果) |
| p7 缺 `config.txt` | 不開機 | ✅ E0g(V1–V3)→ builder / invariants 必須斷言 |
| trial 中 panic / 斷電(p7 版面) | 回預設 | ✅ E0g ⑤ |
| bootB 無任何 `start*.elf` | 閃 4 卡住,拔電回預設 | ✅ E0g ⑥c(需斷電 → D5 讀回驗證是防線) |
| bootB 缺 kernel(tryboot) | 自動回預設 | ✅ E0g ⑦(42 s,不需斷電) |
| userland hang / kernel hang | watchdog 重開 | ✅ E0g ⑧(56 s / 38 s) |
| rollback / commit 到被作廢(`BAD`)的槽(A3) | 拒絕 | 🔴 S5 |
| 誤開被作廢的槽 | `panic=10` → 回預設 | 🔴 S5 |
| stage2 ramfs 工具齊全(A4) | stage2 log 證明 | 🔴 S5 |
| trial 服務都在但 mesh 壞(A5) | 不 commit → timeout 重開回預設 | 🔴 S5(故障注入) |
| #201 首次 `sgdisk` 後 MBR(D2) | 四格正確;不對則寫回 | ✅ E0d 一次(dump 待貼);🔴 讀回+寫回實作 |
| 已佈建卡上 #201 不再動 MBR(D2) | 跳過並記 log | 🔴 S5 |
| 執行期 MBR 不符(D1) | apply/commit/rollback 拒絕 | 🔴 S5 |
| Pi 4 payload + `sysupgrade -F`(D8) | do_upgrade 拒絕 → 回預設 | 🔴 S5 |
| payload 漏 `start_cd.elf` / firmware 不在白名單(D4/D5) | build 與節點端都拒 | 🔴 S4/S5 |
| 帶 docker 的 OTA 在 512 MB(D7) | 不 ENOSPC/OOM | 🔴 S5 |
| autocommit 在有 docker tenant 的 3A+ 上(D6) | memcg 已開 → commit | 🔴 S5 |
| kernel / userland hang(D9) | watchdog 重開 → trial 回預設 | 🔴 **S5 必測** |
| trial 活著但連不上(D9) | autocommit timeout → 主動重開回預設 | 🔴 需實作 + 實測 |
| 從 1.4.14 單槽 OTA(D11) | `assert_fw_sane` 乾淨拒絕 | 🔴 S5 |
| bcm2710 image 缺 brcmfmac(D10) | build gate 拒 | 🔴 S4 |

## 5. 實作順序

- **S1**(已完成)firmware-2710 `bcm27xx-gpu-fw` → 1.20250915(`c68ddf4`,**待 push**)。
- **S2** 本文件第二輪聚焦 review(D1、D2、D3、D5、D7、D9 的新做法)。
- **E0g**(需現場;**硬關卡**)p7(FAT16 `-s 1`、MBR `0x0c`)+ hybrid 四格:①開機 ②tryboot 往返 ③p7 `autoboot.txt` 缺檔 / 截斷 / 亂碼時的行為(A1)④就地覆寫 commit ⑤trial 中 panic / 斷電 ⑥bootB 缺 `start_cd.elf` ⑦bootB kernel 缺 ⑧kernel hang 與 userland hang 的 watchdog。③ 若不會退回 bootA → 回到本文件改 D3。
- **S3** 前置 #230:修好 CI(`sync` = 兩份 `95-batman-storage` 不同步;`ab-card` 待查),併入 D8 的 do_upgrade 硬拒,merge。
- **S4** 實作 D1–D10(Batman + firmware repo + memcg DTS);每個 PR 附實測。
- **S5** 從 merged main 建 bcm2710 燒卡映像 + OTA payload → manet03 完整驗證(燒卡即用、provision、與 02/04 組網、reboot×2、OTA×2 autocommit、`ab-selftest --destructive`、WSL ab-card、daily-validation 全套非 OTS、docker/RAM、§4 全部列)。
- **S6** release(Batman-P),release note 含 D11、不支援 OTS、已知風險(D2 殘餘、D9 若未解)。

## 6. 替代方案

1. **v4.1:tryboot + Pi 4 版面 + p7 firmware 分割(hybrid MBR 四格)**(主案)
2. v4:bootA 兼 firmware 分割(review 判定 D3 風險無法以讀回消除;使用者否決)
3. v3.1 A0:`reboot N` + MBR(E0f 可行,需 firmware ≥ 1.20250915)
4. v2 / U-Boot(不再考慮)

## 7. 連帶要改的文件與 issue

- `docs/storage-architecture.md:32-38`:Pi 3 = Pi 4 版面 + p7 firmware 分割(hybrid MBR),移除 `tryboot.txt` 與「p4 config / p5 data」。
- `docs/field-resilience.md:55`:Pi Zero → Pi 3A+;commit 只寫 p7 的 `autoboot.txt`。
- `docs/design/ab-sysupgrade-platform.md`:D5(驗證)、D7(串流)、D8(do_upgrade 硬拒)屬兩 SoC 共用改動。
- `scripts/e0/`:保留為實驗紀錄;README 註明 v4 不用 `reboot-part`。
- #209 勾選框、#75 樹。

## 8. Review 紀錄

**v3 review(2026-09-30):APPROVE-WITH-CHANGES**(見 git `bc62c0e` §12)。

**v4 review(2026-10-01,獨立 reviewer,聚焦 §3/§4):NEEDS-REWORK。** MUST-FIX 與處理:
1. bcm2710 memcg 關閉 → autocommit 永不 commit → **D6**(移植 950-1446 + check-config)
2. OTA payload 在 512 MB 塞不進 `/tmp` → **D7**(rootfs 串流)
3. `sysupgrade -F` 繞過 SoC gate → **D8**
4. D3 讀回驗證不可行(page cache;stage2 照樣重開;防不了斷電)→ **D3 改為獨立 firmware 分割**(使用者決定)
5. §4 引用的「apply 讀回驗證」並不存在 → **D5**(SHA256SUMS + 不經快取讀回 + 作廢目標 cmdline)
6. D4 日期判斷不可行 → **sha256 白名單**,build + 節點 apply + 燒卡都查(註:`VC_BUILD_ID_TIME` 其實有日期那一行,但白名單更嚴謹,照採)
7. 不明失聯沒處理 → **D9**
8. §4 把不同 firmware 階段失效併成一列 → 已拆列
9. D1 失效描述錯、執行期未檢查 MBR → **D1**(MBR 推導 `fw_part`、執行期斷言)
10. D2 不可行(快取、兩份檔、非一次性)→ **D2**(限首次佈建、備份寫回、出廠開機一次)
SHOULD-FIX 已吸收:§2 實證程度據實標註、bootA 寫入者清點(D3)、FTL 殘餘風險(D2)、D11 的實際擋法、tryboot GET 讀回(D5)、`bootcode.bin` 凍結的相容性(D4)、#81 vs arbiter(D6)、brcmfmac build gate(D10)、`0x0c` 決定(D1)、invariants 加項(D10)。

**v4.1 review(2026-10-01,同一 reviewer 第二輪):APPROVE-WITH-CHANGES,E0g 為硬關卡。** 上輪 MUST-FIX:1/3/4/6/8 已解、2/5/7/9 部分、10 大致解。新 MUST-FIX 與處理:
- A1 p7 的 `autoboot.txt` 缺失/撕裂成為新磚化路徑;vfat rename 非原子 → D3(官方「bootable = 含 start.elf」→ 應退回 bootA,E0g 必測;commit 改就地覆寫;p7 平時不掛載;`ab.good` 不寫 p7)
- A2 所有 `autoboot.txt` 讀取點改 p7、`assert_fw_sane` 範圍依版面、版面偵測 → D3
- A3「作廢」精確定義(保留 `panic=10`、不存在的 PARTUUID、`BAD` 標記)→ D5
- A4 串流不可繞過 apply 檢查、stage2 工具 → D7(`--precheck` / 串流 / `--finish`)
- A5 健康閘看不見「連不上」→ D9.2a(可達性條件、TIMEOUT 校準、回退原因記錄)
- A6 p7 用 FAT16 `-s 1`,`ee` 不重疊 → D1、D3
SHOULD-FIX 已吸收:S1(D2 訊號)、S2(已 commit 槽失聯 → 另開單)、S3(p7 名稱)、S4(p7 只放兩個檔)、S5(`ab.good`)、S6(`/tmp` 檢查位置)。

**v4.2**:依上列修改;下一關 = E0g 實機。

**v4.3(E0g 實機後)**:p7 必含空 `config.txt`(新發現,builder/invariants 斷言);p7 留在 1–4 MiB 空隙(3 MiB 可用);A1 實證為磚化 → commit 改單一磁區原始寫入 + 供電前置條件 + 殘餘風險入 release note;D9 watchdog 對 kernel / userland hang 有效 → E0 那次失聯屬「活著但連不上」,A5 可達性條件與 S2(另開單)更為必要;tryboot 對「缺 kernel」會自動回退(`reboot N` 不會)。另:3A+ `gpu_mem` 從來沒生效(單槽 image 已知問題,與 A/B 無關,另追;影響 docker 可用 RAM 48 MB)。

## 參考

- #209 · #203 · #89 · #133 · #201 · #202 · #211 · #216 · #230 · #231 · #81 · #167
- raspberrypi/rpi-eeprom#705;raspberrypi/firmware `0ea2874060`;raspberrypi/firmware#1974
- Raspberry Pi docs:`config_txt/autoboot.adoc`(A/B 範例:p1 只放 autoboot 的做法)、`raspberry-pi/bootflow-eeprom.adoc`(tryboot)
