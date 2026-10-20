# #254 PR-H1 harness 設計 v1 — 獨立審查 A

審查對象:`254-h1-harness.md` v1(整份)。基準:Batman main dfdd11e(WSL `/home/yello/Batman-h1`)、firmware-2710 build 樹(BlueZ 5.72、linux 6.6.138)、02 / 04 唯讀實讀(2026-10-19/20)。
我沒有改任何節點狀態;沒跑 bluetoothctl / btmgmt;沒印出任何 IRK。

## 我自己查證過的事(證據)

| # | 查證 | 結果 |
|---|---|---|
| V1 | kernel `net/bluetooth/mgmt.c` `set_privacy` | `if (hdev_is_powered(hdev)) return ... MGMT_STATUS_REJECTED`(約 7024 行)→ powered 時 `btmgmt privacy off` 一定被拒 |
| V2 | bluetoothd 收尾 / 重啟 | `adapter.c` 約 10932:shutdown 時 `SET_POWERED 0x00`;啟動 `set_privacy`(約 10365)在未上電時送 → restart 會把 privacy 還原 ✅;patch 900 每次啟動送 `SET_SECURE_CONN` ✅ |
| V3 | A3 `advertising.c` | 約 1893–1895 `/* Reset existing instances */ if (feat->num_instances) remove_advertising(manager, 0);` ✅;`hci_core.c:2754` `hci_adv_instances_clear` ✅ |
| V4 | E7a `adapter.c:9081` | `adapter_set_io_capability` 在 `!btd_opts.pairable` 下只動 bondable ✅ |
| V5 | kernel `.config` | `CONFIG_CRYPTO_USER_API=m`、`_HASH=m`、`_SKCIPHER=m`;`# CONFIG_BT_DEBUGFS is not set`(所以沒有 `sc_only_mode` debugfs,PR-F「讀不到 SC-only」成立) |
| V6 | 節點模組 | 02 / 04 `ls /lib/modules/6.6.138 \| grep -i alg` 空、`/proc/net/protocols` ALG 0 |
| V7 | btmgmt / btmon 相依 | `btmgmt` NEEDED `libreadline.so.8`;`btmon` NEEDED `libglib-2.0.so.0`、`libgthread-2.0.so.0`;兩節點都有這些 lib ✅(設計沒寫這個相依) |
| V8 | `/tmp` 掛載 | 兩台 `tmpfs on /tmp (rw,nosuid,nodev,noatime)`,無 noexec ✅(A5);`/tmp/run` root 0755、`/tmp/run/batman-dv` root 0700、`/tmp/lib` root 0755、`/tmp/lib/bluetooth` root 0700 |
| V9 | `batman-sc` | 兩台 root 0600,boot_id / pid 與現況一致、mode=2 status=0 |
| V10 | logread ring | 02:uptime 16038 s,`logread \| wc -l` = 1081,**第一行 01:55:54,開機約 01:49 → 開機 6 分鐘內的行已被輪掉**;04:uptime 7683 s,1123 行,第一行仍是開機那分鐘。ring 約 1100 行就滿 |
| V11 | 節點時鐘 | 02 `Sun Oct 18 06:16:48 UTC 2026`、04 `Wed Jul 16 06:00:25 UTC 2025`(E12 屬實,兩台相差 > 1 年) |
| V12 | bluetoothd init | `procd_set_param respawn 3600 5 0`;沒有 bluetooth hotplug 腳本(reset 期間不會被別人拉起)✅ |
| V13 | PR-F 證據來源 | `rpa04.sh` 的 RPA 30 分鐘測試用的是 **bluetoothctl `advertise on`**(bluetoothd adv manager),不是 `btmgmt add-adv`;`49:F1:…` 是那次的 R2。btmgmt 只用在配對夾心(`5B:4F:…` r1/r2 同一個、restart 後 `4D:86:…`) |
| V14 | #290 規則 1 | 把 `scripts/node/` 列為「product paths」之一 |
| V15 | 上層 §9 | 列有 `PR-F:coex`(L28 → `prov-coex-254`);`ble-privacy-254`「只在 fresh overlay 上判定」;負對照 wsl.4 / wsl.5 |
| V16 | `verify.py` | 模組層直接 `json.load` + 跑全部檢查 + 結尾 `sys.exit` → 不能被 `peer.py` import 重用;`node_accepts` / `idem_ok` / `cddl_ok` / `deterministic` 是頂層函式 |
| V17 | daily-validation `suite()` | `{ echo "# $cmd"; eval "$cmd"; } > "$log" 2>&1`;tier B 只看 `DNODE` 的 eth0 carrier;`fleet_init` 只收 BENCH/MESH/OTS/DNODE/T263 |

