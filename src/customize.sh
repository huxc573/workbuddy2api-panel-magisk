#!/system/bin/sh
# 安装脚本：补权限 + 建持久数据目录 + 音量键配置 + 首启生成访问密钥。
# 刻意不预写 config.json：交给二进制自己生成（随机 api_key、绝不覆盖已有配置），
# 这里只在「还没有配置」时把它跑一次以拿到密钥，然后立刻杀掉。
#
# ⚠ 音量键是唯一可用的安装期输入：Magisk / APatch / KernelSU 的安装界面没有输入框，
#   也不把 stdin 交给 customize.sh —— 用 read 会永久阻塞（进度条卡住）。

VER=$(sed -n 's/^version=//p' "$MODPATH/module.prop" 2>/dev/null | tr -d '\r')
[ -n "$VER" ] || VER="unknown"

# 本地测试兜底：正常刷入时这几个函数由管理器注入
command -v ui_print >/dev/null 2>&1 || ui_print() { echo "$@"; }
command -v abort >/dev/null 2>&1 || abort() { echo "! $*" >&2; exit 1; }
command -v set_perm >/dev/null 2>&1 || set_perm() {
    chown "$2:$3" "$1" 2>/dev/null; chmod "$4" "$1" 2>/dev/null
}
command -v set_perm_recursive >/dev/null 2>&1 || set_perm_recursive() {
    chown -R "$2:$3" "$1" 2>/dev/null
    find "$1" -type d -exec chmod "$4" {} \; 2>/dev/null
    find "$1" -type f -exec chmod "$5" {} \; 2>/dev/null
}

ui_print " "
ui_print " WorkBuddy2API · $VER (linux/arm64)"
ui_print " "

# 架构校验：只发 arm64 包
ABI=$(getprop ro.product.cpu.abi 2>/dev/null)
ABIS=$(getprop ro.product.cpu.abilist 2>/dev/null)
case "$ABIS" in
    *arm64-v8a*) : ;;
    *) ui_print "! 本机 ABI 不是 arm64-v8a（$ABI / $ABIS），这个包跑不了"
       abort "! 需要 arm64 设备" ;;
esac

# ---------- 权限 ----------
# zip 里已带模式位，这里再兜一次（Windows 打包/解压会丢）
for _f in action.sh check.sh refresh.sh rt.sh service.sh uninstall.sh updater.sh watchdog.sh; do
    [ -f "$MODPATH/$_f" ] && set_perm "$MODPATH/$_f" 0 0 0755
done
[ -f "$MODPATH/bin/wb2api" ] && set_perm "$MODPATH/bin/wb2api" 0 0 0755
[ -f "$MODPATH/module.prop" ] && set_perm "$MODPATH/module.prop" 0 0 0644
[ -f "$MODPATH/lib.sh" ] && set_perm "$MODPATH/lib.sh" 0 0 0644
for _d in etc zoneinfo webroot; do
    [ -d "$MODPATH/$_d" ] && set_perm_recursive "$MODPATH/$_d" 0 0 0755 0644
done

# 持久数据目录：模块更新会把模块目录整体替换，账号与状态必须放这里
# 测试可用 WB2A_DATA_DIR 旁路（与 lib.sh 的 wb2a_data_dir 同一套约定）；刷入时不会设
DATA_DIR=${WB2A_DATA_DIR:-/data/adb/wb2a}
mkdir -p "$DATA_DIR" "$DATA_DIR/data" "$DATA_DIR/auths" "$DATA_DIR/tmp"
set_perm_recursive "$DATA_DIR" 0 0 0700 0600

# ---------- 刷入时选择：只能读音量键 ----------
# 音量下 = 切下一项，音量上 = 确认。**一直等，没有超时**——只有按了音量上才往下走。
# 唯一的自动退出：本机没有 getevent / timeout（极少见），那就只能用默认值。
_key_once() {
    # 最多阻塞 1 秒；只认 KEY_VOLUMEUP / KEY_VOLUMEDOWN 的按下事件。
    # 外面套 { } 是必须的：timeout 杀掉 getevent 时 shell 会往自己的 stderr 打
    # 一行 "Terminated"，光重定向 getevent 的 stderr 盖不住它。
    _ke=$( { timeout 1 getevent -qlc 1; } 2>/dev/null )
    case "$_ke" in
        *KEY_VOLUMEUP*DOWN*) printf 'up' ;;
        *KEY_VOLUMEDOWN*DOWN*) printf 'down' ;;
    esac
}

