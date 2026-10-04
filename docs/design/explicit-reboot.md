# 設計 v2:Pi 4 重開帶明確分割區 + 開機自我檢查 — #209 S5(EEPROM 2026-09-23 把 raw PM_RSTS 當分割區號)

日期 2026-10-03。v1 經獨立對抗式 review → APPROVE-WITH-CHANGES(D2 需改架構再複審);本版納入全部 MUST-FIX(§9 對照)。前提(使用者):EEPROM 維持 2026-09-23。

## 0. 證據與機制(02/04 實機 + 上游)
- 分割區號在 PM_RSTS 偶數位元(bit0,2,…,10;遮罩 0x555)。Linux bcm2835_wdt 重開時先清這些位元再寫入參數 N(無參數 = 0)。
- **bug:參數 0 時,bootloader 有機率把「上一次的 raw PM_RSTS 低 6 位」當分割區號再展開**:0x20→32(0x420)、0x24→36(0x430)、0x430→48(0x520);因 HADWRF(bit5)每次都在,**錯誤號碼必 ≥32**。號碼不存在 → 跳過 autoboot.txt → PARTITION_WALK 落 p1。上游同類:rpi-eeprom 2025-10-08。
- 一般 `reboot` 5/10 錯開;`reboot -f`(參數 0)同樣中(0x430→0x520);**明確 N:10/10 正確**(rsts 0x24)。tryboot(mailbox 旗標 + stage2 `reboot -f`)~25/25 正確。斷電上電 rsts 0x1000(HADPOR)正確。
- **只在 [all]=2 時造成錯開**(walk 落 p1;[all]=1 時剛好對)。Pi 3 無此 bug。
- 節點事實:K* 最後一支是 K90umount(`umount -a -d -r`);docker 不在 K* 內(由 procd 最後的 kill 收尾);`kernel.panic=3`、`panic_on_oops=1`。
- 已知未解:`reboot -f` 非 tryboot 後一次「早期停住」(原因未知,02 ramoops 不保存)。

## 1. 目標
受控重開(我們發起、要回 [all])必定開對;不受控重開(panic、看門狗、網頁/CLI `reboot`、`reboot -f`)錯開時,**在開機極早期**(S11)用明確分割區修正一次;**被錯開的槽絕不 commit**;Pi 3 行為不變。

## 2. 元件
### D1 `batman-reboot`(新套件,C,static)
`batman-reboot <N>`:N 必須是 1..31 的十進位,否則 exit 2;`sync(); reboot(RESTART2, "N")`。呼叫端負責確認 N 是本卡合法 fw 分割區(Pi 4:1/2)。進 `batman-provision` DEPENDS、`RAMFS_COPY_BIN`、image manifest gate(兩板必含)、autocommit 必要檔檢查。

### D2 受控重開:procd 照常關機,只換最後一步
- `batman-slot reboot committed [reason]`:
  1. 僅 Pi 4 版面;Pi 3 → 直接一般 `reboot`(Pi 3 無 bug,且 hybrid MBR 上的 reboot N 未驗證)。
  2. tryboot 已 arm(GET=1)→ **不帶參數**,一般 `reboot`(保持原 trial 行為;明確 N + tryboot 從未驗證)+ 記錄。
  3. N = `ab_section all`,必須 ∈ {1,2}。
  4. 寫 `otalog_k REBOOT to=N reason=…`(此時 p6 還掛著)與 `/tmp/shutdown.reason`。
  5. 寫旗標 `/tmp/batman-reboot.want`(內容 N)。
  6. `setsid` 一個保底:240 s 後節點仍在 → `batman-reboot N`。
  7. 呼叫一般 `reboot`(procd 跑完整 K*:存 log、寫 shutdown.marker、卸 p6 …)。
- `/etc/init.d/batman-reboot`(STOP=90,名稱排在 K90boot/network/sysfixtime/umount 之前):`stop()` **只在旗標存在時**動作,否則什麼都不做(poweroff/halt、batpower 低電關機都不受影響):
  1. 讀 N,再驗一次 ∈ {1,2} 且 GET≠1;不符 → 刪旗標、返回(走原本流程)。
  2. 依序做被跳過的事:`/etc/init.d/sysfixtime stop`(保存時鐘)、`kill -TERM -1` → 等 3 s → `kill -KILL -1`(等同 procd 收尾,停 docker/postgres)、`sync`、`umount -a -d -r`。
  3. `exec batman-reboot N`。失敗 → 返回,procd 走原本 reboot(參數 0,D5 接手)。
