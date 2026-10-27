## 0. 一句話

一個 harness PR(`harness/254-h23`)把 P1 的測試補到設計要求的覆蓋(約 30 個 tier B 單位 + CI 沙箱矩陣),並為 P2 準備協定對手 `peer.py` 與 provd / BLE 測項;產品只加「為了可測」的接縫(`--killpoint`、`--version`、`prov_test` build、`-wbox` 變體、provd 測試傳輸),由一個小的產品 PR(PR-P1b)與 PR-P2 承擔。

## 1. 決策、範圍、事實

### 1.1 使用者決策
| # | 決定 | 日期 |
|---|---|---|
| H3-U1 | H2 缺口照設計補完(選項 1) | 2026-10-28 |
| H3-U2 | 一份設計、兩段實作:甲 = H2 補完 + 接縫;乙 = H3(等 P2 rc) | 2026-10-28 |
| H3-U3 | 成本接受(v3 重算:**約 22–23 h / 輪**,04 OTS 累計斷約 7.5 h,§7.3);依 P-U10 只在動到 prov 的 PR 與發版時跑 | 2026-10-28 |
| H3-U4 | 608B / #255 擱置 | 2026-10-28 |
| (沿用)H-U2 / H-U3 / H-U4、P-U5 / P-U9 / P-U10 / P-U12 / P-U14、H-U6 | | |

本設計自行定、審查者可攻:Q1 UUID 128-bit + scan response(§4.9);`peer.py` 主傳輸 = provd `prov_test` frame socket(§4.8),BLE = Windows `bleak`(§4.10);`peer.py` Noise = `noiseprotocol`;斷電代理 = sysrq `b`;helper mutant 變體一律帶 `prov_test` tag(§4.2)。

### 1.2 範圍
**甲部(H2 補完;在 1.5.14-wsl.4 + 接縫 rc 上驗)**
1. 接縫規格(PR-P1b;§4.1、§4.2)。
2. tier A:`prov-boot-254`(接線 + 標記斷言)、`prov-sock-254`、`prov-sec-helper-uid-254`、`prov-sec-key-perms-254`、`prov-sec-dvpc-254`(provclient 放置負測試,p1-impl §4.3)。
3. tier B(04):p1-impl §5.3 全部 + §5.4 鏈 0 + §5.5 (1)(3)(5/6)(7)–(10) + 雙台 `prov-netjoin-fleet-254`;powerloss 五個 killpoint 各一單位。
4. 沙箱(CI arm64):`dv-sbx` + p1-impl §5.1;`prov-unit-gate` 獨立。
5. 主機端 `scripts/dv/prov-254.sh`。
6. P9 補 §4.7;全套順序(2f 之後、2g 之前)+ `pr_normalise`(lease 內);known-failures 第 4 欄到期 + `NEVER_KNOWN` 補 `NEEDS-PERSON|blocked: DNODE`;移除 7 行過渡條目;chain1 前置兩槽 = V;prov lease 擴到 chain1 / brewrite / pty-commit。
7. `provclient` 擴充 + `provgen.py`(§4.6)。
8. `prov-eeprom-hooks-254`(WSL)。
9. lint / 清單更新(§2.2)。

**乙部(H3;等 PR-P2 rc)**:`peer.py`、provd 測項(§6.3)、P2 要開的測試接縫(§4.8.3)。

