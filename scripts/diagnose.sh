#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
preflight
out="$ARTIFACTS/${1:-diagnostics}"
mkdir -p "$out"
k get deployments,replicasets,pods,services,endpointslices,pdb -o wide > "$out/resources.txt" 2>&1 || true
k describe deployment "$RELEASE" > "$out/deployment.txt" 2>&1 || true
k describe pods -l "app.kubernetes.io/instance=$RELEASE" > "$out/pods.txt" 2>&1 || true
k get events --sort-by=.metadata.creationTimestamp > "$out/events.txt" 2>&1 || true
k logs -l "app.kubernetes.io/instance=$RELEASE" --all-containers --prefix --tail=200 > "$out/app.log" 2>&1 || true
h history "$RELEASE" -o json > "$out/history.json" 2>&1 || true
# No Secrets or kubeconfig are collected.
echo "Diagnostics: $out"
