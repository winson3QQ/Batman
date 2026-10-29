# Review A(第 6 輪):`254-h23-harness.md` v6(28837c0;2026-10-28,唯讀;未碰 02 / 04)

範圍:逐條核對 v5 A(m1–m6)與 v5 B(M1、m1–m12)在 v6 的處置,對照設計文與原始碼(Batman-h23 工作樹;firmware-2710 `golang-package.mk`、`.config`);再讀整份 v6 找修法互相打架之處。重點題:killpoint 檔名與 gate 的 `strings` 斷言、tag 規則、`tests/wbox/helpers.list`、CI 管線、(9) dry-run、hold 值 `cmp` / DISCARDED、tmp-trust 新條目。

## 摘要

v5 的 1 個 MAJOR(B-M1)與 18 個 MINOR 全部有處置,正文與 §14 對得上,沒有只改對應表、正文沒動的情況(v5 A-m3 那類)。

我專門查的幾題結論如下:
- **killpoint 檔名 + gate 斷言**:有鑑別力。`feed/batman-prov/Makefile` `GO_PKG_LDFLAGS:=-s -w`,`golang-package.mk:164-171` 在 `CONFIG_USE_SSTRIP=y`(`.config:418`)時用 `strip --strip-all`。`-s -w` 和 `--strip-all` 都只拿掉符號表和 DWARF,`.rodata` 裡的 Go 字串字面值保留,所以 `"killpoint %s: armed"` 一定還在。release 版沒有這個字面值,現樹 `feed/batman-prov/src`(不含 vendor)grep `killpoint` 和 `armed` 都是 0 命中。`.gopclntab` 留著的函式名(例如 `…armKillpoint`)大寫 K、後面沒接空白,對不上 `killpoint .*: armed`(grep 大小寫敏感)。前提有一條:實作必須用單一格式字面值(例如 `log.Printf("killpoint %s: armed", n)`)。若用字串串接,gate 會 FAIL;這是 fail-closed,E-H2 就會暴露,所以可接受。
- **CI 管線**:`ci.yml` 沒有 `defaults.run.shell`,也沒有逐步的 `shell:`。所以實際 shell 是 GitHub 的預設 `bash -e {0}`,**沒有 pipefail**;`bash --noprofile --norc -eo pipefail` 只有明寫 `shell: bash` 時才會用。兩種情況都對:
  - 沒有 pipefail 時:管線狀態 = `tee` = 0,接著 `test "${PIPESTATUS[0]}" = 0` 讀的是 `go test` 的狀態,非 0 就被 `-e` 終止,job 紅。
  - 有 pipefail 時:管線本身非 0,`-e` 直接終止,也紅。

  `$(grep -c … || true)` 在 `-e` 下安全。
- **(9) dry-run**:`batman-autocommit:382` 的 clamp(300–3600)在 `AUTOCOMMIT_TIMEOUT` 覆寫**之前**,所以 `<uptime+120>` 生效,而且 `MIN_WINDOW=0`。印出 COMMIT(`:529`)後自行 `exit 0`;沒達成就在 deadline 印 `NOT committed` 後 `wait $WDPID` 退出。180 s 的 kill 只是保險。字串 `DRYRUN decision: COMMIT slot $SLOT (services ${NEED}x${POLL}s, mesh samples $jn)` 與 §6.2 一致。hold 區塊在 DRY 不 `rm` p6 旗標(`:290`),但真 main 已經消費掉旗標,所以沒有影響。
- **tmp-trust**:`PAT` 的 `/tmp([^/[:alnum:]_]|/|$)` 會命中 `/tmp/run/batman-prov-test/…`、`/tmp/x` 等寫法。三個漏檔(`prov-base-254.sh`、`dv-preflight.sh`、`prov-sec-254.sh`)都在掃描集合裡(`scripts/node/**`、`scripts/*.sh`),v6 已補上條目。剩下的問題見 m4(`prov-sec-254.sh` 用整檔 `.` 豁免太寬)。

新發現 4 個 MINOR,都是契約或措辭層級,不動 §3 / §4 架構。

**BLOCKER 0 / MAJOR 0 / MINOR 4 → APPROVE**(MINOR 可在實作 PR 的設計 bump 收;不需再一輪)。

---

## v5 發現 → v6 核對

