# h23 設計審查 v9(§17 v9 + §18)— 審查者 A

- 對象:`docs/design/254-h23-harness.md` @ f6de6c2(harness/254-h23),全文 §0–§18;§16–§18 與前文衝突時以後者為準。
- 原始碼:rc 樹 `/home/yello/Batman-rc` @ d0643d5(P1b 1f82e36 + harness b6d562a)。逐行讀了 `batman-autocommit`(全檔)、`batman-slot`(`allowed`、`cmd_commit`、`rollback_lock_gate`、`cmd_rollback`)、`platform-ab.sh`(檔頭、`platform_check_image`、`_ab_live_sysupgrade`、`_ab_arm_mesh`)、`98-batman-sysupgrade`、`init.d/batman-autocommit`、`batman-provhelper.init`、`main.go`(`SetLastKnown`、`--apply-state` 寫 prov-state、daemon 啟動序)、`boot.go` `writeProvState`、`sock.go` `PrepareDir`、`health.go`、`chain1-254.sh` 8.7、`pty-commit-254.sh:28`、`halow-status`、`joinwatch`;也看了 `~/out` 的 payload 清單。
- 限制:沒有 ssh 上節點,沒有 commit,沒有動任何 worktree,也沒碰 `/home/yello/firmware-2710`。沙箱只做了一個 busybox `setsid` 探針,結果不完整,只當 ⚠️。

## 結論

**APPROVE-WITH-CHANGES**:0 BLOCKER / 3 MAJOR / 16 MINOR。

- §17 v9 的方向是對的。四個 L 都改成「判定半邊用 autocommit dry-run 加 mutant;寫入半邊用既有的真 trial 斷言或 CI」,v8 的 BLOCKER(bind 錯檔)與三個 MAJOR(watchdog 副作用、member 前置、第 3 欄)都已解決。四個 mutant 也都只拿掉指名的那一條檢查。
- 三個 MAJOR 是:
  - **M1**:§18.1 沒寫 wbox 判斷在 hold 前還是後。順序寫錯,所有 wbox trial 的「mutant 無效 → `HELD`」判定都會失效,而且會出現假 PASS。
  - **M2**:§18.1 只擋 `commit`。`batman-slot rollback` 一樣能把殘留在另一槽的 wbox image 變成 committed,所以「節點自己拒絕 commit wbox」的說法不完整。
  - **M3**:L11 的負對照(「health 15 s 內不更新」)與原始碼不符。helper 在 `PrepareDir` 失敗之前就已經起了 health goroutine,失敗後 procd 每 5 s respawn 一次,所以結果不確定。
- 這三點都是局部修正。修完後只需重審 §18.1 與 §17.4 的 L11 段,不用重審整份。§18.1 是產品改動,M1、M2 修好之前不要實作。

---

## 0. 先核對前幾輪的發現

### v8 A(`h23-review-v8-A.md`)
| 項 | 狀態 | 依據 |
|---|---|---|
| B1 L51 bind 錯檔 | ✅ 解決 | §17.2 不再 bind `platform-ab.sh`,L51 的寫入半邊改成 CI 加 (7) 的斷言 |
| M1 dry-run watchdog 刪 arm 檔、佔用真名 claim | ✅ 解決,有殘餘(見 m1) | §17.3:`setsid`、殺整個 group、期限 +600、快照與還原;產品殘項記在 §17.5 |
| M2 member 前置 | ✅ 解決 | 判定半邊改用白箱 prov-state,不再需要真的 member;(6) 有自己的前置 |
| M3 第 3 欄 | ✅ 解決 | §17.3 只改第 1、2、4、6 欄;§17.5 deadman 寫回快照、P9 加檢查 |
| m1 L38 時序 | ✅ | 先看到 `sleep 1` 子程序才改寫 |
| m2 擁有權 | ✅,缺一項(m16) | §17.5 |
| m3 L42 的 hold 要在 apply 前寫 | ❌ 沒處理(見 m13) | L42 改搭 (6a),但 §6.2 (6) 列仍沒寫 hold 何時寫、落點斷言、重開指令 |
| m4 L42 與 (6a) 重疊 | ✅ | 已合併 |
| m5 bind 殘留檢查 | ✅ | P9 以 `/proc/mounts` 為準 |
| m6 成本 | ✅ | 沒有新增 trial |
| m7 上層對照 | ⚠️ 一半 | L3、L9、L10、L11、L27 已寫出;§10 仍沒有回報 p1-impl §4(`:288`)「開機路徑 `-wbox` 只寫進 B」被改成 A 上 bind 加 dry-run(m13) |
| m8 dry-run 共用寫入 | ⚠️ 一半 | §17.5 列了 otalog、canary、wd、decided;漏了 `autocommit.why`、`autocommit.canary-ok`、canary 暫存目錄(m1) |
| m9 build 成本 | ✅ | §17.2 |

