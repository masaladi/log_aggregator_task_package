#!/usr/bin/env python3
"""生成基线数据文件：900 万行混合形态 JSONL。

形态设计的目的：让"用正则从原始字节抓字段"的取巧实现在正确性上必然失败。
  - 嵌套 ctx.level  -> 正则会重复计数 ERROR
  - 科学计数法/负数 -> 正则抓不全数值
  - 缺字段          -> 正则的计数分母与真值不一致

注意：文件末尾**不带换行符**（真实写入端停在最后一次换行落盘之前），
基线以一个"尚未提交"的末行结尾。生成结束时按"已提交行"口径打印
有效记录数，供题面盘点记录引用。
"""
import random
import re
import sys

N = 9_000_000
OUT = "/var/lib/log-aggregator/logs.jsonl"
TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

LEVELS = ["INFO", "WARN", "ERROR", "DEBUG"]
WEIGHT = [0.62, 0.15, 0.13, 0.10]

# 非法时间戳的四种形态：空格分隔 / 带毫秒 / 带时区偏移 / 小写 z
BAD_TS = [
    lambda ts: ts[:10] + " " + ts[11:19],
    lambda ts: ts[:-1] + ".500Z",
    lambda ts: ts[:-1] + "+08:00",
    lambda ts: ts.lower(),
]

SCIENTIFIC = ["-2.5e1", "1.02e2", "-7", "3e0", "1.5e-1"]


def main():
    random.seed(20261023)
    buf = []
    with open(OUT, "wb") as f:  # 二进制写入，保证各平台换行一致
        for i in range(N):
            r = random.random()
            lvl = random.choices(LEVELS, WEIGHT)[0]
            hh = i % 24
            mm = (i // 24) % 60
            ss = (i // 1440) % 60
            ts = "2026-10-23T%02d:%02d:%02dZ" % (hh, mm, ss)
            svc = "svc-%d" % (i % 503)

            if r < 0.05:
                # 非法时间戳：必须被静默过滤
                ts = BAD_TS[i % 4](ts)
                buf.append('{"timestamp":"%s","level":"%s","service":"%s","latency_ms":%.3f}'
                           % (ts, lvl, svc, random.uniform(0.5, 900.0)))
            else:
                if r < 0.25:
                    # 嵌套对象里也带 level：只认顶层
                    buf.append('{"timestamp":"%s","level":"%s","service":"%s","latency_ms":%.3f,'
                               '"ctx":{"level":"ERROR","retries":%d}}'
                               % (ts, lvl, svc, random.uniform(0.5, 900.0), i % 5))
                elif r < 0.33:
                    # 缺 latency_ms -> 按 0.0 计入平均
                    buf.append('{"timestamp":"%s","level":"%s","service":"%s"}' % (ts, lvl, svc))
                elif r < 0.40:
                    # 缺 level -> UNKNOWN
                    buf.append('{"timestamp":"%s","service":"%s","latency_ms":%.3f}'
                               % (ts, svc, random.uniform(0.5, 900.0)))
                elif r < 0.46:
                    # 科学计数法 / 负数
                    buf.append('{"timestamp":"%s","level":"%s","service":"%s","latency_ms":%s}'
                               % (ts, lvl, svc, random.choice(SCIENTIFIC)))
                else:
                    buf.append('{"timestamp":"%s","level":"%s","service":"%s","latency_ms":%.3f}'
                               % (ts, lvl, svc, random.uniform(0.5, 900.0)))

            if len(buf) >= 50000:
                f.write(("\n".join(buf) + "\n").encode("utf-8"))
                buf.clear()
        if buf:
            f.write("\n".join(buf).encode("utf-8"))
    # 剥掉文件末尾的换行符：基线以一个"尚未提交"的末行结尾
    with open(OUT, "r+b") as f:
        f.seek(0, 2)
        size = f.tell()
        if size > 0:
            f.seek(size - 1)
            if f.read(1) == b"\n":
                f.truncate(size - 1)

    # 按"已提交行"口径统计有效记录数（与题面盘点一致）；流式统计，不整读入内存
    committed_valid = 0
    prev = None
    with open(OUT, "rb") as f:
        for ln in f:
            if prev is not None and prev.endswith(b"\n"):
                m = re.search(rb'"timestamp":"([^"]*)"', prev)
                if m and TS_RE.match(m.group(1).decode("utf-8", "replace")):
                    committed_valid += 1
            prev = ln
    print("generated %d lines (%d committed valid) -> %s" % (N, committed_valid, OUT), file=sys.stderr)


if __name__ == "__main__":
    main()
