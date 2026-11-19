# Review J — `329-n1-plan.md` v5(整份審查,實跑程式)

審查者:J(獨立;沒看 I 的結果)。日期 2026-11-18。對象:`docs/design/329-n1-plan.md` v5 全文。

**Verdict: APPROVE-WITH-CHANGES** — BLOCKER 0、MAJOR 0、MINOR 10。

## 0. 我做了什麼(三類)

- ✅ 驗過(附原始輸出,§A):
  - 自己的副本 `%TEMP%\claude\n1-v5-J\src`(`feed/batman-prov/src` 的複本),照 v5 §3 逐字實作(`devEnt{since, logged}`、`linkGrace`、`liveLinks`、`countLocked(now)`、`resetDevs`、`Close` 只更新既有條目、`register()` 在 `staleLinks()` 後重算、已存在的條目不被第二個 `Connected=true` 覆寫)。
  - T1–T10 + 2 個額外測試;WSL Ubuntu-24.04、go1.26.4、`-mod=vendor`:`go vet` rc=0、`go test -race -count=1 -v ./cmd/batman-provd/` 全過。
  - 13 個突變,一次一個,跑完還原並 `cmp` 確認與未突變版相同。
  - 計畫引用的 `bluez.go` 行號(`:54 :294-313 :322-334 :394-420 :480-495 :518-567 :583-600 :602-615 :617-625 :656-681 :688-729 :731-783`)、central script(`:112-124 :126-144 :155-167 :168-175`)、`prov-provd-254.sh`(`:68-69 :79-115 :125-137 :192-200`)、`prov-p3-verbs-254.sh:45-56`、`daily-validation.sh:310`:與原始碼相符。
- ⚠️ 推論(紙上追蹤,沒上機):§2 的 harness 追蹤與所有時間數字。我沒有碰任何節點 / 手機 / ssh / adb。
- ❌ 沒做:任何真機量測;`server.go` / `session.go` / `update_route.dart` 的引用只沿用 E、F 已驗的結果,這輪沒重查。

## 1. 單元測試與突變(負對照)

| # | 突變 | 抓到的列 | 備註 |
|---|---|---|---|
| a | 拿掉年齡規則 | T2、T4、T7、T10 FAIL | ✅ |
| b | `Close` 不更新 `since` | T4 FAIL(`right after Close n=0 stale=[A]`) | ✅ |
| b2 | `Close` 更新 `since` 但不清 `logged` | **沒有任何列抓到** | 計畫沒標 ❌ → m3 |
| c | `Close` 無條件寫入 | T5 FAIL | ✅ |
| d | 拿掉 links ∪ devConn 聯集 | T3(n=2)、T6、T7 FAIL | ✅ |
| e | 第二個 `Connected=true` 覆寫 `since` | T10 FAIL(只有它) | ✅ |
| f | `countLocked` 不設 `logged` | T2 FAIL(`second n=0 marked=1`) | ✅ |
| g | 接受錯誤 sender 的 signal | **T1–T10 沒抓到**;只有我額外加的 `TestX_WrongSenderIgnored` 抓到 | 計畫沒這列也沒標 ❌ → m1 |
| h | 拿掉 `register()` 的重算 | **沒抓到** | 計畫 §3.3 / §5.1 已誠實標 ❌ |
| i | `resetDevs` 變空函式 | T8 FAIL | ✅ |
| i2 | `refreshOwner` 不呼叫 `resetDevs` | **T1–T10 沒抓到**;額外的 `TestX_RefreshOwnerResets` 抓到 | → m2 |
| j | `converge` 不用 `countLocked` 的 n | 單元測試沒抓到(預期;計畫說由真機 arm 管) | 真機 arm:沒有 `adv registered` → FAIL |
| k | `converge` 不印那一行 | 單元測試沒抓到(預期) | 真機 arm:非名單版本 → plain FAIL |
| l | grace 改 300 s | T2、T4、T7、T10 FAIL | ✅ |

結論:要求的 (a)–(h) 中,(g) 沒被 T1–T10 抓到且計畫沒標;(h) 沒抓到但計畫有標 ❌;其餘各有一列抓到。

## 2. 新 harness arm 的紙上追蹤(⚠️ 全部是推論)

