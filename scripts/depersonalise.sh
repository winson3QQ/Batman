#!/bin/sh
#
# depersonalise.sh - turn a fully-provisioned node into a redistributable
# "golden" image. Run this ON the node, once, immediately before you power it
# off and read its SD card. It strips per-device identity and the maintainer's
# secrets, resets everything to the documented DEFAULTS, and installs a
# first-boot hook so every card flashed from the image comes up unique.
#
# After it finishes: power off (do NOT reboot this node) and image the card.
#
#   WARNING: this empties the root password and rewrites mesh key / AP key to
#   defaults, and removes authorized_keys. Only run it on the copy you publish.
#
set -e

# ---- documented defaults (keep in sync with docs/release-v1.0.0.md) --------
# root password ships EMPTY (OpenMANET factory style) - no baked credentials.
DEF_MESH_ID='halow-mesh'         # 802.11s mesh id (same on every node)
DEF_MESH_KEY='CHANGE-ME-NOW'    # SAE mesh key   (same on every node, >=8 ch)
DEF_AP_SSID='halow-setup'        # 5 GHz onboarding AP
DEF_AP_KEY='CHANGE-ME-NOW'      # 5 GHz AP key
DEF_CHANNEL='42'                 # S1G ch 42 = 923 MHz @ 2 MHz
DEF_COUNTRY='US'                 # regdomain - installer MUST set their region

echo "==> root password -> EMPTY (factory style; user MUST set one on first login)"
sed -i 's|^root:[^:]*:|root::|' /etc/shadow

echo "==> removing maintainer authorized_keys (host keys: see first-boot hook)"
rm -f /etc/dropbear/authorized_keys /root/.ssh/authorized_keys
# NOTE: do NOT delete the SSH host keys here. On a live node being imaged over
# the network that instantly kills dropbear (new connections reset at kex) and
# locks you out mid-dd. The first-boot hook below drops them so each flashed
# card still regenerates its own unique host keys.
# self-signed TLS certs regenerate on first service start if absent
rm -f /etc/uhttpd.crt /etc/uhttpd.key 2>/dev/null || true

echo "==> mesh + radio -> defaults"
uci set wireless.radio3.channel="$DEF_CHANNEL"
uci set wireless.radio3.country="$DEF_COUNTRY"
uci set wireless.default_radio3.mesh_id="$DEF_MESH_ID"
uci set wireless.default_radio3.encryption='sae'
uci set wireless.default_radio3.key="$DEF_MESH_KEY"

echo "==> reset every AP interface (5 GHz onboarding) to defaults"
for s in $(uci show wireless | sed -n "s/^wireless\.\([^.=]*\)\.mode='ap'\$/\1/p"); do
	uci set wireless.$s.ssid="$DEF_AP_SSID"
	uci set wireless.$s.encryption='psk2'
	uci set wireless.$s.key="$DEF_AP_KEY"
	echo "    $s -> ssid '$DEF_AP_SSID'"
done

echo "==> comms (PTT) -> enabled, web control source"
# openmanetd voice comms ON by default in web mode: browser/phone PTT over the
# mesh, no extra audio hardware needed (verified this board initialises comms in
# web mode, 2026-08-13; multicast group 239.192.41.1). Users who add an OpenVLM
# VLM-KW or nanoPTT dongle can switch controlSource later. config.yml is
# openmanetd's own config, not uci -- edit only the enable/controlSource lines
# inside the comms: block.
OMCFG=/etc/openmanetd/config.yml
if [ -f "$OMCFG" ]; then
	awk '
	/^[A-Za-z]/ { sec=$1 }
	{ if (sec=="comms:" && $1=="enable:")        { print "  enable: true"; next }
	  if (sec=="comms:" && $1=="controlSource:") { print "  controlSource: web"; next }
	  print }
	' "$OMCFG" > "$OMCFG.tmp" && mv "$OMCFG.tmp" "$OMCFG"
	echo "    comms enabled (web); PTT at https://<node>:8081"
fi

echo "==> hostname -> sentinel (first boot derives a unique one)"
uci set system.@system[0].hostname='halow-node'
uci commit

echo "==> clearing per-device state"
rm -f /tmp/meshled.* /tmp/bat-hosts /root/.ash_history
rm -f /etc/config/network.ula 2>/dev/null || true   # ULA regenerates
: > /etc/config/dhcp.leases 2>/dev/null || true
logread -c 2>/dev/null || true

echo "==> installing first-boot identity hook"
cat > /etc/uci-defaults/99-halow-identity <<'FIRSTBOOT'
#!/bin/sh
# Runs once on the end user's first boot, then OpenWrt deletes it. Personalises
# the card so many nodes off one image do not collide.
# 1. unique hostname from eth0's MAC (eth0 is up this early in boot; wlan0/SPI
#    is not, so prefer eth0) e.g. halow-47ee
mac=$(cat /sys/class/net/eth0/address 2>/dev/null)
[ -n "$mac" ] || mac=$(cat /sys/class/net/wlan0/address 2>/dev/null)
sfx=$(echo "$mac" | sed 's/://g' | cut -c 9-12)
[ -n "$sfx" ] || sfx=$(cut -c1-4 /proc/sys/kernel/random/uuid)
host="halow-$sfx"
uci set system.@system[0].hostname="$host"
uci commit system
echo "$host" > /proc/sys/kernel/hostname 2>/dev/null || true
/etc/init.d/avahi-daemon restart 2>/dev/null || true
# 2. unique management IP from the SAME MAC, so many cards off one image do not
#    all boot as the 10.41.1.1 factory default. This is deterministic and runs
#    BEFORE the radio is up, so no two nodes ever race for the same address (a
#    property classic DAD can't give). 10.41.<octet5>.<octet6> of the MAC; the
#    hostname suffix (octet5octet6 in hex) and the IP therefore point at the
#    same device. ip-conflict-check (init.d, post-network) warns in the rare
#    case two NICs share the last two MAC octets.
if [ -n "$mac" ]; then
	o5=$((0x$(echo "$mac" | cut -d: -f5)))
	o6=$((0x$(echo "$mac" | cut -d: -f6)))
	[ "$o6" -eq 0 ]   && o6=1     # never .0   (would look like a network addr)
	[ "$o6" -eq 255 ] && o6=254   # never .255 (would look like a broadcast addr)
	[ "$o5" -eq 1 ] && [ "$o6" -eq 1 ] && o6=2   # never the 10.41.1.1 default
	uci set network.ahwlan.ipaddr="10.41.$o5.$o6"
	# spread each node's DHCP client window (start/limit are host offsets into
	# 10.41.0.0/16) so two fresh cards never lease the same client IPs. Interim:
	# full decentralised client addressing = IPv6 SLAAC (roadmap follow-up).
	uci set dhcp.ahwlan.start=$(( o5 * 16 + 16 ))
	uci set dhcp.ahwlan.limit=16
	uci commit network
	uci commit dhcp
fi
# 3. unique SSH host keys: drop the master's now; dropbear regenerates fresh
#    ones when it starts, which is later in boot than this uci-defaults hook.
rm -f /etc/dropbear/dropbear_*_host_key
exit 0
FIRSTBOOT
chmod +x /etc/uci-defaults/99-halow-identity

sync
echo
echo "DONE. Power this node OFF now (do NOT reboot) and image its card:"
echo "  sudo dd if=/dev/mmcblk0 of=halow-node.img bs=4M status=progress"
echo "  sudo pishrink.sh -z halow-node.img"
