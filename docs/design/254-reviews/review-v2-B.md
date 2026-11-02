# #254 階段 1 實作設計 v2 — 獨立審查 B(第 2 輪,對抗式)

審查對象:`254-stage1-impl-v2.md`(整份,§0–§13)。對照:`219-field-provisioning.md` v2.8、`219-protocol.md` v0.6、`202-config-survival-closeout.md` v6、`REVIEW.md`、`review-v1-A.md`、`review-v1-B.md`。
證據(2026-10-18,全部唯讀,沒有任何寫入):Batman `main` f2f2bf6 原始碼(`src/` 快照:`batman-config-save`、`96-batman-config-migrate`、`batman-autocommit`、`batman-slot`、`halow-setkey`、`halow-keyguard`、`joinwatch`、`meshjoin.sh`、`rundir.sh`、`99-halow-identity`);firmware tree `/home/yello/firmware-2710`(`build_dir/target-aarch64_cortex-a72_musl/linux-bcm27xx_bcm2711/linux-6.6.138` 原始碼與 `.config`、`target/linux/bcm27xx/bcm2711/config-6.6`、`target/linux/bcm27xx/image/boards/ekh01/distroconfig.txt`、`package/base-files/files/etc/init.d/boot`、`feeds/packages/utils/bluez/Makefile` + `files/bluetoothd.init`、`dl/bluez-5.72.tar.xz` 的 `src/adapter.c`/`main.c`/`main.conf`/`bluetooth.conf`、`package/kernel/linux/modules/other.mk`);節點 04(10.41.1.3,slot A)與 02(10.41.1.1,slot B):`cat`/`ls`/`uci show`/`ps`/`zcat /proc/config.gz`/`vcgencmd`/`dmesg`/sysfs/p5 `ro,noload` 掛載後 umount。

## 0. 結論先講

**判定:REJECT(需出 v3 再整份重審)。**

v2 真的把 v1 的骨架問題收掉了:授權物件進 helper(B-B2)、單檔 `prov.cbor`(B-B3)、p5 = SoT + 96 marker(A-B3)、legacy 狀態(B-M3)、autocommit 依 prov 狀態(A-B1)、dbus policy 替換(A-M1/B-M4)、自建 kmod(B-M5)、合法 `main.conf` 鍵(A-M6)。這些方向對,可以留。

但這一輪在三個地方又踩到「設計依賴的事實與真機相反」或「核心流程做不出它說的結果」:

| 等級 | 數量 | 編號 |
|---|---|---|
| BLOCKER | 3 | B1 serdev 根本沒開(`hci_bcm` 不會 probe,D1 的 ✅ 是錯的)、B2 恢復出廠做不出「unclaimed、新身分」而且把前任的 overlay/p6 留給下一手、B3 `legacy → NEED_MESH=0` 把既有 fleet 的 OTA mesh 閘門拆掉 |
| MAJOR | 10 | M1–M10 |
| MINOR | 16 | m1–m16 |

## 1. 先補矩陣與擁有權表漏掉的(REVIEW.md 要求 reviewer 第一件事)

| 漏掉的路徑 / 資源 | 為什麼重要 | 對應 |
|---|---|---|
| **非 fresh 開機、p5 掛不起**(§4.4 步驟 6 的 `--check` rc 1) | helper 要以 overlay 續跑(可用性)還是 `unknown`(fail-closed)?沒寫 | m14 |
| **fresh 開機時 p5 暫時掛不起 → 之後的每一次開機**(96 已被 `uci_apply_defaults` 刪掉,marker 永遠 `p5-unavailable`) | 新卡第一次開機一個 SD 時序問題 = 永遠 `unknown`、無身分、不能認領 | M3 |
| **恢復出廠之後的「同一個 overlay」開機**(§4.5 不清 overlay,96 不再跑) | hostname/IP/dropbear 鎖/shadow/authorized_keys/IRK/`lock-status`/p6 tenants 全部留給下一手;身分產生條件(marker=`absent`)不成立 | B2 |
| **單台在家更新**(擁有者一個人、隊友都關機;219 §6.9 的 app 背景下載 + apply) | L6 `member && members>1 → 要求入網` = 每次都 revert | M5 |
| **legacy 節點第一次 OTA 到階段 1 image 而 p1 還沒重燒**(L19 說要手動重燒,但 L17 的測試是「04 OTA」) | `core_freq_min` 沒帶到 → mini UART 間歇錯框 → `hci0 Powered` 閃爍 → `health_ok` 回退 → revert | M4 |
| **helper 的 `state.apply` 進行中 joinwatch 的 `--on-join` tick** | config-save「讀 `.stage/prov.cbor` 若存在」是所有模式 → 未提交的交易被 `--on-join` 發布到 p5 | M1 |
| **SD 標記檔恢復出廠撞上 trial 槽 / 標記刪不掉** | 拒絕後標記留著;FAT 刪除失敗 = 每次開機重置迴圈 | m5 |
| **在 trial 槽上認領 → revert 回 1.5.12 槽**(不是回另一個階段 1 槽) | L21 的「helper 重建 overlay」在 1.5.12 槽沒有 helper;使用者看到的是「認領不見了」 | m11 |
| 資源:**`$ST/prov-state` 的 boot 綁定**(helper 沒跑到就寫 → 前一次開機 / 前一個槽的值殘留) | autocommit 用它決定要不要驗 mesh | m4 |
| 資源:**`batman-slot invalidate-other`、`halow-setkey --mesh-off`** | 兩個動詞都不存在(02/04 usage 實證);`batman-slot` 是兩板共用檔(219 §9) | M10 |
| 資源:**`CONFIG_SERIAL_DEV_CTRL_TTYPORT`(kernel 內建 bool)** | §4.6 的 kernel 清單只有 BT 模組;沒有它 serdev 不接管 ttyS0 | B1 |
| 資源:**上游 `kmod-bluetooth`(`.config` 仍 `=m`)與 `bluez-libs` 的 `DEPENDS:=+USB_SUPPORT:kmod-bluetooth`** | 自建 kmod 會跟它撞:同一個 kernel 全域符號 `CONFIG_BT_BREDR` 兩個值、兩份 `bluetooth.ko` | M7 |

