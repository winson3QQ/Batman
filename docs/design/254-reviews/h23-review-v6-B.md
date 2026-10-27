# 審查 B(第 6 輪):`254-h23-harness.md` v6(28837c0;2026-10-28,唯讀;未碰 02 / 04)

逐條核對 v5 A(m1–m6)與 v5 B(M1、m1–m12)對 v6 文字與原始碼(Batman-h23 工作樹 28837c0;firmware-2710 build_dir:bluez-5.72、dbus-1.14.10、procd-2026.03.14~c59f2d80;`build-board.sh`),再重讀整份 v6。本輪實跑:
- `bash scripts/check-tmp-trust.sh`(現樹):`check-tmp-trust: 0 untrusted line(s)`。
- `od` / `file` / `readelf -d` 於 dbus-send(a72 / a53 / wrapper)。
- WSL go1.22.2 拋棄式 module,`GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags='-s -w'`,檔名照 §2.1(`killpoint_provtest.go` / `killpoint_release.go`),再做「實作放 `_test.go`」mutant 與「字串串接」變體,`strings | grep -c 'killpoint .*: armed'`:

```
rel: 0  pt: 1
…Typekillpoint %s: armedreflect.Value.IsNil…      (pt 的 strings 片段:Go 字串無 NUL,混在長串裡,grep -c 仍 = 1)
mutant: 0
concat: 0                                          (log.Print("killpoint " + n + ": armed"))
	build	-tags=prov_test
```

## 摘要

v5 的 1 MAJOR / 18 MINOR 全部有處置;B-M1 的修法實測有鑑別力(release 0 / prov_test 1 / `_test.go` mutant 0),release 不會含這個字面值(`killpoint_release.go` 無字串;pclntab 留的是 `killpoint_release.go` 檔名與 `main.armKillpoint`,前者無空白、後者大寫 K,都不中 `killpoint .*: armed`)。dbus-send e_machine `b700` 與 `ble-254.sh:44-45` 同一 `od -j18 -N2` 讀法、實測兩個樹都是 `b700`。CI 管線在 GitHub 預設 shell 下兩種情形都會紅(見 m7)。

新發現都是 MINOR:一個是我 v5 m11 自己寫錯的判定字串(bluetoothctl 不印錯誤訊息),其餘是 tmp-trust 條目的寬度、白箱的可實作性、CI 步驟位置、ujail 下 environ 讀哪個 pid。不動 §3 / §4 架構。

**BLOCKER 0、MAJOR 0、MINOR 10 → APPROVE-WITH-CHANGES。**

---

## v5 發現 → v6 核對

