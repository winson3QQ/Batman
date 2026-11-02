# #254 PR-P2 `batman-provd` 設計 v6 — 對抗式審查 A(第 6 輪,整份重審)

審查者 A,2026-10-31。對象:`scratchpad/254-p2-impl.md` v6 全文 §0–§17。方法:§13–§17 不採信;從現場出發(認領 → 立刻 join 的主流程、10 台一隊、路人、被攻陷的 provd、root 操作員、harness 在 `-wbox` 上跑 kernel patch 臂),把第 5 輪兩個 MAJOR 的 v6 修法逐條對 firmware 腳本、helper 原始碼、kernel / BlueZ 原始碼與 04 實機重核;其餘章節抽查擁有權 / 契約 / 生命週期 / 負對照。

## 0. 我自己核過的事(✅ 原始碼 / 實跑;⚠️ 推論;❌ 沒驗到)

| # | 事實 | 證據 |
|---|---|---|
| V1 ✅ | `build-board.sh` 順序:第 2 步 setup → **`wbox_apply`(對 `feeds/batman` 套 patch)** → 第 3 步 lock → **第 4 步 stamp**;stamp 第 44 行 `[ -z "$(git -C feeds/batman status --porcelain)" ] \|\| { DIRTY=1; why="$why feeds/batman-modified"; }` → **任何帶 patch 的 `-wbox` 變體,`$why` = ` feeds/batman-modified wbox-<name>`**;只有 `test`(無 patch,`wbox_apply:68`)的 `$why` 恰為 ` wbox-<name>`;`$why` 的順序:tracked-changes → untracked → feeds.conf-override → feeds/batman-modified → wbox | `firmware-2710/scripts/build-board.sh:108-116, 140-141`;`stamp-batman-build.sh:38-44, 56`;`lib-wbox.sh:67-82` |
| V2 ✅ | 新增一行 `BATMAN_DIRTY_WHY=` **不會弄壞任何既有讀者**:`check-prov-test-gate.sh` 只 `sed` 取 `BATMAN_VERSION` / `BATMAN_WBOX`(`:52-53, 96-97`);`build-board.sh:190` 的 `cmp` 是同一次 stamp 的兩份副本;節點上 `batman-version`(「Values are PARSED (sed), never sourced」`:7-10`)、`batman-autocommit:66,490-495`、`batman-slot:790-817`、`halow-status:156`、`95-batman-storage:420,717`、`bundle:13`、helper `main.go:511` 全部 `sed` / grep,**沒有任何 `. /etc/batman-build`**(`grep -rn` 零命中)→ 值含空白(`untracked:a b`)也安全 | 原始碼 |
| V3 ✅ | helper 改 record 的路徑:`claimVerify :548` `commitTxn` 在回應前;`applyNet :1134` gen+1 → step 3 `commitTxn :1166` → step 4 `SaveTxn`(≤ 300 s)→ 回;`leave :1192`;`ownerAdd/Remove :877/:904`;`ssh_keys :831`;**`claimReplay` 沒有 commit / Generation / WriteOverlay**(awk 整段 grep 零命中);`finish()` 只 `WriteTxn(… rec.Generation, rec.Generation …)` 不改 gen;`resolve()` 只在 `p5.Generation > ov.Generation` 重寫;`boot.Run` 四處 `Generation: 1`;**`commitTxn :47-50`:p5 已 commit 而 overlay 寫入失敗 → 只 log,overlay 留舊 gen,下一次 `resolve()` / `--boot` 才補** | `node/node.go`、`node/txn.go`、`node/wtxn.go:270-276`、`boot/boot.go:132-211` |
| V4 ✅ | `Handle` 進門 `n.mu.Lock()`(`:157-158`);`info.state` 回 `{1: State, 2: Generation, 3: len(Owners), 4: RadioManaged}`(`:235`);`psks()`:`psk_member = PskMember(root, NetID, Net.Version)`(`:409`)→ 綁版本;`sock.go:107-116` 今天仍是單連線同步 Serve(P2 要改) | 原始碼 |
| V5 ✅ | BlueZ `ActiveInstances` = **`queue_length(manager->clients)`(D-Bus 註冊的 client 數)**,不是 kernel 的 instance 數;5.72 沒有 `advertising_added/removed` mgmt 事件處理;`read_adv_features_callback` 只在 bluetoothd 啟動時 `remove_advertising(manager, 0)` | `bluez-5.72/src/advertising.c:1674-1684, 1868-1896` |
| V6 ✅ | kernel `eir_create_adv_data`:**instance 的 adv_data 裡已有 `EIR_FLAGS` → `goto skip_flags`,不加 3 B**(`eir.c:260-264`);否則 LE-only(`!HCI_BREDR_ENABLED`)無條件 `LE_AD_NO_BREDR` → 寫 3 B(`:276-296`)再 `memcpy` 不檢查(`:300`);`tlv_data_is_valid`:長度 ≤ `tlv_data_max_len`(flags 0 時 = 31,不扣)且 TLV 格式正確,**`EIR_FLAGS` 在 adv data 裡只有 `flags_managed(adv_flags)` 時才拒**(`mgmt.c` `tlv_data_is_valid`);格式錯 → `MGMT_STATUS_INVALID_PARAMS`(`add_advertising` :52-56);`hci_set_adv_data_sync` 的 `struct hci_cp_le_set_adv_data cp` 是**堆疊區域變數**(`hci_sync.c:1331-1336`)→ 3 B 越界是 stack overrun,不保證 panic(F-P10 是 n=1) | 原始碼 |
| V7 ✅ | kernel `add_advertising`:`instance < 1 \|\| instance > le_num_of_adv_sets` → INVALID_PARAMS;legacy 控制器 `le_num_of_adv_sets = HCI_MAX_ADV_INSTANCES`(5,`hci_core.c:2496`)→ instance 5 合法;`hci_add_adv_instance` 同號就地覆寫(與 F-P54 一致) | 原始碼 |
| V8 ✅ | daily-validation 的設定全走**環境變數**(`DV_BT_TOOLS`、`DV_PY`、`DV_T263_KO` 等,`:14-22`);`DV_T263_KO` 未設 → 該單位 **SKIP 帶理由**(`:2737-2738`),不是 FAIL;節點單位從 Git Bash 跑(REPO = `//wsl.localhost/...`,`:56`),git 重的檢查在 MSYS 下會 hang → **委派進 WSL**(`:181-201`,`timeout 900 wsl.exe -d $d -- bash -c …`);harness 今天沒有 `scripts/dv/data/`、沒有 `DV_FW_TREE` | `scripts/daily-validation.sh` |
| V9 ✅ | `helpers.list` 格式 `<name> <prov_test\|release> <helper\|same>`,`test prov_test helper`;prov_test image 的節點端判定 = helper `--version` 第 2 行 marker(`prov-254.sh:488` 已在用) | 原始碼 |
| V10 ✅ | 04 實機(Windows Git Bash,唯讀):`/rom/etc/batman-build` = wsl.16、`BATMAN_FW_COMMIT=6aa0241`、`BATMAN_DIRTY=0`、**無 `BATMAN_WBOX` / 無 `BATMAN_DIRTY_WHY`**;`ActiveInstances 0`、`SupportedInstances 5`、Pairable/Discoverable no;無 `/usr/bin/batman-provd`、無 `/usr/bin/btmgmt`;helper `--version` 1 行;helper pid 4209、bluetoothd 3665;`/tmp/run/batman-prov` root:provd 0750 + `helper.sock` 0660;`/tmp/run/dbus` root 0755 + socket 0777;uptime 4:59(F-P10 之後) | 04 `ssh` 實跑 |
| V11 ❌ | F-P41 le_states、L10 / L11 目錄 bind 實跑、patched kernel 上 `btmgmt add-adv` 的實際行為:本輪無新實證(設計自己標 ⚠️) | — |

