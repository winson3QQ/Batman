# Batman payload-host meta-package (#159) — bakes the Docker engine into the Pi 4
# image so a payload-host node gets a container runtime from the image, not from a
# manual 43-package offline opkg install (the bench expedient proven on manet01 during
# #98). One dependency closure, one tracked toggle, board-gated to bcm2711.
#
# WHY a meta-package (review M3): selecting the 43 packages as loose CONFIG_PACKAGE_*=y
# lines had the "kmod stays =m" trap — a kmod dragged in only as a transitive dep does
# not flip to =y and is left out of the squashfs. A meta-package with an explicit DEPENDS
# closure forces every one of them into the image and gives a single audited toggle.
#
# The DEPENDS set is the runtime closure captured on manet01 and recorded in
# deploy/fts/payload-host-packages.txt, MINUS two categories:
#   1. cgroupfs-mount (see below, review B1).
#   2. ABI-versioned auto-split libraries (libmount1, liblzo2, libxtables12,
#      libiptext0, libiptext6-0, libiptext-nft0). These are NOT buildable package
#      symbols — opkg auto-generates them (with the soname version suffix) from their
#      source packages (util-linux, lzo, iptables). They cannot be DEPENDS targets and
#      are pulled in transitively when btrfs-progs / dockerd / iptables-nft are selected.
#   Everything else — top-level userspace AND every kmod (the "=m trap" packages) — is
#   listed explicitly. scripts/check-payload-host-sync.sh treats those two categories as
#   the allowed delta between this DEPENDS set and payload-host-packages.txt.
#
#   cgroupfs-mount is deliberately NOT installed (review B1). Its init swaps procd's
#   cgroup-v2 hierarchy for a v1 layout at S01; with no CONFIG_CGROUP_DEVICE in this
#   kernel, dockerd then dies with "Devices cgroup isn't mounted." Docker uses cgroup v2
#   here, so the mount script must be absent, not merely disabled. dockerd's DEPENDS does
#   NOT pull cgroupfs-mount (it is only referenced in dockerd/Config.in), so leaving it
#   out of this closure keeps it out of the image.
#
# scripts/check-payload-host-sync.sh (CI) asserts this DEPENDS set == payload-host-packages.txt
# minus cgroupfs-mount, so the two repos (firmware seed vs this feed) cannot drift (review M2).
#
# memcg: enabling the memory cgroup controller is NOT done here — it is a kernel DTB fix
# in the firmware fork (patch 950-1446, drops cgroup_disable=memory from the bcm2711
# bootargs). See docs/design and issue #109/#98.

include $(TOPDIR)/rules.mk

PKG_NAME:=batman-payload-host
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_MAINTAINER:=Batman <yellow.winson@gmail.com>
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/batman-payload-host
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Batman payload-host (Docker engine) meta-package [#159]
  URL:=https://github.com/winson3QQ/Batman
  # Pi 4 (bcm2711) only. The Zero 2 W (bcm2710) has no headroom for a container host
  # and is board-gated out of the payload-host archetype (#110/#68).
  DEPENDS:=@TARGET_bcm27xx_bcm2711 \
    +btrfs-progs \
    +ca-certificates \
    +containerd \
    +docker \
    +dockerd \
    +ip6tables-nft \
    +iptables-mod-extra \
    +iptables-nft \
    +kmod-br-netfilter \
    +kmod-crypto-blake2b \
    +kmod-crypto-xxhash \
    +kmod-fs-btrfs \
    +kmod-ip6tables \
    +kmod-ipt-conntrack \
    +kmod-ipt-core \
    +kmod-ipt-extra \
    +kmod-ipt-nat \
    +kmod-ipt-nat6 \
    +kmod-ipt-physdev \
    +kmod-lib-raid6 \
    +kmod-lib-xor \
    +kmod-lib-xxhash \
    +kmod-lib-zlib-deflate \
    +kmod-lib-zlib-inflate \
    +kmod-lib-zstd \
    +kmod-nf-ipt \
    +kmod-nf-ipt6 \
    +kmod-nf-ipvs \
    +kmod-nf-nat6 \
    +kmod-nft-compat \
    +kmod-veth \
    +libseccomp \
    +mount-utils \
    +runc \
    +tini \
    +xtables-nft
  PKGARCH:=all
endef

define Package/batman-payload-host/description
 Meta-package that pulls the full Docker engine closure (dockerd/containerd/runc +
 iptables-nft + kernel modules) into the Pi 4 image, so a payload-host node ships with
 a container runtime instead of needing a manual offline opkg install. Board-gated to
 bcm2711. Ships a uci-default that points dockerd's data-root at the persistent data
 partition (/opt/batdata/docker) and enables the service. See #159 #119 #98 #68.
endef

# files-only meta-package: the value is the DEPENDS closure + the data-root uci-default.
define Build/Prepare
endef
define Build/Compile
endef

define Package/batman-payload-host/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-batman-payload-docker $(1)/etc/uci-defaults/99-batman-payload-docker
endef

$(eval $(call BuildPackage,batman-payload-host))
