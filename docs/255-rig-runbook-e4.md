# #255 實驗台操作手冊（二）：E4 → E17（第 1 顆晶片，**會永久改變晶片**）

接在 `docs/255-rig-runbook.md`（焊接 → E3）之後。照表操課用：每一步寫明做什麼、預期看到什麼、看到別的怎麼辦。
設計依據：`docs/design/255-608b-config.md` §8（實驗清單與順序）、§8.3（E1–E3 的實測結果與 E4 的前提）。這份手冊不新增任何設計。
審查：與 PR D2 的程式一起審（`docs/design/255-reviews/review-prD2-A.md`、`review-prD2-B.md`）；第一輪兩位對 E4 都是 APPROVE-WITH-CHANGES，手冊的發現（A r1–r7、B M1、m1、m13、m14）已改進本版。

**這份手冊和第一份最大的不同：從 §3 起每一步都回不去。** 鎖設定區、鎖資料區、鎖單一槽、計數器加一、寫位元組 85，做了就是永久的。所以：

- **只用第 1 顆晶片**（序號 `0123ba99e2ca248cee`，變體影像）。它是設計裡的犧牲品，做完這份手冊它不會變成節點。
- **每個標 🔒 的步驟開始前，停下來取得使用者同意**（設計 §8.0）。使用者本人執行時，本人就是同意者；交給助理代跑時每一個 🔒 都要再問一次。
- 🔒 的指令都要同時給 `-allow`（犧牲晶片清單）和 `-serial`（把序號完整再打一次）。少一個工具就拒絕。
- 🔒 的指令先用 `-dry-run` 跑一次：它印出要送的封包然後停，不送任何東西。**把印出來的封包和這份手冊寫的逐字比對**，相同才拿掉 `-dry-run`。手冊上的封包是另外用獨立程式算的（`docs/design/255-reviews/artifacts/indep-forgood-packets.py`），不是工具自己印了再抄回來。
- **看到「停」就停。** 不要換參數重試。把當時的輸出帶回來。
- 不碰 02、04。

標記：✅ 已在真晶片上量過（設計 §8.3）；⚠️ 設計的預期，**還沒有在真晶片上看過** —— 這份手冊大部分的「預期」都是 ⚠️，實驗的目的就是把它們變成 ✅ 或推翻。

**每個指令的輸出開頭都有五行**：`tool_rev=`（工具是哪個 commit 編的）、`revision=`、`serial=`、`lock_config=`、`lock_data=`。後兩行是晶片的鎖定位元組（`55` 未鎖、`00` 已鎖），**不是**鎖定指令的結果。鎖定指令的結果是另一行，名稱以 `_result=` 結尾。

---

## 0. 前提（缺一項就不要開始）

| # | 前提 | 怎麼確認 |
|---|---|---|
| 1 | E1、E2、E3 做完，晶片是「變體影像、未鎖」 | §2 的 `info` 與 `compare` |
| 2 | 影像與鎖定校驗值已由獨立實作重算 | 設計 §8.3：校驗值 `9022`，封包 `03 07 17 00 22 90 1d 15` |
| 3 | 工具是 PR D2 審查通過的那個 commit 編出來的 | §1.1 的 sha256，與每次輸出的 `tool_rev=` |
| 4 | 知道怎麼讓晶片真的斷電 | 切智慧插座，已實測是真的斷電（設計 §8.3）。`poweroff` 本身**不算**斷電。照 §1.3 |
| 5 | 使用者同意開始 | — |

## 1. 準備

### 1.1 工具

在開發機上編（或用附在 PR 的執行檔），記下 commit 與 sha256，複製到實驗台的 tmpfs：

```sh
# 開發機（WSL），在乾淨的 checkout 裡
cd feed/batman-prov/src && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o /tmp/se-lab ./cmd/se-lab
sha256sum /tmp/se-lab
scp /tmp/se-lab root@<實驗台>:/dev/shm/
```

```sh
# 實驗台
cd /dev/shm && chmod +x se-lab && sha256sum se-lab
```

兩邊的 sha256 不同 → **停**。

### 1.2 每開一條新的連線都要先做（斷電後重新連線也算）

