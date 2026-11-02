# Design: #254 PR-H1 — harness:開跑前檢查、CI 協定向量、BLE 空中測項、02 central client — **v8(定稿)**

**狀態**:**v8 定稿**。v7 第 7 輪:A **APPROVE** 0 / 0 / 3;B **APPROVE-WITH-CHANGES** 0 / 0 / 3(`h1-review-v7-{A,B}.md`);兩位都表示 MINOR 不需再審。v8 只收這 6 個 MINOR(§17)。以下 v7 說明保留:v6 第 6 輪:A **APPROVE** 0 / 0 / 3;B REJECT(窄)1 / 0 / 3(`h1-review-v6-{A,B}.md`)。B 的 BLOCKER:`batman-slot rollback` 把預設改成「目前槽以外的槽」,v6 沒先確認節點在 slot B 就呼叫 → 在 A 上(含每次正常結束的 EXIT trap)會讓 02 committed 開進 wsl.2 → rollback 改為節點端單一條件指令、`PHASE` 分四段、三個 stub 負對照。A 的 u1:翻轉段是 legacy Just Works,被動監聽可推出 02 的 IRK → 使用者 2026-10-20 決定(H-U7)收尾重開 02。§16 列去向。以下 v6 說明保留:v5 第 5 輪:A APPROVE-WITH-CHANGES 0 / 1 / 4;B REJECT(窄)0 / 1 / 5(`h1-review-v5-{A,B}.md`)。兩個 MAJOR 都是 v5 自己引入的:B — N3 的 EXIT trap 在 OTA 已啟動後刪 hold 旗標 → 02 會 commit 在 wsl.2(改為依階段處理);A — deadman 的 pgid 檢查在 `mv dm.new dm` 前中斷時兩個 deadman 都不動作(改為 `dm` 或 `dm.new` 皆可)。§15 列去向。以下 v5 說明保留:v4 第 4 輪:A **APPROVE** 0 / 0 / 5;B REJECT(窄)0 / 1 / 6(`h1-review-v4-{A,B}.md`)。B 的 MAJOR:N3 的 V2 寫「從 payload 讀出」,但 payload `metadata` 的 `version=` 是建置時間戳(`build-ab-payload.sh:69`),autocommit 比的是 `BATMAN_VERSION` → 照字面實作會重現 v3 的 B1 → V2 只取自 slot B 的 `/etc/batman-build` 並交叉比對 `slot-B.protected`;已 commit 的分支。§14 列 v4 發現的去向。以下 v4 說明保留:v3 第 3 輪:A APPROVE-WITH-CHANGES 0 / 2 / 6;B REJECT(窄)1 / 1 / 8(`h1-review-v3-{A,B}.md`)。兩位共同:**N3 照 v3 做會讓 02 被 commit 在 wsl.2**(hold 旗標寫的是執行中版本,wsl.2 的 autocommit 只認相符版本 → 丟掉旗標照常 commit)→ §4.10 N3 重寫;**deadman 做不到有 kernel 驗證的 rekey** → 使用者 2026-10-20 決定(H-U6):deadman 遇到 `irk-exposed` 就重開 04。§13 列 v3 發現的去向。以下 v3 說明保留:v2 第 2 輪:A APPROVE-WITH-CHANGES 0 / 3 / 8;B REJECT(窄)0 / 4 / 9(`h1-review-v2-{A,B}.md`)。兩位共同:btmon 過濾把判定要用的縮排子行丟掉(§4.7 改為節點上的結構化判讀);B:`rekey` 沒驗 kernel 真的換了 IRK、鎖只鎖單一指令;A:preflight 不該擋產品狀態;兩位:N3 換槽沒有救回路徑(改為 held trial,§4.10)。§12 列 v2 發現的去向。以下 v2 說明保留:v1 第 1 輪:A REJECT 0 BLOCKER / 8 MAJOR / 15 MINOR;B REJECT(窄)0 / 5 / 12(`254-reviews/h1-review-v1-{A,B}.md`)。v2 重寫 §4 的判定契約(單一時間軸、取樣覆蓋率、以拒絕原因判「擋下」)、BLE runtime 狀態的擁有權與還原(每個狀態變更都有 deadman、節點鎖、殘留標記、preflight 乾淨檢查)、P7 算法、tier B 閘門與順序;依使用者 2026-10-20 決定移出 `peer.py`(→ H3)、coex(→ P2)、負對照 = 白箱 + 02 換到舊版槽一次。§11 列每個發現的去向。

**本文件自足**,不需讀 v1。
上層:`254-stage1-impl.md` v19 §9 / §10 第 3 點;#290(一套測項)規則 1、2、4。
基準:Batman `main` dfdd11e;firmware `build-3aplus` 0439b5bb(= 1.5.12-wsl.9);02(10.41.1.1,BENCH,slot A wsl.9 / slot B 1.5.12-wsl.2)、04(10.41.1.3,MESH / OTS / DNODE,乙太網在這台,兩槽都 wsl.9),都 committed。

