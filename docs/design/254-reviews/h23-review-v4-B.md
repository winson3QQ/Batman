# 審查 B(第 4 輪):`254-h23-harness.md` v4(2026-10-28,唯讀;未碰 02 / 04)

審整份 v4(乾淨全文,37b62e8)。順序:§3 / §5 缺列與雙寫者 → 真實跑法(22 h 無人值守、每個階段 harness 死、兩個操作員、主機藍牙關、CI arm64 排隊與底 rootfs 來源)→ §1.3 F1–F41 與 §4–§6 每個判定字串 / 錯誤碼 / 行號對原始碼(Batman-h23 工作樹;firmware-2710 工作樹含 `root-bcm27xx` staging rootfs、bluez-5.72、kernel 6.6.138 原始碼、`package/base-files`)→ §7 逐 actor → 負對照逐條 → 契約逐條 → §4.9 預算 → 範圍對 p1-impl §5 / stage1 §8–§9 → 最後逐條核對 v3(A 與 B)每個發現。本輪另以 `gh` 唯讀查了 `winson3QQ/firmware` / `winson3QQ/Batman` 的可見性與 release 資產(F18 / D-H11)。

## 摘要

v3 的 A 7 MAJOR / B 6 MAJOR 與全部 MINOR 都有處置,字串與行號面(F8、F9、F11–F15、F20、F22、F23、F25、F29–F31、F33、F34、F36–F41)逐字對上;`chan` 改 init 迴圈、(8) 三臂、(10) L41、`helper-norebuild`、lease / deadman 契約、`prov-sec-sockdir` 都成立。還有 3 個會讓一個 CI job 或一個測項做不出來 / 無鑑別力的問題,全部不動架構:

1. **沙箱底 rootfs 的來源不存在**(M1):`winson3QQ/firmware` 是 PUBLIC(F18 ⚠️ 可清),但它唯一的 release 是 Draft `fw-build-108-final`,資產全是上游 OpenMANET 1.8.0 image;Batman 的 A/B payload 在 **Batman repo** 的 releases(最新 v1.5.11),且 `1.5.14-wsl.4` 沒有任何 release 資產。§4.4.1 照寫會下載不到東西。
2. **tmp-trust 收緊會把 `chain1-254.sh` 打紅**(M2):`chain1-254.sh:112,315` 用的是固定名 `/tmp/run/batman-dvpc/`(無 run id)+ `mkdir -p`,今天靠第 13 行無邊界 regex 過關;v4 的新 regex 不再吃它,新條目又只給 `prov-lib-254.sh` 且 pattern 是 `batman-dvpc\.`。這一行同時就是 §4.5 dvpc 負測試要擋的「放置缺陷」。
3. **`prov-gatt-254` 的旗標判定恆 PASS**(M3):BlueZ client 端的 `Flags` 只會列 8 個 property + 2 個 extended property(`src/gatt-client.c:814-830`);`encrypt-*` / `authenticated-*` 只在 server 端 app 的宣告裡存在(`src/gatt-database.c:1760-1833`)。02 永遠看不到那些字,「無 encrypt-* → PASS」沒有鑑別力。

BLOCKER 0、MAJOR 3、MINOR 15。**APPROVE-WITH-CHANGES**(M1–M3 都是局部改寫;收完 v5 可由一位做窄範圍複查)。

---

## MAJOR

