# 審查 B:`254-h1-harness.md` v1(PR-H1 harness)

審查者 B,獨立進行,沒有和 A 協調。範圍是整份設計,不是只看差異。
基準:`/home/yello/Batman-h1` @ dfdd11e;firmware 樹 `/home/yello/firmware-2710` @ 0439b5bb;02 = 10.41.1.1、04 = 10.41.1.3(只做唯讀查詢)。

**結論:REJECT(窄)— 0 BLOCKER / 5 MAJOR / 12 MINOR。**
方向與大部分事實都成立(E1、E3、E4、A3、A5、gen.py 決定性、verify 195 項都有驗過,見 §0)。問題集中在三處:
- 兩個空中測項的**判定契約**沒寫清楚;
- harness 中途死掉時 **BLE runtime 狀態的擁有權與還原**;
- 一個 preflight 檢查(P7)按設計寫法**抓不到它要抓的事**。

這些都是改設計文字就能修的,不必改方向。

---

## 0. 我驗證過的事實(✅ = 有原始輸出或原始碼)

| 設計聲稱 | 結果 | 證據 |
|---|---|---|
| E1 節點工具 | ✅;另外查到:**節點上沒有 `timeout`**,有 `setsid`、`sha256sum`、`scp`、`sftp-server` | 02、04 `command -v`:`timeout=`(空)、`setsid=/usr/bin/setsid` |
| E3 HDS | ✅ `/tmp/run` root 0755,`/tmp/run/batman-dv` root 0700(兩台都已存在) | `ls -ld` |
| E4 tmpfs 儲存區 | ✅ `/var/lib/bluetooth` 0700 root,`identity` 0600,`/tmp/lib` root 0755;`batman-sc` = 本次 boot_id + 現在的 bluetoothd pid + `mode=2 status=0`(兩台) | 讀檔 |
| E12 時鐘 | ✅ 04 = `Wed Jul 16 2025`,02 = `Sun Oct 18 2026`:**相差約 15 個月** | `date` |
| A3 adv instance 清除 | ✅ `src/advertising.c:1891-1893`(前提是 `max_ads != 0`,`:1888`);kernel `hci_core.c:2754` | 讀碼 |
| A5 `/tmp` 無 noexec | ✅ `tmpfs on /tmp type tmpfs (rw,nosuid,nodev,noatime)` | `mount` |
| 工具的動態函式庫 | ✅ build 樹的 `btmgmt` 需要 `libreadline.so.8`,`btmon` 需要 glib / gthread;兩台節點都有 | `readelf -d` + 節點 `ls` |
| E8 向量 | ✅ `verify.py` 印 `195 checks: ALL PASSED`;`gen.py` 輸出與 `vectors.json` `cmp` 相同,連跑兩次也相同(決定性) | WSL venv-219 |
| logread ring | ✅ 128 KiB;02 開機 4 h 24 m,ring 已經輪掉(第一行 01:53 > 開機 01:49,`Generated IRK` 計數 = 0);04 開機 2 h,計數 = 2(同一次啟動,bluetoothd 每行都以 `daemon.info` 和 `daemon.err` 各記一次) | `logread` |
| smp.c 的拒絕順序 | ✅ `smp.c:1756-1758`:not bondable 且帶 bonding → `SMP_PAIRING_NOTSUPP`;`:1760-1761`:SC-only 且無 SC → `SMP_AUTH_REQUIREMENTS` | 讀碼 |
| PR-F 的 04 btmon 有拒絕原因 | ✅ `air-sandwich-04-btmon-r1.txt:8-9`:`SMP: Pairing Failed` / `Reason: Authentication requirements (0x03)` | scratchpad |
| bluetoothctl 何時註冊 agent | ✅ `client/main.c:3186-3189` 預設 `auto_register_agent=""`;`:491-494` 只在**非** `NON_INTERACTIVE` 時註冊 | 讀碼 |

---

## MAJOR

### M1 `ble-rpa-254` 的判定沒有時間基準,取樣方式也沒定義:會假 FAIL,在特定情況下會假 PASS

