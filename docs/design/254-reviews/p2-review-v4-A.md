# #254 PR-P2 `batman-provd` 設計 v4 — 對抗式審查 A(第 4 輪,整份重審)

審查者 A,2026-10-31。對象:`scratchpad/254-p2-impl.md` v4 全文 §0–§15。方法:從現場出發(認領、10 台一隊、路人、被攻陷的 provd、root 操作員),§13–§15「已修」一律不採信,逐條對原始碼重核;重點 = 第 3 輪 6 個 MAJOR 是否真的關了、修法有沒有帶進新問題(啟動 Disconnect 掃描、全域額度餓死 `ctl`、4 s 輪詢 vs 10 s 承諾、`BATMAN_KPATCH_254_ADV=1` 閘門、stale-while-revalidate 的安全面)。

## 0. 我自己核過的事(✅ 原始碼 / 實跑;⚠️ 推論;❌ 沒驗到)

| # | 事實 | 證據 |
|---|---|---|
| V1 ✅ | `sock.Serve` 今天仍是同步 accept 迴圈;`serveConn` 每連線自足(自己的 buf、每次 `Read` 前武裝 30 s deadline、`h(m)` 同步);PeerUID 拒絕在 `serveConn` 內 → `go s.serveConn` 改法成立(F-P6 / F-P45 正確) | `sock.go:107-116, 136-170` |
| V2 ✅ | `Node.Handle` 進門 `n.mu.Lock()`,verb 解析在鎖內;`dispatch` 對每個動詞先 `LoadOverlay`,無 record 只放行 `info.cert / info.ecdh_pub / info.boot_id / nonce`;`info.state` 回 `{1,2 Generation,3,4}`;`info.net` 回 `{1,2,3 Left}`(F-P26 / F-P44 正確) | `node.go:156-175, 203-247` |
| V3 ✅ | `verifyOwnerOp` 對 h 的每個未用 entry 逐一 `takeHelperNonce`(試一個刪一個);`claimReplay` 先 `takeNodeNonce` 再 `verifyOwnerOp`(F-P33 正確) | `node.go:612-619, 686-703` |
| V4 ✅ | `claimVerify`:`EUnsupported` 唯一來源 = legacy 且 `AuthorizedKeys()` 空(`no-ssh-key`),在 CheckMac 之後;**另一個 6 的來源 = `dispatch` 的 `LoadOverlay` 失敗 / `rec == nil`**(`node.go:203-207`),持鎖時撕裂讀排除,但 p5 讀不到(儲存故障、harness bind 蓋住)時會發生 → 見 m6 | `node.go:500-540` |
| V5 ✅ | `applyNet` step 3 `commitTxn`(gen+1、Member)在 step 4 `SaveTxn` 之前;`psks()` 的 `psk_member` 綁 `Net.Version`、`psk_owner` 綁 `TagKey`(F-P39 正確) | `node.go:391-411, 1131-1180` |
| V6 ✅ | BlueZ 對**進來的** LE 連線也建 `Device1` 物件:mgmt `Device Connected` → `connected_callback` → `btd_adapter_get_device`(不存在就建)→ `adapter_add_connection`;`Connected` 屬性 = `bredr_state.connected \|\| le_state.connected`;`Device1.Disconnect` → `dev_disconnect` → `device_request_disconnect` → 經 adapter 送 mgmt disconnect。**B3-M2 的修法(掃 `Connected==true` 再 Disconnect)在 BlueZ 5.72 上成立** | `adapter.c:9454-9509, 5228`;`device.c:1304-1316, 1839-1879, 2049-2064` |
| V7 ✅ | kernel `is_advertising_allowed`:`le_num_peripheral > 0 && connectable` 需 `le_states[4] & 0x40`(bit 38)與 `le_states[2] & 0x20`(bit 21),否則 `hci_enable_advertising_sync` 回 `-EINVAL`(F-P41 正確);斷線後 `hci_enable_advertising` 在 `adv_instances` 空且無 `HCI_ADVERTISING` 旗標時直接 return(provd 已 Unregister 時 kernel 不會重開空廣播) | `hci_sync.c:1007-1044, 1873-1875, 1941-1948`;`hci_event.c:3421-3424` |
| V8 ✅ | bluetoothd **乾淨停止** `adapter_shutdown` 對每個 powered adapter 送 `SET_POWERED 0`(→ 連線全斷);**啟動**時 `load_connections` 送 mgmt `GET_CONNECTIONS` 重建連線中的 `Device1`(crash 重起的話既有連線會被重新列為 `Connected=true`) | `adapter.c:10915-10939, 5244-5296, 9392` |
| V9 ✅ | **board patch 機制只准碰 `feeds/`**:`openmanet_setup.sh` 註解明寫「patches/<board>/ must only touch feeds/ … a patch of package/ or target/ would be "previously applied" on the second -i and stop setup」;`check-board-patches.sh` 以 `patch -p1 -R --dry-run` 對 tree 反向套用驗「已套用在 feeds/」;現有 11 個 board patch 的 `+++` 路徑全在 `feeds/`。**kernel patch 的既有做法 = `target/linux/bcm27xx/patches-6.6/999-batman-*-305.patch`,一份給兩個 subtarget**(ekh-bcm2710 / ekh-bcm2711 都是 `CONFIG_TARGET_bcm27xx`) | `scripts/openmanet_setup.sh:124-162`;`scripts/check-board-patches.sh`;`patches/ekh-bcm2711/*.patch`;`target/linux/bcm27xx/patches-6.6/999-batman-hci_bcm-close-flow-305.patch`(commit 1524084e);`boards/ekh-bcm27*/target_diffconfig` |
| V10 ✅ | `/etc/batman-build` 由 `scripts/stamp-batman-build.sh` 產生,**key 清單固定**(`BATMAN_VERSION / BOARD / CHANNEL / MILESTONE / BUILD_DATE / BASE / FEED_COMMIT / FW_COMMIT / FW_FEED_PIN / DIRTY / BOARD_PATCHES=<n>:<digest> / FEATURES / NOTE / [WBOX]`),沒有任何 `KPATCH_*`;#275 的 patch witness(`/etc/batman-patch-witness`)只涵蓋 `patches/<board>/`;`batman-autocommit:486-490` 刻意讀 `/rom/etc/batman-build`(overlay 的那份可被改) | `scripts/stamp-batman-build.sh:60-77`;`scripts/patch-witness.sh:1-20`;`batman-autocommit:486-527` |
| V11 ✅ | 既有 kernel patch 的節點端閘門範式 = `bt-uart-305.sh` 以 `BATMAN_FW_COMMIT` 對應工具目錄(`FWCOMMIT` 相等才 stage) | `scripts/dv/bt-uart-305.sh:10, 18, 24-32` |
| V12 ✅ | harness 對 helper socket 的使用:46 處 `provclient`,**全部前景、一次一連線、沒有 `&` 背景並行**;輪詢迴圈都有 `sleep 5–15`;`PROVCLIENT_TIMEOUT_S` 預設 30 s → 正常全套下 471 主體的唯讀動詞速率 ≪ 10/s | `grep provclient scripts/dv/*.sh`;`provclient/main.go:355-370` |
| V13 ✅ | `provclient` 今天的 op 清單 = `info / claim / claim-attacker(-chal) / replay / ssh-keys / root-reset / rename / verb / node / sign / keygen / selftest`;**沒有 `proxy`**;`verb` 是「無參數動詞」 | `provclient/main.go:490-640` |
| V14 ✅ | `health.go`:`ReadInfo` 每次新開 mgmt socket、`SO_RCVTIMEO` 2 s;`Tick` 寫檔 + `poweredFor` + `ble-ok`;`btdPid` 掃整個 `/proc`(F-P27 正確) | `health.go:55-87, 130-170`;`main.go:638-651` |
| V15 ✅ | init 順序:bluetoothd S61、helper S89(STOP 15)、provd S92(本設計)→ 正常開機 provd 起來時 helper.sock 目錄已在(L77 的「正常不會發生」成立) | `batman-ble/files/bluetoothd.init`;`batman-prov/files/batman-provhelper.init` |
| V16 ✅ | 219 §8:同時 BLE 連線 2、未認證 30 s 可被擠、全域交握 20/分、`nonce_helper` ≤ 4 / session;stage1 §4.1 health 契約「ts 超過 60 s 讀者當全 0」;autocommit `health_ok()` 只在 `ble-ok` 存在時看 health、`adv_registered_once=1` | `219-protocol.md:370-386`;`254-stage1-impl.md:129, 420` |
| V17 ❌ | **節點 04 今天連不上**(`ping 10.41.1.3` 100% loss、ssh 三次 timeout)→ 本輪沒有任何上機實證;F-P1–F-P5、F-P23 沿用前三輪;F-P41 le_states 仍 ⚠️ | 15:4x 三次 |
| V18 ⚠️ | bluetoothd 被 SIGKILL(非乾淨停止)時 kernel 是否保持 adapter powered、既有 LE 連線是否存活:`hci_sock_release` 對 `HCI_CHANNEL_CONTROL` 只送 monitor 事件、未見 power off → 推論「連線留著」,未實測 | `hci_sock.c:894-920` |

