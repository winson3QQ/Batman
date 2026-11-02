# Review A(第 7 輪)— `254-stage1-impl.md` v7(+ v4/v5/v6 中標「同 v4」「同 v5」「同 v6」的各節)

審查者 A,獨立、對抗式。審查對象:branch `design/254-stage1-impl` @ c2e6b88 的 v7,與 v7 引用的 `254-reviews/254-stage1-impl-v{4,5,6}.md` 合起來當作一份設計。依使用者 CLAUDE.md 的設計審查規則。使用者已定案的事項(擁有權與 SSH 脫鉤、恢復出廠全清含身分、Go/Flutter+Rust、3A+ 延後、`uart_enable`、改名探針、Q5 = L16 在 04、Q6 = 04 已有 lab key)不重開,只在 §6 列後果。沒有讀 reviewer B 的本輪報告。

**證據來源(全部唯讀,2026-10-19)**
- 原始碼(main f2f2bf6 = branch):`95-batman-storage` 全文(含 INITBODY `boot()`、`fw_override_check`、`restore_payload_guardians`)、`96-batman-config-migrate:55-110`、`batman-config-save`(rc 表、lock、mkfs、rate-limit)、`platform-ab.sh:55-200`、`99-batman-payload-docker`。
- firmware-2710:`package/base-files/files/sbin/sysupgrade:355-440`;fstools `jffs2reset.c:44-140`、`libfstools/overlay.c`(`handle_rmdir`、`foreachdir`、`mount_overlay` 狀態機 `:420-470`)、`libfstools/find.c:103`(`find_mount_point` 用 mountinfo 的 major:minor)、`libfstools/rootdisk.c:155,222`、`mount_root.c:30-125`;procd `rcS.c:197-203`、`state.c:155-235`。
- 04、02:`command -v`、`mount`、`/proc/cmdline`、`ls -la /overlay`、`.fs_state`、`uci show dropbear`、`/etc/shadow` root 欄、RUNDIR 內容、`batman-slot active/is-trial`。
- **沒有任何寫入**;沒 reboot、沒 jffs2reset、沒 mkfs、沒跑 config-save 寫入模式、沒跑 bluetoothctl。

---

## 0. 總評

v7 對 B6-M1/B6-M2 的修法方向是對的:正面哨兵取代「是不是 95 呼叫」、attempts 寫不進就停、停住不掛舊 p6、有意圖就上鎖。我照實際路徑重走了 v6 的兩條 MAJOR 情境,在 v7 下都不再成立。

但「哨兵不在 ⇔ overlay 已清」這條等價,v7 自己就有一個寫者會打破它:**撤銷會刪哨兵,而 F3 的「失敗」不等於「意圖沒寫進去」**。`--reset-intent` 在 rename + sync 之後才 umount、ro 重掛讀回;這之後的任何失敗都回 rc 1,helper 照表撤銷(刪哨兵、刪 marker),但 p5 上的意圖可能已經落盤。下一次開機:意圖在、哨兵不在 → W1/W2 把 p6、p5 格式化,overlay 卻沒清。這會掉資料,也會留下半套重置 → **MAJOR(A7-M1)**。修法是局部的(三態結果 + 只有確定沒寫才撤銷),不需要新機制。

另外三條是同一個等價在別的路徑上不成立,但觸發窄,列 MINOR(必須帶進 PR-P1):tmpfs overlay(m1)、jffs2reset 之後 helper 掛掉(m2)、Wa 的回退靠錯了函式(m3)。

---

## 1. 先補:矩陣缺的列、擁有權缺的資源