```sh
cd /dev/shm
set -o pipefail
false | tee /dev/null; echo "rc=$?"     # 必須印 rc=1
SN=0123ba99e2ca248cee        # 第 1 顆晶片的序號（E1 讀到的，見第一份手冊帶回來的 e1-info.txt）
B17=00                       # 空白位元組 17（E1 讀到的）
echo "$SN" > allow.txt
./se-lab info
```

| 檢查 | 預期 | 不符合時 |
|---|---|---|
| 自我檢查那一行 | `rc=1` | 印 `rc=0` = `pipefail` 沒生效，之後所有 `rc=` 都會是假的 → **停** |
| `info` 的 `serial=` | 和 `e1-info.txt` 裡的 `serial=` **逐字相同**（拿紙本或另一個視窗對，不要只和 `$SN` 比 —— 清單和 `-serial` 都來自 `$SN`，它打錯的話兩道檢查會一起錯） | **停** |
| `info` 的 `tool_rev=` | §1.1 記下的 commit | **停** |

### 1.3 斷電的做法（§2、§3、§6、§12 會用到）

實驗台的電源接在智慧插座上，切插座就是真的斷電（設計 §8.3 的實測：電池只撐幾秒）。全程可以遠端做：

1. **先把 `/dev/shm/*.txt` 用 `scp` 帶走**（tmpfs 斷電就清空）。
2. `poweroff`，等 ssh 斷線後再等 20 秒。
3. 插座斷電，**至少 60 秒**（電池在拔掉市電後還會撐幾秒，關機狀態下可能更久）；這段時間插座回報的功率必須是 `0.0 W`。
4. 插座送電。Pi 會自己開機（約 1 分鐘）。
5. 重新連線，確認 `vcgencmd get_rsts` 印 `get_rsts=1000`，把 `se-lab` 再複製一次並對 sha256（§1.1），再做一次 §1.2。

三項證據要一起成立：斷電期間功率 0.0 W、Pi 自己開機、`get_rsts=1000`。任何一項不成立 → **停**，那一步的「斷電後」不算做過。

人在現場、不用插座時：`poweroff` → 拔掉電源至少 60 秒 → 插回；開機後同樣要看到 `get_rsts=1000`。

### 1.4 看不懂的結果

任何指令 `rc` 不是預期的值、又沒有對應的列 → **停**，跑一次 `./se-lab info 2>&1 | tee stop-info.txt`，連同當時的輸出帶回來。**不要重送剛才那個指令。**

## 2. 鎖定前的最後檢查（可逆，可以重跑）

```sh
./se-lab info 2>&1 | tee p-info.txt
./se-lab -byte17 "$B17" compare 2>&1 | tee p-compare.txt
./se-lab soak 300 2>&1 | tee p-soak.txt; echo "rc=$?" | tee -a p-soak.txt
```

| 輸出 | 預期 | 不符合時 |
|---|---|---|
| `lock_config=`、`lock_data=` | `55`、`55` ✅ | 已經不是 `55` → **停** |
| `compare=` | `EQUAL` ✅ | `DIFFERENT` → **停** |
| `soak_errors=`、`soak_differ=` | `0`、`0`，`rc=0` | 任何一個不是 0 → **停**。這代表匯流排或焊點不穩，在可以重來的時候發現比在鎖定途中發現好 |

「斷電後設定仍在」已經在 2026-11-27 驗過兩次（設計 §8.3），這裡不用再斷電；如果離那次已經隔了很久、或中間有人動過實驗台，就照 §1.3 斷電一次再重跑上面的 `info` 與 `compare`。

## 3. E4：鎖設定區 🔒

先乾跑：

```sh
./se-lab -allow allow.txt -byte17 "$B17" -expect-crc 9022 -dry-run lock-config 2>&1 | tee e4-dry.txt; echo "rc=$?" | tee -a e4-dry.txt
```

| 輸出 | 預期 | 不符合時 |
|---|---|---|
| `compare=` | `EQUAL` | **停** |
| `config_crc=` | `9022`（設計 §8.3 預先算好的） | **停**。不要改 `-expect-crc` 去配合它：這個數字不同代表晶片裡有位元組和 E3 之後不一樣 |
| `lock_packet=` | `03 07 17 00 22 90 1d 15` | **停** |
| `dry_run=` 與 `rc=` | `nothing sent`、`rc=0` | `rc=3` → 讀訊息，**停** |

