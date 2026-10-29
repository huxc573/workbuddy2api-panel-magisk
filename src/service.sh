#!/system/bin/sh
# 启动器：负责环境准备 + 拉起看门狗；网关本身由看门狗拉起并守着。
#
# 保活模型（与 Agent2API-Magisk 同一套，已在真机验证）：
#   service.sh start → setsid watchdog.sh（脱离安装器/adb 会话）
#   watchdog.sh      → 起 `service.sh run`（前置后 exec 成网关）→ wait → 死了重拉
#   wait 是阻塞系统调用：网关活着时看门狗零 CPU、不阻休眠；网关一死立即返回。
#   ⛔ 不要改回「sleep N + pgrep 判活」：每轮一次全表扫描，单核跑满、整夜掉电。
#
# 用法：
#   sh service.sh          前台 exec（调试用，跟着终端走）
#   sh service.sh start    后台起（开机流程、action.sh、安装收尾）
#   sh service.sh run      由 watchdog 调用：前置完 exec 成网关本体
#   sh service.sh stop     停看门狗 + 网关 + 更新定时器
#   sh service.sh restart  重启

MODDIR="$(dirname "$(readlink -f "$0")")"
. "$MODDIR/lib.sh"

# 等 /data 解密完成（FBE 机型 services 阶段 /data/adb 可能还没挂好）
_i=0
while [ ! -d /data/adb ] && [ "$_i" -lt 60 ]; do
    sleep 1
    _i=$((_i + 1))
done

WORK=$(wb2a_data_dir)
mkdir -p "$WORK" "$WORK/data" "$WORK/auths" "$WORK/tmp" 2>/dev/null

# ---------- 运行体自愈 ----------
# rt 缺失 / 没有版本戳 / 比模块旧（刷了新 zip 还没重启、或上次同步被打断）⇒ 整份重同步。
# 正常情况下这里只是 2 次 stat + 1 次 cat，不做任何复制，开销可忽略。
if [ -f "$MODDIR/rt.sh" ] && wb2a_rt_need_sync; then
    sh "$MODDIR/rt.sh" sync >/dev/null 2>&1
fi