### v8 B(`h23-review-v8-B.md`)
| 項 | 狀態 |
|---|---|
| BLOCKER-1 | ✅(同 A-B1) |
| MAJOR-1 / -2 / -3 | ✅(L43 已收緊:整行比對、沒有 `no usable`、事後讀回 arm 檔;也寫明了 `AUTOCOMMIT_TIMEOUT`) |
| m1 / m2 / m3 / m4 / m6 / m8 / m9 / m10 / m11 | ✅。m6 的 L11 負對照本身有問題,見 M3;m8 的 `grep -c = 1` 與見證寫兩次互相矛盾,見 m3 |
| m5 L42 程序 | ❌(同 A-m3,見 m13) |
| m7 §6.2 列 | ⚠️ 內容改成「見 §17」了,但「型」欄還是 `hold / A / F`,而 §17.3 說 prov-misc 不做 OTA(m13) |
| m12 生命週期 | ✅ dry-run 中死掉、bcm2710 已補;L51 bind 加 OTA 的情境已不存在;(6a) 在 apply 與重開之間死掉的情境沒補(m13) |

### 安全審查(`p1b-security-review.md`)
| 項 | 狀態 |
|---|---|
| F1 | ⚠️ §18.1 有設計,但有 M1、M2 與 m8–m12 的缺口 |
| F2 / F3 / F4 / F5 | ⚠️ §18.2 寫了修法,**沒有寫負測試**。安全審查每項都給了負測試:F2 是 `local-ab-tar` gate 案、F3 是 N8 要 FAIL、F4 是 staged 與非 ASCII 兩案、F5 是 W5 要 FAIL。F5 也只做了一半:gate 被 CI 或 `local-ab-tar` 直接呼叫時,仍會讀 env 的 `WBOX_DIR` / `GO`,建議只在 `PROV_GATE_SELFTEST=1` 時採用(m14) |
| F6 / F8–F11 | ✅ INFO;F6 的 `openat` 強化屬可選,沒列成殘項也可接受 |
| F7 | ✅ 已做(5316813,§18.2) |

---

## MAJOR

### M1. §18.1 沒定 wbox 判斷與 hold-commit 的先後;一旦寫錯,所有 wbox trial 的「mutant 無效」偵測都失效,還會出現假 PASS
- **情境**:
  - autocommit `:509-514` 現在是 `if HOLDUNSAFE … elif held_commit …`。§18.1 只說 wbox 的 why「摺進與 hold 相同的位置」,沒說排在 `held_commit` 之前還是之後。
  - 如果排在**前面**:wbox trial 永遠不會走到 `held_commit` 分支,所以永遠不印 `trial … is healthy and HELD`。harness 有好幾處判定靠這一行:
    - §4.3 步驟 1、§6.2 autocommit (1)、§4.2:「`HELD` 反而出現 → FAIL「mutant 無效」+ `back_to_a`」;
    - (9):`is healthy and HELD` 取自真 main 的 logread。
  - 這樣一來,mutant 無效時看不到 `HELD`,trial 等到期限才被 revert,得到 `TRIAL-REVERTED … reason=wbox test image …`。
    - 預期 REVERT 的單位如果只等 `TRIAL-REVERTED`(§4.3 步驟 1 的通則),就會判 **PASS**,也就是假 PASS。
    - autocommit (1) 有比對 reason 的內容,會變成 FAIL,但歸因錯了。
    - (9) 一定 FAIL。
  - 就算排在**後面**:hold 旗標被 DISCARDED 或沒寫的時候(這正是 F1 要防的人為失誤),mutant 無效同樣會得到 `TRIAL-REVERTED reason=wbox test image`,只看 `TRIAL-REVERTED` 的單位同樣會假 PASS。
- **證據**:
  - ✅ `batman-autocommit:505-515`(`FIRSTWHY` 在 hold 之前寫;hold 用 `if/elif`;`HELDLOGGED` 只印一次);`:236-239`(watchdog 從 `autocommit.why` 取 reason)。
  - ✅ 設計 §4.2 第 95 行、§4.3 步驟 1(第 218 行)、§6.2 (1) / (9)(第 369、374 行)。