**🔒 取得同意後**，鎖定：

```sh
./se-lab -allow allow.txt -serial "$SN" -byte17 "$B17" -expect-crc 9022 lock-config 2>&1 | tee e4-lock.txt; echo "rc=$?" | tee -a e4-lock.txt
```

看 `lock_config_result=` 這一行（不是開頭的 `lock_config=55`，那是鎖定**前**讀到的位元組）：

| `lock_config_result=` | `rc=` | 意思 | 怎麼辦 |
|---|---|---|---|
| `locked` ⚠️ | `0` | 鎖了，晶片自己的位元組也說鎖了（同時會看到 `lock_config_after=00`、`lock_data_after=55`） | 繼續 |
| `status_0f` | `1` | 晶片拒絕（校驗值不符）。**沒有鎖** | **停**，帶回輸出 |
| `LOCKED_answer_lost` | `1` | 指令的回應沒收到，但晶片的位元組說**已經鎖了** | **不要再送一次。** 照 §1.4 |
| `NOT_LOCKED_answer_lost`、`NOT_LOCKED_after_success_status`、`status_XX_but_LOCKED` | `1` | 設計沒有預期到的情況 | **停**，照 §1.4 |
| `UNKNOWN_read_back_failed` | `1` | 送出後讀不回晶片，不知道鎖了沒 | **不要再送一次。** 照 §1.4 |
| （沒有這一行）且 `rc=3` | `3` | 沒有送出：訊息是 `changed since it was read`（鎖定前有位元組變了）或 `could not be read again` | **停** |

鎖定後的三項確認：

```sh
./se-lab -allow allow.txt config-write 17 00000000 2>&1 | tee e4-cfgwrite.txt
./se-lab -allow allow.txt random 2>&1 | tee e4-random.txt
./se-lab -allow allow.txt -byte17 "$B17" write-image 2>&1 | tee e4-writeimage.txt; echo "rc=$?" | tee -a e4-writeimage.txt
```

| 指令 | 預期 ⚠️ | 不符合時 |
|---|---|---|
| `config-write 17` | `config_write_word17=status_0f`（設定區不能再寫） | `status_00` = 鎖了還能寫：**停** |
| `random` | 64 個十六進位字元，**不是** `ffff0000` 重複（對照：E2 鎖定前是那個樣式 ✅） | 還是 `ffff0000…` → 照實記錄，**停** |
| `write-image` | `rc=3`、訊息 `config zone is locked` | — |

最後照 §1.3 **斷電一次**，開機後 §1.2 的 `info`：`lock_config=00`（晶片仍在位址 0x60 回應、鎖定狀態還在）。沒有回應 → **停**。

## 4. E5、E6：寫資料區、鎖資料區 🔒

### 4.1 鎖定前（資料區還沒鎖，這一段可以重跑）

```sh
./se-lab -allow allow.txt priv-write 4 2>&1 | tee e6-privwrite-before.txt
./se-lab pubkey 4 2>&1 | tee e6-pubkey4.txt
./se-lab -allow allow.txt fill-data 2>&1 | tee e6-fill.txt; echo "rc=$?" | tee -a e6-fill.txt
./se-lab -allow allow.txt checkmac 5 2>&1 | tee e6-checkmac-before.txt
```

| 指令 | 預期 ⚠️ | 不符合時 |
|---|---|---|
| `priv-write 4` | `priv_write_slot4=status_00`（鎖定前可以明文寫入私鑰：這是 §4.3「必須失敗」的對照組） | `status_0f`：照實記錄，繼續（對照組不成立，E6 的那一列記「無對照」） |
| `pubkey 4` | `pubkey_slot4=` 的值等於上一步印的 `expected_pub_slot4=` | 不同 → 照實記錄 |
| `fill-data` | 槽 0、1、2、4 是 `private_key_slot_skipped`；其餘 12 個槽都是 `written_N_bytes`；`fill_data_failed_slots=0`；`rc=0` | 有槽印 `FAILED`、`rc=1`：**停**。這是設計 E6 寫明的可能結果（晶片不接受秘密槽尾端的 4 位元組寫入；文件上有這個說法，假晶片預設沒有模擬），要回設計改燒錄流程，不要自己重試 |
| `fill-data` 的 `otp_write_block0/1=` | 記下是 `status_00` 還是 `status_0f`（**E5 的答案**，兩種都不算失敗） | — |
| `checkmac 5` | `checkmac_slot5=status_0f`（資料區鎖定前不能用） | `status_00` → 照實記錄 |

