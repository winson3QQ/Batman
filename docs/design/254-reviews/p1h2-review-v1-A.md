# 審查 A:`254-p1-impl.md` v1(PR-P1 + PR-H2)

審查者 A,2026-10-21。範圍:整份設計,對照上層 `254-stage1-impl.md` v19、`254-h1-harness.md` v8、main f1a1122 原始碼、02 / 04 唯讀實查。
**判定:REJECT**:2 BLOCKER / 10 MAJOR / 16 MINOR。

## 0. 我自己查到的證據(唯讀)

| # | 事實 | 證據 |
|---|---|---|
| R1 | **02 沒有乙太網**(`eth0 carrier=0`),04 有(`carrier=1`) | 02 / 04 `cat /sys/class/net/eth0/carrier` |
| R2 | #202 閘的註解原文:未 seed 的 p5 → fresh slot 開成 UNPROVISIONED(沒有 mesh key),「on a mesh-only node (no ethernet) that strands it unrecoverably」;可以覆寫:`/tmp/batman-slot.allow-unseeded` | `batman-slot:528-551` |
| R3 | keyguard:mesh key = placeholder → `wireless.<radio>.disabled=1` | `init.d/halow-keyguard:22-30` |
| R4 | autocommit 今天的 `expected_in_mesh` 先看 p6 `mesh-joined` / `mesh-expected`(02 / 04 都有) | `batman-autocommit:388-396`;節點 `ls /opt/batdata/state` |
| R5 | fresh overlay 上 p6 由 95 在 S10 自己掛起(`"$INIT" boot`,第 5 步),所以 96 讀 p6 `prov-state` 的前提成立 | `95-batman-storage` 結尾 |
| R6 | `lock-status` 在 p6 `/opt/batdata/state/lock-status`,只有 96 寫;02 / 04 目前都是 `UNPROVISIONED`;`ttylogin=0` | `96:161`;節點 |
| R7 | H1 的 run 目錄:`/tmp/run/batman-dv` 是 root `drwx------` | 02 / 04 `ls -ld` |
| R8 | busybox `start-stop-daemon` 支援 `-c USER[:GRP]`;節點上還沒有 `provd` 使用者;已有的 uid:network 101、ntp 123、dnsmasq 453、logd 514、docker 32768、nobody 65534 | 02 / 04 |
| R9 | config-save 只准 root 執行(`:54`),`DEV=/dev/mmcblk0p5` 寫死(`:28`);joinwatch 在每個 JOINED tick 呼叫 `--on-join`(`joinwatch:145`);每個寫入模式最後都寫 `.seeded`(`:397`) | 原始碼 |
| R10 | `f2f2bf6..main` 在 `feed/` 與 `deploy/` 沒有任何差異 → 改 pin 不會夾帶其他產品改動(F11 的擔心不成立,好事) | `git diff --stat f2f2bf6 HEAD -- feed/ deploy/` 為空 |
| R11 | **#254 留言 6292759637 / 6296766607**:04 重開 3 次有 1 次 hci0 初始化逾時,一直到重開才恢復;02 在運行中卡死,bluetoothd restart 救不回 | `gh api …/comments/…` |
| R12 | 04 的 OTS payload init(`batman-payload-opentakserver`)放在 **overlay upper** 的 `/etc/init.d`;docker data-root = `/opt/batdata/docker`(p6) | 04 `ls /overlay/upper/etc/init.d`、`docker info` |
| R13 | `.github/workflows/ab-shared-change.yml`:PR 動到 96 / config-save / autocommit / joinwatch / meshjoin.sh / platform-ab / batman-slot 時,PR body 必須有 `### bcm2711` 與 `### bcm2710` 兩段 | 讀檔 |
| R14 | 向量有 `owner_op`、`op_nonce`、`claim_checkmac`、`claim_replay`、`cose`、`psk_replay` 等段 → provclient 的獨立性可以用向量證明 | `vectors.json` 的頂層 key |
| R15 | `golang-package.mk` 支援 `GO_PKG_TAGS`(`:106,260`) | 讀檔 |

---

## BLOCKER

