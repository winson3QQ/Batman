# Review A(第 3 輪)— `254-stage1-impl.md` v3(#254 階段 1 實作設計)

審查者 A,獨立、對抗式。審整份(§0–§13),不是只看 v2→v3 差異。依使用者 CLAUDE.md 設計審查規則 + `docs/design/REVIEW.md`。使用者已定案事項(擁有權與 SSH 脫鉤、階段 1 恢復出廠全清含身分、Go/Flutter+Rust、3A+ 延後、`uart_enable` typo 不動、改名探針待使用者)不重開,只在 §6 列後果。

**證據來源(全部唯讀,2026-10-19)**
- Batman `design/254-stage1-impl` @ 76f6dd8(= main f2f2bf6 的程式):`batman-config-save`、`96-batman-config-migrate`、`99-halow-identity`、`batman-autocommit`、`batman-slot`、`halow-setkey`、`halow-keyguard`、`joinwatch`、`meshjoin.sh`、`payload-teardown`、`platform-ab.sh`、`init.d/batman-autocommit`。
- firmware-2710 `build_dir/target-aarch64_cortex-a72_musl/fstools-2024.07.14~408c2cc4/`:`jffs2reset.c`、`libfstools/overlay.c`、`libfstools/rootdisk.c`、`libfstools/common.c`、`mount_root.c`。
- 04(10.41.1.3,slot B,committed,1.5.12-wsl.3):`mount`、`/proc/self/mountinfo`、`/sys/block/loop0/loop/{backing_file,offset}`、`find /overlay/upper -name '.*'`、`ls -la /overlay /opt/batdata`、`ls /etc/rc.d`、`grep START /etc/init.d/{dockerd,batman-payload-opentakserver}`、`batman-slot active / is-trial / fw-part B`、`/sys/class/net/eth0/carrier`、`/sys/class/bluetooth`。
- 02(10.41.1.1,slot B):`lock-status`、`uci show dropbear`、`authorized_keys` 行數、root shadow 欄、`ls -la /opt/batdata/state`、eth0 carrier、`/sys/class/bluetooth`。
- **沒有任何寫入**(刻意沒跑 `bluetoothctl`:它會註冊 agent,R40)。

---

## 0. 總評

v3 把 v2 的三條 BLOCKER 方向都收對了:恢復出廠改成 p6→p5→另一槽→本槽 overlay、`legacy` 一律今天的 mesh 閘、helper 自己重算 `ClientChal`;`.stage` 只剩 helper 一個讀者、身分 `.identity.tmp`+rename、`ble-ok` gating、96 verdict 全出口、helper 每次開機自己看 p5 —— 我逐條對過原始碼,可以保留。

但本輪從「現場」重走(轉賣前恢復出廠、02/04 第一次 OTA、買家認領、單台在家更新、BLE 路人、p5 壞掉的機台),找到:

- **1 條 BLOCKER**:恢復出廠是 `unknown`(p5 讀不到)時設計給的唯一補救,但它的第 5 步在「p5 不是 ext4 / 掛不起」時必失敗;設計沒有步驟失敗政策 → 每次開機續做、續做期間 provd 不開 → 節點永久失聯(AP 關、mesh 關、BLE 關)。補救在自己的觸發條件上死鎖。
- **10 條 MAJOR**:`ota-armed.mesh` 在 sysupgrade stage 2 根本算不出來(B-M5 實質沒收);`--no-persist` 仍 `uci commit`,L7「步驟 3 前什麼都沒變」不成立、開機不對帳 wireless;config-save rc≠0 不代表沒寫(rc 6)→ 回滾的交易下次開機復活;§4.4 步驟 7 對 `legacy` 的寫法與 §1.4/§3 矛盾(LOCKED 的 legacy 節點每次開機被解鎖);96 4b 改成「看 prov.meta 跳過」後 helper 沒跑到就 fail-open;身分產生條件漏「overlay 有、p5 沒有」→ 重產身分;斷電續做與 S99 dockerd/guardian 並行;認領回應遺失 → 擁有者永久鎖在外面;L16 在 02 做會把 02 弄到無路可回;`--prov-get` rc 表不全。
- **14 條 MINOR**(其中一條是 R43/D18 的證據寫錯:`jffs2reset` 的提示出現在 `volume_find` **之前**,「走到提示」證明不了找到 volume)。

**判定:REJECT(v3)**。架構不用動,修法都在 §4.2/§4.4/§4.5/§6.1/§6.4/§3/§9 局部;但 BLOCKER + MAJOR 都改到交易與生命週期契約,v4 要整份再審。

---

## 1. 先補:矩陣缺的列、擁有權缺的資源