### M1. §4.4.1 / D-H11:底 rootfs 的 release asset 在 Batman repo,不在 firmware repo;`1.5.14-wsl.4` 沒有 release 資產
- **情境**:`prov-sandbox` job 開頭 `curl` `base.env` 的 `BASE_URL`(= 「firmware repo 的 release asset payload tar」,「本 PR 時 = 1.5.14-wsl.4 的 release asset」)→ 404 → job 永遠紅(E-H3 前 `continue-on-error` 把它藏成 annotation),沙箱矩陣一個案例都跑不到。
- **證據**(`gh`,2026-10-28 唯讀):`gh repo list winson3QQ` → `firmware` PUBLIC、`Batman` PUBLIC;`gh release list -R winson3QQ/firmware` → 只有 `fw-build-108-final`(**Draft**,2026-09-29),資產 = `openmanet-1.8.0-rpi4-mm6108-*-squashfs-sysupgrade.img.gz` 等上游 image + `sha256sums-ekh-bcm27xx.txt`,沒有 Batman payload;`gh release list -R winson3QQ/Batman` → v1.5.11(Latest)資產 `batman-1.5.11-rel.1+6a049f2.fw7049fd8-ekh-bcm2711-ab-payload.tar.gz`(122 441 671 B)、`…-ab.img.gz`、`SHA256SUMS`;`gh release view v1.5.14` / `1.5.14-wsl.4` 兩邊都 `release not found`。§1.2「release asset 由 firmware CI 產」與此不符。
- **修**:`base.env` 指向 Batman repo 的 v1.5.11 payload(公開、直接 `curl`,sha 釘 `SHA256SUMS` 那行);沙箱只用它的 busybox / uci / 基底,P1 `files/` 由 PR 蓋上、helper 現編,所以 rel.1 當底可用;若一定要 wsl.4 底,先在 Batman repo 發一個 pre-release 資產。F18 改寫「firmware PUBLIC,但 payload 資產在 Batman releases」;`secrets.FIRMWARE_READ_TOKEN` 那條刪;E-H3 只剩 arm64 排隊時間與 busybox ash。

### M2. tmp-trust 收緊讓今天的 allowlist 不再通過(`chain1-254.sh:112,315`);且該行是固定名 + `mkdir -p`
- **情境**:harness PR 的 CI `tmp-trust` 紅燈;更重要的是 chain1 的 provclient 放置用固定名 `/tmp/run/batman-dvpc`(無 run id)+ `mkdir -p -m 0711`:已存在(含 symlink)不拒 → 正是 §4.5 `prov-sec-dvpc-254` 宣稱「機制已在:`mkdir` 無 `-p`」要擋的放置缺陷,但只對 `prov-lib-254.sh:92` 成立,對 chain1 不成立。
- **證據**:`chain1-254.sh:112` `"/tmp/run/batman-dvpc/provclient node $*"`;`:315` `fq "mkdir -p -m 0711 /tmp/run/batman-dvpc"`(`mkdir +-p +/tmp/` 本身也是 `PAT` 的一個 hit,`check-tmp-trust.sh:23`);`prov-lib-254.sh:20` `PCD=/tmp/run/batman-dvpc.$RUN`、`:92` `mkdir -m 0711 $PCD`;allowlist `:13` `scripts/*	(/tmp/run/batman-dv|…)` 以 `sed -E s///g` 切掉命中(`check-tmp-trust.sh:55`),所以 `batman-dvpc/` 今天被切成 `pc/provclient` 而過關。v4 §2.2 的新 regex `/tmp/run/batman-dv([^-a-z]|$)` 對 `batman-dvpc/` 不命中(`p` ∈ a-z),新條目 `scripts/dv/prov-lib-254.sh` + `batman-dvpc\.` 對 chain1 的 `batman-dvpc/` 也不命中 → 兩行 UNTRUSTED。`test-tmp-trust.sh:18` 的「clean tree passes」案例會抓到。
- **修**:(a) chain1 改走 `prov-lib-254.sh` 的 per-run `$PCD`(`mkdir -m 0711`,無 `-p`,EEXIST 即拒)並在單位收尾 `rm -rf`;或 (b) 至少把 `:315` 改成 `mkdir -m 0711 /tmp/run/batman-dvpc.$RUN`。§2.2 條目改為 `scripts/dv/prov-lib-254.sh` **與** `scripts/dv/chain1-254.sh` 的 `/tmp/run/batman-dvpc\.`;理由欄寫「root 0711、`mkdir` 無 `-p`」;§4.5 dvpc 那句「機制已在」限定到 `pl_prep`。

