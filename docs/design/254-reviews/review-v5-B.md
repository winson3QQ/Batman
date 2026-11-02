# #254 階段 1 實作設計 v5 — 獨立審查 B(第 5 輪,對抗式)

審查對象:`docs/design/254-stage1-impl.md` v5(branch `design/254-stage1-impl` @ e4e7177),**連同** v5 寫「同 v4」所繼承的 `254-reviews/254-stage1-impl-v4.md` 各節,整份審。
依據:使用者 CLAUDE.md 的設計審查規則、`docs/design/REVIEW.md`。全程唯讀:節點上只跑 `ls/cat/find … -exec echo`/`mount`/`command -v`/`batman-slot active|is-trial`;沒有寫入、沒有 reboot、沒有 commit、沒有跑 bluetoothctl。

## 0. 結論

**判定:REJECT**(0 BLOCKER / 5 MAJOR / 12 MINOR)。

v5 把機制真的減少了,而且方向大多對:
- 拿掉 S13 和開機時的 wireless 對帳;
- 凍結狀態搬到 p5 tombstone;
- `prov-txn` 在 rename 後就刪;
- `ota-armed.mesh` 綁 arm 那次開機的 boot_id;
- 拿掉匿名 NX。

OTA 閘、txn、replay 這三塊剩下的都是局部問題。

**恢復出廠這一塊還沒收斂**。每一輪都在同一個機制上長出新的 MAJOR:v3 沒有失敗政策;v4 是 `find -delete` 不存在、凍結只放在 p6;這一輪是:
1. 觸發 p6 mkfs 的條件「marker step ≥ 4」,在 p5 還沒清之前就已經成立。卡在 R4(v5 宣稱「可取消」)的時候只要重開一次,p6 就被格式化;mkfs 同時把 marker 一起清掉,恢復出廠就被悄悄忘記。
2. p5-dead 路徑完全靠 p6 marker,而 marker 被它自己觸發的 mkfs 清掉。結果和設計宣稱的「新身分可認領」矛盾(繼承的 rc 表規定這種情況是 `unknown`、不產生身分)。
3. 開機時的 mkfs 在 fresh 開機時會被呼叫兩次(95 在 S10,batdata-mount 在 S11),第二次會清掉這次開機已經存下的 crash/boot-reasons 證據。

另外兩條 MAJOR:
- `sysupgrade -T` 照樣會寫 `ota-armed.mesh`:validate 子程序的父程序就是 `/sbin/sysupgrade`。所以 L41 的負對照會 FAIL,A4-M2/B4-m5 宣稱的修正不成立。
- v5 的 BLE 負測試和協定 §3.4 / §8 的 MUST 互相矛盾。

## 1. 先補:缺的生命週期列與資源

| 缺的列 / 資源 | 為什麼 | 對應 |
|---|---|---|
| **停在 R4(rc 8 / rc 1、「可取消」)時斷電或重開** | marker 是 step=4,p5 還沒清 | B5-M1 |
| **R4 判 p5-dead 之後、R6 之前斷電** | 沒有 tombstone;marker 被 95 的 mkfs 清掉 | B5-M2 |
| **fresh R-boot 一次開機裡 boot() 跑兩次**(S10 由 95 呼叫,S11 由 rc.d 呼叫,`95-batman-storage:631,753`) | v5 寫「umount p6(若已掛)→ mkfs」 | B5-M3 |
| **R-boot 到 S89 之前 crash loop** / **R-boot mkfs 中途斷電** | tombstone 要等 S89 才清;每次開機都 mkfs | B5-M3、m8 |
| **`sysupgrade -T` 之後同一次開機直接 `batman-slot apply`** | `-T` 會寫檔(見 M4) | B5-M4 |
| **SD 觸發的重置,R5 刪標記失敗,或 R4–R6 間斷電後續做只重做 R6–R7** | 「無身分時接受任何內容」→ 重置再跑一輪 | m4 |
| **`jffs2reset` 失敗**(D18 仍 ⚠️) | 沒有設 PENDING → overlay 不是 fresh → 「重做 R6–R7」→ 重開迴圈 | m9 |
| **resetting 中擁有者要取消** | resetting 模式下 provd 只答 `status/public`,helper 回 `E_BUSY(resetting)` | B5-M1 |
| **#133 stale-fallback 開機進到還沒 commit 的 member 槽** | 綁定不符 → `joined` → 單台時永遠不 commit,而 REVERT=0 也不會 revert | m11 |
| 資源:`slot_lock` 的持有者辨識 | `batman-slot:88-89` 只認 cmdline 含 `batman-slot` 的 pid | m2 |
| 資源:`prov-state` 的 `<state>` 欄被 `unknown` 覆寫 | 96 拿它當上鎖提示 | m3 |

## 2. MAJOR

