# #329 廣播間隔判定 — 程式碼審查 D(第二輪)

- 範圍:`git diff f89f2e8..9b17237` 整份(harness only),對照 `docs/design/329-adv-interval.md` §8 T1a/T1b、§11(凍結,不重審設計)。
- 角度:判定程式在節點上的生命週期/失敗路徑、lease 時間預算、`set -u`、截斷/異常 btmon 擷取、0x08|0x0036、known-failures ERE。
- 環境:WSL Ubuntu-24.04,`/tmp/revD/r`(由 bundle clone,HEAD 9b17237);busybox v1.36.1 ash/awk。沒有碰任何節點、手機、adb、網路;worktree 只新增本檔。

**Verdict: APPROVE-WITH-CHANGES**(0 BLOCKER / 2 MAJOR / 4 MINOR)

---

## 1. 第一輪發現是否關閉

| 第一輪 | 狀態 | 證據 |
|---|---|---|
| BLOCKER:`btmon -T` 標頭被截斷(`LE.. (0x08|0x0006)`、`Command Comp.. (0x0e)`),舊版比對不到 | ✅ 關閉 | 真機擷取 `a4/nc/advint-live-1.txt` 與 `btmon-04-wsl32-dated.txt` 在 busybox ash 下都得到預期行(E1);更寬的截斷 `LE..`/`Co..` 仍正確(E6);負對照 MUT 1(把 `(0x0e)` 換回 `"Command Complete"`)→ 離線測試 3 個 fail |
| MAJOR:測試只做存在性檢查 | ⚠️ 大部分關閉 | 13 個 mutation 有 11 個被抓到;剩 MUT 4、MUT 9 沒被抓(見 MAJOR-2、MINOR-3) |

## 2. 實際跑過的(✅,附輸出)

- `scripts/test-dv-ble-254.sh` → `124 passed, 0 failed` rc=0;`scripts/test-dv-bt-uart-305.sh` → `54 checks, fails=0` rc=0。
- `busybox ash -n` 三個節點腳本都過。shellcheck 對新區段只有 SC3043(`local`,既有慣例)與 SC2034(AS_* 由呼叫端讀)。
- E1 busybox ash:三個 fixture + 真機擷取,無 key → `image without the interval [...]`;有 key → `block 1 of 1 … main.conf has the key`(NEW);edited-pass + key → PASS。
- E2 CRLF 擷取 → FAIL(fail-safe)。E3 擷取切在 block 中間 → 一般 FAIL,不是舊 image 行。E9 亂碼/只有 banner → `no LE Set Advertising Parameters`。E10 CC 在 command 之前 → `no Command Complete`。
- E4 只有 0x0036 → `FAIL adv interval: no LE Set Advertising Parameters (0x08|0x0006) in the capture`(與 §11 一致)。E5 好的 0x0006 + 壞的 0x0036(1280)→ PASS(0x0036 被忽略)。
- E8 `set -u`:`adv_int_check` 單一參數 OK;`adv_int_arm` 在 BMF 未設時 `ash: BMF: parameter not set` 後印空的 `NO`(實務上到不了:`bm_start` 失敗就離開該 arm)。
- E11 key 偵測:`Key=`、tab 縮排、行尾 CR → KEY;註解、`…IntervalX`、小寫、只有 Max、檔案不存在 → NOKEY。
- 卡住的 bluetoothctl(假 binary + 真的 `lim`,busybox ash 計時):

  ```
  hang, no output, key/no key      -> adv sysconfig unreadable  tries=5 unr=5  (32.6 s)
  prints 0008 then hangs, key      -> 0008 / 0008 after 5 tries               (32.6 s)
  prints 0008 then hangs, no key   -> image without the interval, tries=1     (6.0 s)
  ignores TERM                     -> unreadable                               (32.6 s)
  segfault rc 139, no output       -> unreadable                               (~4 s)
  ```
  最壞每次 rebind 約 33 s < lease 180 s / deadman 185 s(`scripts/node/bt-uart-305.sh:232`);10 次約 330 s + 既有流程,仍在 host 的 600+120 s 內(`scripts/dv/bt-uart-305.sh:63-82`)。沒有殘留程序(複查 0)。
- 真機 log 餵 `kf_classify`(2026-11-20):

  ```
  boot-provd-after.log: FAIL lines=1 -> known #329
  dep-restart-after.log: FAIL lines=4 -> known #329
  rebind-04-after.log: FAIL lines=10 -> known #329
  rebind-02-after.log: FAIL lines=10 -> known #329
  rebind-04-before.log: FAIL lines=0 -> new (no FAIL lines to match)
  ```
  兩台 rebind 的 DET 行 10/10 都是 `tries=1 unreadable=0`。
- known-failures ERE(E12):版本字串空 `[]` → new;尾端多字 → new;任意非空版本 → known;`kf_check ok`。
- Mutation(各自 clone 跑對應離線測試):1、2、3、5、6、7、8、10、11、12、13 被抓;**4、9 沒被抓(124 passed)**。

## 3. 只讀過、沒跑的(⚠️)

- `lim`/`lim_kill` 的 tree-kill 實作本身(只用假 binary 驗過結果,沒在節點上驗)。
- bluetoothd 沒在跑的路徑(只有離線測試的 stub `pidof`)。
- `mgmt.read-sysconfig` 為唯讀、判定不印秘密(只印間隔值與版本字串)— 讀碼判斷。
- host 端 `prov-provd-254.sh` 的 `j()`(62-69)與 dep arms 傳 `$PCD/btmon`(232-240)。