- **修法**:
  1. §18.1 寫死順序:`HOLDUNSAFE` → `held_commit` → `wbox`。被 hold 的 wbox trial 行為與今天完全相同,仍印 `HELD`;只有沒 hold、或已 release 時才落到 wbox。
  2. §4.3 步驟 1 加一條通則:預期 REVERT 的單位,若 `TRIAL-REVERTED` 的 reason 是 wbox 那句(或 otalog 有 `AC WBOX-NOCOMMIT`),判「mutant 無效」FAIL,不判 PASS。
  3. CI `test-autocommit-wbox.sh` 加兩案,各配一個 mutant 負對照(把 wbox 分支移到 `held_commit` 前面 → 測試 BAD):hold 加 wbox → 印 `HELD`、why = held;hold 已 release 加 wbox → why = wbox,不 commit。
  4. 寫明 `release --wait` 對 wbox trial 一定逾時回 1。逐條查過 §6.2,目前沒有單位對 wbox trial 做 release(L17 只 release wsl.9 與 V),這一點要寫進文件。

### M2. §18.1 只擋 `commit`;`batman-slot rollback` 會把另一槽殘留的 wbox image 直接變成 committed
- **情境**:wbox trial 被 revert 後,另一槽(B)留著 wbox image,直到 `pr_brewrite` 把它寫回。在這段期間,以下任一情況都會讓 wbox image 成為 committed:
  - harness 死掉、brewrite 失敗、或 P9 只「印 restore 指令」(§4.2:另一槽含 wbox → 印 brewrite 指令);
  - 有人對 04 下 `batman-slot rollback`。這是文件寫明的補救手段,§4.2、§5 的 `pr_needs_person` 也會印這個指令。

  `cmd_rollback` 只檢查 BADMARK 與 prov lock gate,而 lock gate 只在 claimed / member 時才掛載目標 squashfs。`rollback` 之後重開,wbox image 以 committed 身分開機,autocommit 在 `:326`「already committed」就退出了,§18.1 的兩層防線都碰不到。這和 F1 是同一類人為失誤(拿錯操作,而不是拿錯檔),只是換了一條路。
- **證據**:✅ `batman-slot:786-797`(`cmd_rollback`:`slot_is_bad` + `rollback_lock_gate` + `write_autoboot`);✅ `:771-784`(lock gate 已經有「ro 掛載目標槽 rootfs 再檢查」的程式,但對 legacy / unclaimed 一律 `return 0`);✅ `batman-autocommit:326`。
- **修法**:
  - `cmd_rollback` 對**目標槽**一律(不論 prov 狀態)ro 掛載它的 squashfs,讀 `etc/batman-build`。有非空的 `BATMAN_WBOX=`(或 VER 含 `.wbox-`,見 m9)就拒絕。逃生口與 `commit` 共用同一個(見 m8)。
  - 掛載失敗時的處理要寫明:建議 fail-closed。lock gate 對 claimed 節點已經是 fail-closed,legacy 節點多一次掛載的成本可以接受。
  - CI 案:假目標槽帶 wbox → 拒絕;拿掉這項檢查 → BAD。
  - 節點負測試:B 留著 wbox(本來就會出現在每個 revert 型單位之後、brewrite 之前)時跑 `batman-slot rollback`,要看到拒絕,而且 autoboot 沒變。
  - §18.1 的「擁有權」與「讀者」要加上 `batman-slot rollback`;§7 的「我們自己」列也要更新。
  - 掃一遍其他會讓某個槽變成 committed default 的路徑,逐條寫明有沒有被擋:`apply` 只寫 tryboot;#133 stale fallback 在 autocommit 迴圈內,會被擋;fw-override 不 commit。

### M3. L11 的負對照與原始碼不符:helper 在 `PrepareDir` 失敗前就寫了 health,而且 procd 會每 5 s respawn
- **情境**:§17.4 L11 的負對照是「在 socket 目錄放一個普通檔 → restart → log `sock: unexpected … refusing to start`、health 15 s 內**不**更新」。實際的 daemon 啟動序是:
  1. `boot.Run`,會重寫 p6 `prov-state`;
  2. `go h.Run(stop)`,`Run` 第一件事就是 `Tick(15)` 寫 health;
  3. `sock.PrepareDir` 失敗 → `os.Exit(1)`。

  init 設的是 `respawn 3600 5 0`(無限次、每次間隔 5 s)。所以只要 health goroutine 在 `os.Exit` 之前排到,health 就會被寫入;每次 respawn 都再賽一次跑。15 s 內大約有 3 次機會。「15 s 內不更新」這個結果不確定,很可能被 health 更新推翻。而 L11 的正向判定裡,「health 15 s 內更新」這一條在 crash loop 下照樣成立,沒有判別力。

  另外,crash loop 的每一輪都重跑 `boot.Run`:重寫 `prov-state`、印 `boot rc=` 行,有 `.txn` 時還會起 `restoreWireless`。這些副作用 §7.2 / §17.5 都沒列,也會撞上 §17.5 新加的 P9 `prov-state` 檢查。
