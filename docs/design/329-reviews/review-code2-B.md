# #329 NodeLink 排程（可執行規格）程式審查第 2 輪 — 審查 B

審查對象：`feat/329-nodelink-core` @ 731f7e8（`app/lib/src/nodelink/core.dart`、`app/test/nodelink/*`、`mutate6.out`）。
做法：先照真實使用走情境，寫成測試在自己的 worktree `C:/src/Batman-329core-rB` 跑（沒有 commit），再寫改壞規則的對照，最後才讀第 1 輪審查核對有沒有漏。

## 結論

**APPROVE-WITH-CHANGES**：0 BLOCKER、2 MAJOR、11 MINOR。

- **M1**：認領完立刻用 `loginFor` 建網或加入，附近只要有幾台別人的節點，第一次登入常常失敗。同一個房間 7–10 人一起認領時，大部分人要按 2–4 次「再試一次」。根本原因是 code-1 B-M4 改成「先試沒試過的位址」，被認領的那台在 N9 的 4 s 內第一次回「解不開」，於是被排到所有別人的位址後面。作者的模擬器也重現得出來。
- **M2**：「提前再讀連續最多 3 輪」沒有任何測試守著（設計 T-L2(c) 列的就是這個對照）。拿掉上限，114 個測試全過。

其餘排程規則經我的情境測試都成立：冷啟動、陌生位址、不回應的裝置、重播位址、位址輪換、錯誤碼加鎖屏、移除、兩支手機共用一台、10 支手機。用比較嚴格的模擬器（見 §模擬器）重跑結論也一樣。

## 我寫的東西（都在 worktree，沒有 commit）

| 檔案 | 內容 |
|---|---|
| `C:/src/Batman-329core-rB/app/test/nodelink/simr.dart` | `sim.dart` 的複本，多四項：(1) `sight`：節點重新廣播後，手機要 1.0–2.6 s 才看得到它，之後才能開始連（M-1 R）；(2) `toMsg2`：開始連到收到 msg2 要 1.7–4.9 s（M-1 W），8 s 內沒收到就算沒有回應；(3) `lag`：節點被一支手機開始連之後的 1.5 s 內仍在廣播，另一支手機的掃描會看到它，所以兩支手機真的會相撞；(4) `hijack`：重播位址的裝置搶走某些嘗試；另有 `rng`、`jitter`：讀取時間與看到廣播的時間加隨機延遲 |
| `C:/src/Batman-329core-rB/app/test/nodelink/rb2_test.dart` | 情境 S1–S11、S7b、S7c、S9j；發現 F-a、F-b2；守規則的測試 G-B5、G-B7 |
| `C:/src/Batman-329core-rB/mutB.txt`、`mutB2.txt` | 42 條改壞規則（B1–B47，有跳號），作者的 `mutate.pl` 逐條跑 |
| `C:/src/Batman-329core-rB/rB2-final.out` | 全套（作者 114 個 + 我的 172 個）實跑輸出，`[RB2]` 開頭的行 |
| `C:/src/Batman-329core-rB/mutB.out`、`mutB2.out` | 改壞規則的實跑輸出（跑的時候我的測試先移開，所以只量作者的 114 個） |

執行：`cd C:/src/Batman-329core-rB/app && flutter test --no-pub test/nodelink`。最後一次：`03:59 +281 -12: Some tests failed.`（12 個 FAIL 都是我的測試，用來證明 M1 與 m1；作者的 114 個全部通過）。

## MAJOR

### M1 認領完立刻 `loginFor`，附近有別人的節點時常常第一次就失敗；一群人一起認領時大部分人要重按好幾次

**情境**（U2-1「從零到組網」的 demo 本身）：隊員跟著講師一步一步做，大家在差不多同一時間開機、掃 QR、認領，接著按「加入網路」，隊長則按「建立網路」。流程第一次需要節點就走 `loginFor`（§4.3.9）。這時新紀錄 Y 沒有任何備忘，附近每一台別人的節點都是陌生位址。

**證據 1：單一手機，被認領的節點最先被掃到（它就在使用者手邊），其他節點閒置（S7c）**：

