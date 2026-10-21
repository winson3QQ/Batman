# 審查 A 第 6 輪(聚焦):§13 實證結果與 §13.1 對 §5.4 鏈 0 / 鏈 1 的修正

審查者 A,2026-10-21。範圍:§13、§13.1,以及它們會碰到的 §5.4、§4.5、§4.8、§5.5 (2)。我讀了 `feat/254-p1`(`/home/yello/Batman-p1`,HEAD 58dbb7b)的原始碼與 firmware rootfs。

**判定:APPROVE-WITH-CHANGES**(先修完兩個 MAJOR 再實作鏈 1):0 BLOCKER / 2 MAJOR / 6 MINOR。

> ⚠️ **本輪沒有在真機上驗證**:我要唯讀查 04 時,04 先回 `Connection refused`,之後一直連不上。推測當時有別的測試正在重開它;我沒有重試、也沒有做任何其他動作。下面 Z4 只是從 firmware rootfs 讀出來的,**不是 04 的真機證據**。

## 0. 本輪證據

| # | 事實 | 證據 |
|---|---|---|
| Z1 | P1 的 autocommit:`prov-state` 的 verdict 是 `unclaimed` → `NEED_MESH=0` | `Batman-p1 …/batman-autocommit:408` |
| Z2 | E3 實測:trial 開機到 `HELD`(健康判定通過)約 92–105 s | §13 E3 |
| Z3 | P1 config-save:`--on-join` 只在 `prov-txn` / `.txn` 存在時讓路;`--save` / `--if-healthy` 只等 txn。**三者都不看 identity 是否一致**;identity 的比對只有 `--check` 裡的 `prov_compare` 會做 | `Batman-p1 …/batman-config-save:140-158` |
| Z4 | 主機名:`99-halow-identity` 用 `morse_generate_default_hostname`,取 `get_mac_label`(沒有就用 eth0 的 MAC)的尾 4 碼,是確定的;只有讀不到 MAC 時才用亂數。avahi 預設啟用(`S61avahi-daemon`)、`allow-interfaces=br-ahwlan`(eth0 在裡面)、沒有設定 `host-name`(= 系統主機名) | firmware rootfs `lib/functions/morse.sh`、`etc/avahi/avahi-daemon.conf`、`etc/rc.d` |
| Z5 | P1 的 freshness gate 遇到 `prov-identity` 仍然先看 `allowed STALE_P5`;有覆寫就以 `stale-allowed` 放行 | `Batman-p1 …/batman-slot:486-489` |

## MAJOR

### M1. 鏈 1 的 fresh trial 現在寫的是「不 hold」。在 P1 上,unclaimed 的槽約 95 s 就會被 commit,早於 openmanetd 在約 168 s 的重開 → 會重演 E1b,而且這次是被 commit 掉
- **情境**:P1 對 unclaimed 判 `NEED_MESH=0`(Z1)。健康判定約 92–105 s 就通過(Z2)→ autocommit 在 openmanetd 保留位址、重開(約 168 s,F34)**之前**就 commit 了 B。
  - 結果:04 committed 在 B 上;第二次開機用的是保留後的未知位址;tryboot 已經消耗,不會自己回 A。harness 只能靠 mDNS 或 ARP 去找它,這正是 E1b 失敗的那條路。
  - 如果認領已經做了,B 是 claimed、上鎖,只剩 lab key 能登入。04 有乙太網,所以理論上救得回來,但無人值守(P-U12)的流程會停在一個非 S0、位址不明的狀態。
  - E1b 用的是 wsl.9:legacy 規則要求入網,所以它 revert 了。這掩蓋了 P1 上的行為。
- **修正**:鏈 1 第 4 步改成 **hold = V**。L1 / L44 的「unclaimed 不需要鄰居」改用 `HELD` 斷言,而且要在 openmanetd 重開之前寫進 p6 的證據檔。第 1 個 trial 最後一定回到 A:openmanetd 重開,或 `back_to_a`。

### M2. P-U6 的「凍住」不完整:A 凍住期間,`--on-join` / `--save` / `--if-healthy` 照樣把 A(身分 X)的設定寫進 p5(身分 Y)。這同時打掉了 §13.1 的 (2) 前提
- **情境(§13.1)**:fresh trial 認領 → p5 = claimed、身分 Y、placeholder mesh key。回到 A:A 開機時 joinwatch 會照常啟動(停止服務撐不過重開)→ A 入網 → 第一個 JOINED tick 的 `--on-join` 把 A 的 overrides(fleet mesh key)、dropbear host key、`authorized_keys`、shadow-root 寫進 p5(Z3)。
  - p5 變成「claimed Y + A 的 live key」→ 下一步「A → B 的 trial」測到的是 claimed + live key(走今天的規則),**不是 (2) 的 claimed + placeholder**。斷言判讀就錯了。
