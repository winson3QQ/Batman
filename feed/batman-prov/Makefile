# batman-prov — #254 provisioning service, two binaries from one Go module: batman-provhelper (root; identity,
# persistence, state changes) and batman-provd (uid provd in a ujail; the BLE protocol, PR-P2). Sources are in ./src
# (vendored: the build never fetches anything). docs/design/254-stage1-impl.md, 254-p1-impl.md, 254-p2-impl.md.
#
# The `provd` user/group have a FIXED id 471 (not used by any OpenWrt package or the fleet's containers: 999,
# 1000, rabbitmq) — the helper only answers that uid (SO_PEERCRED).

include $(TOPDIR)/rules.mk

PKG_NAME:=batman-prov
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_MAINTAINER:=Batman <yellow.winson@gmail.com>
PKG_LICENSE:=GPL-2.0-or-later

PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

GO_PKG:=batman-prov
GO_PKG_BUILD_PKG:=batman-prov/cmd/batman-provhelper batman-prov/cmd/batman-provd
GO_PKG_LDFLAGS:=-s -w
# Test-only seams (killpoint file, --version marker; provd's provd.env switches and frame socket): ONLY when the
# firmware build asks for a -wbox variant (build-board.sh --wbox, docs/design/254-h23-harness.md §4.1.2). A release
# build never sets this; its gate checks both binaries for the test strings.
ifeq ($(BATMAN_PROV_TEST),1)
GO_PKG_TAGS:=prov_test
else
GO_PKG_TAGS:=
endif

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/batman-prov
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Batman provisioning helper and BLE protocol process (issue 254)
  DEPENDS:=$(GO_ARCH_DEPENDS) +batman-provision
  USERID:=provd=471:provd=471
endef

define Package/batman-prov/description
  Batman BLE provisioning service: batman-provhelper (root: node identity, the provisioning
  record on the config partition, owner-authorised state changes, health file) and
  batman-provd (unprivileged, jailed: BLE advertisement + GATT, Noise sessions).
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/. $(PKG_BUILD_DIR)/
endef

define Package/batman-prov/install
	$(call GoPackage/Package/Install/Bin,$(1))
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/batman-provhelper.init $(1)/etc/init.d/batman-provhelper
	$(INSTALL_BIN) ./files/batman-provd$(if $(filter 1,$(BATMAN_PROV_TEST)),-test).init $(1)/etc/init.d/batman-provd
	$(INSTALL_DIR) $(1)/etc/capabilities
	$(INSTALL_DATA) ./files/batman-provd.json $(1)/etc/capabilities/batman-provd.json
endef

$(eval $(call GoBinPackage,batman-prov))
$(eval $(call BuildPackage,batman-prov))
