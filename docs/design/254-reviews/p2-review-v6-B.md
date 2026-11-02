# #254 PR-P2 `batman-provd` 設計 v6 — 對抗式審查 B(第 6 輪,整份重審)

審查對象:`scratchpad/254-p2-impl.md` v6 全文 §0–§17。方式:從現場出發(harness 在 `-wbox` image 上跑臂 2、擁有者連著做 join 而 root 同時改 record、被移除的 owner、兩支手機、helper / provd 重啟),§13–§17「已對應」一律不採信,逐條對原始碼與主機 git 樹重核。分工 B:閘門的證據鏈(sha 檔的寫者與時序、pin bump 會不會漏、`git cat-file -e` 對 7 碼的行為、臂 2 停 provd 與 BLE lease / deadman / 其他單位的互動)、`expectGen` 狀態機(兩條 session、`HELPER_WAIT` 到期時排隊的第二個動詞、`ops` 中途重連、helper 中途重啟)、時間預算、Noise / 假 msg2、GATT 快取、dbus policy、生命週期缺口、負對照、誠實界線。

**環境誠實界線**:本輪**沒有上 04**(分工不需要;F-P* 實機事實沿用前五輪)。我核的是:repo main `34f216d`(乾淨)、firmware `/home/yello/firmware-2710` HEAD `da30986f`(wsl.17 pin;乾淨)、兩邊的 scripts、helper 原始碼。全部指令在 WSL 實跑,輸出節錄在 §0。

## 0. 我自己核過的事實(✅ 實跑 / 原始碼;⚠️ 推論;❌ 未驗)

