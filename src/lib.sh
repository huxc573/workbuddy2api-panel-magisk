#!/system/bin/sh
# 公共工具：customize.sh / service.sh / watchdog.sh / rt.sh / action.sh / check.sh /
# refresh.sh / updater.sh 都会 source 它。被 source 不执行，所以不需要可执行位。

# ---------- 路径 ----------
# MODDIR 由调用方设置（customize.sh 里是 $MODPATH，其余由 $0 推导）
DATA_DIR_DEFAULT=/data/adb/wb2a

# busybox：Magisk / KernelSU / APatch 三种根方案位置各不相同。
# ⛔ 别只写死 /data/adb/magisk/busybox —— 有的机器是 APatch，只有 /data/adb/ap/bin/busybox。
WB2A_BUSYBOX=""
for _bb in /data/adb/ap/bin/busybox /data/adb/magisk/busybox /data/adb/ksu/bin/busybox; do
    [ -x "$_bb" ] && { WB2A_BUSYBOX=$_bb; break; }
done

# 数据目录：只认 /data/adb/wb2a（及其子目录）。
# ⛔ 这个值会被 rm -rf 用，绝不能由外部随意指定 —— 一旦变成空/根目录就是灾难。
# 本地测试用环境变量 WB2A_DATA_DIR 旁路（只在测试脚本里设）。
wb2a_data_dir() {
    if [ -n "$WB2A_DATA_DIR" ]; then
        echo "$WB2A_DATA_DIR"
        return
    fi
    _d=$(cat "$MODDIR/.datadir" 2>/dev/null | head -n1 | tr -d '\r')
    case "$_d" in
        /data/adb/wb2a | /data/adb/wb2a/*) : ;;
        *) _d=$DATA_DIR_DEFAULT ;;
    esac
    echo "$_d"
}

# ---------- 二进制 ----------
WB2A_ID=wb2a
WB2A_BIN_NAME=wb2api
# 模块默认 52017（跟 NAS 上那套 wb2a 用同一个端口，口径统一好记）；备选＝上游官方 7863
WB2A_DEFAULT_PORT=52017
WB2A_ALT_PORT=7863

# 运行体的权威位置＝数据目录下的 rt/。
# 为什么不用模块目录：/data/adb/modules/wb2a 是 Magisk 的地盘，只有**下次启动**才会被
#   modules_update 整体替换；运行体放里面，刷完 zip 不重启就还是旧二进制。
#   /data/adb/wb2a 是模块自己的数据，Magisk 从不碰 ⇒ 同步过去立刻生效。逻辑在 rt.sh。
wb2a_rt() { echo "$(wb2a_data_dir)/rt"; }

# 二进制：rt 优先，缺失时回退模块目录（保证任何情况下都起得来）
wb2a_bin() {
    _ab="$(wb2a_data_dir)/rt/bin/$WB2A_BIN_NAME"
    if [ -f "$_ab" ]; then echo "$_ab"; else echo "$MODDIR/bin/$WB2A_BIN_NAME"; fi
}

# rt 的版本戳（= 同步时源 module.prop 的 versionCode）。rt.sh sync 的最后一步才写它，
# 所以它等价于「这次同步完整跑完了」的提交点。读不到一律当 0（= 不可信，需要重同步）。
wb2a_rtver() {
    _rv=$(sed -n '1p' "$(wb2a_rt)/.rtver" 2>/dev/null | tr -dc '0-9')
    case "$_rv" in '' | *[!0-9]*) _rv=0 ;; esac
    echo "$_rv"
}

# 模块自带 module.prop 的 versionCode；读不到当 0
wb2a_modver() {
    _mv=$(sed -n 's/^versionCode=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1 | tr -dc '0-9')
    case "$_mv" in '' | *[!0-9]*) _mv=0 ;; esac
    echo "$_mv"
}

# 是否需要把模块目录的 bin/ 重新同步进 rt（0=需要 1=不需要）。
# 三种情况要同步：rt 里没有二进制 / 没有版本戳（同步被打断过） / rt 比模块旧。
# ⚠ 判据必须是「rt 比模块旧」而不是「不相等」：刷完 zip 但还没重启时，
#   rt 已经是新版、模块目录还是旧版，用「不相等」会把 rt 反而降级回旧版。
wb2a_rt_need_sync() {
    [ -f "$(wb2a_rt)/bin/$WB2A_BIN_NAME" ] || return 0
    _nsv=$(wb2a_rtver)
    [ "$_nsv" -gt 0 ] 2>/dev/null || return 0
    _nmv=$(wb2a_modver)
    [ "$_nmv" -gt "$_nsv" ] 2>/dev/null || return 1
    return 0
}

# ---------- 配置 ----------
# 自动更新开关：update.off 文件 或 WB2A_UPDATE_INTERVAL=0 都算关闭。
# 放 lib.sh 是因为 service.sh（要不要起定时器）、updater.sh、customize.sh 三处都要判。
wb2a_update_on() {
    [ -f "$(wb2a_data_dir)/update.off" ] && return 1
    _u=$(sed -n 's/^WB2A_UPDATE_INTERVAL=\([0-9][0-9]*\).*/\1/p' "$(wb2a_data_dir)/update.conf" 2>/dev/null | head -n1)
    # 没有配置文件＝默认开启
    [ -n "$_u" ] || return 0
    [ "$_u" -gt 0 ] 2>/dev/null
}

