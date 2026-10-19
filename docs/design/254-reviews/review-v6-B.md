# #254 階段 1 實作設計 v6 — 獨立審查 B(第 6 輪,對抗式)

審查對象:`docs/design/254-stage1-impl.md` v6(branch `design/254-stage1-impl` @ 9b8687c),加上 v4/v5 中標「同 v4 / 同 v5」的小節。原始碼 = main f2f2bf6;firmware `/home/yello/firmware-2710`。
只做唯讀:讀檔、`ssh` 到 04/02 跑 `cat/ls/grep/uci show/which/sgdisk -i/docker inspect`,沒有寫入、沒有重開。

## 0. 結論

**判定:REJECT(窄)— 0 BLOCKER / 2 MAJOR / 11 MINOR。**

- 執行期 F0–F5 加撤銷已經收斂。下次開機的**成功路徑**也收斂了:破壞動作只在一處,p5 最後格式化,格式化本身就是完成紀錄,這個做法是對的。
- 兩個 MAJOR 都在 **W 階段的失敗路徑**,而且都是「元件各自沒錯、合起來衝突」那一類:
  - **M1**:W0 用「`boot()` 不是 95 帶 `BATMAN_FIRSTBOOT=1` 呼叫的」來判斷「F4 沒做完」。可是 95 是一次性的 uci-default,`uci_apply_defaults` 在它 exit 0 之後就刪掉它。所以只要 W1 或 W2 失敗過一次,下一次開機必定判成「非 fresh」,走 W0。結果:W0 的「overlay 卡住」計數被拿來數 mkfs 失敗;滿 3 次後「繼續開機」**掛上舊 p6**,和 W1 自己的「不掛舊 p6」相反;計數寫在 p5,而 p5 正是可能正在壞的那個媒體,寫不進去時沒有上限。
  - **M2**:intent 存在、overlay 卻是 fresh 時(W1/W2 失敗,或 95 在走到 `boot()` 之前就 exit),96 判 `resetting`,規則是「不上鎖」,§1.4 寫「不動」。fresh overlay 的「不動」就是 image 預設:`root::` 空密碼、`PasswordAuth on`、`RootPasswordAuth on`(02 `/rom` 實測)。而 p5 此時**還留著前任的全部秘密**(identity/prov 7 檔、overrides 裡的 mesh/AP key、團隊共用的 net 秘密)。這是 fail-open。
- 兩條的修法都是局部的:各改一段文字、一個判斷,不需要新機制。之後的 MINOR 可以在實作時修。依使用者規則,MAJOR 未關不能核准,所以判 REJECT。我建議 v7 只修這兩條加 MINOR,下一輪審查應該就能核准。

## 1. 先補:缺的生命週期列與資源

| 缺的路徑 / 資源 | v6 的行為 | 對應 |
|---|---|---|
| **W1 或 W2 失敗之後的下一次開機**(95 已被 `uci_apply_defaults` 刪掉) | 被當成「F4 沒完成」走 W0:jffs2reset、重開;滿 3 次後掛上舊 p6 | M1 |
| **W2 失敗,原因是 p5 變唯讀**(SD 卡老化最常見的終態) | W0「rw 掛 p5 把 attempts+1」失敗時怎麼做沒寫 → 照字面會無限重開,每一輪 W1 都 mkfs 一次 p6 | M1 |
| **fresh overlay + intent 還在**(W1 失敗、W2 失敗,或 95 在 `:86/:95-101/:106` 就 exit 0、在 `:135/:251` exit 1) | 96 判 resetting、不上鎖;dropbear 用空密碼的 root;p5 是前任的 | M2 |
| 95 腳本本體的步驟 3 / 3b 在 W1 **之前**對舊 p6 做 `recover_ext4` / `e2fsck -pf` + `resize2fs` | 文件說「3b 無事可做」,實際上會對 27 GB 的舊 fs 做完整 fsck | m1 |
| **W2 的目標 p5** 沒有任何守門 | `mkfs.ext4 /dev/mmcblk0p5` 不驗 GPT 名稱 | m2 |
| W0 在 S11(procd STATE_INIT)呼叫 `reboot` | procd 進 SHUTDOWN 跑 K*,rcS 的 S* 佇列還在跑;`boot()` 接著往下做 | m3 |
| intent 檔格式不符 | 95 當作沒有;96、config-save、helper 只看存不存在 → 永遠卡在 resetting,沒有任何 W 路徑會處理 | m4 |
| F3 遇到 config-save rc 8(鎖忙 / 已掛載) | 一律對應成 `E_RESET(p5-unwritable)`「請換卡」 | m5 |
| p6 壞掉的節點要恢復出廠(轉賣前常見) | 前置條件要求 p6 已掛 → `E_PRECOND`;沒寫後果 | m11 |
| 資源:`prov-state` 第 3 欄,寫者有 99zz **和** helper | 「unknown 不覆寫第 3 欄」只規定了 helper | m8 |

