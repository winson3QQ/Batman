# #254 PR-P2 `batman-provd` 設計 v7 — 對抗式審查 A(第 7 輪,整份重審)

審查者 A,2026-10-31。對象:`scratchpad/254-p2-impl.md` v7 全文 §0–§12(§13–§18 不採信)。方法:從現場出發(認領 → 立刻 join、10 台一隊、路人、被攻陷的 provd、root 操作員、harness 在 `-wbox test` 上跑臂 2),把 v7 新寫的三塊(§1.3 `inFlight` / `pendingReconcile` 狀態機、§4.8 閘門 + 釘死 payload + btmon 斷言、§3 / L83 / §9 的 harness provd 感知)逐條對 kernel / BlueZ / firmware 腳本 / helper 原始碼 / 04 實機重核;上游 CVE 修法本輪**真的查到了 commit 與 diff**(§0 V7/V8),這是前六輪都沒有的證據。

## 0. 我自己核過的事(✅ 原始碼 / 實跑;⚠️ 推論;❌ 沒驗)

| # | 事實 | 證據 |
|---|---|---|
| V1 ✅ | 04 實機(Git Bash 唯讀):`/rom/etc/batman-build` = `1.5.14-wsl.16+c46dfc9.fw6aa0241`、`BATMAN_FW_COMMIT=6aa0241`、`BATMAN_DIRTY=0`、無 `BATMAN_WBOX`;無 `/usr/bin/batman-provd`、無 `btmgmt`、無 `btmon`、無 `/etc/init.d/batman-provd`;bluetoothd 3665 / helper 4209;`Powered yes / Discoverable no / Pairable no / ActiveInstances 0 / SupportedInstances 5`;`bluetoothctl mgmt.advinfo` → `Max instances: 5`、`Instances list with 0 items`;已裝 bluez 套件只有 `bluez-daemon`、`bluez-libs`;uptime 5:16 | ssh 實跑 |
| V2 ✅ | BlueZ 5.72 的 `btmgmt add-adv` 實作在 `client/mgmt.c:4658 cmd_add_adv`(`tools/btmgmt.c` 只是殼):`flags` 初值 **0**;`-c` → `CONNECTABLE`、`-g` → `DISCOV`、`-l`、`-m` → `MANAGED_FLAGS`、`-p` → `TX_POWER`、`-n`、`-a`、`-P` → `SEC_*`;`-d` / `-s` 各只准一次,`parse_bytes` = 連續 hex 字串(無空白,長度 ≤ 255 B);→ **只帶 `-d` 時 flags == 0 = 不 connectable、不 discoverable、不 managed** | `client/mgmt.c:4658-4790` |
| V3 ✅ | kernel 6.6.138 `add_advertising`(`mgmt.c:8672`):`instance` 1..`le_num_of_adv_sets`;`tlv_data_is_valid` → `tlv_data_max_len`:adv data 只在 `DISCOV / LIMITED / MANAGED_FLAGS` 時扣 3、`TX_POWER` 扣 3,**flags 0 → 31**;`EIR_FLAGS`(0x01)出現在 adv data 只有 `flags_managed` 時拒;格式錯 → `INVALID_PARAMS`;scan rsp 只在 `LOCAL_NAME / APPEARANCE` 時扣 | `mgmt.c:8498-8590, 8672-8760` |
| V4 ✅ | `eir_create_adv_data`(6.6.138,`eir.c:245`):instance 資料已有 `EIR_FLAGS` → `skip_flags`;否則 `!HCI_BREDR_ENABLED` → `LE_AD_NO_BREDR` → **無條件寫 3 B**(ad_len 從 0 起算)→ `memcpy(ptr, adv->adv_data, adv_data_len)` 不檢查 → 31 B 使用者資料 + 3 = 34 B 進 `hci_cp_le_set_adv_data cp`(`data[31]`,堆疊區域變數,`hci.h:1614`);`cp.length = len`(34)→ 命令仍送出。**`eir_create_scan_rsp`**:沒有 kernel 自加的前置欄位,`memcpy` 31 B 進 `data[31]` 剛好 → 不 overflow(只有 `APPEARANCE` 在前、`LOCAL_NAME` 在後會加) | `eir.c:245-330`;`hci_sync.c:1331-1350` |
| V5 ✅ | legacy 路徑:`add_advertising_sync → hci_schedule_adv_instance_sync → hci_start_adv_sync`(`hci_sync.c:1832`,`!ext_adv_capable`)→ `hci_update_adv_data_sync → hci_set_adv_data_sync` → `__hci_cmd_sync_status(HCI_OP_LE_SET_ADV_DATA)` → **btmon 的 monitor channel 看得到**(`hci_sock.c:358 hci_send_to_monitor`,`hci_core.c:3016` 在 `hci_send_frame` 每個送出的 HCI 封包都複製到 `HCI_CHANNEL_MONITOR`);btmon 是 root 開 raw socket,harness 已 scp(`scripts/lib/ble-254.sh:51-54 ble_stage` periph 角色帶 `btmgmt` + `btmon`,`DV_BT_TOOLS`) | 原始碼 |
| V6 ✅ | `eir_precalc_len` 在 6.6.138 已存在(`eir.h:21`)→ 上游兩個修法可直接 backport | `eir.h:21` |
| V7 ✅ | **CVE-2025-38303 上游 = torvalds `47c03902269aff377f959dc3fd94a9733aa31d6e`「Bluetooth: eir: Fix possible crashes on eir_create_adv_data」(6.16-rc2)**:`eir_create_adv_data(hdev, instance, ptr, size)` 加 `size`;Flags 改成 `if (flags && (ad_len + eir_precalc_len(1) <= size))`、TX power 同形;`hci_set_adv_data_sync` 傳 `sizeof(cp.data)`、`hci_set_ext_adv_data_sync` 傳 `HCI_MAX_EXT_AD_LENGTH`;**`eir_create_scan_rsp` / `eir_create_per_adv_data` 簽名不變**。**注意:這一支單獨不修 F-P10 的路徑** — Flags 檢查在 `ad_len == 0` 時做,`0 + 3 <= 31` 永遠成立,之後的 `memcpy` 仍不檢查;Debian tracker 標 6.6.y「needed」(= 6.6.138 沒有,與 F-P10 一致) | `gh api repos/torvalds/linux/commits/47c0390…`(diff 全文已看) |
| V8 ✅ | **CVE-2026-64539 上游 = torvalds `6f5fb689fdf80bdd143f22a502f9eb1f3c85e286`「Bluetooth: eir: Fix stack OOB write when prepending the Flags AD」(2026-06-03;`Fixes: b44133ff03be`)**:只改一處 — `if (flags && (ad_len + eir_precalc_len(1) + (adv ? adv->adv_data_len : 0) <= size))`;commit message 明寫「drop the flags rather than the user-provided data」、KASAN 報告就是 `eir.c:301` 的 memcpy、`hci_schedule_adv_instance_sync` 路徑;**只動 `eir_create_adv_data`,scan rsp / per-adv 不動**;它依賴 V7 的 `size` 參數(順序:先 47c03902 再 6f5fb689) | 同上(diff 全文已看) |
| V9 ✅ | OpenWrt packages feed:`btmgmt` 裝在 **`bluez-utils-extra`**(`feeds/packages/utils/bluez/Makefile:62-68, 136-142`,與 `mpris-proxy`、`sdptool`、`gatttool` 同包,`DEPENDS += dbus glib2 libncurses libreadline`),不在 `bluez-utils`;`btmon` 單獨一包 `bluez-utils-btmon` | Makefile |
| V10 ✅ | `stamp-batman-build.sh:38-56`:`why` 以 `"$why wbox-$WBOX"` 累加 → 值**以空白開頭**(` wbox-test`);今天沒有 `BATMAN_DIRTY_WHY` / `BATMAN_FW_COMMIT_FULL` 兩個 key;`build-board.sh:121-125` `wbox_apply` 在第 2 步、stamp 在第 4 步(`:140-141`);`lib-wbox.sh:68` 只有 `test` 不套 patch、`:83-84` export `BATMAN_WBOX=$name` + prov_test → `BATMAN_PROV_TEST=1`;`helpers.list` 21 個變體只有 `test` 無 patch | 原始碼 |
| V11 ✅ | `feeds/batman` 是 Batman repo 的完整 clone(`feeds.conf.default:8` pin `34f216da`,`feeds/batman/scripts/dv` 存在;**`scripts/dv/data/` 今天不存在**,H3 才建)→ build 時 `cmp target/…/999-…-254.patch feeds/batman/scripts/dv/data/…` 可行;`KERNEL_FILE_DEPENDS` 含 `$(PATCH_DIR)`,`STAMP_PREPARED` 名字含該目錄的 md5(`kernel-build.mk:12-13`)→ 新 patch 檔自動重 prepare | 原始碼 |
| V12 ✅ | 既有 harness:`ble-lib-254.sh:60-62 adv_instances` = `bluetoothctl mgmt.advinfo` 的 `Instances list with N`(kernel 數);`ble_state:165-166` `!= 0` → `FAIL leftover`;`dv-preflight.sh:81-87` P6 對每台 bcm2711 跑 `ble_state`;`ble-periph-254.sh:42-52` `cmd_adv_on` = `rm-adv 1` + `add-adv [-c] -g -u 181c -d <name> 1`(**instance 1、DISCOV**)、`cmd_adv_off` = `rm-adv 1`、`role_fire_restore:171` `rm-adv 1` + `power off` + `bluetoothd restart`;**`scripts/dv/ble-254.sh:56-223` 八處 `adv-on` / `adv-off`(ble-rpa、N5a、tier B 配對單位)**;`prov-base-254.sh:207,222,258` 已有 `svc stop … batman-provd`(停,沒有起);`scripts/` 沒有任何 `start batman-provd` | 原始碼 |
| V13 ✅ | helper:`Handle` 進門 `n.mu.Lock()`(`node.go:157-158`);`claimVerify` `commitTxn` 在回應前(`:548`);owner-op 進門 `resolve()`(`:748-761`);`sock.Serve` 仍是單連線同步(`sock.go:107-116`);health 行無 trial、`ReadInfo` 每次新開 mgmt socket 2 s(`health.go:55-87, 155-162`) | 原始碼(與 F-P6/F-P44/F-P55/F-P63 一致) |
| V14 ❌ | F-P41 le_states、L10 / L11 目錄 bind、patched kernel 上 `btmgmt add-adv` 的實跑:本輪無新實證(與前六輪同;04 禁試廣播) | — |

