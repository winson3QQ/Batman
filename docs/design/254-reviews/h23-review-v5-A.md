# Review A(第 5 輪):`254-h23-harness.md` v5(89cb901;2026-10-28,唯讀;未碰 02 / 04)

範圍:逐條核對 v4 A(M1–M2、m1–m14)與 v4 B(M1–M3、m1–m15)在 v5 的處置,對設計文與原始碼(Batman-h23 工作樹 89cb901;firmware-2710 工作樹含 bluez-5.72 build_dir、`package/base-files`);再讀整份 v5 找修法互相打架或殘留矛盾。另以 `gh`(Windows)唯讀查 release 資產。

## 摘要

v4 的 5 個 MAJOR 全部核實解決,且修法與原始碼一致:
- A-M1:(9) 改 dry-run。核對 `batman-autocommit:53` `CTL=$RUNDIR/autocommit.ctl`,**`DRY=1` 時 `CTL=$RUNDIR/autocommit.ctl.dry`** → dry-run 的 `held_commit()`(`:60`)看不到真 main 的 hold 標記;p6 flag 已被真 main 消費(`:291`),所以 `:270` 的 hold 區塊也不進;`AUTOCOMMIT_FORCE_TRIAL` → `:69,:323`;`AUTOCOMMIT_TIMEOUT` → `:382` 並把 `MIN_WINDOW=0`;dry 的 watchdog 在 `mkdir $RUNDIR/autocommit.wd || exit 0`(`:202` 後)被真 watchdog 擋掉;COMMIT 分支 `:529` 印字串並 kill 自己的 wd。`payload-274.sh:78`、`tmp-trust-280.sh:71` 已有同招先例。成立。
- A-M2:`DEFER_MAX=600`(`:35`)、`AUTOCOMMIT_DEFER_MAX` 只在 `DRY=1`(`:48`)、`revert deferred:` 行(`:228`)、deadline 檔 `:384`、p6 `autocommit.timeout` `:380`;hold-commit 不擋 revert(`held()` `:94-106` 只看 `/tmp/batman-autocommit.hold` op flag、`$HOLDC`、p6 `autocommit-hold-once`,watchdog `:202,:234` 只呼叫 `held()`)。§4.3 步驟 1 的上限與 renew 規則成立。
- B-M1:`gh release list -R winson3QQ/Batman` → v1.5.11 Latest,資產 `batman-1.5.11-rel.1+6a049f2.fw7049fd8-ekh-bcm2711-ab-payload.tar.gz` + `SHA256SUMS`(另有 bcm2710 payload / 兩個 img.gz);`gh release view 1.5.14-wsl.4` → `release not found`;firmware repo 只有 Draft `fw-build-108-final`。F18 / §4.4.1 / D-H11 與現況一致。
- B-M2:`chain1-254.sh:112` `/tmp/run/batman-dvpc/provclient`、`:315` `mkdir -p -m 0711 /tmp/run/batman-dvpc` 仍在(本 PR 要改);`prov-lib-254.sh:20` `PCD=/tmp/run/batman-dvpc.$RUN`、`:92` `mkdir -m 0711 $PCD … || no "tool placement"`;allowlist `:13` 無邊界;`check-tmp-trust.sh:23` PAT 含 `mkdir +-p +/tmp/`、`:55` `sed s///g`;`test-tmp-trust.sh:18` 已有 clean-tree 案例。掃 `scripts/` 裡所有 `/tmp/run/batman-dv` 的後接字元:除 `batman-dvpc` 三處外全是 `/`、`;`、`"`、空白、`|` → 收緊為 `([^-a-z]|$)` 只會打到 dvpc,新條目 `batman-dvpc\.` 對 prov-lib 與改後 chain1 都能切。Go 側 `main.go:40` 後接 `"`、`sock.go:2` 後接 `/` → 第 99 行同形收緊不傷既有。成立。
- B-M3:`build_dir/target-aarch64_cortex-a72_musl/bluez-5.72/src/gatt-client.c:814-830` `chrc_props[]` / `chrc_ext_props[]` 只有 8 + 2 個字串;`gatt-database.c:1760-1833` 才有 `encrypt-read` / `encrypt-authenticated-*`。§6.3 改行為判定 + `GATT_ENCRYPT_CTRL` 白箱(§4.1.2 (4)、§4.8.3、§10 第 3 點)成立。