### M3. `prov-gatt-254` 的「02 `gatt.attribute-info` Flags 無 `encrypt-*` / `authenticated-*`」沒有鑑別力
- **情境**:stage1 §8(v16 A-N7)要求「GATT 特徵不帶任何 encrypt / authenticate 旗標(PR-P2 斷言)」;v4 §6.3 以 02(central)讀遠端特徵的 `Flags` 來斷言。
- **證據**:`bluez-5.72/src/gatt-client.c:814-830`:遠端特徵的 `Flags` 來自 `chrc_props[]`(`broadcast`、`read`、`write-without-response`、`write`、`notify`、`indicate`、`authenticated-signed-writes`、`extended-properties`)+ `chrc_ext_props[]`(`reliable-write`、`writable-auxiliaries`),由 characteristic declaration 的 property 位元映射;`encrypt-read` / `encrypt-authenticated-*` 等字串只在 `src/gatt-database.c:1760-1833`(server 端解析 **本機** app 宣告的 flags)。安全需求不在 declaration 裡,server 以 ATT 錯誤(0x05 Insufficient Authentication / 0x0F Insufficient Encryption)在存取時才表達。`client/gatt.c:3213` 印的就是這個 D-Bus `Flags` 屬性。
- **修**:判定改為行為:02 未配對、未加密下 `gatt.read` CTRL / STATUS 回資料、`gatt.write` RX 成功(btmon 整段無 `SMP` 交換、無 `LE Start Encryption`);負對照 = provd 白箱(`prov_test` 開關或 bind 一個把 CTRL 宣告成 `encrypt-read` 的 fake GATT app)→ 02 讀到 `org.bluez.Error.NotPermitted` / ATT 0x0F 且 btmon 出現 SMP 請求。§10 第 3 點給 P2 補這個開關。

---

## MINOR

### m1. CI `sudo -E … go test` 會 `go: command not found`
Ubuntu runner 的 sudoers 有 `secure_path`,`-E` 保留環境變數但 **PATH 仍被重設**;`actions/setup-go` 把 go 放進 `GITHUB_PATH`,不在 secure_path。寫成 `sudo -E env PATH="$PATH" GOFLAGS=-mod=vendor GOTOOLCHAIN=local go test -v -tags prov_test ./...`(或 `sudo -E "$(command -v go)" …`)。另 `grep -c -- '--- SKIP'` 計 0 時 rc 1,斷言要寫 `[ "$(… | grep -c -- '--- SKIP' || true)" = 0 ]`。`ci.yml:74` 現況 ✅(非 root、無 `-tags`)。

### m2. §6.3 `ble-rpa-254` 引的 F28 不是本文的 F28
本文 F28 = 「04 S0 = 現況」;「無重註冊不換 RPA、900 s」的證據在 **stage1 F28**(`mgmt.c:1016-1029`:`rpa_expired()` 設 `HCI_RPA_EXPIRED` 後,`HCI_ADVERTISING` 未設即 return;本輪複驗 ✅)。改引 stage1 F28;三態本身正確。

### m3. (8) 臂 C 的「OTA 前 `ble-ok` 已移除」沒寫「停 helper 並保持停到 `sysupgrade -n`」
F14:committed 槽的 helper 15 s 內寫回 `ble-ok`(`health.go:151-156`)。臂 B 寫了停 helper,臂 C 沒寫;實作漏掉 → 臂 C 的 trial 第一次 poll 就印 WARN 並 latch(`batman-autocommit:496-499`)→ 臂 C ≡ 臂 A。補「同臂 B 的移除程序」。

### m4. `unsquashfs -cat -` 不吃 stdin
squashfs-tools 4.6.1(WSL `unsquashfs -help`):`unsquashfs [OPTIONS] FILESYSTEM [… -cat]`,FILESYSTEM 是要 `lseek` 的檔案參數。§4.2 `pr_ota_b` 與 §2.2 `dv-prov-tools.sh` 要先 `tar -xzf <payload> -C <mktemp -d> root.squashfs` 再 `unsquashfs -cat <file> etc/batman-build`(`build-board.sh:162` 就是這樣用)。payload 內名稱 `root.squashfs` ✅(`build-ab-payload.sh:61,73`)。

### m5. `prov-sec-psk-timing-254` 的 n 公式永遠被下限 30 綁住
門檻 = 2·MAD 時 n = (1.96·1.2533·√2·1.4826 / 2)² ≈ 6.6;門檻 = 5 ms(MAD < 2.5 ms)時更小。n 實際恆為 30(可接受:n = 30 時中位數差的 95% CI 半寬 ≈ 0.94·MAD < 2·MAD)。寫明「n = 30 除非 MAD 極端」,或把 CI 半寬目標設為門檻 / 2 讓公式有意義。節流 ≤ 18 / 分 < 219 §8 全域 20 / 分 ✅;錯 PSK 沒有額外 lockout(§3.4 / §8)✅。

