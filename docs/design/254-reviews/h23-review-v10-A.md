# h23 設計審查 v10(§19)— 審查者 A

- 對象:`docs/design/254-h23-harness.md`,全文 §0–§19。派工寫的是 16a0b0b,但 branch 實際在 **18114c7**:比 16a0b0b 多一行,內容是使用者 2026-10-28 決定「`prov-wbox-nocommit-254` 要做」。本審查以 18114c7 為準。
- 原始碼:rc 樹 `/home/yello/Batman-rc` @ d0643d5。
  - `batman-autocommit` 全檔(1–558);
  - `batman-slot`:`allowed` :77、`slot_is_bad` :364、`cmd_commit` :735、`rollback_lock_gate` :771、`cmd_rollback` :786;
  - `halow-status:136-146`;
  - harness `brewrite-254.sh:13`、`chain1-254.sh:140,217,303,351`、`ab-selftest.sh:325`、`negctl-old-slot-254.sh:29`、`fault-injection.sh:141`、`daily-validation.sh:856`;
  - firmware `scripts/check-prov-test-gate.sh:23,34,66`(唯讀);
  - Batman-h23 `scripts/lint-wbox.sh:26,29`;
  - firmware busybox 1.36.1 的 build config 與 `procps/ps.c`、`pgrep.c`(唯讀)。
- 沙箱:`/home/yello/dreview10A.*`,放 `batman-autocommit` 副本,只用 sed 改路徑(p6 / rundir.sh / meshjoin.sh / batman-build 指到沙箱;`p6()`、`dt_tryboot()` 改成 stub)。以 **WSL busybox 1.36.1 ash** 執行;`batman-slot` 與 `logger` 是 PATH stub。跑完已刪。
- 限制:沒有 ssh,沒有 commit,沒有改 worktree(本報告檔除外),沒碰 firmware build(只讀檔)。並行的審查者 B 的沙箱程序沒有被動到。
- 標記:✅ 實跑或原始碼看過;⚠️ 推論或部分;❌ 沒做。

## 結論

**APPROVE-WITH-CHANGES**:0 BLOCKER / 2 MAJOR / 14 MINOR。

§19 把 v9 的 7 個 MAJOR(A 3 個、B 4 個)都正面處理了。

- 核心機制 `hold-consumed` + `AUTOCOMMIT_TIMEOUT=1`:我在沙箱對 **全部 7 個 L 臂**都實跑過(B 的 E9 只跑了 2 臂)。結果:
  - 每一臂都在 `mesh join required` 行之後自己結束;
  - 不起 watchdog、不進 poll 迴圈;
  - 不新增也不改任何真名檔;
  - **L38 臂 b 的 60 s 等待不受 `TIMEOUT=1` 影響**。
- 反向對照:拿掉 `hold-consumed` 會怎樣?watchdog 立即觸發,刪掉 p6 的 `ota-armed.mesh`,並建立 `decided` / `wd`。這證明 `hold-consumed` 是有承重作用的那一環。

兩個 MAJOR 都在「把設計寫成可實作的程式」這一層:
1. §19.1 的結束判定程序在 04 上做不出來,而且它的 15 s 上限會讓 L38 臂 a / b 一律 INVALID(M1)。
2. misc 變體名含大寫 `L`,與既有的 `lint-wbox` 及 gate 的見證格式不相容;照文字實作或「修 lint」都會出問題(M2)。

兩者都是局部修正,修完只需重看 §19.1 與 §17.2 的命名,不需要再審整份。

---

## 0. v9(與 v8、安全審查)發現的處理狀況

