#!/bin/bash
# scripts/test-s5-node-254.sh — offline tests of the #254 S5 daily node checks (scripts/node/fw-boot-254.sh +
# scripts/node/slotlock-lib-254.sh under busybox ash / dash, and the host judges in scripts/dv/s5-254.sh). No node:
# FB_ROOT is a fixture tree; nft, batman-slot are stubs on PATH, provd a dummy process of that name; ssh is a stub for the host-side aggregation.
#   prov-fw-boot-254: good -> PASS; pre-S5 -> INVALID; fw4 / a table missing, a rule loaded twice, an overlay include,
#     a commented-rule-less include -> FAIL; upload tmpfs without noexec / wrong size / not mounted / stacked -> FAIL,
#     provd not running -> recorded, not judged; a verb whose child keeps fd 9 -> FAIL (the negative control of the
#     lock-release check), a verb that never takes the lock -> FAIL, a verb failing -> FAIL, the lock held from
#     outside for 5 tries -> INVALID
#   chk_fw_boot_254 / s5_sum: PASS -> rc 0; INVALID -> SKIP-REASON rc 3; FAIL or no verdict -> rc 1; no node -> rc 1
#   release-key-254 (rk_judge): T + bench stamp -> PASS; T without the stamp / stamp without T / unknown stamp value /
#     bench without .bench / no stamp / not a point / no answer -> FAIL; none, another root -> PASS
# Zero cases = FAIL.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
P=0; F=0
has(){ if grep -qE -- "$3" <<< "$2"; then echo "ok   $1"; P=$((P + 1)); else echo "FAIL $1: lacks /$3/"; printf '%s\n' "$2" | sed 's/^/      /' | head -30; F=$((F + 1)); fi; }
hasnt(){ if grep -qE -- "$3" <<< "$2"; then echo "FAIL $1: has /$3/"; printf '%s\n' "$2" | sed 's/^/      /' | head -30; F=$((F + 1)); else echo "ok   $1"; P=$((P + 1)); fi; }
command -v flock >/dev/null || { echo "FAIL no flock on this host"; echo "S5-NODE 0 passed, 1 failed"; exit 1; }
T=$(mktemp -d); trap 'pkill -f "^sleep 3[0-9]$" 2>/dev/null; pkill -x batman-provd 2>/dev/null; jobs -p | xargs -r kill 2>/dev/null; rm -rf "$T"' EXIT
B=$T/bin; ST=$T/st; FR=$T/root; mkdir -p "$B" "$ST" "$T/run"; chmod 755 "$T/run"
cat > "$T/rundir.sh" <<EOF
RUNDIR=$T/run/batman
batman_rundir(){ mkdir -m 700 "\$RUNDIR" 2>/dev/null; [ -d "\$RUNDIR" ]; }
EOF
export SLK_RD=$T/rundir.sh ST
# ---- stubs
cat > "$B/nft" <<'EOF'
#!/bin/sh
[ "$1 $2" = "list table" ] || exit 1
f="$ST/nft.$3.$4"; [ -f "$f" ] || { echo "Error: No such file or directory" >&2; exit 1; }; cat "$f"
EOF
# provd: a real process of that name (Ubuntu's busybox ash runs its own pidof applet before PATH; the node's busybox has
# no SH_STANDALONE, but a real process works for both)
cp "$(command -v sleep)" "$T/batman-provd"
provd_up(){ pidof batman-provd >/dev/null 2>&1 || { "$T/batman-provd" 300 & }; sleep 0.2; }
provd_down(){ pkill -x batman-provd 2>/dev/null; sleep 0.2; }
cat > "$B/batman-slot" <<'EOF'
#!/bin/sh
. "$SLK_RD"; m=$(cat "$ST/slot" 2>/dev/null)
case "$1" in bootinfo | precheck-node) ;; *) exit 2 ;; esac
[ "$m" = rc18 ] && exit 18
[ "$m" = nolock ] && exit 0
batman_rundir; exec 9>>"$RUNDIR/batman-slot.flock"; flock -n 9 || exit 14
[ "$m" = leak ] && sleep 3 &
[ "$1" = precheck-node ] && exit 12
exit 0
EOF
chmod +x "$B"/*
# ---- the fixture tree
HTTP='add table bridge batman_http
delete table bridge batman_http
table bridge batman_http {
	chain input {
		type filter hook input priority -10; policy accept;
		iifname != "phy*" meta mark set meta mark & 0xfeffffff comment "batman-http: clear"
		iifname "phy*" meta mark set meta mark | 0x01000000 comment "batman-http: mark"
	}
}
add table inet batman_http_in
delete table inet batman_http_in
table inet batman_http_in {
	chain input {
		type filter hook input priority -10; policy accept;
		tcp dport 8095 meta iifname != "br-ahwlan" counter drop comment "batman-http: iif"
		tcp dport 8095 meta mark & 0x01000000 == 0 counter drop comment "batman-http: mark-drop"
	}
}'
INIT='BDIR=/tmp/run/batman-provd-bulk
_bulk_mount() {
	case "$(sed -n s/^BATMAN_BOARD=//p /etc/batman-build 2>/dev/null)" in
	ekh-bcm2711 | ekh-bcm2710) sz=252619530 ;;
	*) return 1 ;;
	esac
	mount -t tmpfs -o nodev,nosuid,noexec,mode=0700,nr_inodes=16,size=$sz,uid=471,gid=471 batman-provd-bulk "$BDIR"
}'
MNT='batman-provd-bulk /tmp/run/batman-provd-bulk tmpfs rw,nosuid,nodev,noexec,relatime,size=246700k,nr_inodes=16,mode=700,uid=471,gid=471 0 0'
good(){
	rm -rf "$FR" "${ST:?}"/* "$T/run/batman"; mkdir -p "$FR/etc/init.d" "$FR/proc/sys/kernel/random" "$FR/usr/sbin" "$FR/rom/usr/share/nftables.d/ruleset-post" "$FR/usr/share/nftables.d/ruleset-post" "$FR/tmp/run/batman-provd-bulk"
	printf 'BATMAN_VERSION=1.5.14-wsl.26+abc.fwdef\nBATMAN_BOARD=ekh-bcm2711\n' > "$FR/etc/batman-build"
	echo "500.10 900.00" > "$FR/proc/uptime"; echo "0123456789ab-x" > "$FR/proc/sys/kernel/random/boot_id"
	printf '#!/bin/sh\nslot_lock() {\n:\n}\n' > "$FR/usr/sbin/batman-slot"
	printf '%s\n' "$HTTP" > "$FR/rom/usr/share/nftables.d/ruleset-post/batman-http.nft"; cp "$FR/rom/usr/share/nftables.d/ruleset-post/batman-http.nft" "$FR/usr/share/nftables.d/ruleset-post/"
	printf '%s\n' "$INIT" > "$FR/etc/init.d/batman-provd"
	printf 'proc /proc proc rw 0 0\n%s\n' "$MNT" > "$FR/proc/mounts"
	echo 'table inet fw4 { }' > "$ST/nft.inet.fw4"
	printf 'table bridge batman_http {\n\tchain input {\n\t\tiifname != "phy*" meta mark set meta mark & 0xfeffffff comment "batman-http: clear"\n\t\tiifname "phy*" meta mark set meta mark | 0x01000000 comment "batman-http: mark"\n\t}\n}\n' > "$ST/nft.bridge.batman_http"
	printf 'table inet batman_http_in {\n\tchain input {\n\t\ttcp dport 8095 iifname != "br-ahwlan" counter packets 0 bytes 0 drop comment "batman-http: iif"\n\t\ttcp dport 8095 meta mark & 0x01000000 == 0x00000000 counter packets 0 bytes 0 drop comment "batman-http: mark-drop"\n\t}\n}\n' > "$ST/nft.inet.batman_http_in"
	provd_up; echo good > "$ST/slot"
}
run(){ cat "$REPO/scripts/node/slotlock-lib-254.sh" "$REPO/scripts/node/fw-boot-254.sh" | PATH="$B:$PATH" FB_ROOT=$FR $SHX 2>&1; echo "rc=$?"; }
SHS="dash"; command -v busybox >/dev/null && SHS="busybox_ash dash"
for s in $SHS; do
	case $s in busybox_ash) SHX="busybox ash -s" ;; *) SHX="dash -s" ;; esac; k=${s%%_*}
	good; o=$(run)
	has "$k good node -> RESULT PASS" "$o" "^RESULT prov-fw-boot-254 PASS"
	has "$k good: FB1 fw4" "$o" "^PASS .*FB1 inet fw4 loaded"
	has "$k good: FB4 each of the 4 rules once" "$(grep -c 'loaded once' <<< "$o")" "^4$"
	has "$k good: FB5 the tmpfs options" "$o" "^PASS .*FB5 /tmp/run/batman-provd-bulk: tmpfs"
	has "$k good: FB6 three verbs, lock free" "$(grep -c '^PASS .*FB6 .*free <= 1 s' <<< "$o")" "^3$"
	hasnt "$k good: no FAIL / INVALID" "$o" "^(FAIL|INVALID)"
	good; printf '#!/bin/sh\nmkdir_lock() { :; }\n' > "$FR/usr/sbin/batman-slot"; o=$(run)
	has "$k pre-S5 image -> INVALID, nothing judged" "$o" "^INVALID .*pre-S5 image 1.5.14-wsl.26"
	has "$k pre-S5 -> RESULT INVALID rc 2" "$(echo $o)" "RESULT prov-fw-boot-254 INVALID rc=2"
	hasnt "$k pre-S5: no PASS / FAIL" "$o" "^(PASS|FAIL)"
	good; rm "$ST/nft.inet.fw4"; o=$(run); has "$k fw4 missing -> FAIL FB1" "$o" "^FAIL .*FB1 inet fw4 missing"
	has "$k fw4 missing -> RESULT FAIL" "$o" "^RESULT prov-fw-boot-254 FAIL"
	good; rm "$ST/nft.bridge.batman_http"; o=$(run); has "$k bridge table missing -> FAIL" "$o" "^FAIL .*table bridge batman_http missing"
	good; sed -i 's/\(comment "batman-http: iif"\)/\1\n\t\ttcp dport 8095 drop comment "batman-http: iif"/' "$ST/nft.inet.batman_http_in"; o=$(run)
	has "$k a rule loaded twice -> FAIL" "$o" '^FAIL .*rule "batman-http: iif" loaded 2 times'
	good; echo "# local edit" >> "$FR/usr/share/nftables.d/ruleset-post/batman-http.nft"; o=$(run); has "$k overlay include -> FAIL" "$o" "^FAIL .*differs from the image"
	good; sed -i 's/ comment "[^"]*"//' "$FR/rom/usr/share/nftables.d/ruleset-post/batman-http.nft"; cp "$FR/rom/usr/share/nftables.d/ruleset-post/batman-http.nft" "$FR/usr/share/nftables.d/ruleset-post/"; o=$(run)
	has "$k include without rule comments -> FAIL (nothing to check by)" "$o" "^FAIL .*no commented rule in table bridge batman_http"
	good; sed -i 's/noexec,//' "$FR/proc/mounts"; o=$(run); has "$k tmpfs without noexec -> FAIL" "$o" "^FAIL .*FB5 .* lack: noexec"
	good; sed -i 's/size=246700k/size=262144k/' "$FR/proc/mounts"; o=$(run); has "$k tmpfs of another size -> FAIL" "$o" "^FAIL .*FB5 .* lack: size=246700k"
	good; printf 'proc /proc proc rw 0 0\n' > "$FR/proc/mounts"; o=$(run); has "$k provd up, tmpfs not mounted -> FAIL" "$o" "^FAIL .*FB5 provd runs but .* is not mounted"
	good; printf '%s\n%s\n' "$MNT" "$MNT" > "$FR/proc/mounts"; o=$(run); has "$k tmpfs stacked -> FAIL" "$o" "^FAIL .*FB5 .* mounted more than once"
	good; provd_down; o=$(run); has "$k provd not running -> recorded" "$o" "^INFO .*FB5 batman-provd not running"
	has "$k provd not running -> the rest still PASS" "$o" "^RESULT prov-fw-boot-254 PASS"
	good; echo leak > "$ST/slot"; o=$(run); has "$k a verb's child keeps fd 9 -> FAIL FB6 (negative control)" "$o" "^FAIL .*FB6 batman-slot bootinfo A .* left the slot flock held by its own process"
	has "$k leak -> RESULT FAIL" "$o" "^RESULT prov-fw-boot-254 FAIL"
	pkill -f "^sleep 3$" 2>/dev/null; sleep 0.2
	good; echo nolock > "$ST/slot"; o=$(run); has "$k a verb that never takes the lock -> FAIL nofile" "$o" "^FAIL .*FB6 .*no lock file afterwards"
	good; echo rc18 > "$ST/slot"; o=$(run); has "$k a verb failing -> FAIL" "$o" "^FAIL .*FB6 batman-slot bootinfo A failed \(rc 18\)"
	# held from outside the whole time: rc 14 x 5 for each verb -> INVALID (a fast sleep for this case only)
	good; mkdir -p "$T/run/batman"; chmod 700 "$T/run/batman"; ( flock -x 7; sleep 30 ) 7>>"$T/run/batman/batman-slot.flock" & hp=$!
	printf '#!/bin/sh\nexec /bin/sleep 0.05\n' > "$B/sleep"; chmod +x "$B/sleep"; o=$(run); rm -f "$B/sleep"; kill $hp 2>/dev/null; wait $hp 2>/dev/null
	has "$k lock held from outside -> INVALID FB6" "$o" "^INVALID .*FB6 batman-slot bootinfo A: the lock stayed busy"
	has "$k held from outside -> RESULT INVALID" "$o" "^RESULT prov-fw-boot-254 INVALID"
done
# ---- host side: chk_fw_boot_254 aggregation (ssh stub) and rk_judge
# shellcheck source=scripts/dv/s5-254.sh
. "$REPO/scripts/dv/s5-254.sh"
cat > "$B/ssh" <<'EOF'
#!/bin/sh
cat >/dev/null; cat "$ST/ssh.out"; exit 0
EOF
chmod +x "$B/ssh"
fb(){ printf '%s\n' "$@" > "$ST/ssh.out"; o=$(PATH="$B:$PATH" chk_fw_boot_254 n1 2>&1; echo "rc=$?"); }
fb "PASS prov-fw-boot-254: x" "RESULT prov-fw-boot-254 PASS"; has "host: PASS -> rc 0" "$o" "rc=0$"
fb "INVALID prov-fw-boot-254: pre-S5" "RESULT prov-fw-boot-254 INVALID"; has "host: INVALID -> SKIP-REASON, rc 3" "$(echo $o)" "SKIP-REASON: prov-fw-boot-254: 1 node.* INVALID.* rc=3$"
fb "FAIL prov-fw-boot-254: x" "RESULT prov-fw-boot-254 FAIL"; has "host: FAIL -> rc 1" "$o" "rc=1$"
fb "PASS prov-fw-boot-254: x"; has "host: no RESULT line -> FAIL rc 1" "$(echo $o)" "FAIL prov-fw-boot-254: n1: no verdict.* rc=1$"
o=$(chk_fw_boot_254 2>&1; echo "rc=$?"); has "host: no node -> FAIL rc 1" "$(echo $o)" "FAIL prov-fw-boot-254: no node checked rc=1"
TP=$(tr -d '\r\n' < "$REPO/tests/keys/T.pub"); R1=04$(printf '%0128d' 7)
rk(){ o=$(rk_judge n1 "$1" "${2:-$TP}"; echo "rc=$?"); }
rk "RK ver=1.5.14-wsl.26+a.fwb.bench bench=T pub=$TP stamp=rom"; has "rk: bench stamp + T -> PASS" "$(echo $o)" "^PASS .*bench build, trusts T.* rc=0$"
rk "RK ver=1.5.14-wsl.26+a.fwb bench=- pub=$TP stamp=rom"; has "rk: T without the bench stamp -> FAIL" "$(echo $o)" "^FAIL .*trusts the TEST root T but its stamp is not a bench build.* rc=1$"
rk "RK ver=1.5.14-wsl.26+a.fwb.bench bench=T pub=- stamp=rom"; has "rk: bench stamp, no T -> FAIL" "$(echo $o)" "^FAIL .*stamp says bench .* does not trust T.* rc=1$"
rk "RK ver=1.5.14-wsl.26+a.fwb.bench bench=T pub=$R1 stamp=rom"; has "rk: bench stamp, another root -> FAIL" "$(echo $o)" "^FAIL .*stamp says bench.* rc=1$"
rk "RK ver=1.5.14-rel.3+a.fwb bench=X pub=$R1 stamp=rom"; has "rk: unknown BATMAN_BENCH_TRUST -> FAIL" "$(echo $o)" "^FAIL .*BATMAN_BENCH_TRUST=\[X\].* rc=1$"
rk "RK ver=1.5.14-wsl.26+a.fwb bench=T pub=$TP stamp=rom"; has "rk: bench without .bench in the version -> FAIL" "$(echo $o)" "^FAIL .*lacks .bench.* rc=1$"
rk "RK ver= bench=- pub=- stamp=none"; has "rk: no stamp -> FAIL" "$(echo $o)" "^FAIL .*no image stamp.* rc=1$"
rk "RK ver=1.5.14-wsl.26+a.fwb bench=- pub=empty stamp=rom"; has "rk: an empty key file -> FAIL" "$(echo $o)" "^FAIL .*not a P-256 point.* rc=1$"
rk ""; has "rk: no answer -> FAIL" "$(echo $o)" "^FAIL .*no answer.* rc=1$"
rk "RK ver=1.5.14-wsl.26+a.fwb bench=- pub=- stamp=rom"; has "rk: no key, no bench -> PASS trusts none" "$(echo $o)" "^PASS .*trusts none.* rc=0$"
rk "RK ver=1.5.14-rel.3+a.fwb bench=- pub=$R1 stamp=rom"; has "rk: another root, no bench -> PASS" "$(echo $o)" "^PASS .*not T.* rc=0$"
rk "RK ver=1.5.14-wsl.26+a.fwb bench=- pub=- stamp=rom" "04zz"; has "rk: a broken harness T.pub -> FAIL, not a PASS" "$(echo $o)" "^FAIL .*T.pub is not one P-256 point.* rc=1$"
# RK_Q against fixture files (the /rom paths rewritten into a temp tree), bench and none
mkdir -p "$T/rk/rom/usr/share/batman" "$T/rk/rom/etc"
printf 'BATMAN_VERSION=1.5.14-wsl.26+a.fwb.bench\nBATMAN_BENCH_TRUST=T\n' > "$T/rk/rom/etc/batman-build"; cp "$REPO/tests/keys/T.pub" "$T/rk/rom/usr/share/batman/release-root.pub"
q=${RK_Q//\/rom\//$T/rk/rom/}
l=$(busybox sh -c "$q" 2>/dev/null || sh -c "$q"); rk "$l"; has "rk: RK_Q on a bench fixture -> PASS" "$(echo $o)" "^PASS .*bench build.* rc=0$"
printf 'BATMAN_VERSION=1.5.14-wsl.26+a.fwb\n' > "$T/rk/rom/etc/batman-build"
l=$(sh -c "$q"); rk "$l"; has "rk: RK_Q on T without the stamp -> FAIL" "$(echo $o)" "^FAIL .*TEST root T.* rc=1$"
rm "$T/rk/rom/usr/share/batman/release-root.pub"; l=$(sh -c "$q"); rk "$l"; has "rk: RK_Q with no key file -> PASS none" "$(echo $o)" "^PASS .*trusts none.* rc=0$"
echo "S5-NODE $P passed, $F failed"
[ "$P" -gt 0 ] && [ "$F" = 0 ]