### m6. `provd.env` 的「只在 `prov_test` 才讀」沒有機制
§4.1.2 (4) 寫「provd 讀」,§4.8.3 寫「init 讀,以 `procd_set_param env` 傳」。init 是 shell、沒有 build tag;provd(uid 471)讀不到 root 0600 檔,所以只能是 init。定為 Makefile `ifeq ($(BATMAN_PROV_TEST),1)` 安裝 `batman-provd.init.test`(release 安裝的 init 沒有那段),並把 gate 的 `grep -rl` 加上 init 內的字串;寫進 §10 第 3 點給 P2。

### m7. `prov-sec-dbus-254` 的 471 期望值依賴 stage1 §4.6 的 provd policy,本文沒引
stage1 `:308`:provd policy 每條 allow 同時寫 `send_destination` + `send_interface` + `send_member`(`LEAdvertisingManager1.{Register,Unregister}Advertisement`、`GattManager1.*Application`、`ObjectManager.GetManagedObjects`、`Properties.{Get,GetAll}`、`Device1.Disconnect`),其餘 deny。所以 P2 後 uid 471 的 `Introspect` **仍** AccessDenied(policy 沒有 `Introspectable`),這不是工具壞 → root `Introspect` 前置有意義,但 tier A 的 471 正向對照應該用 `Properties.Get`(policy 放行的那個),不是 Introspect。F16 的「連 Introspect 都 AccessDenied」加「P1 期;P2 後亦然」。staging `bluetooth.conf` 只有 root policy ✅。

### m8. (10) L41 的「容器 root」臂到不了 `_ab_arm_mesh` 的 pid-ns 檢查
`platform-ab.sh:104-109`:caller `/sbin/procd*` + `$RAM_ROOT/sbin/upgraded` + `_ab_live_sysupgrade`。OTS 容器沒有 `/lib/upgrade`、`/tmp/run`、p6 bind(F35),從容器呼叫根本沒有 `platform_check_image` 可呼叫;節點無 `unshare`(F16)。要打到 pid-ns 這條,得 `docker run --rm -v /lib/upgrade:/lib/upgrade:ro -v /opt/batdata:/opt/batdata -v /tmp/run:/tmp/run busybox sh -c '. /lib/upgrade/platform.sh; …'`(容器內 uid 0、`/proc/<pid>/ns/pid` ≠ host)並斷言 p6 無 `ota-armed.mesh`。寫明做法與副作用(臨時容器)。

### m9. `dm_arm` 的第 3 參數要是節點上的檔案;`prov-base-254.sh` 今天由 stdin 送
`ble-lib-254.sh:121` `setsid sh "$3" dm-fire …`;`prov-lib-254.sh:24` 的 `nb` 以 `ssh sh -s < prov-base-254.sh` 送。每次 `pr_find` 後重新 `dm_arm`(§4.3)之前,要先把 `prov-base-254.sh` 重新 stage 到 `$DVD/<run>/`(root 0700,重開即消失)。§3 / §4.3 補一句。

### m10. `chan` 前置斷言的單次取樣會誤判
chanfix(`99-batman-chanfix:43-55`)與 `wbox-chan` 兩個迴圈互改,某一瞬間 `uci get wireless.radio1.channel` 可能剛好是 p5 值(≤ 8 s 窗);「120 s 內 ≠ p5」以一次取樣判會假 FAIL「mutant 無效」+ `back_to_a`。改為 120 s 窗內連續 3 次(間隔 10 s)皆 ≠ p5,或取 120 s 末端(chanfix 最晚 ~128 s 結束,`wbox-chan` 到 200 s)。

### m11. §3 缺 `ble-ok` 列
寫者:helper health(只在 committed 槽,`health.go:151`)與 harness `state-set`((8) 臂 B / C)。規則要寫死:harness 只在 helper 停止狀態或 trial 內寫;restore 由 `STATEFILES` 放回(`prov-base-254.sh:29`)。

### m12. §5 缺「trial 內節點 kernel panic / 硬重開」列
#132 Morse churn 下 panic 是已知現象。trial 內 panic → tryboot 一次性 → 直接回 A committed:無 `TRIAL-REVERTED`、無 `bad-slot`、hold 旗標已被消費。預期 REVERT 單位等 720 s 逾時 → `pr_abort`;要以 boot-reasons(`panic` / watchdog)區分,免得歸因成「mutant 無效」。