### v9-A(本人上一輪)
| 項 | 狀態 | 依據 |
|---|---|---|
| M1 wbox / hold 順序 | ✅ | §19.3:順序寫死 `HOLDUNSAFE → held_commit → wbox`;revert 型單位斷言 reason 不含 `wbox test image`;CI 有「閘擺在 hold 前 → BAD」的負對照 |
| M1 修法 4(`release --wait` 對 wbox 必逾時) | ⚠️ 沒寫,只缺文件 | 我查了 §6.2,沒有單位會 release wbox trial |
| M2 rollback 洞 | ✅ | §19.3:`cmd_rollback` 讀目標槽 `etc/batman-build`;不設逃生口 |
| M2「掃其他會變 committed default 的路徑」 | ⚠️ 沒逐條列出(m12) | |
| M3 L11 | ✅ | 改用 socket 層判定 + pid 穩定 ≥ 10 s;副作用已列 |
| M3「沒有 `.txn`」前置 | ❌(m10) | |
| m1 canary / 真名檔 | ✅ | 改用自行結束法;快照清單已擴充 |
| m2 pgrep / pgid | ⚠️ | 不再用 `pgrep -f`,但換成的 `ps -o` 在節點上不存在(**M1**) |
| m3 `grep -c` = 2 | ✅ | |
| m4 L51 CI | ✅ | 改用 dv-sbx;補了 fallback 案 |
| m5 L9 / L10 | ✅ | |
| m6 L3 用舊證據 | ❌(m10) | |
| m7 L51「只差第 3 欄」/ L38 臂 c 標 characterization | ❌(m10) | |
| m8 逃生口 | ✅ | 拿掉 |
| m9 讀不到 → wbox、第二訊號 | ✅,邊界見 m7 | |
| m10 舊 payload 隔離 | ✅ | |
| m10 `lint-wbox` 禁止碰閘那幾行 | ❌(m9) | |
| m11 (a) 回歸安全網 | ⚠️ | 有 rollback,沒有 `reboot committed`;rollback 臂本身沒有安全網(m4) |
| m11 (b) 前置 02 在 `batctl n` | ✅ | |
| m11 (b) INVALID 規則 | ❌(m5) | |
| m11 (c) 拿掉負對照 | ✅ | |
| m11 (d) 成本 | ⚠️ 低估(m6) | |
| m12 承載 PR | ✅ | |
| m13 (6a) 程序 | ✅ | |
| m13 §5「apply 與重開之間死掉」一列 | ❌(m10) | |
| m13 actor 表 bind 列 | ❌(m10) | |
| m14 F2–F5 負測試 | ✅ | F5 的說法有誤,見 m8 |
| m15 P9 `prov-state` | ✅ | |
| m16 `_ab_arm_mesh` 刪者 | ✅ | |

### v9-B
| 項 | 狀態 |
|---|---|
| MAJOR-1 / -3 / -4 | ✅ |
| MAJOR-2 | ✅ 機制正確,我在沙箱複驗了全部臂;但結束判定程序有問題(**M1**) |
| m1、m6 | ✅ |
| m2 | ⚠️(**M1**) |
| m3 見證行要放在不受 mutant 條件影響的位置 | ❌(m10) |
| m4 | ⚠️ 快照清單漏 `autocommit.ctl.dry`、`autocommit-dryrun.log`;沒有「p6 無 hold 旗標」前置(m3) |
| m5 L42 靜態 lint「`batman-slot` 不寫 `ota-armed.mesh`」 | ❌(m10) |
| m7 | ✅ |
| m8 CI 用 mount namespace,不在產品加 env 覆寫 | ⚠️ 沒寫 CI 怎麼 stub `/rom`(m11) |
| m9 | ✅ |
| m10 reason 只記錄 | ❌:§19.3 仍斷言 `reason=wbox test image`(m5) |
| m11、m12、m14 | ✅ |
| m13 成本 | ⚠️(m6) |
| m15 L27 / dropbear 副作用 | ❌(m10) |
| m16 | ✅ |
| §5「`pr_ota_b` 要拒絕 `misc-*`」、「`lint-wbox` 拒絕碰閘的 patch」 | ❌(m9) |

