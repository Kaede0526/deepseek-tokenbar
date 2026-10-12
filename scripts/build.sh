#!/bin/bash
# build.sh — 编译 macOS 菜单栏 App（只需要 Command Line Tools，不需要 Xcode）
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # scripts/
ROOT="$(cd "$DIR/.." && pwd)"                          # 项目根
APP="$ROOT/dist/TokenBar.app"
BIN="$APP/Contents/MacOS/TokenBar"
BUILD="$ROOT/.build"
ARCH="$(uname -m)"

mkdir -p "$BUILD"

# --- 找 python3：优先 Homebrew，退回系统 python3
PYTHON=""
for cand in /opt/homebrew/bin/python3 /usr/local/bin/python3 "$(command -v python3 || true)" /usr/bin/python3; do
  if [ -n "$cand" ] && [ -x "$cand" ]; then PYTHON="$cand"; break; fi
done
if [ -z "$PYTHON" ]; then
  echo "错误: 找不到 python3" >&2
  exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "错误: 找不到 swiftc，请先装 Command Line Tools: xcode-select --install" >&2
  exit 1
fi

# --- 预检：Command Line Tools 的一个已知打包 bug
# /usr/include/swift/module.modulemap（2023 年残留）与新版
# /usr/include/module.modulemap（extern module → swift/bridging.modulemap）
# 重复定义 SwiftBridging，任何 import Foundation/AppKit 的编译都会失败。
STALE=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
PROBE="$BUILD/probe.swift"
printf 'import Foundation\n' > "$PROBE"
if ! swiftc -module-cache-path "$BUILD/mc" -typecheck "$PROBE" >/dev/null 2>&1; then
  if [ -f "$STALE" ]; then
    cat >&2 <<EOF
错误: Command Line Tools 安装损坏，无法编译 Swift。

  病根: $STALE
        这个 2023 年的残留文件与新版 module.modulemap 重复定义了 SwiftBridging。

  修复（一行，可逆，需要你的密码）:
    sudo mv "$STALE" "$STALE.disabled"

  然后重新运行本脚本即可。详见 docs/HOW-IT-WORKS.md
EOF
  else
    echo "错误: Foundation 无法编译，请检查 Command Line Tools 安装。" >&2
  fi
  exit 1
fi

# --- 生成编译期常量（路径不写死在源码里）
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
cat > "$BUILD/BuildConfig.swift" <<EOF
// 由 scripts/build.sh 自动生成，请勿手改，也不要提交
let kDataDir = "$(esc "$ROOT/.data")"
let kUsagePath = "$(esc "$ROOT/.data/usage.json")"
let kCollectPy = "$(esc "$ROOT/src/collect.py")"
let kPythonPath = "$(esc "$PYTHON")"
EOF

echo "==> 编译 ($ARCH)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc \
  -O -parse-as-library \
  -target "${ARCH}-apple-macos14.0" \
  -module-cache-path "$BUILD/mc" \
  -framework AppKit -framework SwiftUI \
  -o "$BIN" \
  "$ROOT/src/TokenBar.swift" "$BUILD/BuildConfig.swift"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TokenBar</string>
    <key>CFBundleDisplayName</key><string>TokenBar</string>
    <key>CFBundleIdentifier</key><string>com.lanzhusu.tokenbar</string>
    <key>CFBundleExecutable</key><string>TokenBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>TokenBar</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# --- 图标（可选，由 make-icon.sh 生成）
if [ -f "$ROOT/assets/TokenBar.icns" ]; then
  cp "$ROOT/assets/TokenBar.icns" "$APP/Contents/Resources/TokenBar.icns"
  echo "==> 已嵌入图标"
else
  echo "==> 提示: 没有 assets/TokenBar.icns，可用 scripts/make-icon.sh <图片> 生成"
fi

# --- 本地自用，ad-hoc 签名即可
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "警告: ad-hoc 签名失败，可能需要右键打开"

echo "==> 完成: $APP"
echo "    启动: open '$APP'"
