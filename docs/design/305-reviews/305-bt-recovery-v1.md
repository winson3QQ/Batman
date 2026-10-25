# #305 Pi 4 藍牙 UART:偵測與自動恢復(設計 v1)

**狀態**:v1,送兩位對抗式審查(第 1 輪)。**範圍**:使用者 2026-10-24 決定獨立 PR(不併 PR-P2)。
**基準**:Batman `main` a62bf78、firmware `build-3aplus` 72814fa4、fleet `1.5.12-wsl.15+0328e83.fw84cede4`(02 = 10.41.1.1、04 = 10.41.1.3,都 S0)。

## 1. 問題與現場影響

開發用 WM1302 HAT 的 GPS 佔用 PL011(GPIO14/15),藍牙因此走 mini UART(`distroconfig.txt [pi4] dtoverlay=miniuart-bt`)。mini UART 接收溢位會讓 H4 失去同步,結果有兩種:

| 失敗 | 現場後果 |
|---|---|
| **開機 init 失敗**(`0x1001` / `0x0c0d` / `0xfc79` tx timeout,`No default controller available`) | 這次開機機台不廣播 → app 找不到機台;今天只有重開能恢復 |
| **運行中卡死**(`0x200c` tx timeout 一路下去,掃描回 0 台) | 同上,直到重開 |
| 運行中偶發 `Frame reassembly failed`(未卡死) | 少收幾個廣播 / 事件,kernel 自己重新同步 |

量產(CM4 + HAT v2)提案把藍牙放回 PL011(`hat-v2-spec.md` O13);本設計**不改 UART 配置**,只做「偵測 + 不重開的恢復」,量產也保留(任何 UART 上的控制器都可能卡住)。

## 2. 實證(2026-10-24,#305 留言 6369223548、6373948374)

| 條件 | 開機 | init 失敗 | 5 分鐘掃描段 | 掃描中出錯 |
|---|---|---|---|---|
| mini UART,閒置時重開 | 40 | 0 | — | — |
| mini UART,掃描中重開 | 30 | 1 | 30 | 4(1 次卡死) |
| PL011(02 拿掉 `miniuart-bt`) | 10 | 0 | 10 | 0 |

- E1 每次 hci0 出錯,同一 30 s 取樣窗內 mini UART `oe` 0 → ≥1;PL011 上 113 筆取樣 `oe` 全 0。
- E2 init 失敗時 ttyS0 `tx:18 rx:22 oe:1`;乾淨開機每次都是 `tx:65595 rx:4349`(70 次)。
- E3 init 失敗當下 `unbind` / `bind` `serial0-0`(`/sys/bus/serial/drivers/hci_uart_bcm/`)→ 15 s 內 `Powered: yes`、current settings `powered le secure-conn privacy`、`batman-sc` `mode=2 status=0`,bluetoothd 沒重啟(1/1)。
- E4 bluetoothd 在 index 加入時走 `index_added`(bluez 5.72 `src/adapter.c:10608`)→ `read_info_complete`(`:10236`)→ patch 900 每次重送 `SET_SECURE_CONN` 並寫 `batman-sc` → rebind 後 SC-only 由 bluetoothd 自己恢復。
- E5 mgmt `READ_INFO` 是 kernel 快取,不碰控制器;`GET_CLOCK_INFO`(BDADDR_ANY)在 kernel 就回 0x02,UART 收發 0 位元組。**HCI raw socket 送 `Read_Local_Version_Information`(0x1001)** 會真的走 UART(tx +4、rx +15 / 次),往返 1 ms(兩台各數百次 `status0`)。
- E6 **卡死時現有訊號全部說謊**(04,2026-10-24 08:11,以 E7 誘發):health `hci0_powered=1 privacy=1 sc=1`、`bluetoothctl show` `Powered: yes Discovering: yes`、`READ_INFO` Powered=1;**只有 0x1001 探測 `noreply`(5.2 s)**。dmesg 與自然卡死相同:`0x200c tx timeout`、`Unable to disable scanning`、`Frame reassembly failed`,ttyS0 `oe:9`。
- E7 誘發:HCI raw socket 送 BCM vendor `0xfc18`(Update UART Baud Rate)= 115200,主機端仍 230400 → 3 s 後探測 `noreply`。**rebind 後恢復**:探測 `status0`、新掃描 40 s 看到 9 台、health `privacy=1 sc=1 sc_file=1`(1/1;運行中卡死的恢復證據)。
- E8 自然卡死的獵捕(兩台持續掃描、每 20 s 探測)仍在跑;結果回填。

