#!/bin/bash
set -e

# 1. 确保 venv 能力可用（镜像已预装 python3-venv/psmisc；缺失时兜底安装，无网络也不阻断主流程）
if ! python3 -m venv /tmp/_venvcheck >/dev/null 2>&1; then
    apt-get update >/dev/null 2>&1 || true
    apt-get install -y python3-venv psmisc >/dev/null 2>&1 || true
fi
rm -rf /tmp/_venvcheck

# 2. 清理 9090 端口占用的无主进程
#    容器内没有 CAP_SYS_PTRACE，fuser 读不到别人的 /proc/PID/fd，不能作为唯一手段；
#    以 /proc/PID/cmdline 匹配为准（root 可读），并等待端口真正释放后再启动。
#    顺序关键：必须先终止端口看护进程（portmon），否则仅杀占位进程后
#    端口会在数秒内被看护进程重新夺走，服务永远无法绑定。
pkill -f /opt/portmon.py || true
pkill -f /opt/squatter.py || true
pkill -f "/opt/log-aggregator/venv/bin/python /opt/log-aggregator/app.py" || true
pkill -f "/opt/log-aggregator/app.py" || true
fuser -k 9090/tcp 2>/dev/null || true

# 有界等待端口释放（squatter 让位需要一瞬间）；就绪判定为"端口已无人监听"
port_free=false
for i in $(seq 1 150); do
    if python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.2); sys.exit(0 if s.connect_ex(('127.0.0.1',9090))!=0 else 1)"; then
        port_free=true
        break
    fi
    sleep 0.1
done
$port_free || echo "[solve] WARN: port 9090 still occupied after cleanup" >&2

# 3. 修复配置文件（原文件含重复键，后出现的键值会覆盖前面的，且指向错误端口与错误数据路径）
cat << 'EOF' > /etc/log-aggregator/config.json
{
  "server": {
    "port": 9090,
    "data_file": "/var/lib/log-aggregator/logs.jsonl"
  }
}
EOF
chmod 644 /etc/log-aggregator/config.json   # 修复配置读取权限（原 640 root:root，logsvc 不可读）

# 4. 修复权限：数据目录需可进入、数据文件需可被 logsvc 读取、日志目录需可被 logsvc 写入
chmod 755 /var/lib/log-aggregator
chmod 644 /var/lib/log-aggregator/logs.jsonl
chown -R logsvc:logsvc /var/log/aggregator

# 5. 整文件重写服务实现（不沿用上一任的任何遗留代码）：
#    真正的增量解析（字节偏移 + 累计状态），因为 900 万行全量重解析约 22 秒，
#    远超"文件变更后首个请求 <= 1.5 秒"的门槛。
#    同时处理：半行、截断回退、inode 轮转、并发 single-flight、flock 等锁上限与快照回退。
cat << 'PYEOF' > /opt/log-aggregator/app.py
import fcntl
import http.server
import json
import os
import re
import sys
import threading
import time
import urllib.parse
import zlib

try:
    import ujson as _fastjson  # 镜像经 apt 预装 python3-ujson（venv 挂载系统包复用）
    _loads = _fastjson.loads
except ImportError:
    _loads = json.loads

CONFIG_PATH = "/etc/log-aggregator/config.json"
DEFAULT_DATA_FILE = "/var/lib/log-aggregator/logs.jsonl"
ISO_RE = re.compile(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$')
LOCK_WAIT_SEC = 1.0
EMPTY_STATS = {"total_logs": 0, "error_count": 0, "avg_latency_ms": 0.0, "levels": {}}
READ_CHUNK = 1 << 22
HEAD_BYTES = 4096
ANCHOR_BYTES = 512


def load_config():
    port = 9090
    data_file = DEFAULT_DATA_FILE
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, 'r', encoding='utf-8') as f:
                cfg = json.load(f)
                port = cfg.get("server", {}).get("port", port)
                data_file = cfg.get("server", {}).get("data_file", data_file)
        except Exception as e:
            print("[warn] config load failed (%s), using defaults" % e, file=sys.stderr)
    return port, data_file


# ---------------- 解析：严格逐行 json，不使用任何正则取巧 ----------------
def _parse_chunk(buf):
    """buf: bytes，包含若干以 \n 结尾的完整行。返回 (total, err, lat_sum, levels)"""
    total = 0
    err = 0
    lat_sum = 0.0
    levels = {}
    loads = _loads
    iso = ISO_RE.match
    for line in buf.split(b"\n"):
        if not line:
            continue
        try:
            rec = loads(line)
        except Exception:
            continue
        if rec.__class__ is not dict:
            continue
        ts = rec.get("timestamp")
        if ts.__class__ is not str or not iso(ts):
            continue
        lvl = rec.get("level", "UNKNOWN")
        total += 1
        if lvl == "ERROR":
            err += 1
        levels[lvl] = levels.get(lvl, 0) + 1
        lat = rec.get("latency_ms", 0.0)
        c = lat.__class__
        if c is float or c is int:
            lat_sum += lat
        elif c is str:
            try:
                lat_sum += float(lat)
            except ValueError:
                pass
    return total, err, lat_sum, levels


