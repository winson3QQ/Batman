#!/bin/bash
# scripts/dv/eh15-ethsim-254.sh — #254 H4 probe E-H15 (docs/design/254-h4-harness.md §4.5, §17) on 04, pre-P3 parts:
# ethsim up / teardown through the undo journal, the mesh view (batctl tl), uclient-fetch exit codes, RSS at 120 running,
# 50 conn/s for 60 s with tcpdump on br-ahwlan (SYN seen >= 0.9 x sent), the VLAN double-tag path (seen on br-ahwlan,
# no SYN-ACK / RST), docker0 path (same-path positive :80), uid 471 via start-stop-daemon.
# Not here (P3): named counters, the helper's phy* premise (http.2), 8095 served by provd.
# Changes on 04: netns h4x / h4y, veths h4v0 (br-ahwlan) / h4d0 (docker0) for a few minutes (a locally administered MAC
# shows up in the mesh translation table); ~3000 connection attempts to 04's own br-ahwlan IP; docker0 carrier up while
# h4d0 exists; provd restarted by the release (BLE advertising off a few seconds). Restore: ethsim down + the undo
# journal (host mode in pr_release; the lease deadman otherwise). Git Bash.
PR_UNIT=prov-eh15-254
. "$(dirname "$0")/prov-254.sh"
trap '[ "$PR_BEGUN" = 1 ] && { pe down >/dev/null 2>&1; pr_release; }' EXIT
pe(){ QT=${QT:-200} q "RUN_ID=$RUN sh $PRD/prov-ethsim-254.sh $*"; }
SIMMAC=02:48:34:00:00:01; N=$(echo "$RUN" | cksum | awk '{print $1 % 200 + 20}')

pr_lock
o=$(pr_p9); echo "$o"; grep -q '^FAIL' <<< "$o" && { no "preconditions"; pr_unlock; exit 1; }
o=$(pr_acquire 1500) || { echo "$o"; pr_unlock; exit 1; }; PR_BEGUN=1
BR=$(q "ip -4 -o addr show br-ahwlan | awk '{sub(\"/.*\",\"\",\$4); print \$4; exit}'"); say "br-ahwlan $BR, netns IP 10.41.250.$N"

o=$(pe up "$N" mac=$SIMMAC); say "$o"; grep -q '^UP h4x' <<< "$o" || { no "ethsim up: $o"; exit 1; }
o=$(pl undo-pending); grep -q 'link-del h4v0' <<< "$o" && grep -q 'netns-del h4x' <<< "$o" && ok "h4v0 / h4x registered in the undo journal before use" || no "undo journal: $o"
o=$(q "ls /sys/class/net/br-ahwlan/brif/"); grep -qx h4v0 <<< "$o" && ok "h4v0 is a port of br-ahwlan" || no "brif: $(echo $o)"
o=$(q "ip netns exec h4x ping -c 2 -W 2 $BR >/dev/null && echo PING-OK"); grep -q PING-OK <<< "$o" && ok "netns -> $BR reachable" || no "netns ping $BR"
t=0; while [ $t -lt 12 ]; do o=$(pe state | grep 'tl h4v1'); case "$o" in *": "[1-9]*) break ;; esac; sleep 5; t=$((t + 1)); done
say "$o"; case "$o" in *": "[1-9]*) ok "mesh: the netns MAC is in batctl tl (announced into the mesh)" ;; *) no "mesh: $SIMMAC not in batctl tl after 60 s" ;; esac

# exit codes of uclient-fetch: served (:80), refused (:8095 pre-P3: nothing listens), no answer (an absent host)
o80=$(pe get h4x "http://$BR/"); o95=$(pe get h4x "http://$BR:8095/"); ono=$(pe get h4x "http://10.41.250.$((N + 1)):8095/")
say "rc :80 [$o80] :8095 [$o95] absent host [$ono]"
[ "$o80" != "$o95" ] && [ "$o95" != "GET rc=0" ] && [ -n "$ono" ] && ok "uclient-fetch rcs: :80 $o80, refused $o95, no answer $ono" || no "uclient-fetch rcs do not tell the cases apart"

