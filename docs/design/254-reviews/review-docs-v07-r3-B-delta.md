# #254 docs PR 第 3 輪窄範圍複查 — 審查者 B — `git diff dba5bf9 504bfe7`

**判定:APPROVE-WITH-CHANGES** — 0 BLOCKER / 0 MAJOR / 4 MINOR(都不擋 merge;n1、n4 建議在 PR-H1 之前修)。

第 2 輪我提的 m1–m8 全部關了,我的 type≠verb 攻擊現在會被抓到。剩下的 4 個 MINOR 都在驗證器與 CDDL 的細節上:其中兩個是驗證器的已知缺口(pycddl 的限制被搬到 Python 檢查時沒有補齊),一個是會誤殺合法請求的潛在 bug,一個是分塊大小沒算到信封開銷。

**做法**:只在 WSL 操作;沒有連線節點、沒有 commit;寫入只有這份報告和 `/tmp` 的臨時檔(已刪)。

## 1. 實跑(✅)

```
verify.py vectors.json → rc=0 "189 checks: ALL PASSED"
gen.py | cmp - vectors.json → GEN_IDENTICAL
```

| 攻擊(在臨時副本上) | 結果 |
|---|---|
| 把 `request_network_join` 的信封 type 改成 `network/leave`(第 1、2 輪全過的那一招) | **rc 1**:`FAIL node rule: the network/join request is accepted` ✅ |
| 把 `request_type_mismatch` 的 type 改回 `network/join`(預期被拒的向量變成合法) | rc 1:`FAIL node rule: … under type network/leave is rejected` ✅ |
| 在 STATUS 的 `member_updating` 塞入末碼(key 5) | rc 1 ✅ |
| `{24: 1, -1: 2}` 這個 map,用 bytewise 與 length-first 兩種編碼分別丟進 `deterministic()` | **兩種都回 False** → n1 |

## 2. m1–m8 的去向

| 第 2 輪 | 結論 |
|---|---|
| m1 `status/public` | ✅ 改成未加密的 GATT `STATUS` 特徵值,CDDL `status-public` 依 state 分 open / closed;§4.1 寫明路人讀得到哪些內容。缺口見 n4 |
| m2 type≠verb 是恆真式 | ✅ 新增 `node_accepts`(以信封 type 組簽章輸入,verb 不等即拒),加上負向向量 `request_type_mismatch`;上表的翻轉實驗兩個方向都能鑑別 |
| m3 開發版 / 正式版隔離的文字 | ✅ §3.2、§3.6、§9 已改;正式版 app 在每個看得到 DAC 的地方都拒絕 `dev:` |
| m4 冪等規則 | ✅ 舊清單已刪;帶秘密回應的請求(含 `owner/add`、`bulk/open`)不得帶冪等鍵;快取記 `(type, args_hash)`,不符即 `E_FORBIDDEN`;`owner/add` 與 `bulk/open` 回應遺失時的處理都寫了。分塊的缺口見 n2 |
| m5 legacy | ✅ `device_hint` 同未認領;防呆門在 CheckMac 之後才判斷 |
| m6 bytewise 編碼 | ✅ gen 與 verify 都改用 `det_dumps`,向量位元組不變。但 `deterministic()` 沒跟著改,見 n1 |
| m7 `max_msg` | ✅ `CTRL` 加 key 4;分塊門檻與重組上限統一;§8 改為 8192。每段開銷見 n3 |
| m8 項數 | ✅ 改為 189 |

## 3. MINOR

- **n1. verify.py 的 `deterministic()` 仍以 cbor2 的 length-first 重新編碼來比對,會把合法的 RFC 8949 編碼判成不合法。**
  - 它先用 `walk` 檢查 bytewise 排序,接著又要求 `cbor2.dumps(obj, canonical=True) == raw`。
  - 實測 `{24: 1, -1: 2}`:bytewise 編碼 `a21818012002` → False;length-first 編碼 `a22002181801` → False。
  - `node_accepts` 呼叫的就是它,所以將來的 body 只要同時有負整數 key 與 ≥ 24 的 key,這條參考規則就會拒絕合法請求。這是假 FAIL,不是假 PASS;現有向量沒有這種 map。
  - 修法:最後的比對改成 `det_dumps(obj) == raw`,並加這個 map 當向量。
- **n2. 「CDDL 亦拒絕」帶冪等鍵的秘密請求,這句對分塊不成立。**
  - 規範 CDDL 的 `chunk` 對**任何** msg-type 都允許 `? 7 => bytes16`,所以一個分塊的 `claim/finish` 帶 key 7,規範 CDDL 會接受,只有 Python 的 `idem_ok` 會拒絕。
  - 修法二選一:§4.2 改寫成「以程式檢查(CDDL 無法表達)」;或在 chunk 的註解寫明「key 7 只在 msg-type ∈ 冪等清單時允許」,並在 verify 加一個分塊的負向案例。
- **n3. 分塊門檻沒有算到每一段自己的信封開銷。**
  - §5.1 寫「明文超過 `max_msg − 16` 就切」,但每個分塊本身也是一個完整信封:`0`、`1`、`2`、`6`、可能還有 `7`,外加 bstr 標頭,大約多 30–60 B。
  - 實作者如果把 body 切成剛好 `max_msg − 16` B 的片段,每段都會超過 8192 → 對方中止連線。
  - 修法:規定「每個分塊信封的編碼後明文 ≤ `max_msg − 16`」,並在 GATT / 信封向量裡加一個 8 KiB 邊界的例子。
- **n4. STATUS 的封閉 map 規則,其實沒有任何地方在檢查。**
  - 已知 pycddl 不會擋封閉 map 裡多出來的 key;而 `status_ok` 只補了 key 5(末碼)這一條。
  - 所以一個成員節點的 STATUS 只要多帶一個 key 6(例如完整的 `device_id`),`status_ok` 仍判合格——而 STATUS 正是對路人公開、不能洩漏識別的那個介面。
  - 修法:`status_ok` 加上 `set(o) <= {1, 2, 3, 4, 5}`,並加一個負向向量(成員帶 key 6)。

**關於 pycddl 限制、改由 Python 檢查(`idem_ok`、`status_ok`)是否留下缺口**:除了 n2、n4 之外沒有。前提是 §11 要明寫:**節點與 app 的實作必須以程式碼實作這兩條規則,不能只靠 CDDL 驗證器**。很多 CDDL 實作同樣不擋封閉 map 裡多出的 key,Go 與 Rust 的實作者很可能踩到同一個坑。

## 4. 結論

m1–m8 都已關閉,沒有破壞先前已成立的部分;向量可重現;type≠verb 的攻擊現在雙向都能鑑別。四個 MINOR 只需要改驗證器與改文字。