| 缺的路徑 / 資源 | 為什麼要有 | 對應 |
|---|---|---|
| **F3 回非 0,但意圖已落盤**(rename+sync 之後 umount / ro 重掛 / 讀回失敗,或 helper 逾時殺掉 config-save) | 撤銷會刪哨兵 → 下次開機 W1/W2 在沒清的 overlay 上完成 | M1 |
| **開機落在 tmpfs overlay**(f2fs overlay 掛不起,`mount_root` 退回 ramoverlay;96 `:79` 記載過 Build #2 實際發生) | 每次開機都是 fresh、哨兵永遠不在 | m1 |
| **F4 的 jffs2reset 之後、F5 之前 helper crash / respawn** | 哨兵已被 overlay_delete 刪掉,v7 的 respawn 規則只列了「哨兵還在」 | m2 |
| **Wa 開進的是 tryboot trial** | `fw_override_check` 在 `tb != 0` 時直接 return(`95:449-452`),不會修正 | m3 |
| **95 在建 INIT 之前就 exit 0**(`:86`、`:95-101`、`:106`、`:124-128`) | 這個 overlay 從此沒有 `batdata-mount`,W 永遠不會跑 | m12 |
| 執行期 `/etc/init.d/batdata-mount start/restart`(`start(){ boot; }`,`95:728`) | W 在閂之前,執行期也會跑 W0(A6-m8 要求寫明,v7 沒寫) | m12 |
| 資源:**p5 `.factory-reset` 的 W0 寫入沒有取 `cfgsave.lock`** | 執行期 W0 與 F3 讀回可以同時發生 | m6 |
| 資源:**p6 沒掛時寫到 `/opt/batdata/...` 的檔**(99zz prov-state、helper ble-ok/health、dockerd data-root、marker 檢查) | 卡住的狀態下 p6 不掛,這些路徑落在 overlay 的空目錄 | m9 |

---

## 2. Findings

### MAJOR

**A7-M1. F3 的「失敗」不等於「意圖沒寫進去」:撤銷刪掉哨兵後,下次開機會在沒清的 overlay 上把 p6、p5 格式化(掉資料 + 半套重置)**

- **情境**(使用者情境「p5 正在壞的節點」):
  1. 擁有者在 app 按恢復出廠。F1–F2b 正常。
  2. F3:`--reset-intent` rw 掛 p5 → 寫 tmp → rename → sync → umount → **ro 重掛讀回失敗**(卡片讀錯、EIO,或讀回內容不符)→ rc 1。另一種:helper 的 Go 實作給子程序設逾時,在 rename 之後殺掉 config-save。
  3. helper 照 §4.5 F3 列「其他 rc → 撤銷、`E_RESET(p5-unwritable)`」:改回 `apps/` → **刪哨兵** → 刪 marker → 重啟 dockerd、guardian、joinwatch。app 顯示「設定區寫不進去,請換卡」。
  4. 但 p5 上已經有一份格式正確的意圖(rename + sync 已完成)。執行期的症狀:config-save 的寫入模式全部 rc 1(§4.3「`.factory-reset` 存在 → 拒寫」),`--prov-get` rc 15,precheck-node 拒絕 OTA。節點表面上回到原狀,實際上已經凍結。
  5. 下一次開機(任何原因):`boot()` 讀到意圖,slot 相符,格式正確,**哨兵不在** → 依 v7 的定義「哨兵不存在(overlay 已清)」→ W1 mkfs p6(OTS DB、docker volumes、`apps/`,04 實測都在 p6)→ W2 mkfs p5。
  6. 但 overlay 沒清:舊的 `/etc/batman-prov/identity`、`prov.cbor`(claimed/member)、`authorized_keys`、shadow、wireless key 都還在。helper `--boot`:p5 rc 7(空)+ overlay 有身分 → 依 v4 rc 7 規則沿用 / persist → 舊身分、舊擁有權寫回新的 p5。
- **結果**:
  - 使用者被告知「重置沒做」,下一次重開卻失去整個 p6(tenant 資料),而且沒有任何提示 → **掉資料**。
  - 結果是半套重置:p5/p6 清了,身分、擁有權、SSH 授權留著。如果擁有者以為「失敗了、沒動到」就照常轉賣或交接,前任的 `authorized_keys` 仍然有效(U3:認領不碰 `authorized_keys`)。
- **證據**:
  - §4.3 `--reset-intent`:「寫 `.factory-reset`(tmp + rename)→ sync → umount → **ro 重掛讀回**內容相同才 rc 0;否則 rc 1」。rename 之後的每一步失敗都是 rc 1,與「根本沒寫」同一個 rc。
  - §4.5 F3 列:「其他 rc → 撤銷」;撤銷段:「…→ 刪哨兵 → 刪 marker」。
  - §3 哨兵列:「**消失**只靠 overlay 被清(F4 的 jffs2reset 或 W0)」。這和撤銷段互相矛盾,而 W1 的進入條件正是哨兵不在。
  - W1 的條件只看「哨兵不存在」,不比對 nonce,也不看 p6 marker(W1 時 marker 本來就可能已被清)。
  - v6 的負對照 (d)「F3 白箱讓 p5 唯讀」只測 rw 掛不起(根本沒寫),測不到這條。
- **修法**(不需要新機制):
  - (a) `--reset-intent` 的結果改成三態:rc 0 = 已寫且讀回相同;rc 1 = **確定沒寫**(前提不符、rw 掛不起、寫 tmp 失敗,或 rename 之後失敗但已成功 `rm` 意圖並 sync,再 ro 讀回確認不存在);新 rc(例如 9)= **不確定**。
  - (b) helper:只有 rc 1(確定沒寫)才撤銷。rc 9、被殺、逾時、或任何未知 → **一律當作已提交**:不刪哨兵、不刪 marker,繼續 F4/F5(F4 失敗也不要緊,哨兵在 → 下次開機 W0 會清 overlay)。如果 p5 讀不回,就落到既有的「F3 之後 p5 壞掉」雙重故障殘項,不會變成半套重置。
  - (c) helper 在 respawn 判定時(§4.5「helper 在執行期 crash」)也要用同一條規則:marker step=3 而 p5 意圖**讀不到**(EIO)≠「沒有意圖」→ 當作已提交,不回 `resetting-pending`。
  - (d) §3 哨兵列寫明第二個刪除者(撤銷),以及它的前提「p5 確定沒有意圖」。
- **負對照**:白箱 seam 讓 `--reset-intent` 在 rename+sync 之後的 ro 讀回回失敗 → 斷言 helper 不刪哨兵、不刪 marker、節點重開後走 W0 → 完整重置(UUID 都換、overlay 沒有舊身分)。照 v7 字面:哨兵被刪,下次開機 p6/p5 被格式化,而 `/etc/batman-prov/identity` 舊檔還在(FAIL)。

### MINOR

**A7-m1. tmpfs overlay(ramoverlay)上「哨兵不在 ⇔ overlay 已清」不成立** — **PR-P1 必帶**
- **證據**:fstools `mount_root.c:63-79`:沒有 f2fs magic 或 deadc0de 時,`ramoverlay()`;96 `:79` 的註解記載 Build #2 實際發生過:f2fs overlay 損壞 →「mount_root fell back to a tmpfs overlay」。tmpfs overlay 每次開機都是空的 → 95 每次都跑,哨兵永遠不在。
- **情境**:F3 之後、F4 刪檔時斷電,f2fs 損壞(刪大量檔時斷電本來就是 f2fs 最可能壞的時機)→ 下次開機落在 tmpfs → 意圖在、哨兵不在 → W1/W2 完成,`factory-reset.log` 寫 completed。但磁碟上的 f2fs overlay(前任的身分、`authorized_keys`、shadow、key)從頭到尾沒被清,只是掛不起來。如果之後它又掛得起來,舊的 overlay 就回來了。
- 執行期也一樣:節點如果正跑在 tmpfs overlay 上,F1 的哨兵寫在 RAM,F4 清的是 RAM。
- **修法**:前置條件加「`/overlay` 是持久的 f2fs(`mount` 的 fstype ≠ tmpfs)」;W1 進入條件也加同一條。不成立就 crit `reset-overlay-not-persistent`,不清(上鎖由 96 處理;tmpfs overlay 每次都 fresh,96 每次都會跑)。另外,哨兵檢查要直接看 `/overlay/upper/etc/batman-reset.sentinel`,不要看合併後的 `/etc/...`:rom 若意外帶了同名檔,會變成永遠「沒清」。
- **負對照**:白箱讓 `/overlay` 是 tmpfs,p5 放一份正確意圖 → 斷言 p6/p5 UUID 都不變、有 crit。照 v7 字面:兩者都被格式化(FAIL)。

**A7-m2. jffs2reset 之後、F5 之前 helper 掛掉:v7 的 respawn 規則沒有這一格;這個窗口裡 overlay 已在線上清空,`root:::` 會浮出來** — **PR-P1 必帶**
- **證據**:
  - `jffs2reset.c:44-55`:overlay 掛載中 → `fs_state_set(PENDING)` + `overlay_delete(mp)` 立即 unlink upper 的檔(`overlay.c handle_rmdir`),**不會自動重開**(沒給 `-r`)。
  - v7 §4.5 respawn 規則只列「marker 在、p5 無意圖」與「marker 在、p5 有意圖、**哨兵還在**」。jffs2reset 之後哨兵已經沒了 → 沒有對應的規則。
  - 04/02 實測:rom 預設 `root:::0:999`,`dropbear.main.PasswordAuth='on'`、`RootPasswordAuth='on'`,R70 也證明空密碼登入可用。
- **情境**:helper 在 jffs2reset 回來之後、`reboot` 之前被 OOM 或 crash 殺掉,procd respawn。新的 helper 看到 marker + 意圖 + 沒有哨兵 → 沒有規則可套,很可能判成 `resetting`、只開 status,不重開。這時合併後的 `/etc/shadow`、`/etc/config/dropbear` 已經是 rom 版本。dropbear 一旦 reload(OpenWrt 的 dropbear 有 interface reload trigger,mesh 抖一下就會觸發),就會用 `PasswordAuth on` 加空密碼 root 跑起來,而 p5 還留著前任的全部秘密。觸發窗口很窄,但一旦卡住,會一直維持到有人拔電。
- **修法**:
  - respawn 規則改成「marker + 意圖 + slot == 本槽 → 一律(冪等)F4 + F5,不看哨兵」。
  - F4 的 jffs2reset 改用 `-y -r`(fstools 自己 `sync; reboot(RB_AUTOBOOT)`,不經過 helper)。代價是沒有 clean shutdown,但 p6 本來就要 mkfs,p5 在 F3 已經 umount。
  - 要寫明:這條規則**不能**繞過 W0 的 attempts 上限。W0 卡住時 p6 不掛,helper 看不到 marker,所以今天不會繞過;但這是隱性耦合,要寫成明確條件(例如 `$RUNDIR/reset-stuck` 存在 → helper 不續做)。
- **負對照**:白箱在 jffs2reset 回來之後 `kill -9` helper → 斷言 ≤ 30 s 內重開,下次開機完成重置。照 v7 字面:沒有定義,實作很可能停住(FAIL)。

**A7-m3. Wa「讓 `fw_override_check` 修正槽」只對 EEPROM 開錯槽成立;開進 tryboot trial 時它不動作,autocommit 也沒有「有意圖 → 不 commit」** — **PR-P1 必帶**
- **證據**:
  - `95:445-452`:`tb != 0`(trial)時 `return 0`,不修正。
  - `95:460-465`:fresh 開機時(uci-defaults 還在)延到 autocommit 處理。
  - v7 §6.4 / v5 §6.4 的 `expected_in_mesh()` 與 `health_ok()` 都沒有看意圖。A6-m1 的修法 (a) 原本有「autocommit 加一條:p5 有意圖 → 不 commit」,v7 §13 沒有收進來。
- **情境**:F3 之後有人用 `sysupgrade -F` 寫入另一槽(v7 把它列為「`-F` 例外」)→ trial → Wa:不清、照常掛 p6(`apps/` 已改名、marker 在 → tenant 不會起來)、96 上鎖。這時如果 autocommit commit 了 trial,意圖的 slot 就永遠對不上 → 節點永遠停在 `resetting`(只開 status/public),前任的 p5/p6 都還在,只能重燒卡。
- **修法**:
  - autocommit:p5 有意圖(用共用解析函式讀;讀不到也算)→ 不 commit,一律 revert。
  - 或者 helper:marker + 意圖 + slot ≠ 本槽 → 直接 reboot(tryboot 是一次性的,重開就回到意圖槽 → 哨兵在 → W0)。
  - Wa 的文字改成「trial → autocommit revert;非 trial 的開錯槽 → `fw_override_check`」。
- **負對照**:白箱在 trial 槽放一份 slot 不同的意圖 → 斷言 autocommit revert、回到意圖槽後完成重置。照 v7 字面:沒有東西阻止 commit(FAIL)。

**A7-m4. 「活著的 `/sbin/sysupgrade` 程序」用 `pgrep -f` 判斷,本機非 root 程序或被攻陷的 tenant 可以偽造 cmdline** — **PR-P1 必帶**
- **證據**:`pgrep` 在 04/02 都有(`/usr/bin/pgrep`,busybox)。`pgrep -f` 比對的是 `/proc/<pid>/cmdline`,任何程序都能用任意 argv 去 exec(例如 argv = `/bin/sh /sbin/sysupgrade`)。docker 容器的程序在主機的 `/proc` 也看得到。
- **後果**:
  - (1) F1 之後的再查永遠看到「sysupgrade 在跑」→ 恢復出廠永遠 `E_PRECOND` → 被攻陷的 tenant 能擋住擁有者重置(DoS,讓 tenant 保住自己的持久性;擁有者只剩重燒卡)。
  - (2) §6.4 的寫入條件被滿足的機率變高。風險低,因為還需要殘留的 `upgraded`。
- **修法**:要求那個程序是 root(`/proc/<pid>/status` Uid 0)、和 PID 1 在同一個 pid namespace(`/proc/<pid>/ns/pid` 相同)、`exe` 是 `/bin/busybox`,而且 argv[1] 正好是 `/sbin/sysupgrade`。pattern 要錨定:不錨定會被 `/tmp/sysupgrade.img` 這種路徑自我匹配(使用者記憶裡的 pgrep 坑)。
- **負對照**:非 root 程序以 `exec -a` 等方式偽造 cmdline 常駐 → 斷言恢復出廠前置不受影響。

**A7-m5. 早期開機的意圖解析器(root,S10/S11,讀實體可改的 p5)沒有寫出強化契約** — **PR-P1 必帶**
- **情境**(實體 SD,或我們自己的 bug):
  - `.factory-reset` 是 FIFO → `read` 卡住,S10/S11 沒有逾時(R71),開機永遠停住;
  - 是 symlink → 讀到主機的檔;
  - 若實作用 `.`、`eval` 或 `$(cat)` 展開 → root 程式碼執行。
  實體持有者本來就能重燒卡,但開機卡死、root 執行比重燒卡安靜,而且這個解析器每次開機都會跑。
- **修法**:
  - 共用的 `reset-intent.sh` 規定:`[ -f ] && [ ! -L ]`;`head -c 64`;只用 `case` 或 regex 白名單驗證(`^reset v=1 nonce=[0-9a-f]{16} slot=[AB] attempts=[0-9]$`),不 eval;超長或多行 → 壞意圖。
  - p5 掛載加 `ro,nosuid,nodev,noexec,noload`。
  - W0 寫回時同樣 tmp + rename + fsync(檔與目錄)。
- **負對照**:p5 放 FIFO / symlink / 含 `$(…)` 的意圖 → 開機不卡、不執行、判成 Wb。

**A7-m6. W0 寫 p5 的 attempts 沒有取 `cfgsave.lock`;執行期 `batdata-mount start` 會讓它與 F3 的讀回同時發生** — **PR-P1 必帶**(與 M1 一起修)
- **證據**:p5 的唯一寫者鎖是 `$RUNDIR/cfgsave.lock`(`batman-config-save:67,115-140`)。v7 §3 的 attempts+1 由 batdata-mount 直接寫。`start(){ boot; }`(`95:728`),而 W 放在閂之前。
- **情境**:F3 rename 之後、讀回之前,有人(harness 或操作員)跑了 `batdata-mount restart` → W0 改 attempts → F3 讀回不符 → rc 1 → 撤銷 → 回到 M1。
- **修法**:W0 改呼叫 config-save 的一個新模式(例如 `--reset-attempt`,取同一把鎖),或在 INITBODY 裡取同一把鎖。F3 的讀回只比對 `nonce` 與 `slot`,不比 attempts。

**A7-m7. 「W0 卡住 → 96 上鎖」不成立(96 只在 fresh overlay 跑);另外,W1 失敗之後才完成的重置,終態是「unclaimed 但上鎖」**
- **證據**:96 是 uci-default,fresh overlay 才會跑。W0 只在哨兵在(= 舊 overlay)時走到 → 96 不會跑。鎖定狀態沿用舊 overlay:claimed/member 本來就鎖著,所以沒有安全洞;SD 觸發的 legacy/unclaimed 節點維持原本不上鎖,和重置前一樣。文字要改。
- **W1 失敗的 fresh 開機**:96 上鎖(正確)→ 下一次開機(非 fresh)W1/W2 重試成功 → 這個 overlay 還是上鎖的、沒有 `authorized_keys` → 終態 `prov{unclaimed}` 但上鎖,與 §1.4「unclaimed:不動(image 預設)」不符。
- **修法**:
  - 寫明終態,並在 status 顯示。
  - 或者 W2 在非 fresh 開機成功之後,再做一次 jffs2reset + reboot,讓終態永遠是 image 預設。這是一行規則,建議採用。
- **Q5 後果**(見 §6):04 的還原計畫靠「重置後 image 預設空密碼」從乙太網進去。只要 W1 失敗過一次,04 就會上鎖且沒有 key,遠端救不回。

**A7-m8. W2 失敗的那次開機要不要掛新的 p6 沒有定義;p5 一直寫不進時,W1 每次開機都會重新 mkfs p6、清掉證據**
- 每次開機都 mkfs 一次,不會重開迴圈,但 `factory-reset.log` 和 crash 紀錄每次都會被清掉。
- **建議**:W1 成功後在新 p6 寫 `state/reset-w1-done <nonce>`(A6-m2 的選項)。下一次開機 p6 上有同 nonce → 跳過 W1、直接 W2。並且定義 W2 失敗時要掛新的 p6(只放 log),其餘不啟動。

**A7-m9. 卡住的狀態下 p6 不掛,marker 檢查與 p6 寫者會落在 overlay 的空目錄(fail-open)** — **PR-P1 必帶**
- **證據**:
  - `99-batman-payload-docker`:`data_root=/opt/batdata/docker`,沒有掛載檢查,註解自己寫了「a mkdir would land on the overlay instead of p6」。
  - v7 §4.6 的 marker 檢查是「marker 檔存在 → 不啟動」;p6 沒掛時讀不到 marker → 會啟動。
  - 卡住的情況:Wb、W0 卡住、W1 失敗(都「不掛 p6」),而 W0 卡住時舊 overlay 上的 guardian init 還在。
- **後果**:不洩密(tenant image 在 p6),但會在 overlay 上建 docker data-root、寫 prov-state/ble-ok,造成誤判與 overlay 填滿。
- **修法**:所有 marker 檢查改成「marker 存在 **或** `! mountpoint -q /opt/batdata` → 不啟動」(04/02 都有 `/usr/bin/mountpoint`);99zz/helper 寫 p6 前同樣檢查。

**A7-m10. rc 8 的語意與 config-save 現況不符;rate-limit 與 rw backoff 會被誤報成「請換卡」** — **PR-P1 必帶**
- **證據**:
  - config-save 現在只有 `--check` 在鎖忙時回 8;寫入模式鎖忙回 **1**(`:138-140`)。
  - rw 掛載失敗後 300 s 內直接 rc 1(`:209`)。
  - 每次開機有寫入次數上限,超過 rc 1(`:381`)。
  - v7 §4.3 把 rc 8 定為「p5 已掛載」,F3 列卻寫「rc 8(鎖忙)」。
- **修法**:`--reset-intent` 的 rc 表寫死:8 = 鎖忙或已掛載(可重試);新增 9(不確定,見 M1);1 = 確定沒寫。豁免 rate-limit 與 backoff,或把它們對應成可重試。

**A7-m11. 文件互相矛盾(合起來讀會實作錯)**
- §4.3 的意圖格式 `"reset v=1 nonce=<hex16> attempts=<n>"` **沒有 `slot=`**,§3 有;§4.3 的模式表是 `--reset-intent <nonce>`,F3 是 `--reset-intent <nonce> --slot <slot>`。嚴格解析器會把其中一份判成壞意圖(Wb 永久卡住)。
- §4.3「helper 判 `unknown` 時只改第 2、1 欄」與 v7 的 6 欄 `prov-state` 不符(第 4 欄 `verdict` 也要寫)。v5 §6.4 `expected_in_mesh()` 的表沒有 `resetting` 這個值。
- D34 與 §10 仍寫 `BATMAN_FIRSTBOOT=1`,§4.5 寫「不靠 `BATMAN_FIRSTBOOT`」。要刪掉,或寫明它還用在哪裡。
- §5 L16 寫「(a)–(f)」,§4.5 已經是 (a)–(i);L37 同樣。
- §4.5「直接到步驟 5 呼叫 `boot()`」:步驟 4(產生 INIT)不能略過,否則 `"$INIT" boot` 不存在。
- v5 §10「95/batdata-mount(tombstone/marker → mkfs p6)」經由「同 v5」繼承進來,與 v7「marker 不是觸發」衝突。v7 §10 要明寫「取代」。
- R43「任何層級的 dot 項目都不刪」不精確:`handle_rmdir` 會 unlink 被造訪目錄內的 dot **檔**,也會刪掉 `/overlay/.fs_state` 這個 symlink(`overlay.c`;`foreachdir` 最後對 `/overlay` 本身呼叫 cb)。不刪的是 dot **目錄**。對設計沒有影響:下次開機狀態是 UNKNOWN,照樣走 PENDING 清除(`overlay.c:445-453`)。

**A7-m12. 生命週期矩陣缺的列,以及 A6 要求、v7 沒落地的測試**
- 要補的列:
  - ramoverlay(m1);
  - 各個 F 步驟中 helper respawn(A6-m3 要求逐步列;v7 只寫了兩格);
  - 執行期 `batdata-mount start/restart`(A6-m8);
  - **95 在建 INIT 之前 exit 0**:有意圖時,這個 overlay 永遠不會跑 W → 永久卡住並上鎖(fail-secure,但要寫明,status 要能顯示);
  - Wa trial(m3)。
- A6-m10 / B6-m7 要求的「送出 `claim/finish` 後殺掉 app → 重開 → replay 成功」沒有進 §9 或 L 表。

**A7-m13. §6.4 殘留:`platform_check_image` rc=0,但 procd 的整體 validate 因為其他檢查判 invalid** — 不必帶(可選)
- 這時沒有升級發生,但 `ota-armed.mesh` 已經寫入。只影響同一次開機內的 L42(直接 `batman-slot apply`)。有 boot_id 綁定,風險低。
- 可選修法:batman-slot apply 在 arm 之前 `rm` 掉舊檔(A6-m5 的建議),或寫成殘項。

---

## 3. 指定重點逐項

| 項 | 結論 |
|---|---|
| 哨兵「在 ⇔ 沒清」:F4 部分失敗 | find 之後 jffs2reset 才刪哨兵。jffs2reset 在掛載中的路徑一律回 0(`jffs2reset.c:44-63`,`overlay_delete` 是 void)→「jffs2reset 失敗」實際上只會是 volume 找不到,這時哨兵還在 → W0 補做 ✅。overlay_delete 部分失敗(EIO)時,哨兵可能已刪而其他檔還在 → 下次開機 PENDING 會再清一次(`overlay.c:451-453`)✅ |
| jffs2reset PENDING 第二次清除 | ✅。`.fs_state` 被 overlay_delete 一併刪掉 → 下次開機 UNKNOWN → 設 PENDING 並清除(`:445-453`);fresh 開機在 S95 `mount_root done` 之前斷電 → 再清一次,W1/W2 冪等 ✅(v7 沒寫出這個好處,建議寫進證據) |
| 另一槽的 fresh trial overlay | 哨兵不在,但 Wa 先判 slot ✅。後續回退沒有落地(m3) |
| F4 之後 helper 寫其他 overlay 檔 | 都會被下一次開機的 PENDING 清掉 ✅;F4 之後新建的 **dot 目錄**會留下(fstools 不造訪),內容是新的,沒有前任資料 → 可接受 |
| 撤銷刪哨兵 | **打破等價(M1)** |
| tmpfs overlay | **打破等價(m1)** |
| W0 attempts 讀回 | 有上限 ✅;寫者沒取鎖(m6);上限依賴「卡住時 p6 不掛」(m2 的隱性耦合) |
| Wa + `fw_override_check` | 只修 EEPROM 開錯槽;trial 不修(m3) |
| Wb 壞意圖 | 不清、不掛、上鎖 ✅;解析器的強化(m5);格式定義不一致會製造 Wb(m11) |
| 95 略過 3/3b | ✅,但步驟 4 不可略(m11);95 在 `:86/:95-101/:106` 提早 exit 時 W 永遠不跑(m12) |
| INITBODY 守門用 `return` | ✅。注意 Pi 3 MBR 沒有 PARTNAME → W1 守門永遠不過 → 3A+ 上恢復出廠永遠停在 W1(U6 後果) |
| W0 `reboot` 後 `return` | ✅,而且比 v6 兩位 reviewer 擔心的安全:procd 的 shutdown 會呼叫 `rcS("K")`,而 `rcS()` 會先 `runqueue_init(&q)`(`rcS.c:199`),把還沒跑的 S* 任務丟掉,只有正在跑的 S11 會跑完。所以 `return` 之後 S19 dropbear 不會用 rom 設定起來。⚠️ 這是讀原始碼的結論,要在 bench 以 `logread` 實證 |
| 96 有意圖就上鎖 | fresh overlay ✅;非 fresh 的說法錯(m7);終態上鎖(m7) |
| helper 重啟續做 F4 | 缺「哨兵已刪」與「p5 讀不到」兩格(m2、M1c) |
| F3 rc 8 重試 | 方向 ✅;rc 語意與現有程式不符(m10) |
| §6.4 ota-armed + 活著的 sysupgrade | 機制上成立:sysupgrade 在 `ubus call system sysupgrade` 上同步等待(`sysupgrade:426`),procd 第二次 validate 時這個 shell 還活著 ✅;第一次 validate 的 PPID 是 sysupgrade(`:370` 命令替換的子程序 exec)→ caller ≠ procd ✅;`-F` 的 procd validate rc=1 → 不寫 ✅。可偽造(m4);rc=0 但整體 invalid(m13) |
| prov-state 欄位拆分 | 拆分 ✅;§4.3 文字沒同步、`resetting` 值沒有對應(m11) |

---

## 4. 逐 actor

| Actor | v7 擋住 | 沒擋住 / 寫錯 |
|---|---|---|
| BLE 路人 | psk_replay + 假第 2 則 + 等逾時 ✅;全域額度寫成協定界線 ✅ | — |
| 只看過 QR 的人 | 算不出 psk_replay ✅ | — |
| 本機非 root 程序 | `/etc` 0755 root(04 實測),建不了哨兵 ✅;RUNDIR root-only ✅ | 偽造 sysupgrade 的 cmdline(m4) |
| 被攻陷的 provd | 需要 owner-op 才能發起 / 取消 ✅ | — |
| 被攻陷的 tenant | 碰不到 marker、哨兵 ✅ | 主機上看得到它的程序 → pgrep 偽造擋住重置(m4) |
| 前任擁有者 / 轉賣 | 成功路徑全清 ✅ | 撤銷後的半套重置留下 `authorized_keys`(M1);tmpfs overlay(m1) |
| 買家(弱 BLE、回應遺失) | 契約 ✅ | 測試沒進 L 表(m12) |
| legacy 02/04 第一次 OTA | stage 1 跑舊 image 的 `platform-ab.sh` → 不寫 → 今天的規則 ✅ | — |
| 單台在家 / 整隊 OTA | L51 / L40 ✅ | — |
| p5 壞的節點 | rw 掛不起 → 撤銷 ✅ | **寫進去之後才壞 → M1** |
| p6 壞的節點 | 前置拒絕 ✅;F3 之後才壞 → W1 失敗 → 不掛、上鎖 ✅ | 每次開機重新 mkfs(m8) |
| 實體 SD | 寫意圖 = 觸發清除(等同重燒,已寫明)✅ | FIFO/symlink 讓開機卡死(m5) |
| 我們自己 | 工具都存在(04/02 實測:pgrep、mountpoint、flock、jffs2reset、mkfs.ext4、hexdump、blkid、sgdisk、fsync;`timeout`、`stat` MISSING) | 文件不一致(m11);rc 語意(m10) |

---

## 5. v6 發現核對(一條一行)

| v6 | 狀態 | 說明 |
|---|---|---|
| A6-m1 trial 槽 / sysupgrade 空窗 | partial | slot 欄位 ✅、F1 後再查 ✅;回退沒落地,`fw_override_check` 不處理 trial(m3) |
| A6-m2 attempts 在 p5、「95 再跑」錯 | addressed | 正面哨兵、寫不進就停、重試路徑照實寫 |
| A6-m3 helper F3 後 crash | partial | 缺「哨兵已刪」與「p5 讀不到」(m2、M1c) |
| A6-m4 prov-state 雙語意 | addressed(文字殘留) | 拆欄 ✅;§4.3 舊句未改(m11) |
| A6-m5 procd validate 殘留 upgraded / rc | addressed | rc=0 + 活著的 sysupgrade;偽造(m4)、整體 invalid(m13) |
| A6-m6 resetting 不上鎖 | addressed | fresh overlay 上鎖 ✅;非 fresh 說法錯(m7) |
| A6-m7 守門 / 參數 / 3b / 「只有」 | addressed | 步驟 4 文字(m11) |
| A6-m8 reboot 非同步 / 紀錄 / 執行期 start | partial | `return` + `factory-reset.log` ✅;執行期 `start/restart` 沒寫(m12) |
| A6-m9 `mv -T` / 時段 / busy | addressed | rc 語意(m10) |
| A6-m10 app 先持久化 / 連線佔用 | partial | 契約 ✅;殺 app 的 L 測試沒進(m12) |
| A6-m11 殘留資料誠實界線 | addressed | §4.5 末段 |
| A6-m12 R72 / §8 / 三寫者 | addressed | 但 §3 哨兵列漏了撤銷這個刪除者(M1d) |
| B6-M1 W0 誤判 / 無上限 / 掛舊 p6 | addressed | 等價在撤銷、tmpfs、helper respawn 三條路徑上不成立(M1、m1、m2) |
| B6-M2 resetting 不上鎖 | addressed | fresh overlay 一律上鎖;終態見 m7 |
| B6-m1 95 對舊 p6 跑 3/3b | addressed | 步驟 4 文字(m11) |
| B6-m2 守門不在 INITBODY / R72 | addressed | |
| B6-m3 W0 在 S11 重開 | addressed | 另見 §3:procd `rcS.c:199` 會丟掉剩下的 S* |
| B6-m4 讀者判準不一致 | addressed | 解析器強化(m5);格式定義不一致(m11) |
| B6-m5 F3 rc 對應 | partial | rc 8 語意與現有程式不符(m10);rc 1 不等於沒寫(M1) |
| B6-m6 §6.4 rc / stale upg | addressed | m4、m13 |
| B6-m7 app 契約 | partial | 測試(m12) |
| B6-m8 prov-state 兩寫者 | addressed | |
| B6-m9 resetting-pending 允許清單 | addressed | |
| B6-m10 負對照 (e) | addressed | D34 殘留(m11) |
| B6-m11 p6 壞不能重置 | addressed | |

---

## 6. 使用者已定案事項的後果(不重開,只列)

- **Q5(L16 在 04)**:
  - 還原計畫靠「重置後 image 預設空密碼」從乙太網進去。v7 的 B6-M2 修法(有意圖就上鎖)讓 **W1 或 W2 失敗過一次的 04 變成上鎖、沒有 `authorized_keys`**,遠端救不回,只能實體處理(m7)。
  - 重置之後的網路設定是 image 預設,不是 10.41.1.3,主機要能在預設位址找到它。
  - 依使用者「破壞性測試先列副作用」規則,這兩點要在排 L16 之前列進副作用清單。建議先採用 m7 的「W2 在非 fresh 開機成功後再清一次 overlay」,讓終態一定是 image 預設。
- **Q6**:04 的 lab key 在 overlay 與 p5,L16 之後兩邊都會清掉,所以重置後 lab key 不在了。這是預期,寫進 Q5 的還原步驟即可。
- **U3 擁有權與 SSH 脫鉤**:M1 的半套重置會留下前任的 `authorized_keys`,而認領不會清它。這條是 M1 會造成後果的放大器。
- **U4 全清含身分**:無新後果。
- **U6 3A+ 延後**:W1/W2 的 PARTNAME 守門在 Pi 3 MBR 上永遠不過 → Pi 3 上恢復出廠會停在 W1。95、`platform-ab.sh` 都是兩板共用,bcm2710 ❌。
- **96 bypass 也上鎖**:同 v6。

---

## 7. 本輪唯讀探針(原始輸出摘要)

```
04 command -v: pgrep=/usr/bin/pgrep pidof=/bin/pidof mountpoint=/usr/bin/mountpoint flock=/usr/bin/flock
   jffs2reset=/sbin/jffs2reset mkfs.ext4=/usr/sbin/mkfs.ext4 hexdump=/usr/bin/hexdump blkid=/usr/sbin/blkid
   sgdisk=/usr/bin/sgdisk stat=MISSING readlink=/usr/bin/readlink fsync=/bin/fsync timeout=MISSING   (02 相同)
04 mount: /mmcblk0p4 on /overlay type f2fs (rw,...,nodiscard,...);overlayfs:/overlay on / type overlay (upperdir=/overlay/upper)
          /dev/mmcblk0p6 on /opt/batdata type ext4
04 cmdline: root=PARTUUID=3276af79-…-000000000004 batman_slot=B;batman-slot active=B, is-trial rc=1   (02 相同)
04 /etc、/overlay/upper/etc: drwxr-xr-x root root
04 /overlay: .fs_state -> 2(READY), upper/, work/     (02 相同)
04/02 dropbear.main.PasswordAuth='on' RootPasswordAuth='on';/etc/shadow root:::0:999
04 RUNDIR=/tmp/run/batman(無 ramroot/;有 batdata-mount.booted, cfgsave-writes, joinwatch.state …)
fstools jffs2reset.c:44-63  mounted → fs_state_set(PENDING); overlay_delete(mp); return 0(無 -r 不重開)
fstools overlay.c handle_rmdir: readdir 全部非目錄項(含 dot 檔、symlink)unlinkat;foreachdir glob "/*" 不進 dot 目錄;最後 cb(dir) 本身
fstools overlay.c:445-453  UNKNOWN → set PENDING → fallthrough PENDING → overlay_delete(keep_sysupgrade)
fstools mount_root.c:63-79  FS_NONE/FS_DEADCODE → ramoverlay();96:79 註解記載 Build #2 落入 tmpfs overlay
fstools find.c:103  find_mount_point 以 mountinfo major:minor 比對(loop0 → /overlay 可找到)
procd rcS.c:197-203  rcS(){ runqueue_init(&q); q.max_running_tasks = 1; … }   ← shutdown 的 rcS("K") 重設佇列
procd state.c:223-231  procd_shutdown: state < SHUTDOWN 即進 SHUTDOWN(STATE_INIT 亦然)
sysupgrade:370  json_load "$(/usr/libexec/validate_firmware_image "$IMAGE")"(PPID = sysupgrade)
sysupgrade:426  ubus call system sysupgrade "$(json_dump)"(同步等待 → procd validate 期間 sysupgrade 活著)
95:445-452  fw_override_check: tb != 0 → return 0(trial 不修正);:460-465 uci-defaults 在 → 延到 autocommit
batman-config-save:138-140  寫入模式鎖忙 → rc 1;只有 --check → rc 8;:209 rw 失敗 300 s backoff → rc 1;:381 rate-limit → rc 1
99-batman-payload-docker: data_root=/opt/batdata/docker,無掛載檢查
```

---

## 8. 判定

**REJECT(窄)**

- BLOCKER **0**,MAJOR **1**(A7-M1),MINOR **13**(m1–m13)。
- M1 的修法是局部的:`--reset-intent` 三態結果、只有「確定沒寫」才撤銷、§3 哨兵列補上撤銷這個刪除者、一個負對照。不需要新機制,也不改 v7 的形狀。
- **PR-P1 必帶的 MINOR**(各附負對照):m1(tmpfs overlay)、m2(jffs2reset 後 respawn + `-r`)、m3(trial 有意圖 → revert)、m4(sysupgrade 程序判定不可偽造)、m5(解析器強化)、m6(W0 取鎖)、m9(p6 沒掛 → 不啟動)、m10(rc 表)。
- **實作時修**:m11、m12 進文件與矩陣;m7 進文件,並在 L16 副作用清單列出;m8 要決定(建議採用 `w1-done`);m13 可選。
- 建議下一輪只審 M1 的修法與 m1–m3 的文字是否寫進 §4.5 與 §3,其餘交給 PR-P1 的兩位 code review 與 L16 實機負對照。
