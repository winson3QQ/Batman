# 審查 B(第 5 輪):`254-h23-harness.md` v5(89cb901;2026-10-28,唯讀;未碰 02 / 04)

先逐條核對 v4 A / B 全部發現對 v5 文字與原始碼(Batman-h23 工作樹 89cb901;firmware-2710 工作樹:bluez-5.72、`build-board.sh`、`stamp-batman-build.sh`、`golang-package.mk`、`toplevel.mk`),再重讀整份 v5。本輪實跑:`bash scripts/check-tmp-trust.sh`(現樹 0 untrusted、rc 0)、`git ls-files -- 'scripts/*.sh'`(含 12 個 `scripts/dv/`)、`gh release view v1.5.11` + `SHA256SUMS`、`file` 於 `dbus-send`。

## 摘要

v4 的 5 MAJOR / 29 MINOR 全部有處置,而且處置對得上原始碼:底 rootfs 改 Batman v1.5.11 payload(資產真的在、sha 可釘);tmp-trust 的 regex 與條目在現樹上推演成立(只有 `prov-lib-254.sh:20` 與 `chain1-254.sh:112,315` 失去第 13 行的切除,其餘 `/tmp/run/batman-dv` 命中都接 `/`、`;`、`"`、空白或行尾);`GATT_ENCRYPT_CTRL` 白箱在 BlueZ 5.72 裡成立(server 回 0x0F → 02 的 ATT channel `sec_level` 預設 AUTO 自動升級安全 → SMP Pairing Request → 04 無 agent 拒 → 重試一次 → `org.bluez.Error.NotPermitted "Not paired"`);(9) 的 dry-run 在真 trial 內會印 `DRYRUN decision: COMMIT`(hold 在 `autocommit.ctl.dry` 看不到、`$RUN` 單例與 `autocommit.wd` 都不撞);`provd.env` 由 `prov_test` 專用 init 讀的機制與現有 Makefile 安裝型式一致。

剩 1 個會讓整個 killpoint 家族失效而 CI 仍綠的規格錯誤(M1),其餘都是 PR 時會現形的紅燈或措辭。

BLOCKER 0、MAJOR 1、MINOR 12。**APPROVE-WITH-CHANGES**。

---

## v4 發現 → v5 核對

