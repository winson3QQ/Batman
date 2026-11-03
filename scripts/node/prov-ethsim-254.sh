#!/bin/sh
# scripts/node/prov-ethsim-254.sh — #254 H4 eth-side simulation on 04 (docs/design/254-h4-harness.md §4.5), under the
# prov lease. Staged with prov-lease-254.sh; run as  RUN_ID=<run> sh <dir>/prov-ethsim-254.sh <cmd>
# Every netns / veth is registered in the undo journal (prov-lease undo-add) BEFORE it is created; `down` removes them
# itself too (the undo lines are idempotent). Nothing here survives a reboot (no uci, no p6).
#   up <n> [mac=<mac>]        netns h4x; veth h4v0 (into br-ahwlan) <-> h4v1 (in h4x, 10.41.250.<n>/16, the given MAC);
#                             tcp_syn_retries=1 in h4x
#   docker <n>                netns h4y; veth h4d0 (into docker0) <-> h4d1 (in h4y, 172.17.250.<n>/16, via 172.17.0.1)
#   vlan <n>                  in h4x: q0 (802.1ad id 0 on h4v1) + q0.0 (802.1q id 0 on q0), 10.43.250.<n>/16, static
#                             neighbour for the br-ahwlan IP (the frames reach br-ahwlan double tagged)
#   phy <n>                   veth phy9h4 (into br-ahwlan) <-> h4p1 (in h4x): the UP3 / HT23 second source (P3 arms only)
#   get <ns> <url>            one `wget -T 2` in <ns>; prints "GET rc=<rc>"
#   flood <ns> <rate> <secs> <cap> <url>
#                             <rate> wget -T 2 per second (bursts: the node has no fractional sleep) for <secs>, never
#                             more than <cap> running (checked before every launch); prints launched / skipped / the
#                             largest running count seen / the rc histogram
#   rss <ns> <n> <url>        <n> wget at once at a URL that hangs; VmRSS of each, the sum, MemAvailable before / during
#   cap-start <name> <iface> <host>   tcpdump -i <iface> of tcp port 8095 to/from <host> (vlan-aware on q-arms: "vlan
#                             and vlan and tcp port 8095"); its group registered as kill-pg
#   cap-stop <name>           SIGINT, then "CAP <name> syn=<n> synack=<n> rst=<n> lines=<n>"
#   as471                     `start-stop-daemon -S -c 471:471` runs `id -u` (254-h4 §2): prints "AS471 uid=<uid>"
#   state                     the h4* / phy9h4 links, the netns, docker0, the batctl tl entries of h4v1
#   down                      remove everything above (reverse order), prints each
# busybox ash; no bashisms.
SELF=$(readlink -f "$0"); DIR=$(dirname "$SELF")
. "$DIR/ble-lib-254.sh"
RUN_ID=${RUN_ID:-}
ED=/tmp/run/batman-dv/ethsim; ER=$ED/$RUN_ID
BRIP=$(ip -4 -o addr show br-ahwlan 2>/dev/null | awk '{sub("/.*", "", $4); print $4; exit}')
LEASE_SH=$DIR/prov-lease-254.sh