## 3. 設計

### 3.1 誰做
`batman-provhelper`(root,S89,procd 無限 respawn)新增 `btwatch` goroutine。理由:它已是 BLE health 唯一寫者(`health.go`)、是 root(rebind 要寫 sysfs)、P2 的 provd 是非 root 不能做。

**順序修正**:`btwatch` 與 health 在讀 keystore **之前**啟動(今天 `main.go:397-399` 讀不到身分就 `select{}`,health 不會跑 → 沒身分的節點也要能恢復藍牙)。

### 3.2 偵測(每 15 s,與 health tick 同步)
1. `serial0-0` 存在於 `/sys/bus/serial/devices/` 但沒有 `driver` 連結 → **UNBOUND**(上一個 helper 死在 unbind 與 bind 之間)→ 立即 bind,不計入次數。
2. bluetoothd 在跑且 `READ_INFO` index 0 回 `Invalid Index`(沒有 hci0)或 Powered=0,**持續 ≥ 45 s 且 uptime ≥ 60 s** → **DOWN**。
3. Powered=1 時送 0x1001 探測(3 s 期限);**連續 2 次**沒有 Command Complete → **WEDGED**。
4. rfkill 對 bluetooth 是 blocked(之後 EMCON)→ 不偵測、不恢復(`/sys/class/rfkill/*/type == bluetooth` 且 soft/hard = 1)。今天 kernel 沒有 rfkill 裝置 → 條件恆假。

### 3.3 恢復
- `unbind` → 500 ms → `bind`(兩次寫入中間不讓出;SIGTERM 在這段期間延後到 bind 完成)。之後 30 s 內不再判斷。
- 次數上限:每次開機 3 次,間隔至少 60 s / 300 s / 900 s;用完 → `bt_state=gaveup`,不再動作,**不重開機**(HaLow mesh 比藍牙重要)。計數存在 root-only run dir(`$RUNDIR/btwatch.state`),helper respawn 不會歸零。
- 每次恢復寫一行到 `/opt/batdata/log/bt-recover.log`(p6,root 0600,超過 64 KiB 就截成後半):`<UTC> boot=<8> up=<s> why=<down|wedged|unbound> n=<k> result=<ok|fail>`。同時 `logger -t btwatch`。

### 3.4 health 檔(契約變更,只在行尾加欄位)
`... bondable=0|1 hci0_alive=0|1 bt_state=ok|down|wedged|recovering|gaveup|rfkill bt_recover=<n>`
- `hci0_alive=1` = 最近一次 0x1001 探測成功(≤ 30 s 前)。
- `ble-ok` 的「Powered 連續 10 分鐘」改成「`hci0_alive=1` 連續 10 分鐘」(卡死但 Powered=1 不算)。
- 讀者:autocommit(`batman-autocommit:497-499`,依序比對 `bluetoothd=1 … hci0_powered=1 … adv_registered_once=1`,行尾加欄位不受影響;**仍維持 WARN-only**,因為 `adv_registered_once` 在 P2 前恆為 0)、`scripts/node/prov-p1-254.sh:44-48`(逐鍵讀,新鍵不影響)、`halow-status` 加一行 BT 狀態。

## 4. 擁有權

| 資源 | 唯一寫者 | 唯讀者 |
|---|---|---|
| `/sys/bus/serial/drivers/hci_uart_bcm/{bind,unbind}`(serial0-0) | btwatch | — |
| `$RUNDIR/batman-prov.health` | helper health(既有) | autocommit、harness、halow-status |
| `$RUNDIR/btwatch.state`(新) | btwatch | halow-status |
| `/opt/batdata/log/bt-recover.log`(新) | btwatch | 人、harness |
| p6 `ble-ok` | helper health(既有,條件改) | autocommit |
| hci0 控制器 | kernel(btwatch 只送唯讀命令 0x1001) | bluetoothd |

## 5. 生命週期

