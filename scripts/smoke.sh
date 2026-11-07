#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
preflight
expected="${1:?usage: smoke.sh EXPECTED_VERSION}"
image="$(k get deployment "$RELEASE" -o jsonpath='{.spec.template.spec.containers[0].image}')"
job="smoke-$(python3 -c 'import uuid; print(uuid.uuid4().hex[:12])')"
# A Job reaches the ClusterIP through DNS. A service port-forward would bypass this path.
python3 - "$job" "$image" "$RELEASE" "$expected" <<'PY' | k create -f -
import json,sys
name,image,service,version=sys.argv[1:]
print(json.dumps({"apiVersion":"batch/v1","kind":"Job","metadata":{"name":name},"spec":{
 "backoffLimit":0,"activeDeadlineSeconds":45,"ttlSecondsAfterFinished":300,
 "template":{"spec":{"restartPolicy":"Never","automountServiceAccountToken":False,
 "securityContext":{"runAsNonRoot":True,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}},
 "containers":[{"name":"smoke","image":image,"imagePullPolicy":"IfNotPresent",
 "command":["python","/app/smoke.py",f"http://{service}",version],
 "securityContext":{"allowPrivilegeEscalation":False,"readOnlyRootFilesystem":True,"capabilities":{"drop":["ALL"]}},
 "resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"100m","memory":"64Mi"}}}]}}}}))
PY
result=1
for ((i=0; i<60; i++)); do
  state="$(k get job "$job" -o json)"
  result="$(python3 -c 'import json,sys; s=json.load(sys.stdin).get("status",{}); print(0 if s.get("succeeded",0) else 1 if s.get("failed",0) else 2)' <<< "$state")"
  [[ "$result" == 2 ]] || break
  sleep 1
done
k logs "job/$job" > "$ARTIFACTS/$job.log" 2>&1 || true
cat "$ARTIFACTS/$job.log"
k delete job "$job" --wait=false >/dev/null
[[ "$result" == 0 ]]
