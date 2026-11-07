#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for tool in kind docker kubectl; do command -v "$tool" >/dev/null; done
docker info >/dev/null
if kind get clusters | grep -qx safe-release-demo; then
  echo 'The safe-release-demo cluster already exists; reusing it.'
else
  kind create cluster --name safe-release-demo --config "$ROOT/examples/kind.yaml" \
    --image kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0 --wait 180s
fi
kubectl --context kind-safe-release-demo wait --for=condition=Ready nodes --all --timeout=180s