_nth() {
    _nw=$1; shift; _nj=0
    for _nx in "$@"; do
        _nj=$((_nj + 1))
        [ "$_nj" = "$_nw" ] && { printf '%s' "$_nx"; return; }
    done
}

# choose "标题" 默认序号 选项1 选项2 ...  ⇒ 结果在 $CHOICE，采用值在 $PICKED
choose() {
    _ct=$1; _cd=$2; shift 2
    _cn=$#
    _cur=$_cd
    if ! command -v getevent >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
        CHOICE=$_cd
        PICKED=$(_nth "$_cd" "$@")
        ui_print "- $_ct: $PICKED（本机没有 getevent，取默认）"
        return
    fi
    ui_print " "
    ui_print "- $_ct: 音量下=切换  音量上=确认"
    ui_print "  → $(_nth "$_cur" "$@")"
    while :; do
        case "$(_key_once)" in
            down)
                _cur=$((_cur % _cn + 1))
                ui_print "  → $(_nth "$_cur" "$@")"
                sleep 0.25 ;;
            up)
                break ;;
        esac
        # 屏幕静止时 getevent 自己就阻塞满 1 秒，这里只防事件流很密时空转烧 CPU
        sleep 0.15 2>/dev/null || sleep 1
    done
    CHOICE=$_cur
    PICKED=$(_nth "$_cur" "$@")
    # 确认后停一下：音量上键松开得慢的话，残留事件会把下一个问题也秒确认掉
    sleep 0.4 2>/dev/null || sleep 1
}

# ---------- 读现有配置 ----------
MODDIR="$MODPATH"
. "$MODDIR/lib.sh" 2>/dev/null
WORK="$DATA_DIR"

_cur_port=""
[ -s "$DATA_DIR/port" ] && _cur_port=$(tr -dc '0-9' < "$DATA_DIR/port" 2>/dev/null | head -n1)
case "$_cur_port" in '' | *[!0-9]*) _cur_port="" ;; esac
_cur_listen=$(wb2a_listen_addr)

_installed=0
if [ -s "$DATA_DIR/port" ] || [ -f "$DATA_DIR/config.json" ]; then _installed=1; fi

# ---------- 已安装：第一个问题就问要不要动配置 ----------
# 升级安装最怕「刷一下配置全被重置」，所以默认项是「保持默认」，
# 音量上直接确认＝什么都不改。
RECONF=1
AUTO_ON=""
LISTEN_MODE=""
if [ "$_installed" = "1" ]; then
    _sp=${_cur_port:-7863}
    if wb2a_update_on; then _sa="开启"; else _sa="关闭"; fi
    ui_print " "
    ui_print "- 检测到已安装：端口 $_sp，监听 $_cur_listen，自动更新 $_sa"
    choose "是否重新设置" 1 "保持默认（沿用现有配置，不修改）" "重新设置"
    if [ "$PICKED" = "重新设置" ]; then
        RECONF=1
    else
        RECONF=0
        PORT=$_sp
        ui_print "- 沿用现有配置：端口 $PORT，自动更新 $_sa"
    fi
fi

# ---------- 配置值 ----------
if [ "$RECONF" = "1" ]; then
    # 端口：把当前值放第一项，音量上直接确认＝不改
    case "$_cur_port" in
        52019) _o1=52019; _o2=7863 ;;
        7863 | '') _o1=7863; _o2=52019 ;;
        *) _o1=$_cur_port; _o2=7863 ;;      # 用户自定义过的端口，原样保留
    esac
    choose "网关端口" 1 "$_o1" "$_o2"
    PORT=$PICKED

    # 监听范围：0.0.0.0 才能被同网段的客户端用；127.0.0.1 只有手机自己能连
    if [ "$_cur_listen" = "127.0.0.1" ]; then _ldef=2; else _ldef=1; fi
    choose "监听范围" "$_ldef" "局域网（0.0.0.0，手机同网段可访问）" "仅本机（127.0.0.1）"
    case "$PICKED" in
        仅本机*) LISTEN_MODE=local ;;
        *)       LISTEN_MODE=lan ;;
    esac

    # 自动更新：默认项＝当前状态；首次安装默认「关闭」
    # 理由：GitHub 在部分网络下不可达，在确定能连通之前不该让模块每天 04:00 空跑一次失败。
    if [ ! -f "$DATA_DIR/update.conf" ]; then
        _adef=2                                      # 首次安装：关闭
    elif wb2a_update_on; then
        _adef=1
    else
        _adef=2
    fi
    choose "自动更新（每天 04:00 查 GitHub Releases）" "$_adef" "开启" "关闭"
    AUTO_ON=$PICKED
