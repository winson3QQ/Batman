# #254 PR-P2 `batman-provd` 設計 v7 — 對抗式審查 B(第 7 輪,整份重審)

審查對象:`scratchpad/254-p2-impl.md` v7 全文 §0–§18。方式:§13–§18 一律不採信,從現場出發(全套在 rc image 上跑到 `prov-sec-adv-len-254` 臂 2;擁有者認領後立刻 join;擁有者連著時 root 用 `provclient` 改 record;兩支手機排隊;harness 死在 `SOCK_ONLY` 單位中),逐條對 helper / harness / firmware 腳本、kernel 6.6.138、BlueZ 5.72 原始碼重核。分工 B:撤銷狀態機(`inFlight` / `pendingReconcile`、遲到回應、`QUEUE_WAIT` 丟棄、`ops` 重連、helper 重啟、兩 session 交錯、reconcile 插隊與額度)、閘門證據鏈(正本 → firmware 副本 → build `cmp` → 執行期 `git show | cmp`、改版時誰動什麼)、harness 的 provd 感知(`ble_state` 語意、deadman 還原順序、`rm-adv 5` 空打)、時間預算、Noise / 假 msg2、GATT 快取、dbus policy、負對照、誠實界線。

**環境誠實界線**:本輪**沒有上 04**(分工不需要;F-P* 實機事實沿用前六輪)。核的是 repo main `34f216d`(乾淨)、firmware `/home/yello/firmware-2710` HEAD `da30986f`(乾淨)、kernel / BlueZ build_dir 原始碼。全部指令在 WSL 實跑(`r7b1.sh`–`r7b6.sh`),節錄在 §0。

## 0. 我自己核過的事實(✅ 實跑 / 原始碼;⚠️ 推論;❌ 未驗)

