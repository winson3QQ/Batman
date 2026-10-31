# #254 PR-P2 `batman-provd` 設計 v5 — 對抗式審查 B(第 5 輪,整份重審)

審查對象:`scratchpad/254-p2-impl.md` v5 全文 §0–§16。方式:從現場出發(擁有者在 BLE 上做 `network/join` 而 root 同時跑 `provclient`、被移除的 owner、路人、被攻陷的 provd、helper / bluetoothd / provd 各自重啟、harness 在 `-wbox` 上跑 kernel patch 臂),§13–§16「已對應」一律不採信,逐條對原始碼重核。分工 B:最終模型下的並行與時序(session 撤銷 vs 在飛請求;自己的 `network/join` 也 bump `Generation` 時會不會誤撤)、`ERate` / 不新鮮互動、`Device1.Disconnect` async 等待、Noise 假 msg2 等長與 PSK 時序、GATT 快取新鮮度、dbus policy、kernel patch 閘門的憑據(`BATMAN_FW_COMMIT`、`-wbox` 的 `DIRTY` 語意、主機側 pinned tree)、負對照、誠實。

**環境誠實界線**:04(10.41.1.3)`ssh -o BatchMode=yes -o ConnectTimeout=10` 一次 → `Connection timed out` → **本輪沒有任何 04 實機輸出**;F-P* 的實機事實沿用前四輪核過的。我核的是原始碼:repo main `34f216d`、firmware `/home/yello/firmware-2710` HEAD `da30986f`(`1.8.0-161-gda30986f`,工作樹乾淨)、BlueZ 5.72 / dbus 1.14.10 build 樹、`flynn/noise@v1.1.0`。

## 0. 我自己核過的事實(✅ 原始碼;⚠️ 推論;❌ 未能上機)

