# Design: #254 PR-P1(helper + 兩板共用檔)與 PR-H2(P1 的測項)— **v5.1(自足版)**

**狀態**:v5.1。第 5 輪兩位都判 APPROVE-WITH-CHANGES(A 0 / 0 / 12、B 0 / 0 / 9,`review-v5-{A,B}.md`);v5.1 把這些 MINOR 都寫進來(§12「v5 審查 → v5.1」)。條件是實證 E1–E6 照 §9 先做,結果寫回本文件,推翻前提的段落要送回審查。v4 的審查結果:A APPROVE-WITH-CHANGES 0 / 1 / 11;B REJECT 0 / 4 / 6(`review-v4-{A,B}.md`)。v5 加了使用者決定 P-U11、P-U12,事實 F29–F33,§4.5 整節重寫(可靠的 trial 開機、比對規則、只在 04 重建),沙箱改成只在 CI 跑並加上 `prov-artifact-match`,主機端改在 Git Bash 跑,實證增 E4 / E5,新增 §7.4;對應表見 §12。以下是 v4 的說明。歷次審查結果:
- v1:A REJECT 2 / 10 / 16;B REJECT 3 / 7 / 14。
- v2:A 0 / 9 / 18;B 0 / 11 / 15。
- v3:A REJECT 1 / 7 / 11;B REJECT 1 / 5 / 10(`review-v3-{A,B}.md`)。

v4 的主要改動:
- **使用者新決定**:P-U6(凍住)、P-U7(改名先不開)、P-U8(B 槽留同版)、P-U9(過渡期紅燈 KNOWN)、P-U10(完整 prov tier B 只在動到 prov 或發版時跑)。
- **基準 S0 改成「兩槽都是 V、B 可開機」**:restore 先寫回 p5,再依測項類別逐檔還原或從 p5 重建 A;最後以 held trial 把 B 重寫成 V。B 不再作廢。
- **鏈 1 不會再鎖死 04**:認領前先寫入 lab 公鑰並驗證能登入。
- **#202 閘照上層,只放行 unclaimed**。
- **identity 比對放在 gen 比對與 `--check` 的 rc 7 之前**。
- **`dv-sbx` 補上隔離契約**(PID / NET / UTS / IPC namespace、丟 capability、私有 `/dev`、`/opt/batdata`、`/tmp/run`;v5 起只在 CI 跑)。
- **gate 測項改看正向證據**。
- **tier A 改用 `sysupgrade -l`**。
- **provclient 改成「root 啟動、讀完秘密後自己降權」**。
- **overlay 改比整份清單**,用來抓漂移。
- **§5.7 補齊**;成本重估。
- §12 列出 v3 每個發現的去向。

上層(行為與契約唯一來源):`254-stage1-impl.md` v19;`219-protocol.md` v0.7;`254-h1-harness.md` v8。與上層衝突的地方列在 §10。

基準:
- Batman `main` f1a1122;firmware `build-3aplus` 0439b5bb(= 1.5.12-wsl.9)。
- 02(10.41.1.1)、04(10.41.1.3):wsl.9、slot A committed、root 無密碼(harness 以 `none` 登入)、`lock-status=UNPROVISIONED`。

## 0. 一句話
- **P1**:helper(Go,root)與上層列給 P1 的 shell 改動;不含 BLE / GATT(那是 P2)。
- **H2**:把這些行為的測項先放進 main。每個測項附三個證據:
  - wsl.9 上 FAIL;
  - P1 rc 上 PASS;
  - P1 rc 上拿掉那個檢查就 FAIL。

## 1. 決策、範圍、事實

### 1.1 使用者決定
| # | 決定 | 日期 |
|---|---|---|
| (上層) | U1–U9、Q1–Q8;H-U2;先 H2 / P1,之後調查 Pi 4 藍牙 UART 卡死 | 10-18 ~ 10-21 |
| P-U1 | 以白箱工具回到基準;真的要燒卡時燒**上一版穩定版**(1.5.11-rel.1)、記錄版本,再 OTA | 10-21 |
| P-U2 | 測試 client = harness 內**獨立的 Go `provclient`** | 10-21 |
| P-U3 | helper 做上層 §4.1 **全部動詞**(例外 P-U7) | 10-21 |
| P-U4 | 每個 tier B 測項結束都回到基準;「**測就要有效果,真機有效有真機**」 | 10-21 |
| P-U5 | **`ble-ok` 閘先只記 WARN、不擋 commit**,等 UART 根因修好 | 10-21 |
| P-U6 | overlay 與 p5 的身分不一致 → **凍住等授權**(fail-closed `unknown(identity-mismatch)`,§4.8) | 10-21 |
| P-U7 | `settings.set` 改名(hostname)**這一版先不開**:回 `E_UNSUPPORTED(rename-pending)`,等 U5 改名探針 | 10-21 |
| P-U8 | 每個破壞性測項結束後,**B 槽留跟 A 同一版**(可開機) | 10-21 |
| P-U9 | H2 先進 main、P1 還沒進 main 的期間:測不到的測項**紅燈、標 KNOWN**(有到期日);不新增 PENDING 例外;H2 merge 後盡快 merge P1 | 10-21 |
| P-U10 | **完整 prov tier B 只在「動到 prov 相關程式的 PR」與「每次發版」時跑**;其他 PR 的全套只跑 prov 的 tier A 與沙箱。這是「全套」範圍的定義,要寫進規則 | 10-21 |
| P-U11 | 02 落到 slot B 之前,**先補 02 p3 的 `core_freq_min=500`**(上層 §11):先備份該檔、記 sha,只加這一行,讀回驗證;不重開、不碰 slot A(§9 第 2 步) | 10-21 |
| P-U12 | 完整 prov tier B **連續跑,不需要人一直在場**;遇到需要人處理的狀況,停在安全點並推播通知(§7.4)。這取代 tier B「人在場」的要求,只適用於 prov tier B | 10-21 |

