# #254 PR-F 窄範圍複查 — 審查者 B — v18 → v19(e5f9d2e → b5e6576)

**判定:APPROVE-WITH-CHANGES** — 0 BLOCKER / 0 MAJOR / 4 MINOR。

**範圍**:只看 `git diff e5f9d2e b5e6576 -- docs/design/254-stage1-impl.md`,這次只改了文字;firmware 停在 07f20637,沒有變更。
**做法**:這次沒有連線任何節點、沒有 build、沒有 commit;用到的原始碼行號沿用第 17 / 18 輪已核對過的部分。

## 1. v18 B-N1 的結果:第 2–4 段現在分得出修好與沒修好,不會出現假 PASS

逐條對照 v18 指出的兩種失效:

| v18 的洞 | v19 寫法 | 結論 |
|---|---|---|
| 02 的 bluetoothd 重啟後,patch 900 把 02 改回 SC-only、bondable 也被打開,下一輪變成 SC 配對,在兩種 build 上都會被擋 | 每一輪都在**同一個** session 裡重做 `mgmt.bondable off`、`mgmt.sc off`,並把 `mgmt.info` 放在 `mgmt.pair` 的**緊前一行**,斷言 02 沒有 `bondable`、沒有 `secure-conn` | ✅ 已關。`mgmt.sc off` 會同時清掉 02 的 `HCI_SC_ENABLED` 與 `HCI_SC_ONLY`(`mgmt.c:6919-6922`)。session 一開始自動註冊的 agent 雖然會打開 bondable,但緊接著的斷言會擋下 |
| 失敗字串寫錯;沒連上也被當成 PASS | 三態判定:public 位址 = 外洩;`0x05` **且**曾出現 `Connected: yes` = 擋下;其他一律無效、重做 | ✅ 已關。`0x05` 來自 `smp_failure → mgmt_auth_failed`;`0x04` / `0x08` 被歸為無效 |
| 「擋下」是不是真的由 SC-only 造成 | 夾心順序:目標 → 翻轉(同一 build `mgmt.sc on`,必須外洩,否則整次作廢)→ restart(必須擋下) | ✅。前後三段只差 04 的 `HCI_SC_ONLY` 一個變數,翻轉段同時證明 02 確實要求了 ID key(`HCI_RPA_RESOLVING`)、而且這個觀察方法看得到外洩 |

restart 段:翻轉段之後,04 kernel 裡留著 02 的 IRK(非持久)。04 的 bluetoothd 重啟時會送 LOAD_IRKS 把它清掉(`mgmt.c:7124`),02 這邊也每段重啟一次。所以這一段只剩「patch 900 有沒有把 only 送回去」這一個變數 ✅。

**Q8 的前置與收尾**:p1 與 p3 兩份都改;OTA 之後先斷言 `hci0` 存在、`batman-sc` 為 mode 2 status 0,並在 autocommit 窗口內完成 commit;測試主機上做 `ah()` 用的 04 IRK 副本要列出後刪除;rollback 只用在中途放棄、正常收尾留在 PR-F build——前後已不矛盾。除了 m3,其他都齊了。

## 2. MINOR

- **m1. 第 4 段(restart)沒寫要重新開廣播。**
  - `/etc/init.d/bluetoothd restart` 會讓 bluetoothd 丟掉所有 D-Bus 註冊的廣播,`setsid` 常駐的 bluetoothctl 會不會自動重新註冊沒有保證(⚠️ 未實測)。04 不廣播,02 就連不上 → 那一輪會變成「無效」。這不會造成假 PASS,但會讓整次夾心跑不完。
  - 補充:先前的 `agent off` 已把 `auto_register_agent` 清掉(`client/main.c:1174-1175`),bluetoothd 回來之後不會再自動註冊 agent。即使註冊了,「04 每輪前斷言無 `bondable`」也會攔下。
  - 修法:第 4 段在 restart 之後先結束並重開廣播 session(`agent off` → `advertise on`),並斷言 02 掃得到新的 RPA,之後才重做整輪。配對段落也要明寫它依賴 RPA 段那個 connectable 廣播者。
- **m2. 第 5 段(SC Just Works)沒有負對照。**
  - 「`0x05` 且曾連上」對任何 SMP 失敗都成立,所以這一段無法證明擋下它的是「沒有 agent」。
  - 修法(二選一):
    - 加一段翻轉:04 的廣播 session 改成 `agent NoInputNoOutput` + `default-agent`,經 FIFO 回 `yes` → 必須外洩;做完照第 6 段重開 04。
    - 或者如實標註:D25 後半在空中只有「單向觀察」,維持 ⚠️,不寫成 ✅。
  - 第 2–4 段(legacy / SC-only,也就是 B1)不受影響。
- **m3. 02 的 p3 是新的持久寫入,需要另外取得授權。**
  - 使用者 2026-10-19 授權的是「OTA 02 + p1 加一行」。改 p3 要先掛載 p3 再寫入,屬於新的持久改動。
  - 修法:Q8 註明 p3 這一步要先問使用者,或改成「只改 p1,並寫明 02 之後落到 slot B 時 BT 異常的後果」。
- **m4. 新的 L 編號用到明文保留的號碼。**
  - BLE 那四列改成 L45、L46、L48、L49,但同一張表下方的註記寫著「L35–L37、**L45、L46、L48–L50**、L52–L58 是恢復出廠機制的列……**編號保留不重用**」,兩者互相矛盾。
  - 修法:改用沒出現過的號碼(例如 L62–L65),並同步更新 §11、§13 與 L48 的引用。

## 3. 結論

v19 已經把 v18 的 N1 修好:第 2–4 段的配對測試在修好與沒修好的 build 之間有鑑別力,判定沒有假 PASS 的路徑,而且每一段都有同一 build 的翻轉當對照。剩下四個 MINOR 都只需要改字,不必再整份審查。
