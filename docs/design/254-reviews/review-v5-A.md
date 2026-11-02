# Review A(第 5 輪)— `254-stage1-impl.md` v5(+ v4 中標「同 v4」的各節)

審查者 A,獨立、對抗式。審查對象是 v5(`design/254-stage1-impl` @ e4e7177)**加上** v5 標「同 v4」而沿用的 `254-reviews/254-stage1-impl-v4.md` 各節,當成一份整體來審,不是只看 v4→v5 差異。依使用者 CLAUDE.md 的設計審查規則與 `docs/design/REVIEW.md`。使用者已定案的事項(擁有權與 SSH 脫鉤、恢復出廠全清含身分、Go/Flutter+Rust、3A+ 延後、`uart_enable` typo、改名探針、Q5、Q6)不重開,只在 §5 列後果。

**證據來源(全部唯讀,2026-10-19)**
- 原始碼(main f2f2bf6 = branch):`95-batman-storage`(含產生的 batdata-mount init 全文)、`96-batman-config-migrate`、`batman-slot`(`slot_lock`、`node_checks`、apply 尾段、EXIT trap)、`platform-ab.sh`、`batman-autocommit`(`expected_in_mesh`、reboot 路徑)、`joinwatch`、`batman-config-save`(mode/lock)、`payload-guardian.init.in`、`payload-guardian.sh`、`batman-ots-firstload`;OTS manifest 的 VOLUME/MOUNT。
- firmware-2710:`package/base-files/files/sbin/sysupgrade`、`usr/libexec/validate_firmware_image`。
- 04(10.41.1.3)、02(10.41.1.1):`boot-reasons.log` 尾、`ota-trace.log` 的 `S1 CHECK`、`mkfs.ext4 -V`、`/etc/mke2fs.conf`、`/sys/fs/ext4/features`、`busybox find --help`、逐一 `command -v`、`find /overlay/upper -depth -name '.*'`(只印)、`ls -la /overlay /opt/batdata/state`、`mount`、`date`。
- `gh issue view 254 --comments`(BLE spike 結果,與 R38–R42 一致)。
- **沒有任何寫入**;沒跑 bluetoothctl、沒 reboot、沒 jffs2reset、沒 mkfs、沒跑 config-save 寫入模式。

---

## 0. 總評

v5 的方向對:**把機制變少**。我逐條對過原始碼,下面這些是真的收掉了,而且我沒在它們身上找到新的介面衝突:
- 刪掉 S13 阻塞 init、刪掉開機 wireless 對帳(→ chanfix/morse 回寫/操作員三方衝突消失)。
- `ota-armed.mesh` 綁 arm 那次開機的 boot_id:`boot-reasons.log` 的寫者只有 batdata-mount `boot()`(`95-batman-storage:708`),有 once-per-boot 閂(`:632`),fresh trial 上由 95 在 S10 呼叫(`:753`),早於 autocommit S99 → D28 其實已可用原始碼證成 ✅(見 §3)。trial 中途重開一律落回 committed 槽(tryboot one-shot;`fw_override_check` 在 `tb≠0` 時直接 return,`:451`),所以「trial 在期限內重開」不會造成錯誤採用。
- `joinwatch.lastjoined` 把單次取樣換成「本次開機曾入網」的歷史 → team OTA(L40)成立。
- `psk_replay` 取代匿名 NX → 沒有 QR 的路人第 1 則就失敗。
- prov-txn 在 rename 後刪 + token 豁免 → 不再自擋。
- p5 tombstone → 凍結不再只靠 p6。
- R6 改用 busybox 實有的 `find -depth -name '.*' -exec rm -rf {} \;`(兩台 `--help` 都有 `-depth`、`-exec CMD ARG ;`;04 目前只會刪到 `/overlay/upper/.cache`;`.fs_state` 在 `/overlay` 不在 `upper`,不受影響)。

剩下的問題**集中在一個機制**:恢復出廠的「下次開機 p6 mkfs」觸發條件。它有兩個觸發來源(p5 tombstone **或** p6 marker step ≥ 4),沒有一次性閂,而 helper 與 95 對 marker step 的意義理解不同。這產生 3 條 MAJOR。另有 12 條 MINOR,多半是證據或文字與原始碼不符(`-T` 的父程序、`tune2fs` 不存在、`slot_lock` 不可由 helper 持有)。

**判定:REJECT(v5)**:BLOCKER ×0、MAJOR ×3、MINOR ×12。修法都是局部的(見 §6 收斂判斷)。

---

## 1. 先補:矩陣缺的列、擁有權缺的資源

| 缺的路徑 / 資源 | 為什麼要有 | 對應 |
|---|---|---|
| **停在 R4(rc 8 / rc 1,可取消)時重開**(斷電、擁有者手動重開) | §4.5「斷電點」只列 R1–R3、R4 後(tombstone 在)、R6 後;「停在 R4、無 tombstone、marker step=4」這個狀態下重開的結果沒寫 | M1 |
| **p5-dead 路徑的第一次開機之後**(marker 已隨 p6 mkfs 消失) | 沒有任何持久狀態記得「剛重置完」 | M2 |
| **rc 15 路徑 helper 失敗**(crash loop、rc 8、p5 唯讀、keystore 錯)後的下一次、再下一次開機 | tombstone 每次開機都觸發 mkfs | M3 |
| **R6 前斷電 → 非 fresh 開機 → helper 重做 R6–R7 → fresh 開機** | 一次重置裡 p6 被 mkfs 兩次;R5 沒被重做 | M3、m5 |
| **R4 取消之後**(另一槽已作廢、SD 標記還在) | 取消的後果沒寫 | m12 |
| **sysupgrade stage 1 通過後、stage 2 前開始的恢復出廠** | 前置條件的 `slot_lock` 實際上擋不住(m3) | m3 |
| **Pi 4 EEPROM 開錯槽且 R3 只做到一半** | 舊 image 不認 tombstone | m4 |
| 資源:**p6 mkfs 的「一次性」紀錄** | 目前沒有,只有 tombstone(持續存在到 S89) | M3 |
| 資源:**「重置已完成、p5 無法使用」的紀錄** | p6 mkfs 把 marker 一起刪了 | M2 |
| 資源:**`$RUNDIR/batman-slot.lock` 的持有者契約** | batman-slot 只承認 cmdline 含 `batman-slot` 的持有者 | m3 |

