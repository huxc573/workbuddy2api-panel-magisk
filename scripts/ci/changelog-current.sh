#!/usr/bin/env bash
# 从 CHANGELOG.md 里切出指定版本的条目，写成「只含本版」的 CHANGELOG-current.md。
#
# 为什么要这个：模块管理器会把 update.json 里 changelog 指向的文件**原样**展示在更新弹窗里。
# 直接指整份 CHANGELOG.md，用户看到的就是历史版本 + 开发笔记。所以每次发版重新生成一个
# 单版文件，update.json 指向它。
#
# 用法: scripts/ci/changelog-current.sh <版本号> <上游 tag> [源文件] [输出文件]
#   scripts/ci/changelog-current.sh 26.11.04_1 v2026.11.4.1120
#   → 写 CHANGELOG-current.md
set -euo pipefail

V="${1:?需要模块版本号，如 26.11.04_1}"
UP="${2:-}"
SRC="${3:-CHANGELOG.md}"
OUT="${4:-CHANGELOG-current.md}"
UPVER="${UP#v}"

# 取 "## <V>" 到下一个 "## " 之间的内容；版本号要整词匹配，
# 否则 26.10.31_1 会把 26.10.31_10 也一起吞进去。
body=$(
    awk -v want="$V" '
        /^## / {
            h = $0
            sub(/^##[ \t]+/, "", h)
            sub(/[ \t].*$/, "", h)
            inblk = (h == want)
            if (inblk) next
        }
        inblk { print }
    ' "$SRC"
)

# 去掉首尾空行
body=$(printf '%s\n' "$body" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;};/\n$/ba')

{
    if [ -n "$body" ]; then
        printf '%s\n' "$body"
    else
        # CHANGELOG 里还没补这版条目（CI 自动出包时常见）：至少说清运行体变到了哪
        printf -- '- 运行体升级到上游 `%s`。\n' "${UPVER:-新版本}"
    fi
} > "$OUT"

echo "== 写入 $OUT（${#body} 字节正文）"
cat "$OUT"
