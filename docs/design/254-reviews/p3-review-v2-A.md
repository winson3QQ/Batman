# #254 PR-P3 設計 v2 審查(審查者 A)

對象:`docs/design/254-p3-impl.md` v2(feat/254-p3 @ 03963d9,base main 2ecf1cb)。審的是整份文件,不只看 v1 之後改的地方;§12 宣稱的處理方式逐條對過原始碼。
證據來源:同一棵樹的原始碼(`file:line`)、firmware-2710 的 build_dir(libuci 原始碼)、04 上的唯讀指令(`1.5.14-wsl.22+2ecf1cb.fwce20a68`)。
**自首**:我在 04 上執行過一次 `halow-status json >/tmp/x.json`,在節點的 tmpfs 留下一個暫存檔。發現後已確認內容是我剛產生的 JSON,並且已經刪掉(`ls /tmp/x.json` → No such file)。除此之外沒有任何寫入。

**結論:REJECT(範圍窄)**:BLOCKER 0 / MAJOR 5 / MINOR 15。
v1 的兩個 BLOCKER 都已經修好(BLE 和 HTTP 的槽 / 額度分開；在 Go 用白名單解析 tar,而且先驗簽)。這次的 5 個 MAJOR 是同一類問題：設計自己新增的寫入路徑，與現有元件(halow-setkey、keyguard、config-save、libuci)沒寫明的假設互相衝突。修法都在局部，不需要改架構。

---

## MAJOR

### M1. 手機 AP 配對(key 20)繞過了 halow-setkey 和 keyguard:剛認領的節點配對後 AP 仍然關著，要等重開;擁有權表也寫錯

**情境(現場)**:新卡 → 未認領 → `99zz` / helper `--apply-state --firstboot` 把每個 `mode=ap` 的 key 設成 `CHANGE-ME-NOW`(`99zz-batman-prov-state:30-35`、`main.go:458-467`)→ S18 `halow-keyguard` 看到 placeholder,就寫 `wireless.default_radio0.disabled=1` 與 `/etc/halow-keyguard.blocked`,並且 `uci commit wireless`(`halow-keyguard:31-41`)。認領(P1/P2)不會改 AP key:Go 裡沒有 `--ap`,只有 `main.go:463` 寫 placeholder。
D14 的配對 = `settings/set` key 20。依 §3.3 的表，它只寫 `.ssid` / `.key`,再 `wifi reload radio0`。**`disabled=1` 還留著** → AP 不會起來 → app「用新帳密重連」失敗 → `bulk.open` 看到 disabled,回 reason 16(「AP 關著」)。要等下次開機,keyguard 看到 MARK 而且 key 已經不是 placeholder,才會解除(`halow-keyguard:42-47`)。所以擁有者認領後**第一次**想更新，一定會失敗。D13 說「AP 關著是人的決定」,但這裡的 disabled 其實是 keyguard 造成的，節點分不出這兩種情況。

**其他證據**:
- 現成的唯一入口是 `halow-setkey --ap`:它會解除 keyguard 的 MARK / disabled、拿 `halow-setkey.lock`、讀回確認、persist(`halow-setkey:2-31`、`:213-227`、`:287-294`)。設計另外開了一條 uci 寫入路徑，違反「只做必要的修改」,也讓 wireless 多了一個不拿 `halow-setkey.lock` 的寫者(`99-batman-chanfix` 每次 reassert 都會拿這把鎖，見 setkey 標頭 `:16`)。
- §4 擁有權表說 keyguard 對 `default_radio0` 是「只讀」,這是錯的：它寫 `disabled` 並且 commit 整個 wireless。表上 ssid 的寫者寫成「99zz」,實際上寫 ssid 的是 `99-halow-identity:19-21`(SSID = hostname);99zz 只寫 key。
- `wifi reload radio0` 的參數會被忽略。04 `/sbin/wifi`:`reload) wifi_reload "$2"`,而 `wifi_reload() { ubus call network reload; }`。所以 §3.3「只動 5 GHz」的依據不成立;這個副作用要 H4 實測,不能寫成事實。