`fill-data` 寫的是由晶片序號推導的測試值，不是秘密。**真正的認領秘密永遠不經過 `se-lab`。**

### 4.2 鎖資料區 🔒

OTP 的填充值看上一步 E5 的結果：兩個 `otp_write_block` 都是 `status_00` → 用預設（`00`）；有 `status_0f`（OTP 寫不進去）→ **停**，帶回輸出（要先決定 OTP 的空白值是什麼，再用 `-otp-fill` 指定；`ff` 時的校驗值是 `3c9f`）。

```sh
./se-lab -allow allow.txt -dry-run lock-data 2>&1 | tee e6-dry.txt
```

| 輸出 | 預期（獨立算的） | 不符合時 |
|---|---|---|
| `otp_fill=`、`data_crc=` | `00`、`be96` | **停** |
| `lock_packet=` | `03 07 17 01 96 be 26 70` | **停** |
| `dry_run=` | `nothing sent` | **停** |

**🔒 取得同意後**：

```sh
./se-lab -allow allow.txt -serial "$SN" -expect-crc be96 lock-data 2>&1 | tee e6-lock.txt; echo "rc=$?" | tee -a e6-lock.txt
```

| `lock_data_result=` | `rc=` | 意思 | 怎麼辦 |
|---|---|---|---|
| `locked` ⚠️ | `0` | 鎖了（`lock_data_after=00`）。**同時證明**：尾端 4 位元組的寫入有效、校驗值「跳過私鑰槽」的規則是對的 | 繼續 |
| `status_0f` | `1` | 晶片拒絕，**沒有鎖**，內容也沒有變 | **停**，帶回輸出 —— 校驗值的算法（哪些槽算進去）要回設計查 |
| 其他 | `1` | 同 §3 的表 | 同 §3 的表 |

### 4.3 鎖定後

```sh
./se-lab -allow allow.txt checkmac 5        2>&1 | tee e6-checkmac.txt
./se-lab -allow allow.txt checkmac 5 wrong  2>&1 | tee e6-checkmac-wrong.txt
./se-lab -allow allow.txt priv-write 4      2>&1 | tee e6-privwrite-after.txt
./se-lab -allow allow.txt data-write 5      2>&1 | tee e6-write5.txt
./se-lab -allow allow.txt data-write 7      2>&1 | tee e6-write7.txt
./se-lab -allow allow.txt data-write 6      2>&1 | tee e6-write6.txt
```

| 指令 | 預期 ⚠️ | 不符合時 |
|---|---|---|
| `checkmac 5` | `status_00`（相符；用的是產品的雜湊格式與晶片自己的序號） | `status_01` 或其他 → **停**：認領比對的格式不對 |
| `checkmac 5 wrong` | `checkmac_slot5_wrong=status_01`（不符） | `status_00` → **停** |
| `priv-write 4` | `status_0f`（鎖後不能再明文寫私鑰；對照：§4.1 成功） | `status_00` → **停** |
| `data-write 5`、`data-write 7` | `status_0f`（認領槽與不使用的槽永遠不可寫） | `accepted` → **停** |
| `data-write 6` | `accepted`（對照組：槽 6 設成隨時可寫，證明指令格式是對的） | `status_0f` → 上面兩項的「失敗」沒有對照，照實記錄 |

## 5. E8：認領槽擋得住哪些指令

```sh
for c in "mac 5" "mac 3" "gendig-mac 5" "gendig-mac 3" "hmac 5" "hmac 3" \
         "kdf hkdf 5" "kdf hkdf 3" "kdf prf 5" "kdf prf 3" "aes 5" "aes 3"; do
  echo "=== $c"; ./se-lab -allow allow.txt $c 2>&1 | grep -v '^tool_rev=\|^revision=\|^serial=\|^lock_config=\|^lock_data='
done | tee e8.txt
./se-lab slot-read 5 2>&1 | tee e8-read5.txt
./se-lab slot-read 8 2>&1 | tee e8-read8.txt
```

