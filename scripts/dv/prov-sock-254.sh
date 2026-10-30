#!/bin/bash
# scripts/dv/prov-sock-254.sh — #254 tier A prov-sock-254 (docs/design/254-h23-harness.md §4.5, §6.2): who may talk to
# the helper's socket. Read-only on the node state (provclient placed under the root-only /tmp/run, removed at the end).
#   uid 471 (provd)                     -> info answers (code 0)
#   uid 65534, gid 65534                -> connect refused by the socket mode (0660 root:provd): CONN-ERR permission denied
#   uid 65534 with gid 471              -> the socket lets it connect, the helper's SO_PEERCRED check closes it:
#                                          CONN-CLOSED + a log line "connection refused: peer uid 65534 (want 471)"
#   an unknown verb (as 471)            -> E_SCHEMA (20)
# The PEERCRED negative control (a helper without the check) is a Go unit test (root), 254-h23 §4.5.
set -u
PR_UNIT=prov-sock-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
trap 'q "rm -rf $PCD"' EXIT
pr_pc_place || { pr_result; exit 1; }
pcs(){ timeout 60 ssh $SSHO root@$NODE "$PCD/provclient node $*" 2>&1 </dev/null | tr -d '\r'; }
o=$(pcs info); echo "$o" | sed 's/^/    /'
grep -q '^RESULT info.state code=0 ' <<< "$o" && ok "uid 471: info answers" || no "uid 471 info: $o"
o=$(pcs sock-as 65534 -- info); echo "    $o"
grep -qi '^CONN-ERR .*permission denied' <<< "$o" && ok "uid 65534: connect refused by the socket mode" || no "uid 65534: [$o] (want CONN-ERR permission denied)"
o=$(pcs sock-as 65534 --gid 471 -- info); echo "    $o"
grep -q '^CONN-CLOSED' <<< "$o" && ok "uid 65534 gid 471: the helper closes the connection" || no "uid 65534 gid 471: [$o] (want CONN-CLOSED)"
l=$(qr "logread | grep 'batman-provhelper.*connection refused: peer uid 65534 (want 471)' | tail -1")
[ -n "$l" ] && ok "helper logged the refusal: ${l##*: connection}" || no "no 'connection refused: peer uid 65534 (want 471)' in logread"
o=$(pcs verb no.such.verb); echo "    $o"
grep -q '^RESULT no.such.verb code=20$' <<< "$o" && ok "unknown verb -> E_SCHEMA (20)" || no "unknown verb: [$o]"
pr_result