| v5 | 解? | 證據 / 說明 |
|---|---|---|
| B-M1 killpoint 實作放 `_test.go` | **yes** | §2.1:`killpoint_provtest.go`(`prov_test`)、`killpoint_release.go`(`!prov_test`)、`killpoint_test.go`(單元);§4.1.3 加 `strings \| grep -c 'killpoint .*: armed'` ≥ 1;§6.1 `prov-gate-stubs` 加 mutant;§4.2 成本段 / E-H2 同句。字面值在 strip 後仍在 `.rodata`(見摘要)。負對照 stub 怎麼產生見 m1 |
| A-m1 helper 份數 | **yes**(→ m2) | §2.2 `dv-prov-tools.sh`、§4.2 成本段、§4.7、§5 都改成「依 `tests/wbox/helpers.list`」,不寫死數字;集合規則 = 碰 `src/` ∪ `test` ∪ `helper-exit1`。`helpers.list` 的寫者 / 過期處理見 m2 |
| A-m2 (7) chan 取樣 | yes | §6.2 (7)「§4.2 的三次取樣規則:T+120 s 起連續 3 次、間隔 10 s」 |
| A-m3 / B-m8 行號 / 命名 | yes | F7 `build-board.sh:74-96,170`、F11 `sock.go:37-89,136-141`、F13 `boot.go:120`(`:127` 另列);§0「killpoint 檔」;§2.1 表第一列「killpoint 檔」 |
| A-m4 CI 吞退出碼 | yes | §2.2:`tee go-test.log; test "${PIPESTATUS[0]}" = 0; [ "$(grep -c … go-test.log \|\| true)" = 0 ]`;§6.1「故意 FAIL 一個單元 → job 紅」。`bash -e` 與 `-eo pipefail` 兩種 shell 都正確(見摘要) |
| A-m5 / B-m1 (9) 共用寫入 / 時間 | yes | §6.2 (9):WARN 與 HELD 取自真 main 的 `logread`;dry-run 背景跑 + 180 s kill;`+120`;字串寫全。§7.2 新列列出 `:139-140,426,505,515,521-523`,並明寫為「一資源一寫者」的已知破例 |
| A-m6 / B-m14 hold 值 / DISCARDED | **yes**(→ m3) | §4.2:值取 `BATMAN_VERSION=` 右側,`cmp` 斷言;poll `autocommit.hold-discarded`(`:288` 確實寫);仍在 trial → `back_to_a`,已 commit → `pr_needs_person`;§5 新列。`cmp` 比的兩邊與自測方式見 m3 |
| B-m2 tmp-trust 漏三檔 | yes(→ m4) | §2.2 三檔都加 |
| B-m3 chain1 措辭 | yes | §2.2 / §4.5:chain1 自定 `PCD=/tmp/run/batman-dvpc.$RUN`,不 source prov-lib;allowlist 寫 `\|` 的說明 |
| B-m4 `ble-ipad.md` | yes | §6.3「由本 PR 乙部建立」 |
| B-m5 dbus-send | yes | §2.2:a72 路徑寫死,magic + e_machine `b700` |
| B-m6 `set-provd-env` restart | yes | §4.5:寫入 → restart provd → 驗 `/proc/<pid>/environ` |
| B-m7 GOCACHE | yes | §2.2:`GOCACHE=$(mktemp -d)` + 放最後一步(有了 GOCACHE,放最後一步是多餘的保險,不衝突;現有最後一步 claim-lock stub 已是綠燈:`feed/batman-provision/files/etc/init.d/batman-prov-lock` 存在) |
| B-m9 `peer-vs-provd` 前提 | yes | §4.8.3:由 P2 設計定 |
| B-m10 `helper-flap` tag | yes | §4.2 tag 規則;表 `helper-flap` = prov_test;`96-norestore`(碰 helper)= prov_test,`96-noprov` / `radio1-off` / `chan` / `helper-exit1` = release,都與規則一致;`misc-*` 標「依規則」 |
| B-m11 / B-m12 GATT 白箱字串 / 前置 | yes | §6.3 `prov-gatt-254`:`NotPermitted: Not paired`;SMP Pairing Request → Pairing Failed → ATT 0x0F;前置 04 無 agent + 固定排在 `prov-sec-bond` 之前 |

---

## 新發現

### MAJOR
無。

### MINOR

#### m1. CI 只跑 `-tags prov_test`:release 端的 killpoint 從未被單元測試;「實作放 `_test.go`」mutant 照現在的檔名編不出來
- **情境**:
  - (a) §4.1.1 測試列寫「release no-op」單元,但 §2.2 CI 只跑 `go test -tags prov_test`。`killpoint_release.go`(`!prov_test`)在 test 裡從未被編譯,只有 `go vet ./...`(無 tag)編過它,所以「release no-op」這條斷言實際上不存在。
  - (b) §4.1.3 的無 name gate 沒有 `strings | grep -c 'killpoint'` = 0 這條。release 端的「無 killpoint」只寫在 §4.1.1 的括號裡,gate 不執行。
  - (c) §6.1 `prov-gate-stubs` 的「實作放 `_test.go` 編出」mutant:v6 讓 `killpoint_release.go` 帶 `!prov_test`,實作若移到 `_test.go`,`-tags prov_test` 會因 `armKillpoint` undefined 而**編不過**,stub 拿不到二進位。
  - (d) 若 `./...` 意外對上 0 個測試(cd 錯),`go test` rc 0、SKIP 0,結果是綠的。依通用規則,沒有東西可測時必須 FAIL。
