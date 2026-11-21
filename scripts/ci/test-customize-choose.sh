#!/usr/bin/env bash
# 验证 customize.sh 里音量键选择器的行为（不需要真机）。
#
# 桩的思路跟 Agent2API-Magisk 一样：getevent 桩按队列吐事件，
# `-qlc 1` 这种调用要么立刻给一行事件、要么阻塞到被 timeout 掐掉。
#   · 全程不按 ⇒ 第一题等满 SETTLE 秒取默认，之后的题直接按默认不再等
#   · 按过键   ⇒ 第一题取所选值；后面每题**不再倒计时**，没按键就一直等
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
# 同步等子进程跑完再 sleep：真机 getevent 是有事件立刻返回、没事件一直挂着，
# 这里用「先跑、跑完就返回」来模拟前一种，队列空了才走 sleep+退出 124。
"$@" 2>/dev/null
_rc=$?
[ "$_rc" -eq 0 ] && exit 0
/bin/sleep "${TO_WAIT:-1}"
exit 124
EOF
chmod +x "$TMPD/bin/timeout"

run_case() {
    name=$1 seq=$2 expect=$3 guard=${4:-0}
    # seq 用 | 分隔（"DOWN|UP"），必须拆成多行 —— 桩是按行读的
    printf '%s\n' "$seq" | tr '|' '\n' > "$TMPD/seq"
    : > "$TMPD/idx"

    # 只截取「变量 + _key_once/_nth/choose」这一段，起点 SETTLE= 行，终点 choose() 的收尾 }
    _start=$(grep -n '^WB2A_SETTLE=' src/customize.sh | head -n1 | cut -d: -f1)
    _cstart=$(grep -n '^choose()' src/customize.sh | head -n1 | cut -d: -f1)
    _cend=$(awk -v s="$_cstart" 'NR>=s && /^}$/ {print NR; exit}' src/customize.sh)
    sed -n "${_start},${_cend}p" src/customize.sh > "$TMPD/sel.sh"

    # guard>0：外层再套一层**系统** timeout。后续问题不设倒计时，没人按键会一直等，
    # 这是期望行为，但测试必须能收尾，否则整轮 CI 挂住。
    # ⚠ 必须用绝对路径：PATH 里插了桩目录，写 `timeout` 会命中桩（桩只跑一下再 sleep，
    #   不会杀进程）⇒ 兜底失效、测试永久挂起。
    _gt=""
    if [ "${guard:-0}" -gt 0 ] 2>/dev/null; then
        _gt=$(type -P timeout)
    fi
    out=$(PATH="$TMPD/bin:$PATH" FAKE_SCRIPT="$TMPD/seq" FAKE_IDX="$TMPD/idx" \
          WB2A_SETTLE=3 TO_WAIT=1 ${_gt:+"$_gt" "$guard"} ${_gt:+env} bash -c '
            ui_print() { echo "$*"; }
            . "$1"
            choose "端口" 1 7863 52017
            echo "PORT=$PICKED"
            choose "监听" 1 "局域网" "仅本机"
            echo "LISTEN=$PICKED"
        ' _ "$TMPD/sel.sh" 2>&1)

    # expect 用 || 分隔多条断言（每条内部可以含单个 |），逐条独立匹配 ——
    # 中间隔着提示行，不能拼成整串比。
    #   ^xxx = 否定断言（输出里不许出现 xxx）
    #   末尾 $ = 必须是输出的最后一行
    _ok=1
    _oldifs=$IFS; IFS='|'
    _rest="$expect"
    while [ -n "$_rest" ]; do
        case "$_rest" in
            *"||"*) _want=${_rest%%||*}; _rest=${_rest#*||} ;;
            *)      _want=$_rest; _rest="" ;;
        esac
        case "$_want" in
            ^*)
                case "$out" in *"${_want#^}"*) _ok=0 ;; esac ;;
            *'$')
                _tail=${_want%'$'}
                case "$out" in *"$_tail") ;; *) _ok=0 ;; esac ;;
            *)
                case "$out" in *"$_want"*) ;; *) _ok=0 ;; esac ;;
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

run_case "全程不按 → 免配置，后面全默认" ""     "（超时，按默认）||LISTEN=局域网||（免配置，按默认）"
run_case "第一题切换+确认，第二题切换+确认" "DOWN|UP|DOWN|UP"     "PORT=52017||LISTEN=仅本机||→ 52017  ("
# 第三例：第一题按过键 ⇒ 后续问题不再倒计时。队列只给一个 UP，第二题会一直等（期望行为），
# 用外层 timeout 兜住；只验证第一题正常确认、且第二题的超时**没有**被判成「按默认」。
# 断言（全部正向）：第一题正常确认；第二题打出「→ 局域网」，且它是最后一行 ——
# 没有后续的「…Ns」倒计时，也没有被判成「按默认」。
run_case "第一题确认后，第二题不再倒计时（一直等）" "UP"     "- 端口: 7863||→ 局域网$||^…0s" 25
