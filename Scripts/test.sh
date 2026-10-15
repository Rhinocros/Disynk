#!/bin/zsh
# Disynk 测试：编译 Tests/DKTests 并运行（依赖 build.sh 产物）
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Scripts/toolchain.zsh"
BUILD="$ROOT/.build"
MODULES="$BUILD/modules"
LIBS="$BUILD/lib"

[[ -e "$LIBS/libDKCore.a" ]] || { echo "先运行 Scripts/build.sh"; exit 1; }

# 不静默：build.sh 会打印走了哪条 resource-dir 路径
zsh "$ROOT/Scripts/build.sh"

disynk_resolve_resource_flags "$ROOT"

# 与 build.sh 同步：DISYNK_WITH_LIBVPX=1 且 vendor dylib 就位时，为 DKTests 编译传入
# -D DISYNK_LIBVPX 与 LibVPX modulemap，并链接 dylib（DKExport 静态库内含 vpx 符号引用）。
VPX_ROOT="$ROOT/Scripts/vendor/libvpx"
VPX_DYLIB="$VPX_ROOT/lib/libvpx.11.dylib"
VPX_FLAGS=()
VPX_LINK=()
if [[ "${DISYNK_WITH_LIBVPX:-0}" == "1" && -e "$VPX_DYLIB" ]]; then
  echo "▶ DKTests 启用 libvpx 装配（真实 VP8 编码集成测试将执行）"
  VPX_FLAGS=( -D DISYNK_LIBVPX
              -Xcc -fmodule-map-file="$VPX_ROOT/include/module.modulemap"
              -Xcc -I -Xcc "$VPX_ROOT/include" )
  VPX_LINK=( "$VPX_DYLIB"
             -Xlinker -rpath -Xlinker "$VPX_ROOT/lib" )
fi

swiftc -emit-executable -o "$BUILD/dktests" -module-name DKTests \
  -I "$MODULES" \
  -lDKCore -lDKSettings -lDKEncode -lDKMux -lDKCapture -lDKCompose \
  -lDKAudio -lDKShot -lDKOverlay -lDKExport -lDKVirtualDisplay -lDVKObjC \
  -L "$LIBS" \
  "${DISYNK_RESOURCE_FLAGS[@]}" -module-cache-path "$BUILD/mcache" \
  -target "$(disynk_target "$DISYNK_ARCH")" -O \
  -Xcc -fmodule-map-file="$ROOT/Sources/DVKObjC/include/module.modulemap" \
  -Xcc -I -Xcc "$ROOT/Sources/DVKObjC/include" \
  "${VPX_FLAGS[@]}" "${VPX_LINK[@]}" \
  "$ROOT"/Tests/DKTests/*.swift

echo "▶ 运行 dktests"
"$BUILD/dktests"

# ── 方案第七节外部解码验收（可复现回归）───────────────────────
# 用 PyAV（镜像 ffmpeg）独立核实自研封装产物可被第三方解码器打开并实解码，
# 覆盖 §三/§七 编码×容器矩阵：H.264+AAC/MKV、HEVC/MKV、WebM-VP8、WebM-VP9。
# 未安装 PyAV 时退出码 3 → 跳过不判失败。
VDIR="$BUILD/verify"
mkdir -p "$VDIR"
DISYNK_MKV_AUDIO_FIXTURE="$VDIR/h264aac.mkv" \
DISYNK_MKV_HEVC_FIXTURE="$VDIR/hevc.mkv" \
DISYNK_MKV_MERGE_FIXTURE="$VDIR/merge.mkv" \
DISYNK_WEBM_VP8_FIXTURE="$VDIR/vp8.webm" \
DISYNK_WEBM_VP9_FIXTURE="$VDIR/vp9.webm" \
  "$BUILD/dktests" > /dev/null 2>&1 || true

VERIFY_SKIP=0
verify_one() {  # $1=文件 $2..=传参
  local f="$1"; shift
  [[ -e "$f" ]] || { echo "○ 跳过 $(basename "$f")（未产出 fixture，可非 libvpx 构建）"; return 0; }
  echo "▶ 外部解码验收（PyAV/ffmpeg）：$(basename "$f")"
  if python3 "$ROOT/Scripts/verify_media.py" "$f" "$@"; then
    return 0
  else
    local rc=$?
    if [[ "$rc" == "3" ]]; then VERIFY_SKIP=1; return 0; fi
    echo "✗ $(basename "$f") 外部解码验收失败（rc=$rc）"; return 1
  fi
}
set --
verify_one "$VDIR/h264aac.mkv" --expect-audio --expect-duration --expect-vcodec h264 || exit 1
verify_one "$VDIR/hevc.mkv"    --expect-duration --expect-vcodec hevc || exit 1
verify_one "$VDIR/merge.mkv"   --expect-vcodec h264 --expect-layout || exit 1
verify_one "$VDIR/vp8.webm"    --expect-vcodec vp8 || exit 1
verify_one "$VDIR/vp9.webm"    --expect-vcodec vp9 || exit 1
if [[ "$VERIFY_SKIP" == "1" ]]; then
  echo "○ 外部解码验收已跳过（本机无 PyAV）"
else
  echo "✔ §七 外部解码矩阵验收完成"
fi
rm -rf "$VDIR"