| # | 事實 | 證據 |
|---|---|---|
| RB5-1 ✅ | **`stamp-batman-build.sh` 對任何 `-wbox` 變體強制 `DIRTY=1`**:`WBOX=${BATMAN_WBOX:-}`;`case "$WBOX" in '') ;; … *) DIRTY=1; why="$why wbox-$WBOX"`;VER 加 `.dirty.wbox-<name>`;`BATMAN_WBOX=` 行只在非空時輸出;**`why`(dirty 的原因)只印到 stdout,不進 `/etc/batman-build`**;檔內 key 固定 = VERSION / BOARD / CHANNEL / MILESTONE / BUILD_DATE / BASE / FEED_COMMIT / FW_COMMIT / FW_FEED_PIN / DIRTY / BOARD_PATCHES / FEATURES / NOTE / (WBOX) — **沒有 `BATMAN_PROV_TEST`** | `scripts/stamp-batman-build.sh:38-44, 54-57, 60-75`;h23 `254-h23-harness.md:183` 自己也寫「`BATMAN_WBOX` 有值 → `DIRTY=1` 強制」 |
| RB5-2 ✅ | `BATMAN_FW_COMMIT` = `printf %.7s $(git rev-parse HEAD)`(7 字元);`DIRTY` 的四個來源 = tracked 改動、build 輸入下的 untracked 檔(含 `target`)、`feeds.conf` 覆寫、`feeds/batman` 修改;`build-board.sh:84-94` 對 BASE(`package target include …`)髒樹預設拒建,`BATMAN_ALLOW_DIRTY_BASE=1` 放行為「test build only」 | `stamp-batman-build.sh:36-44, 53, 68`;`build-board.sh:80-95` |
| RB5-3 ✅ | `BATMAN_PROV_TEST=1` 在節點上唯一的痕跡 = helper 二進位的 marker 字串 `BATMAN_PROV_TEST_BUILD_7f3a`(`seam_provtest.go:29`;`--version` 第 2 行;h23 §4.7 preflight 用 `grep -c`);`lib-wbox.sh:83-84` 只 export 給 build,`Makefile:26-27` 轉成 `GO_PKG_TAGS=prov_test` | 原始碼 |
| RB5-4 ✅ | **harness 今天沒有任何 `merge-base` / `is-ancestor` / firmware-tree 路徑變數**:`grep -rn 'merge-base\|is-ancestor\|FW_TREE\|DV_FIRMWARE' scripts/dv/*.sh scripts/*.sh` = 0;`bt-uart-305.sh:18,24` 只是讀 `BATMAN_FW_COMMIT` 去挑 `$BT305_ROOT/bt305-<fw>/` 工具目錄(沒有就 NOTE 不 FAIL),**不是祖先檢查**;唯一寫死的 firmware 樹路徑是 `dv-provclient-tools.sh:11` 的 `GO=` 預設值 | `scripts/dv/bt-uart-305.sh:9-10, 18, 24-33`;`scripts/dv-provclient-tools.sh:11` |
| RB5-5 ✅ | `target/linux/bcm27xx/patches-6.6/` 現有 4 個 `999-batman-*`(兩個 `-305`、兩個 memcg),commit `1524084e`(#305);`openmanet_setup.sh:147-148` 註解明寫 `patches/<board>/` 不得碰 `package/`、`target/`;`check-board-patches.sh` 只掃 `patches/$B/` | `ls`;`git log`;原始碼 |
| RB5-6 ✅ | helper `Handle` 進門 `n.mu.Lock()`(`node.go:157-158`);`applyNet`:`next.Generation = rec.Generation + 1`(`:1134`)→ step 3 `commitTxn`(`:1166`,overlay 寫入 = 無鎖 `info.state` 可見)→ step 4 `SaveTxn`(`:1172`,≤ 300 s)→ 才回;`leave` 同構(`:1192-1205`);`ownerAdd` / `ownerRemove` / `ssh_keys` `Generation++`(`:831, 877, 904`);`info.state` 回 `{1: State, 2: Generation, 3: len(Owners), 4: RadioManaged}`(`:235`) | 原始碼 |
| RB5-7 ✅ | wireless-txn §19.4:一個動詞可先跑 Finish(setkey ≤ 180 + save)再做自己的 → 一次 `net.apply` 期間 overlay 的 `Generation` **可能 bump 兩次**(Finish 的 commit + 自己的 commit);「client 的逾時不是節點的上界」 | `254-wireless-txn.md:627-631` |
| RB5-8 ✅ | BlueZ `dev_disconnect` → `device_request_disconnect(device, msg)` → **回 `NULL`(延後回覆)**;msg 只在 `btd_device_is_connected(device) && msg` 時排進 `device->disconnects`(**已不連線時 msg 既不排隊也不立即回覆**);`disconn_timer` 已在跑就 return(重複呼叫無害、不重排);timer = `DISCONNECT_TIMER` 2 s → `disconnect_all` → mgmt DISCONNECT;回覆在 `Connected` 轉 false 時 `g_dbus_send_reply` | `device.c:69, 1715-1731, 1849-1895, 2049-2064, 3332-3340` |
| RB5-9 ✅ | `flynn/noise` `ReadMessage`:`if len(message) < expected { ErrShortMessage }` → **較長的 msg1 不拒**;psk0 的 `MessagePatternE` 後 `willPsk → MixKey(re)`,`S` 在 `hasK` 時 `expected += 16`;失敗 `Rollback()` | `state.go:516-548` |
| RB5-10 ✅ | dbus `config-parser.c` 對 `<policy user="x">` 的未知使用者只 `_dbus_warn("Unknown username …")` 不拒啟(provd uid 471 由 package `USERID` 烘進 image,正常不會缺) | `bus/config-parser.c:1131, 1771` |
| RB5-11 ✅ | `bluetooth.conf` 現況:root policy = `own`、`send_destination=org.bluez`、六條無 destination 的 `send_interface`(`Agent1 / GattCharacteristic1 / GattDescriptor1 / LEAdvertisement1 / ObjectManager / Properties`);無 default policy;註解已預留「batman-provd gets its own `<policy user>`」 | `package/batman/batman-ble/files/bluetooth.conf` |
| RB5-12 ❌ | 04 實機:本輪連不上;F-P41(le_states)、L10 / L11 目錄 bind 實跑仍欠實機證據(與前兩輪相同) | ssh timed out |

## 1. BLOCKER

無。

## 2. MAJOR

**M1. §4.8 臂 2 的閘門自相矛盾:`BATMAN_DIRTY=0` 與 `BATMAN_WBOX` 非空在 stamp 腳本裡是互斥的 → 閘門永遠不成立 → kernel patch 的唯一正向見證永遠不會跑;而且 `BATMAN_PROV_TEST=1` 在 `/etc/batman-build` 裡根本沒有這個 key。**
- 情境:harness 在 `-wbox` image 上跑 `prov-sec-adv-len-254` 臂 2。讀 `/rom/etc/batman-build`:`BATMAN_WBOX=<name>` 在 → 依 RB5-1 這個 build 的 `BATMAN_DIRTY` **必為 1**(stamp 腳本第 56 行強制;h23 §4.2 :183 自己寫明)。閘門要 `DIRTY=0 && WBOX 非空` → 永遠 FAIL、永遠不執行 `add-adv`。結果是 fail-closed 沒錯,但 D3(kernel patch)從此**沒有任何真機正向見證**:patch 有沒有真的進 kernel、三個 creator 有沒有都修到,整套只剩「負對照 = F-P10 的舊紀錄,不再重現」。這張單的 kernel patch 是「被攻陷的 provd 註冊 31 B → panic」的唯一擋法(§4.4、§8),它的見證不能是一個死閘。
- 第二層:閘門第四個條件 `BATMAN_PROV_TEST=1` 沒有來源——stamp 不寫它(RB5-1 key 清單),`lib-wbox.sh` 只 export 給 build(RB5-3)。實作者照 v5 讀 `/etc/batman-build` 找這個 key → 永遠找不到。節點上唯一痕跡是 helper 的 marker 字串(h23 §4.7 preflight 已在用)。而且臂 2 只用 root `btmgmt`,根本不需要 prov_test helper;這個條件是多餘的。
- 第三層:`DIRTY` 本來要擋的是「image 的 kernel ≠ `FW_COMMIT` 那棵樹」(例如 `BATMAN_ALLOW_DIRTY_BASE=1` 的 test build 本地拿掉了 999 patch)。wbox 強制 DIRTY=1 之後,檔案裡分不出「只因 wbox 而髒」與「樹真的髒」(`why` 只印 stdout,RB5-1)。所以**既有憑據確實不夠**,v4 兩位審查員要的「stamp 一行」還是得加,只是不該是自我宣稱的 `KPATCH=1`,而是 stamp 從 git 算出來的「樹髒不髒」本身。
- 證據:RB5-1、RB5-2、RB5-3;設計 §4.8「`git merge-base --is-ancestor … $BATMAN_FW_COMMIT` **且** `BATMAN_DIRTY=0` **且** `BATMAN_WBOX` 非空 **且** `BATMAN_PROV_TEST=1`」;§16 A4-M1 / B4-M1 列「閘門改用 … + `DIRTY=0` + `WBOX` + `PROV_TEST`」。
- 修(§4.8 / §2 / §9 / §16 改寫):
  1. stamp 加一個由 git 算的 key(不是自我宣稱):在第 56 行 wbox 強制 **之前**把 `DIRTY` 存成 `TREE_DIRTY`,輸出 `BATMAN_TREE_DIRTY=$TREE_DIRTY`(語意 = 樹相對於 `FW_COMMIT` 乾不乾淨,與 wbox 無關;`-wbox` 的 `BATMAN_DIRTY` 照舊 1)。h23 §4.2 / check-prov-test-gate 不受影響(gate 只看 `BATMAN_WBOX` 與 VER)。
  2. 閘門 = `BATMAN_WBOX` 非空 **且** `BATMAN_TREE_DIRTY=0` **且** patch 在 `FW_COMMIT` 那棵樹裡:主機 `git -C $DV_FW_TREE rev-parse --verify "$FW_COMMIT^{commit}"`(7 字元歧義 / 物件不存在 / 樹沒 pull → rc≠0 → **FAIL、不執行**)→ `git -C $DV_FW_TREE cat-file -e "$FW_COMMIT:target/linux/bcm27xx/patches-6.6/999-batman-eir-adv-flags-oob-254.patch"`(更強:`git cat-file -p` 的 blob 與主機 main 上的檔案 `cmp`)。這樣**不需要知道「加入 patch 的 commit id」**(H3 harness 比 firmware PR 先 merge,§12,當時根本不知道那個 id),也不需要 `merge-base`。
  3. 拿掉 `BATMAN_PROV_TEST=1` 條件(臂 2 不用它);若要留,寫明來源 = `strings /usr/bin/batman-provhelper | grep -c BATMAN_PROV_TEST_BUILD_7f3a`(RB5-3)。
  4. `DV_FW_TREE`(預設 `/home/yello/firmware-2710`,與 `dv-provclient-tools.sh:11` 同一棵)寫進 h23 §4 / 本文件 §2 harness 列;樹不存在 → FAIL(不是 NOTE)。
  5. 負對照改成可在 CI 跑的:閘門函式吃一段假的 `batman-build` 文字 + 一個假 git 樹:(a) `TREE_DIRTY=1` → FAIL;(b) `WBOX` 空 → FAIL;(c) `FW_COMMIT` 指向沒有該 patch 的 commit(例如 `1524084e`)→ FAIL;(d) 7 字元歧義 → FAIL;(e) 全成立 → 才回「可執行」。mutant 拿掉任一條件 → 對應案例變 PASS → 單元 FAIL。節點上的「pin 在 wsl.17 的 image → FAIL」留作現場臂,不當唯一負對照。
  6. 誠實界線補:`TREE_DIRTY` 證的是「rootfs 與 kernel 來自同一次 `make`、樹乾淨」(build-board 第 7 步 `cmp` stamp;RB4-3 kernel 自動重 prepare);它不證 kernel 真的含那段程式碼 — 那是臂 2 本身要證的事。

**M2. 「`Generation` 由旁路改變 → 已認證 / 候選 session 立即 Disconnect」在 provd 的觀測模型下不可判定:擁有者自己的 `network/join` 在 step 3 就 bump `Generation`(回應要到 step 4 之後,≤ 180 s 常態 / ≈ 960 s 最壞),`ctl` 看到的是同一個訊號。設計沒說怎麼分「自己的」與「旁路的」,兩種讀法一種讓每次 join 都把擁有者踢掉,另一種讓「立即」變成「最壞 960 s 後」。**
- 情境 A(照字面「`Generation != 上次` ⇒ 旁路」做):擁有者手機送 `network/join` → `ops` 進 `net.apply` → helper step 3 `commitTxn` 寫 overlay(RB5-6)→ 下一輪 `ctl` 的 `info.state` 回 `Generation+1` → provd 當旁路 → **把正在等 join 回應的擁有者 session Disconnect** → join 在 helper 端照做完,app 永遠收不到回應,只能靠 L75 的重連 + `unfinished` 路徑收尾。這會讓 §4.3 的 `network/join` 列(「等 ≤ 330 s」)與 `prov-netjoin-254` 的正向(join 回 0)自己打架;實作者只會在跑單位時才發現。
- 情境 B(實作者自然會做的「`ops` 有改狀態動詞在飛 → 這段的 `Generation` 變化都算自己的」):那 §1.3 的「**立即** Disconnect」在長動詞期間不成立 — root 同時跑 `provclient owner.remove`(L78)或 harness 改 record,被移除者的已認證 session 會活到動詞結束、`info.owners` 重拉之後才被比對掉(最壞 ≈ 960 s)。而且:(i) `Generation` 在一次動詞裡可能跳兩次(Finish + 自己,RB5-7)、可以往下(F-P40)→ **用計數分辨不可能**;(ii) `HELPER_WAIT` 330 s 到期後 `ops` 仍在等真正的回應(§4.3「到期不關連線、以 id 丟棄」)→ 「在飛」的定義必須撐到 helper 真的回應或 `ops` 重連,不是到 330 s;(iii) `ops` 因 EOF 重連(helper 重啟,L11)時動詞結果未知 → 這時該做的是全量 reconcile(重拉 owners / PSK、逐 session 比對),不是「當旁路全斷」也不是「當自己的不動」。
- 證據:RB5-6(commit 在 save 之前、`info.state` 無鎖可見)、RB5-7(兩次 bump)、F-P39 / F-P40(設計自己列的事實);設計 §1.3「非 provd 自己的動詞造成 `Generation` 變化 … 立即 Disconnect」、§3 快取列「失效條件:`ctl` … `Generation != 上次`」、§4.3「**Session 撤銷**:generation 由旁路改變 → 已認證 / 候選 session 全 Disconnect;provd 自己的動詞 → 以新 `info.owners` / PSK 集合逐 session 比對」— 三處都沒有判定規則。
- 修(§1.3 該列、§3 快取列、§4.3 快取段、L78、`cache_test`):
  1. 寫死判定規則:**`ops` 上有改狀態動詞在飛(從送出到 helper 回應抵達或 `ops` 重連,不是到 `HELPER_WAIT`)期間,`ctl` 看到的任何 `Generation` 變化只觸發「標記待重拉」,不觸發撤銷**;動詞回應抵達(任何碼,含丟棄的遲到回應)或 `ops` 重連後 → 重拉 `info.owners`(ctl)+ `psks.get`(ops)→ **逐 session reconcile**(`owner_key_id` 不在集合 / `psk_member` 消失或版本變 → Disconnect);沒有動詞在飛時的 `Generation` 變化才是「旁路 ⇒ 已認證 / 候選全斷」。
  2. 誠實界線改寫:「立即」只對「沒有動詞在飛」成立;長動詞期間旁路改動的撤銷延後到動詞結束(常態 ≤ 180 s、最壞 ≈ 960 s),被移除者這段只讀得到 `info.net`、改狀態動詞被 helper 以已存 owners 拒絕(對)。P3 `owner/remove` 上線後這條要再看(那時 remove 本身走 `ops`、不會與 join 並行,因為 `n.mu` 序列化)。
  3. 測試:`prov-netjoin-254`(sock)加斷言「join 期間擁有者 session **不斷**、收到 code 0 回應」(負對照 = 情境 A 的實作 → session 在 ≤ 8 s 內被斷);`cache_test` 加「`ops` 在飛 + gen 變 → 不斷;回應後 owners 少一把 → 斷」與「無在飛 + gen 變 → 已認證全斷」兩臂(mutant:拿掉在飛判定 → 第一臂 FAIL)。
  4. 被 Disconnect 的 session 若有 `ops` 請求在飛(例如 L24 另一支手機的 `claim/finish` 排在後面):回應抵達時以 session 已不存在丟棄(現在只寫了「以 `id` 丟棄」是 `HELPER_WAIT` 的情況)。

## 3. MINOR

**m1. 臂 2 的 `btmgmt add-adv … 1` 會撞 provd 自己的 instance 1。** mgmt `ADD_ADVERTISING` 同 instance 是「更新」:root 直接改掉 provd 註冊的那個 instance 的資料,BlueZ `advertising.c` 對 provd client 的狀態不知情;事後 provd 的 `UnregisterAdvertisement` 會把 root 加的一起拆掉(或反過來留下孤兒)。修:臂 2 前 `/etc/init.d/batman-provd stop`(本來就是 `-wbox` 單位、副作用清單加「provd 停 / 單位結束 start」),或用 instance 2 並在結束時 `rm-adv 2`;兩臂(adv / scan rsp)各自清理;把「`ActiveInstances` 回到 provd 的 1」當收尾斷言。

**m2. §4.8「與 #305 `bt-uart-305.sh:18,24` 同一套」是誇大。** 那兩行只用 `BATMAN_FW_COMMIT` 挑工具目錄,沒有就 NOTE 繼續(RB5-4);harness 裡沒有任何祖先檢查、沒有 firmware 樹變數。改寫為「沿用 #305 讀 `BATMAN_FW_COMMIT` 的方式;祖先 / blob 檢查是 P2 新加」。

**m3. 啟動盤點對「已經不連線的裝置」呼叫 `Disconnect` 不會拿到 `NotConnected`,而是沒有回覆。** RB5-8:`dev_disconnect` 回 `NULL`,msg 只在 `btd_device_is_connected` 時排進 `disconnects`;裝置在 `GetManagedObjects` 與呼叫之間自己斷了 → provd 等到 5 s 逾時。設計 §4.4 寫「回 `NotConnected` / `Failed` 視為已斷」(這條路徑沒有 `NotConnected`)、逾時 → 「重新盤點再試」— 結果對(重新盤點看到 `Connected=false` 就過),但要寫明「逾時 + 重盤點 `Connected=false` = 已斷,不計失敗」,免得實作把逾時當錯誤退避。另:供應逾時(手機走遠、鏈路已死)時 mgmt DISCONNECT 要等 supervision timeout(手機設,常見 ≤ 6 s)→ 5 s 可能不夠一次,重試一輪即可;寫上限(例如 3 輪)免得永遠不註冊。

**m4. `ERate` 讓廣播「維持」的誠實界線要補一句上界。** §4.1:`ctl` 撞 `ERate` 不推進不新鮮計時、既有廣播維持。全域桶 10/s 只有 uid 471 與 root 能打(provd 自己或 `provclient`);root 的 `provclient` 迴圈若把桶打滿(算術:accept 5/s × `provclient info` 2 動詞 = 10/s),bondable 翻 1 之後廣播可以一直掛著,沒有時間上界。現場 root 自己打自己,不是攻擊面;但 §8「我們自己」列要寫:「`provclient` 迴圈 > 5/s 會讓 health 證據斷掉而廣播不撤 → runbook 禁止」或把 `ctl` 的 `ERate` 連續 N 次(例如 > 120 s)也算不新鮮。

**m5. §1 狀態行仍寫「狀態:v4,2026-10-31」**;應為 v5。§4.8 兩次重複同一段括號(「A3 M3:這個動作在未 patch 的 kernel 上 … 遺失 logread」出現兩次)。

**m6. 擁有者在 `claim/finish` 成功後「Disconnect 其他所有 session」與 L24 的互動:** 另一支手機若正在假 msg2 的 10 s 等待(§4.2「走假路徑的連線也算交握中,不可被擠」)— 這裡是 Disconnect 不是擠槽,要寫明「全部」含交握中的,否則擠槽規則被讀成例外。

**m7. NXpsk0 模式收到 32 B(NX 長度)msg1 走假路徑時,是否仍跑 6 次 `ReadMessage`?** §4.2 沒說。模式本身是公開的(STATUS / `info` 都給 `state`),所以不是 oracle,但為了單元「6 次 `ReadMessage` 計數」的斷言一致,寫明「長度錯 → 不試 PSK、直接假路徑(2 DH)」或「照跑 6 次」擇一。

## 4. 我核過、成立的(§16 說修了、我確認真的修了)

| v4 發現 | v5 | 結果 |
|---|---|---|
| A4-M1 / B4-M1 kernel patch 落點 | `target/linux/bcm27xx/patches-6.6/999-…`、一份兩板共用、不在 #275 見證內、L13 理由 | ✅ 落點對(RB5-5);**閘門本身見 M1** |
| A4-m3 / B4-m1 被移除 owner 的 session | §1.3 新列 + §4.3 撤銷 + `cache_test` 兩臂 | ⚠️ 方向對,但判定規則缺 → M2 |
| A4-m4 / B4-m2 `ctl` `ERate` 與新鮮、退避封頂 10 s、accept 只計首次 Read 成功 | §4.1、§3 | ✅(上界見 m4) |
| A4-m5 撤廣播預算 9 s / L67 9.5 s | §4.4 | ✅ 算術對(4 + 2 + 1 + single-flight 已開始 +2) |
| A4-m6 `claim.verify` 回 6 的第二來源 | §4.3 以 `ctl` 最近成功當旁證、殘項 reason-code | ✅ |
| A4-m7 / B4-RB4-9 `provclient proxy` 不存在 | §2、F-P51 | ✅ |
| A4-m8 Register 順序 | §4.4 GATT → 盤點 → ADV | ✅ |
| A4-m2 bluetoothd crash 後 `load_connections` | §4.4 / L9 盤點 | ✅(F-P50 與 `adapter.c` 一致) |
| A4-m1 / B4-m5 無害重啟斷合法連線、`set-provd-env` 先於 peer | §4.4 app 契約 + harness 規則、L80 臂 2 | ✅ |
| B4-m3 Disconnect async | 等方法回覆 ≤ 5 s、`NotConnected`/`Failed` 視為已斷、重複呼叫無害 | ✅ 與 RB5-8 一致(細節見 m3) |
| B4-m4 L80 負對照 | 改為 `Connected` 斷言、與 le_states 無關 | ✅ |
| B4-m6 provclient `CONN-CLOSED` | §10 第 2 點加退避重試一次 | ✅ |
| B4-m7 / A4-m9 殭屍穩態 | L81 上限 4、≤ 5 s 恢復 | ✅ |
| B4-m8 / A4-m10 文字 | §12「現 v5」、§6 單連線標 P2 改、§2 patch | ✅(§1 狀態行漏改,m5) |
| 假 msg2 等長 | `e'(32) ‖ random(48 + len(node_cert) + 16)`,用節點自己的 `len(node_cert)`(不是寫死 615,DER 簽章長度會變)| ✅ 等長在任何節點都成立 |
| PSK 時序 | 6 次 `ReadMessage` 不 break、無 DH;真 / 假都 2 DH;長度檢查在 6 次之前 | ✅(m7 補一句) |
| GATT 快取新鮮度 | STATUS 來自 `ctl` 快取(≤ 5 s)、> 60 s 無成功 → 0x0E + 撤廣播 | ✅ |
| dbus policy | 八條方法;無 `own` / DBus destination / `receive_sender`;root 六條無 destination 的 `send_interface` 是回呼放行 | ✅ RB5-11;unknown user 只 warn(RB5-10) |
| 長 msg1 不拒 / psk0 msg1 48 B | F-P14 / F-P31 | ✅ RB5-9 |

## 5. 負對照盤點

| 防線 | 有 | 缺 |
|---|---|---|
| kernel patch 閘 | 「pin 在 patch 前 → FAIL」(現場) | 閘門永遠 FAIL(M1);CI 級閘門單元五案例 |
| 自己的 join 不撤 session | — | `prov-netjoin-254` 加「join 期間不斷、收到 0」(M2) |
| 旁路 gen 變 → 斷;在飛 → 不斷 | `cache_test` 兩臂 | 在飛判定臂 + mutant(M2) |
| 臂 2 instance 收尾 | — | `ActiveInstances` 回 1(m1) |
| 啟動盤點 | L80 兩臂 | 逾時 + 重盤點 = 已斷(m3) |
| `ERate` 不撤 | 30 s 不撤 / 60 s 撤 | 長期 `ERate` 的上界(m4) |
| 假 msg2 等長 / churn / stale-while-revalidate / L75 | 單元 + mutant | ✅ |

## 6. 誠實界線

有寫且對:RPA 900 s;BLE 單連線;ADV 自檢只擋自己;`adv_registered_once` 量 kernel;autocommit 只 WARN;被攻陷 provd 的四種能力;`psk_member` 在 update 進行中的空窗;無 provd 保留位;殭屍連線;F-P41 ⚠️;kernel patch 不在 #275 見證內;`model` fail-open;helper 重啟時 latch 時序。
要改:§4.8 閘門(M1,含「與 #305 同一套」m2);§1.3 / §4.3 「立即 Disconnect」的適用範圍(M2);§8 `provclient` 打滿桶的後果(m4);§1 狀態行(m5)。

## 7. 判定

**APPROVE-WITH-CHANGES** — 0 BLOCKER / 2 MAJOR / 7 MINOR。

v4 的 MAJOR 修了一半:patch 落點對了,但新閘門把兩個互斥的 stamp 事實(`-wbox` ⇒ `DIRTY=1`)綁在一起,而且引用了一個不存在的 key(`BATMAN_PROV_TEST` 不在 `/etc/batman-build`)— 結果是 D3 的唯一真機見證永遠不會跑(M1);修法是 stamp 一個由 git 算的 `BATMAN_TREE_DIRTY` + 主機 `cat-file -e` 檢查 patch 在 `FW_COMMIT` 那棵樹(不需要知道加 patch 的 commit id),加 CI 級閘門單元。第二個 MAJOR 是本輪分工點名的並行題:自己的 `network/join` 與旁路改 record 在 `ctl` 眼裡是同一個 `Generation` 訊號,設計沒給判定規則,一種讀法每次 join 都踢擁有者、另一種讀法讓「立即」變 960 s(M2);修法是明文「`ops` 在飛 → 只標記待重拉、回應後 reconcile」+ 兩個負對照。其餘(Disconnect async、`ERate` / 不新鮮、假 msg2 等長、PSK 時序、GATT 快取、dbus policy、v4 的 MINOR)逐一對原始碼核過成立。依通用規則 MAJOR 開著就要改 v6 並整份再審;本輪 04 連不上,F-P41 與 L10 / L11 的實機證據仍欠。
