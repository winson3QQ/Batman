# Design: #254 階段 1 實作 — BLE 平台、keystore、p5 `prov`、`batman-provd` 程序模型 — **v5**

狀態:v4 兩位 REJECT(A:0 BLOCKER / 7 MAJOR / 14 MINOR;B:1 BLOCKER / 7 MAJOR / 15 MINOR;`254-reviews/review-v4-{A,B}.md`,v4 全文 `254-reviews/254-stage1-impl-v4.md`)。v5 的方向是**減少機制**:恢復出廠的 p6 不再逐檔刪,改在下次開機掛載前 `mkfs`;凍結改放在 p5 的 tombstone;拿掉 S13 阻塞 init 與「先關 radio」;開機不再對帳 wireless;`claim/replay` 改成 QR 導出的 PSK(不再有匿名 NX 例外);mesh 閘改綁「arm 那次開機」的 boot_id 與「本次開機曾入網」的歷史。§13 列 v4 每條的收法。
上層:`219-field-provisioning.md` v2.8、`219-protocol.md` v0.6(本文件要求的改動見 §1.3,成為 v0.7)。本文件只定實作層介面;衝突處以本文件為準。
基準:Batman `main` f2f2bf6(= 1.5.12-wsl.2);firmware `build-3aplus` 527303e8 + `feat/254-ble` a5e181b7;02(10.41.1.1,slot B,wsl.2,無乙太網 carrier、無 BLE)、04(10.41.1.3,slot B,wsl.3 spike,OTS,乙太網在這台)。03 故障,階段 1 只做 Pi 4。

## 0. 一句話

BLE(spike 已驗)+ 非 root `batman-provd` + root `batman-provhelper`;helper 自己重算/驗證所有授權物件;**p5 是擁有權 SoT**,p5 的 prov 檔只有 `batman-config-save --prov-only` 一個寫入路徑;狀態只由 `prov.cbor.state` 決定;鎖定欄位:fresh overlay 由 96 寫(claimed/member 一律上鎖,p5 讀不到時看 p6 提示也上鎖),執行期轉換由 helper 寫;legacy(02/04)升級後 OTA 閘與今天相同;member 的 OTA 閘看「arm 前本次開機是否曾入網」,綁 arm 那次開機的 boot_id;**恢復出廠** = 凍結 → 停 payload → 作廢另一槽 → `mkfs` p5 並寫 tombstone → 清 overlay → 重開 → 下次開機在 p6 掛載前 `mkfs` p6 → 產新身分。

## 1. 決策、範圍、事實

### 1.1 使用者決策(不變)

| # | 決策 | 後果 |
|---|---|---|
| U1 | 608B 留空;之後不重工 | keystore `file`/`se` |
| U2 | Go 節點 / Flutter + Rust app / BlueZ D-Bus | 向量 + `verify.py` 裁判 |
| U3 | 擁有權與 SSH 脫鉤 | 認領不碰 `authorized_keys`;dropbear 照跑(只關密碼);**key 登入在上鎖後仍可用**(dropbear `svr-authpasswd.c:94` 的 locked 檢查只在密碼路徑,A4 實讀) |
| U4 | 恢復出廠全清含身分 | 機身 QR 失效;新 QR 經 root 取得;hostname/SSID 依 MAC 產生、跨擁有者不變(可串連,殘項) |
| U5 | 改名探針待使用者 | ⚠️ |
| U6 | 3A+ 等新板 | 共用檔(`batman-slot`、`platform-ab.sh`、`build-ab-payload.sh`、config-save、96、95、halow-setkey、autocommit、joinwatch)bcm2710 未測 |
| U7 | `uart_enable` typo 不動 | |

### 1.2 Reality check(v1–v4 R1–R61 之外新增 / 更正;2026-10-19)