| v4 | 解了? | 證據 |
|---|---|---|
| B-M1 沙箱底來源 | **是** | §4.4.1 / D-H11 / F18;`gh release view v1.5.11`:非 draft、非 prerelease,資產 `…-ekh-bcm2711-ab-payload.tar.gz` 122 441 671 B;`SHA256SUMS`(520 B,4 行)第 2 行 `73300d1b6cc3d4dc1491565d810df751945b782b7dda9fb4d216bc71ec8d7601  batman-1.5.11-rel.1+6a049f2.fw7049fd8-ekh-bcm2711-ab-payload.tar.gz`(bcm2710 payload 也在,103 748 222 B) |
| B-M2 tmp-trust / chain1 | **是**(m2、m3 措辭) | F23 / F30;§2.2 規則推演:現樹 `check-tmp-trust.sh` 0 untrusted;`git grep /tmp/run/batman-dv` 全樹只有 `prov-lib-254.sh:20`(`batman-dvpc.`)與 `chain1-254.sh:112,315`(`batman-dvpc/`)接 a-z;其餘 60 餘處接 `/` `;` `"` 空白或行尾 → 新 regex `([^-a-z]|$)` 仍切;`batman-dvpc-evil` 案例:`scripts/*` glob 在 `case` 裡跨 `/`,新 regex 不切 `-dvp…`,chain1 / prov-lib 專屬條目 glob 不含 `x.sh` → 留下 `/tmp/` → UNTRUSTED ✅;`mkdir -p -m 0700 /tmp/run/batman-dv;` 類的行:切掉 `/tmp/run/batman-dv;` 後 `mkdir +-p +/tmp/` 也不再命中 ✅ |
| B-M3 GATT Flags | **是** | F43;§6.3 行為判定 + 白箱;`gatt-database.c:1760-1762` `encrypt-read` → `BT_ATT_PERM_READ_ENCRYPT`;`gatt-server.c:411-461` `check_permissions`:`PERM_ENCRYPT && security < MEDIUM` → `BT_ATT_ERROR_INSUFFICIENT_ENCRYPTION`(0x0F);`att.c:1209-1215` LE channel 的 `sec_level` 留 0 = `BT_ATT_SECURITY_AUTO`(`att-types.h:22`),`att.c:745-770,796` 收到 0x0F 就 `bt_att_chan_set_security(MEDIUM)` + 重送一次(`op->retry`);04 bluetoothd 無 agent → `device.c:6664-6668` `No agent available` → 配對拒;client 端 `src/gatt-client.c:287-290` 把 0x05 / 0x0F 映成 `btd_error_not_permitted(msg, "Not paired")` → bluetoothctl 印 `org.bluez.Error.NotPermitted`。btmon 期望序列:SMP Pairing Request(02 發起)→ Pairing Failed → ATT Error 0x0F。m12 補前置 |
| B-m1 / A-m7 sudo PATH、grep rc | 是(m7) | §2.2 CI;`ci.yml:74` 現況仍非 root 無 `-tags` ✅ |
| B-m2 F28 引用 | 是 | §6.3 `ble-rpa` 寫 stage1 F28 |
| B-m3 (8) 臂 C 停 helper | 是 | §6.2 (8) 臂 C「同臂 B 的移除程序」;`health.go:151` `Committed()` trial 為假 ✅ |
| B-m4 unsquashfs stdin | 是 | F44;§4.2 `tar -xzf … root.squashfs` → `unsquashfs -cat <file>`;`build-board.sh:162` 同型 ✅ |
| B-m5 n 公式 | 是 | §6.3 n = 30 固定、上限 200 |
| B-m6 provd.env init 機制 | 是(m6) | §4.1.2 (4):`BATMAN_PROV_TEST=1` 安裝 `batman-provd.init.test`、gate grep `BATMAN_PROVD_TEST_INIT_7f3a`;與 `feed/batman-prov/Makefile` 現有 `INSTALL_BIN ./files/batman-provhelper.init` 的安裝型式一致;`BATMAN_PROV_TEST` 以環境變數進 package Makefile:`toplevel.mk` 只 `unexport` P4* / QUILT* / CROSS_COMPILE / ARCH / LPATH / TAR_OPTIONS,不擋它 ✅ |
| B-m7 dbus 471 正向 | 是 | F16「P2 後亦然」;§6.3 正向 = `Properties.Get`;stage1 `:308` policy 無 `Introspectable` ✅ |
| B-m8 (10) 容器臂 | 是 | §6.2 (10)(c) 指令 + characterization 標記 |
| B-m9 / A-m12 re-stage | 是 | §3 lease 列「每次 `pr_find` 先重新 stage」;`ble_stage`(`scripts/lib/ble-254.sh:55`)拒絕已存在的 run dir → 只在重開後才能同 run id 重 stage,與「`pr_find` = 重開後」一致 ✅ |
| B-m10 / A-m10 chan 取樣 | 是 | §4.2「T+120 s 起連續 3 次(間隔 10 s)皆 ≠ p5 且 `batctl n` 空」;chanfix `:39` 40×2 s + `:43-55` 6×8 s ✅ |
| B-m11 §3 `ble-ok` | 是 | §3 列 |
| B-m12 / A-m9 §5 缺列 | 是 | §5「trial 內 kernel panic」「harness 死於 `prov-netjoin-fleet` 中」 |
| B-m13 第 99 行 regex | 是 | §2.2 `([^-a-z]|$)`;Go 只有 `main.go:40`(接 `"`)與 `sock.go:2`(註解)✅ |
| B-m14 hold 值 / DISCARDED | 是 | §4.2;`batman-autocommit:274,287-289` ✅(DISCARDED 另寫 `$RUNDIR/autocommit.hold-discarded`,harness 可直接 poll 該檔) |
| B-m15 F15 / lint / F23 | 是 | F15 已引 `init.d/boot:7-17`;§4.2 lint 不套板 patch;F23 `no "tool placement"` |
| A-M1 (9) commit mutant 槽 | **是**(m1 副作用) | §6.2 (9) dry-run;§7.2 / §7.3 無 (9) 列;`batman-autocommit:50` FORCE_TRIAL、`:323` rc=0、`:339` DRY 跳過 `$RUN` 單例、`:376-384` DRY 不讀 / 不寫共用 deadline、`:432` DRY watchdog 在 `:199` `mkdir autocommit.wd` 失敗即退(真 watchdog 已持有)、`:34,:41,:511` hold 看 `autocommit.ctl.dry` → 不 HELD、`:529` 印 `DRYRUN decision: COMMIT slot B (services 3x10s, mesh samples n)` ✅ |
| A-M2 DEFER_MAX | 是 | F42;§4.3 步驟 1;§4.7 P9 `autocommit.timeout`;`:35,:223-231,:380-381` ✅ |
| A-m1 helper sha 規則 | 是(m10) | §4.2 成本段 10 份;§4.7 |
| A-m2 deadman 清 upper 副本 | 是 | §3 upper-helper 列 |
| A-m3 norebuild nil | 是 | F41;`boot.go:180,185` ✅(`ovRec == nil` 落到 `:185` 解參考) |
| A-m4 txn-2 (a) INVALID、txn-1 ≥ 120 s | 是 | §6.2;`main.go:443,481-494` ✅ |
| A-m5 txn-4 位置 | 是 | §6.2「`RemoveTxn` 之後、`Save` 之前」= `node.go:1118-1120` ✅ |
| A-m6 normalise 前置 / no-op | 是 | §4.3 |
| A-m8 範圍 | 是 | §1.2 claim-lock §11.4、`prov-unit-bcm2710`;§9 |
| A-m11 init mutant enable | 是 | §4.1.3 `etc/rc.d/S??wbox-*` |
| A-m13 02 boot_id > 3600 s | 是 | §4.3 步驟 4 WARN |
| A-m14 行號 / 命名 / (6) / (10) | **部分**(m8) | F13 `boot.go:120` ✅;§4.1.1 標題已改;(6) 前置「04 = member」✅;(10) 容器臂標 characterization ✅;**§2.1 表第一列仍叫 `--killpoint`** |