| # | 事實 | 證據 |
|---|---|---|
| RB7-1 ✅ | **prov 單位的前置 `pr_p9` 對 committed 槽含 wbox image 直接 FAIL**:`case "$(field "$s" ver)$(field "$s" protA)" in *wbox*) echo "FAIL the committed slot carries a wbox image"`;slot B 含 wbox 也 FAIL(「restore it with pr_brewrite」);h23 §4.2 :186「**只進非 committed 槽;一律 hold**」、§3 :143/:147「`-wbox` payload 只進非 committed 槽」。`-wbox test` 是 22 個 build 之一(h23 :214「none + test + 20 變體」) | `scripts/dv/prov-254.sh pr_p9`;`docs/design/254-h23-harness.md:22, 95, 143, 147, 186, 214` |
| RB7-2 ✅ | stamp:`why` 以前置空白累加(`why="$why wbox-$WBOX"`)→ `test` 變體的 `$why` 字面是 **` wbox-test`(前面一個空白)**;`BATMAN_FW_COMMIT=$(printf %.7s "$FW")`,`FW=$(git rev-parse HEAD)`;untracked 掃描清單含 `target`;**今天沒有 `BATMAN_DIRTY_WHY` / `BATMAN_FW_COMMIT_FULL`**(P2 firmware PR 要加) | `firmware-2710/scripts/stamp-batman-build.sh:36-56, 60-77` |
| RB7-3 ✅ | `build-board.sh`:第 2 步 `wbox_apply`(`test` 不套 patch,`lib-wbox.sh:68`)→ 第 3 步 lock → 第 4 步 stamp → 第 7 步 rootfs `cmp` stamp;**`feeds/batman` 是完整 Batman checkout(有 `scripts/dv/*.sh`),但 `scripts/dv/data/` 今天兩邊都不存在**(H3 要建);kernel `KERNEL_FILE_DEPENDS` 含 `$(PATCH_DIR)`,`.prepared_<md5>` 隨之變 → 新 patch 檔觸發重 prepare | `build-board.sh:108-141, 190`;`include/kernel-build.mk:12-13`;`ls feeds/batman/scripts/dv` |
| RB7-4 ✅ | kernel `eir_create_scan_rsp(hdev, instance, ptr)`:**只在 `MGMT_ADV_FLAG_APPEARANCE` / `MGMT_ADV_FLAG_LOCAL_NAME` 旗標時才多加東西**,否則只 `memcpy(scan_rsp_data)` → `btmgmt add-adv -s <31 B>`、flags 0 → 31 B 原樣,**不經任何越界路徑**;`eir_create_adv_data` 在 LE-only 無條件加 3 B Flags(除非資料已含 `EIR_FLAGS`)後 `memcpy` 不檢查(與 F-P10 / F-P60 一致);`hci_set_adv_data_sync`:`cp` 堆疊區域變數、`cp.length = len`(u8)→ 未 patch 時 btmon 會看到 **Length 34**,patch 後 31 → 臂 2 ADV 的 btmon 判定有鑑別力 | `linux-6.6.138/net/bluetooth/eir.c:245-330, 342-368`;`hci_sync.c hci_set_adv_data_sync`;`mgmt.c:8498-8520 tlv_data_max_len` |
| RB7-5 ✅ | kernel `remove_advertising`:instance 不存在 → `MGMT_STATUS_INVALID_PARAMS`;`list_empty(adv_instances)` 也 INVALID_PARAMS;BlueZ `client/mgmt.c:4839 rm_adv_rsp`:status ≠ 0 → `error("Remove Advertising failed …")` + **`bt_shell_noninteractive_quit(EXIT_FAILURE)`** → **`btmgmt rm-adv 5` 在沒有 instance 5 時 rc ≠ 0** | `mgmt.c remove_advertising`;`bluez-5.72/client/mgmt.c:4839-4855`;`src/shared/shell.c bt_shell_noninteractive_quit` |
| RB7-6 ✅ | h23 §4.8.3:**`SOCK_ONLY=1` = 「不碰 dbus / bluetoothd」**(= 無廣播、無 GATT);`set-provd-env` 寫 `provd.env` → restart provd(init **只在 start 讀**);`provd.env` 所在目錄 `/tmp/run/batman-prov-test` 由 `pr_end` / `pr_abort` / **prov deadman** / P9 restore `rm -rf`;prov deadman `role_fire_restore` 今天:`unbind-all`、`rm -rf /tmp/run/batman-prov-test`、helper 寫回 / 起、起 joinwatch / openmanetd / tailscaled,**無 provd** | `254-h23-harness.md:137, 254, 283-285`;`scripts/node/prov-lease-254.sh role_fire_restore` |
| RB7-7 ✅ | **F-P61「沒有任何一處 start / stop `batman-provd`」不準確**:`prov-base-254.sh:207`(p5-restore)、`:222`(overlay-restore)、`:258`(strip-p5-prov)都 `svc stop … batman-provd`(`svc` 只對存在的服務動作,`:62`);`:272` 收尾 `svc start batman-provhelper joinwatch` **沒有 provd**(p5 / overlay restore 之後是重開,strip-p5-prov 不是) | `scripts/node/prov-base-254.sh:62, 207, 222, 258, 272` |
| RB7-8 ✅ | `ble-lib-254.sh ble_state :165-166`:`adv_instances != 0` → `FAIL leftover: <n> advertising instance(s) registered`;BLE deadman `role_fire_restore`:`rm-adv 1` → irk-exposed 則 reboot → 否則 `power off` + `bluetoothd restart` + `wait_bluetoothd`;`cmd_adv_on` / `cmd_adv_off` 無條件 `rm-adv 1`(與 F-P61 這部分一致) | `scripts/node/ble-lib-254.sh:151-166`;`ble-periph-254.sh:42-52, 169-178` |
| RB7-9 ✅ | helper `sock.go serveConn`:每次 `Read` 前 `SetReadDeadline(+Idle)`;`h(m)` 同步、期間不 `Read`;格式錯回 `{1:0, 2:20}` 並關連線(= F-P6 / F-P45);`stateChanging` = `claim.verify / claim.replay / net.apply / network.leave …`(`node.go:177`) | `feed/batman-prov/src/sock/sock.go:136-170`;`node/node.go:177-206, 248-252, 392` |
| RB7-10 ✅ | kernel `remove_advertising` / `add_advertising` 與 F-P54 / F-P60 一致;BlueZ `btmgmt` 的 `rm-adv` 實作在 `client/mgmt.c`(`tools/btmgmt.c` 只有 61 行 shell 殼) | 同上 |
| RB7-11 ❌ | 04 實機(F-P41 le_states、L10 / L11 目錄 bind、patched kernel 上 `add-adv` 行為、`-wbox test` hold 進 B 的流程)本輪未驗 | — |

## 1. BLOCKER

無。

## 2. MAJOR