- **產品面**:這正是 P-U6 要防的「X 的設定 + Y 的擁有權」混合。在現場(上層 §4.8 的 rollback 情境),凍住的舊槽仍會一直改寫 p5:把 X 的 `authorized_keys` 與 shadow-root 寫進 Y 的 p5。下一次 fresh overlay 時,Y 就帶著 X 的登入憑證。
- **修正**:
  - **P1**:`--on-join`、`--save`、`--if-healthy` 在「overlay 與 p5 的 identity 都完整且不同」時拒絕寫入:`--on-join` rc 1 並記 log;`--save` 回錯誤,提示 identity-mismatch。也就是重用 `prov_compare` 的判斷,讓每個寫入模式都經過它。
  - 加入 `prov-unit-cfgsave` 案例,mutant 是「`--on-join` 不檢查 → p5 overrides 改變 → FAIL」。
  - §4.8 補上這一列。
  - 修好之後,§13.1 的流程裡 A 凍住期間 p5 不會被改。可以順便斷言:A 的 `--on-join` 有記「identity-mismatch: not writing」,而 p5 的檔案清單在 A 凍住期間沒有變化。

## MINOR

- **m1** **時間窗太緊**:E1a 在 83 s 才找到 04;之後要做 L1 的證據批次(≤ 60 s)、寫 key、新開一條連線驗證、認領(簽章往返)、認領的 `--save`,全部要在約 168 s 之前做完 → 很可能被 openmanetd 的重開切斷,留下「persist 了,但 `--save` 還沒做」的半套狀態(p5 有 claimed 但沒有 `.seeded`、沒有 lab key)。
  - **修正**:找到 04 之後,第一個指令先 `/etc/init.d/openmanetd stop`(只在測試中;在報告裡記為偏離),時間窗就延長到 hold 的 trial 期限(約 480 s)。
  - 證據批次照原本的順序做:L1 的斷言不依賴 openmanetd。
  - 若選擇不停 openmanetd,就要寫出半套狀態的處理:第 2 個 trial 會被 #202 閘以 claimed 未 seed 擋下 → 這次判 FAIL「時間窗不足」,走 restore。
- **m2** **第 2 個 trial(A → B)也會在約 168 s 重開**:p5 是第 1 個 trial 認領時 seed 的,含 `dhcpconfigured=0` 與 B 第一次開機的 `10.41.254.x`。B 的 trial 由這份 p5 還原,所以位址是**確定的**(= p5 裡的 `ahwlan.ipaddr`,可以事先從快照或 claim 後的 p5 讀出),但 openmanetd 會再保留位址、再重開一次。
  - **修正**:`HELD` 的判定與證據要在 openmanetd 重開之前寫進 p6。或者:第 1 個 trial 停掉 openmanetd 之前,先把 `dhcpconfigured=1` 寫進 B 的 uci,讓認領的 `--save` 寫進 p5。但這會改動受測內容,要列為偏離。
- **m3** **mDNS**:
  - 主機名是由 MAC 決定的(Z4),fresh 槽與 A 會同名 ✅;
  - avahi 預設啟用、在 br-ahwlan 上發布 ✅(依 rootfs 原始碼;fresh 槽上的實際名稱仍待真機確認,同 §13.1 的 ⚠️);
  - Windows 的 mDNS 快取可能在位址改變後還回舊位址(TTL 約 120 s)。
  
  **修正**:每次解析之後,用 ARP 表確認那個位址的 MAC = 04 的 eth MAC 才 ssh;fresh 槽的 host key 每次不同,所以要以 MAC 作為身分。
- **m4** 「從 A 寫 B」用 `ALLOW_STALE_P5` 是可行的:P1 的閘在 `prov-identity` 時仍先看 override(Z5)✅。「先 restore p5 再做」會把 (2) 要的 p5 蓋掉,不能選。請在 §5.4 定案:用 `ALLOW_STALE_P5`,只在 04、只在測項裡。並斷言 stage 1 有記錄 `stale-allowed`。
- **m5** **不會卡死**:
  - 第 1 個 trial 是 held 的(依 M1),有 key 守門,上鎖前就驗過 publickey 登入;
  - 第 2 個 trial 是 held 的,B 從 seed 過的 p5 經 Lane A 還原 lab key;
  - A 凍住但 overlay 完好(legacy、有 lab key),一直連得到。
  
  restore 先 dd p5,就解除了不一致;再把 B 寫回 V,就清掉 B 上的 Y。需要寫進斷言:restore 之後 A 的 helper 回到 legacy、沒有 identity-mismatch(依 §4.5.5 比對 p6 的 `prov-state`)。
- **m6** **S0 與目前狀態**:§13 說兩台現在都是 wsl.10、committed 在 **B**;S0 要求 A,而 02 不允許自動跨槽。prov tier B 開始前要由人決定怎麼讓 02 回到 A(這是一般 OTA 加 commit 到 A,依 §4.5.0 只能人工)。或者重新評估 S0 是否一定要 A:理由是 EEPROM 走到 partition 1,而現在 B 是可開機的同版。請在 §13 記錄當前偏離 S0 的情況,以及要怎麼處理。

## 判定
**APPROVE-WITH-CHANGES**。§13.1 的方向(在 fresh trial 的時間窗內認領,再從 A 寫 B 測 (2))可行,也不會卡死 04,但前提是兩個 MAJOR 都修好:
- M1:fresh trial 必須 hold,否則 P1 在 openmanetd 重開之前就會 commit;
- M2:凍住時 config-save 的寫入模式也必須讓路。這是產品缺口,而且 §13.1 依賴它。

另外建議採用 m1(先停 openmanetd)來避開時間窗的競賽。
