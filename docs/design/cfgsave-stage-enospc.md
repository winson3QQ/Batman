# Design: batman-config-save — p5 寫不完整時不得說 "saved"(stage ENOSPC / EROFS / EIO)— **v6**

狀態:v1(commit 6d65ecd)兩位 APPROVE-WITH-CHANGES(`cfgsave-reviews/review-A.md`、`review-B.md`)。v2(b869e61):A APPROVE-WITH-CHANGES(1 MAJOR + 6 MINOR,`review-A-r2.md`)、B APPROVE(4 MINOR,`review-B-r2.md`)。v3(ec8b79a):A APPROVE(`review-A-r3.md`)、B APPROVE-WITH-CHANGES(`review-B-r3.md`,無 MAJOR)。v4(4a93ba2):A APPROVE(`review-A-r4.md`)、B APPROVE-WITH-CHANGES(1 MAJOR,`review-B-r4.md`)。v5(3781b00):B APPROVE(4 MINOR,`review-B-r5.md`)、A APPROVE-WITH-CHANGES(1 測試 MAJOR + 2 MINOR,`review-A-r5.md`)。v6 處理 v5 審查的項目,§10 逐條列處置(五輪)。基準:`origin/main` 4eba26d;`batman-config-save` sha 936fa8cf…(`deploy/` 與 `feed/` 兩份相同,由 `scripts/check-provisioning-sync.sh` + `.github/workflows/provisioning-sync.yml` 強制一致)。目標版本 v1.6.0。

## 0. 一句話

`batman-config-save` 的寫入模式只有 `set -u`,staging 的每一步都沒檢查。p5 滿、唯讀或 I/O 錯誤時,失敗的 `cp` / redirect 留下 **0 byte 的 stage 檔**,publish 再把它 rename 蓋過 p5 上好的檔案,最後仍印 `saved`、rc 0。只有資料區塊寫失敗(journal 正常)時,舊版與 v1 都把**全 NUL** 的檔案發佈出去並說 `saved`(審查 A-F1)。

v2 的修法:
1. staging 每一步檢查,並與來源比對(page cache 層級:證明 `write()` 成功);
2. 所有需要新 block 的東西在第一個 rename 前配置好;
3. **第一個 rename 前對每個 stage 檔 `fsync`**(證明資料到了卡上;清單要完整、沒有 `fsync` 工具就不存);
4. publish 只剩 rename,每個都檢查;
5. `sync` 後用一次寫入探針抓 journal / metadata 的 writeback 錯誤。

任何失敗 → **rc 15、不印 `saved`、最後一行 stderr 說明哪一步、p5 是否未變**;`--on-join` 之後退避 300 s。

範圍(誠實版):偵測到的是 `write()` 失敗、`fsync()` 失敗、rename 失敗、以及 sync 後 journal abort。偵測不到的是探針**之後**(umount 時)才發生的錯誤,以及卡本身謊報寫入成功。

## 1. 重現(修之前,離線,真腳本)

WSL Ubuntu-24.04 root,loop ext4(`mkfs.ext4 -b 4096 -L batconfig`,同 `scripts/build-ab-image.sh:202`),`busybox sh` + busybox applets。先 `--seed` OLD,live 改成 NEW,把 p5 填滿後釋放 K 個 4 KiB block:

| 模式 | K | 舊行為 | 下次開機 96 |
|---|---|---|---|
| `--on-join` | 1–9 | rc 0 `saved`;`overrides.uci` **與** `lkg/overrides.uci` 皆 0 B;K=2–8 `shadow-root` 0 B;K=3 兩把 host key + `authorized_keys` 0 B | 選 lkg、fragment 為空 → image 預設;root 密碼 / host key / authorized_keys 被 SKIPPED |
| `--save` | 1–10 | rc 0 `saved`;`overrides.uci` / `schema_version` 0 B,lkg 仍是更舊的 OLD | 退回 lkg → 這次與 lkg 之後所有未 promote 的 `--save` 都丟失 |
| 兩者 | 0、ro | rc 1(只是因為 `: >` 是 special builtin,redirect 失敗讓 shell 直接結束 —— 意外的 fail-closed) | OLD |
| 任一 | 只有資料區塊寫失敗(審查 A E4) | rc 0 `saved`;remount 後 overrides / shadow-root / authorized_keys 全 NUL(v1 也一樣) | overrides 被 valid_batch 擋 → lkg;全 NUL 的 `authorized_keys` 蓋掉 operator key |

根因在 staging:`mkdir -p` / `cp -a` / `printf >>` / `echo >` 失敗都被忽略,busybox `cp` 寫入失敗時留下 0 B 目標檔;資料寫入錯誤在 `sync` 時才出現,而 busybox `sync` 不回報。publish 的 `mv` 不是問題(`STAGE="$MNT/.stage.$$"` 與 p5 同一檔案系統,rename 不需要新的資料 block)。

現場機率:ENOSPC **極低**。p5 512 MiB(`scripts/build-ab-image.sh:136`),一次存檔 < 2 KB 加上 ≤ 64 KiB 的 prov.cbor;只有本腳本寫 p5(`99-batman-chanfix:28`、`batman-prov-lock:39`、`batman-autocommit:434` 都是唯讀掛載)。**SD 卡局部寫入錯誤**是較可能的觸發(資料區塊壞、journal 正常),後果相同(mesh key、root 密碼、operator key 全失)。

## 2. Ownership

| 資源 | 唯一寫者 | 讀者(唯讀) |
|---|---|---|
| p5 的 `overrides.uci`、`lkg/overrides.uci`、`schema_version`、`identity/{dropbear,openmanet,shadow-root}`、`.seeded`、`.stage.<pid>/`、`.wprobe` | `batman-config-save` 寫入模式,持 `cfgsave.lock`(`batman-config-save:239-275`) | `96-batman-config-migrate`(開機)、`--check`、`99-batman-chanfix`、`batman-prov-lock`、`batman-autocommit`、`batman-slot` precheck |
| p5 的 `prov.cbor` / `prov.meta` / `identity/prov/` | `--prov-only`(本次不改) | 同上 + `--prov-get` |
| `$RUNDIR/cfgsave-onjoin.state`(on-join 快取) | `batman-config-save` | `batman-config-save` |
| **新** `$RUNDIR/cfgsave-save.failed`(`<uptime> <step>`) | `batman-config-save`:`not_saved` 寫、任何成功刪 | `batman-config-save --on-join`(退避) |

新暫存名(`$STAGE/lkg.uci`、`$STAGE/.seeded`、`$MNT/.wprobe`)都在本程序持鎖期間、私有掛載點(`$RUNDIR` 0700 下的 `tmpd`)內建立。

**清除殘留**:rw 掛載驗證成功後,若持鎖(`LOCK_MINE=1`),刪除 `$MNT/.stage.*` 與 `$MNT/.wprobe.*`(`:396-398`)。持鎖證明它們的寫者已不在(一次只有一個寫者);沒鎖(`RDOK=0`)時不刪,因為可能有別的寫者正擁有它。`rm -rf` 不跟隨 symlink;p5 只有 root 能 rw 掛載。

## 3. 契約變更

**新 rc 15**(寫入模式 `--seed` / `--save` / `--if-healthy` / `--on-join`):p5 **沒有**存好。

- **最後一行 stderr** 是說明:`batman-config-save: p5 NOT saved: <step> failed — <state> (<N> KiB free on p5)`。它是最後一行,因為 stage 在印之前就刪掉,cleanup 的 `rm` 也靜音(審查 A-F6)。另有一行 syslog `daemon.err`。**不印 `saved`**。
- `<state>`:
  - 任何 rename 之前的失敗(staging、預先配置、fsync)→ `p5 is unchanged`(並移除這次建立的空目錄);
  - 第一個 rename 回 0 之後才失敗 → `p5 may be PARTLY updated (each file whole; an I/O error may have kept the last committed state)`(`PUB` 旗標,審查 A-F7)。用「may be」:rename 回 0 只代表記憶體裡成功,journal 在 rename 迴圈中途 abort 時,卡上仍是上一次 commit 的狀態(審查 A-r2 F1:6 個案例中觀察到 1 次 p5 其實未變);read-only remount 則保留已完成的 rename(真的部分更新,測試兩種都驗);
  - `.seeded` rename 失敗 → `p5 may be PARTLY updated and is still unseeded`;
  - sync 後探針失敗 → `p5 holds its last committed state (most likely the old one)`。