## 1. 第 6 輪 MAJOR 的實際修復狀態(不看 §18)

| 第 6 輪 | v7 處置 | 判定 |
|---|---|---|
| A6-M1 / B6-M1 閘門只有 `test` 能過、sha 檔無寫者 | §4.8 綁 `-wbox test`、`WBOX == test ∧ DIRTY_WHY == wbox-test`、正本進 Batman `scripts/dv/data/`、`git show \| cmp`、build 時 `cmp` | ✅ 鏈條每一環有既有寫者(V10/V11);**但 patch 正本的內容(「涵蓋三個 creator」)與上游不符,而設計自己要求正本在核准時定 → M3**;`DIRTY_WHY` 的前導空白 → m3 |
| A6-M2 / B6-M3 `expectGen` 布林 / 餓死 | §1.3 `inFlight` + `pendingReconcile`,reconcile 綁回應 | ✅ 背靠背與連續動詞兩個情境都解了;**但自家動詞造成的 gen 變化在 reconcile 清旗標之後仍會被 `ctl` 當旁路 → M1**(v6 的「`ctl` 之後再輪一次」被拿掉時,它所擋的那個情境沒人接) |
| A6-M3 / B6-m6 臂 2 payload / INVALID_PARAMS | 釘 `1e ff` + 29 B、無 0x01、btmon 斷言 | ✅ 釘法對(V3/V4:flags 0 → max 31、kernel 仍加 NO_BREDR → 走到 memcpy);btmon 可見(V5);**斷言語意 = 上游 6f5fb689 的「丟 Flags 留資料」(V8)→ 正確**;「除非 D3 改 `tlv_data_max_len`」的保留句現在可以刪(m9);scan rsp 臂不具鑑別力(併入 M3) |
| B6-M2 harness 不知道 provd | §3 第三寫者、L83、§9 `ble_state` / deadman / `ble-rpa` | ⚠️ 方向對;**`ble_state` 的「provd 跑著期望 1」在設計自己定義的幾個窗裡是錯的,且八處既有 `adv-on` 單位誰停 / 起 provd 沒寫 → M2** |
| B6-M4 HELPER_WAIT 排隊 | `QUEUE_WAIT` 30 s | ✅ 未送出的解了;已送出之後「不送下一則」要明寫(m4) |

