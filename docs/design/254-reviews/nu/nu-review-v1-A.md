# 審查 A(正確性 / 介面 / 生命週期):254-net-update-members.md v1 DRAFT

審查者 A,2026-11-10。讀過整份設計;對照 Batman-p3 `feat/254-p3` @ e5c89a1(工作樹乾淨,只多了這份未追蹤的設計檔)、219-protocol.md / .cddl、provclient、harness 單元、Batman-app。全程唯讀;唯一跑的程式是把 `feed/batman-prov/src` 複製到 WSL `/tmp/nurA` 後跑的 PoC 測試(repo 本身沒動)。

結論先講:**REJECT(窄)**。1 BLOCKER、3 MAJOR、10 MINOR。BLOCKER 只要改一行,其餘大多是文件與契約要寫清楚。

---

## BLOCKER

### B1. 最後一步的 net_secrets 沒有綁到這個版本:轉送者把舊版的秘密配上新版的 net_config,節點照收(§5 寫的「換不掉任何一步」不成立)
- **情境**(就是這份設計要支援的「移除成員 + 換密碼」):網主把網路從 v 升到 v+1(SAE 換新)。一台落後的節點還停在 v。任何能開 member session 的人——包括**被移除的那位成員**的手機,因為節點還在 v,v 的 `psk_member` 還有效——拿到公開的 v+1 `net_config` / `member_list`,再配上這台節點**第 v 版**的 `net_secrets`(它在 v 的時候本來就收過,而且簽它的 admins 還是同一組)送出 update。節點回 0,`info` 回報 net_version = v+1,app 會當它已經換好了;實際上節點用的還是舊 SAE,而舊 SAE 正是被移除的人知道的那一把。
- **證據**:
  - `parseNet`(`node/node.go:963-1021`)完全不比對 secrets payload 的 key 1(net_id)/ key 2(net_version)與 net_config 是否相同;`decryptSecrets`(`node/wtxn.go:126-152`)只比 target_dac_hash,KDF 的 `other` 直接取 secrets **自己**的 nid‖ver(`wtxn.go:140`),所以舊物件照樣解得開。
  - PoC(在 `/tmp/nurA` 的複本,repo 沒動):先 join v1,接著送 `applyUpdate([]any{v2.cfg}, v1.secrets)`(v2 由 v1 的 admin 簽,SAE 是 "sae-v2-new"):
    ```
    === RUN   TestPoCStaleSecrets
        zz_poc_test.go:9: code=0 wl=sae-v1-pass/m2/36 version=2
    --- PASS: TestPoCStaleSecrets (0.18s)
    ```
    → 回 0,紀錄停在 version 2,無線電上的卻是 **v1 的 SAE**。同樣的路徑也能塞**別的網路**(同一組 admins、net_id 不同)的 secrets。
  - 設計 §5 寫「成員 session / 被攻陷的 provd ……換不掉任何一步(都要 admins 簽)」;§2.2 最後一步寫「secrets 以 adminsOfPrev 驗(不變)、parseNet 不變」。也就是這個洞會被原封不動帶進移除成員的流程。
- **修法**(一行,算必要修改,不是多加的機制):在 `parseNet` 裡,`openSecrets` 驗過簽章之後,要求 secrets payload 的 key 1 == `p.netID`、key 2 == `p.version`,不符就回 `E_BAD_OBJECT "net_secrets"`。join 也走 `parseNet`,所以 join 一起受到保護(app S1 送的 secrets 版本本來就是 1,`gen.py:339` 的向量 nid/ver 也和 netcfg 相同,不會弄壞 S1–S3)。§5 的行為者分析要補這一條,§6 要加 U11「舊版 / 別網的 secrets 配新 net_config → 拒絕,什麼都沒寫」,外加對應的 mutant(拿掉這個比對 → U11 失敗)。今天這個 PoC 回 0,正好當作負向對照。

---

## MAJOR

### M1. 生命週期「回應遺失 → 冪等鍵 key 7 快取(219 §4.2)/ 既有」是錯的:節點根本沒有冪等快取
- **證據**:`provd/session.go:617-622` 只要帶 idem key(key 7),一律回 `E_UNSUPPORTED{1:"idem"}`(secret 類型則回 `E_FORBIDDEN`);node 與 provd 內找不到任何快取(`grep -rn idem provd node` 只有解析與轉送)。`ops()`(`session.go:589-611`)在 helper 逾時時回 `E_BUSY "outcome unknown — re-read info"`。
- **實際行為**:update 已經 commit 但回應掉了,app 重送同一串鏈時,節點已經在 v+k,回 `E_STALE_VERSION "chain not contiguous"`(`node.go:1101-1103`)。這是 app 會直接依賴的契約。
- **修法**:把那一列改成實際行為。§3 的契約加一句:`E_STALE_VERSION` / `E_BUSY outcome unknown` 之後,app 讀 `info` key 9 / 10 / 11;net_version 已經等於目標(而且 key 11 為 false)就當成功;否則從 key 9 那一版重新組鏈。「既有」這個證明要拿掉,或者換成一個真的測試(例如:套用後重送 → `E_STALE_VERSION`,紀錄不變)。

