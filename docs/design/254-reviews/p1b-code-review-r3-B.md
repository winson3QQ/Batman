# PR-P1b + firmware --wbox 程式碼審查 第 3 輪 — 審查者 B

(審查者 agent 無法寫檔,全文由主 session 依其回報原文存入;內容未改寫。)

範圍(整體,非只看第 2 輪修正):Batman `feat/254-p1b-seams` @ 014778c(13 檔 +811/−5)、firmware `feat/254-wbox` @ a0aedd98、rc `rc/254-p1b` @ c62468e6(= a0aedd98 + pin f6ac1f7 + BUILD_N=6)、設計 @ cf26d7d、兩個 wsl.6 payload。所有測試在 /home/yello 下的拷貝跑;未改任何 worktree、未 build、未碰節點。

## 結論
**APPROVE-WITH-CHANGES:0 BLOCKER / 1 MAJOR / 8 MINOR。** 第 1、2 輪 finding 全部已修或已記殘項;這次的 rc 就是審過的程式碼。

## 實跑證據(✅)
- Go 1.26.4 於 014778c 拷貝:`go test ./...` 與 `-tags prov_test ./...` 12 package 全 ok;`-race`(seam / node / cmd)ok;`go vet` 兩 tag 乾淨;`--- SKIP` = 0。第一次 proto / keystore FAIL 是拷貝漏了 tests/vectors,補上後 PASS(翻轉實證,非產品問題)。
- arm64(-trimpath -s -w):release helper 的 `killpoint`、marker、armed、點名、`/dev/kmsg`、`sysrq-trigger`、`batman-prov-test` 全 0;prov_test helper `killpoint` 7,其餘各 ≥ 1。
- rc 內容:`git diff 014778c f6ac1f7 -- feed/batman-prov` 為空;739c1636 與 c62468e6 只差測試腳本;origin/rc/254-p1b = f6ac1f7。
- payload(SHA256SUMS 三檔 OK):
  - normal:`BATMAN_VERSION=1.5.14-wsl.6+f6ac1f7.fw739c163`、`BATMAN_DIRTY=0`、無 `BATMAN_WBOX`;helper 無 `-tags`,seam 字串全 0。
  - test:`….dirty.wbox-test`、`BATMAN_WBOX=test`、helper `-tags=prov_test`;帶第 2 輪才加的字串(`killpoint file longer than 64 bytes`、`sysrq write failed`、`<4>batman-provhelper: `、`reboot did not happen`)→ 確為 014778c 的 seam 程式碼。⚠️ 字串指紋判定,未逐位元重現(CGO=1 的 OpenWrt toolchain 未重跑)。
  - 兩 rootfs `diff -rq` 只差 batman-build、helper、batman-prov.control、luci header.ut。
- gate(c62468e6):normal rootfs → `ok (no test seam; helper tags=[])`;test rootfs + `test` → `ok (wbox test, tag prov_test, helper, …)`;test rootfs 當 normal → FAIL「carries BATMAN_WBOX=test」(wbox build 後誤跑 `--card-only` 會被擋)。
- firmware 自測:gate 45 ok / 0 bad;wbox lib 34 ok / 0 bad;pre-P1b Batman main 當來源 → 明確「predates the #254 P1b seams … pin a Batman that has them」(§16.17 刻意);gate 33 個 `fail` 逐條改 `:` → 33 條全被抓,0 存活。
- Go 突變被殺:late-only-rc0、no-claim-shadow、shadow-after-lock、txn4-before-remove、commit-has-point、no-kmsg、no-maxfile、unlink-untrusted、no-nlink、no-uid、version-marker-release、version-wrong-rc。`at-ignores-arm`:seam 測試 FAIL,但 node 測試卡到逾時(MAJOR-1)。`arm-trims-garbage`:存活(MINOR-3)。
- lib 突變:trap 只 checkout 不 clean → 4 bad ✅;`wbox_apply` 移到 stamp 之後 → 34 ok 存活(MINOR-2)。
- E-H2 / Ctrl-C log:stamp 切換 `test|1 -> none|0`、`none|0 -> test|1`、`in-progress:none|0 -> test|1` 都有記錄;兩模式 gate ok 行都在;feeds/batman 乾淨。
- shellcheck:只有刻意的 SC2064、SC2148,及 `need()` 的 SC1073 誤報。

