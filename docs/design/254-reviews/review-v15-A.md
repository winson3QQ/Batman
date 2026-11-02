# #254 PR-F(firmware)審查 — 審查者 A — design v15(99afc99)+ firmware `feat/254-ble` 5ec36f40 / 625a6161

**Verdict:REJECT(窄)— 0 BLOCKER / 3 MAJOR / 6 MINOR**

PR-F 的兩個程式改動本身是對的:shim 和 bluez 0013 patch 我都重跑或讀過原始碼,沒找到要改的程式錯誤。我 REJECT 的是 v15 設計裡三件沒寫對的事:
- 一個安全主張(D24「RPA 每 900 s 換一次」);
- 一個沒辦法照寫實作的契約(provd「只經 D-Bus 讀 privacy」);
- IRK 這個新的秘密資源少了生命週期列,§3 的說法也和原始碼不符。

三項都要改進 v16、整份再審一次。M1 和 M2 不需要改 PR-F 的程式碼,M3 可能要在 PR-F 的 init 補一段驗證,也許還要拿掉 conffiles。

審查範圍:v15 全文(重點是 F16–F26、§3、§4.5、§4.6、§5、§7、§8、§9、§10、§12)、`git diff 059375a 99afc99`、兩個 commit、BlueZ 5.72 與 linux-6.6.138 build 樹原始碼、wsl.3/.4/.5 三份出貨 payload 的 rootfs(我在 WSL 自己解開),以及 04 的唯讀查詢。

---

## 0. 作者四項主張的查核

| # | 主張 | 結果 | 證據 |
|---|---|---|---|
| 1a | privacy 沒開,是因為產生 IRK 需要 AF_ALG | ✅ | `bluez-5.72/src/adapter.c` 原本走 `bt_crypto_new()`;wsl.3、wsl.4 的 `usr/bin/bluetoothd` 都沒有 `Generated IRK (getrandom)` 字串(0 次),wsl.5 有 1 次;三份 rootfs 都沒有 `af_alg*`/`algif*` 模組(find = 0);kernel `.config`:`CONFIG_CRYPTO_USER_API=m` 等 |
| 1b | 讀既有 IRK 不需要 crypto | ✅ | `load_irk()` 只做 `g_key_file_get_string` + `str2buf`(adapter.c,patch 後約 :4190–4225) |
| 1c | 我們用到的東西沒有別的需要 `bt_crypto` | ⚠️ 不完整 | 見 m1:漏了 `gatt-db.c:255`(GATT Database Hash)、`att.c:1268`、`set.c:269,305`、`csip.c:335` |
| 1d | 有 IRK + `Privacy=device` 時,kernel 以 RPA 廣播,並每 900 s 輪替 | ❌(原始碼反證輪替;RPA 本身 ✅) | 見 M1 |
| 2a | 不開 AF_ALG 是對的 | ✅ 同意 | `getrandom` 和上游 `bt_crypto_random_bytes`(`crypto.c:191-201`,讀 `/dev/urandom`)出自同一個 CRNG,熵品質相同;不必為 16 B 開一個本機 kernel crypto 介面 |
| 2b | `getrandom(…,0)` 不會卡住 | ✅ | 04 `dmesg`:`[    0.000000] random: crng init done`;kernel 有 `CONFIG_HW_RANDOM_IPROC_RNG200=y`;6.6 kernel 另有 jitter 保底;回傳值 `!= 16` 一律當失敗 |
| 2c | PR-F 在 bluez 層 fail-open、由 PR-P2 的 provd 斷言補救,可接受嗎 | ✅ 對 PR-F 可接受,⚠️ 但斷言的寫法不能實作 | PR-F 沒有任何廣播者:04 `ps` 只有 bluetoothd,provd 在 PR-P2 才有;bluetoothd 不註冊廣播就不廣播(原始碼推論 ⚠️,空中未驗)。PR-P2 斷言的契約見 M2 |
| 3a | shim 不會弄壞 F21 的 9 個讀者 | ✅ | 我在 wsl.4 rootfs 逐一讀過,見 §2 |
| 3b | 閘門真的有鑑別力 | ✅(有覆蓋缺口,見 m3) | 我重跑的結果見 §2 |
| 4 | IRK 檔的擁有權與生命週期 | ⚠️ 不完整、部分不符 | 見 M3 |