### m13. 第 99 行收緊 `/tmp/run/batman-prov([^-]|$)` 與第 13 行不一致
`batman-provd-test` 的下一字是 `d`,仍被切掉;新條目因此永遠不會被需要。改成 `([^-a-z]|$)`(與第 13 行同形)。Go 原始碼今天只有 `main.go:40`、`sock.go:2` 兩處 ✅,都是 `/` 或 `"` 接續,不受影響。

### m14. HOLD-COMMIT-DISCARDED 的視窗比「落點斷言」早
`batman-autocommit:270-291`:旗標只在 `want == $(version)`(`/etc/batman-build` 的 `BATMAN_VERSION`)時成立,否則 DISCARDED 並刪旗標;member 臂 NEED_MESH=0 時 commit 只要 3×10 s 健康(`:30-31`)。`pr_find` 找到 trial 至少 60–90 s,落點斷言太晚。寫死:hold 值 = payload `etc/batman-build` 的 `BATMAN_VERSION=` 整行值(§4.2 已讀),並以 `cmp` 斷言;DISCARDED 出現時立即 `back_to_a`,不「重試一次」。

### m15. 可清的 ⚠️ 與小字串
- F15 「uci-defaults 由 base-files 以子殼 source、依檔名序(⚠️ 樹中未複驗)」→ `package/base-files/files/etc/init.d/boot:7-17`:`files="$(ls)"`(busybox `ls` 位元組序)、`( . "./$file" ) && rm -f`;`99-batman-chanfix` < `99zz-batman-prov-state` < `99zz-wbox-*` ✅。清 ⚠️。
- F18 → firmware PUBLIC(M1)。
- §2.2 `lint-wbox` 「CI clone firmware `patches/ekh-bcm2711/` 先套」:board patches 的 `+++` 目標全在 `feeds/openmanet` / `feeds/packages`,沒有一個碰 `feeds/batman` → 對 Batman feed 樹做 `git apply --check` 不需要先套板 patch;trap 的 `git -C feeds/batman checkout -- .` 也不會動到板 patch ✅。可簡化一句。
- F23 說 `pl_prep` 無明確訊息:`prov-lib-254.sh:92` 的 `|| no "tool placement"` ✅。

---

## 負對照 / 契約逐條

