#!/bin/sh
#
# depersonalise.sh - turn a fully-provisioned OpenMANET 1.8.0 node into a redistributable
# "golden" image. Run this ON the golden node, once, immediately before you power it off and
# read its SD card (docs/golden-image.md). It bakes the mesh baseline, strips per-device
# identity and the maintainer's secrets, and installs the first-boot hooks + runtime services
# so every card flashed from the image comes up unique and self-provisioned.
#
#   depersonalise.sh [--mesh-key K] [--ap-key K] [--mesh-id ID] [--channel N] [--country CC] [--bench]
#
# 1.8.0 layout: HaLow = the `morse` wifi-device (radio1 on a Pi 4), LAN = the `ahwlan` bridge
# (eth + bat0 + onboarding APs). Older releases (radio3 / setup-node2.sh) are not supported.
#
# Keys are a management-plane asset (#13): give the deployment's batch key with --mesh-key/--ap-key
# so the cards come up on the air; without them the public placeholder CHANGE-ME-NOW is baked and
# halow-keyguard (#103) keeps the radios DOWN until `halow-setkey` is run over Ethernet.
#
# Addressing is OpenMANET's two-stage scheme (#11 decision): the image carries only a bootstrap
# 10.41.254.x; each card's openmanetd reserves a mesh-unique IP on first boot and reboots once.
# Find nodes by <hostname>.local, never by IP.
#
# --bench keeps the maintainer's authorized_keys and SSH enabled so a test flash stays reachable.
#   It stamps /etc/BENCH-IMAGE; never publish such an image.
#
# After it finishes: power off (do NOT reboot this node) and image the card.
set -e

MESH_KEY='CHANGE-ME-NOW'      # SAE mesh key   (same on every node of a deployment, >= 8 ch)
AP_KEY='CHANGE-ME-NOW'        # onboarding AP PSK
MESH_ID='openmanet1'          # 802.11s mesh id (same on every node)
CHANNEL='40'                  # S1G ch 40 = 922 MHz @ 4 MHz (42 = 2 MHz)
COUNTRY='US'                  # regdomain - installer MUST set their region (#92)
BENCH=0
while [ $# -gt 0 ]; do
	case "$1" in
		--mesh-key) MESH_KEY=$2; shift 2;; --ap-key) AP_KEY=$2; shift 2;; --mesh-id) MESH_ID=$2; shift 2;;
		--channel) CHANNEL=$2; shift 2;; --country) COUNTRY=$2; shift 2;; --bench) BENCH=1; shift;;
		*) echo "unknown arg $1"; exit 2;;
	esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
PROV="$HERE/../deploy/provisioning"
for f in meshpoint-1.8.0.sh halow-keyguard.init halow-setkey uci-defaults/95-batman-storage; do
	[ -f "$PROV/$f" ] || { echo "missing $PROV/$f — stage the repo on the node (scripts/ + deploy/)"; exit 1; }
done
[ -f "$HERE/meshled.1.8.0" ] && [ -f "$HERE/meshled.init" ] || { echo "missing scripts/meshled.1.8.0 or meshled.init"; exit 1; }

echo "==> 1. mesh baseline (Mesh Point, bridge, ${CHANNEL} ${COUNTRY}, mesh_id ${MESH_ID})"
sh "$PROV/meshpoint-1.8.0.sh" -i "$MESH_ID" -k "$MESH_KEY" -c "$CHANNEL" -C "$COUNTRY"
# every card must reserve its own address: re-arm stage 2 and reset the bootstrap
uci set openmanetd.config.dhcpconfigured='0'
uci set network.ahwlan.ipaddr='10.41.254.1'      # first-boot hook randomises this
uci set dhcp.ahwlan.start='100'; uci set dhcp.ahwlan.limit='150'; uci -q delete dhcp.ahwlan.force

echo "==> 2. onboarding APs -> deployment key (placeholder unless --ap-key), low indoor 5 GHz profile"
for s in $(uci show wireless | sed -n "s/^wireless\.\([^.]*\)\.mode='ap'$/\1/p"); do
	uci set "wireless.$s.key=$AP_KEY"
	uci set "wireless.$s.ssid=halow-setup"     # first-boot hook renames to the card's hostname
	echo "    $s -> key $([ "$AP_KEY" = CHANGE-ME-NOW ] && echo PLACEHOLDER || echo set)"
done
# The 5 GHz AP only serves nearby phones (not the mesh): battery-friendly indoor profile;
# deployers run 'apower field' for range.
for r in $(uci show wireless | sed -n "s/^wireless\.\([^.]*\)\.band='5g'$/\1/p"); do
	uci set "wireless.$r.txpower=21"; uci set "wireless.$r.htmode=VHT20"
done

echo "==> 3. comms (PTT) -> enabled, web control source"
# openmanetd voice comms ON by default in web mode: browser/phone PTT over the mesh, no extra
# audio hardware needed (multicast 239.192.41.1). Edit only the enable/controlSource lines
# inside the comms: block of openmanetd's own config.
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

