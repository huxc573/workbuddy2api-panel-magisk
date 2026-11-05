#!/usr/bin/env bash
# 验证 customize.sh 里音量键选择器的行为（不需要真机）。
#
# 桩的思路跟 Agent2API-Magisk 一样：getevent 桩按队列吐事件，
# `-qlc 1` 这种调用要么立刻给一行事件、要么阻塞到被 timeout 掐掉。
#   · 全程不按 ⇒ 第一题等满 SETTLE 秒取默认，之后的题直接按默认不再等
#   · 按过键   ⇒ 取所选值，且后面每题仍各自计时
# 用法: bash scripts/ci/test-customize-choose.sh
set -uo pipefail
cd "$(dirname "$0")/../.."

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/bin"

# getevent 桩：按 $FAKE_SCRIPT 逐行吐事件，队列空了就挂住（真机「一直听」也是这样）。
#   -qc 1 → 能力探测，回一行设备头
#   其它（含 -qlc 1）→ 走队列
cat > "$TMPD/bin/getevent" <<'EOF'
#!/bin/sh
case "$1" in
    -qc*)  echo "[   10.000000] add device 1: /dev/input/event1"; exit 0 ;;
esac
n=$(cat "$FAKE_IDX" 2>/dev/null || echo 0)
line=$(sed -n "$((n + 1))p" "$FAKE_SCRIPT" 2>/dev/null)
echo $((n + 1)) > "$FAKE_IDX"
case "$line" in
    UP)   echo "[   10.000000] /dev/input/event1: EV_KEY KEY_VOLUMEUP DOWN"; exit 0 ;;
    DOWN) echo "[   10.000000] /dev/input/event1: EV_KEY KEY_VOLUMEDOWN DOWN"; exit 0 ;;
    *)    /bin/sleep 10; exit 0 ;;   # 没事件：挂住，由 timeout 掐
esac
EOF
chmod +x "$TMPD/bin/getevent"

# timeout 桩：仿 toybox —— `timeout 1 getevent ...` 跑命令，等 1 秒后杀掉。
# 不支持 -k/-v，跟真机最简形态一致。
cat > "$TMPD/bin/timeout" <<'EOF'
#!/bin/sh
[ $# -gt 0 ] || exit 125
shift                          # 丢掉时长
"$@" 2>/dev/null &
_child=$!
/bin/sleep "${TO_WAIT:-1}"
kill -TERM "$_child" 2>/dev/null
wait "$_child" 2>/dev/null
exit 124
EOF
chmod +x "$TMPD/bin/timeout"

run_case() {
    name=$1 seq=$2 expect=$3
    # seq 用 | 分隔（"DOWN|UP"），必须拆成多行 —— 桩是按行读的
    printf '%s\n' "$seq" | tr '|' '\n' > "$TMPD/seq"
    : > "$TMPD/idx"

    # 只截取「变量 + _key_once/_nth/choose」这一段，起点 SETTLE= 行，终点 choose() 的收尾 }
    _start=$(grep -n '^WB2A_SETTLE=' src/customize.sh | head -n1 | cut -d: -f1)
    _cstart=$(grep -n '^choose()' src/customize.sh | head -n1 | cut -d: -f1)
    _cend=$(awk -v s="$_cstart" 'NR>=s && /^}$/ {print NR; exit}' src/customize.sh)
    sed -n "${_start},${_cend}p" src/customize.sh > "$TMPD/sel.sh"

    out=$(PATH="$TMPD/bin:$PATH" FAKE_SCRIPT="$TMPD/seq" FAKE_IDX="$TMPD/idx" \
          WB2A_SETTLE=3 TO_WAIT=1 bash -c '
            ui_print() { echo "$*"; }
            . "$1"
            choose "端口" 1 7863 52017
            echo "PORT=$PICKED"
            choose "监听" 1 "局域网" "仅本机"
            echo "LISTEN=$PICKED"
        ' _ "$TMPD/sel.sh" 2>&1)

    # expect 用 | 分隔多条断言，逐条独立匹配（中间隔着提示行，不能拼整串比）
    _ok=1
    _oldifs=$IFS; IFS='|'
    for _want in $expect; do
        case "$out" in
            *"$_want"*) ;;
            *) _ok=0 ;;
        esac
    done
    IFS=$_oldifs

    if [ "$_ok" = 1 ]; then
        echo "PASS  $name"
    else
        echo "FAIL  $name"
        printf '%s\n' "$out" | sed 's/^/      /'
    fi
}

run_case "全程不按 → 取默认，且不再逐个等" "" "PORT=7863|LISTEN=局域网"
run_case "切换 + 确认 → 第二项" "DOWN|UP" "PORT=52017"
run_case "按过键后每个问题仍单独计时" "UP|DOWN|UP" "PORT=7863|LISTEN=仅本机"
