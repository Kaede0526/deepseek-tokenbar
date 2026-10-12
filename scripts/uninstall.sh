#!/bin/bash
# uninstall.sh — 退出 App、停掉定时采集、移除安装的文件
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
APP_DEST="$HOME/Applications/TokenBar.app"

pkill -f "TokenBar.app/Contents/MacOS/TokenBar" 2>/dev/null && echo "已退出 TokenBar" || true

# 新旧两个标签都清，避免改名后残留
for L in "com.lanzhusu.tokenbar.collect" "com.dxz.tokenbar.collect"; do
  P="$HOME/Library/LaunchAgents/$L.plist"
  if [ -f "$P" ]; then
    launchctl bootout "gui/$(id -u)/$L" 2>/dev/null || true
    rm -f "$P"
    echo "已移除定时采集 ($L)"
  fi
done

rm -rf "$APP_DEST"
echo "已移除 App"

echo
echo "保留（要清就自己删）:"
echo "  $ROOT/.data/    采集数据与日志"
echo "  $ROOT/dist/     编译产物"
