# Recovery runbook

## Objective and prerequisites

Restore a previously verified application revision, then prove that both Kubernetes rollout and application behavior are healthy. Work only in the disposable `kind-safe-release-demo` cluster. The commands below assume the repository root, Helm 4, and the default local image from `make build`.

## Establish a healthy baseline

```bash
make cluster build deploy smoke
CTX=kind-safe-release-demo
NS=safe-release-demo
GOOD_REVISION=$(helm --kube-context "$CTX" -n "$NS" list \
  --filter '^safe-release$' -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["revision"])')
printf 'Verified recovery revision: %s\n' "$GOOD_REVISION"
```

Record this revision before applying the candidate. Never assume the previous numeric revision is healthy: previous revisions can be failed attempts. The deploy script verifies the existing application before accepting it as a recovery target.

## Deliberately break readiness

The following command intentionally omits automatic rollback so the failure remains available for inspection. Expect a nonzero exit after the wait fails.

```bash
helm --kube-context "$CTX" -n "$NS" upgrade safe-release charts/safe-release \
  --reset-values -f examples/broken-readiness.yaml \
  --set-string image.tag=local --set-string app.version=2.0.0-broken-readiness \
  --wait --timeout 90s
```

The new pod initializes and passes liveness, but `/readyz` returns 503. It cannot replace the two healthy replicas because the Deployment allows zero unavailable replicas. One surge pod is allowed. This depends on sufficient cluster capacity and continued health of the original replicas.

## Diagnose before recovering

```bash
make diagnose
helm --kube-context "$CTX" -n "$NS" history safe-release
kubectl --context "$CTX" -n "$NS" get pods,rs,deploy,pdb
kubectl --context "$CTX" -n "$NS" describe deployment safe-release
kubectl --context "$CTX" -n "$NS" describe pods -l app.kubernetes.io/instance=safe-release
kubectl --context "$CTX" -n "$NS" get endpointslices \
  -l kubernetes.io/service-name=safe-release -o yaml
bash scripts/smoke.sh 1.0.0
```

Look for failed readiness probes, a new ReplicaSet with an unready pod, and the original replicas still serving. The Deployment eventually reports `ProgressDeadlineExceeded`. The Service smoke check should still return baseline version `1.0.0`; it runs inside the cluster and does not use port-forwarding.

| Symptom | Investigate | Response |
| --- | --- | --- |
| Running but not Ready | Readiness failures, dependency health, application configuration | Restore the verified revision and correct the fault |
| `ImagePullBackOff` | Exact image, digest, registry reachability and credentials | Correct image delivery or roll back |
| Pending surge pod | CPU/memory, quotas, scheduling, node availability | Restore capacity; rollback alone may not fix the cause |
| Ready pods, business errors | Smoke Job log and application logs | Roll back despite successful health checks |
| Failed recovery | Image retention, cluster capacity, broken dependencies | Escalate; do not declare recovery from Helm status alone |

## Restore the recorded revision

```bash
bash scripts/recover.sh "$GOOD_REVISION"
```

The recovery script captures diagnostics, calls `helm rollback` with the explicit revision, waits for Deployment completion, and runs the business smoke checks against the restored version. A rollback creates a **new** Helm revision; it does not decrement revision history. A recovery command that fails remains a failure and requires investigation.

Avoid `kubectl rollout undo` for this Helm-managed release: it can restore only the Deployment while leaving Helm values and other resources inconsistent.

## Verify the automated paths

```bash
# Expected failure, followed by automatic readiness recovery:
bash scripts/deploy.sh local 2.0.0-unready examples/broken-readiness.yaml
# Expected failure after readiness passes, followed by explicit rollback:
bash scripts/deploy.sh local 2.0.0-broken examples/broken-business.yaml
# Confirm recovery and demonstrate a successful subsequent release:
bash scripts/smoke.sh 1.0.0
make deploy VERSION=1.1.0
make smoke VERSION=1.1.0
```

Run these commands individually because the intentional failures return nonzero. Use `make drill` for automated orchestration that expects and asserts the failures.

A business fault can affect users between rollout and smoke detection. This demo does not implement a canary, weighted routing, or blue/green promotion. Those approaches reduce exposure when readiness alone cannot identify a bad application release.

## No healthy revision, pending operations, or persistent data

On a failed first install, there is no prior revision to restore. Inspect diagnostics, fix the candidate, and redeploy. If a first install remains deployed but fails business checks, remove the disposable release with the explicitly scoped command below before retrying:

```bash
helm --kube-context kind-safe-release-demo -n safe-release-demo uninstall safe-release --wait
```

If a Helm operation is pending after a cancelled process, inspect history and the cluster before attempting recovery. Do not delete Helm metadata blindly. The wrapper refuses to build on a failed or pending baseline.

This example is stateless. Helm rollback does not undo database migrations, messages, external API calls, or persistent-volume changes. Production release plans must include backward-compatible migrations, independent backups, and application-specific remediation.

## Close the exercise

Save the failed candidate version, known-good revision, diagnostic evidence, verification result, and recovery duration. Correct the candidate in code and run the full pipeline again. Delete the lab with `make clean` when finished.
