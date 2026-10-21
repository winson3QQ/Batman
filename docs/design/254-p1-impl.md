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
| F13 | WSL 有 go1.22,**沒有 qemu-aarch64**;CI 沒有 Go、沒有 image;**repo 是 PUBLIC**(GitHub arm64 runner 可用);release v1.5.11 有 bcm2711 / bcm2710 的 `…-ab-payload.tar.gz`(內含 `root.squashfs`) | 讀檔、`gh` |
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

**鏈 1:firstboot → gate → (2)**(類別 R)
1. snap。joinwatch 一直停到第 4 步重開。
2. 斷言沒有寫 p5 的程序在跑。
3. p5 `mkfs.ext4` → `ro` 斷言沒有 `.seeded`。
4. `BATMAN_ALLOW_UNSEEDED=1 BATMAN_ALLOW_STALE_P5=1 batman-slot apply <rc>`。
   - 要 `ALLOW_STALE_P5` 的原因:P1 的 `--check` 在 rc 7 之前就比 prov;overlay 有 legacy prov、p5 剛被 mkfs → rc 5。
   - 這是直接呼叫,所以沒有 `ota-armed.mesh`,等於 L42 的路徑;不 hold。
   - 接著以 `ro` 再斷言仍未 seed → 受控重開(§4.5.0)→ 落點斷言。
5. **B 的 trial**,經 eth 做硬性斷言(連不到 = FAIL):
   - `iw dev` 沒有 AP 介面;
   - mesh radio 被 keyguard 關;
   - helper log `rc=7`;
   - `prov.meta` = unclaimed;
   - `identity/` 0700,p5 的 `identity/prov/` 有 7 檔且 sha 正確;
   - p5 沒有 `.seeded`。
6. **gate(L44)**:同一個 trial 裡,記下時間 t0 → `BATMAN_ALLOW_TRIAL_APPLY=1 batman-slot precheck-node`。
   - **正向證據**:`$RUNDIR/p5-check.rc` 的 mtime > t0,內容 = `skip:unseeded`;rc ≠ 0,最後一行 = 「mis-aimed tryboot」(B 還沒 commit,F6)。
   - **負對照**:tmpfs 上 wsl.9 的 `batman-slot`,同樣方式跑 → rc 1、「not seeded」、`p5-check.rc` 沒有更新。
   - 注意:`precheck-node` 會寫 `p5-check.rc` 與鎖目錄(F6),不是嚴格唯讀。
7. **(2) claimed + placeholder**:
   1. 等 autocommit 依「unclaimed 不需鄰居」commit B(斷言 log `COMMITTED`),這本身就是上層 §6.4 的斷言。
   2. 依 E1 的結果,處理 openmanetd 重開 / 換 IP,以 MAC 重新找到 04。
   3. **認領前的守門**(BLOCKER 修正):
      - root 把 lab 公鑰寫進 B 的 `/etc/dropbear/authorized_keys`(檔案 root 0600、目錄 0700,符合 dropbear 的要求);
      - 以 `-o PreferredAuthentications=publickey -o IdentitiesOnly=yes` **開一條新連線**,驗證能登入;
      - 驗證失敗 → 中止(B 還沒上鎖,`none` 仍可用),走 restore。
   4. provclient 認領 → claimed;認領的 `--save` 會 seed p5,包含 lab key 與 B 的個人化。
   5. 再開一條新的 publickey 連線驗證(L47)。
   6. 寫 hold = V → `sysupgrade -n` rc 進 A(§4.5.0;閘依 `.seeded` 放行,因為認領的 `--save` 已經 seed 了 p5)→ 進入 A 的 trial(A 從 B 的 p5 建,位址可能是 `10.41.254.x`,以 MAC 找)→ 斷言 hold 生效,autocommit 判「claimed + placeholder → 不需鄰居」、log `HELD`。
   7. `batman-autocommit release` → A committed。
8. restore(類別 R、同槽):p5 寫回 → `firstboot` → A 從原本的 p5 重建 → F16 → B 寫回 V。

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
   - **E6**(B-m3):Git Bash ↔ `wsl.exe` 的雙向 pipe(coproc 或 FIFO)跑 20 次 `SIGN` / `SIG` 往返,每次 ≤ 20 s,並且處理 ``(A-m7)。
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
| A-m7 / B-m5 不一致 | §5 開頭、§7.1、§4.2 `cryptpw`、`` |
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