## 2. BLOCKER

無。

## 3. MAJOR

**M1. §1.3 狀態機:自家改 record 動詞的 `(state, Generation)` 變化,在 reconcile 清掉 `pendingReconcile` 之後才被 `ctl` 看到 → `inFlight == 0 && !pendingReconcile` 成立 → 判旁路 → 剛升擁有者的 session 被 Disconnect(`reason=generation`)。認領 → 立刻 join 的主流程大約四次有三次會中。**
- 情境:t0 `ops` 送 `claim.verify`(`inFlight=1`);t1 helper commit(`:548`)後回 0 → provd 升擁有者、`inFlight=0`、`pendingReconcile=true`、排 `info.owners`(`ctl`)+ `psks.get`(`ops`);兩者 < 1 s 回來 → 逐 session 比對(擁有者在新集合裡,不斷)→ **清 `pendingReconcile`**。`ctl` 下一輪(≤ 4 s 後)`info.state` 回 `(claimed, g+1)` ≠ 上次看到的 `(unclaimed, g)` → 依 §1.3 字面「`ctl` 看到二元組變時:只有 `inFlight == 0 && !pendingReconcile` 才判旁路 → 已認證 / 候選 session 全 Disconnect」→ 擁有者被踢,app 剛要送 `network/join`。只有 `ctl` 輪恰好落在 reconcile 完成前(≈ 25% 機率)才不會。同構:`network/join` 回 0 後(reconcile 快)→ 下一輪 `ctl` 看到 `(member, g+2)` → 全斷;`ssh_keys/set` 同。
- 根因:設計沒有任何一句讓 reconcile 更新 `ctl` 的「上次看到的 `(state, Generation)`」,而 `pendingReconcile` 又在 reconcile 完成時立刻清;v6 的「`ctl` 之後又成功輪過一次才清」正是在擋這個窗,v7 拿掉時沒有替代。第二個洞同源:`ops` EOF「歸 0」但**沒說設 `pendingReconcile`** → helper 重啟前剛 commit 的動詞,其 gen 變化在 EOF 之後、重連全量 reconcile 之前被 `ctl` 看到 → 全斷。
- 證據:§1.3 撤銷列原文;§3 快取列「失效鍵 … 條件:`ctl` 每 4 s 看到二元組變;provd 自己送過的改狀態動詞回應後;…」(三個條件並列,沒有說回應後的重拉會重設基準);§4.3「`Generation != 上次` → 標記待重拉」;V13(`claimVerify` commit 在回應前,`ctl` 的 `info.state` 不取鎖 → 一定看得到)。
- 修(契約文字,不改架構):
  1. reconcile 的內容固定為 **`info.state` + `info.owners`(`ctl`)+ `psks.get`(`ops`)**;reconcile 完成時以**這次 `info.state` 的 `(state, Generation)` 重設 `ctl` 的基準**,再清 `pendingReconcile`。
  2. 或等價寫法:`pendingReconcile` 只在「reconcile 完成 **且** 之後有一輪 `ctl` 其送出時刻晚於最後一個回應抵達」才清;旁路判定仍是 `inFlight == 0 && !pendingReconcile`。選 1(少一輪延遲、不靠時序)。
  3. `ops` EOF / 被當第 5 條拒 → `inFlight = 0` **並設 `pendingReconcile`**;重連後的全量 reconcile 走同一條規則清。
  4. 測試:`cache_test` 加「`claim.verify` 回 0 → reconcile 完成 → `ctl` 下一輪看到 `(claimed, g+1)` → **不斷**」(mutant = 不重設基準 → 斷,= v7 字面);`prov-netjoin-254` L82 斷言延長到「join 回 0 之後再等 ≥ 2 輪 `ctl`(≥ 8 s)log 仍無 `session revoked`」;helper 重啟臂:`claim.verify` 回 0 後立刻 restart helper → 擁有者不被 `reason=generation` 斷。

