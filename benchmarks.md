# 性能实测记录（benchmarks）

本文档固定记录关键性能数字的实测环境、方法与结果，供质检与回归对照。
所有实测均在单核（`--cpus=1`）、2 GB 内存约束下进行，与 `task.toml` 的资源配额一致。

## 环境

- 基础镜像：`ubuntu:22.04`（按 Dockerfile 摘要锁定），Python 3.10
- 基线数据：`environment/gen_baseline.py` 生成，9,000,000 行 / 约 880 MB（`random.seed(20261023)`，确定性）
- 运行方式：`docker run --cpus=1 --memory=2g`，容器内单进程

## 解析全量基线（9M 行，逐行 `loads` + ISO 校验 + latency 累加）

| 实现 | 耗时 | 备注 |
|---|---|---|
| stdlib `json.loads` | 22.2s / 28.3s / 30.3s / 31.0s（多轮实测区间 22-31s，受页缓存与调度影响） | 首次请求宽限 24s 下的不可行路径 |
| `ujson.loads`（apt `python3-ujson` 5.1.0） | 12.3s / 13.3s / 14.8s | 参考解采用；venv 以 `--system-site-packages` 复用 |
| `rapidjson.loads`（apt `python3-rapidjson`） | 13.2s | 备选，未采用 |
| 增量解析（字节偏移之后的新增行，典型追加 5k 行） | ≈0.002s | 1.5s 常规门槛下唯一可行路径 |

## 复现方式

```bash
docker build -t logagg-bench environment
docker run --rm --cpus=1 --memory=2g logagg-bash bash -c \
  "apt-get update -qq && apt-get install -y -qq python3-ujson >/dev/null && python3 /tmp/bench.py"
# bench.py：分块流式读取 /var/lib/log-aggregator/logs.jsonl，
# 逐行 loads + ISO 时间戳过滤 + latency 累加，对 stdlib / ujson / rapidjson 各计时一轮
```

## 门槛与实测余量（门槛定义见 instruction.md）

| 门槛 | 参考解实测 | 余量 |
|---|---|---|
| 首次请求 24s（建态） | 11.4s / 14.4s / 14.8s / 18.5s（多轮） | ≥1.3x |
| 结构性变更 30s（全量重扫响应） | 约 14-20s | ≥1.5x |
| 常规变更 1.5s（增量） | ≈0.002s | ≫ |

## 结论

- stdlib 逐行实现无法通过 24s 建态门与 30s 重扫门（实测 22-31s），必须组合「高性能解析 + 增量解析」；
- 所有门槛数字与 `instruction.md`、`README.md` 保持一致，改动任何一方必须同步其余两方并重跑本记录。
