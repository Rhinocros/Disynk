#!/bin/zsh
# Disynk 打包脚本（方案 M7 双分发路径，同一套代码零改动，环境变量切换）
#
#   路径 A（默认，零成本个人网站直发）：
#     zsh Scripts/package.sh
#     → ad-hoc 签名 + dmg，不含公证；首次运行需用户过 Gatekeeper：
#       xattr -cr /Applications/Disynk.app  或 系统设置→隐私与安全性→「仍要允许」
#     已知代价：每次重编译 cdhash 变化 → 屏幕录制(TCC)授权需重授，
#       应用内「引导重新授权」流程给出 tccutil 提示与隐私面板直达。
#
#   路径 B（正式收费前，Developer ID + 公证 + staple）：
#     DISYNK_SIGN_IDENTITY="Developer ID Application: XXX (TEAMID)" \
#     DISYNK_NOTARY_PROFILE=disynk zsh Scripts/package.sh
#     → 双击即开，TCC 授权随版本更新保持（签名身份稳定）。
#
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Scripts/toolchain.zsh"
BUILD="$ROOT/.build"
APP_NAME="Disynk"
# 版本号优先级：环境变量 DISYNK_VERSION > Resources/Info.plist（项目版本事实源）> 最近 git tag > 0.1.0
# 避开打包产物永远停在默认 0.1.0（与实际代码版本不一致）。
plist_ver="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist" 2>/dev/null || true)"
git_ver="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
git_ver="${git_ver#v}"
VERSION="${DISYNK_VERSION:-${plist_ver:-${git_ver:-0.1.0}}}"
IDENTITY="${DISYNK_SIGN_IDENTITY:--}"     # "-" = ad-hoc（路径 A）
OUT="$BUILD/dist"

# 1. 构建（复用现有 swiftc 直编链，按 DISYNK_ARCHS 逐架构产出再 lipo）
# WebM/libvpx：vendor 已就位时默认装配（DISYNK_WITH_LIBVPX=0 可显式关闭）；
# 不装配则打包产物里选 WebM 产出会因缺 VP8 编码器而失败。
VPX_DYLIB="$ROOT/Scripts/vendor/libvpx/lib/libvpx.11.dylib"
if [[ -e "$VPX_DYLIB" ]]; then
  export DISYNK_WITH_LIBVPX="${DISYNK_WITH_LIBVPX:-1}"
fi

# 逐架构编译：每个架构独立产物目录，避免 .a / .swiftmodule 互踩
# 切片路径逐行记到 slices.txt（用文件而非数组，避开 zsh/bash 下标差异）
SLICES="$BUILD/slices.txt"
: > "$SLICES"
while IFS= read -r ARCH; do
  [[ -n "$ARCH" ]] || continue
  BDIR="$BUILD/$ARCH"
  echo "══════ 架构 $ARCH ══════"
  DISYNK_ARCH="$ARCH" DISYNK_BUILD_DIR="$BDIR" zsh "$ROOT/Scripts/build.sh"
  [[ -e "$BDIR/$APP_NAME" ]] || { echo "✗ $BDIR/$APP_NAME 未产出"; exit 1; }
  # 装配了 libvpx 就要确认 dylib 含本架构切片，否则链接/运行期才炸
  if [[ "${DISYNK_WITH_LIBVPX:-0}" == "1" && -e "$VPX_DYLIB" ]]; then
    lipo -archs "$VPX_DYLIB" | tr ' ' '\n' | grep -qx "$ARCH" || {
      echo "✗ libvpx.11.dylib 不含 $ARCH 切片（现有：$(lipo -archs "$VPX_DYLIB")）"
      echo "  重跑 zsh Scripts/build_libvpx.sh 以产出通用 dylib，或置 DISYNK_WITH_LIBVPX=0"
      exit 1
    }
  fi
  echo "$BDIR/$APP_NAME" >> "$SLICES"
done <<< "$(echo "$DISYNK_ARCHS" | tr ' ' '\n')"

COUNT="$(grep -c . "$SLICES" || true)"
[[ "$COUNT" -ge 1 ]] || { echo "✗ DISYNK_ARCHS 为空（$DISYNK_ARCHS）"; exit 1; }
if [[ "$COUNT" == "1" ]]; then
  cp -f "$(head -1 "$SLICES")" "$BUILD/$APP_NAME"