fi

ui_print " "
ui_print "- 访问密钥: 首次启动时自动生成（随机），装完会打印出来"
ui_print "  随时可看: su -c 'sh /data/adb/modules/wb2a/action.sh key'"

# ---------- 落配置 ----------
# 可选启动环境（service.sh 每次启动 source 本文件）。默认全注释：能跑就别动。
if [ ! -f "$DATA_DIR/env" ]; then
    printf '%s\n' \
        '# WorkBuddy2API 启动环境（service.sh 每次启动 source 本文件）' \
        '# 端口 / 监听范围以 port、listen 两个文件为准，这里改不动它们' \
        '' \
        '# 出站 DNS。留空＝自动（先取 net.dns1/2，取不到用 223.5.5.5,119.29.29.29）。' \
        '# Android 没有 /etc/resolv.conf，Go 自己解析不了域名，所以这一项必须有人填。' \
        '#WB2A_DNS=223.5.5.5,119.29.29.29' \
        '' \
        '# 其余上游开关照 config.json 走；确实要塞环境变量时写在下面（同名 env 优先于配置）' \
        '#WB2A_TIMEOUT_SECONDS=120' \
        '#WB2A_USER_AGENT=' \
        > "$DATA_DIR/env"
fi
chmod 0600 "$DATA_DIR/env" 2>/dev/null

# 端口单独落文件：它是模块的权威值（config.json 里的 listen 每次启动都会被校正成它）
if [ "$RECONF" = "1" ] && [ -n "$PORT" ]; then
    printf '%s\n' "$PORT" > "$DATA_DIR/port"
    chmod 0600 "$DATA_DIR/port" 2>/dev/null
fi
[ -n "$PORT" ] || PORT=$(tr -dc '0-9' < "$DATA_DIR/port" 2>/dev/null | head -n1)
[ -n "$PORT" ] || PORT=7863

if [ "$RECONF" = "1" ] && [ -n "$LISTEN_MODE" ]; then
    printf '%s\n' "$LISTEN_MODE" > "$DATA_DIR/listen"
    chmod 0600 "$DATA_DIR/listen" 2>/dev/null
fi

if [ ! -f "$DATA_DIR/update.conf" ]; then
    printf '%s\n' \
        '# 自动更新：每天一次，按下面的钟点触发（updater.sh daemon 睡到点才醒，零 CPU 空转）' \
        '# 关掉：把下面改成 0（或 sh action.sh auto off）；改钟点：sh action.sh auto 03:30' \
        '# 首次安装默认 0=关闭：GitHub 在部分网络不可达，确认能连通再开' \
        'WB2A_UPDATE_INTERVAL=0' \
        'WB2A_UPDATE_AT=04:00' \
        '# 更新后是否重启网关：1=是' \
        'WB2A_UPDATE_RESTART=1' \
        '# 下载源（逗号分隔，末项留空=GitHub 直连兜底）。默认已内置两个公共加速；' \
        '# 有自建反代就写自己的，例如 WB2A_UPDATE_SOURCES=https://gh.你的域名/' \
        '#WB2A_UPDATE_SOURCES=https://gh-proxy.com/,https://ghproxy.net/,https://ghfast.top/,' \
        '# 上游仓库（默认 misakano7545/workbuddy2api-panel）' \
        '#WB2A_UPDATE_REPO=misakano7545/workbuddy2api-panel' \
        > "$DATA_DIR/update.conf"