ureg() { o=$(RUN_ID=$RUN_ID sh "$LEASE_SH" undo-add "$@") && echo "$o" | grep -q '^UNDO-ADDED' || die "undo-add $*: $o"; }
nint() { isint "$1" && [ "$1" -ge 1 ] && [ "$1" -le 250 ] || die "<n> must be 1..250"; }
rdir() { for d in "$ED" "$ER"; do [ -e "$d" ] || mkdir -m 700 "$d" || die "cannot create $d"; dir_ok "$d" drwx------ || die "$d is not a root 0700 directory"; done; }
ns_has() { ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }
inns() { ns=$1; shift; case "$ns" in h4x|h4y) ;; *) die "netns must be h4x or h4y" ;; esac; ns_has "$ns" || die "no netns $ns"; ip netns exec "$ns" "$@"; }
urlok() { case "$1" in http://*) case "$1" in *[!A-Za-z0-9.:/_-]*) die "bad url" ;; esac ;; *) die "url must be http://" ;; esac; }

c=${1:-}; [ $# -gt 0 ] && shift
[ -n "$RUN_ID" ] || die "RUN_ID unset"; case "$RUN_ID" in *[!A-Za-z0-9_-]*) die "bad RUN_ID" ;; esac
case "$c" in
up)
	nint "${1:-}"; n=$1; mac=""
	case "${2:-}" in "") ;; mac=*) mac=${2#mac=}; case "$mac" in [0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) ;; *) die "bad mac" ;; esac ;; *) die "usage: up <n> [mac=<mac>]" ;; esac
	[ -n "$BRIP" ] || die "br-ahwlan has no IPv4 address"
	ns_has h4x && die "netns h4x exists already"; [ -e /sys/class/net/h4v0 ] && die "h4v0 exists already"
	rdir; ureg link-del h4v0; ureg netns-del h4x
	ip netns add h4x || die "ip netns add h4x"
	ip link add h4v0 type veth peer name h4v1 || die "ip link add h4v0"
	ip link set h4v1 netns h4x || die "move h4v1"
	[ -n "$mac" ] && { ip netns exec h4x ip link set dev h4v1 address "$mac" || die "set mac"; }
	ip link set h4v0 master br-ahwlan && ip link set h4v0 up || die "h4v0 into br-ahwlan"
	ip netns exec h4x sh -c "ip link set lo up && ip link set h4v1 up && ip addr add 10.41.250.$n/16 dev h4v1 && echo 1 > /proc/sys/net/ipv4/tcp_syn_retries" || die "h4x addressing"
	echo "UP h4x 10.41.250.$n mac=$(ip netns exec h4x cat /sys/class/net/h4v1/address) target=$BRIP"
	;;
docker)
	nint "${1:-}"; n=$1
	[ -e /sys/class/net/docker0 ] || die "no docker0"
	ns_has h4y && die "netns h4y exists already"
	rdir; ureg link-del h4d0; ureg netns-del h4y
	ip netns add h4y && ip link add h4d0 type veth peer name h4d1 && ip link set h4d1 netns h4y \
		&& ip link set h4d0 master docker0 && ip link set h4d0 up || die "h4d0 into docker0"
	ip netns exec h4y sh -c "ip link set lo up && ip link set h4d1 up && ip addr add 172.17.250.$n/16 dev h4d1 && ip route add default via 172.17.0.1 && echo 1 > /proc/sys/net/ipv4/tcp_syn_retries" || die "h4y addressing"
	echo "DOCKER h4y 172.17.250.$n via 172.17.0.1 target=$BRIP docker0=$(cat /sys/class/net/docker0/operstate)"
	;;
vlan)
	nint "${1:-}"; n=$1; ns_has h4x || die "up first"
	brmac=$(cat /sys/class/net/br-ahwlan/address)
	ip netns exec h4x sh -c "ip link add link h4v1 name q0 type vlan proto 802.1ad id 0 && ip link add link q0 name q0.0 type vlan id 0 \
		&& ip link set q0 up && ip link set q0.0 up && ip addr add 10.43.250.$n/16 dev q0.0 \
		&& ip route add $BRIP/32 dev q0.0 && ip neigh replace $BRIP lladdr $brmac dev q0.0 nud permanent" || die "q0 / q0.0"
	echo "VLAN q0 (802.1ad 0) / q0.0 (802.1q 0) 10.43.250.$n -> $BRIP lladdr $brmac"
	;;
phy)
	nint "${1:-}"; ns_has h4x || die "up first"; [ -e /sys/class/net/phy9h4 ] && die "phy9h4 exists already"
	ureg link-del phy9h4
	ip link add phy9h4 type veth peer name h4p1 && ip link set h4p1 netns h4x && ip link set phy9h4 master br-ahwlan \
		&& ip link set phy9h4 up && ip netns exec h4x ip link set h4p1 up || die "phy9h4"
	echo "PHY phy9h4 in br-ahwlan (peer h4p1 in h4x)"
	;;