**M2. harness 的 provd 感知:`ble_state`「provd 跑著 → 期望 kernel `num_instances` = 1」在設計自己定義的幾個窗裡是錯的,會讓 preflight P6 / tier A 假 FAIL;八處既有 `adv-on` / `adv-off` 單位(instance 1、DISCOV)誰停 / 起 provd 沒寫;`prov-base-254.sh` 三處已經 `stop batman-provd` 而全 repo 沒有一處 `start`。**
- 情境 A(preflight):`pr_restore` 讓 04 重開 → 下一次 P6 / tier A #5 `ble_state` 在開機後 ≤ 120 s 內跑(L70:`node_cert` 等 `BootFinish` 放鎖才簽,期間**不廣播**)→ `num_instances` 0 而 provd 跑著 → 依 §9 新規則 FAIL「leftover」。同樣會 0 的合法狀態:`health.get` 任一欄不成立(L67,例如上一單位留下 bondable=1 — 這個該 FAIL 但理由是 bondable 不是 instance)、有 BLE 連線中(§4.4「有連線建立 → 撤銷」;02 剛好連著)、`SOCK_ONLY=1`(prov_test 單位之間 provd 跑著但不碰 bluetoothd)、ADV 自檢失敗 sleep 60、bus / adapter 退避中。期望值不能從「process running」推,只能從 provd 自己的狀態推,而 provd 在唯讀 jail 裡**寫不出任何狀態檔**(§3),只有 log。
- 情境 B(既有單位):`scripts/dv/ble-254.sh:56,62,66,72,146,221` 的 `adv-on`(`ble-rpa` 三態、N5a、tier B 配對 / SC / privacy 單位)→ `cmd_adv_on` = `rm-adv 1` + `add-adv … 1`:provd 跑著時 `rm-adv 1` 拔掉 provd 的 instance(BlueZ 不知情)、`add-adv 1` 就地覆寫(F-P54)、provd 的 `ctl` 從 `health.get` 看到 `num_instances` = 1 以為自己的還在。h23 `:118` 說 `cmd_adv_on` 先斷言 provd 未 running — 那誰停它?設計 §9 只寫了 `ble-rpa` provd 模式與兩個 deadman,沒寫 BLE lease 取得 / 釋放對 provd 的責任;`prov-base-254.sh:207,222,258` 今天就 `svc stop … batman-provd`(P2 後真的會停)而 repo 零處 `start` → 這三條路徑(normalise / restore / strip)之後節點無廣播直到重開,deadman 只在 lease 到期才起。
- 證據:V12;§4.4 撤銷條件、L70、§4.6 `SOCK_ONLY`;§9「`ble_state` 改『provd 跑著期望 kernel `num_instances`=1 / 停著期望 0』」;§3 廣播列「harness 只准在 provd 停止時 `add-adv 5` / `rm-adv`」(規則有,機制沒有)。
- 修:
  1. **instance 編號分家**:provd(經 BlueZ)永遠是 1;harness 的 `add-adv` 一律用 **5**(臂 2 已是;`cmd_adv_on` 改 `-… 5`、`cmd_adv_off` / deadman `rm-adv 5`)。`ble_state` 的 leftover 判定改成**不看總數**:provd 停著 → 總數必須 0;provd 跑著 → 不得有 instance 5(總數 0 或 1 都合法)。這樣 L70 / 連線中 / `SOCK_ONLY` 都不假 FAIL,而 harness 殘留一定被抓。⚠️ 要先確認 `bluetoothctl mgmt.advinfo` 是否列出各 instance 編號(`client/mgmt.c:4420` 只看到印總數;若不列,改用 harness 自帶的 `btmgmt advinfo`,或 `ble_state` 在 provd 跑著時以 `logread` 最後一行 `adv registered / withdrawn` 當 provd 的期望)。
  2. **停 / 起 provd 只在一個地方**:BLE lease `acquire`(`ble_begin`)若單位宣告 `needs-adv`(= 會 `adv-on`)→ `stop batman-provd` 並在 lease 記錄 `provd=stopped`;`release` / `ble_end` / 兩個 deadman → `start` 回來並斷言 ≤ 15 s 內 `num_instances` 回 1(或 provd log `adv registered`);`ble-rpa` provd 模式不宣告 `needs-adv` → 不停、不准 `rm-adv`。`prov-base-254.sh` 三處 `stop` 的對應 `start` 寫進 `pr_restore` / `pr_normalise` / deadman。
  3. §5 L83 的負對照保留;新增 L84「開機後 ≤ 120 s 跑 `ble_state`」= `num_instances` 0 且 PASS(負對照 = v7 字面規則 → FAIL)。