---

## 1. 發現

### M1(MAJOR)RPA 不會每 900 s 自動換:對 D-Bus 註冊的廣播 instance,kernel 只在廣播重新啟用時才換位址

**情境。** 現場節點被帶著走一整天,沒有手機連它。provd 開機時註冊一個廣播 instance(沒有 timeout),之後一直廣播。BLE 路人在不同地點掃到的會是**同一個 RPA**,直到下一次連線/斷線、provd 重新註冊、bluetoothd 重啟或重開機才會換。§8 用 RPA 防「追蹤」,D24 寫「每 `rpa_timeout` 換一次」,這兩句在這個情境都不成立。

**證據(linux-6.6.138 build 樹)。**
- `net/bluetooth/mgmt.c:1016-1029` `rpa_expired()`:設 `HCI_RPA_EXPIRED` 之後,`if (!hci_dev_test_flag(hdev, HCI_ADVERTISING)) return;`。`HCI_ADVERTISING` 只由 mgmt `Set Advertising` 設(`mgmt.c:6353`;`hci_sync.c:2645` 是 resume 時還原)。BlueZ 的 `LEAdvertisingManager1` 走 `MGMT_OP_ADD_ADVERTISING` / `MGMT_OP_ADD_EXT_ADV_PARAMS`(`bluez-5.72/src/advertising.c:944,1007`),不會設這個 flag,所以計時器到了也不會重新產生位址。
- 每個 instance 的計時器 `adv_instance_rpa_expired()`(`hci_core.c:1673-1681`)只做 `adv_instance->rpa_expired = true;`,不送任何 HCI 指令。
- legacy 廣播的輪替排程 `hci_schedule_adv_instance_sync()`(`hci_sync.c:2050-2056`):只有一個 instance 時,`!force && cur_adv_instance == instance && HCI_LE_ADV` 就 `return 0`,同樣不送 HCI 指令。
- 新的 RPA 只在 `hci_start_ext_adv_sync` / `hci_enable_advertising_sync` 重新設定廣播時產生(`hci_get_random_address` 看 `rpa_expired`)。
- ⚠️ 以上是原始碼推論,沒有空中實測。

**Q8 的測法也會假 PASS。**
- (b)「iPad nRF Connect 看位址」:iOS 只給 peripheral identifier,不給 MAC。只要一按連線,斷線後廣播重新啟用,RPA 就換了,看起來會像「有輪替」。
- 15 分鐘短於一個 900 s 週期加上餘裕。
- PR-F 沒有廣播者,Q8 用哪個程式廣播沒寫。如果用 `bluetoothctl advertise`,它會註冊 agent(F16,Pairable 變 yes)。文中的「`Batman-04`」名稱也和 §4.8「adv 不帶 Local Name」矛盾。

**修法。**
1. D24 改成「kernel 只在廣播重新啟用時換 RPA」。provd(PR-P2)每 ≤ `rpa_timeout` 加隨機抖動,撤掉再重新註冊廣播(或用 instance `Timeout` 讓 kernel 重排);寫進 §4.8 契約與 §6 流程。
2. Q8 / tier B 的測法:被動掃描 ≥ 2×900 s、期間**不准連線**;廣播者用和 provd 相同的 instance 參數(無 Local Name、無 timeout),不能用 bluetoothctl。
3. 負對照:不做重新註冊時,30 分鐘內看到同一個 RPA(這同時就驗證了本項);做了之後看到 ≥ 2 個不同的 RPA,而且都不是 `88:A2:9E:B5:6C:8B`。