### B5-M1 — p6 mkfs 的觸發條件「marker step ≥ 4」在 p5 被清之前就成立:停在 R4 時重開一次 → p6 被格式化、恢復出廠被悄悄忘記,v5 宣稱的「取消可用 / 恢復原狀」不成立

**情境**:擁有者在 app 按恢復出廠。R4 寫 marker step=4,然後 `--wipe-all` 回 rc 8(有人掛著 p5;v5 會每 5 s 重試 12 次),或 rc 1。v5 說「停在 R4……取消可用」。這時發生兩件事之一:
- 擁有者以為節點卡死,拔電;
- 那 60 s 重試期間剛好斷電。

**下次開機會這樣走**:
1. batdata-mount(S11)掛上 p6,看到 marker step=4 ≥ 4,依 §4.5 R-boot 做 umount → `mkfs.ext4` p6。
2. OTS DB、憑證、docker image 和 volume 全部消失。p5(前任 prov、overrides)和 overlay 都沒動。
3. **marker 跟著 p6 一起被 mkfs 清掉**。tombstone 從來沒寫過。helper 在 S89 看不到任何恢復出廠的痕跡,照 `claimed` 正常開機。
4. 結果:節點還是前任的,tenant 資料沒了,app 不會得到任何「重置失敗 / 被取消」的狀態。

**證據**:
- v5 §3:marker 一列「95/batdata-mount(step ≥ 4 → mkfs p6)」。
- §4.5 R4:「marker step=4 → `--wipe-all`」;§4.3 `--wipe-all` 的前提是「marker step = 4」。所以 step=4 一定在 p5 被清**之前**寫入。
- R4 失敗政策:「rc 8 → … 停在 R4 … 取消可用」「rc 1 → 停、可取消」。
- 負對照 (e):「取消後恢復原狀」。

**取消路徑另外兩個問題**:
- (a) §1.4 / §4.1 規定 resetting 模式下 provd 只答 `status/public`,helper 對其他請求一律 `E_BUSY(resetting)`,所以 **owner-op 取消根本送不進來**。U3 之下民用擁有者通常沒有 SSH key,能用的只有 root CLI。
- (b) R3 已經 `invalidate-other`(v5 把它移到 R4 之前)。取消之後另一槽是 BATMAN-BAD、root 頭已清零,不是「原狀」:節點在下次 OTA 之前沒有後備槽。

**修法**:
- p6 mkfs **只認「不可回頭點之後」的狀態**:p5 tombstone,或者 R4 **成功(rc 0)或判定 p5-dead 之後**才寫的新 step(例如 step=5)。step=4 只表示「即將清 p5」,不得觸發任何破壞動作。
- §1.4 / §4.1 讓 resetting 模式允許 `factory_reset.cancel(owner_op)`。
- 「恢復原狀」改成「payload/joinwatch 恢復;另一槽已作廢,下次 OTA 會補回」。

**負對照**:白箱讓 `--wipe-all` 一直回 rc 8,在 R4 期間 `reboot -f` → 斷言 p6 的 `apps/` 還在、marker 還在、provd 回報 `reset step=4 p5-busy`。照 v5 的寫法,p6 會被清、marker 會消失。

### B5-M2 — p5-dead 路徑只靠 p6 marker,而 marker 被它自己觸發的 p6 mkfs 清掉;終點和繼承的 rc 表矛盾,負對照 (d) 過不了

**情境 A**:R4 回 rc 16(p5-dead),設計說「繼續」→ R5 → R6 前斷電。
- 下次開機 overlay 不是 fresh,所以 95 不跑。batdata-mount 讀不到 p5 tombstone(p5 壞了),看到 marker step=4 → mkfs p6 → marker 被清掉。
- 96 不跑(不是 fresh)。helper `--prov-get` 回 rc 1,overlay 的身分是完整的。依 v4 §4.2 的表,rc 1 + overlay 完整就是「沿用 overlay」。
- 結果:**節點悄悄回到前任擁有者的 claimed 狀態**,p6 被清空,另一槽被作廢,沒有人續做。

**情境 B**:R6/R7 都完成了。重開後是 fresh overlay,沒有 marker(已被 mkfs 清掉),也沒有 tombstone。
- helper 拿到 rc 1/12,overlay 沒有身分。v4 §4.2 的表對這個情況寫的是「`unknown(p5-unreadable)`……**不產生身分**」(v5 §4.2 沒有改這一列)。
- v5 R4 卻寫「下次開機是 `unknown` 但……**新身分在 overlay 可認領**」。就算真的產了身分,認領的 `--prov-only` 也寫不進壞掉的 p5 → `E_PERSIST` → 一樣不能認領。
- 所以負對照 (d)「兩次開機內 `unknown` + 新身分」照兩份文件合起來的規則**無法成立**。

