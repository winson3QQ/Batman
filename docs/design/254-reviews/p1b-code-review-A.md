# PR-P1b + firmware --wbox 程式碼審查 — 審查者 A

- Batman `feat/254-p1b-seams` @ c6601e7(diff `origin/main..c6601e7`)
- firmware `feat/254-wbox` @ 1fc28b95(diff `e7c2a222..1fc28b95`)
- 依據:`254-h23-harness.md` v7 §2.1、§4.1.1–4.1.3、§4.2、§15(§15 優先)。`killpoint` → `seam` 改名是已知、有理由的偏離(§15.4 release 無 `killpoint` 字串;pclntab 會留檔名 / 函式名),不列為問題。
- 唯讀;沒碰 02 / 04;沒在 `/home/yello/firmware-2710` 裡 build(Go 測試與 arm64 編譯都在 `/tmp/revA*` 的副本裡跑,用自己的 GOCACHE,跑完已刪)。

## 摘要

7 個 killpoint 的位置與 §4.1.1 及 §6.2 一致(txn-4 = `RemoveTxn` 之後、`Save` 之前,符合 §6.2 的定義)。不會在非預期路徑觸發:`commit()` 只有 `what == "claim"` 會帶點名,`leave` / `ssh_keys` / `owner.*` 傳 `""`,而 `At` 對 `""` 有守門;`claim.replay` 不走 `commit`;`boot.go` 不呼叫 `commit` / `commitTxn`;`Arm` 只在 daemon 執行。release 確實沒有作用,`strings` 實測 `killpoint` 出現 0 次。gate 自測 16/16 通過,雙 tag 的 vet / test 全綠,Go 單元對 link count 與 owner 兩個 mutant 都會變紅。

主要問題有三:
- 「`sysrq reboot` 那行 log」是判 PASS 的必要證據,但寫完 log 立刻 sysrq,這行幾乎到不了主機。這是設計層面的問題,實作照設計做,但會讓 L7 判定做不到。
- 名稱指定模式的 gate 會放過「release-tag 變體帶著 prov_test helper」的情況。
- CI 沒有任何測試能抓到點的位置被搬動。

另有幾個 build-board 的小問題。

## 發現

### MAJOR

**A-M1 `sysrq reboot` 證據行與 sysrq 之間沒有任何間隔,主機收得到這行的機率趨近 0;§4.1.1 的 PASS 條件因此做不到**(⚠️ 推論,未上機)
- 位置:`seam/seam_provtest.go:47-51`,先 `logf("killpoint %s: sysrq reboot")`,接著立刻 open + write `/proc/sysrq-trigger`。
- 情境:`logf` 走 `log/syslog` 的 unixgram 寫到 logd,datagram 只是排進 socket 佇列。要到主機,還得經過 logd 排程讀取 → ubus 通知 `logread -f` → sshd → TCP 送出。而 `write("b")` 會在 syscall 內同步執行 `emergency_restart`,這中間只有幾微秒。logd 的 ring buffer 在 RAM,重開後就沒了;pstore / ramoops 依記憶「DT reg 壞、pstore 空」,也留不住。於是 harness 的「`sysrq reboot` 行 + 2 s 內 boot_id 改變 → PASS」在 txn1..5、claim-after-persist、claim-before-shadow 7 個單位上很可能每次都判 FAIL 或 ⚠️。
- 證據:程式碼路徑(上述),以及 `main.go:49-56`(`logf` 只寫 syslog)。**沒有真機數據**,E-H6 只測 `echo b`,沒測這行能不能到主機。
- 修法(擇一,並把 E-H6 擴充成實測:04 lease 內主機開 `ssh logread -f`,在節點上 `logger X; echo b > /proc/sysrq-trigger`,看 X 有沒有到):
  - (a) 判定改成:`armed` 行(重開前已收到)、boot_id 改變、狀態停在該點、本次 boot 沒有 `fallback` 行;`sysrq reboot` 行降為「有就記錄」。產品不用改,只改設計 §4.1.1 與 harness。
  - (b) 產品在 log 之後、sysrq 之前固定等 ~300 ms。代價是這段時間內 writeback 可能把 page cache 刷下去,讓「斷電語意」變弱,所以要先證明 p5 / overlay 寫入本來就已 fsync。
  - 建議 (a)。

