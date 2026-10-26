#!/bin/bash
# log-aggregator-incident verifier
# 判分结构：3 项 x 1/3 -> 可能值 0 / 0.33 / 0.67 / 1.00
# 各项的验收口径、时延门槛与宽限时长均以 instruction.md 为准，
# 本脚本不额外引入 instruction.md 之外的判定标准。
set -u

REWARD_FILE="/logs/verifier/reward.txt"
DATA_FILE="/var/lib/log-aggregator/logs.jsonl"
BASE="http://127.0.0.1:9090"
VENV_PY="/opt/log-aggregator/venv/bin/python"
APP_PY="/opt/log-aggregator/app.py"

mkdir -p /logs/verifier
PASS=0
TOTAL=3

export DATA_FILE BASE VENV_PY APP_PY

# 备份原始数据文件，退出时还原
cp -p "$DATA_FILE" /tmp/logs.bak 2>/dev/null || cp -f /dev/null /tmp/logs.bak
trap 'cp -f /tmp/logs.bak "$DATA_FILE" 2>/dev/null; chmod 644 "$DATA_FILE" 2>/dev/null' EXIT

# 等待被测服务就绪（最多 120 秒：服务启动时可能要做首次全量扫描）
for i in $(seq 1 1200); do
    if python3 -c "import socket; s=socket.socket(); s.settimeout(0.2); s.connect(('127.0.0.1', 9090))" 2>/dev/null; then
        break
    fi
    sleep 0.1
done

# 预热：服务启动后的第一次统计请求按 instruction.md 给 24 秒宽限（用于建立初始状态）
python3 - <<'PY' 2>&1 | sed 's/^/[warmup] /'
import json, os, time, urllib.request
BASE = os.environ["BASE"]
t0 = time.monotonic()
try:
    r = urllib.request.urlopen(BASE + "/api/v1/aggregate", timeout=24)
    body = r.read().decode("utf-8", "replace")
    print("first aggregate in %.2fs, total_logs=%s" % (time.monotonic() - t0, json.loads(body).get("total_logs")))
except Exception as e:
    print("warmup failed after %.2fs: %s" % (time.monotonic() - t0, e))
PY