依據:`prov-p2-central-254.sh` `hold`(`:155-167`)= `pick`(`scan_all` 12+1+1 s → `read_one`:connect、睡 8+2+1+2+1+8+1 = 23 s、`info_of`、`drop`)→ 再掃 10+1 s → `connect`、6 s、最多再等 10 s;`watch`(`:168-175`)每秒問一次。04 端 `withdraw` / `register` 用 `logf`(不經 `logLimit`,`bluez.go:599,614`),所以每次連線都有一行。

**rc 正常跑一次,04 在 mark 之後的 log(T = mark 後秒數):**

| T(約) | 04 log 行 | 來源 |
|---|---|---|
| 15 | `adv withdrawn reason=connect` | `pick` 的 `read_one` 連上 |
| 39–41 | `adv registered reason=disconnect` | `read_one` 的 `drop`(連線 23–26 s,低於 30) |
| 52–56 | `adv withdrawn reason=connect` ← **t0** | `hold` 自己的 connect |
| t0+30…35 | `link without session for 30 s` ← **t1** | `converge` 的 `countLocked`(5 s tick) |
| t1+0…15 | `disconnected 1 stale link(s)` → `adv registered reason=disconnect` | `register()` → `staleLinks()` → 重算 → 註冊 |

- `HELD` 約在 t0+6…16 回來,`watch 70` 約 t0+8…18 開始;t1 落在 watch 的第 12–27 s,GONE 在 70 s 內。✓
- t1−t0:`since` 在 `deviceChanged` 設定,t0 行在 `UnregisterAdvertisement` 回來後才印(晚 δ);logread 整秒 → 差值 29…36。計畫的 29…37 合理;下限靠 δ < 1 s(m6)。
- 那一行恰好一次:`converge` 的 `countLocked` 設了 `logged`,`register()` 的重算不再印。✓(突變 f 證明這靠 `logged`)
- 假 FAIL:紙上找不到。`hold` 內部重試(第一次 connect 晚到)→ t0 取「t1 之前最後一行 withdraw」仍正確。
- INVALID:只在某條無 session 的連線被 04 看到超過 30 s 而 02 沒發現時(兩行 stale 行)才會出現;是 INVALID 不是錯判。可接受。
- 假 PASS:PASS 需要那一行 + 29…37 + 20 s 內重新註冊 + GONE + 之後 `read` 成功;沒有產品改動時沒有那一行。找不到。

**舊 image(名單內版本):** withdraw / registered / withdraw 同上,之後沒有 stale 行;連線一直在;`watch 70` 印 `STILL` 並自己 drop;04 這才 `adv registered reason=disconnect`。arm 印固定那一行 FAIL。條件:這條路徑只能有**這一行** FAIL(`known-failures.sh` 要每一行 FAIL 都符合才算 KNOWN)→ m5。

**壞掉的 rc(版本不在名單):**

| rc 壞法 | arm 結果 | 誰是負對照 |
|---|---|---|
| a / l(沒有年齡規則、grace 太長)、k(不印) | 沒有 stale 行 → plain FAIL(非 KNOWN)✓ | arm + T2/T4/T7/T10 |
| j(印了但照舊算 n) | 有 t1,20 s 內沒有 `adv registered` → FAIL ✓ | arm |
| f(`logged` 不設) | 同一 tick 內 `converge` + `register()` 重算各印一次 → ≥2 行 → **INVALID**(不是 FAIL) | T2 是真正的對照;INVALID 不會變 PASS,可接受,但計畫該寫一句 |
| b、b2、c、e、g、h、i2 | arm 看不到(central 從不開 session、沒有第二個 signal)→ PASS | 只有單元測試;b2 / g / h / i2 沒有對照(見 §1) |
| d | arm PASS(沒有 `links`) | T3/T6/T7 |

**#290 與 known-failures:** harness PR 先進、舊 image FAIL / rc PASS 兩份輸出都進 PR、產品 PR 不碰 harness(只動 Go、單元測試、`254-p2-impl.md`)、條目由 harness PR 移除:符合規則。FAIL 文字不含 NEVER_KNOWN 的字。與現有 `pre-p3` 慣例的差別:現有做法是「版本在名單 **且** 沒有 feature marker」,v5 只看名單;因為 rc 一定是新版本字串,只看名單也不會把壞掉的 rc 變 KNOWN,可接受(m4 補一句維護規則)。

