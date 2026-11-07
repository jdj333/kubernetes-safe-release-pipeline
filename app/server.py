"""Dependency-free release laboratory, not an Internet-facing production server."""
import json
import math
import os
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen


def event(name, **fields):
    print(json.dumps({"event": name, **fields}), flush=True)


class Server(ThreadingHTTPServer):
    # server_close waits for accepted requests before process exit.
    daemon_threads = False
    block_on_close = True
    allow_reuse_address = True

    def get_request(self):
        conn, address = super().get_request()
        conn.settimeout(5)
        return conn, address


def run():
    draining = threading.Event()
    started = time.monotonic()
    version = os.getenv("APP_VERSION", "1.0.0")
    startup_delay = float(os.getenv("STARTUP_DELAY_SECONDS", "0"))
    fail_ready = os.getenv("FAIL_READINESS", "false").lower() == "true"
    fail_business = os.getenv("FAIL_BUSINESS", "false").lower() == "true"

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def respond(self, status_code, **body):
            payload = json.dumps({"version": version, **body}).encode()
            self.send_response(status_code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):
            url = urlparse(self.path)
            initialized = time.monotonic() - started >= startup_delay
            if url.path == "/healthz":
                self.respond(200, status="alive")
            elif url.path == "/startupz":
                self.respond(200 if initialized else 503, started=initialized)
            elif url.path == "/readyz":
                ready = initialized and not fail_ready and not draining.is_set()
                self.respond(200 if ready else 503, ready=ready)
            elif url.path == "/api/order":
                self.respond(500 if fail_business else 200,
                             status="broken" if fail_business else "accepted")
            elif url.path in ("/", "/version"):
                self.respond(200, service="safe-release")
            elif url.path == "/work":
                try:
                    seconds = float(parse_qs(url.query).get("seconds", ["1"])[0])
                    if not math.isfinite(seconds) or not 0 <= seconds <= 5:
                        raise ValueError()
                except ValueError:
                    self.respond(400, error="seconds must be between 0 and 5")
                    return
                event("work_started", seconds=seconds)
                time.sleep(seconds)
                self.respond(200, status="completed")
            else:
                self.respond(404, error="not found")

    class Admin(Handler):
        def do_GET(self):
            self.respond(404, error="not found")

        def do_POST(self):
            if self.path != "/drain":
                self.respond(404, error="not found")
                return
            draining.set()
            event("draining")
            self.respond(200, status="draining")

    server = Server(("0.0.0.0", int(os.getenv("PORT", "8080"))), Handler)
    admin = Server(("127.0.0.1", int(os.getenv("ADMIN_PORT", "9000"))), Admin)
    stopping = threading.Event()

    def shutdown(signum, _frame):
        if stopping.is_set():
            return
        stopping.set()
        draining.set()
        event("shutdown_started", signal=signum)
        # Bound shutdown even if a client holds a socket indefinitely.
        watchdog = threading.Timer(10, lambda: os._exit(1))
        watchdog.daemon = True
        watchdog.start()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    threading.Thread(target=admin.serve_forever, daemon=True).start()
    event("listening", port=server.server_address[1], version=version)
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        admin.shutdown()
        admin.server_close()
        server.server_close()
        event("shutdown_complete")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "drain":
        port = os.getenv("ADMIN_PORT", "9000")
        with urlopen(Request(f"http://127.0.0.1:{port}/drain", method="POST"), timeout=2):
            pass
        # Existing traffic still succeeds while endpoint removal propagates.
        time.sleep(float(os.getenv("DRAIN_SECONDS", "5")))
    else:
        run()