echo "===== ITEM 1/3: protocol, endpoints and custom header ====="
ITEM1=$(python3 - <<'PY'
import json, os, urllib.request, urllib.error

BASE = os.environ["BASE"]
HDR = "X-Log-Aggregator-Status"
fails = []

def get(path):
    try:
        r = urllib.request.urlopen(BASE + path, timeout=5)
        return r.getcode(), r.headers, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read().decode("utf-8", "replace")
    except Exception as e:
        return -1, {}, "ERR:%s" % e

code, h, body = get("/healthz")
if code != 200:
    fails.append("/healthz status=%s" % code)
if h.get(HDR) != "Verified":
    fails.append("/healthz header=%r" % h.get(HDR))
try:
    if json.loads(body) != {"status": "healthy"}:
        fails.append("/healthz body=%r" % body[:120])
except Exception:
    fails.append("/healthz body not json: %r" % body[:120])
hz_body_len = len(body.encode("utf-8")) if isinstance(body, str) else -1

code, h, body = get("/api/v1/aggregate")
if code != 200:
    fails.append("/api/v1/aggregate status=%s" % code)
if h.get(HDR) != "Verified":
    fails.append("/api/v1/aggregate header=%r" % h.get(HDR))
try:
    res = json.loads(body)
    if not isinstance(res, dict):
        fails.append("aggregate body is not object")
    else:
        for k in ("total_logs", "error_count", "avg_latency_ms", "levels"):
            if k not in res:
                fails.append("aggregate missing field %s" % k)
        if not isinstance(res.get("levels"), dict):
            fails.append("levels is not object")
        if not isinstance(res.get("total_logs"), int):
            fails.append("total_logs is not int")
        # 紧凑 JSON + levels 键字典序
        try:
            if json.dumps(res, separators=(",", ":")) != body:
                fails.append("aggregate body is not compact JSON (no spaces allowed)")
        except Exception:
            pass
        lv = res.get("levels") or {}
        if isinstance(lv, dict) and list(lv.keys()) != sorted(lv.keys()):
            fails.append("levels keys not sorted")
except Exception:
    fails.append("aggregate body not json: %r" % body[:120])

code, h, body = get("/no-such-path")
if code != 404:
    fails.append("/no-such-path status=%s (want 404)" % code)
if h.get(HDR) != "Verified":
    fails.append("/no-such-path header=%r" % h.get(HDR))

code, h, body = get("/api/v1/aggregate/extra")
if code != 404:
    fails.append("/api/v1/aggregate/extra status=%s (want 404)" % code)

code, h, body = get("/healthz?verbose=1")
if code != 200:
    fails.append("/healthz?verbose=1 status=%s (want 200)" % code)

def head(path):
    try:
        req = urllib.request.Request(BASE + path, method="HEAD")
        r = urllib.request.urlopen(req, timeout=5)
        return r.getcode(), r.headers, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()
    except Exception as e:
        return -1, {}, b"ERR:%s" % str(e).encode()

code, h, body = head("/healthz")
if code != 200:
    fails.append("HEAD /healthz status=%s (want 200)" % code)
if h.get(HDR) != "Verified":
    fails.append("HEAD /healthz header=%r" % h.get(HDR))
if body:
    fails.append("HEAD /healthz returned a body")
try:
    if hz_body_len > 0 and int(h.get("Content-Length") or -1) != hz_body_len:
        fails.append("HEAD /healthz Content-Length=%r (want %d, same as GET)" % (h.get("Content-Length"), hz_body_len))
except ValueError:
    fails.append("HEAD /healthz Content-Length not numeric")

def post(path):
    try:
        req = urllib.request.Request(BASE + path, data=b"", method="POST")
        r = urllib.request.urlopen(req, timeout=5)
        return r.getcode(), r.headers
    except urllib.error.HTTPError as e:
        return e.code, e.headers
    except Exception:
        return -1, {}

code, h = post("/api/v1/aggregate")
if code != 405:
    fails.append("POST /api/v1/aggregate status=%s (want 405)" % code)
elif "GET" not in (h.get("Allow") or ""):
    fails.append("POST 405 missing Allow header, got %r" % h.get("Allow"))
if h.get(HDR) != "Verified":
    fails.append("POST 405 header=%r" % h.get(HDR))

# 其余非 GET/HEAD 方法同样必须 405 + Allow（方法边界完备性）
for meth in ("OPTIONS", "PATCH", "PUT", "DELETE"):
    try:
        req = urllib.request.Request(BASE + "/healthz", data=b"", method=meth)
        r = urllib.request.urlopen(req, timeout=5)
        c2, h2 = r.getcode(), r.headers
    except urllib.error.HTTPError as e:
        c2, h2 = e.code, e.headers
    except Exception:
        c2, h2 = -1, {}
    if c2 != 405:
        fails.append("%s /healthz status=%s (want 405)" % (meth, c2))
    elif "GET" not in (h2.get("Allow") or ""):
        fails.append("%s 405 missing Allow header" % meth)

print("OK" if not fails else "FAIL: " + "; ".join(fails))
PY
)
if [ "$ITEM1" = "OK" ]; then
    PASS=$((PASS + 1))
    echo "ITEM 1: PASS"
else
    echo "ITEM 1: FAIL - $ITEM1"
fi