## MAJOR-1 prov_test 測試裡,沒 arm 的點一觸發就真的 sysrq + `reboot -f`;設計又規定以 root 跑(✅)
- 情境:§2.2、§4.1.1、§15.3 規定 `sudo -E go test -tags prov_test`。`seam_provtest.go` 的 `var reboot = fire`,只有 `ArmForTest` 換掉;node 其他測試呼叫 `seam.At` 走真的 `fire`。`At` / `Arm` 一個回歸、或照設計跑突變負對照,root 下的測試就寫 sysrq `b` → GitHub runner 硬重開(失敗無法歸因)、使用者 WSL VM 重置且無 sync(進行中的 build 一起沒了)。
- 證據:突變 `at-ignores-arm`,非 root + PATH 前放假 `reboot` → `panic: test timed out after 25s … TestClaimLockFailure`;假 reboot log 記 `FAKE reboot -f`。非 root 時 sysrq 寫入 EACCES 所以只卡住;root 就真的重開。
- 修法:`hook_provtest.go` 加 `SafeForTests()` 把 `reboot` 換成 `panic`;seam 與 node 的 prov_test 測試各加 `TestMain` 先呼叫。負對照:`at-ignores-arm` 必須變成立即、清楚的 FAIL。

## MINOR
1. 環境變數 `GO_PKG_TAGS` / `GOFLAGS` 滲進正常 build(⚠️ 最小 makefile 驗 make 語意):`GO_PKG_TAGS=prov_test make` → `tags=[prov_test] origin=environment`;Makefile 無 else、`wbox_env_reset` 未 unset。gate 第 7 步會擋但要等整個 build。修:Makefile `else GO_PKG_TAGS:=`;`wbox_env_reset` 一併 unset。
2. test-build-board-wbox 只檢查呼叫字串在不在;順序錯的突變存活,到 gate 才失敗。修:斷言行號順序。
3. killpoint 檔「一行一個點名」無負對照(`arm-trims-garbage` 存活):`TestRefusals` 加 `"txn-1 x"`、`"txn-1\ntxn-2"`。
4. build-board 註解「-i resets feeds/」不對(`openmanet_setup.sh:244-248` 刻意不重設 feeds/batman);SIGKILL 後 mutant 留在 feeds/batman,下次正常 build 不拒絕、只標 `.dirty`,要等 gate 掃到見證才 FAIL。修:改註解;正常 build 發現 feeds/batman 不乾淨且含 `WBOX-` 見證就提早拒絕。
5. §16.1(f) 的 kmsg `<4>` 能否進 ramoops console 取決於 console loglevel(⚠️ 未驗);helper 的行不含 `sysrq: `,不會偽造 hint ✅。建議 E-H6 加 `cat /proc/sys/kernel/printk` 或改 `<3>`。
6. `fast-build.yml` 產出的 A/B payload 沒有映像 gate(既有,非本 PR;風險≈0;#254 記一行)。
7. wsl.6 沒 build bcm2710(❌;依 CM4 決定記殘項)。
8. Ctrl-C 實證用 `test` 變體(無 patch)(⚠️):patch 還原只在假 feed 證過;第一個帶 patch 的變體出來後補一次真 build + Ctrl-C。GitHub CI 未實跑(❌;依 §16.17 要 pin bump 後才可能綠)。

## 第 1、2 輪對照
- ✅ 已修並驗:r2-B M1、r2-A M1、r2-B m1(txn-3 rc≠0)、m2(鎖)、m3(第 3 欄)、m4(symlink helper)、r2-A m2 / B-m8、m3(舊 pin 訊息)、r1 A-m8、A-m4、(f) 程式部分。
- 殘項(#254 已記):main.go 接線無 Go 測試、P1b 的 CI 只跑 release tag。

## 介面 / 生命週期 / 安全
- 擁有權:build 期間 feeds/batman 單一寫者(flock);wbox stamp 一板一個;killpoint 檔讀完即刪 ✅。
- 契約:舊 helper(wsl.4)收 `--version` → usage rc 2 無副作用 ✅;killpoint 檔不符 → refused(fail-closed)✅;gate 讀不到或缺項 → FAIL ✅。
- 生命週期:正常 → wbox → 正常、Ctrl-C、in-progress 都有 log ✅;wbox 後 `--card-only` 被 gate 擋 ✅;SIGKILL 殘留見 MINOR-4;bcm2710 見 MINOR-7。
- 安全:release 無新攻擊面(只多 argv `--version`),payload 實證 ✅;test 映像 killpoint 目錄 root 0700、fstat 檢查;Lstat→open 的 TOCTOU 需能寫 `/tmp/run`(root 0755,⚠️ 未上節點確認);env 滲入見 MINOR-1;我們自己的錯見 MAJOR-1。

## 分類
- ✅ Go 兩 tag + race + vet、arm64 strings、payload 與 gate 兩模式、rc pin 內容、自測 45 / 34、gate fail 掃描 33/33、14 個 Go 突變、2 個 lib 突變、build log。
- ⚠️ MINOR-1、5、8;payload helper 身分只用字串指紋。
- ❌ GitHub CI 實跑、bcm2710 build、節點端檢查。
