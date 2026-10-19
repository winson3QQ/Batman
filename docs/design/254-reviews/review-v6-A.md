# Review A(第 6 輪)— `254-stage1-impl.md` v6(+ v4/v5 中標「同 v4」「同 v5」的各節)

審查者 A,獨立、對抗式。審查對象:`design/254-stage1-impl` @ 9b8687c 的 v6,加上 v6 標「同 v4」引用的 `254-reviews/254-stage1-impl-v4.md` 與標「同 v5」引用的 `254-stage1-impl-v5.md`,三份合起來當作一份設計來審。依使用者 CLAUDE.md 的設計審查規則與 `docs/design/REVIEW.md`。使用者已定案的事項(擁有權與 SSH 脫鉤、恢復出廠全清含身分、Go/Flutter+Rust、3A+ 延後、`uart_enable` typo、改名探針、Q5/Q6)不重開,只在 §6 列後果。我沒有讀 reviewer B 的報告。

**證據來源(全部唯讀,2026-10-19)**
- 原始碼(main f2f2bf6 = branch):`95-batman-storage`(含產生的 batdata-mount init 全文 `:369-753`)、`96-batman-config-migrate`(全部出口)、`batman-config-save`(lock 與 mkfs)、`batman-slot`(`invalidate_slot`、`ZERO_MB`)、`platform-ab.sh:61-135`、`payload-guardian.*`、`batman-ots-firstload`。
- firmware-2710:`package/base-files/files/sbin/sysupgrade:360-430`、`etc/init.d/boot:7-17`(uci_apply_defaults)、procd `system.c:639-849`、`state.c:223-231`、`signal.c:41,93`、fstools `jffs2reset.c:36-140`、`libfstools/find.c:103+`、`libfstools/partname.c`。
- 04、02:`ota-trace.log` 的 `S1 CHECK`、`boot-reasons.log` 尾、分割 PARTNAME 與大小、`/proc/cmdline`、`mount`、loop offset、`uci show fstab`、`/etc/rc.d` 順序、逐一 `command -v`、`mv --help`、`uci show dockerd`、`/tmp/dockerd/daemon.json`、docker restart policy、`/sys/block/mmcblk0/queue/discard_*`、`/etc/mke2fs.conf`、`/opt/batdata/state` 權限。
- `gh issue view 254 --comments`:BLE spike 結果,與 R38–R42 一致,沒有新事實。
- **沒有任何寫入**;沒跑 bluetoothctl、沒 reboot、沒 jffs2reset、沒 mkfs、沒跑 config-save 寫入模式。

---

## 0. 總評

**v6 對恢復出廠做的刪減是對的,而且有效。** 我照「實際會發生什麼」從頭走了一遍 v5 的三條 MAJOR 情境(停在 R4 時重開、p5-dead、同一次開機 mkfs 兩次),在 v6 下都不成立了:

- 觸發來源只剩一個(p5 意圖)。
- F3 之前的每一步都能撤銷。
- 破壞動作只在一個地方。
- 「p5 被 mkfs」本身就是完成紀錄。

OTA 閘、`state.apply`、claim/replay、96 上鎖這幾個機制,我這輪沒找到新的跨元件衝突。

這一輪找到的都是 **MINOR**,沒有 BLOCKER,也沒有 MAJOR,都可以在實作時修。分兩類:

1. **v6 新寫的 W 階段有幾個邊界契約沒寫完**:
   - 「fresh」不等於「F4 做完」(m1);
   - W0 的計數器存在正在壞的媒體上(m2);
   - helper 在 F3 之後重啟時沒有人把流程做完(m3);
   - W 的守門與參數(m7);
   - W0 的 `reboot` 是非同步的(m8)。
2. **資料契約的小衝突**:
   - `prov-state` 第 3 欄有兩種語意(m4);
   - `caller=procd` 不只出現在真的升級(m5);
   - 96 對 `resetting` 不上鎖,而且沒寫理由(m6);
   - 另外是文件與事實不符的幾處(m9–m12)。

### 收斂判斷

**恢復出廠機制已經收斂。** 理由:

- 結構上只剩一個提交點(p5 意圖)和一個破壞點(95 `boot()` 的 W1/W2)。
- 完成條件是自我證明的(p5 被 mkfs = 意圖消失)。
- 各種斷電點都落在「再做一次」或「可撤銷」。

這一輪找到的問題沒有一條需要再加新的狀態或新的媒體:

- m1 只要在意圖裡多記一個欄位(slot)、前置條件多查一項;
- m2 只要一條規則(計數器寫不進去就當作 ≥ 3);
- m3 只要一條規則(helper 啟動時看到意圖就把 F4–F5 做完)。

這些都不是必須再審一輪才能發現的設計缺陷,在實作 PR 與 code review 裡修、用負對照驗證就夠了。**不建議再為恢復出廠開第 7 輪設計審查。**

---

## 1. 先補:矩陣缺的列、擁有權缺的資源