| # | 事實 | 證據 |
|---|---|---|
| R38–R42 | BLE spike 事實(serdev、三模組、policy plugin、bluetoothctl 自帶 agent、p1+p3 core_freq_min、RSSI) | v3 §1.2;#254 留言 |
| R43 | fstools:`jffs2reset` 提示在 `volume_find` 之前(`jffs2reset.c:121/134`);掛載中走 PENDING + `overlay_delete`,下次開機再刪一次(`overlay.c:444-455`);`glob("%s/*")` 無 `GLOB_PERIOD` → **任何層級**的 dot 項目都不刪 | 兩位 reviewer 讀原始碼;02/04 `.cache` 實測 |
| **R62** | **busybox 沒有 `find -delete`、沒有 `-exec … {} +`**;有 `-mindepth/-maxdepth/-depth/-path/-name/-exec CMD ;/-prune`(04、02 實測 `find: unrecognized: -delete` rc=1;`.config:467,476`) | 我本次 04 實測 + 兩位 reviewer |
| **R63** | payload `metadata` 的 `version=` 是組 payload 時的 `date +%Y%m%d-%H%M%S`(`build-ab-payload.sh:69`;04 的 ota.tar.gz = `20261018-113030`),與 rootfs `BATMAN_VERSION=1.5.12-wsl.3+…` 無共同欄位;`batman-slot apply` 不保存 metadata | 我本次 04 實測 + 原始碼 |
| **R64** | `platform_check_image` 也被 `validate_firmware_image` / `sysupgrade -T` / LuCI 呼叫,既有不變式「no state file」(`platform-ab.sh:74-75`);真的升級時父程序是 `sysupgrade`(`_ab_ramroot_guard` 用 `/proc/$PPID/cmdline` 判斷) | 原始碼 |
| **R65** | joinwatch 在 `$RUNDIR/joinwatch.state` 即時寫 `JOINED <uptime> …` / `NOT_JOINED …`(`joinwatch:130,149`,tmpfs);p6 `mesh-joined` 只寫一次(首次 JOINED) | 原始碼;04 `/tmp/run/batman/joinwatch.state` 存在 |
| **R66** | `boot-reasons.log` 每次開機一行 `<ts> boot_id=<8hex> prev=…`(batdata-mount 寫);`/proc/sys/kernel/random/boot_id` 前 8 碼相同 | 04 本次:`boot_id=61327849` vs `61327849-3cb9-…` |
| **R67** | batdata-mount(`95-batman-storage` 產生)`boot()`:S11(fresh overlay 時 95 在 S10 也呼叫)**單次** mount p6,之後 `restore_payload_guardians`(`:555,725`)從 **image 範本**產生 guardian stub 並 `"$dst" running \|\| "$dst" start` → guardian 在 **S11** 就起來;`S95batman-ots-firstload` `docker load` + 啟動;95 已有「只讀掛 p5 看 `.seeded`」的 `p5_never_seeded()`(`:178-184`) | 原始碼;A4 讀 04 `/etc/rc.d` |
| **R68** | #202 的 OTA 閘:p5 是 ext4 而無 `.seeded` → `precheck-node` 與 stage 2 都 die(`batman-slot:534-547`) | 原始碼 |
| **R69** | 99-batman-chanfix:fresh slot 背景從 p5 overrides 讀頻道,最多 6 次 `uci commit; wifi reload`(`:22-57`);morse 在 regdomain 未穩時回寫硬體預設頻道(`:4-9`) | 原始碼 |
| **R70** | 04 harness 靠**空密碼** + `PasswordAuth=on` 登入(無 `authorized_keys`);02 有 1 行 lab key | 兩台實測 |
| **R71** | procd 開機階段 init 無逾時(`rcS.c:160-163` 只 stop/shutdown 15 s);busybox 無 `timeout`;`flock` 有 | A4 讀原始碼 |

### 1.3 與上層不同處(→ 協定 v0.7 / 219 v2.9)

| 上層 | 本文件 | 理由 |
|---|---|---|
| 219 §6.1 認領寫 `authorized_keys` | 不寫 | U3 |
| 219 §6.3 schema 2 | 維持 1;`prov.cbor` + `prov.meta` | `96:131` |
| 219 §7 保留身分 | 全清 | U4 |
| 219 §6.9 BLE 健康 S4 | 階段 1 就加,`ble-ok` gating | |
| 協定 §3.5 | per-verb 用 `batman-owner-op-v1` | 一標籤一格式 |
| 協定 §7.1 首版 | 需 owner-op `network/join` | |
| 協定 §5.4 | helper 重算 ClientChal | |
| 協定 §3.3 | `device_id = hex(sn)` | |
| **協定 §3.4 PSK 候選** | **加一把 `psk_replay = HKDF(claim_secret, "batman-psk-replay-v1" ‖ device_id)`**:已認領節點以常數時間試 `psk_owner[]`、`psk_member`、`psk_replay`;用 `psk_replay` 建立的 session 角色 = 「認領者候選」,只允許 `claim/replay`。**沒有匿名 NX 例外**:沒有 QR 的人第 1 則就失敗,拿不到 `node_cert`(219:267 的防追蹤要求不變) | A4-M3 / B4-M6/M7 |
| 協定 §10 共用 Rust | Go / Rust | U2 |
| v1 開發 CA | 自簽 + TOFU | |

`psk_replay` 在 608B 上的可行性:要用 `claim_secret` 槽做 HKDF/KDF(608B 有 `KDF` 指令,但槽設定能否同時允許 `CheckMac` 與 `KDF` **未查證**)→ ⚠️ 列入 #255 待查;不可行時 #255 的替代是 app 端也能導出的 `owner_tag_key`(協定 v0.8 再議)。

### 1.4 狀態機

```
legacy ──(claim + 防呆門)──▶ claimed ──(network/join)──▶ member ──(network/leave)──▶ claimed
unclaimed ─(claim)─▶ claimed
任何狀態 ──(factory reset)──▶ resetting ──(重開 2 次內完成)──▶ unclaimed(新身分)
```

| 狀態 / 判決 | AP、dropbear、lock | NEED_MESH(§6.4) | 認領 |
|---|---|---|---|
| `legacy` | 全不動(96 4b 今天規則) | 今天的規則 | 開(防呆門) |
| `unclaimed` | 不動(image 預設) | 0 | 每次開機開 |
| `claimed` | 上鎖;AP:`radio_managed=0` 不動 / `=1` 關 | live key ≠ placeholder → 今天規則;否則 0 | 只 `claim/replay`(psk_replay) |
| `member` | 上鎖;AP 由網路 | §6.4 | 同上 |
| `resetting`(p5 有 tombstone 或 p6 有 marker) | 不動(等 reset 完成) | 不適用(precheck-node 拒絕 OTA) | 無;provd 只 `status/public` |
| `unknown`(判決) | **p6 `prov-state` 最後一次寫的 state ∈ {claimed,member} → 上鎖**(fail-secure 提示,B4-m6);否則不動 | 今天的規則(p5 讀不到 → 1,fail-closed) | 無;SD 標記重置可用 |

## 2. 元件