### B1. `prov-firstboot-254`、`prov-bypass-254`(還有 `prov-gate-254` 如果放在 02)放在 02 跑,會讓 02 卡在現場救不回;而且照寫的步驟根本跑不起來
- **情境(firstboot)**:02 的 p5 被 `mkfs.ext4` 成未 seed → OTA。(a) **#202 閘會擋下這次 OTA**(R2:p5 是 ext4、沒有 `.seeded` → `precheck-node` 與 stage 2 都會 die);P1 的閘改成看 prov,但 mkfs 之後**沒有 `prov.meta`**,照樣擋。所以照寫的流程在 wsl.9(負對照)和 P1 都進不了 trial。(b) 就算加了 `allow-unseeded` 覆寫:fresh overlay → 96 在 `:93` 出口 → 套 image 預設 → mesh key = `CHANGE-ME-NOW` → keyguard 關掉 HaLow radio(R3)→ 02 沒有乙太網(R1)、99zz 又把 AP 關了 → **02 完全連不到**。(c) 在 P1 上,unclaimed 的 NEED_MESH = 0(上層 §6.4)→ autocommit **commit** 這個 fresh 槽 → 02 committed 停在沒有 mesh 的設定 → 要「p5 映像寫回、rollback」都得先 ssh 得到 02,這做不到 → 只能實體處理(serial / 讀卡機)。這正是 #202 閘要防的事,也是使用者「不要浪費我的錢」的那一類。
- **情境(bypass)**:`batman_bypass=1` → 96 在 `:64` exit 1 → fresh overlay 停在 image 預設 → mesh 被 keyguard 關 → 02 在 trial 期間連不到,`unknown(bypass)`、「persist 拒」都讀不到;唯一的出路是靠 autocommit 到時限 revert(R4:p6 有 `mesh-expected` → NEED_MESH = 1)。這樣測項什麼都觀察不到(= 沒有效果的測試,違反 P-U4「測就要有效果」)。
- **情境(gate)**:`prov-gate-254` 的 unclaimed 節點 `sysupgrade -n` → fresh 槽 unseeded → 一樣的路徑(mesh 關、NEED_MESH = 0 → commit)。放在 02 = 卡死。
- **修正**:三個測項都只准在 **04**(DNODE,有乙太網)上跑,preflight 要斷言 `BLE_PERIPH/DNODE eth0 carrier = 1`;寫清楚 fresh image 預設下 04 的乙太網怎麼連得到(位址 / mDNS;⚠️ 要先唯讀查清楚,不能假設),連不到時就不能執行(FAIL)。trial 一律用 **hold-commit**(H1 N3 的做法,版本 = 受測版本)不讓它 commit,並寫明 trial 時限到了 revert 的上限時間;#202 覆寫的檔案由測項自己建、自己刪,放在 lease 的擁有權表裡。P-U4 寫的是「真機」,沒有指定要 02,改到 04 不違反使用者決定;如果作者認為一定要 02,必須先問使用者,並附「02 會卡死」的證據。

### B2. 會改 mesh 的測項(`prov-netjoin-254`、`prov-powerloss-254`、`prov-netupdate-254`、autocommit (4)(7))沒有定義 `net_config` 的值,也沒有「維持連得到」與「還原」的計畫
- **情境**:§3 寫「測試金鑰全部來自公開的協定向量」。照字面做,`net.apply` 套的就是向量裡的 `net_config` / `net_secrets`:mesh key 公開、mesh_id / 頻道和 fleet 不一樣。02 只靠 mesh 連(R1)→ 02 先套用就離開 fleet mesh;04 後套用或套用失敗 → 02 卡死。兩台都套用成功 → fleet 跑在一把**公開的** mesh PSK 上。`prov-reset-legacy`(§4.4)**不還原 wireless / p5 overrides**(只刪 prov、還原 dropbear 與 shadow)→ 跑完之後 fleet 一直留在測試網路。powerloss 是在 `net.apply` 進行中 `reboot -f`,半套用的狀態要靠 `.txn` 對帳——如果對帳本身有 bug(這就是受測對象),02 會卡死。
- **還缺**:兩台的套用順序(先 02 再 04,還是相反;中間 02 連不連得到)、失敗時的救援路徑、真的 fleet mesh key 如果要拿來當測試值,它從哪裡來(要從節點讀出來 → 秘密會出現在主機與 log)、以及「值沒變 → 判讀變成只是存在檢查」的取捨。
- **修正**:定一個測試用的 `net_config`:用 fleet 的實際值(mesh_id、頻道、key),只改一個無害、但讀得出來的欄位(例如網路名稱 / 版本號);或者只在 04 上套,改用一個 04 自己就能證明的欄位。秘密以 `net_secrets` 加密給節點 ECDH,主機上只放 0600 暫存檔、不進 log。`prov-reset-legacy` 要加一步「wireless / overrides 還原成測試前的快照」,並且斷言「02 在 `batctl n` 裡看得到 04」。每個測項都要寫副作用與還原清單(使用者 2026-10-18 規則)。

