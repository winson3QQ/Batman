# #254 docs PR 第 2 輪審查 — 審查者 A — 協定 v0.7 + CDDL + 向量 + field-provisioning v2.9 + 254 同步(`docs/254-protocol-v07` dba5bf9,整份 `8682f57..dba5bf9`)

**Verdict:REJECT(窄)— 0 BLOCKER / 1 MAJOR / 8 MINOR**

第 1 輪我列的 D1–D3 與 m1–m8 大部分都收了,收法在設計上是對的:
- verb 以信封 `type` 組簽章輸入;
- helper 收原始 body 嚴格解碼;
- legacy 定為 state 3 / NX / reason 10;
- `update/*`、`bulk/*` 改為必帶 owner-op;
- 開發版 TOFU 的前提加上負向向量;
- 冪等不快取秘密;
- §8 補了上限。

剩下一個 MAJOR:這輪**新加的 `status/public` 只有名字,沒有線上定義**。協定把它列在「交握完成前」也能用,但協定裡的所有訊息都走 Noise;CDDL 也不收它。§5.4 的 app 恢復流程卻要靠它判斷「節點到底有沒有提交認領」。

另外,我的竄改測試發現兩條這輪的修法**在 verify 裡沒有真正被執行**(「以 type 簽」與「秘密回應沒有冪等鍵」),還有 CDDL 的 `.regexp` 在驗證工具裡是子字串比對。都是 MINOR,但要補,否則向量證明不了這輪改的東西。

---

## 0. 實跑結果

```
verify.py vectors.json → 172 checks: ALL PASSED
gen.py > tmp; cmp      → BYTE-IDENTICAL
竄改(每次只改一個欄位):
  claim_replay.owner_op_input         → rc=1(第 1 輪的 m7 已修 ✅)
  claim_replay.owner_op_sig           → rc=1 ✅
  forged_dev_cert_der 換成真憑證       → rc=1 ✅
  legacy info state 3 → 1             → rc=1 ✅
  legacy reason 10 → 11               → rc=1 ✅
  claim/replay 回應 root 密碼縮短      → rc=1 ✅
  network/join 請求的信封 type 改成 network/leave(verb 仍是 join)→ rc=0,172 PASS   ← N2
  claim/replay 請求加上 7: idem_key   → rc=0,172 PASS                               ← N4
pycddl 探測:
  status/public 請求 → 被拒(msg-type 沒有它)                                     ← N1
  bulk-open-resp 接受整數 2 → False(第 1 輪的 m1 已修 ✅)
  claim/finish 帶 idem_key → 接受                                                  ← N4
  ssh-ed25519-line 接受 "ssh-ed25519 AAAA\nssh-rsa X" 與 "xssh-ed25519 AAAA"        ← N3
```

---

## 1. 指定檢查項

| 項目 | 判定 | 說明 |
|---|---|---|
| §4.2 v0.7 冪等規則 | ⚠️ 方向對,有缺口 | 見 N4、N5 |
| §5.7 verb 以 type 簽 | ✅ 規格正確 | 向量沒有真的驗,見 N2 |
| §5.7 原始 body 驗證 | ✅ 規格正確;254 §4.1 只同步了 `net.apply` 那一列 | 見 N6 |
| legacy(state 3、NX、reason 10) | ✅ | 向量有,竄改會被抓到 |
| §9 階段 1 用正式 prologue / 標籤,隔離靠憑證 | ✅ 決定合理(階段 1 沒有正式機) | §3.2、§9 還留著「永遠無法互通」的舊句子,見 N7 |
| 開發版 TOFU 前提 | ✅ | MUST + 負向向量;換掉偽造憑證會 FAIL |
| §8 上限 | ✅ 數值對齊 v19 | 8 KiB 與 §5.1 的分塊門檻 65519 B 互相矛盾,見 N8 |
| 舊文字是否還矛盾 | ⚠️ | §4.2 舊清單、§3.2 / §9 互通的說法、§11 項數、CDDL idem 註解,見 N5、N7、N8 |

---

## 2. 發現

### N1(MAJOR)`status/public` 沒有線上定義

- **協定這輪的寫法**:§5.3 加了一列 `status/public`,角色是「全部(含未交握完成前的匿名)」;§3.5 匿名角色也列了它;§5.4 的 app 義務寫「若節點其實沒有提交(`status/public` / `info` 仍是未認領),app 改走一般的 NX 認領」。
- **問題**:
  1. 協定的所有訊息都是 Noise 傳輸訊息(§2、§5.1),「交握完成前」根本沒有通道可以送它。
  2. 已認領的節點拒絕匿名 NX(§3.1)。沒有 PSK 的人,包括判斷「我的認領有沒有成功」的 app,在**協定內**就讀不到它。
  3. CDDL 的 `msg-type` / `whole-request` 沒有它,pycddl 實測會拒收。
  4. 它在 v19 原本指的是**未加密**、可直接讀的狀態(GATT 特徵或 scan response)。內容有格式版本、能力位元、`updating`、legacy / 未認領時的 `device_id` 末 4 字元。
