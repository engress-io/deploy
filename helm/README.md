# Helm charts

Canonical Helm charts for Engress workloads on EKS.

| Chart | Workload |
|-------|----------|
| `engress-core/` | Control plane API (`engress-core`) — east only |
| `engress-edge/` | Data plane (`engress-edge`) — east + west (`values-west.yaml`) |

## Usage

Deployed by `deploy/scripts/workload/helm-deploy-eks.sh` (and `ops.yml` dispatch actions). Charts root defaults to `$ENGRESS_DEPLOY_ROOT/helm`.

```bash
./deploy/agents/dispatch-ops.sh helm-deploy-core   # core chart only
./deploy/agents/dispatch-ops.sh helm-deploy-edge   # edge chart east + west
```

## Legacy `charts/` at superproject root

The superproject still has a top-level `charts/` folder — a **mirror/shim**, not a separate submodule. Do not create `engress-io/charts`. Edit here (`deploy/helm/`); see [`charts/README.md`](../../charts/README.md) in the superproject for the full rationale.