```
手機 app ──BLE── bluetoothd(LE、無 agent、dbus root/provd)──D-Bus── batman-provd(uid provd,ujail)
                                                                        │ helper.sock(SEQPACKET,PEERCRED)
                                                                        ▼
                                                              batman-provhelper(root,procd S89)
                                                                ├─ keystore / 授權 / 交易
                                                                ├─ --boot:tombstone → 完成重置;p5↔overlay 對帳;身分;未完的轉換;SD 標記
                                                                └─ health 檔、ble-ok
platform-ab.sh platform_check_image(stage 1,只在 sysupgrade 下):寫 p6 ota-armed.mesh
95/batdata-mount boot()(S10/S11):p5 tombstone 或 p6 reset marker → p6 掛載前 mkfs
96(S10):prov 抄寫、claimed/member 上鎖
99zz(S10):fresh overlay 寫 prov-state(writer=99zz)
```

## 3. 擁有權

| 資源 | 唯一寫者 | 唯讀者 | 備註 |
|---|---|---|---|
| BLE 相關(hci0、main.conf、dbus、IRK、廣播) | 同 v4 | | |
| `$RUNDIR/batman-prov.health` | helper | autocommit | |
| `$RUNDIR/prov-txn`(`<helper_pid> <token>`) | helper:交易步驟 1 建,**步驟 4(rename)後立刻刪** | config-save `--on-join`(存在且 pid 活著 → rc 1);**`--save`/`--prov-only` 帶 `--txn <token>` 且相符 → 不讓路**;操作員 `--save` 等 ≤ 10 s | A4-M4/B4-M3 |
| `/etc/batman-prov/.txn`(overlay;`<gen_from> <gen_to> <verb>`) | helper:步驟 1 寫、步驟 4 後刪 | helper `--boot`(存在 = 上次交易被打斷 → §4.4 步驟 6 一次性對帳) | 取代 v4 的「每次開機對帳」 |
| `/etc/batman-prov/identity/`(7 檔) | helper(產生/補 persist/還原,同 v4 規則);fresh 時 96 也抄 | | |
| `/etc/batman-prov/prov.cbor`、`prov.meta` | helper;fresh 時 96 抄 | 96 4b、`--check` | |
| `/etc/batman-prov/.stage/`、`.identity.tmp/`、`ssh_keys.added` | helper | | |
| `/etc/.batman-prov-restore`(`<boot_id> <verdict> …`) | 96 | helper | |
| p5 `prov.*`、`identity/prov/` | **只有 `--prov-only`** | 96、`--prov-get`、`--check`、95(tombstone) | identity 寫到 `identity/prov.tmp/` 再 rename(B4-m8) |
| **p5 `.factory-reset`(tombstone;`<old_device_id> <uptime>`)** | `--wipe-all`(mkfs 後寫);**唯一刪者**:helper 第一次 `--prov-only --clear-tombstone`(新身分) | 95/batdata-mount、96、config-save、helper、`precheck-node` | 凍結不再只靠 p6(A4-M7/B4-m13) |
| p5 其他(`.seeded`、overrides、lkg、dropbear identity、shadow-root) | config-save 既有模式 | 96 | |
| `$ST`=`/opt/batdata/state/prov-state`(`<boot_id> <writer> <state> <members_n> <mesh_expect>`) | fresh S10:99zz(writer=99zz);S89 起:helper(writer=helper) | autocommit、96(unknown 時的上鎖提示)、`halow-status` | 絕對路徑(A4-m1);autocommit 見 writer 欄 |
| `/opt/batdata/state/ble-ok` | helper | autocommit | |
| `/opt/batdata/state/ota-armed.mesh`(`<arm_boot_id8> <target_slot> joined\|radio`) | stage 1 `platform_check_image`(**只在父程序是 sysupgrade 時**;先 `rm` 再寫,`rm` 失敗 → 拒絕 OTA) | autocommit(只接受 arm_boot_id == `boot-reasons.log` 倒數第二行的 boot_id);決策後刪 | A4-M2/B4-M1/M2/m5 |
| `/opt/batdata/state/mesh-expected`、`mesh-joined` | config-save / joinwatch(不改);helper 只在 leave 刪;恢復出廠隨 p6 mkfs 消失 | autocommit | |
| `$RUNDIR/joinwatch.lastjoined`(新;`<uptime>`) | joinwatch(JOINED tick 時覆寫,tmpfs) | stage 1 | R65 |
| `/opt/batdata/state/factory-reset.inprogress`(`<step> <old_device_id> <reason>`;`flock` 鎖這個檔本身) | helper | 95/batdata-mount(step ≥ 4 → mkfs p6)、config-save、`precheck-node`、guardian 範本 / firstload / dockerd / joinwatch init(存在 → 不啟動) | A4-m2/m11 |
| 鎖定欄位(dropbear PasswordAuth/RootPasswordAuth、ttylogin、shadow、`lock-status`) | **fresh overlay(S10):96**;**S89 起的轉換(認領、完成未完的認領):helper**。helper 判斷「未完」看**實際值**(uci + shadow),不看 `lock-status`;fresh 開機時 helper 只在 96 verdict(boot_id 相符)顯示 4b 沒跑到時才補 | `halow-status` | B4-M5 |
| `/etc/batman-dev-open` | 操作員 / harness | 96、helper | **對 claimed/member 不生效**(照鎖;已有的 `authorized_keys` 保留)。legacy/unclaimed 照今天(B4-M5) |
| live uci `wireless.*` | 執行期:`halow-setkey`(操作員、helper 交易、§4.4 步驟 6 的一次性對帳);fresh:96 Lane B、99-chanfix、morse 回寫(既有) | provd | **開機不再對帳**(A4-M5/B4-M4) |
| 另一槽 | `batman-slot`(apply、`invalidate-other`,持 `slot_lock`) | | |
| 本槽 overlay | 恢復出廠步驟 6 | | |
| p6 整個 fs(恢復出廠) | 95/batdata-mount 的 mkfs(掛載前) | | B4-B1/A4-M1 |
| SD 標記檔 | 實體;helper `--boot` 讀兩個 FAT(`batman-slot boot-devs`) | | |