---

## MAJOR

### M1 `ble-rpa-254` 用兩台節點各自的 epoch 切段 → 必定判錯
- **情境**:§4.5 寫「所有時間戳用 epoch 秒」。04 的時間軸(T0、T0+300、T0+2100…)是 04 的時鐘,02 的 `<epoch> <addr>` 是 02 的時鐘。V11:兩台差一年以上(E12 自己也寫了)。照 epoch 把 02 的看見紀錄分到 (a)(b)(c) 段,所有點都落在段外 →「任一段沒看到位址 = FAIL」。不會假 PASS,但會 100% 假 FAIL,浪費一次 40 分鐘的釋出全套。同樣問題也出現在「每 60 s info」與 btmon 對時。
- **修法**:段落邊界只用一個時鐘。可以由測試主機下指令,用主機時間記錄每個事件;或每台節點在開始與結束時各取一次 `date +%s` 對主機的偏移(±1 s),換算成主機時間。每個轉換點前後留保護帶(例如 ±20 s),落在保護帶的看見紀錄不計入任何一段。把這寫進契約,判定也要有 stub 測試。

### M2 RPA 判定沒有覆蓋率要求 → 假 PASS;40 分鐘的 ssh 掃描 session 斷了也看不出來
- **情境**:(a) 段的判定是「恰好 1 個位址」。如果 02 只在 (a) 的第 1 分鐘看到 R1,之後 scan 死掉(02 經 04 / mesh 連到主機,40 分鐘內 ssh 斷一次很正常;或 bluetoothctl 結束),集合仍然是 {R1} → PASS,但 30 分鐘其實沒有被觀察。(b) 段同理。設計沒寫掃描是前景 ssh 還是節點上 detached 執行,也沒寫最少看見次數。
- **修法**:每段切成 N 分鐘的桶(例如 2 分鐘),每個桶都至少要看到 1 次,每段頭尾的桶也必須有;缺任何一個桶 = FAIL「沒觀察到」。02 的掃描與 04 的時間軸都用 `setsid` 在節點上跑,寫入 `bt/` 的結果檔,主機輪詢。結束時要確認行程活著到最後(例如寫心跳行)。負對照:中途 kill 02 的 scan → 必須 FAIL。另外 bluetoothd 的 discovery 循環與 kernel 的 duplicate filter 會影響看見頻率,PR-F 的 scan log 密度要拿出來當證據。

