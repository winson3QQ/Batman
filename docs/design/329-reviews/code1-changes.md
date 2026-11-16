# NodeLink 排程（可執行規格）程式審查第 1 輪 → 731f7e8 的逐條對應

- 第 1 輪的審查對象：`feat/329-nodelink-core` @ 236ea4b。
  - 審查 A = APPROVE-WITH-CHANGES，0 BLOCKER、4 MAJOR、10 MINOR。
  - 審查 B = APPROVE-WITH-CHANGES，0 BLOCKER、5 MAJOR、9 MINOR。
- 原文：`review-code1-A.md`、`review-code1-B.md`。
- 修正後的程式：731f7e8。
  - 114 個模擬測試全過。
  - 60 個逐字改壞規則的對照全部會 FAIL，沒有一個因為改出編譯錯誤才失敗。
  - 改壞規則的清單：scratchpad 的 `core/mutations.txt`。
  - 執行腳本：`core/mutate.pl`。
  - 輸出：`core/mutate6.out`。

## MAJOR

| 發現 | 改了什麼 | 守住它的測試（改壞規則的對照名稱） |
|---|---|---|
| A-M1 = B-M2：90 s 上限時切掉的那次嘗試被算成「試過」 | 切掉的那次從試過裡撤回（嘗試次數、該位址計數都減回去） | T-L21 7 / 8 / 12 台斷言之後沒有「沒找到」「還沒輪到」；RB-FIX-1、RB-FIX-2（`M1 cut attempt counts as tried`） |
| A-M2 = B-M3：藍牙、權限、金鑰的變化會清掉「身分不符」 | 改成一層疊加：`blocked` 加上 `shownWhy`，底下的節點狀態不動 | code-1 A-M2、RB-FIX-3、RB-FIX-3b、RB-FIX-8（`M2 …` 兩條） |
| A-M3 = B-M1：無法加入或移除紀錄 | 新增 `setRecords`，並在 `releaseLease(recs:)` 時更新；留下的紀錄保留備忘 | code-1 A-M3、RB-FIX-7、RB-CLAIM-*（`M3 setRecords ignored`） |
| B-M4：認領完立刻建網時，附近別人的節點多就登不進去 | `loginFor` 先試沒試過的位址、再重試 | RB-CLAIM-0/3/6/8、RB-CLAIM-RETRY-8（`loginFor retries before untried addresses`）。**接受的上限**：附近有超過 8 台別人的節點時，第一分鐘可能找不到新節點，按一次「再試一次」就會成功（RB-CLAIM-RETRY-10/12）。原因：剛認領完的 30 s 內，新節點和別人的節點都回「解不開」，分不出來 |
| A-M4 = B-M5：負向對照只蓋到一部分 | 兩位列出的規則逐條補測試；改壞規則的清單從 19 條增加到 60 條，全部會 FAIL。另外：T-L13(a) 改成每輪開始時節點正被別人連著；T-L16 改成每秒取樣（RB-T-L16-monitored），刪掉原本空的斷言；T-L2(e) 的前提另外斷言（「前 4 輪跑滿 90 s」）；T-L14 改成先讓節點換位址 | mutate6.out |

## MINOR

| 發現 | 處理 |
|---|---|
| A-m1 / B-m8：重新整理不再結束「身分不符」 | 保留程式的行為（比較安全），並寫成測試 `refresh keeps 身分不符 until a read`。設計回填時改 §4.3.3-4、X1 / X2 / X30 |
| A-m2 / B-m6：冷啟動要多久 | 數字由測試印出：2 台約 30 s、7 台 240 s、8 台 270 s、12 台 820 s；2 台加 12 個不回應的位址 145 s。回填 §4.3.7 |
| A-m3 / B-m2：「立刻有原因」沒有把連續「不變」歸零 | 已修；測試 RB-FIX-5（`m3 …`） |
| A-m4：沒有連續「還沒輪到」的計數 | 新增 `notYetRun` |
| A-m5 / B-m5：擁有權只靠慣例；`LoginFor` 沒有綁佔用 | 佔用收回後到的 `loginFor` 結果直接丟棄（有測試）。欄位設成唯讀：這一版沒做，見下面「沒有照建議做的」 |
| A-m6：`loginFor` 實際可以超過 60 s | 嚴格在 60 s 切掉（`loginFor runs past 60 s`） |
| A-m7 / B-m9：簽名之前的 `End::Broken` 必須對應成 `noResponse`，否則攻擊者能種下錯的「是 Y」 | 這是 driver 的契約。程式註解和設計回填都寫明：`Res.broken` 只能在登入成功之後回報 |
| A-m8：X2 測試的時間點靠巧合 | X2 改成在一輪進行中（90 s）測 |
| A-m10 / B 的等價突變 R51：「是別台」的判斷是死碼 | 拿掉。「這一輪登入過」那個旗標也是死碼，一起拿掉 |
| B-m1：不回應的裝置冒用節點換掉前的舊位址，那台就永遠讀不到 | 已修：已知位址在同一輪兩次沒回應就丟掉「是 Y」，下一輪改去找；`loginFor` 也一樣。測試 RB-REPLAY-a / b / c（`replay: …`） |
| B-m3：`foreground()` 重複呼叫會多開一輪 | 改成重複呼叫不做事；測試 RB-FIX-6 |
| B-m4：藍牙在別的頁面時恢復，60 s 內回首頁仍顯示「藍牙關閉」 | 改成疊加一層後就消失了；測試 RB-FIX-8 |
| B-m7：模擬器比真機寬鬆 | B 的 SIM_REAL 改成預設行為：節點沒在廣播時要等它，8 s 內等不到就算沒回應 |

## 沒有照建議做的

- 欄位改成唯讀視圖（A-m5、B-m5）：沒做。測試需要直接設定備忘來造出情境。等 PR 1 接上驅動層時，對外的 `NodeLink` 只公開唯讀查詢，核心物件不給頁面使用。
- 「同一位址隔 6 s」：真實的連線模型下，太早連只會等節點重新廣播，所以從行為上看不出差別。規則保留（設計 N8），改用直接測排程介面的單元測試守住。
