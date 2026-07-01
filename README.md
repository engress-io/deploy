# Engress Deploy

Infrastructure and deployment for [engress.io](https://engress.io). Single home for Terraform, Helm, operator scripts, and ops agents.

**Agents:** Rules apply on every run — read [AGENTS.md](AGENTS.md) and [docs/deployment-matrix.md](docs/deployment-matrix.md) before any deploy dispatch.

## Layers

| Layer | Path | Tool | Frequency |
|-------|------|------|-----------|
| **L1 Foundation** | `terraform/` | Terraform (split stacks) | Rare |
| **L2 Cluster** | `scripts/cluster/` | kubectl + addons | Occasional |
| **L3 Workloads** | `helm/` + `scripts/workload/` | Helm + SPA sync | Daily |

## Quick start

```bash
# From superproject root (deploy submodule checked out)
./deploy/agents/dispatch-ops.sh plan-stack stack=eks-east
./deploy/agents/dispatch-ops.sh apply-stack stack=eks-east
./deploy/agents/dispatch-ops.sh helm-deploy-core   # core only
./deploy/agents/dispatch-ops.sh helm-deploy-edge   # edge east + west
./deploy/agents/dispatch-ops.sh spa-deploy         # UI only
```

**Deployment rules:** See [docs/deployment-matrix.md](docs/deployment-matrix.md) — path → action matrix for CI and agents. Full-stack deploy (`helm-deploy-all`) is manual only.

## Helm charts

Canonical charts: **`helm/engress-core`**, **`helm/engress-edge`**. See [helm/README.md](helm/README.md).

The superproject `charts/` directory is a legacy mirror (not a submodule). Charts belong in this repo with Terraform and deploy scripts — not in `core`/`edge` app repos.

## Safety

- **SSM tfvars only** — `engress-terraform-tfvars` is the sole source of `enable_*` flags
- **plan-guard** — blocks destroys of EKS, GA, VPC, SPA bucket unless `ALLOW_INFRA_DESTROY=1`
- **Stack applies** — `apply-stack.sh eks-east` targets only east resources on legacy monolith

## Layout

```
deploy/
├── terraform/          # Foundation (legacy monolith + future per-stack state)
├── helm/               # engress-core, engress-edge charts
├── docker/             # Container Dockerfiles
├── scripts/
│   ├── guards/         # plan-guard.sh
│   ├── terraform/      # ops-terraform.sh, apply-stack.sh
│   ├── cluster/        # LBC, LB fixes, addons
│   ├── workload/       # build-push, helm, spa
│   └── smoke/          # health checks
└── agents/             # dispatch-ops, DNS, Clerk
```

## Design

See `specs/2026-06-30-p08-deploy-submodule-design.md` in the superproject.