**修正**:key 20 改走 `halow-setkey`:新增 `--ssid`(同一把鎖、同一套讀回、同一次 persist、同樣解除 keyguard)。§4 改成：ssid / key 的寫者 = halow-setkey(helper 經由它)、99-halow-identity(只在新卡時)、99zz / helper firstboot(只寫 placeholder key);`disabled` 的寫者 = keyguard、halow-setkey。設計裡寫明「配對成功 = AP 起來，而且讀回確認」。
**負對照**:新卡 → 認領 → key 20 → 不重開。要求 30 s 內 `hostapd.phy1-ap0` 存在、`get_clients` 可連、`bulk.open` ≠ 16。照 v2 的寫法，這個測試應該 FAIL。

### M2. SSID / 密碼的驗證規則跟 config-save 的字元禁止集衝突：大約 9 成的隨機密碼會被當成 `E_STORAGE`

**證據**:`batman-config-save:53` `UNSAFE='*[\`$();|&<>'"'"']*'`(96 的 `valid_batch` 也拒絕同一組字元，`96-batman-config-migrate:38`)。PRESERVE 裡的值含這些字元時，不會寫進 p5,而是記進 `REJECTED`(`:461`),`--save` 回 rc 6(`:557`、`:548`)。`halow-setkey:30` 也寫明 key 不能含這些字元。
§3.3 key 20 的規則是「12–63 個可列印 ASCII」;§3.11.5 要求 app 產生「≥ 20 字隨機密碼」。可列印 ASCII 共 95 個字元，其中 10 個被禁止,20 個字全部安全的機率是 (85/95)^20 ≈ 11%。依 §3.3 步驟 3,rc 6 會被當成 `--save` 失敗 → 還原 → 回 `E_STORAGE`。使用者看到的是「儲存壞了」,實際上是輸入不合法(應該回 reason 13)。SSID 含 `'`,或改名後的 hostname,也會碰到同一個問題。
另外:P2 的 `applyNet` 把 `SaveTxn` 的 rc 6 當成成功(`node.go` `if rc, out := n.Sys.SaveTxn(token); rc != 0 && rc != 6`)。所以只要有任何一個 PRESERVE 值不合法，國家(M4)、SSID 這類值就會**默默沒有寫進 p5**,下一次 OTA 之後回到舊值:手機用配對時的帳密連不上更新後的節點。

**修正**:helper 的驗證規則採用與 config-save 相同的禁止集，違反時回 reason 13。CDDL 與 §3.11.5 寫明 app 的字元集(例如 `[A-Za-z0-9._~+=,:@%^*-]`)。rc 6 在 settings 路徑上對應 reason 13,並且不能出現「live 已經改了、p5 沒改」的狀態。
**負對照**:用含 `$` 的密碼呼叫 key 20 → 必須回 `E_REJECTED{13}`,live 與 p5 都不變。照 v2 的寫法會回 `E_STORAGE`。

### M3. 「helper 用私有 uci savedir,不會 commit 別人的暫存」不成立(libuci 原始碼),所以「失敗回到之前的狀態」不完整

**證據**(firmware-2710 `build_dir/.../uci-2025.01.20~16ff0bad`):
- `libuci.c:63-64`:新的 context 一建立,`/tmp/.uci` 就在 `delta_path` 裡。
- `delta.c:99-125` `uci_set_savedir`(CLI 的 `-t`,`cli.c:744-745`)只是把新目錄**加到** `delta_path` 尾端，不會移除 `/tmp/.uci`。
- `delta.c:329-337` `uci_load_delta` 會套用**所有** `delta_path` 裡的 delta,但只 flush `savedir` 裡的那份。
- `file.c:760-788` commit 時 `uci_load_delta(ctx, p, true)`:別人暫存在 `/tmp/.uci/wireless` 的變更會被寫進 `/etc/config/wireless`,而且**留在** `/tmp/.uci` 裡沒有清掉(之後還會再被套用一次)。

