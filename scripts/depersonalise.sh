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

echo "==> removing maintainer SSH keys and host keys"
rm -f /etc/dropbear/authorized_keys /root/.ssh/authorized_keys
rm -f /etc/dropbear/dropbear_*_host_key      # dropbear regenerates per-device
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
# Runs once on the end user's first boot, then OpenWrt deletes it. Gives the
# node a unique hostname from its HaLow MAC so many cards off one image don't
# collide (halow-c6d3, halow-45d7, ...).
mac=$(cat /sys/class/net/wlan0/address 2>/dev/null)
[ -n "$mac" ] || mac=$(cat /sys/class/net/eth0/address 2>/dev/null)
sfx=$(echo "$mac" | sed 's/://g' | cut -c 9-12)
[ -n "$sfx" ] || sfx=$(cut -c1-4 /proc/sys/kernel/random/uuid)
host="halow-$sfx"
uci set system.@system[0].hostname="$host"
uci commit system
echo "$host" > /proc/sys/kernel/hostname 2>/dev/null || true
/etc/init.d/avahi-daemon restart 2>/dev/null || true
exit 0
FIRSTBOOT
chmod +x /etc/uci-defaults/99-halow-identity

sync
echo
echo "DONE. Power this node OFF now (do NOT reboot) and image its card:"
echo "  sudo dd if=/dev/mmcblk0 of=halow-node.img bs=4M status=progress"
echo "  sudo pishrink.sh -z halow-node.img"
