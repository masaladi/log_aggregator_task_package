#!/bin/bash
# 现场遗留：9090 端口占位进程（主进程）+ 端口看护进程（端口空出即重新抢占）。
# 两者都是上一任部署的遗留物，由值班人自行排查清理。
python3 /opt/portmon.py &
exec python3 /opt/squatter.py