- 文字不猜原因(審查 B MINOR-4):只寫哪一步失敗,空閒 KiB 只當作資料附上。`cmp` 不一致也可能是來源在 `cp` 與 `cmp` 之間被改寫;那是短暫的,fail-closed 就是對的。
- staged overrides 過不了 boot reader 的檢查(`batch_ok`)時,step 是 `the boot reader's check of the staged overrides (valid_batch would reject them at boot)`,不與 I/O 失敗共用文字(審查 A-F5)。

**`--check` 的新文字**(審查 A-F2):建不出比對用的 stage 時,回 **rc 5** `p5 stale: unverifiable (<why>)`(`:539-542`),而不是 rc 1。另外兩種「p5 讀不到」也回 rc 5(v4,審查 B-r2 MINOR-2、B-r3 MINOR-1 / MINOR-4、A-r3 F1):
- superblock **讀不到**(`hexdump` 失敗或沒有輸出;可讀的裝置一定印出 4 個 hex,歸零的也是 `0000`)→ `p5 stale: unverifiable (p5 unreadable: the superblock read failed)`。以前這裡回 rc 3 `SKIP not-ext4`,而 batman-slot 對 rc 3 放行;壞卡最常見的樣子就是讀取 EIO。`--prov-get` 則回它自己表中的「p5 unreadable」rc 1(helper 對 rc 1 保留 overlay,`boot.go:259-263`),不是 12。rc 3 / 12 只留給「讀到了,但不是 ext4」。
- magic 是 ext4、但 `ro,noload` 掛載連續 3 次失敗時,先查 p5 是否已被別人掛載(v5,審查 B-r4 MAJOR-1):
  - **更正 v4 的錯誤說法**:v4 寫「`ro,noload` 掛載一個已掛載的 ext4 會共用 superblock,不會失敗」。這只在既有掛載是**唯讀**時成立;既有掛載是 **rw** 時,第二個 `ro,noload` 掛載回 EBUSY(審查 B-r4 R6:util-linux rc 32「already mounted」、busybox rc 255「Device or resource busy」,kernel 6.6)。這種 p5 是健康的:寫入者在 EXIT trap 前被 SIGKILL 留下的 rw 掛載、操作員的除錯掛載、沒有鎖的寫入者。
  - 所以:在 `/proc/self/mountinfo` **只用 major:minor** 找 p5 的整個檔案系統掛載(root 為 `/`,不是我們自己的掛載點;`p5_mountinfo root`)。v5 也比對 source 名稱,但名稱什麼都證明不了:任何檔案系統都能用那個字串當 source 掛載(審查 B-r5 MINOR-1;測試:一個 source 叫 p5 的 tmpfs)。
  - 找到了 → **不經由那個路徑讀**(上面可能疊了別的掛載,也可能在讀的途中被換掉):把那個掛載 `mount --bind` 到**我們自己的**私有掛載點、`remount,bind,ro`(只改我們這個 bind 的旗標,不動 p5 的 superblock),再要求我們自己那一行 mountinfo 是 p5 的 major:minor、root `/`,才比對;任何一步失敗 → rc 5 `p5 stale: unverifiable (p5 busy (mounted at X) and could not be compared)`。比對成功時先印一行 `p5 is mounted at X by another process — compared through a read-only bind of that mount`,再給真正的 fresh / stale 判定(測試:疊在掛載點上的 tmpfs 不會被讀到)。
  - **「fresh」的意義**:經由另一個 rw 掛載比對時,fresh 代表那個掛載**目前的內容(含 page cache)**等於 live,不一定已經寫到卡上(審查 B-r5 MINOR-3)。
  - p5 只剩一個**子目錄的 bind** 還掛著(整個的掛載已卸下,superblock 仍被 rw 持有)→ 沒有整個樹可比對 → rc 5 `p5 stale: unverifiable (p5 busy (held by a bind mount of a part of it at X) and could not be compared)`,不是「does not mount」(審查 B-r5 MINOR-2)。
  - 只有「**沒有掛在任何地方**而且掛不上」才是 `p5 stale: unverifiable (p5 does not mount read-only: <mount 自己的錯誤,一行>[; a save failed earlier this boot: <step>])`,**不需要**失敗標記(審查 A-r4 F1:錯誤訊息保留,EBUSY 與損壞分得出來)。#202 防的暫時性失敗是 rw 掛載撞上唯讀讀者(T11)。LUKS p5 沒有 ext4 magic,不會走到這裡。這也蓋住了「最後一次存檔之後卡才壞、沒有標記」的情況(審查 A-r3 F1)。

兩者在新槽的 96 也同樣讀不到 p5,所以 OTA 不該放行。
- batman-slot 對 `p5 stale: unverifiable` 有自己的拒絕文字(`batman-slot:576-579`,審查 A-r2 F6):`p5 (config) freshness cannot be verified (<why>) — refusing an OTA; '--save' does not fix this. If /tmp is full …, free it and retry; if p5 does not mount, the card needs attention`,加上 allow-stale-p5 的覆寫方法;不再顯示「Run --save」的 `P5_STALE_HINT`。測試在 `tests/prov-p1/slot-p5gate-txn.sh`(4eba26d 的 batman-slot FAIL 2 條)。
- 理由:`batman-slot:559-588` 對 rc 5 擋 OTA(`:577`,可用 allow-stale-p5 覆寫,`:571`);對 rc 1 走 `*)`,沒有 `cfgsave-mount.failed` / `cfgsave-lock.busy` 時是 `skip:error … not blocking`(`:587`)——fail-open。
- p5 沒有被**證明**是最新的,OTA 就不該在沒有人工覆寫的情況下進行。舊版在 /tmp 滿時意外回 rc 5(0 B stage ≠ p5),v1 把它變成 rc 1(審查 A E3);v2 明確回 rc 5。
- 其他讀 `--check` 的呼叫者:helper `parseCheck` 把 rc 5 + `p5 stale` 當成「stale」(`status.go:52-58`);`onlyP3Stale` 只在每個項目都是 P3 key 時才自動 save,`unverifiable (…)` 不是(`status.go:67-80`);`halow-setkey:231` 的 `--check || p3_persist` 會去做一次 `--save`(stage 在 p5 上,不在 run dir)。

**呼叫者對 rc 15 的處理**(逐一查過,沒有一個把 15 當成功):

| 呼叫者 | 怎麼處理 | 15 的效果 |
|---|---|---|
| `halow-setkey:184-189` | `0` saved、`6` PARTIAL、`*` → `persist: FAILED (<最後一行>)`、RC=3 | FAILED,顯示 `p5 NOT saved …` |
| `halow-setkey:228,231,257,309,323`(`p3_persist`) | 只看成功 / 失敗 | 失敗 → 走既有回復路徑 |
| `node.go:843-846` `persisted(rc)` = `rc == 0 \|\| rc == 6` | 其他 rc = 沒存 | 沒存(部分發佈時也是:保守方向) |
| `node.go:477-478` `cfgSaveBusy` | 只有 rc 1 + "another batman-config-save" 才重試 | 不重試 |
| `node.go:536`、`:1303`、`:1353`、`wtxn.go:369` | `rc != 0 && rc != 6` → 失敗 / `.txn` 保留、稍後再 finish(有上限的 bootRetry) | 失敗,`.txn` 保留 |
| `cmd/batman-provhelper/status.go:142` `upgradeSave` | 只 log | log |
| `joinwatch:164` | `>/dev/null 2>&1`,不看 rc | 不變;之後的 tick 在 300 s 內退避(rc 1,不掛載) |
| `batman-slot:559-600` | 只呼叫 `--check` | 寫入失敗後 `--check` 回 5 stale → OTA 被擋 |

