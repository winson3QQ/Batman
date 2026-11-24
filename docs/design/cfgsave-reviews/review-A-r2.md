# Review A, round 2 — cfgsave-stage-enospc (design v2 + 4eba26d..b869e61)

審查者 A。重審整份變更(`git diff 4eba26d b869e61`),不只 v1→v2 的差異。程式碼唯讀;實驗在 WSL Ubuntu-24.04(kernel 6.6,root)自己的 fresh clone `<home>/rev-cfgA2`(HEAD b869e61)。沒有碰任何節點,沒有 commit / stash / push。feed 與 deploy 兩份 `batman-config-save` byte 相同 ✅(`cmp`)。

**Verdict: APPROVE-WITH-CHANGES** — 沒有 BLOCKER;1 個 MAJOR(測試仍會間歇性 FAIL,且它揭露的訊息不實),其餘 MINOR。v1 的 3 個 MAJOR 在產品端都已確實修好並有負向對照。

## 0. 先更正我自己的紀錄:WSL `/dev/null` 是我弄壞的

協調者提到 WSL 的 `/dev/null` 在昨晚 23:40 被換成一般檔案、原因未歸因。**原因是我第一輪的實驗腳本**:`<scratch>/exp-tail.sh:49` 留了一行無作用的 `sed -i '…' /dev/null`,在 root、`PATH` 前面是 busybox applet 的 harness 裡執行(第二次 `r3.sh` 執行,E3 的 `ls` 時間戳正是 `Nov 23 23:40`)。

翻轉證據(在暫存目錄的 `mknod` 複本上做,沒有碰真的 `/dev/null`):

```
character special file 1:3      <- mknod $d/null c 1 3
busybox sed -i rc=0
regular empty file              <- busybox sed -i 把字元裝置換成一般檔
sed: couldn't edit …/null: not a regular file
gnu sed -i rc=4
character special file          <- GNU sed 拒絕
```

所以那次不是環境問題,是我的錯。第一輪報告裡我沒有發現它,在此更正。這段期間(23:40 到修復者還原之間)在 WSL 跑的任何結果都可能受影響;我第一輪 R7(`test-prov-p1-stubs` 27/0)是在那之後跑的,所以它的可信度要打折扣。本輪所有執行都在還原之後,結束時 `stat /dev/null` 是 `character special file 1:3`(見 §5)。

## 1. 我跑過的東西

| # | 內容 | 結果 |
|---|---|---|
| H1 | HEAD 測試 × HEAD 產品,`CFGSAVE_REQUIRE_DM=1` | ❌ `PASS=82 FAIL=1`(85 s)— `--if-healthy EIO (writes only) after the stage fsync, before the renames … says-PARTLY-but-p5-unchanged`,見 F1 |
| H2 | 同上再一次 | ✅ `PASS=83 FAIL=0`(73 s) |
| V1 ×3 | HEAD 測試 × 6d65ecd 產品 | ✅ 3 次都 `PASS=67 FAIL=16`,FAIL 清單相同(diff 只差 pid) |
| B | HEAD 測試 × 4eba26d 產品 | ✅ `PASS=12 FAIL=71` |
| N | HEAD 測試,節點的 busybox(`CFGSAVE_BB="qemu-aarch64-static -L <root-bcm27xx> …/bin/busybox"`,a53 build) | 見 §5 |
| NM | 同上,但產品的 `command -v fsync` 改成找不存在的名字(→ 走 `sync FILE` 退路) | 見 §5 |
| CR | 節點的 `uci`(qemu)`uci batch` 一行 `set wireless.default_radio1.key='abc\rdef'`;節點 busybox awk 跑 96 的 `valid_batch` | `batch rc=0`、`commit rc=0`、`uci get` = `a b c \r d e f`;`valid_batch(CR line) rc=0`、`valid_batch(換行拆行) rc=1` — 見 F2 |
| SRC | 韌體 build tree 的 busybox 1.36.1 原始碼與 rootfs | `coreutils/sync.c`:沒有 `SYNC_FANCY` 時 `sync_main` 是 `bb_warn_ignoring_args(argv[1]); sync(); return EXIT_SUCCESS;`;`fsync` applet 走 `sync_common()`,`fsync()` 失敗回 `EXIT_FAILURE`;`.config`:`CONFIG_FSYNC=y`、`# CONFIG_FEATURE_SYNC_FANCY is not set`;a53 與 a72 的 `root-bcm27xx/bin/fsync -> busybox` 都在 |

