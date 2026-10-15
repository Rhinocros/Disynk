#!/bin/zsh
# 把「程序本体的发布快照」推到 GitHub。
#
# 模型：GitHub 上不存在开发历史，只有一条由快照提交串成的 main。
#   每次运行用 read-tree / write-tree / commit-tree 造一个提交：
#     树 ＝ 本地 $SRC_REF 的树剔掉 EXCLUDE_PATHS
#     父 ＝ 远端 main 的当前头（首次或 RESET=1 时无父，即干净基线）
#   于是公开仓库的历史只有「快照 1 → 快照 2 → …」：开发历史、演示站点、以及被剔除目录的
#   任何旧版本都进不去，也不必用 filter-repo 改写本地分支（本地 master 与群晖 origin 不动）。
#
#   zsh Scripts/publish-github.sh              # 快照接到远端 main 之后，推 v<版本> 标签
#   RESET=1 zsh Scripts/publish-github.sh      # 丢弃远端已有历史，重建为单提交基线（force-push main）
#   PURGE_TAGS=1 ...                           # 先删远端全部旧标签（废弃/失败版本用）
#   DRY_RUN=1 ...                              # 只造快照并自检，不推送
#   TAGS_PUSH=0 ...                            # 只推 main，不动标签
#
# 版本号取自 Resources/Info.plist（事实源），标签名 v<版本>；发别的版本先改 plist 再跑。
# 语法保持 bash/zsh 通吃（本机只能 bash 干跑，macOS 上用 zsh 执行）。
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE="${1:-github.com}"
SRC_REF="${2:-master}"
PUSH_BRANCH="${PUSH_BRANCH:-main}"
EXCLUDE_PATHS=("${EXCLUDE_PATHS:-website}")
STATE="$ROOT/.build/github-publish"

REMOTE_URL="$(git -C "$ROOT" remote get-url "$REMOTE" 2>/dev/null || true)"
[[ -n "$REMOTE_URL" ]] || { echo "✗ 没有名为 $REMOTE 的远端"; exit 1; }
git -C "$ROOT" rev-parse --verify --quiet "$SRC_REF" >/dev/null || { echo "✗ 本地引用 $SRC_REF 不存在"; exit 1; }

# 版本事实源是 Info.plist；plutil 只在 macOS 有，取不到时退回按 XML 结构解析（别让本机干跑拿到错版本）
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist" 2>/dev/null || true)"
if [[ -z "$VERSION" ]]; then
  VERSION="$(grep -A1 '<key>CFBundleShortVersionString</key>' "$ROOT/Resources/Info.plist" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1 || true)"
fi
[[ -n "$VERSION" ]] || { echo "✗ 解析不出版本号（Info.plist 缺 CFBundleShortVersionString）"; exit 1; }
TAG="v$VERSION"

# ── 前置自检 ────────────────────────────────────────────────
# 被剔除目录不能出现在构建/运行链上；*.md 提到路径名不算（不影响构建），本脚本注释里也有该词
PAT=""
for p in "${EXCLUDE_PATHS[@]}"; do PAT="${PAT:+$PAT|}$p/"; done
PAT="($PAT)"
BAD="$(git -C "$ROOT" grep -lE "$PAT" "$SRC_REF" -- Sources Scripts Tests Resources docs .github Package.swift project.yml \
  ':(exclude,glob)**/*.md' ':(exclude)Scripts/publish-github.sh' || true)"
if [[ -n "$BAD" ]]; then
  echo "✗ 以下文件引用了 ${EXCLUDE_PATHS}，剔除后产物不完整，先解耦再发布："
  echo "$BAD" | sed 's/^/    /'
  exit 1
fi

# ── 造快照提交（纯 plumbing，不碰任何工作树） ────────────────
echo "➤ 造发布快照 $TAG（源 $SRC_REF，剔除 ${EXCLUDE_PATHS}）"
rm -rf "$STATE"; mkdir -p "$STATE"
export GIT_INDEX_FILE="$STATE/index.tmp"
git -C "$ROOT" read-tree "$SRC_REF"
for p in "${EXCLUDE_PATHS[@]}"; do
  git -C "$ROOT" rm -r -q --cached --ignore-unmatch -- "$p" >/dev/null