## 0. 一句話
把 PR-F 手動做過的 BLE 空中驗證(privacy、SC-only 配對夾心、RPA 輪替)變成 daily-validation 的常駐測項,並加上長跑之前就擋下設定錯誤的 preflight、CI 自動跑協定向量。只改 harness:`scripts/`(含 `scripts/node/` 的 harness 節點端腳本,見 §1.4)、`tests/`、`.github/`、`docs/`;不改任何進 image 或 `deploy/` 的檔案(#290 規則 1)。

## 1. 決策、範圍、事實

### 1.1 使用者決策
| # | 決策 | 日期 |
|---|---|---|
| H-U1 | PR-H1 併入:① preflight 成為 harness 正式入口 ② CI 跑向量驗證 ③ ble-privacy / ble-pair-sc-only / RPA 空中測試成為常駐測項 | 2026-10-20 |
| H-U2 | **prov-\* 分批進**:H1 只放現在就判得了的 `prov-tools-254`;P1 / P2 / P3 各自的 prov-\* 測項在各產品 PR 之前用小 harness PR(H2 / H3 / H4)先進 main,各附舊版 FAIL + rc PASS | 2026-10-20 |
| H-U3 | **`peer.py`(協定對手)延到 H3**:本 PR 沒有使用者;H3 時傳輸契約照 219 §4.1 frame 層訂,直接對打 Go 實作 | 2026-10-20 |
| H-U4 | **`prov-coex-254` 延到 P2**(那時才有真的 BLE 流量:provd 廣播 + GATT) | 2026-10-20 |
| H-U5 | **負對照 = 白箱故障注入 + 02 換到舊版槽(slot B,1.5.12-wsl.2,無 BLE build)跑一次 tier A BLE 測項**(#290 規則 2 的「舊版 FAIL」) | 2026-10-20 |
| H-U7 | **tier B BLE 區塊收尾時以 `batman-slot reboot committed` 重開 02**(翻轉段 legacy Just Works 可被被動監聽推出 02 的 IRK;重開一定換;02 是 bench、無 OTS,離網約 2 分鐘;只在釋出前全套跑) | 2026-10-20 |
| H-U6 | **harness 中途死掉而 04 的 IRK 已外洩時,deadman 重開 04**(重開一定換 IRK,不需驗證;代價:無人看守時 OTS 中斷約 2 分鐘,只在這種中斷發生;04 有乙太網) | 2026-10-20 |

### 1.2 範圍
**做**:
1. `scripts/dv-preflight.sh` + daily-validation 最先呼叫(§4.1)。
2. CI `vectors-219` job(§4.2)。
3. BLE 測項:`ble-privacy-254`(tier A)、`ble-rpa-254`、`ble-pair-sc-only-254`、`ble-privacy-reboot-254`(tier B)(§4.3–§4.6)。
4. 節點端腳本 `scripts/node/ble-periph-254.sh`(BLE_PERIPH = 04)、`scripts/node/ble-central-254.sh`(BLE_CENTRAL = 02),共用 `scripts/node/ble-lib-254.sh`(§4.7)。
5. `scripts/ble-ah.py`(§4.8)。
6. `prov-tools-254`(§4.9)。
7. 判定的 stub 測試 `scripts/test-dv-ble-254.sh`(btmgmt / bluetoothctl / btmon 真實輸出樣本 + 合成看見紀錄)、`scripts/test-dv-preflight.sh`(stub ssh);CI 與 daily-validation 都跑。
8. 文件:`254-stage1-impl.md` §9 / §10(§10);向量 README 的檢查數(現寫 156,實際 195);#290 的路徑表(§1.4)。

**不做**(寫進 #254 / #290 checklist):
- #290:ssh 同時連線數預算(要改 `fssh`,是執行期計數;本 PR 只在 BLE 測項內自限 ≤ 2,§4.7)、主機端全域互斥鎖、known-failures 到期欄、PR body 標記 CI、每日排程、時鐘接近午夜(§4.1 P8)。
- #254:`peer.py`(H3)、coex(P2)、GATT / iPad 回歸(P2)、SC Just Works 的負對照(P2,要 04 掛 agent)、`flynn/noise` 與 `-dev` 向量(P2)。

### 1.3 事實(本次實測或讀原始碼)
| # | 事實 | 證據 |
|---|---|---|
| E1 | 節點上:有 `bluetoothctl`、`openssl` 3.0.19、`flock`、`fsync`、`readlink`、`mountpoint`、`setsid`、`sha256sum`;**沒有** `btmgmt`、`btmon`、`python3`、`timeout`、`busctl`、`dbus-send` | 02、04 `command -v`(2026-10-20;`timeout` 由審查 B 查) |
| E2 | `btmgmt`、`btmon` 在 firmware build 樹 `build_dir/target-aarch64_cortex-a72_musl/bluez-5.72/{tools/btmgmt,monitor/btmon}`;NEEDED:btmgmt → `libreadline.so.8`,btmon → `libglib-2.0.so.0`、`libgthread-2.0.so.0`,兩台節點都有 | `readelf -d`(審查 A V7 / B)、節點 `ls` |
| E3 | harness 節點暫存目錄 `/tmp/run/batman-dv`(`HDS`:`mkdir -m 700`、`-O`、非 symlink),多個測項共用(halow-fi-263、setkey-202…);tmp-trust allowlist 允許 `scripts/*` 用它 | `daily-validation.sh:266-267,659-660`、`tmp-trust-allowlist.txt` |
| E4 | `/tmp` = `tmpfs (rw,nosuid,nodev,noatime)`,**無 noexec**;`/tmp/run` root 0755;`/tmp/lib` root 0755;`/var/lib/bluetooth` → `/tmp/lib/bluetooth` root 0700;`identity` 0600;`batman-sc` root 0600,格式 `boot_id= pid= index= mode= status=` | 02、04 讀 |
| E5 | `scp` 放上去的檔案沒有執行位元(`-rw-r--r--`)→ PR-F 的 `Permission denied` 是執行位元,`chmod 0700` 後可執行 | 04 實測 2026-10-20 |
| E6 | **非互動的 `bluetoothctl mgmt.info` / `mgmt.advinfo` 不註冊 agent**(advinfo 04 實測:`Max instances: 5`、`Instances list with 0 items`):原始碼只在非 `NON_INTERACTIVE` 時註冊(`client/main.c:491-494`、預設 `:3186-3189`);04 實測輸出 `current settings: powered le secure-conn privacy`(無 bondable)、`Agent registered` 0 次。輸出另有一行 `supported settings:` 列出全部位元 | 原始碼(審查 B)+ 04 實測 |
| E7 | **powered 時 kernel 拒絕改 privacy**(`mgmt.c:7024-7026` → `MGMT_STATUS_REJECTED`)→ 白箱「關 privacy」要 power off → privacy off → power on | 讀碼(A V1) |
| E8 | bluetoothd restart:shutdown 送 `SET_POWERED 0`(`adapter.c` 約 10932),啟動在未上電時送 privacy(約 10365)、patch 900 送 SC only;**IRK 從 `identity` 載入,檔案不存在才產生**(`adapter.c:4201-4223` `load_irk` → `generate_and_write_irk`)→ restart 不換 IRK;**停 bluetoothd、刪 `identity`、再啟動 = 換新 IRK,不必重開節點** | 讀碼(A V2、本次) |
| E9 | bluetoothd 啟動時清掉所有 mgmt adv instance(`src/advertising.c:1888-1893`,`max_ads != 0` 且 `num_instances` 時 `remove_advertising(manager, 0)`);hdev 註銷時 kernel 清(`hci_core.c:2754`) | 讀碼 |
| E10 | privacy 開(basic,非 limited)時,**不論 connectable 與否**廣播都用 RPA(`hci_sync.c:1046-1067` `adv_use_rpa`) | 讀碼 |
| E11 | SMP 拒絕順序:not bondable 且對方要求 bonding → `SMP_PAIRING_NOTSUPP`(`smp.c:1756-1758`)排在 SC-only 且對方無 SC → `SMP_AUTH_REQUIREMENTS`(`:1760-1761`)之前;02 端任何 SMP 失敗都回 mgmt 0x05;04 btmon 看得到送出的 reason:PR-F `air-sandwich-04-btmon-r1.txt:8-9` = `SMP: Pairing Failed` / `Reason: Authentication requirements (0x03)` | 讀碼 + PR-F 證據(B) |
| E12 | `btmon -w` 可在節點上錄、`btmon -r` 可在節點上離線讀(印 `= Note`、`@ MGMT Open` 等事件行);snoop 檔 0644 → 必須放在 0700 目錄 | 04 實測 2026-10-20 |
| E13 | logread ring 128 KiB(約 1100 行):02 開機 4 h 後已輪掉開機時的行;`logread -l N` 可取最後 N 行(04:`-l 200` 第一行 10:07:42、現在 12:50:00 = 平常 200 行約 2.7 小時);bluetoothd 每行同時記 `daemon.info` 與 `daemon.err` | 02、04 實測 |
| E14 | 節點時鐘不可信:04 = 2025-07-16、02 = 2026-10-18(相差約 15 個月) | `date` |
| E15 | PR-F 的 RPA 30 分鐘測試用 **bluetoothctl `advertise on`**(bluetoothd adv manager);btmgmt `add-adv` 只用在配對夾心(r1 / r2 同一個 RPA `5B:4F…` 相隔約 273 s;bluetoothd restart 後換 `4D:86…`)。兩條路最後都是 kernel 的 adv instance(bluetoothd adv manager 也走 `MGMT_OP_ADD_ADVERTISING`) | PR-F 腳本 / 證據(A V13) |
| E16 | PR-F 空中測試的坑:(a) 04 用互動 bluetoothctl 當廣播者 → agent 註冊過,`AlwaysPairable=false` 下撤銷 agent 不改回 IO cap(`adapter.c:9081`)→ 04 停在 KeyboardDisplay → 翻轉不外洩;(b) `grep END` 撞 `SEND`;(c) 02 的 bluetoothd 裝置 cache 讓 02 去連不在廣播的舊 RPA(0x04) | session 紀錄 |
| E17 | CI 沒有向量驗證;`verify.py` 結尾印 `195 checks: ALL PASSED`、rc 0;`gen.py` 輸出與 `vectors.json` 逐位元組相同(兩次);`requirements.txt` 釘 7 個,venv 實際 14 個套件(另有 asn1crypto、attrs、certvalidator、cffi、oscrypto、pycparser、six);pycddl 0.6.4 = `cp312 manylinux_2_17_x86_64` wheel | 讀檔、venv、審查 B |
| E18 | daily-validation:`suite name why cmd [D]`;rc 3 + `SKIP-REASON:` = SKIP;`D` 觸發 fleet settle 慢路徑;`fleet_init`(`:159`)只收 BENCH / MESH / OTS / DNODE / T263;section 1–2c 的主機端 suite 在 `fleet_init` 之前;tier B 在 `FEATURE_MODE=--destructive` **且 DNODE eth0 carrier = 1**(`:2479-2480`);既有會換槽 / 重刷的 suite(ab-selftest `:161-169`、reflash-survives-config-202 `:2037`)都在 tier B 之前;沒有主機端鎖 | 讀檔 |
| E19 | `fault-injection.sh:125-150` `precheck` 已有 payload 對執行中 rootfs 的判定(解壓 + 雜湊數百 MB,`QT=600`),可用 `FI_SOURCE_ONLY=1` source | 讀檔(B) |
| E20 | `batman-slot rollback` = 把預設改成另一個槽(`batman-slot:731-741`),之後 `batman-slot reboot committed` 進入 | 讀碼 |
| E22 | distroconfig:02 p1(`/boot`)有 `core_freq_min=500` 與 `miniuart-bt`,**p3 只有 `miniuart-bt`**;04 p1、p3 兩份都有 | 02、04 `/boot` 讀檔 + p3 唯讀掛載(2026-10-20) |
| E23 | 02 `/opt/batdata/ota.tar.gz` 的 `root.squashfs`(112631352 B)與 02 slot B(`mmcblk0p4`)前 112631352 B 雜湊相同 = 1.5.12-wsl.2;02 沒有 `autocommit-hold-commit` 旗標;`batman-slot verify` ok | 02 實讀(2026-10-20) |
| E24 | btmon `-r` 輸出是「區塊標頭 + 縮排子行」:`< ACL Data TX` / `> ACL Data RX` / `> HCI Event:` 標頭,下面縮排 `SMP: Pairing Failed (0x05) len 1`、再縮排 `Reason: Authentication requirements (0x03)`;同一輪也有斷線事件的 `Reason: Authentication Failure (0x05)`(同碼不同義) | PR-F `air-sandwich-04-btmon-r1.txt` |
| E25 | busybox ash 的 `kill` 不接受 `--`(`invalid number '--'`);`kill -TERM -<pgid>` rc 0、群組結束;pgid 從 `/proc/<pid>/stat` 第 5 欄讀;**`pgrep -f <字串>` 會匹配到下指令的 ssh shell 自己**(作者 2026-10-20 在 02 因此誤殺自己的 session,節點無影響)→ 一律用 `$!` 與 `/proc` | 02 實測 |
| E26 | `bluetoothctl` 只要命令列帶指令(`argc > 0`)就是非互動模式(`shell.c:1245`),不註冊 agent;`--timeout` 選項存在(`shell.c:1132`);**經 FIFO 餵指令 = 互動模式,會註冊 agent** | 讀碼(審查 A / B 第 2 輪) |
| E27 | kernel 只在未上電時接受 privacy / IRK(E7);bluetoothd 啟動時若 adapter 已上電(例如 bluetoothd 被 SIGKILL 後 respawn)不會先斷電,set privacy 失敗只記 log(`adapter.c:4242-4253`、`:10365`)→ 檔案裡是新 IRK、kernel 仍用舊 IRK | 讀碼(審查 B 第 2 輪) |
| E28 | hold-commit 只在旗標內容 == 這次開機的版本時生效,否則記 `HOLD-COMMIT-DISCARDED` 並刪旗標、照常 commit(`batman-autocommit:259-290`;**02 slot B 的 wsl.2 有這段**:唯讀掛載 `mmcblk0p4` squashfs,`/usr/bin/batman-autocommit:286`);`fault-injection.sh:215-218` `held_trial` 寫的是**執行中**版本;r1 / r3 / r4 先跑 `precheck`(payload 必須 == 執行中 build) | 讀碼(審查 A / B 第 3 輪)+ 02 唯讀掛載(作者) |
| E29 | 兩種「壞槽」標記:`BATMAN-BAD`(slot 的 boot FAT,只在 apply 驗證失敗時寫;`rollback` / `commit` 會拒絕該槽)與 `/opt/batdata/state/bad-slot`(autocommit revert 時寫 `slot=… version=…`;只擋「同一槽同一版本」再開機;任何 commit 會刪) | `batman-slot:35,364-384,677,723,735`、`batman-autocommit:195,243,360,502` |
| E30 | Pi 4 EEPROM 在 plain reboot 時約 5/10 次開到錯的槽,explicit partition(`batman-slot reboot committed`)10/10 | `batman-slot:744-751` 註解 |
| E31 | `bluetoothd` 正常停止(SIGTERM)時 `adapter_shutdown` 先斷電;只有 SIGKILL 後 procd respawn 才會在 adapter 上電時啟動(E27 的路徑) | 讀碼(審查 B 第 3 輪) |
| E32 | payload `metadata` 的 `version=` 是建置時間戳(02 `ota.tar.gz` = `20261018-113030`,`build-ab-payload.sh:69` `date +%Y%m%d-%H%M%S`),**不是** `BATMAN_VERSION`;autocommit 的 `version()` 讀 `/etc/batman-build` 的 `BATMAN_VERSION`(`batman-autocommit:66`、比對 `:269-287`);02 `/opt/batdata/state/slot-B.protected` = `1.5.12-wsl.2+f2f2bf6.fw9d87d02`,OTA 會刪它(`batman-slot:432-433`);02 slot B squashfs 的 `/etc/batman-build` = `1.5.12-wsl.2+f2f2bf6.fw9d87d02`(作者唯讀掛載) | 讀碼 + 02 實讀(審查 B 第 4 輪、作者) |
| E33 | autocommit 時序:POLL 10、NEED 3、JOIN_NEED 3、MIN_WINDOW 300(`batman-autocommit:30-34`);hold 沒生效時健康的 trial 可在數十秒到幾分鐘內 commit(`:460-502`);狀態檔 `autocommit.committed`、`autocommit.deadline` | 讀碼(審查 A / B 第 4 輪) |
| E34 | `batman-slot rollback` = 把預設改成**目前執行中槽以外的那個槽**(`batman-slot:731-741`,`T=$(other_slot "$A")`)→ 在 slot A 上執行會把預設改成 B | 讀碼(審查 B 第 6 輪) |
| E35 | wsl.2 的 autocommit(02 slot B 唯讀掛載):bcm2711 `DEF=600`、`MIN_WINDOW=300`、`DEFER_MAX=600`(`:34-35,378`);02 沒有 `/opt/batdata/state/autocommit.timeout` → T = 600 | 02 實讀(作者 2026-10-20) |
| E36 | 翻轉段是 legacy Just Works(PR-F btmon:`No MITM, Legacy`,TK = 0)→ BLE 範圍內被動監聽者可從錄到的配對推出分發的金鑰(04 與 02 的 IRK) | PR-F btmon + 公開攻擊類別(審查 A 第 6 輪) |
| E21 | 2026-10-19 全套的 runner 錯(各浪費一次長跑):缺 `FI_PAYLOAD`、harness 是 `git archive`(沒有 `.git` / `feed/`)、BENCH==MESH;原型 preflight 負對照 5 項全抓、正向 PASS | scratchpad `254/dv-preflight.sh` |

### 1.4 路徑分類
#290 規則 1 把 `scripts/node/` 列為「產品路徑」,但那裡一直放 harness 的節點端 client(`p5-follows-202.sh`、`halow-fi-263.sh`…),不進 image。本 PR 定義:**`scripts/node/*` = harness 節點端工具**;產品路徑 = `feed/`、`deploy/`、`files/`(firmware repo)。本 PR 在 #290 留言更正路徑表(governance CI 還沒寫,不影響現有 CI)。

## 2. 元件
| 元件 | 跑在哪 | 新 / 改 |
|---|---|---|
| `scripts/dv-preflight.sh` | 測試主機(Git Bash 或 WSL) | 新 |
| `scripts/daily-validation.sh` | 測試主機 | 改:最前面 `fleet_init` + preflight;新增 BLE / prov 測項 |
| `scripts/test-dv-preflight.sh`、`scripts/test-dv-ble-254.sh` | CI + daily-validation(無硬體) | 新 |
| `scripts/node/ble-lib-254.sh`、`ble-periph-254.sh`、`ble-central-254.sh` | 節點(root) | 新 |
| `scripts/ble-ah.py` | 測試主機的 `DV_PY` | 新 |
| `.github/workflows/ci.yml` job `vectors-219` | GitHub Actions | 新 |
| `tests/vectors/219-protocol/requirements.txt` | — | 改:整個相依閉包 + `--hash` |
| `scripts/tmp-trust-allowlist.txt` | — | 改:新節點腳本的 `/var/lib/bluetooth` 等條目(§7) |
| 工具目錄 `$DV_BT_TOOLS`(預設 `~/batman-dv-tools/bluez-5.72/`:`btmgmt`、`btmon`、`SHA256SUMS`) | 測試主機 | 新(不進 repo;由 `scripts/dv-bt-tools.sh <build_dir>` 從 build 樹複製一次並寫 SHA256SUMS) |

## 3. 擁有權
所有 BLE runtime 狀態只在 BLE 測項執行期間被 harness 改動,且整段都在節點鎖內(§4.7 `flock`)。

| 資源 | 唯一擁有者(可改) | 唯讀者 / 還原者 |
|---|---|---|
| 04 adv instance 1 | `ble-periph-254.sh`(`adv-on` / `adv-off`) | 02 掃描;還原 = 04 deadman(§4.7)或 bluetoothd 啟動(E9) |
| 04 mgmt runtime 設定(`sc`、`privacy`、`powered`) | bluetoothd(啟動時設定,E8);白箱 / 翻轉段由 `ble-periph-254.sh` 暫改 | 還原 = `ble-periph-254.sh restore`(停 bluetoothd → 啟動)或 04 deadman |
| 04 `identity`(IRK) | bluetoothd;**作廢**由 `ble-periph-254.sh rekey`(bluetoothd 停止期間刪除 → 啟動重新產生,E8) | `irk`、`irk-hash`、`canary`(只讀,§4.8) |
| 04 btmon 程序 + snoop | `ble-periph-254.sh`(`btmon-start` / `btmon-stop`);snoop 只在 `/tmp/run/batman-dv/bt/` | 判定前在節點上過濾(§4.7);刪除 = `btmon-stop` 之後的 `snoop-clean` |
| 02 bluetoothctl session、FIFO、keeper、掃描 | `ble-central-254.sh`(每個 session 一個 process group) | 還原 = `ble-central-254.sh restore`(殺 group + bluetoothd restart)或 02 deadman |
| 02 mgmt runtime 設定(`bondable`、`sc`)、agent / IO cap | `ble-central-254.sh`,同一個 session 內設 | 還原同上 |
| 02 `cache/*` 與裝置目錄(`^[0-9A-F:]{17}$`) | bluetoothd;**清除**只在 bluetoothd 停止期間由 `ble-central-254.sh reset` | — |
| 02 `identity`、`settings` | bluetoothd(harness **不可**改;`reset` 前後比雜湊) | — |
| `bt/lease`(run_id、boot_id、到期) | 取得 lease 的那個 run(`acquire` / `release`);到期後由其 deadman 在鎖內刪除 | 每個指令驗證;preflight、`ble-state` |
| `bt/lock`(flock) | 每個指令執行期間的持有者;`dm-fire` 執行還原時 | — |
| deadman(每台節點至多一個,屬於 lease 擁有者) | `ble-lib-254.sh` `dm_arm`(原子替換)/ `dm_cancel` / `dm-fire` | `ble-state` 檢查 |
| `/tmp/run/batman-dv/bt/`(工具、log、snoop、lock) | BLE 測項;收尾只刪 `bt/` 的 log 與 snoop,不碰 `/tmp/run/batman-dv` 其他東西 | — |
| `/tmp/run/batman-dv/ble-state/{flipped,irk-exposed,dm}`(標記) | `ble-lib-254.sh`;`flipped` 只在 `restore` 驗到新 bluetoothd pid 後刪;`irk-exposed` 只在 `rekey` 驗到 IRK 雜湊改變後刪(或重開 = tmpfs 清空) | preflight、`ble-privacy-254` |
| `$DIR/preflight.txt`、`$DIR/<suite>.log` | daily-validation | 報告 |

PR-P2 之後 provd 擁有廣播;H3 要決定 harness 測項是停 provd 還是改用 provd 的廣播(§9)。

## 4. 契約

### 4.1 `dv-preflight.sh`
- **位置**:daily-validation 開頭(section 1 之前):先 `fleet_init`(加入 `BLE_PERIPH`、`BLE_CENTRAL`),再 preflight。輸出寫 `$DIR/preflight.txt` 並印到 console。可單獨執行。
- **結果**:rc 0 = 全過;rc 1 = 至少一項 FAIL → daily-validation **不跑任何 suite**,報告只有 `preflight` 一列 FAIL,exit 1。`DV_PREFLIGHT=off` 只給 harness 自我測試:報告頁首印「PREFLIGHT BYPASSED」,exit 永遠 ≠ 0。
- **時間**:靜態與 ssh 檢查數秒;P5 依 fault-injection 的 precheck(解壓 + 雜湊)每節點數分鐘,只在 `AB_MODE=--destructive` 時跑。
- **檢查**(每項一行 `preflight ok: …` 或 `PREFLIGHT FAIL: …`;讀不到 = FAIL):
  - P1 harness 是 git checkout、`feed/`、`tests/`、`scripts/daily-validation.sh` 都在。
  - P2 MSYS(Git Bash)下 `REPO` 必須是 `//wsl.localhost/...`。
  - P3 每個設定的節點 ssh 得到、committed(`batman-slot is-trial` rc 1)、`BATMAN_VERSION` 讀得到;fleet 版本一致(#290);沒有殘留的 `autocommit-hold-commit`(印出內容與 N3 的安全清除步驟);`AB_MODE=--destructive` 時 BENCH 在 slot A(#290)。
  - P4 角色:BENCH ≠ MESH;IPERF_PEER ≠ MESH;BENCH ≠ OTS(load-soak);BLE_PERIPH ≠ BLE_CENTRAL;`FEATURE_MODE=--destructive` 時 **BLE_PERIPH == DNODE**(重開要有乙太網救援,E18)。
  - P5 `AB_MODE=--destructive`:對每個 fault-injection 目標以 `FI_SOURCE_ONLY=1 . fault-injection.sh <node> --case r1` 載入(與 `test-harness-265.sh` 相同的 source 方式;`NODE`、`PAYLOAD` 由參數與 `FI_PAYLOAD` 設定)後呼叫 `precheck`(同一份判定,E19);stub 案例證明 payload 不符時它回非 0;`DV_T263_KO` 存在、vermagic == `DV_T263_NODE` `uname -r`、路徑含該節點 `BATMAN_VERSION`。
  - P6 BLE harness 狀態(只擋 harness 與設定,**不擋產品狀態**:`hci0`、`batman-sc` 由 `ble-privacy-254` 與每個 tier B BLE suite 開頭判,02 暖開 1/4 的 hci0 失敗只讓那些 suite FAIL,不讓整個 run 什麼都不跑):每個 bcm2711 節點 **BLE 狀態乾淨**(§4.7 `ble-state`:無 `flipped`、無本次 boot 的 `irk-exposed`、沒有未到期的 lease、無活著的 deadman / btmon / harness bluetoothctl、04 無 adv instance——adv instance 要 bluetoothd 在跑才讀得到;bluetoothd 沒在跑時這一項記 `adv: not readable (bluetoothd down)` 並 FAIL 該節點的 tier B BLE suite(不擋整個 run;`ble-privacy-254` 本來就會因 pid 判 FAIL));`FEATURE_MODE=--destructive` 時另驗 `BLE_PERIPH`、`BLE_CENTRAL` 有設且是 bcm2711、`$DV_BT_TOOLS/SHA256SUMS` 與兩個檔案相符(sha 印進 `preflight.txt`)、staging 後在 BLE_PERIPH 實跑 `btmgmt --version` 與 `btmon --version` = `5.72`(驗動態函式庫)、`DV_PY` 跑 `ble-ah.py --selftest` rc 0。
  - P7 logread 灌爆(#290、#286):每個節點讀 `logread -l 200 | head -1` 的時間戳 t 與節點 `date`(同一台的時鐘,E14 不影響);`now − t < 60 s`(= 60 s 內 > 200 行;平常 200 行約 2.7 小時,E13)→ FAIL;`now < t`(時鐘往回跳)→ FAIL;時間戳解析不了 = FAIL。**開機 10 分鐘內的節點先等**(開機那陣 log 量本來就大):等到 uptime ≥ 600 s 再判,最多等 10 分鐘,仍未到 = FAIL。
  - P8 **時鐘接近午夜(#290)不做**:節點時鐘不可信(E14),依賴固定路徑 log 的 #264 overlay 已移除;理由寫進 #290。
- **信任**:只讀節點,兩個例外:P6 的 staging 寫 `bt/<run_id>/` 下的工具(root 0700);刪除已結束 run 的 `bt/<run_id>/`(條件見 §4.7,先印出)。

### 4.2 CI `vectors-219`
- 觸發:每次 push / PR,不加路徑過濾。
- 步驟:`actions/setup-python`(釘 commit SHA)Python 3.12 → `pip install --require-hashes --no-deps -r requirements.txt`(14 個套件全部釘版本 + hash)→ `verify.py`:rc 0 **且**最後一行符合 `^([0-9]+) checks: ALL PASSED$` 且數字 ≥ `MIN_CHECKS`(workflow 內,= 195)→ `gen.py` 輸出與 `vectors.json` `cmp` 相同 → **負對照**:把 `psk_replay` 一個位元組翻轉成副本後跑 `verify.py`,必須 rc 1 **且**輸出有 `FAIL` 行點名 `psk_replay` 的檢查、且沒有 `Traceback`(證明是判定擋下,不是程式壞掉)→ `test-dv-preflight.sh`、`test-dv-ble-254.sh`。
- 失效:任何一步 rc ≠ 0 = job FAIL。

### 4.3 `ble-privacy-254`(tier A:每天,非破壞性,不放工具)
目標:fleet 中每個 bcm2711 節點;Pi 3 = N/A(SoC 規則)。全部從節點讀,讀不到 = FAIL:
1. `batman-sc`:`boot_id` == 本次、`pid` == `pidof bluetoothd`、`mode=2 status=0`、檔案 root 0600。
2. `bluetoothctl mgmt.info`(非互動,E6):**只取 `current settings:` 那一行**,拆成 token 逐一比對:含 `powered`、`le`、`secure-conn`、`privacy`;不含 `bondable`、`br/edr`、`connectable`、`discoverable`。找不到那一行 = FAIL。
3. `/var/lib/bluetooth` `readlink -f` == `/tmp/lib/bluetooth`、`/tmp` 是 tmpfs mountpoint、`/tmp/lib` root 且非 group / world 可寫、`/tmp/lib/bluetooth` root 0700、每個 `identity` 0600。
4. `/proc/net/protocols` 無 `ALG`,且 `/lib/modules/$(uname -r)` 下沒有 `af_alg*`、`algif_*`(A m10:`=m` 模組會被 `socket(AF_ALG)` 自動載入);`/lib/upgrade/keep.d/*` 無 bluetooth 路徑;`/etc/bluetooth/keys` 不存在。
5. **BLE 狀態乾淨**(§4.7 `ble-state`):無 `flipped`、無本次 boot 的 `irk-exposed`、無未到期的 lease、無活著的 deadman。這條擋住「上一次 tier B 中斷,04 停在 `sc on` 或 IRK 已外洩」(`sc on` 與 only 在 current settings 看起來一樣,只有標記抓得到)。
- **IRK 來源**:2 有 privacy 且 4 沒有 AF_ALG ⇒ IRK 只可能來自 patch 900 的 getrandom 路徑(F26)。`Generated IRK (getrandom)` 這行 log 會被 ring 輪掉(E13),不在 tier A 斷言,改在 §4.6 重開後立刻讀。
- 與上層 §9 的差異:上層寫「只在 fresh overlay 上判定」(防 wsl.5 留下的 `/etc/bluetooth/keys` IRK 被沿用),v2 以斷言 4 的 `/etc/bluetooth/keys` 不存在 + 斷言 3 的儲存區在 tmpfs 直接檢查那個條件,不需要知道 overlay 新舊;上層的 wsl.4 / wsl.5 負對照改為 §4.10 的白箱與舊版槽。
- 負對照(§4.10):N1 關 privacy、N3 舊版槽、N4 留 `flipped` 標記 → 必須 FAIL。

### 4.4 `ble-rpa-254`(tier B,約 40 分鐘)
- **時間軸只有一條,由測試主機擁有**(A M1 / B M1)。主機以自己的時鐘排程:每個 04 事件(adv-on、重新註冊、adv-off)與每個 02 取樣都由主機下指令觸發並以主機時間記錄。節點端長時間程序以 `setsid` detach,寫結果檔,主機輪詢;主機用自己的**單調時鐘**(主機 `/proc/uptime`;Git Bash 與 WSL 都有;不用 bash `$SECONDS`,它跟著牆鐘);節點端時間戳只用 `/proc/uptime`(單調),開始與結束各量一次主機與每台節點 uptime 的差(取 ssh 往返的中點;閒置 RTT 0.17–0.30 s,審查 A 實測),兩次差 > 2 s = 該次無效 → FAIL。
- **廣播**:04 `adv-on` = `btmgmt add-adv -g -u 181c -d <AD local name> 1`,**non-connectable**(無 `-c`,E10:privacy 下仍是 RPA;沒有連線 → 不會因斷線重開廣播而換 RPA)。local name = `BatmanT-<6 hex 隨機>`(每次執行不同,避免其他廣播者或舊 cache 同名)。
- **起點**:T0 之前 04 先 `restore`(bluetoothd restart = power cycle → 新 RPA,`hci_sync.c:5140`、`hci_event.c:1357`,審查 B),免得上一個 RPA 已用了一段時間、(b) 段中途剛好過期。
- **段落**(主機時間,T0 = 主機下 `adv-on` 的時刻):
  - (b) T0 → T0+300:T0+150 重新註冊(`rm-adv` + `add-adv`,timeout 前)→ 整段同一個位址。
  - (a) T0+300 → T0+2100:不動 30 分鐘 → 同一個位址,且與 (b) 相同。
  - (c) T0+2100:重新註冊(已超過 `rpa_timeout` 900 s)→ T0+2100 → T0+2400 新位址,與 (a) 不同。
  - 每個轉換點前後 30 s 是保護帶,保護帶內的看見紀錄不計入任何段。
- **取樣**:02 `ble-central-254.sh sample <name>`:每 60 s(主機觸發)做一次 10 s 掃描:**非互動** `bluetoothctl --timeout 10 scan on`(E26:不註冊 agent;不用 FIFO),回傳該次看到 `<name>` 的位址。只有本次掃描期間收到廣播的紀錄才算看見(bluetoothctl 開 session 時列出的已知裝置不算);實作以真實輸出做判讀 fixture,並以 **N2b**(04 不廣播時取樣必須 0 次看見)證明 cache 不會造成假看見——判讀規則若做不到,改用 `btmgmt find`(kernel 直接回報,沒有 cache),兩者都以 N2b 為準。02 在測項開始前 `reset` 一次(清 cache);名稱每次隨機,舊 cache 裡不會有同名裝置。每段切成 2 分鐘的桶,**每個桶至少一次看見**,段的第一個與最後一個桶都必須有;缺任何桶 = FAIL「沒觀察到」。
- **判定**:每段位址集合恰好 1 個;(a) == (b);(c) ≠ (a);每個位址最高兩位元 = `01`、≠ 04 public 位址;`ah()` 對 04 的 IRK 吻合(§4.8);整段 04 public 位址出現 0 次。04 每 60 s `btmgmt info`:`current settings:` 不得有 `bondable`。04 btmon 錄整段:任何 `LE Connection Complete` → 該次無效 → FAIL(non-connectable 不該有連線)。
- **前提**:整段不得有 power cycle 或 bluetoothd restart(會換 RPA,E15);每次取樣同時讀 04 bluetoothd pid,變了 = 無效 → FAIL。
- 負對照(§4.10):N1(關 privacy → public)、N2(掃描中途殺掉 → 缺桶)、N2b(04 不廣播 → 0 看見)、N5a((a) 段 T0+1200 power cycle → 新 RPA → FAIL)、N5b((c) 段改在 T0+600 重新註冊(未過 900 s)→ RPA 不變 → (c) == (a) → FAIL)。

### 4.5 `ble-pair-sc-only-254`(tier B,`D`)
上層 §9 的夾心,工具換成 PR-F 實證組合(E15、E16),判定改用 04 送出的拒絕原因(B M2)。
- **每輪** `round <label> <sc on|off> [bondable on|off]`:
  1. 02 `reset`:停 bluetoothd → 列出(只印路徑)再刪 `/var/lib/bluetooth/<a>/cache/*` 與名字符合 `^[0-9A-F:]{17}$` 的目錄 → 驗 `identity`、`settings` 雜湊不變 → 啟動 → 等 `hci0` 與 bluetoothd pid。
  2. 04 `adv-on <name> connectable`(`-c`)、`btmon-start <label>`(每輪一個新的 btmon 與 snoop);04 斷言 `current settings:` 有 `privacy`、無 `bondable`,非翻轉段有 `secure-conn`。
  3. 02 同一個**互動** bluetoothctl session(FIFO;E26:會註冊 agent,所以 bondable 由下一步明確關掉,並在 pair 前一行斷言;02 是攻擊者角色,agent 不影響 04 的受測條件):`mgmt.bondable off`(N6 負對照為 `on`)→ `mgmt.sc <x>` → `scan on` 10 s → 取 `<name>` 位址 → `mgmt.info`(緊接 pair 前一行;斷言 `current settings:` 的 bondable 與設定一致、sc off 時無 `secure-conn`)→ `mgmt.pair -c 3 -t 2 <addr>` → 25 s → `devices` → quit。
  4. 04 `btmon-stop` → 節點上 `btmon-judge`(§4.7)把 snoop 轉成結論行後抓回。
- **四態判定**(每輪):
  - **外洩**:02 回 `Paired with <04 public> (LE Public)`,或 `devices` 有 04 public,或 04 結論行有 `SMP TX IdentityInformation`。
  - **擋下**:02 回 `failed with status 0x05` **且** 本輪 04 結論行恰好一個 `CONN status=0x00` **且** 恰好一個 `SMP TX PairingFailed reason=0x03`(TX = 04 送出;reason 以 SMP 區塊內的那一行為準,斷線事件的 Reason 另列 `DISC reason=…`,不混用,E24)**且** 沒有 `SMP TX IdentityInformation`。
  - **其他原因擋下**:同上但 `SMP TX PairingFailed reason` ≠ 0x03(例如 0x05 Pairing Not Supported、0x0c Numeric comparison failed)→ 記錄 reason。
  - **無效**:沒連上、0x04 / 0x08、逾時、步驟 1–3 任何斷言失敗 → 重做一次;仍無效 → FAIL。
- **段落**(一次跑完才算,任一段不符 = FAIL):
  1. 目標(04 SC-only,02 sc off、bondable off)→ 擋下(0x03)。
  2. **翻轉**(04 `flip` = `btmgmt sc on`;先寫 `flipped`、`irk-exposed` 標記與 deadman)→ 外洩;**不外洩 = 整個測項 FAIL「測法失去鑑別力」**。
  3. restart(04 `restore` → 新 pid、`batman-sc` mode 2 → 刪 `flipped`)→ 擋下(0x03)。
  4. N6(02 bondable on、sc off)→ 必須是「其他原因擋下」reason 0x05(NOTSUPP,E11),**不能**判成「擋下」→ 證明判定分得出 SC-only 與其他拒絕。
  5. SC Just Works(02 sc on)→ 只記 `SMOKE reason=<x>`,不影響判定(沒有負對照,上層 §9 v19 B-delta m2)。
- **收尾**:04 `rekey`(§4.7)、`adv-off`、刪 snoop;02 `restore`。不必重開 04(E8),重開留給 §4.6。02 的 IRK 在翻轉段會交給 04(02 有 privacy),而且翻轉段是 legacy Just Works,BLE 範圍內被動監聽者可從錄到的配對推出 04 與 02 的 IRK(E36)→ 04 `rekey` 作廢 04 的 IRK 並刪掉 04 儲存區裡 02 的裝置目錄;**02 在 tier B BLE 區塊收尾時以 `batman-slot reboot committed` 重開**(H-U7)作廢 02 的 IRK。

### 4.6 `ble-privacy-reboot-254`(tier B,`D`,排在 pair 之後)
04:記 bluetoothd pid、IRK 雜湊(`irk-hash`:節點上 `sha256sum` 前 8 hex,IRK 不離開節點)、boot_id → `restore`(bluetoothd restart)→ 新 pid、`batman-sc` mode 2 status 0、IRK 雜湊**不變**(E8)→ `batman-slot reboot committed` → **ssh 一恢復就先** `logread -e 'Generated IRK \(getrandom\)'` 至少 1 行(info / err 兩份都算)、新 boot_id、IRK 雜湊**不同**、`batman-sc` 新 boot_id 與 pid → 再等 OTS ready(fleet settle `D`)。log 行讀不到 = FAIL(不重試、不降級)。
- 依序執行 rpa → pair → reboot,一次全套只重開 04 一次。

### 4.7 節點端腳本(`ble-lib-254.sh` + 兩支)
- **放置與呼叫**:tier B 開始時 harness 把 `ble-lib-254.sh`、`ble-periph-254.sh` 或 `ble-central-254.sh`(與 04 上的 `btmgmt`、`btmon`)`scp` 到 `/tmp/run/batman-dv/bt/<run_id>/`(每個 run 自己的目錄,不會覆蓋另一個 run 的 deadman 要執行的檔案)(`HDS` 規則建立;`bt/` 0700;`chmod 0700`;執行前檢查 owner root、非 symlink、link count 1;sha256 與主機端相同)。之後一律 `ssh root@<n> "RUN_ID=<id> sh /tmp/run/batman-dv/bt/<run_id>/ble-<role>-254.sh <cmd> …"`;**stdin 留給資料**(例如 `canary` 收 log)。deadman 也執行這份檔案。tier A(`ble-privacy-254`)不放檔案,以 `sh -s` 送唯讀的判讀函式(只讀、無狀態)。
- **lease(互斥,取代 v2 的單一指令鎖)**:`bt/lease` = `run_id boot_id expiry_uptime`。`acquire <seconds>` 在 `flock -w 30 bt/lock` 內:沒有 lease、或 lease 已到期**且**其 deadman 已執行完 → 寫入自己的 lease;否則 FAIL「另一個 BLE 測試(run_id …)在跑」。**每個指令**都在 `flock -w 30 bt/lock` 內先驗 lease 的 `run_id` == 自己的 `RUN_ID` 且未到期,否則 FAIL;`release` 在收尾驗證完成後刪 lease。40 分鐘的 rpa 段中,鎖只在指令期間持有,但 lease 全程有效 → 第二個 harness 在任何時刻都拿不到。操作員直接打 bluetoothctl 擋不住,由每輪斷言與 `ble-state` 發現。
- **deadman(每台一個,屬於 lease 擁有者)**:`dm_arm <seconds>` 在鎖內先記下既有 `dm` 與 `dm.new` 的 pgid(上一次 arm 中斷可能留下 `dm.new`,它可能是唯一還在保護節點的 deadman),**先 arm 新的**,再取消記下的舊 deadman;任何時刻至少有一個 deadman(中間 ssh 斷線也至少有一個 deadman 在):`setsid sh /tmp/run/batman-dv/bt/<run_id>/ble-<role>-254.sh dm-fire <run_id> <seconds> </dev/null >/dev/null 2>&1 &`,以 `$!` 讀 `/proc/$!/stat` 第 5 欄得 pgid(不用 `pgrep -f`,E25),寫 `ble-state/dm.new`;然後取消舊的(驗 boot_id + `/proc/<pgid>/cmdline`,`kill -TERM -<pgid>`(E25,不用 `--`),每 1 s 檢查群組成員,10 s 內不全消失 = FAIL);最後 `mv dm.new dm` 當完成標記。lease 到期時間同時延到同一刻;**新 deadman 的期限 ≥ lease 的到期時間**(兩者在同一個鎖內設定,deadman 晚 5 s),所以 lease 一到期,記錄在 `dm` / `dm.new` 的那個 deadman 一定會動作。白箱負對照 N7b:在 `dm.new` 寫好、`mv` 之前殺掉 harness → 到期後由 `dm.new` 的 deadman 還原。preflight / `acquire` 看到 `dm.new` 而沒有對應的 `dm` = 上次 arm 中斷 → 兩個 pgid 都檢查。`dm-fire` 睡到期後取得 `bt/lock`(拿不到就每 30 s 重試;超過 10 分鐘仍拿不到 = 持鎖指令卡死 → 先在 p6 log 記一行,只殺**同一個 run_id** 記錄的群組,不拿鎖直接還原);動作前再驗三件事:lease 屬於該 run、lease **已到期**、自己的 pgid 是 `ble-state/dm` **或** `ble-state/dm.new` 記錄的那一個(`dm_arm` 在 `mv` 前中斷時,新的只記在 `dm.new`;A v5 T1)——不是兩者之一(被替換掉卻沒被殺的更舊 deadman)或 lease 未到期(harness 已延長 lease)→ 只寫 log 退出;通過才執行還原並刪 lease。**每個持鎖指令**都有自己的時間上限(腳本內 `sleep` + kill 的 watchdog,節點沒有 `timeout`,E1),超過 = 該指令 FAIL 並釋放鎖。`acquire` 遇到「lease 已到期、其 deadman 已不在、lease 還在」(deadman 被殺或節點重開過但 lease 是本次 boot)→ 不接手,FAIL「上一次 BLE 測試沒有收尾,先跑 `ble-recover`」;lease 的 boot_id 不是本次 boot → 視為已作廢(重開清了狀態),可接手。**期限**以最長路徑(含一次重做)算:rpa 段 3300 s(2400 + 重做取樣餘裕 + 600);每段配對 900 s(兩輪 ×(reset 30 + scan 10 + pair 25 + btmon 判讀 30)+ 餘裕);rekey 300 s。**每一次**改變節點 BLE 狀態之前先 arm(adv-on、flip、btmon-start、02 session、rekey)。
- **02 的 `irk-exposed`**:翻轉前在 02 也寫 `irk-exposed`(含 boot_id);02 的還原動作與 tier B 收尾看到本次 boot 的標記 → `batman-slot reboot committed ble-dm-254`(H-U7),不論該輪成功或失敗。
- **還原動作**:04 = kill harness 的 btmon 群組 → 刪 snoop → `adv-off` → 若有本次 boot 的 `irk-exposed` → 先把原因寫進 p6(`/opt/batdata/log/ble-dm-254.log` 附加一行:時間、boot_id、run_id、原因;擁有者 = `ble-periph-254.sh`;寫入前檢查 `/opt/batdata/log` 是 root 目錄、檔案不是 symlink 且 link count 1,否則不寫只重開;不輪替,一行 < 200 B,只在中斷時寫;清理 = 人工,先印出再刪)再 **`batman-slot reboot committed ble-dm-254`**(H-U6:重開一定換 IRK;deadman 沒有 02 與主機可做 kernel 驗證),否則 `restore`。`irk-exposed` 只在有驗證的 `rekey` 通過後才刪,所以 rekey 進行中 harness 死掉,deadman 仍然重開 04;02 = kill harness 的 bluetoothctl 群組 → 有本次 boot 的 `irk-exposed` 則先寫 p6 log 再 `batman-slot reboot committed ble-dm-254`,否則 bluetoothd restart。
- **`ble-recover`**(操作員或下一次 run 呼叫):依 `ble-state` 做同一套還原;有 `irk-exposed` 時可選有驗證的 `rekey`(需要 02 與主機)或重開 04。
- **`bt/<run_id>/` 的清理**:`release` 刪自己 run 的目錄;preflight 與 `acquire` 對「lease 已不在(或 boot_id 不是本次)**且**該 run 沒有活著的 deadman」的 run 目錄先印出清單再刪。
- **兩台的 lease**:配對段要 04 與 02 兩台;先 `acquire` 04 再 02,第二台失敗 → `release` 第一台、該 suite FAIL。
- **`restore`**:`btmgmt power off` → `/etc/init.d/bluetoothd restart` → 等新 pid + `batman-sc` 新 pid、mode 2 status 0 → 刪 `flipped`。
- **`rekey`(作廢 IRK,不必重開節點)**:`btmgmt power off`(E27:確保 kernel 未上電,bluetoothd 啟動時才能把新 IRK 寫進 kernel)→ 停 bluetoothd → 刪 `/var/lib/bluetooth/<adapter>/identity` 與 `/var/lib/bluetooth/<adapter>/<MAC>/`(`<adapter>` 是 04 自己的位址目錄,只刪它**底下**名字符合 `^[0-9A-F:]{17}$` 的裝置目錄;翻轉段 02 交給 04 的 IRK 在那裡)→ 啟動 → 新 pid、`batman-sc` mode 2、IRK 檔雜湊 ≠ 舊值 → **kernel 驗證**:02 先 `reset`、04 以**新的隨機名稱** non-connectable `adv-on` 一次、02 取樣一次,看到的 RPA 以**新** IRK 做 `ah()` 必須吻合(§4.8)→ `adv-off`。全部通過才刪 `irk-exposed`;任何一步不過 → 保留標記、FAIL「IRK 可能未作廢,重開 BLE_PERIPH」。
- **`ble-state`**:印 `flipped`、`irk-exposed`(含 boot_id;不是本次 boot 的視為已作廢)、lease、deadman 是否活著、harness 的 btmon / bluetoothctl 群組、adv instance 數(04:非互動 `bluetoothctl mgmt.advinfo`,實測輸出 `Instances list with 0 items`,不需放工具)。preflight 與 tier A 用它判「乾淨」。
- **輸出**:每行 `<TAG> …`,主機加主機時間戳。`irk` 是唯一會輸出 IRK 的指令(32 hex,一行,stdout);腳本內不 `set -x`;IRK 只在 shell 變數或 `bt/` 下的 0600 暫存檔,絕不放進外部指令的 argv(`grep -F -f <檔>`,不用 `-e "$k"`)。
- **`btmon-judge`(在節點上把 snoop 轉成結論行;snoop 不離開節點)**:`btmon -r <snoop>` 的輸出以區塊為單位讀(E24):標頭行決定方向(`<` = TX = 本機送出、`>` = RX)與類別(`ACL Data`、`HCI Event: …`);縮排子行依白名單轉成結論:`CONN status=0x..`(LE Connection Complete / Enhanced)、`DISC reason=0x..`(Disconnect Complete)、`SMP <TX|RX> <PairingRequest|PairingResponse|PairingFailed|PairingConfirm|PairingRandom|EncryptionInformation|MasterIdentification|IdentityInformation|IdentityAddressInformation|SigningInformation|PairingPublicKey|PairingDHKeyCheck> [reason=0x..]`(只帶 SMP 區塊內的 `Reason` 碼)。**任何值欄位(key、rand、ediv 等)都不輸出**;無法歸類的子行計數成 `UNPARSED n`(寫進 log 供檢查)。fixture:PR-F 留下的 btmon 檔是 grep 過的(沒有 HCI Event 標頭),不能當 fixture;實作時在 04 上錄一次**完整** `btmon -r` 輸出(目標段 + 翻轉段)。翻轉段含 04 與 02 的 IRK、LTK 等金鑰 → 在節點上以**白名單**遮蔽:只保留標頭行、`SMP:` / `LE Connection Complete` / `Disconnect Complete` 等事件名稱行、`Reason:` / `Status:` 行,其他所有子行的值一律換成固定假值;`canary` 同時比對 04 與 02 的 IRK(02 的 IRK 由 02 的 `canary` 比對,同樣不離開節點);錄完後 04 `rekey`(有 kernel 驗證)、**02 以 `batman-slot reboot committed` 重開**(E30;02 的 IRK 交給過 04 且可被監聽推出,E36;重開一定換 IRK,不改 harness 不可改的 02 `identity`,§3);進 repo 前跑 gitleaks。→ `tests/fixtures/btmon-254/`;`test-dv-ble-254.sh` 斷言:正例 0x03 擋下、外洩段 `IdentityInformation`、同輪 `DISC reason=0x05` 不得被當成 SMP reason、fixture 的 `UNPARSED` = 0——判讀器另有一份「已知、刻意忽略」的子行欄位清單(例如 `IO capability`、`Authentication requirement`、`Max encryption key size`、遮蔽後的值欄位),這些不算 UNPARSED;只有不在白名單也不在忽略清單的子行才算。
- **IRK 外洩檢查(機制,不是人工)**:收尾時把這次抓回 `$DIR` 的所有 BLE log 經 stdin 送回 04 `canary`:04 把 `identity` 的兩種 byte order,以連續 hex 與「每 2 hex 一組以空白 / 冒號分隔」兩種寫法寫進 `bt/` 0600 暫存檔,`grep -i -F -f`(不分大小寫)比對 stdin,命中 = FAIL,暫存檔刪除。在 `rekey` 之前跑(之後 identity 已換)。

### 4.8 `scripts/ble-ah.py`
- 用法:`ble-ah.py --selftest`;`ble-periph-254.sh irk | $DV_PY ble-ah.py <addr>…`(IRK 從 stdin 讀一行)。輸出每個位址 `<addr> rpa=<yes|no> match=<yes|no>`;**任何情況都不回印 stdin**(包括解析錯誤);stdin 空或不是 32 hex = rc 2(FAIL)。
- byte order:`identity` 檔的字串反轉後才是 `ah()` 用的 MSB-first IRK(PR-F 實證);selftest = Core spec 範例向量 **+** 一組合成向量(固定的假 IRK 依 `identity` 檔格式寫成字串 → 以已知 prand 算出位址 → 經同一條解析路徑必須 match、改一個位元必須不 match)。
- `DV_PY`:WSL 下 = venv 的 python;Git Bash 下 = `wsl -d Ubuntu-24.04 -u yello -- /home/yello/venv-219/bin/python`,腳本路徑由 `REPO` 的 `//wsl.localhost/Ubuntu-24.04` 前綴換成 WSL 路徑,並設 `MSYS_NO_PATHCONV=1`。

### 4.9 `prov-tools-254`(tier A)
每個 bcm2711 節點,在 `bt/` 外的 harness 暫存檔上:`readlink -f /var/lib/bluetooth` == `/tmp/lib/bluetooth`;`mountpoint -q /tmp` rc 0;`flock -n` 拿得到,且**已被另一個程序持有時第二個 `flock -n` rc 1**;`fsync <檔>` rc 0。負對照:`PATH=/nonexistent` → FAIL;持有者不放鎖時的競爭案例本身就是負向。

### 4.10 負對照(PR 要附;#290 規則 2 的 `NEGCTL:` / `PASS-ON:`)
| # | 注入 | 預期 | 還原 |
|---|---|---|---|
| N1 | 04 `btmgmt power off` → `privacy off` → `power on`(E7) | `ble-privacy-254` FAIL(無 privacy);`ble-rpa-254` FAIL(public 位址) | `restore`(bluetoothd restart,E8);adv 由 E9 清掉後重新 `adv-on` |
| N2 | `ble-rpa-254` (a) 段中途殺掉 02 的取樣 | FAIL「沒觀察到」 | 02 `restore` |
| N2b | 04 `adv-on` 讓 02 看見一次 → `adv-off` → 02 在 5 s 與 30 s 時各取樣一次(02 的 bluetoothd 裝置物件還在) | 0 次看見(否則判讀有 cache 假看見);原因比對:FAIL 行必須是「cache 假看見」 | — |
| N3 | **02 以 held trial 開進 slot B 的舊版**(見下)→ 跑 `ble-privacy-254`、`prov-tools-254` 的判讀 | `ble-privacy-254` FAIL(無 hci0 / 無 `batman-sc`);`prov-tools-254` 照實記錄 | trial 不 commit:重開(tryboot 一次性)或時限到 → 自動回 slot A |
| N4 | 04 留下 `flipped` 標記(不翻轉) | `ble-privacy-254` 與 preflight P6 FAIL | 刪標記 |
| N5a | (a) 段 T0+1200 04 power cycle | 新 RPA → FAIL | `restore` |
| N5b | (c) 段改在 T0+600 重新註冊 | RPA 不變 → FAIL | — |
| N6 | 配對段 4(02 bondable on) | 「其他原因擋下」reason 0x05,不得為「擋下」 | 02 `restore` |
| N7 | 中斷:rpa 段中、翻轉後各殺掉 harness 一次 | rpa 段:deadman 到期後 04 無 adv instance、`batman-sc` 新 pid、`ble-state` 乾淨;翻轉後:deadman 到期後 04 與 02 都**重開**(新 boot_id、IRK 雜湊不同,`irk-exposed` 隨 tmpfs 消失);兩者在 deadman 到期前跑 preflight → FAIL(原因:lease 未到期 / deadman 活著) | deadman 自動 |
| N7b | `dm_arm` 寫完 `dm.new`、`mv` 之前殺掉 harness;變體:上一次留下 `dm.new` 後再 arm、在取消舊的之前殺掉 harness | lease 到期後恰好一個 deadman 還原;`ble-state` 乾淨 | deadman 自動 |
| N8 | P7:stub(`logread -l 200` 第一行在 30 s 前)+ 實機 `logger` 迴圈灌 300 行 | FAIL | 實機灌之前先把該節點 `logread` 全部存到 `$DIR`(灌入會把 ring 擠掉舊行,視同刪 log,先印出) |
| N9 | preflight:E21 五項 + BLE_PERIPH ≠ DNODE + `SHA256SUMS` 不符 + 非 BLE build(stub)各一 | FAIL | — |
| N11 | 04:刪 `identity` 後 `kill -9 bluetoothd`(E31:procd 在 adapter 上電時 respawn → 新 IRK 只進檔案,kernel 沿用舊 IRK,E27),接著只跑 rekey 的**驗證**步驟 | kernel 驗證失敗(RPA 對不上新 IRK)→ FAIL、`irk-exposed` 保留 | 正常 `rekey`(先 power off) |
| — | **所有負對照都比對 FAIL 的原因**(FAIL 行的固定前綴),原因不對 = 負對照不成立 | | |
| N10 | 判定 stub(`test-dv-ble-254.sh`):`supported settings:` 與 `current settings:` 兩行都在的真實輸出、`le` 子字串、`END`/`SEND`、桶缺一個、保護帶內的看見、reason 0x05 vs 0x03 | 各自正確判定 | — |

**N3 做法(held trial,v4 依 E28 重寫)**:02 沒有乙太網,不能讓它 commit 在別的槽。`scripts/negctl-old-slot-254.sh`(獨立腳本,不經 daily-validation;不呼叫 fault-injection 的 `precheck` 與 `held_trial`,因為兩者都假設 payload == 執行中版本,E28;只借用它的 `q` / `bootid` 等讀取函式,以 `FI_SOURCE_ONLY=1 … --case r1 --no-tenant` 載入,並以自己的 EXIT trap 取代它的 `restore_node`):
1. 前提(唯讀):02 slot A wsl.9 committed、`batman-slot verify` ok、無 `autocommit-hold-commit`、`/opt/batdata/ota.tar.gz` 的 `root.squashfs` == slot B rootfs(E23,取代 `precheck`);**唯讀掛載 slot B 確認 wsl.2 的 autocommit 有版本相符的 hold**(E28,已做);**`V2` 只取自唯讀掛載的 slot B squashfs 的 `/etc/batman-build` `BATMAN_VERSION`**(與 autocommit `version()` 同一個來源,E32),並與 `/opt/batdata/state/slot-B.protected` 交叉比對,兩者不同 = 停止;**禁止**使用 payload `metadata` 的 `version=`(那是建置時間戳)。記錄:`autocommit.timeout`(T,步驟 6 用)、p5 內容雜湊、`uci show network wireless` 摘要、`/opt/batdata/state` 檔案清單與雜湊、slot A overlay 的雜湊(唯讀)。
2. 寫 hold 旗標 = **`V2`**(payload 的版本,不是執行中版本);`sync`;讀回比對。
3. OTA:以既有 OTA 正道(`sysupgrade -n` + setsid,與 fault-injection 相同的呼叫)把 payload 寫入 slot B(與現有內容逐位元組相同)→ tryboot 進 slot B。
4. ssh 一恢復就讀 `autocommit.committed`、`autocommit.deadline`(記下 revert 時限,步驟 6 的等待以它為準)、`BATMAN_VERSION`、`batman-slot is-trial`、autocommit log。**hold 生效** = `BATMAN_VERSION` == `V2`、is-trial rc 0、log 有 hold 生效的那一行、沒有 `HOLD-COMMIT-DISCARDED`、未 commit。**hold 沒生效**(不論讀到的是否已 commit;讀與動作之間 autocommit 可能剛好 commit,E33)→ 送 **`back_to_a`**(見下)。兩種都記 N3「無法執行」(不是 PASS / FAIL),停下來回報。
5. hold 生效 → 跑 tier A 判讀(`ble-privacy-254`、`prov-tools-254`)→ 預期 `ble-privacy-254` FAIL,原因比對(無 hci0 / 無 `batman-sc`)。
6. 回 A:送 **`back_to_a`**(不用 plain reboot,E30)。**若 trial 中 ssh 不到**:hold 中的 trial 由 autocommit 在時限到時 revert(#261 R4 機制,wsl.2 也有),時限以 **wsl.2 的 autocommit** 為準(trial 跑的是它,E35):讀到 `autocommit.deadline` 就用它(uptime 絕對值),讀不到就用 `max(T, 啟動 + 300)`,T = 步驟 1 讀的 `/opt/batdata/state/autocommit.timeout`(02 沒有該檔 → T = 600);主機**從 OTA 送出那一刻起算**最多等:寫入 + 重開 ≤ 900 s、trial 時限 600 s(uptime)、`DEFER_MAX` 600 s、revert 重開 + 開機餘裕 180 s,合計 ≤ 2280 s(約 38 分鐘),超過才判「需要實體處理 02」 → 不需要實體救回;若連 revert 後都 ssh 不到 = FAIL,寫明「需要實體處理 02」。
7. 回來後斷言:slot A、wsl.9、committed、`batman-sc` mode 2、hold 旗標已不在、02 重新加入 mesh(`batctl n` 有 04);與步驟 1 比對 p5 雜湊、uci 摘要、`/opt/batdata/state`、slot A overlay,不同就印出差異寫進 PR;**預期中的差異**:`slot-B.protected` 被 OTA 刪掉(E32)、走 revert 路徑時的 `bad-slot`(E29)、autocommit / otatrace 的紀錄檔。
- **`back_to_a`(唯一會呼叫 rollback 的地方,E34)**:節點端**單一指令**,條件與動作在同一次 ssh 內:`[ "$(batman-slot active)" = B ] && { v=$(sed -n 's/^BATMAN_VERSION=//p' /etc/batman-build); [ "$v" = "$V2" ] || echo "UNEXPECTED VERSION $v"; batman-slot rollback && batman-slot reboot committed negctl-254; }`——**擋住在 A 上 rollback 的是 `active = B`**;版本不符時照樣回 A(否則一個沒有 hold 的 trial 可能被 commit,B v7 m2)並輸出 `UNEXPECTED VERSION`。不在 B → **什麼都不做**,印出目前 slot / 版本。
- **`PHASE`**(腳本變數,每次轉換寫進 log):`pre`(OTA 送出之前)→ `ota`(OTA 送出,等新 boot)→ `trial`(新 boot 在 B 且版本 == V2)→ `returned`(`back_to_a` 之後的新 boot 在 A)。新 boot 落在 A 而 `PHASE=ota` = 「trial 沒切過去」(tryboot 開錯槽或 OTA 失敗,E30),記 N3「無法執行」,不呼叫任何 rollback;報告印出 `batman-slot verify`、autoboot 的 `[all]` / `[tryboot]`、hold 旗標,確認下次重開不會意外進入 B。
- **EXIT trap**(腳本自己的,取代 fault-injection 的 `restore_node`;**正常結束也會觸發**),**依階段**:
  - `PHASE` 在 OTA 之前(`pre`):刪 hold 旗標並讀回確認不存在。
  - `PHASE=returned`:只印狀態(slot、版本、committed、hold 旗標),不做任何動作。
  - `PHASE=trial`:送 `back_to_a`(條件指令,在 A 上不動作)。
  - `PHASE=ota`:**絕不刪 hold 旗標**(旗標內容是 V2,留著無害:只會讓某次開進 wsl.2 的 trial 被 hold、到時限 revert;刪了反而讓一個健康的 wsl.2 trial 被 commit,B v5 M1)。改為有上限地等新的 boot_id(步驟 6 的同一個上限),若落在 B 且版本 == V2 → `back_to_a`;落在 A → 只印狀態;等不到 = 印出「需要人工確認 02:最後已知 slot / 版本 / hold 旗標仍在」並以非 0 結束。
  - 任何階段結束前印出最終 slot / 版本 / committed / hold 旗標狀態。
  - stub 負對照(`test-negctl-old-slot-254.sh`,假 ssh 依指令回放節點狀態):(1) `PHASE=ota` 之後中斷 → 沒有送出任何刪旗標的指令;(2) `pre` 中斷 → 有送出刪除且有讀回;(3) **成功結束、trap 觸發、節點在 A** → 沒有送出 `rollback`;(4) **tryboot 落在 A**(`PHASE=ota`、新 boot 在 A)→ 沒有送出 `rollback`、記「無法執行」;(5) **`back_to_a` 之後中斷、節點已在 A** → 沒有送出 `rollback`;(6) 在 B → 送出的是條件指令(含 `active = B`),不是裸 `rollback`;在 B 但版本 ≠ V2 → 仍回 A 且輸出 `UNEXPECTED VERSION`。
  - **殘留的 V2 hold 旗標**(OTA 後中斷時刻意留下):fault-injection 的 p5 與 `restore_node` 把「旗標存在」當成 FAIL / 拒絕(A v6 u3)→ preflight **P3**(OTA 狀態,不是 BLE 狀態)把任何 fleet 節點上的 `autocommit-hold-commit` 列為殘留並印出內容與安全清除步驟(FAIL);N3 結尾印出安全清除步驟:確認 `batman-slot is-trial` rc 1、tryboot 未 arm、slot A、版本 wsl.9 之後才 `rm` 並讀回。
副作用:02 重開兩次、離網數分鐘;slot B 被重寫為相同位元組;若走 revert 路徑,`/opt/batdata/state/bad-slot` 記 `slot=B version=V2`(E29:只擋同版本再開進 B,下一次任何 commit 會刪;不影響之後 OTA 新版本到 B);slot B 用 p3,02 p3 沒有 `core_freq_min`(E22),wsl.2 沒有 BLE,不影響這次判讀。

## 5. 生命週期矩陣
| 路徑 | 今天 | 之後 | 證明 |
|---|---|---|---|
| 第一次跑(節點沒有工具、沒有 `bt/`) | — | P6 staging + `--version`;失敗 = preflight FAIL | 實跑 |
| 開跑(設定錯) | 長跑後才發現 | preflight FAIL,不跑 suite | N9 |
| 正常結束 | — | 04 rekey + adv-off、02 restore、snoop 刪、canary 過;04 重開一次(§4.6) | 實跑後 `ble-state` 乾淨 |
| harness 中途死掉 / 主機睡眠 / ssh 斷 | — | 每個狀態變更都有 deadman;到期:04 adv-off + restore,有 `irk-exposed` 則重開 04(H-U6);02 restore;標記與 lease 讓下一次 preflight / tier A 在 deadman 到期前 FAIL | N7 |
| 兩個 run 同時 / 操作員手動 session | — | lease 擋第二個 harness(整段,不只指令期間);手動 bluetoothctl 由每輪斷言與 `ble-state` 發現 | 實跑:lease 有效時另一個 RUN_ID 的指令 FAIL |
| 上一次 run 的 deadman 還活著 | — | lease 未到期 / deadman 活著 → preflight P6 FAIL;到期後 deadman 在鎖內執行還原並刪 lease,之後的 run 才拿得到 lease | N7 |
| 節點重開 / 停電 | — | tmpfs 清空:工具、標記、deadman、IRK 都消失(IRK 重新產生) | §4.6 |
| bluetoothd crash / respawn(依賴,`respawn 3600 5 0`) | — | pid 變 → rpa 該次無效 FAIL;配對該輪無效;respawn 時 adapter 仍上電 → kernel 不換 IRK(E27),所以 `rekey` 一律先 power off 並以 RPA 驗證 | 斷言 pid;N11 |
| hci0 初始化失敗(PR-F ❓ 02 暖開 1/4) | — | `ble-privacy-254` 與該節點的 tier B BLE suite 開頭 FAIL(原因寫實際值,不重試不歸因);preflight 不擋,其他 suite 照跑 | — |
| dbus / dropbear restart | — | dropbear = ssh 斷 = 同「harness 中途死掉」;dbus restart = bluetoothd 重連 → pid 可能變 → 同上 | — |
| 前面的 suite 換槽 / 重刷 | — | BLE tier B 排在 section 3(ab-selftest)之前(§6);每個 BLE suite 開頭重驗 P6 的節點前提 | 讀報告順序 |
| 升級 / 降級(受測 build 沒有 BLE) | — | P6 / `ble-privacy-254` FAIL(不是 SKIP) | N3 |
| Pi 3(bcm2710) | — | N/A(SoC 規則);被設為 BLE_PERIPH / BLE_CENTRAL → P6 FAIL | N9 stub |
| 平台 Git Bash / WSL | 兩邊都跑 | 兩邊都能跑;`DV_PY` 規則 §4.8 | 兩邊各跑 preflight |
| CI | 無向量驗證 | `vectors-219` | PR CI log |

## 6. daily-validation 的接線與順序
- 最前面:`fleet_init`(加 BLE 節點)→ preflight。
- tier A:`ble-privacy-254`、`prov-tools-254`(每個 bcm2711 fleet 節點)。
- tier B BLE 區塊收尾(順序固定,A-w2):(1) 抓回 log;(2) 04 與 02 各自跑 `canary`(02 的 IRK 由 02 比對,不離開節點);(3) 04 `rekey`;(4) 02 有本次 boot 的 `irk-exposed` → `batman-slot reboot committed`(H-U7),fleet settle `D`。
- tier B BLE 區塊:每個 suite 開頭斷言節點前提(版本、slot、`hci0`、`batman-sc`、BLE 狀態乾淨),不符 = 該 suite FAIL;放在 section 3(ab-selftest)**之前**,條件 = `FEATURE_MODE=--destructive` 且 DNODE eth0 carrier = 1 且 `BLE_PERIPH == DNODE`(否則 FAIL 寫明原因)。順序 rpa → pair → reboot;`D` 標在 pair(rekey 期間 bluetoothd 停)與 reboot。
- 環境變數:`BLE_PERIPH`(預設 DNODE)、`BLE_CENTRAL`(預設 BENCH)、`DV_BT_TOOLS`、`DV_PY`、`DV_PREFLIGHT`。

## 7. 安全
- **資產**:04 的 IRK(能追蹤 04 的 RPA)、04 的 SC-only 狀態、02 的 IRK、測試主機的 ssh 金鑰、CI 供應鏈。
- **actor**:
  - **BLE 路人**:翻轉段約 1 分鐘 04 不是 SC-only → 可拿到 IRK 與 public 位址;翻轉段是 legacy Just Works,被動監聽者也能推出 04 **與 02** 的 IRK(E36)→ 02 收尾重開(H-U7);收尾 `rekey`(有 kernel 驗證)作廢;harness 死掉時,翻轉段的 deadman 期限 900 s,到期重開 04(H-U6)→ 窗口 ≤ 900 s + 重開時間。rpa 段廣播 non-connectable、名稱每次隨機、deadman 3300 s 內一定撤掉 → 不留長期 beacon。tier B 只在釋出前、人在場時跑。
  - **節點上的非 root 程序**:`bt/` root 0700 擋換檔 / symlink;snoop 0644 但在 0700 目錄;IRK 不進 argv;`reset` 只刪白名單名稱,刪前重驗 `/tmp/lib`、`/tmp/lib/bluetooth` owner / mode / 非 symlink。
  - **被攻陷的 02**:02 本來就是攻擊者角色;拿到的只有翻轉段 04 的 IRK(rekey 作廢)。
  - **供應鏈**:CI 套件全閉包 `--require-hashes`、`setup-python` 釘 SHA;`DV_BT_TOOLS` 固定目錄 + SHA256SUMS(來源是自己的 build 樹,不驗簽 ⚠️,與 `DV_T263_KO` 同級)。
  - **我們自己的錯**:IRK 進 log / PR → `irk` 輸出只進 pipe;`ble-ah.py` 不回印;snoop 不抓回、只抓回過濾後的事件與 Reason 行;`canary` 機制比對所有抓回的 log。
- **攻擊面變化**:新環境變數(§6),只在測試主機;節點端新指令只在 `bt/`、只有 root;tmp-trust allowlist 新增:`scripts/node/ble-*-254.sh` 的 `/var/lib/bluetooth`、`/tmp/lib/bluetooth`(bluetoothd 的 root 0700 儲存區,只讀斷言與 bluetoothd 停止期間的白名單刪除)。
- **失效模式**:preflight fail-closed;讀不到 = FAIL;翻轉段不外洩 = FAIL;deadman 取消失敗 = FAIL。

## 8. 測試(本 PR 的驗收)
- 全套 daily-validation:`AB_MODE=--destructive FEATURE_MODE=--destructive`,MESH = OTS = DESTRUCTIVE = BLE_PERIPH = 04,BENCH = BLE_CENTRAL = 02;preflight 先過;新測項全 PASS。
- §4.10 N1–N11 每個實跑一次(N3 用 held trial);結果寫進 PR body(`NEGCTL:` / `PASS-ON:`)。
- CI `vectors-219` 綠,負對照步驟的 log 看得到點名 `psk_replay` 的 FAIL 行。
- 破壞性副作用與還原(使用者 2026-10-18 規則):04 bluetoothd 停 / 啟多次(BLE 中斷,目前無 BLE 使用者)、04 重開一次(OTS 中斷約 2 分鐘;04 是主機進 mesh 的橋,有乙太網);N3 02 重開兩次;N8 洗掉一個節點的 logread ring(先存);tier B 收尾 02 以 `reboot committed` 重開一次(H-U7,離網約 2 分鐘);02 cache 刪除(只白名單)。

## 9. 殘項(回 #254 / #290)
- #290:ssh 連線預算(全域)、主機端鎖、known-failures 到期、PR 標記 CI、每日排程、P8 的理由、路徑表更正(§1.4)。
- #254:H2 / H3 / H4 的 prov-\* 測項;`peer.py`(H3,契約照 219 §4.1 frame 層、`verify.py` 改成可 import 並以 `MIN_CHECKS` + CI 負對照證明判定沒變);coex(P2);GATT / iPad(P2);SC JW 負對照(P2);H3 時 harness 廣播與 provd 的擁有權交接(§3)。

## 10. 對 `254-stage1-impl.md` 的修改(同一個 PR)
- §10 第 3 點改為:「**PR-H1(harness)**:preflight、CI 向量、BLE 空中測項(`ble-privacy-254`、`ble-rpa-254`、`ble-pair-sc-only-254`、`ble-privacy-reboot-254`)、02 central client、`prov-tools-254`(設計 `254-h1-harness.md`)。各產品 PR 的 prov-\* 測項以 harness PR(H2 → P1、H3 → P2(含 `peer.py` 對手)、H4 → P3)先進 main(H-U2、H-U3)。`prov-coex-254` 移到 P2(H-U4)。」
- §9:RPA 測試的廣播者改為 `btmgmt add-adv`(non-connectable)、時間軸由主機擁有;配對「擋下」改為 04 送出 reason 0x03;`ble-privacy-254` 的 fresh overlay 前提改為直接檢查(§4.3)。

## 11. v1 審查 → v2 對應(歷史;v3 的修正見 §12)
| 發現 | 處理 |
|---|---|
| A-M1 / B-M1 兩個時鐘、取樣、connectable 換 RPA | §4.4:主機時間軸 + uptime 差檢查 + 保護帶、主機觸發取樣 + 2 分鐘桶、non-connectable、隨機名稱、btmon 有連線 = 無效。**B-M1 的「(a) 中途重新註冊必須 FAIL」**:A2 實證 timeout 前重新註冊 RPA 不變,所以這個注入不一定有鑑別力 → N5 照實記錄結果,不宣稱 |
| A-M2 覆蓋率 | §4.4 桶;N2 |
| A-M3 / B-M3 中途死掉、殘留、兩個寫入者 | §3、§4.7 deadman / 鎖 / 標記 / `ble-state`、`rekey`(不必重開);N7 |
| A-M4 privacy off 被拒、解析假 PASS | E7;N1 改 power off 流程;§4.3 只解析 `current settings:` token;N10 |
| A-M5 / B-m12 tier A 相依 | tier A 改用非互動 bluetoothctl(E6),不放工具;tier B 工具固定目錄 + SHA256SUMS + 節點 `--version` |
| A-M6 coex、fresh overlay、舊版負對照 | H-U4;§4.3 說明;H-U5 + N3 |
| A-M7 / B-m8 peer.py | H-U3 延到 H3 |
| A-M8 / B-M4 P7 | §4.1 P7 `logread -l 200` 時間差;N8 |
| B-M2 擋下用代理訊號 | §4.5 四態判定 + N6 |
| B-M5 閘門與順序 | §6:BLE_PERIPH == DNODE、eth 閘門、排在 ab-selftest 前、每 suite 重驗前提、只重開 04 一次 |
| A-m1 證據引錯 | E15 更正 |
| A-m2 / B-m11 ssh 並行、detach、無 timeout | §4.7 |
| A-m3 / A7 btmon -r、連線配對規則 | E12 實測;§4.5 每輪一個 btmon |
| A-m4 / B-m7 reset 範圍 | §3、§4.5 白名單 + 雜湊不變 |
| A-m5 只刪 `bt/` | §3 |
| A-m6 / B-m10 deadman 實作 | §4.7 |
| A-m7 / B-m4 路徑分類、allowlist | §1.4、§7 |
| A-m8 / B-m6 ah selftest、不回印、DV_PY 路徑 | §4.8 |
| A-m9 人工外洩掃描 | §4.7 `canary` |
| A-m10 AF_ALG 模組 | §4.3 斷言 4 |
| A-m11 順序、fleet_init | §4.1、§6 |
| A-m12 / B-m3 CI 負對照、hash 閉包 | §4.2 |
| A-m13 flock 競爭 | §4.9 |
| A-m14 / B-m2 判定只有一份 | P5 呼叫 fault-injection `precheck`;`batman-sc` 判定在 `ble-lib-254.sh` 一份 |
| A-m15 F16 偏離 | 02 不是受測對象,每次取樣與配對都是短的 session;04 tier A 用非互動(不註冊 agent)、tier B 用 btmgmt |
| B-m1 preflight 位置 | §4.1、§6 |
| B-m5 舊版負對照要使用者拍板 | H-U5 |
| B-m9 restart 不換 IRK 的證據、log 行數 | E8;§4.6「≥ 1 行」、ssh 恢復就讀 |
| B-m6 02 的 IRK | §4.5 收尾說明 |

## 12. v2 審查 → v3 對應
| 發現 | 處理 |
|---|---|
| A-R1 / B-M1 btmon 過濾丟掉縮排子行、Reason 失去上下文 | §4.7 `btmon-judge`:以區塊讀、帶方向、SMP reason 與斷線 reason 分開;值欄位不輸出;fixture 用 PR-F btmon(E24) |
| B-M2 rekey 沒驗 kernel 用的 IRK | E27;§4.7 `rekey` 先 power off、以新 IRK 對真實 RPA 做 `ah()`;N11 |
| B-M3 / A-m2 鎖只在單一指令、deadman 規則矛盾 | §4.7 lease + 原子替換的 deadman + `dm-fire` 取鎖並驗 lease;期限依最長路徑 |
| A-R2 preflight 擋產品狀態 | §4.1 P6 只擋 harness / 設定 / 殘留;產品狀態由 suite 判 |
| A-R3 / B-M4 N3 沒有救回路徑 | §4.10 N3 改為 held trial(hold-commit + tryboot 一次性 + 時限自動 revert);E23 前提已查;p5 / uci 前後比對;獨立腳本,不經 preflight |
| A-m1 deadman 實作(檔案、btmon、pgid) | §4.7 腳本放在 `bt/`、還原動作含 btmon 與 snoop、pgid 讀 `/proc`、E25 kill 語法 |
| A-m3 / B-m3 FIFO 是互動模式 | E26;取樣改 `bluetoothctl --timeout 10 scan on`;配對輪仍是互動 session,寫明理由;N2b 擋 cache 假看見 |
| A-m4 / B canary 大小寫與分隔 | §4.7 `canary` |
| A-m5 / B P7 開機與時鐘回跳 | §4.1 P7 |
| A-m6 / B-m2 N5 沒有鑑別力 | N5a / N5b(依原始碼必定 FAIL) |
| A-m7 / B uptime 偏移與單調時鐘 | §4.4 |
| A-m8 P5 source 方式 | §4.1 P5 + stub |
| B-m1 T0 前 RPA 可能已用了一段時間 | §4.4 起點先 `restore` |
| B `sh -s` 的 stdin 衝突 | §4.7 腳本放節點,stdin 留給資料 |
| B 04 p3 證據 | E22 |
| B §3 / §4.5 rekey 範圍不一致 | §4.7 統一:`identity` + 04 儲存區的裝置目錄 |

## 13. v3 審查 → v4 對應
| 發現 | 處理 |
|---|---|
| A-S1 / B-B1 N3 會讓 02 被 commit 在 wsl.2 | E28;§4.10 N3 重寫:旗標寫 payload 版本、不用 `precheck` / `held_trial`、進 trial 先驗 hold 生效否則立刻 `reboot committed`、回 A 一律 explicit partition(E30)、bad-slot 副作用(E29)、前後比對加 `/opt/batdata/state` 與 slot A overlay |
| A-S2 / B-M1 deadman 做不到有驗證的 rekey | H-U6:deadman 遇到 `irk-exposed` 重開 04;§4.7、§5、§7、N7 一致改寫;`ble-recover` |
| B N11 做不出 | E31;N11 改為刪 identity + `kill -9` |
| B dm_arm 中斷會卡住 | §4.7 先 arm 新的、再取消舊的、`dm.new` → `dm` 完成標記 |
| B §7 窗口數字不一致 | §7 改為 900 s / 3300 s,與 §4.7 一致 |
| B `$SECONDS` 不是單調 | §4.4 改用主機 `/proc/uptime` |
| B P6 adv instance 要 bluetoothd | §4.1 P6 |
| B 兩台 lease | §4.7 |
| B / A N3 用 plain reboot、bad-slot | N3 步驟 6、副作用 |
| A-m1 btmon fixture 不是真實輸出 | §4.7 fixture 改為實錄 + 換假值 + `UNPARSED` = 0 |
| A-m2 N2b 沒有鑑別力 | N2b 改為 adv-off 後 5 s / 30 s 取樣 |
| A-m3 lease 邊角、staging 覆蓋 | §4.7:`dm-fire` 重試、`acquire` 的三種情況、`bt/<run_id>/` |
| A-m4 rekey 驗證前 02 reset、MAC 路徑 | §4.7 rekey |
| A-m5 負對照比對原因 | §4.10 |
| A-m6 N3 比對項目 | N3 步驟 1、7 |

## 14. v4 審查 → v5 對應
| 發現 | 處理 |
|---|---|
| B-M1 V2 來源(metadata `version=` 是時間戳) | E32;N3 步驟 1:V2 只取 slot B `/etc/batman-build`,交叉比對 `slot-B.protected`,禁止用 metadata |
| B-M1 後半 / A-n1 已 commit 在 B 的分支 | E33;N3 步驟 4:讀 `autocommit.committed` / `deadline`,已 commit → `rollback` + `reboot committed` |
| A-n2 / B-m1 舊 deadman 在 lease 延長後動作 | §4.7 `dm-fire` 驗 lease 已到期 + pgid == `dm` |
| A-n3 `dm-fire` 等鎖不放棄 | §4.7 10 分鐘上限、持鎖指令 watchdog |
| A-n4 N3 EXIT trap | N3 EXIT trap |
| A-n5 rekey 期間死掉仍重開 | §4.7 明寫 |
| B-m2 fixture 含 02 的金鑰 | §4.7 白名單遮蔽、雙節點 canary、錄完換兩台 IRK、gitleaks |
| B-m3 `bt/<run_id>/` 清理 | §4.7 |
| B-m4 `slot-B.protected` 被刪 | N3 步驟 7 預期差異 |
| B-m5 deadman 重開前記原因 | §4.7 p6 log + `reboot committed ble-dm-254` |

## 15. v5 審查 → v6 對應
| 發現 | 處理 |
|---|---|
| B-M1 EXIT trap 在 OTA 後刪 hold 旗標 | N3 EXIT trap 依階段:OTA 後絕不刪、等新 boot 再走步驟 4;stub 負對照 |
| A-T1 `mv` 前中斷,兩個 deadman 都不動作 | `dm-fire` 認 `dm` 或 `dm.new`;deadman 期限 ≥ lease;N7b |
| B-m1 步驟 4 讀與動作之間的 TOCTOU | 一律先 `rollback` 再 `reboot committed` |
| B-m2 / A-t2 刪 02 `identity` 與 §3 衝突、無驗證 | fixture 錄完改為重開 02 |
| B-m3 preflight 刪目錄與信任說明 | §4.1 信任、§4.7 刪除條件加「沒有活著的 deadman」 |
| B-m4 鎖逾時直接還原的範圍 | 只殺同 run_id 的群組,先記 log |
| B-m5 / A-t3 revert 時限低估 | 步驟 1 讀 `autocommit.timeout`;時限 = `max(T, 啟動 + 300)` + 600 + 180 |
| A-t1 `UNPARSED` = 0 做不到 | 已知忽略欄位清單 |
| A-t4 p6 log 的擁有者 / symlink / 清理 | §4.7 |

## 16. v6 審查 → v7 對應
| 發現 | 處理 |
|---|---|
| B-B1 在 slot A 上呼叫 rollback(正常結束、tryboot 落 A、步驟 6 後中斷) | E34;`back_to_a` 節點端條件指令(active = B 且版本 == V2);`PHASE` 四段;stub 案例 (3)(4)(5)(6) |
| B-m1 覆寫 `dm.new` 留下孤兒 | `dm_arm` 先取消既有 `dm.new` |
| B-m2 revert 時限以 wsl.2 為準、從 OTA 起算的總數 | E35;N3 步驟 6:≤ 2280 s |
| B-m3 EXIT trap 在正常結束也觸發 | 明寫 + stub 案例 (3) |
| A-u1 02 的 IRK 可被監聽推出 | E36;H-U7 收尾重開 02;§4.5、§7 更正 |
| A-u2 02 重開用 `reboot committed`、列入副作用 | fixture 段、§6、§8 |
| A-u3 殘留 V2 hold 旗標看不到 | preflight P6 列為殘留並 FAIL;N3 結尾的安全清除步驟 |

## 17. v7 審查 → v8 對應(MINOR,兩位都表示不需再審)
| 發現 | 處理 |
|---|---|
| A-w1 先取消 `dm.new` 會留下沒有 deadman 的窗口 | §4.7 先記 pgid、先 arm 新的、再取消;N7b 變體 |
| A-w2 一般 run 的 canary 也比對 02、順序在 02 重開前 | §6 收尾順序 |
| A-w3 tryboot 落在 A 時印出 slot B 狀態 | §4.10 `PHASE` |
| B-m1 harness 死在翻轉後,02 的 IRK 不作廢 | §4.7 02 的 `irk-exposed` + deadman 重開 02;N7 |
| B-m2 `back_to_a` 的版本條件反而有害 | 只以 `active = B` 為條件,版本不符照樣回 A 並輸出 `UNEXPECTED VERSION`;stub 6 |
| B-m3 hold 旗標屬 OTA 狀態 | 檢查移到 P3 |

## 18. 實作時查到的事實(2026-10-20,不改設計,只補證據)
| # | 事實 | 證據 / 處理 |
|---|---|---|
| E37 | 非互動 `bluetoothctl --timeout N scan on`:session 開頭**不**列出 cache 裡的裝置;已知裝置再被收到時只出現 `[CHG] Device <addr> RSSI:` | 02 實測兩次掃描;`sample` 以 `[NEW] … <name>` 或本 session 的 RSSI 行為看見,N2b 驗證 |
| E38 | 節點上沒有 `stat`、`od`;busybox `flock` 沒有 `-w` | 04 實測;改用 `ls -ldn`、`hexdump`、`flock -n` 有上限重試 |
| E39 | 非互動 `bluetoothctl mgmt.advinfo` 偶發 segfault、沒有輸出(04 4/30、02 1/31);`mgmt.info` 0/60;只有 1 個 instance 時輸出是單數 `1 item`(`client/mgmt.c:4420`);`btmgmt --version` 印 `btmgmt: 5.72` | 讀取最多 3 次;regex 用 `item`;版本字串去前綴 |
| E40 | `verify.py` 在 PSK 被竄改時於 `noise_check` 拋出未捕捉的例外(crash)而不是 FAIL | CI 負對照抓到;`noise_check` 改為記一條 FAIL 並返回,正常通過時仍是 195 項 |
| E41 | preflight 第一次實跑就抓到我準備用的 runner 設定 `IPERF_PEER == MESH_NODE`(`mesh-tput-iperf` 會 SKIP);PR-F 第一次全套用 MESH=02 / IPERF=04,不受影響 | `dv-preflight.sh` P4 |