**M1. 臂 2「固定跑在 `-wbox test` 變體」與 harness 的槽政策相撞:prov 單位前置 `pr_p9` 對「committed 槽含 wbox image」直接 FAIL,h23 規定 `-wbox` payload 只進非 committed 槽且一律 hold;而閘門讀的是 `/rom/etc/batman-build`(= 正在跑的 image)。照 v7 字面,全套在 rc image 上跑時 `/rom` 沒有 `BATMAN_WBOX` → 閘門 (3) 永遠 FAIL(fail-closed,但 D3 的正向見證在全套裡**永遠不會執行**);要讓它成立,節點必須正在跑 `-wbox test`,而那只有「hold 進 B 的 trial 內」一種合法狀態,設計沒寫、副作用沒列。**
- 情境:全套 prov 區塊,04 A committed = rc V(release)。`prov-sec-adv-len-254` 臂 2:`sed /rom/etc/batman-build` → `BATMAN_WBOX` 缺 → (3) FAIL「閘門資料缺」。實作者的兩種反應都錯:(a) 先把 `-wbox test` 燒進 A committed → `pr_p9` 對每個後續 prov 單位 FAIL(「the committed slot carries a wbox image」);(b) 放寬 (3) 接受 release image → 證據鏈斷(release image 的 stamp 沒有 wbox,kernel patch 的 witness 就只剩「樹裡有檔」,又回到 v5 的死閘 / 假 PASS 二選一)。
- 證據:RB7-1;設計 §4.8「固定跑在 `-wbox test` 變體」、「harness 自己 `sed` 節點 `/rom/etc/batman-build`」;§5 沒有「臂 2 在 trial 內」的列;§9 單位清單沒有 hold / OTA 步驟;§4.8 副作用清單只有「provd 停 / 起一次、instance 5、數秒廣播」。
- 修:
  1. 臂 2 **定義為 hold 型單位**(與 `prov-provd-dos-254` 同型):`pr_begin` → `pr_ota_b` 推 `-wbox test` payload hold 進 B → trial 內跑閘門 (1)–(4)(此時 `/rom` = `-wbox test` 的 squashfs,`BATMAN_WBOX=test`、helper marker 第 2 行都成立)→ 停 provd / `add-adv 5` / btmon / `rm-adv 5` / 起 provd → `back_to_a` → `pr_brewrite`。閘門 (3) 之前加一條:**本單位在 `batman-slot` 報 trial 且 active ≠ committed 時才執行**,否則 FAIL「臂 2 只在 `-wbox test` trial 內」。
  2. 副作用清單補:OTA 一次(B 槽重寫、`pr_brewrite` 收尾)、trial 視窗(autocommit hold,15 分級)、trial 內 provd 的 STATUS `updating=1`、L21 的改狀態動詞 `EBusy`(臂 2 不打改狀態動詞,無影響)、02 連線斷一次、整體時間 ≈ 15–20 分。
  3. §5 加一列「臂 2 在 `-wbox test` trial 內;主機死 → 一律 hold 的規則:`HELD` 到期 revert → bad-slot → P9 印 restore」(h23 :303 已有同型列,引用即可)。
  4. CI 單元案例加:「`/rom` 無 `BATMAN_WBOX` 且非 trial → FAIL 不執行、不 OTA」;「committed 槽含 wbox → `pr_p9` FAIL(既有)」。
  5. 誠實界線:臂 2 的 kernel = `-wbox test` build 的 kernel,**不是 release image 的 kernel**;兩者同一棵樹、同一 HEAD(條件 (1)(2) + `DIRTY_WHY` 證明),但不是同一個二進位。寫明,並把「release image 的 kernel 與 `-wbox test` 的 kernel 同 sha」加進 build gate(兩個 build 的 `boot/kernel*` 或 `vmlinuz` sha 相等;只有 wbox 時 kernel 不會變,這條等於零成本的證據)。

