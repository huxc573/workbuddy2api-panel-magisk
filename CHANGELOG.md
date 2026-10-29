# CHANGELOG

版本号 `YY.MM.DD_序号`（北京时间），`versionCode = YYMMDD*100 + 序号`。
括号里是这一版打包的上游运行体版本。

## 26.10.29_1 (wb2a 2026.10.29.1418)

首个版本。

**做了什么**

- 把上游 Go 静态二进制装成开机自启的 Magisk 模块：`service.sh` 准备环境 → `watchdog.sh` 用 `wait` 守进程 →
  `service.sh run` exec 成网关；崩溃退避 1/2/5/10/30/60 秒重拉，不轮询、不占 CPU。
- 运行体走 `/data/adb/wb2a/rt/bin/`（`rt.sh` 原子同步 + `.rtver` 提交点）：升级刷完不用重启手机，
  下次启动发现「rt 比模块旧或缺戳」会自动重同步。
- 装机器只问三题（端口 / 监听范围 / 自动更新），音量键操作；已装机器先问「是否重新设置」，默认不动配置。
  首次安装会就地跑一次二进制生成 `config.json` 与随机 `api_key`，把密钥打印在安装日志里。
- Android 三件套在 `service.sh` 补齐：`WB2A_DNS`（无 `/etc/resolv.conf`）、`SSL_CERT_FILE`（Go 不读系统信任锚）、
  `ZONEINFO`+`TZ`（Android 的 tzdata 是打包格式）；`TMPDIR` 指到数据目录。
- `action.sh`：`key`（看/换密钥）、`open`、`config`、`reset`（清账号）、`auto`、`log`、`sync`；点「执行」重启并推通知。
- `check.sh` 自检：文件 / ELF 架构 / 端口监听 / 进程与看门狗 / DNS / 证书张数 / 面板探活 / 最近日志。
- `webroot/index.html`：显示地址 + 密钥（可复制），一键跳面板；另显示模块版本与运行体是否同步，
  并有「查看 Releases / 更新记录」按钮（仓库地址打包时注入）。
- `module.prop` 增加 `updateJson=`：管理器自己比 `versionCode`，有新版直接在模块列表标「有更新」并可一键安装；
  `update.json` 由 CI 每次发版重写，与包内 `module.prop` 同源。
- `updater.sh`：按上游 tag 挑最高版本 → 官方 `digest` 校 sha256 → 多源下载 → 验 aarch64 → 只换 `rt/bin` → 重启；
  睡到钟点才醒的定时器，关掉即不常驻。默认关闭。
- CI 每小时查上游，有新 tag 就出包并发正式 Release（自动标 Latest）；`UPSTREAM` 记账。

**实测确认过的上游行为**（用官方 windows-amd64 包在本机跑出来的，不是猜的）

- 首启自动生成 `config.json`：`listen` 默认 `127.0.0.1:7863`，`api_key` 随机 `sk-` + base64url；
  启动横幅写明「来源 配置文件」。模块默认沿用 **7863**，安装时可切到 **52017**（与 NAS 上那套 wb2a 同端口）。
- **面板在 `/panel/`，根路径 `/` 返回 404**（所以模块里所有入口都写 `/panel/`）。
- `/panel/api/*` 无 Bearer 一律 401，带 `Authorization: Bearer <api_key>` 正常。
- `/healthz` 在「没有可用账号」时按设计回 **503**（`{"healthy":0,...}`），因此探活看 `/panel/` 的 200。
- 账号目录 `auths/` 是懒创建的，`data/` 启动即建 —— 模块两个都预建，省得首启权限/属主踩坑。

**还没验证的**

- 本轮手上没有 arm64 真机：脚本骨架沿用 [Agent2API-Magisk](https://github.com/huxc573/Agent2API-Magisk)
  （同一套启动/看门狗/rt/更新逻辑，已在真机跑过），Android 侧的路径与参数用上游 Windows 包实测对齐。
  上机后先跑 `sh /data/adb/modules/wb2a/check.sh`，有异常按里面各段定位。
