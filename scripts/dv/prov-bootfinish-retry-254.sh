#!/bin/bash
# scripts/dv/prov-bootfinish-retry-254.sh — #254 L111 unit prov-bootfinish-retry-254 (docs/design/254-v16-group1.md §2):
# an unfinished wireless change whose start-up Finish fails with a failure a retry can cure is finished by the helper's
# own bounded retry, without any verb. The case is the one review v2 B-M1 named: a committed network/leave whose forget
# failed — the node keeps the network key on the air until something finishes it.
#   member (random test mesh) -> a halow-setkey wrapper bound over /usr/bin/halow-setkey that fails the first TWO
#   --forget-mesh calls with rc 3 ("not verified on the air", FAULT INJECTED, stated: a slow boot's rc 2/3 has never
#   been seen in a log, design §2) -> network/leave -> EApply 21 (committed, forget failed: .txn kept) -> helper
#   restart (its start-up Finish = the boot path, main.go:696) -> that forget fails too (2nd injection) ->
#   PASS iff a `boot retry` Finish line follows and .txn is gone within 180 s of the failure, the radio forgotten.
# On an image without the retry (wsl.34 and older) the judgement FAILS: .txn stays (the reproduction / negative control).
# Afterwards the wrapper is unbound and the helper restarted (its Finish ends the change) before the restore.
# No killpoint, no test helper, no sysrq. Type: — / A / F. Side effects: 04 off the mesh ~20 min, 2 reboots (after
# the join, the restore), restored from the snapshot; B and 02 untouched.
set -u
PR_UNIT=prov-bootfinish-retry-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
TXN='[ -e /etc/batman-prov/.txn ] && echo present || echo gone'
LINES="logread | grep 'batman-provhelper' | grep -E 'boot finish|finish \\(|finished \\(|network.leave|boot rc=' | tail -14"
pr_begin 2400 || { pr_result; exit 1; }
pr_member || { pr_abort "member"; pr_result; exit 1; }
W=/tmp/run/batman-dv/wbox/$RUN
pw prep >/dev/null
# the wrapper: the first two --forget-mesh calls exit 3 (logged); every other call is the real setkey
q "cp -p /usr/bin/halow-setkey $W/setkey.real && chmod 700 $W/setkey.real && rm -f $W/inj.n && printf '#!/bin/sh\ncase \" \$* \" in *\" --forget-mesh \"*) n=\$(cat $W/inj.n 2>/dev/null || echo 0); if [ \"\$n\" -lt 2 ]; then echo \$((n + 1)) > $W/inj.n; logger -t batman-dv-inj \"forget rc 3 injected (\$((n + 1)) of 2) at uptime \$(cut -d. -f1 /proc/uptime)\"; echo \"not verified on the air (injected)\"; exit 3; fi ;; esac\nexec $W/setkey.real \"\$@\"\n' > $W/setkey.inj && chmod 755 $W/setkey.inj"
h=$(qr "sha256sum < $W/setkey.inj | cut -c1-64"); b=$(pw bind setkey.inj "$h" /usr/bin/halow-setkey); say "$b"
grep -q '^BOUND /usr/bin/halow-setkey' <<< "$b" || { pr_abort "bind of the injecting setkey"; pr_result; exit 1; }
r=$(pr_pc owner.pem PROVCLIENT_TIMEOUT_S=180 -- leave); echo "    $r"
if ! grep -q "RESULT network.leave code=21" <<< "$r"; then
	inv "precondition: network/leave did not end in EApply 21 (committed, forget failed): $r"
else
	ok "precondition: network/leave committed, its forget failed (injected 1 of 2): .txn $(qr "$TXN")"
	t0=$(qr 'cut -d. -f1 /proc/uptime')
	q '/etc/init.d/batman-provhelper restart'
	tf=""; i=0
	until [ $i -ge 60 ]; do
		tf=$(qr "logread | grep 'batman-provhelper' | grep 'boot finish:' | tail -1 | grep -q . && cut -d. -f1 /proc/uptime")
		[ -n "$tf" ] && [ "$tf" -gt "$t0" ] && break; tf=""; sleep 5; i=$((i + 1))
	done
	inj=$(qr "logread | grep -c 'batman-dv-inj.*forget rc 3 injected'")
	if [ -z "$tf" ]; then
		inv "no 'boot finish:' failure line within 300 s of the helper restart (injections: ${inj:-0})"
	elif [ "${inj:-0}" -lt 2 ]; then
		inv "a 'boot finish:' failure without the 2nd injection (injections: ${inj:-0}) — not the injected case"
	else
		ok "fault injected: the start-up Finish's forget got rc 3 (2 of 2); failure line at uptime ~$tf"
		st=""; j=0; while [ $j -lt 60 ]; do st=$(qr "$TXN"); [ "$st" = gone ] && break; sleep 5; j=$((j + 1)); done
		el=$(( $(qr 'cut -d. -f1 /proc/uptime') - tf ))
		l=$(qr "$LINES"); echo "$l" | sed 's/^/    /'
		if [ "$st" = gone ] && grep -qE 'finished \(boot retry [0-9]+\)' <<< "$l" && [ $el -le 180 ]; then
			ok "L111: the helper's own retry finished the leave ${el}s after the failed Finish; .txn gone"
		else
			no "L111: .txn $st ${el}s after the failed start-up Finish; retry lines: $(grep -cE 'boot retry' <<< "$l") — no bounded retry"
		fi
	fi
fi
# clean up: real setkey back, the helper restarted -> its Finish ends the leave before the restore
u=$(pw unbind-all); say "$u"
q '/etc/init.d/batman-provhelper restart'
i=0; until [ "$(qr "$TXN")" = gone ] || [ $i -ge 60 ]; do sleep 5; i=$((i + 1)); done
say "after the unbind: .txn $(qr "$TXN")"
pk_proof && ok "the lab key still logs in (publickey)" || no "the lab key does not log in after the run"
pr_end
pr_result
