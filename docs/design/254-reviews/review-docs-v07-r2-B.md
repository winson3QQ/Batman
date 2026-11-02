# #254 docs PR 第 2 輪審查 — 審查者 B — 整份變更(8682f57 → dba5bf9)

**判定:APPROVE-WITH-CHANGES** — 0 BLOCKER / 0 MAJOR / 8 MINOR。

第 1 輪我提的 M1–M5 在**規格文字**上都收了。下面這些新加的東西我逐一攻擊過,沒有找到能造成授權繞過或秘密外洩的路徑:
- 冪等規則
- 原始 body 驗證
- legacy 認領
- 階段 1 用正式 prologue / 標籤
- §8 的新上限

剩下的 MINOR 有三類:
- **向量的鑑別力有一處誇大**(m2:type ≠ verb 的檢查是恆真式,我的攻擊仍然全過);
- **新增的 `status/public` 沒有線上定義**(m1,建議在 PR-P2 之前補);
- **幾處舊文字與新規則並存**。

範圍與做法:
- 讀 `git diff 8682f57 dba5bf9`,並逐項對照 `git diff baf1a21 dba5bf9`;
- 只在 WSL 操作:跑 verify / gen、做竄改實驗;
- 沒有連節點、沒有 commit;寫入只有這份報告和 `/tmp` 的臨時檔(已刪)。

---

## 1. 實跑(✅)

```
verify.py vectors.json → rc=0 "172 checks: ALL PASSED"
gen.py | cmp - vectors.json → GEN_IDENTICAL
```

| 攻擊 / 竄改(在臨時副本上做) | 結果 |
|---|---|
| 把 `dev_cert_der` 換成 `forged_dev_cert_der` | FAIL ×3(dac_pub、sn 公式、TOFU 前提)✅ |
| 把 `forged_dev_cert_der` 換成真的那張 | FAIL(偽造檢查變得不成立)✅ |
| `claim_replay.response_envelope` 的密碼改成 23 字元 | FAIL ✅ |
| `legacy.response_info_legacy` 的 state 改成 4 | FAIL ✅ |
| **`owner_op.request_network_join` 的信封 `type` 改成 `network/leave`,verb 不動** | **rc 0,172 項全過** → m2 |

## 2. 第 1 輪 M1–M5 的去向

| 第 1 輪 | 結論 |
|---|---|
| M1 verb ≠ type | **規格已收**:§5.7「以信封的 `type` 組簽章輸入,不等即 `E_FORBIDDEN`」。向量那一項是恆真式,見 m2 |
| M2 開發版 TOFU | **已收**:§3.3 MUST 前提 + 偽造憑證向量;254 §4.2 已同步 ✅ |
| M3 階段 1 的 prologue / 標籤 | **已決定**:正式版,隔離靠 `dev:` 憑證,正式版 app 在第 2 則訊息就拒絕、早於任何秘密。但 §3.2、§3.6 還留著舊句子,見 m3 |
| M4 冪等快取 | **已收**:只用於帶 owner-op 的請求與 `network/update`;以 (owner_key_id 或轉送者 session, idem) 為鍵;帶秘密的回應不快取。殘留問題見 m4 |
| M5 `args_hash` 兩種定義 | **已收**:§5.7 改為原始 body、嚴格解碼、只依解碼結果執行;254 `net.apply` 列已同步 ✅ |

## 3. 從實際使用再走一遍(只列結論有變的)

- **認領回應遺失**:現在要求 app 持久化 K 或重掃 QR;節點其實沒提交時改走 NX;重取 session 的 `claim/begin` 必須是已存的那把公鑰 ✅。但退回判斷依賴的 `status/public` 還沒有定義(m1)。廣播是否帶 `device_id` 末碼本身也能判斷,所以有替代路徑。
- **legacy 節點**:state 3,走 NX,另需防呆門,不符回 reason 10 ✅。殘留:prologue 的 `device_hint`、防呆門與 CheckMac 的先後順序(m5)。
- **冪等快取**:我試了「同一位擁有者、同一個 idem、不同的 type 或 body」——命中快取會回上一次的結果,但**不會執行新的請求**,所以不是授權繞過。只是語意不清(m4)。
- **原始 body**:在 network-join 這類 body 裡,巢狀的 COSE 物件都包在 bstr 中,重新編碼只碰最外層的小整數 key,length-first 與 bytewise 兩種排序結果相同。gen 用的是 length-first,和規格 §1 的 RFC 8949 bytewise 不同;目前不衝突,但規格要寫死(m6)。
- **§8 上限**:`claim/replay` 的全域失敗限速只有持有擁有者加密私鑰的人才碰得到,不構成 DoS ✅。`nonce_helper` 每個 session 最多 4 個 ✅。8 KiB 上限與分塊門檻互相衝突,見 m7。