- **證據**:✅ `main.go:467-476`(`go h.Run(stop)` 在 `PrepareDir` 之前,失敗就 `os.Exit(1)`);✅ `health.go:163-165`(`Run` 先 `Tick(15)`);✅ `batman-provhelper.init`(`procd_set_param respawn 3600 5 0`,註解寫「endless respawn」);✅ `sock.go:74`;✅ `boot.go:276-297`(`writeProvState`)。
- **修法**:
  - L11 的判定改用 socket 層。
    - 正向:新 pid 存活 ≥ 30 s 不變(沒有 respawn);`helper.sock` 存在,屬主與權限照 §4.5;`provclient` 經 socket 的一個唯讀請求成功。
    - 負對照:放檔 → 30 s 內 pid 換了 ≥ 2 次(或 procd 的 instance 不是 running)、`helper.sock` 不存在、`provclient` 連線失敗、log 有 `sock: unexpected`。
  - health 那一條只留作記錄,不當判定。
  - §7.2 補一列:負對照期間 helper crash loop,每輪重跑 `boot.Run`、重寫 `prov-state`;還原 = 刪檔 → restart → 斷言 `prov-state` 第 2 欄 = `helper`、第 3 欄 = 快照。
  - 負對照要在**沒有** `.txn` 時做,寫成前置斷言。
  - 若 p1-impl `:539` 的「helper crash loop」要由 prov-misc 涵蓋,這個負對照順便就是它的 characterization,寫明即可。

---

## MINOR

- **m1 「L 臂讀到 `mesh join required` 就殺,不會到 canary」不成立;dry-run 也寫真名的 run-dir 檔**
  - `:425` 印出那一行之後,沒有任何等待:`:426` otalog → `:429-436` 起 watchdog → `:487-492` 第一次 `health_ok`。04 有 OTS tenant,而 committed 開機時 `autocommit.canary-ok` 不存在(真 main 在 `:326` 就退出了),所以第一次 poll 就會跑 `canary_run`,做 `docker import` 或 `run`(`:459-470`),之後 `:515` 寫真名的 `$RUNDIR/autocommit.why`。
  - harness 經 ssh 輪詢 stdout 檔,一定有延遲,實際上多半是在 canary 進行中才殺。後果:`docker import` 管線被中斷;`batman_tmp -d canary` 的暫存目錄留著;`autocommit.canary-ok` 可能被建立。
  - 若 p6 剛好有 `autocommit-hold-once` 或 `autocommit-hold-commit`,dry-run 還會寫真名的 `autocommit.hold-consumed`(`:99`)、`autocommit.hold-discarded`(`:289`)或 `autocommit.ctl.dry`。
  - 修法:
    - 在節點端用一個 reader 決定什麼時候殺:`setsid … run 2>&1 | while read l; do echo "$l" >>out; case $l in *"mesh join required:"*) kill -TERM -- -$pg; break;; esac; done`。殺的時點就落在第一次 `health_ok` 之前(只差 ms 級)。
    - 快照與清除清單補上 `autocommit.why`、`autocommit.canary-ok`、`$RUNDIR` 下的 canary 暫存目錄。
    - 每臂前斷言 p6 沒有兩個 hold 旗標。
    - §7.2 改寫成「可能」跑 canary。
- **m2 `pgrep -f batman-autocommit` 會配到 harness 自己的 `sh -c`;pgid 怎麼取沒寫;deadman 可能殺到 pgid 被重用的別的 group**
  - repo 已經有前例:`pty-commit-254.sh:28` 的註解就是在講這件事(review B1)。§17.2 的「bind 前斷言沒有 autocommit 在跑」也一樣會自我匹配。
  - 修法:
    - 用 `/proc/[0-9]*/cmdline` 精確比對 argv(`batman-autocommit\0run`),並排除自己的 pid 與父 pid;或用 `'[b]atman-autocommit run'` 這種寫法。
    - pgid 由節點端 launcher 從 `/proc/$!/stat` 第 5 欄取得,斷言它等於 `$!`(非互動 shell 下 busybox `setsid` 不會 fork;我在 WSL 的探針看到 pid = pgid = sid,⚠️ 不是 04 上的 busybox),寫進 `$DVD/<run>/dryrun.pgid`。
    - deadman 殺之前先確認 `/proc/<pgid>/environ` 含 `AUTOCOMMIT_DRYRUN=1`。
