# #329 PR 3 程式碼審查第二輪 — CR-D（現場走查）

（審查者的 Write 被權限檢查故障擋下；本檔由作者照審查者交回訊息的原文存檔。）

- 範圍：`git diff 9b00ca6^..1bf9ae7 -- app`，head 1bf9ae7（第一輪修正 = c727779、1bf9ae7）。基準不重審：254-app-join2.md、nodes.dart、Rust。計畫：329-pr3-plan.md v18。
- 方法：照 (a)–(f) 六條路徑逐行讀碼；在 repo 的拷貝（scratchpad `crd/`）裡寫探針測試、做改壞對照。手機、adb、節點都沒碰。

**判定：APPROVE-WITH-CHANGES**（0 BLOCKER、1 MAJOR、4 MINOR）

## 全套測試與分析器（1bf9ae7，原 repo）
```
00:28 +845: All tests passed!
dart analyze lib test
   info - test\member_ui_test.dart:4:8 - The import of 'dart:typed_data' is unnecessary ... - unnecessary_import
1 issue found.
```

## MAJOR

**M-1 建立模式：畫面上標「由這台建立網路」的節點，不一定是真正去建立的那台**
- 情境（走查 (a)）：第一台在 3.2 時已讀到 `node_state == 1`，第二台剛認領還沒讀到。進 4.1 時 `_tickOnce` 先照名稱排序勾第一台，再勾 `widget.ticked` 的第二台。第二台名字排在前面時，畫面標它是建立者，實際卻是第一台建立。使用者取消再勾一台也會這樣。
- 證據：標示 `net_pages.dart:360-361`（`ids` 照名稱排序，:192）；實際 `:243` 用 `_ticked` 的 Set 加入順序，`:252-255` 用 `ticked.first` 建立。計畫 :194「照 4.1 清單順序（節點暱稱排序）」。探針 P1：`P1 first row=節點 1234 marked=[節點 1234] runOrder=[0000000000000c4f2a7d2c, 0000000000000000001234]`。
- 影響：建立網路的是另一台；pending 的建立者與節點頁的「檢查網路」都落在使用者沒選的那台。
- 修法：`final ticked = _ids.where(_ticked.contains).toList();`；負對照：斷言 `NetRunPage.ids.first` 等於標示的那一列，1bf9ae7 上會 FAIL。

## MINOR

**m-1 結果列「檢查網路」升級後，提示仍說「網路沒有建立完成」**：`_check`（:599-602）把列改成 ok，但 `run.stopped` 仍是 `makeFailed`，:628-633 照樣顯示。⚠️ 只讀碼。修法：確定已建立時把 `makeFailed` 清成 `none`，補 widget 測試。

**m-2 對話框關閉只看 `c.mounted`，同一回合兩個關閉來源會 pop 掉 NetRunPage**：探針 P2（radioFirst=true）拋出 `A request was made to pop a route with a result of type bool, but the route expected a value of type String. The route was: MaterialPageRoute<String>`（net_pages.dart:539）。⚠️ 推論現場走不到（兩事件來自不同 platform channel 的 task），列為強化項。修法：每個對話框一個 closed 旗標，或檢查 `isCurrent`。

**m-3 檢查頁 dispose 的 `_run?.pageGone()`（:719）沒有頁面層測試**：改壞對照 M-e 拿掉後 net_pages / wiring / flows / add_pages / pages 共 `+140: All tests passed!`。修法：widget 測試（登入停在 gate → 移除頁面 → 放行 → 沒有 confirm、handoff 已關、佔用已放）。

**m-4 commit message 的測試數與實際不符**：c727779 寫 860，實際 845。

## 改壞對照
M-a（3.2 改回 `pushReplacement`）、M-b（節點頁不處理 goMake）、M-c（`_dismiss` 不 pop）、M-d（連線檢查遇頁面消失不 close）、M-f（問繼續 / 停前不先 close）：都有測試 FAIL ✅。M-e 沒被擋（m-3）。

## 走查 (a)–(f)（佔用與對話框；除上述外只讀碼 ⚠️）
- (a) raw 佔用：認領頁拿、關頁時 pageGone；session 佔用：4.1 拿 → 交 NetRunPage → hold → 還 hold → 完成時 pageGone 立即釋放。回首頁不留佔用、不留對話框。只有 M-1。
- (b) 拔電 → 只給「檢查網路」；04 沒電時檢查頁只給「再檢查一次」；回答後才給「建立網路」；退場動畫中按開始被 D9 擋（計畫 :184 / :251），過一下再按可開始。P3 沒跑。
- (c) 回節點頁時 NodeLink 頁面恢復成這台（net_pages.dart:188）✅ 讀碼；測試只驗 widget 欄位。
- (d) 國家問題當「不要」關掉，不送 `countryConfirmed`；之後只一個「繼續 / 停」，hold 有還。
- (e) 連線檢查中關頁：console 關、佔用放；檢查頁登入中關頁：最多跑完 60 s 登入，關 handoff、不送 confirm，再放佔用。
- (f) 每段等待中關藍牙都停下並說明原因，沒有問題留在畫面上；建立途中要靠 GATT 斷線事件，沒有真機證據。

## ✅ / ⚠️ / ❌
- ✅ 全套 845、analyze 如上；M-a/b/c/d/f 被擋、M-e 沒被擋；探針 P1、P2 輸出如上。
- ⚠️ 其餘走查只讀碼；D9 時序、m-1 沒實測；m-2 現場走不到是推論；藍牙關閉時 GATT 斷線沒有真機證據。
- ❌ P3、P4 沒跑；報告檔沒寫成（權限檢查故障）；沒碰真機；`cargo test` 沒跑。

## 安全
修正沒有新增輸入面；`onLost`、`goMake`、`addAgain` 只在同一行程內傳遞。被入侵的節點在國家問題開著時斷線：同 (d)，不送國家設定、不疊兩個對話框。M-1 不是安全問題。