---

## 2. Findings

### MAJOR

**M1. marker 的 `step=4` 是在 `--wipe-all` **之前**寫的,但 95/batdata-mount 把「step ≥ 4」當成「p5 已清」。結果:卡在 R4(可取消)時只要重開一次,p6 就會被 mkfs,而擁有權完全沒動;取消也不可能了**

- 情境:擁有者在 app 按恢復出廠,R4 `--wipe-all` 一直 rc 8(p5 被某個 ro mount 佔住),或 rc 1。provd 顯示 `reset step=4 p5-busy`,設計說「取消可用」。擁有者決定先拔電源、明天再處理(或在現場斷電)。
  1. 下次開機(非 fresh,R6 沒做):S11 batdata-mount 掛上 p6,看到 marker step=4 → 依 §4.5 R-boot「(p6 掛上後)marker step ≥ 4 → umount p6 → mkfs p6」→ p6 整個清掉,**marker 也一起沒了**。
  2. p5 從來沒被清(R4 沒成功)、也沒有 tombstone → 96 不跑(非 fresh)、helper `--prov-get` rc 0 → 照常以**原擁有者的 claimed/member** 開機;joinwatch/dockerd/guardian 因為 marker 消失照常啟動。
  3. 結果:OTS 資料、docker image、mesh-expected/mesh-joined、所有 log 都沒了;另一槽在 R3 已作廢;擁有權還在;「取消」已無對象(marker 不在),負對照 (e)「取消後恢復原狀」與 R1「斷電後一切照舊可管」都不成立。
- 證據:v5 §4.5 R4 列「marker step=4 → `batman-config-save --wipe-all`」;§4.3 `--wipe-all` 前提「p6 marker 存在且 step = 4」;§4.5 R-boot「(p6 掛上後)marker step ≥ 4 → … mkfs」;§3 marker 讀者「95/batdata-mount(step ≥ 4 → mkfs p6)」。同一個數字,helper 端的意思是「正要清 p5」,95 端的意思是「p5 已清,可以清 p6」。這正是「元件各自沒錯、合起來衝突」的那一類。
- 修法(擇一,建議 a):
  - (a) **p6 mkfs 只認 p5 tombstone**,拿掉「marker step ≥ 4」這個觸發。p5-dead 另案處理(見 M2)。
  - (b) 保留 marker 觸發,但改成 `--wipe-all` 回 0 或 16 **之後**才寫 `step=5`,95 以 `step ≥ 5` 為準;`--wipe-all` 前提維持 `step=4`。
- 負對照:白箱讓 `--wipe-all` 持續 rc 8 → 在 R4 停住時 `reboot` → 斷言 p6 未被 mkfs(白箱放的 canary 檔還在)、marker 仍是 step=4、`--factory-reset-cancel` 可用並恢復 joinwatch/dockerd/guardian。照 v5 字面會 FAIL(p6 被清、marker 消失)。

**M2. p5-dead 分支(R4 rc 16 →「繼續」)的終態,與「同 v4」的 `--prov-get` rc 表互相矛盾;負對照 (d) 照 v4 表實作必定失敗**

- 情境:p5 媒體壞了(這正是 A4-M7 要處理的那台)。R4 rc 16 → `reason+=p5-dead` → R5/R6/R7 → 重開。
  1. fresh 開機:95 讀 p5 tombstone 失敗(p5 讀不到)→ 掛 p6、marker step=6 → mkfs p6 → **marker 消失**。
  2. 96:p5 不是 ext4 或掛不起(`96:71` / `:89`)→ 依 v5 看 p6 `prov-state` 提示 → p6 剛被清空 → 不鎖(重置後本來就不該鎖,這點 OK)。
  3. helper:`--prov-get` rc 1(掛不起)或 12(非 ext4)、overlay 無身分 → 依 v4 §4.2 表(v5 §4.2「同 v4」),這一格是 `unknown(p5-unreadable)` / `unknown(p5-not-ext4)`,**「不產生」身分**。這時已經沒有任何持久狀態(marker 在 p6 上被清了,tombstone 沒寫成)能告訴 helper「這是重置完的機台,可以產新身分」。
  4. v5 R4 寫的是「下次開機是 `unknown` 但 p6 照清、**新身分在 overlay 可認領**」,負對照 (d) 是「兩次開機內 `unknown` + 新身分」。照 rc 表實作,結果是 `unknown`、沒有身分、不能認領;唯一的出口是 SD 標記,而它會再跑一次 R1–R7,R4 又 rc 16 → 同樣的終點(每次都把 p6 再清一次)。
