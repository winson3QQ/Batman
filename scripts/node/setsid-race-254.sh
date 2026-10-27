#!/bin/sh
# scripts/node/setsid-race-254.sh stage|count <variant>|load <secs>|clean — node side of scripts/dv/setsid-race-254.sh
# (#254 claim-lock fix §5.5 / §11.7). busybox ash, root, files only under /tmp/run/batman-dv/race (tmpfs).
# stage: builds one parent script per variant from THIS image's addr_defer_release() (the lines `trap '' HUP`, the
# detached `env -i … setsid /etc/init.d/openmanetd start … &` and `trap - HUP`, whichever exist), the openmanetd start
# replaced by a marker child (sleep 1, then survived.<variant>.<i>):
#   image        the image's construct as is
#   image-delay  the image's construct, a ~ms busy loop (2000 ash steps) between the fork and setsid()   [the test]
#   old-delay    the same without the trap lines (the 1.5.13 construct) + the loop                       [neg. control]
#   nodetach     no trap, no setsid                                                                     [control]
# Prints "STAGED hup=<n of trap lines in the image>". Parent = `sh parent.<variant>.sh <i>`, run under `ssh -tt`.
# SR_ROOT / SR_BS: local tests only (never set on a node).
W=${SR_ROOT:-/tmp/run/batman-dv}/race; BS=${SR_BS:-/usr/sbin/batman-slot}
case "${1:-}" in
stage)
	rm -rf "$W"; mkdir -p "${W%/race}" && mkdir -m 0700 "$W" || exit 1
	printf '#!/bin/sh\nsleep 1\necho ok > %s/survived.$1\n' "$W" > "$W/mark.sh"
	awk '/^addr_defer_release\(\) \{/,/^\}/' "$BS" | grep -E "trap '' HUP|setsid /etc/init.d/openmanetd start|trap - HUP" | sed 's/^[[:space:]]*//' > "$W/rel"
	grep -q 'setsid /etc/init.d/openmanetd start' "$W/rel" || { echo "FAIL no detached openmanetd start in addr_defer_release of $BS"; exit 1; }
	# replacements, read by awk from files (no quoting through sed)
	printf '%s' "setsid $W/mark.sh \"\$V.\$I\"" > "$W/t.plain"
	printf '%s' "sh -c 'i=0; while [ \$i -lt 2000 ]; do i=\$((i+1)); done; exec setsid $W/mark.sh \"\$0\"' \"\$V.\$I\"" > "$W/t.delay"
	printf '%s' "$W/mark.sh \"\$V.\$I\"" > "$W/t.nodetach"
	for v in image image-delay old-delay nodetach; do
		case $v in image) t=t.plain; k=keep ;; image-delay) t=t.delay; k=keep ;; old-delay) t=t.delay; k=drop ;; *) t=t.nodetach; k=drop ;; esac
		{ printf '#!/bin/sh\nV=%s; I=$1\n' "$v"
		  printf "trap 'rm -f %s/t1 %s/t2' EXIT\n" "$W" "$W"   # like the product's EXIT trap (it runs two rm; this one exits sooner)
		  awk -v tf="$W/$t" -v k="$k" 'BEGIN { getline r < tf } k == "drop" && /trap/ { next }
			{ s = "setsid /etc/init.d/openmanetd start"; p = index($0, s); if (p) $0 = substr($0, 1, p - 1) r substr($0, p + length(s)); print }' "$W/rel"
		  echo 'exit 0'; } > "$W/parent.$v.sh"
		sh -n "$W/parent.$v.sh" || { echo "FAIL parent.$v.sh does not parse"; exit 1; }
	done
	chmod 700 "$W"/*.sh
	echo "STAGED hup=$(grep -c "trap '' HUP" "$W/rel")"
	;;
count) k=0; for x in "$W/survived.$2".*; do [ -e "$x" ] && k=$((k + 1)); done; echo "$k" ;;
load)	# 4 CPU busy loops that end by themselves (uptime deadline) even if the host dies
	e=$(( $(cut -d. -f1 /proc/uptime) + $2 ))
	for _ in 1 2 3 4; do sh -c 'while [ $(cut -d. -f1 /proc/uptime) -lt $0 ]; do :; done' "$e" </dev/null >/dev/null 2>&1 & echo $! >> "$W/busy.pids"; done
	echo "LOAD until uptime $e $(cat /proc/loadavg)" ;;
clean)
	if [ -f "$W/busy.pids" ]; then
		# shellcheck disable=SC2046  # one pid per word
		kill $(cat "$W/busy.pids") 2>/dev/null; sleep 1
		n=0; for p in $(cat "$W/busy.pids"); do kill -0 "$p" 2>/dev/null && n=$((n + 1)); done; echo "busy_left=$n"
	fi
	rm -rf "$W"; [ ! -e "$W" ] && echo CLEANED ;;
*) echo "usage: $0 stage|count <variant>|load <secs>|clean"; exit 2 ;;
esac