## 2. BLOCKER

### B1 — serdev 沒有開:`hci_bcm` 不可能自動 probe,D1「✅ 原始碼」是錯的;PR-F 照 §4.6 做會得到一個沒有 `hci0` 的 image

**情境**:PR-F 依 §4.6 建 `kmod-batman-bt`、裝 `.hcd`、`distroconfig [pi4] dtoverlay=miniuart-bt`(今天 p1 就已經是這樣)→ 開機 → `bcm2835-aux-uart` 把 `serial@7e215040` 註冊成**一般 tty `ttyS0`**,serdev 沒有接管 → `hci_uart`/`btbcm` 載入了但沒有任何 serdev 裝置 → 沒有 `hci0`;bluetoothd 起來沒 adapter;provd 退避。而 v2 又刻意不裝 `hciattach`/`btattach`(§4.6 BlueZ 列),連手動 `btattach -B /dev/ttyS0` 的備援都沒有。

**證據**:
- 04 與 02 `zcat /proc/config.gz`:`CONFIG_SERIAL_DEV_BUS=y`、**`# CONFIG_SERIAL_DEV_CTRL_TTYPORT is not set`**;build tree `target/linux/bcm27xx/bcm2711/config-6.6:445-446` 同;kernel `.config:2682-2683` 同。
- `drivers/tty/serdev/Kconfig:14-22`:`SERIAL_DEV_CTRL_TTYPORT` = 「Say Y here if you want to use the Serial device bus with common TTY drivers (e.g. serial drivers)」— 沒有它,8250/aux-uart 這種 tty 驅動不會建 serdev controller。
- 04 實機:`dmesg`:`fe215040.serial: ttyS0 at MMIO 0xfe215040 (irq = 33, base_baud = 62500000) is a 16550`;`/sys/class/tty/ttyS0 -> …/fe215040.serial/tty/ttyS0`(tty 存在 = serdev 沒接管);`/sys/bus/serial/devices/` **空**;`/sys/bus/platform/drivers/` 只有 `bcm2835-aux-uart`、無 `ttyport`。DT 已經正確:`/proc/device-tree/soc/serial@7e215040/status = okay`、子節點 `bluetooth` 存在且 `status = okay`(`bcm271x-rpi-bt.dtsi:14-23` 的 `minibt`,`max-speed = <230400>`)— 也就是 DT 這半邊 v2 說對了,缺的是 kernel 這半邊。
- `drivers/bluetooth/Kconfig:211-218`:`BT_HCIUART_BCM depends on BT_HCIUART_SERDEV`(`:119-122` 是 `default y`,所以能編),但**能編 ≠ 會 probe**:`hci_bcm.c` 的 serdev 路徑(`:462,538`)要 serdev core 先把 `bluetooth` 子節點變成 `serdev_device`。
- `other.mk:30-62`/`.config:1526-1528`:上游也只有 `BT_HCIUART_SERDEV=y`,沒碰 `SERIAL_DEV_CTRL_TTYPORT`。

**修法**:
1. `target/linux/bcm27xx/bcm2711/config-6.6`(以及之後 bcm2710)加 `CONFIG_SERIAL_DEV_CTRL_TTYPORT=y`。它是內建 bool → 改的是 `kernel8.img`,不是 kmod;OTA payload 帶 kernel(`batman-slot:645`),所以 OTA 帶得到,但 §4.6 的 kernel 列要明寫「kernel config 改動」而不是只有「自建 kmod」。注意 `cmdline` 的 `8250.nr_uarts=1` 不用動。
2. PR-F 驗收加:`ls /sys/bus/serial/devices/` 出現 `serial1-0`(或對應名)、`/sys/class/tty/` **不再有 `ttyS0`**(serdev 接管後 tty 不建 — 這同時是「任何 userland 都碰不到 BT UART」的證據)、`dmesg` 有 `hci_uart_bcm serial1-0: BCM: chip id …` 與 `BCM4345C0 'brcm/BCM4345C0.hcd' Patch`。
3. 負對照:今天的 image(serdev 關)— 同一組 kmod 載入後 `hci0` 不存在(= 上面 04 的實測)。
4. D1 改成 ⚠️「原始碼 + 內建 bool 待 PR-F」,不是 ✅。

### B2 — 恢復出廠做不出「`unclaimed`、新身分、新 QR」,而且把前任的 overlay 與 p6 原封不動留給下一手

**情境**:擁有者 app `reset(factory)` → §4.5:`--wipe-all` 清 p5 → `halow-setkey --ap-off --mesh-off` → 清 `/etc/batman-prov` → 作廢另一槽 → `reboot`。重開後**同一個 overlay**(§4.5 沒有清本槽 overlay,`batman-slot invalidate-other` 只碰另一槽):
1. 96 不跑(不是 fresh overlay;`uci_apply_defaults` 在 exit 0 後 `rm -f` 它,`init.d/boot:13-15`)→ `/etc/.batman-prov-restore` 還是上次 fresh 開機寫的值(`restored` 或 `absent`),不會因 reset 改變。
2. helper 看到 `/etc/batman-prov` 空 → §4.2「只在 marker=`absent` 且 p5 無 `identity/prov/`」才產生。若上次是 `restored`(每一台曾經 OTA 過的機台都是)→ **不產生 → `unknown`**,不是 `unclaimed`。§4.5 的「開機看到 marker → 續做」沒有定義續做包含產身分,而 §4.2 的規則明文禁止。
3. 就算產了身分,下一手拿到的機台仍是:前任的 hostname / `ahwlan.ipaddr`、`dropbear.PasswordAuth=off` + 前任的隨機 root 密碼 hash(shadow)、前任 `authorized_keys` 裡的 lab 行(02)、`system.ttylogin=1`、`lock-status=LOCKED`、`/etc/bluetooth/keys` 的 IRK(前任 app 仍認得出這台的 RPA)、p6 的 `mesh-expected`/`mesh-joined`、**p6 上的 docker tenants(04 跑 OTS:TAK server 的資料庫)**。219 §7 明寫恢復出廠要清「擁有者、`authorized_keys`、root 密碼、`lock-status`、整個 p5、p6 資料、另一槽 overlay」;v2 §4.5 只做了 p5、`/etc/batman-prov`、另一槽。
4. 反過來看 96 自己的假設:`96:159`「a factory-reset (overlay wipe) re-runs this hook」— 這個 repo 對「恢復出廠」的既有定義就是 overlay wipe,v2 沒有做。

