# Review I — `329-n1-plan.md` v5(整份審查,不只 v4→v5 差異)

審查者:I(獨立、對抗式)。日期:2026-11-18。對象:`docs/design/329-n1-plan.md` v5(156 行)。
先讀過 `review-n1-plan-v4-E.md`、`-v4-F.md`,逐項對回 v5 本文(不是只看 §7)。

## 結論

**APPROVE-WITH-CHANGES** — 0 BLOCKER / 0 MAJOR / 10 MINOR。

- 產品改動(§3):找不到會造成錯誤行為的地方。有 session 的連線不會被切、攻擊者不能利用 grace 踢掉別人、log 量在既有契約內、數字(30 / 5 / 15 / 約 50 s)與原始碼一致。
- v4 的 4 個 MAJOR(E-M1/F-M1、E-M2、F-M2、F-M3)在 v5 本文都真的處理了(見下表)。
- 剩下的都在 harness 段的文字精確度:幾條規則寫得不夠明確,照字面實作可能多印一行 FAIL 或漏掉一個使用者。都是失敗方向安全(不會假 PASS、不會把 rc 的退化蓋成 KNOWN),所以列 MINOR。建議在動手寫 harness 前把 m1–m5 補進計畫,不需要再開一輪整份審查。

## 我做了什麼

- ✅ 讀完 v5 全文;逐條對 `bluez.go`(783 行)、`server.go`、`main.go`、`ci.yml`、`prov-p2-central-254.sh`、`prov-provd-254.sh`、`prov-p3-verbs-254.sh`、`known-failures.sh`、`validation-known-failures.txt`、`daily-validation.sh`、`254-p2-impl.md` §4.4、app 的三個檔案。
- ⚠️ 所有時間分析都是讀腳本推算,不是量測。F7(一次觀察)與 F8(kernel / BlueZ 原始碼行)我沒有辦法自己驗。
- ❌ 沒跑 `go test`、沒碰任何節點 / 手機 / ssh / adb(依指示唯讀)。F 說「copy 裡 `go vet` 乾淨、`go test -race` PASS」我沒有重跑。

## 引用行號核對

| 計畫引用 | 結果 |
|---|---|
| F2 `bluez.go:733`、`:772-776` | ✅ `nlinks = len(links)+len(devConn)`;case 在 772-776 |
| F3 `:688-729`、`:691`、`:491` | ✅(`:491` 只在 owner name 變了才 reset) |
| F4 `:412`、`:416-418`、`:322-334` | ✅ `Close` 394-420;Disconnect 只在 `conn != nil` 時呼叫、結果忽略 |
| F5 `:583-600`、`:518-567` | ✅ 3 輪 × 5 s;`:538-540` 跳過在 `links` 裡的裝置;`:565` log 不限流 |
| F6 `:656-681` | ✅ `:679` 5 s `time.After` |
| F10 central `:112-124`、`:133-137`、`:155-167` | ✅ `read_one` sleep 合計 23 s → 連線 23–26 s |
| F11 `server.go:835-845`、`main.go:88-100` | ✅ |
| F12 `bluez.go:733`、`:772-775` | ⚠️ 應為 `:772-776`(與 F2 不一致,見 m10) |
| `logLimit` `:617-625` 單一 slot | ✅ |
| `rpa_timeout` 930–1020 s | ✅ `rpaBase = 900`(`:37`)+ `jitter(30,120)` |
| `ci.yml:141` | ✅ `go vet ./... && go test ./...` |
| `prov-provd-254.sh:80` lease、`:99-106`、`:125-137`、`:192-200` | ✅ lease 1500 |
| `daily-validation.sh:310` | ✅ |
| `prov-p3-verbs-254.sh:50-55` | ✅(但先例還多查一個 feature marker,見 m7) |
| `254-p2-impl.md` §4.4 `:227` | ✅ |
| `p3-units.tsv:11`、`blebridge.py:16-17` | ✅ 純註解引用 |
| F9 `prober.dart:123`、`update_route.dart:28`、`settings_page.dart:2` | ⚠️ 內容對,但檔案在 `app/lib/src/nodelink/`、`app/lib/ui/`,計畫沒寫目錄(m10) |