**A-M2 名稱指定模式的 gate 對 `release` tag 變體不檢查 helper 的 tag,實測假 PASS**(✅ 實證)
- 位置:`check-prov-test-gate.sh:58`,只有 `TAG = prov_test` 時才檢查 helper;`build-board.sh:124` 只 `export BATMAN_PROV_TEST=1`,從不 `unset`。
- 情境:操作者的 shell 殘留了 `export BATMAN_PROV_TEST=1`(做過一次 `--wbox test` 手動實驗、或 CI env),接著 `build-board.sh ekh-bcm2711 --wbox 96-noprov`。結果 helper 帶 prov_test tag 編出來,gate 照樣 PASS,image 帶著 killpoint 程式碼出去。雖然 `dv-prov-tools.sh` 的 `same → sha = release` 之後還會擋一次(§15.5),但 gate 本身說了假話,而且 E-H2 驗收「其餘變體 = release helper」要等到 build 完才發現。
- 實測:release-tag 變體 `96-noprov` 的 rootfs 放 prov_test helper,gate 輸出 `check-prov-test-gate: ok (wbox 96-noprov, tag release, helper tags=[prov_test])` rc=0。
- 修法:
  - `build-board.sh` 開頭 `unset BATMAN_WBOX BATMAN_PROV_TEST`,只由 `--wbox` 設定;
  - gate 在 `TAG = release` 且 `ISGO=1` 時,斷言 tags 不含 `prov_test`、marker = 0、`killpoint` = 0;
  - 自測加這兩案例(env 殘留;release-tag 變體帶 prov_test helper → FAIL)。

**A-M3 7 個點的位置沒有任何自動測試會區分;把點搬走,CI 全綠**(✅ 實證)
- 情境:mutant 3 = 把 `txn-4` 搬到 `RemoveTxn` 之前,並把 `commit()` 的 `claim-after-persist` 映射改成 `""`。兩種 tag 的 `go test ./...` 12 個 package 全 `ok`。這類錯誤要等到 18 個變體 build 完、OTA、上 04 硬重開才會被 tier B 發現,一輪要好幾小時,還多一次 04 硬重開。§4.1.1 的四證據之一「狀態停在該點」只在真機上驗。
- 修法(便宜):在 `seam_provtest.go` 加一個 prov_test 專用的 hook(例如 `var Fire = func(name string){…}`,預設為 reboot,測試可替換),node 套件加 `//go:build prov_test` 的測試。用既有 fakeSys 跑 `applyNet` / `claimVerify`,在 Fire 裡 `panic(name)` 截停,斷言每個點當下的狀態:
  - `.txn` 有無;
  - fake setkey 是否已呼叫;
  - p5 gen;
  - overlay gen;
  - `Save` 是否已呼叫;
  - `SetLastKnown` / shadow 是否已執行。

  再對 `leave` / `ssh_keys` / `owner.add` / `claim.replay` 斷言,arm 任何點都不會觸發。負對照就用上面這個 mutant。
- 設計沒有明文要求這組測試,但以 review 規則「測試要能區分」來看,目前這 7 個點在 CI 端沒有任何測試覆蓋。

### MINOR

**A-m1 `build-board.sh:115`:在 `set -euo pipefail` 下,`read … < <(awk …)` 找不到名稱會讓 read 回 1,腳本直接靜默退出(rc 1)**,第 116 行的訊息永遠印不出來。實測:`rc=1`,沒有訊息。fail-closed,但操作者不知道原因。修法:`read … || true`(同第 72 行的寫法)。

**A-m2 wbox stamp 只在成功時寫(`build-board.sh:182`),被中斷的 build 會留下不一致狀態**
- 情境:`--wbox test` 在 batman-prov 已以 prov_test 編好之後才失敗或被 kill,stamp 仍是舊的 `none|0`。下一次正常 build 不會 clean,沿用 prov_test helper,最後 gate 在第 7 步 FAIL。fail-closed,但浪費整輪 build,而且錯誤訊息不會指向 stamp。
- 修法:進第 5 步 clean 判斷之後、`make` 之前,先 `rm -f "$WBSTAMP"` 或寫 `in-progress`,這樣中斷後下一次一定 clean。
- SIGKILL 或斷電時 EXIT trap 不會跑,feeds/batman 會留著 patch。這種情況靠 stamp 的 `feeds/batman-modified` → DIRTY 加上 gate 的 witness 擋住(lint-wbox 保證見證進產物),可以接受,但建議在第 2 步加「feeds/batman 有改動且不是 `--wbox` → 拒絕並提示 `git -C feeds/batman checkout`」。

**A-m3 `--card-only --wbox X` 會做出 wbox 的卡片 image**(`build-board.sh:204,218-229`):gate 會 PASS,把 mutant 燒進 committed 槽 A,違反 §4.2「只進非 committed 槽」。修法:`CARD_ONLY=1` 且 `WBOX` 非空 → exit 2。另外,正常的 `--card-only`(沒有 `--wbox`)遇到上一次是 wbox build 時,會因 `BATMAN_WBOX` 行被 gate 擋下,這是正確行為,建議把訊息寫明是「上一次是 wbox build」。