## 2. MAJOR

### B6-M1 — W0 的「非 fresh = F4 沒做完」不成立:95 跑完一次就被刪,所以 W1/W2 失敗後的每一次開機都會被誤判成 W0;滿 3 次後掛上舊 p6;計數放在可能正在壞的 p5 上,沒有上限

**情境 1(W1 失敗,例如 p6 有 I/O 錯誤)**
1. F5 之後的 fresh 開機:95 `boot()` 帶 `BATMAN_FIRSTBOOT=1` → W1 mkfs p6 失敗 → crit、不掛 p6、不做 W2、意圖保留。`boot()` 回傳,95 走到 `:755 exit 0` → `uci_apply_defaults` 執行 `( . "./$file" ) && rm -f "$file"`,95 被刪掉。
2. 下一次開機:沒有 95 了。S11 `batdata-mount boot()` 沒有 `BATMAN_FIRSTBOOT` → 判「overlay 不是 fresh(F4 沒完成)」→ W0:attempts+1 → 刪 dot 檔 → jffs2reset → reboot。
3. 回到第 1 步(fresh)→ W1 再失敗 → 第 2 步 → …… attempts 到 3 時:crit `reset-stuck overlay`,依 W0 的規則「**不清 p5/p6,繼續開機**」→ 走今天的流程 → **掛上舊 p6**。這直接違反 W1 自己的「失敗 → 不掛舊 p6」(B5-m8 要求的那一條)。
4. 這時的 overlay 是上一次 fresh 開機產生的,96 當時判 resetting、沒有上鎖(M2)。所以結果是:空密碼 root、舊 p6(前任的 docker volumes,04 實測 OTS 的 `ots-pgdata/ots-appdata` 都在 `/opt/batdata/docker/volumes/`)掛著、p5 保留前任身分。status 卻寫「overlay 卡住」,診斷方向是錯的。

**情境 2(W2 失敗,因為 p5 唯讀)**
- fresh:W1 成功(p6 被清)→ W2 mkfs p5 失敗 → 意圖還在 → 95 被刪。
- 下一次:S11 → W0 → 「rw 掛 p5 把 attempts+1」**失敗**(p5 唯讀)。v6 沒寫這時要怎麼做。照字面繼續做 jffs2reset 加 reboot,就是**無限重開**,而且每一輪 fresh 都會再 mkfs 一次 p6,把上一輪存下的 crash / boot-reasons 證據清掉(正是 A5-M3 那一類)。
- §4.5 說「W2 失敗 → 下次開機 W1 會再清一次 p6」,實際上中間還多一次 W0。文件寫的和實際發生的不一樣。

**證據**
- `firmware-2710/package/base-files/files/etc/init.d/boot`:`uci_apply_defaults` 的 `( . "./$(basename $file)" ) && rm -f "$file"`。
- `95-batman-storage:753` `"$INIT" boot`、`:755 exit 0`:不論 `boot()` 裡發生什麼都會 exit 0。
- procd `rcS.c` `_rc()`:開機時只 `glob` 一次 `/etc/rc.d/S*`。fresh overlay 上的 S11 連結是 95 在 S10 才建的,所以 fresh 開機時 S11 **不會**再跑一次 `boot()`(95 尾段註解也這樣寫)。也就是說,`boot()` 沒帶 FIRSTBOOT 的那一次,一定落在 95 已被刪掉的後續開機。
- v6 §4.5 W0「overlay 不是 fresh(…= F4 沒完成)」、W1「失敗 → … 不掛舊 p6 … 下次開機重試」、W0 `attempts ≥ 3` →「繼續開機」。