### M2. 每一步都帶 member_list 之後,大小上限變成「落後節點能補幾版」的實際上限;設計沒有算,也沒有說超過時怎麼辦
- **證據**:真正卡住的是 provd 分塊後的重組上限 `MaxChunks = 8`、`MaxReassembled = 65400`(`provd/session.go:92-97, 531, 548`),BLE 單則訊息 8192(`frame.go:15`)。F9 只引了 65536。一份成員約 290 B(dac hash 32 + 三把 65 B 公鑰 + 名稱 + 選填 lora 32 + CBOR 開銷);removed / used / revoked 清單只會增加,每筆 32 / 16 B;net_config 300–560 B(最多 4 位 admin)。估算:10 位成員每一步約 3.8 KB,大約 17 版就撐不下;20 位成員大約 10 版。今天鏈裡只有 net_config,大約能補 115 版。
- **現場情境**:一台節點關機幾個星期(維修、放倉庫),這段期間有幾次移除成員、改頻道或名稱,每一次都是一個新版本 → 節點**永遠收不到** update(請求太大,session 被關),只能由擁有者 leave 再 join。而且鏈沒辦法拆成幾次送:秘密只能放在最後一步,app 手上只有最新那一版的 secrets(§7.5)。
- **修法**(不加機制):F9 改成算實際的上限(65400 B 對應「步數 × (cfg + members)」),§3 的契約寫清楚超過時的行為(provd 會關掉 session,還是回錯誤碼?要寫是哪一個),並把「太大 → app 改走 leave + join」列進 app 要處理的事 / #254 checklist。§6 加一個接近上限的單元測試(剛好在上限內的鏈 → 0)。

### M3. §2.3 的「已存 members 的 OBJECT_HASH」沒寫清楚不重驗簽章;這正是 r5 B MAJOR-3(換網主之後每一次 update 都失敗)那個 bug 的翻版
- **證據**:`node.go:1083-1086` 的註解寫明,已存的 net_config **不**重驗,因為換網主之後它的簽章者已經不在 `rec.Admins` 裡。§2.2-2 的國碼也寫了「同 :1084 的作法,不重驗簽章」,§2.3 卻沒有。照字面實作的人很可能用 `VerifySign1(rec.Members, …, rec.Admins)`,結果換網主之後的第一次 update 就永遠失敗。另外,已存的 members 壞掉(解不開)時要怎麼處理也沒寫:fail-closed 就等於這台節點再也收不到 update,只能 leave + join。
- **修法**:§2.3 明文寫「`cose.Sign1Payload(stored, CTMembers, LabelMembers)` 取 OBJECT_HASH,不重驗」,壞掉的行為也要寫(建議跟 `stored net_config` 一樣回 `E_BAD_OBJECT "stored member_list"`,並說明恢復方式是 leave + join)。§6 加 U12:換網主(v2 交給新 admins)之後再 update v3,members 走嚴格比對 → 0(以 `TestHandoverStoredObjectsNotReverified` 為底),外加「拿掉 Sign1Payload、改成 Verify」的 mutant。

---

## MINOR

