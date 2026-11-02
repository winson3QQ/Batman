# #254 第 17 輪審查 — 審查者 A — design v17(6feb29d)+ firmware `feat/254-ble` 全部(到 3ec5e9b5)

**Verdict:REJECT(窄)— 0 BLOCKER / 3 MAJOR / 4 MINOR**

v16 我列的 N1–N7 在 v17 的程式碼(3ec5e9b5)裡都成立,見 §0。

v17 自己新增或保留的契約裡有三個 MAJOR:
- **R1**:`sc_only_log` 拿 logread 當證據。04 的 logd 只有 128 KiB 環形緩衝,開機約一小時後那一行就會被擠掉;任何本機程序也能灌 log 把它擠掉 → provd 依 fail-closed 撤廣播 → BLE 管理面消失。
- **R2**:v17 給 provd 的 dbus 白名單擋掉了 `Device1.*`。provd 因此斷不了任何連線;再加上「連線即撤廣播」,一個路人連上不走,就能讓節點的 BLE 管理面一直無法使用。§8 的「10 s / 3 次即斷」也就做不到。
- **R3**:協調者問的空中測試:`ble-pair-sc-only-254` 照 Q8 的判定法(「02 是否存下 04 的 IRK」),**目標與負對照都會得到「沒存下」**,分辨不了。

範圍:
- v17 全文與 `git diff 792967a 6feb29d`(§13「v16 → v17」逐列);
- firmware `3ec5e9b5`;
- linux-6.6.138、BlueZ 5.72 原始碼;
- wsl.7 出貨 rootfs(我自己解開);
- 04 唯讀查詢。

wsl.8 的 build 我沒碰。

---

## 0. v16 發現在 v17 的查核

| v16 | v17 收法 | 判定 | 證據 |
|---|---|---|---|
| N1 SC-only 讀不到;上游只在 SC 關著時送 | patch 900 每次接管 adapter 都送 `SET_SECURE_CONN` 並記 log | ✅ 程式正確;⚠️ 證據走 log,見 R1 | `set_mode()` 無條件送出(`adapter.c:757-800`);LE-only 時 kernel 在 powered 下也直接改旗標(`mgmt.c:6906-6921`,`!HCI_BREDR_ENABLED` 分支);`supported_settings` 在 LE 時一定有 SECURE_CONN(`mgmt.c:836-838`),所以 patch 的條件永遠成立;失敗會由 `set_mode_complete` 記「Failed to set mode」(`adapter.c:723-725`) |
| N2 互動 bluetoothctl 打開 bondable | health 轉壞 ≤ 10 s 撤廣播;runbook | ✅ | |
| N3 `-r` 不寫回 | L21 已改 | ✅ | |
| N4 閘門邊界 | `grep -a`、沒有 busybox 就 FAIL | ✅ | 我實跑:3ec5e9b 的閘門在 wsl.7 rootfs 上 OK;放一個含 `vcgencmd bootloader_config` 的二進位檔 → FAIL `direct bootloader_config readers outside the allow list: ./usr/bin/evilbin`;rootfs 內 `grep -rla` 只命中兩個允許的檔案(沒有誤報) |
| N5 空的 keys 目錄、wsl.5 列 | 0012 不再裝;L20 補上 | ✅(wsl.8 rootfs 待 build 完成後確認) | |
| N6 儲存區擁有權 | init `store_ok()`,不符就不啟動 | ✅ | 靜態讀過:`readlink -f /var`、`[ -O ]`、`_mode` 擋 group/other 寫、STORE 只刪 root 的 symlink、0700;規則與 `rundir.sh` 相同。`start_service` 回 1 就不建 instance。procd respawn 不會重跑 `store_ok`,但 respawn 前驗過的目錄只有 root 改得動 → 可接受 |
| N7 GATT 不帶加密旗標 | §8 provd 契約 + PR-P2 斷言 | ✅ | |

---

## 1. 發現

### R1(MAJOR)`sc_only_log` 用 logread 當證據:會被輪替掉,也會被灌掉;這是 fail-closed 條件,結果就是 BLE 管理面消失

