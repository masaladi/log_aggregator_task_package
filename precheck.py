#!/usr/bin/env python3
"""发布前静态预检（无 Docker、无常驻进程、无网络，可安全进入提交包）。

对任务包做静态一致性断言，任何一项失败都以非零码退出。
动态验证（镜像构建、Oracle/NOP 对照、性能基准）为包外流程，
方法与记录见 README.md「发布前回归清单」与 benchmarks.md。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))

REQUIRED_FILES = [
    "instruction.md",
    "task.toml",
    "README.md",
    "benchmarks.md",
    "precheck.py",
    "docs/scoring-rationale.md",
    "environment/Dockerfile",
    "environment/app.py",
    "environment/config.json",
    "environment/entrypoint.sh",
    "environment/gen_baseline.py",
    "environment/squatter.py",
    "environment/portmon.py",
    "solution/solve.sh",
    "tests/test.sh",
]

# R1 硬门槛触发模式：任何提交包文件中不得出现
FORBIDDEN_PATTERNS = [
    r"docker\s+run\s+-d",
    r"sleep\s+infinity",
    r"nohup.*&\s*$",
]

# 三方（题面/README/判分口径文档）必须同时出现的数字与口径
MUST_ALIGN = {
    "instruction.md": ["24 秒", "30 秒", "1.5 秒", "855 万", "900 万行"],
    "README.md": ["24 秒", "30 秒", "1.5 秒", "900 万行", "benchmarks.md"],
    "benchmarks.md": ["24s", "30s"],
}

# 判分脚本中不允许出现的过期数字（历次迭代残留检查）
STALE_NUMBERS = ["3,800,146", "8,550,015", "390 MB", "9.24s", "75 秒", "45 秒", "60 秒"]


def read(path):
    with open(os.path.join(ROOT, path), "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def main():
    errors = []

    for rel in REQUIRED_FILES:
        if not os.path.isfile(os.path.join(ROOT, rel)):
            errors.append("missing required file: %s" % rel)

    texts = {}
    for rel in REQUIRED_FILES:
        p = os.path.join(ROOT, rel)
        if os.path.isfile(p):
            texts[rel] = read(rel)

    # 硬门槛模式扫描
    for rel, text in texts.items():
        for pat in FORBIDDEN_PATTERNS:
            if re.search(pat, text, re.M):
                errors.append("forbidden pattern %r in %s" % (pat, rel))

    # R1 non_terminating_process 模式：shell 脚本中不得有行尾后台启动（&）
    for rel in REQUIRED_FILES:
        if rel.endswith(".sh"):
            for i, line in enumerate(texts.get(rel, "").splitlines(), 1):
                stripped = line.rstrip()
                if stripped.endswith("&") and not stripped.endswith("&&"):
                    errors.append("background launch (trailing &) in %s:%d" % (rel, i))

    # 三方数字对齐
    for rel, needles in MUST_ALIGN.items():
        text = texts.get(rel, "")
        for n in needles:
            if n not in text:
                errors.append("alignment: %r missing in %s" % (n, rel))

    # 过期数字残留（跳过本文件：其模式表本身就包含这些字面值）
    for rel, text in texts.items():
        if rel == "precheck.py":
            continue
        for n in STALE_NUMBERS:
            if n in text:
                errors.append("stale number %r in %s" % (n, rel))

    # 判分结构不变式：3 项 x 1/3
    t = texts.get("tests/test.sh", "")
    if 'TOTAL = 3' not in t and "TOTAL=3" not in t.replace(" ", ""):
        errors.append("tests/test.sh: judging structure (TOTAL=3) not found")
    if "REWARD_FILE" not in t:
        errors.append("tests/test.sh: REWARD_FILE handling missing")

    if errors:
        print("PRECHECK FAILED (%d):" % len(errors))
        for e in errors:
            print("  - %s" % e)
        return 1
    print("PRECHECK OK: %d files, no forbidden patterns, numbers aligned." % len(REQUIRED_FILES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