# 监听地址：$WORK/listen 里的值（lan→0.0.0.0，local→127.0.0.1），缺省 0.0.0.0
wb2a_listen_addr() {
    _la=$(cat "$(wb2a_data_dir)/listen" 2>/dev/null | head -n1 | tr -d '\r')
    case "$_la" in
        127.0.0.1 | local) echo 127.0.0.1 ;;
        0.0.0.0 | lan | '') echo 0.0.0.0 ;;
        *) echo 0.0.0.0 ;;
    esac
}

# 端口优先级：$WORK/port（模块的权威值）> config.json 的 listen > 默认 52017
wb2a_get_port() {
    _pf="$(wb2a_data_dir)/port"
    _q=""
    [ -r "$_pf" ] && _q=$(tr -dc '0-9' < "$_pf" 2>/dev/null | head -n1)
    case "$_q" in
        '') : ;;
        *[!0-9]*) : ;;
        [1-9]*) [ "$_q" -ge 1024 ] 2>/dev/null && [ "$_q" -le 65535 ] 2>/dev/null && { echo "$_q"; return; } ;;
    esac
    _cfg="$(wb2a_data_dir)/config.json"
    _p=$(sed -n 's/^[[:space:]]*"listen"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_cfg" 2>/dev/null | head -n1)
    case "$_p" in
        *:*) _p=${_p##*:} ;;
    esac
    case "$_p" in
        '' | *[!0-9]*) _p=$WB2A_DEFAULT_PORT ;;
    esac
    echo "$_p"
}

# 启动时把 config.json 的 listen 校正成 <地址>:<端口>。
# 二进制自己也会读 WB2A_LISTEN（env 优先），两边一致才不会出现「面板显示 127.0.0.1、
# 实际却在 0.0.0.0」这种对不上的情况。
wb2a_force_listen() {
    _fa=$1
    _fp=$2
    _cfg="$(wb2a_data_dir)/config.json"
    [ -n "$_fp" ] && [ -f "$_cfg" ] || return 0
    case "$_fp" in '' | *[!0-9]*) return 0 ;; esac
    [ -n "$_fa" ] || _fa=0.0.0.0
    if grep -q '"listen"' "$_cfg" 2>/dev/null; then
        sed -i "s|\"listen\"\([[:space:]]*:[[:space:]]*\)\"[^\"]*\"|\"listen\"\1\"$_fa:$_fp\"|" "$_cfg" 2>/dev/null
    fi
}

# 访问密钥（网关与面板共用同一个 Bearer）。首启由二进制自己生成随机值写进 config.json，
# 这里只读，绝不改。读不到返回空。
wb2a_apikey() {
    sed -n 's/^[[:space:]]*"api_key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$(wb2a_data_dir)/config.json" 2>/dev/null | head -n1
}

# ---------- 网络 ----------
# 单个接口的 IPv4；先 ip -4，再退 ifconfig（两种 ifconfig 输出都认）
iface_ip() {
    _a=$(ip -4 -o addr show "$1" 2>/dev/null | awk 'NR==1{split($4,x,"/"); print x[1]}')
    [ -n "$_a" ] && { echo "$_a"; return; }
    ifconfig "$1" 2>/dev/null | sed -n \
        -e 's/.*[[:space:]]inet addr:\([0-9][0-9.]*\).*/\1/p' \
        -e 's/.*[[:space:]]inet[[:space:]][[:space:]]*\([0-9][0-9.]*\).*/\1/p' | head -n1
}