## 4. 契約

### 4.1 helper socket 與授權

同 v4,以下改動:
- **`claim.replay(h, client_resp, owner_pub, owner_op)`**:只接受 **`psk_replay` session**(provd 由 `psks.get` 拿到導出值);state ∈ {claimed, member}、擁有者 1 位、`owner_pub` == 已存;CheckMac(helper 重算)**且** owner-op。成功 → 回存的 `owner_tag_key`、`adv_owner_key`,產新 root 密碼。失敗計數在 **helper**(每 boot 每小時 10 次,provd respawn 不歸零)。
- `psks.get()` 回 `{psk_owner[≤4], psk_member, psk_replay, adv_owner, adv_member}`。
- `sign.*` 額度分角色計:擁有者 / 成員 session 2/s;認領者候選(psk_replay)與匿名(unclaimed 的 NX)合計 0.5/s(B4-M7)。
- **刪除**認領回應快取(A4-m8/B4-m2):回應遺失一律走 `claim/replay`(每次換新密碼)。
- 誠實界線(同 v4):provd 看得到經過它的明文(`owner_tag_key`、root 密碼、全網 `psk_member`、`psk_replay`);換密碼趕不走持續入侵。
- trial 槽 `E_BUSY(updating)`;resetting `E_BUSY(resetting)`。
- 負測試追加:無 QR 的 central 對已認領節點做 NX / NXpsk0(錯 PSK)→ 第 1 則即斷,收到的位元組不含 `sn`/DAC(v4 會含);路人 10 Hz 連線時擁有者 NXpsk0 交握 < 2 s。

### 4.2 keystore 與身分

同 v4(7 檔、rc 表),以下改動:
- `--prov-get` 新 rc **15 = tombstone**:helper 進入「完成重置」(§4.5 R-boot),**不補 persist、不還原**。
- p5 `identity/prov/` 不完整或 sha 不符(寫到一半)→ 視同「p5 無 identity」:overlay 完整 → 補 persist(寫 `prov.tmp/` → rename 取代);overlay 也缺 → `unknown(identity-lost)`(B4-m8)。
- `--prov-get` 用 `ro`(會 replay journal);失敗才退 `ro,noload` 並標 `maybe-stale`。noload 讀到較舊的 gen 時,§4.4 步驟 7「overlay 新 → 以 overlay 為準」會自癒(A4-m7)。

### 4.3 p5 與 `batman-config-save`(PR-P1,兩板共用)

```
p5/  schema_version=1, .seeded, overrides.uci, lkg/, identity/dropbear/*, shadow-root  (不變)
     identity/prov/{7 檔}         (寫到 identity/prov.tmp/ 再 rename)
     prov.cbor, prov.meta("v=1 state=<s> gen=<n> sha=<hex64>",≤256 B,最後寫)
     .factory-reset               (tombstone,只在恢復出廠中)
```