**修法**(不需要新機制):
- 「overlay 是否已清」改成**正面判斷**,不靠呼叫者。F1 在 overlay 寫一個**非 dot** 的哨兵(例如 `/etc/batman-prov/reset-overlay-armed`,jffs2reset 的 PENDING 會刪它)。`boot()` 見到 intent 時:
  - 哨兵在 → overlay 沒清 → W0;
  - 哨兵不在 → overlay 已清 → 直接 W1/W2。不論是不是 95 呼叫,所以 W1/W2 失敗後的下一次開機就是直接重試 W1/W2,不再多一輪 W0 加重開。
- 重試次數:W 的失敗次數放在 `$RUNDIR` 或 kmsg 都不會持久,所以仍要寫在 intent 裡。**attempts 寫不進去 = 立刻判 stuck,不重開**(fail-safe 而且有上限)。
- stuck 的終點(W0 與 W1/W2 都一樣):**不掛舊 p6、上鎖**(見 M2)、status 顯示真正的原因(`reset-stuck p6-mkfs` / `p5-mkfs` / `overlay`)。
- 負對照:白箱讓 W1 的 mkfs 回非 0,連續開機 → 斷言不出現 W0 的 jffs2reset、重試 ≤ 3 次後停、舊 p6 從未被掛上(先在舊 p6 放 canary,確認 `/opt/batdata` 沒掛載,或 canary 不可見)。白箱讓 p5 唯讀、W2 失敗 → 斷言不會無限重開(開機次數 ≤ N)。照 v6 字面兩條都會 FAIL。

### B6-M2 — 「resetting」在 fresh overlay 上是 fail-open:96 不上鎖,image 預設是空密碼 root 加密碼登入,p5 卻還留著前任的全部秘密

**情境**:任何讓 intent 撐過 fresh overlay 的路徑:
- W1 失敗(M1 情境 1);
- W2 失敗;
- 95 在呼叫 `boot()` 之前就 exit:`:86` 認不出 data 分割、`:95-101` `assert_not_system` 拒絕、`:106` 已掛載、`:135/:251` exit 1。

接著:
1. 96(S10)見到 `.factory-reset` → 依 §4.3「verdict `resetting`、不還原任何東西、**不上鎖**、exit」。§1.4 的 resetting 列也寫「AP、dropbear、lock:不動」。
2. fresh overlay 的「不動」就是 image 預設。02 實測:`/rom/etc/shadow` → `root::`(空密碼);`/rom/etc/config/dropbear` → `PasswordAuth 'on'`、`RootPasswordAuth 'on'`。99-halow-identity 會照 stock 開 onboarding AP。
3. helper rc 15 → `resetting`,「不補 persist、不還原、不產生」,但**沒有任何東西擋 root 讀 p5**。
4. 任何能連上這台的人(onboarding AP、乙太網、mesh 用 image 預設)都能用空密碼 ssh 進 root,讀走 p5:`identity/prov/*`(節點私鑰、`owner_tag_key`、`adv_owner_key`)、`overrides.uci`(mesh key、AP key)、`identity/dropbear`、`shadow-root`;如果是 member,還有團隊共用的 net 秘密(協定 §6 的誠實界線:外流一份就等於全網)。

**為什麼是 MAJOR**:
- 觸發點正是「卡片正在壞」,也就是一般轉賣或報廢前會遇到的情況;
- 洩漏的是前任與整個團隊的秘密;
- 攻擊者不需要 BLE,也不需要實體接觸。

這和 U4(重置**完成**後的 unclaimed 照 image 預設開放)不同:那時 p5 已經清空,沒有東西可讀。這裡不是重開使用者的決策,而是 resetting 這個過渡狀態沒有定義安全姿態。

**修法**:
- 96:`.factory-reset` 存在 → **上鎖**(`PasswordAuth=off`、`RootPasswordAuth=off`、`ttylogin=1`、`root:!`),再 exit。dev-open 不豁免。
- §1.4 把 resetting / resetting-pending 列的「不動」改成「上鎖」。resetting-pending 是在原本的 overlay 上,本來就鎖著,只是要寫明。
- M1 的 stuck 終點同樣上鎖。救援方式 = 重燒卡,v6 已經這樣寫。
- 負對照:白箱讓 W1 失敗 → 重開後從乙太網 `ssh root@`(空密碼)必須被拒,`/etc/shadow` root 欄 = `!`。照 v6 字面會登入成功。

## 3. MINOR

