# #254 PR-F(firmware)審查 — 審查者 B — 設計 v15(99afc99)+ firmware `feat/254-ble`(5ec36f40、625a6161)

**判定:REJECT**(1 BLOCKER / 4 MAJOR / 10 MINOR)

範圍:整個 PR-F。設計 v15 全文中 F16–F26、§3、§4.5、§4.6、§5、§7、§8、§9、§10 第 1 點、§12 Q8;firmware 兩個新 commit 加上 spike commit(`build-3aplus..feat/254-ble`);BlueZ 5.72 與 kernel 6.6.138 build 樹的原始碼;04 唯讀實測;wsl.4 rootfs 解開後實跑 gate。我沒有改 04/02 的任何狀態,也沒有動 build 樹。我執行過的 `bluetoothctl show` / `bluetoothctl mgmt.info` 是非互動模式,依原始碼不會註冊 agent(`client/main.c:491-494`,`NON_INTERACTIVE` 時不呼叫 `agent_register`),跑完之後 `Pairable: no` 沒變。

證據分級:✅ 已驗證並附原始輸出;⚠️ 只從原始碼推得,沒有在空中實測(這裡沒有第二台 BLE central:PC 的藍牙關著,02 沒有 BLE build);❌ 沒做。

---

## 先從現場出發

一個節點由隊伍帶著走,路過的人都能掃到它。它用 `sysupgrade -n` 做 OTA,可能 rollback 到舊槽,可能經重燒轉賣,上面還跑著 OTS 容器。v15 要給的性質是:**路人不能用 BLE 位址追蹤這台節點**。我逐一檢查這個性質實際上是否成立:

1. 開了 privacy 之後,任何未認證的 central 都能從節點拿到 IRK(B1)。拿到 IRK 的人可以解出節點以後所有的 RPA。在 v15 之前,節點沒有 IRK,這條洩漏路徑並不存在。是 F26 的修正把它打開的。
2. RPA 不會照 D24 寫的每 900 s 換一次。只有一個廣播 instance、控制器又只支援 legacy 廣播時,kernel 在 RPA 到期後**不會**重啟廣播(M1)。
3. 就算 1、2 都修好,節點的 2.4 GHz AP 每 100 ms 廣播一次 BSSID `8a:a2:9e:b5:6c:8b`。這就是 BT public 位址 `88:a2:9e:b5:6c:8b`,只多了 locally-administered bit;SSID `BCM2711-6c89` 也是由 MAC 產生的。§8 那一列的寫法是誇大(M2)。

---

## BLOCKER

### B1. 開 privacy 之後,任何路人都能用「不綁定的 legacy Just Works 配對」拿走節點的 IRK 與 public 身分位址 ⚠️(原始碼完整推導;未在空中實測)

**情境**:攻擊者在 Linux 上執行 `btmgmt sc off; btmgmt bondable off; btmgmt pair <節點 RPA>`,或用任何能送 SMP Pairing Request 的工具。它連上 provd 的可連線廣播,送出 Pairing Request:`auth_req = 0`(不綁定、不要 MITM、不要 SC),`io_cap = NoInputNoOutput`,`resp_key_dist = ID_KEY`。

**原始碼路徑**(kernel 6.6.138 build 樹):
- `net/bluetooth/smp.c:1756-1758`:`!HCI_BONDABLE` 時只拒絕**要求綁定**的請求。不綁定的請求照常往下走。
- `smp.c:1760-1761`:只有 `HCI_SC_ONLY` 會擋 legacy 配對。04 的 current settings 是 `powered le secure-conn privacy`(✅ 我本次實測),沒有 SC-only。
- `smp.c:669-670`:`if (HCI_PRIVACY) local_dist |= SMP_DIST_ID_KEY;`。這一行**不看 bondable**。`smp.c:717-718` 再算出 `rsp->resp_key_dist = req->resp_key_dist & local_dist`,所以只要對方要求 ID key,節點就會給。
- `smp.c:873-892`:沒有 MITM 時方法是 `JUST_CFM`。本機 io_cap 是 NoInputNoOutput,所以轉成 `JUST_WORKS`,TK 直接設成 0,**不問 user space**。本機 io_cap 為什麼是 NoInputNoOutput:沒有 agent、`AlwaysPairable=false` 時,`src/adapter.c:9077-9087` 的 `adapter_set_io_capability()` 直接 return,不送 `SET_IO_CAPABILITY`,於是用 kernel 預設 `hdev->io_capability = 0x03`(`hci_core.c:2454` → `hci_conn.c:934`)。
- `smp.c:1308-1328`:金鑰分發時送出 `SMP_CMD_IDENT_INFO`(內容是 `hdev->irk`)與 `SMP_CMD_IDENT_ADDR_INFO`(`hcon->src` = public 位址)。