### M2(MAJOR)「provd 只經 D-Bus 讀 privacy 狀態」做不到;§9 的 `ble-privacy-254` 又用 bluetoothctl

**情境。** v15 的 fail-secure 補救是「provd 開機斷言 privacy 在 current settings,沒有就不註冊廣播」(§8)。但 BlueZ 5.72 的 `Adapter1` 沒有任何 privacy 屬性:`adapter.c:3914-3937` 屬性表只有 Address、AddressType、Name、Alias、Class、Powered、PowerState、Discoverable、DiscoverableTimeout、Pairable、PairableTimeout、Discovering、UUIDs、Modalias、Roles、ExperimentalFeatures、Manufacturer、Version。`AddressType` 讀的是 `adapter->bdaddr_type`(`:2915-2930`),privacy 開著時仍回 `public`。照文件實作,provd 讀不到這個值,只會:
- 永遠 FAIL,節點因此沒有 BLE 管理面,trial 的 health 會讓好 image revert;或
- 被寫成「讀不到就放行」,也就是 fail-open。

**另外。**
- §9 `ble-privacy-254` 和 v15 的實測都用 `bluetoothctl mgmt.info`。F16 已實證 bluetoothctl 會註冊 agent、跑著的時候 Pairable 變 yes。§9 自己也寫「harness 不用 bluetoothctl」「節點端 BLE 斷言走 helper 的 health 檔」,這裡互相矛盾。
- 可行的讀法:mgmt `READ_INFO` 在 untrusted 指令清單內(`mgmt.c:185-196`),不需要 `CAP_NET_ADMIN`;但要開 `AF_BLUETOOTH` socket,這會改到 provd 的 ujail/seccomp 攻擊面。

**修法。**
1. 定一個擁有者:由 helper(root)每 15 s 以 mgmt `READ_INFO` 讀 current settings,在 health 檔加 `privacy=0|1`;provd 讀 health,或經 helper socket 取得。
2. 契約寫明:欄位缺 / 過期(uptime 超過 2 個週期)/ 格式壞 → 視為 0 → 不廣播(fail-closed)。
3. `ble-privacy-254` 改讀 health 檔。負對照用「wsl.4 + 全新 overlay」(注意 m2)。

### M3(MAJOR)IRK 是新加的秘密,卻沒有生命週期列;§3「`sysupgrade -n` / 重燒卡 = 新 IRK」與原始碼不符

逐條路徑(依原始碼與 04 唯讀實測):

| 路徑 | 實際行為 | 證據 |
|---|---|---|
| 首次開機 | 產生 IRK,檔案 0600 | bluetoothd `umask(0077)`(`src/main.c:1383`);04 `/proc/<bluetoothd>/status` `Umask: 0077`;`create_file(…, S_IRUSR\|S_IWUSR)` |
| 首次寫入時斷電 | 第一次寫**沒有 fsync**:`create_file()` 先建空檔,`g_file_set_contents` 帶 `ONLY_EXISTING`,目標是空檔就跳過 fsync。斷電後可能留空檔 → 下次「No IRK stored」→ 重新產生(無害) | glib-2.82.0 `gfileutils.c:1105-1114,1248-1256`;04 overlay = f2fs `fsync_mode=posix` |
| identity 格式壞(人為、或寫壞) | `Invalid IRK format, disabling privacy`,**永久關閉 privacy**,上游不重建(`/* TODO re-create */`)。配上 PR-P2 的 fail-closed → 這個槽永久沒有 BLE 管理面,沒有修復擁有者 | `load_irk()` |
| bluetoothd crash / respawn | 介面通常仍 powered → `set_privacy` 被 kernel 拒(`mgmt.c:7024-7026`,powered 時 REJECTED);kernel 的 `HCI_PRIVACY` + 舊 IRK 沿用上一個 instance → 仍然有 privacy。換 IRK 要等 power cycle | |
| 每一次 OTA(不論有沒有 `-n`) | A/B 的 `platform_copy_config() { :; }`(Batman `feed/batman-provision/files/usr/lib/batman/platform-ab.sh:352`),新槽是全新 overlay → **每次 OTA 都是新 IRK**。96 不從 p5 還原它(Batman main 沒有任何 bluetooth 字樣) | |
| rollback | 回到舊槽 overlay 裡的那把 IRK;wsl.4 槽沒有 IRK,privacy 關,但 PR-F 沒有廣播者 | |
| 清 overlay(L60 `firstboot` / LuCI reset) | 新 IRK;96 不還原 | |
| `sysupgrade -b` / LuCI「備份」 | **IRK 進備份檔**:`/lib/upgrade/keep.d/bluez-daemon` = `/etc/bluetooth/keys`(04 實讀;來源是 0012 保留的 conffiles) | |
| `sysupgrade -r` / LuCI「還原」 | 把舊 IRK 寫回 = 第三個寫者;要等 power cycle 才生效 | |
| 轉賣重燒 | 新 IRK ✅;public 位址(晶片固定)不變,但不上空中 | |
| downgrade 到 ≤ wsl.4 / 1.5.12 | privacy 關或沒有 BLE;沒有廣播者 → 無暴露 | |
| bcm2710 | 0013 只在 `patches/ekh-bcm2711/`(見 m4) | |

