# Batman mesh-node provisioning, config-survival + observability — baked into the image
# instead of installed at deploy time onto a live node (the pre-v2.0 golden-node model in
# scripts/depersonalise.sh). Files-only package: everything is a shipped script/hook, no compile.
#
# Selected into an image with a diffconfig entry (CONFIG_PACKAGE_batman-provision=y) on
# boards/ekh-bcm2711 and boards/ekh-bcm2710. Lands in the read-only squashfs /rom, so the
# first-boot hooks (94/95/96/97/99) re-run once per fresh overlay — i.e. once per A/B slot
# flash, which is exactly what config-survival (#88/#89) needs and the deploy-time model
# cannot give.
#
# 3b RESOLVED (2026-09-13, verified on real hardware — Build #1 booted on a fresh A/B slot on
# manet01): the mesh BASELINE (deploy/provisioning/meshpoint-1.8.0.sh, shipped here as
# /usr/bin/meshpoint-1.8.0) IS baked as 94-batman-baseline, a uci-default numbered BEFORE 96 so
# 96's restored per-node delta overrides this baseline's placeholder values on a slot switch.
# The earlier open question ("does uci_apply_defaults run before wifi-device detection?") was
# answered by reading /etc/init.d/boot's actual source: `/sbin/wifi config` (hardware-detects
# the morse wifi-device into /etc/config/wireless) runs BEFORE `uci_apply_defaults` in the same
# boot() call — so wireless.$RADIO already exists when 94-batman-baseline runs. Confirmed by
# booting Build #1 (this package, pre-94) on manet01's A/B card slot B and reading the real
# init script; 94 itself is untested end-to-end pending Build #2.

include $(TOPDIR)/rules.mk

PKG_NAME:=batman-provision
PKG_VERSION:=1.0.0
PKG_RELEASE:=4
PKG_MAINTAINER:=Batman <yellow.winson@gmail.com>
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/batman-provision
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Batman mesh-node provisioning, config-survival & observability
  # parted + e2fsprogs: 95-batman-storage carves/mkfs the data partition.
  # block-mount: mount helpers. dropbear: dropbearkey used by 96 to fingerprint restored keys.
  # The mesh/observability tools (batctl, iw, uhttpd, logger, wget) are in the OpenMANET base.
  DEPENDS:=+parted +e2fsprogs +block-mount +dropbear +uci +blkid
  PKGARCH:=all
endef