**後果**:攻擊者拿到 IRK 與 public 位址。只要這個 overlay 還在(下次 OTA 或重燒之前),它都能把節點的每一個 RPA 解回這台機器。整個 RPA 只擋得住「沒試過配對的路人」。`prov-sec-bond-254`(04 ✅)用的是 iPad。iOS 一律要求綁定,所以被 `smp.c:1756` 擋下,**那個測試根本沒測到這條路**。

**修法**(PR-F 範圍,只改 `batman-ble` 的 `main.conf`):
- 加 `SecureConnections = only`(`src/main.c:985-994` 認得這個 key)→ mgmt 設 SC-only → `smp.c:1760` 拒絕所有 legacy 配對。
- SC 配對的 Just Works 一律要 user 確認(`smp.c:2206-2214`),沒有 agent 時 `device_confirm_passkey` → `new_auth` 回 NULL(`src/device.c:6666`、`:6741-6743`)→ 拒絕。要求 MITM 的路徑在本機 NoIO 時回 `SMP_AUTH_REQUIREMENTS`(`smp.c:1820-1827`)。
- 這樣不論用哪條配對路徑,都走不到金鑰分發。
- 一併考慮 m10:每次開機換 IRK。這樣即使 IRK 曾經洩漏,也只在本次開機有效。

**負測試**(進 `prov-sec-bond-254` 或新開 `ble-irk-leak-254`):用一台 Linux central 做不綁定的 legacy Just Works 配對,錄下 SMP 封包(`btmon`)。
- 修正前:收到 `Identity Information`,也就是 FAIL。這次執行同時就是負對照。
- 修正後:回 `Pairing Failed (Authentication Requirements)`,而且沒有任何 `Identity Information`。
- 再補一個 SC Just Works 的請求,應該被拒絕。

這個測試要有第二台 BLE central(Q8 的同一個前提)。在那之前,本項維持 ⚠️,而 PR-F 不能宣稱「RPA 防追蹤」。

---

## MAJOR

### M1. D24「每 `rpa_timeout` 換一次 RPA」在這個控制器上不成立:單一廣播 instance 會一直用同一個 RPA,直到斷線或重新註冊 ⚠️(原始碼;04 的廣播能力 ✅)

**證據**:
- 控制器只支援 legacy 廣播:04 上 `bluetoothctl show` 的 `Advertising Features` 只有 `SupportedInstances: 0x05`、`SupportedIncludes`,**沒有 `SupportedSecondaryChannels`**(✅ 本次輸出)。kernel 只在 `ext_adv_capable` 時才回報 SEC 旗標(`mgmt.c:8421-8430`),BlueZ 依這些旗標決定要不要出示那個 property(`advertising.c:1827`)。所以 `ext_adv_capable == false`。
- `mgmt.c:1016-1029` 的 `rpa_expired()`:先設 `HCI_RPA_EXPIRED`,然後 **`if (!HCI_ADVERTISING) return;`**。`HCI_ADVERTISING` 是 mgmt 的 Set Advertising 設定;LEAdvertisingManager 用的是 Add Advertising instance,不會設這個旗標(`mgmt.c:6353` 這一類寫者只在 `set_advertising`)。結果是 RPA 到期了,廣播卻不會重啟。
- instance 的輪播計時器也救不了:`hci_sync.c:624-645` → `adv_timeout_expire_sync` → `hci_clear_adv_instance_sync(..., force=false)`。沒有 timeout 的 instance 不會被移除,下一個 instance 又是自己。接著 `hci_schedule_adv_instance_sync()` 在 `hci_sync.c:2050-2056` 判斷 `!force && cur_adv_instance == instance && HCI_LE_ADV` → return 0,不送任何 HCI 指令,也就不會重新產生 RPA。
- 只有在廣播被重新 enable 時,`hci_enable_advertising_sync()` → `hci_update_random_address_sync()` 看到 `!rpa_valid` 才會換位址(`hci_sync.c:1885-1891`、`1093-1120`)。實際的觸發點是:連線結束後重開廣播、bluetoothd 重啟、provd 重新註冊廣播。