**A-m4 gate 的 init-mutant 偵測寫死 `feed/batman-provision/`**(`check-prov-test-gate.sh:70`):`chan` 或日後的 init mutant 若放在其他套件的 `files/etc/init.d/wbox-*`,這條檢查會靜默不套用。修法:`'^+++ b/feed/[^/]*/files/etc/init.d/wbox-'`。另外,`helpers.list` 的 tag 欄只比對 `prov_test`,其他值(例如打成 `prov-test`)一律當 release;建議 gate 與 build-board 都斷言 tag ∈ {prov_test, release}。

**A-m5 gate 自測只看 rc,不看原因;正常模式下 marker 與 `killpoint` 兩條沒被獨立覆蓋**(`test-prov-test-gate.sh:27`)
- "normal build with prov_test helper" 會先死在 tags 檢查,所以刪掉 `:42-43`(marker / `killpoint` = 0,§15.4)自測照樣 16/16。
- 修法:
  - `want` 加第三參數「預期原因子字串」;
  - 加案例:release tag 但 rodata 含 `killpoint` 的 helper(例如 release 檔裡放一個被引用的 `"killpoint"` 字面值)→ FAIL "killpoint strings"。

  另外 `FW=/home/yello/firmware-2710` 寫死、沒有接進任何 CI 或 daily-validation(firmware `.github/workflows/*` grep 無命中),目前只能手跑。建議接進 E-H2 的固定步驟,並在 PR body 貼輸出。

**A-m6 firmware CI(`build-firmware.yml:213-226` 的 witness 步驟)沒跑 `check-prov-test-gate.sh`**,只有本機 `build-board.sh` 第 7 步跑。若有任何 release 產物出自 CI,gate 不在那條路上。這跟 `check-pvs-shim.sh` 的既有缺口同類。建議在同一步驟加一行(正常模式即可)。

**A-m7 release 測試 `TestReleaseIsANoOp` 的「沒碰檔案」斷言是空的**(`seam_release_test.go:12-30`):release `Arm` 不認得 temp 目錄,所以就算 release `Arm` 誤讀真實的 `/tmp/run/batman-prov-test/killpoint`,這測試也照綠。實際上靠的是 gate(`killpoint` = 0 與 marker = 0)。可接受;建議在註解寫明「真正的保證 = gate §15.4」,或直接刪掉這段斷言,免得給出假信心。

**A-m8 release 二進位仍含 `claim-after-persist` 字面值**(✅ `strings` 實測 cap=1;`claim-before-shadow` 與 `txn-*` 已被 inline 消除)。來源是 `txn.go:15-16` 的 `pt = "claim-after-persist"` 傳進未被 inline 的 `commitTxn`。不違反 §15.4(沒有 `killpoint`),但 release 有了測試點名。修法:`commit()` 改用 `if seam.Enabled && what == "claim"`(常數折疊後字面值會消失),或由呼叫端傳點名;這樣也順便去掉「用 `what` 字串決定 seam」的隱性耦合:把 `"claim"` 改名,點就會靜默失效,而 A-M3 的測試才抓得到。

**A-m9 `Arm` 是 Lstat 之後再 `os.ReadFile(path)`(`seam_provtest.go:88-104`)**:有 TOCTOU 窗口,而且 ReadFile 會跟隨 symlink。實際只有 root 能在 root 0700 目錄(父目錄 `/tmp/run` root 0755)內換檔,所以不構成攻擊面。教科書寫法是 `open(O_RDONLY|O_NOFOLLOW|O_NONBLOCK)` 之後對 fd 做 `Fstat`(type / uid / mode / nlink),再 `io.LimitReader(fd, 64)`。建議改,成本很低。目錄的 sticky / setgid 位元不在 `Perm()` 裡,目錄的 group 也沒檢查(0700 下無意義),都可接受。

**A-m10 fallback 的 `select {}`(`:57`)**:`reboot -f` 失敗時,請求的 goroutine 永久卡住,節點活著、helper 半死。harness 會以 boot_id 沒變判 FAIL,不會誤判 PASS,可接受。建議在 `select {}` 前加一行 `killpoint <name>: reboot failed`,讓 P9 / 歸因有字可查。

**A-m11 CI 只跑 release tag**(`.github/workflows/ci.yml:74`:`go vet ./... && go test ./...`):本 PR 的 prov_test 單元(`seam_provtest_test.go`、`version_test` 的 prov_test 分支)在 P1b 自己的 CI 上不會跑。§8 規定 harness PR 先 merge(§15.3 的 CI 雙跑在那裡),所以 P1b 必須在 harness PR merge 之後 rebase,讓 CI 跑到兩種 tag;PR body 要貼兩次的 `ok` 列表與 SKIP = 0。

### 確認無問題(附證據)

