# Review A(第 4 輪)— `254-stage1-impl.md` v4(#254 階段 1 實作設計)

審查者 A,獨立、對抗式,審整份(§0–§13),不是只看 v3→v4 差異。依使用者 CLAUDE.md 的設計審查規則與 `docs/design/REVIEW.md`。使用者已定案的事項不重開(擁有權與 SSH 脫鉤、恢復出廠全清含身分、Go/Flutter+Rust、3A+ 延後、`uart_enable` typo、改名探針、Q5),只在 §5 列後果。

**證據來源(全部唯讀,2026-10-19)**
- Batman `design/254-stage1-impl` @ 16274af(程式 = main f2f2bf6):`batman-config-save`、`96-batman-config-migrate`、`99-batman-chanfix`、`99-halow-identity`、`95-batman-storage`(產生 batdata-mount 的 init)、`batman-autocommit`、`batman-slot`、`halow-setkey`、`init.d/{halow-keyguard,joinwatch,batman-autocommit}`、`meshjoin.sh`、`platform-ab.sh`、`payload-guardian.init.in`、`payload-teardown`、`feed/batman-payload-host/.../{99-batman-payload-docker,init.d/batman-ots-firstload}`、`scripts/build-ab-payload.sh`。
- firmware-2710 `build_dir/target-aarch64_cortex-a72_musl/`:`busybox-default/busybox-1.36.1/.config`、`procd-default/procd-2026.03.14~c59f2d80/rcS.c`、`dropbear-2024.86/src/{svr-auth.c,svr-authpasswd.c}`。
- 04(10.41.1.3)與 02(10.41.1.1):`find -delete`、`busybox find --help`、`command -v mkfs.ext4 jffs2reset flock`、`ls /etc/rc.d`、`/proc/mounts`、`find /overlay/upper -name '.*'`、`ls -la /opt/batdata /opt/batdata/state`、`/etc/shadow` 第 2 欄(只看是不是空)、`uci get` dropbear/ttylogin/channel、`batman-slot active / is-trial / target`、`/etc/batman-build`。
- **沒有任何寫入**;沒跑 `bluetoothctl`、沒 reboot、沒 `jffs2reset -y`、沒跑 config-save 的寫入模式。

---

## 0. 總評

v4 把 v3 的大方向收對了:`ota-armed.mesh` 移到 stage 1、p5 prov 只剩 `--prov-only` 一個寫者、rc≠0 一律讀回 gen、96 對 claimed/member 一律上鎖、身分補寫不重產、rc 表完整、`claim.replay` 解回應遺失、恢復出廠有失敗政策 + mkfs、SD 標記讀兩個 FAT。這些我都逐條對過原始碼,可以保留。

但從現場重走(轉賣前恢復出廠、02/04 第一次 OTA、買家在弱訊號下認領、單台在家更新、整隊 OTA、p5 壞掉的機台、BLE 路人)之後,還有 **7 條 MAJOR**,都是「元件各自沒錯、合起來不成立」:

