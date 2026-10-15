#!/bin/zsh
# libvpx 装配产物构建（WebM VP8/VP9 软编）—— 产出 package.sh / build.sh 期望的那个 dylib
#
# 仓库里只有手写 shim 头（include/libvpx_shim.h + module.modulemap），dylib 不入库：
# Scripts/build.sh 检测到 Scripts/vendor/libvpx/lib/libvpx.11.dylib 才展开 -D DISYNK_LIBVPX 并链接。
# 本脚本按 DISYNK_ARCHS（默认本机架构，CI 传 "arm64 x86_64"）逐架构编译上游，再 lipo 成通用 dylib，
# 并把 install-name 改写为 @rpath/libvpx.11.dylib（package.sh 会拷进 .app/Contents/Frameworks）。
#
# 事实依据（不是猜的）：
#   • 上游 Darwin shared 产物名 = libvpx.$(SO_VERSION_MAJOR).dylib，1.15.2 里 SO_VERSION_MAJOR=11
#   • Darwin shared 用 -Wl,-exported_symbols_list,libvpx.syms 限制导出，符号表由
#     vpx/exports_com + vpx/exports_enc + vp8/exports_enc + vp9/exports_enc 拼出，
#     所以校验对象必须是 shim 头真正声明的那批函数（iface 走 vpx_codec_vp8_cx()/vp9_cx()，
#     公开的 vpx_codec_control 只是头里的 static inline 包装，不进导出表——上一轮 CI 就是
#     在这里把 vpx_codec_control 当成必需符号而误判失败）
#   • x86_64 目标名必须带 darwin 版本号（x86_64-darwin-gcc 在上游 all_platforms 里不存在），
#     且 x86 汇编需要 nasm 或 yasm，二者皆无时上游 configure 直接 die
#
# 可覆盖：LIBVPX_VERSION（默认 1.15.2，对应 shim 的 ABI 37 假设）、LIBVPX_WORK、DISYNK_ARCHS
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Scripts/toolchain.zsh"
VENDOR="$ROOT/Scripts/vendor/libvpx"
OUT="$VENDOR/lib/libvpx.11.dylib"
SHIM="$VENDOR/include/libvpx_shim.h"
LIBVPX_VERSION="${LIBVPX_VERSION:-1.15.2}"
WORK="${LIBVPX_WORK:-$ROOT/.build/libvpx-src}"
# Darwin 主版本对应 macOS 15（部署目标取 toolchain.zsh 的 DISYNK_MIN_MACOS）
DARWIN_SUFFIX=24

[[ -e "$SHIM" ]] || { echo "✗ 找不到 shim：$SHIM"; exit 1; }