- **m1 — 95 腳本本體在 W1 之前處理舊 p6**:步驟 3 `has_fs`/`recover_ext4`(`:331-344`,包含 `e2fsck -fy`)和 3b `e2fsck -pf` + `resize2fs`(`:349-358`)都在 `:753 "$INIT" boot` 之前跑,而 W1 在 `boot()` 裡。所以 v6 §4.5「#201 的 grow 在 W1 之前已完成…3b 的 resize 無事可做」只對了一半:table grow 確實先做完,但 3b 會對**舊的** 27 GB fs(有 docker overlay2)做完整 fsck,在 S10 阻塞,時間未量(R71)。修法:95 本體在步驟 3 之前用同一個 intent 解析函式讀 p5,有 intent 就跳過 3/3b。時間併入 L16 實測。(A5-m6 / B5-m8 這部分仍是 partial)
- **m2 — W1/W2 的守門**:`assert_not_system` 定義在 95 本體(`:94`),**不在** quoted heredoc 的 INITBODY 裡(`:372-748`),而且用的是 `exit 0`(在 init 裡會結束整個 init)。v6 說「既有守門」不正確。另外 95 註解「no sgdisk on node」(`:76`)和 R72「02、04 都沒有 blkid」也錯:兩台實測都有 `/usr/bin/sgdisk`、`/usr/sbin/blkid`(`tune2fs` 確實沒有),而且 `sgdisk -i 5` 回 `config`、`-i 6` 回 `data`。修法:INITBODY 自帶守門,用 return 不用 exit。W1 驗 GPT 名稱 = `data`、非 squashfs、未掛載;**W2 驗 GPT 名稱 = `config`**、非 squashfs、非 LUKS、未掛載。W2 用和 `batman-config-save do_mkfs` 相同的參數(`-L batman-cfg -m 0`)。更正 R72。
- **m3 — W0 在 S11 重開**:procd `state.c` 的 `procd_shutdown()` 在 STATE_INIT 也會直接進 STATE_SHUTDOWN 跑 `inittab shutdown`(K*),而 rcS 的 S* 佇列不會停。busybox `reboot` 送完訊號就返回,`boot()` 如果接著往下做,就會掛 p6、跑 guardian,和 K* 搶。修法:照 `fw_override_check` 的做法(sync、`mount -o remount,ro /overlay`、`/usr/sbin/batman-reboot` 或 `reboot -f`),之後 `return`,不再往下。寫進 §4.5。
- **m4 — intent 的讀者判準不一致**:95 驗格式,不符就「當作沒有並 crit」;96、config-save(rc 15 / 拒寫)、helper(`resetting`)、precheck-node 只看檔案存不存在。格式不符的檔案(實體寫入或媒體損壞)會讓節點永遠卡在 resetting,而 95 永遠不處理。修法:一個共用的解析函式,所有讀者都用它。格式不符 = 「resetting-stuck(intent malformed)」,上鎖,不破壞。
- **m5 — F3 的 rc 對應**:`--reset-intent` 的 rc 8(未掛載的前提不成立 / 鎖忙)是暫時狀態,例如 F1 之前就開始的 `--on-join` 還握著 p5。v6 一律對應成 `E_RESET(p5-unwritable)`「請換卡」,會叫使用者換一張好卡。修法:F3 先等 config-save 的鎖(有上限);rc 8 對應成 `E_BUSY` 可重試;只有讀回不符或 rw 掛載失敗才算 unwritable。
- **m6 — §6.4 的寫入條件**:
  - (a) 要明寫「並且 `rc=0`」。04 的 ota-trace 實際有 `-F` 時 `caller=/sbin/procd upg=y rc=1` 那一行(`20250714-182104 … S1 CHECK rc=1 caller=/sbin/procd … upg=y`)。
  - (b) `_ab_ramroot_guard` 只在父程序是 sysupgrade 時才清 `$RAM_ROOT`(`platform-ab.sh:92`)。所以本次開機如果有一次 sysupgrade 在 `install_bin` 之後中止,之後 LuCI 的 `ubus call system validate_firmware_image`(caller = procd,`system.c:705`)也會看到 `upg=y`。有 boot_id 綁定,風險低,但 D27「caller=procd 且 upg=y ⇔ 真的升級」不是 ⇔,要改寫成「⇒ 本次開機曾 install_bin」,或在 procd 的 sysupgrade 路徑另加判斷(例如 `/tmp/sysupgrade*` 存在)。
