# Design decisions and operational limits

## Health and shutdown

Startup, readiness, and liveness answer different questions. Startup permits initialization before the other probes run. Readiness controls whether a pod should receive Service traffic. Liveness only tests that this example's HTTP process can respond; a dependency outage should not cause every instance to restart.

During termination, preStop calls an admin listener bound to loopback on port 9000. That listener is absent from the Service. The application becomes unready and continues serving residual traffic for five seconds while endpoint changes propagate. Kubernetes then sends SIGTERM to the Python process, which is PID 1 because the container uses exec-form CMD. The server stops accepting requests and waits for accepted requests to finish.

The demonstrated work request is limited to five seconds, socket reads time out after five seconds, and shutdown has a ten-second watchdog. The pod allows thirty seconds total, including preStop. A process test synchronizes with an accepted request and verifies a 200 response and exit code zero after SIGTERM. Fixed drain delays are illustrative: measure ingress and load-balancer propagation, connection behavior, and real request duration in each environment.

## Rolling updates and disruption

Two replicas, zero unavailable replicas, and one surge replica preserve the original service capacity during the readiness fault, subject to healthy nodes and enough spare resources. `minReadySeconds` requires sustained readiness before a replacement counts as available. The progress deadline reports a stalled deployment; Helm and the wrapper handle recovery.

The PodDisruptionBudget limits voluntary evictions. It does not protect against node failure, direct pod deletion, or a defective application, and it does not control Deployment rolling updates. Preferred pod anti-affinity spreads replicas across the two kind workers when possible without blocking a surge pod on a small cluster.

## Why two release gates

Kubernetes readiness cannot prove a business transaction works. The smoke Job reaches the actual ClusterIP through cluster DNS, checks the expected application version, and verifies `/api/order`. Multiple small samples help detect stale versions, but do not prove every network path, pod, user flow, or performance requirement.

The wrapper records a baseline only after its smoke check passes. Helm 4's rollback-on-failure covers apply and readiness failures; explicit rollback covers a failed rollout-completion or smoke check after Helm returns success. Both paths verify recovery and reject the candidate. `--reset-values` prevents a fault overlay from silently carrying into the next candidate.

Diagnostic collection is best effort, while release and recovery gates fail closed. No secret values or kubeconfig are deliberately collected. Demo logs are suitable for CI artifacts; reassess log sensitivity before adapting this workflow to real workloads.

## Production adaptation

This repository's mutation scripts are intentionally scoped to kind. For a real environment, create a separate deployment workflow with:

- Workload identity or OIDC and namespace-scoped deployment permissions.
- Protected deployment environments, explicit cluster selection, and serialized releases per environment.
- Registry retention, image signing and scanning, and immutable image digests. The chart already supports `image.digest`; the lab uses commit-SHA tags in CI. The Python base image is a mutable maintained tag, so production builds should resolve and pin its digest.
- Service-specific probes and smoke tests, ingress authentication/TLS, network policies, resource tuning, and dependency timeouts.
- Error-rate and latency gates tied to SLOs, plus canary or blue/green promotion for risky behavior changes.
- Backward-compatible database migrations and a recovery plan for stateful side effects.

A cancelled pipeline, exhausted cluster, unavailable registry, or incompatible migration can prevent rollback. Never equate a rollback request with a verified recovery.

## Primary references

- [Kubernetes probes](https://kubernetes.io/docs/concepts/workloads/pods/probes/)
- [Pod termination](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination)
- [Container lifecycle hooks](https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/)
- [Deployment progress and failure](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/)
- [Pod disruption budgets](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/)
- [Helm 4 upgrade](https://helm.sh/docs/helm/helm_upgrade/)
- [Helm rollback](https://helm.sh/docs/helm/helm_rollback/)
- [kind quick start](https://kind.sigs.k8s.io/docs/user/quick-start/)