**M2. 撤銷狀態機漏了「reconcile 之後 `ctl` 的 `(state, Generation)` 基準怎麼更新」:provd 自己的**快動詞**(`claim.verify` 毫秒、`ssh_keys.set`、`network.leave` 常態數秒)回應 → `inFlight` 歸 0、reconcile(`info.owners` + `psks.get`)在 < 1 s 內完成、`pendingReconcile` 清掉;`ctl` 下一輪(≤ 4 s 後)第一次看到 gen 變了,此時 `inFlight == 0 && !pendingReconcile` → 依字面判「旁路」→ 已認證 / 候選 session 全 Disconnect(`reason=generation`),**包括剛認領成功的擁有者**。§9 的單元「`claim.verify` 回 0 → `ctl` 輪一次 → … 不斷」預期相反,文字與測試互相矛盾;實作者二選一都會錯(照文字 = 每次認領後擁有者被踢;照測試去「修」= 很容易把旁路判定整個關掉)。**
- 情境(主流程):手機認領 → `claim.verify` 0 → provd 升擁有者、斷其他 session、`pendingReconcile` 設 → reconcile 200 ms 完成 → `ctl` 在 t+2 s 的 `info.state` 回 gen 2(上次 1)→ 旁路 → 擁有者被斷,log `session revoked reason=generation`。app 重連、再做 join,同樣在 join 回應後 4 s 內再被斷一次。F-P55 的長動詞路徑反而沒事(`ctl` 在飛期間已看過變化、基準已更新)。
- 證據:設計 §1.3 撤銷列「`ctl` 看到 `(state, Generation)` 變時:只有 `inFlight == 0 && !pendingReconcile` 才判旁路」;§3 快取列「失效鍵 = … `!=` 上次」;reconcile 的內容只有 `info.owners` 與 `psks.get`(兩者都不回 gen);§9 `cache_test` 第 4 臂;`claimVerify :548` 在回應前 commit(F-P55)。
- 修(§1.3 該列、§3、§9):
  1. **reconcile 的內容加 `info.state`**(`ctl`,與 `info.owners` 一起插隊),三者到手後:逐 session 比對 **且把 `ctl` 的 `(state, Generation)` 基準設成這次 `info.state` 的值**;之後 `ctl` 只以「相對這個基準的變化」判旁路。
  2. 序號:`ctl` 每則 `info.state` 帶送出序號;reconcile 設基準時記下序號,**序號更早的回應一律不比對**(避免「回應抵達前送出、reconcile 後才回來」的舊值把基準又改回去 → 下一輪再被判旁路)。
  3. 在飛期間(`inFlight > 0` 或 `pendingReconcile`)`ctl` 看到的變化:標待重拉**並更新基準**(v7 只寫「只標待重拉」)。
  4. 單元(負對照):fake helper `claim.verify` 回 0、reconcile 立刻完成、`ctl` 下一輪 gen 1 → 2 → **不斷**(mutant = 不設基準 → 斷,這才是 v7 字面);同一臂加「reconcile 完成後 root `provclient` 再改一次 gen → 這次才斷」證明旁路判定還活著。

**M3. `HELPER_WAIT` 到期後 `ops` 的「槽」是否釋放沒寫,而 v7 的 `inFlight` 計數語意(「回應抵達 −1,含 `HELPER_WAIT` 後遲到的」、「`ops` EOF 歸 0」)只有在**到期後繼續送下一則**時才需要;一旦繼續送,下一則就坐在 socket buffer 裡等 helper 做完長動詞(helper `h(m)` 期間不 `Read`,RB7-9),它的 session 在 +330 s 收到「outcome unknown」、可能已重連並依 `info` 做了相反決定,動詞卻在 ≈ 960 s 才執行 —— 這正是 B6 M4 的情境,只是換成「`HELPER_WAIT` 之後送出的那一則」。`QUEUE_WAIT` 只管「尚未送出」,擋不到它。**
- 情境:A 的 `network/join` 走 Finish-first(≈ 900 s)。+330 s A 收 `E_BUSY{outcome unknown}`;provd 若視槽已空,把 B 在 +340 s 送的 `network/leave` 送進 socket;B 在 +670 s 收 `E_BUSY{outcome unknown}`、重連、讀 `info` 看到入網、決定留下;≈ 900 s helper 做完 join 立刻 `Read` 到 leave → 執行 → 節點離網,B 沒再要求過。
- 證據:設計 §4.3「`HELPER_WAIT = 330 s`(從送出起算)→ 到期不關連線 … 回應到了以 `id` 丟棄並 `inFlight −1`」;§1.3「`inFlight`(… 送出 +1;回應抵達 −1,含 `HELPER_WAIT` 後遲到 …)」;RB7-9(helper 連線內嚴格一次一則)。
- 修:**`HELPER_WAIT` 到期只改「對 session 的回覆」,不釋放 `ops` 的槽**:`ops` 維持 busy 直到真回應抵達、或 960 s 上限關 `ops` 重連;期間新請求全部走 `QUEUE_WAIT`(30 s → `E_BUSY{not sent}`)。`inFlight` 退化成 0/1(可保留計數型別,但單元斷言它永遠 ≤ 1);`ops` 重連時歸 0 照舊。單元:假時鐘「t=0 送 A;t=330 A 收 unknown;t=340 B 排隊;t=370 B 收 not-sent 且 fake helper 只收過 1 則;t=900 A 的真回應抵達 → 丟棄、reconcile、槽釋放」(mutant = 到期釋放槽 → fake helper 收到 2 則 → FAIL)。

