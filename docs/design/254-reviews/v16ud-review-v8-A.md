# Review v8 — reviewer A — `docs/design/254-v16-ud.md` v8 (c518df7)

I read the whole document, focused on §0.6, §4.4 and the member-vs-claimed table. Every claim was checked against
`feed/` (wsl.36), the harness (`prov-254.sh`, `prov-p9-254.sh`, `prov-base-254.sh`), and the two device logs
(`v16ud-ud36-diag.log`, `v16ud-ud36-h0diag.log`). Read-only: no node, no ssh, nothing committed.

## 1. What holds in source

| Claim | Verdict | Evidence |
|---|---|---|
| Legacy → claim gives `claimed`, `Owners=[H0]`, gen + 1, radio and uci kept | **Holds** | `claimVerify`: Legacy / Unclaimed only (`node.go:566-567`); the legacy gate needs an authorized key (`:580-585`, the lab key, `pk_proof`); `next.State=Claimed`, `RadioManaged = rec.State == Unclaimed` → false for legacy (`:589-592`); `Owners` = the one key (`:593`). `peersRecordWritten` only resets the peer table (`peers.go:592-601`), not the radio. |
| Its side effects | **Hold, and the restore covers them** | Random 24-character root password, lock, `--save` (`setPassword`, `:604-607`); `SetLastKnown(claimed)` → p6 `prov-state`. Covered: p5 and overlay (shadow, dropbear lock config, `prov.cbor` / `prov.meta`) come back from the pre-`make_legacy` snapshot; `prov-state`, `lock-status` and `prov-counters` are in `STATEFILES` (`prov-base-254.sh:36`); the restore reboots, so the helper boots from p5's member record. |
| The update / bulk verbs check no prov state | **Holds in effect; one wording fix** | `update.check` is handled before `dispatch` (`node.go:231-240`); the update and bulk verbs are not in `stateChanging` (`:252-253`). But `ownerOpVerb` **does** check state: `rec.State != Claimed && != Member` → `EForbidden "no owner"` (`node.go:784-785`), and `dispatch` needs a loadable record. Claimed passes, so no row changes. |
| Trial mesh gate, claimed vs member | **Holds** | Claimed with a live key → `MeshExpect` "today" (`boot.go:381-393`) → autocommit's `*) :` branch keeps `NEED_MESH` from `expected_in_mesh` (S0 has `mesh-joined` / `mesh-expected`) and `RADIO_REQ=0` (`batman-autocommit:437-461`). Member → `RADIO_REQ=1`, `NEED_MESH=1` (no `ota-armed.mesh` on the app path). Both need 02, so UD1 / UD2 / UD4 / UD5 keep their assertions. The new P line (`mesh join required: 1 (prov=claimed …)`) is the right evidence. |
| Byte-for-byte restore of the record | **Holds** | `pr_compare diffs=0` over p5 / overlay / p6 state, plus the new scan compare (meta fields, record sha, owner-fingerprint multiset) against `ud-s0/<RUN>.txt`. The snapshot is taken before `pr_make_legacy` (`prov-254.sh:742-747`). |
| H0 and `claim.secret` handling | **Holds** | `claim.secret` is read by provclient as root on the node, before the drop (`provclient/main.go:533-539`), and never leaves the node. The claim reply's password / tag / adv are printed only as 8-byte sha prefixes of random values (Q9 reasoning). H0's private key stays a 0600 copy in WSL (`pr_h0`). The scan prints only fingerprints of 65-byte points. |
| Host death mid-arm | **Holds, apart from m1** | 04 stays legacy or claimed by H0 until §7.1 step 2 restores the snapshot; no journal action writes p5 (single writer); the dirty flag makes P9 print the block. |

The make-legacy → claim → final-restore cycle is the harness's existing path (`pr_make_legacy` / `pr_claim`, used by
every `PR_BASE=legacy` unit since #254 H3/H5), so the mechanics are not new.

## 2. Findings

### MAJOR

**M1. Q15's stated reason is false: a member state with `Owners=[H0]` on the bench mesh is reachable without the phone app.**
- The design says covering the member-only gate "needs an owner of 04 to add H0 (`owner.add`), and only the phone app's
  owners can do that". There is another route.
- After the H0 claim, `net.apply --first` (`netJoin`, `node.go:1106-1123`) needs only `rec.Net == nil` and a valid
  first-version `net_config` self-signed by its creator. A legacy-claimed node qualifies. The harness already has the
  sequence in `pr_member` (`prov-254.sh:870-888`: claim → `net-apply --first` → `state=member` → reboot).
