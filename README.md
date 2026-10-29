# WorkBuddy2API-Magisk

在 Android（arm64）上把 [WorkBuddy2API Panel](https://github.com/misakano7545/workbuddy2api-panel) 跑成开机自启的 Magisk 模块。
上游是**单个 Go 静态二进制**（`CGO_ENABLED=0`），所以不需要 chroot、不需要 glibc loader、不需要 python——
直接把官方 release 里的 `wb2api` 放进模块，配上环境就能跑。

- 适用 APatch / Magisk / KernelSU
- 仓库名沿用社区习惯：上游名 + `-Magisk`（同 `OpenList-Magisk`、`box_for_magisk`）

> **上游与致谢**：服务本体、Web 面板、账号池与任务体系全部来自
> [misakano7545/workbuddy2api-panel](https://github.com/misakano7545/workbuddy2api-panel)（**MIT**）。
> 本项目只做「把它装进 Android」这层壳——数据目录布局、启动/看门狗、Android 特有的三件套
> （DNS / 根证书 / 时区）、WebUI 入口页、打包与 CI。Release 里的运行体由 CI 从上游 release 原样取出，未改二进制。
> 详见 [THIRD-PARTY.md](THIRD-PARTY.md)。

## 安装

1. 从 [Releases](../../releases) 下最上面那个 zip（**全部以 pre-release 发布**，页面没有 Latest，按时间倒序取第一行），在管理器里刷入；
2. 按音量键答三题（音量下＝下一项，音量上＝确认）——端口（7863 ↔ 52019，首项是当前值）、
   监听范围（局域网 `0.0.0.0` / 仅本机 `127.0.0.1`）、自动更新（开/关，首次默认关）；
   已装过的机器会**先多问一题**「是否重新设置」，音量上直接确认＝配置一个字都不动；
3. 刷完会打印**访问密钥**（`sk-…`）。**首次安装要重启手机**：刷 zip 只解到 `modules_update/`，
   模块目录要重启才整体替换，安装器会提示「首次安装，重启设备后自动运行」；
   升级安装不用重启——`customize.sh` 会把 `bin/` 同步到 `/data/adb/wb2a/rt/`，再用新脚本停旧起新；
4. 打开 `http://127.0.0.1:<端口>/panel/`，第一次会弹「密钥门」，把第 3 步的密钥贴进去。

> ⚠ 面板在 `/panel/`，根路径 `/` 是 **404**（实测上游行为，不是模块的锅）。
> 密钥随时可看：`su -c "sh /data/adb/modules/wb2a/action.sh key"`，或在管理器的「打开」页里复制。

## 管理器里的三个按钮

| 按钮 | 来源 | 行为 |
|---|---|---|
| **打开** | `webroot/index.html` | 读 `/data/adb/wb2a/port` 与 `apikey.txt`，显示地址+密钥（可复制），再跳面板 |
| **执行** | `action.sh` | 重启网关进程，打印密钥，并推一条系统通知报结果 |
| **卸载** | 管理器自带 | 走 `uninstall.sh`，只删自己那三个写死路径 |

- 「打开」依赖管理器的模块 WebUI：APatch（≥10568）、KernelSU 及各分支原生支持；Magisk 上游没有 WebView，装 KsuWebUI 或 MMRL 才会出现。没有也不影响，`sh action.sh open` 用系统浏览器打开。
- ⚠ 点「执行」成功后管理器会自己退回列表（APatch `ExecuteAPMActionScreen` 里的 `popBackStack()`，脚本控制不了）。结果看通知，或看模块说明行：`运行中 · IP:端口 · 23:25 启动 ｜ 执行=重启进程`。

## 常用命令

```sh
M=/data/adb/modules/wb2a
su -c "sh $M/check.sh"            # 自检：文件 / ELF / 端口 / 进程 / DNS / 证书 / 面板探活
su -c "sh $M/action.sh key"       # 看访问密钥（key new 重新生成并重启）
su -c "sh $M/action.sh open"      # 打印地址+密钥并用系统浏览器打开
su -c "sh $M/action.sh config"    # 改端口、监听范围、自动更新钟点（会重启网关）
su -c "sh $M/action.sh reset yes" # 清空已登录账号（先列清单，加 yes 才真删；配置与密钥不动）
su -c "sh $M/action.sh auto on|off|status|04:00"   # 自动更新
su -c "sh $M/service.sh stop|start|restart"
su -c "sh $M/rt.sh status"        # rt/ 与模块目录各是哪个版本
su -c "tail -50 /data/adb/wb2a/run.log"
```

卸载会清干净，但只碰 `/data/adb/modules/wb2a`、`/data/adb/modules_update/wb2a`、`/data/adb/wb2a` 三个逐字写死的路径（`uninstall.sh` 的 `safe_rm` 白名单）。
想重装保留账号与密钥：卸载前 `touch /data/adb/wb2a/keep`。

## 数据落在哪

| 位置 | 内容 |
|---|---|
| `/data/adb/wb2a/rt/bin/wb2api` | 运行体（权威位置，见下节） |
| `/data/adb/wb2a/config.json` | 上游配置：`api_key` / 池参数 / 排程 / 提示词策略…（面板里改，热生效） |
| `/data/adb/wb2a/auths/*.json` | 账号凭证（面板「添加账号」写这里） |
| `/data/adb/wb2a/data/` | 池状态、用量、积分历史、请求日志 |
| `/data/adb/wb2a/port`、`listen` | 模块的端口与监听范围（生效值以它为准） |
| `/data/adb/wb2a/run.log` | 网关 stdout/stderr + 看门狗日志 |
| `模块目录/bin/` | 同份二进制的副本：首次安装的来源 + rt 缺失时的回退 |

## 为什么升级不用重启手机

`/data/adb/modules/wb2a` 由管理器管，刷 zip 只解到 `modules_update/`，**重启才整体替换**——运行体放那儿，
跑着的自然还是旧二进制。所以会变的部分搬到数据目录：

`rt.sh sync` 用 `cp → .new → mv` 原子替换，全部到位后**最后**写 `rt/.rtver` 当提交点；断电半份的话，
下次启动发现「rt 比模块旧或缺戳」就整份重同步。代价：多占约 12 MB。

## Android 上必须自己补的三件事

上游是按 Linux 容器/Debian 写的，直接扔进 Android 会在这三处翻车，模块在 `service.sh` 里补掉：

| 问题 | 现象 | 模块怎么处理 |
|---|---|---|
| **没有 `/etc/resolv.conf`** | Go 的纯解析器读不到就退回 `127.0.0.1:53`（netd 不听这个口）⇒ 所有域名解析失败，签到/对话/更新全挂 | 启动时算 `WB2A_DNS`：`net.dns1/2` → 取不到用 `223.5.5.5,119.29.29.29`；`config.json` 里手填过 `dns_servers` 就不插手 |
| **没有 Go 认的根证书** | `x509: certificate signed by unknown authority`（Go 只读 `/etc/ssl/certs`，不读 Android 的 `/system/etc/security/cacerts`） | 模块带一份 Mozilla 根证书，`SSL_CERT_FILE` 指过去；缺失时退回系统 cacerts 目录 |
| **tzdata 是打包格式** | `TZ=Asia/Shanghai` 静默回落 UTC ⇒ 用量/请求日志按天分桶整体偏 8 小时 | 模块带 `zoneinfo/Asia/Shanghai`，`ZONEINFO` + `TZ` 双指（日界判定本身用固定 +08:00，不受影响） |

另外 `TMPDIR` 指到 `/data/adb/wb2a/tmp`——Go 默认写 `/tmp`，Android 没有这个目录。

## 进程模型

```
service.sh start ──setsid──> watchdog.sh ──fork──> service.sh run ──exec──> wb2api
                                   └── wait（阻塞，零 CPU） ─────────────┘
```

网关是看门狗的直接子进程，`wait` 等它：活着 0 tick，一死立刻重拉。存活 <60 秒算异常，退避 1/2/5/10/30/60 秒。
⛔ 不用 `sleep+pgrep` 轮询，也不用 `setsid` 起网关（脱离父子关系会让 `wait` 立即返回，变成每秒重启）。

## 自动更新

**默认关闭**——GitHub 在部分网络下不可达，开着就是每天 04:00 试一次运气。开启后：取 `releases` 列表挑最高 tag
→ 逐段比版本（防降级）→ 取官方 `digest` 校 sha256 → 多源下载（`gh-proxy.com → ghproxy.net → ghfast.top → 直连`）
→ 验 aarch64 → 解压出 `wb2api` → 只写 `rt/bin` → 重启网关。

```sh
su -c "sh $M/action.sh auto on|off|status"
su -c "sh $M/action.sh auto 03:30"
su -c "sh $M/updater.sh now"        # 立刻查一次
```

- 上游 tag 是时间戳制（`v2026.10.29.1418`），`/releases/latest` 能用，但模块按列表挑最高版本更稳（不依赖 latest 的语义）。
- 解压用 `unzip`（toybox / busybox 都带）；两者都没有的机器会明确报「无 unzip」而不是假装成功。
- 定时器是「睡到点才醒」的进程，不是轮询；关掉时它根本不启动。

**和面板自带「软件更新」的关系**：面板里那个按钮是上游自带的，会自替换 `os.Executable()`，在模块里就是 `rt/bin/wb2api`，能用。
但刷模块包时若模块版本号更高，`rt.sh` 会把 `rt/bin` 重同步回包里那版——「刷包」永远赢，避免两套更新打架。

## 已知取舍

- 多占约 12 MB（rt 副本）。
- 仅 arm64（上游 release 也只发 amd64/arm64）。
- 面板是 **HTTP**，靠 `api_key` 鉴权；选「局域网」时同网段任何人都能打开登录页（没有密钥进不了 API）。只想本机用就选「仅本机」。
- 上游是个人维护的活跃分支，接口随时可能变；账号风控风险自负。
- 模块不代管上游的签到/成长任务排程——那些由网关自己按 `config.json` 跑（时区已修正）。

## 开发

| 路径 | 说明 |
|---|---|
| `src/` | 脚本壳（`module.prop`、`*.sh`、`webroot/`） |
| `runtime/wb2api` | 运行体，**不入库**，由 `scripts/ci/fetch-runtime.sh` 从上游 release 取出 |
| `assets/` | 根证书（Mozilla bundle）、`zoneinfo/Asia/Shanghai` |
| `build_module.py` | 组装 zip：映射目录、校验 ELF 必须 aarch64、统一 LF、脚本 0755 |
| `.github/workflows/build.yml` | 每 3 小时查上游，有新版自动出包并发 **pre-release**（不占 Latest） |

版本号是日期制 `YY.MM.DD_序号`，`versionCode = YYMMDD*100 + 序号`：

```bash
scripts/ci/fetch-runtime.sh v2026.10.29.1418   # 本地取运行体（需要 gh / curl / unzip）
UPSTREAM_TAG=v2026.10.29.1418 python build_module.py 26.10.29_1
```

## 许可

本仓库 **MIT**；随包分发的上游二进制（MIT）、Mozilla CA 证书（MPL-2.0）、tzdata（公有领域）见 [THIRD-PARTY.md](THIRD-PARTY.md)。
