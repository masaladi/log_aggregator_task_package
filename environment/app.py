# ============================================================================
# 本文件是"上一任遗留"的初始服务：可运行，但存在多处【故意保留】的缺陷，
# 是任务要求被测代理排查修复的对象（见 environment/Dockerfile 中的角色注释）。
# 已知故意缺陷包括但不限于：
#   - 默认端口与数据文件路径错误（依赖 config.json 与现场修正）
#   - 未实现 HEAD 方法契约（缺与 GET 同头不同体的 HEAD 响应）
#   - 每次请求全量重解析，无法满足增量时延门槛
#   - 无 flock 共享锁等待与快照回退、无 ISO 8601 严格校验
#   - 其余配置、权限与并发缺陷由被测代理自行发现
# ============================================================================
import http.server
import json
import os
import urllib.parse
import re

CONFIG_PATH = "/etc/log-aggregator/config.json"
ISO8601_REGEX = re.compile(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$')

def load_config():
    port = 9091 # Intentional bug in default env
    data_file = "/var/lib/log-aggregator/logs.err" # Intentional bug
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, 'r', encoding='utf-8') as f:
                cfg = json.load(f)
                port = cfg.get("server", {}).get("port", port)
                data_file = cfg.get("server", {}).get("data_file", data_file)
        except Exception:
            pass
    return port, data_file

class LogAggregatorHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed_path = urllib.parse.urlparse(self.path)
        path = parsed_path.path

        if path == "/healthz":
            response_data = {"status": "healthy"}
            body = json.dumps(response_data).encode('utf-8')
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("X-Log-Aggregator-Status", "Verified")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        elif path == "/api/v1/aggregate":
            port, data_file = load_config()
            total_logs = 0
            error_count = 0
            total_latency = 0.0
            levels = {}

            if os.path.exists(data_file):
                try:
                    with open(data_file, 'r', encoding='utf-8') as f:
                        # Intentionally missing fcntl.flock in initial bug state
                        for line in f:
                            line = line.strip()
                            if not line:
                                continue
                            try:
                                record = json.loads(line)
                                ts = record.get("timestamp", "")
                                # Intentionally missing strict ISO 8601 regex validation in initial buggy app
                                # Agents must implement ISO 8601 validation!
                                lvl = record.get("level", "UNKNOWN")
                                lat = float(record.get("latency_ms", 0.0))
                                
                                total_logs += 1
                                if lvl == "ERROR":
                                    error_count += 1
                                levels[lvl] = levels.get(lvl, 0) + 1
                                total_latency += lat
                            except Exception:
                                pass
                except Exception:
                    pass

            avg_latency = round(total_latency / total_logs, 3) if total_logs > 0 else 0.0
            response_data = {
                "total_logs": total_logs,
                "error_count": error_count,
                "avg_latency_ms": avg_latency,
                "levels": levels
            }
            body = json.dumps(response_data).encode('utf-8')
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("X-Log-Aggregator-Status", "Verified")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.send_header("X-Log-Aggregator-Status", "Verified")
            self.end_headers()

    # 非 GET/HEAD 方法：按契约返回 405 + Allow（此部分与契约一致；
    # 其余缺陷——端口/数据路径/ISO 校验/增量/flock——仍为故意保留）
    def _method_not_allowed(self):
        self.send_response(405)
        self.send_header("Allow", "GET, HEAD")
        self.send_header("X-Log-Aggregator-Status", "Verified")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        self._method_not_allowed()

    def do_PUT(self):
        self._method_not_allowed()

    def do_DELETE(self):
        self._method_not_allowed()

    def do_OPTIONS(self):
        self._method_not_allowed()

    def do_PATCH(self):
        self._method_not_allowed()

    def log_message(self, format, *args):
        return

def run():
    port, _ = load_config()
    server_address = ('0.0.0.0', port)
    httpd = http.server.HTTPServer(server_address, LogAggregatorHandler)
    httpd.serve_forever()

if __name__ == '__main__':
    run()
