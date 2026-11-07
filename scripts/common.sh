#!/usr/bin/env bash
# All mutation helpers are deliberately restricted to this disposable cluster.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly CONTEXT=kind-safe-release-demo NAMESPACE=safe-release-demo RELEASE=safe-release
readonly CHART="$ROOT/charts/safe-release"
ARTIFACTS="${ARTIFACTS:-$ROOT/artifacts}"
mkdir -p "$ARTIFACTS"
k() { kubectl --context "$CONTEXT" --namespace "$NAMESPACE" "$@"; }
h() { helm --kube-context "$CONTEXT" --namespace "$NAMESPACE" "$@"; }
preflight() {
  for tool in kubectl helm python3; do command -v "$tool" >/dev/null; done
  [[ $(helm version --short) == v4.* ]] || { echo 'Helm 4 is required' >&2; return 1; }
  kubectl config get-contexts "$CONTEXT" -o name | python3 -c \
    'import sys; assert sys.stdin.read().strip() == "kind-safe-release-demo", "Create the demo cluster first"'
  k get --raw=/readyz >/dev/null
}
collect() { bash "$ROOT/scripts/diagnose.sh" "${1:-diagnostics}" || true; }
