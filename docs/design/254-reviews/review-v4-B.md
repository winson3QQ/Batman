# #254 階段 1 實作設計 v4 — 獨立審查 B(第 4 輪,對抗式)

審查對象:`docs/design/254-stage1-impl.md` v4(branch `design/254-stage1-impl` @ 16274af),整份審,不是只看與 v3 的差。
依據:使用者 CLAUDE.md 的審查規則 + `docs/design/REVIEW.md`。全程唯讀:沒有寫節點、沒有 reboot、沒有 commit、沒有跑 bluetoothctl。

## 0. 結論

**判定:REJECT**(1 BLOCKER / 7 MAJOR / 15 MINOR)。

v4 把 v3 的兩條 BLOCKER 方向都收對了:`ota-armed.mesh` 改在 stage 1 寫;恢復出廠有逐步失敗政策,p5 改用 mkfs。p5 上的 prov 也改成只有 `--prov-only` 一個寫者。`claim/replay`、96 fail-secure、wireless 對帳都補上了。

但這一輪從現場重走一遍,又找到下面幾個問題:

1. **恢復出廠依賴的 `find -delete` 在節點上不存在**(BLOCKER)。02、04 兩台實測都是 `find: unrecognized: -delete`,firmware 的 busybox `.config` 也是 `# CONFIG_FEATURE_FIND_DELETE is not set`。步驟 3、4、8 因此每次都失敗。失敗政策是「3 次後繼續」,結果轉賣出去的機台 p6 上整份前任資料都還在(OTS、apps、docker),overlay 的 dot 目錄也沒清。D26 本來標 ⚠️,這輪查證後確定是錯的。
2. **`ota-armed.mesh` 綁的 `version` 在 trial 端找不到可以比對的來源**:payload `metadata` 的 `version=` 是組 payload 當下的 `date +%Y%m%d-%H%M%S`,rootfs 裡沒有這個值。另外 stage 1 只取樣一次,team OTA 時第二台以後會判成 `radio`,於是 fail-open。
3. **交易與讓路契約會自己等自己**:helper 在持有 `prov-txn` 的期間呼叫 `--save`,剛好撞上「`--save` 遇到 `prov-txn` 要等 ≤ 30 s」的規則。
4. **wireless 對帳是 `wireless.radio1.channel` 的第二個寫者**,另一個寫者是 morse 自己回寫 uci,再加上 99-chanfix。
5. **鎖定欄位並沒有真的「依開機階段分擁有者」**:helper 每次開機都會判斷 `lock-status ≠ LOCKED`,這個值又存在跨槽留存的 p6 上;dev-open 的優先順序沒有定。04 目前靠空密碼讓 harness 登入,任何把 04 認領的測試都會把唯一的乙太網橋鎖死。
6. **`claim/replay` 開放的匿名 NX 會把每一台已認領機台的 DAC 憑證交給任何路人**。這直接違反上層 `219-field-provisioning.md:267` 的追蹤防護。

## 1. 先補:矩陣缺的列、擁有權缺的資源

**缺的生命週期列**
- **L-reset-tooling**:恢復出廠所用的指令在 image 上不存在(→ B1)。
- **L-team-ota**:多台 member 依序或同時 OTA,stage 1 取樣時鄰居正在重開(→ M2)。
- **L-validate-only**:`sysupgrade -T`、LuCI、procd `validate_firmware_image` 單純驗證 image,也會寫 p6 的 `ota-armed.mesh`(→ m5)。
- **L-direct-apply**:`batman-slot apply` 直接從 live 系統呼叫(ab-selftest),不經 stage 1,所以沒有檔案(→ m5)。
- **L-operator-setkey-on-member**:操作員用 root 對 `radio_managed=1` 的節點跑 `halow-setkey --channel`(→ M4)。
- **L-morse-writeback**:fresh trial 上 morse 把硬體預設頻道寫回 uci,與 helper 的對帳、99-chanfix 三方同時動作(→ M4)。
- **L-ota-during-reset**:恢復出廠進行到步驟 1–4 時,fleet 推 OTA 過來(→ m10)。
- **L-reset-p6-vanishes**:步驟 5 到 8 之間斷電,而下次開機 p6 掛不起來(→ m13)。
- **L-unknown-on-trial**:claimed 節點 OTA,fresh overlay 上 96 掛不起 p5,helper 判 `unknown`(→ m6)。
- **L-harness-access**:任何 BLE 認領測試結束後,harness 還能不能進 04(→ M5)。

**缺的資源 / 寫者**
- `wireless.radio1.channel` 的寫者還有 **morse/netifd 回寫**(`99-batman-chanfix:4-9`、`halow-setkey:108,121-125`)和 **99-chanfix**(→ M4)。
- `/opt/batdata/.faketime` 的寫者是 batman-faketime。它在 K09 和定期都會寫,在恢復出廠步驟 4 之後還會再寫回去(→ m3)。
- guardian stub 的寫者是 **batdata-mount S11 的 `restore_payload_guardians`**:每次開機從 image 範本重新產生,而且**直接 `start`**(`95-batman-storage` 產生的 init,`"$dst" running || "$dst" start`)。marker 檢查必須放在範本 `payload-guardian.init.in` 裡,不能只靠刪 stub。v4 寫的是「guardian init 補一行」,方向對,但要明寫是範本。
- `/opt/batdata/docker` 是 p6 `/docker` 子目錄的 bind mount(04 `mountinfo`:`33 29 179:6 /docker /opt/batdata/docker … shared:1`)。dockerd 沒有乾淨停下來的時候,它是 EBUSY 的掛載點。

## 2. BLOCKER

### B1 — 恢復出廠步驟 3/4/8 用的 `find -delete` 在 image 上不存在;失敗政策「3 次後繼續」讓轉賣的機台留著前任的 p6 資料