### 1.2 事實(唯讀實查;作者與兩位審查者,2026-10-21)
| # | 事實 | 證據 |
|---|---|---|
| F1 | P1 的東西今天全部不存在 | 掃描 |
| F2 | 節點腳本兩份;`check-provisioning-sync.sh` 比 19 對,缺任一檔就 FAIL(`:42-43`);batman-provision 依 Makefile **逐檔** `INSTALL_*`(`Makefile:62-111`);`ab-shared-change.yml` 要求 PR body 有 `### bcm2711` 與 `### bcm2710` | 讀檔 |
| F3 | 96:出口 `:64` / `:67` / `:71` / `:89-91` / `:93` / `:185`;Lane A(`:96-102`,還原 `authorized_keys` 與 host key)只在 seeded 時跑;上鎖 `:161-176` 的條件 = 「有可用 key **且**有 crypt hash」→ LOCKED + `ttylogin=1`;每台持久化的套件 = `system wireless network openmanetd mesh11sd`(`:22`) | 讀檔 |
| F4 | config-save:只准 root;`DEV=/dev/mmcblk0p5` 寫死;`--on-join` 的 fp 快取在 tmpfs,**每次開機後第一個 JOINED tick 一定 rw 掛 p5**;fp 含 host key、`authorized_keys`、`config.yml`、shadow(`:188-196`);未 seed 的 p5 照寫,最後寫 `.seeded`;**`--check` 遇到未 seed 的 p5,在任何比對之前就 rc 7**(`:337`);rw 掛載一次映像 sha 就會變 | 讀檔、實驗 |
| F5 | autocommit:hold-commit 只在版本相符的 tryboot 開機生效(不符 → `HOLD-COMMIT-DISCARDED`);健康時記 `HELD`;**hold 擋不住 deadline watchdog**:到期會把該槽記進 `bad-slot` 並重開(`:94-103`、`:196-243`、`:360`);正規的 commit 路徑是 `batman-autocommit release`(commit 時刪 `bad-slot`);Pi 4 trial 期限預設 600 s | 讀檔 |
| F6 | `batman-slot`:`apply` 寫完一定 arm tryboot;armed 時 `reboot committed` 退成 plain reboot;`stage-root` / `apply` / `precheck-node` 都先跑 `node_checks`(#202 閘、freshness gate:`--check` 並寫 `$RUNDIR/p5-check.rc`、`[tryboot]` 指向檢查);trial 中要 `BATMAN_ALLOW_TRIAL_APPLY=1` 才往下判;在 B 的 trial 裡,因 `[tryboot]` 仍指 B,最後會 die「mis-aimed tryboot」;`precheck-node` 會寫 `p5-check.rc`、鎖目錄、`/mnt/p5seed.$$`(**不是嚴格唯讀**);freshness gate 把 rc 7 記成 `skip:unseeded` 並放行(`:487`) | 讀檔 |
| F7 | 02 沒有乙太網;04 的 eth0 在 `br-ahwlan`(/16);主機 10.41.240.10/16 | 實查 |
| F8 | fresh 槽:`99-halow-identity` 重新產生 host key / hostname / `10.41.254.(rand)`、`dhcpconfigured=0` → openmanetd 保留正式位址後**重開一次**;placeholder mesh key → keyguard 關 mesh radio(eth 不動);**image 沒有預設 `authorized_keys`**(`/rom/etc/dropbear/` 是空的);dropbear 允許空密碼登入(`none`) | 讀 /rom、04 實查 |
| F9 | joinwatch 每個 JOINED tick 跑 `--on-join`;未入網超過 3600 s → 重開一次 | 讀檔 |
| F10 | `halow-setkey` 每次都 `uci commit` + `wifi reload`,並一律 persist | 讀檔 |
| F11 | `rc.button/reset`、`reset_override` 屬 base-files;rootfs 組裝沒有 `--force-overwrite` | 讀檔 |
| F12 | feed 釘 f2f2bf6;`f2f2bf6..f1a1122` 在 `feed/ deploy/` 沒有差異 | `git diff` |
| F13 | WSL 系統的 go 是 1.22,**實際編譯用 firmware 樹的 go1.26.4**(`staging_dir/hostpkg/lib/go-1.26`,第 7 輪 A-m9 更正),**沒有 qemu-aarch64**;CI 沒有 Go、沒有 image;**repo 是 PUBLIC**(GitHub arm64 runner 可用);release v1.5.11 有 bcm2711 / bcm2710 的 `…-ab-payload.tar.gz`(內含 `root.squashfs`) | 讀檔、`gh` |
| F14 | 99zz 排在所有 `9x` 之後 | rootfs |
| F15 | 已用 uid:101、123、453、514、32768、65534;04 容器 999 / 1000 | 實查 |
| F16 | 04 overlay-only:`crontabs/root`、`uhttpd.key/crt`、`openmanetd.db*`、Tailscale 狀態;OTS init stub 由 95 重建;p6 有 5 份舊 `dv289-backup-*` | 實查 |
| F17 | 兩台藍牙控制器會卡死,只能靠重開 | #254 |
| F18 | 協定向量有 `owner_op`、`op_nonce`、`claim_*`、`cose`、`psk_replay` | `vectors.json` |
| F19 | 節點 busybox 沒有 `unshare` / `losetup` / `nsenter`;有 `/dev/loop-control`、`loop0-7`;kernel `PID_NS` / `NET_NS` / `UTS_NS` = y;`/overlay` = `/dev/loop0`(f2fs);root umask 0022、`/tmp` 1777;有 `sysupgrade -l` | 04 實查 |
| F20 | `/tmp/run/batman-dv` 是 root 0700(H1);`/tmp/run` 是 0755 | 實查 |
| F21 | known-failures 格式 `suite<TAB>ERE<TAB>issue`,沒有到期欄 | 讀檔 |
| F22 | preflight P3 遇到 fleet 版本不同直接 FAIL | `dv-preflight.sh:42` |
| F23 | OTA payload 只驗 SHA256SUMS,不驗簽章 | `platform-ab.sh` |
| F24 | 95 每次開機寫 `slot-<自己>.protected`;`apply` / `stage-root` 先刪目標槽的;每日 `chk_slotintegrity_209` 要求兩槽都有(`daily-validation.sh:593-594`) | 讀檔 |
| F25 | 02:hw watchdog 30 s、`kernel.panic=3` | 實查 |
| F26 | ab-selftest 的 happy path 用 raw tryboot 開 B;`--destructive` 會改 B;`reflash-survives-config-202` 跑完會停在另一槽;H1 N3 需要 B 上有舊版 build | `ab-selftest.sh:227-241`、`daily-validation.sh:38-44, 2111`、`negctl-old-slot-254.sh` |
| F27 | 04 上的 `/opt/batdata/ota.tar.gz` 是 `version=20261018-113030`,不一定等於現在跑的 build | 實查 |
| F28 | `99-batman-chanfix` 在背景最多約 80 s 後,把頻道改回 p5 的值 | 讀檔 |
| F29 | tryboot 已 arm 時,`batman-slot reboot committed` 會退成 procd 的 `reboot`(`:759`);這台 EEPROM 在這條路徑上可能 no-op(`ab-selftest.sh:233-238`)。sysupgrade stage 2 的 `reboot -f` 約 25/25 正確(`platform-ab.sh:266-267`) | 讀檔(審查 A v4) |
| F30 | overlay 在執行中會自己改寫:`board.json`(開機後 12 s)、`config/network`、`config/mesh11sd`(25 s)、`config/firewall`(3851 s)、`config/system`(6340 s);一直在變的還有 `urandom.seed`、`openmanetd.db-wal/shm`、`root/.ssh/known_hosts` | 04 mtime 實查(審查 B v4) |
| F31 | 沙箱要掛 ext4 就必須保有 `CAP_SYS_ADMIN`;有了它,`mount -t devtmpfs`、`/proc/sysrq-trigger`(全域)就都碰得到,所以在節點上做不到隔離 | 審查 B v4 |
| F32 | WSL 沒有 `~/.ssh` 的 key;網路是 NAT(172.30.x;mirrored 模式試過失敗),但 **ssh 到 04 是通的(rc=0)**,只是缺 key(B v5 更正);Git Bash 的 key 兩台都能登入 | 實查(審查 B v4) |
| F33 | 同槽重建的原始碼路徑:96 Lane A 還原 host key 與 `authorized_keys`;`openmanetd` 在持久化清單裡;`99-halow-identity` 在 seeded 時跳過個人化;`batdata-mount`、`platform.sh` 由 95 / 98 在 fresh overlay 重新產生。⚠️ `firstboot -y` 在 f2fs-on-loop 上是否真的清空 upper,只有原始碼推論,沒有真機實證(E4) | 審查 A v4 |

## 2. 元件

### 2.1 P1(產品)
| 元件 | 位置 | 說明 |
|---|---|---|
| Go module `batman-prov` | `feed/batman-prov/src/`(vendored、`go.sum`) | 二進位 `batman-provhelper`。套件:`keystore`、`cbor`(嚴格)、`auth`、`cose`、`provstate`、`txn`、`boot`、`health`、`sock` |
| 動詞 | — | 上層 §4.1 全部(§5.6);`settings.set hostname` 例外(P-U7) |
| OpenWrt package `batman-prov` | `feed/batman-prov/Makefile` | 固定 uid / gid `provd` = 471;procd S89 / K15;不裝 99zz;**`prov_test` tag** 才編進 `--killpoint`、沙箱 mutant 開關、標記字串 `BATMAN_PROV_TEST_BUILD_7f3a` |
| shell 改動 | 兩份同步 | 同 v2 的清單,另外:**沒有 `BATMAN_P5_*` 接縫**;`--prov-only` 不碰 `.seeded`(= 上層 §4.3);**#202 閘 = `.seeded` 或(`prov.meta` 格式 / sha 正確且 state = unclaimed)**(= 上層 L44);§4.8 的判斷順序;`--check` 的 prov / identity 比對移到 `:337` 的 rc 7 **之前**;`batman-slot:487` 的註解改寫;`--persist-now` 遇到 identity-mismatch 拒絕,提示文字另寫 |
| `depersonalise.sh` 安裝清單 | P1 | 產品安裝程式 |
| `rc.button/reset`、`reset_override` | firmware `files/` overlay | — |
| firmware | pin、diffconfig、`batman-config.lock`、manifest 閘 | **build gate**:rootfs 有 `batman-provhelper`;`go version -m` 的 `-tags` 不含 `prov_test`;沒有標記字串;`/etc/passwd`、`/etc/group` 的 `provd` = 471 |

### 2.2 H2(harness)
| 元件 | 說明 |
|---|---|
| `provclient`(Go) | `tests/tools/provclient/`:自寫 deterministic CBOR、嚴格 decoder、COSE、owner-op。模式:`node`(arm64)、`sign`(amd64,WSL)、`selftest`。**node 模式以 root 啟動**:<br>1. 降權前**不讀 stdin**;<br>2. 讀 `claim.secret`、fd 3 的秘密,以及(要比對 root 密碼時)fd 4 的 shadow hash;<br>3. `setgroups([])`、`setgid(471)`、`setuid(471)`;<br>4. 斷言 `getuid` / `geteuid` / `getgid` = 471、補充群組為空、`prctl(PR_GET_DUMPABLE)` = 0;<br>5. 這才連 helper。<br>降權失敗 → 結束。helper 只收 provd uid,所以等於兩層保護。root 密碼在 provclient 程序內以 crypt 對 fd 4 的 hash 比對,明文不經過 stdout(A-m7) |
| `dv-sbx`(Go,arm64 靜態) | 沙箱執行器,**只在 CI**(契約見 §4.10;節點上做不到隔離,F31) |
| 沙箱的底 | **CI**(`ubuntu-24.04-arm`,原生):釘住的 release **payload** tar 的 `root.squashfs`(bcm2711 與 bcm2710 各一,版本 + sha 釘死)+ **依 Makefile install 規則**安裝 repo 的 `feed/batman-provision/files` + 以 `prov_test` 從 repo 原始碼 build 的 helper → 測的是 PR 的程式碼。案例在 `tests/prov-p1/cases/` |
| `prov-artifact-match`(WSL) | 把沙箱的結論接到出貨產物上(誠實的界線,A-m8:對 helper 最多只證明「原始碼相同」,因為沙箱跑的是 `prov_test` build、出貨的是 release build;release build 的行為由節點 tier A / B 涵蓋。另外要比對 busybox、uci、jsonfilter 等工具的 sha 和 1.5.11 的底相同,不同就列出,B-m8):`unsquashfs` 受測 rc 的 `root.squashfs`(x86 也能解),逐檔比對 batman-provision 的檔案與「feed pin 那個 commit 的 repo tree + install 規則」**逐位元組相同**;helper 二進位以同一個 toolchain 版本與旗標(`-trimpath -buildvcs=false`、`-ldflags '-s -w -buildid='`)重建後比 sha。⚠️ OpenWrt `golang-package.mk` 的 build 能不能重現,屬實證 E5;不能重現 → helper 的出貨產物只由節點 tier A / B 涵蓋(明列) |
| 節點端腳本 | `scripts/node/prov-p1-254.sh`(唯讀判讀)、`prov-base-254.sh`(snap / restore,§4.5)、`prov-wbox-254.sh`(bind mount) |
| 主機端 | `scripts/dv/prov-254.sh` **在 Git Bash 跑**(有 key、在主機 LAN 上,可以用 MAC 找 04,F32)。簽章以子程序 `wsl -d Ubuntu-24.04 -u yello -- ~/batman-dv-tools/provclient sign --key <run 的金鑰>` 執行,stdin / stdout 是 pipe;擁有者金鑰留在 WSL ext4(0600)。preflight 增 P9 |
| lint / 清單 | `check-provisioning-sync.sh` 的 PAIRS 加上 P1 的新檔(P1 merge 前 FAIL,P-U9);新增 lint:`files/` 下每個檔在 Makefile 都有 install 行;`ab-shared-change.yml`、`rundir-paths.txt`、`tmp-trust-allowlist.txt`(+ `/tmp/run/batman-dvpc.*`);known-failures 增第 4 欄到期日(daily-validation 處理,附測試);把 P-U10 的範圍定義寫進 `docs/validation` 規則 |

## 3. 擁有權
| 資源 | 唯一擁有者 | 唯讀者 / 例外 |
|---|---|---|
| dead-man(E1c / 鏈 1):p6 `dv-prov/e1c-deadman.sh`、`e1c.cancel`、`e1c.fired`、`e1c-deadman.log`,B 的 rc.local 那一行與 25 分 timer(第 7 輪) | E1c / 鏈 1 的主機腳本寫入;B 的 rc.local / timer 執行 | 一次性(`e1c.fired`)、只在 slot B、快照超過 6 h 不動作;每個出口確認回到 A committed 就 cancel;brewrite 清掉 B 的 overlay;`finish` 刪 p6 檔 |
| `$RUNDIR/slot-committed`(§13.8.2) | `batman-slot commit` 寫(經 `batman_rundir`);`rollback` 刪 | 決定者只測存在;tmpfs,隨重開消失 |
| procd 上 openmanetd instance 的 env `ALFRED.DATATYPES.ADDRESSRESERVATION`(§13.8.2) | openmanetd 的 init(board patch 0014),依決定者的 rc 設定;每次 `start` 重新決定 | 決定者 `status`/`reconcile`、halow-status、tier A 只經 `ubus service list` 讀;`batman-slot commit` 與 joinwatch 只送 detached `start`,不直接改 |
| `$RUNDIR/addr-defer.start.pid`(`<pid> <uptime>`)、`addr-defer.starts`、`addr-defer.said.*`(§13.8.2) | 決定者 `reconcile` 寫 | 無其他讀者;tmpfs |
| helper verdict(prov-state 第 4 欄) | helper,每次開機決定一次 | **整次開機固定**(B-m10):owner 的動作改的是 record,下一次開機才反映到 prov-state;autocommit 只讀這次開機的值 |
| `PROV_BASE_TEST_ROOT`(env,第 7 輪新增輸入) | 只有 CI / WSL 測試設定 | 節點上沒人設:host 端以 `ssh node sh -s -- <cmd>` 呼叫,不帶 env。能控制 root 環境變數的人本來就是 root,所以不是新的權限邊界;空值時路徑與以前相同 |
| 節點在測項期間的 prov / 槽狀態 | 該 tier B 測項(prov lease) | P9、tier A |
| 測項之間的狀態(S0) | `prov-base-254.sh restore` | P9 |
| **p5** | 產品照舊(prov 檔只由 `--prov-only` 寫)。**測試例外寫者**:`restore`(dd)、`strip-p5-prov`,只在 prov lease 內、`cfgsave.lock` 內、helper / provd / joinwatch 停止時 | — |
| 快照 `/opt/batdata/dv-prov/<run_id>/`(0700) | `snap` 建立;`restore` 讀;斷言通過後印出再刪 | 主機另存每個檔的 sha |
| 受測 payload 副本 `/opt/batdata/dv-prov/payload-<ver>.tar.gz` 與解開的 `payload-<ver>/`(0700;sysupgrade 吃 tar,stage-root / apply 吃目錄,A-m11) | prov-254 從 WSL 推上去,以 build 的 SHA256SUMS 驗證;**不使用** `/opt/batdata/ota.tar.gz`(F27) | — |
| dirty 標記 `/opt/batdata/state/dv-prov-dirty`(0600) | `snap` 建、`restore` 斷言通過後刪 | P9;產品不讀 |
| A 的 overlay 標記 `/etc/.dv-prov-mark-<run_id>`(0600,在 A 的 overlay) | `snap` 建、`restore` 刪 | restore:標記不見了 = A 被重建過 |
| B 槽 | 測項期間:產品的 `apply`(由測項觸發);restore 結束:以 held trial 重寫成 V(§4.5) | P9 |
| prov lease `/tmp/run/batman-dv/lease-prov` | prov-254;與 H1 `bt/lease` 互斥 | — |
| provclient 目錄 `/tmp/run/batman-dvpc.<run_id>/`(root 0711,檔案 0755) | prov-254 | — |
| killpoint 檔 `/tmp/run/batman-prov-test/killpoint`(root 0700 目錄、0600 檔;**不放在 helper 的 socket 目錄**) | prov-wbox | test helper 讀完就刪 |
| bind mount | `prov-wbox-254.sh`;deadman 還原 = `umount` + 重啟 helper | — |
| `-wbox` payload | WSL `~/batman-dv-tools/wbox/<version>/` | P9 拒絕任一槽是 `-wbox` |
| 測試金鑰 | WSL `~/.batman-dv/prov-keys/<run_id>/`(ext4,0600) | 節點只看到公鑰、簽章、密文 |

## 4. 契約

### 4.1 為了可測加的介面(P1)
- **`--killpoint`**:只在 `prov_test` build。
  - 點名清單封閉:`txn-1`…`txn-5`、`claim-after-persist`、`claim-before-shadow`。
  - helper 啟動時讀 `/tmp/run/batman-prov-test/killpoint`:必須是 root 0600、非 symlink、link count 1,而且它的目錄是 root 0700、非 symlink;讀完就刪;到點就 `reboot -f`。
  - helper 的 socket 目錄清理不會碰這個目錄。
- 沒有其他產品接縫。build gate 見 §2.1。

### 4.2 主機 ↔ provclient
- **執行**:節點上 root 執行 `/tmp/run/batman-dvpc.<run_id>/provclient node …`(先驗 owner、非 symlink、link count 1、sha256)。它讀完秘密後依 §2.2 降權。stdin / stdout 經 ssh 接到 WSL 的 `provclient sign`。
- **秘密輸入**:
  - `claim.secret`:由 provclient 在降權前讀 root 0600 檔。
  - `net_secrets` 的明文:經 fd 3 傳入,是同一個 root 程序開的 pipe,內容是當場從 uci 讀出的 fleet 值;不經過 `start-stop-daemon`。
  - shadow hash:經 fd 4 傳入,只在比對 root 密碼時需要。
- **簽章往返**(framed):
  1. 向 helper 拿 `nonce_helper`;
  2. 組好請求、算 `args_hash`;
  3. `net_secrets` 在節點上以 helper 的 `ecdh_pub` 加密;
  4. 印出 `SIGN <purpose> <hex(被簽內容,只含密文)>`;
  5. WSL 回 `SIG <hex>`;
  6. 送出請求。
  
  每次往返 ≤ 20 s。ssh 斷線或逾時 → 關閉連線 → 測項 FAIL。helper 那邊:nonce 到期作廢,下一條排隊的連線接手。
- **秘密輸出**:擁有者私鑰不離開 WSL;fleet key 不離開該節點;回應裡的秘密只輸出 sha256 前 8 碼。需要比對時在節點上比(例如 root 密碼由節點 root 以 `cryptpw` 對 shadow 驗)。
- **canary**:測項結束後,對主機 log、`logread`、run 目錄、p6 dv 目錄掃描以下每一個的 hex / base64,必須 = 0:擁有者私鑰、測試 / fleet mesh key、root 密碼、`owner_tag_key`、`adv_owner_key`、psk。
- **P2 之後**:`prov-sock` 移到 tier B(要停 provd)。

### 4.3 provclient 放置
`/tmp/run/batman-dvpc.<run_id>/`:root 0711,檔案 root 0755。H1 的 `batman-dv`(0700)不改。負測試:預先放一個 provd 可寫的檔或 symlink → 拒絕執行。

### 4.4 測試用網路設定
- **單台**(netjoin、netupdate、powerloss、leave):只在 04,用隨機 mesh_id / key,頻道不變。
  - lease 上限 < 3000 s(低於 02 joinwatch 的 3600 s)。
  - powerloss 的三個 killpoint **各自**是一個 snap / restore 單位。
  - 還原後斷言 02 在 `batctl n`。
- **雙台**:fleet 實際值(經 fd 3)。04 先做,斷言 04 重新入網後才做 02。02 的恢復靠 watchdog、panic、joinwatch(F9、F25)。

### 4.5 基準與還原(`prov-base-254.sh`)

#### 4.5.0 S0、可靠的 trial 開機、全套順序
**S0**(每台;snap 記錄,restore 後斷言;P-U8):
- active = committed = **A**,版本 V,不含 `-wbox`;
- **B = V、可開機**:最近一次以 held trial 開過,`slot-B.protected` = V;
- p5 = 快照;A 的 overlay 與 p6 受測檔 = 快照(比對規則見 §4.5.5);
- 沒有 dirty 標記、bind mount、`bad-slot`。

**可靠地開進 trial**(A-M1,F29):寫另一槽**一律走 `sysupgrade -n`**,因為 stage 2 的 `reboot -f` 約 25/25 正確。payload 用 §3 的副本;hold 旗標在呼叫前寫入 p6。只有鏈 1 第 4 步要在重開前做斷言,所以那一步改用直接 `batman-slot apply` 加受控重開:
1. 停 docker / OTS 與其他會寫 p6 的服務;
2. 比照 sysupgrade stage 2:`sync` → p6、p5 卸載或 remount ro(A-m4);
3. `reboot -f`。

**落點斷言**(每次 trial 開機後都做):
- DT `tryboot` = 1、`/proc/cmdline` 的 `batman_slot` = 目標槽;
- log 有 `HOLD-COMMIT` 生效(有 hold 時),沒有 `HOLD-COMMIT-DISCARDED`。

落空(還在原槽)→ **先以 vcmailbox 讀 tryboot 旗標,如果是 armed 就 disarm 並讀回確認**(`batman-slot verify` 不回報 tryboot,B-m2),之後才清 hold 旗標、重試一次;再落空 → FAIL 並通知(§7.4)。理由:先清 hold 而 tryboot 還 armed,下一次重開會進一個沒有 hold 的 trial,健康時就會 commit B。E3 連做 ≥ 10 次,必須 10/10 落點正確。

**全套順序**(B-m5、A-m5、m11):
1. **prov tier B 先跑**:P9 要求兩台都在 S0 的槽條件上;不符 → 04 自動正規化(§4.5.3 跨槽重建,**不帶 `ALLOW_STALE_P5`**;freshness 不過 → FAIL 給人),**02 不自動**,FAIL 給人。
2. 之後才是 ab-selftest、H1 N3、`reflash-survives-config-202`。
   - N3 需要 B 上有舊版:由 N3 自己先以 held trial 把釘住的舊版 payload 寫進 B(⚠️ 實作時確認 `negctl-old-slot-254.sh` 現有的前置,沒有就由 H2 加上)。
   - `reflash-survives-config-202` 結束時多一步:把同一版 OTA 回 A 並 commit(H2 修改這個 harness 測項,附自己的測試),讓下一次 run 的 P9 過得去。

#### 4.5.1 `snap <run_id>`
1. 斷言 S0 的槽條件。
2. 停 joinwatch,取 `cfgsave.lock`。
3. **p5**:`ro,noload` 掛起 → 檔案清單 → 卸載 → `dd` → 映像 sha(主機也存一份)。
4. 在 A 的 overlay 寫標記 `/etc/.dv-prov-mark-<run_id>`。順序要在做清單之前,這樣清單就包含它(A-m10)。
5. **A 的 overlay**:
   - 整個 upper 打 tar,含 symlink、whiteout(char 0:0)、權限;不含 `etc/batman-prov/identity` 的私鑰,私鑰另以 0600 單獨存;
   - 做一份 upper 的清單,每項是路徑、型別、權限、sha;
   - 另做每個 `config/*` 的 `uci export` 正規化輸出。
6. **p6 state**:`lock-status`、`mesh-expected`、`mesh-joined`、`prov-state`、`prov-counters`、`ble-ok`、`ota-armed.mesh`、`autocommit-hold-commit`、`autocommit-hold-once`、`autocommit-skip-once`、`bad-slot`,每項記「內容」或「不存在」。
7. 寫 dirty 標記;放鎖;啟動 joinwatch(鏈 1 例外)。

#### 4.5.2 `restore <run_id>`
0. `is-trial` = 0 → 條件式 `back_to_a`。
1. 在目前 committed 的槽上:
   - 停 joinwatch、helper、provd、openmanetd、tailscaled;
   - 取 `cfgsave.lock`;
   - **p5 先寫回**(`setsid dd`),uncached 讀回比 sha;
   - 放鎖。
2. 判斷類別:
   - committed ≠ A、或版本 ≠ V、或含 `-wbox` → **跨槽重建**(§4.5.3)。
   - 在 A 上,但標記不見、或 host key 指紋 / identity ≠ 快照、或測項屬 R 類 → **同槽重建**(§4.5.3)。
   - 其他 → **逐檔還原**:
     1. 停所有會寫 overlay 的服務(openmanetd、uhttpd、dropbear 以外的 ssh 都不留、docker、cron、logd 的持久寫入)→ 以快照 tar 覆蓋 A 的 upper;覆蓋到重開之間不可中斷:解完立刻 `sync`、`echo 3 > /proc/sys/vm/drop_caches`、重開(kernel 文件:直接改掛著的 upper 屬未定義行為,A-m3 / B-m4);
     2. 刪除快照清單沒有的檔,先印出清單,§4.5.5 允許清單內的不刪;
     3. `/etc/batman-prov/` 整個目錄取代;
     4. 寫回 p6 state;
     5. `batman-slot reboot committed`(這時沒有 armed 的 tryboot,F29 不適用,走 explicit)。
   - **02**:只允許逐檔還原;判到需要重建 → FAIL、通知、停(B-M4)。
3. **B 寫回 V**(§4.5.4)。
4. **斷言**:§4.5.5 的比對;另外 active = committed = A、版本 V;helper state、lock-status == 快照;publickey 登入可用;B 的 `.protected` = V;沒有 `bad-slot`;02 在 `batctl n`;沒有 bind mount。

   全部通過 → 印出清單,刪除快照、標記、dirty 標記。

其他規則:
- 兩台的順序:先 02 後 04。
- 負對照:跳過 p5 寫回;跳過重建;跳過刪除多出的檔。各自都必須 FAIL。
- 中斷:restore 冪等;p5 寫到一半 → rc 10 / 12 → 重跑。
- dirty 標記接手:同一個 run_id 自動接手;否則 P9 FAIL 並印出指令。

#### 4.5.3 重建(只在 04)
- **同槽**:
  1. p5 已寫回;
  2. 停 helper → `firstboot -y` → `batman-slot reboot committed`;
  3. 96 從原本的 p5 重建;
  4. 停 openmanetd、tailscaled、docker → 以快照 tar 覆蓋 upper、刪除多出的檔(同逐檔還原)→ 寫回 p6 state → `batman-slot reboot committed`。
  
  ⚠️ `firstboot -y` 清空 upper 的行為由 E4 實證(F33)。
- **跨槽**(在 B 上):
  1. p5 已寫回;
  2. 寫 hold = V → `BATMAN_ALLOW_STALE_P5=1 sysupgrade -n <payload V>`(stage 1 讀 env 的檔案版:root 擁有的 `/tmp/batman-slot.allow-stale-p5`,用完就刪)。理由:這時 p5 = 已知良好的快照,而 B 跑的設定 ≠ p5,是刻意讓新的 A 採用 p5。只允許在 restore 裡、只在 04 上這樣做。
  3. 落點斷言 → `HELD` → `batman-autocommit release`;
  4. 再做一次同槽重建的第 4 步(tar 覆蓋)。

#### 4.5.4 B 寫回 V
1. 在 A 上:寫 hold = V → `sysupgrade -n <payload V>`。這時 p5 = 快照,所以 freshness 會過。
2. 落點斷言。
3. 在 480 s 內(期限 600 s)斷言:`HELD`、`slot-B.protected` = V、helper state == 快照。超過 480 s 還沒 `HELD` → 一樣 `back_to_a`,並判 FAIL(A-m4)。
4. 條件式 `back_to_a`,一定在期限之前,所以不會產生 `bad-slot`。
5. 回到 A 後斷言:committed = A、沒有 `bad-slot`,p5 的檔案清單 == 快照。B 在 trial 期間可能跑過 `--on-join`;B 是從同一份 p5 建的,fp 相同,不會寫檔;第一次 rw 掛載只動 superblock,而比對看的是檔案清單,所以不受影響。

#### 4.5.5 比對規則(B-M1、A-m2)
- **p5**:`ro,noload` 檔案清單 == 快照。
- **A 的 upper**:路徑、型別、權限 == 快照。內容的比法:
  - `config/*`:比 `uci export` 的正規化輸出,因為 F30 的 uci 改寫可能只是重新排列;
  - 其他檔:比 sha。
- **允許清單** `tests/prov-p1/overlay-allow.txt`:每一行是「路徑 + 允許什麼差異(內容 / 存在) + 證據」。**初始內容由實證 E4 產生**:
  - 只重開一次、比一次;
  - 只做一次同槽重建、比一次;
  - 以兩次的差異為準,至少包含 F30 列出的檔。
  
  沒有證據的條目不准加入;每次放寬都要經 harness PR。
- **身分**:host key 指紋、ahwlan IP、`dhcpconfigured` == 快照;本次開機 openmanetd 沒有重開。
- **p6 state**:每個檔 == 快照(含「不存在」)。

#### 4.5.6 `strip-p5-prov`
只給 legacy-upgrade 用:
1. `ro` 驗 `prov.meta` 存在;
2. 只刪 `prov.*` 與 `identity/prov/`;
3. `ro` 斷言兩者都不在、其他檔清單不變。

### 4.6 白箱三類
| 類別 | 方法 | 用在 |
|---|---|---|
| 執行期 | tmpfs 上的檔 `mount --bind` 蓋上 + 重啟 helper;重開就消失 | `prov-sock`、`prov-claim`、`prov-netjoin`、`prov-netupdate`、`prov-powerloss`、`prov-trial-busy`、`prov-misc`(helper 重啟) |
| 開機路徑 | `-wbox` payload(版本 `-wbox-<name>`)只寫進 B;restore 的 §4.5.4 會把 B 寫回 V | `prov-legacy-upgrade`、`prov-overlay-corrupt`、`prov-overlay-wipe`、`prov-ota`、`prov-lock-failsecure`、`prov-misc`(L38 / L42 / L43 / L51)、autocommit |
| 只能在沙箱 | `dv-sbx` | 96 `:89`(magic 正確、superblock 其他欄位壞)、`:67`、`:71`、L20 / L32、L61 |

### 4.7 preflight P9
- 沒有 `dv-prov-dirty`(同一個 run_id 由 harness 接手,否則 FAIL)。
- 兩槽的 `.protected` 都存在且不含 `-wbox`。缺 = FAIL,印出「先跑 restore 或 OTA」。
- helper 存在時 state ∈ {legacy} 或 `PROV_EXPECT`;pre-P1 = legacy-equivalent;讀不到 = FAIL。
- Git Bash(主機端)能以 `PreferredAuthentications=publickey -o IdentitiesOnly=yes` 登入兩台;WSL 的簽章器存在,而且金鑰目錄是 0700、金鑰檔 0600(以 `stat` 在 ext4 上驗)。
- 02 p3 已有 `core_freq_min=500`(P-U11);沒有 → 有 02 參與的測項 FAIL。
- prov tier B 開始時:斷言全套順序(§4.5 正規化)。

範圍:dirty 與 `-wbox` 擋整個 run;state 非 legacy 只讓 prov-\* tier B FAIL。

### 4.8 identity 不一致(P-U6)
- **觸發**:overlay 與 p5 的 `identity/prov/` 都完整,但 `sn` 或公鑰不同。
- **判斷順序**(B-N5):helper `--boot` **先比 identity,才比 gen**。不一致 → `unknown(identity-mismatch)`,**不呼叫任何 `--prov-only`、`--persist-now`**,所以不會寫出「X 的擁有權 + Y 的身分」這種混合。
- **行為**:
  - 不改狀態;
  - 96 的上鎖依 p6 `last_known_state`;
  - `--check` 在 rc 7 早退**之前**就比 prov / identity → rc 5 `p5 stale: prov-identity` → freshness gate 擋 OTA;
  - `--persist-now` 拒絕,提示「身分不一致:需擁有者以 app 指定或重燒卡」;
  - log 一行(不含金鑰)。
- **恢復**:擁有者以 owner-op 指定(P3);或重燒卡。root 用 `allow-stale-p5` 強制 OTA 等於「採用 p5」:這是 root 的刻意行為,log 會留紀錄,文件寫明。
- **測試**:`prov-unit-helper`(mutant:先比 gen → 寫出混合 → FAIL)、`prov-unit-cfgsave`(未 seed 的 p5 + 不一致 → rc 5,不是 rc 7)。

### 4.9 `--prov-only` 與 #202 閘
- `--prov-only` 不碰 `.seeded`(= 上層 §4.3)。
- 閘只放行 `.seeded` 或「`prov.meta` 有效且 state = unclaimed」(= 上層 L44)。
- claimed / member 的 p5 沒有 `.seeded`(例如 `--save` 失敗)→ 擋,並提示 `--save`。

### 4.10 `dv-sbx` 隔離契約(A-M4、B-N4)
- **namespace**:`CLONE_NEWNS | NEWPID | NEWNET | NEWUTS | NEWIPC`;mount propagation 設 private。
- **只在 CI 的 arm64 runner 上跑**(F31:要掛 ext4 就必須有 `CAP_SYS_ADMIN`,在節點上做不到隔離)。runner 是用完即丟的 VM,這裡的隔離是為了讓判讀不被宿主干擾、讓「逃出沙箱」變成可偵測的 FAIL,不是靠它保護真機。
- **capability**:bounding set 丟掉 `CAP_SYS_BOOT`、`CAP_SYS_MODULE`、`CAP_SYS_TIME`、`CAP_SYS_RAWIO`;`/dev` 建好之後再丟 `CAP_MKNOD`。
- **/proc、/sys**:`/proc/sys`、`/proc/sysrq-trigger` 以 read-only bind 蓋住;`/sys` 不掛。
- **檔案系統**:
  - `/dev` 是新的 tmpfs,只有 `null`、`zero`、`urandom`、`mmcblk0p5`(指向沙箱自己的 loop);`kmsg` 是一個普通檔(stub)。
  - `/opt/batdata`、`/tmp`、`/tmp/run` 是私有 tmpfs。
  - `/proc` 是新 pid ns 的 proc;`/proc/cmdline` 以 bind 蓋成假檔。
  - 沒有 `/proc/device-tree`、`vcmailbox`(換成 stub)。
  - `reboot`、`wifi`、`ubus` 換成 stub,只記錄被呼叫。
- **loop**:只接受沙箱目錄下的 regular file;拒絕已掛載或正在支撐 `/overlay` 的裝置。
- **在哪跑**:只在 CI。**節點上不跑**(02、04 都不跑)。出貨產物由 `prov-artifact-match` 接上(§2.2)。
- **負測試**(`prov-unit-sbx`,runner 上):沙箱內 `reboot -f` → runner 的 boot_id 不變;`mknod` 一個 runner 真實磁碟的 major:minor → 失敗(EPERM);`ip link add` → 宿主看不到;寫 `/proc/sys/kernel/hostname` → 失敗;寫 `/dev/kmsg` → 宿主 `dmesg` 沒有。
- **`prov-unit-gate`**:需要 GPT 卡、FAT、`/boot/autoboot.txt`、DT `compatible`。只在 CI 跑,沿用 `tests/ab-card-invariants.sh` 的 loop 卡做法,加上假的 DT 檔與 `/boot`;節點上的 gate 由鏈 1 實機測。

## 5. H2 測項
每個 tier B 測項:lease → P9 → snap → 測 → restore。只在 `FEATURE_MODE=--destructive` 時跑;**依 P-U12 無人值守**,停下與通知見 §7.4。觸發條件依 P-U10。tier A 的白箱負對照只在 lease 內、PR 證據階段跑。

### 5.1 沙箱
| 測項 | 判讀 | 白箱負對照 |
|---|---|---|
| `prov-unit-sbx` | §4.10 的隔離負測試 | 本身是負測試 |
| `prov-unit-96` | 交叉:每個出口(`:64` 假 cmdline、`:67`、`:71`、`:89` superblock 壞、`:93`、正常)× p5 prov {無、legacy、unclaimed、claimed、member} × meta {好、壞、sha 錯} × p6 `last_known_state` × dev-open × identity {一致、不一致};斷言 dropbear uci、`ttylogin`、`lock-status`、`.batman-prov-restore`;helper 不存在時 = 今天行為(legacy 早退出口寫 lock-status,這是行為變更) | meta 壞 → UNLOCK;p6 claimed → UNLOCK;dev-open 豁免 claimed;漏呼叫判斷;不一致 → 改狀態 |
| `prov-unit-cfgsave` | `--prov-only` 驗 meta、≤ 64 KiB、identity 7 檔、不覆寫 identity、不碰 `.seeded`;ENOSPC 注入 → `--prov-get` 讀到舊 gen;`--prov-get` 每個 rc;`--on-join/--save/--seed` 不碰 prov;`--check`:prov stale / identity 不一致 → rc 5(**含 p5 未 seed 時**);`final_rc` `root:!`;`.txn` 讓路;L20 / L32(掛不起 p5 → helper 下次開機補回 prov / identity) | 先寫 meta;`--on-join` 納入 prov;`--check` 的比對留在 rc 7 之後 |
| `prov-unit-helper` | `--boot` 的每個 rc(上層 §4.2 + §4.8 順序);§4.4 第 6–7 步;身分產生的三個條件 | rc 9 且 overlay 完整也產生;rc 10 且 overlay 缺時產生;先比 gen |
| `prov-unit-auth` | §5.6 每個動詞的授權負測試,加上 nonce、`args_hash`、`type`、重複 key、非 deterministic、64 KiB、逾時、排隊、額度、10 / h、防呆門、admins 鏈、`ssh_keys.set` 注入、`qr` 限制、`keystore.ecdh` / `persist` / `keystore.sign` / 恢復出廠動詞 → `E_SCHEMA` | `prov_test` 的 mutant 開關 |
| `prov-unit-gate`(CI) | `.seeded` 有 / 無 × `prov.meta` {有效、壞、sha 錯} × state {unclaimed、claimed、member};**claimed / member 且未 seed → 擋** | wsl.9 的 `batman-slot`;mutant「放行 claimed」 |
| `prov-unit-button` | `rc.button/reset`、`reset_override` | 原版檔 |
| `prov-unit-bcm2710`(CI,**smoke**) | 同一組案例,以 bcm2710 payload 的 rootfs 為底 | 明列為 smoke |
| `prov-unit-build` | build gate 自測 | release build 過、`prov_test` build 擋 |
| `lint-install` | `files/` 每個檔都有 Makefile install 行 | 刪一行 → FAIL |

### 5.2 節點 tier A(唯讀,每天)
| 測項 | 判讀 | 白箱負對照(lease 內) |
|---|---|---|
| `prov-boot-254` | 每台:`prov-state` 的 boot_id = 本次;overlay gen == p5 gen;`identity/` 權限;health 每個欄位與實況一致、ts ≤ 60 s;`--check` 沒有報 prov stale;`prov-counters` 本次開機沒有增加;不在 keep.d / conffiles;**`sysupgrade -l` 的輸出沒有 `etc/batman-prov`**(不產生 archive,A-M6);`logread` canary = 0;`ble-ok` 只在條件成立的節點(P-U11 之後 02 也有)。負對照改用白箱:在 tmpfs 上複製一份去掉 `core_freq_min` 的 distroconfig,以 bind mount 讓 helper 讀到 → `ble-ok` 不寫(A-m5) | 停 helper → stale;關 privacy → 15 s 內 `privacy=0`;`batman-sc` pid 不符 → `sc_file=0` |
| `prov-sock-254` | 只送唯讀請求(`info.*`、`nonce`);`nobody:nogroup` → 斷線;`nobody:provd` → 斷線;未知動詞 / 多餘欄位 → `E_SCHEMA` | bind mount 不檢查 `SO_PEERCRED` 的 helper |

### 5.3 節點 tier B(04,除非註明)
「類別」:**F** = 逐檔還原,**R** = A 重建(§4.5.2 第 2 步)。

| 測項 | 程序與判讀 | 負對照 | hold / 最終槽 / 類別 |
|---|---|---|---|
| `prov-base-254` | snap → 改 p5 / overlay / p6 → restore → S0;restore 的 dd 期間 `reboot -f` → 重跑 → S0;同槽 A 重建一次 → S0;以這三次重開之後跑三次 `prov-boot-254`(L2 ×3) | 跳過 p5 寫回;跳過 A 重建 | — / A / F + R |
| `prov-legacy-upgrade-254`(L17) | 1. 釘住的 wsl.9(版本 + sha)apply 進 B,不 hold → commit B。2. `strip-p5-prov`。3. rc apply 進 A → A commit。4. 斷言:helper log `rc=9`、`prov{legacy}`;AP key、lock-status、authorized_keys、mesh-expected 前後相同 | `-wbox` helper:rc 9 → unclaimed | 不 hold / A / R |
| `prov-claim-254`(L18、L47、L34) | `claim.verify` → claimed;`ssh -v` 的認證方法只剩 `publickey`;`ttylogin=1`;LOCKED;`claim-after-persist` killpoint → 重開 → `claim.replay` 拿到相同 `owner_tag_key`(比 sha);錯 owner_pub → `E_FORBIDDEN`;以 bind mount 換成空的 `authorized_keys` 視圖 → `E_UNSUPPORTED(no-ssh-key)` | bind mount 一個接受 client 送來的 `ClientChal` 的 helper | — / A / F |
| `prov-netjoin-254` | `network/join`(隨機網路)→ member;wireless == `prov.net`;overrides == prov;`rm=1`;setkey 印 `radio_managed` 警告;`--no-persist` 不 `--save` | bind mount:首版沒有 owner-op 也被接受 | — / A / F |
| `prov-leave-ota-254`(L22) | member → leave → 檔案被刪 → OTA rc(hold)→ B claimed | bind mount 不刪 | hold / A / F |
| `prov-ota-254`(L5) | member → OTA rc(hold)→ B:member、gen 同、wireless 同、上鎖;**96 那一刻的證據**(`.batman-prov-restore` 的 verdict + helper log「overlay prov from 96」) | `-wbox` 96 不抄 → 「restored from p5」 | hold / A / F |
| `prov-lock-failsecure-254`(L5) | 以 `claim-before-shadow` 做前置(claimed、沒有 `shadow-root`)→ OTA `-wbox`(helper = exit 1,hold)→ 認證方法只剩 publickey、LOCKED | 同前置,OTA wsl.9(hold)→ UNPROVISIONED | hold / A / F |
| `prov-powerloss-254`(L7) | `txn-2` / `txn-3` / `txn-4` **各自一個單位**:killpoint → 重開 → wireless == prov、overrides == prov、key 登入可用 | killpoint 在 bind mount 的 test helper | — / A / F |
| `prov-netupdate-254`(L25、L26) | 第 2 步故意失敗 + `--on-join` → overrides 不前進;`txn-3` 後 `--on-join` + 重開 → member | bind mount 一個不讓路的 `--on-join` | — / A / F |
| `prov-trial-busy-254`(L21) | held trial 上 `claim.verify` → `E_BUSY` | bind mount 不看 is-trial | hold / A / F |
| `prov-overlay-corrupt-254`(L33) | 弄壞 A 的 `prov.cbor` → 重開 → 以 p5 重建 | `-wbox` helper 不比 gen | — / A / F |
| `prov-overlay-wipe-254`(L60) | `firstboot` → state、`device_id` 不變 | `-wbox` 96 + helper 都不還原 | — / A / R |
| `prov-downgrade-254`(L12,characterization) | claimed → OTA 釘住的 wsl.9(hold)→ 還原、LOCKED、`ttylogin=1`、p5 的 prov 檔不刪 | 沒有鑑別力(明列) | hold / A / F |
| 鏈 0、鏈 1 | §5.4 | | |
| `prov-autocommit-254` | §5.5 | | |
| `prov-misc-254` | L38 / L42 / L43 / L51(`-wbox`);L11 helper 重啟;socket 目錄預先放 symlink / 他人擁有 → 拒絕;L9 / L10 helper 側(`bluetoothd`、`dbus` 重啟 → 15 s 內 health 恢復);L27(dropbear 重啟後 key 登入恢復);L3 clean shutdown | 各一個 mutant | — / A / F |
| `prov-verbs-254` | §5.6 的正向測試 | §5.6 | — / A / F |

### 5.4 新槽鏈(04)
**實證 E1**(§9)要回答:
- fresh 槽在 trial 中、以及**被 commit 後**,openmanetd 會不會重開、會不會換 IP;
- 主機怎麼以 eth MAC 重新找到 04;
- `none` 能不能登入。

E1 的結果寫回本節;重開的時機和預期不同 → 該鏈送回審查。

**鏈 0:bypass(L15)**
1. snap。
2. 寫 hold = V → 直接 `batman-slot apply` rc 進 B → 在 B 的 boot FAT `cmdline.txt` 只加 `batman_bypass=1`(先記 sha)。
3. 受控重開(§4.5.0:停 docker / OTS、`sync`、`reboot -f`)→ 落點斷言 + hold 生效。
4. 以 eth MAC 找到 04,用 `none` 登入,斷言:`unknown(bypass)`、helper 沒有產生身分、persist 被拒、96 exit 1 留著。
5. `back_to_a` → restore(類別 F;§4.5.4 會重寫 B,cmdline 也一起恢復)。

**鏈 1:firstboot → gate → unclaimed OTA → (2)**(類別 R;第 7 輪改寫,依 §13.3 E1c 的結果定稿;E1c 沒過就改走 §13.2 的 (b) 案)

共同做法:
- 前段(第 1–6 步)和 E1c 相同:快照 + dead-man(一次性、只在 slot B 動作、6 h 到期);
- 「找到」的判定 = ping 有回應 + ssh 讀到 slot / trial 狀態 + boot_id 是新的;
- trial 內一律 hold,dead-man 種好並讀回之後才 release;
- 失敗出口一律走 `abort_to_a`(§13.3)。

1. snap(p5 映像 + A overlay + p6 state 檔)。joinwatch 停到第 4 步重開。把 p6 的 `mesh-joined` / `mesh-expected` **移進快照目錄**:這是第 8 步 (2) 的前提——有這兩個標記,`claimed:0` 不會免鄰居(§13.4 B-M2)。收尾時放回,compare 會驗。
2. 斷言沒有寫 p5 的程序在跑,p5 也沒被掛載。
3. p5 `mkfs.ext4 -L batconfig`,以 `ro` 斷言沒有 `.seeded`。
4. 寫 hold = V → `BATMAN_ALLOW_UNSEEDED=1 BATMAN_ALLOW_STALE_P5=1 batman-slot apply <rc>` → 斷言 armed;以 `ro` 再斷言 p5 仍未 seed → 受控重開 → 落點斷言(slot=B trial、boot_id 是新的)。
   - 要 `ALLOW_STALE_P5`:P1 的 `--check` 在 rc 7 之前就比 prov,而 overlay 有 legacy prov、p5 剛被 mkfs → rc 5。
   - 直接呼叫 apply,所以沒有 `ota-armed.mesh`(等於 L42 的路徑)。
5. **B 的 HELD trial**,經 eth 找,150 s 內(F34)完成硬性斷言:
   - 沒有 AP 介面;mesh radio 被 keyguard 關;
   - helper log `rc=7`;`prov.meta` = unclaimed;
   - `identity/` 是 0700;p5 的 `identity/prov/` 有 7 檔,sha 正確;p5 沒有 `.seeded`;
   - autocommit log `mesh join required: 0 (prov=unclaimed`、`HELD`。
6. **gate(L44)**:同一個 trial(HELD,所以不會和自動 commit 競賽;B-M1),記下 t0 → `BATMAN_ALLOW_TRIAL_APPLY=1 batman-slot precheck-node`。
   - 正向證據:`p5-check.rc` 的 mtime > t0,內容 = `skip:unseeded`;rc ≠ 0,最後一行 = 「mis-aimed tryboot」(F6)。
   - 負對照:tmpfs 上 wsl.9 的 `batman-slot` → rc 1、「not seeded」、`p5-check.rc` 沒有更新。
   - 種 dead-man,讀回 → `batman-autocommit release --wait` → 斷言 B committed。
7. **unclaimed OTA(B-M4 的回歸測項,第 7 輪插入)**:B 是 committed 的 unclaimed 槽。
   1. **負對照先做**:準備一份 live `/lib/upgrade/platform.sh`(由 98-batman-sysupgrade 從 `platform-ab.sh` 複製)的副本,它的 `RAMFS_COPY_DATA` 少了 `prov-lock.sh`,bind mount 到 `/lib/upgrade/platform.sh`(只在 tmpfs,重開即消失)→ 寫 hold = V → `sysupgrade -n <rc>` → 斷言 sysup log 有 stage 2 的 die、仍在 B committed、A 沒被寫(A 的 `.protected` 不變)→ umount。
   2. **正向**:同一步,不做 bind mount → 進入 A 的 HELD trial(位址可能是 `10.41.254.x`,用「找到」的判定)→ 斷言:sysup log 沒有 die;A 的 trial 是 unclaimed(p5 仍未 seed、helper `rc=7` 或 `rc=0` + `state=unclaimed`、沒有 AP);`HELD`。
   3. `back_to_b`:rollback + `reboot committed`,在 deadline 之前,所以沒有 bad-slot → B committed。
   - 這一步驗的是:unclaimed 節點的 OTA 真的會走過 stage 2 的 `prov-lock.sh` 路徑。拿掉 `RAMFS_COPY_DATA` 那一項,同一步會 FAIL。
8. **(2) claimed + placeholder**(在 B,committed):
   1. 經 mDNS / 掃描重新找到 B(E1c 的找法)。
   2. **認領前的守門**:root 把 lab 公鑰寫進 B 的 `/etc/dropbear/authorized_keys`(檔案 root 0600、目錄 0700)→ 開一條新的 `-o PreferredAuthentications=publickey -o IdentitiesOnly=yes` 連線驗證能登入 → 失敗就中止,走 restore(B 還沒上鎖,`none` 仍可用)。
   3. provclient 認領 → claimed。認領的 `--save` 會 seed p5,包含 lab key 與 B 的個人化。
   4. 再開一條新的 publickey 連線(L47)。
   5. 斷言 p6 沒有 `mesh-joined` / `mesh-expected`(第 1 步已移走;B 的 mesh 被 keyguard 關著,joinwatch 不會寫)。
   6. 寫 hold = V → `sysupgrade -n <rc>` 進 A(閘依 `.seeded` 放行)→ A 的 HELD trial(從 B 的 p5 建,以「找到」的判定找)→ 斷言 autocommit log 有 `mesh join required: 0 (prov=claimed mesh_expect=0`、`HELD`。
   7. **負對照**(同一個 trial,真機):把 `mesh-expected` 放回 p6 → `AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_TIMEOUT=<現在 uptime + 60> batman-autocommit run`(`TIMEOUT` 是絕對 uptime,B-m7)(只評估、只印決定,寫自己的 `autocommit-dryrun.log`,不 commit 也不重開;`batman-autocommit:26-28`、`:44`、`:53`)→ 斷言 log 有 `neighbours required (fail-closed)` 和 `mesh join required: 1` → 再把 `mesh-expected` 移回快照目錄。
   8. `back_to_b` 或 release:release 會讓 A 變成 claimed 的槽,restore 還是會整個蓋回,所以兩者都可以;選 `back_to_b`,少一次 commit。
9. restore(類別 R、同槽):
   - p5 寫回(在 B 上,dead-man 的同一支程式)→ rollback 到 A → A 開機;
   - A 的 overlay 從快照 tar 寫回(`overlay-restore`)→ `reboot committed`;
   - 放回 `mesh-joined` / `mesh-expected`;
   - compare(§13.4 B-M6 的規則)→ brewrite B = V → finish。
**副作用**:04 離開 mesh 約 45–60 分鐘,02 被隔離(lease < 3000 s,超過就把鏈 1 拆成兩個 lease、中間讓 04 回到 mesh);OTS 中斷;B 被覆寫;p5 被 mkfs(有快照)。

### 5.5 autocommit(上層 §6.4 (1)–(10))
所有 hold 的 trial:先斷言 hold 生效(沒有 `HOLD-COMMIT-DISCARDED`),否則立刻 `back_to_a` 並 FAIL。

| # | 程序 | hold | 判讀 | 最終槽 |
|---|---|---|---|---|
| (1) | `-wbox`(radio1 disabled)進 B | 不 hold | `REVERT …mesh` | A;誤 commit → 跨槽重建 |
| (2) | 鏈 1 | — | — | — |
| (3)(L31) | 04 member(隨機網路)→ OTA rc | hold | `HELD` | A |
| (4) | `-wbox-chan`:S99 一次性 init,**等 chanfix 完成的 log 行出現後**(實作時從 `99-batman-chanfix` 原始碼取出那一行的確切字串,寫進測項;150 s 內沒出現 → FAIL「mutant 無效」),用 `uci` + `wifi reload` 改頻道(不用 `halow-setkey`,F10 / F28);前置斷言 trial 在 120 s 內確實不在 mesh,不成立 → FAIL「mutant 無效」 | 不 hold | `REVERT` | A |
| (5) | 刪 `ota-armed.mesh` | hold | `UNHEALTHY first_why=need-mesh…` | A |
| (6) | `-T` 後直接 apply | hold | 同上 | A |
| (7)(L40) | 02 = A 角色:rc,hold;04 = B 角色:`-wbox-chan`,不 hold → 04 revert;preflight 斷言角色分配 | 02 hold / 04 不 hold | 04 `REVERT`、02 `HELD` | 兩台都 A |
| (8) | `ble-ok` 在、`power off` | hold | `HELD` + `WARN ble` | A |
| (9) | `-wbox` helper 每 5 s exit | hold | `HELD` + `WARN health-stale`;不會 commit | A |
| (10)(L41) | 非 root / 容器 root 偽造 caller、相對路徑 → 沒有 `ota-armed.mesh`;另外 `-T`、真 OTA、中止後 LuCI validate 三種 caller 各一次 | — | p6 檔是否存在 | A |

### 5.6 動詞 → 測項
| 動詞 | 正向(真機 `prov-verbs` / 沙箱) | 授權負測試(`prov-unit-auth`) |
|---|---|---|
| `info.*` | 值與 keystore、p6 一致;counter 單調增加 | 非 provd uid |
| `nonce` | 一次性、60 s | 重放、過期 |
| `sign.static / ecdh_proof / peer` | 以 identity 公鑰驗簽;被簽內容由 helper 自己組 | 額度;不採用 client 給的內容 |
| `psks.get` | sha == 自行從 keystore 導出的值;沒有 `owner_tag_key` / `net_root` | — |
| `claim.*` | `prov-claim-254` | CheckMac、錯 owner_pub、10 / h、防呆門 |
| `net.apply` | netjoin / netupdate / powerloss | admins 鏈、首版、COSE 壞、解密失敗 |
| `network.leave` | `prov-leave-ota` | 非擁有者 |
| `owner.add / remove` | add → 新擁有者的 owner-op 被接受(psk_owner ≤ 4);remove → `E_FORBIDDEN`;admins +1 | 跳號、降版、移除最後一位;**§10 第 10 點(與 L29 / S3 衝突)** |
| `settings.get / set` | `get` 依能力分組回目前值;`set` 驗 owner-op 與 schema;**P1 沒有可寫的 key**(上層只定義 hostname,P-U7) | `hostname` → `E_UNSUPPORTED(rename-pending)`;未知 key → `E_SCHEMA` |
| `root_password.reset` | provclient 在程序內以 crypt 對 fd 4 的 shadow hash 比對(§2.2);p5 `shadow-root` 的 sha 改變;再呼叫一次就換新 | 非擁有者 |
| `diag.bundle` | fd 是 O_RDONLY、schema 正確、canary = 0、暫存檔讀完就刪 | 非擁有者 |
| `ssh_keys.set` | 只動 `ssh_keys.added`;key 登入可用 | regex、CR/LF、`command=`、> 8 行 |
| `qr` | legacy + dev-open 時有輸出 | claimed 拒、pts 拒 |
| 不存在的動詞(`keystore.ecdh` / `persist` / `keystore.sign` / 恢復出廠) | — | `E_SCHEMA` |
| CLI | `prov-unit-helper` | — |

### 5.7 上層列 → 測項(完整)
| 上層列 | H2 測項 | 不在 H2(理由) |
|---|---|---|
| L1、L44 | 鏈 1 | — |
| L2、L4 | `prov-base`(三次重開)+ 每天的 `prov-boot` | — |
| L3 | `prov-misc` | — |
| L5 | `prov-ota`、`prov-lock-failsecure` | — |
| L6 | §5.5 | — |
| L7 | `prov-powerloss` | — |
| L8 | — | provd → H3 |
| L9–L11 | helper 側:`prov-misc` | provd 側 → H3 |
| L12 | `prov-downgrade`(characterization) | — |
| L13 | `prov-unit-bcm2710`(smoke) | 真機:等新板 |
| L14 | 全部 | — |
| L15 | 鏈 0 | — |
| L16 | — | 轉賣工具在 P3 |
| L17 | `prov-legacy-upgrade` | — |
| L18、L34、L47 | `prov-claim` | 經 BLE 的流程 → H3 |
| L19 | — | PR-F 已驗(04 ✅ 40/40) |
| L20、L32 | `prov-unit-cfgsave` / `prov-unit-helper`(沙箱) | — |
| L21 | `prov-trial-busy` | — |
| L22 | `prov-leave-ota` | — |
| L23 | — | P-U7 / U5 |
| L24 | — | provd 序列化 → H3 |
| L25、L26 | `prov-netupdate`(L26 的 BLE 部分 → H3) | — |
| L27 | `prov-misc`(dropbear);joinwatch / openmanetd 重啟由既有測項涵蓋 | — |
| L28 | — | 共存 → P2 |
| L29 | — | S3 |
| L30 | `prov-unit-helper` | — |
| L31 | §5.5 (3) | — |
| L33 | `prov-overlay-corrupt` | — |
| L38、L42、L43、L51 | `prov-misc` | — |
| L39 | — | provd → H3 |
| L40 | §5.5 (7) | — |
| L41 | §5.5 (10) | — |
| L59 | — | P3 文件 |
| L60 | `prov-overlay-wipe` | — |
| L61 | 沙箱 | — |
| L62、L65 | H1 `ble-privacy-254`(既有) | — |
| L63 | rollback 到沒有本變更的槽:`prov-downgrade`(characterization)+ H1 N3 | 其餘上層已接受 |
| L64 | `prov-boot`(`sysupgrade -l`)+ H1 | — |
| §6.4、§8、§4.2、§4.3、keep.d | §5.5、`prov-unit-auth` / `prov-sock`、`prov-unit-helper`、`prov-unit-96`、`prov-boot` | (9) 的 provd 版本 → H3 |

(L35–L37、L45、L46、L48–L50、L52–L58 已依 U8 從上層移除。)

## 6. 三個時期(P-U9)
| 時期 | 行為 |
|---|---|
| **H2 merge 後、P1 merge 前** | CI 的 `provisioning-sync`(新 PAIRS 缺檔)與 `prov-sandbox`(沒有 `feed/batman-prov`)**FAIL = 紅燈**,不跳過、不 PENDING;tier A prov-\* FAIL「no helper」,在 known-failures 標 KNOWN(第 4 欄是到期日;過期 = NEW);P9 把 pre-P1 視為 legacy-equivalent。使用者 merge H2 後盡快 merge P1,縮短紅燈期 |
| **P1 merge 前的 rc 驗證** | 兩台都 OTA 到 rc;不混 fleet。wsl.9 的負對照在兩台都還是 wsl.9 時跑 |
| **P1 出貨後** | 下一個 harness PR 刪掉 known-failures 條目 |
| **P2 出貨後** | `prov-sock` 移到 tier B;(9) 的 provd 版本、GATT → H3 |

## 7. 生命週期、副作用、成本

### 7.1 生命週期(H2)
| 路徑 | 行為 | 證明 |
|---|---|---|
| harness 死(沒重開) | deadman:`umount`、重啟 helper、啟動 joinwatch / openmanetd / tailscaled;dirty 標記留著 | 白箱 |
| harness 死(重開後) | dirty 標記接手 | 白箱 |
| snap / restore 中斷電 | 冪等重跑 | `prov-base-254` |
| 停在 trial | restore 第 0 步 | 鏈 0 / 1 |
| commit 到別的槽 | 跨槽重建 | `prov-legacy-upgrade`(反向)、autocommit (1) 的誤 commit |
| A 被重建 | 同槽重建 + overlay 清單斷言 | 鏈 1、overlay-wipe |
| hold 失效 | 立刻 `back_to_a` + FAIL | 白箱:版本不符的 hold |
| helper crash loop | procd respawn | `prov-misc` |
| H1 / H2 同時跑 | lease 互斥 | 白箱 |
| 平台 | 主機端在 Git Bash(簽章子程序在 WSL,E6 實證 pipe);沙箱只在 CI arm64;`prov-artifact-match` 在 WSL。退路:E6 不過 → 主機端整條搬到 WSL,另放一份 lab key(B-m3:WSL ssh 得到 04,只是缺 key) | P9、E6 |
| CI | `prov-sandbox`(arm64 runner、`setup-go` 以 SHA 釘、payload 以 sha 釘);⚠️ arm64 runner 在 H2 PR 實證 | PR CI |

### 7.2 破壞性副作用
| 動作 | 碰到 | 還原 | 斷言 |
|---|---|---|---|
| 每個 tier B 單位 | 04 重開 2–4 次(含 B 寫回 V 的 trial);OTS 每次中斷約 2–3 分鐘 | restore | §4.5.2 第 4 步 |
| 單台網路、鏈 0 / 1、autocommit (1)(4) | 02 被隔離(< 3000 s) | restore | 02 在 `batctl n` |
| 雙台 `net.apply` | 02 `wifi reload`(Morse churn,#132) | 04 先、02 後 | 02 入網 |
| 鏈 1 | p5 mkfs;04 committed 在沒有 mesh、位址可能改變的槽上;認領 | restore(R) | host key 指紋、IP、p5 清單 |
| overlay-wipe / 同槽重建 | F16 | restore 寫回(OTS init 由 95 重建) | overlay 清單 |
| powerloss | OTS DB | OTS 自己恢復 | OTS ready |
| 舊 `dv289-backup-*` | p6 | 不動;先印出再問 | — |

### 7.3 成本(⚠️ 推估)
- **每個單位**:snap 約 1 分 + 測(1–3 次 OTA / 重開;不 hold 的 revert 要等 600 s 期限)+ restore(p5 dd、可能重建、B 寫回 V 的 apply + trial + 回 A)約 15–20 分 = **約 30–45 分**。
- **完整 prov tier B**:約 28 個單位(E3 會量 04 上「開機到 `HELD`」的時間分布,檢查 480 s 夠不夠,A-m9) → **約 15–20 小時**,依 P-U12 連續跑。
  - 04 的 OTS 累計中斷約 4 小時;02 被隔離約 3 小時;SD 寫入約 40 GiB。
  - 依 P-U10,只在動到 prov 的 PR 與發版時跑。
- **沙箱**:CI 約 15 分;`prov-artifact-match` 在 WSL 約 2 分。

### 7.4 無人值守與通知(P-U12)
- 每個單位跑完都回到 S0;單位之間是安全點。
- 需要人處理就停在最近的安全點,不再往下跑,並以推播通知(說明是哪台、哪一步、要做什麼)。需要人處理的情況:
  - restore 斷言 FAIL;
  - 落點落空兩次;
  - 節點連不到超過 10 分鐘;
  - 02 需要重建;
  - 正規化時 freshness 不過;
  - canary 不為 0。
- 節點的狀態不是 S0 時,絕不往下一個單位跑。
- 結束時推播總結:PASS / FAIL / KNOWN 的數量,以及報告的位置。
- **通知的機制**(A-m10 / B-m6):由執行這次 run 的 Claude session 以它的推播通知工具送出,不另存 token。內容只有節點名、步驟、FAIL 原因的類別與報告路徑,不含秘密與 log 原文。
- **節點連不到時**:只通知,不送任何改狀態的指令。
- **最壞情況**:測項單位中途失敗、restore 也失敗。04 會停在非 S0(OTS 可能停擺);若那個單位會隔離 02,02 會一直被隔離,直到 04 回來,或 joinwatch 在 3600 s 時自動重開。通知裡會寫明這些影響。
- **「B ≠ V」自動修**(A-m6 / B-m7):包括 02,用 §4.5.4 的 held trial 修。只有 A 側不符(committed ≠ A 或 A 的版本 ≠ V),才交給人處理;04 例外,可以走跨槽重建。正規化時沒有快照可用,所以 04 的跨槽重建在正規化時不做 tar 覆蓋,只依 96 從 p5 重建,之後先 snap 再開始。
- **02 的 B trial 沒入網而到期 revert**(會寫 `bad-slot`,A-m12):列為需要人處理;清 `bad-slot` 的條件(下一次 B 寫回 V 成功 / `release`)要在通知裡寫明。

## 8. 安全
- **資產**:擁有權、mesh key、root 登入、身分私鑰。
- **測試金鑰**:每次跑隨機產生,測完就刪;擁有者私鑰只在 WSL ext4 0600,fleet key 不離開節點。誠實的界線(B-m9):WSL 的 0600 擋不住同一個 Windows 使用者經 `\wsl.localhost` 讀取;能接受,是因為這把金鑰只控制測試用的認領,而且每次跑都會換。
- **provclient**:root 只用來讀秘密,之後降權為 provd。helper 只收 provd uid,所以降權失敗也會被拒。provclient 本身模擬的就是「被攻陷的 provd」(`prov-unit-auth`、`prov-sock`)。
- **秘密不落地**:tier A 不產生備份 archive(`sysupgrade -l`)。
- **白箱**:bind mount 重開就消失;`-wbox` 只進 B,restore 時被 V 覆蓋,P9 拒絕;`prov_test` 由 build gate 擋下。
- **沙箱**:只在 CI;§4.10 的隔離加負測試;節點上不跑。
- **鏈 1 的上鎖**:只在 publickey 登入已驗證之後才進行。
- **identity 不一致**:fail-closed,且判斷順序防止寫出混合狀態。
- **我們自己的錯**:P9(dirty、`-wbox`、`.protected`、state、全套順序);restore 的整份 overlay 清單斷言。

## 9. 工作順序與 PR
1. 兩位審查到沒有 BLOCKER / MAJOR;§10 回報上層。
2. **實證**(先列副作用):
   - **E1**:04 走鏈 0 流程,payload = wsl.9,p5 不動。觀察 fresh 位址、`none` 登入、openmanetd 在 trial 中會不會重開;**再接著讓它 commit**,觀察 commit 後 openmanetd 的重開與 IP;還原:跨槽重建回 A + B 寫回 wsl.9。副作用:04 離開 mesh 約 30 分、02 被隔離、OTS 中斷、B 被覆寫。
   - **02 p3**(P-U11):掛 02 的 p3(slot B boot FAT;`autoboot.txt [tryboot] boot_partition=2` = p3)→ 備份 `distroconfig.txt` 並記 sha → **插在 `[pi4]` 段 `miniuart-bt` 那一行之後**(不要加在檔尾:檔尾那段是 `[all]`,B-m1),讓 p3 的 `[pi4]` 段和 p1 逐位元組相同 → 讀回驗證 → 卸載。04 的 p3 也唯讀確認一次。P9 依段落解析,不是 grep 全檔。不重開,不碰 slot A。前後各印一次 diff。
   - **E2**:CI arm64 runner 上 `dv-sbx` 原型,含 §4.10 的負測試(在 H2 PR 的 CI 上跑)。
   - **E3**:04 上 §4.5.4「B 寫回 V」連做 ≥ 10 次(用 wsl.9),10/10 落點正確;之後跑 `chk_slotintegrity_209`、`chk_trybootget`、`chk_otatrace`,並確認沒有 `bad-slot`。
   - **E4**:04 上(snap 之後):(a) 只重開一次、比一次 §4.5.5;(b) 只做一次同槽重建(`firstboot -y`),再比一次;(c) 做一輪「tar 寫回 + 重開」再比一次。快照要在 uptime > 2 h 時拍,而且整個過程做兩次,才能涵蓋 F30 在 3851 s / 6340 s 的改寫(A-m2) → 產生附證據的 `overlay-allow.txt`,同時實證 `firstboot -y` 在 f2fs-on-loop 上的行為(F33)。副作用:04 重開 3 次,OTS 中斷約 10 分。
   - **E6**(B-m3):Git Bash ↔ `wsl.exe` 的雙向 pipe(coproc 或 FIFO)跑 20 次 `SIGN` / `SIG` 往返,每次 ≤ 20 s,並且處理 `
`(A-m7)。
   - **E5**:`prov-artifact-match` 的可重現性:WSL 上把同一份 helper 原始碼 build 兩次(OpenWrt 一次、獨立一次)比 sha。
3. P1 實作 → firmware pin → rc(1.5.12-wsl.10)與 `-wbox` 變體。
4. H2 實作 → 兩台 wsl.9 時跑負對照 → 兩台 OTA rc → rc PASS → 白箱 → 全套(含完整 prov tier B)。
5. H2 PR 先 merge;**緊接著** merge P1 PR(`### bcm2711`、`### bcm2710`(真機未測))與 firmware PR;在出貨 build 上重跑全套。

## 10. 回報上層
1. identity 不一致 → `unknown(identity-mismatch)`(P-U6);判斷順序在 gen 之前;`--check` 在 rc 7 之前比對。
2. §6.4 `ble-ok` 改為只 WARN(P-U5)。
3. §10 第 4 點與 §4.3 的 fp 衝突 → 以 §4.3 為準。
4. L25 的最終 state 應為 member。
5. `rc.button/reset` 歸 P1。
6. §6.4 (9) 改為 helper 版本;provd 版本移 H3。
7. (更正 v3)`--prov-only` 不碰 `.seeded` 與上層一致;閘的範圍照 L44,只放行 unclaimed。
8. §10 第 5 點的切法:P-U3 讓 helper 動詞全部在 P1;經 BLE 的流程與 provd 留在 P2 / P3;`settings.set hostname` 依 P-U7。
9. L40 的「改頻道」必須在 chanfix 之後。
10. `owner.add / remove`(§4.1)與 L29「第二位擁有者 → S3」衝突:P1 依 P-U3 實作並測試;請上層確認 S3 指的是 app 端流程。
11. `settings/set` 上層只定義 hostname;P1 沒有可寫的 key。

## 11. 殘項
- P2:provd、GATT、Noise、時間分佈、coex、L8 / L24 / L28 / L39。
- #255:se 後端。
- P3:轉賣工具(要拒收 `-wbox`)、改名(U5)、L59。
- bcm2710 真機測試。
- UART 卡死調查。
- `ble-ok` 恢復阻擋。
- 舊 `dv289-backup-*` 的清理(要問使用者)。

## 12. 對應表

### v5 審查 → v5.1
| 發現 | 處理 |
|---|---|
| A-m1 / B-m5 鏈 1 第 7.6 步 | 改走 `sysupgrade -n` |
| A-m2 允許清單 | E4 在 uptime > 2 h 時做,做兩次,含 tar 回寫 |
| A-m3 / B-m4 tar 覆蓋 upper | 停服務、不可中斷、`sync` + `drop_caches` + 重開 |
| A-m4 受控重開 | 比照 stage 2 卸載 / remount ro |
| A-m5 02 `ble-ok` | 白箱負對照 |
| A-m6 / B-m7 正規化、02 的 B | §7.4 自動修 B;正規化不做 tar 覆蓋 |
| A-m7 / B-m5 不一致 | §5 開頭、§7.1、§4.2 `cryptpw`、`
` |
| A-m8 / B-m8 artifact-match 的界線 | §2.2 |
| A-m9 480 s | E3 量時間分布 |
| A-m10 / B-m6 推播 | §7.4 |
| A-m11 payload 是 tar | §3 |
| A-m12 02 的 `bad-slot` | §7.4 |
| B-m1 p3 寫在哪一段 | §9 插在 `[pi4]`;P9 依段落解析 |
| B-m2 落空時的 tryboot | §4.5.0 先 disarm |
| B-m3 雙向 pipe | E6;退路寫在 §7.1;F32 更正 |
| B-m9 WSL 0600 的界線 | §8 |

### v4 審查 → v5
| 發現 | 處理 |
|---|---|
| A-M1 trial 開機落空 | §4.5.0:寫槽一律走 `sysupgrade -n`(鏈 0 / 1 的受控重開除外);每次開機做落點斷言;重試一次;E3 10/10 |
| B-M1 overlay 比對沒有基線 | §4.5.5:`config/*` 比 `uci export`;允許清單由 E4 實證產生、每條附證據;R 類用快照 tar 覆蓋 |
| B-M2 節點沙箱做不到隔離 | §4.10 只在 CI;`prov-artifact-match` 接到出貨產物;E5 |
| B-M3 02 落到 B | P-U11 先補 02 p3 |
| B-M4 02 失聯路徑 | 正規化不帶 `ALLOW_STALE_P5`;02 只允許逐檔還原,需要重建就 FAIL 並通知 |
| A-m1 / F33 firstboot | E4 |
| A-m2 upper 全覆蓋 | §4.5.1 tar 含 symlink / whiteout |
| A-m3 / B-m3 R 類的 p6 | §4.5.3 寫回 p6 state |
| A-m4 / B-m4 B 寫回的時限 | §4.5.4 480 s |
| A-m5 正規化與 02 | §4.5.0 |
| A-m6 沙箱 caps | §4.10 |
| A-m7 root 密碼比對 | §2.2 fd 4 + 程序內比對 |
| A-m8 dropbear 權限 | §5.4 鏈 1 第 7 步 |
| A-m9 / P-U12 長時間 | §7.4 |
| A-m10 標記的順序 | §4.5.1 第 4 步 |
| A-m11 L63、N3 | §5.7;§4.5.0 |
| B-m1 WSL 沒有 key、NAT | §2.2 主機端改在 Git Bash,只有簽章在 WSL |
| B-m2 鏈 1 第 4 步 stale | §5.4 |
| B-m5 dumpable、stdin | §2.2 |
| B-m6 chanfix 的 log 行 | §5.5 (4) |

### v3 審查 → v4
| 發現 | 處理 |
|---|---|
| A-B1 / B-B1 鏈 1 鎖死 04 | §5.4 鏈 1 第 7 步:認領前寫入 lab 公鑰,以新連線驗證 publickey;失敗就中止;認領後再驗一次 |
| A-M1 / B-N1 作廢 B | P-U8:§4.5.4 B 寫回 V;全套順序(§4.5);P9 |
| A-M2 / B-N2 A 漂移、清單不全 | §4.5.1 清單補上 host key、openmanetd、mesh11sd、config.yml、F16(每次都記);A 重建(同槽 / 跨槽);整份 overlay 清單斷言;指紋 / IP / dhcpconfigured 斷言 |
| A-M3 / B-N3 閘放寬 | §4.9 只放行 unclaimed;`prov-unit-gate` 加 claimed / member 未 seed → 擋;§10 第 7 點更正 |
| A-M4 / B-N4 沙箱隔離 | §4.10;`prov-unit-sbx`;gate 只在 CI 的 loop 卡跑;不在 02 |
| A-M5 gate 判讀 | §5.4 第 6 步的正向證據 |
| A-M6 / B-m3 `sysupgrade -b` | `sysupgrade -l` |
| A-M7 PENDING | P-U9 紅燈 KNOWN,§6 |
| B-N5 identity 漏洞 | §4.8 判斷順序、`--check` 的比對移到 rc 7 之前、`--persist-now` 拒絕、恢復方式寫明 |
| A-m1 修復順序 | §4.5.2 第 1 步先寫回 p5 |
| A-m2 sysupgrade 時序 | 直接 `batman-slot apply` + 手動重開 |
| A-m3 成本 | §7.3 重估 15–20 小時;P-U10 |
| A-m4 install 規則、payload 底 | §2.2、`lint-install` |
| A-m5 / B-m8 §5.7 | 補齊 |
| A-m6 killpoint 位置 | §3 / §4.1 獨立目錄 |
| A-m7 / B-m1 hold 失效、手動 commit | 每個 hold 先斷言生效;用 `batman-autocommit release`;deadline 前回 A;`bad-slot` 斷言 |
| A-m8 / B-m10 `precheck-node` 不唯讀 | F6、§5.4 寫明 |
| A-m9 powerloss 時長 | 各自一個單位 |
| A-m10 bcm2710 | 標為 smoke |
| A-m11 / B-m9 payload 來源 | §3 payload 副本、以 sha 驗證,不用 `ota.tar.gz` |
| B-m2 `claim.secret`、fd 3 | §2.2 / §4.2:root 讀完再降權,不經過 `start-stop-daemon` |
| B-m4 chanfix 時序 | §5.5 (4) |
| B-m5 gate 依 `.seeded` | §5.4 第 7 步 |
| B-m6 Tailscale | §4.5.2 第 1 步停 tailscaled;overlay 清單斷言 |
| B-m7 §5.6 缺漏 | 補上不存在動詞列、`settings` 的範圍、§10 第 10、11 點 |

## 13. 實證結果(2026-10-21,§9 第 2 步)
| 實證 | 結果 | 證據 | 對設計的影響 |
|---|---|---|---|
| E6 主機 ↔ WSL 雙向 pipe | ✅ 20/20 往返,最慢 61 ms,CR 已處理 | `scratchpad/h2/e6` | §2.2 成立 |
| 補 02 p3(P-U11) | ✅ 只在 `[pi4]` 段 `miniuart-bt` 之後加一行;讀回的 sha `2415edfe…` 與 p1 相同;原檔備份在 02 p6 `/opt/batdata/dv-prov/backup/`;04 p3 本來就與 p1 相同 | 指令輸出(對話紀錄) | — |
| E3 B 寫回 V ×10 | ✅ PASS 10/10:每輪都落在 B 的 trial(DT tryboot=1、hold 生效、沒有 DISCARDED);開機到 `HELD` 為 92–105 s;都在期限前回到 A;沒有 `bad-slot`;`slot-B.protected` = V | `scratchpad/h2/e3/e3.log` | §4.5.0 / §4.5.4 成立;480 s 的上限足夠 |
| E1a fresh 槽可達性 | ✅ fresh trial 開機 83 s 後在 `10.41.254.160/16`(br-ahwlan,經 eth)以 MAC 找到;`none` 登入成功;`dhcpconfigured=0`;wsl.9 的 fresh 槽有 AP 介面(= 上層 L1 的負對照) | `scratchpad/h2/e1/e1.log` | §5.4 鏈 0 / 鏈 1 第 5 步可行 |
| E1a fresh 槽自己重開 | ⚠️ 開機後約 **168 s** 以「reboot command」結束;harness 當時沒有送任何重開指令,推論是 openmanetd 保留位址後重開(#11);因為 tryboot 是一次性的,04 直接回到 A | 04 `boot-reasons.log` | **新事實 F34**:fresh trial 內的斷言必須在約 2 分鐘內完成;鏈 0 / 鏈 1 第 5–6 步要依此重排 |
| E1b commit fresh 槽 | ❌ 沒做成:同一個 fresh overlay 第二次開機時,位址已不在 `10.41.254.x`(推論是 openmanetd 保留的正式位址),harness 找不到;期限到了 revert,並寫了 `bad-slot`(測試殘留,已印出後刪除) | 04 `autocommit.log` `TRIAL-REVERTED … mesh not joined` | **推翻鏈 1 第 7 步的前提**:「commit 一個 fresh 槽之後再經 eth 找到它」沒有可行的找法。第 7 步(autocommit (2))送回審查 |
| 還原 | ✅ 一輪 E3 把 B 寫回 wsl.9;B 的 cmdline 沒有 bypass;04 回到 S0(A committed、p6 state 乾淨、02 在 mesh) | `scratchpad/h2/e3/e3-after-e1.log` | — |
| E4 / E5 / E2 | ❌ 尚未:E4 要 04 開機超過 2 h;E5 要等 rc build;E2 要在 H2 PR 的 CI 上跑 | — | — |

**F34**:fresh 槽(`dhcpconfigured=0`)開機後約 168 s 會自己重開(⚠️ 推論為 openmanetd #11)。第二次開機用的是保留後的位址,不在 `10.41.254.x`。

### 13.1 依 E1 修正 §5.4(待審)
- **找到新槽的方法**,依序:
  1. mDNS `<hostname>.local`(✅ 實測:Windows 主機可解析 `BCM2711-6c89.local` → 10.41.1.3;hostname 由 MAC 尾碼決定;⚠️ fresh 槽的 hostname 是否相同,下一次新槽實驗時確認);
  2. ARP 掃 `10.41.254.0/24` 比對 eth MAC(第一次開機用的隨機位址)。

  兩者都找不到 → FAIL,並等 trial 期限讓它自己 revert,絕不盲目送指令。
- **時間窗**(F34):fresh trial 約 168 s 會被 openmanetd 重開。鏈 0 / 鏈 1 第 5–6 步的斷言,要在找到位址後**一次 ssh 批次**做完(目標 ≤ 60 s),並把結果寫進 p6(`/opt/batdata/dv-prov/<run>/fresh-evidence`)。之後就算 trial 被重開回到 A,也讀得到證據。
- **鏈 1 第 7 步((2) claimed + placeholder)改法**:不再要求「commit 一個 fresh 槽之後再認領」。改為:
  1. 在 fresh trial 的時間窗內就完成認領(provclient 經 eth,約 5 s);
  2. 認領的 `--save` 會 seed p5,這時 p5 就是「claimed + placeholder」;
  3. 之後回到 A(重開或 revert),再從 A 以 `sysupgrade -n` 寫 rc 進 B(hold)→ B 的 trial 裡,斷言 autocommit 判「claimed + placeholder → 不需鄰居」並記 `HELD`。

  好處是 A 從頭到尾不換身分,只有 p5 換。注意:A 回來時會看到 p5 是「claimed、身分 Y」,而 A 的 overlay 是 legacy、身分 X → `unknown(identity-mismatch)`(P-U6,凍住)。這正是 P-U6 的真機情境,可以順便斷言 A 凍住:不 persist、`--check` 報 `prov-identity`、OTA 被擋。所以「從 A 寫 B」這一步要帶 `ALLOW_STALE_P5`(只在 04、只在測試裡),或者改成先 restore p5 再做。**這段需要審查決定。**

### 13.2 第 6 輪審查 → 處置(§13.1 作廢,改為下列)
- **B-B1(trial 上認領會 `E_BUSY`)成立,§13.1「在 trial 時間窗內認領」作廢。** 鏈 1 第 7 步改回審查 B 的 (a) 案:
  1. fresh 槽**不 hold**,讓 P1 的 autocommit 依「unclaimed 不需鄰居」自己 commit(A-M1 指出約 95 s 就會 commit,早於 openmanetd 約 168 s 的重開;這正是 (2) 的前半段斷言);
  2. openmanetd 重開、換到保留位址之後,以 mDNS `<hostname>.local` 找到它,並以 ARP 比對 eth MAC(A-m3,防 Windows 的 mDNS 快取回舊位址);
  3. 這時已經是 committed、不是 trial,才認領:先寫入 lab 公鑰並驗證 publickey 登入,再認領;
  4. mesh 被 keyguard 關著 → joinwatch 不會寫 p5 → p5 維持「claimed + placeholder」;
  5. 從 B 以 `sysupgrade -n` 寫 A(hold),在 A 的 trial 裡斷言 autocommit 判「claimed + placeholder → 不需鄰居」並記 `HELD`,證據在重開前寫進 p6(A-m2)。

  前提是先做 **E1c**:fresh 槽 commit、被 openmanetd 重開之後,`<hostname>.local` 仍解析得到,而且 MAC 相符;同時確認是誰下的重開(B-m5)。E1c 不過,(2) 就改成 (b):沙箱單元測試 + autocommit DRYRUN,並明列「沒有真機端到端」。
- **A-M2 / B-M2(凍住不完整)= 產品漏洞,已修**(`feat/254-p1` c392443、b482268):
  - config-save 每個寫入模式在身分不一致時都拒寫;`--prov-only` 拒收和 p5 不同的身分;
  - helper 在 verdict 為 `unknown(*)` 時,改狀態的動詞一律回 `E_STATE`(22)。

  ⚠️ 本地 sanity 8/8(x86,負對照有效)、Go 單元測試 PASS;真機驗證要等 wsl.11。
- **B-M3(rc 13 降級)已修**:只補身分,而且要 `sn` 相符、overlay 的 gen ≥ p5 的 gen;否則 `unknown(identity-lost)`,不寫。附單元測試。
- **B-M4(stage 2 沒有 `prov-lock.sh`)已修**:加進 `RAMFS_COPY_DATA`。新增測項:unclaimed 節點真的跑一次 `sysupgrade -n`(就是上面第 5 步之前、從 committed 的 unclaimed B 做的 OTA);負對照是拿掉 `RAMFS_COPY_DATA` 那一項 → stage 2 die。
- **B-m1(`IsTrial` 判不出來時放行)已修**:rc ≠ 1 都算 trial。
- **B-m3(`--check` 漏掉 p5 沒有身分)已修**:報 `prov-identity-missing`。
- **A-m6 / B-m4(兩台 committed 在 B,不是 S0)**:04 已正規化(A = rc committed,B 寫回 rc)。02 用同一支腳本(一般 OTA,hold,安全方向),之後補上。
- **B-m2(三處寫 prov-state 的判法不一致)**:c1e1c72 統一成 `boot.MeshExpect`,**但我把「key 空的或讀不到」也判成 0,這是 fail-open 的錯誤**(第 7 輪 A-M7 / B-M2 抓到)。31b4751 改正,規則見 §13.4。


### 13.3 E1c(鏈 1 第 7 步的前提實驗;04;≥ wsl.12)— 以 `scratchpad/h2/e1c/e1c.sh` v2 為準
目的:用**真的** unclaimed 新槽驗證 (a) 案的三個事實,沒有證據就不寫進鏈 1。E1a/E1b 用的是 `batman_bypass=1`(verdict = `unknown(bypass)`),不是 unclaimed,所以 E1b 的 revert 對 P1 沒有結論力。

**步驟**(每一步都是斷言,失敗走下方的出口):
1. 前置:A committed、版本 = `VEXP`(= payload 版本)、無 hold / bad-slot;先驗 payload sha 才解壓;記錄 02 的狀態。
2. `prov-base snap`(p5 映像 + A overlay tar,joinwatch 停到重開);dead-man 寫到 p6,讀回語法。
3. p5 沒被掛載、沒有 config-save 程序 → `mkfs.ext4 -L batconfig` → 寫 hold = V → `BATMAN_ALLOW_UNSEEDED=1 BATMAN_ALLOW_STALE_P5=1 batman-slot apply` → 斷言 armed,而且 p5 仍未 seed → 受控重開。
4. **HELD 的 B trial**:掃描 `10.41.254.x` 後,只有「ping 有回應 + 以 `none` ssh 讀到 `slot=B trial_rc=0` + boot_id 是新的」才算找到(A 和 B 同一個 MAC,只比 MAC 沒有鑑別力;A-M2 / B-m1)。在 150 s 內完成(F34:約 168 s 會被重開)。斷言:
   - log 有 `mesh join required: 0 (prov=unclaimed`;
   - 有 `HELD`,沒有 `HOLD-COMMIT-DISCARDED`;
   - 沒有 AP 介面。
5. 在**還 HELD 的時候**種 dead-man:寫 B 的 rc.local,再加一個 25 分鐘的 timer,外加 p6 的 logread 記錄器;讀回 `rclocal=1 script=y timer≥1` 才 `batman-autocommit release --wait`;斷言 B committed。
6. 等 B 停止回應(連續 3 次 ssh 失敗)。之後用 mDNS 找;找不到再掃 `10.41.1.x` / `10.41.254.x`。判定「找到」的條件和第 4 步相同(`slot=B trial_rc=1`);boot_id ≠ commit 時的那個,就是「commit 後被重開」。從 p6 讀前一個 boot 的 logread,找出是誰下的重開(B-m5)。找不到就標 ❓。
7. 收尾:在 B 上用 `setsid` 跑 dead-man,不先刪 rc.local 那行。
   - dead-man 的步驟是 p5-restore(讀回 sha)→ rollback → `reboot committed`,每一步的 rc 都寫進 p6 的 log。
   - 回到 A 後斷言:A committed `VEXP`、沒有 hold / bad-slot;dead-man log 有 `P5-RESTORED <run> sha=<快照 sha>`、`p5-restore rc=0`、`rollback rc=0`;A 的 prov-state 是 `helper legacy legacy`;`--check` rc 0;02 可達而且是 committed。
   - **不比 p5 的原始映像 sha**:A 的 joinwatch 第一次 rw 掛載就會改變它(A-M4 / B-M5)。p5 內容由 dead-man 寫入後讀回的 sha 證明。
8. 呼叫端接著做:brewrite B = V(同時清掉 B 的 overlay,包括 rc.local 那行),然後 `prov-base finish <run>`。

**dead-man 的契約**(B-M5、A-m2):
- 寫的人是 E1c;讀的人是 B 的 rc.local 和 timer。
- 只在 slot B 上動作;一次性(`e1c.fired`);快照超過 6 h 就不動;`e1c.cancel` 存在就不動。
- 每個出口(trap)只要確認 04 在 A committed,就建立 cancel 檔、刪掉 dead-man 腳本、啟動 joinwatch;否則保留 dead-man,並印出它還在 armed。

**trial 內的失敗出口(`abort_to_a`)**:
1. 在 B 上 `rollback` + `reboot committed`,不等 deadline,所以不留 bad-slot;
2. 等 A(最多 900 s);
3. 在 A 上 p5-restore,並刪掉 hold;
4. 900 s 內沒回到 A → 印出「需要人處理」,不做還原。

**副作用**:
- 04 離開 mesh 約 25 分鐘,02 被隔離,遠低於 3000 s 的 lease;OTS 中斷。
- B 被寫兩次。
- p5 被 mkfs,再從映像寫回。
- A 的 overlay 多一個 prov-base 標記檔,`finish` 會刪。
- p6 留下:`dv-prov/<run>`、`e1c-*`、B 的 prov-state / otalog 行(綁 B 的 boot_id;A 每次開機都重寫 prov-state)、B 的 commit 會刪掉 A 的 `ota-armed.mesh`(B 審查確認過;04 平常沒有這個檔)。

**E1c 沒有涵蓋的**:認領(在鏈 1 第 7 步做);Pi 3(ekh-bcm2710:沒有乙太網,fresh 槽找不到 → 只做沙箱 + DRYRUN,並明列)。

### 13.4 第 7 輪審查 → 處置
第 7 輪兩位都判 REJECT,0 BLOCKER(A 7 MAJOR / 11 MINOR,B 6 MAJOR / 10 MINOR),報告在 `review-v7-{A,B}.md`。

**產品**(`feat/254-p1` 31b4751,wsl.12):
- **A-M7 / B-M2(c1e1c72 讓 mesh_expect fail-open)已修,這是我的錯。** 修正後的規則:
  - 只有 mesh key **等於 placeholder** → `0`;key 空的或讀不到 → `today`;
  - 另外,autocommit 的 `claimed:0` 只有在 p6 **沒有** `mesh-joined` / `mesh-expected` 時才免鄰居。有標記代表「進過 mesh、現在卻是 placeholder」= 弄丟了 key → fail-closed。這兩個標記由 joinwatch / `--seed` / `--on-join` 寫入,只有 network/leave 會刪。
  - 負對照:
    - mutant「空 key → 0」→ `TestMeshExpect` FAIL;
    - autocommit case 區塊的 stub:舊版有標記仍得 0,新版得 1;
    - 99zz stub:新版空 key → `today`。
  - **鏈 1 受影響**:04 的 p6 有 `mesh-expected`,第 7 步的 (2) 要先把它們移進快照目錄,收尾時放回。這件事要寫進鏈 1。
- **A-M6(凍住的節點每 15 s rw 掛載 p5)已修**:
  - `--on-join` 遇到身分不一致時,在 run dir 留下 `cfgsave-frozen`,之後的 tick 在掛載前就跳過;其他寫入模式會清掉這個標記。
  - 測試:loop 裝置加 mount 計數,三個 tick 下來,HEAD 是 1→3,新版是 1→1。
- **B-M3(`--persist-now` 繞過凍住與 rc 13 規則)已修**:
  - 改用 `boot.PersistNow`,不跑第二次 `boot.Run`,所以不動 `.stage` / `.txn` / prov-state;
  - 拒絕的情況:bypass、`.txn` 存在(就算格式壞了也拒絕,fail-closed)、p5 讀不到、身分不一致、p5 gen ≥ overlay gen(不降代)、rc 13 但 sn 不同;
  - 測試是 `TestPersistNow`,每一條規則各有一個 mutant FAIL。
- **B-m9(rc 13 的 gen 條件沒有測試)已修**:新增 `TestRc13SameSnOlderGen`,對應的 mutant FAIL。
- **A-m10 / B-m7(提示文字)已修**:`prov-identity-missing` 的文字現在寫出 rc 13 的條件。
- **B-m8(99zz 看「任一個」mesh 介面,Go 只看第一個)**:只有 placeholder 會判 0,兩者唯一會不同的情況是「有多個 mesh 介面、其中一個是 placeholder」。現在沒有這種設定。⚠️ 列為已知差異,不改。

**E1c**:A-M1..M5、B-M1/M5、A-m1..m4、B-m1..m6 全部改進 v2,內容見 §13.3。
- B-m3 改為 `VEXP` 斷言,而且只在 ≥ wsl.12 上跑,因為 A 必須有凍住寫入保護。
- B-m6 改用 `mktemp`。

**H2 harness**(還沒改,在 H2 PR 裡做,落地前不跑 tier B):
- **B-M6(S0 比對在重開後不可能成立)**:prov-base 的 compare 要把帶 boot_id 的 p6 檔(`prov-state`、`ble-ok`、`ota-armed.mesh`、health)從「整檔 sha」改成「去掉 boot_id 欄位後再比」,或者列為允許改變的清單,每一項附理由。負對照:加一個真正的差異 → FAIL。
- **A-M4 / B-M5(p5 原始映像 sha)**:所有測試單位一律比 ro 的檔案清單(§4.5.5),不比原始映像。
- **B-M4 / A-m5(B-M4 的回歸測項沒有鑑別力)**:鏈 1 在第 6 步和第 7 步之間插一步「unclaimed 的 B 以 `sysupgrade -n` 寫 A(hold)」,這時 stage 2 一定會讀 `prov-lock.sh`(斷言 sysup log 沒有 die、A 的 trial 是 unclaimed)。負對照是同一步用一份 `RAMFS_COPY_DATA` 少了 `prov-lock.sh` 的 `platform-ab.sh`(bind mount 到 tmpfs)→ 斷言 stage 2 die、仍在 B。
- **A-m8(`prov-claim` 草稿)**:
  - 認領前先寫入 lab 公鑰,開一條新的 publickey 連線,驗證成功才認領,否則中止(04 平常走 `none`);
  - 覆蓋範圍補齊 §5.3 的清單;canary 也要掃這次跑的全部輸出與 p6 log。
- **A-m6**:config-save 的測試補上 `--if-healthy` / `--seed`,並斷言 p5 檔案清單不變。

**文件**:
- **A-m7**:§5.4 的鏈 1 本文改寫成 §13.2 / §13.3 的 (a) 案,包括 hold、`mesh-expected` 的處理、插入的 unclaimed OTA。
- **A-m9**:F13 更正為 go1.26.4。
- **A-m11**:fleet 版本對齊見下面的「現況」。
- **B-m10**:helper 的 verdict 在整次開機內固定,owner 的動作在下一次開機才會反映到 prov-state。這點要寫進 §3。

**現況(2026-10-21 17:40)**:
- 02、04 都在 S0,`1.5.12-wsl.11+c1e1c72.fw3db3f36`(ROLL11 PASS:兩台的 OTA tier A 全 PASS,04 正規化回 A,兩台的 B 都寫回 V)。
- wsl.11 帶著 A-M7 的 fail-open bug,但兩台都是 legacy(mesh_expect = `today`),沒有實際觸發。
- wsl.12(31b4751)正在編。編好後兩台都升,再跑 E1c。
- B 審查期間,在 WSL 用 GOTOOLCHAIN=auto 下載了 go1.26.4 的 toolchain。這和我們用的版本相同,沒有影響,記錄在此。

### 13.5 第 8 輪審查 → 處置
第 8 輪兩位都判 REJECT,0 BLOCKER(A 5 MAJOR / 14 MINOR,B 4 MAJOR / 15 MINOR),報告在 `review-v8-{A,B}.md`。產品 31b4751 沒有 MAJOR:第 7 輪的 5 個 mutant,兩位都各自重跑過。

**E1c → v3**(`e1c/e1c.sh`;§13.3 的步驟不變,以下是修正):
- **A-M1**:原本用 `pgrep -f`,在 busybox 下會比對到自己(04 上實測回 2)。p5 busy 檢查和 timer 讀回都改成 `ps w | grep -c '[b]atman-config-save'` / `'[s]leep 1500'`。另外新增 **`DRY=1`**:跑完快照、dead-man 的放置與版本檢查後,在 mkfs 之前停下並收尾。**在 04 上先跑一次 DRY。**
- **A-M2 / B-M1**:HELD 與判定行改成輪詢 `logread` 全文,不用 `tail`,直到 t0+150 s;看到 `HOLD-COMMIT-DISCARDED` 立刻停。
- **A-M3 / B-m3**:
  - 重開改用受控重開(停 dockerd、`sync`、`reboot -f`,§4.5.0);
  - 落點:`find_b` 要求 `dt_try=00000001`,而且不能是舊的 boot;
  - 落點失敗、apply 沒 arm、p5 不是 unseeded 的出口,都以 `vcmailbox 0x00038064` disarm(跟 `batman-slot` 的 `disarm_tryboot` 同一組呼叫)並還原 p5。
- **A-M4 / B-M3**:重開前,用唯讀 loop 掛起 payload 的 `root.squashfs`,斷言 `BATMAN_VERSION` == `VEXP`(= A 的版本 = hold 的值)。不符就停,這時還沒有任何改變。
- **A-M5 / B-m4**:`abort_to_a` 回到 A 之後:
  1. disarm;
  2. 印出 bad-slot 再刪除(這是本次測試的殘留);
  3. 以 `timeout 900` 跑 p5-restore,並斷言 `P5-RESTORED`;
  4. **重開 A**,用 `a_healthy` 斷言:helper 這次開機寫的 verdict 是 legacy、`--check` rc 0、helper 在跑、沒有 bad-slot。
- **A-m1**:`e1c.fired` 改成 rollback 成功後才寫,所以中途斷電時,下次進 B 會重試。
- **A-m2 / B-m5**:dead-man 不再用時間判斷到期(節點沒有 RTC,時鐘靠 faketime)。改為 dirty 旗標仍寫著本次 run 才動作;`finish` 會刪掉 dirty 旗標。
- **A-m5**:B 的 rc.local 開機時 `ping -c 5 <主機>`,讓主機的 ARP 學到它。`find_b` 依序找:ARP(任何網段、04 的 MAC)→ `10.41.254.x` 掃描 → `10.41.1.x` 掃描。
- **A-m6 / B-m15**:主機端互斥鎖 `$TEMP/batman-dv-04.lock`。prov lease 在 H2 的 lease 機制落地後改用它(H2 殘項)。
- **A-m7**:busy 檢查到 mkfs 之間沒有持 `cfgsave.lock`。⚠️ 接受的理由:joinwatch 從 snap 起就停著;helper 只在開機和 owner 動作時寫 p5,這段期間兩者都沒有。
- **A-m8 / B-m10**:DONE 時刪除 `payload-e1c/` 與 `e1c-*`;dead-man 的 log 搬進 run 目錄,由 `finish` 一起刪。
- **A-m9**:`FRESHO` 的信任界線已寫進腳本開頭:只在 lab LAN 上對 fresh B 使用,不傳送秘密。§13.3 補同一段。
- **B-m6**:前置條件加上 `a_healthy`(含 `--check` = 0);BT 為空就 abort;recorder 和 timer 改用 `setsid`;讀回改在另一條 ssh session 做。

**產品**(`feat/254-p1` 6e3a8c1):
- **A-m10 / B-m1(rc 10 會降代)已修**:
  - `--prov-get` 在 rc 10 時,交出原始 meta 與 identity,不交 cbor;
  - `boot.Run` 的 case 10 只在「meta 解析得出 gen、而且 ≤ overlay」時才補寫,否則 `unknown(prov-corrupt)`、不寫;
  - `PersistNow` 在 gen 讀不到時拒絕。
  - **這改變了上層 §4.2 第 10 列**(原本是「重寫 overlay 的」),要回報上層原單。
  - 測試:`TestRc10NeverDowngrades`,2 個 mutant 都 FAIL;loop 裝置測試 `cfgsave-provget-rc10`,舊版 FAIL。
- **B-m2(`identity_mismatch` 要兩邊都有 sha256 才成立)**:⚠️ 暫不修,理由如下:
  - p5 身分不完整就是 rc 13 的情況,boot path 已經依 sn 與 gen 處理;
  - 要在 config-save 擋,就得放行 `--prov-only` 的身分補寫,會和 rc 13 的修復互相牽動。
  - 列為已知缺口:p5 身分殘缺時,`--on-join` 仍可能把設定寫到殘缺身分旁邊;下一次開機時 helper 會判 identity-lost 並凍住。
- **B-m12**:同 §13.4 B-m8,已知差異。
- **B-m13(`--seed` 寫 `mesh-expected`)**:這是刻意的設計:seed 過的節點應該在 mesh 裡。代價是:操作員對一個 claimed + placeholder 的節點做 `--seed` 之後,它之後的 OTA 都要有鄰居才會 commit。要寫進操作文件。

**H2**(`harness/254-h2`):
- **A-m11 / B-m11**:5 支 shell 回歸測試進了 `tests/prov-p1/`(e48ec83),每支都有舊版 FAIL 的負對照。CI 還沒接上,`go test` 也還不在 CI 裡,這屬於 H2 的 CI 殘項。
- **A-m12(compare 在 diff 目錄不存在時 fail-open)已修**(d8beab9):建目錄;寫不出來或少了 manifest 就 die。舊版對真實差異回 rc 0,新版 10/10。
- **A-m13 / B-m14**:`prov-claim` 草稿的殘項(canary 範圍、restore 與重開拆成兩條 ssh、§5.3 覆蓋)放在 H2 的 tier B 實作時一起做。
- **A-m14 / B-m8**:鏈 1 第 7 步之後,A 已經被重寫,`abort_to_a` 回到的 A 不是已知良好的狀態。鏈 1 實作時要分段,第 7 步之後的 abort 要走 overlay-restore。這點已寫進鏈 1 第 9 步,實作時加斷言。

**鏈 1 文字修正**:
- **B-M2**:負對照的路徑改為 live 的 `/lib/upgrade/platform.sh`(由 98-batman-sysupgrade 複製)。機制 B 已對照原始碼確認(procd 的 chroot 與 `install_file`)。
- **B-m7**:
  - DRYRUN 要帶 `run` 參數;
  - `AUTOCOMMIT_TIMEOUT` 是絕對 uptime;
  - 節點 LOCKED 之後,「找到」改用 publickey;
  - 第 7.2 步套用 F34 的時間預算;
  - 04 目前有 `ota-armed.mesh`,第 1 步要一起移開。
- **B-m9**:「拆成兩個 lease」做不到。照實寫:02 隔離超過 3600 s 時,joinwatch 會重開它一次。鏈 1 要控制在 3600 s 內,否則就接受 02 重開一次,並在結果裡記錄。

**B-M4(現場生命週期缺口)→ 需要使用者決定**,見 §13.6。

### 13.6 F34 的成因(openmanetd 原始碼已確認)與 B-M4(使用者已決定:P-U13,見 §13.8.1)
openmanetd 1.3.10 原始碼(`build_dir/.../openmanetd-1.3.10`)確認:
- **誰重開**:`AddressReservationWorker.ReserveAddressIfNeeded`(`internal/mgmt/address_reservation.go:36-176`)。觸發條件是 `!configured || ipConflictDetected`(`:78`);`dhcpconfigured` 為 0 或空時,`configured` = false(`internal/network/uci_openmanet.go:211`)。依序:
  1. 選 IP;
  2. 寫 network / dhcp;
  3. 寫 `dhcpconfigured=1`,commit;
  4. 刪 `lan`、reload;
  5. 執行 plain `reboot`(`internal/system/system.go:9-10`)。
  - **沒有任何 tryboot / 升級檢查**。
  - Batman feed 裡沒有其他元件會因為位址改變而重開。
- **時間**:ticker 是 125 s(`internal/mgmt/mgmt.go:21`),第一次觸發就在 openmanetd 啟動後 125 s。openmanetd 的 init 在 bat0 up 時會重啟它,計時從頭算。所以 F34 的 168 s ≈ openmanetd 啟動(約 40 s)+ 125 s。**不需要鄰居**:只要 `batctl mj` 成功(bat0 存在)就會觸發。
- **新 IP**:非 gateway 模式下,已知節點 ≤ 1 時是**亂數**的 `10.41.<1-252>.<1-254>`(`uci_network.go:724-739`)。所以只能用 mDNS 或 ARP 找(E1c v3 已改成讓 B ping 主機)。
- **hostname**:由 MAC 末 4 碼決定(`99-halow-identity:9-17` → `morse.sh:8-55`),04 是 `…-6c89`。
- **開關**:
  - openmanetd YAML `alfred.dataTypes.addressReservation`(預設 true,`config.go:33,413-416`);
  - 或 `dhcpconfigured=1`(遇到 IP 衝突時仍會觸發)。
- **上游 bug**:`ipConflictDetected` 一旦設成 true 就永遠不會清掉(`:39`、`:69`)。之後每個 tick 都會重新保留位址並重開,也就是重開迴圈。要另外回報上游(要先問使用者)。

**B-M4 的現場影響(確認)**:P1 開放了 unclaimed 節點的 OTA(L44)。這種 OTA 一定是 fresh 槽,因為 p5 沒有 seed,96 沒有東西可以還原。
- trial 裡會發生兩件事,而且互相競賽:
  - autocommit 約 95–105 s commit(Pi 4 實測);
  - openmanetd 約 165 s 執行 plain `reboot`。
- Pi 4 有約 60 s 的餘裕。Pi 3 ❌ 沒有量過,這是民用主力 SKU。
- 如果 `reboot` 先到:tryboot 是一次性的,節點會回到舊槽,不留 bad-slot,OTA **無聲失敗**。
- 如果 `reboot` 落在 commit 寫入的期間:⚠️ 推論可能損壞(依 B 引用的 autocommit 註解),沒有實測。

**選項**(需要使用者決定;決定會改變 E1c 的預期,所以在決定之前不跑 E1c 的破壞性部分):
1. **產品端讓位址保留等 trial 決定之後(建議)**:
   - 只在 fresh 槽處於 tryboot trial 時,`99-halow-identity` 先寫 `dhcpconfigured=1`,讓 worker 不觸發,並在 p6 留一個標記;
   - autocommit commit 之後,看到標記就把 `dhcpconfigured` 設回 0 並重啟 openmanetd → 125 s 後保留位址並重開,這時已經 committed,會回到同一槽;
   - 不改上游。代價是 commit 後多一次 openmanetd 重啟,外加原本就有的那一次重開。
   - 要新增測項:Pi 4 / Pi 3 都要斷言 trial 內不重開、commit 後才保留位址。
2. **接受競賽**:Pi 4 有 60 s 餘裕;Pi 3 要用 serial 量。03 目前停用,所以要等硬體。
3. **只回報上層原單,之後再處理**:P1 照現狀出,並明列「unclaimed OTA 在慢的板子上可能無聲失敗」。

### 13.7 (作廢,見 §13.8)B-M4 修法 v1:改 config.yml 暫停位址保留
**要解決的現場問題**(§13.6):unclaimed 節點做 OTA 時,一定開進 fresh 槽。openmanetd 啟動後 125 s 會保留位址並執行 plain `reboot`,不管是不是 trial。這個 `reboot` 若比 commit 早到,OTA 會無聲失敗。

**機制**:用 openmanetd 自己的開關 `alfred.dataTypes.addressReservation: false`(`config.go:413-416`,在 `mgmt.go:122` 啟動時判斷)。不偽造 `dhcpconfigured`。理由:`halow-status`、`joinwatch` 用 `dhcpconfigured` 標示位址狀態;config-save 會把它連同 IP 存進 p5。偽造成 1 會在 p5 留下 bootstrap IP + 已保留,之後從 p5 還原的槽永遠不會再保留位址。
1. **進入暫停**(`99-halow-identity`,只在 fresh 槽個人化時跑):寫完 `dhcpconfigured=0` 後,若 `batman-slot is-trial` rc = 0(這次開機是未 commit 的 trial),而且 `/etc/openmanetd/config.yml` 沒有頂層的 `alfred:` 鍵,就在檔尾附加一段固定區塊(開頭與結尾各有 `# batman-addr-defer` 註記行),內容是 `alfred: dataTypes: addressReservation: false`;同時寫 p6 標記 `/opt/batdata/state/addr-defer` = `<slot>`。
   - 已經有 `alfred:` 鍵 → 不暫停(合併 YAML 有風險),記 WARN,行為與今天相同。
   - `is-trial` ≠ 0(新卡第一次開機、讀不到)→ 不暫停,維持今天的行為。
2. **解除暫停**(`batman-autocommit` 的 `addr_defer_release`)。呼叫點:
   - autocommit commit 成功之後(`:537`);
   - 操作員 commit 之後(`:551`);
   - 每次開機時,running slot 已是 committed 的路徑(`:326`):這是補救點,處理 commit 後、解除前當機或斷電的情況。

   動作:
   - 只刪 config.yml 中兩行註記之間的區塊,而且刪除前先比對內容完全等於我們寫的那段(不等就不動,記 WARN);
   - 刪 p6 標記;
   - openmanetd 正在跑就 `/etc/init.d/openmanetd restart`。125 s 後它會照常保留位址並重開,這時槽已經 committed,會回到同一槽。
   - 標記寫的不是這個槽:另一個槽是 trial 失敗被退回的,它的 overlay 只能經由 `apply` 重寫才會再被開,所以只刪標記、不動 config.yml。
3. `is-trial` = 2(讀不到)→ 不解除(fail-closed)。代價是位址保留延後;節點仍可經 bootstrap IP / mDNS 連到。

**擁有權**:
- config.yml 的暫停區塊:寫的是 `99-halow-identity`,刪的是 autocommit 的 `addr_defer_release`;openmanetd 只讀。
- `addr-defer` 標記:寫入者同上,刪除者同上。
- 其他人都不碰。config-save 不持久化 config.yml,所以不會帶到 p5(✅ 04 實查:`batman-config-save:48-49` 只持久化 uci 的 `openmanetd.config.dhcpconfigured` / `roipconfigured`)。

**契約**:
- 區塊格式固定,內容必須完全相符才刪。
- 標記內容 = `A` 或 `B`;缺少或格式不對 → 只看 config.yml 有沒有區塊:有區塊、而且這個槽已 committed → 解除。
- 能寫的人:只有 root(✅ 04 實查:`/opt/batdata/state` 是 root 0755;config.yml 是 root 0600)。

**生命週期**:
| 路徑 | 今天 | 改後 | 證明 |
|---|---|---|---|
| 新卡第一次開機(不是 trial) | 125 s 後保留位址並重開 | 不變 | stub 測試:is-trial=1 → 不寫區塊 |
| unclaimed OTA(fresh 槽 trial) | 和 commit 競賽 | trial 內不保留位址;commit 後 openmanetd 重啟,約 125 s 後保留並重開回同一槽 | E1c v4:trial 內 165 s 以上不重開;commit 後保留、重開、`dhcpconfigured=1`、還在 B |
| legacy / claimed 的 OTA(從 p5 還原) | `99-halow-identity` 跳過 | 不變(跳過,不暫停) | 既有的 OTA tier A |
| trial 被退回(revert) | 回舊槽 | 回舊槽;舊槽 committed 開機時刪掉別槽的標記 | stub |
| commit 後、解除前當機或斷電 | — | 下次開機走 `:326` 補救點 | stub:committed + 區塊 → 解除 |
| 操作員手動 `batman-slot commit` | — | 下次開機走補救點 | stub |
| 降版到沒有這個改動的版本 | — | 只有新版 fresh 槽才會寫區塊,而那個槽的 autocommit 就是新版;舊版 A 不受影響 | 推論:兩個寫入點都在同一個新版槽 |
| openmanetd 自己重啟(bat0 up) | — | 仍會讀到區塊 → 仍然暫停,直到解除 | 原始碼:`mgmt.go:122` 在每次 Start 判斷 |
| Pi 3 / Pi 4 | 相同 feed | 相同 | stub 兩板一致;真機只有 Pi 4(03 停用) |

**依賴的證據**:
- viper 讀 `/etc/openmanetd/config.yml`(`cmd/root.go:80-88`);
- `IsSet`/`GetBool`(`config.go:413-416`);
- worker 只在 Start 時啟動(`mgmt.go:122`);
- 04 的 config.yml 和 /rom 相同,沒有 `alfred:` 鍵(2026-10-21 實查);
- `keep.d/openmanetd` 會在一般 sysupgrade 時保留 config.yml,但 `-n` 不保留。

**安全**:
- 沒有新的對外輸入;寫入者都是 root 的開機腳本。
- 攻擊者若能寫 config.yml 或 p6 state,本來就已經是 root。
- fail 方向:讀不到 trial 狀態 → 維持暫停,也就是不重開,這是安全方向;代價只是位址晚一點保留。

**測項**:
- `tests/prov-p1/addr-defer.sh`(stub):進入暫停的判斷;解除時的精確比對與各條路徑。負對照是舊版 `99-halow-identity` / autocommit。
- 真機:E1c v4(取代 v3 的 (2)「誰重開」):trial 內不重開;commit 後才保留位址並回到同一槽。

### 13.8 B-M4 修法 v2:用環境變數關掉 trial 內的位址保留(取代 §13.7;元件 1、3 與契約的定稿見 §13.8.2)
**§13.7 作廢**。第 9 輪兩位都 REJECT,根因相同:config.yml 有第二個寫入者(openmanetd 會以 yaml.v3 整檔重寫,`persist.go:19-60`、`frontend/handlers.go:772-814`);改檔不是原子的;壞 YAML 會讓 openmanetd 靜默改用全部預設值(`root.go:96-98`)。改 config.yml 這條路不安全。

**機制**:openmanetd 用全域 viper,`initConfig` 在 `--config` 之後呼叫 `viper.AutomaticEnv()`(`cmd/root.go:80-92`)。所以環境變數 `ALFRED.DATATYPES.ADDRESSRESERVATION=false` 就能關掉 worker,config.yml 一個位元都不動。
- **✅ 實測**:`scratchpad/h2/src/envprobe.sh` 用 openmanetd 1.3.10 自己的 `internal/config`(viper v1.21.0,離線 module cache)讀 04 的 `/rom` config.yml:
  - 不設 → `addressReservation=true`;
  - 設 `…=false` → `false`;
  - 底線版 `ALFRED_DATATYPES_ADDRESSRESERVATION` → 無效(`true`);
  - 三種情況下其餘設定(`gnss.enable=true`)都不變。

**元件**:
1. **(作廢,見 §13.8.2:決定者不呼叫 `is-trial`,也不寫 `addr-deferred`)決定者 `/usr/libexec/batman-addr-defer`**(Batman feed,新檔,root 0755):沒有狀態,每次 openmanetd start 時呼叫一次。
   - `batman-slot is-trial` rc 0 → 暫停;
   - rc 2 而且 DT `tryboot=1` → 暫停(fail-closed:判不出的 trial 不讓它被重開);
   - 其他(rc 1 = committed、rc 2 但不是 tryboot、找不到 `batman-slot`)→ 不暫停,和今天一樣。
   - 暫停時寫 `/tmp/run/batman/addr-deferred`(tmpfs,只活這次開機;內容是 boot_id),並記 log。
   - 進入條件**和槽是不是 fresh 無關**(第 9 輪 A-M3、B9-m1):任何未 commit 的 trial 都暫停。對 `dhcpconfigured=1` 的還原槽,暫停沒有副作用,因為 worker 本來就不會觸發。
2. **掛勾**:board patch `0014-openmanetd-addr-defer-254.patch`(`patches/ekh-bcm2711` 與 `patches/ekh-bcm2710`),改的是 `feeds/openmanet/openmanetd/files/openmanetd.init`:在 `procd_set_param command` 之後加一行
   `[ -x /usr/libexec/batman-addr-defer ] && /usr/libexec/batman-addr-defer && procd_set_param env ALFRED.DATATYPES.ADDRESSRESERVATION=false`
   - witness:`file /etc/init.d/openmanetd batman-addr-defer`(#275)。
   - 上游的版本已釘住(`feeds.conf.default`)。上游改了 init,patch 會在 build 時失敗,不會靜默失效。
3. **(作廢,見 §13.8.2:無條件 detached `start`,不用旗標判斷、不 `restart`)解除**:`batman-slot commit`(唯一的 commit 實作,autocommit 和操作員都經過它)。commit 成功、`sync` 之後,如果 `/tmp/run/batman/addr-deferred` 存在而且是這次開機寫的,就刪掉它,並 `/etc/init.d/openmanetd restart`。restart 時決定者看到 rc 1 → 不暫停 → worker 125 s 後保留位址並 plain `reboot`,這時已 committed,會回到同一槽。

**(此段的旗標 / `restart` 細節已被 §13.8.2 取代)為什麼不會卡住**(第 9 輪 A-M4、B9-m3):狀態只存在環境變數和 tmpfs 裡,下一次 openmanetd start(bat0 up、重開、手動 restart)一定重新判斷。
- 唯一會延後的情況:commit 之後、restart 之前,`batman-slot` 被殺掉,而且之後一直沒有 openmanetd restart。
- 為此 `halow-status` 加一項:已 committed 而且 `addr-deferred` 存在 → **WARN**,寫明原因和處理方法(`/etc/init.d/openmanetd restart`)。
- daily-validation tier A 加斷言:committed 的槽不能有 `addr-deferred`;settle 之後要 `dhcpconfigured=1`(H2)。

**擁有權**:
- 環境變數:procd instance,由 init 的掛勾設定,只看決定者的結果。
- `/tmp/run/batman/addr-deferred`:決定者寫,`batman-slot commit` 刪。
- `halow-status` 只讀。
- config.yml:不碰。

**契約**:
- `addr-deferred` 的內容 = boot_id。內容不符或格式壞掉 → `batman-slot commit` 照樣 restart openmanetd。多一次 restart 沒有壞處,是安全方向。
- 決定者讀不到 trial 狀態而且是 tryboot → 暫停;不是 tryboot → 不暫停。

**生命週期**:
| 路徑 | 今天 | 改後 | 證明 |
|---|---|---|---|
| 新卡第一次開機(不是 trial) | 125 s 後保留並重開 | 不變 | stub:rc 1 → 不暫停 |
| fresh 槽 trial(unclaimed OTA) | 和 commit 競賽 | trial 內不保留;commit → restart → 保留 → 重開回同一槽 | E1c v4 + 負對照(wsl.12 上同一流程應在 trial 內重開) |
| 還原槽 trial、`dhcpconfigured=0`(認領或 `--seed` 發生在保留之前) | 同樣競賽 | 同上 | stub + 鏈 1 |
| 還原槽 trial、`dhcpconfigured=1` | worker 不觸發 | 暫停,沒有影響 | stub |
| trial 被退回 | 回舊槽 | 回舊槽;tmpfs 旗標隨重開消失 | 推論:tmpfs |
| commit 後、restart 前當機 | — | 下一次 openmanetd start 重新判斷;halow-status WARN | stub |
| 操作員手動 `batman-slot commit` | — | 同一條解除路徑 | stub |
| openmanetd 自己 restart(bat0 up) | — | 每次 start 都重新判斷 | 原始碼:init 的 `start_service` |
| 降版到沒有這個改動的版本 | — | 舊 image 沒有掛勾,行為和今天相同 | build:舊 image 沒有 patch |
| Batman feed 沒有決定者(只有 patch) | — | `[ -x ]` 不成立 → 不暫停 | stub |
| Pi 3 / Pi 4 | — | 同一個 patch(兩板各一份)、同一個決定者 | witness 檢查兩板;真機只有 Pi 4 |

**現場影響**(B9-m8):暫停期間節點停在 bootstrap IP(`10.41.254.<2-254>`,隨機)。
- 只會持續到 commit,通常 ≤ 600 s 的 deadline;hold 的 trial 例外,會一直持續到 release。
- 期間 bootstrap IP 有可能和別的節點碰撞,這和今天 fresh 槽前 125 s 的情況相同。
- 寫進操作文件:**hold 期間不要按網頁的「重開」**(B9-m7)。那是 openmanetd 自己的另一條 plain reboot 路徑,trial 會無聲退回。

**commit 後的保留重開**(A-m4、B9-m4):約在 commit 後 125–170 s,而這正是操作員最可能去認領的時候。
- 認領被重開打斷時,由 `.txn` 與 `--apply-state` 收尾(§4.4 第 6 步)。這條路要在鏈 1 加一項測試:在保留重開期間認領。
- plain `reboot` 在 Pi 4 上可能先落到 partition 0,再由自檢修正(`batman-reboot.c:2-6`)。E1c v4 要記錄,但不判 FAIL。

**安全**(B9-m9):
- 沒有新的對外輸入。決定者由 root 的 init 呼叫,只讀 DT 和 `batman-slot`。
- 網頁使用者可以改 config.yml,但改不了 procd 的環境變數,所以這個暫停不受網頁影響。
- 這比 §13.7 強:§13.7 的狀態放在 config.yml,網頁使用者寫得到。

**測項**:
- `tests/prov-p1/addr-defer.sh`(stub):
  - 用 stub 的 `batman-slot` / DT 驅動決定者:rc 0、rc 1、rc 2 有 tryboot、rc 2 沒 tryboot、找不到 `batman-slot`;
  - `batman-slot commit` 的解除:有旗標才 restart,沒有就不 restart;
  - 對打過 patch 的 init 做 rc.common 模擬,斷言有暫停時 procd 收到那個 env。
  - 負對照:沒打 patch 的 init 收不到 env。
- 真機 E1c v4,斷言照兩位第 9 輪列的清單:
  - **trial 內**:有 `addr-deferred`;這次開機沒有出現 `AddressReservationWorker initialized`;openmanetd 啟動後撐過 300 s;
  - **release 之後**:B committed;`addr-deferred` 已刪;openmanetd 換 pid,恰好出現一次 worker initialized;125–200 s 內出現 `Rebooting system to apply new network settings`;
  - **新的那次開機**:B committed;`dhcpconfigured=1`;IP 不在 `10.41.254.x`;撐過 300 s,沒有第二次保留重開。
  - **負對照**:同一支 v4 跑在 wsl.12 上,預期 B 在約 165–200 s 時在 trial 內重開並退回 A。這同時是 B-M4 的真機重現,符合「先重現再修」。
- Pi 3:❌ 沒有硬體(03 停用),只有 stub 與 witness。

**§13.8 的依賴證據(環境變數從 init 到 openmanetd 的整條路)**:
- `procd_set_param env K=V` → `_procd_add_table_data`(`package/system/procd/files/procd.sh:125-133`)→ `json_add_string "$var"`。jshn 遇到名稱含 `.` 時,shell 變數名換成 `_`,但另存原名 `N_<cur>_<var>=$2`(libubox `jshn.sh:58-59`),所以 JSON 的鍵保留 `ALFRED.DATATYPES.ADDRESSRESERVATION`。
- procd 依原名 `setenv(blobmsg_name(var->data), …)`(`procd service/instance.c:480-481`)。env 改變會讓 instance 被視為不同(`:960`)。
- viper 依原名讀(`envprobe.sh` 實測)。
- ⚠️ 節點上的端對端效果(這次開機沒有出現 `AddressReservationWorker initialized`)要等 rc 上的 E1c v4 證明。

#### 13.8.1 第 10 輪 → 修訂(兩位都是 APPROVE-WITH-CHANGES,各 1 MAJOR,都在「解除」)
**使用者決定紀錄**:**P-U13**(2026-10-21):B-M4 在產品端擋住,也就是 trial 期間不讓 openmanetd 保留位址。實作方式是 board patch 對上游 init 加一行掛勾:上游檔只多一行呼叫,判斷邏輯全部放在 Batman feed。§13.6 的「待使用者決定」到此結案。

**修訂後的規則**(取代 §13.8 的元件 1、3 與契約):
1. **決定者 `/usr/libexec/batman-addr-defer`**:只輸出結果,不寫任何檔案。
   - 判斷順序:
     1. DT `tryboot` ≠ 1 → 不暫停。#133 stale fallback 和一般開機都屬於這一類(A-m1 / B10-m4)。這也避免 Pi 3 在一般開機時每次都掛載 p7(B10-m2 / A-m2)。
     2. `$RUNDIR/slot-committed` 存在 → 不暫停。這個旗標由 `batman-slot commit` 寫,用來序列化(A10-M1(b)(c))。
     3. `batman-slot is-trial`,上限 10 s(✅ 04 實查沒有 `timeout` 指令,改用背景執行 + 輪詢 rc 檔 + 逾時 kill):rc 0 → 暫停;rc 2 或逾時 → 暫停(這時已確定是 tryboot,判不出來就 fail-closed);rc 1 → 不暫停。
   - 決定者有 10 s 的時間上限(A-m4)。
2. **權威狀態**:「現在有沒有在暫停」只讀 `ubus call service list '{"name":"openmanetd"}'` 裡 instance 的 env(procd `instance.c:1685-1691`),不讀旗標(A10-M1(a))。
3. **commit 的契約**(`batman-slot cmd_commit`,A-m3):
   1. commit 寫完並 `sync` 之後,以 `batman_rundir` 建立 `$RUNDIR/slot-committed`(#280,B10-m3 / A-m9);
   2. **無條件**執行 `setsid /etc/init.d/openmanetd start </dev/null >/dev/null 2>&1 &`(B10-M1)。`start` 讓 procd 拿新的 instance 定義比對:env 有變就在內部原子地重啟(`instance.c:1564-1575`),沒變就什麼都不做。不先 stop,所以 PTY hangup 殺不到中間狀態;
   3. 這一步的 rc **不影響** commit 的 rc。
4. **對帳**(冪等):joinwatch 每個 tick、`halow-status` 每次都做。「不該暫停」的條件 = DT `tryboot` ≠ 1,或 `slot-committed` 存在。
   - 不該暫停,但 ubus env 有那個變數 → joinwatch 記 WARN,並以同樣的 detached `start` 修正;halow-status 報 WARN。
   - 這不需要呼叫 `is-trial`,所以 Pi 3 不會每個 tick 都掛 p7。
5. **daily-validation tier A**(H2,#290):
   - committed 的槽,ubus env 裡不能有那個變數;
   - settle 之後要 `dhcpconfigured=1`;
   - image 裡要同時有 witness 字串和決定者。只有其中一個 = FAIL(A-m5)。wsl.12 沒有這兩者,依 P-U9 標 KNOWN,並寫期限。

**新增或改寫的測項**:
- `tests/prov-p1/addr-defer.sh`(stub,跑在 busybox ash,用 image 建出的 init,B10-m8)。案例:
  - tryboot=0 → 不暫停;
  - tryboot=1 + rc 0 → 暫停;
  - tryboot=1 + rc 2 → 暫停;
  - tryboot=1 + `slot-committed` → 不暫停;
  - (作廢:§13.8.2 的決定者不呼叫 `is-trial`)`is-trial` 卡住 → 10 s 內回來,而且暫停;
  - commit 後 `start` 被送出,commit 的 rc 不受影響;
  - 對帳:env 有 + `slot-committed` → 送出 `start`;
  - stop 之後模擬 SIGHUP:新設計不經過 stop,所以 openmanetd 仍在跑。
  - 負對照:§13.8 的 v1 規則(只看旗標、用 restart),上面三個 A10-M1 的案例 + SIGHUP 案例都會 FAIL。
- E1c v4,要有正向證據(B10-m5 / A-m8):
  - 每個 openmanetd pid 都有 `Alfred Client Started`;
  - trial 內 ubus env 有變數,`/proc/<pid>/environ` 也有;
  - trial 內 `kill` openmanetd 一次 → procd respawn → 新 pid 的 env 仍有變數,而且沒有 `AddressReservationWorker initialized`;
  - release → ubus env 沒有變數、新 pid、恰好一次 worker initialized、125–200 s 內 `Rebooting system to apply new network settings`;
  - 新的那次開機:B committed、`dhcpconfigured=1`、IP 不在 `10.41.254.x`。
  - 再從 ssh 直接 `batman-slot commit` 一次(在另一個 trial),斷言 env 被清掉。
- **wsl.12 負對照的出口**(B10-m6):B 在 trial 內被 openmanetd 重開 → 回到 A,這時 B 已經連不到。`abort_to_a` 的「等 A」分支涵蓋這種情況:rollback 那步會失敗,接著等 A、disarm、印出 bad-slot、還原 p5、重開 A、`a_healthy`。副作用和 E1c 相同,外加一次非預期的重開。這條分支的結果記成「B-M4 已真機重現」,不算 FAIL。

**現場影響,修正 §13.8 的說法**(B10-m7 / A-m10):
- 暫停期間,openmanetd 的 IP 衝突偵測也是關的。hold 的 trial 沒有上限,所以這不只是「和今天前 125 s 相同」。操作文件要寫:hold 的 trial 不要放著過夜。
- 操作文件再補兩條 plain reboot 路徑:trial 期間啟用 BLOS(`blos.go:108`),和網頁的「重開」。
- 只有 trial 才會多一次 openmanetd restart:`start` 在 env 沒變時什麼都不做。
- **claimed + placeholder 的節點**(A-m6):p5 一直是 `dhcpconfigured=0`,所以每次 OTA 都會拿到新的亂數 IP,commit 後也會多一次重開。這種節點不在任何 mesh 裡,IP 換了沒有人依賴,用 mDNS 找。接受,並寫進操作文件。

#### 13.8.2 第 11 輪 → 定稿(A:APPROVE-WITH-CHANGES 2 MAJOR;B:APPROVE-WITH-CHANGES 1 MAJOR;A10-M1 / B10-M1 兩位都確認已關)
**§13.8 的元件 1、3 與 §13.8.1 的規則 1–4 以本節為準**(A11-m8:舊文保留作歷史,標作廢)。

- **A11-M1 / B11-M1(決定者逾時 kill `is-trial` 會在 Pi 3 留下 p7 掛載)→ 決定者不再呼叫 `is-trial`。**
  決定 = DT `tryboot` = 1 **而且** `$RUNDIR/slot-committed` 不存在 → 暫停;否則照 stock。依據:tryboot 是一次性的,只有 `batman-slot apply` 會武裝它(`batman-slot:14`、`:567`);開機內唯一改變狀態的是 commit,而 commit 一定寫旗標。原本第 3 步只在 rc 2 時多給一個「也是暫停」的答案,沒有增加資訊,只有風險。決定者從此不碰任何磁碟。
- **A11-M2(對帳的 detached `start` 沒有單例、沒有上限)→ 對帳集中在決定者的 `reconcile` 模式**,joinwatch 和 halow-status 都呼叫它,不自己重寫規則(B11-m1):
  - 單例:`$RUNDIR/addr-defer.start.pid`,前一支還活著就不再送;
  - 上限:每次開機最多 3 次(`$RUNDIR/addr-defer.starts`);超過 → log `HUNG`、rc 2,halow-status 顯示 WARN「openmanetd 沒有依指示重啟,請檢查 /var/lock」;
  - 送出的 `start` 用 `env -i PATH=…`(A11-m5:不繼承 `BATMAN_FAULT_INJECT` / `BATMAN_ALLOW_*`),`setsid`、stdio 導向 /dev/null;
  - 只修「不該暫停卻在暫停」;「該暫停卻沒暫停」只回報 WARN(A11-m2),因為那代表 hook 不在 image 裡,重啟沒有用。
- **權威狀態的讀法**(A11-m3):`ubus -t 5 call service list '{"name":"openmanetd"}'`,以 grep 找 `"ALFRED.DATATYPES.ADDRESSRESERVATION": "false"` 字串(不用 jsonfilter 的帶點路徑);ubus 失敗或逾時 → `env=unknown`,對帳不動作、只回報。
- **`rollback` 刪 `slot-committed`**(A11-m1),因為 rollback 之後這個槽不再是 committed。
- **決定者的 RUNDIR 不可用**(B11-m1):旗標不存在就當「未 commit」→ 暫停(fail-closed);對帳模式在 RUNDIR 不可用時不送 `start`、只回報。
- **procd 語意,列為依賴證據**(A11-m6,A 已追 c59f2d80):`start` 對執行中的服務 → `service_update` → env 變了才 `instance_restart`(原子、不吃 respawn 額度 `instance_exit:859-864`),沒變 → 不動(`instance_update:1564-1583`);mid-stop → 只設 `restart=true`,程序退出後重啟;未註冊 → 直接啟動;`procd.sh` 在 source 時就拿 per-service flock,決定者與 commit 的 `start` 全部序列化。`term_timeout` 5 s。
- **既有的面**(A11-M2 的後半):procd 的 per-service flock 放在 1777 的 `/var/lock`,本機任何非 root 程序都能以 O_RDONLY + flock 永久持有,讓所有 `/etc/init.d/<svc>` 卡住。這不是本改動引入的,寫進 §8 並列殘項(屬 #280 那一類)。
- **B11-m3**:`start` 會拉起操作員刻意 `stop` 的 openmanetd。接受:commit 本來就意味著節點回到正常服務;寫進操作文件。
- **B11-m5 / A11-m4(Pi 3 時序)**:決定者現在不掛 p7,所以 A11-m4 的「commit 當下與決定者互撞」不再存在;Pi 3 的整體時序仍無量測,殘項。
- **B11-m7**:降版到沒有 hook 的 image,trial 內會重現 B-M4,這就是 E1c v4 的負對照。

**介面**(`/usr/libexec/batman-addr-defer`,Batman feed,root 0755;唯一的實作):
| 呼叫 | 誰呼叫 | 輸出 |
|---|---|---|
| (無參數) | openmanetd init 的掛勾,每次 `start` | rc 0 = 暫停(init 設 env);rc 1 = stock |
| `status` | halow-status、測試 | `want=defer|stock env=present|absent|unknown openmanetd=up|down` |
| `reconcile` | joinwatch 每 tick | rc 0 沒事或已送 `start`;rc 2 HUNG;只回報的情況 rc 0 + log |

**生命週期補列**:
| 路徑 | 行為 | 證明 |
|---|---|---|
| Pi 3,trial 內 bat0 up 讓 openmanetd 重啟 | 決定者只讀 DT 與旗標,不掛 p7 | stub(決定者在 pi3 layout 下沒有任何 mount 呼叫:以 PATH 擋掉 `mount` 斷言) |
| flock 被卡住、`start` 送不出去 | 第 1–3 次各一個 detached 程序;第 4 次起 HUNG,halow-status WARN;不再堆程序 | stub(假的 `/etc/init.d/openmanetd` 永不結束) |
| 兩個 `start` 互相覆蓋 | procd.sh 的 flock 序列化;最後一個贏,而且決定者是冪等的 | 原始碼(A) |
| rollback 後同一次開機 | 旗標被刪;決定者回到「暫停」(仍是 tryboot 開機);openmanetd 不會因此重啟,因為沒有人送 `start` | stub |

**§13.8.2 已實作(2026-10-23)**:`feat/254-p1` d88250b(決定者 `/usr/libexec/batman-addr-defer`、`batman-slot commit/rollback`、joinwatch 對帳、halow-status、Makefile);firmware 51f8f256(board patch 0014,兩板,witness `file /etc/init.d/openmanetd batman-addr-defer`);H2 `tests/prov-p1/addr-defer.sh` 22/22(dash 與 busybox ash;stock init 負對照)。真機證據待 E1c v4(wsl.13)。
- 實作時的小決定:決定者 `have()` 把「openmanetd 已註冊但沒有 instance」算成 `env=absent`;`reconcile` 在 `want=defer` 但 `env=absent` 且 openmanetd 在跑時只記 WARN(hook 不在 image 裡,重啟無用)。

### 13.9 B-M4 真機重現(E1c v4 NEG=1,04,wsl.12,2026-10-23)
**✅ 重現成功**(腳本在找到 trial 後因 `find_b` 子 shell bug 當掉,**沒有跑到它自己的 NEG 斷言**;證據是事後從 p6 取的 forensic 紀錄,B12-m5):
- 04 的 `boot-reasons.log`:B 的那次開機 `boot_id=b4486f5b` → `prev=CLEAN: … uptime=170.45s trigger=reboot/halt command`;同一個 boot 在 `autocommit.log` 是 `HOLD-COMMIT boot=b4486f5b slot=B`。
- 也就是:一個 **HELD、沒有被 autocommit 動過的 trial,在 170 s 時被 plain `reboot` 退回 A**。這和 §13.6 的 openmanetd 時序(啟動約 40 s + 125 s ticker)吻合;trigger 文字是「reboot/halt command」而不是 openmanetd,原因如 §13.6 所述(`reboot_trigger()` 只看 logread 最後 50 行)。
- 主機端:08:07:04 時 B 還在 bootstrap 位址 `10.41.254.212`;08:07:51 已經不回應。
- ⚠️ 關機 dump `shutdown_20250719-112926_b4486f5b.log` 裡有沒有 openmanetd 的「Rebooting system」行,由 recover2 的輸出補上。

**兩個腳本 bug(都已修)**:
1. E1c v3/v4 的 `FIP=$(find_b …)` 在子 shell 裡執行,`FOUND_HOW` 傳不回父 shell,`set -u` 當掉。發生在找到 trial、種 dead-man **之前**,所以當時 trap 印的「dead-man stays ARMED」不是事實(只是 staged 在 p6,rc.local 沒種)。修法:`find_b` 直接設定父 shell 變數;trap 文字改成只陳述 `PLANTED` 旗標。
2. prov-base `lock_take` 在 `&` 之後立刻讀 `/proc/$!/cmdline`:子程序還沒 exec 到 holder 腳本時讀到的是父 shell 的 cmdline → `p5-restore` die。昨天的 snap 只是時序剛好。修法:拿掉多餘的 `setsid`(它若 fork,`$!` 就會是錯的 pid),比對改成最多 4 次、每秒重試。

**04 的狀態與還原**:當掉後 B 自己重開回 A(hold 旗標留在 p6,A committed 開機不受影響),p5 被 mkfs 過。還原 = recover-04.sh / recover2-04.sh(等 A → 收證據 → disarm → 刪 hold → p5-restore → `reboot committed` → `a_healthy` → brewrite B → compare → finish)。結果見 §13.9 下方的紀錄。
- **✅ 歸因確定(recover2,2026-10-23 08:12)**:關機 dump `shutdown_20250719-112926_b4486f5b.log` 內,openmanetd[6283] 在 11:27:12 記 `AddressReservationWorker initialized`,11:29:18(126 s 後)記 `Rebooting system to apply new network settings`;同一份 dump 顯示該 boot `dt_tryboot=00000001`。這就是 §13.6 的時序,不是推論了。
- **還原**:p5-restore(修過 lock_take 之後)→ `P5-RESTORED e1c10230803 sha=a4571a4f33ded757`;A 重開後 `ps=helper/legacy check_rc=0 helper=up`。B 重寫、compare、finish 見 recover3 的紀錄。
- **recover3(08:16–08:24)**:B 重寫 PASS(HELD 在 107 s);compare 有 6 個 DIFF,全部是 `etc/openmanetd/openmanetd.db{,-wal,-shm}`(openmanetd 的 SQLite 執行期重寫,F30 那一類)→ 登記到 `tests/prov-p1/overlay-allow.txt`(kind content,附這次的證據)。其餘 p5 / uci / identity / p6 state 全部相同。finish 完成,04 回到 S0。⚠️ recover3 沒有以 diffs=0 當 finish 的條件(救援腳本);正式的 tier B 單位要有。

### 13.10 wsl.13 上線(2026-10-23 08:27–08:58)與 addr-defer 的第一批真機痕跡
- ROLL13 PASS:02、04 都在 S0,`1.5.12-wsl.13+d88250b.fw9292567`;OTA tier A 34 PASS / 0 FAIL;committed 槽上 `batman-addr-defer status` = `want=stock env=absent openmanetd=up`,init 有 hook,決定者 root 0755。
- 兩台的 `ota-trace.log` 各有兩行 `SLOT ADDR-DEFER-RELEASE flag=written`(OTA trial 的 commit 與正規化的 commit):`batman-slot commit` 的解除路徑在真機跑過 4 次,沒有影響 commit 的結果(兩個 trial 都 committed)。
- ⚠️ 這批 trial 是從 p5 還原的 legacy 槽(`dhcpconfigured=1`),所以暫停沒有可見效果(worker 本來就不會觸發);trial 內 openmanetd 有沒有帶 env、commit 後有沒有被 restart,這批沒有量。正式證據 = E1c v4 正向(fresh unclaimed 槽)。

### 13.11 E1c v4 正向,第 1 次(04,wsl.13,2026-10-23 08:59–09:11)
**✅ 前半段(trial 內)成立,真機證據**:
- fresh unclaimed 的 HELD trial(`prov … state=unclaimed`、`mesh join required: 0 (prov=unclaimed`、`HELD`、沒有 AP 介面);
- `batman-addr-defer` 在 S99 記 `uncommitted tryboot trial — deferring …`;openmanetd pid 6282 的 `/proc/<pid>/environ` 有 `ALFRED.DATATYPES.ADDRESSRESERVATION=false`,`status` = `want=defer env=present openmanetd=up`,`alfred_started=1 worker_init=0`;
- `kill` 之後 procd respawn(pid 13027),env 仍在、worker 仍沒起來;
- openmanetd 跑到 **uptime 305 s**:`worker_init=0 rebooting=0`,B 的 boot_id 不變。對照 §13.9 沒有 hook 的 wsl.12:126 s 就 `Rebooting system`。

**❌ 後半段沒量到**:腳本在 305 s 的斷言用了 `*" worker_init=0 "*" rebooting=0 "*`,兩段字面搶同一個空格,永遠不成立 → 誤判 ABORT。`abort_to_a` 照設計走完:B 上 rollback + `reboot committed`(沒有 bad-slot)→ A → disarm(flag 0)→ p5-restore(sha 相符)→ A 重開 → `a_healthy`(legacy、`--check` 0、helper up、`want=stock env=absent`)→ dead-man 取消。
- 收尾:brewrite B 到 wsl.13 PASS;compare **diffs=0**(allow-list 推到節點上,openmanetd.db 的變動被 kind content 擋掉;其他全相同)→ finish。這是第一次在真機上拿到乾淨的 S0 compare。
- pattern 已修(單一段 `" worker_init=0 rebooting=0 "`);第 2 次正向跑在 09:2x 開始。
- 小錯:recover4 用 `sed 's/^RUN=…/'` 改 run id,但 `RUN=` 不在行首 → 對舊 run 做 finish 而失敗,且同一行的 rm 把節點上的 prov-base 副本刪掉。救援腳本的教訓:清理步驟要以 finish 成功為條件(§13.9 已註記)。

### 13.12 P-U14(2026-10-23):量產用 CM4,Pi 3 暫不支援
使用者決定:量產載板是 **CM4**(BCM2711,與 Pi 4 同 target `ekh-bcm2711`),不是 CM3。因此 **Pi 3 / `ekh-bcm2710` 暫時不支援**:
- 本文件所有標 ⚠️「Pi 3 未實測」的項目(§13.4 B-M4 的 Pi 3 時序、§13.8.2 的 p7 掛載、A11-m4 / B11-m2 / B11-m5、E1c 的 Pi 3 版)一律改為**殘項,不是阻擋**,寫進 #254 的 checklist。
- 生命週期矩陣的「Pi 3」欄保留,內容標「暫不支援(P-U14)」;board patch 0014 仍放 `patches/ekh-bcm2710`(同一棵樹出兩板,無害)。
- 出貨判定只認 bcm2711。CM4 載板與 Pi 4 的差異(eMMC / 無 WiFi 版 / EEPROM)待載板定案後另開 reality check。

### 13.13 E1c v4 正向,第 2 次(04,wsl.13,2026-10-23 09:23–09:43)— **DONE,B-M4 修法端到端成立**
| 階段 | 證據 |
|---|---|
| HELD trial(fresh unclaimed,B 10.41.254.143,boot 7cfc636a) | `mesh join required: 0 (prov=unclaimed`、`HELD`、`state=unclaimed`、沒有 AP;`batman-addr-defer: uncommitted tryboot trial — deferring` |
| openmanetd 在 trial 內 | pid 6269:`/proc/<pid>/environ` 有變數(`env=1`),`status=[want=defer env=present openmanetd=up]`,`alfred_started=1 worker_init=0` |
| procd respawn | kill 後 pid 13541:env 仍在、`worker_init=0` |
| 撐過 openmanetd 300 s | `openmanetd up 305s, no worker, no reservation reboot`;B 的 boot_id 不變(沒有 hook 的 wsl.12:126 s 就重開,§13.9) |
| release(B uptime 415 s) | `release: committed`;`slot_committed=y`;openmanetd 換 pid 13541 → 10915;**1 秒內** `env=0 status=[want=stock env=absent]`;`worker_init=1`(恰好一次) |
| 保留位址重開(committed 槽上) | recorder 存下 prev-boot:`12:12:53 AddressReservationWorker initialized` → `12:14:58 Static IP 10.41.80.47 and DHCP configured via address reservation` → `12:15:00 Rebooting system`;B 在 commit 後 146 s 消失;boot-reasons `uptime=562.29s trigger=reboot/halt command` |
| 找回 | mDNS 27 s:`10.41.80.47`,`slot=B trial_rc=1 dt_try=00000000`,`dhcpconfigured=1`,`status=[want=stock env=absent]`,`worker_init=1` |
| 穩定 | 300 s 沒有第二次重開 |
| 還原 | dead-man:`P5-RESTORED e1c10230923 sha=7feb94f1…`、`rollback rc=0`、`reboot committed` → A `ps=helper/legacy check_rc=0 helper=up want=stock env=absent`;02 不受影響;dead-man 取消 |

- 腳本訊息 bug(不影響判定):「openmanetd logged the reservation reboot 1 s after the commit」是假的 — `fq '… | grep -q …'` 的結束碼被 `| tr -d '\r'` 蓋掉,永遠成功。已改成 `grep -c` 取值比對。
- 這一跑同時是 §13.3 (a) 案三個事實的證明:fresh 槽自己 commit(這裡是 release 觸發)、重開成因(openmanetd,§13.6)、重開後找得到(mDNS,位址亂數 `10.41.80.47`)。
- 收尾(brewrite B、compare、finish)見 finish-04.log。
- **收尾(09:44–09:58)**:brewrite B PASS;第一次 compare 有 2 個 DIFF = `etc/board.json`(快照 sha 6dc275aaf914、live 6175191bb6ef)。結構 diff:只有 `wlan.phy1.info.bands.{2G,5G}` 的 HT/VHT 能力欄位(快照 HT40/VHT80,live 只有 NOHT);phy1 = **brcmfmac**(Pi 內建 WiFi),不是 morse。**翻轉測試**:plain `batman-slot reboot committed` 一次 → sha 回到 6dc275aaf914、modes 回到 `NOHT,HT20,HT40`。歸因:`/bin/board_detect` 每次 preinit 重寫 board.json(mtime = 開機時間),brcmfmac 能力探測有時序差;與 #254 無關,無功能影響(OpenWrt 只在缺 wireless config 時用它)。登 `overlay-allow.txt`(kind content)附兩次證據。之後 compare diffs=0 → finish。

### 13.14 第 12 輪(程式碼 + 整份設計)→ 處置
兩位都 APPROVE-WITH-CHANGES,各 1 MAJOR,**同一件事**:回歸保護沒進常規套(A12-M1 / B12-M1)。程式碼本身 0 MAJOR;兩位各自重跑 stub(dash + busybox)與 mutant,重讀 E1c v4 的 log 逐條對上 §13.8.2;節點只讀。

**A12-M1 / B12-M1(進常規套)已做**(H2):
- CI 新 job `prov-p1`:no-root 的 stub(決定者 dash + busybox、autocommit case、99zz、batman-slot release)、root 的 loop 裝置測試(config-save 三支、prov-base statecmp)、`go vet` + `go test`。
- daily-validation:`prov-p1-stubs`(無硬體,從本 checkout 的產品檔跑;root 時加 loop 裝置那組)、tier A `addr-defer-254`(`scripts/node/addr-defer-254.sh`:決定者與 hook **同時**在 image、DT tryboot 節點存在(CM4 reality check,A12-m9)、committed 槽 `want=stock env=absent openmanetd=up` **且** procd env 沒有變數、沒有 HUNG、uptime ≥ 300 s 時 `dhcpconfigured=1`)。02 / 04 各 8/8 PASS。
- `tests/prov-p1/batman-slot-addr-defer.sh`:從真檔抽出 `addr_defer_release` / `cmd_rollback` 的旗標行,stub 下驗旗標、唯一一次 detached start、rc 不受影響、run dir 不可用的分支、`env -i` 不洩漏、沒有決定者時 no-op;負對照 6e3a8c1 FAIL(函式不存在)。

**產品 MINOR,已修**(`feat/254-p1`,下一個 rc):
- B12-m1 / B12-m2:reconcile 的 pid 檔改為 `<pid> <uptime>`;start 還活著但超過 60 s → HUNG rc 2;死掉或過期的 pid 釋放單例。
- A12-m6:reconcile 不再用 `setsid`(joinwatch 沒有 PTY;busybox setsid 會 fork 讓 `$!` 錯);commit 那條保留 `setsid`(B10-M1 的 PTY hangup)。
- A12-m7:HUNG 與 trial-WARN 每次開機只記一次(`addr-defer.said.*` 標記)。
- B12-m7:決定者的決策只經 `logger` 記一次,不再 echo 到 stderr(procd 會轉送 init 的 stderr → 重複)。
- A12-m4 / B12-m3:trial 但沒暫停的文案補上「或這次開機 commit 後又 rollback」。
- A12-m5:stub 補 `ubus` 必帶 `-t`、`env -i` 不洩漏的案例(兩個 mutant 現在會被抓到)。
- A12-m10:witness 路徑去掉前導 `/`,與其他 patch 一致(兩板)。

**文件,已修**:A12-m1 / B12-m6 §3 新增四個資源列;A12-m2 §13.8 作廢段逐段標記、§13.8.1 的 `is-trial` 測項標作廢;B12-m5 §13.9 註明 forensic;A12-m8 §13.8.2 介面表:halow-status 只呼叫 `status`(程式碼為準);A12-m3 / B12-m6 §8 補 `/var/lock` 既有面(見下)。

**§8 補:既有的面(不是本改動引入)**:procd 的 per-service flock 放在 1777 的 `/var/lock`,本機任何非 root 程序可以 O_RDONLY + flock 永久持有,讓該服務的 `/etc/init.d/<svc>` 全部卡住。對本改動的可見後果:committed 槽永遠不保留位址(halow-status WARN、tier A FAIL、reconcile HUNG 一次)。屬 #280 那一類,列殘項。

**沒做 / 殘項**:B12-m4 從 PTY(ssh 互動 / 網頁終端機)下 `batman-slot commit` 的真機斷言 — 殘項(目前只有第 11 輪的主機 PTY 實驗);reconcile 路徑在節點上從未被觸發(只有 stub);Pi 3(P-U14)。

### 13.15 最終 rc wsl.14(b938e55 / fw271bea4)的真機驗證(2026-10-23)
- **ROLL14 PASS**(10:0x–10:56):02、04 OTA tier A 全 PASS,正規化回 A,B 重寫;committed 槽上 `want=stock env=absent openmanetd=up`。
- **E1c v4 正向 #3,DONE**(10:56–11:15,04):trial 內 `env=1 want=defer env=present`、respawn 後仍暫停、openmanetd 跑到 304 s 沒重開;release(B uptime 400 s)→ committed、openmanetd 換 pid(13131 → 10218)、1 s 內 `env=absent`、`worker_init=1`;commit 後 145 s B 消失(保留位址重開),mDNS 28 s 找回 `10.41.213.30`、committed、`dhcpconfigured=1`;穩定 300 s;dead-man 還原 → A 健康、02 不受影響。收尾:B 重寫 PASS,compare **diffs=0**,finish。
- **WSL root 半邊**:ab-card invariants bcm2711 / bcm2710 rc=0;prov-p1 loop 測試對 P1 產品(b938e55)全 PASS(identity-freeze 8/8、frozen-nomount、provget-rc10、statecmp 14/14);**對 main 舊產品(H2 checkout 自己的 feed)正確 FAIL**(2/8、FAIL、FAIL)= 負對照 → 寫成 KNOWN(#254)直到 P1 merge,CI 的 prov-p1 job 在 harness PR 上刻意紅(P-U9)。
- Go:`go vet` + `go test ./...` 9/9 ok(b938e55)。
- node 半邊全套(dvfull14,從 H2 e23ad77,破壞性含 tier B)11:2x 啟動,結果見 §13.16。

### 13.16 全套第 1 / 2 次(wsl.14,H2 e23ad77)— 兩個 harness bug,依規則停掉
- 第 1 次(11:24):preflight 擋下 — 我的 runner 少了 `FI_PAYLOAD`(節點上要有正在跑的版本的 payload)與 `DV_T263_KO`(#263 FI 模組要對 wsl.14 編)。補齊:`FI_PAYLOAD=/opt/batdata/ota-wsl14.tar.gz`,`scripts/build-debug-mm6108-fi.sh ekh-bcm2711` 產出 `out/…wsl.14…/debug/mm6108_sdio-fi263.ko`。
- 第 2 次(11:32):preflight PASS;`tmp-trust-static` FAIL(我新加的腳本有 11 行 #280 不信任:run dir 字面、`$$` 命名、主機端 `/tmp`)、`prov-p1-stubs` FAIL(`chk_prov_p1_stubs` 定義在 `suite` 呼叫之後)。兩個都是 harness 錯 → 依「同一步 harness bug 兩次停」在 11:5x 停掉(INT → TERM,ps 確認 0 殘留;當時在 ble-rpa-254)。
- 修正 = H2 881ed5f:函式移到 `self_test()` 之後;run dir 經 `rundir.sh` 解析(`PROV_BASE_TEST_ROOT` 也前綴 library 路徑,供 CI/WSL 測試);scratch 用 `mktemp -d` 在 `/tmp/run/batman-dv` 下、裡面用固定名;prov-claim 主機端用自己的 `mktemp -d`;allowlist 兩條(附理由);`rundir-paths.txt` 加 `batman-prov.health`、`slot-committed`、`addr-defer.start.pid`、`addr-defer.starts`、`addr-defer.said.*`。驗證:clone 與 worktree 都 check-tmp-trust 0、test-tmp-trust 26/26、statecmp 15/15、stubs / cfgsave 全 PASS、修過的 addr-defer-254.sh 在 02 8/8。
- 中斷留下:兩台 `/tmp/run/batman-dv/{ble-state,bt}`(BLE suite 的殘留)→ 第 3 次前清掉(見 §13.17)。

### 13.17 中斷 BLE suite 的清理 + 全套第 3 次
- `ble_state` 報 FAIL leftover:兩台各有 run `dv1792726405p1397` 的 BLE lease(約 34 分後到期)與 live deadman;04 另有 btmon 程序與 1 個廣播 instance。用 harness 自己的入口 `ble_recover <node> periph|central`(`scripts/lib/ble-254.sh:67-68`,P6 指向它):兩台 `RECOVER kill deadman group …` → GC run dirs → `RECOVERED` → `STATE clean`;沒有觸發 IRK 重開。
- 全套第 3 次(H2 881ed5f,wsl.14)12:0x 啟動;結果見 §13.18。

### 13.18 全套第 3 次(wsl.14,H2 881ed5f,11:57–17:30)— 結果
**99 PASS / 2 FAIL / 21 SKIP / 6 N/A**(report:`rc/dvfull14/20261023-115733/report.md`)。
- FAIL KNOWN(#254):`prov-p1-stubs` — H2 checkout 的產品是 pre-P1,預期;P1 merge 後轉綠。
- FAIL NEW:`ble-pair-sc-only-254`(401 s)— 第 2 段「翻轉」:第一次連上但配對 `status 0x04 Connect Failed`,重試 `invalid:no-target`(02 掃不到 04)→ suite 判無效。H1 時代的 BLE tier B,P1/H2 沒碰;歸因見 §13.19(單獨重跑)。
- SKIP 21:#264 系列 17 個(overlay 已拆,由 #289 取代)、`hold-261` ×2(Pi 3,P-U14)、`ab-card-invariants`(WSL root 半邊已 PASS 兩板)、`p5-follows-config-202b`。
- N/A 6:`p7-209`(Pi 4 無 p7)、#264 的 4 個 gateway-only、`soak-cot-264`。
- 與 #254 直接相關全 PASS:tier A `addr-defer-254`、`prov-tools-254`、`ble-privacy-254`、`ble-rpa-254`、`ble-privacy-reboot-254`、`tmp-trust-static`(含新腳本)、全部 fault-injection、OTA/A/B(`ab-selftest --destructive`)、#202 四條、#274、#289、soak。

### 13.19 ble-pair-sc-only-254 的歸因(❓)與 H2 收尾
- 單獨重跑(17:33–17:41):第 2 段 LEAK 正確;第 3 段 `0x08 Timeout` → `0x04 Connect Failed` → invalid。兩次失敗在不同段落、都是連線層;連上時政策判定全對。P1 的 150 個改動檔無 BLE 相關、firmware 無 bluez patch 變動 → **❓ 未歸因,不是 #254 P1**;開 winson3QQ/Batman#305 記錄(含 btmon 追查、與 Pi 4 BT UART 卡死合併看)。
- harness:`validation-known-failures.txt` 加 `ble-pair-sc-only-254` 一條,只對應連線層的 `VERDICT invalid`(#305);policy 判錯仍 NEW。
- 全套最終判讀:**99 PASS / 21 SKIP / 6 N/A / 2 FAIL(皆 KNOWN:prov-p1-stubs #254、ble-pair-sc-only-254 #305)**;#254 相關全 PASS。
