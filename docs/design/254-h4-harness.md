# Design: #254 PR-H4 — P3 的 harness — **v2(整份重寫,審查中)**

**狀態**:v2,2026-11-02,審查中。
- v1(a31489b)兩位審查都 **REJECT**:A = 2 BLOCKER / 8 MAJOR / 15 MINOR,B = 2 / 12 / 11(`254-reviews/h4-review-v1-{A,B}.md`)。
- v2 **整份重寫**,不是在 v1 上修補。v1 每一條意見的處理見附錄 B。

**上層**:
- `254-p3-impl.md` **v7.1(凍結,`feat/254-p3` @ dfedd03)**,以下稱 P3;
- `254-h23-harness.md` v14(以下稱 h23;lease、主機鎖、bind、dry-run、known-failures、P9 都沿用);
- `219-protocol.md` v0.7 + `.cddl`。

**流程**:P3 D1 規定 H4 照 v7.1 的契約寫、先 merge,之後才開始 P3 實作。H4 走獨立的 harness PR(#290)。

## 0. 一句話

H4 把 P3 §6 生命週期的每一列、§8 的每一條斷言、附錄 D-1…D-17,逐條做成單位與臂(附錄 A)。

每一臂都寫清楚五件事:
1. **在什麼載具上跑**(§2:committed release、committed + bind、真試用、新卡);
2. **怎麼誘發**;
3. **斷言什麼**;
4. **負對照是哪一種**;
5. **有什麼副作用、怎麼還原**。

要做到這些,需要四樣新工具:
- **WSL 上的 owner client `peer.py`**:秘密與判定都留在 WSL;
- **Windows 端的 BLE 薄橋**:只用 bleak;
- **常駐實驗室的 S20 手機 relay**;
- **新卡 lib**:chain1 步驟 1–6 + 可續期的 dead-man。

另外:
- bench 有一個定義好的基準狀態 **S0**,擁有者金鑰長期保存(§3)。
- P3 要提供的接縫與注入點寫成契約(§5)。

## 1. 決策、範圍、事實

### 1.1 使用者決策

| # | 決定 | 來源 |
|---|---|---|
| H4-U1 | HTTP 正向臂的 AP client 用 S20 + Termux sshd(專用公鑰) | #254 留言 6576525655 |
| H4-U2 | 新卡臂用 chain1 式新卡(不必每次重燒) | 同上 |
| H4-U3 | BLE 用桌機 Windows bleak(E-H1 掃描 ✅) | 6576687238 |
| H4-U4 | **S20 是備用機,常駐實驗室、常接電源**;可以為測試調設定(關行動數據、關其他網路的自動連線、MAC 用「手機 MAC」) | 2026-11-02 對話 |
| H4-U5 | 「從網路孔進來」的臂用 **04 本機模擬**(netns + veth 接進 bridge);真 eth0 驅動路徑列誠實界線 | 2026-11-02 對話 |
| H4-U6 | WSL venv 依 `tests/vectors/219-protocol/requirements.txt` 以 `--require-hashes` 安裝(已裝,F-H20) | 2026-11-02 對話 |
| (沿用) | P3 D1、D2、D11、D20(02 / 04 重燒成新卡)、D21、D22;h23 全部機制 | P3 §1.1、h23 |

**本設計自己決定、審查者可以攻的點**:
- Q1:協定核心在 WSL;Windows 只放 bleak 薄橋(B-M5 的建議做法)。
- Q2:接縫負對照都在 **committed** 槽上以 bind 執行;wbox 試用只用在「試用本身就是被測物」的地方(§2)。
- Q3:eth0 側的流量由 04 本機的 netns 模擬(H4-U5)。
- Q4:bench S0 由 harness 的長期擁有者 H0 持有(§3)。

### 1.2 範圍

**本 PR**:
1. `peer.py` 與三種傳輸、Windows 的 `blebridge.py`、手機的 `httprelay.py`(§4)。
2. `scripts/dv/phone-254.sh`、`scripts/dv/fresh-254.sh`(chain1 改成 source 它)、`scripts/node/prov-ethsim-254.sh`(netns / veth)。
3. bench S0:`prov-bench-s0-254` 單位(建立與每次斷言)與金鑰庫(§3)。
4. 附錄 A 的全部單位,以及 `tests/tools/peer/p3-units.tsv`(由附錄 A 產生,lint 對 P3 原文比內容,§6.3)。
5. T 簽章的軟體簽章器 `tests/tools/sign-test-release.py`;惡意 tar / FIFO / 壞 rootfs payload 的產生器(`scripts/dv/data/p3-payloads.sh`)。
6. §9-4 探針 `scripts/dv/http-src-probe-254.sh`(§7;H4 凍結的閘門)。
7. `prov-eeprom-hooks-254`(D11,§8.2)。
8. CI:`peer.py --selftest`、`blebridge.py --selftest`(假 BLE 後端)、`httprelay.py --selftest`、`p3-units.tsv` lint、tmp-trust allowlist、shellcheck。
9. pre-P3 處理與 known-failures 條目(§6.1)。

**不在本 PR**:
- P3 的產品程式、Go 單元測試與 mutant;
- 接縫的**實作**(P3 依 §5 做);
- U5 改名;YubiKey 實機(bench 臂 NEEDS-PERSON);bcm2710 真機(P-U14);晶片換表(D21);iOS;
- 真 eth0 驅動路徑(H4-U5 的界線)。

### 1.3 事實(2026-11-02 實查;main 2ecf1cb;04 / 02 = `1.5.14-wsl.22+2ecf1cb.fwce20a68`,都是 legacy)

| # | 事實 | 證據 |
|---|---|---|
| F-H1 | 04 的手機 AP iface = `phy1-ap0`(section `default_radio0`,SSID `BCM2711-6c89`),與 `eth0`、`bat0` 同在 `br-ahwlan`。沒有 `isolate`;`forward_ahwlan` → `accept_to_ahwlan`(計數器在跑);iptables FORWARD = ACCEPT;`br_netfilter` 已載入 → 桌機與 AP 上的手機在 L2 互通(⚠️ E-H8 仍要實測) | 04 `bridge link`、`iw dev`、`uci show wireless`;審查 B E6 |
| F-H2 | 桌機上網走自己的 Wi-Fi(預設路由 metric 0 + 35) | `Get-NetRoute` |
| F-H3 | 桌機 BLE:bleak WinRT 掃到 2 個 provd 廣播,一台 −55 到 −65 dBm;provd 的廣播只有 `ServiceUUIDs` | #254 留言 6576687238;`cmd/batman-provd/bluez.go:269` |
| F-H4 | **試用中,會改狀態的動詞一律 `EBusy`**(`claim.verify`、`net.apply`、`owner.*`、`settings.set`…);h23 規則「trial 內只能 restart 類」 | `node/node.go:198-206`;h23 `:255` |
| F-H5 | `-wbox` 永遠不 auto-commit | `batman-autocommit:485-530` |
| F-H6 | 回到 Unclaimed 的唯一辦法是 p5 mkfs | `node.go:514-539` |
| F-H7 | chain1:步驟 6 release → **B committed unclaimed**,步驟 8 才在 B 上認領;dead-man 種在步驟 6,固定 `sleep 1500`;held 試用期限 600 s | `chain1-254.sh:10, 275, 280-297` |
| F-H8 | prov lease 的 dead-man 契約:「It never touches a slot or p5」;有 `renew` | `scripts/node/prov-lease-254.sh:14-18, 9` |
| F-H9 | h23 的 bind 機制:`bind`、`push-helper`(bind prov_test helper → 一次 restart → 斷言 `--version` 標記、exe sha、`killpoint …: armed`)、`set-provd-env`(只在 prov_test image)、`unbind-all`、`upper-helper` | `scripts/node/prov-wbox-254.sh:1-25` |
| F-H10 | h23 §17 的 dry-run:在 committed 槽 bind 一個 `batman-autocommit` 變體,`AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1`,以 `DRYRUN decision` 判定 | h23 `:706-760` |
| F-H11 | prov_test 的 provd 只在 wbox image;provd 的 `--version` 沒有 prov_test 標記;`batman-provd-test.init` 的 `_provd_env` 只接受純數字的值 | `testenv_provtest.go:1-5`;`cmd/batman-provd/main.go:7, 53`;`batman-provd-test.init:26` |
| F-H12 | 只要有任何 BLE link 或 session,provd 就撤廣播;`rpa_timeout` 時重新註冊、換 RPA;GATT rx = write-without-response,tx = notify;inbound `MaxFrame = 512`、`OutFrame = 244` | `bluez.go:771-777, 233-236`;`provd/frame.go:12-17` |
| F-H13 | `peer_core` / `owner` 會 import `verify.py`,而它要 `pycddl`、`dissononce`、`cryptography.x509`;`transport_sock.Proxy` 在 pipe 上用 `select()`(Linux 可以,Windows 不行) | `verify.py:23-36`;`transport_sock.py:75` |
| F-H14 | 02 的 eth0 NO-CARRIER(沒接線),02 只經 bat0 到 04;02 沒有 python3 / arping / socat,只有 nc / ip / tcpdump;04 的 eth0 段上只有桌機 | 審查 A M4、B E7 |
| F-H15 | 04:`/sbin/ip` → `ip-full`(netns);`CONFIG_NET_NS=y`、`CONFIG_VETH=m`(已載入)、`CONFIG_VLAN_8021Q=y`、`CONFIG_BRIDGE_VLAN_FILTERING=y`(`br-ahwlan` 未啟用);有 `nc`;沒有 arping / python3 / socat / unshare | 04 唯讀,2026-11-02 |
| F-H16 | 04 的 kernel cmdline 有 `panic=10`;procd 的硬體 watchdog 在跑(timeout 30 s) | 04 `/proc/cmdline`、`ubus call system watchdog` |
| F-H17 | 只存在 overlay 的東西(OTS payload init、dockerd / tailscale 的 rc.d)firstboot 會清掉;`firewall stop` 會刪掉所有 nft 表,含 docker 的 `ip filter` / `ip nat` | 審查 B E11、E6 |
| F-H18 | `strip-p5-prov`(h23)在快照內把 p5 的 prov 紀錄拿掉 → 造出 legacy 狀態 | `prov-base-254.sh:12, 256-266` |
| F-H19 | P3 文件矛盾:`:168`(§3.1 第 2 點)寫 key 20 經 HTTP → reason 7;§5.1 / §8 寫 19。H4 照 19 | P3 `:168` vs `:481` |
| F-H20 | WSL venv `~/.batman-dv/peer-venv`:`verify.py` 197 checks ALL PASSED;`peer` selftest 29 checks ALL PASSED;cryptography 50.0.2 | 2026-11-02 |
| F-H21 | known-failures 只看 `FAIL` 行;pre-P2 的先例是看結構(「no batman-provd on 04」),不是看產品的回應 | `validation-known-failures.txt:25-35`;`known-failures.sh` |
| F-H22 | CI 沙箱 `dv-sbx`(arm64、真的 helper 以 root 跑)已存在 | `.github/workflows/ci.yml:162-179` |

### 1.4 回報給 P3(P3 實作的第一個 commit 處理,不改契約的語意)

1. F-H19 的文字。
2. §5 的接縫契約,特別是這幾項:
   - **T 的信任編進 prov_test helper 的二進位**(build tag),不是 image 上的檔案,這樣在 committed release 槽 bind prov_test helper 就能用 T;
   - provd 的 `--version` 加上 prov_test 標記;
   - `batman-provd-test.init` 接受 `BATMAN_FAULT` 的名字值;
   - 新增的注入點與 killpoint 名字。
3. `prov-fw-boot` 的 rc 閘門 `fw4 print | nft -c -f -`:H4 在 bench 上提供腳本。

## 2. 載具(每一臂標一種;附錄 A 的「載」欄)

| 代號 | 載具 | 能做什麼 | 不能做什麼 |
|---|---|---|---|
| **R** | committed release(S0) | 黑箱正向:BLE / HTTP 上的所有動詞(會改狀態的也可以) | 接縫 |
| **RB** | R + bind:`push-helper`(prov_test helper,信任 T、Go fault / killpoint)、`push-provd`(新:prov_test provd + test init,§5.3)、`/tmp/batman-fault.*`、檔案 bind(`uci-argv` shim、`batman-autocommit` 變體) | 接縫負對照、注入、T 簽的 pending、上傳窗、update 主臂的起點 | 重開後 bind 就消失:觀察點在重開前,或用 update-last / `upper-helper` |
| **RD** | RB + autocommit dry-run(h23 §17) | autocommit 的判定(`DRYRUN decision: COMMIT/REVERT`) | 真 commit |
| **T** | 真試用:經 app 路徑寫入、T 簽的 payload(由 RB 的 helper 接受),重開進試用 | update 的 phase 4 / 5 / 6、autocommit 真 commit / revert、D-9 | 試用中改狀態(F-H4) |
| **W** | wbox held 試用 | 只用在「試用本身是被測物、不需改狀態」的臂:`fw-badinclude`(在 02) | 認領、改狀態、commit |
| **F** | 新卡:`fresh-254.sh`(chain1 1–6 → B committed unclaimed),之後在 F 上再用 R / RB | 新卡 → 認領 → key 20 / key 2 / join、`unclaimed` 的 CGI、luci reset(只動 B) | — |
| **L** | legacy:R + 快照內 `strip-p5-prov`(F-H18),以 legacy 身分認領 | legacy 的 key 2 / 20 → 20、legacy CGI | — |
| **C** | CI / WSL(沙箱、loop 檔、解開的 rootfs) | 兩板共用的 shell、eeprom-hooks、轉賣工具 loop 臂 | 真無線 |

**flip 規則**(B-M2):每組正 / 負對照只差一個變數,也就是同一個載具、同一個 image,只差接縫,或只差 image(wsl.22 對 P3)。

## 3. Bench 基準狀態 S0 與金鑰庫(B-B2、A-M6)

### 3.1 S0 的定義

D20 重燒之後,由 `prov-bench-s0-254 provision` 建立 S0(使用者在場時做一次):

| 項目 | S0 值 | 誰設 |
|---|---|---|
| 04、02 的狀態 | 都是 claimed → member,`RadioManaged = true` | `peer.py`(BLE 認領) |
| 擁有者 | 每台兩位:**H0**(主)、**H0b**(備用,D17) | `peer.py` claim + `owner/add` |
| 網路 N0 | 02 + 04,國家 US、ch 與現在 fleet 相同,mesh key = 新產生的測試值 | `peer.py` `network/join`(依 `provgen.py`) |
| 04 的手機 AP | SSID / passphrase = **C0**(測試值,不是任何現場密碼) | `peer.py` key 20(BLE) |
| 02 的手機 AP | C0' | 同上 |
| 手機 | 已存 C0(04)與 ALT(測試值)兩個網路;MAC 類型 = 手機 MAC | 使用者(一次) |

**每個單位**:
- 開始前,`s0_assert` 確認 S0:
  - `status` = member;
  - H0 的 `auth/owner` 成功;
  - `settings.get` 的 SSID = C0;
  - root 讀 hostapd conf 的 sha = 庫裡的值。
- 結束時還原並再斷言一次。
- 不成立 → 該單位 **INVALID**,並印出重建步驟。一個不成立的 S0 不會被當成任何單位的 PASS。

### 3.2 金鑰庫

**位置**:WSL `~/.batman-dv/bench/`(0700,檔案 0600;WSL ext4 的權限位元有效,不放在 Windows)。

**內容**(每個節點):
- H0 / H0b 私鑰;
- tag key;
- `adv_owner_key` 的最新值;
- N0 的 `net_config` 與 mesh key;
- C0 / ALT;
- 每次輪替的日誌。

**先寫意圖再寫節點**(B-B2):會輪替節點端秘密的動作(`owner/add` 重送、`owner/remove`、key 20、`network/*`),順序是:
1. 先把「意圖 + 新值」寫進 `journal.cbor`(fsync);
2. 再送出;
3. 成功後改寫成「已套用」。

中斷後的下一個 run 先讀 journal:新、舊兩組都試(`auth/owner`、讀 SSID),哪一組成立就以那組為準。

**備份**:每次改動後,把整個庫以 `tar` 寫一份到 Windows `%LOCALAPPDATA%\batman-dv\bench-backup\`。程式設定 ACL(只限目前使用者,去掉繼承),並以 `icacls` 讀回斷言;沒有通過就 FAIL。

**H0 與 H0b 都遺失時**:只能重燒(D20 流程)→ 要使用者在場。這寫在 §11。

**臨時擁有者**:`prov-owner` 的 add / remove / 最後一位等臂,只對**臨時加入的擁有者 Hx** 做,H0 / H0b 不動。「最後一位」臂在快照內:`owner/remove` H0b、H0、Hx 的順序 → 斷言 → 由快照還原 p5 → `s0_assert`。

### 3.3 S0 的生命週期

| 路徑 | 行為 |
|---|---|
| 首次(D20 之後) | `provision` 建 S0,使用者在場:燒卡、手機存網路 |
| 每個單位 | 開頭斷言、結尾還原 + 斷言 |
| 單位中斷(主機死) | lease dead-man(F-H8,不碰 p5)只做 unbind 與重啟服務;p5 / AP 的還原由下一個 run 的 `pr_begin` 偵測 dirty → 印出 restore 指令(h23 既有) |
| 金鑰輪替中斷 | journal(§3.2) |
| 回到 wsl.22(負對照基準) | 在 F 載具上做(wsl.22 的新卡),不動 S0 |

## 4. 元件

### 4.1 `peer.py`(WSL,D2)

**執行**:`~/.batman-dv/peer-venv/bin/python tests/tools/peer/peer.py`,沿用 `peer_core`、`owner`、`transport_sock`(Linux 的 `select` 可用,F-H13)。

**輸出**:每次呼叫印一行 JSON:`{"t", "via", "rc", "code", "reason", "body"}`。
- 秘密欄位一律只印 `short()`。
- 秘密欄位的清單寫死在 `peer.py`:`bulk-open-resp` 的 key 2、`owner/add` 回的 tag key、PSK、認領輸出、`settings.set` 的 key 20 值、`net_config` 的 mesh key。
- selftest 斷言:對每一種回應,JSON 輸出裡都找不到原值。

**子命令**:
- `s0 provision|assert|restore`
- `claim`、`auth`
- `call <type> <cbor-diag>`
- `owner-add|owner-remove`
- `settings-get|settings-set`:passphrase 只從庫或檔案讀
- `status`、`diag-summary`、`diag-bundle`
- `update-check|prepare|apply|status`
- `bulk-open|close`、`upload`
- `raw <hex>`
- `load ro <rate> <secs>`
- `--selftest`

**傳輸 `--via`**:
- **`sock`**:`ssh root@<node> provclient node sock-as 471 -- proxy <gatt.sock>`(既有)。只在 RB 的 `push-provd SOCK_ONLY` 用(不會用在需要 BLE 廣播的斷言)。
- **`ble`**:WSL 經 interop 起 `py.exe -E -P blebridge.py`。
  - 協定:一行 hex = 一個 frame;控制行 `SCAN`、`CONNECT <last4>`、`MTU`、`CLOSE`。
  - Windows 端只看得到 Noise 密文與公開的 `STATUS`,**秘密不經 Windows**。
- **`http`**:`ssh -i ~/.ssh/batman_phone_ed25519 -o UserKnownHostsFile=~/.batman-dv/phone_known_hosts -o StrictHostKeyChecking=yes -p 8022 <user>@<phone-ip> python ~/batman-h4/<run>/httprelay.py <node-ip> <port>`。

**連線規則**:
- 主機鎖底下只有一個單位在跑。
- `peer.py` 的 BLE / HTTP session 數由單位決定:例如 `prov-owner` 同時開 BLE + HTTP 是刻意的。
- P3 §2「第 4 條 helper 連線最多 1 條」是給 **provclient → helper** 的。H4 遵守的方式是:provclient 與 app 的唯讀負載不並行;測額度的臂除外,單位裡會明寫。

### 4.2 `blebridge.py`(Windows,bleak)

**認目標**:
1. 掃描服務 UUID;
2. 依 RSSI 由強到弱逐一連線;
3. 讀 `STATUS`(未加密的 read),key 5 = 目標序號末 4 碼才留下,否則立刻斷線。

- 連到 02 時,02 會短暫撤廣播(F-H12)。主機鎖底下沒有別的單位在用 02,所以這不會干擾別人;仍然記錄在副作用裡。
- RPA 換了 → 重新掃描並驗證(每次 `CONNECT` 都重驗)。

**frame 大小**:MTU 談完之後(bleak 的 `max_write_without_response_size` 穩定兩次讀值),frame = `min(244, CTRL key 3, max_write_without_response_size)`,永遠 ≤ 512(F-H12)。

**notify**:用 `start_notify`(CCCD)。write 用 `response=False`。

**Windows 配對提示**:provd 不要求配對;如果出現配對提示 = FAIL(不該發生)。

**出錯時**:
- link 掉了 → 印 `CLOSED`,`peer.py` 判 Closed。
- key 20 臂(Wi-Fi reload 可能讓 BLE 斷,P3 §9-8):Closed = outcome unknown → 重連並讀 `settings.get`,依讀回判定;不判 FAIL 或 INVALID(P3 §5.2)。

**selftest**:假後端(不碰 bleak)驗證行協定、frame 大小計算、認目標的流程。

### 4.3 手機:`httprelay.py` 與 `phone-254.sh`(H4-U4)

**手機設定**(使用者一次,寫在 `docs/validation/s20-setup.md`,本 PR):
- Termux(F-Droid),外加 **Termux:Boot**,開機自動起 sshd + wakelock。
- `authorized_keys` 那一行加 `no-port-forwarding,no-agent-forwarding,no-X11-forwarding`;`PasswordAuthentication no`;不執行 `termux-setup-storage`。
- 行動數據關閉;家用 Wi-Fi 刪除,或關掉自動連線;只留 C0 與 ALT 兩個網路,兩者 MAC 類型都設成「手機 MAC」。
- 電池「不受限制」、永不睡眠。
- 常接電源,放在 04 旁邊。

**host key**:第一次由 `phone-254.sh pin` 抓 host key,寫進 `~/.batman-dv/phone_known_hosts`。之後 `StrictHostKeyChecking=yes`;key 變了 → FAIL。

**手機 IP**:每個 run 依手機 MAC 從 04 的 `ip neigh` / `bridge fdb` 找,不存。

**relay**(只用標準庫):
- argv 固定 `<node-ip> <port>`,只連這一個位址。
- `REQ` / `PUT-FILE` 行協定。
- 錯誤分類:`refused`(RST)、`timeout`(丟棄)、`unreach`、`reset`,讓「沒在聽」與「被防火牆丟」分得開。

**`phone_preflight`**:任一項不過 → 手機臂 **INVALID**(單位照跑其他臂):
1. ssh 連得上(釘住的 host key);
2. 04 的 `hostapd_cli -i phy1-ap0 all_sta`:手機 MAC 的 flags 含 **`AUTHORIZED`**;
3. 手機 MAC 在 04 的 `bridge fdb` 上,port = `phy1-ap0`;
4. relay 的 sha256 = repo 的版本;
5. **relay → `<node-ip>:80` 拿到 HTTP 200**(證明手機的流量確實走 04 的 AP,B-M4-2)。

**同路徑正向對照**(A-M3-5):每個經手機的負向斷言(「連不上 8095」),都在**同一臂內、緊接著**做 relay → 04:80 = 200。沒有這一步 → INVALID。

**key 20「新帳密可連」**拆成兩條(B-m7):
- (a) 節點端:≤ 30 s 內 hostapd 的 SSID = 新值,`phy1-ap0` 起來 → 這是產品的斷言;
- (b) 手機端:≤ 180 s 內手機 MAC 在新 AP 上 `AUTHORIZED`,且 relay → 04:80 = 200 → 這是手機的行為;超時判 **INVALID**,不判產品 FAIL。

用法:新值 = ALT;還原 = C0,還原後同樣要通過 (a)(b)。

### 4.4 新卡 lib:`fresh-254.sh`(A-B2、B-B1)

**做什麼**:抽出 chain1 的步驟 1–6,以及步驟 9(restore_all):
- snap(含 overlay 快照)、p5 idle / mkfs;
- hold + 套用 **release V** 到 B(不 seed)+ reboot → held 試用;
- **release → B committed unclaimed**;
- 回傳 B 的 IP(`find04`)。

**之後的動作**都在 committed 的 B 上做:認領、key 20 等;也可以在 F 上再疊 RB。

**dead-man 改成可續期**(A-B2、B-M8):
- p6 `fresh-deadline`(root 0600):一行 `<run> <uptime 秒>`。
- B 的 rc.local 與一個 setsid 迴圈每 60 s 檢查;超過期限就執行 chain1 既有的 `ch1-deadman.sh`(restore → A)。
- 主機每 ≤ 10 分鐘續期一次(寫 now + 30 分)。

**chain1 改成 source 這個 lib**。回歸要求:
- wsl.22 上 chain1 整個重跑,結果要與 H3 收尾時相同(`chain1-254` 59 PASS / 0 FAIL);
- 加兩個 dead-man 臂:
  - 不續期 → 30 分後 restore 發生(04 回到 A);
  - 有續期 → 60 分內沒有 restore。

**新卡的 AP 被 keyguard 關著**(P3 F74):key 20 之前所有手機臂 INVALID 是預期的,所以手機臂只排在 key 20 之後。

**新卡期間 02**:04 離開 N0,主機只能經 eth 連 04。`prov-country-join` 要用 02 的那一半時,要先讓 04 以 N0 的 `net_config` join,回到 mesh 之後再拿 02 的 central 鎖。

### 4.5 eth0 側模擬:`prov-ethsim-254.sh`(H4-U5)

在 04 上,lease 底下執行:
1. `ip netns add h4x`;
2. `ip link add h4v0 type veth peer name h4v1`;
3. `h4v0` 接進 `br-ahwlan`(與 eth0 同一種「非 `phy*`」port);
4. `h4v1` 移進 netns,設一個 `10.41.250.<n>/16`。

**各臂**:

| 臂 | 做法 |
|---|---|
| mesh / eth 臂 | netns 內 busybox `nc` 迴圈連 `<04>:8095`(50 conn/s × 10 分) |
| VLAN 臂(D-1) | netns 內 `ip link add link h4v1 name q0 type vlan proto 802.1ad id 0` 再疊 `type vlan id 0`,從 `q0.0` 送 SYN |
| 偽造手機 MAC 臂(D-4,只驗連不上) | `h4v1` 的 MAC = 手機 MAC。04 的 fdb 會把手機 MAC 學到 `h4v0` → **手機斷線**:這一臂與手機臂不重疊,結束後刪 veth,由手機 ping 04 讓 fdb 學回來,再跑 `phone_preflight` |
| docker 臂 | 第二組 veth 接進 `br-ots`(容器的 bridge),同樣從 netns 送;不動任何容器 |
| lo 臂 | 04 本機 `nc 127.0.0.1 8095` 與 `nc <br-ahwlan IP> 8095` |

**還原**:`ip netns del h4x`、`ip link del h4v0`(以及 br-ots 那組)。EXIT trap 做一次;**lease dead-man 也做**(擴充它的契約:只刪 `h4*` 的 veth / netns,不碰 slot / p5)。P9 檢查殘留。

**誠實界線**:真 eth0 驅動的接收路徑(含網卡的 VLAN offload)沒有涵蓋。veth 也會經過 `__netif_receive_skb` 的 VLAN 處理,但沒有網卡驅動那一段。

**⚠️ E-H15**:veth 接進 `br-ahwlan` 會不會影響 mesh、helper 的 `phy*` 前提檢查。名字不是 `phy*`,依 P3 §3.8.1 不影響;仍需在 lease 底下實測一次。

## 5. P3 要提供的接縫、注入點與標記(契約)

### 5.1 Go fault(只在 prov_test build)

**兩個檔**(A-m2a):
- `/tmp/run/batman-prov-test/fault.helper`:helper 啟動時讀;
- `/tmp/run/batman-prov-test/fault.provd`:由 `batman-provd-test.init`(root)讀,經 `procd_set_param env BATMAN_FAULT=<a,b>` 傳給 provd;init 接受 `[a-z0-9,-]{1,128}`。

**檔案規則**:root 0600、regular、非 symlink、link 1、≤ 256 B,每行一個名字。各元件有自己的封閉清單:
- 認得的名字 → 記 `fault <name>: armed`(本次 pid);
- 不認得的名字 → 記 `fault <name>: unknown, ignored`。不拒絕啟動,以免 crash loop(B-M1-4);單位要求每個要的名字都有 `armed` 行,打錯字的結果是 INVALID。

**開 / 關**(B-M1-1/2/3):
- 開 = 寫檔 → 重啟該 daemon → 斷言本次 pid 的 `armed` 行(provd 另外斷言 `/proc/<pid>/environ`)。
- 關 = 刪檔 → 重啟 → 斷言新 pid **沒有** `armed` 行、environ 沒有 `BATMAN_FAULT`。
- `unbind-all` 與 lease dead-man 都做「關」。P9 檢查**執行中行程**的 environ 與 log,不只看檔案。

**重啟的副作用**(單位要算進去):
- helper 重啟:重跑開機邏輯(P3 F42)、上傳窗消失、上傳檔被刪;
- provd 重啟:session 斷、廣播撤掉再重來。

**名字**:

| 名字 | 元件 | 關掉什麼 |
|---|---|---|
| `http-nofw` | helper | 不檢查表與 `phy*` 前提就給 `http.2` |
| `p5-autosave-off` | helper | 不做「只因新 key 而 stale → `--save`」 |
| `upload-nobusy` | helper | `otaBusy` 不看上傳窗 |
| `d7-ssid-rc6` | helper | 把「只有 SSID 不可存」的 rc 6 當失敗(D-7 的負對照) |
| `d10-no-disarm` | helper | `reboot committed` 失敗時不 disarm |
| `healthok-2field` | provd | 備援只看 bluetoothd + hci0_powered |
| `ro-on-ctl` | provd | app 的唯讀動詞走 ctl |
| `upload-noowner` | provd | PUT 不檢查窗擁有者 |
| `upload-nosrcip` | provd | PUT 不比對來源 IP |

### 5.2 Go killpoint(既有機制,F-H9;新增名字)

| 名字 | 時點 |
|---|---|
| `UpdWriteMid` | worker 串流 root.squashfs 到一半(≥ 16 MiB 之後) |
| `UpdBeforeArm` | update-last 寫成 `armed: false` 之後、arm 之前 |
| `UpdAfterArm` | `armed: true` 之後、寫 `rebooting` 之前 |

用 sysrq `b`,以 `push-helper killpoint=<name>` 武裝。

### 5.3 provd 的標記與 `push-provd`

- P3 讓 prov_test 的 provd `--version` 第 2 行 = 與 helper 相同的 prov_test 標記。
- H4 新增節點指令 `prov-wbox-254.sh push-provd <file> <sha> [env…]`:
  1. bind prov_test provd 到 `/usr/bin/batman-provd`;
  2. bind `batman-provd-test.init` 到 `/etc/init.d/batman-provd`;
  3. 寫 `fault.provd` / `provd.env`;
  4. restart;
  5. 斷言新 pid 的 exe sha、`--version` 標記、environ。
- `unbind-all` 一併解除。
- ⚠️ **E-H12**:ujail 會不會看到 bind 過的 binary。ujail 在自己的 mount ns 裡重新 bind 同一個路徑,預期看得到 bind 後的檔,但要在 lease 底下實測。不成立 → provd 的接縫改走 W 載具,而且只做「試用中做得到」的臂;附錄 A 那些列會標出來。

### 5.4 shell 注入(`/tmp/batman-fault.<name>`,F-H8 的 `batman_opf`)

| 名字 | 誰讀 | 效果 | 用在 |
|---|---|---|---|
| `setkey-norollback` | `halow-setkey` | `--rollback` 不還原 | 負對照 |
| `setkey-readback-skip` | 同上 | 跳過讀回 | 負對照 |
| `setkey-notrap` | 同上 | 不設 `trap '' PIPE` | 負對照 |
| `setkey-apply-fail` | 同上 | 套用後讀回當作失敗(注入) | 配對注入失敗 → 還原 |
| `setkey-rbverify-fail` | 同上 | 還原的讀回也失敗(D-6 注入) | rc 6 + 封鎖 + CRIT |
| `setkey-pause` | 同上 | commit 之後、讀回之前 sleep 30 s(確定的窗口) | 殺 helper 臂 |
| `setkey-settle-timeout` | 同上 | settle 直接逾時 | D-5 |
| `slot-copy-all` | `batman-slot` | 複製所有 boot 檔 | sysupgrade 臂負對照 |
| `slot-reboot-fail` | 同上 | `reboot committed` rc ≠ 0 | D-10 |
| `slot-pause-write` | 同上 | write 開始後 sleep 30 s | D-14(在這個窗口送 TERM) |
| `bulk-mount-fail` | `batman-provd` init | tmpfs 掛載當作失敗 | D-15 |

- D-5 其他兩種情況由 root 直接造:`.txn` 存在(既有手法);run dir 不能用 = 暫時把 `$RUNDIR` 換成非 root 擁有(既有的 #280 測試手法)。
- 每個 shell fault 由單位的 EXIT trap 與 lease dead-man 刪除;P9 檢查殘留。

### 5.5 檔案 bind(RB)

- `uci-argv`:`/sbin/uci` 外包一層 shim(`scripts/node/uci-argv-shim.sh`),把 argv 寫進 `/tmp/run/batman-dv/uci-argv.<run>`(root 0600)。斷言只在節點上 grep、只輸出計數;臂結束就刪掉,**絕不拷回主機**(B-m3)。
- autocommit 變體(RD,h23 §17 的做法):`ac-noprov`(不看 helper / provd-stable)、`ac-id-pid`(peer pid == instance pid)、`ac-nofw4`(不看 `inet fw4`,D-17)、`ac-helperoff-err`(helper 停用也 FAIL,D-16)。見證行與 INVALID 規則照 h23 §17.2。

## 6. pre-P3、負對照與對表

### 6.1 pre-P3 的判斷(B-M3、A-m3)

- **依 build 特徵,不依產品回應**:節點上沒有 `/usr/share/nftables.d/ruleset-post/batman-http.nft`,而且沒有 `/usr/share/batman/release-root.pub` → pre-P3。
  - 這時單位印一行 `FAIL <unit>: pre-P3 image (<version>)` 就結束;known-failures 條目 expires = P3 預估 merge + 14 天(估計)。
- 在 P3 build 上,任何 `E_UNSUPPORTED` 都是一般的 FAIL。
- 不經 provd 的單位(`prov-eeprom-hooks`、`prov-transfer-tool` 的 loop 臂)不看 P3,現在就跑。
- INVALID:單位以非 0 結束;known-failures 只認 FAIL 行,所以只有 INVALID 的 suite 會被歸成 NEW。這是刻意的:INVALID 一定要有人看。

### 6.2 負對照的種類(附錄 A 的「負」欄)

| 代號 | 意思 | H4 PR 附什麼 |
|---|---|---|
| **W** | wsl.22 上這條斷言 FAIL(`--pre-p3-full`) | ✅ 原始輸出 |
| **S** | 同一載具、只差一個接縫 / 注入 | ❌ 接縫要 P3 實作後才存在 → **P3 PR 的閘門**:P3 PR 必須附上每一條 S 的 FAIL 輸出 |
| **P** | 前提證據:同一臂內有正向對照(例如 relay → :80 = 200、`ss -ltn` 在聽、計數器增加、bundle 非空)。缺了 → INVALID | 隨每次執行 |
| **—** | 沒有負對照(附理由) | — |

- 每一條都要有至少一種;**「連不上 / 不存在」這一類一律要 P**(B-M2)。
- `--pre-p3-full` 要讓 F 載具在 wsl.22 上跑一次(新卡的 wsl.22 基準,B-m10),成本算進 §10。

### 6.3 對表

- 附錄 A 是唯一的來源。`tests/tools/peer/p3-units.tsv` 由附錄 A 機械產生(`gen-p3-units.py`)。
- lint 用內容比對:P3 §6 的每一列、§8 每一列的每個斷言片語、D-1…D-17,都要在 TSV 裡找得到對應的列(比對 P3 原文的片語 ID,不是比列數)。
- TSV 記下 P3 文件的 commit。單位執行時印出這個 commit;節點上 image 的 P3 版本與 TSV 對不上 → FAIL(版本不一致,B-M12)。

## 7. §9-4 探針 `http-src-probe-254.sh`(H4 凍結的閘門;D22、D-1、D-2;A-M7)

**在哪**:04,lease 底下(⚠️ P3 原本寫「非 DUT」,因為 02 沒有 eth 也沒有手機;**要使用者同意改在 04**,§11)。在 wsl.22 上做,P3 的表由探針自己載入、自己刪。

**步驟**:
1. 記下 `nft list tables` 與 `nft list ruleset | sha256sum` 作為基準。
2. 載入 v7 規則(P3 §3.8.1 原文的兩張表)。04 上沒有東西在聽 8095:探針在 04 上起 `nc -lk -p 8095`(busybox)當接收端。
3. **正向**:手機 relay → `04:8095`,TCP 連上(`nc` 收到),且 `bridge batman_http` 那條規則的 counter **增加**(D-2)。
4. **負向**:
   - netns(§4.5)送 → 連不上,`inet batman_http_in` 的 drop counter 增加;
   - lo → 同樣被丟;
   - VLAN 802.1ad 0 + 802.1q 0 雙層 → 被丟。
5. **探針自身的鑑別力**(D-1):改載 v6 規則(bridge 層比 `tcp dport`),同一個 VLAN 雙層 → **放行**。證明 VLAN 臂分得出 v6 與 v7。
6. 刪表,`nft list ruleset` 的 sha 回到基準,`nc` 結束 → 結束。

**不成立時**:
- 正向不通 → 改用 P3 §9-4 的備案規則,再做一次短審查(使用者決定);
- 結果回填 P3 F76、D-1、D-2。

**手機 AP 密碼不進對話**:C0 是 S0 的測試值,在 §3.1 由 harness 設定。在 S0 之前(現在 04 是 legacy)做探針的話,由 harness 經 root 把 04 的 AP 暫時改成 C0,結束後還原。真密碼只在節點上的 uci 裡,不出現在 log 或對話中。

## 8. 個別元件的細節

### 8.1 T 簽章與 payload

- `tests/keys/`:T 的私鑰與公鑰(公開,只有 prov_test 信任),加上 K_test。
- `sign-test-release.py` 產生 E_T(K_test, serial)與 S。
- `p3-payloads.sh` 從 V 的 payload 產生:
  - 四包惡意 tar(重複成員、symlink、`../`、沒列名的 boot 檔);
  - `SHA256SUMS` 不是第一個成員;
  - 版本解析失敗(`1.5.14-wsl`);
  - **壞 rootfs**:root.squashfs 截斷,`SHA256SUMS` 用截斷後的 sha,所以簽章與讀回都會過。

**「新版沒開機成功」用壞 rootfs**(A-M8-1):kernel 正常載入 → 掛不上 root → panic → `panic=10` 之後重開(F-H16)→ tryboot 是一次性的,所以回到原槽。⚠️ **E-H13**:第一次執行時使用者要在場(萬一卡住就拔電);之後列進常規。不做「kernel 壞掉」,因為韌體可能直接卡住。

### 8.2 `prov-eeprom-hooks-254`(D11;A-m9、B-m6)

**WSL 上的載具**:
- 解開 rootfs:wsl.22 的 `root.squashfs`,用 `unsquashfs`。
- `qemu-aarch64-static` + binfmt;沒裝就 FAIL(⚠️ E-H16 檢查 WSL 有沒有)。
- 在 `chroot` 裡,PATH 最前面放假 `vcgencmd`,回傳四個 key。
- 依序執行 rootfs 的 `/etc/uci-defaults/*`(fresh overlay)。
- 斷言:`authorized_keys` 不含植入的 key、root 密碼的 hash 不變、AP `disabled`、country 沒被鎖。

**負對照**:`/home/yello/out/1.5.12-wsl.9+f2f2bf6.fw07f2063` 的 rootfs(在 shim 之前,PR-F 之前;sha 釘死)→ 全部被採用。

### 8.3 `prov-fw-boot-254` 與 `fw-badinclude`(A-M5、B-M9)

- **常規**:每次開機後斷言三張表都在。做成單位框架的掛鉤:任何單位做完重開後都會呼叫。
- **rc 閘門** `fw4 print | nft -c -f -`:bench 上做(兩板中只有 bcm2711 有節點)。
- **`fw-badinclude`(W)**:在 **02** 上做 wbox held 試用,拿 02 central 鎖。這段時間 02 開機沒有防火牆,只在實驗室的 mesh 上,最長 600 s;判定 = 02 試用的 `TRIAL-REVERTED` / `WBOX-NOCOMMIT` 原因與 fw4 不在的 log;還原 = 回到 committed 槽。依 P3 §6 要**使用者同意**才跑(§11)。
- **D-17**(autocommit 看 `inet fw4`):RD 載具。dry-run 時 PATH 最前面放假 `nft`,回報沒有 `inet fw4`:
  - 正確的 autocommit → `DRYRUN decision: REVERT`;
  - `ac-nofw4` 變體 → `COMMIT`(負對照 S)。
- 這樣就不必真的讓節點沒有防火牆。

## 9. 擁有權

| 資源 | 唯一寫者 | 其他(唯讀) |
|---|---|---|
| 04 / 02 的節點狀態(uci、p5、slot、防火牆、AP) | 持有 prov lease 的單位(h23) | 其他、P9 |
| bench 金鑰庫與 journal | `peer.py s0` 與單位 | — |
| 備份 | `peer.py s0`(每次改動後) | 使用者 |
| 新卡(p5 快照、B 槽、`fresh-deadline`、B 的 rc.local) | `fresh-254.sh` | — |
| netns `h4x`、veth `h4*` | `prov-ethsim-254.sh`;dead-man 刪除 | P9 |
| fault 檔與帶 fault 的**執行中行程** | 單位(`push-helper` / `push-provd`);關閉 = 單位 EXIT trap + dead-man | P9 |
| `/tmp/batman-fault.*` | 單位;EXIT trap + dead-man 刪除 | P9 |
| 手機上的 `~/batman-h4/<run>/`、relay 行程 | `phone-254.sh` | — |
| 手機的 Wi-Fi 設定、Termux、電源 | 使用者(一次設定) | harness 只檢查 |
| `phone_known_hosts` | `phone-254.sh pin` | 其他 |
| 桌機的 BLE adapter | `blebridge.py`(主機鎖底下) | — |
| 02 的 central 鎖 | h23 既有 | — |

## 10. 契約(新介面)

| 介面 | 寫 → 讀 | 格式 | 缺 / 壞 | 誰寫得到 |
|---|---|---|---|---|
| `peer.py` 的 JSON 行 | peer → 單位 | §4.1 | 不是 JSON / 缺欄 → INVALID | WSL 使用者 |
| blebridge 行協定 | peer ↔ bridge | §4.2 | 不認得 → `ERR`;bridge 結束 → Closed | Windows 使用者(只看得到密文) |
| relay 行協定 | peer ↔ relay | §4.3 | 同上 | 持有手機 key 的主機 |
| bench 金鑰庫 / journal | `peer.py s0` → 單位 | CBOR,0600 | 缺 → 所有單位 INVALID + 重建步驟;journal 不一致 → 兩組都試 | WSL 使用者 |
| `fresh-deadline` | 主機 → B 的 dead-man | `<run> <uptime>` | 缺 / 壞 / run 不符 → dead-man 不動(chain1 的規則:dirty flag 不指向這個 run 就不動) | root |
| fault 檔 | 單位 → helper / provd init | §5.1 | §5.1 | root |
| `p3-units.tsv` | 產生器 → 單位、lint | TSV + P3 commit | P3 commit 對不上 → FAIL | harness PR |

## 11. 生命週期矩陣(harness 自己的路徑)

| 路徑 | 行為 | 測法 |
|---|---|---|
| 首次 / D20 之後 | `prov-bench-s0-254 provision`;S0 不成立 → 所有單位 INVALID | 庫是空的時候跑一次任一單位 → INVALID + 步驟 |
| 一般執行 | `s0_assert` → 臂 → 還原 → `s0_assert` | 每個單位 |
| 主機死 / 睡眠 / Windows 更新重開 / `wsl --shutdown` | lease dead-man(unbind、fault 關閉、ethsim 刪除、服務重啟);新卡由 `fresh-deadline` 回到 A;下一個 run 看到 dirty → 印 restore | chain1 回歸的 dead-man 臂;lease dead-man 既有測項加 fault / ethsim 的檢查 |
| BLE adapter 關 / 驅動重啟 | blebridge `ERR` → 該臂 INVALID | 關藍牙跑一次 |
| 手機關機 / 重開 | Termux:Boot 把 sshd 帶起來;起來之前手機臂 INVALID | 重開手機跑一次 |
| 手機換了網路 | preflight 2 / 3 / 5 不過 → INVALID;每臂前後都檢查 | 手機改連 ALT 跑一次 |
| 02 在臂進行中重開 | 02 的動作 rc ≠ 0 → 該臂 INVALID;02 的 boot_id 前後比對 | — 偵測型 |
| 04 非預期重開 | boot_id 變了 → FAIL 並印 boot-reasons | — 偵測型 |
| 中途換接縫 | §5.1:重啟,單位重建上傳窗 / session | 每個 S 臂 |
| 單位 > 3000 s | lease 每 10 分鐘 `renew`(F-H8) | 長單位 |
| EXIT trap 組合 | 單位只有一個 EXIT trap,依序呼叫 lib 註冊的 cleanup 清單(`h4_on_exit add <fn>`) | `test-h4-lib.sh` |
| H4 與 P3 版本不一致 | §6.3 → FAIL | lint + 單位 |
| 新卡時 04 的 IP 改變 | `fresh_ip` 每一步重讀;relay 的 node-ip 每臂重給 | — |
| 平台 bcm2710 | P-U14,不支援;C 載具兩板共用 | — |

## 12. 安全

**資產**:04 / 02 的控制權、bench 金鑰庫(擁有者私鑰、mesh key、C0)、手機。

**攻擊面的變化**:
- **手機 sshd(8022)**:在 04 的 AP、經 `br-ahwlan` ↔ `bat0` 的**整個 mesh**都到得了(A-m11、B-m2);家用 Wi-Fi 已移除,行動數據關閉(H4-U4)。
  - 只收一把專用 ed25519 key,並加上 forwarding 限制;沒有密碼;不給 storage 權限。
  - 被攻破的後果:看到 relay 經手的 Noise 密文、`X-Batman-Session` bearer(P3 已列為界線),以及手機上存的 C0 / ALT(都是 bench 測試值)。
- **relay**:只連 argv 指定的位址。
- **blebridge**:Windows 端只看得到密文與公開的 `STATUS`。
- **ethsim**:netns / veth 只在 lease 期間存在,由 root 建立。

**秘密**:
- 金鑰庫在 WSL 0600;備份的 ACL 由程式設定並讀回驗證(§3.2)。
- 秘密不進 argv:passphrase 從庫讀,經 stdin;單位 log grep 斷言不含(只比 `short()`)。
- `uci-argv` 的 log 不離開節點。
- dev-open 臂(bundle-gate):`/etc/batman-dev-open` 的存在時間 ≤ 該臂(約 2 分鐘),EXIT trap + lease dead-man 都會刪;這段時間 legacy 認領的閘門被放寬(`node.go:529-534`),所以這一臂只在 L 載具上、主機鎖底下做,寫進副作用。

**權限**:接縫檔是 root 0600(`batman_opf`)。非 root 寫入 → 被忽略並記 TAMPER(P3 的單元測試證明;H4 在節點上用 `prov-sec` 補一條:uid 65534 建 `/tmp/batman-fault.setkey-norollback` → setkey 照常還原)。

**失敗模式**:手機、BLE、relay、S0 出問題一律 INVALID,不會變 PASS;還原失敗 = FAIL + NEVER_KNOWN。

## 13. 副作用與還原(每輪;A-M8、B-M9)

| 單位 | 動到什麼 | 還原 / 驗證 |
|---|---|---|
| 全部 | 04 的 lease 與服務 | h23 |
| F 載具(settings / country-join / bundle-gate unclaimed / luci-reset) | 04 離開 N0 60–120 分、OTS 停、p5 mkfs、B 重寫 | chain1 的 restore_all + compare;B 留著 V(brewrite) |
| prov-luci-reset | firstboot **只在 F 的 B 上做**,A 的 overlay 不動 | F 的 restore |
| prov-http | 停 bluetoothd ≥ 5 分(#305 BT UART 卡住的風險:卡住 → 單位 FAIL、需要重開,印 `bt-uart-305` 的判讀);刪表 / reload;`firewall stop` → docker 的 nft 表也被刪 | `firewall start` + `/etc/init.d/dockerd restart` + 等 OTS 健康(OTS 中斷約 3 分);斷言 `nft list tables` 與基準相同 |
| prov-http ethsim / MAC 偽造 | netns / veth;手機斷線最長約 5 分 | §4.5 |
| prov-settings key 20 | 04 的 AP 換成 ALT → **連在 04 AP 上的所有裝置都斷線** | 還原 C0,(a)(b) |
| prov-update | 多次重開、A / B 重寫(T 簽的 V)、update-last;壞 rootfs 臂一次 panic 重開 | 回到 S0 的槽與版本;brewrite;`s0_assert` |
| prov-upload | 126 MB 經手機上傳 × 每個接縫一次 | 上傳檔由 helper 刪,斷言 tmpfs 用量回到 0 |
| prov-bundle-gate dev-open | 認領閘門放寬(§12) | 刪旗標 |
| fw-badinclude | 02 那次試用沒有防火牆 ≤ 600 s | 02 回到 committed;使用者同意 |
| 02 | country-join、mesh 臂、BLE 認目標時被短暫連線 | 02 的 S0 斷言 |
| 手機 | AP 換帳密兩次;payload 暫存 | run 結束刪除 |

## 14. 成本(⚠️ 推估;h23 的 hold 型單位實測約 47 分)

| 單位 | 估時 | 主要成本 |
|---|---|---|
| prov-bench-s0(assert) | 3 分 / 單位 | — |
| prov-p3-routes | 40 分 | 角色 × 動詞 × 兩種傳輸;legacy 一次(L) |
| prov-owner | 30 分 | |
| prov-settings + country-join + bundle-gate unclaimed + luci-reset | 180 分 | 一次 F(約 90 分)+ 臂 + restore |
| prov-status-diag | 30 分 | ro 10 分鐘負載 × 2(正向 + `ro-on-ctl`) |
| prov-bundle-gate(其他) | 15 分 | |
| prov-http | 150 分 | 備援要等 5 分 × 多次、mesh 洪流 10 分 × 2、`firewall stop` 加 OTS 重啟、接縫重啟 |
| prov-upload | 120 分 | 126 MB × 約 6 次(每個接縫、helper 重啟臂) |
| prov-update | 300 分 | T 試用約 6 次(主臂、同版本、壞 rootfs、回滾、升級臂、sysupgrade 臂)× 約 37–47 分 |
| prov-autocommit-p3 | 90 分 | T 試用 2 次 + RD dry-run × 6 |
| prov-transfer-tool | 10 分(loop) | 真卡另外、NEEDS-PERSON |
| prov-fw-boot | 1 分 / 次 | |
| fw-badinclude(02) | 30 分 | 只在 rc |
| prov-eeprom-hooks | 10 分(WSL) | |
| **合計** | **約 17–18 小時 / 輪** | 04 離開 mesh 約 3 小時;OTS 中斷約 5 小時 |

另外:
- 每個 rc 的 build:prov_test 的 helper + provd 兩個 binary(不需要整個 wbox image);只有 `fw-badinclude` 需要一個 wbox image(約 10 分)。
- `--pre-p3-full`(wsl.22 基準)只在 H4 PR 做一次,約 6 小時。
- 依 P-U10,只在動到 prov 的 PR 與發版時跑。**要使用者確認這個成本**(§15)。

## 15. 工作順序與要使用者決定的

**順序**:
1. 本設計 → 兩位審查到 0 BLOCKER / 0 MAJOR → 凍結(另需 §7 探針的結果)。
2. `peer.py`、`blebridge.py`、`httprelay.py` + CI selftest。
3. 實測(唯讀的先做,改狀態的要使用者同意):
   - E-H9(BLE 連線、notify、MTU、9 KiB、維持 230 s);
   - E-H8(手機路徑);
   - E-H10(Android 換網路);
   - E-H12(`push-provd` + ujail);
   - E-H15(ethsim);
   - E-H16(qemu binfmt)。
4. `fresh-254.sh`,chain1 在 wsl.22 上回歸。
5. 各單位依序做,每個在 wsl.22 上跑 pre-P3 一行與 `--pre-p3-full`。
6. 使用者在場:§7 探針、D20 重燒、`prov-bench-s0-254 provision`、E-H13、YubiKey。
7. harness PR 附全部輸出(S 型負對照標 ❌,改由 P3 PR 附上)→ 使用者 merge → P3 實作開始。

**要使用者決定**:
1. 成本:約 17–18 小時 / 輪(§14)。
2. §7 探針改在 04 做(P3 原本寫非 DUT;02 沒有 eth 也沒有手機)。
3. `fw-badinclude` 在 02 上做(02 那次試用沒有防火牆 ≤ 600 s)。
4. 會改節點狀態的實測:E-H12(在 04 bind provd)、E-H15(在 04 建 netns / veth),都在 lease 底下、做完立即還原。

## 附錄 A. 逐列對表(P3 §6、§8、附錄 D → H4)

欄位:**#**(H4 的 ID)| **來源**(P3 原文片語)| **單位 / 臂** | **載**(§2)| **誘發** | **斷言** | **負**(§6.2)

### A.1 `prov-p3-routes-254`

| # | 來源 | 臂 | 載 | 誘發 | 斷言 | 負 |
|---|---|---|---|---|---|---|
| RT1 | §8「每個動詞 × 角色 × owner-op 缺 / 錯 → §5.1」 | matrix | R(BLE)+ RB(HTTP 經上傳窗) | `peer.py call`,依 `p3-expect.tsv` | 線上碼與 reason 完全相等 | W(wsl.22 全部 `E_UNSUPPORTED`) |
| RT2 | §8「key 20 經 HTTP → `E_UNSUPPORTED`」 | key20-http | RB | HTTP session 送 key 20 | `E_UNSUPPORTED{1: typ, 2: 19}` | W |
| RT3 | §6「首次安裝:HTTP 不聽」 | idle | R | 不開窗、BLE 健康 | 手機 relay → 8095 = `timeout`(被丟)或 `refused`;同臂 relay → :80 = 200 | P |
| RT4 | §5.1 legacy key 2 / 20 → 20 | legacy | L | strip → legacy 認領 → key 2、key 20 | `E_UNSUPPORTED{2: 20}` | W(wsl.22 沒有 key 20 → 不同碼) |
| RT5 | §5.1 `status` scope 1 → 7;key 10–13 → 7 | matrix | R | | `E_UNSUPPORTED{2: 7}` | W |

### A.2 `prov-owner-254`

| # | 來源 | 臂 | 載 | 誘發 | 斷言 | 負 |
|---|---|---|---|---|---|---|
| OW1 | §8 add | add | R | H0 加 Hx | Hx `auth/owner` 成功;journal 已套用 | W |
| OW2 | §8 重送輪替 / §5.2 | resend | R | 同一 add 再送 | 新 tag key ≠ 舊;舊的 `auth` 失效 | W |
| OW3 | §8 remove(BLE 與 HTTP session 都被切) | remove | RB(上傳窗讓 HTTP 開) | Hx 開一條 BLE + 一條 HTTP session → H0 remove Hx | 兩條都在 ≤ 5 s 內 Closed;Hx 重新交握 → 被拒;`adv_owner_key` 輪替 | W + P(切之前兩條都能用) |
| OW4 | §8 最後一位 | last | R(快照) | remove H0b、Hx 後再 remove H0 | 依 P3 / helper 的既有規則(F3)回應;快照還原 → `s0_assert` | W |
| OW5 | §5.2 remove 重送 | resend-rm | R | 再 remove Hx | `E_FORBIDDEN` | W |

### A.3 `prov-settings-254`(F 與 R)

| # | 來源 | 臂 | 載 | 誘發 | 斷言 | 負 |
|---|---|---|---|---|---|---|
| ST1 | §8 get | get | R | `settings-get` | 值 = uci;不含密碼 | W |
| ST2 | §8 新卡 → 認領 → key 20 → 不重開 | fresh-k20 | F | BLE 認領 → key 20 = C0 | (a) 節點端 ≤ 30 s(§4.3);(b) 手機端;沒有重開(boot_id 相同);p5 有新值(root 讀 p5) | W(wsl.22 的 F:key 20 不存在) |
| ST3 | §8 `bulk.open ≠ 16` | fresh-bulk | F + RB | T pending → `bulk.open` | 回應 ok(不是 15、也不是 16);有 pending 是前提 | P(先斷言 `update.status` 有 pending)+ W |
| ST4 | §8 已入網 key 20,morse plink 不斷,沒走 `wifi reload \|\| wifi` 的退路 | member-k20 | R | key 20 = ALT,再改回 C0 | `iw wlh0 station dump` 的 plink 連續、`connected time` 不歸零;logread 沒有退路那一行 | P(同臂先證明 plink 在) |
| ST5 | §8 新卡配對注入失敗 → AP 不在空中、`disabled=1`、MARK、p5 不變 | fresh-k20-fail | F + RB | `setkey-apply-fail` | `iw dev` 沒有 `phy1-ap0`;uci `disabled=1`;MARK 有;p5 sha 不變;`E_REJECTED{13}` | S(`setkey-norollback` → AP 留著) |
| ST6 | §8 已配對節點注入失敗 → 舊帳密回來 | k20-fail | RB | `setkey-apply-fail` | hostapd SSID / 密碼 sha = C0;手機仍 `AUTHORIZED` | S(`setkey-norollback`) |
| ST7 | D-6 還原也失敗 | k20-rbfail | RB | `setkey-apply-fail` + `setkey-rbverify-fail` | setkey rc 6;AP 被封鎖、不在空中;CRIT log;`status` 回報;`E_REJECTED{13}` | S(拿掉 `setkey-rbverify-fail` → 走一般還原,證明這條路只由注入觸發) |
| ST8 | §8 讀回 | readback | RB | 正常 key 20 | setkey log 有讀回行 | S(`setkey-readback-skip` → 沒有讀回行,而 ST6 的注入失敗沒被發現) |
| ST9 | §8 passphrase 不在 cmdline / log / 診斷包 | secret | RB | `uci-argv` bind + `/proc/*/cmdline` 每 10 ms 取樣;key 20 | 節點上 grep 的計數 = 0(cmdline、`uci-argv` log、logread、helper / provd log、`diag-bundle` 解開) | S(把 setkey 換成用 `uci set …=$AP` 的變體,bind → 計數 > 0) |
| ST10 | §8 密碼含 `$` → 13 | input | R | key 20 帶 `$` | `E_REJECTED{13}`;AP 不變 | W |
| ST11 | §8 另一程序持 setkey 鎖 15 s | lock | R | root `flock` setkey 鎖 15 s,同時送 key 20 | 成功、總時間 ≤ 230 s | P(log 有等鎖那一行) |
| ST12 | §8 commit 與讀回之間殺 helper → setkey 自己跑完並還原 | kill-helper | RB | `setkey-apply-fail` + `setkey-pause`;在 pause 窗口 `kill -9` helper | setkey 行程(另一個 pgid)繼續、還原完成、AP = C0;helper 重啟後 `settings.get` 一致 | S(`setkey-notrap` → setkey 被 SIGPIPE 結束,停在一半:uci 有新值、AP 狀態不一致) |
| ST13 | §8 `/tmp/.uci/wireless` 有暫存 → `E_BUSY` + `status` 回報 | staged | R | root `uci set wireless.x.y=z`(不 commit) | `E_BUSY`;`status` key 15 有 `uci_staged: [wireless]`;結束 `uci revert` | W |
| ST14 | §8 國家:未入網改 → 成功、p5 已存 | fresh-k2 | F | key 2 = `DE` | 成功;p5 有;**不看目前頻道**(D-B6-M1) | W |
| ST15 | §8 已入網 key 2 → 14 | member-k2 | R | | `E_REJECTED{14}` | W |
| ST16 | §8 同值 `settings.set` 在 p5 stale 時存檔 | stale | RB | root 讓 p5 stale(既有手法)→ 同值 key 1 | p5 被存;沒有 reload | W |
| ST17 | §8 改名 U5 前 → `rename-pending` | rename | R | key 1 | `E_UNSUPPORTED`(rename-pending) | — (U5 前行為不變) |
| ST18 | §6 helper 重啟時 setkey 子程序還在跑 | = ST12 | | | | |
| ST19 | D-5 結束碼 | d5 | RB | 三種:`setkey-settle-timeout`、`.txn` 存在、run dir 換成非 root | setkey rc 5 或 12(依 D-5 定的表);helper 回 `E_BUSY` / reason 12 | S(不注入 → rc 0) |
| ST20 | D-7 SSID 不可存 | d7 | RB | root 把 SSID 設成含 `'`(不經 setkey)→ key 2 | 成功、不被還原 | S(`d7-ssid-rc6` → 被還原) |
| ST21 | D-11 cmdline 取樣不夠 → `uci-argv` | = ST9 | | | | |
| ST22 | §8 Wi-Fi / BT 共存 | coex | R | key 20 期間 blebridge 量測 | 只記錄 BLE 有沒有斷(P3 §9-8,不判定) | — (量測) |

### A.4 `prov-country-join-254`(F + 02)

| # | 來源 | 臂 | 載 | 誘發 | 斷言 | 負 |
|---|---|---|---|---|---|---|
| CJ1 | §8 join 國家不符 → 14,`.txn` 不在、uci 不變 | join-mismatch | F | key 2 = `AU`,join N0(US) | `E_REJECTED{14}`;`.txn` 不存在;uci sha 不變 | W(wsl.22 不比國家 → 入網) |
| CJ2 | §8 update 國家不符 → 14 | update-mismatch | R | 已入網 04,`network/update` 帶不同國家 | 同上 | W |
| CJ3 | §8 先 key 2 再 join 同國家 → 成功 | join-ok | F | key 2 = `US`,join N0 → 04 回到 mesh | 成功;02 看得到 04 的 plink | W(此臂 wsl.22 也成功 → 不鑑別;鑑別在 CJ1) |
| CJ4 | §8 新卡 key 2 = `DE` 仍成功 | = ST14 | | | | |

(入網臂的國家用 AU / US:在 ch 40 合法,與 US 同頻率,P3 F79;A-m10)

### A.5 `prov-status-diag-254`

| # | 來源 | 臂 | 載 | 誘發 | 斷言 | 負 |
|---|---|---|---|---|---|---|
| SD1 | §8 status 與 halow-status 一致 | status | R | | 欄位逐一相等 | W |
| SD2 | §8 成員只拿摘要 | member | R | 以 N0 的成員 PSK 開 session | 只有摘要的欄位 | W |
| SD3 | §8 ro 10/s × 10 分:`cfgsave-lock.busy` 不出現、poll 無 ERate、BLE 廣播在 | ro-load | RB(HTTP 上傳窗) | 手機經 HTTP 以 `settings.get` + `update.status` 共 10/s,持續 10 分;**桌機 blebridge 只掃描**(不連線) | `cfgsave-lock.busy` 取樣 0 次;helper log 沒有 ERate;掃描每 30 s 都看到 04 的 UUID | S(`ro-on-ctl` → poll ERate)+ P(負載確實送到:helper 的 ro 計數 ≥ 5000) |
| SD4 | §8 bundle > 64 KiB 完整、tar 可解、不含秘密 | bundle | R | `diag-bundle` | 大小 > 64 KiB;`tar t` ok;grep 庫裡每個秘密 → 0 | P(bundle 非空) |
| SD5 | §8 handle 跨 session 被拒 | handle | R | session A 的 handle 在 B 用 | `E_REJECTED{15}` | W |
| SD6 | §6 成員輪詢 status 卡住 p5 存檔 | = SD3 | | | | |

### A.6 `prov-bundle-gate-254`

| # | 來源 | 臂 | 載 | 誘發 | 斷言 | 負 |
|---|---|---|---|---|---|---|
| BG1 | §8 claimed → 403 | claimed | R | `wget /cgi-bin/bundle` | 403 | W(wsl.22 → 200) |
| BG2 | legacy 無旗標 → 403 | legacy | L | | 403 | W |
| BG3 | unclaimed / legacy + dev-open → 200 | devopen | F(unclaimed)+ L | root 建旗標 | 200;刪旗標 → 403 | P |
| BG4 | `status` 仍 200 | status | R | | 200 | — (行為不變) |

### A.7 `prov-http-254`

| # | 來源 | 臂 | 載 | 誘發 | 斷言 | 負 |
|---|---|---|---|---|---|---|
| HT1 | §8 正向:手機 AP 上的 client 連得上 | pos | RB(上傳窗) | 手機 relay → 8095 | Noise 交握成功 | S(以 v5 `phy*-ap*` 規則載入 → 連不上) |
| HT2 | 平常不聽 | idle | R | | = RT3 | P |
| HT3 | 停 bluetoothd 5 分 → 聽 | fb-bt | R | `stop bluetooth` | 5 分 ± 10 s 後 relay 連得上;再早 30 s 時連不上 | S(`healthok-2field` → 不同的開啟時點,只在 RB 上)+ P |
| HT4 | `sc_file` 失效 5 分 → 聽 | fb-sc | RB | 依 P2 的手法讓 `sc_file` 失效 | 同上 | S(`healthok-2field` → **不**開) |
| HT5 | 恢復 → 不收新連線、既有保留 | fb-recover | R | 啟動 bluetoothd | 1 分後新連線 refused / timeout;既有 session 仍能用 | P |
| HT6 | psk_owner → 候選 → `auth/owner` | roles | RB | | 成功 | W |
| HT7 | NX / psk_replay 被拒 | roles-neg | RB | | 連線關閉(與 fake path 等長) | W |
| HT8 | mesh 臂(拆兩臂,D-4):(a) 偽造手機 MAC → 連不上;(b) 不偽造的洪流 50 conn/s × 10 分 → 連不上、poll 無 ERate、BLE 廣播在、擁有者照樣傳完 | mesh-a / mesh-b | RB + ethsim | §4.5 | (a) `timeout`、drop counter 增加;(b) 同 + 手機完成 126 MB 上傳 + 掃描看到廣播 | S(`http-nofw` + 不載表 → (b) 的 netns 連得上)+ P(同臂手機連得上) |
| HT9 | lo 臂 | lo | RB | §4.5 | `timeout`、counter | P |
| HT10 | VLAN 臂(D-1:802.1ad 0 + 802.1q 0) | vlan | RB + ethsim | §4.5 | 被丟、counter | S(v6 規則 → 放行)+ P |
| HT11 | docker 臂 | docker | RB + ethsim(br-ots) | | 被丟 | P |
| HT12 | 刪表 → ≤ 8 s 不聽 | deltable | RB | `nft delete table inet batman_http_in` | ≤ 8 s 後 `ss -ltn` 沒有 8095 | S(`http-nofw` → 照樣聽)+ P |
| HT13 | firewall reload → 兩張表回來、規則各一份 | reload | RB | `fw4 reload` ×2 | 兩張表各一份規則 | W |
| HT14 | `firewall stop` → ≤ 8 s 不聽 | fwstop | RB | `/etc/init.d/firewall stop` | 不聽;還原(§13) | S(`http-nofw`) |
| HT15 | helper 停 → provd ≤ 8 s 不聽 | helper-stop | RB | | `ss` 沒有 8095 | P |
| HT16 | §6 provd crash / crash loop → HTTP 斷、上傳檔被刪 | provd-kill | RB | 上傳中 `kill -9` provd | 連線斷;下一個 poll 週期內上傳檔不在;tmpfs 用量 0 | P |
| HT17 | §6 hostapd / `wifi reload` | wifi-reload | RB | 開窗中 `wifi reload` | 規則仍有效:手機重新連上之後連得上 | P |
| HT18 | §3.8.1 `auto_includes = 0` → 不給 `http.2` | autoinc | RB | 設 0 + `fw4 reload` | 表不在、≤ 8 s 不聽;還原 | S(`http-nofw`) |
| HT19 | D-3 別人寫 bit 24 → 不給 `http.2` | bit24 | RB | root 加一條外來的 `meta mark set … 0x01000000` | 8 s 內不聽;`status` 回報 | S(`http-nofw`) |
| HT20 | D-8 非 `phy*` 的 frame 先清 bit | d8 | RB + ethsim | 在 bridge 更早的優先序加一條規則,替 `h4v0` 進來的 frame 打 bit | 仍被丟 | S(載入沒有清 bit 的規則版本 → 放行) |
| HT21 | D-13 AP iface 不是 `br-ahwlan` 的 port | d13 | RB | `ip link set phy1-ap0 nomaster` | `http.2` 消失、`status` 回報;還原 `master br-ahwlan` | S(`http-nofw`) |

### A.8 `prov-upload-254`(RB,T pending)

| # | 來源 | 臂 | 斷言 | 負 |
|---|---|---|---|---|
| UP1 | AP 關 → 16 | ap-off | `bulk.open` → `E_REJECTED{16}` | W |
| UP2 | 非窗擁有者的 session → 拒 | other | Hx 的 HTTP session PUT → 拒 | S(`upload-noowner`) |
| UP3 | 來源 IP 綁定 | srcip | 換一個 IP 的 PUT(手機加第二個 IP 不可行 → 從 ethsim 送,但那條路被防火牆擋)→ **改用**:session 建在手機上、PUT 從 netns(`http-nofw` + 不載表才到得了)→ 拒 | S(`upload-nosrcip`);⚠️ 這一臂需要同時用兩個接縫,列給審查判斷 |
| UP4 | 大小不符 → prepare 15 | size | `E_REJECTED{15}` | W |
| UP5 | 寫超過 tmpfs → ENOSPC、其他服務正常 | enospc | PUT 比 `size=` 大的檔 → 被截斷;OTS 與 helper 正常 | P(tmpfs 用量到上限) |
| UP6 | 窗外的上傳檔一個 poll 週期內被刪 | outside | 先證明檔在 → 關窗 → ≤ 8 s 內 tmpfs 用量 0 | P |
| UP7 | 上傳中 `network/update` → `E_BUSY` | busy | `E_BUSY` | S(`upload-nobusy`) |
| UP8 | 上傳中 helper 重啟 → 窗消失、重傳成功 | helper-restart | 窗不在;重開窗重傳 → prepare 成功 | P |
| UP9 | `owner/remove` 清掉窗 | rm | Hx 開窗 → remove Hx → 窗不在 | W |
| UP10 | D-15 tmpfs 掛不上 → 不開窗 | d15 | `bulk-mount-fail` → `bulk.open` 被拒;掛載點不是一般目錄 | S(不注入 → 正常) |

### A.9 `prov-update-254`

| # | 來源 | 臂 | 載 | 斷言 | 負 |
|---|---|---|---|---|---|
| UD1 | T 簽 → trial → commit → 5 | main | RB → T | phase 2 → 3 → 重開 → 4 → commit → 5 | W |
| UD2 | 同版本重試退回 → 6(不是 5) | same | RB → T | 6 | W |
| UD3 | arm 前斷電 → 0 | kp-before | RB(`UpdBeforeArm`) | 重開後 phase 0;tryboot 旗標不在 | S(換成 `UpdAfterArm` → 不同的 phase) |
| UD4 | 新版沒開機成功 → 6 + 18 | badroot | RB → T(壞 rootfs) | panic 重開回原槽;6 + 18 | P(serial / boot-reasons 有 panic 行);⚠️ E-H13 |
| UD5 | 之前退回同一槽的 bad-slot 不造成假 6 | oldbad | RB | 先造一次 bad-slot → 再一次正常更新 → 5 | W |
| UD6 | worker 失敗的 reason 依類別 | worker | RB | 1 / 11 / 12 / 17 各一 | W |
| UD7 | 簽章錯、serial < min、板子錯、降級、min_from、開機設定不符、版本解析失敗 | reject | RB | `update.check` 的 reason 逐一相等 | W |
| UD8 | 四包惡意 tar、FIFO、上傳後改 payload | malicious | RB | reason 11;目標槽 BAD、不 arm | W |
| UD9 | prepare 中 kill helper / 斷電 | kill | RB(`UpdWriteMid`;kill -9) | 槽 BAD、仍跑舊槽 | P |
| UD10 | helper 重啟後 phase 3 重建 | rebuild | RB | phase 3 | W |
| UD11 | 回滾臂 | rollback | T | 回到舊槽;舊槽的 P3 狀態 | W |
| UD12 | 升級臂:P2 未入網 → P3 → `--check` fresh | upgrade | F(wsl.22 新卡、未入網)→ ssh sysupgrade 到 P3 | `--check` fresh;沒有 reason 17 | S(`p5-autosave-off` → stale) |
| UD13 | SSID 含 `'` 的節點升級後 OTA 不被擋 | quote-ssid | RB | `update.check` 通過 | W |
| UD14 | sysupgrade 臂:沒列名的 dtb 不被寫進槽 | sysupgrade | R | 目標槽 boot 沒有那個 dtb | S(`slot-copy-all` → 有) |
| UD15 | bench 臂:YubiKey | bench | — | — | NEEDS-PERSON |
| UD16 | D-9 試用轉 committed 時存一次 | d9 | T | commit 之後 p5 不 stale | S(`p5-autosave-off`,在 T 之前以 `upper-helper` 放進去,撐過重開) |
| UD17 | D-10 同版本又失敗只報 6;`reboot committed` 失敗時 disarm | d10 | RB | (a) 6 不帶 18;(b) `slot-reboot-fail` → tryboot 旗標不在 | S(`d10-no-disarm`) |
| UD18 | D-14 write 被 TERM → `.busy` 不留 | d14 | RB | `slot-pause-write` 窗口送 TERM → `.busy` 不在 | S(拿掉 `trap 'exit 143' TERM` 的 `batman-slot` 變體 bind → `.busy` 留著) |
| UD19 | D-12 `update.check` 不拿 `n.mu` | d12 | RB | `setkey-pause` 中的 `settings.set` 期間送 `update.check` → ≤ 5 s 回應(`E_BUSY` 或結果,不是卡住) | W |

### A.10 `prov-autocommit-p3-254`

| # | 來源 | 臂 | 載 | 斷言 | 負 |
|---|---|---|---|---|---|
| AC1 | 正常 provd → commit | pos | T | committed | W(wsl.22 沒有 provd-stable 檢查 → 不鑑別;鑑別在 AC2) |
| AC2 | provd 壞掉 → revert | badprovd | RD(dry-run,provd 停用但 enabled)| `DRYRUN decision: REVERT` | S(`ac-noprov` → COMMIT) |
| AC3 | helper 不在 → revert | nohelper | RD | REVERT | S(`ac-noprov`) |
| AC4 | 穩定 60 s 後被殺 → 仍 commit | stable-kill | RD | COMMIT | S(`ac-id-pid` → 正常 provd 也 REVERT) |
| AC5 | provclient 掛 60 s 不算 | provclient | RD | REVERT | S(`ac-id-pid`) |
| AC6 | provd 被停用 → 只 WARN、commit | disabled | RD | COMMIT + WARN 行 | S(`ac-helperoff-err`) |
| AC7 | D-16 helper 被停用 → 只 WARN | d16 | RD | COMMIT + WARN | S(`ac-helperoff-err`) |
| AC8 | D-17 `inet fw4` 不在 → 不 commit | d17 | RD(假 `nft`) | REVERT | S(`ac-nofw4`) |

### A.11 其他

| # | 來源 | 單位 | 載 | 斷言 | 負 |
|---|---|---|---|---|---|
| TT1 | §8 轉賣工具 | prov-transfer-tool | C(loop)+ 真卡 | §3.9 全部 | S(`--test-skip-wipe` → 特徵字串還在) |
| LR1 | §8 firstboot 後擁有者 / mesh / AP 帳密仍在 | prov-luci-reset | F(只動 B) | 三者都在 | W(wsl.22 的 `flash.js` 舊字串;A-m12) |
| FB1 | §8 三張表都在 | prov-fw-boot | R(每次開機後) | | — (偵測) |
| FB2 | rc 閘門 `nft -c` | prov-fw-boot | bench | rc 0 | S(`fw-badinclude` 的檔 → rc ≠ 0,在 WSL 對 `nft -c` 也可以) |
| FB3 | `fw-badinclude` | fw-badinclude | W(02) | 試用時沒有 fw4、試用被退回 | — |
| EE1 | D11 | prov-eeprom-hooks | C | §8.2 | 1.5.12 rootfs |
| D1/D2 | 附錄 D-1、D-2 | §7 探針 | 04 | §7 | v6 規則 |
| D3 | D-3 | HT19 + lint | | | |
| D4 | D-4 | HT8 | | | |
| D5–D17 | 見上 | ST19、ST7、ST20、HT20、UD16、UD17、ST9、ST*、HT21、UD18、UP10、AC7、AC8 | | | |

## 附錄 B. v1 審查的處理

| 意見 | 處理 |
|---|---|
| A-B1 / B-B1 wbox 試用跑不出來 | §2 的載具;接縫都在 committed 槽 bind(RB / RD);T 編進 prov_test helper(§1.4);wbox 只用在 `fw-badinclude` |
| A-B2 新卡停在試用 | §4.4 涵蓋步驟 6、可續期的 dead-man;AP keyguard;02 的安排 |
| B-B2 / A-M6 S0 與擁有者 | §3 |
| A-M1 / B-M10 對表 | 附錄 A + §6.3 |
| A-M2 HTTP 怎麼開 | 每臂標 RB(T pending 上傳窗)或 R(備援) |
| A-M3 / B-M4 手機 | §4.3、H4-U4 |
| A-M4 / B-M7 發送端 | §4.5(H4-U5) |
| A-M5 / B-M9 D-17 / fw-badinclude | §8.3 |
| A-M7 探針 | §7 |
| A-M8 / B-M9 副作用、kernel 壞掉 | §13、§8.1(改成壞 rootfs,E-H13) |
| B-M1 接縫契約 | §5 |
| B-M2 / A-m4 鑑別 | §6.2 逐條 W / S / P |
| B-M3 / A-m3 pre-P3 | §6.1 |
| B-M5 Windows | §4.1(核心在 WSL)、F-H13、F-H20 |
| B-M6 BLE | §4.2;SD3 只掃描不連線 |
| B-M8 dead-man / lease | §4.4;lease dead-man 只加 unbind / fault / ethsim,不碰 p5 / AP |
| B-M11 / A 成本 | §14 |
| B-M12 / A-m8 生命週期 | §11 |
| A-m1 F-H13 行號 | F-H19 改為 `:168` |
| A-m2 fault 檔 | §5.1 |
| A-m5 ro 負載 | SD3 |
| A-m6 / B-m3 秘密 | §4.1、§5.5、§12 |
| A-m7 Windows / WSL、host key | §4.1、§4.3 |
| A-m9 / B-m6 eeprom | §8.2 |
| A-m10 國家 | A.4 |
| A-m11 / B-m2 sshd 曝露面 | §12 |
| A-m12 luci 負對照 | LR1 |
| A-m13 S 型在 H4 跑不了 | §6.2:S = P3 PR 的閘門 |
| A-m14 `SOCK_ONLY` 的 `HealthOK` | sock 只用在 RB 的 `push-provd SOCK_ONLY`,而且不用在備援 / 廣播的斷言;sock 臂斷言 8095 不在聽(P) |
| A-m15 連線規則 | §4.1 |
| B-m1 F-H1 證據 | F-H1 |
| B-m4 state 保留 | §3.2(臨時 run 的狀態不含 H0) |
| B-m5 lint | §6.3 |
| B-m7 30 s 拆兩條 | §4.3 |
| B-m8 新卡 AP | §4.4 |
| B-m9 fw-boot 掛鉤 | §8.3 |
| B-m10 wsl.22 新卡 | §6.2 |
| B-m11 E-H11 | 從證據表拿掉(那次的 eth0 沒有載波;動節點狀態的錯誤已回報 #254) |
