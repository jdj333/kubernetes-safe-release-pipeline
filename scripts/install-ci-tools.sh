#!/usr/bin/env bash
# Versioned official downloads, verified before execution. Linux amd64 CI helper.
set -Eeuo pipefail
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'Linux amd64 only; see README for local prerequisites'; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.tools"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fsSL --retry 3 https://get.helm.sh/helm-v4.3.1-linux-amd64.tar.gz -o "$work/helm.tar.gz"
curl -fsSL --retry 3 https://get.helm.sh/helm-v4.3.1-linux-amd64.tar.gz.sha256sum -o "$work/helm.sha256sum"
python3 - "$work" <<'PY'
import hashlib,pathlib,sys,tarfile
p=pathlib.Path(sys.argv[1])
assert hashlib.sha256((p/'helm.tar.gz').read_bytes()).hexdigest()==(p/'helm.sha256sum').read_text().split()[0]
with tarfile.open(p/'helm.tar.gz') as t: t.extract('linux-amd64/helm',p,filter='data')
PY
install -m 755 "$work/linux-amd64/helm" "$ROOT/.tools/helm"
curl -fsSL --retry 3 https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-linux-amd64 -o "$work/kind"
echo "aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d  $work/kind" | sha256sum -c -
install -m 755 "$work/kind" "$ROOT/.tools/kind"
curl -fsSL --retry 3 https://dl.k8s.io/release/v1.35.8/bin/linux/amd64/kubectl -o "$work/kubectl"
curl -fsSL --retry 3 https://dl.k8s.io/release/v1.35.8/bin/linux/amd64/kubectl.sha256 -o "$work/kubectl.sha256"
echo "$(cat "$work/kubectl.sha256")  $work/kubectl" | sha256sum -c -
install -m 755 "$work/kubectl" "$ROOT/.tools/kubectl"
echo "Add $ROOT/.tools to PATH"