29 個 MINOR 中 25 個完全收掉;4 個只收了一半(文字沒改到位,不影響機制):A-m1(§5 還寫 helper 17 份)、A-m10(§6.2 (7) 還是單次取樣措辭)、A-m14(F13 `:119`、F7 `:166`、F11 `:107-141` 沒改;§0 / §2.1 還叫 `--killpoint`)、B-m14(hold 值「整行值」有歧義;DISCARDED 後「立即 back_to_a」在 NEED_MESH=0 / 健康 mutant 上追不上 30 s commit)。新發現 2 個 MINOR(CI pipe 吞掉 `go test` 退出碼;(9) dry-run 與真 main 共用 `autocommit.why` / `ble-warned` latch 要寫明)。

**BLOCKER 0 / MAJOR 0 / MINOR 6 → APPROVE-WITH-CHANGES**(全部是文字修正,可與實作 PR 一起收;不需再一輪整份審查)。

---

## v4 發現 → v5 核對

| v4 | 解? | 證據 / 說明 |
|---|---|---|
| A-M1 (9) commit mutant 槽 | **yes** | §6.2 (9) dry-run;§7.2 / §7.3 的 (9) 列已刪;§1.4「不會 commit mutant 槽」現在成立。原始碼:`batman-autocommit:53`(dry CTL 分開)、`:69,:323`(FORCE_TRIAL)、`:382`(TIMEOUT + MIN_WINDOW=0)、`:529`。見 m5 的共用檔註記 |
| A-M2 DEFER_MAX | **yes** | F42 行號逐一對上(`:27,35,48,69,162,194,228,240,270,323,380,384,529`);§4.3 步驟 1「deadline + 600 + 120,不寫死」+ `revert deferred` → `+600`;§4.7 印 `autocommit.timeout`;§7.3「+ ≤ 600 s」 |
| A-m1 helper sha 規則 | **partial** | §4.2 成本段 + §4.7「10 份」✅;**§5 install 列仍寫「`prov-test` helper 17」**;§2.2 `dv-prov-tools.sh`「從每個 `-wbox` payload 抽 helper」= 17 份(與 10 份規則不一致)→ m1 |
| A-m2 deadman 清 upper 副本 | yes | §3 A 槽 upper 列:sha ≠ `/rom/usr/bin/batman-provhelper` → `rm` + restart |
| A-m3 `helper-norebuild` nil | yes | F41 + §4.2 表「`ovRec == nil` 時回 `unknown(norebuild)`」;`boot.go:180-185` 確認 `case ovRec.Generation > …` 會 nil 解參考 |
| A-m4 txn-2 (a) INVALID / txn-1 ≥ 120 s | yes | §6.2 txn-1「≥ 120 s 後」;txn-2 (a)「≤ 120 s 內先斷言 `.txn` 在且無 restored 行 → 否則 INVALID 重跑一次」;`main.go:481-495` `restoreWireless` sleep 120 s 後才 `RemoveTxn` |
| A-m5 txn-4 位置 | yes | §6.2「`RemoveTxn` 之後、`Save` 之前」;`node.go` `commitTxn` → `RemoveTxn` → `Save` 順序對上 |
| A-m6 normalise 前置 / no-op | yes | §4.3 `pr_normalise`:A committed V → no-op;B 路徑加「02 在 `batctl n`」 |
| A-m7 / B-m1 sudo PATH / grep rc | yes(→ m4) | §2.2 `sudo -E env PATH="$PATH" …` + `[ "$(… \| grep -c … \|\| true)" = 0 ]`;但 pipe 會吞 `go test` 退出碼 → m4 |
| A-m8 範圍 | yes | §1.2 列 claim-lock §11.4 真機與 `prov-unit-bcm2710` smoke 不做 + 理由;§9 |
| A-m9 / B-m12 §5 缺列 | yes | §5「harness 死於 `prov-netjoin-fleet` 中」、「trial 內 kernel panic / 硬重開」兩列;§4.3 步驟 1 以 boot-reasons 判 INVALID |
| A-m10 / B-m10 chan 取樣 | **partial** | §4.2「T+120 s 起連續 3 次(間隔 10 s)皆 ≠ p5 且 `batctl n` 空」✅、≤ 13 次 reload ✅;**§6.2 (7) 仍寫「120 s 內頻道 ≠ p5 且 `batctl n` 空」**(單次語意;雖註「§4.2」)→ m2 |
| A-m11 init mutant enable | yes | §4.1.3「`etc/rc.d/S??wbox-*` 存在」;§4.2 `chan`「image 內要有 `etc/rc.d/S99wbox-chan`」 |
| A-m12 / B-m9 re-stage | yes | §3 lease 列「每次 `pr_find` 先重新 stage `ble-lib-254.sh` + `prov-base-254.sh` 到 `$DVD/<run>/`」;`ble-lib-254.sh:121` `setsid sh "$3" dm-fire` 確需節點上的檔 |
| A-m13 02 boot_id > 3600 s | yes | §4.3 步驟 4「02 重開但回 `batctl n` 且 A committed → WARN」;`joinwatch:37` `t_reboot 3600`、`chain1-254.sh:362` warn 同款 |
| A-m14 行號 / 命名 / (6) 前置 / (10) 容器臂 | **partial** | (6) 前置「04 = member」✅;(10)(c) characterization ✅;§4.1.1 標題改「killpoint 檔(無 CLI 旗標)」✅;**F13 仍寫 `:119`(實際 `boot.go:120`,本輪複驗)、F7 仍 `build-board.sh:166`(`patch-witness.sh check` 在 `:170`)、F11 仍 `:107-141`;§0 與 §2.1 仍叫 `--killpoint`**;§13 自稱「F13 boot.go:120」但正文沒改 → m3 |
| B-M1 沙箱底來源 | **yes** | 見摘要;F18 改寫正確;§4.4.1 sha 釘 `SHA256SUMS`;E-H3 改 v1.5.11 下載 |
| B-M2 tmp-trust / chain1 | **yes** | 見摘要;§2.2 條目(prov-lib **與** chain1 `batman-dvpc\.`、第 13 / 99 行同形收緊、`batman-prov-test` / `batman-provd-test` / `wbox/` 條目)、兩個測試案例;§4.5 dvpc「機制在 `pl_prep` 已有;chain1 本 PR 改走同一 `$PCD`」 |
| B-M3 GATT Flags | **yes** | 見摘要;F43 行號對上 bluez-5.72 |
| B-m2 F28 引用 | yes | §6.3 `ble-rpa`「stage1 F28 … 不是本文的 F28」 |
| B-m3 (8) 臂 C 停 helper | yes | §6.2 (8) 臂 C「同臂 B 的移除程序」;`health.go:151` `Committed()` 在 trial 為假 → 不寫回 |
| B-m4 unsquashfs stdin | yes | F44;§4.2 `tar -xzf … root.squashfs` → `unsquashfs -cat <file>`;WSL `unsquashfs -help` 4.6.1 `FILESYSTEM` 位置參數 |
| B-m5 n 公式 | yes | §6.3 `prov-sec-psk-timing`「n = 30 … 上限 200」 |
| B-m6 provd.env init 機制 | yes | §4.1.2 (4) `batman-provd.init.test` + Makefile ifeq + gate 加 `BATMAN_PROVD_TEST_INIT_7f3a` |
| B-m7 dbus 471 正向 | yes | F16「P2 後亦然」+ stage1 §4.6 policy 清單(本輪複驗 `254-stage1-impl.md` §4.6 dbus 列:無 `Introspectable`);§6.3 471 正向 = `Properties.Get` |
| B-m8 (10) 容器臂 | yes | §6.2 (10)(c) `docker run … -v /lib/upgrade … -v /opt/batdata … -v /tmp/run` + characterization 標註 |
| B-m11 §3 `ble-ok` 列 | yes | §3 p6 `ble-ok` 列(helper health 只在 committed;harness `state-set` 只在 helper 停止或 trial 內) |
| B-m13 第 99 行 regex | yes | §2.2「與第 13 行同形 `([^-a-z]\|$)`」 |
| B-m14 hold 值 / DISCARDED | **partial** | §4.2「hold 旗標的值 = 讀到的 `BATMAN_VERSION=` 整行值」**有歧義**(整行 = 含 `BATMAN_VERSION=` 前綴 → `want != $(version)` → 必 DISCARDED;autocommit `:271` `want=$(head -c 200 flag)` 對 `version()` = `sed s/^BATMAN_VERSION=//p`);「DISCARDED 立即 `back_to_a`」在無 hold 的健康 trial 上追不上 commit → m6 |
| B-m15 F15 ⚠️ / lint 簡化 / F23 訊息 | yes | F15 清 ⚠️(`init.d/boot:7-17` 本輪複驗 `files="$(ls)"` + `( . "./$file" ) && rm -f`);§4.2 `lint-wbox` 不套板 patch;F23 `|| no "tool placement"` |

