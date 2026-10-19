# Review A — `254-stage1-impl.md` v1(#254 階段 1 實作設計)

審查者 A(獨立、對抗式)。審整份文件(§0–§11),不是只看最新段。依 `REVIEW.md` + 使用者 CLAUDE.md 的設計審查規則:先找生命週期矩陣缺的列與擁有權表缺的資源,再逐 actor 攻擊,每個假設對原始碼或真機核對。

**證據來源(全部唯讀,2026-10-18)**:Batman `main` f2f2bf6 的 `96-batman-config-migrate`、`batman-config-save`、`batman-autocommit`、`halow-keyguard`、`99-halow-identity`、`joinwatch`、`meshjoin.sh`、`halow-setkey`、`rundir.sh`;firmware-2710 的 `other.mk`、`feeds/packages/utils/bluez/{Makefile,files/bluetoothd.init}`、`dl/bluez-5.72.tar.xz`(`src/bluetooth.conf`、`src/main.conf`、`src/main.c`、`src/adapter.c`)、`.config`、dbus `system.conf`、`miniuart-bt-overlay.dts`、overlays README;節點 04(10.41.1.3)與 02(10.41.1.1)的 `ls/ps/uci show/zcat config.gz/strings/docker inspect`。沒有改任何東西。

---

## 0. 總評(一段)

骨架方向對:helper(root)/ provd(非 root、ujail)拆開、keystore 介面固定、p5 `schema_version` 維持 1 加 `prov/version`(R9 讀 `96:131` 正確:schema 2 會讓舊 96 退回 `lkg/`)、AP 關閉一律用 placeholder key、p5 單一寫者不破。這些可以留。

但文件在三個地方把「今天的程式會怎麼做」寫錯或沒寫,而且都是會在現場咬人的:(1) **p5 一有 `.seeded`,autocommit 就要求入網**(`batman-autocommit:388-397`),而且 `--seed` 自己就寫 `mesh-expected`(`batman-config-save:356-362`)——L6「已認領未入網也能 commit」在現行程式上不成立;(2) **dropbear 沒編 ECDSA**(`.config:1584 # CONFIG_DROPBEAR_ECC is not set`;節點 `strings /usr/sbin/dropbear` 只有 ed25519),擁有者的 P-256 金鑰進不了 `authorized_keys`,而 `--seed/--save` 沒有可用 key 就拒絕、96 有 key+密碼就 LOCKED——認領要嘛存不進 p5,要嘛把節點鎖成只有手機金鑰能開的門(而手機沒有 SSH client);(3) **overlay 與 p5 的 `prov/` 不一致時,每條路徑都是 overlay 贏**(96 掛不起 p5 → 被 disarm;trial 槽認領後 revert;factory reset 中途斷電),而 overlay 可能是「未認領」的那份 → 擁有權無聲消失、認領窗口重開、任何人可再認領。這直接違反 §7「全部 fail-closed」。

另外 BlueZ 的 D-Bus 預設 policy 讓**任何本機 uid** 都能操作 `org.bluez`(關 adapter、註冊自己的廣播/GATT),設計寫的 `main.conf` 鍵有兩個在 5.72 不存在,`mesh-solo` 沒有清除者、沒有 radio 門檻。

**結論:REJECT(v1)**。不是推翻架構,是矩陣與契約要照真機事實重寫一輪再審整份。下面每條都附證據與收法。

---

## 1. 矩陣缺的列、擁有權缺的資源(先列,找到的洞多半從這裡來)

### 1.1 缺的生命週期列