**情境。** provd 只在 health 檔的 `privacy=1 sc=1 sc_only_log=1 bondable=0` 時廣播,health 轉壞就在 10 s 內撤掉(§8)。`sc_only_log` 依 D27 =「本次開機 log 有 `Batman: SecureConnections mode 2 requested`,且其後沒有 `Failed to set mode`」。helper 每 15 s 重算 health(§2、§3 health 列)。

**證據(04 唯讀)。**
- `logd -S 128`(128 KiB 環形緩衝);
- 開機約 60 分鐘時,`logread` 已經 138197 B / 1127 行,最舊一行是開機後 12.5 s 的 kernel 訊息,也就是前 12 s 已經被擠掉;
- bluetoothd 每行 log 寫兩次(stderr 與 syslog,v15 時 04 實讀)。

**後果。**
- bluetoothd 在 S61 啟動時記的那一行,一般負載下約一小時內就會從 logread 消失 → helper 重算後 `sc_only_log=0` → provd 撤廣播 → 節點沒有 BLE 管理面,直到 bluetoothd 重啟或重開機。
- 任何本機非 root 程序都能用 `logger` 灌滿緩衝,讓這件事立刻發生(D27 只考慮了「偽造」,沒考慮「擠掉」)。
- 另外,「其後沒有 `Failed to set mode`」分不出是哪個 mode 失敗:SET_BONDABLE 等其他 mode 失敗也會讓它變 0。結果偏向 fail-closed,但同樣會造成誤撤。

**修法。** 不要用 log 當契約。patch 900 在 SET_SECURE_CONN 的**完成回呼**(拿到 status 的那一刻)寫一個檔到 bluetoothd 自己的 0700 儲存區,例如 `/var/lib/bluetooth/batman-sc`,內容 `<boot_id> <bluetoothd_pid> <mode> <status>`:
- 寫者只有 bluetoothd,儲存區本來就由它擁有;
- 非 root 改不了,也不會被輪替;
- helper 讀檔,要求 `boot_id` 是本次、`pid` 是現在的 bluetoothd、`mode=2 status=0`;
- log 那一行留著當 witness 和人看的紀錄。

測試:
- 白箱:`kill -9` bluetoothd → respawn 後檔案的 pid 跟著更新;
- 灌 log 到緩衝滿 → health 不變;
- 負對照:現行 D27 的 log 契約在灌 log 之後會變成 0。

### R2(MAJOR)provd 的 dbus 白名單擋掉 `Device1.*` → provd 斷不了連線;加上「連線即撤廣播」,一個路人連著不走就能讓 BLE 管理面一直無法使用

- **v17 寫的**:§4.6 provd 只放行 `LEAdvertisingManager1.{Register,Unregister}Advertisement`、`GattManager1.{Register,Unregister}Application`、`ObjectManager.GetManagedObjects`、`Properties.{Get,GetAll}`,並且**明確 deny `Device1.*`**。
- **但 §4.8 與 §8 要求**:「同時連線 ≤ 2;未交握 10 s;失敗 3 次 / 連線」即斷(`prov-sec-hog-254`)。
- **BlueZ 上斷開周邊連線只有一條路**:`Device1.Disconnect`(`device.c:3167`)。GATT server 端關掉 AcquireWrite/AcquireNotify 的 fd 不會斷 LE link;kernel 也沒有閒置斷線。
- v17 又加了「連線建立即撤廣播,斷線後才重新註冊」(B-m2)。結果:一個路人連上之後什麼都不送,節點就不再廣播;provd 也踢不掉它 → 其他人連不上,直到對方自己離開。這比 v16 更糟。
- **修法**:
  - 白名單加上 `Device1.Disconnect`(只有這個方法)。`Pair`、`CancelPairing`、`Connect`、`ConnectProfile`、`DisconnectProfile` 仍然 deny;Disconnect 不能用來繞過 B1。
  - `prov-sec-dbus-254` 加正向案例:以 provd uid 呼叫 `Device1.Disconnect` 成功;`Device1.Pair` 回 AccessDenied。
  - `prov-sec-hog-254` 的判定改成「hog 連線 10 s 內被斷,廣播在斷線後回來」。