**情境**
- 判定要把 04 的事件(T0、T0+300、T0+2100…)和 02 的掃描行(`<epoch> <addr>`)放到同一條時間軸上分段。設計寫「所有時間戳用 epoch 秒」,但沒說用誰的時鐘。實測兩台差約 15 個月(04 在 2025-07,02 在 2026-10)。照字面實作,02 的每一行都會落在 04 的視窗外,於是「任一段沒看到位址 = FAIL」→ 每次都 FAIL。
- 如果之後改成用 offset 對齊,40 分鐘內節點時鐘跳動(`batman-faketime`、之後接上 NTP 或 GPS)會把段落邊界移位。(c) 段的新位址可能被算進 (a),造成假 FAIL;更糟的是,(a) 段中途真的輪替出的位址可能被算進 (c),結果「(a) 恰 1 個、(c) 與 (a) 不同」→ **假 PASS**。被漏掉的正好是 F28 的負對照。
- **取樣**:02 用 bluetoothctl `scan on`,只有出現新裝置或 RSSI 改變時才印行。位址沒變的 30 分鐘裡,可能很少甚至完全沒有行。「每段都要看到位址」需要在段內**主動取樣**(例如每 60 s `scan off` / `scan on`,或固定查詢一次),否則 (a) 和 (b) 會假 FAIL。⚠️ PR-F 留下的證據只有結論表(`pr-f-body.md:34-41`),原始掃描 log 已不在 02 上,看不出 PR-F 是怎麼取樣的。
- **環境雜訊**:測試廣播是 connectable(`-c`)。30 分鐘內只要有任何 central 連上 04(路人手機、殘留的 02 session),斷線後 kernel 重開廣播,而 RPA 在 900 s 後已標記為 expired(`hci_sync.c:1085`),就會換成新位址 → (a) 假 FAIL,而且無法歸因。
- 同一個 local name 的其他廣播者,或 02 上 cache 裡帶同名的舊位址(bluetoothctl 啟動時會把已知裝置當 `[NEW]` 列出),也會讓「恰好 1 個位址」失準。

**修法**
- **時間軸只有一條,由測試主機擁有**:主機依自己的時鐘下 04 的每個事件,02 的取樣也由主機在每段**內部**下指令(段落邊界兩側各留 ≥ 30 s 保護帶)。節點時間戳只當參考。如果一定要用節點時間,就用 `/proc/uptime`(單調),並在開始和結束各量一次主機與節點的差。
- 每段內固定週期取樣,並寫明「該段沒有取樣結果 = FAIL」。
- RPA 測項改用 non-connectable 廣播(去掉 `-c`;privacy 下仍然是 RPA,判定靠 `ah()`)。04 的 btmon 若看到這段期間有連線,該段標「無效」。
- local name 帶每輪的隨機後綴;02 掃描前先做 `reset`(清 cache)。
- 負對照之外,再加一個**白箱**案例:在 (a) 中途故意重新註冊一次 → 判定必須 FAIL。這證明 (a) 的鑑別力不靠運氣。

### M2 `ble-pair-sc-only-254` 的「擋下」判定用的是代理訊號,而真正能分辨的證據就在手邊

**情境**
- 02 端所有 SMP 失敗都回 `0x05`(設計 A4 自己也這麼寫)。04 拒絕的原因可能是:
  - SC-only:`SMP_AUTH_REQUIREMENTS`,`smp.c:1760`;
  - 02 帶了 bonding 旗標:`SMP_PAIRING_NOTSUPP`,`smp.c:1757`,這個檢查還**排在 SC 檢查前面**;
  - 其他原因,例如 SC JW 段的 `Numeric comparison failed`(PR-F btmon 第 138 行)。
- 設計的判定是「`0x05` 且 04 btmon 有 LE Connection Complete」,分辨不出「被 SC-only 擋下」和「因為別的原因失敗」。
- 夾心結構只在翻轉段證明一次「這套設定能配對」。目標段和 restart 段各自都可能因為別的原因失敗,卻被算成擋下。例如 02 那一輪的 `mgmt.bondable off` 沒生效、session 斷掉後重連、agent 重新註冊讓 bondable 變回 1;設計只在 pair 前一行斷言 bondable,pair 那一刻的狀態沒有斷言。
- 「btmon 有對到該連線的 LE connection complete」怎麼對沒有定義。02 自己開了 privacy,對 04 送的 initiator 位址是會輪替的 RPA,用位址對不上;用時間對又回到 M1 的兩個時鐘問題。

**證據**:PR-F 的 `air-sandwich-04-btmon-r1.txt:8-9` 已經有 `Reason: Authentication requirements (0x03)`。這個值不是秘密,而設計 §4.7 只打算抓回事件名稱行,等於把它丟掉。