- **證據**:§2.2 CI 列;§4.1.1 末條;§4.1.3 無 name 列;§6.1 `prov-gate-stubs`。
- **修**:
  - CI 再跑一次無 tag 的 `go test ./...`,同樣存檔 + `PIPESTATUS`,以 root 跑或允許 sock 的 SKIP(由 tagged run 涵蓋),讓 release no-op 單元在 release 檔上執行。
  - 無 name gate 加 helper `strings | grep -c 'killpoint'` = 0。
  - mutant 寫成「`killpoint_release.go` 拿掉 build tag 以後 `-tags prov_test` 編出的 helper」(= v5 B-M1 情境 (b)),或直接用一個只含標記字串、不含 `armed` 的假 ELF。
  - 斷言 `grep -c '^ok ' go-test.log` ≥ 已知 package 數。

#### m2. `tests/wbox/helpers.list` 與 tag 的單一來源沒定契約
- **情境**:
  - §4.2 寫「由 `lint-wbox` 從 patch 內容算出,寫進 `helpers.list`」。CI lint 不應該寫 repo 檔,所以寫者與時機不明。
  - 讀者有兩個:P9 `--destructive`(harness main 的 checkout)和 `dv-prov-tools.sh`。payload 則來自 firmware pin 住的 `feeds/batman/tests/wbox/`。harness PR 先 merge(§8 第 5 步)時,兩邊的變體集合可能不同。
  - tag 本身由誰決定也沒寫:§4.2 只說 `export … (+ BATMAN_PROV_TEST)`;`lint-wbox`「tag 欄與表一致」裡的「表」是設計文,程式讀不到。
  - 規則「碰 `src/`」也漏了 `helper-exit1` 那種「碰 `feed/batman-prov/` 的 Makefile / files」的情況。v6 文字是以列舉方式把它補進集合,沒有寫成可機械化的條件。
- **證據**:§4.2 tag 規則段與成本段;§4.7;§5 install 列。
- **修**:
  - 寫明「`helpers.list` = 已提交的檔(一行一個 name + tag)。`lint-wbox` 從 patch 路徑重算:碰 `feed/batman-prov/src/` → prov_test;碰 `feed/batman-prov/**` 或是 `test` → 列入 helper 集合。與已提交的檔不一致 → FAIL」。
  - `build-board.sh --wbox` 用同一路徑規則或讀同一個檔決定 `BATMAN_PROV_TEST`,不另設來源。
  - `dv-prov-tools.sh` 雙向斷言:列入者的 sha ≠ release 且互異;未列入者的 sha = release。任一不符 → FAIL「helpers.list 與 payload 不一致(版本錯位?)」。這樣 harness 與 pin 錯位時會 fail-closed。

#### m3. hold `cmp` 兩邊沒寫清;§5「DISCARDED 且已 commit」的自測會故意 commit 一個槽
- **情境**:
  - (a) §4.2「與節點 `sed -n 's/^BATMAN_VERSION=//p' /etc/batman-build` 逐位元組相等;`pr_ota_b` 推送前以 `cmp` 斷言」:推送前節點跑的是 A(V),它的 `/etc/batman-build` 不是 trial 會讀的那份。能比的是:主機對 `unsquashfs -cat … etc/batman-build` 跑同一個 `sed` 的輸出,對上節點寫入後讀回的 p6 旗標,讀回要比照 autocommit `:271` 做 `head -c 200 | tr -d '\r\n'`。Git Bash 送出的 `\r` 會被 autocommit 去掉,但 `cmp` 會判不等。這是 fail-closed,但會誤判。
  - (b) §5 白箱「繞過 `cmp` 的 harness 自測 → `pr_needs_person`」:要走到「已 commit」分支,就得讓一個沒有 hold 的 trial 真的 commit。若用 wbox payload,就是主動製造 §1.4 不變量禁止的「committed mutant 槽」,而且結果是需人;用 V payload 則該分支無害,卻也被判 `pr_needs_person`,過度。
  - (c) 補充:DISCARDED 後「仍 trial → `back_to_a`」跟 commit 之間有競態。harness 可以先在 trial 內以 root 建 `$RUNDIR/autocommit.ctl/hold-commit`,`held_commit()` 每輪 poll 都會看(`:60`、`:510`),立即擋住 commit,再 `back_to_a`。
