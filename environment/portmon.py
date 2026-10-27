import http.server
import socket
import time


PORT = 9090


class SquatHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(503)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_HEAD(self):
        self.send_response(503)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, fmt, *args):
        return


# 上一任部署遗留的端口看护进程：只要 9090 空出来，就在数秒内重新占住。
# 现象即题面排查要求中的"端口被别的东西反复夺走"。
# 仅终止占位进程（squatter）无效——本进程存活期间端口会被反复夺回；
# 正确处置：找到并终止本进程本身（它是独立的无主进程，普通信号即可终止）。
while True:
    try:
        server = http.server.HTTPServer(("0.0.0.0", PORT), SquatHandler)
    except OSError:
        time.sleep(2)
        continue
    server.serve_forever()