### R3(MAJOR)Q8 的 `ble-pair-sc-only-254` 判定法分辨不了目標與負對照

**Q8 的寫法。** 02 以 runtime `mgmt.sc off` 當 legacy initiator,「判定看 02 是否存下 04 的 `IdentityResolvingKey`」,負對照 04 = wsl.5。

**兩種情況都會得到「沒存下」。**
- **02 要求綁定時**:BlueZ 的 `Device1.Pair` 走 MGMT_PAIR_DEVICE,02 只要 bondable 就帶 BONDING 位元(`smp.c:658-663`)。而 02 只要有 agent 註冊(互動式 bluetoothctl;配對本來就需要 agent),BlueZ 就會在 `AlwaysPairable=false` 下把 bondable 打開(`adapter.c:9089-9090`)。04 不 bondable → 對帶 BONDING 的請求回 Pairing Not Supported(`smp.c:1756-1758`)。**wsl.8 和 wsl.5 都一樣被拒** → 兩邊都沒有 IRK。
- **02 設成不綁定時**:wsl.5 會照 B1 交出 IRK,但 kernel 只在雙方都帶 BONDING 時把 IRK 標成 persistent(`smp.c:1045-1054`),02 的 BlueZ 在 `new_irk_callback` 遇到 `if (!persistent) return;`,在 `store_irk` 之前就回了(`adapter.c:8980-8982`)→ **攻擊成功也不會存檔**。

所以「存下 IRK」這個判定在負對照上永遠不會成立,這個測試證明不了任何事。

**修法(判定與控制都要改)。**
1. **02 的前置條件**(並把實際狀態印出來):agent 用 NoInputNoOutput;配對前 `mgmt.bondable off`(要在 agent 註冊**之後**下)、`mgmt.sc off`;`mgmt.info` 確認沒有 `bondable`、沒有 `secure-conn`。
2. **判定**看「IRK 是否被分發」,而不是是否存檔:
   - 首選:02 上的 Device1 位址在配對後變成 04 的身分位址 `88:A2:9E:B5:6C:8B`。`new_irk_callback` 在檢查 persistent **之前**就呼叫 `device_update_addr()`(`adapter.c:8976`),所以不綁定也看得到。
   - 或者:用 btmon / mgmt 事件看到 `New IRK` / SMP `Identity Information`。
   - 目標判 PASS:配對失敗、原因 Authentication Requirements(0x03,`smp.c:1760-1761`)、位址沒變。
3. **負對照改成「只改一個變因」的翻轉測試**,不必把 04 OTA 回 wsl.5(那樣會在 overlay 留下持久 IRK,B-m7):
   - 同一個 wsl.8 上,`bluetoothctl mgmt.sc on`(SC 開但不是 only)→ 同一套 02 步驟應該**看得到**位址變成 public;
   - 接著 `/etc/init.d/bluetoothd restart` → patch 900 改回 only → 再跑一次 → 被拒。這一步同時驗證了 v17 的 L22。

### R4(MINOR)空中測試的廣播者、順序與殘留

- **04 需要一個沒有 agent 的可連線廣播者**,PR-F 沒有。Q8 只寫「04 測試廣播」。如果用互動式 bluetoothctl 的 `advertise on`,04 會註冊 agent → bondable 打開、SC Just Works 的確認改走那個 agent,受測條件就不一樣了。非互動的 `bluetoothctl advertise on` 結束後,廣播會隨 client 一起消失。
  - 建議:用靜態編譯的 `btmgmt add-adv -c`(kernel instance,和 provd 將來的 instance 路徑相同),或一支不註冊 agent 的小型 D-Bus 廣播程式。測前測後都印 04 的 `mgmt.info`,斷言沒有 `bondable`。