| 缺的路徑 / 資源 | 為什麼要有 | 對應 |
|---|---|---|
| **恢復出廠某一步失敗**(p5 非 ext4/掛不起、另一槽 FAT 掛不起、`clear_root` 參數不存在) | 「每步冪等、開機續做」只處理斷電,沒處理「每次都失敗」 | B1 |
| **恢復出廠續做期間其他開機服務**(S98 joinwatch、S99 dockerd/guardian/autocommit) | helper 是 S89 的 procd 常駐,`--boot` 與後面的 init 並行 | M7 |
| **sysupgrade stage 2 ramfs 中的 `batman-slot apply`**(寫 `ota-armed.mesh` 的那一刻) | ramfs 沒有 iw/batctl/ip/dropbear、`/opt/batdata` 已卸載 | M1 |
| **`state.apply` 步驟 2 之後、步驟 3 之前斷電 / helper 崩潰**(uci 已 commit) | L7 說「什麼都沒變」,實際上 wireless 已提交 | M2 |
| **config-save 寫了但回 rc≠0**(rc 6、逾時被殺) | helper 會回滾 overlay,p5 卻已 n+1 | M3 |
| **overlay 有 `identity/`、p5 沒有 `identity/prov/`**(第一次 `--save` 失敗或被重開打斷) | §4.2 只寫了反方向 | M6 |
| **`claim/finish` 回應遺失**(RSSI −82~−95 dBm,R42) | 認領後只接受 NXpsk0,app 沒有 `owner_tag_key` 連不回來 | M8 |
| **L16 之後 02 如何回到 harness**(02 無乙太網、無 BLE) | 破壞性測試先列副作用與還原(記憶 2026-10-18) | M9 |
| 資源:`/opt/batdata/.faketime`、`/overlay/upper/.cache/`、`/etc/batman-prov/.stage`、`.identity.tmp`(dot 開頭) | `jffs2reset`/`mount_overlay` 與 shell glob 都跳過 dot 項目 | m2 |
| 資源:`/etc/dropbear/authorized_keys` 的寫者還有 **96 Lane A**(`96:96-101`);`$ST/prov-state` 在 fresh 開機的寫者是 **99zz(S10)** | §3 只列 helper / 操作員 | m10 |
| 資源:`$ST/ble-ok`、`$ST/ota-armed.mesh`、`factory-reset.inprogress` 的權限、誰刪、何時失效 | §3 沒寫 | m12、M1 |

---

## 2. Findings

### BLOCKER

**B1. 恢復出廠沒有步驟失敗政策;在它自己的觸發條件(p5 壞)上死鎖,節點永久失聯**

- 情境:民用機 p5 的 ext4 壞了(或被讀卡機格式化成別的)→ §1.4 `unknown`:「只開 `status/public` + factory reset(SD 標記)」。使用者照做,放 SD 標記檔 → helper `--boot` 開始 §4.5:步驟 1–4 OK → 步驟 5 `batman-config-save --wipe-all` 失敗 → 下次開機「從該步續做」→ 再失敗 → 無限迴圈。§4.5「續做時 provd 不開 socket、不廣播,直到完成」+ 步驟 2 已 `--mesh-off --ap-off` → **AP 關、mesh 關、BLE 關**。民用機沒有 SSH key(U3「沒有行 = SSH 關」),只能重燒卡。
- 證據:
  - `batman-config-save:159-164`:寫入模式遇到非 ext4 magic → `exit 1`(「run --seed first」),而 §4.3 明寫 `--wipe-all`「不 mkfs」;`:247-249` rw 掛載 5 次失敗 → `exit 1`。
  - 步驟 6 的 `clear_root`(`batman-slot:614`)用的 `ZERO_MB` 只在 `precheck()` 依 payload 的 squashfs 大小算(`:608`);`invalidate-other` 沒有 payload → `dd count=` 空值 → `die "overlay clear failed"` → **照字面「重用 `clear_root`」實作時,每一次恢復出廠都卡在步驟 6**。`tboot_open`(`:413`)另一槽 FAT 掛不起也 `die`。
  - §4.5 表只有「斷電後續做」欄,沒有「失敗」欄;§4.1 也沒說 `factory_reset` 執行中 `info.state`/`status/public` 回什麼。
- 修法:
  1. 每一步定義「失敗 → 動作」:清除類步驟在媒體不可用時降級為「破壞性清零」(p5:非 LUKS 時 `dd` 清掉 superblock 區並記錄;另一槽:不論 FAT 能否掛載都清 rootfs 頭,FAT 可掛才寫 `BATMAN-BAD`),否則記錄並**跳過**,不阻塞後面的步驟;
  2. 每步重試上限(例如 3 次開機),到上限就完成並把 `partial:<step>` 寫進 `status/public`;
  3. 續做期間 provd **要開** `status/public`(回 `resetting step=N` / `reset-partial`),不准讓節點全暗;
  4. `invalidate-other` 自己定義清零範圍(例如讀另一槽 squashfs `bytes_used` 對齊 64 KiB + 64 MiB;讀不到就清整個 rootfs 分割頭部固定大小);
  5. 負對照:白箱讓 p5 掛不起(或寫壞 magic)→ SD 標記重置 → N 次開機內完成、BLE 可答;v3 規則下永遠卡住。

### MAJOR

**M1. `ota-armed.mesh` 由 `batman-slot apply` 以 `meshjoin_reachable` 判定 —— apply 跑在 sysupgrade stage 2 ramfs,那裡算不出來;也沒有人清它(B-M5 實質沒收)**