## 1. 第 3 輪 6 個 MAJOR 的實際修復狀態(逐項重驗,不看 §15)

| 第 3 輪 | v4 處置 | 我的判定 |
|---|---|---|
| A3-M1 helper 無 reason 文字 | 選 (a):`claim.verify` 回 6 ⇒ reason 10(推論 F-P38);21/22 → 11 無 detail 3;20 的處理 | **關閉**,但推論有一個漏洞(V4):`dispatch` 的 `LoadOverlay` 失敗也回 6,持鎖不排除 p5 讀不到的情況 → m6 |
| A3-M2 重拉中語意 / 成員 update 空窗 | §3 / §4.3「失效 = 標記待重拉,舊集合繼續服務」+ F-P39 誠實界線 + L75 負對照 | **關閉**;新引入的安全面(擁有者被移除後舊集合仍服務)見 m3 |
| A3-M3 adv-len 臂 2 無閘 | §4.8 `BATMAN_KPATCH_254_ADV=1` 前置 | **沒關**:閘門與 patch 位置都沒有可用的機制(V9 / V10)→ **M1** |
| B3-M1 `gatt.sock` 目錄所有權 | §1.3 / §3 / §4.5 改回 h23 :139 的兩個目錄 | **關閉**(與 h23 §4.1 表逐字一致) |
| B3-M2 provd 重啟時既有 LE 連線 | §4.4 啟動 / 重註冊前掃 `Connected==true` → Disconnect;L80 | **關閉**(V6 / V7 證實機制成立);附帶後果見 m1 / m2 |
| B3-M3 每連線額度 churn 歸零 | 全域 10/s 突發 40 + accept ≤ 5/s + churn mutant | **關閉**;與 provd 自己的 `ctl` 重連互動見 m4 / m5 |