## 從實際使用走一遍(產品段)

| 情境 | 結果 |
|---|---|
| 手機連上、走 claim / probe(數秒內寫 RX) | `links` 有項目 → 任何年齡都算;`staleLinks` 本來就跳過(`:538-540`);`Sessions()>0` 擋 register。不受影響 ✅ |
| 手機連上後走遠 / 關藍牙,節點沒收到斷線(F1) | 30 s 後 stale → `n==0` → `!advOn` → `register()` → `staleLinks()` 切掉 → 廣播回來。上限 30+5+15 ✅ |
| 兩支手機:A 有 session,B 閒置 | B 被記一行 log、不切;A 結束後才切。廣播本來就因 A 收著。A 不會被切 ✅ |
| 攻擊者每 30 s 重連 | 節點持續不可見(計畫 §2 已明說,今天是連一次就永遠)。每輪約 4 行 log、週期 ≥ 35 s,在「每 60 s 最多 10 行」內 ✅ |
| 攻擊者想踢掉合法 session | 做不到:有 `links` 的裝置不會 stale;`staleLinks` 只在 `Sessions()==0` 且 `n==0` 時跑 ✅ |
| 本機非特權 D-Bus 行程偽造 `Connected` | `:691` sender 檢查沒變 ✅ |
| stale 切完後 `register()` 的 recount | 這時 run loop 卡在 `register()` 裡,`Connected=false` 還沒處理,entry 還在但是 stale,不算進 `n` → 照常註冊;reason 是先前 tick 設的 `disconnect`,和新 arm 的斷言一致 ✅ |
| bluetoothd 重啟 | owner 變 → reset → 重新註冊,同今天 ✅ |
| provd 重啟 / crash loop | 無磁碟狀態;啟動時 `staleLinks`,同今天 ✅ |
| 節點重開 / 斷電、OTA 升降級 | 無儲存狀態;舊版 = 今天的行為 ✅ |
| BLE 配對類 suite(ble-rpa / pair-sc-only / sec-bond) | 這些在 BLE lease 下先停 provd(`ble-lib-254.sh:293`),不會遇到 N1 ✅ |

擁有權:`devConn` 四個寫入點都在 `b.mu` 下、各自寫的欄位有列(§4)。沒有第二個擁有者。

## 發現

### MINOR

**m1. 新 arm 在 rc 上:連線自己提早斷掉時會印一般 FAIL,而不是 INVALID。**
情境:02 `hold` 住 04,20 s 時連線因無線因素自己斷了。04 記 `adv registered reason=disconnect`,沒有 `link without session` 行。照 §5.2(L110)「on any other image it prints a different plain FAIL」→ rc 上產品沒錯卻 FAIL。L106 的 INVALID 規則只涵蓋「t0 和 t1 之間有 `adv registered`」,沒有 t1 時用不上。
最小修法:沒有 t1 行、且 04 在最後一條 withdraw 之後不到 29 s 就記了 `adv registered` → INVALID(原因:連線自己斷了)。L80 control arm 已經是這個做法。

**m2. 舊 image 路徑:「the timing checks are skipped」沒說清楚哪幾項算 timing check。**
情境:wsl.26 上連線不會被切,`watch 70` 會印 STILL、沒有 `adv registered` 行、最後的 `c02 read` 要等 drop 之後才會成功。L108 的三項(`adv registered` 20 s 內、GONE)如果有任何一項照跑,就會多印一行 FAIL;`known-failures.sh` 要求**每一行** FAIL 都對上才算 KNOWN,結果變 NEW。方向安全(不會遮蓋),但 §5.4 寫的「FAILs with the fixed line」就不成立。
最小修法:明寫「沒有 t1 行時,L107–L108 全部跳過;只跑 drop、單一 instance 檢查、最後的 `c02 read`」,並把 known-failures 條目的 ERE 寫出來且兩端錨定,例如 `^FAIL prov-boot-provd-254: no 'link without session' line in 70 s \(pre-N1 image\)$`。

