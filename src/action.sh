#!/system/bin/sh
# 「执行」按钮：重启网关进程（不动手机），并把访问密钥和地址打出来。
# 打开面板归「打开」按钮：webroot/index.html（APatch / KernelSU 原生支持；
#   Magisk 自己没有 WebView，要装 KsuWebUI 或 MMRL 才会显示那个按钮）。
# 命令行：sh action.sh key | open | config | reset | auto … | log | sync | update

MODDIR="$(dirname "$(readlink -f "$0")")"
. "$MODDIR/lib.sh"

WORK=$(wb2a_data_dir)
mkdir -p "$WORK" 2>/dev/null
CONF="$WORK/update.conf"

# ---- 自动更新开关 ----
# 两处都能关：$WORK/update.off 文件，或 update.conf 里 WB2A_UPDATE_INTERVAL=0。
# 写配置时顺手清掉 update.off，避免「文件留着、配置开了却仍不跑」。
auto_status() {
    if [ -f "$WORK/update.off" ]; then
        echo "关闭（存在 update.off）"
        return
    fi
    _i=$(sed -n 's/^[[:space:]]*WB2A_UPDATE_INTERVAL=\([0-9][0-9]*\).*/\1/p' "$CONF" 2>/dev/null | head -n1)
    [ -n "$_i" ] || _i=86400
    if [ "$_i" = "0" ]; then
        echo "关闭（WB2A_UPDATE_INTERVAL=0）"
        return
    fi
    _at=$(sed -n 's/^[[:space:]]*WB2A_UPDATE_AT=\([0-9:]*\).*/\1/p' "$CONF" 2>/dev/null | head -n1)
    case "$_at" in
        [0-9]:[0-9][0-9] | [01][0-9]:[0-9][0-9] | 2[0-3]:[0-9][0-9]) : ;;
        *) _at=04:00 ;;
    esac
    echo "开启（每天 $_at）"
}

set_kv() {
    # 变量名带 sk_ 前缀：sh 没有 local，叫 _k/_v 会把调用方的同名变量改掉
    _sk=$1; _sv=$2
    [ -f "$CONF" ] || : > "$CONF"
    if grep -q "^[[:space:]]*$_sk=" "$CONF" 2>/dev/null; then
        sed -i "s|^[[:space:]]*$_sk=.*|$_sk=$_sv|" "$CONF"
    else
        printf '%s=%s\n' "$_sk" "$_sv" >> "$CONF"
    fi
}

url_of() {
    _p=$(wb2a_get_port)
    # 面板在 /panel/，根路径 / 是 404（实测）
    echo "http://${1:-127.0.0.1}:$_p/panel/"
}

key_show() {
    _k=$(wb2a_apikey)
    if [ -n "$_k" ]; then
        echo "$_k"
    else
        echo "（还没有密钥：网关没成功启动过，或 config.json 被删了。重启一次即会生成）" >&2
        return 1
    fi
}

