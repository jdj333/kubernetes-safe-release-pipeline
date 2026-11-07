import concurrent.futures
import contextlib
import json
import os
from pathlib import Path
import queue
import signal
import socket
import subprocess
import sys
import threading
import time
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]


def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def request(base, path, method='GET'):
    try:
        response = urlopen(Request(base + path, method=method), timeout=8)
    except HTTPError as exc:
        response = exc
    with response:
        return response.status, json.load(response)


@contextlib.contextmanager
def running(**overrides):
    app_port, admin_port = port(), port()
    while app_port == admin_port:
        admin_port = port()
    proc = subprocess.Popen([sys.executable, str(ROOT / 'app/server.py')],
                            env={**os.environ, 'PORT': str(app_port), 'ADMIN_PORT': str(admin_port),
                                 'APP_VERSION': 'test-v1', **overrides},
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    events = queue.Queue()
    def read_events():
        for line in proc.stdout:
            events.put(line)
    reader = threading.Thread(target=read_events, daemon=True)
    reader.start()
    base, admin = f'http://127.0.0.1:{app_port}', f'http://127.0.0.1:{admin_port}'
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                if request(base, '/healthz')[0] == 200:
                    break
            except OSError:
                time.sleep(0.02)
        else:
            raise AssertionError('Server did not start')
        yield proc, base, admin, events
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=12)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
        reader.join(timeout=1)
        proc.stdout.close()


class ApplicationTests(unittest.TestCase):
    def test_ready_and_business_contract(self):
        with running() as (_, base, _, _):
            self.assertEqual(request(base, '/readyz'), (200, {'version': 'test-v1', 'ready': True}))
            result = subprocess.run([sys.executable, str(ROOT / 'app/smoke.py'), base, 'test-v1'], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            wrong = subprocess.run([sys.executable, str(ROOT / 'app/smoke.py'), base, 'wrong'], capture_output=True)
            self.assertNotEqual(wrong.returncode, 0)

    def test_unready_does_not_mean_dead(self):
        with running(FAIL_READINESS='true') as (_, base, _, _):
            self.assertEqual(request(base, '/healthz')[0], 200)
            self.assertEqual(request(base, '/startupz')[0], 200)
            self.assertEqual(request(base, '/readyz')[0], 503)

    def test_business_failure_passes_readiness_but_fails_smoke(self):
        with running(FAIL_BUSINESS='true') as (_, base, _, _):
            self.assertEqual(request(base, '/readyz')[0], 200)
            self.assertEqual(request(base, '/api/order')[0], 500)
            result = subprocess.run([sys.executable, str(ROOT / 'app/smoke.py'), base, 'test-v1'], capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_startup_probe_protects_slow_initialization(self):
        with running(STARTUP_DELAY_SECONDS='0.8') as (_, base, _, _):
            self.assertEqual(request(base, '/startupz')[0], 503)
            self.assertEqual(request(base, '/readyz')[0], 503)
            deadline = time.monotonic() + 3
            while request(base, '/startupz')[0] != 200 and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertEqual(request(base, '/readyz')[0], 200)

    def test_drain_stops_readiness_without_dropping_residual_traffic(self):
        with running() as (_, base, admin, _):
            self.assertEqual(request(base, '/drain')[0], 404)
            self.assertEqual(request(admin, '/drain', 'POST')[0], 200)
            self.assertEqual(request(base, '/readyz')[0], 503)
            self.assertEqual(request(base, '/api/order')[0], 200)
            self.assertEqual(request(base, '/healthz')[0], 200)

    def test_sigterm_completes_an_accepted_request(self):
        with running() as (proc, base, _, events):
            with concurrent.futures.ThreadPoolExecutor() as pool:
                work = pool.submit(request, base, '/work?seconds=1')
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    line = events.get(timeout=5)
                    if '"event": "work_started"' in line:
                        break
                else:
                    self.fail('Request was never accepted')
                proc.send_signal(signal.SIGTERM)
                self.assertEqual(work.result(timeout=5)[1]['status'], 'completed')
                self.assertEqual(proc.wait(timeout=5), 0)

    def test_request_duration_is_bounded(self):
        with running() as (_, base, _, _):
            for value in ('-1', '6', 'nan', 'inf', 'oops'):
                self.assertEqual(request(base, '/work?seconds=' + value)[0], 400)


if __name__ == '__main__':
    unittest.main()
