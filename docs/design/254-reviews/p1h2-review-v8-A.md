# 審查 A 第 8 輪:#254 PR-P1 + PR-H2(整份設計、31b4751、afb8f91、E1c v2)

審查者 A,2026-10-21。

**判定:REJECT**:0 BLOCKER / 5 MAJOR / 14 MINOR。
- 產品(31b4751)的第 7 輪修正**都有鑑別力**,沒有 MAJOR,只有 2 個 MINOR(m10、m11)。
- **E1c v2 照現稿不可在 04 上跑**:M1–M5 都是 E1c 的問題。
  - M1:在 mkfs 之前**必定**中止(實機證據)。
  - M2:就算 M1 修好,很可能因為時序競賽而白跑一輪破壞性流程。
  - M4:一條操作失誤路徑會讓 04 停在 committed 的 fresh B 上,而且沒有 dead-man 可以帶它回來。

**讀了哪些東西**:
- 設計:`254-p1-impl.md` 全文,含新增的 §3 三行、§5.4、§13.3、§13.4。
- 產品:`git show 31b4751`,以及該 commit 的 `boot.go`、`batman-slot`、`batman-autocommit`、`platform-ab.sh`、`joinwatch`、`batman-config-save`。
- harness:`afb8f91` 的 `prov-base-254.sh`、`prov-base-statecmp.sh`。
- 草稿:`e1c.sh` v2、`prov-claim-254.sh`。

**真機**:只做唯讀 ssh(04;02 這段期間正在 rollout,一度連不上,之後讀到一次)。用到的指令有 `cat`、`ls`、`pgrep`、`find -maxdepth 0`、`uci show`、`date`,以及一次 64 MiB 的 `dd iflag=direct` **讀取** p5 測速。沒有寫入、沒有重開、沒有印出任何秘密。

**本機**:
- 在 `/tmp/rv8A` 的複本上跑 Go mutant,另外加了 2 個自己寫的測試;
- 在 WSL root 下跑 config-save frozen 測試,以及 statecmp 新舊兩版;
- 跑 autocommit 與 99zz 的 stub 測試,新舊兩版各一次。

工具在 `scratchpad/h2/revA8/`。repo 沒有修改。

