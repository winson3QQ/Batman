# #254 第 16 輪審查 — 審查者 A — design v16(792967a)+ firmware `feat/254-ble` 全部(到 5fa809b1)

**Verdict:REJECT(窄)— 0 BLOCKER / 1 MAJOR / 7 MINOR**

B1 的修法(`SecureConnections=only`)我從原始碼逐條追過:在這個 kernel 與 BlueZ 上,legacy 配對、SC Just Works、passkey、OOB、central 發起、BR/EDR 這幾條路都擋得住。SC-only 也不會弄壞設計需要的任何東西。tmpfs 儲存區、拿掉 conffiles、加強的閘門都成立。

唯一的 MAJOR 是 v16 新增的契約 `sc_only`:mgmt current settings **根本沒有 SC-only 這個位元**,所以 helper 讀不出它。照文件實作,provd 的 fail-closed 條件要嘛永遠不成立,要嘛被寫成看 `secure-conn`(沒有鑑別力)。§9 的負對照「wsl.5 → 沒有 sc-only」也就無從判定。同時 BlueZ 只在 SC 還沒開時才送 SC 設定。修法很小(見 N1),但要改設計並整份再審。

範圍:
- v16 全文與 `git diff 99afc99 792967a -- docs/design/254-stage1-impl.md`(§13「v15 → v16」逐列對照);
- B 的 v15 報告;
- firmware `e8e69c99`、`5fa809b1`,以及先前的 `5ec36f40`、`625a6161`;
- linux-6.6.138 `net/bluetooth`、BlueZ 5.72 原始碼(build 樹);
- wsl.6 出貨 payload(我自己解開 rootfs);
- 04 唯讀查詢。

wsl.7 的 build 我沒碰。

---

## 0. 協調者指定的檢查項

| 項 | 結果 | 證據 |
|---|---|---|
| SC-only 擋 legacy 配對(節點當 responder) | ✅ | `smp.c:1760-1761`:`HCI_SC_ONLY && !(auth & SMP_AUTH_SC)` → `SMP_AUTH_REQUIREMENTS` |
| 節點當 initiator 時的 legacy | ✅ | `smp.c:1950`(pairing rsp 同樣檢查);節點不主動連線。儲存區在 tmpfs、沒有 bond,policy plugin 沒有可重連的裝置 |
| SC 失敗後退回 legacy | ✅ | `smp.c:2057`:`fixup_sc_false_positive()` 在 SC-only 下回「refusing legacy fallback」 |
| SC Just Works | ✅ | `smp.c:2206-2216`:一律送 `mgmt_user_confirm_request`。BlueZ 的處理:`adapter.c:8028-8034` → `device_confirm_passkey()` → `new_auth()` 找不到 agent 回 NULL(`device.c:6661-6669,6741-6743`)→ `btd_adapter_confirm_reply(FALSE)`。bluetoothd 不在時沒人回覆 → SMP 逾時 → 仍然失敗(fail-closed) |
| passkey / numeric comparison | ✅(沒有 agent 時) | 本機 io_cap = NoInputNoOutput(沒有 agent 時 BlueZ 不送 SET_IO_CAPABILITY,`adapter.c:9323-9327`),只會走 Just Works。⚠️ 有 agent 時另論,見 N2 |
| SC + OOB | ✅ | 要 `SMP_DEV(hdev)->local_oob`(`smp.c:1773-1774`)或 remote OOB data(`smp.c:681-692`)。兩者都只能由 trusted mgmt 指令設(`READ_LOCAL_OOB_*` / `ADD_REMOTE_OOB_DATA` 不在 `mgmt.c:185-196` 的 untrusted 清單)。BlueZ 裡唯一讀 local OOB 的是 neard plugin(`plugins/neard.c:793`),而 init 用 `--noplugin=…neard` 停掉了 |
| BR/EDR / CTKD | ✅ 不適用 | `CONFIG_BT_BREDR` 未設;`hci_conn.c:2297`、`hci_event.c:5191,5544` 的 SC-only 分支都是 BR/EDR |
| policy plugin / agent 預設 | ✅(見 N2) | BlueZ 沒有內建 agent。`bluetoothctl` 互動模式預設註冊 agent(`client/main.c:3186-3190,491-494`),非互動不註冊 |
| 容器碰 HCI | ✅ | 04 `docker inspect`:5 個 OTS 容器都在 `ots-net`、`capdrop=[ALL]`、非 root、`no-new-privileges` |
| SC-only 會不會弄壞設計需要的東西 | ✅ | 設計本來就不配對:§0「只開 LE、不配對」、D14、§8「配對 / 綁定」列;協定走 GATT 上的 Noise。kernel 的 SC-only 只影響 SMP 與 BR/EDR link mode,不影響未加密的 LE 連線與 ATT。前提是 provd 的 GATT 不能帶加密旗標(見 N7) |
| tmpfs 儲存區的生命週期 | ✅(小缺口見 N5、N6) | 見 §2 |
| 拿掉 conffiles | ✅ | wsl.6:`/lib/upgrade/keep.d/` 沒有 `bluez-daemon`、`batman-ble`;`usr/lib/opkg/info/` 沒有這兩個的 `.conffiles` |
| 加強後的閘門 | ✅(邊界見 N4) | 我重跑的結果見 §2 |