## 新發現

### MAJOR
無。

### MINOR

#### m1. helper 份數:§5 與 §2.2 仍是 17,§4.2 / §4.7 是 10
- **情境**:P9 `--destructive` 以「10 份」斷言,`dv-prov-tools.sh` 抽 17 份、§5 install 列要求 17 份 → 寫實作的人二選一,另一處的負對照(`test-dv-preflight.sh` 缺項)跟著錯。
- **證據**:§5 第一列「`prov-test` helper 17」;§2.2 `dv-prov-tools.sh`「從每個 `-wbox` payload 抽 helper」;§4.2 成本段 / §4.7「10 份,不是 17」。
- **修**:§5、§2.2 改「抽 10 個 helper 變體(§4.2 規則)+ 對其餘 7 個斷言 helper sha = release」。

#### m2. §6.2 (7) 的 `chan` 前置仍是單次取樣措辭
- **證據**:§6.2 (7)「前置(§4.2:120 s 內頻道 ≠ p5 且 `batctl n` 空 …)」vs §4.2「T+120 s 起連續 3 次(間隔 10 s)」。
- **修**:(7) 改寫為「前置 = §4.2 的 3 次取樣規則」。

#### m3. A-m14 的行號 / 命名只在 §13 宣稱修了,正文未動
- **證據**:F13 `boot.go … :119`(實際 `:120`,`provstore.RemoveTxn` 在 `:119`);F7 `build-board.sh:74-96,166`(`patch-witness.sh check` 在 `:170`);F11 `sock.go:37-89,107-141`(拒絕在 `:136-141`);§0「`--killpoint`」、§2.1 表第一列「`--killpoint`」(契約是檔,§4.1.1 已改名)。
- **修**:改四處字串;§2.1 改「killpoint 檔」。