- **RPA 被動掃描要排在配對測試之前**,或兩台都重開之後再做。配對時 kernel 會把對方的 IRK 加進解析表(non-persistent 也會加),之後 02 會把 04 的 RPA 解析成 public 位址,掃描結果就不能用了。
- **RPA 測試分兩段**:
  - 不重新註冊 → 30 分鐘內同一個 RPA(F28 對照);
  - 每 900 s + 抖動重新註冊 → ≥ 2 個 RPA,且都不是 `88:A2:9E:B5:6C:8B`。

  掃描時開 `duplicate-data on`、記原始位址與時間戳;期間不准連線。
- 02 OTA 到 PR-F 後,02 自己也會開 BLE。02 本身沒有廣播者;測完之後 02 要回到 1.5.12-wsl.2 還是保留,要寫進收尾。

### R5(MINOR)反方向的 dbus 規則沒寫

- 註冊廣播與 GATT 之後,是 bluetoothd(root)主動呼叫 provd 的物件:`LEAdvertisement1.Release`、`GattCharacteristic1.ReadValue/WriteValue/StartNotify`、`Properties.GetAll`、`ObjectManager.GetManagedObjects`。
- 這些 send 是用 root 的政策評估。v17 只寫 root「own/send org.bluez + 6 個 send_interface」,沒說是否涵蓋送往 provd 的 unique name。spike 的 GATT server 是以 root 身分跑的,沒有驗過這條路。
- 修法:§4.6 列出 root → provd 方向需要的 send 規則(只限 provd 的 unique name / interface)。`prov-sec-dbus-254` 的正向案例:非 root 的 provd 讀寫一個 GATT 特徵成功。

### R6(MINOR)Q8 的「GATT 回歸」只測得到 bluetoothd 內建的服務

- PR-F 沒有 GATT app。02 連上 04 只讀得到 GAP / GATT / DIS,測不到 provd 的特徵,也測不到 N7(加密旗標)。
- 寫明這只是 smoke test;真正的回歸放在 PR-P2。

### R7(MINOR)D27 的第三點應寫成 R1 修法後的檔案契約

- 「其後沒有 `Failed to set mode`」分不出是哪個 mode,R1 已說明。修法後 D27 變成:
  - `batman-sc` 檔:本次 `boot_id`、當前 bluetoothd 的 pid、`mode=2 status=0`;
  - 加上 `secure-conn` 位元;
  - 加上 tier B 實證。

---

## 2. 我實際跑過或讀過的東西

- **閘門(3ec5e9b 版)對 wsl.7 rootfs**(`/home/yello/out/1.5.12-wsl.7*`,由我自己解開,用完即刪):
  - `check-pvs-shim: OK (… 11 keys READ rc 1 silent under: sh busybox_ash; … direct readers only: ./etc/uci-defaults/95-batman-storage ./sbin/persistent_vars_storage.sh)`;
  - 放入含字串的二進位檔 → FAIL rc=1;
  - `grep -rla bootloader_config` 只命中兩個允許的檔案。
- **原始碼行號**(build 樹):
  - kernel `smp.c:658-663,1045-1054,1756-1761`;`mgmt.c:836-838,6906-6921`;
  - BlueZ `adapter.c:723-725,757-800,8976-8982,9089-9090,10299-10313`(patch 後);`device.c:3167-3173`。
- **04 唯讀**:`ps`:`/sbin/logd -S 128`、`ubusd` 以 `ubus` 使用者執行;`logread | wc -c` = 138197、`wc -l` = 1127,最舊一行是開機 12.5 s 的 kernel 訊息。

沒有在 04/02 上做任何變更,也沒跑 bluetoothctl。

## 3. 沒做或做不到的

- ❌ wsl.8 rootfs:build 還在跑。0012 不再裝 keys 目錄、0013 的 witness 字串要在 wsl.8 出來後確認。
- ❌ 沒有親手在 busybox 下跑 `store_ok()` 的負案例(作者說跑過 4 個)。我做了靜態審查,認為邏輯正確。
- ❌ 空中:D24、D25 照 R3 / R4 的修法後才有判定力。
