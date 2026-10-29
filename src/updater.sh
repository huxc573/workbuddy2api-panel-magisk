#!/system/bin/sh
# 自动更新：查 GitHub Releases（misakano7545/workbuddy2api-panel），拉官方
# wb2api-panel-<ver>-linux-arm64.zip，用 GitHub API 的 assets[].digest 校验 sha256，
# 解压出 wb2api 后只替换 rt/bin/（运行体权威位置，见 rt.sh），再重启网关。
#
# ⛔ 不要写成 `while :; do … sleep 60; done`：那是纯白耗电（每 60 秒 fork 一次算钟点）。
# ⛔ 也不要指望 crond：Android 没有 crond。
# ✅ tick 是一次性的：判断该不该跑，跑完退出。
# ✅ daemon 是「睡到目标时刻再醒」：一天最多 1 次真干活，单次睡眠上限 30 分钟。
#
# 用法：
#   sh updater.sh now      立即检查（不管钟点）
#   sh updater.sh tick     按钟点判断该不该查（跑完退出）
#   sh updater.sh daemon   常驻定时器（service.sh 拉起，睡到点才醒）
#   sh updater.sh status   看开关与上次结果

MODDIR="${WB2A_UPDATE_MODDIR:-$(dirname "$(readlink -f "$0")")}"
# 兜底：测试旁路被误设成空/根目录时不做任何删除
case "$MODDIR" in
    '' | / | /data | /data/adb | /sdcard | /storage* | /system* | /data/local/tmp)
        MODDIR=$(dirname "$(readlink -f "$0")") ;;
esac
. "$MODDIR/lib.sh"

WORK="${WB2A_UPDATE_WORK:-$(wb2a_data_dir)}"
case "$WORK" in
    '' | / | /data | /data/adb | /sdcard | /storage* | /system* | /data/local/tmp)
        echo "[wb2a] 数据目录异常（$WORK），拒绝执行" >&2; exit 1 ;;
esac

RT="$WORK/rt"
REPO="${WB2A_UPDATE_REPO:-misakano7545/workbuddy2api-panel}"
GH="${WB2A_UPDATE_API:-https://api.github.com}"
STAMP="$WORK/update.stamp"
LOG="$WORK/update.log"
STATUS="$WORK/update.status"
OFF="$WORK/update.off"
VERF="$WORK/upstream.version"
CONF="$WORK/update.conf"

# 上游的 release 里资产名带版本号，只能按 tag 现拼
asset_name() { printf 'wb2api-panel-%s-linux-arm64.zip' "${1#v}"; }

# ---- 基础工具 ----
have() { command -v "$1" >/dev/null 2>&1; }

if command -v sha256sum >/dev/null 2>&1; then
    SHA="sha256sum"
elif [ -n "$WB2A_BUSYBOX" ] && "$WB2A_BUSYBOX" sha256sum </dev/null >/dev/null 2>&1; then
    SHA="$WB2A_BUSYBOX sha256sum"
elif command -v openssl >/dev/null 2>&1; then
    SHA="openssl dgst -sha256"
elif [ -n "$WB2A_BUSYBOX" ] && "$WB2A_BUSYBOX" openssl dgst -sha256 </dev/null >/dev/null 2>&1; then
    SHA="$WB2A_BUSYBOX openssl dgst -sha256"
else
    SHA=""
fi

# 解压：toybox / busybox 都有 unzip；都没有就只能放弃（不做自研解压）
UNZIP=""
if command -v unzip >/dev/null 2>&1; then
    UNZIP="unzip"
elif [ -n "$WB2A_BUSYBOX" ] && "$WB2A_BUSYBOX" unzip -h >/dev/null 2>&1; then
    UNZIP="$WB2A_BUSYBOX unzip"
fi

say() {
    _t=$(date '+%Y-%m-%d %H:%M:%S')
    printf '%s %s\n' "$_t" "$*"
    printf '%s %s\n' "$_t" "$*" >> "$LOG" 2>/dev/null
}
mark() { printf '%s %s\n' "$(date '+%m-%d %H:%M')" "$*" > "$STATUS" 2>/dev/null; }