---

## 1. 發現

### N1(MAJOR)`sc_only` 讀不到:mgmt current settings 沒有 SC-only 位元;BlueZ 只在 SC 還沒開時才設定它

**情境。** v16 寫 helper「經 mgmt `READ_INFO` 讀 privacy / **sc-only** / bondable」(§3),provd 只在 health 檔的 `privacy=1 sc_only=1 bondable=0` 時註冊廣播(§8);`ble-privacy-254` 斷言 current settings「含 `sc-only`」,負對照「wsl.5 → 有 privacy、沒有 sc-only」(§9)。

**證據。**
- kernel 的 settings 位元只有 `MGMT_SETTING_SECURE_CONN`(BIT 11),沒有 SC-only(`include/net/bluetooth/mgmt.h:94-115`)。
- `get_current_settings` 只看 `HCI_SC_ENABLED`(`mgmt.c:893-894`);`HCI_SC_ONLY` 不出現在任何 mgmt 回覆裡。
- 讀 `HCI_SC_ONLY` 的唯一介面是 debugfs `sc_only`(`hci_debugfs.c:301`),而 `CONFIG_BT_DEBUGFS` 沒開。
- bluetoothctl 對應的字串也只有 `"secure-conn"`(`client/mgmt.c:353`)。

**實作後會怎樣。**
- 照文件寫:`sc_only` 永遠是 0 → provd 永遠不廣播 → 沒有 BLE 管理面,trial 的 health(`adv_registered_once`)會讓每個好 image 都 revert。
- 或被寫成看 `secure-conn` → wsl.5(SC on、非 only)也是 1 → 負對照判不出來,fail-closed 變裝飾。

**另一個前提也要寫明。** BlueZ 只在 SC 缺席時才送 SC 設定(`adapter.c:10302-10304`,`if (missing_settings & MGMT_SETTING_SECURE_CONN)`)。所以 SC-only 生效依賴「本次開機 bluetoothd 第一次起來前,SC 是關的」。這在今天成立:
- LE-only、有 HCI_MGMT 時,kernel 自己不會開 SC:`hci_event.c:683` 要求 `!HCI_MGMT`,`hci_write_sc_support_sync`(`hci_sync.c:3299`)要求 BR/EDR SC;
- respawn 時沿用上一個 instance 的 `HCI_SC_ONLY`;
- 但任何 root 用 `bluetoothctl mgmt` 的 `sc on` 改過,之後 bluetoothd 重啟也**不會**改回 only,而且沒有任何東西看得出來。

**修法(任一,建議 1+2)。**
1. 0013 再加一段:`read_info_complete` 時**無條件**送 `SET_SECURE_CONN(btd_opts.secure_conn)`,並記一行可斷言的 log(例如 `Batman: SecureConnections mode 0x02 applied`,當 witness)。這樣 SC-only 不再依賴「SC 原本是關的」。
2. health 欄位改名為誠實的 `sc=`(`secure-conn` 位元)。§3 / §8 寫明推論鏈:kernel 對 LE-only 不會自己開 SC → 這次開機 SC 的唯一寫者是用 image 的 `main.conf` 起來的 bluetoothd → `sc=1` 即 SC-only。要讓推論成立,init 改成 `bluetoothd -f /rom/etc/bluetooth/main.conf`(04:`/rom/etc/bluetooth` 存在;bluetoothd 支援 `-f`),overlay 裡的 `main.conf` 就改不動它。
3. SC-only 的真實證據只有 tier B 的 `ble-pair-sc-only-254`(D25 ⚠️)。§9 刪掉「current settings 含 sc-only」,改成斷言 `secure-conn` 加上 (1) 的 log;負對照:wsl.5 沒有那行 log。

### N2(MINOR)只要有 agent 註冊(互動式 bluetoothctl),節點就變成可綁定,SC 配對確認會跳到操作員終端;provd 只在註冊廣播時才看 health