**`--on-join` 退避**(審查 B MAJOR-1 / A-F4):`not_saved` 寫 `cfgsave-save.failed`。`--on-join` 在 300 s 內看到它就 `p5 save failed Ns ago (<step>) — backing off`、rc 1、不掛載(`:349-354`,與 `MNTFAIL` 同形)。任何成功(寫入或 `unchanged`)都刪除它(`:634,692`)。其他寫入模式不看它:操作員的 `--save` 永遠會嘗試,成功就解除退避。syslog 因此最多每 300 s 一行。

**on-join 快取**:`onjoin_record` 只在成功出口呼叫(`:637,700`,不變);`not_saved` 另外 `rm -f "$ST"`(測試:好的 tick 寫入快取,失敗的 tick 移除它)。

**UNSAFE 加入換行**(審查 A-F5 / B MINOR-1,`:58-64`):含換行的值會讓它的 `set` 行斷開,boot reader 會拒絕整個 batch。現在它走 #202 T4 的既有規則(v2 也把 CR 加了進去,v3 拿掉:CR 不會斷行,節點的 `uci batch` 原樣保存並還原它,96 的 `valid_batch` 也接受;v1 能存的值 v2 卻會擋 OTA,審查 A-r2 F2):
- 該值列入 `REJECTED`,rc 6,stderr 報出 key,其餘照存;
- `--check` 報 `stale … unpersistable`(batman-slot 已有對應訊息);
- ssid 依 `SKIP_UNSAFE` 不存也不算 stale。

`batch_ok` 仍保留為最後一道檢查(防禦縱深;正常輸入已無法觸發,測試用白箱觸發)。

**fail-closed 的理由**:寫不完整的 p5 會在下一次跑 96 時(OTA 到新槽、overlay 清除、重燒卡)丟掉 mesh key / root 密碼 / host key;報錯並保留舊 p5 永遠比較安全。舊 p5 仍是完整、自洽的設定,`--check` 繼續報 stale,OTA gate 繼續擋。

## 4. 修法(`feed/batman-provision/files/usr/bin/batman-config-save`,`deploy/` 同步)

1. **`stage_overrides`**(`:467`)回傳 rc:1 = 寫入失敗或 stage 與來源不同;2 = `batch_ok` 拒絕。
   - 每個 `mkdir` / `cp -a` 後接 `cmp -s 來源 stage`;shadow 行寫完後比對;`overrides.uci` 在記憶體組好(位元組與舊寫法相同)、寫一次、`printf | cmp -s -` 比對,再過 `batch_ok`(`:502`,96 `valid_batch()` 的 awk 原文,lint 保證一致);`schema_version` 寫完比對。
   - 這些 `cmp` 讀的是 page cache:它們證明 `write()` 成功,不證明資料在卡上;卡上由步驟 4 的 fsync 證明(審查 B MINOR-5)。
   - 不再用 `: >`(special builtin 的 redirect 失敗會直接結束 shell)。
2. **`--check`**:`stage_overrides` 失敗 → rc 5 `p5 stale: unverifiable (…)`(`:539-542`)。
3. **預先配置**(`:660-669`):p5 上缺的目錄(`mkd`,記下自己建的,失敗時 `rmdir`)、lkg 副本先在 stage 內 `cp -a` + `cmp`、首次 seed 的 `.seeded` 先在 stage 內建立。
4. **fsync**(`:675-676`,審查 A-F1):stage 內每個檔案 `fsync`;失敗 → `not_saved "fsync of the stage (<file>)"`,此時 p5 尚未改變。
   - 節點的 busybox 有 `fsync` applet:兩個 SoC 的 build `.config` 都是 `CONFIG_FSYNC=y`、`# CONFIG_FEATURE_SYNC_FANCY is not set`;shipped rootfs 有 `/bin/fsync`。
   - 它的 `sync_common()` 在 `fsync()` 失敗時回 `EXIT_FAILURE`(`busybox-1.36.1/coreutils/sync.c`,同一個 build tree)。
   - **沒有 `fsync` 工具 = fail-closed**(`:687`,審查 A-r2 F3 / B-r2 MINOR-3):rc 15 `fsync of the stage (no fsync tool on this system)`。v2 的 `sync FILE` 退路在沒有 SYNC_FANCY 的 busybox 上會忽略 FILE、回 0(`sync.c` 的 `bb_warn_ignoring_args(argv[1]); sync(); return EXIT_SUCCESS`;審查 A-r2 NM 實測:節點 busybox 走退路時 data-only ×5 都 `saved rc=0`)。離線 harness 自己在 PATH 放 `fsync` shim(coreutils `sync FILE`,同一個 syscall):本測試與 `cfgsave-txn-save`、`cfgsave-identity-freeze`、`cfgsave-frozen-nomount`、`prov-p3/cfgsave-ssid`。
   - **清單要完整**(`:688-690`,審查 A-r2 F5):`find` 的 rc 要檢查,檔數要等於 identity 檔數 + overrides + schema(+ lkg,+ `.seeded`),否則 rc 15 `listing the stage for fsync (N files, want M)`,這時還沒有 rename。
5. **publish 只剩 rename**,每個都檢查,第一個成功後 `PUB=1`。`mv "$STAGE/schema_version" "$MNT/schema_version"` 這一行保持原文(`tests/prov-p1/sbx/cases/cfgsave.sh` 的 onjoin-prov mutant 以它為錨點),下一行檢查 stage 檔已不在。`.seeded` 仍最後(DR-2)。
6. **`sync` 後寫入探針**(`:690`):journal / metadata 的 writeback 錯誤會 abort journal;busybox `sync` 回 0、`/proc/mounts` 仍是 `rw`,但下一次建立檔案立刻 EROFS / EIO(實測 WSL 6.6,§6)。
7. **其他**:`--on-join` 退避(`:349-354`)、殘留清除(`:396-398`)、cleanup 靜音(`:139`)、UNSAFE 加換行(`:58-64`)、`--check` 掛不上 + 已失敗 → rc 5(`:415-422`)、batman-slot 的 unverifiable 文字(`batman-slot:576-579`)。
8. **沒有改的**:`final_rc`、rc 6 語意、lkg 輪替規則(N-R8)、鎖、mount 驗證、`--prov-only` / `--prov-get`、`--check` 的判定邏輯(只改它建不出比對時的回應)。

## 5. Lifecycle

| 路徑 | 今天(4eba26d) | 之後 | 測試 |
|---|---|---|---|
| 首次 seed(`--seed`,未 seed 的 p5) | 滿時印 saved、身分檔缺 / 0 B | 存好,或 rc 15 + p5 未變(仍 unseeded,不留空目錄) | `--seed K=0,2,5,9,12`、data-only、control |
| `--save` | K=1–10 印 saved、overrides 0 B;data-only 印 saved、全 NUL | 存好或 rc 15、p5 位元組相同 | `--save K=0..12`、ro、EIO×5、control |
| `--save --promote-lkg` | 同上 + lkg 0 B | 同上 | `K=1,4,8`、data-only |
| `--on-join` | K=1–9 兩份都 0 B、快取記成功;壞卡上每 tick 重試 | 存好或 rc 15、快取不記、之後 300 s 退避 | `--on-join K=0..12`、ro、EIO×5、control、退避、快取 |
| `--if-healthy` | 同 on-join(無快取) | 存好或 rc 15 | `--if-healthy K=0..12`、ro、EIO×5、control |
| OTA precheck `--check` | 寫入失敗後 rc 5;run dir 滿時意外 rc 5 | 寫入失敗後 rc 5;run dir 滿時 rc 5 `unverifiable` | 每個案例後的 `--check`;run dir 滿 |
| 重開 / 斷電 / SIGKILL 在 staging 中 | p5 未變,`.stage.<pid>/` 永久殘留 | p5 未變;殘留在下一次持鎖寫入時刪除 | 預放 `.stage.99999` + `.wprobe.99999` 於滿的 p5;ro 跑完的殘留被下一次 save 刪 |
| 斷電在 publish 中(rename 之間) | 部分新部分舊,每檔完整 | 同(資料已 fsync,rename 原子) | 不新增 |
| 卡持續壞 / 滿 | on-join 每 15 s 掛載 + 寫 + log | 每 300 s 一次 | 退避案例 |
| 升級到含修正的版本 | — | p5 格式不變,無遷移;舊版留下的 `.stage.*` 會被清掉 | 殘留案例 |
| 降級 / 回滾到舊版 | — | **無作用**:p5 檔案格式、檔名、內容位元組都不變;`cfgsave-save.failed` 在 tmpfs 的 run dir,舊版不讀。新增的暫存名只在同一次執行內存在 | 不需(格式不變) |
| 依賴重啟(joinwatch / helper) | — | 退避標記在 run dir,重開機即清除 | — |
| 平台 bcm2710 / bcm2711 | 同一支 shell | 同;兩個 build 都有 `fsync` applet | busybox ash;節點 busybox 在 qemu 下跑過完整測試(§8) |