- **m3 見證的 `grep -c` 會是 2,不是 1**:§17.2 寫「mutant 那一行旁加 `log … WBOX-misc-LNN-…`,檔頭註解另一次」,又要求 `grep -c WBOX-misc-LNN /usr/bin/batman-autocommit` = 1,兩者矛盾。照文件實作,bind 斷言一定 FAIL。改成 = 2,或改成只比對 `log` 那一行的 pattern。
- **m4 CI `test-arm-mesh-254.sh` 碰到寫死的路徑**:
  - `_ab_arm_mesh` 寫死了三個路徑:`f=/opt/batdata/state/ota-armed.mesh`、`grep -q ' /opt/batdata ' /proc/mounts`、`/usr/lib/batman/meshjoin.sh`(在子殼裡 source,會蓋掉預先定義的 stub 函式)。另外 `platform-ab.sh` 一 source 就會讀 `/lib/functions.sh`。用函式覆寫做不到「stub `/proc/mounts` 檢查」。runner 上沒有 meshjoin.sh,「空 + 未入網 → radio」這一案會因為檔案不存在而**一定**通過,完全沒走到 `meshjoin_joined` 的退路(stage1 L51:「joinwatch 停用時退回當下 `meshjoin_joined` 單次取樣」)。
  - 修法:在 dv-sbx(root)裡用 `unshare -m` 開一個 mount namespace:`/opt/batdata` 掛 tmpfs,stub 版 `meshjoin.sh` bind 到 `/usr/lib/batman/meshjoin.sh`,提供 `/lib/functions.sh`。
  - 案例補上:`lastjoined` 空加 `meshjoin_joined` 真 → `joined`,並配一個 mutant(拿掉 `elif` 分支)。
  - 「caller 不是 procd」這一案改成斷言「事先放的檔被**刪掉**」。`platform-ab.sh:106` 先 `rm` 才檢查 caller,不是「不寫」。
- **m5 L10(dbus)沒有有判別力的負對照;L9 沒定義「health ok」**:health 行的欄位(`health.go:4,138`)都不靠 dbus(mgmt socket 加 pid),所以「dbus 重啟後 health ok」沒有因 dbus 而失敗的路徑。`bluetoothd stop` 的負對照只涵蓋 L9。修法:L10 明標 characterization(P1 的 helper 不用 dbus,P2 provd 的 `NameOwnerChanged` 再測,§6.3),或另找一個依賴 dbus 的觀察點。L9 寫明「ok」= `bluetoothd=1 hci0_powered=1` 且 ts 新鮮。⚠️ dbus 重啟可能讓 bluetoothd 退出且沒被 respawn,這件事值得記錄,但它不是 helper 的性質。
- **m6 L3 的負對照引用 E-H6 的舊證據**:同一輪 L7 的 5 個 powerloss 單位都會做 sysrq,建議直接引用同一 run 裡的 `UNCLEAN … hints: sysrq` 當負對照(同版本、同一套 95)。正向另加一條:helper 在 K15 的最後一次寫入有落地(stage1 L3 的本意是 stop 順序)。
- **m7 L51 的判定正向沒有寫明「只差第 3 欄」**:`required: 1` 也可以是 boot8 或槽不符造成的。寫明 L51 正向的檔 = L43 對照臂的檔(同一 run 的同一個 boot8 與 active),只把 `radio` 改成 `joined`。L38 臂 c(boot_id 不符)沒有 mutant,明標 characterization。
- **m8 逃生口的命名與機制**:`batman-slot` 既有的慣例是 `allowed X`,也就是 env `BATMAN_ALLOW_X` 或 root 擁有的 `/tmp/batman-slot.allow-x` 旗標(`batman-slot:77`),後者 `halow-status:107` 會顯示出來。§18.1 自己另取了 `BATMAN_SLOT_ALLOW_WBOX`。
  - 建議二選一:乾脆不要逃生口(§18.1 自己說「§6.2 目前沒有單位需要」,也就沒有攻擊面);或用 `allowed WBOX`,好讓它在 `halow-status` 上看得到。
  - 寫明 autocommit 那一層不讀任何逃生口(它根本不會呼叫 `commit`)。
  - 權限邊界:非 root 本來就不能 commit,被攻陷的 root 元件本來就能寫槽,所以這個逃生口不跨權限。⚠️ 但 env 會被子程序繼承(例如操作員在 profile 裡 export),旗標檔也會活到重開。這兩點都要寫進 §7。
- **m9 `/etc/batman-build` 讀不到時當成非 wbox**:
  - autocommit 這一層其實是 fail-closed:`:455` 檔案缺或空就判 unhealthy,永不 commit。§18.1 應該把這點當作證據寫進去。
  - `batman-slot commit` 這一層真的是 fail-open。理由(release image 沒有這一行)成立,但只靠一個標記。
  - 建議加第二個獨立標記:`BATMAN_VERSION` 含 `.wbox-` 也算 wbox(VER 由 stamp 強制帶 `.dirty.wbox-<name>`,§4.2)。兩個標記任一命中就拒絕。
  - 「行有、值空」要寫明算非 wbox,並給 CI 一案。
