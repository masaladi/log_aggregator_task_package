import http.server

class DummyHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(503)
        self.end_headers()
        self.wfile.write(b"Port 9090 is squatted")

if __name__ == '__main__':
    server = http.server.HTTPServer(('0.0.0.0', 9090), DummyHandler)
    server.serve_forever()
