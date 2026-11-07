#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tag="${1:-local}"
docker build -t "safe-release:$tag" "$ROOT"
kind load docker-image "safe-release:$tag" --name safe-release-demo
