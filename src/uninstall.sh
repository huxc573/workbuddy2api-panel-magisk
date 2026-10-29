#!/system/bin/sh
# 卸载：停进程 + 删模块目录 + 删数据目录。
# ⛔ 只碰写死的三个路径，且必须精确匹配白名单；其它一律不删。
#    绝不用通配符、绝不 rm -rf 任何动态拼出来的路径。
#    想重装后保留账号：卸载前 touch /data/adb/wb2a/keep

MODDIR=/data/adb/modules/wb2a
WORK=/data/adb/wb2a

# 白名单删除：只认这三个精确路径，其它一律拒绝（防变量异常时误删）
safe_rm() {
    case "$1" in
        /data/adb/modules/wb2a | /data/adb/modules_update/wb2a | /data/adb/wb2a)
            [ -d "$1" ] || return 0
            rm -rf "$1" 2>/dev/null
            [ -d "$1" ] && return 1
            return 0 ;;
        *)
            echo "[wb2a] 拒绝删除非白名单路径: $1" >&2
            return 1 ;;
    esac
}

# 先停看门狗与网关（service.sh stop 会连带停更新定时器）
_svc="$MODDIR/service.sh"
if [ -f "$_svc" ]; then
    sh "$_svc" stop >/dev/null 2>&1
fi

# 兜底：更新定时器（按 pidfile 精确杀，不 pkill，避免误伤同名进程）
if [ -f "$WORK/update.timer.pid" ]; then
    _t=$(cat "$WORK/update.timer.pid" 2>/dev/null)
    if [ -n "$_t" ]; then
        kill "$_t" 2>/dev/null
        sleep 0.2 2>/dev/null
        kill -9 "$_t" 2>/dev/null
    fi
    rm -f "$WORK/update.timer.pid" 2>/dev/null
fi

# 兜底：网关本体。路径与 lib.sh 的 wb2a_pids 保持一致（rt 优先、模块目录回退、安装期临时目录）
pkill -f "$WORK/rt/bin/wb2api" 2>/dev/null
pkill -f "$MODDIR/bin/wb2api" 2>/dev/null
pkill -f "/data/adb/modules_update/wb2a/bin/wb2api" 2>/dev/null
sleep 1
pkill -9 -f "$WORK/rt/bin/wb2api" 2>/dev/null
pkill -9 -f "$MODDIR/bin/wb2api" 2>/dev/null
pkill -9 -f "/data/adb/modules_update/wb2a/bin/wb2api" 2>/dev/null

echo "[wb2a] 网关 / 更新排班已停止。"
# 运行体自检：rt/ 里还留着二进制就说明进程没停干净（下面删数据目录会连带删掉）
if [ -f "$WORK/rt/bin/wb2api" ] && [ -n "$(pgrep -f "$WORK/rt/bin/wb2api" 2>/dev/null)" ]; then
    echo "[wb2a] ⚠ 仍有进程在用 $WORK/rt 里的二进制，重启后再手动删一次 $WORK"
fi

touch "$MODDIR/remove" 2>/dev/null
[ -f "$MODDIR/disable" ] || touch "$MODDIR/disable" 2>/dev/null
cd / 2>/dev/null
safe_rm "$MODDIR"
safe_rm /data/adb/modules_update/wb2a

# 数据目录：账号凭证、配置、日志 —— 一并清掉
if [ -f "$WORK/keep" ]; then
    echo "[wb2a] 检测到 $WORK/keep，保留数据目录（重装可继续用同一批账号与密钥）。"
else
    if safe_rm "$WORK"; then
        echo "[wb2a] 数据目录已删除（$WORK）。"
    else
        echo "[wb2a] 数据目录没删干净（$WORK），重启后再手动删一次。"
    fi
fi

if [ -d "$MODDIR" ]; then
    echo "[wb2a] 模块目录没删掉（$MODDIR），已打 remove 标记：重启后由管理器清除。"
else
    echo "[wb2a] 模块已卸载（目录已删除，管理器列表刷新后即消失）。"
fi
