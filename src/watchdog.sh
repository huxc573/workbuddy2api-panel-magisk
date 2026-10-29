#!/system/bin/sh
# 看门狗：串行地「起网关 → wait → 死了就重拉」。
#
# ⛔ 这里故意不用轮询（sleep N + 判活）。
#    网关是本脚本的直接子进程，wait 是阻塞系统调用：子进程活着时本脚本
#    完全不占 CPU、也不阻系统休眠；子进程一死 wait 立刻返回。
# ⛔ 也别用 setsid 起网关：一旦脱离子进程关系，wait 就失效了，
#    会立刻返回 ⇒ 变成每秒重启一次的死循环。
#
# 生命周期：
#   由 service.sh start 用 setsid 拉起（脱离安装器/adb 会话）
#   由 service.sh stop 先 SIGTERM 本脚本，本脚本 trap 里带走网关

MODDIR="$(dirname "$(readlink -f "$0")")"
. "$MODDIR/lib.sh"

WORK=$(wb2a_data_dir)
mkdir -p "$WORK" 2>/dev/null

PIDFILE="$WORK/watchdog.pid"

# ---------- 单实例 ----------
# pid 会被复用，必须校验 cmdline 里确实有 watchdog.sh
_old=$(cat "$PIDFILE" 2>/dev/null)
if [ -n "$_old" ] && [ "$_old" != "$$" ] && kill -0 "$_old" 2>/dev/null &&
   grep -q 'watchdog\.sh' "/proc/$_old/cmdline" 2>/dev/null; then
    exit 0
fi
echo "$$" > "$PIDFILE"

_gw=""
_sp=""

# ---------- 退出：先把子进程收干净，再删 pidfile ----------
_cleanup() {
    trap - TERM INT HUP
    [ -n "$_sp" ] && kill "$_sp" 2>/dev/null
    if [ -n "$_gw" ]; then
        kill "$_gw" 2>/dev/null
        _i=0
        while [ "$_i" -lt 25 ] && kill -0 "$_gw" 2>/dev/null; do
            sleep 0.2 2>/dev/null || sleep 1
            _i=$((_i + 1))
        done
        kill -9 "$_gw" 2>/dev/null
    fi
    rm -f "$PIDFILE" "$WORK/gw.pid" 2>/dev/null
    exit 0
}
trap '_cleanup' TERM INT HUP

_log() {
    echo "$(date '+%m-%d %H:%M:%S') [watchdog] $*" >> "$WORK/run.log" 2>/dev/null
}

_log "启动 (pid $$)"

_fails=0
while :; do
    # 用 read 内建读 /proc/uptime，不 fork
    read -r _up0 _ < /proc/uptime
    _up0=${_up0%.*}

    # run 模式：service.sh 做完前置后 exec 成网关本体，所以这个子进程就是网关
    sh "$MODDIR/service.sh" run >> "$WORK/run.log" 2>&1 < /dev/null &
    _gw=$!
    echo "$_gw" > "$WORK/gw.pid" 2>/dev/null

    wait "$_gw"
    _rc=$?
    _gw=""

    read -r _up1 _ < /proc/uptime
    _up1=${_up1%.*}
    _alive=$((_up1 - _up0))

    # 活够 60 秒算「正常运行后退出」，退避归零；
    # 秒退说明配置/文件有问题，退避拉长，别把 CPU 烧在这里
    if [ "$_alive" -ge 60 ]; then
        _fails=0
    else
        _fails=$((_fails + 1))
    fi

    _log "网关退出 rc=$_rc 存活 ${_alive}s，${_fails} 次连续失败后重启"
    sh "$MODDIR/refresh.sh" quiet >/dev/null 2>&1

    case "$_fails" in
        0) _wb=1 ;;
        1) _wb=2 ;;
        2) _wb=5 ;;
        3) _wb=10 ;;
        4) _wb=30 ;;
        *) _wb=60 ;;
    esac
    # 退避也要能被 stop 立刻打断，所以放后台再 wait
    sleep "$_wb" &
    _sp=$!
    wait "$_sp"
    _sp=""
done