### 協調者問的 67/16 vs 66/17

我的 3 次都是 `67/16`,清單完全相同:read-only ×3、data-only ×5、run dir 滿、退避、殘留 ×2、換行 / CR ×3、白箱。修復者多出的那一個是他列的「eio6 的最後一行」(v1 的 cleanup `rm` 錯誤變成最後一行)。我 3 次 × 3 個模式共 9 個 v1 的 eio6 案例,最後一行都是 `p5 NOT saved: mkdir identity/… failed`(都 ok),所以**那個案例不是確定性的**:要看 cleanup 的 `rm` 有沒有碰到需要從壞掉的裝置讀的 block。對 v1 的負向對照沒有影響(v1 仍有 16 個確定性的 FAIL),但它是 v2 的 eio6 斷言(「最後一行是說明」)唯一的負向對照。這條對照不可靠,需要一個確定性的版本(F4)。

## 2. 協調者指定的四點

### (1) A-F1 的 fsync 路徑:`sync FILE` 退路在出貨的東西上會不會 fail-open?

- **出貨的 image 不會走退路** ✅:兩個 SoC 的 rootfs 都有 `/bin/fsync -> busybox`(SRC),而 `fsync` applet 在 `fsync()` 失敗時回 1(`sync_common`)。§5 的 N 用節點的 busybox 跑完整測試。
- **退路本身在節點的 busybox 上就是 fail-open** ⚠️→✅:沒有 SYNC_FANCY 的 `sync FILE` 會忽略參數、回 0(SRC 原始碼;NM 實測見 §5)。設計 §7 / §9 有寫,也承認是 fail-open。我不同意「只給離線 harness 用」這個理由:測試自己已經在 `$W/bin/fsync` 放了 shim(`cfgsave-stage-enospc.sh:62-65`),所以產品根本不需要這條退路。見 F3。
- 另一個靜默的洞:`for f in $(cd "$STAGE" && find . -type f); do …` 的 `$(…)` 丟掉 `find` 的 rc。`find` 在壞掉的目錄上只列出部分檔案(甚至什麼都不列)時,沒被列到的檔案就不做 fsync,迴圈也照樣成功。見 F5。

### (2) `--check` rc 5 `unverifiable`:有沒有呼叫者對 rc 5 的處理和 §10 說的不同?

我逐一讀過,都和 §3 / §10 的說法一致:
- `batman-slot:559-578`:`keys` 取到 `unverifiable`;`*"p5 stale: prov"*` 與 `*unpersistable*` 都不匹配,於是落到 `die_c 12 "p5 (config) is STALE vs the running config (unverifiable) … $P5_STALE_HINT"` → **擋 OTA** ✅;`allow-stale-p5` 可以覆寫 ✅;stage 2 的 `p5_verdict_gate` 對 `stale:unverifiable` 回 1 → 也擋 ✅。
- Go `parseCheck`(`status.go:53-61`):rc 5 + `p5 stale` → `(false, nil)`,也就是 stale。v1 的 rc 1 在這裡是「no answer」(快取保留舊值),現在 app 看到的是「p5 not saved」。這是保守方向 ✅。
- `onlyP3Stale`(`status.go:67-82`):`unverifiable (…)` 不是 P3 key → false → `upgradeSave` 不會自己 `--save` ✅。
- `halow-setkey:231,257,309,323`:`--check || p3_persist` → 多做一次 `--save`(stage 在 p5 上,不在 run dir)✅。
- 其他:`grep` 整個 repo,沒有任何地方依賴舊字串 `p5 error staging` ✅。
- MINOR(F6):`batman-slot` 擋下時印 `$P5_STALE_HINT`(「Run 'batman-config-save --save' …」)。但 `unverifiable` 的原因是 run dir(/tmp)滿,`--save` 修不好;最可能的時機是 sysupgrade 把 image 放進了 /tmp。操作員會照著錯的提示做。

