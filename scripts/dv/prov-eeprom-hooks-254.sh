#!/bin/bash
# scripts/dv/prov-eeprom-hooks-254.sh — #254 unit prov-eeprom-hooks-254 (D11; docs/design/254-h4-harness.md §8.2 EE1 /
# EE2; 254-stage1-impl.md:487). Runs in WSL, rootless, in eeprom-sbx-254.sh's sandbox; no node, no root.
#
# A previous owner can plant "persistent vars" in the Pi EEPROM (vcgencmd bootloader_config), which survive a card
# re-flash. The Morse image's readers turn them into an SSH key, the root password and a region lock. Batman's shim
# (PR-F, firmware 5ec36f40) makes every READ answer "absent".
#
#   EE1  a fake vcgencmd answers four planted keys; the first-boot readers run on a fresh copy of the rootfs:
#        authorized_keys does not carry the planted key, the root password hash is unchanged, no region firmware is
#        selected, `READ default_wifi_key` prints nothing
#   EE2  the shim answers rc 1 / no output for every key on READ, and READALL lists every key empty
#   W    the same arms on 1.5.12-wsl.2 (no shim, F-H39): every planted value IS adopted (the arms discriminate);
#        P: that rootfs carries the Morse original, not the shim
#
#   prov-eeprom-hooks-254.sh <prepared dir of the image under test> <prepared dir of 1.5.12-wsl.2>
# (prepare each with eeprom-sbx-254.sh prep; the payload sha256 is pinned there)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SBX=$HERE/eeprom-sbx-254.sh
DUT=${1:?prepared dir of the image under test}; NEG=${2:?prepared dir of 1.5.12-wsl.2}
RC=0
ok() { echo "PASS $*"; }
bad() { echo "FAIL $*"; RC=1; }
KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlantedByAPreviousOwnerXXXXXXXXXXXXXXXXXX planted'
PW='planted-root-pw'
WIFI='plantedwifikey123'

# one arm on a fresh copy; prints "key=value" lines of the observations
observe() {	# $1 prepared dir
	W=$(mktemp -d "$HOME/.batman-dv/sbx/work.XXXXXX") || return 1
	cp -a "$1/rootfs" "$W/rootfs" || return 1
	mkdir -p "$W/rootfs/fakebin"
	cat > "$W/rootfs/fakebin/vcgencmd" <<EOF
#!/bin/sh
[ "\$1" = bootloader_config ] || exit 1
echo "device_password=$PW"
echo "dropbear_authorized_keys=$KEY"
echo "default_wifi_key=$WIFI"
echo "mm_region=EU"
EOF
	chmod 755 "$W/rootfs/fakebin/vcgencmd"
	mkdir -p "$W/rootfs/lib/firmware"
	: > "$W/rootfs/lib/firmware/mm_region_EU_bcf_probe.bin"     # a region-specific file: selected only if a region is read
	"$SBX" run "$W" /bin/busybox sh -c '
		export PATH=/fakebin:/usr/sbin:/usr/bin:/sbin:/bin
		h0=$(grep "^root:" /etc/shadow | cut -d: -f2 | md5sum | cut -c1-8)
		sh /etc/uci-defaults/31_dropbear_persistent_storage >/dev/null 2>&1
		sh /etc/uci-defaults/31_password >/dev/null 2>&1
		sh /etc/boot-defaults/01-region-restriction >/dev/null 2>&1
		h1=$(grep "^root:" /etc/shadow | cut -d: -f2 | md5sum | cut -c1-8)
		echo "pwchanged=$([ "$h0" = "$h1" ] && echo no || echo yes)"
		echo "authkey=$(grep -c planted /etc/dropbear/authorized_keys 2>/dev/null || echo 0)"
		echo "region=$([ -e /lib/firmware/bcf_probe.bin ] && echo selected || echo none)"
		w=$(persistent_vars_storage.sh READ default_wifi_key 2>/dev/null); echo "wifirc=$?"; echo "wifi=${w:-none}"
		for k in device_password default_wifi_key dpp_priv_key mm_region mm_virtual_wire mm_mode dropbear_authorized_keys dropbear_ed25519_host_key dropbear_rsa_host_key; do
			o=$(persistent_vars_storage.sh READ $k 2>/dev/null); echo "read.$k=$?:${o:+out}"
		done
		echo "readall=$(persistent_vars_storage.sh READALL 2>/dev/null | grep -v "=$" | wc -l)"
		echo "shim=$(grep -c "Batman #254 shim" /sbin/persistent_vars_storage.sh)"
	'
	rm -rf "$W"
}

"$SBX" escape "$DUT" >/dev/null || { echo "FAIL prov-eeprom-hooks-254: the sandbox escape negatives do not hold — not running"; exit 1; }

o=$(observe "$DUT"); echo "$o" | sed 's/^/    dut: /'
echo "$o" | grep -q '^shim=1$' && ok "EE: the image under test carries the shim" || bad "EE: no shim in the image under test"
echo "$o" | grep -q '^authkey=0$' && ok "EE1: the planted SSH key is not in authorized_keys" || bad "EE1: planted SSH key adopted"
echo "$o" | grep -q '^pwchanged=no$' && ok "EE1: the root password hash is unchanged" || bad "EE1: root password changed"
echo "$o" | grep -q '^region=none$' && ok "EE1: no region firmware selected" || bad "EE1: region selected from the EEPROM"
echo "$o" | grep -q '^wifi=none$' && ok "EE1: READ default_wifi_key prints nothing" || bad "EE1: default_wifi_key read"
n=$(echo "$o" | grep -c '^read\..*=1:$'); [ "$n" = 9 ] && ok "EE2: READ answers rc 1, no output, for all 9 keys" || bad "EE2: READ rc 1 / no output for only $n of 9 keys"
echo "$o" | grep -q '^readall=0$' && ok "EE2: READALL lists every key empty" || bad "EE2: READALL has a value"

o=$(observe "$NEG"); echo "$o" | sed 's/^/    neg: /'
echo "$o" | grep -q '^shim=0$' && ok "W/P: 1.5.12-wsl.2 has the Morse original (no shim)" || bad "W/P: the negative-control image has the shim (wrong image)"
echo "$o" | grep -q '^authkey=1$' && ok "W: 1.5.12-wsl.2 adopts the planted SSH key (EE1 discriminates)" || bad "W: 1.5.12-wsl.2 did not adopt the key — EE1 proves nothing"
echo "$o" | grep -q '^pwchanged=yes$' && ok "W: 1.5.12-wsl.2 changes the root password" || bad "W: 1.5.12-wsl.2 kept the password — the password arm proves nothing"
echo "$o" | grep -q '^region=selected$' && ok "W: 1.5.12-wsl.2 selects the planted region" || bad "W: 1.5.12-wsl.2 did not select the region — the region arm proves nothing"
echo "$o" | grep -q "^wifi=$WIFI\$" && ok "W: 1.5.12-wsl.2 reads default_wifi_key" || bad "W: 1.5.12-wsl.2 did not read default_wifi_key"
echo "prov-eeprom-hooks-254: $([ $RC = 0 ] && echo PASS || echo FAIL)"
exit $RC
