# #254 PR-F 審查 第 16 輪 — 審查者 B — 設計 v16(792967a)+ firmware `feat/254-ble`(e8e69c99、5fa809b1)

**判定:REJECT(窄)** — 0 BLOCKER / 2 MAJOR / 7 MINOR。

PR-F 的 firmware 程式碼沒有 MAJOR。兩個 MAJOR 都是設計的契約寫錯:
- **N1** 寫了一個 kernel 讀不出來的狀態(`sc-only`),而 PR-F 的驗證清單與 provd 的 fail-closed 條件都依賴它。
- **N2** 寫了 provd 將來的 D-Bus 權限,照現在的寫法,被攻陷的 provd 可以把 B1 的修正繞過去。

修法都不大,但都要先改設計才能宣稱 SC-only 有被驗證、有被守住。

範圍:v16 全文,其中重新讀了 F26–F29、§3、§4.6、§5 L19–L22、§7 D24–D26、§8、§9、§10、§11、§12 Q8、§13 v15→v16;firmware 兩個新 commit;wsl.6 的 payload(`/home/yello/out/1.5.12-wsl.6…/ekh-bcm2711/…ab-payload.tar.gz`),解開 rootfs 放在我自己的 mktemp 目錄;kernel 6.6.138 與 BlueZ 5.72 的 build 樹原始碼。04 只做了唯讀操作(`ls`、`ps`、`grep`),沒有 build、沒有改樹、沒有 commit。

證據分級:✅ 已驗證並附原始輸出或檔案行號;⚠️ 只從原始碼推得,沒有在空中實測(仍然沒有第二台 BLE central);❌ 沒做。

---

## 先從現場出發:SecureConnections=only 有沒有把 B1 關乾淨

逐一檢查一個遠端 BLE 攻擊者、在節點沒有 agent 的情況下,能不能走到 key distribution(那一步會送出 IRK):

| 路徑 | 結果 | 證據 |
|---|---|---|
| legacy 配對(不綁定的 JW,也就是 v15 的 B1) | 被拒:`SMP_AUTH_REQUIREMENTS` | `smp.c:1760-1761` ⚠️ |
| SC + Just Works / Numeric Comparison(沒有 MITM) | 一律送 `mgmt_user_confirm_request`(`smp.c:2206-2216`)→ BlueZ `device_confirm_passkey` → `new_auth` 因為沒有 agent 回 NULL(`device.c:6661-6667`、`:6741-6743`)→ `confirm_reply(FALSE)`(`adapter.c:8028-8035`) | ⚠️ |
| SC + 要求 MITM | 本機 io_cap 是 NoIO(kernel 預設 `hci_core.c:2454`;沒有 agent 時 BlueZ 不送 `SET_IO_CAPABILITY`,`adapter.c:9077-9087`)→ 依 `smp.c:821-833` 的表只會選到 JW → `pending_sec_level ≥ HIGH` 時回 `SMP_AUTH_REQUIREMENTS`(`smp.c:1820-1827`) | ⚠️ |
| SC + passkey | 本機 NoIO 時,上表那一列(row 3)不會產生 `REQ/DSP_PASSKEY` | ⚠️ |
| SC + OOB | 需要 `local_oob`(`smp.c:1771`,只有 `smp_generate_oob` 會設,`:585`)或 remote OOB data(`hci_find_remote_oob_data`)。兩者都只能經由 **trusted** mgmt 指令產生,`mgmt_untrusted_commands`(`mgmt.c:185-196`)裡沒有任何 OOB opcode。BlueZ 的 neard 外掛被 `--noplugin` 關掉,D-Bus 又只開放給 root。所以只有 root 能讓 OOB 路徑成立 | ✅ 原始碼 |
| 以 legacy 回退繞過 SC | 被拒:`refusing legacy fallback in SC-only mode`(`smp.c:2057-2060`) | ⚠️ |
| 節點發 Security Request(由周邊端發起) | 對方收到後一樣送 Pairing Request,走的還是上面第一到五列,沒有另外的路 | ⚠️ |
| 節點當 central 主動配對 | 沒有任何程式讓節點以 central 身分配對:沒有 bonded device,policy 外掛的重連只對 bonded device 生效 | ⚠️ |
| 經 BR/EDR 的 cross-transport key derivation | `CONFIG_BT_BREDR` 沒開;`SMP_DIST_LINK_KEY` 只在 SSP 啟用時才會加 | ✅ `.config:1496` |
| 用舊的 LTK 加密 | 儲存區在 tmpfs,沒有任何 LTK | ✅ |
| 開機時的空窗 | hci0 在約 11 s 出現,這時處於 `AUTO_OFF`:不廣播、不可連線。BlueZ 在 `read_info_complete` 裡依序送 LE → SC → privacy 指令,之後 policy 外掛才開電(`adapter.c:10262-10310`)。開電之前無法配對 | ✅ 原始碼 + 04 dmesg |

