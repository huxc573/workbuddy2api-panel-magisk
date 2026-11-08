**本模块 26.11.08_1**　发布于 18:39 UTC+8

**上游 2026.11.8.1203 的改动**

* fix(videos,images): 回读成品直链只认产物域、不跟随重定向、不静默截断，/content 不依赖内存快照
* fix(responses): image_generation 探测用 prompt 参数、出图前过积分闸、出图管道与 images 对齐
* fix(server): /v1/search 把上游卡片改写为等价检索链接（仅 DSH）
* feat(reqlog,panel): 请求记录全链路区分降级前后模型（补 #128/#137 的 reqlog 半边）
* fix(panel): 统一控件尺寸与表格内距，修掉配置页两处错位
* fix(panel): 清除筛选没清掉状态偏好，刷新页面又选回「错误」