**修法**
- 「擋下」=
  1. 02 回 `0x05`;
  2. **本輪專屬的** 04 btmon(每輪重開 btmon,不靠時間對)恰好有一個 LE Connection Complete(status success);
  3. 04 **送出** `SMP: Pairing Failed`,`Reason: Authentication requirements (0x03)`。
- 原因是 `0x05 Pairing Not Supported` 或其他值 = 「無效」,並在報告寫出原因。過濾規則改成抓回「事件名稱 + Reason 行」,只排除 `Identity Information`、`Encryption Information`、`Signing Information`、`Public Key` 等帶值的行之後的內容。
- 負對照補一個:02 刻意 `mgmt.bondable on` → 04 回 0x05 NOTSUPP → 判定必須是「無效」,不能是「擋下」。

### M3 harness 中途死掉時,BLE runtime 狀態沒有擁有者、也沒有還原者(§3、§5 漏列資源)

設計只替**翻轉段**的 04 SC 設定配了 deadman。漏掉的資源與路徑:

1. **04 的 adv instance 1,在翻轉段以外**。`ble-rpa-254` 有 40 分鐘,配對輪也會開廣播。如果主機在這時死掉(Windows 睡眠、更新、ssh 斷、操作者 TaskStop),04 會一直廣播一個**固定 RPA + 固定 name + 181c、connectable** 的 instance,直到下次 bluetoothd restart 或重開。04 是 OTS 節點,會帶到現場:這等於留下一個可長期追蹤的 beacon,剛好違反這組測項要驗的性質。§5 那一列「adv instance 由 bluetoothd 啟動時清掉」只在 restart 真的發生時才成立,而 restart 只由翻轉段的 deadman 觸發。
2. **02 的孤兒程序與設定**:FIFO bluetoothctl session、`sleep 100000` keeper、FIFO 檔、40 分鐘的掃描 session。互動 session 會註冊 agent(`client/main.c:491-494`),02 會停在 agent / bondable / `sc off` / 持續 active scan。§5 說「02 是 central,不對外」:
   - 今天沒有 provd 廣播,勉強成立;H3 / PR-P2 之後 02 也會廣播,`sc off` 就變成真實的外洩面。
   - 持續的 BLE scan 會和 Pi 4 的 2.4 GHz Wi-Fi(radio0,手機 AP)共用天線,削弱 02 的 AP。
3. **跨次執行的殘留**。上一次執行死掉後,10 分鐘內 deadman 還沒觸發,新的一次執行就開始翻轉 → 舊 deadman 在新一輪中途 restart bluetoothd → 新一輪結果被污染。`deadman.pid` 也可能已經被重用:收尾 `kill $(cat deadman.pid)` 會殺到無關的 root 程序。既有慣例是先比對 `/proc/$p/cmdline` 再 kill(`daily-validation.sh:461`),設計沒有照做。
4. **兩個 harness 同時跑**:操作者在全套進行中另開一個 `DV_ONLY` 重跑。`daily-validation.sh` 沒有主機端鎖(`grep flock` 沒有結果),兩次執行會同時寫 04 的 instance 1 和 SC 設定 → 兩個寫入者。

**修法**
- §3 補上每一項,並寫出唯一擁有者:adv instance、btmon 程序與 snoop、02 的 session 程序、FIFO、keeper、02 的 agent / IO cap、deadman。
- **每一次**改 04 狀態(adv-on、flip、btmon-start)都先掛 deadman,期限 = 該段長度 + 餘裕,例如 rpa 段 45 min。deadman 用 `setsid` 開一個新的 process group,取消時 `kill -- -<pgid>`,並先比對 cmdline。
- 02 也要有 deadman:到期就 kill 那些 session 並 restart bluetoothd。
- 節點端用 `flock -n /tmp/run/batman-dv/bt/lock` 把整個 BLE 測項包起來;拿不到鎖 = FAIL,寫明「另一個執行在跑」。
- preflight P6 加一項「BLE 狀態乾淨」:04 `btmgmt advinfo` 沒有 instance、沒有殘留 deadman 或 btmon、02 沒有 bluetoothctl 或 keeper 程序。不乾淨 = FAIL,印出殘留清單。這也是第 3 點的修法。
- §5「harness 中途死掉」這一列要逐項寫出今天和之後的行為,並各附一個白箱測試,例如在 rpa 段中 kill harness,在期限後讀 04 的 `advinfo`。