- **m7 — psk_replay 的 app 契約**:要用 replay 的情境,正是 `claim/finish` 的回應遺失。app 要算 `ECDH(owner_enc_priv, node_ecdh_pub)`,就必須在**收到第 2 則時**,也就是送出 `claim/finish` **之前**,把 `node_cert`(`ecdh_pub`、DAC、`sn`/`device_id`)和「pending claim」持久化。v6 寫的「認領時 TOFU pin 下來的 `node_cert`」如果實作成「成功後才 pin」,剛好在要用的情境失效。補進 app 契約,並加一個測試:送出 `claim/finish` 後殺掉 app 再重開 → replay 成功。
- **m8 — `prov-state` 第 3 欄的兩個寫者**:§4.3 只規定 helper 判 `unknown` 時保留第 3 欄,但 99zz(fresh S10)也會寫 `prov-state`(§3)。96 讀不到 p5 的那次 fresh 開機,99zz 如果寫 `unknown`,下一次 OTA 時提示就沒了(B5-m3 原本的情境)。另外「96 時 p6 沒掛 → 沒有提示 → fail-open」仍然沒寫明。(B5-m3 partial)
- **m9 — resetting-pending 的允許清單**:§4.1 規定 provd「只放行 `status/public` + `factory_reset.cancel`」,§4.5 卻說擁有者可以「重新發起(從 F0 開始)」。重新發起的動詞不在清單裡。也要寫明 cancel 是靠 per-verb owner-op,從 `psk_owner`(擁有者候選)session 就能送,不需要 `auth/owner`。否則照協定 §3.5,候選 session 只能送 `info`、`auth/owner`。
- **m10 — 「同一次開機 `boot()` 被呼叫兩次」的前提**:§4.5「天然只做一次」引用「95 uci-default 與 S11 init 都會呼叫」。fresh 開機上這不成立(procd `rcS.c` `_rc` 只 glob 一次,S11 連結是 S10 才建的),結論仍然對,但負對照 (e)「同一次開機兩次 `boot()` 只格式化一次」不會自然發生,要寫成白箱(手動再呼叫一次 `boot`)。D34 的證據也要更正。
- **m11 — p6 壞掉的節點不能用 app 恢復出廠**:前置條件「p6 已掛、無 crit」加上 marker 放在 p6 → `E_PRECOND`。p6 壞是轉賣或報廢的常見原因。要在 L35 和 app 文字寫明後果「請重燒卡(會換身分)」,並確認 app 不會顯示「已重置」。

(另:04 實測 OTS 的狀態資料在 `/opt/batdata/docker/volumes/ots-{pgdata,appdata,mqdata}`,不在 `apps/`。成功路徑由 W1 處理,沒有問題;L49 的殘項描述「`apps.reset/` 與 docker 資料」是正確的,這裡只是補證據。dockerd 沒開 live-restore,`daemon.json` 實測沒有;restart policy 實測是 `no`,所以 F2 停掉 dockerd 會停掉所有容器。)

## 4. v5 發現 → v6 核對(一條一行)

