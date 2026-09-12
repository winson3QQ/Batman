# Batman mesh-node provisioning, config-survival + observability — baked into the image
# instead of installed at deploy time onto a live node (the pre-v2.0 golden-node model in
# scripts/depersonalise.sh). Files-only package: everything is a shipped script/hook, no compile.
#
# Selected into an image with a diffconfig entry (CONFIG_PACKAGE_batman-provision=y) on
# boards/ekh-bcm2711 and boards/ekh-bcm2710. Lands in the read-only squashfs /rom, so the
# first-boot hooks (95/96/99) re-run once per fresh overlay — i.e. once per A/B slot flash,
# which is exactly what config-survival (#88/#89) needs and the deploy-time model cannot give.
#
# OPEN (3b, needs the OpenMANET firmware source + a build to settle): the mesh BASELINE
# (deploy/provisioning/meshpoint-1.8.0.sh, shipped here as /usr/bin/meshpoint-1.8.0) is NOT yet
# wired as a baked default. Two candidate mechanisms, decide against the built image:
#   (a) a uci-default (numbered 94, BEFORE 96 so 96's restored per-node delta wins) that runs
#       meshpoint-1.8.0 without --apply; depends on the `morse` wifi-device already existing in
#       /etc/config/wireless at S10 uci_apply_defaults time (hardware-detected, unverified timing);
#   (b) shipping the post-wizard /etc/config/{network,wireless,mesh11sd,firewall,dhcp} as static
#       files in /rom (idiomatic, but may collide with OpenMANET's board wireless generation).
# Until 3b lands, an image built from this package boots with stock networking.

include $(TOPDIR)/rules.mk

PKG_NAME:=batman-provision
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
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
 verdict-first /cgi-bin/status, #14 /cgi-bin/mesh and root landing page.
 See docs/design/p5-config-partition.md and issues #88 #89 #127 #130 #14.
endef

# files-only: nothing to build
define Build/Prepare
endef
define Build/Compile
endef

define Package/batman-provision/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults $(1)/etc/init.d $(1)/usr/bin $(1)/www/cgi-bin
	# first-boot hooks (0755)
	$(INSTALL_BIN) ./files/etc/uci-defaults/95-batman-storage        $(1)/etc/uci-defaults/95-batman-storage
	$(INSTALL_BIN) ./files/etc/uci-defaults/96-batman-config-migrate $(1)/etc/uci-defaults/96-batman-config-migrate
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-halow-identity        $(1)/etc/uci-defaults/99-halow-identity
	# services
	$(INSTALL_BIN) ./files/etc/init.d/halow-keyguard $(1)/etc/init.d/halow-keyguard
	$(INSTALL_BIN) ./files/etc/init.d/batpower       $(1)/etc/init.d/batpower
	$(INSTALL_BIN) ./files/etc/init.d/flightrec      $(1)/etc/init.d/flightrec
	$(INSTALL_BIN) ./files/etc/init.d/joinwatch      $(1)/etc/init.d/joinwatch
	$(INSTALL_BIN) ./files/etc/init.d/meshled        $(1)/etc/init.d/meshled
	# tools
	$(INSTALL_BIN) ./files/usr/bin/batman-config-save $(1)/usr/bin/batman-config-save
	$(INSTALL_BIN) ./files/usr/bin/halow-setkey       $(1)/usr/bin/halow-setkey
	$(INSTALL_BIN) ./files/usr/bin/halow-status       $(1)/usr/bin/halow-status
	$(INSTALL_BIN) ./files/usr/bin/joinwatch          $(1)/usr/bin/joinwatch
	$(INSTALL_BIN) ./files/usr/bin/batpower           $(1)/usr/bin/batpower
	$(INSTALL_BIN) ./files/usr/bin/flightrec          $(1)/usr/bin/flightrec
	$(INSTALL_BIN) ./files/usr/bin/meshled            $(1)/usr/bin/meshled
	$(INSTALL_BIN) ./files/usr/bin/meshpoint-1.8.0    $(1)/usr/bin/meshpoint-1.8.0
	# web
	$(INSTALL_BIN) ./files/www/cgi-bin/status $(1)/www/cgi-bin/status
	$(INSTALL_BIN) ./files/www/cgi-bin/bundle $(1)/www/cgi-bin/bundle
	$(INSTALL_BIN) ./files/www/cgi-bin/mesh   $(1)/www/cgi-bin/mesh
	$(INSTALL_DATA) ./files/www/index.html    $(1)/www/index.html
endef

# Enable the runtime services in the built image. On a squashfs image build this runs with
# $${IPKG_INSTROOT} set (offline root); enable respects it and creates the rc.d symlinks at each
# init script's own START= number (halow-keyguard S18, batpower S95, joinwatch S98,
# flightrec/meshled S99). VERIFY in CI that the symlinks land in the image.
define Package/batman-provision/postinst
#!/bin/sh
for s in halow-keyguard batpower flightrec joinwatch meshled; do
	if [ -x "$${IPKG_INSTROOT}/etc/init.d/$$s" ]; then
		"$${IPKG_INSTROOT}/etc/init.d/$$s" enable 2>/dev/null
	fi
done
[ -n "$${IPKG_INSTROOT}" ] || {
	for s in halow-keyguard batpower flightrec joinwatch meshled; do
		/etc/init.d/$$s start 2>/dev/null
	done
}
exit 0
endef

$(eval $(call BuildPackage,batman-provision))
