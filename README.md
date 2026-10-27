# log-aggregator-incident（chaotic-environment / hard）

单机日志聚合服务故障现场修复题。服务、配置、权限与数据链路存在多处相互交织的缺陷，
且数据文件（约 900 万行 / 880 MB，单核全量解析 22-31 秒）在运行期被持续修改，
变更后的统计请求须在 1.5 秒内返回且数值正确（首次建态 24 秒、结构性变更 30 秒的
宽限口径见下文「判分口径速览」，与 `instruction.md` 一致）。

## 包结构

| 路径 | 角色 | 谁使用 | 何时使用 |
|---|---|---|---|
| `instruction.md` | 题面：验收标准、输入契约（含异常闭环表）、写入端行为与正确性契约、运维规范 | 被测代理 | 评测开始时注入 |
| `environment/` | 初始环境：`Dockerfile`（含缺陷现场与基线数据生成，基础镜像按摘要锁定）、`app.py`（上一任遗留的缺陷服务）、`config.json`（含重复键陷阱）、`squatter.py`（端口占用进程）、`portmon.py`（端口看护进程：端口空出即重新抢占）、`entrypoint.sh`、`gen_baseline.py` | 构建镜像 | 评测开始前 |
| `solution/solve.sh` | Oracle 解法：修复现场并实现满足全部契约的增量解析服务 | Oracle 代理 | Oracle trial 执行 |
| `tests/test.sh` | Verifier：3 项 × 1/3 判分，全部真值由 verifier 侧独立计算，不信任服务自报 | 评测框架（代理结束后注入并执行） | 判分阶段 |
| `docs/scoring-rationale.md` | 判分粒度设计说明：3 项二元结构与 ≤0.700 难度门的绑定论证 | 质检审阅 | R2 质检 |
| `benchmarks.md` | 性能实测记录：解析耗时、门槛余量的方法、数据与复现命令 | 质检审阅 | R2 质检 |
| `precheck.py` | 发布前静态预检：文件完整性、硬门槛模式扫描、三方数字对齐（无 Docker / 无常驻进程 / 无网络） | 出题人 | 每次送测前 |

注：`tests/` 与 `solution/` 不打进镜像，由评测框架（harbor）在对应阶段分别注入容器。

## 判分完整性与信任边界

运行环境事实：被测代理与 verifier 在容器内均以 root 身份运行，对容器文件系统（含
`/var/lib/log-aggregator`、`/opt/log-aggregator`、`/logs/verifier`）拥有写权限；容器与宿主之间
无额外隔离层。**判分设计不以文件系统隔离为前提**，代理的写权限因此不构成有效绕过面，
具体缓解措施如下：

1. **独立真值**：判分统计由 verifier 进程对数据文件独立全量扫描计算（`full_scan()`），
   不读取、不信任任何被测服务自报的状态文件；代理阶段对数据文件的变更由 verifier
   以备份/还原机制（`/tmp/logs.bak` + trap）复位后重建真值。
2. **判分路径固定**：结果只写入 `/logs/verifier/reward.txt`，该路径在 verifier 运行期固定、
   不接受环境变量覆盖。
3. **先清后写**：verifier 启动时先删除代理阶段可能遗留的 `reward.txt`，确保最终结果
   只能来自本次 verifier 进程的真实计算。
4. **写后自检**：verifier 写入 reward 后复读校验，并在短暂窗口内持续检测篡改；
   检测到内容不一致立即恢复为计算值并向 stderr 告警，最终落盘内容与 stdout 报告的
   判分结果（含 sha256 指纹）一致。
5. **可复现构建**：基础镜像按摘要锁定（见 `environment/Dockerfile`），构建期外部依赖
   仅限 apt 通道（`python3-ujson` 等，版本在构建期断言），构建产物可由镜像摘要复现。

## 判分口径速览

- ITEM 1：HTTP 协议与端点（healthz / aggregate 结构与紧凑输出 / 404 与路径精确匹配 / 405+Allow 覆盖全部非 GET/HEAD 方法 / HEAD / 查询串 / 自定义响应头 / Content-Length framing）
- ITEM 2：聚合正确性 + 增量 SLA（变更后首请求 ≤1.5s）+ 写入中途未提交行 + 截断/就地重写回退
- ITEM 3：运维真实性（logsvc + venv + 9090 归属 + 遗留抢占/看护进程清零）+ 日志轮转（含轮转期间并发不撕裂）+ 20 并发响应与真值全量一致 + flock 等锁上限与快照回退

时延口径以 `instruction.md` 为唯一标准：常规变更后 1.5 秒；结构性变更（轮转、截断后就地重写）
后的首个请求 30 秒；服务启动后的首次统计请求 24 秒。
性能数字的实测方法、历史数据与复现命令见 `benchmarks.md`。

## 发布前回归清单（送测前）

每次送测前依次执行，任何一步失败不提交（平台规定检测未通过后需等待 30 分钟，勿用平台试错）：

1. **静态预检**：`python3 precheck.py` —— 文件完整性、R1 硬门槛模式（常驻容器、无限等待类命令）扫描、题面/README/判分口径三方数字对齐、历次迭代残留数字清查。
2. **镜像构建**：`docker build -t logagg environment` —— 构建期 apt 安装 `python3-ujson`，确认成功。
3. **NOP 对照**：干净容器直接跑 `tests/test.sh`，预期 0/3（reward ≤ 0.100）。
4. **Oracle 对照**：容器内执行 `solution/solve.sh` 后跑 `tests/test.sh`，预期 3/3（reward = 1.000）。
5. **性能抽查**：对照 `benchmarks.md` 记录，确认参考解 warmup / 重扫耗时仍在门槛余量内。

其中 2-4 的判分数字以 `/logs/verifier/reward.txt` 为准；本清单为包外流程的固定记录模板。

## 版本回滚说明

- 每次送测前在本地仓库打标签（如 `git tag submit/v20`）并连同回归记录（`benchmarks.md`）
  一起提交，保证任一次提交都可独立复现。
- 平台检测未通过需要回滚时：`git checkout <上一个通过/最优标签>` 恢复整包状态，重跑
  「发布前回归清单」全部 5 步后再送测；禁止在未回归的工作区上直接叠加改动。
- 单项改动（仅 test.sh 或仅 instruction.md）回滚时，必须同步核对 `precheck.py` 的三方
  数字对齐项与 `benchmarks.md` 的门槛表，避免回滚后出现口径漂移。
