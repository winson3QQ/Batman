# Design: #254 PR-H3 — harness:H2 補完(P1 tier B / 沙箱 / 接縫)+ H3(provd / BLE / `peer.py`)— **v14(審查中)**

**狀態**:**v14 審查中**,2026-10-28(§23 = v13 審查的修訂,優先於前文全部;v13:A AWC 0/1/10、B AWC 0/0/8;§22 = v12 的修訂;v12:A AWC 0/1/12、B AWC 0/0/9;§21 = v11 的修訂)。v7 定稿之後的增補:§16(P1b 程式碼審查 r1–r4 的修訂)、§17(misc 變體,v9 重寫)、§18(安全審查)、§19(v9 審查)、§20(v10 審查,優先於前文全部)。v8:§17 兩位 REJECT;v9:A AWC 0/3/16、B REJECT 0/4/16;v10:A AWC 0/2/14、B AWC 0/1/11(`254-reviews/h23-review-v{8,9,10}-{A,B}.md`)。以下為 v7 時的狀態:v6 審查:A **APPROVE**(0 / 0 / 4)、B **APPROVE-WITH-CHANGES**(0 / 0 / 10)(`254-reviews/h23-review-v6-{A,B}.md`),兩位都表示不需再審整份;v7 = v6 + §15(把 14 個 MINOR 寫成實作規格,**§15 與前文衝突時以 §15 為準**)。v6 之前:v5 審查:A APPROVE-WITH-CHANGES(0 / 0 / 6)、B APPROVE-WITH-CHANGES(0 / 1 / 12)(`254-reviews/h23-review-v5-{A,B}.md`);v6 收全部,對應表 §14(§12、§13 是前兩輪的表)。歷史:v1 A REJECT 2/8/12、B REJECT 3/17/14;v2 A REJECT 1/6/15、B AWC 0/7/19;v3 A AWC 0/7/10、B AWC 0/6/13;v4 A AWC 0/2/14、B AWC 0/3/15;v5 如上。使用者決定(2026-10-28):H2 沒做完的部分照 `254-p1-impl.md` §5 補完,與 H3 一份設計、兩段實作;608B(#255)擱置。

上層:`254-stage1-impl.md` v19、`254-p1-impl.md` v5.1、`254-h1-harness.md` v8、`254-claim-lock-fix.md` v9.1、`219-protocol.md` v0.7、`219-protocol.cddl`。

## 0. 一句話

一個 harness PR(`harness/254-h23`)把 P1 的測試補到設計要求的覆蓋(約 30 個 tier B 單位 + CI 沙箱矩陣),並為 P2 準備協定對手 `peer.py` 與 provd / BLE 測項;產品只加「為了可測」的接縫(killpoint 檔、`--version`、`prov_test` build、`-wbox` 變體、provd 測試傳輸),由一個小的產品 PR(PR-P1b)與 PR-P2 承擔。

## 1. 決策、範圍、事實

### 1.1 使用者決策
| # | 決定 | 日期 |
|---|---|---|
| H3-U1 | H2 缺口照設計補完(選項 1),不做 H2-lite | 2026-10-28 |
| H3-U2 | 一份設計、兩段實作:甲 = H2 補完 + 接縫(wsl.4 基礎的 rc 上驗);乙 = H3(等 P2 rc) | 2026-10-28 |
| H3-U3 | 成本接受:約 22–23 h / 輪、04 OTS 累計斷約 7.5 h、02 隔離約 3 h、SD 約 45 GiB(§7.3);依 P-U10 只在動到 prov 的 PR 與發版時跑 | 2026-10-28 |
| H3-U4 | 608B / #255 擱置 | 2026-10-28 |
| (沿用)H-U2 / H-U3 / H-U4、P-U5 / P-U9 / P-U10 / P-U12 / P-U14、H-U6 | | |

本設計自行定、審查者可攻:Q1 UUID 自訂 128-bit + scan response(§4.9);`peer.py` 主傳輸 = provd `prov_test` frame socket(§4.8),BLE = Windows `bleak`(§4.10);`peer.py` Noise = `noiseprotocol`;斷電代理 = sysrq `b`;**所有 `-wbox` trial 一律 hold**(§4.2);需要 killpoint 的 helper 變體帶 `prov_test` tag。

### 1.2 範圍
**甲部(H2 補完)**
1. 接縫規格(PR-P1b;§4.1、§4.2)。
2. tier A:`prov-boot-254`(接線 + 標記斷言)、`prov-sock-254`、`prov-sec-helper-uid-254`、`prov-sec-key-perms-254`、`prov-sec-dvpc-254`、`prov-sec-sockdir-254`(helper socket 目錄預置 → 拒絕啟動,p1-impl §5.3 `prov-misc` 的那條)。
3. tier B(04):p1-impl §5.3 全部 + §5.4 鏈 0 + §5.5 (1)(3)(6)(7)(8)(9)(10) + 雙台 `prov-netjoin-fleet-254`;powerloss 五個 killpoint 各一單位。**(4) = (7) 的 04 側**(有鄰居、`chan` mutant → revert),不另列;**(5)「trial 內刪 `ota-armed.mesh`」不可測**(autocommit 開機一次讀 `:419`),由 (6) 兩臂取代。
4. 沙箱(CI arm64):`dv-sbx` + p1-impl §5.1;`prov-unit-gate` 獨立。
5. 主機端 `scripts/dv/prov-254.sh`。
6. P9 補 §4.7;全套順序(2f 之後、2g 之前)+ `pr_normalise`;known-failures 第 4 欄到期 + `NEVER_KNOWN` 補 `NEEDS-PERSON|blocked: DNODE`;移除 7 行過渡條目;chain1 前置兩槽 = V;prov lease 擴到 chain1 / brewrite / pty-commit。
7. `provclient` 擴充 + `provgen.py`(§4.6)。
8. `prov-eeprom-hooks-254`(WSL)。
9. lint / 清單 / CI 更新(§2.2,含 Go 單元測試以 root 跑)。

**乙部(H3;等 PR-P2 rc)**:`peer.py`、provd 測項(§6.3)、P2 要開的測試接縫(§4.8.3)。

**不在本 PR(逐條理由)**:P3 測項(H4);bcm2710 真機(P-U14);**`prov-unit-bcm2710` CI smoke 也不做**(P-U14:連沙箱底都不維護第二份,日後 Pi 3 恢復時一起加);轉賣工具與 L16 節點層;iPad GATT 自動化(手動);`prov-rename`(U5);真斷電(sysrq 代理);release asset 掃描(Batman 的 release asset 由發版流程手動上傳,tag push 時不存在;供應鏈三層擋:firmware gate、P9、tier A);`docs/validation` 的 P-U10 文字(另 PR);autocommit (5)(上);autocommit (9) 在 P1 只能 characterization(§6.2);txn-4 後 `overrides` 的補寫是產品缺口(§6.2,回 #254);**claim-lock §11.4 的真機 tier B(4 / 4-inj / 4b / 4b' / 4c / 4d / 5)**:使用者 2026-10-26 決定縮小(claim-lock §13、F27),本 PR 不做,仍在 #254 checklist。

### 1.3 事實(2026-10-28 唯讀實查,main 5914f03;fleet 02/04 = `1.5.14-wsl.4+7fd2124.fw6be516a`)
| # | 事實 | 證據 |
|---|---|---|
| F1 | P1 出貨沒有任何測試接縫(`killpoint` / `prov_test` / `wbox` 零命中) | grep |
| F2 | H2 實際交付:`prov-base-254.sh`、`prov-p1-254.sh`(未接線)、`addr-defer-254.sh`、CI stub、`prov-claim-254.sh` 草稿 | #306;`daily-validation.sh` |
| F3 | daily-validation 現有 #254 測項 14(含 `harness-negctl-254`) | `daily-validation.sh:208,214,227-296` |
| F4 | `prov-base-254.sh` restore = `p5-restore` + `overlay-restore`(tar 覆蓋 upper + 以 `tree_manifest /overlay/upper` 全樹刪多出 + 每個 `STATEFILES` 寫回快照值,快照沒有就 `rm -f`);鏈 1 R 類 = 這條 + `reboot committed` + brewrite;無 `firstboot -y` | `prov-base-254.sh:29,65-71,190-220`;`chain1-254.sh:122-176` |
| F5 | E4 沒做;`overlay-allow.txt` 3 條;`jffs2reset` = 掛著刪 upper 再 sync | `tests/prov-p1/overlay-allow.txt`;fstools `overlay.c:139-142,322-342` |
| F6 | payload 只有 `SHA256SUMS` + `metadata`(`version=` 時間戳);無簽章;04 沒有 `unsquashfs` / `mksquashfs`;**04 的 upper 沒有 `usr/bin/`**(upper 副本 = 多出的檔) | `platform-ab.sh:12,156,329,374`;`batman-slot:591-600`;`build-ab-payload.sh:69`;04 `ls` 2026-10-28 |
| F7 | stamp:DIRTY `:38-44`、VER `:52-53`、`check-board-patches.sh` `:48`、`patch-witness.sh list` `:49`;OpenWrt 重建雜湊 = 套件目錄檔案 md5 + mtime,不含 env;`GO_PKG_TAGS`;`build-board.sh` 第 2 步 `-i` reset feeds、BASE dirty 閘只看 `package target …`、第 7 步 `patch-witness.sh check` | `stamp-batman-build.sh`;`package.mk:114`、`depends.mk:14`;`golang-package.mk:106-111,260`;`build-board.sh:74-96,170` |
| F8 | helper CLI 無 `--version`(其他 → usage exit 2);非 root exit 2;daemon:`boot.Run` → 有 Restore 則 `go restoreWireless(…, 120 s)`(**用記憶體裡的 Txn**,睡 120 s 後 setkey,rc 0 才 `RemoveTxn`)→ `keystore.Load`(失敗 `select {}`)→ `applyState` → `go h.Run` → `PrepareDir` → serving;`Sys` 20 法;`commitTxn`;`.txn` tmp + rename + fsync | `main.go:373-407,439-462,479-495`;`node.go:62-83`;`txn.go:16-34`;`provstore/txn.go:21-40`;`provstore.go:326` |
| F9 | 錯誤碼 `EStaleVersion 5`、`EUnsupported 6`、`EBusy 7`、`EStorage 10`、`ERate 12`、`ESchema 20`、`EApply 21`、`EState 22`(內部)、`ELockIncomplete 23`;協定無 `E_STATE`;改狀態動詞在 trial 一律 `EBusy "trial slot (updating)"` | `node.go:33-50,163-170` |
| F10 | `provclient` 7 動詞;keygen PEM `EC PRIVATE KEY` 0600;降權 471;`unixpacket` | `provclient/main.go:294-305,417-424,470,489-560` |
| F11 | helper socket 目錄 `PrepareDir`:root 0750 chown gid 471;非 root 擁有 / symlink / 目錄裡 `helper.sock` 以外任何東西 → `sock: … refusing to start`;socket 0660;uid ≠ 471 → log `connection refused: peer uid <u> (want 471) <err>`(**尾巴 `%v`**,grep 用前綴) | `sock.go:37-89,136-141` |
| F12 | autocommit(START=99):REVERT 寫 `bad-slot`;任何 COMMITTED `rm -f bad-slot`(`:361` 是拒絕 commit);字串:`TRIAL-REVERTED boot=… slot=… version=… waited=…s reason=<why>`、`HOLD-COMMIT`、`HOLD-COMMIT-DISCARDED`、`mesh join required: <n> (prov=<v> mesh_expect=<m> radio_required=<r>)`(`:425`)、member 臂:三欄且 boot_id = boot-reasons 倒數第二行且 slot 相符且 `radio` → `NEED_MESH=0` + `member: armed in radio-only mode (ota-armed.mesh) — no neighbour required`(`:420`),否則 `NEED_MESH=1`,檔缺才印 `member: no usable ota-armed.mesh — neighbours required (fail-closed)`(`:421`);`why`:`member: HaLow mesh interface not up on the configured mesh id`(`:494`)、`mesh not joined/reachable (<n>/<JOIN_NEED> samples: …)`(`:502`,**串接在既有 why 之後**)、`mesh lost (…)`(`:503`);`otalog AC UNHEALTHY first_why=<why>`(`:505`);**`WARN ble: ble-ok present but BLE health is not good (<health line \| no health file>) — not blocking (P-U5)`(`:499`)只在 `ble-ok` 存在且 health 行不含三個 `=1` 時印,且本次開機只印一次(`autocommit.ble-warned` latch,`:496-500`;autocommit 開機即 poll,`:487`)**;`is healthy and HELD`(`:513`);`COMMITTED`(`:537`);hold 只擋 commit 不擋 revert(`:233-244,277`);`release --wait`;`AUTOCOMMIT_DRYRUN` | `batman-autocommit`;`init.d/batman-autocommit:6` |
| F13 | 96 字串:`prov: state=<st> copied=<…>`(`:168`);`/etc/.batman-prov-restore` = `<boot_id> <verdict> prov=<PCOPY> state=<PST> lock=<LOCKWORD>`(`:113`);`root password restored from p5`(`:193`);96 唯一 `exit "$2"`(`:115`),出口以呼叫字串區分;helper:`boot rc=<n> verdict=<v> action=<a>`(`boot.go:59`;`action=txn <verb> NOT committed (gen n): wireless to be restored`,`:127`;`txn <verb> committed (gen n): overlay completed from p5`,`:120`)、`overlay record unusable: …`(`:72`)、`p5 lost a committed prov write (…)`(`:187`);restore 完成 `txn <verb> not committed: restored the previous wireless values, setkey rc=<n> (<out>)`(`main.go:504`) | 原始碼 |
| F14 | health:stale = ts > 60 s;`Run` 第一件事 `Tick(15)`;P1 固定 `adv_registered_once=0`(`:138`);`ble-ok` 條件 `poweredFor ≥ 600 && Committed && ConfigOK`(程序內計數;**committed 槽的 helper 15 s 內會把刪掉的 `ble-ok` 寫回**;trial 槽 `Committed()` 假 → 不寫) | `health.go:8-9,138,151-157,160-166` |
| F15 | 99-batman-chanfix:**整段在 `( … ) &` 背景子殼**(等 `wlh0` ≤ 80 s → `sleep 8` → 比 uci 頻道與 p5,不同就 `uci set` + `wifi reload`,最多 6 次);第一次相符(`a=0`)靜默 exit、無 log;子殼沒有可 `pgrep` 的名字;uci-defaults 由 base-files `/etc/init.d/boot` 以 `files="$(ls)"`(位元組序)逐檔 `( . "./$file" ) && rm -f` 執行 → 檔名序只排「啟動」,`99-batman-chanfix` < `99zz-batman-prov-state` < `99zz-wbox-*` | `99-batman-chanfix:18-58`;`package/base-files/files/etc/init.d/boot:7-17`(B 複驗) |
| F16 | 節點沒有 python3 / busctl / unshare / unsquashfs;有 `libdbus-1.so.3`(1.14.10);firmware 樹 `tools/dbus-send` 是 libtool bash wrapper(10004 B),真二進位 `tools/.libs/dbus-send`(ELF aarch64 77424 B);04 的 `bluetooth.conf` 只有 root policy、無 default policy → uid 471 連 Introspect 都 AccessDenied(P1 期;**P2 後亦然**:stage1 §4.6 的 provd policy 只放行 `LEAdvertisingManager1.*Advertisement`、`GattManager1.*Application`、`ObjectManager.GetManagedObjects`、`Properties.{Get,GetAll}`、`Device1.Disconnect`,沒有 `Introspectable`) | 04 `ls`;`file`;staging rootfs `etc/dbus-1/system.d/bluetooth.conf`;stage1 §4.6 `:308` |
| F17 | Windows venv `C:/Users/yello/batman-dv-tools/pyble`:`bleak 0.22.3`、`noiseprotocol 0.3.1`、`dissononce`、`pycose`、`pycddl`、`cbor2`、`ecdsa`、`cryptography` 已裝;MediaTek adapter OK、`bthserv` running、**radio Off** | pip、WinRT |
| F18 | GitHub `ubuntu-24.04-arm` 公開 repo 免費(2025-01 公開預覽);Batman PUBLIC;**firmware repo PUBLIC,但它唯一的 release 是 Draft `fw-build-108-final`(上游 OpenMANET image);Batman 的 A/B payload 資產在 Batman repo 的 releases(最新 v1.5.11:`batman-1.5.11-rel.1+6a049f2.fw7049fd8-ekh-bcm2711-ab-payload.tar.gz` + `SHA256SUMS`);`1.5.14-wsl.4` 沒有任何 release 資產** | changelog;`gh repo view`;`gh release list / view`(2026-10-28) |
| F19 | `verify.py` 純腳本,模組層讀向量(`:176-186`);`gen.py` `noiseprotocol` + 注入金鑰(`:225-227`);scalar 規則 `d = (int(SHA-256('batman-test-vector/'+name)) mod (n-1)) + 1`(`:38,184`);`MIN_CHECKS=195`;`requirements.txt` 釘 `noiseprotocol==0.3.1` | 原始碼 |
| F20 | repo 無 provd / Noise / GATT / UUID;`feed/batman-prov/src/` 有 `proto`、`cbor`、`cose`、`shacrypt`;go.mod 只 `x/crypto`;`sock_test.go:67 TestWrongPeerClosed` 存在**但 `needRoot` 在非 root `t.Skip`,CI `go test ./...` 以非 root 跑 → 今天從未在 CI 跑過** | `go.mod`;`sock_test.go:13-17,67`;`ci.yml:74` |
| F21 | 04 BLE `powered le secure-conn privacy`;`kernel.sysrq = 502` | 04 |
| F22 | `ble-periph-254.sh cmd_adv_on` 第一動作 `mg rm-adv 1`;`ble-lib-254.sh`:`dm_arm` 以 `$ST/dm` / `dm.new` 保證每台至多一個 deadman;**`cmd_dm_fire` = `sleep N` → 重讀 `$BT/lease` → lease 不是該 run / 未到期 → `exit 0`,不重排**;延長 = 重新 `dm_arm`(舊 group 被 `pg_kill`) | `ble-periph-254.sh:42-52`;`ble-lib-254.sh:84-134,212-228` |
| F23 | `prov-lib-254.sh pl_prep`:`PCD=/tmp/run/batman-dvpc.$RUN`、`mkdir -m 0711 $PCD`(無 `-p`)`|| no "tool placement"` → 已存在即 FAIL,但沒有白箱;**`chain1-254.sh:112,315` 用固定名 `/tmp/run/batman-dvpc/` + `mkdir -p -m 0711`(已存在 / symlink 不拒 = 放置缺陷),今天靠 tmp-trust 第 13 行無邊界 regex 過關**;`brewrite-254.sh`:`NODE` 預設 04、`:21` 前置 `badslot=[]`、`:37` 等 docker ≥ 6 | `prov-lib-254.sh:20,92`;`chain1-254.sh:112,315` |
| F24 | 鏈 1:`find04`、deadman、主機鎖、`restore_all` 刪 bad-slot、已 > 3000 s、joinwatch 還原事故註解 | `chain1-254.sh` |
| F25 | 2e → 2f(#305 tier B,`bt-uart-boot-305` 對 DNODE loaded reboots,不動槽)→ 2g(pty-commit 移槽);`fault-injection` 目標 `$OTS_NODE`、`reflash-202` 目標 `$MESH_NODE`(在呼叫端展開);`suite()` 只收 4 參數;`NEVER_KNOWN`(`:2740`,ERE);`classify` 只抓 `^FAIL `;known-failures `read -r ks pat iss` | `daily-validation.sh:77-99,127,254-296,335,386,2175,2740-2749` |
| F26 | known-failures #254 過渡條目 7 行;3 欄無到期 | `validation-known-failures.txt:10,19-24` |
| F27 | claim-lock §11.4 4 / 4-inj / 4b / 4b' / 4c / 4d / 5 只有 CI stub | memory |
| F28 | 04 S0 = 現況 | 10-27 全套 |
| F29 | kernel `CONFIG_MAGIC_SYSRQ=y`、`DEFAULT_ENABLE=0x1f6`;**`/proc/sysrq-trigger` 的寫入走 `__handle_sysrq(c, false)`,不看 mask**(mask 只管鍵盤) | `.config`;`drivers/tty/sysrq.c:571,598,1152-1167` |
| F30 | tmp-trust **有掃 `scripts/dv/*.sh`**(git pathspec `scripts/*.sh` 跨 `/`;allowlist 已有 `scripts/dv/` 條目 `:71,72,75,87,95,97`);`prov-lib-254.sh:20` 的 `/tmp/run/batman-dvpc.$RUN` 與 `chain1-254.sh:112,315` 的 `/tmp/run/batman-dvpc/` 今天過關都是靠第 13 行 `scripts/*` 的無邊界前綴 `/tmp/run/batman-dv` 以 `sed s///g` 切掉命中;第 99 行 `/tmp/run/batman-prov` 同樣無邊界;Go 原始碼今天只有 `main.go:40`、`sock.go:2` 兩處,後接 `/` 或 `"` | `check-tmp-trust.sh:23,29,55`;`tmp-trust-allowlist.txt:13,99` |
| F31 | `batman-slot apply` 刪目標槽 `.protected`;95 寫完整版本;rollback gate 只擋 claimed/member | `batman-slot:424-436,771-791`;`95:717` |
| F32 | wsl.9 有 HOLD-COMMIT;wsl.9 的 96:key 且密碼都在才 LOCKED | `git show f2f2bf6` |
| F33 | joinwatch `t_reboot 3600`;`$RUNDIR/joinwatch.lastjoined` 由 joinwatch 寫(`:135`)、無刪除者、tmpfs、**已在 `rundir-paths.txt:97`**;stage 1 `_ab_arm_mesh`:caller `/sbin/procd*` + `$RAM_ROOT/sbin/upgraded` + `_ab_live_sysupgrade` 才寫;`lastjoined` 存在 → `m=joined`,否則當下 `meshjoin_joined` → `joined`,否則 `radio`;`batman-slot` 不寫此檔 | `joinwatch:135`;`platform-ab.sh:104-115`;grep |
| F34 | golang 旗標:兩個 `-ldflags` + `-buildvcs=false -trimpath` + `-tags` | `golang-package.mk:236-262` |
| F35 | deploy/ots 無 `/dev/log`、`/tmp/run`、`/opt/batdata/state` bind | grep |
| F36 | gate 位置 第 7 步 `$WR/r`;`check-go-toolchain.sh` REQUIRED 不含 helper | `build-board.sh:146-172` |
| F37 | S13 只在 p5 `ok claimed|member` 且 identity 同 overlay 且 `prov_root_hash_ok` 才收斂 root;否則只鎖門 | `batman-prov-lock:7-11,50-56` |
| F38 | `net.apply` 首版要 owner-op;legacy 02 要先 `claim.verify` | `node.go:218-224,996-1000` |
| F39 | `applyNet` 在 `--save` 後只剩回應;`prov-state` 只在 `boot.Run` 與 claim 寫;**開機後沒有任何程式呼叫 `--save` / `--check` 補 overrides**(`Save` 只在 `applyNet` / claim / owner / ssh_keys 動詞;`--on-join` 要 JOINED) | `node.go:399-454,795,1120`;`boot.go`、`main.go` grep 零命中;`batman-config-save:165-166` |
| F40 | `claim/replay` 10 / h 計失敗 | `node.go:94,542-549` |
| F41 | `boot.Run` 開機路徑:有 `.txn` 先走 txn 分支(`g == t.To && p5Rec != nil` → `WriteOverlay(p5Rec)` + `RemoveTxn`,**不看 gen 比對**;`g == t.From` → Restore;其他 → `unknown(txn-generation)`);gen 比對只在無 `.txn` 時:`case ovRec == nil \|\| p5Rec.Generation > ovRec.Generation` → 重建(`:180-184`),**下一個 case `ovRec.Generation > p5Rec.Generation`(`:185`)在 `ovRec == nil` 時會 nil 解參考**(mutant 跳過第一個 case 必須自己處理 nil) | `boot.go:105-130,178-190` |
| F42 | autocommit watchdog:`DEFER_MAX=600`,slot write / first-load / payload converge 進行中時 revert 延後(log `revert deferred: slot write, first-load or payload converge in progress (max 600s)`),最多再 600 s 才寫 bad-slot 與重開;dry-run 接縫:`AUTOCOMMIT_DRYRUN=1` + `AUTOCOMMIT_FORCE_TRIAL=1`(committed 槽也當 trial 評估)印 `DRYRUN decision: COMMIT …` / `DRYRUN decision: REVERT …`;`AUTOCOMMIT_DEFER_MAX` 只在 dry-run 生效;deadline 寫在 `$RUNDIR/autocommit.deadline`,p6 `autocommit.timeout` 可改(04 目前沒有此檔 = 預設 600) | `batman-autocommit:27,35,48,69,162,194,223-228,240,270,323,529`;04 `cat` 2026-10-28 |
| F43 | BlueZ client 端遠端特徵的 D-Bus `Flags` 只來自 characteristic declaration 的 property 位元(`broadcast`、`read`、`write-without-response`、`write`、`notify`、`indicate`、`authenticated-signed-writes`、`extended-properties`、`reliable-write`、`writable-auxiliaries`);`encrypt-*` / `authenticated-*` 只在 server 端 app 宣告(`gatt-database.c`),central 永遠看不到;安全需求以 ATT 錯誤(0x05 / 0x0F)在存取時才表達 | `bluez-5.72/src/gatt-client.c:814-830`;`src/gatt-database.c:1760-1833`(B 查) |
| F44 | `unsquashfs`(squashfs-tools 4.6.1)的 FILESYSTEM 參數要能 `lseek`,**不吃 stdin**;payload 內檔名 `root.squashfs` | WSL `unsquashfs -help`;`build-ab-payload.sh:61,73`;`build-board.sh:162` |

### 1.4 與上層設計不同處(→ §10)
- p1-impl §4.5.3 同槽重建 = 鏈 1 程序;E4 作廢;`prov-base` 補 whiteout 負對照;opaque 未查(§9)。
- p1-impl §2.2 `dv-sbx` shell;`-wbox` 真 build + 見證;known-failures 到期欄落地。
- p1-impl §7.4 推播:daily-validation 印 `NEEDS-PERSON`;推播由操作 session 做。
- p1-impl §4.5.0 順序:prov tier B 在 2f 之後、2g 之前 + `pr_normalise`。
- p1-impl §5.5:(4) 併入 (7) 04 側;(5) 由 (6) 兩臂取代;(8) P1 期以 `ble-ok` gate 兩臂 + `hci0_powered=0` 臂;(9) characterization。
- stage1 §6.4 (3) radio-only 前提 = 本次開機未 JOINED(F33)→ member → OTA 前多一次重開。
- **所有 `-wbox` trial 一律 hold**(hold 不擋 revert,F12):mutant 有效 → 期限 revert;無效 → `HELD` → harness 判「mutant 無效」FAIL + `back_to_a`,不會 commit mutant 槽。

## 2. 元件

### 2.1 產品接縫(PR-P1b)
| 元件 | 位置 | 說明 |
|---|---|---|
| killpoint 檔 | 套件 `batman-prov/seam`(名稱刻意不含 killpoint,§16.10):`points.go`(無 tag,`seam.Point` 整數常數)、`seam_provtest.go`(`//go:build prov_test`,實作)+ `hook_provtest.go`(單元測試用的 `ArmForTest`)、`seam_release.go`(`//go:build !prov_test`,空 `Arm` / `At`);單元測試 `seam_provtest_test.go` / `seam_release_test.go` + `node/seam_points_test.go`。**實作檔不得叫 `*_test.go`**:`go build` / `go install` 一律排除 `_test.go`,實作會不進二進位而 `go test` 照樣綠(v5 B-M1) | §4.1.1 |
| `--version` | `main.go`:第 1 行 `batman-provhelper <BATMAN_VERSION>`;`prov_test` 第 2 行 `BATMAN_PROV_TEST_BUILD_7f3a`;exit 0 | pre-P1b 偵測 |
| `prov_test` tag | `feed/batman-prov/Makefile`:`ifeq ($(BATMAN_PROV_TEST),1) GO_PKG_TAGS:=prov_test else GO_PKG_TAGS:= endif`(環境裡的 `GO_PKG_TAGS` 不算,§16.21) | §4.1.2 |
| build gate | firmware `scripts/check-prov-test-gate.sh <rootfs> [<wbox-name>]`,`build-board.sh` 第 7 步 | §4.1.3 |
| `-wbox` 變體 | `build-board.sh --wbox <name>` | §4.2 |
| mutant 補丁 + 見證 | Batman `tests/wbox/<name>.patch`:檔頭 `# wbox <name>: <一句話>` + `# wbox-witness: WBOX-<name>-<8 hex>`;`.go` hunk 的見證必須在被引用的字串字面值內;shell / init 可用註解 | §4.2 |
| provd 測試傳輸(P2) | frame socket、`SOCK_ONLY`、三開關 | §4.8.3 |

### 2.2 harness(本 PR)
| 元件 | 說明 |
|---|---|
| `scripts/dv/prov-254.sh` | `pr_begin` / `pr_end` / `pr_abort`、`pr_normalise`、`pr_ota_b`、`pr_find`、`pr_lease_renew`、`pr_restore`、`pr_brewrite <node>`、`pr_needs_person`、canary;每單位一支 `scripts/dv/prov-<unit>-254.sh` |
| `scripts/node/prov-base-254.sh` | 既有 + `lock-hold`、`strip-p5-prov`、`state-set`、`dm-arm` / `dm-cancel`(重用 `dm_arm` / `$ST/dm`,`dm-fire` 讀 `lease-prov`)、`restoring set|clear`、`normalising set|clear`(p6) |
| `scripts/node/prov-wbox-254.sh` | `bind` / `unbind-all` / `list` / `arm-killpoint` / `push-helper` / `upper-helper` / `set-provd-env`(§4.5) |
| `scripts/node/prov-sock-254.sh`、`prov-sec-254.sh` | tier A(§4.5) |
| `scripts/node/prov-p1-254.sh` | 既有 + 標記斷言 |
| `scripts/node/ble-periph-254.sh` | `cmd_adv_on`:先 `adv_instances` = 0 且 provd 未 running,再 `rm-adv`;`acquire` 看到有效 `lease-prov` → FAIL |
| `scripts/node/ble-lib-254.sh` | `lease_*` 參數化檔名(`$BT/lease` / `$BT/lease-prov`);`dm_arm` 第 4 參數 = lease 檔 |
| `tests/tools/provclient/` | + `net-apply`、`leave`、`owner-add` / `owner-remove`、`diag`、`sock-as`、`exec`、`proxy`(§4.6) |
| `tests/tools/provgen.py` | §4.6 |
| `tests/prov-p1/sbx/`、`tests/prov-p1/gate/` | §4.4 |
| `tests/tools/peer/` | `peer.py`、`transport_sock.py`、`transport_ble.py`;`verify.py` 改 `def main()` + `load_vectors()` |
| `scripts/dv-dbus-tools.sh` | 複製**寫死 a72 路徑** `build_dir/target-aarch64_cortex-a72_musl/dbus-1.14.10/tools/.libs/dbus-send`(同名檔也在 a53 樹;`tools/dbus-send` 是 bash wrapper)+ 斷言 ELF magic `7f454c46` **與** e_machine `b700`(aarch64,同 `scripts/lib/ble-254.sh:44-45`,v5 B-m5)+ SHA256SUMS |
| `scripts/dv-prov-tools.sh` | 主機端從 §4.2 的「helper 變體」payload 抽 helper(`tar -xzf` → `unsquashfs -cat <file> usr/bin/batman-provhelper`)到 `~/batman-dv-tools/prov-test/<ver>/<name>/` + SHA256SUMS;對其餘變體只斷言 helper sha = release(v5 A-m1) |
| `tests/prov-p1/eeprom-hooks.sh` | §6.2 |
| CI | `vectors-219` + `peer.py --selftest` + `provgen.py --selftest`;`prov-sandbox`(arm64,E-H3 前 `continue-on-error` + 最後一步 `::warning::` annotation,PR body 貼結論);`prov-unit-gate`;`prov-p1`:**Go 單元改以 root 跑**(放在該 job 的**最後一步**,免得 root 擁有的 go cache 讓後續非 root 步驟 EACCES,v5 B-m7):`G=$(mktemp -d); sudo -E env PATH="$PATH" GOCACHE="$G" GOFLAGS=-mod=vendor GOTOOLCHAIN=local go test -v -tags prov_test ./... 2>&1 | tee go-test.log; test "${PIPESTATUS[0]}" = 0; [ "$(grep -c -- '--- SKIP' go-test.log || true)" = 0 ]`(runner 的 sudo `secure_path` 會重設 PATH;`PIPESTATUS[0]` 保住 `go test` 的退出碼,否則管線只回最後一段;SKIP 計數讀同一次的存檔輸出;v4 A-m7 / B-m1、v5 A-m4)(F20);負對照:故意 FAIL 一個單元 → job 紅;killpoint Go 單元;`prov-gate-stubs`;`known-failures-format` |
| lint | `lint-install`;`lint-wbox`(§4.2);`ab-shared-change.yml` 加 P1b 共用檔;**tmp-trust**(F30、F23):第 13 行收緊 `/tmp/run/batman-dv([^-a-z]\|$)`;**`chain1-254.sh` 自己定 `PCD=/tmp/run/batman-dvpc.$RUN`**(chain1 不 source `prov-lib-254.sh`:prov-lib 在 source 時就 `exec > >(tee)`、設 `RUN`、要求 `DV_PROV_TOOLS` / `DV_CRYPTPROBE`,chain1 有自己的 `pc` / `FIP` / `$RUN`,v5 B-m3),`:315` 改 `mkdir -m 0711 $PCD`(無 `-p`,EEXIST 即拒;每次開機只上傳一次,tmpfs 重開即清,不會撞)、`:112` 用 `$PCD`(本 PR 的 harness 修正,v4 B-M2);新條目:`scripts/dv/prov-lib-254.sh` **與** `scripts/dv/chain1-254.sh` 的 `/tmp/run/batman-dvpc\.`(root 0711、`mkdir` 無 `-p`)、`scripts/dv/prov-254.sh` + `scripts/dv/prov-*-254.sh` + `scripts/node/prov-wbox-254.sh` + **`scripts/node/prov-base-254.sh`(prov deadman 的 `rm -rf`)+ `scripts/dv-preflight.sh`(P9 的存在檢查)** 的 `/tmp/run/batman-prov-test([^-a-z]|$)`、`/tmp/run/batman-provd-test([^-a-z]|$)`、`/tmp/run/batman-dv/wbox/`(root 0700 / provd 0700,`mkdir` 非 `-p`);**`scripts/node/prov-sec-254.sh` 的 `ln -s /tmp/x /tmp/run/batman-prov` 是攻擊模擬,比照 `tmp-trust-280.sh`(allowlist `:53`)加一條專屬條目並寫理由**(v5 B-m2:每缺一條 = harness PR 的 tmp-trust 紅燈);**allowlist 檔裡寫 `|`,本文表格的 `\|` 只是 markdown 跳脫**;`feed/batman-prov/src/*`:第 99 行收緊 `/tmp/run/batman-prov([^-a-z]\|$)`(與第 13 行同形,否則 `batman-provd-test` 仍被切掉,v4 B-m13)+ killpoint 目錄與 provd 測試 socket 目錄條目;`test-tmp-trust.sh` 加兩案例:`scripts/dv/x.sh` 含 `/tmp/run/batman-dvpc-evil` → UNTRUSTED;**乾淨樹(含改過的 chain1)→ 0 UNTRUSTED**;`rundir-paths.txt` 不改 |
| known-failures | 第 4 欄 `expires=YYYY-MM-DD`;缺欄 / 壞格式 → run FAIL;過期 → NEW;`NEVER_KNOWN` 加 `\|NEEDS-PERSON\|blocked: DNODE`;`test-known-failures.sh` 四案例;移除 F26 7 行;新增 `pre-P1b` / `pre-P2` 條目(到期 = 產品 PR 預計 merge + 14 天) |

## 3. 擁有權

延續 h1 §3 與 p1-impl §3;每列一個寫者:

| 資源 | 唯一擁有者 | 唯讀者 / 例外 |
|---|---|---|
| `/tmp/run/batman-prov-test/`(root 0700)、`killpoint`、`provd.env`(root 0600) | `prov-wbox-254.sh` 寫;helper(`prov_test`)讀 `killpoint` 完就刪;provd init(`prov_test`)讀 `provd.env`;整個目錄由 `pr_end` / `pr_abort` / prov deadman / P9 restore 指令 `rm -rf` | release 不讀 |
| helper 記憶體內 killpoint arm | helper;解除 = restart(`unbind-all` 看 `wbox.list` 的 `armed <name>`) | P9:helper 本次 pid 的 log 無 `killpoint .*: armed` |
| `/tmp/run/batman-provd-test/`(provd:provd 0700)、`gatt.sock`(provd 0600) | provd init(root)`mkdir` + `chown 471:471` + `chmod 0700`;provd `O_NOFOLLOW` 驗 owner=471、非 symlink 才 bind;在 P2 ujail mount 清單 | `provclient sock-as 471 -- proxy`(owner → 進得去);release 沒有 |
| bind mount(`/tmp/run/batman-dv/wbox/<run>/`,root 0700) | `prov-wbox-254.sh bind` / `unbind-all`;deadman 還原 | 重開消失;P9 |
| A 槽 upper 的 `/usr/bin/batman-provhelper` 副本(`upper-helper`) | `prov-wbox-254.sh upper-helper` 放(**在任何 bind 之前**);`overlay-restore` 刪多出(F6:04 upper 無 `usr/bin/`);**prov deadman 也清**:`/overlay/upper/usr/bin/batman-provhelper` 存在且 sha ≠ `/rom/usr/bin/batman-provhelper` → `rm` + restart helper(只動 harness 自己放的檔,v4 A-m2)| P9 標記 grep |
| p6 `ble-ok` | helper health(只在 committed 槽,F14);**harness `state-set` 只在 helper 停止狀態或 trial 內寫**((8) 臂 B / C);restore 由 `STATEFILES` 放回 | autocommit 每次 poll 讀 |
| B 槽 | 單位期間:產品 `sysupgrade -n`(**一律 hold**;預期 REVERT 單位另等 `TRIAL-REVERTED`);收尾:`pr_brewrite`(單位寫過 B,或 B 現在 ≠ V) | P9:**committed 槽**含 wbox → FAIL;另一槽含 wbox → 印 restore 指令 |
| `bad-slot`(p6) | autocommit 寫;刪:產品任何 COMMITTED,或 harness 在預期 REVERT 單位且內容 = `slot=B version=<wbox ver>` 時(在 `pr_restore` 之前) | brewrite 前置;P9(印內容;`slot=A version=V` 註明可能是 normalise 殘骸) |
| `autocommit-hold-commit`(p6) | 四個 harness 寫者都在 prov lease 內;autocommit 消費 | P3 |
| B 槽 overlay `/etc/rc.local`(ch1 deadman 行) | 鏈 1 寫 / brewrite 清 | P9 |
| `-wbox` payload(`~/out/<VER>/ekh-bcm2711/`) | firmware build 寫;`prov-254.sh` 驗、推 | 只進非 committed 槽 |
| firmware `feeds/batman` 工作樹 | `build-board.sh --wbox` 套 / 還原(`checkout -- . && clean -fdx`) | gate |
| prov lease `$BT/lease-prov`(`<run> <boot> <expiry>`) | 取得者;取得 / 延長 / 釋放都在 `$BT/lock` flock 內,**延長 = `lease_write` + 重新 `dm_arm`**(F22);到期由 prov deadman 刪;chain1 / brewrite / pty-commit / `pr_normalise` 也取 | BLE `acquire` 看到有效 `lease-prov` → FAIL,反之亦然;**單位內互斥 = lease(重開前)+ p6 `dv-prov-dirty`(跨重開,snap 寫)+ p6 `dv-prov-normalising`(正規化期間)**;每次 `pr_find` 找到節點後**先重新 stage**(`ble-lib-254.sh` + `prov-base-254.sh` 到 `$DVD/<run>/`,root 0700;`dm_arm` 的第 3 參數要是節點上的檔,`$BT/lock` / `$ST` 在 tmpfs,v4 A-m12 / B-m9)再 acquire + `dm_arm`(剩餘預算) |
| prov deadman(`$ST/dm`,共用) | `dm_arm <run> <secs> prov-base-254.sh lease-prov`;`dm-fire`:讀 `lease-prov`;動作:`unbind-all`(含 armed → restart helper)、`rm -rf /tmp/run/batman-prov-test`、有 `restoring` 標記時到此為止;否則啟動 joinwatch / openmanetd / tailscaled;留 dirty;不碰槽 / p5 | 與 ch1 deadman 不同時 armed(P9) |
| `restoring`(`$DVD/restoring.<run>`,tmpfs) | `pr_restore` 開始建;`finish` 刪;**只活到 restore 內的 `reboot committed`**;之後若 harness 死,只剩 dirty(可接受:p5 / overlay 已寫回,compare 待下次) | deadman |
| `dv-prov-normalising <run> <boot>`(p6) | `pr_normalise` 開始寫、完成刪 | P9:存在 → FAIL「正規化進行中 / 殘骸」+ 清法 |
| S0 | `pr_restore`;通過才 `finish` | P9 |
| `NEEDS-PERSON` | `pr_needs_person` 寫 `$DIR/needs-person.txt`、`DNODE_BLOCKED=1`;`suite()`:之後 `kind=D` 且 `$cmd`(已展開)含 `$DNODE0` 的 IP 的 suite 印 `FAIL blocked: DNODE needs a person (<step>)` 不執行 | 報告 |
| 測試金鑰 `~/.batman-dv/prov-keys/<run_id>/` | `pr_begin` 產;`pr_end` 刪;`pr_abort` / `pr_needs_person` 保留並寫進通知 | — |
| 沙箱內一切 | `dv-sbx.sh` | 宿主:負測試 |
| 04 廣播(P2 後) | provd;harness `adv-on` 只在 provd 停止時 | 02 |

## 4. 契約

### 4.1 接縫(產品)

#### 4.1.1 killpoint 檔(只在 `prov_test` build;**沒有 CLI 旗標**,helper daemon 啟動時讀檔)
- 點名封閉:`txn-1`(`prov-txn` + `.txn` 寫完、setkey 前)、`txn-2`(setkey 後、`--prov-only` 前)、`txn-3`(`--prov-only` rc 0 後、overlay rename 前)、`txn-4`(rename 後、`--save` 前)、`txn-5`(`--save` 後、回應前)、`claim-after-persist`、`claim-before-shadow`。
- 檔案 `/tmp/run/batman-prov-test/killpoint`:目錄 root 0700 非 symlink;檔 root 0600 非 symlink link 1(細則與讀法見 §16.6);不符 → log `killpoint: refused (<why>)`;讀完刪;成功 → `killpoint <name>: armed`。
- 到點:log `killpoint <name>: sysrq reboot` → `echo b > /proc/sysrq-trigger`(F29:不看 mask;無 sync)。保險:`sleep 2` 仍活著(寫入失敗,例如 `/proc` 唯讀)→ log `killpoint <name>: fallback reboot -f` → `sync` → `reboot -f`。L7 的判定見 §16.1(`sysrq reboot` 行不預期送達主機)。
- 注入成立四證據:`armed` 行、檔已刪、boot_id 改變、狀態停在該點。
- release:`seam.Arm` / `seam.At` 是空函式;二進位無 `killpoint`、無點名、無標記(gate 檢查,§16.8)。
- 測試(CI,root):Go 單元(`-tags prov_test`,temp dir;`sudo -E go test`,F20):0777 / symlink / link 2 / 非 root 擁有 → refused;正確 → armed + 刪;release no-op;mutant 拿掉 link count → FAIL;**skip = FAIL**(job 斷言無 `--- SKIP`)。

#### 4.1.2 `prov_test` build(封閉清單)
- `BATMAN_PROV_TEST=1` → `GO_PKG_TAGS:=prov_test`(helper;P2 加 provd);否則 `GO_PKG_TAGS:=`(§16.21)。
- 額外行為全部:(1) killpoint 檔;(2) `--version` 第 2 行 + `--boot` 第一行 log 標記;(3)(P2)provd frame socket;(4)(P2)**provd 的 init 測試版**(`batman-provd.init.test`,Makefile 在 `BATMAN_PROV_TEST=1` 時安裝它取代 release init;release init 沒有讀 `provd.env` 的那段;gate 的 `grep -rl` 另加 init 內字串 `BATMAN_PROVD_TEST_INIT_7f3a`,v4 B-m6)讀 `provd.env`:`SOCK_ONLY`、`FAST_FAKE_DELAY_MS`、`NO_BRUTE_LIMIT`、**`GATT_ENCRYPT_CTRL`**(§4.8.3)。沒有 mutant 開關、沒有 fakeSys 模式。
- 標記字串只在 tag build 的檔案;release 二進位 `grep -c` = 0。

#### 4.1.3 build gate(`check-prov-test-gate.sh <rootfs> [<wbox-name>]`,第 7 步 `$WR/r`)
- 無 name:helper `go version -m` 的 `-tags` 不含 `prov_test`;`grep -c BATMAN_PROV_TEST_BUILD_7f3a` = 0;`/etc/batman-build` 無 `BATMAN_WBOX=`;rootfs 內 wbox 見證集合為空(格式 `WBOX-<name>-<8 hex>`,讀不到的檔 = FAIL,§16.8);helper 不得是 symlink、無點名(§16.10、§16.15)。
- 有 name:`BATMAN_WBOX=<name>` 行在;VER 含 `.dirty.wbox-<name>`;見證:rootfs 內的見證集合恰為本變體那一個(§16.8);`test` 的見證集合為空(§16.8、§16.26);**帶 `prov_test` 的 helper 另斷言 killpoint 實作真的編進去:`strings <helper> | grep -c 'killpoint .*: armed'` ≥ 1**(release = 0,與 §4.1.1「release log 無 `killpoint`」同一字串;擋住實作檔誤命名為 `_test.go` 的情況,v5 B-M1);`go version -m` 無輸出(shell 取代)→ 只以見證判;**init 類 mutant(`chan`)另斷言 `etc/rc.d/S??wbox-*` 存在**(OpenWrt image build 由 postinst `enable`,v4 A-m11)。
- 負對照(CI `prov-gate-stubs`):`prov_test` helper → FAIL;release → PASS;含 `WBOX-` 的假 rootfs → FAIL;**有 name = `test` 但 helper 以「實作放 `_test.go`」的 mutant 編出(無 `armed` 字串)→ FAIL**。

### 4.2 `-wbox` 變體(firmware `build-board.sh --wbox <name>`)
- 輸入:`feeds/batman/tests/wbox/<name>.patch`;`test` 無 patch(只 `BATMAN_PROV_TEST=1`)。**tag 規則(v5 B-m10:以 patch 內容判,`lint-wbox` 驗)**:**patch 碰 `feed/batman-prov/src/` 的變體(= helper 變體)與 `test` 一律帶 `prov_test`**;其餘 release tag。`helper-exit1` 以 shell 取代二進位、patch 只碰 Makefile 與 `files/`,屬 release tag 但 helper sha ≠ release;因此「helper sha ≠ release」的集合 = helper 變體 + `test` + `helper-exit1`,其餘變體的 helper sha = release(v5 A-m1)。表的 tag 欄是這條規則的結果。
- 步驟:第 1–2 步(含 `-i`)→ apply patch → `export BATMAN_WBOX=<name>`(+ `BATMAN_PROV_TEST`)→ 第 3 步 lock → 第 4 步 stamp(`BATMAN_WBOX` 有值 → `DIRTY=1` 強制;VER = `…+$F7.fw$W7.dirty.wbox-<name>`;`BATMAN_WBOX=<name>` 行;`check-board-patches.sh` 照跑)→ `logs/wbox-<board>.stamp`(`<name>|<PROV_TEST>`)與這次不同 → `make package/batman-prov/clean package/batman-provision/clean` → 第 5–10 步 → trap:`git -C feeds/batman checkout -- . && git -C feeds/batman clean -fdx`、寫 stamp。
- 正常 build:同 stamp 機制;gate 三條擋殘留。
- 輸出 `~/out/<VER>/ekh-bcm2711/`。
- **只進非 committed 槽;一律 hold**;P9:committed 槽 `.protected` 缺或含 `wbox`、`/etc/batman-build` 含 `wbox` → run FAIL;另一槽含 `wbox` → 印 restore 指令(brewrite)。
- 版本與見證斷言(`pr_ota_b`,全在主機端,F6、F44):驗 SHA256SUMS → `tar -xzf <payload> -C <mktemp -d> root.squashfs` → `unsquashfs -cat <file> etc/batman-build` 讀兩行(**`unsquashfs` 不吃 stdin**)→ `unsquashfs -cat` 見證所在檔 grep 見證 → 推上節點後節點端 `sha256sum` = 主機 sha → 才 `sysupgrade -n`。**hold 旗標的值 = `etc/batman-build` 裡 `BATMAN_VERSION=` 右側的值**(不含前綴;與節點 `sed -n 's/^BATMAN_VERSION=//p' /etc/batman-build` 逐位元組相等;`pr_ota_b` 推送前以 `cmp` 斷言;autocommit `:271` 以 `want == $(version)` 判,既有 harness `brewrite` / `chain1` / `pty-commit` 也寫值,v5 A-m6)。不符 → `HOLD-COMMIT-DISCARDED` 並刪旗標(另寫 `$RUNDIR/autocommit.hold-discarded`,harness 直接 poll 這個檔);member 臂 NEED_MESH=0 時 3×10 s 就 commit,`pr_find` 找到 trial 要 60–90 s,追不上。所以:DISCARDED 出現 → 先 `batman-slot is-trial`:**仍 trial → `back_to_a`;已 committed(mutant 槽)→ `pr_needs_person`**(印 `batman-slot rollback` 指令,不自動回槽,因 deadman 不碰槽);不「重試一次」。前面的 `cmp` 斷言讓這條路徑只在 harness 自己的 bug 時發生。
- `helper-exit1`:patch 改 `feed/batman-prov/Makefile` install(`GoPackage/Package/Install/Bin` → `INSTALL_BIN ./files/wbox-helper-exit1.sh`)+ 新增該檔(含見證)。
- **uci-defaults / init 類 mutant 的檔名規則**:uci-defaults 新檔一律 `99zz-wbox-<name>`(排在 `99zz-batman-prov-state` 之後,免被 96 的 overrides 寫回覆蓋);**只在 fresh overlay 第一次開機執行**(uci-defaults 執行後自刪),單位不得拿同一 B trial 做第二次開機;`lint-wbox` 驗檔名前綴。
- `chan`(v4 重寫,F15):**不是 uci-defaults**,是 `files/etc/init.d/wbox-chan`(START=99,`start()` 背景化一個迴圈;image 內要有 `etc/rc.d/S99wbox-chan`):等 `iw dev wlh0 info` 成立 → 從此每 5 s 讀 `uci get wireless.radio1.channel`,≠ 目標值(p5 值以外的合法頻道)就 `uci set` + commit + `wifi reload`,**持續 ≥ 200 s**(> chanfix 最長 80 + 6×8 s)後 exit;log `wbox-chan: asserted <ch> (<n> times)`(見證字串在這行);chanfix 的 `gave up reasserting` 行若出現 = 旁證,不當判定;mutant + chanfix 合計 ≤ 13 次 `wifi reload`,`health_ok` 看 `wpad running`,不受影響。trial 內前置斷言(v4 A-m10 / B-m10:mutant 與 chanfix 交替期間單次取樣可能剛好相等)= 「T+120 s 起連續 3 次(間隔 10 s)`uci get wireless.radio1.channel` 皆 ≠ p5 值 **且** `batctl n` 空」,不成立 → FAIL「mutant 無效」+ `back_to_a`(hold 擋 commit)。`wifi reload` 對 morse 真的換頻道只有 chanfix 自己的註解當證據 → E-H7 必做。
- 變體清單(18;`misc-*` 四個算四個):

| name | mutant | tag | 用在 |
|---|---|---|---|
| `test` | 無 | prov_test | killpoint 單位 helper 來源 |
| `rc9-unclaimed` | helper `--boot` rc 9 → `prov{unclaimed}` | prov_test | legacy-upgrade 負對照 |
| `96-noprov` | 96 `PCOPY=none` | — | prov-ota 負對照 |
| `helper-exit1` | helper = `exit 1` shell | — | lock-failsecure 正向 |
| `helper-norebuild`(取代 v3 `helper-nogen`,F41;2026-10-30 依 wireless-txn 改) | `--boot` 不以 p5 重建 overlay(`ovRec == nil` 回 `unknown(norebuild)`,F41)**且** Finish 的 `resolve()` 也不重建(否則開機 Finish 會補建,負對照不可能失敗);舊的 `.txn` 世代分支已不存在 | prov_test | overlay-corrupt、powerloss txn-3 負對照 |
| `96-norestore` | 96 + helper 不從 p5 還原 | prov_test | overlay-wipe 負對照 |
| `helper-nojoinop` | `net.apply` 首版不要 owner-op | prov_test | netjoin 負對照 |
| `helper-noleave` | leave 不刪 p6 標記(leave 本身照樣忘網路) | prov_test | leave-ota 負對照 |
| `helper-notrial` | 不看 `IsTrial` | prov_test | trial-busy 負對照 |
| `helper-clientchal` | 採用 client 的 ClientChal | prov_test | prov-claim 負對照 |
| `helper-notxn` | 開機時把未完成的 `.txn` 刪掉、不 Finish(wireless-txn §3 的反面) | prov_test | powerloss txn-2 負對照(neg-b) |
| `helper-noforget` | `ForgetMesh` 什麼都不做、回成功(leave 與 Finish 都不忘網路) | prov_test | powerloss-rejoin 負對照 |
| `helper-alwaysforget` | 入網失敗一律「忘記」,不還原 `.txn` 快照(操作員的設定)(review B r5 m5) | prov_test | powerloss-legacyjoin 負對照 |
| `helper-skipapply` | Finish 把任何狀態都當 already、從不重套(wireless-txn §15.4,review B MAJOR-3) | prov_test | powerloss txn-2 neg-skip |
| `radio1-off` | `99zz-wbox-radio1-off`:`radio1.disabled=1` | — | autocommit (1) |
| `chan` | init `wbox-chan`(上) | — | autocommit (7) 04 側(= (4)) |
| `helper-flap` | helper 在 `serving` 後 5 s `os.Exit(1)`(procd respawn) | prov_test(碰 `src/`) | autocommit (9) |
| `misc-L38` / `misc-L42` / `misc-L43` / `misc-L51` | §6.2 | 依規則(碰 `src/` → prov_test) | prov-misc |

- 成本:22 build / rc(none + test + 20 變體,2026-10-30 v8 起);E-H2 量兩次 × 18 寫 §7.3;只在 rc 發版與動到 prov 的 PR 時 build;E-H2 驗收:「helper sha ≠ release」集合(上段規則)內的 helper sha 互異且 ≠ release,**且帶 `prov_test` 者 `strings` 含 `killpoint .*: armed`**(§4.1.3);其餘變體 = release helper sha。P9 與 `dv-prov-tools.sh` 的 helper 份數照同一集合(由 `lint-wbox` 從 patch 內容算出,寫進 `tests/wbox/helpers.list`,不在文件寫死數字)。
- `lint-wbox`:對 Batman `feed/` 做 `git apply --check`(板 patch 的目標全在 `feeds/openmanet` / `feeds/packages`,不碰 `feeds/batman`,v4 B-m15 → 不需先套板 patch);至少改一個 `feed/` 檔(`test` 例外);見證 ≥ 2 次且 `.go` hunk 的見證在 `"…"` 內;§6.2 引用的 name 都存在;tag 欄與表一致;uci-defaults 新檔名前綴 `99zz-wbox-`。

### 4.3 主機端 `prov-254.sh`(Git Bash;簽章與 COSE 在 WSL)
沿用 p1-impl §4.2–§4.5。

- **單位骨架**:`pr_begin <unit> <secs> [helper=<variant>]` = P9 子集(S0 槽條件、無 dirty / bind / wbox / killpoint 目錄 / normalising、02 在 `batctl n`)→ lease(**初值 3000 s**)+ `dm_arm` → `snap`(寫 dirty)→(`upper-helper` → `push-helper`)→ 步驟 → `pr_end`:
  1. 預期 REVERT 單位:等 `TRIAL-REVERTED`(**上限 = trial 內讀到的 `$RUNDIR/autocommit.deadline` + `DEFER_MAX` 600 + 120 s**,不寫死;看到 `revert deferred:` 行就 `pr_lease_renew +600`,F42、v4 A-M2;若反而 `HELD` → FAIL「mutant 無效」+ `back_to_a`;**逾時但 boot-reasons 顯示 panic / watchdog 硬重開(trial 內 panic → tryboot 一次性 → 直接回 A,無 `TRIAL-REVERTED`、無 bad-slot)→ 判 INVALID「trial panic」而非「mutant 無效」**,v4 B-m12)→ `pr_find` 04 在 A committed → **先**讀 / 印 / 斷言 / 刪 `bad-slot`(`slot=B version=<wbox ver>`;不符 → `pr_needs_person`);
  2. `pr_restore`(前 `pr_lease_renew +1800` + `restoring`)→ compare diffs=0;
  3. `pr_brewrite 04` 只在「單位寫過 B」或「B 的 `.protected` ≠ V」;否則斷言 `.protected` = V 且 mtime 未變;
  4. `finish` → `rm -rf /tmp/run/batman-prov-test` → lease release → `dm_cancel` → 02 在 `batctl n`(180 s 窗)、02 boot_id 前後相同((7) 與 `prov-netjoin-fleet` 例外:02 回 A committed、`badslot=[]`、在 `batctl n`;**單位超過 3600 s 時 02 可能被 joinwatch 重開(F33):02 重開但回 `batctl n` 且 A committed → WARN 不 FAIL**,同 chain1,v4 A-m13)。
  任一步失敗 → `pr_abort`(restore;再失敗 → `pr_needs_person`)。
- **lease 規則**:每次 `pr_ota_b` 落點後 `pr_lease_renew +900`;每次 `pr_find` 找到節點(= 重開後 tmpfs 清空)**重新 acquire + `dm_arm`**(剩餘預算);`pr_restore` 前 `+1800`;renew = `lease_write` + `dm_arm`(同一把 flock)。
- **`pr_normalise`**(prov 區塊開頭;自己 acquire lease **1800 s** + `dm_arm`,寫 p6 `dv-prov-normalising`):04 committed = A、版本 V、無 wbox、無 bad-slot → **no-op**;04 committed = B、版本 V、無 wbox、無 bad-slot、**且 02 在 `batctl n`**(04 legacy + p6 `mesh-joined` → A trial `NEED_MESH=1`,02 不在就 600 s revert 成 `bad-slot slot=A version=V`,v4 A-m6)→ 在 B 寫 hold = V → `sysupgrade -n` 進 A → 落點後 renew +900 → HELD → `release --wait` → A committed → 刪 normalising → 之後 snap。其他不符 → `pr_needs_person`。白箱:04 留 B committed → 第一單位 PASS;正規化中殺主機 → 下次 P9 FAIL 印清法。
- **全套順序**:prov 區塊在 2f 之後、2g 之前。區塊內:`pr_normalise` → `prov-base` → (1)(7-04) revert 型 → hold 型 → killpoint 型 → 鏈 0 → `prov-netjoin-fleet` → (7) → `prov-legacy-upgrade`。
- **member → OTA 的通則**(F33):`net-apply` 之後、`sysupgrade -n` 之前一律 `batman-slot reboot committed`;trial 內斷言 `:420` 行 + `mesh join required: 0 (prov=member mesh_expect=<m> radio_required=1)`。
- `pr_ota_b <payload> <sha> <target-slot> [allow-stale]`:一律寫 hold;落點斷言(DT tryboot=1、目標槽、`HOLD-COMMIT` 生效、無 DISCARDED);落空 → disarm、清 hold、重試一次 → `pr_needs_person`。
- 還原 F / R / 跨槽(同 p1-impl §4.5.2,R = F);`pr_brewrite <node>` docker 等待依角色。
- **secrets / canary**:同 p1-impl §4.2;金鑰 `~/.batman-dv/prov-keys/<run_id>/`;`pr_end` 刪並斷言,`pr_abort` 保留;canary 掃主機 log、`logread`、p6 `*.log`、run dir。
- `NEEDS-PERSON`:印行、檔、`DNODE_BLOCKED=1`、return 1;`NEVER_KNOWN` 含它。

### 4.4 `dv-sbx.sh`(CI `ubuntu-24.04-arm`,root)
契約 = p1-impl §4.10。步驟:(1) 宿主:底 rootfs 取得(§4.4.1)→ `unsquashfs` 到 `$SBX/root` → 依 `feed/batman-provision/Makefile` install 規則蓋 PR 的 `files/`(`lint-install` 保證每檔有 install 行)→ helper 以 `setup-go`(SHA 釘)`-tags prov_test` arm64 原生 build → `losetup -f --show $SBX/p5.img`(拒絕已掛載 / 支撐 `/overlay` 的裝置);(2) `unshare --mount --pid --fork --net --uts --ipc --propagation private -- sh setup.sh`:`mount -t proc proc $SBX/root/proc`、`/proc/sys` 與 `/proc/sysrq-trigger` ro bind、`/sys` 不掛、`/dev` tmpfs + `mknod null/zero/urandom` + `mknod mmcblk0p5 b <loop major> <minor>`、`kmsg` regular file、`/opt/batdata` / `/tmp` / `/tmp/run` tmpfs、`/proc/cmdline` bind 假檔、無 `/proc/device-tree`、stub `vcmailbox` / `reboot` / `wifi` / `ubus` 在 PATH 前(記錄到 `/tmp/run/sbx-calls.log`);(3) `capsh --drop=cap_sys_boot,cap_sys_module,cap_sys_time,cap_sys_rawio,cap_mknod -- -c "chroot $SBX/root /bin/sh case.sh"`。
- `prov-unit-sbx` 負測試(job 開頭,任一不成立 → job FAIL):`reboot -f` → runner boot_id 不變;`mknod` runner 真實磁碟 → EPERM;`ip link add dummy0` 成功但宿主 `ip link` 無(netns);`ip link set eth0 down` → 找不到;`echo x > /proc/sys/kernel/hostname` → 失敗;`echo x > /dev/kmsg` → 宿主 `dmesg` 無。
- 案例 `tests/prov-p1/sbx/cases/<name>.sh`(p1-impl §5.1 逐條)+ `--mutant`(必 FAIL)。
- `prov-unit-gate` 獨立:`tests/prov-p1/gate/`,loop GPT 卡 + 假 DT + `/boot/autoboot.txt`,對 `batman-slot` 跑 `.seeded` × `prov.meta` × state;mutant 放行 claimed;wsl.9 `batman-slot`。
- CI:`timeout-minutes` 不計排隊;E-H3 前 `continue-on-error` + `::warning::`。
- `prov-artifact-match`(WSL,rc 時手動):F34 整串旗標(E-H4 照 `make V=s` 記);不可重現 → 明列。

#### 4.4.1 底 rootfs 的來源(D-H11,v4 B-M1)
- `tests/prov-p1/sbx/base.env`:`BASE_VER`、`BASE_URL`、`BASE_SHA256`。
- 來源 = **Batman repo 的 release asset**(F18:payload 不在 firmware repo;`1.5.14-wsl.4` 沒有資產):本 PR 時 = `v1.5.11` 的 `batman-1.5.11-rel.1+6a049f2.fw7049fd8-ekh-bcm2711-ab-payload.tar.gz`,sha 釘該 release `SHA256SUMS` 的那行;公開,直接 `curl`;sha 不符 → job FAIL。沙箱只用它的 busybox / uci / 基底,P1 的 `files/` 由 PR 蓋上、helper 現編,所以 rel.1 當底可用(底與 fleet 版本的 busybox / uci 差異由 `prov-artifact-match` 的工具 sha 比對列出,E-H4)。
- 之後每次發 rc / release 都上傳 payload 資產(本來就是發版流程的一步)並 bump `base.env`。無 PAT、無 secret。

### 4.5 節點端新增
- `prov-base-254.sh`:`lock-hold`、`strip-p5-prov`、`state-set`、`dm-arm` / `dm-cancel`、`restoring`、`normalising`。
- `prov-wbox-254.sh`:
  - `bind <name> <dst>`、`unbind-all`(umount、`armed` → restart helper、`rm -rf /tmp/run/batman-prov-test`)、`list`;
  - `upper-helper <variant> <sha>`:`cp` helper 到 `/usr/bin/batman-provhelper`(落 upper,撐過重開;restore 清);**必須在任何 bind 之前**;觀察點 = 重開後;
  - `push-helper <variant> <sha> [killpoint=<name>]`:先寫 killpoint 檔 → bind helper → **一次** restart → 斷言 `--version` 第 2 行標記、`/proc/<pid>/exe` sha、`killpoint <name>: armed`(本次 pid)→ `wbox.list` 記 `armed`;觀察點 = 重開前;restart 跑 `boot.Run`(F8);
  - `arm-killpoint <name>`(單獨);`set-provd-env <k=v…>`(P2):寫 `provd.env` → **restart provd**(init 只在 start 讀,§4.8.3)→ 斷言 provd 本次 pid 的 `/proc/<pid>/environ` 含所設的值(v5 B-m6)。
- **負對照通則**:重開前 → bind;需要 helper 重跑開機邏輯但不重開 → `restart`;重開後 → `upper-helper`;trial 內不能改狀態(F9)、不能重開(tryboot 一次性)→ trial 內只能 restart 類。§6.2 每個負對照標 [bind / restart / upper / wbox-B]。
- `prov-sock-254.sh`(tier A):`sock-as 471 -- info` 正確;`sock-as 65534` → EACCES;`sock-as 65534 --gid 471` → provclient 印 `CONN-CLOSED`,helper log 前綴 `connection refused: peer uid 65534 (want 471)`;未知動詞 → `E_SCHEMA`(20)。PEERCRED 負對照在 Go 單元(root 跑,F20)。
- `prov-sec-254.sh`(tier A):`prov-sec-helper-uid-254`;`prov-sec-key-perms-254`(bind 0644 副本 → FAIL);`prov-sec-dvpc-254`(機制在 `pl_prep` 已有:`mkdir -m 0711` 無 `-p`,F23;**chain1 的固定名 `mkdir -p` 在本 PR 改成 chain1 自己的 per-run `PCD=/tmp/run/batman-dvpc.$RUN` + 無 `-p`**(§2.2);本 PR 加明確訊息 `FAIL dvpc dir pre-exists` 從 `mkdir` rc 判 + 白箱:root 預建 symlink → FAIL,對 `pl_prep` 與 chain1 各做一次);**`prov-sec-sockdir-254`**(lease 內白箱:停 helper → root 以 `ln -s /tmp/x /tmp/run/batman-prov` 或 `chown 471` 預建 → 啟 helper → log `sock: … refusing to start`、socket 不存在 → 還原 → 啟 helper 正常)。

### 4.6 `provclient` 擴充與 `provgen.py`
- `net-apply`、`leave`、`owner-add` / `owner-remove`、`diag`、`sock-as <uid> [--gid g] -- <op>`、`exec <argv…>`(降權後 `execve`,清 env、無 stdin)、`proxy`(stdin/stdout ↔ 指定 socket,一行 hex = 一個 packet)。
- `provgen.py`:`netcfg` / `members` / `secrets` / `chain` / `invite`;金鑰 PEM;`--selftest` 依 F19 scalar 規則重算 `d` → PEM → 逐位元組重現 `cose.net_config` / `member_list` / `net_secrets`。

### 4.7 preflight P9(每條有 `test-dv-preflight.sh` 負對照)
- committed 槽 `.protected` 缺或含 `wbox`、`/etc/batman-build` 含 `wbox` → FAIL;另一槽含 `wbox` → FAIL + 印 brewrite 指令。
- helper `grep -c BATMAN_PROV_TEST_BUILD_7f3a` ≠ 0 → FAIL。
- `dv-prov-dirty` 不同 run → FAIL + restore 指令;`dv-prov-normalising` → FAIL + 清法。
- bind 殘留、`/tmp/run/batman-prov-test/` 存在、helper log `killpoint .*: armed`(本次 pid)→ FAIL。
- ch1 deadman 殘留;`bad-slot` 存在 → FAIL(印內容與清法)。
- helper state;`--destructive`:WSL 工具、`provgen.py --selftest`、`prov-test` helper 依 `tests/wbox/helpers.list`(§4.2 規則)的 sha、`-wbox` payload 18 份、`dbus-send` ELF(magic + aarch64);chain1 兩槽 = V;pre-P1b 偵測(`--version` rc);`kernel.sysrq` 只記錄(F29,不當 FAIL 條件);**04 的 p6 `autocommit.timeout` 存在且 > 600 → 印出**(它改變所有 revert 型單位的預算,F42);H3:`peer.py --selftest`、bleak、WinRT radio On、provd release 無測試 socket 目錄。

### 4.8 `peer.py`(H3)
#### 4.8.1 角色與裁判
- 手機角色與攻擊者角色。Noise 用 `noiseprotocol`(與 `gen.py` 同、與 `verify.py` 的 `dissononce` 異);CBOR `cbor2` + `det_dumps`、CDDL `pycddl`、ES256 `python-ecdsa` 從 `verify.py` import(改 `def main()` + `load_vectors()`,模組層無 I/O)。
- 裁判:(1) 向量(`verify.py`);(2) `peer.py` ↔ provd(Go `flynn/noise`)互打。`peer.py --selftest` 對 `gen.py` 的交握 transcript 逐位元組(金鑰注入同 F19)。CI 負對照:import 後 `main()` checks ≥ 195;`peer.py --selftest` 刪一個比對 → FAIL。

#### 4.8.2 傳輸契約(§4.1 frame 層)
- `transport_sock.py`:`SOCK_SEQPACKET`;一 packet = 一 frame(`flags(1) ‖ seq(2 BE) ‖ data`);`max_frame` 244;重組 / 中止與 BLE 相同。
- 控制包 `0xC0`(讀 `CTRL`)/ `0xC1`(讀 `STATUS`):長度 1,只在交握完成前;之後收到 → 中止;長度 < 3 且不是這兩個值 → 中止。
- **一條 sock 連線 = 一條 BLE 連線**:219 §8 全部計數器同樣適用;**P2 契約(回 219 §10):假第 2 則送出後 peer 斷線 → 立即釋放連線槽**(BLE 斷線本來如此,sock 比照)。
- socket `/tmp/run/batman-provd-test/gatt.sock`;harness 經 `provclient sock-as 471 -- proxy`。
- `transport_ble.py`:`bleak`;E-H1 驗 WinRT 後端是否把 scan response 的 service data 併進 `AdvertisementData`。

#### 4.8.3 P2 要開的 `prov_test` 開關(`provd.env`)
- 寫者 `prov-wbox-254.sh set-provd-env`(root 0600、非 symlink、link 1,在 `/tmp/run/batman-prov-test/`);讀者 provd init(只 `prov_test`)以 `procd_set_param env` 傳;缺檔 / 壞檔 → 不設;非 root 建不了。
- `SOCK_ONLY=1`(不碰 dbus / bluetoothd);`FAST_FAKE_DELAY_MS=<n>`;`NO_BRUTE_LIMIT=1`;**`GATT_ENCRYPT_CTRL=1`**(provd 把 `CTRL` 特徵宣告成 `encrypt-read`;`prov-gatt-254` 的負對照,v4 B-M3)。
- CI `peer-vs-provd`:`useradd -u 471 provd`;helper `sudo` root 跑真 `realSys`,`batman-slot` / `batman-config-save` / `halow-setkey` / `prov_apply_lock` PATH stub;provd `sudo -u provd` + `SOCK_ONLY=1`。**runner 上要預建的目錄與 stub 清單(`/tmp/run/batman` 0700、`/etc/batman-prov/`、`/opt/batdata/state`、p5 不存在時 `boot.Run` 走新卡路徑的處理)在 P2 設計定**(乙部,v5 B-m9)。

### 4.9 服務 UUID(Q1)與廣播預算
- 自訂 128-bit(核准時 `uuidgen` 一次,寫進 219 §4.1 與常數);特徵 base+1…+4。
- 預算:ADV 31 B = Flags 3 + 128-bit UUID 列表 18 = 21 → 剩 10;B16 service data 放 scan response(128-bit Service Data 頭 18 B → payload ≤ 13 B;nonce 8 + 旗標 1 可放)。iOS 合併 scan response(⚠️ P2 實機驗);nonce > 12 B 則改 16-bit(要申請)。

### 4.10 BLE 空中(H3)
- 主 central = Windows `bleak`(F17 radio 目前 Off;E-H1 量 RSSI);02 = 攻擊者 central;`prov-sec-bond` 翻轉段與 `ble-rpa` N1 在 provd 停止模式做。

## 5. 生命週期矩陣

| 路徑 | 本 PR 之後 | 證明 |
|---|---|---|
| install / first run(harness 新主機) | Windows `pyble` venv、WSL venv + `provgen.py`、`-wbox` payload 18、`prov-test` helper(`tests/wbox/helpers.list`)、`dbus-send`;P9 逐項,缺 = FAIL | `test-dv-preflight.sh` 每缺項一個負對照 |
| start(prov 區塊) | `pr_normalise`(lease 1800 + `dm_arm` + p6 normalising) | 白箱:04 留 B committed → 第一單位 PASS |
| harness 死於 `pr_normalise` 的 A trial 中 | 600 s revert → `bad-slot slot=A version=V` → 04 回 B committed;無快照;p6 normalising 留著 → 下次 P9 FAIL 印清法 → 需人 | 白箱 |
| start / clean stop(單位) | `pr_begin` / `pr_end` | 每單位 |
| harness 死(wbox trial 中,一律 hold) | mutant 有效 → 期限 revert → bad-slot → dirty → P9 FAIL + restore 指令(含 bad-slot 段);mutant 無效 → `HELD` 到期 revert → 同上 | 白箱 |
| harness 死(V hold trial 中) | 期限 revert → 同上 | 白箱 |
| 誤 commit(產品 bug)後 harness 死 | deadman 不碰槽;P9「committed 含 wbox」FAIL;需人 | 白箱(`state-set` 模擬 `.protected`) |
| `HOLD-COMMIT-DISCARDED` 且 trial 已 commit(mutant 槽) | `pr_needs_person` 印 `batman-slot rollback` 指令;不自動回槽(§4.2) | 白箱:故意寫錯 hold 值(帶前綴) → 斷言 `cmp` 先擋下;繞過 `cmp` 的 harness 自測 → `pr_needs_person` |
| harness 死於 restore 途中(dd / overlay-restore) | `restoring` → deadman 只 unbind + helper restart,不起 joinwatch;lease 已 +1800 | 白箱 |
| harness 死於 restore 的 `reboot committed` 之後、compare 之前 | `restoring` / lease / deadman 已隨重開消失;只剩 dirty;下次同 run_id 接手 compare(p5 / overlay 已寫回) | 白箱 |
| harness 死(節點不重開,一般) | prov deadman:unbind、armed → restart helper、刪 prov-test 目錄、起 joinwatch / openmanetd / tailscaled;dirty 留 | 白箱 |
| harness 死(節點已重開) | bind / killpoint 目錄 / 記憶體 arm / lease / deadman 隨 tmpfs 消失;dirty 接手 | 白箱 |
| killpoint 已 arm、harness 死在觸發前 | `unbind-all` / deadman 看 `wbox.list armed` → restart;P9 看 log | 白箱 |
| 單位內重開(≥ 5 次 / hold 型) | 每次 `pr_find` 後重新 acquire + `dm_arm`;跨重開互斥 = p6 dirty / normalising | 白箱:重開期間第二個 `pr_begin` → P9 子集撞 dirty |
| 兩個 harness | 節點 lease + p6 標記;chain1 / brewrite / pty-commit / normalise 都 acquire | 白箱 |
| 產品自己的重開(joinwatch 3600 / autocommit 期限) | 單位 ≤ 3000 s + renew;§7.3 | 表 |
| upgrade(fleet → 含接縫 rc) | 接縫 release no-op;tier B 在 rc PASS | rc 全套 |
| rollback(fleet 回 wsl.4) | 需接縫的單位印一行 `FAIL pre-P1b image: <ver> (helper has no --version)`(KNOWN,有到期) | wsl.4 負對照 run |
| `prov_test` build 被 pin / 手動 make | gate、P9 + tier A 標記、`--version` 第 2 行 | gate 負對照;tier A 白箱 |
| downgrade(04 → wsl.9) | `prov-downgrade` | 單位 |
| crash loop(helper) | procd 固定 5 s respawn;`prov-misc` L11、(9) | 單位 |
| 斷電 | sysrq `b` 五個 txn 點;真斷電 §9 | 單位 |
| 主機 ↔ 04 eth 斷 | `NEEDS-PERSON`(10 分鐘);deadman 到期還原 bind / helper | 白箱:`nft` 暫擋 |
| 依賴重啟 | `prov-misc` helper 側;H3 provd 側 | 單位 |
| CI arm64 / 底 rootfs | 排隊不計;底 sha 不符 → FAIL;E-H3 前不擋 PR(annotation) | PR CI |
| 02 在 `prov-netjoin-fleet` 認領後還原失敗 | 02 LOCKED、擁有者 = run 金鑰;金鑰保留;無 OOB → 需人 | §7.2 |
| harness 死於 `prov-netjoin-fleet` 中(02 已認領 + 入測試網,還原未開始) | 02 LOCKED、member 於測試網;joinwatch 3600 s 重開不會改回(p5 已寫);02 的 p6 dirty(02 snap 寫)→ 下次 P9 FAIL;金鑰保留;需人 | 白箱 |
| trial 內節點 kernel panic / 硬重開(#132 Morse churn) | tryboot 一次性 → 直接回 A committed:無 `TRIAL-REVERTED`、無 bad-slot、hold 旗標已消費;`pr_end` 以 boot-reasons 判 INVALID「trial panic」,重跑一次,不歸因為 mutant 無效 | 白箱(`echo c > /proc/sysrq-trigger` 在 trial 內) |
| P2 後 provd 擁有廣播 | `adv-on` 先查 | 白箱 |

## 6. 測項

每個測項:輸入、判定(確切字串 / 碼 → 檔:行)、負對照(標 [bind / restart / upper / wbox-B])、副作用、型別(hold+revert | hold | — / 最終槽 / F|R)。

### 6.1 CI(無硬體)
| 測項 | 判定 | 負對照 |
|---|---|---|
| `prov-p1-stubs`(擴) | Go 單元以 root 跑(§2.2 CI 那一整串,`PIPESTATUS` + 存檔後數 SKIP),無 SKIP;killpoint 單元(§4.1.1;`seam` 套件與 `node/seam_points_test.go`,§16.3);release no-op | mutant 拿掉 link count;非 root 跑 → SKIP → job FAIL(自測);故意 FAIL 一個單元 → job 紅(管線退出碼自測) |
| `prov-gate-stubs` | §4.1.3 四種輸入 | 內建(含「實作放 `_test.go`」mutant → FAIL) |
| `lint-install`、`lint-wbox` | §2.2、§4.2 | 刪 install 行 / 空 patch / 見證 1 次 / 引用不存在 / tag 不符表 / 檔名前綴錯 → FAIL |
| `prov-sandbox`(arm64) | §4.4 負測試 → §5.1 案例 | 每案例 `--mutant` |
| `prov-unit-gate`(amd64) | §4.4 | wsl.9 `batman-slot`;mutant 放行 claimed |
| `vectors-219`(擴) | + `verify.py` import 後 ≥ 195;`peer.py --selftest`;`provgen.py --selftest` | 既有 + 刪一個 check |
| `known-failures-format` | 4 欄;到期 = NEW;缺欄 = FAIL;`NEVER_KNOWN` 行 | 四案例 |
| `tmp-trust`(既有 lint,擴) | 新條目生效;**乾淨樹(含改過的 chain1、新的 `prov-base` / `prov-sec` / `dv-preflight` 行)→ 0 UNTRUSTED** | `scripts/dv/x.sh` 含 `/tmp/run/batman-dvpc-evil` → UNTRUSTED |
| `peer-vs-provd`(H3,amd64) | §4.8.3 | `provd.env` 開關 + 向量負向 |

### 6.2 節點(甲部;04 = DNODE 除非註明)
**tier A(每天,唯讀)**:
| 測項 | 判定 | 負對照(PR 證據階段,lease 內) |
|---|---|---|
| `prov-boot-254` | p1-impl §5.2 全部 + helper 無標記字串 + `--version` 第 2 行不存在(P1b 後) | 停 helper > 60 s → stale;`privacy off` → `privacy=0`;`batman-sc` pid 不符 → `sc_file=0`;`ble-ok` 的 distroconfig bind → 不寫;bind test helper → 標記 FAIL |
| `prov-sock-254` | §4.5 | Go 單元(root) |
| `prov-sec-helper-uid-254`、`prov-sec-key-perms-254`、`prov-sec-dvpc-254`、`prov-sec-sockdir-254` | §4.5 | 各自白箱 |

**tier B**(每單位 `pr_end` 規則見 §4.3):
| 單位 | 程序與判定 | 負對照 | 型 |
|---|---|---|---|
| `prov-base-254` | snap → 改 p5 一檔 / overlay 一檔 / p6 一 state / 刪 lower `/etc/banner` → restore → S0(banner 回來);restore 的 dd 期間主機送 sysrq → 重跑 restore → S0;3 次 `prov-boot` | `PROV_BASE_SKIP=p5\|extra` → compare FAIL | — / A / F |
| `prov-legacy-upgrade-254`(L17) | 釘住 wsl.9(`DV_OLD_PAYLOAD` + sha)hold 進 B → release → B commit → `strip-p5-prov` → **正向**:V hold 進 A → trial 內 helper `boot rc=9 verdict=legacy` → release → A commit → AP key / lock-status / authorized_keys / mesh-expected 前後相同 → **負對照(正向之後)**:`-wbox rc9-unclaimed` hold 進 B → B trial `boot rc=9 verdict=unclaimed` → `back_to_a` → `strip-p5-prov` + 斷言 p5 無 `.seeded` / prov.meta(mutant 可能 seed)→ restore(p5-restore 本來就會蓋回) | [wbox-B] | hold→commit / A / R;B 最後 = wbox → brewrite |
| `prov-claim-254` | 既有 + killpoint 段(`push-helper test killpoint=claim-after-persist` → claim → sysrq → replay 同 `owner_tag_key`)+ 空 `authorized_keys`(同一 ssh 批次 bind) | `helper-clientchal` [bind] → 攻擊者 ClientChal 被接受 | — / A / F |
| `prov-netjoin-254` | `net-apply --first` → `code=0`、state=member、wireless == prov.net、overrides == prov、`rm=1`、setkey 警告 | `helper-nojoinop` [bind] → 無 owner-op 的 `--first` code=0 | — / A / F |
| `prov-netjoin-fleet-254` | **02 先 snap**;02 `claim.verify`(F38;lab key,`pk_proof`)→ fleet 值經 fd 3:04 join → 入網(`batctl n` 有 02)→ 02 join → 入網;**還原順序:02 先**(p5-restore + overlay-restore + 重開 → 回 `batctl n`),再 04 F | — | — / A / F(02 F;§7.2) |
| `prov-leave-ota-254`(L22;L22-A:leave = 忘網路) | member → leave → 標記刪 + **網路忘掉**(placeholder、radio1 封鎖、無 wlh0、mesh_expect 0、`--check` rc 0)→ 重開 → OTA V hold → B trial `claimed`、`mesh join required: 0 (prov=claimed mesh_expect=0` | `helper-noleave` [bind] → 標記留 → `mesh join required: 1` | hold / A / F |
| `prov-ota-254`(L5) | member → 重開 → OTA V hold → B:`:420` 行、`mesh join required: 0 (prov=member`、member、gen 同、wireless 同、上鎖、`.batman-prov-restore` `prov=full`、96 `prov: state=member copied=full` | `-wbox 96-noprov` [wbox-B] → `copied=none` | hold / A / F |
| `prov-lock-failsecure-254` | `push-helper test killpoint=claim-before-shadow` → claim → sysrq → 重開後(F37)`lock-status=LOCKED`、root 欄 = 注入前、p5 無 `shadow-root` → OTA `-wbox helper-exit1` hold → B:`offered` 只 publickey、LOCKED | 同前置 → OTA wsl.9 hold → UNPROVISIONED(F32) | hold / A / F |
| `prov-powerloss-254-txn{1..5}`(L7;2026-10-30 依 wireless-txn §3/§8 改判) | `push-helper test killpoint=txn-N` → `net-apply --update` → sysrq → 重開(release helper)→ helper 在 serving **之前** Finish:txn-1 `… wireless = the committed network, already, save rc=0`、mesh id = 舊值;txn-2 **白箱注入**(helper init 先停、重開後寫半套 uci、再起 helper;v8 §15 / review B MAJOR-3)→ `… the committed network, applied …`、mesh id = 舊值、p5 gen 不前進;等 Finish 行(背景 Finish,§15.2)不等 serving;txn-3 `action=p5 newer: rebuilt the overlay record` + Finish、overlay gen = p5 gen、mesh id = 新值;txn-4 Finish 存檔、p5 gen n+1(F39 由 `--save --txn` 收掉);txn-5 無 Finish;**每一點**:`.txn` 不在、uci 與 live(wpa_supplicant ssid)mesh id 對、`--check` rc 0、之後一次 `--save` rc 0(出貨版的卡死 = 整個單位的負對照,wsl.9 上 04 重現兩次,#254 留言 6469943996) | txn-2 neg-skip:`helper-skipapply` [bind,注入後起] → 注入的 mesh id 留著(正向判定在它上面會失敗);txn-2 neg-b:`helper-notxn` [upper] → 見證行、無 Finish 行;txn-3 neg:`helper-norebuild` [upper] → 無重建行、overlay gen ≠ p5 gen;舊 neg-a(120 s 延遲還原的競態)已無對象 → 刪 | — / A / F |
| `prov-powerloss-legacyjoin-254`(wireless-txn §8) | S0 legacy(操作員的網)→ claim → **停用 helper init** + sync → killpoint txn-2 `net-apply --first` → sysrq → 重開(helper 不起)→ 前置:`.txn` 在 → **白箱注入**半套 wireless 進 uci(sysrq 不 sync,setkey 的 uci 寫入會掉 — M6 實測;不注入則 Finish 無事可做、兩臂都無鑑別力)→ 起 release helper → `finished (boot): wireless = the pre-change snapshot`、key(sha 前綴,不印)/ uci / live mesh id = 操作員的、`.txn` 不在、`--check` rc 0、`--save` rc 0、02 回到鄰居 | `helper-alwaysforget` [bind,注入後起] → 見證行、key = placeholder | — / A / F |
| `prov-powerloss-rejoin-254`(wireless-txn §5/§8) | claim + join → **leave**(真機第一次 `--forget-mesh`:placeholder、radio1 `disabled=1` 且在 keyguard mark、無 wlh0、mesh_expect 0、`--check` rc 0)→ 停用 helper init → killpoint txn-2 `net-apply --first` → sysrq → **白箱注入**半套 wireless(隨機 key、新 mesh id、radio 解封)→ 起 release helper → `finished (boot): wireless = left (forgotten)`、再次全部忘掉、`.txn` 不在、`--check`/`--save` rc 0 | `helper-noforget` [bind,注入後起] → 見證行、注入的 key 留著 | — / A / F |
| `prov-netupdate-254`(L25、L26) | bind `halow-setkey` `exit 1` + `--on-join` → p5 overrides 不前進;`killpoint=txn-3` + `--on-join` + sysrq → member | bind 不讓路的 config-save [bind] → p5 overrides 前進 | — / A / F |
| `prov-trial-busy-254`(L21) | OTA V hold → B trial `claim` → `E_BUSY`(7) | `helper-notrial` [bind 在 B trial + restart] → 被接受 | hold / A / F |
| `prov-overlay-corrupt-254`(L33) | 寫垃圾進 A `prov.cbor` → 重開 → `overlay record unusable:` + 以 p5 重建、gen 相等 | `helper-norebuild` [wbox-B hold 進 B → B 內寫垃圾 → restart](不重開)→ 不重建 | — / A / F |
| `prov-overlay-wipe-254`(L60) | 清 upper → 重開 → state、`device_id` 不變 | `-wbox 96-norestore` [wbox-B] | — / A / R |
| `prov-downgrade-254`(L12) | claimed → OTA wsl.9 hold → 還原、LOCKED、`ttylogin=1`、p5 prov 檔不刪(characterization) | — | hold / A / F |
| `prov-downgrade-left-254`(wireless-txn §2/§8) | 臂 1:claim(無 key 12)→ OTA 上一版 P1(wsl.9)hold → 舊 helper verdict `claimed` → back;臂 2:join + leave(`Left` 進 p5)→ OTA wsl.9 hold → 舊 helper `unknown(prov-corrupt)`(fail-closed)、LOCKED、p5 不變 → back → 新 helper 讀回 `claimed` | 臂 1 即臂 2 的對照(同一舊 image、同一 claimed 紀錄、只差 key 12) | hold / A / F |
| `prov-forget-orphan-254`(wireless-txn §19.3/§19.6,白箱、確定性) | 手工重建 §19.1 的孤兒(radio 照 forget 的方式關掉 → 同名 mesh netdev 建回 morse phy、寫進 netifd 的 /var/state splist、起 root `wpa_supplicant_s1g`;沒建成 = INVALID)→ 臂 1:`--forget-mesh` → 升級處置(kill s1g by /proc exe+Uid、`iw dev del`)→ rc 0、log「forgotten after escalation」、netdev/行程消失 → setkey 把節點自己的網路設回(key 從節點 uci 走 stdin)→ rc 0、netifd up/not pending、meshjoin_radio_up、02 180 s 內回鄰居(= netifd 下一次 setup 容忍 splist 裡被刪的名字);臂 2(`prov-forget-orphan-noforget-254` = 同腳本 `noforget`,獨立一輪 snapshot/restore,只記錄):同一孤兒不 forget,只 setkey 重建 → netifd 自己會不會清 | wsl.15 同臂 1 → forget rc 3(無升級處置) | — / A / F |
| `prov-leave-after-join-254`(wireless-txn §19.1/§19.6,黑箱、真機重現) | 舊 image 進 B(hold)→ back_to_a → claim → join 測試 mesh → 立刻 leave,節點上 1 Hz sampler + logread;PASS = leave code 0 + radio 確認關(placeholder、disabled+mark、無 mesh netdev、netifd down+disabled、`--check` rc 0)**且時間窗有開**(join 期間 pending 連續 ≥3 樣本 且 setkey log `read-back: netifd up after n s` n≥3);沒開 → INVALID(非 PASS),換一次 B-rollback 重開再試,最多 3 次;FAIL 為終局 | wsl.15 = 4/5 FAIL(code 21 → 22,孤兒 wlh0 在空中) | hold / A / F |
| 鏈 0(L15) | p1-impl §5.4:apply V 進 B + cmdline `batman_bypass=1`(hold)→ 受控重開 → `none` 登入 → `unknown(bypass)`、不產身分、persist 拒、96 exit 1 → `back_to_a` | 無 bypass → 正常 | hold / A / F(兩個 lease) |
| autocommit (1) | `-wbox radio1-off` **hold** 進 B → `TRIAL-REVERTED … reason=` 含 `mesh not joined/reachable` 或 `member: HaLow mesh interface not up`(F12 `why` 表);`HELD` 反而出現 → FAIL「mutant 無效」+ `back_to_a`;bad-slot 順序 §4.3 | 本身 | hold+revert / A |
| (3) | member → 重開 → OTA V hold → `:420` 行 + `mesh join required: 0` + `is healthy and HELD` | 與 (6) 互為對照 | hold / A |
| (6)(取代 (5)) | **前置:04 = member(只有 `member:*` 分支讀 `ota-armed.mesh`,`:416-421`)**;兩臂:(6a) `sysupgrade -T` 後直接 `batman-slot apply`(無 `ota-armed.mesh`)→ `member: no usable ota-armed.mesh — neighbours required (fail-closed)` + `mesh join required: 1`;(6b) 手寫**不等於本次開機**的 boot_id 的 `ota-armed.mesh` 後直接 apply → 無 `no usable` 行、`mesh join required: 1`;兩臂 `otalog AC UNHEALTHY first_why=` 行**含** `mesh not joined/reachable` → 480 s 內 `back_to_a` | 與 (3) 互為對照 | hold + back_to_a / A |
| (7)(含 (4)) | 04 在 A 在 mesh;02 hold OTA V 進 B → `HELD` → 02 `back_to_a`;→ 04 `-wbox chan` **hold** 進 B → 前置(**§4.2 的三次取樣規則**:T+120 s 起連續 3 次、間隔 10 s,頻道皆 ≠ p5 且 `batctl n` 空;不成立 → FAIL「mutant 無效」+ `back_to_a`,v5 A-m2)→ `TRIAL-REVERTED`、otalog `S1 ARMED-MESH … m=joined`;02 全程 committed A | — | 02 hold+back / 04 hold+revert / 兩台 A |
| (8) | P1 期三臂(F12 latch、F14):臂 A `ble-ok` 在 → 本次開機有一行 `WARN ble:`(括號內容只記錄)+ HELD;臂 B `ble-ok` 不在(**停 helper → `state-set ble-ok absent` → 保持停到 `sysupgrade -n` 送出**;trial 不寫回)→ 無 WARN 行 + HELD;臂 C(`hci0_powered=0` 分支):**同臂 B 的移除程序(停 helper → `state-set ble-ok absent` → 保持停到 `sysupgrade -n` 送出**,否則 committed 槽的 helper 15 s 內寫回,v4 B-m3)→ trial 內 `btmgmt power off` → 等一個 health tick(≤ 15 s)讀到 `hci0_powered=0` → `state-set ble-ok` 放回(trial 不寫回)→ 下一次 poll 印 `WARN … hci0_powered=0 …` + HELD | 三臂互為對照 | hold / A |
| (9) | `-wbox helper-flap` hold,04 有 `ble-ok`:health 不 stale(F14)→ **WARN 行與 `is healthy and HELD` 取自真 main 的 `logread`**(內容只記錄)→ **同一 trial 內背景跑 `AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1 AUTOCOMMIT_TIMEOUT=<uptime+120> batman-autocommit run`,180 s 後 kill(同 chain1 8.7 的寫法 `chain1-254.sh:347`)→ 斷言其 stdout 含 `DRYRUN decision: COMMIT slot B (services 3x10s, mesh samples <n>)`(F42;決定 COMMIT 要 NEED=3 輪 × 10 s + pre-commit canary `docker run`,所以 +120 不是 +60,v5 B-m1)→ `back_to_a`**;dry-run 的 latch 已被真 main 用掉,不會再印 WARN(v5 A-m5),判定不從 dry-run 找 WARN;不真 commit mutant 槽(v4 A-M1);**characterization**(L39 本意 = provd flap → §6.3) | — | hold / A |
| (10)(L41) | 三個偽造 caller:(a) 非 root `sysupgrade -T`;(b) 主機 root 以非 procd 父程序直接呼叫 `platform_check_image`(`:81` 讀 `/proc/$PPID/cmdline`,**這是有鑑別力的偽造臂**);(c) 容器 root:`docker run --rm -v /lib/upgrade:/lib/upgrade:ro -v /opt/batdata:/opt/batdata -v /tmp/run:/tmp/run busybox sh -c '. /lib/upgrade/platform.sh; …'`(容器內 uid 0、pid ns ≠ host;**OTS 容器本身沒有這些 bind(F35),所以這臂是 characterization**,v4 A-m14 / B-m8)→ 三臂皆 p6 無 `ota-armed.mesh`、無 `otalog S1 ARMED-MESH`;真 OTA(hold)→ 檔在、三欄格式、`ARMED-MESH` 行 | — | 偽造臂 — / 真 OTA hold / A / F |
| `prov-misc-254` | 見 §17(L38 / L42 / L43 / L51 / L11 / L9 / L10 / L27 / L3) | 見 §17 | — / A / F |
| `prov-verbs-254` | p1-impl §5.6 正向含 `settings.set hostname` → 6(`rename-pending`)、未知 key → 20、`owner.*`、`ssh_keys.set`、`diag.bundle`、`qr` | 沙箱 | — / A / F |
| `prov-eeprom-hooks-254` | 對解出的 rc rootfs:shim 對所有 key `READ` rc 1;PATH 假 `vcgencmd` 回四個 key → 讀者不採用 | 1.5.12 rootfs → 採用 | WSL |

### 6.3 節點(乙部,H3;P2 rc 後)
| 單位 | 程序與判定(§8 對應列) | 負對照 | tier |
|---|---|---|---|
| `prov-firstboot-254`(provd 側) | 鏈 1 第 5 步加:B trial `STATUS` 經 BLE 可讀、`updating=1`、末 4 碼在、無 AP | 1.5.12 新卡 → 無廣播(重燒,手動) | 併鏈 1 |
| `prov-boot-254`(provd 側) | health `adv_registered_once=1`;provd uid 471、ujail;廣播有、無 Local Name;已認領不帶末碼;health 轉壞 → ≤ 10 s 撤廣播(白箱 bind `bondable=1` health 視圖);連線即撤、斷線後新 nonce 重註冊 | 停 provd → ≤ 10 s 無廣播 | A(白箱段 B) |
| `prov-respawn-254`(L8) | kill provd ×5 → procd 5 s respawn;provd 退避行 `provd: backoff <n>s` 遞增(P2 契約);`info.state` 不變 | — | A |
| `prov-dep-restart-254`(L9–L11) | bluetoothd / dbus / helper 各重啟 → provd 重註冊 ≤ 15 s;無 hci0 → `hci0_powered=0` | — | A |
| `prov-two-phones-254`(L24) | 兩個 `peer.py` 同時 `claim/finish` → 一個 0、一個 `E_BUSY`(7)(P2 需實作認領互斥,回 219 §10) | — | B |
| `prov-provd-dos-254`(L39) | OTA V hold;trial 期間反覆連線 + 超大訊息(§8:斷線)+ `kill` provd ×10 → `HELD` | — | B |
| `prov-ble-claim-254` | `peer.py` BLE:NX → claim → 密碼 → `psk_replay` → `claim/replay` 同 `owner_tag_key`;`killpoint=claim-after-persist` → sysrq → replay;10 次錯 response 後第 11 次 `E_RATE`(12),成功不計(F40) | 錯 `owner_pub` → 3;NX 對已認領 → 假第 2 則 | B |
| `prov-sec-claim-brute-254`(§8 3 次) | 同連線 3 次錯 → 斷;新連線再 3 次 → 斷;`claimed_counter` 不變 | `NO_BRUTE_LIMIT=1` → 4 次仍連著 | A(sock) |
| `prov-sec-hog-254` / `-oversize-254` | 3 條連線(2 sock + 1 BLE)→ 第 3 條被拒;不交握 10 s → 斷;交握後閒置 30 s → 斷;單則 > 8192 → 斷;分塊超 `max_msg` → 斷 | — | A/B |
| `prov-sec-psk-timing-254`(§3.4) | sock;節流 ≤ 18 / 分、兩臂交錯、錯臂並行 ≤ 2、`peer.py` 收到假 msg2 即斷(槽立即釋放,§4.8.2 契約);先量正確 PSK 延遲的 MAD;門檻 = max(2·MAD, 5 ms);**n = 30**(公式 n ≥ (1.96 · 1.2533 · √2 · 1.4826 · MAD / 門檻)² 在門檻 = 2·MAD 時 ≈ 6.6,恆被下限 30 綁住;n = 30 時中位數差 95% CI 半寬 ≈ 0.94·MAD < 門檻,夠用;MAD 極端(> 門檻 / 2 以外)才會超過 30,上限 200,v4 B-m5);PASS = 中位數差 < 門檻且 bootstrap 95% CI 在 ±門檻;明寫不驗「相同次數 DH」 | `FAST_FAKE_DELAY_MS=20` → 差 ≥ 20 ms | A |
| `prov-sec-dbus-254` | tier A:先證 root 能 `Introspect`(dbus-send 動態連結 OK);`provclient exec dbus-send …`(471)呼叫 `AgentManager1.RegisterAgent`、`Properties.Set Pairable`、`Device1.Pair` + 3 個未列 → AccessDenied;**471 的正向對照 = `Properties.Get`(stage1 §4.6 policy 放行的方法;`Introspect` 在 P2 後對 471 仍 AccessDenied,F16,不能當正向)**;root 對照只用無副作用方法(`Introspect`、`Properties.Get`);tier B(02 連著):`Device1.Disconnect` → 成功;bluetoothd → provd 回呼 → 成功;root `RegisterAgent` 正向只在 tier B 並立即 `UnregisterAgent` | root / 471 `Properties.Get` 對照 | A + B |
| `prov-sec-bond-254`(翻轉;provd 停止模式) | 停 provd → `adv-on` → 04 掛 agent(白箱常駐)→ 02 SC JW → 通過(外洩)→ 收 agent → 擋下 → `rekey` + 04 重開 → 起 provd | 本身 | B |
| `prov-coex-254`(L28) | AP 客戶端 = Windows 主機 Wi-Fi 連 04 AP;iperf 60 s 基線 → 同時 `peer.py` BLE 連續 `status` 60 s → 記差異 / 斷線數;第一輪記錄,第二輪起門檻 = 基線 − 30% | — | B |
| `ble-rpa-254`(provd 模式) | 三態(**stage1 F28** 時間條件:`mgmt.c:1016-1029` `rpa_expired()` 設 `HCI_RPA_EXPIRED` 後 `HCI_ADVERTISING` 未設即 return;不是本文的 F28):無重註冊 → 同 RPA;重註冊且距上次 RPA 改變 < 900 s → 同 RPA;≥ 900 s → 新 RPA;provd log `adv re-registered reason=<rpa_timeout\|connect\|disconnect\|health> nonce=<8hex>`(P2 契約)+ btmon 對齊;N1 = 停 provd + `adv-on` ≥ 30 分 | N1 / N2 / N5a | B |
| `prov-sock-254` → tier B | 停 provd 才跑 | 同 §4.5 | B |
| `prov-gatt-254` | **前置:04 無 agent**(`prov-sec-bond-254` 會在 04 掛 agent;固定排序 `prov-gatt` 在 `prov-sec-bond` 之前,且 P9 / 單位前置斷言 04 `AgentManager1` 無註冊,v5 B-m12);`peer.py` BLE:MTU、分段(1 B / 剛好 / 超過)、序號亂 → 斷、notify 回壓 100 則;**「特徵不帶加密旗標」以行為判(F43:client 端 `Flags` 永遠不含 `encrypt-*`)**:02 未配對、未加密下 `gatt.read` `CTRL` / `STATUS` 回資料、`gatt.write` `RX` 成功,btmon 整段無 `SMP` 交換、無 `LE Start Encryption` | 序號亂不斷 = FAIL;**白箱:`provd.env` `GATT_ENCRYPT_CTRL=1`(§4.8.3)→ 02 `gatt.read` CTRL 得 `org.bluez.Error.NotPermitted: Not paired`(`gatt-client.c:290`)且 btmon 序列 = SMP Pairing Request(02 發)→ Pairing Failed → ATT Error Response 0x0F,無 `LE Start Encryption`**(server 回 0x0F → 02 的 ATT 預設 `sec_level` AUTO 自動升級安全 → 04 無 agent 拒 → 重試一次後回 D-Bus 錯,`att.c:745-810`,v5 B-m11) | B |
| iPad GATT 回歸 | ⚠️ 手動:步驟文件 `docs/validation/ble-ipad.md` **由本 PR 乙部建立**(今天不存在,v5 B-m4),結果貼 PR | — | 手動 |

## 7. 安全

- **資產**:04 / 02 控制權與 S0、擁有者測試金鑰、fleet mesh key、root 密碼、IRK;runner 宿主。

| actor | 攻擊 | 擋法 | 負測試 |
|---|---|---|---|
| 本機非 root(節點) | 預建 `/tmp/run/batman-prov-test/` 或寫 killpoint / `provd.env` | root 0700 + 0600 + link 1 + 非 symlink;release 不讀 | Go 單元(root)+ 節點白箱(`nobody` 預建 → refused) |
| 本機非 root | 預建 helper socket 目錄 / symlink | `PrepareDir` 拒絕啟動(F11) | `prov-sec-sockdir-254` |
| 本機非 root | 碰 bind 副本 / `wbox.list` / dvpc 目錄 | root 0700 `/tmp/run/batman-dv/wbox/`;dvpc `mkdir` 無 `-p` | tmp-trust;`prov-sec-dvpc-254` |
| 本機非 root | 連 provd 測試 socket | 目錄 provd 0700、socket 0600;只在 `prov_test` | `sock-as 65534` → EACCES |
| 攻陷的 provd(P2) | 經測試 socket 對自己送請求;寫 `provd.env` | socket = BLE 入口,helper 不信 provd;`provd.env` 在 root 0700 目錄 | `peer-vs-provd` 負向;perm |
| OTS 容器 / tenant root | 碰 `/dev/log`、`/tmp/run`、`/opt/batdata/state`;偽造 sysupgrade caller | deploy/ots 無這些 bind(F35);stage 1 caller 判定(F33) | **autocommit (10)**(§6.2 L41) |
| 第二個操作員 / 另一 session | 同時跑 harness | 節點 lease + p6 dirty / normalising | 白箱 |
| 遠端 BLE 路人 | 對 `prov_test` 節點用開關 | env 只在節點本機 root 檔;release 無 | gate + strings |
| 供應鏈 | `-wbox` / `prov_test` image 混進出貨 | gate(第 7 步)、P9、tier A 標記;`.dirty.wbox` 在 VER | gate 負對照;tier A 白箱 |
| 我們自己 | 忘了還原 feeds/batman、stale helper、mutant 無效被 commit | trap 還原;stamp DIRTY;wbox stamp → clean;gate;**wbox trial 一律 hold** | E-H2 白箱;§6.2 (1)(7) 前置 |
| 我們自己 | 沙箱逃逸 | §4.4 負測試 | 內建 |
| 我們自己 | 金鑰外洩 / 02 留 LOCKED | WSL ext4 0600;每 run 換;`pr_abort` 保留金鑰;canary | canary = 0 |
| 我們自己 | 無人值守留壞狀態 | `NEEDS-PERSON` + DNODE 擋;deadman 不碰槽 / p5;restore 中不起 joinwatch;normalising 標記 | 白箱 ×4 |

- **privilege**:節點端腳本 root;provclient 降權後連 socket / exec;`dbus-send` 以 471;CI Go 單元以 root(有理由:chown 與檔案擁有權契約)。
- **secrets**:同 p1-impl §8;IRK 翻轉後作廢;`peer.py` PSK 只在記憶體。
- **failure mode**:P9 缺項 = FAIL;killpoint 檔不符 = 忽略;沙箱負測試不過 = job FAIL;`pr_find` 找不到 = `NEEDS-PERSON`;CI SKIP = FAIL。

### 7.2 副作用(新增)
| 動作 | 碰到 | 還原 | 斷言 |
|---|---|---|---|
| `prov-netjoin-fleet` | 02 snap、認領(LOCKED、密碼關、擁有者 = run 金鑰)、`wifi reload` | 02 先還原(經 mesh,無 OOB),再 04 | 02 回 legacy、`batctl n`;失敗 → 金鑰保留 + 需人 |
| (7) | 02 一次 held trial + `back_to_a` | 自身 | 02 A committed、無 bad-slot |
| (9) dry-run 在真 trial 內 | **§3「一資源一寫者」的已知破例**:dry-run 也寫 `$RUNDIR/autocommit.why`(真 main 與 `release --wait` 讀它)、`otalog_k AC START` / `AC UNHEALTHY`(p6 `ota-trace.log`,本次開機多一組)、pre-commit canary 失敗時 `rm -f` 共用的 canary latch、canary 舊 tag prune(`batman-autocommit:139-140,426,505,515,521-523`)(v5 A-m5 / B-m1) | 不還原;hold 擋 commit、`back_to_a` 收尾後 trial 消失 | `pr_end` 不以 otalog / `autocommit.why` 判 (9);(9) 只斷言 dry-run stdout 的 `DRYRUN decision: COMMIT` 與真 main 的 `HELD` |

### 7.3 成本(⚠️ 推估;E-H2 量後更新)
- hold 型:snap 1 + net-apply 2 + 重開 3 + OTA 3 + settle 1.5 + HELD ≤ 8 + 斷言 2 + back_to_a 3 + restore 5 + compare 1 + brewrite 14 ≈ 47 分;revert 型 ≈ 37 分 + 600 s(+ ≤ 600 s watchdog 延遲,F42);`—` 型 ≈ 20 分。
- 全套 ≈ 30 單位 + 8 個獨立 held-trial 負對照 × 15 分 ≈ **22–23 h**;04 OTS 中斷 ≈ 7.5 h;02 隔離約 3 h;SD 約 45 GiB。
- `-wbox` build 18 × ⚠️ ≈ 3 h / rc。

## 8. 工作順序與 PR
1. 本設計兩位審查到 0 BLOCKER / 0 MAJOR;§10 回報上層。
2. **實證**(先列副作用):
   - **E-H1**:使用者打開主機藍牙 → 04 lease 內 `adv-on` → 主機 `bleak` scan 看到、記 RSSI、驗 scan response 合併 → `adv-off`;04 `readelf -d`(`LD_TRACE_LOADED_OBJECTS=1`)`.libs/dbus-send` 只需 `libdbus-1.so.3` + musl;root `Introspect` 成功、uid 471 AccessDenied。副作用:04 廣播 ≤ 2 分。
   - **E-H2**:`build-board.sh --wbox test` 與 `--wbox rc9-unclaimed`;量時間;gate 反向;**`test` 的 helper `strings` 含 `killpoint .*: armed`、release 不含**(v5 B-M1);正常 build → gate PASS、helper sha ≠ 變體、樹乾淨;Ctrl-C → 樹乾淨;boot log 再確認 uci-defaults 順序(F15 已由原始碼證)。
   - **E-H3**:CI `ubuntu-24.04-arm` job(負測試 + v1.5.11 payload 下載與 sha + busybox ash);排隊時間。
   - **E-H4**:`prov-artifact-match`(F34 整串)。
   - **E-H5**:`lock-hold` + helper `--save` 撞鎖(= `prov-claim` 一單位)。
   - **E-H6**:04 `echo b > /proc/sysrq-trigger` 一次(S0 後)→ 重開、boot-reasons;證 F29。副作用:04 硬重開一次。
   - **E-H7**:`wbox-chan` init 在 04 的 B trial 跑一次(hold)→ 證 200 s 內 chanfix 放棄、頻道維持 mutant 值、不入網 → `back_to_a`。
3. PR-P1b(`feat/254-p1b-seams`)+ firmware `--wbox` / stamp / gate → rc `1.5.14-wsl.5` + 18 變體。
4. harness 實作;每單位先在 wsl.4 跑負對照(`pre-P1b` 行),兩台 OTA wsl.5 → 單位逐個 PASS → 全套。
5. harness PR 先 merge(紅燈 KNOWN,有到期)→ PR-P1b + firmware pin → 出貨 build 重跑全套。
6. 乙部與 P2 設計一起;H3 測項在 P2 rc 上 PASS 後再 PR(D-H5)。

## 9. 殘項(回 #254)
claim-lock §11.4 真機 tier B(4 / 4-inj / 4b / 4b' / 4c / 4d / 5)仍未排程(§1.2);真斷電;bcm2710 真機;iPad GATT 手動;`prov-rename`;opaque 目錄未查;L16 節點層;`prov_test` vs release 差異只靠 gate + tier A/B;release asset 掃描不做;`docs/validation` 文字;B16 nonce 長度;(5) 不可測;(9) P1 characterization;txn-1 / 4 / 5 無獨立負對照;**txn-4 後 overrides 要到下次入網才補(產品缺口)**;`prov-sock` PEERCRED 負對照只在 Go 單元;sock 傳輸的「假第 2 則後立即釋放槽」是 P2 契約。

## 10. 回報上層
1. p1-impl §4.5.3 同槽重建 = 鏈 1 程序;E4 作廢;§4.5.0 順序改為「2f 之後、2g 之前 + 正規化」。
2. p1-impl §2.2:`dv-sbx` shell;`-wbox` 真 build + 見證;known-failures 到期欄;放置負測試 = `prov-sec-dvpc-254`;socket 目錄預置 = `prov-sec-sockdir-254`。
3. stage1 §10:H3 = 本文;P2 設計要收 §4.8.2(sock = BLE 連線、控制包、**假第 2 則後立即釋放槽**)、§4.8.3(含 `GATT_ENCRYPT_CTRL` 白箱開關與 provd 測試版 init 的安裝機制)、§4.9、provd log 契約(`adv re-registered`、`backoff`)、ujail 多掛 `/tmp/run/batman-provd-test`、認領互斥 → `E_BUSY`;stage1 §8 A-N7「GATT 不帶加密旗標」的斷言改為行為判定(F43)。
4. 219 §4.1 / §8 / §12:Q1 定案;sock 計入 §8;釋放槽契約。
5. stage1 §6.4:(3) radio-only 前提 = 本次開機未 JOINED;(4) 併 (7);(5) 由 (6) 取代;(8) P1 期三臂;(9) L39 本意 provd flap;**txn-4 後 overrides 無補寫路徑**(產品缺口,#254 checklist)。
6. 不要求 P1b 加 txn log 行(F13 既有)。
7. CI Go 單元今天從未在 CI 跑過 root-gated 測試(F20)→ 本 PR 修。

## 11. 待決
| # | 題 | 建議 |
|---|---|---|
| D-H1 | `dv-sbx` shell / Go | shell |
| D-H2 | `-wbox` 真 build / 改寫 | 真 build |
| D-H3 | `peer.py` Noise 函式庫 | `noiseprotocol` |
| D-H4 | UUID | 128-bit + scan response |
| D-H5 | H3 同 PR 第二段 / 第二個 PR | 看 P2 時程 |
| D-H6 | coex 門檻 | 第一輪記錄 |
| D-H7 | 斷電代理 | sysrq `b` |
| D-H8 | 主機 bleak RSSI | E-H1 |
| D-H9 | txn-1 / txn-5 要不要測 | 要 |
| D-H10 | (9) 保留在甲部 | 保留為 characterization |
| D-H11 | 沙箱底 rootfs 來源 | **定案:Batman repo v1.5.11 release payload(§4.4.1)** |

## 12. v3 審查 → v4 對應
| 發現 | 處置 |
|---|---|
| A-M1 / B-M2 `chan` 賽跑、revert 無 hold | §1.4 / §4.2:wbox trial 一律 hold;`chan` 改 init 背景迴圈 ≥ 200 s + 見證 log;前置斷言;E-H7;(1)(7) 型別 hold+revert |
| A-M2 txn-3 / overlay-corrupt 負對照 | F41;`helper-norebuild` 取代 `helper-nogen` |
| A-M3 txn-2 (a) | 120 s 內 `mv` + restart(殺 goroutine) |
| A-M4 txn-4 | F39;判定改 `--check` rc 5 + gen;overrides 缺口回 #254 / §10 |
| A-M5 / B-M3 (8)(9) | 三臂重寫(A gate 有 / B 停 helper 移除 / C 移除→power off→放回);(9) characterization,WARN 只記錄 |
| A-M6 / B-M1 / B-M6 範圍 | (10) 恢復 L41;`prov-sec-sockdir-254`;(4) 併 (7) 明寫;§7 OTS 列指向 (10) |
| A-M7 lease / deadman | F22;§3:renew = `lease_write` + `dm_arm`;`dm-fire` 讀 `lease-prov`;互斥雙向;每次 `pr_find` 後重取;p6 normalising;`restoring` 生命週期明寫;§5 補列 |
| B-M4 CI 非 root | F20;§2.2 CI `sudo -E go test -tags prov_test`,SKIP = FAIL |
| B-M5 tmp-trust | F30 改寫;§2.2 條目重寫;測試案例 |
| A-m1 rundir-paths:97 | F33;§1.2 假殘項刪 |
| A-m2 (6) `first_why` 含 | §6.2 |
| A-m3 helper-flap 退出點 | §4.2:`serving` 後 5 s |
| A-m4 upper 先於 bind | §3、§4.5 |
| A-m5 只進 B 矛盾 | §4.2「只進非 committed 槽」;P9 分 committed / 另一槽;legacy-upgrade 負對照改到正向之後進 B |
| A-m6 fleet 還原順序 / 02 snap | §6.2 |
| A-m7 (6b) boot_id | §6.2 |
| A-m8 (1) hold | 同 A-M1 |
| A-m9 brewrite 條件 | §4.3 步驟 3「或 B ≠ V」 |
| A-m10 空區塊 / F29 行號 | 全文重寫;F29 |
| B-m1 F29 語意 | F29 改寫;fallback 當保險;P9 只記錄 |
| B-m2 tag 規則 | §4.2 以表為準,lint 驗 |
| B-m3 (4) | §1.2 |
| B-m4 timing n / 釋放槽 | §6.3 公式;§4.8.2 契約 |
| B-m5 legacy-upgrade 兩臂 | 負對照移到正向之後 + strip + 斷言 |
| B-m6 沙箱底來源 | §4.4.1、D-H11 |
| B-m7 dvpc 機制 | §4.5 |
| B-m8 字串尾巴 | F11 |
| B-m9 radio1-off 檔名 | §4.2 |
| B-m10 §7 殘文 | 重寫 |
| B-m11 normalise lease | 1800 + renew |
| B-m12 continue-on-error 可見 | §2.2 CI |
| B-m13 chan 只跑一次 | §4.2 uci-defaults 規則 |

## 13. v4 審查 → v5 對應
| 發現 | 處置 |
|---|---|
| A-M1 (9) commit mutant 槽 | §6.2 (9) 改 dry-run(F42);§7.2 / §7.3 刪 (9) 列 |
| A-M2 revert 等待未計 `DEFER_MAX` | F42;§4.3 步驟 1 上限 = deadline + 600 + 120、`revert deferred` → renew +600;P9 印 `autocommit.timeout`;§7.3 |
| B-M1 沙箱底來源不存在 | F18;§4.4.1 改 Batman v1.5.11 payload;D-H11 定案;E-H3 |
| B-M2 tmp-trust / chain1 固定名 | F23、F30;§2.2:chain1 改 per-run `$PCD`、新條目含 chain1、乾淨樹案例;§4.5 dvpc 措辭 |
| B-M3 GATT Flags 無鑑別力 | F43;§6.3 改行為判定 + `GATT_ENCRYPT_CTRL` 白箱;§4.1.2 / §4.8.3 / §10 |
| A-m1 helper sha 規則 | §4.2 成本段;§4.7 10 份 |
| A-m2 deadman 清 upper 副本 | §3 |
| A-m3 `helper-norebuild` nil | F41;§4.2 表 |
| A-m4 txn-2 (a) INVALID / txn-1 ≥ 120 s | §6.2 |
| A-m5 txn-4 位置 | §6.2 |
| A-m6 normalise 前置 / no-op | §4.3 |
| A-m7 / B-m1 sudo PATH / grep rc | §2.2 CI |
| A-m8 範圍(claim-lock §11.4、bcm2710 smoke) | §1.2、§9 |
| A-m9 / B-m12 §5 缺列 | §5 兩列 |
| A-m10 / B-m10 chan 取樣 / reload 次數 | §4.2 |
| A-m11 init mutant enable | §4.1.3、§4.2 |
| A-m12 / B-m9 dm_arm 前 re-stage | §3 |
| A-m13 02 boot_id > 3600 s | §4.3 步驟 4 |
| A-m14 行號 / 命名 / (6) 前置 / (10) 容器臂 | F13 `boot.go:120`;§4.1.1 標題;§6.2 (6)(10) |
| B-m2 F28 引用 | §6.3 `ble-rpa` |
| B-m3 (8) 臂 C 停 helper | §6.2 |
| B-m4 unsquashfs stdin | F44;§4.2 |
| B-m5 n 公式 | §6.3 |
| B-m6 provd.env init 機制 | §4.1.2 |
| B-m7 dbus 471 正向 | F16;§6.3 |
| B-m8 (10) 容器臂 | §6.2 |
| B-m11 §3 `ble-ok` 列 | §3 |
| B-m13 第 99 行 regex | §2.2 |
| B-m14 hold 值 / DISCARDED | §4.2 |
| B-m15 F15 ⚠️ 清、lint 簡化、F23 訊息 | F15;§4.2;F23 |

## 14. v5 審查 → v6 對應
| 發現 | 處置 |
|---|---|
| B-M1 killpoint 實作放 `_test.go` 不進二進位 | §2.1:`killpoint_provtest.go` / `killpoint_release.go` / `killpoint_test.go`;§4.1.3 gate 對 `prov_test` helper 斷言 `strings` 含 `killpoint .*: armed`;`prov-gate-stubs` 加「實作放 `_test.go`」mutant;E-H2 |
| A-m1 helper 份數 | §4.2 tag 規則以 patch 內容判、集合寫進 `tests/wbox/helpers.list`;變體 18;§2.2 `dv-prov-tools.sh`、§4.7、§5、§7.3、§8 改 |
| A-m2 (7) chan 取樣 | §6.2 (7) 引 §4.2 三次取樣 |
| A-m3 / B-m8 行號 / 命名 | F7 `:170`、F11 `:136-141`、F13 `:120`;§0、§2.1「killpoint 檔」 |
| A-m4 CI 管線吞退出碼 | §2.2 CI:`tee` + `PIPESTATUS[0]` + 存檔數 SKIP;§6.1 負對照「故意 FAIL → 紅」 |
| A-m5 / B-m1 (9) dry-run 共用寫入 / 時間 | §6.2 (9):判定來源分開、背景 + 180 s kill、`+120`、完整字串;§7.2 新列(已知破例) |
| A-m6 / B-m14 hold 值 / DISCARDED | §4.2:右側值 + `cmp`;poll `autocommit.hold-discarded`;已 commit → `pr_needs_person`;§5 新列 |
| B-m2 tmp-trust glob 漏三檔 | §2.2:加 `prov-base-254.sh`、`dv-preflight.sh`、`prov-sec-254.sh`(攻擊模擬條目)|
| B-m3 chain1 措辭 | §2.2 / §4.5:chain1 自定 `PCD`;allowlist 寫 `|` |
| B-m4 `ble-ipad.md` | §6.3:由本 PR 乙部建立 |
| B-m5 dbus-send e_machine / 路徑 | §2.2 |
| B-m6 `set-provd-env` restart | §4.5 |
| B-m7 GOCACHE / 步驟位置 | §2.2 CI |
| B-m9 `peer-vs-provd` 前提 | §4.8.3:P2 設計定 |
| B-m10 `helper-flap` tag | §4.2:碰 `src/` 一律 `prov_test` |
| B-m11 / B-m12 GATT 白箱字串 / 前置 | §6.3 `prov-gatt-254` |

## 15. 實作規格補充(v6 審查 MINOR;**與前文衝突時以本節為準**)

**killpoint 與 CI(v6 A-m1、B-m1、B-m7)**
1. killpoint 的 log 呼叫固定為單一格式字面值 `log.Printf("killpoint %s: armed", name)`;常數只在 `seam/seam_provtest.go` 定義;Go 單元對 log 輸出斷言整行。gate 的 `strings | grep -c 'killpoint .*: armed'` 依賴這一點(拋棄式 arm64 `-s -w -trimpath` build 實測:release 0、prov_test 1、實作放 `_test.go` 0、字串串接 0)。
2. 單元測試檔拆兩個:`seam/seam_provtest_test.go`(`//go:build prov_test`,斷言 armed)與 `seam/seam_release_test.go`(`//go:build !prov_test`,斷言 no-op)。
3. CI 的 root Go 步驟**緊接 setup-go**(不放最後;既有「expected-red 步驟放最後」慣例不動),root 跑兩次:`go test -v ./...` 與 `go test -v -tags prov_test ./...`,各自存檔、各自 `PIPESTATUS`、各自數 SKIP = 0,且 `grep -c '^ok ' <log>` ≥ 已知 package 數(對到 0 個測試 = FAIL);`go vet` 同兩次。
4. 無 name 的 gate 加一條:helper `strings | grep -c 'killpoint'` = 0。`prov-gate-stubs` 的「實作沒進二進位」mutant = 「`seam_provtest.go` 改名成 `_test.go`、`seam_release.go` 停用、補一個帶標記的空殼後以 `-tags prov_test` 編出的 helper」(有 `--version` 標記、無 `armed` 字串)。

**`helpers.list`(v6 A-m2、B-m10a)**
5. `tests/wbox/helpers.list` 入版控,一行 `<name> <prov_test|release> <helper|same>`。`lint-wbox` 從 patch 路徑重算(碰 `feed/batman-prov/src/` → `prov_test`;碰 `feed/batman-prov/**` 或 name = `test` → `helper`),與檔案逐行不等 → FAIL。`build-board.sh --wbox` 讀同一檔決定 `BATMAN_PROV_TEST`,不另設來源。`dv-prov-tools.sh` 雙向斷言:`helper` 者 sha ≠ release 且互異;`same` 者 sha = release;不符 → FAIL「helpers.list 與 payload 不一致(版本錯位?)」。

**hold 值與 DISCARDED(v6 A-m3、B-m10b)**
6. `cmp` 兩邊:主機 = payload 的 `etc/batman-build` 經 `sed -n 's/^BATMAN_VERSION=//p'`;節點 = 寫入後讀回的 p6 旗標經 `head -c 200 | tr -d '\r\n'`(同 autocommit `:271`)。
7. DISCARDED 出現 → **先**在 trial 內以 root 建 `$RUNDIR/autocommit.ctl/hold-commit`(`held_commit()` 每輪 poll 讀,`:60,510`,立即擋 commit)→ 再 `batman-slot is-trial`:0(trial)→ `back_to_a`;1(committed)且版本 = V → INVALID + 正常 restore;1 且含 wbox → `pr_needs_person`;**2(unknown)→ `pr_needs_person`**。§5「DISCARDED 且已 commit」的自測只用 V payload。

**tmp-trust(v6 A-m4、B-m4)**
8. `prov-sec-254.sh` 用**行級** ERE,不用 `.` 整檔豁免:`ln -s /tmp/x /tmp/run/batman-prov( |$)|/tmp/run/batman-prov( |$)|/tmp/run/batman-dvpc\.` + 理由(root 白箱、攻擊模擬,目標只在 root 0755 的 `/tmp/run` 下);dvpc 白箱若在 `scripts/dv/` 另加同條。`test-tmp-trust.sh` 加:`prov-sec-254.sh` 多一行 `cat /tmp/x` → UNTRUSTED(證明不是整檔豁免)。

**白箱可實作性(v6 B-m5、B-m6)**
9. 建 `$PCD` 的邏輯抽成共用函式 `scripts/lib/dvpc-254.sh dvpc_place <ssh> <dir>`(`mkdir -m 0711` 無 `-p` → EEXIST 即 `FAIL dvpc dir pre-exists`),`prov-lib-254.sh` 與 `chain1-254.sh` 都呼叫它;dvpc 白箱只對這個函式做(chain1 的 `RUN` 寫死,不為一個 `mkdir` 白箱跑整條鏈)。
10. killpoint 目錄的負測試改為:root 預建後 `chown 65534` / `chmod 0777` / 改成 symlink / 第二個 hardlink → helper log `killpoint: refused (<why>)`;`nobody` 只用來證明 `/tmp/run`(root 0755)本身擋住(一行 EACCES)。§7 第一列照此改讀。

**GATT 與 agent(v6 B-m2、B-m3)**
11. `prov-gatt-254` 白箱:02 的判定 = bluetoothctl 印 `Failed to read: org.bluez.Error.NotPermitted`(bluetoothctl 只印錯誤**名稱**,`client/gatt.c:835`;`Not paired` 訊息不會出現,v5 B-m11 原文錯);0x0F 與 0x02 的區分交給 btmon(ATT Error Response 0x0F + SMP Pairing Request / Pairing Failed、無 LE Start Encryption);需要訊息時改用 02 上 `dbus-send --print-reply … ReadValue`。
12. §3 加一列「04 agent 程序(bluetoothctl,pid 檔 `$DVD/<run>/agent.pid`):`prov-sec-bond-254` 起 / 收;prov deadman `kill` + 刪 pid 檔」。`prov-gatt-254` 前置改為「pid 檔不存在 **且** 04 無 harness 起的 bluetoothctl 程序 **且** 02 `bluetoothctl paired-devices` 不含 04」(`AgentManager1` 沒有列舉方法,原文的「斷言無註冊」做不到)。乙部順序在 §4.3 補一行:`prov-gatt` → `prov-sec-bond` → 其餘。

**provd env 與 dbus-send(v6 B-m8、B-m9)**
13. `set-provd-env` 斷言讀的 pid = `/proc/<pid>/exe` 為 provd 二進位、父程序為 ujail 的那一個(procd 記的 instance pid 是 ujail,它的 environ 一定含所設值 → 讀錯 pid 永遠 PASS);負對照:`provd.env` 寫一個 init 不認的鍵 → 子程序 environ 無它。
14. E-H1 的 dbus-send 預期 NEEDED = `libdbus-1.so.3`、`libgcc_s.so.1`、`libc.so`(`readelf -d` 實測),並斷言 04 有 `libgcc_s.so.1`;可改抄同樹 `ipkg-install/usr/bin/dbus-send`(同樣寫死 a72 路徑)。

**未核對(帶進實證)**:CI 實際用 go 1.26(審查用 1.22.2 驗字串佈局);04 的 `libgcc_s.so.1`;dry-run 在 OTS 節點 120 s 內能否完成 pre-commit canary `docker run`(加進 E-H5 量測)。

## 16. P1b 程式碼審查後的修訂(p1b-code-review-A / -B;**與前文衝突時以本節為準**)

**L7 判定(A-M1、B-M2)**
1. `killpoint <name>: sysrq reboot` 這行**不預期送達主機**:寫完 syslog 後數微秒內就寫 sysrq `b`,這行還在 RAM 的 logd ring 裡,隨重開消失。§4.1.1「只在 `sysrq reboot` 行 + 2 s 內 boot_id 改變時判 L7 PASS」與 §6.2 L7 列的「全部:sysrq 行」**作廢**,改為以下全部成立才 PASS:
   - (a) `push-helper` 當下收到本次 pid 的 `killpoint <name>: armed`,且 killpoint 檔已刪;
   - (b) 觸發動作(`net-apply` / claim)**沒有回應**,ssh 斷線;
   - (c) 整段期間主機端 `logread -f` 串流**沒有** `killpoint <name>: fallback` 行(fallback 前有 2 s 睡眠,串流來得及送出;看到 = ⚠️,不是 PASS);
   - (d) boot_id 改變;
   - (e) 重開後的狀態等於該點的預期狀態(§6.2 各列),這一項才是真正有判別力的證據。
   產品不改:不在 sysrq 前加睡眠(加了會讓別的 goroutine 多跑一段,離「拔電」更遠)。
2. E-H6 擴充:04 上 `logger -t e-h6 probe-$RANDOM; echo b > /proc/sysrq-trigger`,主機端同時 `logread -f`;記下 probe 行有沒有到主機(只當資訊,不影響上面的判定)。

**點的位置有單元測試(A-M3)**
3. `node/seam_points_test.go`(`prov_test`):每個點以 `seam.ArmForTest` 截停,斷言當下的 overlay gen / state、`.txn` 有無、p5 寫入次數、setkey 次數、`--save` 次數、root 欄、p6 last_known、lock 呼叫次數;claim.replay、ssh_keys.set、root_password.reset、`commit`(leave / ssh_keys / owner.add / owner.remove)不觸發任何點;claim 不觸發 txn 點,join 不觸發 claim 點。突變負對照(txn-4 移到 RemoveTxn 前、claim 點拿掉、txn-1 放進 commit、claim-before-shadow 移到上鎖後)全紅。
4. `commit()` 不再由 `what` 字串推出點名;`claimVerify` 直接呼叫 `commitTxn(&next, "", "claim-after-persist")`。
5. `txn-3` 也在「`--prov-only` rc ≠ 0 但讀回 p5 gen 已前進」的分支觸發(B-m7);§4.1.1 的「`--prov-only` rc 0 後」讀作「p5 已持有新 gen 後」。

**killpoint 檔的讀法(A minor、B-m6)**
6. 目錄先 `Lstat` 檢查(root、0700、非 symlink);不過 → refused,**不在該目錄內 unlink 任何東西**。過 → 檔以 `O_NOFOLLOW|O_NONBLOCK` 開一次,對 fd `fstat` 檢查(regular、root、mode 位元含 setuid/setgid/sticky 須**恰為** 0600、link 1),讀至多 64 B;檔在可信目錄內一律刪除(不論結果)。`reboot -f` 之後仍活著 → log `reboot did not happen` 再停住。

**wbox build 與 gate(A-M2、B-M1、雙方 minor)**
7. `build-board.sh` 解析完參數即 `unset BATMAN_WBOX BATMAN_PROV_TEST`;`--wbox` 不得與 `--card-only` / `--update-lock` 併用;`helpers.list` 的 tag 只能是 `prov_test` / `release`;套 patch 前 `git -C feeds/batman status --porcelain --ignored` 必須為空,否則拒絕並列出內容(上次被 SIGKILL 的 build 留下的 mutant、開發者未 commit 的修改都不會被疊加或抹掉);variant 改變時先清兩個套件並把 stamp 寫成 `in-progress:<variant>`,build 成功才寫正式值。
8. gate:release tag 變體的 Go helper 套用與正常 build 相同的「無 seam」三條(tags / marker / `killpoint`);rootfs 內的 wbox 見證集合必須**恰好**是本變體的那一個(`test` = 空集合),見證格式 `WBOX-<name>-<8 hex>`;見證掃描遇讀不到的檔案 = FAIL,且在 gate 自己的 shell 內執行(之前在 `$(...)` 內,`fail` 只結束子 shell → gate 照樣 PASS,由新自測抓到)。
9. gate 自測每個 FAIL 案例要對上**原因字串**;新增 marker-only / killpoint-only release helper、讀不到的檔、殘留與疊加見證、release 變體帶 prov_test helper、tag 打錯;路徑從腳本位置推。逐條拿掉 gate 的 5 個檢查 → 自測各自 BAD。firmware CI(`build-firmware.yml`,ekh 兩板)跑 gate 與自測。

**仍是殘項(記在 #254)**:P1b 自己的 CI 要等 harness PR 進 main 後 rebase 才會跑 `prov_test` tag(A minor);`seam_release_test.go` 只是文件性質,真正的保證是 gate 的 `strings` 檢查(B-m5,已在檔頭註明)。

**程式碼審查第 2 輪後的增補(p1b-code-review-r2-A / -B;與前文衝突時以本段為準)**

10. 點名在 release 二進位裡也不能出現(r1 A-m8):呼叫點用 `seam.Point`(`points.go`,`uint8` 常數 `Txn1`…`ClaimBeforeShadow`、`None`),名稱表只在 `seam_provtest.go`。arm64 實測:release 的 `killpoint` / 點名 / 標記 / `/dev/kmsg` 都是 0;gate 的「無 seam」三條加第四條:無點名(`claim-after-persist`、`claim-before-shadow`)。
11. §16.1 加 (f):重開後的 boot-reasons 記錄為 `UNCLEAN` 且帶 `hints: sysrq`(`95-batman-storage:671`,看 console capture 裡核心自己印的 `sysrq: ` 行),fallback 走 `reboot -f` 不會有這個 hint。helper 在 sysrq 前把 `killpoint <name>: sysrq reboot` 也寫進 `/dev/kmsg`(fallback、`sysrq write failed` 同),console capture 就帶著點名過重開;(c)「串流沒有 fallback」降為輔助證據。⚠️ 04 的 console capture 有沒有開,E-H6 一併確認;沒開時 (f) 判 INVALID(不是 PASS)。
12. killpoint 檔超過 64 B → refused(不截斷後照讀)。
13. 回歸測試(r2 A-M1):`--wbox` 的步驟搬到 firmware `scripts/lib-wbox.sh`(`bb_lock`、`wbox_env_reset`、`wbox_apply`、`wbox_stamp_begin` / `_done`),`build-board.sh` 只呼叫它們;`scripts/test-build-board-wbox.sh` source 同一份 lib,在假 feed 上跑 34 個案例(乾淨 / 已改 tracked / untracked / ignored / 殘留 mutant / SIGTERM、SIGINT 中途 / env 繼承 / stamp 四態 / 鎖 / build-board 真的呼叫 lib)。8 個 lib 突變(trap 移到檢查前、拿掉乾淨檢查、拿掉 `--ignored`、不 unset、不寫 in-progress、不鎖、拿掉 tag / 第 3 欄檢查)各自讓測試 BAD。接進 firmware CI。
14. 一棵樹同時只跑一個 `build-board.sh`(r2 B-m2):`flock -n logs/.build-board.lock`,第二個 exit 2。
15. `helpers.list` 第 3 欄(r2 B-m3):`helper` = 變體帶自己的 helper;`same` = release helper,gate 要求 tag `release` 且 helper 是無 seam 的 Go 二進位;其他值 = FAIL(build-board 與 gate 都擋)。gate 另拒 symlink 形式的 helper(r2 B-m4:絕對 symlink 會讓 gate 讀到 build 主機的檔);init mutant 的偵測不再寫死 `batman-provision`(r1 A-m4)。
16. gate 自測(r2 A-m2 / B-m8):先檢查 `BATMAN_SRC` 有 P1b 的 seam 套件,沒有就明說「pin 要指向有 P1b 的 Batman」;每個 mutant helper 先驗它真的是案例假設的樣子再跑案例;37 個案例,gate 的每一條 `fail` 逐條拿掉都要讓自測 BAD(數字以 #254 留言的實跑結果為準,不在這裡寫死)。
17. **合併順序**:Batman PR-P1b 先 merge,firmware PR 後 merge 且 pin 指向含 P1b 的 Batman commit;firmware CI 的 gate 自測在舊 pin 上會明確失敗,這是刻意的。
18. **rc 必須是審過的程式碼**(r2 B-M1):rc 的 Batman pin 要含本輪的 P1b commit;每次 P1b 改動後重切 Batman `rc/254-p1b`、firmware pin + `BATMAN_BUILD_N` 加 1,payload 重 build,E-H2 重跑並附 step 7 gate 輸出。舊 payload(`1.5.14-wsl.5+01b12c9…`)只當 build 流程的證據,不上節點。

**殘項(#254 checklist)**:`main.go` 的接線(daemon 啟動 `seam.Arm`、`--boot` 印標記)沒有 Go 單元測試——拿掉 `seam.Arm` 時 linker 會一起丟掉 armed 字面值,gate 會擋;`--boot` 的標記只由 tier A preflight(P9)抓(r2 A-m6)。

**程式碼審查第 3 輪後的增補(p1b-code-review-r3-A / -B;與前文衝突時以本段為準)**

19. **單元測試不可能真的重開機**(r3 B-M1):prov_test 單元測試以 root 跑(§2.2),所以 `seam.SafeForTests()`(prov_test only)把 `reboot` 換成 panic、`sysrqPath` / `kmsgPath` 指到不存在的路徑、`fallback` 換成 panic;seam 與 node 的 prov_test 測試各有 `TestMain` 先呼叫它,`ArmForTest` 照舊逐測試替換並還原。負對照:`At` 忽略 arm 的突變 → node 測試 0.04 s 內清楚 FAIL(之前是卡到逾時、root 下會寫 sysrq);拿掉 SafeForTests 的 reboot 替換 → `TestSafeForTestsNeverReboots` FAIL。
20. killpoint 檔一行一個點名:`"txn-1 x"`、`"txn-1\ntxn-2"` 等一律 refused(r3 B-m3)。
21. `GO_PKG_TAGS` 只由 `BATMAN_PROV_TEST` 決定(Makefile `else GO_PKG_TAGS:=`),`wbox_env_reset` 另 unset `GO_PKG_TAGS` / `GOFLAGS`(r3 B-m1)。
22. 正常 build 遇到 feeds/batman 帶 wbox 見證的修改 / untracked / ignored 檔 → 提早拒絕(`wbox_normal_check`;`openmanet_setup.sh -i` 不重設 feeds/batman,r3 B-m4);其他未 commit 的修改照舊允許(標 `.dirty`)。
23. wbox patch 只能改 `feed/batman-prov/` 與 `feed/batman-provision/`(stamp 步驟會清的兩個套件);碰 `tests/wbox/` 或其他路徑 → 拒絕(r3 A-m5)。
24. `test-build-board-wbox.sh` 加:build 中產生的 ignored 檔被清掉(`clean -x`,r3 A-m1)、SIGHUP、patch 範圍、正常 build 的殘留檢查、`build-board.sh` 內各步驟的**順序**(r3 B-m2);共 53 案例。gate 拒 symlink 形式的 `/etc/batman-build`(r3 A-m3);自測 46 案例。
25. **E-H6 已實證(2026-10-28,04)**:`sync` 後 `echo b > /proc/sysrq-trigger` → boot_id 換新、uptime 歸零;boot-reasons `prev=UNCLEAN … hints: sysrq`;ramoops console 檔留著 `<4>` 的 kmsg probe 行與核心的 `sysrq: Resetting`(r3 A-m4 / B-m5 的前提成立);04 回 A wsl.4、鄰居恢復。主機 `logread -f` 收到 syslog probe(該次有 `sync`,時序與 killpoint 不同,只當資訊)。
26. §4.1.3 舊句「`test` 的見證 = helper 標記」作廢:`test` 的見證集合為空(§16.8),它的身分由 helper 的 tag / 標記 / armed 字面值判定(r3 A-m2)。

**殘項(#254 checklist)**
- `local-ab-tar.sh` 打包時不跑 gate:要人工偏離流程(wbox build 後手動 stamp → make → local-ab-tar)才會做出「標 normal、帶 seam」的 payload(r3 A-m6)。
- `fast-build.yml` 產出的 A/B payload 沒有映像 gate(既有,非本 PR,r3 B-m6)。
- bcm2710 的 wsl.x 沒 build(CM4 決定,r3 B-m7)。
- 帶 patch 的變體出來後,補一次真 build + Ctrl-C(目前只在假 feed 上證過還原,r3 B-m8)。

**程式碼審查第 4 輪後的增補(p1b-code-review-r4-A / -B:兩位都 0 BLOCKER / 0 MAJOR;與前文衝突時以本段為準)**

27. 測試 binary 一律安全(r4 A-m2 / B-m1):prov_test 的 seam 在 `init()` 偵測 `os.Args[0]` 以 `.test` 結尾就套 `SafeForTests`,不靠各 package 自己寫 `TestMain`;`cmd/batman-provhelper` 的 `TestSeamSafeWithoutTestMain` 守住。負對照:拿掉 init 防護 → 該測試 FAIL;刪 node 的 TestMain + `At` 忽略 arm → node 測試 0.07 s FAIL(上輪是卡住 + 假 reboot 被呼叫)。
28. wbox patch 不得 rename / copy(`--numstat` 只列 rename 的目的地,r4 A-m1);`lint-wbox` 與 `wbox_apply` 都擋。`wbox_normal_check` 的 git 失敗 = 拒絕(r4 B-m3)。root 不建 build 鎖檔(r4 A-m4 / B-m5)。`test-build-board-wbox.sh` 的呼叫 / 順序檢查排除註解行、gate 呼叫比對完整參數(r4 B-m2);61 案例。
29. **§4.2 步驟句更正**:stamp 不是 trap 寫的——變體改變時先清兩個套件、寫 `in-progress:<variant>`,build 成功(第 6 步後)才寫 `<variant>`;trap 只還原 feeds/batman(§16.7、§16.13)。
30. **擁有權表補 build 端(§3 的增列,r4 B-m6)**

| 資源 | 唯一寫者 | 讀者 | 備註 |
|---|---|---|---|
| `logs/.build-board.lock`(firmware 樹) | `build-board.sh` 的 `bb_lock`(tree owner 建;root 只用不建) | 下一個 `build-board.sh` | `flock -n` fd 9;SIGKILL 後孤兒 make 仍握 fd 9 → 下一個 build 被擋,剛好防兩個 build 共用 build_dir |
| `logs/wbox-<board>.stamp` | `wbox_stamp_begin` / `_done` | 同兩者 | 三態:`<variant>`、`in-progress:<variant>`、不存在(= unknown → 清) |
| `files/etc/batman-build` | `stamp-batman-build.sh`(第 4 步) | image build、第 7 步 gate、`pr_ota_b` | wbox build 後仍留著 → 手動跑 `local-ab-tar` 會帶錯標籤(殘項 r3 A-m6) |
| build_dir 的 `batman-prov` / `batman-provision` | OpenWrt make | image | 變體改變時由 `wbclean` 清 |
| `feeds/batman` 工作樹 | `wbox_apply`(套 patch + EXIT trap 還原);正常 build 只讀(`wbox_normal_check`) | make | 套 patch 前必須乾淨 |

31. **生命週期矩陣補 build 端(§5 的增列,r4 B-m6)**

| 路徑 | 行為 | 證據 |
|---|---|---|
| wbox build 被 Ctrl-C / TERM / HUP | EXIT trap 還原 feeds/batman;stamp 停在 `in-progress:<variant>` → 下次必清 | 真 build:normal 與 test 各一次 Ctrl-C(rc 130、無殘留、鎖釋放);lib 測試三種訊號 |
| wbox build 被 SIGKILL | trap 不跑 → mutant 留在 feeds/batman;下一個 wbox build 拒絕(不乾淨)、下一個正常 build 拒絕(帶見證);孤兒 make 握鎖時下一個 build exit 2 | lib 測試(殘留 mutant 案例);⚠️ 真 SIGKILL 未做 |
| 兩個 build 同時 | 第二個 `flock -n` 失敗 exit 2 | lib 測試 |
| wbox build 之後跑 `--card-only` | 第 7 步 gate 無 name → FAIL「carries BATMAN_WBOX」 | 真 payload(r3、r4 審查實跑) |
| stamp 停在 in-progress 後的正常 build | `wbox variant changed` → 清兩個套件 | wsl.6b build log |
| root 在新樹第一次跑 | `bb_lock` 拒絕(不建鎖檔) | lib 測試(stub id) |

32. 行號更新(r4 A-m3):`main.go:504`(`not committed: restored`)、`:506`(`RemoveTxn`)、`node.go:1122-1123`(txn-4)、`boot.go:120` / `:127` 不變。

**misc-L38 / -L42 / -L43 / -L51(§4.2 表最後一列)**:§6.2 只寫了 L 編號,沒寫每個 mutant 改哪裡、讓哪條判定失效;L51 在 stage1 設計是「`lastjoined`」、在本設計 §6.2 是「`sock: unexpected`」,兩處不一致。**這 4 個變體先不做**,待補一段設計(每個:mutant 位置、對應的 prov-misc 判定、負對照預期)並過審查後再寫 patch;其餘 13 個變體已在 `tests/wbox/`(harness 5b32fdd)。


## 17. misc 變體與 `prov-misc-254`(v9;取代 v8 的 §17;**與前文衝突時以本節為準**)

### 17.1 為什麼要補(v8 審查 A / B 之後重寫)
§6.2 `prov-misc-254` 原文只寫「L38(96 superblock 壞出口)、L42、L43、L51(`sock: unexpected`)」。對照原始碼(rc d0643d5):
- L38 / L42 / L43 / L51 的定義在 `254-stage1-impl.md:368,372,373,379`;判定全在 autocommit 的「mesh join required」段(`batman-autocommit:399-425`),arm 的寫入在 sysupgrade 第 1 段的 `_ab_arm_mesh`(sysupgrade source 的是 98 在新 overlay 複製的 `/lib/upgrade/platform.sh`,不是 `/usr/lib/batman/platform-ab.sh`,`98-batman-sysupgrade:7-10`,v8 A-B1 / B-BLOCKER-1)。
- 「96 superblock 壞出口」與 L38 無關,作廢;「`sock: unexpected`」是 helper socket 目錄的拒絕(`sock/sock.go:74`),移到 L11 / `prov-sec-sockdir-254`(§17.4)。
- §6.2 `prov-misc-254` 那一列改讀「見 §17」(v8 B-m7)。

### 17.2 四個變體:全部只改 `batman-autocommit`,只在 dry-run 裡用
v8 的 `misc-L42`(mutant `batman-slot` 寫 arm 檔)與 `misc-L51`(bind `platform-ab.sh` 跑真 OTA)作廢:前者讓 root 的槽寫入器在 bind 期間若遇真 OTA 會被抄進 ramfs、寫出 `radio`(fail-open,v8 B-m3),後者 bind 目標錯且要在 bind 下跑真 sysupgrade(未經實證)。改為:**每個 L 的「判定」半邊用 autocommit dry-run + 白箱狀態 + autocommit mutant 測;「寫入」半邊用既有的真 trial 斷言或 CI 單元測。**

| name | mutant(`batman-autocommit`) | 讓哪條判定失效 |
|---|---|---|
| `misc-L38` | 拿掉 `:404` 的等待迴圈 | writer=99zz 時等 ≤ 60 s 改用 helper 的值 |
| `misc-L42` | `:421` 缺檔時 `NEED_MESH=0`(不 fail-closed) | member 無 arm 檔 → 要鄰居 |
| `misc-L43` | `:420` 不比對第 1 欄(boot8) | arm 檔綁 arm 開機,舊檔無效 |
| `misc-L51` | `:420` 第 3 欄 `joined` 也當 `radio` | arm 開機入過網 → 要鄰居 |

- 見證:mutant 那一行旁加 `log "… WBOX-misc-LNN-<8 hex>"`(dry-run stdout 可見),檔頭註解另一次。tag release / kind same(`lint-wbox` 依規則算)。
- bind:來源 = 變體 payload 抽出的 `usr/bin/batman-autocommit`(`dv-prov-tools.sh` 同法,root 0755,主機 sha = 節點 sha);目標 = `/usr/bin/batman-autocommit`。**只在 dry-run 臂期間 bind**;bind 前斷言沒有 `batman-autocommit` 程序在跑(committed 槽的真 main 開機即退出,`:326`);bind 後斷言 `grep -c WBOX-misc-LNN /usr/bin/batman-autocommit` = 1;mutant 臂 stdout 沒有見證行 = **INVALID**(mutant 沒被執行),不是「mutant 無效」。臂結束立刻 unbind。不在 bind 下做任何 OTA / apply / reboot。
- 仍用真 build 出 payload(與其他變體同一條 gate 鏈、E-H2 驗收;成本 4 build / rc,§7.3)。

### 17.3 dry-run 臂的共同規則(v8 A-M1 / B-MAJOR-2、A-M3 / B-MAJOR-3)
- 起法:`setsid env AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1 AUTOCOMMIT_TIMEOUT=$((uptime+600)) batman-autocommit run`,stdout 存檔;讀到 `mesh join required:` 行(L 臂只需這行)或 150 s 逾時就 `kill -TERM -- -<pgid>`,再斷言 `pgrep -f batman-autocommit` 為空(殘留 → FAIL 並 `kill -KILL -- -<pgid>`;不是硬體持有者)。期限設 600 s,watchdog 在被殺前不會到期。
- 每臂前快照、臂後還原並斷言:`$ST/prov-state`、`$ST/ota-armed.mesh`(有 / 無與內容)、`$RUNDIR/autocommit.wd`、`$RUNDIR/autocommit.decided`(committed 槽上本來不存在;dry-run 建的由 harness 刪)、`$ST/ota-trace.log` 只增不改(記錄新增行數)。
- `prov-state` 白箱:只改第 1(= 本次 boot_id,或刻意的別值)、2、4、6 欄,**第 3、5 欄照抄快照**;tmp + `mv`、0600。每臂結束**立即**寫回快照行。整臂期間 helper pid 不變(變了 → INVALID:helper 重啟會重寫 `prov-state`)。
- `ota-armed.mesh` 白箱:同樣 tmp + `mv`、0600;臂後回到快照。
- 順序:四個 L 的 dry-run 臂連續做完、每臂殺乾淨;`prov-misc-254` 不做 OTA。
- 04 是 OTS 節點:dry-run 進到 commit 分支前會跑 canary(`:518-528`);L 臂在 `mesh join required` 行就殺,不會到 canary;仍把「可能 import / prune canary image」列進 §7.2。

### 17.4 各項測法(04,`prov-misc-254`)
- **L38**
  - 臂 a(切換):`prov-state` = `<boot> 99zz <snap3> unclaimed <snap5> 0` → 起 dry-run → 等到它在迴圈裡(其 pgid 下有 `sleep 1` 子程序)→ 改寫 `<boot> helper <snap3> member <snap5> radio`、`ota-armed.mesh` 刪掉 → 斷言 `mesh join required: 1 (prov=member mesh_expect=radio radio_required=1)`。
  - 臂 b(helper 沒來):不改寫 → 斷言 `mesh join required: 0 (prov=unclaimed` 且該行出現在起始後 ≥ 60 s。**有判別力的是臂 b**(v8 B-m1)。
  - 臂 c(boot_id 不符 → 今天的規則,v8 B-m2):第 1 欄 = 別的 boot_id → 斷言 `prov=none`。
  - 負對照:bind `misc-L38` 跑臂 b → 立即得到 `prov=unclaimed`、時間 < 60 s → 判定 FAIL = mutant 有效;臂 a 在 mutant 下得到 `prov=unclaimed`(沒等)。
- **L42**
  - 寫入半邊 = §6.2 (6a) 既有的真 trial(直接 `batman-slot apply`):**加一條斷言**「apply 之後 p6 沒有 `ota-armed.mesh`」(apply 前刪除並斷言)。
  - 判定半邊(dry-run):`prov-state` member/radio、`ota-armed.mesh` 不存在 → 斷言 `member: no usable ota-armed.mesh — neighbours required (fail-closed)` + `required: 1`。負對照:bind `misc-L42` → `required: 0`。
  - 寫入半邊的判別力:白箱寫一個正確的 radio 檔(boot8 = boot-reasons 倒數第 2 行、slot = active)→ dry-run `armed in radio-only mode` + `required: 0`;證明「apply 後若有檔,保護就失效」,所以 (6a) 的「無檔」斷言是有判別力的。
- **L43**(dry-run)
  - 正向:member/radio + `ota-armed.mesh` = `<非 arm 開機的 boot8> <active> radio` → 斷言整行 `mesh join required: 1 (prov=member mesh_expect=radio radio_required=1)`、本次 stdout **沒有** `no usable`、行後讀回 arm 檔內容未變(v8 B-MAJOR-2)。
  - 對照:boot8 改成 boot-reasons 倒數第 2 行 → `armed in radio-only mode` + `required: 0`。
  - 負對照:bind `misc-L43` 跑正向臂 → `required: 0` → FAIL = mutant 有效。
- **L51**
  - 寫入半邊(`_ab_arm_mesh` 在入過網時寫 `joined`):
    - CI 新測 `scripts/test-arm-mesh-254.sh`:source `platform-ab.sh` 後以函式覆寫 stub 掉 `_ab_live_sysupgrade`、`batman-slot`、`/proc/mounts` 檢查、`RAM_ROOT`、`RUNDIR`;案例:`lastjoined` 非空 → `joined`;空 + meshjoin stub 未入網 → `radio`;caller 不是 procd → 不寫檔;upgraded 不在 → 不寫。負對照:把 `m=joined` 分支改掉的副本 → BAD。
    - 節點:§6.2 (7) 既有的 `S1 ARMED-MESH … m=joined` 斷言(04 在 fleet mesh、本次開機入過網)。
  - 判定半邊(dry-run):member/radio + arm 檔 = `<arm boot8> <active> joined` → `required: 1`;負對照 bind `misc-L51` → `required: 0`。
- **L11**(helper 重啟,含 `sock: unexpected`,v8 B-m6):`/etc/init.d/batman-provhelper restart` → 新 pid、`helper.sock` 重建且屬主 / 權限照 §4.5、health 檔 15 s 內更新。負對照:root 先在 socket 目錄放一個普通檔再 restart → log `sock: unexpected … refusing to start`、health 15 s 內**不**更新(證明 health 斷言有判別力)→ 刪檔、restart、恢復。
- **L9 / L10**(`bluetoothd` / `dbus` 重啟):重啟後 15 s 內 health ok;負對照:`bluetoothd` stop(不 start)→ 15 s 後 health 非 ok → start 恢復。
- **L27**(dropbear 重啟):重啟後 lab key 登入成功;負對照:以不在 `authorized_keys` 的金鑰登入 → 拒絕(證明登入斷言有判別力)。
- **L3**(clean shutdown):`batman-slot reboot committed` → 新開機 boot-reasons `prev=CLEAN`、helper `boot rc=…` 行;負對照 = E-H6 已證的 sysrq → `UNCLEAN … hints: sysrq`(§16.25),不重做。

### 17.5 擁有權、生命週期、副作用(補 §3 / §5 / §7.2,v8 A-m2 / B-m9 / B-m12)
- §3 增列:
  - p6 `prov-state`:寫者 = 99zz、helper(產品);`prov-misc-254` 的 dry-run 臂期間 harness 是白箱寫者(lease 內、helper pid 不變時;第 3、5 欄不改;每臂還原)。
  - p6 `ota-armed.mesh`:寫者 = `_ab_arm_mesh`;刪者 = autocommit commit / revert(**含 dry-run 的 watchdog**,`:237`);harness 白箱寫(dry-run 臂內,每臂還原)。
  - `/usr/bin/batman-autocommit` bind:`prov-wbox-254.sh bind`;`wbox.list` 記錄;解除 = 臂結束 unbind、`unbind-all`、deadman、重開。
- §5 增列:harness 在 dry-run 臂中死掉 → deadman:`kill` 該 pgid、unbind、自 `$DVD/<run>` 快照寫回 `prov-state` / `ota-armed.mesh`、刪 dry-run 建的 `autocommit.wd` / `decided`;P9 加檢查:`prov-state` 第 2 欄 ≠ `helper` 且 uptime > 120 s,或第 3 欄 ≠ 快照 → FAIL 並印還原指令;`/proc/mounts` 有 `/usr/bin/batman-autocommit` 的 bind → FAIL。bcm2710 不適用(CM4 決定)。
- §7.2 增列:dry-run 在 p6 `ota-trace.log` 寫 `AC START` / `UNHEALTHY` 行;OTS 節點上 canary 可能 import / prune;`autocommit.wd` / `decided` 由 harness 清;bind 期間若有人在 04 上跑真 OTA,mutant autocommit 不會被抄進 ramfs(不在 `RAMFS_COPY_BIN`)但會在 trial 外影響 dry-run 以外的手動 `batman-autocommit` 呼叫 → 臂結束立即 unbind。
- **產品殘項(#254)**:dry-run 的 watchdog 會在 committed 槽上刪 `ota-armed.mesh`、拿真的 `autocommit.decided`(`:207-215,233-240`)— dry-run 接縫的副作用,本 PR 不改產品。

### 17.6 成本
- 不新增 OTA / apply / 重開;dry-run 臂約 12 個 × ≤ 150 s(L38 臂 b ≥ 60 s)≈ 15–20 分鐘;L11 / L9 / L10 / L27 各 ≤ 1 分;L3 一次重開(既有)。
- 4 個 misc 變體各一次 build(§7.3)。
- 在使用者核准的 H3-U3 預算內(不增加 trial 次數)。

## 18. 安全審查後的修訂(`254-reviews/p1b-security-review.md`;**與前文衝突時以本節為準**)

### 18.1 F1(MEDIUM):節點自己拒絕 commit `-wbox` image
**問題**:§4.2「只進非 committed 槽;一律 hold」與 P9 只在 harness 裡;節點上沒有任何東西拒絕 commit 一個 `-wbox` image。拿錯檔、手動 `sysupgrade -n`、harness 忘了 hold → 健康的 trial 被 commit;`helper-nojoinop` / `helper-clientchal` / `rc9-unclaimed` / `helper-notrial` 削弱驗證,P2 BLE 上線後是遠端可達的接管路徑。

**設計**(產品,batman-provision;閘在被 trial 的 image 自己身上):
- `batman-autocommit`:`wbox_image()` = `/etc/batman-build` 有非空的 `BATMAN_WBOX=` 行。**非 dry-run** 時,健康的 trial 若是 wbox image,`why = "wbox test image (BATMAN_WBOX=<name>) — never auto-committed (deadline revert armed)"`,摺進與 hold 相同的位置(只在其他條件都健康時出現,不搶 `FIRSTWHY`);log 一次 + `otalog AC WBOX-NOCOMMIT`。看門狗照舊在 deadline revert。dry-run 不受影響(§6.2 (9) 的 `DRYRUN decision: COMMIT` 不變;§17 的 dry-run 臂只看 `mesh join required` 行)。
- `batman-slot commit`(第二層,擋操作員手動 commit):wbox image → 拒絕,除非環境 `BATMAN_SLOT_ALLOW_WBOX=1`(§6.2 目前沒有單位需要)。
- `/etc/batman-build` 讀不到 → 當成非 wbox(release image 無此行;wbox 由 gate 保證有此行)。
- 擁有權:`/etc/batman-build` 由 build 寫、rootfs 唯讀;讀者 = autocommit、batman-slot。
- 生命週期:release image 行為不變;wbox image 永不自動 commit;閘在被 trial 的 image 裡,降級不相關;hold + wbox 兩條都擋。
- 測試:
  - CI `scripts/test-autocommit-wbox.sh`:以 stub 的 `/etc/batman-build`、`batman-slot`、健康檢查驅動 autocommit 的決定 → wbox:不 commit、`why` 正確;非 wbox:commit;dry-run + wbox:`DRYRUN decision: COMMIT`;`batman-slot commit` 對 wbox 拒絕、帶 `BATMAN_SLOT_ALLOW_WBOX=1` 放行。負對照:拿掉閘 → BAD。
  - 節點新單位 `prov-wbox-nocommit-254`(04):OTA 一個 release tag 的 wbox 變體(`96-noprov`)**不設 hold** → B trial 健康 → `WBOX-NOCOMMIT` + deadline revert(`TRIAL-REVERTED … reason=wbox test image`)→ 回 A。負對照:同流程用 wsl.6 的 `--wbox test` payload(本閘之前 build)→ 被 commit → 斷言 COMMITTED 後立刻 `batman-slot rollback` 回 A(副作用:04 commit 過一次 wbox 槽,列入 §7.2)。

### 18.2 其餘
- **F2**:`local-ab-tar.sh` 打包前對 rootfs 跑 `check-prov-test-gate.sh`(name 取自 stamp 的 `BATMAN_WBOX`);`fast-build.yml` 加與 `build-firmware.yml` 相同的 gate 步驟。關閉殘項 r3 A-m6、r3 B-m6。
- **F3**:gate 的正常模式對**整個 rootfs** grep marker 與 armed 字面值。
- **F4**:`wbox_normal_check` 也看 staged 的檔,以 `-z` 讀檔名(非 ASCII)。
- **F5**:`wbox_env_reset` 另 unset `WBOX_DIR`、`GO`。
- **F7**:killpoint 拒絕訊息以 `%q` 輸出(已做,P1b 5316813)。
- F6 / F8–F11:INFO,無改動。

### 18.3 待審查
§17(v9)與 §18 送兩位全文審查;§18.1 是產品行為改動,過審才實作。

## 19. v9 審查後的修訂(`h23-review-v9-A` AWC 0/3/16、`-B` REJECT 0/4/16;**與 §17、§18 衝突時以本節為準**)

### 19.1 §17.3 dry-run 臂(取代 §17.3 的起法與殺法;v9 B-M2、A-m1 / m2、B 沙箱 E1 / E8 / E9)
- **起法**:臂前建 `$RUNDIR/autocommit.hold-consumed`(若原本不存在;記錄並於臂後刪),以 `AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1 AUTOCOMMIT_TIMEOUT=1` 起 dry-run。依 v9 B 的沙箱實證(E9,busybox 1.36.1 ash 驅動 autocommit 副本):印完 `mesh join required` 行後約 15 ms 自行結束,不起 watchdog、不進 poll 迴圈(不跑 canary、不寫真名的 `autocommit.why` / `canary-ok` / `wd` / `decided`)。⚠️ 04 的 busybox 版本未確認 → E-H5 加一項:在 04 上照此起一次,斷言 15 s 內程序結束且上述真名檔未新增 / 未變。
- 仍以 `setsid` 起,記下它的 pid(= pgid);結束判定用 `ps -o pid,pgid` 找該 pgid 的程序(**不用 `pgrep -f`**,它會配到 harness 自己的命令列,v9 A-m2 / B E0);15 s 未結束 → `kill -TERM -- -<pgid>` → 再 5 s → `kill -KILL -- -<pgid>`(非硬體持有者)→ 臂判 INVALID。deadman 殺 pgid 前比對該 pgid 的 leader 命令列仍是本 run 的 dry-run(防 pgid 重用)。
- **L38 臂 a**(切換):firmware busybox `FEATURE_SH_NOFORK=y`,`sleep` 不 fork,「pgid 下有 `sleep 1`」永遠不成立(v9 B)→ 改為:dry-run stdout 出現 `gate until` 行之後 ≥ 3 s 仍沒有 `mesh join required` 行(= 在等待迴圈裡)才改寫 `prov-state`。
- 快照清單(臂前記錄、臂後還原並斷言):`$ST/prov-state`、`$ST/ota-armed.mesh`、`$RUNDIR/autocommit.{wd,decided,why,hold-consumed,hold-discarded}`、`$RUNDIR/canary-ok`(若存在)、`$ST/ota-trace.log` 行數。**不假設 `wd` / `decided` 本來不存在**(`tmp-trust-280.sh:71`、`payload-274.sh:78` 會在 committed 開機建它們,v9 B):記錄有無與內容,臂後回到原狀。
- 見證:每個 misc mutant 的見證出現 2 次(檔頭註解 + mutant 的 log 行);bind 後斷言 `grep -c WBOX-misc-LNN /usr/bin/batman-autocommit` = **2**;mutant 臂 stdout 沒有見證行 = INVALID(v9 A-m3 / B)。

### 19.2 L42 / L51 寫入半邊、L11 / L9 / L10(取代 §17.4 對應段)
- L51 的 CI 測試不放 GitHub runner 的一般 job,改放 `dv-sbx`(`ubuntu-24.04-arm` root 沙箱,`unshare -m` + tmpfs / bind 提供 `/opt/batdata`、`/proc/mounts` 的替身、`/lib/functions.sh` stub),以 source 真的 `platform-ab.sh` 驅動 `_ab_arm_mesh`;案例:`lastjoined` 非空 → `joined`;空 + `meshjoin_joined` 真 → `joined`(**fallback 這一案,v9 A-m4**);空 + 假 → `radio`;caller 非 procd → 不寫;upgraded 不在 → 不寫;每次先刪舊檔(`platform-ab.sh:106`)。負對照:去掉 `joined` 分支的副本 → BAD。
- (6a) 的程序(v8 A-m3 / B-m5,v9 A-m13):hold 旗標在 `batman-slot apply` **之前**寫並 `cmp`(apply 會 arm tryboot,`batman-slot:720`);apply 前刪 `ota-armed.mesh` 並斷言 apply 後仍不存在;落點斷言照 `pr_ota_b`(DT tryboot=1、目標槽、`HOLD-COMMIT`、無 DISCARDED);重開用 `reboot`(tryboot 已 armed 時 `batman-slot reboot committed` 退成 plain reboot,`batman-slot:816-826`)。
- **L11**(v9 A-M3):health 的時序不定(`main.go:473` 先起 `go h.Run` 再 `PrepareDir`,失敗 `os.Exit(1)`,`respawn 3600 5 0`)→ 判定改在 socket 層:正向 = restart 後 30 s 內 pid 穩定 ≥ 10 s、`helper.sock` 存在且屬主 / 權限照 §4.5、`provclient info.state` 成功;負對照 = 預放普通檔 → log `sock: unexpected … refusing to start`、30 s 內 `provclient` 連不上 → 刪檔、restart、恢復。副作用(列 §7.2):crash loop 每輪重跑 `boot.Run`、重寫 `prov-state`(第 3 欄沿用,無害)、procd respawn 計數;單位結束斷言恢復且 respawn 已停止。
- **L9**:health ok = `batman-prov.health` 的 boot_id 本次、時間戳 ≤ 15 s、`bluetoothd` pid 欄非 0;負對照照 §17.4。**L10**(dbus 重啟):characterization(只記錄 15 s 內 health 恢復與否,不判 PASS / FAIL):停 dbus 會連帶 bluetoothd / OTS 等,沒有乾淨且有判別力的負對照(v9 A-m5)。
- P9 的 `prov-state` 檢查(v9 A-m15):只在 helper 已安裝且 running(pid 存在)、uptime > 120 s 時檢查;「快照」= `pr_begin` 寫到 `$DVD/<run>/prov-state.snap` 的那一行(沒有 run 時只檢查第 2 欄 = `helper`)。

### 19.3 §18.1 修訂(v9 A-M1 / M2、B-M1 / M3 / M4、A-m8 / m9 / m10 / m11 / m12、B 的 MINOR)
- **位置**:autocommit 的 `why` 摺疊順序寫死為 `HOLDUNSAFE` → `held_commit` → **wbox**(`:509-514` 的 if/elif 末端)。wbox + hold 的 trial 仍印 `is healthy and HELD`、`otalog AC HELD`;只有沒有 hold 時才出現 `WBOX-NOCOMMIT`(僅在 `ok ≥ NEED` 時記一次)。**所有「預期 REVERT」的單位**(autocommit (1)、(7) 04 側等)加斷言:`TRIAL-REVERTED … reason=` 不得含 `wbox test image`,含了 = FAIL「hold 沒寫成 / DISCARDED,判定被 wbox 閘頂替」。
- **判斷 wbox**:讀 `/rom/etc/batman-build`(squashfs 下層,root 也改不了;overlay 的 `/etc` 版本可被改),`BATMAN_WBOX=` 非空 **或** `BATMAN_VERSION` 含 `.wbox-` → wbox;**讀不到 / 解析不了 → 當成 wbox(fail-closed,v9 B)**:release image 一定有此檔(gate 保證),讀不到本身就是異常,不 commit、期限 revert。
- **`batman-slot rollback` 也拒絕**(v9 A-M2 / B-M4):`cmd_rollback` 在換預設槽前唯讀掛載目標槽的 squashfs(它本來就會,`batman-slot:771-797`),讀其 `etc/batman-build`,是 wbox(同上規則)→ `die "slot <X> holds a -wbox test image: never made the default"`;`batman-slot commit` 同樣讀**當前槽的** `/rom/etc/batman-build`。**沒有逃生口**(`BATMAN_SLOT_ALLOW_WBOX` 作廢;§6.2 沒有任何單位需要 commit / rollback 到 wbox 槽,v9 A-m8)。
- **stale-fallback**:裝置若以非 trial 方式開進 wbox 槽(tryboot 失敗回落等),autocommit 不是 trial → 不 commit 也不 revert;P9 的「committed 槽含 wbox → run FAIL」照 §4.2 抓到並印 brewrite 指令。
- **承載與流程**(v9 A-m12):§18.1 屬產品,放 PR-P1b(`feat/254-p1b-seams`,batman-provision 的 autocommit / batman-slot);照 §16.18 重切 rc、重 build 全部 wbox payload;P1b 的程式碼審查(兩位)與安全審查對這段 diff 再跑一次。
- **舊 payload 隔離**(v9 A-m10):主機 `~/out` 裡本閘之前 build 的 wbox payload 搬到 `~/out/quarantine-pre-nocommit/`;`pr_ota_b` 推送前斷言 payload 的 rootfs `usr/bin/batman-autocommit` 含 `WBOX-NOCOMMIT` 字串(沒有 → 拒推)。
- **CI**:`scripts/test-autocommit-wbox.sh`(stub `/rom/etc/batman-build`、`batman-slot`、健康)案例:wbox 無 hold → 不 commit、`WBOX-NOCOMMIT`;wbox + hold → HELD(不是 wbox);非 wbox → commit;讀不到 → 不 commit;dry-run + wbox → `DRYRUN decision: COMMIT`。`batman-slot` 的 commit / rollback 拒絕以 `dv-sbx` 驅動(要 loop 掛 squashfs)。負對照:閘拿掉 → BAD;閘擺在 hold 前 → wbox + hold 案 BAD。
- **節點單位 `prov-wbox-nocommit-254`**(v9 B-M3、A-m11):**不做「commit 舊 wbox image」的負對照**(違反 §4.2 / §16.18,負對照只放 CI)。正向:02 在 `batctl n`(前置)→ OTA `96-noprov`(本閘之後 build)**不設 hold**(§4.2「一律 hold」的明列例外,只此一單位)→ B trial 健康 → `WBOX-NOCOMMIT` + 期限 revert(`reason=wbox test image`)→ 回 A;再在 A 上 `batman-slot rollback`(目標 = 含 wbox 的 B)→ 被拒絕、預設槽不變。安全網:若出現 `COMMITTED`(閘回歸)→ 立即 `batman-slot rollback`(目標 = A,非 wbox,允許)+ `pr_needs_person`。成本:1 次 trial(到期 revert 約 10 分)+ brewrite 約 14 分 ≈ 25 分;**超出 H3-U3 核准成本 — 使用者 2026-10-28 決定:做**(本單位納入 §6.2 與全套)。
- **F2–F5 的負測試**(v9 A / B):F2 `local-ab-tar.sh` 對帶 seam 的 rootfs → 拒絕打包(gate 自測加一案);F3 正常模式 helper 換路徑的 prov_test binary → gate FAIL(自測加一案);F4 staged 殘留 / 非 ASCII 檔名殘留 → `wbox_normal_check` 拒絕(lib 測試加兩案);F5 gate 不再讀環境的 `WBOX_DIR` / `GO`,只讀自測專用的 `PROV_GATE_SELFTEST_WBOX_DIR` / `PROV_GATE_SELFTEST_GO`(build-board、local-ab-tar、CI 直接呼叫時都不會繼承);自測加「環境有 `WBOX_DIR` 指向偽 helpers.list」→ 仍 FAIL 一案。
- **擁有權補列**(v9 A-m16):p6 `ota-armed.mesh` 的刪者另有 `_ab_arm_mesh`(每次 `platform_check_image` 先刪,`platform-ab.sh:106`)。
- §6.2 `prov-misc-254` 列的型欄改為 `— / A / F`(不做 OTA,v9 A-m13);§7 actor 表加「操作員誤推 wbox payload」一列 → §18.1;§7.3 build 數 = 13 + 4(misc)+ normal / test = 19 / rc。
- §10 回報上層(v8 A-m7、v9 A-m13 / B-m12):p1-impl §4 / `:288`、`:377` 的 misc 作法改為 §17(autocommit mutant + dry-run,不 OTA mutant 槽);§18.1 為 P1 新增的產品閘。
- bcm2710:不適用(CM4 決定);兩個 PR body 照慣例各有 `### bcm2711` / `### bcm2710` 兩節(後者寫明不適用與理由)。

## 20. v10 審查後的修訂(`h23-review-v10-A` AWC 0/2/14、`-B` AWC 0/1/11;**本節優先於前文全部,含 §1.4 / §4.2 / §7 的「一律 hold」與 §17–§19**)

### 20.1 dry-run 臂的結束判定與計時(v10 A-M1、B-m1 / m2)
- 04 的 busybox 沒開 `CONFIG_DESKTOP`,`ps -o` 不可用(`ps.c:670`),image 無 procps-ng → 判定改為掃 `/proc/[0-9]*/stat`:第 6 欄(session id)= dry-run 的 setsid leader pid 者即為同一組;讀不到 `/proc` 或解析失敗 = **INVALID**(不是「已結束」)。
- 計時:從 stdout 出現 `mesh join required` 行時起算,其後 15 s 內該 session 必須清空,否則 TERM → 5 s → KILL 整個 session(`kill -- -<pgid>`;setsid leader 的 pgid = sid)→ INVALID。整臂另有硬上限:L38 臂 a / b 90 s,其他臂 30 s(從起動算),超過 → 同上殺法 → INVALID。
- L38 臂 b 的「≥ 60 s」以**節點 uptime** 量(臂前、判定行出現時各讀一次 `/proc/uptime`),門檻 ≥ 58 s(`:404` 迴圈 60 × `sleep 1` 加讀檔時間;WSL 實測 uptime 60.04 s、`date` 58.13 s)。
- L38 臂 a:真程式在 `gate until` 行後 3 s 內就出判定行 → INVALID(沒走過切換)。
- `hold-consumed` 是承重的:臂前斷言 p6 **沒有** hold 旗標(有 → 會建真名 `hold-discarded`,前置失敗)、gate 行含 `revert=0`(由 hold-consumed 造成的不 revert 路徑);stdout 必須有 `hold present` 類行(依 autocommit 實際字串,實作時抓原文)→ 沒有 = INVALID。快照清單再加 `$RUNDIR/autocommit.ctl.dry`、`$RUNDIR/autocommit-dryrun.log`。deadman 也刪 dry-run 建的 `hold-consumed`(否則 `halow-status:136-146` 給操作員誤導訊息)。

### 20.2 變體名一律小寫(v10 A-M2)
`misc-L38` / `misc-L42` / `misc-L43` / `misc-L51` → **`misc-l38` / `misc-l42` / `misc-l43` / `misc-l51`**;見證 `WBOX-misc-lNN-<8 hex>`。`lint-wbox` 名稱規則 `[a-z0-9-]`、gate 的見證 regex `WBOX-[a-z0-9-]+-[0-9a-f]{8}` 不變。§17 / §19 所有大寫寫法以此為準。

### 20.3 `prov-wbox-nocommit-254` 的 rollback 臂與安全網(v10 B-M1、A-m4 / m5)
- rollback 臂**整段在一條節點端指令內**完成:記下 `batman-slot` 的預設槽(`[all]`)→ `batman-slot rollback`(目標 = 含 wbox 的 B)→ PASS 條件三者皆真:rc ≠ 0、輸出含 `holds a -wbox test image`、`[all]` 未變。
  - rc ≠ 0 但訊息不是那句(`assert_fw_sane`、`slot_is_bad`、lock gate、`power_ok` 等)→ **INVALID**。
  - rc = 0 或 `[all]` 變了(閘回歸)→ **同一條指令內**立刻 `batman-slot commit`(此時跑在 A,A 非 wbox,允許)並讀回 `[all]` = A;仍不是 A → 不重開、`pr_needs_person`(印出手動恢復指令)。之後才回主機判 FAIL。
- trial 期間若出現 `COMMITTED`(autocommit 閘回歸):harness 立刻在 B 上 `batman-slot rollback`(目標 = A,非 wbox,允許)→ `batman-slot reboot committed` → 斷言回 A;失敗 → `pr_needs_person`。
- 判定看 `otalog AC WBOX-NOCOMMIT`(只在 `ok ≥ NEED` 時記),不看 `TRIAL-REVERTED reason`(最後一輪可能因 mesh 抖動變成 `mesh lost`);沒有 `WBOX-NOCOMMIT` 而 reason 是 mesh 類 → INVALID(重跑一次)。
- 「不設 hold」的例外有機制:`pr_ota_b` 的 `nohold` 參數只在單位名 = `prov-wbox-nocommit-254` 時接受,`lint-install` 加規則掃 `scripts/dv/` 確認只此一處使用。
- 前置:02 在 `batctl n`;p6 無殘留 hold 旗標。

### 20.4 產品閘的細節(v10 B-m3 / m4 / m6 / m7、A 的 MINOR)
- `cmd_rollback` 的 wbox 檢查是**獨立函式、在 `rollback_lock_gate` 之前無條件執行**:legacy 狀態在 `:775-776` 提早 return、`UNLOCKED_ROLLBACK`(env 或 `/tmp` 旗標)在 `:777` 提早 return,檢查若塞進 lock gate 就會被這兩條繞過(v10 B-m3)。目標槽唯讀掛載以讀 `etc/batman-build`(同 lock gate 的掛載法);掛不上 / 讀不到 → 拒絕。既有 `tests/prov-p1/batman-slot-rollback-gate.sh:61`(legacy 時「目標槽不讀」)同步改為「目標槽一律讀 batman-build、lock 部分仍不讀」。
- 讀不到 `/rom/etc/batman-build` 用**獨立字串**:`build stamp unreadable (/rom/etc/batman-build) — not committing (deadline revert armed)` + `otalog AC STAMP-UNREADABLE`,不寫成 wbox(v10 B-m4)。failsafe 開機沒有 `/rom`,但 failsafe 不跑 autocommit(不影響)。`cmd_commit` 讀當前槽的 `/rom/etc/batman-build`;`cmd_rollback` 讀目標槽掛載點內的檔。
- 跨閘降級(v10 B-m6):rollback 的防線在**執行中的槽**的 `batman-slot`;節點若跑不含閘的版本(wsl.4 / wsl.9 等),rollback 到 wbox 槽不會被擋 → §5 增列此路徑;P9 對「另一槽含 wbox」除了印 brewrite 指令外,另印「本槽版本不含 rollback 閘,勿 rollback」提醒。
- `back_to_a`(`brewrite-254.sh:13`、`negctl-old-slot-254.sh:30`)遇 rollback 被拒時記錄 stderr(原本靜默 rc 0,v10 B-m7);行為不變(trial 期限 revert 是安全結果)。
- `lint-wbox` 加規則:patch 不得刪改含 `wbox_image`、`WBOX-NOCOMMIT`、`STAMP-UNREADABLE`、`holds a -wbox test image` 的行(mutant 不能拆掉閘);`pr_ota_b` 拒推 `misc-*`(只做 bind 用)。

### 20.5 F5 的機制(v10 A、B-m10)
環境變數一定被子程序繼承,改名不夠 → gate 的覆寫**只走命令列**:`check-prov-test-gate.sh ROOTFS [NAME] [--selftest-wbox-dir DIR] [--selftest-go GO]`,不讀任何環境變數的 `WBOX_DIR` / `GO`;`test-prov-test-gate.sh` 以參數傳入。負測試:環境設 `WBOX_DIR` 指向偽 helpers.list、`GO=/bin/echo` → gate 仍 FAIL。CI stub `/rom`:在 `dv-sbx` 的 mount namespace 以 tmpfs 提供,**產品不加任何 env 覆寫**。

### 20.6 §17 / §19 的其餘修正(v10 A-m10、B-m8–m11)
- L9:health ok = `batman-prov.health` 的 `bluetoothd=1`(`health.go:4,138`)、boot_id 本次、時間戳 ≤ 15 s。
- L11:前置斷言無 `.txn`(crash loop 的 `boot.Run` 會處理 `.txn`)。
- L3:負對照引用**同一全套**中 `prov-powerloss-254-txn*` 單位產生的 sysrq 開機記錄(`hints: sysrq`),不引用 E-H6。
- L51 / L38 臂 c 標為「判定半邊」(寫入半邊見 §19.2);見證行位置:autocommit mutant 的 log 行緊接在被改的那一行之後。
- L42 寫入半邊另加靜態檢查:CI 掃 `feed/batman-provision/files/`,寫 `ota-armed.mesh` 的只能是 `platform-ab.sh` 的 `_ab_arm_mesh`(刪除者另列)。
- L27 / L10 副作用列入 §7.2(dropbear 重啟斷開既有 ssh 連線、dbus 重啟連帶 bluetoothd / OTS 重連)。
- §5 增列:L11 crash loop、跨閘降級、rollback 臂閘回歸;§7 actor 表增列「操作員誤推 / 誤 rollback wbox payload」→ §18.1 / §19.3 / §20.3–20.4。
- 文件標頭(第 1–3 行)更新為 v11。

### 20.7 成本(v10 A-m6;**需使用者重新確認**)
`prov-wbox-nocommit-254` 照 §7.3 revert 型算法:OTA + 期限 revert(≈ 37 分,含 600 s deadline)+ rollback 臂(≈ 2 分)+ brewrite(≈ 14 分)≈ **47–57 分**,不是 §19.3 寫的 25 分。使用者 2026-10-28 的「做」是依 25 分的估計,需再確認。

## 21. v11 審查後的修訂(`h23-review-v11-A` AWC 0/1/12、`-B` AWC 0/0/8;**本節優先於前文全部**)

### 21.1 rollback 臂(`prov-wbox-nocommit-254`)— 撐過斷線、前置、判定順序(v11 B-m1 / m2 / m3、A-m4 / m5 / m12)
節點端以**一個 detached 程序**執行,harness 只輪詢結果檔:
```
trap '' HUP PIPE; setsid sh -c '<arm>' </dev/null >"$RUNDIR/dv-rbarm.<run>" 2>&1
```
`<arm>` 的步驟(順序寫死):
1. 前置(任一不成立 → `RESULT=INVALID <why>`,**不做 rollback**):`grep -q 'holds a -wbox test image' /usr/sbin/batman-slot`(A 帶閘;否則 = pre-gate image,單位在**任何 OTA 之前**就印 `FAIL pre-gate image` 並停,v11 A-m5 / B-m2);p6 `slot-B.protected` = 本次 wbox 版本(B 仍是 wbox,brewrite 之前);`a0 = bf_ab_all`(`bootfacts.sh:43`)是合法值(1 或 2 的 fw 分割區,其餘 → INVALID);uptime 與電源 `power_ok` 正常。
2. `batman-slot rollback`,記 rc、輸出。
3. `a1 = bf_ab_all`。**第一件事永遠是回補檢查**:rc = 0 **或** `a1 ≠ a0` → `batman-slot commit`(此時跑在 A;每 5 s 重試、共 3 次,應付 `power_ok` 欠壓 die,`batman-slot:278-300`)→ 讀回 `a2 = bf_ab_all` = A → `RESULT=FAIL-RECOVERED`;仍不是 A → `RESULT=FAIL-NEEDS-PERSON`(不重開)。`write_autoboot` 是先寫後讀回(`:357-361`),「寫了 `[all]` 才失敗、訊息不是 wbox」也會走到這裡(v11 A-m4)。
4. 回補檢查通過後才分類:rc ≠ 0 且輸出含 `holds a -wbox test image` → `RESULT=PASS`;rc ≠ 0 而訊息是 `build stamp unreadable` 之類或其他 → `RESULT=INVALID <msg>`。
- harness 輪詢結果檔(最多 120 s);沒有結果檔 → 讀 `bf_ab_all`:≠ A → 立即執行同一回補(另一個 detached 程序)並 `pr_needs_person`。
- 白箱測試(dv-sbx + 節點一次):臂執行中殺掉 ssh → 結果檔仍寫出 `FAIL-RECOVERED`(以 stub 回歸的 batman-slot 驗回補)。
- §5 增列:臂中 ssh 斷線 / harness 死 / 斷電 → detached 臂繼續或在下次開機由 P9 抓。
- **P9 新增**(v11 A MAJOR-1 表、B-m1):`bf_ab_all` ≠ 執行中的槽,且它指向的槽的 `slot-X.protected` 或掛載後的 `etc/batman-build` 含 wbox → run FAIL,印 `batman-slot commit`(在執行中的非 wbox 槽上)恢復指令。

### 21.2 產品閘的字串與清理(v11 B-m3、A-m9)
- `cmd_rollback` 讀不到目標槽的 batman-build → `die "slot <X> build stamp unreadable — refusing to make it the default"`(與 wbox 那句不同);`cmd_commit` 讀不到 `/rom/etc/batman-build` → `die "this slot's build stamp is unreadable (/rom/etc/batman-build) — not committing"`。
- 每條路徑都 `umount` + `rmdir`(照 `:778-782` 寫法);dv-sbx CI 斷言沒有殘留 `/tmp/.rb*`。
- `lint-wbox` 保護字串清單 = `wbox_image`、`WBOX-NOCOMMIT`、`STAMP-UNREADABLE`、`holds a -wbox test image`、`build stamp unreadable`。
- failsafe 開機:沒有 `/rom` → 操作員 `batman-slot commit` 被拒(訊息如上);failsafe 本來就不做 commit,寫進 §5。

### 21.3 `/proc` 掃描與 dry-run 細節(v11 B-m4、A-m1 / m2 / m3 / m10)
- 單筆 `/proc/<pid>/stat` 讀不到(程序剛結束)→ 略過該筆;只有 `/proc/self/stat` 讀不到或整輪 0 筆可讀 → INVALID。欄位從最後一個 `) ` 之後解析(`comm` 可含 `)` 與空白)。
- sid 從 dry-run 程序**自己**的 stat 讀(busybox `setsid` 在呼叫者已是組長時會 fork,launcher 的 pid ≠ sid);起動後第一次掃描必須 ≥ 1 個成員,否則 INVALID(不能把「找不到」當「已結束」)。
- `comm` 偽裝只造成 DoS(多算成員 → 逾時 → INVALID),fail-safe;記入 §7。
- `hold present` 行整行比對:`hold present — this trial will not be reverted`(`batman-autocommit:372`;前綴會誤配 watchdog 的 `:190,202,234`)。
- 臂 b 的時間在**節點端**取(臂內的 shell 迴圈讀 `/proc/uptime`,與判定行一起寫進結果檔),不靠主機輪詢。
- 前置另加:本次開機沒有 `batman-fw-override`(否則 dry-run 在 `:314` 就結束)。
- dry-run stdout 與結果檔放 `$DVD/<run>/`(root 0700)。
- 刪 `hold-consumed` 的理由更正:避免後續真 trial 被誤判已消費(`halow-status` 只在 `autocommit.ctl/hold-commit` 存在時顯示,與此無關)。
- churn 白箱:dry-run 執行中背景大量起落短命程序,掃描結果仍正確。

### 21.4 見證位置與 mutant 的範圍(v11 A-m3、B-m6)
- 見證行放在**必經且語法安全**的位置:`misc-l38` 放在被刪的 `:404` 原位(一行 `log`);`misc-l42` / `-l43` / `-l51` 放在 `:417` 之後(member 分支進入時)。`lint-wbox` 對 shell 檔另跑 `sh -n`(實測 `;;` 之後插行 → `syntax error`)。
- `lint-wbox` 檔案範圍規則:只有 `misc-*` 可以碰 `feed/batman-provision/files/usr/bin/batman-autocommit`;**任何變體都不得碰** `usr/sbin/batman-slot`;`pr_ota_b` 斷言推送 payload 的 rootfs 內這兩檔的 sha 與同一 rc 正常 build 相同(取代只查字串)。
- nohold 例外的檢查放 `lint-wbox`(不是不存在的 `lint-install`,v11 A-m7 / B-m8):`scripts/dv/` 內 `pr_ota_b … nohold` 只准出現在 `prov-wbox-nocommit-254`。

### 21.5 F5 的負測試(v11 B-m5)
- sentinel:環境 `GO` / `WBOX_DIR` 指向「一被執行 / 讀取就建檔」的東西 → 斷言 sentinel 檔沒被建,且 gate 輸出與不設 env 時逐位元組相同。
- gate 先解析 `--selftest-*`,遇未知 `--*` → FAIL(`--selftest-wbox-dir` 能過名字的 `[a-z0-9-]` 檢查,必須先當旗標吃掉)。
- lint:`--selftest-` 只准出現在 `test-prov-test-gate.sh`。

### 21.6 其他
- 判定行限定本次 trial(v11 A-m6):`WBOX-NOCOMMIT`、`TRIAL-REVERTED` 只取 `boot=<本次 trial boot8>` 的行(`otatrace.sh:28` 每行帶 `boot=`)。
- 既有 `tests/prov-p1/batman-slot-rollback-gate.sh:61` **不改**(它只抽 lock gate 一個函式,v11 A-m8);另加順序測試:`cmd_rollback` 內 wbox 檢查行在 `rollback_lock_gate` 呼叫之前。
- 回補 commit 會觸發 `addr_defer_release`(背景重啟 openmanetd),列 §7.2(v11 A-m12)。
- §11 待決:成本已由使用者 2026-10-28 再確認(47–57 分,做);§7.3 總成本更新為約 23–24 h(含本單位)。

### 21.7 遺留項目總表(v11 A MAJOR-1、B-m7;**每項標「已改」或「殘項 → #254」**)

| 來源 | 項目 | 處理 |
|---|---|---|
| v10 A-M2 | gate 自測加小寫 misc 見證一案 | 已改(實作時加,§21.4) |
| v10 A-m7 | failsafe 下 commit 被擋、`cmd_commit` 拒絕字串 | 已改 §21.2 |
| v10 A-m10 / v11 B-m7(3) | L51 正向檔 = L43 對照檔,只改第 3 欄(`radio` → `joined`) | 已改(本表即規格) |
| v10 A-m10 | L38 臂 c 標 characterization(boot_id 不符 → 今天規則;無 mutant) | 已改(本表即規格) |
| v10 A-m10 / v11 B-m7(2) | (6a) 的「apply 後無 arm 檔」標 characterization 以外的斷言:保留為斷言,負對照 = §17.4 L42 的白箱 radio 檔臂 | 已改(本表) |
| v10 A-m10 / v11 B-m7(9) | §5:(6a) 在 apply 與重開之間死掉 → tryboot 已 armed + hold 已寫(§19.2 順序)→ 重開進 held trial → 期限 revert | 已改(本表) |
| v10 A-m10 / v11 B-m7(8) | §7 actor 表:「bind 覆蓋 root 的 autocommit / 白箱寫 p6」→ 只在 dry-run 臂期間、lease 內;deadman 解除 | 已改(本表) |
| v10 A-m11 / v11 B-m7(4) | CI 加「`BATMAN_WBOX=` 有但值空 → 非 wbox」、「只有 `BATMAN_VERSION` 含 `.wbox-` → wbox」兩案 | 已改(本表;實作時加) |
| v10 A-m12 / v11 B-m7(11) | hold-once + wbox:hold-once 消費後仍不 commit(wbox 閘在 hold 之後,hold-once 只影響 hold);`release --wait` 遇 wbox 一定逾時 → 文件註明、harness 不對 wbox 槽用 `release --wait` | 已改(本表) |
| v10 A-m12 / v11 B-m7(11) | 會讓某槽成為 committed default 的路徑:autocommit commit、`batman-slot commit`、`batman-slot rollback`、`sysupgrade`(apply 不改 default)、firstboot 寫卡 —— 前三者有 wbox 閘;sysupgrade 只寫非 committed 槽;寫卡不帶 wbox(`--card-only --wbox` 被拒) | 已改(本表) |
| v10 A-m14 / v11 B-m7(12) | §4.2 DISCARDED → 已 committed 的分支:有閘之後只剩「閘回歸」才會發生 → 同 §21.1 回補 + `pr_needs_person` | 已改(本表) |
| v10 B-MAJOR-1 修法 5 | P9 `[all]` 檢查 | 已改 §21.1 |
| v10 B-m3 | 「補救 = 對該槽 apply release」 | 已改:P9 的恢復指令 = 在非 wbox 槽上 `batman-slot commit`;另一槽留 wbox 由 brewrite 覆蓋(§4.2) |
| v10 B-m4 / v11 B-m7(13) | **E-H5 上機確認 `/rom`**:04 A committed 與一次 B trial 都 `grep ' /rom ' /proc/mounts; cat /rom/etc/batman-build` | **實作 §18.1 之前做**(列入 E-H5;不成立 → 改設計) |
| v10 B-m6 | pre-gate 單位在任何 OTA 前停 | 已改 §21.1 前置 |
| v10 B-m8 | L9 `hci0_powered=1` | 殘項 → #254(健康欄位語意已足,可接受) |
| v11 B-m7(1) | dv-sbx 的 L51 stub:`meshjoin.sh`、`_ab_live_sysupgrade`、`RUNDIR` | 已改:§19.2 的 dv-sbx 測試以函式覆寫 stub 這三者(本表即規格) |
| v11 B-m7(5) | prov-misc 期間不得有 `sysupgrade -T` | 已改:前置斷言無 sysupgrade 程序、單位期間 harness 不呼叫 |
| v11 B-m7(7) | L27 重連方式與判定 | 已改:dropbear 重啟後新開 ssh(lab key)執行 `true` 成功 = PASS;負對照照 §17.4 |
| v11 B-m7(10) | failsafe 下操作員 commit 被擋 | 已改 §21.2 |
| v11 A-m11 | 成本確認與 §7.3 | 已改 §21.6 |

## 22. v12 審查後的修訂(`h23-review-v12-A` AWC 0/1/12、`-B` AWC 0/0/9;**本節優先於前文全部**)

### 22.1 rollback 臂的完整規格(取代 §21.1 的對應文字)
- **節點上不放 stub**(v12 A-MAJOR-1):stub `batman-slot` 的回歸 / 回補測試**只在 dv-sbx**。節點上證明「撐過斷線」的方法:臂腳本開頭 `sleep 10`,harness 在這 10 s 內殺掉 ssh;臂接著執行**真的** `/usr/sbin/batman-slot rollback`(A 帶閘 → 被拒)→ 結果檔仍寫出 `RESULT=PASS`。不碰 `[all]`、不 bind 任何東西。
- 臂 stage 成 `$DVD/<run>/rbarm.sh`(root 0700;執行中不改寫),以 `trap '' HUP PIPE; setsid sh $DVD/<run>/rbarm.sh </dev/null >$DVD/<run>/rbarm.out 2>&1 &` 起動(ssh 立即返回);臂第一行寫 `$$` 到 `$DVD/<run>/rbarm.pid`(v12 A-m3 / B-m1)。
- 前置(任一不成立 → `RESULT=INVALID <why>`、不做 rollback;v12 A-m2 / B-m2):
  - `grep -q 'holds a -wbox test image' /usr/sbin/batman-slot`(A 帶閘;否則單位在任何 OTA 前印 `FAIL pre-gate image` 並停);
  - `batman-slot active` = A、`batman-slot is-trial` rc = 1;
  - `a0 = bf_ab_all` = `$(batman-slot fw-part A)`(不只是「1 或 2」);
  - p6 `slot-B.protected` = 本次 wbox 版本;
  - 電源:`vcgencmd get_throttled` bit 0 = 0,取樣 3 次(照 `batman-slot:285-293` 的規則;`power_ok` 是內部函式,不能呼叫)。
- 步驟 2–4 同 §21.1;回補一律呼叫絕對路徑 `/usr/sbin/batman-slot commit`;前後各記一次 `[tryboot]`;回補之後斷言 openmanetd running(`addr_defer_release` 會背景重啟它,v11 A-m12)。
- harness 輪詢條件 = `rbarm.out` 內出現 `^RESULT=` 行(檔案一起動就存在、內容空);120 s 未出現 → `kill -0 $(cat rbarm.pid)`:還活著 → 再等最多 60 s(不另起回補,避免撞 `slot_lock`,`batman-slot:84-96`);已不在而仍無 `RESULT=` → 讀 `bf_ab_all`,≠ `fw-part A` → 另起同一回補腳本並 `pr_needs_person`。
- `FAIL-NEEDS-PERSON` 的通知文字(v12 B-m3):「`[all]` 指向 wbox 槽:先排除電源問題再在 A 上 `batman-slot commit`;在那之前**不要重開**」。
- 回歸窗口(rollback 已寫、回補未做)斷電 → 下次以 `[all]` 開進 committed 的 wbox B(非 trial,autocommit 不評估)→ 既有 P9「執行中槽含 wbox → FAIL」抓到;**恢復指令改為**在 B 上 `batman-slot rollback`(目標 A,非 wbox,允許)+ `batman-slot reboot committed`,不是 brewrite(v12 B-m3)。§5 增列此路徑。

### 22.2 P9 的 `[all]` 檢查(取代 §21.1 的 P9 段;v12 A-m4 / B-m4)
- 只在 Pi 4(`bf_pi4` = yes;bcm2710 無 `/boot/autoboot.txt`,不適用)。
- `x = bf_ab_all`;空值 / 非 1 / 2 → **FAIL**(fail-closed)。
- `x` = `$(batman-slot fw-part "$(batman-slot active)")` → 不觸發。
- `x` ≠ 執行中槽的 fw-part:找出 `x` 對應的槽 S;S 的 `slot-S.protected` 含 wbox,或(`.protected` 缺時)以 `mktemp -d` 唯讀掛載 S 的 squashfs 讀 `etc/batman-build` 含 wbox → FAIL,印「在本槽(非 wbox)`batman-slot commit`」;讀不到 → FAIL;S 不是 wbox → WARN 並列出(stale fallback / Pi 4 EEPROM 開錯槽)。
- 不誤觸發的情況(已由 v12 B 對照原始碼):一般 committed、release trial(跑 B、`[all]`=A)、mid-OTA(apply 只寫 `[tryboot]`,`:720`)。
- `test-dv-preflight.sh` 加三案:`[all]` 指向含 wbox 的另一槽 → FAIL;正常 release trial → PASS;`[all]` 讀不到 → FAIL。

### 22.3 dry-run 的 sid 與臂 a(v12 A-m1、B-m7、A-m11(1)(2))
- 起法:`setsid sh -c 'echo $$ > $DVD/<run>/dry.pid; exec env … batman-autocommit run' > $DVD/<run>/dry.out 2>&1 &`。sid 的預期值 = `dry.pid` 的內容;在 ≤ 2 s 內輪詢 `/proc/<pid>/stat` 直到第 6 欄 = pid 才開始計時(立即讀會讀到 launcher 的 session:沙箱 185/200 次),超時 → INVALID。
- 「在場」證據 = 曾讀到 sid = pid **或** `dry.out` 已有任一 `batman-autocommit` 行(短命臂可能在第一輪掃描前結束,不要求掃描抓到)。
- 臂 a 的「`gate until` 行後 ≥ 3 s 無判定行」在**節點端**迴圈判(同臂 b),結果寫進 `dry.out` 旁的 `arm-a.verdict`。
- `hold present — this trial will not be reverted` 行必須出現在 `gate until` 行**之前**,否則 INVALID。
- `hold-consumed` 的刪除理由更正(v12 A-m8):`RUNDIR` 是 tmpfs,真 trial 必在另一次開機、看不到它;刪除是為了同一次開機內後續的 dry-run 臂從乾淨狀態開始。

### 22.4 lint 與 sha(v12 A-m5 / m6、B-m5 / m8)
- 受保護集合 = `usr/sbin/batman-slot`、`usr/bin/batman-autocommit`、`etc/init.d/batman-autocommit`、`usr/lib/batman/{otatrace,rundir,bootfacts,meshjoin}.sh`(兩支程式 source 的檔,`batman-slot:51,62,812`、`batman-autocommit:42,111,113,358`)。`lint-wbox`:非 `misc-*` 不得碰集合內任何檔;`misc-*` 只准碰 `usr/bin/batman-autocommit`。負對照:改 `otatrace.sh` 的假 patch → FAIL。
- `pr_ota_b`:推送 payload 的 rootfs 內受保護集合的 sha = 同一 rc 正常 build,**並且**保留 §19.3 的 `WBOX-NOCOMMIT` 字串檢查(兩者並存;正常 build 若是 pre-gate 舊產物,sha 相同不代表有閘)。
- `sh -n` 用 **busybox ash**(CI 的 `sh` 是 dash);負對照:「`;;` 之後插行」的 patch → lint FAIL。
- 兩條「只准出現在…」的 lint 明列豁免的定義檔:
  - `nohold`:只准出現在 `prov-wbox-nocommit-254`,豁免 `scripts/dv/prov-254.sh`(`pr_ota_b` 的定義);負對照:第二處呼叫 → FAIL。在 Batman repo 的 `lint-wbox`。
  - `--selftest-`:只准出現在 `scripts/test-prov-test-gate.sh`,豁免 `scripts/check-prov-test-gate.sh`(解析處);在 **firmware repo** 的 CI;另斷言 `build-board.sh` / `local-ab-tar.sh` 不傳 `--selftest-`。

### 22.5 F5 sentinel 的機制(v12 A-m7、B-m8c)
- `GO`:指向「一執行就 `touch` sentinel」的腳本(v11 B R3 已證)。
- `WBOX_DIR`:`$WBOX_DIR/helpers.list` 做成 FIFO,背景寫者在對端 open 成功後 `touch` sentinel 並寫入偽內容;gate 呼叫加 `timeout 30`。新 gate:sentinel 不存在、輸出與不設 env 時逐位元組相同。舊 gate:會開 FIFO → sentinel 被建(或阻塞到逾時)→ 負對照成立。

### 22.6 其他
- `COMMITTED` 行也只取 `boot=<本次 trial boot8>`;harness 沒拿到本次 trial 的 boot8(trial 內沒找到節點)→ INVALID(v12 A-m11(4)、B-m6)。
- §19.3 的 stale-fallback 文字更正(v12 A-m9):非 tryboot 開進非 committed 槽時 `is-trial` 回 0,autocommit 印 `will commit when healthy, will NOT reboot`(`:363`)並在條件成立時走 commit 分支(`:367-381`);wbox image 不 commit 是因為 wbox 閘摺在共用的 `why`(`:509-514`)。CI `test-autocommit-wbox.sh` 加「REVERT=0 stale fallback + wbox → 不 commit、不 revert」一案。
- **E-H5 完整清單**(取代 §8 的 E-H5;v12 A-m10 / B-m9):
  1. `lock-hold` + helper `--save` 撞鎖(原文);
  2. OTS 節點上 pre-commit canary 的時間(§15);
  3. 04 busybox 上 §19.1 / §22.3 的 dry-run 起法自行結束、真名檔不變;
  4. `/rom/etc/batman-build`:A committed ✅(2026-10-28 實查:`/dev/root /rom squashfs ro`、檔可讀、與 `/etc` 相同);B trial 那一次搭 `prov-ota-254` 的 held trial(`grep ' /rom ' /proc/mounts; cat /rom/etc/batman-build`)。
- 負對照補齊(v12 A-m11 / B-m9):test-dv「stub 舊版 `batman-slot` → 不推送、印 `FAIL pre-gate image`」;nohold 第二處 → lint FAIL;回補後 openmanetd running 斷言(§22.1)。

### 22.7 v12 全部發現的處理表

| 發現 | 處理 |
|---|---|
| A-MAJOR-1 節點 stub 白箱無規格 | §22.1:節點不放 stub;節點只證斷線(真 rollback 被拒 → PASS) |
| A-m1 sid 競態 / 第一輪掃描 | §22.3 |
| A-m2 a0 前置、`power_ok`、`[tryboot]` | §22.1 |
| A-m3 結果檔位置 / 語意 / 引號 / 二次回補 | §22.1 |
| A-m4 P9 比較方式、讀不到、非 wbox、fixture | §22.2 |
| A-m5 lint 擋到定義處、`sh -n`、負對照 | §22.4 |
| A-m6 sha 閉包、保留字串檢查 | §22.4 |
| A-m7 F5 `WBOX_DIR` sentinel | §22.5 |
| A-m8 `hold-consumed` 理由 | §22.3 |
| A-m9 stale-fallback 文字 | §22.6 |
| A-m10 E-H5 清單 | §22.6 |
| A-m11(1)–(7) | (1)(2) §22.3;(3)(5)(6) §22.6;(4) §22.6;(7) 改為「實作時加」,列入實作 checklist(§22.8) |
| A-m12 殘項沒登記 | 已登記 #254 留言 6460421575(`hci0_powered`、dry-run watchdog 副作用) |
| B-m1 結果檔 | §22.1 |
| B-m2 前置 | §22.1 |
| B-m3 斷電恢復指令 / NEEDS-PERSON 文字 | §22.1 |
| B-m4 P9 | §22.2 |
| B-m5 受保護集合 | §22.4 |
| B-m6 `COMMITTED` 限 boot8 | §22.6 |
| B-m7 dry.pid、臂 a 節點端 | §22.3 |
| B-m8 busybox `sh -n`、`--selftest-` 豁免、sentinel | §22.4、§22.5 |
| B-m9 負對照與殘項記帳、E-H5 | §22.6;#254 已登記 |

### 22.8 實作 checklist(本設計要求、易漏的項目)
- [ ] gate 自測加小寫 misc 見證一案(v10 A-M2)
- [ ] CI:`BATMAN_WBOX=` 空值 → 非 wbox;只有 `.wbox-` → wbox;stale fallback + wbox(§22.6)
- [ ] dv-sbx:rollback 臂四種結果 + 臂中殺 ssh;`cmd_rollback` 讀不到 / 清理 `/tmp/.rb*`;L51 `_ab_arm_mesh` stub 測試
- [ ] lint-wbox:受保護集合、misc 範圍、busybox `sh -n`、nohold、各附負對照;firmware CI:`--selftest-` lint
- [ ] test-dv-preflight:P9 `[all]` 三案;pre-gate stub 一案
- [ ] E-H5 四項(§22.6)

## 23. v13 審查後的修訂(`h23-review-v13-A` AWC 0/1/10、`-B` AWC 0/0/8;**本節優先於前文全部**)

### 23.1 節點上「撐過斷線」的證明改為有判別力的形式(v13 A-MAJOR-1、B-m1)
不配 pty 的 `ssh node cmd` 起動後,連沒有任何保護的 `&` 也活得下來(v13 A 沙箱 nopty 四種全 PASS),所以 §22.1「起動後殺 ssh」沒有判別力。改為:
- **正向**:`ssh -tt node 'sh $DVD/<run>/rbarm-launch.sh; sleep 30'`(pty;launcher 照 §22.1 以 `trap '' HUP PIPE; setsid sh rbarm.sh … &` 起臂),臂開頭 `sleep 10` 並記 `t0 = /proc/uptime`;harness 在第 3 s 殺掉 ssh client,記錄殺的時刻與 session shell 的 pid 已消失;臂在 rollback 前後各記 uptime;斷言:`rbarm.out` 有 `RESULT=PASS`、殺 ssh 的時刻早於臂的 rollback 時間戳。
- **負對照**(同一條 `ssh -tt` 路徑、同一窗口殺 ssh):起一個**無害**的臂(不呼叫 batman-slot,只 `sleep 10; echo RESULT=PASS`),**不加** `trap` 與 `setsid` → 必須沒有 `RESULT=`(v13 A 沙箱:plain-pty、setsid-only-pty 都死、design 存活)。負對照碰不到任何槽狀態。
- 若節點上的負對照沒死(例如 dropbear 不送 HUP)→ 該證明判 INVALID,改以 dv-sbx 的 pty 模擬為準並標 ⚠️(不當 PASS)。

### 23.2 rollback 臂的收尾與回補(v13 A-m1、B-m2 / m3)
- `kill -0` 前比對 `/proc/<pid>/cmdline` 含 `rbarm.sh`(防 pid 重用)。
- 120 s 無 `RESULT=` 且臂還活著 → 再等最多 60 s;180 s 仍無 → **一律不另起回補**,`pr_needs_person`,附 `bf_ab_all`、`[tryboot]`、程序列表。臂已不在而無 `RESULT=` → 讀 `bf_ab_all`,≠ `fw-part A` → 起 `rbfix.sh`。
- **`rbfix.sh`**(另 stage,只做回補):前置 = `batman-slot active` = A、boot_id 與臂起動時相同(臂期間重開過 → 不 commit,交給 P9 / §22.1 的「B 上 rollback + `reboot committed`」並 `pr_needs_person`)、沒有任何 cmdline 含 `batman-slot` 的程序(避免撞 `slot_lock`,`batman-slot:61-73`);然後 `/usr/sbin/batman-slot commit` 重試 3 次 → 讀回 `bf_ab_all` = A。
- 前置的電源檢查:`vcgencmd` 不存在 / 讀不到 → INVALID(fail-closed);batpower 狀態 `CRIT` → INVALID(會讓 `write_autoboot` die,遮住回歸,`:294-298`)。
- 回補後 openmanetd:`addr_defer_release` 背景 start(`:754-768`)→ ≤ 30 s 內輪詢 `/etc/init.d/openmanetd running`;此斷言只在 dv-sbx 的回歸案被執行到(節點 PASS 路徑不回補),文件註明。
- `pr_begin` / P9:殘留且仍活著的 `rbarm.pid` / `rbfix.pid` → FAIL(否則下一單位的 sysupgrade 撞 `slot_lock`)。
- 回歸窗口斷電後開進 committed wbox B 的恢復需要 ssh 進 B:B 是 `96-noprov`(provisioning 不還原),到達方式 = lab key 經乙太網(04 有乙太網)或 `pr_find`;本單位前置斷言 B trial 期間 ssh 可達(`pr_find` 找得到),§5 註明(v13 A-m8)。

### 23.3 dry-run 起法(v13 A-m2、B-m5)
- 不在單引號內用未 export 的 `$DVD`:dry-run 也 stage 成 `$DVD/<run>/dry.sh`(執行中不改寫),內容寫 `echo $$ > "$D/dry.pid.tmp" && mv "$D/dry.pid.tmp" "$D/dry.pid"; exec env … batman-autocommit run`(`D` 以 stage 時的絕對路徑寫入)。
- harness 先輪詢到 `dry.pid` 存在且全為數字(v13 B 沙箱:137/200 次第一次讀到空檔),再做 §22.3 的 sid 輪詢;兩者共用 2 s 上限。

### 23.4 P9 `[all]`(取代 §22.2 的判定;v13 A-m3 / m6、B-m4)
- 前置:A/B 卡(`batman-slot layout` 成功)且 Pi 4;golden 或非 A/B 的 Pi 4(無 `/boot/autoboot.txt`)→ 不適用(不是 FAIL)。A/B 卡上 `bf_ab_all` 空值 / 非 1|2、`batman-slot fw-part` 或 `active` 回空(`detect_layout` die,`:95,98`)→ FAIL。
- trial 進行中(DT tryboot = 1 且執行中槽 = `[tryboot]` 指的槽)→ INFO「trial 進行中」,只對 `[all]` 指的槽 S 做 wbox 判定;不印 stale fallback WARN。
- S 的 wbox 判定**一律以唯讀掛載 S 的 squashfs 讀 `etc/batman-build`**(`mktemp -d`);`.protected` 只做交叉核對,兩者不一致 → FAIL(apply 之後、首開之前 `.protected` 是舊版本號,v13 A-m6;apply 會刪目標槽的 `.protected`,`batman-slot:432-433`,屆時以 squashfs 為準)。掛不上 / 讀不到 → FAIL。
- 非 trial 且 S ≠ 執行中且 S 非 wbox → WARN「stale fallback / EEPROM 開錯槽」。
- `test-dv-preflight.sh` fixture:`[all]` 指向 wbox 槽 → FAIL;release trial → PASS 且**無 WARN**;stale fallback(非 wbox)→ WARN;`[all]` 讀不到 → FAIL;golden Pi 4 → 不適用。

### 23.5 F5 的負測試改法(取代 §22.5;v13 A-m4、B-m6)
現行 gate 是 `[ -f "$LIST" ] || fail`(firmware `check-prov-test-gate.sh:68`),FIFO 不是一般檔、舊 gate 不會開它 →「舊 gate 開 FIFO 建 sentinel」不成立(v13 B 沙箱 S2)。改為:
- `WBOX_DIR`:一般檔誘餌 —— 偽 `helpers.list` 的內容一被採用就會改變判定(v13 B S3:`chan prov_test helper` → `FAIL: prov_test variant but the helper is not a Go binary`);新 gate 的判定與輸出必須和不設 env 時逐位元組相同。
- `GO`:一執行就 `touch` sentinel 的腳本(v13 B S2b 已證判別力)。
- 負對照:**新 gate 的 mutant**(把 `WD=${WBOX_DIR:-…}` / `GO=${GO:-…}` 加回去)→ 測試必須 FAIL;不拿舊 gate 當負對照(它不支援 `--selftest-*`,會因別的原因不同)。
- 不用 FIFO(避免寫者殘留);gate 呼叫仍加 `timeout 30`(GNU timeout 會收孫程序,S4)。

### 23.6 lint 與執行期竄改(v13 A-m5 / m10、B-m7)
- `lint-wbox` 所在的 CI job 安裝 busybox;找不到 `busybox` → FAIL(不跳過)。
- 非 `misc-*` patch 的新增行(`+`)出現受保護集合的任一路徑字串或 `autoboot.txt` → FAIL(防 uci-defaults / init mutant 在首開以 root 改寫 overlay 裡的閘);負對照:一個新增 `99zz-wbox-x` 內含 `/usr/bin/batman-autocommit` 字串的假 patch → FAIL。
- 節點端:B trial 期間斷言 `/overlay/upper` 內沒有受保護集合的路徑、`/boot/autoboot.txt` 的 mtime 未在 trial 內被非 batman-slot 程序改(以 trial 起點記錄的 mtime 比對)。

### 23.7 其他
- E-H5 第 4 項 `/rom` 原始輸出已貼 #254 留言 6460577320(v13 A-m7、B-m8a)。
- 兩條殘項與本日其他殘項已寫進 #254 **本體**的「H2 + H3 殘項」checklist(v13 B-m8b)。

### 23.8 v13 全部發現的處理表

| 發現 | 處理 |
|---|---|
| A-MAJOR-1 / B-m1 節點斷線證明無判別力 | §23.1(`ssh -tt` + 無害臂負對照;負對照不死 → INVALID 改以 dv-sbx 為準) |
| A-m1 / B-m2 收尾、pid 重用、`rbfix.sh`、臂中重開 | §23.2 |
| A-m2 / B-m5 dry-run 引號與 `dry.pid` 空檔 | §23.3 |
| A-m3 / B-m4 P9 trial 誤 WARN、`fw-part` die、golden Pi 4 | §23.4 |
| A-m4 / B-m6 F5 FIFO | §23.5 |
| A-m5 busybox 在 lint job | §23.6 |
| A-m6 `.protected` 先信 | §23.4 |
| A-m7 / B-m8a `/rom` 原始輸出 | §23.7(#254 6460577320) |
| A-m8 B 的可達性 | §23.2 |
| A-m9 / B-m8c checklist 漏項 | §23.9 |
| A-m10 / B-m7 執行期改寫 | §23.6 |
| B-m3 vcgencmd / CRIT / openmanetd 窗口 | §23.2 |
| B-m8b 殘項進 #254 本體 | §23.7(已寫入本體) |

### 23.9 實作 checklist(取代 §22.8,完整版)
- [ ] gate 自測加小寫 misc 見證一案
- [ ] CI `test-autocommit-wbox.sh`:wbox 無 hold / wbox + hold / 非 wbox / 讀不到 / dry-run + wbox / `BATMAN_WBOX=` 空值 / 只有 `.wbox-` / stale fallback + wbox;負對照:閘拿掉、閘在 hold 前
- [ ] dv-sbx:rollback 臂 PASS / INVALID / FAIL-RECOVERED / FAIL-NEEDS-PERSON、a0 = B → INVALID、pty 下臂中殺 ssh(design 活、無保護死)、`rbfix.sh` 前置(重開過 / active ≠ A / 有 batman-slot 程序)、回補後 openmanetd ≤ 30 s
- [ ] dv-sbx:`cmd_rollback` 讀不到 → 獨立訊息、無殘留 `/tmp/.rb*`;wbox 檢查在 `rollback_lock_gate` 之前的順序測試
- [ ] dv-sbx:L51 `_ab_arm_mesh` stub 測試(含 meshjoin fallback)
- [ ] lint-wbox:受保護集合、misc 只碰 autocommit、非 misc 新增行不得含受保護路徑 / `autoboot.txt`、busybox `sh -n`(job 裝 busybox,缺則 FAIL)、nohold 只在單位與 `prov-254.sh`;各附負對照
- [ ] firmware CI:`--selftest-` lint(豁免 gate 本身);`build-board.sh` / `local-ab-tar.sh` 不傳 `--selftest-`;F5 誘餌 + `GO` sentinel + gate mutant 負對照
- [ ] test-dv-preflight:P9 `[all]` 五案(§23.4);pre-gate stub 一案;殘留 `rbarm.pid` 一案
- [ ] dry-run:`dry.sh` / `dry.pid` 原子寫入、sid 輪詢、在場判定、`hold present` 在 `gate until` 之前、臂 a 節點端 `arm-a.verdict`
- [ ] 判定行限本次 trial boot8:`WBOX-NOCOMMIT`、`TRIAL-REVERTED`、`COMMITTED`
- [ ] `/proc` churn 白箱
- [ ] prov-misc 前置:無 sysupgrade 程序、無 `batman-fw-override`、p6 無 hold 旗標
- [ ] 文件:`release --wait` 遇 wbox 一定逾時
- [ ] 節點:§23.1 正向 + 負對照;B trial 期間 overlay / autoboot 竄改斷言(§23.6)
- [ ] E-H5 四項(B trial 的 `/rom` 搭 `prov-ota-254`)
