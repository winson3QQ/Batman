# #254 PR-P2 `batman-provd` 設計 v4 — 對抗式審查 B(第 4 輪,整份重審)

審查對象:`scratchpad/254-p2-impl.md` v4 全文 §0–§15。方式:從現場出發(認領、10 台一隊 join/update、路人、被攻陷的 provd、root 操作員跑 `provclient` / harness、provd 與 helper 各自重啟、owner 被移除),§13–§15「已對應」一律不採信,逐條對原始碼重核。分工 B:最終模型下的並行與時序(ctl 10 s / 4 s、全域桶 10/s 突發 40 與 provclient 共用、IsTrial 快取、accept 限速 vs 退避、殭屍連線)、Noise / 假 msg2 與 stale-while-revalidate 的退化、啟動盤點(Disconnect 合法連線的 UX、temporary device 的 D-Bus 可見性)、GATT 快取新鮮度、生命週期、dbus policy、kernel patch 閘的 marker 來源、負對照、誠實。

**環境誠實界線**:04(10.41.1.3)`ssh -o ConnectTimeout=10` 兩次 `Connection timed out`、一次 WSL 本身 0x8007274c → **本輪沒有任何 04 實機輸出**;F-P* 的實機事實沿用前三輪核過的。我核的是原始碼:repo main `34f216d`、firmware `/home/yello/firmware-2710`(scripts/、patches/、include/、BlueZ 5.72 build 樹、dbus 1.14.10 build 樹)。

## 0. 我自己核過的事實(✅ 原始碼;⚠️ 推論 / 未能上機)