**M4. harness 的 provd 感知只做了「停了 provd」那一半:`SOCK_ONLY=1`(= 不碰 dbus / bluetoothd,RB7-6)是由 `provd.env` 經 init 在 start 時注入環境,**init 只在 start 讀**;prov deadman / `pr_end` / `pr_abort` / P9 restore 都 `rm -rf /tmp/run/batman-prov-test`(把 `provd.env` 刪掉),但 provd 行程還活著、環境還是 `SOCK_ONLY=1` → 節點沒有廣播、沒有 GATT,直到有人 restart provd 或重開;v7 L83 / deadman 的「`start batman-provd`」對已經在跑的 provd 是 no-op。autocommit 只 WARN(F-P20),沒人會發現。**
- 情境:tier A `prov-sock-254`(h23 :405「停 provd 才跑」)或任何 `set-provd-env SOCK_ONLY=1` 的 sock 單位(`prov-sec-claim-brute`、`prov-sec-psk-timing`、`prov-sec-hog` 的 sock 臂):peer 跑一半主機死 → prov deadman 到期:`unbind-all`、`rm -rf /tmp/run/batman-prov-test`、起 helper、`start batman-provd`(已在跑 → 無事)→ 04 回到 A committed、helper 正常、**provd 仍是 `SOCK_ONLY`**,BLE 管理面消失直到下次重開(可能數天;這類單位沒有 restore reboot)。同樣的事也發生在正常收尾:`pr_end` 刪了目錄但沒寫要 restart provd(h23 :137 只寫 `rm -rf`)。
- 證據:RB7-6;設計 §3 `provd.env` 列(「只在 test init 以 root 讀 → `procd_set_param env`」)、§4.6、L83(只涵蓋「停了 provd」)、§9「兩個 deadman restore 加 `start batman-provd` + `rm-adv 5`」。
- 修:
  1. 規則:**任何刪 `provd.env` 的路徑都 `restart batman-provd`**(不是 `start`):prov deadman(在 helper 之後、`rm -rf` 之後)、`pr_end` / `pr_abort`(曾 `set-provd-env` 時;或一律 restart,代價只是手機斷一次)、P9 restore 指令;BLE deadman 在 `bluetoothd restart` 之後也改 `restart`(provd 跑著時 L9 會自己重註冊,restart 多此一舉但與 prov deadman 同形、免得兩套規則)。
  2. 收尾斷言(deadman 與 `pr_end` 都做):provd 本次 pid 的 `/proc/<pid>/environ` **不含** `SOCK_ONLY` / `FAST_FAKE_DELAY_MS` / `NO_BRUTE_LIMIT` / `GATT_ENCRYPT_CTRL` / `ADV_LEN_TEST`,且 ≤ 15 s 內 kernel `num_instances = 1`(h23 :604 已有讀對 pid 的方法)。
  3. L83 改名「harness 停了 provd **或改了它的環境**後主機死掉」,負對照:`set-provd-env SOCK_ONLY=1` → 殺主機 → deadman → provd pid 變、environ 乾淨、`num_instances` 回 1(mutant = `start` → pid 不變、`num_instances` 0)。
  4. `prov-base-254.sh:272`(strip-p5-prov 收尾)補 `batman-provd`(RB7-7),F-P61 文字改正。

## 3. MINOR