echo
echo "===== ITEM 2/3: correctness + incremental SLA + half-line + truncation ====="
ITEM2=$(python3 - <<'PY'
import copy, json, os, re, sys, time, urllib.request

DATA = os.environ["DATA_FILE"]
BASE = os.environ["BASE"]
fails = []
ISO = re.compile(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$')
SLA = 1.5          # 变更后的首个请求门槛
ROTATE_SLA = 30.0  # 截断/轮转这类结构性变更的宽限


def parse_lines(lines):
    """按题目口径解析：ISO 过滤 / 顶层 level / 缺字段兜底。返回 total, err, lat_sum, levels"""
    total = err = 0
    s = 0.0
    lv = {}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        if not isinstance(r, dict):
            continue
        ts = r.get("timestamp", "")
        if not isinstance(ts, str) or not ISO.match(ts):
            continue
        lvl = r.get("level", "UNKNOWN")
        total += 1
        if lvl == "ERROR":
            err += 1
        lv[lvl] = lv.get(lvl, 0) + 1
        try:
            s += float(r.get("latency_ms", 0.0))
        except Exception:
            pass
    return total, err, s, lv


def full_scan():
    total = err = 0
    s = 0.0
    lv = {}

    def absorb(line):
        nonlocal total, err, s, lv
        line = line.strip()
        if not line:
            return
        try:
            r = json.loads(line)
        except Exception:
            return
        if not isinstance(r, dict):
            return
        ts = r.get("timestamp", "")
        if not isinstance(ts, str) or not ISO.match(ts):
            return
        lvl = r.get("level", "UNKNOWN")
        total += 1
        if lvl == "ERROR":
            err += 1
        lv[lvl] = lv.get(lvl, 0) + 1
        try:
            s += float(r.get("latency_ms", 0.0))
        except Exception:
            pass

    # verifier 口径：只有以换行符结尾的行才计入统计（EOF 未换行的尾行视为未提交）
    with open(DATA, "r", encoding="utf-8", errors="replace") as f:
        prev = None
        for line in f:
            if prev is not None:
                absorb(prev)
            prev = line
        if prev is not None and prev.endswith("\n"):
            absorb(prev)
    return {"total_logs": total, "error_count": err, "lat_sum": s, "levels": lv}


def expect_of(truth):
    t = truth["total_logs"]
    return {
        "total_logs": t,
        "error_count": truth["error_count"],
        "avg_latency_ms": round(truth["lat_sum"] / t, 3) if t else 0.0,
        "levels": truth["levels"],
    }


def get_agg(timeout=30):
    t0 = time.monotonic()
    r = urllib.request.urlopen(BASE + "/api/v1/aggregate", timeout=timeout)
    body = r.read().decode("utf-8", "replace")
    return json.loads(body), time.monotonic() - t0


def check(got, want, label):
    if got.get("total_logs") != want["total_logs"]:
        fails.append("%s: total_logs=%r want %r" % (label, got.get("total_logs"), want["total_logs"]))
    if got.get("error_count") != want["error_count"]:
        fails.append("%s: error_count=%r want %r" % (label, got.get("error_count"), want["error_count"]))
    if got.get("levels") != want["levels"]:
        fails.append("%s: levels mismatch (got %d keys, want %d keys)"
                     % (label, len(got.get("levels") or {}), len(want["levels"])))
    try:
        v = got.get("avg_latency_ms")
        # NaN/Infinity 防绕过：nan 与任何数的比较恒为 False，必须显式排除
        if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v or v in (float("inf"), float("-inf")):
            fails.append("%s: avg_latency_ms not finite numeric (%r)" % (label, v))
        elif abs(v - want["avg_latency_ms"]) > 0.001:
            fails.append("%s: avg_latency_ms=%r want %r" % (label, v, want["avg_latency_ms"]))
    except Exception:
        fails.append("%s: avg_latency_ms not numeric" % label)


# ---------- 基线真值（verifier 独立全量计算，不信任服务） ----------
t0 = time.monotonic()
baseline = full_scan()
base_size = os.path.getsize(DATA)
print("[truth] baseline scan %.1fs total=%d err=%d" % (time.monotonic() - t0, baseline["total_logs"], baseline["error_count"]), file=sys.stderr)
state = copy.deepcopy(baseline)  # verifier 侧滚动状态（必须深拷贝，否则会污染 baseline.levels）

# 基线末行不带换行符（写入端停在换行落盘前）：它是"尚未提交"的行，
# 不计入 baseline 真值；当后续追加的前置换行符到达时才提交计数。
with open(DATA, "rb") as _f:
    _f.seek(0, 2)
    _sz = _f.tell()
    _f.seek(max(0, _sz - 4096))
    _tail = _f.read()
PENDING = _tail.rsplit(b"\n", 1)[-1].decode("utf-8", "replace")  # 未提交的基线末行

def add_lines(lines):
    """滚动更新 verifier 侧状态，返回期望值"""
    t, e, s, lv = parse_lines(lines)
    state["total_logs"] += t
    state["error_count"] += e
    state["lat_sum"] += s
    for k, v in lv.items():
        state["levels"][k] = state["levels"].get(k, 0) + v


# ---------- 2a. 基线正确性（已预热，必须快） ----------
try:
    got, el = get_agg(timeout=30)
    check(got, expect_of(state), "2a baseline")
    if el > SLA:
        fails.append("2a baseline: %.2fs > %.1fs (state should already be built)" % (el, SLA))
except Exception as e:
    fails.append("2a baseline request failed: %s" % e)

# ---------- 2a2. 非法内容批次：空行 / JSON 损坏行 / 非法时间戳行 不得影响任何统计 ----------
try:
    junk = [
        "", "", "",
        'not a json line at all',
        '{broken',
        '{"timestamp":"2026-10-24 10:00:03","level":"ERROR","service":"x","latency_ms":1}',
        '{"timestamp":"2026-10-24T10:00:03.500Z","level":"ERROR","service":"x","latency_ms":1}',
        '{"timestamp":"2026-10-24T10:00:04+08:00","level":"ERROR","service":"x","latency_ms":1}',
        '{"timestamp":"2026-10-23t10:00:05z","level":"ERROR","service":"x","latency_ms":1}',
        '{"timestamp":"2026-10-24T10:00:06Z","level":"ERROR","service":"x"}',  # 缺 latency 且时间戳合法 → 是合法行
    ]
    junk = junk[:-1]  # 最后一条为合法行，本批次验证"全非法"；缺字段场景由基线数据与 fixture 覆盖
    with open(DATA, "a", encoding="utf-8") as f:
        f.write("\n" + "\n".join(junk) + "\n")    # 前置换行符：提交基线末行；本批次全部为空行或非法行
    add_lines([PENDING])                           # 基线末行随换行符到达而提交
    got, el = get_agg(timeout=30)
    check(got, expect_of(state), "2a2 invalid-only batch must not change stats")
except Exception as e:
    fails.append("2a2 invalid batch failed: %s" % e)

# ---------- 2b. 增量 SLA：追加后首个请求必须 <=1.5s 且值正确 ----------
def mk_line(i, lvl="INFO"):
    return '{"timestamp":"2026-10-24T%02d:%02d:%02dZ","level":"%s","service":"probe-%d","latency_ms":%.3f}' % (
        1 + i % 20, i % 60, (i // 60) % 60, lvl, i % 997, 1.0 + (i % 500) * 0.01)

batch = [mk_line(i) for i in range(2000)]
try:
    with open(DATA, "a", encoding="utf-8") as f:
        f.write("\n".join(batch) + "\n")
    add_lines(batch)
    got, el = get_agg(timeout=30)
    if el > SLA:
        fails.append("2b incremental SLA: %.2fs > %.1fs after appending 2000 lines (must parse only the delta)" % (el, SLA))
    check(got, expect_of(state), "2b after append")
except Exception as e:
    fails.append("2b append failed: %s" % e)

# ---------- 2c. 半行：末尾不完整行不得计入，补齐后必须计入 ----------
try:
    tail = [mk_line(90000 + i, "ERROR") for i in range(500)]
    whole = '{"timestamp":"2026-10-24T23:50:00Z","level":"WARN","service":"probe-tail","latency_ms":7.25}'
    # 关键：写入一整行【合法 JSON】内容，但故意不写末尾换行符 —— 模拟写入方还没写完。
    # 只有这样才有区分度：用 splitlines() / for line in f 的实现会把这行算进去，
    # 而正确实现必须等换行符到达后才计入。
    with open(DATA, "a", encoding="utf-8") as f:
        f.write("\n".join(tail) + "\n")
        f.write(whole)                     # 完整 JSON，但没有换行符
    add_lines(tail)
    got, el = get_agg(timeout=30)
    if el > SLA:
        fails.append("2c half-line: %.2fs > %.1fs" % (el, SLA))
    check(got, expect_of(state), "2c trailing line without newline must be ignored")

    # 换行符到达
    with open(DATA, "a", encoding="utf-8") as f:
        f.write("\n")
    add_lines([whole])
    got, el = get_agg(timeout=30)
    if el > SLA:
        fails.append("2c completed line: %.2fs > %.1fs" % (el, SLA))
    check(got, expect_of(state), "2c after completing the line")
except Exception as e:
    fails.append("2c half-line test failed: %s" % e)

# ---------- 2d. 截断：文件变短必须丢弃增量状态重新计算 ----------
try:
    grown = [mk_line(700000 + i, "DEBUG") for i in range(1000)]
    with open(DATA, "a", encoding="utf-8") as f:
        f.write("\n".join(grown) + "\n")
    add_lines(grown)
    got, _ = get_agg(timeout=30)
    check(got, expect_of(state), "2d before truncate")

    os.truncate(DATA, base_size)           # 截断回基线大小
    state = copy.deepcopy(baseline)        # verifier 侧同步回退（深拷贝）
    got, el = get_agg(timeout=40)   # 传输上限略高于 ROTATE_SLA，判定以 ROTATE_SLA 为准
    if el > ROTATE_SLA:
        fails.append("2d truncate: %.2fs > %.1fs" % (el, ROTATE_SLA))
    check(got, expect_of(state), "2d after truncate (must fall back to full rescan)")
except Exception as e:
    fails.append("2d truncate test failed: %s" % e)

# ---------- 2e. 非法时间戳必须被过滤 ----------
try:
    bad = ['{"timestamp":"2026-10-24 10:00:03","level":"ERROR","service":"x","latency_ms":1.0}',
           '{"timestamp":"2026-10-24T10:00:03.500Z","level":"ERROR","service":"x","latency_ms":1.0}',
           '{"timestamp":"2026-10-24T10:00:04+08:00","level":"ERROR","service":"x","latency_ms":1.0}',
           '{"timestamp":"2026-10-24t10:00:05z","level":"ERROR","service":"x","latency_ms":1.0}']
    good = [mk_line(800000 + i, "INFO") for i in range(50)]
    with open(DATA, "a", encoding="utf-8") as f:
        f.write("\n" + "\n".join(bad + good) + "\n")   # 前置换行符：2d 截断后基线末行仍未提交
    add_lines([PENDING] + bad + good)                  # 截断回退后基线末行随换行符提交
    got, el = get_agg(timeout=30)
    if el > SLA:
        fails.append("2e bad-timestamp: %.2fs > %.1fs" % (el, SLA))
    check(got, expect_of(state), "2e bad timestamps must be filtered")
except Exception as e:
    fails.append("2e bad timestamp test failed: %s" % e)

print("OK" if not fails else "FAIL: " + "; ".join(fails))
PY
)
if [ "$ITEM2" = "OK" ]; then
    PASS=$((PASS + 1))
    echo "ITEM 2: PASS"
else
    echo "ITEM 2: FAIL - $ITEM2"
fi

echo
echo "===== ITEM 3/3: runtime identity + rotation + concurrency + flock ====="
ITEM3=$(python3 - <<'PY'
import concurrent.futures as cf
import fcntl, json, os, pwd, re, subprocess, threading, time, urllib.request

DATA = os.environ["DATA_FILE"]
BASE = os.environ["BASE"]
VENV_PY = os.environ["VENV_PY"]
APP_PY = os.environ["APP_PY"]
fails = []
ISO = re.compile(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$')
SLA = 1.5
ROTATE_SLA = 30.0


def get_agg(timeout=30):
    t0 = time.monotonic()
    r = urllib.request.urlopen(BASE + "/api/v1/aggregate", timeout=timeout)
    return json.loads(r.read().decode("utf-8", "replace")), time.monotonic() - t0


def full_scan():
    total = err = 0
    s = 0.0
    lv = {}

    def absorb(line):
        nonlocal total, err, s, lv
        line = line.strip()
        if not line:
            return
        try:
            r = json.loads(line)
        except Exception:
            return
        if not isinstance(r, dict):
            return
        ts = r.get("timestamp", "")
        if not isinstance(ts, str) or not ISO.match(ts):
            return
        lvl = r.get("level", "UNKNOWN")
        total += 1
        if lvl == "ERROR":
            err += 1
        lv[lvl] = lv.get(lvl, 0) + 1
        try:
            s += float(r.get("latency_ms", 0.0))
        except Exception:
            pass

    # verifier 口径：只有以换行符结尾的行才计入统计（EOF 未换行的尾行视为未提交）
    with open(DATA, "r", encoding="utf-8", errors="replace") as f:
        prev = None
        for line in f:
            if prev is not None:
                absorb(prev)
            prev = line
        if prev is not None and prev.endswith("\n"):
            absorb(prev)
    return {"total_logs": total, "error_count": err,
            "avg_latency_ms": round(s / total, 3) if total else 0.0, "levels": lv}


def check(got, want, label):
    if got.get("total_logs") != want["total_logs"]:
        fails.append("%s: total_logs=%r want %r" % (label, got.get("total_logs"), want["total_logs"]))
    if got.get("error_count") != want["error_count"]:
        fails.append("%s: error_count=%r want %r" % (label, got.get("error_count"), want["error_count"]))
    if got.get("levels") != want["levels"]:
        fails.append("%s: levels mismatch" % label)
    try:
        v = got.get("avg_latency_ms")
        # NaN/Infinity 防绕过：nan 与任何数的比较恒为 False，必须显式排除
        if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v or v in (float("inf"), float("-inf")):
            fails.append("%s: avg_latency_ms not finite numeric (%r)" % (label, v))
        elif abs(v - want["avg_latency_ms"]) > 0.001:
            fails.append("%s: avg_latency_ms=%r want %r" % (label, v, want["avg_latency_ms"]))
    except Exception:
        fails.append("%s: avg_latency_ms not numeric" % label)


# ---------- 3a. 9090 监听归属 + 服务进程身份 ----------
def listen_rows(port=9090):
    rows = []
    for path in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            lines = open(path).read().splitlines()[1:]
        except Exception:
            continue
        for ln in lines:
            p = ln.split()
            if len(p) < 10:
                continue
            try:
                if int(p[1].split(":")[1], 16) == port and p[3] == "0A":
                    rows.append({"local": p[1], "uid": int(p[7]), "inode": p[9]})
            except Exception:
                continue
    return rows


try:
    logsvc_uid = pwd.getpwnam("logsvc").pw_uid
except Exception:
    logsvc_uid = -1
    fails.append("system user logsvc not found")

rows = listen_rows()
if not rows:
    fails.append("nothing is LISTENing on :9090")
for r in rows:
    if r["uid"] != logsvc_uid:
        fails.append(":9090 LISTEN socket owned by uid=%s (want logsvc=%s)" % (r["uid"], logsvc_uid))

cands = []
for d in os.listdir("/proc"):
    if not d.isdigit():
        continue
    try:
        raw = open("/proc/%s/cmdline" % d, "rb").read().decode("utf-8", "replace")
    except Exception:
        continue
    argv = [a for a in raw.split("\x00") if a]
    if not argv:
        continue
    if APP_PY in argv and "python" in os.path.basename(argv[0]):
        try:
            uid = os.stat("/proc/%s" % d).st_uid
        except Exception:
            uid = -1
        cands.append({"pid": d, "argv": argv, "uid": uid})

owned = [c for c in cands if c["uid"] == logsvc_uid]
if not owned:
    fails.append("no logsvc-owned process running %s (found %d candidate(s))" % (APP_PY, len(cands)))
else:
    pid, argv = owned[0]["pid"], owned[0]["argv"]
    if os.path.realpath(argv[0]) != os.path.realpath(VENV_PY):
        fails.append("argv[0]=%r (want %s)" % (argv[0], VENV_PY))
    if not os.path.isfile("/opt/log-aggregator/venv/pyvenv.cfg"):
        fails.append("/opt/log-aggregator/venv/pyvenv.cfg missing (not a real venv)")
    else:
        try:
            out = subprocess.run([VENV_PY, "-c", "import sys; print(sys.prefix)"],
                                 capture_output=True, text=True, timeout=20).stdout.strip()
            if not out.startswith("/opt/log-aggregator/venv"):
                fails.append("venv interpreter sys.prefix=%r" % out)
        except Exception as e:
            fails.append("venv interpreter not runnable: %s" % e)

# ---------- 3b. 日志轮转（原子替换 inode） ----------
try:
    tmp = DATA + ".rotate"
    with open(tmp, "w", encoding="utf-8") as f:
        # 新文件首行：写入端轮转重启后落下的残段（行为描述见 instruction.md 写入端契约）
        f.write(', "service":"rot-tail","latency_ms":900.0}\n')
        buf = []
        for i in range(50000):
            lvl = ["INFO", "WARN", "ERROR", "DEBUG"][i % 4]
            buf.append('{"timestamp":"2026-11-%02dT%02d:%02d:%02dZ","level":"%s","service":"rot-%d","latency_ms":%.3f}'
                       % (1 + i % 28, i % 24, (i // 24) % 60, (i // 1440) % 60, lvl, i % 31, 2.0 + (i % 700) * 0.03))
            if len(buf) >= 10000:
                f.write("\n".join(buf) + "\n")
                buf.clear()
        if buf:
            f.write("\n".join(buf) + "\n")
    os.chmod(tmp, 0o644)
    with open(DATA, "a", encoding="utf-8") as f:
        f.write('{"timestamp":"2026-11-28T10:15:30Z","level":"ERROR","service":"rot-tail","latency_ms":7.5')
    os.replace(tmp, DATA)                  # 新 inode
    want = full_scan()
    got, el = get_agg(timeout=40)   # 传输上限略高于 ROTATE_SLA，判定以 ROTATE_SLA 为准
    if el > ROTATE_SLA:
        fails.append("3b rotation: %.2fs > %.1fs" % (el, ROTATE_SLA))
    check(got, want, "3b after rotation (inode changed)")
except Exception as e:
    fails.append("3b rotation test failed: %s" % e)

# ---------- 3c. 20 并发：不得重复累加 ----------
try:
    add = ['{"timestamp":"2026-11-30T%02d:%02d:%02dZ","level":"%s","service":"cc-%d","latency_ms":%.3f}'
           % (i % 24, (i // 24) % 60, (i // 1440) % 60, ["INFO", "ERROR"][i % 2], i % 17, 3.0 + (i % 90) * 0.05)
           for i in range(5000)]
    with open(DATA, "a", encoding="utf-8") as f:
        f.write("\n".join(add) + "\n")
        f.flush()
        os.fsync(f.fileno())
    time.sleep(0.3)                    # 写入完全落盘并稳定后，再进入并发窗口
    want = full_scan()

    def one():
        return get_agg(timeout=30)

    # 计时前先发两次不计时的请求：消除首次访问新页/冷缓存的调度抖动，
    # 使 1.5s SLA 的测量只反映"变更后首个请求"的增量解析能力
    for _ in range(2):
        try:
            get_agg(timeout=30)
        except Exception:
            pass

    with cf.ThreadPoolExecutor(max_workers=20) as ex:
        futs = [ex.submit(one) for _ in range(20)]
        results = [f.result() for f in futs]
    slow = [e for _, e in results if e > SLA]
    if slow:
        fails.append("3c concurrency: %d/20 requests exceeded %.1fs (max %.2fs)"
                     % (len(slow), SLA, max(slow)))
    # 全部 20 个响应都必须与真值一致（写窗口已关闭，不存在新旧状态并存）
    for i, (got, _) in enumerate(results):
        if got != want:
            fails.append("3c concurrency: response #%d inconsistent with truth" % i)
            break
except Exception as e:
    fails.append("3c concurrency test failed: %s" % e)

# ---------- 3d. flock：持锁写入期间不得看到半写状态 ----------
STATE_A = ['{"timestamp": "2026-10-23T09:00:00Z", "level": "INFO", "service": "a", "latency_ms": 10.0}',
           '{"timestamp": "2026-10-23T09:00:01Z", "level": "INFO", "service": "a", "latency_ms": 20.0}']
STATE_B = ['{"timestamp": "2026-10-23T09:00:00Z", "level": "ERROR", "service": "b", "latency_ms": 30.0}',
           '{"timestamp": "2026-10-23T09:00:01Z", "level": "INFO",  "service": "b", "latency_ms": 40.0}',
           '{"timestamp": "2026-10-23T09:00:02Z", "level": "WARN",  "service": "b", "latency_ms": 50.0}',
           '{"timestamp": "2026-10-23T09:00:03Z", "level": "ERROR", "service": "b", "latency_ms": 60.0}',
           '{"timestamp": "2026-10-23T09:00:04Z", "level": "INFO",  "service": "b", "latency_ms": 70.0}']

def aggregate(lines):
    total, errors, lats, lv = 0, 0, [], {}
    for line in lines:
        rec = json.loads(line)
        lvl = rec["level"]
        total += 1
        if lvl == "ERROR":
            errors += 1
        lv[lvl] = lv.get(lvl, 0) + 1
        lats.append(float(rec["latency_ms"]))
    return {"total_logs": total, "error_count": errors,
            "avg_latency_ms": round(sum(lats) / len(lats), 3), "levels": lv}

EXPECT = {2: aggregate(STATE_A), 5: aggregate(STATE_B)}
stop = threading.Event()

def writer():
    seq = [STATE_A, STATE_B]
    i = 0
    while not stop.is_set():
        lines = seq[i % 2]
        i += 1
        try:
            with open(DATA, "r+", encoding="utf-8") as f:
                fcntl.flock(f.fileno(), fcntl.LOCK_EX)
                f.seek(0)
                f.truncate()
                f.write(lines[0] + "\n")
                f.flush()
                time.sleep(0.05)
                f.write("\n".join(lines[1:]) + "\n")
                f.flush()
                os.fsync(f.fileno())
                fcntl.flock(f.fileno(), fcntl.LOCK_UN)
        except Exception:
            pass
        time.sleep(0.04)

t = threading.Thread(target=writer, daemon=True)
t.start()
bad = []
observed = set()
stale_grace = 2    # 允许至多 2 次落在"等锁超时返回上一次完整快照"的合法路径
                   # （写锁持有时 3e 契约允许返回旧快照；重试应观察到新状态）
try:
    for _ in range(25):
        try:
            r = urllib.request.urlopen(BASE + "/api/v1/aggregate", timeout=5)
            res = json.loads(r.read().decode("utf-8", "replace"))
        except Exception as e:
            bad.append("request error: %s" % e)
            break
        tot = res.get("total_logs")
        observed.add(tot)
        if tot not in (2, 5):
            if stale_grace > 0:
                stale_grace -= 1
                time.sleep(0.15)
                continue
            bad.append("torn read: total_logs=%r (want 2 or 5)" % tot)
            break
        want = EXPECT[tot]
        v = res.get("avg_latency_ms")
        avg_bad = (isinstance(v, bool) or not isinstance(v, (int, float))
                   or v != v or v in (float("inf"), float("-inf"))
                   or abs(v - want["avg_latency_ms"]) >= 0.001)   # NaN 比较恒 False，须显式排除
        if res.get("levels") != want["levels"] or res.get("error_count") != want["error_count"] or avg_bad:
            bad.append("inconsistent snapshot at total=%r: got=%r want=%r" % (tot, res, want))
            break
        time.sleep(0.05)
finally:
    stop.set()
    t.join(timeout=2)

if bad:
    fails.extend(bad)
if not observed:
    fails.append("no successful request during concurrency window")

# ---------- 3e. 长时间持锁：必须 <=2s 返回上一次完整快照 ----------
def write_locked(lines):
    with open(DATA, "r+", encoding="utf-8") as f:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX)
        f.seek(0)
        f.truncate()
        f.write("\n".join(lines) + "\n")
        f.flush()
        os.fsync(f.fileno())
        fcntl.flock(f.fileno(), fcntl.LOCK_UN)

try:
    write_locked(STATE_A)
    time.sleep(0.25)
    primed, _ = get_agg(timeout=30)
    if primed.get("total_logs") != 2:
        fails.append("prime snapshot total_logs=%r (want 2)" % primed.get("total_logs"))
except Exception as e:
    fails.append("prime failed: %s" % e)
    primed = None

if primed is not None and primed.get("total_logs") == 2:
    holding = threading.Event()

    def long_writer():
        try:
            with open(DATA, "r+", encoding="utf-8") as f:
                fcntl.flock(f.fileno(), fcntl.LOCK_EX)
                f.seek(0)
                f.truncate()
                f.write(STATE_B[0] + "\n")
                f.flush()
                holding.set()
                time.sleep(3.5)
                f.write("\n".join(STATE_B[1:]) + "\n")
                f.flush()
                os.fsync(f.fileno())
                fcntl.flock(f.fileno(), fcntl.LOCK_UN)
        except Exception:
            holding.set()

    th = threading.Thread(target=long_writer, daemon=True)
    th.start()
    holding.wait(timeout=3)
    time.sleep(0.15)

    t0 = time.monotonic()
    try:
        during = json.loads(urllib.request.urlopen(BASE + "/api/v1/aggregate", timeout=9).read().decode("utf-8", "replace"))
        elapsed = time.monotonic() - t0
        if elapsed > 2.0:
            fails.append("lock contention: %.2fs to respond (must be <= 2s)" % elapsed)
        if during.get("total_logs") != 2:
            fails.append("during long lock hold: total_logs=%r (want last complete snapshot 2)" % during.get("total_logs"))
    except Exception as e:
        fails.append("during lock hold request failed: %s" % e)
    th.join(timeout=12)

    time.sleep(0.3)
    try:
        after, _ = get_agg(timeout=30)
        if after.get("total_logs") != 5:
            fails.append("after writer finished: total_logs=%r (want 5)" % after.get("total_logs"))
    except Exception as e:
        fails.append("post-writer request failed: %s" % e)

# ---------- 3f. 轮转进行中的并发：响应必须是旧态或新态之一，不得撕裂 ----------
try:
    write_locked(STATE_B)
    time.sleep(0.25)
    get_agg(timeout=30)
    want_old = full_scan()

    tmp2 = DATA + ".rot2"
    with open(tmp2, "w", encoding="utf-8") as f:
        for i in range(20000):
            f.write('{"timestamp":"2026-12-%02dT%02d:%02d:%02dZ","level":"%s","service":"r2-%d","latency_ms":%.3f}\n'
                    % (1 + i % 28, i % 24, (i // 24) % 60, (i // 1440) % 60,
                       ["INFO", "WARN", "ERROR", "DEBUG"][i % 4], i % 41, 1.5 + (i % 800) * 0.02))
    os.chmod(tmp2, 0o644)

    def swapper():
        time.sleep(0.05)
        try:
            os.replace(tmp2, DATA)
        except Exception:
            pass

    sw = threading.Thread(target=swapper, daemon=True)
    sw.start()
    with cf.ThreadPoolExecutor(max_workers=20) as ex:
        futs = [ex.submit(lambda: get_agg(timeout=40)) for _ in range(20)]
        results = [fu.result() for fu in futs]
    sw.join(timeout=10)
    want_new = full_scan()

    for got, _ in results:
        if got != want_old and got != want_new:
            fails.append("3f rotation+concurrency: torn response %r" % got.get("total_logs"))
            break
except Exception as e:
    fails.append("3f rotation+concurrency test failed: %s" % e)

print("OK" if not fails else "FAIL: " + "; ".join(fails))
PY
)
if [ "$ITEM3" = "OK" ]; then
    PASS=$((PASS + 1))
    echo "ITEM 3: PASS"
else
    echo "ITEM 3: FAIL - $ITEM3"
fi

REWARD=$(awk -v s="$PASS" -v t="$TOTAL" 'BEGIN {printf "%.2f", s/t}')
echo
echo "===== RESULT: $PASS/$TOTAL -> reward=$REWARD ====="

# harbor 通过下载容器内 /logs/verifier 目录来收集判分结果，
# reward.txt 必须写在 stdout 同目录下，否则 RewardFileNotFoundError
mkdir -p "$(dirname "$REWARD_FILE")"
printf '%s' "$REWARD" > "$REWARD_FILE"
echo "[reward] written to $REWARD_FILE"