**修法**(擇一,寫清楚):
- p5-dead 時,把 reset 狀態存在 overlay 以外、又能撐過 p6 mkfs 的地方。例如 95 在 mkfs 之前把 marker 讀進 `$RUNDIR`,mkfs 之後寫回新的 p6,改成 step=`p5dead`。helper 看到它就續做 R5–R7,並明定終點(建議:`unknown(p5-dead)`、不產生身分、`status/public` 回報「換 SD 卡」)。
- 或者**承認 p5-dead 是硬體維修情境**:R4 rc 16 時不繼續,先完成 R6/R7 清 overlay,再停在 `unknown(p5-dead)`;同時把「可認領」從文件拿掉。

**負對照**:白箱讓 p5 回 rc 16,分兩點斷電(R5 後、R7 後)→ 斷言不會回到前任狀態;終點和文件寫的一致。

### B5-M3 — 開機時的 p6 mkfs 沒有「每次開機一次」的保護:fresh R-boot 會在 S10、S11 各格式化一次,把這次開機已經存下的證據清掉;tombstone 清掉之前,每次開機都會重來

**證據**:
- `95-batman-storage:753`:fresh 開機時 95 在 S10 呼叫 `"$INIT" boot`。`:631` 的註解寫明「the first-boot hook calls `boot` itself and the S11 link may run it again」。
- 既有的每次開機一次的 guard(`$RUNDIR/batdata-mount.booted`,`:632`)放在 mount 和 resize **之後**。v5 的檢查是「p6 掛載**前**……umount p6(若已掛)→ mkfs」,所以 S11 那一次會在 guard **之前**又看到 tombstone(要到 S89 helper 才清)。

**後果**:
1. S10 寫好的這幾樣東西被 S11 清掉:
   - 本次的 `boot-reasons.log` 那一行(`:708`);
   - pstore 搬出來的 crash 紀錄(`:641-651`);
   - 96 寫的 `state/lock-status`;
   - 99zz 寫的 `prov-state`。
2. 之後 guard 已經存在,S11 不會補寫 boot-reasons 那一行 → **這次開機沒有紀錄**。
3. 如果 S10 之後有程式持有 p6 上的檔案,umount 會 EBUSY。`mkfs.ext4 -F`(單一 `-F`)會拒絕格式化已掛載的裝置(`batman-config-save:155` 的註解),於是走 crit。p6 處於什麼狀態沒有定義。
4. tombstone 要等 S89 才清。在那之前開機若 crash loop(kernel panic、helper 起不來),**每次開機都 mkfs p6**,上一輪的 crash 紀錄永遠留不到下一輪。這破壞了 #61 的 crash 擷取契約,而 crash loop 正是最需要那些證據的時候。每次還要多花 10–30 s(D30 ⚠️)。

**修法**:
- mkfs 前先檢查並寫 `$RUNDIR/batdata-mount.reformatted`,同一次開機只做一次。S11 看到 p6 已經掛著,就**不再** umount/mkfs。
- mkfs 前先把 `/sys/fs/pstore` 的內容留在原地(現在就是 mount 之後才搬),保證 mkfs 在 pstore 搬移之前。
- 寫明:mkfs 完成後,tombstone 存在的「同一 old_device_id」不再觸發 mkfs。例如 95 把 `old_device_id` 記到新 p6 的 `state/reformatted-for`,下次開機比對相符就跳過。這樣 crash loop 時證據可以累積。

**負對照**:
- fresh R-boot 開機後斷言 `boot-reasons.log` 恰好一行、`dmesg | grep -c 'p6 reformatted'` = 1;
- 白箱讓 S89 之前 panic 兩次,斷言第二次開機的 `crash/` 裡有第一次的紀錄。

### B5-M4 — `sysupgrade -T` 會寫 `ota-armed.mesh`:validate 子程序的父程序就是 `/sbin/sysupgrade`;L41 會 FAIL,`platform-ab.sh:74-75` 的不變式仍被打破

**證據**:
- firmware-2710 `package/base-files/files/sbin/sysupgrade:370`:`json_load "$(/usr/libexec/validate_firmware_image "$IMAGE")"`。`-T` 的 `exit 0` 在 `:403`,也就是 validate **之後**。
- `validate_firmware_image` 是 `/sbin/sysupgrade` 的子程序,它呼叫 `platform_check_image`。在這個子程序裡 `/proc/$PPID/cmdline` = `/bin/sh /sbin/sysupgrade -T <img>`,含有 `sysupgrade`。
- `platform-ab.sh:90-92` 自己的註解:「Only stage 1 (our parent is /sbin/sysupgrade)」。也就是說,這個判斷本來就區分不出 `-T` 和真的升級。
- v5 §6.4:「只在父程序是 `sysupgrade`」寫;L41:「`-T` 後檔案不存在」。