## 4. 發現

### MAJOR-1 — 舊 image 上被切斷的 rebind 場次會被歸成 KNOWN #329

- **情境**:04/02 還是沒有 key 的 image(到 2026-12-20 前的常態)。rebind 第 3 次後 ssh 斷線、節點重開、或 host 720 s 逾時。`bt305_leased`(`scripts/dv/bt-uart-305.sh:69-74`)只把已收到的輸出印出並設 `rc`,release 成功時不印任何 FAIL 行。log 裡唯一的 FAIL 行是 3 行舊 image 行 → 全部符合 `bt-uart-rebind-305` 條目。
- **證據(跑過)**:
  ```
  cut run: known #329 (issue state not checked: no gh)
  same cut run before this change (no FAIL lines): new (no FAIL lines to match)
  ```
  也就是這個變更讓「場次沒跑完」從 NEW 變成 KNOWN。同類:`INVALID prov-dep-restart-254: … precondition: provd not advertising` + 一行舊 image 行 → `known #329`(kf 不看 INVALID 行)。
- **修法(最小)**:`chk_bt_uart_rebind_305`/`bt305_leased` 在節點命令 rc 為 124/255,或輸出裡沒有最後一行 `DET rebind 10:` 時,印一行 FAIL(與 `prov-provd-254.sh:62-69` `j()` 的 "the judge did not finish" 同一做法),並加一個離線 kf 案例(切斷的 log → NEW)。INVALID 那條若不處理,至少在 PR body 的「沒處理」列出。

### MAJOR-2 — 舊 image(KNOWN)行需要「connectable + Success」這個條件沒有負對照

- **情境**:`adv_int_check` 用 `c && mn[i]=="1280…" && mx[i]=="1280…"` 計 `old`;把 `c &&` 拿掉後,無 key 的節點上「控制器拒絕(Command Disallowed)」「non-connectable」「沒有 Command Complete」三種真故障都會印舊 image 行 → KNOWN。
- **證據(跑過)**:現行程式對這三種都印一般行(正確):
  ```
  FAIL adv interval: block 1 of 1 is 1280.000 / 1280.000 msec … main.conf has no key
  ```
  套 MUT 4 後三種都印 `image without the interval [v]`,而 `test-dv-ble-254.sh` 仍是 `124 passed, 0 failed`。
- **修法**:加 3 行 `ai_case`(由 `btmon-04-wsl32-dated.txt` 用 sed 產生 refused / non-connectable / 無 CC,配 nokey.conf,預期一般行),各配一個 kf「→ NEW」檢查。不需要新機制。

### MINOR-3 — dep-power 的防呆只被數行數

MUT 9(把 `[ "$a" = dep-power ] && adv_int_arm` 的條件拿掉)→ 124 passed。測試只數 `adv_int_arm` 出現 3 次。修法:grep 改成比對整行 `[ "$a" = dep-power ] && adv_int_arm`。

### MINOR-4 — 設計 §5(151 列)/§8 仍寫 T1a 會讀 0x0036,程式照 §11 不讀

程式與 §11 一致(E4)。副作用:同一份擷取有好的 0x0006 和壞的 0x0036 會 PASS(E5),這顆控制器上不會發生。修法:不改程式;在 `adv_int_check` 註解標一句「§11:沒有 0x0036 分支」,設計 §5/§8 那兩處加指向 §11。

### MINOR-5 — 真機證據多數是 6cfcd8c 跑的

`git diff 6cfcd8c..9b17237 -- scripts/node/` 只有一行(`if (done < n) st[++done]` → `if (n) st[n]`),但 dep-restart / boot-provd / rebind 的 log 是 6cfcd8c 跑的,只有 adv-data-final 是 9b17237。T1b 程式之後沒變。修法:PR body 寫明各 log 對應的 commit;或在 9b17237 重跑 dep-restart(dep-dbus 可能有多個 block,最受那一行影響)。

### MINOR-6 — ERE 與輸出的邊角

- `\[[^]]+\]` 接受任何非空版本:未來某個 image 掉了 key,到期日前仍是 KNOWN(設計已接受,T2/T3 另有檢查)。
- sysconfig 值行被切成 `00` 且無 key → `adv sysconfig 00 / 0008 but main.conf has no key`(NEW,fail-safe,但文字不是 unreadable)。
- awk 無輸出時 `adv_int_arm` 會印空的 FAIL 文字(NEW,fail-safe)。

都不擋 merge,記錄即可。

## 5. 對照要求

| 要求 | 結果 |
|---|---|
| 每個修正有負對照 | ⚠️ MUT 4、MUT 9 缺(MAJOR-2、MINOR-3) |
| 找不到東西可查就 FAIL | ✅ 空/亂碼/無 block/無 CC 都 FAIL |
| 空/讀不到不算過 | ✅ unreadable → FAIL;⚠️ 但場次被切斷在舊 image 上變 KNOWN(MAJOR-1) |
| 有 key 的 image 不會印 KNOWN 行 | ✅ `old == n && !key`,MUT 2 被抓;E1 有 key 一律一般行 |
| 判定唯讀、不印秘密 | ⚠️ 讀碼判斷 |
| 不默默跳過 | ✅ flip/RB_UP 防呆 MUT 10 被抓;⚠️ dep-power 防呆未釘住(MINOR-3) |

## 6. 沒做的(❌)

- 沒在真機上跑任何東西(依指示)。
- 沒驗 gh 查 issue 狀態那段(`KF_NO_GH=1`)。