### M4 P7「logread 灌爆」按設計寫法抓不到灌爆,判定延後到實作才定

**情境**:ring 是固定的 128 KiB,約 1100 行。實測 02 開機 4 h 後 ring 已經滿了:`wc -l` = 1081,第一行時間晚於開機時間。ring 滿了以後,不論灌得多兇,`wc -l` 都不會再增加。所以「10 s 內差 > 200 行」在真正灌爆時永遠是 0 → **假 PASS**。偏偏灌爆的節點一定是 ring 已滿的狀態。設計自己標了 ⚠️「以實測定」,但 fail-closed 閘門的判定不能留到實作時才決定:這樣審查審不到,負對照也沒有定義。另外,bluetoothd 每行都記兩次(`daemon.info` 加 `daemon.err`,04 實測),會讓既有的 log 量加倍,門檻要把這點算進去。

**修法**:在設計裡寫定算法。例如:取 `logread` 的最後 N 行,用每行的時間戳(秒)數出最近 10 s 的行數;節點時鐘不可信也沒關係,因為只比同一個節點自己的相對時間。也可以讓主機在 10 s 內抓兩次 `logread | tail -1`,比對內容和行數。寫出門檻與理由。負對照:stub 案例(兩次讀值「行數不變但時間戳顯示 10 s 內有 300 行」→ 必須 FAIL),加上實機一次 `logger` 迴圈灌入 → 必須 FAIL。

### M5 tier B 的 BLE 測項會重開 04,但沒有放在 DNODE 乙太網閘門內,也沒有定義執行順序和每個測項自己的前提

**情境**
- `ble-privacy-reboot-254` 和 `ble-pair-sc-only-254` 收尾都會**重開 BLE_PERIPH**。現有 tier B 的所有重開都放在 `FEATURE_MODE=--destructive` **且 DNODE 有 eth carrier** 的閘門內(`daily-validation.sh:2479-2480`),理由是「壞了要能從 eth 救回」。設計沒有要求 BLE_PERIPH == DNODE 或 BLE_PERIPH 有 eth,也沒說這些 suite 放在哪個區塊。今天剛好 04 = DNODE = OTS = 主機進 mesh 的唯一橋(04 `eth0 carrier=1`,02 `carrier=0`),換一組設定就會變成重開一台沒有頻外救援的節點。
- 和其他 suite 的**順序**沒寫:
  - #274 那一組在 tier B 之後要等 OTS 節點(`:2504-2541`),兩次額外的 04 重開會插在哪裡?
  - `ab-selftest --destructive` 和 fault-injection 會換槽、重刷。PR-F 那次全套後,04 就因為 fault-injection 換過槽。parent §11 Q8 寫明 **02 的 p3 distroconfig 還沒加 `core_freq_min=500`**,而 scratchpad 有 `02-hci0-timeout-boot1.txt` 這份 hci0 逾時的證據。所以前面的 suite 把節點留在另一個槽之後,BLE 測項可能遇到 hci0 不穩,產生無法歸因的 FAIL。preflight 只在開跑時檢查一次,碰不到這種中途變化。
- 兩次 04 重開(§4.4 的 reboot 和 §4.6 的收尾)可以合併,省掉一次 OTS 中斷。

**修法**
- BLE tier B 放在 DNODE 乙太網閘門內,並要求 `BLE_PERIPH == DNODE`(或 BLE_PERIPH 自己有 eth carrier),不符就 FAIL 並寫明原因。
- 寫定順序:BLE 測項排在任何換槽或重刷的 suite **之前**;順序是 rpa → pair → reboot,`ble-privacy-reboot-254` 的重開同時當配對收尾的 IRK 作廢。或者明寫在哪些 suite 之後,並說明理由。
- 每個 BLE suite 開頭重新斷言 P6 的節點前提:版本、slot、`hci0`、`batman-sc`、乾淨狀態。不符 = FAIL,原因寫「前提被前面的 suite 改變(<實際值>)」。
- §8 的副作用清單補上「OTS 中斷次數」與「BLE_PERIPH 必須有 eth」。

---

## MINOR

**m1 preflight 的位置自相矛盾**。設計寫「在任何 suite 之前(`fleet_init` 之後)」,但 `fleet_init` 在 `:159`,前面已經跑過 `ab-card-invariants`、`harness-265`、`tmp-trust-static`、`onboarding-ip`。要嘛把 preflight 和 `fleet_init` 一起提到最前面,要嘛明寫那幾個主機端 suite 例外。另外 `fleet_init` 要加入 `BLE_PERIPH` / `BLE_CENTRAL`,否則角色不重疊的設定下,fleet settle 不會等它們。

