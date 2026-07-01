# Deploy Submodule — Agent Rules

This submodule owns Terraform, Helm, Docker, and operator scripts. See [docs/deployment-matrix.md](docs/deployment-matrix.md) for the canonical path → action matrix.

## Mandatory rules for cloud agents

1. **Never** dispatch `apply-foundation`, `helm-deploy-all`, `p03-rollout`, or `fix-lbs` unless the task explicitly requires full-scope work.
2. **UI changes** (`core/web/**`) → `spa-deploy` only.
3. **Core API changes** (`core/**` minus web) → `helm-deploy-core` (CI handles push to main automatically).
4. **Edge changes** (`edge/**`) → `helm-deploy-edge` (east + west).
5. **Helm chart changes** (`deploy/helm/**`) → `helm-deploy` or `helm-deploy-west` as needed (no image build).
6. **Infra changes** (`deploy/terraform/**`) → `plan-stack stack=<name>` first, then `apply-stack stack=<name>` only.
7. **Docs-only changes** → no deploy dispatch.

## Preferred dispatch entry

```bash
./deploy/agents/dispatch-ops.sh <action>
```

Superproject shim: `./scripts/agent/dispatch-ops.sh` delegates to deploy when submodule is checked out.

## Component-scoped workload actions

| Action | Scope |
|--------|-------|
| `spa-deploy` | SPA build + S3 + CloudFront only |
| `helm-deploy-core` | engress-core Helm (east) |
| `helm-deploy-edge` | engress-edge Helm (east + west) |
| `helm-deploy` | Both charts (east) |
| `helm-deploy-west` | Edge only (west) |
| `helm-deploy-all` | Full east + west (manual reconcile only) |

## Foundation actions (L1)

| Action | Scope |
|--------|-------|
| `plan-stack stack=eks-east` | Plan one stack |
| `apply-stack stack=eks-east` | Apply one stack (plan-guard enforced) |
| `audit-ssm-tfvars` | Verify SSM tfvars flags |

SSM `engress-terraform-tfvars` is the sole source of `enable_*` flags. Never pass partial `-var enable_*` overrides.

## CI workflows (superproject)

| Workflow | Behavior |
|----------|----------|
| `deploy-k8s.yml` | Change-detected EKS deploys (spa/core/edge/helm jobs) |
| `ci.yml` | Change-detected EC2 deploys (when `engress-deploy-target=ec2`) |
| `ops.yml` | Manual/dispatched operator actions |

Full-stack deploy: GitHub Actions → Deploy to EKS → Run workflow → scope `full`.