| 缺的路徑 / 資源 | 為什麼要有 | 對應 |
|---|---|---|
| **p5 有意圖時開進 OTA trial 槽**(fresh overlay,但不是 F4 清出來的 overlay) | 95 檔頭 `:296-297` 自己寫「this hook re-runs on the first boot of every OTA slot」→ 每次 OTA trial 的第一次開機都是 `BATMAN_FIRSTBOOT=1` | m1 |
| **sysupgrade stage 1 已通過、stage 2 還沒進 ramfs 時開始恢復出廠** | 前置條件只查 `slot_lock`。這時 batman-slot 還沒在跑,precheck-node 也已經先過了 | m1 |
| **W2(或 W1)失敗之後的下一次開機** | 95 的 uci-default 一律 `exit 0`(`:755`),跑完就會被刪掉(`etc/init.d/boot:14`)。所以下一次開機**不是** fresh,走的是 W0,而不是 v6 寫的「95 再跑」 | m2 |
| **W0 時 p5 掛不起 rw / attempts 寫不進去** | 計數器放在 p5,而 W2 失敗通常就是因為 p5 壞了 | m2 |
| **helper 在 F3 之後、F5 之前 crash / 被 respawn** | 意圖已提交,但沒有人重開機 | m3 |
| **helper 在 F1–F2b 之間 crash / 被 respawn**(不是開機) | 只寫了「下次開機」怎麼判 `resetting-pending` | m3 |
| **執行期 `/etc/init.d/batdata-mount start/restart`** | `start(){ boot; }`(`:728`);W 放在 once-per-boot 閂之前,所以執行期也會跑 W0 | m8(寫明即可) |
| 資源:**`prov-state` 第 3 欄** | 96 要的是「最後已知狀態」,autocommit 與 `halow-status` 要的是「本次判決」 | m4 |
| 資源:**`$RUNDIR/ramroot/sbin/upgraded` 的殘留** | 它決定了 `upg=y` | m5 |

---

## 2. Findings

**沒有 BLOCKER,沒有 MAJOR。**

### MINOR

**m1. 「`boot()` 由 95 uci-default 呼叫」只代表「這個槽的 overlay 是 fresh」,不代表「F4 在發起恢復出廠的那個槽做完了」。p5 有意圖時開進 OTA trial 槽,W1/W2 會在錯的槽上完成重置**

- **事實**:
  - 95 檔頭 `:296-297` 寫的是「this hook re-runs on the first boot of every OTA slot」。
  - A/B 兩個槽各有自己的 overlay。我在 02、04 實測:overlay 是 `rootB` = `mmcblk0p4` 上 offset 約 108 MiB 的 loop。
  - 所以 `BATMAN_FIRSTBOOT=1` 在以下四種情況都成立:F4 之後的開機、每一次 OTA trial 的第一次開機、被打斷的第一次開機重跑、出廠第一次開機。
- **情境**(視窗窄,但真實存在):
  1. 操作員(或腳本)從 SSH 送 `sysupgrade -n`。stage 1 的 precheck-node 先通過;這時擁有者在 app 按了恢復出廠。
  2. helper 的前置條件只看 `slot_lock`,而 batman-slot 要到 stage 2 才會取鎖 → 通過 → F1…F3 寫入意圖。
  3. stage 2 的 kill 把 helper 殺在 F3 或 F4 中間 → 寫入另一槽、arm tryboot → 開進 trial(fresh overlay)→ W1/W2 在 trial 槽上完成重置。
  4. 原來的 committed 槽(F4 沒做完)仍然保有前任的 overlay:identity、`authorized_keys`、shadow、wireless key。
     - 如果 trial 被 revert:回到舊槽,這時不是 fresh,p5 是空的 → helper 的 rc 7 規則是「overlay 有身分就沿用 / persist」→ **前任的認領被復活**。
     - 如果 trial 被 commit:舊槽留著前任的 overlay,而且不是 BATMAN-BAD,直到下一次 OTA。L16 的「另一槽 BATMAN-BAD」斷言會 FAIL。
  5. `sysupgrade -F` 在 F3–F5 之間是同一條路。v6 把它寫成「操作員自己的選擇」,但沒有寫出這個後果。
- **修法**(都很便宜):
  - (a) 意圖加一個 `slot=<A|B>`(F3 時的 `batman-slot active`)。W1/W2 只在「fresh **且** 目前槽 == 意圖槽」時做;fresh 但槽不同 → 不做任何破壞,crit `reset-on-other-slot`。這時 96 見意圖不還原、helper rc 15,autocommit 必須判 revert(在 `health_ok` 加一條「p5 有意圖 → 不 commit」)→ 回到意圖槽 → 非 fresh → W0 → 照常完成。
  - (b) 前置條件加:`$RUNDIR/ramroot/sbin/upgraded` 不存在、沒有 `sysupgrade` 程序、`/tmp/sysupgrade*` 不存在。順序上要**先寫 F1 marker,再查**,查到就撤銷。這樣與 precheck-node 讀 marker 合起來才沒有空窗(A5-m3 / B5-m2 的殘留)。
- **負對照**:白箱在 trial 槽的 fresh 開機前,在 p5 放一個 slot 與目前槽不同的意圖 → 斷言 p6、p5 的 UUID 都不變、autocommit revert、回到意圖槽後完成重置。照 v6 字面會在 trial 槽格式化。

**m2. W0 的「attempts ≤ 3」上限存在 p5 上。W2 失敗最常見的原因正是 p5 寫不進去,這時上限失效 → 可能無限重開;另外,W1/W2 失敗後的重試路徑寫錯了**

- **證據**:
  - 95 尾段 `exit 0`(`:755`);`uci_apply_defaults` 遇到 rc 0 就 `rm -f`(`etc/init.d/boot:14`)。所以 W1/W2 **失敗**(不是斷電)時,95 還是會跑完並被刪掉,下一次開機不是 fresh。
  - fresh 開機只會呼叫一次 `boot()`:S11 的連結是 95 自己建的,rcS 列舉時還不存在(`:752`)。