- **證據**:`batman-autocommit:60,271-290,510-513`;§4.2;§5 DISCARDED 列。
- **修**:
  - `cmp` 寫成「主機:payload 的 `etc/batman-build` 經同一個 `sed`;節點:讀回 p6 旗標並 `tr -d '\r\n'`」。
  - DISCARDED 後先建 ctl hold marker,再 `is-trial`。
  - 自測限用 V payload,並把「已 commit 且版本 = V」改判 INVALID + 正常 restore。「已 commit 且含 wbox」才走 `pr_needs_person`。

#### m4. `prov-sec-254.sh` 比照 `tmp-trust-280.sh` 用整檔 `.` 豁免太寬
- **情境**:allowlist `:53` 的 `scripts/node/tmp-trust-280.sh	.` 能成立,是因為那支檔**只做**攻擊模擬。`prov-sec-254.sh` 是混合檔:除了 `prov-sec-sockdir-254` 的 `ln -s /tmp/x /tmp/run/batman-prov` / `chown 471`,還包含 `helper-uid`、`key-perms`、`dvpc` 三個 root 執行的 tier A。整檔豁免後,這支檔日後若誤用 `/tmp` 下的決策路徑,tmp-trust 就看不到。
- **證據**:§2.2「比照 `tmp-trust-280.sh`(allowlist `:53`)加一條專屬條目」;`check-tmp-trust.sh` 以 glob + ERE 逐 hit 切除。
- **修**:條目寫成行級 ERE,例如 `ln -s /tmp/x /tmp/run/batman-prov` 與 sockdir 段的 `rm -rf /tmp/x`;或把 sockdir 攻擊模擬拆成獨立檔再用 `.`。

---

## 整份 v6 複讀(修法是否互相打架)
- §2.1 檔名、§4.1.3 gate、§6.1 stub、E-H2:同一字串 `killpoint .*: armed` 貫穿全文;與 §3 P9「本次 pid 的 log 無 `killpoint .*: armed`」也是同一字串。✅(m1 只補 release 端與 stub 產生方式。)
- §4.2「不重試一次」(DISCARDED)與 §4.3 `pr_ota_b`「落空 → 重試一次」:對象不同,不衝突。✅
- §6.2 (9) 的「dry-run 不會再印 WARN」與 §6.2 (8) 臂 A 的「本次開機一行 `WARN ble:`」:都以真 main 為準,一致。✅
- §2.2 CI「放最後一步」與現有 `ci.yml` 註解「claim-lock stub 是 LAST step」:claim-lock 已 merge、那一步已轉綠,所以沒有矛盾。實作時順手更新那段註解即可(不列發現)。
- §4.7 寫死「payload 18 份」,但 helper 份數改讀 `helpers.list`:變體表固定 18 列(數過:14 + `misc-*` 4),一致。✅
- tag 規則對表:`rc9-unclaimed`、`helper-*`(exit1 除外)、`96-norestore` = prov_test;`96-noprov`、`helper-exit1`、`radio1-off`、`chan` = release。都符合「碰 `src/`」規則。✅

## 已核對的假設(本輪,file:line)
`feed/batman-prov/Makefile`(`GO_PKG_LDFLAGS:=-s -w`、無 `GO_PKG_LDFLAGS_X` → `--version` 版號不會讓非 helper 變體的 sha 改變);`golang-package.mk:86-111,164-171,236-251`;firmware `.config:416-419`(`CONFIG_USE_SSTRIP=y` → `strip --strip-all`);`feed/batman-prov/src`(不含 vendor)grep `killpoint` / `armed` = 0;`sock_test.go:13-15`(唯一的 `t.Skip`);`ci.yml:69-74`(無 `shell:` / `defaults`)、`:75-85`;`batman-autocommit:25-75,270-291,376-384,426,505-557`;`chain1-254.sh:347-350`(背景 + kill 寫法);`check-tmp-trust.sh:23,29-34,55`;`tmp-trust-allowlist.txt:13,53,99`;`feed/batman-provision/files/etc/init.d/batman-prov-lock` 存在。

## 未核對
節點側全部(依指示不碰 02 / 04);`strings` 在 firmware WSL 的 binutils 版本(預設 `-a` 與否;`.rodata` 屬資料段,兩種預設都會掃到);Go linker 字串排序對 `.*` 跨字串誤配的實測(release 無 `killpoint ` 字面值,所以不影響判定);E-H1–E-H7。

## 裁決

**APPROVE**(BLOCKER 0 / MAJOR 0 / MINOR 4)。v5 的全部發現都已核實處置,且與原始碼一致;killpoint gate 有鑑別力,CI 管線在兩種 shell 下都正確。4 個 MINOR 是契約與措辭的補強,可以在實作 PR 的設計 bump 裡收,不需要再開一輪整份審查。