## 2. BLOCKER

無。

## 3. MAJOR

**M1. §4.8 的 kernel patch 放錯管道、`BATMAN_KPATCH_254_ADV=1` 沒有寫者;臂 2 的閘門照 v4 寫法做不出來,而它是 harness 與一次已實證的 kernel panic 之間唯一的東西。**
- 情境:實作者照 §4.8 把 `0015-bluetooth-eir-adv-flags-oob-254.patch` 放進 `patches/ekh-bcm2711/` 與 `patches/ekh-bcm2710/`。(1) 這條管道是 `openmanet_setup.sh patch_feeds_packages`,`patch -N -p1` 打在 firmware tree 根,**註解明寫只准碰 `feeds/`**:碰 `target/` 的 patch 在第二次 `-i` 會「previously applied」讓 setup 停掉(V9);`check-board-patches.sh` 與 #275 witness 也都是為 feeds/ 設計的。(2) 既有的 kernel patch(#305 兩個)都在 `target/linux/bcm27xx/patches-6.6/999-batman-*.patch`,**一份**同時進 bcm2710 / bcm2711(兩板都是 `CONFIG_TARGET_bcm27xx`,V9),不是「兩板目錄各一份」。(3) `BATMAN_KPATCH_254_ADV=1` 要「由 board patch 存在與否決定」寫進 `/etc/batman-build`,但 `stamp-batman-build.sh` 的 key 清單固定、沒有這個 key、也沒有任何「依 patch 存在與否」的邏輯(V10)→ firmware PR 要嘛自己發明一個 stamp 外的寫法(違反「Never hand-edit it」),要嘛這行永遠不會出現 → 臂 2 永遠 FAIL(至少安全)。(4) 即使寫進去了,閘門讀的是 `/etc/batman-build`(overlay 可寫)不是 `/rom/etc/batman-build`(autocommit 刻意用 /rom 的理由,V10),且它是**同一個 PR 自我宣稱**的一行字,不是 patch 真的在 kernel 裡的證據:patch 套用與否由 OpenWrt quilt 決定,一個 `.rej` 或 kernel bump 後 fuzz 失敗都不會改變這行。閘門若放行而 kernel 其實沒 patch = F-P10 的 panic 在全套中間重現(2026-10-18 規則)。
- 證據:`scripts/openmanet_setup.sh:124-162`;`scripts/check-board-patches.sh`;`target/linux/bcm27xx/patches-6.6/999-batman-hci_bcm-close-flow-305.patch`;`scripts/stamp-batman-build.sh:60-77`;`batman-autocommit:486-490`;設計 §2「board patch … 兩板目錄各一份」、§4.8 全段、§9 臂 2。
- 修:
  1. patch 位置改為 `target/linux/bcm27xx/patches-6.6/999-batman-eir-adv-flags-oob-254.patch`,一份;標頭照 #305 範式(`Written against kernel 6.6.138; downstream, rebase on kernel bumps`)+ 上游 commit id;§2 / §4.8 / §6 / L13 同步改。
  2. 閘門改用**已有的真憑據**:節點 `/rom/etc/batman-build` 的 `BATMAN_FW_COMMIT`(與 `bt-uart-305.sh` 同一套,V11)。harness 主機在 pinned firmware tree 上 `git merge-base --is-ancestor <加入 999 patch 的 commit> <BATMAN_FW_COMMIT>` 且 `BATMAN_DIRTY=0`(dirty build 可能本地拿掉 patch)且 `BATMAN_WBOX` 非空且 `BATMAN_PROV_TEST=1`;任一不成立 → 單位 FAIL、絕不 `add-adv`。kernel 的 patch 本來就沒有 rootfs witness(#275 的 `none` 類)→ 把「唯一可見證據 = fw commit 祖先關係」寫進單位 header 與 §6。
  3. 若仍想要 image 內一行字,走 #275 機制(patch-witness `none <reason>`)而不是發明新 key;但它不能代替 2。
  4. §9 / §8 第 7 列把「臂 2 前置」的描述換掉;L68 同步。

## 4. MINOR

**m1. 啟動 / 重註冊前的 Disconnect 掃描會打掉每一條合法連線,包括 `set-provd-env` 無害重啟時 02 / 手機的連線;設計沒把這個後果寫進契約。**
- 情境:harness 每次 `set-provd-env` 都 restart provd(h23 :254);02 連著 → 新 provd 起來先 Disconnect 02 → 任何在 provd restart 前後跨越的 sock / BLE 單位都要預期「連線必斷、重新交握」;現場:provd crash 時擁有者手機被斷(但它的 session 本來就死了:GATT app 已被 BlueZ 釋放,F-P41)→ app 只能照 219 §3.7「連線中斷 → 重新交握」處理。這是對的選擇,但要寫明:(a) 219 §3.7 / app 契約「節點端任何重啟都會主動斷線」;(b) h23 §4.8.3 `set-provd-env` 的後果;(c) L80 把「合法擁有者連著時 provd 無害重啟」列為情境(今天只寫 crash / respawn)。
- 證據:V6;設計 §4.4 第 3 點、L80;h23 :254。
- 修:三處補一句;`prov-respawn-254` L80 臂加「02 以擁有者 session 連著 → restart → 02 看到 disconnect → 重新交握成功」。

**m2. L9「bluetoothd 重啟 → 既有連線已斷」只對乾淨停止成立;crash 路徑 bluetoothd 會把既有連線重新列為 `Connected=true`,掃描要在這裡也跑(設計文字沒明說)。**
- 情境:bluetoothd 被 OOM / SIGKILL(L65)→ kernel 不 power off(V18 ⚠️)→ 手機 LE 連線留著 → 新 bluetoothd `load_connections` 重建 `Device1 Connected=true`(V8)→ provd 收 `NameOwnerChanged` 後若直接 Register → F-P41 的 `Failed`。§4.4 的「啟動 / 重註冊前」字面上涵蓋,但 L9 / L65 寫「既有連線已斷」會讓實作者在這條路徑省掉掃描。
- 證據:`adapter.c:10915-10939`(乾淨停止才 power off)、`5244-5296, 9392`(啟動重載連線)。
- 修:L9 改「乾淨重啟:`adapter_shutdown` power off → 連線全斷;crash:連線可能留著且被新 bluetoothd 重列 → 同 §4.4 掃描」;L65 引 L9 的 crash 分支;`prov-dep-restart-254` bluetoothd 臂加 `kill -9` 變體(02 連著)。V18 標 ⚠️ 進 §6。

**m3. stale-while-revalidate 的安全面:generation 由旁路改變時,既有已認證 session 的角色與舊 PSK 集合都繼續有效到新集合回來,設計只寫了「不斷既有匿名 session」。**
- 情境:P2 的 BLE 沒有 `owner/remove`(P3),但 root 旁路(`provclient`、未來 P3、helper 重建 record)會縮小 owners / 換 `psk_member`。期間:(a) 已拿到擁有者 / 成員角色的 session 繼續被 provd 當擁有者 / 成員 → `info.net`(`net_id`、`version`、`unfinished`)繼續給它(helper 這個動詞無授權,靠 provd 的角色閘);改狀態動詞 helper 會擋(owner-op 驗章)。(b) 舊 `psk_owner` / `psk_member` 在 `psks.get` 回來前仍能交握(`ctl` 4 s 看到 generation → `psks.get` 排 `ops`,若恰有長動詞在跑最壞 ≈ 960 s)。資產是 `net_id` 一類中等機密,不是金鑰;P2 內只有 root 能觸發 → MINOR,但 P3 `owner/remove` 上線就是 MAJOR。
- 證據:設計 §3 快取列、L78「既有匿名 NX session 不斷」;`node.go:238-240`(`info.net` 無授權)。
- 修:§3 / §4.3 加一條 fail-closed 規則:**非 provd 自己動詞造成的 `Generation` 變化 → 所有已認證(擁有者 / 成員 / 候選)session 立即 Disconnect**(匿名 NX 不動);它們以新集合重新交握。成本 = 零(root 改 record 本來就極少);P3 的 `owner/remove` 直接沿用。L78 改寫;`cache_test` 加一臂。

**m4. `ctl` 的 ERate 會算進「不新鮮」計時 → 60 s 的 helper-dead 判定可以被額度撞出來;且 `ctl` 的 10 s 重連在 helper SIGSTOP 期間會在 backlog 堆連線,SIGCONT 後 accept 限速可能把 provd 自己的活連線關掉。**
- 情境 A:§4.1「不新鮮 = 最近一次**成功**的 `info.state` 距今 > 60 s」;`ERate` 不是成功。正常負載(V12)撞不到 10/s,但 `provclient` 在 60 s 內若有人手動迴圈(運維 debugging)→ provd 撤廣播 `reason=helper`,誤歸因。情境 B:helper `kill -STOP` 65 s(L71 臂):`ctl` 每 10 s 關 + 重連 → connect() 進 backlog 成功 6 次;SIGCONT → helper 一口氣 accept 7 條(6 條已被 provd 關 → `Read` EOF 立即結束,但 accept 計數 > 5/s)→ 第 6、7 條(可能是 provd 現在活著的 `ctl` / `ops`)被 accept 限速關掉 → provd 再退避重連;L71 的「≤ 65 s 撤廣播」仍成立,但恢復重註冊會多一輪退避,L71 若斷言恢復時間會抖。
- 證據:設計 §4.1 不新鮮定義、§4.3 `ctl` 10 s 重連、§1.3 accept ≤ 5/s;`sock.go` Listen 用 Go 預設 backlog。
- 修:(a) 不新鮮計時只對「非 `ERate` 的失敗 / 無回應」累計,`ERate` 時 `ctl` 0.5 s 後重試一次;(b) `ctl` 重連退避 10, 20, 40 s(上限 60);(c) accept 限速只對**通過 PeerUID 且第一個 `Read` 成功**的連線計數(被 provd 自己關掉的死連線不算),或限速改成「每秒超過 5 條時延遲 accept」而不是關;(d) L71 的 SIGSTOP 臂斷言「恢復後 ≤ 30 s 重註冊」。

**m5. 撤廣播 10 s 預算的計算漏了兩項,實際最壞 ≈ 9–13 s。**
- 情境:§4.4 寫 4 + 2 + 1 ≈ 7 s、L67 斷言 9.5 s。但 §4.3 把 `health.get` 的 `compute()` 與 tick **single-flight 共用**:bondable 在 tick 的 compute 開始後 ε 翻 1,`ctl` 請求 join 那次 compute → 拿到翻 1 前的結果(+2 s);`ctl` 一輪是 `health.get` → `info.state` 兩則**同步**(各 ≤ 2 s);再加 m4 的一次 `ERate` 跳過一輪(+4 s)→ 4 + 2 + 2 + 1 = 9 s 常態最壞,13 s 若撞額度。
- 證據:設計 §4.3 唯讀動詞列「與 tick 共用、single-flight」、§4.4 時間預算、L67。
- 修:single-flight 只合併「compute 尚未開始」的請求(或 `health.get` 回應帶 compute 起始 uptime,provd 丟掉比上次輪詢更舊的);`ctl` 每輪 `health.get` 先送、輪詢週期以**送出時刻**算 4 s;配合 m4(a)。L67 的 9.5 s 保留,但預算表改寫成 4 + 2 + 2 + 1 並說明 single-flight 的邊界。

**m6. F-P38「持鎖的 `claim.verify` 回 6 ⇒ no-ssh-key」的推論有第二個來源:`dispatch` 的 `LoadOverlay` 失敗。**
- 情境:p5 在執行期讀不到(儲存故障;harness bind 蓋住 record;`prov-wbox` 的 `unbind-all` 競態)→ `dispatch` 在進 `claimVerify` 之前就回 6 → provd 告訴 app「這台沒 SSH key」(reason 10),使用者去加 key,問題其實是儲存。
- 證據:`node.go:203-207`(`fail(EUnsupported, "no usable provisioning record")`,對 `claim.verify` 不在放行名單);F-P38 只排除了「撕裂讀」與「開機後一定存在」。
- 修(擇一):(a) 保留推論,但 provd 在收到 6 前先用 `ctl` 的最後一次 `info.state` 判 state:state 不是 legacy(3)→ 不帶 reason 10、只回 `E_UNSUPPORTED{capability:"claim"}` + log;(b) 真修:helper 錯誤回應 key 3 加 `{1: <reason-code uint>}`(數字,不是文字,無洩密問題;`no-ssh-key` = 10、`no-record` = 1),§2 helper 改動 + 單元。(b) 一行改動,建議直接做。

**m7. `provclient sock-as 471 -- proxy` 今天不存在,設計把它當既有事實引用。**
- 證據:V13(op 清單無 `proxy`);設計 §3 `/tmp/run/batman-provd-test/` 列「harness(root `provclient sock-as 471 -- proxy`)」、§1.3 F-P42 列。
- 修:F-P22 補「無 `proxy`」;§2 harness 項列「`provclient` 加 `proxy`(H3 PR)」;§12 工作順序 3 明寫 H3 含它。

**m8. GATT app 與廣播的註冊順序沒寫。**
- 情境:先 `RegisterAdvertisement` 再 `RegisterApplication`(或 bluetoothd 重啟後只重做其中一個)→ 手機連上後找不到服務 → iOS 快取空服務表。
- 修:§4.4 註冊前置加「`RegisterApplication` 成功後才 `RegisterAdvertisement`;`UnregisterApplication` 前先撤廣播」;L9 同。

**m9. L81 殭屍連線佔名額可以便宜地減輕,設計直接列為誠實界線。**
- 情境:長動詞 ≈ 960 s 期間 provd 重啟 2 次 → `provclient` 被拒;3 次 → provd 自己的第 2 條被拒。
- 修(可選,寫成殘項即可):helper 每連線開一個 watcher goroutine `poll(POLLRDHUP)`,對端掛斷即把名額釋放(goroutine 本身仍卡在 `h(m)` 到動詞結束,但不再佔名額);單元:持鎖 30 s 期間 client 關連線 → 第 5 條立刻被接受。

**m10. 文字 / 一致性。**
- §12 第 1 步寫「本設計 **v2** 兩位整份重審」→ v4。
- §6 F-P41 列說「實作第一步以 btmon 見證」,但 04 今天不可達(V17)且 P-U18 禁止在 04 試廣播 → 見證方法要寫清楚是「只 btmon 看連線中 `RegisterAdvertisement` 的 mgmt status」(不用自己註冊 31 B)或在 02 上做;否則第一步就卡。
- §1.3「`-wbox` 變體 image 加裝 `btmgmt`」與 M1 的閘門一起寫進 §9 release gate(已有)✓;但 §8 第 7 列「臂 2」的引用要跟 M1 改。
- F-P1–F-P5、F-P23 的「2026-10-31 唯讀實查」是上午的;本輪未能重核,v5 若引用請保留日期。

## 5. 擁有權 / 契約 / 矩陣補充(未列為 finding)

- §3 廣播 instance 列的「kernel 第二寫者」:V7 證實 provd 已 Unregister 時 kernel 的斷線重開是 no-op(`adv_instances` 空),所以「手機快連快斷時 kernel 已重開而 provd 的 Unregister 才到」只在 provd 來不及 Unregister 的窗內成立;可以把這句收窄,降低實作者對「foreign instance」誤判的機會。
- §3 helper socket 連線列:PeerUID 拒絕「不佔名額」✓;但 accept 限速的計數對象(全部 accept 還是通過 PeerUID 的)沒寫 → m4(c)。
- 矩陣缺一列:**bluetoothd crash(非乾淨)且手機連著**(m2);**provd 無害重啟且擁有者連著**(m1)。
- L10 dbus 重啟:dbus 重啟後 bluetoothd 也重起 → 走 L9 乾淨路徑(power off)✓。

## 6. 安全(逐 actor,只寫本輪新面)

- **root 操作員 / 我們自己**:M1 — 閘門不是證據;一次誤判 = 節點 panic + 遺失 logread。負測試:在**未** patch 的 fw commit 上跑臂 2 → 單位 FAIL 且 btmon 無 `Add Advertising`。
- **路人 → 攻陷 provd**:v4 新放行 `Device1.Disconnect` + `GetManagedObjects` → 可斷任何 LE 連線、看到連線中手機的 RPA;§8 已含「斷線」,RPA 列表是零增量(RPA 本身無法追蹤)。✓
- **被移除的擁有者 / 成員(P3 前只有 root 能移)**:m3 — 舊集合 + 舊角色在重拉窗內仍有效,fail-open 的時間窗 ≤ 4 s + `psks.get` 排隊;修法零成本。
- **運維 `provclient` 誤用**:m4(A)— 額度撞出假的 helper-dead 撤廣播;無安全後果,只有可用性與誤歸因。
- 負對照盤點:M1 修後臂 2 的負對照 = 「未 patch commit → FAIL」可在主機端單元做(不碰節點);m3 的負對照 = `cache_test` 不斷 session → 舊角色仍能讀 `info.net` → FAIL。

## 7. 判定

**APPROVE-WITH-CHANGES** — 0 BLOCKER / 1 MAJOR / 10 MINOR。

第 3 輪 6 個 MAJOR 中 5 個真的關了(我自己對 BlueZ / kernel / helper 原始碼核過 B3-M2 的機制成立、B3-M1 與 h23 一致、B3-M3 的全域桶在 harness 的真實負載下不會誤傷、A3-M1 / A3-M2 的改寫正確);A3-M3 的「閘門」沒關:kernel patch 放進了只准碰 feeds/ 的 board-patch 管道,`BATMAN_KPATCH_254_ADV=1` 在 stamp 腳本裡沒有寫者,而且就算有也是自我宣稱不是證據。M1 修法明確(改用 #305 的 `999-batman-*` 位置 + `BATMAN_FW_COMMIT` 祖先閘門),改完不影響其他章節的結構;MINOR 以 m3(fail-closed 一句話)、m4 / m5(時間預算與額度互動)、m6(reason 推論的第二個來源)為先。本輪沒有上機(04 不可達,V17),所有 ⚠️ 維持。