done
TREE="$(git -C "$ROOT" write-tree)"
REMOTE_TIP="$(git ls-remote "$REMOTE_URL" "refs/heads/$PUSH_BRANCH" | awk '{print $1}')"
PARENT=()
if [[ -n "$REMOTE_TIP" && "${RESET:-0}" != "1" ]]; then
  PARENT=( -p "$REMOTE_TIP" )
  echo "➤ 父提交＝远端快照头 ${REMOTE_TIP:0:7}（可 fast-forward）"
else
  echo "➤ 无父提交：单提交基线${REMOTE_TIP:+，将 force-push 覆盖 ${REMOTE_TIP:0:7}}"
fi
COMMIT="$(printf 'release %s —— Disynk 发布快照（源码自本地 %s）\n' "$TAG" \
  "$(git -C "$ROOT" rev-parse --short "$SRC_REF")" | git -C "$ROOT" commit-tree "$TREE" "${PARENT[@]}")"
echo "✔ 快照提交 $COMMIT"

# 树内容自检：不含被剔除路径、不含已废弃模块、必需文件齐备
LIST="$(git -C "$ROOT" ls-tree -r --name-only "$COMMIT")"
LEFT="$(echo "$LIST" | grep -E "^$PAT" || true)"
[[ -z "$LEFT" ]] || { echo "✗ 快照仍含 $LEFT"; exit 1; }
DEAD="$(echo "$LIST" | grep -E '^Sources/DKLicense/' || true)"
[[ -z "$DEAD" ]] || { echo "✗ 快照仍含已废弃的授权模块：$DEAD"; exit 1; }
for f in .github/workflows/release.yml Scripts/toolchain.zsh Scripts/build.sh Scripts/package.sh \
         Scripts/build_libvpx.sh Package.swift README.md README.zh-CN.md LICENSE \
         ADDITIONAL-TERMS.md THIRD-PARTY-NOTICES.md; do
  echo "$LIST" | grep -qx "$f" || { echo "✗ 快照缺 $f（本地是否已提交？）"; exit 1; }
done
echo "✔ 快照含 $(echo "$LIST" | grep -c .) 个文件，无 ${EXCLUDE_PATHS}、无 DKLicense"
unset GIT_INDEX_FILE

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "ℹ DRY_RUN=1，未推送（快照对象已在本地库，可 git show $COMMIT 查看）"
  exit 0
fi

# ── 推送 ────────────────────────────────────────────────────
FORCE=()
[[ -n "$REMOTE_TIP" && "${RESET:-0}" == "1" ]] && FORCE+=(--force)
echo "➤ 推 $PUSH_BRANCH"
git push "${FORCE[@]}" "$REMOTE_URL" "$COMMIT:refs/heads/$PUSH_BRANCH"

if [[ "${PURGE_TAGS:-0}" == "1" ]]; then
  echo "➤ 删除远端全部旧标签"
  # 只删真实标签引用：^{} 是 ls-remote 附带的「剥皮」条目，不是合法 refspec，
  # 混进批次会让整批 push 直接 fatal 失败（上一版就是这样几乎没删掉）
  git ls-remote "$REMOTE_URL" 'refs/tags/*' | cut -f2 \
    | grep -v -F '^{}' | grep -v -x "refs/tags/$TAG" \
    | sed 's|^|--delete |' | paste -sd" " - > "$STATE/tags.txt"
  N="$(wc -w < "$STATE/tags.txt" | tr -d ' ')"
  if [[ "$N" -gt 0 ]]; then
    xargs -n 30 git push "$REMOTE_URL" < "$STATE/tags.txt" || echo "  ○ 部分批次失败"
    echo "✔ 已尝试删除 $((N / 2)) 个标签"
  fi
  echo "  注意：标签删掉后，挂在其上的 Release 会变成草稿，需在网页端手动删除"
fi

if [[ "${TAGS_PUSH:-1}" == "1" ]]; then
  echo "➤ 推标签 $TAG → ${COMMIT:0:7}"
  git push "${FORCE[@]}" "$REMOTE_URL" "$COMMIT:refs/tags/$TAG"
fi

cat <<EOF
✔ 发布完成：$REMOTE_URL 的 $PUSH_BRANCH 已指向快照 ${COMMIT:0:7}（$TAG）
  · GitHub 侧历史只有发布快照，开发历史不进公开仓库
  · CI 由标签推送触发；树里没有 .github/workflows 的旧标签不会构建
EOF