**證據**:§4.5、§4.2、§3 marker 列(「96 每次它跑到時寫」— 但 96 只在 fresh overlay 跑);`init.d/boot:7-17`;`96:155-176`(lock 只在 96 跑時重新導出);04 `docker ps` 有 OTS 容器、p6 `/opt/batdata/apps`;219 §7。

**修法**(v3 要定案,每一項都要在矩陣 L16 有測試):
- 恢復出廠的資源清單**逐項列出**並指定誰清:p5(`--wipe-all`)、p6 的 `state/`(保留 `slot-*.protected`、`autocommit.timeout`?要決定)與 `apps/`/tenants(219 §7 要求)、另一槽 overlay(`batman-slot` 新動詞)、**本槽 overlay**、`/etc/bluetooth/keys`、dropbear/shadow/ttylogin/lock-status。
- 本槽 overlay 怎麼清要**先探針再寫**:OpenWrt 的 `jffs2reset -y`(對 overlay 走 `mount_root` 的 `rootfs_data` 重格式化路徑)在這個 f2fs-on-loop 的版面能不能用、會不會碰到 `96:76-88` 註解的「舊 f2fs superblock 殘留」問題;或者改成「`batman-slot` 把**本槽**也標成待清 → 重開進另一槽?」(但另一槽剛被作廢)。這是設計決定,不是實作細節。
- 身分產生規則改成由 helper **自己看 p5**(見 M3):p5 無 `identity/prov/` 且非 bypass 且 p5 可讀 → 產生;marker 只告訴 helper「96 這次有沒有跑」。
- 斷電續做:`factory-reset.inprogress` 要記錄步驟,每一步冪等;測試含「p5 清了、overlay 還沒清」與反向兩個斷電點。
- 負對照:在 v2 的流程上做一次 reset,斷言 `uci get system.@system[0].hostname` 與 `grep ^root: /etc/shadow` 與 `ls /opt/batdata/apps` 都**沒變** → 證明問題存在;v3 流程上同一組斷言必須全變。

### B3 — `legacy → NEED_MESH=0` 把既有 fleet 節點的 OTA mesh 閘門拆掉(1.4.12 教訓原樣回來)

**情境**:02/04 今天是 mesh 成員(真 key、p6 有 `mesh-expected` 與 `mesh-joined`)。OTA 到階段 1 image → 它們是 `legacy`(L17)→ helper 寫 `$ST/prov-state = legacy …` → L6 的 `expected_in_mesh()` v2:「`$ST/prov-state` 存在 → `unclaimed|claimed|legacy` → 0」→ **NEED_MESH=0**。從這一刻起,任何一個 morse 驅動壞掉 / channel 錯 / `kmod-brcmfmac` 掉了的 image 都會在 02/04 上 **commit**。今天同一台會 revert(`batman-autocommit:388-397`:p6 marker → NEED_MESH=1)。這正是記憶裡 2026-09-25「1.4.12 報廢、02 stranded」那一類事故的防線,v2 對唯一真實存在的節點把它關了。而且 L17 的測試 `prov-legacy-upgrade-254` 只斷言「AP key 不變、UNPROVISIONED 不變、SSH 不變」,抓不到。

**證據**:L6 表;04/02 `cat /opt/batdata/state/mesh-expected` = `seeded --on-join`、`mesh-joined` 存在;`batman-autocommit:388-397`。

**修法**:`legacy` **不**進新規則:`prov-state` 的 state 為 `legacy` 時 `expected_in_mesh()` 一律退回今天的規則(p6 marker / p5 `.seeded`);`mark_mesh_expected()` 在 legacy 也照舊寫。只有 `unclaimed|claimed` 才回 0。負對照:04(legacy)OTA 到一個 `uci set wireless.radio1.disabled=1` 的 trial → 必須 revert;v2 規則下會 commit。

## 3. MAJOR

### M1 — `.stage/prov.cbor` 被所有 config-save 模式讀取 → joinwatch 的 `--on-join` 會把**未提交的交易**發布到 p5;配上「p5 是 SoT」規則,被回滾的交易下次開機復活;L25「helper 持 `cfgsave.lock`」做不到