**修法。**
1. §3 IRK 列改成「每個槽的 overlay 一把;OTA、清 overlay、重燒都換新;rollback 回舊槽那把」。
2. §5 加上表中的 IRK 列。
3. 修復擁有者:放在 bluetoothd 的 init `start_service`(同一個元件,不新增寫者)。啟動前驗 `identity` 的 `IdentityResolvingKey` 是 32 個十六進位字元,不是就改名成 `identity.bad.<ts>`、記 log;接著要 power cycle(`bluetoothd` 啟動前介面本來就是 off)。測試:白箱寫壞 identity → 重啟 → privacy 回來;負對照:沒有這段 → privacy 永久關。
4. 決定 IRK 要不要進 LuCI 備份。建議 0012 把 `/etc/bluetooth/keys` 從 conffiles 拿掉:IRK 沒有保留價值(不配對、沒有 bond),留著只會讓它離開節點。測試:`sysupgrade -l` 不列出它。

### m1(MINOR)F26「其他 `bt_crypto` 呼叫者我們都不用」不完整

- 漏列 `src/shared/gatt-db.c:255`:每個 `gatt_db_new()` 都開 crypto。失敗時 `gatt_db_hash_support()` 回 false(`:649-655`),`gatt-database.c:1271` 就**不提供 GATT Database Hash 特徵**,也就沒有 Robust Caching。
- 也漏列 `att.c:1268`(signed write,沒用到)、`set.c:269,305`、`profiles/audio/csip.c:335`(CSIP,沒用到)。
- 後果:client 只能靠 Service Changed,而未配對的連線沒有持久的 CCC。加上 M1(位址長時間不變),⚠️ iOS 可能在 OTA 改了 provd 的 GATT 佈局後沿用舊快取。
- 修法:F26 補列;協定 / app 二選一:GATT 佈局永不改 handle,或在 `status/public` 帶佈局版本、版本不符就重新探索。⚠️ 需要 iOS 實測。

### m2(MINOR)04 上的原型 IRK 會污染 `ble-privacy-254` 的負對照

- 04 的 wsl.4 overlay 現在有作者預寫的 `/etc/bluetooth/keys/88:A2:9E:B5:6C:8B/identity`(64 B,0600,Jul 15 20:52),所以 wsl.4 目前會顯示 privacy,負對照會 PASS 而不是 FAIL。
- rollback 回這個槽也會誤導。
- 修法:
  1. 在 #254 記錄這個原型檔;
  2. 驗證前先列出、再移除(使用者的規則);
  3. 負對照一律用全新 overlay;
  4. 正向斷言加上「這個 overlay 第一次開機的 log 有 `Generated IRK (getrandom)`」,證明 IRK 是 bluetoothd 自己產生的,不是外來檔案。

