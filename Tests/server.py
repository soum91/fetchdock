"""Local HTTP fixture for real URLSession transfer tests on the iOS Simulator."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time
import json
import threading

PAYLOAD = bytes(range(251)) * (2097152 // 251) + bytes(range(2097152 % 251))
STATS = {}
LOCK = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/segment-stats':
            with LOCK:
                data = json.dumps(STATS).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if self.path in ('/segments', '/segments-slow', '/ignore-ranges', '/bad-range', '/changing-etag', '/no-validator'):
            self.serve_segments()
            return
        if self.path == '/redirect-other-host':
            self.send_response(302)
            self.send_header('Location', f'http://localhost:{self.server.server_port}/no-cookies')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path == '/no-cookies':
            if self.headers.get('Cookie'):
                self.send_error(403, 'Cookie leaked across hosts')
                return
            self.path = '/file'
        if self.path == '/private-release':
            if 'user_session=fixture-session' not in self.headers.get('Cookie', ''):
                self.send_error(404)
            else:
                self.send_response(302)
                self.send_header('Location', '/file')
                self.send_header('Content-Length', '0')
                self.end_headers()
            return
        if self.path not in ('/file', '/slow'):
            self.send_error(404)
            return
        size = 2097152 if self.path == '/slow' else 524288
        start, end = 0, size - 1
        ranged = bool(self.headers.get('Range'))
        if ranged:
            first, last = self.headers['Range'].split('=')[1].split('-')
            start = int(first)
            if last: end = min(int(last), size - 1)
        if start >= size or end < start:
            self.send_error(416)
            return
        self.send_response(206 if ranged else 200)
        self.send_header('Content-Length', str(end - start + 1))
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Disposition', 'attachment; filename="fixture.bin"')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('ETag', '"fetchdock-fixture-v1"')
        self.send_header('Last-Modified', 'Wed, 21 Oct 2026 07:28:00 GMT')
        if ranged:
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        self.end_headers()
        try:
            for offset in range(start, end + 1, 32768):
                self.wfile.write(b'F' * min(32768, end + 1 - offset))
                self.wfile.flush()
                if self.path == '/slow':
                    time.sleep(0.05)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def serve_segments(self):
        size = len(PAYLOAD)
        ranged = self.headers.get('Range') and self.path != '/ignore-ranges'
        first, last = 0, size - 1
        if ranged:
            start, end = self.headers['Range'].split('=')[1].split('-')
            first, last = int(start), int(end) if end else size - 1
        if first < 0 or first >= size or last < first or last >= size:
            self.send_error(416)
            return
        segment = bool(ranged and last > first)
        with LOCK:
            stats = STATS.setdefault(self.path, {'active': 0, 'peak': 0, 'parts': 0, 'full': 0})
            if segment:
                stats['active'] += 1
                stats['peak'] = max(stats['peak'], stats['active'])
                stats['parts'] += 1
            if not ranged: stats['full'] += 1
        try:
            self.send_response(206 if ranged else 200)
            self.send_header('Content-Length', str(last - first + 1))
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Disposition', 'attachment; filename="segments.bin"')
            self.send_header('Accept-Ranges', 'bytes')
            if self.path != '/no-validator':
                etag = '"fixture-v2"' if segment and self.path == '/changing-etag' else '"fixture-v1"'
                self.send_header('ETag', etag)
            if ranged:
                reported = first + 1 if segment and self.path == '/bad-range' else first
                self.send_header('Content-Range', f'bytes {reported}-{last}/{size}')
            self.end_headers()
            for offset in range(first, last + 1, 32768):
                self.wfile.write(PAYLOAD[offset:min(last + 1, offset + 32768)])
                self.wfile.flush()
                if segment: time.sleep(0.08 if self.path == '/segments-slow' else 0.015)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            if segment:
                with LOCK: STATS[self.path]['active'] -= 1

if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', 8765), Handler).serve_forever()