## 6. 依賴的行為與證據

- busybox ash 中 `: > 不存在路徑` 讓 shell 結束,包在 `{ }` 裡也一樣;`printf '' >` 失敗只回 rc 1:WSL busybox 1.36.1 實測(`survived_printf rc=1`、`colon shell rc=1`)。
- busybox `cmp -s -` 讀 stdin:同上實測。
- ash 的 glob `case` 中,bracket 內的換行可以比對:WSL busybox、dash,以及**節點的 busybox**(OpenWrt 24.10 build,aarch64,qemu-user)都實測 `line1\nline2 => UNSAFE`、tab / 空白 => ok。
- CR:節點的 `uci`(qemu)`uci batch` 一行 `set wireless.default_radio1.key='abc\rdef'` → `batch rc=0`、`commit rc=0`、`uci get` 讀回 `a b c \r d e f`;節點 busybox awk 跑 96 的 `valid_batch`:CR 行 rc 0、換行拆開的行 rc 1(審查 A-r2 CR 實驗)。本測試:CR 值 `--save` rc 0、overrides 的那一行位元組相同、reader 選 overrides@1、`--check` 0。
- 節點 busybox 的 `fsync`:`<home>/firmware-2710/build_dir/target-aarch64_cortex-a{53,72}_musl/busybox-default/busybox-1.36.1/.config` 都是 `CONFIG_FSYNC=y`;shipped rootfs(`p2-rootfs-squashfs.img`,DISTRIB_REVISION r28739)有 `bin/fsync`;`coreutils/sync.c` 的 `sync_common()` 在 fsync 失敗時印錯並回 `EXIT_FAILURE`。
- 只有資料區塊寫失敗時:`busybox sync` rc 0、`sync -f` rc 0、建檔探針 rc 0,但 `sync FILE`(fsync)rc 1、O_DIRECT 讀回不符(審查 A E6)。v2 測試的 data-only 案例:修正版 rc 15 `fsync of the stage (…) failed`。
- journal / metadata 的 writeback 錯誤後:busybox `sync` rc 0、`/proc/mounts` 仍 `rw`、立即建檔 EROFS(dm-flakey `error_writes` 實測:`busybox sync rc=0`、`opts after sync: rw,relatime`、`immediate probe rc=1 … Read-only file system`、dmesg `Detected aborted journal`)。
- `dmsetup suspend` 沒有 `--nolockfs` 時會凍結檔案系統並先寫完 dirty data(審查 A F1 推論,dmsetup(8));v2 的「stage 仍 dirty」案例用 `--nolockfs --noflush`,修正版在 fsync 那一步失敗,證實錯誤確實在 stage 資料落碟前就開始。
- 96 的 `valid_batch` 接受空檔案,選檔順序 overrides@schema → lkg:`96-batman-config-migrate:33-47,211-215`。
- 呼叫者的 rc 處理:§3 表格的 file:line。

## 7. Security

- **資產**:p5 上的 mesh key、AP key、root 密碼雜湊、SSH host key、`authorized_keys`。舊行為下,一個能把 p5 填滿的人(本機 root 才能 rw 掛載 p5)或一張局部壞的卡,可以讓下一次 OTA / 重燒後節點變成 UNPROVISIONED(開放)或失去 operator key;新行為下 p5 保持舊值。
- **新輸入面**:
  - `$RUNDIR/cfgsave-save.failed`:root 0700 run dir 內,`-O` 檢查擁有者;內容只解析數字 uptime,其餘只印出。
  - 刪除 `$MNT/.stage.*` / `.wprobe*`:在私有掛載點內、持鎖、`rm -rf` 不跟隨 symlink。
  - 沒有新的環境變數或參數。
- **權限**:不變(root)。
- **秘密**:錯誤訊息只含步驟名、檔名(stage 內的相對路徑)與 KiB 數,不含值;`batch_ok` 不輸出內容。殘留的 `.stage.*`(含 host key 與 shadow 雜湊副本)現在會被清除,不再比金鑰輪替活得久(審查 B「our own mistakes」)。
- **失敗模式**:fail-closed(不寫、報錯、舊 p5 保留、`--check` stale → OTA 擋)。沒有 `fsync` 工具也是 fail-closed(v2 的 `sync FILE` 退路已移除)。v3 刻意保留的 fail-open(`--check` 掛不上 p5、沒有標記時回 rc 1)已在 v4 移除:讀不到的 p5,以及沒有掛在別處、自己也掛不上的 ext4 p5,都回 rc 5,操作員要 OTA 必須明確使用 allow-stale-p5。健康但忙碌的 p5(已被別人 rw 掛載)經由既有掛載的唯讀 bind 正常判定(v5 / v6),不會被誤擋。已知的邊角(fail-closed,有覆寫):只剩子目錄 bind 持有的健康 p5、掛在 mountinfo 會跳脫的路徑上的 p5、以及 bind 之後驗證不到 p5 的情況,都回 rc 5「busy … could not be compared」,操作員可以卸下那個掛載或用 allow-stale-p5。p5 的 umount 失敗(cleanup、存檔之後)現在會記一行 `daemon.warn`,原因看得到(審查 A-r5 F3)。`--seed` 遇到讀不到的 superblock 拒絕、不 mkfs(v5):對一張正在壞的卡格式化只會毀掉 p5。
- **負向測試**:`tests/prov-p1/cfgsave-stage-enospc.sh` 對 4eba26d 與 6d65ecd 的腳本都 FAIL(§8),並逐一用 mutant 證明各部分有測到。

## 8. 測試

`tests/prov-p1/cfgsave-stage-enospc.sh <batman-config-save>`(root;loop + device-mapper)。接進 `.github/workflows/ci.yml` prov-p1 job **自己的 step**(`!cancelled()`,先 `modprobe dm_flakey`,不行就裝 `linux-modules-extra-$(uname -r)`;沒有 dm-flakey 時只紅這一步,不會跳過其他 loop-device 測試,審查 B-r2 MINOR-1),以及 `scripts/test-prov-p1-stubs.sh` 的 root 區塊(daily-validation suite `prov-p1-stubs`)。兩處都設 **`CFGSAVE_REQUIRE_DM=1`**:沒有 dm 或 dm-flakey 就 FAIL,不是跳過(審查 B MAJOR-2)。

**故障矩陣**(每個模式):
- K = 0..12 個空閒 block(先探針確認 ENOSPC,設不出來 = FAIL);
- staging 後 `remount,ro`;
- staging 後整個裝置變 dm `error`,也測一次停 6 s 再變(讓一次 journal commit 落在中間,審查 A-F3 的確定性版本);
- staging 後 dm-flakey `error_writes` + `suspend --nolockfs`(stage 資料仍 dirty);
- fsync 之後、rename 之前 dm-flakey `error_writes`(只剩 journal / metadata 會失敗 → 探針);
- 只有資料區塊失敗(seed 後所有空閒 block `error_writes`,其餘 linear;審查 A E4)。