---

## MAJOR

### M1. §2.1:`killpoint_test.go` 是 Go 的測試檔,永遠不進二進位 → `prov_test` helper 沒有 killpoint,而 CI 仍綠
- **情境**:PR-P1b 照 §2.1 寫 `cmd/batman-provhelper/killpoint_test.go`(`//go:build prov_test`)+ `killpoint_release.go`。`go build` / `go install` 一律排除 `*_test.go`。兩種結果都壞:(a) `killpoint_release.go` 帶 `//go:build !prov_test` → `go install -tags prov_test` 編不過(`armKillpoint` undefined)→ `test` 變體 build 失敗;(b) `killpoint_release.go` 無 tag → release 版的 `armKillpoint()` 回 "" 也進了 `prov_test` 二進位 → 17 個變體全部 build 成功、`--version` 第 2 行標記在、gate 過、`go version -m` 的 `-tags prov_test` 在,但 helper 從不讀 killpoint 檔 → `prov-powerloss-254-txn{1..5}`、`prov-claim-254` killpoint 段、`prov-lock-failsecure-254` 全在真機才以「無 `armed` 行」FAIL。兩種情況下 §4.1.1 的 Go 單元(`go test -tags prov_test`)都 **PASS**(測試二進位本來就含 `_test.go`)。
- **證據**:§2.1 表第一列;Go 規格「Files whose names end in `_test.go` are only compiled by `go test`」;§4.1.3 gate 的三條(`-tags`、`grep -c` 標記、`WBOX-`)都看不到 `armKillpoint` 是否存在。
- **修**:實作檔改名 `killpoint_provtest.go`(`//go:build prov_test`)/ `killpoint_release.go`(`//go:build !prov_test`);單元測試另放 `killpoint_test.go`(兩 tag 都編)。gate 有 name = `test` 時加一條:helper `strings | grep -c 'killpoint .*: armed'` ≥ 1(release 版 = 0,與 §4.1.1「release log 無 `killpoint`」同一字串)。E-H2 驗收也加這條。

