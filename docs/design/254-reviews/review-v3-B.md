# #254 階段 1 實作設計 v3 — 獨立審查 B(第 3 輪,對抗式)

審查對象:`docs/design/254-stage1-impl.md` v3(branch `design/254-stage1-impl` @ 76f6dd8),整份審,不是只看與 v2 的差。
依據:使用者 CLAUDE.md 的審查規則 + `docs/design/REVIEW.md`。全程唯讀:沒有寫節點、沒有 reboot、沒有 commit。

## 0. 結論先講

**判定:REJECT**(1 BLOCKER / 5 MAJOR / 13 MINOR)。

v3 把 v2 的三個 BLOCKER 都正面處理了:legacy 保留今天的 mesh 閘、helper 自己重算 ClientChal、恢復出廠改成 p6 → p5 → 另一槽 → 本槽 overlay。serdev 也有 04 實證。剩下的問題集中在三處**跨元件介面**,每處都是「元件單獨看是對的,合起來會壞」:

1. **`ota-armed.mesh` 的寫入點選錯了**(BLOCKER):`batman-slot apply` 在正式 OTA 是在 sysupgrade stage-2 ramfs 裡跑的。那裡沒有 `iw`、`batctl`、`ip`,也沒有 dropbear 和 `/opt/batdata`,所以 `meshjoin_reachable` 永遠是假。結果 `member` 節點永遠只檢查 `radio_up`。「radio 起來了但入不了網」的壞 image(例如 96 註解自己寫的 morse 掉回硬體預設頻道)會被 commit,節點就被丟在網外,和 1.4.12 是同一類事故。
2. **恢復出廠還有兩個漏口**:執行期間 p5 沒有凍結,joinwatch 的 `--on-join` 仍可能重新 seed p5,而且步驟失敗(不是斷電)時要停還是繼續,文件沒有定義;另外 `jffs2reset` 不會進點開頭的目錄,而 R43 拿來當 D18 證據的那段輸出,是在 `volume_find` 之前就印出來的提示,證明不了任何事。
3. **p5 上的 `prov` 實際上有兩個寫者**:helper 用明示參數寫,`--on-join`/`--save` 從 overlay 同步。再加上「overlay 比 p5 新時以 p5 為準」這條規則,一個良性的競態就會變成擁有權回退。

另外兩條 MAJOR 都是現場路徑:SD 標記檔在 slot B 上會去找錯的 FAT(`fw-part` 回的是韌體編號,而且使用者實際會寫在 p1);認領的回應在 persist 之後才送出,BLE 在 −90 dBm 下斷線、節點又重開時,買家就永遠拿不到 `owner_tag_key`。

這些修法都是局部的,但依規則,有 BLOCKER 或 MAJOR 未關就要改設計並整份重審。

## 1. 先補:矩陣缺的列、擁有權缺的資源

