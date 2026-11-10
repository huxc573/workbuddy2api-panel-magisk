**本模块 26.11.10_2**　发布于 19:15 UTC+8

**上游 2026.11.10.1436 的改动**

* fix(upstream): 资料接口空昵称不再静默成功，并兼容顶层平铺响应
* feat(panel): 账号导入支持多文件，选中先预览、确认再写入
* fix(responses): 工具调用缺函数名被丢弃时留 WARN，不再静默
* feat(server): 工具轮里「说一句就停」时试续一次，只采纳工具调用
* chore(diag): narration/toolonly 记录尾部片段与续写结果
* feat: 运行日志落盘+导出、上游劣化滑窗告警、选号策略可配
* fix(server): 直连传输层失败记到出口，不再按轮转逐号记连败
* feat: 额度窗口探针、号池分区、代理订阅导入
* revert(scope): 撤销号池分区，文本/媒体不再需要人工标注

完整对比：https://github.com/misakano7545/workbuddy2api-panel/compare/v2026.11.9.1131...v2026.11.10.1436