---

## MINOR

### m1. (9) dry-run 在真 trial 內的共用寫入與時間預算
`batman-autocommit` DRY 模式沒有隔離這些:`:515` 每輪 `echo "$why" > $RUNDIR/autocommit.why`(與真 main 兩個寫者;`release --wait` `:172,:176` 讀它);`:426` `otalog_k AC START …`、`:505` `otalog AC UNHEALTHY first_why=`(`otatrace.sh` 無 DRY 分支,寫進 p6 `/opt/batdata/log/ota-trace.log`,本 boot 會多一組 AC START);`:521-523` pre-commit canary 失敗時 `rm -f $CANARY_LATCH`(共用,真 main 會重跑 canary);`:139-140` canary 舊 tag prune。都不致命(hold 擋 commit、`back_to_a` 收尾),但 §3「一資源一寫者」在這裡破例,§7.2 要列。另:決定 COMMIT 要 NEED=3 輪 × 10 s + pre-commit canary(`docker run`)(+ NEED_MESH=1 時 JOIN_NEED=3 個樣本),`<uptime+60>` 很緊;chain1 8.7 是背景跑 + 90 s kill。建議 `+120`、同 chain1 的背景 + kill 寫法、斷言字串寫全(`:529`)。

### m2. tmp-trust 新條目的 glob 漏了三個會變紅的檔
`scripts/dv/prov-*-254.sh` 不匹配 `scripts/node/…`:(a) `scripts/node/prov-base-254.sh` 的 prov deadman `rm -rf /tmp/run/batman-prov-test`(§3);(b) `scripts/dv-preflight.sh` 的 P9「`/tmp/run/batman-prov-test/` 存在 → FAIL」與「provd release 無測試 socket 目錄」(`scripts/*.sh` 在掃描範圍);(c) `scripts/node/prov-sec-254.sh` 的 `ln -s /tmp/x /tmp/run/batman-prov`——`/tmp/x` 自己就是 `PAT` 命中,需要像 `tmp-trust-280.sh`(allowlist `:53`,`.`)那樣的攻擊模擬條目。每缺一條 = harness PR 的 `tmp-trust` 紅燈(feedback:開 PR 後要看 CI)。

### m3. §2.2 / §4.5「chain1 改走 `prov-lib-254.sh` 的 per-run `$PCD`」的措辭
`chain1-254.sh` 沒有、也不能 source `prov-lib-254.sh`(prov-lib 在 source 時就 `exec > >(tee)`、設 `RUN=`、要求 `DV_PROV_TOOLS` / `DV_CRYPTPROBE`;chain1 有自己的 `pc` `:100-115`、`FIP` / `FRESHO`、`$RUN`)。寫成:chain1 自己定 `PCD=/tmp/run/batman-dvpc.$RUN`,`:315` 改 `mkdir -m 0711 $PCD`(無 `-p`;每 boot 只上傳一次,tmpfs 重開即清,所以不撞),`:112` 用 `$PCD`;§2.2 的 chain1 條目因此是必要的(它保留自己的字面值)。另:文件表格裡的 `\|` 是 markdown 跳脫,allowlist 要寫 `|`。

