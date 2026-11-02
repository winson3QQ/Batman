# 審查 B 第 4 輪 — `254-p1-impl.md` v4(PR-P1 + PR-H2)

審查者 B(獨立)。審查範圍是整份 v4(588 行),對照的依據:

- 上層 `254-stage1-impl.md` v19;
- main f1a1122 的原始碼;
- 02 / 04 與 WSL 的唯讀實查。

沒有寫入節點、沒有重開、沒有重啟服務,也沒有印出任何秘密。

**判定:REJECT**:0 BLOCKER / 4 MAJOR / 6 MINOR。

v3 的 BLOCKER 已經解掉:鏈 1 在認領前先寫入 lab key,並以新連線驗證能登入。另外五項在產品端照上層修正:

- 閘只放行 unclaimed;
- identity 的比對排在 gen 比對之前;
- `--check` 的比對移到 rc 7 之前;
- 遇到不一致時 `--persist-now` 拒絕;
- `settings.set` 在 P1 沒有可寫的 key。

`P-U8`(B 寫回 V)也解掉了「每日驗證會 FAIL」和「沒有 rollback 槽」的問題。

剩下的問題:

- **overlay 整份清單比對沒有基線**:04 上好幾個檔在每次開機和執行中都會被改寫,照現在的寫法 restore 會一直 FAIL。
- **`dv-sbx` 在 04 上的隔離做不到**:沙箱保留了 `CAP_SYS_ADMIN` / `CAP_MKNOD`,`/proc/sysrq-trigger` 又是全域的,隔離無法成立。
- **02 會常態性 OTA 進 slot B**:上層 §11 / Q8 的前提(02 的 p3 要先補 `core_freq_min`)沒有處理。
- **02 有兩條還原路徑可能讓它失聯**:套件開頭的正規化用 `ALLOW_STALE_P5`,而且同槽重建(`firstboot`)沒有排除 02。

---

## 0. 本輪驗證的事實

| # | 事實 | 證據 |
|---|---|---|
| X1 | 04 開機在 1752758412(epoch,節點時鐘)。overlay 檔的 mtime:`board.json` 是開機後 +12 s;`config/network`、`config/mesh11sd` 是 +25 s;`config/firewall` 是 **+3851 s**;`config/system` 是 **+6340 s**(都在執行期間被改寫);另外有 `openmanetd.db`(+ `-wal` / `-shm`)、`urandom.seed`、`root/.ssh/known_hosts`。`etc root usr www` 底下共 52 個檔 | 04 `date -r` / `find /overlay/upper` |
| X2 | **WSL 是 NAT**:`eth0 172.30.211.0/20`,default via 172.30.208.1。`.wslconfig` 的註解寫 mirrored 模式 2026-09-24 試過,「WSL still could not route to that NIC」,已退回。可是 WSL 現在 ssh 得到 04(rc=0) | WSL `ip addr`、`~/.wslconfig`、WSL `ssh … true` |
| X3 | **WSL 的 yello 沒有 `~/.ssh`**,沒有任何 key。能登進 04 只是因為 `none`(空密碼) | WSL `ls ~/.ssh` |
| X4 | freshness gate 遇到 rc 5 一律 die,除非設了 `ALLOW_STALE_P5`。註解說明這個 gate 存在的原因:「on a mesh-only node an old mesh key is unrecoverable」 | `batman-slot:441-447,483-489` |
| X5 | `node_checks` 的 #202 interlock 與 freshness gate 都在 `apply` 寫入之前執行 | `batman-slot:516-560,524-535` |
| X6 | 上層 §11:「**02 p3 的 `core_freq_min=500` 尚未補**(下一次 02 OTA 落到 slot B 之前必做)」;Q8:這次授權**不改 p3** | 上層 §11、§12 Q8 |
| X7 | hold-commit 不在 `held()` 裡,deadline watchdog 會寫 `bad-slot`。`bad-slot` 只在 commit 時刪除 | `batman-autocommit:94-103,243,502` |

---

## MAJOR

