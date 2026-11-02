# Review A(第 2 輪)— `254-stage1-impl-v2.md`(#254 階段 1 實作設計 v2)

審查者 A,獨立、對抗式。審整份(§0–§13),不是只看 v1→v2 的差異。依 `REVIEW.md` + 使用者 CLAUDE.md 設計審查規則:先找矩陣缺列 / 擁有權缺資源,再從現場情境逐 actor 攻,每個假設對原始碼或真機核對。使用者已定案的事項(擁有權與 SSH 脫鉤、階段 1 恢復出廠全清、Go/Flutter、3A+ 延後、改名探針 ⚠️ 待跑)不重開,只列後果。

**證據來源(全部唯讀,2026-10-18)**
- Batman `main` f2f2bf6:`96-batman-config-migrate`、`batman-config-save`、`batman-autocommit`、`batman-slot`、`halow-setkey`、`halow-keyguard`、`99-halow-identity`、`joinwatch`、`meshjoin.sh`(scratchpad `src/`,與前一輪相同快照)。
- firmware-2710:`target/linux/bcm27xx/image/boards/ekh01/distroconfig.txt`、`dl/bluez-5.72.tar.xz` 內 `src/bluetooth.conf`、`feeds/packages/utils/bluez/Makefile:120-158`。
- 節點 04(10.41.1.3,slot A,1.5.12-wsl.2)與 02(10.41.1.1,slot B):`ls -la /opt/batdata/state`、`/etc/init.d/* START/STOP`、`/rom/etc/uci-defaults`、`/etc/config/dropbear`、`/proc/cmdline`、`/proc/device-tree/soc/serial@7e215040/bluetooth/status`、`vcgencmd get_config`、`/usr/share/dbus-1/system.conf`、`/etc/dbus-1/system.d/`、`docker inspect` mounts、p5 `ro,noload` 掛載後 `ls` + umount。**沒有任何寫入。**

---

## 0. 總評

v2 把 v1 的骨架問題大多收對了方向:p5 = SoT + 96 四態 marker、helper 自驗授權物件、單檔 `prov.cbor` + generation、`legacy` 狀態、`halow-setkey --ap-off`、dbus policy 替換、自建 kmod、撤內建 CA、`$ST/prov-state` 取代 `mesh-solo`。這些可以保留。

但三件事在真機上會直接咬人,而且都是 v2 **新寫進來**的:

1. **恢復出廠(§4.5)做出來的不是「出廠」,而是「前任擁有者的 legacy 節點」**:順序是 `--wipe-all` → `halow-setkey --ap-off --mesh-off`,而 `halow-setkey` 最後一定跑 `batman-config-save --save`(`halow-setkey:147`)→ p5 **立刻被重新 seed**(`.seeded`、overrides、`identity/dropbear/*`、`shadow-root` = 前任的隨機 root 密碼);現行 overlay 完全沒清(hostname、host key、`authorized_keys` 的前任 `batman-prov:` 行、PasswordAuth=off、隨機密碼);p6(`lock-status`、`prov-state`、OTS 資料)沒清;`batman-slot invalidate-other` **這個動詞不存在**。219 §7 明寫要清的五樣(authorized_keys、root 密碼、lock-status、整個 p5、p6、另一槽 overlay),v2 只做到 p5 的一半。
2. **既有 fleet(02/04 = `legacy`)升級後失去 OTA 的 mesh 閘**:L6 把 `legacy` 和 `claimed` 都判 NEED_MESH=0。今天 02/04 任何 OTA 都要求入網才 commit(`batman-autocommit:388-397` + 兩台 p6 都有 `mesh-expected`)。v2 之後,一個 morse 驅動壞掉的 image 在 02/04 上會被 **commit**。這是 1.4.12 事故(brcmfmac 掉包、02 stranded)的同型回歸,而第一批要升到階段 1 image 的就是這兩台。
3. **helper 授權模型在 `claim.verify` 上有洞**:`client_chal` 由 provd 傳入而不是 helper 自己算。被攻陷的 provd 在買家認領的那一刻把 `owner_pub` 換成攻擊者的,helper 用 provd 給的 `client_chal` 驗 MAC 會過 → 攻擊者成為擁有者。v2 §0 的「provd 被攻陷 ≠ 能改網、能重置」在最重要的資產(擁有權)上不成立。

另有 MAJOR 一批(`.stage/` 會被 `--on-join` 提前發布、shadow 不回滾把 04 鎖死、`owner.auth` 重用協定標籤但換了內容、`net.apply` 第一次 join 沒有授權來源、`keystore.ecdh` 是沒有消費者的解密 oracle、S10 hook 走 `halow-setkey` 會等 20 s 並在 S10 寫 p5、BLE 進 `health_ok` 會在 p1 未重燒的 02/04 上把升級 revert 掉、identity 產生與 `--on-join` 的複製競爭)。