---

## MAJOR

### M1. provclient 以 provd uid 執行時,讀不到放在 root 0700 目錄下的檔案
§4.3 把 provclient 放在 `/tmp/run/batman-dv/bt/<run_id>/`;這個目錄與它的父目錄都是 root 0700(R7)→ `start-stop-daemon -c provd` 執行時,在目錄路徑上就 `EACCES`。實作的人很可能順手把 `bt/` 改成 0755,這會打破 H1 §3 / §7 的 tmp-trust 前提。**修正**:另開一個 root 擁有、0755 的 `…/<run_id>/pc/`,provclient 本身 root 0755(provd 可以執行,但不能寫);執行前驗 owner、不是 symlink、link count 1、sha256;tmp-trust allowlist 加這一條;負測試:預先建一個 provd 可寫的檔或 symlink → 拒絕執行。

### M2. `prov-reset-legacy` 違反擁有權,而且還原不完整;§4.4 自己的斷言會 FAIL
- 上層 §3:p5 的 prov 檔「**只有** `--prov-only`」能寫,`identity/prov/` 是一次寫入。reset 直接刪,成了第二個寫者,而且沒有拿 config-save 的鎖(`mkdir $RUNDIR/cfgsave.lock`)。joinwatch 每個 JOINED tick 都會以 rw 掛 p5 跑 `--on-join`(R9)→ 兩邊會撞在一起(EBUSY,或者刪到一半時被 `--on-join` 讀走)。
- 漏了要還原的東西:`lock-status`(p6;認領後是 LOCKED;legacy 的 helper 不寫鎖定欄位(上層 §4.4 第 8 點)→ 斷言「lock-status 與測試前相同」**必然 FAIL**,R6);p6 `prov-state`(`last_known_state=claimed` 留著 → 之後任何一次 fresh overlay、只要 p5 讀不到,96 就會上鎖)、`ble-ok`、`ota-armed.mesh`、`mesh-expected` / `mesh-joined`(`network/leave` 時 helper 會刪)、wireless(B2)、`authorized_keys` 裡 `ssh_keys.set` 加的行(若有測);刪掉 overlay `/etc/batman-prov/` 會連 `ssh_keys.added` 一起刪,之後就沒人知道是哪幾行)。
- 備份 `/opt/batdata/dv-prov-backup/`:誰建、什麼時候建、綁哪一個 run_id 與 boot_id、過期的備份(上一次 run 留下的)會不會被套回去、備份不存在時怎麼辦(必須 fail-closed,不能還原成 image 預設)。
- **修正**:reset 一律在 config-save 的鎖內做(或者在 config-save 加一個只給測試用、需要 root 的 `--prov-wipe-for-test` 模式,讓唯一寫者還是 config-save,並列進擁有權表);還原清單補齊上面每一項,而且每一項都有斷言;備份檔帶 run_id、boot_id、sha,不符就拒絕;§3 把 reset 列為測試期間 p5 prov 與 p6 state 的第二個寫者,並寫明理由。