dm 的切換一律 `load → suspend → resume`,任何一步失敗都 `resume`(load 只寫 inactive table;先 suspend 再 load 失敗會讓裝置停在 SUSPENDED,之後所有 I/O 卡死,審查 A-r2 F7)。

**斷言**:每個案例都必須是下面兩種結果之一,而且任何分支都不得有 0 B 檔(`.seeded` 與壞裝置上留下的 stage 除外)。
- saved:rc 0,p5 = NEW,reader 讀 NEW,`--check` 0;
- not saved:rc 15,最後一行 stderr 是說明,p5 位元組相同,reader 讀 OLD,`--check` 5,無快取,下一個 tick 不 `unchanged`。p5 未變時不得說 PARTLY;例外是 I/O 錯誤類(eio*、datafail)可以說「may be PARTLY」(journal abort,審查 A-r2 F1)。

**其他案例**:
- run dir 滿時 `--check` rc 5 `unverifiable`;
- `--on-join` 退避:第 1 tick rc 15、第 2 tick rc 1 且 ext4 mount count 不變、把標記調早 301 s 後第 3 tick 再嘗試、成功的 `--save` 解除;
- 預放的 `.stage.99999`(40 block)+ `.wprobe.99999` 在滿的 p5 上被刪,存檔因而放得下;
- ro 失敗留下的 stage 被下一次 save 刪除;
- on-join 快取被失敗的 tick 移除;
- hostname 含換行 → rc 6、其餘存好、`--check` 5;ssid 含換行 → rc 0、不存、`--check` 0;mesh key 含 CR → rc 0、該行位元組原樣存下、`--check` 0;
- 第一批 rename 之後(hook 3)read-only remount → rc 15「may be PARTLY」、identity 是 NEW、overrides 是 OLD、每個檔案都是 OLD 或 NEW 的完整副本;同一點 dm-flakey `error_writes` → rc 15、每個檔案 OLD 或 NEW(審查 A-r2 F1 的確定性版本);
- 沒有 `fsync` 工具(用主機的 busybox sh 跑,PATH 裡拿掉 shim)→ rc 15「no fsync tool」、p5 未變;
- fsync 前 stage 少一個檔(hook 4 刪掉 `lkg.uci`)→ rc 15「listing the stage for fsync (7 files, want 8)」、p5 未變(審查 A-r2 F5);
- 「最後一行是說明」的確定性對照:`chattr +i` 一個 stage 檔,它的 rename 和之後所有 `rm` 都必定失敗(審查 A-r2 F4);
- `--check`:ext4 p5 的 superblock 壞掉(magic 保留):沒有失敗標記 → rc 5「unverifiable (p5 does not mount read-only)」;有標記 → rc 5 並寫出那次失敗的步驟(審查 B-r2 MINOR-2 / B-r3 MINOR-4);
- `--check`:整個裝置換成 dm `error` 並 `blockdev --flushbufs`(superblock 讀不到):有沒有標記都 rc 5「p5 unreadable」;`--prov-get` rc 1。對照:歸零(可讀、非 ext4)的 p5 → `--check` rc 3「SKIP not-ext4」、`--prov-get` rc 12(審查 B-r3 MINOR-1);
- `tests/prov-p1/cfgsave-txn-save.sh` 的「掛不上的 p5、沒有 .txn」對照改成期待 rc 5 unverifiable;
- `tests/prov-p1/slot-p5gate-txn.sh`:batman-slot 對 `p5 stale: unverifiable` 用自己的拒絕文字、不顯示 `P5_STALE_HINT`、allow-stale-p5 可覆寫(審查 A-r2 F6);
- 白箱:PRESERVE 多一個 96 不收的 package → rc 15「boot reader」訊息、p5 未變;
- lint:`batch_ok` awk == 96 `valid_batch` awk。

**v5 新增案例**:測試的副本改用真名 `batman-config-save`(鎖的 cmdline 檢查要認得正在跑的寫入者,與節點相同;審查 B-r4)。健康但忙碌的 p5:被別人 rw 掛載(p5 == live → rc 0 fresh;live 改過 → rc 5 真正的 stale,不是 unverifiable)、被別人 ro 掛載(rc 0 fresh)、掛在 mountinfo 會跳脫的路徑(rc 5「busy … could not be compared」)、一個存檔正持鎖(rc 8 lock-busy,那個存檔隨後 rc 0)。「掛不上」的文字帶 mount 的錯誤。`--seed` 遇到讀不到的 superblock:拒絕、沒有 `formatting` 行、p5 不變;對照:歸零的 p5 照常 format + seed。

**v6 測試框架**(審查 A-r5 F1 MAJOR / F2、B-r5 MINOR-4):
- 一台主機同時只跑一個實例:`flock` `/run/cfgsave-stage-enospc.lock`,有上限地等待(預設 1800 s),逾時就 FAIL;
- dm 裝置用這次執行自己的 mktemp 目錄命名(`cfgenospc-tmp.XXXXXX`),不用 `$$`;
- 每次 mkfs、每次切換 dm 表之前先 `udevadm settle`;
- 每個案例開始時,裝置若仍被掛載就讓那個案例 FAIL,並印出 mountinfo、holders、各 pid 的 mountinfo、`fuser`;setup 的掛載失敗也印這些;
- mkfs 只在裝置**沒有**掛在本 namespace 時有上限地重試(15 × 2 s),所以真的 umount bug 仍會立刻 FAIL;
- teardown:`udevadm settle` → `dmsetup remove --retry` → 證明 dm 裝置與 loop 都不在了;還在就印 `FAIL teardown: LEAK …` 並讓最後一行變成 `FAIL=…`(審查 A-r5 F1:沒有 `--retry` 時 40 次 remove 有 40 次因 udev 的探測而 EBUSY,裝置因此被留下)。

**v6 新增案例**:一個 tmpfs 疊在 p5 的掛載點上 → rc 5 busy(不從 tmpfs 判定);一個 source 名稱跟 p5 一樣的非 p5 檔案系統(內容是好 p5 的副本),而 p5 本身壞掉 → rc 5「does not mount」,不從那個假的判定;p5 只被子目錄 bind 持有 → 它自己的 rc 5 文字。

**結果 v6**(WSL 6.6,busybox 1.36.1,`CFGSAVE_REQUIRE_DM=1`,fresh clone 0fd4591;`/dev/null` 前後都是 character special file;開始前與結束後 `losetup -a` / `dmsetup ls` 都是空的):

| 執行對象 | 結果 |
|---|---|
| 修正版,連跑 10 次 | 10 次都 `PASS=106 FAIL=0`(107–125 s),每次 `host lock … taken after 0 s` |
| 兩個實例同時啟動 | 兩個都 `PASS=106 FAIL=0`;一個 `taken after 0 s`,另一個等了 112 s 才拿到鎖;共 225 s |
| 3781b00(v5)的腳本 | `PASS=80 FAIL=26`:新案例 ×3(疊在掛載點上的 tmpfs → rc 7、從 tmpfs 判定;source 名稱像 p5 的假檔案系統 → rc 0 fresh、從假的判定;子目錄 bind → 「does not mount」),另外 23 個 `setup mkfs`(見下面的外部持有) |
| 6d65ecd / 4eba26d 的腳本 | `PASS=74 FAIL=32` / `PASS=17 FAIL=89` |
| `slot-p5gate-txn.sh` | HEAD 與 3781b00 的 batman-slot `21/0`;6d65ecd / 4eba26d `21/2` |
| mutant v6 | 名稱比對放回:`105/1`(source 名稱像 p5 的假檔案系統被拿來比對,回 busy 而不是 does not mount);拿掉 bind 的驗證:`105/1`(疊上的 tmpfs 被讀到,rc 7) |
| 測試本身的 leak 檢查 | `CFGSAVE_TEST_LEAK=1`(結束時讓裝置保持開啟):真的測試印 `FAIL teardown: LEAK dm:cfgenospc-tmp.…(1 open) loop:/dev/loop0`,最後一行 `PASS=106 FAIL=1`,rc 1;拿掉 leak 檢查的測試 mutant 同樣情況是 `PASS=106 FAIL=0` rc 0(無聲)。兩次留下的裝置都由驗證腳本依「本次新增的 dm 名稱」移除 |
| 節點的 busybox(a72 build,qemu-user) | `PASS=106 FAIL=0`(975 s) |
| 全套 | `PROV-P1-STUBS stubs=27 fails=0`(`cfgsave-stage-enospc: PASS=106 FAIL=0`、`cfgsave-txn-save 59/0`、`slot-p5gate-txn 21/0`);h4 `19 passed, 0 failed` |