- agent 一註冊,`adapter_set_io_capability()` 在 `AlwaysPairable=false` 時會**打開** bondable(`adapter.c:9089-9090`),io_cap 變成 KeyboardDisplay。
- 路人的 SC 配對因此變成 numeric comparison,提示出現在操作員的 bluetoothctl。操作員回 yes 就會分發 IRK 與身分位址(tmpfs,重開後失效)。
- provd 照 v16 只在註冊或重新註冊時(約每 15 分鐘)檢查 health。
- 修法:
  - provd 每次讀 health(15 s)時,只要 `bondable=1` / `privacy=0` / `sc=0`,就立刻撤掉廣播;
  - runbook 寫「節點上別用互動式 bluetoothctl;要看狀態用 `bluetoothctl <cmd>` 一次性(NON_INTERACTIVE 不註冊 agent,`client/main.c:491-492`)」;
  - 或 image 不帶 bluetoothctl。
  - 測試:白箱註冊一個 agent → 一個 health 週期內 adv 消失。

### N3(MINOR)L21 的「今天」欄與事實不符:Batman 上 `sysupgrade -r` 是 no-op

- `/sbin/sysupgrade:334-337`:定義了 `platform_restore_backup` 就呼叫它,不走 `tar -x`。
- Batman 的 `platform-ab.sh:353` 是 `platform_restore_backup() { :; }`(04 實讀 `/lib/upgrade/platform.sh:353` 同樣)。
- 所以 wsl.5 的「`-r` 寫回」不成立,LuCI 還原也什麼都不寫(我 v15 M3 那一列同樣寫錯,在此更正)。
- 「還原備份不能把 SC-only 改回去」結論對,但理由應該是這個。root 直接改 overlay 的 `main.conf` 仍會持久,由 N1-2 的 `-f /rom/...` 收。

### N4(MINOR)加強後的閘門:邊界要寫明,ash 那一輪會靜默略過

- **我實跑(wsl.6 rootfs)**:OK;在 `usr/sbin` 多放一份 shim → FAIL ✅。
- **兩個邊界(閘門 PASS)**:
  - 在 `usr/bin` 放一個含 `vcgencmd bootloader_config` 字串的**二進位檔** → OK(`grep -I` 跳過二進位);
  - 寫一個 `bootloader_conf""ig` 拆開字串的 uci-default → OK。

  這是靜態掃描的本質限制,在閘門註解與設計寫明「只擋腳本型直接讀者」即可。
- **ash 輪的問題**:`busybox_ash` 那一輪用的是主機(Ubuntu x86)的 busybox,不是目標版本。主機沒有 busybox 時這一輪被**靜默略過**,OK 訊息仍然出現,只是 shell 清單變短。這違反「找不到可檢查的東西就要 FAIL」。修法:沒有 busybox → FAIL;或註明用的是主機 busybox。

### N5(MINOR)wsl.5 槽與 image 裡殘留的 `/etc/bluetooth/keys`

- wsl.6 image 仍然內建一個空的 `/etc/bluetooth/keys`(0755,0012 的 `INSTALL_DIR` 還在)。不再使用,建議刪掉,免得之後的檢查或人誤判。
- L20 只列 wsl.2/.3/.4。曾經裝過 wsl.5 的槽,overlay 會留著一把**持久的 IRK**,而且沒有 SC-only(privacy 開、legacy 可配對)。直到那個槽下次被 OTA 寫入(fresh overlay)才消失。rollback 到這種槽時沒有廣播者,無暴露;但應寫進 L20,並和 04 slot A 的原型檔一起列入 §11 收尾。

### N6(MINOR)init 沒有照 #280 的方式驗證 tmpfs 儲存區

- `[ -L ] && rm; mkdir -p; chmod 700` 只靠開機順序,前提是 `/tmp/lib` 由 root 先建好。04 實測:`/tmp/lib` 是 root 0755,子目錄 `dbus`、`misc` 由 dbus、dnsmasq 的 init 以 root 建;`fs.protected_symlinks=1`。
- 今天沒有可利用的路徑。但 IRK 是 #280 定義下「root 寫入 /tmp 底下」的秘密。
- 建議 mkdir 後驗證:父目錄是 root、不可被 group/other 寫;目錄本身不是 symlink、owner root、模式 0700;不符就不啟動 bluetoothd(fail-closed)並記 log。可以重用 `rundir.sh` 的 `_rd_mode` 寫法。

### N7(MINOR)SC-only 的前提要寫成 provd 的契約

- SC-only 不會弄壞設計,前提是 provd 的 GATT 特徵**沒有**任何 `encrypt-*` / `secure-*` / `authorize` 旗標。
- 只要有一個有,iOS/Android 會自動發起配對,而配對在 SC-only + 沒有 agent 下必失敗 → app 讀不到那個特徵。
- 修法:§4.8 寫明;PR-P2 加斷言,列出 provd 匯出的 GATT flags,不得含上述旗標。