| v5 | 解了? | 證據 |
|---|---|---|
| B-M1 killpoint 實作放 `_test.go` | **是**(m1 補一句) | §2.1 三檔命名;§4.1.3 gate `strings … ≥ 1`;§6.1 `prov-gate-stubs` mutant;E-H2。實測見上:release 0、`prov_test` 1、mutant 0。gate 只在實作用**單一格式字面值**時成立(串接 → 0,fail-closed)→ m1 |
| B-m1 (9) dry-run 共用寫入 / 時間 | 是 | §6.2 (9) `+120`、背景 + 180 s kill;§7.2 破例列。`batman-autocommit:382` `T=$AUTOCOMMIT_TIMEOUT`、`DEADLINE=$T` = 絕對 uptime → `<uptime+120>` 寫法正確;`:270` dry-run 的 hold 區塊要 p6 flag,真 main 已消費 ✅;`:529` 字串與 §6.2 一致 ✅ |
| B-m2 tmp-trust 漏三檔 | **部分**(m4) | 推演:`prov-base-254.sh` 的 `rm -rf /tmp/run/batman-prov-test`(行尾 → `$` 分支切掉,剩 `rm -rf ` 不中 PAT)✅;`dv-preflight.sh` 的 `[ -e /tmp/run/batman-prov-test/ ]` / `/tmp/run/batman-provd-test` ✅;bind 殘留 `/tmp/run/batman-dv/wbox` 由第 13 行收緊後 `([^-a-z]\|$)` 接 `/` 仍切 ✅;`/run/batman-prov-test` 的 `/run/batman` 後接 `-` 不中 PAT 第 3 分支 ✅。`prov-sec-254.sh` 條目的 regex 沒寫,照 `:53` 先例(`.`)會豁免整檔 → m4 |
| B-m3 chain1 措辭 | 是 | §2.2;改後 chain1 只剩 `PCD=/tmp/run/batman-dvpc.$RUN` 一處字面值 → 條目切成 `PCD=$RUN`,`:315` 變 `mkdir -m 0711 $PCD` 不再中 `mkdir +-p +/tmp/` ✅ |
| B-m4 `ble-ipad.md` | 是 | §6.3 由乙部建立 |
| B-m5 dbus-send e_machine / 路徑 | 是(m9 附帶) | a72 `.libs/dbus-send`:`7f454c46` / `b700`、`ELF 64-bit LSB … ARM aarch64 … interpreter /lib/ld-musl-aarch64.so.1`、77424 B;a53 同為 `b700`(e_machine 分不出 a53 / a72,靠寫死路徑 ✅);`tools/dbus-send` = `2321202f`(`#! /`,bash wrapper)✅ |
| B-m6 `set-provd-env` restart | 是(m8 附帶) | §4.5;procd `instance.c:397-399` 對每個 env 加 `-e NAME` 給 ujail、`:480-481` `setenv`;`jail.c:2758-2778` 只匯入 `-e` 列出的變數、`:1314-1330` 以 `build_envp` `execve` 子程序 → env 會進 jail ✅;讀哪個 pid → m8 |
| B-m7 GOCACHE / 步驟位置 | **是,但與現有慣例衝突**(m7) | `GOCACHE=$(mktemp -d)` 已隔離;「放最後一步」與 `ci.yml` 現有 claim-lock 步驟註解衝突 |
| B-m8 `--killpoint` | 是 | §0、§2.1 |
| B-m9 `peer-vs-provd` 前提 | 是 | §4.8.3 |
| B-m10 `helper-flap` tag | 是 | §4.2 規則 + 表 |
| B-m11 GATT 白箱字串 | **否,是我 v5 寫錯**(m2) | bluetoothctl 只印 `error.name` |
| B-m12 04 無 agent 前置 | **部分**(m3) | 排序有;「斷言 `AgentManager1` 無註冊」做不到 |
| A-m1 helper 份數 | 是(m10 附帶) | §2.2、§4.2、§4.7、§5 改 `tests/wbox/helpers.list` |
| A-m2 (7) 三次取樣 | 是 | §6.2 (7) |
| A-m3 行號 / 命名 | 是 | F7 `build-board.sh:170`(本輪複驗 `:170` = `patch-witness.sh check`);F11 `sock.go:136-141`(`serveConn` 的 `connection refused: peer uid %d (want %d) %v`);F13 `boot.go:120`(`txn %s committed (gen %d): overlay completed from p5`) |
| A-m4 CI 吞退出碼 | 是 | 見 m7 的 shell 分析 |
| A-m5 (9) 判定來源 | 是 | §6.2 (9)、§7.2 |
| A-m6 hold 值 / DISCARDED | 是(m10 一句) | §4.2 右側值 + `cmp`;`:289` 寫 `autocommit.hold-discarded` ✅;`batman-slot is-trial` 存在(`batman-slot:18` 回 0 / 1 / 2)|

---

## 新發現

### BLOCKER
無。

### MAJOR
無。

### MINOR

#### m1. killpoint gate 綁在「單一格式字面值」上,§4.1.1 要寫死
- **情境**:實作若寫 `log.Print("killpoint " + n + ": armed")` 或 `Printf("killpoint %s: %s", n, "armed")`,gate 讀 0 → `test` 變體 build FAIL。fail-closed,但會在 E-H2 才發現。
- **證據**:上面實測 `concat: 0`。
- **修**:§4.1.1 寫明 log 呼叫是 `Printf("killpoint %s: armed", name)`(同一字面值),Go 單元對 log 輸出斷言整行;gate 字串與 P9 / §4.1.1 共用同一常數名(只在 `killpoint_provtest.go` 定義)。