| v5 | 判定 | 說明 |
|---|---|---|
| A5-M1 step=4 觸發 | addressed | 觸發只剩 p5 intent |
| A5-M2 p5-dead 終點 | addressed | F3 失敗 → 撤銷;rc 8 對應見 m5 |
| A5-M3 mkfs 一次性閂 | partial | 成功路徑 ✅;失敗路徑經 W0 誤判形成迴圈(M1) |
| A5-m1 `-T` 寫檔 | addressed | 只在 procd+upg;rc=0 與 stale upg 見 m6 |
| A5-m2 tune2fs / 假時鐘 | addressed | hexdump UUID;R72 對 blkid 的說法錯(m2) |
| A5-m3 slot_lock | addressed | |
| A5-m4 R3 失敗繼續 | addressed | 改撤銷 |
| A5-m5 fresh 判定 / SD 迴圈 | partial | SD ✅;FIRSTBOOT 判定在 W 失敗後誤判(M1) |
| A5-m6 95 放置 / 規則 / LUKS / Pi 3 | partial | 放置、LUKS、規則 ✅;3/3b 對舊 fs、守門不在 init(m1、m2) |
| A5-m7 psk_replay 綁 device_id | addressed | ECDH(owner_enc);app 持久化契約見 m7 |
| A5-m8 簽章額度 | addressed | |
| A5-m9 `.txn` | addressed | |
| A5-m10 96 出口 | addressed | 出口清單完整(`:64/:67/:71/:91/:93`、結尾) |
| A5-m11 帶回家更新 | addressed | L51 |
| A5-m12 取消後果 | addressed | |
| B5-M1 step≥4 觸發 / 取消 | addressed | |
| B5-M2 p5-dead marker 自清 | addressed | |
| B5-M3 S10/S11 兩次 mkfs | addressed | 前提本身不成立(m10),結論正確 |
| B5-M4 `-T` 寫檔 | addressed | 見 m6 |
| B5-M5 BLE 負測試與 §3.4/§8 衝突 | addressed | 假第 2 則加逾時;6 次;DoS 寫成協定界線 |
| B5-m1 tune2fs | addressed | |
| B5-m2 slot_lock | addressed | |
| B5-m3 提示衰減 / 出口 | partial | helper ✅;99zz 未規定、p6 未掛 fail-open 未寫(m8) |
| B5-m4 SD 無身分接受任何內容 | addressed | |
| B5-m5 lastjoined 誤判 | addressed | 說明書加單次取樣退回 |
| B5-m6 psk_replay 界線 / 608B | addressed | D31 刪、D33 ⚠️ |
| B5-m7 `.txn` | addressed | |
| B5-m8 mkfs 守門與失敗處理 | partial | 「不掛舊 p6」被 W0 stuck 推翻(M1);守門不在 init(m2) |
| B5-m9 jffs2reset 沒有上限 | partial | 有 attempts,但計數在 p5 上,寫不進去時沒有上限(M1) |
| B5-m10 tombstone 契約 | addressed | intent 一份格式;讀者判準見 m4 |
| B5-m11 stage 1 前提 / sync / stale-fallback | addressed | |
| B5-m12 R6 之後的 dot 檔 | addressed | 列殘項 |

## 5. 指定重點逐項

- **intent 是唯一提交點 / 觸發**:F 階段確實只有 F3 一個提交點 ✅。但讀者判準不一致(m4)。§8 寫「意圖要格式 + p6 marker nonce」,開機時 95 其實**不比對** nonce(p6 還沒掛),nonce 只在寫入時檢查。所以實體持有者直接寫 intent 就能觸發清除。這和「可以重燒卡」等價,可以接受,但 §8 的寫法要改成實話。
- **`BATMAN_FIRSTBOOT=1` 與 `uci_apply_defaults`**:95 被 source 進子 shell,exit 0 就刪,exit 1 會保留。exit 1 的路徑(`:135`、`:251`)都在 `boot()` 之前,下次開機 95 會再跑並帶 FIRSTBOOT,這部分 OK。問題在 exit 0 之後的開機(M1)。95 不會「意外保持 armed」。
- **W0 在 S11 重開**:見 m3。
- **W1/W2 相對 LUKS / mount / 閂 / pstore / #201 grow 的位置**:在 `boot()` 內位置正確(mount、`:632` 閂、pstore、boot-reasons、`fw_override_check` 之前)。缺的是 95 本體的 3/3b(m1)。
- **`apps/` → `apps.reset`**:`restore_payload_guardians` 和 `refresh_payload_config` 都只看 `$MOUNT/apps`,原始碼 `95-batman-storage` 的 `restore_payload_guardians` 確認 ✅。firstload、guardian 範本、dockerd 都看 marker ✅。04 沒開 live-restore、policy 是 `no` ✅。tenant 的狀態在 docker volumes(見 §3 附註)。
- **取消路徑與 SD 標記刪除**:✅;resetting-pending 的允許清單矛盾見 m9。
- **§6.4 caller=procd && upg=y**:04 ota-trace 實證,每次 OTA 都有兩行 S1 CHECK(`caller=/bin/sh /sbin/sysupgrade … upg=n` 與 `caller=/sbin/procd upg=y`);sysupgrade `:370` 的 validate 在 `:403` TEST exit 之前、`:407 install_bin` 在之後;procd `system.c:792` 在 sysupgrade ubus 內再 validate。✅,但要補 rc=0 與 stale upg(m6)。
- **psk_replay**:協定 §5.3 確認 `claim/finish` 帶 `owner_enc_pub`,§3.3 確認 `node_cert` 有 `ecdh_pub` 與 `sig_ecdh` → 兩邊都算得出 ✅;§3.4 現在寫的是「5 次」,§1.3 要求 v0.7 改成 6 ✅;§6 金鑰表要為 ECDH 金鑰與擁有者加密金鑰加上「也用於 psk_replay」;app 持久化見 m7。路人、只看過 QR 的人都拿不到 ✅。
- **96 上鎖提示用 `prov-state` 第 3 欄**:見 m8;另外 resetting 不上鎖見 M2。