- **後果**:§5.4 恢復流程的關鍵判斷依據沒有格式;節點與 app 會各自發明。這東西在未認證時就讀得到,本身也是新的指紋面。
- **修法**:
  - 定成 GATT 的一個**不加密 Read 特徵**(或併入 `CTRL`);
  - CDDL 寫 `status-public = {1: proto-ver, 2: caps-bits, 3: bool updating, ? 4: tstr .size 4}`(末 4 碼只在 state ∈ {0, 3});
  - §3.5 與 §5.3 把它從「訊息」表移到 §4.1 GATT;
  - §8 寫明它在任何狀態都可讀,以及因此暴露了哪些資訊(誠實界線);
  - 補向量。

### N2(MINOR)「以信封 type 組簽章輸入」沒有被向量真正驗到

- verify 新加的檢查只是自己組一個 `network/leave` 的輸入、確認簽章不過。它沒有**從請求信封讀 `type`** 再組輸入。
- 所以把 `request_network_join` 的信封 type 改成 `network/leave`(owner-op 的 verb 仍是 join),172 項仍全過。
- 修法:verify 的 owner-op 檢查一律用 `request[2]`(type)組 `op_input`,並要求 `op[1] == request[2]`;加一個 type ≠ verb 的請求向量,必須 FAIL。

### N3(MINOR)`ssh-ed25519-line` 的 `.regexp` 在 pycddl 是子字串比對

- RFC 8610 的 `.regexp` 是 XSD 正規式(隱含整串比對)。但 pycddl 實測接受 `"ssh-ed25519 AAAA\nssh-rsa X"` 與 `"xssh-ed25519 AAAA"`。
- 也就是說,向量宣稱的「格式」檢查,實際上只是「含有 `ssh-ed25519 ` 這個子字串」。
- 不同語言的 CDDL / regex 實作是否錨定行首行尾也不一致。若 app 或節點拿 CDDL 當唯一檢查,一行裡夾換行就能塞進第二把 ssh-rsa 金鑰,同時繞過「≤ 8 行、只收 ed25519」。v19 helper 的 `^…$` + 單行檢查擋得住,所以今天不是漏洞。
- 修法:
  - §5.3 文字寫明「整行比對、不得含 `\n` / `\r`」;
  - verify 改用 `re.fullmatch` 另外驗;
  - 加兩個必須被拒的負向案例(含換行、前綴垃圾)。

### N4(MINOR)「帶秘密的回應沒有冪等鍵」只寫在文字裡

- §4.2 規定 `claim/finish`、`claim/replay`、`root_password/reset` 沒有冪等鍵。但:
  - CDDL 對任何請求都接受 `7`(實測 `claim/finish` 帶 idem 被接受);
  - verify 對加了 `7` 的 `claim/replay` 照樣 172 PASS;
  - 文字沒說節點收到這些請求帶 `7` 時怎麼辦。
- CDDL `request` 的註解仍寫「REQUIRED on state-changing requests」:`claim/finish` 會改變狀態,現在卻**不准**帶。
- 修法:
  - 文字寫「這三種請求帶 `7` 時,節點忽略、永不快取」(或回 `E_FORBIDDEN`);
  - 改 CDDL 註解;
  - verify 加一條「secret-bearing 請求帶 idem 時,向量裡不得出現」的檢查。

### N5(MINOR)冪等規則的兩個缺口;§4.2 舊清單還在

- **快取命中時沒比對內容**:命中就直接回上次結果,但沒比對這次請求的 `type` 與 `args_hash` 是否和快取的一致。app 若重用冪等鍵發送**不同**請求,會靜默拿到別的結果。修法:快取存 `(type, args_hash)`,不一致 → `E_FORBIDDEN`。
- **原則與清單衝突**:規則說「回應帶秘密的請求一律不快取」,但 `owner/add`(回新擁有者的 `owner_tag_key`)與 `bulk/open`(回一次性 PSK)都帶 owner-op,依規則**有**冪等鍵、會被快取。二選一:
  - 原則改成「秘密回應只回給同一位擁有者」;
  - 或把這兩個也列入不快取。
