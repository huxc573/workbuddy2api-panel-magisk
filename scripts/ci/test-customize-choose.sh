#!/usr/bin/env bash
# 验证 customize.sh 里音量键选择器的「N 秒无操作」行为（不需要真机）。
# getevent / timeout 都换成桩：
#   · 全程不按 ⇒ 第一个问题等 SETTLE 秒取默认，后面几个直接按默认，不再逐个等
#   · 按过键   ⇒ 取所选值，并且后面每个问题仍然会等
# 用法: bash scripts/ci/test-customize-choose.sh
set -uo pipefail
cd "$(dirname "$0")/../.."

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/bin"

# getevent 桩：按 $FAKE_SCRIPT 顺序吐事件；探测调用（首参以 - 开头）只回显一行。
# 没事件时阻塞 5 秒 —— 真机「一直听」也是这么挂着，由 timeout 掐。
cat > "$TMPD/bin/getevent" <<'EOF'
#!/bin/sh
case "$1" in
    -t)  /bin/sleep 5; exit 0 ;;          # 「一直听」：没事件就挂着，等 timeout 掐
    -*)  echo "[   10.000000] add device 1: /dev/input/event1"; exit 0 ;;   # -qc 探测
esac
n=$(cat "$FAKE_IDX" 2>/dev/null || echo 0)
line=$(sed -n "$((n + 1))p" "$FAKE_SCRIPT")
echo $((n + 1)) > "$FAKE_IDX"
case "$line" in
    UP)   echo "[   10.000000] /dev/input/event1: EV_KEY KEY_VOLUMEUP DOWN"; exit 0 ;;
    DOWN) echo "[   10.000000] /dev/input/event1: EV_KEY KEY_VOLUMEDOWN DOWN"; exit 0 ;;
    *)    /bin/sleep 5; exit 0 ;;
esac
EOF
chmod +x "$TMPD/bin/getevent"

# timeout 桩：仿 toybox timeout —— -v 打一行带秒数的提示；
# 其余调用先把 getevent 跑掉，等 TO_WAIT 秒后按超时退出（也打一行带秒数的提示）。
cat > "$TMPD/bin/timeout" <<'EOF'
#!/bin/sh
case "$*" in
    "-v 1 true")
        echo "timeout: sending signal TERM to command 'true'"; exit 124 ;;
    *getevent*)
        while [ $# -gt 0 ]; do
            case "$1" in
                -k) shift 2 ;;
                -v) shift ;;
                [0-9]*) shift ;;
                *) break ;;
            esac
        done
        "$@" 2>/dev/null
        /bin/sleep "${TO_WAIT:-1}"
        echo "timeout: sending signal TERM to command 'getevent'"
        exit 124 ;;
esac
exit 124
EOF
chmod +x "$TMPD/bin/timeout"

run_case() {
    name=$1 seq=$2 expect=$3
    printf '%s\n' "$seq" > "$TMPD/seq"
    : > "$TMPD/idx"
    out=$(SEL="$TMPD/sel.sh" KF="$TMPD/key.out" PATH="$TMPD/bin:$PATH" \
          FAKE_SCRIPT="$TMPD/seq" FAKE_IDX="$TMPD/idx" WB2A_SETTLE=3 TO_WAIT=1 \
        bash -c '
            ui_print() { echo "$*"; }
            sed -n "/^SETTLE=/,/^# ---------- 读现有配置/p" src/customize.sh | sed "\$d" > "$SEL"
            . "$SEL"
            _probe_timer
            _KF="$KF"          # 暂存文件放临时目录，不碰真机路径
            choose "端口" 1 7863 52017
            echo "PORT=$PICKED"
            choose "监听" 1 "局域网" "仅本机"
            echo "LISTEN=$PICKED"
        ' 2>&1)
    got=$(printf '%s\n' "$out" | tr '\n' '|')
    case "$got" in
        *"$expect"*) echo "PASS  $name" ;;
        *) echo "FAIL  $name"; printf '%s\n' "$out" | sed 's/^/      /' ;;
    esac
}

run_case "全程不按 → 取默认，且不再逐个等" "" "PORT=7863|LISTEN=局域网"
run_case "切换 + 确认 → 第二项" "DOWN|UP" "PORT=52017"
run_case "按过键后每个问题仍单独计时" "UP|DOWN|UP" "PORT=7863|LISTEN=仅本机"
