**上游 2026.11.4.1120 的改动**

* fix(panel): 按域降级键命中与锁池表「已路由至」标注
* fix(proxypool): 经代理的 HTTPS 先建隧道再走指纹握手，修 SOCKS 绕过代理直连与 HTTP 代理丢指纹
* feat(panel): 默认网关档位可在面板配置，并提示哪些模型会降级
* fix(panel): 企业版账号不自动签到/不自动执行成长任务
* fix(pool): 到期加权不再低于不开时的权重，窗口默认放宽到 30 天
* fix: Compose 默认使用 GHCR 镜像，修复自建版本更新误报
* fix(upstream): 流式请求关闭前读掉流尾、Close 幂等，修上游连接无法复用
* fix(reqlog): 超长事件行不再让整个事件日志页读不出来
* fix(server): 上游心跳帧会吞掉紧随其后的 Responses 事件