#### m2. `prov-gatt-254` 白箱判定字串:bluetoothctl 不印 `Not paired`(改正我 v5 m11)
- **情境**:02 是 bluetoothctl(`ble-central-254.sh:5-7,52,70`)。`gatt.read` 失敗時 bluetoothctl 只印 D-Bus 錯誤**名稱**,不印訊息 → `org.bluez.Error.NotPermitted: Not paired` 永遠不會出現,照文件 grep = 白箱讀成 FAIL。另外 `NotPermitted` 也是 0x02 `Read not permitted` 的名稱,單靠名稱分不出 0x0F。
- **證據**:bluez-5.72 `client/gatt.c:835` `bt_shell_printf("Failed to read: %s\n", error.name);`;`src/gatt-client.c:283-290`(0x02 → `"Read not permitted"`、0x05 / 0x0F / 0x0C → `"Not paired"`,同一 `btd_error_not_permitted`)。v5 m11 的字串是我寫的,錯在我。
- **修**:02 的判定改成 `Failed to read: org.bluez.Error.NotPermitted`(bluetoothctl),**0x0F 的鑑別交給 btmon**(ATT Error Response 0x0F + SMP Pairing Request / Pairing Failed、無 LE Start Encryption);要拿到 `Not paired` 訊息就改用 02 上的 `dbus-send --print-reply … ReadValue`(印 `Error org.bluez.Error.NotPermitted: Not paired`)。

#### m3. 「04 `AgentManager1` 無註冊」查不到;agent 這個資源沒有擁有者
- **情境**:BlueZ `AgentManager1` 只有 `RegisterAgent` / `UnregisterAgent` / `RequestDefaultAgent`,沒有列舉方法 → P9 / 單位前置照字面做不出來。`prov-sec-bond-254` 在 04 掛的「白箱常駐」agent 不在 §3 表、不在 prov deadman 動作裡;harness 死在 prov-sec-bond 中 → agent 留著 → 下次 `prov-gatt` 白箱變成「配對成功、讀到資料」= 無效而非 FAIL。
- **證據**:§3 表無 agent 列;§3 prov deadman 動作只有 unbind / `rm -rf` / 起服務;§6.3 `prov-sec-bond` 列。
- **修**:§3 加一列「04 agent 程序(bluetoothctl,pid 檔 `$DVD/<run>/agent.pid`):`prov-sec-bond` 起 / 收;deadman `kill` + 刪 pid 檔」;前置改為「pid 檔不存在 **且** 04 無 harness 起的 bluetoothctl 程序」。同時斷言 02 上沒有 04 的配對紀錄(`bluetoothctl paired-devices` 不含)。

#### m4. tmp-trust:`prov-sec-254.sh` 的條目要窄,且還漏兩種行
- **情境**:(a)§2.2 說「比照 `tmp-trust-280.sh`(allowlist `:53`)」,而 `:53` 的 line-ERE 是 `.` → `sed s/.//g` 把整行清空 = 整檔豁免。`prov-sec-254.sh` 是 root 跑的 tier A(還放 key-perms、dvpc、uid 三個測項),整檔豁免等於把這支檔從 #280 防線拿掉。(b)sockdir 的另一臂「`chown 471` 預建 `/tmp/run/batman-prov`」那行 `/tmp/run/batman-prov` 後接空白,第 99 行只套 `feed/batman-prov/src/*`,這檔沒有條目 → 紅。(c)dvpc 白箱「root 預建 symlink」那行會寫 `/tmp/run/batman-dvpc.<run>`:第 13 行收緊後 `dvpc` 的 `p` 是 a-z 不切,dvpc 條目只給 `prov-lib` / `chain1` → 白箱所在檔(`prov-sec-254.sh` 或 `scripts/dv/prov-sec-dvpc-254.sh`)紅。
- **證據**:`tmp-trust-allowlist.txt:13,53,99`;`check-tmp-trust.sh:23,55`。
- **修**:`prov-sec-254.sh` 一條:`ln -s /tmp/x /tmp/run/batman-prov( |$)|/tmp/run/batman-prov( |$)|/tmp/run/batman-dvpc\.` + 理由(root 白箱、攻擊模擬,目標名只在 0755 root 的 `/tmp/run` 下);dvpc 白箱若在 `scripts/dv/` 另加同條。`test-tmp-trust.sh` 加:`prov-sec-254.sh` 多一行 `cat /tmp/x` → UNTRUSTED(證明不是整檔豁免)。