| 項目 | 結果 | 證據 |
|---|---|---|
| `prov-sec-psk-timing` n / 節流 / 釋放槽 | ✅(m5) | 219 §3.4、§8(20 / 分,無 lockout);§4.8.2 契約 |
| `NO_BRUTE_LIMIT` → 4 次仍連著 | ✅ | 219 §8「3 次後斷線」是 per-connection |
| `FAST_FAKE_DELAY_MS=20` → 差 ≥ 20 ms | ✅ | — |
| `prov-sec-bond` provd 停止模式 | ✅ | `adv-on` 先查 provd(§2.2);04 agent 白箱 |
| `ble-rpa` 三態 | ✅(m2) | `mgmt.c:1016-1029` |
| `prov-gatt` Flags via 02 | ❌ M3 | `gatt-client.c:814-830` |
| `prov-two-phones` `E_BUSY` | ⚠️ P2 契約(§10 有) | 219 §5.2 碼 7 |
| `prov-sec-dbus` 471 / root 前置 | ✅(m7) | staging `bluetooth.conf`;stage1 §4.6 `:308` |
| `prov-sec-dvpc` | ✅ prov-lib / ❌ chain1(M2) | `prov-lib-254.sh:92`;`chain1-254.sh:315` |
| `prov-sec-sockdir` | ✅ | `sock.go:37-77`:Lstat → symlink / 非 root / 非目錄 → `exists and is not a root-owned directory — refusing to start`;目錄內多出 → `unexpected … refusing to start`;`os.Exit(1)` → procd 5 s respawn(`batman-provhelper.init:13`) |
| (8) 三臂 | ✅(m3) | `batman-autocommit:496-500`;`health.go:138,151-157,163-165` |
| (9) | ✅ | `serving` 後 5 s;health 已由 `h.Run` 啟動(`main.go:460,475`) |
| `wbox-chan` init 迴圈 | ✅(m10) | chanfix 最長 80 + 6×8 s;`applyState` 只寫 AP placeholder key(`main.go:309-332`),不碰 channel / disabled |
| `99zz-wbox-radio1-off` 排序 | ✅ | `init.d/boot:11-14`;`applyState` 不碰 radio1 |
| `lint-wbox` tag 表 / 套板樹 / 見證在字串內 | ✅(m15) | §4.2 表;board patch 目標;gate `grep -rl WBOX-` 才是「被引用」的真判定 |
| CI Go root + SKIP=FAIL | ⚠️ m1 | `ci.yml:74`;`sock_test.go:13-17` |
| `--version` | ✅ | `main.go:405-407` 其他 → usage exit 2 |
| killpoint + sysrq + `sleep 2` | ✅ 一致 | F29(proc 寫入不看 mask);fallback 只對 `/proc` 唯讀 / 無 sysrq 的情況,P9 只記錄 |
| `provd.env` + 三開關 | ⚠️ m6 | — |
| `SOCK_ONLY`、provd 測試目錄 0700、控制包、`max_frame 244`、sock = BLE 連線 | ✅ | 219 §4.1 frame ≥ 3 B;`CTRL` / `STATUS` 為 Read 特徵 |
| `push-helper` / `upper-helper` 順序 | ✅ | §3 / §4.5 |
| `exec` / `proxy` / `sock-as` | ✅ | `provclient/main.go:410-431` 降權 + dumpable 0 |
| `provgen.py` scalar 規則 | ✅ | `gen.py:38,184` |
| `pr_normalise` 1800 + p6 marker | ✅ | — |
| `restoring`、`wbox.list armed`、`DNODE_BLOCKED` | ✅ | `daily-validation.sh:77-99`(`$cmd` 已展開,`:335` `$OTS_NODE`、`:2175` `$MESH_NODE`) |
| known-failures 第 4 欄 + `NEVER_KNOWN` | ✅ | `:2740` ERE;`:2749` `read -r ks pat iss`(第 4 欄併進 `iss`,設計已說由 daily-validation 拆) |
| tmp-trust 條目 | ❌ M2 / m13 | `check-tmp-trust.sh:23,29,55`;allowlist `:13,99`;新案例 `batman-dvpc-evil` 確實 UNTRUSTED ✅ |
| gate 腳本位置 | ✅ | `build-board.sh:159-173`(`$WR` 在 `:173` 刪除前) |
| wbox stamp → clean、`git clean -fdx`、DIRTY | ✅ | `stamp-batman-build.sh:38-44`(`:44` feeds/batman 有改動即 DIRTY);`feeds.conf` 的 batman 是 src-git 整個 Batman repo → `feeds/batman/tests/wbox/` = Batman `tests/wbox/` ✅;`package.mk:114` 以目錄 md5+mtime 判重建,`files/` 在套件目錄內 ✅ |
| `-s -w` 後 `go version -m` | ✅ | buildinfo 不在被 strip 的段;`-trimpath -buildvcs=false` 不影響 `-tags` 記錄 |
| §4.9 預算 | ✅ | 3 + 18 = 21 → 10;scan response 31 − 18 = 13 |
| txn-4 `--check` rc 5 `p5 stale:` | ✅ | `batman-config-save:450` `p5 stale: $keys`(overrides 鍵);`:157` 是 `p5 stale: prov` |
| 鏈 1 / brewrite / pty-commit 取 prov lease | ✅ | 同一把 `$BT/lock`(`ble-lib-254.sh:80-90`) |

## v3 發現 → v4 處置核對

