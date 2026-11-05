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

# getevent 桩：按 $FAKE_SCRIPT 顺序吐事件。
#   · -qc 1（能力探测）→ 回一行 add device
#   · -t（一直听）→ 真机也是「按键就给一行、没按键就挂着」，所以这里同样走队列
# 队列空了/没轮到按键就 sleep 5，由 timeout 掐掉 —— 等价真机「这段时间没按键」。
cat > "$TMPD/bin/getevent" <<'EOF'
#!/bin/sh
case "$1" in
    -qc*)  echo "[   10.000000] add device 1: /dev/input/event1"; exit 0 ;;
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
# 注意 toybox 的时长只认 1 个位置参数（-k 1 1 里的第一个 1 是信号静默期），
# 所以循化里「第一个非 - 参数」就跳出，别把时长一起吃掉。
cat > "$TMPD/bin/timeout" <<'EOF'
#!/bin/sh
case "$*" in
    "-v 1 true")
        echo "timeout: sending signal TERM to command 'true'"; exit 124 ;;
    *getevent*)
        _dur=$TO_WAIT
        while [ $# -gt 0 ]; do
            case "$1" in
                -k) shift 2 ;;
                -v) shift ;;
                -*) shift ;;
                *)  _dur=${_dur:-$1}; break ;;
            esac
        done
        "$@" 2>/dev/null
        /bin/sleep "${TO_WAIT:-1}"
        echo "[  ${TO_WAIT:-1}.000000] timeout: sending signal TERM to command 'getevent'"
        exit 124 ;;
esac
exit 124
EOF
chmod +x "$TMPD/bin/timeout"

run_case() {
    name=$1 seq=$2 expect=$3
    printf '%s\n' "$seq" > "$TMPD/seq"
    : > "$TMPD/idx"
    # 只取「计时变量 + _probe_timer/_key_once/_took/choose」这一段：
    # 起点 = SETTLE= 那行的行号，终点 = choose() 往下第一个单独的 }
    _start=$(grep -n '^SETTLE=' src/customize.sh | head -n1 | cut -d: -f1)
    _cstart=$(grep -n '^choose()' src/customize.sh | head -n1 | cut -d: -f1)
    _cend=$(awk -v s="$_cstart" 'NR>=s && /^}$/ {print NR; exit}' src/customize.sh)
    sed -n "${_start},${_cend}p" src/customize.sh > "$TMPD/sel.sh"
    out=$(PATH="$TMPD/bin:$PATH" FAKE_SCRIPT="$TMPD/seq" FAKE_IDX="$TMPD/idx" \
          WB2A_SETTLE=3 TO_WAIT=1 bash -c '
            ui_print() { echo "$*"; }
            . "$1"
            _probe_timer
            : > "$FAKE_IDX"    # 探测阶段吃掉的队列位不参与用例
            _KF="$2"           # 暂存文件放临时目录，不碰真机路径
            choose "端口" 1 7863 52017
            echo "PORT=$PICKED"
            choose "监听" 1 "局域网" "仅本机"
            echo "LISTEN=$PICKED"
        ' _ "$TMPD/sel.sh" "$TMPD/key.out" 2>&1)
    got=$(printf '%s\n' "$out" | tr '\n' '|')
    case "$got" in
        *"$expect"*) echo "PASS  $name" ;;
        *) echo "FAIL  $name"; printf '%s\n' "$out" | sed 's/^/      /' ;;
    esac
}

run_case "全程不按 → 取默认，且不再逐个等" "" "PORT=7863|LISTEN=局域网"
run_case "切换 + 确认 → 第二项" "DOWN|UP" "PORT=52017"
run_case "按过键后每个问题仍单独计时" "UP|DOWN|UP" "PORT=7863|LISTEN=仅本机"
