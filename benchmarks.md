# 性能实测记录（benchmarks）

本文档固定记录关键性能数字的实测环境、方法与结果，供质检与回归对照。
所有实测均在单核（`--cpus=1`）、2 GB 内存约束下进行，与 `task.toml` 的资源配额一致。

## 环境

- 基础镜像：`ubuntu:22.04`（按 Dockerfile 摘要锁定），Python 3.10
- 基线数据：`environment/gen_baseline.py` 生成，9,000,000 行 / 约 930 MB（`random.seed(20261023)`，确定性）
- 运行方式：`docker run --cpus=1 --memory=2g`，容器内单进程

## 解析全量基线（9M 行，逐行 `loads` + ISO 校验 + latency 累加）

| 实现 | 耗时 | 备注 |
|---|---|---|
| stdlib `json.loads` | 22.2s / 28.3s / 30.3s / 31.0s（多轮实测区间 22-31s，受页缓存与调度影响） | 首次请求宽限 24s 下的不可行路径 |
| `ujson.loads`（apt `python3-ujson` 5.1.0） | 12.3s / 13.3s / 14.8s | 参考解采用；venv 以 `--system-site-packages` 复用 |
| `rapidjson.loads`（apt `python3-rapidjson`） | 13.2s | 备选，未采用 |
| 增量解析（字节偏移之后的新增行，典型追加 5k 行） | ≈0.002s | 1.5s 常规门槛下唯一可行路径 |

## 复现方式

构建与运行使用同一个镜像标签 `logagg-bench`；基准脚本完整内联如下，可直接复制执行。

```bash
docker build -t logagg-bench environment
docker run --rm --cpus=1 --memory=2g logagg-bench bash -c 'apt-get update -qq \
  && apt-get install -y -qq python3-ujson python3-rapidjson >/dev/null \
  && cat > /tmp/bench.py << "EOF"
import json, time, re
ISO = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
DATA = "/var/lib/log-aggregator/logs.jsonl"

def bench(loads, name):
    t0 = time.monotonic()
    total = 0
    with open(DATA, "rb") as f:
        prev = None
        for line in f:
            if prev is not None:
                try:
                    r = loads(prev)
                except Exception:
                    prev = line
                    continue
                if isinstance(r, dict):
                    ts = r.get("timestamp", "")
                    if isinstance(ts, str) and ISO.match(ts):
                        total += 1
            prev = line
    print("%s: %.1fs total=%d" % (name, time.monotonic() - t0, total))

import ujson; bench(ujson.loads, "ujson   ")
import rapidjson; bench(rapidjson.loads, "rapidjson")
bench(json.loads, "stdlib  ")
import ujson; bench(ujson.loads, "ujson(2)")
EOF
python3 /tmp/bench.py'
```

预期输出形如：`ujson: 12-15s`、`rapidjson: ~13s`、`stdlib: 22-31s`、`total=8550015`。

## 回归记录与冻结版本关联

**关联口径**：提交到评测平台时，平台会对包内容重建 git 快照，其 HEAD 由平台生成，
与出题侧本地 commit 不同源；因此历史回归结果与**当前冻结版本**的关联不依赖本地
commit SHA，而以下列**文件内容指纹（sha256）**为准——质检可在任一冻结快照内直接
用 `sha256sum` 复核，与 git 历史无关。

### 当前版本（v21b）关键文件指纹

| 文件 | sha256 |
|---|---|
| `solution/solve.sh` | `4164d4213a88039704483f47dcbdde2ac888d046ff5d812396a682021c1dc606` |
| `tests/test.sh` | `b39ece9f3278b9b161efd271f2f247ef7204b547a32b98794f73b25f3d9426e6` |
| `environment/gen_baseline.py` | `cd65ae3af448ead48e169d5c796610592d05b4bf9a62a22dbee6cb1a1c53e1d6` |
| `environment/Dockerfile` | `6577e5c76cc21e8fc58d37a79abc3863588067a3a2270af697b2395e712abc5f` |
| `environment/squatter.py` | `02656bf51a1196119748eba309d9698644a6a31f81db35096d041c307b6c4cd4` |
| `environment/entrypoint.sh` | `f7a51865b9e8945abed7c7e5fb4686d7e51d9d36b7af142d7198d2b3ee7efb4e` |
| `environment/portmon.py` | `2b88305ab839a9891d8d736d6515b9855fc6c6007101e19c9fb8a7268366d56c` |

### 历史回归记录

每条记录绑定当次送测版本；本地 commit 仅供出题侧回溯，跨环境对照一律以
当次记录的文件指纹为准。

| 日期 | 版本 | 本地 commit（仅出题侧） | Oracle 结果 | warmup 实测 |
|---|---|---|---|---|
| 2026-10-26 | v12（9M 数据 + 双性能门首版） | 24cab45d 之前 | 3/3 = 1.00 | 30.7s（stdlib 参考解） |
| 2026-10-26 | v13c（ujson + 双性能门） | — | 3/3 = 1.00 | 14.4-15.6s |
| 2026-10-26 | v15（锚点 17 个 + 方法契约补测） | — | 3/3 = 1.00（连跑两轮） | 14.4s / 15.0s |
| 2026-10-26 | v18（size 塌陷监视器） | — | 3/3 = 1.00（连跑两轮） | 14.9s / 15.6s |
| 2026-10-27 | v20（见上方指纹表） | f5aecca | 3/3 = 1.00（同容器连跑三轮） | 13.4s |
| 2026-10-27 | v21（端口看护进程 + 精确匹配契约） | b074547 | NOP 0/3；3/3 = 1.00（同容器连跑两轮） | 14.6s |
| 2026-10-27 | v21b（portmon 启动挪入 squatter 内部，entrypoint 还原以过 R1） | bcb999f | NOP 0/3；3/3 = 1.00（同容器连跑两轮） | 14.3s |

新增记录时必须：先更新「当前版本关键文件指纹」表，再在本表追加行；未关联指纹的
性能数字不作为回归对照依据。

## 门槛与实测余量（门槛定义见 instruction.md）

| 门槛 | 参考解实测 | 余量 |
|---|---|---|
| 首次请求 24s（建态） | 11.4s / 14.4s / 14.8s / 18.5s（多轮） | ≥1.3x |
| 结构性变更 30s（全量重扫响应） | 约 14-20s | ≥1.5x |
| 常规变更 1.5s（增量） | ≈0.002s | ≫ |

## 结论

- stdlib 逐行实现无法通过 24s 建态门与 30s 重扫门（实测 22-31s），必须组合「高性能解析 + 增量解析」；
- 所有门槛数字与 `instruction.md`、`README.md` 保持一致，改动任何一方必须同步其余两方并重跑本记录。