**情境**:擁有者轉賣 04 這類 OTS 節點,從 app 發起 `factory_reset`。
- 步驟 3 `find /opt/batdata/docker -mindepth 1 -delete`、步驟 4 `find /opt/batdata -mindepth 1 … -delete`、步驟 8 `find /overlay/upper /overlay/work -mindepth 1 -delete` 都是 parse error,rc 1,**一個檔案都沒刪**。
- 照 §4.5 的失敗政策:步驟 3「3 次後繼續,`teardown-partial`」,步驟 4「3 次後 `reason=p6-partial` 並繼續」,步驟 8「失敗 → 繼續(dot 已刪)」。可是 dot 其實沒刪。
- 結果:p5 被 mkfs、身分換新、另一槽作廢,但 **p6 原封不動**:`apps/opentakserver`(OTS DB、憑證、CoT 歷史)、`docker/`(映像與 volume)、`.faketime`,04 上還有一堆操作員檔案(`ota.tar.gz`、`dv289-backup-*`、`lora_*.py`…)。下次開機,S11 會依 `apps/*/*.manifest` **把前任的 OTS guardian 重新產生並啟動**。新擁有者拿到的是一台跑著前任 TAK server 的機台。`/overlay/upper/.cache/Tailscale` 也還在。
- 要觸發多少次才走到「3 次後」,文件沒有定(「下次開機重試」= 要重開 3 次?)。

**證據(本輪實測,唯讀)**
- 04 和 02:`ls -la $(command -v find)` → `/usr/bin/find -> ../../bin/busybox`;`find /nonexistent-zz-254 -delete` → `find: unrecognized: -delete`,`rc=1`。`busybox find --help` 的 Actions 只有 `-print`、`-print0`、`-exec CMD ARG ;`,沒有 `-delete`,也沒有 `-exec … {} +`。
- firmware-2710 `build_dir/target-aarch64_cortex-a72_musl/busybox-default/busybox-1.36.1/.config`:`:476 # CONFIG_FEATURE_FIND_DELETE is not set`、`:467 # CONFIG_FEATURE_FIND_EXEC_PLUS is not set`。
- 設計 §7 D26 自己標了「⚠️ 待 PR-P1 上機 `find --help`」。依規則「Probe unverified assumptions read-only before the design is approved」,現在已經查證:**不成立**。

**第二層問題(即使換成 `rm -rf` 也存在)**:失敗政策把 p6 沒清乾淨當成可以接受的結果(`p6-partial` 之後繼續做 mkfs p5、清 overlay、重開)。p6 清不乾淨的情況包括 EBUSY 的 bind mount、I/O error、immutable 檔。這時結果正是 v2/v3 一直要擋的「前任擁有者的節點」,只是換成 tenant 資料這一層。§4.5 對 p5 的規則是「停在此步(否則會還原前任)」,p6 這邊卻是「繼續」,兩邊不一致。p6 上的 apps/docker 下次開機**會被自動啟動**,不是惰性的殘留。

**修法**
- 步驟 3/4/8/11 改用 busybox 實際有的寫法。例如 `for e in "$d"/* "$d"/.[!.]* "$d"/..?*; do [ -e "$e" ] || [ -L "$e" ] || continue; …; rm -rf -- "$e"; done`,或 `find "$d" -mindepth 1 -maxdepth 1 ! -name state ! -name lost+found -exec rm -rf {} \;`(只用 `-exec ;`)。或者在 busybox diffconfig 開 `FEATURE_FIND_DELETE`,這是兩板共用 image 的改動,要列進 U6 殘項。不論選哪個,§7 都要附上機證據。
- `apps/`、`docker/` 刪不掉時**不准繼續**:停在步驟 4(同步驟 5 的政策),status 顯示 `p6-busy`,下次開機重試。或者把 p6 也改成 mkfs:p6 本來就整個清,只留 `state/factory-reset.inprogress`。mkfs 前先把 marker 搬到 `$RUNDIR`,mkfs 後寫回。mkfs 一次就解決 dot、bind、lost+found 三個問題。
- dockerd 停不下來、或 bind mount 還在時,先 `umount /opt/batdata/docker`(moby 的 root propagation bind,`stop` 正常會卸掉)。
- 「3 次」寫明單位(開機次數或同次重試),以及誰觸發重開。
- **負對照**:(a) 在 04 類節點(有 `apps/opentakserver`)做 L16 → 重開後 `ls -A /opt/batdata` 只剩白名單、`/etc/init.d/batman-payload-*` 不存在、`docker ps -a` 空。v4 寫法下三條都會 FAIL。(b) 白箱讓 `/opt/batdata/docker` 保持 bind 掛著 → 必須停在步驟 4,不可以走到步驟 5。

## 3. MAJOR

### M1 — `ota-armed.mesh` 的 `<payload_version>` 在 trial 端沒有可比對的來源 → member 永遠 fail-closed(單台在家更新又會被 revert)

**證據**
- `scripts/build-ab-payload.sh:69`:`printf 'board=%s\nversion=%s\nsize=%s\n' "$BOARD" "$(date +%Y%m%d-%H%M%S)" "$SQ_BYTES" > "$T/metadata"`。
- 04 上實際的 payload `/opt/batdata/ota.tar.gz` 的 metadata 是 `version=20261018-113030`;04 的 `/etc/batman-build` 是 `BATMAN_VERSION=1.5.12-wsl.3+f2f2bf6.fw8b33f3e`。兩者沒有共同欄位。
- `batman-slot apply`(`:625-705`)不會把 metadata 抄到目標槽的 boot FAT 或 rootfs;stage 2 也沒有其他地方留下它。
- §6.4 寫「`ota-armed.mesh` 的 slot 與 version == 本 trial 且值 = `radio` → 不要求」。trial 取得不到 metadata version,所以這個比對**永遠不符**,一律落到 fail-closed 的 `joined` 分支。