o=$(pe as471); say "$o"; [ "$o" = "AS471 uid=471" ] && ok "start-stop-daemon -c 471:471 runs as uid 471" || no "as471: $o"

o=$(pe rss h4x 120 "http://10.41.250.$((N + 1)):8095/"); say "$(echo $o)"
k=$(sed -n 's/.*RSS running=\([0-9]*\).*/\1/p' <<< "$o"); [ "${k:-0}" -ge 110 ] && ok "120 uclient-fetch at once: $k running ($(sed -n 's/.*\(per_kB=[0-9-]*\).*/\1/p' <<< "$o"))" || no "rss: only ${k:-0} running"

# 50 conn/s for 60 s to the br-ahwlan IP:8095, tcpdump on br-ahwlan
pe cap-start fl br-ahwlan "10.41.250.$N" >/dev/null
o=$(QT=600 pe flood h4x 50 60 120 "http://$BR:8095/"); say "$(echo $o)"
c=$(pe cap-stop fl); say "$c"
sent=$(sed -n 's/.*launched=\([0-9]*\).*/\1/p' <<< "$o"); syn=$(sed -n 's/.* syn=\([0-9]*\).*/\1/p' <<< "$c"); maxr=$(sed -n 's/.*maxrunning=\([0-9]*\).*/\1/p' <<< "$o")
[ "${sent:-0}" -ge 2700 ] && ok "flood: $sent launched in 60 s (target 3000), max running $maxr <= 120" || no "flood: only ${sent:-0} launched (rate not reached: honest limit)"
[ -n "$syn" ] && [ "$syn" -ge $(( ${sent:-1} * 9 / 10 )) ] && ok "tcpdump on br-ahwlan saw $syn SYN >= 0.9 x $sent" || no "tcpdump saw ${syn:-?} SYN of $sent"

# VLAN double tag (D-1): the frames reach br-ahwlan; 04 answers none of them
o=$(pe vlan "$N"); say "$o"
pe cap-start vl br-ahwlan "10.43.250.$N" >/dev/null
for i in 1 2 3 4 5; do pe get h4x "http://$BR:8095/" >/dev/null; done
c=$(pe cap-stop vl); say "vlan: $c"
syn=$(sed -n 's/.* syn=\([0-9]*\).*/\1/p' <<< "$c"); sa=$(sed -n 's/.*synack=\([0-9]*\).*/\1/p' <<< "$c"); rs=$(sed -n 's/.*rst=\([0-9]*\).*/\1/p' <<< "$c")
[ "${syn:-0}" -ge 5 ] && [ "$sa" = 0 ] && [ "$rs" = 0 ] && ok "vlan: $syn double-tagged SYN on br-ahwlan, no SYN-ACK / RST" || no "vlan: $c"

# docker0 path: netns h4y via docker0 -> 04's br-ahwlan IP (input, zone docker = ACCEPT); same-path positive :80
o=$(pe docker "$N"); say "$o"
o=$(pe get h4y "http://$BR/"); [ "$o" = "$o80" ] && ok "docker0 path to $BR:80: $o (same as the eth path)" || no "docker0 path: $o (eth path $o80)"

# teardown through the undo journal (host mode, as pr_release does), then nothing left
o=$(pe down); say "$(echo $o)"; grep -q 'DOWN clean' <<< "$o" || no "ethsim down: $o"
pr_release; PR_BEGUN=0
o=$(qr 'ls /sys/class/net | grep -E "^(h4|phy9h4)"; ip netns list | grep "^h4"; ls -A /tmp/run/batman-dv/undo/ /tmp/run/batman-dv/ethsim/ 2>/dev/null | grep -v -e "^$" -e ":$"; pidof uclient-fetch tcpdump; cat /sys/class/net/docker0/operstate')
say "after: $(echo $o)"; [ "$(echo $o)" = down ] && ok "nothing of ethsim left; docker0 back to down" || no "left after release: $(echo $o)"
say "fails=$fails invalid=$invalid"; [ "$fails" = 0 ] && echo "E-H15 PASS" || echo "E-H15 FAIL"