- **後果**:
  1. v6 §4.5 寫的「W1 失敗 → 意圖保留、下次開機重試」「W2 失敗 → 下次開機 W1 再清一次」,實際的路徑是:下次開機 → S11 → W0(attempts+1、清 overlay、reboot)→ fresh → W1 → W2。每重試一次要多重開一次、消耗一個 attempt。結果仍然有上限,但文件要照實寫。
  2. p5 的寫入區壞了、但 overlay 正常、p5 還能 ro 掛(意圖讀得到)時:W2 失敗 → W0 的「rw 掛 p5 把 attempts+1」也失敗。v6 沒寫這時要怎麼做。如果照字面繼續清 overlay、reboot,就是**沒有上限的重開迴圈**,每一輪還會再 mkfs 一次 p6,把 crash 證據清掉(A5-M3 的同一類問題回來)。
  3. 「天然只做一次」那一段的理由(同一次開機兩次 `boot()`)不是真正的路徑。結論沒錯,但理由要改。
- **修法**:
  - W0:attempts 寫不進去(rw 掛不起、寫入失敗或讀回不符)→ 當作 ≥ 3:crit `reset-stuck p5-unwritable`,不清、不重開。
  - 文件照實寫重試路徑(W0 → fresh → W1/W2)。
  - 可選:W1 成功後,在**新的** p6 寫一行 `state/reset-progress <nonce> w1-done`(RUNDIR 也留一份)。下一次開機如果 p5 已經不是 ext4 magic 但這個檔還在 → 可以重做 W2。這樣「W2 中斷電 → 只能 bench 重做」那一列也有自動出路。
- **負對照**:白箱讓 p5 的 rw 掛載失敗,但 ro 掛載與意圖都正常 → 連開 5 次,斷言最多 1 次 W0 reboot、之後停在 `reset-stuck`。照 v6 字面沒有定義(實作很可能會無限重開)。

**m3. helper 在 F3 之後、F5 之前 crash 或被 procd respawn:意圖已經提交,但不會有人把 F4–F5 做完。在 F1–F2b 之間 respawn 時,狀態判定也只寫了「開機」那一條**

- **證據**:
  - v6 §4.2:「rc 15 時 helper:不補 persist、不還原、不產生;判 `resetting`……95 下次開機會完成」。
  - §4.5:「F1–F2b 之間斷電:下次開機 marker 在 …… `resetting-pending`」。
  - helper 是 procd 服務(S89)。respawn 不是開機,不會走 `--boot`。
- **後果**:
  - app 顯示「已開始,請勿斷電」之後,節點停在 `resetting`,帶著前任的 overlay(F4 沒做)、payload 已停,一直到有人拔電源才會繼續。
  - F1–F2b 中的 respawn:payload 已停、`apps/` 已改名,但 helper 如果只在 `--boot` 判 `resetting-pending`,respawn 後的 provd 可能回報舊狀態,而且 cancel 不能用。
- **修法**:helper 每次啟動(不只是 `--boot`)都先判:
  - p5 有意圖且本次開機不是 fresh → 直接(冪等)做 F4–F5;
  - 只有 marker → `resetting-pending`,開放 cancel。
- **負對照**:白箱在 F3 rc 0 之後 `kill -9` helper → 斷言 ≤ 30 s 內節點重開並完成重置。照 v6 字面會停住。

**m4. `prov-state` 第 3 欄有兩個互相衝突的語意:96 要「最後已知狀態」,autocommit 與 `halow-status` 要「本次判決」**

- **證據**:
  - v6 §4.3:「`prov-state` 的 `unknown` 不覆寫上一次的 claimed/member:helper 判 `unknown` 時只改第 2、1 欄(writer、boot_id),第 3 欄保留」。
  - v5 §6.4 的 `expected_in_mesh()` 讀 `prov-state`:boot_id 相符就採用第 3 欄。
  - §1.4:`unknown` 的 NEED_MESH =「今天的規則」。
- **後果**:p5 讀不到的那次開機,helper 判 `unknown`,卻寫出「本次 boot_id + member」→ autocommit 當作 member 處理,`halow-status` 顯示 member。這與 §1.4 矛盾。方向大多是更嚴格(要求鄰居),不是安全洞,但它正是「兩個讀者對同一欄的假設不同」的那一類問題,診斷時也會誤導。
- 另外:99zz(`--apply-state --firstboot`)是否同樣遵守「unknown 不覆寫」沒有寫。p6 沒掛時沒有提示 → fail-open,這點也沒寫(B5-m3 的殘留)。
- **修法**:
  - 加第 6 欄 `verdict`(本次判決,可以是 `unknown(...)`)。
  - 第 3 欄改名為 `last_known_state`,只由確定的判決覆寫。
  - autocommit 與 `halow-status` 讀 `verdict`,96 讀第 3 欄。
  - 寫明 99zz 走同一個 writer 函式,也寫明 p6 未掛時 fail-open 及其理由。

**m5. 「caller=/sbin/procd 且 upg=y」不只發生在真的升級:LuCI / `ubus call system validate_firmware_image` 在殘留了 `upgraded` 的 RAM_ROOT 下也成立;rc=0 條件也沒寫**