### m4. `docs/validation/ble-ipad.md` 不存在
§6.3「iPad GATT 回歸 ⚠️ 手動:`docs/validation/ble-ipad.md`」與 §1.2「`docs/validation` 的 P-U10 文字(另 PR)」:`git ls-files | grep validation` 只有 `docs/design/268-validation-harness.md`、`scripts/daily-validation.sh`、`scripts/validation-known-failures.txt`、`scripts/test-dv-preflight.sh`。本 PR 建它,或寫明它住哪(Batman-P?)。

### m5. `scripts/dv-dbus-tools.sh` 的「ELF magic 斷言」要加 e_machine
`build_dir/target-aarch64_cortex-a72_musl/dbus-1.14.10/tools/.libs/dbus-send` = ELF aarch64、動態連結 musl、77 424 B(✅ F16);但同名檔也在 `…cortex-a53_musl/…`,且 OpenWrt 的 `tools/` 慣例是 host 工具。照 `scripts/lib/ble-254.sh:44-45` 同時斷言 magic `7f454c46` 與 e_machine `b700`,並寫死 a72 路徑。

### m6. `set-provd-env` 之後要 restart provd
§4.8.3「讀者 provd init … 以 `procd_set_param env` 傳」= 只在 start 讀。§4.5 的 `set-provd-env` 契約補「寫 → restart provd → 斷言 provd 本次 pid 的 env」;`provd.env` 在 `/tmp/run/batman-prov-test/` 內,`unbind-all` / deadman 的 `rm -rf` 已涵蓋 ✅。

### m7. CI root `go test` 的 GOCACHE 歸屬
`sudo -E env PATH=…` 保留 `HOME=/home/runner` → `~/.cache/go-build` 之後是 root 的檔;同 job 內其後任何非 root `go` 步驟會 EACCES。把 root 步驟放該 job 最後,或加 `GOCACHE=$(mktemp -d)`。`grep -c -- '--- SKIP'` 要對同一次 `go test -v` 的存檔輸出做,不是再跑一次。

### m8. §2.1 表第一列仍叫 `--killpoint`
§4.1.1 已改「killpoint 檔(沒有 CLI 旗標)」;表列同改(A-m14 殘餘)。

### m9. `peer-vs-provd`(§4.8.3,H3)在 amd64 runner 跑真 `realSys` helper 的前提沒列
helper 要 `/tmp/run/batman`(節點上 procd 建;runner 要先 `mkdir -m 0700`)、`boot.Run` 的 p5 路徑(`/dev/mmcblk0p5` 不在 → case 7 新卡路徑)、`/etc/batman-prov/`、`/opt/batdata/state`。⚠️ 乙部範圍;§8 步驟 6 說與 P2 設計一起,那就在 §4.8.3 註明「stub / 目錄清單在 P2 設計定」。

### m10. `helper-flap` 是 helper 程式碼 mutant 卻用 release tag
它的 helper sha ≠ release、但沒有 `BATMAN_PROV_TEST_BUILD_7f3a` 標記 → P9「helper 標記 ≠ 0 → FAIL」抓不到流落的 `helper-flap` helper,只剩 `.protected` / `batman-build` 含 wbox 那條。可接受(committed 槽檢查仍擋),但 §4.2 tag 規則寫「改到 helper Go 碼的變體一律 `prov_test`」更單純(`lint-wbox` 也好驗:patch 碰 `feed/batman-prov/src/` → 必 `prov_test`)。

### m11. `prov-gatt-254` 白箱的判定字串寫全
`org.bluez.Error.NotPermitted` 的訊息是 `Not paired`(`src/gatt-client.c:290`);btmon 序列是 SMP Pairing Request(02 發)→ Pairing Failed → ATT Error Response 0x0F(02 的 ATT 重試一次後才回 D-Bus 錯,`att.c:796-810`)。「btmon 出現 SMP 請求」改為「SMP Pairing Request + Pairing Failed,無 LE Start Encryption」。