## 1. 第 5 輪 MAJOR 的實際修復狀態(不看 §17)

| 第 5 輪 | v6 處置 | 判定 |
|---|---|---|
| A5-M1 / B5-M1 閘門互斥、無 `PROV_TEST` key、主機無樹 | `DV_FW_TREE` + `rev-parse --verify` + `cat-file -e` + sha 檔 + `BATMAN_DIRTY_WHY == wbox-<name>` + helper `--version` marker | 條件 (1)(2)(4) 關閉(V5 of r5 + V9);**條件 (3) 只對 `test` 變體成立**(V1)→ M1;另外臂 2 本身的判定在 kernel 層不具鑑別力(V6)→ M3 |
| A5-M2 / B5-M2 撤銷缺歸因 | `expectGen` 由 `ops` 擁有、在飛只標待重拉、回應後 reconcile、`(state, Generation)` 鍵 | 規則方向對、`cache_test` 單臂對;**但清除條件以「單一動詞」寫成,兩個改 record 動詞背靠背(認領 → join 是主流程)時會在第二個動詞在飛中清掉** → M2;鍵的涵蓋見 §4 |

## 2. BLOCKER

無。

## 3. MAJOR

**M1. §4.8 條件 (3) `BATMAN_DIRTY_WHY == wbox-<name>` 只有無 patch 的 `test` 變體能滿足;設計寫的語意(「= 樹本體無 tracked 修改 / untracked / feeds override」)與 stamp 腳本不符,而條件 (4) 又允許任何 `prov_test` 變體 → 在 `helper-flap` 之類的 image 上跑,單位永遠 FAIL 且歸因錯(「樹髒」),實作者第一個反應就是放寬條件。**
- 情境:harness 在 prov_test image 上跑 `prov-sec-adv-len-254` 臂 2(需要 `btmgmt`,只有 `-wbox` 變體有)。`build-board.sh` 第 2 步 `wbox_apply` 先把 `tests/wbox/<name>.patch` 套進 `feeds/batman`,第 4 步才 stamp;stamp 第 44 行看到 `feeds/batman` 有修改 → `why=" feeds/batman-modified wbox-<name>"`。閘門要求字串恰等於 `wbox-<name>` → 對所有帶 patch 的 prov_test 變體(`rc9-unclaimed`、`helper-flap`、…)FAIL。只有 `test`(`wbox_apply:68` 跳過 patch)能過。
- 證據:V1;設計 §4.8 (3)「`BATMAN_DIRTY_WHY == wbox-<name>`(= 樹本體無 tracked 修改 / untracked / feeds override)」、(4)「`BATMAN_WBOX=<name>` 在 `helpers.list` 標 `prov_test`」;§4.8 負對照 (b) 五案例裡沒有這一案。
- 修:
  1. 寫明臂 2 的 image = **`-wbox test`**(prov_test、無 patch、有 `btmgmt`),閘門 (4) 改為 `BATMAN_WBOX == test`,或
  2. 把 (3) 定義成集合:`BATMAN_DIRTY_WHY` 以空白切開後 **⊆ {`wbox-<name>`, `feeds/batman-modified`}** 且含 `wbox-<name>`,理由寫明:kernel patch 在 firmware 樹本體 `target/`,只有 `tracked-changes` / `untracked:` 能拿掉或改它;`feeds/batman-modified` 與 `feeds.conf-override` 碰不到 kernel(前者是 wbox 本來就會有的)。
  3. 兩種都要:§4.8 的語意句改對(V1 的順序與來源);CI 負對照加「`feeds/batman-modified wbox-x`」一案(選 1 → FAIL;選 2 → 可執行)與「`tracked-changes wbox-x`」→ FAIL;h23 §4.2 :183 的 stamp 步驟一併補「patch 已套 → `feeds/batman-modified`」。
  4. §6「kernel patch 落點與 stamp 產生者」加 V2 的證據(新 key 不壞既有讀者:全部 sed、無 source;gate / cmp 不看它)— 設計現在只斷言「不受影響」沒給證據。

