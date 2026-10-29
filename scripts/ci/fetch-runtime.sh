#!/usr/bin/env bash
# 从上游 release 取 linux-arm64 包，抽出 wb2api 放到 runtime/，供 build_module.py 打包。
# 用法: scripts/ci/fetch-runtime.sh <tag>      例如 v2026.10.29.1418
#       scripts/ci/fetch-runtime.sh 2026.10.29.1418
set -euo pipefail

REPO="${WB2A_UPSTREAM_REPO:-misakano7545/workbuddy2api-panel}"
TAG="${1:?需要上游 tag}"
TAG="${TAG#v}"
ASSET="wb2api-panel-${TAG}-linux-arm64.zip"
URL="https://github.com/${REPO}/releases/download/v${TAG}/${ASSET}"

echo "== 上游 $REPO v$TAG"
META=$(gh api "repos/$REPO/releases/tags/v${TAG}")
DIGEST=$(printf '%s' "$META" | python3 -c '
import json,sys
d=json.load(sys.stdin)
want=sys.argv[1]
for a in d.get("assets", []):
    if a["name"] == want:
        print((a.get("digest") or "").replace("sha256:", ""))
        break
' "$ASSET")
SIZE=$(printf '%s' "$META" | python3 -c '
import json,sys
d=json.load(sys.stdin); want=sys.argv[1]
print(next((a["size"] for a in d.get("assets", []) if a["name"] == want), 0))
' "$ASSET")
[ -n "${DIGEST:-}" ] || { echo "::error::release 里没有 $ASSET（或没有 digest）"; exit 1; }
echo "资产 $ASSET  ${SIZE} 字节  sha256 $DIGEST"

mkdir -p runtime
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Actions 上 GitHub 直连可用；本地跑如果被墙，可用 WB2A_DL_PREFIX 指定加速前缀
PREFIX="${WB2A_DL_PREFIX:-}"
for i in 1 2 3; do
    echo "== 下载（第 $i 次）${PREFIX:+经 $PREFIX}"
    if curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 20 -o "$TMP/$ASSET" "${PREFIX}${URL}"; then
        break
    fi
    [ "$i" = "3" ] && { echo "::error::下载失败"; exit 1; }
    sleep 5
done

GOT=$(sha256sum "$TMP/$ASSET" | awk '{print $1}')
[ "$GOT" = "$DIGEST" ] || { echo "::error::sha256 不符（得 $GOT）"; exit 1; }
echo "sha256 校验通过"

unzip -o -q "$TMP/$ASSET" -d "$TMP/x"
[ -f "$TMP/x/wb2api" ] || { echo "::error::包里没有 wb2api"; ls -l "$TMP/x"; exit 1; }
install -m 0755 "$TMP/x/wb2api" runtime/wb2api

python3 - <<'PY'
import os
p = "runtime/wb2api"
d = open(p, "rb").read(20)
if d[:4] != b"\x7fELF" or int.from_bytes(d[18:20], "little") != 0xB7:
    raise SystemExit("运行体不是 aarch64 ELF")
print("ELF aarch64 ok, %d 字节" % os.path.getsize(p))
PY

# 版本串防呆：二进制里应带这个 tag（上游用 -X main.appVersion 注入）
if ! grep -qa "$TAG" runtime/wb2api; then
    echo "::warning::二进制里没找到版本串 $TAG，确认 release 与资产是否对齐"
fi