**結果**:L31「單台在家更新」照字面實作會 revert,也就是 v3 B-M5 原本要修的問題沒有修到。如果實作者自己改成拿 `BATMAN_VERSION` 比對 metadata,就是兩個不同來源的字串,永遠不相等。如果只比 slot,又失去「上一次 OTA 留下的殘檔」的保護。

**修法**:綁一個兩端都看得到的值。
- `build-ab-payload.sh` 從 rootfs 讀 `/etc/batman-build` 的 `BATMAN_VERSION`(或 `BATMAN_BUILD_DATE`+commit),寫成 metadata 的 `build=`。stage 1 寫這個值,trial 拿自己的 `/etc/batman-build` 比對。
- 或者綁 `<target_slot> <arming boot_id>`,trial 用 p6 `boot-reasons.log` 的上一行 boot_id 比對(batdata-mount 已經寫了這一行)。

**負對照**:member 單台、無鄰居,用真的 `build-ab-payload.sh` 產物 OTA → commit。照 v4 的字面讀法會 revert。

### M2 — stage 1 只取樣一次 `meshjoin_joined`,team OTA 時第二台以後判 `radio` → 有鄰居的 member 只檢查 `radio_up`(fail-open)

**情境**:兩台以上的 member,擁有者或 harness 依序推 OTA。第一台在 stage 2 或 trial 開機時,它的 radio 不在網上。第二台這時跑 stage 1:`iw station dump` 和 `batctl n` 看不到第一台 → `m=radio`。第二台的 trial 就不要求鄰居。若新 image 會讓 mesh 斷(SAE 壞、頻道不對,也就是 §6.4 負對照 (4) 的情形),第二台照樣 commit,被丟在網外。兩台的 fleet(02+04 正是這樣)最容易發生。

**證據**:`meshjoin.sh:14-22`:`meshjoin_sample` 是當下的 `iw dev wlh0 station dump` + `batctl n`,沒有歷史。§6.4:「`meshjoin_sample; meshjoin_joined && m=joined || m=radio`」。B3-B1 的修法本來提過替代方案:joinwatch 每次 JOINED 寫 `mesh-last <boot_id> <uptime>`。v4 沒有採用。

**修法**:stage 1 的判定改成「本次開機曾經 JOINED,或 p6 上有 `mesh-joined`(joinwatch 寫的)」→ `joined`。只有「這個 member 從來沒有入網過」才判 `radio`。也就是用歷史訊號,不用一次取樣。

**負對照**:兩台 member,A 先 OTA 進入 trial(radio 離網)的同時讓 B 跑 stage 1,B 的 image 預設頻道改成 A 不用的頻道 → B 必須 revert。v4 會 commit。

### M3 — helper 持有 `prov-txn` 時自己呼叫 `--save`(以及 `--prov-only`)→ 撞上「`--save` 遇到 `prov-txn` 等 ≤ 30 s」的規則,自己等自己

**證據**
- §3 `prov-txn` 那一行:「`batman-config-save` 寫入模式:存在且 pid 活著且 cmdline 含 `batman-provhelper` → `--on-join` 回 1;操作員 `--save` 等 ≤ 30 s」。
- §4.4 步驟 5:「→ `batman-config-save --save` … → 刪 prov-txn」。§6.1 步驟 4 `--save`,步驟 6 才刪 prov-txn。
- config-save 認的是「pid 活著且 cmdline 含 batman-provhelper」,沒辦法分辨呼叫者是不是持有者本人。§4.3 的 `--prov-only` 也是「寫入模式」,是不是同樣要讓路,沒有寫。
- §4.1:helper socket 逾時 30 s。

**結果**:每次認領或 `net.apply`,`--save` 至少卡 30 s,之後怎麼處理沒有定義。若視為失敗 rc 1:新的 root 密碼 hash(shadow-root)沒進 p5,下次 OTA 之後 96 會設成 `root:!`,擁有者剛拿到的密碼失效。若 `--prov-only` 也要讓路:步驟 3 再卡 30 s,provd 先逾時,告訴 app「失敗」,可是節點其實已經提交了 → app 重送 → `E_STATE` → 只能走 `claim/replay`,又換一次密碼。

**修法**:讓路規則排除持有者。例如 helper 呼叫 config-save 時帶 `--txn <token>`,token 與 `prov-txn` 內容相符就不讓路。或者 config-save 比對 `prov-txn` 的 pid == 自己的 `$PPID`。並寫明 `--prov-only` 不受 prov-txn 影響。helper 的 socket 逾時要大於整個交易的最壞時間。

**負對照**:計時一次認領,斷言總時間 < 10 s,p5 `identity/shadow-root` 的 hash == 回應的密碼。照 v4 的字面讀法會 > 30 s 或沒有寫入。

### M4 — wireless 對帳是 `wireless.radio1.channel` 的第二、第三個寫者(morse 回寫、99-chanfix、操作員 `halow-setkey`)

**證據**
- `99-batman-chanfix:4-9`:fresh slot 上 morse 在 regdomain 還沒穩定時「falls back to its hardware-default channel (42) AND writes 42 back into uci」;太早 `wifi reload` 沒有用,要晚一點再 reassert。它在背景最多重試 6 次,每次 `uci commit wireless; wifi reload`。
- `halow-setkey:108,121-125`:morse 拒絕頻道時,uci 會被改成硬體預設;setkey 接著「restoring channel ${prev_chan}」,這裡的 `prev_chan` 是**呼叫前 uci 的值**,可能已經是 morse 寫回的 42,然後 `exit 3`。
- §4.4 步驟 7:`--apply-state`(S89 開機,以及 helper 重啟後)只要 live uci 的 channel ≠ prov,就經 `halow-setkey --no-persist` 改回去。