- 證據:`platform-ab.sh:25-37`:stage 2 已 pivot 到 ramfs,`RAMFS_COPY_BIN` 只有 `batman-slot batman-reboot vcmailbox hexdump tr sha256sum head tail cut cmp mktemp`(**沒有 `iw`、`batctl`、`ip`**),`RAMFS_COPY_DATA` 沒有 `meshjoin.sh`;`:212-227`「stage-2 ramfs has lost /opt/batdata」,p6 只在 `$RUNDIR/p6t` **背景**(`&`)重掛;`:330,343` stage-root/apply 在這裡跑。`meshjoin.sh:23-27` `meshjoin_reachable` 需要 `iw dev wlh0 station dump`、`batctl n`、`ip -4 addr`、`/etc/init.d/dropbear running`(stage 2 全被殺)。
- 後果:`ota-armed.mesh` 永遠是 `radio`/`none`(或 p6t 沒掛上時根本寫不進去 → 留著**上一次** OTA 的值)。於是有鄰居的 `member` 也只檢查 `meshjoin_radio_up` → 一個能建 mesh point、但 SAE/plink 壞掉的 image 在整隊 member 上 commit。§6.4 負對照 (4)「member 有鄰居 OTA 到 `radio1.disabled=1` → revert」碰巧會過(radio_up 抓得到),**抓不到 plink 壞的 image**,所以它不是 ota-armed 的負對照。L31「單台在家」會 commit 是碰巧對。
- 另:`meshjoin_reachable` 要求 dropbear 在跑;§6.2「沒有行 = SSH 關」若實作成停 dropbear,member 永遠不 reachable → 每次 OTA revert。要寫明 dropbear 照跑(只關密碼)或 prov 狀態下改用不含 dropbear 的判定。
- 修法:在 **stage 1**(`platform_check_image` → `batman-slot precheck-node`,live 系統)判定並寫 p6:`<target_slot> <target_version> <boot_id> joined|radio`(0600);autocommit 只在 slot+version 與本 trial 相符時採用,決策後刪除;負對照:member 有鄰居、OTA 到「mesh point 起得來但 SAE 失敗」的 trial(例如 trial 的 uci-defaults 改壞 key)→ 必須 revert(v3 會 commit)。

**M2. `halow-setkey --no-persist` 仍 `uci commit wireless` → 副作用已提交在 overlay、joinwatch 會把它帶進 p5;L7「步驟 3 前:什麼都沒變」不成立,`--apply-state` 也不對帳 wireless**

- 證據:`halow-setkey:99` `uci commit wireless` 在 `:101` reload 之前、與 persist(`:147`)無關;`batman-config-save:86-89` 只隱藏「未提交」的 uci,已提交的照存;`joinwatch:145` JOINED 每 tick `--on-join`。§4.4 步驟 7 `--apply-state` 只列 AP/dropbear/ttylogin/lock-status/shadow,沒有 mesh key/mesh_id/channel。
- 情境:`network/update`(換 mesh key)步驟 2 之後 helper 崩潰或斷電 → 重開(非 fresh):wifi 用**新 key** 起來,`prov.cbor.net` 仍是舊版、generation 相等 → `--apply-state` 不動 wireless → 節點跑在 prov 不認得的 key 上,且 `--on-join` 把新 key 寫進 p5 overrides。app 收到的是失敗(或沒收到),節點卻已換 key。L25 的測試只斷言「p5 generation 不前進」,抓不到 overrides 已前進。
- 修法:`--apply-state`(開機 + helper 重啟)把 wireless(mesh key/id/channel、AP key/disabled)對帳到 `prov.cbor`(只在不一致時經 `halow-setkey --no-persist`);L7 斷電點斷言 `uci get wireless.*.key` 與 prov 一致;L25 加斷言 p5 `overrides.uci` 的 mesh key 未變。

**M3. config-save「回 rc≠0」不等於「沒寫」→ helper 回滾 overlay,p5 已是 n+1,下次開機以 p5 重建 = 失敗的交易復活(A-M1 同一類,換一條路)**

- 證據:`batman-config-save:21`「6 write modes: a live value could not be persisted … — the rest was written」;`:389-408` 寫完才 `final_rc` 回 6。§4.4 步驟 3「rc ≠ 0 → 回滾步驟 2、刪 stage、`E_PERSIST(rc)`」;步驟 6「p5 新 → 以 p5 重建 overlay」。rc 6 的來源是任何一個 PRESERVE 值含禁用字元(例如 legacy 節點操作員手設的 hostname),不是本交易本身。helper 若對 config-save 加逾時(§4.1 30 s)而殺掉它,也可能寫了一半。
- 修法:helper 在任何 rc≠0 後**讀回** `--prov-get` 的 `prov.meta.generation` 決定結果(== n+1 → 視為已提交,走步驟 4–5,回 `E_PARTIAL`;== n → 回滾);或 `--prov-file` 模式在寫任何東西前先做 PRESERVE 驗證、有 REJECTED 就整筆不寫。負對照:白箱讓 hostname 含 `'` 再做 `net.apply` → 重開後 state 與 app 收到的結果一致(v3 會復活)。

**M4. §4.4 步驟 7 對 `legacy/unclaimed` 寫「PasswordAuth 回 image 預設」+ 依狀態經 `halow-setkey` 重設 AP —— 與 §1.4/§3「legacy 全部不動、helper 不碰」矛盾;照步驟 7 實作,LOCKED 的 legacy 節點每次開機被解鎖**

