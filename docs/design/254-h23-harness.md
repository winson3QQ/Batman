# Design: #254 PR-H3 — harness:H2 補完(P1 tier B / 沙箱 / 接縫)+ H3(provd / BLE / `peer.py`)— **v1(審查中)**

**狀態**:v1,2026-10-28。使用者決定(2026-10-28):H2 沒做完的部分照 `254-p1-impl.md` §5 補完,與 H3 一份設計、兩段實作;608B(#255)擱置。審查:兩位獨立審查者審整份(通用規則:擁有權 / 契約 / 生命週期矩陣 / 證據 / 安全 / 負對照)。

上層:`254-stage1-impl.md` v19(§9 測試、§10 切法)、`254-p1-impl.md` v5.1(§4.1 接縫、§4.5 基準與還原、§5 H2 測項)、`254-h1-harness.md` v8(§3 擁有權、§4.7 lease / deadman)、`254-claim-lock-fix.md` v9.1(§11.4 真機規格)、`219-protocol.md` v0.7(§3–§5、§8、§11)。

## 0. 一句話

一個 harness PR(`harness/254-h23`)把 P1 的測試補到設計要求的覆蓋(約 28 個 tier B 單位 + CI 沙箱矩陣),並為 P2 準備協定對手 `peer.py` 與 provd / BLE 測項;產品只加「為了可測」的接縫(`--killpoint`、`prov_test` build、`-wbox` 變體、provd 測試傳輸),由一個小的產品 PR(PR-P1b)與 PR-P2 承擔。

## 1. 決策、範圍、事實

### 1.1 使用者決策
| # | 決定 | 日期 |
|---|---|---|
| H3-U1 | H2 缺口**照設計補完**(選項 1),不做 H2-lite:少掉的 powerloss ×3 / lock-failsecure / autocommit (1)(4)(7)(8)(9) / 沙箱矩陣正是現場最危險的路徑 | 2026-10-28 |
| H3-U2 | 一份設計(本文),兩段實作:甲 = H2 補完 + 接縫(現在就能在 wsl.4 基礎的 rc 上驗);乙 = H3(等 P2 rc) | 2026-10-28 |
| H3-U3 | 成本接受:完整 prov tier B 一輪 15–20 h、04 OTS 累計斷約 4 h、02 隔離約 3 h、SD 約 40 GiB;依 P-U10 只在動到 prov 的 PR 與發版時跑 | 2026-10-28 |
| H3-U4 | 608B / #255 擱置,不是本單前置 | 2026-10-28 |
| (沿用)H-U2 / H-U3 / H-U4 | harness 先進 main;`peer.py` 在 H3;coex 在 P2 | 2026-10-20 |
| (沿用)P-U9 / P-U10 / P-U12 | harness merge 後產品 merge 前紅燈;prov tier B 只在 prov PR 與發版;無人值守 + 停在安全點 + 推播 | 2026-10-21 |
| (沿用)P-U14 | 量產 CM4;bcm2710 不支援,真機只有 04(DNODE)與 02 | 2026-10-23 |

未明說、本設計照建議寫(審查者可攻):
- **Q1 服務 UUID = 自訂 128-bit**(§4.9),不申請 16-bit。
- `peer.py` 的主要傳輸 = provd 在 `prov_test` build 開的本機 frame socket(§4.8);BLE 空中以 Windows 主機 `bleak` 走 MediaTek 藍牙(§4.10,⚠️ D-H8)。

### 1.2 範圍
**甲部(H2 補完;在 1.5.14-wsl.4 + 接縫 rc 上驗)**
1. 接縫規格(產品,PR-P1b;§4.1):`--killpoint`、`prov_test` build tag + gate、`-wbox` 變體 build 流程、`BATMAN_WBOX` 版本標記。
2. 節點 tier A:`prov-boot-254`(`scripts/node/prov-p1-254.sh` 接線)、`prov-sock-254`。
3. 節點 tier B(04):`254-p1-impl.md` §5.3 全部 + §5.4 鏈 0 + §5.5 autocommit (1)(3)–(10)。
4. 沙箱(CI `ubuntu-24.04-arm`):`dv-sbx` + §5.1 全部。
5. 主機端程式庫 `scripts/dv/prov-254.sh`(lease、snap、OTA 到 B、找節點、還原 F / R、B 寫回 V、安全點、通知)。
6. P9 preflight 補 §4.7;全套順序(§4.5.0);known-failures:移除 #254 過渡條目,新增「pre-P1b / pre-P2 image」條目;chain1 開跑前兩槽 = V。
7. `provclient` 擴充:`net-apply`(join / update)、`leave`、`owner-add` / `owner-remove`、`diag`、`verb`(已有)。COSE 物件由 Python(`tests/tools/provgen.py`,與 `gen.py` 同一套函式庫)產生,provclient 只傳輸。

**乙部(H3;等 PR-P2 rc)**
1. `peer.py`:協定對手(手機角色 + 攻擊者角色),§4.8;`verify.py` 改成可 import(`MIN_CHECKS` 不變,CI 負對照證明判定沒變)。
2. provd 測項(§6.3):firstboot / boot provd 側、respawn、bluetoothd / dbus / helper 重啟、two-phones、provd-dos、BLE 認領 + replay、sec-claim-brute、sec-hog / oversize、sec-dbus(provd uid)、sec-bond 翻轉(SC JW 負對照)、coex、`prov-sock` 移 tier B、`ble-rpa-254` 改用 provd 廣播、GATT 回歸。
3. P2 要開的測試接縫(§4.8):frame socket、`prov_test` mutant 開關(owner-op 不驗、PSK 假第 2 則不等逾時)。

**不在本 PR**:P3 的測項(H4);bcm2710 真機;轉賣工具;iPad GATT 回歸只能手動(⚠️,§9)。

### 1.3 事實(2026-10-28 唯讀實查,main 5914f03;fleet 02/04 = `1.5.14-wsl.4+7fd2124.fw6be516a`,`BATMAN_DIRTY=0`)
| # | 事實 | 證據 |
|---|---|---|
| F1 | P1 出貨**沒有**任何測試接縫:`killpoint` / `prov_test` / `wbox` 在 feed、scripts、tests、CI、firmware `scripts/` 零命中 | `grep -rn` 2026-10-28 |
| F2 | H2(#306)實際交付:`prov-base-254.sh`(snap / manifest / compare / p5-restore / overlay-restore / finish)、`prov-p1-254.sh`(tier A 判定,**未接線**,只在 `rundir-paths.txt` 被提到)、`addr-defer-254.sh`、CI `prov-p1` stub、`prov-claim-254.sh` 草稿;§5.1 沙箱與 §5.3 其餘 tier B 沒有 | `#306` body 第 8、11 行;`scripts/dv/*`、`daily-validation.sh` 2f/2g |
| F3 | daily-validation 現有 #254 測項 12 個:`ble-privacy / ble-rpa / ble-pair-sc-only / ble-privacy-reboot`、`prov-tools`、`addr-defer`、`prov-lock-rest`、`prov-p1-stubs`、`setsid-race`、`prov-claim`、`adr-reconcile`、`chain1`、`pty-commit` | `grep -o 'suite (prov|chain1|…)'` |
| F4 | `prov-base-254.sh` 的 restore 只有「逐檔」;**沒有** `firstboot -y` 同槽重建;鏈 1 的 R 類還原實際走 p5-restore → overlay-restore(tar 覆蓋 + 刪多出的檔)→ brewrite B,已在 wsl.3 / wsl.4 PASS | `chain1-254.sh:122-176`;firmware#24 鏈 1 PASS |
| F5 | E4(`firstboot -y` on f2fs-on-loop,F33)**沒做**;`overlay-allow.txt` 有 3 條帶證據的規則(openmanetd.db、board.json、bat-hosts) | p1-impl §13 E4 ❌;`tests/prov-p1/overlay-allow.txt` |
| F6 | sysupgrade payload 只有 `SHA256SUMS`(root.squashfs + boot/*)+ `metadata`,**沒有簽章**;stage 1 / `batman-slot precheck` 以 sha 驗 | `platform-ab.sh:12,156,329,374`;`batman-slot:595-600` |
| F7 | 版本戳由 `scripts/stamp-batman-build.sh` 產生:`VER=$REL-$CH.$N+$F7.fw$W7`,feeds/batman 有修改 → `BATMAN_DIRTY=1` 且 VER 加 `.dirty`;OpenWrt `golang-package.mk` 支援 `GO_PKG_TAGS` | `stamp-batman-build.sh:51-67`;`golang-package.mk:106-260` |
| F8 | helper CLI:`--boot`、`--apply-state [--firstboot]`、`--persist-now`、`qr`、daemon;`Sys` 介面 20 個方法(可 fakeSys);交易 `commitTxn` = stage → `--prov-only` → overlay rename;`net.apply` 另有 setkey 步驟 | `cmd/batman-provhelper/main.go:380-415`;`node/node.go:62-100`;`node/txn.go` |
| F9 | `provclient` 動詞:`info`、`claim` / `claim-attacker`、`replay`、`ssh-keys`、`root-reset`、`rename`、`verb`;**沒有** `net.apply` / `network.leave` / `owner.*` / `diag.bundle`;selftest 對向量 | `tests/tools/provclient/main.go:490-558` |
| F10 | `batman-autocommit` 有 `AUTOCOMMIT_DRYRUN=1` / `AUTOCOMMIT_TIMEOUT`(bench 接縫,已存在);hold-commit / hold-once / skip-once / release 機制在 | `batman-autocommit:26-28,44-60,97-100,151-165,260-282` |
| F11 | 99-batman-chanfix 的 log 行:`reassert radio1 channel <cur> -> <CH> from p5 (try <a>) + wifi reload`、`radio1 channel is <CH> (settled after <a> reassert)` | `99-batman-chanfix:47,53` |
| F12 | 節點沒有 python3、dbus-send、busctl、unshare;firmware 樹有編好的 `dbus-send`(`build_dir/.../dbus-1.14.10/tools/dbus-send`)與 python3-base ipk(無 dbus / cbor2 / ecdsa) | 04 `which` 2026-10-28;`ls build_dir` |
| F13 | Windows 主機:Python 3.12 / 3.13,**沒有** `bleak`;MediaTek Bluetooth Adapter(狀態 OK);現有 `DV_PY`(WSL venv,`cryptography`)給 `ble-ah.py` | `Get-PnpDevice`、`python -c "import bleak"` 2026-10-28 |
| F14 | GitHub `ubuntu-24.04-arm` / `ubuntu-22.04-arm` 對公開 repo 免費(2025-01 公開預覽;私有 repo 不可用);winson3QQ/Batman 是 PUBLIC | github.blog changelog 2025-01-16;`gh repo view --json visibility` |
| F15 | `tests/vectors/219-protocol/verify.py`(661 行)是純腳本:頂層 import + `check()`,沒有 `main()`;CI `vectors-219` 以 `MIN_CHECKS=195` + gen 逐位元組 + 竄改負對照把關 | `verify.py:16-281`;`ci-check.sh` |
| F16 | repo 沒有 provd / Noise / GATT / UUID 程式碼;`feed/batman-prov/src/` 有 `proto`(標籤、CheckMac、owner-op、HKDF、ES256)、`cbor`、`cose`、`shacrypt`;go.mod 只依賴 `golang.org/x/crypto`,沒有 `flynn/noise` | `go.mod`;`proto/proto.go:1-25` |
| F17 | 04 BLE current settings:`powered le secure-conn privacy`;bluetoothd 5.72 + patch 900;04 `/tmp/run/batman-dv/bt` 無殘留 | 04 `bluetoothctl mgmt.info` 2026-10-28 |
| F18 | 已有的 BLE harness 基礎:`ble-lib-254.sh`(lock / lease / deadman / `settings` / `sc_check`)、`ble-periph-254.sh`(`adv-on` = `btmgmt add-adv -g -u 181c -d <name> 1`、`adv-off`、`flip`、`privacy-off`、`restore`、`rekey`、btmon)、`ble-central-254.sh`(02:reset / sample / pair rounds)、`scripts/lib/ble-254.sh`(`ble_stage`、`ble_begin` / `ble_end`、`ble_pre`) | 原始碼 |
| F19 | `prov-lib-254.sh`:`pl_prep` / `pl_restore` / `pl_end`、`pc`(provclient 經 ssh,簽章在 WSL)、`pk_proof`、`offered`、`probe`(cryptprobe)、`lockstate`、`p5shadow`;`brewrite-254.sh`:`back_to_a`、`settle`、B 寫回 V 的 E3 迴圈(10/10 PASS) | 原始碼;p1-impl §13 E3 |
| F20 | 鏈 1 的「找到 04」= `find04`(mDNS + ARP 掃 `10.41.254.0/24` + `10.41.1.0/24`,以 eth MAC 與 `batman-slot` 狀態判定);deadman 在 p6 `dv-prov/ch1-deadman.sh`,一次性、只在 B | `chain1-254.sh:57-92` |
| F21 | 既有 known-failures 的 #254 過渡條目 6 行(prov-p1-stubs ×3、prov-lock-rest、setsid-race、prov-claim、chain1 8.3);fleet 已是修正版 → 這些條目已過時 | `scripts/validation-known-failures.txt` |
| F22 | claim-lock §11.4 的 4 / 4-inj / 4b / 4b' / 4c / 4d / 5 只有 CI stub(真機腳本撰寫被中斷,使用者選縮小範圍,**不要重寫 `prov-lock-254.sh`**) | memory 2026-10-26;`#254` checklist |
| F23 | 04 的 S0 沒有被證明等於出廠(10-26 手動還原快照太早 finish);之後的鏈 1 / wsl.4 短驗證在它上面取了新的 S0 並 PASS → 本 PR 的 S0 = 現在的 04 狀態(claimed → 已還原 legacy) | claim-lock-fix §13;10-27 全套 |

### 1.4 與上層設計不同處(→ 回報上層 §10)
- p1-impl §4.5.3「同槽重建 = `firstboot -y`」改為鏈 1 已證實的 p5-restore → overlay-restore → reboot committed(F4、F5);`firstboot -y` 的行為(F33)不再是前提,E4 作廢。
- p1-impl §2.2「`dv-sbx`(Go,arm64 靜態)」改為 shell(`unshare` + `capsh` + `mount`)實作同一份契約(§4.4);理由:runner 上有 util-linux / libcap2-bin,Go 執行器要自己重做 namespace / capability 的細節,沒有多出保護,負測試一樣。審查者可否決。
- p1-impl §2.2「`-wbox` payload 在 WSL `~/batman-dv-tools/wbox/<version>/`」:改為**真 build**(firmware `build-board.sh --wbox <name>`),不做 payload 改寫(§4.2;F6 雖允許改寫,但改寫的 squashfs 與出貨的不是同一條 build 路徑,負對照會混入 mksquashfs 差異)。
- p1-impl §7.4「推播由執行 run 的 Claude session 送」:daily-validation 本身只印 `NEEDS-PERSON <node> <step> <class> <report>` 行並停在安全點;推播由操作 session 做(不變),但**每個停下的理由都在報告裡有一行**,不靠 session 記憶。

## 2. 元件

### 2.1 產品接縫(PR-P1b;兩板共用檔 `feed/batman-prov`、`feed/batman-provision`;firmware `scripts/`)
| 元件 | 位置 | 說明 |
|---|---|---|
| `--killpoint` | `feed/batman-prov/src/cmd/batman-provhelper/killpoint_test_build.go`(`//go:build prov_test`)+ `killpoint_release.go`(`//go:build !prov_test`,no-op) | 契約 §4.1.1 |
| `prov_test` tag | `feed/batman-prov/Makefile`:`ifeq ($(BATMAN_PROV_TEST),1) GO_PKG_TAGS:=prov_test endif`;helper 在 `prov_test` build 的 `--boot` log 與 `batman-provhelper --version` 都印標記字串 `BATMAN_PROV_TEST_BUILD_7f3a` | 契約 §4.1.2 |
| build gate | firmware `scripts/check-image-manifest.sh` 新增:rootfs 的 `/usr/bin/batman-provhelper` 以 `go version -m` 讀 `-tags`,**不含** `prov_test`;`grep -c BATMAN_PROV_TEST_BUILD_7f3a` = 0;`BATMAN_WBOX` 有設時反向(必須含) | 契約 §4.1.3 |
| `-wbox` 變體 | firmware `scripts/build-board.sh --wbox <name>`:套用 `feeds/batman/tests/wbox/<name>.patch` 到 feeds/batman 工作樹 → `BATMAN_WBOX=<name>` 進 stamp → VER 加 `.wbox-<name>`(DIRTY 照舊為 1)→ build → payload;結束後 `git -C feeds/batman checkout -- .` 還原 | 契約 §4.2 |
| mutant 補丁 | Batman `tests/wbox/<name>.patch`(對 `feed/` 的 unified diff,每個檔頭有 `# wbox <name>: <mutant 的一句話>`)| §4.2 列表 |
| `BATMAN_WBOX` 戳 | `stamp-batman-build.sh`:`BATMAN_WBOX=<name>` 行;`batman-version` 顯示 | P9 以它拒絕 |

### 2.2 harness(本 PR)
| 元件 | 位置 | 說明 |
|---|---|---|
| 主機端 prov 程式庫 | `scripts/dv/prov-254.sh`(sourced by daily-validation)+ 每個 tier B 單位一支 `scripts/dv/prov-<unit>-254.sh`(可手動跑,同 claim-lock 做法) | §4.3 |
| 節點端 | `scripts/node/prov-base-254.sh`(既有 + `lock-hold`、`strip-p5-prov`、`state-set`)、`prov-p1-254.sh`(既有)、`prov-wbox-254.sh`(bind mount 白箱:`bind <src> <dst>`、`unbind-all`、`list`,只在 tmpfs 副本上)、`prov-sock-254.sh`(以 `provclient` 降權送唯讀請求 + `nobody` 負測試) | §4.3、§4.5 |
| `provclient` 擴充 | `tests/tools/provclient/`:`net-apply <hex objects>`、`leave`、`owner-add` / `owner-remove`、`diag`、`sock-as <uid>`(降權到指定 uid 後連線,給 `prov-sock` 負測試) | §4.6 |
| `provgen.py` | `tests/tools/provgen.py`:以 `gen.py` 的函式庫產 `net_config` / `member_list` / `net_secrets` / `invite` / 版本鏈(給 `net-apply`);**與 helper 的 Go 實作獨立**(同向量的第二份實作) | §4.6 |
| 沙箱 | `tests/prov-p1/sbx/dv-sbx.sh`(runner root)、`tests/prov-p1/sbx/cases/*.sh`、CI job `prov-sandbox`(`ubuntu-24.04-arm`) | §4.4 |
| `peer.py` | `tests/tools/peer/peer.py` + `transport_sock.py` + `transport_ble.py`(bleak);`verify.py` 改 `def main()` + 可 import 的 `noise_initiator` / `det_dumps` / `cddl_ok` 等 | §4.8 |
| dbus 測試工具 | `scripts/dv-dbus-tools.sh`:從 firmware build 樹複製 `dbus-send`(同 `dv-bt-tools.sh` 做法,SHA256SUMS,只 stage 進 `/tmp/run/batman-dv/bt/<run>/`) | §6.3 `prov-sec-dbus` |
| CI | `ci.yml`:`vectors-219` 加 `peer.py --selftest`;新 job `prov-sandbox`(arm64);`prov-p1` job 加接縫 stub(killpoint 檔案契約、gate 負對照) | §6.1 |
| lint | `check-provisioning-sync.sh` PAIRS 不變;新 lint `tests/prov-p1/lint-install.sh`(`files/` 每檔有 Makefile install 行)、`tests/wbox/lint-wbox.sh`(每個 patch 乾淨套用到 main 的 `feed/`) | §6.1 |
| known-failures | 移除 F21 的 6 行;新增:`<每個 tier B 單位>	^FAIL pre-P1b image: 	254`、`<每個 H3 單位>	^FAIL pre-P2 image: 	254` | §4.7 |

## 3. 擁有權

延續 `254-h1-harness.md` §3(BLE)與 `254-p1-impl.md` §3(prov);本 PR 新增 / 修改:

| 資源 | 唯一擁有者(可改) | 唯讀者 / 例外 |
|---|---|---|
| `/tmp/run/batman-prov-test/`(root 0700)與 `killpoint`(root 0600) | `prov-wbox-254.sh arm-killpoint <name>` 寫;**helper(`prov_test` build)讀完就刪** | 不在 helper socket 目錄;release build 不讀(檔案存在也無作用) |
| bind mount(tmpfs 副本蓋產品檔) | `prov-wbox-254.sh bind` / `unbind-all`;deadman 還原 = `unbind-all` + 重啟 helper | 重開即消失;P9 斷言沒有殘留 bind(`/proc/mounts` 中 `/tmp/run/batman-dv/wbox/` 來源 = 0) |
| B 槽 | 單位期間:產品 `sysupgrade -n`(由單位觸發,一律 hold);收尾:`brewrite` 寫回 V | P9:`.protected` 不含 `wbox` |
| `-wbox` payload(WSL `~/out/<ver>.wbox-<name>/ekh-bcm2711/`,SHA256SUMS) | `build-board.sh --wbox` 產;`prov-254.sh` 以 sha 驗後推到 04 `/opt/batdata/dv-prov/payload-<ver>.tar.gz`(0700 目錄) | 只進 B;restore 後 `finish` 刪 |
| `prov lease` `/tmp/run/batman-dv/lease-prov`(`<run_id> <boot_id> <expiry>`) | 取得者;到期由 prov deadman 在鎖內刪 | 與 H1 `bt/lease` 互斥:兩者任一存在且有效 → 另一方 acquire FAIL |
| prov deadman(節點 `setsid`,每台至多一個) | `prov-254.sh` 經 `prov-base-254.sh dm-arm <run> <secs>`;動作 = `unbind-all`、重啟 helper、啟動 joinwatch / openmanetd / tailscaled、留 dirty 標記、**不碰槽、不碰 p5** | `ble-state` 檢查;鏈 1 的 ch1-deadman 另一套(只在 B、會 p5-restore + rollback),兩者不同時 armed(P9) |
| 單位之間的安全點 S0 | `restore`;通過才 `finish` | P9;下一個單位 |
| `NEEDS-PERSON` 行與停止 | `prov-254.sh`:印行、寫 `$DIR/needs-person.txt`、`return 2`;daily-validation 遇 rc 2 **不再跑任何 prov tier B**(其餘非 prov 測項照跑) | 報告 |
| 沙箱內的一切(`/dev/mmcblk0p5` loop、`/opt/batdata`、`/proc/cmdline` 假檔) | `dv-sbx.sh` 建、案例用、結束刪 | runner 宿主:負測試證明碰不到 |
| `peer.py` session 狀態(`h`、nonce、PSK) | `peer.py` 程序;每個測項新程序 | 不落地;canary 掃描 |
| provd frame socket `/tmp/run/batman-prov-test/gatt.sock`(P2,`prov_test` build) | provd 建(0600,uid provd);`peer.py` 經 ssh 以 root 執行的 `provclient sock-as 471 -- proxy` 連 | release build 沒有這個 socket |
| 04 廣播 instance(P2 後) | **provd**(§8 契約);harness 的 `ble-periph-254.sh adv-on` 在 provd 存活時 **FAIL**(`adv_instances` ≠ 0 → die),`ble-rpa-254` 改為 `provd` 模式(§6.3) | 02 掃描 |

## 4. 契約

### 4.1 接縫(產品)

#### 4.1.1 `--killpoint`(只在 `prov_test` build)
- **點名封閉**:`txn-1`(寫 `prov-txn` + `.txn` 之後)、`txn-2`(setkey `--no-persist` 之後、`--prov-only` 之前)、`txn-3`(`--prov-only` rc 0 之後、overlay rename 之前)、`txn-4`(overlay rename 之後、`--save` 之前)、`txn-5`(`--save` 之後、`prov-state` 寫入之前)、`claim-after-persist`(= claim 的 txn-3)、`claim-before-shadow`(= claim 的 txn-4,上鎖之前)。對照上層 §4.4 步驟 1–5。
- **檔案**:`/tmp/run/batman-prov-test/killpoint`,一行 = 點名。helper **daemon 啟動時**讀:目錄 root 0700、非 symlink;檔 root 0600、非 symlink、link count 1;不符 → log `killpoint: refused (<why>)` 並忽略;讀完**立刻刪**;點名不在清單 → log 並忽略。
- **到點**:log `killpoint <name>: reboot -f`(syslog,`logread` 可見;這行在重開後由 p6 `boot-reasons`無法證明,所以 harness 以「重開前 helper log 有 arm 行 + 重開後 `killpoint` 檔已不存在 + boot_id 改變 + 狀態停在該點」四者判「注入成立」)→ `sync` → `reboot -f`。
- release build:檔案存在也不讀(`killpoint_release.go` 的 `armKillpoint()` 回 ""),helper log 沒有 `killpoint` 字樣(負對照)。
- 誰能寫:root。非 root 寫不進 0700 目錄;預先建目錄(非 root)→ 擁有權不符 → refused。

#### 4.1.2 `prov_test` build
- Makefile:`BATMAN_PROV_TEST=1` → `GO_PKG_TAGS:=prov_test`;只對 `batman-provhelper`(與 P2 的 `batman-provd`)生效。
- `prov_test` build 的額外行為**全部**列在這裡(封閉清單,之後 P2 只能追加並寫回本節):`--killpoint`(§4.1.1);`batman-provhelper --version` 第 2 行印 `BATMAN_PROV_TEST_BUILD_7f3a`;`--boot` 第一行 log 印同字串;**沒有** mutant 開關(mutant 一律用 `-wbox` 變體或 fakeSys,避免 `prov_test` 變成萬用後門)。P2 追加:frame socket、`prov_test` 下的兩個開關(§4.8.3)。
- 標記字串放在只在 tag build 編進去的檔案;release build 的二進位 `strings | grep -c` = 0。

#### 4.1.3 build gate
- `check-image-manifest.sh`(firmware,每次 build 第 6 步):
  - `BATMAN_WBOX` 未設:rootfs 的 helper `go version -m` 的 `build -tags=` 不含 `prov_test`;`grep -c BATMAN_PROV_TEST_BUILD_7f3a <helper>` = 0;`/etc/batman-build` 沒有 `BATMAN_WBOX=` 行;否則 build 停。
  - `BATMAN_WBOX=<name>`:反向:`BATMAN_WBOX=<name>` 行必須在;`<name>` 在 `tests/wbox/` 存在;`.wbox-<name>` 在 VER。
- release-scan(Batman CI `release-scan.yml`)對 release asset 也掃一次(同三條)。
- 負對照(CI `prov-p1` job):對一個以 `prov_test` build 的 helper(CI 自己 build)跑 gate → 必須 FAIL;對 release build → PASS。

### 4.2 `-wbox` 變體(firmware `build-board.sh --wbox <name>`)
- 輸入:`feeds/batman/tests/wbox/<name>.patch`(Batman repo,pin 的那個 commit 裡的檔)。
- 步驟:`git -C feeds/batman apply --check` → apply → `BATMAN_WBOX=<name>` export → 既有第 3–10 步(lock 檢查照常:mutant 只改 `files/`,不改 `.config`)→ 結束(成功或失敗)一律 `git -C feeds/batman checkout -- . && git -C feeds/batman clean -fd tests/ files/`。
- 版本:`VER=$REL-$CH.$N+$F7.fw$W7.dirty.wbox-<name>`(DIRTY 必為 1,因 feeds/batman 修改;`.dirty` 保留,`.wbox-<name>` 追加)。`BATMAN_BUILD_N` 不 bump(同一個 N 的變體)。
- 輸出:`~/out/<VER>/ekh-bcm2711/`(payload tar + SHA256SUMS)。
- **只進 B、一律 hold**(§4.3);P9 任一槽 `.protected` 或 `/etc/batman-build` 含 `wbox` → 整個 run FAIL;`prov-254.sh` 推 payload 前斷言 payload 的 `metadata` 版本含 `.wbox-` 且 `<name>` 等於單位要求的。
- 變體清單(每個對應的單位與負對照在 §6.2):

| name | mutant(一句話) | 用在 |
|---|---|---|
| `test` | 無 mutant,只有 `prov_test` tag(killpoint) | `prov-powerloss`、`prov-claim` 的 killpoint 段、`prov-netupdate` |
| `rc9-unclaimed` | helper `--boot` rc 9(legacy)→ 寫 `prov{unclaimed}` | `prov-legacy-upgrade` 負對照 |
| `96-noprov` | 96 不抄 overlay prov(走「restored from p5」) | `prov-ota` 負對照 |
| `helper-exit1` | helper 二進位 = `exit 1` 的 shell | `prov-lock-failsecure` 正向 |
| `helper-nogen` | helper `--boot` 不比 gen(overlay 壞也不重建) | `prov-overlay-corrupt` 負對照 |
| `96-norestore` | 96 + helper 都不從 p5 還原 | `prov-overlay-wipe` 負對照 |
| `radio1-off` | uci-defaults 一次性 `radio1.disabled=1` | autocommit (1) |
| `chan` | S99 一次性 init:等 F11 的 settled 行後 `uci set radio1.channel` 另一值 + `wifi reload` | autocommit (4)(7) |
| `helper-flap` | helper 每 5 s exit(procd respawn) | autocommit (9) |
| `misc-L38` / `misc-L42` / `misc-L43` / `misc-L51` | 各一個 mutant(定義隨單位,§6.2 `prov-misc`) | `prov-misc` |

- 負對照的負對照(lint):`tests/wbox/lint-wbox.sh` 對每個 patch `git apply --check` 於 main 的 `feed/`;另外 **每個 patch 必須至少改一個 `feed/` 下的檔**,否則 lint FAIL(空 mutant)。

### 4.3 主機端 `prov-254.sh`(Git Bash;簽章與 COSE 在 WSL)
沿用 p1-impl §4.2–§4.5 的契約;本節只寫 H2 沒實作、本 PR 要定的部分。

- **單位骨架**(每支 `prov-<unit>-254.sh`):`pr_begin <unit> <secs>`(P9 子集:S0 槽條件、無 dirty、無 bind、無 wbox、lease 取得、prov deadman armed、`snap`)→ 步驟 → `pr_end`(`restore` → `compare diffs=0` → `brewrite` B = V → `finish` → lease release → deadman cancel)。每一步失敗走 `pr_abort <why>`(= restore;restore 也失敗 → `NEEDS-PERSON`)。
- **OTA 到 B(hold)**:`pr_ota_b <payload-path> <sha> [allow-stale]`:寫 hold = 目標版本 → `setsid sysupgrade -n`(同 brewrite 的做法,E3 證實 25/25)→ `waitboot` → `find`(§F20 的 `find04`,一般化成 `pr_find <node> <want-state> [old-boot]`)→ **落點斷言**(DT tryboot=1、`batman_slot` = B、hold 生效、無 DISCARDED)。落空 → 讀 tryboot 旗標、disarm、清 hold、重試一次;再落空 → `NEEDS-PERSON`。
- **還原類別**:F = `p5-restore` + `overlay-restore` + `reboot committed`(既有);R = 同 F(F4,鏈 1 已證實 tar 覆蓋 + 刪多出的檔等於重建)。**不再有 `firstboot -y`**。跨槽(committed ≠ A 或版本 ≠ V 或含 wbox)= 在 B 上 p5-restore → rollback → A 開機 → F。
- **B 寫回 V**:`brewrite-254.sh N=1`(既有)。
- **順序**(§4.5.0):`FEATURE_MODE=--destructive` 時 prov tier B 在 2g 之後、ab-selftest / N3 / `reflash-survives-config-202` 之前;單位順序 = `prov-base` → 不 hold 的(autocommit (1)(4))→ hold 的 → killpoint 的 → 鏈 0 → `prov-legacy-upgrade`(最後:它把 B 寫成 wsl.9 再寫回)。每個單位是安全點;`NEEDS-PERSON` 後不再跑 prov。
- **時間預算**:每單位 ≤ 3000 s(02 joinwatch 3600 s);超過的單位(鏈 0 + autocommit (7))拆成兩個 lease。
- **secrets**:同 p1-impl §4.2;測試金鑰 `~/.batman-dv/prov-keys/<run_id>/`(WSL ext4 0600),`pr_end` 刪並斷言。
- **canary**(每單位結束):主機 log、節點 `logread`、p6 `/opt/batdata/log/*.log`、run dir 掃 owner 私鑰 / mesh key / root 密碼 / `owner_tag_key` / `adv_owner_key` / psk 的 hex 與 base64 前 16 碼 → 0。

### 4.4 `dv-sbx.sh`(CI `ubuntu-24.04-arm`,root)
契約 = p1-impl §4.10,逐條對應實作:
- namespace:`unshare --mount --pid --fork --net --uts --ipc --mount-proc --propagation private`。
- capability:`capsh --drop=cap_sys_boot,cap_sys_module,cap_sys_time,cap_sys_rawio -- -c <setup>`;`/dev` 建好後再 `capsh --drop=cap_mknod`。
- `/proc/sys`、`/proc/sysrq-trigger`:`mount --bind -o ro`;`/sys` 不掛(新 mount ns 裡 `umount /sys`)。
- `/dev`:tmpfs,`mknod null/zero/urandom`,`mmcblk0p5` = `losetup -f` 對沙箱目錄內 regular file(拒絕已掛載 / 支撐 `/overlay` 的裝置:`losetup -j` 與 `/proc/mounts` 檢查);`kmsg` = regular file。
- `/opt/batdata`、`/tmp`、`/tmp/run`:tmpfs;`/proc/cmdline`:bind 假檔;`/proc/device-tree`:不存在;`vcmailbox`、`reboot`、`wifi`、`ubus`:stub 到 `/usr/bin` 前面的 PATH,只記錄呼叫到 `/tmp/run/sbx-calls.log`。
- 底:釘住的 release payload `root.squashfs`(bcm2711;版本 + sha 釘在 `tests/prov-p1/sbx/base.env`)`unsquashfs` 到 `$SBX/root`,再**依 `feed/batman-provision/Makefile` 的 install 規則**把 PR 的 `files/` 蓋上(解析 `$(INSTALL_BIN)` / `$(INSTALL_DATA)` 行 → 目標路徑;一條 lint 保證每個 `files/` 檔都有 install 行,§2.2);helper 由 CI `setup-go`(SHA 釘)以 `-tags prov_test` 從 PR 原始碼 build(arm64 原生)。
- 進入:`chroot $SBX/root /bin/sh`(busybox ash,同節點)。
- `prov-unit-sbx` 負測試(每次 job 開頭):沙箱內 `reboot -f` → runner `boot_id` 不變;`mknod` runner 真實磁碟 major:minor → EPERM;`ip link add dummy0` → 宿主 `ip link` 看不到;`echo x > /proc/sys/kernel/hostname` → 失敗;`echo x > /dev/kmsg` → 宿主 `dmesg` 沒有;**任一條不成立 → job FAIL,後面的案例不跑**。
- 每個案例 `tests/prov-p1/sbx/cases/<name>.sh`:輸入 = 狀態(p5 loop 映像內容、overlay 檔、p6 檔、`/proc/cmdline`)+ 要跑的產品程式;輸出 = PASS / FAIL 行;每個案例帶 `--mutant <x>` 的負對照(p1-impl §5.1 表的「白箱負對照」欄),負對照必須 FAIL。
- `prov-artifact-match`(WSL,rc 驗證時手動):`unsquashfs` 受測 rc 的 `root.squashfs`,逐檔比 batman-provision 的檔案與 pin commit 的 `files/` + install 規則;helper 以同 toolchain `-trimpath -buildvcs=false -ldflags '-s -w -buildid='` 重建比 sha(⚠️ E5:OpenWrt build 能不能重現,本 PR 第一次做;不能 → 明列,helper 出貨產物只由節點 tier A / B 涵蓋)。

### 4.5 節點端新增
- `prov-base-254.sh` 新子命令:
  - `lock-hold <run> <secs>`:以 §F19 的 holder 方式持 `cfgsave.lock` N 秒(印 `HELD` 後背景執行),給 §6.2 的 `--save` 失敗注入。
  - `strip-p5-prov <run>`(p1-impl §4.5.6)。
  - `state-set <run> <file> <content|absent>`:改一個 p6 state 檔(只限 `STATEFILES` 清單),先印舊值。
  - `dm-arm <run> <secs>` / `dm-cancel <run>`:prov deadman(§3)。
- `prov-wbox-254.sh`:`bind <name> <dst>`(副本在 `/tmp/run/batman-dv/wbox/<run>/<name>`,root 0600;`mount --bind`;記到 `wbox.list`)、`unbind-all`、`list`、`arm-killpoint <name>`(§4.1.1 的檔案契約,之後 `/etc/init.d/batman-provhelper restart`,斷言 helper log 有 `killpoint <name>: armed`)。
- `prov-sock-254.sh`(tier A):以 staged `provclient sock-as 471 -- info` 送 `info.*` / `nonce` → 回應正確;`sock-as 65534`(nobody)→ 連線被關(`EOF` 或 `ECONNRESET`,**不是** 回應);`sock-as 65534 --gid 471` → 同;未知動詞 / 多餘欄位 → `E_SCHEMA`(21)。全部唯讀。

### 4.6 `provclient` 擴充與 `provgen.py`
- `provclient node net-apply <cfg.hex> <members.hex> <secrets.hex> [--first|--update <chain.hex>]`:讀三個 COSE 物件(hex,stdin 或檔),`--first` 加 owner-op `network/join`(簽章往返同 §4.2),`--update` 送 `network/update` 版本鏈(不帶 owner-op);印 `RESULT net.apply code=<n>`。
- `leave`、`owner-add <pub.hex> <enc.hex> <sig_enc.hex>`、`owner-remove <key_id.hex>`、`diag`(只驗 fd 是 O_RDONLY、schema、大小,內容丟棄)。
- `sock-as <uid> [--gid <gid>] -- <op>`:降權到指定 uid/gid(不是 471 時 helper 應關連線;輸出 `CONN-CLOSED` 或回應)。
- `provgen.py`(WSL venv,同 `requirements.txt`):`netcfg <net_id> <admins...>`、`members <...>`、`secrets <node ecdh_pub> <mesh_key> <mesh_id> <chan>`、`chain <prev> <next>`;**金鑰由 provclient `keygen` 產,provgen 只收公鑰與要簽的私鑰路徑**(WSL ext4 0600);輸出 hex。向量一致性:`provgen.py --selftest` 以固定金鑰重現 `vectors.json` 的 `net_config` / `net_secrets` 位元組。
- 獨立性:helper(Go `cose` 套件)解、`provgen.py`(Python `pycose`)產;兩者錯得一樣的機率由向量 + `verify.py` 擋。

### 4.7 preflight P9(`dv-preflight.sh` 新段)
- 任一節點 `/etc/batman-build` 或兩槽 `.protected` 含 `wbox` → FAIL。
- `dv-prov-dirty` 存在且 run_id 不同 → FAIL,印 `restore` 指令。
- `/proc/mounts` 有 `/tmp/run/batman-dv/wbox/` 來源的 bind → FAIL。
- `/tmp/run/batman-prov-test/` 存在 → FAIL(殘留的 killpoint 目錄)。
- helper state ∈ {legacy} 或 `PROV_EXPECT`;讀不到 → FAIL。
- `--destructive` 時:WSL `provclient sign` 可執行、金鑰目錄 0700;`provgen.py --selftest` PASS;`-wbox` payload 目錄存在且每個 §4.2 的 name 都有 SHA256SUMS 且版本前綴 = fleet 版本(缺任一 → prov tier B 整段 FAIL,不 SKIP);04 `/opt/batdata/ota.tar.gz` **不被使用**(F27)。
- 02 p3 `core_freq_min=500`(已有,F 事實 2026-10-23 兩台都有)。
- chain1 前置(#254 checklist):兩槽 `.protected` 版本都 = V;不是 → `chain1-254` 以一行 `FAIL precondition: slot B is <ver>, want <V> (OTA twice first)` 結束(不是 SKIP)。
- H3(P2 後):`peer.py --selftest`;bleak 匯入;`ble-periph adv-on` 在 provd 存活時拒絕(§3)。

### 4.8 `peer.py`(H3)
#### 4.8.1 角色與獨立性
- 手機角色(S1–S6 的協定面)與攻擊者角色(錯 PSK、重放 id、超大訊息、`type ≠ verb`、無 owner-op、假 `dev:` 憑證)。
- 實作:Python,Noise 用 `dissononce`(與 `verify.py` 同一套,**不是** Go `flynn/noise`),CBOR 用 `cbor2` + `det_dumps`,CDDL 用 `pycddl`,ES256 用 `python-ecdsa`;全部從 `verify.py` import(F15:改成 `def main()`,模組層只有函式與常數)。**CI 負對照**:`ci-check.sh` 新增「import 後 `main()` 的 checks 數 ≥ `MIN_CHECKS`」與「`peer.py --selftest` 對向量重跑 NX / NXpsk0 / owner-op / CheckMac 全部位元組相同」。
- 裁判:向量(§11)是第一裁判;`peer.py` ↔ provd(Go)互打是第二裁判;兩者都要過。

#### 4.8.2 傳輸契約(§4.1 frame 層)
- `transport_sock.py`:`SOCK_SEQPACKET` unix socket,**一包 = 一個 frame**(`flags(1) ‖ seq(2 BE) ‖ data`),`max_frame` 由 `CTRL` 讀(第一個包 = `CTRL` 讀取請求,協定外:`0xC0` 單位元組 → 回 CDDL `ctrl` 的 CBOR;`0xC1` → `status-public`);之後與 BLE 完全相同的重組與中止規則(序號不連續 / 超過 `max_msg` → **關 socket** = 斷 BLE)。這個 socket 只在 `prov_test` build 的 provd 存在:`/tmp/run/batman-prov-test/gatt.sock`,uid provd 0600;harness 以 `provclient sock-as 471 -- proxy` 在節點上代理 stdin/stdout ↔ socket(經 ssh),或在 CI 上 provd(amd64 build,fakeSys)直接本機。
- `transport_ble.py`:`bleak`(Windows 主機 MediaTek 藍牙,F13):scan 以服務 UUID(§4.9)過濾、connect、`CTRL` / `STATUS` 讀、`RX` write-without-response、`TX` notify;MTU 由 `bleak` 的 `mtu_size` − 3。
- 兩個傳輸對 `peer.py` 的介面相同(`send_msg(bytes)` / `recv_msg() -> bytes` / `abort()`);協定測項在 sock 上跑完整組,在 BLE 上跑子集(§6.3)。

#### 4.8.3 P2 要開的 `prov_test` 開關(封閉清單,寫回 §4.1.2)
- `BATMAN_PROVD_TEST_NO_OWNEROP=1`(env,只在 `prov_test` build 讀):provd 不把 owner-op 轉給 helper 驗 → 負對照「關掉檢查就過」必須被 **helper** 擋(helper 不信 provd),所以這個開關證明的是 helper 層;provd 層的負對照用 `type ≠ verb` 的向量。
- `BATMAN_PROVD_TEST_FAST_FAKE=1`:錯 PSK 時假第 2 則立刻斷線 → 時間分佈測試(§6.3 `prov-sec-psk-timing`)的負對照必須能分辨。
- release build:env 無作用,二進位無字串。

### 4.9 服務 UUID(Q1,建議定案)
- `batman-prov` 服務:`0x5A7D0001-...`(128-bit,以 `uuidgen` 一次產生,寫進 `219-protocol.md` §4.1 與 `peer.py` / provd 常數;本設計核准時產生,v2 填值)。特徵:`RX` = base+1、`TX` = base+2、`CTRL` = base+3、`STATUS` = base+4。
- 廣播:128-bit UUID 佔 18 B,B16 上位設計的廣播 payload(nonce + 旗標)另算;本 PR 不改 B16,只記 ⚠️ 給 P2。

### 4.10 BLE 空中(H3)
- 主要 central = Windows 主機 `bleak`(⚠️ D-H8:主機到 04 的距離與 RSSI 未量;核准前做一次唯讀實證:04 `ble-periph adv-on`(lease 內)→ 主機 `bleak` scan 看到該 name → `adv-off`)。
- 02 仍是攻擊者 central(配對 / 綁定 / 佔連線),沿用 `ble-central-254.sh`。
- `bleak` 不能做的(配對控制、精確時間)不在主機做。

## 5. 生命週期矩陣

| 路徑 | 今天(wsl.4 + 現有 harness) | 本 PR 之後 | 證明 |
|---|---|---|---|
| install / first run(harness 在新主機) | DV_* env + WSL venv | + `bleak` venv(Windows)、`provgen.py` venv(WSL)、`-wbox` payload 目錄、dbus-send 工具目錄;P9 逐項檢查,缺 = FAIL | `test-dv-preflight.sh` 新負對照(每個缺項一個) |
| start(每個 tier B 單位) | — | `pr_begin`:S0 槽條件、lease、deadman、snap | `prov-base-254` 單位 |
| clean stop(單位正常結束) | — | `pr_end`:restore → compare → brewrite → finish → release → cancel | 每個單位 |
| restart(harness 死,節點不重開) | BLE deadman(H1) | prov deadman:unbind、重啟 helper、起 joinwatch;dirty 留著;下次 P9 FAIL 印 restore 指令 | 白箱:殺主機腳本 → 30 s 內節點 `wbox.list` 空、helper 新 pid |
| restart(harness 死,節點已重開) | — | bind 與 killpoint 目錄隨 tmpfs 消失;dirty 標記接手;同 run_id 自動 restore | 白箱 |
| upgrade(fleet 升到含接縫的 rc) | — | 接縫是 release build 的 no-op;tier B 單位在 rc 上 PASS | rc 全套 |
| rollback(fleet 回 wsl.4,無接縫) | — | 每個需要接縫的單位印一行 `FAIL pre-P1b image: <ver> (no killpoint / no wbox build)`,KNOWN #254;其餘單位照跑 | wsl.4 上的負對照 run(PR 附) |
| downgrade(節點到 1.5.12 / wsl.9) | `prov-downgrade`(characterization) | 同左(hold,只進 B) | 單位 |
| crash / crash loop(helper) | procd respawn | `prov-misc` L11 + autocommit (9)(`helper-flap`) | 單位 |
| 斷電(真) | ❌ 不做(實驗室) | `prov-powerloss` 以 `reboot -f` 模擬(killpoint)⚠️ 不是真斷電;真斷電列殘項 | 單位 |
| 網路斷(主機 ↔ 04 eth) | 主機腳本逾時 | `NEEDS-PERSON`(連不到 10 分鐘),不送改狀態指令;deadman 到期自己還原 bind / helper | 白箱:拔線模擬 = `nft` 暫擋 |
| 依賴重啟(bluetoothd / dbus / openmanetd) | `prov-misc`(helper 側) | + H3 provd 側 L9–L11 | 單位 |
| CI runner(arm64 公開預覽) | 無 | job 用 `ubuntu-24.04-arm`;runner 排隊久時 job 逾時 60 min = FAIL(不是跳過) | PR CI |
| 平台:bcm2710 | 不支援(P-U14) | `prov-unit-bcm2710` smoke(沙箱,bcm2710 squashfs 底)照設計做;真機無 | CI |
| 平台:Git Bash ↔ WSL | E6 證實 pipe | 同;`provgen.py` 也經同一個 pipe 契約(`GEN <args>` → `OBJ <hex>`) | 20 次往返測試(既有 E6 的擴充) |
| H1 / H2 / H3 測項同時跑 | BLE lease | BLE lease 與 prov lease 互斥(§3) | 白箱 |
| P2 後:provd 擁有廣播 | — | `adv-on` 拒絕;`ble-rpa-254` provd 模式 | H3 單位 |

## 6. 測項

每個測項:輸入、判定、負對照、副作用與還原、類別(hold / 最終槽 / F|R)。沒寫負對照的不是測項。

### 6.1 CI(無硬體)
| 測項 | 判定 | 負對照 |
|---|---|---|
| `prov-p1-stubs`(既有,擴) | + killpoint 檔案契約(以 `prov_test` build 的 helper 在 CI 本機跑:目錄 0777 / symlink / link count 2 / 非 root 擁有 → `refused`;正確 → `armed` 且檔被刪);release build 對同檔 → log 無 `killpoint` | mutant:拿掉 link count 檢查 → FAIL |
| `prov-gate-stubs` | §4.1.3 gate 對 `prov_test` build FAIL、release PASS;`BATMAN_WBOX` 反向 | 內建 |
| `lint-install`、`lint-wbox` | §2.2 | 刪一行 install → FAIL;空 patch → FAIL |
| `prov-sandbox`(arm64) | §4.4 負測試 → 案例:`prov-unit-96`、`-cfgsave`、`-helper`、`-auth`、`-gate`、`-button`、`-bcm2710`(smoke)、`-build`(p1-impl §5.1 表,逐條) | 每案例的 `--mutant` |
| `vectors-219`(既有,擴) | + `verify.py` import 後 checks ≥ 195;`peer.py --selftest`;`provgen.py --selftest` | 既有竄改負對照 + 刪一個 check → FAIL |
| `peer-vs-provd`(H3,amd64) | provd `prov_test` build(fakeSys)在 runner 本機開 frame socket;`peer.py` 跑 §6.3 的協定子集 | `BATMAN_PROVD_TEST_*` 開關 + 向量負向 |

### 6.2 節點(甲部;04 = DNODE,除非註明)
tier A(每天,唯讀):`prov-boot-254`(p1-impl §5.2;白箱負對照只在 PR 證據階段:停 helper → stale;`privacy off` → `privacy=0`;`batman-sc` pid 不符 → `sc_file=0`)、`prov-sock-254`(§4.5)。

tier B(`--destructive`;hold / 最終槽 / 類別):
| 單位 | 程序與判定 | 負對照 | hold / 槽 / 類 |
|---|---|---|---|
| `prov-base-254` | snap → 改 p5(寫一個檔)/ overlay(一個檔)/ p6(一個 state)→ restore → S0;restore 的 dd 期間 `reboot -f`(主機 10 s 後送)→ 重跑 restore → S0;之後跑 3 次 `prov-boot` | 跳過 p5 寫回 / 跳過刪多出的檔 → compare 必 FAIL(以 `PROV_BASE_SKIP=p5|extra` 白箱開關,只在 harness 腳本) | — / A / F |
| `prov-legacy-upgrade-254`(L17) | 釘住 wsl.9(`DV_OLD_PAYLOAD` + sha)apply 進 B 不 hold → B commit(E1c 的找法)→ `strip-p5-prov` → rc(V)apply 進 A → A commit → 斷言 helper log `rc=9`、`prov{legacy}`;AP key / lock-status / authorized_keys / mesh-expected 前後相同 | `-wbox rc9-unclaimed` → `prov{unclaimed}` → FAIL | 不 hold / A / R |
| `prov-claim-254`(既有)+ killpoint 段 | 既有 + `claim-after-persist` 注入 → 重開 → `replay` 拿到相同 `owner_tag_key`(sha);錯 `owner_pub` → 3;空 `authorized_keys` 視圖(bind)→ 6 | 既有 | — / A / F |
| `prov-netjoin-254` | `provgen` 隨機網路(單台)→ `net-apply --first` → member;wireless == prov.net;overrides == prov;`rm=1`;`halow-setkey` 印 `app-managed` 警告 | bind:helper 副本接受首版無 owner-op(⚠️ 需要 mutant helper 二進位:用 `-wbox` 的 helper 檔 bind,不另建)→ 必須被接受才算負對照有效 | — / A / F |
| `prov-leave-ota-254`(L22) | member → `leave` → p6 標記刪、prov 換 → OTA V(hold)→ B 的 trial `claimed` | bind helper 不刪標記 → B trial 要求鄰居 | hold / A / F |
| `prov-ota-254`(L5) | member → OTA V(hold)→ B:member、gen 同、wireless 同、上鎖;證據 = `.batman-prov-restore` verdict + helper log「overlay prov from 96」 | `-wbox 96-noprov` → log「restored from p5」 | hold / A / F |
| `prov-lock-failsecure-254`(L5) | `claim-before-shadow` 注入(claimed、無 shadow-root)→ OTA `-wbox helper-exit1`(hold)→ 認證只剩 publickey、LOCKED | 同前置 → OTA wsl.9(hold)→ UNPROVISIONED | hold / A / F |
| `prov-powerloss-254`(L7) | `txn-2` / `txn-3` / `txn-4` **各一單位**:arm → `net-apply --update`(或 join)→ 重開 → wireless == prov、overrides == prov、key 登入可用;`.txn` 處理的 log 行 | killpoint 在 release build 不觸發(= 正常完成,不是負對照);負對照 = `txn-2` 後把 `.txn` 刪掉(bind 空檔)→ 開機不對帳 → wireless ≠ prov → FAIL | — / A / F |
| `prov-netupdate-254`(L25、L26) | 第 2 步故意失敗(bind 一個 `halow-setkey` 副本 `exit 1`)+ `--on-join` → overrides 不前進;`txn-3` 注入 + `--on-join` + `reboot -f` → member | bind 不讓路的 `--on-join`(config-save 副本去掉 txn 檢查)→ gen 前進 → FAIL | — / A / F |
| `prov-trial-busy-254`(L21) | OTA V(hold)→ 在 B trial `claim`(經 eth)→ `E_BUSY`(7) | bind helper 不看 is-trial(wbox helper 檔)→ 被接受 | hold / A / F |
| `prov-overlay-corrupt-254`(L33) | 弄壞 A 的 `prov.cbor`(寫垃圾)→ 重開 → 以 p5 重建、gen 相等 | `-wbox helper-nogen` → 不重建 → state unknown | — / A / F |
| `prov-overlay-wipe-254`(L60) | 清 overlay(`firstboot -y` 不用;以 overlay-restore 的「刪全部」路徑 = tar 空 + 刪多出)→ 重開 → state、`device_id` 不變 | `-wbox 96-norestore` → legacy / 新身分 | — / A / R |
| `prov-downgrade-254`(L12) | claimed → OTA wsl.9(hold)→ 還原、LOCKED、`ttylogin=1`、p5 prov 檔不刪(characterization,無鑑別力,明列) | — | hold / A / F |
| 鏈 0(L15) | p1-impl §5.4:直接 apply V 進 B + cmdline `batman_bypass=1` → 受控重開 → `none` 登入 → `unknown(bypass)`、不產身分、persist 拒、96 exit 1 | 同鏈沒有 bypass → 正常 | hold(=V) / A / F |
| `prov-autocommit-254` (1) | `-wbox radio1-off` 進 B 不 hold → `REVERT …mesh`;誤 commit → 跨槽重建 | — (它本身是負對照) | 不 hold / A |
| (3)(L31) | member(單台)→ OTA V hold → `HELD` | — | hold / A |
| (4) | `-wbox chan` 不 hold → 前置:120 s 內不在 mesh(否則「mutant 無效」FAIL);chanfix settled 行出現(F11)→ `REVERT` | — | 不 hold / A |
| (5) | OTA V hold,trial 內刪 `ota-armed.mesh` → `UNHEALTHY first_why=need-mesh…` | — | hold / A |
| (6) | `sysupgrade -T` 後直接 `batman-slot apply` → 同上 | — | hold / A |
| (7)(L40) | 02 = A 角色(V,hold)、04 = B 角色(`-wbox chan`,不 hold)→ 04 `REVERT`、02 `HELD`;preflight 斷言角色 | — | 02 hold / 04 不 hold |
| (8) | `ble-ok` 在、`btmgmt power off` → `HELD` + `WARN ble`(P-U5 只 WARN) | `ble-ok` 不在 → 只 WARN(同一次跑兩段) | hold / A |
| (9) | `-wbox helper-flap`(hold)→ `HELD` + `WARN health-stale`;不 commit | — | hold / A |
| (10)(L41) | 非 root / 容器 root 偽造 sysupgrade cmdline、相對路徑 → 沒有 `ota-armed.mesh`;`-T`、真 OTA、中止後 LuCI validate 三種 caller 各一次 → 檔案有無正確 | — | — / A |
| `prov-misc-254` | L38 / L42 / L43 / L51(各一 `-wbox misc-*`,定義:L38 = 96 在 `:89` 出口 + p6 claimed → 仍鎖;L42 = 直接 apply 沒有 `ota-armed.mesh` → 要求鄰居;L43 = `.stage/` 殘留被丟棄;L51 = helper socket 目錄預先放 symlink → 拒絕);L11 helper 重啟 ≤ 15 s health 恢復;L9 / L10 bluetoothd / dbus 重啟 → health 15 s;L27 dropbear 重啟後 key 登入;L3 clean shutdown → boot-reasons 乾淨 | 各一 mutant | — / A / F |
| `prov-verbs-254` | p1-impl §5.6 正向:`info.*`、`nonce`、`sign.*`、`psks.get`、`owner.add / remove`、`settings.get`、`ssh_keys.set`、`diag.bundle`、`qr`(legacy + dev-open)| `prov-unit-auth`(沙箱)| — / A / F |

### 6.3 節點(乙部,H3;P2 rc 後)
| 單位 | 程序與判定 | 負對照 | tier |
|---|---|---|---|
| `prov-firstboot-254`(L1,provd 側) | 鏈 1 第 5 步加:B trial 的 `STATUS` 經 BLE 可讀(`bleak`)、`updating=1`、`device_id` 末 4 碼在、無 AP | 1.5.12 新卡(釘住)→ 無廣播 | 併鏈 1 |
| `prov-boot-254`(provd 側) | health `adv_registered_once=1`;provd 以 provd uid 跑、ujail;廣播有、無 Local Name;`STATUS` 已認領不帶末碼 | 停 provd → ≤ 10 s 無廣播(health 不變) | A |
| `prov-respawn-254`(L8) | kill provd ×5 → 每次 respawn,退避遞增;認領結果不受影響(`info.state` 不變) | — | A |
| `prov-dep-restart-254`(L9–L11) | bluetoothd / dbus / helper 各重啟 → provd `NameOwnerChanged` 重註冊 / 重連 ≤ 15 s;無 hci0 → health `hci0_powered=0` | — | A |
| `prov-two-phones-254`(L24) | 兩個 `peer.py`(sock + BLE)同時 `claim` → 一個 0、一個 `E_STATE`;序列化 | — | B |
| `prov-provd-dos-254`(L39) | OTA V hold,trial 期間 `peer.py` 以超大訊息反覆 crash provd → `HELD`,不 revert;health 只看 bluetoothd / hci0 / `adv_registered_once` | — | B |
| `prov-ble-claim-254`(L18 / L34 / L47 經 BLE) | `peer.py` BLE:NX → `claim/begin` / `finish` → 密碼 → `psk_replay` session → `claim/replay` 相同 `owner_tag_key`;persist 後 `reboot -f`(killpoint)→ replay | 錯 `owner_pub` → 3;NX 對已認領 → 假第 2 則 | B |
| `prov-sec-claim-brute-254` | 同一連線 3 次錯 response → 斷線;新連線再 3 次 → 斷線;節點 `claimed_counter` 不變 | `prov_test` 無開關 → 用向量:4 次錯仍連著 = FAIL | A |
| `prov-sec-hog-254` / `-oversize-254` | 3 個 central(2 × sock + 1 BLE)→ 第 3 個被拒;未交握 10 s 斷;單則 > 8192 → 斷;分塊超 `max_msg` → 斷 | — | A |
| `prov-sec-psk-timing-254` | 50 × 錯 PSK vs 50 × 對 PSK 的第 2 則時間分佈(Mann-Whitney p > 0.05) | `BATMAN_PROVD_TEST_FAST_FAKE=1` → p < 0.01 | A |
| `prov-sec-dbus-254`(擴) | 以 provd uid(`provclient sock-as 471 -- exec dbus-send …`)呼叫 `AgentManager1.RegisterAgent`、`Properties.Set Pairable`、`Device1.Pair` + 抽測 3 個未列方法 → AccessDenied;`Device1.Disconnect` → 成功;bluetoothd → provd `ReadValue` / `Release` 回呼 → 成功(以 `peer.py` 讀 `CTRL` 證明) | 以 root 呼叫同方法 → 成功(鑑別力) | A |
| `prov-sec-bond-254`(翻轉) | 04 掛 agent(白箱:`bluetoothctl agent NoInputNoOutput` 常駐)→ 02 SC Just Works → **通過**(外洩)→ 收 agent → 擋下;IRK 作廢(rekey)、04 重開 | 本身是翻轉 | B |
| `prov-coex-254`(L28) | AP 吞吐(iperf 經 AP)有 / 無 BLE 流量(`peer.py` 連續 `status` 60 s)→ 記錄差異;FAIL 門檻:AP 掉 > 30% 或 BLE 斷線 | — | B |
| `ble-rpa-254`(provd 模式) | 廣播者 = provd(不 `adv-on`);時間軸由主機;provd 的重新註冊(F28)在 `rpa_timeout` + 30–120 s 內發生 → 新 RPA;不重新註冊段(停 provd 的重新註冊 = 無法:改為量 provd 的實際週期並斷言 ≥ 900 s 才換) | 既有 N1 / N2 / N5a | B |
| `prov-sock-254` → tier B | 停 provd 才跑(socket 單連線) | 同 §4.5 | B |
| `prov-gatt-254` | `peer.py` BLE:MTU 協商、分段(1 B / 剛好 / 超過)、序號亂 → 斷、`CTRL` / `STATUS` 不加密旗標(bleak 讀特徵屬性)、notify 回壓(連續 100 則) | 序號亂不斷 = FAIL | B |
| iPad GATT 回歸 | ⚠️ 手動(無自動 central):步驟寫在 `docs/validation/ble-ipad.md`,結果貼 PR | — | 手動 |

## 7. 安全

- **資產**:04 / 02 的控制權與 S0、擁有者測試金鑰、fleet mesh key、root 密碼、IRK;runner 宿主(沙箱逃逸)。
- **actor 與攻擊面 delta**:

| actor | 攻擊 | 擋法 | 負測試 |
|---|---|---|---|
| 本機非 root(節點) | 預建 `/tmp/run/batman-prov-test/`、寫 killpoint 讓 helper 重開 | 目錄 root 0700 + 檔 0600 + link count 1 + 非 symlink;release build 不讀 | CI stub(§6.1)+ 節點白箱:以 `nobody` 預建 → `refused` |
| 本機非 root | 碰 bind 副本 | 副本在 root 0700 的 `/tmp/run/batman-dv/wbox/` | tmp-trust 掃描(allowlist 加該路徑) |
| 本機非 root | 連 provd frame socket | uid provd 0600;socket 只在 `prov_test` build | `sock-as 65534` → 拒 |
| 攻陷的 provd(P2) | 經 frame socket 自己對自己送請求 | socket 等同 BLE 入口,helper 層不信 provd(既有) | `peer-vs-provd` 負向 |
| 遠端(BLE 路人) | 對 `prov_test` build 的節點用 env 開關 | env 只在節點本機;release build 無 | gate + strings |
| 供應鏈 | `-wbox` payload 混進出貨 | gate(§4.1.3)、release-scan、P9 拒 wbox、`.dirty` 在 VER | gate 負對照 |
| 我們自己 | 忘了還原 feeds/batman(wbox 之後的正常 build 帶 mutant) | `build-board.sh` trap 還原;stamp 的 DIRTY 會把它標成 `.dirty`;gate 的 `BATMAN_WBOX` 反向檢查 | 白箱:中途 Ctrl-C → 樹乾淨 |
| 我們自己 | 沙箱逃逸改到 runner | §4.4 負測試每 job 開頭 | 內建 |
| 我們自己 | 測試金鑰外洩 | WSL ext4 0600;每 run 換;canary | canary = 0 |
| 我們自己 | 無人值守時把 04 留在壞狀態 | `NEEDS-PERSON` 停在安全點;deadman 只還原 bind / helper / 服務,不碰槽與 p5(槽的還原要人) | 白箱 |
- **privilege**:節點端腳本以 root 跑(必要:p5、mount、slot);provclient 降權到 471 後才連 socket;`dbus-send` 以 provd uid 跑(`sock-as 471 -- exec`)。
- **secrets**:同 p1-impl §8;新增 IRK(`prov-sec-bond` 翻轉後作廢);`peer.py` 的 PSK 只在記憶體。
- **failure mode**:P9 任何缺項 = FAIL 整段(不 SKIP);killpoint 檔不符 = 忽略(fail-closed,不重開);沙箱負測試不過 = job FAIL。

## 8. 工作順序與 PR

1. 本設計兩位審查到 0 BLOCKER / 0 MAJOR;§10 回報上層。
2. **實證**(先列副作用;全部唯讀或可還原):
   - **E-H1**:Windows `bleak` venv 建立;04 `ble-periph adv-on`(lease 內,非連線廣播)→ 主機 scan 看到 → `adv-off`。副作用:04 廣播 ≤ 2 分鐘。D-H8。
   - **E-H2**:firmware `build-board.sh --wbox test`(只有 `prov_test` tag)在 WSL build;量時間;gate 反向檢查;之後 `--wbox` 不帶 → 正常 build 的 gate PASS 且樹乾淨。副作用:無(本機 build)。
   - **E-H3**:CI `ubuntu-24.04-arm` job:只跑 §4.4 的負測試 + unsquashfs 底 + busybox ash `echo` → 證明 runner 可用與排隊時間。
   - **E-H4**:E5(`prov-artifact-match`):OpenWrt build 的 helper 與獨立 build 比 sha。
   - **E-H5**:`prov-base-254 lock-hold` + helper `--save` 撞鎖 → log「busy, retrying once」(claim-lock §11.4 4b 的前提),在 04 上 1 次。副作用:認領 + 還原(= `prov-claim` 一個單位)。
3. PR-P1b(產品分支 `feat/254-p1b-seams`)實作 §4.1–§4.2 + firmware `--wbox` → rc `1.5.14-wsl.5`(release build,接縫 no-op)+ `-wbox-*` 變體 build。
4. harness 實作(本 branch):§2.2 全部;每個 tier B 單位先在 wsl.4(舊版)跑負對照(需要接縫的單位 → `FAIL pre-P1b image`),再 OTA 兩台到 wsl.5 → 單位逐個 PASS → 全套(含完整 prov tier B,約 15–20 h,無人值守)。
5. harness PR 先 merge(CI 紅燈 = KNOWN,P-U9)→ PR-P1b + firmware pin merge → 出貨 build 上重跑全套。
6. 乙部:與 P2 設計一起;本文 §4.8–§4.10、§6.3 是 P2 設計的測試章節輸入;H3 測項在 P2 rc 上 PASS 後再開第二個 harness PR(或同一 PR 的第二段,視 P2 時程)。

## 9. 殘項(回 #254)
- 真斷電(用 `reboot -f` 模擬);真機 bcm2710;iPad GATT 手動;`prov-rename`(U5);`firstboot -y` 行為(F33)不再需要,但 LuCI reset 走 `firstboot` 的 L60 真機只以 overlay 清空模擬;608B;`prov_test` 與 release 的行為差異只靠 gate + 節點 tier A/B 涵蓋(E5 若不可重現)。

## 10. 回報上層
1. p1-impl §4.5.3 同槽重建改為鏈 1 的程序(F4),E4 作廢。
2. p1-impl §2.2 `dv-sbx` 改 shell 實作;`-wbox` 改真 build。
3. stage1 §10 第 3 點:H3 = 本文;P2 的測試接縫(§4.8.3)與 UUID(§4.9)要寫進 P2 設計與 219 §4.1 / §12。
4. 219 §12 Q1 定案(自訂 128-bit)。

## 11. 待決
| # | 題 | 建議 |
|---|---|---|
| D-H1 | `dv-sbx` 用 shell 還是 Go | shell(§1.4) |
| D-H2 | `-wbox` 真 build 還是 payload 改寫 | 真 build(§4.2) |
| D-H3 | `peer.py` 的 Noise 用 `dissononce`(同 verify.py)還是 `noiseprotocol`(同 gen.py) | `dissononce`:與裁判同一套,gen.py 已是另一份 |
| D-H4 | 服務 UUID | 128-bit 自訂(§4.9) |
| D-H5 | H3 測項是同一個 PR 的第二段還是第二個 PR | 看 P2 時程;設計一份 |
| D-H6 | `prov-coex` 的 FAIL 門檻 30% | 無既有數據,第一次跑只記錄,第二次起判 |
| D-H7 | killpoint 以 `reboot -f` 模擬斷電 | 接受(實驗室) |
| D-H8 | 主機 `bleak` 到 04 的 RSSI | E-H1 實證後定 |
