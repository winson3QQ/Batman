#!/bin/sh
# 在【第二台】OpenMANET 節點上執行，套用與 manet01 相同的 mesh 參數。
# 前置：已燒錄映像 + 清 overlay + 開機 + 裝好 SSH 公鑰。
set -e

# ── HaLow radio（必須與 manet01 完全相同）──
uci set wireless.radio3.channel='42'          # 923 MHz @ 2 MHz
uci set wireless.radio3.country='US'
uci set wireless.radio3.hwmode='11ah'
uci set wireless.radio3.band='s1g'
uci set wireless.radio3.bcf='bcf_fgh100mhaamd.bin'
uci set wireless.radio3.enable_ps='0'
uci set wireless.radio3.enable_twt='0'
uci set wireless.radio3.enable_mcast_rate_control='1'

# ── mesh iface（mesh_id / encryption / key 必須完全相同）──
uci set wireless.default_radio3.mode='mesh'
uci set wireless.default_radio3.mesh_id='openmanet1'
uci set wireless.default_radio3.encryption='sae'
uci set wireless.default_radio3.key='12345678'      # ← 若已更換，兩台一起改
uci set wireless.default_radio3.beacon_int='1000'
uci set wireless.default_radio3.wds='1'
uci set wireless.default_radio3.network='batmesh0'

# ── 不用 2.4G ──
uci set wireless.radio2.disabled='1'

# ── 識別 ──
uci set system.@system[0].hostname='manet02'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Taipei'

# ── LED 指示器：開機預設「未接管」暗閃，meshled 通過檢查後才改恆亮 ──
# 這段一定要在 meshled 之前存在，否則沒裝 meshled 時紅燈會是出廠恆亮，
# 跟「系統 OK」分不出來。
uci -q delete system.led_pwr_unmanaged
uci set system.led_pwr_unmanaged=led
uci set system.led_pwr_unmanaged.name='PWR unmanaged'
uci set system.led_pwr_unmanaged.sysfs='PWR'
uci set system.led_pwr_unmanaged.trigger='timer'
uci set system.led_pwr_unmanaged.delayon='4900'
uci set system.led_pwr_unmanaged.delayoff='100'
uci set system.led_pwr_unmanaged.default='1'

uci commit
/etc/init.d/system reload
/etc/init.d/avahi-daemon restart      # 不做的話 mDNS 會繼續廣播舊名稱
/etc/init.d/led restart
wifi reload
sleep 5

# ── 安裝 meshled ──
# 先從 Pi 500 複製過來：
#   scp ~/Batman/scripts/meshled      root@<node>:/usr/bin/meshled
#   scp ~/Batman/scripts/meshled.init root@<node>:/etc/init.d/meshled
if [ -x /usr/bin/meshled ] && [ -x /etc/init.d/meshled ]; then
	/etc/init.d/meshled enable
	/etc/init.d/meshled restart
	echo "meshled: 已啟動"
else
	echo "⚠️  meshled 尚未複製到這台，紅燈會停在暗閃（UNMANAGED）"
fi

echo "--- 驗證 ---"
echo "hostname: $(cat /proc/sys/kernel/hostname)"
morse_cli -i wlan0 channel 2>/dev/null | head -3
batctl if 2>/dev/null
batctl n 2>/dev/null
echo "--- 燈號 ---"
# 用 ps 而非 pgrep：pgrep -f 會把呼叫端自己的指令列也算進去
echo "meshled 實例: $(ps w | grep -c '[m]eshled run')"
[ -x /usr/bin/meshled ] && /usr/bin/meshled status