**L80 與共用 guard:**
- L80 control:`hold` 回來時連線 0–16 s + ssh + `watch 15` → STILL 時最老約 33 s,確實會撞 grace;改 8(最壞約 26 s)或 5(約 23 s)照量測選,可實作。
- L80 kill arm:新的 provd 沒有 `devConn` 條目 → 不會印 stale 行,`disconnected N stale link` 來自 `register()` → `staleLinks()`,不變;「pid 沒變 = INVALID」可實作。
- guard 對 `prov-provd-254.sh` 自己的 arm(已有 `hmark` / `plog`)可照寫。對 `prov-netjoin-254.sh:63` 可做,但函式得放在 `prov-254.sh`(netjoin 只 source 它,`:20`),計畫沒說放哪。對 `chain1-254.sh:168` **照寫做不出來** → m7。
- `read` 的值在 connect 後約 15 s 就讀完,連線在 23–26 s 自己斷;N1 不會改變任何 `read` 使用者的結果。guard 對 `read` 只是保險。

## 3. Findings

沒有 BLOCKER,沒有 MAJOR。產品設計(§3、§4)我用實作 + 突變 + 逐情境(手機連上走開、藍牙開關、provd 重啟 / crash loop、bluetoothd 重啟、OTA 升降版、兩支手機、grace 期間有 session 的手機)找不到錯誤行為:
- 有 `links` 條目的裝置在 `liveLinks` 與 `staleLinks`(`:538-540`)兩處都不會被切;
- 沒有新的輸入;`Connected` 仍只收 sender 檢查過的 signal(`:691`);本機非特權程序無法偽造;
- BLE 攻擊者要每 30 s 重連一次才能讓節點持續不廣播(計畫 §4 已寫),且佔的是單一連線位,與今天相比只變好;
- log:每個裝置每次連線最多一行(`logged`),重連一次一行,頻率受 BLE 連線時間限制,在既有契約內。

**m1(MINOR)sender 檢查沒有測試列。** 情境:有人把 `:691` 的 sender 檢查改壞,T1–T10 全綠(突變 g,§A)。計畫 §5.1 說測試「自己設 `Sender`,否則會空過」,但沒有一列驗證錯的 sender 被丟掉,也沒標 ❌。這是既有程式,但 §4 Security 的「local process cannot fake it」正靠它。最小修正:加一列(錯 sender 的 signal → 沒有條目;我的 `TestX_WrongSenderIgnored` 8 行),或在「Not covered」標 ❌。

**m2(MINOR)T8 測的是 `resetDevs` 本身,不是呼叫點。** 突變 i2(`refreshOwner` 不呼叫 `resetDevs`)T1–T10 全綠。`refreshOwner` 在 `conn == nil` 下可直接呼叫(owner `""` ≠ `bluezName` 就走重置分支),所以 T8 改成「設 `bluezName`、放一個條目、呼叫 `refreshOwner`、條目沒了」即可,不需要新機制。

**m3(MINOR)`Close` 清 `logged` 沒有對照。** 突變 b2 全綠。影響只是「session 結束後又閒置 30 s 的裝置第二次被切時不印那一行」(log 契約,不影響切不切)。最小修正:T4 最後加一個斷言(31 s 後 `countLocked` 回 marked=1),或標 ❌。

**m4(MINOR)`pre-n1-versions.txt` 的維護規則沒寫。** 現有慣例(`pre-p3-versions.txt` 檔頭)是「功能出貨前,每次 pin bump 加一行」。若 harness PR 合併後、N1 產品 PR 合併前有別的 PR 先 bump pin,04 會跑一個不在名單的版本 → plain FAIL、不是 KNOWN → 擋住全套。最小修正:§5.4 加一句同樣的規則(由 harness PR 加行)。