```
[RB2] S7c author nf=8  end=LoginEnd.ok handshakes=10: 80.0 loginFor u2×Y2 -> undecryptable | 85.0 f0 ... | 120.0 f7×Y2 -> undecryptable | 131.0 loginFor u2×Y2 -> body
[RB2] S7c author nf=10 end=LoginEnd.notFound handshakes=12: 80.0 loginFor u2×Y2 -> undecryptable | 85.0 f0×Y2 ... | 130.0 loginFor f9×Y2 -> undecryptable
```

第一次嘗試在佔用釋放後約 1 s 開始，落在 N9 的 4 s 輪詢之前，所以回「解不開」。程式照規則不記備忘、標成可以重試，但 `LoginFor.next` 先試沒試過的位址（core.dart:642，code-1 B-M4 加的），真的那台只能等每一個別人的位址都試完。附近有 10 台閒置的節點時，60 s 用完，結果是 NOT_FOUND。§4.3.9 與 T-L17 寫的是「6 s 後同一位址再試、≤ 15 s」，T-L17 會通過，只是因為它附近只有一台節點。

**證據 2：同一個房間 m 個人、每 3 s 一人認領完並立刻 `loginFor`（S11）**。兩種模擬器都跑：「author」= 作者原本的連線模型，「strict」= `simr.dart`。失敗的人再按「再試一次」（先清掉「不是 Y」），最多再按 3 次：

```
[RB2] S11 author hint=false m=7  loginFor ends=[notFound, notFound, notFound, notFound, ok, ok, ok]
[RB2] S11 author hint=false m=7  loginFor presses until ok (5 = never in 4): [2, 2, 2, 2, 1, 1, 1]
[RB2] S11 author hint=false m=10 loginFor ends=[notFound x5, ok, notFound x3, ok]
[RB2] S11 author hint=false m=10 loginFor presses until ok (5 = never in 4): [2, 2, 2, 3, 4, 1, 3, 2, 2, 1]
[RB2] S11 strict hint=false m=4  loginFor ends=[ok, ok, notFound, ok]
[RB2] S11 strict hint=false m=7  loginFor presses until ok (5 = never in 4): [3, 3, 4, 3, 3, 2, 1]
[RB2] S11 strict hint=false m=10 loginFor presses until ok (5 = never in 4): [3, 3, 3, 5, 4, 3, 2, 1, 3, 1]
```

一個人的失敗 log（strict，m=7，p0）：`12.0 loginFor Y0`；`18.8 a0×Y0 -> undecryptable`（自己的節點，N9）；`26.8 a1 noResponse`；`36.6 a2 undecryptable`；`44.6 a3 noResponse`；…；`68.4 a6 undecryptable`。自己的節點直到 60 s 用完都沒有再被試。

**原因有三個，會互相放大**：
1. 第一次嘗試落在 N9 的 4 s 內。「先試沒試過的」把那次重試排到所有陌生位址後面。
2. 每一個隊友的節點對新紀錄都是陌生位址。釋放後 30 s 內所有「解不開」都不能記，每支手機都去握每一台，節點一直有人在連，於是出現很多次 8 s 的「沒有回應」。
3. 「再試一次」會清掉 Y 的「不是 Y」，連這一輪已經學到的正確備忘也一起清掉，重試又要從頭握一遍。

code1-changes.md 寫「接受的上限：附近超過 8 台」，那是用閒置的別人節點量的。真實 demo 是隊友同時操作，3 台就會失敗，而且要按不只一次。這讓使用者在最核心的流程裡做重連（違反 U2-4），所以列 MAJOR。