**m2 P5 和 fault-injection 的 precheck 是兩個判定,而且說「秒級」不實**。`fault-injection.sh:125-150` 已經有同一個判定(payload 的 `root.squashfs` sha 對 `/rom` 來源的 `head -c size | sha256sum`,`QT=600`),要解壓並雜湊數百 MB,不是秒級。preflight 應該用 `FI_SOURCE_ONLY=1` 呼叫同一個 `precheck`,只留一份判定;「幾秒內」的說法也要改。

**m3 `--require-hashes` 要涵蓋整個相依閉包**。`requirements.txt` 只釘了 7 個套件,venv 裡實際有 14 個(另外有 `asn1crypto`、`attrs`、`certvalidator`、`cffi`、`oscrypto`、`pycparser`、`six`),全部都要釘版本並附 hash,否則 pip 直接拒絕安裝。CI 的 `actions/setup-python` 也要釘 commit SHA,和供應鏈的說法一致。現有 `ci.yml` 用 tag 或 `curl | sh`,這不是本 PR 造成的,記一行就好。

**m4 路徑分類與 tmp-trust**。#290 規則 1 的文字把 `scripts/node/` 列為**產品路徑**,但 tmp-trust 把它當節點端程式,而 harness 的 node client 也一直放在那裡。設計說「不碰產品路徑」,卻在 `scripts/node/` 新增檔案,要對齊:改 #290 的文字,或在設計裡寫出分類。新的節點腳本會出現 `/var/lib/bluetooth` 和 `/tmp/lib/bluetooth`,`check-tmp-trust.sh` 的 `PAT` 對 `/var/<x>` 一律算命中,所以要新增 allowlist 條目並附理由:`/tmp/lib` 是開機時建的 root 0755(實測),`bluetooth` 是 0700。`ble-privacy-254` 斷言 3 也要檢查 `/tmp/lib` 是 root 而且不是全域可寫。

**m5 負對照和 parent §9 比少了什麼**。#290 規則 2 要求「在上一個出貨版本上 FAIL」。設計改用白箱翻轉,理由是不能切槽。這要使用者拍板,或附上「1.5.11 上 `ble-privacy-254` FAIL(沒有 hci0)」這種低成本但鑑別力弱的結果,並寫明它的限度。parent §9 的 wsl.4 / wsl.5 負對照,和「只在 fresh overlay 上判定」的前提被拿掉了,也要寫明理由。

**m6 IRK 衛生的缺口**
- 節點端也不能讓 IRK 出現在 argv,例如 `awk -v`、`printf` 以外的外部指令。
- `ble-ah.py` 不論成功或解析錯誤,都**不得**回印 stdin。
- 讀不到 IRK(stdin 空的)= FAIL。
- 在 Git Bash 下,`DV_PY="wsl … python"` 要定義路徑轉換:腳本路徑必須是 WSL 路徑,不能是 `//wsl.localhost`;MSYS 的路徑轉換會把它弄壞。
- 翻轉段 02 開了 privacy,也會把**自己的** IRK 交給 04,而收尾只 restart 02 的 bluetoothd,沒有重開,所以 02 的 IRK 不會作廢。04 上的 snoop 在 harness 死掉時會留在 tmpfs,裡面同時有兩台的 IRK。要嘛收尾也重開 02,要嘛寫明這是接受的殘餘風險。

**m7 `reset` 的刪除範圍**。02 的 `/var/lib/bluetooth/<a>/` 裡有 `identity` 和 `settings`(實測),和裝置目錄在同一層。刪除規則要寫成白名單,只刪 `cache/*` 和 `^[0-9A-F:]{17}$` 這種名字的目錄,並加一個測試:刪完之後 `identity` 的雜湊不變。刪錯會讓 02 換 IRK,以後的判定都會受影響。