**m3. L80 kill arm 的 INVALID 規則「provd 的 pid 沒變」沒有鑑別力。**
`kill -9` 之後 pid 一定會變,這條永遠不觸發。真正要排除的是:N1 在 kill **之前**就把連線切了(`hold` 的連線年齡加上前置步驟超過 30 s),那時 stale-link 行來自舊行程。
最小修法:kill arm 也套 L114 的共用 guard(arm 期間出現 `link without session` 行 → INVALID),拿掉 pid 規則或改成「stale-link 行的時間在 kill 之後」。

**m4. 共用 guard 的涵蓋清單和 F10 不一致,也沒說函式放哪。**
F10 列的使用者有 wbox 和 rpa;L114 的清單只有「the arms of this file」、netjoin、chain1。`prov-provd-wbox-254.sh:112`、`:119`、`:229` 也呼叫 `c02 read`。另外 `chain1-254.sh` 不 source `prov-254.sh`(source 的是 `bench-254.sh` / `fresh-254.sh`),它的 reader 是在 02 上迴圈 `read -`、最長 3600 s,「arm 期間」的範圍和其他 arm 不同。
最小修法:清單補 wbox;寫明函式放在哪個檔、chain1 怎麼用(或寫明 chain1 不套用以及原因:`read` 的連線 23–26 s,本來就在 grace 內)。

**m5. 連線年齡量測只列了 L80 和 `read`,沒列 boot-provd `:99-106` 和 sec-dbus `:192-200`;也沒說怎麼量。**
`hold` 回來時連線已有 0–16 s,加上後面的 sleep 和幾次 ssh,`:99-106` 在 drop 時我估約 23–25 s、sec-dbus(`watch 15`)可以到 31 s 上下(⚠️ 讀腳本估的)。sec-dbus 的 `watch 15` 和 L80 control 是同一個問題,但 L115 只改 L80。guard 會讓它變 INVALID 而不是錯判,所以不是錯誤行為,只是常跑會有 INVALID 噪音。
最小修法:5 次量測涵蓋四個 hold arm;寫明量法(04 的 log:該連線的 `adv withdrawn reason=connect` 到 `adv registered` 的差);sec-dbus 的 watch 值用同一條規則決定。

**m6. `Close` 裡的 `logged = false` 沒有負向對照。**
T4 沒有先把 `logged` 設成 true,所以把這個重設拿掉,T1–T10 全部照過。影響:session 結束後 Disconnect 失敗的裝置第二次 stale 時不記 log(只少一行 log,不影響切斷)。
最小修法:T4 加一個斷言(先讓 entry stale 且 `countLocked` 回 1 → 建 link → `Close` → 31 s 後 `countLocked` 再回 1)。同樣地,T5 在 `Connected=false` 之後要明寫「entry 不存在」的中間斷言(F-m7 提過,v5 沒寫出來)。

**m7. `pre-n1-versions.txt` 的內容規則沒寫完整。**
L119 只說放 04 當時的版本(預期 wsl.26)。在 product PR 合併、pin 移動之前,04 可能被重燒成目前 main 的 pin(記憶裡 02 已是 wsl.29);那個版本不在清單裡就會印一般 FAIL → NEW。方向安全,但會吵。先例 `prov-p3-verbs-254.sh:50-56` 還多查一個 feature marker,並在清單和 marker 矛盾時 FAIL。
最小修法:清單放「這段期間 04 可能跑的每個 pre-N1 版本」(至少 04 現在的版本和 main 的 pin);寫一句為什麼這裡只看版本字串就夠(rc 的 hash 一定不同,不會落在清單裡)。

**m8. 生命週期表少一列:「stale 裝置存在但 health 不 OK」。**
`converge` 的第一個 case(`!ok`)先成立時不會走到 `register()`:log 行會記、但不會切,等 health 回來才切。廣播那時本來就收著,行為正確,只是表裡沒有。
最小修法:加一列,測試欄寫「未測(行為同今天:health 不 OK 時不廣播)」。

**m9. 新 arm 在 boot-provd 裡的位置和時間戳取法沒寫。**
它必須排在 `:99-106` 那個 arm 重新註冊之後、`j stop` / `j flip` 之前,不然量到的是別的狀態。時間戳若用 `logread` 的 `$4`,跨午夜要處理(rpa unit 已有 +86400 的做法)。
最小修法:各一句話。