**M3. D3 patch 正本的內容與上游不符,而設計自己要求「正本在核准時就定」:§4.8 寫「涵蓋三個 creator(F-P43)」,上游兩個修法只動 `eir_create_adv_data`;scan rsp 臂(`-s` 31 B)在未 patch 的 kernel 上也不 overflow,不是見證。commit id 現在查得到,應直接釘進設計。**
- 事實(V7/V8):CVE-2025-38303 = `47c03902269a`(加 `size`,Flags / TX power 各自檢查「自己放不放得下」);CVE-2026-64539 = `6f5fb689fdf8`(Flags 檢查改成「Flags + instance 資料放不放得下」,放不下**丟 Flags 留資料**)。兩支合起來才修 F-P10 的路徑(第一支單獨時 `0 + 3 <= 31` 永遠成立、memcpy 仍不檢查);順序固定;6.6.138 有 `eir_precalc_len`(V6),context 可套。**`eir_create_scan_rsp` / `eir_create_per_adv_data` 上游不動**:legacy scan rsp 沒有 kernel 前置欄位(V4),31 B `-s` + flags 0 → `memcpy` 剛好 31 → 不越界;所以 §4.8「scan rsp 臂 `-s <31 B 同形 payload>` 同判定」在**未 patch** 的 kernel 上一樣 PASS(btmon `LE Set Scan Response Data` length 31)= 不具鑑別力,不能列為 D3 的見證;「涵蓋三個 creator」若真寫進 patch,就是我們自創的改動,沒有上游對照、沒有負對照(找不到能觸發的輸入)。
- 影響:H3 PR 帶的正本若照 §4.8 的描述寫,firmware PR 複製它、build 時 `cmp` 過、閘門 (2) 過 — 全鏈一致地見證一份**非上游**的 patch;而 scan rsp 臂的 PASS 讓人以為第三個 creator 被驗過。
- 修:
  1. §4.8 / D3 / §6 最後一列改成:patch 正本 = **上游 `47c03902269a` + `6f5fb689fdf8` 兩支的 6.6 backport,標頭寫兩個 id 與 CVE 編號,只動 `eir_create_adv_data` 與 `hci_sync.c` 兩個呼叫端、`eir.h` 簽名**;刪「涵蓋三個 creator」;F-P43 保留為事實但註明上游不動另外兩個。
  2. 臂 2 的正向判定維持「btmon `LE Set Advertising Data` length == 31、內容 == payload、無 0x01」(= `6f5fb689` 的語意,V8 已證);**刪掉 scan rsp 臂**,或保留但標成「非見證、只證 scan rsp 路徑不受 patch 影響」且不計入 D3 的 PASS;§9 同步。
  3. 「mgmt 回 INVALID_PARAMS 不算通過(除非 D3 改 `tlv_data_max_len`)」的保留句刪掉:上游沒改 `tlv_data_max_len`,INVALID_PARAMS 一律 FAIL(m9)。
  4. CI 單元(主機、不需節點)加:對正本 patch 做 `grep -c '^+++ '` == 3(`eir.c`、`eir.h`、`hci_sync.c`)且不含 `eir_create_scan_rsp` / `eir_create_per_adv_data` 的 hunk(mutant:多加一個 creator 的 hunk → FAIL)。