**情境**
- (a) member OTA trial(fresh overlay):約 50 s 時 morse 寫回 42,S89 helper 看到 42 ≠ 40 → setkey `--channel 40` → `wifi reload`。同一時間 99-chanfix 在背景也 reload。這正是 chanfix 註解說「太早 reload 會再掉回 42」的時間點。兩個寫者都沒有協調。autocommit 計 dwell 的那段時間,頻道一直在抖。
- (b) helper 在現場 crash 後 respawn(L8/L11),`--apply-state` 若碰到 morse 寫回的值,就在執行期觸發一次 `wifi reload`,mesh 斷一次。L2 宣稱「一致 → 無 reload」,這只在 morse 從不回寫時才成立。
- (c) 擁有者用 root(他有 root 密碼)對 member 跑 `halow-setkey --channel 44`,p5 也存了。下次開機 helper 把它改回 prov 的值,`--on-join` 再寫回 p5。操作員的設定被無聲地推翻,`halow-setkey` 的使用說明和 `P5_STALE_HINT` 也沒提到這件事。
- (d) 對帳用的是 `--no-persist`。節點沒有入網(在家單台)時,`--on-join` 不會跑,p5 會比 live 舊 → stage 1 `--check` rc 5 → **OTA 被擋**,直到入網為止。

**修法**:§3 明定 `radio_managed=1` 時 wireless 的 SoT 是 prov,live uci 是衍生值。
- `--apply-state` 的對帳延後到 radio 穩定之後(例如 wlh0 存在、mesh point,並且晚於 99-chanfix 結束),只 reassert 一次,之後交給 joinwatch。或者在 fresh boot 上由 99-chanfix 一個寫者處理,helper 只負責非 fresh 的開機。
- `halow-setkey` 在 `radio_managed=1` 時拒絕或警告,除非帶 `--prov`(helper 專用)。
- 對帳之後若未入網,用 `--save` 而不是 `--no-persist`,或在 `--check` 把 prov 管理的 key 排除。
- **負對照**:member trial,把 p5 channel 設成非預設(40),斷言 dwell 期間 `logread | grep -c 'reloading wifi'` ≤ 1,且最終 channel = 40。另外,執行期 `kill` helper 讓它 respawn,斷言沒有 wifi reload。

### M5 — 鎖定欄位不是「依開機階段分擁有者」:helper 每次開機都看 p6 `lock-status ≠ LOCKED` 決定要不要上鎖;dev-open 優先順序未定;04 被認領後 harness 進不去

**證據**
- §4.4 步驟 7「完成未完的轉換:state ∈ {claimed, member} 而 `lock-status` ≠ LOCKED → helper 上鎖」。L2 說每次開機都跑,fresh 開機也跑(S89)。所以 fresh 開機時,96(S10)和 helper(S89)**都寫**鎖定欄位,不是 §3 說的分時段。
- `lock-status` 在 p6(`96:161` `/opt/batdata/state/lock-status`),跨槽保留。dropbear/ttylogin 在 overlay,OTA 時會重置。兩者可能脫鉤:96 在 `:71`、`:89`、`:93` 提前 exit 時不重寫 `lock-status`,p6 上還是上一槽的 `LOCKED`,helper 看到 LOCKED 就不鎖,可是 overlay 的 dropbear 是 image 預設的 `PasswordAuth=on`、root 無密碼。節點是開著的,狀態卻顯示 LOCKED。
- `96:165-166`:今天 dev-open 先判,寫 `DEV-OPEN`。v4 §4.3 寫「claimed/member 一律上鎖」,沒說 dev-open 是否優先。若 96 保留 dev-open 優先,helper 在 S89 看到 `DEV-OPEN ≠ LOCKED` 就上鎖,兩個寫者在同一次開機互相推翻。
- **04 實測**:`/etc/dropbear/authorized_keys` 不存在、`root:::`(空密碼)、`PasswordAuth='on'`。harness 的 `ssh -o BatchMode=yes`(`scripts/daily-validation.sh:71,157,250…`)能登入 04,靠的就是空密碼。04 是唯一有 BLE、也是唯一有乙太網的節點。L34、L5 `prov-lock-failsecure-254`、L16,以及所有正向認領測試,都需要一台已認領的 BLE 節點,也就是 04。04 一被認領,`PasswordAuth=off` + `root:!` → harness 失去 04,主機到 mesh 的唯一橋也斷了。§9「破壞性測試先列副作用與還原」只對 L16 寫了 Q5,認領本身沒有寫。

**修法**
- helper 的完成判斷改看**實際值**(uci `dropbear.*.PasswordAuth`/`RootPasswordAuth`、`system.ttylogin`、shadow),不看 `lock-status`。
- §3 明寫 fresh 開機時 helper 只確認、不寫,除非 96 的 verdict(`/etc/.batman-prov-restore`,有 boot_id)顯示它沒有跑到 4b。
- 定 dev-open 的優先順序。建議:dev-open 對 claimed/member 仍然上鎖,但保留**已存在**的 `authorized_keys`。
- harness 的前置步驟:認領測試之前先在 04 裝 lab key(副作用清單 + 還原步驟),否則不排。
- **負對照**:(a) claimed 節點 OTA,白箱讓 96 在 `:89` exit → 斷言 helper 仍然上鎖(v4:p6 LOCKED 擋住了,不鎖)。(b) 04 有 lab key 時認領 → harness `up()` 仍然成功。

### M6 — `claim/replay` 的匿名 NX 例外讓任何路人拿到每一台已認領機台的 DAC 憑證(穩定識別碼)→ 追蹤