#### m5. dvpc 白箱「對 chain1 也做一次」做不到(RUN 不可覆寫)
- **情境**:預建 symlink 要先知道名字;`prov-lib` 有 `RUN=${RUN:-…}`,chain1 是 `RUN=ch1$(date +%m%d%H%M)` 寫死,而且 chain1 是新卡鏈,為一個 `mkdir` 白箱跑整條鏈成本太高。
- **證據**:`prov-lib-254.sh:11`;`chain1-254.sh:26`;§4.5。
- **修**:把「建 `$PCD`(`mkdir -m 0711` 無 `-p` → EEXIST 即 `FAIL dvpc dir pre-exists`)」抽成一個兩邊共用的函式(例如 `scripts/lib/dvpc-254.sh dvpc_place <ssh> <dir>`),白箱只對這個函式做;或 chain1 改 `RUN=${RUN:-…}`。

#### m6. §7 第一列「`nobody` 預建 → refused」不會發生在 helper 端
- **情境**:`/tmp/run` 是 root 0755(allowlist `:12`、procd 建),`nobody` 的 `mkdir /tmp/run/batman-prov-test` 直接 EACCES,helper 的 owner / mode / symlink 檢查從沒被走到。這條負測試會「過」但沒測到想測的東西。
- **修**:改為「root 預建後 `chown 65534` / `chmod 0777` / 改成 symlink / `ln` 第二個 hardlink → helper log `killpoint: refused (<why>)`」;`nobody` 只用來證明 `/tmp/run` 本身擋住(一行 EACCES)。

#### m7. CI:「root `go test` 放最後一步」與現有慣例衝突;只跑 `-tags prov_test` 會漏 release 變體
- **情境**:(a)`ci.yml` prov-p1 job 現在的最後一步是 claim-lock stub,註解寫明「the LAST step of the job, so the expected red never skips the P1 steps above」。v6 要把 root `go test` 放最後;一旦它前面有任何 harness-first 的 expected-red 步驟,root Go 單元就被跳過,F20 修了等於沒修,而 job 照樣「紅 = KNOWN」。既然 `GOCACHE=$(mktemp -d)` 已經隔離,「最後一步」不必要。(b)根步驟只有 `-tags prov_test` → `killpoint_release.go` 的 release no-op 單元只在現有非 root `go test ./...`(`ci.yml:74`)還留著時才跑;v6 沒說那步留不留。「`killpoint_test.go` 兩種 tag 都編」也要兩種 tag 有不同預期(armed vs no-op),一個無 tag 測試檔得自己分支。`go vet` 也沒帶 tag。
- **shell 分析(GitHub 預設)**:`run:` 未指定 `shell` → `bash -e {0}`(無 pipefail):`go test … | tee` 回 tee 的 0 → `test "${PIPESTATUS[0]}" = 0` 不成立 → `-e` 退出 → 紅 ✅;指定 `shell: bash` → `bash --noprofile --norc -eo pipefail {0}`:管線本身非 0 → `-e` 在那行就退出 → 紅 ✅(`PIPESTATUS` 多餘無害)。`grep -c` 0 筆時印 `0` 且 rc 1,`|| true` 吃掉 rc、輸出仍是 `0` ✅。
- **修**:root 步驟緊接 setup-go,expected-red 步驟維持在最後(或後續步驟加 `if: success() || failure()`);root 跑兩次:`go test -v ./...` 與 `go test -v -tags prov_test ./...`(各自存檔、各自 `PIPESTATUS`、各自數 SKIP),`go vet` 同兩次;單元測試檔拆 `killpoint_provtest_test.go`(`//go:build prov_test`)/ `killpoint_release_test.go`(`//go:build !prov_test`)。

#### m8. `set-provd-env` 斷言要讀 jail 裡的 provd,不是 procd 記的 pid
- **情境**:P2 的 provd 跑在 ujail(§3 `/tmp/run/batman-provd-test` 列「在 P2 ujail mount 清單」)。procd 的 instance pid = ujail;procd 先 `setenv` 再 exec ujail(`instance.c:480-481`),所以 **ujail 的 `/proc/<pid>/environ` 一定含所設值**,不管 ujail 有沒有把它傳給子程序。讀錯 pid = 永遠 PASS。
- **證據**:`instance.c:397-399`(`-e NAME`)、`jail.c:2758-2778`(只匯入 `-e` 列的變數)、`:1314-1330`(`execve(…, envp)`)。root 讀 dumpable=0 / 別的 pid ns 的 `environ`:PTRACE_MODE_READ + CAP_SYS_PTRACE,OK。
- **修**:§4.5 寫「pid = `/proc/<pid>/exe` 為 provd 二進位、父程序為 ujail 的那一個」;負對照:`provd.env` 寫一個 init 不認的鍵 → 子程序 environ 無它。

