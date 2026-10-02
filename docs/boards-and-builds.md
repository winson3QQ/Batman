# 板子、build 與共用 A/B 機制(正本)

**要 build、改 A/B 相關程式、或在 Pi 3A+ / Pi 4 上驗證之前,先讀這份。** 這份是正本;`CLAUDE.md`(本 repo 與 firmware fork 各一份)只放規則和指向這裡的連結。
來源:#209(Pi 3 A/B)S5,2026-10-02。設計細節見 `docs/design/209-ab-on-pi3.md`、`docs/design/ab-autocommit.md`、`docs/design/ab-sysupgrade-platform.md`。

## 1. 板子矩陣

| board | SoC(OpenWrt subtarget)| 硬體 | 卡片版面(`batman-slot layout`)| 開機鏈 | OTS | 驗證節點 |
|---|---|---|---|---|---|---|
| `ekh-bcm2711` | bcm2711 | Pi 4(manet02、manet04 8GB) | `pi4`:GPT,bootA=p1 rootA=p2 bootB=p3 rootB=p4 p5 設定 p6 資料;`autoboot.txt` 在 bootA | EEPROM bootloader(缺 `start4.elf` 時會自己退回) | 有(`batman-payload-ots`) | 02、04 |
| `ekh-bcm2710` | bcm2710(DT `bcm2837`)| Pi 3A+ 512 MB(manet03) | `pi3`:同一套 GPT,另加 **p7 firmware 分割**(FAT16,`bootcode.bin` + `autoboot.txt` + 空的 `config.txt`)與 **hybrid MBR** 四格:1=p7(active)2=bootA 3=bootB 4=ee | SD 上的 `bootcode.bin`(**沒有 EEPROM**;firmware 缺檔、`autoboot.txt` 壞掉都會卡死,要斷電或重燒)| **沒有**(#209 D6) | 03 |

Pi 3 的 firmware 必須 **≥ 1.20250915**。1.20250430 無法從 MBR 分割 4 開機(上游 firmware `0ea2874060`)。實際把關的是 sha256 白名單 `feed/batman-provision/files/usr/share/batman/firmware-allowlist-bcm2710.sha256`,builder 和節點端的 `batman-slot apply` 都讀這一份。

### 驗證角色(使用者 2026-10-02)
- **模擬已部署角色**:只用 `sysupgrade`(A/B OTA payload)更新,不重燒卡;破壞性測試要先問使用者。
- **bench 角色**:可以燒卡,用來驗燒卡 image(flash-and-go)。
- 角色會輪替:現在 Pi 4(02、04)是部署角色,Pi 3(03)是 bench 角色;Pi 3 驗完後也轉成部署角色。v1.1 開發期間,**每塊板的燒卡 image 都要在 bench 角色的機台上實燒驗證**。

## 2. 一棵樹、一個版本號

- 兩塊板都從 firmware fork(`winson3QQ/firmware`)的 **`build-3aplus`** 分支 build。`build-108-batman` 凍結在 1.4.14,不再使用。
- **同一個 commit 出兩個 image,版本號相同**;板子是另一個欄位。版本字串規則見 `docs/VERSIONS.md`:`<M>.<m>.<p>-<channel>.<n>+<feed7>.fw<fw7>`。
- `/etc/batman-build` 由 firmware fork 的 `scripts/stamp-batman-build.sh` **在 build 時產生**,不再手動維護;它寫入 `BATMAN_BOARD` 和 `BATMAN_DIRTY`。build 完之後,`build-board.sh` 會從 rootfs 抽出戳記,斷言 board 與兩個 commit 都對。
  - **image 裡沒有戳記就永遠無法 commit**:`batman-autocommit` 把缺 `/etc/batman-build` 視為不健康,每次 OTA 都會被 revert。所以 CI 和本機 build 都必須產生戳記。
- 節點上用 `batman-version` 自報:版本、board、feed/firmware commit、DIRTY。

## 3. 怎麼 build(唯一入口)

```
# firmware fork(WSL:wsl -d Ubuntu-24.04 -u yello,樹在 /home/yello/firmware-2710)
scripts/build-board.sh ekh-bcm2710               # Pi 3A+:build + OTA payload(樹的擁有者身分)
scripts/build-board.sh ekh-bcm2711               # Pi 4
scripts/build-board.sh <board> --card-only       # 以 root 執行,build 完之後:燒卡 image + 卡片 invariants
```

`build-board.sh` 依序負責:
1. 該板的配方(`boards/<board>/batman-recipe`;Pi 3 包含 `-x payloadhost`);
2. `.config` 必須等於 `boards/<board>/batman-config.lock`;
3. 產生戳記;
4. build(平行編譯失敗時自動用 `-j1` 重試);
5. manifest gate(`check-image-manifest.sh`:兩板必含 brcmfmac / 43455 / mm6108 / batman-provision,禁 mm8108;Pi 4 必含 OTS,Pi 3 禁 OTS);
6. 用 `scripts/pick-rootfs.sh` 選出 rootfs(見下),並斷言其中的戳記與 SoC;
7. OTA payload(之後以 root 執行 `--card-only` 做燒卡 image + invariants);
8. 印出 sha256。

**不要自己拼 `openmanet_setup.sh` 的參數,也不要裸跑 `make defconfig`。** 裸 defconfig 會默默丟掉 `kmod-brcmfmac` 和 mm6108 firmware,morse 就會掉到 radio0,OTA 後節點 stranded(1.4.12 事故)。

### rootfs:燒卡 image 和 OTA payload 必須是同一個檔案(2026-10-02)
OpenWrt 開了 `CONFIG_TARGET_PER_DEVICE_ROOTFS`,`build_dir/target-*/linux-bcm27xx_<sub>/` 底下有兩種 squashfs:
- `root.squashfs`:**target 通用版**,不含該裝置的 `DEVICE_PACKAGES`。
- `root.squashfs+pkg=<hash>`:**per-device 版**,也就是出貨 image p2 的內容。只有 per-device 套件與通用版不同時才會產生;Pi 3 沒有這個檔,因為它的通用版就等於裝置版。

過去在這件事上出過兩次事,教訓剛好相反:
1. **2026-09-16(manet02 卡片救援)**:用通用 `root.squashfs` 建卡,缺 `morse/mm6108.bin`,HaLow 起不來。當時 mm6108 韌體只是 `DEVICE_PACKAGES`。教訓是「改用 image 的 p2」。
2. **2026-09-25**:從 gunzip 後的 `.img.gz` 切出 p2,少了 268 bytes,squashfs 尾巴被截斷,開機 kernel panic。教訓是「改用 build_dir 的完整檔」。後來通用版剛好夠用,只是因為 `mm6108only_diffconfig` 把 mm6108 韌體強制設成 `=y`。

**規則**:一律用 `scripts/pick-rootfs.sh <board>`。它從 image p2 的前 4 KiB(squashfs superblock)認出是哪一個檔,交出的是 build_dir 裡完整的那一份,並驗證「檔案大小 = superblock 的 bytes_used」。燒卡 image、OTA payload、戳記檢查、CI 都用它。這樣一來,不會缺裝置套件,也不會被截斷。

產物與 release:release 只發「實機驗過的那一批」,以 sha256 為準。CI 的 A/B payload 步驟失敗時,整個 build 必須失敗。

## 4. 共用 vs 單板程式地圖

改到「兩板」那一欄的任何東西,**兩塊板都要實機驗證**;CI 檢查 `ab-shared-change` 會強制 PR body 附兩板的實測結果(§6)。

| 檔案(feed `batman-provision` 除非另註) | 兩板都會執行 | 只有 pi3 | 只有 pi4 |
|---|---|---|---|
| `usr/sbin/batman-slot` | `detect_layout`/`layout`(版面要對上 SoC)、`verify`(SoC 認不出來就拒絕)、`is-trial`、commit/rollback 流程、`apply`(先刪除殘留的 skip-once 標記、SHA256SUMS、寫後不經快取讀回、不符就作廢成 BAD 槽、arm tryboot + GET 讀回、busy 檔、試用中拒寫)、`stage-root`、電壓不足延後、`tryboot-get` / `corrupt-after-write` 注入點 | `assert_mbr` / `mbr_entry`、由 MBR 推 `fw_part`、`write_autoboot_pi3`(p7 單一磁區原地覆寫)、firmware 白名單、GET 讀不到就硬失敗、`mbr-mismatch` 注入點 | 由 GPT 內 FAT 順序推 `fw_part`、bootA 上的 `autoboot.txt`、GET 讀不到只警告 |
| `usr/lib/batman/platform-ab.sh`(由 98 裝成 `/lib/upgrade/platform.sh`) | check_image:tar 清單、SHA256SUMS、試用中拒絕、`/tmp` 容量、**SoC gate(fail-closed)**;do_upgrade:SoC gate(`-F` 下也擋)、rootfs 串流寫入、apply | `RAMFS_COPY_DATA` 白名單檔(只有 pi3 會讀) | — |
| `etc/uci-defaults/95-batman-storage` | `$DISKN`、#201 長滿卡(step 1b / 3b) | hybrid MBR 備份、驗證、寫回;**已佈建的 pi3 卡不長**(D2) | — |
| `usr/bin/batman-autocommit` | v2.2 全部:mesh 加入閘、獨立 watchdog revert、只在真 tryboot 才 revert、p6 逾時覆寫、hold-once、skip-once、`autocommit.log` | 預設逾時 900 s(bcm2837) | 預設逾時 600 s |
| `usr/lib/batman/meshjoin.sh`、`usr/bin/joinwatch`、`usr/bin/batman-config-save`(mesh 標記)、`usr/bin/halow-status`(LAST OTA)、`usr/bin/batman-version` | 全部 | — | — |
| feed `batman-payload-host` | docker 引擎、data-root、通用 firstload | — | 帶入 `batman-payload-ots`(`+TARGET_bcm27xx_bcm2711`) |
| firmware fork:`package/kernel/bcm27xx-gpu-fw` | 版本 1.20250915 | `start*.elf` / `bootcode.bin` | `start4*.elf` / `fixup4*.dat`(**Pi 4 也換了**) |
| firmware fork:`target/linux/bcm27xx/image/boards/ekh01/distroconfig.txt` | 同一個檔案 | `[pi3]` 段(gpu_mem、core_freq_min、ramoops) | `[pi4]` 段(ramoops-pi4)— 位元組重排過,生效設定不變 |
| firmware fork:memcg DTS patch、cmdline-extra hook、`bcm2710trim` / `onboardradioonly` / `ptt` diffconfig、bcm2710 kernel config | — | 全部 | — |
| 主機端:`scripts/ab-selftest.sh`、`scripts/daily-validation.sh`、`tests/ab-card-invariants.sh`、`scripts/build-gpt-ab-card.sh`、`scripts/build-ab-payload.sh` | 依 layout / SoC 分流 | pi3 分支 | pi4 分支 |

## 5. 1.4.14 之後 Pi 4 的行為變更(都來自 #209)

基準:1.4.14 = feed `8685c5a` + firmware `397e313`(注意:1.4.14 戳記裡寫的 `6763ed8` / `c19763a` 是錯的,§2 的戳記腳本就是為了修這個)。「驗證」欄在 S5-D 完成後回填:實機名稱 + 測試 + 結果。

| # | 來源 | Pi 4 上的行為變更 | 對應的實機驗證 | 狀態 |
|---|---|---|---|---|
| 1 | #230 | sysupgrade 的 SoC gate 移到 check_image,do_upgrade 再擋一次(`-F` 也擋) | §4 矩陣 165:Pi 3 payload 打 02 必須拒絕 | 待 S5-D |
| 2 | #233 | payload 必須有 SHA256SUMS(1.4.13 / 1.4.14 的舊 payload 會被拒) | 02 OTA 正常路徑;舊 payload 被拒 | 待 S5-D |
| 3 | #233 | 寫後不經快取讀回;不符就把槽作廢(cmdline 指向不存在的 PARTUUID + `panic=10` + BATMAN-BAD),不 arm tryboot | 147 / 158 / 159 在 02 上 | 待 S5-D |
| 4 | #233 | rootfs 由 sysupgrade 串流寫入(不在 /tmp 落地),`/tmp` 容量先檢查 | 02 / 04 OTA 正常路徑;160 stage2 log | 待 S5-D |
| 5 | #233 | 電壓不足時延後 commit / rollback | 記錄 throttled;02 正常 commit | 待 S5-D |
| 6 | #233 | tryboot arm 後 GET 讀回(Pi 4 若 firmware 不回應只警告) | `trybootget-209` suite;02 OTA | 待 S5-D |
| 7 | #234 | 95-batman-storage 的 `$DISKN` 重構;MBR 保護在 pi4 不會啟動 | 02 OTA 前後 GPT 與 MBR dump 一致;`p6grow-201` | 待 S5-D |
| 8 | #235 | OTS 改成獨立套件 `batman-payload-ots`,由 bcm2711 條件依賴帶入 | manifest gate;04 OTS 全綠 | 待 S5-D |
| 9 | #236 | autocommit v2.2:節點預期在 mesh 時要加入 mesh 才 commit;watchdog 保證 revert;試用中拒絕 apply / sysupgrade;`autocommit.log` | 02 OTA commit + 刻意失敗 OTA 退回;04 docker tenant 路徑 | 待 S5-D |
| 10 | S5-A | 無法辨識的 SoC 改成拒絕;`batman-slot verify`;skip-once;注入點;`batman-version` 印 board | 165b;`slot-verify-209`;02 上 `ab-selftest` 正常路徑 | 待 S5-D |
| 11 | firmware `c68ddf4` | GPU firmware 1.20250915:Pi 4 的 `start4*` / `fixup4*` 換新 | 02 OTA:trial 在新 start4 上開機;記錄 EEPROM 版本;**Pi 4 燒卡 image 待 S5-F 實燒** | 待 S5-D / S5-F |
| 12 | firmware distroconfig | 檔案位元組重排,Pi 4 生效設定不變。**只影響燒卡 image**:OTA payload 不帶 `config.txt`、`distroconfig.txt`、`cmdline.txt`,已部署的節點保留自己的設定 | S5-B 差異審計 + S5-F 燒卡後 `vcgencmd get_config int` / `str` 比對 | 待 S5-F |
| 13 | rootfs 統一(2026-10-02) | 已部署的 Pi 4(1.4.12 / 1.4.14)跑的是通用 rootfs;1.5.0 改用 per-device rootfs,**多出 6 個 Pi 4 系列標準驅動**:`kmod-r8169`、`r8169-firmware`、`kmod-usb-net-lan78xx`、`kmod-phy-realtek`、`kmod-phy-microchip`、`kmod-i2c-brcmstb`。只有對應硬體存在時才載入(Pi 4B 上預期只有 i2c-brcmstb) | 02 / 04 OTA 後 `lsmod` 對照、dmesg 無新錯誤、mesh 與 eth 正常 | 待 S5-D |

S5-B 差異審計結果(1.5.0 Pi 4 payload 對 1.4.14 payload):
- 開機檔只有 `start4*` / `fixup4*`(gpu-fw)和 `kernel8.img` 改變。kernel `.config`、版本字串、大小相同,只差 40 個 build-id 類 bytes。bcm2711 DTB 和所有 overlay 完全相同。
- rootfs 套件差異 = `batman-*` 版本、`batman-payload-ots`(#235)、`gpu-fw`,以及第 13 項那 6 個驅動;沒有其他差異。

## 6. 改共用 A/B 程式的規則

- 「共用 A/B 檔案」= 一改就會影響兩塊板的 OTA、開機、slot 或 commit 閘門的檔案,清單如下。和 `.github/workflows/ab-shared-change.yml` 的 `paths`、`CLAUDE.md` 是同一份清單,改一處就要三處一起改:
  - feed `batman-provision`:
    - `usr/sbin/batman-slot`
    - `usr/lib/batman/platform-ab.sh`
    - `etc/uci-defaults/95-batman-storage`
    - `etc/uci-defaults/96-batman-config-migrate`(設定跨 slot 靠它)
    - `etc/uci-defaults/98-batman-sysupgrade`
    - `usr/bin/batman-autocommit`
    - `etc/init.d/batman-autocommit`
    - `usr/lib/batman/meshjoin.sh`
    - `usr/bin/joinwatch`
    - `usr/bin/batman-config-save`(後兩者會寫入 commit 閘門要讀的 mesh 標記)
    - `usr/share/batman/firmware-allowlist-bcm2710.sha256`
  - `deploy/provisioning/` 裡的複本:`uci-defaults/*`、`joinwatch`、`batman-config-save`
  - feed `batman-payload-host/`
  - 建卡與打包:`scripts/build-ab-payload.sh`、`scripts/build-gpt-ab-card.sh`、`scripts/build-ab-image.sh`、`scripts/lib/pi3-fwpart.sh`
- §4 裡 `halow-status`、`batman-version` 也是兩板都會執行,但只負責顯示,不影響 OTA,所以不在這份清單上。firmware fork 的改動(gpu-fw、distroconfig 等)不在這個 CI 的管轄範圍,由 firmware fork 的 config lock 和 `build-board.sh` 把關。
- PR 改到上面任一檔案時,CI 檢查 `ab-shared-change` 要求 PR body 同時有 `### bcm2711` 和 `### bcm2710` 兩個實測段落(寫哪台、做了什麼、原始輸出或數字;沒測就寫「未測」和原因)。**這個檢查只確認「有交代」,不確認「真的測了」**:review 的人要讀內容。不要把它設成 branch protection 的必要檢查,否則沒動到這些檔案的 PR 會永遠卡在 "Expected"。
- 故障注入點(`BATMAN_FAULT_INJECT`)只在直接呼叫 `batman-slot` 時生效:sysupgrade 的 stage2 由 procd 用自己的環境啟動,環境變數傳不進去,所以正式運作時不會誤觸發。`mbr-mismatch` 只對 pi3 有效(pi4 不讀 MBR);`tryboot-get`、`corrupt-after-write` 兩板都有效。§4 失效矩陣第 147、148、164 列要直接執行 `batman-slot apply`。
- 部署角色的節點只用 sysupgrade 驗證。
- 新功能的回歸測試加進 `scripts/daily-validation.sh`;因 SoC 本來就不適用的 suite 用 `na`(會列出理由,但不算失敗),不要用 SKIP 偽裝。

## 7. 坑

- rootfs:一律用 `scripts/pick-rootfs.sh`,不要直接拿 build_dir 的 `root.squashfs`,也不要從 `.img.gz` 切 p2。原因見 §3 的兩次事故。
- 從 Windows 經 `\\wsl.localhost` 寫進 WSL 樹的檔案,擁有者會變成 root。Windows git 操作過 `.git` 之後,WSL 的 git 會寫不進去(`cannot lock ref`)。處理:`wsl -u root chown -R yello:yello <path>`。
- OpenWrt 平行編譯偶爾會有競態(例如 `toolchain/gcc/final`);改用 `-j1` 重跑就會過。`build-board.sh` 會自動重試。
- 開機檔要複製到 FAT(boot 分割、p7)時不要用 `cp -a`:FAT 沒有擁有者,非 root 擁有的檔案會出現 "failed to preserve ownership",在 `set -e` 下整個建卡就中止。`build-ab-image.sh` 已改用 `cp -r --preserve=mode,timestamps`。
- WSL 沒有 udev:`losetup -P` 之後,loop 的分割節點(`/dev/loopNpX`)是非同步出現的。`build-ab-image.sh` 現在最多等 10 秒;曾經有一次 Pi 3 建卡因為這樣失敗,重跑就過。

- WSL:`wsl bash -c '...'` 會吃掉 `$變數`,一律寫成腳本檔再執行;WSL 裡 `git push` 會卡在認證,改用 Windows git:`git -c safe.directory='*' -C //wsl.localhost/Ubuntu-24.04/home/yello/firmware-2710 push github build-3aplus`。
- 不要從 Windows 用 `Set-Content` / `>` 改開機分割的檔案(會變成 CRLF,#208)。
- busybox 沒有 `pkill`、`timeout`、`install`、`sleep 0.3`、`cat -n`。
- Pi 3:p7 的 `autoboot.txt` 一壞就永久卡死、要重燒;只能由 `batman-slot` 的單一磁區寫入去改。
- Pi 3 電源餘量很薄:長時間電壓不足時,HaLow SPI 會逾時;反覆 `wifi down/up` 會讓 morse 驅動卡在 D 狀態。紅燈 5 Hz 閃 = meshled 鎖存的「開機以來曾經電壓不足」(`meshled clear` 清除)。
- `sysupgrade` OTA 的那次開機目前會被記成 `prev=UNCLEAN`(ramfs 階段最後 `reboot -f`),已另開待辦。
