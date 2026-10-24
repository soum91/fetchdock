"""Local HTTP fixture for real URLSession transfer tests on the iOS Simulator."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ('/file', '/slow'):
            self.send_error(404)
            return
        size = 2097152 if self.path == '/slow' else 524288
        start = 0
        if self.headers.get('Range'):
            start = int(self.headers['Range'].split('=')[1].split('-')[0])
        self.send_response(206 if start else 200)
        self.send_header('Content-Length', str(size - start))
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Disposition', 'attachment; filename="fixture.bin"')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('ETag', '"fetchdock-fixture-v1"')
        self.send_header('Last-Modified', 'Wed, 21 Oct 2026 07:28:00 GMT')
        if start:
            self.send_header('Content-Range', f'bytes {start}-{size-1}/{size}')
        self.end_headers()
        try:
            for offset in range(start, size, 32768):
                self.wfile.write(b'F' * min(32768, size - offset))
                self.wfile.flush()
                if self.path == '/slow':
                    time.sleep(0.05)
        except (BrokenPipeError, ConnectionResetError):
            pass

if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', 8765), Handler).serve_forever()