# 取一个 PC 能访问到的 IPv4：只认 wlan0 / ap*，故意不碰 rmnet/ccmni 蜂窝口
# （蜂窝地址 PC 连不上，显示它比不显示更误导）
wlan_ip() {
    _v=$(iface_ip wlan0)
    [ -n "$_v" ] && { echo "$_v"; return; }
    for _d in $(ip -4 -o addr show 2>/dev/null | awk '{print $2}' | grep -E '^(wlan|ap)') \
              $(ifconfig -a 2>/dev/null | sed -n 's/^\(\(wlan\|ap\)[a-zA-Z0-9_]*\)[[:space:]:].*/\1/p'); do
        [ "$_d" = wlan0 ] && continue
        _v=$(iface_ip "$_d")
        [ -n "$_v" ] && { echo "$_v"; return; }
    done
}

# 出站 DNS。
# ⚠ Android 没有 /etc/resolv.conf：Go 的纯 Go 解析器读不到就会退回 127.0.0.1:53
#   （netd 不在那儿监听）⇒ 所有域名解析失败。所以必须显式给上游客户端一个解析器。
# 顺序：config.json 里用户自己填过 dns_servers ⇒ 不插手；否则 net.dns1/2 ⇒ 公共 DNS。
wb2a_dns() {
    _cfg="$(wb2a_data_dir)/config.json"
    # 数组可能是单行 `[]`，也可能是面板写出来的多行；两种都要认。
    # 取「从 dns_servers 那行到第一个 ]」这一段，里面有数字就说明用户配了。
    if [ -f "$_cfg" ]; then
        _cd=$(awk '/"dns_servers"/{f=1} f{printf "%s", $0} f&&/\]/{exit}' "$_cfg" 2>/dev/null)
        case "$_cd" in
            *[0-9]*) return 0 ;;
        esac
    fi
    _out=""
    for _k in net.dns1 net.dns2; do
        _v=$(getprop "$_k" 2>/dev/null | tr -d ' \r')
        case "$_v" in
            '' | 0.0.0.0 | ::) continue ;;
        esac
        case " $_out " in
            *" $_v "*) continue ;;
        esac
        _out="${_out:+$_out,}$_v"
    done
    [ -n "$_out" ] || _out=223.5.5.5,119.29.29.29
    echo "$_out"
}

# ---------- 进程 ----------
# 判活 = 找 argv 里带 <运行体路径> 的进程。
# ⛔ 绝不要写成「遍历 /proc + 每个进程 fork 一次 tr/cat」：千级进程时单次十几秒 CPU，
#    放进轮询里就是单核跑满。pgrep -f 单次 ~70ms，结果完全一致。
_wb2a_pids_one() {
    # $1 = cmdline 里要匹配的完整路径
    if command -v pgrep >/dev/null 2>&1; then
        for _p in $(pgrep -f "$1" 2>/dev/null); do
            # 排掉自己：调用方命令行里也可能带这个路径，不能把自己当网关（会误杀）
            case "$_p" in
                "$$" | "$PPID") continue ;;
            esac
            echo "$_p"
        done
        return 0
    fi
    # 没有 pgrep 的老 ROM：用 ps 一次读全表（1 次 fork）
    ps -A -o PID,ARGS 2>/dev/null | while read -r _pid _rest; do
        case "$_pid" in
            '' | *[!0-9]* | "$$" | "$PPID") continue ;;
        esac
        case " $_rest" in
            *"$1"*) echo "$_pid" ;;
        esac
    done
}

wb2a_pids() {
    # 四条路都要匹配：
    #   rt/                          运行体权威位置
    #   $MODDIR/bin/                 旧装法、或 rt 还没同步时的回退
    #   /data/adb/modules/wb2a/bin/  ⛔ 和 $MODDIR 不是一回事：customize.sh 里
    #                                $MODDIR=$MODPATH=…/modules_update/wb2a，
    #                                从那儿调 stop 必须能认出正跑着的旧网关
    #   modules_update/              安装期从临时目录拉起的进程
    for _q in "$(wb2a_data_dir)/rt/bin/$WB2A_BIN_NAME" \
              "$MODDIR/bin/$WB2A_BIN_NAME" \
              "/data/adb/modules/$WB2A_ID/bin/$WB2A_BIN_NAME" \
              "/data/adb/modules_update/$WB2A_ID/bin/$WB2A_BIN_NAME"; do
        [ -n "$_q" ] || continue
        _wb2a_pids_one "$_q"
    done | awk 'NF && !_s[$0]++'
}