**證據**
- `219-protocol.md` §3.1:「已認領的節點一律拒絕沒有 PSK 的 `NX`(防止降級)」;第 2 則交握訊息的 payload = `node_cert`,內含 DAC 鏈。CN = `device_id`,serialNumber = `sn`(§3.3)。
- `219-field-provisioning.md:267`:已認領的機台「app 必須先證明持有擁有者金鑰或網路金鑰,節點才送出 DAC 與 `device_id` — 防止任何人連上 GATT 就拿到明文的身分(追蹤)」;`:623` 也是同一點。
- v4 §1.3、§4.8:「claimed|member 允許匿名 NX 只為 `claim/replay`」。交握在任何應用訊息之前就完成了,所以 DAC 在 helper 驗 CheckMac **之前**就已經送出。§8 沒有這一列。

**結果**:`adv_owner` 輪替、RPA 這些防追蹤設計全部失效。路人只要連上 GATT、做一次 NX,就拿到不會變的 `device_id`。也能確認「這是一台 Batman 已認領節點」。單一擁有者的機台(v4 只對單一擁有者開例外)正是民用的主要情境。

**修法**(擇一,協定 v0.7 要寫清楚)
- (a) replay 改用 `NXpsk0`,`psk_replay = HKDF(claim_secret, "batman-replay-v1" ‖ owner_pub)`。app 有 QR,所以有 claim_secret;provd 經 helper 拿到導出值。被攻陷的 provd 本來就已在節點上,不擴大權限。
- (b) 讓 `owner_tag_key` 可以由 app 自己重新導出(例如 `ECDH(owner_priv, ecdh_pub)` 經 KDF),從根本上不需要 replay。
- (c) 已認領時匿名 NX 的第 2 則 payload 不放 `node_cert`,DAC 等 CheckMac 與 owner-op 驗過之後才給。代價是 app 在送 CheckMac 之前無法驗證節點身分,要評估中繼攻擊。

**負測試**:路人(沒有 QR、沒有私鑰)對已認領節點做 NX,斷言拿不到任何 DAC 或 `device_id` 位元組。v4 拿得到。

### M7 — replay 不受限次數、失敗計數在 provd 記憶體:`claim/replay` 成為已認領節點上常開、匿名、會改狀態的動詞(新 DoS 面)

**證據**:§4.1 `claim.replay` 的效果是「產新 root 密碼(同 `root_password.reset`)→ shadow → `--save`」,每成功一次就寫一次 p5。§3 的失敗計數在 provd 記憶體,provd respawn 就歸零(L8「無限 respawn」)。replay 對已認領節點**永遠開著**,沒有認領窗口。

**情境**:能驗過的只有「QR + 擁有者私鑰」,所以路人改不了狀態。問題是匿名 session 的存在本身。M6 的身分洩漏是一點;另外,每次匿名 NX 都讓 helper 做一次 `nonce` 加 DAC 簽章(`sign.static` 全域 2/s),路人可以把這個額度吃滿,讓擁有者自己的 NXpsk0 session 在 2/s 的全域限制下拿不到 `sign.static`。這是新的 DoS 面。v3 的已認領節點對匿名請求一律拒絕,沒有這個面。

**修法**:匿名 NX 的 `sign.*` 額度和 NXpsk0 分開計(匿名的額度可以很小);replay 的失敗計數放在 helper(provd respawn 不歸零);replay 成功時若和上一次間隔不到 X 分鐘,不換密碼,直接回傳同一份。**負測試**:路人以 10 Hz 做匿名 NX 時,擁有者的 NXpsk0 交握仍然在 2 s 內完成。

## 4. MINOR

- **m1 — marker 路徑寫了兩種**:§4.3 `--prov-only` 寫「`$RUNDIR/factory-reset` 檢查」,其他地方都是 p6 的 `$ST/factory-reset.inprogress`。要統一,否則 `--prov-only` 在 reset 期間不會被凍結。
- **m2 — 認領回應快取沒有讀者**:§6.1 步驟 5「helper 快取 10 分鐘」,可是 §4.1 沒有讀它的動詞。已認領之後,app 重送 `claim/finish` 只能走匿名 NX,而 §4.8 規定這個管道只接受 `claim/replay`,所以快取永遠讀不到。二選一:讓 `claim/finish` 以同一個 `idem_key` 重送時回快取(並列入 NX 例外),或刪掉快取。root 密碼在 helper 記憶體多留 10 分鐘也是暴露。
- **m3 — L16 的結果斷言有三條會誤判 FAIL**:
  - 「hostname 新」:`99-halow-identity:9-14` 由 `morse_generate_default_hostname`/MAC 產生(例如 `BCM2711-47ee`),恢復出廠後**一樣**。應改成「== image 依 MAC 產生的預設」。這也代表 SSID=hostname 跨擁有者可追蹤,屬於殘項 B-m8。
  - 「p6 只剩白名單」:`batman-faketime` 在 K09 和定期都寫 `/opt/batdata/.faketime`(`usr/sbin/batman-faketime:14`、`init.d/batman-faketime:6,10`),步驟 10 正常 shutdown 時就會寫回來。
  - 96 在 fresh 開機寫 `state/lock-status`(`96:161`),batdata-mount 寫 `log/`;所以白名單不能是「state/(空)」。
  - 依規則,FAIL 會要求歸因;斷言本身寫錯,就會變成無謂的 ❓。