case "$1" in
reset)
    # 清掉已登录的账号：auths/*.json 是唯一存凭证的地方，池状态在 data/state.json。
    # ⛔ 只删 $WORK 下我们自己的文件，且路径必须落在 /data/adb/wb2a 之内 ——
    #    路径异常时宁可不动，也不能变成 `rm -f /*.json` 这种。
    case "$WORK" in
        /data/adb/wb2a | /data/adb/wb2a/) : ;;
        *) echo "路径异常（$WORK），拒绝删除"; exit 1 ;;
    esac
    # 默认不动手：先把要删的东西列出来，确认才删（管理器按钮调它时没有 tty，不能靠 read）
    echo "会删除这些账号文件（配置与访问密钥不动）："
    _n=0
    for _f in "$WORK"/auths/*.json; do
        [ -e "$_f" ] || continue
        echo "  ${_f#$WORK/}"
        _n=$((_n + 1))
    done
    [ -f "$WORK/data/state.json" ] && echo "  data/state.json（池状态）"
    [ "$_n" = "0" ] && { echo "  （没有已登录账号，不用清）"; exit 0; }
    _go=""
    case "$2" in
        yes | -y | --yes) _go=1 ;;
    esac
    if [ -z "$_go" ] && [ -t 0 ]; then
        printf '确认删除? [y/N]: '
        read -r _yn
        case "$_yn" in y* | Y*) _go=1 ;; esac
    fi
    [ -n "$_go" ] || { echo "未删除。确认无误后执行: sh $MODDIR/action.sh reset yes"; exit 1; }
    for _f in "$WORK"/auths/*.json "$WORK/data/state.json"; do
        [ -e "$_f" ] && rm -f "$_f" && echo "  删除 ${_f#$WORK/}"
    done
    sh "$MODDIR/service.sh" restart >/dev/null 2>&1
    sh "$MODDIR/refresh.sh" quiet >/dev/null 2>&1
    echo "网关已重启；打开 $(url_of) 重新「添加账号」"
    exit 0 ;;
key)
    case "$2" in
    new | re | regen)
        # 重新生成访问密钥：只能改 config.json（网关与面板共用这一个 Bearer）。
        _cfg="$WORK/config.json"
        [ -f "$_cfg" ] || { echo "还没有 $_cfg，先启动一次网关"; exit 1; }
        _nk="sk-$(od -An -tx1 -N18 /dev/urandom 2>/dev/null | tr -d ' \n')"
        case "$_nk" in
            sk-[0-9a-f]*) [ "${#_nk}" -eq 39 ] || { echo "生成的密钥长度不对（${#_nk}）"; exit 1; } ;;
            *) echo "生成随机数失败"; exit 1 ;;
        esac
        if grep -q '"api_key"' "$_cfg"; then
            sed -i "s|\"api_key\"\([[:space:]]*:[[:space:]]*\)\"[^\"]*\"|\"api_key\"\1\"$_nk\"|" "$_cfg" || {
                echo "写入失败"; exit 1; }
        else
            echo "config.json 里没有 api_key 字段，拒绝乱改"; exit 1
        fi
        printf '%s\n' "$_nk" > "$WORK/apikey.txt" 2>/dev/null
        chmod 0600 "$WORK/apikey.txt" 2>/dev/null
        sh "$MODDIR/service.sh" restart >/dev/null 2>&1
        echo "新密钥 $_nk（已重启；客户端和面板都要换成这个）"
        exit 0 ;;
    esac
    _k=$(key_show) || exit 1
    echo "访问密钥 $_k"
    echo "面板     $(url_of)"
    exit 0 ;;
open)
    PORT=$(wb2a_get_port)
    IP=$(wlan_ip)
    echo "局域网   http://${IP:-127.0.0.1}:$PORT/panel/"
    echo "设备本机 http://127.0.0.1:$PORT/panel/"
    _k=$(wb2a_apikey)
    [ -n "$_k" ] && echo "密钥     $_k（面板首次打开要填）"
    am start -a android.intent.action.VIEW -d "http://127.0.0.1:$PORT/panel/" >/dev/null 2>&1 &&
        echo "→ 已打开浏览器" || echo "→ 打开浏览器失败，手动访问上面的地址"
    exit 0 ;;
config)
    # 刷入时没法交互（安装器不给 stdin），配置只能装完后在终端改。
    # 非终端（Magisk 点「操作」按钮、被管道喂）直接打现状，不阻塞。
    if [ ! -t 0 ] && [ -z "$WB2A_ASSUME_TTY" ]; then
        echo "当前配置（要改请在终端跑 su -c 'sh $0 config'）"
        echo "  端口        $(wb2a_get_port)"
        echo "  监听        $(wb2a_listen_addr)"
        echo "  访问密钥    $(wb2a_apikey 2>/dev/null | sed 's/^\(sk-.\{4\}\).*/\1…（sh action.sh key 看全量）/')"
        echo "  自动更新    $(auto_status)"
        exit 0
    fi

    echo "== WorkBuddy2API 配置（直接回车＝保持现值）=="

    # 1) 端口
    _cp=$(wb2a_get_port)
    printf '端口 [%s]: ' "$_cp"
    read -r _v
    [ -n "$_v" ] || _v=$_cp
    case "$_v" in
        '' | *[!0-9]*) echo "  跳过：不是数字" ;;
        *) if [ "$_v" -ge 1024 ] 2>/dev/null && [ "$_v" -le 65535 ] 2>/dev/null; then
               printf '%s\n' "$_v" > "$WORK/port"; chmod 0600 "$WORK/port"
               echo "  端口 → $_v"
           else
               echo "  跳过：要 1024~65535"
           fi ;;
    esac

    # 2) 监听范围
    _cl=$(wb2a_listen_addr)
    if [ "$_cl" = "127.0.0.1" ]; then _cn=1; else _cn=2; fi
    echo "监听范围现在是 $( [ "$_cl" = "127.0.0.1" ] && echo '仅本机 127.0.0.1' || echo '局域网 0.0.0.0' )"
    printf '改成 [1=仅本机 2=局域网，回车不改]: '
    read -r _v
    case "$_v" in
        1) printf 'local\n' > "$WORK/listen"; echo "  → 仅本机" ;;
        2) printf 'lan\n' > "$WORK/listen"; echo "  → 局域网" ;;
        *) echo "  保持" ;;
    esac
    chmod 0600 "$WORK/listen" 2>/dev/null

    # 3) 自动更新
    echo "自动更新现在是 $(auto_status)"
    printf '自动更新钟点（HH:MM，输 off 关闭，回车不改）: '
    read -r _v
    case "$_v" in
        off | OFF) rm -f "$WORK/update.off"; set_kv WB2A_UPDATE_INTERVAL 0; echo "  已关闭" ;;
        [0-9]:[0-9][0-9] | [01][0-9]:[0-9][0-9] | 2[0-3]:[0-9][0-9])
            rm -f "$WORK/update.off"; set_kv WB2A_UPDATE_INTERVAL 86400; set_kv WB2A_UPDATE_AT "$_v"
            echo "  已设为每天 $_v" ;;
        '') echo "  保持 $(auto_status)" ;;
        *) echo "  跳过：格式要 HH:MM" ;;
    esac

    # 改完立刻把 config.json 的 listen 同步成新值：否则面板「配置」页会显示上一个端口，
    # 用户一保存就把旧端口写回去（下一轮启动又被 port 文件覆盖，看着像改了没用）。
    wb2a_force_listen "$(wb2a_listen_addr)" "$(wb2a_get_port)"

    echo "→ 已重启网关，端口/监听改动生效"
    sh "$MODDIR/service.sh" restart >/dev/null 2>&1
    sh "$MODDIR/refresh.sh" quiet >/dev/null 2>&1
    exit 0 ;;
