#!/bin/sh
# 发版前运行：根据 Makefile 版本和 CHANGELOG.md 生成 version.json（供 jsDelivr / 镜像检查更新）
set -e
cd "$(dirname "$0")"
V=$(sed -n 's/^PKG_VERSION:=//p' luci-app-sshguard/Makefile)
R=$(sed -n 's/^PKG_RELEASE:=//p' luci-app-sshguard/Makefile)
python3 - "$V" "$R" <<'PY'
import sys, json, re
v, r = sys.argv[1], sys.argv[2]
t = open('CHANGELOG.md', encoding='utf-8').read()
m = re.search(r'^## ' + re.escape(v) + r' \(([^)]*)\)\n(.*?)(?=^## |\Z)', t, re.S | re.M)
if not m: sys.exit('CHANGELOG.md 里没有 ' + v)
notes = m.group(2).strip()
json.dump({'version': v, 'date': m.group(1), 'ipk': f'luci-app-sshguard_{v}-{r}_all.ipk', 'apk': f'luci-app-sshguard-{v}-r{r}.apk', 'notes': notes},
          open('version.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
open('dist/notes.md', 'w', encoding='utf-8').write(notes + '\n') if __import__('os').path.isdir('dist') else None
print('version.json ->', v)
PY