## 4. MINOR

- **m1. `status/public` 沒有線上定義。**
  - 它被放進 §5.3 的訊息目錄(那是加密信封裡的訊息),角色卻寫「含未交握完成前的匿名」——交握完成前不可能送信封訊息;
  - CDDL 的 `msg-type` / `whole-request` 都沒有它(grep 沒有結果);
  - stage-1 §4.8 的「未交握只 `status/public`」看起來是指 GATT 上不加密的可讀特徵值。
  
  修法:定義成 GATT 可讀特徵值(和 `CTRL` 一樣不加密),在 CDDL 補上格式,並寫明會對路人公開 `updating` 與 `device_id` 末碼(後者本來就在廣播裡)。§5.4 的退回判斷也要指向它。建議在 PR-P2 之前補。
- **m2. 「type ≠ verb 被拒」的向量是恆真式,§11 的說法誇大。**
  - 新的檢查只驗「以 `network/leave` 組的輸入,驗不過 join 的簽章」,這和既有的「換 verb 驗不過」是同一件事;
  - 它沒有一個「節點接受函式」吃信封、依 type 判斷;
  - 實測:信封 type 改成 `network/leave` 的請求,verify 仍然 172 項全過。
  
  修法:在 verify.py 寫一個參考用的 `node_accepts(envelope)`(依信封 type 組簽章輸入),加上負向向量 `owner_op.request_type_mismatch`,預期 `E_FORBIDDEN`;§11 的文字改得準確。
- **m3. 「開發版」一詞有兩個意思,舊句子還在。**
  - §3.2 仍寫「開發版用 `batman-prov-dev/1`,與正式版的交握永遠無法互通」;§3.6 仍寫「開發版的標籤一律加 `-dev`」;
  - 但 §9 現在說階段 1 的 file 後端(§3.3 也叫它「開發版」)用正式 prologue 與標籤;
  - §9 結尾那句「兩邊永遠無法互通」也只對以開發根簽發的 608B 開發機成立。
  
  修法:命名區分,例如「file 後端(自簽 `dev:`)」與「開發根機台」,並修改 §3.2、§3.6、§9 的那三句。
- **m4. §4.2 的冪等規則有殘留與缺口。**
  - 寫了「取代下文舊清單」,但舊的那段(含 `claim/finish`、`reset`、「跨 session 有效」)原封不動留著。正式文字裡互相矛盾的條文應該直接刪掉;
  - 快取項目要記 `(type, args_hash)`,命中但不同時回 `E_BUSY` 或錯誤,不要回別的請求的結果;
  - `owner/add` 的回應(新擁有者的 `owner_tag_key`)會進快取,只回給同一位擁有者,可以接受,但要寫明。
- **m5. legacy 的兩個細節沒寫。**
  - §3.2 的 `device_hint` 只定義了「未認領 / 已認領」,legacy 用哪一種沒寫(建議同未認領,用 `device_id`),否則交握對不上;
  - 防呆門(reason 10)必須在 CheckMac **通過之後**才判斷。否則任何沒有 K 的路人都能探出「這台沒有 SSH key」。
- **m6. deterministic 編碼要寫死成 RFC 8949 §4.2.1 bytewise。** §11 已承認 gen.py 用的是 cbor2 canonical(length-first),而 Go 的 fxamacker core deterministic 是 bytewise,app 的 Rust 庫也要選同一種。§5.7 的「重新編碼」應明寫是 bytewise。之後若有 map 同時帶負整數 key 和 ≥ 24 的 key,兩種排序就會不同,`args_hash` 會對不上。
- **m7. 8 KiB 上限和分塊門檻互相衝突。**
  - §8 新增「階段 1 BLE 單則 Noise 訊息 8 KiB,超過走 §5.1 分塊」;
  - 但 §5.1 只在超過 65519 B 時才分塊,§4.1 的重組上限也是 65535。
  
  修法:分塊門檻改為「`max_frame`(`CTRL` / `info` 回報的值)− 16」,§4.1 的重組上限也跟著改。
- **m8. §11 的數字過時。** 仍寫「共 **156 項**」,實際是 172 項。

## 5. 結論

這次變更已經忠實寫回 stage-1 v19。第 1 輪的五個 MAJOR 在規格層面都關了,向量可重現,大部分竄改都抓得到。8 個 MINOR 只需要改文字或補向量。其中 m1(`status/public` 的定義)與 m2(type ≠ verb 的參考接受函式與負向向量)建議在 PR-P2 實作之前完成。