**後果**:
- `-T` 會留下 `<本次 boot_id> <target> radio|joined`。同一次開機之後若走 L42 的直接 `batman-slot apply` 並重開進 trial,倒數第二行 = 本次 boot_id → 檔案被採用。若內容是 `radio`,member 不要求鄰居 → **fail-open**。
- L42 宣稱的「無檔 → 要求鄰居」也就不成立。
- A4-M2 / B4-m5 的修正因此只完成一半。

**修法**:
- 只在真正要升級時寫:判斷 `$PPID` cmdline 不含 ` -T`/`--test`。更好的做法是在 stage 2 `batman-slot apply` **成功 arm tryboot 之後**,由 stage 1 留在 `$RUNDIR` 的暫存(會跨進 ramfs)搬到 `$RUNDIR/p6t`,這和 B4-m5 原本的建議一樣。
- 直接 `batman-slot apply` 要先 `rm -f` 這個檔。

**負對照**:`sysupgrade -T img` → 斷言 p6 沒有 `ota-armed.mesh`(照 v5 會有);`-T` 之後直接 apply → member trial 要求鄰居。

### B5-M5 — v5 的 BLE 負測試和協定的 MUST 互相矛盾:§3.4 規定失敗時要送假第 2 則並等到逾時;§8 有全域交握上限。「第 1 則即斷」和「路人 10 Hz 時擁有者 < 2 s」不可能同時成立

**證據**:
- `219-protocol.md:80`(MUST):PSK 都失敗時,「組出一則格式正確的第 2 則訊息……**和真 session 一樣等到逾時才斷線**」;`:408` 把「假第 2 則分辨得出」列為安全項。
- `:331-334`:交握逾時 10 s;**全域交握每分鐘 20 次**;未認證 session 閒置 30 s。
- v5 §4.1 負測試:「無 QR 的 central 對已認領節點做 NX / NXpsk0(錯 PSK)→ **第 1 則即斷**」,以及「路人 10 Hz 連線時擁有者 NXpsk0 交握 < 2 s」。

**後果**:
- 照協定實作:路人 10 Hz 會先吃滿每分鐘 20 次的全域額度,擁有者的交握會被 `E_RATE`;假 session 還會佔住連線直到逾時。B4-M7(DoS)宣稱的修正測不過。
- 照 v5 實作「第 1 則即斷」:違反 §3.4 的 MUST,而且變成一個能分辨「PSK 對不對」的 oracle。
- 另外,§3.4「固定試 5 次」沒有改成 6(加了 `psk_replay`)。這會造成時間差。

**修法**:
- 在 §1.3 / 協定 v0.7 明定:§3.4 改成固定 6 把;失敗時行為**照 §3.4**。
- DoS 的保證改成可以達成的版本:全域額度改成「每個來源位址各自計 + 擁有者保留額度」。注意 RPA 會換位址,所以真正能保證的只有「擁有者在路人停手後 N 秒內可連」。
- 或者把「< 2 s」降級為「量測值」,不當 PASS 條件。
- 負測試要改成符合協定的寫法:錯 PSK 收到等長的第 2 則、等到逾時才斷線、payload 裡沒有 `sn`/DAC。

## 3. MINOR

- **m1 — L16 的斷言又用了節點上沒有的工具(R62 同一類錯)**:04、02 實測 `tune2fs: MISSING`、`dumpe2fs: MISSING`(`blkid`、`e2fsck`、`resize2fs`、`flock`、`jffs2reset`、`mkfs.ext4` 都在)。另外時鐘是假的(R 表),所以「建立時間 ≥ 重置時間」沒有意義。改成比對 p6 superblock UUID(`blkid -s UUID`,或 `hexdump -s 1128 -n 16`)在重置前後不同。`prov-tools-254` 也要把 L16 用到的每個指令(含 `blkid`、`umount`)都列進去,缺一個就 FAIL。
- **m2 — 「R1–R7 持 `slot_lock`」實際上擋不住**:`slot_lock()`(`batman-slot:84-96`)只把 cmdline 含 `batman-slot` 的 pid 當作持有者。helper(`batman-provhelper`)持有的鎖會被當成 stale 而**接管**;R3 自己呼叫的 `batman-slot invalidate-other` 也會接管。stage 2(ramfs)看不到 p6 marker,所以 `sysupgrade -F` 在 R1–R3 期間只會被 stage 1 擋(`-F` 會忽略 stage 1 的拒絕)。修法:helper 在 R1–R3 期間也在 p5 留 intent,或者把 marker 抄一份到 `$RUNDIR`(stage 2 看得到),並寫實「鎖」的實際語意。
- **m3 — 96 的 p6 上鎖提示會失效,且有出口沒列到**:
  - 99zz(S10)和 helper 在 p5 讀不到時會把 `prov-state` 的 state 寫成 `unknown`,下一次 fresh 開機的提示就沒了。要規定「state 欄只用已知狀態覆寫;`unknown` 時保留上一次已知的 state(另加 `verdict=` 欄)」。
  - 96 的 bypass 出口(`:63-64`)與無 p5 出口(`:67`)沒有列進「每個出口前判上鎖」。
  - p6 沒掛時沒有提示 → fail-open,要寫明。