**M2. `expectGen` 的清除條件以「一個動詞」寫成;兩個改 record 動詞背靠背時,第一個動詞的「回應處理完 + `ctl` 輪過一次」會在第二個動詞在飛中把旗標清掉 → 第二個動詞的 commit 被當旁路 → 擁有者 session 被撤銷。認領 → 立刻 `network/join` 正是現場主流程。**
- 情境(認領現場):t0 `ops` 送 `claim.verify`(`expectGen=true`)→ t1 helper 回 0(commit 在回應前,`:548`)→ provd 升擁有者、Disconnect 其他、標待重拉;依 §1.3「回應處理完且 `ctl` 之後又成功輪過一次才清」排定清除 → t1+0.3 s app 送 `network/join`,`ops` 送 `net.apply`(§1.3「送出前設 `expectGen=true`」,本來就是 true)→ t1+2 s `ctl` 輪到 `(claimed, g+1)`,「claim 的回應已處理 + ctl 成功輪過」成立 → **清 `expectGen=false`**,join 仍在飛 → t1+10 s `applyNet` step 3 commit `(member, g+2)` → `ctl` 看到變化、`expectGen=false`、依 §1.3「沒有在飛動詞時 … 旁路 → 已認證全 Disconnect」→ **擁有者在自己的 join 進行中被斷,join 回應落空**(與 A5-M2 情境 A 相同結果)。同構:join → `network/update`、`ssh_keys/set` 連發;兩支手機各一動詞排在 `ops` FIFO;`HELPER_WAIT` 到期的動詞後面又排一個。設計唯一的在飛臂(「自家 `net.apply` 在飛時 gen +1 → 不斷」)是單動詞,測不到。
- 第二層:「`ctl` 之後又成功輪過一次」沒說是**送出時刻**在回應之後的那一輪。`info.state` 不取鎖、直接讀 overlay(F-P44),`claim.verify` 的 commit 緊貼回應;一個在回應前送出、在 commit 前執行、回覆在回應之後抵達的 `ctl` 輪會被算成「之後輪過」→ 清旗標 → 下一輪才看到 gen 變 → 旁路 → 撤銷(ms 級窗,但是確定的競態)。
- 第三層:`HELPER_WAIT` 到期分支寫「`expectGen` 撐到 `ctl` 看到 gen 變、或 960 s 上限」;動詞失敗而**沒 commit**(setkey 失敗、`EState`、Finish 失敗)時 gen 永遠不變 → 旗標卡滿 960 s;而真正的訊號(遲到回應以 `id` 丟棄,§4.3)設計沒拿來清旗標。
- 證據:V3、V4;設計 §1.3 撤銷列、§4.3 快取段、L82、§9 `cache_test`。
- 修(把它寫成狀態機,不是布林):
  1. `ops` 擁有 `inFlight`(改 record 動詞計數:送出 +1;回應抵達 −1,**含 HELPER_WAIT 之後遲到、以 `id` 丟棄的回應**;`ops` 重連歸 0 並進全量 reconcile)與 `pendingReconcile`(任一回應抵達時設)。
  2. `ctl` 一輪成功且**該輪送出時刻晚於最後一次回應處理完**且 `inFlight == 0` → 做一次 reconcile(新 owners / PSK 逐 session)→ 清 `pendingReconcile`。
  3. 「旁路 ⇒ 已認證全斷」只在 `inFlight == 0 && !pendingReconcile` 時適用;其餘一律只標待重拉。
  4. 960 s 上限只留給「`ops` 連線還在但回應永遠不來」(helper 卡死),到期 = 關 `ops` 重連 → 全量 reconcile,不是「旁路全斷」。
  5. 測試:`cache_test` 加「`claim.verify` 回 0 → `ctl` 輪一次 → `net.apply` 在飛 gen +1 → 不斷;回應後 reconcile 仍是擁有者 → 不斷」(mutant:布林 + 單動詞清除 → 斷);`prov-netjoin-254` 正向臂的順序就是 claim → join 背靠背,斷言 log 無 `session revoked` 並收到 join 的 0。
  6. 順手:`claim.replay` 不改 record(V3),從 §1.3 / L82 的清單拿掉(留著只是多計一次,但事實表要對)。

