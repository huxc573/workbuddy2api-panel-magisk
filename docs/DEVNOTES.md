# 开发笔记

这些内容**不给用户看**，也不该出现在管理器更新弹窗里。
`CHANGELOG.md` 只管「这一版改了什么」，从第一行起就是版本条目 —— 因为 `update.json` 的
`changelog` 字段会让模块管理器把那个文件原样展现在更新提示里。

## 版本号规则

- 格式 `YY.MM.DD_序号`（北京时间），`versionCode = YYMMDD * 100 + 序号`。
- 例：`26.11.04_1` → `26110401`。
- 括号里是这一版打包的上游运行体版本，如 `26.10.29_1 (wb2a 2026.10.29.1418)`。
- 序号由 CI 算：取当天已有 release 的**最大序号 + 1**，不是第一个空位 —— 删过旧 Release 后空位会重号。

## 实测确认过的上游行为

用官方 windows-amd64 包在本机跑出来的结论，不是推测：

- 首启自动生成 `config.json`：`listen` 默认 `127.0.0.1:7863`，`api_key` 随机 `sk-` + base64url；
  启动横幅写明「来源 配置文件」。模块默认沿用 **7863**，安装时可切到 **52017**（与 NAS 上那套 wb2a 同端口）。
- **面板在 `/panel/`，根路径 `/` 返回 404**（所以模块里所有入口都写 `/panel/`）。
- `/panel/api/*` 无 Bearer 一律 401，带 `Authorization: Bearer <api_key>` 正常。
- `/healthz` 在「没有可用账号」时按设计回 **503**（`{"healthy":0,...}`），因此探活看 `/panel/` 的 200。
- 账号目录 `auths/` 是懒创建的，`data/` 启动即建 —— 模块两个都预建，省得首启权限/属主踩坑。

## 脚本命令一览

`action.sh`：`key`（看/换密钥）、`open`、`config`、`reset`（清账号）、`auto`、`log`、`sync`；
管理器点「执行」＝重启网关并推一条系统通知报结果。

`check.sh`：文件 / ELF 架构 / 端口监听 / 进程与看门狗 / DNS / 证书张数 / 面板探活 / 最近日志。

## 待验证

- 首版时手上没有 arm64 真机：脚本骨架沿用 [Agent2API-Magisk](https://github.com/huxc573/Agent2API-Magisk)
  （同一套启动/看门狗/rt/更新逻辑，已在真机跑过），Android 侧的路径与参数用上游 Windows 包实测对齐。
  上机后先跑 `sh /data/adb/modules/wb2a/check.sh`，有异常按里面各段定位。

## 发布口径

- `changelog` 字段指向 GitHub Pages 上的 `CHANGELOG.md`：`raw.githubusercontent.com` 在国内基本连不上。
- 发布一律 `--prerelease`，与上游 `misakano7545/workbuddy2api-panel` 口径一致。
- 管理器判断「有更新」只看 `update.json` 的 `versionCode`，与 Latest 标记无关。