### v8-A / v8-B
- v8 的 BLOCKER / MAJOR 在 v9 已解。
- v8-A m7 / B m12(§10)由 §19.3 補上 ✅。
- 沒有新的回歸。

### 安全審查(`p1b-security-review.md`)
- F1 ✅(§19.3)。
- F2 / F3 / F4 ✅(負測試已列)。
- F5 ⚠️:改名不等於「不繼承」(m8)。
- F6–F11 ✅。

---

## 沙箱實證(✅ 原始輸出節錄;WSL busybox 1.36.1 ash)

每臂的作法:臂前 `: > $RUNDIR/autocommit.hold-consumed`,再以 `setsid env AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1 AUTOCOMMIT_TIMEOUT=1 ac run &` 起跑。`fs-delta` 是臂前臂後 `find run batdata` 加 md5 的 diff。

```
== L38b: elapsed=58.13s(date;同機 uptime 量 60.04 s,見下) sid-left=[]
    | hold present — this trial will not be reverted
    | slot A is an uncommitted trial — gate until uptime 5249s (now 5249s), revert=0
    | mesh join required: 0 (prov=unclaimed mesh_expect=0 radio_required=0)
    | slot A NOT committed by uptime 5249s. last: ?
    fs-delta: (空)
== L38a: elapsed=4.04s(gate 行後 3 s 改寫 prov-state=helper/member/radio、刪 arm 檔)
    | member: no usable ota-armed.mesh — neighbours required (fail-closed)
    | mesh join required: 1 (prov=member mesh_expect=radio radio_required=1)
    fs-delta: 只有 harness 自己改的 prov-state
== L38c: mesh join required: 1 (prov=none mesh_expect=- radio_required=0)   fs-delta: (空)
== L42:  no usable … + mesh join required: 1 (prov=member …)              fs-delta: (空)
== L43pos [cccccccc A radio]: mesh join required: 1,無 no usable 行          fs-delta: (空)
== L43ctl [bbbbbbbb A radio]: armed in radio-only mode + required: 0       fs-delta: (空)
== L51pos [bbbbbbbb A joined]: mesh join required: 1                        fs-delta: (空)
-- p6 有 autocommit-hold-commit(= 本版)時:
== HCmatch: HOLD-COMMIT: this trial (…) will not be committed …
    fs-delta: > run/autocommit-dryrun.log  > run/autocommit.ctl.dry/  > run/autocommit.ctl.dry/hold-commit
-- 反向對照:沒有 hold-consumed,TIMEOUT=1:
    | gate until uptime 5318s … revert=1
    | TRIAL-REVERTED slot A after 0s: unhealthy
    | DRYRUN decision: REVERT (reboot to the committed slot) — reason: unhealthy
    fs-delta: < batdata/state/ota-armed.mesh(被刪)  > run/autocommit.decided/  > run/autocommit.decided/pid  > run/autocommit.wd/
-- 時鐘:busybox 60× sleep 1:uptime-delta=60.04  date-delta=58.125
```

另外,節點 busybox 的設定(firmware `build_dir/target-aarch64_cortex-a72_musl/busybox-default/busybox-1.36.1/.config`):

```
# CONFIG_DESKTOP is not set
CONFIG_PS=y
CONFIG_FEATURE_PS_WIDE=y
CONFIG_SETSID=y
CONFIG_FEATURE_SH_NOFORK=y
# CONFIG_PACKAGE_procps-ng is not set
```

`procps/ps.c:670`:非 DESKTOP 的 `getopt32(argv, "^" … "w" "\0" "ww")`,不接受 `-o`。

---

## MAJOR