**M3. 臂 2 的判定在 kernel 層不具鑑別力:(a) payload 若含 `EIR_FLAGS`(0x01)AD,kernel 直接 `skip_flags`、不加 3 B → 未 patch 也不越界 → PASS;(b) payload TLV 格式錯 → 任何 kernel 都 `INVALID_PARAMS`,而設計把 `INVALID_PARAMS` 算通過 → 未 patch 也 PASS;(c) 越界是 3 B 的 stack overrun(`cp` 是區域變數),「沒 panic」不是確定的正向見證。設計沒釘 payload、沒釘可觀測的 patch 語意。**
- 情境:H3 寫單位時選了 `btmgmt add-adv -d 020106…`(很自然:拿 BlueZ 自己產的 ADV 當範本,前三 B 就是 Flags)或隨便填 31 B 的 hex → 兩種都在未 patch 的 kernel 上 PASS;D3 的唯一正向見證變成不證自明。規則:「找不到東西檢查的測試必須 FAIL」、「宣稱的修法要有負對照」。
- 證據:V6(`eir.c:260-264` skip_flags;`tlv_data_is_valid` 只在 `flags_managed` 時拒 `EIR_FLAGS`;格式錯 → `add_advertising :52-56` INVALID_PARAMS;`hci_sync.c:1331` 區域變數);設計 §4.8「`btmgmt add-adv -d <31 B> 5` … 不 panic … (或 mgmt 拒絕 INVALID_PARAMS,兩者都算通過)」。
- 修:
  1. **釘 payload**:31 B、單一 AD、型別 0xFF(manufacturer)`1e ff` + 29 B 固定常數,**不含 0x01**;只用 `-d`,不帶 `-g/-l/-m`(flags 0 → `tlv_data_max_len` = 31、kernel 仍要加 NO_BREDR flags → 走到越界路徑);harness 由程式組 payload、CI 單元斷言長度 31、TLV 合法、無 0x01。
  2. **正向判定改成可觀測的 patch 語意**:BLE lease 內開 `btmon`,斷言 `LE Set Advertising Data` 的 length == 31 且內容 == payload、**無 Flags AD**(= 「放不下時丟 Flags」),再加 `advinfo` 有 instance 5、boot_id 不變;`INVALID_PARAMS` **只在** D3 選的上游修法是改 `tlv_data_max_len`(扣 flags)時才算通過,且要寫明是哪一個 commit 的語意(D3 commit id 定了就定);兩種結果不能同時「都算通過」。
  3. 負對照 (c) 的誠實句改寫:F-P10 是 n=1 的 stack overrun 紀錄,不是「未 patch 必 panic」;未 patch 的真正負對照留在閘門 (2)(patch 檔不在樹裡 → 不執行)與 CI 單元。
  4. 副作用清單加:`add-adv` 到 `rm-adv` 之間節點對空中廣播了 harness 的 31 B(無 Flags、connectable)幾秒。

