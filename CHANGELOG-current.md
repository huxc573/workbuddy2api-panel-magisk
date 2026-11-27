**本模块 26.11.27_1**　发布于 11:00 UTC+8

**上游 2026.11.27.1055 的改动**

* fix(embeddings): 请求级错误码改成 input_too_large、日志带上游 code（#290）
* fix(upstream): tool 配对吸收 hub #26 三修：相邻批合并、孤儿不遮挡、重复结果去重
* fix(upstream): TraeCode 自述句进脱敏表（参考 hub 2026-11-24 CN 池实测）
* docs(readme): 补 embeddings 单条 input 上限与 input_too_large（#290）
* fix(embeddings): 8 MiB 请求体 413 的错误码改成 payload_too_large（#290）
* feat(panel): 模型规则页账号列右侧显示积分余额（#291）
* feat(panel): 积分到期分布每行可展开看每段金额（#294）
* fix(server): zero-tool-calls 收尾日志带上 tok/think
* fix(server,pool,scheduler): 截断上游回执按 rune 边界，别再劈开汉字
* feat(prompt): 可选把 system 挪到消息末尾，救回被每轮变 system 打碎的前缀缓存（issue #293）
* feat(upstream): 数出「缺 calls 包裹的 invoke 块」，先量发生率不猜着转
* chore(autobot): 补 3304711297/workbuddy2api 到参考仓库清单

详情点击打开后，查看更新记录。