- **m4 — §6.4 負對照 (2)「unclaimed OTA → commit(1.5.12 revert)」不能分辨新舊版**:unclaimed 的 p5 沒有 `.seeded`,1.5.12 的 `batman-slot precheck-node` 在 stage 1 就拒絕(`batman-slot:534-547`「p5 (config) is not seeded」)。即使用 allow-unseeded 繞過,1.5.12 的 `expected_in_mesh`(`batman-autocommit:388-396`)對未 seed 的 p5 也回 1 → NEED_MESH=0 → commit。真正能分辨的是「unclaimed 認領後 `--save` 已 seed、key 仍是 placeholder」的 claimed 節點。
- **m5 — 只做 image 驗證也會寫 p6 狀態檔**:`platform-ab.sh:74-75` 的不變式是「Stage 1(also run by validate_firmware_image / `sysupgrade -T` / LuCI): trace the verdict ONLY — no state file, so a mere validation leaves nothing that a later boot could misread as an OTA」。v4 在 `platform_check_image` 寫 p6 的 `ota-armed.mesh`,違反這條。另外 `batman-slot apply` 直接從 live 系統跑時(ab-selftest)不經 stage 1,讀到的是驗證留下的殘檔。修法:改寫 `$RUNDIR`(會跨進 ramfs),由 stage 2 apply 成功 arm 之後再搬到 p6t;或者只在 `$PPID` 是 sysupgrade 時寫。
- **m6 — `unknown` 判決在 §1.4 沒有列(鎖定、AP、autocommit)**:claimed 節點 OTA,fresh trial 上 96 在 `:89` 掛不起 p5 → exit 0,沒有 Lane A、B,也沒有 4b → image 預設(`PasswordAuth=on`、root 無密碼、`ttylogin=0`)。helper 判 `unknown(p5-unreadable)`,不鎖(§4.4 步驟 7 只對 claimed/member)。乙太網和 serial 開放到 revert 為止。autocommit 碰巧會 revert(`expected_in_mesh` 遇到 unreadable 回 0 → NEED_MESH),但沒有寫進設計。§8「fail-secure」的宣稱要縮小範圍,或者規定 `unknown` 且 p6 上有 `mesh-expected`/`lock-status=LOCKED` 時上鎖。
- **m7 — 96 4b 仍在 `:93`(`.seeded` 檢查)之後**:claimed 但 p5 未 seed 的情形會跳過鎖定。這發生在 unclaimed 認領時 §6.1 步驟 4 `--save` 失敗:`--prov-only` 已提交,`.seeded` 還沒寫。v4 只把 prov 抄寫移到 `:93` 之前,4b 的 claimed/member 分支也要一起移。
- **m8 — p5 上不完整的 `identity/prov/` 永遠不會修**:§4.3「`--prov-identity` 只在 p5 無 `identity/prov/` 時寫」。第一次 persist 寫到一半斷電(新卡第一次開機,或 legacy rc 9),p5 會留下不完整的目錄。之後的補寫都被這條規則跳過。下一次 OTA(fresh overlay)時 96 驗 sha 失敗不抄 → helper `unknown(prov-corrupt)` → 只能 SD 重置,擁有權就丟了。修法:p5 上寫到 `identity/prov.tmp/` 再 rename;條件改成「p5 沒有**完整且 sha 對**的 identity」。
- **m9 — fresh 開機時 `prov-state` 先由 99zz(S10)寫,S89 helper 之後可能改判**(p5 gen 較新、`prov-corrupt`)。autocommit 只在啟動時讀一次(`batman-autocommit:388-399`)。99zz 的 boot_id 與本次相符,autocommit 不會等,直接用了之後可能被推翻的值。修法:檔案加 `writer=99zz|helper` 欄位;fresh trial 上 autocommit 等到 helper 版本出現(≤ 60 s),或者 helper 改判時重算 NEED_MESH。
- **m10 — 恢復出廠進行中可以被 OTA**:前置條件只在開始時查一次 `slot_lock`/tryboot;reset 期間沒有持鎖,`precheck-node` 也不看 marker。步驟 1–4 時 p5 仍是 seeded 且 fresh,stage 1 會通過,stage 2 殺掉 helper 並寫另一槽,trial 帶著 marker 開機,接著和 S13 續做、步驟 7 `invalidate-other`(trial 上 rc 2)互相干擾。修法:reset 全程持 `slot_lock`,或者 `node_checks` 在 marker 存在時拒絕。
- **m11 — S13 阻塞期間節點是全暗的**:「續做時不會全暗」只在 S13 返回之後才成立。S13 在 S19 dropbear、S20 network、S61 bluetoothd、S92 provd 之前跑。步驟 4 在 04 這種 p6 上(docker overlay2,數萬個檔案)可能要好幾分鐘;步驟 5 rc 8 會重試 10×5 s。procd 對 `boot` 參數沒有逾時(`procd rcS.c:160-163` 只有 stop/shutdown 是 15 s),所以會一直等,畫面上像當機。要寫預期時間和 LED 指示,並限制 S13 內每一步的時間,太久就交給 S89 helper 在背景做。
- **m12 — 步驟 8 直接刪 live overlay 的 `upper/` 和 `work/`**:kernel `Documentation/filesystems/overlayfs.rst`「Changes to underlying filesystems」寫明行為未定義。刪 `work/work` 之後的 copy-up(步驟 9、10 的 shutdown 寫入)可能 EIO。jffs2reset 本來也會刪 upper,這點是上游接受的,但 work 不需要碰。建議只刪 upper 裡的 dot 項目,其他交給 jffs2reset/PENDING(D22 ✅)。
- **m13 — p5 凍結只靠 p6 marker**:步驟 5 到 8 之間斷電,下次開機 p6 掛不起來 → marker 看不到 → config-save 不凍結;helper `--prov-get` rc 7 + overlay(前任)identity 完整 → 依 §4.2「補 persist」,前任的 prov 與身分寫回 p5。機率低(需要兩個故障),但結果是前任擁有權復活。修法:步驟 5 mkfs 之後在 p5 放 `.resetting` tombstone;`--prov-get` 遇到它回專用 rc,helper 不補寫;步驟 11 再刪掉。
- **m14 — 新攻擊面沒有寫進 §8**:S13 是 root,在早期開機解析 FAT 上的內容(實體可寫)。要定長度上限(例如 `head -c 64`)、字元集 `[0-9a-f]` 或 `any`、只讀 regular file。另外,續做前要比對 marker 的 `device_id` == 本機(A3-m12 的要求),v4 marker 有這個欄位,但沒有寫要比對(防止搬卡)。
- **m15 — `--wipe-all` 改變了 config-save 的硬規則**:`batman-config-save:103-109`「NEVER mkfs a non-ext4 partition … only --seed may format」。v4 允許對非 ext4、非 LUKS 的 p5 做 mkfs,方向是對的(A-B1 需要),但要做到兩件事:改寫該段註解和 `p5-config-partition.md`;LUKS 的判定寫清楚(offset 0 的 `LUKS\xba\xbe` 與 LUKS2 第二標頭)。`--wipe-all` 也要以 marker 存在且 step ≥ 5 為前提,避免成為一個隨手的 root 清 p5 指令。