**後果**:一台沒人連的節點(現場常態)整次開機都用同一個 RPA,路人可以連續追蹤好幾個小時。Q8 照現在的寫法(掃 35 分鐘)會失敗。如果掃描端在過程中連了線,反而可能誤判成「有輪替」。

**修法**:
- 在 §3 / §4.8 寫明 **RPA 輪替的擁有者是 provd**。provd 每隔 T 註銷再重新註冊廣播,T 要略大於 `rpa_timeout`(900 s,`hci_event.c:1356-1358` 在 set_random_addr 完成時才起算),例如 905–960 s 加上隨機抖動,確保重新 enable 時 RPA 已經過期。
- 同一次重新註冊要一併換掉廣播 payload 裡會變的欄位(219 協定 B16 的 nonce 或計數器)。否則 payload 會把新舊兩個 RPA 串在一起;反過來,payload 換了而位址沒換也一樣會被串起來。這是 provd 與 B16 之間一條新的契約,要寫進 §4.8。
- Q8 / tier B 的空中測試要明定三件事:由誰廣播(PR-F 還沒有 provd,要有一個不註冊 agent 的最小廣播器,見 m5);測試期間**不能有任何連線**;觀察時間要大於 2 × `rpa_timeout`。
- 負對照是:不做重新註冊時位址不變(依本項的推導,預期就是這樣)。

### M2. §8「BLE 路人/追蹤」那一列誇大:節點有好幾個靜態識別碼一直在對空廣播 ✅(04 實測)

**證據**(04,`iw dev`):`phy1-ap0 addr 8a:a2:9e:b5:6c:8b ssid BCM2711-6c89 type AP`;BT public 位址是 `88:A2:9E:B5:6C:8B`(`bluetoothctl show`)。也就是說,AP 的 BSSID 就是 BT 身分位址加上 locally-administered bit,SSID 是由 MAC 產生的。

另外還有幾個靜態識別碼:
- mesh 介面 `wlh0 addr a8:dd:9f:4d:c6:10`,802.11s beacon 用的是固定 MAC。
- 依 `219-field-provisioning.md:266` 與本文件 §4.8,unclaimed / legacy 節點的廣播或 `status/public` 帶 `device_id` 末 4 字元。
- 對任何連上來的人,GATT 的 Device Information / Modalias `usb:v1D6Bp0246d0548` 都會曝露 BlueZ 版本(m9)。

已認領的節點在現場會開 AP 給手機連(見 OTS 現場情境),所以這台機器隨時都能用 WiFi 掃描認出來,而且掃到的就是 BT 位址。