### M1. §19.1 的結束判定在 04 上做不出來;15 s 上限會讓 L38 臂 a / b 一律 INVALID
- **情境**:
  1. §19.1 規定:結束判定「用 `ps -o pid,pgid` 找該 pgid 的程序」。但 04 的 `ps` 是 busybox 非 DESKTOP 版,只接受 `w` / `ww`,`-o` 直接 usage 錯誤退出;image 也沒有 procps-ng。
     - 如果實作者沒檢查 rc,把空輸出當成「pgid 裡沒有程序 = 已結束」,這個判定就是 **fail-open**:dry-run 還活著,harness 就開始寫回快照。
     - 這違反「找不到東西可檢查必須 FAIL」的規則。
  2. 同一段又說「15 s 未結束 → TERM → 5 s → KILL → 臂判 INVALID」,而且沒限定時間從哪裡算起。E-H5 的新項也寫「15 s 內程序結束」。
     - 但 L38 臂 b 的判別依據正是「`mesh join required` 行出現在起跑 ≥ 60 s 後」:沙箱實跑 uptime 60.04 s;程式是 `:404` 的 `i < 60` 迴圈,在 deadline 之前,不受 `TIMEOUT=1` 影響 ✅。
     - 臂 a 也要等 harness 在 gate 行後 ≥ 3 s 才改寫。
     - 照字面實作,15 s 一到就被殺、判 INVALID:**臂 b 這個唯一有判別力的臂永遠跑不出結果**,臂 a 也一樣。
- **證據**:
  - ✅ 上面的 busybox `.config` 與 `ps.c:670`;
  - ✅ `batman-autocommit:383,403-404,487`;
  - ✅ 沙箱 L38b 在 TIMEOUT=1 下仍等滿約 60 s(uptime);
  - ✅ §19.1 第 2 點與 E-H5 的文字。
- **修法**:
  - 成員判定改用節點上確定存在的東西:掃 `/proc/[0-9]*/stat` 的第 6 欄(session id,`setsid` 之後 sid = pgid = `$!`;沙箱就是這樣做的),或用 busybox `pgrep -s <sid>`(`pgrep.c:141` 有 `-s`)。讀不到 `/proc` 或工具 rc ≠ 0 → INVALID,不可判成「已結束」。
  - 逾時從 **`mesh join required` 行出現**時起算 15 s。另設一個「起跑到那一行」的上限:L38 臂 a / b 用 90 s,其他臂用 15 s。E-H5 照同樣規則寫。
  - 臂 a 的 mutant 情況要寫清楚:在「gate 行後 3 s」之前就看到 `mesh join required` 行,判「mutant 有效」(負對照的預期結果),不是 INVALID;正向臂遇到同樣情況才是 INVALID。

### M2. misc 變體名 `misc-L38` / `misc-L42` / `misc-L43` / `misc-L51` 與既有的 `lint-wbox` 名字規則、gate 的見證格式不相容
- **情境**:
  - §17.2 / §19.1 的變體名與見證 `WBOX-misc-LNN-<8 hex>` 都含大寫 `L`。
  - 既有工具全是小寫契約:
    - `lint-wbox.sh:26`:`case "$name" in *[!a-z0-9-]*|test) err "$name: bad variant name"` → 4 個 misc patch 一律被 lint 拒絕;
    - gate `check-prov-test-gate.sh:23`:`grep -rhaoE 'WBOX-[a-z0-9-]+-[0-9a-f]{8}'` 抓不到 `WBOX-misc-L38-…`(我實跑:同一段輸入只抓到 `WBOX-helper-flap-…`)。
  - 有名字的模式要求「rootfs 內的見證集合恰為本變體那一個」,所以 misc 的 build 一定 FAIL。
  - 更糟的情況:實作者為了讓 lint 過而放寬名字字元類別,卻沒改 gate 的 regex。那麼正常 build 的殘留掃描(§4.1.3「見證集合為空」)**看不到** misc 見證。一個殘留的 misc mutant `batman-autocommit`(拿掉 fail-closed 的那一版)混進 release image 時,gate 不會擋,對 L42 而言就是 fail-open。這正是 gate 要防的「我們自己」。