get)
	[ $# = 2 ] || die "usage: get <ns> <url>"; urlok "$2"
	inns "$1" wget -q -T 2 -O /dev/null "$2" >/dev/null 2>&1; echo "GET rc=$?"
	;;
flood)
	[ $# = 5 ] || die "usage: flood <ns> <rate> <secs> <cap> <url>"
	for v in "$2" "$3" "$4"; do isint "$v" && [ "$v" -ge 1 ] || die "rate / secs / cap must be integers >= 1"; done
	[ "$2" -le 200 ] && [ "$4" -le 400 ] || die "rate <= 200, cap <= 400"; urlok "$5"
	rdir; rc=$ER/flood.rc; : > "$rc"
	# the loop runs inside the netns (one ip netns exec); each wget in a subshell that appends its rc (O_APPEND)
	inns "$1" sh -c '
		rate=$1 secs=$2 cap=$3 url=$4 rc=$5; launched=0 skipped=0 maxc=0 s=0 t0=$(date +%s)
		while [ $s -lt $secs ]; do
			# once a second (254-h4 §4.5 "每秒斷言"): the running count, then at most cap - running launches
			cur=$(pidof uclient-fetch | wc -w); [ $cur -gt $maxc ] && maxc=$cur
			n=$((cap - cur)); [ $n -gt $rate ] && n=$rate; [ $n -lt 0 ] && n=0; skipped=$((skipped + rate - n))
			i=0; while [ $i -lt $n ]; do
				( wget -q -T 2 -O /dev/null "$url" >/dev/null 2>&1; echo $? >> "$rc" ) 9>&- &
				i=$((i + 1))
			done; launched=$((launched + n))
			sleep 1; s=$((s + 1))
		done
		t1=$(date +%s); wait
		echo "FLOOD launched=$launched skipped=$skipped maxrunning=$maxc cap=$cap secs=$secs rate=$rate wall=$((t1 - t0))"' sh "$2" "$3" "$4" "$5" "$rc"
	echo "FLOOD rc: $(sort "$rc" | uniq -c | awk '{printf "%s=%s ", $2, $1}')done=$(wc -l < "$rc")"
	;;
rss)
	[ $# = 3 ] || die "usage: rss <ns> <n> <url>"; isint "$2" && [ "$2" -le 400 ] || die "n <= 400"; urlok "$3"
	ma0=$(awk '/^MemAvailable/{print $2}' /proc/meminfo)
	# the target must hang (not fail fast): a static neighbour to a MAC nobody has, inside the netns (gone with it)
	h=${3#http://}; h=${h%%[:/]*}; case "$h" in *[!0-9.]*) die "rss: the url host must be an IPv4 address" ;; esac
	dv=h4v1; [ "$1" = h4y ] && dv=h4d1
	ip netns exec "$1" ip neigh replace "$h" lladdr 02:48:34:00:00:fe dev "$dv" nud permanent || die "rss: static neighbour"
	inns "$1" sh -c 'i=0; while [ $i -lt $1 ]; do wget -q -T 2 -O /dev/null "$2" >/dev/null 2>&1 & i=$((i + 1)); done; sleep 1
		t=0; k=0; for p in $(pidof uclient-fetch); do r=$(awk "/^VmRSS/{print \$2}" /proc/$p/status 2>/dev/null); [ -n "$r" ] && { t=$((t + r)); k=$((k + 1)); }; done
		echo "RSS running=$k sum_kB=$t per_kB=$([ $k -gt 0 ] && echo $((t / k)) || echo -) memavail_during_kB=$(awk "/^MemAvailable/{print \$2}" /proc/meminfo)"
		wait' sh "$2" "$3"
	echo "RSS memavail_before_kB=$ma0 after_kB=$(awk '/^MemAvailable/{print $2}' /proc/meminfo)"
	;;
cap-start)
	[ $# = 3 ] || die "usage: cap-start <name> <iface> <host>"
	case "$1" in ""|*[!a-z0-9]*) die "bad name" ;; esac
	[ -e "/sys/class/net/$2" ] || die "no iface $2"; case "$3" in *[!0-9.]*) die "bad host" ;; esac
	rdir; f=$ER/cap.$1
	case "$2" in br-ahwlan) flt="(tcp port 8095 and host $3) or (vlan and vlan and tcp port 8095)" ;; *) flt="tcp port 8095 and host $3" ;; esac
	( umask 077; : > "$f" )
	setsid sh -c 'exec tcpdump -i "$1" -nn -l -U "$2" > "$3" 2>/dev/null' h4cap"$1" "$2" "$flt" "$f" </dev/null >/dev/null 2>&1 9>&- &
	p=$!; sleep 1; pg=$(cut -d' ' -f5 "/proc/$p/stat" 2>/dev/null); isint "$pg" || die "tcpdump did not start"
	echo "$pg" > "$ER/cap.$1.pg"; ureg kill-pg "$pg" tcpdump; sleep 1
	echo "CAP-START $1 $2 pg=$pg"
	;;
