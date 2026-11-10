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
# 用法: scripts/ci/changelog-current.sh <版本号> <上游 tag> [源文件] [输出文件] [已发布条目账本]
#   scripts/ci/changelog-current.sh 26.11.07_2 v2026.11.5.2306
#   → 写 CHANGELOG-current.md，并把本次展示过的条目追加进 .changelog-seen
# 环境: GH_TOKEN（读上游 release notes 需要；没有就跳过上游那段）
set -euo pipefail

V="${1:?需要模块版本号，如 26.11.04_1}"
UP="${2:-}"
SRC="${3:-CHANGELOG.md}"
OUT="${4:-CHANGELOG-current.md}"
SEEN="${5:-.changelog-seen}"
UP_REPO="${WB2A_UPSTREAM_REPO:-misakano7545/workbuddy2api-panel}"
UPVER="${UP#v}"

# ---------- 本模块这版 ----------
# 取 "## <V>" 到下一个 "## " 之间的内容。
# ⚠ 不能只按 $V 精确匹配：CHANGELOG.md 里的版本号是「动手那天」写的（如 26.11.05_1），
#   而 CI 每次跑的 $V 是当场算的序号（26.11.07_2、_3…），两者对不上。
#   所以先按 $V 找；找不到就取「第一条 ## 段落」，再剔掉 `.changelog-seen` 里
#   已经发布过的条目 —— 剩下的才是本版真正的新改动。全被剔掉 ⇒ 本版无模块改动。
#   ⚠ 早期是「无条件取最新一段」，于是每发一个纯升运行体的包，弹窗里都重复贴
#     同一条旧文案（26.11.05_1 / 26.11.07_1 都被反复贴过）。
#   ⚠ 也别用 git 前后对比当判据：CI 自己提交 CHANGELOG-current.md，
#     HEAD 永远比手写 CHANGELOG.md 新，判据必然误判。

# 条目归一化：去掉列表符号/粗体/结尾标点，只留可比较的正文
_norm() {
    printf '%s\n' "$1" | sed -e 's/^[[:space:]]*[-*][[:space:]]*//' \
                            -e 's/\*\*//g' -e 's/[[:space:]]*$//' \
                            -e 's/[。.]$//'
}

# 已发布过的条目（每行一条）
_seen_has() {
    [ -f "$SEEN" ] || return 1
    _k=$(_norm "$1")
    [ -n "$_k" ] || return 1
    grep -Fxq -- "$_k" "$SEEN"
}

# 把本模块段里没发布过的条目挑出来（保留缩进的续行，交给调用方处理）
_fresh() {
    while IFS= read -r _l; do
        case "$_l" in
            ""|" "*) continue ;;      # 空行、缩进续行
        esac
        if _seen_has "$_l"; then continue; fi
        printf '%s\n' "$_l"
    done <<EOF2
$1
EOF2
}

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
# 剔掉已经发布过的条目：一段 CHANGELOG 只在它自己那一版出现一次，
# 后续任何版本（纯升运行体、改 CI、force 重出包）都不再重复贴。
self_body=$(_fresh "$self_body")
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
#
# ⚠ 上游有时（尤其连发几版时）release body 里只有一行 **Full Changelog**，
#   没有 "## What's Changed" —— 照上面的规则筛完就是空，弹窗只剩「本包版本号」。
#   这时从 Full Changelog 里把 `a...b` 抠出来，改用 compare API 取提交列表。
up_body=""
up_link=""
if [ -n "$UP" ] && command -v gh >/dev/null 2>&1; then
    # 每次都从**这一版上游 release 的正文**里现取，不写死任何 tag：
    # 上游连发几版时 body 可能只有一行 **Full Changelog**，链接里的 a...b 也跟着变。
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

    # 顺手把正文里的对比链接抠出来（有就留着，没有就自己按上一版拼）
    _mlink=$(printf '%s\n' "$notes" | sed -n 's|.*\(https://[^ )]*/compare/[^ )]*\).*|\1|p' | head -n1)
    range=$(printf '%s\n' "$_mlink" | sed -n 's|.*/compare/\([^ )]*\)$|\1|p')

    # 兜底：release notes 里没条目 → 用 compare API 拉两次 tag 之间的提交
    if [ -z "$(printf '%s' "$up_body" | tr -d '[:space:]')" ]; then
        if [ -n "$range" ]; then
            up_body=$(gh api "repos/$UP_REPO/compare/$range" \
                        --jq '.commits[] | .commit.message | split("\n")[0]' 2>/dev/null \
                      | awk 'NF' \
                      | sed -e 's/[[:space:]]*$//' -e 's/^/* /' || true)
        fi
    fi
    # 有对比范围就给链接（正文的优先，其次按 range 拼官网地址），纯动态，不写死
    if [ -n "$range" ] && [ -n "$(printf '%s' "$up_body" | tr -d '[:space:]')" ]; then
        up_link="${_mlink:-https://github.com/$UP_REPO/compare/$range}"
    fi
fi

# 本包版本号里已经带了日期和当日序号，这里只补「发布时刻 + 时区」，
# 不再重复日期（26.11.07_2 → 22:56 UTC+8）。
BUILT="$(TZ=Asia/Shanghai date '+%H:%M') UTC+8"

# 先把本版要展示的条目记进账本，再写产物：
# 这样同一版本重复出包（force）时，上一轮已展示过的条目会被 _fresh 剔掉，不会重复贴。
if [ -n "$self_body" ]; then
    _norm_block=$(printf '%s\n' "$self_body" | while IFS= read -r _b; do
        case "$_b" in ""|" "*) continue ;; esac
        _norm "$_b"; echo
    done)
    _norm_block=$(printf '%s\n' "$_norm_block" | grep -v '^$' || true)
    if [ -n "$_norm_block" ]; then
        [ -f "$SEEN" ] || : > "$SEEN"
        printf '%s\n' "$_norm_block" >> "$SEEN"
        sort -u "$SEEN" -o "$SEEN"
    fi
fi

{
    printf '**本模块 %s**　发布于 %s\n' "$V" "$BUILT"

    if [ -n "$self_body" ]; then
        echo
        printf '%s\n' "$self_body"
    fi

    if [ -n "$up_body" ]; then
        echo
        printf '**上游 %s 的改动**\n\n' "${UPVER:-新版本}"
        printf '%s\n' "$up_body"
        # 上游没写 release notes、条目取自提交记录时，附一行完整对比链接：
        # 弹窗里不可点也没关系，用户可以照着敲，或者去 Releases 页看。
        if [ -n "$up_link" ]; then
            printf '\n完整对比：%s\n' "$up_link"
        fi
    elif [ -z "$self_body" ]; then
        # 本模块这版没有新条目、也读不到上游 notes
        echo
        printf -- '- 本版仅更新运行体到上游 `%s`，无其它改动。\n' "${UPVER:-新版本}"
    fi
} > "$OUT"

echo "== 写入 $OUT（本版 ${#self_body} 字节，上游 ${#up_body} 字节）"
cat "$OUT"