### m3(MINOR)`check-pvs-shim.sh` 的覆蓋缺口

1. 只測 `default_wifi_key`、`dropbear_authorized_keys` 兩個 key。讀者實際讀 11 個:9 個 `all_keys` 加上 `mm_sku`、`mm_region_unlocked`。建議 stub 給全部 11 個值,逐一測。
2. 只看 `/sbin`。OpenWrt 的 PATH 是 `/usr/sbin:/usr/bin:/sbin:/bin`,讀者用裸名呼叫(例如 `morse.sh:136`)。只要 `/usr/sbin` 或 `/usr/bin` 有一份同名檔就會蓋掉 shim。今天沒有(我在 wsl.4/.5 rootfs `find -name 'persistent_vars*'` 只有 `/sbin` 一份),但閘門不會擋未來的情況。建議 rootfs 內除了 `/sbin` 那份之外有任何同名檔 → FAIL。
3. 沒擋「直接呼叫 `vcgencmd bootloader_config` 的新讀者」。今天只有 `95-batman-storage:418`(只取 `BOOT_ORDER|PARTITION_WALK`)。建議加 allowlist。
4. 用主機的 dash 跑,不是目標的 busybox ash。行為差異很小,但要在註解寫明。

### m4(MINOR)bcm2710 的影響沒寫

- `files/` 是整棵樹共用,shim 會進 3A+ 的 image。`boards/ekh-bcm2710/` 沒有 persistent-vars 套件,原本讀者呼叫時「command not found」、stdout 空;換成 shim 後是 rc 1、stdout 空,讀者行為相同。
- 0012 / 0013 只在 `patches/ekh-bcm2711/`,3A+ 加 BLE 時要一起帶上,否則又回到 F26。
- 修法:L13 寫這兩點。

### m5(MINOR)誠實界線:BLE 路人的追蹤防護不只看 RPA

- 節點同時廣播其他穩定識別:
  - 2.4 GHz AP 的 BSSID/SSID(依 MAC 產生;legacy 節點 AP 開著);
  - HaLow mesh beacon;
  - `legacy|unclaimed` 的 `device_id` 末 4 字元。未交握就能讀,是穩定的 16 bit 標記。
- 末 4 字元放在哪裡,文件前後不一:§1.3 寫「adv 帶末 4 字元」,§4.8 寫在 `status/public`。
- 修法:§8 寫明「RPA 只在其他無線電不帶穩定識別時有意義」;統一末 4 字元的位置;legacy 節點要不要帶由使用者決定(建議只在使用者觸發的認領窗口內帶)。

### m6(MINOR)PR-F 驗證步驟要明寫「沒有廣播者」

- §10 第 1 點列了「空中 RPA(⚠️)」,但 PR-F image 沒有廣播者,沒有東西可以量。
- 修法:
  - PR-F 驗收改成「privacy 在 current settings」(經 M2 的讀法)加上 identity 由 bluetoothd 產生(m2);
  - 空中輪替移到 PR-P2,用 provd 本身測(M1);
  - 寫明 PR-F 的 fail-open 之所以可接受,是因為沒有廣播者;
  - 「沒有廣播者」本身要有證據:目前只是原始碼推論 ⚠️。

---

## 2. 我實際跑過或讀過的東西

**閘門與 shim**(WSL;三份出貨 payload 由我自己 `unsquashfs4` 解出):