| v3 | 解了? | 說明 |
|---|---|---|
| B-M1 / A-M6(a) (10) L41 | 是 | §6.2 (10) 三個偽造 caller + 真 OTA;§7 指向 (10)(m8:容器臂做法) |
| B-M2 / A-M1 `chan` 賽跑 | 是 | init 背景迴圈 ≥ 200 s + 見證 log + 一律 hold;E-H7(m10 取樣) |
| B-M3 / A-M5 (8)(9) | 是 | 臂 A/B/C;臂 C 先移除後放回(m3 臂 C 要寫停 helper);(9) characterization |
| B-M4 CI 非 root | **部分** | `sudo -E` 寫了但 secure_path 會讓 go 找不到(m1);SKIP = FAIL ✅ |
| B-M5 tmp-trust | **部分** | F30 改寫 ✅;§2.2 條目對 `prov-lib` ✅、對 `chain1-254.sh:112,315` 漏(M2);第 99 行 regex 不一致(m13) |
| B-M6 / A-M6(b) sockdir | 是 | `prov-sec-sockdir-254` ✅ 字串對 `sock.go:49,74` |
| B-m1 F29 | 是 | 改寫 ✅;fallback 當保險;P9 只記錄 |
| B-m2 tag 表 | 是 | 表為準、lint 驗 |
| B-m3 (4) | 是 | §1.2「(4) = (7) 的 04 側」 |
| B-m4 n / 釋放槽 | **部分** | 釋放槽契約 ✅;n 公式換了但仍被下限綁(m5) |
| B-m5 legacy 兩臂 | 是 | 負對照移到正向之後 + strip + 斷言 |
| B-m6 沙箱底 | **否** | §4.4.1 寫了來源但來源不存在(M1) |
| B-m7 dvpc | 是(prov-lib) | chain1 例外(M2) |
| B-m8 字串尾巴 | 是 | F11 |
| B-m9 radio1-off 檔名 | 是 | `99zz-wbox-` + lint |
| B-m10 §7 殘文 | 是 | 重寫 |
| B-m11 normalise lease | 是 | 1800 + renew |
| B-m12 continue-on-error | 是 | `::warning::` + PR body |
| B-m13 chan 只跑一次 | 是 | §4.2 uci-defaults 規則(chan 已改 init,規則留給 radio1-off / misc) |
| A-M2 txn-3 / overlay-corrupt | 是 | F41 ✅(`boot.go:115-120` 不看 gen);`helper-norebuild` |
| A-M3 txn-2 (a) | 是 | ≤ 120 s `mv` + restart(`main.go:441-443`) |
| A-M4 txn-4 | 是 | F39 ✅;`--check` rc 5(`config-save:450`);overrides 缺口回 #254 |
| A-M7 lease / deadman | 是 | renew = `lease_write` + `dm_arm`(`ble-lib-254.sh:116-133,212-226` ✅);`dm-fire` 讀 `lease-prov`;每次 `pr_find` 重取(m9:要先 re-stage 腳本);p6 normalising |
| A-m1 rundir-paths:97 | 是 | `rundir-paths.txt:97` ✅ |
| A-m2 `first_why` 含 | 是 | §6.2 (6)(`:502` 串接 ✅) |
| A-m3 helper-flap 退出點 | 是 | `serving` 後 5 s |
| A-m4 upper 先於 bind | 是 | §3 / §4.5 |
| A-m5 只進非 committed 槽 | 是 | §4.2;P9 分兩種 |
| A-m6 fleet 還原順序 | 是 | 02 先 snap、先還原 |
| A-m7 (6b) boot_id | 是 | 「不等於本次開機」 |
| A-m8 (1) hold | 是 | 一律 hold |
| A-m9 brewrite 條件 | 是 | 「或 B ≠ V」 |
| A-m10 空區塊 | 是 | 全文重寫 |

## 假設驗證表