- 點位對照(`node.go:1111/1117/1119/1123/1128`,`txn.go:41`,`node.go:521`):
  - txn-1 在 WriteTxnMarker 與 WriteTxn 之後、setkey 之前;
  - txn-2 在 setkey 之後、commitTxn(Persist)之前;
  - txn-3 在 Persist rc 0(或 rc≠0 但 p5 gen = next)之後、WriteOverlay 之前;
  - txn-4 在 RemoveTxn 之後、Save 之前(= §6.2);
  - txn-5 在 Save 之後、return 之前;
  - claim-after-persist 在 claim 的 Persist 之後、overlay 之前;
  - claim-before-shadow 在 commit 與 SetLastKnown 之後、setPassword 之前。
- 非預期路徑:`commit()` 的 6 個呼叫點(`node.go:514/718/791/836/863`)只有 514 帶 `"claim"`;`claimReplay`(`:530-590`)不走 commit;`At("")` 被 `armed != ""` 擋住;`Arm` 只在 `daemon()`(`main.go:452`),`--boot` / `--apply-state` 不 arm。
- `--version`(`main.go:377-379`)在 syslog 與 root 檢查之前;`len(os.Args)==2`;rc 0。舊版二進位不論是否 root 都回 2(非 root 回 `root only`,root 回 usage)。所以 pre-P1b 偵測用 rc 是成立的。
- 權限:killpoint 只有 root 能寫(`/tmp/run` root 0755,目錄必須 root 0700)。provd(471)與 `nobody` 進不去。release 完全不碰檔案系統。`--version` 讓非 root 能讀 `/etc/batman-build`,但那本來就是 world-readable。沒有新的特權。
- trap:非 `--card-only` 路徑上沒有其他 EXIT trap(`--card-only` 的 `:224` trap 在另一個分支);feeds/batman 是真的 src-git clone(`feeds/batman/.git`),不是 src-link;板 patch 全在 feeds/openmanet 與 feeds/packages(`+++` 列表),`clean -fdx` 不會清掉它們。
- gate 的 `go version -m` 解析:prov_test helper 輸出 `build -tags=prov_test`,release 沒有 `-tags` 行。

## 實際執行

```
# Go 1.26(firmware staging go-1.26),副本 /tmp/revA2.*,含 tests/vectors
== full tags=[]          12 packages ok(boot cbor cmd cose health keystore node proto provstore seam shacrypt sock)
== full tags=[prov_test] 12 packages ok
vet-ok ×2
seam -tags prov_test -v: TestArmedLineIsTheGateLiteral / TestAtFiresOnlyTheArmedPoint / TestNoFileNothingArmedNoLog /
  TestRefusals/{dir_0777,file_0644,file_symlink,second_hardlink,dir_is_a_symlink,unknown_point} / TestWrongOwnerRefused / TestMarker  PASS
== mutant 1: drop Nlink check   → --- FAIL: TestRefusals/second_hardlink   (負對照 ✅)
== mutant 2: drop owner check   → --- FAIL: TestWrongOwnerRefused          (負對照 ✅)
== mutant 3: txn-4 移到 RemoveTxn 前 + claim-after-persist 映射改 ""  → 兩種 tag 12/12 ok   (A-M3)

# arm64 -trimpath -s -w
release  : killpoint=0 armed=0 marker=0 claim-after-persist=1 claim-before-shadow=0 sysrq-trigger=0 batman-prov-test=0 ; no -tags line
prov_test: killpoint=5 armed=1 marker=1 claim-after-persist=1 claim-before-shadow=1 sysrq-trigger=1 batman-prov-test=1 ; build -tags=prov_test

# gate 自測(commit 1fc28b95 的 gate)
RESULT gate self-test: 16 ok, 0 bad
-- release-tag variant 96-noprov carrying a prov_test helper (want FAIL):
check-prov-test-gate: ok (wbox 96-noprov, tag release, helper tags=[prov_test])  rc=0     (A-M2)
-- set -e + read with no match: rc=1, no message                                      (A-m1)
```
第一次只抽了 `src` 的副本,proto 有 4 個 FAIL(`vectors.json: no such file`)。原因是我的副本沒帶 `tests/vectors`,不是產品問題:補上 `tests/vectors` 後(上面的結果)全部 ok。

沒做的:真機(依指示);E-H6 / log 送達實測(A-M1 為推論);firmware 完整 build(依指示)。

## 結論

**APPROVE-WITH-CHANGES**:0 BLOCKER / 3 MAJOR / 11 MINOR。

- A-M2 與 A-M3 是程式碼修正加測試。
- A-M1 先用 E-H6 擴充實測:如果收不到那行,改設計 §4.1.1 的判定(建議 (a),不動產品);如果收得到,附數據後降級。
- MINOR 建議同一輪修:A-m1、A-m2、A-m3、A-m8 都是一兩行。
