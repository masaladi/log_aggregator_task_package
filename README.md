# log-aggregator-incident（chaotic-environment / hard）

单机日志聚合服务故障现场修复题。服务、配置、权限与数据链路存在多处相互交织的缺陷，
且数据文件（约 900 万行 / 880 MB，单核全量解析 20 秒以上）在运行期被持续修改，
变更后的统计请求须在 1.5 秒内返回且数值正确。

## 包结构

| 路径 | 角色 | 谁使用 | 何时使用 |
|---|---|---|---|
| `instruction.md` | 题面：验收标准、输入契约（含异常闭环表）、写入端行为与正确性契约、运维规范 | 被测代理 | 评测开始时注入 |
| `environment/` | 初始环境：`Dockerfile`（含缺陷现场与基线数据生成，基础镜像按摘要锁定）、`app.py`（上一任遗留的缺陷服务）、`config.json`（含重复键陷阱）、`squatter.py`（端口占用进程）、`entrypoint.sh`、`gen_baseline.py` | 构建镜像 | 评测开始前 |
| `solution/solve.sh` | Oracle 解法：修复现场并实现满足全部契约的增量解析服务 | Oracle 代理 | Oracle trial 执行 |
| `tests/test.sh` | Verifier：3 项 × 1/3 判分，全部真值由 verifier 侧独立计算，不信任服务自报 | 评测框架（代理结束后注入并执行） | 判分阶段 |
| `docs/scoring-rationale.md` | 判分粒度设计说明：3 项二元结构与 ≤0.700 难度门的绑定论证 | 质检审阅 | R2 质检 |
| `docs/benchmarks.md` | 性能实测记录：解析耗时、门槛余量的方法、数据与复现命令 | 质检审阅 | R2 质检 |
| `tools/precheck.py` | 发布前静态预检：文件完整性、硬门槛模式扫描、三方数字对齐（无 Docker / 无常驻进程 / 无网络） | 出题人 | 每次送测前 |

注：`tests/` 与 `solution/` 不打进镜像，由评测框架（harbor）在对应阶段分别注入容器。

## 判分口径速览

- ITEM 1：HTTP 协议与端点（healthz / aggregate 结构与紧凑输出 / 404 / 405+Allow 覆盖全部非 GET/HEAD 方法 / HEAD / 查询串 / 自定义响应头）
- ITEM 2：聚合正确性 + 增量 SLA（变更后首请求 ≤1.5s）+ 写入中途未提交行 + 截断/就地重写回退
- ITEM 3：运维真实性（logsvc + venv + 9090 归属）+ 日志轮转（含轮转期间并发不撕裂）+ 20 并发响应与真值全量一致 + flock 等锁上限与快照回退

时延口径以 `instruction.md` 为唯一标准：常规变更后 1.5 秒；结构性变更（轮转、截断后就地重写）
后的首个请求 30 秒；服务启动后的首次统计请求 24 秒。
性能数字的实测方法、历史数据与复现命令见 `docs/benchmarks.md`。

## 发布前回归清单（送测前）

每次送测前依次执行，任何一步失败不提交（平台规定检测未通过后需等待 30 分钟，勿用平台试错）：

1. **静态预检**：`python3 tools/precheck.py` —— 文件完整性、R1 硬门槛模式（常驻容器、无限等待类命令）扫描、题面/README/判分口径三方数字对齐、历次迭代残留数字清查。
2. **镜像构建**：`docker build -t logagg environment` —— 构建期 apt 安装 `python3-ujson`，确认成功。
3. **NOP 对照**：干净容器直接跑 `tests/test.sh`，预期 0/3（reward ≤ 0.100）。
4. **Oracle 对照**：容器内执行 `solution/solve.sh` 后跑 `tests/test.sh`，预期 3/3（reward = 1.000）。
5. **性能抽查**：对照 `docs/benchmarks.md` 记录，确认参考解 warmup / 重扫耗时仍在门槛余量内。

其中 2-4 的判分数字以 `/logs/verifier/reward.txt` 为准；本清单为包外流程的固定记录模板。