- **證據**:✅ `lint-wbox.sh:26,29`;✅ gate `:23`;✅ 實跑:
  ```
  printf 'WBOX-misc-L38-1a2b3c4d\nWBOX-helper-flap-0011aabb\n' | grep -oE 'WBOX-[a-z0-9-]+-[0-9a-f]{8}'
  → WBOX-helper-flap-0011aabb
  ```
- **修法**:
  - 變體名一律小寫:`misc-l38` / `misc-l42` / `misc-l43` / `misc-l51`;§17.2 表、§19.1 的 `grep -c WBOX-misc-lNN`、§6.2、`helpers.list`、§7.3 一起改。
  - 在 §4.2 寫明名字契約 `[a-z0-9-]+`,而且它必須和 gate regex 同一套。
  - `lint-wbox` 與 gate 自測各加一案:含大寫的見證放進 rootfs → 仍要被抓到(或者 regex 改成 `[A-Za-z0-9-]`,兩邊同步)。

---

## MINOR

- **m1 L38 臂 b 的「≥ 60 s」要用節點 uptime 量,並留餘量**:同一台 WSL 上,60 次 `sleep 1` 量到的 uptime 是 60.04 s,`date` 卻只有 58.13 s。04 沒有 RTC,開機後 NTP 經 mesh 可能 step 時間。改成:harness 在節點端記下起跑與看到那一行時的 `/proc/uptime`,判定門檻用 ≥ 55 s(mutant 會在 < 5 s 出現)。
- **m2 正向臂的前置:gate 行必須是 `revert=0`,且有 `hold present` 行**:反向對照顯示,`hold-consumed` 沒建成時(路徑寫錯、`RUNDIR` 解析不同),dry-run 會在幾 ms 內刪掉真的 p6 `ota-armed.mesh`,並建立 `decided` / `wd`。快照還原能補救,但臂要判 INVALID,不能繼續判定。deadman 的清除清單也要加 `hold-consumed`(§19.1 只寫「臂後刪」)。
- **m3 hold 旗標前置與快照清單**:p6 有 `autocommit-hold-commit` 時,dry-run 會建 `autocommit.ctl.dry/`(與 `hold-commit`)以及 `autocommit-dryrun.log`(沙箱 HCmatch);旗標不符時則寫真名的 `hold-discarded`(B 的 E6)。§19.1 的快照清單沒有 `ctl.dry`、`autocommit-dryrun.log`。修法:前置斷言 p6 沒有 `autocommit-hold-commit` / `autocommit-hold-once`(B-m4 原建議);清單補上這兩項。
- **m4 `prov-wbox-nocommit-254` 的 rollback 臂可能「因為別的原因被拒」而判 PASS,而且回歸時沒有安全網**:
  - `cmd_rollback` 在 wbox 檢查之外還有幾條路會 die:`assert_fw_sane`、`slot_is_bad`(BATMAN-BAD)、`rollback_lock_gate`(claimed / member)、`write_autoboot` 的 `power_ok`。正向臂只斷言「被拒、預設槽不變」,會因這些原因假 PASS。修法:斷言 stderr 含 `holds a -wbox test image`,且 `st` 紀錄沒有 `ROLLBACK-BEGIN`。
  - 反過來,如果閘回歸、rollback 成功,04 的預設槽就變成 wbox B。§19.3 的安全網只涵蓋 `COMMITTED`。這種情況要立刻 `batman-slot commit`:在 A 上執行會把 A 設回預設;不能再 rollback,那只會再指向 B。然後 FAIL,失敗就 `pr_needs_person`。
  - `COMMITTED` 安全網也要補 `batman-slot reboot committed`。rollback 只改 autoboot,不重開的話 04 會一直跑 wbox image。