- 這是 v4 A4-M7 修法 2 的字面被採用、機制卻沒有接上。「同 v4」的 rc 表在這裡和 v5 正文互相矛盾。
- 修法(擇一,要在 rc 表寫明):
  - (a) 95 mkfs p6 之後,立刻在**新的** p6 寫一行 `state/factory-reset.done <old_device_id> p5-dead`(0600)。helper 見 rc 1/12 **且**這個檔 → 產新身分、`prov{unclaimed}` 只存 overlay、開窗口;寫明「p5 不能 persist → 每次 OTA 都會失去認領,請換卡」。
  - (b) 不要「繼續」:rc 16 → 停在 R4、`status` 顯示 `p5-dead: replace the card`、可取消。和 M1 修法 (a) 一致(只有一個觸發來源:tombstone),也最簡單。實體持有者本來就能重燒卡。
- 負對照:白箱讓 p5 讀寫都失敗(dm-error 或 loop 唯讀)→ 依所選方案斷言終態(a:兩次開機內出現新 `device_id` 且 `info.state=unclaimed`;b:停在 R4、status 顯示 p5-dead、p6 未動)。照 v5 字面兩個都不成立。

**M3. p6 mkfs 沒有「一次性」閂:tombstone 從 R4 一直存在到 S89 helper 成功清除為止,中間每次開機都會 mkfs p6。helper 卡住時,節點每次開機都抹掉上一次的 crash/pstore 紀錄,原因永遠查不到**

- 情境:
  1. **一次重置清兩次**:R4 之後、R6 之前斷電 → 非 fresh 開機,S11 mkfs p6(第 1 次)→ helper rc 15、overlay 不是 fresh → 重做 R6–R7 → fresh 開機,S10 95 → `boot()` → tombstone 仍在 → mkfs p6(第 2 次)。功能上無害,但每次都要阻塞 10–30 s 以上(D30 未量;節點上沒有 `/etc/mke2fs.conf`,mke2fs 1.47.0 用內建預設,會先對整個 25.8 GiB 分割做 discard,時間未知)。
  2. **helper 在 rc 15 路徑失敗**:crash loop、`--prov-only --clear-tombstone` rc 8、p5 卡在唯讀(SD 衰退時常見)、keystore 錯誤。結果是每次開機 tombstone 都還在 → **每次開機都 mkfs p6**。batdata-mount 在同一次開機會把 pstore 搬進(新的)p6 `crash/`,但下一次開機又被 mkfs 清掉。`boot-reasons.log`、`ota-trace.log`、`firstload.log`、shutdown dump 也一樣。卡住的節點每重開一次就把「為什麼卡住」的證據刪掉一次。這違反使用者的「不盲刪紀錄」規則,也讓 FAIL 永遠只能標 ❓。
  3. **未來 `se` 後端**:`--clear-tombstone` 的條件是「與 tombstone 不同 device_id 的完整新身分」。608B 的 `sn` 是晶片序號,`device_id = hex(sn)` 重置後不會變 → 條件永遠不成立 → 每次開機都 mkfs p6。這和 U1「之後不重工」衝突。
- 證據:§4.5 R-boot「tombstone 仍在 → 每次開機重試」;§3 tombstone 的唯一刪者是 helper 的 `--prov-only --clear-tombstone`;§4.3 clear 的條件「不同 device_id」;batdata-mount `boot()` 的 pstore 搬移在掛載之後(`95-batman-storage:635-651`),所以第 N 次開機搬進去的紀錄會在第 N+1 次的 mkfs 時消失。
- 修法:
  - tombstone 內容帶 nonce:`<old_device_id> <nonce>`。
  - 95 mkfs 之後,在新 p6 寫 `state/p6-wiped <nonce>`。同一個 nonce 不再 mkfs,只 log `factory reset: p6 already reformatted for <nonce>`。
  - clear 的條件改成「overlay 有完整新身分,且 prov gen=1、state=unclaimed」,不比 device_id。`se` 後端要另外定義「新身分」(例如換 `claim_secret`/cert),列進 #255。
- 負對照:白箱讓 helper 在 rc 15 時 `exit 1` → 連續開機 3 次 → 斷言 p6 只被 mkfs 一次(第 1 次開機後放進去的 canary 檔、`crash/` 都還在)。照 v5 字面會 FAIL。

### MINOR

**m1. L41 / D27 不成立:`sysupgrade -T` 呼叫 platform_check_image 時,父程序**也是** sysupgrade → `-T` 會寫 `ota-armed.mesh`,L41 的負測試必定 FAIL**
- 證據:`sbin/sysupgrade:370` `json_load "$(/usr/libexec/validate_firmware_image "$IMAGE")"`,在 `:403` `if [ $TEST -eq 1 ]; then exit 0` **之前**;`validate_firmware_image` 在自己的 shell 裡呼叫 `platform_check_image`,`$PPID` = sysupgrade。04 `ota-trace.log` 的實際紀錄:同一次 OTA 有兩次 `S1 CHECK`,第一次 `caller=/bin/sh /sbin/sysupgrade -n … upg=n`,第二次 `caller=/sbin/procd upg=y`。`-T` 只會有第一種,而第一種的 cmdline 也含 `sysupgrade`。D27 引用的 `_ab_ramroot_guard`(`platform-ab.sh:92`)用這個判斷區分的是「stage 1 vs procd 的那次 validate」,**不是**「真的升級 vs `-T`」。
- 影響:只在 bench(`-T` 之後、同一次開機直接 `batman-slot apply`),而且留下的判定是同一次開機的真實值,所以實際風險低。但 `platform-ab.sh:74-75` 的「no state file」不變式仍被打破,而實作者會撞上一個寫錯的測試。
- 修法:只在 **procd 那次 validate** 寫(`caller=/sbin/procd` 且 `[ -x "$RAM_ROOT/sbin/upgraded" ]`,也就是 otalog 的 `upg=y`;只有真的升級在 `sysupgrade:407 install_bin` 之後才會出現)。並且只在 `_ab_check_image` 全部通過(rc=0)之後才寫。