fi
chmod 0600 "$DATA_DIR/update.conf" 2>/dev/null

# 刷入时选的开关落进配置（没选＝保持默认，什么都不动）
_aui=$(sed -n 's/^WB2A_UPDATE_INTERVAL=\([0-9][0-9]*\).*/\1/p' "$DATA_DIR/update.conf" 2>/dev/null | head -n1)
if [ "$AUTO_ON" = "关闭" ]; then
    sed -i 's|^WB2A_UPDATE_INTERVAL=.*|WB2A_UPDATE_INTERVAL=0|' "$DATA_DIR/update.conf"
    rm -f "$DATA_DIR/update.off" 2>/dev/null
elif [ "$AUTO_ON" = "开启" ] && [ "$_aui" = "0" ]; then
    sed -i 's|^WB2A_UPDATE_INTERVAL=.*|WB2A_UPDATE_INTERVAL=86400|' "$DATA_DIR/update.conf"
    rm -f "$DATA_DIR/update.off" 2>/dev/null
fi

# 自动更新状态（给人看的）
_at=$(sed -n 's/^WB2A_UPDATE_AT=\([0-9:]*\).*/\1/p' "$DATA_DIR/update.conf" 2>/dev/null | head -n1)
[ -n "$_at" ] || _at=04:00
if wb2a_update_on; then
    AUTO_ST="每天 $_at"
else
    AUTO_ST="已关闭（sh $MODPATH/action.sh auto on 打开）"
fi

# 记下当前上游版本，updater 拿它跟最新 release 比。
# ⚠ 升级安装时也必须重写：刷进去的就是这个版本，若沿用旧记录会被判定成「有新版本」，
#   进而去下载旧 release，造成降级覆盖。
UPV=$(sed -n 's/.*(wb2a \([^)]*\)).*/\1/p' "$MODPATH/module.prop" 2>/dev/null | head -n1)
if [ -n "$UPV" ]; then
    printf '%s\n' "$UPV" > "$DATA_DIR/upstream.version"
    chmod 0600 "$DATA_DIR/upstream.version" 2>/dev/null
fi

# ---------- 首启生成配置 + 拿访问密钥 ----------
# 全新安装时在这里跑一次二进制：它会把 config.json（含随机 api_key）写到 cwd，
# 写完就 kill —— 不做常驻，只为把密钥拿到手、顺手证明这个二进制在本机能跑。
# 升级安装：配置已在，直接读。
KEY=""
if [ ! -f "$DATA_DIR/config.json" ] && [ -f "$MODPATH/bin/wb2api" ]; then
    ui_print "- 正在生成配置文件与访问密钥…"
    # WB2A_LISTEN 给 127.0.0.1:0（内核分配临时端口），不和任何东西抢端口。
    # 3 秒足够写完配置；写不完就是这台机器根本跑不了它，那时要让人看见。
    ( cd "$DATA_DIR" && WB2A_LISTEN=127.0.0.1:0 HOME="$DATA_DIR" TMPDIR="$DATA_DIR/tmp" \
        timeout 3 "$MODPATH/bin/wb2api" ) >/dev/null 2>&1
    if [ ! -f "$DATA_DIR/config.json" ]; then
        ui_print "! 二进制没能生成配置（可能不兼容本机内核）"
        ui_print "  重启后仍失败的话：sh $MODPATH/check.sh 把输出发我"
    fi
fi
KEY=$(wb2a_apikey)
[ -n "$KEY" ] && { printf '%s\n' "$KEY" > "$DATA_DIR/apikey.txt"; chmod 0600 "$DATA_DIR/apikey.txt"; }

# 把 config.json 的 listen 校正成选定值（首启生成的是上游默认 127.0.0.1:7863）
wb2a_force_listen "$(wb2a_listen_addr)" "$PORT"

ui_print " "
ui_print "- 数据目录: $DATA_DIR（账号 / 状态 / 配置都在这里）"
ui_print "- 网关端口: $PORT（$( [ "$(wb2a_listen_addr)" = "127.0.0.1" ] && echo '仅本机' || echo '局域网 0.0.0.0' )）"
ui_print "  面板地址: http://127.0.0.1:$PORT/panel/ ，手机同 WiFi 用 http://<手机IP>:$PORT/panel/"
if [ -n "$KEY" ]; then
    ui_print "- 访问密钥: $KEY"
    ui_print "  面板登录要填它（客户端也用它当 Bearer）；随时可看: sh action.sh key"