**m5(MINOR)舊 image 路徑要明寫「只印一行 FAIL」。** §5.2 說沒有 stale 行時「timing checks are skipped」,但「watch 印 GONE」與「`c02 read` 成功」算不算 timing check 沒寫清楚。舊 image 上 watch 會印 `STILL`;若實作把它也判 FAIL,就有第二行 FAIL,suite 不再是 KNOWN(`known-failures.sh`:每一行 FAIL 都要符合)。最小修正:寫明沒有 stale 行時只做 drop + one-instance(+ 可選的 `read`),GONE 不判。

**m6(MINOR)下限 29 靠 withdraw 的 D-Bus 往返 < 1 s。** t0 行在 `UnregisterAdvertisement` 回來後才印(`:613-614`);若那次呼叫 ≥ 1 s,差值可到 28 → 假 FAIL。計畫已要求 5 次量測值進 PR;補一句「5 次裡出現 29 就把下限的理由與 δ 一起寫進 PR,出現 28 就停下來回報」,不要事後默默調界線。

**m7(MINOR)`chain1-254.sh:168` 的 guard 照寫做不出來。** 該處是 02 上背景跑一小時的 reader 迴圈,期間 04 mkfs + 重開(log ring 清空),chain1 也不 source `prov-254.sh`;「arm 前後數 04 的 log 行」不成立。而且不需要:reader 的空樣本(`-`)本來就不判(`chain1-254.sh:346`),`read` 的值在 15 s 內讀完。最小修正:把 chain1 從 guard 名單拿掉並寫這個理由;另外 §5.3 的名單漏了 `prov-provd-wbox-254.sh:112,119,229`(F10 有列 wbox),補上或同樣寫明不需要;並寫明共用函式放在 `prov-254.sh`。

**m8(MINOR)新 arm 的判定沒有離線測試。** 判定有六個出口(PASS / <29 / >37 / 兩行 = INVALID / 中間有 `adv registered` = INVALID / 沒有行),真機只會走到兩個(舊 image 沒有行、rc PASS)。現有慣例是 judge 在 `scripts/test-dv-ble-254.sh` 有好 / 壞兩種離線案例(CI `ci.yml:32` 與 `harness-ble-254` suite,RPA judge 就是這樣)。最小修正:判定寫成吃 log 文字的函式,在 `test-dv-ble-254.sh` 餵 rc 真機擷取的行(格式照真機,不手寫)各走一次;跨午夜照 rpa arm 的做法(`prov-provd-254.sh:251`,`d < 0 → +86400`)。`plog` 只會數,讀時間要新的一行讀取(一次讀完,計畫已寫)。

**m9(MINOR)突變 f 型的 rc 在真機 arm 是 INVALID 不是 FAIL。** 見 §2 表。不會變 PASS,T2 是對照;計畫在「two or more = INVALID」旁補一句「rc 上重複出現 = 產品問題,不是重跑就好」即可,避免 INVALID 被當成環境問題重跑。

**m10(MINOR)文字。** (1) lifecycle 表仍寫「wsl.26 is the negative control」,§5.4 已改成「從節點讀」;統一。(2) T5 的中間斷言(`Connected=false` 後條目不在、`Close` 後仍不在)沒明寫,只有通則「each row first asserts the entry it expects exists」;T5 的價值正在中間那一步,寫出來。(3) 一句話交代:`Connected=false` 遺失時,已 `logged` 的條目會一直留著(不計數、不再印;同一路徑重連時因條目存在而不重設 `since`,那條連線不被計數:廣播不收回、也不會被切(`staleLinks` 只在 `register()` 內跑,而 `advOn` 仍為真),手機寫 RX 後照常有 session;下一個 `Connected=false` 清掉條目就恢復)— 無害,是 T10 規則的代價;⚠️ 讀程式推論,沒真機驗證;值得在 §4 lifecycle 寫一列。(4) L80 watch 值的規則沒寫「5 s 也超過 25 s 時怎麼辦」(紙上最壞 23 s,應該不會發生)。

## 4. v4 finding → resolved?