**v5 的 ❓(setup 時裝置「in use by the system」)有了證據**:在 3781b00 那一輪,`--on-join K=7` 到 `--save K=9` 的 23 個案例,mkfs 重試 15 次都失敗,之後自己恢復。新的 evidence 印出:dm 裝置 `Open 1`、沒有 holders、**本 namespace 沒有掛載它**,但 `/proc/2424576/mountinfo` 裡有它的 `254:0`。也就是說,**另一個 mount namespace 裡有這個裝置的一份掛載副本**:一個在我們的裝置剛好掛著時建立 mount namespace 的程序(`unshare -m` 一類),複製了那個掛載並一直持有,我們的 umount 傳不過去。那個 pid 在我查的時候已經結束,所以是哪個程序沒有查到;我自己的驗證腳本當時是循序執行,沒有在跑會建立 namespace 的東西。歸類:**已歸因到能查到的程度**——一個在我們的掛載存在時建立自己 mount namespace 的程序,複製了那個掛載並持有裝置;程序本身已結束,查不到是誰。產品不受影響:它只發生在測試的 setup,而且是 FAIL,不會變成假的 PASS。

**已加固(2d2f1fc)**:測試會以 `unshare -m --propagation private` 重新執行自己(標記 `CFGSAVE_PRIVATE_NS=1`,並確認自己的 mount namespace 與 pid 1 的不同),所以外面的程序複製不到它的掛載;沒有 `unshare` 時,在 `CFGSAVE_REQUIRE_DM=1`(CI、stubs runner)下是 setup FAIL。主機 flock 在 `/run`,namespace 之間共用,所以兩個實例仍然會排隊。加固後(fresh clone 2d2f1fc):
- 連跑 10 次:都 `PASS=106 FAIL=0`(107–122 s),mkfs 重試 0 次;
- 同時啟動兩個:兩個都 `PASS=106 FAIL=0`(各自的 namespace `4026532284` / `4026532285`,主機 `4026532217`),一個等鎖 120 s;共 238 s;
- 3781b00 的負向對照:`PASS=103 FAIL=3`,只剩那 3 個新案例的預期 FAIL,**`setup mkfs` FAIL 從 23 個變成 0 個**,mkfs 重試 0 次;
- 全套 `PROV-P1-STUBS stubs=27 fails=0`(`cfgsave-stage-enospc: PASS=106 FAIL=0`)、h4 `19 passed, 0 failed`;開始前與結束後 `losetup -a` / `dmsetup ls` 都是空的,`/dev/null` 是 character special file。
- private namespace 加上主機鎖,讓同一台主機上的執行一律排隊:一次約 110–125 s,有別的實例在跑時要等它(本輪等過 112–120 s,含等待約 200 s 以上)。CI 只跑一個實例,不會等鎖。

**結果 v5**(WSL 6.6,busybox 1.36.1,`CFGSAVE_REQUIRE_DM=1`,fresh clone e30f746;`/dev/null` 前後都是 character special file):

| 執行對象 | 結果 |
|---|---|
| 修正版(驗證腳本內 5 次) | 4 次 `PASS=103 FAIL=0`(99–115 s);**1 次在 2 s 內中止**(`PASS=3 FAIL=95`:K=1 的 setup 掛載回「already mounted or mount point busy」、mkfs 說裝置「in use by the system」,之後的 setup 全部失敗,並留下這次的 dm / loop 裝置)。❓ 未歸因:它緊接在上一次執行結束的同一秒開始;之後同一個 clone 連跑 8 次都 `PASS=103 FAIL=0`,沒有再出現 |
| 修正版,另外連跑 8 次 | 8 次都 `PASS=103 FAIL=0`(94–112 s) |
| 4a93ba2(v4)的腳本 | `PASS=97 FAIL=6`:健康但忙碌 ×3(rc 5 unverifiable)、掛不上的文字 ×2(沒有 mount 錯誤)、`--seed` 讀不到(嘗試 mkfs) |
| 6d65ecd / 4eba26d 的腳本 | `PASS=73 FAIL=30` / `PASS=17 FAIL=86` |
| `slot-p5gate-txn.sh` | HEAD 與 4a93ba2 的 batman-slot `21/0`;6d65ecd / 4eba26d `21/2` |
| mutant v5 | 拿掉忙碌偵測:`100/3`;`--seed` 不再拒絕讀不到的 superblock:`102/1`;拿掉 mount 錯誤文字:`101/2` |
| 節點的 busybox(a72 build,qemu-user) | `PASS=103 FAIL=0`(908 s) |
| 全套 | `PROV-P1-STUBS stubs=27 fails=0`(`cfgsave-stage-enospc: PASS=103 FAIL=0`、`cfgsave-txn-save 59/0`、`slot-p5gate-txn 21/0`);h4 `19 passed, 0 failed` |

**結果 v4**(WSL 6.6,busybox 1.36.1,`CFGSAVE_REQUIRE_DM=1`,fresh clone 45f47e2;`/dev/null` 前後都是 character special file):

| 執行對象 | 結果 |
|---|---|
| 修正版 ×5 | 5 次都 `PASS=96 FAIL=0`(78–96 s) |
| 4eba26d 的腳本 | `PASS=14 FAIL=82` |
| 6d65ecd 的腳本 | = 確定性清單 + 時序相關案例(見下) |
| `slot-p5gate-txn.sh` × 4eba26d / 6d65ecd 的 batman-slot | 兩者都 `cases=21 fails=2`;HEAD `21/0` |
| mutant v4 | 讀不到的 superblock 又當成 not-ext4:`93/3`(`--check` ×2 回 rc 3、`--prov-get` 回 12);掛不上又要求標記:`95/1`(沒有標記時 rc 1) |
| 節點的 busybox(a72 build,qemu-user) | `PASS=96 FAIL=0`(864 s) |
| 全套 | `PROV-P1-STUBS stubs=27 fails=0`(含 `cfgsave-stage-enospc: PASS=96 FAIL=0`、`slot-p5gate-txn 21/0`、`cfgsave-txn-save 59/0`);h4 `19 passed, 0 failed` |

**6d65ecd 的負向對照**:它 FAIL 的是「確定性清單」,加上時序相關案例。
- **確定性清單**(每次都 FAIL,因為 v1 沒有那個修正):data-only ×5、run dir 滿、退避、殘留 ×2、換行 ×2、白箱、no-fsync、stage-list(v1 沒有那一步)、immutable 最後一行、`--check` 掛不上 ×2、superblock 讀不到 ×3(`--check` ×2、`--prov-get`)、健康但忙碌 ×3(rw fresh、rw stale、跳脫路徑)、`--seed` 讀不到。
- **時序相關**:其餘「最後一行是說明」類案例(ro / eio / eiow),取決於 v1 cleanup 的 `rm:` 有沒有碰到壞掉的 block。

**結果 v3**(fresh clone 2aba4f0,保留作紀錄):