else
    ui_print "- 访问密钥: 重启后自动生成，sh action.sh key 查看"
fi
ui_print "- 自动更新: $AUTO_ST（源: GitHub Releases 的 linux-arm64 包，带 sha256 校验）"
ui_print " "
ui_print "  随时可改：su -c 'sh /data/adb/modules/wb2a/action.sh config'"
ui_print "- 重启设备即自动运行；手动启停: sh /data/adb/modules/wb2a/service.sh start|stop"
ui_print "- 卸载: 管理器点卸载（会连 $DATA_DIR 一起删干净；想留账号先 touch $DATA_DIR/keep）"
ui_print " "

# ---------- 运行体同步 + 立即启动 ----------
# 运行体的权威位置是 /data/adb/wb2a/rt，不是模块目录：模块目录由 Magisk 管，
# 刷 zip 只解到 /data/adb/modules_update/wb2a，要**重启**才整体替换。
# 数据目录 Magisk 从不碰 ⇒ 刷完只要重启网关进程，不用重启手机。
FINAL_DIR=/data/adb/modules/wb2a

# 先把刚解压到 $MODPATH（= modules_update/wb2a）的 bin 同步进 rt。
# 放在 stop 之前做：mv 是原子替换，旧进程握着的旧 inode 要等它退出才回收，不影响它继续跑。
if WB2A_DATA_DIR="$DATA_DIR" sh "$MODPATH/rt.sh" sync >/dev/null 2>&1; then
    _rt_ok=1
else
    _rt_ok=0
fi

# 自动更新当前状态（update.off 或 INTERVAL=0 都算关闭）
_upd=开启
if [ -f "$DATA_DIR/update.off" ]; then
    _upd=关闭
else
    _iv=$(sed -n 's/^WB2A_UPDATE_INTERVAL=\([0-9][0-9]*\).*/\1/p' "$DATA_DIR/update.conf" 2>/dev/null | head -n1)
    [ -n "$_iv" ] && [ "$_iv" -eq 0 ] 2>/dev/null && _upd=关闭
fi

if [ "${WB2A_INSTALL_NO_START:-0}" = "1" ]; then
    ui_print "- 已跳过立即启动（WB2A_INSTALL_NO_START=1），重启后自动运行"
    ui_print " "
elif [ ! -d "$FINAL_DIR" ]; then
    # 全新安装：模块目录要重启后才出现，这会儿没有能常驻的脚本可跑
    ui_print "- 首次安装，重启设备后自动运行"
    ui_print " "
elif [ -f "$FINAL_DIR/disable" ]; then
    ui_print "- 模块当前处于停用状态，未启动（启用后重启生效）"
    ui_print " "
else
    ui_print "- 正在切到本次刷入的版本（重启网关进程，不用重启手机）…"
    # ⚠ 必须用 $MODPATH 里的新脚本：$FINAL_DIR 里的还是上一版
    sh "$MODPATH/service.sh" stop >/dev/null 2>&1
    _st=0
    WB2A_DATA_DIR="$DATA_DIR" sh "$MODPATH/service.sh" start >/dev/null 2>&1 || _st=1
    _port=$(cat "$DATA_DIR/port" 2>/dev/null)
    case "$_port" in '' | *[!0-9]*) _port=7863 ;; esac

    if [ "$_st" = "0" ]; then
        ui_print "- 网关已启动，端口 $_port 可以访问（已是本次刷入的版本）"
    else
        ui_print "! 网关没能启动（端口 $_port 无响应）"
        ui_print "  重启设备后会自动重试；若重启后仍不行，请把下面日志发我："
        ui_print "  $DATA_DIR/run.log"
    fi
    if [ "$_rt_ok" = "0" ]; then
        ui_print "! 运行体同步失败（$DATA_DIR/rt），当前仍是旧版本在跑"
        ui_print "  重启设备后自动重试；仍失败请检查 /data 剩余空间"
    fi
    ui_print "- 自动更新：$_upd"
    ui_print " "
fi