# 必需符号＝shim 头里声明的函数（按 ; 分块取括号前的最后一个标识符），不再手抄清单
REQUIRED="$(awk 'BEGIN{RS=";"} {
  if ($0 ~ /typedef|define|inline|\{|\}/) next
  if ($0 !~ /\(/) next
  line=$0; sub(/\(.*/,"",line)
  gsub(/[ \t\n\r*]/," ",line)
  n=split(line,parts," ")
  name=parts[n]
  if (name ~ /^(vpx|vp8|vp9)[a-zA-Z0-9_]*$/) print name
}' "$SHIM" | sort -u)"
[[ -n "$REQUIRED" ]] || { echo "✗ 没能从 $SHIM 解析出函数声明"; exit 1; }
echo "➤ shim 声明的 libvpx 符号 $(echo "$REQUIRED" | grep -c .) 个，作为产物校验清单"

SRC="$WORK/libvpx-$LIBVPX_VERSION"
rm -rf "$WORK"; mkdir -p "$WORK"
TARBALL="$WORK/libvpx.tar.gz"
echo "➤ 拉取 libvpx v$LIBVPX_VERSION"
curl -fsSL --retry 3 -o "$TARBALL" \
  "https://github.com/webmproject/libvpx/archive/refs/tags/v$LIBVPX_VERSION.tar.gz"
tar xzf "$TARBALL" -C "$WORK"
[[ -d "$SRC" ]] || { echo "✗ 解包后找不到 $SRC"; exit 1; }

# x86 汇编器：runner 镜像里未必带 yasm/nasm，缺则装（brew 的 nasm 是正式版，不是 Apple 的 0.98 桩）
if echo "$DISYNK_ARCHS" | tr ' ' '\n' | grep -qxE 'x86_64|i386'; then
  if ! command -v nasm >/dev/null 2>&1 && ! command -v yasm >/dev/null 2>&1; then
    echo "➤ 未找到 nasm/yasm，尝试 brew install nasm"
    brew install nasm || { echo "✗ nasm 安装失败，x86_64 切片需要它（上游 configure 无汇编器即 die）"; exit 1; }
  fi
  echo "✔ 汇编器：$(command -v nasm || command -v yasm)"
fi

# 逐架构编译
SLICES="$WORK/slices.txt"
: > "$SLICES"
while IFS= read -r ARCH; do
  [[ -n "$ARCH" ]] || continue
  TGT="${ARCH}-darwin${DARWIN_SUFFIX}-gcc"
  echo "══════ libvpx 架构 $ARCH（target $TGT）══════"
  BDIR="$WORK/build-$ARCH"
  rm -rf "$BDIR"; mkdir -p "$BDIR"
  ( cd "$BDIR"
    "$SRC/configure" \
      --target="$TGT" \
      --prefix="$WORK/prefix" \
      --enable-shared --disable-static \
      --enable-pic \
      --enable-vp8 --enable-vp9 --enable-vp9-highbitdepth \
      --disable-examples --disable-tools --disable-docs --disable-unit-tests \
      > "$WORK/configure-$ARCH.log" 2>&1 || {
        echo "✗ configure 失败（$ARCH），日志尾部："; tail -25 "$WORK/configure-$ARCH.log"; exit 1; }
    make -j"$(sysctl -n hw.ncpu)" > "$WORK/make-$ARCH.log" 2>&1 || {
      echo "✗ make 失败（$ARCH），日志尾部："; tail -25 "$WORK/make-$ARCH.log"; exit 1; }
    FOUND="$(find "$BDIR" -maxdepth 2 -name 'libvpx*.dylib' ! -name '*dSYM*' | head -1)"
    [[ -n "$FOUND" ]] || { echo "✗ 构建完没找到 dylib，日志尾部："; tail -25 "$WORK/make-$ARCH.log"; exit 1; }
    echo "$FOUND" >> "$SLICES"
  ) || exit 1
  echo "✔ $ARCH 切片：$(tail -1 "$SLICES")"
done <<< "$(echo "$DISYNK_ARCHS" | tr ' ' '\n')"

COUNT="$(grep -c . "$SLICES" || true)"
[[ "$COUNT" -ge 1 ]] || { echo "✗ 没有产出任何切片（DISYNK_ARCHS=$DISYNK_ARCHS）"; exit 1; }

mkdir -p "$VENDOR/lib"
if [[ "$COUNT" == "1" ]]; then
  cp -f "$(head -1 "$SLICES")" "$OUT"
else
  xargs lipo -create -output "$OUT" < "$SLICES"
fi
chmod u+w "$OUT"
install_name_tool -id "@rpath/libvpx.11.dylib" "$OUT"

# BSD-3-Clause 要求随产物保留许可原文 → CI 会把它作为 Release 附件
if [[ -e "$SRC/LICENSE" ]]; then
  cp "$SRC/LICENSE" "$VENDOR/LICENSE"
  echo "✔ 上游 LICENSE 已复制到 Scripts/vendor/libvpx/LICENSE"
else
  echo "⚠ 未找到 $SRC/LICENSE，分发前需自行补齐 libvpx 许可原文"
fi

# 逐切片校验导出符号（通用 dylib 必须每个架构都齐全）
# 一律用 while-read 拆行，不用 `for x in $(...)`——zsh 与 bash 对它的分词行为不同，
# 一旦被当成单个词，nm 会拿 "arm64\nx86_64" 当架构名，构建明明成功也会误判失败
FAILED=0
while IFS= read -r ARCH; do
  [[ -n "$ARCH" ]] || continue
  EXPORTS=" $(nm -arch "$ARCH" -gU "$OUT" 2>/dev/null | awk '{print $NF}' | sed 's/^_//' | sort -u | tr '\n' ' ') "
  MISS=""
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    case "$EXPORTS" in *" $s "*) ;; *) MISS="$MISS $s" ;; esac
  done <<< "$REQUIRED"
  if [[ -n "$MISS" ]]; then
    echo "✗ $ARCH 切片缺少符号：$MISS"
    FAILED=1
  else
    echo "✔ $ARCH 切片符号齐全"
  fi
done <<< "$(echo "$DISYNK_ARCHS" | tr ' ' '\n')"
[[ "$FAILED" == "0" ]] || { echo "  多为 LIBVPX_VERSION 与 shim 的 ABI 假设不符（见 libvpx_shim.h 131-139 行）"; rm -f "$OUT"; exit 1; }

echo "✔ 装配就绪：$OUT（切片 $(lipo -archs "$OUT")）"
otool -D "$OUT" | tail -n +2

cat <<'EOF'

下一步：
  zsh Scripts/test.sh      # dylib 就位时 DKTests 的真实 VP8 编码用例
  zsh Scripts/package.sh   # package.sh 自动装配 libvpx 并拷入 .app/Contents/Frameworks
EOF