**m10. 文字 / 路徑。**
- F12 `:772-775` → `:772-776`(和 F2 一致)。
- F9 的 `prober.dart`、`update_route.dart`、`settings_page.dart` 補上目錄(`app/lib/src/nodelink/`、`app/lib/ui/`)。
- §5.5 的 S20 步驟:寫明有鑑別力的是「沒有 `link without session` 行」這個斷言;「頁面保持連線」本身沒有鑑別力(`Sessions()>0` 本來就擋住 register,就算 entry 被錯判 stale 也不會切)。

## v4 發現 → v5 是否解決

| v4 發現 | 解決? | 位置 / 說明 |
|---|---|---|
| E-M1 / F-M1 t0 定義(`hold` 會產生 2 條以上 withdraw) | 是 | §5.2 L105–106:t0 = t1 之前最後一條 withdraw;t1 必須恰好一條;中間有 `adv registered` → INVALID。F10 也改寫了 |
| E-M2 known-failures 會把 rc 的退化蓋掉;條目由誰移除 | 是 | L110:固定行只在 `pre-n1-versions.txt` 裡的版本印;L119 / §6:harness PR 移除。固定行不含 NEVER_KNOWN 的字 ✅。殘餘:m2、m7 |
| F-M2 / E-m3 `logged` 一次無法測、第四個寫入者 | 是 | §3.2 `countLocked`;§4 擁有權列了四個寫入點;T2 測回傳 1 再 0。殘餘:m6 |
| F-M3 沒有「有 session 的連線不被切」的真機檢查 | 是 | §5.5 S20 更新頁開 ≥ 90 s。殘餘:m10 第三點 |
| E-m4 `register()` recount 沒測 | 是(如實標 ❌) | §3.3、§5.1 最後一點 |
| E-m1 / F-m1 下限 29、wall clock | 是 | L107 |
| E-m2 / F-m3 執行時間、lease | 是 | L103:量測後寫進 PR,不足 300 s 就加 lease |
| E-m5 / F-m5 FAIL 要在 OTA 前跑、版本不寫死 | 是 | L119「read from the node」 |
| E-m6 `read` 使用者也要 guard | 部分 | L114 有,但漏 wbox、chain1 的套用方式沒寫(m4) |
| E-m7 Disconnect 清不掉的生命週期列 | 是 | 表 L72,兩個分支都寫了 |
| E-m8 `blebridge.py` 行號引用 | 是 | L118 |
| E-m9 文字(路徑、契約用語、單一 instance 檢查的時點) | 部分 | 契約用語、instance 檢查時點(L108)有;F9 的路徑仍缺目錄(m10) |
| F-m2 L80 watch 餘裕 | 是 | L115:8 或 5,取量測最壞年齡 ≤ 25 s 的較大者。sec-dbus 的 `watch 15` 沒跟著處理(m5) |
| F-m4 `watch` 自己會 drop;舊 image 仍查 instance | 是 | L110 末句、L111 |
| F-m6 「已存在的 entry 不動」沒有對照 | 是 | T10 |
| F-m7 過時的「§5.5」指標、T4/T5 時間移動方法、T5 中間斷言 | 部分 | 指標改成 §5 "Not tested" ✅;時間方法 L96 ✅;T5 中間斷言沒明寫(m6) |

## #290 規則

- harness 改動在獨立 PR、先進 main ✅(§5.2–5.4、§6)。
- 新檢查在舊 image FAIL、在 rc PASS,兩份輸出進 harness PR ✅。
- product PR 不碰 harness;行號引用留給後面的 harness PR ✅(L118)。
- known-failures 不會遮蓋 rc 的退化 ✅(版本清單;rc 的版本字串不在清單裡)。

## 安全

沒有新的輸入、權限不變、失敗方向是「仍算在內」或「重試」,不會切掉 session。負向測試(非擁有者 central 被切)就是新 arm 本身。沒有發現。

## 沒有審的

- 已核准的 provd 基準行為(`staleLinks` 本身、session idle 上限)依指示不重審。
- F1 的根因(❓ 未知)計畫已明說不在範圍內;手動現場檢查不擋 PR,這個取捨我同意。