**m1. 臂 2 的 scan response 臂不具鑑別力。** kernel `eir_create_scan_rsp` 對 instance 只在 `APPEARANCE` / `LOCAL_NAME` 旗標時才多加東西(RB7-4);`-s <31 B>`、flags 0 → 31 B 原樣寫入,未 patch 的 kernel 也不越界 → 「同判定(無 Flags AD)」在 patch 前後都 PASS。而要走到會多加的路徑,mgmt 的 `tlv_data_max_len` 會先扣掉 name / appearance 的長度把 31 B 拒掉。改寫:scan rsp 臂 = 「patch 涵蓋三個 creator(原始碼見證,`eir.h` 簽章)」,**沒有 mgmt 可達的正向見證**;或刪掉這一臂,免得 §9 把它算成一個 PASS。

**m2. `rm-adv 5` 空打 = 失敗退出。** kernel 對不存在的 instance 回 `INVALID_PARAMS`,`btmgmt` 的 `rm_adv_rsp` → `EXIT_FAILURE`(RB7-5)。deadman / `trap` / `pr_end` 裡的 `rm-adv 5` 一律 `|| true`(今天 BLE deadman 的 `rm-adv 1` 已是 `>/dev/null 2>&1` 不看 rc,prov deadman 新加的要同形),且順序固定 `rm-adv 5` → `restart provd`(反過來 provd 已註冊 1 時 `rm-adv 5` 失敗仍無害,但 log 多一行誤導)。單元:restore 腳本在 instance 5 不存在時 rc 0。

**m3. `BATMAN_DIRTY_WHY` 的字面有前置空白。** stamp 的 `why` 是 `" wbox-test"`(RB7-2);閘門 (3)「`== wbox-test`(整行取值)」在不 trim 時永遠 FAIL(fail-closed 的假 FAIL)。寫死:stamp 輸出 `BATMAN_DIRTY_WHY=${why# }`(去一個前置空白),harness 比對前也 trim;CI 七案例加「前置空白」一案。順便:`BATMAN_FW_COMMIT_FULL` 與 `BATMAN_DIRTY_WHY` 今天都不存在(RB7-2),§4.8 寫成「既有寫者」有誤導 —— 寫者既有(stamp 腳本),**key 是新的**。

**m4. `ble_state` 的 provd 期望值要有時間窗。** provd 跑著時 kernel `num_instances` 合法為 0 的瞬間:900 s RPA 撤 / 重註冊(< 1 s)、前置翻壞又恢復(例如 `prov-sec-bond` 之後 bondable 回 0 到 provd 下一輪 ≤ 5 s)、helper 不新鮮 > 60 s 剛恢復。`ble_state`(preflight P6、tier A)改成「provd running → ≤ 10 s 內讀到 1(每 2 s 重讀),否則 FAIL 並印 provd 最近 3 行 `adv withdrawn reason=`」;provd 停著 → 期望 0 不重試。

**m5. reconcile 與 `psks.get` 1/s 額度的互動沒寫重試。** 兩個改 record 回應在 1 s 內(擁有者連送 `ssh_keys/set`)→ 第二次 `psks.get` 撞 `ERate`;§4.2 只寫「稍後重拉」。寫明:`ERate` → `pendingReconcile` 保持、1 s 後重送(single-flight 合併期間所有觸發),在它回來前 `ctl` 看到的變化都只標待重拉。另:**被 Disconnect 的 session 在 `ops` 佇列裡尚未送出的請求要一併移除**(v7 只寫「在飛回應 → 丟棄」),否則擠槽 / 旁路斷線後它的 `ssh_keys/set` 仍會被送進 helper 執行(helper 會以已存 owners 驗,副作用與 app 送時一致,但 app 永遠不知道結果)。

**m6. `ops` EOF 到重連 reconcile 完成之間,`ctl` 看到 gen 變會被判旁路(`inFlight` 已歸 0、`pendingReconcile` 未設)→ 全斷。** helper 重啟 + `boot.Run` 重寫 record 時這可能就是想要的,但要寫成規則:`ops` EOF → 設 `pendingReconcile`(與回應抵達同形),重連後的全量 reconcile 逐 session 決定;若刻意要「helper 重啟即全斷」,寫明並在 L11 斷言 log reason。