| v4 finding | v5 處理 | 結果 |
|---|---|---|
| E-M1 / F-M1(t0 定義錯:`hold` 先 read) | §5.2:t1 之前最後一行 withdraw、兩行 = INVALID、中間有 registered = INVALID;F10 改寫 | ✅ 解決(紙上追蹤 §2) |
| E-M2(known-failures 會蓋掉壞掉的 rc) | `pre-n1-versions.txt` + 其他版本印不同的 plain FAIL;條目由 harness PR 移除 | ✅ 解決(m4、m5 是補充) |
| F-M2(`logged` 一次性無法測) | `countLocked(now)` + T2 | ✅ 解決(突變 f:T2 FAIL) |
| F-M3(有 session 的連線沒有真機檢查;重算沒測) | §5.5 S20 更新頁 ≥ 90 s;重算標 ❌ | ✅ 解決(突變 h 確認沒對照,且有標) |
| E-m1 / F-m1(下限) | 29;時鐘跳動 = FAIL 並印兩行(E 要 INVALID,F 接受) | ✅(m6) |
| E-m2 / F-m3(執行時間用估的) | 量測值進 PR,必要時加 lease | ✅ |
| E-m3、E-m9(契約用字、路徑) | 已改 | ✅ |
| E-m4(重算沒測) | 標 ❌ | ✅ |
| E-m5 / F-m5(FAIL 要在 OTA 前跑) | §5.4、§6 | ✅(lifecycle 表殘留 wsl.26,m10) |
| E-m6(guard 也要管 `read`) | §5.3 共用函式 | ⚠️ 部分:chain1 做不出來、wbox 漏列(m7) |
| E-m7(Disconnect 沒清掉的列) | lifecycle 已加 | ✅ |
| E-m8(`blebridge.py` 行號) | 延到移除條目的 harness PR | ✅ |
| F-m2(L80 watch 值) | 由量測決定 8 或 5 | ✅ |
| F-m4(每個出口 drop + instance) | §5.2 最後一點 | ✅ |
| F-m6(T10) | 已加 | ✅(突變 e:只有 T10 抓到) |
| F-m7(指標 / 移時間的方法 / T5 中間斷言) | 前兩項已改;T5 中間斷言沒明寫 | ⚠️ 部分(m10-2) |

## 5. Verdict

**APPROVE-WITH-CHANGES。** 0 BLOCKER、0 MAJOR、10 MINOR。MINOR 都是一兩句或一列測試,不需要新機制,也不需要再審一輪設計;m1–m3 的測試列與 m5 / m7 的文字建議在實作前改掉。

---

## A. 原始輸出

環境:`wsl -d Ubuntu-24.04 -u yello`,`/home/yello/firmware-2710/staging_dir/hostpkg/bin/go1.26`,`GOFLAGS=-mod=vendor GOTOOLCHAIN=local`。`out-mut.txt` 的 (a) 第一次是我的突變寫法編不過(`declared and not used: e`),有效的 (a) 在 `out-mut2.txt` 開頭。

### out-baseline.txt

```
go version go1.22.2 linux/amd64
go version go1.26.4 linux/amd64
vet rc=0
=== RUN   TestT1_FreshDeviceCounted
--- PASS: TestT1_FreshDeviceCounted (0.00s)
=== RUN   TestT2_StaleAfterGraceLoggedOnce
--- PASS: TestT2_StaleAfterGraceLoggedOnce (0.00s)
=== RUN   TestT3_DeviceWithLinkCountedOnce
--- PASS: TestT3_DeviceWithLinkCountedOnce (0.00s)
=== RUN   TestT4_ClosedLinkGetsOneMoreGrace
--- PASS: TestT4_ClosedLinkGetsOneMoreGrace (0.00s)
=== RUN   TestT5_DisconnectThenCloseThenReconnect
--- PASS: TestT5_DisconnectThenCloseThenReconnect (0.00s)
=== RUN   TestT6_OpenSessionCountedAtAnyAge
--- PASS: TestT6_OpenSessionCountedAtAnyAge (0.00s)
=== RUN   TestT7_StaleDevicePlusOtherLink
--- PASS: TestT7_StaleDevicePlusOtherLink (0.00s)
=== RUN   TestT8_ResetEmpties
--- PASS: TestT8_ResetEmpties (0.00s)
=== RUN   TestT9_LinkWithoutEntryCounted
--- PASS: TestT9_LinkWithoutEntryCounted (0.00s)
=== RUN   TestT10_SecondConnectedDoesNotRestartGrace
--- PASS: TestT10_SecondConnectedDoesNotRestartGrace (0.00s)
=== RUN   TestX_WrongSenderIgnored
--- PASS: TestX_WrongSenderIgnored (0.00s)
PASS
ok  	batman-prov/cmd/batman-provd	1.010s
test rc=0

```