- **m10 「降級不相關」不精確:磁碟上已經有沒帶閘的 wbox payload**:`~/out` 現有 `1.5.14-wsl.5…wbox-test`、`wsl.6…wbox-test` ×2、`wsl.7…wbox-test`、`wsl.7…wbox-rc9-unclaimed`,後者在 F11 屬於「削弱擁有權」那一組。F1 的情境「拿錯檔」正好包含這些檔:它們自己的 autocommit 沒有閘,沒 hold 推上去就會被 commit。修法:
  - `pr_ota_b` 推送前,對 payload 的 `usr/bin/batman-autocommit` 斷言含閘的字串(`WBOX-NOCOMMIT`),不含就拒絕;
  - 把沒有閘的 wbox payload 移到隔離目錄或刪掉(若 m11 保留 wsl.6 負對照,就只留那一份,並寫明);
  - `lint-wbox` 禁止 wbox patch 碰閘本身的那幾行(misc-L* 也改 autocommit,所以要以行為範圍)。
- **m11 節點單位 `prov-wbox-nocommit-254`**:
  - (a) 正向臂沒有 hold。如果閘本身壞了(這正是被測的東西),`96-noprov` 就會被 commit 進 04。要寫明安全網:看到 `COMMITTED` → FAIL → `batman-slot rollback` + `reboot committed` + brewrite。正向建議改用 `test` 變體,它在 F11 是傷害最低的一級。
  - (b) 前置:04 legacy 加 `mesh-joined` 時要求 02 在 `batctl n`(§4.3 `pr_normalise` 的同一事實)。沒有 `WBOX-NOCOMMIT` 行、reason 又是 mesh 類 → 判 INVALID,不判 FAIL。
  - (c) 負對照讓 04 commit 一個 wsl.6 的 wbox 槽,這違反 §4.2「只進非 committed 槽」,也違反 §16.18「舊 payload 不上節點」的精神;在 COMMITTED 與 rollback 之間若 harness 死掉,04 就停在 committed 的 wbox 上。建議改成:CI 的翻轉測試(拿掉閘 → BAD)當真正的負對照;節點端依靠「`WBOX-NOCOMMIT` 只在其他條件都健康時才出現」這個性質,證明「沒有閘就會 commit」;如果還要節點端證據,就在同一 trial 內背景跑一次 dry-run,得到 `DRYRUN decision: COMMIT`(作法同 (9))。若堅持保留 wsl.6 commit,§5 要補「harness 死於 COMMITTED 與 rollback 之間」一列,§7.2 列副作用,並寫明它是 §16.18 的例外。
  - (d) 成本:正向是 revert 型(約 37 分 + 600 s),負向還要多一次 commit、rollback、重開、brewrite。§17.6 說「在 H3-U3 預算內」只涵蓋 §17,§18.1 的成本沒算,要算出來並告訴使用者。
- **m12 §18.1 由哪個 PR 承載沒寫**:它改的是 `batman-provision`,所以要進 P1b 或另開一個產品 PR。照 §16.18:重切 rc、`BATMAN_BUILD_N` 加 1、全部 wbox payload 重 build(加上 4 個 misc,共 18 加 4);P1b 的程式碼審查與 `/security-review` 對這段 diff 要再跑一次。還有一點:wbox 閘必須進到被 trial 的 image 裡,也就是要在第一次重 build wbox 之前 merge 進 rc。
- **m13 前幾輪的遺留與文件不一致**:
  - v8 A-m7:§10 沒回報 p1-impl §4(`:288`)的改動。
  - v8 A-m3 / B-m5:(6a) 的 hold 要在 `batman-slot apply` 之前寫並 `cmp`;落點斷言照 `pr_ota_b`;重開指令要寫明(tryboot 已 armed 時 `reboot committed` 會退成 plain reboot)。§5 也要補「在 apply 與重開之間死掉」一列。
  - §6.2 `prov-misc-254` 列的型 `hold / A / F` 與 §17.3「不做 OTA」矛盾,應該是 `— / A / F`。
  - §7 的 actor 表缺兩列:autocommit 的 bind(我們自己)與 §18.1(節點自己拒絕)。
  - §7.3 的 build 數仍寫 18。