**影響**:操作員(或任何 root 腳本)暫存了一半的 wireless / system 變更時，執行 `settings.set`,會把那些變更一起 commit,並由 `--save` 寫進 p5。失敗時的還原只寫回 helper 自己記下的舊值，別人的變更還是在 → 違反「失敗就回到之前的狀態」。§4 擁有權表與 §12 A-M4 / B-M5 的回應都是以這個不成立的前提為基礎。

**修正**:刪掉這個宣稱。wireless 部分照 M1 改走 halow-setkey。`system.hostname`:commit 前若 `/tmp/.uci/<pkg>` 不是空的，就回 `E_BUSY`(fail-closed),或者把現有暫存原樣記下、在還原時一起處理。兩種都要寫明，並附負測試。
**負對照**:先 `uci set wireless.radio0.channel=44`(只暫存、不 commit)→ 執行 key 20 → 斷言 `/etc/config/wireless` 的 channel 沒變。照 v2 的寫法會變成 44。

### M4. 國家寫進 txn 只有三行;P2 交易裡的寫入入口、驗證、Finish 的期望值、能不能還原，都沒有設計(v1 A-M2 / B-M6 實際上還沒處理)

**證據**:
- `halow-setkey` 沒有設國家的參數(F7);它依 radio 的國家驗 `--channel`(`halow-setkey:30-31`)。設計寫「netJoin 在 halow-setkey 之前 `uci set` radio1 / radio0 country」,但沒說用哪個 savedir:若用 M3 的私有 savedir,setkey 讀不到，會用舊國家驗頻道;若用預設 savedir,就是在 setkey 的鎖之外多一個 wireless 寫者。
- `applyNet` 在動手前先跑 `CheckRestorable(k, id, ch)`(`node.go:1112-1118`,用 setkey `--check-only` 驗快照)。這個介面沒有國家，所以快照的國家能不能放回去，沒有人驗。
- Finish 的期望值來自 `desired(rec, tx)`(`wtxn.go:165`):**已經 commit 的**交易，期望值是紀錄裡的 net_config,不是快照。設計只寫「還原時先還原國家」,沒有寫 commit 之後的 Finish(斷電在 Txn3 到 Txn5 之間)要套用的是**紀錄裡的國家**,也沒寫 `satisfied()` / `uciIs()`(`wtxn.go:209-227`)要比對國家。
- 改國家能不能讓 morse 真正換到新的 regdomain / 頻道表(只執行 `wifi reload` 夠不夠),沒有任何證據(F7 只證明 setkey 不設國家)。
- `network/update` 帶新國家 = 整個 mesh 換國家。這個行為的生命週期(成員節點的版本不一致時怎麼辦)沒有寫。

**修正**:`halow-setkey` 加 `--country`,作為唯一入口(同一把鎖、依新國家驗頻道、讀回確認)。`wantWireless`、`CheckRestorable`、`satisfied`、`uciIs` 加入國家。`.txn` 第 4 行的格式照設計。H4 在每個 seam(Txn1 到 Txn5)各斷電一次,斷言國家的結果:commit 前 = 快照,commit 後 = 紀錄。在 04 上先實測「改國家 → morse 的頻率真的變了」(`iw` / `morse_cli`),才寫進設計。

### M5. 不需任何憑證，就能從 mesh / eth 擋掉上傳窗與 HTTP 備援:HTTP 的 2 個槽、10 次/分額度由 AP client 與 mesh 來源共用

**情境**:上傳窗開著時,listener 綁在 br-ahwlan 的位址上。§3.8.1 的 `LocalAddr` 檢查只看目的位址，所以 mesh(bat0)與 eth0 上的任何主機都連得到 `/session`。HTTP 交握的全域額度是 10 次/分，槽有 2 個,fake path 佔槽 10 s;每 IP 3 次/分的限制，在 L2 bridge 上換幾個來源 IP 就繞過了(bat0 是 L2 bridge,F9)。攻擊者不需要 PSK:每分鐘送 10 個錯誤的 msg1,擁有者手機在 AP 上就建不起上傳用的 HTTP session → 上傳窗 15 分鐘白白過去。BLE 不健康時，備援 HTTP 是**唯一**的管理通道，這就變成 v1 B1 的同一個問題，只是往下移了一層。§7 的負測試只驗 BLE 不受影響，沒有驗 HTTP 本身。