### M3. lease / deadman 撐不過重開,但幾乎每個 tier B 測項都會重開
lease、deadman、標記都在 tmpfs(H1 §5「節點重開 → tmpfs 清空」);H1 規定 lease 的 boot_id 不是本次開機就「視為作廢,可以接手」。prov 的 tier B 測項(OTA、`reboot -f`、`prov-reset-legacy` 本身)都會重開 → 重開之後節點是 claimed / member,而 deadman 已經消失 → harness 這時候死掉,沒有人會 reset。節點會停在一個**擁有者私鑰公開**的 claimed 狀態。P1 還沒有 BLE,所以暫時打不進來;但操作員之後 OTA 到 P2,任何人都能以擁有者身分操作。preflight P3 只擋下一次 validation,擋不住操作員 OTA。**修正**:在 p6 放一個持久標記 `/opt/batdata/state/dv-prov-active`(run_id、測項、開始時的 boot_id;root 0600),開機後由 harness 或節點端的 deadman(用 procd 一次性服務,或下一次 `acquire`)接手。preflight 與 `halow-status` 看到這個標記,或看到 `owner_pub` == 向量的測試金鑰 → FAIL 或顯示警告。設計 §6 補「節點重開後 harness 死掉」這條路徑,並附白箱測試。

### M4. 白箱負對照在節點上怎麼做沒有定義:Go 二進位與 96 都在唯讀 rootfs 裡
§5 的白箱是「在 P1 rc 上換掉一行或一個函式」,但 helper 是編譯過的 Go、96 在 fresh 槽的 squashfs 裡。各測項需要的東西:
- `prov-sock`(不檢查 PEERCRED)、`prov-claim`(不重算 ClientChal)、`prov-trial-busy`、`prov-legacy-upgrade`(rc 9 → unclaimed)、`prov-powerloss`(`PROV_TEST_KILLPOINT` test build):要一支**換過的 helper 二進位**放到節點上;
- `prov-lock-failsecure`:要一個「helper = `exit 1`」的**完整 image**,還要讓 96 在 `:89` 出口(fresh 槽上要怎麼讓 p5 mount 失敗?弄壞 p5 superblock 等於毀掉 SoT)。

這些都沒說:檔案放哪裡、誰擁有、怎麼保證不會留下來。如果寫進 overlay `/usr/bin/batman-provhelper`,它會撐過重開。harness 死掉時,04 就留著一支「不檢查 SO_PEERCRED」的 root helper,這是 fail-open。特製 image 有版本號,會不會被當成出貨品、會不會進轉賣工具清單,也都沒說。killpoint 怎麼啟動也沒說:procd 服務的環境變數從哪裡來?如果由 init script 讀某個檔,那個 seam 就存在於 release 的 init script 裡。
- **修正**:換過的二進位一律用 **tmpfs bind mount** 蓋在 `/usr/bin/batman-provhelper` 上(重開就消失)。這樣 `reboot -f` 之後由**出貨的** helper 做 `--boot` 對帳,測的才是出貨品。由 lease 擁有,deadman 的還原動作是 `umount` + 重啟 helper。killpoint 只讀 test build 才有的 0600 root 檔,不經環境變數,release 的 init 不改。特製 image 的版本號加 `-negctl` 後綴,發行清單與 preflight P3 都拒收。`:89` 的注入方式寫清楚,例如 test build 的 96 放在特製 image 裡讀 cmdline token;或者承認這一項只能用單元測試證明。「release 二進位不含 killpoint 字串」要在**組好的 rootfs** 上檢查(同 PR-F 閘門),不是在 CI 自己 build 的那一份上。