- **m5 `prov-wbox-nocommit-254` 的 reason 與 INVALID**:
  - `TRIAL-REVERTED … reason=` 是最後一輪 poll 的 `why`(`:236-239`)。04 是 `NEED_MESH=1`,最後一輪 mesh 抖動,reason 就會變成 `mesh not joined/…`,導致假 FAIL。判定應放在 `otalog AC WBOX-NOCOMMIT`(只在 `ok ≥ NEED` 時記),reason 只記錄(B-m10)。
  - 沒有 `WBOX-NOCOMMIT` 行而 reason 是 mesh 類,判 INVALID(A-m11b)。
- **m6 成本低估,使用者是照低估的數字做的決定**:
  - §19.3 寫「1 次 trial(到期 revert 約 10 分)+ brewrite 約 14 分 ≈ 25 分」;
  - §7.3 的 revert 型是「≈ 37 分 + 600 s(+ ≤ 600 s watchdog 延遲)」,而且這個單位還多一個 rollback 臂;
  - 18114c7 記的是使用者依「≈ 25 分」做的決定。
  - 依規則要以 §7.3 的算法重算(約 47–57 分),**回報使用者並重新確認**。
- **m7 `/rom/etc/batman-build` 的邊界**:
  - ✅ A/B 節點有 `/rom`:`fault-injection.sh:141` 要求 `/rom` 的來源是 mmcblk 分割區;`daily-validation.sh:856` 的 `chk_patches_275` 在 fleet 上讀 `/rom/etc/batman-build`。不過 `:856` 有 `[ -f /rom/etc/batman-build ] || R=` 的退路,表示曾預期它可能不在。⚠️ 沒上機確認。
  - 沒有 overlay 的開機(failsafe、`/` 直接是 squashfs)沒有 `/rom`:autocommit 本來就不跑,但操作員的 `batman-slot commit` 會被 fail-closed 擋下。這可以接受,但要寫進生命週期列。
  - 建議 `cmd_commit` 改用與 rollback 相同的讀法:ro 掛載 `slot_rootdev "$A"` 的 squashfs。兩條路一致,不依賴 `/rom`。
  - autocommit 這一層的 fail-closed 對 release image 沒有新的風險:`:455` 在 `/etc/batman-build` 缺或空時本來就判 unhealthy ✅。
  - 新的 mount 要在所有路徑上 `umount` / `rmdir`(照 `rollback_lock_gate:778-782` 的寫法)。
- **m8 F5「不會繼承」的說法不對**:環境變數一定會被子程序繼承。改名成 `PROV_GATE_SELFTEST_*` 只是避免撞名;同一個 shell 先跑過自測再跑 build,gate 照樣會吃到。現在的 gate 讀 env 的地方是 `:34 GO=${GO:-…}`、`:66 WD=${WBOX_DIR:-…}` ✅。修法(二選一):gate 只在 CLI `--selftest` 時才採用這兩個值;或 `wbox_env_reset`、`local-ab-tar` 呼叫前 `unset`。另加自測案:不在 selftest 模式但 env 有這兩個變數 → 忽略或 FAIL。
- **m9 lint / 推送規則的遺留**:
  - `lint-wbox` 拒絕任何碰 `wbox_image` / §19.3 閘那幾行的 patch(misc-* 本身就改 autocommit,所以要以行為範圍)。
  - `pr_ota_b` 拒絕推 `misc-*` payload:它們只能 bind,不能 OTA。
  - 現在只靠「含 `WBOX-NOCOMMIT` 字串」把關,字串在但閘被改壞的 patch 擋不住。