**m2. L16 斷言用 `tune2fs -l`,但節點上沒有 `tune2fs`;時間又是假的 → 這條斷言必定誤判(重演 R62 教訓)**
- 證據:04、02 `command -v tune2fs` → MISSING、`dumpe2fs` → MISSING(`95-batman-storage:43` 自己也寫「no dumpe2fs/blkid … not in the image」);04 `date` = 2025-07-15,02 = 2026-10-17。
- 修法:用 `hexdump` 讀 ext4 superblock 的 UUID(offset 1024+0x68,16 B),與重置前記下的 UUID 比對;或在重置前放 canary 檔。`prov-tools-254` 只斷言實際有的工具(加上 `hexdump`)。

**m3. 「整個執行期部分(R1–R7)持 `slot_lock`」照現有 lock 協定無法實作**
- 證據:`batman-slot:84-96` 的 `slot_lock` 是 `mkdir` 鎖;持有者的 cmdline 不含 `batman-slot` → 一律當 stale、接管。helper 是 `batman-provhelper`,所以任何 `batman-slot apply/commit` 都會搶走它。R3 的 `batman-slot invalidate-other` 也會接管,並在 EXIT trap(`:157`)把鎖刪掉 → 從 R3 起 helper 就沒有鎖了。
- 現在真正擋 OTA 的是 precheck-node 對 marker/tombstone 的檢查(L45),這已經夠用,但文字與原始碼不符。另外,sysupgrade stage 1 通過之後、stage 2 進 `apply` 之前開始的恢復出廠,兩邊的檢查都看不到對方。
- 修法:刪掉「持 slot_lock」的說法,改寫成「precheck-node 與 stage 2 `node_checks` 都看 marker/tombstone」,並寫明 stage1→stage2 的窗口(reset 前置條件另查 `$RAM_ROOT/sbin/upgraded` 或 `/tmp/sysupgrade*` 存在就拒絕)。或者擴充 lock 協定(持有者欄位 + 傳給子程序的 token)。

**m4. R3 的失敗政策「`other-slot-partial`,繼續」,碰上 Pi 4 EEPROM 開錯槽,會讓前任的 seed 回到 p5**
- 情境:R3 root 清零失敗(例如 dd I/O error)→ 繼續 → R4 mkfs p5 + tombstone → 之後 EEPROM 開錯槽,`fw_override_check` 連續兩次以上就不再修正(`95-batman-storage:459-462`,STUCK)→ 舊槽、舊 overlay、**舊 image 的 config-save 不認 tombstone** → joinwatch `--on-join` 把前任的 overrides、dropbear identity(含 `authorized_keys`)、shadow 重新 seed 到剛 mkfs 的 p5 → 回到新槽,helper 只清 tombstone → 下一次 OTA,96 還原前任的 SSH key。
- 修法:root 清零失敗 → 停(可取消),不要繼續;`--clear-tombstone` 前斷言 p5 上只有 tombstone(有 `.seeded`/`overrides.uci`/`identity/dropbear` → 再 `--wipe-all` 一次)。

**m5. R-boot 細節缺兩處**
- (a) helper 在 rc 15 時判斷「overlay 是不是 fresh」的依據沒有定義。建議:96 verdict(`/etc/.batman-prov-restore`)的 boot_id == 本次 = fresh。
- (b) 非 fresh 時「重做 R6–R7」漏了 R5(刪 SD 標記)。A4-m4 的規則是「overlay 與 p5 都沒有身分時,接受任何內容」;fresh 開機、helper 產身分之前正好就是這個狀態 → 殘留的標記會**再觸發一次重置**。若 R5 一直刪不掉(FAT 錯誤),就會無限重置。
- 修法:tombstone / rc 15 期間忽略 SD 標記並重試刪除;重做 R5–R7;§4.5 寫明 helper `--boot` 內「tombstone 處理 → SD 標記」的順序。

**m6. 95/batdata-mount 加 mkfs 的位置與副作用沒寫清楚**
- 位置:必須在 pstore 搬移(`:635`)、once-per-boot 閂(`:632`)、`fw_override_check`(`:721`,會寫 `state/fw-override-count`)、boot-reasons 寫行(`:708`)**之前**,否則該次開機的 crash 紀錄寫進舊 fs 就被清掉。
- S10 路徑上,95 的 3b 會先對**舊** fs 跑 `e2fsck -pf` + `resize2fs`(`:350-357`),白費時間,可以在 tombstone 存在時跳過。
- mke2fs 預設會 discard 整個分割:對「全清」是加分,但時間未知(D30),要明定用不用 `-E nodiscard`。
- 文件同步:95 檔頭 `:24-25`、`:37-39`、`:297-301`「a pre-made data partition is NEVER formatted」要改寫(A4-m12 的 p6 版),並說明新的格式化許可只來自 tombstone(實體 / root)。
- LUKS p6:95 的 `LUKS=1` 路徑在重置後會產新 key(`:279`),開不了舊 p6 → mkfs 對象不存在 → crit,每次開機重試。前置條件要加「p6 非 LUKS」(同 p5),或寫成 `luksFormat` 新 key(加密抹除)。
- Pi 3(U6):`p5_never_seeded()`(`:178-184`)在 `--wipe-all` 之後回真 → 現場重置過的 Pi 3 卡,下次 95 會被當成工廠卡,允許改寫開機關鍵的 MBR(`:211`)。要寫明這是有意的,或者讓 `p5_never_seeded` 把 tombstone 也當成「已佈署過」。
- 95 讀 tombstone 只看「存在且是 regular file」,不解析內容(實體可寫)。