cap-stop)
	[ $# = 1 ] && [ -f "$ER/cap.$1.pg" ] || die "no capture $1"
	pg=$(cat "$ER/cap.$1.pg"); kill -INT "-$pg" 2>/dev/null; sleep 2; pg_kill "$pg" >/dev/null; rm -f "$ER/cap.$1.pg"
	f=$ER/cap.$1
	echo "CAP $1 syn=$(grep -c 'Flags \[S\]' "$f") synack=$(grep -c 'Flags \[S\.\]' "$f") rst=$(grep -c 'Flags \[R' "$f") lines=$(wc -l < "$f")"
	;;
as471)
	o=$(start-stop-daemon -S -c 471:471 -n h4id471 -a /bin/sh -- -c 'id -u' 2>&1); echo "AS471 uid=$(echo $o)"
	;;
state)
	echo "STATE links: $(ls /sys/class/net | grep -E '^(h4|phy9h4)' | tr '\n' ' ')"
	echo "STATE netns: $(ip netns list 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
	echo "STATE docker0: $(cat /sys/class/net/docker0/operstate 2>/dev/null) brif: $(ls /sys/class/net/br-ahwlan/brif | tr '\n' ' ')"
	m=$(ip netns exec h4x cat /sys/class/net/h4v1/address 2>/dev/null)
	[ -n "$m" ] && echo "STATE tl h4v1 $m: $(batctl tl 2>/dev/null | grep -ci "$m")"
	;;
down)
	for d in phy9h4 h4d0 h4v0; do [ -e "/sys/class/net/$d" ] && { ip link del "$d" && echo "DOWN link $d" || echo "FAIL ip link del $d"; }; done
	for ns in h4y h4x; do ns_has "$ns" && { ip netns del "$ns" && echo "DOWN netns $ns" || echo "FAIL ip netns del $ns"; }; done
	for f in "$ER"/cap.*.pg; do [ -f "$f" ] && { pg_kill "$(cat "$f")"; rm -f "$f"; echo "DOWN capture $f"; }; done
	[ -d "$ER" ] && { echo "DOWN rm $ER: $(ls "$ER" | tr '\n' ' ')"; rm -rf "$ER"; }
	left=$(ls /sys/class/net | grep -E '^(h4|phy9h4)'; ip netns list 2>/dev/null | awk '{print $1}' | grep '^h4')
	[ -z "$left" ] && echo "DOWN clean" || echo "FAIL left: $(echo $left)"
	;;
*) echo "usage: RUN_ID=<run> prov-ethsim-254.sh up|docker|vlan|phy|get|flood|rss|cap-start|cap-stop|as471|state|down ..."; exit 2 ;;
esac