### out-mut.txt

```
== M0 baseline (no mutation)
ok  	batman-prov/cmd/batman-provd	1.008s
== (a) age rule removed
vet: ./bluez.go:815:9: declared and not used: e
./bluez.go:815:9: declared and not used: e
FAIL	batman-prov/cmd/batman-provd [build failed]
FAIL
== (b) Close refresh removed
--- FAIL: TestT4_ClosedLinkGetsOneMoreGrace (0.00s)
    n1_test.go:132: T4 right after Close n=0 stale=[/org/bluez/hci0/dev_AA_AA_AA_AA_AA_AA] (want 1, none)
FAIL
FAIL	batman-prov/cmd/batman-provd	0.008s
FAIL
== (b2) Close refreshes since but does not clear logged
ok  	batman-prov/cmd/batman-provd	1.008s
== (c) Close writes unconditionally
--- FAIL: TestT5_DisconnectThenCloseThenReconnect (0.00s)
    n1_test.go:156: T5 n=0 stale=[/org/bluez/hci0/dev_AA_AA_AA_AA_AA_AA] (want 1, none: the new connection gets a fresh grace)
FAIL
FAIL	batman-prov/cmd/batman-provd	0.008s
FAIL
== (d) union removed (links + devConn counted separately)
--- FAIL: TestT3_DeviceWithLinkCountedOnce (0.00s)
    n1_test.go:115: T3 n=2 stale=[] (want 1 — not 2 —, none)
--- FAIL: TestT6_OpenSessionCountedAtAnyAge (0.00s)
    n1_test.go:167: T6 at 31s n=1 stale=[/org/bluez/hci0/dev_AA_AA_AA_AA_AA_AA] (want 1, none)
--- FAIL: TestT7_StaleDevicePlusOtherLink (0.00s)
    n1_test.go:183: T7 n=1 stale=[/org/bluez/hci0/dev_AA_AA_AA_AA_AA_AA /org/bluez/hci0/dev_BB_BB_BB_BB_BB_BB] (want 1, [A])
FAIL
FAIL	batman-prov/cmd/batman-provd	0.008s
FAIL
== (e) second Connected=true overwrites since
--- FAIL: TestT10_SecondConnectedDoesNotRestartGrace (0.00s)
    n1_test.go:219: T10 n=1 stale=[] (want 0, [A])
FAIL
FAIL	batman-prov/cmd/batman-provd	0.008s
FAIL
== (f) countLocked does not set logged
--- FAIL: TestT2_StaleAfterGraceLoggedOnce (0.00s)
    n1_test.go:105: T2 countLocked second n=0 marked=1 (want 0, 0)
FAIL
FAIL	batman-prov/cmd/batman-provd	0.009s
FAIL
== (g) wrong-sender signal accepted
--- FAIL: TestX_WrongSenderIgnored (0.00s)
    n1_test.go:228: X: a signal from :1.99 made an entry
FAIL
FAIL	batman-prov/cmd/batman-provd	0.009s
FAIL
== (h) register() recount removed
ok  	batman-prov/cmd/batman-provd	1.009s
== (i) resetDevs does nothing
--- FAIL: TestT8_ResetEmpties (0.00s)
    n1_test.go:196: T8 entries=1 n=1 stale=[] (want all empty)
FAIL
FAIL	batman-prov/cmd/batman-provd	0.009s
FAIL
== (j) converge ignores n (uses len+len as today)
ok  	batman-prov/cmd/batman-provd	1.010s
Traceback (most recent call last):
  File "<stdin>", line 3, in <module>
AssertionError: ('\tb.logStale(k)\n\tok, why', 0)
== (k) converge never prints the line
ok  	batman-prov/cmd/batman-provd	1.014s
restored: bluez.go identical to the unmutated prototype

```

### out-mut2.txt