## 6. 逐 actor(只列本輪有變化的)

- **BLE 路人**:psk_replay 擋住追蹤 ✅;吃滿 §8 全域額度是協定既有界線,已寫明。
- **網路上的鄰居(AP / 乙太網)**:**M2**:重置卡在半途時,空密碼 root 可以讀到前任的 p5。
- **本機非 root 程序**:p6 `state/`、`apps/` 實測都是 root 0755,建不了 marker 來 DoS ✅。
- **被入侵的 provd**:發不出 F0 或 cancel(需要 owner-op)✅;看得到 psk_replay(和 psk_owner 同級,誠實界線)。
- **前任擁有者**:成功路徑全清 ✅;M1 的 stuck 路徑會掛上舊 p6。
- **實體 SD**:寫 intent = 觸發清除(等同重燒);格式不符的 intent = 永久卡住(m4)。
- **我們自己**:M1(失敗路徑迴圈、文件與實際不符)、m3(重開競態)。

## 7. 使用者決策的後果(不重開,只列)

- U4 全清含身分:F3 寫不進 p5 → 撤銷 →「請換卡」;p6 壞 → 不能用 app 重置(m11)。兩種情況實際上都要靠重燒卡。
- U3 與 SSH 脫鉤、image 預設開放:重置完成後的 unclaimed 照 image 預設是空密碼 root,這是既定決策。M2 只針對 p5 還沒清空的 resetting 過渡狀態。

## 8. 收斂判斷

- **恢復出廠已經收斂到正確的形狀**:執行期可撤銷、單一提交點、下次開機單點破壞、p5 最後清、以格式化當完成紀錄。本輪沒有發現成功路徑的問題,也不需要新機制。
- 剩下的兩個 MAJOR 是失敗路徑的**判準與安全姿態**:
  - M1 改成用 overlay 哨兵正面判斷 fresh、attempts 寫不進去就 stuck、stuck 時不掛舊 p6;
  - M2 讓 resetting 上鎖。
- 合計大約兩段文字加一個哨兵檔,各附一個負對照。11 個 MINOR 都可以在實作時修(APPROVE-WITH-CHANGES 等級)。
- 建議:v7 只做這些修改,不要重寫。下一輪審查只要確認 M1/M2 的負對照有寫進 L16 的 (c)–(f) 與 `prov-reset-*`,就可以核准。

## 9. 本輪唯讀探針(原始輸出摘要)

- 04 `/opt/batdata/log/ota-trace.log`:`S1 CHECK rc=0 caller=/bin/sh /sbin/sysupgrade -n /opt/batdata/ota-280.tar.gz … upg=n` → `S1 CHECK rc=0 caller=/sbin/procd … upg=y`(14 s 後);`-F` 那次:`rc=1 caller=/sbin/procd … upg=y`。
- 02 `/rom/etc/shadow`:`root:::0:999`;`/rom/etc/config/dropbear`:`PasswordAuth 'on'`、`RootPasswordAuth 'on'`。
- 02 / 04:`sgdisk`、`blkid`、`mkfs.ext4`、`jffs2reset`、`flock`、`hexdump`、`e2fsck` 都有;`tune2fs` MISSING;04 `sgdisk -i 5` → `config`、`-i 6` → `data`。
- 04 dockerd:`daemon.json` = `{data-root, log-level, iptables:false, ip6tables:false}`(沒有 live-restore);容器 restart policy 全是 `no`;OTS 狀態 = `/opt/batdata/docker/volumes/ots-{appdata,mqdata,pgdata}`。
- 04 `/opt/batdata`、`state/`、`apps/`:root 0755;`/etc/batman-dev-open`、`/rom/etc/batman-dev-open` 都不存在。
- 04 rc.d:`S11batdata-mount`、`S95batman-ots-firstload`、`S98joinwatch`、`S99dockerd`、`S99batman-payload-opentakserver`、`K08batman-prestop-payload`、`K09batman-payload-opentakserver`。
- firmware:`etc/init.d/boot` `uci_apply_defaults` = `( . "./$file" ) && rm -f "$file"`;procd `rcS.c _rc()` 只 glob 一次;`state.c procd_shutdown()` 在 STATE_INIT 也會進 SHUTDOWN;`system.c:705/792` 兩處 validate。
