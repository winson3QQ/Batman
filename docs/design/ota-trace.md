# OTA flight recorder (ota-trace) — #209 S5

> **Status (2026-10-03): phase 1 implemented** — §3 writer + isolation rules, §4 stage-2 recorder,
> §5 SLOT trace, §7 boot-reasons graded by evidence, §8 BOOT facts line, §9 HTTP (bundle + `last_s2`
> / `last_arm` in the status JSON), daily suite `ota-trace-209`.
> **§6 (automatic verdict classes in `last_ota`) is deferred to phase 2**: the second independent
> review found it still NEEDS-REWORK — M1 adjacency needs positive evidence (a trial interrupted, a
> life that died before S11 or with p6 unmounted leaves no boot-reasons line), M2 marker lifecycle
> (terminal verdicts must clear markers; disarm/stage-root must clear `ota-armed`; manual apply and
> Pi 4 blind arm need rows; a catch-all row), M3 ordered first-match + the exact order inside
> batdata-mount boot(), M4 hold / manual commit outcomes. Phase 1 needs no state markers at all, so
> none of those failure modes exist; the raw evidence (S2 END rc, ARM SET/GET, BOOT dt_tryboot)
> already separates "arm refused" from "armed but not taken" from "stage 2 died".
> Phase-1 extras from the reviews: everything stage 2 needs is exported (`OTATRACE_FILE`); the lib
> rides in `RAMFS_COPY_DATA`; the default trace path is used only while p6 is really mounted.

# OTA flight recorder(ota-trace)設計 v2 — #209 S5

日期 2026-10-03。v1 經獨立對抗式 review → APPROVE-WITH-CHANGES,2.4/2.5 UNSOUND;本版全部納入(§9 對照),並依 review 建議縮成「最小核心」。

## 0. 目的與觸發事件
使用者:「出事了才可收斂」。manet03 第 6 次 OTA:B 寫好、驗證過、BAD 已清、cmdline 正確,但重開 DT tryboot=0、partition=2,開回 A。現有紀錄無法區分:
(a) apply 的 arm 讀回失敗而 die(BAD 已清、cmdline 已寫 → 狀態完全吻合)→ platform_do_upgrade return 1 → **stock do_stage2 不看 rc,照樣 reboot -f**;
(b) 旗標設上了,但 `reboot -f` 路徑或韌體沒採用;
(c) stage2 在 arm 之前就死了(但 BAD 已清 → 不太可能)。