| 缺的路徑 | 為什麼要有 |
|---|---|
| **在 trial 槽(OTA 後未 commit)上認領 / 建網 / 加入,然後 autocommit revert** | B1 讓這條幾乎必發生(已認領未入網 → NEED_MESH=1 → revert);revert 回舊槽後 overlay 是未認領的,p5 是已認領的(詳 B3) |
| **96 掛不起 p5**(`96:89-92`:exit 0、「image defaults」、hook 被 disarm;2026-09-13 Build #2 真的發生過) | helper「缺檔就產生」會造出第二個身分(B3) |
| **factory reset 中途斷電**(p5 已清、overlay 未清;或反過來) | 219 §7 要求「清除日誌標記、開機續做」,本文件 L16 沒有 |
| **改名**(`state.apply(改名)`) | `99-halow-identity:22-25` 註明 openmanetd 開機後保留 IP「並重開一次」;記憶(#202 殘項)指出改 hostname 會讓 openmanetd 換 IP;SSID=hostname 只在 firstboot 設(`99-halow-identity:18-21`)。改名可能在 BLE session 中觸發重開 → M7 |
| **第二支手機 / 擁有者手機遺失 / 二手機** | §3 只有單數 `owner.pub`;協定 §3.4 是「最多 4 把 psk_owner」;219 §6.8 的「掃 QR + 按鍵(SD 標記)換擁有者」沒有列 |
| **BLE 與 WiFi AP 同一顆 CYW43455 同時運作**(B13) | AP 5 GHz(`uci show wireless`:radio0 band 5g ch36,節點 04 `phy1-ap0` 在跑)+ BLE 同時;要一列 + 測試(`prov-coex-254`:AP 上 iperf 同時 GATT 傳 8 KiB 訊息,量失敗率/延遲) |
| **bluetoothd 起來但沒有 hci0**(`.hcd` 缺、serdev 沒綁) | 4.6 只寫「log 一次」;provd 的行為(等多久、`halow-status` 怎麼說)沒寫 |
| **helper 在 `state.apply` 中途死掉 / 被 kill**(dropbear 已鎖、`state.cbor` 還是 unclaimed) | L7 只講斷電,沒講 helper crash;兩者後果不同(crash 後 procd 5 s 內 respawn,p5 沒存) |
| **OTA(sysupgrade)時 BLE session 還在** | app 看到的是斷線;要定義 provd 在 stage 1 被殺前要不要回一則「updating」 |
| **`network/update` 由成員轉送**(非擁有者 session)觸發 `halow-setkey` → `wifi reload` → 離網 | 202 §5「`wifi reload` 窗」那一列的 provd 版本 |
| **joinwatch / openmanetd / dpp-handler 重啟** | 矩陣只有 bluez/dbus/helper;joinwatch 重啟會重跑 `--on-join`(M2 的快取問題就在這) |

### 1.2 擁有權表缺的資源

| 資源 | 實際寫者 | 文件的說法 / 問題 |
|---|---|---|
| `$ST/mesh-expected` | **`batman-config-save`**(`:356-362`,`--seed` 與 `--on-join`)—不是文件寫的「joinwatch/meshjoin」;joinwatch 寫的是 `mesh-joined`(`joinwatch:48`) | §3 的「今天」欄寫錯 → L6 的推論建立在錯的事實上(B1) |
| `/etc/dbus-1/system.d/bluetooth.conf` | **bluez-daemon 套件**安裝(`bluez/Makefile:142-143`),內容是上游 `src/bluetooth.conf`,預設 `<policy context="default"><allow send_destination="org.bluez"/>` | 文件只列自己的 `batman-provd.conf`,沒意識到還有一份更寬的(M1) |
| `/etc/bluetooth/keys/`(= `/var/lib/bluetooth`,`bluetoothd.init:11`):IRK、LTK、adapter settings | bluetoothd | 沒列;`INSTALL_DIR` 預設 0755;`Privacy=device` 的 IRK 就放這 |
| `hci0 Powered` | bluetoothd(`[Policy] AutoEnable`)**與** provd(文件 §3 第一列) | 兩個寫者;選一個 |
| `/etc/dropbear/authorized_keys` 的**每一行** | 認領時 helper(擁有者 key?)、96(還原)、lab 操作員(`ssh-copy-id`) | 誰的 key 會在裡面、認領會不會清掉 lab key,沒寫(B2) |
| `/etc/shadow` root 行 | helper(認領)、96(還原)、操作員 `passwd` | 同上;`uci system.ttylogin` 也是 |
| `$ST/mesh-solo` | helper 寫 | **沒有清除者**(M5) |
| `identity/claimed.counter` | helper | 放在 factory reset 會清掉的目錄 → 「恢復出廠後要按鍵才開窗口」(219 §6.1)在階段 1 **不成立**;要明寫為階段 1 限制 |
| SD 卡標記檔(認領窗口 / 恢復出廠) | 誰讀(哪個 init、S 幾)、讀哪個分割(p1/p3)、讀完誰刪 | 只在 §3 一行帶過 |
| `/tmp/run/batman-prov/`(socket 目錄) | helper | 文件寫 `/var/run/...`;`rundir.sh:9-11` 明說「NEVER /var/run」(stage-2 ramfs 的 `/var` 是真目錄);ujail 掛載清單也要用 `/tmp/run/dbus/system_bus_socket`(節點:`/var -> tmp`) |

---

## 2. Findings

### BLOCKER

**B1. 「已認領未入網」的 OTA 一定被 autocommit revert;L6 與 §3 的前提和現行程式相反**
- 現場:使用者認領一台(還沒建網 / 加網),之後 OTA(或這台本來就在 trial 槽上被認領)。
- 證據:
  - `batman-autocommit:388-397` `expected_in_mesh()`:p6 無 marker 時掛 p5,**`.seeded` 存在就 return 0 → NEED_MESH=1**;`:460-466` 沒入網就 `why=mesh not joined` → 到 deadline revert。
  - `batman-config-save:397` 每個寫入模式(含 `--save`)都 `: > .seeded`;`:356-362` **`--seed` 與 `--on-join` 都寫 `mesh-expected`**。文件 §3 說 helper 認領後呼叫 `--seed` → 當場就有 `mesh-expected`,與同一表「helper 只在 `network/join` 成功時寫 mesh-expected」自相矛盾。
  - 219 §6.3 早就點名「現在『已認領、未入網』的節點 OTA 會一直 revert」是要改的;本文件把它寫成「helper 寫 mesh-expected 僅在 join 後」就當解決了。
- 後果:階段 1 的基本流程(認領 → 之後再建網)在任何 OTA 下都會 revert;再加上 B3,revert 回去的槽還會把認領弄丟。
- 收法:`expected_in_mesh()` 改成**先看 prov 狀態**(由 helper 以 `--apply-state` 或一個 root 0600 的 `$ST/prov-state` 摘要提供):`unclaimed`/`claimed`(未入網)→ NEED_MESH=0;`member` → 1,除非 `mesh-solo`(見 M5);找不到 prov 摘要才退回今天的 `.seeded` 規則(fail-closed 保留)。認領時用 `--save`(`:287-288` 已是 first-seed 路徑)不用 `--seed`,或讓 `mark_mesh_expected` 只在 `--on-join` 寫。負對照:`prov-autocommit-254` 要在**未改 autocommit 的 image** 上先證明 revert。

**B2. 認領的 SSH 鎖定在這個 image 上做不出來,做出來就是鎖死 —— 而且會先鎖死 02/04**
- 現場:app 認領 → helper 寫 `authorized_keys`、隨機 root 密碼、`PasswordAuth=off`、`--seed`。
- 證據:
  - firmware `.config:1583-1588`:`CONFIG_DROPBEAR_CURVE25519=y`、**`# CONFIG_DROPBEAR_ECC is not set`**、`ED25519=y`;節點 04 `strings /usr/sbin/dropbear | grep -iE 'ecdsa|ed25519'` 只有 `ssh-ed25519` / `sk-ssh-ed25519`。擁有者金鑰是 P-256(協定 §6)→ **dropbear 不認**。
  - `batman-config-save:151,350` `seed_key_ok()`:`--seed` 沒有 `^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-|sk-)` 開頭的行就 `exit 1` → 寫 P-256 進去(`ecdsa-sha2-nistp256 ...`)regex 會過、dropbear 不會;寫不進去 → p5 不 seed → `--check` rc 7 → OTA 被 C5 擋。
  - `96:164-172`:p5 有 `shadow-root` + 任一 `ecdsa-sha2-` 行就 `PasswordAuth=off`、`ttylogin=1`、LOCKED → **沒有任何能用的 key** = 只剩 serial(而 `console=ttyAMA0` 是 GPS 口,`inittab` `::askconsole` 會把 login 開在 NMEA 上)。
  - 節點現況:04 `UNPROVISIONED`、**沒有 `authorized_keys`**、root 空密碼、`PasswordAuth=on`;02 有一行 lab `ssh-ed25519`、root 空密碼。harness 與使用者是靠這個進去的。`prov-firstboot-254` 說「flash 04 → 認領」→ 04(跑 OTS)認領完就進不去了。
  - 219 §6.8 又說換擁有者時「清掉所有 `authorized_keys`」—— 沒有例外給 lab key。
- 收法(三件一起):(a) 寫明 `authorized_keys` 內容:階段 1 認領**不放**擁有者 P-256 key;SSH 的 key 另有來源(lab/操作員 ed25519,或 app 另產一把 ed25519 經安全通道送來——那又是一個新秘密要寫進 §7);(b) 階段 1 規則:認領**只追加、不清除**既有 `authorized_keys` 行,且 `/etc/batman-dev-open`(`96:165`)存在時 helper 的 `state.apply` 也不鎖(今天 96 就是這樣);(c) L1/L2/L5/L12 全部補上「認領後 lab 仍能 SSH」的斷言;B5(219)「dropbear 是否支援 ECDSA」在這裡**定案為否**。

**B3. overlay 與 p5 的 `prov/` 不一致時一律 overlay 贏,而 overlay 可能是未認領的 → 擁有權無聲遺失、窗口重開(fail-open)**
- 三個現場:
  1. **96 掛不起 p5**:`96:89-92` 印「p5 mount failed — image defaults」後 `exit 0` → uci-defaults 把 96 **刪掉**(只有 bypass 走 exit 1 留著)。helper 在 S89 看到空的 `/etc/batman-prov` → 依 §4.6「缺 keystore → 產生」→ 新 node.key、新認領秘密、`claimed.counter=0` → provd 廣播「未認領、窗口開」。之後 joinwatch `--on-join`(或任何 `--save`)把 `/etc/batman-prov` 複製進 p5 `prov/` → **舊身分與 owner.pub 被覆寫**。擁有者的 app 再也連不上(psk_owner 失敗),任何路人掃不到 QR 也不行、但有 QR 的人(店員、前任)可以認領。今天同一個 mount failure 只會讓 dropbear host key 換新,節點還進得去;加了 prov 之後代價變成「擁有權」。
  2. **trial 槽認領後 revert(B1 讓它常發生)**:認領寫在新槽 overlay + p5;revert 回舊槽,舊槽 overlay 是未認領(或舊狀態);96 不會再跑(overlay 不是 fresh);helper 以 overlay 為準 → 廣播未認領;p5 `prov/` 與 overlay 不同 → `--check` stale → OTA 被擋,直到某個 `--save` 把**未認領**狀態寫回 p5。這就是 #202 T10 的 prov 版本,文件 L6 的「今天」欄引用了 T10 卻沒把它套到 prov。
  3. **factory reset 中途斷電**(L16 順序「先清 p5 prov/ → 清 overlay → 作廢另一槽 → 重開」):p5 清了、overlay 還是 claimed → 下次開機 helper 以 overlay 為準,`--save` 又把 claimed 寫回 p5 → 恢復出廠被取消;反向(先 overlay 後 p5)則 96 把擁有者還原回來(219 §7 已點名)。
- 文件 L7 寫「狀態不一致時 helper 以 p5 還原的 overlay 為準」—— 這句話在上面三條路徑都是錯的方向。
- 收法:定義「**p5 `prov/` 是擁有權的 SoT,overlay 只是快取**」的規則,並由 96 留下**可被 hook/helper 讀的結果 marker**(`/etc/.batman-prov-restore = restored|absent|p5-unavailable`,root 0600;不能借用 `/etc/.batman-p5-restored`,它被 `99-halow-identity:7` 刪掉):
  - `absent`(p5 seeded 但沒 `prov/`,或 p5 未 seed)→ helper 可以產生身分;
  - `p5-unavailable`(掛不起、bypass)→ helper **不產生**、state=unknown(只 `status/public`),`halow-status` 紅字;
  - `restored` → 照 p5。
  - 非 fresh overlay 開機(96 沒跑):helper 開機時用 `batman-config-save --check` 的 prov 差異(M2 要先補)判定;p5 `prov/` 比 overlay **新**(例如 p5 claimed、overlay unclaimed)→ 以 p5 為準重建 overlay 再啟動,不是反過來。
  - factory reset:先在 **p6** 寫 `state/factory-reset.inprogress`(含步驟),開機看到就續做(219 §7 的要求);完成才刪。
  - 負對照:`prov-p5-mountfail-254`(fault-injection:把 p5 superblock 暫時弄壞或 `batman_bypass`→ 不該出現新身分)、`prov-trial-revert-254`(trial 槽認領 → 強迫 revert → 舊槽開機後 provd 仍廣播 claimed、`--check` fresh)。

### MAJOR

**M1. BlueZ 的 D-Bus policy 預設對所有本機 uid 開放 `org.bluez`;文件的 `batman-provd.conf` 擋不住**
- 證據:bluez-5.72 `src/bluetooth.conf`:`<policy context="default"><allow send_destination="org.bluez"/></policy>`;`bluez/Makefile:142-143` 把它裝到 `/etc/dbus-1/system.d/bluetooth.conf`;dbus `system.conf` `<allow user="*"/>`;節點 `/var/run/dbus/system_bus_socket` **0777**;dbus-daemon 以 root 跑(`ps`)。節點上的非 root 程序:`ubus`、`logd`、`network`(hostapd/wpa_supplicant)、`nobody`(gpsd、avahi)、`ntp`、`dnsmasq`;容器 uid 1000/999(OTS 五個容器,`net=ots-net`、非 privileged,目前沒掛 dbus socket)。
- 攻擊:任一個被攻陷的非 root 程序 `Properties.Set org.bluez.Adapter1 Powered=false`(BLE 消失 = 3A+ 唯一管理路徑消失)、`RegisterAdvertisement`(偽造「未認領 Batman 節點」廣播騙 app)、`RegisterApplication`(第二個 GATT 服務)、`RemoveDevice`。
- 收法:image **替換**上游 `bluetooth.conf`:刪掉 default-context 的 allow;`<policy user="provd">` 允許 `send_destination="org.bluez"`;root 保留(harness 用 `bluetoothctl`)。provd 端再驗 incoming method call 的 sender 是 `org.bluez` 的持有者。負測試 `prov-sec-dbus-254`:`start-stop-daemon -c nobody -x dbus-send -- --system --dest=org.bluez /org/bluez/hci0 org.freedesktop.DBus.Properties.Get org.bluez.Adapter1 string:Powered` → 必須 `AccessDenied`;先在未改 policy 的 image 證明會過。

**M2. `/etc/batman-prov/` 多檔狀態 vs `batman-config-save` 的快照:沒有互斥、快取與比對都看不到 prov/**
- 證據:`batman-config-save:188-218` `onjoin_fp()` 只算 PRESERVE + 4 個 identity 檔 + shadow;`:319-327` `same_identity()/p5_matches()` 只比 `identity/`;`:368-373` on-join 命中就「unchanged — skip」。文件 §4.3 只說 `--check` 把 prov 差異算 stale,沒說 fingerprint / `p5_matches`。結果:helper 改了 `/etc/batman-prov` 但 persist 失敗(p5 忙)→ 下個 tick `--on-join` 判「unchanged」永遠不補 → `--check` 卻說 stale → **OTA 永遠被擋**,訊息還叫人跑 `--save`。
- 互斥:joinwatch 每 tick `--on-join`(`joinwatch:145`)在 helper 改 `net/*.cose`、`members.cose`、`state.cbor` 的中間讀 → p5 拿到半套。helper 不能持 `cfgsave.lock`:`batman-config-save:118` 的接管規則是「cmdline 不含 `batman-config-save` 就當殘鎖接管」。
- 收法:可變狀態**單檔化**(`state.cbor` 內含 members/net 物件,tmp+rename+fsync;identity 檔只在產生時寫一次),或加 `prov/generation` 並讓 config-save 複製前後比對 generation 不一致就重試;`onjoin_fp` 與 `p5_matches` 一律納入 `/etc/batman-prov` 的 sha。D1 風格的並行測試(helper 緊迴圈改狀態 vs `--on-join`)要進 `prov-boot-254`。

**M3. Q1 內建開發 CA 私鑰 = 公開 repo 裡的假信任根;加上節點時鐘差一年,憑證效期也沒定**
- 證據:repo 公開;協定 §9 說開發版 app「只內建開發根」。CA 私鑰在二進位裡 → 任何人可簽「正牌開發節點」,SIGMA/NX 的節點身分驗證在階段 1 等於沒有(可冒充節點騙走網路密碼,219 安全 M1 的攻擊原樣回來)。它在內部是可接受的風險,但**不該用一把會長住的 CA**。時鐘:節點 04 `date` = **2025-07-15**(faketime 卡住),02 = 2026-10-16;兩台差 15 個月。helper 在 04 簽的 `node.cert` 若 notBefore=簽發當時,手機(真時間)沒事;但若節點時間跑在手機前面(faketime 上界被推過頭,或手機時區錯)就是 `not yet valid`,app 端(Rust webpki)預設會驗時間。
- 收法:階段 1 用**自簽 node.cert + app 認領時 TOFU pin**(認領秘密已把 app 綁到那台;CA 在這裡沒有多給任何東西),cert 內放明確的 dev OID/CN 前綴,release build 的 app 拒絕;效期固定 2020-01-01 → 2120(或 app 明寫不驗時間,照 219 P4「不依賴時間」)。Q1 的「內建 CA」選項請撤。

**M4. L12 降級/回滾的真實後果沒寫:已認領的節點回到 1.5.12 = 不可管理**
- 證據:舊 96 Lane A 還原 `authorized_keys` + `shadow-root` → LOCKED(`96:167-172`);AP 若是 placeholder → keyguard 關(`halow-keyguard:30-35`);mesh 若未入網也是 placeholder → radio 關;舊 image 無 BLE。= 無 AP、無 mesh、SSH key-only(B2 的 key)、serial 是 GPS 口。autocommit revert(B1)就是走這條路,不是罕見操作。
- 收法:L12 改寫為「降級後**只有** Ethernet(Pi 4)+ lab key 可達;3A+ 不可達」,並把 B2(b)的 lab key 規則當作 L12 的前提;`prov-downgrade-254` 加斷言「降級後 `ssh -i <lab key>` 可登入、`halow-status` 顯示 LOCKED」。

**M5. `mesh-solo` 沒有門檻、沒有清除者;autocommit 健康檢查沒有 BLE**
- 證據:`batman-autocommit:421-425` `health_ok()` 只看 `mesh11sd openmanetd wpad` 三個程序;`mesh-solo` 只要存在就 NEED_MESH=0 → 單台建網的節點 OTA 到一個 **radio 壞掉**(morse 驅動不載、channel 錯)的 image 也 commit。之後第二台加入、這台 members>1,`mesh-solo` 還在。219 §6.9 要求 autocommit 加 bluetoothd / provd / 廣播;本文件把它推到 S4,但 S3 已包含 OTA 路徑(L5),而 BLE 是這些節點唯一的管理面。
- 收法:`mesh-solo` 只在 `network/join` 的成員名單長度 = 1 時寫,名單 > 1、`network/leave`、factory reset 時刪;autocommit 看到 `mesh-solo` 時改要求「`iw dev wlh0 info` 是 mesh point 且 `mesh_id` 等於 uci」(用 `meshjoin.sh` 加一個 `meshjoin_radio_up`);`health_ok` 在階段 1 就加 `bluetoothd`、`batman-provd` 在跑 + `hci0` Powered(`btmgmt info` 或 D-Bus)。負對照:單台建網 → 故意 `uci set wireless.radio1.disabled=1` 的 trial → 必須 revert。

**M6. BLE 平台設定有一部分是寫出來的、不是查出來的:`main.conf` 鍵、bluetoothd init、kernel 模組範圍**
- 證據:
  - bluez-5.72 `src/main.c:60-140` 的合法鍵表**沒有 `Pairable`、`Discoverable`**(有 `AlwaysPairable`、`DiscoverableTimeout`、`PairableTimeout`、`ControllerMode`、`Privacy`、`JustWorksRepairing`、`AutoEnable`)。bluetoothd 對未知鍵只警告。實際行為:`adapter.c:9083-9092`——`AlwaysPairable=false`(預設)時,**沒註冊 agent 就 BONDABLE=0**;有 agent 才 1。所以「不裝 agent」才是真正的防線,文件該這樣寫,並由 provd 讀回 `Adapter1.Pairable==false` 當斷言。`ControllerMode=le` 確實送 `MGMT_OP_SET_BREDR 0`(`adapter.c:10290-10300`)✅。
  - `feeds/.../files/bluetoothd.init`:START=62、**沒有 respawn**、`ln -snf /etc/bluetooth/keys/ /var/lib/bluetooth`(IRK/LTK 落在 overlay,目錄由 `INSTALL_DIR` 建 = 0755;檔案 bluetoothd 自己 0600)。文件 4.6 說「bluez 套件自帶 init 要改」但沒列要改成什麼(我們自己的 init、respawn、目錄 0700、不要 `obexd`)。
  - `other.mk:30-57` `kmod-bluetooth` 一包帶 `BT_BREDR=y`、RFCOMM、BNEP、HIDP、btusb、btintel、btrtl;`bluez-daemon` 裝 `obexd`、`hciattach`、`hcitool`、`rfcomm`、`l2ping`、`gatttool`、`sdptool`。攻擊面增量段只寫「只開 LE」,kernel 側沒縮。
  - `.config:2779` `CONFIG_PACKAGE_kmod-bluetooth=m` 但節點 `/lib/modules` 沒有 → 目前根本沒進 image(R3 ✅)。
- 收法:自建 `kmod-batman-bt`(`BT_BREDR=n`、無 RFCOMM/BNEP/HIDP/btusb、`BT_HCIUART_BCM=y`);`bluez-daemon` 拆成只裝 `bluetoothd` + `bluetoothctl`;自己的 `bluetoothd` init(respawn、`/etc/bluetooth/keys` 0700、`main.conf` 只用合法鍵);`Powered` 只由 `AutoEnable=true` 管,provd 只讀。CVE:BlueZ 5.72 是 2023-12 的版本,S1 前查 NVD 對 ≥5.72 的 LE/GATT server 側修正並寫進 #247 清單。

**M7. 改名(`state.apply(改名)`)的連鎖反應未查、未列**
- 證據:`99-halow-identity:18-25`:SSID=hostname、`ahwlan.ipaddr` bootstrap、「openmanetd reserves the real IP after boot and reboots once」;#202 文件 §3 把 `hostname / ahwlan.ipaddr / dhcpconfigured` 的執行期寫者列為 openmanetd、操作員、provd;記憶(#202 殘項)記為「改 hostname = openmanetd 換 IP」。我沒有在真機改名驗證(唯讀審查),所以這條是「必須探針」:在 bench 節點 `uci set system.@system[0].hostname=…; uci commit; /etc/init.d/system reload`,看 openmanetd 的 log 與是否重開。
- 風險:BLE session 中改名 → 節點重開 → app 看到斷線、p5 是否已 `--save`、hostname 字元集(`valid_batch` 擋 `` `$();|&<>'``,但空白/UTF-8/長度 > 32 進 SSID 會壞)。
- 收法:改名列進矩陣(含 openmanetd 的 IP 重算與重開);helper 先 `--save` 再套用;hostname 白名單 `[A-Za-z0-9-]{1,32}`(SSID 32 B 上限);app 顯示「機台會重新啟動」。

**M8. L16 恢復出廠:順序、原子性、`.seeded` 殘留與階段 1 的認領窗口語意**
- 證據:`--wipe-prov` 只清 `prov/`,p5 仍 `.seeded` 且 `overrides.uci` 帶 mesh key / AP key / hostname → 「恢復出廠」後另一個人拿到的卡仍含你的網路密碼(219 §7 說「整個 p5」);`claimed.counter` 在被清的目錄 → 重置後窗口每次開機都開(219 §6.1 的保護在階段 1 不存在);沒有續做標記(B3 場景 3)。`batman-slot` 作廢另一槽「試用期拒絕」是對的,但另一槽 overlay 的清法(f2fs superblock 位置,`96:76-88` 註解)要引用。
- 收法:Q3 定案 `--wipe-all`(清 `prov/`、`overrides.uci`、`lkg/`、`identity/`、`.seeded`;**不 mkfs**);p6 續做標記;明寫「階段 1 恢復出廠後 = 新身分、新 QR、窗口每次開機都開(內部限制,608B 才解)」;destructive 測試含斷電點(p5 清後、overlay 清前)。

### MINOR

- **m1. 路徑拼法**:`/var/run/batman-prov` → `/tmp/run/batman-prov`(節點 `/var -> tmp`;`rundir.sh:9-11`);`/tmp/run` 是 root 0755(節點 `ls -ld`)所以非 root 不能預建,`O_NOFOLLOW`/owner 檢查留著當第二道;ujail 的掛載清單用 `/tmp/run/dbus/system_bus_socket`;新增 `provd` uid/gid(R12 沒有)並說明 `procd_add_jail` + `procd_set_param user`(`/etc/init.d/sysntpd:73-82` 的寫法)。
- **m2. 96 還原 `prov/` 的信任**:`cp -a` 會保留 symlink/特殊檔;p5 是實體信任等級但 96 以 root 執行,應只複製 regular file、強制 0700/0600、大小上限、`prov/version` 是純數字;`state.cbor` 壞但 `identity/` + `owner.pub` 完好 → 視為 `claimed`(未入網)而非 `unknown`,擁有者才救得回來。
- **m3. §3「LED 不碰」正確**,但 219 §2.4 的燈號表是 app 驗收的一部分 → 階段 1 殘項要明列「燈號不做」。
- **m4. SSID 與 hostname 綁定**:`99-halow-identity:18-21` 只在 firstboot;app 改名後 SSID 不變;要寫清楚哪個是真相。
- **m5. AP PSK 今天就是 world-readable**:節點 `/var/run/hostapd-phy1.conf` 0644 root(含 PSK)、`/etc/config/wireless` 0644(#13 已知)。§7 把 AP key 列為資產,請加「已知缺口 → #13」。
- **m6. `prov-sec-key-perms-254`** 應涵蓋 `/etc/bluetooth/keys`、`/tmp/run/batman-prov`、`$ST/prov-state`。
- **m7. provd 連線數 ≤ 2、未交握 10 s 擠掉**:BlueZ 不替你限,provd 要自己對多出來的 `Device1.Disconnect`;dbus policy 要允許 provd 呼叫它。
- **m8. 診斷包 `diag.bundle` 回 fd(SCM_RIGHTS)**:要寫 fd 是 helper 擁有的 `batman_tmp` 檔、O_RDONLY、provd 讀完 helper 刪。
- **m9. distroconfig `uart_enable=1`** 不是合法鍵(正確是 `enable_uart=1`);Pi 4 走 `miniuart-bt` 時韌體自己會開 mini UART,所以今天沒差,但 D12 的「core clock 固定」證據是 `vcgencmd` 500 MHz(04 實測),不是 overlay 內容(`miniuart-bt-overlay.dts` 沒有 core_freq,README 只說「lower baudrate」)。
- **m10. `.hcd` 檔名**:`hci_bcm` 會先找 `brcm/BCM4345C0.raspberrypi,4-model-b.hcd` 再退回 `brcm/BCM4345C0.hcd`;package 放哪個、3A+(`raspberrypi,3-model-a-plus`)同檔,寫進 S1。
- **m11. `ttylogin=1` + `console=ttyAMA0` = GPS 口**(節點 cmdline、`inittab ::askconsole`、gpsd 佔 ttyAMA0):LOCKED 後 login 會開在 NMEA 流上。既有問題(#105),但認領會把它觸發,矩陣要註。
- **m12. 測試負對照**:每個 `prov-sec-*` 寫了「先證明不加檢查會過」✅,但 L5/L12/L6 的負對照沒寫(B1、M4 給了);`prov-powerloss-254` 要指定斷電點在「dropbear 已鎖、state.cbor 未換」之間。
- **m13. 協定 §4.2 的冪等鍵**(10 分鐘、跨 session、32 筆)住在 provd 記憶體 → provd respawn 後消失;L8 要註明重送可能重做(`owner/remove` 的輪替會做兩次)。

---

## 3. 逐 actor 小結(§7 的補強)

| Actor | 文件有擋 | 本次發現沒擋 |
|---|---|---|
| 路人(BLE) | 匿名只 `status/public`、每連線 ≤ 3/5 次、8 KiB、簽章標籤 | 偽造廣播(M1 走本機;BLE 空中偽造本就擋不住,摘要只顯示用 ✅) |
| 本機非 root / 攻陷的 provd | socket uid 檢查、動詞 schema、ujail | **`org.bluez` 全開(M1)**;`hostapd.conf` 0644(m5) |
| 攻陷的容器(OTS uid 1000/999) | 自己的 netns、無 dbus socket | 若將來掛 host dbus 就等於 M1 |
| 實體拿到 SD | 明寫擋不住 ✅ | 但 B3 讓**不是**實體的人也能拿到擁有權(mount failure) |
| 供應鏈 | `.hcd` sha、#247 | **自己簽發的開發 CA 就是供應鏈風險(M3)**;bluez 套件多裝的工具(M6) |
| 我們自己 | 兩寫者互斥、tmp-trust | §3「今天」欄的事實錯(mesh-expected 寫者)、`main.conf` 鍵不存在、`/var/run` 拼法、矩陣缺 11 列 |

---

## 4. 需要在 v2 前做的唯讀探針(規則 4:「should be」不算證據)

1. bench 節點改 hostname → openmanetd 行為(M7)。
2. `tar` 出 `hci_bcm.c` 看 `.hcd` 檔名順序與 serdev `max-speed`(D1/m10)。
3. `bluetoothd -n -d` 在一台裝了 `.hcd` 的 04 上跑一次(S1 第一個 build),抓 `Adapter1.Pairable/Discoverable/Powered` 初值與 `btmgmt info` 的 BR/EDR 旗標 → 當 M6 的證據。
4. `/etc/bluetooth/keys` 建立後的實際 mode。
5. 04 的 faketime 為何停在 2025-07-15(與 02 差 15 個月)—— 不是本設計的錯,但 M3 的效期規則要以它為案例。

---

## 5. 判定

**REJECT(v1)**。

理由:B1–B3 都是「設計依賴的現行行為與原始碼相反」或「fail-open 在它要保護的那個資產上」,不是措辭問題;修完會動到 §3 擁有權、§4.3/4.4 契約、§5 矩陣(至少加 11 列)與 §7,所以 v2 要整份重審。可以直接保留的:helper/provd 分工、keystore 介面、schema 1 + `prov/version`、placeholder 規則、p5 單一寫者、`--apply-state` 邏輯只有一份、ujail、SO_PEERCRED、測試分層與「02 當 central」。

v2 最少要:B1(autocommit 以 prov 狀態判定)、B2(authorized_keys 內容與 lab key 規則、dropbear 無 ECDSA 定案)、B3(p5 為 SoT + 96 結果 marker + factory reset 續做標記)、M1(替換 `bluetooth.conf`)、M2(單檔狀態 + fingerprint 納入)、M3(撤內建 CA)、M5(`mesh-solo` 門檻/清除 + BLE 進 health_ok)、M6(合法 `main.conf` 鍵、自己的 init、縮 kmod)、M7(改名探針)、M8(`--wipe-all` + 續做);其餘 MINOR 可併入。