**m8 `peer.py`**
- `verify.py` 在模組最上層就跑完所有檢查,最後還 `sys.exit`(`:75`、`:650-651`)。要「用 verify.py 的判定組成參考回應者」就得先把 verify.py 重構成模組。這等於改了判定,需要自己的負對照,但設計沒提。
- 參考回應者和語料的檢查都用同一組判定,selftest (1) 和 (2) 是循環的;只有 (3) 有實質意義。
- 傳輸契約裡「一則訊息 = 一個 GATT write payload」和「分塊照 §5.1」是誰負責分塊,寫得不清楚。
- 本 PR 沒有任何使用者。建議延到 H3 再做;要保留的話,把以上三點寫清楚。

**m9 §4.4 缺的證據**。「bluetoothd restart 不換 IRK」沒有附證據,需要 `load_irk` 路徑的原始碼位置,或一次實測。`Generated IRK` 每次啟動會出現 2 行(info 和 err 各一),判定要寫「≥ 1」,不能寫「恰好 1」。這個 log 斷言和 IRK 雜湊不同、新 boot_id 是重複的,而且 ring 輪掉就會假 FAIL,建議降為 info。

**m10 deadman 的實作契約**。`setsid sh -c 'sleep 600; restart'` 如果只記到 `sleep` 的 pid,kill 掉 sleep 會讓 restart 立刻執行。要記 pgid,並 kill 整個 group。setsid 出去的程序要把 stdin、stdout、stderr 全部導走,否則 ssh 不會返回。

**m11 長時間的節點端動作**。40 分鐘的 02 掃描和 04 時間軸不能靠一條前景 ssh:02 經由 04 → mesh 連線,中途斷掉就整段作廢。要像 PR-F 一樣在節點上 detach 執行,主機輪詢結果檔,同時對到 M1 的「主機擁有時間軸」。節點上沒有 `timeout`(實測),腳本要自己控制時長。

**m12 tier A 依賴 `DV_BT_TOOLS`**
- 每天跑的 tier A `ble-privacy-254` 需要從 build 樹放上 `btmgmt`,但 preflight 只在 `FEATURE_MODE=--destructive` 時檢查 `DV_BT_TOOLS`。沒設的時候會怎樣(FAIL 還是 SKIP),設計沒定義。
- build 樹是會被清掉或換掉的路徑(`firmware-2710` → 下一棵樹),版本也會漂移。
- 建議 preflight 在**任何** fleet 中有 bcm2711 節點時都檢查,並把工具的 sha 寫進 `preflight.txt`。
- 也可以評估另一條路:`bluetoothctl mgmt.info` 用命令列參數執行時是 `NON_INTERACTIVE`,不會註冊 agent(`client/main.c:491-494`、`:3186`)。如果實測 `mgmt.info` 可以這樣跑,tier A 就不必把工具放上節點。⚠️ 我沒有在節點上執行它:這次的審查規則禁止跑 bluetoothctl。

---

## 生命週期矩陣漏掉的路徑

| 路徑 | 設計 | 缺什麼 |
|---|---|---|
| harness 在 rpa 段或配對輪(非翻轉段)死掉 | 沒列 | M3 第 1 點 |
| 上一次執行死掉後,10 分鐘內開新的一次 | 沒列 | M3 第 3 點 |
| 兩個執行同時跑 | 沒列 | M3 第 4 點 |
| 前面的 suite 換槽或重刷後才跑 BLE 測項 | 沒列 | M5 |
| 節點時鐘在測項中途跳動 | 沒列 | M1 |
| dbus 或 dropbear restart(依賴) | 沒列 | 至少寫 N/A 和理由;dropbear restart = ssh 斷 = 跟 harness 死掉同一條路 |
| 主機 Windows 睡眠 | 沒列 | 等同 harness 死掉,但時間可能很長,所以 deadman 要涵蓋所有狀態(M3) |

## 範圍(和 parent §9 / §10、#290 對照)
- H-U2 的 prov-\* 分批、`prov-tools-254`:和使用者決定一致 ✅。
- 拿掉的部分:P8(午夜)和 ssh 預算有寫理由,也回寫到 #290 ✅;舊版負對照與 fresh overlay 前提沒有寫理由(m5)。
- 超出範圍的部分:`peer.py` 本 PR 沒有使用者(m8)。`scripts/node/` 的分類有爭議(m4)。

## 結論
**REJECT(窄)**。5 個 MAJOR 都可以只改設計文字解決:
- M1:時間軸與取樣;
- M2:用拒絕原因判定;
- M3:BLE 狀態的擁有權、deadman 與鎖;
- M4:P7 的算法;
- M5:閘門與順序。

改完之後請送整份重審,並附上 M1、M2、M3 的白箱負對照。
