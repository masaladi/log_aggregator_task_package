# 基础镜像按摘要锁定，保证各次构建输入一致（可复现性）
FROM ubuntu:22.04@sha256:0a9887931b0e38af2e3487ed39e29436b0535c4f3f52e57745baaf79d1898956

RUN sed -i \
    -e 's|http://archive.ubuntu.com|http://mirrors.tuna.tsinghua.edu.cn|g' \
    -e 's|http://security.ubuntu.com|http://mirrors.tuna.tsinghua.edu.cn|g' \
    /etc/apt/sources.list

RUN apt-get update && apt-get install -y \
    python3 \
    python3-venv \
    python3-ujson \
    procps \
    psmisc \
    && rm -rf /var/lib/apt/lists/*
# python3-ujson：高性能 JSON 解析库（与基础包同走 apt 渠道，无额外网络依赖）。
# 900 万行的解析性能预算是本题的一部分，实现者可自行决定是否使用。

# 依赖锁定断言：构建期固定关键三方库的主版本（jammy 通道为 5.1.0），
# 版本漂移时构建直接失败，避免性能基准（见 benchmarks.md）失配。
RUN python3 -c "import ujson; assert ujson.__version__.startswith('5.1'), ujson.__version__" \
    && python3 --version

WORKDIR /app

RUN useradd --system --create-home --shell /usr/sbin/nologin logsvc

# /opt/log-aggregator/app.py 是"上一任遗留"的初始服务代码：可运行，但存在
# 配置/权限/实现层面的缺陷，修复它是任务的一部分（评测代理可整体重写该文件）。
# 注意：任务包中的 tests/ 与 solution/ 不打进镜像——评测框架（harbor）会在
# 评测阶段分别将它们注入容器：solution/solve.sh 由 Oracle 代理执行，
# tests/test.sh 由 verifier 在代理结束后执行。
COPY app.py /opt/log-aggregator/app.py
COPY squatter.py /opt/squatter.py
COPY portmon.py /opt/portmon.py
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh /opt/log-aggregator/app.py /opt/squatter.py /opt/portmon.py

COPY config.json /etc/log-aggregator/config.json
# 上一任留下的配置权限现场：文件属 root 且组/其他用户不可读，
# 以 logsvc 运行的服务因此读不到配置，需自行排查。
RUN chown root:root /etc/log-aggregator/config.json \
    && chmod 640 /etc/log-aggregator/config.json \
    && chmod 755 /etc/log-aggregator

# 基线数据：约 900 万行 / 880 MB。规模是本题难度的一部分——
# 单核下全量重解析需 20 秒以上，因此服务必须做增量解析。
COPY gen_baseline.py /opt/gen_baseline.py
RUN mkdir -p /var/lib/log-aggregator \
    && python3 /opt/gen_baseline.py \
    && rm -f /opt/gen_baseline.py

# 上一任留下的权限现场：数据目录不可进入、数据文件不可读、日志目录不可写。
# 服务以 logsvc 运行时会因此读不到数据、也写不出日志，需自行排查。
RUN mkdir -p /var/log/aggregator \
    && chown -R root:root /var/lib/log-aggregator \
    && chmod 700 /var/lib/log-aggregator \
    && chmod 600 /var/lib/log-aggregator/logs.jsonl \
    && chown -R root:root /var/log/aggregator \
    && chmod 755 /var/log/aggregator

CMD ["/usr/local/bin/entrypoint.sh"]