**修法（兩項都在我的 worktree 驗過，作者的 114 個測試沒有退步）**：
- (a) **N9 的模糊期只算到釋放後約 10 s，模糊的重試排在最前面**：只有在「釋放後 10 s 內」回的「解不開」才當成可能是 N9，標記成優先重試，6 s 後先試它。10 s 之後回的「解不開」已經是確定的答案（節點 4 s 輪詢已過），直接記「不是 Y」。這是 `LoginFor` 裡大約 5 行的改動（`n9` 集合 + `next` 先挑它 + 判斷 `now - w < 10000`）。結果：

  ```
  S7c author/strict nf=4..10 -> 全部 ok, handshakes=4
  S11 author hint=false m=4/7/10 -> 全部第一次就 ok, handshakes 2-4
  S11 strict hint=false m=7/10 -> 仍然失敗（下一項才解）
  RB-CLAIM-* 不變；RB-CLAIM-RETRY-10/12 不變（位址在認領時換掉的情況，仍然要按一次）
  ```

  §4.3.3-4 例外 (1) 的 30 s（給一般的輪，T-L13(b) 用）可以不動；`loginFor` 只需要 4 s 輪詢再加一點餘裕。
- (b) **認領流程把它剛剛認領的位址告訴 `NodeLink`**：例如 `releaseLease(written:{Y}, claimedAddr:{Y: a})`，寫備忘的仍然只有 `NodeLink`，而且這只決定先試哪個位址、不觸發 30 s 的等待。測試裡直接設 `isY` 模擬這件事：

  ```
  S11 author/strict hint=true m=4/7/10 -> 全部第一次就 ok，每人 2 次握手
  ```

  前提 ⚠️ 未驗證：節點的位址在認領前後不變。我讀到的程式是：每次斷線後 `register()` 重新註冊廣播（bluez.go:583-600），RPA 只有在 `rpa_timeout` 時才主動換（bluez.go:776-779），所以推論是不會換，但沒有量過。PR 1 的真機場次應該量一次（認領前後各掃一次位址）。位址如果會換，就只剩 (a)。

**負向對照**：S7c 與 S11（hint=false）在 731f7e8 上 FAIL（上面的輸出），套上修法後通過。這兩個測試應該加進 T-L17 一起跑。

### M2 「提前再讀連續最多 3 輪」沒有任何測試守著

**證據**：`mutB.out`

```
== B5 T-L2(c) no 3-round cap on early re-reads: SURVIVED (00:06 +114: All tests passed!)
```

設計 §9.1 的 T-L2(c) 寫明對照是「拿掉 3 輪上限 → 握手 / 掃描次數超過 → FAIL」。現有的 `y` 測試只斷言計數會到 3，沒有斷言第 4 輪不會發生；`hh` 測的是歸零。上限沒了，一台一直「還沒輪到」的節點會讓每一輪結束 10 s 後都再掃描、再握手（§4.3.7 的掃描比例與 N4 的握手配額都以 3 輪為前提）。

**修法**：採用我的 `G-B5`（10 筆舊紀錄 + 12 個陌生位址，跑 15 分鐘；先斷言每一輪都有觸發條件、計數不會歸零，再斷言提前再讀恰好 3 次）。實跑：

```
未改：[RB2] G-B5 ... early rounds=3            -> PASS
B5 ： [RB2] G-B5 ... early rounds=5  Expected: <3> Actual: <5> -> FAIL
```

## MINOR

1. **「沒找到 → 登入被拒 → 沒找到」第二次沒找到就顯示「找不到」，蓋掉「登入被拒」**。`F-b2`（只用核心）：
   ```
   30.0 round 0 end {Y1: notFound} / 42.0 a1×Y1 -> refusedForbidden / 42.0 round 1 end {Y1: reason} / 120.0 round 2 end {Y1: notFound}
   Expected: Why.refused  Actual: Why.notFound
   ```
   §4.3.5 要「連續兩輪」，可是 `_end` 的 `Concl.reason` 沒有把 `miss` 歸零（core.dart:509-510）。修法：加一行 `s.miss = 0;`（B35）。加了之後 F-b2 通過，作者 114 個測試全過（`mutB.out` B35 SURVIVED = 不會弄壞別的規則）。