define Package/batman-provision/description
 First-boot hooks (95-batman-storage data partition, 96-batman-config-migrate p5
 config+identity restore, 99-halow-identity personalisation), config-survival saver
 (batman-config-save), and runtime observability services (joinwatch #127,
 halow-status health roll-up, meshled, batpower #122, flightrec #105) plus the
 verdict-first /cgi-bin/status, #14 /cgi-bin/mesh and root landing page, plus
 batman-faketime (#174): offline monotonic wall-clock persistence (no RTC/NTP).
 See docs/design/p5-config-partition.md and issues #88 #89 #127 #130 #14 #174.
endef

# files-only: nothing to build
define Build/Prepare
endef
define Build/Compile
endef

define Package/batman-provision/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults $(1)/etc/init.d $(1)/usr/bin $(1)/usr/sbin $(1)/usr/lib/batman $(1)/www/cgi-bin
	# first-boot hooks (0755)
	$(INSTALL_BIN) ./files/etc/uci-defaults/94-batman-baseline        $(1)/etc/uci-defaults/94-batman-baseline
	$(INSTALL_BIN) ./files/etc/uci-defaults/92-batman-ramoops-fix        $(1)/etc/uci-defaults/92-batman-ramoops-fix
	$(INSTALL_BIN) ./files/etc/uci-defaults/95-batman-storage        $(1)/etc/uci-defaults/95-batman-storage
	$(INSTALL_BIN) ./files/etc/uci-defaults/96-batman-config-migrate $(1)/etc/uci-defaults/96-batman-config-migrate
	$(INSTALL_BIN) ./files/etc/uci-defaults/97-batman-landing        $(1)/etc/uci-defaults/97-batman-landing
	$(INSTALL_BIN) ./files/etc/uci-defaults/98-batman-sysupgrade      $(1)/etc/uci-defaults/98-batman-sysupgrade
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-halow-identity        $(1)/etc/uci-defaults/99-halow-identity
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-batman-chanfix        $(1)/etc/uci-defaults/99-batman-chanfix
	# services
	$(INSTALL_BIN) ./files/etc/init.d/halow-keyguard $(1)/etc/init.d/halow-keyguard
	$(INSTALL_BIN) ./files/etc/init.d/batpower       $(1)/etc/init.d/batpower
	$(INSTALL_BIN) ./files/etc/init.d/flightrec      $(1)/etc/init.d/flightrec
	$(INSTALL_BIN) ./files/etc/init.d/joinwatch      $(1)/etc/init.d/joinwatch
	$(INSTALL_BIN) ./files/etc/init.d/meshled        $(1)/etc/init.d/meshled
	$(INSTALL_BIN) ./files/etc/init.d/batman-faketime $(1)/etc/init.d/batman-faketime
	# tools
	$(INSTALL_BIN) ./files/usr/bin/batman-version     $(1)/usr/bin/batman-version
	$(INSTALL_BIN) ./files/etc/uci-defaults/93-batman-version-banner $(1)/etc/uci-defaults/93-batman-version-banner
	$(INSTALL_BIN) ./files/usr/bin/batman-config-save $(1)/usr/bin/batman-config-save
	$(INSTALL_BIN) ./files/usr/bin/halow-setkey       $(1)/usr/bin/halow-setkey
	$(INSTALL_BIN) ./files/usr/bin/halow-status       $(1)/usr/bin/halow-status
	$(INSTALL_BIN) ./files/usr/bin/joinwatch          $(1)/usr/bin/joinwatch
	$(INSTALL_BIN) ./files/usr/bin/batpower           $(1)/usr/bin/batpower
	$(INSTALL_BIN) ./files/usr/bin/flightrec          $(1)/usr/bin/flightrec
	$(INSTALL_BIN) ./files/usr/bin/meshled            $(1)/usr/bin/meshled
	$(INSTALL_BIN) ./files/usr/bin/meshpoint-1.8.0    $(1)/usr/bin/meshpoint-1.8.0
	$(INSTALL_BIN) ./files/usr/bin/meshtest           $(1)/usr/bin/meshtest
	# generic payload manager (#167): orchestrator + arbiter + shared guardian logic. Per-tenant
	# state (manifest/net.alloc/hardening.env/fw4 + the 4-line guardian init) lives on p6 under
	# apps/<tenant>/ and is restored after A/B flash by 95-batman-storage's #192 glob — NOT baked here.
	$(INSTALL_BIN) ./files/usr/bin/payload-run        $(1)/usr/bin/payload-run
	$(INSTALL_BIN) ./files/usr/bin/payload-arbiter    $(1)/usr/bin/payload-arbiter
	$(INSTALL_BIN) ./files/usr/bin/payload-teardown   $(1)/usr/bin/payload-teardown
	$(INSTALL_DATA) ./files/usr/lib/batman/payload-guardian.sh $(1)/usr/lib/batman/payload-guardian.sh
	# offline monotonic wall-clock (#174): restore@S12 (after batdata-mount S11), save@K09 + periodic
	$(INSTALL_BIN) ./files/usr/sbin/batman-faketime   $(1)/usr/sbin/batman-faketime
	# A/B slot operator (#89): the one audited place for slot apply/commit/rollback, shared with
	# scripts/ab-selftest.sh and /lib/upgrade/platform.sh. See docs/design/ab-sysupgrade-platform.md.
	$(INSTALL_BIN) ./files/usr/sbin/batman-slot       $(1)/usr/sbin/batman-slot
	# A/B platform.sh override (installed over /lib/upgrade/platform.sh by 98-batman-sysupgrade,
	# first boot; the feed cannot ship /lib/upgrade/platform.sh directly — base file clash).
	$(INSTALL_BIN) ./files/usr/lib/batman/platform-ab.sh $(1)/usr/lib/batman/platform-ab.sh
	# web
	$(INSTALL_BIN) ./files/www/cgi-bin/status $(1)/www/cgi-bin/status
	$(INSTALL_BIN) ./files/www/cgi-bin/bundle $(1)/www/cgi-bin/bundle
	$(INSTALL_BIN) ./files/www/cgi-bin/mesh   $(1)/www/cgi-bin/mesh
	# NOT /www/index.html — luci-base owns that path (build-time file clash); ship it under a
	# distinct name and let 97-batman-landing copy it over /www/index.html on first boot.
	$(INSTALL_DATA) ./files/www/index-batman.html $(1)/www/index-batman.html
endef

# Enable the runtime services in the built image. On a squashfs image build this runs with
# $${IPKG_INSTROOT} set (offline root); enable respects it and creates the rc.d symlinks at each
# init script's own START= number (halow-keyguard S18, batpower S95, joinwatch S98,
# flightrec/meshled S99). VERIFY in CI that the symlinks land in the image.
define Package/batman-provision/postinst
#!/bin/sh
for s in halow-keyguard batpower flightrec joinwatch meshled batman-faketime; do
	if [ -x "$${IPKG_INSTROOT}/etc/init.d/$$s" ]; then
		"$${IPKG_INSTROOT}/etc/init.d/$$s" enable 2>/dev/null
	fi
done
[ -n "$${IPKG_INSTROOT}" ] || {
	for s in halow-keyguard batpower flightrec joinwatch meshled batman-faketime; do
		/etc/init.d/$$s start 2>/dev/null
	done
}
exit 0
endef

$(eval $(call BuildPackage,batman-provision))