| 路徑 | 今天 | 之後 | 測試 |
|---|---|---|---|
| 首次開機 | init 失敗就整個 boot 無 BLE | 60 s + 45 s 後 rebind | T1 |
| 開機 | 同上 | 同上;init 正常時探測每 15 s 1 次 | T1、T4 |
| 運行中卡死 | 到重開為止 | 2 次探測失敗(≤ 30 s)→ rebind | T2 |
| 乾淨關機 / 重開 | — | helper K15 停;rebind 中收到 SIGTERM → bind 完才結束(≤ 1 s) | T5 |
| helper crash / respawn 迴圈 | — | 次數從 state 檔讀回;UNBOUND 自癒 | T3 |
| bluetoothd restart | — | bluetoothd 不在時不判斷 | T6 |
| OTA trial / autocommit | BLE gate WARN-only | 不變(WARN-only,`adv_registered_once`) | 既有 |
| 斷電 | — | state 在 tmpfs 歸零;log 最後一行可能殘缺(讀者忽略) | — |
| 降版到沒有 btwatch 的 image | — | 新欄位消失,讀者都容忍缺鍵;p6 log 留著無人寫 | 降版 tier A |
| bcm2710 | 暫不支援(P-U14) | 沒有 `serial0-0` / 不是 `hci_uart_bcm` → btwatch 不動作 | 程式分支 + 單元測試 |

## 6. 安全

- 新輸入:無外部輸入。btwatch 讀 sysfs、mgmt、HCI raw socket(皆 root / kernel 提供),寫 root-only 路徑(`$RUNDIR` #280、p6 log 0600),sysfs 路徑與裝置名寫死。
- 非 root 本機程序:不能寫 bind/unbind、run dir、p6 log;不能讓 btwatch 誤判?→ 能讓控制器真的忙(例如非 root 不能開掃描;bluetoothd dbus policy 只給 root / provd)。最多讓 btwatch 用完 3 次後放棄 = 與今天相同的狀態(無 BLE),不會擴大權限。
- 被攻陷的 provd(P2 之後):可透過 bluetoothd 做大量掃描 / 廣播把 UART 打到溢位 → 觸發恢復;上限 3 次 → 之後無 BLE。可用性降級,沒有權限提升。
- HCI raw socket 只送 0x1001(唯讀);過濾器只收 Command Complete / Status。
- Fail mode:恢復失敗 = 沒有 BLE(fail-secure,佈建不可用,不會開放其他路徑)。

## 7. 測試(先進 harness PR,再上產品 PR)

| # | 測什麼 | 怎麼誘發 | 斷言 | 負對照(wsl.15) |
|---|---|---|---|---|
| T1 | init 失敗等價(沒有 hci0) | `unbind serial0-0` 後不 bind | ≤ 150 s 內 hci0 回來、`bt_state=ok`、log 一行 `why=down` | 不會回來 → FAIL;測試自己 bind 還原 |
| T2 | 運行中卡死 | HCI vendor `0xfc18` 把控制器鮑率改掉(主機仍 230400)→ 之後命令都 tx timeout | ≤ 90 s rebind、0x1001 探測恢復、privacy + SC-only 仍在、`why=wedged` | 不會恢復 → FAIL;還原 = 測試自己 rebind |
| T3 | 死在 unbind 與 bind 之間 | `unbind` 後立即 `kill -TERM` helper | respawn 後 ≤ 30 s bind 回來 | 留在 unbound |
| T4 | 不誤判 | 掃描 10 分鐘 | `bt_recover` 只在有探測失敗紀錄時增加 | — |
| T5 | 次數上限 | T1 連做 4 次 | 第 4 次 `bt_state=gaveup`,沒有重開 | — |
| T6 | bluetoothd restart | `/etc/init.d/bluetoothd restart` | 不觸發恢復 | — |

- 單元測試:狀態機(假探測 / 假 READ_INFO)、次數與間隔、rfkill、UNBOUND。
- T2 的誘發已在 04 試過(E7):探測確定失敗、rebind 確定恢復。

## 8. 不做 / 留在 #305 的殘項

- 關機前讓控制器斷電(降低「上一個 boot 的流量撞到 init」):E2 只有 1 例支持,沒有證據有效 → 不做;init 失敗由恢復處理。
- 降低 mini UART 鮑率、DT 加 `uart-has-rtscts`:沒驗證 → 不做。
- 藍牙回 PL011:量產 HAT v2(O13),開發 HAT 上 GPS 佔用 PL011。
- autocommit BLE gate 改為阻擋:P2(有廣播之後)。

## 9. 待使用者決定
(審查後補)
