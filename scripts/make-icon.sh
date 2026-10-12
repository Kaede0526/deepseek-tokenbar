#!/bin/bash
# make-icon.sh — 把任意图片转成 App 图标 assets/TokenBar.icns
#
# 用法: scripts/make-icon.sh <图片路径> [裁切位置%]
#   裁切位置% : 长边裁成正方形时从哪里取。0=贴顶/贴左，50=居中(默认)，100=贴底/贴右
#
# 支持 png / jpg / webp / heic 等（先经 sips 解码，再交给 Pillow 缩放）

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
SRC="${1:-}"
ANCHOR="${2:-50}"

[ -n "$SRC" ] || { echo "用法: scripts/make-icon.sh <图片路径> [裁切位置%]" >&2; exit 1; }
[ -f "$SRC" ] || { echo "错误: 找不到 $SRC" >&2; exit 1; }

PY="${TOKENBAR_PYTHON:-}"
if [ -z "$PY" ]; then
  for cand in /opt/homebrew/bin/python3 /usr/local/bin/python3 "$(command -v python3 || true)"; do
    if [ -n "$cand" ] && [ -x "$cand" ] && "$cand" -c "import PIL" >/dev/null 2>&1; then PY="$cand"; break; fi
  done
fi
[ -n "$PY" ] || { echo "错误: 需要一个带 Pillow 的 python3（pip install pillow）" >&2; exit 1; }

mkdir -p "$ROOT/assets" "$ROOT/.build"
WORK="$ROOT/.build/icon"
rm -rf "$WORK" && mkdir -p "$WORK"

# webp/heic 等先统一转成 png，保证 Pillow 一定能读
sips -s format png "$SRC" --out "$WORK/src.png" >/dev/null 2>&1 \
  || { echo "错误: 无法解码图片 $SRC" >&2; exit 1; }

"$PY" - "$WORK/src.png" "$WORK/master.png" "$WORK/icon.iconset" "$ANCHOR" <<'PYEOF'
import sys, os
from PIL import Image

src, dst, iconset, anchor = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
im = Image.open(src).convert("RGBA")
w, h = im.size
side = min(w, h)

if w != h:
    # 裁成正方形。anchor 决定从长边的哪一处开始取：0=贴顶/贴左，100=贴底/贴右
    extra = (h if h > w else w) - side
    off = int(extra * anchor / 100.0)
    box = (0, off, w, off + side) if h > w else (off, 0, off + side, h)
    im = im.crop(box)
    print(f"  裁切 {w}x{h} → {side}x{side} (偏移 {off}px, anchor={anchor}%)")

im = im.resize((1024, 1024), Image.LANCZOS)
im.save(dst, "PNG")

# macOS 图标需要的全部尺寸
os.makedirs(iconset, exist_ok=True)
for base, scale in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]:
    suffix = "" if scale == 1 else "@2x"
    im.resize((base * scale, base * scale), Image.LANCZOS).save(
        os.path.join(iconset, f"icon_{base}x{base}{suffix}.png"), "PNG")
print("  生成 10 个尺寸")
PYEOF

iconutil -c icns "$WORK/icon.iconset" -o "$ROOT/assets/TokenBar.icns"
echo "==> 图标已生成: $ROOT/assets/TokenBar.icns"
echo "    重新运行 scripts/install.sh 生效"
