# Deployment Matrix

Canonical rules for **what deploys when**. Humans, CI, and cloud agents must follow this matrix.

## Layers

| Layer | Tool | Auto on push? | Dispatch |
|-------|------|---------------|----------|
| **L1 Foundation** | Terraform | Never | `plan-stack` / `apply-stack` |
| **L2 Cluster** | kubectl + addons | Never | `install-addons`, `fix-lbs` |
| **L3 Workloads** | Helm + SPA | Component-scoped | `helm-deploy-*`, `spa-deploy` |

**Invariant:** L3 cannot invoke L1 `apply` without plan-guard + approval.

## Path → deploy action

| Changed paths | Auto deploy (CI) | Manual dispatch |
|---------------|------------------|-----------------|
| `core/web/**` | SPA only | `spa-deploy` |
| `core/**` (backend, not web) | Build core image + Helm east `--core-only` | `helm-deploy-core` |
| `edge/**` | Build edge image + Helm east `--edge-only` + west edge | `helm-deploy-edge` |
| `deploy/helm/**`, `charts/**` | Helm upgrade only (existing image tag) | `helm-deploy` / `helm-deploy-west` |
| `deploy/docker/Dockerfile.core` | Rebuild core image + Helm east core | `helm-deploy-core` |
| `deploy/docker/Dockerfile.edge` | Rebuild edge image + Helm east+west edge | `helm-deploy-edge` |
| `deploy/terraform/**` | Nothing | `plan-stack` / `apply-stack` |
| `agent/**` | Agent release workflow only | not EKS |
| `docs/**`, `internal-docs/**`, `*.md` | Nothing | — |
| `scripts/**` | Nothing (shellcheck in scripts CI) | — |

## Full-stack deploy (manual only)

Use only for operator-initiated reconciles:

```bash
./deploy/agents/dispatch-ops.sh helm-deploy-all
./deploy/agents/dispatch-ops.sh spa-deploy   # if SPA also needed
```

Or GitHub Actions → Deploy to EKS → Run workflow → scope: `full`.

Routine `main` pushes **never** run the full east + west + SPA pipeline.

## Agent rules (mandatory)

Cloud agents and operators must:

1. **Never** dispatch `apply-foundation`, `helm-deploy-all`, `p03-rollout`, or `fix-lbs` unless the task explicitly requires it.
2. UI changes → `spa-deploy` only.
3. Core API changes → `helm-deploy-core` (CI handles push to main; dispatch for manual).
4. Edge changes → `helm-deploy-edge`.
5. Infra changes → `plan-stack` first, then `apply-stack` with named stack only.

## Examples

| Scenario | Expected |
|----------|----------|
| Edit `core/web/src/pages/Oasis.tsx` | `deploy-spa` job only |
| Edit `core/internal/api/handler.go` | `deploy-core` job only |
| Edit `edge/internal/tunnel/quic.go` | `deploy-edge` job (east + west) |
| Edit `deploy/helm/engress-edge/values.yaml` | `deploy-helm` job only, no ECR |
| Edit `docs/foo.md` | No deploy workflows |
| `dispatch-ops.sh spa-deploy` | ops `spa-deploy` step only |
| `dispatch-ops.sh plan-stack stack=eks-east` | terraform plan only, no helm |

## Workflows

| Workflow | Role |
|----------|------|
| `deploy-k8s.yml` | EKS component deploys on push (change-detected) |
| `ci.yml` | EC2 component deploys on push (change-detected) |
| `ops.yml` | Manual/dispatched operator actions |

## Verification (2026-06-30)

| Check | Result |
|-------|--------|
| `bash -n deploy/scripts/workload/build-push-ecr.sh` | pass |
| `bash -n scripts/deploy/scripts/build-push-ecr.sh` | pass |
| `bash -n deploy/agents/dispatch-ops.sh` | pass |
| `deploy-k8s.yml` path triggers exclude `agent/**`, `scripts/**` | pass |
| `ci.yml` path triggers exclude docs-only paths | pass |
| `ops.yml` helm-deploy uses `helm-deploy-eks.sh` (not inline charts) | pass |
| `fix-lbs` no longer auto-redeploys charts | pass |
| `helm-deploy-core` / `helm-deploy-edge` in dispatch + ops | pass |