## 5. v3 發現 → v4 核對(一條一行)

| v3 | 狀態 | 一行說明 |
|---|---|---|
| A3-B1 恢復出廠失敗政策 / p5 壞死鎖 | partial | 政策與 mkfs 有了;但 `find -delete` 不存在,p6 的「3 次後繼續」→ B1 |
| A3-M1 ota-armed stage 2 算不出 | partial | 改到 stage 1 ✅;version 無來源(M1)、單次取樣(M2) |
| A3-M2 `--no-persist` 仍 commit / 不對帳 | partial | 對帳有了;與 morse 回寫、chanfix、操作員打架(M4) |
| A3-M3 rc 6 已寫 | addressed | `--prov-only` 無 rc 6 + 讀回 gen |
| A3-M4 legacy 被解鎖 | addressed | 步驟 7 legacy/unclaimed 不寫 |
| A3-M5 96 4b fail-open | partial | claimed/member 上鎖 ✅;`:71/:89/:93` 提前 exit、`lock-status` 跨槽、dev-open(M5、m6、m7) |
| A3-M6 身分重產 | addressed | rc 表與「補 persist」;部分寫入見 m8 |
| A3-M7 續做並行 | addressed | S13 阻塞 + init 拒啟;guardian 要改範本(§1) |
| A3-M8 認領回應遺失 | partial | replay ✅;追蹤(M6)、DoS 面(M7)、快取無讀者(m2) |
| A3-M9 L16 在 02 無路可回 | addressed(待使用者) | Q5;認領本身的 harness 影響未列(M5) |
| A3-M10 rc 表 | addressed | §4.2 完整 |
| A3-m1 R43 證據 | addressed | 改用原始碼 |
| A3-m2 dot 項目 | open | 修法用的 `find -delete` 不存在(B1);刪 work 有 UB(m12) |
| A3-m3 on-join/check 語意 | addressed | §4.3 |
| A3-m4 meta 格式 | addressed | 一份定義 |
| A3-m5 SD 標記 FAT | addressed | `boot-devs` 兩個都讀 |
| A3-m6 legacy 門 overclaim | addressed | 誠實改寫、`qr` 不收 pts |
| A3-m7 psks 界線 | addressed | §4.1/§8 |
| A3-m8 ble-ok 條件 | addressed | 兩個 FAT + clock + 10 分鐘 |
| A3-m9 root 密碼時機 | addressed | §6.1;但寫入被 M3 卡住 |
| A3-m10 擁有權缺寫者 / `$RUN` | partial | 補了 96/99zz;缺 morse 回寫、faketime、S11 guardian(§1) |
| A3-m11 `--on-join` seed 未 seed p5 | partial | 凍結 ✅;p6 不在時 fail-open(m13) |
| A3-m12 新 p6 檔契約 | partial | 0600/-O ✅;續做比對 device_id 未寫(m14) |
| A3-m13 lost+found | addressed | 清內容 |
| A3-m14 ssh_keys 標記 | addressed | sidecar |
| B3-B1 ota-armed stage 2 | partial | 同 A3-M1(M1、M2) |
| B3-M1 p5 prov 兩寫者 | addressed | 只有 `--prov-only`;但讓路規則自鎖(M3) |
| B3-M2 reset 期間 p5 未凍結 | partial | marker 凍結 ✅;p6 不在時 fail-open(m13)、reset 期間可被 OTA(m10) |
| B3-M3 dot 目錄 / R43 | open | 工具不存在(B1);R43 更正 ✅ |
| B3-M4 SD 標記位置 | addressed | 兩個 FAT、`boot-devs` |
| B3-M5 認領回應遺失 | partial | 同 A3-M8(M6、M7、m2) |
| B3-m1 rc 10 | addressed | meta 最後寫 + rc 表 |
| B3-m2 身分產生條件 | addressed | rc 7/9 + 補 persist |
| B3-m3 legacy persist 改 overrides | addressed | `--prov-only` |
| B3-m4 qr pty | addressed | 實體 console |
| B3-m5 psks 界線 | addressed | |
| B3-m6 meta 副本 / fail-open | partial | 同 A3-M5 |
| B3-m7 單 FAT ble-ok | addressed | |
| B3-m8 clear_root | addressed | `invalidate-other` 讀 `bytes_used`(offset 40 正確) |
| B3-m9 reset 撞 tryboot | addressed | 前置 + disarm;進行中被 OTA 見 m10 |
| B3-m10 trial prov-state 順序 | partial | 99zz S10 ✅;helper 改判後 autocommit 不重算(m9) |
| B3-m11 L20 / boot_id | addressed | |
| B3-m12 provd DoS revert | addressed | health 不看 provd 存活;新 DoS 面見 M7 |
| B3-m13 p6 未掛 / 編輯錯 | addressed | 前置條件、守門改成 device_id |

## 6. 使用者已定案事項的後果(不重開,只列)

