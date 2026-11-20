# Design review round 1 — #329 A1 honest error messages (v1)

Two independent reviewers, whole document. A: APPROVE-WITH-CHANGES. B: REJECT.

| # | Sev | Finding | v2 |
|---|---|---|---|
| 1 | MAJOR | C1 named 「還沒設定手機 Wi-Fi」 as the cause. JOINED + CRIT also comes from a critical battery, a core service down, the mesh key (`halow-status:72-91`); the neutral lead is a reviewed decision (`254-app-status-page.md` T4). | lead kept, action added |
| 2 | MAJOR | C2 split "link not up" from "no answer" with data `_lfAttempt` does not carry, and counted any silent device. | two endings; counted only on a 「是 Y」/「像 Y」 address; hint is unauthenticated, stated in §3 |
| 3 | MAJOR | C2: `LoginForResult` / `OpReply` change breaks the test fakes; tests called `loginLine` directly. | named optional; tests drive the pages |
| 4 | MAJOR | C3 said the update needs other nodes: false for `NEED_MESH=0` and for the other revert causes (`batman-autocommit:451-554`). | 「常見原因…若已加入隊伍網路」 |
| 5 | MAJOR | C4 changed `StatusHero` for ~25 users and claimed the page stops moving; warning states still grow. | opt-in on two pages, limits stated |
| 6 | MAJOR | C5 「只留下下面這 N 把」 is false: the node keeps the keys the app did not add (`node.go:839-880`). | wording corrected |
| 7 | MAJOR | Tests asserting a constant against itself are not negative controls. | literals |
| 8 | MINOR | F8 (Bluetooth off) is not a bug in source; say so. | F8 row, §5 |