sha_of() {
    [ -n "$SHA" ] || { printf '\n'; return; }
    case "$SHA" in
        *openssl*) $SHA "$1" 2>/dev/null | awk '{print $NF}' | tr -d '\r' ;;
        *)         $SHA "$1" 2>/dev/null | awk '{print $1}' | tr -d '\r' ;;
    esac
}

# 下载：curl -> busybox wget -> wget。GitHub 会 302 到 objects.githubusercontent.com，必须跟。
# $3 非空时带 Authorization（API 吃更高限流；资产走 302 不需要）
# $4 = 最长秒数（默认 900）；$5 非空时启用慢速放弃（<8KB/s 持续 30 秒就掐掉换源）
fetch() {
    _u=$1; _o=$2; _h=$3; _t=${4:-900}; _sl=$5
    rm -f "$_o"
    if have curl; then
        _cs="--connect-timeout 20 --max-time $_t"
        [ -n "$_sl" ] && _cs="$_cs --speed-limit 8192 --speed-time 30"
        if [ -n "$_h" ]; then
            curl -fsSL $_cs -H "Authorization: Bearer $_h" -o "$_o" "$_u" && return 0
        else
            curl -fsSL $_cs -o "$_o" "$_u" && return 0
        fi
    elif [ -n "$WB2A_BUSYBOX" ]; then
        if [ -n "$_h" ]; then
            "$WB2A_BUSYBOX" wget -q -T 120 -O "$_o" --header "Authorization: Bearer $_h" "$_u" && return 0
        else
            "$WB2A_BUSYBOX" wget -q -T 120 -O "$_o" "$_u" && return 0
        fi
    elif have wget; then
        wget -q --timeout=120 -O "$_o" "$_u" && return 0
    fi
    [ -s "$_o" ] || { rm -f "$_o"; return 1; }
    return 0
}

# ---- 配置读取 ----
conf_get() {
    [ -f "$CONF" ] || return 0
    sed -n "s/^[[:space:]]*$1=\(.*\)/\1/p" "$CONF" | head -n1 | tr -d '\r'
}

# 开关：update.off 文件 或 WB2A_UPDATE_INTERVAL=0
is_on() {
    [ -f "$OFF" ] && return 1
    _i=$(conf_get WB2A_UPDATE_INTERVAL)
    [ -n "$_i" ] || _i=86400
    [ "$_i" = "0" ] && return 1
    return 0
}

# 每天的执行钟点 WB2A_UPDATE_AT=HH:MM，格式不对退回 04:00
check_at() {
    _t=$(conf_get WB2A_UPDATE_AT)
    case "$_t" in
        [0-9]:[0-9][0-9] | [01][0-9]:[0-9][0-9] | 2[0-3]:[0-9][0-9]) : ;;
        *) _t=04:00 ;;
    esac
    echo "$_t"
}