**m7. `psk_replay` 綁的是 `device_id`,不是 `owner_pub` → 看過機身 QR 的人都能做「這台在不在附近」的探針;§1.3「219:267 的防追蹤要求不變」講過頭了**
- 情境:修理行、借用者,或任何人拍下機身 QR 貼紙 → 之後在 BLE 範圍內對每台已認領節點送 `psk_replay` 的 NXpsk0 第 1 則 → 成功的那台就是目標,並拿到 `node_cert`。v4 是任何路人都行,v5 縮小成「看過 QR 的人」,但 219:267 要的是「持有擁有者金鑰或網路金鑰」。
- 修法:採 B4-M6 (a) 的原案 `psk_replay = HKDF(claim_secret, "batman-psk-replay-v1" ‖ device_id ‖ owner_pub)`。app 有 `owner_pub`,只拍 QR 的人沒有。或者在 §1.3 / §8 誠實寫明殘留面。另外,協定 §3.4「固定試 5 次(不足以假 PSK 補)」要改成 6(v0.7)。

**m8. 簽章額度:unclaimed 節點上的買家,和路人共用 0.5/s**
- §4.1:「認領者候選(psk_replay)與匿名(unclaimed 的 NX)合計 0.5/s」。在 unclaimed 節點上,買家的認領交握本身就是匿名 NX → 路人 10 Hz 匿名 NX 會把額度吃滿,買家要搶到 `sign.static` 才能繼續。B4-M7 的負測試只保護擁有者。
- 修法:每個連線 / 每個 central 公平分配(round-robin),或每連線各自限速;負測試:路人 10 Hz 時,買家的認領交握在 N 秒內完成。

**m9. `.txn` 的一次性對帳會撤銷操作員刻意做的 setkey**
- §4.4 步驟 9 承諾:操作員對 `radio_managed=1` 的節點跑 `halow-setkey`「照做 … 開機不改回」。但步驟 6 的對帳是把 wireless 改回「prov 的值」。若操作員之前改過頻道(live ≠ prov),之後某次交易在步驟 1–4 間斷電 → 開機對帳會把操作員的頻道一起改回去,而且有 persist。
- 修法:`.txn` 記下交易前的 live 值,對帳改回那一份;`.txn` 要在步驟 2 之前 fsync;寫明 `--prov-get` 失敗(rc 1/8)時的行為(建議:保留 `.txn`、下次開機再試)。

**m10. 96 的上鎖出口只列了 `:71`、`:89`**
- `96-batman-config-migrate` 的出口還有 `:64`(bypass,exit 1)、`:67`(無 p5)、`:91`、`:93`、`:185`。§4.3 寫「每一個出口之前」,但括號只列兩個 → 實作者會照括號做。要全部列出,單元測試逐一驗。bypass 要不要依 p6 提示上鎖,要明定(bypass 是實體的開機參數)。

**m11. L31 的現場說明:member 在本次開機內曾入網、之後帶回家沒有重開,stage 1 會判 `joined` → 一定 revert**
- fail-closed,方向正確,但「單台在家更新」的使用者會看到「更新失敗」而不知道原因。release note 與 `status/public` 要提示「在家更新前先重開一次」,或在 stage 1 拒絕時印出原因。

**m12. R4 取消的後果沒寫**
- R3 已經作廢另一槽 → 取消後**沒有回退槽**,直到下一次 OTA 寫好。
- SD 標記路徑:取消時 R5 還沒做 → 標記還在 → 下次開機 helper 又讀到它,又開始重置 → 卡在 R4 → 再取消,循環。
- 修法:取消時一併刪 SD 標記(或記住「已取消的標記內容」);`status` 顯示「無回退槽」。

---

## 3. 作者點名項逐一回答