槽 5 是認領槽（設了 NoMac），槽 3 是對照組（同樣是秘密，但沒有 NoMac）。

| 指令 | 槽 5 預期 ⚠️ | 槽 3（對照）預期 ⚠️ | 不符合時 |
|---|---|---|---|
| `mac` | `mac_slot5=status_0f` | 一串 64 字元 + `mac_matches_host=yes` | **槽 5 回了資料 → 停，回到設計**（只有 MAC 類的輸出能當認領回應） |
| `gendig-mac` | `gendig_slot5=status_00` 然後 `mac_tempkey=status_0f` | `mac_matches_host=yes` | **槽 5 的 `mac_tempkey` 回了資料 → 停，回到設計** |
| `hmac` | `hmac_start_slot5=status_0f`（或 `hmac_end=status_…`） | `hmac_matches_host=yes` | 槽 5 回了摘要 → 記錄，由設計判斷 |
| `kdf hkdf`、`kdf prf` | `status_…` | 一串資料 | 槽 5 回了資料 → 記錄，由設計判斷。**兩個槽都是 `status_03`** = 指令格式可能不對（這幾個格式沒有在真晶片上驗過）→ 記為「無對照」 |
| `aes` | `status_…` | 一串資料或 `status_…` | 同上；兩邊都失敗時連同 E1 的位元組 13（`0x61`）一起記錄 |
| `slot-read 5` | `slot5=status_0f` | — | 讀得出來 → **停** |
| `slot-read 8` | 832 個十六進位字元（全 0） | — | 對照組：證明讀取指令的格式是對的 |

格式不對而想改封包重試時用 `raw`：`./se-lab -allow allow.txt raw <OP> <P1> <P2> [<資料>]`，全部十六進位。`raw` 送不出 Lock、Counter、UpdateExtra，也寫不到設定區的鎖定位元組。改了什麼要記下來。

## 6. E11：計數器 🔒

**如果這一節做到一半斷線或斷電：先跑 `counter-read 1`，值已經是 1 就不要再加一次**（加一不能重來，也不會自動略過）。

```sh
./se-lab counter-read 0 2>&1 | tee e11-read0.txt
./se-lab counter-read 1 2>&1 | tee e11-read1.txt
./se-lab -allow allow.txt -dry-run counter-inc 1 2>&1 | tee e11-dry.txt
```

乾跑預期：`packet=03 07 24 01 01 00 06 f7`、`dry_run=nothing sent`。不同 → **停**。

**🔒 取得同意後**（這顆晶片的 Counter[1] 會永久加一；上限 2,097,151，一次無妨）：

```sh
./se-lab -allow allow.txt -serial "$SN" counter-inc 1 2>&1 | tee e11-inc.txt
./se-lab counter-read 1 2>&1 | tee e11-read1-after.txt
```

| 輸出 | 兩種結果都要記 |
|---|---|
| `counter1_after_inc=` | 一串 8 字元（**成功 = 匯流排上任何人不用授權就能加**）或 `status_…`（**被拒**）。這一行回填 `security-architecture.md` §10 O-1、O-17 的陷阱紀錄 |
| 加一前後的 `counter1_le=` | 差 1 |

照 §1.3 **斷電一次**，開機後 `counter-read 1`：值不變（或照實記錄跳了幾格）。然後兩個「降不回去」的嘗試（寫的是 Counter[1] 的兩個字，位元組 60–67；`ffffffff`、`00000000` 是它們的空白值）：

```sh
./se-lab -allow allow.txt config-write 15 ffffffff 2>&1 | tee e11-cfgwrite15.txt
./se-lab -allow allow.txt config-write 16 00000000 2>&1 | tee e11-cfgwrite16.txt
./se-lab -allow allow.txt -dry-run update-extra 2 00 2>&1 | tee e11-dec-dry.txt
./se-lab -allow allow.txt -serial "$SN" update-extra 2 00 2>&1 | tee e11-dec.txt
./se-lab counter-read 1 2>&1 | tee e11-read1-final.txt
./se-lab counter-read 0 2>&1 | tee e11-read0-final.txt
```

