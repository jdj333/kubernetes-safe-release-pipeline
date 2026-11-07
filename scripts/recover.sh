#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
preflight
revision="${1:?usage: recover.sh KNOWN_GOOD_REVISION}"
[[ "$revision" =~ ^[1-9][0-9]*$ ]] || { echo 'Use an explicit positive revision, never 0' >&2; exit 2; }
values="$(h get values "$RELEASE" --revision "$revision" -o json)"
expected="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["app"]["version"])' <<< "$values")"
collect before-recovery
h rollback "$RELEASE" "$revision" --wait --timeout 180s --cleanup-on-fail
k rollout status "deployment/$RELEASE" --timeout=180s
bash "$ROOT/scripts/smoke.sh" "$expected"
echo "RECOVERED: revision $revision, application $expected; rollback creates a new Helm revision"