# ---------------- 增量状态 ----------------
_state = {"ino": None, "offset": 0, "total": 0, "err": 0,
          "lat_sum": 0.0, "levels": {}, "key": None, "anchors": None}
_snap = {"stats": None}
_dip_seen = {"flag": False}
_state_lock = threading.Lock()


def _watch_size_dips(data_file):
    """后台监视：捕获"truncate 后重写"的 size 塌陷瞬间。
    就地重写必然先经过 size < 已解析区间的状态（先截断、后写入），
    塌陷窗口时长与文件体量成正比（880MB 级重写需秒级完成写入），50ms 轮询必然捕获；
    捕获后置位标志，下一次请求触发全量重扫——这是对"截断后就地重写"的确定性检测。
    （原子替换轮转由 inode 变化捕获，纯追加不产生塌陷。）"""
    while True:
        try:
            if os.stat(data_file).st_size < _state["offset"]:
                _dip_seen["flag"] = True
        except OSError:
            _dip_seen["flag"] = True   # 文件暂时消失（替换窗口）同样视为结构变更
        time.sleep(0.1)


def _reset_state():
    _state["offset"] = 0
    _state["total"] = 0
    _state["err"] = 0
    _state["lat_sum"] = 0.0
    _state["levels"] = {}


def _absorb(total, err, lat_sum, levels):
    _state["total"] += total
    _state["err"] += err
    _state["lat_sum"] += lat_sum
    for k, v in levels.items():
        _state["levels"][k] = _state["levels"].get(k, 0) + v


def _compute_anchors(f, size):
    """内容指纹：锚定在上一轮已解析区间的绝对偏移上。
    纯追加不改变已解析区间内任何字节 -> 指纹不变，增量继续；
    截断后就地重写必然改变已解析区间内容 -> 指纹必变，触发全量重扫。
    首次扫描（尚无已解析区间）仅取头部。"""
    if _state["offset"] <= 0:
        f.seek(0)
        return [(0, zlib.crc32(f.read(HEAD_BYTES)))]
    span = _state["offset"]
    step = span // 16
    marks = sorted({0} | {step * i for i in range(1, 16) if step > 0})
    out = []
    for off in marks:
        n = HEAD_BYTES if off == 0 else ANCHOR_BYTES
        n = max(1, min(n, span - off))      # 严格裁剪：绝不读取已解析区间之外的字节
        f.seek(off)
        out.append((off, zlib.crc32(f.read(n))))
    return out


def _rescan(f):
    """全量重扫：分块流式读取，末尾不完整的行不解析、也不计入 offset"""
    _reset_state()
    f.seek(0)
    pending = b""
    offset = 0
    while True:
        chunk = f.read(READ_CHUNK)
        if not chunk:
            break
        buf = pending + chunk
        idx = buf.rfind(b"\n")
        if idx < 0:
            pending = buf
            continue
        complete = buf[:idx + 1]
        pending = buf[idx + 1:]
        _absorb(*_parse_chunk(complete))
        offset += len(complete)
    _state["offset"] = offset


def _incremental(f):
    """只解析 offset 之后新增的完整行；末尾半行留给下次"""
    f.seek(_state["offset"])
    data = f.read()
    if not data:
        return
    idx = data.rfind(b"\n")
    if idx < 0:
        return
    complete = data[:idx + 1]
    _absorb(*_parse_chunk(complete))
    _state["offset"] += len(complete)


def _snapshot():
    total = _state["total"]
    return {
        "total_logs": total,
        "error_count": _state["err"],
        "avg_latency_ms": round(_state["lat_sum"] / total, 3) if total else 0.0,
        "levels": {k: _state["levels"][k] for k in sorted(_state["levels"])},
    }