#### m9. E-H1「dbus-send 只需 `libdbus-1.so.3` + musl」不對
- **證據**:`readelf -d …/tools/.libs/dbus-send`:`NEEDED libdbus-1.so.3`、`libgcc_s.so.1`、`libc.so`。照原文斷言 E-H1 會自己 FAIL。另:同樹有 `ipkg-install/usr/bin/dbus-send`(套件安裝版),可考慮改抄它(與 a72 路徑同樣寫死)。
- **修**:E-H1 預期改為三個 NEEDED,並斷言 04 有 `libgcc_s.so.1`。

#### m10. `tests/wbox/helpers.list` 的寫者;`is-trial` rc 2
- (a)「由 `lint-wbox` 從 patch 內容算出,寫進 `helpers.list`」:CI 的 lint 不能寫回 repo。改為「檔案入版控;`lint-wbox` 重算並與它逐行相等,否則 FAIL」(P9 / `dv-prov-tools.sh` 讀它);同理 §4.2「tag 欄與表一致」的「表」要指這個檔,不是設計文件。
- (b)§4.2 DISCARDED 路徑只寫了 `is-trial` 0(trial)/ 1(committed);`batman-slot:18,38` 還有 2 = unknown → 寫明 2 → `pr_needs_person`(不 `back_to_a`)。

---

## 整份 v6 複讀(修法有沒有互相打架)
- §2.1 / §4.1.1 / §4.1.3 / §6.1 / E-H2 的 killpoint 命名與 gate 一致;P9 用同一字串 ✅。
- §4.2 tag 規則 ↔ 表 ↔ §4.7 / §5 / §7.3 的份數都改成「依 `helpers.list`」,無殘留 17 / 10 ✅(m10 只是寫者)。
- §4.2 DISCARDED ↔ §5 新列 ↔ §4.3 `pr_ota_b`「落空 → 重試一次」:對象不同(DISCARDED 不重試),不衝突 ✅。
- §6.2 (9) ↔ §7.2 破例列 ↔ §3:§3 沒有對應的「破例」註腳,§7.2 有;可接受。
- §6.3 `prov-gatt` 排在 `prov-sec-bond` 前,但乙部沒有像 §4.3 那樣的全套順序段;排序只寫在單位列 → 隨 m3 在 §4.3 補一行乙部順序。

## 已核對(本輪,file:line / 實跑)
`check-tmp-trust.sh:23,29,45,55`;`tmp-trust-allowlist.txt:12,13,53,99`;`test-tmp-trust.sh:18-35`;`scripts/lib/ble-254.sh:44-45,55`;`ble-central-254.sh:5-7,52,70`;`prov-lib-254.sh:11,20,92`;`chain1-254.sh:26,112,315,347`;`prov-base-254.sh:27,210-212`;`dv-preflight.sh:4,94`;`batman-autocommit:27-28,69,194,240,270,289,323,376-386,496-499,529`;`batman-slot:18,38`;`boot/boot.go:115-125`;`sock/sock.go:49,74,136-141`;`sock_test.go:13-15`;`ci.yml:47-85`;bluez-5.72 `client/gatt.c:825-835,2189`、`src/gatt-client.c:280-295`;procd `service/instance.c:385-400,470-490`、`jail/jail.c:967-1006,1314-1330,2634-2778`;firmware `build-board.sh:168-172`;dbus-send `od` / `file` / `readelf -d`;go1.22.2 arm64 `-s -w -trimpath` 拋棄式 build(上)。

## 未核對
CI 用 go 1.26(本輪 1.22.2;字串常數的佈局跨版本沒變過,但未實測);04 的 `libgcc_s.so.1`、bondable 狀態;Linux 6.6 SMP 對 SC Just Works 是否一律問 user space(v5 以 `device.c` 推論,本輪未重查 kernel 源碼);dry-run 在 OTS 節點 120 s 內能否完成 pre-commit canary `docker run`(⚠️,E-H 沒列量測)。

## 裁決

**APPROVE-WITH-CHANGES**(BLOCKER 0 / MAJOR 0 / MINOR 10)。v5 的 B-M1 修法實測成立;全部 v5 A / B 發現已處置(B-m2、B-m12 部分,B-m11 是我原本寫錯,本輪更正)。剩下的都是文字 / 條目 / 白箱可實作性,可在實作 PR 的設計 bump 裡收,不需要再審一輪整份。