**判定:REJECT(v2)**。架構不用推翻;要改的是 §4.5 整段、L6/§4.3 的 legacy 規則、§4.1 三個動詞的輸入與標籤、§4.4 的 `.stage` 消費者與回滾範圍、§2/§3 的 hook 執行模式。改完整份再審。

---

## 1. v1 發現的收法核對

| v1 | 狀態 | 說明 |
|---|---|---|
| A-B1 / B-M1 autocommit | **部分** | `$ST/prov-state` 機制對;但 `legacy → 0` 是回歸(本輪 B2);S10 hook 寫 prov-state 的時序 OK(95 先掛 p6、autocommit S99 之後讀) |
| A-B2 / B-B1 dropbear 無 ECDSA | **已收(U3)** | 後果未寫全:無 key 的節點(04)認領後 SSH 全關、Ethernet 管理消失;96 的 4b 在 fresh overlay 會把它判 UNPROVISIONED(兩寫者,M3) |
| A-B3 / B-M8 overlay vs p5 | **部分** | p5 SoT + marker + 交易式 apply 對;但 `.stage/` 被 `--on-join` 消費(M1)、shadow 不回滾(M2)、overlay 壞而 p5 好的路徑沒有(m4)、ext4 magic 判「raw」的 fail-open(m5) |
| B-B2 helper 無授權 | **部分** | 模型有了;`claim.verify` 輸入(B3)、`owner.auth` 標籤(M4)、`net.apply` 首次 join(M5)、`keystore.ecdh`(M6)、`persist --promote-lkg`(m7) |
| B-B3 / A-M2 prov 複製語意 | **已收** | 單檔 + generation + fp 納入;`identity/prov/` 一次寫入與 helper 產生的原子性要補(M8) |
| B-M3 legacy 升級 | **部分** | 狀態有了、AP/dropbear 不碰對;autocommit 回歸(B2);`batman-dev-open` 進 wsl 頻道的後果(m9) |
| A-M1 / B-M4 dbus | **已收** | 替換 policy 要保留 root 的 `send_interface` 白名單,否則 bluetoothd 呼不到 provd 的 GATT 物件(m1) |
| B-M5 / A-M6 kmod / BlueZ | **已收(紙上)** | 等 PR-F |
| B-M6 keystore | **大致已收** | `claimed.counter` 放在一次寫入目錄 → 不單調(m6);provd 需要的 PSK 材料(`owner_tag_key`、`net_root`)沒有動詞(M6) |
| A-M3 開發 CA | **已收** | |
| A-M4 降級後果 | **部分** | 漏寫:`claimed` 未入網的節點**降不了級**(舊 autocommit 見 `.seeded` 就要求 mesh → revert 回階段 1)(m10) |
| B-M7 / A-M8 恢復出廠 | **未收(B1)** | |
| B-M9 / A-m9 core clock | **已收** | 02/04 p1 要重燒;本輪 M7 指出它與 `health_ok` 的交互 |
| B-M10 `--seed` lkg | **已收** | |
| B-M11 測試 | **已收** | |
| A-M5 mesh-solo | **已收** | |
| A-M7 改名 | **開(⚠️ 使用者決定)** | |
| A-m2 96 還原 prov 的信任 | **部分** | §10 PR-P1 寫「驗檔」但沒有契約(m3) |

---

## 2. 矩陣缺的列、擁有權缺的資源