## 4. MINOR

**m1. `ActiveInstances` 看不到 root 的 `btmgmt` instance。** V5:它是 BlueZ 的 D-Bus client 數,root `btmgmt add-adv` 不經 BlueZ → §3 廣播列「provd 看到 `ActiveInstances` > 自己註冊數 → log `adv: foreign instance count`」永遠不會觸發;§4.8 / L68「provd log `foreign instance` 為預期」雙重不成立(臂 2 期間 provd 本來就停著)。修:foreign 偵測改用 `health.get` 行裡 kernel 的 `num_instances`(F-P28)對 provd 自己的註冊數;L68 / §4.8 的預期結果改掉。

**m2. reconcile 會踢掉剛做完 `network/update` 的成員 session。** V4:`psk_member` 綁 `Net.Version`;成員手機自己送 `network/update` → 回 0 → reconcile:該 session 的 `psk_member` 版本 ≠ 新版本 → Disconnect(`psk-rotated`)。結果可辯護(認證基礎已舊),但要寫進 app 契約(219 §3.7:update 成功後成員必須以新版本 `psk_member` 重連)與 `cache_test`;擁有者 session 不受影響(`psk_owner` 不變)要同句寫。

**m3. 鍵 `(state, Generation)` 的誠實界線:p5 已 commit、overlay 寫入失敗的分支。** V3:`commitTxn :47-50` 只 log;`info.state` 讀 overlay → provd 看到舊 `(state, gen)` 直到下一個 owner-op 的 `resolve()` 或 `--boot`。root `provclient owner.remove` 落在這個分支 → 被移除者的 session 不會被撤銷(helper 端 `verifyOwnerOp` 以 overlay 的 owners 驗 → 也還放行,直到 resolve)。這是 P1 的性質,不是 P2 的 bug,但 §3 快取列「涵蓋所有 record 重寫路徑」要加這一句,殘項列「overlay 寫入失敗時 helper 主動 resolve」。