1. **事實的行號有幾處偏差**:F1 說 `:1092` 驗簽 → 實際是 `:1093`;`:1098` 版本與 prev 檢查 → `:1101`;`:1105` secrets → `:1107-1108`;F1 / §2.2 的 `:1084` Sign1Payload → `:1086`。F4 漏了 `node/wtxn_test.go:448,455` 與 `node/wtxn_v8_test.go:24`(都呼叫 `applyUpdate`,要一起改)。§3 的表寫「p5 `prov.meta` key 10」:key 10 在 `prov.cbor` 裡,`prov.meta` 是一行文字(`provstore.go:10`)。
2. **寬鬆檢查的範圍比使用者的決定大**:使用者說的是「wsl.24 入網的節點」;設計是 join 不存 members,所以**每一台**節點的第一次 update 都走寬鬆檢查,永遠如此。§2.3 的安全論證我驗過,成立(有 admins 簽、綁 net_id 與版本),但這是偏離使用者決定的地方,要放進 §7 讓使用者拍板。
3. **降級 → 舊形狀 update → 再升級,會留下過期的 Members**:wsl.24 的 `applyNet` 做 `next := *rec`,會把舊的 Members 原樣帶過去(`node.go:1145`)。bench 上的 A/B rollback 加上舊 harness(舊形狀)就會發生;再升回 wsl.25 時嚴格比對對到過期清單,每一次 update 都 `E_BAD_OBJECT`。現場沒有人送舊形狀,所以風險很低。便宜的修法:嚴格比對只在「已存 members 的 key 2 == `rec.Net.Version`」時做,否則當成沒存過。至少要把這條路寫進 §4 的降級列。
4. **錯誤碼沒定義清楚**:members 的 prev_hash 不符回 `E_BAD_OBJECT`,net_config 的 prev 不符卻回 `E_STALE_VERSION`,app 的反應不一樣,要寫明並給理由。「最後一步缺 secrets」實際會是 `E_BAD_OBJECT "net_secrets"`(`cbor.Encode(nil)` → openSecrets 失敗),設計只寫「拒絕」。
5. **國碼比對的語意**:要寫明 key 5 必須是 tstr、逐位元組相等;已存的設定沒有 key 5(Go 測試的 `mkNet` 就沒有,`wtxn_test.go:77-80`)時算不符還是放過?現有測試靠的是 nil == nil 會過,要明文規定。
6. **record 超過 MaxRecord 時,是在無線電已經改了之後才失敗**:`provstore.Encode` 超過 65536 時回錯(`provstore.go:104`),而這發生在 `commitTxn` 裡、setkey 之後 → 走 Finish 退回。§3 說「檢查都在 applyNet 之前,什麼都不寫」,在這個情況不成立。實際上不太可能碰到(請求本身上限 65400),但 §3 要嘛加一個 Encode 大小的預檢,要嘛把例外寫出來。
7. **硬體負向對照的說法不精確**:在 wsl.24 上,新形狀在 setkey 之前就被拒,所以 `prov-netupdate-254` 的 arm yield 會走 `inv`(`prov-netupdate-254.sh:57`)→ UNIT INVALID(`prov-254.sh:523-525`),不是 FAIL。txn-3 臂則因為停點沒觸發而失敗。§6 要逐個單元寫出 wsl.24 上預期的結果(PASS / FAIL / INVALID)。
8. **嚴格路徑沒有上機測試**:每個硬體單元都先跑 `pr_member`(重新 join → Members = nil),所以真機只會走到寬鬆檢查。`provclient --update` 也沒有輸入 / 輸出前一版 member_list 的方式(不像 net_config 有 `NETCFG` 那一行)。CJ2 被錯誤接受時,P 變成第二次 update,會因為 members 不符而 FAIL,歸因會混亂。修法:provclient 輸出 `MEMBERS <hex>`,並接受前一版 members 當參數;§6 標明嚴格路徑只有 Go 單元覆蓋(⚠️),或在 netupdate 單元加一次連續第二次 update。
9. **mutation 清單缺項**:要加「第二步起的 prev = 上一步 members」、B1 的 secrets 綁定、M3 的不重驗。§2.2-3 的「key 4–7 是陣列」也要一個 mutant 或一個 U 項目。
10. **app 偵測不到節點太舊**:wsl.24 收到新形狀時回 `E_BAD_OBJECT "chain link"`(`VerifySign1` 收到的是 map),跟「資料壞了」分不出來。§4 的降級列說「app 提示先升級」,但沒說 app 憑什麼判斷。最少的做法:契約寫明 app 依 `info` key 4 fw_version 判斷(不另加 capability);#254 checklist 加一行。另外,分叉(§7.5 雜湊較小者勝)節點本來就不支援,members 進到鏈裡也沒有改變這一點;建議在 §0「不做」補一行。

---

## 我驗證過、成立的部分
- F2:`netJoin` 只讀 key 1、3(`node.go:1024-1041`)✅
- F3:Members 唯一的寫入是 leave 清成 nil(`node.go:1206`);Encode / Decode 的 key 10(`provstore.go:90-95, 210-216`)✅
- F5:`node.go:756-758` 在 owner-op 之前就分流;`session.go:79, 82` owner / member 都允許 update ✅
- F6:鏈只檢查版本與 prev;`parseNet` 只檢查 net_id 長度(`node.go:972`)✅
- F7:`ReasonCountryJoin` 只出現在 `settingsset.go:21, 123`;CJ2 說明在 `prov-country-join-254.sh:3-6` ✅
- F8:`EReject = 24`(`node.go:53`)、`hEReject 24`(`helper.go:26`),`mapHelperR` 會轉成 `E_REJECTED{2: reason}`(`session.go:~905-907`)✅
- F10:provstore 在 832fbf8 與 e5c89a1 之間沒有差異(`git diff --stat` 是空的),Decode 收 key 10 = bytes ✅
- 常數 `CTMembers` 與 `LabelMembers` 已存在(`cose.go:22`、`proto.go:31`)✅
- 向量 `gen.py:547` 已經用 CDDL 的 update 形狀;app 的 `vectors.rs:44` 把 version_chain 標成 pending,方向一致 ✅
- Finish / 斷電:整筆 record 存到 p5 `prov.cbor`(`txn.go:26-47`),Members 跟著同一筆 record 一起前進或退回,所以 U9 測的東西是對的 ✅
- CBOR 深度:envelope → body → 鏈 → step → tag → array,深度 < 16(`cbor.go:117`)✅
- 對照組:在原始碼複本上跑 `go test ./node/` 通過;provd 與 cose 在複本裡失敗,只是因為 `vectors.json` 的相對路徑在 `/tmp` 複本下找不到,不是產品問題(在 repo 原處沒有跑)。

## 判定:REJECT(窄)
修完 B1(一行,加 U11 與負向對照)、M1–M3(文件與契約,M3 另加一個測試)之後,再整份重新審一次。MINOR 可以在同一輪一起收。