### M1. overlay「整份清單 == 快照」沒有基線,照寫 restore 會一直 FAIL,不然就是 allow 清單變成盲區
- **情境**:§4.5.2 第 4 步比對 `/overlay/upper/{etc,root,usr,www}` 每個檔的 sha,「多、少、不同 → FAIL」,只靠 `overlay-allow.txt` 排除例外。可是 04 上:
  - 每次開機都會改寫 `board.json`、`config/network`、`config/mesh11sd`;
  - 執行期間也會改寫 `config/firewall`、`config/system`;
  - `urandom.seed`、`openmanetd.db*`、`root/.ssh/known_hosts` 會持續變動(X1)。
  
  F 類(逐檔還原)只寫回清單上的那些檔,之後的重開又會把其他檔改掉。R 類(`firstboot` 重建)更是只會長出 uci-defaults 產生的那一份:執行期才出現的檔(例如 `known_hosts`、被服務改過的 firewall / system)不是不見,就是內容不同。這些內容差異到底是「每次重寫但內容相同」,還是「內容真的會變」,沒有人量過。
- **後果**:不是每個 tier B 都 FAIL、dirty 標記一直留著,就是有人把 allow 清單越寫越大,最後真的漂移也抓不到。
- **修法**:
  - §9 加 **E4**:在 04 連續 snap 兩次,中間只做 (a) 一次普通的 `reboot committed`、(b) 一次同槽 `firstboot` 重建(不做任何測項),記下差異;以這份證據產生 allow 清單,每一行附證據。
  - `config/*` 改比語意(`uci export` 排序之後),不比 sha。
  - R 類的還原改成「`firstboot` → 96 重建 → 停服務 → 把快照的 overlay(`etc root usr www` 的完整 tar)寫回 → 重開」,不要只寫回 F16 項目。這樣 R 類和 F 類的比對結果才可預期。

### M2. `dv-sbx` 在 04 上照 §4.10 做不到隔離
- **情境**:96 與 config-save 要掛 ext4,所以沙箱裡的程序保有 root 的 `CAP_SYS_ADMIN`,§4.10 也沒有丟掉 `CAP_MKNOD`。這兩個能力在沒有 user namespace、沒有 device cgroup 的情況下,足以:
  - `mknod 179:5`(真的 p5),或直接 `mount -t devtmpfs` 拿到全部真實裝置 → §4.10 的負測試「以真的 p5 的 major:minor 去 open → 失敗」**沒有任何機制能讓它通過**;
  - `echo b > /proc/sysrq-trigger`:新 pid ns 的 proc 底下,`sysrq-trigger` 仍是全域的 → 真機立刻重開,繞過「丟 `CAP_SYS_BOOT`」;
  - 寫 `/proc/sys/*`(全域 sysctl)、掛起 p6 等。
  
  沙箱是用來跑「被 mutant 改過的」96 / config-save / helper 的(prov_test 開關),「我們自己的錯」正是預期中會發生的。
- **修法(建議)**:**不在節點上跑沙箱**。「測出貨產物」改成在 CI 用出貨 payload 的 `root.squashfs`(sha 釘死)當底,這已經是 §2.2 CI 那一種底的做法,只是把釘住的版本換成受測版本。04 上不需要再跑。
  - 如果一定要在節點上跑:加 cgroup v2 device controller(BPF,只允許沙箱的 loop、null、zero、urandom),做完 mknod 之後丟掉 `CAP_MKNOD`,`/proc/sysrq-trigger` 與 `/proc/sys` 以唯讀或 `/dev/null` 蓋掉,並以 seccomp 拒絕 `devtmpfs` 與其他區塊裝置的 mount。負測試要包含 `devtmpfs`、`mknod 179:5`、`sysrq`、`sysctl` 四項,而且要先在 E2 實證全部擋得住。

### M3. 02 會常態性 OTA 進 slot B,違反上層 §11 / Q8 的前提
- **情境**:P-U8 之後,每次有 02 參與的測項,restore 都會做一次「B 寫回 V」= 02 的 OTA 落到 **slot B**(§4.5.4)。§5.5 (7) 也讓 02 OTA rc 進 B。上層 §11 明寫「02 p3 的 `core_freq_min=500` 尚未補(下一次 02 OTA 落到 slot B 之前必做)」;Q8 只授權改 p1,不改 p3(X6)。設計完全沒提。
- **後果**:02 在 B 上沒有固定的 core 頻率,mini-UART 的藍牙不可靠,而 F17 的 UART 卡死已經存在。在 P-U5 之下只會記 WARN,不會失聯;但這是上層寫明、需要使用者授權的前提。
- **修法**:§1.1 加一項待使用者決定:(a) 先補 02 的 p3(寫明副作用與還原:掛 p3、加一行、讀回),或 (b) 02 的 B 不寫回、改用其他做法維持 `chk_slotintegrity`(例如 02 不參與 prov tier B,(7) 改成只動 04)。在使用者決定之前,02 不做任何落到 B 的 OTA。