- **U3 擁有權與 SSH 脫鉤**:claimed 之後 `root:!` + `ttylogin=1`,serial 也進不去。擁有者遺失 app 或密碼時只剩 SD 重置,而 SD 重置在 B1 修好之前清不乾淨 p6。另外 harness 對 04 是靠空密碼登入(M5)。
- **U4 全清含身分**:恢復出廠後新 QR 只能經 root 取得;hostname/SSID 依 MAC 產生,恢復出廠後不變,前後兩任擁有者的機台可以被串起來(m3)。
- **U6 3A+ 延後**:B1 若改 busybox config,是兩板共用的改動;`platform-ab.sh` stage 1、`build-ab-payload.sh` metadata(M1)也都兩板共用,bcm2710 ❌。
- **U5 改名探針**:L23 仍是 ⚠️。
- **Q5**:L16 的位置與還原方式待使用者決定。補充:04 一被認領 harness 就失聯,這是任何 BLE 正向測試的前置問題,不只限於 L16(M5)。

## 7. 逐 actor 小結

- **BLE 路人**:改不了狀態 ✅。拿得到 DAC/`device_id` 可以追蹤(M6);能吃滿 `sign.*` 額度(M7)。
- **攻陷的 provd**:界線照 v4 §4.1 的誠實寫法;replay 綁 owner_pub ✅。
- **本機非 root**:新增的 p6 檔都是 0600 + -O ✅。
- **前任擁有者(轉賣)**:p6 / OTS / docker 全部留著,下次開機自動重新啟動(B1);m13 是低機率的擁有權復活。
- **買家**:認領會卡 30 s 以上,密碼可能沒持久化(M3)。
- **legacy 02/04 第一次 OTA**:mesh 閘照今天的規則 ✅;rc 9 身分產生 ✅。
- **單台在家更新的擁有者**:member 會被 revert(M1);對帳後沒入網,OTA 會被 p5 stale 擋(M4 d)。
- **member 團隊 OTA**:第二台以後 fail-open(M2)。
- **p5 壞掉的機台**:mkfs 出口 ✅(負對照 d)。
- **實體 SD 持有者**:本來就擋不住;S13 解析 FAT 要加限制(m14)。
- **我們自己**:未驗證的 D26 是錯的(B1);讓路規則自鎖(M3);L16 斷言寫錯(m3);負對照 (2) 不能分辨新舊版(m4)。

## 8. 本輪唯讀探針(原始輸出摘要)

- 04、02:`ls -la $(command -v find)` → `/usr/bin/find -> ../../bin/busybox`;`find /nonexistent-zz-254 -delete` → `find: unrecognized: -delete`,`rc=1`;`busybox find --help` Actions 只有 `-print`、`-print0`、`-exec CMD ARG ;`。
- firmware-2710 busybox `.config`:`:467 # CONFIG_FEATURE_FIND_EXEC_PLUS is not set`、`:476 # CONFIG_FEATURE_FIND_DELETE is not set`。
- procd `rcS.c:160-163`:只有 `stop`/`shutdown` 設 `run_timeout = 15000`;`boot` 沒有逾時。
- 04 `/opt/batdata/ota.tar.gz` 的 metadata:`board=ekh-bcm2711`、`version=20261018-113030`、`size=112631352`;`/etc/batman-build`:`BATMAN_VERSION=1.5.12-wsl.3+f2f2bf6.fw8b33f3e`、`BATMAN_BUILD_DATE=2026-10-18`。02:`1.5.12-wsl.2+f2f2bf6.fw9d87d02`。
- 04 `mountinfo`:`29 23 179:6 / /opt/batdata … ext4 /dev/mmcblk0p6`;`33 29 179:6 /docker /opt/batdata/docker … shared:1`。
- 04:`authorized_keys` 不存在、shadow `root:::0:999`、`dropbear.main.PasswordAuth='on'`、`RootPasswordAuth='on'`、`lock-status`=UNPROVISIONED、無 `/etc/batman-dev-open`;harness 以 `BatchMode=yes` 登入成功(即空密碼)。
- 04:`/opt/batdata` 有 `.faketime`、`apps/`、`docker/`、`dv289-backup-*`、`lost+found`;`state/` 有 `lock-status mesh-expected mesh-joined slot-A.protected slot-B.protected`。
- 04、02:`/overlay/upper/.cache/Tailscale` 都在;04 `/overlay/.fs_state -> 2`。
- 04、02:`jffs2reset`、`mkfs.ext4`、`flock`、`vcgencmd` 都有;沒有 `timeout`;`batman-slot is-trial` rc 1(committed)。
- 04 `/etc/rc.d`:S11batdata-mount、S12batman-faketime、S12log、S13openssl、S18halow-keyguard、S19dropbear、S20network、S60dbus、S61bluetoothd;K09batman-faketime、K09batman-payload-opentakserver、K10batdata-mount。
- 原始碼:`platform-ab.sh:74-75,150`;`batman-slot:534-547,625-705,789`;`batman-config-save:103-109,287-288,350-408`;`96:71,89,93,161-176`;`99-batman-chanfix:4-9,43-55`;`halow-setkey:99,108,121-125`;`99-halow-identity:9-14`;`meshjoin.sh:14-27`;`batman-autocommit:388-396`;`scripts/build-ab-payload.sh:69`;`95-batman-storage` 產生的 batdata-mount(`restore_payload_guardians` 的 `"$dst" start`);`219-field-provisioning.md:267,623`;`219-protocol.md` §3.1、§3.3。

## 9. 判定

**REJECT(v4)**:BLOCKER ×1、MAJOR ×7、MINOR ×15。

B1 是「恢復出廠用的工具在 image 上不存在,失敗政策又把清不乾淨當成可以繼續」,結果直接違反 U4 的「全清」。修法是機械性的:換指令,或把 p6 也 mkfs,並且 p6 清不掉就停在該步。

MAJOR 集中在三處:
- `ota-armed.mesh` 的綁定和取樣(M1、M2);
- 交易與鎖定的寫者契約(M3、M5)、wireless 的多寫者(M4);
- replay 的匿名 NX 例外(M6、M7)。

架構不用動。依規則,改完後整份再審(兩位)。