```
== M0 baseline, all rows incl. the two X extras
ok  	batman-prov/cmd/batman-provd	1.010s
== (a) age rule removed
--- FAIL: TestT2_StaleAfterGraceLoggedOnce (0.00s)
    n1_test.go:99: T2 n=1 stale=[] (want 0, [A])
--- FAIL: TestT4_ClosedLinkGetsOneMoreGrace (0.00s)
    n1_test.go:138: T4 31 s after Close n=1 stale=[] (want 0, [A])
--- FAIL: TestT7_StaleDevicePlusOtherLink (0.00s)
    n1_test.go:183: T7 n=2 stale=[] (want 1, [A])
--- FAIL: TestT10_SecondConnectedDoesNotRestartGrace (0.00s)
    n1_test.go:219: T10 n=1 stale=[] (want 0, [A])
FAIL
FAIL	batman-prov/cmd/batman-provd	0.008s
FAIL
== (g) wrong-sender signal accepted — plan rows T1–T10 only
ok  	batman-prov/cmd/batman-provd	1.013s
== (i2) refreshOwner no longer calls resetDevs — plan rows T1–T10 only
ok  	batman-prov/cmd/batman-provd	1.011s
== (i2) refreshOwner no longer calls resetDevs — with X extras
--- FAIL: TestX_RefreshOwnerResets (0.00s)
    n1_test.go:239: X: the owner change left the entry
FAIL
FAIL	batman-prov/cmd/batman-provd	0.009s
FAIL
== (k) converge never prints the line
ok  	batman-prov/cmd/batman-provd	1.014s
== (l) grace 300 s instead of 30 s
--- FAIL: TestT2_StaleAfterGraceLoggedOnce (0.00s)
    n1_test.go:99: T2 n=1 stale=[] (want 0, [A])
--- FAIL: TestT4_ClosedLinkGetsOneMoreGrace (0.00s)
    n1_test.go:138: T4 31 s after Close n=1 stale=[] (want 0, [A])
--- FAIL: TestT7_StaleDevicePlusOtherLink (0.00s)
    n1_test.go:183: T7 n=2 stale=[] (want 1, [A])
--- FAIL: TestT10_SecondConnectedDoesNotRestartGrace (0.00s)
    n1_test.go:219: T10 n=1 stale=[] (want 0, [A])
FAIL
FAIL	batman-prov/cmd/batman-provd	0.009s
FAIL
restored: bluez.go identical to the unmutated prototype

```

### prototype diff vs worktree (bluez.go)