- **m14 安全審查 F2–F5 沒有負測試**:見 §0 的表。每一項都把安全審查給的案例放進 `test-build-board-wbox.sh` 或 gate 自測,並附「修之前 FAIL」的輸出。
- **m15 P9 `prov-state` 檢查的邊界**:
  - 「第 2 欄 ≠ `helper` 且 uptime > 120 s → FAIL」:helper 在 S89 起來之前就結束的開機,或 M3 的 crash loop 收尾之前,都會判 FAIL。另一方面,`main.go:340` 的 `--apply-state` 會寫 `99zz`。要寫明這一條只在 helper 有安裝且 `running` 時才適用。
  - 「第 3 欄 ≠ 快照」:快照的來源沒寫。新一輪 P9 跑的時候,沒有本 run 的快照。要寫明讀的是上一個 run 留在 `$DVD/<run>` 的快照,還是只交給 deadman 處理。
- **m16 §17.5 的 `ota-armed.mesh` 刪者少了一個**:`_ab_arm_mesh` 在每一次 `platform_check_image` 時都會先 `rm`(`platform-ab.sh:106`,包括 `sysupgrade -T` 與 LuCI 的驗證),而且是在 caller 檢查之前。要列進擁有權表。prov-misc 期間不能有任何 `sysupgrade -T`,寫成前置條件。

---

## 回答派工的具體問題

1. **每個 autocommit mutant 是否只拿掉指名的檢查?** ✅ 對照 `:402-421`:
   - L38 拿掉 `:404` 迴圈,只改「等待」;
   - L42 只改 `:421` 的缺檔分支,錯檔仍回 1,不影響 L43;
   - L43 只拿掉 `:420` 的第 1 欄比對;
   - L51 只讓第 3 欄 `joined` 等同 `radio`。

   要補的只有 m7:L51 的正向要以「只差第 3 欄」證明 `required: 1` 不是別的原因造成的。
2. **dry-run 臂的程序能否避免 v8 的副作用?**
   - ✅ 期限 `uptime+600` 是絕對值,而且是在 `:381` 的 clamp **之後**才覆寫(`:382`),所以不受 300–3600 的限制;watchdog 在 150 s 內不會到期,`autocommit.decided` 不會被建立,`:237` 也不會刪 arm 檔。
   - ✅ `( revert_watchdog ) &` 子殼與 main 在同一個 pgid,殺整個 group 會一起殺掉。fork 與 group 訊號的競態由核心處理(⚠️ 依 Linux 語意推論)。
   - ⚠️ 殘餘問題:真名的 `autocommit.why` / `canary-ok` 與 canary 動作(m1)、pgrep 自我匹配與 pgid 來源(m2)、hold 旗標在時的真名寫入(m1)。
   - ✅ 快照與還原的欄位規則正確:第 3、5 欄照抄;`SetLastKnown` 與 `writeProvState` 都會保留其他欄或沿用前值(`main.go:204-222`、`boot.go:284-297`)。
3. **只在 dry-run 期間 bind `/usr/bin/batman-autocommit` 安全嗎?** ✅ 安全。
   - 產品裡會執行它的只有 init(`init.d/batman-autocommit:11`,one-shot,沒有 respawn),而 committed 槽在 `:326` 就退出了。
   - `halow-status` 與 `joinwatch` 只讀旗標字串,不執行它。
   - 它不在 `RAMFS_COPY_BIN`(`platform-ab.sh:38`)。
   - daily-validation 的 `batman-autocommit canary` 由 lease 互斥。

   要補的是 m3(見證計數)與 P9 / deadman 以 `/proc/mounts` 為準(§17.5 已寫)。
4. **L42 / L51 寫入半邊的覆蓋是否成立、有沒有判別力?**
   - L42:(6a) 的「apply 後沒有檔」是一個「不存在」斷言,本身沒有能讓它失敗的 mutant。§17.4 用「白箱放一個正確的檔 → `required: 0`」證明這個斷言**有後果**,這是合理的,但不等於斷言本身有判別力。建議在 CI 加一條靜態檢查:`batman-slot` 不得出現 `ota-armed.mesh`;只有 `platform-ab.sh` 與 `batman-autocommit` 可以出現。也要補 m13 的 (6a) 程序。
   - L51:CI 測試的方向對,但照現在的寫法有一案一定 PASS、退路沒測到(m4)。(7) 的 `m=joined` 是真機的正向證據(`_ab_arm_mesh` 不看 prov 狀態,所以 04 不必是 member ✅)。
5. **L11 / L9 / L10 / L27 / L3 現在有沒有真的負對照?**
   - L11:❌ 負對照的預期是錯的(M3)。
   - L9:✅,但要定義「ok」(m5)。
   - L10:❌,沒有判別力,應標 characterization(m5)。
   - L27:✅,未授權金鑰被拒,證明登入斷言能區分授權。
   - L3:⚠️ 有,但引用舊證據,建議改用同一 run 的 sysrq(m6)。