- **舊清單沒刪**:§4.2 的 v0.7 註記寫「取代下文舊清單」,但舊清單(含 `claim/finish`、`reset`)原樣留在下一段。應該刪掉或劃線。

### N6(MINOR)254 §4.1 只有 `net.apply` 改成「收原始 body」

- `ssh_keys.set(list, owner_op)`、`root_password.reset(owner_op)`、`diag.bundle(owner_op)`、`claim.replay(h, client_resp, owner_pub, owner_op)` 的簽名仍是 provd 拆好的欄位。
- 協定 §5.7 的原始 body 規則適用所有帶 owner-op 的請求。建議在 §4.1 表前加一句「所有帶 owner-op 的 helper 動詞都收原始請求 body,欄位由 helper 自己解」,並把動詞簽名改掉。

### N7(MINOR)「開發與正式永遠無法互通」的舊句子還在

- §3.2 第 52 行「開發版用 `batman-prov-dev/1` … 與正式版的交握永遠無法互通」、§9 末段「兩邊永遠無法互通」,都和 §9 新的決定(階段 1 的 file 後端用**正式** prologue 與標籤,隔離只靠 app 驗憑證)矛盾。
- 修法:
  - 改成「`-dev` 保留給之後的 608B 開發機;階段 1 的隔離靠 `dev:` 憑證,協定層可以互通」;
  - 並寫明正式版 app 在**每個**看到 `node_cert` 的地方都拒絕 `dev:`:交握第 2 則、`join-request`(§7.6)、`peers/challenge` 的目標。

### N8(MINOR)上限與數字的殘留

- **8 KiB 與分塊門檻矛盾**:§8「單則 Noise 訊息(階段 1 BLE)8 KiB,超過走 §5.1 分塊」,但 §5.1 的分塊門檻寫死 65519 B。應改成「超過當下上限(BLE 階段 1 為 8 KiB − 16)」。
- **8 KiB 由誰回報不清**:§8 說「經 `CTRL` `max_frame` / `info` 回報」,但 `max_frame` 是 GATT 框架上限(§4.1),不是訊息上限。CDDL `ctrl` 加一個 `4: max_msg`。
- **§11 項數過時**:§11 仍寫「共 156 項」(現在是 172),標頭 Status 也是 156。
- **向量工具的排序**:§11 已誠實寫明 `gen.py` 用 cbor2 長度優先、`verify.py` 依位元組序。但 `verify.py` 的 `args_hash` 仍用 `cbor2.dumps(canonical=True)`(長度優先)。若之後出現兩種排序不同的 body,verify 算出的 `args_hash` 會和 Go 節點不同。建議 verify 自己寫位元組序編碼。

---

## 3. 第 1 輪發現的去向

| 第 1 輪 | 收法 | 判定 |
|---|---|---|
| D1 `args_hash` 兩種定義 / helper 收欄位 | §5.7 原始 body;254 `net.apply` 列 | ✅(其他動詞見 N6) |
| D2 legacy | state 3、NX、reason 10、向量 | ✅ |
| D3 `update/*`、`bulk/*` | 必帶 owner-op;CDDL 必填 31;負向向量 | ✅ |
| m1 CDDL 孤兒行 | 刪除;pycddl 實測 `bulk-open-resp` 不再接受 2 | ✅ |
| m2 冪等清單 | v0.7 規則 | ✅(缺口見 N4、N5) |
| m3 `claim/begin` 在 replay 角色的 `owner_pub` | 必須等於已存的那把 | ✅ |
| m4 開發版 TOFU | MUST + 負向向量 | ✅ |
| m5 上限 / `status/public` | §8 補上 | ✅;`status/public` 沒定義(N1) |
| m6 沒網路時的 `network/update` | `E_STALE_VERSION` | ✅ |
| m7 向量 | `owner_op_input` / `owner_op_sig` 已檢查 | ✅;排序問題見 N8 |
| m8 field-provisioning 殘留 | §6.1 步驟 4、§6.1 搶先認領、§6.8、B5 | ✅ |

## 4. 協定層安全(整份重看)

這輪的修法沒有引入新的可濫用路徑:
- **以 type 簽**:擋掉「把擁有者簽好的 join 改成 leave 送出」;
- **原始 body**:擋掉 provd 拆換欄位;
- **冪等以擁有者為鍵、先查快取再驗**:命中時不執行任何新操作,所以不能拿來繞過 owner-op;
- **legacy 走 NX**:只能到認領為止,認領照樣需要 QR 秘密與防呆門。

唯一新增的暴露面是未認證可讀的 `status/public`(N1),要在定義時一起寫清楚它暴露什麼。

只在 WSL 唯讀操作;除了本報告沒寫任何東西;沒有 commit。
