include $(TOPDIR)/rules.mk

PKG_NAME:=batman-reboot
PKG_VERSION:=1
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=Batman project

include $(INCLUDE_DIR)/package.mk

define Package/batman-reboot
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Restart into an explicit Raspberry Pi firmware boot partition
endef

define Package/batman-reboot/description
  reboot(2) RESTART2 with a decimal firmware partition number (1..31). Works around the Pi 4
  bootloader reading raw PM_RSTS flags as the reboot partition on partition-0 restarts.
  See docs/design/explicit-reboot.md in winson3QQ/Batman.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

# static: it is also staged into the sysupgrade ramfs (RAMFS_COPY_BIN), where shared libs are not guaranteed
define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) -Wall -Wextra -o $(PKG_BUILD_DIR)/batman-reboot $(PKG_BUILD_DIR)/batman-reboot.c $(TARGET_LDFLAGS) -static
endef

define Package/batman-reboot/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/batman-reboot $(1)/usr/sbin/batman-reboot
endef

$(eval $(call BuildPackage,batman-reboot))
