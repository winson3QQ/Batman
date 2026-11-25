# Review: `docs/255-rig-runbook.md` (soldering day + E0a–E3)

Reviewed: runbook at branch `docs/255-rig-runbook` (53970e7); tool at `C:/src/Batman-255d` branch `feat/255-se608-core` (a62c5a0); design `255-608b-config.md` §4, §6, §8; `255-608b-impl.md` §5; `608b-facts.md` §9, §12; issue #300 body and comments; both annotated photos.
Read-only review. Nothing was run on a device. Two local checks were run in WSL (git, and the build command with a throwaway cache and `-o /dev/null`).

## Verdict: APPROVE-WITH-CHANGES

BLOCKER 0 / MAJOR 6 / MINOR 11

What is right (checked, no change needed): the 608B SOIC-8 pin table (1, 2, 3, 7 NC; 4 GND; 5 SDA; 6 SCL; 8 VCC — from memory of the datasheet, high confidence, and it agrees with #300); the pin 1 dot position in the photos is consistent with pin 8 sitting next to the two capacitor footprints; the header pin 1 mark in the overview photo matches the silkscreen "1 … 39" on the inner row; Pi header facts (1 = 3.3 V, 2/4 = 5 V, 3 = SDA1, 5 = SCL1, 9 = GND, odd pins = inner row; high confidence); Adafruit 3013 pull-ups on VIN (high confidence); wake response `04 11 33 43`; every `se-lab` command line, flag position, output field name and exit code (table at the end); no step writes to the chip before E1's read-only checks; nothing goes beyond E3; the tool cannot lock (`allowedOps` = Read, Write, Random, Info; word 21 with the lock bytes is not in `ImageWords`), so "E0–E3 leave no permanent change" holds.

---

## MAJOR

### M1. `rc=$?` after `| tee` is always tee's exit code (0); error text is not saved; exit 1 in E2/E3 has no instruction

Section: §6, §7, §8.

What goes wrong: `./se-lab … write-image | tee e3-write.txt; echo "rc=$?"` prints `rc=0` even when `se-lab` exits 1, 3 or 4. The table row "`compare=EQUAL`, `rc=0`" half-passes on a failure, and the rows "`rc=4`" and "代碼 3" can never be seen. Refusals and errors go to stderr (`main.go:128,140,144,152,170,176-182,220`), so they are on the screen but not in the saved file. For exit 1 during `data-write`, `random` or `write-image` (a bus error half-way; `written_words=` is printed first, `main.go:218-221`) the runbook says nothing; only `info` has a rule.

Evidence: in bash, `$?` after a pipeline is the last command's status. `main.go` writes all refusals to `e.errOut`.

Replacement: at the start of §6 add

```sh
cd /dev/shm
set -o pipefail
```

and write every `se-lab` line in this form (example):

```sh
./se-lab -allow allow.txt -byte17 "$B17" write-image 2>&1 | tee e3-write.txt; echo "rc=$?" | tee -a e3-write.txt
```

Add one rule under the exit-code line in §5: "任何一步 `rc=1`（`info` 以外）、`rc=2`、`rc=3`：**停**。不要重跑、不要改檔案。把該步的輸出檔帶回來。`rc=1` 出現在 `write-image` 時晶片可能只寫了一部分，這沒有壞處（未鎖、可重寫），但由設計決定下一步。"

### M2. §9 raw wake test is typed as two lines; the chip is asleep again before the second line

Section: §9.

What goes wrong: the watchdog is 1.3 s nominal, **0.7 s minimum** (`608b-facts.md:287`). A person cannot enter the second line reliably in that time. The read then fails with an I/O error, and the table tells the operator the chip does not answer and to check orientation and joints — on a good chip. That leads to reworking a good solder job.

Replacement (one line; also keeps the result):

```sh
i2ctransfer -y -a 1 w1@0x00 0x00; i2ctransfer -y 1 r4@0x60 2>&1 | tee -a raw-wake.txt; echo "rc=$?"
```

Text: "整行一次貼上再按 Enter。第一個指令印 `Error: Sending messages failed`（NACK）屬正常。做三次。" Change "約 1.3 秒" to "0.7–1.7 秒".

### M3. U3 / C6 / C7 nets are marked ✅ but come from the design files of a different board revision; no check on the bare pads before the irreversible step

Section: §1.1 ("✅ 板子網路表，#300"), §1.2.

What goes wrong: #300's net list is parsed from the Seeed v1.0 `.brd`, whose U3 is TNGLORAS with silkscreen `0x59`. The #300 comment of 2026-11-21 says the spare HAT is "a different revision" (`0x60`, U3/C6/C7 unpopulated). Nobody has confirmed that this revision routes U3 the same way, that R13/R14 are fitted on it (#300 says "照片上有焊" about the Seeed photo), or that the two footprints in the blue box are C6/C7. It takes two minutes with a meter on the empty pads, before soldering.

Replacement: mark the table ⚠️ ("設計檔是 0x59 那一版；本板在 §1.2 第 0 步用電表確認") and add step 0 to §1.2, HAT off the Pi, unpowered:

| 量哪裡（空焊盤） | 預期 | 不符合時 |
|---|---|---|
| U3 焊盤 4 ↔ `GND` 焊盤 | 導通 | **停，不要焊**，回報 |
| U3 焊盤 5 ↔ 排針第 3 腳 | 導通 | 同上 |
| U3 焊盤 6 ↔ 排針第 5 腳 | 導通 | 同上 |
| U3 焊盤 8 ↔ 藍框兩組焊盤各自的其中一個焊盤 | 導通（記下是上面還是下面那個） | 同上 |
| 藍框兩組焊盤各自的另一個焊盤 ↔ `GND` | 導通 | 同上 |
| U3 焊盤 8 ↔ 排針第 2 腳（5 V） | 不導通 | 同上 |
| U3 焊盤 5 ↔ 焊盤 8、焊盤 6 ↔ 焊盤 8（電阻檔） | 各約 4.7 kΩ（R13、R14 有焊）；讀不到就記「沒有上拉」，可以繼續（Pi 自己有 1.8 kΩ 上拉） | 只記錄 |
| U3 焊盤 8 ↔ 焊盤 4（電阻檔） | 記下讀值，§1.3 拿來比 | — |

Also: the runbook assigns R13 to SDA and R14 to SCL; #300 only says "R13、R14 各 4.7 kΩ". Drop the designators from the two rows or mark them ⚠️.

### M4. §1.3 continuity checks can pass on a bad joint and fail on a good one; pin 8's joint is never checked; no orientation gate before power

Section: §1.3, §3.1.

What goes wrong:

- (a) "U3 第 5 腳 ↔ 排針第 3 腳" does not say where the probe goes. On the pad, it beeps whether or not the lead is soldered. Pressing hard on a lifted lead also makes it beep.
- (b) "排針第 3 腳／第 5 腳" on the HAT: the photo marks only pin 1. Header numbering zigzags (pin 2 is in the other row). Someone counting 1-2-3 along one row lands on pin 5 when they want pin 3. The check then fails on a good joint and the operator reflows for nothing.
- (c) There is no unpowered check of pin 8's joint. The first evidence is the powered voltage in §3.2, which (same problem as (a)) reads 3.3 V on the pad under an open lead.
- (d) A chip rotated 180° puts VCC on pin 4 and GND on pin 8. None of the meter checks sees this. The only orientation check is in steps 3–4. There should be a hold point just before power.

Replacement, text above the §1.3 table: "探棒輕輕點在**晶片腳的肩部（腳本身的金屬）**，不是焊盤，不要用力壓。排針的腳位：照片綠框是第 1 腳；**同一排**（印有 1…39 的那一排）往右第二個焊點是第 3 腳，第三個是第 5 腳。"

Add rows:

| 量哪裡 | 預期 | 不符合時 |
|---|---|---|
| U3 第 8 腳（腳本身）↔ §1.2 第 0 步找到的電容 VCC 焊盤 | 導通 | 第 8 腳沒焊好 |
| C6、C7 各自兩端 | 不導通（讀值與第 0 步記下的 8 ↔ 4 相近） | 0 Ω = 電容底下連錫 |

Add as the last line of §1.3 and again in step 2 of §3.1: "**上電前最後確認：晶片的 pin 1 圓點在近照黃圈那一角。方向不對不要上電。** 上電後 10 秒內用手指碰晶片：會燙就立刻斷電，回報。"

### M5. RTC on the back of the Pi: pin 1 is found only by "square pad", on a Pi whose model is not yet known; the two meter checks pass on wrong wiring

Section: §2.1, §2.2.

What goes wrong: on the back the header is mirrored. The runbook's only cue is "方形焊盤 = 第 1 腳" (true on the Pi 3 / 4 / Zero boards I know — about 85 % confidence, and not checked for whatever board the rig is; solder or flux can hide the pad shape). If the operator starts from the wrong corner or the wrong row, both checks in §2.2 ("1 ↔ 9 不導通", "1 ↔ 2 不導通") still pass: they do not test which pads the wires are on. The 5 V row is 2.54 mm away.

Replacement for §2.2 (all unpowered, SD card out, HAT off, before soldering; probe the pads you intend to use on the back against the pins on the front):

| 量哪裡 | 預期 | 意思 |
|---|---|---|
| 正面第 2 腳 ↔ 第 4 腳 | 導通 | 這兩支是 5 V，確認數的方向對 |
| 背面「要焊 VIN 的焊點」↔ 正面第 17 腳 | 導通 | 第 1 與第 17 腳都是 3.3 V，板內相連 |
| 背面「要焊 VIN 的焊點」↔ 正面第 2 腳 | 不導通 | 不是 5 V |
| 背面「要焊 GND 的焊點」↔ USB 或 HDMI 插座的金屬外殼 | 導通 | 是地 |
| 背面「要焊 SDA／SCL 的焊點」↔ 正面第 3／5 腳 | 導通 | 位置對 |

Add text to §2.1: "從背面看排針是左右相反的。不要用『左邊／右邊』找腳，用上表的電表結果找。第 1、3、5、7、9 腳在**同一排**（離板邊較遠的那排）；第 7 腳（1 與 9 之間第四個）不接。"

After soldering, keep the two existing checks and add a powered check **before the HAT goes on**: "只接電源開機，量模組上 VIN ↔ GND = 3.2–3.4 V；SDA、SCL 對 GND 也是 3.2–3.4 V。任何一點超過 3.6 V：立刻斷電，回報。"

Also say at the top of §2: "斷電、拔 SD 卡、HAT 不在 Pi 上時才焊；背面的線頭用膠帶固定，Pi 不要放在金屬桌面上。"

### M6. `git log --oneline -1` fails in WSL at that path (verified)

Section: §5.

What goes wrong: `C:/src/Batman-255d` is a git worktree; its `.git` file holds a Windows path. In WSL the command prints `fatal: not a git repository: /mnt/c/src/Batman-255d/C:/src/Batman-app/.git/worktrees/Batman-255d`. The operator is stopped at the first line of the build, and the commit to record is unknown. (The `go build` line itself was run as written, with a throwaway `GOCACHE` and `-o /dev/null`: exit 0. The toolchain path exists and reports go1.26.4.)

Replacement: take the commit on the Windows side first (Git Bash or PowerShell):

```sh
git -C C:/src/Batman-255d log --oneline -1      # a62c5a0 unless the branch moved
git -C C:/src/Batman-255d status --short        # no output expected
```

then the WSL block without the `git log` line.

---

## MINOR

1. **§1.1 orientation words.** "左上角" is only true with the 40-pin header at the top, as in the photo; say so. For C6/C7 say how a capacitor sits: "每顆電容直放，跨在同一組的上、下兩個焊盤；不要橫跨兩組" (the zoom photo shows two footprints, each with an upper and a lower pad). A capacitor laid across the two upper pads joins two pads that are probably the same net and does nothing.
2. **§3.1 / §3.2 order.** The heading says to measure the voltage first, but it comes after `raspi-config` and `apt-get`. Move the pin 8 measurement to directly after step 2 of §3.1. Measure on the capacitor's VCC pad (found in M3), not on the SOIC lead; the joint itself is covered by M4.
3. **§3.2 `xxd` expected output.** `xxd` prints `00000000: 0001 86a0  ....`, not `000186a0`. Use `od -An -tx1 /sys/bus/i2c/devices/i2c-1/of_node/clock-frequency` and expect ` 00 01 86 a0` (the same form as the #300 comment). `od` is in coreutils; `xxd` being present on Lite is from memory (medium confidence).
4. **§3.2 `/sys/bus/i2c/devices` has no pass rule.** State it: "`i2c-N` 是匯流排本身，不算裝置。出現 `1-00xx` 這種名稱 = 核心綁了一個裝置：**停**，回報。預期沒有任何 `1-00xx`。" If `/dev/i2c-1` is missing: "`sudo reboot` 後再看一次；還是沒有就停。" The expected owner on Raspberry Pi OS is `root i2c`, mode `crw-rw----` (memory, high confidence); the first user is in group `i2c`, so `sudo` is normally not needed.
5. **§4: `60` can show up and must not be a stop.** Any transfer that holds SDA low for 60 µs wakes the chip (`608b-facts.md:291`). Writing register pointer `0x00` to the RTC, or reading an RTC byte that is `0x00`, does this at 100 kHz. A scan run within about a second of RTC traffic can show `60`. Add a row: "出現 `60`：是 608B 被匯流排上的 0x00 位元組叫醒，正常，記下來，繼續。" Also run the scan once more after E1 and save it (design E0a: the wake pulse must not disturb other devices).
6. **§6 RTC compare.** Status register bit 2 (BSY) is set for a fraction of a second every 64 s during temperature conversion (DS3231 datasheet, from memory, high confidence). Add: "只有第二個位元組的 bit 2 不同（例如 `0x88` ↔ `0x8c`）：再讀一次；仍然只差這一位就算相同。"
7. **`HH`.** The sentence about `HH` sits in §7, whose commands do not use it; the first use is in §8. Remove the hand substitution: in §7 add `B17=$(grep '^byte17=' e1-dump.txt | cut -d= -f2); echo "byte17=$B17"` (must print two hex digits) and use `-byte17 "$B17"` in §8. Note in §7 and §8: "新開的 SSH 連線要先 `cd /dev/shm; set -o pipefail` 並重新設 `B17`。"
8. **§8 "代碼 3 … 照訊息處理" leaves the decision to the operator.** Replace with: "`byte 17 = xx, -byte17 = yy`：`B17` 設錯，照 §7 重設後重跑一次。其他任何拒絕訊息：**停**，回報；不要改 `allow.txt`。"
9. **Allow list origin.** Design §8.0 says the list is "開發者電腦傳入". The runbook builds it on the rig from whatever chip is there, which makes the gate pass for any chip. To follow the design: copy `e1-info.txt` to the developer machine, compare the serial by eye with the E1 record, create `allow.txt` there, and `scp` it to `/dev/shm`. If the shortcut is intended, say so in the runbook as a stated deviation.
10. **Results that are never written to a file.** §3.2, §4, the RTC re-read and the general-call line in §6, and `compare` in §8 only go to the screen ("把輸出存下來" does not say how). Pipe each through `2>&1 | tee -a /dev/shm/e0a.txt` (and `e3-compare.txt`), add them to the §10 list, and give the copy-back command, run on the developer machine: `scp '<使用者>@<實驗台>:/dev/shm/*.txt' <目的資料夾>/`. Move "斷電前先複製" from §11 to the end of §8 as a numbered step.
11. **Small gaps for a literal follower.**
    - `sudo apt-get update` before `apt-get install` on a fresh image.
    - `chmod +x /dev/shm/se-lab` after `scp` (the mode normally survives; it costs nothing).
    - §3.1 step 2: "HAT 插回前斷電；40 支腳全部對齊、沒有錯開一排或一格再上電" — an offset HAT puts 5 V on a GPIO.
    - §8 `written_words=`: the estimate is ⚠️ (blank values are unknown until E1); the hard upper bound is 23 (`dev.go` `ImageWords`: 9 + 4 + 10).
    - §2.1 "CR1220 正極朝上" and "pull-ups on VIN" come from memory of the Adafruit board, not from a source in the repo: mark ⚠️ or cite the Adafruit page.

---

## Gaps against the design rows

| Design item | Runbook | Status |
|---|---|---|
| E0a read-only scan, no quick-write | §4 `i2cdetect -y -r 1` | ok |
| E0a kernel-bound devices | §3.2 `ls /sys/bus/i2c/devices/` | no pass rule (minor 4) |
| E0a wake pulse does not affect others | §6 RTC re-read | ok; add second scan (minor 5), BSY note (minor 6) |
| E0a owner and mode of `/dev/i2c-1` | §3.2 | ok |
| E0a bus speed ≤ 100 kHz, stop otherwise | §3.2 | ok (output format, minor 3) |
| E0a general-call ACK recorded | §6 | ok |
| E0a "only known devices", else stop | §4 | ok |
| E1 revision `00 00 60 03`, stop otherwise | §6 and tool exit 3 | ok |
| E1 unlocked, address `0xC0`, bytes 13 / 17 / 19 | §6 | ok |
| E1 generate and attach the image | §8 `image` (before the write) | ok |
| E2 data write refused; Random recorded | §7 | ok |
| E2 fail → change §5 | §7 "停，回報" | ok |
| E3 write variant, read back, equal | §8 | ok; rc handling wrong (M1) |
| §8.0 tool on tmpfs, not in an image | §5 | ok |
| §8.0 list passed in from the developer machine | built on the rig | deviation (minor 9) |
| §8.0 consent before touching the rig | §11 | ok |
| §8.0 E4 and later excluded | scope, end of §8 | ok |

## Commands

| Command (runbook §) | Checked against | Result |
|---|---|---|
| `sudo raspi-config nonint do_i2c 0` (§3.1) | memory of raspi-config (0 = enable; applies the dtparam and loads `i2c-dev` at runtime), high confidence | ok |
| `sudo apt-get install -y i2c-tools` (§3.1) | Debian package name | ok; add `apt-get update` |
| `cat /proc/device-tree/model` (§3.2) | Linux | ok |
| `ls -l /dev/i2c-1` (§3.2) | design E0a | ok |
| `xxd …/of_node/clock-frequency` (§3.2) | xxd output format; #300 comment shows `00 01 86 a0` | command ok, **expected text wrong** (minor 3) |
| `ls /sys/bus/i2c/devices/` (§3.2) | design E0a | ok, no pass rule |
| `i2cdetect -y -r 1` (§4) | i2c-tools man page (memory, high) | ok |
| `i2ctransfer -y 1 w1@0x68 0x00 r7` (§4, §6) | i2ctransfer syntax; DS3231 0x00–0x06 | ok |
| `i2ctransfer -y 1 w1@0x68 0x0e r2` (§4, §6) | DS3231 0x0E control, 0x0F status | ok |
| `cd /mnt/c/src/Batman-255d/feed/batman-prov/src` (§5) | path exists, `vendor/` present | ok |
| `git log --oneline -1` (§5) | run in WSL | **wrong: fatal, not a git repository** (M6) |
| `export PATH=…go1.26.4…/bin:$PATH` (§5) | path exists in WSL, `go version go1.26.4` | ok |
| `GOFLAGS=-mod=vendor GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o /tmp/se-lab ./cmd/se-lab` (§5) | run in WSL with `-o /dev/null`: exit 0; matches `main.go:7` | ok |
| `sha256sum …` (§5) | — | ok |
| `scp /tmp/se-lab …:/dev/shm/se-lab` (§5) | `/dev/shm` on Raspberry Pi OS is tmpfs without `noexec` (memory, high) | ok; add `chmod +x` |
| `./se-lab info \| tee e1-info.txt` (§6) | `main.go:92,161,188`: prints `revision=`, `serial=`, `lock_config=`, `lock_data=` | ok; exit code and stderr lost (M1) |
| `./se-lab dump \| tee e1-dump.txt` (§6) | `main.go:163-168`: `config[ 16]=c0 …`, `byte13=`, `byte17=`, `byte19=` | ok; same |
| `i2ctransfer -y -a 1 w1@0x00 0x00; echo "rc=$?"` (§6, §9) | `-a` needed for 0x00 (#300 comment 2026-11-21); same byte that `dev.go` `wake()` sends | ok |
| `grep '^serial=' e1-info.txt \| cut -d= -f2 > allow.txt` (§7) | `readAllow` (`main.go:253`): one 18-hex line | ok |
| `./se-lab -allow allow.txt data-write 6 \| tee …` (§7) | `main.go:96-104,198-211`: `data_write_slot6=status_xx` or `=accepted`, exit 0 | ok |
| `./se-lab -allow allow.txt random \| tee …` (§7) | `main.go:190-197`: `random=` and 64 hex digits | ok |
| `./se-lab -byte17 HH image \| tee …` (§8) | `main.go:109-122,240`: no bus opened | ok |
| `./se-lab -allow allow.txt -byte17 HH write-image \| tee e3-write.txt; echo "rc=$?"` (§8) | `main.go:215-236`: `written_words=`, `compare=EQUAL` / `DIFFERENT`, exit 0 / 4 | command ok, **`rc` is tee's, always 0** (M1) |
| `./se-lab -byte17 HH compare; echo "rc=$?"` (§8) | `main.go:215,228-236` | ok (not saved, minor 10) |
| second `write-image` → `written_words=0` (§8) | `dev.go` `WriteConfigImage` writes only differing words | ok |
| `./se-lab dump \| tee e3-dump.txt` (§8) | as above | ok |
| `i2ctransfer -y 1 r4@0x60` on its own line (§9) | watchdog 0.7 s minimum, `608b-facts.md:287`; expected `0x04 0x11 0x33 0x43` = `dev.go` `wakeOK` | bytes ok, **must be on the same line as the wake** (M2) |
| Exit-code list (§5) | `main.go:26-27,46-52` | ok |
