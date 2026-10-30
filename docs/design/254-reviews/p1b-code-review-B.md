# P1b 程式碼審查 — 審查者 B

範圍:Batman `feat/254-p1b-seams` @ c6601e7(vs `origin/main`)+ firmware `feat/254-wbox` @ 1fc28b95(vs `e7c2a222`)。
依據:`254-h23-harness.md` v7 §2.1、§4.1、§4.2、§15(§15 優先)。`seam` 命名偏離為刻意(§15.4),不算 finding。
唯讀;沒有碰節點;firmware 樹只讀檔案與 build_dir 產物(build 進行中)。

## 摘要

- Go seam:7 個點與 §4.1.1 一一對應,只在 `daemon()` 內 `Arm`,其他 verb 打不到;`armed` 只在起 goroutine 前寫,`-race` 乾淨;兩種 tag 的 `go vet` / `go test` 都綠;release arm64 helper `strings` 中 `killpoint` = 0、marker = 0,prov_test = 5 / armed 1 / marker 1。
- gate:自測 16/16;**真的 `--wbox test` payload(1.5.14-wsl.5…dirty.wbox-test)**:wbox 模式 PASS、normal 模式 FAIL;真 1.5.14-wsl.4 rootfs:normal PASS,換 prov_test helper → FAIL。OpenWrt 的 env 會傳進 Makefile:build_dir 的 ipkg helper `-tags=prov_test`、armed 1。
- 兩個 MAJOR:(1)`--wbox` 不先確認 `feeds/batman` 乾淨 → SIGKILL 留下的 mutant 會跟下一個疊在一起,gate 照樣 PASS;trap 也會清掉開發者在 `feeds/batman` 的本地修改。(2)⚠️ 推論:`sysrq reboot` 這行在 reboot 前幾乎送不出節點,但 §6.2 的 L7 要求看到這一行。

## Findings