- **m4 — SD 標記「無身分時接受任何內容」和續做路徑合起來會讓重置再跑一輪**:R4–R6 之間斷電時,續做只「重做 R6–R7」,沒有 R5。重開後 overlay 與 p5 都沒有身分,所以殘留的標記被接受,又完整重置一次(p5、p6 再 mkfs 一次)。若 FAT 一直刪不掉,會無限重置。修法:helper `--boot` 先處理 rc 15,再讀 SD;拿 tombstone 的 `old_device_id` 當「本機身分」比對;續做包含 R5。
- **m5 — `joinwatch.lastjoined`(「本次開機曾經入網」)的兩種誤判**:
  - (a) member 在現場入網後沒有重開就帶回家更新 → `joined` → 在家 revert,L31「單台在家更新 → commit」只在重開過才成立(fail-closed,但寫明);
  - (b) `joinwatch.main.enabled=0`(`joinwatch:185`)時沒有這個檔,會退回 v4 的單次取樣(B4-M2 復發)。
  
  建議改成「最近 N 分鐘內 JOINED」,N 大於一次 OTA 週期(例如 30 min)。joinwatch 停用時一律寫 `joined`。
- **m6 — `psk_replay` 的界線與 608B**:
  - 持有 QR 的人(看過機身貼紙的維修行、拍到 QR 的人)能完成 NXpsk0、拿到 `node_cert`,能在一堆 RPA 裡認出這台機器。§1.3 寫「219:267 的防追蹤要求不變」是 overclaim,要寫成「僅限持 QR 者」。
  - helper 的 replay 失敗計數是每小時 10 次,持 QR 者可以一直把擁有者的 replay 鎖在外面。界線要寫明。
  - D31:不必依賴 608B 的 KDF 權限。建立身分時(file 後端由 helper 算;se 後端在工廠算)**預先算好 `psk_replay` 存進一個資料槽**,它的保密等級和已經存著的 `psk_owner` 相同。這樣 U1 的「不重工」不會被 #255 推翻。
- **m7 — `.txn` 的一次性對帳**:
  - 步驟 1 寫 `.txn` 之後要 fsync,才能做步驟 2(否則斷電後 uci 已 commit、`.txn` 卻不在);
  - 重開後 `prov-txn`(tmpfs)不見了,在 120 s 等待期間 joinwatch 一 JOINED,`--on-join` 就會把做到一半的 wireless 寫進 p5。`.txn` 存在時 `--on-join` 也要讓路;
  - 「改回 prov 的值」在第一次 join(claimed 時 prov 還沒有 net)和 `radio_managed=0` 時沒有定義。目標應該是交易前的值(`.stage` 裡留一份快照,或 p5 overrides);
  - 120 s 的等待不能擋住 `--boot`(它擋住的是 provd 和 `prov-state`);
  - p5 讀不到而 `.txn` 存在時怎麼辦,沒有寫。