| 項 | 結論 |
|---|---|
| §4.5 p6 在 95/batdata-mount 掛載前 mkfs(S10 首次呼叫與 S11) | 方向對,一次解決 dot、bind、lost+found 三個問題。缺:觸發條件互相衝突(M1)、沒有一次性閂(M3)、放在 `boot()` 的位置與 3b/LUKS/Pi 3/檔頭文件(m6) |
| 與 95「never mkfs a pre-made data partition」 | 規則被改寫了,但 95 的檔頭與 `:37-39`、`:297-301` 沒同步;新的許可要寫成「只來自 p5 tombstone」(m6) |
| LUKS p6 | 重置後新 key 開不了舊 p6 → 永久 crit(m6) |
| #201 grow | Pi 4:p6 已長滿 → 1b no-op ✅;Pi 3 的 `p5_never_seeded` 語意改變(m6) |
| golden payload refresh | p6 清空後 `refresh_payload_config` 只刷新已有 `*.manifest` 的 tenant(`:510`)→ no-op ✅;firstload 找不到 `images/*.tar` → no-op ✅ |
| 同次開機寫 p6 的 crash/pstore | mkfs 若放在搬移之前,該次的紀錄保住;下一次開機若再 mkfs 就被清(M3、m6) |
| p5 tombstone 跨 95/96/config-save/helper/precheck-node | 寫者唯一(`--wipe-all`)✅;讀者 5 個 ✅;刪者唯一但條件不適用 `se`(M3);p5-dead 時根本沒有 tombstone(M2) |
| R4 取消路徑 | 有 ✅;取消之前重開會清 p6(M1);取消後的後果(m12) |
| R6 在 live overlay upper 上 `find -depth … -exec rm -rf {} \;` | busybox 兩台都支援 ✅;`-depth` 使 dot 目錄的內容先處理、目錄最後 `rm -rf`,不會出現刪完後再往下走的情況 ✅;`.fs_state` 不在範圍內 ✅;刪 live upper 與上游 `jffs2reset` 對已掛 overlay 的做法同類,可接受;不碰 `work/` ✅ |
| §6.4 boot_id 綁 `boot-reasons.log` 倒數第二行 | 寫者唯一 = batdata-mount `boot()`,once-per-boot 閂 ✅;fresh trial 由 95 S10 寫 → 早於 S99 ✅(D28 可改 ✅,證據 `95-batman-storage:632,708,753`);arm 那次開機沒寫行(p6 沒掛)→ 不符 → fail-closed ✅;trial 在期限內重開 → 一律回 committed 槽 ✅;95 提早退出(`:86/:135/:251/:339`)→ 本次沒寫行 → 不符 → fail-closed ✅。小建議:解析時用 `cut -d' ' -f2`,不要用 `.* boot_id=` 這種貪婪比對(`:695` 的寫法會取到最後一個) |
| `joinwatch.lastjoined` | ✅(m11 的使用說明) |
| psk_replay vs 協定 §3.4 常數時間、608B 可行性 | 常數時間要改成固定 6 次(m7);綁定對象(m7);608B 標 ⚠️ 並列 #255 合理 |
| `.txn` 一次性對帳 | 機制可以;回滾目標應是交易前的 live 值(m9) |
| 96 用 p6 `prov-state` 當上鎖提示 | 寫者只有 root(99zz/helper);OTS tenant 只有 `apps/<t>` 的 VOLUME/MOUNT,碰不到 `state/` ✅。我擔心過「提示被 trial 的 99zz/helper 覆寫成 unknown 而衰減」,但 p5 讀不到的 trial 一定會 revert(overrides 沒還原 → placeholder key → `expected_in_mesh` 回 1),committed 槽的 helper 會把提示寫回 claimed → 不成立,不列 finding。出口清單見 m10 |
| Q6 | 使用者待決;後果見 §5 |

---

## 4. 逐 actor

| Actor | v5 擋住 | 沒擋住 / 寫錯 |
|---|---|---|
| BLE 路人 | 無 QR 第 1 則即失敗、拿不到 `node_cert` ✅;擁有者額度分開 ✅ | 看過 QR 的人可做存在探針(m7);unclaimed 時能餓死買家(m8) |
| 本機非 root | 新檔都在 root-only run dir 或 p6 0600 + tmp+rename ✅;`ota-armed.mesh` 非 root 寫不到 ✅ | — |
| 攻陷的 provd | 換擁有者 / replay 換人仍需 owner-op + 已存 owner_pub ✅;誠實界線 ✅ | — |
| 攻陷的 tenant | 碰不到 `state/`(manifest 只掛 `apps/<t>`)✅;重置期間 guardian 範本 + firstload 有 marker 檢查 ✅ | 非 fresh 的斷電路徑上,舊 stub 會啟動,但 `apps/` 已空 → start 失敗,只有噪音 |
| 前任擁有者(轉賣) | p6 mkfs、overlay dot、p5 tombstone ✅ | R3 只做一半 + EEPROM 開錯槽 → 前任 seed 回來(m4) |
| 買家(弱 BLE) | replay 不需快取 ✅ | 額度(m8);新 QR 只能經 root(U4) |
| legacy 02/04 第一次 OTA | stage 1 是舊 image 的程式,不寫 `ota-armed.mesh`;trial 上 legacy → 今天的規則 ✅ | — |
| 單台在家更新 | 本次開機沒入網 → commit ✅ | 入網後帶回家沒重開 → revert(m11) |
| 整隊 OTA | `lastjoined` ✅;同時 OTA 也成立(大家都要求鄰居,互為鄰居)✅ | — |
| p5 壞掉的機台 | tombstone 讓前任不會回來 ✅ | 終態矛盾(M2) |
| p6 壞掉的機台 | 前置條件拒絕(L36)✅ | 這種機台無法恢復出廠,只能重燒(寫明即可) |
| 實體 SD | FAT 解析限制 ✅ | 殘留標記造成重置迴圈(m5)、取消後再觸發(m12) |
| 我們自己 | 用到的指令先上機查 ✅(find) | `tune2fs` 不存在(m2)、`-T` 的父程序(m1)、`slot_lock`(m3)、marker step 雙重語意(M1) |

---

## 5. 使用者已定案事項的後果(不重開,只列)