else
  xargs lipo -create -output "$BUILD/$APP_NAME" < "$SLICES"
fi
echo "✔ 可执行架构切片：$(lipo -archs "$BUILD/$APP_NAME")"

# 2. 组装 .app bundle
echo "➤ 打包版本：$VERSION"
STAGE="$OUT/$APP_NAME.app"
rm -rf "$OUT"; mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$STAGE/Contents/Frameworks"
cp "$BUILD/$APP_NAME" "$STAGE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$STAGE/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$VERSION" "$STAGE/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$(date +%Y%m%d%H%M)" "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

# 2a. 图标资源：彩色 AppIcon.icns（Dock/Finder/⌘Tab）+ 单色 MenuBarIcon（状态栏 template）
#     两者由 Scripts/make_icon.sh 产出：App 图标按 Cv6_SymSlant 矢量原生重绘，
#     菜单栏 template 图直接从 logo/menubar 拷贝（纯黑+alpha）。
for icon_res in AppIcon.icns MenuBarIcon.png "MenuBarIcon@2x.png"; do
  if [[ -e "$ROOT/Resources/$icon_res" ]]; then
    cp "$ROOT/Resources/$icon_res" "$STAGE/Contents/Resources/$icon_res"
  else
    echo "✗ 缺少 Resources/$icon_res，请先运行 zsh Scripts/make_icon.sh"
    exit 1
  fi
done
# 图标改动后刷新 Launch Services 缓存，避免 Dock 仍显示旧图标
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$STAGE" || true

# 2b. 将 vendor libvpx 拷入 Frameworks（可执行 rpath 已包含 @executable_path/../Frameworks）
HAVE_VPX=0
if [[ "${DISYNK_WITH_LIBVPX:-0}" == "1" && -e "$VPX_DYLIB" ]]; then
  cp "$VPX_DYLIB" "$STAGE/Contents/Frameworks/libvpx.11.dylib"
  chmod u+w "$STAGE/Contents/Frameworks/libvpx.11.dylib"
  HAVE_VPX=1
  echo "✔ libvpx 已拷入 .app/Contents/Frameworks"
fi

# 3. 签名（entitlements 按路径区分；hardened runtime 仅路径 B）
# 先内后外：Framework dylib 先签 → 再签整个 app 时其 CodeResources 包含 dylib cdhash。
if [[ "$HAVE_VPX" == "1" ]]; then
  codesign --force --sign "$IDENTITY" --timestamp=none "$STAGE/Contents/Frameworks/libvpx.11.dylib"
fi
if [[ "$IDENTITY" == "-" ]]; then
  ENT="$ROOT/Resources/Disynk.entitlements"
  codesign --force --sign - --timestamp=none --entitlements "$ENT" "$STAGE"
  echo "✔ ad-hoc 签名（路径 A）"
else
  ENT="$ROOT/Resources/Disynk.hardened.entitlements"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" --entitlements "$ENT" "$STAGE"
  echo "✔ Developer ID + hardened runtime（路径 B）"
fi

# 4. dmg
DMG="$OUT/$APP_NAME-$VERSION.dmg"
hdiutil create -volname "$APP_NAME" -srcdir "$OUT" -ov -format UDZO "$DMG" > /dev/null
if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi

# 5. 公证 + staple（仅路径 B；需 xcrun notarytool store-credentials 预置 profile）
if [[ "$IDENTITY" != "-" && -n "${DISYNK_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$DISYNK_NOTARY_PROFILE" --wait
  xcrun stapler staple "$STAGE"
  xcrun stapler staple "$DMG"
  echo "✔ 公证与 staple 完成"
fi

echo "产物：$DMG"
if [[ "$IDENTITY" == "-" ]]; then
  cat <<'EOF'

── 路径 A 安装指引（发给用户）──────────────────────────
1. 双击 dmg，把 Disynk.app 拖入「应用程序」
2. 首次运行若被 Gatekeeper 拦截，终端执行：
     xattr -cr /Applications/Disynk.app
   或打开「系统设置 → 隐私与安全性」，拉到底点「仍要允许」
3. 每次应用更新后，屏幕录制权限需要重新勾选
   （可到「系统设置 → 隐私与安全性 → 屏幕录制」重新勾选 Disynk）
────────────────────────────────────────────────────
EOF
fi