#### m4. CI `go test … | grep -c` 會吞掉 `go test` 的退出碼
- **情境**:`sudo -E env PATH="$PATH" … go test -v -tags prov_test ./... | grep -c -- '--- SKIP' || true` 這條管線的退出狀態是最後一段;`|| true` 再把一切歸零 → Go 單元 FAIL 時 job 仍綠(只要沒有 SKIP)。
- **證據**:§2.2 CI 列;§6.1 `prov-p1-stubs` 列同句。
- **修**:`sudo -E env PATH="$PATH" GOFLAGS=-mod=vendor GOTOOLCHAIN=local go test -v -tags prov_test ./... 2>&1 | tee go-test.log; test "${PIPESTATUS[0]}" = 0; [ "$(grep -c -- '--- SKIP' go-test.log || true)" = 0 ]`(或 `set -o pipefail` + 檔案)。負對照:故意 FAIL 一個單元 → job 紅。

#### m5. (9) dry-run 與真 main 共用 `$RUNDIR/autocommit.why`、`autocommit.ble-warned`、`otalog`:要寫明副作用與判定來源
- **情境**:dry-run 的 main 每輪 `echo "$why" > "$RUNDIR/autocommit.why"`(`:515`,不分 DRY),與真 main 交錯寫同一檔;`WARN ble:` latch(`:496-500`)也共用 → dry-run **不會**再印 WARN。(9) 判定若從 dry-run 輸出找 WARN 會假 FAIL;`otalog AC UNHEALTHY` 若 dry-run 先踩到(例如 NEED=3 未滿)會寫進真 otalog。在 held trial 裡 `autocommit.why` 的交錯無害(watchdog 不會動),但設計要說。
- **證據**:`batman-autocommit:496-500,515`;§6.2 (9) 只寫「WARN 行(內容只記錄)+ HELD → dry-run → `DRYRUN decision: COMMIT`」。
- **修**:(9) 寫明「WARN 行與 `HELD` 取自真 main 的 `logread`;dry-run 只斷言 stdout 的 `DRYRUN decision: COMMIT`;dry-run 執行 ≤ 60 s;其 otalog / `autocommit.why` 寫入為已知副作用,`pr_end` 不以 otalog 判 (9)」。