**結論:對遠端 BLE 攻擊者,原始碼層面 B1 已經關了**(⚠️ 仍待 `ble-pair-sc-only-254` 的空中實證)。剩下的洞在節點內部:SC-only 在節點上讀不出來(N1);provd 將來的 D-Bus 權限可以替攻擊者註冊 agent(N2)。

另外查了 SC-only 會不會弄壞設計需要的東西。結論是不會:`hci_conn_check_link_mode` 的 SC-only 檢查只在兩個地方被呼叫,一是 encrypt change 事件(`hci_event.c:3583`),二是 BR/EDR 的 `l2cap_connect`(`l2cap_core.c:3981`)。LE 上 ATT 是 fixed channel,不經過這兩處,所以不配對的 GATT 讀寫不受影響 ⚠️。這點要在實機上重跑 iPad 測試確認(m6)。

---

## MAJOR

### N1. 「current settings 含 `sc-only`」在 kernel 6.6 上不存在;health 檔的 `sc_only=1`、`ble-privacy-254`、PR-F 的驗證清單都依賴一個讀不到的值 ✅(原始碼)

**證據**:
- mgmt 的 settings 位元只有 `MGMT_SETTING_SECURE_CONN`(BIT 11),沒有 SC-only 的位元(`include/net/bluetooth/mgmt.h:94-115`)。
- `get_current_settings` 只看 `HCI_SC_ENABLED`(`mgmt.c:893-894`)。
- `bluetoothctl mgmt.info` 能印出的字串表裡也只有 `secure-conn`(`client/mgmt.c:341-361`)。
- 其他非特權的讀取指令:`READ_CONTROLLER_CAP` 的 security flags 只有 public key 驗證與 key size 強制兩類(`mgmt.c:4293-4322`)。
- 唯一讀得到 `HCI_SC_ONLY` 的是 debugfs 的 `sc_only_mode`(`hci_debugfs.c:301`),但 `CONFIG_BT_DEBUGFS` 沒開(`.config:1502`)。

**後果**:
- §8 的 fail-closed 條件寫的是 `privacy=1 sc_only=1 bondable=0`。照字面實作,`sc_only` 永遠讀不到,provd 就永遠不廣播;如果實作者放寬條件,`sc_only` 就變成一個沒人檢查的欄位。
- §9 與 §10 第 1 點都把「current settings 有 `sc-only`」當成 PR-F 要在 04 驗的項目。這個驗證根本做不出來,寫成「已驗證」就是誇大。
- 另一個依賴設計沒寫出來:BlueZ 只在 `SECURE_CONN` 位元**還沒設**時才送 `SET_SECURE_CONN 0x02`(`adapter.c:10302-10304`),之後不會再確認一次。

**修法**:
- §3 / §8 / §9 / D26 改寫:privacy 與 bondable 由 helper 經 `READ_INFO` 讀,這部分可行;**SC-only 在節點上無法觀察**。
- 二選一:
  - (a) 在 BlueZ 加一個小 patch:在 `set_mode(SET_SECURE_CONN)` 完成的 callback 裡記一行固定格式的 log(例如 `SC mode 0x02 applied, status 0x00`)。helper 只認本次開機出現的這一行,把它當成 `sc_only` 的來源。這一行就是一個新的介面,要補上契約:寫者是 bluetoothd、讀者是 helper、要比對 boot_id、找不到或格式不對就當 0,fail-closed。
  - (b) 誠實寫成 `sc_only` 是由 image 擁有的 `main.conf` 推斷而來 ⚠️,實證只靠 tier B 的 `ble-pair-sc-only-254`,而且每次發行都要跑一次。
- 負對照:
  - 用 (a) 時:拿掉 `SecureConnections=only` 再 build → log 裡沒有 `0x02` → helper 判 `sc_only=0` → provd 不廣播。
  - 用 (b) 時:只能靠空中測試。

### N2. provd 的 D-Bus 政策若照 §4.6 寫的「PR-P2 加 `<policy user="provd">` 同一組」,被攻陷的 provd 可以註冊 agent,讓 SC Just Works 通過,IRK 就又被分發出去 ✅(原始碼與 wsl.6 rootfs)

**證據**:
- wsl.6 的 `/etc/dbus-1/system.d/bluetooth.conf` 給 root 的是 `<allow send_destination="org.bluez"/>`(✅ 本次讀取)。這代表 org.bluez 的**每一個方法**都可以呼叫,包括 `AgentManager1.RegisterAgent` / `RequestDefaultAgent`、`Adapter1` 的 `Properties.Set`(可以改 `Pairable`)、`Device1.Pair`。
- F27 的修正有一個前提:「沒有 agent → SC 的 Just Works 被拒」(`device.c:6666`)。只要有一個會自動接受的 agent,`smp.c:2213` 的確認就會通過。隨後 `smp.c:669-670` 照樣加上 `ID_KEY`,也就是 IRK 加上 public 位址被送出。
- provd 是面向 BLE、最容易被打穿的程序,§8 也列了「攻陷的 provd」這個 actor。但現在那一列的誠實界線只寫了「看得到經過的明文」,沒寫「能重新打開配對」。