**修正**:(a) 只有上傳窗、沒有備援時(mode bit 2 而沒有 1):accept 時就檢查來源 IP 是不是本 AP 的 client(與 reason 17 用同一份快取),不是就直接關，不佔槽、不扣額度。(b) 備援模式:AP client 來源與其他來源用不同的槽和額度(例如 AP client 1 槽 + 自己的額度)。(c) §7 加一列負測試:mesh 上的主機以 20 次/分假交握 + 換 IP,期間 AP 上的擁有者仍能建立 HTTP session 並完成上傳。照 v2 的寫法，這個測試應該 FAIL。

---

## MINOR

1. **tar 的目錄成員與 gzip**:`build-ab-payload.sh:73` 用的是 `tar -czf ... boot`,會產生 `boot/`、`boot/overlays/` 兩個目錄成員，而且整包是 gzip。§3.7.4 步驟 4 寫「只收 regular file,目錄 → reason 11」,照字面執行會拒絕所有合法的 payload。要寫明：只允許這兩個目錄成員(其餘欄位忽略);用 `compress/gzip` 解壓;`root.squashfs` 的 tar header size 必須等於 `metadata size=`,且 ≤ 目標槽大小，否則 reason 11。
2. **開上傳檔時可能卡住**:provd 擁有那個目錄，可以把 `payload` 換成 FIFO,`open(O_RDONLY|O_NOFOLLOW)` 會一直等 writer → worker 卡住,`otaBusy` 一直是真的。要加 `O_NONBLOCK`,fstat 確認是 regular 之後才清掉這個旗標。另外，上傳檔目前有 provd、worker、重啟後的 helper 三個刪除者，要收斂成一個;helper 重啟時若 `batman-slot.lock` 的持有者還活著，就不要刪解出的 boot 目錄。
3. **key 8 檢查錯了分割**:config.txt 不在 payload 裡(`build-ab-payload.sh:18`),每個槽用的是自己 boot FAT 上的 config.txt。要檢查的是**目標槽**的(Pi 4 是 p1 或 p3;Pi 3 還有 p7),不是「本機 p1」。現在跑在 B 槽時剛好對，跑在 A 槽時就錯了(會由 trial 退回，屬於 fail-safe,但 reason 5 的意義就失去了)。
4. **update-last 用版本字串判讀**:重裝同版本(`=` 允許)時 from = to,退回之後會先命中「= to 且已 commit → 5」→ app 顯示成功。改用槽代號判讀(`batman_slot=`,寫入時記 `{from_slot, to_slot}`)。
5. **`LocalAddr` 允許清單其實不限制進來的介面**(Linux 是 weak host model):容器連 10.41.1.3,LocalAddr 一樣是 10.41.1.3。真正擋住的是 fw4:04 上 `input_dockert → drop_from_dockert`,而 docker0 是 accept 的。§3.8.1 的「不含 docker0、br-ots」要把證據改成 fw4 的規則。
6. **`hostapd.phy1-ap0` 寫死**:phy 的編號取決於核心 probe 的順序(04 上 radio0 = phy1)。Pi 3 / CM4 的順序沒有證據。要改從 `ubus call network.wireless status` 的 radio0 → interfaces[].ifname 取得。
7. **備援的觸發條件**:只看 `bluetoothd` / `hci0_powered`。已知的「BLE 不可用但兩者都是 1」的情況(D3b:廣播 instance 狀態不一致；provd 沒 Ready)不會觸發；反過來，刻意關 BLE(rfkill、之後的 EMCON)5 分鐘後會打開 HTTP。另外,BLE 恢復時關閉 HTTP 會切斷正在進行的 session(例如正在下載診斷包)。要定義清楚：觸發的意圖、例外情況、關閉前是否等 session 結束。
8. **漏列的介面**:「上傳完成」(provd → helper,經 ctl;ctl 依 `readonly.go:3-8` 是唯讀的，不能改狀態)、「IP 是否為 AP client」查詢動詞、provd 要比對的 `Content-Length`(pending key 3 不在 poll 的 `http` 欄位裡)、HTTP 的 `max_msg` 與 `/msg` body ≤ 9 KiB 的關係。這四項要補進 §5.3。
9. **`X-Batman-Session` 是明文的 bearer**:PUT 的 body 和空 body 的「取下一塊」都沒有經過 Noise 認證。看得到這個 header 的人(同一個 WPA2-PSK 上知道 AP 密碼的人;備援模式下 mesh 上的人)可以搶走分塊或塞垃圾 payload,完整性只靠簽章。要寫成誠實界線，或者讓 PUT 帶 session key 導出的 MAC。
10. **joinwatch 的 `verdict()` 改成 `code|句子`**:它也被 `diagline`(`joinwatch:89`,`|` 是欄位分隔)、STATE 檔(`:154`)、NOREBOOT(`:161`)、`status`(`:191`)使用;join.log 在 p6 上，降級後舊版也會讀。要列出所有消費者，或者另開一個 `verdict_code()`,不要改原本的輸出。
11. **`otaBusy()` 只看 `batman-slot.busy`**(`wtxn.go:448-451`):worker 在呼叫 `batman-slot write` 之前的 tar 解析階段不算 busy。要寫明 helper 在記憶體裡另有一個旗標。
12. **文件不一致**:D15 不存在(§3.8.1 引用了它);CDDL `update-manifest` key 5 的註解(「signature over metadata + SHA256SUMS」)和 `bulk-open-resp` key 2 的「one-time」都要改，但 §10 沒列;`update-phase` 2 在 CDDL 是 verifying,本文是「寫入中」;§9.3 的 ⚠️ 現在就能關掉:`platform-ab.sh:207,328,370` 本來就以名字取成員。降級那一列沒提到 p5 `overrides.uci` 多出的 ssid / radio0.country(舊版的 96 會照樣套用，無害，但要寫出來)。
13. **撤銷界線**:經 key 6 降級到舊版本後，舊 image 的 `release-min-serial` 比較低，已撤銷的 K 又會被接受。`min_from` 遇到不同 channel 時怎麼比沒有定義。兩者都要寫成規則或界線。
14. **CM4**:量產是 CM4(使用者 2026-10-23 的決定)。如果用 eMMC 版，就沒有轉賣 / 遺失手機的重燒路徑，單一擁有者遺失手機 = 節點不能再用。這不只是 checklist 項目，要請使用者決定量產用 Lite 還是 eMMC,並寫進 §3.9。
15. **被入侵的 provd 可以長期佔用 RAM**:bulk tmpfs 是 provd 啟動時就掛上的，不是只在上傳窗內。在 3A+ 上等於隨時可以佔 136 MiB。要寫成界線，或者在 §7 說明為什麼可以接受。

