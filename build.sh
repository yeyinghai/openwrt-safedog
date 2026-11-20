#!/bin/sh
# 不依赖 OpenWrt SDK，直接打包架构无关的 ipk：./build.sh  ->  dist/luci-app-sshguard_<版本>_all.ipk
set -e
cd "$(dirname "$0")"
TOP=$(pwd)
PKG=luci-app-sshguard
VER=$(sed -n 's/^PKG_VERSION:=//p' $PKG/Makefile)-$(sed -n 's/^PKG_RELEASE:=//p' $PKG/Makefile)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/ctl" dist
cp $PKG/control/* "$W/ctl/"
chmod 755 "$W/ctl/postinst" "$W/ctl/prerm" "$W/ctl/postrm"
cp -r $PKG/root "$W/data"
chmod 755 "$W/data/usr/bin/sshguard.sh" "$W/data/usr/bin/sshguard-luci-hook" "$W/data/etc/init.d/sshguard" "$W/data/etc/uci-defaults/luci-sshguard"
SIZE=$(du -sk "$W/data" | cut -f1)
cat > "$W/ctl/control" <<C
Package: $PKG
Version: $VER
Depends: libc, curl, luci-compat
Source: https://github.com/yeyinghai/openwrt-safedog
Section: luci
Architecture: all
Maintainer: yeyinghai
Installed-Size: $((SIZE * 1024))
Description: SSH 与 LuCI 网页登录 Bark 预警
C
echo 2.0 > "$W/debian-binary"
(cd "$W/ctl"  && tar --owner=0 --group=0 --numeric-owner -czf ../control.tar.gz ./control ./conffiles ./postinst ./prerm ./postrm)
(cd "$W/data" && tar --owner=0 --group=0 --numeric-owner -czf ../control.tmp . && mv ../control.tmp ../data.tar.gz)
OUT="$TOP/dist/${PKG}_${VER}_all.ipk"
(cd "$W" && tar --owner=0 --group=0 --numeric-owner -czf "$OUT" ./debian-binary ./control.tar.gz ./data.tar.gz)
echo "$OUT"