**修法**:
- §4.6 / §8 明寫 provd 的政策**不是同一組**,只放行這些:
  - `LEAdvertisingManager1` 的 Register / UnregisterAdvertisement;
  - `GattManager1` 的 Register / UnregisterApplication;
  - `ObjectManager.GetManagedObjects`;
  - `Properties.Get` / `GetAll`;
  - BlueZ 回呼 provd 物件所需的 `send_interface`。
- **明確拒絕**:`AgentManager1`、`Properties.Set`、`Device1.Pair`、`Adapter1.SetDiscoveryFilter/StartDiscovery`。
- 負測試 `prov-sec-dbus-254` 擴充:以 provd uid 呼叫 `RegisterAgent` 與 `Set Pairable true`,兩者都必須回 `AccessDenied`。
- helper 的 health 檔已經看 `bondable=0`;可以再加一條:health 偵測到 `bondable=1` 或出現 agent 就記 TAMPER。這只能偵測,擋的工作要靠 dbus 政策。

---

## MINOR

- **m1.** SC-only 只在 bluetoothd 啟動時套用一次(見 N1)。同一次開機中,如果 root 執行過 `btmgmt sc on` 或 `bluetoothctl mgmt.sc on`,kernel 就會變回只有 SC on,bluetoothd 重啟後也不會再改回來,因為那時 `SECURE_CONN` 已經不算缺少。§3 要寫明 hci0 的 SC 狀態只有 bluetoothd 一個寫者。L22(respawn)那一列要加上「SC 狀態沿用 kernel 裡現有的值」。有個順序上的前提我確認過是成立的:`set_secure_conn` 要求 LE 已經啟用(`mgmt.c:6889-6892`),而 BlueZ 在同一個 mgmt 佇列裡先送 LE,所以沒問題 ✅。
- **m2.** F28 的輪替會讓 RPA 與 payload 被串起來。除了 provd 定時重新註冊,kernel 自己也會在兩個時機重新啟用廣播並換新的 RPA:連線結束時,以及加密失敗時(`hci_event.c:3575-3577` 會把 RPA 設成過期)。如果這時 payload 的 nonce 還是舊的,觀察者就能把新舊兩個 RPA 連起來。修法:provd 在連線建立時就 Unregister 廣播,斷線後再以新的 nonce 註冊,不要讓 kernel 用舊的 instance 自動重開。把這條寫進 §4.8 的 F28 契約,PR-P2 再加一個斷線後的被動掃描測試。
- **m3.** 儲存區在 init 裡寫的是 `[ -L "$STORE" ] && rm -f; mkdir -p; chmod 700`,隱含的前提是 `/var/lib`(也就是 `/tmp/lib`)由 root 建立,而且非 root 程序無法搶先建立。04 上實際的狀態是 `/tmp/lib` root 0755 ✅,但它是在 S19 由 dnsmasq 的 init 建立的(`etc/init.d/dnsmasq:918`),dbus 在 S60 也會建(`etc/init.d/dbus:15`)。這是一個沒有寫出來的依賴。在 S19 之前就已經跑著的非 root 程序有 ubusd、logd,而 `/tmp` 是 1777;如果某次開機 dnsmasq 沒有啟用,先建出 `/tmp/lib/bluetooth` 的人就可以預先放一個自己知道的 IRK,`load_irk` 會照收。修法:照 `rundir.sh` 的做法,檢查 `/tmp/lib` 與 `$STORE` 不是 symlink、owner 是 root、不可被 group/other 寫入;任何一項不符就不啟動 bluetoothd(fail-closed)並記 WARN。這也是 #280 的同一類問題。
- **m4.** L20 列了 wsl.2/.3/.4,卻漏了 wsl.5。wsl.5 正好是 B1 的狀態:privacy 開、沒有 SC-only、IRK 存在 overlay、有 keep.d。不過今天沒有實際暴露,因為 wsl.3–.6 都沒有廣播者,不廣播就不能被連、也就不能配對。這點已核對 wsl.6 rootfs:有用到 `LEAdvertisingManager` 的只有 `usr/bin/bluetoothd` 與 `bluetoothctl` ✅。L20 補上 wsl.5,並寫明「之後的 provd image 一律帶 SC-only,所以不存在『有廣播者卻沒有 SC-only』的槽」。
- **m5.** gate 的強化我實跑過(wsl.6 rootfs):
  - OK,11 個 key 在 `sh` 與 `busybox_ash` 下都回 rc 1 且沒有輸出 ✅。
  - 在 `usr/sbin` 多放一份 shim → FAIL ✅。
  - 放一個含 `bootloader_config` 字串的假執行檔 → FAIL ✅。這只是因為我的假檔裡沒有 NUL,`grep -I` 會跳過真正的 ELF。
  - 用字串拆開的寫法(`c=bootloader_; vcgencmd ${c}config`)→ **OK**,沒有擋下。

  另一個問題:`command -v busybox` 找不到 busybox 時,這一段會**安靜地**只用 `sh` 測(違反「找不到要測的東西就要 FAIL」)。目前這台 host 有 `/usr/bin/busybox`,所以現在沒影響。修法:沒有 busybox 就 FAIL;對 ELF 另外跑 `strings | grep -l bootloader_config`,為之後的 Go 二進位檔(provd、helper)預先準備。字串拆開這種寫法列為「防的是我們自己的失誤,不是防對手」的已知限制,寫進 §11。