---

## 對 §12 的查證(節錄)

- ✅ A-B1 / B-B1:BLE 和 HTTP 的槽、額度分開，撤廣播只看 BLE。方向正確，但 HTTP 自己仍然被共用(→ M5)。
- ✅ A-B2 / B-M2:Go 白名單、`SHA256SUMS` 移到第一個成員、只複製列名的檔。方向正確，細節見 m1、m2。
- ✅ A-M1 / B-M7:status 改成背景快取。
- ❌ A-M2 / B-M6:國家只寫了三行(→ M4)。
- ⚠️ A-M4 / B-M5:暫時 AP 拿掉是對的，但「私有 savedir」的前提不成立(→ M3),key 20 又開了新的寫者(→ M1)。
- ✅ B-M1 錯誤碼、B-M8 `n.mu`、A-M6 key 7 / 8(key 8 的分割錯了，見 m3)、A-M7 狀態機(update-last 的判讀見 m4)。

## 判定

**REJECT(範圍窄)**。M1 到 M4 都是「設計在現成的唯一入口(halow-setkey / config-save)旁邊另開一條路」造成的，收回到 halow-setkey 就能同時解決大部分。M5 只需要在 accept 時加來源檢查，並把槽 / 額度分開。改完後請兩位審查者再審一次整份文件。