### M4. 02 有兩條還原路徑可能讓它失聯:正規化用 `ALLOW_STALE_P5`,同槽重建沒有排除 02
1. **套件開頭的正規化**(§4.5):「committed ≠ A 或版本 ≠ V(例如 `reflash-survives-config-202` 之後)→ 依 §4.5.3 的 A 重建」。跨槽重建第 2 步是 `BATMAN_ALLOW_STALE_P5=1 batman-slot apply`。但正規化時**沒有快照、也沒有寫回 p5**,這時的 p5 是當下的狀態。freshness gate 存在,正是為了防止「p5 落後於執行中的設定,fresh 槽拿到舊的 mesh key → 只有 mesh 的節點救不回來」(X4)。如果 `reflash-202` 的 `MESH_NODE` 是 02,正規化就會在 02 上關掉這道閘。
2. **同槽重建**(`firstboot -y`):§4.5.2 第 2 步的觸發條件(標記不見、host key / identity ≠ 快照)不分節點,§4.5.3 只排除了 02 的「跨槽」。02 一旦 `firstboot`,96 只要遇到任何提早出口(`:89` 掛載失敗、`:93` 等),02 就會停在 image 預設值 → mesh key 是 placeholder → keyguard 關掉 radio → 02 沒有乙太網 → 失聯。
- **修法**:
  - 正規化**一律不用** `ALLOW_STALE_P5`:先斷言 `--check` = fresh(必要時在 JOINED 時先 `--save`),否則 FAIL,交給人處理。
  - 02 上**禁止任何 A 重建**(同槽與跨槽):02 只做 F 類;一旦判到需要重建 → FAIL,印出狀態,交給人。P9 也斷言這一點。
  - 04 的同槽重建在 `firstboot` 前,先以 `ro` 驗證 p5 清單 == 快照、`.seeded` 存在。

---

## MINOR

- **m1**:主機端「在 WSL 跑」的前提要補兩件事:
  - (a) WSL 沒有 key(X3),今天 P9 的「每個 runner 都能 publickey 登入」對 WSL 會 FAIL,鏈 1 的守門也會中止。這是安全的,但要寫明 WSL key 怎麼安裝(等於 lab 私鑰多一個存放位置,要列進 §8)。
  - (b) WSL 是 NAT(X2),**看不到 04 的 L2**,鏈 0 / 鏈 1 / E1 的「以 eth MAC 找到 04」(ARP、ping 掃描)必須在 Windows 端做(例如經 interop 呼叫 `arp -a`)。
- **m2**:鏈 1 第 4 步會被 P1 自己的 `--check` 擋下。mkfs 之後,A 的 overlay 有 legacy 的 `prov.meta`,p5 沒有 → 依 §4.8,比對移到 rc 7 之前 → rc 5「p5 stale: prov」→ `apply` 的 freshness gate die(X4、X5)。只設 `ALLOW_UNSEEDED` 不夠,這一次呼叫要同時設 `ALLOW_STALE_P5`,並在 §5.4 註明理由。也正好可以把這一步當成 §4.8 的正向證據(斷言先看到 rc 5)。
- **m3**:R 類(§4.5.3)沒有還原 p6 state 這一步(只有 F 類有)。`bad-slot`、hold 旗標、`ota-armed.mesh`、`mesh-*` 在鏈 1、legacy-upgrade、overlay-wipe 之後不會回到快照,可是 S0 斷言「沒有 `bad-slot`」。不 hold 的 `-wbox` revert(§5.5 (1)(4)(7))一定會寫 `bad-slot`(X7)。§4.5.3 兩種重建都補上 p6 寫回。
- **m4**:「B 寫回 V」要在 600 s 的期限內走完 HELD + `back_to_a`。04 有 OTS:payload converge 或 first-load 期間 watchdog 會延後,HELD 也可能來得晚。要寫明:到 deadline 前 60 s 還沒 HELD → 照樣 `back_to_a`,記錄並 FAIL,不要等到 watchdog 去寫 `bad-slot`。
- **m5**:provclient 的「root 啟動後降權」要補兩點:
  - 斷言降權後 `/proc/self/status` 的 dumpable = 0。換 euid 會清掉 dumpable,所以同 uid 的 provd(P2)無法 ptrace 去讀記憶體裡的 `claim.secret` 與 fleet key,這要實測。
  - 寫明降權前不讀 stdin(stdin 是來自 WSL 的 SIG 行),也不連 helper。
  
  Go 1.16 以後 `syscall.Setuid` 會套用到所有執行緒;要在 `go.mod` 釘住 Go 版本 ≥ 1.16 並附上證據。