**情境**:`network/leave`(成員節點,JOINED):步驟 1 helper 寫 `.stage/prov.cbor`(gen+1,state=claimed、無 net)→ 步驟 2 `halow-setkey`(`wifi reload` + 最多 20–60 s 讀回)期間 joinwatch 每 tick 跑 `--on-join`(`joinwatch:145`,JOINED 時每 tick)→ §4.3「config-save 讀 `.stage/prov.cbor` 若存在」→ p5 拿到 gen+1。若步驟 2 失敗 → helper 回滾副作用、刪 stage、回 `E_APPLY`,app 顯示失敗 → 但 p5 已是「已離開」→ 下次開機 §4.4 步驟 6「p5 generation > overlay → 以 p5 重建 overlay」→ 節點真的離網了,而 app 被告知失敗。`net.apply`(新 key 套不上)同理:復活一個驗證失敗過的 mesh 設定。
另外 `onjoin_fp()` 若算的是 overlay 的 `prov.cbor` sha、寫的卻是 stage,快取永遠不命中 → 每 tick 寫 p5(寫入放大,#202 A3 的 guard 會開始限速並 warn)。
L25 說「helper 持 `cfgsave.lock` 競爭:`--save` 排隊」:`batman-config-save:115-122` 的接管規則是「持有者 cmdline 不含 `batman-config-save` 就當殘鎖接管」,helper 持鎖會**立刻被接管**,互斥不存在。

**修法**:config-save **永遠不讀 `.stage/`**;helper 的 persist 用明示參數(例如 `--save --prov-file <path>`,只有這一次寫 stage 檔),`--on-join`/`--check`/`--seed` 只看已提交的 `/etc/batman-prov/prov.cbor`。交易順序變成:stage → 副作用 → `--save --prov-file stage`(p5 先到 gen+1)→ rename → `prov-state`;在 3 與 4 之間斷電 = p5 較新 = 步驟 6 重建(這才是「p5 是 SoT」該涵蓋的唯一情境)。L25 改寫:互斥靠「helper 的 persist 本身就是 config-save 取鎖」,不靠 helper 持鎖。測試:`prov-netupdate-254` 加「步驟 2 故意失敗 + 期間 `--on-join` 跑過」→ 重開後 state 必須不變。

### M2 — marker 四態 vs `legacy` 五態、「只在 `absent` 產身分」vs「legacy 開機就產」:兩條規則互相矛盾,`legacy` 的定義自己會翻轉

- §3 marker 列:`restored|absent|p5-unavailable|too-new`;L17:marker=`legacy`;§4.2:「**只有** restore marker = `absent` …」;L17/Q1:legacy 開機就產身分。兩個實作者會做出不同的東西(一個 fail-closed 不產,一個產)。
- `legacy` 定義為「p5 `.seeded` 且無 `prov.cbor`」(§1.4)。helper 替 legacy 產了身分後要 `persist`(否則 QR 跨 OTA 無效)→ p5 就有 `prov.cbor` 了 → 下一次 fresh 開機,它不再符合 `legacy` 的定義。要嘛 `prov.cbor.state = legacy` 明寫,要嘛「有 prov.cbor 但 state=legacy」另有行為。
- **修法**:狀態只由 `prov.cbor.state` 決定(`legacy` 是一個明寫的 state,由 helper 在升級後第一次開機建立並 persist);96 的 marker 只描述「這次 fresh 開機 p5 的情況」(四態,`.seeded` 無 prov 歸 `absent` 加一個 `seeded=1` 欄位);§4.2 的產生條件改成 M3 的規則。

### M3 — restore marker 一生只寫一次,helper 卻每次開機都信它:fresh 開機 p5 一次暫時性掛載失敗 = 這個 overlay 永遠 `unknown`(無身分、不能認領、AP 關)

**情境**:新卡第一次開機(或任何 OTA 後的 fresh 開機)p5 掛載暫時失敗(2026-09-13 真的發生過,原因是 overlay 壞;但 SD 時序問題在 bench 也見過)→ v2 L20:96 寫 `p5-unavailable` 再 `exit 0` → `uci_apply_defaults` 把 96 **刪掉**(`boot:14`)→ 之後每次開機 p5 都正常,96 卻不再跑、marker 永遠 `p5-unavailable` → helper 每次開機 `unknown`:不產身分、AP 關、只有 `status/public`。民用機沒有 console,唯一出路是重燒卡。bypass 路徑沒這問題(`96:63-64` exit 1 留著),只有 mount-fail 路徑有。
**修法**:helper 開機自己 `ro,noload` 看 p5(或借 `batman-config-save --check` 的結果 + 自己讀 `identity/prov/` 存在與否):p5 可讀且無 `identity/prov/` 且非 bypass → 產生;p5 可讀且有 → 還原(非 fresh 時由 helper 自己抄,等同 96 Lane A 的 prov 版);p5 不可讀 → `unknown` 但**下次開機再試**。marker 只用來區分「96 跑過/沒跑過」,不當永久判決。負對照:fault-injection 讓第一次開機的 p5 掛不起(白箱:`batman_bypass` 不行,它走 exit 1;要用「96 單元測試 + helper 單元測試」兩段),第二次開機必須有身分。

### M4 — `health_ok()` 無條件要求 bluetoothd + provd + `hci0 Powered`:BT 硬體壞 / `.hcd` 缺 / p1 沒重燒(02/04 現況)的節點**永遠**不能 OTA;legacy fleet 的第一次 OTA 就會撞到

**情境**:(a) 02/04 的 p1 `distroconfig.txt` 沒有 `core_freq_min`(實證 `vcgencmd get_config core_freq_min` = 200、`core_freq` = 500;p1 不隨 OTA,`batman-slot:663` 明列 `distroconfig.txt` 不抄)。L19 說「02/04 手動重燒 p1(使用者)」,但 L17/L5 的測試是「04 OTA」— 順序沒綁死。mini UART 在 `max-speed = <230400>`(`bcm271x-rpi-bt.dtsi:17`)下 baud 由 core clock 導出;閒置時 core 掉到 200 MHz → 間歇錯框 → `hci0` Powered 可能閃爍 → `health_ok` regress → 到 deadline revert。(b) 一台 BT 晶片壞的機台(或 `.hcd` 包錯)→ 之後**每一個** image 都 revert,連修它的 image 也上不去;唯一出口是 `autocommit-hold-once`,v2 沒提。
**修法**:BLE 健康只在「上一個 committed 槽證明過 BLE 可用」時要求:helper 在 committed 槽第一次看到 `hci0` up 時寫 p6 `$ST/ble-ok`(含 boot id),`health_ok` 只在 `ble-ok` 存在時檢查 BLE;另明寫 `autocommit-hold-once` 是逃生口。PR-F 的順序寫死:**先重燒 02/04 的 p1,再做 L5/L17 的 OTA 測試**;L19 的閒置 10 分鐘取樣是 PR-F 的前置,不是附帶。

### M5 — `member && members>1 → 要求入網`:擁有者一個人在家更新(隊友全部關機)= 每次 OTA 都 revert

219 §6.9 的更新流程是 app 背景下載、擁有者自己 `update/apply`;現場最常見的就是「出發前一晚在家一台一台更新」,沒有鄰居。L6 規則下 `member`(members>1)節點 OTA → `meshjoin_reachable` 永遠不成立 → 到 deadline revert。這和 B3 是同一個旋鈕的兩端:B3 太鬆,M5 太緊。
**修法**:`member` 一律至少要 `meshjoin_radio_up`(wlh0 mesh point、`mesh_id` == uci);「要求看到鄰居」只在 **這次開機前 N 分鐘內 committed 槽曾經 JOINED**(joinwatch 的 `mesh-joined` 加時間戳 + boot id)或 app 在 `update/apply` 帶 `expect=mesh`(owner auth)時要求。把決定寫進 `prov-state` 的第四欄,autocommit 讀它。測試:單台 member、無鄰居 → OTA 必須 commit(負對照:v2 規則 revert);有鄰居的 member OTA 到 `radio1.disabled=1` → 必須 revert。

### M6 — `keystore.ecdh(peer_pub)` 對 provd 無授權開放:攻陷的 provd 可以把它經手的 `net_secrets` 解開,「明文 SAE key 不經 provd」白寫

`net_secrets` 經 BLE 進來一定先過 provd(密文);COSE_Encrypt 的 CEK = HKDF(ECDH 共享秘密, context),context 全是公開值(`219-protocol.md` §7.3:`target_dac_hash`、`net_id`、`net_version`、AlgorithmID);§4.1 讓 provd 拿 `ecdh(peer_pub)` 的「HKDF 輸出,標籤固定」— 只要那個輸出能導出 CEK(或就是共享秘密的某個確定性函數),provd 就能解密它剛轉送的 `net_secrets`。B-B2 的收法本來就是「helper 自己解」(§4.1 `net.apply` 已經這樣做),所以這個動詞沒有正當用途。
**修法**:從 provd 可呼叫的動詞表刪掉 `keystore.ecdh`;ECDH 只在 helper 的 `net.apply` 內部用。負測試:provd uid 呼叫 `keystore.ecdh` → `E_SCHEMA`/`E_FORBIDDEN`。

### M7 — 套件層面做不出 §4.6 的 kernel 側:`bluez-libs` 硬依賴上游 `kmod-bluetooth`,`.config` 也還選著它;`CONFIG_BT_BREDR` 是 kernel 全域符號,兩個 KernelPackage 給不同值會撞

**證據**:`feeds/packages/utils/bluez/Makefile:40` `Package/bluez-libs DEPENDS:=+libpthread +USB_SUPPORT:kmod-bluetooth`(Pi 4 有 USB_SUPPORT → 任何 bluez-* 都拉進上游 kmod);`:72` `bluez-daemon DEPENDS:=+bluez-libs +bluez-utils +bluez-utils-extra …`(hciattach/rfcomm/gatttool/sdptool 全進來);`.config:2779 CONFIG_PACKAGE_kmod-bluetooth=m`(A 的 R3);`other.mk:38-39` `CONFIG_BT_BREDR=y` 是該套件的 KCONFIG。OpenWrt 的 kernel `.config` 是 target config + **所有被選到的** KernelPackage 的 KCONFIG 合併;`kmod-bluetooth` 與 `kmod-batman-bt` 同時被選 → `CONFIG_BT_BREDR` 一個要 y 一個要 n、兩個套件都宣告 `net/bluetooth/bluetooth.ko` → 不是 build 失敗就是裝到哪個看運氣。
**修法**:(1) board diffconfig 明寫 `# CONFIG_PACKAGE_kmod-bluetooth is not set`(記憶裡 build A/B image 必用 board diffconfig 的規則正好適用);(2) 自己的 bluez 套件(或 feed patch)把 `bluez-libs` 的依賴改成 `+kmod-batman-bt`,`bluez-daemon-min` 不依賴 `bluez-utils*`;(3) PR-F 驗收加 `ls /lib/modules/*/` 的 BT 子集 = 恰好 `bluetooth.ko btbcm.ko hci_uart.ko` 三個、`lsmod` 無 `rfcomm|bnep|hidp|btusb`、`opkg list-installed | grep bluez` 只有 libs + daemon-min。

### M8 — `99zz-batman-prov-state` 在 S10 呼叫 `--apply-state` → `halow-setkey --ap-off` → `wifi reload` + 20 s 讀回 + `batman-config-save --save`:在 network(S20)/wpad(S19)/keyguard(S18)之前做這些是錯的

`halow-setkey:99-137`:`uci commit` → `wifi reload`(netifd 還沒起 → 失敗或掛)→ 等 `mesh_netdev` 最多 20 s → `batman-config-save --save`。uci-defaults 階段的 hook 應該只 `uci set` + 寫 keyguard MARK;§4.5 把 hook 與 helper 都綁到同一個 `--ap-off`(B-M2 的收法)是對的,但 `--ap-off` 需要一個 `--firstboot`(或 `--no-reload --no-persist`)模式:只改 uci + MARK、不 reload、不 persist;執行期才做完整流程。另外 S10 時 `batman_rundir` 要 `/tmp/run` 已存在(procd 早建,OK),但 p5 的 `--save` 在 fresh 開機這個時間點是多餘的(96 剛從 p5 還原)。
**修法**:§4.5 加 `--ap-off --firstboot`;L1/L2 測試斷言 S10 階段沒有 `wifi reload` 的 log 行(負對照:v2 會有 `halow-setkey: … reloading wifi` 在 boot 早期)。

### M9 — legacy 認領會把操作員鎖在外面(04:無 `authorized_keys`、無 `batman-dev-open`、跑 OTS);而今天任何連上 04 AP 的人都能 root → 印 QR → 認領

04 實證:`lock-status=UNPROVISIONED`、`/etc/dropbear/` 無 `authorized_keys`、`PasswordAuth=on`、root 無密碼、AP 真 key 開著、`/etc/batman-dev-open` 不存在、p6 跑 OTS 容器(靠 SSH 維運)。L18/§6.2:認領 → `PasswordAuth=off`、隨機 root 密碼、**不動 `authorized_keys`**(= 沒有行)→ SSH 關;Ethernet 進來也是 key-only;serial 是 GPS 口(R34)。結果:認領 = 失去對 04 的維運通道,OTS 只能經 BLE 診斷包。再者,`batman-provhelper qr` 只要 root 就能印(§4.2),04 今天 root 是開的(#137 既有缺口)→ 路人連 AP → SSH → `qr` → 用自己的手機認領 → 鎖定後**操作員**進不去,路人是擁有者。新的不是「路人能 root」(既有),新的是「路人能把擁有權拿走並把你鎖在外面,而且 ownership 在 p5 跨 OTA 存活」。
**修法**:`claim.verify` 在 `legacy` 狀態要求「`/etc/batman-dev-open` 存在 **或** `authorized_keys` 至少一行可用」,否則 `E_UNSUPPORTED(reason=no-ssh-key)`,app 文案「先裝 SSH 公鑰或開發標記」;`batman-provhelper qr` 在 legacy 只允許 `batman-dev-open` 存在或 serial console(`tty` 檢查)時執行;L18 在 **04** 做負測試(必須被拒),02(有 lab key)做正測試。

### M10 — `batman-slot invalidate-other`、`halow-setkey --mesh-off` 不存在,也不在 PR 清單;`batman-slot` 是兩板共用檔

02/04 `batman-slot` usage:`active|target|layout|fw-part|stage-root|apply|commit|rollback|is-trial|verify|precheck-node|verdict-gate|reboot`— 沒有 `invalidate-other`(內部函式 `invalidate_slot` `:381` 有,沒有 CLI);`halow-setkey` 只有 `--mesh/--ap/--mesh-id/--channel/--status`,v2 §4.5 標題只定義 `--ap-off`,內文又用了 `--mesh-off`。219 §9 規定兩板共用的 A/B 檔要兩板實測,3A+ 現在沒板(U6)→ `batman-slot` 的改動要寫明「bcm2710 ❌ 未測」並進殘項。
**修法**:§10 PR-P1 加 `batman-slot invalidate-other`(含 `is-trial` 拒絕與 `otalog_k` 固定 token)、`halow-setkey --mesh-off`(語意:mesh key = placeholder + radio disabled + MARK;注意 `halow-setkey:55` 今天拒絕 placeholder);L13 註明。

## 4. MINOR

- **m1 `keystore.sign(purpose, msg)`**:helper 必須**自己組**被簽內容(標籤 + 自己的 `boot_id`/`nonce_node` + 對方欄位),不能接受整段 `msg`;否則攻陷的 provd 可以拿舊 `nonce_node` 要到 `batman-peer-v1` 簽章。另外 608B 簽章 ~100 ms、與 INA226/RTC 共用 I2C(協定 §8 全域 2/s)→ helper 端限速,`file` 後端就先做,`se` 才不用重工。
- **m2 `claim.verify`**:helper 要用**自己發的一次性 nonce** 重算 `ClientChal`,不接受 provd 算好的 `client_chal`(否則 CheckMac 綁不到 `owner_pub`,provd 可以拿一組合法 (chal, resp) 換上自己的 owner_pub)。
- **m3 授權漏網**:`persist(promote_lkg)` 無授權 → 攻陷的 provd 能把未證明的設定升成 lkg(96 在 overrides 壞時退回 lkg)— 改成只有 helper 內部在 `meshjoin_joined` 後才下;`ssh_keys.set` 正規式要明寫「單行、無 `\n`、長度上限」(Go 的 `$` 預設不是多行模式,但要寫進規格與向量)。
- **m4 `$ST/prov-state` 沒有 boot 綁定**:helper 沒跑到(crash、trial 槽二進位壞)就留著前一次開機/前一個槽的值;加 boot id 欄,autocommit 不符就當「無檔」(退回今天規則)。
- **m5 SD 標記檔**:誰刪、刪不掉(FAT)怎麼辦(每次開機重置迴圈)、trial 中拒絕後標記留著等 commit 再炸;p1 是 `rw` 掛在 `/boot`、root 0755 fmask 0022(04 實證)所以非 root 寫不到 ✅,但要寫進 §8。
- **m6 respawn 3600 5 5**:5 次 crash 後 procd 放棄 → BLE 管理面死到重開機;一個會讓 provd crash 的 BLE 封包 = 遠端 DoS 管理面。改 `respawn 3600 5 0`(無限)+ 自己退避。
- **m7 bluetoothd init「沒 hci0 就退出」**:`btbcm` patchram 要幾秒,S61 時 hci0 常常還沒出現;bluetoothd 本來就靠 mgmt 熱插拔,讓它跑就好,不要退出/respawn 競速。
- **m8 `--noplugin=*`** 也關掉 `hostname` plugin(它會把 adapter Name 設成系統 hostname → 若 adv 帶 Local Name 就洩漏 hostname)— 好事,但要明寫 `main.conf Name=` 固定值且 provd 的 LE adv **不帶** Local Name;`g_pattern_match_simple` 支援 `*` ✅。
- **m9 `device_id` 從 `sn` 的導出公式沒寫**(§4.2 只有 `SN() [9]byte; DeviceID() string`);這是 QR 與 cert CN 的內容,Go/Rust 會各做一種;進 `-dev` 向量後才算定案。
- **m10 96 還原 `identity/prov/` 的信任**(A-m2 仍開):只抄 regular file、強制 0600/0644、大小上限、`backend` 內容白名單;p5 是實體信任等級但 96 是 root。
- **m11 L21 / 在 trial 槽認領**:L21「以 p5 重建 overlay」要列清楚重建什麼(`identity/prov`、`prov.cbor`、`shadow-root`、`authorized_keys`、dropbear uci、`lock-status`);revert 回 **1.5.12** 槽時沒有 helper,什麼都不會重建(擁有者 app 看到「未認領」但 p5 說已認領,下次升級才回來)。建議:provd 在 `batman-slot is-trial` = 0(未 commit 的 trial)時對所有改狀態的動詞回 `E_BUSY(updating)`,只允許唯讀;219 §6.9 的更新流程本來就是 app 在等 commit。
- **m12 秘密與 log**:`batman-provhelper qr` 的 stdout(含 `claim.secret`)不得進 syslog/flightrec/`logger`;§8 要有這一行與測試(`logread | grep -c <secret>` = 0)。
- **m13 p1 已經與 tree 不同步**:tree `distroconfig.txt` 有 `arm_boost=1`,04 `vcgencmd get_config arm_boost` = 0 → 04 的 p1 是較舊的 distroconfig;L19 的「重燒 p1」要用**哪一版**寫清楚(含 `uart_enable` typo 修正、`core_freq_min=500`、`ramoops-pi4`)。`core_freq_min=500` 讓 VPU 固定 500 MHz → 耗電上升,電池機要量(殘項即可)。
- **m14 矩陣補列**:非 fresh 開機 p5 掛不起時 helper 的行為(建議:沿用 overlay 狀態、`persist` 一律拒、`halow-status` 紅字)、helper 開機的 `--check` 與 joinwatch `--on-join` 的鎖競爭(`--check` 等 5 s → rc 8 → helper 怎麼辦)、OTA stage-2 ramfs 時 `/tmp/run/batman-prov` 不存在(provd K10 已停 ✅,寫明)。
- **m15 `health_ok` 怎麼讀 `hci0 Powered`**:autocommit 是 root shell;`bluez-daemon-min` 只裝 `bluetoothctl`(互動式,`bluetoothctl show | grep Powered` 可用但要 `--timeout`),或讀 `/sys/class/bluetooth/hci0`(存在 ≠ Powered)。寫明用哪一個與負對照(`bluetoothctl power off` 後必須 UNHEALTHY)。
- **m16 fresh overlay 上 `lock-status` 兩個寫者的順序**:96(S10,依 authorized_keys+pw 寫 `UNPROVISIONED`/`LOCKED`)→ `99zz`(S10 稍後,helper `--apply-state` 寫 `LOCKED` + `PasswordAuth=off`)。順序由 uci-defaults 檔名決定 ✅,但要寫進 §3(現在 §3 寫「fresh overlay:96」是不完整的)。

## 5. 作者特別點名的項目(逐一回答)

| 項目 | 結論 |
|---|---|
| keystore §4.2 vs 協定(608B 真的能 drop-in?) | **可以**,介面形狀對得上(`sn`/`CN=device_id`/`serialNumber`、ECDH 與 DAC 分開、`CheckMac(clientChal, clientResp)` + helper 持 SN/OtherData、`boot_id`/`nonce` helper 產)。缺:m1(helper 組訊息 + 限速)、m2(ClientChal 由 helper 重算)、m9(`device_id` 公式);`ClaimedCounter` 在 `file` 會隨恢復出廠歸零、608B 不會 — v2 已誠實寫 U4。 |
| helper 授權物件(攻陷的 provd 還能做什麼) | `factory_reset`/`net.apply`/`owner.auth` 的物件設計站得住;漏網:**M6 `keystore.ecdh`**、m3 `persist(promote_lkg)`、m1 `sign` 的訊息組成、m2 `client_chal`;owner auth 重放:nonce_helper 一次性 + 綁 verb/args_hash/h ✓;legacy 的 `qr` + `claim.verify`:**M9**。 |
| 單檔 `prov.cbor` + `identity/prov/` + generation 在 config-save | 單檔 rename 的原子性 ✓;**M1** 的 `.stage` 讀取是新缺陷;`onjoin_fp` 納入 ✓(但要指明用已提交的檔);`--seed` 不旋轉 lkg ✓;`--wipe-all` 刪 `.seeded` ✓(之後 `--save` 在 ext4 p5 上可用,`:163` 只擋非 ext4)。 |
| 交易式 `state.apply` 與「p5 是 SoT」 | 規則本身不會迴圈(generation 單調,重建後 overlay == p5);但 **M1** 讓「p5 較新」可以由未提交交易造成;**M3** 讓 marker 永久凍結。 |
| `legacy` + Q1 | Q1「升級後開機就產」可以接受,但 **M2** 的定義矛盾與 **B3** 的 autocommit 必須先修;trial 上產身分 → persist → revert 回 1.5.12:p5 多了 `identity/prov/` + `prov.cbor`,舊 96/config-save 不認識它們、也不會刪(`cp -a` 只加不刪)→ 無害 ✓。 |
| `expected_in_mesh` v2 / `meshjoin_radio_up` / `health_ok` + BLE | **B3**(太鬆)、**M5**(太緊)、**M4**(BT 壞 = 永遠不能 OTA);`meshjoin_radio_up` 的定義(wlh0 mesh point 且 mesh_id == uci)可用,04 實證 `iw dev wlh0 info` 有 `type mesh point`。 |
| 韌體打包 §4.6 | **B1**(serdev)、**M7**(套件依賴);`BT_BREDR=n` 下 `hci_bcm`/`btbcm` 可建(drivers/bluetooth 沒有任何 BREDR 參照;`CONFIG_BT_BREDR` 只出現在 `include/net/bluetooth/{bluetooth,hci_core}.h`)✓;dbus `bluetooth.conf` 不是 conffile(`bluez/Makefile:75-76` 只有 `main.conf`)→ 自己的套件直接裝自己的檔即可 ✓;`core_freq_min=500` 與 p1 重燒 ✓(但 m13 版本);`uart_enable=1` typo 實證存在(p1 與 tree 都有),`enable_uart=1` 是 firmware 因 overlay 自動設(04 `vcgencmd get_config enable_uart` = 1)✓。 |
| `99zz-` 排序 | `uci_apply_defaults` 用 busybox `ls`(ASCII)→ `99zz-…` 在 `99_morse_radio_defaults`、`99-halow-identity`、`99-batman-chanfix` 之後 ✓(`z` 0x7A > `_` 0x5F > `-` 0x2D);keyguard S18 在 S10 之後 ✓;但 **M8**(hook 不該 reload/persist)。 |
| 測試計畫 §9 | 負對照概念對;缺 B1/B2/B3/M1/M4/M5/M8/M9 各自的負對照(上面各條已給);「02 當 central 只驗 GATT 框架」合理,協定裁判用向量 + `verify.py` 對手 ✓;但 02–04 BLE 距離仍是 ⚠️(PR-F 量)。 |

## 6. v1 發現 → v2 收法核對

| v1 | 狀態 | 備註 |
|---|---|---|
| A-B1 / B-M1 autocommit | **部分** | `claimed` 分支對;`legacy` 分支反而拆閘(B3);單台在家(M5);BLE 健康無條件(M4) |
| A-B2 / B-B1 dropbear 無 ECDSA | 已收 | U3 脫鉤;但 legacy 的 lockout(M9) |
| A-B3 / B-M8 overlay vs p5 | **部分** | p5 = SoT 方向對;marker 一次性(M3)、五態矛盾(M2)、`.stage` 讀取(M1)、恢復出廠不清 overlay(B2) |
| B-B2 helper 授權 | **部分** | 主要動詞 ✓;`keystore.ecdh`(M6)、`persist`(m3)、`sign`(m1)、`client_chal`(m2) |
| B-B3 / A-M2 prov 複製語意 | 已收 | 單檔 + fp 納入;M1 是新的 |
| B-M3 legacy | **部分** | 狀態有了;定義矛盾(M2)、autocommit(B3)、lockout(M9) |
| A-M1 / B-M4 dbus | 已收 | 負測試可直接進 harness(busybox `start-stop-daemon -c nobody` 存在) |
| B-M5 / A-M6 kmod & BlueZ | **部分** | kmod 內容 ✓;serdev(B1)、套件依賴(M7) |
| B-M6 keystore | 已收(m1/m2/m9 微調) | |
| A-M3 開發 CA | 已收 | 自簽 + TOFU |
| A-M4 降級後果 | 已收 | L12 誠實 |
| B-M7 / A-M8 恢復出廠 | **開**(B2) | `--wipe-all` + p6 標記有了,但 overlay/p6 資料/身分產生/dropbear 解鎖都沒有 |
| B-M9 / A-m9 core clock | 已收 | 加 m13 版本問題 |
| B-M10 `--seed` lkg | 已收 | |
| B-M11 測試 | 已收(各條負對照待補) | |
| A-M5 mesh-solo | 已收 | `prov-state` + `meshjoin_radio_up` |
| A-M7 改名 | 開(U5,使用者探針) | 不計入 |
| v1 MINOR | 大多已收 | A-m2(96 驗 p5 檔)仍開 → m10;A-m13 冪等鍵 L8 ✓ |

## 7. 依 REVIEW.md 逐項

| 項目 | 狀態 |
|---|---|
| 1 擁有權 | 大致有;缺 `prov-state` 的 boot 綁定(m4)、`lock-status` 兩寫者順序(m16)、`CONFIG_SERIAL_DEV_CTRL_TTYPORT`/上游 kmod(B1/M7) |
| 2 契約 | `.stage` 契約矛盾(M1);marker 四態 vs 五態(M2);`invalidate-other`/`--mesh-off` 不存在(M10);`--ap-off` 的 firstboot 模式(M8) |
| 3 生命週期 | 缺 §1 表的列,最重要是「恢復出廠後同一 overlay 開機」(B2)、「fresh 開機 p5 暫時掛不起之後」(M3)、「單台在家更新」(M5) |
| 4 假設證據 | **D1 標 ✅ 但真機反證**(B1);D4 ⚠️ 仍待 PR-F;D12 ✓;D15 ⚠️ 使用者探針 |
| 5 安全 | actor 表完整;漏:攻陷 provd 經 `keystore.ecdh` 讀 SAE key(M6)、恢復出廠後 tenant 資料與前任狀態外流(B2,資產:tenant data)、legacy 的擁有權接管 + 操作員 lockout(M9)、provd crash loop = 管理面 DoS(m6)、QR 秘密進 log(m12) |

## 8. 給 v3 的順序

1. **B1 + M7**:PR-F 先做(`SERIAL_DEV_CTRL_TTYPORT=y`、deselect `kmod-bluetooth`、自己的 bluez 套件),在 04 上看到 `hci0` + serdev 裝置 + 只有三個 BT 模組,再回來核准其餘。
2. **B2**:恢復出廠重寫(資源清單、本槽 overlay 清法先探針、身分產生規則)。
3. **B3 + M5 + M4**:`expected_in_mesh`/`health_ok` 三條規則一起定(legacy 退回今天、member 看 radio + 近期 JOINED、BLE 只在 `ble-ok` 後要求)。
4. **M1 + M2 + M3**:`.stage` 只給 helper 的明示 persist;狀態只由 `prov.cbor.state`;helper 自己看 p5。
5. **M6、M8、M9、M10** 與 MINOR 併入。

**判定:REJECT**(BLOCKER ×3、MAJOR ×10、MINOR ×16;修完整份重審)。