```diff
--- /c/src/Batman-b8/feed/batman-prov/src/cmd/batman-provd/bluez.go	2026-11-18 22:10:21.262314800 +0800
+++ src/cmd/batman-provd/bluez.go	2026-11-18 23:50:29.822816200 +0800
@@ -51,7 +51,7 @@
 	appOK     bool
 	advOn     bool
 	links     map[dbus.ObjectPath]*bleLink
-	devConn   map[dbus.ObjectPath]bool // Device1.Connected as BlueZ reports it (a link without Acquire*, e.g. a STATUS read)
+	devConn   map[dbus.ObjectPath]*devEnt // Device1.Connected as BlueZ reports it (a link without Acquire*, e.g. a STATUS read)
 	nextRPA   time.Time
 	foreign   int
 	advAt     time.Time // last register / withdraw
@@ -61,7 +61,7 @@
 }
 
 func newBLE(srv *provd.Server, te provd.TestEnv, logf func(string, ...any)) *bleSide {
-	return &bleSide{srv: srv, te: te, logf: logf, links: map[dbus.ObjectPath]*bleLink{}, devConn: map[dbus.ObjectPath]bool{},
+	return &bleSide{srv: srv, te: te, logf: logf, links: map[dbus.ObjectPath]*bleLink{}, devConn: map[dbus.ObjectPath]*devEnt{},
 		quit:  make(chan struct{}),
 		kickc: make(chan struct{}, 1)}
 }
@@ -411,6 +411,9 @@
 	if b.links[l.dev] == l {
 		delete(b.links, l.dev)
 	}
+	if e := b.devConn[l.dev]; e != nil { // N1-CLOSE
+		e.since, e.logged = time.Now(), false
+	}
 	c := b.conn
 	b.mu.Unlock()
 	if c != nil {
@@ -488,7 +491,7 @@
 	b.mu.Lock()
 	if owner != b.bluezName {
 		b.appOK, b.advOn = false, false // a new bluetoothd knows neither
-		b.devConn = map[dbus.ObjectPath]bool{}
+		b.resetDevs()
 	}
 	b.bluezName = owner
 	b.mu.Unlock()
@@ -588,6 +591,13 @@
 		return
 	}
 	b.staleLinks()
+	b.mu.Lock() // N1-RECOUNT
+	n, k := b.countLocked(time.Now())
+	b.mu.Unlock()
+	b.logStale(k)
+	if n > 0 {
+		return
+	}
 	if err := c.Object(bluez, adapter).Call("org.bluez.LEAdvertisingManager1.RegisterAdvertisement", 0, advPath,
 		map[string]dbus.Variant{}).Err; err != nil {
 		b.logLimit("register", fmt.Sprintf("provd: adv register failed: %v", err))
@@ -688,13 +698,15 @@
 func (b *bleSide) deviceChanged(s *dbus.Signal) {
 	b.mu.Lock()
 	defer b.mu.Unlock()
-	if string(s.Sender) != b.bluezName || len(s.Body) < 2 {
+	if string(s.Sender) != b.bluezName || len(s.Body) < 2 { // N1-SENDER
 		return
 	}
 	set := func(p dbus.ObjectPath, props map[string]dbus.Variant) {
 		if v, ok := props["Connected"]; ok {
 			if on, _ := v.Value().(bool); on {
-				b.devConn[p] = true
+				if b.devConn[p] == nil { // N1-KEEP
+					b.devConn[p] = &devEnt{since: time.Now()}
+				}
 			} else {
 				delete(b.devConn, p)
 			}
@@ -730,8 +742,10 @@
 
 func (b *bleSide) converge(reason *string) {
 	b.mu.Lock()
-	name, appOK, advOn, nlinks, next := b.bluezName, b.appOK, b.advOn, len(b.links)+len(b.devConn), b.nextRPA
+	name, appOK, advOn, next := b.bluezName, b.appOK, b.advOn, b.nextRPA
+	nlinks, k := b.countLocked(time.Now())
 	b.mu.Unlock()
+	b.logStale(k)
 	if name == "" {
 		return // bluetoothd not on the bus: wait for NameOwnerChanged
 	}
@@ -781,3 +795,50 @@
 		b.register(*reason)
 	}
 }
+
+// ---- N1: a connected device with no session stops counting after linkGrace (#329) ------------------------------
+
+const linkGrace = 30 * time.Second
+
+type devEnt struct {
+	since  time.Time // Connected turned true, or the device's link was closed
+	logged bool      // the "link without session" line was written for this stale period
+}
+
+// resetDevs: b.mu held
+func (b *bleSide) resetDevs() { b.devConn = map[dbus.ObjectPath]*devEnt{} }
+
+// liveLinks: n = devices with a link + devices BlueZ reports connected that have no link and are younger than
+// linkGrace (each device once); stale = connected, no link, older.
+func liveLinks(links map[dbus.ObjectPath]*bleLink, devConn map[dbus.ObjectPath]*devEnt, now time.Time) (n int, stale []dbus.ObjectPath) {
+	n = len(links)
+	for p, e := range devConn {
+		if _, ok := links[p]; ok { // N1-UNION
+			continue
+		}
+		if now.Sub(e.since) < linkGrace { // N1-AGE
+			n++
+		} else {
+			stale = append(stale, p)
+		}
+	}
+	return n, stale
+}
+
+// countLocked (b.mu held): liveLinks, and marks each stale entry not yet logged; returns how many it marked
+func (b *bleSide) countLocked(now time.Time) (n, marked int) {
+	n, stale := liveLinks(b.links, b.devConn, now)
+	for _, p := range stale {
+		if e := b.devConn[p]; !e.logged {
+			e.logged = true // N1-LOGGED
+			marked++
+		}
+	}
+	return n, marked
+}
+
+func (b *bleSide) logStale(k int) {
+	for ; k > 0; k-- {
+		b.logf("provd: link without session for 30 s")
+	}
+}
```