# 兜底：某些安装方式会把文件解成 644，二进制就起不来。每次启动顺手纠正一遍，幂等。
# ⚠ rt/bin 也要补：customize.sh 里的 set_perm_recursive 会把数据目录下的文件统一改成
#   0600，rt 里那份二进制会被顺手收掉可执行位（真机踩过）。
chmod 755 "$MODDIR"/*.sh "$MODDIR/bin/"* "$WORK/rt/bin/"* 2>/dev/null

stop_gw() {
    [ -n "$(wb2a_pids)" ] || return 0
    for _p in $(wb2a_pids); do kill "$_p" 2>/dev/null; done
    # 给 3 秒优雅退出，之后强杀（开机/重装时不该在这里耗时间）
    _i=0
    while [ -n "$(wb2a_pids)" ] && [ "$_i" -lt 15 ]; do
        sleep 0.2 2>/dev/null || sleep 1
        _i=$((_i + 1))
    done
    for _p in $(wb2a_pids); do kill -9 "$_p" 2>/dev/null; done
}

# ---------- 看门狗 ----------
# 顺序很关键：停的时候必须先停看门狗，否则它会在网关被杀后立刻重拉，
# 表现就是「stop 了但进程马上又回来」。
stop_watchdog() {
    _w=$(wb2a_watchdog_pid) || { rm -f "$WORK/watchdog.pid" 2>/dev/null; return 0; }
    kill "$_w" 2>/dev/null
    # 它 trap 里要收网关，给足时间（最多 5 秒）
    _i=0
    while [ "$_i" -lt 25 ] && kill -0 "$_w" 2>/dev/null; do
        sleep 0.2 2>/dev/null || sleep 1
        _i=$((_i + 1))
    done
    kill -9 "$_w" 2>/dev/null
    rm -f "$WORK/watchdog.pid" 2>/dev/null
    return 0
}

start_watchdog() {
    # 已经在跑就是幂等
    if [ -n "$(wb2a_watchdog_pid)" ]; then
        return 0
    fi
    # 有网关但没看门狗（看门狗被系统杀过）：那个网关不是它的子进程，wait 管不到，
    # 只能重启一次纳管。
    if [ -n "$(wb2a_pids)" ]; then
        stop_gw
    fi
    # setsid：脱离安装器 / adb 会话的进程组，装完/断开后不被一起带走
    setsid sh "$MODDIR/watchdog.sh" >/dev/null 2>&1 < /dev/null &
    # 等它把 pidfile 写出来（正常 1 秒内），最多 5 秒
    _i=0
    while [ "$_i" -lt 25 ] && [ -z "$(wb2a_watchdog_pid)" ]; do
        sleep 0.2 2>/dev/null || sleep 1
        _i=$((_i + 1))
    done
    [ -n "$(wb2a_watchdog_pid)" ]
}

# ---------- 自动更新：一个睡眠进程，到点才醒，不轮询 ----------
# ⛔ 别指望 crond：Android 上没有 crond，探测必然失败，自动更新会静默失效。
# ⛔ 也别每 60 秒醒一次算钟点：那是纯白耗电。
# 做法：updater.sh daemon —— 睡到下一个目标时刻才醒；单次最多睡 30 分钟。
start_update_timer() {
    # 关着就别起这个常驻进程：它只会一直睡，白占进程槽
    if ! wb2a_update_on; then
        stop_update_timer
        return 0
    fi
    if [ -f "$WORK/update.timer.pid" ]; then
        _t=$(cat "$WORK/update.timer.pid" 2>/dev/null)
        # 必须校验 cmdline：pid 会被复用
        if [ -n "$_t" ] && kill -0 "$_t" 2>/dev/null &&
           grep -q 'updater\.sh' "/proc/$_t/cmdline" 2>/dev/null; then
            return 0
        fi
    fi
    setsid sh "$MODDIR/updater.sh" daemon >/dev/null 2>&1 < /dev/null &
    return 0
}

stop_update_timer() {
    [ -f "$WORK/update.timer.pid" ] || return 0
    _t=$(cat "$WORK/update.timer.pid" 2>/dev/null)
    if [ -n "$_t" ] && kill -0 "$_t" 2>/dev/null; then
        kill "$_t" 2>/dev/null
        _i=0
        while [ "$_i" -lt 10 ] && kill -0 "$_t" 2>/dev/null; do
            sleep 0.2 2>/dev/null
            _i=$((_i + 1))
        done
        # 兜底：它被 KILL 掉、来不及收子进程时，按 PPID 清掉残留
        for _c in $(ps -A -o PID,PPID 2>/dev/null | awk -v t="$_t" '$2 == t {print $1}'); do
            kill -9 "$_c" 2>/dev/null
        done
        kill -9 "$_t" 2>/dev/null
    fi
    rm -f "$WORK/update.timer.pid" 2>/dev/null
    return 0
}

case "$1" in
    stop)    stop_watchdog; stop_gw; stop_update_timer; exit 0 ;;
    # ⛔ restart 必须落到 start 分支：只写「停三件套」的话后面会一路掉到文件末尾的
    #    前台 exec ⇒ restart 永不返回，而且看门狗不会被拉起。
    restart) stop_watchdog; stop_gw; stop_update_timer; set -- start ;;
    crontab) stop_update_timer; start_update_timer; exit 0 ;;
esac

# 已在跑就不重复起（restart 除外）；但看门狗和定时器要按最新配置兜一次。
# run 是 watchdog 专用的前台模式，必须绕开这个早退判断，否则会立刻退出→无限重启。
if [ "$1" != "restart" ] && [ "$1" != "run" ] && [ -n "$(wb2a_pids)" ]; then
    case "$1" in
        # 空参数 = 开机流程调用（APatch/Magisk 都是无参执行 service.sh）
        start | "") start_watchdog; start_update_timer ;;
        crontab)    stop_update_timer; start_update_timer ;;
    esac
    exit 0
fi

[ -f "$(wb2a_bin)" ] || { echo "[wb2a] 缺少二进制 $(wb2a_bin)" >&2; exit 1; }

# ---------- 运行环境 ----------
[ -f "$WORK/env" ] && . "$WORK/env"
export HOME="$WORK"
# Go 的 os.TempDir 默认 /tmp —— Android 没有这个目录，临时文件会创建失败
export TMPDIR="$WORK/tmp"

PORT_FORCED=$(wb2a_get_port)
[ -n "$PORT_FORCED" ] || PORT_FORCED=$WB2A_DEFAULT_PORT
LISTEN_ADDR=$(wb2a_listen_addr)
# 端口以 $WORK/port 为准。env 与 config.json 同时校正：前者保证这次启动真的绑对，
# 后者保证面板「配置」页显示的就是实际值。
[ -f "$WORK/port" ] || printf '%s\n' "$PORT_FORCED" > "$WORK/port" 2>/dev/null
wb2a_force_listen "$LISTEN_ADDR" "$PORT_FORCED"
export WB2A_LISTEN="$LISTEN_ADDR:$PORT_FORCED"

# Android 没有 /etc/resolv.conf；显式给解析器，否则域名全解析失败（见 lib.sh）。
# 已在 $WORK/env 里手填过 WB2A_DNS 就尊重它，不覆盖。
if [ -z "$WB2A_DNS" ]; then
    _DNS=$(wb2a_dns)
    [ -n "$_DNS" ] && export WB2A_DNS="$_DNS"
fi

eval "$(wb2a_cert_env)"     # Go 不读 Android 的信任锚
eval "$(wb2a_tz_env)"       # Android 的 tzdata 是打包格式，Go 不认

# 日志归档：只在非 run 分支做（run 是看门狗拉起的子进程，此刻 run.log 正被 hold 着 fd，
# 替换文件会让后续日志写进已 unlink 的旧 inode —— 宁可只在上层 start/stop 时归档）。
[ "$1" = "run" ] || wb2a_rotate "$WORK/run.log" 5242880

cd "$WORK" || exit 1

# ---------- 后台模式 ----------
if [ -z "$1" ] || [ "$1" = "start" ]; then
    if ! start_watchdog; then
        echo "[wb2a] 看门狗没能启动（$WORK/watchdog.pid 未出现）" >&2
        exit 1
    fi
    # 等端口真的在 LISTEN，而不是「进程存在就算好」。
    _i=0
    while [ "$_i" -lt 40 ] && ! wb2a_port_listen "$PORT_FORCED"; do
        sleep 0.5 2>/dev/null || sleep 1
        _i=$((_i + 1))
    done
    # 密钥落一份给人看的副本（0600）。首启由二进制生成，这一步只是抄出来。
    _k=$(wb2a_apikey)
    if [ -n "$_k" ]; then
        printf '%s\n' "$_k" > "$WORK/apikey.txt" 2>/dev/null
        chmod 0600 "$WORK/apikey.txt" 2>/dev/null
    fi
    # 列表里刷一次状态（运行中 · IP:端口）；之后只在点「操作」时刷
    sh "$MODDIR/refresh.sh" quiet >/dev/null 2>&1
    start_update_timer
    echo "$(date '+%m-%d %H:%M') 网关已启动（看门狗 pid $(wb2a_watchdog_pid)，$LISTEN_ADDR:$PORT_FORCED）" >> "$WORK/run.log"
    # 记一行运行体来源：排查「升级了但服务还是老的」时，先看这里
    echo "$(date '+%m-%d %H:%M') 运行体 $(wb2a_bin)（rt $(wb2a_rtver) / 模块 $(wb2a_modver)）" >> "$WORK/run.log"
    if wb2a_port_listen "$PORT_FORCED"; then
        exit 0
    fi
    echo "[wb2a] 网关 20 秒内没有监听端口 $PORT_FORCED，详见 $WORK/run.log" >&2
    exit 1
fi

# ---------- 前台模式：exec，把本进程直接变成网关 ----------
exec "$(wb2a_bin)"