## 4. MINOR

**m1. `btmgmt` 的套件不是「bluez-utils 的單一工具」。** V9:在 `bluez-utils-extra`(連 `gatttool` / `sdptool` / `mpris-proxy`,依賴 dbus / glib2 / ncurses / readline),04 今天只有 `bluez-daemon` + `bluez-libs`(V1)。harness 本來就 scp `btmgmt` + `btmon`(V5,`ble_stage`),臂 2 在 BLE lease 內跑 → D9 多餘;建議刪 D9(release gate「無 `/usr/bin/btmgmt`」仍可留),或明寫要新開一個只裝 `btmgmt` 的套件定義(不是一行 `+bluez-utils`)。

**m2. 臂 2 副作用清單「無 Flags、connectable」錯。** V2:只帶 `-d` 時 flags 0 → 不 connectable(ADV_NONCONN_IND / ADV_SCAN_IND,`hci_enable_advertising_sync` 依 `hci_adv_instance_is_scannable`)。改成「non-connectable、無 Flags」;順便寫明 `-d` 的格式 = 62 個連續 hex 字元(`parse_bytes`,無空白)。

**m3. `BATMAN_DIRTY_WHY` 的值以空白開頭。** V10:`why` 以 `"$why wbox-$WBOX"` 累加,第一個 token 前有一個空白;stamp 寫檔要 `${why# }`(或 harness 比對前 trim),否則 `== wbox-test` 永遠不成立(fail-closed 的假 FAIL);CI 七案例裡「全成立」那案要用真 stamp 腳本產的值,不是手寫字串。