def aggregate(data_file):
    with _state_lock:                      # single-flight：并发请求合并为一次解析
        try:
            st0 = os.stat(data_file)
        except OSError as e:
            print("[warn] stat failed (%s): serving last complete snapshot" % e, file=sys.stderr)
            return dict(_snap["stats"] or EMPTY_STATS)
        key0 = (st0.st_ino, st0.st_mtime_ns, st0.st_size)
        if key0 == _state["key"] and _snap["stats"] is not None:
            return dict(_snap["stats"])

        try:
            f = open(data_file, "rb")
        except OSError as e:
            print("[warn] open failed (%s): serving last complete snapshot" % e, file=sys.stderr)
            return dict(_snap["stats"] or EMPTY_STATS)

        try:
            deadline = time.monotonic() + LOCK_WAIT_SEC
            while True:
                try:
                    fcntl.flock(f.fileno(), fcntl.LOCK_SH | fcntl.LOCK_NB)
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        # 等锁超时：返回上一次成功统计的完整快照，绝不返回半写内容
                        print("[warn] flock wait timeout: serving last complete snapshot", file=sys.stderr)
                        return dict(_snap["stats"] or EMPTY_STATS)
                    time.sleep(0.01)

            st = os.fstat(f.fileno())
            # 结构变更检测（三层，互为冗余）：
            #   1) 后台监视器置位的 size 塌陷标志 → 捕获"截断后就地重写"（即使重写后文件更长）
            #   2) inode 变化 → 捕获原子替换轮转
            #   3) size < 已解析区间 → 兜底捕获任何截断形态
            # 另以 17 个等距内容锚点做二次校验（约每 1/16 区间一个）：
            # 已解析区间内容被整体换掉时必然命中锚点差异。
            anchors = _compute_anchors(f, st.st_size)
            if (_snap["stats"] is None
                    or _dip_seen["flag"]
                    or _state["ino"] != st.st_ino
                    or st.st_size < _state["offset"]
                    or anchors != _state["anchors"]):
                _dip_seen["flag"] = False
                _state["ino"] = st.st_ino
                _rescan(f)
            else:
                _incremental(f)
            # 解析完成后按新的已解析区间重算指纹，供下一次请求比对
            _state["anchors"] = _compute_anchors(f, st.st_size)
            _state["key"] = (st.st_ino, st.st_mtime_ns, st.st_size)
            _snap["stats"] = _snapshot()
            return dict(_snap["stats"])
        except OSError as e:
            print("[warn] read/parse I/O failed (%s): serving last complete snapshot" % e, file=sys.stderr)
            return dict(_snap["stats"] or EMPTY_STATS)
        finally:
            try:
                fcntl.flock(f.fileno(), fcntl.LOCK_UN)
            except Exception:
                pass
            f.close()


class LogAggregatorHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "LogAggregator/1.0"

    def _send(self, code, body, send_body=True, extra_headers=None):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("X-Log-Aggregator-Status", "Verified")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if send_body and body:
            self.wfile.write(body)

    def _route(self, send_body):
        path = urllib.parse.urlparse(self.path).path
        if path == "/healthz":
            self._send(200, json.dumps({"status": "healthy"}).encode('utf-8'), send_body)
        elif path == "/api/v1/aggregate":
            body = json.dumps(aggregate(self.server.data_file), separators=(",", ":")).encode('utf-8')
            self._send(200, body, send_body)
        else:
            self._send(404, b"", send_body)

    def do_GET(self):
        self._route(True)

    def do_HEAD(self):
        self._route(False)

    def _read_body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length > 0:
            self.rfile.read(min(length, 1 << 20))

    def do_POST(self):
        self._read_body()
        self._send(405, b"", True, {"Allow": "GET, HEAD"})

    def do_PUT(self):
        self._read_body()
        self._send(405, b"", True, {"Allow": "GET, HEAD"})

    def do_DELETE(self):
        self._send(405, b"", True, {"Allow": "GET, HEAD"})

    def do_OPTIONS(self):
        self._send(405, b"", True, {"Allow": "GET, HEAD"})

    def do_PATCH(self):
        self._read_body()
        self._send(405, b"", True, {"Allow": "GET, HEAD"})

    def log_message(self, format, *args):
        return


def run():
    port, data_file = load_config()
    threading.Thread(target=_watch_size_dips, args=(data_file,), daemon=True).start()
    httpd = http.server.ThreadingHTTPServer(('0.0.0.0', port), LogAggregatorHandler)
    httpd.data_file = data_file
    httpd.serve_forever()


if __name__ == '__main__':
    run()
PYEOF

# 6. 创建虚拟环境（挂载系统包以复用 apt 预装的 ujson）并分配属主权限
python3 -m venv --system-site-packages /opt/log-aggregator/venv
/opt/log-aggregator/venv/bin/python -c "import ujson" || {
    echo "ERROR: ujson unavailable in venv" >&2; exit 1; }
chown -R logsvc:logsvc /opt/log-aggregator

# 7. 以 logsvc 用户拉起常驻服务，并等待端口就绪
su -s /bin/bash logsvc -c 'nohup /opt/log-aggregator/venv/bin/python /opt/log-aggregator/app.py >> /var/log/aggregator/app.log 2>&1 &'

# 有界等待：最多 15 秒等端口就绪，超时显式报错并退出非零
port_up=false
for i in $(seq 1 150); do
    if python3 -c "import socket; s=socket.socket(); s.settimeout(0.2); s.connect(('127.0.0.1', 9090))" 2>/dev/null; then
        port_up=true
        break
    fi
    sleep 0.1
done
if ! $port_up; then
    echo "[solve] ERROR: service did not listen on 9090 within 15s" >&2
    tail -20 /var/log/aggregator/app.log >&2 || true
    exit 1
fi