| 執行對象 | 結果 |
|---|---|
| 修正版 ×5 | 5 次都 `PASS=91 FAIL=0`(81–98 s) |
| 4eba26d 的腳本 | `PASS=13 FAIL=78` |
| 6d65ecd 的腳本 | 本輪 `PASS=70 FAIL=21`。因為「最後一行」類案例看 v1 的 `rm:` 何時出現,各次執行介於 16–21 FAIL(審查者 16、17、18,本輪 21);**每次都 FAIL 的確定性清單**:data-only ×5、run dir 滿、退避、殘留 ×2、換行 ×2、白箱、no-fsync、stage-list(v1 沒有那一步)、immutable 最後一行、`--check` 掛不上 |
| `slot-p5gate-txn.sh` × 4eba26d / 6d65ecd 的 batman-slot | 兩者都 `cases=21 fails=2`(unverifiable 的文字與 `P5_STALE_HINT`) |
| mutant v3(各拿掉一部分) | `sync FILE` 退路放回:`90/1`(no-fsync);「is PARTLY」文字放回:`89/2`(第一批 rename 後 ro ×2);拿掉掛不上 → rc 5:`90/1`;拿掉 stage-list 數量檢查:`90/1`(p5 被部分改動) |
| mutant v2(b869e61 時) | 拿掉 fsync:`78/5`;拿掉探針:`80/3`;拿掉殘留清除:`81/2`;拿掉退避:`82/1`;拿掉 `rm -f "$ST"`:`82/1`;拿掉 `batch_ok`:`82/1` |
| 節點的 busybox(OpenWrt 24.10 a72 build,qemu-user,`CFGSAVE_BB`) | `PASS=91 FAIL=0`(862 s)。no-fsync 案例固定用主機的 busybox sh:qemu `-L <rootfs>` 讓 guest 看得到 rootfs 的 `/bin/fsync`(節點上也有),藏不掉 |
| 沒有 dm 的主機(v2 時,`dmsetup` 換成會失敗的 shim) | `CFGSAVE_REQUIRE_DM=1` → `FAIL setup … PASS=0 FAIL=1` rc 1;未設 → `note:` + `PASS=66 FAIL=0` |

**測試環境的一次事故(已歸因)**:11-23 23:40:07 起 WSL 的 `/dev/null` 變成一般檔案,造成 h4 的 `derive_misc` FAIL(`fatal: bad config line 1 in file /dev/null`)。v2 報告時我把原因列為「❓ 未歸因」。審查者 A 後來確認是他第一輪實驗腳本 `exp-tail.sh:49` 的一行 `sed -i … /dev/null`,在 PATH 前面是 busybox applet 的 harness 裡執行。翻轉:在 `mknod` 的複本上,busybox `sed -i` rc 0 並把字元裝置換成一般檔,GNU sed 拒絕(rc 4)。我當時只測了 GNU sed,所以沒找到。已還原(`mknod -m 666 /dev/null c 1 3`)並在乾淨的 `/dev/null` 上重跑所有結果。

## 9. 不處理(寫在原 issue 的 checklist)

- **A-F8**:lint 也比對 96 的 `ALLOWED_PKGS=` 與 `batch_ok` 的 `-v allowed=`(現在兩者相同,但 96 改清單時 lint 不會紅)。
- **A-F10**:`--on-join` / `--if-healthy` 輪替 lkg 時要求 `wireless.default_radio1.key` 存在,避免 uci 全壞時把空的 overrides 也輪替進 lkg(既有行為)。
- Go 端 `settings.go:106` 的 `ConfigUnsafe` 與 `batman-slot` 提示的字元清單補上「newline」(app 的 ssid 路徑已有白名單,`halow-setkey:264`)。
- build / ab-card 檢查 rootfs 有 `/bin/fsync`(現在沒有它就每次存檔 rc 15,是大聲的失敗,但最好在出貨前就擋下,審查 A-r2 F3)。
- GitHub runner 上有沒有 dm-flakey 尚未驗證(分支沒 push);PR 要附上 CI log 中 EIO 案例確實跑過的那幾行(審查 B-r2 MINOR-1)。
- `tests/prov-p1/cfgsave-frozen-nomount.sh` 裡的 `fsync` shim 用不到(frozen 的 `--on-join` 在 staging 前就結束),只是對稱;可以拿掉或加註(審查 A-r3 F3)。
- 探針之後(umount 時)才發生的 I/O 錯誤偵測不到;卡謊報寫入成功偵測不到。
- uci 整個壞掉時,`overrides.uci` 合法地是空的,仍會被寫入(既有行為;離線 harness 沒有 uci,也是靠這條路)。

## 10. 審查處置

### v1 → v2(審查 A / B 第一輪)

| # | 嚴重度 | 處置 | 證據 |
|---|---|---|---|
| A-F1 | MAJOR | 修:rename 前對每個 stage 檔 `fsync`(節點 busybox 有 `fsync` applet,§6);新增 data-only 案例(A 的 E4 dm 多段表);「stage 仍 dirty」案例改用 `suspend --nolockfs --noflush`;另加「fsync 後、rename 前」的案例保留探針的負向對照 | data-only:修正版 rc 15;4eba26d 與 6d65ecd 皆 `saved rc=0` + 全 NUL → FAIL |
| A-F2 | MAJOR | 修:`--check` 建不出比對時回 rc 5 `p5 stale: unverifiable (…)`,依 `batman-slot:559-588` 只有 rc 5 會擋 | run dir 滿:修正版 rc 5;6d65ecd rc 1;4eba26d rc 5 但沒有 `unverifiable`(只是意外) |
| A-F3 | MAJOR | 修:0 B 檢查排除 `.stage.*`;加確定性的 `+ 6 s` EIO 案例;測試連跑 5 次 | 5/5 `PASS=83 FAIL=0` |
| A-F4 / B MAJOR-1 | MINOR / MAJOR | 修:`cfgsave-save.failed` + `--on-join` 300 s 退避 | 退避案例(mount count 不變) |
| A-F9 / B MAJOR-1 | MINOR / MAJOR | 修:持鎖的 rw 掛載後刪除 `.stage.*` / `.wprobe.*` | 殘留 ×2 案例 |
| B MAJOR-2 | MAJOR | 修:`CFGSAVE_REQUIRE_DM=1`(ci.yml、test-prov-p1-stubs.sh) | 無 dm shim:rc 1 FAIL |
| A-F5 / B MINOR-1 | MINOR | 修:UNSAFE 加換行 / CR(rc 6、報出 key、其餘照存);`batch_ok` 失敗有自己的訊息;白箱案例給 `batch_ok` 負向對照 | 換行 / CR ×3、白箱 |
| A-F6 | MINOR | 修:先刪 stage 再印;cleanup 的 `rm` 靜音;測試斷言最後一行 | 6d65ecd 在 eio6 FAIL(最後一行是 `rm:`) |
| A-F7 | MINOR | 修:`PUB` 旗標;測試斷言 p5 未變時不得說 PARTLY | `--save read-only`:`renaming identity/… failed — p5 is unchanged` |
| A-F8 | MINOR | §9 follow-up | — |
| A-F10 | MINOR | §9 follow-up | — |
| B MINOR-2 | MINOR | 修:on-join 快取案例(好 tick 寫、失敗 tick 刪) | 4eba26d FAIL;mutant(拿掉 `rm -f "$ST"`)`82/1` |
| B MINOR-3 | MINOR | §9 follow-up | — |
| B MINOR-4 | MINOR | 修:中性文字,不猜「p5 full」 | — |
| B MINOR-5 / A | MINOR | 修:註解改成「compare (page cache)」、ci.yml 註解改成「a failed write, fsync or an aborted journal」 | — |

### v2 → v3(審查 A-r2 / B-r2)