### (3) 300 s 的 on-join 退避標記:誰能寫 / 刪?跨重開機變舊?時鐘跳?

- **寫者**:只有 `not_saved`(`[ "$RDOK" = 1 ] && ( umask 077; echo "$(up) $1" > "$SAVEFAIL" )`)。
- **刪者**:成功的寫入(`umount` 後 `rm -f "$SAVEFAIL"`)和 on-join 的 `unchanged` 路徑。
- **讀者**:只有 `--on-join`,而且要通過 `-f` + `-O`。
- **所在位置**:`$RUNDIR`(`/tmp/run/batman`,root 0700,由 `rundir.sh` 驗證);`RDOK=0` 時指向 `/nonexistent`。非特權程序無法建立、改寫或刪除它 ✅。
- **跨重開機**:在 tmpfs 上,重開機就消失 ✅。
- **時鐘**:用的是 `/proc/uptime`(開機後單調遞增,與 wall clock / RTC 無關)。NTP 跳動或沒有 RTC 都不影響 ✅。
- **邊界**:
  - `t` 比 `now` 大(只有 root 手寫才會發生)時,`now - t < 300` 永遠成立 → 這次開機的 on-join 永久退避,直到有人 `--save` 成功。只有 root 做得到,影響也只是 on-join 不存(`--check` 仍會說 stale)。不另列。
  - run dir 滿時標記寫不進去 → 沒有退避(失敗時多重試,是安全方向)✅。
  - 操作員的 `--save` 失敗也會讓 on-join 退避 300 s。合理。
- 測試(退避案例)用 ext4 的 mount count 證明退避期間沒有掛載 ✅;它也是負向對照(v1:`rc 15/15/15 mounts 3/4/5`)。

### (4) 殘留的 `.stage.*` / `.wprobe.*` 清除:會不會刪到不是我們的東西?

- **執行條件**:`[ "$LOCK_MINE" = 1 ] && rm -rf "$MNT"/.stage.* "$MNT"/.wprobe.*`,只在 rw 掛載驗證成功之後、持鎖時執行;`$MNT` 是 root 0700 run dir 下的私有掛載點。
- **誰能在 p5 根目錄放名字**:`grep` 整個 feed/ deploy/ scripts,p5 唯一的 rw 寫者就是 `batman-config-save`(其他元件都是 `ro` / `ro,noload` 掛載),也沒有其他程式碼用 `.stage.` / `.wprobe.` 這兩個前綴 ✅。非特權程序碰不到 p5。
- **symlink**:busybox `rm -rf` 用 `lstat`,刪的是 link 本身,不會跟隨;也不會遞迴進 symlink 指向的目錄 ✅。hardlink 只能指向 p5 內部。
- **物理接觸卡的人**能放任何東西,但他本來就能直接改 p5。最多讓 `rm` 跑很久,只是 DoS,不另列。
- **鎖被錯誤接管時**:兩個 config-save 同時跑,一個刪了另一個的 stage → 後者 rename 失敗 → rc 15(fail-closed)✅。
- **frozen 節點**:清除發生在 `identity_mismatch` 拒絕之前。刪掉的是本 slot 自己寫的暫存(含 host key / shadow 副本),不是另一個 identity 的紀錄。可接受;設計 §7 還把它當成好處(秘密不再殘留)。

## 3. Findings

### F1 — MAJOR(測試 + 訊息):journal 在 rename 迴圈中途 abort 時,產品說「PARTLY updated」,但 p5 其實沒變;測試因此間歇性 FAIL

- **證據**:H1:
  ```
  FAIL --if-healthy EIO (writes only) after the stage fsync, before the renames: not-saved rc=15 :: says-PARTLY-but-p5-unchanged
    err=[… renaming identity/dropbear/dropbear_rsa_host_key failed — p5 is PARTLY updated (each file whole) …]
  ```
  同一次與 H2 的其他 5 個 `eiowp` 案例,都是所有 rename 在記憶體中成功、到探針才失敗(`the final sync … failed — p5 holds its last committed state`)。這次是第 1 個 rename 在記憶體中成功(`PUB=1`),之後 journal abort,第 2 個 rename 才失敗。重新掛載後,第 1 個 rename 不在卡上(它屬於被 abort 的交易)。⚠️ 機制是推論(jbd2 commit 剛好落在 rename 迴圈裡),沒有做翻轉;頻率是 2 次執行、6 個 eiowp 案例中出現 1 次。協調者 2 次、修復者 5 次都沒遇到 → 罕見但真實。