- `pr_member` joins a **random test mesh**, which would cut 04 off from 02 and make every trial need-mesh gate fail.
  Given the **bench mesh's own** parameters instead, read on the node into fd 3 as `pr_member`'s `PR_FD3` already does
  (`mesh_id`, `channel`, `country`, the SAE key from `uci -q get`), 04 becomes `member`, `Owners=[H0]`, on the same mesh.
  Then `RADIO_REQ=1` and the `meshjoin_radio_up` gate (`batman-autocommit:564-565`) are exercised. That is the field
  case for app-path updates.
- Conditions to check before choosing this route:
  1. The real SAE key must never reach the host. It goes into the join body's secret part (key 3, `node.go:1111`). The
     design must show that neither the `SIGN` lines (provclient prints the input to sign) nor the `NETCFG` line carry
     it, or that the signed `net_config` holds only public parameters.
  2. The `NETCFG` line prints the mesh id, which the owner treats as redaction-worthy. Keep it out of the logs.
  3. The join rewrites the radio config through halow-setkey with the same values. One radio reload is a short mesh
    drop; say so in §1.7.
  4. The final restore already brings back p5, overlay and uci.
- Fix. Either adopt this route for the trial arm (UD1 / UD2 / UD4 / UD5 then run on a member, and the claimed-state
  rows stay as they are), or keep the gate uncovered **with the corrected reason** ("covering it needs a bench-mesh
  join with the live SAE key through the app path; not done because …"), as an informed owner decision. Either closes
  this finding; the current text does not.

### MINOR

1. **§7.1 still hard-codes `PR_S0_STATE=member`** (`prov-p9-254.sh:118`; design §7.1 step 2 and its step 3 comment
   "state=member … expected"). v8 now accepts member, claimed and legacy start states (§4.4 step 1). For a run that
   started claimed or legacy, `pr_finish_snap` finds end state ≠ `member`, runs one more restore, and ends NEEDS-PERSON
   (`prov-254.sh:528-544`). Fill it from the snapshot instead: P9 can read the state from the run's snapshot copy of
   `prov.meta` on p6, validated against `legacy|claimed|member`, as a fourth placeholder. Or the person reads it from
   `ud-s0/@DEAD@.txt`. Add a dry-run case with S0 = claimed.
2. **Q14: a per-run owner key is at least as good as H0.**
   - Nothing in the rows needs H0's identity any more, since it is not 04's owner.
   - `pr_claim` already claims with the run's fresh `owner.pem` / `$OWNER`, which `pr_keys_drop` deletes at the end.
   - Using H0 makes a long-lived bench key the sole owner of 04 for the arm. After a host death it stays the owner
     until the recovery.
   - I do not block on this, because the owner chose H0 explicitly. The design should record the trade-off (per-run
     key: nothing long-lived becomes owner; H0: one key for all arms and §7.1). The guard text "`H0-IN-RECORD=yes`"
     then reads "the run's owner key in the record".
3. **Wording.** Correct "the update and bulk verbs check no prov state" to "need only `Claimed` or `Member` (owner-op
   gate, `node.go:784-785`) and a loadable record; nothing else", so the table's claim is exact.
4. **App-visible counters.** The claim increments `ClaimedCounter` (`node.go:592`), which `info.counter` exposes. The
   restore returns it to the S0 value. If a phone connects to 04 during an arm (unlikely on the bench, but 04 "must stay
   usable by the phone app"), it would see the counter go up and then back. One line in §1.7 side effects: "no phone
   session to 04 during an arm".

## 3. Owner's provisional answers

| Q | Verdict |
|---|---|
| Q14 | Acceptable. A per-run key is the cleaner option (m2). |
| Q15 | Not as worded: the reason is wrong (M1). Accept "not covered" only with the corrected reason, or cover it through a bench-mesh join. |

## 4. Verdict: **APPROVE-WITH-CHANGES**

0 BLOCKER, 1 MAJOR, 4 MINOR.
- The temporary-ownership design is sound in source. The legacy claim keeps the radio, the restore covers every side
  effect, and secrets stay on the node or in WSL.
- M1 is about the honesty of the coverage claim: decide with the corrected facts.
- m1 is a real defect in the printed recovery block for non-member start states.