乾跑預期 `packet=03 07 20 02 00 00 03 f8`。其餘預期 ⚠️：三個都是 `status_…`（被拒），`counter1_le` 不變、`counter0_le` 和一開始相同。變小了 → 照實記錄（這是重要發現）。**Counter[0] 從頭到尾不動**：工具本身也拒絕 `counter-inc 0`。

## 7. E17：產生金鑰、簽章、鎖單一槽 🔒

```sh
./se-lab -allow allow.txt genkey 4 2>&1 | tee e17-genkey.txt
./se-lab -allow allow.txt sign 4   2>&1 | tee e17-sign.txt; echo "rc=$?" | tee -a e17-sign.txt
./se-lab -allow allow.txt -dry-run lock-slot 4 2>&1 | tee e17-dry.txt
```

乾跑預期：`slot=4`、`slot_config=2083`、`key_config=0073`、`lockable=yes`、`slot_already_locked=no`、`lock_packet=03 07 17 12 00 00 8e 08`、`dry_run=nothing sent`。任何一項不同 → **停**。

**🔒 取得同意後**：

```sh
./se-lab -allow allow.txt -serial "$SN" lock-slot 4 2>&1 | tee e17-lock.txt; echo "rc=$?" | tee -a e17-lock.txt
./se-lab -allow allow.txt genkey 4 2>&1 | tee e17-genkey-after.txt
./se-lab pubkey 4                  2>&1 | tee e17-pubkey-after.txt
./se-lab -allow allow.txt sign 4   2>&1 | tee e17-sign-after.txt; echo "rc=$?" | tee -a e17-sign-after.txt
```

| 指令 | 預期 ⚠️ | 不符合時 |
|---|---|---|
| `genkey 4`（鎖前） | `genkey_slot4=` 128 個十六進位字元 | `status_…` → **停**（燒錄流程 S2 靠這個） |
| `sign 4`（鎖前） | `signature_valid=yes`、`rc=0`。這是產品的簽章方式（直通 nonce + 外部簽章）。記下 `sign_sequence_ms=` | `sign_slot4=status_…` → **停**：產品的登入證明做不出來，回到設計 |
| `lock-slot 4` | `lock_slot4_result=locked`、`slot_locked_after=ffef`、`rc=0` | `status_0f` → **停**；其他結果照 §3 的表 |
| `genkey 4`（鎖後） | `genkey_slot4=status_0f`（鎖住的槽不能再產生） | 回了新公鑰 → **停** |
| `pubkey 4`（鎖後） | 和鎖前 `genkey 4` 印的相同 | 不同 → **停** |
| `sign 4`（鎖後） | `signature_valid=yes`（鎖住的金鑰仍可用） | → **停** |

工具只肯對槽 4、5、6 送鎖定，而且要兩區都鎖了之後。

## 8. E9、E10：寫入指定槽、ECDH

槽 0 保持空的。先給槽 1、2 產生金鑰，然後**先做 E9**（它的對照組用槽 3 當來源，要在任何可能寫到槽 3 的指令之前做）：

```sh
./se-lab -allow allow.txt genkey 1 2>&1 | tee e10-genkey1.txt
./se-lab -allow allow.txt genkey 2 2>&1 | tee e10-genkey2.txt
for c in "kdf hkdf 3 6" "kdf hkdf 3 5" "kdf hkdf 3 15" "kdf hkdf 3 4" "kdf hkdf 3 0" "kdf prf 3 6" "kdf prf 3 5"; do
  echo "=== $c"; ./se-lab -allow allow.txt $c 2>&1 | grep -v '^tool_rev=\|^revision=\|^serial=\|^lock_config=\|^lock_data='
done | tee e9.txt
for c in "ecdh 2 clear" "ecdh 2 tempkey" "ecdh 2 enc" "ecdh 2 compat" "ecdh 1 clear" "sign 1" "sign 0" "sign-internal 4" "sign-internal 2" "ecdh 2 slot"; do
  echo "=== $c"; ./se-lab -allow allow.txt $c 2>&1 | grep -v '^tool_rev=\|^revision=\|^serial=\|^lock_config=\|^lock_data='
done | tee e10.txt
```

E9（KDF「寫入指定槽」）：