```
### 1.5.12-wsl.3+f2f2bf6.fw8b33f3e
check-pvs-shim: FAIL: rootfs shim sha256 570310c6…94bb != files/ c1446ce4…cd83 (Morse original or stale build)
gate rc=1
### 1.5.12-wsl.4+f2f2bf6.fw5ec36f4
check-pvs-shim: OK (sha256 c1446ce4…cd83; READ rc 1 silent; READALL empty; WRITE refused)   gate rc=0
### 1.5.12-wsl.5+f2f2bf6.fw625a616
check-pvs-shim: OK (…)  gate rc=0;  getrandom witness: 1(wsl.3/.4 = 0)
### negative: missing rootfs → FAIL rc=1
### negative: 把 Morse 原版放進假 rootfs 的 /sbin → FAIL(sha)rc=1
原版 + stub vcgencmd(mm_region=EU):READ rc=0 out=[EU];shim:rc=1 out=[]
空 EEPROM:原版(dash)READ rc=1 out=[] err=[];shim READ rc=1 out=[] err=["The key … doesn't exist …"]
READALL:兩者都輸出 9 個 `key=`、rc 0
```

wsl.5 的 build log 同樣有 `check-pvs-shim: OK` 與 `patch-witness: all 9 patch(es) … witnessed`。

**9 個讀者逐一檢查**(wsl.4 rootfs):
- 都只看 stdout 是否為空,或是否等於 `"1\n"`;沒有人看 rc,也沒有人把 stderr 併進值裡:
  - `31_password:14`、`31_dropbear_persistent_storage:12`、`morse-wireless-defaults:19,24` 用 `-n`;
  - `luci-i18n…:7`、`morse.sh:136,471-472`、`diag_override.sh:18`、`morse-mode:223` 都有 `2>/dev/null`;
  - LuCI 的 `process.exec(…, true)` 沒要 stderr,接到 `/dev/null`(`luci/sys.lua:425-437`)。
- 沒有讀者用 `READALL`。唯一的寫者是 `save_dropbear_setup.sh`,原版在 bcm2711 也回 rc 1。
- shim 比原版多寫一行 stderr,只出現在首次開機的 uci-defaults 輸出。無害。

**04 唯讀查詢**(沒有改任何東西):
- 版本:`BATMAN_VERSION=1.5.12-wsl.4+f2f2bf6.fw5ec36f4`;
- `/var/lib/bluetooth -> /etc/bluetooth/keys/`;keys 目錄、位址目錄都是 0700;`identity` 0600、64 B(作者的原型檔);
- bluetoothd `Umask: 0077`;`random: crng init done` 出現在 0.000000;
- overlay = f2fs;`/lib/upgrade/keep.d/bluez-daemon` = `/etc/bluetooth/keys`;
- OTS 容器以 uid 1000 執行,沒有掛到 `/etc/bluetooth`。

我沒有在 04 上跑 bluetoothctl:它會註冊 agent,讓 Pairable 變 yes(F16)。

## 3. 沒做或做不到的

- ❌ 空中 RPA 與輪替(沒有第二台 central)。M1 是原始碼推論,要靠 M1 修法第 3 點的負對照實證。
- ❌ 確認 BCM4345C0 是否 `ext_adv_capable`。兩條路徑(legacy、ext)我都讀了,結論相同。
- ⚠️ 「bluetoothd 沒有廣播者就不廣播」:原始碼推論,空中未驗。
- ⚠️ glib 0600 / fsync 的行為:原始碼推論。WSL 沒有 glib-dev,沒編測試程式;但 04 上 `settings` 檔 0600 與 umask 0077 一致。
- ❌ iOS 在沒有 Database Hash 時的 GATT 快取行為(m1)。

## 4. 審查規則對照

- **擁有權**:IRK 內容的唯一寫者是 bluetoothd,目錄權限由 init 管;漏列 `sysupgrade -r`(M3)。
- **契約**:privacy 狀態的讀法不能實作(M2)。
- **生命週期**:IRK 列缺(M3)。
- **證據**:D24 被原始碼反證(M1),F26 不完整(m1)。
- **安全**:AF_ALG 的決定與 `getrandom` ✅;追蹤面的誠實界線(m5);IRK 經備份外流(M3-4)。
- **負對照**:shim 閘門 ✅;IRK 的負對照被原型檔污染(m2)。