# 今天该查的时刻（epoch）
today_at() {
    _h=$((10#${1%%:*}))
    _m=$((10#${1##*:}))
    _today=$(date +%Y-%m-%d 2>/dev/null)
    _s=""
    if [ -n "$_today" ]; then
        _s=$(date -d "$_today $_h:$_m:00" +%s 2>/dev/null)
        if [ -z "$_s" ] && [ -n "$WB2A_BUSYBOX" ]; then
            _s=$("$WB2A_BUSYBOX" date -d "$_today $_h:$_m:00" +%s 2>/dev/null)
        fi
    fi
    case "$_s" in '' | *[!0-9]*) _s="" ;; esac
    [ -n "$_s" ] || _s=$(($(date +%s 2>/dev/null || echo 0) + 60))
    echo "$_s"
}

gh_token() { echo "${GITHUB_TOKEN:-}"; }

# 版本比较：$1 严格大于 $2 才返回 0。上游是纯数字时间戳（2026.10.29.1418），
# 按点分段逐段比数值，最多 4 段；非数字段当 0。
# ⚠ 必须有这一步：API 可能返回陈旧 release，只判「tag 相等」会拿旧版覆盖新版。
vercmp_gt() {
    [ "$1" = "$2" ] && return 1
    _va=$(printf '%s' "$1" | sed 's/^[vV]//')
    _vb=$(printf '%s' "$2" | sed 's/^[vV]//')
    _k=1
    while [ "$_k" -le 4 ]; do
        _x=$(printf '%s' "$_va" | cut -d. -f"$_k" 2>/dev/null)
        _y=$(printf '%s' "$_vb" | cut -d. -f"$_k" 2>/dev/null)
        case "$_x" in '' | *[!0-9]*) _x=0 ;; esac
        case "$_y" in '' | *[!0-9]*) _y=0 ;; esac
        [ "$_x" -gt "$_y" ] && return 0
        [ "$_x" -lt "$_y" ] && return 1
        _k=$((_k + 1))
    done
    return 1
}

# 从 releases 列表里挑最高版本（跳过 draft）。$1=json 文件 → 输出 tag
pick_tag() {
    _pc="$WORK/.cand"
    tr -d ' \n\r\t' < "$1" | sed 's/},{/}\n{/g' \
        | sed -n 's/.*"tag_name":"\([^"]*\)".*"draft":\(true\|false\).*/\1 \2/p' > "$_pc" 2>/dev/null
    _best=""
    while read -r _t _dr; do
        [ -n "$_t" ] || continue
        [ "$_dr" = "false" ] || continue
        if [ -z "$_best" ] || vercmp_gt "$_t" "$_best"; then _best=$_t; fi
    done < "$_pc"
    rm -f "$_pc"
    printf '%s' "$_best"
}

# 取指定 tag 的 arm64 资产：输出 "资产名<TAB>sha256"
release_asset() {
    _tag=$1
    _tf="$WORK/.rel1.json"
    fetch "$GH/repos/$REPO/releases/tags/$_tag" "$_tf" "$(gh_token)" || { rm -f "$_tf"; return 1; }
    _an=$(asset_name "$_tag")
    _line=$(tr -d ' \n\r\t' < "$_tf" | sed 's/},{/}\n{/g' | grep -F "\"name\":\"$_an\"" | head -n1)
    rm -f "$_tf"
    [ -n "$_line" ] || return 1
    _sha=$(printf '%s' "$_line" | sed -n 's/.*"digest":"sha256:\([0-9a-f]\{64\}\)".*/\1/p')
    printf '%s\t%s\n' "$_an" "$_sha"
}

sources() {
    _s=$(conf_get WB2A_UPDATE_SOURCES)
    [ -n "$_s" ] || _s="${WB2A_UPDATE_SOURCES:-}"
    [ -n "$_s" ] || _s="https://gh-proxy.com/,https://ghproxy.net/,https://ghfast.top/,"
    printf '%s\n' "$_s" | tr ',' ' '
}

fetch_asset() {
    _url=$1; _out=$2; _want=$3
    for _p in $(sources); do
        if [ -n "$_p" ]; then
            _u="${_p%/}/$_url"
            _label=$_p
        else
            _u=$_url
            _label="github 直连"
        fi
        say "  试源 $_label"
        if [ -n "$_p" ]; then
            _ok=$(fetch "$_u" "$_out" "" 480 slow && echo 1)
        else
            _ok=$(fetch "$_u" "$_out" "" 1200 && echo 1)
        fi
        if [ -n "$_ok" ]; then
            if [ -z "$_want" ]; then
                say "  没有官方摘要可比，接受该源（无法校验）"
                return 0
            fi
            _got=$(sha_of "$_out")
            if [ "$_got" = "$_want" ]; then
                say "  sha256 校验通过"
                return 0
            fi
            say "  校验不符（得 $_got），换下一个源"
            rm -f "$_out"
        else
            say "  连不上/超时，换下一个源"
        fi
    done
    return 1
}

# ELF 必须是 aarch64（防上游误传 amd64 把模块跑废）
is_arm64() {
    _magic=$(dd if="$1" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [ "$_magic" = "7f454c46" ] || return 1
    _m=$(dd if="$1" bs=1 skip=18 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [ "$_m" = "b700" ]
}

check_once() {
    if ! is_on; then
        say "自动更新已关闭"
        mark "自动更新已关闭"
        return 2
    fi
    [ -n "$SHA" ] || { say "没有 sha256 工具，无法校验，跳过"; mark "失败：无 sha256 工具"; return 1; }
    [ -n "$UNZIP" ] || { say "本机没有 unzip（toybox/busybox 都没有），跳过"; mark "失败：无 unzip"; return 1; }

    wb2a_rotate "$LOG" 262144

    say "检查更新（$REPO）"
    _tf="$WORK/.rel.json"
    fetch "$GH/repos/$REPO/releases?per_page=15" "$_tf" "$(gh_token)" || {
        rm -f "$_tf"; say "取不到 release 列表（网络不通/被墙/限流）"; mark "失败：取 release 失败"; return 1; }
    _tag=$(pick_tag "$_tf")
    rm -f "$_tf"
    [ -n "$_tag" ] || { say "release 列表里没有可用 tag"; mark "失败：无 tag"; return 1; }
    say "最新 $REPO → $_tag"

    _old=$(tr -d ' \r\n' < "$VERF" 2>/dev/null)
    [ -n "$_old" ] || _old=$(sed -n 's/.*(wb2a \([^)]*\)).*/\1/p' "$MODDIR/module.prop" 2>/dev/null | head -n1)
    if [ "$_tag" = "$_old" ] || [ "$_tag" = "v$_old" ]; then
        say "已是最新（$_tag）"
        mark "已是最新 $_tag"
        return 0
    fi
    if [ -n "$_old" ] && ! vercmp_gt "$_tag" "$_old"; then
        say "远端 $_tag 不比本地 $_old 新，忽略"
        mark "已是最新 $_old（远端 $_tag）"
        return 0
    fi

    _ai=$(release_asset "$_tag") || { say "取不到 $_tag 的 arm64 资产"; mark "失败：无 arm64 资产"; return 1; }
    _an=$(printf '%s' "$_ai" | cut -f1)
    _want=$(printf '%s' "$_ai" | cut -f2)
    [ -n "$_an" ] || { say "资产名为空"; mark "失败：资产解析失败"; return 1; }

    say "发现新版 $_tag（当前 ${_old:-未知}）→ 下载 $_an"
    _zip="$WORK/.dl.zip"
    fetch_asset "https://github.com/$REPO/releases/download/$_tag/$_an" "$_zip" "$_want" || {
        say "所有源都失败（或校验都没过）"; mark "失败：下载/校验"; rm -f "$_zip"; return 1
    }
    [ -s "$_zip" ] || { say "下载结果为空"; rm -f "$_zip"; mark "失败：下载为空"; return 1; }

    _st="$WORK/.staged"
    rm -rf "$_st"; mkdir -p "$_st"
    if ! $UNZIP -o -q "$_zip" -d "$_st" 2>/dev/null; then
        say "解压失败（包不完整？）"; rm -f "$_zip"; rm -rf "$_st"; mark "失败：解压"; return 1
    fi
    rm -f "$_zip"

    _newbin="$_st/$WB2A_BIN_NAME"
    if [ ! -s "$_newbin" ]; then
        say "包里找不到 $WB2A_BIN_NAME"; rm -rf "$_st"; mark "失败：包结构异常"; return 1
    fi
    if ! is_arm64 "$_newbin"; then
        say "新二进制不是 aarch64，拒绝替换"; rm -rf "$_st"; mark "失败：架构不符"; return 1
    fi

    chmod 0755 "$_newbin"
    mkdir -p "$RT/bin" 2>/dev/null
    if ! cp -f "$_newbin" "$RT/bin/$WB2A_BIN_NAME.new" 2>/dev/null; then
        say "写二进制失败（$RT 不可写/空间不足？）"; rm -rf "$_st"; mark "失败：替换失败"; return 1
    fi
    mv -f "$RT/bin/$WB2A_BIN_NAME.new" "$RT/bin/$WB2A_BIN_NAME" || {
        say "替换二进制失败"; rm -rf "$_st"; mark "失败：替换失败"; return 1
    }
    rm -rf "$_st"
    say "二进制已替换（$(wc -c < "$RT/bin/$WB2A_BIN_NAME" | tr -d ' ') 字节）"

    printf '%s\n' "$_tag" > "$VERF"

    _rs=$(conf_get WB2A_UPDATE_RESTART)
    [ -n "$_rs" ] || _rs=1
    if [ "$_rs" = "0" ]; then
        say "文件已更新；WB2A_UPDATE_RESTART=0，未重启（下次启动生效）"
        mark "已更新 $_tag（待下次启动生效）"
        return 0
    fi

    sh "$MODDIR/service.sh" restart >/dev/null 2>&1
    sh "$MODDIR/refresh.sh" quiet >/dev/null 2>&1
    say "已重启网关"
    mark "已更新 $_tag，已重启"
    return 10
}

# tick：按钟点判断今天该不该查。给开机流程 / daemon 调用，跑完就退出。
tick() {
    is_on || exit 2
    _now=$(date +%s 2>/dev/null)
    case "$_now" in '' | *[!0-9]*) exit 1 ;; esac
    _slot=$(today_at "$(check_at)")
    _last=$(tr -dc '0-9' < "$STAMP" 2>/dev/null)
    [ -n "$_last" ] || _last=0
    # 还没到点、或今天已经查过 → 什么都不做
    [ "$_now" -ge "$_slot" ] || exit 0
    [ "$_last" -lt "$_slot" ] || exit 0

    check_once
    _rc=$?
    # 成功失败都记「今天这个钟点查过了」。
    # ⛔ 别写成 slot-21600（「6 小时后重试」）：daemon 每 30 分钟醒一次都会重跑 tick，
    #    那个值让 _last < _slot 恒成立 ⇒ 实际变成每 30 分钟联网重试，整夜反复唤醒。
    echo "$_slot" > "$STAMP" 2>/dev/null
    exit "$_rc"
}

mkdir -p "$WORK" 2>/dev/null

# daemon：睡到下一个目标时刻再醒，醒了跑一次 tick。
# 单次睡眠封顶 1800 秒：手机深睡会把 sleep 拉长、用户也可能改钟点，
# 每 30 分钟重新校准一次，代价可忽略（sleep 期间不占 CPU、不阻休眠）。
daemon() {
    # 关掉自动更新就别常驻：否则整夜挂着一个只会睡的进程
    if ! wb2a_update_on; then
        rm -f "$WORK/update.timer.pid" 2>/dev/null
        exit 0
    fi
    echo $$ > "$WORK/update.timer.pid"
    _sp=""
    trap 'rm -f "$WORK/update.timer.pid" 2>/dev/null
          [ -n "$_sp" ] && kill "$_sp" 2>/dev/null
          exit 0' TERM INT HUP
    while :; do
        sh "$MODDIR/updater.sh" tick >/dev/null 2>&1
        _now=$(date +%s 2>/dev/null)
        case "$_now" in
            '' | *[!0-9]*) _wait=300 ;;
            *)
                _slot=$(today_at "$(check_at)")
                _last=$(tr -dc '0-9' < "$STAMP" 2>/dev/null)
                [ -n "$_last" ] || _last=0
                if [ "$_last" -ge "$_slot" ]; then
                    _next=$((_slot + 86400))     # 今天查过了，等明天
                else
                    _next=$_slot
                fi
                _wait=$((_next - _now))
                [ "$_wait" -lt 60 ] && _wait=60
                [ "$_wait" -gt 1800 ] && _wait=1800
                ;;
        esac
        # 后台 sleep + wait：这样 TERM 到达时能把 sleep 一起收掉。
        # ⛔ 直接 sleep 前台阻塞的话，只杀 daemon 会留一个跑满 1800 秒的孤儿 sleep。
        sleep "$_wait" &
        _sp=$!
        wait "$_sp" 2>/dev/null
        _sp=""
    done
}

case "$1" in
    now|check)   check_once; exit $? ;;
    daemon)      daemon ;;                    # 常驻定时器（service.sh 拉起）
    tick)        tick ;;                      # tick 自带 exit
    status)
        if is_on; then echo "开启（每天 $(check_at)）"; else echo "关闭"; fi
        [ -f "$STATUS" ] && echo "上次 $(cat "$STATUS")"
        exit 0 ;;
    '')
        tick ;;                               # 无参 = 一次性 tick
    *)
        echo "用法: sh updater.sh now | tick | status"
        exit 1 ;;
esac