## 1. Reality check(03 上已查證)
- do_stage2:`platform_do_upgrade "$IMAGE"` 之後不檢查 rc,`umount -a; reboot -f`。✅
- `/usr/libexec/validate_firmware_image` 也呼叫 `platform_check_image`(LuCI 上傳、`sysupgrade -T`、ubus)。✅ → stage1 不得寫任何狀態檔。
- `/proc/sys/kernel/printk_devkmsg = ratelimit`。✅ → kmsg 每步只寫一行摘要。
- busybox **沒有 `timeout`**。
- 韌體 log:`vclog -m` 可用,從 start.elf 開始,有 `boot-part: N` 與讀到的 cmdline;**沒有 bootcode 階段的 tryboot 判斷** → 只能當旁證。DT `chosen/bootloader/{boot-mode,partition,rsts,tryboot}` 可讀。PM_RSTS 即時值不可得(不假裝有記)。
- throttled 在 ramfs 用 `vcmailbox 0x00030046 4 4 0`(03 回 `0x00050000`)。
- manet02 ramoops 不保存(#173)→ stage2 必須直寫 p6。

## 2. 最小核心(只做這些)
1. **S2**:stage2 全程 trace(含 `S2 END rc=`),wrapper 保證。
2. **SLOT**:只 trace 改狀態的指令(stage-root / apply / commit / rollback)與 die 原因;arm 的原始 SET/GET。
3. **BOOT**:每次開機一行韌體事實。
4. **裁決**:batdata-mount 每次開機對帳,分類寫進 autocommit.log(→ `last_ota`)。
5. **boot-reasons 證據分級**。
6. **AC**:只記啟動事實、第一次失敗原因、裁決。
**延後**:95 的 trace、AC 逐轉換、stage1 狀態。

## 3. 寫入函式與隔離規則(review MUST-FIX 2)
`/usr/lib/batman/otatrace.sh`(只定義函式,頂層無副作用;stage2 由 **RAMFS_COPY_DATA** 帶入):
```
otalog(){  # <stage> <event> [k=v ...] — NEVER affects the caller
  ( f=${OTATRACE_FILE:-/opt/batdata/log/ota-trace.log}
    line="$(date +%Y%m%d-%H%M%S 2>/dev/null) boot=$(cut -c1-8 /proc/sys/kernel/random/boot_id 2>/dev/null) up=$(cut -d. -f1 /proc/uptime 2>/dev/null) $*"
    [ -d "${f%/*}" ] && { echo "$line" >> "$f"; sync; }
    case "${OTATRACE_KMSG:-}" in 1) echo "batman-ota: $line" > /dev/kmsg ;; esac
  ) </dev/null >/dev/null 2>&1 || :
}
```
- 一律 subshell,stdin/stdout/stderr 全導走,`|| :`;函式內只用自己的變數(subshell 隔離 `set -u` 與全域變數)。
- 載入:`[ -f /usr/lib/batman/otatrace.sh ] && . /usr/lib/batman/otatrace.sh; type otalog >/dev/null 2>&1 || otalog(){ :; }`。
- **插入規則(寫進檔頭並由測試檢查)**:
  1. 先存 rc 再 trace:`cmd; rc=$?; otalog …`——不准插在指令與 `$?` 之間;
  2. 不准當「回傳值會被判斷」的函式最後一行(`real_tryboot` `held` `expected_in_mesh` `power_ok` `is_trial` `slot_is_bad` `main_alive` …);
  3. 擷取 stdout 的函式內不准呼叫(`health_ok` `fw_part` `ab_section` `committed_fw` `canary_run` `stage-root` 的輸出路徑);
  4. Pi3 p7 單磁區寫入窗內不准(在 power_ok 之前、讀回之後才寫)。
- kmsg:只有 `OTATRACE_KMSG=1` 的少數「摘要行」送 kmsg(每次 OTA ≤ 8 行:S2 BEGIN/END、SLOT ARM、ARM-FAIL/DIE、BOOT、VERDICT),避開 ratelimit;完整資料只寫檔。
- 大小:檔 > 256 KiB 時,batdata-mount 開機時 `tail -n 1500 → tmp → mv`。

## 4. S2(review MUST-FIX 3)
- 開機時 batdata-mount 把實際的 p6 裝置寫到 `/tmp/batdata.dev`(LUKS 時是 mapper;/tmp 會被 supivot 帶進 ramfs)。
- `platform_do_upgrade` 改成 wrapper:
```
platform_do_upgrade(){ ota_s2_open; _ab_do_upgrade "$@"; rc=$?; ota_s2_end "$rc"; ota_s2_close; return $rc; }
```
- `ota_s2_open`:讀 `/tmp/batdata.dev`、先驗 ext4 magic(hexdump),**背景 mount + 輪詢 10 s**(busybox 無 timeout:`mount … & p=$!; n=0; while kill -0 $p && [ $n -lt 10 ]; do sleep 1; n=$((n+1)); done; kill -0 $p && { kill -9 $p; 放棄 }`)。成功 → `OTATRACE_FILE=/tmp/p6t/log/ota-trace.log`;失敗 → 只走 kmsg。寫 **`ota-pending`**(見 §6)。
- `ota_s2_end`:`S2 END rc= armed=<最後 GET 原始值> throttled=<vcmailbox> secs_since_arm=`,**在此再 GET 一次 tryboot**(盡量靠近 reboot)。
- `ota_s2_close`:sync;背景 umount + 輪詢 5 s(卡住就放著,`reboot -f` 會 sync)。
- 每一步:SoC gate 結果、stage-root rc、串流 dd rc + 秒數、apply rc(apply 自己的細節在 SLOT 行)。

## 5. SLOT(只改狀態的指令)
- 每個 die → `die()` 內先 `otalog SLOT DIE cmd=<指令> msg=…`(subshell,不影響 exit code)再 exit。
- apply:begin_write 的 disarm GET、clear_root rc、寫入 rc、verify 結果(不符檔名)、cmdline 讀回、BAD 清除、**ARM:SET 原始回應 + rc、GET 原始回應、`[all]/[tryboot]` 內容、fw_part(T)、throttled(vcmailbox)**;GET=1 後寫 **`ota-armed`**(含 target、version、GET 原始值;manual apply 也會寫)。
- commit/rollback:power_ok 的取樣值(在 power_ok 之前)、寫入後讀回的 `[all]/[tryboot]`(讀回之後)——p7 寫入窗內不寫。
- read-only 指令(is-trial / verify / layout / fw-part / precheck-node / active / target)**不寫 p6**。

## 6. 標記與裁決(review MUST-FIX 1/4/5 — 取代 v1 的 2.4)
**標記(都在 `/opt/batdata/state/`)**:
- `ota-pending`:stage2 進入時寫(stage1 / validate 永不寫)。內容:`target= version=<payload metadata> from_boot= from_slot=`。
- `ota-armed`:apply 讀回 GET=1 後寫。內容:`target= version= get=<raw> from_boot=`。
- trial 開機時(batdata-mount 判斷 DT tryboot=1 且 running=target)在 pending 追加 `trial_boot=<本次 boot_id>`。

**裁決**(batdata-mount `boot()`,每次開機必跑,早於 autocommit 的 skip-once / is-trial 退出;autocommit 只讀結果):
前提:pending 的 `from_boot` 必須是 **boot-reasons.log 裡緊鄰本次的上一筆 boot_id**(新舊 image 都寫這個檔);否則 → `STALE`(只寫 trace,不寫 autocommit.log),刪標記。
| 條件(本次開機)| 裁決 |
|---|---|
| pending 有、armed 無、S2 END rc≠0 | `NOT-TRIALLED/APPLY-REFUSED (reason=<S2/SLOT DIE 最後一行>)` |
| pending 有、armed 無、無 S2 END | `NOT-TRIALLED/STAGE2-DIED (last=<最後一行 S2/SLOT>)` |
| armed 有、DT tryboot=0、running≠target | `NOT-TRIALLED/ARMED-BUT-FW-IGNORED (arm_get=… end_get=… rsts=…)` |
| armed 有、DT tryboot=1、running≠target | `TRIAL-FW-FALLBACK (partition=… rsts=…)`(Pi4 PARTITION_WALK) |
| running=target、DT tryboot=0 | `RAN-TARGET-WITHOUT-TRYBOOT (#133 stale fallback)` |
| running=target、DT tryboot=1 | `TRIAL-STARTED`(記 trial_boot;保留 pending 給 autocommit 的 COMMITTED/REVERTED 收尾)|
| pending 已有 trial_boot、本次不是那個 trial、autocommit.log 無該 trial 的 COMMITTED/TRIAL-REVERTED | `TRIAL-INTERRUPTED (trial_boot=… prev=<boot-reasons 分類>)`;若上一輩子 console-ramoops 的 cmdline 是 `batman_slot=<target>` → `TRIAL-BOOTED-DIED-EARLY` |
| autocommit 寫了 COMMITTED / TRIAL-REVERTED / HOLD-CONSUMED | 由 autocommit 刪 pending/armed(結案)|
- 版本比對:`TRIAL-STARTED` 時 pending.version 必須等於 `/etc/batman-build` 的版本,不等 → `STALE`。
- ab-selftest:它寫 skip-once;裁決看到 skip-once 存在 → 結果只寫 trace(`SELFTEST`),不寫 autocommit.log。
- 降版到沒有本機制的舊 image:舊 image 不讀不寫標記 → 回到新 image 時 from_boot 不相鄰 → `STALE`,清掉;不會誤配。
- 寫進 autocommit.log 的格式:`<ts> OTA-<裁決> boot=<本次> target=… version=… <細節>` → 狀態頁 `last_ota` 直接顯示。

## 7. boot-reasons 證據分級(review MUST-FIX 6 — 取代 v1 的 2.5)
優先序:`PANIC`(pstore)> 以下 > 原 `UNCLEAN`/`CLEAN`。
- 上一輩子有 `S2 END`(p6 trace 或 ramoops 的 `batman-ota:` 行):`SYSUPGRADE-REBOOT (rc=… armed=…)`,後面**保留**原 UNCLEAN 的文字與 hints。
- 有 `S2 BEGIN` 無 `S2 END`:`DIED-IN-STAGE2 (last=…)` + 原文。
- 其餘不變。不再用「pending 存在」推論。

## 8. BOOT 行(每次開機,batdata-mount)
`BOOT slot=<cmdline batman_slot> ver=<batman-build> dt_tryboot=<hex> dt_partition=<hex> dt_rsts=<hex> dt_bootmode=<hex> get_now=<vcmailbox 原始值> ab_all= ab_try= throttled= fw="<vclog -m 裡 boot-part 那行>" prev=<boot-reasons 分類> devkmsg=<printk_devkmsg>`
- Pi3 加:p7 autoboot.txt 所在磁區 sha256 前 12、bootcode.bin sha256 前 12。
- Pi4 加:EEPROM 版本(`vcgencmd bootloader_version` timestamp)、`BOOT_ORDER`、`PARTITION_WALK`。
- 上一輩子跑哪個 slot:從剛搬進 crash/ 的 console-ramoops 找最後一個 `batman_slot=`(有才記)。

## 9. HTTP
bundle(feed + deploy 兩份):+ `log/ota-trace.log`(最後 400 行)+ `state/ota-pending`、`state/ota-armed`。status JSON:`last_ota` 不變(來源仍是 autocommit.log,現在含 OTA-* 裁決),+ `ota_pending`(escape)。

## 10. 失效模式
| 情境 | 結果 / 對策 |
|---|---|
| otalog 出錯 / 未設變數 / 往 stdout 印字 / 卡住 | subshell + 導走 + `|| :`;**惡意 stub 測試**(§11) |
| 插在 `$?` 前 / 函式最後一行 / 擷取 stdout 的函式內 | 規則 + 測試 grep 檢查 + 惡意 stub 測試 |
| kmsg ratelimit | 每次 OTA ≤ 8 行 kmsg;BOOT 行記 devkmsg 值 |
| stage2 mount p6 卡住 | 背景 + 輪詢 10 s,卡住就放棄,不阻塞升級 |
| p6 滿 / 唯讀 | append 失敗靜默;OTA 結果不變(測試)|
| validate-only 呼叫 check_image | stage1 不寫任何標記 |
| 舊 image 降版 | 不相鄰 → STALE |
| p7 寫入窗 | 窗內不寫 |
| LUKS | `/tmp/batdata.dev` 指 mapper |

## 11. 測試(重 build 後整份計畫從頭重跑,另加)
1. **儀器不得改決策**:otatrace.sh 換成四種惡意 stub(`exit 1`、引用未設變數、印字到 stdout、`sleep 30`)→ 跑 ab-card-invariants、batman-slot 的 T1–T8 注入集、autocommit dry-run:結果與 exit code 必須和無 trace 時完全相同。
2. stage2 p6 mount 失敗(fault flag `s2-nomount`)、p6 滿 → OTA 結果不變,trace 只在 kmsg/ramoops。
3. 每次 OTA 後 bundle 的 trace 必含 S2 BEGIN→SLOT ARM→S2 END→BOOT→VERDICT 整條鏈。
4. 製造每一類裁決:APPLY-REFUSED(`tryboot-get` flag)、STAGE2-DIED(`die-mid-apply` 之前就停的 seam)、正常 TRIAL-STARTED→COMMITTED、TRIAL-REVERTED、STALE(手放一個不相鄰的 pending)、`sysupgrade -T` 不留 pending。ARMED-BUT-FW-IGNORED 靠自然發生 + 統計。
5. boot-reasons:sysupgrade 重開顯示 SYSUPGRADE-REBOOT。
6. 02:確認 p6 直寫補上 ramoops 缺失。
7. **tryboot 統計**:trace 落地後在 03 連跑 N ≥ 20 次 OTA,量 arm 成功率與 tryboot 生效率;對照 ab-selftest 的 SET + procd reboot。
8. daily-validation 新 suite `ota-trace-209`(此 image 尚未 OTA 過 → `na`)。

## 12. v1 review 對照
MUST-FIX 1 pending 不在 S1 → §6;2 隔離規則 → §3;3 stage2 防卡死/wrapper/LUKS → §4;4/5 對帳重設計、分類、搬到 batdata-mount → §6;6 boot-reasons 證據分級 → §7;7 kmsg ratelimit → §3;8 只 trace 改狀態的指令 → §5;9 惡意 stub 測試 → §11。SHOULD-FIX:deploy 副本同步、`na` → §9/§11;95 trace 延後;AC 精簡;throttled 用 vcmailbox;N≥20 統計 → §11.7。資料點:S2 END rc、arm 細節、結尾再 GET、BOOT 欄位、上一輩子 slot → §4/§5/§8;韌體 log 只當旁證、PM_RSTS 不可得 → §1。
