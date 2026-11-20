# Design review round 2 — #329 A1 honest error messages (v2)

Two independent reviewers, whole document. Both: APPROVE-WITH-CHANGES.

| # | Sev | Finding | v3 |
|---|---|---|---|
| 1 | MAJOR (A, B) | C5 dialog said 「不是 app 加的不受影響」 and dropped the exception already on the page: a key that was on the node and was also sent by the app is removed by any later replacement (`node.go:857-866`, `dev_pages.dart:89-91`). | the dialog shows `sshReplaceNote` |
| 2 | MAJOR (B), MINOR (A) | C3: reason 18 (no verdict from the health check, `updwork.go:899-908`) got the "cannot reach other nodes" sentence. | two lines |
| 3 | MAJOR (B) | C2 told the user to reboot a node that may be answering "busy" to this phone while serving another. | reboot removed, 「稍等…可能另一支手機正在連它」 |
| 4 | MAJOR (B) | `LoginForResult(this.end, [this.handoff])` cannot take a named optional. | second optional positional |
| 5 | MINOR (A, B) | C2: order of the check against the memo writes in `result()`; `near` never shrank after `undecryptable`. | rules per `Res`, removal, test (g) |
| 6 | MINOR (B) | C2: nothing tried while the gate is busy. | limit (c) |
| 7 | MINOR (A, B) | C4: about 90 dp of blank for good on the node page; three-line texts; the busy row is 48 high; membership can be empty. | home only; cost and limits stated |
| 8 | MINOR (A, B) | §4: (a)(d)(e) pass without the change; tap counts wrong (3, not 7 + 1); no test for reason 18 or for `found` with other endings. | §4 split into negative controls and guards with mutations |
| 9 | MINOR | C1: the old sentence is at `254-app-status-page.md:28` and `:73`. | both named |

Checked true by the reviewers: the same update file can be sent again after a revert; the test fakes still compile;
no generated bridge file holds the changed strings; §3 has no gap.
