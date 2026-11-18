**本模块 26.11.18_1**　发布于 12:37 UTC+8

**上游 2026.11.18.1058 的改动**

* fix(ci): 官方头对拍只对 UA 与 X-IDE-Version 按形态比版本号
* fix(narration): 结构未闭合用预告句指令、空救援不发第二次、无标点长正文只救承诺句
* fix(upstream): 深度规整 tools schema 并阻断 11129 误判连败降权 (Closes #250)
* fix(server): /v1/responses 保真回放思维链历史，修复长任务多轮「降智」
* fix(upstream): 早到结果重排按最近声明配对，跨轮复用 id 不再误挪
* fix(panel): 实时任务卡的启动位置、行渲染与上游请求量
* fix(narration): 等用户拍板的措辞在任何一句里都挡住救援（#209 回归）
* fix(server): 异步换段补齐 Close 回收、首帧窗口不补保活、失败落到下一条
* fix(upstream): tools schema 规整不碰数据关键字，依赖容器按属性名处理，null 取值保留
* fix(server,upstream): 首帧 error 帧里的请求级错误立即回 400，探测同样止损；11129 识别改走 hasBusinessCode
* fix(server): /v1/responses 回放补齐 Chat 形状 tool_call_id、跳过托管工具回执、不把 compaction 密文当摘要

详情点击打开后，查看更新记录。