### M3 中途死掉的路徑不完整:deadman 只保翻轉段;留下的狀態下一次跑也偵測不到
- **情境 A**:`ble-rpa-254` 跑 40 分鐘時主機斷電、ssh 斷,或操作員按了 Ctrl-C。04 的 instance 1(connectable、帶唯一的測試名稱)會一直留著,直到 bluetoothd 重啟或節點重開。A2 說 RPA 只在重新啟用時輪替 → 04 以固定 RPA 加獨特名稱長期廣播 = 可被追蹤,而且沒有任何 deadman。
- **情境 B**:翻轉段已外洩 IRK,deadman 也已經把 SC 改回 only,但在收尾重開 04 之前死掉。IRK 會一直有效到下次重開(04 是長期開著的 OTS 節點,可能幾週)。設計寫「寫進 log 與報告」,但寫報告的就是已經死掉的 harness。
- **情境 C**:deadman 沒有成功(`setsid` 之前 ssh 就斷了,或 restart 失敗),04 停在 `sc on`。tier A 斷言 2 看 `secure-conn`,但這個位元在 on 與 only 時一樣(PR-F body 自己也寫了「root 事後 `mgmt.sc on` 健康檢查看不出」);`batman-sc` 是舊 pid 的紀錄,但 pid 沒變 → 隔天 tier A 與 preflight 都 PASS = **假 PASS,節點留在會外洩的狀態**。
- **修法**:(1) 每次 `adv-on` 都設 deadman(到期執行 `rm-adv` 或 bluetoothd restart),不只翻轉段。(2) `flip` 在 `sc on` 之前寫 tmpfs 標記 `bt/flipped`(含 boot_id),只有在看到 `batman-sc` 換成新 pid(restart 成功)後才刪。另外寫 `bt/irk-exposed`(含 boot_id),只在重開後自然消失。(3) preflight 與 tier A `ble-privacy-254` 在 BLE 節點上檢查:有 `irk-exposed` 且 boot_id 是本次 → FAIL「上次中斷,IRK 已外洩,需要重開」;有 `flipped` → FAIL;`btmgmt advinfo` 有 instance → FAIL;`pidof bluetoothctl btmon` 有東西,或有殘留的 deadman → FAIL。(4) 白箱負對照:每一種情境各在中途 kill 一次,下一次 preflight 必須 FAIL。(5) 可以考慮讓 deadman / 收尾改成「刪 identity 再 restart bluetoothd」:patch 900 在沒有 identity 時會重新產生 IRK,這樣不用重開 04(OTS 中斷)也能作廢 IRK。這要在 build 樹讀碼加實測當證據。

### M4 `privacy off` 負對照照寫是做不出來的;斷言 2 的解析有假 PASS 的風險,剛好又沒有負對照擋
- **情境**:§4.3 與 §4.5 的負對照都是「04 runtime `btmgmt privacy off`」。V1:powered 時 kernel 回 `REJECTED`,privacy 不會變,所以負對照實際上沒有注入故障。同時,`btmgmt info` 的輸出有一行 `supported settings:`,裡面有 `privacy secure-conn le bondable br/edr …` 全部。如果判定對整段輸出 grep「含 privacy」就永遠 PASS,grep「不含 bondable」就永遠 FAIL。而且 `le` 是 `bondable`、`connectable`、`discoverable` 的子字串。這正是 E7b(`END` 撞到 `SEND`)那一類問題。唯一能抓到解析錯誤的是負對照,但它又做不出來。
- **修法**:負對照改成 `power off` → `privacy off` → `power on`(power off 也會清 adv instance,§4.5 的負對照要在之後重新 `adv-on`);還原 = bluetoothd restart(V2:restart 會先 power off,再設 privacy,有證據)。判定只取 `current settings:` 那一行,拆成 token 逐字比對,不用子字串。`test-dv-preflight.sh` 或另一支 stub 測試要放 `supported` 與 `current` 兩行都有的真實 btmgmt 輸出樣本,各做一個正例與反例。

### M5 tier A 的相依沒有 preflight,也沒有定義缺少時怎麼辦
- **情境**:`ble-privacy-254` 是 tier A(每天跑),需要 `DV_BT_TOOLS`(btmgmt)。但 P6 只在 `FEATURE_MODE=--destructive` 時檢查 `DV_BT_TOOLS` / `DV_PY`。每日排程沒設 `DV_BT_TOOLS` 時,是 FAIL、SKIP,還是 rc 3?設計沒說,結果就是長跑之後才知道,正好是 preflight 要消滅的那一類錯誤。另外 `DV_BT_TOOLS` 的來源是 firmware build 樹的 `build_dir`,換分支、`make clean` 或重 build 就會變動或消失,每日排程拿不到穩定的 binary。V7:btmon 還需要 glib / gthread,btmgmt 需要 readline,ELF 標頭檢查看不出缺 lib。
- **修法**:只要 fleet 裡有 bcm2711 節點,P6 的工具檢查就在 daily 模式也做。stage-check 要在節點上實際執行 `btmgmt --version` / `btmon --version`(驗 lib)。把工具複製到一個 harness 自己的固定位置(例如 `~/batman-dv-tools/<bluez-ver>/`,記錄 sha256 並印進報告),不要直接指向 build_dir。明文規定:沒設 = FAIL,不是 SKIP。

