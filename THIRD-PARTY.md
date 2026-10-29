# 第三方组件与致谢

本项目是 **WorkBuddy2API Panel 的 Android/Magisk 包装层**，不含服务本体源码。
Release 里打包的 `bin/wb2api` 全部来自上游项目，由 CI 从官方 release 的 `linux-arm64` 包原样取出，未做二进制修改。

## WorkBuddy2API Panel

- 仓库：<https://github.com/misakano7545/workbuddy2api-panel>
- 许可：**MIT License**，Copyright (c) 2026 Sliverkiss / linguo2625469 / misakano7545
- 血统：`Sliverkiss/workbuddy2api`（已删库）→ `linguo2625469/workbuddy2api-panel`（已停止维护）→ 本仓的直接上游

上游许可全文：

```
MIT License

Copyright (c) 2026 Sliverkiss (original project: https://github.com/Sliverkiss/workbuddy2api)
Copyright (c) 2026 linguo2625469 (fork: https://github.com/linguo2625469/workbuddy2api-panel)
Copyright (c) 2026 misakano7545 (this fork: https://github.com/misakano7545/workbuddy2api-panel)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 打包进模块的静态资源

| 文件 | 来源 | 许可 |
|---|---|---|
| `etc/ca-certificates.crt` | <https://curl.se/ca/cacert.pem>（Mozilla CA 根证书集） | MPL-2.0 |
| `zoneinfo/Asia/Shanghai` | IANA tzdata（取自 Debian/alpine 的 tzdata 包，未修改） | 公有领域 |

## 运行体依赖

`bin/wb2api` 是 `CGO_ENABLED=0` 的 Go 静态二进制，只依赖 Android 自带的内核与 `/system` 库，
不随包分发 glibc / libc++ 等第三方运行库（这也是它比 glibc 系模块小得多、也没有 loader 的原因）。
