#!/bin/zsh
# Disynk 模块化构建脚本（swiftc 直编）
#
# 背景：本机 Command Line Tools 安装存在两处缺陷——
#   1. libPackageDescription.dylib 缺失清单 init 符号 → SwiftPM `swift build` 不可用
#   2. usr/include/swift 下 module.modulemap 与 bridging.modulemap 重复定义
#      SwiftBridging → 任何 import Foundation 的编译失败
# 对策：用 -resource-dir 指向修补后的伪资源目录（剔除重复 modulemap 的副本）。
# Package.swift 保留为工程事实源，待 CLT/Xcode 修复后 `swift build` 可直接接管。

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Scripts/toolchain.zsh"
BUILD="${DISYNK_BUILD_DIR:-$ROOT/.build}"
MODULES="$BUILD/modules"
LIBS="$BUILD/lib"
TARGET="$(disynk_target "$DISYNK_ARCH")"

mkdir -p "$MODULES" "$LIBS" "$BUILD/mcache"

# ---- resource-dir 修补（按症状判定，判定逻辑只在 toolchain.zsh 里一份） ----
disynk_resolve_resource_flags "$ROOT"
echo "➤ 架构 $DISYNK_ARCH · 目标 $TARGET · 产物目录 $BUILD"

COMMON=( "${DISYNK_RESOURCE_FLAGS[@]}" -module-cache-path "$BUILD/mcache"
         -target "$TARGET" -O )

# ---- libvpx 可选装配（WebM VP8/VP9 软编） ----
# 存在 vendor dylib 且置 DISYNK_WITH_LIBVPX=1 时：
#   • 为所有模块追加 `-D DISYNK_LIBVPX` 与 LibVPX clang modulemap include
#     （仅 DKExport/DisynkApp 实际使用；其他模块无副作用）
#   • 可执行链接时直接给定 dylib 绝对路径（Swift 无 -lvpx.11 支持）+ 两条 rpath
#     开发 rpath 为绝对路径，打包后 package.sh 会拷入 .app/Contents/Frameworks 并以 @executable_path 解析
VPX_ROOT="$ROOT/Scripts/vendor/libvpx"
VPX_DYLIB="$VPX_ROOT/lib/libvpx.11.dylib"
VPX_ENABLED=0
if [[ "${DISYNK_WITH_LIBVPX:-0}" == "1" && -e "$VPX_DYLIB" ]]; then
  echo "➤ 启用 libvpx 装配（VP8/VP9 WebM 软编）"
  COMMON+=( -D DISYNK_LIBVPX
            -Xcc -fmodule-map-file="$VPX_ROOT/include/module.modulemap"
            -Xcc -I -Xcc "$VPX_ROOT/include" )
  VPX_ENABLED=1
fi

# 模块依赖表（顺序即编译顺序）
typeset -A DEPS
DEPS=(
  DKCore          ""
  DKSettings      "DKCore"
  DKEncode        "DKCore"
  DKMux           "DKCore DKEncode"
  DKCapture       "DKCore DKSettings"
  DKCompose       "DKCore"
  DKAudio         "DKCore DKSettings"
  DKShot          "DKCore DKCapture DKSettings"
  DKOverlay       "DKCore DKSettings"
  DKExport        "DKCore DKMux"
  DKVirtualDisplay "DKCore DVKObjC"
)
ORDER=(DKCore DKSettings DKEncode DKMux DKCapture DKCompose DKAudio DKShot DKOverlay DKExport DKVirtualDisplay)

compile_module() {
  local m="$1"
  # DVKObjC 为 C/ObjC 目标，单独处理
  if [[ "$m" == "DVKObjC" ]]; then
    mkdir -p "$BUILD/dvkobjc"
    for f in "$ROOT"/Sources/DVKObjC/*.m; do
      clang -c "$f" -o "$BUILD/dvkobjc/$(basename $f .m).o" \
        -fmodules -fmodule-map-file="$ROOT/Sources/DVKObjC/include/module.modulemap" \
        -I "$ROOT/Sources/DVKObjC/include" -target "$TARGET"
    done
    libtool -static -o "$LIBS/libDVKObjC.a" "$BUILD"/dvkobjc/*.o
    # 生成 swiftmodule 占位（供 -I 检索 import 语法？不需要：Clang 模块经 modulemap 暴露）
    return
  fi

  local files=("$ROOT"/Sources/$m/*.swift)
  [[ ${#files[@]} -eq 0 || ! -e ${files[1]} ]] && { echo "skip $m (无源文件)"; return; }

  local linkflags=()
  local cflags=()
  for d in ${=DEPS[$m]}; do
    linkflags+=( -l$d )
    if [[ "$d" == "DVKObjC" ]]; then
      # 导入 ObjC 桥接：经 modulemap 暴露为 clang 模块
      cflags+=( -Xcc -fmodule-map-file="$ROOT/Sources/DVKObjC/include/module.modulemap"
                -Xcc -I -Xcc "$ROOT/Sources/DVKObjC/include" )
    fi
  done

  echo "➤ $m"
  swiftc -emit-module -emit-module-path "$MODULES/$m.swiftmodule" \
    -emit-library -static -o "$LIBS/lib$m.a" \
    -module-name "$m" \
    -I "$MODULES" "${linkflags[@]}" -L "$LIBS" \
    "${COMMON[@]}" "${cflags[@]}" "${files[@]}"
}

# Clang 模块（DKVirtualDisplay 依赖的 ObjC 桥接）
compile_module DVKObjC
for m in "${ORDER[@]}"; do
  compile_module "$m"
done

# ---- App 可执行 ----
echo "➤ Disynk (executable)"
EXE_LINK=()
for m in "${ORDER[@]}"; do EXE_LINK+=( -l$m ); done
EXE_LINK+=( -lDVKObjC )

# WebM/libvpx 可选装配：已在 COMMON 中展开 -D + modulemap，此处仅处理 dylib 链接与 rpath
VPX_LINK=()
if [[ "$VPX_ENABLED" == "1" ]]; then
  VPX_LINK+=( "$VPX_DYLIB"
              -Xlinker -rpath -Xlinker "$VPX_ROOT/lib"
              -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' )
fi

swiftc -emit-executable -o "$BUILD/Disynk" -module-name Disynk \
  -I "$MODULES" "${EXE_LINK[@]}" -L "$LIBS" \
  "${COMMON[@]}" \
  -Xcc -fmodule-map-file="$ROOT/Sources/DVKObjC/include/module.modulemap" \
  -Xcc -I -Xcc "$ROOT/Sources/DVKObjC/include" \
  "${VPX_LINK[@]}" \
  "$ROOT"/Sources/DisynkApp/*.swift

echo "✔ 构建完成: $BUILD/Disynk"
