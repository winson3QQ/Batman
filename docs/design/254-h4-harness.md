# Design: #254 PR-H4 — P3 的 harness — **v3(審查中)**

**狀態**:v3,2026-11-02,審查中。

**歷程**:
- v1(a31489b):兩位審查都 REJECT,A = 2 / 8 / 15、B = 2 / 12 / 11。
- v2(d5cf7ed,整份重寫):兩位審查都 REJECT,A = 1 / 9 / 22、B = 1 / 10 / 19。B 說骨架站得住、不需要再整份重寫。
- v3:在 v2 骨架上把每一節改成一致的版本(整份重新寫過,不是在 v2 上貼補丁)。v2 每條意見的處理見附錄 C。審查報告在 `254-reviews/h4-review-v{1,2}-{A,B}.md`。

**上層**:
- `254-p3-impl.md` v7.1(凍結,`feat/254-p3` @ dfedd03),以下稱 P3;
- `254-h23-harness.md` v14,以下稱 h23;
- `219-protocol.md` v0.7 + `.cddl`。

**流程**:P3 D1 規定 H4 先 merge,之後才開始 P3 實作。H4 走獨立的 harness PR(#290)。

## 0. 一句話

H4 把 P3 的測試要求全部變成可以執行的單位與臂。涵蓋的來源是 P3 §6 的每一列、§7 的每一條負測試、§8 的每一個斷言片語,以及附錄 D-1…D-17;逐條對照在附錄 A。

**每一臂都寫清楚五件事**:
1. 在哪種載具上跑(§2);
2. 怎麼誘發;
3. 斷言什麼;
4. 負對照是哪一種(§6.2);
5. 副作用與還原。

**需要的工具**:
- WSL 上的 owner client `peer.py`;
- Windows 的 BLE 薄橋;
- 實驗室常駐的 S20 手機 relay;
- 新卡 lib(chain1 1–6 + 可續期 dead-man);
- 04 本機的 eth 側模擬;
- 節點端的 undo journal。

**bench 基準狀態**:分兩段。P3 之前叫 **S0-pre**,P3 之後叫 **S0**(§3)。

**驗證分成四段,各自附證據**:
1. 離線 / CI;
2. 現在就能做、不影響節點的實測;
3. 一次現場(重燒、S0-pre、手機、§7 探針、E-H13);
4. P3 rc 上機:S 型負對照與正向全套,這是 P3 PR 的閘門。

## 1. 決策、範圍、事實

### 1.1 使用者決策

| # | 決定 | 來源 |
|---|---|---|
| H4-U1 | HTTP 的 AP client 用 S20 + Termux sshd(專用公鑰) | #254 留言 6576525655 |
| H4-U2 | 新卡臂用 chain1 式的新卡 | 同上 |
| H4-U3 | BLE 用桌機 Windows bleak | 6576687238 |
| H4-U4 | S20 是備用機,常駐實驗室、常接電源;可以為測試調整設定 | 2026-11-02 |
| H4-U5 | eth 側的臂用 04 本機模擬(netns + veth);真 eth0 驅動路徑列誠實界線 | 2026-11-02 |
| H4-U6 | WSL venv 依 `tests/vectors/219-protocol/requirements.txt` 以 `--require-hashes` 安裝(已裝) | 2026-11-02 |
| H4-U7 | **一次現場**,依序:重燒 02 / 04 → harness 認領並建 bench 網路(S0-pre)→ 手機設定(掃 QR 存測試熱點)→ §7 防火牆探針**在 04 做** → 第一次跑「新版開不起來」臂。**H4 PR 等這次現場做完、收到證據才開** | 2026-11-02 |
| H4-U8 | 「試用轉 committed 那一刻存設定」(D-9)的負對照**只由 Go 單元測試證明**,節點上只測正向,寫成誠實界線 | 2026-11-02 |
| H4-U9 | `fw-badinclude` **保留在節點上真的跑**(使用者沒有同意拿掉) | 2026-11-02 |
| H4-U10 | 下載:WSL `qemu-user-static` `1:8.2.2+ds-0ubuntu1.18`(已裝,binfmt aarch64 已註冊);Windows bleak 3.0.2 以 `tests/tools/peer/requirements-win.txt`(hash 釘選)重裝(已裝) | 2026-11-02 |
| (待決) | 全套成本(§14);使用者問「測試程式很難一次寫對,怎麼克服」→ §16 | — |
| (沿用) | P3 D1、D2、D11、D20、D21、D22;h23 全部機制 | P3 §1.1、h23 |

**本設計自己決定、審查者可以攻的點**:
- Q1:協定核心在 WSL,Windows 只放 bleak 薄橋。
- Q2:接縫負對照都在 committed 槽上以 bind 執行;wbox 只用在 `fw-badinclude`。
- Q3:eth 側用 04 本機的 netns 模擬。
- Q4:bench 由 harness 的長期擁有者持有(S0-pre / S0)。

### 1.2 範圍

**本 PR 的檔案**:

| 類別 | 檔案 |
|---|---|
| 主機 / 手機工具 | `tests/tools/peer/peer.py`、`blebridge.py`、`httprelay.py`、`requirements-win.txt`、`sign-test-release.py`、`gen-p3-units.py`、`p3-units.tsv` |
| 主機端腳本 | `scripts/dv/phone-254.sh`、`fresh-254.sh`(chain1 改成 source 它)、`prov-p3-254.sh`(單位驅動)、`http-src-probe-254.sh`(§7)、`data/p3-payloads.sh` |
| 節點端腳本 | `scripts/node/prov-ethsim-254.sh`、`prov-undo-254.sh`(undo journal)、`uci-argv-shim.sh`;`prov-wbox-254.sh` 擴充 `push-provd`、`set-fault`、新的 bind 目標與 killpoint 名字;`prov-lease-254.sh` 的 dead-man 擴充(§5.7) |
| 判定 | `tests/judges/h4/*`:離線判定 + 存下的節點輸出(§16) |
| 單位 | 附錄 A 的全部單位 + `prov-bench-s0-254` |
| CI | peer / blebridge(假後端)/ relay 的 selftest、判定的離線測試、`p3-units.tsv` lint、tmp-trust、shellcheck |
| 文件 | `docs/validation/s20-setup.md` |

**不在本 PR**:
- P3 的產品程式、Go 單元測試與 mutant;
- 接縫的**實作**(P3 依 §5 做);
- U5 改名;
- YubiKey 實機(UD15 NEEDS-PERSON;但「release 拒收 T」是常規臂,UD-T1);
- bcm2710 真機(P-U14);
- 晶片換表(D21);
- iOS;
- 真 eth0 驅動路徑(H4-U5)。

### 1.3 事實

實查日期 2026-11-02;main 2ecf1cb;04 / 02 = `1.5.14-wsl.22+2ecf1cb.fwce20a68`,兩台都是 legacy。

| # | 事實 | 證據 |
|---|---|---|
| F-H1 | 04 的手機 AP = `phy1-ap0`(`default_radio0`),與 `eth0`、`bat0` 同在 `br-ahwlan`。沒有 `isolate`;`forward_ahwlan` → `accept_to_ahwlan`;iptables FORWARD = ACCEPT;`br_netfilter` 已載入。⚠️ E-H8 尚未實測 | 04 `bridge link`、`iw dev`、`uci show wireless`;審查 v1-B E6 |
| F-H2 | 桌機上網走自己的 Wi-Fi | `Get-NetRoute` |
| F-H3 | **E-H9(部分)✅**:bleak 連上兩台、讀到 `STATUS` / `CTRL`,沒有配對提示:<br>`57:57:26:04:77:79 -62 mtu 517 STATUS …0564 35636663`(末 4 碼 `5cfc` = 04)<br>`63:6C:F5:E0:C7:08 -80 … 63663464`(`cf4d` = 02)<br>`CTRL a4 01 01 02 00 03 18f4 04 192000`(frame 244、msg 8192)<br>MTU 會談到 517 → frame 必須取 min | 2026-11-02 輸出;節點上 `identity/sn` 末 4 碼 |
| F-H4 | 試用中,會改狀態的動詞一律 `EBusy` | `node/node.go:198-206` |
| F-H5 | `-wbox` 永遠不 auto-commit | `batman-autocommit:485-530` |
| F-H6 | 回到 Unclaimed 的唯一辦法是 p5 mkfs;**不能移除最後一位擁有者**:`EForbidden "cannot remove the last owner"` | `node.go:514-539, 890` |
| F-H7 | chain1:步驟 6 release → B committed unclaimed;dead-man 在 B 的 `/etc/rc.local`(overlay)+ setsid `sleep 1500`;held 試用期限 600 s;前提「A committed $V」 | `chain1-254.sh:10, 186-196, 275, 280-297` |
| F-H8 | lease 的 dead-man:unbind-all、刪 killpoint 目錄、還原 upper helper、provd 重啟、radio 還原、啟動服務;「never touches a slot or p5」;有 `renew`;staged 檔在 tmpfs | `prov-lease-254.sh:9, 14-18` |
| F-H9 | h23 bind 機制:`bind`(封閉清單:provhelper / autocommit / halow-setkey / config-save / banner / node.key / authorized_keys,**不含 batman-slot**)、`push-helper`、`upper-helper`(**寫目前槽的 overlay upper**)、`set-provd-env`(只在 prov_test image)、`unbind-all`;killpoint 名字封閉清單 `txn-[1-5] \| claim-after-persist \| claim-before-shadow` | `prov-wbox-254.sh:1-25, 50, 64-67` |
| F-H10 | h23 §17 的 dry-run;autocommit 不重設 PATH | h23 `:706-760`;`batman-autocommit:26-27, 69, 323` |
| F-H11 | prov_test 版 provd 只在 wbox image;provd `--version` 沒有 prov_test 標記;test init 的 `_provd_env` 只收固定 key、純數字值;release init 與 test init 各有一份 `start_service`;provd 在 jail 裡的 log pid 是 `[1]` | `testenv_provtest.go:1-5`;`main.go:7, 53`;`batman-provd-test.init:24-33`;`prov-wbox-254.sh:149` |
| F-H12 | 有任何 BLE link 或 session 就撤廣播;`rpa_timeout` 約 900 s + jitter 換 RPA;rx = write-without-response,tx = notify;inbound `MaxFrame` 512、`OutFrame` 244;廣播只有 `ServiceUUIDs` | `bluez.go:37, 233-236, 268-270, 597, 771-779`;`frame.go:12-17` |
| F-H13 | `verify.py` 需要 `pycddl`、`dissononce`、`cryptography.x509`;`transport_sock.Proxy` 在 pipe 上用 `select()`(Linux 可以) | `verify.py:23-36`;`transport_sock.py:75` |
| F-H14 | 02 的 eth0 沒接線,只經 bat0 到 04;04 的 eth0 段上只有桌機 | 審查 v1 |
| F-H15 | **04 的工具**:<br>busybox `nc` 只有 `nc IP PORT`(沒有 `-l/-k/-p/-w`);**沒有** `timeout`、`ss`、`hostapd_cli`(只有 morse 的 `hostapd_cli_s1g`)、arping、python3、socat、unshare、curl。<br>**有** `netstat`、`tcpdump`、`uhttpd`、busybox `wget`(`-T`)、`uclient-fetch`、`flock`、`setsid`、`bluetoothctl` 5.72、`ip-full`(netns)、`iperf`、`openssl`。<br>`ubus call hostapd.phy1-ap0 get_clients` 可用。<br>核心:`CONFIG_NET_NS=y`、`VETH=m`(已載入)、`VLAN_8021Q=y`;`tcp_syn_retries` = 6 | 04 唯讀;審查 v2 A E2、B E2 |
| F-H16 | 04 的 kernel cmdline `panic=10`、`rootfstype=squashfs,ext4`;procd watchdog 30 s | `/proc/cmdline`、`ubus call system watchdog` |
| F-H17 | firstboot 會清掉只存在 overlay 的東西;`firewall stop` 會刪掉所有 nft 表,含 docker 的 | 審查 v1-B E11、E6 |
| F-H18 | `strip-p5-prov` 只在快照內使用 | `prov-base-254.sh:12, 256-266` |
| F-H19 | P3 文件矛盾:`:168` 寫 reason 7,§5.1 / §8 寫 19 | P3 |
| F-H20 | WSL venv:`verify.py` 197 ALL PASSED、peer selftest 29 ALL PASSED | 2026-11-02 |
| F-H21 | known-failures 只看 FAIL 行;pre-P2 的條目 ERE `\([0-9][^)]*\)` 比對任何版本 | `validation-known-failures.txt:25-35` |
| F-H22 | CI 沙箱 `dv-sbx`(arm64)已存在,它的底是 1.5.11-rel.1 的 rootfs | `ci.yml:162-179`;h23 §4.4.1 |
| F-H23 | **`network/join` 不在 `p3Types`**;`owner/add`、`owner/remove`、`settings/*`、`status`、`peers/challenge`、`diag/*`、`update/*`、`bulk/*` 在 → wsl.22 上回 `E_UNSUPPORTED` | `provd/session.go:66-69, 623-625` |
| F-H24 | 04 的 `BATMAN_FEATURES` 含 `provd-p2(#254)`,沒有 P3 標記 | 04 `/etc/batman-build` |
| F-H25 | overlay 是每個槽各一份(槽 A 的 overlay loop 在 p2 offset 116391936) | 審查 v2-A E1 |
| F-H26 | `br-ots`(zone `dockert`)的 input 是 DROP;`docker0`(zone `docker`)是 `accept_from_docker`;docker0 目前 DOWN、沒有容器 | 審查 v2 A E3、B E3 |
| F-H27 | provd 的 ops 一次只跑一個,在跑時新的直接 `ErrBusy` | `provd/server.go:182-184` |
| F-H28 | `batman-slot` 寫 rootfs 前會清零 SQ + 64 MiB;已有 shell fault `corrupt-after-write` | `batman-slot:638, 644, 666-668, 686` |
| F-H29 | `halow-setkey` 等鎖時不寫 log | `halow-setkey:132-134` |
| F-H30 | `halow-status` 會對非 root 擁有的 `/tmp/batman-fault.*` 記 `WARN tamper` | `halow-status:111-113` |
| F-H31 | WSL 的 `appendWindowsPath = false`;Windows Python = `C:\Users\yello\AppData\Local\Programs\Python\Python313\python.exe` | `/etc/wsl.conf`;`py -0p` |
| F-H32 | 04 的 `/tmp/dhcp.leases` 是 0 行;02、04 都有 `dhcp.ahwlan` | 審查 v2-B E8 |
| F-H33 | **02、04 都沒有預設路由**,只有 `10.41.0.0/16`(加上 docker / br-ots)→ 沒有任何外網路徑 | 02、04 `ip route`,2026-11-02 |
| F-H34 | H3 收尾時的 chain1 結果:`chain1 59/0`(04 + 02 wsl.21) | commit c12567b 的訊息 |

### 1.4 回報給 P3(P3 實作的第一個 commit 處理)

1. F-H19 的文字。
2. **§5 的接縫契約**:Go fault 的名字;killpoint 名字;shell fault 名字(所有 image 都有,只認 root 擁有的檔,其他記 TAMPER);T 的信任以 build tag 編進 prov_test helper;provd 的 prov_test 標記;test init 接受 `fault.provd`;helper 的 ro 計數與 `provd-stable` 是否重算寫進契約。
3. **`BATMAN_FEATURES` 加 `provd-p3(#254)`**,讓 H4 可以依 build 判斷是不是 pre-P3(§6.1)。
4. **pending 要綁定驗它的信任集合**(審查 v2-B m13):prov_test helper 用 T 驗過的 pending,在 unbind 回 release helper 之後不能被沿用。H4 的 `unbind-all` 也會刪 pending 與上傳檔。
5. **autocommit 的 `inet fw4` 檢查以 PATH 呼叫 `nft`**(D-17 的 RD 臂靠假 `nft`)。

## 2. 載具(附錄 A 的「載」欄)

| 代號 | 載具 | 能做 | 不能做 |
|---|---|---|---|
| **R** | committed release(S0-pre 或 S0) | 黑箱正向:BLE / HTTP 上的所有動詞 | 接縫 |
| **RB** | R + bind:`push-helper`(prov_test helper,信任 T、Go fault / killpoint)、`push-provd`(§5.3)、shell fault、檔案 bind(§5.5) | 接縫負對照、注入、T 簽的 pending、上傳窗 | **跨重開**:bind、`/tmp` fault 重開就消失;`upper-helper` 只寫目前槽(F-H25)。凡是需要跨重開的負對照,一律寫成 Go 單元測試的界線(H4-U8) |
| **RD** | RB + autocommit dry-run(h23 §17) | autocommit 的判定 | 真 commit |
| **T** | 真試用:RB 的 helper 收下 T 簽的 payload(V = 受測 rc 本身,以 T 重新簽)→ app 路徑寫入 → 重開進試用 | phase 4 / 5 / 6、autocommit 的真 commit / revert、D-9 的正向 | 試用中改狀態 |
| **W** | wbox held 試用 | 只用在 `fw-badinclude`(02) | 改狀態、commit |
| **F** | 新卡(§4.4):B committed unclaimed,之後在 B 上再用 R / RB | 新卡 → 認領 → key 20 / key 2 / join、unclaimed CGI、luci reset、D-6、D-7 | — |
| **L** | legacy:R + 快照內 `strip-p5-prov` → 以 legacy 身分由臨時擁有者認領 | legacy 的 key 2 / 20、legacy CGI | — |
| **C** | CI(`dv-sbx` arm64)或 WSL(loop 檔、qemu-user + 隔離) | 兩板共用的 shell(含 D-14)、eeprom-hooks、轉賣工具 loop | 真無線 |

**flip 規則**:每組正 / 負對照只差一個變數。也就是同一個載具、同一個 image,只差一個接縫;或者同一套流程,只差 image(wsl.22 對 P3 rc)。

## 3. Bench 基準狀態

### 3.1 S0-pre(pre-P3)與 S0(P3)

| 項目 | S0-pre | S0 | 設定者 |
|---|---|---|---|
| 04、02 | claimed → member,`RadioManaged = true` | 同 | `peer.py`:BLE 認領(P2 有)+ `network/join`(P2 有,F-H23) |
| 擁有者 | **H0**(一位) | H0 + **H0b**(`owner/add`) | `peer.py` |
| 網路 N0 | 02 + 04,US,ch / 頻寬 = 現在的 fleet,mesh key = 新產生的測試值 | 同 | `provgen.py` + `network/join` |
| 04 的手機 AP | **C0**:root 在 04 上以 `halow-setkey --ap` 寫入。值是推到節點 `/tmp/run/batman-dv/c0`(root 0600)的檔案,讀出後傳入;argv 界線見 F73 | C0:key 20(journal) | S0-pre:root;S0:`peer.py` |
| 02 的手機 AP | C0'(同上) | 同 | 同 |
| 手機 | 已存 C0(04)與 ALT,MAC 類型 = 手機 MAC | 同 | 使用者在現場掃 QR(§4.3) |

- C0、C0'、ALT 都是 20 字元以上的高熵隨機測試值。

**`s0_assert`**:依 §6.1 判斷 image 是 pre-P3 還是 P3,選對應的版本。

- **S0-pre 版**只用 P2 有的東西:
  - BLE 讀 `STATUS`:state = member;
  - H0 的 `auth/owner` 成功;
  - root 讀 uci 的 SSID = 庫裡的值;
  - hostapd conf 的 sha:ifname 從 `ubus call network.wireless status` 取(P3 F52),不寫死 phy 編號;
  - 目前槽與 `BATMAN_VERSION` = 受測 image。
- **S0 版**再加:H0b 的 `auth/owner`;`settings.get` 的 SSID;`status`。
- 不成立 → 該單位 **INVALID**,並印出重建步驟。

**W 列的判法**(審查 v2-B B1 的修法 2):在 S0-pre 上,前置或本體的 P3 動詞回 `E_UNSUPPORTED` → 印 `FAIL <unit> <row>: …`。只有 S0-pre 本身不成立時才印 INVALID。

**升級 S0-pre → S0**:第一個 P3 rc 上機後,執行 `prov-bench-s0-254 upgrade`:
- `owner/add` H0b;
- key 20 = C0(值不變,改經產品路徑寫);
- journal 照 §3.2;
- 這一步是 P3 PR 的閘門之一。

### 3.2 金鑰庫

**位置**:WSL `~/.batman-dv/bench/`(0700,檔案 0600)。

**範圍**:
- `bench/`:S0 的部分,長期保存;
- `run/<run>/`:臨時擁有者 Hx、F 載具的 HF、快照內的動作。不會寫進 `bench/`,run 結束就刪。

**journal**:會輪替節點端秘密的動作(`owner/add` 重送、`owner/remove`、key 20、`network/*`):
1. 先把「意圖 + 新值」寫進 `journal.cbor`(fsync);
2. 再送出;
3. 成功後改成「已套用」。

中斷之後,下一個 run 先讀 journal,新、舊兩組都試,哪一組成立就以那組為準。快照內的動作只記在 `run/` 範圍(例如 OW4 移除 H0b),不會把 S0 記成「H0b 已移除」。

**備份**:每次改動後,`tar` 一份到 Windows `%LOCALAPPDATA%\batman-dv\bench-backup\`。ACL 由程式設定(只限目前使用者、去掉繼承),並以 `icacls` 讀回斷言。

**誠實界線**(審查 v2-A m10):同一個 Windows 使用者底下的任何行程,都能經 `\\wsl.localhost` 讀到 WSL 的庫,備份也一樣。庫裡都是 bench 測試值,可以接受。

**H0 與 H0b 都遺失**:只能重燒(D20 流程),要使用者在場。

**C0 怎麼給手機**:`phone-254.sh c0-card` 在 Windows `%LOCALAPPDATA%\batman-dv\c0-card.html` 產生 Wi-Fi QR(`WIFI:T:WPA;S:…;P:…;;`),ACL 只限使用者。使用者在桌機本地打開,用手機掃。我(以及任何工具輸出)都不讀這個檔,密碼不出現在對話裡。

### 3.3 S0 的生命週期

| 路徑 | 行為 | 測法 |
|---|---|---|
| 首次(D20 之後,現場) | `provision` 建 S0-pre | 這一步本身就是測試:結束時跑 `s0_assert` |
| 每個單位 | 開頭 `s0_assert` → 臂 → 還原 → `s0_assert` | 每個單位 |
| P3 rc 第一次上機 | `upgrade` → S0 | P3 PR |
| 單位中斷(主機死) | lease dead-man 照 undo journal 還原(§5.7);p5 由 h23 既有的 dirty 機制交給下一個 run | §11 |
| 金鑰輪替中斷 | journal | 斷在送出與「已套用」之間,兩組都試 |
| 降回 wsl.22(負對照基準) | `s0_assert` 自動用 S0-pre 版;H0b 與 key 20 留在 p5,舊版不認 | UD11 的降級臂 |

## 4. 元件

### 4.1 `peer.py`(WSL)

**執行**:`~/.batman-dv/peer-venv/bin/python tests/tools/peer/peer.py`。

**輸出**:每次呼叫一行 JSON `{"t", "via", "rc", "code", "reason", "body"}`。
- 秘密欄位一律只印 `short()`。清單寫死在程式裡:`bulk-open-resp` key 2、tag key、PSK、認領輸出、key 20 的值、mesh key。
- selftest 斷言:原值不會出現在任何 JSON 輸出裡。
- 單位的秘密斷言在 **WSL 端用原值 grep**,命中數必須是 0;不是比 `short()`(審查 v2-B m19)。

**子命令**:`s0 provision|assert|upgrade|restore`、`claim`、`auth`、`call`、`owner-*`、`settings-*`、`status`、`diag-*`、`update-*`、`bulk-*`、`upload`、`raw`、`load ro <rate> <secs>`(自己計數:ok / `E_RATE` / 其他)、`--selftest`。

**傳輸 `--via`**:
- **`sock`**:`ssh root@<node> provclient node sock-as 471 -- proxy <gatt.sock>`。只用在 `push-provd SOCK_ONLY=1`,不用在任何需要廣播或 HTTP 備援的斷言。
- **`ble`**:WSL 以絕對路徑執行 `/mnt/c/Users/yello/AppData/Local/Programs/Python/Python313/python.exe -E -P <repo>\tests\tools\peer\blebridge.py`(F-H31)。preflight 檢查:
  - Windows Python 版本;
  - bleak 版本 = `requirements-win.txt`;
  - 沒有殘留的 blebridge 行程(`Get-CimInstance Win32_Process` 比對 cmdline)。
- **`http`**:`ssh -i ~/.ssh/batman_phone_ed25519 -o UserKnownHostsFile=~/.batman-dv/phone_known_hosts -o StrictHostKeyChecking=yes -p 8022 <user>@<phone-ip> python -I ~/batman-h4/<run>/httprelay.py <node-ip> <port>`。

**helper 的第 4 條連線**(P3 §2):
- provclient → helper 最多一條,而且不與 app 的唯讀負載並行。
- D-12 的 UD19 走這條,刻意在 `settings.set` 佔著 `n.mu` 時直接打 helper。

**BLE / HTTP session 的並發**:由單位決定,例如 OW3 同時開 BLE + HTTP。

### 4.2 `blebridge.py`(Windows)

**行協定**:一行 hex = 一個 frame;控制行有 `SCAN`、`CONNECT <last4>`、`MTU`、`CLOSE`、`ADDR`(回目前連線的位址)。stdin EOF 或父行程消失 → 斷線並結束(審查 v2-B m11)。

**認目標**(F-H3 已實證):
1. 掃描服務 UUID;
2. 依 RSSI 由強到弱逐一連線,讀 `STATUS` key 5;
3. 不是目標就立刻斷線。

- 連到 02 會讓 02 短暫撤廣播(F-H12)。主機鎖底下沒有其他單位在用 02,所以不干擾別人;仍然記錄在副作用裡。
- RPA 換了 → 每次 `CONNECT` 都重新驗證。
- 新卡(F)的末 4 碼從節點讀 `identity/sn`(p5 mkfs 後是新的,chain1 `:268-269`)。

**frame 大小**:MTU 談完後(`max_write_without_response_size` 連續兩次讀值相同),frame = `min(244, CTRL key 3, 該值)`。

**其他**:notify 用 `start_notify`;write 用 `response=False`。出現配對提示 = FAIL。

**key 20 臂**:Closed = outcome unknown → 重連並讀 `settings.get`,以讀回判定(P3 §5.2)。

**「04 的廣播在」不在桌機判**(審查 v2 的 A-M4-1 / B-M8):廣播只有 UUID,02 也廣播同一個。改在 **04 端**判:
- provd log 臂期間 `adv withdrawn` / `registered` 的行數;
- root `bluetoothctl show` 的 advertising instances 數,每 30 s 取樣一次。

**selftest**:假後端,驗行協定、frame 計算、認目標流程、EOF 退出。

### 4.3 手機:`httprelay.py`、`phone-254.sh`、`docs/validation/s20-setup.md`

**手機設定**(使用者在現場做一次):
- Termux + Termux:Boot(開機時自動起 sshd + wakelock);
- `authorized_keys` 加 `no-port-forwarding,no-agent-forwarding,no-X11-forwarding`;`PasswordAuthentication no`;不執行 `termux-setup-storage`;
- 行動數據關閉;刪除家用 Wi-Fi;只留 C0 與 ALT 兩個網路,兩者 MAC 類型都設成「手機 MAC」;
- 電池「不受限制」、永不睡眠;常接電源。

**host key**:`phone-254.sh pin` 寫進 `~/.batman-dv/phone_known_hosts`;之後 `StrictHostKeyChecking=yes`。

**手機 IP**:每個 run 都重找:
1. 讀 04 與 02 的 `/tmp/dhcp.leases`;
2. 再 `ip neigh`;
3. 都沒有 → 從 04 ping 一次廣播再讀。

**relay**:只用標準庫;每個 run 由 scp 推一份新的,`python -I` 執行。
- argv 固定 `<node-ip> <port>`,只連這一個位址。
- 錯誤分成 `refused`、`timeout`、`unreach`、`reset`。

**`phone_preflight`**:任一項不過 → 手機臂 INVALID。
1. ssh 連得上(釘住的 host key);
2. 04 的 `ubus call hostapd.<ifname> get_clients`:手機 MAC 的 `authorized: true`;
3. 手機 MAC 在 04 的 `bridge fdb` 上,port = AP iface;
4. relay 的 sha256 = repo;
5. relay → `<node-ip>:80` = HTTP 200。

**同路徑正向對照**:每個經手機的負向斷言,同一臂內緊接著做 relay → :80 = 200。

**節點端佐證**(審查 v2-B m4):每個經手機的負向斷言,同時在 04 上:
- `tcpdump -i <AP ifname>` 數到來自手機 MAC 的 SYN;
- 相關 nft counter 有增加。

被入侵的手機回報的結果不能單獨作數。

**key 20「新帳密可連」**:
- (a) 節點端:≤ 30 s 內 hostapd SSID = 新值、AP iface 起來 → 產品斷言;
- (b) 手機端:≤ 180 s 內 `authorized: true` 且 relay → :80 = 200 → 超時判 INVALID,不判產品 FAIL。

### 4.4 新卡 lib:`fresh-254.sh`

**抽出 chain1 的步驟 1–6 與 9(restore_all)**,完成後是 **B committed unclaimed**。

- 參數 `image`:受測 rc,或 wsl.22(做負對照基準時)。
- restore 之後 B 的內容 = A 的版本(brewrite,與 chain1 相同),A 經 overlay-restore + compare 回到原狀。這也涵蓋「F 內的 sysupgrade 寫到 A」的情況(UD12)。
- 新卡由**臨時擁有者 HF** 認領,金鑰放在 `run/` 範圍。

**dead-man**:
- p6 `fresh-deadline`:`<run> <boot_id> <uptime 期限>`。
- B 的 rc.local + setsid 迴圈每 60 s 讀一次:
  - run 不符 → 不動作;
  - boot_id 不同 → 改寫成「本次開機 uptime + 30 分」(給主機一次續期的機會;主機真的死了,30 分後就觸發);
  - 超過期限 → 執行 chain1 的 `ch1-deadman.sh`。
- 主機每 ≤ 10 分續期一次。
- **每次 B 開機後,主機第一件事是斷言 rc.local 那一行與迴圈都在**(chain1 `:292` 的檢查)。
- **LR1(luci-reset 的 firstboot)排在 F 的最後**:firstboot 重開回來,第一個動作就是重新種 dead-man 並斷言,接著直接走 restore_all。中間的空窗(約 2 分)列進副作用。

**兩個 dead-man 的先後**:F 期間,p6 的 dirty flag 指向這個 F run。lease dead-man 看到它,就只做 unbind / fault / ethsim / undo journal,不啟動服務、不碰 openmanetd(與 h23 `restoring` 標記同一種規則)。

**新卡的 AP**:key 20 之前被 keyguard 關著,所以手機臂排在 key 20 之後。

**新卡 root 的 `none` 登入**(chain1 `:33-40`):認領前,lab LAN 上任何人都可以登入 root。列進副作用。

**新卡期間 02**:要用 02 的那一半,先讓 04 以 N0 join 回到 mesh,再拿 02 的 central 鎖。

**回歸**:
- chain1 改成 source lib 後,在 wsl.22 上整個重跑,結果要與 c12567b 記錄的 59 / 0 相同(F-H34);
- dead-man 兩臂:不續期 → 30 分後 restore;有續期 → 60 分內不 restore;
- 加一臂:B 重開後 boot_id 改寫生效。

### 4.5 eth 側模擬:`prov-ethsim-254.sh`(04,lease 底下)

**建立**:
1. `ip netns add h4x`;
2. veth `h4v0` ↔ `h4v1`,`h4v0` 接進 `br-ahwlan`;
3. `h4v1` 移進 netns,IP `10.41.250.<n>/16`(不在 DHCP 範圍);
4. netns 內 `sysctl net.ipv4.tcp_syn_retries=1`(netns 自己的值)。

**連線端**:busybox `wget -T 2 -q -O /dev/null http://<ip>:8095/`,背景執行。並發上限 20;每秒斷言 netns 內的行程數 ≤ 20;結果記 `ok` / `refused` / `timeout`。

**判定都在 04 端**:
- `inet batman_http_in` 的 drop counter;
- `tcpdump -i br-ahwlan` 數 8095 的 SYN 與 SYN-ACK。

**各臂**:

| 臂 | 做法 |
|---|---|
| mesh / eth 洪流 | 50 conn/s × 10 分(受並發上限約束,實際速率記錄下來) |
| 偽造手機 MAC + IP(D-4) | `h4v1` 用手機的 MAC 與 IP;以這個 IP 送出的 ARP 請求就構成 ARP 毒化。手機會斷線,所以這一臂不與手機臂重疊;結束後刪 veth,手機 ping 04,再跑 `phone_preflight` |
| VLAN(D-1) | netns 內建 `q0`(`proto 802.1ad id 0`)再疊 `q0.0`(`id 0`);`q0.0` 設 IP,加 `ip neigh add <04 IP> lladdr <br-ahwlan MAC> dev q0.0 nud permanent`。判定只看 04 端的 counter / tcpdump(04 回的封包不帶標籤,netns 端看不到結果) |
| docker0 | 第二組 veth 接進 **docker0**(zone input ACCEPT,F-H26)。docker0 會因此變 UP,列進副作用。VLAN 雙層也從這一組送 |
| lo | 04 本機 `wget -T 2 http://127.0.0.1:8095/` 與 `http://<br-ahwlan IP>:8095/` |
| UP3 的第二來源 | 一條名字以 `phy` 開頭的 veth `phy9h4`(≤ 15 字元)接進 br-ahwlan → 會被 bridge 規則打 bit。**這條 veth 會讓 helper 的 `phy*` 前提檢查失效,所以只准在 `http-nofw` 時存在** |

**還原**:刪 netns 與所有 `h4*`、`phy9h4` 的 veth,並登記進 undo journal(§5.7);EXIT trap、lease dead-man 都會做;P9 檢查殘留。

**誠實界線**:沒有涵蓋網卡驅動那一段(含 VLAN offload);veth 之後的 `__netif_receive_skb` 與 bridge 路徑相同(⚠️ 推論,§7 會實測)。

**⚠️ E-H15**:在 lease 底下實測一次:mesh 不受影響(看 `batctl tl`)、helper 的前提檢查不受影響、還原乾淨。

## 5. P3 要提供的接縫與 H4 的節點端機制(契約)

### 5.1 Go fault(prov_test build)

**兩個檔**:
- `/tmp/run/batman-prov-test/fault.helper`:helper 啟動時讀;
- `/tmp/run/batman-prov-test/fault.provd`:由 test init 以 root 讀,經 `procd_set_param env BATMAN_FAULT=<a,b>` 傳給 provd;init 接受 `[a-z0-9,-]{1,128}`。

**檔案規則**:root 0600、regular、非 symlink、link 1、≤ 256 B,每行一個名字;各元件有自己的封閉清單。
- 認得的名字 → 記 `fault <name>: armed`;
- 不認得的名字 → 記 `fault <name>: unknown, ignored`。

**開**:`prov-wbox-254.sh set-fault helper|provd <names…>`:
1. 寫檔;
2. 重啟;
3. 斷言新行程帶著 fault:
   - helper:本次 pid 的 `armed` 行;
   - provd:新 pid 的 `/proc/<pid>/environ` 含 `BATMAN_FAULT`,加上「新出現」的 `armed` 行數(provd 的 log pid 是 `[1]`,F-H11)。

**關**:刪檔 → 重啟 → 斷言新行程沒有 fault。`unbind-all` 與 lease dead-man 都會做「關」。P9 檢查**執行中行程**的 environ 與 log。

**重啟的副作用**:
- helper 重啟:重跑開機邏輯、上傳窗消失、上傳檔被刪;
- provd 重啟:session 斷、廣播撤掉再重來。

| 名字 | 元件 | 關掉什麼 |
|---|---|---|
| `http-nofw` | helper | 不檢查表與 `phy*` 前提就給 `http.2` |
| `p5-autosave-off` | helper | 「只因新 key 而 stale → `--save`」(非試用的開機時,也就是 helper restart 時) |
| `provd-id-pid` | helper | provd 辨識改回「peer pid = instance pid」(P3 §8 指定;AC4 / AC5 / AC1 的 S) |
| `upload-nobusy` | helper | `otaBusy` 不看上傳窗 |
| `d7-ssid-rc6` | helper | 「只有 SSID 不可存」的 rc 6 當失敗 |
| `d10-no-disarm` | helper | `reboot committed` 失敗時不 disarm |
| `d12-take-mu` | helper | `update.check` 拿 `n.mu` |
| `helper-arm-crash` | helper | 寫完 `armed: true` 後 `os.Exit(1)`,不重開(P3 §3.7.4 B6 那一列的注入) |
| `healthok-2field` | provd | 備援只看 bluetoothd + hci0_powered |
| `ro-on-ctl` | provd | app 的唯讀動詞走 ctl |
| `upload-noowner` | provd | PUT 不檢查窗擁有者 |
| `upload-nosrcip` | provd | PUT 不比對來源 IP |
| `http-allow-nx` | provd | HTTP 收 NX / psk_replay |
| `k20-any-transport` | provd | key 20 不限 BLE |

### 5.2 Go killpoint

既有機制。名字封閉清單擴充為 `upd-write-mid`(串流 ≥ 16 MiB 之後)、`upd-before-arm`、`upd-after-arm`,`prov-wbox-254.sh` 的清單同步加入。

### 5.3 `push-provd`

- P3 提供:prov_test provd 的 `--version` 第 2 行 = prov_test 標記;test init 跟上 release init 在 P3 的變更(bulk tmpfs、rw 掛載、`bulk-mount-fail`)。H4 的 lint 比對兩份 `start_service` 的差異只在已知的 test 段。
- `prov-wbox-254.sh push-provd <bin> <bin-sha> <init> <init-sha> [env…]`:
  1. bind 到 `/usr/bin/batman-provd` 與 `/etc/init.d/batman-provd`(兩個都加進 bind 封閉清單);
  2. 寫 env / fault 檔;
  3. restart;
  4. 斷言 exe sha、`--version` 標記、environ。
- `unbind-all` 解除時會重啟 provd 並斷言回到 release。
- ⚠️ **E-H12**(lease 底下實測):ujail 的 `procd_add_jail_mount "$PROG"` 從父 namespace bind 同一路徑,推論可以看到 bind 後的檔。不成立的退路是 `upper-provd`(同 `upper-helper`,只在目前槽,不需要跨重開)。

### 5.4 shell fault(`/tmp/batman-fault.<name>`,`rundir.sh:44` 的 `batman_opf`)

所有 image 都有,只認 root 擁有的檔;其他擁有者 → 記 TAMPER(`halow-status` 會記 `WARN tamper`,F-H30)。

| 名字 | 誰讀 | 效果 | 用在 |
|---|---|---|---|
| `setkey-norollback` | `halow-setkey` | `--rollback` 不還原 | ST5 / ST6 的 S |
| `setkey-readback-skip` | 同上 | 跳過讀回 | ST8 的 S |
| `setkey-notrap` | 同上 | 不設 `trap '' PIPE` | ST12 的 S |
| `setkey-apply-fail` | 同上 | 套用後的讀回當作失敗 | 注入 |
| `setkey-rbverify-fail` | 同上 | 還原的讀回也失敗 | D-6 注入 |
| `setkey-pause` | 同上 | commit 之後、讀回之前 sleep 30 s | 殺 helper 臂、UD19 |
| `setkey-settle-timeout` | 同上 | settle 直接逾時 | D-5 |
| `setkey-full-restart` | 同上 | 一律走 `wifi` 全重啟 | ST4 的 S |
| `slot-copy-all` | `batman-slot` | 複製所有 boot 檔 | UD14 的 S |
| `slot-reboot-fail` | 同上 | `reboot committed` rc ≠ 0 | D-10 |
| `bulk-mount-fail` | provd init | tmpfs 掛載當作失敗 | D-15 |

D-14(`batman-slot write` 被 TERM)的正向與負對照都在 **C**(`dv-sbx`)做;節點不 bind `batman-slot`(h23 r2 A-m5 的規則不變)。

### 5.5 檔案 bind(加進封閉清單)

- **`/sbin/uci` → `uci-argv-shim.sh`**:shim 呼叫 `/rom/sbin/uci`,把 argv 寫進 `/tmp/run/batman-dv/uci-argv.<run>`(root 0600)。只在節點上 grep 計數;臂結束就刪,絕不拷回主機。
- **假 `nft`**:只在 RD 的 dry-run 環境以 PATH 前置,不 bind。
- **autocommit 變體**(RD,h23 §17 的規則:見證行、只在 dry-run 期間 bind):

| 變體 | 改了什麼 | 用在 |
|---|---|---|
| `ac-noprov` | 不看 helper / provd-stable | AC2 / AC3 的 S |
| `ac-provd-required` | provd 停用時也要求 provd-stable | AC6 的 S |
| `ac-helperoff-err` | helper 停用時 FAIL | AC7 的 S |
| `ac-nofw4` | 不看 `inet fw4` | AC8 的 S |

### 5.6 `provd-stable` 的處理(RD)

AC 臂的流程:
1. root 刪 `$RUNDIR/provd-stable`。這是 helper 擁有的檔;H4 在 lease 底下是**第二個寫者**,僅限 AC 臂,記進 §9。
2. `push-helper`(帶或不帶 `provd-id-pid`)→ restart provd → 等 70 s。
3. dry-run。
4. 還原:helper 正常重啟後重寫;斷言檔內是本次 boot_id。

### 5.7 節點端的 undo journal(`prov-undo-254.sh`)

**檔案**:`/tmp/run/batman-dv/undo.<run>`(root 0700 目錄)。每行 = 一個封閉清單裡的還原動作。

**規則**:每個會改狀態的動作,**先登記、後執行**。EXIT trap 與 lease dead-man 都依**逆序**執行;每一項執行完都斷言結果。

**動作清單**:

| 動作 | 還原內容與斷言 |
|---|---|
| `fw-start` | `firewall start` → `/etc/init.d/dockerd restart` → 斷言 `nft list tables` 與基準相同、OTS 健康 |
| `uci-revert <pkg>` | 撤銷暫存的 uci 變更 |
| `uci-restore <pkg> <file>` | 用 `uci import` 寫回臂前 export 的檔(root 0600) |
| `nft-del-table <family> <name>` | 刪表 |
| `link-master <dev> <br>` | 把 dev 接回 bridge |
| `link-del <dev>` | 刪介面 |
| `netns-del <ns>` | 刪 netns |
| `svc-start <name>` | 啟動服務 |
| `svc-enable <name>` | 恢復開機啟用 |
| `bt-start` | 啟動 bluetoothd |
| `fault-del <name>` | 刪 shell fault 檔 |
| `ap-restore` | `halow-setkey` 取鎖,從 root 0600 檔寫回原 AP,並 `--save` |
| `pending-del` | 刪 pending 與上傳檔 |

**`firewall stop`(HT14)的額外保險**:停之前先在 04 上起 `setsid sh -c 'sleep 60; firewall start; /etc/init.d/dockerd restart'`。這個保險不靠主機,所以 04 沒有防火牆的時間 ≤ 60 s。

**撐不過重開**:journal 在 tmpfs。臂期間重開了,而又有持久的變更(例如 HT18 的 `auto_includes` commit、AC 的 `disable`),怎麼辦:
- 這類動作的臂**不包含重開**;
- 下一個 run 的 P9 依 p6 的 dirty flag 印出殘留項目。
- `auto_includes = 0` 的後果是 HTTP 不聽(fail-closed),不是 fail-open。

**lease 契約的擴充**:dead-man 加「執行 undo journal」一項,仍然不碰 slot 與 p5。`ap-restore` 經 `halow-setkey` 的 `--save` 寫 p5,這是 setkey 自己的職責,不是 dead-man 直接寫。每一類動作有一個 dead-man 臂:不續 lease → 等 dead-man → 斷言還原(`test-h4-undo.sh` 在 04 上跑)。

## 6. pre-P3、負對照與對表

### 6.1 pre-P3 的判斷

- `BATMAN_FEATURES` 沒有 `provd-p3(#254)`(§1.4 第 3 點)**而且**版本 = `1.5.14-wsl.22+…` → 印一行 `FAIL <unit>: pre-P3 image (<version>)`。
- known-failures 的 ERE 把版本寫死成 `1\.5\.14-wsl\.22\+`(審查 v2-B m1)。expires = P3 預估 merge + 14 天(估計)。
- 其他版本(例如 P3 rc 漏打包標記)→ 一般的 FAIL,不會被吞掉。
- `--pre-p3-full`:在 wsl.22 + S0-pre 上照跑全部斷言,作為 W 證據(現場之後,H4-U7)。
- INVALID:單位以非 0 結束,known-failures 只認 FAIL 行,所以只有 INVALID 的 suite 會被歸成 NEW(刻意的)。

### 6.2 負對照的種類

| 代號 | 意思 | 什麼時候附 |
|---|---|---|
| **W** | wsl.22 + S0-pre 上會 FAIL。附錄 A 每列寫出**預期 FAIL 的那一行**。凡是只在「動詞不存在」那一層 FAIL 的,一律另外加 P(P3 上同一臂內證明子斷言的前提)| H4 PR(現場之後) |
| **S** | 同一載具、只差一個接縫 / 注入 | **P3 PR 的閘門**:P3 PR 必須附上每一條 S 的 FAIL 輸出;H4 PR 標 ❌ |
| **P** | 前提證據(同一臂內):正向對照、`netstat -ltn` 有 LISTEN、counter 增加、bundle 非空、前置狀態已造成。缺了 → INVALID | 每次執行 |
| **G** | 只由 Go 單元測試證明(H4-U8 那一類),節點上只有正向 | P3 PR |
| **—** | 沒有負對照,附理由 | — |

**換規則型的 S**(HT1、HT10、HT20、HT8、HT11):正、負兩邊都在 `http-nofw` 底下跑,只差規則內容,並且兩邊都先斷言 `netstat -ltn` 有 8095 LISTEN(審查 v2-B M3)。

### 6.3 對表

- 附錄 A 是唯一的來源;`gen-p3-units.py` 由它產生 `p3-units.tsv`。
- **片語 ID** = `<P3 節>.<列>.<片語序>`。產生方式:P3 §6 每一列一個;§7 每一列一個;§8 每列的斷言欄以 `;`、`;`、`、` 切開後依序編號;附錄 D 用 D 編號。產生器同時記下片語文字的正規化 sha。
- lint 規則(PR 時):每個片語 ID 至少對到附錄 A 的一列;片語 sha 變了(P3 文件改了)→ FAIL,要求重新對表。
- 執行時不做文件版本比對;image 的版本由 §6.1 判斷。

## 7. §9-4 探針 `http-src-probe-254.sh`(H4 凍結的閘門;D22、D-1、D-2;在 04 做,H4-U7)

**前提**:
- 04 = wsl.22,在 S0-pre 上,lease 底下,主機鎖底下。
- 手機已在 04 的 C0 AP 上:現場的步驟 3 先做,所以不需要改 AP。

**步驟**:
1. **基準**:`nft -s list ruleset`(stateless,不受計數器影響)存檔;`netstat -ltn` 存檔。
2. **listener**:`uhttpd -f -p <04 br-ahwlan IP>:8095 -h <空的 root 0700 目錄>`,登記 undo `svc`。
3. **載入 v7 規則**(P3 §3.8.1 原文的兩張表),登記 `nft-del-table` ×2。
4. **正向**:手機 relay → `04:8095` = HTTP 回應(uhttpd 的 404 也算連上);`bridge batman_http` 那條規則的 counter 增加(D-2);04 上 `tcpdump -i <AP ifname>` 看到手機的 SYN。
5. **負向**(ethsim):
   - mesh / eth、lo、docker0、VLAN 雙層 → `inet batman_http_in` 的 drop counter 增加;
   - tcpdump 看到 SYN、看不到 SYN-ACK;
   - 每一項之前都有同路徑的正向:netns → `04:80` = 200(證明 netns 的路徑本身是通的)。
6. **鑑別力**(D-1):刪掉 v7 表,改載 v6 規則(bridge 層比 `tcp dport`)→ 同一個 VLAN 雙層 → **tcpdump 看到 SYN-ACK**(放行)。
7. **還原**:執行 undo → `nft -s list ruleset` 與基準相同、`netstat` 與基準相同。

**不成立時**:正向不通 → 改用 P3 §9-4 的備案規則,做一次短審查,由使用者決定。結果回填 P3 F76、D-1、D-2。

## 8. 個別機制

### 8.1 T 簽章與 payload

- `tests/keys/`:T 與 K_test,公開。`sign-test-release.py` 產生 E_T 與 S。prov_test image 的 `release-min-serial` 釘為 2,serial 1 的背書用來測「serial < min」。
- `p3-payloads.sh` 以受測 rc 的 payload 為底,產生:
  - 四包惡意 tar;
  - `SHA256SUMS` 不在第一位;
  - 版本解析失敗;
  - **壞 rootfs**:長度不變,破壞 squashfs superblock 的前 4 bytes(magic),`SHA256SUMS` 用破壞後的 sha → 簽章與讀回都過,但 mount 一定失敗(與 B 分割原本的內容無關,審查 v2-A M9)→ ext4 也試過之後 panic → `panic=10` 重開 → tryboot 一次性,所以回到原槽。
- ⚠️ **E-H13**:第一次在現場跑。觀察 panic 行、ext4 的嘗試、重開的時間。

### 8.2 `prov-eeprom-hooks-254`(D11;C 載具,WSL)

- **底**:wsl.22 的 `root.squashfs`(`/home/yello/out/1.5.14-wsl.22+2ecf1cb.fwce20a68`,sha 釘死)→ `unsquashfs`。
- **隔離**:沿用 `dv-sbx.sh` 的 setup:
  - `unshare --mount --pid --fork --net --uts --ipc`;
  - `capsh` 拿掉 `cap_sys_boot,cap_sys_module,cap_sys_time,cap_sys_rawio,cap_mknod`;
  - `chroot`;
  - qemu-aarch64 以 binfmt 執行(H4-U10)。
  
  實作前先唯讀確認 `dv-sbx.sh` 在 WSL 也能用(⚠️ E-H16)。
- **流程**:PATH 最前面放假 `vcgencmd`,回傳四個 key → 依序執行 `/etc/uci-defaults/*`。
- **斷言**:`authorized_keys` 不含植入的 key;root 密碼的 hash 不變;AP `disabled`;country 沒被鎖。
- **負對照(W 類)**:`1.5.12-wsl.9+f2f2bf6.fw07f2063` 的 rootfs(PR-F 之前、沒有 shim,sha 釘死)→ 全部被採用。

### 8.3 `prov-fw-boot-254` 與 `fw-badinclude`

- **常規**:每次開機後斷言三張表都在。做成單位框架的掛鉤:任何單位做完重開後都會呼叫。
  - 負對照(W):wsl.22 上沒有這些表 → FAIL。
- **rc 閘門**:bench 上執行 `fw4 print | nft -c -f -`。
- **`fw-badinclude`(H4-U9,W 載具,02)**:
  - 拿 02 central 鎖;
  - 臂前、臂後都斷言 02 沒有預設路由(F-H33:02 本來就到不了外網);
  - 02 進 wbox held 試用:那次開機沒有防火牆,只暴露在實驗室 L2(主機、04、手機),最長 600 s;
  - 判定:試用的 `TRIAL-REVERTED` / `WBOX-NOCOMMIT` 原因 + fw4 不在的 log + 開機斷言 FAIL;
  - 還原:回到 committed 槽,`s0_assert`;
  - 只在 rc 時跑。
- **D-17**:RD 臂,假 `nft`(§1.4 第 5 點)。

## 9. 擁有權

| 資源 | 唯一寫者 | 其他(唯讀) |
|---|---|---|
| 節點狀態(uci、p5、slot、防火牆、AP) | 持有 lease 的單位 | P9 |
| undo journal | 單位登記;EXIT trap 或 dead-man 執行(兩者互斥:EXIT trap 執行時持有 lease 鎖,dead-man 只在 lease 過期後才動作) | P9 |
| `$RUNDIR/provd-stable` | helper;**例外**:AC 臂在 lease 底下刪除(§5.6) | autocommit |
| bench 金鑰庫 / journal | `peer.py s0`;`run/` 範圍由該 run | 單位 |
| 備份 | `peer.py s0` | 使用者 |
| 新卡(p5 快照、B、`fresh-deadline`、B 的 rc.local) | `fresh-254.sh` | lease dead-man(只讀 dirty flag) |
| netns / veth | `prov-ethsim-254.sh` | P9 |
| fault 檔與帶 fault 的執行中行程 | `set-fault` / `push-*`;關閉 = EXIT trap + dead-man | P9 |
| `c0-card.html` | `phone-254.sh c0-card` | 使用者 |
| 手機的 `~/batman-h4/<run>/`、relay 行程 | `phone-254.sh` | — |
| 手機的 Wi-Fi 設定、Termux、電源 | 使用者 | harness 只檢查 |
| 桌機 BLE adapter、blebridge 行程 | `peer.py --via ble`(主機鎖底下) | — |
| 02 central 鎖 | h23 | — |

## 10. 契約(新介面)

| 介面 | 寫 → 讀 | 格式 | 缺 / 壞 | 誰寫得到 |
|---|---|---|---|---|
| `peer.py` 的 JSON 行 | peer → 單位 | §4.1 | INVALID | WSL 使用者 |
| blebridge 行協定 | peer ↔ bridge | §4.2 | `ERR` / Closed → INVALID | Windows 使用者(只看得到密文與公開的 STATUS) |
| relay 行協定 | peer ↔ relay | §4.3 | 同上 | 持有手機 key 的主機 |
| 金鑰庫 / journal | `s0` → 單位 | CBOR 0600 | 缺 → INVALID + 重建步驟 | WSL 使用者 |
| `fresh-deadline` | 主機 → B dead-man | `<run> <boot_id> <uptime>` | run 不符 → 不動;壞檔 → 當作已過期(fail-secure:回到 A) | root |
| undo journal | 單位 → EXIT / dead-man | 一行一動作,封閉清單 | 不認得的行 → 記 CRIT、跳過、繼續其他行,P9 FAIL | root |
| fault 檔 | `set-fault` → helper / provd init | §5.1 | §5.1 | root |
| `p3-units.tsv` | 產生器 → 單位、lint | §6.3 | 片語 sha 不符 → lint FAIL | harness PR |

## 11. 生命週期矩陣(harness)

| 路徑 | 行為 | 測法 |
|---|---|---|
| 首次 / D20(現場) | `provision` → S0-pre;庫是空的 → 所有單位 INVALID + 步驟 | 空庫跑一次 |
| 一般執行 | §3.1 | 每個單位 |
| P3 rc 第一次上機 | `upgrade` → S0 | P3 PR |
| 主機死 / 睡眠 / Windows 更新 / `wsl --shutdown` | lease dead-man:unbind、fault 關、undo journal;F → `fresh-deadline`;HT14 → 節點端 60 s 保險 | `test-h4-undo.sh` 的 dead-man 臂;chain1 回歸的 dead-man 臂 |
| 孤兒 blebridge | stdin EOF → 結束;preflight 檢查 Windows 行程 | 殺掉 WSL 端,確認 Windows 端 5 s 內結束 |
| BLE adapter 關 / 驅動重啟 | `ERR` → INVALID | 關藍牙跑一次 |
| 手機關機 / 重開 | Termux:Boot;起來之前 INVALID | 重開手機跑一次 |
| 手機換網路 | 每臂前後都做 preflight 2 / 3 / 5 | 手機改連 ALT 跑一次 |
| 02 在臂進行中重開 | 前後比對 boot_id → INVALID | 偵測型 |
| 04 非預期重開 | boot_id 變了 → FAIL + boot-reasons | 偵測型 |
| 中途換接縫 | §5.1 的重啟 → 單位重建窗 / session | 每個 S 臂 |
| 長單位 | lease 每 10 分 `renew` | 長單位 |
| EXIT trap 組合 | `h4_on_exit add <fn>`,一個 trap 依序執行 | `test-h4-lib.sh` |
| 新卡時 04 的 IP 改變 | `fresh_ip` 每一步重讀 | — |
| 降回 wsl.22 | `s0_assert` 用 S0-pre 版 | UD11 降級臂 |
| bcm2710 | P-U14;C 載具兩板共用 | — |

## 12. 安全

**資產**:節點控制權、金鑰庫、手機。

**攻擊面的變化**:
- **手機 sshd**:在 04 的 AP 與整個 mesh 都到得了。只收一把專用 key,加 forwarding 限制,沒有密碼、沒有 storage 權限。
  - 被攻破的後果:看得到經手的密文、`X-Batman-Session` bearer(P3 已列為界線)、手機上存的 C0 / ALT(bench 測試值)。
  - 被入侵的手機可以假造正向結果,但負向斷言有節點端佐證(§4.3)。
- **relay**:只連 argv 指定的位址。
- **blebridge**:只看得到密文與公開 `STATUS`;bleak 依 hash 釘選。被竄改的橋可以讓「連線被切」類的斷言出錯 → 這類臂都有節點端佐證(provd log 的 session 數)。
- **ethsim**:只在 lease 期間存在。
- **T 私鑰是公開的**:UD-T1 是常規臂,證明 release 拒收 T。
- **供應鏈**:
  - WSL venv 與 Windows bleak 都依 hash 釘選;
  - qemu-user-static 是 Ubuntu 官方套件庫的固定版本;
  - Termux 套件(python、openssh)來自 Termux 的套件庫,沒有釘選 → 手機端只跑 relay(只用標準庫)與 sshd,判定不依賴它,列為界線。

**秘密**:
- 金鑰庫在 WSL 0600,經 `\\wsl.localhost` 可讀(界線,§3.2);
- 不進 argv(從庫或節點上的檔案讀,經 stdin);
- 斷言在 WSL 端以原值 grep,必須是 0;
- `uci-argv` 的 log 不離開節點;
- C0 只經本地 QR,不進對話。

**dev-open 臂**(BG3):`/etc/batman-dev-open` 只在臂期間(約 2 分)存在,登記進 undo journal;這段時間 legacy 認領的閘門被放寬(`node.go:529-534`)→ 只在 L / F 載具、主機鎖底下做。

**權限**:fault 檔 root 0600。非 root 寫的 → TAMPER。H4 用 `prov-sec` 補一條:uid 65534 建 `/tmp/batman-fault.setkey-norollback` → setkey 照常還原。排在最後,因為 health 會變 WARN(F-H30)。

**失敗模式**:手機、BLE、relay、S0 出問題一律 INVALID;還原失敗 = FAIL + NEVER_KNOWN;沒有防火牆的窗口 ≤ 60 s(HT14)或 ≤ 600 s(02 的 `fw-badinclude`,沒有外網)。

## 13. 副作用與還原

| 單位 / 臂 | 動到什麼 | 還原 / 驗證 |
|---|---|---|
| 全部 | lease、服務 | h23 + undo journal |
| F(settings / country-join / bundle-gate unclaimed / luci-reset / UD12) | 04 離開 N0 約 90–150 分、OTS 停、p5 mkfs、B 重寫、UD12 會寫 A;新卡 root `none` 登入 | `fresh-254.sh` 的 restore_all + compare + brewrite;`s0_assert` |
| LR1 | firstboot 只在 B,約 2 分沒有 dead-man | 回來後重種並斷言,接著 restore_all |
| HT3 | 停 bluetoothd ≥ 5 分(#305 BT UART 卡住的風險:卡住 → FAIL + `bt-uart-305` 的判讀,需要重開) | `bt-start` |
| HT14 | 沒有防火牆 ≤ 60 s;docker NAT 重建、OTS 中斷約 3 分 | `fw-start` |
| HT18 / HT19 / HT20 / HT21 | `auto_includes`、外來規則、`nomaster`(所有 AP client 斷線) | undo |
| ethsim / MAC 偽造 | netns / veth;手機斷線最長約 5 分;docker0 變 UP | undo |
| HT8 / UP3 的 S(`http-nofw` + `phy9h4`) | 這段時間 8095 對整個 mesh 開著(lab 內) | 關 fault、刪 veth |
| UP7 的 S | `network/update` 會真的套用 → 送與現值相同的 net_config,仍然會 reload | 斷言 plink 恢復 |
| UP1 | AP 關:所有 AP client 斷線 | 還原 AP |
| key 20 臂 | 04 的 AP 換成 ALT:所有 AP client 斷線 | `ap-restore` 回 C0,(a)(b) |
| ST13 | `/tmp/.uci/wireless` 暫存:用一個 commit 了也無害的 key,臂後斷言沒有被別人提交 | `uci-revert` |
| prov-update | 多次重開、A / B 重寫、update-last;壞 rootfs 臂一次 panic 重開 | 回到 S0 的槽與版本;brewrite;`s0_assert` |
| prov-upload | 126 MB × 每個接縫一次 | tmpfs 用量回到 0 |
| AC 臂 | 刪 `provd-stable`;AC6 / AC7 `disable` | helper 重啟重寫;`svc-enable` |
| fw-badinclude | 02 沒有防火牆 ≤ 600 s(沒有外網) | 回到 committed |
| uid 65534 fault 檔 | health WARN | 刪檔;排在最後 |
| 02 | country-join、mesh 臂、BLE 認目標時被短暫連線 | 02 的 `s0_assert` |
| 手機 | AP 換兩次;payload 暫存 | run 結束刪除 |

## 14. 成本(⚠️ 推估;h23 實測 hold 型約 47 分 / 單位)

| 單位 | 估時 |
|---|---|
| s0_assert | 3 分 × 單位數 |
| prov-p3-routes | 45 分(含 L) |
| prov-owner | 30 分 |
| F 一輪(settings + country-join + bundle-gate unclaimed + D-6 / D-7 + UD12 + luci-reset) | 240 分 |
| prov-status-diag | 35 分 |
| prov-bundle-gate(其他) | 15 分 |
| prov-http | 170 分 |
| prov-upload | 130 分 |
| prov-update | 320 分 |
| prov-autocommit-p3 | 100 分 |
| transfer(loop)、eeprom、fw-boot | 25 分 |
| fw-badinclude(02,只在 rc) | 30 分 |
| **合計** | **約 19–20 小時 / 輪**;04 離開 mesh 約 4 小時、OTS 中斷約 5 小時 |

- `--pre-p3-full`(W 證據)在現場之後做一次:約 8 小時(其中 F 用 wsl.22 跑一次)。
- 每個 rc 的 build:prov_test 的 helper + provd 兩個 binary,加一個 wbox image(`fw-badinclude`)。
- 依 P-U10,只在動到 prov 的 PR 與發版時跑。**成本待使用者決定**。

## 15. 工作順序

1. 本設計兩位審查 → 0 BLOCKER / 0 MAJOR。
2. **現在就能做(不改節點)**:
   - 工具:`peer.py`、`blebridge.py`、`httprelay.py` + CI selftest;
   - 判定的離線框架(§16);
   - E-H9 的剩餘部分:對 04 開一個 NX session 讀 `status/public`、notify、9 KiB 分塊、維持 230 s(只讀);
   - E-H16(`dv-sbx` 在 WSL 能否用)。
3. **改節點狀態的實測**(lease 底下、立即還原,實測本身已經是本設計的一部分;要先給使用者步驟):E-H12、E-H15、`test-h4-undo.sh`。
4. `fresh-254.sh` + chain1 在 wsl.22 回歸。
5. 各單位依序寫(§16 的做法);每臂在 wsl.22 上先確認「pre-P3 一行」。
6. **現場(H4-U7)**:D20 重燒 → S0-pre provision → 手機設定 + C0 QR → §7 探針 → E-H13。wsl.22 沒有 update 動詞,所以 E-H13 用 ssh `batman-slot apply` 寫入壞 rootfs payload:`SHA256SUMS` 用破壞後的 sha,讀回會過 → arm → 重開 → 只驗證「panic → 回原槽」這個機制。經 app 路徑的 UD4 等 P3 rc。
7. `--pre-p3-full`(W 證據)。
8. harness PR(附全部輸出;S / G 標 ❌,列為 P3 PR 的閘門)→ 使用者 merge → P3 實作。

## 16. 怎麼讓測試程式少改幾次(回答使用者)

1. **先驗工具,再寫測試**:每用到一個節點工具或新機制,先做最小的實測(E-H 系列),確認了才寫進單位。這兩輪審查抓到的工具問題都屬於這一類。
2. **抓資料與判定分開**:
   - 每一臂把節點的原始輸出存成 log(`/opt/batdata/dv-prov/<run>/` 拷回主機);
   - 判定是 `tests/judges/h4/` 裡的離線程式,吃 log、吐 PASS / FAIL;
   - 判定寫錯時,拿存下的 log 離線重判,不用重跑節點。
   - 判定程式本身有離線測試:每條判定都要有「餵壞的 log → FAIL」的案例(H3 的 `tests/judges/` 做法)。
3. **一次只跑一臂**:`prov-p3-254.sh <unit> --arm <id>`。開發時只跑正在改的那一臂(幾分鐘),每臂自帶前置與還原。
4. **舊版先 FAIL、新版再 PASS**:每臂先在 wsl.22 上確認 W 那一行會出現;P3 rc 出來後再確認 PASS 與 S。
5. **全套只當最後確認**:所有臂各自通過、程式碼審查過之後才跑全套。全套中途出錯 → 修好後只補跑出錯的臂,最後再完整跑一次當作 PR 證據。

## 17. 實測項目(E-H)

| # | 內容 | 狀態 |
|---|---|---|
| E-H1 | 桌機 BLE 掃描 | ✅ |
| E-H8 | 桌機 ↔ AP 上的手機;relay → 04:80 | ❌ 等手機(現場) |
| E-H9 | BLE:連線、讀 STATUS / CTRL、MTU ✅;NX session、notify、9 KiB、230 s ❌ | 部分 |
| E-H10 | Android 在 C0 ↔ ALT 之間切換要多久 | ❌ 現場 |
| E-H12 | `push-provd` 在 ujail 下 | ❌ 要改節點(§15-3) |
| E-H13 | 壞 rootfs → panic → 回原槽 | ❌ 現場 |
| E-H15 | ethsim 對 mesh / 前提檢查的影響 | ❌ 要改節點(§15-3) |
| E-H16 | `dv-sbx` 在 WSL + qemu 下能否用 | ❌ 唯讀,先做 |

## 附錄 A. 逐列對表

**欄位**:# | 來源(P3 片語)| 臂 | 載 | 誘發 | 斷言 | 負(W 寫出預期 FAIL 的那一行)

**簡寫**:「E_U」= `E_UNSUPPORTED`;「W(E_U)」= wsl.22 上第一個 P3 動詞回 E_U → 印 `FAIL <row>: <type> E_UNSUPPORTED`。

### A.1 `prov-p3-routes-254`

| # | 來源 | 臂 | 載 | 誘發 | 斷言 | 負 |
|---|---|---|---|---|---|---|
| RT1 | §8 動詞 × 角色 × owner-op 缺 / 錯 | matrix-ble | R | `peer.py call` 依 `p3-expect.tsv`(匿名 / 候選 / 成員 / 擁有者 × BLE) | 碼與 reason 逐一相等 | W(E_U,每列寫出預期的 type) |
| RT1h | 同上,HTTP 那一半 | matrix-http | RB(T 窗) | 同上 × HTTP | 同上 | S(`http-allow-nx` → NX 被接受);W 不適用(wsl.22 沒有 HTTP) |
| RT2 | §8 key 20 經 HTTP → `E_U{2: 19}` | key20-http | RB | | `E_U{1: typ, 2: 19}` | S(`k20-any-transport`) |
| RT3 | §6 首次:HTTP 不聽 | idle | R | 不開窗、BLE 健康 | relay → 8095 = refused 或 timeout;`netstat` 沒有 8095;同臂 relay → :80 = 200 | P(同一單位內開窗後同一個 relay → 8095 連得上) |
| RT4 | §5.1 legacy key 2 / 20 → 20 | legacy | L | | `E_U{2: 20}` | W(E_U,沒有 reason) |
| RT5 | §5.1 `status` scope 1 → 7;key 10–13 → 7 | matrix | R | | `E_U{2: 7}` | W(E_U,沒有 reason) |

### A.2 `prov-owner-254`

| # | 來源 | 臂 | 載 | 斷言 | 負 |
|---|---|---|---|---|---|
| OW1 | §8 add | add | R | Hx `auth/owner` 成功 | W(E_U `owner/add`) |
| OW2 | 重送輪替 | resend | R | 新 tag key ≠ 舊、舊的失效 | W(E_U)+ P(第一次 add 成功) |
| OW3 | remove 切 BLE + HTTP | remove | RB(T 窗) | 兩條 session ≤ 5 s Closed;provd log 的 session 數歸 0;Hx 重新交握被拒;`adv_owner_key` 輪替 | W(E_U)+ P(remove 前兩條都能用) |
| OW4 | 最後一位 | last | R(快照,`run/` 範圍) | 依序 remove Hx → H0b → H0:前兩次成功,第三次 `EForbidden "cannot remove the last owner"`(F-H6);快照還原;`s0_assert` | W(E_U) |
| OW5 | §5.2 remove 重送 | resend-rm | R | `E_FORBIDDEN` | W(E_U)+ P(第一次 remove 成功) |
| OW6 | §7 遺失手機:psk 失效 | psk | RB | 被 remove 的 Hx,psk_owner 交握失敗 | W(E_U) |

### A.3 `prov-settings-254`

| # | 來源 | 臂 | 載 | 斷言 | 負 |
|---|---|---|---|---|---|
| ST1 | get | get | R | 值 = uci;不含密碼(原值 grep 0) | W(E_U `settings/get`) |
| ST2 | 新卡 → 認領 → key 20 → 不重開 | fresh-k20 | F | (a)(b);boot_id 不變;p5 有新值 | W(F on wsl.22:E_U `settings/set`) |
| ST3 | `bulk.open ≠ 16` | fresh-bulk | F + RB | T pending 存在(P)→ `bulk.open` ok | W(E_U)+ P |
| ST4 | 已入網 key 20,plink 不斷、沒走退路 | member-k20 | R | `iw <mesh ifname> station dump` 的 `connected time` 遞增;logread 沒有退路行 | S(`setkey-full-restart` → connected time 歸零)+ P |
| ST5 | 新卡注入失敗 → AP 不在空中、`disabled=1`、MARK、p5 不變 | fresh-k20-fail | F + RB | 四項 + `E_REJECTED{13}` | S(`setkey-norollback` → AP 留著) |
| ST6 | 已配對注入失敗 → 舊帳密 | k20-fail | RB | hostapd = C0;手機 `authorized` | S(`setkey-norollback`) |
| ST7 | D-6 新卡上還原也失敗 | fresh-k20-rbfail | **F + RB** | rc 6;AP 封鎖不在空中;CRIT;`status` 回報;`E_REJECTED{13}` | P(注入確實生效:setkey log 有 rollback 讀回失敗的行);真正的負對照 = G |
| ST8 | 讀回 | readback | RB | 搭配 `setkey-apply-fail`:失敗被發現(→ 13) | S(`setkey-readback-skip` → 沒被發現,回 ok) |
| ST9 | passphrase 不外洩(cmdline / uci argv / logread / log / 診斷包) | secret | RB(`uci-argv` bind + `/proc/*/cmdline` 每 10 ms 取樣) | 節點上的計數 = 0;WSL 原值 grep = 0 | S(bind 一個用 `uci set …=$AP` 的 setkey 變體 → 計數 > 0) |
| ST10 | 密碼含 `$` → 13 | input | R | `E_REJECTED{13}` | W(E_U) |
| ST11 | 持鎖 15 s | lock | R | 成功;setkey 總時間 ≥ 15 s(持鎖者的時間戳)且 ≤ 230 s | W(E_U)+ P(持鎖者確實持有 15 s) |
| ST12 | commit 與讀回之間殺 helper → setkey 自己完成並還原 | kill-helper | RB(`setkey-apply-fail` + `setkey-pause`) | setkey 行程(另一個 pgid)繼續、還原完成、AP = C0;helper 重啟後一致 | S(`setkey-notrap` → setkey 停在一半) |
| ST13 | `/tmp/.uci/wireless` 暫存 → `E_BUSY` + `status` 回報 | staged | R | `E_BUSY`;`status` key 15 有 `uci_staged: [wireless]` | W(E_U)+ P(暫存存在) |
| ST14 | 未入網改國家 → 成功、p5 已存;`DE`(ch 40 不在它的表) | fresh-k2 | F | 成功;p5 有 | W(F on wsl.22:E_U) |
| ST15 | 已入網 key 2 → 14 | member-k2 | R | `E_REJECTED{14}` | W(E_U) |
| ST16 | 同值 set 在 p5 stale 時存檔 | stale | RB | p5 被存、沒有 reload | W(E_U)+ P(stale 已造成:`--check` 回 stale) |
| ST17 | 改名 U5 前 → rename-pending | rename | R | E_U(rename-pending) | —(行為不變) |
| ST19 | D-5 結束碼 | d5 | RB | 三種情況的 setkey rc 與線上碼依 D-5 的表 | P(注入生效);G |
| ST20 | D-7 SSID 不可存 | d7 | **F + RB** | 未入網的 key 2 成功、不被還原;`status` 回報「SSID 無法保存」(D-12) | S(`d7-ssid-rc6` → 被還原) |
| ST22 | Wi-Fi / BT 共存 | coex | R | 只記錄(P3 §9-8) | — 量測 |
| ST23 | §6 helper 重啟時 setkey 子程序還在 | = ST12 | | | |

### A.4 `prov-country-join-254`

| # | 來源 | 臂 | 載 | 斷言 | 負 |
|---|---|---|---|---|---|
| CJ1 | join 國家不符 → 14,`.txn` 不在、uci 不變 | join-mismatch | F | key 2 = `AU`、join N0(US)→ `E_REJECTED{14}`;`.txn` 不在;uci sha 不變 | W(F on wsl.22:key 2 由 root 以 uci 設 AU,join → 入網成功 → FAIL「joined with country mismatch」) |
| CJ2 | update 國家不符 → 14 | update-mismatch | R | 同上 | W(同上的手法:`network/update` 帶 AU → 套用 → FAIL) |
| CJ3 | 先 key 2 再 join 同國家 → 成功 | join-ok | F | 成功;02 看得到 04 的 plink | W(E_U key 2) |

### A.5 `prov-status-diag-254`

| # | 來源 | 臂 | 載 | 斷言 | 負 |
|---|---|---|---|---|---|
| SD1 | status 與 halow-status 一致 | status | R | 欄位逐一相等 | W(E_U `status`) |
| SD2 | 成員只拿摘要 | member | R | 只有摘要欄位 | W(E_U)+ P(session 的角色是成員:`auth` 回應) |
| SD3 | ro 10 / s × 10 分:沒有 `cfgsave-lock.busy`、poll 沒有 ERate、04 的廣播在 | ro-load | RB(T 窗,HTTP) | `cfgsave-lock.busy` 取樣 0 次;helper log 沒有 ERate;04 端 advertising instances 每次取樣 ≥ 1、provd log 沒有 withdraw | S(`ro-on-ctl` → ERate);P:peer 自己計數 ok + E_RATE ≥ 5400、ok ≥ 2500 |
| SD4 | bundle > 64 KiB、tar 可解、不含秘密 | bundle | R | 大小、`tar t`、原值 grep 0 | W(E_U)+ P(非空) |
| SD5 | handle 跨 session | handle | R | `E_REJECTED{15}` | W(E_U)+ P(同 session 取得成功) |

### A.6 `prov-bundle-gate-254`

| # | 來源 | 臂 | 載 | 斷言 | 負 |
|---|---|---|---|---|---|
| BG1 | claimed → 403 | claimed | R | 403 | W(wsl.22 → 200:「FAIL BG1: claimed node served the bundle」) |
| BG2 | legacy 沒有旗標 → 403 | legacy | L | 403 | W(200) |
| BG3 | unclaimed / legacy + dev-open → 200 | devopen | F + L | 200;刪旗標 → 403 | P |
| BG4 | `status` 仍 200 | status | R | 200 | —(不變) |

### A.7 `prov-http-254`

| # | 來源 | 臂 | 載 | 斷言 | 負 |
|---|---|---|---|---|---|
| HT1 | 正向 | pos | RB(T 窗) | Noise 交握成功;04 端 tcpdump 看到手機的 SYN / SYN-ACK | S(兩邊都 `http-nofw`,v5 `phy*-ap*` 規則 → 連不上)+ P(LISTEN) |
| HT2 | 平常不聽 | = RT3 | | | |
| HT3 | 停 bluetoothd 5 分 → 聽 | fb-bt | R | 5 分 ± 10 s 後連得上;早 30 s 連不上 | W(wsl.22 沒有 HTTP → 「FAIL HT3: not listening after 300 s」) |
| HT4 | `sc_file` 失效 5 分 → 聽 | fb-sc | RB | 同上 | S(`healthok-2field` → 不開) |
| HT5 | 恢復 → 不收新連線、既有保留 | fb-recover | R | | W(同 HT3)+ P |
| HT6 | psk_owner → 候選 → `auth/owner` | roles | RB(T 窗) | 成功 | P;W 不適用(wsl.22 沒有 HTTP),由 HT7 的 S 涵蓋 |
| HT7 | NX / psk_replay 被拒 | roles-neg | RB | 連線關閉 | S(`http-allow-nx`) |
| HT8a | mesh:偽造手機 MAC + IP + ARP → 連不上 | mesh-a | RB + ethsim | timeout;drop counter 增加 | S(兩邊都 `http-nofw`,不載 `batman_http_in` → 連得上)+ P(LISTEN、同路徑 :80 正向) |
| HT8b | 不偽造的洪流 → 連不上、poll 沒有 ERate、04 廣播在、擁有者傳完 | mesh-b | RB + ethsim + 手機 | 同上 + 手機完成上傳 + 04 端廣播 | 同上 |
| HT9 | lo | lo | RB | drop counter | P(LISTEN);S(同 HT8a) |
| HT10 | VLAN 雙層 | vlan | RB + ethsim | 04 端沒有 SYN-ACK、drop counter | S(兩邊都 `http-nofw`,v6 規則 → 有 SYN-ACK) |
| HT11 | docker0 + VLAN | docker | RB + ethsim(docker0) | 同上 | S(同 HT10) |
| HT12 | 刪表 → ≤ 8 s 不聽 | deltable | RB | ≤ 8 s 後 `netstat` 沒有 8095 | S(`http-nofw` → 仍在聽) |
| HT13 | reload → 兩張表、各一份 | reload | R | | W(wsl.22 沒有表 →「FAIL HT13: table missing」) |
| HT14 | `firewall stop` → ≤ 8 s 不聽 | fwstop | RB | | S(`http-nofw`) |
| HT15 | helper 停 → ≤ 8 s 不聽 | helper-stop | RB | | P(停之前在聽) |
| HT16 | §6 provd crash → HTTP 斷、上傳檔刪 | provd-kill | RB | 連線斷;tmpfs 用量 0 | P |
| HT16b | §6 provd 正常停止 | provd-stop | RB | 同上 | P |
| HT16c | §6 provd crash loop(`respawn 3600 5 0` 用完) | provd-loop | RB | 不聽;helper 正常 | P |
| HT17 | §6 hostapd / `wifi reload` | wifi-reload | RB | 手機重連後連得上 | P |
| HT18 | `auto_includes = 0` | autoinc | RB | 不給 `http.2` | S(`http-nofw`) |
| HT19 | D-3 別人寫 bit 24 | bit24 | RB | 不聽;`status` 回報 | S(`http-nofw`) |
| HT20 | D-8 非 `phy*` 的 frame 先清 bit | d8 | RB + ethsim | 在更早的優先序替 `h4v0` 打 bit → 仍被丟 | S(兩邊都 `http-nofw`,沒有清 bit 的規則 → 放行) |
| HT21 | D-13 AP iface 不在 bridge | d13 | RB | `http.2` 消失、`status` 回報 | S(`http-nofw`) |

### A.8 `prov-upload-254`(RB,T pending)

| # | 來源 | 斷言 | 負 |
|---|---|---|---|
| UP1 | AP 關 → 16 | `E_REJECTED{16}` | W(E_U)+ P(pending 存在) |
| UP2 | 非窗擁有者 | 拒 | S(`upload-noowner`) |
| UP3 | 來源 IP 綁定 | session 建在手機上,PUT 從 netns 經 `phy9h4` 送 → 拒 | S(兩邊都 `http-nofw` + `phy9h4`,只差 `upload-nosrcip`) |
| UP4 | 大小不符 → 15 | `E_REJECTED{15}` | W(E_U)+ P |
| UP5 | provd 寫超過 tmpfs → ENOSPC、其他正常 | 以 uid 471 在 tmpfs 直接寫超過 `size=`(模擬被入侵的 provd)→ ENOSPC;OTS、helper 正常 | P(用量到上限) |
| UP6 | 窗外的上傳檔被刪 | 檔先存在(P)→ 關窗 → ≤ 8 s 用量 0 | P |
| UP7 | 上傳中 `network/update` → `E_BUSY` | | S(`upload-nobusy`) |
| UP8 | 上傳中 helper 重啟 | 窗不在;重開窗重傳 → prepare 成功 | P |
| UP9 | `owner/remove` 清窗 | | W(E_U)+ P(窗存在) |
| UP10 | D-15 tmpfs 掛不上 | `bulk-mount-fail` → `bulk.open` 被拒;掛載點不是一般目錄 | P;G |
| UP11 | §7 本機非 root 搶建 `/tmp/run/batman-provd-bulk` | 停 provd → uid 65534 試建 → 失敗(`/tmp/run` 只有 root 能寫);root 預建 symlink → init 拒絕掛載、不啟動上傳 | P |

### A.9 `prov-update-254`

| # | 來源 | 臂 | 載 | 斷言 | 負 |
|---|---|---|---|---|---|
| UD-T1 | §8 bench「T 簽的被拒」(常規,不需要 YubiKey) | t-reject | **R** | `update.check` → `{1: false, 2: 11}` | S(同一個 manifest 在 RB 上 → 通過) |
| UD1 | T 簽 → trial → commit → 5 | main | RB → T | phase 2 → 3 → 重開 → 4 → commit → 5 | W(E_U `update/check`) |
| UD2 | 同版本重試退回 → 6 | same | RB → T | hold 不 release、等試用期限 → revert → 6(不是 5) | W(E_U)+ P(revert 確實發生) |
| UD3 | arm 前斷電 → 0 | kp-before | RB(`upd-before-arm`) | phase 0;tryboot 旗標不在 | S(`upd-after-arm` → 不同的 phase) |
| UD3b | §3.7.4 B6:arm 之後、同一次開機 helper 掛掉 → disarm、報 3 | arm-crash | RB(`helper-arm-crash`) | helper 重啟後 tryboot 旗標被清、phase 3 | G(P3 單元)+ P(旗標先存在) |
| UD4 | 新版沒開機成功 → 6 + 18 | badroot | RB → T(壞 rootfs) | panic → 回原槽;6 + 18 | P(boot-reasons 有 panic 行) |
| UD5 | 舊的 bad-slot 不造成假 6 | oldbad | RB | 先造 bad-slot(P)→ 正常更新 → 5 | W(E_U)+ P |
| UD6 | worker 失敗的 reason | worker | RB | 1 / 11 / 12 / 17 各一 | W(E_U)+ P(每種失敗都真的發生了) |
| UD7 | 簽章錯 / serial < min / 板子錯 / 降級 / min_from / 開機設定不符 / 版本解析失敗 | reject | RB | reason 逐一相等 | W(E_U) |
| UD8 | 惡意 tar ×4、FIFO、上傳後改 payload | malicious | RB | 11;目標槽 BAD、不 arm | W(E_U) |
| UD9 | prepare 中 kill / 斷電 | kill | RB(`upd-write-mid`;kill -9) | 槽 BAD、仍跑舊槽 | P |
| UD10 | helper 重啟後 phase 3 重建 | rebuild | RB | phase 3 | W(E_U)+ P(重啟前 phase 3) |
| UD10b | §6 重開 → pending 消失 | reboot | RB | 重開後 `update.status` 沒有 pending | P |
| UD11 | 回滾 / **降級到 pre-P3** | downgrade | R → ssh sysupgrade 到 wsl.22 | 舊槽沒有 P3 動詞;`.txn` 相容;舊版判 stale 直到它自己 `--save`;舊版 96 照樣套用 ssid 行;update-last 留著沒人讀;`s0_assert` 用 S0-pre 版 | P |
| UD12 | 升級臂:未入網 P2 → P3 → `--check` fresh | upgrade-unjoined | F(wsl.22)→ ssh sysupgrade 到 P3 | `--check` fresh | G(H4-U8) |
| UD12b | 升級臂:已入網 → 下一個 joinwatch tick 存 p5 | upgrade-joined | R(wsl.22)→ sysupgrade | tick 後 fresh | P |
| UD13 | SSID 含 `'` 的節點升級後 OTA 不被擋 | quote-ssid | RB | `update.check` 通過 | W(E_U)+ P(SSID 確實含 `'`) |
| UD14 | sysupgrade 不寫沒列名的 dtb | sysupgrade | R | 沒有那個 dtb | S(`slot-copy-all` → 有) |
| UD15 | bench:YubiKey K 簽、release 設定節點 | bench | R | — | NEEDS-PERSON |
| UD16 | D-9 試用轉 committed 時存一次 | d9 | T | commit 後 p5 不 stale | G(H4-U8);節點上只有正向 |
| UD16b | P3 §3.3 非試用開機時存一次 | d9-boot | RB | p5 只因新 key 而 stale(P)→ helper restart → 存 | S(`p5-autosave-off` → stale 留著) |
| UD17 | D-10 | d10 | RB | (a) 同版本又失敗只報 6;(b) `slot-reboot-fail` → tryboot 旗標不在 | S(`d10-no-disarm`) |
| UD18 | D-14 | — | C(`dv-sbx`) | write 被 TERM → `.busy` 不在 | S(沒有 trap 的變體 → 留著) |
| UD19 | D-12 `update.check` 不拿 `n.mu` | d12 | RB(`setkey-pause` 中;provclient 直接打 helper) | ≤ 5 s 回應 | S(`d12-take-mu` → 卡住到 pause 結束) |

### A.10 `prov-autocommit-p3-254`(§5.6 的流程)

| # | 來源 | 臂 | 載 | 斷言 | 負 |
|---|---|---|---|---|---|
| AC1 | 正常 provd → commit | pos | T + RD | T:committed;RD:刪 `provd-stable` → 70 s → COMMIT | S(`provd-id-pid` → REVERT) |
| AC2 | provd 壞掉 → revert | badprovd | RD | 刪檔、provd 停(enabled)→ REVERT | S(`ac-noprov` → COMMIT) |
| AC3 | helper 不在 → revert | nohelper | RD | REVERT | S(`ac-noprov`) |
| AC4 | 穩定 60 s 後被殺 → 仍 commit | stable-kill | RD | 刪檔 → 70 s → kill provd → COMMIT | S(`provd-id-pid` → 檔不會寫 → REVERT) |
| AC5 | provclient 掛 60 s 不算 | provclient | RD | 刪檔、provd 停、provclient 掛 70 s → REVERT | S(`provd-id-pid` 之外的對照:讓 provclient 冒充 PPid 不成立 → G) |
| AC6 | provd 停用 → 只 WARN、commit | disabled | RD | COMMIT + WARN | S(`ac-provd-required` → REVERT) |
| AC7 | D-16 helper 停用 → 只 WARN | d16 | RD | COMMIT + WARN | S(`ac-helperoff-err`) |
| AC8 | D-17 `inet fw4` 不在 | d17 | RD(假 `nft`) | REVERT | S(`ac-nofw4` → COMMIT) |

### A.11 其他

| # | 來源 | 單位 | 載 | 斷言 | 負 |
|---|---|---|---|---|---|
| TT1 | §3.9 轉賣工具 | transfer | C(loop)+ 真卡(NEEDS-PERSON) | §3.9 全部 | S(`--test-skip-wipe`) |
| LR1 | firstboot 後擁有者 / mesh / AP 仍在 | luci-reset | F(最後) | 三者都在 | W(wsl.22 的 `flash.js` 舊字串) |
| FB1 | 三張表 | fw-boot | R(開機後) | | W(wsl.22 沒有表) |
| FB2 | `nft -c` 閘門 | fw-boot | bench | rc 0 | S(壞 include 檔 → rc ≠ 0) |
| FB3 | `fw-badinclude` | fw-badinclude | W(02) | §8.3 | P(include 確實壞:`nft -c` rc ≠ 0) |
| EE1 | D11 | eeprom | C | §8.2 | W(1.5.12-wsl.9 rootfs) |
| PR1 | D-1 / D-2 / §9-4 | 探針 | 04 | §7 | v6 規則 |
| SEC1 | §7 非 root 的 fault 檔 | prov-sec 補 | R | setkey 照常還原;TAMPER | P |

**D 項對照**:
- D-1 → HT10、PR1;D-2 → PR1;D-3 → HT19 + lint;D-4 → HT8a / HT8b;
- D-5 → ST19;D-6 → ST7;D-7 → ST20;D-8 → HT20;
- D-9 → UD16 / UD16b;D-10 → UD17;D-11 → ST9;D-12 → UD19 + ST13 + ST20;
- D-13 → HT21;D-14 → UD18;D-15 → UP10;D-16 → AC7;D-17 → AC8。

## 附錄 B. v1 的處理

見 v2(d5cf7ed)的附錄 B。v3 沿用 v2 的處理,修正項見附錄 C。

## 附錄 C. v2 審查的處理

| 意見 | 處理 |
|---|---|
| A-B1 / B-B1 S0 在 pre-P3 建不起來 | §3.1 S0-pre / S0、W 的判法、`upgrade`;§15 順序(現場 → `--pre-p3-full` → PR);H4-U7 |
| A-M1 / B-M5 跨重開的接縫 | §2 RB 的界線;D-9 交給 G(H4-U8);UD16b 改在 committed 上做 restart flip;UD12 → G |
| A-M2 / B-M6 / B-M7 dead-man | §5.7 undo journal + HT14 節點端保險;§4.4 deadline 帶 boot_id、LR1 排最後並重種、兩個 dead-man 的先後 |
| A-M3 / B-M1 工具 | F-H15 改正;listener = uhttpd、連線端 = `wget -T`;`netstat`;`ubus get_clients`;判定都在 04 端;netns 的 `syn_retries` 與並發上限 |
| A-M4 / B-M8 判定 | 廣播改在 04 端判;SD3 的 P 改成 peer 自己計數;UD19 走 provclient;HT3 改 W;HT11 改 docker0 + counter |
| A-M5 / B-M4 autocommit | `provd-id-pid` 改成 helper fault;§5.6 先刪 `provd-stable`;AC6 的變體改正 |
| A-M6 W 太粗 | §6.2:W 寫出預期的 FAIL 行,只在動詞層 FAIL 的另加 P;HTTP 類改 S |
| A-M7 / B-M9 T 被拒 | UD-T1(R,常規) |
| A-M8 / B-M9 漏列 | UD11 真的降級、UD3b、UD12b、UD10b、HT16b / HT16c、UP11、HT8 的 IP + ARP、D-12 對到 UD19 + ST13 + ST20 |
| A-M9 壞 rootfs | §8.1 改成破壞 superblock magic |
| B-M2 br-ots | HT11 改 docker0 |
| B-M3 換規則的 S | §6.2:兩邊都 `http-nofw` + LISTEN;UP3 用 `phy9h4` |
| B-M10 未探的假設 | E-H9 部分完成(F-H3);qemu 已裝(H4-U10);`py.exe` 改絕對路徑(F-H31);bleak 依 hash 重裝 |
| A-m1 V 沒定義 | §2 T:V = 受測 rc;`s0_assert` 斷言版本 |
| A-m2 UD2 / serial | UD2 用 hold 等期限;`min-serial = 2`(§8.1) |
| A-m3 封閉清單 | §5.2、§5.3、§5.5;`batman-slot` 不 bind,D-14 改在 C |
| A-m4 provd 的 pid | §5.1 |
| A-m5 探針的基準 sha | §7 用 `nft -s` |
| A-m6 / B-M1-5 VLAN 回程 | §4.5 靜態 neighbor;判定在 04 端 |
| A-m7 MAC + IP + ARP | §4.5、HT8a |
| A-m8 docker0 VLAN | HT11 |
| A-m9 `fw-badinclude` 的斷網 | F-H33、§8.3 |
| A-m10 Windows 讀得到庫 | §3.2 界線 |
| A-m11 C0 怎麼交付 | §3.2 QR |
| A-m12 / B-m3 手機 IP | §4.3 |
| A-m13 供應鏈 | §12 |
| A-m14 / B-M10-2 E-H16 | 已裝 qemu;隔離用 `dv-sbx` setup;E-H16 先唯讀確認 |
| A-m15 OW4 | OW4 的順序與 `EForbidden` |
| A-m16 ST4 | `setkey-full-restart` |
| A-m17 / B 不注入 → 正常 | 改標 P + G |
| A-m18 UP7 / HT8 的副作用 | §13 |
| A-m19 假 `nft` 靠 PATH | §1.4 第 5 點 |
| A-m20 / B-M3 pre-P3 判斷 | §6.1:`provd-p3` 標記 + 版本寫死 |
| A-m21 / B-m2 片語 ID | §6.3 |
| A-m22 / B-m10 F 的細節 | HF、新末 4 碼、`none` 登入 |
| B-m4 手機自己說的結果 | §4.3 節點端佐證 |
| B-m5 ST11 | 改成量時間 |
| B-m6 UP5 | 以 uid 471 直接寫 tmpfs |
| B-m7 UD19 | provclient |
| B-m8 壞 rootfs 的確定性 | §8.1 |
| B-m9 §7 改 AP | 不改:手機在現場時先連上 C0 |
| B-m11 孤兒 blebridge | §4.2、§11 |
| B-m12 test init | §5.3 lint;退路 `upper-provd` |
| B-m13 pending 殘留 | §1.4 第 4 點;`pending-del` |
| B-m14 副作用 | §13 |
| B-m15 hostapd conf 路徑 | §3.1 從 `network.wireless status` 取 |
| B-m16 chain1 證據 | F-H34 |
| B-m17 `batman_opf` 引用 | §5.4 |
| B-m18 HT3 | 改 W |
| B-m19 秘密斷言 | §4.1 原值 grep;C0 / ALT 高熵;CJ1 的 W 理由改正 |