auto)
    case "$2" in
    off)
        rm -f "$WORK/update.off"
        set_kv WB2A_UPDATE_INTERVAL 0
        sh "$MODDIR/service.sh" crontab >/dev/null 2>&1
        echo "自动更新已关闭（改回: sh $MODDIR/action.sh auto on）"
        exit 0 ;;
    on)
        rm -f "$WORK/update.off"
        set_kv WB2A_UPDATE_INTERVAL 86400
        sh "$MODDIR/service.sh" crontab >/dev/null 2>&1
        echo "自动更新已开启 → $(auto_status)"
        exit 0 ;;
    status)
        echo "$(auto_status)"
        exit 0 ;;
    [0-9]:[0-9][0-9] | [01][0-9]:[0-9][0-9] | 2[0-3]:[0-9][0-9])
        rm -f "$WORK/update.off"
        set_kv WB2A_UPDATE_AT "$2"
        # 改钟点要让定时器按新时刻重排：crontab 子命令 = 停旧定时器 + 起新的
        sh "$MODDIR/service.sh" crontab >/dev/null 2>&1
        echo "检查钟点已改为每天 $2 → $(auto_status)"
        exit 0 ;;
    esac
    echo "用法: sh $MODDIR/action.sh auto on | off | status | HH:MM"
    exit 1
    ;;
update)
    sh "$MODDIR/updater.sh" now
    exit $? ;;
log)
    tail -n "${2:-40}" "$WORK/run.log" 2>/dev/null || echo "没有 run.log"
    exit 0 ;;
sync)
    sh "$MODDIR/rt.sh" sync
    exit $? ;;
refresh)
    sh "$MODDIR/refresh.sh" "$2"
    exit 0 ;;
start)
    sh "$MODDIR/service.sh" start
    sh "$MODDIR/refresh.sh" quiet >/dev/null 2>&1
    exit 0 ;;
stop)
    sh "$MODDIR/service.sh" stop
    sh "$MODDIR/refresh.sh" quiet >/dev/null 2>&1
    echo "网关已停止"
    exit 0 ;;
restart)
    sh "$MODDIR/service.sh" restart >/dev/null 2>&1 &&
        echo "网关已重启（pid $(wb2a_pids | tr '\n' ' ' | sed 's/ *$//')）" ||
        echo "重启失败：端口 $(wb2a_get_port) 没有监听，详见 $(wb2a_data_dir)/run.log"
    exit 0 ;;
esac

# ---- 默认（点「执行」按钮）：重启网关进程 ----
# ⛔ 不再顺带开浏览器：那个动作归「打开」按钮（webroot/index.html）。
PORT=$(wb2a_get_port)
WL=$(wlan_ip)

# 管理模式（APatch）在脚本成功返回后**自己 popBackStack 退回列表**，输出页留不住，
# 所以结果必须额外推一条系统通知 —— 否则点完执行完全看不出来到底重启没重启。
notify() {
    command -v cmd >/dev/null 2>&1 || return 0
    cmd notification post -S bigtext -t 'WorkBuddy2API' wb2a_restart "$1" >/dev/null 2>&1 ||
        cmd notification post -t 'WorkBuddy2API' wb2a_restart "$1" >/dev/null 2>&1
}

echo "== WorkBuddy2API =="
if wb2a_running; then
    echo "重启前   运行中 pid=$(wb2a_pids | tr '\n' ' ' | sed 's/ *$//')"
else
    echo "重启前   未运行"
fi

# service.sh restart 自己会等到端口真的 LISTEN 才返回 0，这里直接用它的退出码，
# 不再另写一遍轮询（重复判活最容易和真实现状漂）。
if sh "$MODDIR/service.sh" restart >/dev/null 2>&1; then
    echo "重启后   运行中 pid=$(wb2a_pids | tr '\n' ' ' | sed 's/ *$//')（端口 $PORT 已监听）"
    notify "网关已重启 · 端口 $PORT · $(url_of)"
else
    echo "重启后   ! 失败：端口 $PORT 没有监听"
    echo "         详见 $(wb2a_data_dir)/run.log"
    notify "网关重启失败 · 端口 $PORT 没监听，详见 run.log"
fi
echo "面板     $(url_of "$WL")"
_k=$(wb2a_apikey)
[ -n "$_k" ] && echo "密钥     $_k"
echo "运行体   $(wb2a_bin)"
echo "自动更新 $(auto_status)"
echo ""
echo "打开面板 sh $MODDIR/action.sh open"
echo "改配置   sh $MODDIR/action.sh config"