### MAJOR-1 `--wbox` 套 patch 前沒確認 `feeds/batman` 乾淨 → mutant 疊加、開發者修改被刪
- 位置:`scripts/build-board.sh:111-126`(trap :117、apply :121);註解 :109「-i resets feeds/」。
- 事實:
  - `openmanet_setup.sh:244-248` 明文**不 reset `feeds/batman`**(「feeds/batman is ours and never patched here: leave a developer's local edits there alone」)。所以 `-i` 不會清掉 mutant,:109 的註解對 `feeds/batman` 不成立。
  - EXIT trap 遇到 SIGKILL 不會跑(實測:TERM → yes,INT → yes,KILL → no)。現場會出現 SIGKILL 的情況:`wsl --shutdown`、OOM killer、TaskStop 殘留後手動 kill、斷電。
- 情境 A(疊加):`--wbox helper-notrial` 被 SIGKILL,patch 留在樹上 → 下一次跑 `--wbox helper-noleave`,`git apply --check` 只要不衝突就會過 → image 裡同時有兩個 mutant。stamp 本來就因 wbox 被強制 DIRTY,所以分不出來;gate 只找本變體的見證。實測:在 rootfs 加上別的變體的見證 `"WBOX-helper-notrial-55667788"`,`check-prov-test-gate.sh … chan` 結果仍是 `ok`。`--wbox test` 本身沒有 patch,遇到殘留 mutant 一樣全收。負對照的結論會錯,而且查不出來。
- 情境 B(修改被刪):開發者在 `feeds/batman` 有未 commit 的修改,這是 setup 與 stamp(`feeds/batman-modified` → DIRTY)都支援的工作流程。這時跑 `--wbox X`:修改會混進變體,而且 exit 時 `checkout -- .` 加上 `clean -fdx` 把修改和未追蹤檔一起刪掉,救不回來。
- 修法:
  1. 在 :117 設 trap **之前**檢查 `[ -z "$(git -C feeds/batman status --porcelain --ignored)" ] || { echo "feeds/batman not clean — refusing --wbox" >&2; exit 1; }`。要先檢查再設 trap,否則拒絕時 trap 還是會清。
  2. gate 的 wbox 模式:rootfs 裡所有 `WBOX-` 命中都必須是 `WBOX-$NAME-`;`test` 模式要求 0 命中。
  3. 改正 :109 的註解。
  4. 自測補「疊加見證 → FAIL」。

### MAJOR-2(⚠️ 推論,未在硬體重現)`killpoint <name>: sysrq reboot` 這行在 reboot 前送不出節點
- 位置:`seam/seam_provtest.go:47-50`(`logf` 之後馬上寫 `/proc/sysrq-trigger`);`main.go:49-56`(`logf` = syslog datagram)。
- 情境:這行先進 logd 的 RAM buffer,要再經過 ubus、`logread -f`、sshd、TCP 才到主機。sysrq `b` = `emergency_restart`,幾微秒後就重開、不 flush,RAM log 也跟著沒了。§4.1.1 規定「只在 `sysrq reboot` 行 + 2 s 內 boot_id 改變時判 L7 PASS」,§6.2 `prov-powerloss` 也要求「全部:sysrq 行」,結果是每個 L7 單位都判 ⚠️ 或 FAIL。這是 fail-closed、不會誤判 PASS,但測項等於不能用。程式碼照設計文字寫,所以缺口同時在設計和實作。E-H6 是手動 `echo b`,不驗這件事。
- 修法(二選一,寫進 §4.1.1):
  - (a)`logf` 之後先 `time.Sleep(300*time.Millisecond)` 再寫 sysrq。只擋住 txn 這個 goroutine,仍然不 sync。再加一個 E-H 項,實測主機端真的收得到這行。
  - (b)L7 的判定改成「`armed` 行 + 檔已刪 + boot_id 改變 + 狀態停在該點」,不再要求 sysrq 行。`fallback` 改用「重開後 boot-reasons 的類型」來區分。

### MINOR-1 `read` 在 `set -e` 下沒有提示就退出
- `build-board.sh:115`:`read -r _ WTAG _ < <(awk …)` 找不到名字時 read 回 1,`set -e` 直接 exit 1,:116 的錯誤訊息永遠印不出來。實測:rc=1,沒有任何輸出。
- 修法:比照 :72 加 `|| true`。

### MINOR-2 gate 對 release tag 變體不檢查 helper,tag 打錯字會被當成 release
- `check-prov-test-gate.sh:58-64`、`build-board.sh:124`。
- 情境:release tag 變體(例如 `chan`)拿到 prov_test helper(BATMAN_PROV_TEST 從環境漏進來,見 MINOR-3)→ gate 回 `ok (wbox chan, tag release, helper tags=[prov_test])`(實測)。helpers.list 把 tag 寫成 `prov-test` → build 和 gate 都當 release 處理,gate 也 `ok`(實測)。後面還有 `lint-wbox` 和 `dv-prov-tools` 會擋,但 gate 本身是 fail-open。
- 修法:`case "$TAG" in prov_test|release) ;; *) fail` 兩處都加;TAG=release 且 ISGO=1 時,斷言沒有 prov_test tag、marker 為 0、`killpoint` 為 0。

### MINOR-3 `BATMAN_PROV_TEST` / `BATMAN_WBOX` 會從操作者的環境繼承
- `build-board.sh` 沒有 unset 這兩個變數。操作者 shell 裡有 `export BATMAN_PROV_TEST=1` 時跑一般 build:整個 image build 完,才在 step 7 被 gate 擋下(fail-closed,但浪費一次完整 build);遇到 release tag 變體則會漏過(MINOR-2)。build-board.sh 是子行程,它自己的 export 不會漏回父 shell,這點沒問題。
- 修法:參數解析後加 `unset BATMAN_PROV_TEST BATMAN_WBOX`,之後只由 :123-124 設定。

### MINOR-4 讀不到的檔案會讓見證掃描 fail-open
- `check-prov-test-gate.sh:47,68`:`grep -rla … 2>/dev/null` 遇到讀不到的檔案直接略過。實測:放一個含 `WBOX-x-00000000`、mode 0000 的檔案 → normal 模式 `ok`。機率低,因為 unsquashfs 以擁有者身分解開。helper 本身讀不到時是 fail-closed(會落到「not a Go binary」)。
- 修法:grep rc 2 視為 FAIL,或先 `find "$R" -type f ! -readable | head -1`,有結果就 FAIL。

### MINOR-5 `seam_release_test.go` 判別力很弱
- release 的 `Arm` 根本不知道測試用的 temp 路徑,所以就算 release `Arm` 真的去讀 `/tmp/run/batman-prov-test/killpoint`,這個測試照樣綠。真正擋住的是 gate 的 `strings | grep -c killpoint` = 0(已實測 release 為 0)。
- 修法:註解寫明「真正的保證是 gate §15.4」,或拿掉「never reads」這個宣稱。

### MINOR-6 `owned()` 只比 `Perm()`
- `seam_provtest.go:77`:目錄 01700 / 02700、檔案 04600 都會被接受。風險極低,因為只有 root 能建。
- 修法:改比 `fi.Mode() & (os.ModePerm|os.ModeSetuid|os.ModeSetgid|os.ModeSticky)`。

### MINOR-7 雜項
- `build-board.sh:52` 的 usage 沒有 `--wbox`。
- 設計 §4.2 寫「trap 寫 stamp」,實作在 :182(step 6 之後)才寫。實作的做法比較安全(build 失敗下次會再 clean),請在設計註記。
- txn-3 在「`--prov-only` rc≠0 但 p5 的 gen 已前進」的分支也會觸發(`txn.go:41`)。這和「p5 已持有新 gen」的語意一致,但 §4.1.1 寫的是「rc 0 後」,請在文件補一句。

## 已確認沒有問題的攻擊面
- `${WBOX:+"$WBOX"}` 的引號正確。`make package/batman-prov/clean`、`package/batman-provision/clean` 這兩個路徑存在(`package/feeds/batman/` 下有)。真 build 時 env 有傳到 Makefile(ipkg helper `-tags=prov_test`)。
- 多個 tag:`,$TAGS,` 的比對對逗號分隔的寫法正確。go 會把 `-tags` 正規化成逗號分隔,這點是推論,沒有實測空白分隔的情況。
- `go version -m` 讀不到時:ELF → FAIL,shell 檔 → 依模式判斷(normal = FAIL)。`GO=/nonexistent` 加 prov_test helper → FAIL。真 OpenWrt helper(CGO=1、stripped)的 build info 讀得到。
- 見證 grep 不會命中 `/etc/batman-build`(那裡只有 `BATMAN_WBOX=name`)。release helper 沒有 `WBOX-`。真 1.5.14-wsl.4 rootfs 全樹沒有 `WBOX-` 也沒有 `killpoint`。
- 7 個 hook 只在 `applyNet`(network/join、network/update)與 `commit(…,"claim")`。leave / ssh_keys / owner.* 傳的是 "";`At("")` 不會觸發;`--boot` / `--apply-state` 不會 `Arm`。
- TOCTOU:目錄 root 0700,`/tmp/run` root 0755,非 root 換不了檔。目錄是 symlink 時 `owned(Dir)` 會擋(有測試)。
- 測試隔離:沒有 `t.Parallel`;`reboot` 用 defer 還原;每個測試都 `setup()` 重設 `Dir` / `wantUID`。`-shuffle=on -count=5` 兩種 tag 都綠。

## 實跑紀錄
```
# Go(go1.26.4,副本 /tmp/revB,含 tests/vectors)
vet tags=[] rc=0 ; vet tags=[prov_test] rc=0
test tags=[]          → 12 packages ok, rc=0
test tags=[prov_test] → 12 packages ok, rc=0
SKIP = 4(兩種 tag 都一樣:TestAllowedPeer/TestWrongPeerClosed/TestOversizeAndMalformedClose/TestPrepareDirRefusals = 既有的 root-only;seam 的測試沒有 skip)
-race ./seam ./cmd/... 兩種 tag 都 ok;-shuffle=on -count=5 都 ok
arm64 -trimpath -s -w:
  release   killpoint=0 armed=0 marker=0 WBOX-=0
  prov_test killpoint=5 armed=1 marker=1 WBOX-=0, build -tags=prov_test
# gate 自測(副本,BATMAN_SRC=副本)
RESULT gate self-test: 16 ok, 0 bad
# 真 rootfs 1.5.14-wsl.4:normal → ok;換 prov_test helper → FAIL helper built with -tags prov_test;換 release helper → ok
# 真 payload 1.5.14-wsl.5+01b12c9.fwd2a4bfd.dirty.wbox-test:gate test → ok (tag prov_test, helper tags=[prov_test]);gate normal → FAIL BATMAN_WBOX=test
# 對抗:release tag + prov_test helper → ok(MINOR-2);tag 打錯字 → ok(MINOR-2);疊加見證 → ok(MAJOR-1);0000 見證檔 → ok(MINOR-4)
# shell:read 找不到 → rc=1,沒有訊息;trap EXIT:TERM yes / INT yes / KILL no
```
沒有做:以 root 跑 Go 測試(沒有 sudo 密碼,CI 的 `sudo -E` 路徑沒驗);節點上的 sysrq 行能否送達(MAJOR-2 是推論)。

## Verdict
**APPROVE-WITH-CHANGES**:MAJOR-1 修好並補自測;MAJOR-2 要在 04 跑 L7 之前做出決定(a 或 b)並寫進設計。MINOR 可以隨這次 PR 一起修。