#### m6. hold 值「整行值」歧義;DISCARDED 後的恢復路徑寫錯
- **情境**:(a) 若實作照「整行值」寫 `BATMAN_VERSION=1.5.14-…` 進 p6 flag,autocommit `:271-290` 以 `want == $(version)`(`=` 之後的值)比對 → 每個 hold 單位都 DISCARDED。既有 harness(`brewrite-254.sh:22`、`chain1-254.sh:228`、`pty-commit-254.sh:56`)都寫 `$V`(值)。(b) DISCARDED 後 trial 無 hold:NEED_MESH=0(member radio-only)或 mesh 正常的 helper 類 mutant(`helper-notrial`、`helper-exit1` …)在 3×10 s 健康後 commit(`:30-31,:524-537`);`pr_find` 找到 trial 要 60–90 s → 「立即 `back_to_a`」追不上,結果是 committed 的 wbox 槽 = §4.2 不變量破、P9 FAIL 需人。
- **證據**:§4.2「hold 旗標的值 = 這裡讀到的 `BATMAN_VERSION=` 整行值 … 一看到 DISCARDED 行立即 `back_to_a`」;`batman-autocommit:271,284-289`。
- **修**:(a) 寫成「hold 值 = `etc/batman-build` 的 `BATMAN_VERSION=` **右側的值**,與節點 `sed -n 's/^BATMAN_VERSION=//p' /etc/batman-build` 逐位元組相等;`pr_ota_b` 推送前以 `cmp` 斷言」。(b)「DISCARDED 行出現 → 先 `batman-slot is-trial`:仍 trial → `back_to_a`;已 committed(mutant 槽)→ `pr_needs_person`(印 `batman-slot rollback` 指令),不自動回槽」;§5 加一列「DISCARDED 且已 commit」。

---

## 整份 v5 複讀(修法是否互相打架)
- §1.4「一律 hold」與 §6.2 (9) dry-run、§4.3 步驟 1 revert 等待、§5 panic 列:一致;hold 不擋 revert 由 `held()` `:94-106` 證實。
- §2.2 tmp-trust 新 regex 與 §4.5 dvpc 白箱(`pl_prep` 與 chain1 各一次)與 §3「dvpc `mkdir` 無 `-p`」:一致。
- §4.1.2 (4) `batman-provd.init.test` 與 §4.8.3「讀者 provd init(只 `prov_test`)」與 §3 `provd.env` 列:一致。
- §4.2 B-m14 的「立即 back_to_a」與 §4.3 `pr_ota_b`「落空 → 重試一次」:兩者對象不同(DISCARDED vs 沒落在 trial),不衝突;m6 補路徑。
- §4.4.1 v1.5.11 底 + §4.4 helper 現編 + `files/` 由 PR 蓋:自洽;E-H4 列出 busybox / uci 差異。
- §6.3 `prov-gatt` 行為判定依賴 P2 的 `GATT_ENCRYPT_CTRL`,§10 第 3 點已回報;P2 前此負對照不存在 → 乙部本來就等 P2 rc,可接受。

## 已核對的假設(本輪,file:line)
`batman-autocommit:27,30-31,35,42-43,48,52-60,69,94-106,162,194,200-204,228,233-247,270-291,323,376-384,432,496-500,515,529,544-557`;`boot.go:62-66,100-131,178-190`;`node.go` `commitTxn` → `RemoveTxn` → `Save`;`main.go:40,439-495`;`health.go:151,160-166`;`sock.go:2,36-50,70-78,136-141`;`sock_test.go:13-17,67`;`ble-lib-254.sh:78-133,205-228`;`joinwatch:37,135`;`platform-ab.sh:75-117`;`99-batman-chanfix:18-58`;`chain1-254.sh:112,315,362`;`prov-lib-254.sh:20,92`;`check-tmp-trust.sh:23,29,55`;`tmp-trust-allowlist.txt:13,99`;`test-tmp-trust.sh:18`;`ci.yml:74`;`daily-validation.sh:77-99,2740-2749`;`validation-known-failures.txt:10,19-24`;`batman-config-save:440-450`;`provclient/main.go:294-305,410-431`;firmware `init.d/boot:7-17`、`build-board.sh:146-173`、`stamp-batman-build.sh:38-58`;bluez-5.72 `gatt-client.c:814-830`、`gatt-database.c:1760,1766,1769,1783,1792,1827-1833`;WSL `unsquashfs -help`;`gh release list/view`(Batman、firmware)。

## 未核對(與前輪相同)
節點側 F6 / F16 / F17 / F21 / F28 / `autocommit.timeout` 是否存在;E-H1–E-H7;`BATMAN_PROV_TEST` 能否穿過 OpenWrt 子 make;`go version -m` 在 `-trimpath` 靜態二進位上保留 `-tags`。

## 裁決

**APPROVE-WITH-CHANGES**(BLOCKER 0 / MAJOR 0 / MINOR 6)。v4 的 5 個 MAJOR 全部核實解決;6 個 MINOR 都是文字一致性與一條 CI 管線退出碼,不動 §3 / §4 架構,可在實作 PR 的設計 bump 裡一併收,不需再開一輪整份審查。