**m7. 執行期 `git show $FW:<path> | cmp - $REPO/scripts/dv/data/<patch>` 的 `$REPO` 是 harness 的 Batman main;正本改版(例如 D3 commit id 進標頭)而 rc image 還是舊 pin 時,一台 kernel 其實已修好的節點會 FAIL。** fail-closed 正確,但要寫進 §4.8 與 known-failures 規則(「正本改版 → 到 pin bump 的 rc 出來前臂 2 預期 FAIL,到期日 = 該 rc」),否則第一次發生時會被歸因成「kernel 沒 patch」。同一段也寫明證據鏈到 kernel 二進位的最後一跳靠 `KERNEL_FILE_DEPENDS`(RB7-3 ✅)而不是 witness。

**m8. 文字殘留:** §3 快取列「撤銷歸因見 §1.3(`expectGen` 由 `ops` 擁有)」與 L82「`expectGen` 遮住 → …(負對照 = 拿掉 `expectGen`)」仍用 v6 的名字;v7 的狀態是 `inFlight` / `pendingReconcile`,兩處改掉,L82 的負對照改成「拿掉 `inFlight` 遮罩 → ≤ 8 s 被斷」。§4.8 (3) 的「其他變體 … 不放行」在 M1 的 hold 型定義下仍對,保留。

**m9. 時間預算一處要補:** M3 修完後,`ops` 在長動詞期間對所有 session 的最壞回應 = `QUEUE_WAIT` 30 s(not sent);而 `claim/finish` 排在 `provclient` 的長動詞後面時 app 看到的是 7,不是 L24 的「一個 0 一個 7」;L24 寫明前提「兩者都在 30 s 內進 helper」。

## 4. 我核過、成立的(§18 說修了、我確認真的修了)

| v6 發現 | v7 | 結果 |
|---|---|---|
| A6-M1 / B6-M1 閘門 (3) 只有 `test` 過、sha 檔無寫者 | 固定 `test`;正本進 Batman `scripts/dv/data/`;firmware 副本 + build 第 4 步 `cmp`;執行期 `git show \| cmp`;`BATMAN_FW_COMMIT_FULL` | ✅ 證據鏈本身成立(正本 → 副本 `cmp` 在 build 就拒漂移,RB7-3;7 碼歧義以 `_FULL` 解);**但跑的位置(committed 槽)不合法 → M1;前置空白 → m3** |
| A6-M2 / B6-M3 / m1–m3 `expectGen` 布林、背靠背、餓死 | `inFlight` + `pendingReconcile`,reconcile 綁每個回應、插隊、候選以 PSK 值比對、Finish-first 以回應收尾 | ✅ 餓死與背靠背都解了;**基準更新缺 → M2;`HELPER_WAIT` 後的槽 → M3** |
| A6-M3 / B6-m6 臂 2 payload 未釘 | `1e ff` + 29 B、無 0x01、只 `-d`、btmon length == 31 無 Flags、INVALID_PARAMS 不算通過 | ✅ ADV 臂有鑑別力(未 patch 時 `cp.length` = 34,RB7-4);**scan rsp 臂無鑑別力 → m1** |
| B6-M2 harness 不知道 provd | §3 第三寫者 harness;`ble_state` 依 provd 狀態;`ble-rpa` 不准 `rm-adv`;兩個 deadman `start provd` + `rm-adv 5`;L83 | ✅ 「停了 provd」的一半;**`provd.env` 環境殘留 → M4;`rm-adv 5` rc → m2;`ble_state` 時間窗 → m4;F-P61 不準 → M4.4** |
| B6-M4 `HELPER_WAIT` 排隊語意 | `QUEUE_WAIT` 30 s 未送即 `E_BUSY{not sent}`;`HELPER_WAIT` 從送出起算 | ✅ 排隊的那一則解了;**到期後送出的下一則 → M3** |
| B6-m5 兩個計時器、`IsTrial` exec | STATUS 以 `info.state`、撤廣播以 `health.get`;`ctl` 先送 `health.get`;trial 快取 stale-while-revalidate、exec ≤ 5 s | ✅ |
| A6-m1 `ActiveInstances` 看不到 root instance | 改用 kernel `num_instances`(F-P60) | ✅ |
| A6-m2 成員 update 後 reconcile 斷自己 | app 契約 | ✅ |
| A6-m3 / F-P62 overlay 寫入失敗分支 | 誠實界線 + 殘項 | ✅ |
| Noise / 假 msg2 | §4.2 與 v6 字面相同:msg1 長度表、6 個 state 各 `ReadMessage`、不 break、`e'(32) ‖ random(48 + len + 16)`、兩次 DH、`Config.Random` 餵向量、32 B msg1 在 psk 模式仍 6 次 | ✅ 未動 |
| GATT 快取 | CTRL 常數、STATUS 來自 `ctl` 快取、未填 / > 60 s → 0x0E | ✅ |
| dbus policy | 8 條方法、無 own / DBus destination / receive_sender;root 回呼 4 行 gate | ✅ 未動 |
| 時間預算 | 撤廣播 4 + 2 + 1 (+2) ≤ 9 s(L67 9.5);`ctl` 單則 10 s;`ERate` 120 s;L80 ≤ 15 s;`QUEUE_WAIT` 30 / `HELPER_WAIT` 330 > 180 | ✅ 算術對;**M3 之後 `ops` 的語意要跟著補 m9** |

