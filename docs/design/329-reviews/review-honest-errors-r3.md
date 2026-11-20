# Design review round 3 — #329 A1 honest error messages (v3)

Two new independent reviewers, whole document. Both: APPROVE-WITH-CHANGES. A: 1 MAJOR. B: 0 BLOCKER / 0 MAJOR
(eleven field situations walked through the code).

| # | Sev | Finding | v3.1 |
|---|---|---|---|
| 1 | MAJOR (A), MINOR (B) | C1: the action was unconditional. With the phone Wi-Fi already set (battery / service CRIT) the user is sent to set it again, which drops the phones on it (`254-app-status-page.md:28`). | 「還沒設定的話，請到…；已設好仍然如此請找維修人員」 |
| 2 | MINOR (B) | C2: 「找到了這台節點」 is false when a stranger replays the advertisement with the node off. | 「附近有像是這台節點的裝置」; memo path added to §3 |
| 3 | MINOR (B) | C3: a node in no network could not tell whether it may try again. | 「可以再更新一次」 moved out of the condition |
| 4 | MINOR (A, B) | C3: the line shows only on the run's result screen. | limit stated |
| 5 | MINOR (A, B) | C4: `next` must be reserved when null; the cost was understated. | `next` reserved when null, title two lines; cost stated |
| 6 | MINOR (A, B) | C5: the dialog must scroll; keys for the tests. | stated |
| 7 | MINOR (A, B) | §4: (h) does not compile today; `retest_s_boards_test.dart:23,:344`; paths. | corrected |
| 8 | MINOR (B) | A reflashed node at its old address reads 「沒有找到」 (as today). | limit (d) |

The one MAJOR is a one-clause rewording both reviewers proposed in the same words; applied and frozen without a
fourth design round. The code review (two reviewers) covers the final texts.
