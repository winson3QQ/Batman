# #254 階段 1 實作設計 v1 — 獨立審查 B(對抗式)

審查對象:`254-stage1-impl.md` v1(整份)。對照:`219-field-provisioning.md` v2.8、`219-protocol.md` v0.6、`202-config-survival-closeout.md` v6、`REVIEW.md`。
證據來源(2026-10-18,全部唯讀):Batman `main` f2f2bf6 原始碼(`gh api … raw`)、firmware tree `/home/yello/firmware-2710`(含 build_dir 的 linux-6.6.138 原始碼)、BlueZ 5.72 上游原始碼(github.com/bluez/bluez tag 5.72)、節點 04(10.41.1.3,slot A)與 02(10.41.1.1,slot B)唯讀探針(`cat`/`ls`/`uci show`/`ps`/`zcat /proc/config.gz`/`vcgencmd get_config`/`strings`/p5 `ro,noload` 掛載後 umount)。沒有做任何寫入。

## 0. 結論先講

**判定:REJECT(需出 v2 再整份重審)。** 骨架(非 root provd + root helper + keystore 介面 + p5 `prov/` + `99-zz` hook)方向正確,但有三個 BLOCKER 會讓階段 1 的核心流程(認領 → #137 鎖定 → OTA 存活)在真機上做不出來或做出危險的東西,另有十餘個 MAJOR 是介面沒定清楚、兩個實作者會做出不相容的東西。

| 等級 | 數量 | 編號 |
|---|---|---|
| BLOCKER | 3 | B1 dropbear 無 ECDSA、B2 provd 被攻陷 = 可恢復出廠/作廢另一槽、B3 p5 `prov/` 複製語意(不刪、不原子)|
| MAJOR | 11 | M1–M11 |
| MINOR | 14 | m1–m14 |

## 1. 先補生命週期矩陣與擁有權表漏掉的列(REVIEW.md 要求 reviewer 第一件事)

| 漏掉的路徑 / 資源 | 為什麼重要 | 對應發現 |
|---|---|---|
| **既有 fleet 節點(02/04:p5 已 seed、AP 用真 key 開著、`lock-status=UNPROVISIONED`、沒有 `prov/`)OTA 到階段 1 image** | 這是第一個會真的發生的升級;v1 矩陣只有「first boot」與「已認領」兩種起點 | M3 |
| **認領中途 `persist` 失敗**(bypass boot、p5 掛不起、rc 6)— overlay 已寫、p5 沒寫 | L7 只講斷電;「helper 以 p5 還原的 overlay 為準」沒有定義 | M8 |
| **`batman_bypass=1` 的非 fresh overlay 開機**(uci-defaults 早已跑過,`/etc/batman-prov` 還在) | L15 假設 `/etc/batman-prov` 是空的,只對 fresh slot 成立 | M8 |
| **`prov/version` 太新時 helper 的身分產生** | §4.3 說「以未認領起來」,§4.6 說「缺 keystore → 產生」→ 產生第二個身分蓋掉 p5 的 | M8 |
| **恢復出廠後 `prov/identity/`(node.key、claim.secret、counter)的去留** | L16「清 p5 prov/ + identity」與 219 §7「保留出廠身分」、§6.1 窗口語意衝突 | M7 |
| **`network/leave` / `owner/remove` 之後 OTA** | 刪掉的成員資格/擁有者會不會從 p5 回來 | B3 |
| **兩支手機同時認領(≤ 2 連線)**、**OTA 進行中有認領 session** | 沒寫誰贏、provd 要不要擋 | m11 |
| **`$ST/mesh-solo` 的生命週期**(誰清、第二台加入時、p6 跨 OTA 殘留) | 新資源沒進擁有權表 | M1 |
| 資源:`/etc/bluetooth/keys/`(bluetoothd 的 adapter 設定/IRK)、`boot_id` 與 `s_node`(每次開機)、`prov/identity/backend` 標記、`nonce_node` 產生者 | 擁有權表沒有 | m7、M6 |

## 2. BLOCKER

### B1 — 認領的 #137 鎖定做不出來:image 的 dropbear 沒有 ECDSA,擁有者 P-256 公鑰進不了 `authorized_keys`

**情境**:買家掃 QR 認領 → helper 照 §3「dropbear 列」寫 `authorized_keys`(擁有者公鑰)+ 隨機 root 密碼 → `96:164` 的 `has_key` 正規式與 `batman-config-save:151` 的 `seed_key_ok` **都接受 `ecdsa-sha2-` 開頭的行** → 節點 LOCKED(`PasswordAuth=off`)→ 但 dropbear 根本不認得 ECDSA 公鑰 → SSH 完全進不去,只剩 serial + root 密碼(而民用殼沒有 serial 台,219 F3)。而且下一次 OTA 後舊 image 的 96 也會因為同一組檔案 LOCKED(L12 列寫「SSH 都 key-only」= 假的)。

**證據**:
- 04:`strings /usr/sbin/dropbear | grep -i "ecdsa\|nistp\|ssh-"` 只有 `ssh-ed25519`、`sk-ssh-ed25519@openssh.com`、`rsa-sha2-256`、`ssh-rsa`;02:`strings … | grep -ci "ecdsa\|nistp"` = **0**。dropbear 2024.86-r2,這個 build 沒有 `DROPBEAR_ECC`。
- 協定裡擁有者只有 P-256 金鑰(`219-protocol.md` §6:owner 簽章金鑰、owner 加密金鑰都是 P-256;`claim/finish` 請求只帶 `owner_pub`、`owner_enc_pub`、`sig_enc`)— 沒有任何欄位能帶一把 ed25519 SSH 公鑰。
- v1 設計 §3 dropbear 列、§4.2、L1/L2/L5/L12 全部假設「同一組值」可以寫,但**沒有一行寫 `authorized_keys` 裡放什麼**;219 B5 早就列了這個問題(「dropbear 是否支援 ECDSA authorized_keys(否則另產 ed25519)」),v1 沒有收。

**修法(三選一,v2 要定案)**:
1. PR-F 把 dropbear 以 `CONFIG_DROPBEAR_ECC=y` 重建(image 改動,兩板),並把 `96:164` / `config-save:151` 的正規式收緊到**這個 image 真的支援的演算法**(否則以後再踩);或
2. 節點端認領時由 helper 產生一把 ed25519 SSH 金鑰對,私鑰經安全通道在 `claim/finish` 回應裡交給 app(與 `root_password` 同一等級)→ 協定 v0.7 加欄位 + CDDL + 向量;或
3. app 產生 ed25519 SSH 公鑰、`claim/finish` 多帶一欄 → 同樣是協定改動。
無論哪一個,負對照:以 `ecdsa-sha2-nistp256` 行餵 `96`,LOCKED 之後 `ssh -i <p256>` 必須成功;舊 image 上同一測試必須 FAIL(證明是 dropbear 的事)。

### B2 — 「provd 攻陷 ≠ root」不成立:helper 對 provd 的每個動詞都無條件執行,包含恢復出廠、作廢另一槽、改 mesh key

**情境**:路人在 BLE 範圍內打中 provd 的 Noise/CBOR/GATT 解析 bug(新 kernel BT 堆疊 + 新 userland parser 都是未交握就可達的輸入)→ 取得 provd 執行權 → 對 helper socket 送 `state.apply(恢復出廠)` → helper 清 p5 `prov/`、清 overlay、`batman-slot` 作廢另一槽、重開 → 整隊節點變磚(要重燒卡)。或送 `net.apply(mesh key=攻擊者的)` → 整隊掉網。helper 只驗 `SO_PEERCRED == provd` 與 schema,**沒有任何一個動詞要求「這個請求經過擁有者授權」的證明**。

**證據**:§4.1 動詞表:`state.apply(認領 / 加入 / 離開 / 恢復出廠 / 改名 / 國家)`、`net.apply`、`persist`;§7 T6 列只擋「本機非 root 冒用 app」;L16 恢復出廠由 helper 直接執行。§7 攻擊面段自己承認「新的 kernel 攻擊面,BLE 範圍任何人可送 HCI/L2CAP 封包」。

**修法**:破壞性與改網的動詞必須帶**helper 自己能驗的授權物件**,不是信任 provd 的判斷:
- `net.apply` 改成接受 **COSE `net_config` + `net_secrets`**(對這台加密),helper 用自己保管的 `admins`(prov state)驗鏈、自己 ECDH 解密(keystore 本來就在 helper)→ 明文 SAE key 從頭到尾不經過 provd(順便補上「provd 攻陷可讀網路密碼」這個洞)。
- `claim`:helper 自己做 CheckMac(已經是)**而且 `owner.pub` 的寫入綁在 CheckMac 成功的同一個請求裡**,不是兩個動詞。
- `reset`(leave/factory)、`owner/*`、`settings/set`:要求 `ES256_owner("batman-owner-auth-v1" ‖ h ‖ owner_key_id)` 加上 helper 自己產生的一次性 nonce(避免 provd 重放上一個 session 的簽章),helper 用 `owner.pub` 驗。
- 恢復出廠一律要「作廢另一槽」→ 加一道 helper 端的速率/冷卻(例如每次開機最多一次)與 `batman-slot is-trial` 拒絕(已有)。
- 負測試:在 provd 的 uid 下直接對 socket 送 `state.apply(factory)`(不經 BLE)→ 必須 `E_FORBIDDEN`;v1 的實作會成功 = 負對照。

### B3 — p5 `prov/` 的複製語意:只加不刪、多檔不原子 → 離網/移除擁有者後 OTA 又回來;斷電撕裂

**情境 1(安全)**:擁有者 `network/leave` 或 `owner/remove` → helper 刪 `/etc/batman-prov/net/*.cose` / 舊 owner → `batman-config-save` 的識別檔複製是 `cp -a "$STAGE/identity/." "$MNT/identity/"`(`:390`),**從不刪 p5 上的檔**,`same_identity()` 明寫「只在 p5 上的檔不算」(`:319-326`)→ 若 `prov/` 照同一套做,p5 還留著舊網路/舊擁有者 → 下次 OTA 新槽 96 還原 → 節點帶著**已離開的網路密碼**重新入網、被移除的擁有者又能 `auth/owner`。`--check` 也不會說 stale。

**情境 2(斷電)**:T8/L7 說「p5 由 config-save 原子」— 原子的只有 `mv overrides.uci`(`:391`)與 `.seeded` 最後寫(`:397`);identity 是多檔 `cp -a`。`prov/` 若是 `state.cbor` + `net/*.cose` + `members.cose` 多檔,斷電會得到「state=joined 但 net_secrets 是上一版」的 p5 → 新槽用錯 key 入網失敗,而 provd 卻回報 joined。

**證據**:`batman-config-save:319-326, 390-397`;v1 §4.3 只寫「逐檔複製(保留權限)」,§3 寫「p5 寫入走 batman-config-save(stage + rename + sync)」。

**修法**:`prov/` 在 p5 上改成**單一檔** `prov.cbor`(或 `prov.tar`)+ 內含 `version` 與 SHA-256,寫法 = stage 到 `batman_tmp` → `mv` 到 p5 → `sync`,刪除語意自然正確(整包取代);`--check` / `onjoin_fp()`(`:188-197`,**v1 沒提到這個快取,不加進指紋 `--on-join` 每 tick 會 cache hit 跳過**)/`same_identity` 都比對這一個檔的雜湊。`/etc/batman-prov/` 在 overlay 上也用同一個 bundle + `rename` 原子換(helper 現在只寫 `state.cbor` 原子,其他檔沒講)。負對照:leave → OTA → 新槽 `prov` state 必須是 `claimed`(未入網);v1 語意下會是 `joined`。

## 3. MAJOR

### M1 — 「已認領未入網」OTA 仍會被 autocommit revert:`expected_in_mesh()` 的 `.seeded` 分支與 `--seed` 寫 `mesh-expected` 都沒處理

**情境**:買家認領一台(還沒建網)→ helper 依 §3 呼叫 `batman-config-save --seed` → (a) `mark_mesh_expected()`(`:356-362`)**在 `--seed` 時就寫 p6 `mesh-expected`**;(b) 就算不寫,`batman-autocommit:388-396` `expected_in_mesh()` 最後一行 `[ -f "$m/.seeded" ]` → `NEED_MESH=1` → 之後任何 OTA(S4)都在沒有鄰居時 revert。v1 L6 只寫「helper 在 `network/join` 後才寫 mesh-expected」+「mesh-solo」,兩個分支都還在。219 §6.3 要求的是「改為依 p5 是否有成員資格判斷」。

**證據**:`batman-config-save:356-362`;`batman-autocommit:388-396`;04 實機 `cat /opt/batdata/state/mesh-expected` = `seeded --on-join`。

**修法**:`expected_in_mesh()` v2:若 `/etc/batman-prov`(或 p5 `prov`)有狀態 → `NEED_MESH = (state == joined && members > 1)`;沒有 prov 狀態(legacy 節點)→ 今天的規則。`mesh-solo` 不要另開一個 p6 標記(誰清?第二台加入後殘留 = 永遠不驗 mesh);成員數就在 `members.cose`。`--seed` 的 `mark_mesh_expected` 在 prov 狀態存在時不寫。負對照寫對了(不寫 solo 會 revert),但要加「認領未入網 → OTA → commit」這條(v1 的 L6 測試只測單台建網)。

### M2 — 執行期「關 AP 一律 key = placeholder」走不了 `halow-setkey`:它拒絕 placeholder

**情境**:`network/leave` 或恢復出廠要把 AP 關掉(219 §6.3 規定用 placeholder 表示)→ v1 §3 說 helper「經 halow-setkey(與操作員同一條路)」且「provd 不直接 uci set」→ `halow-setkey:55` `refusing the placeholder as a key` exit 2。於是實作者只能自己 `uci set`,live `wireless.*` 就多了一個寫者(擁有權表第 11 列破功),而且不會釋放/設定 keyguard 的 `MARK`、不會 `--save`。

**修法**:`halow-setkey` 加 `--ap-off`(= key=placeholder + `disabled=1` + 寫 `MARK` + `--save`),成為唯一的門;hook 的 `--apply-state` 也呼叫它。負對照:`halow-setkey --ap CHANGE-ME-NOW` exit 2(今天)。

### M3 — 既有 fleet 節點升級會把操作員設好的 AP 關掉、被當成「未認領」

**情境**:02/04 今天:p5 seeded、`default_radio0.key` 是真 key(非 placeholder,ssid `BCM2711-6c89` / `BCM2711-45d7`,兩台 hash 不同 = 各自設定)、`lock-status=UNPROVISIONED`、沒有 `prov/`。OTA 到階段 1 image → 新槽 fresh overlay → 96 還原 overrides(AP 真 key)→ `99-zz` 讀不到 state → 「unclaimed」→ 依 §4.4 把 AP key 改 placeholder、LuCI 關 → 操作員的 AP 消失;`--on-join` 下一 tick 把 placeholder **照字面**寫進 p5(202 B2)→ 真 key 從 p5 永久消失。同時 provd 每次開機開認領窗口並產生新 QR 秘密(只有 root 印得出)。

**證據**:04/02 探針(上);`halow-keyguard:30-35`;202 §2 B2。

**修法**:定義第三種狀態 `legacy`(p5 seeded 且無 prov)→ hook/helper **不碰** AP、dropbear、lock-status;provd 廣播「可認領」但認領成功後才接管 AP;矩陣加「legacy 升級」「legacy 認領」兩列與測試(04 是現成的 legacy 節點)。

### M4 — D-Bus:BlueZ 自帶的 `bluetooth.conf` 讓**任何本機 uid** 都能對 `org.bluez` 下指令,v1 的 `batman-provd.conf` 擋不住

**情境**:`bluez-daemon` 套件把上游 `src/bluetooth.conf` 裝到 `/etc/dbus-1/system.d/bluetooth.conf`(bluez Makefile `Package/bluez-daemon/install`),內容 `<policy context="default"><allow send_destination="org.bluez"/></policy>`;system bus socket 是 `srwxrwxrwx`、`system.conf` `<allow user="*"/>`(04 實測)。所以 gpsd(nobody)、avahi(nobody)、dnsmasq、ntp、或任何逃到非 root uid 的容器程序都能 `RegisterAdvertisement`(假廣播)、`RegisterApplication`(在 provd 旁邊再掛一個 GATT 服務)、`Set Powered=false`(DoS)、`StartDiscovery`。dbus 的規則是檔案照字母序載入、**後面的 allow/deny 蓋前面**,`batman-provd.conf`(`ba` < `bl`)排在 `bluetooth.conf` 前面,deny 會被上游的 allow 蓋掉。

**修法**:自己的 bluez 套件 patch 掉上游 `bluetooth.conf`(或裝一個 `zz-batman-bluez.conf`:default 全 deny `org.bluez`,只 `user="provd"` allow),並把 `bluetoothd` 用 `--noplugin=*`(或白名單)關掉 a2dp/avrcp/network/input/hog/battery 等 plugin、不要裝 `obexd`。負測試(可直接進 harness,節點有 `start-stop-daemon -c nobody`):`start-stop-daemon -S -c nobody -x /usr/bin/dbus-send -- --system --dest=org.bluez --print-reply / org.freedesktop.DBus.Introspectable.Introspect` → 必須被拒;上游 conf 下會成功 = 負對照。

### M5 — kmod-bluetooth:少了 `btbcm.ko`,`hci_uart` 載不起來;AUTOLOAD 順便載入 rfcomm/bnep/hidp/btusb

**證據**:`drivers/bluetooth/Kconfig:211-218` `BT_HCIUART_BCM … select BT_BCM`,`BT_BCM` 是 tristate(`:10-12`)→ `CONFIG_BT=m` 下變 `btbcm.ko`,`hci_uart.ko` 會依賴它的符號;`other.mk` `KernelPackage/bluetooth` 的 FILES 沒有 `btbcm.ko`,AUTOLOAD = `bluetooth rfcomm bnep hidp hci_uart btusb`(`:62`)。`btbcm.c:664-678` 要的韌體名是 `brcm/BCM4345C0.<board>.hcd` → `brcm/BCM4345C0.hcd`;linux-firmware-20241110 只有 `BCM-0bb4-0306.hcd`(D3 正確,要另外包)。

**修法**:PR-F 自建 `kmod-bluetooth-batman`(或 patch):FILES 加 `btbcm.ko`;AUTOLOAD 只 `bluetooth btbcm hci_uart`;rfcomm/bnep/hidp 不打包(BNEP = 經 BT 的 L2 網路橋接,是不該存在的攻擊面);btusb 不載(插一支 USB BT dongle 不應該變成第二個 adapter;provd 要綁 `hci0` by path)。D1「上機證據待 S1 第一次 build」= 這個設計有一個 P0 假設沒驗,PR-F 應該當 spike 先做,設計核准以它為條件。

### M6 — keystore 介面:缺 ECDH 金鑰與 `sn`/`device_id` 定義、`CheckMac` 簽名與 608B 對不上、`node_cert` 的鏈形狀沒定 → `se` 後端不可能零改 provd/app

**證據/缺口**(對照 `219-protocol.md` §3.3、§5.4、§6):
1. 協定要 `ecdh_pub`(65 B)+ `sig_ecdh`,且 ECDH 金鑰**與 DAC 分開**;v1 §4.2 的 `file` 後端檔案表只有 `node.key`、`node.cert`、`claim.secret`、`claimed.counter`,**沒有 `identity/ecdh.key`**;介面有 `ECDH(peerPub)` 卻沒有 `ECDHPub()`。
2. `node_cert` 要 `sn`(9 B,608B 序號)且 DAC 憑證 `subject.serialNumber = sn 小寫 hex`、`CN = device_id`;v1 沒定義 `file` 後端的 `sn` 怎麼來(必須隨身分固定、存檔)、`device_id` 怎麼從 `sn` 導出、鏈 `[葉, 中繼…]` 在開發 CA 下是 `[葉]` 還是 `[葉, 開發中繼]`。沒定,Go 與 Rust 兩邊會各做一種。
3. `CheckMac(nonce, mac)`:608B 的 CheckMac 輸入是 `ClientChal(32)`、`ClientResp(32)`、`OtherData(13)`,`ClientChal = SHA-256("batman-claim-v1" ‖ nonce ‖ h ‖ SHA-256(DAC) ‖ owner_pub)` 只有 provd 算得出(`h` 在 provd)。介面應是 `CheckMac(clientChal, clientResp)`,`SN`/`OtherData` 在 helper。而且認領成功要**原子地**寫 `owner.pub` + `IncClaimed()`(見 B2)。
4. `Sign(purpose, msg)`:`boot_id` 與 `nonce_node` 協定規定「節點自己產生、絕不簽對方提供的值」→ 應由 helper 產生並回傳,不是 provd 傳進來(provd 攻陷時 helper 仍是帶標籤的簽章 oracle;至少 `peers/challenge` 的 `nonce_node` 要 helper 出)。
5. `IncClaimed()`/`ClaimedCounter()`:608B 單調計數器只能 +1、不可歸零;`file` 後端必須有同樣的「只增」語意,並寫明**恢復出廠不歸零**(見 M7)。
6. 「`se` 應在而不在 → 拒絕啟動」:什麼叫「應在」?需要一個持久標記(`prov/identity/backend = file|se`,身分建立時寫)。另外要明寫 #255 的現場後果:**焊上 608B = 新身分、新 QR、所有擁有者重新認領**(金鑰搬不進晶片);「provd/app 不重工」是程式層面,不是使用者層面。

**修法**:§4.2 補 `ecdh.key`、`sn`(9 B 隨機,存檔)、`device_id = f(sn)` 公式、鏈形狀、`backend` 標記;§2 介面改成 `DeviceCert() (chain, sn)`, `ECDHPub()`, `Sign(label, msg) `, `ECDH(peerPub)`, `CheckMac(clientChal, clientResp) (ok, err)`, `Claim(clientChal, clientResp, ownerPub) `(原子)、`ClaimedCounter()`、`NewNonce()`。驗收:同一組 `tests/vectors/219-protocol` 的 `node_cert`/CheckMac 向量,`file` 後端要過;`se` 後端留 B1 實機交叉驗證。

### M7 — 恢復出廠對 `prov/identity/` 的處理沒定,與認領窗口語意衝突

v1 L16:「helper:先清 p5 `prov/` + identity(`--wipe-prov`)」。若 `prov/identity/`(node.key、node.cert、claim.secret、counter)也清 → 新身分、counter=0 → 「從未認領,每次開機開窗口」→ 219 §6.1「恢復出廠後要按鍵/SD 標記才開窗口」失效,而且機身 QR 失效(與 219 §7「保留出廠身分」相反)。若只清 dropbear identity → 要寫清楚。另外 L16 寫「作廢另一槽(試用期拒絕)」但沒寫**誰**寫清除日誌標記、斷電續做(219 §7 要求)— 是 helper 在 p6 寫,還是 `batman-slot`?擁有權表沒有這個資源。

**修法**:定義 `--wipe-prov` = 刪 `prov` bundle 裡 `owner/*`、`net/*`、`members`、`state`,**保留 `identity/*` 與 counter**;dropbear `authorized_keys`/`shadow-root` 由 helper 刪 live 後 `--save` 跟上;p6 的 `factory-reset.inprogress` 標記(helper 寫、開機 hook 讀)進擁有權表;測試 `prov-factory-reset-254` 要斷言 `device_id` 不變、窗口關閉(需 SD 標記才開)。

### M8 — 狀態轉換不是交易:persist 失敗、bypass boot、prov 版本太新三種情況都會讓 overlay 與 p5 分岔,甚至產生第二個身分

**情境**:
- 認領:helper 寫 `/etc/batman-prov`(claimed)→ `persist` → `batman-config-save` rc 1(bypass、mount 失敗、鎖逾時)或 rc 6 → v1 只說「E_STORAGE」。節點 overlay 已是 claimed,app 也以為 claimed;下次 OTA 新槽回 unclaimed。L7 的「以 p5 還原的 overlay 為準」是事後,不是事前。
- `batman_bypass=1` 非 fresh overlay:`/etc/batman-prov` 還在(uci-defaults 早跑完),provd 正常起、helper 正常接請求,但 `persist` 一律被拒(`config-save:99-102`)。
- fresh slot + bypass,或 `prov/version` > 認得的:`/etc/batman-prov` 空 → §4.6「缺 keystore → 產生」→ **新的 node.key/claim.secret**;之後正常開機 96 又把 p5 的舊身分蓋回來 → 身分來回跳、QR 一下有效一下無效。

**修法**:
- `state.apply` 兩階段:先 stage 新 bundle 到 `batman_tmp` → `persist` 成功(rc 0)→ 才 `rename` 進 `/etc/batman-prov`;失敗則 overlay 不動、回 `E_STORAGE`。rc 6(不可持久化的值)對 prov 不可能(是 CBOR,不走 uci batch)— 寫明。
- helper 啟動:`batman_bypass=1` → `state=unknown`、**拒絕產生身分**;無 `/etc/batman-prov` 時先 `ro,noload` 看 p5:p5 有 `prov` → 不產生(等正常開機還原)並廣播「需要維護」;p5 版本太新 → 同上;只有 p5 也沒有 `prov` 才產生。
- 這些各加一列矩陣與測試(`prov-bypass-254` 要同時測 fresh 與非 fresh)。

### M9 — mini UART 的 core clock 沒有被釘住(D12 的 ⚠️ 要現在解,因為 p1 不隨 OTA)

**證據**:`miniuart-bt-overlay.dts`(linux-6.6.138)只切 pinmux 與 `&minibt status`,**沒有任何 clock 設定**;02 與 04 `vcgencmd get_config core_freq_min` = **200**、`core_freq` = 500、`enable_uart` = 1;distroconfig `[all]` 寫的是 `uart_enable=1`(不是合法鍵 `enable_uart`,只是上游的 typo,`enable_uart=1` 是 firmware 因 overlay 自動設的)。mini UART 的 baud 由 VPU core clock 導出;若 core clock 在閒置時掉到 200 MHz,HCI 會錯框/掉線,而且是**間歇性**(閒置才發生)。D12「`vcgencmd measure_clock core` = 500」是一次快照,不是證據。

**修法**:`[pi4]` 加 `core_freq_min=500`(與 `[pi3]` 的 `core_freq_min=400` 同一個理由,#203 已有前例),並在 PR-F 以「閒置 10 分鐘 + 每 10 s 取樣 `measure_clock core` + 同時 BLE 連線不中斷」當驗收;**02/04 要重燒 p1 才能帶到**(OTA payload 不含 distroconfig,`batman-slot:640-648` 只抄 kernel/dtb/overlays/start*/fixup*)→ 寫進 L13/L14 與 release note。

### M10 — `--seed` 的前置條件與認領流程綁死,且 `--seed` 會旋轉 lkg

`batman-config-save:350` `--seed` 要求 `authorized_keys` 有可用鍵(B1 的問題),且 `:392-394` `--seed` 把**未入網證明過**的 overrides 升成 lkg(202 的 lkg 契約是「入網證明過」)。認領當下 mesh key 沒變所以無害,但 `network/join` 之後 helper 若再用 `--seed`(例如 p5 剛好未 seed 的新卡)就違反契約。另外 `--seed` 在 p5 未 seed 且有 p7 時跑 Pi 3 factory gate(`:288`)— 3A+ 不在本階段,但 `--seed` 的 rc 1 要有對應的 app 訊息。

**修法**:helper 的 `persist` 動詞改成:p5 未 seed → `--seed`(只在 claim);之後一律 `--save`,入網後 `--save --promote-lkg` 只在 helper 自己驗到 `meshjoin_joined` 才下(219 §6.4 L373 已這樣寫)。

### M11 — 測試:BLE 黑箱的「假手機」不是獨立實作,且「02 與 04 在 BLE 範圍內」沒有證據

§9 選 (a) 02 當 central,用 `go-bluetooth` + 同一份 Go 協定庫當 client → 同一份程式碼兩端互通**不是黑箱**(共同的 CBOR/COSE/Noise bug 兩邊都有就一起過)。真正獨立的是 `tests/vectors/219-protocol/verify.py`(Python,另一份實作)。再者 02/04 是否在 ~10 m 內、02 經 mesh 被 harness 驅動時同時當 BLE central 會不會影響它的 mesh 角色,v1 沒有證據(D 表沒有這條)。

**修法**:(1) 協定層黑箱 = Go 實作必須**逐位元組**通過 119 項向量 + 新增 `-dev` 向量 + Go 端用 `verify.py` 的對手實作做交握(socket 承載即可,不需 BT);(2) BLE 傳輸層用 02 central 只驗 GATT 框架/MTU/重組/斷線(可以同庫);(3) 每個 `prov-sec-*` 的負對照要能**關掉那個檢查**跑一次(例如 helper `--insecure-no-peercred` 只在 harness build?不行 — 改用「假 provd」以 nobody 連 socket,今天的 helper 若不驗 PEERCRED 就會過)。D 表加「02–04 BLE RSSI 實測」。

## 4. MINOR

- **m1 uci-defaults 排序**:`-`(0x2D)排在 `_`(0x5F)前,`99-zz-batman-prov-state` 會在 `99_morse_radio_defaults`(把 morse channel 設回 42、country US)**之前**跑;雖然它不碰 AP key,但 v1「排在最後」的描述不對。若要真的最後,檔名用 `99zz-…`;並把 04 `/rom/etc/uci-defaults` 的完整清單(含上游 `31_dropbear_default_disable`、`32_openmanet_dropbear_enable`、`50-root-passwd`)寫進 D 表。
- **m2 BLE 配對/綁定**:`main.conf` 5.72 沒有 `Pairable` 鍵(只有 `AlwaysPairable`、`PairableTimeout`);不綁定靠的是「`AlwaysPairable=false`(預設)+ 不註冊 agent → `adapter_set_io_capability()` 清 `MGMT_SETTING_BONDABLE`」(`src/adapter.c:9080-9090`)。v1 要寫對機制,並加負測試:nRF Connect 按 Bond → 失敗、`/etc/bluetooth/keys/<adapter>/` 無 peer 目錄。
- **m3 bluetoothd 服務**:上游 init 是 `START=62`、無 respawn、`ln -snf /etc/bluetooth/keys /var/lib/bluetooth`(adapter 設定/IRK 落在 overlay,fresh slot 會換 IRK → RPA 關聯性在槽切換時斷,這是好事但要寫進擁有權表);v1 寫 61。`bluez-daemon` 會拉 `bluez-utils`(hciattach、rfcomm、hcitool…)、`bluez-utils-extra`(gatttool、sdptool、btmgmt)、`obexd` — 建議自己的 `bluez-daemon-min` 只裝 `bluetoothd` + `bluetoothctl`。
- **m4 ujail 路徑**:`/var -> tmp`(04 實測),jail 內用 `-r/-w` staging 時請一律寫 `/tmp/run/…`(`rundir.sh:9-11` 的理由),否則 jail 內沒有 `/var` symlink。provd 需要的只有 `helper.sock`、`system_bus_socket`、二進位本身;寫一份 `capabilities/provd.json`(空)進 D 表。
- **m5 停止順序**:L3/L10 沒寫 STOP 順序;provd 的 `STOP` 必須小於 bluetoothd 與 dbus(K 序),否則 reboot 時 provd 會先看到 `NameOwnerChanged` 風暴再被殺,log 髒。
- **m6 `status/public` 在已認領狀態不得帶 `device_id` 末碼**(219 §3.3/§3.4:已認領先驗對方才揭露身分;廣播只有擁有者/成員認得出的摘要);v1 §4.5 無條件列了。
- **m7 擁有權表補列**:`/etc/bluetooth/keys/`(bluetoothd)、`boot_id`/`s_node`(helper 產、provd 持有)、`nonce_node`(helper)、`prov/identity/backend`、p6 `factory-reset.inprogress`。
- **m8 數字不一致**:認領失敗「≤ 5 即斷」(v1 §7)vs 協定 §8「3 次」;單則訊息 8 KiB(v1)vs 協定 65519/1 MB 分塊 — 8 KiB 要在 `info`/`CTRL` 回報成能力,否則 app 不知道何時該走 S4 的 WiFi 備援。
- **m9 Go 端協定庫**:協定 §10/§11 明寫 `flynn/noise` 交叉驗證與 `-dev` 向量「尚未」;v1 Q4 說「已定」但 PR-P2 的驗收條件要寫成「Go 通過全部向量 + 產出 `-dev` 向量交給 app」。Go 沒有成熟 COSE 函式庫、CBOR 要用 core-deterministic 模式(例如 `fxamacker/cbor` `EncOptions{Sort: SortCoreDeterministic}`)— 這類選型寫進 D 表。
- **m10 D3 授權**:`.hcd` 的授權檔要在 PR-F 真的抓到並列 sha(linux-firmware 有 `LICENCE.broadcom_bcm43xx`,RPi `bluez-firmware` 另有 Cypress 條款);v1 寫「待抓」是對的,但核准前要有。
- **m11 矩陣補列**:兩支手機同時 `claim/begin`(誰贏、另一個收 `E_BUSY` 還是 `E_CLAIM_FAILED`)、認領 session 進行中跑 OTA(provd 要在 `persist` 未完成時讓 `--check` 判 stale → 已自然被 202 C5 擋,寫明即可)、全新卡 p5 為 raw(`--seed` mkfs 路徑)。
- **m12 `halow-status`**:UNPROVISIONED 文字(`halow-status:118` "anyone reaching this node may get root")在未認領但 AP 已關時會誤導;219 §6.2 要求改字,v1 沒列。
- **m13 LED**:219 §2.3 的「找不到機台:確認燈號藍色慢閃」在階段 1 做不到(v1 不碰 LED,對,dpp-handler 會 `led reload`);寫進 §11 殘項與 app 文案。
- **m14 R17**:`/rom` 419.6 MB 是 `du`(解壓);squashfs 實際 107.5 MB(`df`),Q5 估大小請用 squashfs 增量。

## 5. 依 REVIEW.md 逐項核對(v1 哪裡沒達標)

| 項目 | 狀態 |
|---|---|
| 1 擁有權 | 大致有;漏列見 §1;`wireless.*` 執行期實際上會有第二個寫者(M2) |
| 2 契約 | helper socket 動詞有 schema 但**沒有授權模型**(B2);`prov/` 的格式/缺/壞/刪除語意不足(B3);`authorized_keys` 內容未定(B1) |
| 3 生命週期 | 缺 legacy 升級、persist 失敗、非 fresh bypass、恢復出廠身分、leave 後 OTA(§1 表) |
| 4 假設證據 | D1/D3/D4/D12 標 ⚠️;其中 D12 本審查已探出反證(M9);D4(非 root 用 BlueZ D-Bus API)上游 policy 其實是「任何人都可以」(M4),方向相反 |
| 5 安全 | 資產/actor 表有;但 T5/T6 的「provd 攻陷 ≠ root」結論不成立(B2);D-Bus 本機攻擊面漏掉(M4);kernel BR/EDR 模組載入(M5);負測試大多有名字沒有「關掉檢查就會過」的規格(M11) |

## 6. 給 v2 的建議順序

1. 先定 B1(三選一)— 它決定協定要不要改版,影響 PR-P2 與 app。
2. B2 + M6 一起重寫 §2/§4.1/§4.2:helper 變成「驗證授權物件並執行」而不是「provd 說什麼做什麼」;keystore 介面補齊到能生成協定要的 `node_cert` 全部欄位。
3. B3 + M8 + M7:`prov` 改單檔 bundle、交易式 `state.apply`、恢復出廠保留 identity。
4. M1/M2/M3:autocommit、`halow-setkey --ap-off`、legacy 狀態。
5. PR-F 當 spike:M5(btbcm、AUTOLOAD)、M4(dbus policy)、M9(`core_freq_min=500` + p1 重燒計畫)、m3,先在 04 上看到 `hci0` + `bluetoothctl show` 的 `Pairable: no` + 非 root dbus-send 被拒,再回來核准設計其餘部分。

**判定:REJECT**(BLOCKER ×3、MAJOR ×11;修完整份重審)。
