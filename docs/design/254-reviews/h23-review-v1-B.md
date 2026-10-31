# 審查 B:`254-h23-harness.md` v1(2026-10-28,唯讀;未碰 02 / 04)

審整份。先找擁有權表與生命週期矩陣的缺口,再對 §1.3 事實逐條對原始碼;協定 / BLE 面(§4.8–§4.10、§6.3)對 `219-protocol.md` v0.7 與 CDDL;範圍對 `254-p1-impl.md` §5 與 `254-stage1-impl.md` §8–§9。

## 摘要

設計方向(真 build 的 `-wbox`、killpoint 封閉清單、frame socket 作為 `peer.py` 主傳輸、沙箱改 shell)可用,但照 v1 寫的程序**第一個單位就起不來**(全套順序與 `pty-commit-254` 衝突)、**四個單位的負對照引用不存在的 mutant**(§4.1.2 又禁止其他 mutant 路徑)、**provd 的 frame socket 放在 provd 寫不進的目錄**。另外多處判定字串與錯誤碼對不上原始碼(會把正確的產品判 FAIL)、上層要求的測項被靜默丟掉、`peer.py` 的「第二裁判」與第一裁判是同一份實作。

BLOCKER 3、MAJOR 17、MINOR 14。**REJECT**。

---

## BLOCKER

### B1. 全套順序讓 prov tier B 的第一個單位必 FAIL
- **情境**:§4.3「prov tier B 在 2g 之後」。2g 的最後一個 suite 是 `pty-commit-254`,它**把 04 移到另一槽**(`scripts/dv/pty-commit-254.sh:14`「Each run moves the node to the other slot」;`daily-validation.sh:279-281, 297`「moves the node to the other slot, so it runs last」)。`pr_begin` 的 P9 子集要求 S0 = A committed(§4.3)。於是每次 `--destructive` run 的第一個 prov 單位都在 `pr_begin` 停下 → 15–20 h 的無人值守 run 從未開始。
- **證據**:上層 `254-p1-impl.md` §4.5.0 寫的是「prov tier B **先跑**;不符 → 04 自動正規化(跨槽重建)」。h23 §4.3 把順序改到 2g 之後,**且沒有保留正規化步驟**(§3、§4.3、§5 都沒有「committed = B 時怎麼回 A」的入口;§4.3 的「跨槽」只在還原類別裡,不在 `pr_begin`)。
- **修**:二選一並寫進 §4.3 + §5 + 測試:(a) prov tier B 放在 2g 的 `pty-commit-254` **之前**(或把 `pty-commit-254` 移到 prov tier B 之後),並在 prov 區塊開頭做 p1-impl §7.4 的「B ≠ V / committed ≠ A 正規化」(04 跨槽重建,無快照,不做 tar 覆蓋,先 snap 再開始);(b) `pr_begin` 自己接受 committed = B 並走跨槽還原。兩者都要白箱測試:故意把 04 留在 B committed → 下一個 run 的第一個單位 PASS。

### B2. 四個單位的負對照引用不存在的 mutant,而 §4.1.2 禁止其他 mutant 路徑
- **情境**:`prov-netjoin`(helper 接受首版無 owner-op)、`prov-leave-ota`(helper 不刪標記)、`prov-trial-busy`(helper 不看 is-trial)、`prov-claim` 既有負對照(p1-impl §5.3:helper 接受 client 送來的 ClientChal)都寫「bind wbox 的 helper 檔」。§4.2 的變體表只有 `test / rc9-unclaimed / 96-noprov / helper-exit1 / helper-nogen / 96-norestore / radio1-off / chan / helper-flap / misc-*`——**沒有這四個 helper mutant**。§4.1.2 又規定「沒有 mutant 開關(mutant 一律用 `-wbox` 變體或 fakeSys)」,而 fakeSys 只在 CI。
- **證據**:§4.2 表 vs §6.2 四列;§1.2 甲部 1「`-wbox` 變體 build 流程」是封閉清單。`prov-netjoin` 那格自己寫「⚠️ 需要 mutant helper 二進位:用 `-wbox` 的 helper 檔 bind,不另建」——哪一個 `-wbox`?沒有。
- **修**:§4.2 表補 `helper-nojoinop`、`helper-noleave`、`helper-notrial`、`helper-clientchal` 四個 patch(每個一句話 + 哪個單位用),E-H2 量 4 次額外 build 的時間;`lint-wbox` 另加「§6.2 每個引用的 `-wbox` name 都在 `tests/wbox/`」;「必須被接受才算負對照有效」改寫成可判定的斷言(例如 `RESULT net.apply code=0` 且 `prov.meta` state=member)。