- **m6.** SC-only 對不配對 GATT 的影響,原始碼推論是沒有影響(見上方),但 iPad 的 GATT 連線與讀取在 wsl.6/.7 上要重跑一次,當作回歸確認,寫進 §10 第 1 點。iOS 在對方是 SC-only 時,會不會在某些特性上主動要求配對 ⚠️ 還沒實測。
- **m7.** 舊 overlay 裡的 `/etc/bluetooth/keys`:wsl.5 的 keep.d 會讓它跟著不帶 `-n` 的 sysupgrade 走,04 的 slot A 也還有原型 IRK。v16 之後沒有人讀它,但它仍是一份留在硬碟上的秘密。init 可以在第一次啟動時「先列出再刪除」(依使用者規則,不能盲刪),或至少把它列進 §11 的收尾清單。現在 §11 只寫了 04 slot A 那一份。

---

## 已驗證成立的部分(✅,附證據)

- wsl.6 rootfs:`/etc/bluetooth/main.conf` 有 `SecureConnections = only`;`lib/upgrade/keep.d/` 裡沒有 `bluez-daemon`(只剩 alsa-lib…wpad-openssl);`bluez-daemon.conffiles` 與 `batman-ble.conffiles` 都不存在;`strings usr/bin/bluetoothd | grep -c 'Generated IRK (getrandom)'` = 1;init 裡是 `STORE=/var/lib/bluetooth`、`mkdir -p`、`chmod 700`,spike 那條指向 overlay 的 symlink 已移除。
- BlueZ 5.72 認得 `SecureConnections` 這個 key(`main.c:84`、`:985-994`),`SC_ONLY` 的值是 2(`btd.h:40-42`)。kernel 的 `set_secure_conn` 在 LE-only(BR/EDR 關閉)時走不需要 HCI 指令的分支,直接設 `HCI_SC_ONLY`(`mgmt.c:6906-6916`)。
- 非特權的 `READ_INFO` 讀得到 privacy 與 bondable(`mgmt.c:185-196`、`:894-898`),D26 的這一半成立。
- tmpfs 儲存區的生命週期:
  - 第一次開機:目錄 0700、bluetoothd umask 0077、identity 0600(v15 已在 04 實測)。
  - respawn:procd 只重啟程序,不會重跑 `start_service`,所以沿用同一個 IRK,與 L22 一致。
  - 從 wsl.5 OTA 上來:A/B 是新的 overlay,而 `/var` 是新的 tmpfs,不會有舊的 symlink。
  - rollback:見 m4 / m7。
- 04 現況(唯讀):`/tmp/lib` root `drwxr-xr-x`、`/var -> tmp`;S61 之前就在跑的非 root 程序有 ubus、logd、dnsmasq、network(hostapd/wpa_supplicant)、ntp、nobody(gpsd、avahi);OTS 容器的 uid 1000/999 都在自己的 netns。

## 沒做的(❌)

- 空中測試(`ble-pair-sc-only-254`、RPA 被動掃描)。原因同上,仍沒有第二台 Linux BLE central;Q8 待使用者決定。
- wsl.6/.7 上機:按指示沒有動節點。
- iPad 在 SC-only 下的回歸(m6)。

## 結論

SecureConnections=only 在 linux-6.6.138 + BlueZ 5.72 上,對遠端攻擊者把 B1 的配對路徑全部關掉了(⚠️ 原始碼推論,待空中實證),也不影響不配對的 GATT。v16 的 tmpfs 儲存區、拿掉 conffiles 與 keep.d、強化後的 gate 都成立。還沒處理的是兩個介面的定義:N1(sc-only 讀不到,PR-F 不能宣稱在 04 上驗過)與 N2(provd 的 dbus 政策必須排除 agent 與 Set)。修完之後只需要窄範圍複查。