**修法**:§8 改寫為誠實界線。RPA 只保證「BLE 這一層不額外增加一個穩定識別碼」,而且前提是 B1 已修、M1 已修、節點是 claimed/member、AP 關著(unclaimed 時 99zz 會關 AP,但 unclaimed 本身會廣播 `device_id` 末碼)。真正的節點不可追蹤性要靠 AP BSSID/SSID 隨機化與 HaLow MAC 的處理,這兩件列進殘項(#254 checklist)或 #255,不在階段 1 宣稱。§4.5 已經寫了「hostname/SSID 依 MAC 產生」是轉賣串連的殘項,§8 要用同樣的口徑。

### M3. provd「只經 D-Bus 讀 privacy 狀態」做不到:BlueZ 5.72 的 `Adapter1` 沒有 privacy property ✅(原始碼)

**證據**:`src/adapter.c:3914-3937` 列出了 adapter 的全部 D-Bus property:Address、AddressType、Name、Alias、Class、Powered、PowerState、Discoverable、DiscoverableTimeout、Pairable、PairableTimeout、Discovering、UUIDs、Modalias、Roles、ExperimentalFeatures、Manufacturer、Version。**裡面沒有 Privacy**。`AddressType` 回的是身分位址的型別(`public`),跟 privacy 開沒開無關(✅ 04 上 `Controller 88:A2:9E:B5:6C:8B (public)`,當時 privacy 是開著的)。

**後果**:§8 的 fail-secure 是「provd 開機斷言 privacy,沒有就不註冊廣播」;§3 寫 provd 是唯讀者、走 D-Bus。這兩處都依賴一個不存在的介面,照字面實作只會讀不到東西。

**修法**,二選一,寫進 §3 / §4.6 / §4.7:
- (a) helper(root)開 mgmt socket 送 `READ_INFO`,把 `privacy=` 寫進 health 檔,provd 讀 health。
- (b) provd 自己開一個**不受信任**的 mgmt socket。`read_controller_info` 帶 `HCI_MGMT_UNTRUSTED`(`mgmt.c:9277-9278`),所以不需要 `CAP_NET_ADMIN`(`hci_sock.c:1096` 只決定 trusted 與否)。但 `af_bluetooth.c:118` 要求程序在 init_net,所以 provd 的 ujail **不能**另開 netns。這一點要在 §4.7 寫明。

不論選哪個,讀不到(socket 失敗、hci0 不存在)都要當成「privacy 沒開」,也就是 fail-closed。負測試:白箱讓讀取回 `privacy` 不在 → provd 不註冊廣播。

### M4. `ble-privacy-254` 與它的負對照分辨不出有沒有 patch;04 上現在就留著原型 IRK ✅(04 實測)

**證據**:04 slot A(wsl.4,**沒有** patch 900)現在的 current settings 是 `powered le secure-conn privacy`,`/etc/bluetooth/keys/88:A2:9E:B5:6C:8B/identity` 存在,權限 `-rw------- root`(✅ 本次)。這就是作者手寫的原型。§9 的斷言是「current settings 含 `privacy`,而且 identity 0600 root」。這兩項在**未修正**的 wsl.4 上現在就會 PASS,所以「負對照 = wsl.4 FAIL」只在 fresh overlay 上才成立。設計沒有把這個前提寫出來。

另外,只要 IRK 檔已經存在,patch 900 的產生路徑(`generate_and_write_irk`)根本不會執行。所以這個測試在任何不是第一次開機的節點上,都**沒有測到修正本身**。

**修法**:
- PR-F 的驗證只在 fresh overlay 上做(OTA 到另一槽),並且多斷言兩件事:本次開機的 log 有 `Generated IRK (getrandom)`;identity 的 IRK 不等於原型(只比對雜湊,不要印出 IRK)。
- daily-validation 的 `ble-privacy-254` 照舊斷言 privacy 與權限,但說明它是「狀態檢查」,不是 patch 900 的回歸測試。patch 900 的回歸改由 build 期的 witness 加上 fresh overlay 測試負責。
- 負對照寫成「wsl.4 + fresh overlay → current settings 沒有 `privacy`」。04 上這一點已有證據:wsl.4 首次開機的 log 有 `generate_and_write_irk() Failed to open crypto`(✅ 04 logread `20:46:21`)。
- 原型 IRK 是 bluetoothd 擁有的資源被手動寫入,等於第二個寫者。§1 要記下它的存在。驗證完之後二選一:刪掉(要先問使用者),或明寫「04 rollback 到 slot A 時會顯示有 privacy,原因是這個原型檔」(見 m6)。

---

## MINOR

- **m1.** F26 的證據寫 current settings 有 `bondable`。這跟 §3 的「Bondable off」矛盾,也跟 F16 對照不起來。我本次在 04 看到的是 `powered le secure-conn privacy`,沒有 `bondable`;`Pairable: no` ✅。所以 F26 那次擷取時有 agent 在(互動式 bluetoothctl 或 spike 的腳本):有 agent 時 `adapter_set_io_capability()` 會把 bondable 打開(`adapter.c:9089-9090`)。修法:F26 註明擷取時的狀態。F16 的「bluetoothctl 會自己註冊 agent」限縮為互動模式;非互動的 `bluetoothctl <cmd>` 不註冊(`client/main.c:491-494`),§9 的測試必須用非互動形式。`ble-privacy-254` 另外斷言 current settings **沒有** `bondable`,而且有 `sc-only`(B1 修好之後)。
- **m2.** `lib/upgrade/keep.d/bluez-daemon` 的內容是 `/etc/bluetooth/keys`(✅ wsl.4 rootfs),所以 IRK 會被 `sysupgrade -b`(LuCI「產生備份」)打包下載,不帶 `-n` 的 sysupgrade 也會把它帶進新系統。§3 只寫了「`-n` / 重燒 = 新 IRK」,§8 的秘密盤點也沒有這條。修法:由 `batman-ble` 移除或覆蓋這個 keep.d 項目(沒有 bond,保留 IRK 沒有任何功能需求),或明寫接受這個風險。
- **m3.** IRK 檔格式錯(長度不是 32 hex)時,BlueZ 會 `error("Invalid IRK format, disabling privacy")`,而且**不會**重新產生(`adapter.c:4230-4234`,上游留了 TODO)。這等於在這個槽永久 fail-open。如果再加上 M3 的 provd fail-secure,結果就是這個槽的 BLE 永久不廣播,沒有人負責修復(3A+ 只能靠 BLE 管理)。修法:bluetoothd 的 init(它在 bluetoothd 之前跑,是這個前置檢查唯一合適的擁有者)在啟動前驗格式,不對就移走並記 WARN,讓 bluetoothd 重新產生;或直接採用 m10。另加白箱測試。
- **m4.** §5 生命週期矩陣沒有任何 privacy / IRK 的列。要補:
  - 第一次開機產生 IRK:`getrandom` 會阻塞到 CRNG 就緒,START=61 時應該已經就緒 ⚠️ 未量。
  - bluetoothd crash 後 respawn:hci0 仍在 powered 狀態,`Set Privacy` 會被拒(`mgmt.c:7024-7026` `REJECTED`),但 kernel 留著上一個程序設的 `HCI_PRIVACY` 與 IRK,所以結果正確。要寫明這個依賴。
  - clean restart:`adapter_shutdown()` 先關電(`adapter.c:10857-10881`)再重設 privacy ✅,這與作者的原型一致。
  - hci0 重新註冊。
  - IRK 檔損壞(m3)。
  - **rollback / 降級到 wsl.3 / wsl.4 這類有 BLE 卻沒有 patch 900 的槽** → 用 public 位址廣播。這類 image 必須排除在 OTA 與轉賣工具的清單之外,並寫進 L12。
- **m5.** Q8 的 (b) 做不到它要驗的事。iOS 的 CoreBluetooth 不提供 BLE 位址,只給每支手機自己的 UUID,所以 nRF Connect 在 iPad 上**看不出**位址是不是 public,也看不到位址本身,頂多看到 UUID 換了。再者「`Batman-04`」與 §4.6 的 GAP Name 固定 `Batman`、adv 無 Local Name 互相矛盾。(a) 也要先定義 PR-F 期間由誰廣播:`bluetoothctl advertise on` 必須在互動模式下跑,會註冊 agent,也就會打開 bondable(m1),測試本身就改變了要測的狀態。
- **m6.** 04 slot A 的原型 IRK(見 M4)要寫進 §1 的節點現況,並決定怎麼收尾。
- **m7.** `check-pvs-shim.sh` 我實跑過,結果是:對 wsl.4 rootfs OK(sha `c1446ce4…`,與 04 上的檔案以及 `files/` 版一致 ✅);換成 Morse 原版 → FAIL(sha 不符)✅;路徑不存在 → FAIL ✅。gate 檢查的 `ROOTSQ` 和 payload 用的是同一份,`build-board.sh:182-183` 有 `cmp`,卡片 image 也是用它建的 ✅。這個 gate 的弱點:行為測試只能抓到「透過 PATH 呼叫 `vcgencmd`」。如果 shim 改用 `/usr/bin/vcgencmd`、`vcmailbox` 或 `/proc/device-tree` 去讀,在 host 上因為沒有這些檔案會讀到空,gate 照樣 PASS。測試也是在 host 的 dash 下跑,不是 busybox ash。目前有 sha 把 shim 釘在審過的 `files/` 版本上,所以算 MINOR。修法:另外斷言 shim 的非註解行裡沒有 `vcgencmd|vcmailbox|bootloader|device-tree`。
- **m8.** L12 寫「舊 image 在 fresh overlay 會重新執行 F21 的 EEPROM 讀者」,不完整。`/lib/netifd/wireless/morse.sh:136,471-472`(每次 wifi setup)、LuCI `header.htm:82`、`diag_override.sh:18`、rpcd `morse-mode:223` 都是**執行期**的讀者。所以 rollback 到舊槽(overlay 不是 fresh)時,`mm_region` / `mm_region_unlocked` 立刻又會被讀,區域鎖也就立刻生效(前提是 EEPROM 被動過)。
- **m9.** GATT 的 Device Information 與 Modalias(`usb:v1D6Bp0246d0548`,0x0548 = 5.72)讓任何連上來的人知道 BlueZ 版本,方便挑 CVE 來打。可以考慮在 main.conf 設 `DeviceID` 或拿掉 deviceinfo,列進 #247 的 SBOM 討論。
- **m10.**(建議)節點沒有任何 bond,沒有人需要長期解析它的 RPA(擁有者 app 靠 `adv_owner` 標記辨認節點,不用 IRK)。所以可以讓 init 在每次啟動前刪掉 `identity`,或把它放在 tmpfs,讓 IRK **每次開機都換**。這樣一舉處理掉 m2(備份或保留)、m3(格式損壞)、B1 的殘餘風險(洩漏的 IRK 只活到下次重開),也不再需要「重燒才換 IRK」這條生命週期。代價:要確認 BlueZ 沒有其他東西依賴穩定的 IRK(我沒有找到)⚠️。
- **(平台)** patch 0013 放在 `patches/ekh-bcm2711/`,改的卻是**共用**的 `feeds/packages` bluez。目前 bcm2710 不裝 BLE,所以沒有影響。等 3A+ 要上 BLE 時,要把這條移到共用的 patch(或兩板都套),否則同一棵樹先 build 哪一板會決定 bluez 有沒有被 patch。在 L13 加一句即可。

---

## 已驗證成立的部分(✅,附證據)

- shim 在 04 上:`READ default_wifi_key` → rc 1、stdout 空,stderr 是 `The key "default_wifi_key" doesn't exist…`;sha `c1446ce4…` 與 `files/` 相同;每個 key 的 WARN 只記一次,標記放在 `/tmp/run/batman`(root 0700)✅。EEPROM 只有 `BOOT_UART/WAKE_ON_GPIO/POWER_OFF_ON_HALT/NET_INSTALL_AT_POWER_ON`,沒有 persistent var ✅(F24 成立)。
- 讀者盤點:在 wsl.4 rootfs 搜 `persistent_vars_storage` 與 `bootloader_config`,結果與 F21 的 9 個讀者一致。`95-batman-storage:418` 只取 `BOOT_ORDER|PARTITION_WALK`。uci.js 讀的是 uci `system.default_wifi_key`(由 morse-wireless-defaults 寫入,值來自 shim → 空 → 隨機)。沒有發現繞過 shim 的讀者 ✅。shim 的 rc / stdout 語意與 Morse 原版對「key 不存在」時相同,所以 `set -e` 的讀者行為不變 ✅。
- patch 900:IRK 不進 log(只有 `info("Generated IRK (getrandom)")`);檔案由 `create_file(…, 0600)` 建立再 `g_file_set_contents`;bluetoothd 的 `Umask: 0077`(04 `/proc/<pid>/status` ✅),所以 rename 之後仍是 0600;目錄 0700 root ✅。不開 AF_ALG 的取捨合理,kernel `.config` 是 `CRYPTO_USER_API*=m` 而且沒有裝 ✅。
- 容器碰不到 BT:OTS 五個容器都在 `ots-net`(自己的 netns)、`capdrop=[ALL]`、非 root(✅ `docker inspect`);`af_bluetooth.c:118` 只允許 init_net。所以容器 root 開不了 AF_BLUETOOTH ✅。本機非 root 程序可以開不受信任的 mgmt socket,讀到 current settings,但改不了任何設定。kernel 沒有開 LL privacy,IRK 不會送進控制器,本機非 root 讀不到 IRK ✅(原始碼)。
- 可連線廣播在 privacy 開啟時用 RPA(`hci_sync.c:1885-1891` `adv_use_rpa`);`Privacy=device` 對應 0x01,是 basic privacy,不是 limited(`main.c:852-853`),所以 bondable 與否不影響位址型別 ✅(原始碼)。

## 沒做的(❌)

- 任何空中測試:B1 的 IRK 洩漏、M1 的 RPA 不輪替、Q8。原因同上,這裡沒有第二台 BLE central。
- wsl.5 實機:image 還在 build。
- 3A+:板子壞了,而且 3A+ 不在 PR-F 範圍。

## 結論

PR-F 的 shim 與 gate 可以接受,只剩 m7 / m8 兩個 MINOR。BLE privacy 這部分則還不能宣稱任何防追蹤效果。B1 讓開 privacy 這件事反而讓 IRK 可以被拿走,而且修法只要改 PR-F 的 main.conf(`SecureConnections = only`)。M1 / M3 需要設計補上 provd 的契約。M2 需要改寫 §8 的誠實界線。M4 需要能分辨有沒有 patch 的驗證方式。修完以後請把整份文件重審一次。
