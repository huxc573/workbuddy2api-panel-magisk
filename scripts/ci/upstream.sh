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
echo "上游 tag: $TAG（仓库记录: ${CUR:-空}）"

{
    echo "tag=$TAG"
    if [ "$TAG" = "$CUR" ] && [ "${FORCE:-0}" != "1" ]; then
        echo "skip=1"
    else
        echo "skip=0"
    fi
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT 未设置}"
