# batman-prov — #254 provisioning service: batman-provhelper (root; identity, persistence, state changes) now,
# batman-provd (unprivileged BLE protocol, PR-P2) later from the same Go module. Sources are in ./src (vendored:
# the build never fetches anything). docs/design/254-stage1-impl.md, docs/design/254-p1-impl.md.
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
GO_PKG_BUILD_PKG:=batman-prov/cmd/batman-provhelper
GO_PKG_LDFLAGS:=-s -w
# Test-only seams (killpoint file, --version marker): ONLY when the firmware build asks for a -wbox variant
# (build-board.sh --wbox, docs/design/254-h23-harness.md §4.1.2). A release build never sets this; its gate checks
# the helper binary for the marker and the killpoint strings.
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
  TITLE:=Batman provisioning helper (issue 254)
  DEPENDS:=$(GO_ARCH_DEPENDS) +batman-provision
  USERID:=provd=471:provd=471
endef

define Package/batman-prov/description
  Root half of the Batman BLE provisioning service: node identity (file backend), the
  provisioning record on the config partition, owner-authorised state changes, health file.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/. $(PKG_BUILD_DIR)/
endef

define Package/batman-prov/install
	$(call GoPackage/Package/Install/Bin,$(1))
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/batman-provhelper.init $(1)/etc/init.d/batman-provhelper
endef

$(eval $(call GoBinPackage,batman-prov))
$(eval $(call BuildPackage,batman-prov))