| 指令 | 預期 ⚠️ | 不符合時 |
|---|---|---|
| `kdf hkdf 3 6`、`kdf prf 3 6` | `status_00`（對照：寫入槽 6 要成功）⚠️ 這個指令的格式沒有驗過 | 對照也失敗 → 下面幾項「結果不確定」，槽 5 的保護只靠「設成永不可寫」（文件），記為已知殘餘 |
| `kdf hkdf 3 5`、`kdf prf 3 5`、`kdf hkdf 3 15`、`kdf hkdf 3 4` | `status_…`（寫不進認領槽、不使用的槽、已鎖的私鑰槽） | **指向 5 或 4 成功 → 停** |
| `kdf hkdf 3 0` | 照實記錄 | — |

設計的 E9 也列了 ECDH 的「寫入指定槽」，目標 5、15、4、0。ECDH 只能寫到「來源槽的下一槽」，而變體影像沒有任何一槽開了這個功能，所以那幾列**做不出只差受測條件的實驗，只靠文件**；能做的只有下表的 `ecdh 2 slot`（目標是槽 3）。

E10（ECDH 與簽章的角色）：

| 指令 | 預期 ⚠️ | 不符合時 |
|---|---|---|
| `ecdh 2 clear` | `ecdh_matches_host=yes`（和軟體算的相同） | 不同或 `status_…` → **停** |
| `ecdh 2 tempkey` | `status_00` | 記錄 |
| `ecdh 2 enc` | `status_…`（**加密輸出要被拒**） | 回了資料 → 記錄：最終影像要改 ChipOptions（設計 E10 的「不通過時」） |
| `ecdh 2 compat` | `ecdh_matches_host=yes`（508A 相容模式；槽 2 沒有開「寫入下一槽」，所以是明文輸出） | 照實記錄 |
| `ecdh 1 clear` | `status_0f`（槽 1 不准 ECDH；對照：槽 2 成功） | 回了資料 → **停** |
| `sign 1` | `sign_slot1=status_0f`（槽 1 只准內部簽章） | 簽出來 → **停** |
| `sign 0` | `status_0f`（槽 0 沒有金鑰） | — |
| `sign-internal 4` | `sign_internal_slot4=` 128 字元（槽 4 兩種簽章都准） | 照實記錄 |
| `sign-internal 2` | `status_0f`（槽 2 不准簽章） | 簽出來 → 記錄 |
| `ecdh 2 slot`（最後做） | `status_…`（槽 2 沒有開「結果寫入下一槽」） | `status_00` → **停**：槽 3 被寫了 |

## 9. E13：個別鎖定 🔒

```sh
./se-lab -allow allow.txt data-write 6 2>&1 | tee e13-write6-before.txt
./se-lab -allow allow.txt -dry-run lock-slot 6 2>&1 | tee e13-dry6.txt
./se-lab -allow allow.txt -dry-run lock-slot 5 2>&1 | tee e13-dry5.txt
```

| 輸出 | 預期 |
|---|---|
| `data-write 6` | `data_write_slot6=accepted` |
| 槽 6 乾跑 | `lockable=yes`、`slot_already_locked=no`、`lock_packet=03 07 17 1a 00 00 cd 89` |
| 槽 5 乾跑 | `lockable=no`、`lock_packet=03 07 17 16 00 00 0d 8a` |

任何一項不同 → **停**。**🔒 取得同意後**（兩個鎖定各問一次）：

```sh
./se-lab -allow allow.txt -serial "$SN" lock-slot 6 2>&1 | tee e13-lock6.txt; echo "rc=$?" | tee -a e13-lock6.txt
./se-lab -allow allow.txt data-write 6 2>&1 | tee e13-write6-after.txt
./se-lab -allow allow.txt -serial "$SN" lock-slot 5 2>&1 | tee e13-lock5.txt; echo "rc=$?" | tee -a e13-lock5.txt
```

| 指令 | 預期 ⚠️ | 不符合時 |
|---|---|---|
| `lock-slot 6` | `lock_slot6_result=locked`、`rc=0` | `status_0f` → **停** |
| `data-write 6`（鎖後） | `status_0f` | `accepted` → **停** |
| `lock-slot 5` | `lock_slot5_result=status_0f`、`rc=1`（槽 5 設成不可鎖；**這裡的 `rc=1` 是預期的**） | `locked` → 照實記錄 |