- **U3 擁有權與 SSH 脫鉤**:上鎖後只剩 key 登入(`svr-authpasswd.c:94`)。重置後節點回到 image 預設(04 今天是 `root:::`、`PasswordAuth=on`)→ 接上乙太網的人都是 root(#137)。
- **U4 全清含身分**:新 QR 只能經 root 取得;hostname/SSID 依 MAC 產生,重置前後相同,前後兩任擁有者可以被串起來。p6 mkfs 也會清掉工廠預載的 OTS image tar(`batman-ots-firstload` 的 flash-and-go 來源),重置後的 OTS 節點是「沒有 OTS 的裸機」,與出廠狀態不同(Q4 已定)。
- **U1 608B 之後不重工**:`--clear-tombstone` 的「不同 device_id」條件在 `se` 後端不成立(M3);`psk_replay` 的 KDF 可行性(D31)若不成立,協定 v0.8 要改 app。
- **U6 3A+ 延後**:95(m6 的 Pi 3 MBR 語意)、`platform-ab.sh`(m1)都是兩板共用,bcm2710 ❌。
- **Q5**:L16 是唯一能抓到 M1–M3 的破壞性測試。建議把 M1/M3 的白箱(`--wipe-all` rc 8 + reboot、helper rc 15 `exit 1` × 3)做成 loop 裝置上的 tier-A 測試,不必等 Q5。
- **Q6**:任何 BLE 認領測試都會把 04 上鎖。裝 lab key 之後,harness 靠 key 登入可行(U3 的 dropbear 事實),但 04 從此不接受空密碼;L16 若在 04 跑,重置後又回到空密碼(image 預設)。

---

## 6. 收斂判斷

**有在收斂。** v4 的 1 BLOCKER + 14 MAJOR 全部 addressed,或降成 MINOR(見 §7)。這一輪的 3 條 MAJOR **全部出自同一個機制**:恢復出廠的「下次開機在 p6 掛載前 mkfs」。它有兩個觸發來源(p5 tombstone / p6 marker step ≥ 4),沒有一次性閂,清除條件又綁 device_id。從 v3 起每一輪的 BLOCKER/MAJOR 都有一部分落在恢復出廠的狀態機上(v3 A-B1;v4 B1/A-M1/A-M7;v5 M1–M3)。其他機制(OTA 閘、交易、鎖定、replay)這一輪只剩局部的 MINOR。

**建議砍 / 簡化的地方**(只動恢復出廠):
1. **p6 mkfs 只有一個觸發:p5 tombstone**。拿掉「marker step ≥ 4」(收 M1)。
2. **mkfs 一次性**:tombstone 帶 nonce,新 p6 寫 `state/p6-wiped <nonce>`(收 M3 的 1、2)。
3. **p5-dead 不要「繼續」**:停在 R4、`status` 顯示 `p5-dead: replace the card`、可取消(收 M2)。現場機率低,實體持有者能重燒卡;這樣可以刪掉「p5 讀不到但已重置」這整類狀態。
4. 刪掉「持 slot_lock」的說法(m3),只靠 precheck-node / stage 2 的 marker/tombstone 檢查。

這 4 點都是刪東西,不是加機制。做完之後,恢復出廠的狀態只剩:p6 marker(執行期進度,R1–R4)→ p5 tombstone(R4 之後的唯一真相)→ p6-wiped 閂。

---

## 7. v4 發現核對(一條一行)

| v4 | 狀態 | 說明 |
|---|---|---|
| A4-M1 `find -delete` 不存在 | addressed | p6 改 mkfs;R6 用 `-depth -exec ;`(兩台 `--help` 證實) |
| A4-M2 version 比不上 / 陳舊值 | addressed(殘 m1) | 綁 boot_id + slot ✅;`-T` 仍會寫(m1) |
| A4-M3 匿名 NX 洩漏 | addressed(殘 m7) | psk_replay ✅;QR 持有者探針、5→6 次 |
| A4-M4 prov-txn 自擋 | addressed | rename 後刪 + token |
| A4-M5 wireless 對帳 | addressed(殘 m9) | 開機不對帳 ✅;`.txn` 回滾目標 |
| A4-M6 #202 閘 | addressed | prov-aware、L44 |
| A4-M7 永久 resetting / 凍結只在 p6 | partial | tombstone、取消 ✅;p5-dead 終態矛盾(M2);卡在 R4 時重開清 p6(M1) |
| A4-m1 路徑 | addressed | 絕對路徑 |
| A4-m2 guardian S11 / firstload | addressed | 範本 + firstload + dockerd + joinwatch |
| A4-m3 S13 全暗 | addressed | 刪 S13;S10/S11 mkfs 的時間見 m6 / D30 |
| A4-m4 SD 無身分 | addressed(殘 m5) | 無身分時接受;與 rc 15 的順序(m5) |
| A4-m5 4b 位置 | partial | 「每個出口」✅;括號只列 2 個(m10) |
| A4-m6 `root:!` rc 4 / dev-open | addressed | `final_rc` 視為上鎖;dev-open 不豁免 |
| A4-m7 noload | addressed | `ro` 優先 + 自癒 |
| A4-m8 快取無讀者 | addressed | 刪除 |
| A4-m9 作廢順序 | addressed(殘 m4) | R3 在 R4 前 ✅;R3 失敗仍繼續(m4) |
| A4-m10 reset 中 OTA | partial | precheck 拒 ✅;`slot_lock` 不可持有(m3) |
| A4-m11 flock / state 殘留 | addressed | flock 鎖 marker;p6 mkfs |
| A4-m12 mkfs 規則文件 | partial | p5 ✅;p6 的 95 檔頭未同步(m6) |
| A4-m13 矩陣缺列 | addressed(殘 m1) | L41–L46;L41 的斷言錯(m1) |
| A4-m14 降級 serial | addressed | L12 寫明 |
| B4-B1 `find -delete` / 「繼續」吞資料 | addressed | p6 mkfs |
| B4-M1 version 無來源 | addressed | boot_id |
| B4-M2 單次取樣 | addressed | `lastjoined` |
| B4-M3 prov-txn 自等 | addressed | token |
| B4-M4 wireless 多寫者 | addressed | 開機不對帳 |
| B4-M5 鎖定寫者 / dev-open / harness | addressed | 看實際值;dev-open 不生效;Q6 交使用者 |
| B4-M6 匿名 NX DAC | addressed(殘 m7) | psk_replay;綁定對象 |
| B4-M7 replay DoS | partial | 擁有者 ✅;unclaimed 買家與路人同池(m8) |
| B4-m1 marker 路徑 | addressed | |
| B4-m2 快取 | addressed | |
| B4-m3 L16 斷言 | partial | 改了 ✅;`tune2fs` 不存在、時間假(m2) |
| B4-m4 負對照 (2) | addressed | claimed+placeholder |
| B4-m5 validate 寫狀態 | partial | 父程序判斷擋不住 `-T`(m1) |
| B4-m6 unknown 開放 | addressed | p6 提示;衰減情境不成立(§3) |
| B4-m7 4b 位置 | partial | 同 A4-m5(m10) |
| B4-m8 identity 半寫 | addressed | `prov.tmp` rename |
| B4-m9 prov-state 改判 | addressed | writer 欄 |
| B4-m10 reset 中 OTA | partial | 同 A4-m10(m3) |
| B4-m11 S13 全暗 | addressed | 刪 S13 |
| B4-m12 刪 work | addressed | 不碰 work |
| B4-m13 p6 不在凍結失效 | addressed | tombstone |
| B4-m14 FAT 解析 | addressed | 長度、字元集、regular file |
| B4-m15 `--wipe-all` 規則 | partial | 前提與 LUKS ✅;前提用的 `step=4` 與 95 的 `step ≥ 4` 語意衝突(M1) |

---

## 8. 本輪唯讀探針(原始輸出摘要)

```
04$ tail -3 /opt/batdata/log/boot-reasons.log
  20250623-204049 boot_id=34a5f532 prev=SYSUPGRADE-REBOOT (rc=0 get=0x00000001 thr=0x00000000) — UNCLEAN …
  20250715-141436 boot_id=6d36b85d prev=CLEAN: … trigger=reboot/halt command (last ssh login from 10.41.240.10)
  20250715-141615 boot_id=61327849 prev=CLEAN: …
04$ grep " S1 CHECK" /opt/batdata/log/ota-trace.log | tail -4
  … boot=da2ff64a up=13750 S1 CHECK rc=0 caller=/bin/sh /sbin/sysupgrade -n /opt/batdata/ota-202w2.tar.gz  … upg=n
  … boot=da2ff64a up=13764 S1 CHECK rc=0 caller=/sbin/procd  … upg=y
  … boot=7f972daf up=18324 S1 CHECK rc=0 caller=/bin/sh /sbin/sysupgrade -n /opt/batdata/ota-280.tar.gz  … upg=n
  … boot=7f972daf up=18338 S1 CHECK rc=0 caller=/sbin/procd  … upg=y
firmware-2710 sbin/sysupgrade:370  json_load "$(/usr/libexec/validate_firmware_image "$IMAGE")"   (早於 :403 的 TEST exit)
04$ mkfs.ext4 -V → mke2fs 1.47.0 ; /etc/mke2fs.conf → No such file ; /sys/fs/ext4/features 含 lazy_itable_init
04$ cat /sys/class/block/mmcblk0p6/size → 54109151 ; df /opt/batdata → 25.4G, 5.2G used
04,02$ busybox find --help → -xdev / -maxdepth / -mindepth / -depth / -exec CMD ARG ;   (無 -delete)
04,02$ command -v (逐一) → tune2fs=MISSING dumpe2fs=MISSING timeout=MISSING
                            e2fsck/resize2fs/mkfs.ext4=/usr/sbin  jffs2reset=/sbin  flock=/usr/bin
04$ date → Tue Jul 15 16:18:06 UTC 2025 ; 02$ date → Sat Oct 17 15:16:41 UTC 2026
04$ find /overlay/upper -depth -name '.*' → /overlay/upper/.cache
04$ ls -la /overlay → .fs_state -> 2, upper/, work/
04$ mount → /mmcblk0p4 on /overlay type f2fs ; overlayfs:/overlay on / … upperdir=/overlay/upper ; 5× docker overlay merged
04$ ls /opt/batdata/state → lock-status mesh-expected mesh-joined slot-A.protected slot-B.protected
04$ OTS manifest → VOLUME ots-pgdata/ots-mqdata/ots-appdata, MOUNT rabbitmq-*.conf/eud-gateway.pyz (無 state/)
原始碼:batman-slot:84-96 (slot_lock: cmdline 不含 batman-slot → 接管), :157 (EXIT trap 刪鎖), :534-547 (#202 閘;掛不起 → 不擋);
        95-batman-storage:178-184, :211, :279, :297-301, :350-357, :605-727 (boot: mount → 閂 :632 → pstore :635 → 寫行 :708 → fw_override :721 → refresh/restore :724-725), :753;
        96:64,67,71,89,93; platform-ab.sh:74-83, :92; batman-autocommit:388-397; joinwatch:127-150;
        payload-guardian.sh start_service (`$_DIR` 不在 → return 1); batman-ots-firstload:51-53 (無 tar → no-op)
```

---

## 9. 判定

**REJECT(v5)**:BLOCKER ×0、MAJOR ×3、MINOR ×12。

3 條 MAJOR 都在恢復出廠「下次開機 p6 mkfs」的觸發契約上,修法是 §6 的 4 個刪減(單一觸發、一次性閂、p5-dead 停住、不宣稱 slot_lock)。其餘 MINOR 都是局部的文字與證據修正。依規則,改完要整份再審(兩位);下一輪的重點可以放在恢復出廠的狀態機與 m1/m2 的證據。
