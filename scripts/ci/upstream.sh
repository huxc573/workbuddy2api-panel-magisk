#!/usr/bin/env bash
# 解析上游最新 release tag。输出到 $GITHUB_OUTPUT：tag=<tag>  skip=<0|1>
#   skip=1 表示和仓库里 UPSTREAM 记录的一致（没有新版），除非 FORCE=1。
set -euo pipefail

REPO="${WB2A_UPSTREAM_REPO:-misakano7545/workbuddy2api-panel}"
IN="${1:-}"

TAG="$IN"
if [ -z "$TAG" ]; then
    TAG=$(gh api "repos/$REPO/releases?per_page=20" \
            --jq '[.[] | select(.draft == false) | .tag_name][0] // empty')
fi
[ -n "$TAG" ] || { echo "::error::$REPO 拿不到 release"; exit 1; }

CUR="$(cat UPSTREAM 2>/dev/null | tr -d ' \r\n' || true)"

# 比版本时一律去掉前导 v：上游 tag 是 v2026.10.29.1418，人手写 UPSTREAM 时常写成
# 2026.10.29.1418，两边直接比字符串会判成「有新版」→ 白出一遍包。
_norm() { printf '%s' "${1#v}"; }
echo "上游 tag: $TAG（仓库记录: ${CUR:-空}）"

{
    echo "tag=$TAG"
    if [ "$(_norm "$TAG")" = "$(_norm "$CUR")" ] && [ "${FORCE:-0}" != "1" ]; then
        echo "skip=1"
    else
        echo "skip=0"
    fi
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT 未设置}"
