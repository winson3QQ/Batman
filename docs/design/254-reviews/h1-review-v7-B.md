# 審查 B 第 7 輪:`254-h1-harness.md` v7(整份)

本輪獨立審查,看的是整份文件,並逐條核對 §16。依據是設計文字和前幾輪已讀過的原始碼(`batman-slot:731-741`、`batman-autocommit:30-35,269-290,376-383,460-502`),本輪沒有新的節點讀取,也沒有印出任何 IRK。H-U7 是使用者決定,不重議。

**結論:APPROVE-WITH-CHANGES — 0 BLOCKER / 0 MAJOR / 3 MINOR。**

第 6 輪的 B1(在 slot A 上 rollback)已經修好:
- 所有 rollback 都收斂到 `back_to_a` 這一個節點端條件指令;
- `PHASE` 分成四段;
- 我提的三條路徑都有 stub 案例對應。

我逐條推演了 rollback 在各個 PHASE 和中斷時點的結果,沒有找到會在 A 上執行 rollback 的路徑。

---

## 推演 `back_to_a` 與 `PHASE`
| 狀況 | 節點上的實際狀態 | `back_to_a` 的結果 | 結論 |
|---|---|---|---|
| 正常步驟 6,在 B 上、hold 生效 | active=B、V2、未 commit | `cmd_rollback`:`A`=B、`T`=A → `[all]`=`fw_part(A)`(`:731-741`;A 沒有 BADMARK)→ `reboot committed` 以 explicit partition 開進 A | ✅ |
| hold 沒生效且 B 已被 commit | active=B、V2、已 commit | 同上,`[all]` 改回 A,`reboot committed` → A;回 A 後 A 是 committed 預設 | ✅ |
| 成功結束,trap 觸發(`PHASE=returned`) | 在 A | 只印狀態 | ✅(stub 3) |
| tryboot 開錯槽落在 A(`PHASE=ota`) | 在 A、wsl.9 | 條件不成立 → 不動作,記「無法執行」 | ✅(stub 4) |
| `back_to_a` 送出後中斷,節點已回 A(`PHASE=trial`) | 在 A | 條件不成立 → 不動作 | ✅(stub 5) |
| `back_to_a` 送出後中斷,節點仍在 B、正在關機 | 在 B | 再 rollback 一次(冪等,`[all]` 仍是 A)、再 reboot 一次 | ✅ 無害 |
| 回 A 時 autocommit watchdog 剛好同時 revert | 在 B | 兩者都會開進 A | ✅ |

revert 等待上限 ≤ 2280 s,和 E35(wsl.2 `DEF=600`、`MIN_WINDOW=300`、`DEFER_MAX=600`)及 `max(T, START+300)` 一致:trial 的 autocommit 啟動時 uptime 通常不到 300 s,所以 deadline 是 600。✅

---

## MINOR

**m1 harness 中途死掉時,02 不會重開,H-U7 涵蓋不到**。H-U7 的理由(E36:翻轉段是 legacy JW,被動監聽者能推出 02 的 IRK)在 harness 中途死掉時一樣成立,但 02 的 deadman 只做 bluetoothd restart。04 有 `irk-exposed` 讓 deadman 重開(H-U6),02 沒有對應的機制,所以 02 的 IRK 會一直有效到下次重開。另外,tier B 區塊在翻轉段之後因為某一段 FAIL 而提早結束時,「收尾重開 02」也要保證會執行。修法:
- 翻轉段開始前,也在 02 寫 `irk-exposed`;
- 02 的 deadman 遇到它就 `batman-slot reboot committed`,做法和 04 相同,原因先寫進 p6 log;
- 區塊收尾重開 02 的條件改為「本次 boot 的 02 有 `irk-exposed`」,和成功與否無關;
- §5、N7 補上 02 這一側的預期。

**m2 `back_to_a` 的版本條件只會產生「什麼都不做」的狀態,沒有保護作用**。真正防止「在 A 上 rollback」的是 `active = B` 這個條件。若節點在 B、但版本 ≠ V2(步驟 1 已驗 payload 與 slot B 位元組相同,照理不會發生),`back_to_a` 不會動作,節點就停在一個 hold 不會生效的 B trial,可能被 commit。建議:
- 條件只保留 `active = B`;
- 版本不符時照樣 rollback 回 A,並在輸出寫 `UNEXPECTED VERSION`、N3 記為「無法執行」;
- stub 6 改成驗證這個行為。

在 B 上 rollback 一定回 A,所以拿掉版本條件不會引入新的風險。

**m3 hold 旗標檢查放錯位置**。殘留的 `autocommit-hold-commit` 寫在 P6(「BLE harness 狀態」)下,但它是 OTA / autocommit 的狀態,和 BLE 無關,而且 fleet 裡的 Pi 3 節點也可能有。建議移到 P3(slot / committed 那一組),FAIL 訊息帶出旗標內容和安全清除步驟,並寫明它也會擋下操作者為 #261 驗收而刻意放的 hold(這是正確的:fleet 不在穩態)。

---

## §16 對應核對
| 發現 | 結果 |
|---|---|
| B-B1 | ✅ `back_to_a`、四段 `PHASE`、stub 3 / 4 / 5 / 6;另見 m2 |
| B-m1 孤兒 `dm.new` | ✅ `dm_arm` 開頭先驗證並取消 |
| B-m2 時限 | ✅ E35,≤ 2280 s,從 OTA 送出起算 |
| B-m3 trap 在正常結束時觸發 | ✅ 已明寫,有 stub 3 |
| A-u1 / u2 02 的 IRK、`reboot committed` | ✅ 正常路徑成立;中斷路徑見 m1 |
| A-u3 殘留旗標 | ✅ 有檢查也有清除步驟;檢查的位置見 m3 |

## 結論
**APPROVE-WITH-CHANGES**。3 個 MINOR 都可以在實作時處理,不需要再送設計審查。其中 m1(02 側的 `irk-exposed` 與 deadman 重開)和 H-U7 的安全理由直接相關,建議優先處理。