### B3. provd 的 frame socket 放在 provd 寫不進的目錄;兩個寫者共用一個目錄
- **情境**:§3 把 `/tmp/run/batman-prov-test/` 定為 **root 0700**(killpoint 的目錄),同一表又說 `gatt.sock` 由 **provd 建(0600,uid provd)** 在同一目錄。uid 471 在 root 0700 目錄裡 `bind()` 必 EACCES。再者 provd 跑在 ujail,只掛 `/tmp/run/batman-prov` 與 dbus socket(`254-stage1-impl.md` §4.7),`/tmp/run/batman-prov-test` 在 jail 裡根本不存在。
- **證據**:§3 第 1 列(root 0700)與倒數第 2 列(provd 建);§4.1.1「目錄 root 0700、非 symlink」;stage1 §4.7。
- **修**:frame socket 另立目錄(建議 `/tmp/run/batman-prov/test.sock`,在既有 jail mount 內;helper 的 socket 目錄清理規則 `sock.go:58-77` 目前「目錄裡有別的東西就拒絕啟動」要改成允許 provd 的 socket,或用第二個目錄 `/tmp/run/batman-provd-test` root:provd 0750 並寫進 P2 的 ujail mount 清單)。§3 寫清楚:killpoint 目錄只有 root 寫、helper 讀;socket 目錄只有 provd 寫。`tmp-trust-allowlist.txt` 各補一行(見 m8)。

---

## MAJOR