**缺的生命週期列**
- **L-ota-stage2**:`batman-slot apply` 在 stage-2 ramfs 寫 p6 和判定 mesh 的行為(→ B1)。
- **L-reset-stepfail**:恢復出廠某一步**失敗**(不是斷電)。例如 `--wipe-all` 拿不到 rw mount(#202 T11)、`halow-setkey --mesh-off` 卡住(#132 morse churn)、`payload-teardown` 因 dockerd 壞掉而失敗(→ M2)。
- **L-reset-during-ota**:恢復出廠與 sysupgrade 同時進行,或 tryboot 已經 arm(步驟 6 會作廢剛寫好的另一槽,步驟 9 重開時會 trial 一個已作廢的槽)(→ m9)。
- **L-p6-unmounted**:95 拒絕掛上受損的 p6。此時 `prov-state`、`ble-ok`、`factory-reset.inprogress` 都會落到 overlay 上的 `/opt/batdata` 目錄,而 `jffs2reset` 會把恢復出廠的 marker 一起清掉(→ m13)。
- **L-claim-response-lost**:persist 之後、回應送到 app 之前,BLE 斷線或節點斷電(→ M5)。
- **L-provd-dos-during-trial**:遠端 BLE 封包讓 provd 一直 crash,於是 `health_ok` 一直失敗,好 image 被 revert(→ m12)。

**缺的資源(§3 沒列)**
- `$ST/ota-armed.mesh`:**誰清除它**沒寫;綁定的 slot 或版本也沒寫(→ B1)。
- `/overlay/upper` 底下點開頭的目錄,例如 04 和 02 都有的 `.cache/Tailscale/`,以及 helper 自己的 `/etc/batman-prov/.stage/` 和 `.identity.tmp/`(→ M3)。
- `/overlay/sysupgrade.tgz`:`mount_overlay` 用 `keep_sysupgrade=true`,所以它會保留下來,preinit 會把它還原(→ M3 附帶)。
- `prov.meta` 第一欄的 `state` 是 `prov.cbor.state` 的第二份副本(→ m6)。

## 2. BLOCKER

### B1 — `ota-armed.mesh` 在 stage-2 ramfs 判不出來 → `member` 節點的 OTA 永遠只看 `radio_up`,會 commit 入不了網的 image

**情境**:現場的 `member` 節點有鄰居。擁有者用 app 做 OTA,走 sysupgrade → stage 2 → `batman-slot apply`。設計 §3 和 §6.4 說 apply 在 arm 成功時「以 `meshjoin.sh` 的 `meshjoin_reachable` 現場判定」,然後寫 `$ST/ota-armed.mesh`。
- `platform-ab.sh:37` 的 `RAMFS_COPY_BIN` 只帶了 `batman-slot batman-reboot vcmailbox hexdump tr sha256sum head tail cut cmp mktemp`,**沒有 `iw`、`batctl`、`ip`**;`RAMFS_COPY_DATA`(`:39`)也沒有 `meshjoin.sh`。
- `meshjoin.sh:15,20,25-26` 用的就是 `iw dev wlh0 station dump`、`batctl n`、`ip -4 addr`、`/etc/init.d/dropbear running`。stage 2 已經殺掉所有服務,dropbear 不在跑。
- `platform-ab.sh:212-213` 的註解寫著「The stage-2 ramfs has lost /opt/batdata」:p6 只會以盡力而為的方式重掛到 `$RUNDIR/p6t`(`:226-233`,10 秒預算,失敗就放棄)。所以連寫 `$ST/ota-armed.mesh` 這個路徑本身都不存在。
- 正式 OTA 的 apply 確實在 stage 2:`platform-ab.sh:343`。

**結果**:`joined` 永遠寫不出來(檔案不存在,或內容是 `radio`/`none`),trial 只要求 `meshjoin_radio_up`(wlh0 是 mesh point 且 mesh_id 相符)。這種 image 會被 commit:radio 起來了,但頻道錯(`96:143-146` 自己寫了 morse 會回寫硬體預設頻道)、SAE 或 wpad 壞、batman-adv 壞。commit 之後節點就被丟在網外。今天(1.5.12)任何 seeded 節點都要求入網。v3 的負對照「(4) member 有鄰居 OTA 到 `radio1.disabled=1` → revert」測不到這個洞,因為 `radio1.disabled=1` 連 `radio_up` 都不會過。

**另外**:沒有定義誰清除 `ota-armed.mesh`。若 stage 2 寫 p6t 失敗,上一次 OTA 留下的值會沿用:殘留 `radio` 會 fail-open,殘留 `joined` 會讓單台在家更新白白 revert。

**修法**
- 在 **stage 1** 判定(活系統、服務都在):`platform_check_image` 或 `batman-slot precheck-node`(`platform-ab.sh:150`,stage 1 就會跑)呼叫 `meshjoin_sample; meshjoin_reachable`,結果寫進 `$RUNDIR/ota-armed.mesh`。`/tmp/run/batman` 會跨進 ramfs(`platform-ab.sh:214-216` 的註解)。stage 2 的 apply 再把它和 `target=<T> version=<payload>` 一起抄到 `$RUNDIR/p6t/state/`。
- 或者改讀上一個 committed boot 留下的紀錄:joinwatch 每次 JOINED 時寫 `$ST/mesh-last <boot_id> <uptime>`,stage 1 再把它凍結成 `ota-armed.mesh`。
- 讀取端:`ota-armed.mesh` 缺失或不是這次 trial 的 target/版本時,**fail-closed 當作 `joined`**,逃生口是 `hold-once`。commit 或 revert 時由 autocommit 刪除。
- **負對照**:member 有鄰居,OTA 到「wlh0 起來但 channel 不對」的 trial(可用 `uci set wireless.radio1.channel=<鄰居不用的合法頻道>` 做成 image 預設)→ 必須 revert。v3 的規則在這個 case 會 commit。

## 3. MAJOR

### M1 — p5 上的 `prov` 實際有兩個寫者;「overlay 新 → 以 p5 為準」會把已提交的認領回退

**證據**:§4.3 說「只有這個明示參數會把 prov 檔寫進 p5」。可是同一格又說 `--on-join`/`--check`/`--seed`/操作員 `--save`「永遠只看已提交的 `/etc/batman-prov/prov.cbor`+`prov.meta`(納入 fp / same_identity / `--check`)」。§4.3 的「互斥」那格說「`--on-join` 任一時刻讀到的 prov 是舊或新完整檔」,L25 說「`--on-join` 只看已提交 prov → 未提交交易永不進 p5」。這些句子只有在 `--on-join` **會把 overlay 的 prov 寫進 p5** 時才說得通。今天的 `same_identity()`(`batman-config-save:327-334`)會比對 stage 裡每個 identity 檔,而寫入步驟是 `cp -a "$STAGE/identity/." "$MNT/identity/"`(`:389`)。所以 prov 一旦「納入 same_identity」,就會被寫。

**情境**:legacy 的 02 正在 JOINED,joinwatch 每 tick 呼叫 `--on-join`(`joinwatch:145`)。
1. 認領走到 §4.4 步驟 3:helper 的 `--save --prov-file` 把 p5 寫成 generation 1(`claimed`),然後放鎖。
2. 在步驟 4 `rename` 之前,`--on-join` 拿到鎖。`--on-join` 的 wait 是 0,有空就拿(`:127-131`),而 fp 在拿到鎖之後才算。它讀到 overlay 的 generation 0(`legacy`),判定 p5 不符,把 p5 **寫回 0**。
3. helper 執行 rename,overlay 變成 1。
4. 若在下一個 tick 之前斷電:§4.4 步驟 6「overlay 新(不可能,除非 p5 被外力回退)→ log + 以 p5 為準」→ 節點回到 `legacy`,但步驟 5 已經鎖定了。擁有者手上有 app,可是節點說它「未認領」。

另一種讀法是 `--on-join` 不寫 prov。那麼 fp 與 `--check` 只要 overlay 和 p5 不一致就一直判 stale,寫入放大要靠 `:395-401` 的限速才擋得住,而且「誰把 overlay 的 prov 補進 p5」又沒有人負責。兩種讀法都不能交給實作者自己選。

`ro,noload` 的 `--prov-get` 在 journal 需要 replay 時也可能讀到較舊的 generation(96 的 `:89` 同樣是 noload),同樣會觸發「以 p5 為準」的回退。

**修法**
- 明寫:`--on-join`、`--save`、`--seed` **不寫、不刪** prov 檔與 `identity/prov/`。fp 和 `same_identity` **排除** prov。`--check` 另外加一條:p5 的 `prov.meta` == overlay 的 `prov.meta`,否則 stale(rc 5)。這樣 p5 上的 prov 就只有 helper 一個寫者。
- 步驟 6 的「overlay 新」改成:以 overlay 為準並重新 persist,同時 log `p5 lost a committed write`。overlay 只可能因為 p5 漏了一次寫入才比 p5 新。實體 SD 回退本來就擋不住(§8)。
- **負對照**:helper 在步驟 3 和 4 之間插入 sleep,期間觸發 `--on-join`,然後 `reboot -f` → 重開後 `state=claimed`。用 v3 的讀法會回到 `legacy`。

### M2 — 恢復出廠期間 p5 沒有凍結;步驟「失敗」的路徑沒有定義 → 仍可能做出「前任擁有者的節點」

**證據**
- `batman-config-save --on-join` 在**未 seed** 的 p5 上照樣寫,最後寫 `.seeded`(`:403`)。它沒有任何「p5 未 seed 就不寫」的守門,只有 `--save` 被註明是 first-seed 路徑(`:287`)。
- joinwatch 只要判定 JOINED 就每 tick 呼叫一次(`joinwatch:145`)。恢復出廠的步驟 2 只是 `halow-setkey --mesh-off --no-persist`,依賴 `wifi reload` 真的把 wlh0 拿掉。`wifi reload` 卡住或失敗(#132 morse churn 的 panic 或 hang)時,節點仍在網內。
- §4.5 的表只有「斷電後續做」一欄。步驟 2、3、5、6 **回非 0** 時要停、要重試還是繼續,沒有寫。

**情境 A**:步驟 2 沒有真的讓節點離網,步驟 5 `--wipe-all` 已完成。下一個 joinwatch tick 跑 `--on-join`,用 overlay 的前任 host key、`shadow-root`(前任的隨機密碼)、`authorized_keys`(含前任的 `batman-prov:` 行)重新 seed p5;若 M1 的同步讀法成立,連前任的 `prov.cbor`(`claimed`)也寫回去。步驟 7 清掉 overlay,下次是 fresh 開機,96 會把**前任擁有者整套**還原回來。這就是 v2 A-B1 / B-B2 的結果,只是換了一個寫者。

**情境 B**:步驟 5 拿不到 rw mount(#202 T11:一個 ro 讀者,例如 autocommit 的 `expected_in_mesh` `:394` 或 99-chanfix,會讓 rw mount 變成唯讀;config-save 只重試 5 次)。若實作「每步冪等、往下走」,p5 就原封不動,下一個 fresh 開機一樣還原前任。

**修法**
- 恢復出廠一開始,先 `/etc/init.d/joinwatch stop`,再停所有會呼叫 config-save 的程式。並且 `batman-config-save` 的**所有寫入模式**在 `$ST/factory-reset.inprogress` 存在時拒絕寫(rc 1),只有 `--wipe-all` 例外。p5 的擁有者在這段期間就是 helper 一個。
- 每一步加「失敗 → 停在此步,marker 保留,`halow-status` 紅字,下次開機從此步重試」。不准跳到下一步。
- 步驟 9 之前加一個驗證步:`--prov-get` 必須回 rc 7(未 seed),否則回到步驟 5。
- **負對照**:(a) 用 fault injection 讓 `--mesh-off` 回 0 但不卸 wlh0(或直接不跑步驟 2),期間 `--on-join` 照跑 → 重開後 `device_id` 必須是新的、p5 無 `shadow-root`。用 v3 的流程,p5 會被重新 seed。(b) 步驟 5 時讓另一個程式持有 p5 ro mount → 必須停在 5,不可往下走。

### M3 — 本槽 overlay 清除不完整:fstools 不會進點開頭的目錄;R43 對 D18 的證據不成立

**證據**
- `jffs2reset.c:121` 的 `ask_user()` 在 `:134` 的 `volume_find("rootfs_data")` **之前**,所以 R43「走到提示 = 找得到 `rootfs_data` volume」沒有證明力。fstools 原始碼:`build_dir/target-aarch64_cortex-a72_musl/fstools-2024.07.14~408c2cc4/jffs2reset.c`。
- `overlay_delete()` → `foreachdir()`(`libfstools/overlay.c:84-99`)用 `glob("%s/*", GLOB_NOESCAPE|GLOB_MARK|GLOB_ONLYDIR)`,沒有 `GLOB_PERIOD`。musl 1.2.5 的 `src/regex/glob.c:146` 在沒有 `GLOB_PERIOD` 時加 `FNM_PERIOD`,所以 **`*` 不會配到點開頭的目錄**。`handle_rmdir`(`:43-69`)只刪檔案,點開頭的目錄完全不會被走到。下一次開機 `mount_overlay` 的 PENDING 清除(`overlay.c:444-455`)用的是同一個函式,一樣漏掉。
- 實況:**04 和 02 的 `/overlay/upper/.cache/Tailscale/{tailscaled.log*.txt,tailscaled.log.conf}` 都在**(本次 `find /overlay/upper -name '.*'`)。v3 自己也會產生 `/etc/batman-prov/.stage/`(含 `owner{tag_key,adv_key}` 明文)和 `.identity.tmp/`(私鑰)。crash 之後這些殘留會撐過恢復出廠。
- `keep_sysupgrade=true`(`overlay.c:453`)會保留 `/overlay/sysupgrade.tgz`,preinit 會把它還原。Batman 的 `platform_copy_config` 是 no-op(`platform-ab.sh:352`),正常不會有這個檔,但沒有斷言它不存在。

**好消息(D22 可以改 ✅)**:有掛載的那條路是 `fs_state_set(PENDING)` → `overlay_delete`(`jffs2reset.c:52-53`)。`handle_rmdir` 會把 `/overlay/.fs_state` 也刪掉,下次開機看到 UNKNOWN,設成 PENDING,再清一次(`overlay.c:444-455`)。READY 要等 `mount_root done`(S95)才會設。所以步驟 7 之後的 overlay 寫入、以及步驟 7 中途斷電,下次開機都會再清一次,「從 8 續」是對的。若 `find_mount_point` 對不上 loop,就走 `jffs2_mark`(`:57`,寫 `0xdeadc0de`),下次開機 `block_volume_format` 會 mkfs(`libfstools/common.c:123-171`),結果一樣是 fresh。

**修法**
- 步驟 7 之前由 helper 自己刪掉 `/overlay/upper` 底下所有點開頭的項目(`find /overlay/upper -mindepth 1 -name '.*' -prune -exec rm -rf {} +`),並刪 `/overlay/sysupgrade.tgz`。或者直接以 `find /overlay/upper /overlay/work -mindepth 1 -delete` 取代對 fstools 的依賴,只保留 `jffs2reset` 處理 `.fs_state`。
- D18 改成 ⚠️,證據換成能證明的東西:`/sys/block/loop0/loop/{backing_file,offset}`(04:`/mmcblk0p4`、`113442816`)與 squashfs `bytes_used` 對齊 64 KiB 的計算一致。
- L16 的結果斷言加三條:`find /overlay/upper -name '.*'` 為空、`! -e /overlay/sysupgrade.tgz`、`! -e /etc/batman-prov/.stage`。**負對照**:恢復出廠前先在 `/overlay/upper/etc/batman-prov/.stage/` 放一個假檔 → 只用 `jffs2reset -y` 時,這個檔重開後還在。

### M4 — SD 標記檔的位置契約錯了,而且和現場使用相反

**證據**
- §4.5 寫「`batman-slot fw-part $(batman-slot active)`,p1 或 p3」。可是 `fw-part` 回的是**韌體分割編號**,不是 GPT 裝置:Pi 4 上 A=1、B=2(`batman-slot:9,207-224`;04 和 02 本次 `fw-part A`=1、`fw-part B`=2)。Pi 3 回的是 MBR 項序號 2/3(`:23-24`)。照字面實作,slot B 會去掛 `/dev/mmcblk0p2`,那是 rootA 的 squashfs,mount 失敗,標記永遠讀不到。
- 現場:使用者用讀卡機在 PC 上放檔,看到的(多半也只寫的)是第一個 FAT,也就是 p1。他不知道目前是哪一槽。R41 說 `/boot` 永遠掛 p1,而 helper 讀標記和韌體讀 `distroconfig.txt` 是兩回事,沒有理由「不能用 `/boot`」。v3 這條是把 distroconfig 的事實套錯了地方。
- 影響:fleet 現在兩台都在 slot B。實體恢復出廠是「手機遺失 / M5 認領回應遺失」時**唯一**的救法。

**修法**:標記檔兩個 boot FAT 都接受(p1 = `/boot`,以及另一個 FAT,ro 掛到 `batman_tmp -d`),兩份都刪。找 FAT 用 `slot_bootdev`(新增 `batman-slot boot-dev A|B` 動詞),不要用 `fw-part`。**負對照**:slot B 時把標記放在 p1 → 必須執行。v3 的契約下會被忽略。

### M5 — 認領在 persist 之後才回應:回應遺失(BLE 弱訊號 + 重開 / provd crash)= 擁有者永遠拿不到 `owner_tag_key`

**證據**:§4.4 和 §6.1 的順序是「persist → rename → 鎖定 → 回應」。協定 `219-protocol.md:148` 要求節點把冪等鍵的結果保留 10 分鐘、跨 session 有效,`claim/finish` 的回應裡有 `owner_tag_key`、`adv_owner_key`、`root_password`(`:185`)。v3 §3 卻把「冪等鍵」放在 **provd 記憶體,respawn 後消失**,重開當然也消失。R42 的實測是 5–10 m 就已經 −82 ~ −95 dBm,回應斷線是常態,不是意外。

**情境**:買家認領,helper 完成 persist,BLE 斷線,節點斷電或 provd crash。app 重送 `claim/finish` → 節點是 `claimed` → `E_STATE`。app 沒有 `owner_tag_key` 就導不出 `psk_owner`(`219-protocol.md:252`),永遠連不上。唯一的出口是實體恢復出廠,而在 slot B 上它又是壞的(M4)。

**修法**:由 helper 做可重放的認領。`state=claimed`、只有一位擁有者、且 `owner_pub` 相同時,`claim.verify` 若 CheckMac 驗過(`claim.secret` 在恢復出廠前不變),加上一個以 `owner_pub` 簽 `nonce_helper` 的 owner-op(防止只持有 QR 的人重放),就回傳 `prov.cbor` 裡存的 `owner_tag_key`/`adv_owner_key`,並產生新的 root 密碼。冪等結果不再依賴 provd 記憶體。**負對照**:persist 之後 `reboot -f`,app 重送 → 拿到相同的 `owner_tag_key`。v3 下會是 `E_STATE`。

## 4. MINOR

- **m1 — `--prov-get` rc 10(`prov-corrupt`)沒有對應的狀態**。§4.2 和 §4.4 只處理 rc 0/7/9/1/8/3。config-save 的寫入順序是 identity → overrides → schema → `.seeded`(`:389-403`),prov 的 mv 插在哪裡沒寫。中途斷電就是 rc 10。fresh 開機時 96 不抄,helper 會怎麼判?若當成 rc 9,`claimed` 節點就會被改成 `legacy`。修法:`prov.meta` **最後**寫,當作 commit 紀錄;rc 10 的處理是「非 fresh 開機用 overlay 的並重新 persist;fresh 開機判 `unknown`」。
- **m2 — 身分產生條件自相矛盾**。§4.2 寫「rc 0 或 rc 7」,可是 legacy 升級是 rc 9(L17、Q1),照 §4.2 實作,02 和 04 永遠不會有身分。另外「overlay 已有 identity、p5 沒有」的情況(persist 失敗之後)會每次開機重產,`device_id` 和 QR 跟著一直變。修法:條件寫成 rc ∈ {7, 9} 且 p5 沒有 `identity/prov/`。overlay 已有 identity 時**只重新 persist**,不重產。
- **m3 — trial 上 legacy 身分的 persist 會用 trial 的 live uci 重寫 `overrides.uci`**(`--save` 會走 `stage_overrides`,`:389`)。若 trial 的 96 套用失敗(`errors-reverted` → image 預設、placeholder),p5 就被寫成預設值。joinwatch 的 `--on-join` 在 revert 之後大多會自癒,但 L17「不碰 overrides 語意」是錯的。修法:新增 `--save --prov-only`,只寫 prov 和 `identity/prov/`;或者等 committed 之後才 persist。
- **m4 — legacy 的 `qr` 門擋不住 SSH**。「stdin 是 tty」:`ssh root@04` 就有 pty。而且已經是 root 的攻擊者可以自己往 `authorized_keys` 加一行,§6.1 的門也就過了。§8 那一列「連上 legacy 節點 AP 的人」的擋法並不成立。修法:誠實寫明「legacy 上 root = 可認領」,這道門只是防止誠實的操作員把自己鎖在外面。`qr` 的 tty 判斷改成 `/dev/console` 或 `ttyAMA*`,不接受 `pts`。
- **m5 — `psks.get` 的誠實界線寫小了**。`psk_member`、`adv_member` 是**全網共用**的(`219-protocol.md:253,255,261`),所以 provd 被攻陷 = 能以成員身分連**全網每一台**節點、追蹤全網的廣播,不只是「這台」。`claim/finish` 的回應(`owner_tag_key`、`root_password`)也會經過 provd。換密碼(`net_version`+1)之後,provd 會立刻重新拉到新值,所以換密碼趕不走一個持續存在的入侵。這兩點都要寫進 §4.1 和 §8。
- **m6 — `prov.meta` 的 `state` 是第二份副本,而且 claimed/member 節點的鎖定是 fail-open**。96 4b 只看 meta 的 state 就跳過,即使 `prov.cbor` 的 sha 對不上、沒有抄過去。helper 沒跑(新 image 的二進位壞掉)時,今天的 4b 規則在「無 key 的 claimed 節點」上會判成 UNPROVISIONED,也就是開著。`ttylogin` 預設 0 = serial 直接給 root shell(02 本次 `ttylogin=0`)。修法:96 只在**成功抄完** prov 時才跳過 4b。p5 說 claimed/member 而 helper 不可用時,至少要 `ttylogin=1`、`PasswordAuth=off`(fail-secure)。helper 也要驗 meta 的 state == cbor 的 state。
- **m7 — 只改一份 FAT 的機台會被 `ble-ok` 永久擋 OTA**。`batman-slot apply` 不會抄 `config.txt`/`distroconfig.txt`(`:645-647` 的複製清單、`:660` 的排除清單)。操作員照 release note 只改了 `/boot`(p1)的話,slot A 上 BT 正常,寫出 `ble-ok`,之後 OTA 到 B(p3 沒有 `miniuart-bt`)就一律 revert。修法:helper 只在兩份 FAT 都有 `dtoverlay=miniuart-bt` 時才寫 `ble-ok`(唯讀檢查);或讓 apply 同步 `distroconfig.txt`。
- **m8 — `invalidate-other` 不能直接重用 `clear_root`**。`clear_root`(`:614`)用的 `ZERO_MB` 來自 `precheck` 的 payload 大小(`:607`),沒有 payload 時 `count=` 是空的,dd 直接 die。修法:定義成清整個目標 root 分割,或讀它的 squashfs `bytes_used`(讀不到就清全部)。並且要 `slot_lock` + `disarm_tryboot`(見 m9)。
- **m9 — 恢復出廠撞上已 arm 的 tryboot 或正在進行的 sysupgrade**。步驟 6 作廢另一槽,步驟 9 重開時 trial 那個已作廢的槽,`panic=10` 才會回來。修法:前置條件加「`slot_lock` 可取得且 tryboot 未 arm」,`invalidate-other` 裡面先 `disarm_tryboot`。
- **m10 — `prov-state` 在非 fresh 的 trial 上可能晚於 autocommit**。autocommit 的 `expected_in_mesh` 只在啟動時算一次(`batman-autocommit:388-399`),它的 init 註明「ordering is NOT relied on」(`init.d/batman-autocommit:3`)。helper 是 procd S89,非同步執行。OTA trial 的 overlay 一定是 fresh,99zz 會在 S10 寫好,所以實務上大多有蓋到。但要明寫「99zz 是 trial 上 `prov-state` 的寫者」,並讓 autocommit 在沒有本次 `boot_id` 的 `prov-state` 時重算 NEED_MESH(最多等到 helper 寫好)。另外,設計用的變數 `$RUN/batman-prov.health` 和 autocommit 既有的 `RUN=$RUNDIR/autocommit.run`(`:79`)同名。
- **m11 — L20/L32「下次開機恢復」寫過頭了**。helper 只補 prov 和 identity,overrides(mesh key、hostname、IP)要靠已經被刪掉的 96 Lane B,節點仍然停在 image 預設。這和今天的行為一樣,但不是「恢復」。`/etc/.batman-prov-restore` 沒有 `boot_id`,helper 因此無法判斷「96 這次有沒有跑」(§3 說它的用途就是這個)。
- **m12 — 遠端 BLE 能讓好 image 被 revert**。`health_ok` 要求 `provd=1`,而 provd 被設計成可被 crash 後 respawn + 退避。路人在 trial 期間反覆送讓 provd crash 的封包,就能讓 dwell 一直歸零,直到 deadline revert。修法:在 trial 上,provd 只要「本次開機曾經成功註冊廣播」就算健康;或者 `ble-ok` 的檢查只看 bluetoothd 和 `hci0`。
- **m13 — p6 沒掛上時的恢復出廠沒有定義**,以及兩處編輯錯誤。marker 會寫到 overlay,被 `jffs2reset` 清掉;步驟 4 會刪到 overlay 上的 `/opt/batdata`。修法:前置條件加「p6 已掛」(`batman-storage.crit` 不存在),否則拒絕。編輯:§6.4 說「負對照四件」實際列了五件;§4.5 的 B2-m5「p5 未 seed 且 unclaimed → 忽略」這條守門在 step 10 seed 之後永遠不成立,實際防止重置迴圈的是 `device_id` 已經改變,要寫成這個。

## 5. v2 發現 → v3 收法核對

| v2 | 狀態 | 一行說明 |
|---|---|---|
| A-B1 恢復出廠 | partial | 順序和範圍已修;p5 未凍結、步驟失敗路徑、點開頭目錄殘留未修(M2/M3) |
| A-B2 legacy mesh 閘 | addressed | legacy 照今天的規則;但 member 的新規則有 B1 |
| A-B3 claim 換 owner | addressed | helper 自己重算 ClientChal,有負測試 |
| A-M1 `.stage` 兩讀者 | partial | 不再讀 `.stage`,但 `--on-join` 同步 overlay prov,變成兩個寫者(M1) |
| A-M2 shadow 回滾 | addressed | 鎖定移到 persist 之後;但回應遺失的路徑是新洞(M5) |
| A-M3 96/helper 兩寫者 | partial | 4b 依 meta 跳過;meta/cbor 重複、helper 不在時 fail-open(m6) |
| A-M4 標籤 | addressed | `batman-owner-op-v1`(待 docs PR) |
| A-M5 首次 join 授權 | addressed | 第 1 版需要 owner-op |
| A-M6 `keystore.ecdh` | addressed | 已刪;誠實界線寫小了(m5) |
| A-M7 health BLE | partial | `ble-ok` gating;只改一份 FAT 的陷阱(m7) |
| A-M8 身分原子性 | partial | tmp + rename 已做;persist 失敗會重產(m2) |
| A-M9 hook 走 setkey | addressed | `--firstboot` 只做 uci set |
| A-m1 dbus send_interface | addressed | R39 |
| A-m2 96 marker 出口 | partial | 每個出口都寫了;沒有 `boot_id`(m11) |
| A-m3 還原契約 | addressed | §4.3 |
| A-m4 overlay 壞 p5 好 | addressed | 步驟 6 |
| A-m5 非 ext4 判定 | addressed | 分成 `raw` 與 `p5-unavailable` |
| A-m6 counter 位置 | addressed | 進 `prov.cbor` |
| A-m7 persist 授權 | addressed | 動詞刪除 |
| A-m8 seed_key_ok | addressed | helper 只用 `--save` |
| A-m9 dev-open 進 image | addressed | 不進任何 image |
| A-m10 降級 | addressed | L12;unclaimed 降級也會被 revert,建議補一句 |
| A-m11 root 密碼遺失 | addressed | `root_password.reset` |
| A-m12 mesh-joined | addressed | leave/reset 時刪 |
| A-m13 SD 標記 | partial | 位置錯(M4) |
| A-m14 legacy 定義 | addressed | §1.4 |
| A-m15 typo | 使用者決定 | 不動 |
| A-m16 perms | addressed | 0600 + boot_id |
| B-B1 serdev | addressed | R38,04 實證 |
| B-B2 恢復出廠 | partial | 同 A-B1(M2/M3) |
| B-B3 legacy mesh 閘 | addressed | 同 A-B2 |
| B-M1 `.stage` 被 on-join 發布 | partial | 同 A-M1(M1) |
| B-M2 marker 四態/五態 | addressed | 狀態只由 `prov.cbor` 決定 |
| B-M3 marker 永久凍結 | addressed | helper 每次開機重看 p5;config 本身不會恢復(m11) |
| B-M4 health 擋 OTA | partial | `ble-ok`;m7 陷阱、m12 DoS |
| B-M5 單台在家更新 | **open** | 規則寫了,但 stage 2 判不出來(B1) |
| B-M6 ecdh oracle | addressed | 已刪 |
| B-M7 套件依賴 | addressed | 0012 patch + diffconfig,04 實證 |
| B-M8 S10 setkey | addressed | `--firstboot` |
| B-M9 legacy 認領鎖死 | partial | 誠實操作員有保護;防攻擊者的說法不成立(m4) |
| B-M10 不存在的動詞 | partial | 已列入 PR-P1;`clear_root` 的 ZERO_MB 缺口(m8) |
| B-m1 sign 訊息 | addressed | helper 自己組訊息,2/s |
| B-m2 ClientChal | addressed | |
| B-m3 persist 授權 / ssh_keys 正規式 | addressed | |
| B-m4 prov-state 綁 boot | addressed | boot_id |
| B-m5 SD 標記 | partial | M4;重置迴圈的守門寫錯(m13) |
| B-m6 respawn | addressed | `3600 5 0` |
| B-m7 無 hci0 | addressed | 照跑 |
| B-m8 hostname 洩漏 | addressed | `Name=Batman`、adv 不帶 Local Name |
| B-m9 device_id | addressed | `hex(sn)` |
| B-m10 96 信任 identity | addressed | |
| B-m11 trial 認領 | addressed | `E_BUSY` |
| B-m12 qr 進 log | addressed | 但 tty 判斷擋不住 pty(m4) |
| B-m13 p1 版本 | addressed | R41 |
| B-m14 非 fresh p5 掛不起 | addressed | 步驟 8 |
| B-m15 讀 Powered | addressed | health 檔 |
| B-m16 lock-status 順序 | addressed | 4b 跳過 |

**使用者決策不重開,只列後果**:
- U3 擁有權與 SSH 脫鉤 → 加上 m4,legacy 上任何 root 都等於可以認領。
- U4 全清 → M5 的回應遺失只能靠實體恢復出廠救。
- U6 3A+ 延後 → B1 的修法(stage 1 判定)也碰兩板共用檔,bcm2710 ❌。
- U5 改名探針 → 仍是 ⚠️。

## 6. 逐 actor 小結

- **路人(BLE)**:讀身分 / 配對 ✅(04 已驗)。新增 m12:能讓好 image 被 revert。
- **攻陷的 provd**:改狀態、換擁有者都已擋住 ✅。實際能拿到的範圍比 v3 寫的大:全網成員權限、看到認領回應裡的秘密(m5)。
- **前任擁有者**:M2、M3 是殘留路徑。
- **買家**:M5(認領回應遺失)、M4(實體恢復出廠在 slot B 失效)。
- **legacy fleet(02/04)第一次 OTA**:mesh 閘維持今天的規則 ✅;身分 persist 會改寫 overrides(m3);§4.2 的條件會讓身分永遠產不出來(m2)。
- **單台在家更新的擁有者**:B1 修好之前,所有 member 節點的有鄰居 case 都是 fail-open。
- **實體持有 SD 卡的人**:本來就擋不住(§8 有寫);m6 讓 serial 在 helper 不在時也打開。
- **我們自己的錯**:M1(兩個寫者)、M3(工具的盲點)、R43 證據無效。

## 7. 本輪唯讀探針(原始輸出摘要)

- 04 與 02:`find /overlay/upper -name '.*'` → `/overlay/upper/.cache`(內容 `Tailscale/tailscaled.log1.txt`、`log2.txt`、`log.conf`),兩台都有。
- 04:`/sys/block/loop0/loop/backing_file` = `/mmcblk0p4`,`offset` = `113442816`;`/proc/mounts`:`/dev/loop0 /overlay f2fs`、`/dev/mmcblk0p6 /opt/batdata/docker ext4`(bind)。
- 兩台:`batman-slot active` = B;`fw-part A` = 1;`fw-part B` = 2(不是 p3)。
- 04:`is-trial` rc = 1。02:`ttylogin` = 0,`authorized_keys` 1 行。04:`authorized_keys` 0 行。
- 04 的 `/boot/distroconfig.txt`:`:15 core_freq_min=500`、`:16 dtoverlay=miniuart-bt`。02:`:15 dtoverlay=miniuart-bt`,沒有 `core_freq_min`。
- fstools 原始碼(WSL `firmware-2710/build_dir/.../fstools-2024.07.14~408c2cc4`):`jffs2reset.c:52-53,121,134`;`libfstools/overlay.c:43-69,84-99,444-455`;`libfstools/rootdisk.c:212-224`;`libfstools/common.c:123-171`。musl 1.2.5 的 `src/regex/glob.c:146`(只讀 `dl/` tarball 到 stdout,沒有解壓到磁碟)。
