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
| `core/web/**` | SPA only (staging then prod) | `spa-deploy` |
| `core/**` (backend, not web) | Binary stack: core + edge + agent build on staging; promote same SHA to prod | `helm-deploy-core` |
| `edge/**` | Binary stack: core + edge + agent build on staging; promote same SHA to prod | `helm-deploy-edge` |
| `agent/**` | Binary stack on staging; `promote-agent` on prod approval | — |
| `deploy/helm/**`, `charts/**` | Helm upgrade only (existing image tag) | `helm-deploy` / `helm-deploy-west` |
| `deploy/docker/Dockerfile.core` | Rebuild core image + Helm east core | `helm-deploy-core` |
| `deploy/docker/Dockerfile.edge` | Rebuild edge image + Helm east+west edge | `helm-deploy-edge` |
| `deploy/terraform/**` | Nothing | `plan-stack` / `apply-stack` |
| `docs/**`, `internal-docs/**`, `*.md` | Nothing | — |
| `scripts/**` | Nothing (shellcheck in scripts CI) | — |

**Binary stack:** any change under `core/**` (non-web), `edge/**`, or `agent/**` deploys **core + edge + staging agent binaries** together before validation.

## Full-stack deploy (manual only)

Use only for operator-initiated reconciles:

```bash
./deploy/agents/dispatch-ops.sh helm-deploy-all
./deploy/agents/dispatch-ops.sh spa-deploy   # if SPA also needed
```

Or GitHub Actions → **Deploy to EKS (manual prod reconcile)** → provide validated `image_tag` from staging.

Routine `main` pushes use **deploy-staging.yml → deploy-production.yml** (production environment approval).

## Agent rules (mandatory)

Cloud agents and operators must:

1. **Never** dispatch `apply-foundation`, `helm-deploy-all`, `p03-rollout`, or `fix-lbs` unless the task explicitly requires it.
2. UI changes → `spa-deploy` only.
3. Core API changes → staging binary stack, then prod promotion.
4. Edge changes → staging binary stack, then prod promotion.
5. Infra changes → `plan-stack` first, then `apply-stack` with named stack only.
6. **Never** push directly to production ECR or `downloads/latest/` without a passing staging validation.

## Examples

| Scenario | Expected |
|----------|----------|
| Edit `core/web/src/pages/Oasis.tsx` | `deploy-spa` job only |
| Edit `core/internal/api/handler.go` | `deploy-core` + `deploy-edge` + `build-agent` on staging |
| Edit `edge/internal/tunnel/quic.go` | Binary stack on staging, then prod promote |
| Edit `agent/cmd/engress/main.go` | Binary stack on staging, `promote-agent` on prod |
| Edit `deploy/helm/engress-edge/values.yaml` | `deploy-helm` job only, no ECR |
| Edit `docs/foo.md` | No deploy workflows |

## Workflows

| Workflow | Role |
|----------|------|
| `deploy-staging.yml` | Auto on `main`: build binaries → staging EKS → `validate.sh` |
| `deploy-production.yml` | After staging success + approval: promote same SHA to prod |
| `deploy-k8s.yml` | Break-glass manual prod reconcile (requires `image_tag` + production approval) |
| `ci.yml` | EC2 fallback only when `engress-deploy-target=ec2` |
| `ops.yml` | Manual/dispatched operator actions |

## Verification

| Check | Command |
|-------|---------|
| Staging validation | `ENGRESS_ENV=staging IMAGE_TAG=<sha> ./deploy/scripts/smoke/validate.sh` |
| Prod smoke | `ENGRESS_ENV=prod ./deploy/scripts/smoke/smoke-test.sh` |
| Script syntax | `bash -n deploy/scripts/smoke/validate.sh` |