- 恢復出廠的步驟 3/4/8 靠 `find -delete`,但**映像檔裡的 busybox 沒有 `-delete`**(兩台實測,`.config` 也確認)。加上步驟 4/8 的失敗政策是「繼續」,照字面實作,每次恢復出廠都會把前任的 tenant 資料和 dot 檔交給買家,而且回報完成。
- `ota-armed.mesh` 綁的 `metadata version=` 其實是**建置時間戳**(`build-ab-payload.sh:69`)。trial 端沒有任何地方知道這個值,所以永遠比不上 → member 單台在家更新永遠 revert(B-M5 / L31 實質沒收)。另外它沒有綁開機,會留下陳舊值。
- `claim/replay` 讓已認領節點接受匿名 `NX`,任何 BLE 路人都能拿到 `node_cert`(DAC、`sn`、`device_id`)→ 可以追蹤,和 219 §3.4 的需求正面衝突。
- `prov-txn` 讓路規則會擋到 helper **自己**在交易中呼叫的 `--save`(config-save 分不出呼叫者)→ 每筆交易卡 30 s,剛好等於 socket 逾時。
- `radio_managed=1` 的 wireless 對帳和另外三個 live 寫者(99-chanfix、morse 回寫、操作員 halow-setkey)沒有契約 → 開機互相覆寫、多次 wifi reload(#132 的觸發條件)、操作員在現場改的頻道在重開後被靜默改回去。
- #202 的「p5 未 seed 拒絕 OTA」閘(`batman-slot:534-547`)會擋掉 unclaimed 與剛恢復出廠的節點,§6.4 的負對照 (2) 根本跑不到。
- 恢復出廠的凍結與續做狀態**只存在 p6 marker 裡**。步驟 5 的失敗政策又分不出「暫時忙」和「媒體壞了」→ 可能永久停在 resetting(而步驟 2 已經把 mesh/AP 關掉並 commit 進 overlay);p6 之後若掛不起,凍結就消失,helper 的「rc 7 + overlay 有身分 → 補 persist」會把前任的 prov 寫回去。

另外有 14 條 MINOR。

**判定:REJECT(v4)**。架構不用動,修法都在 §4.3/§4.4/§4.5/§6.1/§6.4 局部;但有 MAJOR 未收,依規則改完要整份再審。

---

## 1. 先補:矩陣缺的列、擁有權缺的資源

| 缺的路徑 / 資源 | 為什麼要有 | 對應 |
|---|---|---|
| **`sysupgrade -T` / LuCI / procd 第二次 validate**(只驗證、不升級) | `platform-ab.sh:74-75` 的既有不變式:「a mere validation leaves nothing that a later boot could misread as an OTA」。v4 在 `platform_check_image` 寫 p6 狀態檔,打破了它 | M2 |
| **直接 `batman-slot apply`**(live 系統、不經 sysupgrade;`batman-slot:510` 明列為合法路徑,ab-selftest/bench 用) | 不會跑 `platform_check_image` → 沒有新的 `ota-armed.mesh`,可能讀到舊的 | M2 |
| **操作員 `batman-slot commit`(COMMITTED-BY-OPERATOR)、stage 2 拒寫沒 arm** | autocommit 沒做決策 → 沒人刪 `ota-armed.mesh` | M2 |
| **unclaimed / 恢復出廠後的 OTA**(p5 未 seed) | `batman-slot:534-547` 的 #202 閘先擋 | M6 |
| **恢復出廠步驟 5 永久失敗**(p5 媒體壞、LUKS)與**取消** | 「停在此步、下次開機重試」沒有終點 | M7 |
| **恢復出廠中途 p6 掛不起**(95 拒絕受損 p6,`batman-storage.crit`) | 前置條件只在開始時檢查一次 | M7 |
| **恢復出廠期間有人下 OTA**(precheck-node 不看 marker) | slot_lock 會序列化,但 trial 撞上 reset 的結果沒定義 | m10 |
| **dropbear 重啟**(`meshjoin_reachable` 依賴它,R55) | REVIEW.md 要求「每個依賴的重啟」 | m13 |
| 資源:**live `wireless.radio1.channel` 的其他寫者**:`99-batman-chanfix:50-52`(fresh 開機)、morse 驅動回寫硬體預設(`96:143-146`、`halow-setkey:108`)、操作員 `halow-setkey` | §3 寫「執行期只經 halow-setkey」不成立 | M5 |
| 資源:**guardian 的實際啟動點**:batdata-mount 在 **S11** 就 `"$dst" running \|\| "$dst" start`(`95-batman-storage` 產生的 init,`restore_payload_guardians`);**`S95batman-ots-firstload`** 載入 p6 的 image 並啟動 guardian | R59 寫「guardian START=99」,所以「S13 在 guardian 之前」的推論不成立 | m2 |
| 資源:恢復出廠的 `flock` 檔放哪裡 | 步驟 4 會刪 `state/` 裡 marker 以外的一切 | m11 |
| 資源:`claim/finish` 回應快取的**讀取路徑** | 已認領後匿名 NX 只收 `claim/replay`,而 replay 不讀快取 | m8 |

---

## 2. Findings

### MAJOR

**M1. 恢復出廠的步驟 3/4/8 依賴 busybox 沒有的 `find -delete`;步驟 4/8 的失敗政策是「繼續」→ 照字面實作,每次恢復出廠都會留下前任的 tenant 資料與 dot 檔,並回報完成**

- 情境:擁有者要轉賣,在 app 按恢復出廠 → 步驟 3 `find /opt/batdata/docker -mindepth 1 -delete` 失敗 → 「下次開機重試,3 次後繼續」;步驟 4 失敗 → 「3 次後 `reason=p6-partial` 並繼續」;步驟 8 失敗 → 「繼續」。結果:OTS 的 DB 與 volume、`/opt/batdata/.faketime`、`/overlay/upper/.cache/Tailscale/*`,以及 `/etc/batman-prov/.stage/`(內含 `owner{tag_key,adv_key}` 明文)全部留著;新擁有者拿到的是 `unclaimed`,卻帶著前任的資料。
- 證據(✅ 實測):
  ```
  04$ find / -maxdepth 0 -delete      → find: unrecognized: -delete
  02$ find / -maxdepth 0 -delete      → find: unrecognized: -delete
  04$ ls -l $(command -v find)        → /usr/bin/find -> ../../bin/busybox
  busybox-1.36.1/.config:476          # CONFIG_FEATURE_FIND_DELETE is not set
  busybox-1.36.1/.config:462,478,461  CONFIG_FEATURE_FIND_MAXDEPTH=y / FIND_PATH=y / FIND_XDEV=y
  ```
  §7 D26 自己標了 ⚠️「待上機」;本輪上機結果是**不可用**。L16 的斷言(「p6 只剩白名單」)本來抓得到,但 L16 要等 Q5 才跑(§9)→ 在那之前沒有任何測試擋得住。
- 附帶:
  - 04 的 `/proc/mounts` 有 `/dev/mmcblk0p6 /opt/batdata/docker ext4`(data-root 的 bind)以及多個 `overlay …/merged`。步驟 4 刪的時候若還有任何掛載點在 `/opt/batdata` 下面,會 EBUSY,或者經 `merged` 寫出 whiteout。
  - `-xdev` 擋不住同一個 fs 的 bind mount。
- 修法:
  1. 刪除改在 helper(Go)裡做:`Lstat`、不跟 symlink、含 dot、遇到掛載點就拒絕。或者用 busybox 有的 `find … -depth -exec rm -rf {} \;`(`FIND_EXEC=y`)。或者在 busybox config 打開 `FEATURE_FIND_DELETE`(會改 image,兩板都要)。
  2. 步驟 3/4 開始前斷言 `grep -c ' /opt/batdata/' /proc/mounts` = 0,不是 0 → 該步失敗。
  3. 步驟 4/8 失敗**不准以「完成」結束**:最終 `info.state` 要帶 `reset-partial:<step>`,app 必須顯示「未完全清除」。前任資料殘留不是可以吞掉的失敗。
  4. 負對照:在目前的 image 上照 v4 文字跑步驟 4 → 回 `unrecognized: -delete`,p6 不變(現況已證明)。修好後同一組斷言要 PASS。

**M2. `ota-armed.mesh` 的綁定比不上:`metadata version=` 是建置時間戳,trial 端無從得知 → member 有鄰居 / 沒鄰居一律走「要求鄰居」;此外沒有綁開機,留下的陳舊值會 fail-open**

- 證據(✅ 原始碼與實測):
  - `scripts/build-ab-payload.sh:69`:`printf 'board=%s\nversion=%s\nsize=%s\n' "$BOARD" "$(date +%Y%m%d-%H%M%S)" …` → `version=` 是時間戳。
  - trial 端只知道 `BATMAN_VERSION`(`batman-autocommit:66` `version(){ sed -n 's/^BATMAN_VERSION=//p' /etc/batman-build; }`;02 實測 `BATMAN_VERSION=1.5.12-wsl.2+f2f2bf6.fw9d87d02`)。`batman-slot apply`(`:625-708`)沒有把 payload 的 metadata 存到任何地方。所以 §6.4 的「slot 與 version == 本 trial」永遠不成立。D24「payload metadata 有 `version=` ✅」只證明了欄位存在,沒證明能比對。
  - 後果:fail-closed 方向,所以是安全的;但 **L31「單台在家更新 → commit」和負對照 (3) 一定失敗**。member 單台的每一次 OTA 都會 revert,v2 B-M5 / v3 B3-B1 想解的問題實質沒收。
- 陳舊值(修好 version 之後就會出現):
  - `platform-ab.sh:74-75` 寫明 stage 1 也被 `validate_firmware_image` / `sysupgrade -T` / LuCI 呼叫,而且「no state file」是刻意的不變式;`:90` procd 還會再 validate 一次。
  - 一次單純驗證(在家時、沒鄰居 → `radio`)會留下 `<T> <V> radio`。之後若走直接 `batman-slot apply`(`batman-slot:510`),或某次 stage 1 寫檔失敗(設計說「寫失敗 → 不阻擋 OTA」),同一個 slot、同一個 version 的 trial 就會讀到陳舊的 `radio` → 不要求鄰居 → fail-open。
  - harness 會反覆 OTA 同一個 build(`fault-injection.sh:191`、`daily-validation.sh:1890`),「同版本」在 bench 上是常態。
  - 操作員 `batman-slot commit` 或 stage 2 拒寫時,autocommit 沒做決策,也就沒人刪這個檔。
- 另:stage 1 只取**一次**樣本(`meshjoin_sample; meshjoin_joined`)。−82~−95 dBm 的現場(R42)plink 會抖,一次 0 → `radio` → 有鄰居的 member 被當成單台,壞 image 會被 commit。
- 修法:
  1. 綁定改成 trial 端能驗的值:`build-ab-payload.sh` 從 rootfs 的 `/etc/batman-build` 把 `batman_version=` 寫進 metadata,autocommit 用 `version()` 比對;或者綁 rootfs 的 `RSUM` 前 16 字元,trial 從自己的 root 分割算(較貴)。
  2. 綁開機:檔案加 stage 1 的 `boot_id`。autocommit 只接受「上一次開機」的 boot_id(batdata-mount 每次開機都在 `boot-reasons.log` 記 `boot_id=`,倒數第二行就是)。
  3. 只在 `/proc/$PPID/cmdline` 含 `sysupgrade` 時才寫(`platform-ab.sh:92` 已有同樣的判斷);寫之前先 `rm -f`;`rm` 失敗 → 拒絕這次 OTA。
  4. `joined` 的判定改用 joinwatch 的近期狀態(最近 N 分鐘內 JOINED 過),或 stage 1 取多個樣本取 OR。
  5. 負對照:(a) `sysupgrade -T` 後直接 `batman-slot apply` 同一個 payload,有鄰居 → 必須要求鄰居;(b) 單台 member OTA → commit(v4 文字下會 revert,因為 version 比不上)。

**M3. `claim/replay` 的匿名 `NX` 例外會讓任何 BLE 路人拿到已認領節點的 `node_cert` → 可追蹤;違反上層「已認領機台先驗對方才揭露身分」的需求**

- 情境:路人對附近每一台已認領/成員節點都打開匿名 NX。協定第 2 則訊息的 payload 一律是 `node_cert`(`219-protocol.md` §3.1「第 2 則的 payload = `node_cert`」;§3.3 內容含 `dac_chain`、`sn`、`device_id`)。NX 的回應方靜態金鑰只用發起方的臨時金鑰加密,所以匿名發起方解得開。於是路人拿到一個穩定的識別碼,RPA(`Privacy=device`)和輪替的 `adv_owner_key` 都白做了。
- 證據:
  - v4 §4.8(:296)「`claimed|member` 允許匿名 NX 只為 `claim/replay`(其他訊息 `E_FORBIDDEN`)」—— 擋的是**訊息**,但身分在交握第 2 則就已經送出了。
  - `219-field-provisioning.md:267`:「已認領的機台 … app 必須先證明持有擁有者金鑰或網路金鑰,節點才送出 DAC 與 `device_id` | 防止任何人連上 GATT 就拿到明文的身分(追蹤)」;`:623` 同一條需求。
  - `219-protocol.md:41`「已認領的節點一律拒絕沒有 PSK 的 `NX`(防止降級)」—— v4 §1.3 只寫了例外,沒寫隱私與降級的後果。
- 附帶:匿名 session 也讓路人能長時間佔住 ≤2 條連線(以前 NXpsk0 在第 1 則就失敗)。
- 修法(實作層可做,不必等 608B):replay 模式的 NX 第 2 則 payload **不帶 `node_cert`**(只帶 `boot_id` + `nonce_helper`)。app 先送 `owner_op(h)` + `owner_pub`,helper 驗過「== 已存的 owner_pub」之後,provd 才送 `node_cert` 並開始 CheckMac。路人拿不到擁有者簽章,什麼也看不到;owner-op 綁 `h`,中繼到別台也沒用。協定 v0.7 要寫成新的模式,不是「NX 例外」。**負測試**:無 owner key 的 central 對 claimed 節點做 NX → 收到的 payload 不含 `sn`/DAC(v4 文字下會含)。

**M4. `prov-txn` 讓路會擋到 helper 自己在交易中呼叫的 `--save` → 每一筆認領 / `net.apply` 卡 30 s(= socket 逾時),或者失敗**

- 證據:§3 prov-txn 一列(:107):存在、pid 活著、cmdline 含 `batman-provhelper` → `--on-join` 回 1、「操作員 `--save` 等 ≤ 30 s」。但 §4.4 步驟 5 與 §6.1 步驟 4 的 `--save`,是 helper 在**刪 prov-txn 之前**呼叫的(§4.4 步驟 5「→ 刪 prov-txn」;§6.1 步驟 6 才刪)。config-save 只看得到 `mode=--save`(`batman-config-save:44-53`),分不出是操作員還是 helper 的子程序 → helper 的 `--save` 等自己 30 s。§4.1 的 socket 逾時也是 30 s → provd 回失敗,節點卻已提交 → 這正是 L34 要解的「回應遺失」,由設計自己製造出來。如果 30 s 後判失敗,shadow-root 沒進 p5 → 下次 OTA 96 設 `root:!`。
- 修法:prov-txn 只需要保護步驟 2–4(uci 已 commit、prov 未 rename 的那段)。改成**步驟 4 rename 之後就刪 prov-txn**,再做步驟 5 的 `--save`。或者 helper 傳一個只有 helper 知道的 token(例如 `--in-txn <nonce>`,nonce 寫在 prov-txn 裡)。負對照:量 `claim.verify` 的端到端時間,v4 文字下 ≥30 s,修後 <5 s。

**M5. `radio_managed=1` 的 wireless 對帳沒有和其他三個 live 寫者訂契約 → 開機互相覆寫、多次 wifi reload、操作員的現場修改在重開後被靜默改回**

- 證據:
  - `99-batman-chanfix:22-57`:每個 fresh slot 第一次開機,背景從 **p5 `overrides.uci`** 讀頻道,最多 6 次 `uci commit wireless; wifi reload`。
  - `96:143-146`、`halow-setkey:108`:morse 在 regdomain 還沒穩定時會把硬體預設頻道**寫回 uci**。
  - `halow-setkey:147`:操作員的 `halow-setkey --channel/--mesh` 持久化到 p5 `overrides.uci`,不會更新 `prov.cbor.net`。
  - v4 §4.4 步驟 7:helper 每次開機把 live uci 對帳到 `prov.cbor.net`,「不同才 `halow-setkey --no-persist`」,之後 joinwatch 再把結果寫回 p5。
- 情境 A(整隊 OTA 的 trial,fresh overlay):96 從 overrides 套頻道 X,morse 回寫 42,helper(S89)看到 42 ≠ prov 的 X → setkey + reload,同時 chanfix 也在 reload。開機期間 2–7 次 wifi reload。記憶中 #132 正是「Morse churn 下 panic/hang」。L2「無 `wifi reload` log」只在非 fresh 開機成立。
- 情境 B(現場):成員網因為干擾,操作員用 SSH(owner 經 `ssh_keys.set` 加的 key)在每台下 `halow-setkey --channel Y` → p5 overrides = Y、prov = X → 下一次斷電重開,每台的 helper 把頻道改回 X,joinwatch 再把 X 寫回 p5 → 操作員的修改被靜默撤銷;若只有部分節點重開 → 網路分裂。
- 修法:二擇一寫清楚,並把 §3 改成實話。
  1. `radio_managed=1` 時 `halow-setkey` 拒絕(提示走 app `network/update`),並且 99-chanfix 改讀 prov 的頻道;
  2. 或者 helper 不在開機時強制,只在 helper 自己的交易中斷(prov-txn 殘留 / gen 不一致)時才對帳。
  
  對帳的比較要排除 morse 回寫的暫態(等 chanfix 結束,或者只比 key / mesh_id,不比 channel)。負對照:fresh trial 上數 `logread | grep -c 'wifi reload\|reassert'`,v4 文字下 >1;操作員改頻道後重開 → 頻道維持(或 setkey 拒絕)。

**M6. #202 的「p5 未 seed 拒絕 OTA」閘會擋掉 unclaimed 與剛恢復出廠的節點;§6.4 的負對照 (2) 跑不到,店裡的庫存也無法更新**

- 證據:`batman-slot:534-547`(`node_checks`,stage 1 的 `precheck-node` 與 stage 2 都跑):p5 是 ext4 而沒有 `.seeded` → `die "p5 (config) is not seeded … strand it"`。`--prov-only` 明定「不碰 `.seeded`」(§4.3)。unclaimed 的 mesh key 是 placeholder,永遠不會 JOINED,所以 `--on-join` 永遠不會 seed。恢復出廠後是 mkfs 過、未 seed 的 p5。→ unclaimed 節點 OTA 一定被拒,除非 touch `/tmp/batman-slot.allow-unseeded`。
- 這條閘的前提是「未 seed = fresh slot 會以未佈署狀態開機 → 在只有 mesh 的節點上 strand」。在 prov 的世界裡,unclaimed 本來就該未佈署,而 `prov.cbor` 才是狀態的 SoT。
- 修法:閘改成 prov-aware:p5 有完整的 prov 且 `state ∈ {unclaimed}` → 不擋;claimed / member 仍以 `.seeded` 為準。claimed 在 §6.1 步驟 4 的 `--save` 之後就是 seeded;這一步失敗時要擋(見 m5)。§6.4 負對照 (2) 照這條改寫。負對照:unclaimed 節點 `sysupgrade -n` → 進到 trial 並 commit(v4 文字下 stage 1 會 `REFUSING (node not ready for an OTA): p5 … not seeded`)。

**M7. 恢復出廠的凍結與續做只存在 p6 marker;步驟 5 的失敗政策分不出「暫時忙」與「媒體永久失敗」→ 可能永久停在 resetting,也可能讓前任的 prov 被寫回**

- 情境 A(永久 resetting):p5 硬體壞了(I/O error;正是 §4.2 說「SD 標記重置是 p5 壞掉機台的出口」的那台)→ 步驟 5 `mkfs` 每次都失敗 → 「停在此步(不往下)…下次開機重試」,沒有上限、沒有取消。而 joinwatch / dockerd / guardian 因為 marker 都拒絕啟動,步驟 2 已經 `--mesh-off --ap-off`。`--no-persist` 仍會 `uci commit`(R56、`halow-setkey:99`)→ 每次開機 mesh 和 AP 都是關的。結果是節點永久離網,只剩乙太網 / BLE status,而原本 `unknown` 的機台至少還能跑。Secure tier(#111)的 LUKS p5 會走 rc 1,一樣永久停住。
- 情境 B(凍結消失):步驟 5(mkfs)完成之後、步驟 8 之前斷電 → 下次開機 p6 掛不起(95 拒絕受損 p6,或 batdata-mount `mount` 單次失敗就 `return 0`,見 `95-batman-storage` 產生的 `boot()`)→ `$ST` 落在 overlay 上的空目錄 → 看不到 marker:
  - S13 不續做;
  - config-save 不凍結;
  - helper `--boot`:`--prov-get` rc 7 + overlay 身分完整 → 依 §4.2 表「補 persist」→ 把前任的 `prov{claimed}` 與身分寫回剛 mkfs 的 p5;
  - joinwatch 若 JOINED(mesh 已 off,機會低)也會 reseed。
  
  恢復出廠被靜默撤銷,而 p6 的半刪狀態留著。在大量刪除 p6 時斷電,正是 p6 最可能需要 fsck 的時候,兩個故障是相關的。
- 修法:
  1. `--wipe-all` 在 mkfs 之後立刻在 p5 寫 tombstone(例如 `.factory-reset <device_id>`)。helper 看到 tombstone → resetting(不補 persist);config-save 的寫入模式看到 tombstone 也拒寫。tombstone 只由新身分的第一次 `--prov-only` 移除。凍結因此不再只依賴 p6。
  2. 步驟 5 分流:rc 8(忙)→ 重試;**mkfs 失敗、且 p5 ro 也掛不起**(96 也讀不到,所以不會還原前任)→ 記 `reason=p5-dead` 並繼續步驟 6–10,完成後是 `unknown(p5-unreadable)`,但新身分在 overlay、可以認領。LUKS → 階段 1 不存在,但要寫明 #111 必須改這一步。
  3. 給擁有者 / 操作員一個取消或「放棄並完成」的出口(owner-op 或 root CLI)。
  4. 負對照:(a) 白箱讓 p5 的 mkfs 失敗(dm-error 或 loop 唯讀)→ N 次開機內結束 resetting(v4 文字下永遠停住);(b) 步驟 5 之後斷電,下次開機讓 p6 掛不起 → 前任的 prov 不回到 p5(v4 文字下會回來)。

### MINOR

- **m1. marker 路徑與變數名不一致**:§4.3 `--prov-only` 寫「`$RUNDIR/factory-reset` 檢查」,§3 / §4.5 是 p6 的 `$ST/factory-reset.inprogress`。config-save 裡 `$ST` 已經是 `$RUNDIR/cfgsave-onjoin.state`(`batman-config-save:64`)→ 照設計的 `$ST` 實作會指錯檔案。統一寫絕對路徑。
- **m2. R59 的 guardian 時序錯了**:batdata-mount 在 S11 的 `restore_payload_guardians` 會 `"$dst" running 2>/dev/null || "$dst" start` → guardian 每次開機都在 **S11** 被拉起,早於 S13。`S95batman-ots-firstload`(04/02 的 `/etc/rc.d` 都有)會 `docker load` p6 上的 image 並啟動 guardian。所以拒絕啟動的檢查必須放在 `payload-guardian.sh` 的 `start_service`(image 內,不是 p6 上的 stub)與 firstload 的 `boot()`,不能依賴「S13 在 S99 之前」。§4.7 補上 firstload。
- **m3. S13 阻塞 init 與「不全暗」矛盾、沒有時間預算**:S13 在 dropbear(S19)、network(S20)、dbus(S60)、bluetoothd(S61)、provd(S92)之前跑 → 續做期間節點**全暗**,而 docker data-root 的大量刪除可能要好幾分鐘。procd 開機階段沒有逾時:`rcS.c:160-163` 只有 `stop`/`shutdown` 設了 `run_timeout = 15000`;busybox 也沒有 `timeout`(`.config:339`)。修法:S13 只做「不需要網路的快速步驟」(marker / SD 偵測、凍結),長步驟交給 S89 的 helper 在背景做(那時 provd 已能廣播 resetting);續做時跳過步驟 2(wifi 還沒起來,netifd 未啟動)。
- **m4. SD 標記的 `device_id` 從哪裡來沒定**:S13 在 fresh overlay 上(以及 `unknown(identity-lost)`、fresh + `p5-unreadable`)沒有身分可比 → §4.2「unknown 時 SD 重置可用」對這幾種情況不成立。另外,恢復出廠後第一次開機,S13 在 helper 產新身分之前就讀 SD 標記,「沒有身分」要明確定義成「忽略」,否則可能重置迴圈。建議:讀不到任何身分(overlay 與 p5 都沒有)時接受 `any`。實體持有 SD 的人本來就能重燒卡,安全上沒有損失。
- **m5. 96 4b 的位置**:§4.3 說 prov 的抄寫放在 `:93` 之前,但 4b 上鎖目前在 `:155` 之後。claim 步驟 4 的 `--save` 失敗時,p5 是「有 prov、未 seed」→ 96 在 `:93` 就 exit,沒有上鎖 → fail-open。要明寫:只要讀到 `prov.meta` 的 state ∈ {claimed, member},**每一個出口**之前都上鎖。
- **m6. `root:!` 的連帶效應**:dropbear 的 key 登入不受影響(✅ `dropbear-2024.86/src/svr-authpasswd.c:94` 的 locked 檢查只在密碼路徑;`svr-auth.c:130` 只擋空密碼的 none-auth)→ harness 的 lab key 照常可用。但 `stage_overrides` 只存 `root:$*`(`batman-config-save:304`)→ `--on-join` 的 `final_rc` 永遠回 4(「node still OPEN」,`:363`),halow-status / joinwatch 會把上了鎖的節點報成 open。另外,`/etc/batman-dev-open` 與 claimed 上鎖誰優先沒寫(`96:165` 今天是 dev-open 優先)。
- **m7. `ro,noload` 會讀到交易前的 metadata**:`96:89`、`batman-config-save:254`、`--prov-get` 都用 `noload`。若斷電發生在 `sync`(journal 已提交)與 `umount`(checkpoint)之間,noload 看不到 journal → fresh overlay 會抄到較舊的 prov。在可寫的 block device 上,ext4 的 `ro` 掛載**會** replay journal(`96:74` 註解「ro can't replay」的前提不對)。改用 `ro`,或者 helper 開機時先做一次 rw 掛載再卸載。
- **m8. claim 回應快取沒有讀取路徑**:§3 / §6.1 步驟 5 快取 10 分鐘(含 root 密碼),但已認領後匿名 NX 只收 `claim/replay`,而 replay 是讀 `prov.cbor` 並產**新**密碼,沒用到快取。root 密碼因此白白在 helper 記憶體多留 10 分鐘。要嘛定義「同一 session / 同一 idem_key 的 `claim/finish` 重送」走快取,要嘛刪掉快取。
- **m9. 步驟順序**:另一槽的作廢(步驟 7)排在 p5 mkfs(步驟 5)之後。這段期間若 firmware 開錯槽(Pi 4 EEPROM 開錯槽 bug;`fw_override_check` 只有在 p6 已掛、次數 ≤2 時才修正),另一槽完整的舊 overlay(前任的身分、可能是沒有 marker 檢查的舊 image)會跑起來。把 `invalidate-other` 移到 mkfs 之前。
- **m10. 恢復出廠期間的 OTA**:`node_checks`(`batman-slot:516-560`)不看 marker,app 雖然在 resetting 會擋,但 SSH / harness 的 `sysupgrade` 不會被擋。precheck-node 要在 marker 存在時拒絕。
- **m11. `flock` 檔與 `state/` 殘留**:步驟 4 刪掉 `state/` 裡 marker 以外的一切;若 flock 檔是另一個檔案,它被 unlink 之後互斥就失效。步驟 4 之後 helper 若又寫出 `ble-ok` / `prov-state`,這些檔會活過重置(步驟 11 只清 `log/`、`crash/`)。flock 直接鎖 marker 本身,步驟 11 也清 `state/`(只留 marker 之外的空目錄)。
- **m12. `--wipe-all` 改寫了既有的「只有 `--seed` 可以 format」規則**(`batman-config-save:103-109`)。設計要同步改這段註解與 #202 的文件,並說明為什麼這次不需要 `--reformat` 那套守門(`:172-180`:未掛載、ro 掛三次都失敗、有 key)。
- **m13. 矩陣缺列**:dropbear 重啟(`meshjoin_reachable` 依賴它)、`sysupgrade -T` / LuCI validate、直接 `batman-slot apply`、操作員 commit 之後 `ota-armed.mesh` 的清理、恢復出廠期間的 OTA、stage 1 寫檔對 bcm2710 的影響(platform-ab 兩板共用)。
- **m14. 降級到 1.5.12 的 claimed 節點**:舊的 96 4b 對「無 key、有密碼」判 UNPROVISIONED(`96:173-176`),而 `ttylogin` 預設 0(02 實測 `0`)→ serial 直接給 root shell。L12 應列出這個後果(是實體威脅,但屬於 fail-open)。

---

## 3. 作者點名項逐一回答

| 項 | 結論 |
|---|---|
| §4.5 步驟失敗表 | 有表了 ✅;步驟 3/4/8 的工具不存在、「繼續」會吞掉前任資料(M1);步驟 5 沒有終點(M7) |
| `mkfs` p5 vs「never mkfs non-ext4」/ LUKS #111 | LUKS 標頭會回 rc 1 → 階段 1 不存在,但會永久停住(M7);既有規則與文件要同步(m12);`mkfs.ext4` 在 04 上存在(`/usr/sbin/mkfs.ext4`)✅ |
| p5 凍結 vs 所有 p5 寫者 | 寫者只有 config-save 的 `--on-join`/`--save`/`--seed`/`--if-healthy`(呼叫者:`joinwatch:145`、`halow-setkey:147`)✅;96 / 99-chanfix 只讀 ✅。漏洞在凍結只存在 p6(M7 情境 B),路徑名不一致(m1) |
| S13 阻塞 init vs procd / 開機時序 | procd 開機階段無逾時(`rcS.c:160-163`);guardian 在 S11 就被拉起、firstload 在 S95(m2);續做期間全暗(m3) |
| live overlayfs upperdir 上的 `find -delete` | busybox 沒有 `-delete`(M1);直接刪 upper/work 等同上游 `jffs2reset` 對已掛 overlay 的做法(`overlay_delete`),本身可接受 |
| batdata-mount 每次開機從 p6 還原 guardian stub | stub 是由 **image 的模板**產生(`restore_payload_guardians`,不抄 p6 的 `.init`),所以 marker 檢查放在模板 / lib 就會生效;但它會在 S11 主動 start(m2)。步驟 3「只刪 stub」沒有意義,`apps/` 還在就會重生,要靠步驟 4 |
| SD 標記讀兩個 FAT | ✅ `batman-slot boot-devs` 對應 `slot_bootdev`(`:103`);身分來源未定(m4) |
| §6.4 `platform_check_image` 是否一定跑 | `sysupgrade`(含 `-F`)會跑,但 `-F` 會忽略失敗;直接 `batman-slot apply` 不跑;`-T` / LuCI / procd 會**多**跑(M2) |
| `batman-slot target` 語意 | committed 節點上 = 非 active 槽 ✅(`:789`;02 實測 `active=B`、`target=A`) |
| version 字串比對 | ❌ metadata 是時間戳(M2) |
| 誰刪 `ota-armed.mesh` | 只有 autocommit 做決策時刪;operator commit / stage 2 拒寫時沒人刪(M2) |
| §4.3 單一 prov 寫者 + `prov-txn` 讓路 | 單一寫者 ✅;讓路擋到 helper 自己(M4) |
| §4.4 wireless 對帳 vs `halow-setkey` / 99-chanfix | 會互相覆寫(M5) |
| 96 fail-secure `root:!` 之後誰依賴 root 登入 | key 登入不受影響(dropbear 原始碼)✅;harness 用 key ✅;OTS 不用 root 登入;副作用見 m6;上鎖位置見 m5 |
| `claim/replay` 協定例外 | 解回應遺失 ✅;身分外洩(M3) |
| 認領回應快取 | 沒有讀取路徑(m8) |

---

## 4. 逐 actor

| Actor | v4 擋住 | 本輪沒擋住 / 寫錯 |
|---|---|---|
| BLE 路人 | 匿名只收 `status/public` + `claim/replay`、無 agent、provd DoS 不會 revert(L39) | 匿名 NX 拿到 `node_cert` → 追蹤(M3);佔連線 |
| 攻陷的 provd | 換擁有者 / replay 換人(需 owner-op + 已存 owner_pub)✅、誠實界線 ✅ | — |
| 本機非 root | dbus、PEERCRED、0600 + `-O` | `ota-armed.mesh` 的陳舊值不是非 root 寫得出來的(p6 是 root)✅ |
| 攻陷的 tenant | — | 續做時 guardian 在 S11 就起來、firstload 在 S95(m2) |
| 前任擁有者(轉賣) | p5 mkfs、overlay 含 dot、SD 標記綁 device_id | 工具不存在 → 資料殘留(M1);凍結只在 p6(M7);另一槽作廢太晚(m9) |
| 買家 | 新身分、回應遺失可 replay | 新 QR 只能經 root(U4 後果) |
| 實體 SD | 標記要 device_id | 身分讀不到時無出口(m4);降級 → serial root(m14) |
| legacy fleet(02/04)第一次 OTA | mesh 閘不變、`--prov-only` 不碰 overrides ✅ | — |
| 單台在家更新 | — | version 永遠比不上 → 一定 revert(M2) |
| 整隊 OTA | stage 1 `joined` → 要求鄰居 ✅ | fresh trial 的 wifi reload 互相覆寫(M5);單次取樣(M2) |
| p5 壞掉的機台 | mkfs 能修好「格式壞」的 p5 | 媒體壞 → 永久 resetting(M7);fresh 無身分 → SD 出口不存在(m4) |
| 我們自己 | rc 表、單一寫者大多到位 | D24 / D26 證據不足(M1/M2)、R59 錯(m2)、prov-txn 自擋(M4)、#202 閘(M6) |

---

## 5. 使用者已定案事項的後果(不重開,只列)

- **U3 擁有權與 SSH 脫鉤**:claimed / member 的 serial 只能用 app 下發的 root 密碼;fail-secure 路徑上是 `root:!` → serial 完全進不去,只剩 key(若 owner 用 `ssh_keys.set` 加過)與 app。
- **U4 全清含身分**:轉賣時買家要經乙太網 / serial 以 root 取新 QR;unclaimed 的 image 預設是空密碼 + `PasswordAuth=on`(04 實測 `root:` 空、`PasswordAuth=on`、`ttylogin=0`)→ 任何接上乙太網的人都能取 QR,也都是 root(#137)。M6 修好之前,unclaimed 連 OTA 都做不了。
- **3A+ 延後**:M2 的修法會改 `build-ab-payload.sh` 與 `platform-ab.sh`(兩板共用);M1 若選擇改 busybox config,兩板都要重驗。
- **Q5 待定**:L16 是唯一能抓到 M1 / M7 的測試,在 Q5 定案前不會跑 → 建議至少把 M1 的「工具存在」與 M7 的白箱放進 tier A(不需要破壞性還原)。

---

## 6. v3 發現核對(一條一行)

| v3 | 狀態 | 說明 |
|---|---|---|
| A3-B1 恢復出廠無失敗政策 / p5 壞死鎖 | partial | 有政策 + mkfs ✅;工具不存在 + 「繼續」吞資料(M1);步驟 5 無終點(M7);身分讀不到時無出口(m4) |
| A3-M1 `ota-armed.mesh` stage 2 算不出 | partial | 移到 stage 1 ✅;version 比不上、陳舊值、單次取樣(M2) |
| A3-M2 `--no-persist` 仍 commit、不對帳 | partial | prov-txn + 對帳 ✅;對帳與 chanfix / 操作員打架(M5)、prov-txn 自擋(M4) |
| A3-M3 rc 6 已寫 | addressed | `--prov-only` 沒有 rc 6;rc≠0 讀回 gen |
| A3-M4 legacy 被解鎖 | addressed | 步驟 7:legacy / unclaimed 不寫 |
| A3-M5 96 4b fail-open | partial | 一律上鎖 ✅;`:93` 未 seed 出口沒寫(m5) |
| A3-M6 身分重產 | addressed | rc 表 + overlay 完整 → 補 persist |
| A3-M7 續做與開機服務並行 | partial | S13 + 拒啟 ✅;guardian 在 S11 啟動、firstload 漏列(m2) |
| A3-M8 認領回應遺失 | partial | `claim.replay` ✅;身分外洩(M3)、快取無讀取路徑(m8) |
| A3-M9 L16 在 02 無路可回 | addressed(待使用者) | Q5,未定不跑 |
| A3-M10 rc 表不全 | addressed | §4.2 完整 |
| A3-m1 R43 證據 | addressed | 改用原始碼 |
| A3-m2 dot 項目 | partial | 有寫含 dot,但 `-delete` 不可用(M1) |
| A3-m3 on-join / check 語意 | addressed | §4.3 |
| A3-m4 meta 格式 | addressed | 一份定義 |
| A3-m5 SD 標記 FAT | addressed | 兩個 FAT 都讀都刪 |
| A3-m6 legacy 門 overclaim | addressed | §6.1 / §8 誠實改寫 |
| A3-m7 psks 界線 | addressed | |
| A3-m8 ble-ok 條件 | addressed | 兩個 FAT + core clock + 10 分鐘 |
| A3-m9 root 密碼時機 | addressed | §6.1 |
| A3-m10 擁有權缺寫者 / `$RUN` | addressed | 但 `$ST` 撞名(m1) |
| A3-m11 `--on-join` 重 seed | partial | 凍結 ✅;只存在 p6(M7) |
| A3-m12 新 p6 檔契約 | partial | 0600 / `-O` ✅;`ota-armed.mesh` 沒有綁開機(M2) |
| A3-m13 lost+found | addressed(工具見 M1) | |
| A3-m14 ssh_keys 標記 | addressed | `ssh_keys.added` |
| B3-B1 `ota-armed.mesh` stage 2 | partial | 同 A3-M1(M2) |
| B3-M1 p5 prov 兩寫者 | addressed | 只剩 `--prov-only`;overlay 新 → 以 overlay 為準 |
| B3-M2 reset 期間 p5 未凍結 / 步驟失敗 | partial | 凍結 + 政策 ✅;p6 單點、步驟 5 無終點(M7) |
| B3-M3 dot 目錄 / R43 | partial | R43 更正 ✅;`-delete` 不可用(M1) |
| B3-M4 SD 標記位置 | addressed | `boot-devs` |
| B3-M5 回應遺失 | partial | replay ✅;M3 |
| B3-m1 rc 10 | addressed | meta 最後寫 |
| B3-m2 身分條件 | addressed | |
| B3-m3 legacy persist 改 overrides | addressed | `--prov-only` |
| B3-m4 qr tty / legacy 門 | addressed | 不收 pts |
| B3-m5 psks 界線 | addressed | |
| B3-m6 meta 副本 / fail-open | partial | sha 綁定 cbor ✅、一律上鎖 ✅;`:93` 出口(m5) |
| B3-m7 只改一份 FAT | addressed | ble-ok 檢查兩份 |
| B3-m8 clear_root 不可重用 | addressed | `invalidate-other` 自算 ZERO_MB(offset 40 的 `bytes_used` 正確) |
| B3-m9 reset 撞 tryboot | addressed | 前置條件 + disarm;OTA 撞 reset 另見 m10 |
| B3-m10 trial 上 prov-state 順序 | addressed | fresh 開機時 95 在 S10 就掛好 p6(`96:6` 註解 + 95 尾端 `"$INIT" boot`),99zz 寫得到 |
| B3-m11 L20 overclaim / boot_id | addressed | |
| B3-m12 provd DoS revert | addressed | health 不看 provd 存活 |
| B3-m13 p6 未掛 / 編輯錯誤 | partial | 開始時檢查 ✅;中途 p6 掛不起(M7) |

---

## 7. 本輪唯讀探針(原始輸出摘要)

```
04$ find / -maxdepth 0 -delete         → find: unrecognized: -delete
04$ busybox find --help | grep …       → -xdev …  -mindepth N …   (沒有 -delete)
02$ find / -maxdepth 0 -delete         → find: unrecognized: -delete
04$ command -v mkfs.ext4 jffs2reset flock → /usr/sbin/mkfs.ext4   (另兩個在 busybox / fstools,未列印路徑)
04$ /proc/mounts                        → /dev/mmcblk0p6 /opt/batdata ext4 rw; /dev/mmcblk0p6 /opt/batdata/docker ext4 rw;
                                          5 × overlay /opt/batdata/docker/overlay2/*/merged; /dev/mmcblk0p1 /boot vfat fmask=0022
04$ find /overlay/upper -maxdepth 3 -name '.*'  → /overlay/upper/.cache
02$ 同上                                 → /overlay/upper/.cache
04$ ls -la /opt/batdata                  → .faketime, apps/, docker/, lost+found/, dv289-backup-*/ …
04$ /etc/rc.d                            → … S11batdata-mount S11fstab S12batman-faketime S12log S13openssl S18halow-keyguard
                                          S19dropbear S20network S60dbus S61bluetoothd S95batman-ots-firstload S98joinwatch
                                          S99batman-autocommit S99batman-payload-opentakserver S99dockerd …
04$ shadow root 第 2 欄                   → 空;PasswordAuth=on;ttylogin=0;lock-status=UNPROVISIONED
02$ batman-slot active / is-trial / target → B / rc=1 / A
02$ /etc/batman-build                    → BATMAN_VERSION=1.5.12-wsl.2+f2f2bf6.fw9d87d02
02$ uci get wireless.radio1.channel      → 40
build-ab-payload.sh:69                   → version=$(date +%Y%m%d-%H%M%S)
busybox .config:476                      → # CONFIG_FEATURE_FIND_DELETE is not set ;  :339 # CONFIG_TIMEOUT is not set ; :628 CONFIG_FLOCK=y
procd rcS.c:160-163                      → run_timeout 只給 stop/shutdown
dropbear svr-authpasswd.c:94             → "User account '%s' is locked" 只在密碼路徑
```

---

## 8. 判定

**REJECT(v4)**:BLOCKER ×0、MAJOR ×7、MINOR ×14。

MAJOR 的修法都是局部的:
- 刪除改 Go,或改用 `-exec rm`;
- version 改綁 `BATMAN_VERSION` + boot_id;
- replay 改成延後揭露身分;
- prov-txn 在 rename 之後就刪;
- 定義 radio 寫者的契約;
- #202 閘改成 prov-aware;
- p5 tombstone + 步驟 5 分流。

但這些改到的是 OTA 閘、協定與恢復出廠的契約,依規則 v5 要整份再審。
