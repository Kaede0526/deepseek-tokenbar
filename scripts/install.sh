#!/bin/bash
# install.sh — 编译 App + 装到 ~/Applications + 注册定时采集 + 启动
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # scripts/
ROOT="$(cd "$DIR/.." && pwd)"                          # 项目根
LABEL="com.lanzhusu.tokenbar.collect"
LEGACY_LABEL="com.dxz.tokenbar.collect"   # 改名前用过的标签，装完顺手清掉
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
APP_DEST="$HOME/Applications/TokenBar.app"
DATA_DIR="$ROOT/.data"
INTERVAL=60   # 采集间隔（秒）

# --- 找 python3
PYTHON=""
for cand in /opt/homebrew/bin/python3 /usr/local/bin/python3 "$(command -v python3 || true)" /usr/bin/python3; do
  if [ -n "$cand" ] && [ -x "$cand" ]; then PYTHON="$cand"; break; fi
done
[ -n "$PYTHON" ] || { echo "错误: 找不到 python3" >&2; exit 1; }

# --- 必须能读会话日志，否则采不到用量
if ! command -v zstd >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/zstd ]; then
  echo "警告: 找不到 zstd，collect.py 将无法读取会话日志。" >&2
  echo "      安装: brew install zstd" >&2
fi

mkdir -p "$DATA_DIR"

# --- 1) 编译
"$DIR/build.sh"

# --- 2) 装 App
mkdir -p "$HOME/Applications"
# 先退掉正在跑的实例，否则旧进程会继续持有已被替换的 bundle
pkill -f "TokenBar.app/Contents/MacOS/TokenBar" 2>/dev/null && sleep 1 || true
rm -rf "$APP_DEST"
cp -R "$ROOT/dist/TokenBar.app" "$APP_DEST"
touch "$APP_DEST"   # 让 Finder 重新读图标而不是拿缓存
echo "==> 已安装: $APP_DEST"

# --- 3) 定时采集（LaunchAgent）
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON</string>
        <string>$ROOT/src/collect.py</string>
    </array>
    <key>StartInterval</key><integer>$INTERVAL</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$DATA_DIR/collect.log</string>
    <key>StandardErrorPath</key><string>$DATA_DIR/collect.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
EOF

# 清掉改名前的旧任务：否则两个标签会同时生效，每 60 秒跑两次、数据分叉
if [ -f "$LEGACY_PLIST" ]; then
  launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null || true
  rm -f "$LEGACY_PLIST"
  echo "==> 已移除旧任务 $LEGACY_LABEL（改名前的）"
fi

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/$LABEL" 2>/dev/null || true
echo "==> 定时采集已启用: 每 ${INTERVAL}s 一次 ($LABEL)"
echo "    日志: $DATA_DIR/collect.log"

# --- 4) 先立刻采一次，再启动
"$PYTHON" "$ROOT/src/collect.py" || true
open "$APP_DEST"
echo "==> 已启动 TokenBar，看菜单栏（可能需要几秒）"
echo
echo "卸载: scripts/uninstall.sh"