- **m10 前幾輪遺留的 MINOR,§19 沒提到也沒記成殘項**(逐條處理,或寫進 #254 checklist):
  - L11 負對照的前置「沒有 `.txn`」(A-M3):crash loop 每輪都會起 `restoreWireless`。
  - L3 改用同一 run 的 sysrq 證據(A-m6)。
  - L51 正向寫明「與 L43 對照臂只差第 3 欄」;L38 臂 c 標 characterization(A-m7)。
  - misc 見證 log 行要放在不受 mutant 條件影響的位置,例如 `member:*)` 分支開頭(B-m3);否則 INVALID 與「mutant 無效」分不開。
  - L42 寫入半邊的靜態 lint「`batman-slot` 不出現 `ota-armed.mesh`」,(6a) 標 characterization(B-m5)。
  - §5「(6a) 在 apply 與重開之間死掉」一列(A-m13)。
  - §7 actor 表「我們自己:bind 覆蓋 root 執行的 autocommit、白箱寫 p6」一列(A-m13 / B-m12)。
  - L27 / L10 對 harness 自己的 ssh 與 OTS 的副作用(B-m15)。
- **m11 CI `test-autocommit-wbox.sh` 怎麼 stub `/rom` 沒寫**:
  - 用 sed 改路徑的副本(與 B / 我的沙箱同法),或在 dv-sbx 裡 `unshare -m`;明文禁止在產品加「build 檔路徑」的 env 覆寫(B-m8)。
  - 案例補兩個:「`BATMAN_WBOX=` 行有、值空,且 VER 無 `.wbox-`」→ 非 wbox;「VER 含 `.wbox-` 但無 `BATMAN_WBOX=` 行」→ wbox(第二訊號自己的翻轉)。
- **m12 §19.3 沒寫的路徑與互動**(只缺文件):
  - wbox + `autocommit-hold-once`:`REVERT=0` 且永不 commit,停在 trial 直到重開。這是 fail-secure,寫一句。
  - `release` 對 wbox trial 一定逾時回 1(A-M1 修法 4)。
  - 「會讓某槽變成 committed default」的路徑清單(A-M2):`apply` 只寫 tryboot;fw-override(`:308-318`)不 commit;stale fallback 走同一個 poll 迴圈;`commit` / `rollback` 已擋;ab-selftest、`back_to_a`、chain1 的 rollback 目標都是 A(V)✅(`brewrite-254.sh:13`、`chain1-254.sh:140,217`、`ab-selftest.sh:325`)。只有「root 直接改 autoboot.txt」不擋,屬攻陷 root。
- **m13 §19 的優先序宣告範圍太窄**:標題寫「與 §17、§18 衝突時以本節為準」,但 §19.3 實際上推翻了 §1.4 / §4.2 / §4.3 / §7 的「一律 hold」,也改了 §6.2 的表與 §7 的 actor 表。這些地方的原文都沒改,與 §19 衝突時以誰為準沒有定義。改成「與前文衝突時以本節為準」,或把 §1.4 / §4.2 / §7 的原文就地加註例外。
- **m14 `pr_ota_b` 的 DISCARDED → 「已 committed(mutant 槽)→ `pr_needs_person`」分支**:§18.1 / §19.3 之後,有閘的 wbox image 不會自己 commit,這條分支只剩「閘回歸」才會走到。該處印的 `batman-slot rollback`(從 wbox B 回到 A)仍允許 ✅。§4.2 加註即可。

---

## 對派工具體問題的回答

1. **`hold-consumed` + `TIMEOUT=1` 是否在 `mesh join required` 行後就結束,且不起 watchdog / canary / 真名檔?**
   - ✅ 7 臂都是。原始碼路徑:`:372` `held()` 在 `:96` 命中 `HOLDC` → `REVERT=0` → `:429` 不起 watchdog;`:382-383` `DEADLINE = START` → `:487` 迴圈一輪都不跑 → 不跑 `health_ok` / canary,不寫 `why`。
   - **L38 臂 b**:`:404` 的等待在 deadline 之前,不受影響,實測 uptime 60.04 s ✅。但 §19.1 的 15 s 上限會殺掉它(M1)。
   - ⚠️ 前提是 p6 沒有 hold 旗標(m3),且 `hold-consumed` 真的建在 `RUNDIR`(m2)。
   - ⚠️ 04 的 busybox 行為要等 E-H5 確認;`.config` 與 WSL 是同版本 1.36.1。
2. **L38 臂 a 用 `gate until` 行偵測**:✅ 沙箱可行(4.04 s,改寫後得到 `required: 1 (prov=member …)`)。mutant 情況的判定見 M1 第 3 點。
3. **§19.3 的位置與互動**:
   - 順序寫死 ✅;
   - FIRSTWHY 不搶(只在 `why` 為空時摺入,`:505` 在前)✅;
   - canary 不會在 wbox 時跑,因為 `why` 非空,不進 `:516` ✅;
   - COMMITTED-BY-OPERATOR:`commit` 被擋,所以不會出現 ✅;
   - hold-once 見 m12。
4. **`/rom/etc/batman-build` 與 fail-closed**:健康的 release image 讀不到的情況只有「沒有 `/rom`」的開機(failsafe),那時 autocommit 不跑;fleet 上的證據見 m7(⚠️ 沒上機)。
5. **`cmd_rollback` 讀目標槽**:✅ 可行。`rollback_lock_gate:778-782` 已有「`mktemp -d` → `mount -t squashfs -o ro $(slot_rootdev T)` → 讀 → `umount`」,現在只對 claimed / member 做;改成一律做即可。所有既有的 rollback 呼叫者,目標都是 A(V),不受影響 ✅。
6. **節點單位的副作用與安全網**:見 m4 / m5 / m6。
7. **F5**:見 m8。

## 證據分類

**✅ 實跑或原始碼**
- 沙箱 7 臂、HCmatch / HCother、反向對照、時鐘量測(上面節錄)。
- `batman-autocommit:44,53,62,78,94-106,236-240,270-292,323-326,351,372,376-386,398-437,455,486-516`。
- `batman-slot:77,364-369,735-797`。
- `halow-status:136-146`。
- busybox `.config`、`ps.c:670-689`、`pgrep.c:141`。
- gate `:23,34,66`;`lint-wbox.sh:26,29`。
- harness rollback 呼叫者的行號(m12)。
- `git diff 16a0b0b..18114c7`(1 行)。

**⚠️ 推論或部分**
- 04 上 `/rom` 的實況(只有 harness 的間接證據)。
- 04 busybox 與 WSL 同版本但沒上機。
- `pgrep -s` 不帶 pattern 時的行為沒實跑。

**❌ 沒做**
- 上機。
- `test-autocommit-wbox.sh` / dv-sbx 的 rollback 案(還不存在)。
- §0–§16 未改動的部分沒有逐行重審。前幾輪已兩位 APPROVE;我只抽查了 §1.4、§4.2、§4.3、§6.2、§7、§7.3、§9、§10 與 §19 的一致性。

## 摘要

§19 收掉了 v9 的全部 MAJOR。`hold-consumed` + `AUTOCOMMIT_TIMEOUT=1` 經沙箱 7 臂實證:乾淨、自行結束,不碰真名檔,L38 的 60 s 等待也保留下來。

剩下兩個 MAJOR 都是「寫成程式時會壞」:
1. 結束判定用了 04 上不存在的 `ps -o`,15 s 上限又會殺掉 L38 臂 a / b(M1)。
2. misc 變體名含大寫,與 `lint-wbox` 及 gate 的見證格式衝突;放寬 lint 卻不改 gate,就會出現殘留偵測的盲點(M2)。

MINOR 裡要讓使用者知道的有三點:
- `prov-wbox-nocommit-254` 的成本被低估(約 25 分,實際約 47–57 分),使用者是照低估的數字決定的(m6);
- rollback 臂可能因為別的原因被拒而假 PASS,而且回歸時沒有安全網(m4);
- reason 斷言會被 mesh 抖動誤判(m5)。

修完 M1、M2 後,只需重看 §19.1 與命名,不用再審整份。