- 證據:§4.4 步驟 7 原文「legacy/unclaimed **不碰 shadow**,PasswordAuth 回 image 預設」;L2「每次開機 `--apply-state`(冪等)」;`96:167-172` 有 key + 有密碼的 legacy 節點是 `PasswordAuth=off`/`RootPasswordAuth=off`(#137 現場佈署就是這樣)。02 今天恰好是 UNPROVISIONED(實測 `PasswordAuth='on'`、root 欄空、1 行 lab key),04 也無 key → **02/04 測不出這條回歸**。
- 另一面:member 每次開機「AP 由網路設定決定」若經 `halow-setkey --ap …`(`:101` 一定 `wifi reload`、`:134` 等最多 20 s)→ 每次開機多一次 wifi reload,mesh 在開機時抖一次。
- 修法:步驟 7 改成「state ∈ {legacy, unclaimed}:helper 對 dropbear/ttylogin/lock-status/shadow/AP **一律不寫**(96 4b 是唯一寫者)」;`claimed/member` 只在與目標值不同時才寫,AP 只在不同時才經 setkey。負對照:bench 上做一台 LOCKED 的 legacy 節點(key + 密碼)→ OTA → 重開 3 次 → 仍 `PasswordAuth=off`(照 v3 步驟 7 會變 on)。

**M5. 96 4b 改成「p5 `prov.meta` state ∈ {claimed, member} 就跳過」→ 鎖定只剩 99zz/helper 一個寫者,它沒跑到就 fail-open**

- 證據:§4.3 96 bullet;`96:155-160` 的原設計理由「LOCAL uci only, never p5-sourced」;fresh overlay 上 dropbear 是 image 預設(`PasswordAuth on`,02 實測值即預設);shadow 由 Lane A 還原(`96:107-117`)—— 若 p5 沒有 `shadow-root`(§4.4 步驟 5 的第二次 `--save` 沒成功,或認領前本來就空密碼,04 即是)→ root 空密碼。
- 情境:claimed 節點 OTA 到一個 helper 有 bug 的 image(或 `prov.cbor` sha 不符被 96 拒抄、但 meta 第一欄仍是 `claimed`)→ 96 跳過 4b、99zz `--apply-state --boot` 失敗 / 判 `unknown` → **沒有人鎖** → mesh 上任何成員、乙太網上任何人以 root 空密碼登入;trial 在 revert 前也一樣開著。
- 關於「hostile p5 能否濫用這個跳過」:實體 SD 攻擊者本來就能經 Lane A 放 `authorized_keys`(`96:96-101`)拿 root,跳過 4b 不增加其權限 —— 不是新提權;問題是**非惡意**的失敗(helper bug、sha 不符)變成 fail-open,違反 fail-secure 預設。
- 修法:96 在 state ∈ {claimed, member} 時**照樣寫**鎖定(`PasswordAuth=off`、`RootPasswordAuth=off`、`ttylogin=1`、`lock-status=LOCKED`,不需要 key —— U3 下 LOCKED 本來就可以是「無 SSH」),helper 只做同值確認;meta 有而 prov 抄失敗 → 照鎖。負對照:白箱把新 image 的 helper 換成 `exit 1` → claimed 節點 OTA 後 `ssh -o PreferredAuthentications=password root@…` 失敗(v3 會成功)。

**M6. 身分產生條件漏了「overlay 有、p5 沒有」→ 第二次開機重產身分(新卡 QR 作廢;已認領機台 DAC 被換、擁有者 TOFU pin 失效)**

- 證據:§4.2「產生條件(唯一):`--prov-get` rc 0 或 7 **且 p5 無 `identity/prov/`** 且非 bypass」—— 不看 overlay;「p5 有而 overlay 沒有 → 還原」只寫了反方向。觸發:第一次 `--save` 失敗(`config-save:125,140` 鎖忙 10 s、`:247-249` rw 掛載失敗)、或在 rename 與 `--save` 之間被重開(`99-halow-identity:22`:新卡第一次開機 openmanetd 保留 IP 後**會重開一次**;joinwatch AUTOREBOOT;使用者拔電)。rc 0(p5 有 prov、但 `identity/prov/` 抄失敗)同樣會走產生分支 —— 這時 `prov.cbor` 的擁有者綁的是舊 DAC。實作上 `rename(.identity.tmp, identity)` 遇到已存在的非空 `identity/` 會 ENOTEMPTY → 要嘛刪舊重產、要嘛永遠產不出來,兩種都錯。
- 修法:overlay 有完整 `identity/`(7 檔 + sha 對)而 p5 沒有 → **補 persist overlay 那份**,絕不重產;p5 有 prov 但無 identity → `unknown`(紅字),不重產。負對照:白箱讓第一次 `--save` 回 1 → 重開 → `device_id` 不變、p5 補上 identity(v3 會換)。

**M7. 斷電續做與開機服務並行:helper 是 S89 的 procd 常駐,步驟 3/4 會和 S99 dockerd、guardian、S98 joinwatch 同時跑**

- 證據:04 `/etc/rc.d`:`S98joinwatch`、`S99dockerd`、`S99batman-payload-opentakserver`、`S99batman-autocommit`(`grep START` 皆 99);procd instance 背景執行,init 不等它(`init.d/batman-autocommit:3`「ordering is NOT relied on」是同一機制)。`payload-teardown:42,72-73` 需要 dockerd 活著(`docker rm -f`、`docker volume rm` 失敗都 `|| true` 吞掉)。
- 情境:步驟 3 中途斷電(guardian 的 `/etc/init.d/batman-payload-<t>` 還沒刪)→ 重開:S89 helper 續做步驟 3,dockerd 還沒起 → teardown 的 docker 指令全部靜默失敗 → `dockerd stop`(沒在跑)→ `rm -rf /opt/batdata/docker/*` 的同時 S99 dockerd 在同一個 data-root 初始化、guardian 拉起 OTS 寫 DB。結果大概率仍被步驟 4 清掉,但沒有任何斷言;§4.5「冪等」對這個交錯沒有證據。
- 修法:續做在**阻塞**的早期 init 跑(非 procd 的 `start()`,例如 S11 緊接 batdata-mount,順序執行、做完才讓 init 往下);或 dockerd / guardian / joinwatch 的 init 在 `factory-reset.inprogress` 存在時拒絕啟動。L16 斷電點加「步驟 3 中途」並斷言重開後 `docker ps -a` 空、無 OTS volume。

**M8. `claim/finish` 回應遺失 → 擁有者永遠連不回來(沒有 `owner_tag_key` 就沒有 `psk_owner`),只剩 SD 標記重置**

- 證據:`219-protocol.md:185` `claim/finish` 的**回應**帶 `owner_tag_key`、`adv_owner_key`、`root_password`;`:39` 已認領只接受 `NXpsk0`;`:148` 冪等鍵「跨 session 有效」,但要重送得先建 session —— 已認領節點不接受匿名 NX,app 沒有 `owner_tag_key` 建不了 NXpsk0。v3 §3「冪等鍵在 provd 記憶體,respawn 後消失」;§6.1 先 persist 再回應。R42:04 室內 5–10 m 只有 −82 ~ −95 dBm,斷線是常態。
- 修法(實作層可做):認領提交後 10 分鐘內(綁 boot_id、只綁該 `idem_key`)節點對匿名 NX **只**接受 `claim/finish` 重送並回傳快取結果;快取由 **helper** 持有(provd respawn 不丟);或改協定讓 `owner_tag_key` 由 app 產生、在 request 中加密給節點。L 矩陣加「認領回應遺失」列,負對照:helper commit 後丟掉回應 → app 以同 idem_key 重送 → 拿到同一份結果(v3:鎖在外面)。

**M9. L16(destructive 恢復出廠)指定在 02 做 —— 02 無乙太網、無 BLE build,而 harness 的 BLE central 也是 02;做完 02 無路可回**

- 證據:02 `cat /sys/class/net/eth0/carrier` = `0`、`/sys/class/bluetooth` 不存在(本輪實測;04 = `1` / `hci0`);R41「02 未升級到 BLE build」;§9「02 當 central 只驗 GATT 框架」;§9「L16 在 02 做…還原 = 重新 `halow-setkey` + 回 fleet 設定」。恢復出廠後 02:mesh key = placeholder(離網)、AP 關(unclaimed)、`authorized_keys` 清掉 → 主機經 mesh / AP / SSH 都到不了,`halow-setkey` 沒有人能下。
- 修法:L16 的前置寫死:(a) 02 先升 BLE build 且 p1+p3 改好;(b) 指定另一個 central(主機 BLE 介面或 04);(c) 還原路徑走產品本身 —— central 認領 02 + `net.apply` 回 fleet(正好是黑箱驗收);或 (d) 接乙太網 / serial 並寫進副作用清單。沒有可行還原路徑前不准排 L16。

**M10. `--prov-get` 的 rc 表不全:rc 3 混了 bypass / 無 p5 / 非 ext4;helper `--boot` 對 rc 9/10 的行為沒定**

- 證據:`batman-config-save:95-102,166`:讀取模式「no-p5」「bypass」「not-ext4」都 `exit 3`;§4.3 把 `--prov-get` rc 3 定義為 bypass;§4.2 只寫 rc 0/7 產生、rc 1/8 unknown、bypass unknown;rc 9(seeded 無 prov)只在 §5 L17 出現;rc 10(prov-corrupt)在 helper `--boot` 怎麼處理沒寫。
- 後果:無 p5 的卡或 raw p5 被當 bypass → 永遠 `unknown`、永遠不能認領;rc 10 時 helper 若落到「無 identity → 產生」分支 = M6。
- 修法:`--prov-get` 給 bypass / no-p5 / not-ext4 各自的 rc;§4.2 補 rc 9/10 的 helper 行為表(rc 10 → `unknown`,絕不產生);單元測試逐 rc。

### MINOR

- **m1. R43 / D18 的證據寫錯**:`jffs2reset.c:121` 先 `ask_user()`,`:134` 才 `volume_find("rootfs_data")` —— 「走到提示 rc=255」證明不了找到 volume。可改用原始碼補證(仍需 L16 實跑):`rootdisk.c:100-123` 以 `/rom` 的裝置找 squashfs、`:155-170` 以 `lo_file_name`+offset 重用既有 loop(04 `offset=113442816`);`jffs2reset.c:49-54` mounted → `fs_state_set(PENDING)` + `overlay_delete`;**下次開機** `overlay.c:444-454` 見 UNKNOWN/PENDING 會再刪一次 → 步驟 7 之後的寫入(含步驟 8 自己 `tboot_open` 的 `mkdir /mnt/slotboot.$$`,`batman-slot:412`)也會被清。所以「之後不得再寫 overlay」不是必要條件(設計自己也做不到),理由改寫成這條,D22 可升 ✅(原始碼)。
- **m2. dot 開頭的項目會在「全清」後留下**:`overlay.c` 的 `foreachdir` 用 `glob("%s/*")`(不含 `.*`)遞迴,dot 目錄不進去、其父目錄 rmdir 失敗。04 實測 overlay 有 `/overlay/upper/.cache/Tailscale/`(含 `tailscaled.log.conf`);設計自己的 `/etc/batman-prov/.stage/`、`.identity.tmp/` 也是 dot 目錄。p6 步驟 4 若用 shell `*` glob 會漏 `/opt/batdata/.faketime`(04 實測存在)。修法:步驟 7 後 helper 自己清 `/overlay/upper` 下全部(含 dot),步驟 4 明寫含 dot;L16 斷言 overlay upper 與 p6 只剩白名單。
- **m3. `--on-join`/`--check` 對 prov 的語意沒定死**:§4.3 說它們「納入 fp / same_identity / --check」但「只有 `--prov-file` 會寫 prov」。若 `--on-join` 把 prov 算進 `p5_matches`(`config-save:327`)卻不能寫它,不一致時每 tick 重寫 overrides(撞 `:375-383` 的限流);若它會寫,則步驟 3 與 4 之間的一個 tick 會把 p5 從 n+1 寫回 n。要明寫:`--on-join` 不寫也不比 prov;只有 `--check` 報 `prov-stale`,且 `P5_STALE_HINT`(`batman-slot:477`)要指向 helper(`--save` 修不了 prov)。
- **m4. `prov.meta` 格式兩處不一致**:§3 `<state> <generation> <sha256>`;§4.3 96 bullet「`v` 在 meta 第一欄之後加」。定一份:欄位、分隔、字元集、長度上限、多欄時的向前相容規則;96 與 config-save 共用同一 parser 的單元測試。
- **m5. SD 標記檔**:`batman-slot fw-part B` 在 04 回 `2`(autoboot 的分割序號,不是裝置),§3/§4.5 寫成「= 當前開機槽的 FAT」需要再映射到 `slot_bootdev`;使用者拿讀卡機時不知道哪個槽是 active → 放錯 FAT 就靜默無效。建議兩個 FAT 都讀、都刪;SD 路徑下「冷卻 60 s 可取消」由誰取消要寫。
- **m6. legacy 門 / `qr` 的 tty 限制在 §8 是 overclaim**:04 AP 上的人拿到的是 root,root 可以 `touch /etc/batman-dev-open`、加一行 `authorized_keys`、或直接讀 `identity/claim.secret`;互動 SSH 會配 pty,「stdin 是 tty」也成立。§8 那一列改寫成「legacy 節點 root 開放(#137)= 認領也開放;本設計只防止**意外**把操作員鎖在外」,負測試改名。
- **m7. `psks.get` 誠實界線寫窄了**:`psk_member` 由 `net_root` 導出、全網共用(`219-protocol.md:253,261`)→ 被攻陷的 provd 能對**整個網路**每一台冒充成員 session,不只「這台」;`owner_tag_key` 與 `root_password` 在 `claim/finish` 回應(`:185`)與 `root_password.reset` 時明文經過 provd(Noise 終點在 provd)。§4.1/§8 照實寫。
- **m8. `ble-ok` 寫入不看 core clock**:helper 在 committed 槽「第一次看到 Powered」就寫;p1/p3 沒改 `core_freq_min` 的節點(02 現況,R41)也會短暫 Powered → 之後每次 OTA 的 health 受 mini UART 漂移影響 → 間歇 revert。寫 `ble-ok` 的條件加「`vcgencmd get_config core_freq_min` ≥ 500 且連續 Powered ≥ 10 分鐘」。
- **m9. 認領回應裡 `root_password` 的產生時機**:§6.1「persist → rename → 鎖定」,鎖定才產隨機密碼,但回應要帶它(協定 `:185`);要寫明密碼在 stage 階段產生、persist 後才寫 shadow、回應前已在 helper 快取(與 M8 一起)。
- **m10. §3 擁有權表缺寫者**:`authorized_keys` 的 96 Lane A(`96:96-101`);`$ST/prov-state` 在 fresh 開機由 99zz(S10)寫;§3/§6.4 的 `$RUN/batman-prov.health` —— autocommit 裡 `$RUN` 已是 `$RUNDIR/autocommit.run`(`batman-autocommit:77`),改寫 `$RUNDIR`,免得照抄出錯。
- **m11. `--on-join` 會 seed 一個未 seed 的 p5**:`config-save:365-397` 對 `--on-join` 不檢查 `.seeded`,`p5_matches` 失敗就寫並 `: > .seeded`。恢復出廠步驟 5 之後,任何殘留的 joinwatch tick、操作員 `--save`、不帶 `--no-persist` 的 `halow-setkey` 都會把前任的 host key/shadow/hostname 寫回 p5,下次 fresh 開機 96 還原它們、helper 判成 `legacy`。步驟 2 前先 `joinwatch stop`;`--wipe-all` 留 p5 tombstone 讓其他寫入模式拒寫,直到 helper 的 unclaimed persist 清掉。
- **m12. 新 p6 檔的契約**:`ble-ok`、`ota-armed.mesh`、`factory-reset.inprogress` 的權限(0600)、`-O`/非 symlink 檢查(同 `batman-autocommit:54` 的 ctl_ok 規則);續做前比對 marker 的 `device_id` == 本機(卡片複製 / 搬卡)。
- **m13. p6 `lost+found` 被保留**:fsck 救回的碎片可能是前任 tenant 資料;列入誠實界線或一併清空內容。
- **m14. `ssh_keys.set` 以行尾 `batman-prov:<key_id>` 認自己的行**:任何能寫 `authorized_keys` 的人寫同樣標記就會被 helper 當成自己的而改刪;寫明這是同一信任等級可接受,或改用 helper 自己的 sidecar 清單。

---

## 3. 作者點名項逐一回答

| 項 | 結論 |
|---|---|
| §4.5 十步順序 | 範圍對(p6→p5→另一槽→overlay);缺失敗政策(B1)、續做並行(M7)、dot 項目(m2)、`--on-join` 重 seed(m11) |
| 冪等 / 每個斷電點 | 1–2、4–5、5–7、7 之後:原始碼支持(7 之後見 m1 的二次刪除);步驟 3 中途見 M7;步驟 6 照字面實作必失敗(B1) |
| `jffs2reset -y` on f2fs-on-loop0 / 下次開機 | 原始碼看可行(m1),但現有證據錯;下次開機 `mount_overlay` 再清一次,所以 7→9 之間的寫入無害 |
| 清 p6 時 dockerd/guardian 還在 | live 路徑:步驟 3 先停 ✅;續做路徑:M7 |
| SD 標記 `/boot` 永遠 p1 | 方向對;`fw-part` 回序號、使用者不知 active 槽(m5) |
| §6.4 `legacy` 規則 | ✅(`batman-autocommit:388-396` 原樣保留;`mark_mesh_expected` 不改) |
| `ota-armed.mesh` / stage 2 / 誰清 | ❌ 算不出來、沒人清(M1) |
| `ble-ok` gating | 機制對;寫入條件太鬆(m8) |
| `--prov-get` / `--prov-file` / `prov.meta` | `--prov-file` 明示 ✅;rc 表不全(M10);meta 格式不一致(m4);rc≠0 ≠ 沒寫(M3) |
| config-save 永不讀 `.stage/` vs `--on-join` | ✅ 收了;但 prov 是否進 `p5_matches` 要定(m3);`--no-persist` 的 `uci commit` 讓「未提交交易進 p5」從 wireless 那一側回來(M2) |
| §4.4 claim 先 persist 後鎖 | ✅ 解決 A-M2;回應遺失(M8)、密碼產生時機(m9) |
| §6.1 legacy 門 | 擋得住「意外鎖死操作員」✅;擋不住 AP 上的 root(m6) |
| `psks.get` 誠實界線 | 寫窄了(m7) |
| helper `--boot` p5 不可讀 | fresh:`unknown`、下次再試 ✅;非 fresh:沿用 overlay ✅;但「unknown → SD 重置」本身死鎖(B1),rc 3/9/10 未定(M10) |
| 96 4b 依 `prov.meta` 跳過 / hostile p5 | hostile p5 不是新提權(本來就能放 `authorized_keys`);非惡意失敗變 fail-open(M5) |

---

## 4. 逐 actor

| Actor | v3 擋住 | 本輪沒擋住 / 寫錯 |
|---|---|---|
| BLE 路人 | 匿名只 `status/public`、無 agent、LE only、≤2 連線、8 KiB | — |
| 路人 → 攻陷 provd | 換擁有者 ✅(helper 重算 ClientChal)、首版 join 需 owner-op ✅、無 ecdh/persist ✅ | 誠實界線:全網 `psk_member`、`owner_tag_key`/`root_password` 經手(m7) |
| 本機非 root | dbus 無 default、socket PEERCRED、0600 | 新 p6 檔權限未寫(m12) |
| 攻陷的 tenant(OTS) | 碰不到 `state/` | 續做與 guardian 並行(M7) |
| 前任擁有者(轉賣) | p5/p6/另一槽/overlay 都清 | dot 項目殘留(m2)、`--on-join` 重 seed(m11)、步驟失敗卡住(B1) |
| 買家 | 新身分、新 QR | 認領回應遺失鎖在外(M8);新 QR 怎麼拿見 §6 |
| 實體 SD | 標記檔要 device_id | 續做 marker 不比 device_id(m12);放錯 FAT(m5) |
| legacy fleet(02/04)第一次 OTA | mesh 閘不變 ✅、AP/dropbear 不動 ✅ | §4.4 步驟 7 文字會解鎖 LOCKED legacy(M4) |
| 單台在家更新 | commit(因 M1 的缺陷碰巧對) | 有鄰居的 member 也降成只看 radio(M1) |
| 我們自己 | 單寫者表大致完整 | 96 4b fail-open(M5)、身分重產(M6)、L16 無還原路徑(M9)、證據寫錯(m1) |

---

## 5. v2 發現核對(一條一行)

| v2 | 狀態 | 說明 |
|---|---|---|
| A-B1 恢復出廠 | 部分 | 範圍與順序對;B1、M7、m2、m11 |
| A-B2 legacy mesh 閘 | 已收 | `:388-396` 保留、`mark_mesh_expected` 不改 |
| A-B3 claim 換 owner | 已收 | helper 重算 ClientChal,介面無 `client_chal` |
| A-M1 `.stage` 讀者 | 部分 | `.stage` 已收;M2(uci commit)、M3(rc 6)、m3 |
| A-M2 shadow 回滾 | 已收 | 鎖在 persist 之後 |
| A-M3 96 vs helper 兩寫者 | 部分 | 兩寫者解了,換成 fail-open(M5) |
| A-M4 owner-auth 標籤 | 已收 | `batman-owner-op-v1` |
| A-M5 首次 join 授權 | 已收 | |
| A-M6 `keystore.ecdh` | 已收(界線部分) | 動詞刪了;誠實界線 m7 |
| A-M7 health BLE | 部分 | `ble-ok` 對;寫入條件 m8 |
| A-M8 身分原子 | 部分 | tmp+rename 對;反方向缺 M6 |
| A-M9 hook 走 setkey | 已收 | `--firstboot` |
| A-m1 dbus send_interface | 已收 | |
| A-m2 restore marker 非 fresh | 已收 | verdict 全出口、helper 自己看 p5 |
| A-m3 96 還原契約 | 部分 | meta 格式不一致 m4 |
| A-m4 overlay 壞 p5 好 | 已收 | L33 |
| A-m5 非 ext4 → raw | 已收 | |
| A-m6 counter | 已收 | |
| A-m7 persist 授權 | 已收 | |
| A-m8 seed_key_ok | 已收 | |
| A-m9 dev-open 進 wsl | 已收 | |
| A-m10 降級 | 已收 | L12 |
| A-m11 root 密碼遺失 | 部分 | `root_password.reset` 有;整包回應遺失 M8 |
| A-m12 mesh-joined | 已收 | |
| A-m13 SD 標記 | 部分 | m5 |
| A-m14 legacy 定義 | 已收 | |
| A-m15 typo | 使用者決定 | 不動 |
| A-m16 perms / boot 綁定 | 部分 | prov-state 有;新 p6 檔 m12 |
| B-B1 serdev | 已收 | R38 實機 |
| B-B2 恢復出廠 | 部分 | 同 A-B1 |
| B-B3 legacy mesh 閘 | 已收 | |
| B-M1 `.stage` | 部分 | 同 A-M1 |
| B-M2 marker 四/五態 | 已收 | 狀態只由 prov.cbor |
| B-M3 marker 永久凍結 | 已收 | |
| B-M4 health BLE | 部分 | m8 |
| B-M5 單台在家 | 未收(實質) | `ota-armed.mesh` 在 stage 2 算不出(M1) |
| B-M6 ecdh | 已收 | |
| B-M7 套件依賴 | 已收 | R39 |
| B-M8 S10 setkey | 已收 | |
| B-M9 legacy 鎖住操作員 | 部分 | 意外鎖死擋住;AP root 攻擊 overclaim(m6) |
| B-M10 不存在的動詞 | 部分 | 已列入 PR-P1;`clear_root` 的 `ZERO_MB` 不存在(B1) |
| B-m1 sign 訊息 | 已收 | |
| B-m2 claim chal | 已收 | |
| B-m3 persist lkg / regex | 已收 | |
| B-m4 prov-state boot id | 已收 | |
| B-m5 SD 標記 | 部分 | m5 |
| B-m6 respawn | 已收 | |
| B-m7 bluetoothd 無 hci0 | 已收 | |
| B-m8 hostname 洩漏 | 已收 | SSID=hostname 列殘項 |
| B-m9 device_id | 已收 | |
| B-m10 96 還原 identity 信任 | 已收 | |
| B-m11 trial 認領 | 已收 | |
| B-m12 qr 進 log | 已收 | |
| B-m13 p1 版本 | 已收 | |
| B-m14 非 fresh p5 掛不起 | 已收 | |
| B-m15 讀 Powered | 已收 | health 檔 |
| B-m16 lock-status 順序 | 已收 | |

---

## 6. 使用者已定案事項的後果(不重開,只列)

- **U4 全清含身分**:機身印的 QR 在恢復出廠後失效;買家拿新 QR 的唯一路徑是 root(`batman-provhelper qr`,unclaimed 時乙太網 + image 預設空密碼)。轉賣流程要寫明(例如「接乙太網取 QR」),否則一般買家無法認領。
- **U3 擁有權與 SSH 脫鉤**:`LOCKED` 可能等於「完全沒有 SSH」;若實作成停 dropbear,`meshjoin_reachable`(`meshjoin.sh:26`)永遠假 → 見 M1。
- **3A+ 延後**:`batman-slot`(`invalidate-other`、ota-armed)、`config-save`、`96`、`halow-setkey`、`autocommit`、`joinwatch` 的改動在 bcm2710 未測;`RAMFS_COPY_BIN` 兩板共用 —— M1 的修法會改 stage 1/2,兩板都要驗。
- **改名探針待跑**:L23/D15 仍 ⚠️。

## 7. v4 前需要的唯讀探針 / 實跑

1. L16 實跑前(02 先升 BLE build、先解決 M9),在 bench 上做一次 `find /overlay/upper -mindepth 1` 前後比對(m1/m2)。
2. 在 stage 2 log(p6t `ota-trace.log`)印 `command -v iw batctl ip` 與 `meshjoin_reachable` 結果,證實 M1;或直接改在 stage 1 判定。
3. M9 的 L16 還原路徑先定案再排。

## 8. 判定

**REJECT(v3)** — BLOCKER ×1、MAJOR ×10、MINOR ×14。B1 是「設計寫的補救在自己的觸發條件上會讓節點永久失聯」;MAJOR 多半是交易 / 開機對帳的契約缺口,修法都已給、都是局部改動。改完後整份重審(兩位獨立審查)。