6. **§18.1 的位置與互動**:
   - 與 hold:順序沒定(M1)。
   - 與 FIRSTWHY:✅ 照 hold 的作法不搶。
   - 與 canary:✅ 摺進 why 之後不會進 commit 分支,所以 pre-commit canary 不會跑。
   - 與 deadline watchdog:✅ 會 revert,reason 取自 `autocommit.why`,所以單位判定要照 M1-2。
   - 與 hold-once:wbox 加 hold-once → 不 commit、也不 revert,一直停在 trial,直到下次重開才回 committed。這是 fail-secure,要寫明。
   - 與 COMMITTED-BY-OPERATOR:✅ `batman-slot commit` 拒絕,所以不會出現。
   - 與 #133 stale fallback:✅ 在同一個迴圈內,會被擋。
   - 漏掉的路徑:rollback(M2)。
7. **`batman-slot commit` 的逃生口**:見 m8。非 root 碰不到;被攻陷的 root 元件本來就能寫槽,所以不跨權限。harness 與產品目前都沒有需要 commit wbox 的地方(逐條查了 §6.2:L17 的 wsl.9 與 V、`pr_normalise` 的 V、(9) 的 dry-run,都不是真的 commit wbox)。
8. **`/etc/batman-build` 讀不到 → 非 wbox**:autocommit 這一層實際上是 fail-closed(`:455`),`batman-slot` 這一層是 fail-open。建議加第二個標記(m9)。
9. **新節點單位的負對照是否安全**:有風險,而且非必要(m11-c)。

## 證據分類

**✅ 原始碼已核對**
- `batman-autocommit` 的行號:`:44-53,84,94-106,199,207-215,233-240,270-292,326,376-386,398-437,441-483,486-537`。
- `batman-slot:77,735-797`。
- `platform-ab.sh:38-75,76-118`。
- `98-batman-sysupgrade`。
- `init.d/batman-autocommit`、`batman-provhelper.init`。
- `main.go:204-222,325-345,467-487`;`boot.go:276-297`;`sock.go:60-75`;`health.go:4,138,163-171`。
- `chain1-254.sh:347`、`pty-commit-254.sh:28`、`halow-status:107`、`joinwatch:168-180`。
- `~/out` 的 wbox payload 清單:
  ```
  /home/yello/out/1.5.14-wsl.5+01b12c9.fwd2a4bfd.dirty.wbox-test
  /home/yello/out/1.5.14-wsl.6+f6ac1f7.fw739c163.dirty.wbox-test
  /home/yello/out/1.5.14-wsl.6+f6ac1f7.fwdb6693d.dirty.wbox-test
  /home/yello/out/1.5.14-wsl.7+d0643d5.fwdf93828.dirty.wbox-rc9-unclaimed
  /home/yello/out/1.5.14-wsl.7+d0643d5.fwdf93828.dirty.wbox-test
  ```

**⚠️ 推論或只部分驗證**
- busybox `setsid` 在非互動 shell 下不 fork:WSL 探針印出 `inner pid=601268 pgid=601268 sid=601268`,但用的不是節點的 busybox,輸出也不完整。
- fork 與 group 訊號的核心競態。
- 被殺的 `docker run --rm` 由 daemon 清掉容器。
- dbus 重啟對 bluetoothd 的影響。
- M3 裡 health goroutine 與 `os.Exit` 誰先跑(由排程決定,兩種結果都可能,所以判「不確定」)。

**❌ 沒做**
- 任何上機驗證。
- 沙箱實跑 autocommit:m1 的時序是直接從程式碼讀出來的,沒有實測。
- firmware 樹的 `stamp-batman-build.sh` / gate(依指示不碰)。

## 摘要

§17 v9 已經把 v8 的 BLOCKER 與六個 MAJOR 都解決了。四個 mutant 都準確,dry-run 臂的期限、process group 與快照規則基本正確,剩下的是程序細節(m1–m4、m7)。

新增的三個 MAJOR:
1. §18.1 要寫死 `HOLDUNSAFE` → `held_commit` → `wbox` 的順序,並讓預期 REVERT 的單位把 `reason=wbox` 判為「mutant 無效」,否則會出現假 PASS(M1)。
2. `batman-slot rollback` 也要對目標槽檢查 wbox,否則 revert 後殘留在另一槽的 wbox 一次 rollback 就變成 committed(M2)。
3. L11 的負對照與 helper 的啟動序、procd respawn 衝突,判定要改用 socket 層,並列出 crash loop 的副作用(M3)。

另有兩件事要讓使用者知道:
- 磁碟上有 5 份沒帶閘的 wbox payload(m10);
- §18.1 節點單位的成本,以及讓 04 commit wsl.6 wbox 的負對照風險(m11)。

修完後只需重審 §18.1 與 §17.4 的 L11。§18.1 在 M1 / M2 修好、過審之前不要實作。