## 10. E15：槽 8 放得下憑證

憑證最大多少位元組已經在開發機上由測試算過（最壞情況 393，槽 8 是 416）。這裡只確認 416 位元組的槽寫得進、讀得回：

```sh
BLOB=$(printf 'a55a%.0s' $(seq 195))     # 390 位元組
./se-lab -allow allow.txt slot-write 8 "$BLOB" 2>&1 | tee e15-write.txt
./se-lab slot-read 8 2>&1 | tee e15-read.txt
```

預期 ⚠️：`slot_write_slot8=written_416_bytes`；`slot8=` 的前 780 個字元是 `a55a` 重複，後面 52 個是 `0`。

這比設計的 E15 窄：設計寫的是「憑證寫入槽 8、讀回、驗章」。第 1 顆晶片的槽 0 刻意不產生金鑰，組不出一張完整的憑證；真的憑證（含驗章）在第 2 顆晶片的燒錄流程（F1）才寫。

E16（健康測試失敗後恢復）沒有辦法主動誘發，不做；過程中若剛好看到 `status_08`，記下當時的指令與之後一次喚醒的結果。

## 11. 斷電前先把結果帶走

到這裡為止的 `/dev/shm/*.txt` 全部 `scp` 走。下一節是整份手冊唯一可能讓晶片從匯流排上「消失」的步驟。

## 12. E12：位元組 85 🔒（放在最後）

設計的順序是 E12 在 E13、E15 之前。這裡放到最後：萬一「位元組 85 不影響位址」這個假設是錯的，晶片斷電後會跑到別的位址，工具就再也連不上它，排在後面的實驗會全部做不了。E13、E15 不依賴 E12，先做沒有影響。

```sh
./se-lab -allow allow.txt -dry-run update-extra 1 a0 2>&1 | tee e12-dry.txt
```

乾跑預期：`byte84_before=00`、`byte85_before=00`、`packet=03 07 20 01 a0 00 03 e9`、`dry_run=nothing sent`。不同 → **停**。

**🔒 取得同意後**（位元組 85 只能寫一次；`a0` 是「位址 0x50」，一個不是 0x60 的值）：

```sh
./se-lab -allow allow.txt -serial "$SN" update-extra 1 a0 2>&1 | tee e12.txt
```

預期 ⚠️：`update_extra_mode1=status_00`、`byte85_after=a0`。然後照 §1.3 **斷電一次**，開機後：

```sh
./se-lab info 2>&1 | tee e12-after-power.txt; echo "rc=$?" | tee -a e12-after-power.txt
i2cdetect -y -r 1 2>&1 | tee e12-scan.txt
```

預期：`rc=0`、掃描仍在 `60`、沒有 `50`（ChipMode 第 0 位元 = 0，所以位元組 85 不影響位址）。晶片跑到 `50` 或不回應 → **停**，設計的假設被推翻（這顆晶片的實驗到此為止，其他都已經做完了）。

## 13. 要帶回來的東西

`/dev/shm` 裡所有 `p-*.txt`、`e4-*.txt` … `e17-*.txt`、`stop-info.txt`（**每次斷電前先 `scp` 走**），加上手寫：

| 項目 | 來源 |
|---|---|
| `se-lab` 的 commit 與 sha256 | §1.1 |
| 每一次斷電：電源燈有沒有熄滅、等了幾秒 | §1.3 |
| 每一個 🔒：誰同意、什麼時候 | 各節 |
| 任何和「預期」不同的地方，連同當時的完整輸出 | 全部 |

這些結果用來：把設計與假晶片裡標 ⚠️ 的行為換成實測；把 `se608.ProvisionalCmds` 這個標記拿掉（它在，PR 2 就不能出晶片映像）；決定燒錄流程（§5）要不要改；然後才做第 2 顆晶片（最終影像，F1）。

做完這份手冊，第 1 顆晶片的狀態是：兩區已鎖、槽 4 與槽 6 已鎖、槽 1 / 2 / 4 有金鑰、Counter[1] = 1、位元組 85 = `a0`。它留在實驗台當對照，不會成為節點。