wb2a_running() {
    [ -n "$(wb2a_pids)" ]
}

# 端口是否真的在 LISTEN。
# 「进程还在」≠「服务可用」：网关可能起来了但端口没绑上（配置错、端口被占）。
# 只读 /proc/net/tcp{,6}，一次 awk 判完，不连网络、不依赖 curl。
#   /proc/net/tcp 的 $4 是状态，0A = LISTEN；$2 是 local_address，形如 00000000:1EB7
wb2a_port_listen() {
    _pt=$1
    case "$_pt" in '' | *[!0-9]*) return 1 ;; esac
    _hx=$(printf '%04X' "$_pt" 2>/dev/null)
    [ -n "$_hx" ] || return 1
    if command -v awk >/dev/null 2>&1; then
        awk -v h="$_hx" '
            FNR == 1 { next }
            $4 == "0A" { n = split($2, a, ":"); if (a[n] == h) { f = 1; exit } }
            END { exit(f ? 0 : 1) }
        ' /proc/net/tcp /proc/net/tcp6 2>/dev/null && return 0
        return 1
    fi
    # 兜底：没有 awk 的机器用 grep 粗判（同一条记录里本地端口 + 状态 0A）
    for _f in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$_f" ] || continue
        grep -q ":$hx .* 0A " "$_f" 2>/dev/null && return 0
    done
    return 1
}

# 看门狗的 pid；没在跑则返回非 0。pid 会被复用，必须校验 cmdline。
wb2a_watchdog_pid() {
    _wp=$(cat "$(wb2a_data_dir)/watchdog.pid" 2>/dev/null)
    case "$_wp" in '' | *[!0-9]*) return 1 ;; esac
    kill -0 "$_wp" 2>/dev/null || return 1
    grep -q 'watchdog\.sh' "/proc/$_wp/cmdline" 2>/dev/null || return 1
    echo "$_wp"
}

# ---------- 证书 ----------
# Go 的 crypto/x509 在 Linux 上只认几个固定路径（/etc/ssl/certs/…），Android 都没有
# （系统的信任锚在 /system/etc/security/cacerts，Go 不读它）⇒ 必须显式指 SSL_CERT_FILE。
# 模块自带一份 Mozilla 根证书；缺失时退回系统 cacerts 目录（Go 支持 SSL_CERT_DIR 读散装 PEM）。
wb2a_cert_env() {
    if [ -f "$MODDIR/etc/ca-certificates.crt" ]; then
        echo "SSL_CERT_FILE=$MODDIR/etc/ca-certificates.crt"
        echo "SSL_CERT_DIR=$MODDIR/etc/certs"
        return
    fi
    for _d in /system/etc/security/cacerts \
              /apex/com.android.conscrypt/cacerts; do
        if [ -d "$_d" ]; then
            echo "SSL_CERT_DIR=$_d"
            return
        fi
    done
}

# ---------- 时区 ----------
# Android 的 tzdata 是 /system/usr/share/zoneinfo/tzdata 这个打包格式，Go 不认。
# 模块自带一份 Asia/Shanghai 并用 ZONEINFO 指过去；TZ 给名字，Go 优先查 $ZONEINFO。
# 网关自己做日界判定用固定 +08:00（不依赖时区），这里影响的是日志/用量分桶的本地时间。
wb2a_tz_env() {
    if [ -f "$MODDIR/zoneinfo/Asia/Shanghai" ]; then
        echo "ZONEINFO=$MODDIR/zoneinfo"
        echo "TZ=Asia/Shanghai"
    else
        echo "TZ=CST-8"
    fi
}

# ---------- 日志 ----------
# 超限只留尾部；调用前必须保证没有写入者（只在冷启动时调用）
wb2a_rotate() {
    _f=$1
    _max=$2
    [ -f "$_f" ] || return 0
    [ "$(wc -c < "$_f" 2>/dev/null | tr -d ' ')" -gt "$_max" ] 2>/dev/null || return 0
    tail -c $((_max / 4)) "$_f" > "$_f.tmp" 2>/dev/null && mv -f "$_f.tmp" "$_f"
}