2. **偏離第 3 點（重新整理不再結束「身分不符」）的理由寫錯**。作者說「沒有測試分得出來」，其實分得出來：`F-a`：`before=Why.identity after refresh + 10 min with the node off: Kind.unreachable Why.identity miss=7`。節點關著時，按重新整理之後「身分不符」永遠不會結束，只有讀到或移除紀錄才結束。行為我接受（比較安全，第 1 輪 A-m1 / B-m8 也同意），但回填設計時要寫真正的理由與這個後果，F-a 也要進測試。
3. **沒有任何測試守著的規則**（`mutB.out`、`mutB2.out`，每一條 = 拿掉規則之後 114 個全過）：
   - B2 X30 / 第七輪 B-m6：提前再讀的輪進行中按重新整理 → 要取消、開全輪。
   - B7 已經「連不到」的節點遇到「還沒輪到」也觸發提前再讀（§4.3.2 規定不觸發）。我的 `G-B7` 可以守住：B7 套上時 `early re-reads after that=1 Expected <0>` FAIL，未改時 PASS。
   - B9 `notYetRun` 不計數（§4.3.5「還沒輪到連續兩輪以上」的句子用它）。
   - B12 一個目標得到原因（身分不符）之後，這一輪還繼續試別的位址。那樣同一輪讀到就會結束「身分不符」，違反「之後的某一輪（不是同一輪）」，這是安全規則。
   - B14、B15：`EForbidden`、錯誤碼不記「是 Y」（§4.3.3-4 兩列都寫要記）。
   - B16 已取消或不是目前嘗試的結果仍被接受。X3 的時序真的會遇到（取消首頁的一輪、立刻開節點頁的一輪，舊的藍牙結果晚到）；拿掉檢查時 `r.t[a.id]!` 可能直接丟例外。
   - B22、B23、B25 `loginFor` 的三條備忘規則：身分不符記「不是 Y」（T-S3 的「另加 loginFor 一例」寫了要斷言）、成功記「是 Y」、「是 Y」位址第一次解不開只丟掉（§4.3.3-4 例外 2 在 `loginFor` 的版本；被重播攻擊時要靠它）。
   - B27 佔用中寫入 Y 的紀錄後沒有清掉「不是 Y」（T-L11(g)）。
   - B32、B33、B34、B39（`loginFor` 同位址隔 6 s）、B47：較次要，見輸出。

   B10 與 B46（已知位址用完）是等價突變：`_conclude` 的 `!_canTry(r, k, id)` 與 `_candidates` 的 `_canTry(r, k, id) ? [k] : []` 實際走不到。前者的理由：已知位址的每一種結果，不是讓 `isY` 消失，就是讓它可以重試、或讓目標結束，所以 `k != null` 時不會遇到不能再試的情況。建議拿掉這段死碼，或加註解說明。
4. **`mutate6.out` 沒有列出全部 FAIL 的測試**，例如 `window end ignores pending attempts: killed (+100 -14)` 只列了 4 個名字，所以「每個測試都有自己的對照」從輸出上無法逐一核對。建議讓 `mutate.pl` 印出全部名字。
5. **模擬器在「剛斷線就再連」這件事上比真機寬鬆**。`sim.dart` 只要等待 ≤ 7 s 就算連得上，等於假設 msg2 在節點可連之後 1 s 到。M-1 R 量到「隔 0 s：整次 7.3–8.8 s」，已經踩在 8 s 的邊上；M-1 W 量到連上 527–3905 ms、到 msg2 1701–4930 ms。另一點：節點在嘗試開始的瞬間就變成「忙」，掃描又要連續 3 s 才回報位址，所以模擬裡兩支手機在一輪開頭幾乎不會相撞。我用 `simr.dart`（看到廣播 1.0–2.6 s、msg2 1.7–4.9 s、1.5 s 的 lag、0–4 s 的 jitter）把 S1–S10 重跑一遍，結論都沒有變（見下面的情境表）。唯一有實質差異的是 M1，而 M1 在原本的模擬器上也重現得出來。建議把 strict 參數當成第二組，`sim.dart` 兩組都跑。
6. **節點頁的紀錄被移除之後，那一頁還在最上層時，每 60 s 會開一次空的輪**（`S8`：`scans started while the removed node page was on top=1`）。目標是空的，但 `scanStarts` 會加 1，driver 會真的開掃描，吃掉系統的掃描配額（§1.3 E）。修法：`_begin` 在目標為空時不開輪；或在契約裡寫明移除後頁面一定要先關。
7. **code1-changes 說 `Res.broken` 只能在登入成功之後回報、「程式註解寫明」，但 core.dart 裡沒有這段註解**（`grep -n broken core.dart` 只有 :32、:433、:684）。這是安全契約：握手前的格式錯誤如果回報成 `broken`，會被記成「是 Y」。請補在 `Res` 的註解上。
8. **位址輪換後 `loginFor` 會先等 30 s**（`S5`：`loginFor after rotation: end=LoginEnd.ok handshakes=1 ok at 40 s`）。舊的「是 Y」還在、但那個位址已經不再出現，流程頁要顯示「正在連到節點…」40 s。建議：如果已知位址在上一輪就沒被掃到，就不要等。
9. **90 s 上限切掉的嘗試會重複握手**：`S2`：`foreign handshakes=[12, 11, 11, 11, 12, 12, 13, …] (pairs=11 each, cuts=6)`。「切掉的算沒試過」是對的，但 T-L11(i)「每一對只握一次」要改成「切掉的那次除外」，§4.3.7 的握手數也照這樣回填。
10. **`log` 沒有上限**。app 開一整天會一直累積。建議改成環狀緩衝，或交給 driver 每輪取走。
11. **短暫解鎖時看不到更新**：`S6` 第一版用「背景 15 s / 前景 30 s」的循環，一直回錯誤碼的節點那一輪要約 31 s（錯誤碼 → 隔 6 s → 再一次 11 s），每次回前景都在讀完前被下一次進背景取消，13 / 14 個循環結束時都是不新鮮。改成前景 39 s 之後就全部正常（`cycles not fresh 40 s after return=0`）。這是設計本身的代價（健康的節點也要約 14 s），不用改程式，但 §4.3.7 回填時寫一句。