| 模式 | 內容 |
|---|---|
| `--prov-only --prov-file f --prov-meta m [--prov-identity d] [--txn tok] [--clear-tombstone]` | 只有 helper;tombstone 存在 → 拒寫,**除非** `--clear-tombstone` 且 `--prov-identity` 給的是與 tombstone 不同 device_id 的完整新身分;寫入順序 identity → prov.cbor → prov.meta → (刪 tombstone);p5 未 seed 也可寫 |
| `--prov-get d` | rc 表 v4 + 15 |
| `--wipe-all` | **前提**:p6 marker 存在且 step = 4(否則 rc 1,B4-m15);p5 offset 0 不是 `LUKS\xba\xbe`(否則 rc 1:階段 1 不存在,#111 要改這一步);未掛載(否則 rc 8);`mkfs.ext4 -F` → 掛 rw → 寫 `.factory-reset <old_device_id>` → sync → umount。mkfs 失敗:ro 也掛不起 → rc 16 `p5-dead`;否則 rc 1 |
| `--on-join` / `--save` / `--seed` / `--if-healthy` | 不寫不比對 prov(v4);`prov-txn` 讓路(帶 token 的 helper 呼叫除外);**tombstone 或 p6 marker 存在 → rc 1** |
| `--check` | 另比 overlay/p5 `prov.meta`;tombstone → `p5 resetting`(rc 5) |
| `final_rc` 的「root 有沒有密碼」 | `root:!` 視為「已上鎖」:`--on-join` 回 0 不回 4(A4-m6) |
| 註解 / `p5-config-partition.md` | 「只有 `--seed` 會 format」改成「`--seed` 與恢復出廠的 `--wipe-all`(marker step=4、非 LUKS)」(A4-m12/B4-m15) |

`96`(PR-P1):
- 每個出口寫 verdict(含 boot_id)。
- p5 有 tombstone → verdict `resetting`,**不還原任何東西**(identity、overrides、prov、shadow),不上鎖,exit。
- prov 抄寫在 `.seeded` 檢查(`:93`)之前(v4)。
- **上鎖在每一個出口之前判斷**(A4-m5/B4-m7):
  - 讀得到 p5 `prov.meta` 且 state ∈ {claimed,member} → 上鎖;
  - p5 讀不到(`:71`、`:89`)而 p6 `prov-state` 最後的 state ∈ {claimed,member} → 上鎖(B4-m6);
  - 上鎖 = `PasswordAuth=off`、`RootPasswordAuth=off`、`ttylogin=1`、`LOCKED`,root 無 hash → `root:!`;dev-open 不豁免;
  - 其他 → 今天的 4b。

### 4.4 交易式 `state.apply`

1. helper 產 token → `$RUNDIR/prov-txn` + overlay `/etc/batman-prov/.txn`;組 `.stage/`。
2. 可失敗副作用:`halow-setkey … --no-persist`。失敗 → 反向、清 stage/txn、`E_APPLY`。
3. `--prov-only --txn tok`;rc≠0 → `--prov-get` 讀回 gen 判定。
4. rename overlay prov → **刪 `prov-txn` 與 `.txn`**。
5. 不可失敗副作用(鎖、shadow、AP)→ `--save --txn tok`(token 已失效也無妨:prov-txn 已刪,不會讓路)→ `prov-state`。
6. **開機時 `.txn` 存在**(= 步驟 1–4 間被打斷):`--prov-get` 判 p5 gen:== gen_to → 已提交,補步驟 4–5;== gen_from → 未提交:等 `meshjoin_radio_up` 或 120 s(避開 99-chanfix 與 morse 回寫的暫態)後,**一次**以 `halow-setkey`(**會 persist**)把 wireless 改回 prov 的值,刪 `.txn`。沒有 `.txn` 的開機**不對帳**(A4-M5/B4-M4)。
7. 開機 gen 比對(v4):p5 新 → 重建;overlay 新 → 以 overlay 為準重新 `--prov-only`。
8. `--apply-state`:**完成未完的轉換**看實際值(PasswordAuth/RootPasswordAuth/ttylogin/shadow),不看 `lock-status`;legacy/unclaimed 不寫;`--firstboot`(99zz)只寫 prov-state(writer=99zz)。
9. 操作員對 `radio_managed=1` 節點跑 `halow-setkey`:**照做**(現場要能改),但印警告 `this node is app-managed (member): the change is not in the network config — other members and the app still use the old value; change it from the app`;prov 不改、開機不改回。殘項:`network/update` 從 app 統一改(A4-M5 選項 2,誠實寫明會分歧)。

### 4.5 恢復出廠(重寫)

**前置條件**(任一不成立 → `E_PRECOND(reason)`;SD 路徑保留標記、log、下次開機再試):committed 槽;`slot_lock` 可取得且 tryboot 未 arm;p6 已掛且無 `batman-storage.crit`;非 bypass;p5 非 LUKS。**整個執行期部分(R1–R7)持 `slot_lock`**;`precheck-node` 見 marker 或 tombstone → 拒絕 OTA(A4-m10/B4-m10)。

| 步 | 動作(全部用 busybox 實有的指令,R62) | 失敗政策 |
|---|---|---|
| R1 | 寫 `/opt/batdata/state/factory-reset.inprogress`(step=1,flock 鎖這個檔);provd 進 resetting;`/etc/init.d/joinwatch stop`。此後 config-save 除 `--wipe-all` 外拒寫。**不關 radio、不關 AP**(A4-M7:節點在 R1–R7 間仍在網上,斷電後一切照舊可管) | — |
| R2 | 停 payload:每個 `/etc/init.d/batman-payload-*` `stop`(範本見 marker 不會被 guardian 拉回)、`/etc/init.d/dockerd stop`。**不刪 p6 的任何檔**(p6 在下次開機掛載前 mkfs) | 失敗 → log 繼續(下次開機 dockerd/guardian 見 marker 不啟動,p6 照樣 mkfs) |
| R3 | `batman-slot invalidate-other`(移到 p5 mkfs 之前,A4-m9;實作同 v4,自算 ZERO_MB) | rc 2(trial)→ 中止並撤銷(前置已擋);其他 → `reason+=other-slot-partial`,繼續 |
| R4 | marker step=4 → `batman-config-save --wipe-all`(mkfs p5 + tombstone) | rc 8 → 每 5 s 重試 12 次;仍 8 → 停在 R4,provd status `reset step=4 p5-busy`,**取消可用**(R1 撤銷:刪 marker、啟動 joinwatch/dockerd/guardian;owner-op 或 root `batman-provhelper --factory-reset-cancel`,A4-M7);rc 16 p5-dead → `reason+=p5-dead`,**繼續**(p5 讀不到 = 96 無法還原前任,下次開機是 `unknown` 但 p6 照清、新身分在 overlay 可認領);rc 1 → 停、可取消 |
| R5 | 刪 SD 標記(兩個 FAT) | 刪不掉 → log;下次開機以 device_id 比對忽略 |
| R6 | marker step=6 → `find /overlay/upper -depth -name '.*' -exec rm -rf {} \;`(dot 項目,任何層級)→ `rm -f /overlay/sysupgrade.tgz` → `jffs2reset -y`(其餘 upper 由 fstools 刪 + PENDING;**不碰 `work/`**,B4-m12) | 失敗 → log 繼續(PENDING 下次開機仍會清非 dot 項目) |
| R7 | `sync; reboot` | — |
| R-boot(下次開機) | **95/batdata-mount**(S10 fresh / S11):p6 掛載**前**看 p5 tombstone(只讀掛 p5,同 `p5_never_seeded` 寫法)或(p6 掛上後)marker step ≥ 4 → umount p6(若已掛)→ `mkfs.ext4 -F -b 4096 -L <label> -m 0` p6 → 重掛 → **不還原 guardian**(p6 已空);kmsg 一行 `factory reset: p6 reformatted`。**96**:tombstone → `resetting`、不還原。**99**:重新個人化。**helper(S89)**:`--prov-get` rc 15 → overlay 若不是 fresh(R6 之後、R7 之前斷電)→ 重做 R6–R7;fresh → 產新身分 → `--prov-only --clear-tombstone` → `prov{unclaimed}` → 窗口開 | p6 mkfs 失敗 → 95 既有的 crit 路徑(`batman-storage.crit`);tombstone 仍在 → 每次開機重試;provd status `reset p6-mkfs-failed` |

- **斷電點**:R1–R3 中(marker 在、p5/p6 未動)→ 開機 joinwatch/dockerd/guardian 不啟動,helper 從 R1 重來(全部冪等);R4 後(tombstone 在)→ 不論 p6 能不能掛,95 都會 mkfs 或 crit,96/helper 都不還原前任;R6 後 → 同 R-boot。
- **時間**:mkfs p6(27 GB,`lazy_itable_init` 預設)約 10–30 s,在 S10/S11 阻塞(R71 無逾時);寫進 release note 與 `status/public`(下次開機前看不到);⚠️ 實測待 L16。
- **結果斷言**(L16;B4-m3 更正):重開後 `info.state=unclaimed`、`device_id` 新、舊 `claim.secret` 無效(replay 也失敗)、`authorized_keys` 不存在、root shadow = image 預設、**hostname == 依 MAC 產生的預設**(與重置前同,U4 殘項)、p6 是新 fs(`tune2fs -l` 建立時間 ≥ 重置時間、無 `apps/`、`docker/` 空)、`find /overlay/upper -name '.*'` 為空、另一槽 BATMAN-BAD、`/etc/init.d/batman-payload-*` 不存在、`docker ps -a` 空、舊 SSH 金鑰被拒。
- **負對照**:(a) v2 流程上同組斷言失敗;(b) 用 v4 的 `find -delete` 寫法 → `unrecognized: -delete`、p6 不變(現況已證,R62);(c) R4 後白箱讓 p6 掛不起 → 前任 prov 不回 p5(tombstone 擋),v4 會回;(d) 白箱 p5 mkfs 失敗 → R4 走 p5-dead,兩次開機內 `unknown` + 新身分,不會永久 resetting(v4 會);(e) R4 rc 8 持續 → 停在 R4、BLE status 可答、取消後恢復原狀。
- **SD 標記**:檔名、兩個 FAT、內容 `device_id` 或 `any`;**overlay 與 p5 都沒有身分時接受任何內容**(實體持有者本來能重燒卡,A4-m4);讀檔 `head -c 64`、字元集 `[0-9a-f]` 或 `any`、只 regular file(B4-m14);由 helper `--boot` 讀(S89,不再有 S13)。

### 4.6 BLE 平台、4.7 procd、4.8 GATT

同 v4,改動:**刪除 `batman-factory-reset` S13 init**;marker 檢查加在 `payload-guardian.sh` 的 `start_service`(image 範本,B4 §1 / A4-m2)、`batman-ots-firstload` `boot()`、dockerd init(patch)、joinwatch init;§4.8 刪「匿名 NX 例外」。

## 5. 生命週期矩陣

v4 L1–L39 保留,以下改動 / 新增:

| # | 路徑 | 階段 1 後(v5) | 測試(負對照) |
|---|---|---|---|
| L5 | OTA 到本 image | + 96 每個出口前判上鎖 | `prov-lock-failsecure-254`(helper 換成 `exit 1`;另一個:白箱 96 在 `:89` exit + p6 prov-state=claimed → 仍上鎖,v4 不鎖) |
| L7 | 斷電在交易中 | `.txn` 一次性對帳,會 persist | 斷言對帳後 wireless == prov、p5 overrides == prov |
| L16 | 恢復出廠 | §4.5 v5 | 五個負對照 + 三個斷電點;位置 = Q5 |
| L31 | 單台在家更新 | stage 1:本次開機沒入網過 → `radio` → 只要 radio_up → commit | (3) |
| L34 | 認領回應遺失 | psk_replay session + `claim/replay` | 無 QR → 第 1 則失敗;錯 owner_pub → `E_FORBIDDEN` |
| L35–L37 | reset 前置 / p6 / 步驟失敗 | §4.5 v5 | (c)(d)(e) |
| **L40** | **team OTA**(兩台 member 依序) | 第二台 stage 1 看 `joinwatch.lastjoined`(本次開機曾 JOINED)→ `joined` → 要求鄰居 | 負對照:A 在 trial 時 B 跑 stage 1,B 的 image 預設頻道改掉 → B 必須 revert(v4 commit,B4-M2) |
| **L41** | **`sysupgrade -T` / LuCI validate** | 不寫 `ota-armed.mesh`(父程序不是 sysupgrade) | `-T` 後檔案不存在 |
| **L42** | **直接 `batman-slot apply`**(ab-selftest) | 無檔 → member 要求鄰居(fail-closed);bench 寫明 | 無檔時 member trial 要求鄰居 |
| **L43** | **operator `batman-slot commit` / stage 2 拒寫** | 留下的 `ota-armed.mesh` 綁的是 arm 那次的 boot_id,下一次 trial 的「上一次開機」不同 → 無效 | 舊檔不影響下一次 trial |
| **L44** | **unclaimed / 重置後 OTA** | #202 閘 prov-aware:p5 `prov.meta` state=unclaimed → 不擋(A4-M6) | unclaimed `sysupgrade -n` 進 trial 並 commit(v4 被 `not seeded` 拒) |
| **L45** | **恢復出廠中 OTA** | `precheck-node` 見 marker / tombstone 拒絕 | |
| **L46** | **dropbear 重啟** | `meshjoin_reachable` 暫時假 → JOIN_NEED 取樣涵蓋;不改 | 既有 |
| **L47** | **認領測試後 harness 存取 04**(B4-M5) | 上鎖後 key 登入仍可用(U3);**前置:先在 04 裝 lab key**(副作用:04 從「空密碼可登入」變「只有 key」,還原 = 刪那行 + 恢復出廠或保持) | Q6 |
| L12 | 降級到 1.5.12 | 補:claimed 節點降級後舊 96 對「無 key 有密碼」判 UNPROVISIONED、`ttylogin` 預設 0 → **serial 給 root shell**(fail-open,實體威脅;A4-m14) | |

## 6. 流程

### 6.1 認領
同 v4 步驟 1–6,但**無回應快取**;步驟 4 的 `--save` 帶 token、在 prov-txn 刪除之後(§4.4 步驟 4–5)。回應遺失 → `claim/replay`(psk_replay)。legacy 防呆門與誠實界線同 v4。

### 6.2 鎖定
同 v4;`/etc/batman-dev-open` 對 claimed/member 不生效;已存在的 `authorized_keys` 保留 → harness 以 lab key 進入(Q6)。

### 6.3 建網 / 加入
同 v4。

### 6.4 autocommit

**stage 1 寫 `ota-armed.mesh`**:`platform_check_image` 在 `precheck-node` 通過後,**只在父程序是 `sysupgrade`**:`rm -f` 舊檔(失敗 → 拒絕 OTA)→ `m=radio`;`$RUNDIR/joinwatch.lastjoined` 存在(本次開機曾 JOINED,R65)或當下 `meshjoin_joined` → `m=joined` → 寫 `<boot_id 前 8 碼> <batman-slot target> <m>`(tmp + rename,0600)。

**trial 讀**:`ota-armed.mesh` 的 boot_id == `boot-reasons.log` 倒數第二行(= arm 的那次開機)**且** slot == 本 trial 的 slot → 採用;否則(缺、不符、壞)→ `joined`(fail-closed)。

`expected_in_mesh()`(讀 `prov-state`;fresh trial 上 writer=99zz → 等 ≤ 60 s 至 writer=helper,仍無 → 用 99zz 的值;boot_id 不符 → 今天的規則,B4-m9):

| state | NEED_MESH | 鄰居要求 |
|---|---|---|
| 無檔 / `legacy` / `unknown` | 今天的規則 | 今天的規則 |
| `unclaimed`;`claimed`+placeholder | 0 | — |
| `claimed`+live key | 今天的規則 | 今天的規則 |
| `member` | `meshjoin_radio_up` | `ota-armed.mesh` 採用且 = `radio` → 不要求;否則 `meshjoin_reachable` ≥ JOIN_NEED |

`health_ok()`、`ble-ok` 同 v4。`ota-armed.mesh` 在 autocommit 決策後刪(殘留無害:boot_id 綁定)。

**負對照**(更正 B4-m4):(1) 04 legacy OTA 到 `radio1.disabled=1` → revert;(2) **claimed+placeholder**(unclaimed 認領後、`--save` 已 seed)OTA → commit(1.5.12 `.seeded` → NEED_MESH=1 → revert);(3) member 單台、本次開機未入網 → commit;(4) member 有鄰居 OTA 到改頻道的 trial → revert;(5) 刪掉 `ota-armed.mesh` → 要求鄰居;(6) `-T` 後直接 apply → 要求鄰居;(7) team OTA(L40);(8) BLE `ble-ok` 兩項;(9) provd 被反覆 kill → 不 revert。

### 6.5 診斷、6.6 改名
同 v4。

## 7. 依賴與證據(v4 D1–D25 保留,以下改動)

| # | 依賴 | 證據 | 狀態 |
|---|---|---|---|
| **D26(更正)** | busybox `find`:`-depth`、`-name`、`-exec CMD ;` 可用;**`-delete` 不可用** | R62(04 實測) | ✅ |
| D27 | `/proc/$PPID/cmdline` 含 `sysupgrade` 可區分真的升級 | `platform-ab.sh` `_ab_ramroot_guard` 既有用法 | ✅ 原始碼 |
| D28 | `boot-reasons.log` 倒數第二行 = 上一次開機 | R66;batdata-mount 每次開機寫一行 | ✅;⚠️ fresh trial 上 batdata-mount 寫本次那行的時點 < autocommit(S99)要實證 |
| D29 | 95/batdata-mount 在 p6 掛載前可只讀掛 p5 | `95-batman-storage:178-184` 既有 `p5_never_seeded` | ✅ |
| D30 | `mkfs.ext4` 27 GB p6 的時間 | 未量 | ⚠️ L16 |
| D31 | 608B 槽可同時 `CheckMac` 與 `KDF`(psk_replay) | 未查 | ⚠️ #255 |
| D32 | `dockerd stop` 卸掉 `/opt/batdata/docker` 的 bind | 未驗;不再依賴(p6 在下次開機掛載前 mkfs) | 不適用 |

## 8. 安全(v4 表保留,改動列)

| Actor | 攻擊 | 擋法 | 負測試 |
|---|---|---|---|
| BLE 路人 | 對已認領節點拿 `node_cert` 追蹤 | **無匿名 NX 例外**;psk_replay 需 QR | §4.1 |
| BLE 路人 | 吃滿簽章額度 | 角色分開計 | §4.1 |
| 前任擁有者 | p6 殘留 / dot 檔 / 凍結失效 | p6 掛載前 mkfs;tombstone 在 p5 | L16 (b)(c) |
| 只持 QR 的人 | replay 換擁有者 | 需擁有者私鑰 | L34 |
| 實體 SD | 放標記重置 / 改 FAT 內容攻擊 helper 解析 | device_id 比對;`head -c 64`、字元集、regular file | L16 |
| 我們自己 | fail-open 在 p5 讀不到 | 96 用 p6 prov-state 提示上鎖 | L5 |

## 9. 測試

同 v4;追加:L40–L47;所有用到的指令先上機 `command -v` / `--help` 驗證(R62 教訓)→ PR-P1 加 tier-A `prov-tools-254`(斷言 busybox 有 `find -depth -exec`、`mkfs.ext4`、`flock`、`jffs2reset`;缺 → FAIL)。

## 10. 實作切法
同 v4;PR-P1 追加:95/batdata-mount(tombstone/marker → mkfs p6)、`build-ab-payload.sh` 不需改(綁 boot_id,不綁版本)、payload-guardian 範本 + firstload + dockerd init 的 marker 檢查;刪 S13 init。

## 11. 殘項
v4 殘項 + `network/update` 從 app 統一改頻道(操作員 setkey 會分歧);D28/D30/D31 實證;hostname/SSID 跨擁有者可串連(U4)。

## 12. 待決

| # | 題 | 建議 |
|---|---|---|
| Q1–Q4 | 同 v4 | 定案 |
| Q5 | L16 位置與還原 | 02 升 BLE build + p1/p3;L16 期間乙太網線移到 02;還原經乙太網 |
| **Q6** | **任何 BLE 認領測試都會把 04 上鎖**(04 現在靠空密碼給 harness 登入) | 認領測試前在 04 裝一把 lab key(上鎖後 key 登入仍可用);副作用:04 之後只接受 key;**需使用者同意** |

## 13. v4 審查 → v5 對應

| v4 發現 | 收法 |
|---|---|
| B4-B1 / A4-M1 `find -delete` 不存在、p6「繼續」吞資料 | p6 改在下次開機掛載前 mkfs(不逐檔刪);overlay dot 用 `find -depth -name '.*' -exec rm -rf {} \;`;R62/D26 實測;`prov-tools-254` |
| A4-M2 / B4-M1 version 比不上、陳舊值 | 綁 arm 開機 boot_id + slot;只在 sysupgrade 下寫;先 rm |
| B4-M2 單次取樣 | `joinwatch.lastjoined`(本次開機曾入網) |
| A4-M3 / B4-M6 匿名 NX 洩漏身分 | psk_replay;無匿名例外 |
| B4-M7 replay DoS | helper 計數;簽章額度分角色 |
| A4-M4 / B4-M3 prov-txn 自擋 | rename 後即刪;token 豁免 |
| A4-M5 / B4-M4 wireless 對帳 | 開機不對帳;只在 `.txn` 殘留時一次性、等 radio 穩定、會 persist;操作員 setkey 照做 + 警告 |
| A4-M6 #202 閘 | prov-aware;L44 |
| A4-M7 永久 resetting / 凍結只在 p6 | 不先關 radio;tombstone 在 p5;p5-dead 繼續;取消出口 |
| B4-M5 鎖定寫者 / dev-open / harness | 看實際值;dev-open 對 claimed/member 不生效;Q6 |
| A4-m1 / B4-m1 路徑 | 絕對路徑 |
| A4-m2 guardian S11 / firstload | 檢查放範本 + firstload + dockerd |
| A4-m3 / B4-m11 S13 全暗 | 刪 S13;只剩 S10/S11 的 mkfs p6(時間寫明) |
| A4-m4 SD 無身分 | 無身分時接受 |
| A4-m5 / B4-m7 4b 位置 | 每個出口前判 |
| A4-m6 `root:!` rc 4 / dev-open | `final_rc` 視為上鎖;dev-open 不豁免 |
| A4-m7 noload | `ro` 優先 + 自癒 |
| A4-m8 / B4-m2 快取 | 刪除 |
| A4-m9 作廢順序 | R3 在 R4 前 |
| A4-m10 / B4-m10 reset 中 OTA | 持 slot_lock + precheck 拒 |
| A4-m11 flock / state 殘留 | flock 鎖 marker;p6 mkfs |
| A4-m12 / B4-m15 mkfs 規則 | 註解與文件同步;LUKS 判定;marker step=4 前提 |
| A4-m13 矩陣缺列 | L41–L46 |
| A4-m14 降級 serial | L12 |
| B4-m3 L16 斷言 | 更正 |
| B4-m4 負對照 (2) | 改 claimed+placeholder |
| B4-m5 validate 寫狀態 | 只在 sysupgrade 下 |
| B4-m6 unknown 開放 | p6 prov-state 提示上鎖 |
| B4-m8 identity 半寫 | `prov.tmp` rename;不完整 = 無 |
| B4-m9 prov-state 改判 | writer 欄;等 helper |
| B4-m12 刪 work | 不碰 work |
| B4-m13 p6 不在凍結失效 | tombstone |
| B4-m14 FAT 解析 | 長度、字元集 |