- **產品面**:`PUB=1` 只代表 rename 在 page cache / 記憶體裡成功,不代表已落到卡上。journal abort 時,「PARTLY updated」是錯的斷言;正確的說法是「不確定」。依 owner 規則,對操作員的報告不能 overclaim。
- **修法**:
  - rename 失敗而 `PUB=1` 時,文字改成 `p5 may be PARTLY updated (each file whole; an I/O error may have kept the last committed state)`。
  - 測試在 `eio*` 類別接受「p5 未變 + may be PARTLY」,但 `ro` 類別維持嚴格(ro remount 不會丟掉已完成的 rename)。
  - 再加一個確定性案例:在第 1 個 rename 之後注入錯誤(在 publish 迴圈裡加第二個 hook),這條路徑才每次都被走到。

### F2 — MINOR:把 CR 加進 UNSAFE,讓原本可以正確保存、還原的值變成「不能存」

- **證據**:CR 實驗:節點的 `uci batch` 原樣保存 `abc\rdef`;節點 busybox awk 的 `valid_batch` 接受這一行(rc 0);CR 不會把 `set` 行拆開(awk 的 RS 是 `\n`)。另外 v1 對同一案例 `mesh key with a CR` 的結果是 `--save rc 0 … reader=overrides.uci@1`:舊版能存,開機也會套用。v2 改成 rc 6、不存,`--check` 也因此回 5 unpersistable,OTA 被擋。
- **影響**:只有 root 直接 `uci set` 才放得進 CR。所以是 MINOR,但它的方向反了:設計 §3「含換行或 CR 的值會讓它的 `set` 行斷開」對 CR 不成立,§6 也只證明了 ash 的 `case` 比對得到 CR,沒有證明 reader 會拒絕。
- **修法**:UNSAFE 只加換行;測試的 CR 案例改成期待 rc 0 + 讀回位元組相同(用節點 uci 證明能還原);設計 §3 / §6 更正。

### F3 — MINOR:`sync FILE` 退路在每個沒有 SYNC_FANCY 的 busybox 上都是無聲成功(fail-open)

- **證據**:SRC(`sync_main` 在沒有 FANCY 時 `return EXIT_SUCCESS`);NM 見 §5。
- 現在出貨的 image 不會走到這條退路,但將來一個去掉 `fsync` applet 的 build 會把 A-F1 的修法無聲地拿掉,而測試照樣全綠:測試在 `$W/bin/fsync` 永遠放了東西。
- **修法**:產品沒有 `fsync` 時 fail-closed:`not_saved "no fsync tool"`,或退到 `dd if=… iflag=direct` 讀回比對(`FEATURE_DD_IBS_OBS=y`)。再加一個 build / ab-card 檢查,確認 rootfs 有 `/bin/fsync`。

### F4 — MINOR(測試):eio6「最後一行」的負向對照不是確定性的

- **證據**:§1。我 9 個 v1 eio6 案例全過,修復者遇到 1 次失敗。
- **修法**:另做一個確定性的對照:注入 cleanup `rm` 一定會失敗的狀況,例如在 `not_saved` 之前讓 stage 目錄的讀取必定 EIO(先 `echo 2 > /proc/sys/vm/drop_caches`,再切到 `error` 表),或用白箱 mutant 把 `2>/dev/null` 拿掉後斷言 FAIL。

### F5 — MINOR:fsync 迴圈忽略檔案清單的 rc,也不檢查數量

- `for f in $(cd "$STAGE" && find . -type f)` 中,`cd` 或 `find` 失敗或只列出部分檔案時,沒列到的檔案不做 fsync,而 rename 仍可能在記憶體中成功(目錄項在 cache 裡)。
- **修法**:先 `list=$(cd "$STAGE" && find . -type f) || not_saved "listing the stage"`,並斷言數量 = identity 檔數 + overrides + schema +(lkg)+(.seeded)。