## 5. 負對照盤點

| 防線 | 有 | 缺 |
|---|---|---|
| 閘門 (1)(2)(3)(4)、build `cmp`、CI 七案例 | ✅ | 跑的位置(非 trial → FAIL 不 OTA,M1);前置空白(m3);正本改版 → 預期 FAIL 條目(m7) |
| 自家動詞在飛不撤、背靠背、Finish-first | `cache_test` 五臂 + mutant | **快動詞回應後 `ctl` 首輪不斷(M2)**;reconcile 後再改一次才斷 |
| `HELPER_WAIT` / `QUEUE_WAIT` | 假時鐘兩臂 | 到期後 fake helper 只收 1 則(M3) |
| harness 停 / 改 provd 後主機死 | L83 白箱(停) | `SOCK_ONLY` 殘留 → deadman restart(M4);`rm-adv 5` rc 0(m2) |
| `ble_state` 與 provd 並存 | 兩態 | 時間窗(m4) |
| 臂 2 ADV 語意 | btmon length 31 無 Flags | scan rsp 臂(m1:無正向,寫明) |
| 假 msg2 等長 / churn / L75 / L80 / L81 | 單元 + mutant | ✅ |

## 6. 誠實界線

有寫且對:RPA 900 s;BLE 單連線;ADV 自檢只擋自己;`adv_registered_once` 量 kernel;autocommit 只 WARN;被攻陷 provd 的能力;`psk_member` 在 update 中的空窗;無 provd 保留位;殭屍連線;F-P41 ⚠️;kernel patch 不在 #275 見證內;F-P10 是 n=1 的 stack overrun;新連線在 reconcile 完成前以舊集合放行;p5 commit / overlay 失敗分支看不到。
要改:§4.8「固定跑在 `-wbox test` 變體」→ 「在 `-wbox test` 的 **hold trial 內**」,且 kernel 是 wbox build 的(M1.5);§4.8「全部用既有寫者」→ 寫者既有、key 新(m3);scan rsp 臂「同判定」→ 無正向見證(m1);L83「停了 provd」→ 「停了或改了環境」(M4);F-P61 的「沒有任何一處 start / stop」(RB7-7)。

## 7. 判定

**APPROVE-WITH-CHANGES** — 0 BLOCKER / 4 MAJOR / 9 MINOR。

v6 的五個 MAJOR 各自的機制都真的改了,而且方向對:證據鏈(正本在 Batman、build `cmp`、執行期 `git show | cmp`)自洽;reconcile 綁回應解掉了餓死;payload 釘死且 btmon 判定在未 patch 時會看到 34;harness 知道 provd 存在;`QUEUE_WAIT` 擋住排隊的那一則。但四條都差最後一步:臂 2 要跑的那個 image 在 harness 的槽政策下只能以 hold trial 存在,設計寫成跑在 committed 槽(M1);撤銷狀態機沒說 reconcile 之後 `ctl` 的基準怎麼更新,照字面每次快動詞之後擁有者會被踢(M2);`HELPER_WAIT` 到期後若釋放 `ops` 的槽,B6 M4 的「app 放棄後才執行」原樣回來(M3);deadman 的 `start provd` 對 `SOCK_ONLY` 殘留的 provd 是 no-op,節點會靜默失去 BLE 管理面到下次重開(M4)。Noise / 假 msg2、GATT 快取、dbus policy、時間算術、v6 的 MINOR 對原始碼核過成立。依通用規則 MAJOR 開著就要改 v8 並整份再審;04 實機證據(F-P41、L10 / L11、hold 進 B 的 `-wbox test` 流程)仍欠,與前幾輪相同。