### M5. 負對照的鑑別力不夠,有些判讀只是存在或缺席檢查
1. **「wsl.9 FAIL」對每一項都只是「no helper」**:它只證明測項不會在沒有二進位時空過,分不出每一項的契約。真正的鑑別力在白箱,而 `prov-ota`、`prov-netupdate`、`prov-overlay-corrupt/-wipe`、`prov-downgrade` 的白箱寫「—」→ 這幾項沒有負對照,違反 §5 表頭自己的規則與使用者規則。建議的負對照:ota → 新槽的 96 不抄 prov(mutant)→ gen / state 不符;netupdate → `--on-join` 不讓路(mutant)→ p5 gen 前進;overlay-corrupt → helper 不比 gen → state 錯;overlay-wipe → 96 不抄 prov → `device_id` 變了。
2. **`prov-unit-96-lock` 只測純函式**:最可能的 bug 是「某個出口忘了呼叫,或傳錯參數」(例如 `:67` 忘了呼叫,或 `p6_last_known` 在 p6 沒掛時沒填成 unknown),純函式測不到。上層 §4.3 要求的是「96 對每個出口」。**修正**:加一個整合測試,在 fake root 上真跑 96(要給 96 加 `BATMAN_P5_DEV` / `MNT` / `CMDLINE` / `STATE` 的 seam,同 config-save,root 限定),每個出口 × prov 狀態都斷言 dropbear uci、ttylogin、lock-status。mutant 至少三個:meta 壞 → UNLOCK;p6 claimed → UNLOCK;dev-open 豁免 claimed。
3. **`--prov-only` 的寫入順序(identity → cbor → meta 最後)怎麼判讀沒有寫**:輸出結果分不出順序。**修正**:用小容量 loop fs 讓第 k 次寫入 ENOSPC,或者在每次寫入前加一個 hook;斷言「meta 不存在,或者 meta 對應的是舊 gen」;mutant:先寫 meta → FAIL。
4. **`prov-boot-254`「沒有 `wifi reload` log」**:logread ring 128 KiB 會輪掉(H1 E13),log 是空的就判 PASS,這是「找不到東西就判 PASS」。**修正**:只有在 `logread` 第一行的時間 ≤ 本次開機時間時才判定,否則 FAIL;或者改讀 99-chanfix / netifd 寫在 p6 的計數。
5. **`prov-downgrade-254` 寫「照實記錄」**:沒有 PASS 條件,不是測試。上層 L12 列了可以斷言的行為(舊 96 還原 overrides / identity / shadow;authorized_keys 有行時 LOCKED;claimed 未入網會被 revert;p5 的 prov 檔不刪)。而且 rollback 到一個**非 fresh** 的 wsl.9 槽,96 不會跑,測不到 L12;要 OTA wsl.9 payload 進 fresh overlay。
6. **`prov-gate-254` 的模擬方法錯了**:`prov-reset-legacy` 之後 helper 走 rc 9 → `prov{legacy}`,不是 unclaimed;再刪 `.seeded` 之後,`prov.meta` state 仍是 legacy → 新閘照樣擋 → 這個測項依設計就會 FAIL。另外 joinwatch 下一個 JOINED tick 跑 `--on-join` 會**重新寫回 `.seeded`**(R9)→ 兩邊會撞在一起。要拿到 unclaimed,得走 rc 7(p5 未 seed、沒有 prov)。這又回到 B1(只能在 04)。