### F6 — MINOR:`unverifiable` 被 batman-slot 擋下時,提示的是錯的補救(`--save`)

- 見 §2 (2)。
- **修法**:`batman-slot` 對 `*"p5 stale: unverifiable"*` 加一個分支,說明是 run dir / /tmp 滿,請釋放 /tmp 或用 allow-stale-p5。這是跨元件的修改,也可以列入 checklist,和 B MINOR-3 一起做。

### F7 — MINOR(測試健壯性):`dmtab` / `datafail_table` 先 suspend 再 load,load 失敗時裝置永遠停在 SUSPENDED

- 我第一輪自己的腳本就這樣卡住過:之後所有 I/O 都卡在 D state,EXIT trap 也跑不到(cleanup 的 `dmsetup resume` 救不了正在卡住的指令)。
- **修法**:`dmsetup load … && dmsetup suspend … && dmsetup resume … || dmsetup resume …`(load 只寫 inactive table,不必先 suspend)。

## 4. 逐項確認(沒有 finding)

- **v1 的 A-F1(data-only)**:修正版 data-only ×6 都 rc 15 `fsync of the stage (…) failed — p5 is unchanged`;v1 / 4eba26d 都 `saved rc=0`(V1 / B)。負向對照 ✅。我也看了修復者的 mutant 數字(拿掉 fsync → `78/5`),沒有重跑。
- **A-F2**:run dir 滿 → rc 5 `unverifiable` ✅;v1 rc 1 ✅(負向對照)。
- **A-F3**:0 B 檢查排除 `.stage.*`、加了 eio6;H1/H2 中 eio / eio6 全過 ✅。
- **A-F4 / A-F9**:退避與殘留案例,v1 都 FAIL、HEAD 都 PASS ✅。
- **A-F5**:換行 → rc 6、報出 key、其餘照存 ✅(CR 見 F2)。
- **A-F6 / A-F7**:最後一行斷言、`PUB` 旗標 ✅(F1 是 `PUB` 在 journal abort 下的語意缺口)。
- **rename-only、`: >`、呼叫者對 rc 15**:同第一輪,結論不變;§3 的表格與 source 一致。
- **安全**:沒有新的、非特權者可以碰到的輸入;標記與清除都在 root 0700 / 私有掛載點內;錯誤訊息不含值 ✅。
- **降級**:p5 格式不變;`cfgsave-save.failed` 在 tmpfs 上,舊版不讀 ✅。
- **時間成本**:新測試 73–85 s(原本 45–50 s),可接受。

## 5. 節點 busybox 執行(N / NM)與收尾

- ✅ **N**(HEAD 產品、節點 a53 busybox 1.36.1 經 qemu-user、`CFGSAVE_REQUIRE_DM=1`):`PASS=83 FAIL=0`,630 s。harness 用的是 busybox 自己的 `fsync` applet,所以出貨的路徑確實被測到了。⚠️ 這個 busybox 來自 build tree(`root-bcm27xx/bin/busybox`,build 日期 2025-06-23),不是從 shipped squashfs 取出的。
- ✅ **NM**(同上,但產品找不到 `fsync` → 走 `sync FILE` 退路):`PASS=78 FAIL=5`,630 s。FAIL 的正是 5 個 data-only 案例,全是 `saved rc=0`,並且 `overrides!=NEW … identity/…!=live`。這證明退路在節點的 busybox 上 fail-open(F3);它同時也是 fsync 修法在節點 busybox 上的負向對照。
- ✅ 收尾:`losetup -a` 與 `dmsetup ls` 皆空(`No devices found`),`stat /dev/null` = `character special file 1:3`。本輪沒有在任何地方對 `/dev/null` 用 `sed -i` 或 `mv`。

❌ 沒做:
- 沒在節點上跑;
- 沒有重跑修復者的 mutant 表(只重現了 fsync 那一項,即 NM);
- 沒跑 sbx 和 GitHub CI;
- F1 的機制沒有做翻轉,只觀察到 1 次。
