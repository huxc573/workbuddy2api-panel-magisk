#!/usr/bin/env bash
# 生成「只含本版」的 CHANGELOG-current.md，给模块管理器的更新弹窗用。
#
# 为什么要单版文件：管理器会把 update.json 里 changelog 指向的文件**原样**展示给用户，
# 指整份 CHANGELOG.md 就会看到历史版本和开发笔记。
#
# 内容两段，顺序就是用户在弹窗里看到的顺序：
#   1. 本模块这版做了什么（CHANGELOG.md 里 "## <版本>" 那一段）
#   2. 上游这一版改了什么（上游 release notes 里的 "## What's Changed" 那一串）
# 两段都可能为空，那就只出另一段；都空就退回到一句话，绝不回落成整份文件。
#
# 用法: scripts/ci/changelog-current.sh <版本号> <上游 tag> [源文件] [输出文件]
#   scripts/ci/changelog-current.sh 26.11.04_1 v2026.11.4.1120
#   → 写 CHANGELOG-current.md
# 环境: GH_TOKEN（读上游 release notes 需要；没有就跳过上游那段）
set -euo pipefail

V="${1:?需要模块版本号，如 26.11.04_1}"
UP="${2:-}"
SRC="${3:-CHANGELOG.md}"
OUT="${4:-CHANGELOG-current.md}"
UP_REPO="${WB2A_UPSTREAM_REPO:-misakano7545/workbuddy2api-panel}"
UPVER="${UP#v}"

# ---------- 本模块这版 ----------
# 取 "## <V>" 到下一个 "## " 之间的内容。
# ⚠ 不能只按 $V 精确匹配：CHANGELOG.md 里的版本号是「动手那天」写的（如 26.11.05_1），
#   而 CI 每次跑的 $V 是当场算的序号（26.11.05_2、_3…），两者对不上就会一个字都取不到。
#   所以先按 $V 找，找不到就退回到「第一条 ## 段落」（＝最新那版）。
_pick_self() {  # $1=要匹配的版本号；空 = 直接取第一条
    awk -v want="$1" '
        /^## / {
            h = $0
            sub(/^##[ \t]+/, "", h)
            sub(/[ \t].*$/, "", h)
            if (want == "") { inblk = (n == 0) }
            else            { inblk = (h == want) }
            n++
            if (inblk) next
        }
        inblk { print }
    ' "$SRC" 2>/dev/null || true
}

self_body=$(_pick_self "$V")
if [ -z "$(printf '%s' "$self_body" | tr -d '[:space:]')" ]; then
    self_body=$(_pick_self "")
fi
self_body=$(printf '%s\n' "$self_body" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;};/\n$/ba')

# ---------- 上游这版 ----------
# 上游 release notes 是 GitHub 自动生成的，长这样：
#   ## What's Changed
#   * fix(panel): xxx by @user in https://.../pull/137
#   ...
#   ## New Contributors
#   ...
#   **Full Changelog**: https://.../compare/a...b
# 对用户有用的是第一条列表；"New Contributors" 和 Full Changelog 那一行删掉，
# 每条后面的 " by @xxx in https://..." 也删掉 —— 弹窗里看链接没用，还特别长。
up_body=""
if [ -n "$UP" ] && command -v gh >/dev/null 2>&1; then
    notes=$(gh release view "$UP" -R "$UP_REPO" --json body --jq .body 2>/dev/null || true)
    if [ -n "$notes" ]; then
        up_body=$(printf '%s\n' "$notes" | awk '
            /^## New Contributors/ { stop = 1 }
            /^\*\*Full Changelog\*\*/ { stop = 1 }
            stop { next }
            /^## What.s Changed/ { next }
            /^\* / || /^- / { print }
        ' | sed -e 's/[[:space:]]\+by[[:space:]]\+@[^ ]*[[:space:]]\+in[[:space:]]\+https\{0,1\}:[^ ]*$//' \
              -e 's/[[:space:]]*$//' || true)
    fi
fi

{
    if [ -n "$self_body" ]; then
        printf '%s\n' "$self_body"
    fi

    if [ -n "$up_body" ]; then
        [ -n "$self_body" ] && echo
        printf '**上游 %s 的改动**\n\n' "${UPVER:-新版本}"
        printf '%s\n' "$up_body"
    elif [ -z "$self_body" ]; then
        # 两段都空（CHANGELOG 还没补条目、也读不到上游 notes）
        printf -- '- 运行体升级到上游 `%s`。\n' "${UPVER:-新版本}"
    fi
} > "$OUT"

echo "== 写入 $OUT（本版 ${#self_body} 字节，上游 ${#up_body} 字节）"
cat "$OUT"