- 呼叫點:batman-autocommit revert、joinwatch AUTOREBOOT → `batman-slot reboot committed`。操作員文件改用此指令;網頁/`reboot` 交給 D5。

### D3 stage2 失敗路徑(D4 in v1)
`platform_do_upgrade` 結尾:Pi 4 版面且 `ota_get` ≠ 1(apply 被拒或驗證失敗,沒 arm)→ `sync; batman-reboot <[all]>`(從 /boot/autoboot.txt 讀;合法才用),不回到 stock 的 `reboot -f`。成功(GET=1)維持原狀(tryboot 路徑 ~25/25)。

### D4 開機自我檢查(S11,batdata-mount boot())
- 只在 Pi 4 版面、且 `/proc/device-tree/chosen/bootloader/{rsts,partition,tryboot}` 都存在時判斷。
- `p_req = unspread(rsts & 0x555)`(bit2k → 2^k)。
- **bug 判定**:`tryboot == 0` && `p_req ≥ 32` && `partition ≠ [all]` && `[all] ∈ {1,2}`。
  - `p_req` 是合法 fw 分割區但 ≠ partition → 真的 walk(那個槽開不起來)→ 原 #133 邏輯,不重開。
  - `p_req == 0` → 原 #133 邏輯。
- bug 成立:
  - p6 已掛:計數 `state/fw-override-count` +1(同時記 boot_id);落在 [all] 的開機歸零。計數 ≤ 2 → `otalog_k BOOT-FW-OVERRIDE …`、`aclog FW-OVERRIDE …`、sync、卸 p6、`batman-reboot [all]`(此時幾乎沒有服務在跑)。計數 > 2 → `aclog FW-OVERRIDE-STUCK`、寫 `/tmp/batman-fw-override`,不重開。
  - **p6 沒掛:只寫 `/tmp/batman-fw-override` + kmsg,不重開**(避免無上限迴圈)。
- 有 `/tmp/batman-fw-override` 時:
  - batman-autocommit:不 commit、不走 stale fallback commit;
  - `batman-slot precheck-node`:拒絕 OTA(「韌體錯開了槽」);
  - status JSON:`fw_override` 欄位。
- `state/fw-override.disable`(一次性,操作員刻意開另一槽時):存在就不判定並刪除。

### D5 bad-slot 標記
autocommit 決定 revert 時寫 `state/bad-slot`(槽 + 版本)。STUCK 時若跑的槽 == bad-slot → 永不 commit;否則允許原 #133 commit(避免永遠卡住)。commit 成功清掉。

### D6 遷移(review MUST-1,最重要)
- 舊 image(無 D4)在另一槽時,錯開到舊槽 → 舊 autocommit 會把它當 #133 commit(靜默降版)。
- 規則:第一個含 D4 的 image commit 後,**同版本再 OTA 一次到另一槽**;兩槽都含 D4 之前,status 顯示 `fw_override_protection: partial`(檢查另一槽 rootfs 是否有 `/usr/sbin/batman-reboot`:ro 掛載另一槽 squashfs)。
- 之後每個 image 必含 D4:image manifest gate + CI(batman-reboot、D4 判斷式存在)。
- daily suite 檢查兩槽皆受保護。

### D7 可觀測
BOOT 行加 `p_req`、`fw_override`;EEPROM `PARTITION=` 設定;daily suite `slot-integrity-209`:錯開但下一次沒回到 [all] = FAIL、STUCK = FAIL、`batman-reboot` 缺 = FAIL、兩槽未都受保護 = FAIL。

## 3. 替代方案
1. 只偵測後一般重試 —— 參數 0 再中 ~50%。否決。
2. `reboot -f` —— 同樣參數 0,且有早期停住。否決。
3. 自己跑 K* 的精簡關機(v1 D2)—— 會被 SSH/dropbear 的停止殺掉,順序錯。否決。
4. 官方佈局(p1 只放 autoboot)—— walk 仍落最低槽。否決。
5. EEPROM `[partition=32..63]` 條件段 / 降 EEPROM —— 改機台韌體 / 使用者否決。
6. **kernel patch:bcm2835_wdt 加 `default_partition`(sysfs),參數 0 時改用它,開機與 commit/rollback 時設成 [all]** —— 唯一能涵蓋 panic / 看門狗 / 網頁 / `reboot -f` 全路徑的修法;要重編 kernel,驗證範圍大 → **列為 v2(下一階段)**,並向上游回報。

