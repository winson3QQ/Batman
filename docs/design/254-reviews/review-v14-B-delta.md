# #254 v14 窄範圍複查 — 審查 B(v13 → v14,d876fad)

範圍(使用者指定):只查 (1) B13-M1 是否關閉;(2) v13→v14 的 diff 有沒有引入新的 BLOCKER/MAJOR;(3) 我 v13 的 MINOR(m1–m9)各自的去向。全程唯讀:只看 `git diff ad35e32 d876fad -- docs/design/254-stage1-impl.md`,另外讀了 firmware 樹的 `scripts/check-image-manifest.sh` 和 `build-board.sh:140-150`。

**判定:APPROVE-WITH-CHANGES — 0 BLOCKER / 0 MAJOR / 新 MINOR 3 條(n1–n3,都是 PR 要求)。**

## 1. B13-M1(RAK4631 的 flash 沒被轉賣流程涵蓋)→ **closed**

- F25 新增周邊盤點:RAK4631(02、04 都有)、GPS、MM6108 OTP、RTC/HAT EEPROM/customer OTP。和我在 04 看到的一致(`239a:8029`、`/dev/ttyACM0`)。
- §4.5:賣方新增步驟 ⓪「Meshtastic factory reset」;買方在重設 EEPROM、重燒之後,再做一次 factory reset。
- §8 新增一列,L16 節點層加了斷言(頻道 PSK = 預設、節點資料庫為空)和負對照(只重燒 SD 卡 → 舊頻道仍在)。
- 誠實界線改成「重設 EEPROM、重燒、重設 LoRa 模組」三件事。
- 剩下的是精確度問題 → n1(MINOR)。

## 2. v13→v14 diff 有沒有新的 BLOCKER/MAJOR → **沒有**

我逐段看過以下改動:
- 99zz 的判斷改為 verdict=`unseeded` 且(無 prov 或 state=`unclaimed`);
- `--firstboot` 加了唯一一個 uci 寫入;
- 95 把 BOOT_ORDER 和預設值比對,不同就 WARN(只是訊號,不是閘門);
- 轉賣工具第 1、2、3、7 點;
- 買方的 bootloader 版本下限;
- Q7(使用者已接受區域鎖失效);
- dpp/wps/rfkill 列為 inert。

這些都沒有引入新的共享資源寫者,也沒有新增 fail-open 路徑。

## 3. 新 MINOR

- **n1 — 要寫明 Meshtastic 是哪一種 factory reset**(PR-P3)。Meshtastic 有兩種:只重設設定 / 頻道的,和整機重設(`--factory-reset-device`,連節點資料庫和 BLE bond 一起清)。§4.5 要清的是頻道 PSK、節點資料庫、位置,所以要明寫用整機重設;說明頁也要寫 app 裡對應的選項。否則賣方照字面做了設定重設,節點資料庫(隊友名稱與最後位置)和賣方手機的 BLE bond 還會留著。L16 斷言已經檢查節點資料庫為空,會抓到做錯的情形,所以只算 MINOR。
- **n2 — shim 的斷言放進 `check-image-manifest.sh` 照現狀做不到**(PR-F)。這支腳本只讀**套件 manifest**(`check-image-manifest.sh:13`,`build-board.sh:147-148` 傳的是 `$BT/*.manifest`)。shim 是 `files/` 的覆蓋檔,套件 `persistent-vars-storage-bcm2711` 還是在 manifest 裡,所以 manifest 看不出 shim 有沒有蓋上去。要擴充成也讀 rootfs(build_dir 的 root 或解開的 squashfs),檢查檔案 sha 等於 repo 的 shim,並實跑 `READ` 得到 rc 1、無輸出;rootfs 讀不到時要 FAIL。負對照:拿掉 `files/sbin/persistent_vars_storage.sh` → 閘門 FAIL。
- **n3 — 兩處文字和新規則不一致**(文件)。
  - §4.5「節點端」那一條還寫著「p5 未 seed、無 prov」,和 §3 / §4.4 的新判斷不同,請統一。
  - 轉賣工具第 3 點同一句話裡先說「先 `Clear-Disk -RemoveData` 移除分割」,又說「不用 `Clear-Disk -RemoveData`」。請改成「Clear-Disk 只用來釋放 volume,不靠它清零」。

## 4. v13 MINOR 的去向

| # | 狀態 | 一句話 |
|---|---|---|
| m1 | partial | L44 / L60 已涵蓋,也加了斷言;96 從 `:64/:67/:71/:89` 出去時(verdict 不是 unseeded)仍會保留隨機 key 的 AP。這和使用者的取捨一致,不升級;另外文字不一致見 n3 |
| m2 | addressed | §3 讀者加了 99zz;`--firstboot` 的 uci 寫入寫明了;D5 改了字 |
| m3 | addressed | MediaType 來源、IsBoot/IsSystem、防睡眠、中斷不回報成功、sha 算 `.img.gz` 都補了;剩一句措辭矛盾,見 n3 |
| m4 | addressed | 拒絕已掛載的目標和系統根所在裝置;ENOSPC 以已寫位元組數判定 |
| m5 | addressed | 只收 regular file,並加了負測試(實作時要先解析 symlink 再判斷) |
| m6 | addressed | 標記檔放 root-only 的 `$RUNDIR`、只 `logger`;READALL 行為寫明了(實作時要確認 S10 時 `$RUNDIR` 已存在) |
| m7 | partial | 寫了要進 git、當建置閘門和發行清單閘門;但閘門放錯地方,見 n2 |
| m8 | addressed | L1 負對照改用 bench 的 `flash-card.ps1` 燒卡 |
| m9 | addressed | 誠實界線補了 OTP / secure-boot 鎖、GPS BBR、硬體植入;殘項補了 GPS 型號 |

## 5. PR 要求

n1 → PR-P3;n2 → PR-F;n3 → 下一次改文件時順手修。