---

## 2. 我實際跑過或讀過的東西

**wsl.6 rootfs**(`/home/yello/out/1.5.12-wsl.6+f2f2bf6.fwe8e69c9`,由我自己 `unsquashfs4` 解出,用完即刪):
- `keep.d`:`alsa-lib … wpad-openssl`,沒有 bluez-daemon、batman-ble;兩者都沒有 `.conffiles`。
- `main.conf` 含 `SecureConnections = only`、`Privacy = device`。
- init 與 `e8e69c99` 相同(`STORE=/var/lib/bluetooth`、mkdir、chmod 700)。
- `grep -rl LEAdvertisingManager` 只命中 `usr/bin/bluetoothctl`、`usr/bin/bluetoothd` → PR-F 沒有廣播者 ✅。
- `etc/bluetooth/keys/` 空目錄仍在(N5)。

**閘門(tree 現行版 `5fa809b1`)**:

```
check-pvs-shim: OK (… 11 keys READ rc 1 silent under: sh busybox_ash; READALL empty; WRITE refused; 1 shim; direct readers only: ./etc/uci-defaults/95-batman-storage ./sbin/persistent_vars_storage.sh)  rc=0
neg 第二份 usr/sbin → FAIL: rootfs has 2 files named persistent_vars_storage* … rc=1
二進位讀者 → OK rc=0(邊界,N4)
拆字串讀者 → OK rc=0(邊界,N4)
主機 busybox:/usr/bin/busybox(x86)
```

**04 唯讀查詢**:
- `/tmp/lib`(root 0755):`bluetooth -> /etc/bluetooth/keys/`(wsl.4 的 symlink)、`dbus`、`misc`;
- `fs.protected_symlinks = 1`、`protected_regular = 2`;
- `/lib/upgrade/platform.sh:353 platform_restore_backup() { :; }`;
- `/sbin/sysupgrade:334-337`;
- `bluetoothd --help` 有 `-f, --configfile`;`/rom/etc/bluetooth` 存在;
- OTS 容器的 net / cap 如 §0 所列。

我沒有在 04 上跑 bluetoothctl,也沒有改任何東西。

**tmpfs 生命週期**(原始碼 + 04):

| 路徑 | 行為 |
|---|---|
| 首次開機、每次開機 | 新的 0700 目錄;bluetoothd `umask 0077` → identity 0600;`getrandom` 產生新 IRK |
| respawn | 目錄留著,同一把 IRK;介面仍 powered 時 `set_privacy` 被拒(`mgmt.c:7024`),kernel 沿用原本的 `HCI_PRIVACY`/IRK;SC-only 也沿用 |
| clean restart | 介面先關,IRK 照檔案重設 |
| 從 wsl.5 升上來 | 新槽是 fresh overlay(`platform_copy_config` no-op),舊的 `/etc/bluetooth/keys` 只留在舊槽(N5);`/var/lib/bluetooth` 原本就在 tmpfs,舊 symlink 開機後不存在,init 的 `[ -L ] && rm` 只對同一次開機有效 |
| rollback | 回到舊槽的設定(L20 + N5) |
| 轉賣重燒 | 無殘留 |

## 3. 沒做或做不到的

- ❌ 空中:B1 / SC-only 的實際拒絕(D25)、RPA(D24)。要 Linux central(Q8)。
- ⚠️ `Pairing Failed` 之後 kernel 是否斷線:沒追。不影響安全結論。
- ❌ iOS:沒有 Database Hash 時的 GATT 快取行為(F29 已列 ⚠️)。

## 4. v15 我列的發現在 v16 的去向

| v15 發現 | v16 收法 | 判定 |
|---|---|---|
| M1 RPA 不自己輪替 | F28 + provd 重新註冊 + 被動掃描測法 | ✅ |
| M2 privacy 不在 D-Bus | D26(helper `READ_INFO`) | ✅;但新加的 sc_only 欄位有同類問題 → N1 |
| M3 IRK 生命週期 | 儲存區改 tmpfs、無 conffiles、L19–L22 | ✅;N3、N5 是小更正 |
| m1 GATT DB Hash | F29 + §11 | ✅ |
| m2 原型 IRK 污染負對照 | 只在 fresh overlay 判定 + log 斷言 | ✅ |
| m3 閘門涵蓋面 | 11 個 key、PATH、允許清單 | ✅;邊界見 N4 |
| m4 bcm2710 | §11 | ✅ |
| m5 追蹤防護的誠實界線 | F29 | ✅ |
| m6 PR-F 沒有廣播者 | §10 + rootfs grep 為證 | ✅(我在 wsl.6 重驗) |
