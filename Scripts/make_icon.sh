#!/bin/zsh
# 生成 Disynk 图标资源（Cv6_SymSlant 彩色 App 图标 .icns + 从 logo/menubar 拷贝的单色菜单栏 template 图标）。
# 复用 build.sh 修补后的 resource-dir（本机 CLT 的 module.modulemap 重复定义问题）。
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build"
RESFIX="$BUILD/resfix"
[[ -e "$RESFIX/.patched" ]] || { echo "✗ 请先运行 build.sh 生成修补后的 resource-dir"; exit 1; }

echo "➤ 编译图标生成器"
swiftc -O -resource-dir "$RESFIX" -module-cache-path "$BUILD/mcache" \
  -target arm64-apple-macos15.0 \
  "$ROOT/Scripts/make_icon.swift" -o "$BUILD/make_icon"

echo "➤ 生成 PNG 资源"
"$BUILD/make_icon" "$ROOT"

echo "➤ 合成 AppIcon.icns"
iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"

echo "✔ 图标资源完成：Resources/AppIcon.icns, MenuBarIcon.png/@2x.png"