### m12. `prov-gatt-254` 白箱的前置:04 不得掛 agent
`prov-sec-bond-254` 在 04「掛 agent(白箱常駐)」;若順序在 `prov-gatt-254` 之前且 agent 未收,SC Just Works 會過 → CTRL 讀成功 → 白箱變「無效」而非 FAIL。`prov-gatt-254` 前置或 P9 加「04 無 agent(`AgentManager1` 無註冊 / provd 停止模式的 agent 已收)」,或固定 `prov-gatt` 排在 `prov-sec-bond` 之前。

---

## 其他核對(非發現)

| 項目 | 結果 | 證據 |
|---|---|---|
| 現樹 tmp-trust | ✅ 0 untrusted | `bash scripts/check-tmp-trust.sh` rc 0 |
| `scripts/*.sh` pathspec 含 `scripts/dv/` | ✅ 12 檔 | `git ls-files -- 'scripts/*.sh'` |
| rundir 名稱表 | ✅ | `rundir-paths.txt:11-17,87,99`:`autocommit.{deadline,start,why,ctl,ctl.dry,hold-discarded,ble-warned}`、`batman-prov.health` 都在 → harness 以 `$R/…` 引用不觸發 N3 |
| `GO_PKG_TAGS` → `-tags` | ✅ | `golang-package.mk:262` |
| stamp DIRTY 於 feeds/batman 改動 | ✅ | `stamp-batman-build.sh:44` |
| gate 位置 `$WR/r` | ✅ | `build-board.sh:168-173` |
| `health.go:138` 固定 `adv_registered_once=0` → WARN 必印 | ✅ | `batman-autocommit:496-499` |
| `boot.go:115-120` txn 分支不看 gen;`:180-190` | ✅ | F41 |
| `node.go:1098-1123` 五個 killpoint 位置 | ✅ | txn-1 `:1106` 後、txn-2 `:1110` 後、txn-3 `commitTxn` 內 rename 前、txn-4 `:1118` 後、txn-5 `:1120` 後 |
| `EBusy 7`、`ESchema 20`、`ELockIncomplete 23` | ✅ | `node.go:32-47` |
| `provclient` 降權 471 + dumpable 0 | ✅ | `main.go:410-431` |
| `ble-lib-254.sh` `dm_arm` 第 3 參數 = 節點檔;`cmd_dm_fire` 不重排 | ✅ | `:117-133,:212-226` |
| `ble_stage` 拒絕已存在 run dir | ✅ | `scripts/lib/ble-254.sh:55` |
| 219 §4.1 `CTRL` / `STATUS` Read 不加密;§8 3 次斷線 | ✅ | `219-protocol.md:139,379` |
| `prov-base-254.sh` `STATEFILES` 含 `ble-ok`、`bad-slot`、`ota-armed.mesh`、hold 旗標 | ✅ | `:29` |
| `_ab_arm_mesh` caller / `lastjoined` | ✅ | `platform-ab.sh:103-117` |
| chain1 8.7 的 dry-run 寫法(背景 + 90 s kill) | ✅ 可沿用 | `chain1-254.sh:347` |
| 不可驗(未上機 / 未實測) | ⚠️ | F1、F2、F6、F17、F21、F28、F32、E-H1–E-H7、`bleak` WinRT 合併、Windows 主機藍牙 |

## 裁決

**APPROVE-WITH-CHANGES**(BLOCKER 0 / MAJOR 1 / MINOR 12)。M1 是給 PR-P1b 的規格本身會把整個 killpoint 接縫做成 no-op 而 CI 不會察覺,改一個檔名加一條 gate 即可;m1–m3、m7 是 PR 開出來就會紅或留殘骸的細節;其餘措辭。v4 的全部發現都已核實處置。
