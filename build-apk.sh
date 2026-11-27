#!/bin/sh
# 打包 25.12+ 固件用的 apk：APK=<OpenWrt/ImmortalWrt ImageBuilder 或 SDK 里的 staging_dir/host/bin/apk> ./build-apk.sh
# 输出 dist/luci-app-sshguard-<版本>-r<release>.apk
set -e
cd "$(dirname "$0")"
TOP=$(pwd)
PKG=luci-app-sshguard
: "${APK:?需要设置 APK=apk 可执行文件路径}"
V=$(sed -n 's/^PKG_VERSION:=//p' $PKG/Makefile)
R=$(sed -n 's/^PKG_RELEASE:=//p' $PKG/Makefile)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/data/lib/apk/packages" "$W/s" dist
cp -r $PKG/root/. "$W/data/"
chmod 755 "$W/data/usr/bin/sshguard.sh" "$W/data/usr/bin/sshguard-luci-hook" "$W/data/usr/bin/sshguard-update" "$W/data/etc/init.d/sshguard" "$W/data/etc/uci-defaults/luci-sshguard" "$W/data/usr/share/sshguard/firewall.include"
cp $PKG/control/conffiles "$W/data/lib/apk/packages/$PKG.conffiles"
(cd "$W/data" && find . -type f,l -printf "/%P\n" | sort > "$W/list" && mv "$W/list" "lib/apk/packages/$PKG.list")
hdr() { printf '#!/bin/sh\n[ -s "${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0\n. "${IPKG_INSTROOT}/lib/functions.sh"\nexport root="${IPKG_INSTROOT}"\nexport pkgname="%s"\n' "$PKG"; }
{ hdr; echo '[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0'; echo default_postinst; sed '/^\s*#!/d; /^exit 0$/d' $PKG/control/postinst; echo 'exit 0'; } > "$W/s/post-install"
{ echo '#!/bin/sh'; echo 'export PKG_UPGRADE=1'; sed '/^\s*#!/d' $PKG/control/postinst; } > "$W/s/post-upgrade"
{ hdr; echo default_prerm; sed '/^\s*#!/d; /^exit 0$/d' $PKG/control/prerm; echo 'exit 0'; } > "$W/s/pre-deinstall"
cp $PKG/control/postrm "$W/s/post-deinstall"
chmod 755 "$W/s/"*
OUT="$TOP/dist/$PKG-$V-r$R.apk"
"$APK" mkpkg \
  --info "name:$PKG" --info "version:$V-r$R" \
  --info "description:SSH 与 LuCI 网页登录 Bark 预警、暴力破解自动封禁" \
  --info "arch:noarch" --info "license:MIT" --info "origin:$PKG" \
  --info "url:https://github.com/yeyinghai/openwrt-safedog" --info "maintainer:yeyinghai" \
  --info "depends:libc curl luci-compat luci-lib-nixio" \
  --script "post-install:$W/s/post-install" --script "post-upgrade:$W/s/post-upgrade" \
  --script "pre-deinstall:$W/s/pre-deinstall" --script "post-deinstall:$W/s/post-deinstall" \
  --files "$W/data" --output "$OUT"
echo "$OUT"
