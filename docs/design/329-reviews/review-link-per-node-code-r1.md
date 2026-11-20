# Code review round 1 of 009d592 (feat/329-link-per-node) — two reviewers, findings and what was done

Both reviewers read the design (329-link-per-node.md v4), the whole diff and the tests; reviewer A also ran tests and one
mutation in a copy. Verdict of both: APPROVE-WITH-CHANGES.

## Findings

1. **MAJOR (A-1, B-1) — a raw lease is given while the kept links are still connected.** `acquire` called `_closeKept`
   without waiting; `LoginHandoff.destroy()` unsubscribes from tx before `link.close()`; until the unsubscribe
   returned the link was still open and parked, so `gate.active` was 0, `_dropAll` waited for nothing, and
   `gate.revoked` does not see a parked link. main waited on `gate.links`. L7 passed only because the rig's
   unsubscribe took no time. Reviewer A reproduced it with a 20 ms unsubscribe: `(gate.links, radio.open) == (2, 2)`
   when the lease was given.
2. **MINOR (A-2, B-2) — the same window after a record is removed, in `dispose`, and in `_makeRoom` when it is cut:**
   for a moment more than `keptMax` links. Reviewer A reproduced 3 links with a 2 s unsubscribe and 3 records.
3. **MINOR (B-3) — `_makeRoom` iterated the live `_kept.entries`** (safe only because of the `break`).
4. **MINOR (A-3) — the comment in `_makeRoom` named the wrong step** (the gap is the unsubscribe, not the dispose).
5. **MINOR (A-4) — L7 ran without a moving clock / slow close,** against the design's own rig rule.
6. **MINOR (B-4) — the wait in `_makeRoom` is bounded at about 6 s;** on timeout the connect is refused by the gate
   and counted as a failed attempt.

## Changes (the commit after 009d592)

- `_closeKept` closes the link at once and then destroys the handoff: the gate counts the link as closing from the
  first instant, so every place that looks at `gate.active` sees it (1, 2).
- `GateLink.close()`: a second call waits for the same end as the first (before: returned at once). Without this the
  handoff's own `link.close()` would return before the link is gone (T7 (c) and L15 fail).
- `acquire` waits for the closes it started (bounded at 5 s) before `_dropAll`: the lease is given with the sessions
  disposed (1).
- `_makeRoom` iterates a copy and no longer waits for the close itself: the wait on `gate.active` below it now sees
  the closing link (3, 4). The mutation "eviction not waited for" has nothing left to remove and is dropped.
- Rig: `KRadio.subCancelMs`, the unsubscribe of tx returns after that long on the fake clock. New tests: L7 with a
  300 ms unsubscribe; L20 (a kept link being closed is gone from the gate before its unsubscribe returns) (5).
- 6: not changed. A link that does not close within 6 s is already a failure of the stack; the refused connect is
  tried again in the next round.

## Negative controls

| mutation | failing test |
|---|---|
| `_closeKept` does not close the link first | L20 (and L11) |
| `acquire` does not wait for the closes | L7 (300 ms unsubscribe) |
| a second `close()` returns at once | L15 (and T7 (c) in kept_link_test.dart) |

The other 22 mutations of the first commit were run again: all caught.