**m4. `DV_FW_TREE` 的執行環境沒定。** V8:節點單位從 Git Bash 跑,REPO 是 `//wsl.localhost/...`;harness 對 git 重的檢查已有「MSYS → 委派 WSL」機制(`daily-validation.sh:181-201`),Git for Windows 對 `\\wsl.localhost` 要 `-c safe.directory='*'`(`:54-57` 已這樣做)且慢。設計要寫:`DV_FW_TREE` 的路徑形式(WSL `/home/yello/firmware-2710` vs Git Bash `//wsl.localhost/Ubuntu-24.04/home/yello/firmware-2710`),三個 git 查詢(`rev-parse`、`cat-file -e`、`show | sha256sum`)在 MSYS 下走同一個委派,hang 以 timeout 當 FAIL;「未設 → FAIL 不 SKIP」與 `DV_T263_KO` 的 SKIP 慣例不同,要寫明是刻意的(閘門資料缺 = 單位沒東西可查 = FAIL,符合通用規則)。

**m5. `HELPER_WAIT` 遲到回應與 960 s 上限**(併入 M2 第三層):遲到回應抵達 = 動詞結束,應清 `inFlight`;「`ctl` 看到 gen 變」不能當清除條件(失敗的動詞不變 gen)。

**m6. 事實表 / 文字**:F-P55 / §1.3 把 `claim.replay` 列為改 record(V3:不是);§12 第 1 點「本設計(現 v5)」應為 v6;§4.8 (3) 語意句(M1);§6 加 V2 證據;L68 預期結果(m1)。

**m7. 臂 2 的「兩者都算通過」**(M3 (b))在 §4.8 與 §9 各出現一次,改時兩處同步。

## 5. 我核過、成立的(§17 說修了、我確認真的修了)