## 4. 失效模式
| 情境 | 結果 |
|---|---|
| 從 SSH 發起受控重開 | procd 關機會停 dropbear,但重開由 K90 hook 完成,不依賴發起的 session |
| K90 hook 失敗 / batman-reboot 缺 | 返回 → procd 參數 0 重開 → D4 接手 |
| 保底計時器與 procd 同時 | batman-reboot 參數一致,誰先都對 |
| poweroff / batpower 低電 halt | 沒有旗標 → hook 不動作 |
| tryboot 已 arm | 不帶參數(原行為) |
| [all] 槽真的壞(韌體層開不起來)| p_req = 合法號 → 判為真 walk → 原 #133;不會重開迴圈 |
| 錯開 + p6 沒掛 | 不重開,標記不 commit,OTA 拒絕,等人 |
| 錯開到剛被 revert 的壞槽 | D4 重開回 [all];STUCK 時 bad-slot 永不 commit |
| 舊 image 槽 | D6 規則 + 狀態顯示 partial |
| 硬體看門狗逾時 / panic | 參數 0 路徑 → D4 接手 |
| Pi 3 | D2 一般 reboot、D4 不判定 —— 行為不變 |

## 5. 驗收(兩台 Pi 4 + Pi 3,記錄器全程;通過才算穩定)
- 受控重開 ≥ 50/台(含 ≥10 次從 SSH 互動 session、≥10 次 04 跑 OTS 時):0 錯開、0 停住;04 postgres 無 "not properly shut down"。
- autocommit revert(trial 在 A、在 B 各半)≥ 20/台:0 錯開、被 revert 的槽 0 次被 commit。
- 不受控一般 `reboot` ≥ 30/台:每次在 ≤1 次修正內回 [all];0 錯 commit;0 STUCK。
- panic(sysrq-c)≥ 10/台;硬體看門狗逾時(停餵狗)≥ 5/台:同上。
- OTA 成功路徑 ≥ 50 合計;失敗路徑(注入驗證失敗)≥ 10:0 錯、0 停住。
- 遷移:舊 image 槽情境可觀察 + partial 顯示正確;兩槽升級後 protected。
- 錯開狀態下 OTA 被拒;p6 沒掛的錯開不重開(注入)。
- Pi 3:全套回歸,行為不變。
- 任一停住 → 停止、收證據,不帶已知失敗進 release。
- 做不到的:真斷電(等智慧插座)→ 標 ⚠️。

## 6. v1 review 對照
MUST-1 遷移 → D6;MUST-2 遮罩 0x555 + p_req≥32 → D4;MUST-3 p6 沒掛不重開 → D4;MUST-4 D2 不被 K* 殺 → procd 關機 + K90 hook;MUST-5 log 在卸 p6 前 → D2 step 4;MUST-6 tryboot 已 arm → D2 step 2、hook step 1;MUST-7 1..31 + 合法號 → D1/D2;MUST-8 stage2 失敗路徑 → D3。SHOULD:Pi 3 不改、旗標觸發不影響 poweroff、bad-slot、kernel patch 列 v2、CI/manifest、D5 放 S11、precheck-node 拒絕、joinwatch(S11 就重開,joinwatch 尚未啟動,不入帳)。

## 7. Second review (v2 → implementation constraints, all applied)
Verdict APPROVE-WITH-CHANGES; implemented as: the self-check sits after crash capture / boot-reasons /
BOOT line and before payload start, writes a FW-OVERRIDE shutdown marker before its restart, re-mounts
p6 and continues (marked) if the restart fails, never restarts during a first boot's uci-defaults
(deferred to batman-autocommit at S99); tryboot flag read as 1/0/unknown (`bf_get`), unknown keeps the
old behaviour everywhere; the K90 hook is a plain rc.common script (no USE_PROCD), `trap '' TERM`,
builtin `kill -1` at the top level, dockerd stopped through its init before the kill (procd would
respawn it within 5 s), well inside procd's 15 s + 10 s budget; STUCK never commits; a stale fallback
commits only when p_req is 0 or [all] and the slot is not the one autocommit reverted (state/bad-slot);
batpower drops a pending controlled-reboot flag before its halt. Acceptance adds ≥50 forced
self-check restarts per Pi 4 (seam: p6 state/fault.fw-override-once) — 0 hangs required.
