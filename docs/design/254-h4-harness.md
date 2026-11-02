# Design: #254 PR-H4 — P3 的 harness(owner client、手機 relay、新卡試用、P3 測項)— **v1(審查中)**

**狀態**:v1,2026-11-02,審查中。
**上層**:`254-p3-impl.md` **v7.1(凍結,`feat/254-p3` @ dfedd03)**,以下簡稱 P3;`254-h23-harness.md` v14(H2 / H3 的機制,本設計沿用,不重述);`219-protocol.md` v0.7 + `.cddl`。
**流程**:P3 D1 規定 H4 照 v7.1 的契約寫、先 merge,P3 實作才開始。H4 走獨立的 harness PR(#290:測項只有一套,只從 harness PR 進 main)。

## 0. 一句話

H4 把 P3 §8 與附錄 D 的測項寫成可執行的單位。為此要先補齊三樣「打得到 P3」的工具:
1. **host 端的 owner client `peer.py`**(D2):真的完成 Noise 交握、認領、`auth/owner`、owner-op 簽章,再打 P3 的動詞。
2. **手機端 relay**:跑在使用者的 S20(Termux)上,讓 HTTP 從「手機 AP 上的 client」發出。
3. **新卡試用 lib**:把 chain1 的「另一槽新卡試用」抽成共用 lib,讓新卡臂可以重複跑。

另外還有:產品接縫的契約(由 P3 實作)、wsl.22 基準的負對照、pre-P3 的已知失敗條目,以及 H3 漏做的 `prov-eeprom-hooks-254`(D11)。

## 1. 決策、範圍、事實

### 1.1 使用者決策

| # | 決定 | 來源 |
|---|---|---|
| H4-U1 | HTTP 正向臂的 AP client 用使用者的 Android S20:Termux + sshd(只收專用公鑰 `batman-h4-phone`),Wi-Fi 常駐連在 04 的手機 AP 上;手機上不跑 Claude Code | #254 留言 6576525655 |
| H4-U2 | 新卡臂用 chain1 式的新卡試用(p5 快照 → mkfs → 另一槽不 seed → hold → 跑 → rollback / 還原),每輪 04 離開 mesh 約 60–90 分鐘、OTS 停;不必每次重燒 | 同上 |
| H4-U3 | BLE 傳輸用桌機的 Windows `bleak`(E-H1:掃描到 provd 的服務 UUID,強的一台 −55 到 −65 dBm) | #254 留言 6576687238 |
| (沿用) | P3 D1(H4 先 merge)、D2(host owner client)、D11(eeprom-hooks 併 H4)、D20(02 / 04 上機前重燒新卡)、D22(§9-4 探針在 H4 凍結前跑完);h23 的 lease、主機鎖、wbox、known-failures、P9 | P3 §1.1、h23 |

**本設計自己決定、審查者可以攻的點**:
- Q1:手機端只放一個無狀態的 relay(只用 Python 標準庫)。Noise、金鑰與判定都留在桌機,手機上不放任何秘密。
- Q2:`peer.py` 在 Windows Python 3.13 上跑:BLE 必須在 Windows 端,sock 與 HTTP 都經 `ssh` 子程序,所以三種傳輸共用一支程式。
- Q3:行為斷言盡量在 **release image** 上跑(BLE = bleak,HTTP = 手機)。只有需要接縫的負對照才在 `-wbox` 試用上跑。
- Q4:新文件,不併進 254-h23(那份已經 14 版)。

### 1.2 範圍

**本 PR**:
1. `peer.py` CLI 與三種傳輸(§2.1)。
2. 手機 relay `httprelay.py` 與 `scripts/dv/phone-254.sh`(§2.2)。
3. `scripts/dv/fresh-254.sh`:從 chain1 抽出的新卡試用 lib,chain1 改成 source 它(§2.3)。
4. P3 接縫的**契約**(§2.4);實作在 P3。
5. P3 §8 的 14 個單位,加上附錄 D 每一項的測試(§2.5)。
6. pre-P3 處理:known-failures 條目,以及 `--pre-p3-full` 負對照模式(§2.6)。
7. `prov-eeprom-hooks-254` 整個單位(H3 範圍第 8 項沒有做,F-H11)。
8. §9-4 探針腳本 `scripts/dv/http-src-probe-254.sh`(D22、附錄 D-1 / D-2);在 H4 凍結前、使用者在現場時跑。
9. CI:`peer.py --selftest`(向量)、`httprelay.py --selftest`、lint、tmp-trust allowlist。

**不在本 PR**:
- P3 的產品程式與 Go 單元測試、mutant(P3 §8 最後一段歸 P3)。
- U5 改名:`prov-settings-254` 的改名斷言在 U5 之前只斷言 `rename-pending`。
- YubiKey 實機:`prov-update-254` 的 bench 臂在使用者現場測過 YubiKey 前標 NEEDS-PERSON。
- bcm2710 真機(P-U14)。
- 晶片的國家換表(D21)。
- iPad / iOS(手動)。

### 1.3 事實(2026-11-02 實查;main 2ecf1cb;04 = `1.5.14-wsl.22+2ecf1cb.fwce20a68`)

| # | 事實 | 證據 |
|---|---|---|
| F-H1 | 04 的手機 AP iface 是 **`phy1-ap0`**(radio0 的 section `default_radio0`,SSID `BCM2711-6c89`);它與 `eth0`、`bat0` 同在 `br-ahwlan`(L2)。所以桌機(eth)經 04 的 bridge 可以直接到達 AP 上的手機(⚠️ 尚未實測,E-H8) | 04 `bridge link`、`iw dev`、`uci get wireless.default_radio0.ssid` |
| F-H2 | 桌機的上網走 Wi-Fi(預設路由 metric 0 + 35;乙太網路 256 + 25)→ 不拿桌機的 Wi-Fi 當 AP client | `Get-NetRoute` |
| F-H3 | 桌機 BLE:MediaTek 藍牙;bleak WinRT 掃描 30 s,掃到 2 個廣播 provd UUID 的裝置:一台 −55 到 −65 dBm,一台 −74 到 −94 dBm;RPA 會換。哪一台是 04 尚未確認(E-H9) | #254 留言 6576687238 |
| F-H4 | provd 的廣播只有 `ServiceUUIDs`,沒有 service data | `bluez.go:269` |
| F-H5 | `tests/tools/peer/` 有 `peer_core.py`(Noise / 信封)、`owner.py`(認領 / owner-op 計算)、`transport_sock.py`、`selftest.py`,**沒有 CLI、沒有接進 CI**(repo 裡沒有任何呼叫者) | `grep -rln peer_core scripts tests .github` |
| F-H6 | WSL 沒裝 `noiseprotocol`;向量的 requirements 已經把它 pin 住(含 hash) | `tests/vectors/219-protocol/requirements.txt:33` |
| F-H7 | Go 接縫目前只有 killpoint:prov_test build 在 daemon 啟動時讀 `/tmp/run/batman-prov-test/killpoint` 一次就刪掉;release build 沒有這些字串 | `seam/seam_provtest.go`、`seam/points.go` |
| F-H8 | shell 接縫:`fault()` = env `BATMAN_FAULT_INJECT` 或 root 擁有、非 symlink、link 1 的 `/tmp/batman-fault.<name>`(`batman_opf`) | `batman-slot:69-75` |
| F-H9 | `-wbox` image 永遠不會被 autocommit commit(held 的試用照樣回報 HELD) | `batman-autocommit:486-528` |
| F-H10 | 產品裡沒有回到 Unclaimed 的路(只有 Unclaimed / Legacy → Claimed → Member);新卡狀態只能靠 p5 mkfs | `node.go:514-539` |
| F-H11 | `prov-eeprom-hooks-254` 不存在(h23 範圍第 8 項沒做);shim 在 firmware 的 `files/sbin/persistent_vars_storage.sh`;1.5.12 的 image 在 `/home/yello/out/1.5.12-wsl.*` | `grep -rn eeprom-hooks scripts tests` 為空;`ls` |
| F-H12 | `SOCK_ONLY=1`(prov_test)時,provd 以 frame socket 代替 BLE,一條 sock 連線 = 一條 BLE 連線 | `testenv_provtest.go:1-30`;h23 §4.8.2 |
| F-H13 | **P3 文件自相矛盾**:§3.1.2 寫「key 20 經 HTTP → `E_UNSUPPORTED{2: 7}`」,§5.1、§8、附錄 C 寫 reason **19**。H4 照 §5.1(19);P3 實作的第一個 commit 要修 §3.1.2 的文字 | P3 `:183` vs `:481` |
| F-H14 | known-failures 的格式(第 4 欄必填 expires),以及「pre-P2 一行」的先例 | `validation-known-failures.txt:1-35` |
| F-H15 | chain1 的新卡試用:約 409 行;04 離開 mesh 60–90 分鐘;用 dead-man(p6 + B 的 rc.local,25 分鐘)把 04 帶回 A | `chain1-254.sh:1-30, 212-220` |

### 1.4 對 P3 的回報(不改 P3 契約,只回報)

- F-H13 的文字矛盾。
- **autocommit 的兩個接縫(`autocommit-noprov`、`provd-id-pid`)不能用 `/tmp` 旗標。** autocommit 在試用開機時就讀這些旗標,而 `/tmp` 不會撐過重開。所以它們要做成 `-wbox` 變體(`release` tag,只改 `batman-autocommit`),照 h23 §17 的 misc 變體先例。P3 §8 只寫了「接縫」,沒指定形式;本設計定為 wbox 變體(§2.4)。
- 附錄 D-11 要的 `uci` argv shim 也做成 wbox 變體(`uci-argv`)。

## 2. 元件

### 2.1 `peer.py`(host owner client,D2)

**位置**:`tests/tools/peer/peer.py`,import 既有的 `peer_core`、`owner`、`transport_sock`。

**執行環境**:Windows Python 3.13。依賴放在 `tests/tools/peer/requirements.txt`,pin 版本 + hash,裝的時候用 `--require-hashes`:`cbor2`、`noiseprotocol`(連帶 `cryptography`)、`ecdsa`、`bleak`。依賴的下載要使用者同意(§9);CI 用同一份檔。

**子命令**:每次呼叫印一行 JSON(`{"t":…, "rc":…, "code":…, "reason":…, "body":…}`);秘密一律只印 `short()`(SHA-256 前 16 hex)。
- `keygen`、`claim`、`replay`
- `auth`
- `call <type> <cbor-diag-json>`:任意動詞,給 `prov-p3-routes-254` 的動詞 × 角色矩陣用。
- `owner-add`、`owner-remove`
- `settings-get`、`settings-set <key> <value | @file>`:passphrase 只能從檔案讀,不進 argv。
- `status`、`diag-summary`
- `diag-bundle --out <file>`:多塊取回。
- `update-check <manifest> <E> <S>`、`update-prepare`、`update-apply`、`update-status`
- `bulk-open`、`bulk-close`
- `upload <file>`:只經 HTTP 傳輸。
- `raw <hex>`:負測試直接送位元組。
- `--selftest`

**傳輸**(`--via`):

| 傳輸 | 怎麼接 | 用在哪 |
|---|---|---|
| `sock` | `ssh root@04 provclient node sock-as 471 -- proxy /tmp/run/batman-provd-test/gatt.sock`(既有,`transport_sock.Proxy`) | `-wbox` 試用(`SOCK_ONLY=1`);接縫負對照與新卡試用 |
| `ble` | bleak:依服務 UUID 掃描,只連「`STATUS` key 5 = 目標節點序號末 4 碼」的那一台(RPA 會換,不能用位址);frame 層與 sock 相同 | release image 上的認領、key 20、只能經 BLE 的臂 |
| `http` | 經手機 relay(§2.2):`ssh -i <phone key> -p 8022 <phone> python httprelay.py <ip> <port>`;Noise 在桌機,relay 只搬 HTTP body | release image 上的 HTTP 臂、上傳 |

**Session 狀態**:擁有者金鑰、PSK 的輸入、tag key 寫進 `%LOCALAPPDATA%\batman-dv\prov-owner\<run>\state.json`。這個目錄的 ACL 只有使用者本人,與 h23 的 WSL 0600 檔等價。每個 run 用一個新目錄,run 結束時刪除(或保留到失敗分析,§7)。

**一次一條連線**(P3 §2「第 4 條連線留給 H4 的 provclient:最多 1 條,且不與 app 的讀取並行」):
- 主機鎖(`batman-dv-04.lock`,h23 既有)底下,provclient 與 `peer.py` 依序執行、不並行。
- 測額度的臂除外:額度本來就要並發,P3 §3.1.9 的額度也是對 app 的。這些臂明確寫在單位裡。

**判定**:`peer.py` 只回報線上的碼與內容;PASS / FAIL 由單位腳本比對 P3 §5.1 表。比對表做成資料檔 `tests/tools/peer/p3-expect.tsv`(動詞 × 情況 → 線上碼),由 P3 §5.1 逐列轉寫;lint 檢查列數與 §5.1 一致(P3 merge 後改成對 main 上的 P3 文件)。

### 2.2 手機 relay(S20 / Termux)

- `tests/tools/peer/httprelay.py`:只用標準庫(`http.client`、`sys`)。
  - argv 固定 `<node-ip> <port>`;**只連這一個位址**,其他一律拒絕。
  - stdin 一行一個請求:`REQ <id> <method> <path> <hdr-json-hex> <body-hex>` → `RSP <id> <status> <body-hex>`,或 `ERR <id> <connect|timeout|reset>`。
  - `PUT-FILE <id> <path> <local-file> <hdr-json-hex>`:上傳,檔案事先以 scp 放在手機。
  - 連線逾時 10 s、讀取逾時 30 s(上傳時 900 s)。
- `scripts/dv/phone-254.sh`(Git Bash,經 WSL 的 ssh,用 key `~/.ssh/batman_phone_ed25519`):
  - **`phone_preflight`**:四項都要過,任一不過 → **FAIL**(不是 SKIP):
    1. ssh 連得上,Termux 回 `uname -m`;
    2. 手機 MAC 在 04 的 `bridge fdb` 裡、port = `phy1-ap0`;
    3. 04 的 `hostapd_cli all_sta`(或 `iw dev phy1-ap0 station dump`)列出這個 MAC;
    4. relay 的 sha256 與 repo 相同。
  - **`phone_push`**:把 relay、上傳用的 payload 放到 `~/batman-h4/<run>/`。
  - **`phone_cleanup`**:刪 `~/batman-h4/<run>/`。
- **手機 MAC**:Android 對每個 SSID 用固定的隨機 MAC。第一次接上時由 `phone-254.sh discover` 從 04 的 station dump 記下,存在 host 設定檔 `%LOCALAPPDATA%\batman-dv\phone.conf`(MAC、手機 IP、Termux 使用者)。
- **key 20 臂怎麼讓手機連到新帳密**:Termux 沒有 root,不能替手機設定 Wi-Fi(Android 10 之後的限制)。改用**預存的第二個網路**:
  - 使用者在手機上預先存一個 Wi-Fi 設定 `batman-h4-alt`(SSID 與 passphrase 是測試值,放在 `phone.conf`,不是真的 AP 密碼),只做一次。
  - key 20 臂把 04 的 AP 改成這組值;Android 會自動連上已存的網路。用 preflight 第 2、3 項(MAC 出現在新 AP 上)證明「新帳密可連」。
  - 還原時 AP 改回原值,手機自動回到原網路。
  - ⚠️ Android 自動重連要多久、可不可靠,在 E-H10 實測;不可靠就把這一臂改標 NEEDS-PERSON。

### 2.3 新卡試用 lib(`scripts/dv/fresh-254.sh`)

- 從 `chain1-254.sh` 抽出步驟 1–5 與 9:snap、p5 idle / mkfs、hold + 套用 V 到 B(不 seed)+ reboot、找到 held 的新卡試用,以及 restore_all + dead-man。
- 對外提供的函式:
  - `fresh_begin <image>`:image 可以是 release V,或 V 的 `-wbox` 變體。
  - `fresh_ip`:回傳試用中的 IP。
  - `fresh_end`:回傳 PASS / FAIL;還原失敗就 FAIL,並且是 NEVER_KNOWN。
- `chain1-254.sh` 改成 source 這個 lib,不留兩份。**回歸要求**:chain1 在 wsl.22 上整個重跑一次,結果要與 H3 收尾時相同(59 PASS / 0 FAIL)。
- 新卡試用期間主機到 04 走 lab LAN(eth,chain1 既有);手機仍然經 eth0 → bridge 到得了(F-H1)。

### 2.4 P3 要提供的接縫(契約;H4 依此寫,P3 實作)

**Go 接縫**(只在 prov_test build):
- 檔案 `/tmp/run/batman-prov-test/fault`:root 0600、regular、非 symlink、link 1、≤ 256 B,每行一個名字,名字必須在封閉清單內。
- helper 與 provd 在**啟動時**讀一次,讀完不刪(與 killpoint 不同:一個 fault 持續整個行程的生命期)。每個生效的名字記一行 `fault <name>: armed`;不認得的名字 → 拒絕啟動(fail-closed,避免打錯字的負對照「沒生效卻 PASS」)。
- 寫者:`prov-wbox-254.sh set-fault`(root)。provd 在 jail 內讀不到 `/tmp/run/batman-prov-test` → provd 的 fault 由 init(root)讀進來,經 `procd_set_param env BATMAN_FAULT=<names>` 傳入,與 h23 §4.8.3 的 `provd.env` 同一條路。
- release build:沒有名字、沒有 `fault .*: armed` 字串(build gate 斷言,與 killpoint 相同)。

**shell 接縫**:沿用 `/tmp/batman-fault.<name>`(F-H8)。這個機制在所有 image 上都有,只有 root 能觸發(與現況相同)。

**wbox 變體**:只在**開機時**讀的檔案改用 image 變體(`tests/wbox/*.patch`、`helpers.list`)。

| 名字 | 形式 | 誰讀 | 關掉什麼 | 單位 |
|---|---|---|---|---|
| `http-nofw` | Go(helper) | helper | 不檢查 nft 表與 `phy*` 前提就給 `http.2` | prov-http |
| `healthok-2field` | Go(provd) | provd | 備援只看 bluetoothd + hci0_powered | prov-http |
| `ro-on-ctl` | Go(provd) | provd | app 的唯讀動詞走 ctl | prov-status-diag |
| `p5-autosave-off` | Go(helper) | helper | 不做「只因新 key 而 stale → `--save`」 | prov-update 升級臂、D-9 |
| `upload-noowner` | Go(provd) | provd | PUT 不檢查窗擁有者 | prov-upload |
| `upload-nosrcip` | Go(provd) | provd | PUT 不比對來源 IP | prov-upload |
| `upload-nobusy` | Go(helper) | helper | `otaBusy` 不看上傳窗 | prov-upload |
| `setkey-norollback` | shell | `halow-setkey` | `--rollback` 不還原 | prov-settings |
| `setkey-readback-skip` | shell | `halow-setkey` | 跳過 radio0 / hostapd 讀回 | prov-settings |
| `setkey-notrap` | shell | `halow-setkey` | 不設 `trap '' PIPE` | prov-settings |
| `slot-copy-all` | shell | `batman-slot` | 複製所有 boot 檔 | prov-update sysupgrade 臂 |
| `autocommit-noprov` | wbox(release) | `batman-autocommit` | 不看 helper / provd-stable | prov-autocommit-p3 |
| `provd-id-pid` | wbox(release) | `batman-autocommit` | provd 辨識 = peer pid == instance pid | prov-autocommit-p3 |
| `fw-badinclude` | wbox(release) | fw4 | 安裝一個故意寫錯的 `ruleset-post` 檔 | prov-fw-boot |
| `uci-argv` | wbox(prov_test) | — | `/sbin/uci` 外包一層 shim,把 argv 記到 `/tmp/run/batman-prov-test/uci-argv.log`(root 0600)(D-11) | prov-settings |

**規則**:每一個接縫在 P3 裡都要有單元測試,證明「沒設時行為不變」(release 路徑不受影響),P3 的程式碼審查會檢查。

### 2.5 單位

共通規則(h23 既有):
- 每個單位在 04 上都要先拿 prov lease,EXIT trap 負責還原。
- FAIL / INVALID / NEEDS-PERSON 照 h23 的定義:空的結果 = FAIL。
- 連線失敗、手機不在、BLE 找不到目標 → **INVALID**,不是 PASS。

| 單位 | image / 傳輸 | 主要臂(P3 §8 與附錄 D,逐列對表見 `tests/tools/peer/p3-units.tsv`) | 負對照 | 類型 / 估時 |
|---|---|---|---|---|
| `prov-p3-routes-254` | release;ble + http | 動詞 × 角色(匿名 / 候選 / 成員 / 擁有者)× owner-op 缺 / 錯 → §5.1 的碼;key 20 經 HTTP → `E_UNSUPPORTED{2: 19}` | wsl.22:全部 `E_UNSUPPORTED` | A,約 15 分 |
| `prov-owner-254` | release;ble + http | add / 重送輪替 / remove(BLE 與 HTTP session 都被切)/ 最後一位 | wsl.22 | A,10 分 |
| `prov-settings-254` | **新卡試用(wbox `test` + `uci-argv`)**;sock + http;另有已入網的 release 臂 | P3 §8 該列全部 + D-5 / D-6 / D-7 / D-13;密碼不在 cmdline(`uci-argv` log + `/proc/*/cmdline` 每 10 ms 取樣)、logread、log、診斷包;Wi-Fi / BT 共存量測(只記錄) | `setkey-norollback`、`setkey-readback-skip`、`setkey-notrap`、wsl.22 | 破壞性,約 120 分(含新卡試用) |
| `prov-country-join-254` | 新卡試用(與 settings 同一輪) + 02 | 國家不符 → 14,`.txn` 不在、uci 不變;先 key 2 再 join 成功;key 2 = `DE` 仍成功 | wsl.22(不比國家) | 破壞性,與 settings 同輪 |
| `prov-status-diag-254` | release;ble | status 與 halow-status 一致;成員只拿摘要;ro 10/s × 10 分鐘;bundle > 64 KiB 可解、不含秘密;handle 跨 session 被拒 | `ro-on-ctl`(wbox) | A,20 分 |
| `prov-bundle-gate-254` | release | claimed → 403;legacy 無旗標 → 403;unclaimed / legacy + dev-open → 200;`status` 仍 200(unclaimed 在新卡試用裡測) | wsl.22(全部 200) | A,5 分 |
| `prov-http-254` | release;http + ble;02 的 eth0 / docker0 / bat0 | 正向(手機)、備援開關、psk 角色、mesh 臂(拆成兩臂,D-4)、lo 臂、VLAN 臂(VID 0 雙層,D-1)、刪表 / reload / helper 停、D-8(bit 先清)、D-3 lint | `healthok-2field`、`http-nofw`、v6 規則、v5 規則 | 破壞性(停 bluetoothd、改防火牆),約 60 分 |
| `prov-upload-254` | release;http(手機) | P3 §8 該列;tmpfs 用量(不是檔案在不在);D-15 | 三個 upload Go 接縫(wbox)+ wsl.22 | 破壞性,約 40 分 |
| `prov-update-254` | release + wbox;ble + http | P3 §8 該列全部 + D-10 / D-14;四包惡意 tar 與 FIFO 由 `scripts/dv/data/` 產生器建 | `slot-copy-all`、`p5-autosave-off` | 破壞性,多次重開,約 150 分 |
| `prov-autocommit-p3-254` | wbox 試用 | P3 §8 該列 + D-16 / D-17 | `autocommit-noprov`、`provd-id-pid` | 破壞性,約 60 分 |
| `prov-transfer-tool-254` | WSL loop 檔 + 真卡(使用者的讀卡機) | P3 §3.9 | `--test-skip-wipe` | WSL 自動;真卡 = NEEDS-PERSON |
| `prov-luci-reset-254` | release | firstboot 之後擁有者 / mesh / AP 帳密仍在 | —(只驗文字與保留) | 破壞性,20 分 |
| `prov-fw-boot-254` | 常規全套,每次開機後 | 三張表都在;rc 驗收另跑 `fw4 print \| nft -c -f -`(bcm2711) | `fw-badinclude`(只在非 DUT、使用者同意、斷網) | A,1 分 |
| `prov-eeprom-hooks-254` | WSL,解開的 rootfs | `254-stage1-impl.md:487` 那一列 + D11 的 fresh-overlay 檢查 | 1.5.12 rootfs | CI / WSL,5 分 |

**手機在哪些臂上是必要的**:prov-http 正向、prov-upload、prov-settings「新帳密可連」、prov-routes 的 HTTP 半邊、prov-owner 的 HTTP session 被切。手機不在 → 這些臂 INVALID,其他臂照跑。

**新卡試用的順序**:一輪新卡試用裡依序跑 settings、country-join,以及 bundle-gate 的 unclaimed 臂,只付一次 60–90 分鐘的代價。

### 2.6 pre-P3 與負對照

- **pre-P3 判斷**:每個單位的第一步向 provd 送 `settings/get`;回 `E_UNSUPPORTED` 就是 pre-P3。
  - 這時只印一行 `FAIL <unit>: pre-P3 image (<version>)` 就結束。
  - known-failures 加對應條目,expires = P3 預估 merge + 14 天(估計值,照 pre-P2 先例)。
- **`--pre-p3-full`**:在 wsl.22 上把全部斷言照跑,證明單位分得出來。H4 PR 附這些輸出當負對照,每個單位都要至少有一條 FAIL 才算有鑑別力。
  - 例外:有些斷言在 wsl.22 上本來就成立,例如「表不在就不聽」(wsl.22 根本不聽)。這些斷言的鑑別改由接縫負對照證明,逐條標在 `p3-units.tsv`。

## 3. 擁有權

| 資源 | 唯一寫者 | 其他(唯讀) |
|---|---|---|
| 04 的狀態(uci、p5、slot、防火牆、AP 帳密) | 持有 prov lease 的單位(h23) | 其他單位、P9 |
| 04 的 AP 帳密在臂期間的變更 | key 20 臂;還原 = 它的 EXIT trap + lease dead-man(`wireless` 快照,root 0600) | 手機 |
| 新卡試用(p5 快照、B 槽、dead-man) | `fresh-254.sh`(chain1 共用,同一時間只會有一個) | — |
| 手機上的 `~/batman-h4/<run>/` 與 relay 行程 | `phone-254.sh` | — |
| 手機的 Wi-Fi 連線、Termux、電池、預存網路 | **使用者** | harness(只讀 / 只檢查) |
| 桌機 BLE adapter | `peer.py --via ble`(主機鎖底下,一次一條) | — |
| owner 狀態檔 | 產生它的 `peer.py` run | 同一 run 的單位 |
| 02 | 持有 02 central 鎖的 session(h23) | — |
| `/tmp/run/batman-prov-test/fault`、`/tmp/batman-fault.*` | 該單位(root,經 lease);EXIT trap 刪除 | P9 檢查殘留 |

## 4. 契約(新介面)

| 介面 | 寫 → 讀 | 格式 | 缺 / 舊 / 壞 | 誰寫得到 |
|---|---|---|---|---|
| `peer.py` 的 JSON 輸出行 | peer.py → 單位 | 一行一個物件;秘密只出現 `short()` | 不是 JSON / 缺 `code` → 單位判 INVALID | 主機上的使用者 |
| relay 的 stdin / stdout 行協定 | peer.py ↔ relay | §2.2 | 不認得的行 → `ERR`;relay 結束 → peer.py 判 Closed → INVALID | 持有手機 key 的主機 |
| `phone.conf` | 使用者 / `phone-254.sh discover` → 單位 | `key=value` | 缺 → 手機臂 INVALID 並印設定步驟 | 主機上的使用者 |
| `p3-expect.tsv`、`p3-units.tsv` | repo → 單位、lint | TSV | 列數不符 P3 §5.1 / §8 → lint FAIL | harness PR |
| Go fault 檔 | `set-fault` → helper / provd init | §2.4 | 不認得的名字 → 拒絕啟動;壞檔 → 不設 + 記一行 | root |
| wbox 變體 | firmware `build-board.sh --wbox` → 04 | h23 §4.2 | build gate | build 主機 |

## 5. 生命週期矩陣(harness 自己的路徑)

| 路徑 | 行為 | 測法 |
|---|---|---|
| 首次:手機沒設定 | `phone_preflight` FAIL,並印出設定步驟 | 主機設定檔不存在時跑一次 |
| 手機睡著 / Termux 被殺 | ssh 不通 → 手機臂 INVALID,其他臂照跑 | 關掉 Termux 跑一次 |
| 手機在跑一半時斷線 | relay `ERR` / Closed → 該臂 INVALID;EXIT trap 照樣還原 04 | relay 跑到一半殺掉手機的 sshd |
| key 20 臂中斷(主機死) | lease dead-man 從 `wireless` 快照還原 AP 帳密(h23 的 dead-man 加這一項) | 斷主機的 ssh,dead-man 觸發後讀回 uci 與 hostapd |
| 新卡試用中斷(主機死) | chain1 的 dead-man(25 分鐘)把 04 帶回 A;之後需要人跑 restore(chain1 既有,F-H15) | 重構後的 chain1 回歸;dead-man 臂沿用 chain1 的測法 |
| 04 非預期重開 | 單位 boot_id 對不上 → FAIL(不是 INVALID),並印 boot-reasons | — |
| BLE 掃不到目標 / adapter 關著 | INVALID + 印原因;preflight 列出 adapter 狀態 | 關藍牙跑一次 |
| pre-P3 image | 一行 FAIL(known) | wsl.22 上跑 |
| P3 rc 升級 / 回滾 | 單位只看當下 image 的版本;回滾到 wsl.22 → 又回到 pre-P3 一行 | — |
| 平台 bcm2710 | 不支援(P-U14);WSL / CI 的部分兩板相同 | — |

## 6. 測項(H4 自己的)

- **CI**:
  - `peer.py --selftest`:對 `gen.py` 的 transcript 逐位元組比對。負對照 = 刪掉一個比對 → FAIL。
  - `httprelay.py --selftest`:對本地 `http.server`;拒絕連別的位址;`PUT-FILE` 的大小。
  - `p3-expect.tsv` 的 lint、tmp-trust、shellcheck。
- **WSL**:`prov-eeprom-hooks-254`、`prov-transfer-tool-254`(loop 檔)、`fresh-254` 的離線 stub 測試。
- **實機,現在就能做**(wsl.22,legacy 04):
  - 每個單位的 pre-P3 一行;
  - `--pre-p3-full` 的負對照;
  - BLE 認出 04(E-H9);
  - 手機路徑(E-H8 / E-H10)。
- **實機,要等 P3 rc 與 02 / 04 重燒(D20)**:全部正向臂。

## 7. 安全

- **資產**:04 的控制權(root ssh、lease)、owner 私鑰與 PSK、04 的 AP 密碼、手機。
- **新攻擊面**:
  - 手機上的 sshd(埠 8022)。手機在家用 Wi-Fi、04 的 AP、行動網路上都會開著它。
    - 只收一把專用 ed25519 公鑰;設定步驟加 `PasswordAuthentication no`(Termux 的 `$PREFIX/etc/ssh/sshd_config`)。
    - 不用時使用者可以 `pkill sshd`。
    - 私鑰只在桌機 WSL 的 `~/.ssh/batman_phone_ed25519`(0600)。
  - relay:只連 argv 指定的位址,不轉送任意目標;它看得到 HTTP body,但 body 是 Noise 密文。`X-Batman-Session` 是 P3 本來就有的明文 bearer(P3 §3.8.2 的界線),手機看得到。
  - BLE:bleak 以未配對的 client 連線,不 bond,與 app 相同。
- **秘密**:
  - `bulk.open` 回的 AP 密碼、key 20 的新密碼、owner 私鑰都不進 log、不進 argv(passphrase 從檔案讀)。單位的斷言 grep 自己的 log,不能出現這些值(只比對 `short()`)。
  - `batman-h4-alt` 的密碼是測試值,不是任何真實 AP 的密碼。
- **權限**:接縫檔是 root 0600、非 symlink、link 1(既有的 `batman_opf` 規則)。非 root 寫不了,這由 P9 + `prov-sec` 既有的測試涵蓋。
- **失敗模式**:手機、BLE、relay 出問題一律 INVALID(fail-closed,不會變 PASS);還原失敗 = FAIL + NEVER_KNOWN。
- **負測試**:
  - `httprelay.py` 拒絕第二個位址(selftest);
  - 單位 log 不含秘密(grep);
  - 非 root 寫 fault 檔 → 被忽略並記 TAMPER(由 P3 的單元測試證明,H4 在節點上補一條)。

### 7.1 副作用(每輪)

- **04**:
  - 新卡試用一次:離開 mesh 60–90 分鐘、OTS 停、p5 快照後 mkfs 再還原、B 槽重寫;
  - prov-update:多次重開、A / B 重寫;
  - prov-http:停 bluetoothd 5 分鐘以上、改防火牆表;
  - prov-luci-reset:firstboot。
- **02**:prov-http 的 mesh / VLAN 臂從 02 送流量(MAC 偽造只在 02 的 eth0 這一臂);country-join 臂讓 02 入網。
- **手機**:AP 換帳密兩次(自動重連),payload 約 126 MB 放在手機上(run 結束時刪除)。
- **還原**:每一項都寫在單位的 EXIT trap 與 dead-man 裡,並列在單位檔頭(h23 慣例)。

### 7.2 成本(⚠️ 推估)

- 一輪 P3 全部單位:約 8–9 小時;其中 04 離開 mesh 約 2.5 小時、OTS 停約 3 小時。
- 依 P-U10,只在動到 prov 的 PR 與發版時跑。

## 8. 工作順序

1. 本設計 → 兩位審查,改到 0 BLOCKER / 0 MAJOR → 凍結。
2. 使用者同意 §9 的依賴下載後:`peer.py` 與 relay,加上 CI selftest。
3. E-H8 / E-H9 / E-H10 實測(手機要先設好)。
4. `fresh-254.sh` 抽出,chain1 在 wsl.22 回歸。
5. 各單位依序寫,每個在 wsl.22 上跑 pre-P3 一行與 `--pre-p3-full`。
6. §9-4 探針(使用者在現場)→ 結果回填 P3 F76 / D-1 / D-2 → **H4 凍結**。
7. harness PR(附全部輸出)→ 使用者 merge → P3 實作開始。

## 9. 待決 / 要使用者的

1. **依賴下載**(要使用者同意):Windows Python 的 `cbor2`、`noiseprotocol`、`cryptography`、`ecdsa`(`bleak` 已同意並安裝)。
2. 手機:照 `S20-termux-setup.md` 設定,另加兩件:
   - `PasswordAuthentication no`;
   - 預存 `batman-h4-alt` 網路(值到時候給)。
3. 現場事項:02 / 04 重燒新卡(D20,破壞性,先列步驟)、§9-4 探針、手機第一次連上 04 的 AP、YubiKey、U5。

## 10. 實測項目(E-H)

| # | 內容 | 狀態 |
|---|---|---|
| E-H1 | 桌機 BLE 收得到 provd | ✅ 掃描(F-H3) |
| E-H8 | 桌機經 04 的 bridge ssh 到 AP 上的手機;手機的 relay 連得到 04 的 AP 位址(用 04 上現有的埠,例如 uhttpd :80) | ❌ 等手機 |
| E-H9 | bleak 連線讀 `STATUS` key 5 認出 04;GATT frame 能來回 | ❌ 下一步(要連線,唯讀) |
| E-H10 | AP 換到預存的 alt 網路時,Android 會在多久內自動切過去 | ❌ 等手機 |
| E-H11 | 02 能不能建 VID 0 的 VLAN iface(VLAN 臂的發送端) | ⚠️ 部分:02、04 都是 `CONFIG_VLAN_8021Q=y`;`ip link add link eth0 name probe.0 type vlan id 0` 成功、立刻刪除(2026-11-02;這一步改了節點狀態,超出原本說的唯讀,已回報)。雙層(QinQ)與從 bat0 送出未測 |
