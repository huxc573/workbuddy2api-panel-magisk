#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""组装 wb2a（WorkBuddy2API）Magisk 模块 zip。

用法: python build_module.py [版本号]
  - 源码壳:   src/        (module.prop / *.sh / webroot/)
  - 运行体:   runtime/wb2api      (由 scripts/ci/fetch-runtime.sh 从上游 release 抽出)
  - 静态资源: assets/     (根证书、Asia/Shanghai)
  - 产物:     publish/WorkBuddy2API-Magisk-v<版本>.zip

运行体不入库（约 12 MB），CI 从上游 Release 的 linux-arm64 包原样取出。
"""
import os
import re
import shutil
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "src")
RUNTIME = os.path.join(HERE, "runtime")
ASSETS = os.path.join(HERE, "assets")
PUB = os.path.join(HERE, "publish")
STAGE = os.path.join(HERE, ".stage")

BIN_NAME = "wb2api"

# 运行体 + 静态资源的落点（模块内相对路径）
FILES = [
    (os.path.join(RUNTIME, BIN_NAME), "bin/" + BIN_NAME),
    (os.path.join(ASSETS, "ca-certificates.crt"), "etc/ca-certificates.crt"),
    (os.path.join(ASSETS, "zoneinfo", "Asia", "Shanghai"), "zoneinfo/Asia/Shanghai"),
]

SHELLS = ["service.sh", "watchdog.sh", "rt.sh", "refresh.sh",
          "updater.sh", "action.sh", "uninstall.sh"]
EXEC = set(SHELLS) | {"customize.sh", "check.sh"}

EM_AARCH64 = 0xB7   # 防呆：曾经把 amd64 的二进制打进包里


def elf_machine(path):
    with open(path, "rb") as f:
        head = f.read(20)
    if head[:4] != b"\x7fELF":
        return None
    return int.from_bytes(head[18:20], "little")


def version_code(ver):
    """版本号 → versionCode（必须是递增整数，模块管理器只认这个）。

    `26.10.29_1` = 2026-10-29 当天的第 1 个版本 → 26102900 + 1 = 26102901。
    """
    m = re.match(r"^(\d{2})\.(\d{2})\.(\d{2})_(\d{1,2})$", ver)
    if m:
        yy, mm, dd, n = m.groups()
        return int(yy + mm + dd) * 100 + int(n)
    parts = (ver.split(".") + ["0", "0"])[:3]
    return int(parts[0]) * 10000 + int(parts[1]) * 100 + int(parts[2])


def main():
    ver = sys.argv[1] if len(sys.argv) > 1 else "26.10.29_1"
    up = os.environ.get("UPSTREAM_TAG", "").strip().lstrip("v")

    os.makedirs(PUB, exist_ok=True)
    shutil.rmtree(STAGE, ignore_errors=True)
    os.makedirs(STAGE)

    # 1) 壳（src 下的文件 + webroot 整目录）
    for name in sorted(os.listdir(SRC)):
        s = os.path.join(SRC, name)
        if os.path.isfile(s):
            shutil.copy2(s, os.path.join(STAGE, name))
    wr = os.path.join(SRC, "webroot")
    if not os.path.isdir(wr):
        sys.exit("缺少 src/webroot（管理器里的「打开」按钮入口）")
    shutil.copytree(wr, os.path.join(STAGE, "webroot"))

    # 1.5) 注入本仓库地址：WebUI 的「查看 Releases」+ module.prop 的 updateJson。
    #      CI 传 $WB2A_SELF_REPO=${{ github.repository }}；本地构建用下面的默认值。
    #      updateJson 走 GitHub Pages（raw.githubusercontent 在国内基本连不上，Pages 能连）。
    #      用二进制替换，免得被换行/编码处理搅乱；漏替换会在打包前直接报错。
    self_repo = os.environ.get("WB2A_SELF_REPO", "huxc573/workbuddy2api-panel-magisk").strip()
    _owner, _, _name = self_repo.partition("/")
    # 只给主机+路径，scheme 由模板里的 https:// 提供（早先这里带 scheme，结果拼出 https://https://）
    pages = ("%s.github.io/%s" % (_owner, _name)) if _name else ""
    subs = [(b"__WB2A_REPO__", self_repo.encode("utf-8")),
            (b"__WB2A_PAGES__", pages.encode("utf-8"))]
    for rel in ("webroot/index.html", "module.prop"):
        p = os.path.join(STAGE, rel.replace("/", os.sep))
        with open(p, "rb") as f:
            data = f.read()
        for tok, val in subs:
            data = data.replace(tok, val)
        with open(p, "wb") as f:
            f.write(data)

    # 2) 运行体与静态资源
    for src, rel in FILES:
        if not os.path.isfile(src):
            sys.exit("缺少文件: %s（先跑 scripts/ci/fetch-runtime.sh）" % src)
        if rel.startswith("bin/"):
            m = elf_machine(src)
            if m != EM_AARCH64:
                sys.exit("架构不对: %s machine=%s（要 aarch64 0xB7）"
                         % (src, hex(m) if m else "非ELF"))
        dst = os.path.join(STAGE, rel.replace("/", os.sep))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)

    # 3) module.prop：只换版本号，保留上游版本标注
    mp = os.path.join(STAGE, "module.prop")
    with open(mp, "r", encoding="utf-8") as f:
        raw = f.read()
    mark = ""
    if up:
        mark = "(wb2a %s)" % up
    else:
        m = re.search(r"\(wb2a [^)]*\)", raw)
        if m:
            mark = m.group(0)
    out = []
    for ln in raw.splitlines():
        if ln.startswith("version="):
            out.append(("version=%s %s" % (ver, mark)).strip() if mark else ("version=%s" % ver))
        elif ln.startswith("versionCode="):
            out.append("versionCode=%d" % version_code(ver))
        else:
            out.append(ln)
    with open(mp, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out) + "\n")

    # 4) 换行统一 LF（Android 上 CRLF 会让 sh 报错）。
    #    只处理文本后缀：bin/wb2api 与 zoneinfo/Asia/Shanghai 没有后缀，不会被碰到。
    for root, _dirs, files in os.walk(STAGE):
        for fn in files:
            if not fn.endswith((".sh", ".prop", ".html", ".md", ".json", ".crt")):
                continue
            p = os.path.join(root, fn)
            with open(p, "rb") as f:
                data = f.read().replace(b"\r\n", b"\n")
            with open(p, "wb") as f:
                f.write(data)

    zip_path = os.path.join(PUB, "WorkBuddy2API-Magisk-v%s.zip" % ver)
    if os.path.exists(zip_path):
        os.remove(zip_path)

    # 占位符漏替换 = updateJson / WebUI 指向不存在的仓库，直接拦下
    for root, _dirs, files in os.walk(STAGE):
        for fn in files:
            if fn.endswith((".html", ".prop")):
                p = os.path.join(root, fn)
                with open(p, "rb") as f:
                    data = f.read()
                for tok, _v in subs:
                    if tok in data:
                        sys.exit("占位符 %s 未替换: %s" % (tok.decode(), p))

    # URL 拼接自检：漏了/多了一层 scheme 这种错肉眼很容易放过
    with open(os.path.join(STAGE, "module.prop"), "r", encoding="utf-8") as f:
        for ln in f:
            if ln.startswith("updateJson="):
                u = ln.strip().split("=", 1)[1]
                if not u.startswith("https://") or u.count("https://") > 1 or "//" in u[8:]:
                    sys.exit("updateJson 拼坏了: %s" % u)

    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for root, dirs, files in os.walk(STAGE):
            dirs.sort()
            for fn in sorted(files):
                full = os.path.join(root, fn)
                rel = os.path.relpath(full, STAGE).replace(os.sep, "/")
                zi = zipfile.ZipInfo(rel, date_time=(1980, 1, 1, 0, 0, 0))
                zi.compress_type = zipfile.ZIP_DEFLATED
                mode = 0o755 if (rel in EXEC or rel.startswith("bin/")) else 0o644
                zi.external_attr = (mode & 0xFFFF) << 16
                with open(full, "rb") as f:
                    z.writestr(zi, f.read())

    size = os.path.getsize(zip_path)
    print("产物: %s" % zip_path)
    print("大小: %.2f MB" % (size / 1048576.0))
    print("上游: %s" % (up or "(module.prop 原值)"))
    print("仓库: %s" % self_repo)
    with zipfile.ZipFile(zip_path) as z:
        names = z.namelist()
        print("条目数: %d" % len(names))
        print("顶层: %s" % ", ".join(sorted({n.split("/")[0] for n in names})))


if __name__ == "__main__":
    main()