- **m6**:`-wbox-chan` 的「等 chanfix 完成的 log」:要寫明是哪一行 log(`99-batman-chanfix` 自己的 logger tag),以及找不到時怎麼處理(FAIL「mutant 無效」,不能一直等)。

---

## v3 發現的狀態

| v3 | 狀態 |
|---|---|
| B1 鏈 1 鎖死 04 | ✅ 認領前寫 key + 新的 publickey 連線,失敗就中止;認領後再驗。WSL 沒有 key → 會中止(m1) |
| N1 作廢 B | ✅ P-U8 B 寫回 V、全套順序、P9 斷言兩槽 `.protected`。⚠️ 02 落到 B 的新問題(M3) |
| N2 清單不全 | ✅ 補上 host key / openmanetd / mesh11sd / config.yml / F16,並有同槽、跨槽重建。⚠️ 整份清單比對沒有基線(M1);R 類沒有還原 p6(m3) |
| N3 閘放寬 | ✅ 只放行 unclaimed;`prov-unit-gate` 有對應列 |
| N4 沙箱隔離 | ❌ 寫了契約,但在節點上做不到(M2) |
| N5 identity 漏洞 | ✅ 順序、rc 7 之前比對、`--persist-now` 拒絕、恢復方式寫明。副作用:鏈 1 第 4 步要加 `ALLOW_STALE_P5`(m2) |
| m1 手動 commit / `bad-slot` | ✅ 改用 `release`,deadline 前回 A |
| m2 `claim.secret` / fd 3 | ✅ root 讀完再降權(m5 補強) |
| m3 `sysupgrade -b` | ✅ 改用 `-l` |
| m4 chanfix | ✅(m6 補強) |
| m5 gate 依 `.seeded` | ✅ |
| m6 Tailscale | ✅ 先停 tailscaled |
| m7 動詞表 | ✅ 不存在動詞列、`settings` 範圍、§10 第 10、11 點 |
| m8 §5.7 | ✅ 補齊(我逐列對過 L1–L65,沒有缺漏) |
| m9 payload 來源 | ✅ 推上去並以 sha 驗證,不用 `ota.tar.gz` |
| m10 `precheck-node` 不唯讀 | ✅ |

## 其他確認成立(✅)
- 鏈 1 第 6 步的 gate 判讀合理:B 的 trial 中,P1 的閘先放行 unclaimed → freshness 記 `skip:unseeded`(B 自己的 overlay prov 與 p5 一致)→ 最後一行 mis-aimed tryboot。wsl.9 版本則在 interlock 就 die「not seeded」。兩邊都有正向證據。
- 鏈 1 第 7 步:有了 key 守門,認領後走「A 的 trial → `release`」;openmanetd 若在 trial 中重開,會回到 committed 的 B(有 key),再由跨槽重建處理。04 不會被鎖死(E1 要實證時機)。
- `firstboot` / 96 的同槽重建,在 04 上是可行的還原路徑(上層 F22);restore 先寫回 p5,所以 96 用的是原本的 p5。
- 白箱不會外洩:`-wbox` 只寫進 B,之後 B 被寫回 V;P9 斷言兩槽 `.protected` 都沒有 `-wbox`;test helper 放在 tmpfs 並以 bind mount 蓋上;killpoint 在獨立的 0700 目錄;build gate 檢查 buildinfo 與標記字串。
- 秘密:`sysupgrade -l` 不產生 archive。擁有者私鑰只在 WSL。fd 3 是同一個 root 程序開的 pipe。

## 判定
**REJECT**(0 BLOCKER / 4 MAJOR / 6 MINOR)。產品端與上層的對應,這一版大致都對了。剩下的問題集中在 harness 的還原與執行環境:

- M1:overlay 整份清單比對要先有基線證據;
- M2:建議不在節點上跑沙箱;
- M3:02 落到 B 要先由使用者決定;
- M4:02 上不得覆寫 freshness gate,也不得重建 A。

修完請整份重審。
