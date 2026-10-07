# #263 root fix — morse_driver command skb ownership (patch 016)

v1, 2026-10-07. Driver: Gateworks/morse_driver @dec5bc2 + openmanet patches 0001..015 (PKG_VERSION 1.16.4-gateworks); module `mm6108_sdio.ko`, mm6108 over SPI, **pageset** TX path (`pageset.c`), kernel 6.6.138.

## 0. Crash localization (done, evidence)

The Oops symbol name is misleading: kallsyms only knows a subset of statics, so `morse_mac_get_mcs_mask+0x4c/0x578` means "0x4c into the 0x578-byte unnamed gap after `morse_mac_get_mcs_mask`" (0xb47c..0xb9f4). Checked with the real `.ko` pulled from 04 (md5 746e973f…): nm shows `morse_mac_get_mcs_mask`@0xb47c and the next symbol at 0xb9f4, so the gap is exactly 0x578 and matches the Oops, which means the layout is the crash-time layout.

objdump (toolchain aarch64-openwrt-linux-musl-objdump):
- 0xb488 = the static `__morse_skbq_unlink(mq=x0, queue=x1, skb=x2)` (skbq.c:200), inlined `__skb_unlink`:
  `ldr w0,[x20,#16]; sub; str` (queue->qlen--), `ldp x1,x0,[x19]` (next, prev), `stp xzr,xzr,[x19]`, **`b4c8: str x0,[x1,#8]`** (next->prev = prev). That last store is the faulting PC: write to 0x8 means `skb->next == NULL`. The Oops registers show x0 = x1 = 0, so next == prev == NULL.
- lr `morse_skbq_skb_finish+0x1dc` = 0xcc08. That is the return address of `bl b488` at 0xcc04, reached from `ldr w1,[x0,#64]; cbnz w1, cbfc`, i.e. `mq->pending.qlen != 0`. So it is the **first branch of `__skbq_cmd_finish`** (skbq.c:1038-1040): `__morse_skbq_unlink(mq, &mq->pending, skb)`.
- Caller chain: `morse_cmd_vendor` → (static, shown as `morse_log_modparams+…`) `morse_cmd_tx` → `morse_skbq_skb_finish` (command.c:193, the timeout/cleanup path) in the morse_cli netlink context.

**Conclusion**: `morse_cmd_tx` finished a command skb that was **not on `pending`** (next and prev already zeroed, i.e. it had already been dequeued), while `pending.qlen > 0`. Next and prev are zeroed only by `__skb_unlink`/`__skb_dequeue`. Every caller that dequeues a cmd skb and does not relink it then frees it (`morse_skbq_purge` → `dev_kfree_skb_any`). So the command thread is operating on an skb the TX worker **already dequeued and freed** (use-after-free; the freed skbuff_head still reads next = prev = 0).

## 1. Root cause (code)

Command skbs have **two owners and no ownership protocol**:

| who | context | lock held | what it does to cmd skbs |
|---|---|---|---|
| C = `morse_cmd_tx` (command.c:110) | caller (netlink/morse_cli, mac80211 ops) | `cmd_wait`, `cmd_lock`, and `mq->lock` around finish | enqueue to `skbq`; on completion/timeout `morse_skbq_skb_finish` → `__skbq_cmd_finish` = unlink + **free** |
| W = `morse_pageset_tx(cmd_q)` (pageset.c:618) | chip_if work | `mq->lock` only inside helpers; **not cmd_lock** | `morse_skbq_purge(mq,&mq->pending)` = dequeue + **free** every pending cmd skb (pageset.c:644-646, "this should not happen"); `deq` from skbq to a **stack list**; SPI write (can stall for seconds: "SPI transfer timed out"); then `tx_complete` → `pending`, or `skbq_failed` → purge/**free** |
| R = `morse_cmd_resp_process` (command.c:609) | RX dispatch work | `cmd_lock`; `mq->lock` only for the peek | `skb_peek(pending)`, then **after dropping mq->lock**: `skb_pull` header (command.c:635, before the match check) and read `resp_cb` |

Defects:
- **D1** `__skbq_cmd_finish` (skbq.c:1034) infers *where* the skb is from **queue lengths** (`pending.qlen > 0` → assume it is on pending; `skbq.qlen > 0` → assume skbq), not from membership. When the skb is in W's stack list, already moved, or already freed, it unlinks from the wrong list. That corrupts both lists' `qlen` (u32 underflow is possible, which makes `pending.qlen > 0` permanently true), corrupts W's stack list, and double-frees or frees in-flight skbs.
- **D2** W frees cmd skbs (purge pending / purge failed) that C still references and will finish later. This is a UAF, and it is the observed crash.
- **D3** R `skb_pull`s the header off the first pending skb **before** checking that the response matches. A late response therefore strips the header of the live command; when the real response then arrives, R reads the ids at the wrong offset, sees a mismatch, treats it as a late response, and the live command times out. That is a **timeout cascade**, which in turn produces more D1/D2 windows. R also dereferences the peeked skb after releasing `mq->lock`, while W can free it (UAF).

Trigger: anything that makes a command's response slower than `default_cmd_timeout_ms` (600 ms) while the skb is still with W. Typical cause is an SPI stall ("SPI transfer timed out") → late response. Exposure scales with the command rate; meshled issues `morse_cli stats` every 5 s.

## 2. Fix (one patch, `016-cmd-skb-ownership.patch`)

Principle: **C owns the command skb lifetime via a reference; W and R never free or mutate it outside `mq->lock`, and finish unlinks only from the list that actually contains it.**

- **F1 (D2) C holds its own reference.** In `morse_cmd_tx`, after `morse_skbq_skb_tx` returns 0 (the skb is queued; `*skb` may have been replaced by the copy-expand path, so we take the reference on the returned pointer), and **under `mq->lock`**, do `skb_get(skb)`. Taking it under the lock is safe against W: W only dequeues under the same lock, so it cannot free the skb between the enqueue and the `skb_get`.
  - Wait: `morse_skbq_skb_tx` itself takes and drops the lock internally. So W *can* dequeue, write, and (on failure) purge-free the skb before C reacquires the lock. Hence F1 has to be done **before** enqueue: call `skb_get` on the skb before `morse_skbq_skb_tx`. Problem: if `morse_skbq_skb_tx` replaces `*skb` (headroom copy), the new skb has refcount 1 and the old one keeps our extra ref. Resolution: allocate the cmd skb with enough headroom/tailroom so that `morse_skbq_skb_tx` never reallocates it (verify by reading skbq.c:1425-1500: `morse_skbq_alloc_skb` already reserves `sizeof(hdr)` + alignment for exactly this purpose). Then assert `skb == original` after the tx (WARN + handle by dropping our ref on the original).
  - **Verified (skbq.c:1409-1497)**: `morse_skbq_skb_tx` never replaces `*skb_orig`. `morse_skbq_alloc_skb` reserves headroom (hdr + extra_tx_offset + bulk_alignment) and the 4-byte tail pad, so `skb_push`/`skb_pad` do not reallocate. Final F1: `skb_get(skb)` **before** `morse_skbq_skb_tx`. On a non-zero return, skb_tx has already dropped one reference, so C drops its own and breaks.
  - Shared-skb hazard: once refcount is 2, any `pskb_expand_head`/`skb_cow` on the TX path would BUG_ON(skb_shared). This needs checking: `morse_pageset_write` / bus write and checksum code must not expand cmd skbs (reviewer: verify).
  - Then W's `dev_kfree_skb_any` only drops W's reference, and the memory stays valid until C's final `kfree_skb`.
- **F2 (D1) membership-checked finish.** New `__skbq_cmd_finish`, under `mq->lock`:
  ```c
  if (__skb_on_list(&mq->pending, skb))      __morse_skbq_unlink(mq, &mq->pending, skb), dev_kfree_skb(skb); /* list's ref */
  else if (__skb_on_list(&mq->skbq, skb))    __morse_skbq_unlink(mq, &mq->skbq, skb),    dev_kfree_skb(skb); /* list's ref */
  else  /* in flight in W (stack list) or already freed by W: W owns the list ref */ ;
  dev_kfree_skb(skb);  /* C's own ref (F1) */
  ```
  `__skb_on_list` = `skb_queue_walk` pointer compare. The cmd queue holds a handful of entries at most, so O(n) is fine.
- **F3 (D3) R does the match before mutating, and does it under `mq->lock`.** Peek the first pending skb **and** read its header ids at the *unpulled* offset (`data + sizeof(morse_buff_skb_header) + hdr->offset`) under `mq->lock`. Only on a match: `skb_get` the cmd skb, drop the lock, and copy the response into `dest_resp`. Never `skb_pull` the pending skb at all; compute the request pointer instead, so the operation is idempotent. Release the ref at exit.
  - Also guard against a stale skb (C already returned) matching by seq (impossible across commands because `cmd_seq` increments per command; within one command, every retry shares the caller's live `dest_resp`). Unchanged.
- **F4 (observability)** Rate-limited counters plus a log line when finish finds the skb in neither list (`cmd skb in flight at finish`) and when W purges a non-empty cmd pending list. These make the race visible in the field without crashing.

Not changed: W's purge-of-pending policy itself, retry policy, timeouts.

## 3. Alternatives considered
- **A1 Raise `default_cmd_timeout_ms`** (e.g. 600 → 3000 ms): only narrows the window, does not fix D1–D3. Rejected as a fix (workaround; user directive: root fix). It may still be worth considering *in addition*, separately.
- **A2 Serialize W's cmd_q handling under `cmd_lock`**: W runs in the chip_if work that also does RX/data; taking a sleeping mutex held by C across a 600 ms wait would stall all TX/RX. Rejected.
- **A3 Only fix F2 (membership)**: does not cover D2 (W frees an skb C still holds → UAF on any C access, e.g. `resp_cb` reads). Rejected alone.
- **A4 Upstream newer driver** (Morse 1.17+/2.x): no evidence it is fixed upstream; the Gateworks fork pins 1.16.4. Worth a check-and-report, but it does not block this patch.
- **A5 Reduce `morse_cli stats` frequency/caching** (#263 noise cache): exposure reduction, not a fix. Per the user directive, it is not the fix. May still land later as an efficiency change.

## 4. Failure modes of the fix
- FM1 Extra ref leaks (C path that returns early without the final put) → memory leak per command. Mitigation: a single exit path in `morse_cmd_tx`; review each `break`.
- FM2 `morse_skbq_skb_tx` replaces the skb → our ref is on the wrong object. Mitigation: F1 verification plus a WARN fallback.
- FM3 R's no-pull change: other code that relies on the pending cmd skb having been pulled (e.g. finish or debug dumps)? Grep `remove_hdr_after_sent_to_chip` callers; the cmd path only uses it in R.
- FM4 Module unload / driver restart (`morse_skbq_finish`, `tx_flush`) while C holds a ref: purge drops the list ref and C drops its own later; no UAF. Restart while C is waiting: `cmd_comp` timeout path → finish → membership miss → put own ref. OK.
- FM5 yaps path (mm8108) has the same structure (yaps.c:293-295). The patch must cover both or explicitly scope to pageset. **Decision: fix the shared code (skbq.c / command.c) so both benefit**; W changes are not needed for either.

## 5. Test plan
- **T0 build**: patch applies on top of 0001..015; build for **bcm2711 (Pi4)** and bcm2710; no new warnings.
- **T1 deterministic repro on stock (DESTRUCTIVE — may panic; needs user OK; target 02, never 03 which is the only bridge)**: `echo 5 > /sys/module/mm6108_sdio/parameters/default_cmd_timeout_ms`, then loop `morse_cli -i wlh0 stats` (plus a parallel data load such as an iperf to a peer so W is busy) for up to 10 min. Record: late responses/min, "Command Q not found", Oops (y/n, time to Oops). Restore 600 afterwards. If no Oops in 10 min at 5 ms, try 1–2 ms.
- **T2 same load on patched module**: 30 min, no Oops; F4 counters show the race being *hit* (in-flight-at-finish > 0), which proves the window was exercised; `morse_cli stats` keeps working once the timeout is restored to 600; slab skbuff_head_cache stable (no leak: compare `/proc/slabinfo` before/after).
- **T3 regression**: daily-validation full (tput/mesh/HaLow suites) on a 1.5.5 build containing the patch; 24 h idle soak.
- **T4 daily-validation**: add `halow-cmd-timeout-race` as a tier-B (manual/destructive-gated) check that runs T2 for 5 min on the bench node; plus an auto-tier check that greps the boot's dmesg for the F4 counter line and Oops.

## 6. Second root (separate): why SPI stalls
D1–D3 turn SPI stalls into panics; the stalls themselves are #270/#263's other half: undervoltage on 03 (throttled=0x50000), and the correlation with p5 rw-mount (joinwatch churn, M0). Those are tracked separately: M0 is fixed by the joinwatch latch; power needs the PSU swap control test. This patch makes stalls survivable; it does not remove them.

## 7. v2 — review v1(FAIL)併入:取代 §1 的因果敘述與 §2 的 F1–F3、§5 的 T1

**因果更正(review #2)**:pageset 的 W 是 singlethread workqueue,每輪只處理 1 個 cmd page,而且每次 dequeue 下一個 cmd 前都會先 purge pending。只要 qlen 和真正的 list 一致,「W 釋放了 C 的 skb」(D2)只會讓 C 落進無害的「Command Q not found」。**崩潰必須先有 D1 造成 qlen 錯帳**。D1 才是主 bug。

可重現 Oops 特徵的具體交錯(review 推導,和 log 一致):
1. A0 已經寫進 chip,但 `put()` 卡在 SPI 超過 600 ms;
2. C 對 A0 逾時,落進「not found」,A0 留在 W 手上;C 送出 A1,此時 skbq={A1};
3. W 的 tx_complete 把 A0 放上 pending={A0},然後又卡在 SPI;
4. C 對 A1 逾時:`pending.qlen==1`,於是把**其實在 skbq 上的 A1** 從 pending unlink。這一步不會當機,但造成錯帳:skbq 的 list 已經空了、qlen 卻是 1;pending 的 list 是 {A0}、qlen 卻是 0;
5. 下一個命令 B0(dfe0):W purge pending 時,dequeue 掉 A0,`pending.qlen` 從 0 **下溢成 0xFFFFFFFF**。接著 B0 寫入 SPI 失敗 → 進 skbq_failed → 被 purge(free 掉,next/prev = NULL)。但 chip 已經收到了;
6. 回應進來,R 去 peek pending,是空的 → log「Late response … have 0x0000:0000」;
7. C 對 B0 逾時:`pending.qlen=0xFFFFFFFF > 0` → 對 B0 做 unlink → next 是 NULL → 寫 0x8 → Oops。

**新抓到的真問題**
- **D4(BLOCKER)stale `dest_resp` 記憶體破壞**:R 的 `memcpy(dest_resp, …)`(command.c:668-673)不受 `cmd_comp` 管控。如果最後一次 retry 被放棄、C 已經返回,之後同一個 seq 的回應又到了(cmd_seq 要到下一次呼叫才會變),R 會把資料寫進**已經失效的呼叫端 stack**,或寫進已經送出並釋放的 vendor reply skb(vendor.c:55-73)。
- **D5 只比對 head**:結果寫到 pending 第一個 skb 的 `resp_cb`,但 C 讀的是自己那個 skb 的 `resp_cb->ret`。有 retry 時,head 可能是同一個 seq 的舊 skb → C 得到 0(假成功),或讀到已釋放的記憶體。
- D3 被高估:長度 < 256 bytes 的請求,第二次 pull 會是 no-op(像 stats 這種)。≥ 256 bytes 的才會讀錯造成連鎖。修法不變。

**v2 修法(採 review 建議;不用 refcount)**
1. **`struct morse` 加 `cmd_inflight { u16 host_id; struct morse_cmd_resp *dest; u32 length; int ret; bool valid; }`**,只在 `cmd_lock` 下讀寫。C 每次 try 送出前設定(包含這次 try 的 host_id),結束(完成或逾時)時、仍持有 `cmd_lock` 的情況下 `valid=false`,然後才返回。
2. **R 只對 `cmd_inflight` 比對**,全程在 `cmd_lock` 下:`valid` 且 seq 相同(retry bits 可以不同)→ 複製到 `dest`、設 `ret`、`complete`;否則就是 late response,只釋放回應。**R 完全不碰 cmd_q 的 list 和 skb**,所以 D3、D4、D5 都消失。
3. **cmd skb 永不進 pending**:`morse_skbq_tx_complete` 遇到 `MORSE_SKB_CHAN_COMMAND` 直接釋放(送到 chip 之後,host 端不需要這份 skb,回應的路由已經改走 `cmd_inflight`)。pageset.c:644 和 yaps.c:293 的「purge pending」改為 no-op(保留但永遠是空的)。**W 一旦 dequeue 一個 skb,W 就是它唯一的擁有者**。
4. **C 的收尾**(在 `mq->lock` 下):在 `mq->skbq` 上用指標逐一比對(不 deref 其他欄位),找到才 unlink + free;找不到就什麼都不做(W 擁有它)。沒有 refcount,也就沒有 shared-skb BUG 的風險。
5. **`__morse_skbq_unlink` 加成員資格防護**:skb 不在指定的 queue 上就 `WARN_ONCE` 並跳過(用 `skb->next` 非 NULL 加上 walk 確認)。另外加 qlen 一致性計數:debugfs 可讀;不一致時 `WARN_ONCE`(F4)。
6. yaps(mm8108):`update_status` 失敗時提早 return 會漏掉整個 `skbq_to_send` 的 skb → 改成 requeue(prepend)。被放棄的 cmd 在 prepend 後會被重送 → W 寫入前丟掉 seq ≠ `READ_ONCE(cmd_inflight.host_id)` 的 cmd skb。我們用的是 mm6108/pageset,這一項只做到「不會更糟」,並註明沒有上機驗證。

**v2 測試計畫(取代 T1;不調低全域 timeout)**
- **T1' 故障注入**:只在 debug build 加 module param,正式 build 不帶:
  - `fi_cmd_put_delay_ms`:pageset 的 cmd 在 `put()` 之後、`tx_complete` 之前 msleep;
  - `fi_cmd_put_fail`:`write_page` 之後強制讓 `put()` 失敗;
  - `default_cmd_timeout_ms` 保持 600 不動。
  - **stock 程式碼 + 故障注入 + qlen 一致性 WARN**:預期在第一次錯帳(步驟 4)時就 WARN,不必等到 Oops,大幅降低 panic 風險。
  - 只在 02 做,先停 joinwatch 和 config-save,避免 p5 寫入時剛好當機。
  - 可選:開機參數 `slub_debug=FZP,skbuff_head_cache`。
- **T2' patched + 同樣的故障注入**:30 分鐘不得出現 Oops 或 WARN;qlen 和 skbq_size 要等於實際走訪的長度;slabinfo 穩定;timeout 恢復預設後 `morse_cli stats` 正常;再用 daily-validation 跑 mesh/tput 回歸。
- **T3** 全套 daily-validation 加 24h soak(1.5.6-rc)。

## 8. v2.1 — v2 複審(PASS-with-changes)併入;實作以 mm6108-2.0.1 + openmanet 0001..022 為準,patch 編號 **023**

- 步驟 3(tx_complete 直接釋放 cmd skb)經複審確認安全,涵蓋 PS、tx_status、pager、restart 與 debug 路徑。附帶好處:pending.qlen 下溢成 0xFFFFFFFF 會讓 `needs_wake` 永遠成立、stale 計時器一直觸發,這個現象也一併消失。
- 實作細節:
  - `morse_skbq_tx_complete` 的 locked walk 裡加 `case MORSE_SKB_CHAN_COMMAND: dev_kfree_skb_any()`,不設 `skb_awaits_tx_status`。
  - **`valid` 在同一次呼叫的多次 retry 之間保持為真**:`message_id` 與 seq 每次呼叫設一次,每次 try 只更新 retry bits,返回前才清掉。
  - 加 `delivered` 旗標:C 判定逾時後,在 `cmd_lock` 下若發現已經 delivered,就改走成功路徑。
  - 比對時 `message_id` 和 seq 都要一致,retry bits 可以不同。
  - C 一律從 `cmd_inflight.ret` 讀結果,不再讀 skb 的 `resp_cb`。
  - W 端丟棄過期 cmd:用單一 `u32 cmd_live_host_id`(0 代表沒有),在 `cmd_lock` 下 `WRITE_ONCE`,比對完整 host_id(包含 retry bits)。pageset 可以不做;yaps 必須在建 `to_chip_pkts[]` 之前丟。
- **成員資格檢查改成 O(1)**:共用 helper 只檢查 `skb->next && skb->prev && skb->next->prev == skb && skb->prev->next == skb`,不成立就 `WARN_ONCE` 並跳過。只有 cmd 路徑會走訪整條 list;qlen 的走訪比對只在 debugfs 讀取時或 debug build 才做,避免拖慢資料路徑。
- **T1' 改成三個一次性旋鈕**,只作用在 cmd,經 debugfs 觸發:
  - (a) `put` 之後延遲約 800 ms;
  - (b) **tx_complete/notify 之後延遲約 600 ms**,這是重現步驟 4 的關鍵;
  - (c) 用「注入失敗」**取代**真正的 `put()`,不要在 put 成功之後才回錯誤(那會重複 put 同一個 page,可能把 pager/firmware 卡死)。
  - stock 版跑到步驟 4 的 qlen WARN 就停,不要讓它走到 Oops。真的要繼續,先設 `panic_on_oops=1`,否則持 spinlock 時 Oops 會 hard lockup。
- T2' 加兩項:
  - 同樣的旋鈕跑 patched 版:不得出現 WARN;A0 由 tx_complete 釋放;A0 的回應要能交給 A1 的等待;
  - (a) 調成約 300 ms:確認正在等的命令能收到回應,不會被當成 late。
