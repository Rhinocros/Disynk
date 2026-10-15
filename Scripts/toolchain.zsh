#!/bin/zsh
# Disynk 构建链共享配置（build.sh / test.sh / package.sh / build_libvpx.sh 一律 source 本文件）
#
# 为什么要有这个文件：部署目标、目标架构、resource-dir 修补判定此前散在三个脚本里各抄一份，
# 改一处漏两处（test.sh 就硬编码过 -resource-dir，健康工具链上会直接编译失败）。
# 数值只有这里一份定义。
#
# 可覆盖的环境变量：
#   DISYNK_MIN_MACOS   部署目标，默认 15.0（与 Package.swift 的 .macOS(.v15)、Info.plist 的
#                      LSMinimumSystemVersion 对齐；project.yml 里写的 14 是 XcodeGen 侧的旧值）
#   DISYNK_ARCH        单架构脚本使用的架构，默认本机架构（arm64 runner 上即 arm64）
#   DISYNK_ARCHS       package.sh 产出的架构列表，默认 "$DISYNK_ARCH"（本机保持单架构快循环）
#   DISYNK_BUILD_DIR   产物目录，默认 .build（多架构打包时按架构分目录，避免 .a/.swiftmodule 互踩）
#   DISYNK_CLT         Command Line Tools 路径，默认 /Library/Developer/CommandLineTools

DISYNK_MIN_MACOS="${DISYNK_MIN_MACOS:-15.0}"
DISYNK_ARCH="${DISYNK_ARCH:-$(uname -m)}"
[[ -z "${DISYNK_ARCHS:-}" ]] && DISYNK_ARCHS="$DISYNK_ARCH"
DISYNK_CLT="${DISYNK_CLT:-/Library/Developer/CommandLineTools}"

# 目标三元组：$1=架构
disynk_target() {
  echo "${1:-$DISYNK_ARCH}-apple-macos${DISYNK_MIN_MACOS}"
}

# resource-dir 修补判定
#
# 本机 CLT 缺陷：usr/include/swift 下 module.modulemap 与 bridging.modulemap 重复定义
# SwiftBridging → 任何 import Foundation 的编译失败。健康工具链（CI 的 Xcode/CLT）上
# module.modulemap 是必需的，删掉反而全挂——所以必须按症状判定，而不是无条件修补。
# 两条路径都打日志，否则事后无法判断当时走了哪条。
#
# 结果写入数组 DISYNK_RESOURCE_FLAGS（健康工具链上为空）。
# 参数：$1=仓库根（用于放修补目录）
disynk_resolve_resource_flags() {
  local root="$1"
  local hdr="$DISYNK_CLT/usr/include/swift"
  DISYNK_RESFIX="${DISYNK_RESFIX:-$root/.build/resfix}"
  DISYNK_RESOURCE_FLAGS=()
  if [[ -e "$hdr/module.modulemap" && -e "$hdr/bridging.modulemap" ]]; then
    if [[ ! -e "$DISYNK_RESFIX/.patched" ]]; then
      rm -rf "$DISYNK_RESFIX"
      mkdir -p "$DISYNK_RESFIX/include" "$(dirname "$DISYNK_RESFIX")"
      cp -R "$DISYNK_CLT/usr/include/swift" "$DISYNK_RESFIX/include-swift"
      rm -f "$DISYNK_RESFIX/include-swift/module.modulemap"  # 保留 bridging.modulemap
      ln -sfn "$DISYNK_RESFIX/include-swift" "$DISYNK_RESFIX/include"
      local f
      for f in "$DISYNK_CLT"/usr/lib/swift/*; do
        [[ "$(basename "$f")" == "include" ]] && continue
        ln -sfn "$f" "$DISYNK_RESFIX/$(basename "$f")"
      done
      touch "$DISYNK_RESFIX/.patched"
    fi
    DISYNK_RESOURCE_FLAGS=( -resource-dir "$DISYNK_RESFIX" )
    echo "➤ 检测到 CLT 重复 SwiftBridging 定义 → 启用 resource-dir 修补：$DISYNK_RESFIX"
  else
    echo "➤ 未检测到 CLT 重复 modulemap（健康工具链）→ 不注入 -resource-dir"
  fi
}

# 架构列表展开（供 for 循环用；保持 bash/zsh 都能跑）
disynk_arch_list() {
  echo "$DISYNK_ARCHS"
}