- **證據**:
  - procd `system.c:848` 有獨立的 `validate_firmware_image` ubus 方法,和 `sysupgrade` 方法(`:792`)一樣,透過同一個 `validate_firmware_image_call()` fork/exec 驗證腳本(`:660,683`),父程序都是 procd。
  - `upg` 只看 `$RAM_ROOT/sbin/upgraded` 是否存在(`platform-ab.sh:77`)。
  - RAM_ROOT 只在父程序是 sysupgrade 時清(`_ab_ramroot_guard`,`:88`)。所以某次 stage 1 已經 `install_bin` 之後失敗(`sysupgrade:406`,例如 procd 的 validate 拒絕而且沒有 `-F`),`upgraded` 會一直留著,直到下一次 sysupgrade。
  - 04 的 ota-trace 實證兩種 caller 的格式:`caller=/bin/sh /sbin/sysupgrade -n … upg=n`,接著 `caller=/sbin/procd  … upg=y`,而且 `-F` 那次 procd validate 是 `rc=1`,升級照樣進行。
- **後果**:低風險。只在同一次開機、L42 直接 `batman-slot apply` 時,會採用一份不是升級當下的判決。D27 的「⇔」寫得過頭了。
- **修法**:
  - 只在 rc=0 時寫(或明定 `-F` 時不寫 → fail-closed)。
  - stage 1 在 `ubus call system sysupgrade` 失敗時,刪掉 `$RAM_ROOT`。或者在 batman-slot apply 成功 arm tryboot 之後,才把 `$RUNDIR` 裡 stage 1 留下的判決搬到 p6(B5-M4 原本的建議)。
  - 直接 `batman-slot apply` 先 `rm -f` 舊檔。
  - D27 改為 ⚠️,證據寫成「真的升級 ⊂ {procd, upg=y}」。
- **負對照**:`ubus call system validate_firmware_image '{"path":"…"}'`(先放一個殘留的 `upgraded`)→ 斷言不寫檔。

**m6. 96 見到 `.factory-reset` 時「不上鎖」是一個沒寫理由的 fail-open,而前任的秘密這時還在媒體上**