### M1. `-wbox` 沒有「mutant 真的在 image 裡」的見證
- **情境**:`build-board.sh --wbox` 先 apply patch 再走既有第 2 步;第 2 步在 feed pin 不符或 `.batman-patched-board` 不符時跑 `openmanet_setup.sh -i`(`firmware-2710/scripts/build-board.sh:86-96`),`-i` 會 reset `feeds/`(同檔 :75 註解)→ mutant 被丟掉。stamp 仍因 `BATMAN_WBOX` env 加 `.wbox-<name>`;gate 的反向檢查只看 `/etc/batman-build` 有 `BATMAN_WBOX=` 行、name 存在、VER 含 `.wbox`(§4.1.3),**沒有一條看 rootfs**。負對照會在 20–40 分鐘的 OTA 週期之後才以「mutant 無效」失敗(只有 autocommit (4) 有前置檢查)。
- **修**:每個 patch 帶見證(同 #275 `Batman-Witness` 做法:patch 檔頭一行 `# wbox-witness: <字串>`,mutant 檔內含該字串);`check-image-manifest.sh --wbox` 在 rootfs grep 到才過;`build-board.sh --wbox` 在 `INIT=(-i)` 時拒絕(或 apply 移到 setup 之後);stamp 斷言 `DIRTY=1`;`prov-254.sh` 推 payload 前 `unsquashfs` 抽那一個檔比見證。

### M2. `prov-powerloss` 的負對照跨不過它自己需要的重開
- **情境**:「`txn-2` 後把 `.txn` 刪掉(bind 空檔)→ 開機不對帳」。`.txn` 在 overlay `/etc/batman-prov/.txn`(`provstore.go:326`);bind mount 是 tmpfs 掛載,`reboot -f` 後消失,真的 `.txn` 又回來 → helper 照 stage1 §4.4 第 6 步對帳 → 負對照 PASS → 無鑑別力。
- **修**:負對照改為真的在 overlay 上 `mv .txn .txn.dv`(快照還原會蓋回),或 `-wbox helper-notxn`。設計加一條通則:**任何觀察點在重開之後的負對照不能用 bind mount**;逐一標示 §6.2 每個 bind 負對照的觀察點在重開前還是後。

### M3. chain 1 / brewrite / pty-commit 不取 prov lease;chain 1 的 deadman 沒人檢查;沒有主機端互斥
- **情境**:第二個操作員或使用者的另一個 Claude session 手動跑 `brewrite-254.sh` 或 `chain1-254.sh`(兩者都寫 `autocommit-hold-commit`、都 `sysupgrade -n`;`brewrite-254.sh:22-23`、`chain1-254.sh`)時,prov 單位正在同一台上跑。chain1 只有主機 `$TEMP/batman-dv-04.lock`(`chain1-254.sh:27`,每個使用者的 temp 不同);daily-validation 沒有主機鎖(h1 §9 殘項)。chain 1 的 deadman 是 B 槽 `rc.local` 一行 + `setsid sleep 1500`(`chain1-254.sh:259`),§3 說「兩者不同時 armed(P9)」但 §4.7 的 P9 沒有任何一條看 `ps | grep 'sleep 1500'`、`/etc/rc.local`、`ch1.cancel/ch1.fired`。
- **修**:本 PR 讓 `chain1-254.sh`、`brewrite-254.sh`、`pty-commit-254.sh` 都走 `pr_begin`/`pr_end` 的 lease(或至少 acquire / release);P9 加「無 ch1 timer、兩槽 overlay 的 `rc.local` 無 `ch1-deadman`、p6 無 `ch1-deadman.sh`」;主機端互斥(每台節點一個 lock,放 `$TEMP` 不夠,改放節點端 lease 即可,但要寫明 lease 是唯一互斥)。

### M4. 上層要求被靜默丟掉(§1.2 / §9 都沒列)
1. p1-impl §2.2 lint 清單:known-failures **第 4 欄到期日**、`ab-shared-change.yml`、`rundir-paths.txt`、`tmp-trust-allowlist.txt`(+ `/tmp/run/batman-dvpc.*`)、P-U10 範圍規則進 `docs/validation`。h23 §2.2 只寫「PAIRS 不變」+ 兩個新 lint。現 `scripts/validation-known-failures.txt` 仍是 3 欄。
2. stage1 §8 的 `prov-sec-helper-uid-254`、`prov-sec-key-perms-254`、`prov-eeprom-hooks-254`、L16 節點層:repo 零命中(`grep -rln` scripts tests .github);h23 沒提。
3. stage1 §8 provd 行為(H3 該測):「health 轉壞 → ≤ 10 s 撤廣播(v16 A-N2)」、「連線建立即撤廣播,斷線後新 nonce 重新註冊(v16 B-m2)」、固定 6 次 PSK 嘗試、`claim/replay` 每小時 10 次(節點全域)經 BLE。§6.3 只有「停 provd → ≤ 10 s 無廣播」,那是另一件事。
4. p1-impl §4.4:單台測項「還原後斷言 02 在 `batctl n`」;雙台 `net.apply`(fleet 實際值經 fd 3,04 先 02 後)。h23 只剩 autocommit (7) 是雙台。
5. p1-impl §5.2 `prov-boot` 的 `ble-ok` 負對照(去掉 `core_freq_min` 的 distroconfig bind,A-m5)。
6. p1-impl §5.6 `settings.set`(hostname → `E_UNSUPPORTED(rename-pending)`、未知 key → `E_SCHEMA`)。
- **修**:每一項要嘛進 §6,要嘛在 §1.2「不在本 PR」逐條列出理由並回報上層 §10。

### M5. `peer.py` 不是獨立的第二裁判
- **情境**:§4.8.1「全部從 `verify.py` import」(dissononce / cbor2 / pycddl / python-ecdsa)。第一裁判(向量 → `verify.py`)與第二裁判(`peer.py` ↔ provd)是**同一份實作**;dissononce 的 bug、`verify.py` 的誤讀,兩個裁判一起錯。真正獨立的是 `gen.py`(`noiseprotocol` + `cryptography`,無 pycose:`grep -c pycose gen.py` = 0)。219 §10 的「兩份實作的裁判是測試向量與對手實作」預期對手與向量產生器不同。
- **修**:D-H3 重新決定:`peer.py` 的 Noise 用 `noiseprotocol`(與 `gen.py` 同、與 `verify.py` 異),或明寫「`peer.py` = `verify.py` 的實作,互打只證明 provd 與 verify.py 一致」。CI 的 `peer.py --selftest` 要對 `gen.py` 的交握 transcript 逐位元組比(不是只對 `verify.py` 的函式)。

### M6. `prov-sec-psk-timing` 的統計沒有鑑別力
- **情境**:PASS = Mann-Whitney p > 0.05(n = 50 / 50)。「不拒絕 H0」不是「相等」;沒有效應量門檻、沒有功效計算;BLE 的抖動是數十 ms,1 ms 的洩漏看不見。負對照 `FAST_FAKE`(立刻斷線)是秒級差異,只證明測法看得出巨大差異。
- **修**:在 sock 傳輸上量(抖動小),第一次跑先量抖動分佈定 n;PASS 條件改為「中位數差 < X ms 且差值 95% CI 落在 ±X」;負對照改成小注入延遲(例如 `BATMAN_PROVD_TEST_FAKE_DELAY_MS=20`,進 §4.8.3 封閉清單);明寫此測不能驗 §3.4 的「假訊息做相同次數 DH」。

### M7. `prov-sec-claim-brute` 的負對照是循環的
- 「`prov_test` 無開關 → 用向量:4 次錯仍連著 = FAIL」是斷言本身,不是負對照。
- **修**:§4.8.3 加 `BATMAN_PROVD_TEST_NO_BRUTE_LIMIT=1`(或在 CI `peer-vs-provd` 以 mutant build),否則明列「無負對照」。

### M8. `prov-sec-dbus` 的工具與前提沒定義
- `provclient sock-as 471 -- exec dbus-send …`:`exec` 不在 §4.6 的動詞清單(只有 `sock-as <uid> -- <op>`,op 是 provclient 自己的動詞)。`Device1.Disconnect → 成功` 要有一個已連線的 device 物件 → 需要 02 連著,但該測項標 tier A(無 02)。
- **修**:§4.6 加 `exec`(argv 原樣、清 env、無 stdin、降權後 `execve`);`Disconnect` 正向與「bluetoothd → provd 回呼」移到 tier B;dbus-send 的動態連結依賴(libdbus-1 在節點上有,因 bluez-daemon 依賴 dbus)在 E 實證列一條。

### M9. `prov-sec-bond` 翻轉段在 P2 之後做不到
- **情境**:04 掛 `bluetoothctl agent NoInputNoOutput` 常駐 → 04 的 current settings 出現 `bondable`(stage1 §9:互動式 bluetoothctl 註冊 agent,04 實測)→ helper health `bondable=1` → provd fail-closed 在 ≤ 10 s 內**撤廣播**(stage1 §8 v16 A-N2)→ 02 找不到 04,配對沒得做。§3 又規定 provd 存活時 `adv-on` 拒絕。
- **修**:翻轉段先停 provd、以 `ble-periph adv-on` 廣播(同 H1 程序),測完 `rekey` + 重開(H-U6);§6.3 寫明這一段是在「provd 停止」的模式,與 §3 一致。

### M10. `ble-rpa-254` provd 模式的時間軸不成立
- F28:provd 在 `rpa_timeout` + 30–120 s 重新註冊,**且**每次連線 / 斷線、health 翻轉都重新註冊並換 nonce(stage1 §8 B-m2)。h23 要「量 provd 的實際週期並斷言 ≥ 900 s 才換」,但任何一次 02 連線、health 抖動都會提前換 RPA → 假 FAIL;N1 負對照(≥ 30 分不重新註冊 → 同 RPA)在 provd 活著時做不出來。
- **修**:provd 模式只量「RPA 改變 ⇔ provd 重新註冊事件」(需要 provd 一行可解析的 log,寫進 P2 契約),N1 負對照 = 停 provd + 既有 `adv-on`。

### M11. frame socket 與 §8 限制的關係沒定義 → `prov-sec-hog`、`prov-two-phones` 量到的是接縫不是產品
- 「3 個 central(2 × sock + 1 BLE)→ 第 3 個被拒」預設 sock 連線算進「同時 BLE 連線 2」(219 §8);「未交握 10 s 斷」對應的是 §8「交握逾時 10 s」還是「未認證 session 閒置 30 s」沒說。`prov-two-phones` 期望 `E_STATE`——219 §5.2 沒有這個碼(只有 1–13)。
- **修**:§4.8.2 寫明:一條 sock 連線 = 一條 BLE 連線,所有 §8 計數器相同;`CTRL`/`STATUS` 讀取對應特徵讀取 handler;並列每個測項對應的 §8 列。兩支手機同時認領的第二個回應改用協定既有碼(`E_BUSY` 7 或 `E_CLAIM_FAILED` 9),引用 §5.2。

### M12. 判定字串與原始碼不符(正確的產品會被判 FAIL)
| 設計 | 原始碼 |
|---|---|
| autocommit (9)「`HELD` + `WARN health-stale`」 | 沒有這個字串。只有 `WARN ble: ble-ok present but BLE health is not good (...)`,**且只在 `ble-ok` 存在時**才 log(`batman-autocommit:496-499`);無 `ble-ok` 什麼都不印。(9) 沒寫 `ble-ok` 前置 |
| `prov-ota` 證據「helper log『overlay prov from 96』」/ 負對照「『restored from p5』」 | 96 寫的是 `prov: state=<st> copied=<none\|record\|full\|copy-failed\|bad>`(`96-batman-provision-lockdown:168`)與 `/etc/.batman-prov-restore` 的 `prov=$PCOPY`(`:113`);「restored from p5」只在 root 密碼那一行(`:193`)。helper 端沒有「from 96」字樣(`boot.go` 零命中) |
| `prov-sock`「未知動詞 / 多餘欄位 → `E_SCHEMA`(21)」 | `ESchema = 20`,`EApply = 21`(`node.go:41-42`) |
| `prov-sock`「`sock-as 65534`(nobody)→ 連線被關(`EOF` 或 `ECONNRESET`)」 | socket 目錄 root:provd 0750、socket 0660(`sock.go:2-3, 41-55`);uid 65534 無 gid 471 連 `connect()` 都到不了(EACCES),只有 `--gid 471` 那一列才會走到 PEERCRED 關連線 |
- **修**:每個以 log / 碼判定的單位列一張「確切字串 / 碼 → 檔:行」表(同 F11 做法),實作時 `grep` 原始碼取字串。

### M13. 供應鏈列的擋法只擋 `wbox`,不擋「只有 `prov_test` tag」的 image
- §7「供應鏈」:gate + release-scan + P9 拒 wbox + `.dirty`。但 `BATMAN_PROV_TEST=1` 而未設 `BATMAN_WBOX` 的 build(手動 `make`,沒跑 `check-image-manifest.sh`)VER 沒有 `.wbox`、`/etc/batman-build` 沒有 `BATMAN_WBOX=`,P9 的三條都看不出來。
- **修**:tier A `prov-boot-254` 每天斷言 `batman-provhelper --version` 第 2 行**沒有** `BATMAN_PROV_TEST_BUILD_7f3a`、helper 二進位 `grep -c` = 0;P9 同。

### M14. `release-scan.yml` 不掃 release asset
- §4.1.3「release-scan 對 release asset 也掃一次(同三條)」。現行 `.github/workflows/release-scan.yml` 只在 tag push 對**原始碼樹**跑 dependency-check + SBOM,沒有下載任何 asset,且 tag push 時 asset 通常還沒上傳。
- **修**:新 job on `release: published`,`gh release download` payload → unsquashfs → 三條檢查;或刪掉這句,明寫只靠 firmware gate + P9 + M13。

### M15. prov deadman 的「啟動 joinwatch」會毀掉 harness 自己的還原
- **情境**:單位 ≤ 3000 s,但不 hold 的 autocommit 單位要等 600 s 期限 + OTA + restore(p5 dd + overlay + reboot + brewrite ≈ 15–20 分)容易貼近上限;lease 到期 → deadman 起 joinwatch。`chain1-254.sh:135-137` 的註解正是這個事故:joinwatch 的 `--on-join` 把 A 的 live root line 存進剛還原的 p5 → S0 compare diffs=3。§5「restart(harness 死)」列沒有「harness 死在 restore 途中」這條。
- **修**:`restore` 開始前先延長 lease(並在 §4.3 寫明每步的 lease 預算);deadman 看到 `dv-prov-dirty` 的 run 正在 restore(`prov-base-254.sh` 留 `restoring` 標記)時只做 unbind + 重啟 helper,不起 joinwatch;生命週期矩陣補「harness 死於 restore 的 dd / overlay-restore 中」+ 白箱測試。

### M16. killpoint 在 helper 記憶體裡 armed,但 P9 / deadman 只看檔案
- **情境**:`arm-killpoint` → helper restart 讀檔並**刪檔** → harness 在觸發前死掉。helper 仍 armed;prov deadman「重啟 helper」只在 lease 到期後;下一次 run 的 P9 看 `/tmp/run/batman-prov-test/` 不存在 → 過;下一個單位的 `net-apply` 撞到 `txn-2` → 節點 `reboot -f`,歸因錯誤。
- **修**:`arm-killpoint` 把 `armed <name>` 記進 `wbox.list`,`unbind-all`(deadman、`pr_end`、P9 的 restore 指令)看到就重啟 helper;P9 加「helper 本次啟動的 log 沒有 `killpoint … armed`」。

### M17. `ble-periph adv-on` 在檢查前就 `rm-adv 1`
- §3 / §4.7 說 provd 存活時 `adv-on` 要 FAIL(`adv_instances ≠ 0 → die`)。現行 `cmd_adv_on` 第一個動作是 `mg rm-adv 1`(`ble-periph-254.sh:45`),再 add、再數 instances。P2 後這會先**撤掉 provd 的廣播**才報錯。
- **修**:設計寫明 instances 檢查在 `rm-adv` 之前,且 provd 存活(`/etc/init.d/batman-provd running`)時直接拒絕;附白箱測試。

---

## MINOR

### m1. 事實計數錯
- F3「12 個」但列了 13 個名字(ble ×4、prov-tools、addr-defer、prov-lock-rest、prov-p1-stubs、setsid-race、prov-claim、adr-reconcile、chain1、pty-commit)。
- F21「6 行」實為 7 行(`validation-known-failures.txt`:prov-p1-stubs ×3、prov-lock-rest、setsid-race、prov-claim、chain1)。移除清單要列全;第一行 `product in this checkout is pre-P1` 是否也移除要說。

### m2. `NEEDS-PERSON` 的 rc 2 契約沒落地
- `suite()`(`daily-validation.sh:77-99`)把 rc 2 當 FAIL 照跑下去,沒有「之後不跑 prov tier B」的機制。設計要寫:誰設旗標(`$DIR/needs-person.txt`)、prov 區塊每個 suite 前讀、rc 2 在 `suite()` 的意義(或改 rc 1 + 檔案)。known-failures 拒絕「restore failed」類 pattern,所以 NEEDS-PERSON 永遠是 NEW,要在報告段寫明。

### m3. `prov-p1-stubs` 的 killpoint 檔案契約測試跑不起 daemon
- helper `main()` 非 root 直接 exit 2(`main.go:375-378`),又寫 syslog、要 `/tmp/run/batman`。改為 Go 單元測試(`-tags prov_test`,temp dir 注入目錄路徑)+ release tag 的 no-op 測試。

### m4. `pre-P1b image` 的偵測方式沒寫
- wsl.4 的 helper 沒有 `--version` 模式(usage、exit 2,`main.go:404-406`)。每個單位要用什麼指令判「沒有接縫」才印那唯一一行 FAIL(known-failures 要求整個 suite 只有相符的 FAIL 行)。

### m5. `prov-provd-dos` 的前提錯
- 超大訊息依 §8 是**斷線**,不是 crash provd。DoS 測項 = 反覆連線 / 超大訊息下 provd 不掛、`HELD`;respawn 用 `kill` 或 P2 的 crash seam。另 `prov-respawn`「退避遞增」:procd `respawn 3600 5 0` 是固定 5 s(`batman-provhelper.init:13`;stage1 §4.7 的 provd 同),退避是 provd 自己的,觀察點要寫。

### m6. `prov-coex` 缺 AP 客戶端與基線程序
- iperf 經 AP 的客戶端是誰(主機 Wi-Fi?02?)沒寫;D-H6「第一次只記錄」與 §6.3 的 30% FAIL 門檻、known-failures 無法表達「記錄不判」三者要對齊。

### m7. UUID 廣播預算現在就能算
- legacy adv 31 B:flags 3 + 128-bit service UUID 18 = 21,剩 10 B 給 B16 的 nonce + 旗標;要嘛 service data 進 scan response,要嘛 16-bit。§4.9 不該「本 PR 不改 B16,只記 ⚠️」,算一次寫進 §4.9 給 P2。

### m8. tmp-trust allowlist 第 99 行會把新路徑「順便」放行
- `feed/batman-prov/src/*	/tmp/run/batman-prov`(無邊界)對 `/tmp/run/batman-prov-test/...` 也命中,新路徑在沒有理由的情況下通過 lint。harness PR 先把該行收緊為 `/tmp/run/batman-prov([^-]|$)`,再為 killpoint 目錄與 frame socket 目錄各加一行(理由寫清)。這兩行屬 harness PR(一套測項規則),§2.2 要列。

### m9. 沙箱契約小缺口
- `--mount-proc` 掛的是新 ns 的 `/proc`,`chroot $SBX/root` 之後 chroot 內的 `/proc` 是空的,要 bind;`losetup -f` 必須在進 ns / 丟 `cap_mknod` 之前於宿主做,`mmcblk0p5` 以 mknod 指到該 loop——寫成步驟順序。`ip link add dummy0 → 宿主看不到` 在 netns 裡恆真,不是 capability 負測試,改成 `ip link add` 成功但宿主 `ip link` 無(證 netns)+ 另一條 `CAP_NET_ADMIN` 相關。

### m10. `prov-artifact-match` 的重建旗標不完整
- Makefile `GO_PKG_LDFLAGS:=-s -w`;`golang-package.mk:239-260` 另加 `-extldflags`(TARGET_LDFLAGS)、`all=$(GO_PKG_DEFAULT_LDFLAGS)`、`-buildvcs=false -trimpath`、`-tags`。§4.4 列的旗標少了前兩項;E-H4 要記錄實際用的整串。

### m11. `provgen.py` 的金鑰檔格式沒定
- 「金鑰由 `provclient keygen` 產,provgen 只收私鑰路徑」:`keygen` 的檔案格式(PEM? raw 32 B?)與 pycose 讀法要寫;`provgen.py --selftest` 要用 `vectors.json` 的固定金鑰(格式同上)。

### m12. Windows 端 `peer.py` 依賴未證
- F13 只證「沒有 bleak」。`verify.py` 的 `pycddl`(Rust wheel)、`pycose`、`dissononce` 在 Windows Python 3.12/3.13 能否裝,E-H1 一併做;否則 `transport_ble.py` 的 import 要延後,`peer.py --selftest` 不得因 bleak 缺而失敗。

### m13. 生命週期矩陣 / 擁有權表缺列
- 矩陣缺:harness 死於 restore 途中(M15);兩個 harness 同時(只有 lease 一句,M3);產品自己的重開(joinwatch 3600 s、autocommit 期限)打斷單位;`prov_test` build 被 pin(M13)。
- 擁有權缺:B 槽 overlay 的 `/etc/rc.local`(chain 1 寫)、p6 `autocommit-hold-commit`(`pr_ota_b`、brewrite、chain1、pty-commit 四個 harness 寫者 + autocommit 消費者)、helper 記憶體內的 killpoint arm(M16)、`~/out/<VER>`(firmware build 寫、harness 讀)、`feeds/batman` 工作樹(`build-board --wbox` 寫 / 還原)。

### m14. 其他小點
- `prov-boot-254` 負對照「停 helper → stale」是 health 檔 > 60 s 的 stale(`health.go:8`),寫明等待時間。
- `prov-gatt`「`CTRL` / `STATUS` 不加密旗標(bleak 讀特徵屬性)」:bleak 回的是 properties(read/write/notify),**不是** BlueZ 的 `encrypt-read` 旗標;要從 02 端 `bluetoothctl` 的 `Flags` 或 provd 的 D-Bus 物件讀。
- §6.3 `prov-firstboot-254`「1.5.12 新卡 → 無廣播」負對照需要重燒卡(不是 OTA),與「無人值守」衝突,標手動。
- OTS 容器列(§7 沒列的 actor):deploy/ots 沒有 `/dev/log` bind、容器只掛 `/opt/batdata/apps/<tenant>`,碰不到 `/tmp/run/batman-prov-test` 與 `/opt/batdata/state`;要寫一行,附 grep 證據。

---

## 假設驗證表

| # | 設計主張 | 結果 | 證據 |
|---|---|---|---|
| F2 | H2 實際交付清單 | ✅ | `scripts/dv/`、`scripts/node/` 目錄;`prov-p1-254.sh` 只在 `rundir-paths.txt` / 無 suite 接線 |
| F3 | 12 個 #254 suite | ⚠️ 計數 13 | `daily-validation.sh:214,227-295` |
| F4 | 鏈 1 R 類 = p5-restore → overlay-restore → brewrite | ✅ | `chain1-254.sh:122-176` |
| F5 | E4 未做;overlay-allow 3 條 | ✅ | `tests/prov-p1/overlay-allow.txt`;p1-impl §13 |
| F6 | payload 只 SHA256SUMS 無簽章 | ✅ | `platform-ab.sh:12,156,329`;`batman-slot:591-600` |
| F7 | stamp VER 規則、DIRTY、`GO_PKG_TAGS` | ✅ | `stamp-batman-build.sh:44-62`;`golang-package.mk:106-111,260` |
| F8 | helper CLI、Sys 20 方法、commitTxn | ✅ | `main.go:373-407`;`node.go:63-83`(20 個);`txn.go:16-34` |
| F9 | provclient 動詞 | ✅ | `provclient/main.go:489-558` |
| F10 | autocommit 接縫 | ✅ | `batman-autocommit:26-28,44-60,97-100,151-165,260-282` |
| F11 | chanfix 兩行 | ✅ | `99-batman-chanfix:47,53` |
| F15 | verify.py 661 行、無 main、MIN_CHECKS=195 | ✅ | `verify.py:16-42`;`ci-check.sh`;`ci.yml:45` |
| F16 | 無 provd / Noise;go.mod 只 x/crypto | ✅ | `go.mod`;`proto.go:1-25` |
| F18 | BLE harness 基礎 | ✅ | `ble-periph-254.sh:42-52,195-205`;`ble-lib-254.sh:84-134` |
| F19 | prov-lib / brewrite | ✅ | `prov-lib-254.sh:21-108`;`brewrite-254.sh:5-39` |
| F20 | find04、ch1-deadman 一次性只在 B | ✅ | `chain1-254.sh:70-82,205-221,259` |
| F21 | known-failures 6 行 | ⚠️ 7 行 | `validation-known-failures.txt` |
| §4.1.2 | helper 只收 provd uid、單連線 | ✅ | `sock.go:2-3,107-131` |
| §4.5 | `E_SCHEMA` = 21 | ❌ 20 | `node.go:41-42` |
| §6.2 (9) | `WARN health-stale` | ❌ 不存在 | `batman-autocommit:496-499` |
| §6.2 prov-ota | 「overlay prov from 96」/「restored from p5」 | ❌ 不存在 | `96:113,168,193`;`boot.go` |
| §4.3 | 02 joinwatch 3600 s | ✅ | `joinwatch:20,37` |
| §4.3 | prov tier B 在 2g 之後可行 | ❌ | `pty-commit-254.sh:14`;p1-impl §4.5.0 |
| §4.1.3 | release-scan 掃 asset | ❌ | `release-scan.yml`(只掃原始碼,tag push) |
| §4.2 | build-board 既有第 2 步不動 feeds/batman | ⚠️ 會 | `build-board.sh:86-96`(`-i` reset feeds) |
| §4.4 | runner 有 util-linux / libcap2-bin | ⚠️ 未驗 | E-H3 |
| §4.8.2 | frame 格式 | ✅ 同 219 §4.1 | `219-protocol.md:136-152` |
| §6.3 hog | 「未交握 10 s」 | ⚠️ 219 §8 有 10 s 交握逾時與 30 s 閒置兩條,未指明 | `219-protocol.md:370-386` |
| §6.3 two-phones | `E_STATE` | ❌ 無此碼 | `219-protocol.md` §5.2 |
| §3 | provd ujail 只掛 `/tmp/run/batman-prov` | ✅(→ B3) | stage1 §4.7 |
| F1, F12, F13, F14, F17, F22, F23 | 節點 / 主機 / GitHub 現況 | ⚠️ 本審查唯讀、未上機,未驗 | — |
| §4.8.1 | `verify.py` 改 `def main()` 後 checks 不變 | ⚠️ 設計層可行,CI 負對照已設計 | `ci-check.sh` |

## 範圍對照(p1-impl §5 / stage1 §9)
- 涵蓋:§5.1 全部、§5.2、§5.3 全部(含 F→R 的改寫)、§5.4 鏈 0、§5.5 (1)(3)–(10)、§5.6 大部分、§5.7 的 H2 列;stage1 §9 tier A/B/destructive 的 prov-* 列(rename 以 U5 明列殘項 ✅)。
- 靜默丟掉:見 M4 六項。
- 多出且未說明理由:`prov-sec-psk-timing`(上層沒有;可留,但要有 M6 的統計定義);`ble-rpa-254` provd 模式(h1 §9 要求「決定」,可;但 M10)。

## 結論

**REJECT**(BLOCKER 3 / MAJOR 17 / MINOR 14)。B1–B3 任一都讓本 PR 的主要交付(無人值守全套、負對照、`peer.py` 傳輸)照 v1 做不出來;M1、M2、M12 會在第一次全套就製造錯誤歸因。修完請整份再審(含 §3 擁有權表與 §5 矩陣的補列)。