## 情境走查（都有實跑；`strict=true` 是 `simr.dart`）

| # | 情境 | 結果（原始輸出） | 判定 |
|---|---|---|---|
| S1 | 冷啟動 2 / 7 / 8 / 12 台、沒有備忘、紀錄順序與掃描順序相反 | `n=2 all read at 25 s` / `n=7 80 s` / `n=8 114 s` / `n=12 436 s`；兩種模擬器 `notFound conclusions=0; 連不到 s={}` | ✅ 健康的節點從不顯示連不到。回填 §4.3.7：冷啟動時間取決於紀錄順序，作者印的 240 / 820 s 是紀錄順序最差的情況（T-L21 的 mtime 剛好倒序） |
| S2 | Y1 讀到、Y2 關機、10 筆舊紀錄、12 個回解不開的位址 | `Y2 連不到 at 691 s; Y1 max gap 150 s, not-fresh s=0` | ✅ Y1 不受影響。Y2 要 11.5 分鐘才顯示連不到，和 §4.3.5 寫的「沒有固定上限」一致 |
| S3 | 12 個不回應的裝置先被掃到 + 2 台已知的節點 | `cold both read after 145 s; worst read after round start 24 s over 7 rounds` | ✅ T-L14 的 40 s 成立 |
| S4 | 重播 Y1「目前」位址的裝置，隔一次搶一次，持續 10 分鐘（不回應 / 回解不開） | `Y1 reads during attack=6/7; 連不到 s={}; first read after the attacker left: 13–49 s` | ✅ |
| (code-1) | 重播「舊」位址 | RB-REPLAY-a/b/c 通過 | ✅ |
| S5 | 位址輪換 + 6 個陌生位址，輪換之後立刻 `loginFor` | `ok at 40 s` | ✅（慢，見 m8） |
| S6 | 每次讀都回錯誤碼，每 45 s 鎖屏一次（背景 5 s） | `view after 3 min=2'; cycles not fresh 40 s after return=0` | ✅（見 m11） |
| S7 / S7b / S7c / S11 | 認領 → 立刻 `loginFor`，附近有 0–12 台別人的節點；一群人同時認領 | 見 M1 | ❌ M1 |
| S8 | 從首頁、從節點頁移除一台 | `Y2 handshakes after removal=0; states=[Y1]` | ✅（見 m6） |
| S9 | 兩支手機一台節點，strict，看到廣播 1.0 / 1.8 / 2.6 s × msg2 1.7 / 4.9 s × 起始錯開 0–57 s（120 種） | 120 種都是 `連不到 s=[0, 0]`；起始錯開 0 s 的 6 種各有一輪「沒找到」：`noResponse=[0, 1] notFound rounds=[0, 1]` | ✅ 真的有相撞，兩輪規則吸收掉 |
| S9j | 同上，每次讀取與看到廣播加 0–4 s 隨機延遲，20 種亂數 × 60 分鐘 | `沒找到 rounds=1, consecutive pairs=0, 連不到 s=0, worst read gap=80 s` | ✅ |
| S10 | 5 / 10 支手機各有一台節點，同時啟動（strict） | `m=10 first read s=[13 … 85]; 連不到 s=[0 x10]; max gap 73 s` | ✅ |
| (author) | 錯誤碼 → 鎖屏 → 解鎖 | T-H2(f) 通過 | ✅ |

