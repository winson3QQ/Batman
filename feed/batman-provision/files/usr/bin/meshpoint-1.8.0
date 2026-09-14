#!/bin/sh
# meshpoint-1.8.0.sh — configure a stock OpenMANET 1.8.0 node as an 802.11s **Mesh Point (bridge)**
# without the LuCI wizard. Reproduces what the wizard writes (read from the image's
# luci-static tools/morse/{wizard,uci}.js + view/morse/meshwizard.js, 2026-09-11), so the golden
# image carries the post-wizard mesh baseline and every flashed card comes up as a mesh member.
#
# Addressing is OpenMANET's two-stage scheme (openmanetd docs/setup-wizard.md, decision #11 2026-09-11):
# this script only writes a throwaway BOOTSTRAP address 10.41.254.<random> and arms the reservation
# worker (`openmanetd.config.dhcpconfigured=0`). After boot openmanetd gossips over alfred, claims a
# mesh-unique static IP + a 16-lease DHCP window, sets dhcpconfigured=1 and REBOOTS once (~2 min
# after bat0 is up; boot-reasons.log names it). Never hardcode a node's IP — use <hostname>.local.
#
# Deliberate deviations from the wizard (both are bugs/gaps in it):
#   * mesh11sd: the wizard writes `nolearn=1` (wrong key, silently ignored) — the daemon reads
#     `mesh_nolearn`. Without it batman-over-802.11s loses all unicast (docs/upgrade-1.8.0.md bug #2).
#   * bat0.multicast_mode is left at 0: openmanetd reconciles it to 0 on every boot anyway
#     (batman.multicastForceflood=true), so writing the wizard's 1 only creates churn.
#
# Usage: meshpoint-1.8.0.sh [-i MESH_ID] [-k KEY] [-c CHANNEL] [-C COUNTRY] [-a BOOTSTRAP_IP] [--apply]
#   defaults: mesh_id openmanet1, key CHANGE-ME-NOW (placeholder; the first-boot guard #103 refuses
#   to bring the radios up while it is unchanged), channel 40 (= 4 MHz, US op_class 70; 42 = 2 MHz),
#   country US, bootstrap 10.41.254.<random>. Without --apply it only commits; --apply also reloads
#   services (and openmanetd will then reserve + reboot).
# Idempotent: re-running with the same values changes nothing; the reservation worker is re-armed
# only when the ahwlan interface is created by this run.

MESH_ID=openmanet1
KEY=CHANGE-ME-NOW
CHANNEL=40
COUNTRY=US
AHWLAN_IP="10.41.254.$(( $(hexdump -n1 -e '1/1 "%u"' /dev/urandom 2>/dev/null || echo 7) % 253 + 2 ))"
APPLY=0
while [ $# -gt 0 ]; do
	case "$1" in
		-i) MESH_ID=$2; shift 2;; -k) KEY=$2; shift 2;; -c) CHANNEL=$2; shift 2;;
		-C) COUNTRY=$2; shift 2;; -a) AHWLAN_IP=$2; shift 2;; --apply) APPLY=1; shift;;
		*) echo "unknown arg $1"; exit 2;;
	esac
done

RADIO=$(uci show wireless | sed -n "s/^wireless\.\([^.]*\)\.type='morse'$/\1/p" | head -1)
[ -n "$RADIO" ] || { echo "no morse radio in /etc/config/wireless"; exit 1; }
IFACE="default_$RADIO"
ETH=""; for d in /sys/class/net/eth[0-9]*; do [ -e "$d" ] && { ETH=$(basename "$d"); break; }; done
lg(){ logger -t meshpoint "$*"; echo "meshpoint: $*"; }

# --- wireless: HaLow mesh point ------------------------------------------------------------
uci -q batch <<EOF
set wireless.$RADIO.channel='$CHANNEL'
set wireless.$RADIO.country='$COUNTRY'
set wireless.$RADIO.enable_ps='0'
set wireless.$RADIO.enable_dynamic_ps_offload='0'
set wireless.$RADIO.enable_twt='0'
delete wireless.$RADIO.disabled
set wireless.$IFACE=wifi-iface
set wireless.$IFACE.device='$RADIO'
set wireless.$IFACE.mode='mesh'
set wireless.$IFACE.mesh_id='$MESH_ID'
set wireless.$IFACE.encryption='sae'
set wireless.$IFACE.key='$KEY'
set wireless.$IFACE.beacon_int='1000'
set wireless.$IFACE.wds='1'
set wireless.$IFACE.network='batmesh0'
delete wireless.$IFACE.disabled
EOF
# every non-HaLow AP joins the HaLow bridge (wizard "bridge" traffic mode)
for s in $(uci show wireless | sed -n "s/^wireless\.\([^.]*\)\.mode='ap'$/\1/p"); do
	[ "$s" = "$IFACE" ] && continue
	uci -q set "wireless.$s.network=ahwlan"
done

