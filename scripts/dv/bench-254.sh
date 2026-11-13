# shellcheck shell=bash
# scripts/dv/bench-254.sh — the ONE reader of the bench store's membership log (WSL ~/.batman-dv/bench/nodes.txt,
# written only by prov-bench-s0-254.sh: keep -> "node=<n> run=keep-<id> ... ip=<a> mac=<m> ...", restore ->
# "node=<n> restored=<run> ..."). The LAST line of a node says where it is: run=keep-... = on N0 at that address;
# restored=... = it left N0 (back to its snapshot: its old address is not known here).
#   bench_ip <04|02>   prints the address when the node's last line is a keep line; nothing otherwise (no store, no
#                      line, a restored= last line, an unreadable store). Callers decide what "nothing" means.
# Sourced by chain1-254.sh and prov-dv-254.sh (and prov-254.sh once it switches over).
bench_ip(){
	MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu-24.04 -u yello -- cat /home/yello/.batman-dv/bench/nodes.txt 2>/dev/null | tr -d '\r' \
		| awk -v me="node=$1" '$1 == me { last = $0 } END { if (last ~ /^node=[0-9]+ run=keep-/ && match(last, / ip=[0-9.]+ /)) print substr(last, RSTART + 4, RLENGTH - 5) }'
}