## 0. 本輪證據
| # | 事實 | 證據 |
|---|---|---|
| ✅ V1 | 04:`slot=A ver=1.5.12-wsl.11+c1e1c72 trial_rc=1`;prov-state 是 `helper legacy legacy - today`;p6 有 `mesh-expected`、`mesh-joined`、`ota-armed.mesh`(`dceb9f18 B joined`)、`ble-ok`。02 稍後讀到:`ver=1.5.12-wsl.12+31b4751 trial_rc=1 up=64`。rollout 進行中,暫時混版,這是預期的 | ssh |
| ✅ V2 | **04 上 `pgrep -f` 會匹配到自己**:沒有任何 config-save 在跑(`ps w \| grep -c "[b]atman-config-save"` = 0),`pgrep -f batman-config-save \| wc -l` 仍是 **2**,`pgrep -f "sleep 1500" \| wc -l` 也是 **2**。匹配到的是 dropbear 開的 `ash -c` 本身(印出了 `pid 11656: ash -c ps w \| grep …`) | ssh |
| ✅ V3 | 04 時鐘是 `2025-07-17`,02 是 `2026-10-19`(今天是 2026-10-21)。時鐘由 `batman-faketime`(#174,S12 restore / K09 save,存在 p6)維持為**單調的節點時間**;ntpd 在跑,但沒有同步 | `date`、`/etc/init.d/batman-faketime` |
| ✅ V4 | busybox `find -mmin` 可用;`mkfs.ext4`、`setsid`、`mktemp`、`hexdump`、sftp-server 都有;節點上**沒有** `timeout`;`rc.local` 由 `/etc/init.d/done` 以 `sh /etc/rc.local` 同步執行;沒有任何 K 腳本呼叫 config-save | ssh |
| ✅ V5 | p5 direct 讀取:64 MiB 花 1.53 s(約 42 MB/s)。所以 512 MiB 的 sha 約 12 s,讀回也約 12 s;寫入速度沒有測(唯讀限制) | ssh `dd … of=/dev/null iflag=direct` |
| ✅ V6 | Go:`mut7` 的 5 個 mutant 全部 FAIL(persistnow-gen、rc13-gen、txn-readtxn、persistnow-ident、meshexpect-empty),原碼 PASS | `revA8/mut7c.sh` 的輸出 |
| ✅ V7 | autocommit stub 測試:**舊版**(c1e1c72)`claimed:0` 加上 `mesh-joined` 或 `mesh-expected` → NEED_MESH=0;**新版** → 1。99zz:舊版空 key → `0`,新版空 key → `today`,placeholder → `0` | `ex2.sh` |
| ✅ V8 | frozen 測試:舊版 rw 掛載 1→2→3、`M6 RESULT: FAIL`;新版 1→1→1、`PASS`;joinwatch 把 `--on-join` 的輸出丟到 `>/dev/null`(`joinwatch:147`),所以不會洗 log | `ex3.sh` |
| ✅ V9 | statecmp:新版 8/8;舊版(afb8f91^)FAIL 2 項(只差 boot_id、`ota-armed.mesh` 被消耗)→ 負對照有效 | `ex4.sh` |
| ✅ V10 | **compare 在 `/tmp/run/batman-dv` 不存在時是 fail-open**:p5.manifest 確實不同,仍印出 `cannot create /tmp/run/batman-dv/d.1345` 和 `COMPARE t1 x diffs=0`,rc 0。目錄存在時正確印出 `DIFF p5.manifest - file-a / + file-b`、`diffs=2` | `ex4.sh` |
| ✅ V11 | 我新寫的 2 個 Go 測試,在 HEAD 上都 FAIL(見 m10):<br>`TestRv8PersistNowRc10LowersGen` → `rc=0 persisted gen 1 (identity too: true)`;<br>`TestRv8RunRc10IdentityMismatchNotFrozen` → `verdict=claimed`(不是 `unknown(identity-mismatch)`) | `revA8/rv8_test.go` |
| ✅ V12 | 這台 Pi 4 EEPROM 上,plain 的 armed tryboot 可能 no-op | `ab-selftest.sh:233-238`(`warn "raw tryboot no-op on this Pi 4 EEPROM…"`) |
| ✅ V13 | hold:p6 的 flag 在**任何 tryboot 開機**都會被消耗(`batman-autocommit:260-292`);只有在 `want = $(version)` 時才生效,不符 → `HOLD-COMMIT-DISCARDED`。`HELD` 只在健康判定的 dwell 過了之後才記(`:506-513`)。`release` 要求 trial、main 存活、未過 deadline(`:151-176`) | 讀碼 |
| ✅ V14 | stage 2 少了 `prov-lock.sh` 時,`node_checks` 的條件是 `[ -r …prov-lock.sh ] && …`(`batman-slot:549`)→ 失敗 → 在 `begin_write` **之前** die → `ota_s2_explicit_restart_if_not_armed` 重開到 [all]。所以鏈 1 第 7.1 步的負對照是有鑑別力的 | 讀碼 |

---

## MAJOR(全部是 E1c v2)

### M1. `pgrep -f` 會匹配到自己:p5 busy 檢查**一定**判 busy,E1c 在 mkfs 前就中止;dead-man 的 `timer≥1` 讀回也因此沒有鑑別力
- **證據**:V2。`e1c.sh:87` 的遠端指令是 `pgrep -f batman-config-save | wc -l`,dropbear 的 `ash -c "<整條指令>"` 本身就含這個字串 → 至少 1。所以 `:88` 的 `[ "$(echo $o)" = "0 0" ]` 永遠不成立 → `FAIL p5 busy` → exit。
- **同一個 bug 的第二處**:`:121` 的 `timer=$(pgrep -f 'sleep 1500' | wc -l)` 同樣匹配到自己。§13.3 第 5 步宣稱的「讀回 `timer≥1`」等於沒有證據。trial 裡那個 timer 撐不撐得過 ssh session 結束,⚠️ 目前沒有任何驗證。
- **後果**:04 不會受損,中止點在 mkfs 之前。但 snap 已經做了,留下:
  - `dv-prov-dirty`、A overlay 的標記、`$D`、`payload-e1c`;
  - 下一次 snap 會因為 dirty flag 直接 die,需要人清理。

  這是浪費一輪 04 + OTS 的停機時間,而且這個問題在桌上就能抓到。
- **修正**:
  - 改用 `pgrep -f '[b]atman-config-save'`,或者直接列 `/proc/*/cmdline` 並排除 `$$`;
  - timer 改成 `setsid sh -c 'sleep 1500; …' & echo $!`,讀回時以 `/proc/<pid>/cmdline` 驗證;
  - **E1c 先做一次「乾跑」**:跑到 mkfs 之前就停,再 `finish`。這樣 precondition、snap、dead-man 寫入、busy 檢查都在 04 上驗過,而且不破壞任何東西。

### M2. `HELD` 只在「找到 B」的那一刻讀一次:找到的時間通常早於 HELD → 判讀失敗 → 白跑一輪破壞性流程
- **證據**:
  - `:102-111`:每輪先 `sleep 10`,再掃描,找到就立刻讀一次 `logread | … | tail -12`;
  - `:115`:沒有 `HELD` 就判 `dec=bad` → `:124` `abort_to_a`;
  - E1a:fresh trial 約 83 s 可達;
  - E3(非 fresh 的 B):開機到 `HELD` 是 92–105 s;
  - 而 HELD 要等健康 dwell 過了才記(V13)。fresh 第一次開機還要跑 uci-defaults、產生 key、啟動 OTS 的兩個 docker tenant,只會更晚。⚠️ 推估。

  依 `:102` 的節奏,「找到」大約落在 B uptime 75–90 s,早於 HELD。另外 `tail -12` 也可能把 `mesh join required` 那一行切掉。
- **後果**:abort_to_a → 回到 A,但這時 p5 已經是 B 寫入的身分 Y → A 凍住(見 M5)。這一輪的破壞性操作就白做了。
- **修正**:
  - 找到之後,**輪詢**,直到出現 `HELD`、`HOLD-COMMIT-DISCARDED` 或 `UNHEALTHY`;以 B 的 uptime 設上限(例如 ≤ 140 s);
  - 用 `logread -e batman-autocommit`,或 grep 完整的 log,不要用 `tail -12`;
  - 把「開機到 HELD」的實測值寫進報告(F34 的時間窗)。

### M3. 仍然用 plain `reboot` 重開 armed 的 tryboot,沒有落點斷言,也沒有 disarm;§13.4 卻寫「A-m1 / B-m2 已改進」
- **證據**:
  - `:98` `(sleep 2; reboot)`;
  - V12:這台 EEPROM 在這條路徑上可能 no-op;
  - §4.5.0 規定的是「停 docker / OTS → `sync` → `reboot -f`」,§13.3 第 3 步也寫「受控重開」;
  - 程式裡沒有任何「10.41.1.3 以新的 boot_id 回應 → 落點落空」的判斷。
- **落空時的路徑**(逐步追):
  1. A 帶著 mkfs 過的 p5 開機:A 的 helper rc 7 → 把 overlay 的身分 persist 進 p5;joinwatch 開機時自動起來 → `--on-join` 把 A 的設定寫進 p5,並建 `.seeded`。
  2. `:102` 只掃 `10.41.254.x`,掃滿 150 s → `abort_to_a`(FIP 是空的)→ 在 A 上 p5-restore、刪 hold → exit → cleanup 在 A 上取消 dead-man。
  3. **tryboot 仍然 armed(沒有 disarm)**。⚠️ no-op 之後旗標會不會保留,沒有實證。如果保留:下一次任何原因的重開都會進入一個沒有 hold 的 B trial,從 p5 建起 → 健康就 commit B → 04 不聲不響地移到 B。
  4. 報告會寫「held fresh trial not found」,把落點問題誤記成事實 3(找不找得到)的 ❓。
- **修正**:
  - 照 §4.5.0 做受控的 `reboot -f`(先停 docker / OTS、`sync`、p5 / p6 卸載或 remount ro);
  - 重開後先問 10.41.1.3:如果是新 boot_id 而且 `slot=A` → 判「落點落空」→ 以 vcmailbox 讀 tryboot 旗標,armed 就 disarm 並讀回 → p5-restore → FAIL「landing」;
  - §13.4 的處置表照實改寫(目前寫成已修,實際沒修)。

### M4. 沒有斷言 payload 的版本 = VEXP:hold 被 DISCARDED → unclaimed 的 B 自己 commit,`is_b` 只接受 `trial_rc=0`,所以永遠找不到;cleanup 謊稱「dead-man stays ARMED」→ 04 停在 committed 的 fresh B 上,沒有自動回復
- **證據**:
  - `:59` 只斷言 **A** 是 VEXP;`:60` 只驗 payload 的 sha;
  - hold 寫的是 VEXP(`:92`),只在 `want = $(version)` 時生效(V13);
  - payload 的 `metadata` 本身就有 `version=`(`platform-ab.sh:11`),卻沒有比對。
- **情境**:VEXP 與 payload 不一致(我們自己的錯,例如重新 build 過、`+hash` 不同),依序發生:
  1. B 的 trial 判 `HOLD-COMMIT-DISCARDED`,`unclaimed:*` → NEED_MESH=0,約 95–105 s **自己 commit**;
  2. `:104` 的 `is_b … "trial_rc=0 "` 不接受已經 commit 的 B → 150 s 後 `abort_to_a`,而這時 FIP 是空的;
  3. 等 900 s 的 `slot=A`:A 不會回來,因為 B 已經 committed,openmanetd 會把它重開到保留位址;
  4. 印出「needs a person」→ exit;
  5. cleanup 看到 `STAGED=1` 就印「**dead-man stays ARMED (fires <=25 min…)**」。這是錯的:B 的 rc.local **從來沒有被種下**。
  
  結果:04 停在 committed、unclaimed、位址不明的 B 上;02 被隔離;OTS 停擺;只能靠人用 `none` 經 eth 找回來。這正是第 7 輪 M1 的困住路徑,現在換成由操作失誤觸發。
- **修正**:
  - 前置條件加上 `sed -n 's/^version=//p' $PDIR/metadata` == VEXP == A 的 `BATMAN_VERSION`;
  - 掃描時也接受 `slot=B trial_rc=1`:一旦看到「B 已經 commit,但 dead-man 沒有種」,立刻在 B 上種 dead-man,或直接 rollback;
  - cleanup 的訊息依 `PLANTED`(rc.local 讀回成功)判斷,不要依 `STAGED`。

### M5. `abort_to_a` 回到 A 之後的狀態不是 S0,而且沒有驗證:p5-restore 的結果沒有檢查;A 帶著凍住的 verdict,helper 停著,joinwatch 被 FROZEN 標記跳過
- **追蹤**(abort 一定發生在 B 開過機之後:B 的 helper rc 7 → 產生身分 Y → `--prov-only` 寫進 p5):
  1. A 回來時,p5 是「unclaimed、身分 Y」,overlay 是 X → `unknown(identity-mismatch)`。這次開機內固定(§3 B-m10)。joinwatch 的第一個 tick 寫下 `cfgsave-frozen`,之後一直跳過。
  2. `:41`:`q "… p5-restore …" | tail -1`,在 `timeout 120` 底下**同步**執行,而且**不檢查** `P5-RESTORED`。p5-restore 包括:
     - 先讀 512 MiB 驗 sha(約 12 s,V5);
     - 寫入 512 MiB 加 fsync(寫入速度未測);
     - direct 讀回(約 12 s);
     - 如果 lock busy,`lock_take` 最多再等 30 s。
     
     有可能超過 120 s,不過 ⚠️ 這是推估。
  3. `p5-restore` 會 `svc stop joinwatch batman-provhelper batman-provd`(`prov-base-254.sh:176`);cleanup 只重啟 joinwatch → **helper 一直停到下次重開**。joinwatch 也因為 FROZEN 標記照樣跳過。
  4. 結果:P9(helper state ∈ {legacy})與 dirty flag 會擋下一次 run;報告只有 `ABORT … RESULT: FAIL`,沒有寫出這些狀態。

  M2 讓 abort 很可能真的發生,所以這條路徑一定會走到。
- **修正**:abort_to_a 回到 A 之後要做:
  1. 以 detached(setsid)執行 p5-restore,把結果寫進 p6 log;
  2. 讀 log,斷言 `P5-RESTORED <run> sha=<SNAPSHA>`;
  3. `batman-slot reboot committed`;
  4. 斷言 prov-state = `helper legacy legacy`、`--check` rc 0、沒有 bad-slot、helper 在跑;
  5. 任何一項失敗都明確印出「04 不在 S0,原因 …,需要人處理」。

  §13.3 的「trial 內的失敗出口」與「副作用」段要寫出 A 會暫時凍住,以及可能留下 `bad-slot`(m4)。

---

## MINOR
- **m1 dead-man 的 one-shot 在動作之前就設好**(`:75` 先 `: > e1c.fired`):
  - 如果在 p5-restore 或 rollback 期間斷電,就永遠不會重試 → 04 停在 committed 的 B,p5 可能只寫了一半;
  - host 接著會印「dead-man stays ARMED」,這也是錯的。
  - **修正**:改成「嘗試次數 ≤ 2」,每一步都冪等(p5-restore 與 rollback 本來就冪等);`fired` 在 rollback 成功之後才寫。
- **m2 dead-man 的 6 h 期限用的是節點時間**(V3,batman-faketime #174),不是實際時間,而且只在開機時前進。這個行為可以接受,但:
  - §3 要寫明;
  - 「FAIL 而且 A 沒確認」的出口要靠 brewrite 移除 rc.local 那一行。在那之前,只要在 6 h 的節點時間內開進那份 B overlay(例如 ab-selftest 的 raw tryboot),dead-man 就會拿 E1c 的舊快照蓋掉 p5。
  - **建議**:額外綁定開機次數(snap 時記下 `boot-reasons.log` 的行數,超過 +3 就不動作)。
- **m3 apply 之後的 FAIL 出口沒有 disarm**:
  - `:96`(p5 不是 unseeded):沒有 p5-restore,也沒有 disarm,只刪了 hold → 下一次重開進入沒有 hold 的 fresh B trial;
  - `:94`(apply 沒有印出 armed):p5-restore 了,但沒有用 vcmailbox 確認 tryboot 沒被 arm。
  
  這兩個出口都要做:p5-restore + disarm + 讀回。
- **m4 abort 時如果 FIP 是空的,B 的 HELD trial 可能要等 deadline 才 revert** → watchdog 會寫 `bad-slot=B`。abort 之後沒有清,也沒有判 FAIL 原因;cleanup 仍然判「A committed」→ S0 不成立,卻沒有說明。
- **m5「找到」的範圍**:
  - commit 之後的保留位址可能在整個 /16(03 曾經是 10.41.7.57),sweep 只掃 10.41.1.x 和 10.41.254.x;
  - `MDNS` 寫死,沒有使用 trial 裡讀到的 hostname(§13.1 的 ⚠️ 仍未解);
  - **建議**:在 B 的 rc.local 加一行 `ping -c1 10.41.240.10`,讓主機的 ARP 表直接學到 B 的 IP 與 MAC,再以 `is_b` 確認。
- **m6 沒有取得 prov lease,也沒有取得主機端的 orchestrator 互斥鎖**(第 7 輪 B-m5 沒處理)。daily-validation 或 H1 的 BLE 套件如果同時跑,會一起動到 04。
- **m7 TOCTOU**:「busy 檢查 → mkfs → apply → unseeded 斷言」整段沒有拿 `cfgsave.lock`。應該比照 `prov-base` 的 `lock_take`,持鎖跑完整段。
- **m8 §3 寫「`finish` 刪 p6 檔」,不正確**:`finish` 只刪 `$D`、標記、dirty flag(`prov-base-254.sh:204-207`)。`$BASE/e1c-deadman.sh`、`e1c.cancel`、`e1c.fired`、`e1c-deadman.log`、`payload-e1c/` 都會留下。
- **m9 §13.3 沒有寫明 `FRESHO` 的信任界線**:`StrictHostKeyChecking=no` 加 `none` 登入,意思是任何回應那個 IP、而且印出 `slot=B` 的主機,都會收到 rollback / dead-man 指令。實驗室可以接受,但要寫明(第 7 輪 m4)。
- **m10(產品)`--prov-get` 回 rc 10 時什麼都不複製**(`batman-config-save` 的 `prov corrupt` 分支在 `cp` 之前就 `exit 10`):
  - (a)`boot.Run` 在 rc 10 看不到 p5 的身分 → identity mismatch 不成立 → verdict 是 overlay 的 state,不是 `unknown(identity-mismatch)`。寫入被 config-save 的 `identity_mismatch` 擋下,所以沒有寫出混合狀態,但 P-U6 的 verdict 契約不成立(V11)。
  - (b)`PersistNow` 的「a generation is never lowered」在 rc 10 時不成立:commit 順序是先 cbor 後 meta,斷電就會落在 rc 10。這時 legacy gen 1 會蓋過 p5 上的 claimed gen 5(V11;`boot.Run` 的 case 10 也一樣)。這需要兩個故障同時發生(斷電加上換槽),所以列 MINOR。
  - (c)`boot_test.go` 的 fake `GetP5` 不管 rc 都會複製檔案,和實際的 `--prov-get` 不同,所以這個洞被測試蓋住了。
  - **修正**:rc 10 時複製 `prov.cbor` 與 `identity/`(標成不可信),gen / identity 的比較照做;fake 依 rc 照實模擬。
- **m11 shell 修正的回歸測試只在 scratchpad**:frozen 標記、autocommit 的 marker 規則、99zz,都不在 repo 裡。§13.4 只把 A-m6 列進 H2。依規則,這些都要進 `prov-unit-cfgsave` / `prov-unit-96` / 沙箱。另外 `sanity_frozen_m6.sh` 用 `grep -vc ro` 計 rw 掛載很脆弱:mktemp 的路徑可能剛好含有 `ro`。
- **m12(harness)`compare` fail-open**(V10):
  - `$T` 不存在時,集合差的輸出寫不出去 → `diffs=0`;
  - `PROV_BASE_TEST_ROOT` 沒有重導 `T`、`MARK`、`LOCK`;
  - `prov-base-statecmp.sh` 跑的時候 `$T` 不存在,所以它的 manifest 部分是空的,不算有測。
  - **修正**:`mkdir -p "$T"`,寫失敗就 FAIL;測試補一個「manifest 真的不同 → DIFF」的案例。
- **m13 `prov-claim` 草稿**(第 7 輪 m8 的殘項):
  - canary 只查 `claim.secret` 的 hex 前綴,而且這個前綴被帶回主機;沒有涵蓋 §4.2 列的其他秘密,也沒有 base64;
  - `overlay-restore` 和重開仍然分在兩條 ssh;
  - §5.3 的 killpoint replay、`no-ssh-key`、bind mount 負對照仍然缺。
  
  publickey 的前置檢查已經加上(`:32-33`)✅。
- **m14 鏈 1(§5.4)第 7 步之後的失敗出口不成立**:
  - 第 7 步會把 A 重寫成從 p5 建起的 overlay(身分 Y)。之後 §13.3 的 `abort_to_a`(在 A 上 p5-restore)只會讓 A 凍住;
  - 「A 的 overlay 一直完好、有 lab key」這個前提,在第 7 步之後就不成立了。
  - 第 7 步之後需要自己的出口:回到 committed 的 B → 類別 R 的還原。另外鏈 1 第 4 步寫的是「受控重開」,E1c 卻用 plain reboot(M3),兩邊不一致。
  - 這要在實作鏈 1 之前寫清楚。

---

## 第 7 輪處置的查核(對照程式碼)
| 第 7 輪 | §13.4 的說法 | 本輪結論 |
|---|---|---|
| A-M7 / B-M2 mesh_expect fail-open | 31b4751 | ✅ V6、V7。多個 mesh 介面的差異(B-m8):04 / 02 各只有 1 個 mesh 介面(`uci show` 數過),可以接受 |
| A-M6 凍住時每 tick 都掛載 | FROZEN 標記 | ✅ V8;沒有 log 洗版(`joinwatch:147` 丟到 `/dev/null`);測試沒進 repo(m11) |
| B-M3 `--persist-now` | `boot.PersistNow` | ✅ mutant(V6);不再跑 `boot.Run`,也不動 `.stage` / prov-state(測試有斷言)。rc 10 的洞見 m10 |
| B-m9 rc 13 的 gen 條件 | `TestRc13SameSnOlderGen` | ✅ V6 |
| A-m10 / B-m7 提示文字 | 已改 | ✅ 讀 diff 確認 |
| B-M6 S0 比對 | afb8f91 | ✅ V9;fail-open 見 m12 |
| A-M1(E1c 先 hold) | v2 | ⚠️ 有 hold,但沒有版本斷言 → M4 |
| A-M2 / B-m1「找到」的判定 | `is_b` | ✅ ping + ssh 讀 slot + boot_id;但 commit 之後只接受 `trial_rc=1`,trial 中只接受 `trial_rc=0`(M4) |
| A-M3 restore 改 detached | v2 | ⚠️ 成功路徑 ✅;abort 路徑仍是同步、不檢查(M5) |
| A-M4 / B-M5 不比映像 sha | `P5-RESTORED` 那一行 | ✅ |
| A-M5 §13.3 重寫 | 已改 | ⚠️ 前置條件少了 payload 版本;副作用少了 A 凍住、helper 停止、bad-slot |
| A-m1 / B-m2 落點斷言 + 受控重開 | 「全部改進」 | ❌ 沒做(M3) |
| A-m2 dead-man one-shot / 期限 | v2 | ⚠️ one-shot 的位置不對(m1);期限是節點時間(m2) |
| A-m3 報告的真實性 | v2 | ✅ 改成連續 3 次失敗才判離線、斷言決策行;`shutdown_*.log` 沒有用上 |
| A-m4 | v2 | ✅ 先驗 sha 才解壓、印出還原指令;FRESHO 沒有寫明(m9) |
| B-m3 版本 | VEXP | ⚠️ 只驗 A(M4) |
| B-m5 lease / 02 | 02 的前置 ✅ | lease ❌(m6) |
| B-m6 mktemp | ✅ | — |
| A-m7 §5.4 改寫 | 已改 | ✅;第 7 步之後的出口見 m14 |
| A-m9 F13 | ✅ | — |
| B-m10 §3 verdict 整次開機固定 | ✅ | — |

## 確認成立
- 31b4751 的四項產品修正都有負對照,而且我重跑過(V6–V8)。
- E1c **成功路徑**的程式邏輯成立(前提是 M1、M2 修好):
  - hold 生效 → 先種 dead-man 再 release;
  - commit 之後以 `is_b` 加新的 boot_id 確認;
  - dead-man 以 setsid 執行,p5-restore 失敗仍然 rollback;
  - 回到 A 後斷言 legacy、`--check` rc 0、02 committed。
  
  `batman-slot rollback` 在 committed 的 B 上寫 [all]=A;`reboot committed` 在 tryboot 旗標已清的情況下走 explicit(`batman-slot:740-780`)。
- dead-man 的資源權限:p6 的 `dv-prov` 在 snap 時 chmod 700;容器只掛 docker volumes;uid 471 碰不到。
- 鏈 1 第 7.1 步的負對照有鑑別力(V14)。

## 判定
**REJECT**(0 / 5 / 14)。

- **產品**:可以進 rc。m10、m11 併入 H2 / 下一個 commit。
- **E1c**:修完 M1–M5 之後,**先在 04 做一次不破壞的乾跑**(跑到 mkfs 之前,然後 `finish`),再交給兩位審查者看 v3 的 diff 與乾跑 log,之後才做真正的 E1c。