# --- network: ahwlan bridge (eth + bat0 + APs), batman-adv ---------------------------------
NEW_AHWLAN=0; uci -q get network.ahwlan >/dev/null || NEW_AHWLAN=1
uci -q batch <<EOF
set network.ahwlan=interface
set network.ahwlan.proto='static'
set network.ahwlan.device='br-ahwlan'
set network.ahwlan.ipaddr='$AHWLAN_IP'
set network.ahwlan.netmask='255.255.0.0'
set network.ahwlan.ip6assign='64'
set network.ahwlan.ip6ifaceid='eui64'
set network.ahwlan.dns='1.1.1.1'
set network.br_ahwlan=device
set network.br_ahwlan.name='br-ahwlan'
set network.br_ahwlan.type='bridge'
set network.bat0=interface
set network.bat0.proto='batadv'
set network.bat0.routing_algo='BATMAN_V'
set network.bat0.bridge_loop_avoidance='1'
set network.bat0.hop_penalty='30'
set network.bat0.bonding='1'
set network.bat0.aggregated_ogms='1'
set network.bat0.ap_isolation='0'
set network.bat0.fragmentation='1'
set network.bat0.orig_interval='1000'
set network.bat0.distributed_arp_table='1'
set network.bat0.multicast_mode='0'
set network.bat0.network_coding='1'
set network.bat0.isolation_mark='0x00000000/0x00000000'
set network.bat0.gw_mode='client'
set network.batmesh0=interface
set network.batmesh0.proto='batadv_hardif'
set network.batmesh0.master='bat0'
set network.batmesh1=interface
set network.batmesh1.proto='batadv_hardif'
set network.batmesh1.master='bat0'
set network.lan.dns='1.1.1.1'
EOF
uci -q get network.ahwlan.ip6class | grep -q local || uci -q add_list network.ahwlan.ip6class='local'
# bridge ports: eth + bat0 (idempotent)
uci -q delete network.br_ahwlan.ports
[ -n "$ETH" ] && uci -q add_list network.br_ahwlan.ports="$ETH"
uci -q add_list network.br_ahwlan.ports='bat0'
# the stock lan bridge must give the ethernet port up, or eth sits in two bridges
for d in $(uci show network | sed -n "s/^network\.\([^.]*\)\.name='br-lan'$/\1/p"); do
	uci -q del_list "network.$d.ports=$ETH"
done
# stock lan keeps its 10.41.254.1 -> would clash with ahwlan; park it on the wizard's LAN default
uci -q set network.lan.ipaddr='10.40.0.1'
# arm openmanetd's address reservation (stage 2) when ahwlan is new; ahwlan IP above is only bootstrap
[ "$NEW_AHWLAN" = 1 ] && uci -q set openmanetd.config.dhcpconfigured='0'

# --- mesh11sd: the trio batman-over-802.11s needs ------------------------------------------
uci -q batch <<EOF
set mesh11sd.setup.enabled='1'
set mesh11sd.mesh_params.mesh_fwding='0'
set mesh11sd.mesh_params.mesh_nolearn='1'
set mesh11sd.mesh_params.mesh_gate_announcements='0'
EOF

# --- firewall: ahwlan zone (local: everything accepted), forwarding ahwlan->lan ------------
if ! uci show firewall | grep -q "\.name='ahwlan'"; then
	z=$(uci -q add firewall zone)
	uci -q batch <<EOF
set firewall.$z.name='ahwlan'
add_list firewall.$z.network='ahwlan'
set firewall.$z.input='ACCEPT'
set firewall.$z.output='ACCEPT'
set firewall.$z.forward='ACCEPT'
set firewall.$z.mtu_fix='1'
EOF
	f=$(uci -q add firewall forwarding)
	uci -q set "firewall.$f.src=ahwlan"; uci -q set "firewall.$f.dest=lan"
fi

# --- dhcp: serve the HaLow bridge (clients: phones on the AP, wired laptops) ---------------
uci -q get dhcp.ahwlan >/dev/null || uci -q batch <<EOF
set dhcp.ahwlan=dhcp
set dhcp.ahwlan.interface='ahwlan'
set dhcp.ahwlan.start='100'
set dhcp.ahwlan.limit='150'
set dhcp.ahwlan.leasetime='12h'
EOF
uci -q set dhcp.lan.ignore='1'
# mDNS on the bridge
uci -q get umdns.@umdns[0] >/dev/null 2>&1 && { uci -q get umdns.@umdns[0].network | grep -q ahwlan || uci -q add_list umdns.@umdns[0].network='ahwlan'; }

uci commit
lg "committed: mesh_id=$MESH_ID ch=$CHANNEL($COUNTRY) bootstrap=$AHWLAN_IP (reservation armed=$NEW_AHWLAN) hardif=batmesh0->bat0->br-ahwlan($ETH)"

if [ "$APPLY" = 1 ]; then
	lg "applying (network restart drops the link for a few seconds)"
	/etc/init.d/firewall reload >/dev/null 2>&1
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	/etc/init.d/network restart
	sleep 8
	/etc/init.d/mesh11sd restart >/dev/null 2>&1
	/etc/init.d/umdns restart >/dev/null 2>&1
	lg "applied"
fi
exit 0