**m4. `ops`「一次一則」要寫成硬規則。** `HELPER_WAIT` 到期後若 `ops` 把佇列裡下一則寫進 socket(helper 在 `h(m)` 內不讀,封包停在 buffer),它會在長動詞結束後被執行 — 正是 B6 M4 的情境換了位置,`QUEUE_WAIT` 擋不到(它已「送出」)。寫明:`ops` 在真回應或 EOF 之前**不送**下一則,`HELPER_WAIT` 到期只回 `E_BUSY` 不解除;排隊的照 `QUEUE_WAIT`。假時鐘單元:HELPER_WAIT 到期後 fake helper 的收件計數仍是 1。

**m5. reconcile 的失敗語意沒定。** `info.owners` / `psks.get` 回 `EUnsupported`(撕裂讀、無 record)或 `ERate`(`psks.get` 1/s,連續動詞時每個回應都排一次)→ §4.3「暫態,保留舊快取」→ `pendingReconcile` 永不清 → 旁路判定永遠被壓住、被移除的 owner 也永不被比對。寫:`ERate` / 撕裂 → 退避重試(≤ 3 次 / 10 s);重試後仍 `EUnsupported` 且 `ctl` 最近 `info.state` 成功 → 視為空集合(全部已認證 / 候選 Disconnect `reason=generation`);這也補 helper 重啟 `boot.Run` 把 record 重寫成無 owners 的情況。

**m6. 正本漂移的第三種:harness 自己的 checkout 比 image 的 pin 新。** build 時 `cmp` 用的是 `feeds/batman`(pin),閘門 (2) 用的是 `$REPO`(main)。Batman 改了正本、firmware 還沒重 build → 臂 2 FAIL(fail-closed,對)— 寫進 §4.8 的預期與 known-failures 流程,免得被歸因成「樹髒」。

**m7. `bluetoothctl mgmt.advinfo` 的輸出是否列 instance 編號 ⚠️ 未驗**(`client/mgmt.c:4420` 只印總數;`:4459` 的 `Instance: %u` 是別的回應);M2 的「不得有 instance 5」判定依賴它,實作前查一次或改用 harness 的 `btmgmt advinfo`。

**m8. 文字**:§4.8 負對照 (a) 寫 wsl.17,04 今天是 wsl.16(V1),兩者都無 patch、都 fail-closed,寫清楚哪台;§1.2 F-P4 加 V1 的「已裝 bluez 套件只有 daemon + libs」;§6 最後一列「上游 CVE 修法 commit 待查」改為 V7/V8 的兩個 id。

**m9. §4.8「mgmt 回 INVALID_PARAMS 不算通過(除非 D3 改 `tlv_data_max_len`)」** — 上游不改 `tlv_data_max_len`(V7/V8),保留句刪掉,INVALID_PARAMS 一律 FAIL(併入 M3 第 3 點,這裡只提醒 §4.8 與 §9 兩處同步)。

## 5. 我核過、成立的(§18 說修了、我確認真的修了)

| v6 發現 | v7 | 結果 |
|---|---|---|
| 閘門綁 `test`、`WBOX == test ∧ DIRTY_WHY == wbox-test` | §4.8 (3) | ✅ `test` 是唯一無 patch 的 prov_test 變體(V10);`BATMAN_PROV_TEST=1` 隨 prov_test tag 自動 export → helper marker 成立;前導空白 → m3 |
| 正本進 Batman、`git show \| cmp`、build 時 `cmp` | §4.8 (2)、§10 第 6 點 | ✅ 每環有寫者:H3 PR 寫正本、firmware PR 複製、`build-board.sh` 第 4 步 `cmp`(`feeds/batman` 是完整 clone,V11)、harness `cmp`;內容見 M3 |
| 釘死 payload、無 0x01、只 `-d` | §4.8 | ✅ V2/V3/V4:flags 0 → max 31 → 接受;無 0x01 → 不 `skip_flags`;LE-only → NO_BREDR 必加 → memcpy 越界路徑;TLV `1e ff …` 合法 |
| btmon 斷言語意 | §4.8 | ✅ = 上游 `6f5fb689` 的行為(V8:丟 Flags、留 31 B、`cp.length = 31`);btmon 看得到 `LE Set Advertising Data`(V5) |
| `inFlight` 計數、遲到回應 −1、候選以 PSK 值比對、成員 update 後 `psk-rotated` | §1.3 | ✅ 背靠背(claim → join)與連續動詞兩個情境在字面上都不再撤;基準重設缺 → M1 |
| `QUEUE_WAIT` 30 s | §4.3 | ✅ 未送出的解了;送出後規則 → m4 |
| `ActiveInstances` → kernel `num_instances` | §3 / L68 | ✅(F-P60 對:`ActiveInstances` 是 D-Bus client 數) |
| 兩個計時器(STATUS 以 `info.state`、撤廣播以 `health.get`)、`IsTrial` exec ≤ 5 s | §4.1 | ✅ `health.get` 不碰 `IsTrial`(V13) |
| `BATMAN_FW_COMMIT_FULL`、`DV_FW_TREE` 未設 FAIL、MSYS 委派 | §4.8 (1) | ✅ 委派機制在 `daily-validation.sh:181-201` 真的存在 |
| `claim.replay` 不改 record 從清單拿掉 | §1.3 | ✅ |

