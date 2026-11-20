# OpenWrt SDK / 源码树编译：把 luci-app-sshguard 目录放到 package/ 下，
# make menuconfig 选中 LuCI -> 3. Applications -> luci-app-sshguard，然后 make package/luci-app-sshguard/compile V=s
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-sshguard
PKG_VERSION:=1.4.0
PKG_RELEASE:=1
PKG_MAINTAINER:=yeyinghai

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for SSH / LuCI login alert (Bark)
  DEPENDS:=+curl +luci-compat +ipset +iptables
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  监控 dropbear 与 LuCI 网页登录，暴力破解或登录成功时通过 Bark 推送到手机。
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/sshguard
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(CP) ./root/* $(1)/
	chmod 0755 $(1)/usr/bin/sshguard.sh $(1)/usr/bin/sshguard-luci-hook $(1)/usr/bin/sshguard-update $(1)/etc/init.d/sshguard $(1)/usr/share/sshguard/firewall.include
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || { [ -f /etc/uci-defaults/luci-sshguard ] && ( . /etc/uci-defaults/luci-sshguard ) && rm -f /etc/uci-defaults/luci-sshguard; /usr/bin/sshguard-luci-hook apply; /etc/init.d/sshguard enable; /etc/init.d/sshguard restart; }
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	/etc/init.d/sshguard stop; /etc/init.d/sshguard disable
	/usr/bin/sshguard.sh cron off
	/usr/bin/sshguard-luci-hook remove
	iptables -t raw -D PREROUTING -m set --match-set sshguard_ban src -j DROP 2>/dev/null
	ipset -q destroy sshguard_ban
}
exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
uci -q delete ucitrack.@sshguard[-1] && uci commit ucitrack
uci -q delete firewall.sshguard && uci commit firewall
sed -i "/sshguard.sh report/d; /sshguard-update check/d" /etc/crontabs/root 2>/dev/null
rm -rf /tmp/luci-* /tmp/sshguard
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