| 缺的路徑 / 資源 | 為什麼要有 | 對應 |
|---|---|---|
| **p6 在恢復出廠中的角色**(`lock-status`、`prov-state`、`mesh-*`、`autocommit-*`、`docker/`、`apps/`)— 04 的 p6 同時是 docker data-root(`/dev/mmcblk0p6 on /opt/batdata/docker`),五個 OTS 容器 volume 都在上面 | 219 §7 要清 p6;清 p6 要先停 guardian/容器(#274 的擁有權) | B1 |
| **現行槽 overlay 在恢復出廠中的角色** | 219 §7:「先清 p5 再清 overlay」;v2 只清 p5 | B1 |
| **`--on-join` 與 `state.apply` 交錯**(joinwatch 每 tick 跑 `--on-join`,`joinwatch:145`) | `.stage/prov.cbor` 若被 `--on-join` 讀到就提前發布 | M1 |
| **overlay `prov.cbor` 壞 / 不見,p5 完好**(f2fs 位元壞、人為刪) | v2 只處理 generation 大小,沒處理「overlay 壞」→ `unknown` → AP 關、只剩 SD 標記全清 | m4 |
| **helper 產身分期間 `--on-join` 複製 `identity/prov/`**(legacy 04 在 mesh 裡,joinwatch 每 tick 跑) | 半套身分被「一次寫入」到 p5 | M8 |
| **p1 未重燒的 02/04 OTA 到階段 1**(`core_freq_min=200`) | `health_ok` 加 `hci0 Powered` → 間歇失敗 → revert | M7 |
| **`claimed` 未入網 → 降級到 1.5.12** | 舊 autocommit `.seeded` → NEED_MESH=1 → revert 回來,降不了 | m10 |
| **random root 密碼在 `claim/finish` 回應遺失**(BLE 斷在 helper commit 之後) | 擁有者拿到一台 LOCKED、密碼未知的節點;沒有 `settings/root_password` 動詞 | m11 |
| 資源:`$ST/mesh-joined`(joinwatch 寫) | `network/leave` 後舊 image 仍視為 expected | m12 |
| 資源:`/boot`(p1,04/02 都 **rw 掛在 /boot**)上的 `batman-factory-reset` 標記 | 誰刪(helper)、何時(清完)、bypass 時要不要理 | m13 |
| 資源:provd 持有的 `owner_tag_key[]`、`net_root`(NXpsk0 要用) | 不在 §3,也沒有動詞 | M6 |

---

## 3. Findings

### BLOCKER

**B1. 恢復出廠(§4.5 / L16)做出來的是「前任擁有者的 legacy 節點」,且呼叫了不存在的動詞**

現場:擁有者轉賣前在 app 按「恢復出廠」。v2 順序:寫 `$ST/factory-reset.inprogress` → `batman-config-save --wipe-all` → `halow-setkey --ap-off --mesh-off` → 清 `/etc/batman-prov` → `batman-slot invalidate-other` → 刪 marker → reboot。

證據與後果,逐步:
1. `--wipe-all` 清 p5(prov.cbor、identity/*、shadow-root、overrides、lkg、`.seeded`)✅。
2. `halow-setkey --ap-off --mesh-off`:`halow-setkey:140-152` 每次成功套用後**無條件** `batman-config-save --save`;`batman-config-save:287-288` `--save` 是 first-seed 路徑,`:389-397` 會寫 `identity/dropbear/*`、`shadow-root`(`:302-305`,取**現行** `/etc/shadow` 的 root 行 = 前任的隨機密碼)、`overrides.uci`(hostname、placeholder key、IP)、最後 `: > .seeded`。→ **p5 在第 2 步就被重新 seed**。下次 fresh overlay:96 掛到 seeded p5、無 prov.cbor → 依 §1.4 定義 = **`legacy`**,不是 `unclaimed`;96 Lane A 還原前任的 host key 與 root 密碼 hash(`96:96-117`)。
3. 清 `/etc/batman-prov`:只清 prov;**現行槽 overlay 其他東西都在**:`/etc/dropbear/authorized_keys`(含前任用 `ssh_keys.set` 裝的 `batman-prov:<key_id>` 行 — v2 沒說 wipe 會刪它們)、`/etc/shadow`(前任隨機密碼)、`dropbear.PasswordAuth=off`、`system.ttylogin=1`、hostname、host keys、`/etc/openmanet/config.yml`。reboot 後 overlay 不是 fresh,96/99zz 都不跑。→ **新買家認領前,前任仍可用自己的 SSH 金鑰 root 登入**;新買家認領後 helper 只「追加/刪除 app 自己加的行」(§3),前任的行若標記相同就會被視為 app 的……總之沒有定義。
4. p6 沒清:`lock-status=LOCKED`、`$ST/prov-state=member …`(直到 helper 下次 `--apply-state` 改寫)、`mesh-expected`/`mesh-joined`、**OTS 的資料庫與 EUD 名單**(04:`/opt/batdata/docker/volumes/ots-pgdata`、`ots-appdata`)— 219 §7「p6 資料」明列要清;而 p6 同時是 docker data-root,清它之前要先停 guardian 與容器(#274 的單一擁有者規則),v2 沒提。
5. `batman-slot invalidate-other`:**不存在**。`batman-slot:785-809` 的動詞是 `active|target|layout|fw-part|stage-root|apply|commit|rollback|is-trial|verify|precheck-node|verdict-gate|reboot committed`;`invalidate_slot()`(`:381-390`)是 `apply` 內部用的函式(寫 `cmdline.txt` 為 BATMAN-BAD)。要新增動詞 = 兩板共用檔改動、要有 `is-trial` 拒絕、要有測試;v2 §13 把它當「已有」。
6. 試用期拒絕 → `E_TRIAL` 不開始:對,但沒說使用者下一步(先 `batman-slot commit` 或等 autocommit)。

收法(照 219 §7 的順序與範圍):
- 順序:停 payload guardian/容器 → `halow-setkey --ap-off --mesh-off --no-persist`(或改為只 `uci set` + 不 `--save`)→ 清 p6 state(保留 `factory-reset.inprogress` 到最後;OTS volumes 依 219 清)→ `--wipe-all`(p5)→ 新增 `batman-slot invalidate-other`(拒絕 trial)→ **清現行 overlay**(f2fs rootfs_data 的 firstboot 等價;`96:155-160` 的註解已預期「factory-reset = overlay wipe 會重跑 96」)→ 刪 marker → reboot。結果 = fresh overlay、96 看到未 seed 的 p5 → marker=`absent` → `unclaimed`、新身分。
- `--wipe-all` 要拒絕在 `halow-setkey --save` 之後被呼叫?不如反過來:`halow-setkey` 加 `--no-persist`(只給 helper 用)。
- 矩陣 L16 加兩個斷電點(p5 清後 overlay 清前;overlay 清後 marker 刪前)與斷言:重開後 `status/public` = `unclaimed`、`authorized_keys` 不存在、`/etc/shadow` root 行 = image 預設、p6 無 `prov-state`、舊 `claim.secret` 無效、舊 SSH 金鑰 `ssh -i` 被拒(負對照:v2 順序下會成功登入)。

**B2. `legacy`(= 02/04 升級後)與「legacy 認領後的 `claimed`」被判 NEED_MESH=0 → 既有 fleet 失去 OTA 的 mesh 閘**

現場:02/04 升到階段 1 image(L17)。之後任何一次 OTA 到一個 morse 壞掉的 image(1.4.12 事故的同型:kmod 掉包、channel 錯、驅動 panic)。

證據:
- 今天:`batman-autocommit:388-397` `expected_in_mesh()`:p6 `mesh-joined`/`mesh-expected` 任一存在 → NEED_MESH=1;兩台 p6 都有(04:`mesh-expected` Jul 5、`mesh-joined` Jun 30;02:Oct 6 / Oct 1)。沒入網 → deadline revert(`:460-466`)。
- v2 L6:「`$ST/prov-state` 存在 → `unclaimed|claimed|legacy` → 0」;§4.3「`mark_mesh_expected()` 在 prov-state 存在時不寫」;§1.4 legacy 升級後 helper 寫 `$ST/prov-state=legacy …`。→ 02/04 升級後第一次 OTA 起就 NEED_MESH=0。`health_ok` 只看 `mesh11sd openmanetd wpad` 程序在跑(`:421-425`),radio 壞了程序照跑。
- legacy 認領(L18)後 = `claimed`,但節點實際上在手動設定的 mesh 裡(AP/mesh「不動」)→ 同樣 0。
- 219 §6.3 要求的是「已認領未入網也能 commit」與「單台網路也能 commit」,不是「legacy 不用 mesh」。

收法:NEED_MESH 不要只看 prov 狀態,看**live mesh key 是否為 placeholder**:
- `legacy` → 今天規則(marker / `.seeded`),`mark_mesh_expected()` 在 legacy 時照寫;
- `claimed` 且 live mesh key ≠ placeholder(legacy 認領後)→ 1;
- `claimed` 且 placeholder → 0;`unclaimed` → 0;
- `member`:members>1 → 1;members==1 → `meshjoin_radio_up`(v2 已有)。
- 負對照:04(legacy)OTA 到 `radio1.disabled=1` 的 trial image → 今天 revert、v2 規則 commit、修後 revert。

**B3. `claim.verify` 的 `client_chal` 由 provd 提供 → 被攻陷的 provd 可在買家認領時把擁有者換成攻擊者**

現場:路人用 BLE 打中 provd(未交握就可達的 Noise/CBOR/GATT 解析)取得 provd 執行權(v2 §8 自己列的 actor)。買家此時掃 QR 認領。

證據:
- 協定 §5.4:`ClientChal = SHA-256("batman-claim-v1" ‖ nonce ‖ h ‖ SHA-256(DAC) ‖ owner_pub)`,app 用**自己的** `owner_pub` 算,回 `response = SHA-256(K ‖ ClientChal ‖ OtherData…)`。
- v2 §4.1:`claim.verify(client_chal, client_resp, owner_pub, owner_enc_pub, sig_enc, h)` — helper 拿 provd 給的 `client_chal` 做 CheckMac,再把 provd 給的 `owner_pub` 寫進 prov.cbor。兩者之間沒有綁定。provd 傳 `(client_chal_買家, client_resp_買家, owner_pub_攻擊者, …)` → CheckMac 過 → 擁有者 = 攻擊者;買家的 app 收到 ok(provd 可以回任何東西)。
- 這正是 v2 §0 宣稱 helper 自驗授權物件要擋的情境;對 `net.apply`/`owner.auth` 做到了,對 `claim.verify` 沒做到。

收法:helper 自己重算 `ClientChal`(nonce 是 helper 發的,DAC 在 helper,`owner_pub` 用**即將寫入**的那把;`h` 由 provd 給沒關係 — 它只是把 MAC 綁到 session,換不了擁有者);介面改成 `claim.verify(h, client_resp, owner_pub, owner_enc_pub, sig_enc)`。同理 `sig_enc` 用同一把 `owner_pub` 驗。負測試:以 provd uid 直接送 `(client_chal_A, resp_A, owner_pub_B)` → `E_FORBIDDEN`;v2 介面會寫入 B。

### MAJOR

**M1. `.stage/prov.cbor` 會被 `--on-join` 提前發布到 p5 → 回滾掉的交易在下次開機被「p5 較新」規則復活**

- §4.4 步驟 3:「config-save 讀 `.stage/prov.cbor` 若存在」。`joinwatch:145` 每 tick(JOINED 時)跑 `batman-config-save --on-join`,它與 `--save` 共用 `stage_overrides()`。helper 在步驟 1 寫好 stage、步驟 2 套副作用(`halow-setkey` 要等 `wifi reload` + 20 s 讀回,`halow-setkey:134`)期間,`--on-join` 跑到 → p5 拿到 generation n+1。步驟 2 失敗 → helper 回滾副作用、刪 stage → overlay 仍 n、p5 n+1 → 下次開機 §4.4 步驟 6「p5 generation > overlay → 以 p5 重建 overlay」→ 失敗的那版網路設定變成現行。
- 同一期間 `batman-slot precheck` 的 `--check` 比哪一份也沒定義。
- 收法:`.stage/` 只有 helper 自己的 `--save --prov-file <path>`(明確參數)會讀;`--on-join`/`--check`/操作員 `--save` 永遠讀 `/etc/batman-prov/prov.cbor`。helper 在交易期間持有 `cfgsave.lock`?不行(`config-save:118` 接管規則),所以用明確參數。測試:helper 緊迴圈 apply-fail vs joinwatch tick,斷言 p5 generation 不前進。

**M2. 回滾不還原 shadow → 認領失敗/斷電後 root 密碼「誰都不知道」;04 會被鎖死**

- L7:「shadow 保留,PasswordAuth 依狀態」。步驟 2 已寫隨機 24 字元到 `/etc/shadow`,步驟 3 `--save` 失敗(rc≠0,例如 p5 忙 / mount 來不及 rw,`config-save:234-250` 的 T11 路徑)或步驟 2-3 之間斷電 → 回滾只把 PasswordAuth 開回來,密碼仍是沒交給任何人的隨機值。04 今天 root 空密碼、無 `authorized_keys`(本輪實測)、harness 靠 Ethernet 密碼登入 → **一次失敗的認領就把 04 鎖在 Ethernet 外**,只剩 BLE 再認領一次(能救,但 harness/OTS 維運當場斷)。
- 收法:stage 裡存舊 root 行,回滾還原;或把 shadow/dropbear 這兩個副作用移到 persist **之後**(它們不會失敗,先 persist 再鎖),`--apply-state` 開機從 prov.cbor 重算時對 `unclaimed|legacy` 一律把 PasswordAuth 恢復 image 預設並**不碰 shadow**(此時 shadow 已是舊值)。`prov-powerloss-254` 斷言:斷電點在步驟 2 後 → 重開後 04 仍可空密碼登入(負對照:v2 規則下不能)。

**M3. fresh overlay 上 `lock-status` / dropbear uci 有兩個寫者(96 的 4b 與 helper 的 `--apply-state`),而且 96 會判出相反的結果**

- `96:161-176`:LOCKED 需要 `has_key=1 && has_pw=1`;U3 之後認領**不寫** `authorized_keys` → 沒有 lab key 的節點(04、所有民用新機)在每次 fresh overlay 上被 96 寫成 `UNPROVISIONED`、dropbear 留 image 預設(PasswordAuth on),然後 99zz 的 helper 再改回 LOCKED/off。同一 S10 內改兩次、log 兩條相反的 lockdown 行;`halow-status` 讀 `lock-status` 的文字也會在 96 與 99zz 之間錯。§3 把 96 列為 fresh overlay 的寫者卻沒改 96 的規則。
- 另一後果要明寫:`LOCKED` 的語意從「key-only」變成「可能完全沒 SSH」。
- 收法:96 的 4b 在 p5 有 `prov.cbor` 且 state ∈ {claimed, member} 時跳過(由 helper 當唯一寫者);或 96 只在 `legacy|absent` 做舊推導。單元測試 96 對四種 marker + 有/無 prov 的輸出。

**M4. `owner.auth` 重用協定標籤 `batman-owner-auth-v1` 但換了被簽內容 → 一個標籤兩種格式,且是未宣告的協定改動**

- 協定 §3.5:`auth/owner` 的 `sig = ES256_owner("batman-owner-auth-v1" ‖ h ‖ owner_key_id)`(119 項向量含它)。v2 §4.1:`ES256_owner("batman-owner-auth-v1" ‖ h ‖ nonce_helper ‖ verb ‖ args_hash)`。同一把鑰匙、同一標籤、兩種訊息長度 → 協定 §3.6「每種用途一個標籤」被破;Go 與 Rust 兩邊會各做一種;向量/`verify.py` 沒有這條。§1.3 的「與上層不同處」沒列。
- 收法:新標籤(如 `batman-owner-op-v1`)、進 `219-protocol.md` v0.7 + CDDL + 向量;`auth/owner`(session 升級)與 per-verb 授權分開。

**M5. `net.apply` 的第一次 `network/create|join` 沒有授權來源:`prov.cbor.admins` 一開始是空的**

- §4.1:`net.apply` 用 `prov.cbor.admins` 驗 `net_config` 鏈;協定 §7.1:「第 1 版由建立者自簽,手機與節點記下 `net_id` 與建立者公鑰」。節點「記下」的動作就是信任的起點,必須由擁有者授權(否則被攻陷的 provd 可把節點加入攻擊者自簽的網路,再推 `net_secrets` 換掉 SAE key = 整隊掉網的路徑回來了)。`owner.auth` 的動詞表列了 `network/leave` 但沒有 `network/create|join`。
- 收法:`net.apply` 在 `prov.cbor.net` 為空時要求 `owner.auth(verb=network/join, args_hash = H(net_config v1 ‖ net_secrets))`;之後的版本才靠 `admins` 鏈。負測試:provd uid 送自簽 `net_config` v1 無 owner auth → `E_FORBIDDEN`。

**M6. `keystore.ecdh(peer_pub)` 沒有任何合法消費者,卻是 `net_secrets` 的解密 oracle;provd 真正需要的 PSK 材料反而沒有動詞**

- 協定 §3.3/§6:Noise 的靜態金鑰 `s_node` 是 **25519、每次開機在記憶體**(provd 自己產,helper 只簽 `sig_static`);P-256 ECDH 金鑰**唯一用途**是 §7.3 `net_secrets` 的 ECDH-ES(+HKDF-256,context 固定)。v2 已把 `net_secrets` 解密放進 helper(`net.apply`)。那 `keystore.ecdh` 給誰用?若它的 HKDF 標籤/context 與 COSE 的相同,provd 拿 `net_secrets` 裡的臨時公鑰呼叫一次就得到 KEK → 解出 SAE key,「明文 SAE key 不經 provd」失效。若不同,它什麼都做不了 → 砍掉。
- 反過來,NXpsk0 交握(協定 §3.4)需要 provd 持有 `psk_owner[]`(由 `owner_tag_key` 導出)與 `psk_member`(由 `net_root` 導出,而 `net_root` 在 `net_secrets` 明文裡)→ helper 解密後必須把 `net_root`、`owner_tag_key[]`(或導出的 PSK)交給 provd。§3/§4.1 沒有這個動詞、沒有資源列、沒有「provd 持有 `net_root` = 可冒充全網成員」的誠實界線(協定 §6 有,v2 要引用)。
- 收法:刪 `keystore.ecdh`;新增 `psks.get` → 回 `{psk_owner[], psk_member(current), adv_*}`(只回導出值,不回 `net_root`/`owner_tag_key` 本體),每次 prov.cbor 變更後 provd 重拉。

**M7. `health_ok` 加 `hci0 Powered` 會在 p1 未重燒的 02/04 上讓升級間歇 revert**

- 兩台 DT `serial@7e215040/bluetooth/status = okay`(`miniuart-bt` 已在現行 p1 生效,`enable_uart=1`)→ 裝了 kmod + `.hcd` 後 `hci0` 會出現;但 `core_freq_min=200`(兩台實測)→ 閒置時 mini UART baud 漂移 → HCI 錯框 → `Powered` 可能掉 → autocommit 在 trial 期間 `health regressed … resetting dwell` → revert。L19 說「02/04 手動重燒 p1(使用者)」,但 L17 的升級測試沒把它列為前置,`health_ok` 也沒有「legacy 時只 WARN」的分支。
- 收法:(a) L17 前置條件 = p1 已重燒(PR-F 驗收含 10 min 閒置取樣);(b) `health_ok` 的 BLE 項在 `legacy` 狀態降為 WARN(log + `halow-status`),`unclaimed|claimed|member` 才 gating;(c) 另外 `hci0 Powered` 要用 root 能用的查法(`bluetoothctl show` 或 `btmgmt info`,policy 允許 root)寫清楚。

**M8. 身分產生不是原子的,而 `--on-join` 每 tick 都在複製 `identity/prov/`「一次寫入」**

- Q1 決定 legacy 升級後開機就產身分。04/02 都在 mesh 裡 → joinwatch 每 tick `--on-join`(`joinwatch:145`);v2 §4.3 讓 `onjoin_fp()` 納入 `identity/prov/` 的 sha → helper 寫到一半(`node.key` 在、`node.cert` 還沒)時 fp 變了 → `--on-join` 把半套複製進 p5,之後「只在 p5 尚無時複製」→ 半套永久。下次 fresh overlay 還原半套 → `unknown`。
- 收法:helper 在 `/etc/batman-prov/.identity.tmp/` 產完 7 檔 + `sha256` → `rename` 目錄;config-save 複製 `identity/prov/` 前驗 7 檔齊全 + sha 相符,否則不複製也不算 fp。

**M9. S10 hook `--apply-state` 若走 `halow-setkey` 會在 S10 `wifi reload`、等 20 s、並寫 p5;v2 兩處說法互相矛盾**

- §3 wireless 列:「執行期只經 `halow-setkey`;firstboot:96/99 鏈」。§2/§4.4 步驟 5:`--apply-state` = 「冪等的依狀態重設 AP/dropbear/lock」且「hook 與 helper 都只走 `--ap-off`」(§4.5)。在 S10 呼叫 `halow-setkey`:`:101` `wifi reload`(netifd 還沒起,S20)、`:134` 等 `mesh_netdev` 最多 20 s、`:147` `--save` 寫 p5 → 每次 fresh overlay 多 20 s 開機、在 S10 寫一次 p5、且 `--save` 的 `onjoin` 快取被清。
- 其實 fresh overlay 不需要 hook 碰 wireless:96 還原的 overrides 已含 placeholder(claim 時 `--ap-off --save` 寫進去的),keyguard S18 會 disable。hook 只需做 dropbear/ttylogin/lock-status(M3)與寫 `$ST/prov-state`。
- 收法:`--apply-state` 分 `--boot`(只 uci set + prov-state,不 reload、不 persist)與 runtime(經 `halow-setkey`);§3 寫清楚。

### MINOR

- **m1. dbus policy 替換要保留 root 的 `send_interface` 白名單**:上游 `bluetooth.conf` 的 `<policy user="root">` 除了 own/send `org.bluez`,還有 `GattCharacteristic1`/`GattDescriptor1`/`LEAdvertisement1`/`ObjectManager`/`Properties` 的 `send_interface` allow;節點 `system.conf:51` 預設 `<deny send_type="method_call"/>`,bluetoothd(root)呼叫 provd 物件的 `ReadValue`/`Release` 需要這些。§4.6 只寫「allow own/send org.bluez」。
- **m2. `/etc/.batman-prov-restore` 只在 fresh overlay 被 96 寫**:非 fresh 開機它是上次的值;v2 的「非 bypass」判斷 helper 必須自己讀 `/proc/cmdline`(§3 沒說);bypass 的非 fresh 開機 marker 不會變 `p5-unavailable`。另外 96 的 5 個早退點(bypass `:63`、無 p5 `:67`、非 ext4 `:71`、mount 失敗 `:89`、未 seed `:93`)各寫哪個 marker要逐一列。
- **m3. 96 還原 `prov.cbor`/`identity/prov/` 的契約缺**:只收 regular file、大小上限(例如 64 KiB)、強制 0600/0700、`v` 怎麼從 CBOR 讀(busybox shell;建議 sidecar `prov.version` 文字檔或固定前綴)、sha256 不符 → marker=? 同樣 config-save 比對 generation 也是 shell 讀 CBOR。
- **m4. overlay `prov.cbor` 壞、p5 好 → 應以 p5 重建,不是 `unknown`**:§4.4 步驟 6 只比 generation;壞檔沒有 generation。加一條「overlay 壞 + p5 可讀 → 重建」,`unknown` 只留給 p5 也不可用。
- **m5. 96 把「非 ext4 magic」一律當 image defaults(`:71`)**:v2 L1 把它映射成 `absent`(新卡)。ext4 superblock 損壞也會讀出非 53ef → 被當新卡 → 產新身分 → 之後 `--save` 失敗(`config-save:163-164` 不 mkfs)還好;但 `--seed`(操作員)會 mkfs。`absent` 只在前 4 KiB 全零時成立,否則 `p5-unavailable`。(新卡 p5 由 `build-gpt-ab-card.sh` 預先 ext4,`p5-config-partition.md:8`,所以正常新卡走 `:93` 未 seed 路徑,不是 `:71`。)
- **m6. `claimed.counter` 放在「一次寫入」的 `identity/prov/`**:`IncClaimed()` 改了 overlay 那份,p5 永遠是 0 → 跨 OTA 不單調。移進 `prov.cbor`。
- **m7. `persist(promote_lkg?)` 無授權**:被攻陷的 provd 可把未證明入網的 overrides 升成 lkg(回滾目標)。§6.3 說只在 `meshjoin_joined` 後 — 寫成 helper 自己檢查,不信 provd 的旗標。
- **m8. `seed_key_ok` 放行條件寫錯對象**:`--save` 從不呼叫 `seed_key_ok`(只有 `--seed` `:161,350`),helper 走 `--save`;放行只影響操作員 `--seed`。而且 `$ST/prov-state=claimed` 在 §4.4 步驟 4 才寫 → 若哪天 helper 用 `--seed`,步驟 3 時 prov-state 還是舊值 → 循環。明寫 helper 只用 `--save`。
- **m9. Q2 `batman-dev-open` 進 wsl 頻道**:02/04 跑的就是 wsl 頻道(1.5.12-wsl.2)。進 wsl = fleet 節點認領後**不鎖**(§6.2 第 3 點),L18 測不到鎖定;且記憶明寫「出貨判定只認 main 的 harness」、wsl 是出貨中的頻道。建議 `batman-dev-open` 只進 bench 用的 image 或由 harness 在測試前後裝/拆。
- **m10. L12 漏寫**:`claimed` 未入網的節點降級到 1.5.12 會被舊 autocommit revert 回來(`.seeded` → NEED_MESH=1),只能 `--commit` 強制;`member` 且 members==1 同樣(舊 image 無 `meshjoin_radio_up`)。
- **m11. 隨機 root 密碼只在 `claim/finish` 回應交一次**:BLE 斷在 helper commit 之後 → 擁有者有節點、沒密碼;需要 `settings/root_password`(owner auth,重設並回傳)。
- **m12. `$ST/mesh-joined` 不在 §3**;`network/leave` 要清 `mesh-joined`/`mesh-expected`(219 §7 離開網路那欄),否則降級後舊 image 仍要求 mesh。
- **m13. SD 標記檔契約**:04/02 都 `rw` 掛在 `/boot`(p1);誰刪、bypass 時是否仍執行、trial 槽上讀哪個 FAT(`batman-slot active`)、檔案內容是否要含 `device_id`(避免卡片搬到別台)。
- **m14. `unknown` 狀態「AP 關」在 `legacy` 節點不會發生**(legacy 無 prov.cbor 可壞),但 §1.4 要寫明「有 identity 無 prov.cbor」= legacy 而非 unknown,否則 wipe 中途斷電的中間態分類不清。
- **m15. `/boot` 與 `distroconfig` 的 `uart_enable=1` typo**:R28 的 ❓ 可以關了 — 節點 `enable_uart=1` 是 `miniuart-bt` overlay 讓韌體自動設的;distroconfig `[all]` 只有 `uart_enable=1`(無效鍵),改成 `enable_uart=1` 對 Pi 4 無差、對 3A+(`disable-bt`)會改變 mini UART 行為 — 等板子再動。
- **m16. 02/04 `/opt/batdata/state` 是 0755、既有檔 0644**:`$ST/prov-state` 自己 0600 即可;但 `lock-status` world-readable 既有,provd(非 root)若要讀它要列進 §3。

---

## 4. 逐 actor 小結

| Actor | v2 有擋 | 本輪發現沒擋 |
|---|---|---|
| 路人(BLE) | 匿名只 `status/public`、3 次、2 連線、無 agent、LE only | — |
| 路人 → 攻陷 provd | `net.apply` COSE、`owner.auth`、`factory_reset` 授權 | **`claim.verify` 可換 owner_pub(B3)**;首次 join 無授權(M5);`keystore.ecdh` oracle(M6);`persist --promote-lkg`(m7) |
| 本機非 root | dbus default deny、socket PEERCRED、0600 | — |
| 攻陷的容器(OTS uid 1000/999) | 只掛 `/opt/batdata/docker/volumes/*` 與 `apps/*` 檔案,碰不到 `state/`(本輪實測) | 恢復出廠時 p6 清除與容器的擁有權(B1) |
| 實體 SD | 明寫擋不住 | 前任(= 曾經的實體/root)在恢復出廠後仍有 SSH 金鑰(B1) |
| 供應鏈 | sha 釘死、無內建 CA | — |
| 我們自己 | 單寫者表、marker | 96 vs helper 兩寫者(M3);`.stage` 兩讀者(M1);legacy 閘回歸(B2);不存在的 `invalidate-other`(B1) |

---

## 5. 需要在 v3 前做的唯讀探針 / 確認

1. 02/04 的 OTS/guardian 在 p6 清除時怎麼停(#274 文件的 clean-stop 介面)→ B1。
2. `--on-join` 與 helper 交易交錯的重現腳本(M1、M8)— 可在 bench 用假 helper 做。
3. 改名探針(U5)仍 ⚠️。
4. PR-F spike(hci0、Pairable、dbus 負測試、閒置 core clock)仍是核准條件。

## 6. 判定

**REJECT(v2)**。B1(恢復出廠不是出廠、動詞不存在)、B2(fleet 失去 mesh 閘)、B3(認領可被換擁有者)都是「設計寫出來的流程在現行程式上會做出相反的結果」,不是措辭。修法都已給,不動架構;但 §4.5、§4.3/L6、§4.1、§4.4、§2/§3 的 hook 模式會一起改 → v3 整份重審(同樣兩位獨立審查)。