echo "==> 4. root password -> EMPTY (factory style; user MUST set one on first login)"
sed -i 's|^root:[^:]*:|root::|' /etc/shadow

if [ "$BENCH" = 1 ]; then
	echo "==> 5. --bench: keeping authorized_keys + SSH enabled (NOT for release)"
	uci set dropbear.main.enable='1'
	echo "bench image built $(date) — do not publish" > /etc/BENCH-IMAGE
else
	echo "==> 5. removing maintainer authorized_keys"
	rm -f /etc/dropbear/authorized_keys /root/.ssh/authorized_keys /etc/BENCH-IMAGE
fi
# Do NOT delete the SSH host keys here: on a live node being imaged over the network that kills
# dropbear mid-dd. The first-boot hook drops them so each card regenerates its own.
rm -f /etc/uhttpd.crt /etc/uhttpd.key 2>/dev/null || true   # self-signed TLS regenerates

echo "==> 6. hostname -> sentinel (first boot derives a unique one)"
uci set system.@system[0].hostname='halow-node'
uci commit

echo "==> 7. clearing per-device state"
rm -f /tmp/meshled.* /tmp/bat-hosts /root/.ash_history /etc/halow-keyguard.blocked
rm -f /etc/config/network.ula 2>/dev/null || true   # ULA regenerates
logread -c 2>/dev/null || true
# openmanetd's peer/reservation DB must not be inherited by the cards (stale peers, stale IP rows)
/etc/init.d/openmanetd stop 2>/dev/null || true
rm -f /etc/openmanetd/openmanetd.db /etc/openmanetd/openmanetd.db-wal /etc/openmanetd/openmanetd.db-shm

echo "==> 8. installing first-boot hooks"
cp "$PROV/uci-defaults/95-batman-storage" /etc/uci-defaults/95-batman-storage && chmod 0755 /etc/uci-defaults/95-batman-storage
echo "    /etc/uci-defaults/95-batman-storage (#88/#61)"
cat > /etc/uci-defaults/99-halow-identity <<'FIRSTBOOT'
#!/bin/sh
# 99-halow-identity — runs once on the card's first boot, then OpenWrt deletes it.
# Personalises the card so many nodes off one image do not collide.
# 1. unique hostname with OpenMANET's own scheme (e.g. BCM2711-47ee from the MAC label / eth0)
. /lib/functions/morse.sh 2>/dev/null
host=$(morse_generate_default_hostname 2>/dev/null)
if [ -z "$host" ]; then
	mac=$(cat /sys/class/net/eth0/address 2>/dev/null)
	sfx=$(echo "$mac" | sed 's/://g' | cut -c 9-12); [ -n "$sfx" ] || sfx=$(cut -c1-4 /proc/sys/kernel/random/uuid)
	host="halow-$sfx"
fi
uci set system.@system[0].hostname="$host"
echo "$host" > /proc/sys/kernel/hostname 2>/dev/null || true
# 2. onboarding AP SSID = hostname (stock behaviour), so a phone can tell nodes apart
for s in $(uci show wireless | sed -n "s/^wireless\.\([^.]*\)\.mode='ap'$/\1/p"); do
	uci set "wireless.$s.ssid=$host"
done
# 3. addressing: bootstrap only. openmanetd reserves the real IP after boot and reboots once (#11).
b=$(hexdump -n1 -e '1/1 "%u"' /dev/urandom 2>/dev/null || echo 7)
uci set network.ahwlan.ipaddr="10.41.254.$(( b % 253 + 2 ))"
uci set openmanetd.config.dhcpconfigured='0'
uci commit
# 4. unique SSH host keys: drop the master's; dropbear regenerates fresh ones when it starts
rm -f /etc/dropbear/dropbear_*_host_key
exit 0
FIRSTBOOT
chmod +x /etc/uci-defaults/99-halow-identity
echo "    /etc/uci-defaults/99-halow-identity (hostname, AP ssid, bootstrap IP, host keys)"

echo "==> 9. installing runtime services"
cp "$PROV/halow-keyguard.init" /etc/init.d/halow-keyguard && chmod 0755 /etc/init.d/halow-keyguard && /etc/init.d/halow-keyguard enable
cp "$PROV/halow-setkey" /usr/bin/halow-setkey && chmod 0755 /usr/bin/halow-setkey
cp "$HERE/meshled.1.8.0" /usr/bin/meshled && chmod 0755 /usr/bin/meshled
cp "$HERE/meshled.init" /etc/init.d/meshled && chmod 0755 /etc/init.d/meshled && /etc/init.d/meshled enable
echo "    halow-keyguard (S18, #103) · halow-setkey · meshled (1.8.0)"

sync
echo
echo "DONE. Power this node OFF now (do NOT reboot) and image its card — docs/golden-image.md §2."
[ "$BENCH" = 1 ] && echo "BENCH image: maintainer SSH key kept. Do not publish."
[ "$MESH_KEY" = CHANGE-ME-NOW ] && echo "NOTE: mesh key is the placeholder — cards will boot with radios DOWN until halow-setkey."
exit 0
