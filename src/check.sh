#!/system/bin/sh
# 安装后自检：在手机上跑一遍，把结果贴回来（不依赖管理器的 ui_print）。
# 用法: su -c "sh /data/adb/modules/wb2a/check.sh"

MODDIR="$(dirname "$(readlink -f "$0")")"
. "$MODDIR/lib.sh"
WORK=$(wb2a_data_dir)

echo "== 环境 =="
echo "abi: $(getprop ro.product.cpu.abi) / $(getprop ro.product.cpu.abilist)"
echo "android: $(getprop ro.build.version.release) (sdk $(getprop ro.build.version.sdk))"
echo "selinux: $(getenforce 2>/dev/null)"
echo "magisk: $(magisk -V 2>/dev/null || echo '非 magisk?')"
echo "uname: $(uname -m)"

echo "== 文件 =="
for f in etc/ca-certificates.crt zoneinfo/Asia/Shanghai webroot/index.html; do
    [ -e "$MODDIR/$f" ] && echo "  ok   $f ($(wc -c < "$MODDIR/$f" | tr -d ' ') B)" || echo "  MISS $f"
done
echo "  bin  $(wb2a_bin) ($([ -f "$(wb2a_bin)" ] && wc -c < "$(wb2a_bin)" | tr -d ' ' || echo 0) B)"
echo "  ELF  $(dd if="$(wb2a_bin)" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n') machine=$(dd if="$(wb2a_bin)" bs=1 skip=18 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')（要 7f454c46 / b700）"
echo "  运行体版本: rt=$(wb2a_rtver) 模块=$(wb2a_modver)$(wb2a_rt_need_sync && echo '  ⚠ 需要同步')"
echo "  数据目录: $WORK（$(df -h "$WORK" 2>/dev/null | awk 'NR==2{print $4" 可用"}')）"

echo "== 二进制自检（-h，预期打印用法后退出，不 segfault）=="
(
  cd "$WORK" 2>/dev/null || exit 0
  export HOME="$WORK" TMPDIR="$WORK/tmp"
  eval "$(wb2a_cert_env)"
  eval "$(wb2a_tz_env)"
  timeout 5 "$(wb2a_bin)" -h 2>&1 | head -n 6
)

echo "== 时区 / 证书 =="
# 只看「子进程实际能拿到什么」：这几个变量曾经漏了 export —— 端口照通，
# 但网关自己发 HTTPS 会报 x509: certificate signed by unknown authority。
( eval "$(wb2a_cert_env)"; eval "$(wb2a_tz_env)"; \
  env | grep -E '^(SSL_CERT_FILE|SSL_CERT_DIR|ZONEINFO|TZ)=' | sed 's/^/  /' )
[ -f "$MODDIR/zoneinfo/Asia/Shanghai" ] && echo "  zoneinfo 文件 $(wc -c < "$MODDIR/zoneinfo/Asia/Shanghai" | tr -d ' ') B"
[ -f "$MODDIR/etc/ca-certificates.crt" ] && echo "  根证书 $(grep -c 'BEGIN CERTIFICATE' "$MODDIR/etc/ca-certificates.crt" 2>/dev/null) 张"

echo "== 出站 DNS =="
echo "  net.dns1=$(getprop net.dns1) net.dns2=$(getprop net.dns2)"
echo "  本次会用: $(wb2a_dns)$( [ -z "$(wb2a_dns)" ] && echo '（config.json 里已自带 dns_servers）')"
[ -f /etc/resolv.conf ] && echo "  /etc/resolv.conf 存在（$(wc -l < /etc/resolv.conf) 行）" || echo "  /etc/resolv.conf 不存在（正常：Android 本来就没有，所以必须靠 WB2A_DNS）"

echo "== 端口监听 =="
PORT=$(wb2a_get_port)
echo "  port=$PORT listen=$(wb2a_listen_addr)"
(netstat -ltnp 2>/dev/null || ss -ltnp 2>/dev/null) | grep ":$PORT" || echo "  未监听（进程没起来）"

echo "== 进程 =="
wb2a_running && echo "  pid: $(wb2a_pids | tr '\n' ' ')" || echo "  未运行"
_w=$(wb2a_watchdog_pid) && echo "  看门狗: pid $_w" || echo "  看门狗: 未运行"
if [ -f "$WORK/update.timer.pid" ]; then
    _t=$(cat "$WORK/update.timer.pid" 2>/dev/null)
    if [ -n "$_t" ] && kill -0 "$_t" 2>/dev/null; then
        echo "  更新定时器: 在跑（pid $_t）"
    else
        echo "  更新定时器: pidfile 过期（下次 start 会重建）"
    fi
else
    echo "  更新定时器: 未启动（自动更新关着就是正常）"
fi

echo "== 模块列表显示的描述 =="
echo "  $(sed -n 's/^description=//p' "$MODDIR/module.prop" 2>/dev/null | tail -n1)"
echo "  写失败日志: $(tail -n1 "$WORK/desc.log" 2>/dev/null || echo '无')"

echo "== 配置 =="
echo "  config.json: $([ -f "$WORK/config.json" ] && echo 有 || echo '无（还没成功启动过）')"
echo "    listen      $(sed -n 's/^[[:space:]]*"listen"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$WORK/config.json" 2>/dev/null)"
echo "    api_key     $(wb2a_apikey 2>/dev/null | sed 's/^\(sk-.\{4\}\).*/\1…/')（sh action.sh key 看全量）"
echo "    dns_servers $(sed -n 's/^[[:space:]]*"dns_servers"[[:space:]]*:[[:space:]]*\(.*\),\{0,1\}$/\1/p' "$WORK/config.json" 2>/dev/null | head -n1)"
echo "    账号数      $(ls "$WORK"/auths/*.json 2>/dev/null | wc -l | tr -d ' ')"
echo "  env:"
sed 's/^/    /' "$WORK/env" 2>/dev/null | grep -v '^    #' || echo "    无 env"
echo "  update.conf:"
sed 's/^/    /' "$WORK/update.conf" 2>/dev/null | grep -v '^    #' || echo "    无 update.conf"
echo "  update.status: $(cat "$WORK/update.status" 2>/dev/null || echo '未检查过')"

echo "== 面板探活 =="
# /healthz 在「没有可用账号」时按设计回 503（healthy:0），所以探活看 /panel/ 的 200。
if command -v curl >/dev/null 2>&1; then
    curl -s --noproxy '*' --max-time 5 -o /dev/null -w "  面板 http %{http_code} (%{time_total}s)\n" "http://127.0.0.1:$PORT/panel/" 2>/dev/null
    echo "  健康 $(curl -s --noproxy '*' --max-time 5 "http://127.0.0.1:$PORT/healthz" 2>/dev/null | head -c 160)"
elif command -v wget >/dev/null 2>&1; then
    wget -q -T 5 -O /dev/null "http://127.0.0.1:$PORT/panel/" && echo "  探活 OK" || echo "  探活失败"
else
    echo "  无 curl/wget，跳过"
fi

echo "== 最近日志 =="
tail -n 25 "$WORK/run.log" 2>/dev/null || echo "  无 run.log"