## 6. 負對照盤點

| 防線 | 有 | 缺 |
|---|---|---|
| 自家動詞不撤 session | `cache_test` 背靠背 / 連續動詞臂 | reconcile 後 `ctl` 下一輪不撤(M1);helper 重啟後不撤(M1-3) |
| 臂 2 鑑別力 | payload 釘死、btmon 無 Flags、INVALID_PARAMS FAIL | scan rsp 臂無鑑別力(M3);正本 hunk 範圍 CI(M3-4) |
| 閘門 | wsl.16 / .17 image → FAIL;CI 七案例;build `cmp` | 真 stamp 值(前導空白)那案(m3);harness-vs-pin 漂移預期(m6) |
| `ble_state` 與 provd 並存 | — | L70 / 連線中 / `SOCK_ONLY` 不假 FAIL(M2-3) |
| 停 provd 的單位把它起回來 | L83 deadman | lease release / `pr_restore` / `pr_normalise`(M2-2) |
| reconcile 失敗 | — | `EUnsupported` 重試後視為空集合(m5) |
| `ops` 一次一則 | — | HELPER_WAIT 到期後 fake helper 收件數 = 1(m4) |

## 7. 誠實界線

有寫且對:RPA 900 s;BLE 單連線;ADV 自檢只擋自己;`adv_registered_once` 量 kernel;autocommit 只 WARN;被攻陷 provd 的能力;`psk_member` 在 update 進行中的空窗;無 provd 保留位;殭屍連線;F-P41 ⚠️;kernel patch 不在 #275 見證內;`model` fail-open;新連線在 reconcile 前以舊集合放行;F-P10 是 n=1 stack overrun。
要改:「涵蓋三個 creator」(M3);「connectable」(m2);「bluez-utils 的單一工具」(m1);§6「上游 commit 待查」→ 已查(V7/V8)。

## 8. 判定

**APPROVE-WITH-CHANGES — 0 BLOCKER / 3 MAJOR / 9 MINOR。**

第 6 輪的五個 MAJOR 在機制層都解了:閘門的每一環現在有既有寫者且在 04 上今天就 fail-closed;`inFlight` / `pendingReconcile` 擋住了背靠背與連續動詞;payload 釘法與 btmon 斷言我對 kernel 原始碼與**上游兩個修法的 diff 本身**核過,語意正確。留下的三個 MAJOR 都是契約文字層、各一兩句就能關:(M1)reconcile 完成後沒有重設 `ctl` 的 `(state, Generation)` 基準,所以自家動詞的 gen 變化在下一輪 `ctl` 仍會被當旁路、認領後擁有者被踢;(M2)`ble_state`「provd 跑著期望 1」在開機 120 s / 連線中 / `SOCK_ONLY` 都是假 FAIL,八處既有 `adv-on` 單位與 `prov-base` 三處 `stop` 沒有人負責起回 provd — 改成 instance 編號分家 + lease 統一停起;(M3)patch 正本寫「三個 creator」與上游不符、scan rsp 臂無鑑別力 — 上游 id 現在有了(`47c03902269a` + `6f5fb689fdf8`),直接釘。依通用規則 MAJOR 開著就再出 v8 整份重審;04 實機證據(F-P41、L10 / L11)仍欠,與前六輪相同。