### M6 上層範圍被默默丟掉
- **情境**:上層 §9 的測項列表有「PR-F:coex」(§5 L28 → `prov-coex-254`:BLE 與 WiFi AP 共用 CYW43455,量吞吐)。H1 的「做」與「不做」(§1.2)、殘項(§9)都沒有它。上層 `ble-privacy-254` 有「只在 fresh overlay 上判定」(A-m2 / B-M4),H1 拿掉了但沒說理由(H1 改查 `/etc/bluetooth/keys` 不存在,也許夠,但要寫出取代關係)。上層的負對照是 wsl.4(無 privacy)/ wsl.5(有 privacy 無 SC-only),H1 改成白箱翻轉,§4.3 有寫一句,但沒有對照上層。
- **修法**:coex 要嘛放進 H1(PR-F 已有 BLE:04 `adv-on` + 02 掃描 / 連線,同時從 AP 端跑 iperf),要嘛明寫延到哪個 PR,並寫進 #254 checklist。§10 的修改要一併處理 coex 與 fresh overlay 這兩點。

### M7 `peer.py` 的傳輸契約把三層混在一起;參考回應者等於第二份未審查的節點實作
- **情境**:§4.8 寫「每則訊息 = u32 BE 長度 + 位元組(= 一個 GATT write / notify 的 payload,分塊規則照協定 §5.1)。長度 > `max_msg` → 必須斷線」。協定有三層:§4.1 GATT frame(`max_frame`、序號、結尾、重組上限 `max_msg`)、Noise 訊息(≤ `max_msg`)、§5.1 應用層信封分塊(`6: {n,total}`、≤ `max_msg − 16`)。一個 GATT write 的 payload 是 §4.1 的 frame,不是 §5.1 的 chunk;單一 frame 的上限是 `max_frame`,不是 `max_msg`。PR-P2 的 Go 實作與 H3 都要照這份契約,寫得不清楚就會各做各的,之後要重做。另外,selftest (2) 的「用 verify.py 的判定組成的參考回應者」需要狀態(重放 `op/nonce`、psk 錯 6 次之後、冪等、分塊重組),verify.py 沒有這些。這實際上是用 Python 重寫一次節點狀態機,而它就是 adversary 預期錯誤碼的判準,卻沒有擁有者、沒有審查。V16 也顯示 verify.py 現在不能被 import。
- **修法**:明定 `peer.py` 操作在哪一層,建議 §4.1 frame 層,另加 Noise 與 §5.1 兩層各自的語料。上限照層寫(`max_frame` / `max_msg` / 1 MB)。每個 adversary 案例的預期錯誤碼要引用 219 協定的條文(單一來源),不要由參考回應者決定。verify.py 改成可 import(`if __name__ == "__main__":`),並寫明這次修改由 `MIN_CHECKS` 與 CI 負對照證明沒有改變判定。

### M8 P7(logread 灌爆)是一個還沒決定的檢查,照現在寫的永遠 PASS;§4.4 讀開機 log 也有時間風險
- **情境**:V10:ring 大約 1100 行就滿了,02 開機 6 分鐘內的行已經被輪掉。所以「隔 10 s 兩次 `wc -l` 差 > 200」在 ring 滿的時候差值永遠是 0,也就是永遠 PASS,正好在最需要的時候失靈。設計自己標了 ⚠️,寫「以實測定」,但這等於把一個沒審過的判定送進 #290 規則 4 的強制項。設計提的替代方案「最後一行時間戳之差」也沒有鑑別力:兩次讀到的都是「現在」。§4.4 重開 04 之後讀 `Generated IRK (getrandom)`:04 是 OTS 節點,開機後容器的 log 量很大,如果先等 `ots_ready` 才讀,這行可能已經被輪掉 → 假 FAIL。
- **修法**:P7 改為用 `logread -l 200` 取第 200 新那一行的時間戳 t,速率 = 200 / (now − t),兩個值都來自同一台節點的時鐘,所以時鐘不準沒關係;門檻用 02 / 04 平時的實測值決定。負對照:在節點上 `logger` 灌一段(要先列副作用,會把 ring 洗掉)→ 必須 FAIL。§4.4 在 ssh 一恢復就先 `logread -e 'Generated IRK \(getrandom\)'`,再等 OTS,並寫明這行讀不到 = FAIL(不重試、不降級)。

