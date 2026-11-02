# #254 docs PR 第 3 輪審查 — 審查者 A — 整份 `8682f57..504bfe7`(協定 v0.7 + CDDL + 向量 + field-provisioning v2.9 + 254 同步)

**Verdict:APPROVE-WITH-CHANGES — 0 BLOCKER / 0 MAJOR / 6 MINOR**

第 2 輪的 N1–N8 都收了,收法正確:
- **N1**:`STATUS` 定成未加密的 GATT Read 特徵,CDDL `status-public` 定義欄位,§4.1 寫明它對附近的人暴露什麼;
- **N2**:參考規則 `node_accepts` 以**信封 type** 組簽章輸入。我把 join 請求的 type 改成 leave,現在會 FAIL;
- **N4 / N5**:帶秘密回應的請求不得帶冪等鍵,帶了即 `E_FORBIDDEN`;快取記 `(type, args_hash)`;舊清單已刪;
- **N6**:254 §4.1 寫明所有 owner-op 動詞都收原始信封;
- **N7**:隔離的句子改寫,正式版 app 在每個看到 `node_cert` 的地方都拒絕 `dev:`;
- **N8**:`max_msg`(`CTRL` 4)統一了分塊門檻與重組上限。

整份重看沒找到新的協定層問題。剩下 6 個 MINOR 都在向量 / 工具與 CDDL 的邊角,合併前改字或補幾行 verify 即可,不需要再審一輪。

---

## 0. 實跑結果

```
verify.py vectors.json → 189 checks: ALL PASSED
gen.py > tmp; cmp      → BYTE-IDENTICAL
竄改(每次只改一個欄位):
  request_network_join 的 type → network/leave           → rc=1(node rule)✅
  request_type_mismatch 的 type 改回 network/join          → rc=1 ✅
  join 的 owner-op verb → leave(type 仍是 join)           → rc=1,4 FAIL ✅
  status_public.bad_member_with_tail 拿掉末碼               → rc=1 ✅
  status_public.member_updating 加上末碼                    → rc=1 ✅
  status_public.unclaimed 拿掉末碼                          → rc=1 ✅
  envelope.request_reset_with_idem 拿掉 7                   → rc=1 ✅
  claim_replay.request 加上 7: idem_key                    → rc=0,189 PASS     ← R1
pycddl 探測:
  規範版 CDDL(只放寬 .cbor)可以編譯                        → True
  status-public-closed(封閉 map)擋掉多出的 key 5            → True(pycddl 對封閉 map 是正確的)
  status-public(type choice)接受 member + 末碼               → True(這才是 pycddl 的限制)  ← R3
  規範版:claim/finish 帶 idem                               → 被拒 ✅
  規範版:owner/add 的「分塊」帶 idem                         → 接受               ← R2
  RFC 8949 位元組序的 {24:0,-1:0} = a2 18 18 00 20 00 → verify.deterministic() 回 False  ← R4
```

---

## 1. 協調者指定的判斷:冪等規則與 STATUS 末碼規則改用 Python 驗,可以接受嗎

**可以接受。** 理由:
- 規範版 CDDL 本身照實寫出規則,而且 pycddl 能編譯它(我實測);
- Python 的 `idem_ok` / `status_ok` 是規則的直接翻譯,我的竄改測試證明兩者都有鑑別力。

條件:
- §11 的說明要寫對 pycddl 真正的限制,見 R3;
- 向量裡所有**請求範例**都要跑一次 `idem_ok`,不只是合成的負向案例,見 R1;
- PR-H1 用 Go / Rust 的 CDDL 驗證器時,直接用規範版、不放寬,作為第二份裁判(寫進 §11「尚未」)。

---

## 2. 發現(全部 MINOR)

### R1 冪等規則沒有套用到向量裡的請求範例

- verify 只對合成的負向案例跑 `idem_ok`。
- 把 `claim_replay.request` 加上 `7: idem_key` 後,189 項仍全過:放寬版 CDDL 把 `? 7` 搬回了 request map,而這個向量本身沒有經過 `idem_ok`。
- 修法:對 vectors 裡每一個請求(`owner_op.*`、`claim_replay.request`、`envelope.request_*`、`chunking.*`、`op_nonce.request`)都斷言 `idem_ok`。`request_reset_with_idem` 已經是刻意的負例,改名為 `bad_reset_with_idem` 並移出「信封範例」。

### R2 規範版 CDDL 的 `chunk` 一律允許 `7`