| 主張 | 結果 | 證據 |
|---|---|---|
| F8 | ✅ | `main.go:373-409,439-476,481-495` |
| F9 | ✅ | `node.go:32-48,165-171` |
| F10 | ✅ | `provclient/main.go:294-305,410-431,470` |
| F11 | ✅ | `sock.go:36-77,136-141`(字串 `sock: %s exists and is not a root-owned directory — refusing to start` / `sock: unexpected %s in the socket dir — refusing to start`) |
| F12 | ✅ | `batman-autocommit:30-31,60,66,94-102,233-247,270-291,419-425,487-537` |
| F13 | ✅ | `96:104-116,168,193`;`boot.go:59,72,120,127,187`;`main.go:491` |
| F14 | ✅ | `health.go:1-9,138,146-157,162-165` |
| F15 | ✅(⚠️ 可清) | `99-batman-chanfix:19-58`;`init.d/boot:7-17` |
| F16 bluetooth.conf 只 root policy | ✅ | staging rootfs `etc/dbus-1/system.d/bluetooth.conf`;`main.conf` `Privacy = device`、`AutoEnable = true` |
| F18 | ✅ 補:firmware PUBLIC(M1) | `gh repo list` |
| F19 | ✅ | `verify.py:176-186`;`gen.py:38,184,225-227`;`ci-check.sh:12` |
| F20 | ✅ | `sock_test.go:13-17,67`;`ci.yml:74` |
| F22 | ✅ | `ble-periph-254.sh:42-52`;`ble-lib-254.sh:84-133,212-226` |
| F23 | ✅ | `prov-lib-254.sh:20,89-93` |
| F25 | ✅ | `daily-validation.sh:77-99,127,254-258,335,386,2175,2740-2755` |
| F26 | ✅ | `validation-known-failures.txt:10,19-24` |
| F29 | ✅(第 3 輪已驗) | `sysrq.c` |
| F30 | ✅ 前半 / M2 補 chain1 | `check-tmp-trust.sh:23,29,55`;allowlist `:13,99`;`chain1-254.sh:112,315` |
| F31 | ✅ | `batman-slot:424-436,771-791` |
| F33 | ✅ | `platform-ab.sh:104-115`;`rundir-paths.txt:97` |
| F34 | ✅ | `golang-package.mk:237-260` |
| F36 | ✅ | `build-board.sh:159-173` |
| F37 | ✅ | `batman-prov-lock:42-58` |
| F38–F41 | ✅ | `node.go:216-222,994-1002,1088-1124`;`txn.go:17-40`;`boot.go:105-131,179-190` |
| stage1 F28(kernel 不自換 RPA) | ✅ | `mgmt.c:1016-1029` |
| BlueZ 遠端 Flags 字彙 | ✅(→ M3) | `gatt-client.c:814-830`;`gatt-database.c:1760-1833` |
| unsquashfs stdin | ❌ 不支援(m4) | WSL `unsquashfs -help` 4.6.1 |
| board patch 不碰 feeds/batman | ✅ | `patches/ekh-bcm2711/*.patch` 的 `+++` 目標 |
| 不可驗(未上機 / 未實測) | ⚠️ | F1、F2、F6(04 upper)、F16 節點側 `libdbus`、F17、F21、F27、F28、F32、F35(grep 沿用)、E-H1–E-H7、`halow-setkey --no-persist` 後重開的 uci 值(txn-2 兩臂都依賴)、bleak WinRT 合併、`BATMAN_PROV_TEST` 環境變數能否穿過 OpenWrt 子 make |

## 範圍對照(p1-impl §5 / stage1 §8–§9)
- 涵蓋:p1-impl §5.1 全部、§5.2、§5.3 全部(含 socket 目錄預置 → `prov-sec-sockdir-254`)、§5.4 鏈 0、§5.5 (1)(3)(6)(7+4)(8)(9)(10)、§5.6、§5.7 全表;stage1 §8 的 `prov-sec-*` 列、§9 tier 列與 RPA / GATT(GATT 判定見 M3)。
- 明列不做且理由可接受:(5)(autocommit `:419` 一次讀 ✅)、P3 / bcm2710 真機 / L16 / iPad 自動化 / `prov-rename` / 真斷電 / release asset 掃描 / `docs/validation` 文字 / txn-1/4/5 獨立負對照。
- claim-lock §13 的「§11.4 真機 4 / 4-inj / 4b / 4b' / 4c / 4d / 5 未實作」:v4 只在 F27 記錄,§1.2 / §9 都沒說本 PR 做或不做。不算靜默縮小(它屬 claim-lock 單的殘項、已寫進 #254 checklist),但 §9 加一行「claim-lock §11.4 真機項仍未排程」較誠實。

## 裁決

**APPROVE-WITH-CHANGES**(BLOCKER 0 / MAJOR 3 / MINOR 15)。M1 是事實錯(資產不在那個 repo、該版本沒有資產)會讓沙箱 job 永遠紅;M2 會在 harness PR 的 CI 以 UNTRUSTED 現形並暴露 chain1 的固定名 `mkdir -p`;M3 讓一個 H3 安全斷言恆 PASS。三者都有確切修法,不動 §3 / §4 架構;v5 可由一位做窄範圍複查(M1–M3 + m1 / m3 / m14)。