- **情境**:W2 失敗(或 W1 失敗)。fresh overlay = image 預設(04 今天是 `root:::`、`PasswordAuth=on`,#137)。p5 上還有前任的 `prov.cbor`(member 節點含 `net_root` → 全隊的 `psk_member`)、overrides(SAE 密碼)、dropbear identity;W1 失敗時,舊的 p6 也還在(雖然沒掛)。這時接上乙太網的任何人就是 root,可以 `mount` p5 讀出來。W0 重試 3 次後停在 `reset-stuck`,一直保持這個狀態。
- **證據**:v6 §4.3「`.factory-reset` 存在 …… verdict `resetting`、不還原任何東西、**不上鎖**、exit」;§1.4 `resetting` 列「不動」。
- **修法**:`resetting` 也上鎖(`root:!`、PasswordAuth off、`ttylogin=1`)。代價是 stuck 時只能重燒卡,而 v6 本來就是這麼寫的(「需要重燒卡」);W0 重試會清 overlay,所以上鎖不影響重試。如果決定不鎖,就要在 §8 寫明理由(這和使用者規則的 fail-secure 預設相反)。
- **負對照**:白箱讓 W2 失敗 → 斷言 dropbear 拒絕空密碼登入。

**m7. W1/W2 的守門與參數沒有落到它們真正執行的地方**

- `assert_not_system`(`95:94-104`)與 `p5_never_seeded()`(`:178-184`)都在 uci-default 的部分,**不在**產生出來的 INITBODY(`:372-748`)裡;INITBODY 也只有 `PART/DEV`(p6),沒有 p5 的路徑。v6 寫的「既有守門」「同 `p5_never_seeded()` 寫法」需要把它們搬進 INITBODY。另外,`assert_not_system` 用的是 `exit 0`,在 init 裡會結束整個 init。
- W2 沒有對 p5 的守門。建議:`/sys/class/block/<p5>/uevent` 的 `PARTNAME=config`(02、04 實測都有),且不是 squashfs。W1 同樣檢查 `PARTNAME=data`(Pi 3 MBR 沒有 PARTNAME,寫明退回現有守門)。
- W2 的 mkfs 參數要和 `batman-config-save do_mkfs`(`:156` `-F -q -L batman-cfg -m 0`)一致,否則 bench 與現場重置出來的 p5 不同。
- discard:節點上沒有 `/etc/mke2fs.conf`(04 實測);mke2fs 1.47.0 預設會 discard;SanDisk 32G 回報 `discard_max_bytes=170519429120`。要明定用不用 discard。用 discard 時,重置對殘留資料比較有利(§m11),但耗時要在 L16 實測(D30 仍是 ⚠️)。
- 有意圖時,95 的 step 3/3b(`recover_ext4` / `e2fsck -pf` / `resize2fs`,`:330-357`)會先對**舊的** p6 跑一遍:白費時間,而且 e2fsck 遇到 I/O 錯誤時會 crit。建議有意圖時跳過(B5-m8 的殘留)。
- 「p6、p5 的格式化:只有 95 W1、W2」講過頭了:95 step 3 的 P3MARK mkfs(`:335`)與 config-save `--seed --reformat`(`:152-184`)也會格式化。改成「現場只有 W1/W2;工廠與 bench 另有 P3MARK、`--seed --reformat`」。

**m8. W0 的 `reboot` 是非同步的,而且整個重置過程沒有留下持久紀錄**

- **證據**:busybox `reboot` 只是送信號(`/sbin/reboot -> busybox`)。procd 在 STATE_INIT 收到後轉入 SHUTDOWN(`state.c:223-231`),但 rcS 的 S* 會繼續跑。
  - 如果 `boot()` 在 `reboot` 之後沒有停下,就會繼續走 W3:mount p6、`restore_payload_guardians`……
  - 而 S12 之後各 init 的 marker 檢查,在 p6 還沒掛時讀到的是 overlay 上的空目錄 → fail-open(例如 dockerd 會以 overlay 上的 `/opt/batdata/docker` 當 data-root 啟動)。
- **修法**:W0 寫成 `sync; reboot; sleep 600; reboot -f`(或至少 `return 1` 且不做 W3)。
- **紀錄**:W0 的 attempts 在 W2 時跟 p5 一起消失;W1 會把 p6 上的 `boot-reasons`、`ota-trace` 清掉。重置做了幾次、哪一步失敗,事後都查不到(使用者的「每個 FAIL 要有證據」)。建議:W 階段把 `nonce`、`attempts`、各步驟 rc 存在 `$RUNDIR`,W3 掛上新的 p6 之後寫一行 `log/factory-reset.log`。
- 執行期 `/etc/init.d/batdata-mount start/restart` 也會跑 W(W 在閂之前)。在 F3–F5 與 `reset-stuck` 期間會因此 W0。方向上沒錯,寫明即可。

**m9. cancel 的 `mv apps.reset apps` 在 `apps/` 已存在時會變成 `apps/apps.reset`;cancel 的可用時段前後寫法不一致**

- busybox `mv` 有 `-T`(04 `mv --help` 實測)。撤銷時用 `mv -T apps.reset apps`;`apps/` 已存在(例如重新發起時「`apps.reset` 已存在就略過 mv」,而 `apps/` 被重建)→ 先把 `apps/` 改名成 `apps.dup.<nonce>`、log,不要合併。
- §4.1 寫「只在 `resetting-pending`(F1–F2)可用」,§4.5 寫「只在 F3 之前可用」(含 F2b)。要統一。另外要明定 cancel 與正在跑的 F 步驟之間的互斥:helper 單執行緒,或者靠 marker 的 flock。
- F3 的 rc 1 也可能只是 config-save 的 lock 忙(`batman-config-save:125-140`,等 10 s 後 rc 1)。這時 app 顯示「請換卡」是錯的訊息。建議區分 `E_RESET(p5-busy)` 與 `p5-unwritable`。

**m10. `psk_replay`:app 要保存什麼沒有寫成契約;「路人最多佔一條連線」沒有根據**

- 協定 §3.1:手機依**本機紀錄**選模式。認領回應遺失之後要能 replay,app 必須在**送出 `claim/finish` 之前**就先持久化 `{device_id, node_cert(含 ecdh_pub、DAC), claim-pending}`。否則 app 當掉 / 被殺之後,只會用 NX 去連(會被拒,而且看起來和「被別人認領」一樣),無法算出 `psk_replay`。要寫成 app 端的 write-ahead 規則,並列入 L 測試(在 `claim/finish` 送出後殺掉 app → 重開 → replay 成功)。
- `ECDH(node_ecdh_priv, owner_enc_pub)` 讓 608B 的 ECDH 槽同時當 §7.3 ECDH-ES 的接收方與 static-static 的導出來源。協定 §6 的「一把金鑰不兼兩種用途」原本說的是簽章 / 加密,兩者同屬 key agreement,加上 HKDF 標籤區隔,我判定可以接受,但 §1.3 要寫明這是有意識的例外。D33 ⚠️ 合理。
- §4.1「同時連線 ≤ 2 → 路人最多佔一條」:兩支手機或 RPA 輪替就能同時佔兩條。可以保證的是協定 §8 的「未認證 session 可被新連線擠掉」,要改寫成那一條,並在負測試裡以兩個 central 驗證。

**m11. 殘留資料:§8 的「前任擁有者 → 重置後殘留」寫得比實際做到的強**

- 219 `:490` 的誠實界線是「清除是盡力覆寫;SD 卡不保證讀不回」。v6 實際做到的:
  - p5、p6 mkfs(預設 discard,見 m7);
  - **本槽 overlay 只 unlink**:jffs2reset 的 mounted 路徑 = `overlay_delete`(`jffs2reset.c:49-55`),而 overlay 掛的是 `nodiscard`(02、04 的 `mount` 輸出)→ 前任的 identity、SAE、`net_root` 副本在 f2fs 的資料區可以直接 carve 出來;
  - **另一槽 overlay** 只清了 `ZERO_MB = ceil(squashfs)+64 MiB`(`batman-slot:608,614`)。overlay 從 squashfs 尾端開始(04 loop offset 113442816 B),所以只清到 overlay 開頭 64 MiB 左右,後面約 1.3 GiB 的 f2fs 資料區留著。
- **修法**:
  - §8 那一列改成實際做到的程度,並引用 219:490;
  - `invalidate-other` 改成清整個另一槽 root 分割(1.5 GiB,dd 約數十秒,在可撤銷期,可以接受),或至少寫明沒清;
  - 本槽 overlay:節點沒有 `fstrim`(04 實測 MISSING),寫成殘項。
- 這不重開 U4,只要求文件不要過度宣稱。

**m12. 文件與事實不符(小)**

- **R72**「02、04 都沒有 `blkid`」是錯的:兩台都有 `/usr/sbin/blkid`(本輪 `command -v`)。用 hexdump 讀 UUID 不受影響,但 R 表要更正(96 的「blkid/od absent」註解也已經過時)。
- **§8**「意圖要格式 + p6 marker nonce」:只有 `--reset-intent` 寫入時會比對 nonce,95 讀意圖時只驗格式(而且不能驗:W1 之後 marker 就沒了)。要改寫成「實體持有者寫一個格式正確的意圖就能觸發全清;本來就能重燒卡,不擴大」。
- **§1.4 / §8** 的 `unknown` 上鎖依賴 p6 提示,p6 沒掛時是 fail-open(m4)。
- **§3** 的意圖檔有三個寫者(config-save 建立、95 W0 更新 attempts、95 W2 消滅)。時段互斥,可以接受,寫成「依時段分屬」即可(擁有權規則要求寫明)。

---

## 3. 作者點名項逐一回答

| 項 | 結論 |
|---|---|
| F0–F5 可撤銷 + 單一提交點 | ✅。F3 之前每一步都有撤銷;F3 之後只往前走。缺 helper respawn(m3)、跑 stage 1 時的前置(m1b) |
| 意圖 = 唯一提交點與唯一觸發 | ✅ 觸發唯一。但「fresh」的判定要綁槽(m1a) |
| `BATMAN_FIRSTBOOT=1` ⇔ fresh? | 等價於「**本槽** overlay 是第一次開機」:F4 之後、每一次 OTA trial 第一次開機(`95:296-297`)、被打斷的第一次開機重跑、出廠第一次開機。**不等價**於「F4 在意圖槽做完」→ m1。95 被重跑:只有斷電打斷時才會(95 一律 `exit 0` → 被刪,`boot:14`),這種情況 overlay 是重置後的新 overlay,無害。95 不會「被留著 armed」(與 96 的 bypass `exit 1` 不同,`96:64`) |
| W0 在 S11 重開(logd/dropbear 之前) | procd 在 STATE_INIT 會接受 reboot(`state.c:225`)✅;rcS 會繼續跑 → 要停住 `boot()`(m8);重開前 p6 沒掛 → 沒有 shutdown marker,下一次 boot-reasons 會記 UNCLEAN(正確);pstore 留在 RAM,warm reboot 後還在 ✅;計數器存放位置有問題(m2) |
| W1/W2 放在 LUKS/mount/閂/pstore 之前 | 位置對 ✅(`boot()` `:605` 的最前面)。守門要搬進 INITBODY(m7);95 step 3/3b 在 `boot()` 之前就對舊的 p6 動手(m7) |
| mkfs 時間 | ⚠️ 沒量。卡支援 discard(04:`discard_max_bytes` 170 GB、granularity 4 MiB);沒有 mke2fs.conf;procd 在 rcS 期間仍會 pet watchdog(uloop),逾時不是問題;要在 L16 實測並決定 discard(m7) |
| `apps/`→`apps.reset` vs guardian restore / firstload / dockerd | `restore_payload_guardians` 只掃 `$MOUNT/apps/*/`(`95:561-566`),`refresh_payload_config` 只動 `apps/<t>`(`:509`)→ `apps.reset` 不會被拉起 ✅。firstload 只看 `$APPS`(`:41`)✅。dockerd:04 沒有 live-restore(`/tmp/dockerd/daemon.json`),所有容器的 restart policy = `no` → dockerd 不會自己重啟容器 ✅;procd 停 dockerd 可能逾時 SIGKILL,shim 會留著,但 F5 reboot 會收掉,撤銷時也無害。cancel 的 `mv` 要加 `-T`(m9) |
| cancel 路徑 | 有 ✅;SD 標記一併刪 ✅;無回退槽寫明 ✅;時段寫法不一致(m9) |
| SD 標記 | ✅ device_id 比對 + F4 刪除 + 重置後 device_id 改變 → 不會迴圈;`any` 只在 dev-open,而 dev-open 會被 F4 清掉 ✅ |
| §6.4 caller=procd && upg=y | 對「區分 `-T` 與真的升級」✅(04 ota-trace 實證)。但 procd 的 `validate_firmware_image` 方法 + 殘留的 `upgraded` 也符合(m5);rc 條件(m5) |
| psk_replay(ECDH)vs §3.4 常數時間 6 次、§6 金鑰表 | 只有持擁有者加密私鑰的人能算 ✅;看過 QR 的人與攻陷的成員節點都算不出 ✅;固定 6 次 + 假第 2 則 + 等逾時符合 §3.4 MUST ✅;app 端要保存的東西(m10);一把金鑰兩種 key-agreement 用途(m10,可接受) |
| 96 上鎖提示 + 第 3 欄不被 `unknown` 覆寫 | 出口清單完整 ✅(我逐一對過 `96:64,67,71,91,93,185`);第 3 欄雙重語意(m4);bypass 也會上鎖 = 後果見 §6 |

---

## 4. 逐 actor

| Actor | v6 擋住 | 沒擋住 / 寫錯 |
|---|---|---|
| BLE 路人 | 第 1 則用錯 PSK → 假第 2 則 + 等逾時 ✅;拿不到 `node_cert` ✅ | 全域額度能被吃滿(協定 §8,已寫明);「最多佔一條」不成立(m10) |
| 只看過 QR 的人 | 算不出 `psk_replay` ✅ | — |
| 本機非 root | `state/` 0755 root、新檔由 root 以 tmp+rename 寫入 ✅;p5 沒掛、非 root 碰不到 ✅;`BATMAN_FIRSTBOOT` 只在 root 的 init 環境 ✅ | — |
| 攻陷的 provd | 觸發重置需要 owner-op ✅;cancel 需要 owner-op ✅;拿到 `psk_replay` 也只能取得 replay 角色 ✅ | — |
| 攻陷的 tenant | 只有 `apps/<t>` 的 bind mount,碰不到 `state/` 或 marker ✅;rename 不會跟著 symlink 走 ✅ | — |
| 前任擁有者 / 轉賣 | 正常路徑 p5、p6 mkfs + overlay(含 dot)✅ | trial 槽 / 跑 stage 1 時的競態讓前任 overlay 留下(m1);殘留資料的程度被寫得過強(m11);W 失敗時不上鎖(m6) |
| 買家(弱 BLE、回應遺失) | `psk_replay` 不需要快取的回應 ✅ | app 要先持久化 `node_cert`(m10) |
| legacy 02/04 第一次 OTA | stage 1 跑的是舊 image 的 `platform-ab.sh`(98 從 overlay 複製)→ 不寫 → 今天的規則 ✅ | — |
| 單台在家更新 / 整隊 OTA | `lastjoined` + L51 說明 ✅ | — |
| p5 壞掉的節點 | F3 失敗 → 撤銷 + 請換卡 ✅ | W2 失敗後計數器失效(m2) |
| p6 壞掉的節點 | 前置條件拒絕 → 只能重燒(已寫明)✅ | — |
| 實體 SD | 標記比對 device_id ✅ | 寫一個格式正確的意圖就能全清(m12,不擴大,但文件寫錯) |
| 我們自己 | 工具都先上機查過 ✅(`find -exec`、`hexdump`、`flock`、`jffs2reset`、`mkfs.ext4`) | W 階段沒留紀錄(m8);`reboot` 非同步(m8);R72 錯(m12) |

---

## 5. v5 發現核對(一條一行)

| v5 | 狀態 | 說明 |
|---|---|---|
| A5-M1 step≥4 觸發 | addressed | 只剩 p5 意圖一個觸發 |
| A5-M2 p5-dead 終點矛盾 | addressed | F3 失敗 → 撤銷 + 請換卡;F3 之後 p5 壞 = 雙重故障殘項 |
| A5-M3 mkfs 沒有一次性閂 | addressed | p5 mkfs = 完成;只在 W2 失敗的重試中才會重複 mkfs p6(有上限,但上限本身見 m2) |
| A5-m1 `-T` 寫檔 | addressed | 新的小問題見 m5 |
| A5-m2 tune2fs / 假時鐘 | addressed | hexdump UUID |
| A5-m3 slot_lock | partial | 不再宣稱持鎖 ✅;stage 1→stage 2 的空窗沒補(m1b) |
| A5-m4 R3 失敗繼續 | addressed | 改為撤銷 |
| A5-m5 fresh 判定、R5 | partial | `BATMAN_FIRSTBOOT=1` ✅,但它 ≠ 「F4 做完」(m1);R5 已收 ✅ |
| A5-m6 95 位置、規則、LUKS、Pi 3 | partial | 位置 ✅、規則文件 ✅、LUKS 前置 ✅;守門不在 INITBODY、3b 仍跑、discard 沒定(m7);Pi 3 的 `p5_never_seeded` 在重置後為真的語意沒處理(U6 延後,列後果) |
| A5-m7 psk_replay 綁定 | addressed | 改用 ECDH(owner_enc);app 端保存見 m10 |
| A5-m8 簽章額度 | partial | 每條連線分開額度 ✅;「最多一條」沒有根據(m10) |
| A5-m9 `.txn` 撤銷操作員 | addressed | 存變更前的值 + 寫明殘項 |
| A5-m10 96 出口 | addressed | 清單完整 |
| A5-m11 帶回家更新 | addressed | L51 |
| A5-m12 取消後果 | addressed | 寫明無回退槽;cancel 時刪 SD 標記 |
| B5-M1 step=4 重開清 p6 | addressed | 同 A5-M1;cancel 動詞已放行 |
| B5-M2 p5-dead marker 被清 | addressed | 同 A5-M2 |
| B5-M3 同一次開機兩次 mkfs | addressed | fresh 開機只呼叫一次 `boot()`(S11 連結當時不存在),而且 p5 最後才清 |
| B5-M4 `-T` 寫檔 | addressed | caller=procd && upg=y(m5 補 rc 與 ubus validate) |
| B5-M5 BLE 負測試違反 §3.4 | addressed | 假第 2 則 + 等逾時 + 固定 6 次 + 寫明 §8 界線 |
| B5-m1 工具 / 時鐘 | addressed | 但 R72 的 blkid 寫錯(m12) |
| B5-m2 slot_lock 擋不住 | partial | 同 A5-m3(m1b) |
| B5-m3 提示衰減、出口 | partial | 出口 ✅;第 3 欄雙重語意、99zz、p6 沒掛時 fail-open 都沒寫(m4) |
| B5-m4 SD 標記重跑 | addressed | 刪掉「無身分接受任何內容」;F4 刪標記 |
| B5-m5 lastjoined 誤判 | addressed | L51 + joinwatch 停用時退回 |
| B5-m6 psk_replay 界線、608B KDF | addressed | ECDH;D31 刪除;持 QR 的人不再能鎖住 replay |
| B5-m7 `.txn` | partial | fsync / 變更前值 / 背景 / `--on-join` 讓路 ✅;「p5 讀不到而 `.txn` 存在」時怎麼做沒寫 |
| B5-m8 開機 mkfs 守門 | partial | 規則文件 ✅、失敗時不掛舊 p6 ✅、LUKS ✅;`assert_not_system` 不在 INITBODY、3b 沒跳過(m7) |
| B5-m9 jffs2reset 失敗迴圈 | partial | attempts ≤ 3 ✅;計數器在 p5 上,寫不進去時沒定義(m2) |
| B5-m10 tombstone 格式 | addressed | 只剩一個格式 |
| B5-m11 stage 1 前提 | addressed | p6 已掛、sync、stale-fallback |
| B5-m12 R6 之後的 dot 檔 | open(列殘項) | v6 選擇列成殘項。建議 W1 時(fresh,便宜)對 `/overlay/upper` 再做一次 dot sweep 就能收掉 |

---

## 6. 使用者已定案事項的後果(不重開,只列)

- **U3 擁有權與 SSH 脫鉤**:重置後 = image 預設(04 是 `root:::`、`PasswordAuth=on`)→ 接上乙太網的人就是 root(#137)。W 失敗時,這和「秘密還在 p5」疊在一起(m6)。
- **U4 全清含身分**:新 QR 只能經 root 取得。hostname/SSID 依 MAC 產生,前後任擁有者可以被串起來。OTS 的 image tar 被 W1 清掉 → 重置後是沒有 OTS 的裸機(Q4 已定)。殘留資料的程度見 m11。
- **U1 608B 之後不重工**:`psk_replay` 依賴 608B 的 ECDH 輸出共享秘密(D33 ⚠️ #255)。如果槽設定成只能加密輸出,主機端要多做一次解密,協定不用改。
- **U6 3A+ 延後**:95(W1/W2 的守門、`p5_never_seeded` 在重置後為真 → Pi 3 的下一次開機會被當成工廠卡,允許改寫 MBR,`95:211`)、`platform-ab.sh`(m5)都是兩板共用,bcm2710 ❌。
- **96 bypass 也上鎖(A5-m10 的定案)**:對已認領的節點,`batman_bypass=1` 不再能當免 console 的救援入口,救援只能重燒卡。
- **Q5**:m1/m2/m3 的負對照可以在 loop 裝置或 bench 卡上用白箱做(tier-A),不必等 L16 的位置定案。
- **Q6**:BLE 認領測試會把 04 上鎖;裝 lab key 之後 key 登入還能用(U3)。L16 若在 04 跑,重置後又會回到空密碼。

---

## 7. 本輪唯讀探針(原始輸出摘要)

```
04 ota-trace S1 CHECK(最後 6 行):
  rc=1 caller=/bin/sh /sbin/sysupgrade -F -n /opt/batdata/ota.tar.gz upg=n
  rc=1 caller=/sbin/procd  upg=y          ← -F:procd validate rc=1,升級照樣進行
  rc=0 caller=/bin/sh /sbin/sysupgrade -n /opt/batdata/ota-202w2.tar.gz upg=n
  rc=0 caller=/sbin/procd  upg=y
  rc=0 caller=/bin/sh /sbin/sysupgrade -n /opt/batdata/ota-280.tar.gz upg=n
  rc=0 caller=/sbin/procd  upg=y
04 batman-slot active=B, is-trial rc=1;boot-reasons 最後一行 boot_id=61327849 = /proc/sys/kernel/random/boot_id 前 8 碼
02/04 分割:p1 bootA, p2 rootA(3145728), p3 bootB, p4 rootB(3145728), p5 config(1048576), p6 data
  cmdline root=PARTUUID=…-000000000004;overlay = loop on /mmcblk0p4,offset 04=113442816、02=112656384;f2fs nodiscard
02/04 command -v:blkid ✅ /usr/sbin/blkid、tune2fs MISSING、mkfs.ext4 ✅、jffs2reset ✅、flock ✅、hexdump ✅;04:cryptsetup MISSING、timeout MISSING、fstrim MISSING
04 busybox mv:Usage: mv [-finT] …  -T Refuse to move if DEST is a directory
04 dockerd:data_root=/opt/batdata/docker;daemon.json 無 live-restore;5 個 OTS 容器 RestartPolicy=no
04 /etc/mke2fs.conf:No such file;mke2fs 1.47.0;mmcblk0 discard_max_bytes=170519429120 granularity=4194304(SN32G)
04 /opt/batdata/state:drwxr-xr-x root;內容 lock-status mesh-expected mesh-joined slot-A/B.protected(沒有 prov-state:spike build)
02/04 fstab:auto_mount=1、anon_mount=0(只掛 /overlay 的 uuid → 不會自動掛 p5/p6)
rc.d 順序:S10boot S10system S11batdata-mount S11fstab S11sysctl S12…log S12rpcd … S19dropbear
procd system.c:848 UBUS_METHOD("validate_firmware_image") 與 :849 "sysupgrade" 都走 validate_firmware_image_call():660 fork / :683 execl
procd state.c:225 if (state >= STATE_SHUTDOWN) return; → STATE_INIT 期間可以 reboot
base-files etc/init.d/boot:14 ( . "./$(basename $file)" ) && rm -f "$file"
fstools jffs2reset.c:49-55 find_mount_point(v->blk) → PENDING + overlay_delete;否則 jffs2_mark(deadc0de)
```

---

## 8. 判定

**APPROVE-WITH-CHANGES**

- BLOCKER **0**,MAJOR **0**,MINOR **12**(m1–m12)。
- 實作 PR-P1 時必須帶上:m1(意圖綁槽 + 跑 sysupgrade 時的前置)、m2(計數器寫不進去 = stuck)、m3(helper 啟動時續做 F4–F5)、m6(resetting 上鎖或寫明理由),各自附負對照。m4、m5、m7–m12 在實作與文件裡修。
- 恢復出廠機制已經收斂,不需要第 7 輪設計審查;下一個把關點是 PR-P1 的 code review(兩位)加上 L16 的實機負對照。