- `chunk = ( 2 => msg-type, 3 => bstr, 6 => part, ? 7 => bytes16 )` 對**任何** type 都接受 `7`。我實測規範版接受 `owner/add` 的分塊帶冪等鍵,和 §4.2「回應帶秘密的請求不得帶冪等鍵」矛盾。
- `idem_ok` 只看 `o[2]`,會擋下來,但規範 CDDL 本身是寬的。
- 修法(二選一):
  - chunk 也拆成兩個替代項:`2 => idem-msg-type` 可以帶 7,其他 type 不行;
  - 或在 CDDL 註解寫明「分塊的 `7` 也依同一份清單」,並在 verify 對 chunk 跑 `idem_ok`。

### R3 §11 對 pycddl 限制的描述不準確

- §11 寫「封閉 map 不擋多出的 key」。我實測 pycddl 對封閉 map(`status-public-closed` 加 key 5)會正確拒絕。
- 真正的問題是 **type choice**(`status-public = open / closed`):只要有一個替代項錯了,pycddl 就可能整體接受。這和 v0.6 已記錄的限制相同。
- 修法:改成這個描述。否則實作者會以為 pycddl 連封閉 map 都不可信,而 verify 其他地方(簽章物件拒絕未知 key)正依賴封閉 map。

### R4 `verify.deterministic()` 仍以 cbor2 長度優先比對

- `gen.py` / `verify.py` 已改用 RFC 8949 位元組序的 `det_dumps`。但 `deterministic()` 仍要求 `cbor2.dumps(obj, canonical=True) == raw`。
- 實測:`det_dumps({24:0, -1:0}) = a2 18 18 00 20 00`,這是合法的 RFC 8949 編碼,`deterministic()` 卻判 False。
- 參考節點規則 `node_accepts` 第一步就呼叫它,所以這個參考實作會**拒收**一部分合法請求。目前向量都還沒碰到這種 map。
- 修法:`deterministic()` 改成 `det_dumps(cbor2.loads(raw)) == raw`,並加一個 key 24 與 -1 並存的正向案例。

### R5 §5.3 的 `ssh_keys/set` 文字沒寫整行規則

- 整行比對、不得含 `\n` / `\r` 只寫在 CDDL 註解與 verify 裡;§5.3 表格仍是「每行 `ssh-ed25519 …`、≤ 256 B」。
- 修法:把「整行比對(`ssh-ed25519 <base64 ≤200> [ 可印 ASCII ≤40]`)、不得含 CR / LF」寫進 §5.3。
- 順帶一提:254 §4.1 helper 的正規式(`( [^\n]*)?`、總長 ≤ 256)比 CDDL 寬。app 照 CDDL 送出的一定是 helper 接受範圍的子集,不影響安全;建議兩邊寫成同一條。

### R6 `owner/add` 對已存在的 `owner_pub` 重送會輪替對方的金鑰

- §4.2 新增:「對同一把 `owner_pub` 重送 `owner/add` 會輪替該擁有者的 `owner_tag_key` 並回新值」。
- 這讓擁有者 B 可以替擁有者 A 換掉 `owner_tag_key`:A 的 `psk_owner` 失效,而新值交給了 B。在「擁有者彼此對等、B 本來就能 `owner/remove` A」的模型下不算新的權限。
- 但這是新的語意,應該在 §5.3 `owner/add` 列寫明,並說明 `adv_owner_key` 是否一起輪替。

---

## 3. 第 2 輪發現的去向

| 第 2 輪 | 判定 |
|---|---|
| N1 `status/public` 沒定義 | ✅ `STATUS` 特徵 + `status-public` + 暴露面說明 + 三個向量(含必須被拒的負例) |
| N2 type 與 verb | ✅ `node_accepts` + `request_type_mismatch`;竄改驗證通過 |
| N3 ssh 整行 | ✅ verify 用 `fullmatch`;§5.3 文字見 R5 |
| N4 帶秘密回應的請求與冪等鍵 | ✅ 規則 + `E_FORBIDDEN` + 合成負例;範例與分塊見 R1、R2 |
| N5 快取比對內容、舊清單 | ✅ |
| N6 254 §4.1 所有動詞 | ✅ |
| N7 隔離句 | ✅ |
| N8 上限 / 排序 / 項數 | ✅ `max_msg`、位元組序、189;`deterministic()` 見 R4 |

另外兩項確認:legacy 的防呆門「在 CheckMac 之後才判斷」(避免沒有秘密的人探測)✅;legacy 的 `device_hint` ✅。

只在 WSL 唯讀操作;除了本報告沒寫任何東西;沒有 commit。