**不在本 PR(逐條理由)**:P3 測項(H4);bcm2710 真機(P-U14);轉賣工具與 L16 節點層(P3 / 現場);iPad GATT 自動化(無可程式 central → 手動);`prov-rename`(U5);真斷電(sysrq 代理);release asset 掃描(release 由 firmware CI 產、Batman tag push 時 asset 不存在;供應鏈三層擋:firmware gate、P9、tier A);`docs/validation` 的 P-U10 文字(另 PR);autocommit (5) 的「trial 內刪 `ota-armed.mesh`」(做不到:autocommit 開機早期一次讀,之後不再讀;以 (6) 的兩臂取代,§6.2);autocommit (9) 在 P1 只能 characterization(§6.2 理由);`joinwatch.lastjoined` 不在 `rundir-paths.txt`(產品側,記 #254 殘項)。

### 1.3 事實(2026-10-28 唯讀實查,main 5914f03;fleet 02/04 = `1.5.14-wsl.4+7fd2124.fw6be516a`)
| # | 事實 | 證據 |
|---|---|---|
| F1 | P1 出貨沒有任何測試接縫(`killpoint` / `prov_test` / `wbox` 零命中) | grep(A、B 複驗 ✅) |
| F2 | H2 實際交付:`prov-base-254.sh`、`prov-p1-254.sh`(未接線)、`addr-defer-254.sh`、CI stub、`prov-claim-254.sh` 草稿 | #306;`daily-validation.sh` |
| F3 | daily-validation 現有 #254 測項 **14**(含 `harness-negctl-254` 自測):`ble-*` ×4、`prov-tools`、`addr-defer`、`prov-lock-rest`、`prov-p1-stubs`、`harness-negctl-254`、`setsid-race`、`prov-claim`、`adr-reconcile`、`chain1`、`pty-commit` | `daily-validation.sh:208,214,227-296` |
| F4 | `prov-base-254.sh` restore = `p5-restore` + `overlay-restore`(tar 覆蓋 upper + 刪多出的檔 + **每個 `STATEFILES` 寫回快照值,快照沒有就 `rm -f`**);鏈 1 的 R 類還原 = 這條 + `reboot committed` + brewrite,wsl.3 / wsl.4 PASS;無 `firstboot -y` | `prov-base-254.sh:29,190-220`;`chain1-254.sh:122-176` |
| F5 | E4 沒做;`overlay-allow.txt` 3 條;`jffs2reset` 機制 = 掛著刪 upper 再 sync | `tests/prov-p1/overlay-allow.txt`;fstools `overlay.c:139-142,322-342` |
| F6 | payload 只有 `SHA256SUMS` + `metadata`(`version=` 是時間戳);無簽章;**04 沒有 `unsquashfs` / `mksquashfs`** | `platform-ab.sh:12,156,329,374`;`batman-slot:591-600`;`feeds/batman/scripts/build-ab-payload.sh:69`;04 `which` 2026-10-28 |
| F7 | stamp:DIRTY `:38-44`、VER `:52-53`;stamp 跑 `check-board-patches.sh`(`:48`)與 `patch-witness.sh list`(`:49`);OpenWrt 重建雜湊 = 套件目錄檔案 md5 + mtime,不含 env;`GO_PKG_TAGS`;`build-board.sh` 第 2 步 `-i` reset feeds;第 7 步 `patch-witness.sh check` | `stamp-batman-build.sh`;`include/package.mk:114`、`depends.mk:14`;`golang-package.mk:106-111,260`;`build-board.sh:86-96,166` |
| F8 | helper CLI 無 `--version`(其他 → usage exit 2);非 root exit 2;daemon 啟動跑 `boot.Run`,`.txn` 有 Restore 時 **`go restoreWireless(…, 120 s)`**;`--boot` 模式立即 restore;`Sys` 20 法;`commitTxn`;`.txn` 以 tmp + rename + fsync 寫 | `main.go:373-407,388,439-443,479-491`;`node.go:62-83`;`txn.go:16-34`;`provstore/txn.go:21-40`;`provstore.go:326` |
| F9 | 錯誤碼:`EStaleVersion 5`、`EUnsupported 6`、`EBusy 7`、`EStorage 10`、`ERate 12`、`ESchema 20`、`EApply 21`、`EState 22`(helper 內部)、`ELockIncomplete 23`;協定 §5.2 無 `E_STATE`;**改狀態動詞在 trial 一律 `EBusy "trial slot (updating)"`**(`dispatch` 第一條) | `node.go:33-50,163-170` |
| F10 | `provclient` 動詞 7 個;keygen PEM `EC PRIVATE KEY` 0600;降權 471;`unixpacket` | `provclient/main.go:294-305,417-424,470,489-560` |
| F11 | helper socket 目錄 `PrepareDir`:root 0750 chown gid 471;**目錄裡 `helper.sock` 以外任何東西 → 拒絕啟動**;socket 0660;uid ≠ 471 → log `connection refused: peer uid <u> (want 471)` 並關 | `sock.go:37-89,107-141` |
| F12 | autocommit:REVERT 寫 `bad-slot`(`slot=<S> version=<v>`);**任何 COMMITTED 都 `rm -f bad-slot`**(`:361` 的同槽同版本檢查是「拒絕 commit」);字串:`TRIAL-REVERTED boot=… slot=… version=… waited=…s reason=<why>`、`HOLD-COMMIT`、`HOLD-COMMIT-DISCARDED`、`mesh join required: <n> (prov=<v> mesh_expect=<m> radio_required=<r>)`(`:425`)、member 臂:`ota-armed.mesh` 三欄且 boot_id = boot-reasons 倒數第二行且 slot 相符且第 3 欄 `radio` → `NEED_MESH=0` + log(`:420`,實作時 grep 確切字串);否則 `NEED_MESH=1`,檔缺才印 `member: no usable ota-armed.mesh — neighbours required (fail-closed)`(`:421`);`why` 字串:`member: HaLow mesh interface not up on the configured mesh id`(`:494`)、`mesh not joined/reachable (<n>/<JOIN_NEED> samples: plink=… batman(wlh0)=…)`(`:502`)、`mesh lost (last joined …s ago)`(`:503`);`otalog AC UNHEALTHY first_why=<why>`(`:505`);`WARN ble: ble-ok present but BLE health is not good (<health line \| no health file>) — not blocking (P-U5)`(`:499`,**只在 `ble-ok` 存在且 health 行不同時含 `bluetoothd=1`、`hci0_powered=1`、`adv_registered_once=1` 時**);`trial <S> is healthy and HELD — waiting for release`(`:513`);`COMMITTED`(`:537`);`release --wait`(`:151-165`);`AUTOCOMMIT_DRYRUN` / `_TIMEOUT` | `batman-autocommit:26-28,151-165,192-195,238-244,277-288,361,412-426,494-505,513,537` |
| F13 | 96 字串:`prov: state=<st> copied=<none\|record\|full\|copy-failed\|bad>`(`:168`);`/etc/.batman-prov-restore` = `<boot_id> <verdict> prov=<PCOPY> state=<PST> lock=<LOCKWORD>`(`:113`);`root password restored from p5`(`:193`);96 只有一個 `exit`(`:115` 的 `exit "$2"`),出口以**呼叫它的字串**(第 1 參數)區分,不以行號;helper boot log:`boot rc=<n> verdict=<v> action=<a>`(`boot.go:59`,`action=txn <verb> NOT committed (gen n): wireless to be restored`,`boot.go:43`)、`overlay record unusable: …`(`:72`)、`p5 lost a committed prov write (…)`(`:187`);restore 完成:`txn <verb> not committed: restored the previous wireless values, setkey rc=<n> (<out>)`(`main.go:491`) | 原始碼 |
| F14 | health:stale = ts > 60 s;**`Run` 一開始就 `Tick(15)`**(每次 helper 啟動立刻寫一行)→ helper 每 5 s 重啟時 health 永遠新鮮;P1 固定 `adv_registered_once=0`(`:138`);`ble-ok` 條件 `poweredFor ≥ 600 && Committed && ConfigOK` | `health.go:8-9,138,151,160-166` |
| F15 | 99-batman-chanfix:第一次檢查就相符(`a=0`)→ **靜默 exit 0,沒有行**;只有 reassert ≥ 1 次才印 `radio1 channel is <CH> (settled after <a> reassert)`;reassert 行 `reassert radio1 channel <cur> -> <CH> from p5 (try <a>) + wifi reload` | `99-batman-chanfix:45-55` |
| F16 | 節點沒有 python3 / busctl / unshare / unsquashfs;**有 `libdbus-1.so.3`(1.14.10,`/usr/lib/libdbus-1.so.3.32.4`)**;firmware 樹 `tools/dbus-send` 是 **libtool bash wrapper(10004 B)**,真二進位是 `tools/.libs/dbus-send`(ELF aarch64,77424 B) | 04 `ls /usr/lib/libdbus*`;`file …/.libs/dbus-send` |
| F17 | Windows venv `C:/Users/yello/batman-dv-tools/pyble`:`bleak 0.22.3`、`noiseprotocol 0.3.1`、`dissononce`、`pycose`、`pycddl`、`cbor2`、`ecdsa`、`cryptography` 全部已裝;MediaTek adapter OK、`bthserv` running,**radio Off**(WinRT state 2)→ 需使用者打開 | pip、WinRT 2026-10-28 |
| F18 | GitHub `ubuntu-24.04-arm` 公開 repo 免費(2025-01 公開預覽);Batman PUBLIC | changelog;`gh repo view`(審查者無法上網,E-H3 實證) |
| F19 | `verify.py` 純腳本,模組層讀向量(`:176-186`);`gen.py` 用 `noiseprotocol` + `cryptography`,以 `set_keypair_from_private_bytes(EPHEMERAL/STATIC)` 注入金鑰(`:225-227`);私鑰 scalar 規則 `d = (int(SHA-256('batman-test-vector/'+name)) mod (n-1)) + 1`(`:38,184`);CI `MIN_CHECKS=195`;`requirements.txt` 釘 `noiseprotocol==0.3.1` | 原始碼 |
| F20 | repo 無 provd / Noise / GATT / UUID;`feed/batman-prov/src/` 有 `proto`、`cbor`、`cose`、`shacrypt`;go.mod 只 `x/crypto`(+ `x/sys` indirect);`sock_test.go:67 TestWrongPeerClosed` 已覆蓋 PEERCRED 負對照 | 原始碼 |
| F21 | 04 BLE current settings `powered le secure-conn privacy`;`kernel.sysrq = 502`(= 0x1f6) | 04 2026-10-28 |
| F22 | `ble-periph-254.sh cmd_adv_on` 第一個動作 `mg rm-adv 1`;`ble-lib-254.sh` 的 `dm_arm` 以 `$ST/dm` / `dm.new` 保證每台至多一個 deadman,同一把 `$BT/lock` | `ble-periph-254.sh:42-52`;`ble-lib-254.sh:78-134` |
| F23 | `prov-lib-254.sh`:`pl_prep` 只 `mkdir -m 0711` + sha,**沒有**放置負測試;`brewrite-254.sh`:`NODE` 預設 04、`:21` 前置 `badslot=[]`、`:37` 等 docker running ≥ 6 | 原始碼 |
| F24 | 鏈 1:`find04`、deadman(B 的 rc.local + `sleep 1500` timer + p6 腳本)、主機鎖 `$TEMP/batman-dv-04.lock`、`restore_all` 刪本 run 的 bad-slot、已 > 3000 s、joinwatch 還原事故註解 | `chain1-254.sh:27,57-92,122-176,135-137,145,205-221,259,362` |
| F25 | 2e(BLE tier B)→ **2f(#305 tier B,`bt-uart-boot-305` 對 DNODE loaded reboots,不動槽)**→ 2g(`setsid-race → prov-claim → adr-reconcile → chain1 → pty-commit`,pty-commit 移槽);`fault-injection` 目標 `$OTS_NODE`、`reflash-202` 目標 `$MESH_NODE`;`suite()` 只收 name / why / cmd / kind;DNODE 變數 `$DNODE0`(`:127`)與 `$DNODE`(`:386`);`NEVER_KNOWN='restore\|cleanup\|CONNECTION-LOST\|…'`(`:2740`),`classify` 只抓 `^FAIL `,known-failures `read -r ks pat iss`(`:2749`) | `daily-validation.sh:77-99,127,254-296,335,386,2175,2740-2749` |
| F26 | known-failures #254 過渡條目 7 行;3 欄無到期 | `validation-known-failures.txt:10,19-24` |
| F27 | claim-lock §11.4 的 4 / 4-inj / 4b / 4b' / 4c / 4d / 5 只有 CI stub | memory |
| F28 | 04 S0 = 現況 | 10-27 全套 |
| F29 | kernel `CONFIG_MAGIC_SYSRQ=y`、`DEFAULT_ENABLE=0x1f6`;**寫 `/proc/sysrq-trigger` 在 mask 不含 0x80 時寫入成功、動作被忽略** | `.config:6904-6905`;kernel 語意 |
| F30 | `tmp-trust-allowlist.txt:99` 無邊界;`check-tmp-trust.sh:29` 只掃 `feed/**`、`deploy/**`、`scripts/node/**`、`scripts/*.sh`(**`scripts/dv/*.sh` 不掃**) | 原始碼 |
| F31 | `batman-slot apply` 刪目標槽 `.protected`;95 寫完整版本;rollback gate 只在 `cmd_rollback`、只擋 claimed/member | `batman-slot:424-436,771-791`;`95:717` |
| F32 | wsl.9 有 HOLD-COMMIT;wsl.9 的 96:key 且密碼都在才 LOCKED | `git show f2f2bf6`(A 查) |
| F33 | joinwatch `t_reboot 3600` 每個未入網 episode;**`$RUNDIR/joinwatch.lastjoined` 由 joinwatch 寫(`:135`)、無任何刪除者、tmpfs**;sysupgrade stage 1 `_ab_arm_mesh`:`lastjoined` 存在 → `m=joined`,否則當下 `meshjoin_joined` → `joined`,否則 `radio` | `joinwatch:135`;`platform-ab.sh:104-115`;`grep -rn lastjoined feed/` |
| F34 | golang 旗標:兩個 `-ldflags`(`all=-linkmode external -extldflags …` 與 `-s -w -linkmode external -extldflags …`)+ `-buildvcs=false -trimpath` + `-tags` | `golang-package.mk:236-262` |
| F35 | deploy/ots 無 `/dev/log`、`/tmp/run`、`/opt/batdata/state` bind | grep |
| F36 | gate 位置:`build-board.sh` 第 7 步 `$WR/r`;`check-go-toolchain.sh` REQUIRED 不含 helper | `build-board.sh:146-172` |
| F37 | S13 `batman-prov-lock`:p5 `ok claimed|member` 且 identity 同 overlay 且 `prov_root_hash_ok` 才收斂 root;否則只鎖門、root 欄不變 | `batman-prov-lock:7-11,50-56` |
| F38 | `net.apply` 首版要 owner-op(`ownerOpVerb` → 首版以 owner-op 為信任錨);legacy 02 無 owners → 要先 `claim.verify` | `node.go:218-224,996-1000` |
| F39 | `applyNet` 在 `--save` 之後只剩回應(`:1120-1124`);`prov-state` 只在 `boot.Run` 與 claim 的 `SetLastKnown` 寫 | `node.go:1116-1126`;`boot.go:60` |
| F40 | `claim.replay` 的 10 / h 計**失敗**次數(`replayF`) | `node.go:94,542-549` |

### 1.4 與上層設計不同處(→ §10)
- p1-impl §4.5.3 同槽重建 = 鏈 1 程序;E4 作廢;`prov-base` 補 whiteout 負對照;opaque 未查(§9)。
- p1-impl §2.2 `dv-sbx` shell;`-wbox` 真 build + 見證;known-failures 到期欄落地。
- p1-impl §7.4 推播:daily-validation 印 `NEEDS-PERSON`;推播由操作 session 做。
- p1-impl §4.5.0 順序:prov tier B 在 2f 之後、2g 之前 + `pr_normalise`。
- p1-impl §5.5 (5):以 (6) 兩臂取代(§1.2);(9) P1 期 characterization。
- stage1 §6.4 (3) 的「radio-only」前提只在「本次開機從未 JOINED」成立(F33)→ member → OTA hold 的單位在 OTA 前多一次重開。

## 2. 元件

### 2.1 產品接縫(PR-P1b)
| 元件 | 位置 | 說明 |
|---|---|---|
| `--killpoint` | `cmd/batman-provhelper/killpoint_test.go`(`//go:build prov_test`)、`killpoint_release.go`(`!prov_test`,`armKillpoint()` 回 "") | §4.1.1 |
| `--version` | `main.go`:第 1 行 `batman-provhelper <BATMAN_VERSION>`;`prov_test` build 第 2 行 `BATMAN_PROV_TEST_BUILD_7f3a`;exit 0 | pre-P1b 偵測 |
| `prov_test` tag | `feed/batman-prov/Makefile`:`ifeq ($(BATMAN_PROV_TEST),1) GO_PKG_TAGS:=prov_test endif` | §4.1.2 |
| build gate | firmware `scripts/check-prov-test-gate.sh <rootfs> [<wbox-name>]`,`build-board.sh` 第 7 步(`$WR/r`) | §4.1.3 |
| `-wbox` 變體 | `build-board.sh --wbox <name>`(§4.2) | |
| mutant 補丁 + 見證 | Batman `tests/wbox/<name>.patch`:檔頭 `# wbox <name>: <一句話>` + `# wbox-witness: WBOX-<name>-<8 hex>`;**`.go` hunk 的見證必須在被引用的字串字面值內(例如該 mutant 的 log 行);shell / init hunk 可用註解** | §4.2 |
| provd 測試傳輸(P2) | frame socket、`SOCK_ONLY`、三開關 | §4.8.3 |

### 2.2 harness(本 PR)
| 元件 | 說明 |
|---|---|
| `scripts/dv/prov-254.sh` | `pr_begin` / `pr_end` / `pr_abort`、`pr_normalise`、`pr_ota_b`、`pr_find`、`pr_restore`、`pr_brewrite <node>`、`pr_lease_*`、`pr_needs_person`、canary;每單位一支 `scripts/dv/prov-<unit>-254.sh` |
| `scripts/node/prov-base-254.sh` | 既有 + `lock-hold`、`strip-p5-prov`、`state-set`、`dm-arm` / `dm-cancel`(**重用 `ble-lib-254.sh` 的 `dm_arm` / `$ST/dm`,只有 `dm-fire` 腳本不同**)、`restoring set|clear` |
| `scripts/node/prov-wbox-254.sh` | `bind` / `unbind-all` / `list` / `arm-killpoint` / `push-helper` / `upper-helper` / `set-provd-env`(§4.5) |
| `scripts/node/prov-sock-254.sh`、`prov-sec-254.sh` | tier A(§4.5) |
| `scripts/node/prov-p1-254.sh` | 既有 + 標記斷言(§6.2) |
| `scripts/node/ble-periph-254.sh` | `cmd_adv_on`:先 `adv_instances`=0 且 `/etc/init.d/batman-provd running` 為假,再 `rm-adv` |
| `tests/tools/provclient/` | + `net-apply`、`leave`、`owner-add` / `owner-remove`、`diag`、`sock-as`、`exec`、`proxy`(§4.6) |
| `tests/tools/provgen.py` | §4.6 |
| `tests/prov-p1/sbx/`、`tests/prov-p1/gate/` | §4.4 |
| `tests/tools/peer/` | `peer.py`、`transport_sock.py`、`transport_ble.py`;`verify.py` 改 `def main()` + `load_vectors()` |
| `scripts/dv-dbus-tools.sh` | 複製 **`tools/.libs/dbus-send`**(ELF magic 斷言)到 `~/batman-dv-tools/dbus-1.14.10/` + SHA256SUMS |
| `scripts/dv-prov-tools.sh` | 從 `-wbox` payload 抽 helper(主機端 `unsquashfs -cat`,F6:04 沒有 unsquashfs)到 `~/batman-dv-tools/prov-test/<ver>/<name>/batman-provhelper` + SHA256SUMS |
| `tests/prov-p1/eeprom-hooks.sh` | §6.2 |
| CI | `vectors-219` + `peer.py --selftest` + `provgen.py --selftest`;`prov-sandbox`(arm64,E-H3 前 `continue-on-error`);`prov-unit-gate`;`prov-p1` + killpoint Go 單元 + `prov-gate-stubs`;`known-failures-format` |
| lint | `lint-install`;`lint-wbox`(§4.2);`ab-shared-change.yml` 加 P1b 共用檔;`tmp-trust-allowlist.txt`:第 99 行收緊 `/tmp/run/batman-prov([^-]|$)`,新增 `feed/batman-prov/src/*` 的 killpoint 目錄與 provd 測試 socket 目錄條目、`scripts/node/prov-wbox-254.sh` 的 `/tmp/run/batman-dv/wbox/` 與 `/tmp/run/batman-prov-test/` 條目(`scripts/dv/*.sh` 不在掃描範圍,F30,p1-impl 的 `batman-dvpc.*` 條目不需要,明寫);`rundir-paths.txt` **不改**(它只列 `$RUNDIR` 底下的 basename,兩個新目錄是 `/tmp/run/` 的兄弟) |
| known-failures | 第 4 欄 `expires=YYYY-MM-DD`;daily-validation:缺欄 / 格式壞 → run FAIL,過期 → NEW;`NEVER_KNOWN` 加 `NEEDS-PERSON\|blocked: DNODE`;`test-known-failures.sh` 四案例(舊 3 欄、`expires=` 壞、過期、NEEDS-PERSON 行);移除 F26 的 7 行;新增 `pre-P1b` / `pre-P2` 條目(到期 = 產品 PR 預計 merge + 14 天) |

## 3. 擁有權

延續 h1 §3(BLE)與 p1-impl §3(prov)。每列一個寫者:

| 資源 | 唯一擁有者 | 唯讀者 / 例外 |
|---|---|---|
| `/tmp/run/batman-prov-test/`(root 0700)、`killpoint`、`provd.env`(root 0600) | `prov-wbox-254.sh` 寫;helper(`prov_test`)讀 `killpoint` 完就刪;provd init(`prov_test`)讀 `provd.env`;整個目錄由 `pr_end` / `pr_abort` / prov deadman / P9 restore 指令 `rm -rf` | release 不讀 |
| helper 記憶體內 killpoint arm | helper;解除 = restart helper(`unbind-all` 看 `wbox.list` 的 `armed <name>`) | P9:helper 本次 pid 的 log 無 `killpoint .*: armed` |
| `/tmp/run/batman-provd-test/`(**provd:provd 0700**)、`gatt.sock`(provd 0600) | provd init(root)`mkdir` + `chown 471:471` + `chmod 0700`;provd 自己 `O_NOFOLLOW` 驗 owner=471、非 symlink 才 bind;在 P2 ujail mount 清單 | harness `provclient sock-as 471 -- proxy`;release 沒有;§7 擋法 = 目錄 0700 provd 擁有 |
| bind mount(`/tmp/run/batman-dv/wbox/<run>/`,root 0700) | `prov-wbox-254.sh bind` / `unbind-all`;deadman 還原 | 重開消失;P9 斷言無殘留 |
| A 槽 upper 的 `/usr/bin/batman-provhelper` 副本(`upper-helper`,§4.5) | `prov-wbox-254.sh upper-helper` 放;`overlay-restore` 的「刪多出」清 | P9 標記 grep 擋殘留 |
| B 槽 | 單位期間:產品 `sysupgrade -n`(hold 或預期 REVERT,§6.2 標明);收尾:`pr_brewrite`(**只在單位寫過 B 時**) | P9 |
| `bad-slot`(p6) | autocommit 寫;刪:產品任何 COMMITTED(F12),或 harness 在預期 REVERT 單位且內容 = `slot=B version=<wbox ver>` 時(**在 `pr_restore` 之前**,§4.3) | brewrite 前置;P9(存在 → FAIL,印內容與清法) |
| `autocommit-hold-commit`(p6) | 四個 harness 寫者(`pr_ota_b`、brewrite、chain1、pty-commit)都在 prov lease 內寫;autocommit 消費 | P3 |
| B 槽 overlay `/etc/rc.local`(ch1 deadman 行) | 鏈 1 寫 / brewrite 清 | P9 |
| `-wbox` payload(`~/out/<VER>/ekh-bcm2711/`) | firmware build 寫;`prov-254.sh` 驗、推 | 只進 B |
| firmware `feeds/batman` 工作樹 | `build-board.sh --wbox` 套 / 還原(`checkout -- . && clean -fdx`) | gate 擋殘留 |
| prov lease `/tmp/run/batman-dv/lease-prov` | 取得者;取得 / 釋放在 `$BT/lock` 同一把 flock 內;到期由 prov deadman 刪;chain1 / brewrite / pty-commit / **`pr_normalise`** 也取 | 與 BLE lease 互斥;主機端互斥只有它 |
| prov deadman | `dm_arm`(與 BLE 共用 `$ST/dm`,每台至多一個);動作:`unbind-all`(含 armed → restart helper)、`rm -rf /tmp/run/batman-prov-test`、**有 `restoring` 標記時到此為止**;否則啟動 joinwatch / openmanetd / tailscaled;留 dirty;不碰槽 / p5 | 與 ch1 deadman 不同時 armed(P9) |
| `restoring` 標記 | `pr_restore` 建、`finish` 刪 | deadman 讀 |
| S0 | `pr_restore`;通過才 `finish` | P9 |
| `NEEDS-PERSON` | `pr_needs_person` 寫 `$DIR/needs-person.txt`、`DNODE_BLOCKED=1`;`suite()`:之後 `kind=D` 且 **`$cmd` 展開後含 `$DNODE0` 的 IP** 的 suite 印 `FAIL blocked: DNODE needs a person (<step>)` 不執行(涵蓋 `$OTS_NODE` / `$MESH_NODE` 與 DNODE 同 IP 的情況;ab-selftest on 02 照跑,寫明 02 可能被隔離) | 報告 |
| 測試金鑰 `~/.batman-dv/prov-keys/<run_id>/` | `pr_begin` 產;`pr_end` 刪;**`pr_abort` / `pr_needs_person` 保留**(02 若留在 claimed 狀態,它是唯一能解鎖的金鑰;路徑寫進通知) | — |
| 沙箱內一切 | `dv-sbx.sh` | 宿主:負測試 |
| 04 廣播(P2 後) | provd;harness `adv-on` 只在 provd 停止時 | 02 |

## 4. 契約

### 4.1 接縫(產品)

#### 4.1.1 `--killpoint`(只在 `prov_test` build)
- 點名封閉:`txn-1`(`prov-txn` + `.txn` 寫完、setkey 前)、`txn-2`(setkey 後、`--prov-only` 前)、`txn-3`(`--prov-only` rc 0 後、overlay rename 前)、`txn-4`(rename 後、`--save` 前)、`txn-5`(**`--save` 後、回應前**,F39)、`claim-after-persist`、`claim-before-shadow`。
- 檔案 `/tmp/run/batman-prov-test/killpoint`:目錄 root 0700 非 symlink;檔 root 0600 非 symlink link 1;不符 → log `killpoint: refused (<why>)`;讀完刪;成功 → `killpoint <name>: armed`。
- 到點:log `killpoint <name>: sysrq reboot` → `echo b > /proc/sysrq-trigger` → **`sleep 2` 仍活著**(F29:mask 不含 0x80 時寫入成功但被忽略)→ log `killpoint <name>: fallback reboot -f` → `sync` → `reboot -f`。harness 只在 `sysrq reboot` 行 + 2 s 內 boot_id 改變時判 L7 PASS;`fallback` = ⚠️。
- 注入成立四證據:`armed` 行、檔已刪、boot_id 改變、狀態停在該點。
- release build:`armKillpoint()` 回 "";log 無 `killpoint`。
- 測試(CI):Go 單元(`-tags prov_test`,temp dir):0777 / symlink / link 2 / 非 root → refused;正確 → armed + 刪;release no-op;mutant 拿掉 link count → FAIL。

#### 4.1.2 `prov_test` build(封閉清單)
- `BATMAN_PROV_TEST=1` → `GO_PKG_TAGS:=prov_test`(helper;P2 加 provd)。
- 額外行為全部:(1) `--killpoint`;(2) `--version` 第 2 行 + `--boot` 第一行 log 標記;(3)(P2)provd frame socket;(4)(P2)provd 讀 `provd.env`:`SOCK_ONLY`、`FAST_FAKE_DELAY_MS`、`NO_BRUTE_LIMIT`。**沒有** mutant 開關、**沒有** fakeSys 模式(CI `peer-vs-provd` 用 PATH stub 跑真 `realSys`,§4.8.3)。
- 標記字串只在 tag build 的檔案;release 二進位 `grep -c` = 0。

#### 4.1.3 build gate(`check-prov-test-gate.sh <rootfs> [<wbox-name>]`,第 7 步)
- 無 name:helper `go version -m` 的 `-tags` 不含 `prov_test`;`grep -c BATMAN_PROV_TEST_BUILD_7f3a` = 0;`/etc/batman-build` 無 `BATMAN_WBOX=`;rootfs `grep -rl 'WBOX-'` = 0。
- 有 name:`BATMAN_WBOX=<name>` 行在;VER 含 `.dirty.wbox-<name>`;見證 `grep -rl WBOX-<name>-` ≥ 1(`.go` 見證在二進位字串內,`strings` 可見);`test` 的見證 = helper 標記;`go version -m` 無輸出(shell 取代)→ 只以見證判。
- 負對照(CI `prov-gate-stubs`):`prov_test` helper → FAIL;release → PASS;含 `WBOX-` 的假 rootfs → FAIL。

### 4.2 `-wbox` 變體(firmware `build-board.sh --wbox <name>`)
- 輸入:`feeds/batman/tests/wbox/<name>.patch`;`test` 無 patch(只 `BATMAN_PROV_TEST=1`)。**所有 `helper-*` 變體也設 `BATMAN_PROV_TEST=1`**(需要 killpoint 的負對照,§6.2);其他變體 release tag。
- 步驟:第 1–2 步(含 `-i`)→ apply patch → `export BATMAN_WBOX=<name>`(+ `BATMAN_PROV_TEST`)→ 第 3 步 lock → 第 4 步 stamp(`BATMAN_WBOX` 有值 → `DIRTY=1` 強制;VER = `$REL-$CH.$N+$F7.fw$W7.dirty.wbox-<name>`;`BATMAN_WBOX=<name>` 行;**stamp 的 `check-board-patches.sh` 照跑**,所以 patch 不得破壞板 patch 的 context,見 lint)→ `logs/wbox-<board>.stamp`(`<name>|<PROV_TEST>`)與這次不同 → `make package/batman-prov/clean package/batman-provision/clean` → 第 5–10 步 → trap:`git -C feeds/batman checkout -- . && git -C feeds/batman clean -fdx`(**`-x` 整棵 feed 工作樹**,新增檔也清)、寫 stamp。
- 正常 build:同 stamp 機制 → 上次 wbox → clean;gate 三條擋殘留。
- 輸出 `~/out/<VER>/ekh-bcm2711/`(payload、SHA256SUMS、`batman-build.txt`)。
- 只進 B;hold 或預期 REVERT;P9 任一槽 `.protected` 缺或含 `wbox` → run FAIL。
- 版本與見證斷言(`pr_ota_b`):**全在主機端**(F6):驗 SHA256SUMS → `tar -xzOf payload root.squashfs | unsquashfs -cat - etc/batman-build` 讀 `BATMAN_VERSION` / `BATMAN_WBOX` → `unsquashfs -cat` 見證所在檔 grep 見證 → 推上節點後節點端 `sha256sum` = 主機 sha → 才 `sysupgrade -n`。
- `helper-exit1`:patch 改 `feed/batman-prov/Makefile` 的 install(`GoPackage/Package/Install/Bin` → `INSTALL_BIN ./files/wbox-helper-exit1.sh`)+ 新增該檔(含見證);`check-go-toolchain.sh` 不擋(F36)。
- 變體清單(17):

| name | mutant | tag | 用在 |
|---|---|---|---|
| `test` | 無 | prov_test | killpoint 單位 helper 來源 |
| `rc9-unclaimed` | helper `--boot` rc 9 → `prov{unclaimed}` | prov_test | legacy-upgrade 負對照 |
| `96-noprov` | 96 `PCOPY=none` | — | prov-ota 負對照 |
| `helper-exit1` | helper = `exit 1` shell | — | lock-failsecure 正向 |
| `helper-nogen` | `--boot` 不比 gen | prov_test | overlay-corrupt、powerloss txn-3 負對照 |
| `96-norestore` | 96 + helper 不從 p5 還原 | prov_test | overlay-wipe 負對照 |
| `helper-nojoinop` | `net.apply` 首版不要 owner-op | prov_test | netjoin 負對照 |
| `helper-noleave` | leave 不刪 p6 標記 | prov_test | leave-ota 負對照 |
| `helper-notrial` | 不看 `IsTrial` | prov_test | trial-busy 負對照 |
| `helper-clientchal` | 採用 client 的 ClientChal | prov_test | prov-claim 負對照 |
| `helper-notxn` | 開機不對帳 `.txn`(只刪) | prov_test | powerloss txn-2 負對照之二 |
| `radio1-off` | uci-defaults `radio1.disabled=1` | — | autocommit (1) |
| `chan` | uci-defaults **`99zz-wbox-chan`**(排在 `99-batman-chanfix` 之後,uci-defaults 依檔名序執行):等 `wifi status` radio1 up 後 `uci set radio1.channel`(p5 值以外)+ commit + `wifi reload`,**不依賴 chanfix 的 log 行**(F15) | — | autocommit (4)(7) |
| `helper-flap` | helper 每 5 s exit | — | autocommit (9) |
| `misc-L38` / `misc-L42` / `misc-L43` / `misc-L51` | §6.2 | 視需要 | prov-misc |

- 成本:17 build / rc(payload 必須對應 V);E-H2 量兩次後 × 17 寫 §7.3(估 10 分 × 17 ≈ 3 h);**只在 rc 發版與動到 prov 的 PR 時 build**(P-U10)。E-H2 驗收:17 個變體各做「helper sha ≠ 前一變體」(F7 mtime 同秒風險)。
- `lint-wbox`:對 **套過板 patch 的 feed 樹**做 `git apply --check`(CI:clone firmware repo 的 `patches/ekh-bcm2711/` 先套到 `feed/`);patch 不得碰 `board-patch-digest.sh` 列出的板 patch 檔(清單比對);至少改一個 `feed/` 檔(`test` 例外);見證在 patch 內 ≥ 2 次且 `.go` hunk 的見證在 `"…"` 內;§6.2 引用的 name 都存在。

### 4.3 主機端 `prov-254.sh`
- **單位骨架**:`pr_begin <unit> <secs> [helper=<variant>]` = P9 子集 → lease(**初值 3000 s;`pr_ota_b` 落點後 +900;`pr_restore` 前 +1800**)→ deadman → `snap` →(`push-helper`)→ 步驟 → `pr_end`:
  1. 預期 REVERT 單位:等 `TRIAL-REVERTED`(≤ 720 s)→ `pr_find` 04 在 A committed → **先**讀 / 印 / 斷言 / 刪 `bad-slot`(內容 = `slot=B version=<wbox ver>`;不符 → `pr_needs_person`)→ 才 restore(F4:restore 會依快照 `rm -f` 它,順序不能反);
  2. `pr_restore` → compare diffs=0;
  3. **單位寫過 B 才 `pr_brewrite`**(§6.2 型別欄非 `—`);否則斷言 `slot-B.protected` = V 且 mtime 未變;
  4. `finish` → `rm -rf /tmp/run/batman-prov-test` → lease release → deadman cancel → 02 在 `batctl n`(**180 s 重試窗**)、02 boot_id 前後相同((7) 與 `prov-netjoin-fleet` 例外:改斷言 02 回 A committed、`badslot=[]`、在 `batctl n`)。
  任一步失敗 → `pr_abort`(= restore;再失敗 → `pr_needs_person`)。
- **`pr_normalise`**(prov 區塊開頭,**自己取 lease ≤ 1500 s + deadman**):04 committed = B、版本 V、無 wbox、無 bad-slot → 在 B 寫 hold = V → `sysupgrade -n` 進 A → HELD → `release --wait` → A committed → 之後 snap。其他不符 → `pr_needs_person`。白箱:04 留 B committed → 第一單位 PASS。
- **全套順序**:prov 區塊在 **2f 之後、2g 之前**(F25;2f 的重開讓 04 以乾淨 tmpfs 進來,但 B1 的重開不依賴它)。區塊內:`pr_normalise` → `prov-base` → (1)(4) revert 型 → hold 型 → killpoint 型 → 鏈 0 → `prov-netjoin-fleet` → (7) → `prov-legacy-upgrade`。
- **member → OTA hold 的通則(v2 A-B1,F33)**:`net-apply` 之後、`sysupgrade -n` 之前一律 `batman-slot reboot committed`(tmpfs 清空 → `lastjoined` 不在 → `m=radio`);trial 內斷言 `:420` 的 radio-only 行 + `mesh join required: 0 (prov=member mesh_expect=<m> radio_required=1)`。每單位 +3 分。
- `pr_ota_b <payload> <sha> <hold|revert> [allow-stale]`;落點斷言;落空 → disarm、清 hold、重試一次 → `pr_needs_person`。
- **還原**:F = `p5-restore` + `overlay-restore` + `reboot committed`;R = 同 F(F4);跨槽 = 在 B 上 p5-restore → rollback → A → F。`pr_restore` 開始前**延長 lease 到 +1800 s** 並在節點寫 `restoring` 標記(v1 B-M15)。(v3:`restoring` 標記在 `pr_restore` 開始時寫。)
- `pr_brewrite <node>`:docker 等待依節點角色(02 無 OTS → 不等;F23)。
- **secrets / canary**:同 p1-impl §4.2;金鑰 `~/.batman-dv/prov-keys/<run_id>/`,`pr_end` 刪並斷言;canary 掃主機 log、`logread`、p6 `*.log`、run dir。(v3:`pr_abort` / `pr_needs_person` 保留金鑰目錄。)
- `NEEDS-PERSON`:印行、檔、`DNODE_BLOCKED=1`、return 1;`NEVER_KNOWN` 含它。

### 4.4 `dv-sbx.sh`
契約 = p1-impl §4.10;步驟順序(v1 B-m9):
1. 宿主:`unsquashfs` 底(釘住 `base.env`:版本 + sha)到 `$SBX/root`;依 `feed/batman-provision/Makefile` install 規則蓋 PR 的 `files/`;helper 以 `setup-go`(SHA 釘)`-tags prov_test` arm64 原生 build;`losetup -f --show $SBX/p5.img`(宿主做,記 loop 裝置;拒絕已掛載 / 支撐 `/overlay` 的裝置)。
2. `unshare --mount --pid --fork --net --uts --ipc --propagation private -- sh setup.sh`:`mount -t proc proc $SBX/root/proc`(chroot 內要有 /proc);`/proc/sys`、`/proc/sysrq-trigger` ro bind;`/sys` 不掛;`/dev` tmpfs + `mknod null/zero/urandom` + `mknod mmcblk0p5 b <loop major> <minor>`;`kmsg` regular file;`/opt/batdata`、`/tmp`、`/tmp/run` tmpfs;`/proc/cmdline` bind 假檔;無 `/proc/device-tree`;stub `vcmailbox` / `reboot` / `wifi` / `ubus` 在 PATH 前。
3. `capsh --drop=cap_sys_boot,cap_sys_module,cap_sys_time,cap_sys_rawio,cap_mknod -- -c "chroot $SBX/root /bin/sh case.sh"`。
- `prov-unit-sbx` 負測試(job 開頭,任一不成立 → job FAIL,不跑案例):`reboot -f` → runner boot_id 不變;`mknod` runner 真實磁碟 → EPERM;`ip link add dummy0` 成功但宿主 `ip link` 無(證 netns);`ip link set eth0 down`(宿主的 eth0 不在 ns 內 → 找不到);`echo x > /proc/sys/kernel/hostname` → 失敗;`echo x > /dev/kmsg` → 宿主 `dmesg` 無。
- 案例 `tests/prov-p1/sbx/cases/<name>.sh`(p1-impl §5.1 表逐條)+ `--mutant`(負對照必 FAIL)。
- `prov-unit-gate` **獨立於 sbx**:`tests/prov-p1/gate/`,沿用 `tests/ab-card-invariants.sh` 的 loop GPT 卡 + 假 DT 檔 + `/boot/autoboot.txt`,對 `batman-slot` 跑 `.seeded` × `prov.meta` × state 矩陣;mutant「放行 claimed」+ wsl.9 的 `batman-slot`。
- CI:`timeout-minutes` 只限執行時間,**排隊不計**(v1 A-m9);E-H3 之前 job 不擋 PR(`continue-on-error` 標明),E-H3 後轉必要。
- `prov-artifact-match`(WSL,rc 時手動):`unsquashfs` rc 的 `root.squashfs`,逐檔比 batman-provision 與 pin commit 的 `files/` + install 規則;helper 以 F34 的**整串旗標**(`-buildvcs=false -trimpath -ldflags "all=-linkmode external -extldflags <TARGET_LDFLAGS>" -ldflags "-s -w …"`,E-H4 記錄實際字串)重建比 sha;不可重現 → 明列,helper 出貨產物只由節點 tier A / B 涵蓋。

**v3 修正 / 補充(取代上文中對應的句子)**:
步驟:(1) 宿主 unsquashfs 底、蓋 `files/`、build helper、`losetup -f --show`(拒絕已掛載 / 支撐 `/overlay` 的裝置);(2) `unshare --mount --pid --fork --net --uts --ipc --propagation private`:`mount -t proc proc $SBX/root/proc`、`/proc/sys` 與 `/proc/sysrq-trigger` ro bind、`/sys` 不掛、`/dev` tmpfs + `mknod`(含 `mmcblk0p5` → loop major:minor)、`kmsg` 檔、三個 tmpfs、`/proc/cmdline` 假檔、stub PATH;(3) `capsh --drop=cap_sys_boot,cap_sys_module,cap_sys_time,cap_sys_rawio,cap_mknod -- -c "chroot … case.sh"`。負測試六條(含 `ip link add dummy0` 成功但宿主無 = netns;`ip link set eth0 down` → 找不到)。案例 + `--mutant`。`prov-unit-gate` 獨立(loop GPT 卡 + 假 DT + `/boot/autoboot.txt`)。CI `timeout-minutes` 不計排隊;E-H3 前 `continue-on-error`。`prov-artifact-match` 用 F34 整串(E-H4 照 `make V=s` 記)。

### 4.5 節點端新增
- `prov-base-254.sh`:`lock-hold`、`strip-p5-prov`、`state-set`、`dm-arm` / `dm-cancel`(重用 `dm_arm`)、`restoring`。
- `prov-wbox-254.sh`:
  - `bind <name> <dst>`、`unbind-all`、`list`;
  - `push-helper <variant> <sha>`:**先寫 killpoint 檔(若單位要 arm)**,再 bind helper 到 `/usr/bin/batman-provhelper` → **一次** `restart`(同時讀 killpoint;v2 B-m16)→ 斷言 `--version` 第 2 行標記、`/proc/<pid>/exe` sha、`killpoint <name>: armed`(本次 pid)→ `wbox.list` 記 `armed <name>`;**觀察點:重開前**。restart 跑 `boot.Run`(F8),prov-state verdict 行重寫;S0 compare 以 boot_id 規則處理;
  - `upper-helper <variant> <sha>`:`cp` helper 到 `/usr/bin/batman-provhelper`(落在 A 的 overlay upper,**撐過重開**;`overlay-restore` 的「刪多出」清掉;P9 標記 grep 擋殘留)→ restart(或由重開啟動);**觀察點:重開後**;用於需要「A 以 mutant helper 開機」的負對照;
  - `arm-killpoint <name>`(單獨 arm,不換 helper);
  - `set-provd-env <k=v…>`(P2);
  - `unbind-all`:umount、`armed` → restart helper、`rm -rf /tmp/run/batman-prov-test`。
- **負對照通則**(v2 A-M2):觀察點在重開前 → bind;需要 helper 重跑開機邏輯但不重開 → `restart`(daemon 啟動必跑 `boot.Run`);觀察點在重開後 → `upper-helper`(upper,restore 清);trial 內**不能**改狀態(F9)也**不能**重開(tryboot 一次性 → 回 A)→ trial 內的注入只能是 restart 類。§6.2 每個負對照標 **[bind / restart / upper / wbox-B]**。
- `prov-sock-254.sh`(tier A):`sock-as 471 -- info` 正確;`sock-as 65534` → EACCES(F11);`sock-as 65534 --gid 471` → provclient 印 `CONN-CLOSED`(**provclient 自己的輸出**),helper log `connection refused: peer uid 65534 (want 471)`;未知動詞 → `E_SCHEMA`(20)。PEERCRED 的負對照在 Go 單元(F20 `TestWrongPeerClosed`)。
- `prov-sec-254.sh`(tier A):`prov-sec-helper-uid-254`、`prov-sec-key-perms-254`(bind 0644 副本 → FAIL)、**`prov-sec-dvpc-254`**(p1-impl §4.3:`pl_prep` 在 `mkdir` 前 `lstat`,既有且非 root 擁有 / symlink / group-or-other 可寫 → `FAIL dvpc dir pre-exists: <why>` 不放工具;白箱:root 預建 symlink → 拒絕)。

### 4.6 `provclient` 擴充與 `provgen.py`
- `net-apply`、`leave`、`owner-add` / `owner-remove`、`diag`、`sock-as <uid> [--gid g] -- <op>`、`exec <argv…>`(降權後 `execve`,清 env、無 stdin)、`proxy`(stdin/stdout ↔ 指定 socket,SEQPACKET 包界線 = 一行 hex)。
- `provgen.py`:`netcfg` / `members` / `secrets` / `chain` / `invite`;金鑰 PEM `EC PRIVATE KEY`;`--selftest`:依 F19 的 scalar 規則重算 owner-sign / admin 的 `d` → PEM → 逐位元組重現 `vectors.json` 的 `cose.net_config` / `member_list` / `net_secrets`(轉換函式也在 selftest 內驗)。

### 4.7 preflight P9(每條有 `test-dv-preflight.sh` 負對照)
- `.protected` 缺或含 `wbox`、`/etc/batman-build` 含 `wbox` → FAIL。
- helper `grep -c BATMAN_PROV_TEST_BUILD_7f3a` ≠ 0 → FAIL。
- `dv-prov-dirty` 不同 run → FAIL + restore 指令(含 bad-slot 清法)。
- bind 殘留、`/tmp/run/batman-prov-test/` 存在、helper log `killpoint .*: armed`(本次 pid)→ FAIL。
- ch1 deadman 殘留;`bad-slot` 存在 → FAIL(印內容;若 = `slot=A version=V` 註明「可能是 `pr_normalise` 殘骸:確認 A `.protected` = V 後 rm」)。
- helper state;`--destructive`:WSL 工具、`provgen.py --selftest`、`prov-test` helper 17 份 sha、`-wbox` payload 17 份、`dbus-send` ELF;`kernel.sysrq` 含 0x80;chain1 兩槽 = V;pre-P1b 偵測(`--version` rc);H3:`peer.py --selftest`、bleak、**WinRT radio state == On**(F17)、provd release 無測試 socket 目錄。

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

**v3 修正 / 補充(取代上文中對應的句子或表列)**:
#### 4.8.1 角色與裁判
同 v2:`noiseprotocol`;從 `verify.py` import CBOR / CDDL / ES256;裁判 (1) 向量(`verify.py`)、(2) `peer.py` ↔ provd;`peer.py --selftest` 對 `gen.py` transcript 逐位元組(金鑰注入同 F19);CI 負對照。

#### 4.8.2 傳輸契約
同 v2:一 packet = 一 frame;`max_frame` 244;控制包 `0xC0` / `0xC1` 只在交握前;一條 sock = 一條 BLE 連線(§8 全部計數器);socket `/tmp/run/batman-provd-test/gatt.sock`;`transport_ble.py` bleak(E-H1 驗 WinRT 後端是否把 scan response 的 service data 併進 `AdvertisementData`)。

#### 4.8.3 P2 要開的 `prov_test` 開關(`provd.env`)
- 寫者 / 讀者 / 缺檔行為同 v2;`SOCK_ONLY=1`、`FAST_FAKE_DELAY_MS=<n>`、`NO_BRUTE_LIMIT=1`。
- CI `peer-vs-provd`:`useradd -u 471 provd`;helper 以 root 跑 **真 `realSys`**,`batman-slot` / `batman-config-save` / `halow-setkey` / `prov_apply_lock` 以 PATH stub 假腳本取代(同 `prov-p1` job 的 stub 做法;不加 fakeSys 模式,§4.1.2);provd `sudo -u provd` + `SOCK_ONLY=1`。

### 4.9 服務 UUID(Q1)與廣播預算
- `batman-prov` 服務 UUID:自訂 128-bit,本設計核准時以 `uuidgen` 產生一次,寫進 219 §4.1 與常數;特徵 = base+1…+4(`RX` / `TX` / `CTRL` / `STATUS`)。
- **預算**(v1 B-m7):legacy ADV 31 B = Flags(3)+ Complete List of 128-bit UUIDs(18)= 21 → 剩 10 B;B16 的 service data(nonce + 旗標)放 **scan response**(31 B:128-bit Service Data 需 2 + 16 = 18 B 頭 → payload ≤ 13 B;nonce 8 B + 旗標 1 B 可放)。手機以 UUID 過濾 + 讀 scan response(iOS `CBAdvertisementDataServiceDataKey` 含 scan response 內容 ✅ 一般行為,⚠️ 實機在 P2 驗)。寫進 P2 設計;若 B16 的 nonce > 12 B 則改 16-bit UUID(要申請)。

**v3 修正 / 補充(取代上文中對應的句子)**:


### 4.10 BLE 空中(H3)
- 主 central = Windows 主機 `bleak`(F17:radio 目前 Off,需使用者打開;E-H1 量 RSSI)。
- 02 = 攻擊者 central(配對 / 綁定 / 佔連線),沿用 `ble-central-254.sh`。
- `prov-sec-bond` 翻轉段、`ble-rpa` N1 負對照都在 **provd 停止**模式做(`adv-on` 的前提,v1 B-M9 / B-M10)。

**v3 修正 / 補充(取代上文中對應的句子)**:


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

**v3 修正 / 補充(取代上文中對應的句子或表列)**:
| 路徑 | 本 PR 之後 | 證明 |
|---|---|---|
| install / first run | P9 逐項 | 負對照 |
| start(prov 區塊)| `pr_normalise`(lease 內) | 白箱 |
| **harness 死於 `pr_normalise` 的 A trial 中** | 600 s revert → `bad-slot slot=A version=V` → 04 回 B committed;無快照、無 dirty;下次 P9 FAIL 並印「normalise 殘骸」清法 → 需人 | 白箱 |
| start / clean stop(單位) | `pr_begin` / `pr_end` | 每單位 |
| harness 死(非 hold wbox trial 中) | revert → bad-slot → dirty → P9 FAIL + restore 指令(含 bad-slot 段) | 白箱 |
| harness 死(hold trial 中) | 期限 revert → 同上 | 白箱 |
| 誤 commit 後 harness 死 | deadman 不碰槽;P9「含 wbox」FAIL;需人 | 白箱 |
| harness 死於 restore 途中 | `restoring` → deadman 不起 joinwatch;lease 已 +1800 | 白箱 |
| harness 死(一般 / 已重開 / killpoint armed) | 同 v2 | 白箱 |
| 兩個 harness | 節點 lease 唯一互斥(含 normalise、chain1、brewrite、pty-commit) | 白箱 |
| 產品自己的重開 | 單位 ≤ 3000 s + 延長規則;§7.3 預算 | 表 |
| upgrade / rollback / downgrade / `prov_test` 被 pin / crash loop / 斷電 / eth 斷 / 依賴重啟 / CI / bcm2710 / pipe / 同時 / P2 廣播 | 同 v2 | |
| 02 在 `prov-netjoin-fleet` 中認領後還原失敗 | 02 LOCKED、擁有者 = 本 run 金鑰;`pr_abort` 保留金鑰目錄;通知寫路徑;無 OOB → 需人 | §7.2 |

## 6. 測項

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

**v3 修正 / 補充(取代上文中對應的句子)**:


### 6.2 節點(甲部)
**tier A**:`prov-boot-254`(+ 標記斷言;負對照:停 helper > 60 s → stale;`privacy off`;`batman-sc` pid;`ble-ok` 的 distroconfig bind;bind test helper → FAIL)、`prov-sock-254`、`prov-sec-helper-uid-254`、`prov-sec-key-perms-254`、`prov-sec-dvpc-254`。

**tier B**(型別 = hold|revert|— / 最終槽 / F|R;負對照標 [bind / restart / upper / wbox-B];每單位 `pr_end` 規則見 §4.3):
| 單位 | 程序與判定 | 負對照 | 型 |
|---|---|---|---|
| `prov-base-254` | snap → 改 p5 一檔 / overlay 一檔 / p6 一 state / **刪 lower 檔 `/etc/banner`** → restore → S0(含 banner 回來);restore 的 dd 期間主機送 `echo b > /proc/sysrq-trigger` → 重跑 restore → S0;3 次 `prov-boot`(v3:含刪 lower `/etc/banner`、sysrq 中斷 restore 重跑) | `PROV_BASE_SKIP=p5\|extra` → compare FAIL | — / A / F |
| `prov-legacy-upgrade-254` | 釘住 wsl.9(`DV_OLD_PAYLOAD` + sha)apply 進 B 不 hold → B commit → `strip-p5-prov` → **負對照先做**:在 B 上 hold OTA `-wbox rc9-unclaimed` 進 A → A trial 內 helper log `boot rc=9 verdict=unclaimed`(mutant)→ rollback 回 B(期限內,無 bad-slot)→ **正向**:V 進 A 不 hold → A commit → helper log `boot rc=9 verdict=legacy`、AP key / lock-status / authorized_keys / mesh-expected 前後相同(v3:負對照先做(B=wsl.9 上 hold OTA `-wbox rc9-unclaimed` 進 A → trial 內 `boot rc=9 verdict=unclaimed` → rollback)→ 正向(V 進 A 不 hold → commit → `boot rc=9 verdict=legacy`、四項不變) | [wbox-B 型,在 A trial] | hold→commit / A / R |
| `prov-claim-254` | 既有 + killpoint 段(`push-helper test` + `claim-after-persist` → sysrq → replay 同 `owner_tag_key`)+ 空 `authorized_keys`(同一 ssh 批次 bind) | `helper-clientchal` [bind,重開前] → 攻擊者 ClientChal 被接受 | — / A / F |
| `prov-netjoin-254` | `net-apply --first` → `code=0`、state=member、wireless == prov.net、overrides == prov、`rm=1`、setkey 警告 | `helper-nojoinop` [bind] → 無 owner-op 的 `--first` code=0 | — / A / F |
| `prov-netjoin-fleet-254` | **02 先 `claim.verify`**(F38;需 02 lab key,`pk_proof`)→ fleet 值經 fd 3:04 join → 入網(`batctl n` 有 02)→ 02 join → 入網;還原:04 F;02 = p5-restore + overlay-restore + 重開(經 mesh) | — | — / A / F(02 F;副作用 §7.2) |
| `prov-leave-ota-254` | member → leave → 標記刪 → **重開**(§4.3 通則)→ OTA V hold → B trial `claimed`、`mesh join required: 0 (prov=claimed mesh_expect=0` | `helper-noleave` [bind] → 標記留 → 要求鄰居 | hold / A / F |
| `prov-ota-254`(L5) | member → **重開** → OTA V hold → B:radio-only 行(`:420`)、`mesh join required: 0 (prov=member`、member、gen 同、wireless 同、上鎖、`.batman-prov-restore` `prov=full`、96 `prov: state=member copied=full` | `-wbox 96-noprov` [wbox-B] → `copied=none` | hold / A / F |
| `prov-lock-failsecure-254` | `push-helper test` + `claim-before-shadow` → claim → sysrq → 重開後斷言(F37):`lock-status=LOCKED`、root 欄 = 注入前、p5 無 `shadow-root` → OTA `-wbox helper-exit1` hold → B:`offered` 只 publickey、LOCKED | 同前置 → OTA wsl.9 hold → UNPROVISIONED(F32) | hold / A / F |
| `prov-powerloss-254-txn{1..5}` | `push-helper test` + `arm txn-N` → `net-apply --update` → sysrq → 重開(release helper)→ txn-1:`.txn` 刪、wireless 不變;txn-2:**≥ 120 s 後**(F8)`txn <verb> not committed: restored …` 行、wireless 回舊值、p5 gen 不前進;txn-3:p5 n+1 → overlay 重建、wireless == prov;txn-4:`--check` 報 stale → helper 補 `--save`、overrides == prov;txn-5:`--check` rc 0(與 txn-4 的差);全部:sysrq 行、key 登入 | txn-2 (a):`disable` 法 [重開後,真檔 `mv .txn .txn.dv`];txn-2 (b):`helper-notxn` [upper];txn-3:`helper-nogen` [upper];txn-4/5:無獨立負對照(明列,靠 txn-2/3) | — / A / F |
| `prov-netupdate-254` | bind `halow-setkey` `exit 1` + `--on-join` → p5 overrides 不前進;`arm txn-3` + `--on-join` + sysrq → member | bind 不讓路的 config-save [bind] → p5 overrides 前進 | — / A / F |
| `prov-trial-busy-254` | OTA V hold → B trial `claim` → `E_BUSY`(7) | `helper-notrial` [bind 在 B trial + restart] → 被接受 | hold / A / F |
| `prov-overlay-corrupt-254` | 寫垃圾進 A `prov.cbor` → 重開 → `overlay record unusable:` + 以 p5 重建、gen 相等 | `helper-nogen` [wbox-B hold 進 B → B 內寫垃圾 → **restart helper**(不重開)] → 不重建 | — / A / F |
| `prov-overlay-wipe-254` | 清 upper → 重開 → state、`device_id` 不變 | `-wbox 96-norestore` [wbox-B] | — / A / R |
| `prov-downgrade-254` | claimed → OTA wsl.9 hold → 還原、LOCKED、`ttylogin=1`、p5 prov 檔不刪(characterization,無鑑別力) | — | hold / A / F |
| 鏈 0 | p1-impl §5.4:apply V 進 B + cmdline `batman_bypass=1` → 受控重開 → `none` 登入 → `unknown(bypass)`、不產身分、persist 拒、96 exit 1 | 無 bypass | hold / A / F |
| autocommit (1) | `-wbox radio1-off` revert → `TRIAL-REVERTED … reason=mesh not joined/reachable (0/…)` 或 `member: HaLow mesh interface not up …`(實作時以 `health_ok` 的 `why` 字串表為準);bad-slot 順序 §4.3 | 本身 | revert / A |
| (3) | member → **重開** → OTA V hold → radio-only 行 + `mesh join required: 0` + `is healthy and HELD` | 與 (6) 互為對照 | hold / A |
| (6)(取代 (5)) | 兩臂:(6a) `sysupgrade -T` 後直接 `batman-slot apply`(無 `ota-armed.mesh`)→ `member: no usable ota-armed.mesh — neighbours required (fail-closed)` + `mesh join required: 1`;(6b) 手寫舊 boot_id 的 `ota-armed.mesh` 後直接 apply → 無 `no usable` 行、`mesh join required: 1`;兩臂都 `otalog AC UNHEALTHY first_why=mesh not joined/reachable` → **480 s 內 `back_to_a`**(無 bad-slot) | 與 (3) 互為對照 | hold + back_to_a / A |
| (7) | 04 在 A 在 mesh;02 hold OTA V 進 B → `HELD` → **02 `back_to_a`**(不 release;02 B 已是 V,不 brewrite)→ 04 `-wbox chan` revert → 04 `TRIAL-REVERTED`,04 otalog `S1 ARMED-MESH … m=joined`;02 全程 committed A | — | 02 hold+back / 04 revert / 兩台 A |
| (8) | P1 三臂(F12、F14):臂 1 `ble-ok` 在 + `btmgmt power off` → `WARN ble: … (boot_id=… hci0_powered=0 …)` + HELD;臂 2 `ble-ok` 在、BT 正常 → `WARN … (… hci0_powered=1 … adv_registered_once=0 …)`(**P1 characterization;P2 後期望無 WARN**);臂 3 `ble-ok` 不在(`state-set`)→ 無 WARN 行 + HELD | 三臂互為對照 | hold / A |
| (9) | `-wbox helper-flap` hold,04 有 `ble-ok`:health 永不 stale(F14 `Tick` 在啟動)→ WARN 行含 health 內容、HELD;`release` → commit(P-U5)→ 跨槽還原;**P1 期只證「helper flap 不阻擋 HELD / commit」,characterization**;真正的 L39(provd flap)= §6.3 `prov-provd-dos` | — | hold→commit / 跨槽 |
| (10) | member 單台 → OTA V hold → `is healthy and HELD` | — | hold / A |
| `prov-misc-254` | L38(96 的 superblock 壞出口 → 以呼叫字串定位,F13)、L42、L43、L51(`sock: unexpected`)、L11 / L9 / L10 / L27 / L3 | 各 mutant | hold / A / F |
| `prov-verbs-254` | p1-impl §5.6 正向含 `settings.get`、`settings.set hostname` → `E_UNSUPPORTED`(6,reason rename-pending)、未知 key → `E_SCHEMA`(20)、`owner.add / remove`、`ssh_keys.set`、`diag.bundle`、`qr` | 沙箱 | — / A / F |
| `prov-eeprom-hooks-254` | 對解出的 rc rootfs:shim 對所有 key `READ` rc 1;PATH 假 `vcgencmd` 回 `dropbear_authorized_keys` / `device_password` / `default_wifi_key` / `mm_region` → 讀者(96、95、morse.sh)不採用 | 1.5.12 rootfs | WSL |

### 6.3 節點(乙部,H3)
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

**v3 修正 / 補充(取代上文中對應的句子)**:
同 v2,修正:
- `prov-ble-claim-254`:`claim/replay` 的 10 / h 計**失敗**(F40):10 次錯 response 後第 11 次 → `E_RATE`(12),成功不計。
- `prov-sec-psk-timing-254`:sock 上;**節流 ≤ 18 / 分、兩臂交錯**;錯臂 `peer.py` 收到假 msg2 即主動斷(量 msg1→msg2);n 由抖動定:n ≥ (2·1.96·MAD / 效應量)²,上限 200;PASS = 中位數差 < max(2·MAD, 5 ms) 且 bootstrap 95% CI 在 ±該值;負對照 `FAST_FAKE_DELAY_MS=20`;明寫不驗「相同次數 DH」;時間預算 §7.3。
- `prov-sec-dbus-254` tier A:root 正向對照改用**無副作用**方法(`Introspect`、`Properties.Get`;先證 root 能呼叫 = dbus-send 動態連結 OK,F16);`RegisterAgent` / `Pairable` 的 root 正向只在 tier B 並立即 `UnregisterAgent` / 設回;`exec dbus-send` 以 `.libs` 二進位(E-H1 `readelf -d` 只需 `libdbus-1.so.3` + musl)。
- `ble-rpa-254` provd 模式:**三態**(F28 時間條件):無重註冊 → 同 RPA;重註冊且距上次 RPA 改變 < 900 s → 同 RPA;≥ 900 s → 新 RPA;以 provd log `adv re-registered reason=<…> nonce=<8hex>` 時間戳 + btmon 對齊;N1 = 停 provd + `adv-on`。
- `prov-two-phones-254`:第二個 → `E_BUSY`(7)(設計決定,回 219 §10:provd 需實作認領互斥)。
- `prov-provd-dos-254`、`prov-respawn-254`:同 v2(超大訊息 = 斷線;provd 退避 log 契約)。

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

**v3 修正**:provd 測試 socket 擋法 = 目錄 provd 0700;`prov-sec-dvpc` 列入「我們自己」;02 認領後的金鑰保留(§3)。

### 7.2 副作用(新增)
| 動作 | 碰到 | 還原 | 斷言 |
|---|---|---|---|
| `prov-netjoin-fleet` | 02 認領(LOCKED、密碼關、擁有者 = run 金鑰)、`wifi reload` | 02 p5-restore + overlay-restore + 重開(經 mesh,無 OOB) | 02 回 legacy、`batctl n`;失敗 → 金鑰保留 + 需人 |
| (7) | 02 一次 held trial + `back_to_a`(兩次重開) | 自身 | 02 A committed、無 bad-slot |

### 7.3 成本(v2 A-m3 重算)
- hold 型單位:snap 1 + net-apply 2 + 重開 3 + OTA 3 + settle 1.5 + HELD ≤ 8 + 斷言 2 + back_to_a 3 + restore 5 + compare 1 + brewrite 14 ≈ **47 分**;revert 型 ≈ 37 分;`—` 型(不 brewrite)≈ 20 分。
- 全套:約 30 單位 + 8 個獨立 held-trial 負對照 × 15 分 + (9) 跨槽 15 分 ≈ **22–23 h**;04 OTS 中斷 ≈ 每單位 15 分 × 30 ≈ **7.5 h**;02 隔離約 3 h;SD 約 45 GiB。
- `-wbox` build:17 × ⚠️(E-H2)≈ 3 h / rc。

## 8. 工作順序與 PR

**v3 補充**:E-H1 加:`readelf -d .libs/dbus-send`、04 以 uid 471 `dbus-send --system --print-reply --dest=org.bluez / org.freedesktop.DBus.Introspectable.Introspect`、bleak WinRT scan response 合併;E-H2 加 17 變體 sha 互異;E-H6 sysrq 一次。
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

**v3 修正 / 補充(取代上文中對應的句子)**:


## 9. 殘項(回 #254)
v2 全部 + `joinwatch.lastjoined` 不在 `rundir-paths.txt`(產品側);autocommit (5) 的「trial 內刪檔」不可測(已由 (6) 兩臂取代);(9) P1 期 characterization;txn-4 / txn-5 無獨立負對照。

## 10. 回報上層
v2 的 1–4 + 5. stage1 §6.4 (3):radio-only 前提 = 本次開機未 JOINED(F33),測項以重開滿足;(5) 改 (6) 兩臂;(9) 的 L39 本意是 provd flap,P1 期不可測;6. **不**要求 P1b 加 txn log 行(F13 既有兩行足夠;v2 §10 第 5 點撤回);7. p1-impl §4.3 放置負測試落地為 `prov-sec-dvpc-254`。

## 11. 待決

**v3 補充**:D-H10:(9) 是否保留在甲部(建議保留為 characterization)。
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

**v3 修正 / 補充(取代上文中對應的句子)**:


## 12. v2 審查 → v3 對應
| 發現 | 處置 |
|---|---|
| A-B1 `lastjoined` | §4.3 通則(member → 重開 → OTA);F33;(3)/`prov-ota`/`leave-ota` 改;§1.4 |
| A-M1 (5)/(6) 字串 / 時序 / 型別 | (6) 兩臂取代 (5);F12 字串;hold + 480 s back_to_a |
| A-M2 trial 內負對照不可能 / txn-3 鑑別 | §4.5 負對照通則 + `upper-helper`;helper 變體一律 `prov_test`;§6.2 每列標法;txn-3 → `helper-nogen` |
| A-M3 bad-slot 順序 | §4.3 `pr_end` 步驟 1 在 restore 前;§3 |
| A-M4 (7) 02 停 B | 02 `back_to_a`,不 release、不 brewrite |
| A-M5 / B-M2 (8)(9) | 三臂括號內容;(9) characterization;F14 Tick |
| A-M6 wbox × 板 patch / exit1 / stamp / 成本 | `lint-wbox` 對套板 patch 的樹 + 檔案清單;`helper-exit1` 改 Makefile;17 變體 sha 互異;§7.3 |
| B-M1 socket 目錄權限 | provd:provd 0700 |
| B-M3 chanfix 行 | `99zz-wbox-chan` 依 uci-defaults 順序,不依賴 log |
| B-M4 rpa 三態 | §6.3 |
| B-M5 dbus-send wrapper | F16;`.libs`;ELF 斷言;E-H1 |
| B-M6 / A-m14 dvpc 負測試 | `prov-sec-dvpc-254` |
| B-M7 timing 限速 / n | §6.3 |
| A-m1 sysrq 退路 | `sleep 2` 偵測 |
| A-m2 normalise lease | §4.3;§5 新列 |
| A-m3 時間 / brewrite 省略 | §4.3 lease 規則、步驟 3;§7.3 |
| A-m4 txn-2 字串 | F13 既有兩行;§10 第 6 點撤回 |
| A-m5 txn-5 視窗 | §4.1.1、§6.2 |
| A-m6 96 行號 | F13 以呼叫字串 |
| A-m7 lock-failsecure 前置證據 | F37;§6.2 |
| A-m8 / B-m8 DNODE 機制 | §3:`$cmd` 含 DNODE IP |
| A-m9 / B-m9 2f | §4.3 |
| A-m10 rundir-paths | §2.2 不改 |
| A-m11 02 認領 / 金鑰保留 | `prov-netjoin-fleet`;§3 金鑰列;§7.2 |
| A-m12 fakeSys 模式 | §4.8.3 PATH stub |
| A-m13 02 batctl 窗 | 180 s |
| A-m15 F7 / F34 / CONN-CLOSED / dbus root / noiseprotocol | F7、F34、§4.5、§6.3、F17 |
| B-m1 F3 | 14 |
| B-m2 F12 | 任何 COMMITTED 刪 |
| B-m3 120 s | §6.2 txn-2 |
| B-m4 clean -fdx | §4.2 |
| B-m5 Go 見證字串 | §2.1、§4.1.3、lint |
| B-m6 replay 失敗計 | F40;§6.3 |
| B-m7 NEVER_KNOWN | §2.2 |
| B-m10 / A-m2 normalise 殘骸 | §5、§4.7 |
| B-m11 deadman 共用 | §2.2、§3 |
| B-m12 dbus root 副作用 | §6.3 |
| B-m13 radio P9 / scan response | §4.7、§4.8.2 |
| B-m14 scalar 規則 | F19、§4.6 |
| B-m15 tmp-trust 範圍 | §2.2 |
| B-m16 一次 restart | `push-helper` |
| B-m17 brewrite 02 | `pr_brewrite <node>` 依角色 |
| B-m18 parser 測試 | §2.2 四案例 |
| B-m19 (1) reason 字串 | F12 `why` 表 |

## 13. v1 審查 → v2 對應(歷史)
(v2 §12 內容原樣保留於 git 歷史 b2a00da;本版不重複。)