| # | 事實 | 證據 |
|---|---|---|
| RB6-1 ✅ | **`build-board.sh` 第 2 步 `wbox_apply` 把 `tests/wbox/<name>.patch` 套進 `feeds/batman`,第 4 步才跑 `stamp-batman-build.sh`**;stamp 的 `[ -z "$(git -C feeds/batman status --porcelain)" ] \|\| { DIRTY=1; why="$why feeds/batman-modified"; }` 在 wbox 那行(`why="$why wbox-$WBOX"`)**之前** → 任何**有 patch 的變體**(helpers.list 21 個裡 20 個;只有 `test` 無 patch)的 `$why` = ` feeds/batman-modified wbox-<name>`,**不等於** `wbox-<name>` | `build-board.sh:122, 141`;`lib-wbox.sh wbox_apply`(`git -C "$feed" apply "$wp"`);`stamp-batman-build.sh:38-44, 54-56`;`tests/wbox/helpers.list`(`test prov_test helper` 是唯一無 patch 的 prov_test 變體) |
| RB6-2 ✅ | `git -C firmware-2710 rev-parse --verify --quiet '6aa0241^{commit}'` → 全 hash、rc 0;**歧義 4 碼 `86ff`** → rc 1(`--quiet` 吞訊息);不存在 `deadbee` → rc 1;`git cat-file -e 86ff:Makefile` → `error: short object ID 86ff is ambiguous … fatal`,rc 128;`git cat-file -e 6aa0241:…/999-batman-hci_bcm-close-flow-305.patch` rc 0、`…-254.patch` → `fatal: path … does not exist in '6aa0241'`;`git show 6aa0241:<305 patch> \| sha256sum` = `60e0cdc7…` = 工作樹同檔 sha。**目前所有 commit 的 7 碼前綴無重複**(`rev-list --all \| cut -c1-7 \| uniq -d` = 0) | WSL 實跑 |
| RB6-3 ✅ | **`ble-lib-254.sh ble_state`(preflight P6、tier A #5,`scripts/dv-preflight.sh:83` 對每台 BLE 節點跑)在 `adv_instances != 0` 時印 `FAIL leftover: <n> advertising instance(s) registered`**;`ble-periph-254.sh` 的 `cmd_adv_on` / `cmd_adv_off` / deadman `role_fire_restore` 都無條件 `rm-adv 1`(`:45, 52, 171`),deadman 再 `power off` + `bluetoothd restart`;**沒有任何一處 start / stop `batman-provd`** | `scripts/node/ble-lib-254.sh`(`ble_state`);`scripts/node/ble-periph-254.sh`;`scripts/dv-preflight.sh:83` |
| RB6-4 ✅ | **prov deadman `role_fire_restore`(`prov-lease-254.sh`)到期只做:`unbind-all`、`rm -rf /tmp/run/batman-prov-test`、把 upper 的 harness helper 換回 release、修 socket 目錄、確保 helper 跑著、起 `joinwatch / openmanetd / tailscaled`;不碰 `batman-provd`、不 `rm-adv`** | `scripts/node/prov-lease-254.sh role_fire_restore` |
| RB6-5 ✅ | h23 已預設「provd 停止模式」:`:118` `cmd_adv_on` 先驗 `adv_instances = 0` 且 provd 未 running;`:157` 「harness `adv-on` 只在 provd 停止時」;`:402` `prov-sec-bond` 停 provd → … → 起 provd;`:404` `ble-rpa` N1 停 provd;`:405` `prov-sock` 停 provd 才跑;**但 h23 沒寫 `ble_state` 對 provd 的 instance 怎麼辦、也沒寫 deadman 要把 provd 起回來** | `docs/design/254-h23-harness.md:118, 157, 402-405` |
| RB6-6 ✅ | health 行 = `boot_id ts bluetoothd hci0_powered adv_registered_once privacy sc sc_file bondable`,**不含 committed / trial** → `health.get` 的 `compute()` 不碰 `IsTrial()`;`IsTrial()` = fork `batman-slot is-trial`,`run` 預設逾時 60 s(F-P27) | `health/health.go:155-162`;`cmd/batman-provhelper/main.go:138, 598` |
| RB6-7 ✅ | helper `net.apply` + 信封 `network/update` → `netUpdate`,**以版本鏈驗、不收 owner-op**(`// version chain, no owner-op (219 §5.3)`);其餘 owner-op 動詞 `verifyOwnerOp(h, typ, body, ownerPubs(rec))` 後 `resolve()`;`stateChanging` 名單 = `claim.verify / claim.replay / net.apply / network.leave …` | `node/node.go:735-736, 744-761, 177` |
| RB6-8 ✅ | `sock.Serve` 今天仍是同步 accept 迴圈(`serveConn` 在迴圈內同步)、`serveConn` 每連線自己的 buf、`Read` 前武裝 `Idle` deadline、`h(m)` 同步 | `sock/sock.go:107-116, 136-170` |
| RB6-9 ✅ | `check-prov-test-gate.sh` 只讀 `/etc/batman-build` 的 `BATMAN_VERSION` 與 `BATMAN_WBOX`,**沒有固定 key 清單** → 加 `BATMAN_DIRTY_WHY` 對它無影響;`build-board.sh:189-190` 的 `cmp` 比的是同一支 stamp 腳本的兩份輸出 | `scripts/check-prov-test-gate.sh`;`scripts/build-board.sh:189-190` |
| RB6-10 ✅ | harness 今天的 `DV_*` 設定全由環境變數給(`DV_PROV_TOOLS / DV_BT305_TOOLS_ROOT / DV_CRYPTPROBE …`),沒有 `DV_FW_TREE`;firmware 對 Batman 的 pin 在 `feeds.conf.default:8`(`^34f216da…`),**方向是 firmware pin Batman**,Batman repo 沒有任何「firmware commit」的記錄 | `grep -rhoE 'DV_[A-Z0-9_]+' scripts/`;`firmware-2710/feeds.conf.default` |
| RB6-11 ❌ | 04 實機(F-P41 le_states、L10 / L11 目錄 bind、patched kernel 上 `btmgmt add-adv` 行為)本輪未驗,與前幾輪相同 | — |

## 1. BLOCKER

無。

## 2. MAJOR

**M1. §4.8 臂 2 閘門的條件 (3)「`BATMAN_DIRTY_WHY == wbox-<name>`」在現行 build 流程下只有 `test` 這一個變體能成立;其他 20 個變體(含所有帶 patch 的 prov_test 變體)stamp 時 `feeds/batman` 已被 `wbox_apply` 改過 → `$why` 多一項 `feeds/batman-modified` → 閘門永遠 FAIL。設計沒說臂 2 跑在哪個變體,照 h23 的慣例(單位各自指定 `helper=<variant>`)實作者很可能挑一個 helper 變體,臂 2 就跟 v5 一樣是死閘。另外證據鏈的另一端(`kpatch-254-adv.sha256`)在 §12 的工作順序下沒有人能在對的時間寫。**
- 情境 A:`prov-sec-adv-len-254` 臂 2 跑在 `helper-flap`(或任何有 patch 的變體)的 `-wbox` image 上。`/rom/etc/batman-build` 的 `BATMAN_DIRTY_WHY=feeds/batman-modified wbox-helper-flap`(RB6-1)。閘門要 `== wbox-helper-flap` → FAIL、不執行。D3 又沒有正向見證。v6 自己寫的 CI 負對照 (b)「DIRTY_WHY 多一項 → FAIL」會 PASS,但它證的正是現場永遠 FAIL。
- 情境 B(sha 檔):§4.8 (2) 要 `git show $FW:<patch> \| sha256sum == scripts/dv/data/kpatch-254-adv.sha256`,「firmware PR / pin bump PR 更新;H3 可先 merge」。但 (i) patch 文字在 firmware PR 才寫出來,H3(Batman PR,先 merge)沒有 sha 可寫 → 只能放空或假值 → 單位 FAIL 到某個**第三個** Batman PR 補上;(ii) firmware repo 的 PR 改不了 Batman repo 的檔(RB6-10:pin 方向是 firmware → Batman,Batman 不記 firmware commit),所以「pin bump PR 更新」沒有主體;(iii) 之後 patch 若改版(例如 D3 的上游 commit id 查出來後重寫標頭),sha 不符 → 單位 FAIL(fail-closed,對),但沒有任何機制在 **build 時**就抓到,只會在全套跑完才 FAIL。
- 證據:RB6-1、RB6-2、RB6-10;設計 §4.8 (2)(3)(4)、§12、§10 第 6 點、§17 第 1 列。
- 修:
  1. **臂 2 綁定 `test` 變體**(唯一無 patch 的 prov_test 變體,RB6-1;`btmgmt` 依 D9 在所有 `-wbox` 變體都有):§4.8 (3) 寫成 `BATMAN_WBOX == test ∧ BATMAN_DIRTY_WHY == wbox-test`,(4) 的 helper marker 檢查保留(`test` 本來就是 prov_test)。不要把 `feeds/batman-modified` 放進允許集合——它也是「feeds/batman 有本地修改」的訊號,放行會讓誠實的 DIRTY 理由失效。單位 header 寫「臂 2 只在 `test` 變體」;h23 §6.3 該列同步。
  2. **patch 文字的正本放 Batman repo**:`scripts/dv/data/999-batman-eir-adv-flags-oob-254.patch`(H3 PR 就能帶,因為 patch 內容可以先寫、D3 commit id 進標頭時兩邊同改);firmware PR 把它複製到 `target/linux/bcm27xx/patches-6.6/`。閘門 (2) 改成 `git show $FW:<path> \| cmp - $REPO/scripts/dv/data/<patch>`(不要 sha 檔;B5 M1 修法 2 已建議)。**build 時的見證**:firmware `build-board.sh` 第 4 步(或 `check-board-patches.sh` 旁邊)加一行 `cmp target/linux/bcm27xx/patches-6.6/999-…-254.patch feeds/batman/scripts/dv/data/999-…-254.patch \|\| exit 1` → pin bump 若讓兩邊漂移,**build 就拒**,不必等全套。這一行是 firmware PR 的一部分,寫進 §2 firmware 列與 §10 第 6 點。
  3. §4.8 的「H3 可先 merge,不需要事先知道加 patch 的 commit id」改寫成「H3 帶 patch 正本;firmware PR 複製 + build 時 cmp;在 firmware PR merge 並 pin 到含它的 commit 之前,臂 2 的閘門 (2) FAIL(預期,寫進 known-failures 並到期)」。
  4. CI 單元案例改對應:`(c) commit 無 patch`、`(d) 7 碼歧義`、`(e) 樹裡的 patch ≠ repo 正本`、`(f) WBOX ≠ test`、`(g) DIRTY_WHY 多一項`;mutant 拿掉任一條件 → 該案例變 PASS → FAIL。

**M2. 臂 2「停 provd」與既有 BLE / prov harness 的生命週期沒有對上:(a) 今天的 BLE preflight P6 / tier A #5 `ble_state` 在 provd 註冊著時就 FAIL(`leftover: 1 advertising instance`),P2 image 一上 04 / 02,整個 BLE 套件的 preflight 就紅;(b) `ble-periph-254.sh` 的 `adv-on` / `adv-off` / BLE deadman 無條件 `rm-adv 1` = 直接拔掉 provd 的 instance(BlueZ 不知情);(c) 兩個 deadman(BLE、prov)到期都不把 provd 起回來 → 任何「停 provd 才跑」的單位(臂 2、`prov-sec-bond`、`ble-rpa` N1、`prov-sock`)在主機死掉後讓節點**沒有廣播直到下次重開**,而 autocommit 只 WARN(F-P20),沒有人會注意。設計 §4.8 只寫了臂 2 自己的副作用清單,§5 沒有這一列,§10 第 2 點也沒交給 H3。**
- 情境:全套跑到 BLE 區塊(在 prov 區塊之前或之後都一樣):`dv-preflight.sh:83` 對 04、02 跑 `ble_state` → `adv_instances` 回 1(provd 的)→ `FAIL leftover` → P6 FAIL → BLE 套件不跑。或:`prov-sec-bond-254` 停 provd → 主機 ssh 斷 → prov deadman 到期:起 helper / joinwatch / openmanetd,**不起 provd** → 04 回 A committed 後沒有 BLE 管理面,直到有人重開。或:`ble-rpa-254`(provd 模式,h23 :404)跑完 `role_fire_restore` 的 `rm-adv 1` → provd 的 BlueZ client 狀態仍是 registered、kernel instance 已沒了 → provd 的 `ctl` 看 `ActiveInstances`(BlueZ 的數)仍 1、不重註冊 → 節點靜默無廣播到下一個觸發(連線 / 900 s RPA 重註冊)。
- 證據:RB6-3、RB6-4、RB6-5;設計 §3 廣播列(只列 kernel 與 root 手動為第二 / 第三寫者,沒列 harness)、§4.8、§5、§10 第 2 點。
- 修:
  1. §3 廣播列加第四個寫者 **harness(`rm-adv`,只准在 provd 停止時)**;規則:**任何要碰 mgmt 廣播 / 翻 bondable / 掛 agent 的單位先 `/etc/init.d/batman-provd stop`,結束 `start`;`ble_state` 的「leftover instance」判定改為「provd 跑著 → 期望 1(且 `ActiveInstances` = 1);provd 停著 → 期望 0」**(instance 數對不上才 FAIL);`cmd_adv_on` 先斷言 provd 未 running(h23 :118 已寫,要真做)。
  2. **兩個 deadman 的 restore 都加「provd 應該在跑 → `start`」**(BLE deadman 在 `bluetoothd restart` 之後;prov deadman 在 helper 之後),並 `rm-adv 5`(臂 2 的 instance)/ 清 instance 2+(harness 用的);寫進 h23 §3 deadman 列與本文件 §5 新列 **L83「harness 停了 provd 後主機死掉」**(今天:provd 不存在;P2 後:deadman 起回 provd、`ActiveInstances` 回 1;負對照:deadman 不起 → 到期後 04 無廣播)。
  3. 臂 2 自己:`trap` 在任何退出路徑 `rm-adv 5` + `start provd` + 斷言 `ActiveInstances == 1`(§4.8 現在只在正向路徑做)。
  4. `ble-rpa-254` provd 模式的三態與 `rm-adv 1` 互斥:provd 模式下 harness **不准** `rm-adv`,只觀測(btmon);寫明。

**M3. `expectGen` 的清除與 reconcile 綁在一起,而「清」要等「回應處理完 **且** `ctl` 之後又成功輪過一次」—— `ops` 是 FIFO、一次一則,下一個改 record 的動詞在上一個回應後**立刻**送出就再設 `expectGen=true`,`ctl` 永遠等不到「之後一輪」→ `expectGen` 永不清、reconcile 永不跑 → 旁路撤銷(被 root `provclient owner.remove` 移除的 owner、helper 重啟後 record 被改寫)在有連續動詞的 session 存在時**無上界**地不生效。v5 M2 要的是「延後到動詞結束(≤ 960 s)」,v6 做出來的是「只要有人一直送就永遠不」。**
- 情境:owner X 被 root `provclient owner.remove` 移除(L78),X 的 session 還活著。X 的 app(或拿到 X 金鑰的人)每 3 s 送一個 `ssh_keys/set`:helper 以已存 owners 拒 `EForbidden`(毫秒回),provd 回 `E_FORBIDDEN`、計失敗;但每一則送出前都設 `expectGen=true`,回應後 `ctl` 還沒輪完下一則又來 → 從不清 → 從不 reconcile → X 永遠讀得到 `info.net`(`net_id` / `net_version` / `unfinished`)。3 次失敗斷線的規則只對 `claim / auth` 計(§4.3「認領失敗 3 次」),`ssh_keys/set` 的 `E_FORBIDDEN` 不計;就算計,X 換送合法但無害的 `network/update`(版本鏈驗,RB6-7,舊版本 → `EStaleVersion`)也一樣。誠實的情境也會碰到:owner 做 join 後接著 ssh_keys/set、再 join 第二張網……每個都在前一個回應後 < 4 s 送出。
- 證據:設計 §1.3 撤銷列原文「回應處理完 … **且 `ctl` 之後又成功輪過一次**才清 … **清掉後第一次** … 逐 session reconcile」;§4.3 `ops` 「一次一則」、FIFO;RB6-7(拒絕路徑毫秒回)。
- 修(§1.3 該列、§4.3、L82、`cache_test`):
  1. **reconcile 綁在每個改 record 動詞的回應上,不綁在清除上**:回應抵達(任何碼;含 `HELPER_WAIT` 後遲到的、含 `ops` 重連視為回應)→ 立刻排 `info.owners`(`ctl`)+ `psks.get`(`ops`,排在佇列最前,不是最後)→ 兩者都回來後逐 session reconcile。`expectGen` 改成「`ops` 上是否有改 record 動詞在飛」的布林,**只用來把 `ctl` 看到的 `(state, Generation)` 變化從「旁路 → 全斷」降為「待重拉」**;它不再控制 reconcile 的時機。
  2. 旁路規則補上界:在飛期間 `ctl` 看到的變化累積成一個 `pendingSide` 旗標;該動詞回應後的 reconcile 若發現集合沒變(例如旁路只是 `resolve()` 重建、gen 變但 owners / PSK 不變)就清旗標;集合變了 → 逐 session 比對(比「全斷」精確,且涵蓋 F-P55 的兩種旁路)。沒有在飛時的旁路變化照舊全斷。
  3. 負對照加一臂:`cache_test`「在飛動詞回應後立刻再送一個,期間 owners 少一把 → 第二個動詞回應後 ≤ 1 輪被斷」(mutant = v6 的「清掉後才 reconcile」→ 永不斷 → FAIL)。

**M4. `HELPER_WAIT`(330 s)到期時,`ops` 佇列裡**還沒送出**的第二個動詞怎麼辦沒寫;照 §4.3「期間 `ops` 上後續請求繼續排隊」,它會在前一個動詞結束後(最壞 960 s)被送給 helper 執行,而它的 session 早在 330 s 就收到 `E_BUSY`、可能已重連並依 `info` 做了相反的決定。非冪等動詞在 app 放棄後才執行 = 無回應的副作用。**
- 情境:owner 手機 A 送 `network/join`(helper 走 Finish-first 路徑,≈ 900 s)。第二支擁有者手機 B(或 A 重連後的新 session)送 `network/leave` 排在後面。330 s:B 收 `E_BUSY{3:"outcome unknown"}`,B 重連、讀 `info`(`unfinished=1`)、等到 `unfinished=0`、看到已入網、決定留下。≈ 900 s:A 的 join 回應回來;provd 接著把**排隊中的 leave** 送出 → 節點離網。B 從沒再要求過。`claim/finish` 排在長動詞後也同構(L24 的「一個 0 一個 7」假設兩個都進 helper;排隊的那個 330 s 後被告知 7,之後卻仍被送進 helper,helper 以 `EBusy` 或成功回,provd 丟棄)。
- 證據:設計 §4.3 `HELPER_WAIT` 段:「到期不關連線 … 回應到了以 `id` 丟棄;期間 `ops` 上後續請求繼續排隊」;§4.3 EOF 規則只講重連時的非冪等不重送,沒講逾時時排隊的。
- 修:**`HELPER_WAIT` 到期 → 若該請求尚未送出 → 從佇列移除(不送),回 `E_BUSY` + detail 3 `"not sent — helper busy"`(與「outcome unknown」分開,app 可直接重試不必查 `info`);已送出的照 v6(outcome unknown,等真回應以 id 丟棄)。** 更好:排隊的請求各自有 `HELPER_WAIT`,從**送出**起算,排隊時另算 `QUEUE_WAIT`(例如 30 s)→ 到期即以「未送出」拒絕;這樣 B 不會白等 330 s。單元:假時鐘「排隊 30 s 未送 → `E_BUSY` 且 helper 從未收到(fake helper 計數 0)」(mutant = 到期仍送 → 計數 1 → FAIL)。

## 3. MINOR

**m1. `HELPER_WAIT` 到期分支「`expectGen` 撐到 `ctl` 看到 gen 變、或 960 s 上限」對 Finish-first 路徑是錯的。** F-P32 / F-P55:一個 `net.apply` 可以先 commit Finish(gen +1,早在 ≤ 300 s)再做自己的(第二次 gen +1 可能在 ≈ 480 s 以後)。330 s 時 `ctl` 早已看過第一次變化 → 依字面 `expectGen` 清掉 → 第二次 gen 變化發生在「沒有在飛」→ 被判旁路 → 已認證 session 全斷(`reason=generation`)。`ops` 連線沒關、真回應一定會到(或 `ops` EOF),所以直接「撐到真回應抵達或 `ops` 重連」即可,960 s 只當保險;M3 的修法已隱含此點,但 §1.3 的字要改。

**m2. `ops` 中途重連(helper 重啟 L11、第 5 條被拒退避)對 `expectGen` 的處置沒寫在 §1.3**(只在 L11 寫「`ops` 重連全量 reconcile 涵蓋」)。寫明:`ops` EOF = 在飛動詞的回應(outcome unknown,對該 session `E_BUSY`),走 M3 的 reconcile;重連後第一個動詞送出前先完成 `psks.get` + `info.owners` 重拉(helper 重啟可能重寫 record,F-P55)。

**m3. 「候選」session(psk_owner 交握成功、尚未 `auth/owner`)的 reconcile 規則缺:它沒有 `owner_key_id`。** 照 §1.3 字面「`owner_key_id` 不在集合 → Disconnect」對候選不可判。寫:候選以**它成功的那把 `psk_owner[i]` 的值**比對新集合(值變 / 消失 → Disconnect `reason=psk-rotated`);`psk_owner` 由 TagKey 導出,只在重新認領時變,所以常態不斷。

**m4. `BATMAN_FW_COMMIT` 是 `printf %.7s`(固定 7 碼,不是 `rev-parse --short`),樹長大後 7 碼可能歧義 → 閘門 (1) FAIL(fail-closed,對,但是假 FAIL)。** 今天 0 重複(RB6-2)。stamp 多印 `BATMAN_FW_COMMIT_FULL=<40>`(與 `BATMAN_DIRTY_WHY` 同一個 PR),閘門優先用它;沒有時退回 7 碼。順便:`DV_FW_TREE` 的樹若沒 fetch 到該 commit 也是 FAIL,單位訊息要印「`git -C $DV_FW_TREE fetch` 後重跑」而不是只印 FAIL。

**m5. 「不新鮮」只以 `info.state` 的成功計,而 `info.state` 的 key 5 走 `IsTrial()` 快取 + single-flight,底下是 fork `batman-slot is-trial`、`run` 逾時 60 s(F-P27、RB6-6);`health.get` 不碰它(RB6-6)。** SD 卡 I/O 卡住時:`info.state` 在 helper 內等 single-flight ≤ 60 s → `ctl` 的 10 s 單則逾時 → 關 `ctl` 重連 → 重送 `info.state` 又卡 → 60 s 後撤廣播 `reason=helper`,**雖然 `health.get` 每次都成功**。fail-closed 沒錯,但撤的理由不實。修:(a) `ctl` 一輪的順序固定 `health.get` 先;(b) 撤廣播的「不新鮮」以 **`health.get`** 的最近成功計,STATUS 0x0E 以 `info.state` 計(兩個計時器);(c) helper 的 trial 快取改 stale-while-revalidate(有舊值就先回舊值、背景刷新),exec 逾時 ≤ 5 s(`run` 可帶逾時)。L71 的 `kill -STOP` 臂不受影響(兩個都無回)。

**m6. 臂 2 的 31 B 資料要寫成具體位元組。** mgmt `add_advertising` 先 `tlv_data_is_valid` 驗 TLV 結構,亂填會被 `INVALID_PARAMS` 拒 → 依 §4.8「mgmt 拒絕也算通過」= 假 PASS。用 F-P10 實跑那組(`0x1E 0xFF …` 一個 30 B manufacturer AD),並把「mgmt 回 INVALID_PARAMS 算通過」限縮為「**patched kernel 的拒絕碼**(待 D3 commit 定)」,未 patch 的 kernel 對這組資料是接受後 panic,不是拒絕。

**m7. `BATMAN_DIRTY_WHY` 的值可含空白與多個 token(`untracked:<files> …`),harness 的 `sed -n 's/^BATMAN_DIRTY_WHY=//p'` 取整行即可;h23 §4.2 的 key 清單是文件,`check-prov-test-gate.sh` 沒有 key 清單(RB6-9)→ §4.8 (3) 的「`check-prov-test-gate.sh` 兩邊同一腳本產出不受影響」正確,但「h23 §4.2 key 清單同步」是改文件不是改 gate,寫清楚免得實作者去找不存在的清單。

**m8. 文字**:§12 第 1 點「本設計(現 v5)」應為 v6;§1.3 撤銷列與 §4.3 快取段各自寫了一遍撤銷規則,M3 改完後只留一處、另一處引用。

## 4. 我核過、成立的(§17 說修了、我確認真的修了)

| v5 發現 | v6 | 結果 |
|---|---|---|
| B5-M1 / A5-M1 閘門互斥、`PROV_TEST` 非 key、無主機樹 | `DV_FW_TREE` + `rev-parse --verify --quiet` + `cat-file -e` + sha + `BATMAN_DIRTY_WHY` + helper marker | ⚠️ 工具行為全部對(RB6-2:7 碼可解、歧義 / 不存在都非 0、`cat-file -e` 能問某 commit 的樹、`show \| sha256sum` 可用);**但條件 (3) 只在 `test` 變體成立、sha 檔沒有合法的寫者時序 → M1** |
| B5-M2 / A5-M2 撤銷缺歸因 | `expectGen` 由 `ops` 擁有、在飛只標待重拉、回應後 reconcile、無在飛才全斷 | ⚠️ 方向對、`prov-netjoin-254` 的「join 期間不斷」正向成立;**清除條件可被連續動詞餓死 → M3;Finish-first 兩次 bump → m1** |
| B5-m1 / A5-m1 `add-adv 1` 覆寫 | 停 provd、instance 5、`rm-adv`、前後 `advinfo` | ✅ 對 provd 本身;**對 harness 其餘部分的互動 → M2** |
| A5-m2 helper 重啟換 state 不換 gen | 失效鍵 `(state, Generation)` | ✅(`boot.Run` 每次啟動都跑,A5 V9) |
| A5-m3 L80 ≤ 15 s | 算法寫明 | ✅ |
| A5-m4 / B5-m2 `/rom` 自己 sed、`bt-uart-305` 不同套 | §4.8 明寫 | ✅ |
| B5-m3 已斷裝置 Disconnect 無回覆 | 逾時 5 s + 重盤點 `Connected=false` = 已斷、上限 3 輪 | ✅ 與 `device.c` 一致 |
| B5-m4 `ERate` 連續 > 120 s | §4.1 | ✅ |
| B5-m6 認領成功斷其他含假路徑 | §1.3 L24 列 | ✅ |
| B5-m7 psk 模式 32 B msg1 仍 6 次 | §4.2 | ✅ |
| Noise / 假 msg2 | §4.2 文字與 v5 相同:`e'(32) ‖ random(48 + len(node_cert) + 16)`、2 DH、6 次 `ReadMessage` 不 break、長度檢查在前、`Config.Random` 餵向量 | ✅ 未動(B5 已逐條核過 `state.go`) |
| GATT 快取 | CTRL 常數、STATUS 來自 `ctl` 快取、未填 / > 60 s → 0x0E | ✅(新鮮度的量法見 m5) |
| dbus policy | 8 條方法、無 own / DBus destination / receive_sender;root 回呼行 gate | ✅ 未動(B5 RB5-11) |
| `network/update` 成員轉送 | provd 成員角色 → `net.apply`(信封 type `network/update`) | ✅ helper 走版本鏈、不收 owner-op(RB6-7),與 219 §5.3 一致 |
| 時間預算 | 撤廣播 4 + 2 + 1 (+2) ≤ 9 s;`ctl` 單則 10 s;`ERate` 120 s;`HELPER_WAIT` 330 > leave 165 / apply 180 | ✅ 算術對;`health.get` 不依賴 exec(RB6-6);**排隊請求的等待沒上界 → M4** |

## 5. 負對照盤點

| 防線 | 有 | 缺 |
|---|---|---|
| 閘門 (1)(2)(4) | wsl.17 image → FAIL;CI 五案例 | **(3) 的現場正向在 `test` 以外的變體不存在**(M1);patch 正本 vs 樹 `cmp`;build 時 cmp(M1) |
| 自家動詞在飛不撤 | `cache_test` 在飛臂、`prov-netjoin-254` L82 | 連續動詞下旁路仍會被撤(M3);Finish-first 兩次 bump 不誤判(m1) |
| 排隊請求逾時 | — | 未送出的到期不送(M4) |
| harness 停 provd 後主機死 | — | deadman 起回 provd、`ActiveInstances` 回 1(M2 L83) |
| `ble_state` 與 provd 並存 | — | provd 跑著期望 1 / 停著期望 0(M2) |
| 臂 2 資料 | — | 具體位元組、拒絕碼限縮(m6) |
| 假 msg2 等長 / churn / stale-while-revalidate / L75 / L80 / L81 | 單元 + mutant | ✅ |

## 6. 誠實界線

有寫且對:RPA 900 s;BLE 單連線;ADV 自檢只擋自己;`adv_registered_once` 量 kernel;autocommit 只 WARN;被攻陷 provd 的能力;`psk_member` 在 update 進行中的空窗;無 provd 保留位;殭屍連線;F-P41 ⚠️;kernel patch 不在 #275 見證內;`model` fail-open;撤銷在重拉完成前新連線仍以舊集合放行;臂 2 在未 patch 的 kernel 上 = panic。
要改:§4.8「H3 可先 merge、不需要事先知道 commit id」(M1:需要 patch 正本);§1.3 撤銷的上界(M3:今天的字沒有上界);§4.3 `HELPER_WAIT` 對排隊請求的語意(M4);§3 廣播列的寫者清單(M2:harness 是第四個);m5 撤廣播 `reason=helper` 的實際成因。

## 7. 判定

**APPROVE-WITH-CHANGES** — 0 BLOCKER / 4 MAJOR / 8 MINOR。

v5 的兩個 MAJOR 各修了一半。閘門:工具鏈(`rev-parse` / `cat-file -e` / `DIRTY_WHY` / helper marker)全部實跑成立,但 stamp 在 `wbox_apply` **之後**跑,任何有 patch 的變體 `why` 都多一項 `feeds/batman-modified`,條件 (3) 只有 `test` 變體能過,而設計沒指定變體;sha 檔則沒有能在對的時間寫它的人(firmware PR 改不了 Batman repo,H3 時 patch 還不存在)→ M1(修:綁 `test`、patch 正本進 Batman、firmware build 時 `cmp`)。撤銷歸因:在飛不撤的方向對,但「清掉後才 reconcile」加上「清要等 `ctl` 再輪一次」讓連續動詞把 reconcile 餓死 → M3(修:reconcile 綁回應,不綁清除)。本輪分工新抓到兩條生命週期:harness 的 `ble_state` / `rm-adv 1` / 兩個 deadman 都不知道 provd 存在,P2 image 一上節點 BLE preflight 就紅、停了 provd 的單位死掉後節點無廣播到重開 → M2;`HELPER_WAIT` 到期時排隊未送的非冪等動詞之後仍會被送進 helper → M4。其餘(Noise / 假 msg2 未動、GATT 快取、dbus policy、`network/update` 成員路徑、時間算術、v5 的 MINOR)對原始碼核過成立。依通用規則 MAJOR 開著就要改 v7 並整份再審;04 實機證據(F-P41、L10 / L11)仍欠,與前幾輪相同。
