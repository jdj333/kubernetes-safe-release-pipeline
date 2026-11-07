#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
preflight
tag="${1:-local}"
current_revision() {
  h list --filter "^${RELEASE}$" -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["revision"])'
}
assert_recovered_fault() {
  local before="$1" flag="$2" expected="$3"
  local after candidate
  after="$(current_revision)"
  [[ "$after" -eq "$((before + 2))" ]] || { echo 'Expected one candidate and one rollback revision' >&2; return 1; }
  candidate="$(h get values "$RELEASE" --revision "$((before + 1))" -o json)"
  python3 -c 'import json,sys; app=json.load(sys.stdin)["app"]; assert app[sys.argv[1]] is True; assert app["version"]==sys.argv[2]' "$flag" "$expected" <<< "$candidate"
}
# Isolated lab only. This intentionally changes the demo release.
bash "$ROOT/scripts/deploy.sh" "$tag" 1.0.0
baseline="$(h list --filter "^${RELEASE}$" -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["revision"])')"
echo "Manual recovery target: $baseline"
# Leave one failed rollout in place so operators can inspect it and practice recovery.
if h upgrade "$RELEASE" "$CHART" --reset-values -f "$ROOT/examples/broken-readiness.yaml" \
    --set-string "image.tag=$tag" --set-string app.version=2.0.0-broken-readiness --wait --timeout 90s; then
  echo 'ERROR: deliberately unready release unexpectedly succeeded' >&2
  exit 1
fi
# Prove the expected fault was applied, rather than treating any CLI error as success.
k get deployment "$RELEASE" -o json | python3 -c 'import json,sys; d=json.load(sys.stdin); e={v["name"]:v["value"] for v in d["spec"]["template"]["spec"]["containers"][0]["env"]}; assert e["FAIL_READINESS"]=="true"; assert d["status"].get("updatedReplicas",0)>0; assert d["status"].get("availableReplicas",0)>=2'
collect manual-readiness-failure
# Old healthy replicas must still be serving through the actual Service.
bash "$ROOT/scripts/smoke.sh" 1.0.0
bash "$ROOT/scripts/recover.sh" "$baseline"
# Exercise automated readiness rollback.
before="$(current_revision)"
if RELEASE_TIMEOUT=90s bash "$ROOT/scripts/deploy.sh" "$tag" 2.0.0-auto-readiness "$ROOT/examples/broken-readiness.yaml"; then
  echo 'ERROR: broken readiness release was accepted' >&2; exit 1
fi
assert_recovered_fault "$before" failReadiness 2.0.0-auto-readiness
bash "$ROOT/scripts/smoke.sh" 1.0.0
# Exercise failure after readiness passes, requiring the explicit smoke-test rollback.
before="$(current_revision)"
if bash "$ROOT/scripts/deploy.sh" "$tag" 2.0.0-broken-business "$ROOT/examples/broken-business.yaml"; then
  echo 'ERROR: broken business release was accepted' >&2; exit 1
fi
assert_recovered_fault "$before" failBusiness 2.0.0-broken-business
bash "$ROOT/scripts/smoke.sh" 1.0.0
# A new valid release must still work after both recoveries.
bash "$ROOT/scripts/deploy.sh" "$tag" 1.1.0
h history "$RELEASE" | tee "$ARTIFACTS/final-history.txt"
echo 'PASS: manual recovery, automatic rollback, business rollback, and healthy upgrade'