| # | 嚴重度 | 處置 | 證據 |
|---|---|---|---|
| A-r2 F1 | MAJOR | 修:`PUB=1` 之後的文字是「p5 may be PARTLY updated (each file whole; an I/O error may have kept the last committed state)」;I/O 錯誤類案例接受「p5 未變 + may be PARTLY」,ro 類仍嚴格;新增 hook 3(第一批 rename 之後)的 ro 與 dm-flakey 確定性案例 | 4 個新案例;mutant(舊文字)`89/2` |
| A-r2 F2 | MINOR | 修:CR 不再是 UNSAFE,只留換行;CR 案例改成 rc 0 且位元組原樣 | CR 案例;§6 節點 uci 證據 |
| A-r2 F3 / B-r2 MINOR-3 | MINOR | 修:沒有 `fsync` 工具 = rc 15(不再退回 `sync FILE`);離線 harness 自備 shim | no-fsync 案例;mutant(退路放回)`90/1` |
| A-r2 F4 | MINOR | 修:`chattr +i` 的確定性對照 | 6d65ecd、4eba26d 都 FAIL(最後一行是 `rm: … Operation not permitted`) |
| A-r2 F5 | MINOR | 修:`find` 的 rc 與檔數檢查 | stage-list 案例;mutant(拿掉數量檢查)`90/1`(p5 被部分改動) |
| A-r2 F6 | MINOR | 修:batman-slot 對 unverifiable 的專屬拒絕文字 | `slot-p5gate-txn.sh` 21/0;舊 batman-slot 21/2 |
| A-r2 F7 | MINOR | 修:dm 切換 load → suspend → resume,失敗時 resume | 測試程式碼(5 次 + 節點 busybox 執行無卡死) |
| B-r2 MINOR-1 | MINOR | 修:CI 獨立 step + `modprobe dm_flakey` / `linux-modules-extra`;runner 未驗證(§9) | ci.yml YAML 解析通過 |
| B-r2 MINOR-2 | MINOR | 修:`--check` 掛不上 p5 且這次開機已有存檔失敗 → rc 5 unverifiable;沒有證據時仍 rc 1 | 案例(rc 1 / rc 5);mutant `90/1` |
| B-r2 MINOR-4 | MINOR | 修:§8 對 6d65ecd 的負向對照改成範圍加確定性清單 | §8 |
| /dev/null 事故 | — | 更正紀錄:已由審查者 A 歸因(§8) | 翻轉:busybox `sed -i` 把字元裝置換成一般檔 |

### v3 → v4(審查 A-r3 / B-r3)

| # | 嚴重度 | 處置 | 證據 |
|---|---|---|---|
| B-r3 MINOR-1 | MINOR | 修:superblock 讀不到 → `--check` rc 5 `p5 unreadable`、`--prov-get` rc 1;rc 3 / 12 只留給讀到但不是 ext4 | dm `error` 案例(有 / 沒有標記、`--prov-get`)+ 歸零的對照;4eba26d / 6d65ecd 都 FAIL ×3;mutant `93/3` |
| B-r3 MINOR-4 / A-r3 F1 | MINOR | 修(owner 決定):ext4 p5 的 `ro,noload` 掛載失敗 3 次 → rc 5,不需要標記;有標記就寫出步驟 | 掛不上案例 ×2;`cfgsave-txn-save` 對照改為 rc 5;mutant `95/1` |
| B-r3 MINOR-2 / A-r3 F2 | MINOR | 修:CI step 在 `linux-modules-extra` 前先 `apt-get update -qq` | ci.yml |
| B-r3 MINOR-3 | MINOR | 修:§8 改成「確定性清單 + 時序相關案例」 | §8 |
| B-r3 附註(`--seed` 會 mkfs 讀不到的 superblock) | — | §9(既有問題) | — |
| A-r3 F3 | MINOR | §9(frozen-nomount 的 shim 用不到) | — |

### v4 → v5(審查 A-r4 / B-r4)

| # | 嚴重度 | 處置 | 證據 |
|---|---|---|---|
| B-r4 MAJOR-1 | MAJOR | 修:`ro,noload` 失敗 3 次後先在 mountinfo 以 major:minor 找 p5;掛在別處就經由那個掛載唯讀比對,給真正的判定;讀不到 → rc 5「busy … could not be compared」;只有沒掛在任何地方又掛不上才是「does not mount」。§3 與程式註解的錯誤說法已更正 | 健康但忙碌 ×4 + 持鎖;4a93ba2 FAIL ×3;mutant `100/3` |
| B-r4 MINOR-1 | MINOR | 修:上述健康但忙碌的對照,副本用真名 | 同上 |
| B-r4 MINOR-2 | MINOR | 修:§8 不再寫 6d65ecd 的觀察總數 | §8 |
| A-r4 F1 | MINOR | 修:「does not mount」帶 mount 自己的錯誤(一行) | 4a93ba2 FAIL ×2;mutant `101/2` |
| A-r4 F2 | MINOR | 修:hexdump 註解:busybox 在 EIO 時 exit 0、輸出空白,靠 `-z` 判斷 | 程式註解 |
| (B-r3 附註,§9) | — | 修:`--seed` 遇到讀不到的 superblock 拒絕、不 mkfs;歸零的 p5 仍 format;已從 §9 移除 | 案例 + 對照;4a93ba2 FAIL;mutant `102/1` |

### v5 → v6(審查 A-r5 / B-r5)

| # | 嚴重度 | 處置 | 證據 |
|---|---|---|---|
| A-r5 F1 | MAJOR(測試) | 修:teardown 先 `udevadm settle` 再 `dmsetup remove --retry`,然後證明 dm 與 loop 都不在,否則 `FAIL teardown: LEAK` | `CFGSAVE_TEST_LEAK=1`:真的測試 FAIL、拿掉檢查的 mutant 無聲 PASS;10 次 + 並行 2 次後 `losetup` / `dmsetup` 都是空的 |
| A-r5 F2 / B-r5 MINOR-4 | MINOR(測試) | 修:主機 flock(有上限地等待)、dm 用 mktemp 目錄命名、每個案例先確認裝置沒被掛載、setup 失敗時印 evidence、mkfs 只在沒掛載時重試 | 並行 2 次:一個等了 112 s,兩個都 PASS;evidence 抓到 v5 ❓ 的機制(§8) |
| A-r5 F3 | MINOR | 修:p5 的 umount 失敗記一行 `daemon.warn`(cleanup、存檔之後) | 程式碼 |
| B-r5 MINOR-1 | MINOR | 修:只用 major:minor 找 p5;把那個掛載 bind 到我們自己的私有掛載點、設成唯讀,並驗證那一行 mountinfo 是 p5 的 major:minor 與 root `/`,才比對 | 疊上的 tmpfs、名稱像 p5 的假檔案系統;3781b00 都 FAIL;mutant ×2 |
| B-r5 MINOR-2 | MINOR | 修:只剩子目錄 bind 持有的 p5 有自己的 rc 5 文字;§7 記為已知邊角 | 子目錄 bind 案例;3781b00 FAIL |
| B-r5 MINOR-3 | MINOR | 修:§3 說明經由別的 rw 掛載比對時,「fresh」代表那個掛載目前(含 cache)的內容 | §3 |

### v6 → 最後一輪(審查 A-r6 / B-r6,兩位 APPROVE)

| # | 嚴重度 | 處置 | 證據 |
|---|---|---|---|
| A-r6 F1 / B-r6 MINOR-1 | MINOR | 修:`remount,bind,ro` 的結果要檢查,而且我們那一行 mountinfo 的掛載選項必須是 `ro`(連同 major:minor 與 root `/`);否則 umount 我們的 bind,回 rc 5「busy … could not be compared」 | 新案例:`mount` 的 remount 被 shim 拒絕 → rc 5;f49107a FAIL(經由 rw bind 給出 fresh) |
| A-r6 F2 | MINOR | §8 一行:private namespace + 主機鎖讓執行排隊(含等待約 200 s);CI 只跑一個實例 | §8 |
| B-r6 MINOR-2 | MINOR | 不另做:節點上的 `mount` 是 mount-utils 的 `/usr/bin/mount`(審查者 A;韌體 `.config` `CONFIG_PACKAGE_mount-utils=y`,節點 busybox 沒有 `SH_STANDALONE`,所以走 PATH,`/usr/bin` 在 `/bin` 之前)。測試裡兩種都有跑到:主機的 busybox sh 會把 `mount` 解析成它自己的 applet(實測:PATH 前面的 shim 不會被呼叫),而 remount shim 的案例改用 dash 跑,走 PATH,用的是 util-linux 的 `mount` | 審查 A-r6;shim 實測 |