## 模擬器與真機事實（§1.2、§1.3）

- N1、N3（一次一條連線、連著就不廣播）：`sim.dart` 有做，但節點在嘗試開始的瞬間就變成「忙」，也就是假設連線是瞬間建立的（M-1 W 實際要 0.5–3.9 s）。⇒ m5，`simr.dart` 的 `lag` 補上了。
- N4（每台每分鐘 20 次握手）：沒有模擬，只有安全斷言。S11 這種很多人同時操作的情境，真機只會更差（超過配額的那次直接斷線 = 沒有回應）。
- N7（RPA 約 900 s）：provd 每次註冊廣播都把 `nextRPA` 往後推（bluez.go:597），實際由 `rpa_timeout` 才換（:776-779）。認領前後位址會不會換，⚠️ 未量（M1 修法 (b) 的前提）。
- N8 / M-1 R：見 m5。
- N9：`claimedAt + 4 s` 和設計一致。M1 正是發生在這 4 s 裡。
- M-1 W（拿錯紀錄 1.7–4.9 s）：模擬器用 5 s，比真機保守（不利於程式），可以接受。

## 擁有權與契約

- 備忘（`isY`、`notY`、`lastSeen`、`writtenAt`）與節點狀態，只有 `NodeLinkCore` 與 `LoginFor`（透過 `c.`）會寫；沒有任何一處寫節點紀錄。✅ 讀過 core.dart 全文。但這些都是公開欄位，「只有一個寫入者」仍然只靠慣例（第 1 輪 A-m5 / B-m5，作者說 PR 1 處理）。
- §4.3.9：`loginFor` 建立時不檢查是否持有佔用，只在結果回來時檢查 `c.lease`。driver 如果在沒有佔用時呼叫，會跑 60 s、然後全部丟掉。建議在建立時直接回 `precondition`。
- §5.1：第 4、5、8、10 列需要的資料（`shownWhy`、`roundsRun`、`notYetRun`、`last`、`fresh`）都有。六種結論都有測試走到過（排隊中：T-L21；還沒輪到：S2）。
- 安全，逐個角色：
  - 附近的攻擊者只能造出「沒有回應」與「解不開」（握手成功之後的結果需要金鑰）。最壞的後果是一台節點顯示連不到，直到位址輪換或使用者按重新整理（S4、RB-REPLAY）。設計已經接受。
  - 其他 app 連走節點 = 另一支手機的情況（S9）。
  - 被入侵的節點：只能對自己的紀錄回錯誤碼（顯示灰）或錯的狀態本體。如果它有 Y 的標籤金鑰，就會造成 CertRejected，屬於安全事件；結束條件見 m2、m3（B12）。
  - 寫入：一輪與 `loginFor` 都不寫任何紀錄。✅

## 和第 1 輪對照（我的發現定稿之後才讀）

第 1 輪的 MAJOR 都修了，我的情境測試也重現不出來（RB-FIX-1/2/3/3b/7、RB-CLAIM-*）。沒有被丟掉的項目，只有兩處要補：
- B-M4 的修法帶出新的 M1（「先試沒試過的」把 N9 的重試排到最後）。「接受的上限」只量了閒置的別人節點。
- A-m7 / B-m9 的註解沒有寫進去（m7）。