| v5 發現 | v6 | 結果 |
|---|---|---|
| 閘門 (1)(2):`DV_FW_TREE` + `rev-parse --verify --quiet "$FW^{commit}"` + `cat-file -e $FW:<patch>` + sha 檔 | §4.8 | ✅ 機制對(A5 V5 實證可問樹;04 今天的 wsl.16 image 無 patch、無 `DIRTY_WHY` → 兩條都 fail-closed = 現成負對照,V10) |
| 閘門 (4) prov_test 偵測 | helper `--version` marker + `helpers.list` | ✅(V9;`prov-254.sh:488` 同一判定) |
| 新 stamp key 不壞 gate / cmp | §4.8「不受影響」 | ✅ 成立但無證據(V2 補;m6) |
| `add-adv` 用 instance 5、先停 provd、`rm-adv`、前後 `advinfo` | §4.8 | ✅(V7:instance 5 合法;覆寫語意 F-P54 對) |
| 撤銷歸因方向(在飛只標待重拉、回應後 reconcile、無在飛才旁路) | §1.3 / §4.3 / L82 | ✅ 方向對;清除條件見 M2 |
| 失效鍵 `(state, Generation)` | §3 | ✅ 涵蓋 `commitTxn`(所有改 record 動詞 gen+1)、`resolve()`(gen 往上)、`boot.Run`(gen 1 + state;同 (state,1) → 同 NX 模式、PSK 空,無害);p5-only 分支見 m3 |
| `boot.Run` 每次 helper 啟動都跑 | L11 | ✅ `main.go:585` |
| `Device1.Disconnect` 對已斷裝置無回覆 → 逾時 + 重盤點、上限 3 輪 | §4.4 | ✅ 與 F-P56 一致 |
| `ERate` 連續 > 120 s 也撤 | §4.1 | ✅ |
| 認領成功 Disconnect 全部含假路徑;psk 模式 32 B msg1 仍 6 次 | §4.3 / §4.2 | ✅ |
| L80 ≤ 15 s;`/rom` 自己 sed、`bt-uart-305` 不重用 | L80 / §4.8 | ✅ |

## 6. 負對照盤點

| 防線 | 有 | 缺 |
|---|---|---|
| kernel patch 閘 (1)(2)(4) | 04 wsl.16 image → (2) FAIL、無 `DIRTY_WHY` → (3) FAIL(V10);CI 五案例 | `feeds/batman-modified wbox-x` 一案(M1) |
| 臂 2 本身 | 「不 panic + advinfo」 | payload 釘死 + btmon 語意斷言;「INVALID_PARAMS = 通過」要收(M3) |
| 自家動詞不撤 session | `cache_test` 單動詞在飛臂、`prov-netjoin-254` | 背靠背兩動詞 + 布林 mutant(M2) |
| 成員 update 後的 reconcile | — | 明文 + 臂(m2) |
| foreign instance log | — | 改用 kernel `num_instances`(m1) |
| `DV_FW_TREE` 缺 / MSYS | — | 未設 FAIL、MSYS 委派(m4) |

## 7. 誠實界線

有寫且對:RPA 900 s;BLE 單連線;ADV 自檢只擋自己;`adv_registered_once` 量 kernel;autocommit 只 WARN;被攻陷 provd 的能力;`psk_member` 在 update 進行中的空窗;無 provd 保留位;殭屍連線;F-P41 ⚠️;kernel patch 不在 #275 見證內;`model` fail-open;撤銷在新連線重拉前以舊集合放行。
要改:§4.8 (3) 的語意(M1)、臂 2「未 patch = panic」(M3 (c))、`ActiveInstances` 的意義(m1)、鍵對 p5-only 分支的盲點(m3)、`claim.replay` 不改 record(m6)。

## 8. 判定

**APPROVE-WITH-CHANGES — 0 BLOCKER / 3 MAJOR / 7 MINOR。**

第 5 輪兩個 MAJOR 各修了大半:閘門的四個條件裡三個現在有既有寫者、04 上今天就 fail-closed(V10),但條件 (3) 因為 `wbox_apply` 早於 stamp、stamp 把套了 patch 的 feed 記成 `feeds/batman-modified`,只有 `test` 變體能過(M1);撤銷歸因有了擁有者與方向,但清除條件按單一動詞寫,認領 → join 這個主流程就會在 join 在飛中把擁有者踢掉(M2)。新發現的 M3 是臂 2 自己的鑑別力:kernel 對含 Flags AD 的 payload 會跳過加 flags、對格式錯的 payload 任何版本都回 INVALID_PARAMS,而設計把後者算通過、又沒釘 payload — 這個單位今天的寫法可以在未 patch 的 kernel 上 PASS。三個都是契約文字層的修改(集合 / 狀態機 / 釘 payload + btmon 斷言),不需要改架構;關了再出 v7 整份重審一次(MAJOR 開著不進實作)。本輪 04 可從 Windows 端唯讀連上(V10),F-P41 與 L10 / L11 的實機證據仍欠。