| # | 事實 | 證據 |
|---|---|---|
| RB4-1 ✅ | `/etc/batman-build` **只由 `scripts/stamp-batman-build.sh` 在 build 時產生**(「Never hand-edit it」;`.gitignore:38-39` 排除 `files/etc/batman-build`;firmware `CLAUDE.md:9` 同句);它已輸出 `BATMAN_BOARD_PATCHES=<n>:<digest>`,並把每個 board patch 的 `Batman-Witness:` 行烘進 `/etc/batman-patch-witness`(#275);`check-board-patches.sh` 不全套用就拒絕 stamp | `scripts/stamp-batman-build.sh:1-4, 52-58, 72-88`;`scripts/patch-witness.sh:1-16`;`scripts/build-board.sh:141` |
| RB4-2 ✅ | **`patches/<board>/` 只准碰 `feeds/`**:`openmanet_setup.sh` 的註解明寫「the reset covers feeds/, not the firmware tree itself, so a patch of package/ or target/ would be "previously applied" on the second -i and stop setup」;套法 `patch -N -p1`,失敗即 `exit 1`;現有 10 個 ekh-bcm2711 patch 的 `+++` 全部在 `feeds/…`(0013 是「patch 加 patch」到 `feeds/packages/utils/bluez/patches/900-…`) | `scripts/openmanet_setup.sh:147-160`;`grep '^+++' patches/ekh-bcm2711/*.patch` |
| RB4-3 ✅ | kernel patch 的正確落點是 **`target/linux/bcm27xx/patches-6.6/`(1321 個,兩板共用)**;OpenWrt 的 `KERNEL_FILE_DEPENDS` 含 `$(PATCH_DIR)`,`STAMP_PREPARED` 檔名帶這些目錄的 md5 → **新增 / 改 patch 檔會自動讓 kernel 重新 prepare + 編譯**,不需手動 `target/linux/clean` | `include/kernel-build.mk:12-13`;`include/kernel.mk:43` |
| RB4-4 ✅ | `patches/ekh-bcm2710/` **沒有** `0012-bluez-daemon-min-254` / `0013-bluez-irk-getrandom-254`(只在 bcm2711);早在 review-v15-B 就指出 | `ls patches/ekh-bcm27{10,11}/` |
| RB4-5 ✅ | BlueZ:LE 對端連上 → mgmt `Device Connected` → `connected_callback → btd_adapter_get_device → adapter_create_device → device_create → device_new → g_dbus_register_interface(DEVICE_INTERFACE)` → **temporary 裝置在連線期間一定有 D-Bus 物件**,`Connected` 屬性 `dev_property_get_connected`;`remove_temporary_devices` 只在 discovery 結束 / power 事件掃,不會拔掉連線中的 | `adapter.c:9454-9490`、`btd_adapter_get_device`;`device.c:device_new(+47)`、`:1304, 3195`;`adapter.c:744-755` |
| RB4-6 ✅ | `Device1.Disconnect` 是 **async**:`dev_disconnect → device_request_disconnect`:關 `att_io`、把 msg 排進 `device->disconnects`,**排一個 `DISCONNECT_TIMER = 2 s` 的 timer 才呼叫 `disconnect_all → btd_adapter_disconnect_device`(mgmt DISCONNECT)**;回覆在 `Connected` 轉 false 時才送(`device.c:3332-3340`)→ 從呼叫到回覆 ≥ 2 s + HCI 斷線時間 | `device.c:69, 1715-1731, 1847-1875, 3332-3340` |
| RB4-7 ✅ | `psk_owner[i] = PskOwner(o.TagKey, dev)` **每個 owner 一把**;`psk_replay` 只在恰 1 個 owner;`psk_member` 綁 `Net.Version`;`ownerRemove` 刪 owner、`AdvOwnerKey` 輪替、`Generation++`、commit;`info.net` 回 `{1: net_id, 2: version, 3: left}`;**今天沒有 `info.owners`**(新動詞) | `node.go:391-411, 884-910, 236-247`;`grep '"info.owners"'` = 0 |
| RB4-8 ✅ | 219 §3.5:擁有者候選只能 `info` / `auth/owner`;`auth/owner` 比對 p5 裡的擁有者公鑰;`owner/remove` 刪該 owner 的 `owner_tag_key` 與 `psk_owner`、輪替 `adv_owner_key`;**協定沒有一句講「被移除者的既有 session 怎麼辦」** | `219-protocol.md:94-99, 201-203` |
| RB4-9 ✅ | `provclient info` = **一條連線打 2 個唯讀動詞**(`info.state` + `info.cert`);每次呼叫 `DialUnix` 新連線;只有 `verb` 泛用子命令,沒有 `proxy`;**harness 今天沒有任何 `provclient` 迴圈**(awk 6 行窗掃 `prov-lib / prov-254 / chain1 / prov-sec`,唯一命中是註解) | `tests/tools/provclient/main.go:522, 543-549, 618`;`scripts/dv/*.sh` |
| RB4-10 ✅ | `sock.go`:`Serve` 同步 accept;`serveConn` 先 `peerUID` 再進迴圈;`Idle` 只在 `Read` 前武裝;malformed → 以 id 0 回 20 關連線 | `sock.go:107-170` |
| RB4-11 ✅ | dbus `system.conf` default:`deny own=*`、`deny send_type=method_call`、**allow signal / method_return / error(requested reply)、allow receive 四類**、allow `org.freedesktop.DBus` 三介面 + `Containers1`、deny `UpdateActivationEnvironment` / `Debug.Stats` / `systemd1.Activator`;firmware `bluetooth.conf` root policy 六條 `send_interface` 無 destination → bluetoothd → provd 回呼(`GattCharacteristic1` / `LEAdvertisement1` / `ObjectManager` / `Properties`)放行 | `dbus-1.14.10/bus/system.conf.in:44-82`;`package/batman/batman-ble/files/bluetooth.conf` |
| RB4-12 ✅ | `IsTrial()` = `rc != 1`(fail-closed)、health `Committed()` = `rc == 1`,互補 → 共用一個快取語意一致;`ReadInfo` 每次新開 mgmt socket、`SO_RCVTIMEO 2 s`、≤ 8 事件 | `main.go:137-138, 598`;`health.go:55-87` |
| RB4-13 ✅ | h23:`set-provd-env` **每次都 restart provd**(init 只在 start 讀 env) | `254-h23-harness.md:254` |

## 1. BLOCKER

無。

## 2. MAJOR

**M1. §4.8 kernel patch 閘的 marker 來源寫錯了兩層,而這個閘是 `prov-sec-adv-len-254` 臂 2 不重現 F-P10 panic 的唯一防線。**
- 情境:harness 在 `-wbox` 上跑臂 2 前先看 `/etc/batman-build` 有沒有 `BATMAN_KPATCH_254_ADV=1`。設計說這個值「由 board patch 存在與否決定」、patch 放 `patches/ekh-bcm2711/0015-…` 與 `patches/ekh-bcm2710/` 各一份。
  - (a) **kernel patch 放不進 `patches/ekh-*/`**:那個機制只准碰 `feeds/`(RB4-2 的註解明說 `target/` 的 patch 在第二次 `-i` 會「previously applied」而讓 setup 停掉);`net/bluetooth/eir.c` 的修正必須是 **`target/linux/bcm27xx/patches-6.6/9xx-…patch`**,直接 commit 進 firmware 樹、**兩板共用一份**(RB4-3),不是「兩板目錄各一份」。這樣一來它也**不在 #275 的 board-patch 見證機制裡**(`check-board-patches.sh` / `patch-witness.sh` / `BATMAN_BOARD_PATCHES` 都只掃 `patches/<board>/`)→「由 board patch 存在與否決定」沒有東西可以決定。
  - (b) **`/etc/batman-build` 不能由 firmware PR「寫」**:它是 `stamp-batman-build.sh` 在 build 時產生的(RB4-1,「Never hand-edit」),所以 marker 必須是 stamp 腳本新增的一行,由一個明確的檢查決定(例如 `[ -f target/linux/bcm27xx/patches-6.6/9xx-bluetooth-eir-adv-flags-oob-254.patch ]`),而不是模糊的「patch 存在」。
  - 後果:實作者照 v4 文字做 → 要嘛 patch 進 `patches/ekh-*` 被 setup 擋掉、要嘛手寫 batman-build 違反 firmware 的規則;更糟的是閘的語意不清時,臂 2 可能在沒 patch 的 kernel 上被判「可跑」→ 重現 panic(A3-M3 要擋的正是這個)。
- 證據:RB4-1、RB4-2、RB4-3;設計 §2「board patch `0015-…`(兩板目錄各一份)」、§4.8「firmware PR 同時在 `/etc/batman-build` 寫 `BATMAN_KPATCH_254_ADV=1`(由 board patch 存在與否決定)」、§6「上游 CVE 修法 commit ⚠️」。
- 修:§2 / §4.8 改寫:(1) patch 落點 = `target/linux/bcm27xx/patches-6.6/9xx-bluetooth-eir-adv-flags-oob-254.patch`(firmware 樹本體、兩板共用;RB4-3 保證 kernel 自動重編);(2) marker 由 `stamp-batman-build.sh` 輸出:`BATMAN_KPATCH_254_ADV=$([ -f target/linux/bcm27xx/patches-6.6/9xx-… ] && echo 1 || echo 0)`(同一次 build 的 kernel 與 rootfs 同一個 slot image,所以 rootfs 的 marker 可代表該 slot 的 kernel;寫明這個依賴);(3) 節點閘 = `/etc/batman-build` 的 `BATMAN_KPATCH_254_ADV=1` **且** `-wbox` **且** `BATMAN_PROV_TEST=1`,缺一 → 單位 FAIL、不執行 `add-adv`(照 v4);(4) 把「kernel patch 不在 #275 見證內」寫進誠實界線,或把 stamp 的那行當它的見證;(5) L13:bcm2710 **自動**拿到 kernel patch(共用目錄),但 `patches/ekh-bcm2710/` 缺 0012 / 0013 bluez patch(RB4-4)→ L13 ❌ 的理由寫這個。負對照:stamp 在沒有該檔的樹跑 → marker=0 → 臂 2 FAIL 不執行(mutant:拿掉閘 → 會跑 `add-adv`)。

## 3. MINOR

**m1. 被移除的擁有者在 stale-while-revalidate 下的窗沒寫,而且既有的擁有者 session 永遠不會被降級。**
- 情境(P2 內就會發生:root `provclient verb owner.remove` 或 L78 的 record 改動;P3 後是 BLE `owner/remove`):(i) 被移除者的手機在 ≤ 4 s 輪詢 + `psks.get` 一趟內仍能用舊 `psk_owner[i]`(RB4-7:每 owner 一把,新集合才會少掉它)交握成 候選,`auth/owner` 對舊 `info.owners` 也過 → 擁有者角色 → 可讀 `info.net`(net_id / version / left)與 `unfinished`;改狀態動詞全被 helper 以已存 owners 拒絕(對)。窗常態 ≈ 5 s;若 `ops` 當時正排在一個改網動詞後面(F-P32)則到該動詞結束。(ii) **已經認證的 session**:設計只在「provd 自己的認領成功」時 Disconnect 其他 session;owner 被移除、`network/leave` 讓 `psk_member` 消失、generation 變,都不動既有 session → 被移除者保有擁有者角色直到 300 s 閒置或自己斷線,期間持續讀 `info.net`。協定沒規定(RB4-8),所以這是 provd 的角色模型缺口,不是違約;影響小(他本來就知道 net_id),但要寫明。
- 修:§4.3 快取段加一句:`info.owners` 新集合到手後,**任何 session 的 `owner_key_id` 不在新集合 → Disconnect**(成員 session 在 `psk_member` 消失 / 版本變時同理);誠實界線:新連線在重拉完成前(常態 ≤ 5 s、最壞到長動詞結束)仍以舊集合放行到「候選 / 擁有者」,只讀得到 `info.net`;`cache_test` 加「owners 少一把 → 該 session 在下一輪被斷」。

**m2. `ctl` 撞全域桶 `ERate` 時「新鮮」怎麼算沒寫;而 provclient 單獨就能把桶打滿。**
- 算術:accept ≤ 5 新連線/s × `provclient info` 每連線 2 個唯讀動詞(RB4-9)= **10/s = 全域桶的補充速率**;加 `ctl` 的 0.5/s 就是淨流出 → 一個持續打 `provclient info` 的迴圈幾十秒後桶空,`ctl` 的 `info.state` / `health.get` 隨機吃 `ERate`。§4.1「不新鮮 = 最近一次**成功**的 `info.state` 距今 > 60 s」→ `ERate` 不是成功 → 持續 60 s 就撤廣播 `reason=helper`。today 的 harness 沒有這種迴圈(RB4-9 ✅),所以是契約洞不是現場 bug;但 §1.3 寫「超過 `ERate` 不關連線、不算失敗」與 §4.1 的「成功」定義互相沒接上。
- 修:寫明 `ctl` 收到 `ERate` → 1 s 後重試、**不**重置新鮮計時(helper 活著但沒給 health 證據 → 仍 fail-closed);並把 `ctl` 的重連退避**封頂 10 s**(§4.5 的 1,2,4,…≤ 60 s 若套在 `ctl` 上,一次退避就能自己吃掉 60 s 窗)。選項:全域桶 15/s 或 provclient 單連線多動詞也計每連線桶(今天 provclient 一條連線 2 發,碰不到 5/s)。單元:fake helper 回 `ERate` 30 s → 不撤;60 s → 撤。

**m3. 啟動盤點的「等 `Connected` 轉 false(≤ 2 s)」剛好貼在 BlueZ 的 `DISCONNECT_TIMER = 2 s` 上。** RB4-6:`Device1.Disconnect` 先等 2 s 才送 mgmt DISCONNECT,回覆在 `Connected` 轉 false 時才來 → provd 等 2 s 必常常逾時而「重新盤點再試」。修:等 **方法回覆**(async,≤ 5 s),回錯(`NotConnected` / `Failed`)視為已斷不重試;另註:fd HUP 可能早於 `PropertiesChanged(Connected=false)`,「所有連線結束 → 重註冊前盤點」可能對一個正在斷的裝置再呼叫 Disconnect → 無害、不得迴圈。

**m4. L80 的負對照依賴 F-P41 ⚠️。** 「不盤點 → `RegisterAdvertisement` 持續 Failed」只在控制器不允許 peripheral 連線中開 connectable 廣播時成立;若 BCM4345C0 的 le_states bit 38/21 有,負對照不會 FAIL → 依規則不是負對照。修:負對照改成與 le_states 無關的斷言「不盤點 → 02 的連線 10 s 後仍 `Connected=true`;盤點 → ≤ 10 s 變 false」,`ActiveInstances=1` 另列為正向;F-P41 的 btmon 見證照做並回填 §1.2。

**m5. 盤點會斷掉合法擁有者的連線(benign restart UX)。** 現場:provd 只在 crash / 升級重啟,斷一次可接受、L80 已寫。harness:`set-provd-env` 每次 restart provd(RB4-13)→ 任何 sock / BLE 單位必須「先 set env、再連 peer」,否則自己的 peer 被盤點斷掉而誤判。§4.6 加這條規則一句。

**m6. 全域 accept 限速「超過關」會讓 provclient 直接死(`CONN-CLOSED`),它今天沒有重試。** 5/s 在 harness 序列呼叫下碰不到,但 §1.3 寫「provd / provclient 都要能退避重試」→ H3 的 provclient 要加「連上即 EOF → 退避 1 次重試」或 §10 第 2 點明寫不保證。

**m7. 殭屍連線(L81)在 crash loop 下的穩態要寫一句。** 每次重啟留一條卡在 `h(m)` / 等 `n.mu` 的 goroutine,cap 4 讓殭屍最多 4 條(之後的連線直接關、不佔 goroutine);穩態 = 動詞結束前 provd 與 provclient 全連不上,動詞結束後 ≤ 5 s 恢復。L81 文字對,補「上限 4、不會無限累積」。

**m8. 文字 / 一致性:** §12 第 1 步仍寫「本設計 v2 兩位整份重審」(應為 v4);§6「helper 契約…**單連線**」列是「今天」的事實、P2 後改多連線,標明;§2「board patch `0015-…`(兩板目錄各一份)」隨 M1 改;§9 單元列 `cache_test` 加 m1 的 owners 臂;§11 殘項加「被移除 owner 的 session 降級」若不在 P2 做。

## 4. 我核過、成立的(§15 說修了、我確認真的修了)

| v3 發現 | v4 | 結果 |
|---|---|---|
| A3-M1 helper 無 reason 文字 | `claim.verify` 回 6 ⇒ reason 10(推論 F-P38);21/22 無 detail 3;20 的處理 | ✅ 與 `node.go:170-173, 534-540` 一致;mutant 寫了 |
| A3-M2 / B3-m4 重拉中語意 | stale-while-revalidate;`psk_member` 新版本在 update 進行中走假路徑的誠實界線;L75 負對照「清快取 → 假 msg2」 | ✅ 與 RB4-7(`psk_owner` 由 TagKey、`psk_member` 綁 Version)一致;**退化只剩 m1 的 owner 移除窗**,沒有新的 fake-msg2 oracle(假路徑仍等長、同 DH、等逾時;長度檢查在 6 次試之前) |
| A3-M3 adv-len 臂 2 閘 | `BATMAN_KPATCH_254_ADV=1` 前置,不成立 FAIL 不執行 | ⚠️ 閘的**形狀**對,marker **來源**錯 → M1 |
| B3-M1 `gatt.sock` 目錄 | 兩個目錄照 h23(F-P42) | ✅ |
| B3-M2 provd 重啟時既有 LE 連線 | 啟動 / 重註冊前 `GetManagedObjects` → `Connected==true` → Disconnect;L80 | ✅ temporary 裝置確有 D-Bus 物件(RB4-5);Disconnect 路徑成立(RB4-6);時間與負對照見 m3 / m4 |
| B3-M3 每連線額度 churn | 全域 10/s 突發 40 + accept ≤ 5/s;churn mutant | ✅ 機制擋得住 churn;與 provclient 共用的邊界見 m2 |
| B3-m1 無保留位 | §3 誠實界線 + runbook「≤ 2 個 provclient」 | ✅ |
| B3-m2 / A3-m3 `ctl` 單則 10 s、在飛不 keepalive | §4.3 | ✅;`ctl` 每 4 s 兩發 → 永不閒置 20 s,keepalive 只對 `ops` 有意義(對) |
| B3-m3 / A3-m6 stale 撤銷 | `reason=helper`、`kill -STOP` 臂 | ✅ |
| B3-m5 `ops` 重連清對 | §4.3 | ✅ |
| B3-m6 / A3-m8 IsTrial 快取同步 | mutex + single-flight、與 `Committed()` 共用 | ✅ RB4-12 語意互補;鎖內 `dispatch` 與鎖外 `info.state` 共用一個 ≤ 5 s 快取,trial→committed 晚 5 s 只多撐 5 s `E_BUSY`,無安全面 |
| B3-m7 `info.net` `ERate` | `info` 不帶 9/10/11 | ✅ |
| B3-m9 三個 creator + scan rsp 臂 | §4.8 | ✅(落點見 M1) |
| B3-m10 / A3-m7 時間預算 | 4 s 輪詢、mgmt 並行、9.5 s 斷言 | ✅ 兩個 mgmt 查詢各自 socket(RB4-12)可並行 |
| B3-m11 假路徑不可擠 | §4.2 只影響 prov_test | ✅ |
| dbus policy 完整性 | §4.7 八條方法 | ✅ RB4-11:provd 要的 `Hello / AddMatch / GetNameOwner` 走 default 的 `org.freedesktop.DBus` allow;回覆走 `send_requested_reply`;接收四類 default allow;bluetoothd 回呼走 root 無 destination 的 `send_interface`;無缺口 |
| 殭屍連線、accept 限速 vs 退避 | §3 / L81 / §4.5 | ✅ 退避 1,2,4 遠低於 5/s;helper 重啟時 provd 2 條 + provclient 數條不會碰限速(m7 補穩態一句) |

## 5. 負對照盤點

| 防線 | 有 | 缺 |
|---|---|---|
| kernel patch 閘 | 臂 2 前置 FAIL | marker 來源(M1):stamp 在無 patch 樹 → marker=0 → 不執行 |
| 被移除 owner 的 session | — | owners 少一把 → session 被斷(m1) |
| `ctl` `ERate` 與新鮮 | — | fake helper 回 `ERate` 30 s 不撤 / 60 s 撤(m2) |
| 啟動盤點 | L80 臂 | 負對照改為「不盤點 → 02 仍 Connected」(m4);等待改方法回覆(m3) |
| stale-while-revalidate | L75、`cache_test` 延遲臂 | ✅ |
| 全域桶 churn | mutant | ✅ |
| `set-provd-env` 先於 peer | — | 規則一句(m5) |

## 6. 誠實界線

有寫且對:RPA 900 s;BLE 單連線被路人佔;ADV 自檢只擋自己;`adv_registered_once` 量 kernel;autocommit 只 WARN;被攻陷 provd 開滿 4 條 / 冒充 / Discoverable 廣播 / 洩 `info.net`;`psk_member` 在 update 進行中的空窗;無 provd 保留位;殭屍連線;F-P41 ⚠️;`model` fail-open;helper 重啟時 latch 時序。
要改:§4.8 / §2 的 patch 落點與 marker 來源(M1);L13 的理由(RB4-4);被移除 owner 的窗與既有 session(m1);`ctl` 撞 `ERate` 的新鮮語意(m2);§12 的「v2」。

## 7. 判定

**APPROVE-WITH-CHANGES** — 0 BLOCKER / 1 MAJOR / 8 MINOR。

v3 的六個 MAJOR 我逐一對原始碼重核,五個真的修掉了:reason 10 的推論站得住;stale-while-revalidate 與 helper 的 PSK 導出一致、沒有引入新的 fake-msg2 oracle,退化只剩「被移除 owner 多活一個輪詢窗 + 既有 session 不降級」(m1,影響小、要寫);`gatt.sock` 目錄照 h23;啟動盤點在 BlueZ 上成立(temporary 裝置確有 D-Bus 物件、Disconnect 路徑對),只是等待時間貼在 BlueZ 的 2 s timer 上、負對照依賴未驗的 le_states(m3 / m4);全域桶 + accept 限速擋得住 churn,與 provclient 共用的邊界要補一句新鮮語意(m2)。剩下的 MAJOR 是 A3-M3 的修法本身:閘的形狀對,但 marker 的來源寫錯 — kernel patch 進不了 `patches/ekh-*/`(機制只准碰 `feeds/`),`/etc/batman-build` 只能由 stamp 腳本產生;這是一個會重現 panic 的臂的唯一防線,所以仍是 MAJOR,修法是 §2 / §4.8 / L13 的幾段文字 + stamp 腳本一行。依通用規則 MAJOR 開著就要改 v5 並整份再審;本輪 04 連不上,F-P41 的 btmon 見證與 L10 / L11 的目錄 bind 實跑仍欠實機證據。