### M6. 跟上層比,P1 該有的測項缺了不少(P-U3 說 helper 要做全部動詞)
H2 的表沒有涵蓋下列項目,這些都是 P1 會出貨的 root 程式碼:
- **上層 §4.1 的負測試**:owner-op 的 `nonce_helper` 只能用一次且 60 s 過期(同一個 owner-op 送兩次 → `E_FORBIDDEN`;這是重放防護的核心);`args_hash` 綁定(拿 verb A 的 owner-op 配不同的 args → `E_FORBIDDEN`);嚴格解碼(重複 key、非 deterministic 編碼 → `E_SCHEMA`;這是「被攻陷的 provd 拿 parser 差異搞混 helper」的主要防線);請求 > 64 KiB;30 s 逾時;第二條連線要排隊;`sign.*` 的額度;`claim.replay` 每小時 10 次的失敗計數;legacy 防呆門(沒有 key 也沒有 dev-open → `E_UNSUPPORTED(no-ssh-key)`,上層 L18 白箱);`net.apply` 用上一版 `admins` 驗鏈(跳號、降版)。
- **動詞的正向與負向**:`ssh_keys.set`(regex、CR / LF、≤ 8 行、只動 `ssh_keys.added`)、`root_password.reset`、`diag.bundle`(fd、讀完就刪)、`network/leave`(刪 `mesh-expected` / `mesh-joined`,L22)、helper CLI `qr`(claimed 拒絕;legacy 只在 dev-open 或實體 console 時給,不收 `pts`。這是「連上 legacy AP → SSH → 偷 QR」那條路的防線)。
- **health 欄位的正確性**(上層 §10 第 4 點明列 P1):`privacy` / `sc` / `sc_file` / `bondable` 要對得上實際狀態。負對照:H1 N1(關 privacy)→ 15 s 內 `privacy=0`;停掉 bluetoothd → `bluetoothd=0`;`batman-sc` 的 boot_id 或 pid 不符 → `sc_file=0`。§4.3 只檢查「格式與 ≤ 60 s」,這是存在檢查。
- **`ble-ok` 寫入條件**:02 的 p3 沒有 `core_freq_min`(H1 E22)→ 02 絕對不能有 `ble-ok`。這是 fleet 上現成的負對照,不要浪費。
- `halow-setkey --no-persist` 不得呼叫 `--save`(交易回滾靠它);`meshjoin_radio_up`;`P5_STALE_HINT` 文字;helper 重啟(L11:socket 重建、殘留 socket 清掉、health 恢復);socket 目錄被預先建成 symlink 或別人擁有時拒絕(上層 §8「預建 socket 目錄」);L25 後半段(步驟 3–4 之間 `reboot -f` → state=claimed);L34「persist 之後、回應之前 crash」;L38(writer=99zz 等 60 s);L42 / L43 / L51 / L61 的白箱;「我們自己」那一列的 `logread | grep -c <secret>` = 0;`/etc/batman-prov` 不在 `keep.d`、不在 conffiles(`sysupgrade -b` 備份不能帶走身分私鑰)。
- **修正**:§5 加一張「上層 §4.1 負測試 / §5 各列 / §8 各列 → H2 測項」的對照表,每一列都要有歸屬(H2 測項、留給 H3,或標 N/A 並寫理由)。

### M7. tier A 的 `prov-sock-254` 每天在正式 fleet 上送會改狀態的動詞
錯的 owner-op、錯的 `owner_pub`、`net.apply` 首版缺 owner-op……這些「預期被拒」的請求,只要 helper 有回歸,就會**真的生效**(節點被向量金鑰認領,或 mesh 被改掉;02 會卡死,見 B2)。tier A 沒有 lease、沒有 reset。這是 fail-open 的測試設計。**修正**:tier A 只送唯讀動詞(`info.*`、`nonce`)與不會改狀態的 schema 錯誤(未知動詞、`keystore.ecdh`、`persist`);所有會改狀態動詞的負測試都移到 tier B,在 lease + reset 之內做;或者在 tier A 先讓節點進入 helper 一定會拒絕的狀態,但那等於另一個 seam,不建議。

