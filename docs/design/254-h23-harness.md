# Design: #254 PR-H3 — harness:H2 補完(P1 tier B / 沙箱 / 接縫)+ H3(provd / BLE / `peer.py`)— **v2(審查中)**

**狀態**:v2,2026-10-28。v1 兩位審查都 REJECT(A:2 BLOCKER / 8 MAJOR / 12 MINOR;B:3 / 17 / 14;`254-reviews/h23-review-v1-{A,B}.md`)。v2 收全部 BLOCKER / MAJOR 與大部分 MINOR,對應表在 §12;整份重寫,請整份再審。使用者決定(2026-10-28):H2 沒做完的部分照 `254-p1-impl.md` §5 補完,與 H3 一份設計、兩段實作;608B(#255)擱置。

上層:`254-stage1-impl.md` v19(§4.4、§4.7、§8、§9、§10)、`254-p1-impl.md` v5.1(§2、§4.1–§4.10、§5、§7)、`254-h1-harness.md` v8(§3、§4.7、§9)、`254-claim-lock-fix.md` v9.1(§11.4、§13)、`219-protocol.md` v0.7(§3–§5、§8、§10–§12)、`219-protocol.cddl`。

## 0. 一句話

一個 harness PR(`harness/254-h23`)把 P1 的測試補到設計要求的覆蓋(約 30 個 tier B 單位 + CI 沙箱矩陣),並為 P2 準備協定對手 `peer.py` 與 provd / BLE 測項;產品只加「為了可測」的接縫(`--killpoint`、`prov_test` build、`-wbox` 變體、provd 測試傳輸),由一個小的產品 PR(PR-P1b)與 PR-P2 承擔。

## 1. 決策、範圍、事實

### 1.1 使用者決策
| # | 決定 | 日期 |
|---|---|---|
| H3-U1 | H2 缺口**照設計補完**(選項 1),不做 H2-lite | 2026-10-28 |
| H3-U2 | 一份設計(本文),兩段實作:甲 = H2 補完 + 接縫;乙 = H3(等 P2 rc) | 2026-10-28 |
| H3-U3 | 成本接受:完整 prov tier B 一輪 15–20 h、04 OTS 累計斷約 4 h、02 隔離約 3 h、SD 約 40 GiB;依 P-U10 只在動到 prov 的 PR 與發版時跑 | 2026-10-28 |
| H3-U4 | 608B / #255 擱置 | 2026-10-28 |
| (沿用)H-U2 / H-U3 / H-U4、P-U5 / P-U9 / P-U10 / P-U12 / P-U14、H-U6(IRK 外洩後 rekey + 重開) | | |

本設計自行定、審查者可攻:
- Q1 服務 UUID = 自訂 128-bit(§4.9,含廣播預算)。
- `peer.py` 主傳輸 = provd 在 `prov_test` build 開的本機 frame socket(§4.8);BLE 空中以 Windows 主機 `bleak`(§4.10)。
- `peer.py` 的 Noise 用 `noiseprotocol`(與 `gen.py` 同、與 `verify.py` 的 `dissononce` 異;v1 B-M5)。
- 斷電代理 = `echo b > /proc/sysrq-trigger`(v1 A-M3)。

### 1.2 範圍
**甲部(H2 補完;在 1.5.14-wsl.4 + 接縫 rc 上驗)**
1. 接縫規格(產品,PR-P1b;§4.1、§4.2)。
2. 節點 tier A:`prov-boot-254`(接線 + 兩條新斷言)、`prov-sock-254`、`prov-sec-helper-uid-254`、`prov-sec-key-perms-254`。
3. 節點 tier B(04):p1-impl §5.3 全部 + §5.4 鏈 0 + §5.5 (1)(3)–(10) + 雙台 `prov-netjoin-fleet-254`;powerloss 五個 killpoint 各一單位。
4. 沙箱(CI `ubuntu-24.04-arm`):`dv-sbx` + p1-impl §5.1 全部。
5. 主機端程式庫 `scripts/dv/prov-254.sh`。
6. P9 補 §4.7;全套順序與正規化(§4.3);known-failures:移除 7 行 #254 過渡條目、**加第 4 欄到期日**(daily-validation 處理 + 測試)、新增 `pre-P1b` / `pre-P2` 條目;chain1 前置兩槽 = V;prov lease 擴到 chain1 / brewrite / pty-commit。
7. `provclient` 擴充 + `provgen.py`(§4.6)。
8. `prov-eeprom-hooks-254`(WSL,對解出的 rootfs,stage1 §8)。
9. lint:`lint-install`、`lint-wbox`、`ab-shared-change.yml` / `rundir-paths.txt` / `tmp-trust-allowlist.txt` 更新(§2.2)。

**乙部(H3;等 PR-P2 rc)**:`peer.py`、provd 測項(§6.3)、P2 要開的測試接縫(§4.8.3)。

**不在本 PR(逐條理由)**:P3 測項(H4);bcm2710 真機(P-U14);轉賣工具與 L16 節點層(P3 / 現場);iPad GATT 自動化(無可程式 central → 手動,§6.3);`prov-rename`(U5 探針待使用者);真斷電(實驗室,以 sysrq 代理,§4.1.1);`release-scan.yml` 掃 release asset(v1 §4.1.3 的那句**刪除**:release asset 由 firmware CI 產,Batman 的 tag push 時 asset 還不存在;供應鏈由 firmware gate + P9 + tier A 三層擋,§7);P-U10 範圍規則進 `docs/validation`(本 PR 只在 daily-validation 註解與 known-failures 到期欄落地;文件另 PR)。

### 1.3 事實(2026-10-28 唯讀實查,main 5914f03;fleet 02/04 = `1.5.14-wsl.4+7fd2124.fw6be516a`,`BATMAN_DIRTY=0`)
| # | 事實 | 證據 |
|---|---|---|
| F1 | P1 出貨**沒有**任何測試接縫:`killpoint` / `prov_test` / `wbox` 在 feed、scripts、tests、CI、firmware `scripts/` 零命中 | `grep -rn`(審查 A 複驗 ✅) |
| F2 | H2(#306)實際交付:`prov-base-254.sh`、`prov-p1-254.sh`(**未接線**)、`addr-defer-254.sh`、CI `prov-p1` stub、`prov-claim-254.sh` 草稿;§5.1 沙箱與其餘 tier B 沒有 | `#306` body;`daily-validation.sh` 無 `prov-p1-254` suite(A、B 複驗 ✅) |
| F3 | daily-validation 現有 #254 測項 **13** 個:`ble-privacy / ble-rpa / ble-pair-sc-only / ble-privacy-reboot`、`prov-tools`、`addr-defer`、`prov-lock-rest`、`prov-p1-stubs`、`setsid-race`、`prov-claim`、`adr-reconcile`、`chain1`、`pty-commit` | `daily-validation.sh:214,227-296` |
| F4 | `prov-base-254.sh` restore 只有「逐檔」:`p5-restore`、`overlay-restore`(tar 覆蓋 upper + 刪多出的檔 + 寫回 p6 state);鏈 1 的 R 類還原 = p5-restore → overlay-restore → `reboot committed` → brewrite B,wsl.3 / wsl.4 PASS;**沒有** `firstboot -y` | `prov-base-254.sh:190-220`;`chain1-254.sh:122-176`;firmware#24 |
| F5 | E4 沒做;`overlay-allow.txt` 3 條帶證據(openmanetd.db、board.json、bat-hosts);`jffs2reset` 的機制 = 掛著刪 upper 再 sync,與 `overlay-restore` 的「刪多出」同機制 | `tests/prov-p1/overlay-allow.txt`;fstools `libfstools/overlay.c:139-142,322-342`(A 查) |
| F6 | payload 只有 `SHA256SUMS` + `metadata`,無簽章;`metadata` 的 `version=` 是**時間戳**,不是 BATMAN_VERSION | `platform-ab.sh:12,156,329,374`;`batman-slot:591-600`;`scripts/build-ab-payload.sh:69` |
| F7 | 版本戳 `VER=$REL-$CH.$N+$F7.fw$W7`,feeds/batman 有修改 → `DIRTY=1` + `.dirty`;OpenWrt 套件重建判定 = 套件目錄檔案 md5,**不含 env**;`golang-package.mk` 支援 `GO_PKG_TAGS`;`build-board.sh` 第 2 步在 pin / 板 patch digest / golang rules 不符時跑 `openmanet_setup.sh -i`(reset `feeds/`) | `stamp-batman-build.sh:51-67`;`include/package.mk:114`、`include/depends.mk:14`;`golang-package.mk:106-111,260`;`build-board.sh:86-96` |
| F8 | helper CLI:`--boot`、`--apply-state [--firstboot]`、`--persist-now`、`qr`、daemon;**沒有 `--version`**(其他參數 → usage、exit 2);`main()` 非 root exit 2;daemon 每次啟動跑 `boot.Run`;`Sys` 介面 20 個方法;`commitTxn` = stage → `--prov-only` → overlay rename;`.txn` 在 overlay `/etc/batman-prov/.txn`,以 `.txn.tmp` + rename 寫 | `main.go:373-407,439`;`node.go:62-83`;`txn.go:16-34`;`provstore/txn.go:21-33`;`provstore.go:326` |
| F9 | 錯誤碼:`EStaleVersion 5`、`EUnsupported 6`、`EBusy 7`、`EStorage 10`、`ERate 12`、**`ESchema 20`**、`EApply 21`、`EState 22`(helper 內部,verdict unknown)、`ELockIncomplete 23`;協定 §5.2 沒有 `E_STATE` | `node.go:36-50`;`219-protocol.md` §5.2 |
| F10 | `provclient` 動詞:`info`、`claim` / `claim-attacker`、`replay`、`ssh-keys`、`root-reset`、`rename`、`verb`;keygen = PEM `EC PRIVATE KEY`(0600);降權 471;`unixpacket` | `provclient/main.go:294-305,420,470,489-558` |
| F11 | helper socket 目錄 `PrepareDir`:root:provd 0750,**目錄裡有 `helper.sock` 以外的任何東西 → 拒絕啟動**;socket 0660;單連線序列化 | `sock.go:37-89,107-131` |
| F12 | `batman-autocommit`:REVERT 一律寫 `bad-slot`(`slot=<S> version=<v>`),只有同槽同版本 COMMITTED 才刪;`brewrite-254.sh` 前置與後斷言都要求 `badslot=[]`;判定字串:`TRIAL-REVERTED …`、`HOLD-COMMIT`、`HOLD-COMMIT-DISCARDED`、`mesh join required: <n> (prov=<v> mesh_expect=<m> radio_required=<r>)`、`WARN ble: ble-ok present but BLE health is not good (…)`(**只在 `ble-ok` 存在時**)、`otalog AC UNHEALTHY first_why=<why>`、`trial <S> is healthy and HELD — waiting for release`、`COMMITTED …`;接縫 `AUTOCOMMIT_DRYRUN` / `AUTOCOMMIT_TIMEOUT` | `batman-autocommit:192-195,238-244,277-288,361,425,499,505,513,537` |
| F13 | 96 的判定字串:`prov: state=<st> copied=<none\|record\|full\|copy-failed\|bad>`;`/etc/.batman-prov-restore` 一行 `<boot_id> <verdict> prov=<PCOPY> state=<PST> lock=<LOCKWORD>`;`root password restored from p5`;helper boot log:`boot rc=<n> verdict=<v> action=<a>`、`overlay record unusable: …`、`p5 lost a committed prov write (overlay gen N > p5 gen M)` | `96-batman-config-migrate:79,113,159-169,193`;`boot.go:59,72,187` |
| F14 | health 檔 stale = ts 超過 60 s;`ble-ok` 寫入條件 `poweredFor ≥ 600 && Committed && ConfigOK` | `health.go:8-9,151` |
| F15 | 99-batman-chanfix 的 log 行:`reassert radio1 channel <cur> -> <CH> from p5 (try <a>) + wifi reload`、`radio1 channel is <CH> (settled after <a> reassert)` | `99-batman-chanfix:47,53` |
| F16 | 節點沒有 python3、dbus-send、busctl、unshare;firmware 樹有編好的 `dbus-send`(`build_dir/target-aarch64_cortex-a72_musl/dbus-1.14.10/tools/dbus-send`)與 python3-base ipk;節點有 `libdbus-1`(bluez-daemon 依賴 dbus)⚠️ E-H1 確認 `.so` 版本 | 04 `which` 2026-10-28;`ls build_dir`;`opkg list-installed`(`dbus 1.14.10-r1`、`libdbus`) |
| F17 | Windows 主機:Python 3.12 / 3.13;`bleak 0.22.3`、`dissononce`、`pycose`、`pycddl`、`cbor2`、`ecdsa`、`cryptography` 都能裝進 venv `C:\Users\yello\batman-dv-tools\pyble`(2026-10-28 實裝);**`noiseprotocol` 未裝 ⚠️ E-H1**;MediaTek 藍牙 adapter OK、`bthserv` running,但 **radio state = Off**(WinRT `Radio.get_radios_async` → `藍牙 state 2`)→ 需使用者在系統設定打開 | `pip install` 輸出;`Get-PnpDevice`;WinRT 讀值 |
| F18 | GitHub `ubuntu-24.04-arm` / `ubuntu-22.04-arm` 公開 repo 免費(2025-01-16 changelog,公開預覽;私有 repo 不可用;排隊可能較久);winson3QQ/Batman 是 PUBLIC | github.blog changelog;`gh repo view --json visibility`(審查者無法上網複驗,⚠️ E-H3 實證) |
| F19 | `verify.py` 661 行,純腳本:頂層 import、模組層載入向量(`:181` `cbor2.loads(NC_RAW)`)、`check()`;`gen.py` 用 `noiseprotocol` + `cryptography`,無 pycose;CI `vectors-219` `MIN_CHECKS=195` + gen 逐位元組 + 竄改負對照 | `verify.py:16-42,181`;`gen.py`;`ci-check.sh`;`ci.yml:45` |
| F20 | repo 沒有 provd / Noise / GATT / UUID;`feed/batman-prov/src/` 有 `proto`、`cbor`、`cose`、`shacrypt`;go.mod 只依賴 `golang.org/x/crypto` | `go.mod`;`proto/proto.go:1-25` |
| F21 | 04 BLE current settings `powered le secure-conn privacy`;bluetoothd 5.72 + patch 900;`/tmp/run/batman-dv/bt` 無殘留 | 04 `bluetoothctl mgmt.info` 2026-10-28(審查者未上機) |
| F22 | BLE harness 基礎:`ble-lib-254.sh`(flock `$BT/lock`、lease、deadman、`settings`、`sc_check`)、`ble-periph-254.sh`(`cmd_adv_on` **第一個動作是 `mg rm-adv 1`**,再 add-adv、再數 instances;`adv-off`、`flip`、`privacy-off`、`restore`、`rekey`、btmon)、`ble-central-254.sh`、`scripts/lib/ble-254.sh`(`ble_stage` / `ble_begin` / `ble_end` / `ble_pre`) | `ble-periph-254.sh:42-52,195-210`;`ble-lib-254.sh:78-134` |
| F23 | `prov-lib-254.sh`:`pl_prep` / `pl_restore` / `pl_end`、`pc`、`pk_proof`、`offered`、`probe`、`lockstate`、`p5shadow`;`brewrite-254.sh`:`back_to_a`、`settle`、E3 迴圈(10/10) | 原始碼 |
| F24 | 鏈 1:`find04`(mDNS + ARP 掃 `10.41.254.0/24`、`10.41.1.0/24`);deadman = B 槽 `/etc/rc.local` 一行 + `setsid sleep 1500` timer + p6 `dv-prov/ch1-deadman.sh`,一次性、只在 B;主機鎖 `$TEMP/batman-dv-04.lock`(每個使用者不同);`restore_all` 刪本 run 的 `bad-slot`;鏈 1 已 > 3000 s(60–90 分);鏈 1 註解記錄過「joinwatch 在還原期間把 A 的 root line 存進剛還原的 p5 → diffs=3」事故 | `chain1-254.sh:27,57-92,122-176,135-137,145,205-221,259`;`claim-lock-254.sh:11` |
| F25 | `pty-commit-254` 把 04 移到另一槽,所以排在 2g 最後;2g = `setsid-race → prov-claim → adr-reconcile → chain1 → pty-commit`;`fault-injection` 的目標是 `OTS_NODE`(= 04)、`reflash-survives-config-202` 的目標是 `MESH_NODE`;`suite()` rc 2 = FAIL 且照跑下一個 | `pty-commit-254.sh:14`;`daily-validation.sh:77-99,278-296,335,2175` |
| F26 | known-failures 的 #254 過渡條目 **7 行**(`prov-p1-stubs` ×3、`prov-lock-rest`、`setsid-race`、`prov-claim`、`chain1`),fleet 已是修正版;檔案 3 欄,**沒有**到期欄(p1-impl §2.2 要求第 4 欄) | `scripts/validation-known-failures.txt:10,19-24` |
| F27 | claim-lock §11.4 的 4 / 4-inj / 4b / 4b' / 4c / 4d / 5 只有 CI stub(真機腳本撰寫被中斷,使用者選縮小範圍,不重寫 `prov-lock-254.sh`) | memory 2026-10-26 |
| F28 | 04 的 S0 = 現在的狀態(10-27 全套在它上面取新 S0 並 PASS) | claim-lock-fix §13;10-27 全套 |
| F29 | kernel `CONFIG_MAGIC_SYSRQ=y`、`CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE=0x1f6`(含 reboot 0x80) | `build_dir/…/linux-bcm27xx_bcm2711/linux-*/.config` |
| F30 | `tmp-trust-allowlist.txt:99` 的 pattern `/tmp/run/batman-prov`(無邊界)會順便放行 `/tmp/run/batman-prov-test/…` | 檔案 |
| F31 | `batman-slot apply` 一開始就刪目標槽的 `slot-<T>.protected`;`95-batman-storage:717` 寫完整 `BATMAN_VERSION` | `batman-slot:424-436` |
| F32 | wsl.9 的 autocommit 有 HOLD-COMMIT;wsl.9 的 96 鎖規則 = key **且** 密碼都在才 LOCKED,否則 UNPROVISIONED | `git show f2f2bf6:…`(A 查) |
| F33 | joinwatch `t_reboot 3600` 是每個未入網 episode 計,04 回 mesh 即重置 | `joinwatch` init:14、bin:19-20 |
| F34 | golang-package.mk 的 install 旗標:`-buildvcs=false -trimpath -ldflags "all=-linkmode external -extldflags <TARGET_LDFLAGS>"` + `GO_PKG_LDFLAGS`(`-s -w`)+ `-tags` | `golang-package.mk:236-262` |
| F35 | deploy/ots 沒有 `/dev/log`、`/tmp/run`、`/opt/batdata/state` 的 bind(grep 零命中);OTS 容器只掛 tenant 目錄 | `grep -rn deploy/ots/` |
| F36 | `check-image-manifest.sh` 只收 `<manifest> <board>`;rootfs 目錄在 `build-board.sh` 第 6 步是 `root-bcm27xx`(給 `check-go-toolchain.sh`)、第 7 步是 `$WR/r`(給 `check-pvs-shim.sh`) | `build-board.sh:146-172`(A 查) |

### 1.4 與上層設計不同處(→ §10)
- p1-impl §4.5.3 同槽重建 = 鏈 1 已證實的 p5-restore → overlay-restore → reboot(F4、F5);`firstboot -y`(F33)不再是前提,E4 作廢;**補一個負對照**(§6.2 `prov-base`):單位內刪一個 lower 檔 → 還原後回來;跳過「刪多出」→ compare FAIL。opaque 目錄(`trusted.overlay.opaque`)在 04 的 upper 是否存在**未查**(節點無 getfattr);風險接受並寫在 §9。
- p1-impl §2.2 `dv-sbx` 改 shell(§4.4)。
- p1-impl §2.2 `-wbox` 改真 build(§4.2),含 mutant 見證。
- p1-impl §7.4 推播:daily-validation 印 `NEEDS-PERSON` 行 + 檔案;推播由操作 session 做。
- p1-impl §4.5.0 全套順序:prov tier B 排在 2g **之前**並帶正規化(§4.3)。

## 2. 元件

### 2.1 產品接縫(PR-P1b;`feed/batman-prov`、`feed/batman-provision`;firmware `scripts/`)
| 元件 | 位置 | 說明 |
|---|---|---|
| `--killpoint` | `cmd/batman-provhelper/killpoint_test.go`(`//go:build prov_test`)、`killpoint_release.go`(`//go:build !prov_test`,`armKillpoint()` 回 "") | §4.1.1 |
| `--version` | `main.go`:新模式,第 1 行 `batman-provhelper <BATMAN_VERSION>`,`prov_test` build 第 2 行 `BATMAN_PROV_TEST_BUILD_7f3a`;release build 只有第 1 行;exit 0 | pre-P1b 偵測(§4.7):wsl.4 對 `--version` 回 usage、exit 2 |
| `prov_test` tag | `feed/batman-prov/Makefile`:`ifeq ($(BATMAN_PROV_TEST),1) GO_PKG_TAGS:=prov_test endif` | §4.1.2 |
| build gate | firmware `build-board.sh` **第 7 步**(對 `$WR/r` = 進 payload 的 squashfs)新增 `scripts/check-prov-test-gate.sh <rootfs> [<wbox-name>]`(F36:不是 `check-image-manifest.sh`) | §4.1.3 |
| `-wbox` 變體 | firmware `build-board.sh --wbox <name>`;patch 在 **第 2 步之後、第 4 步 stamp 之前**套用(F7:`-i` 會 reset feeds);`BATMAN_WBOX=<name>` 進 stamp;stamp 強制 `DIRTY=1`;結束一律還原 feeds/batman;`logs/wbox-<board>.stamp` 變化 → `make package/batman-prov/clean package/batman-provision/clean` | §4.2 |
| mutant 補丁 + 見證 | Batman `tests/wbox/<name>.patch`:檔頭 `# wbox <name>: <一句話>` + `# wbox-witness: WBOX-<name>-<8 hex>`;patch 必須把見證字串寫進它改的那個檔(註解或字串) | §4.2 |
| provd 測試傳輸(P2) | `batman-provd` `prov_test` build:frame socket、`SOCK_ONLY`、三個開關 | §4.8.3 |

### 2.2 harness(本 PR)
| 元件 | 說明 |
|---|---|
| `scripts/dv/prov-254.sh` | 主機端程式庫(sourced):`pr_begin` / `pr_end` / `pr_abort`、`pr_normalise`、`pr_ota_b`、`pr_find`、`pr_restore`、`pr_brewrite`、`pr_lease_*`、`pr_needs_person`、canary;每個單位一支 `scripts/dv/prov-<unit>-254.sh` |
| `scripts/node/prov-base-254.sh` | 既有 + `lock-hold`、`strip-p5-prov`、`state-set`、`dm-arm` / `dm-cancel`、`restoring` 標記 |
| `scripts/node/prov-wbox-254.sh` | `bind` / `unbind-all` / `list` / `arm-killpoint` / `push-helper`(§4.5) |
| `scripts/node/prov-sock-254.sh`、`prov-sec-254.sh` | tier A:socket 負測試;helper uid / key perms(§6.2) |
| `scripts/node/prov-p1-254.sh` | 既有 + 兩條:helper 二進位 `grep -c BATMAN_PROV_TEST_BUILD_7f3a` = 0;`--version` 第 2 行不存在(P1b 之後) |
| `scripts/node/ble-periph-254.sh` | `cmd_adv_on`:在 `rm-adv` **之前**先 `adv_instances` = 0 且 `/etc/init.d/batman-provd running` 為假,否則 die(v1 B-M17) |
| `tests/tools/provclient/` | + `net-apply`、`leave`、`owner-add` / `owner-remove`、`diag`、`sock-as <uid> [--gid g] -- <op>`、`exec <argv…>`(§4.6) |
| `tests/tools/provgen.py` | COSE 物件產生器(§4.6) |
| `tests/prov-p1/sbx/` | `dv-sbx.sh`、`base.env`、`cases/*.sh`、`gate/`(GPT loop 卡案例,獨立於 sbx) |
| `tests/tools/peer/` | `peer.py`、`transport_sock.py`、`transport_ble.py`;`verify.py` 改 `def main()`(模組層不讀檔;向量載入進 `load_vectors()`) |
| `scripts/dv-dbus-tools.sh` | 複製 `dbus-send` 到 `~/batman-dv-tools/dbus-1.14.10/` + SHA256SUMS(同 `dv-bt-tools.sh`) |
| `scripts/dv-prov-tools.sh` | 從 `-wbox test` payload 抽 `prov_test` helper(`unsquashfs -cat`)到 `~/batman-dv-tools/prov-test/<ver>/` + SHA256SUMS |
| `tests/prov-p1/eeprom-hooks.sh` | `prov-eeprom-hooks-254`(WSL,對解出的 rootfs;§6.2) |
| CI | `ci.yml`:`vectors-219` + `peer.py --selftest` + `provgen.py --selftest`;新 job `prov-sandbox`(arm64);`prov-p1` job + killpoint Go 單元測試 + gate 負對照;`prov-gate-stubs` |
| lint | `tests/prov-p1/lint-install.sh`;`tests/wbox/lint-wbox.sh`(每個 patch 對 main `feed/` `git apply --check`、至少改一個 `feed/` 檔、見證字串在 patch 內出現 ≥ 2 次、§6.2 引用的每個 name 都存在);`ab-shared-change.yml` 加 P1b 的共用檔;`rundir-paths.txt` 加 `batman-prov-test/`、`batman-provd-test/`;`tmp-trust-allowlist.txt`:第 99 行收緊為 `/tmp/run/batman-prov([^-]|$)`,新增 killpoint 目錄與 provd 測試 socket 目錄各一行 |
| known-failures | 第 4 欄 `expires=YYYY-MM-DD`(daily-validation:過期 = NEW;缺欄 = 檔案格式錯 → run FAIL;`test-known-failures.sh` 新負對照);移除 F26 的 7 行;新增 `pre-P1b` / `pre-P2` 條目(到期 = 對應產品 PR 預計 merge 後 14 天) |

## 3. 擁有權

延續 `254-h1-harness.md` §3(BLE)與 `254-p1-impl.md` §3(prov)。本 PR 新增 / 修改(每列一個寫者):

| 資源 | 唯一擁有者(可改) | 唯讀者 / 例外 |
|---|---|---|
| `/tmp/run/batman-prov-test/`(root 0700)、`killpoint`(root 0600)、`provd.env`(root 0600) | `prov-wbox-254.sh arm-killpoint` / `set-provd-env` 寫;helper(`prov_test`)讀 `killpoint` 完就刪;provd init(`prov_test`)讀 `provd.env`;**整個目錄**由 `pr_end` / `pr_abort` / prov deadman / P9 的 restore 指令 `rm -rf` | release build 不讀 |
| helper 記憶體內的 killpoint arm | helper(讀檔後持有到觸發或程序結束);**解除** = 重啟 helper(`unbind-all` 看到 `wbox.list` 有 `armed <name>` 就 restart) | P9:helper 本次 pid 的 log 沒有 `killpoint <name>: armed` |
| `/tmp/run/batman-provd-test/`(root:provd 0750)、`gatt.sock`(provd,0660) | provd(`prov_test` build,`SOCK_ONLY` 或正常模式)建 socket;目錄由 provd init 建(同 `PrepareDir` 規則);在 P2 的 ujail mount 清單 | `provclient sock-as 471 -- proxy` 連;release build 沒有 |
| bind mount(`/tmp/run/batman-dv/wbox/<run>/` root 0700 的副本蓋產品檔) | `prov-wbox-254.sh bind` / `unbind-all`;deadman 還原 = `unbind-all` + helper restart | 重開即消失;P9 斷言 `/proc/mounts` 無該來源 |
| B 槽 | 單位期間:產品 `sysupgrade -n`(由單位觸發;**hold 或預期 REVERT,§6.2 每列標明**);收尾:`pr_brewrite` 寫回 V | P9:`.protected` 存在且不含 `wbox` |
| `bad-slot`(p6) | autocommit 寫(REVERT);刪:產品 COMMITTED,或 harness `pr_end` 在「預期 REVERT」單位且內容 = `slot=B version=<該 wbox 版本>` 時(先印出) | brewrite 前置;P9(非本 run 的 bad-slot = FAIL 給人) |
| `autocommit-hold-commit`(p6) | **四個 harness 寫者**(`pr_ota_b`、brewrite、chain1、pty-commit)都經 `pr_lease` 持有者寫;autocommit 消費 | P3 preflight |
| B 槽 overlay 的 `/etc/rc.local`(ch1 deadman 行) | 鏈 1 寫 / brewrite 清 | P9:兩槽 overlay 的 rc.local 無 `ch1-deadman`、無 `sleep 1500` timer、p6 無 `ch1-deadman.sh` |
| `-wbox` payload(`~/out/<VER>/ekh-bcm2711/`,SHA256SUMS + `batman-build.txt`) | firmware `build-board.sh --wbox` 寫;`prov-254.sh` 讀、驗、推到 04 `/opt/batdata/dv-prov/payload-<ver>.tar.gz`(0700) | 只進 B;`finish` 刪節點副本 |
| firmware `feeds/batman` 工作樹 | `build-board.sh --wbox` 套 patch / 還原(trap) | 正常 build 以 stamp 的 DIRTY + gate 擋殘留 |
| `prov lease` `/tmp/run/batman-dv/lease-prov`(`<run_id> <boot_id> <expiry>`) | 取得者;取得與釋放都在 **`$BT/lock` 同一把 flock 內**(與 BLE lease 同鎖,v1 A-m4);到期由 prov deadman 在鎖內刪;**chain1 / brewrite / pty-commit 也取**(v1 B-M3) | BLE lease 與 prov lease 互斥:任一有效 → 另一方 acquire FAIL;**主機端互斥 = 只有節點端 lease**(`$TEMP` 鎖刪除) |
| prov deadman(節點 `setsid`,每台至多一個) | `prov-base-254.sh dm-arm <run> <secs>`;動作:`unbind-all`(含 killpoint 重啟 helper)、`rm -rf /tmp/run/batman-prov-test`、**有 `restoring` 標記時只做到這裡**;否則再啟動 joinwatch / openmanetd / tailscaled;留 dirty;**不碰槽、不碰 p5** | 與 ch1 deadman 不同時 armed(P9) |
| `restoring` 標記(`$DVD/restoring.<run>`) | `pr_restore` 開始時建、`finish` 刪 | deadman 讀(v1 B-M15) |
| 單位之間的安全點 S0 | `pr_restore`;通過才 `finish` | P9;下一單位 |
| `NEEDS-PERSON`(`$DIR/needs-person.txt` + 報告行 + `DNODE_BLOCKED=1`) | `pr_needs_person` 寫;daily-validation `suite()` 讀:之後 `kind=D` 且目標含 DNODE 的 suite 印 `FAIL blocked: DNODE needs a person (<step>)` 不執行(v1 A-M7) | 報告 |
| 沙箱內一切 | `dv-sbx.sh` | runner 宿主:負測試 |
| `peer.py` session 狀態 | `peer.py` 程序 | 不落地;canary |
| 04 廣播 instance(P2 後) | provd;harness `adv-on` 只在 provd 停止時 | 02 掃描 |

## 4. 契約

### 4.1 接縫(產品)

#### 4.1.1 `--killpoint`(只在 `prov_test` build)
- **點名封閉**:`txn-1`(`prov-txn` + `.txn` 寫完、setkey 之前)、`txn-2`(setkey `--no-persist` 之後、`--prov-only` 之前)、`txn-3`(`--prov-only` rc 0 之後、overlay rename 之前)、`txn-4`(overlay rename 之後、`--save` 之前)、`txn-5`(`--save` 之後、`prov-state` 寫入之前)、`claim-after-persist`(claim 的 txn-3)、`claim-before-shadow`(claim 的 txn-4)。對照上層 §4.4 步驟 1–5。**五個 txn 點都有單位**(§6.2)。
- **檔案**:`/tmp/run/batman-prov-test/killpoint`,一行點名。helper daemon 啟動時讀:目錄 root 0700、非 symlink;檔 root 0600、非 symlink、link count 1;不符 → log `killpoint: refused (<why>)` 忽略;讀完立刻刪;點名不在清單 → log 忽略;成功 → log `killpoint <name>: armed`。
- **到點**:log `killpoint <name>: sysrq reboot` → `echo b > /proc/sysrq-trigger`(**不 sync、不卸載**;F29)。sysrq 不可用(寫入失敗)→ log `killpoint <name>: fallback reboot -f` → `sync` → `reboot -f`。harness 只在看到 `sysrq reboot` 那行時把 L7 判 PASS;`fallback` 行 = ⚠️(報告標)。
- **注入成立的四證據**:重開前 helper log 有 `armed`;重開後 `killpoint` 檔不存在;boot_id 改變;狀態停在該點(每個單位各自定義)。
- release build:`armKillpoint()` 回 "",檔案存在也不讀,log 無 `killpoint` 字樣。
- 寫者 root;非 root 預建目錄 → 擁有權不符 → refused。
- **測試**(CI `prov-p1`):Go 單元測試(`-tags prov_test`,temp dir 注入目錄路徑;v1 A-m3 / B-m3):0777 / symlink / link 2 / 非 root 擁有 → refused;正確 → armed 且檔被刪;release tag 的 no-op 測試。mutant:拿掉 link count 檢查 → FAIL。

#### 4.1.2 `prov_test` build(封閉清單)
- Makefile:`BATMAN_PROV_TEST=1` → `GO_PKG_TAGS:=prov_test`;只對 `batman-provhelper`(P2 再加 `batman-provd`)生效。
- `prov_test` build 的額外行為(**全部**,P2 只能追加並寫回):(1) `--killpoint`;(2) `--version` 第 2 行 `BATMAN_PROV_TEST_BUILD_7f3a`、`--boot` 第一行 log 同字串;(3)(P2)provd frame socket;(4)(P2)provd 讀 `provd.env`:`SOCK_ONLY`、`FAST_FAKE_DELAY_MS`、`NO_BRUTE_LIMIT`(§4.8.3)。**沒有** mutant 開關(mutant 一律 `-wbox` 變體或 fakeSys)。
- 標記字串只在 tag build 編進去的檔案;release 二進位 `grep -c` = 0。

#### 4.1.3 build gate(`scripts/check-prov-test-gate.sh <rootfs-dir> [<wbox-name>]`,`build-board.sh` 第 7 步)
- 無 `<wbox-name>`:`go version -m <rootfs>/usr/bin/batman-provhelper` 的 `build -tags=` 不含 `prov_test`;helper `grep -c BATMAN_PROV_TEST_BUILD_7f3a` = 0;`<rootfs>/etc/batman-build` 沒有 `BATMAN_WBOX=` 行;`<rootfs>` 整棵 `grep -rl 'WBOX-'` = 0(任何見證字串都不該在);否則 build 停。
- 有 `<wbox-name>`:`BATMAN_WBOX=<name>` 行在;VER 含 `.dirty.wbox-<name>`;**見證**:patch 檔頭的 `wbox-witness` 字串在 `<rootfs>` 裡 `grep -rl` ≥ 1(v1 B-M1);`test` 變體的見證 = helper 的 `BATMAN_PROV_TEST_BUILD_7f3a`;`helper-exit1` 這種 shell 取代 Go 二進位的變體:`go version -m` 無輸出時改以見證字串判(v1 A-m1)。
- 負對照(CI `prov-gate-stubs`):對一個 `prov_test` build 的 helper(CI 自建)跑 gate → FAIL;對 release → PASS;對有 `WBOX-` 字串的假 rootfs → FAIL。

### 4.2 `-wbox` 變體(firmware `build-board.sh --wbox <name>`)
- 輸入:`feeds/batman/tests/wbox/<name>.patch`(pin 的那個 commit 裡的檔);`name=test` 時**沒有 patch**(例外,lint 明列),只設 `BATMAN_PROV_TEST=1`。
- 步驟:第 1–2 步照常(含可能的 `-i`)→ **第 2 步之後**:`git -C feeds/batman apply --check` → apply → `export BATMAN_WBOX=<name>`(`test` 另 `export BATMAN_PROV_TEST=1`)→ 第 3 步 lock(mutant 只改 `files/` / Go 原始碼,`.config` 不變)→ 第 4 步 stamp(`BATMAN_WBOX` 有值時 **`DIRTY=1` 強制**,VER = `$REL-$CH.$N+$F7.fw$W7.dirty.wbox-<name>`,加 `BATMAN_WBOX=<name>` 行)→ 第 5 步前:`logs/wbox-<board>.stamp`(上次的 `<name>|<BATMAN_PROV_TEST>`)與這次不同 → `make package/batman-prov/clean package/batman-provision/clean`(F7:env 不進重建雜湊)→ 第 5–10 步 → trap(成功或失敗)`git -C feeds/batman checkout -- . && git -C feeds/batman clean -fd tests/ files/`、寫 stamp。
- 正常 build(無 `--wbox`):同一個 stamp 機制 → 上次是 wbox → clean 一次;gate 的 `WBOX-` / 標記 / `BATMAN_WBOX=` 三條擋殘留。
- 輸出:`~/out/<VER>/ekh-bcm2711/`(payload tar、SHA256SUMS、`batman-build.txt`)。
- **只進 B**;hold 或預期 REVERT(§6.2 標明);P9 任一槽 `.protected` 缺、或 `.protected` / `/etc/batman-build` 含 `wbox` → run FAIL。
- **版本與見證斷言**(`pr_ota_b`,v1 A-M2 / B-M1):主機端驗 SHA256SUMS、讀 `batman-build.txt` 的 `BATMAN_VERSION` / `BATMAN_WBOX`;推上節點後 `tar -xzf … -O root.squashfs > $T/r.sq && unsquashfs -cat $T/r.sq etc/batman-build`(節點有 unsquashfs?**⚠️ E-H2 查**;沒有就在主機端對同一份 tar 做,sha 綁定)讀同兩行,並 `unsquashfs -cat` 見證所在檔 grep 見證字串;三者一致才 `sysupgrade -n`。
- 變體清單(v1 B-B2 補四個 helper mutant):

| name | mutant(一句話) | 見證 | 用在 |
|---|---|---|---|
| `test` | 無 patch,只有 `prov_test` tag | helper 標記字串 | killpoint 單位的 helper 來源(§4.5 `push-helper`) |
| `rc9-unclaimed` | helper `--boot` rc 9 → 寫 `prov{unclaimed}` | log 字串 | `prov-legacy-upgrade` 負對照 |
| `96-noprov` | 96 不抄 overlay prov(`PCOPY=none`) | 96 註解 + log | `prov-ota` 負對照 |
| `helper-exit1` | helper 二進位 = `exit 1` 的 shell(含見證註解) | 檔內字串 | `prov-lock-failsecure` 正向 |
| `helper-nogen` | `--boot` 不比 gen | log | `prov-overlay-corrupt` 負對照 |
| `96-norestore` | 96 + helper 都不從 p5 還原 | log | `prov-overlay-wipe` 負對照 |
| `helper-nojoinop` | `net.apply` 首版不要求 owner-op | log | `prov-netjoin` 負對照 |
| `helper-noleave` | `network.leave` 不刪 p6 mesh 標記 | log | `prov-leave-ota` 負對照 |
| `helper-notrial` | 改狀態動詞不看 `IsTrial` | log | `prov-trial-busy` 負對照 |
| `helper-clientchal` | `claim.verify` 採用 client 送來的 `ClientChal` | log | `prov-claim` 負對照(p1-impl §5.3) |
| `helper-notxn` | 開機不對帳 `.txn`(只刪) | log | `prov-powerloss` 的負對照之一(§6.2) |
| `radio1-off` | uci-defaults 一次性 `radio1.disabled=1` | 檔內 | autocommit (1) |
| `chan` | S99 一次性 init:等 F15 settled 行後 `uci set radio1.channel` 另一值 + `wifi reload` | 檔內 | autocommit (4)(7) |
| `helper-flap` | helper 每 5 s exit | log | autocommit (9) |
| `misc-L38` / `misc-L42` / `misc-L43` / `misc-L51` | §6.2 `prov-misc` | 各自 | `prov-misc` |

- 共 **17 個 build**;E-H2 量單次增量 build 時間 × 17 寫進 §7.3。
- `lint-wbox`:每個 patch 對 main 的 `feed/` `git apply --check`;至少改一個 `feed/` 檔(`test` 例外);見證字串在 patch 內出現 ≥ 2 次(檔頭 + 檔內);§6.2 引用的每個 name 都在 `tests/wbox/`。

### 4.3 主機端 `prov-254.sh`(Git Bash;簽章與 COSE 在 WSL)
沿用 p1-impl §4.2–§4.5。本節寫 H2 沒實作、本 PR 要定的部分。

- **單位骨架**:`pr_begin <unit> <secs> [helper=test]` = P9 子集(S0 槽條件、無 dirty / bind / wbox / killpoint 目錄、02 在 `batctl n`)→ lease(鎖內)→ deadman armed → `snap` →(`helper=test` 時 `push-helper`,§4.5)→ 步驟 → `pr_end`(= `pr_restore` → compare diffs=0 → `pr_brewrite` → `finish` → `rm -rf /tmp/run/batman-prov-test` → lease release → deadman cancel → **02 在 `batctl n`、02 boot_id 前後相同**)。任一步失敗 → `pr_abort <why>`(= `pr_restore`;restore 也失敗 → `pr_needs_person`)。
- **正規化 `pr_normalise`**(prov 區塊開頭,v1 B1):04 committed = B、版本 = V、無 wbox、無 bad-slot → 在 B 上寫 hold = V → `sysupgrade -n <V payload>` 進 A → A 的 HELD trial → `release --wait` → A committed → 之後才 snap(無快照,不做 tar 覆蓋;p1-impl §7.4)。其他不符(版本 ≠ V、含 wbox、bad-slot、02 不在 A)→ `pr_needs_person`,prov 區塊不跑。白箱:故意把 04 留在 B committed → 下一次 run 第一個單位 PASS。
- **全套順序**:`FEATURE_MODE=--destructive` 時 prov tier B 區塊放在 **2g 之前**(2e BLE tier B 之後;2g 的 chain1 也要 A,pty-commit 最後把 04 移槽,之後 ab-selftest / FI / `reflash-202` 自己處理槽)。區塊內:`pr_normalise` → `prov-base` → 不 hold 的 autocommit (1)(4) → hold 的單位 → killpoint 單位 → 鏈 0 → `prov-netjoin-fleet`(雙台)→ autocommit (7) → `prov-legacy-upgrade`(最後:B 寫 wsl.9 再寫回)。每單位是安全點;`NEEDS-PERSON` 後不再跑 prov,且之後 `kind=D` 且目標含 DNODE 的 suite 被擋(§3)。
- **OTA 到 B**:`pr_ota_b <payload> <sha> <hold|revert> [allow-stale]`:`hold` 寫 hold = 目標版本;`revert` 不寫(預期 REVERT)。`setsid sysupgrade -n` → `waitboot` → `pr_find`(`find04` 一般化)→ 落點斷言(DT tryboot=1、`batman_slot` = B、`hold` 時 `HOLD-COMMIT` 生效且無 DISCARDED)。落空 → 讀 tryboot 旗標、disarm、清 hold、重試一次;再落空 → `pr_needs_person`。
- **預期 REVERT 單位的收尾**(v1 A-M1):等 `TRIAL-REVERTED` 行(≤ 600 s + 120 s)→ 04 回 A → 斷言 `bad-slot` 內容 = `slot=B version=<wbox ver>` → 印出 → 刪 → `pr_brewrite`。內容不符 → `pr_needs_person`。
- **還原**:F = `p5-restore` + `overlay-restore` + `reboot committed`;R = 同 F(F4);跨槽 = 在 B 上 p5-restore → rollback → A → F。`pr_restore` 開始前**延長 lease 到 +1800 s** 並在節點寫 `restoring` 標記(v1 B-M15)。
- **lease 預算**:每單位 ≤ 3000 s(F33);鏈 1 例外(既有 60–90 分,列為已接受例外,每段重新 acquire);鏈 0、autocommit (7)、`prov-legacy-upgrade` 拆兩個 lease。
- **secrets / canary**:同 p1-impl §4.2;金鑰 `~/.batman-dv/prov-keys/<run_id>/`,`pr_end` 刪並斷言;canary 掃主機 log、`logread`、p6 `*.log`、run dir。
- **`NEEDS-PERSON`**:`pr_needs_person <node> <step> <class>`:印 `NEEDS-PERSON <node> <step> <class> <report>`、寫 `$DIR/needs-person.txt`、`DNODE_BLOCKED=1`、return 1(suite FAIL;known-failures 拒收此 pattern → 永遠 NEW,報告段寫明)。

### 4.4 `dv-sbx.sh`(CI `ubuntu-24.04-arm`,root)
契約 = p1-impl §4.10;步驟順序(v1 B-m9):
1. 宿主:`unsquashfs` 底(釘住 `base.env`:版本 + sha)到 `$SBX/root`;依 `feed/batman-provision/Makefile` install 規則蓋 PR 的 `files/`;helper 以 `setup-go`(SHA 釘)`-tags prov_test` arm64 原生 build;`losetup -f --show $SBX/p5.img`(宿主做,記 loop 裝置;拒絕已掛載 / 支撐 `/overlay` 的裝置)。
2. `unshare --mount --pid --fork --net --uts --ipc --propagation private -- sh setup.sh`:`mount -t proc proc $SBX/root/proc`(chroot 內要有 /proc);`/proc/sys`、`/proc/sysrq-trigger` ro bind;`/sys` 不掛;`/dev` tmpfs + `mknod null/zero/urandom` + `mknod mmcblk0p5 b <loop major> <minor>`;`kmsg` regular file;`/opt/batdata`、`/tmp`、`/tmp/run` tmpfs;`/proc/cmdline` bind 假檔;無 `/proc/device-tree`;stub `vcmailbox` / `reboot` / `wifi` / `ubus` 在 PATH 前。
3. `capsh --drop=cap_sys_boot,cap_sys_module,cap_sys_time,cap_sys_rawio,cap_mknod -- -c "chroot $SBX/root /bin/sh case.sh"`。
- `prov-unit-sbx` 負測試(job 開頭,任一不成立 → job FAIL,不跑案例):`reboot -f` → runner boot_id 不變;`mknod` runner 真實磁碟 → EPERM;`ip link add dummy0` 成功但宿主 `ip link` 無(證 netns);`ip link set eth0 down`(宿主的 eth0 不在 ns 內 → 找不到);`echo x > /proc/sys/kernel/hostname` → 失敗;`echo x > /dev/kmsg` → 宿主 `dmesg` 無。
- 案例 `tests/prov-p1/sbx/cases/<name>.sh`(p1-impl §5.1 表逐條)+ `--mutant`(負對照必 FAIL)。
- `prov-unit-gate` **獨立於 sbx**:`tests/prov-p1/gate/`,沿用 `tests/ab-card-invariants.sh` 的 loop GPT 卡 + 假 DT 檔 + `/boot/autoboot.txt`,對 `batman-slot` 跑 `.seeded` × `prov.meta` × state 矩陣;mutant「放行 claimed」+ wsl.9 的 `batman-slot`。
- CI:`timeout-minutes` 只限執行時間,**排隊不計**(v1 A-m9);E-H3 之前 job 不擋 PR(`continue-on-error` 標明),E-H3 後轉必要。
- `prov-artifact-match`(WSL,rc 時手動):`unsquashfs` rc 的 `root.squashfs`,逐檔比 batman-provision 與 pin commit 的 `files/` + install 規則;helper 以 F34 的**整串旗標**(`-buildvcs=false -trimpath -ldflags "all=-linkmode external -extldflags <TARGET_LDFLAGS>" -ldflags "-s -w …"`,E-H4 記錄實際字串)重建比 sha;不可重現 → 明列,helper 出貨產物只由節點 tier A / B 涵蓋。

### 4.5 節點端新增
- `prov-base-254.sh`:`lock-hold <run> <secs>`(印 `HELD` 後背景持鎖)、`strip-p5-prov <run>`、`state-set <run> <file> <content|absent>`(只限 `STATEFILES`;先印舊值)、`dm-arm` / `dm-cancel`、`restoring <run> set|clear`。
- `prov-wbox-254.sh`:
  - `bind <name> <dst>`:副本 `/tmp/run/batman-dv/wbox/<run>/<name>`(root 0600)`mount --bind` 到 `<dst>`,記 `wbox.list`;
  - `push-helper <sha>`(v1 A-B2):接收主機推來的 `prov_test` helper(來源 `~/batman-dv-tools/prov-test/<ver>/batman-provhelper`,`dv-prov-tools.sh` 從 `-wbox test` payload `unsquashfs -cat` 取出並記 sha)→ 驗 sha → `bind` 到 `/usr/bin/batman-provhelper` → `/etc/init.d/batman-provhelper restart` → 斷言 `--version` 第 2 行 = 標記、`/proc/$(pidof batman-provhelper)/exe` sha = 推上去的;**重開後 bind 消失,恢復邏輯由 A 槽 release helper 執行**(這正是 L7 要測的:release code 的恢復);restart 會再跑一次 `boot.Run`(F8),`prov-state` 的 verdict 行會重寫,單位的 S0 compare 以 p1-impl §4.5.5 的 boot_id 規則處理;
  - `arm-killpoint <name>`:寫檔(§4.1.1 契約)→ restart helper → 斷言 log `killpoint <name>: armed`(本次 pid)→ `wbox.list` 記 `armed <name>`;
  - `set-provd-env <k=v…>`(P2):寫 `provd.env`(root 0600)→ restart provd;
  - `unbind-all`:umount 全部、`wbox.list` 有 `armed` → restart helper、`rm -rf /tmp/run/batman-prov-test`;
  - `list`。
- `prov-sock-254.sh`(tier A):staged `provclient sock-as 471 -- info` → 正確回應;`sock-as 65534`(無 gid 471)→ **`connect()` EACCES**(目錄 0750,F11);`sock-as 65534 --gid 471` → 連上後被 PEERCRED 關(`CONN-CLOSED`);未知動詞 / 多餘欄位 → **`E_SCHEMA`(20)**(F9)。全唯讀。
- `prov-sec-254.sh`(tier A):`prov-sec-helper-uid-254`(helper 程序 uid 0、provd uid 471 存在、socket 目錄 root:provd 0750、socket 0660)、`prov-sec-key-perms-254`(`/etc/batman-prov/identity/` 0700、每個私鑰 0600 root、p5 `identity/prov/` 同;負對照:bind 一個 0644 的副本 → FAIL)。

### 4.6 `provclient` 擴充與 `provgen.py`
- `net-apply <cfg.hex> <members.hex> <secrets.hex> --first | --update <chain.hex>`;`leave`;`owner-add <pub.hex> <enc.hex> <sig_enc.hex>`;`owner-remove <key_id.hex>`;`diag`;`sock-as <uid> [--gid <gid>] -- <op>`;**`exec <argv…>`**(降權後 `execve`,清 env、無 stdin、argv 原樣;給 `dbus-send`,v1 B-M8)。
- `provgen.py`(WSL venv):`netcfg` / `members` / `secrets` / `chain` / `invite`;金鑰 = `provclient keygen` 的 PEM `EC PRIVATE KEY`(F10),`provgen.py` 以 `cryptography` 讀 PEM,pycose 簽;`--selftest`:以 `vectors.json` 的固定金鑰(同 PEM 格式,由 `gen.py` 的 raw 私鑰轉換,轉換函式也在 selftest 內驗)**逐位元組**重現 `net_config` / `member_list` / `net_secrets`(不是只驗簽)。
- 獨立性:helper(Go `cose`)解、`provgen.py`(`pycose`)產,向量 + `verify.py` 擋;pycose 的 Sign1 header 順序與 `gen.py` 手組是否相同由 selftest 逐位元組證明(v1 A 無法核對項)。

### 4.7 preflight P9(`dv-preflight.sh` 新段;每條都有 `test-dv-preflight.sh` 負對照)
- 任一節點 `/etc/batman-build` 或兩槽 `.protected` 含 `wbox`、**或 `.protected` 缺**(F31)→ FAIL。
- helper 二進位 `grep -c BATMAN_PROV_TEST_BUILD_7f3a` ≠ 0 → FAIL(v1 B-M13;tier A 每天也查)。
- `dv-prov-dirty` 存在且 run_id 不同 → FAIL,印 restore 指令。
- `/proc/mounts` 有 `/tmp/run/batman-dv/wbox/` 來源 → FAIL;`/tmp/run/batman-prov-test/` 存在 → FAIL;helper 本次 pid 的 log 有 `killpoint .*: armed` → FAIL(v1 B-M16)。
- ch1 deadman 殘留(§3 rc.local 列)→ FAIL;`bad-slot` 存在 → FAIL(印內容)。
- helper state ∈ {legacy} 或 `PROV_EXPECT`;讀不到 → FAIL。
- `--destructive`:WSL `provclient sign`、`provgen.py --selftest`;`~/batman-dv-tools/prov-test/<V>/` 的 helper sha;`-wbox` payload 目錄:§4.2 的 17 個 name 都有 SHA256SUMS 且 `batman-build.txt` 版本前綴 = fleet 版本(缺 → prov tier B 整段 FAIL);`dbus-send` 工具目錄;04 `/opt/batdata/ota.tar.gz` 不被使用。
- `sysctl kernel.sysrq` 含 0x80(F29;不含 → killpoint 單位全部 FAIL,不 SKIP)。
- chain1 前置:兩槽 `.protected` 版本 = V,否則 `FAIL precondition: slot B is <ver>, want <V> (OTA twice first)`。
- **pre-P1b 偵測**(v1 B-m4):`batman-provhelper --version` rc 0 → P1b;rc 2 → pre-P1b;需要接縫的單位印唯一一行 `FAIL pre-P1b image: <ver> (helper has no --version)`。
- H3(P2 後):`peer.py --selftest`;bleak 匯入;provd `prov_test` socket 目錄不存在(release)。

### 4.8 `peer.py`(H3)
#### 4.8.1 角色與裁判
- 手機角色與攻擊者角色。
- **實作**(v1 B-M5):Noise 用 `noiseprotocol`(與 `gen.py` 同;`gen.py` 已證明可注入臨時金鑰做決定性交握,`peer.py --selftest` 沿用同方法);CBOR `cbor2` + `det_dumps`、CDDL `pycddl`、ES256 `python-ecdsa` 從 `verify.py` import(改 `def main()`,模組層無 I/O;v1 A-m12)。
- **裁判**:(1) 向量(`verify.py`,`dissononce`);(2) `peer.py`(`noiseprotocol`)↔ provd(Go `flynn/noise`)互打。`peer.py --selftest` 對 `gen.py` 的交握 transcript **逐位元組**比,不只對 `verify.py` 的函式。CI 負對照:import 後 `main()` checks ≥ 195;`peer.py --selftest` 刪一個比對 → FAIL。

#### 4.8.2 傳輸契約(§4.1 frame 層)
- `transport_sock.py`:`SOCK_SEQPACKET`;**一個 packet = 一個 frame**(`flags(1) ‖ seq(2 BE) ‖ data`);`max_frame` 固定 **244**(= 常見 BLE MTU 247 − 3;provd 的 `CTRL` 回同值);重組與中止規則與 BLE 相同(序號不連續 / 超過 `max_msg` → 關 socket = 斷 BLE)。
- **協定外控制包**(v1 A-m8):長度 1 的 packet `0xC0`(讀 `CTRL`)/ `0xC1`(讀 `STATUS`)對應 GATT 特徵讀取 handler;**只允許在交握完成之前**,之後收到 → 中止;長度 < 3 且不是這兩個值 → 中止。
- **一條 sock 連線 = 一條 BLE 連線**(v1 B-M11):219 §8 的每個計數器(同時連線 2、每連線 1 個交握、全域 20 / 分、未認證閒置 30 s、交握逾時 10 s、認領失敗 3 次 / 連線、`claim/replay` 10 / h)對 sock 連線同樣適用;§6.3 每個測項標對應的 §8 列。
- socket:`/tmp/run/batman-provd-test/gatt.sock`(§3;**不在** killpoint 目錄,v1 B3);harness 經 `provclient sock-as 471 -- proxy`(stdin/stdout ↔ socket,經 ssh)。
- `transport_ble.py`:`bleak`;scan 以服務 UUID 過濾;`CTRL` / `STATUS` 讀、`RX` write-without-response、`TX` notify;MTU 由 `bleak` `mtu_size` − 3。
- 介面相同(`send_msg` / `recv_msg` / `abort`);協定測項在 sock 上跑完整組,BLE 上跑子集。

#### 4.8.3 P2 要開的 `prov_test` 開關(`provd.env`,封閉清單)
- 寫者:`prov-wbox-254.sh set-provd-env`(root 0600、非 symlink、link count 1,在 `/tmp/run/batman-prov-test/`);讀者:provd **init**(只在 `prov_test` build;release init 不讀),以 `procd_set_param env` 傳給 provd;缺檔 / 壞檔 → 不設(正常行為);非 root 建不了(0700 目錄)。
- `SOCK_ONLY=1`:provd 不碰 dbus / bluetoothd,只開 frame socket(CI `peer-vs-provd` 用;v1 A-M6)。
- `FAST_FAKE_DELAY_MS=<n>`:錯 PSK 的假第 2 則延後 n ms 才送(`prov-sec-psk-timing` 負對照;v1 B-M6)。
- `NO_BRUTE_LIMIT=1`:關掉每連線 3 次限制(`prov-sec-claim-brute` 負對照;v1 B-M7)。
- (v1 的 `NO_OWNEROP` 刪除:owner-op 由 helper 驗,provd 層負對照用 `type ≠ verb` 向量即可。)
- release build:env 無作用、二進位無字串。
- CI `peer-vs-provd` 執行模型(v1 A-M6):runner `useradd -u 471 provd`;helper `sudo` 以 root 跑(fakeSys 由 `-tags prov_test` 的 CI 模式提供假 `batman-config-save` 等,與 `prov-p1` job 同套)、provd `sudo -u provd` + `SOCK_ONLY=1`;`peer.py` 本機連 socket。

### 4.9 服務 UUID(Q1)與廣播預算
- `batman-prov` 服務 UUID:自訂 128-bit,本設計核准時以 `uuidgen` 產生一次,寫進 219 §4.1 與常數;特徵 = base+1…+4(`RX` / `TX` / `CTRL` / `STATUS`)。
- **預算**(v1 B-m7):legacy ADV 31 B = Flags(3)+ Complete List of 128-bit UUIDs(18)= 21 → 剩 10 B;B16 的 service data(nonce + 旗標)放 **scan response**(31 B:128-bit Service Data 需 2 + 16 = 18 B 頭 → payload ≤ 13 B;nonce 8 B + 旗標 1 B 可放)。手機以 UUID 過濾 + 讀 scan response(iOS `CBAdvertisementDataServiceDataKey` 含 scan response 內容 ✅ 一般行為,⚠️ 實機在 P2 驗)。寫進 P2 設計;若 B16 的 nonce > 12 B 則改 16-bit UUID(要申請)。

### 4.10 BLE 空中(H3)
- 主 central = Windows 主機 `bleak`(F17:radio 目前 Off,需使用者打開;E-H1 量 RSSI)。
- 02 = 攻擊者 central(配對 / 綁定 / 佔連線),沿用 `ble-central-254.sh`。
- `prov-sec-bond` 翻轉段、`ble-rpa` N1 負對照都在 **provd 停止**模式做(`adv-on` 的前提,v1 B-M9 / B-M10)。

## 5. 生命週期矩陣

| 路徑 | 今天 | 本 PR 之後 | 證明 |
|---|---|---|---|
| install / first run(harness 新主機) | DV_* env + WSL venv | + Windows `pyble` venv(bleak + noiseprotocol + verify.py 依賴)、WSL venv + `provgen.py`、`-wbox` payload 17 個、`prov-test` helper、`dbus-send` 工具;P9 逐項,缺 = FAIL | `test-dv-preflight.sh` 每缺項一個負對照 |
| start(prov 區塊) | — | `pr_normalise` → 單位 | 白箱:04 留在 B committed → 第一單位 PASS |
| start(單位) | — | `pr_begin` | 每單位 |
| clean stop(單位) | — | `pr_end` | 每單位 |
| harness 死(非 hold 的 wbox trial 中) | — | deadline revert 接手 → `bad-slot` → dirty 留著 → 下次 P9 FAIL 印 restore 指令(含 bad-slot 清法) | 白箱:殺主機腳本 |
| harness 死(hold trial 中) | — | 600 s 期限到 revert(hold 只擋 commit)→ 同上 | 白箱 |
| **誤 commit 後 harness 死**(04 committed 在 wbox B) | — | deadman 不碰槽;P9 FAIL「A/B 含 wbox」;**需人**(跨槽還原指令印在 P9) | 白箱(以 `prov-wbox` 的 `state-set` 模擬 `.protected`) |
| **harness 死於 restore 途中**(p5 dd / overlay-restore) | 鏈 1 事故(F24) | `restoring` 標記 → deadman 只 unbind + helper restart,**不起 joinwatch**;lease 已延長 1800 s;dirty 留著;下次同 run_id 接手 restore 冪等 | 白箱:restore 中殺主機 → 30 s 後 joinwatch 未啟動 |
| harness 死(節點不重開,一般) | BLE deadman | prov deadman:unbind、killpoint 解除(restart helper)、刪 prov-test 目錄、起 joinwatch / openmanetd / tailscaled;dirty 留 | 白箱 |
| harness 死(節點已重開) | — | bind / killpoint 目錄隨 tmpfs 消失;helper 記憶體 arm 消失;dirty 接手 | 白箱 |
| killpoint 已 arm、harness 死在觸發前 | — | deadman / `unbind-all` 看 `wbox.list` 的 `armed` → restart helper;P9 看 log | 白箱:arm → 殺主機 → 下一單位的 net-apply 不重開 |
| 兩個 harness(第二個操作員 / 另一 session) | 只有 chain1 的 `$TEMP` 鎖 | 節點端 lease 是唯一互斥;chain1 / brewrite / pty-commit 也 acquire | 白箱:兩個 `pr_begin` → 第二個 FAIL |
| 產品自己的重開打斷單位(joinwatch 3600 s / autocommit 期限) | — | 單位 ≤ 3000 s(F33);autocommit 期限是單位設計的一部分(hold / revert 兩型) | 時間預算表 §7.3 |
| upgrade(fleet → 含接縫的 rc) | — | 接縫 release no-op;tier B 在 rc PASS | rc 全套 |
| rollback(fleet 回 wsl.4) | — | 需接縫的單位印一行 `FAIL pre-P1b image: …`(KNOWN,有到期);其餘照跑 | wsl.4 負對照 run(PR 附) |
| `prov_test` build 被 pin / 手動 make 出貨 | — | gate(build)、P9 + tier A(`grep -c` 標記)、`--version` 第 2 行 | gate 負對照;tier A 白箱(bind 一個 test helper → FAIL) |
| downgrade(04 → wsl.9) | `prov-downgrade` | 同左 | 單位 |
| crash loop(helper) | procd respawn 固定 5 s | `prov-misc` L11、autocommit (9) | 單位 |
| 斷電 | ❌ | sysrq `b`(無 sync)五個 txn 點;真斷電列 §9 | 單位 |
| 主機 ↔ 04 eth 斷 | 逾時 | `NEEDS-PERSON`(10 分鐘連不到),不送改狀態指令;deadman 到期自己還原 bind / helper | 白箱:`nft` 暫擋 |
| 依賴重啟(bluetoothd / dbus / openmanetd / dropbear) | `prov-misc` helper 側 | + H3 provd 側 | 單位 |
| CI arm64 runner | 無 | job;排隊不受 timeout 限制(只變慢);E-H3 前不擋 PR | PR CI |
| 平台 bcm2710 | 不支援 | `prov-unit-bcm2710` smoke(沙箱) | CI |
| Git Bash ↔ WSL pipe | E6 ✅ | `provgen.py` 走同契約(`GEN …` → `OBJ <hex>`) | 20 次往返 |
| H1 / H2 / H3 同時 | BLE lease | 同一把 flock;互斥 | 白箱 |
| P2 後 provd 擁有廣播 | — | `adv-on` 先查 instances / provd running 再 `rm-adv`(v1 B-M17) | 白箱 |

## 6. 測項

每個測項:輸入、判定(**確切字串 / 碼 → 檔:行**,F9、F12、F13)、負對照、副作用與還原、類別。

### 6.1 CI(無硬體)
| 測項 | 判定 | 負對照 |
|---|---|---|
| `prov-p1-stubs`(擴) | + killpoint Go 單元測試(§4.1.1);release tag no-op | mutant 拿掉 link count 檢查 |
| `prov-gate-stubs` | §4.1.3 三種輸入 | 內建 |
| `lint-install`、`lint-wbox` | §2.2 | 刪 install 行 / 空 patch / 見證只出現 1 次 / §6.2 引用不存在的 name → FAIL |
| `prov-sandbox`(arm64) | §4.4 負測試 → p1-impl §5.1 案例(`-96`、`-cfgsave`、`-helper`、`-auth`、`-button`、`-bcm2710` smoke、`-build`) | 每案例 `--mutant` |
| `prov-unit-gate`(amd64,loop GPT 卡) | §4.4 | wsl.9 `batman-slot`;mutant 放行 claimed |
| `vectors-219`(擴) | + `verify.py` import 後 ≥ 195;`peer.py --selftest`;`provgen.py --selftest` | 既有 + 刪一個 check → FAIL |
| `known-failures-format` | 4 欄;到期 = NEW;缺欄 = FAIL | `test-known-failures.sh` |
| `peer-vs-provd`(H3,amd64) | §4.8.3 執行模型;§6.3 協定子集 | `provd.env` 開關 + 向量負向 |

### 6.2 節點(甲部;04 = DNODE 除非註明)
**tier A(每天,唯讀)**:
| 測項 | 判定 | 負對照(PR 證據階段,lease 內) |
|---|---|---|
| `prov-boot-254` | p1-impl §5.2 全部 + helper 二進位無標記字串 + `--version` 第 2 行不存在(P1b 後) | 停 helper → **> 60 s** 後 health stale(F14);`privacy off` → `privacy=0`;`batman-sc` pid 不符 → `sc_file=0`;`ble-ok`:bind 去掉 `core_freq_min` 的 distroconfig 視圖 → 不寫(p1-impl A-m5);bind 一個 test helper → 標記斷言 FAIL |
| `prov-sock-254` | §4.5 | bind 不檢查 PEERCRED 的 helper(`-wbox` 無此 mutant → 改用 `test` helper 的 Go 單元測試覆蓋 PEERCRED;節點上只做正向 + EACCES / CONN-CLOSED,明列) |
| `prov-sec-helper-uid-254`、`prov-sec-key-perms-254` | §4.5 | bind 0644 副本 → FAIL |

**tier B**(`--destructive`;hold|revert / 最終槽 / F|R;每單位 `pr_end` 斷言 02 在 `batctl n` 且 02 boot_id 不變):
| 單位 | 程序與判定 | 負對照 | 型 |
|---|---|---|---|
| `prov-base-254` | snap → 改 p5 一檔 / overlay 一檔 / p6 一 state / **刪 lower 檔 `/etc/banner`** → restore → S0(含 banner 回來);restore 的 dd 期間主機送 `echo b > /proc/sysrq-trigger` → 重跑 restore → S0;3 次 `prov-boot` | `PROV_BASE_SKIP=p5|extra`(harness 白箱開關)→ compare 必 FAIL | — / A / F |
| `prov-legacy-upgrade-254`(L17) | 釘住 wsl.9(`DV_OLD_PAYLOAD` + sha)apply 進 B 不 hold → B commit → `strip-p5-prov` → **負對照先做**:在 B 上 hold OTA `-wbox rc9-unclaimed` 進 A → A trial 內 helper log `boot rc=9 verdict=unclaimed`(mutant)→ rollback 回 B(期限內,無 bad-slot)→ **正向**:V 進 A 不 hold → A commit → helper log `boot rc=9 verdict=legacy`、AP key / lock-status / authorized_keys / mesh-expected 前後相同 | 上述(v1 A-M5) | revert→hold→commit / A / R |
| `prov-claim-254`(既有 +) | 既有 + killpoint 段(`push-helper` → `arm-killpoint claim-after-persist` → claim → sysrq → `replay` 相同 `owner_tag_key` sha)+ 空 `authorized_keys` 視圖(**同一條 ssh 批次內** bind → provclient → unbind;v1 A-m11)→ `E_UNSUPPORTED`(6) | `helper-clientchal`(bind 自 wbox payload 抽出的 helper)→ 攻擊者 ClientChal 被接受 → FAIL | — / A / F |
| `prov-netjoin-254` | `provgen` 隨機網路 → `net-apply --first` → `RESULT net.apply code=0`、`prov.meta` state=member、wireless == prov.net、overrides == prov、`rm=1`、`halow-setkey` 印 `app-managed` 警告 | `helper-nojoinop` helper bind → 無 owner-op 的 `--first` 回 code=0(被接受)= 負對照成立 → 正向斷言 FAIL | — / A / F |
| `prov-netjoin-fleet-254`(雙台,p1-impl §4.4) | fleet 實際值經 fd 3:04 先 join → 04 重新入網(`batctl n` 有 02)→ 02 join → 02 入網;還原兩台 | — | — / A / F(02 只 F) |
| `prov-leave-ota-254`(L22) | member → `leave` → p6 `mesh-expected` / `mesh-joined` 刪 → OTA V hold → B trial `claimed`、`mesh join required: 0 (prov=claimed mesh_expect=0` | `helper-noleave` → 標記留著 → B trial 要求鄰居(`mesh join required: 1`) | hold / A / F |
| `prov-ota-254`(L5) | member → OTA V hold → B:member、gen 同、wireless 同、上鎖;證據 = B 的 `/etc/.batman-prov-restore` 第 3 欄 `prov=full`(F13)+ 96 log `prov: state=member copied=full` | `-wbox 96-noprov` → `copied=none` | hold / A / F |
| `prov-lock-failsecure-254`(L5) | `push-helper` → `arm-killpoint claim-before-shadow` → claim → sysrq(claimed、無 shadow-root)→ OTA `-wbox helper-exit1` hold → B trial:`offered` 只 publickey、LOCKED(96 一律鎖) | 同前置 → OTA wsl.9 hold → UNPROVISIONED(F32) | hold / A / F |
| `prov-powerloss-254-txn{1,2,3,4,5}`(L7,五個單位) | `push-helper` → `arm-killpoint txn-N` → `net-apply --update`(或 join)→ sysrq → 重開(release helper)→ 依點斷言:txn-1:`.txn` 刪、wireless 不變;txn-2:對帳改回(`.txn` 處理 log 行,P1b 補一行 `txn <tok>: reverted wireless to .txn values`)、p5 gen 不前進;txn-3:p5 已 n+1 → overlay 重建、wireless == prov;txn-4:`--save` 補做、wireless == prov、overrides == prov;txn-5:`--check` rc 0、prov-state 本次;全部:key 登入可用、sysrq 行(§4.1.1) | (a) txn-2:注入前 `batman-provhelper disable` → sysrq → 重開(helper 不自啟)→ 斷言 `.txn` 在、wireless ≠ prov → `mv .txn .txn.dv`(真 overlay 操作,快照還原)→ `enable`+`start` → wireless 仍 ≠ prov、無對帳 log → 正向斷言 FAIL(v1 A-M4);(b) txn-3:`helper-notxn` bind **在重開前**無效(bind 消失)→ 改用 `-wbox helper-notxn` 進 B 的 hold trial 做同一注入 → 不重建 | — / A / F;(b) hold / A / F |
| `prov-netupdate-254`(L25、L26) | bind `halow-setkey` 副本 `exit 1` + `--on-join` → **p5 `overrides.uci` 的 radio1 key / mesh_id 不前進**;`arm-killpoint txn-3` + `--on-join` + sysrq → member | bind 不讓路的 config-save 副本(去掉 txn-live 拒做)→ p5 overrides 前進到未提交值 → FAIL(v1 A-M4) | — / A / F |
| `prov-trial-busy-254`(L21) | OTA V hold → B trial `claim`(經 eth)→ `E_BUSY`(7) | `helper-notrial`(bind 在 B trial 內,重開前觀察)→ 被接受 | hold / A / F |
| `prov-overlay-corrupt-254`(L33) | 寫垃圾進 A 的 `prov.cbor` → 重開 → helper log `overlay record unusable:` + 以 p5 重建、gen 相等 | `-wbox helper-nogen` hold 進 B 做同一注入 → 不重建 → `unknown` | — / A / F;負對照 hold / A |
| `prov-overlay-wipe-254`(L60) | overlay 清空(overlay-restore 的「刪多出」路徑,空 tar)→ 重開 → state、`device_id` 不變 | `-wbox 96-norestore` hold → legacy / 新身分 | — / A / R |
| `prov-downgrade-254`(L12) | claimed → OTA wsl.9 hold → 還原、LOCKED、`ttylogin=1`、p5 prov 檔不刪(characterization,無鑑別力) | — | hold / A / F |
| 鏈 0(L15) | p1-impl §5.4:apply V 進 B + cmdline `batman_bypass=1` → 受控重開 → `none` 登入 → `unknown(bypass)`、不產身分、persist 拒、96 exit 1 | 同鏈不加 bypass → 正常 | hold / A / F(兩個 lease) |
| `prov-autocommit-254` (1) | `-wbox radio1-off` 進 B **revert** → `TRIAL-REVERTED … reason=` 含 mesh → `bad-slot` 清法 §4.3;誤 commit → 跨槽還原 + FAIL | 本身 | revert / A |
| (3)(L31) | member 單台 → OTA V hold → `is healthy and HELD` | — | hold / A |
| (4) | `-wbox chan` revert → 前置 120 s 內不在 mesh、F15 settled 行(150 s 內沒出現 → FAIL「mutant 無效」)→ `TRIAL-REVERTED` | — | revert / A |
| (5) | OTA V hold,trial 內刪 `ota-armed.mesh` → `otalog AC UNHEALTHY first_why=need-mesh…`(F12) | — | hold / A |
| (6) | `sysupgrade -T` 後直接 `batman-slot apply` → 同上 | — | hold / A |
| (7)(L40,v1 A-M8 改法) | 04 在 A 在 mesh;02 hold OTA V 進 B → 02 `HELD` → 02 `release --wait` → 02 committed(04 的 `lastjoined` 為真);**之後** 04 `-wbox chan` revert → 04 `TRIAL-REVERTED`,04 stage 1 寫的 `ota-armed.mesh` 行為 `… joined`(從 04 的 otalog 讀);02 全程 committed,04 回來後讀 02 的 autocommit log 確認 02 沒有 revert;02 的 B 寫回 V 以 brewrite(hold,安全方向;p1-impl §7.4) | — | 02 hold / 04 revert / 兩台 A(兩個 lease) |
| (8) | `ble-ok` 在 + `btmgmt power off` → `WARN ble: ble-ok present …` 行 **且** `HELD`;`ble-ok` 不在(`state-set ble-ok absent`)→ **沒有**該行 且 `HELD`(v1 A-m10) | 兩臂互為對照 | hold / A |
| (9) | `-wbox helper-flap` hold,**04 須有 `ble-ok`** → `WARN ble: … (no health file)` 行 + `HELD`;`release` → 依 P-U5 **預期 commit**(stale 只 WARN);commit 後跨槽還原 | — | hold → commit / A → 跨槽 |
| (10)(L41) | 非 root / 容器 root 偽造 sysupgrade cmdline、相對路徑 → 無 `ota-armed.mesh`;`-T`、真 OTA(hold)、中止後 LuCI validate 各一次 → 檔案有無正確 | — | hold / A |
| `prov-misc-254` | L38(`misc-L38`:96 `:89` 出口 + p6 claimed → 仍鎖)、L42(`misc-L42`:直接 apply 無 `ota-armed.mesh` → `mesh join required: 1`)、L43(`misc-L43`:`.stage/` 殘留被丟棄)、L51(`misc-L51`:socket 目錄預先放 symlink → helper 拒絕啟動 `sock: unexpected`);L11 helper 重啟 ≤ 15 s health 恢復;L9 / L10 bluetoothd / dbus 重啟 → health 15 s;L27 dropbear 重啟後 key 登入;L3 clean shutdown → boot-reasons 乾淨 | 各 mutant | hold / A / F |
| `prov-verbs-254` | p1-impl §5.6 正向含 `settings.get`、`settings.set hostname` → `E_UNSUPPORTED`(6,reason rename-pending)、未知 key → `E_SCHEMA`(20)、`owner.add / remove`、`ssh_keys.set`、`diag.bundle`、`qr` | `prov-unit-auth`(沙箱) | — / A / F |
| `prov-eeprom-hooks-254`(WSL,stage1 §8) | 對解出的 rc rootfs:shim 對所有 key `READ` rc 1;PATH 假 `vcgencmd` 回 `dropbear_authorized_keys` / `device_password` / `default_wifi_key` / `mm_region` → 讀者(96、95、morse.sh)不採用 | 1.5.12 rootfs(釘住)→ 採用 | WSL |

### 6.3 節點(乙部,H3;P2 rc 後)
| 單位 | 程序與判定(§8 對應列) | 負對照 | tier |
|---|---|---|---|
| `prov-firstboot-254`(provd 側) | 鏈 1 第 5 步加:B trial 的 `STATUS` 經 BLE 可讀、`updating=1`、`device_id` 末 4 碼在、無 AP | 1.5.12 新卡 → 無廣播(**重燒,手動**) | 併鏈 1 |
| `prov-boot-254`(provd 側) | health `adv_registered_once=1`;provd uid 471、ujail;廣播有、無 Local Name;已認領 `STATUS` 不帶末碼;**health 轉壞 → ≤ 10 s 撤廣播**(白箱:bind `bondable=1` 的 health 視圖);**連線建立即撤、斷線後新 nonce 重註冊**(`peer.py` 連 → 02 掃不到;斷 → 新 nonce)(stage1 §8 A-N2 / B-m2) | 停 provd → ≤ 10 s 無廣播 | A(白箱段 B) |
| `prov-respawn-254`(L8) | kill provd ×5 → procd 每次 5 s respawn;provd 自己的退避行(P2 契約:`provd: backoff <n>s`)遞增;`info.state` 不變 | — | A |
| `prov-dep-restart-254`(L9–L11) | bluetoothd / dbus / helper 各重啟 → provd `NameOwnerChanged` 重註冊 ≤ 15 s;無 hci0 → `hci0_powered=0` | — | A |
| `prov-two-phones-254`(L24) | 兩個 `peer.py`(sock + BLE)同時 `claim/finish` → 一個 0、一個 **`E_BUSY`(7)**(F9:無 `E_STATE`) | — | B |
| `prov-provd-dos-254`(L39) | OTA V hold;trial 期間 `peer.py` 反覆連線 + 超大訊息(§8:斷線,不是 crash)+ `kill` provd ×10 → `HELD`;health 不看 provd 存活 | — | B |
| `prov-ble-claim-254`(L18 / L34 / L47) | `peer.py` BLE:NX → `claim/begin` / `finish` → 密碼 → `psk_replay` → `claim/replay` 相同 `owner_tag_key`;`arm-killpoint claim-after-persist` → sysrq → replay;**`claim/replay` 10 / h**(第 11 次 `E_RATE` 12) | 錯 `owner_pub` → 3;NX 對已認領 → 假第 2 則 | B |
| `prov-sec-claim-brute-254`(§8 認領失敗 3 次) | 同連線 3 次錯 → 斷;新連線再 3 次 → 斷;`claimed_counter` 不變 | `NO_BRUTE_LIMIT=1` → 4 次仍連著 | A(sock) |
| `prov-sec-hog-254` / `-oversize-254`(§8 同時連線 2、交握逾時 10 s、閒置 30 s、單則 8192) | 3 條連線(2 sock + 1 BLE)→ 第 3 條被拒;不交握 10 s → 斷;交握後閒置 30 s → 斷;單則 > 8192 → 斷;分塊超 `max_msg` → 斷 | — | A/B |
| `prov-sec-psk-timing-254`(§3.4) | **sock 上**:先量 n=50 正確 PSK 的第 2 則延遲分佈定抖動;PASS = 錯 PSK vs 對 PSK 的中位數差 < max(2 × 抖動 MAD, 5 ms) 且差值 95% bootstrap CI 在 ±該值;明寫不能驗「相同次數 DH」 | `FAST_FAKE_DELAY_MS=20` → 差 ≥ 20 ms | A |
| `prov-sec-dbus-254`(擴) | tier A:`provclient exec dbus-send …`(uid 471)呼叫 `AgentManager1.RegisterAgent`、`Properties.Set Pairable`、`Device1.Pair` + 3 個未列方法 → AccessDenied;以 root 同方法 → 成功(鑑別力);**tier B(02 連著)**:`Device1.Disconnect` → 成功;bluetoothd → provd `ReadValue` / `Release` 回呼 → 成功(`peer.py` 讀 `CTRL`) | root 對照 | A + B |
| `prov-sec-bond-254`(翻轉;provd 停止模式) | 停 provd → `adv-on` → 04 掛 agent(白箱常駐 `bluetoothctl agent NoInputNoOutput`)→ 02 SC Just Works → **通過**(外洩)→ 收 agent → 擋下 → `rekey` + 04 重開(H-U6)→ 起 provd | 本身翻轉 | B |
| `prov-coex-254`(L28) | AP 客戶端 = **Windows 主機 Wi-Fi**(radio On)連 04 的 2.4 GHz AP;iperf 到 04 60 s 基線 → 同時 `peer.py` BLE 連續 `status` 60 s → 記差異與 BLE 斷線數;第一輪只記錄(D-H6),第二輪起門檻 = 基線 − 30% | — | B |
| `ble-rpa-254`(provd 模式) | 廣播者 = provd;判定改為「RPA 改變 ⇔ provd 重註冊事件」(P2 契約:provd log 一行 `provd: adv re-registered reason=<rpa_timeout\|connect\|disconnect\|health> nonce=<8hex>`,harness 以 btmon 時間對齊);N1 負對照 = 停 provd + 既有 `adv-on`(≥ 30 分同 RPA) | N1 / N2 / N5a | B |
| `prov-sock-254` → tier B | 停 provd 才跑 | 同 §4.5 | B |
| `prov-gatt-254` | `peer.py` BLE:MTU、分段(1 B / 剛好 / 超過)、序號亂 → 斷、notify 回壓 100 則;**特徵旗標**從 02 端 `bluetoothctl gatt.attribute-info` 的 `Flags`(不是 bleak properties,v1 B-m14)→ 無 `encrypt-*` / `authenticated-*` | 序號亂不斷 = FAIL | B |
| iPad GATT 回歸 | ⚠️ 手動:步驟 `docs/validation/ble-ipad.md`,結果貼 PR | — | 手動 |

## 7. 安全

- **資產**:04 / 02 控制權與 S0、擁有者測試金鑰、fleet mesh key、root 密碼、IRK;runner 宿主。
- **actor / 攻擊面 delta**:

| actor | 攻擊 | 擋法 | 負測試 |
|---|---|---|---|
| 本機非 root(節點) | 預建 `/tmp/run/batman-prov-test/` 或寫 killpoint / `provd.env` | root 0700 + 0600 + link 1 + 非 symlink;release 不讀 | Go 單元 + 節點白箱(`nobody` 預建 → refused) |
| 本機非 root | 碰 bind 副本 / `wbox.list` | root 0700 `/tmp/run/batman-dv/wbox/` | tmp-trust |
| 本機非 root | 連 provd 測試 socket | root:provd 0750 目錄、0660 socket;只在 `prov_test` | `sock-as 65534` → EACCES |
| 攻陷的 provd(P2) | 經測試 socket 對自己送請求;寫 `provd.env` | socket = BLE 入口,helper 不信 provd;`provd.env` 在 root 0700 目錄 provd 寫不進 | `peer-vs-provd` 負向;perm 測試 |
| OTS 容器 / tenant root(v1 B-m14) | 碰 `/dev/log`、`/tmp/run`、`/opt/batdata/state` | deploy/ots 沒有這些 bind(F35);容器 netns + capdrop | grep 證據;既有 autocommit (10) |
| 第二個操作員 / 另一 session | 同時跑 harness | 節點端 lease 唯一互斥(含 chain1 / brewrite / pty-commit) | 白箱 |
| 遠端 BLE 路人 | 對 `prov_test` 節點用開關 | env 只在節點本機 root 檔;release 無 | gate + strings |
| 供應鏈 | `-wbox` / `prov_test` image 混進出貨 | gate(build 第 7 步,含見證與標記)、P9(`.protected` 缺 / 含 wbox、helper 標記)、tier A 每天標記;`.dirty.wbox` 在 VER | gate 負對照;tier A 白箱 |
| 我們自己 | 忘了還原 feeds/batman、stale helper | trap 還原;stamp DIRTY;wbox stamp → clean;gate 三條 | E-H2 白箱 |
| 我們自己 | 沙箱逃逸 | §4.4 負測試 | 內建 |
| 我們自己 | 金鑰外洩 | WSL ext4 0600;每 run 換;canary | canary = 0 |
| 我們自己 | 無人值守留壞狀態 | `NEEDS-PERSON` + DNODE 擋;deadman 不碰槽 / p5;restore 中 deadman 不起 joinwatch | 白箱 ×3 |
- **privilege**:節點端腳本 root(必要);provclient 降權後連 socket / exec;`dbus-send` 以 471。
- **secrets**:同 p1-impl §8;IRK 翻轉後作廢;`peer.py` PSK 只在記憶體。
- **failure mode**:P9 缺項 = FAIL;killpoint 檔不符 = 忽略;沙箱負測試不過 = job FAIL;`pr_find` 找不到 = `NEEDS-PERSON`,不盲送指令。

### 7.3 成本(⚠️ 推估;E-H2 量後更新)
- 單位 30–45 分 × 約 30 = 15–22 h;autocommit (1)(4)(7-04) 各多 600 s revert;(9) 多一次跨槽還原(+15 分)。
- `-wbox` build 17 個 × ⚠️ 分鐘(E-H2)。
- 04 OTS 累計斷約 4–5 h;02 隔離約 3 h + (7) 一次 held trial;SD 約 45 GiB。

## 8. 工作順序與 PR
1. 本設計兩位審查到 0 BLOCKER / 0 MAJOR;§10 回報上層。
2. **實證**(先列副作用):
   - **E-H1**:使用者打開主機藍牙 → `pyble` venv 加 `noiseprotocol`(⚠️ Windows wheel)→ 04 lease 內 `adv-on`(非連線)→ 主機 `bleak` scan 看到、記 RSSI → `adv-off`;順便 04 `ls /usr/lib/libdbus-1.so*`、`which unsquashfs`。副作用:04 廣播 ≤ 2 分。
   - **E-H2**:firmware `build-board.sh --wbox test` 與 `--wbox rc9-unclaimed`(兩種:純 tag、帶 patch)build;量時間;gate 反向;之後正常 build → gate PASS、helper sha ≠ test 變體(證明重編)、樹乾淨;中途 Ctrl-C → 樹乾淨。
   - **E-H3**:CI `ubuntu-24.04-arm` job 只跑 §4.4 負測試 + unsquashfs 底 + busybox ash `echo`;記排隊時間。
   - **E-H4**:E5 `prov-artifact-match`(F34 整串旗標)。
   - **E-H5**:04 上 `lock-hold` + helper `--save` 撞鎖 → log `busy, retrying once`(= `prov-claim` 一個單位)。
   - **E-H6**:04 上 `echo b > /proc/sysrq-trigger` 一次(S0 快照後)→ 重開、boot-reasons 記錄為何;確認 `kernel.sysrq` 值。副作用:04 一次硬重開。
3. PR-P1b(`feat/254-p1b-seams`)實作 §2.1 + firmware `--wbox` / stamp / gate → rc `1.5.14-wsl.5` + 17 個變體。
4. harness 實作;每單位先在 wsl.4 跑負對照(`pre-P1b` 行),兩台 OTA wsl.5 → 單位逐個 PASS → 全套(含完整 prov tier B,無人值守)。
5. harness PR 先 merge(紅燈 KNOWN,有到期)→ PR-P1b + firmware pin → 出貨 build 重跑全套。
6. 乙部與 P2 設計一起;H3 測項在 P2 rc 上 PASS 後再 PR(或同 PR 第二段,D-H5)。

## 9. 殘項(回 #254)
- 真斷電;bcm2710 真機;iPad GATT 手動;`prov-rename`(U5);opaque 目錄未查(風險接受);L16 節點層(現場);`prov_test` vs release 行為差異只靠 gate + tier A/B(E5 若不可重現);release asset 掃描(不做,理由 §1.2);`docs/validation` 的 P-U10 文字(另 PR);B16 nonce 長度對 UUID 預算(P2);`prov-sock` 的 PEERCRED 負對照只在 Go 單元。

## 10. 回報上層
1. p1-impl §4.5.3 同槽重建 = 鏈 1 程序;E4 作廢;§4.5.0 順序改為「prov tier B 在 2g 之前 + 正規化」。
2. p1-impl §2.2:`dv-sbx` shell;`-wbox` 真 build + 見證;known-failures 到期欄落地。
3. stage1 §10:H3 = 本文;P2 設計要收 §4.8.2(sock = BLE 連線、控制包)、§4.8.3(`provd.env` 三開關、`SOCK_ONLY`)、§4.9(UUID + scan response)、provd log 契約(`adv re-registered reason=…`、`backoff`)、ujail 多掛 `/tmp/run/batman-provd-test`。
4. 219 §4.1 / §8 / §12:Q1 定案;sock 傳輸計入 §8;`E_BUSY` 用於兩支手機同時認領。
5. stage1 §4.4:P1b 補一行對帳 log `txn <tok>: reverted wireless to .txn values`。

## 11. 待決
| # | 題 | 建議 |
|---|---|---|
| D-H1 | `dv-sbx` shell / Go | shell |
| D-H2 | `-wbox` 真 build / 改寫 | 真 build |
| D-H3 | `peer.py` Noise 函式庫 | `noiseprotocol`(v2 改) |
| D-H4 | UUID | 128-bit + scan response |
| D-H5 | H3 同 PR 第二段 / 第二個 PR | 看 P2 時程 |
| D-H6 | coex 門檻 | 第一輪記錄 |
| D-H7 | 斷電代理 | sysrq `b`(v2 改) |
| D-H8 | 主機 bleak RSSI | E-H1 |
| D-H9 | txn-1 / txn-5 要不要測 | 要(五單位) |

## 12. v1 審查 → v2 對應
| 發現 | 處置 |
|---|---|
| A-B1 / B-B1 順序 | §4.3:prov 區塊移到 2g 之前 + `pr_normalise` + 白箱 |
| A-B2 `prov_test` helper 到 A、`test` 變體、重建雜湊 | §4.5 `push-helper`;§4.2 `test` 無 patch 例外 + stamp 強制 DIRTY + wbox stamp → clean;E-H2 |
| B-B2 四個 helper mutant 不存在 | §4.2 補 `helper-nojoinop / noleave / notrial / clientchal / notxn`;lint 查引用 |
| B-B3 / A-M6 socket 目錄 / ujail / env / CI 模型 | §3、§4.8.2、§4.8.3:獨立目錄 `batman-provd-test`;`provd.env` 契約;`SOCK_ONLY`;CI useradd 471 |
| A-M1 bad-slot | §3 列;§4.3 預期 REVERT 收尾;§5 兩列 |
| A-M2 / B-M1 版本與見證 | §4.2:`batman-build.txt` + unsquashfs + 見證;gate 第 7 步 |
| A-M3 sysrq;txn-1/5 | §4.1.1;五個 powerloss 單位 |
| A-M4 / B-M2 powerloss / netupdate 負對照 | §6.2:`disable` 法 + `helper-notxn` hold;p5 overrides 斷言;通則「重開後觀察不用 bind」 |
| A-M5 legacy-upgrade | §6.2:負對照 = held A trial + rollback |
| A-M7 / B-m2 NEEDS-PERSON | §3、§4.3:`DNODE_BLOCKED` 擋 D 類;rc 契約 |
| A-M8 autocommit (7) | §6.2 (7) 改序 |
| B-M3 lease / ch1 deadman / 主機鎖 | §3、§4.7 |
| B-M4 六項丟掉 | §1.2 / §2.2 / §6.2 / §6.3 全部收回(到期欄、sec-helper-uid、key-perms、eeprom-hooks、provd A-N2/B-m2、雙台 netjoin、ble-ok 負對照、settings.set) |
| B-M5 / A-m12 peer.py 裁判 | §4.8.1:`noiseprotocol`;selftest 對 gen.py transcript;verify.py 模組層無 I/O |
| B-M6 timing | §6.3:sock、抖動定 n、效應量、`FAST_FAKE_DELAY_MS` |
| B-M7 brute | `NO_BRUTE_LIMIT` |
| B-M8 dbus | `exec` 動詞;Disconnect / 回呼移 tier B |
| B-M9 / B-M10 bond 翻轉 / rpa provd 模式 | provd 停止模式;RPA ⇔ 重註冊 log |
| B-M11 sock vs §8 / `E_STATE` | §4.8.2;`E_BUSY` |
| B-M12 / A-m10 判定字串 | F9、F12、F13;§6.2 各列改寫;(8)(9) 兩臂 |
| B-M13 prov_test 無 wbox | P9 + tier A 標記 |
| B-M14 release-scan | 刪該句,§1.2 理由 |
| B-M15 / B-M16 deadman restore / 記憶體 arm | §3 `restoring`;`wbox.list armed`;P9 |
| B-M17 adv-on | §2.2 `ble-periph` 改 |
| A-m1 gate 位置 / shell helper | §2.1、§4.1.3 |
| A-m2 chain1 > 3000 | 例外明列;02 boot_id 每單位 |
| A-m3 whiteout | `prov-base` 刪 lower 檔負對照;opaque 列 §9 |
| A-m4 lease 鎖 | 同一把 flock |
| A-m5 / B-m1 計數 | F3 13、F26 7 行;到期欄 |
| A-m6 `.protected` 缺 | §4.7 |
| A-m7 目錄刪除者 | §3 |
| A-m8 傳輸三件事 | §4.8.2 |
| A-m9 / B-m9 沙箱 | §4.4 步驟順序、gate 獨立、排隊 |
| A-m11 authorized_keys | 同一 ssh 批次 |
| B-m3 killpoint stub | Go 單元 |
| B-m4 pre-P1b | `--version` rc |
| B-m5 provd-dos / respawn | §6.3 改寫 |
| B-m6 coex | 主機 Wi-Fi 客戶端 |
| B-m7 UUID 預算 | §4.9 |
| B-m8 tmp-trust | §2.2 |
| B-m10 ldflags | F34 |
| B-m11 keygen 格式 | F10、§4.6 |
| B-m12 Windows 依賴 | F17(已裝;noiseprotocol E-H1) |
| B-m13 矩陣 / 擁有權缺列 | §3、§5 補 |
| B-m14 其他 | §6.2 stale 60 s;§6.3 gatt Flags;firstboot 手動;OTS actor §7 |
