"""Verify the Service, readiness, release identity, and a business response."""
import json
import sys
import time
from urllib.request import urlopen


def check(base_url, expected):
    for _ in range(5):
        for path in ("/readyz", "/version", "/api/order"):
            with urlopen(base_url.rstrip("/") + path, timeout=3) as response:
                body = json.load(response)
                if response.status != 200 or body.get("version") != expected:
                    raise RuntimeError(f"Unexpected release response at {path}: {body}")
                if path == "/readyz" and body.get("ready") is not True:
                    raise RuntimeError("Application is not ready")
                if path == "/api/order" and body.get("status") != "accepted":
                    raise RuntimeError("Business transaction failed")
        time.sleep(0.1)
    print(f"PASS: Service routes healthy business requests to version {expected}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: smoke.py BASE_URL EXPECTED_VERSION")
    check(sys.argv[1], sys.argv[2])