- **m8 — 開機 mkfs 的守門與失敗處理**:
  - 95 的硬規則「pre-made data partition is NEVER formatted」(`95-batman-storage:37-39,297-301`)在 v5 只改了 config-save 的註解與 `p5-config-partition.md`,95 本身與 `201-firstboot-grow.md` 也要同步;
  - mkfs 放在產生出來的 init body,`assert_not_system`(squashfs、GPT 名稱、GUID)不在那裡。mkfs 前要再驗一次;
  - mkfs 失敗時要明定:**不得**重新掛上舊的 p6(否則前任資料又可見,guardian 會不會還原也沒定);
  - LUKS p6 沒處理:新 overlay 會產新 key(#111),開不起來。前置條件要像 p5 一樣拒絕;
  - fresh R-boot 時 95 的 step 3 / 3b 會先對要被清的 p6 做 `e2fsck -pf` 和 recover。mkfs 做到一半斷電時還會走 crit,`batman-storage.crit` 留到這次開機結束。tombstone 存在時應跳過這兩步。
- **m9 — `jffs2reset` 失敗沒有上限**:R6 的失敗政策寫「PENDING 下次開機仍會清」。可是 jffs2reset 失敗時根本沒有設 PENDING,下次開機 overlay 不是 fresh → helper「重做 R6–R7」→ 重開迴圈,而且每次都 mkfs p6。D18 自 v3 起一直是 ⚠️。04 實測 `/dev/loop0 on /overlay f2fs`(`find_mount_point` 會命中,mounted 路徑看來成立,但沒有實跑)。修法:R6 檢查 `/overlay/.fs_state` 是否變成 PENDING(1);不是的話自己 `find /overlay/upper -mindepth 1 -maxdepth 1 -exec rm -rf {} \;`,並限制續做次數。
- **m10 — tombstone 契約不一致**:§3 寫 `<old_device_id> <uptime>`,§4.3 寫只有 `<old_device_id>`。`--clear-tombstone` 一直失敗(p5 可讀不可寫)時,節點永遠不能認領,而且每次開機都 mkfs p6,沒有上限、也沒有 status。
- **m11 — stage 1 寫檔的前提**:要求 p6 已掛(否則會寫進 overlay 的 `/opt/batdata/state`,而 `rm` 成功,不會觸發「rm 失敗 → 拒絕」);rename 之後要 `sync`。#133 stale-fallback 開機(tryboot=0)進到還沒 commit 的 member 槽時,綁定不符 → `joined`;單台情況下永遠不 commit,REVERT=0 也不 revert。要寫明是接受,還是 stale-fallback 時改用「radio」。
- **m12 — R6 之後到 R7 之間新寫的 dot 檔會留下來**:例如操作員 SSH 登出時寫的 `/root/.ash_history`。PENDING 下次開機只刪非 dot 項目(R43)。修法:helper 在 rc 15 / fresh 的 R-boot 時對 `/overlay/upper` 再做一次 dot sweep。

## 4. v4 發現 → v5 核對(一條一行)

| v4 | 狀態 | 說明 |
|---|---|---|
| A4-M1 `find -delete` / p6「繼續」 | partial | 工具已換、p6 改 mkfs ✅;觸發時點與重入的問題見 M1、M3 |
| A4-M2 version 比不上 / 陳舊值 | partial | boot_id + slot ✅;`-T` 仍寫(M4) |
| A4-M3 匿名 NX 洩漏 | addressed | `psk_replay`;持 QR 者的界線見 m6 |
| A4-M4 prov-txn 自擋 | addressed | rename 後即刪 + token |
| A4-M5 wireless 對帳 | addressed | 開機不對帳;`.txn` 細節見 m7 |
| A4-M6 #202 閘 | addressed | prov-aware;stage 2 的 `node_checks` 也要同樣放行(寫明) |
| A4-M7 永久 resetting / 凍結只在 p6 | partial | tombstone ✅;p5-dead 終點(M2)、取消被 resetting 擋(M1) |
| A4-m1 路徑 | addressed | |
| A4-m2 guardian S11 / firstload | addressed | 範本 + firstload + dockerd |
| A4-m3 S13 全暗 | addressed | 剩 S10/S11 的 mkfs(時間 ⚠️ D30) |
| A4-m4 SD 無身分 | partial | 接受 `any` ✅;重置再跑一輪(m4) |
| A4-m5 4b 位置 | addressed | bypass 與無 p5 出口未列(m3) |
| A4-m6 `root:!` rc 4 / dev-open | addressed | |
| A4-m7 noload | addressed | |
| A4-m8 快取 | addressed | |
| A4-m9 作廢順序 | addressed | 副作用:取消後另一槽已作廢(M1) |
| A4-m10 reset 中 OTA | partial | precheck 拒絕 ✅;`slot_lock` 實際擋不住(m2) |
| A4-m11 flock / state 殘留 | addressed | |
| A4-m12 mkfs 規則 | partial | 95 自己的 never-mkfs 規則與 201 文件未同步(m8) |
| A4-m13 矩陣缺列 | partial | 已補 L41–L46;L41 本身錯(M4);缺列見 §1 |
| A4-m14 降級 serial | addressed | L12 已寫 |
| B4-B1 `find -delete` | addressed | 改 mkfs + `-exec ;`(04 實測 `-depth -name -exec echo` 可用);新問題見 M1、M3 |
| B4-M1 version 無來源 | addressed | 改綁 boot_id |
| B4-M2 單次取樣 | partial | `lastjoined` ✅;joinwatch 停用時退回單次(m5) |
| B4-M3 prov-txn 自擋 | addressed | |
| B4-M4 wireless 多寫者 | addressed | |
| B4-M5 鎖定寫者 / dev-open / harness | addressed | Q6 待使用者 |
| B4-M6 匿名 NX 追蹤 | addressed | 持 QR 者界線(m6) |
| B4-M7 replay DoS | partial | helper 計數、額度分角色 ✅;負測試與協定 §3.4/§8 矛盾(M5);持 QR 者可把擁有者鎖在外面(m6) |
| B4-m1 marker 路徑 | addressed | |
| B4-m2 快取無讀者 | addressed | |
| B4-m3 L16 斷言 | partial | hostname 已更正 ✅;`tune2fs` 不存在、時鐘是假的(m1) |
| B4-m4 負對照 (2) | addressed | |
| B4-m5 validate 寫狀態 | open | `-T` 的父程序就是 sysupgrade(M4) |
| B4-m6 unknown 開放 | partial | p6 提示 ✅;提示會失效(m3) |
| B4-m7 4b 在 `:93` 後 | addressed | |
| B4-m8 identity 半寫 | addressed | |
| B4-m9 prov-state 改判 | addressed | |
| B4-m10 reset 中被 OTA | partial | 同 A4-m10(m2) |
| B4-m11 S13 全暗 | addressed | |
| B4-m12 刪 work | addressed | |
| B4-m13 凍結只在 p6 | partial | p5 正常時 ✅;p5-dead 時仍只靠 p6,而且被自己清掉(M2) |
| B4-m14 FAT 解析 | addressed | |
| B4-m15 `--wipe-all` 規則 | partial | 前提 step=4 ✅;但 step=4 同時是 p6 mkfs 的觸發(M1) |

## 5. 逐 actor

- **BLE 路人**:沒有 QR → 交握失敗,拿不到 `node_cert` ✅。DoS 的保證和協定 §8 矛盾(M5)。
- **持 QR 者**(維修行、看過貼紙的人):能完成交握、拿到 `node_cert`,能把擁有者的 replay 鎖住一小時(m6)。
- **攻陷的 provd**:知道 `psk_replay`,但做不了 owner-op ✅;誠實界線照 v4。
- **本機非 root**:新檔都在 root-only 的 `$RUNDIR` / p6 ✅。`slot_lock` 的接管規則本來就允許 root 接管(m2,屬於「我們自己的錯」)。
- **攻陷的 tenant**:resetting 時 guardian 範本與 firstload 都看 marker ✅。p6 `prov-state` 若對 tenant 可寫,只能把提示改成不上鎖,而且只在 p5 讀不到時有效(m3)。
- **前任擁有者 / 轉賣**:正常路徑是 tombstone + 開機 mkfs ✅;停在 R4 時重開(M1)與 p5-dead(M2)會悄悄回到前任狀態;R6 之後新寫的 dot 檔(m12)。
- **買家**:新身分 ✅;SD 標記可能讓重置多跑一輪(m4)。
- **實體 SD**:放 tombstone 就能讓節點 mkfs p6(反正本來就能重燒卡,不擴大);FAT 解析的長度與字元集限制 ✅。
- **legacy 02/04 第一次 OTA**:stage 1 跑的是**舊**的 platform-ab.sh,不會寫 `ota-armed.mesh`;trial 是 legacy → 今天的規則 ✅。舊 config-save 用 `cp -a identity/.` 合併(`batman-config-save:390`),revert 回 1.5.12 也不會刪掉 `identity/prov/` ✅。
- **單台在家更新**:重開過才會 commit(m5a)。
- **整隊 OTA**:`lastjoined` ✅(m5b 例外)。
- **p5 / p6 壞掉的機台**:p5-dead 的終點和文件寫的矛盾(M2);p5 可讀不可寫 → 永遠 mkfs p6、不能認領(m10);LUKS p6 沒處理(m8)。
- **我們自己**:`tune2fs` 不存在(m1)、`-T` 的父程序(M4)、和協定 MUST 的矛盾(M5)、mkfs 重入(M3)。

## 6. 使用者已定案事項的後果(不重開,只列)

- **U3**:resetting 模式下若不開放 owner-op 取消,沒有 SSH key 的民用擁有者只能等,或者斷電(而斷電正是 M1 的觸發)。
- **U4**:恢復出廠的正常路徑多了一段在 S10/S11 阻塞 10–30 s 的 p6 mkfs(D30 未量)。hostname/SSID 依 MAC 產生,跨擁有者可以串起來(殘項,v5 已寫)。
- **U1 / #255**:若照 m6 預先算好 `psk_replay` 存起來,608B 的 KDF 權限就不再是會推翻「不重工」的未知數。
- **U6**:95/batdata-mount、platform-ab stage 1 都是兩板共用;bcm2710 ❌。
- **Q6**:任何認領測試之前在 04 裝 lab key → 04 之後只接受 key 登入。harness 的 `BatchMode` 目前靠空密碼(R70),要同步改 harness 的金鑰設定。未經使用者同意不能排。
- **Q5**:L16 是唯一能抓 M1–M3、m4、m9 的測試。建議 M1、M3 的白箱(rc 8 時 `reboot -f`、S10/S11 重入)放進非破壞性的 tier A,用 loop device 跑,不必等 Q5。

## 7. 收斂判斷

- **已收斂**(剩下的都是局部問題):OTA mesh 閘(boot_id 綁定,只剩 M4 和 m5、m11)、`state.apply` 交易(m7)、`claim/replay`(M5、m6 是協定對齊與界線)、96 上鎖(m3)。
- **沒收斂**:**恢復出廠**。這一輪的 M1、M2、M3、m4、m8、m9、m10、m12 全部出在這裡。原因是一個可續做的多步驟流程,狀態分散在 **2 個媒體**(p5 tombstone + p6 marker)、**4 個寫者或讀者**(helper、95/batdata-mount、96、config-save),再加上兩個破壞點(R4 執行期 mkfs p5、R-boot 開機 mkfs p6)。p6 的 mkfs 又會清掉它自己的狀態檔。
- **建議砍掉或簡化**:把**所有破壞動作集中到開機早期的一個元件、一個意圖紀錄**。
  - 執行期只做這幾步:凍結 → 停 payload → `invalidate-other` → **在 p5 寫「重置意圖」tombstone(在任何破壞之前)**→ dot sweep + `jffs2reset` → 重開。
  - 下次開機由 batdata-mount 在**任何人掛 p5/p6 之前**(95 的 S10 早於 96)依 tombstone 把 p5、p6 都 mkfs,並在新 p5 寫「已完成」tombstone。同一次開機只做一次。
  - 取消窗口 = 寫 tombstone 之前。p5-dead = tombstone 寫不進去 → 不往下做,停在 `unknown(p5-dead)`,回報換卡。
  - 這樣就不再需要 R4 的重試與取消、「marker step ≥ 4」、p6 marker 撐過 mkfs、`--wipe-all` 的前提鏈,也沒有「停在 R4 時重開」這條路徑。
- 另外建議拿掉「SD 標記在沒有身分時接受任何內容」:改用 tombstone 的 `old_device_id`,沒有就要求 `any` 加 dev-open。這條規則每一輪都在和續做路徑互相作用。

## 8. 本輪唯讀探針(原始輸出摘要)

```
04$ find /overlay/upper -depth -name ".*" -exec echo HIT {} \;   → HIT /overlay/upper/.cache ; rc=0
04$ busybox find --help → -maxdepth/-mindepth/-depth/-name/-exec CMD ARG ;  (無 -delete、無 {} +)
04$ ls -la /overlay → .fs_state -> 2, upper/, work/
04$ /proc/mounts → /dev/loop0 /overlay f2fs rw…;  overlayfs:/overlay / overlay …upperdir=/overlay/upper,workdir=/overlay/work
                   /dev/mmcblk0p6 /opt/batdata ext4;  /dev/mmcblk0p6 /opt/batdata/docker ext4;  5× docker overlay …/merged
04$ /sys/block/loop0/loop/backing_file → /mmcblk0p4 ; offset 113442816
04$ boot_id → 61327849-3cb9-…;  tail boot-reasons.log → … boot_id=6d36b85d … / … boot_id=61327849 prev=CLEAN…   (R66 ✅)
04$ ls /opt/batdata/state → lock-status mesh-expected mesh-joined slot-A.protected slot-B.protected
04$ command -v: mkfs.ext4 e2fsck resize2fs flock jffs2reset blkid 都在;tune2fs MISSING;dumpe2fs MISSING;timeout MISSING
02$ command -v: mkfs.ext4 e2fsck resize2fs flock jffs2reset 都在;tune2fs MISSING
04$ batman-slot active → B;is-trial rc=1
firmware-2710 sbin/sysupgrade:56 -T→TEST=1;:370 validate_firmware_image "$IMAGE";:403 [ $TEST -eq 1 ] && exit 0
firmware-2710 usr/libexec/validate_firmware_image → platform_check_image "$1"(子程序,PPID = sysupgrade)
fstools jffs2reset.c:44-55 mounted → fs_state_set(PENDING)+overlay_delete;否則 jffs2_mark(deadc0de)
原始碼:95-batman-storage:37-39,106,297-343,605-633,708,725,753;96:63-93,161-176;batman-config-save:103-109,152-158,390;
       batman-slot:84-96,516-559;batman-autocommit:348-369,388-397;joinwatch:115-185;meshjoin.sh:14-27;
       platform-ab.sh:74-92,150;219-protocol.md:39-42,77-81,327-336,408
```

## 9. 判定

**REJECT(v5)**:BLOCKER ×0、MAJOR ×5、MINOR ×12。

- MAJOR 的修法都是局部的:
  - M1:觸發條件改成不可回頭點之後,並開放取消;
  - M2:p5-dead 的終點與狀態保存;
  - M3:mkfs 每次開機只做一次,並保住證據;
  - M4:`-T` 不寫;
  - M5:對齊協定 §3.4/§8。
- 依規則,恢復出廠的契約改完後要整份再審。
- 強烈建議先照 §7 把恢復出廠簡化成「單一意圖紀錄 + 開機早期單一執行者」。否則下一輪很可能還會在同一個機制上找到新的 MAJOR。