---

## MINOR

- **m1 A1 / A2 證據引錯**:A1 引用的 `49:F1…` 是 bluetoothctl 那次 RPA 測試的 R2(V13),不是 btmgmt。btmgmt add-adv 用 RPA 的證據是配對夾心的 `5B:4F…` / `4D:86…`(最高兩位都是 01)。A2 的 (b)「timeout 前重新註冊 → 同一個 RPA」有 btmgmt 的部分證據(夾心 r1 / r2 都是 `5B:4F`,相隔約 273 s);(a) 30 分鐘不變、(c) 900 s 後換新,都只在 bluetoothctl 路徑驗過。另外夾心 restart 後換了新 RPA(bluetoothd restart 會先 power off),這是 (b) 的反例條件,要寫進前提:§4.5 期間不得有 power cycle 或 bluetoothd restart。
- **m2 ssh 並行與節點端互斥**:§4.5 / §4.6 同時有 02 掃描、04 時間軸、btmon、每 60 s info、IRK 讀取,會同時開幾條 ssh 到 04 沒有寫(#290 記過 dropbear 並行重置事件)。也沒有節點端的鎖(`flock bt/lock`)擋第二個 run 或操作員的手動 session;E7a 就是被人手動開的 bluetoothctl 污染的。要寫出每台節點的最大並行數(建議 ≤ 2,其餘在節點上 detached),並加節點鎖。
- **m3 夾心的「擋下」配對規則沒寫**:「04 btmon 有對到該連線的 LE Connection Complete」:02 也開了 privacy,peer 位址是 02 的 RPA,要用什麼對上這次連線(每輪 btmon 起訖範圍內恰好一次 complete + 該輪 02 的 `Connected: yes`?)要寫清楚。A7(`btmon -r`)⚠️ 要在設計審查時就驗,不要留到實作。
- **m4 02 `reset` 刪除範圍**:「裝置目錄」要寫成明確的 glob(只限 MAC 形式的子目錄與 `cache/*`)。絕不能動 02 自己的 `identity` / `settings`。「先印出」只印路徑,不印內容(`info` 檔可能含金鑰)。刪除前比照 PR-F init 重驗 `/tmp/lib`、`/tmp/lib/bluetooth` 的 owner / mode / 非 symlink。新節點腳本會出現 `/var/lib/bluetooth`、`/tmp/lib/bluetooth` 等字樣,`check-tmp-trust` 會擋,需要新增 allowlist 條目,要列進 §7 的攻擊面變化。
- **m5「暫存目錄刪除」**只能刪 `bt/`;`/tmp/run/batman-dv` 由 halow-fi-263、setkey-202 等其他測項共用(`daily-validation.sh:659-660,1909`)。
- **m6 deadman 實作**:用 `setsid` 建自己的 process group,取消時 `kill -- -pgid`,再確認已經不在;pid 檔要附 boot_id 與 cmdline 比對,避免 pid 被重用。取消失敗要 FAIL,否則它可能在之後的測項中途 restart bluetoothd,造成假 FAIL。
- **m7 路徑分類**:#290 規則 1 把 `scripts/node/` 列為 product path(V14),§0「不碰產品路徑」與此衝突。要寫明 `scripts/node/*-254.sh` 是 harness 工具,並同步 #290 的路徑表,以免之後的 governance CI 誤擋。
- **m8 `ble-ah.py --selftest`** 只驗 spec 向量,沒有涵蓋 identity 檔的 byte order(E6:這裡最容易錯,錯了就是 40 分鐘的假 FAIL)。加一組合成向量:隨機 IRK 依 identity 檔格式寫入,再算出對應的 RPA,經完整解析路徑驗證。不要用真 IRK,就算已作廢的也不要。
- **m9 IRK 外洩掃描是人工的**(§7「PR 前人工 grep」)。改成機制:收尾時把抓回的 log 經 stdin 送回 04,在 04 上 `grep -F` 比對 identity 的兩種 byte order,命中 = FAIL。IRK 不離開節點。
- **m10 AF_ALG 斷言**:V5 顯示是 `=m` 模組。`/proc/net/protocols` 沒有 ALG 只代表模組還沒載入,`socket(AF_ALG)` 會自動載入。斷言 4 / 5 要加「`/lib/modules/$(uname -r)` 下沒有 `af_alg*` / `algif_*`」(V6:現在確實沒有)。
- **m11 順序與 fleet**:BLE tier B 測項與 fault-injection / ab-selftest(會換槽)的先後要寫明,每個測項開頭重驗 P6 的條件。`BLE_PERIPH` / `BLE_CENTRAL` 要加進 `fleet_init`(V17)。`BLE_PERIPH ≠ DNODE` 時沒有 eth0 閘門,要寫明為什麼可以接受(clean reboot,同 #274 的理由)。
- **m12 CI**:向量負對照只看 rc 1 沒有鑑別力(JSON 壞掉造成的 traceback 也是 rc 1),要斷言輸出含 `k FAILED` 且失敗的是 `psk_replay` 那幾項。`--require-hashes` 必須連遞移相依一起釘(cffi、pycparser 等),否則 CI 第一次就失敗。
- **m13 `prov-tools-254`** 的 `flock -n` rc 0 只等於存在檢查。要測競爭:已持有鎖時,第二個 `flock -n` 必須 rc 1。
- **m14 判定只能有一份**:P5 重寫了 fault-injection 自己的 payload precheck,P6 與 tier A 斷言 1 各寫一次 `batman-sc` 判定 → 改成共用函式 / 呼叫同一支節點端 precheck(#290 一套測項的精神)。
- **m15 F16 偏離**:§4.5 的 02 用 bluetoothctl 長時間掃描(agent 會讓 02 變 bondable)。02 不是受測對象、也沒有廣播,所以可接受,但要寫出理由。

---

## 生命週期矩陣缺漏(彙整)
- 40 分鐘 RPA 中途中斷(M3-A)、翻轉後在重開前中斷(M3-B)、deadman 失效(M3-C):缺。
- 第二個 run 或操作員同時操作 BLE 節點:缺(m2)。
- bluetoothd 在測試中 crash / respawn(V12 respawn):fail-closed,但矩陣沒列。
- ssh / 網路中斷(02 經 mesh):只寫了 harness 死掉,沒寫 run 繼續但觀察中斷的情況(M2)。
- hci0 初始化失敗(PR-F ❓ 02 暖開 1/4):`ble-privacy-reboot-254` 碰到時判 FAIL,要寫明不重試、不歸因。

## 安全(彙整)
- 路人:M3-A(長期固定 RPA 加獨特名稱)、M3-B(外洩的 IRK 長期有效)是主要缺口。
- 本機非 root:暫存目錄與工具的檢查足夠(V8);reset 走 `/var` → `/tmp` 的刪除要重驗(m4)。
- 秘密:IRK 只走 pipe 是對的;btmon snoop 不抓回是對的;人工掃描要改成機制(m9);`reset` 印出的內容(m4)。
- 供應鏈:`DV_BT_TOOLS` 改成固定位置加 sha256(M5)。

## 裁決
**REJECT(改 v2 後整份再審)**:架構方向沒問題(只動 harness、fail-closed、IRK 走 pipe、三態判定、翻轉段的鑑別力要求都對),但有 8 個 MAJOR。其中 M1 讓 RPA 測項照寫一定判錯;M3 是安全面的中斷路徑;M4 讓兩個負對照做不出來;M7 是 PR-P2 要照著做的跨元件契約。這些修完要整份再審。BLOCKER:0。

未驗(標 ⚠️):A7 `btmon -r`;02 掃描在 40 分鐘內的實際看見密度(PR-F 的 scan log 已不在節點上);dropbear 並行上限的實際數字。