### M8. PR 順序與 #290 衝突:H2 先 merge,但測項依賴還不在 main 的產品碼;preflight 在 wsl.9 上沒有定義
- `prov-unit-helper-boot` 寫「放在 P1 的 Go module,由 harness 的 CI job 執行」。這等於**測項放在產品路徑**,產品 PR 可以自己改測試(#290 規則 1、「測項只能有一套」)。H2 先 merge 時這個 module 還不存在 → CI job 要嘛 FAIL(之後每個 PR 的 CI 都紅),要嘛 SKIP(找不到東西卻判綠,違反規則)。`prov-unit-96-lock` source 的 `prov-lock.sh` 也一樣不在 main。
- §3 / §5:preflight P3 要求「兩台都是 legacy」。H2 merge 之後 fleet 仍是 wsl.9(沒有 helper,也就沒有 `prov.meta`):判 legacy?還是 FAIL?如果 FAIL,依 H1 §4.1 的規則,daily-validation **一個 suite 都不會跑**,所有其他工作的驗證都會停。
- **修正**:helper 的行為表測試放在 harness(例如 `tests/prov-p1/helper-boot/`),以黑箱方式驅動 `batman-provhelper --boot --root`(要 test tag build;產品碼只提供 seam);preflight 明定「沒有 helper = pre-P1,判 legacy-equivalent,PASS」;H2 merge 到 P1 出貨之間,prov-\* 一律登記為 known-failure,附到期日(#290);CI 的單元 job 在 P1 merge 前標「expected-fail」並要求 FAIL 原因 = 檔案不存在。

### M9. 已知的 BT UART 卡死,加上 P1 新增的 `ble-ok` 閘 → 04 的 OTA 約 1/3 會 revert(產品回歸,也會汙染測試結果)
R11:04 重開 3 次有 1 次 hci0 逾時,只有重開能恢復。P1 讓 helper 在 04 上寫 `ble-ok`(04 兩個 FAT 都有 500 MHz,條件成立);之後每次 OTA 的 trial 一旦遇到 hci0 卡死 → health `hci0_powered=0` → UNHEALTHY → **把好 image revert 掉**。H2 裡 04 上每個 tier B OTA 測項(`prov-ota`、`lock-failsecure`、`trial-busy`、`gate`、`firstboot`、autocommit (1)(4)(5)(6)(10)…)都有大約 1/3 的機率 FAIL,而且原因不是受測對象。產品端:P1 出貨之後,04 這類節點的 OTA 也有同樣的 revert 率。使用者決定「UART 調查在 H2 / P1 之後」,但設計必須寫出這個交互作用,並請使用者在下面二選一:(a) P1 先不寫 `ble-ok`(只 log WARN),等 UART 根因查清楚;(b) 照上層做,接受 revert 率。另外,每個 OTA 測項都要記錄每次開機的 hci0 狀態(dmesg 有沒有 `0x0c0d tx timeout`),FAIL 的歸因以這個證據為準(使用者規則:FAIL 要嘛有歸因證據,要嘛標 ❓)。這是與上層的衝突,依 §0 應該回報。

### M10. H2 的生命週期矩陣只有 4 列;破壞性副作用沒有列
缺的路徑:H2 改名 H1 的 `bt/lease` → 正在跑的舊 run 的 deadman 怎麼辦(harness 升級)、要重跑 H1 N7 / N7b;節點在測項中途重開(M3);helper crash 或 crash loop 發生在測項期間;joinwatch / dropbear / openmanetd 在測項期間重啟;P1 rc 先 OTA 到 04 還是 02、版本不一致時 preflight P3 的「fleet 版本一致」(`prov-legacy-upgrade` 之後 02 還在 wsl.9);Git Bash 與 WSL(provclient 要 Go;Git Bash 下怎麼 build / 呼叫);CI;操作員在 claimed 節點上手動 OTA。
**副作用清單**(使用者 2026-10-18 規則,完全沒寫):每次 `prov-reset-legacy` 都重開 04 → OTS 中斷約 2 分鐘 × 十幾個測項;`firstboot`(overlay-wipe)會清掉 04 overlay 裡的 OTS payload init(R12)→ OTS 能不能自己回來 ⚠️ 要先查;`reboot -f` 打斷 04 上 p6 的 OTS DB / docker;p5 mkfs(firstboot);`device_id` 每次 reset 都換;02 的 slot B / p3 沒有 `core_freq_min`。每一項都要寫:碰到哪個資源、怎麼還原、還原後拿什麼斷言。

---

## MINOR

- m1 `BATMAN_P5_DEV` / `BATMAN_P5_MNT`:我沒找到非 root 能影響 root 呼叫者環境的路徑(config-save `:54` 只准 root;呼叫者是 procd 啟動的 joinwatch、helper、S10 的 96;我沒看到 CGI 或 rpcd exec 這條路)。但在正式節點上它也會生效:操作員在 profile export 錯值 → 寫到別的裝置。建議:真正的 `/dev/mmcblk0p5` 存在時,只有在 `BATMAN_TEST_FAKE_P5=1` 而且目標是 loop 裝置時才採用,否則忽略並記 log。
- m2 新增的共用檔案(`prov-lock.sh`、`99zz`、`rc.button/reset`)要加進 `check-provisioning-sync.sh` 的 PAIRS;`prov-lock.sh` 被 96 source,要加進 `ab-shared-change.yml` 的 paths 與 `docs/boards-and-builds.md` §6。P1 的 PR body 必須有 `### bcm2710` 段(R13),寫明 03 故障、未測。
- m3 golden 路徑(`deploy/` 經 `depersonalise.sh`)沒有 Go helper。96 / 99zz 在 helper 不存在時的行為要定(建議:exit 0、不改鎖定欄位、記 log),並加一個單元測試。
- m4 `rc.button/reset` 是 base-files 的檔案(F10)。Batman 套件裝同一個路徑會檔案衝突;改用 firmware 的 `files/` overlay(同 PR-F 的 shim)並在 rootfs 上斷言 sha。上層提到的 `reset_override` 沒處理。沒有測項:至少要做 rootfs 斷言,加上以 `ACTION=released SEEN=6` 跑在 stub 環境,證明它不呼叫 `jffs2reset`。
- m5 Go 工具鏈:CI 用 `setup-go` 並釘 SHA;host go1.22 對 firmware go1.26,`go.mod` 的 `go` directive 要兩邊都能 build;provclient 的第三方 CBOR 庫是新的供應鏈 → 建議自己寫一個最小的 deterministic encoder(R14 的向量就能證明對不對),不要加 `ugorji`。
- m6 provclient 自測要涵蓋 `owner_op`、`op_nonce`、`claim_checkmac`、`claim_replay`、`cose`、`psk_replay`(R14)這幾段,而且要寫出「195 項」實際對到哪幾段;`net_secrets` 解密只有一處提到,要確認它有自己的向量。
- m7 `PROV_TEST_KILLPOINT` 的 release 檢查,見 M4:要在組好的 rootfs 上做。
- m8 autocommit (9) 在 P1 改成「helper 反覆被 kill」,語意變了:health 會變舊 → fail-closed → 預期**會** revert,和上層 (9)「不 revert」正好相反。要嘛定新的預期並寫理由,要嘛整項移到 H3。
- m9 `provd` 的 uid:要避開 R8 列的 uid 與 OTS 容器實際執行的 uid(容器沒有 userns remap);斷言 helper socket 路徑沒有被 bind 進任何容器。
- m10 上層的「其他 → 今天的 4b」用在早退出口,等於 legacy 節點在早退出口現在也會寫 `lock-status`;今天不寫(F3)。這是行為變更,要明寫並納入 `prov-legacy-upgrade` 的斷言。
- m11 `prov-sock`:另外測「uid ≠ provd,但補充群組 = provd」(socket 0660)→ 必須被拒。
- m12 preflight「或指定狀態」的逃生口沒有定義:誰設、怎麼記錄在報告裡。
- m13 lease 改名要相容 H1 已出貨的 `ble-lib-254.sh`,並重跑 H1 N7 / N7b。
- m14 provclient 的輸出(`root_password`、`owner_tag_key`、`adv_owner_key`、`diag` 內容)不得印出、不得進 log,只能輸出雜湊;claimed 期間 root 密碼就是 serial console 的秘密。對抓回來的 log 跑 canary(同 H1 §4.7)。
- m15 `prov-claim` 的白箱「helper 不重算 ClientChal」:正常請求不帶 ClientChal 欄位,所以 provclient 要有一個對應的「攻擊模式」把它送進去;mutant 也要讀這個欄位。兩邊都要寫清楚,否則這個負對照做不出來。
- m16 `prov-sock` 在表中寫「trial 上改狀態動詞 → `E_BUSY`(…以真 trial 在 tier B 測)」,又另有 `prov-trial-busy-254`,重複了,刪一處。

## 我確認成立的部分
- feed pin 從 f2f2bf6 改到 P1 不會夾帶其他產品改動(R10)。
- 96 在 fresh overlay 上讀 p6 的前提成立(R5);config-save 只准 root(R9)。
- busybox `start-stop-daemon -c` 可以用(R8),只是放檔案的位置錯了(M1)。
- `GO_PKG_TAGS` 可以用來隔開 test build(R15)。
- P-U1(白箱 reset)、P-U2(獨立 Go client)、P-U3(全部動詞)、P-U4(真機)的方向都照實作,但 P-U3 的測項不完整(M6),P-U4 選的機器不對(B1)。

## 判定
**REJECT**。B1 / B2 照寫去跑會讓 02 卡在現場;M1–M10 要在下一版的整份設計裡解決。之後要對**整份**文件再審一次。
