# Staging environment setup (P07A) — operator runbook

Code and CI are in-repo. This runbook covers everything **you** must do in consoles (Neon, Clerk, Spaceship, GitHub) plus AWS CLI steps.

**PRs to merge first:** see [Submodule pull requests](#submodule-pull-requests) at the bottom.

---

## Overview and order of operations

```text
1. Merge P07A PRs (superproject + submodules)
2. Neon staging branch → SSM
3. Clerk staging app → SSM + GitHub secret
4. Terraform staging apply → SSM engress-staging-deploy-*
5. staging-secrets-bootstrap.sh → K8s secrets
6. Spaceship DNS
7. GitHub environments (staging + production)
8. helm-deploy-staging + validate.sh
9. Push to main → confirm staging → approve production
```

Until step 4 completes, `deploy-staging.yml` skips with “Staging cluster not configured” — **production is not deployed from main**.

---

## Submodule pull requests

| Repo | Branch | Base | What it contains |
|------|--------|------|------------------|
| [engress-io/engress](https://github.com/engress-io/engress) | `walter/p07a-staging-environment-7db0` | `walter/documentation-atlas-496a` | Workflows, charts mirror, specs, narrative |
| [engress-io/deploy](https://github.com/engress-io/deploy) | `walter/p07a-staging-environment-7db0` | `main` | Helm, scripts, staging tfvars, bootstrap |
| [engress-io/core](https://github.com/engress-io/core) | `walter/p07a-staging-environment-7db0` | `main` | Terraform `environment` var, staging SSM in core |
| [engress-io/scripts](https://github.com/engress-io/scripts) | `walter/p07a-staging-environment-7db0` | `main` | SSM loader, `prod-rollout.sh` |
| [engress-io/docs](https://github.com/engress-io/docs) | `walter/p07a-staging-environment-7db0` | `main` | P07a narrative |
| [engress-io/internal-docs](https://github.com/engress-io/internal-docs) | `walter/p07a-staging-environment-7db0` | `main` | Plans index |

Merge **deploy + core before** relying on staging pods reading `engress-staging-*` SSM names.

---

## 1. Neon (database)

### Goal

A separate Postgres branch for staging — same **schema** as production, **no production data** (unless you intentionally copy fixtures).

### Steps

1. Open [Neon Console](https://console.neon.tech) → your Engress project (same project as prod is fine).
2. **Branches** → **Create branch**
   - Parent: `main` (production branch)
   - Name: `staging`
   - **Do not** include data if prompted (schema-only / empty preferred)
3. Open the `staging` branch → **Connection details** → copy the **pooled** connection string (`postgresql://...?sslmode=require`).

### Store in SSM

```bash
export AWS_REGION=us-east-2
export AWS_PROFILE=ghostweasel-flux   # or your operator profile

aws ssm put-parameter \
  --name engress-staging-neon-db-connection-string \
  --type SecureString \
  --value 'postgresql://USER:PASSWORD@HOST/neondb?sslmode=require' \
  --overwrite \
  --region "$AWS_REGION"
```

### Verify

```bash
aws ssm get-parameter --name engress-staging-neon-db-connection-string \
  --with-decryption --region us-east-2 --query Parameter.Value --output text | head -c 40
# Should print postgresql://... (not empty)
```

### Notes

- Staging core reads this via `ENGRESS_ENV=staging` → `engress-staging-neon-db-connection-string`.
- Migrations: first core deploy against staging should run migrations the same way prod does (Flyway/golang-migrate on startup). If schema is cloned from prod branch, you should be aligned.
- Cost: Neon free tier often covers a small staging branch; check Neon billing.

---

## 2. Clerk (authentication)

### Goal

A **separate Clerk application** for staging. No shared users/sessions with production.

### Steps

1. Open [Clerk Dashboard](https://dashboard.clerk.com) → **Create application** → name `Engress Staging`.
2. **API Keys**: copy publishable (`pk_test_...`) and secret (`sk_test_...`) keys.
3. Store keys in SSM (below) and `STAGING_CLERK_PUBLISHABLE_KEY` in GitHub Actions secrets.
4. **Configure the instance via API** (do **not** use Dashboard → Domains — dev instances cannot add `staging.engress.io` there; sign-in uses `*.accounts.dev` until you promote to Production):

```bash
# After SSM keys are set:
AWS_PROFILE=ghostweasel-flux ./scripts/agent/clerk-auth.sh --staging configure

# Or dispatch from a machine without AWS SSO:
./scripts/agent/dispatch-ops.sh clerk-configure-staging
```

This whitelists redirect URLs for `https://staging.engress.io/*` and disables the org gate on sign-up (same beta posture as prod).

### Webhook (optional)

Skip for P07A v1 — tenants are created on first JWT. If you test billing/org sync later:

1. **Webhooks** → endpoint `https://staging.engress.io/api/v1/clerk/webhook`
2. Store `whsec_...` in SSM as `engress-staging-clerk-webhook-secret`

### Store in SSM

```bash
aws ssm put-parameter --name engress-staging-clerk-secret-key \
  --type SecureString --value 'sk_test_...' --overwrite --region us-east-2

aws ssm put-parameter --name engress-staging-clerk-publishable-key \
  --type String --value 'pk_test_...' --overwrite --region us-east-2

# Optional webhook:
aws ssm put-parameter --name engress-staging-clerk-webhook-secret \
  --type SecureString --value 'whsec_...' --overwrite --region us-east-2
```

### GitHub secret (for SPA build in CI)

In **engress-io/engress** → Settings → Secrets → Actions:

| Secret | Value |
|--------|-------|
| `STAGING_CLERK_PUBLISHABLE_KEY` | Same `pk_test_...` as above |

Optional: `STAGING_SPA_BUCKET` after Terraform creates the staging SPA bucket (or set from terraform output).

---

## 3. Tunnel CA and metrics (staging isolation)

### Goal

Separate tunnel CA from production so staging tokens cannot affect prod edge.

### Option A — New staging CA (recommended)

```bash
openssl ecparam -genkey -name prime256v1 -noout -out /tmp/staging-ca.key
openssl req -new -x509 -key /tmp/staging-ca.key -out /tmp/staging-ca.crt -days 825 \
  -subj "/CN=Engress Staging Tunnel CA"

aws ssm put-parameter --name engress-staging-tunnel-ca-cert-pem \
  --type SecureString --value file:///tmp/staging-ca.crt --overwrite --region us-east-2

aws ssm put-parameter --name engress-staging-tunnel-ca-key-pem \
  --type SecureString --value file:///tmp/staging-ca.key --overwrite --region us-east-2

rm -f /tmp/staging-ca.key /tmp/staging-ca.crt
```

### Option B — Copy prod CA (test tenants only)

Only if you accept shared CA material:

```bash
for p in engress-tunnel-ca-cert-pem engress-tunnel-ca-key-pem; do
  v=$(aws ssm get-parameter --name "$p" --with-decryption --region us-east-2 --query Parameter.Value --output text)
  aws ssm put-parameter --name "engress-staging-${p#engress-}" \
    --type SecureString --value "$v" --overwrite --region us-east-2
done
```

(Adjust names: prod uses `engress-tunnel-ca-cert-pem` → staging `engress-staging-tunnel-ca-cert-pem`.)

Metrics ingest secret is auto-created by `staging-secrets-bootstrap.sh` if missing.

---

## 4. Terraform (AWS infrastructure)

### Publish staging intent to SSM

```bash
cd /path/to/engress   # superproject with deploy submodule
./deploy/scripts/terraform/publish-ssm-tfvars.sh \
  deploy/terraform/env/staging.tfvars.example \
  engress-terraform-tfvars-staging
```

Review [`deploy/terraform/env/staging.tfvars.example`](../terraform/env/staging.tfvars.example) first. Key flags:

- `environment = "staging"`
- `name_prefix = "engress-staging"`
- `base_domain = "staging.engress.io"`
- `enable_eks_west = false`, `enable_global_accelerator = false`
- Single-node EKS sizing

### Apply (isolated state)

Use a **separate state key** so prod is untouched:

```bash
export AWS_REGION=us-east-2
export ENGRESS_TFSTATE_KEY=engress/deploy/staging/terraform.tfstate

# From core/deploy/terraform (or deploy/terraform/_legacy-monolith until P08 stack split):
cd core/deploy/terraform
terraform init -reconfigure   # ensure backend uses staging key if configured
terraform plan -var-file=<(aws ssm get-parameter --name engress-terraform-tfvars-staging \
  --with-decryption --region us-east-2 --query Parameter.Value --output text)
```

**Or** via ops dispatch after merge:

```bash
./deploy/agents/dispatch-ops.sh plan-foundation   # when staging tfvars loader is wired
```

After apply, confirm SSM parameters exist:

```bash
aws ssm get-parameter --name engress-staging-deploy-eks-east-cluster-name --region us-east-2
aws ssm get-parameter --name engress-staging-deploy-edge-host --region us-east-2
```

Expected cluster name: `engress-staging-east`.

### Post-apply outputs you need for DNS

```bash
# CloudFront domain (staging frontend) — from terraform output or AWS console
# NLB hostname/IP for *.edge.staging — from EKS after first edge Helm deploy:
kubectl get svc -n engress engress-edge-nlb -o wide
```

---

## 5. Kubernetes secrets bootstrap

After Terraform + SSM app secrets (Neon, Clerk, tunnel CA):

```bash
export ENGRESS_ENV=staging
./deploy/scripts/cluster/staging-secrets-bootstrap.sh
```

Creates:

- `engress-core-secrets-staging` (`FLUX_SESSION_KEY`)
- `engress-edge-secrets-staging` (metrics + tunnel CA files)

---

## 6. DNS (Spaceship)

Log in to Spaceship DNS for `engress.io`.

| Name | Type | Target | Notes |
|------|------|--------|-------|
| `staging` | ALIAS/CNAME | Staging CloudFront distribution | `staging.engress.io` app |
| `*.edge.staging` | A | Staging east NLB public IP | Wildcard tunnels |
| `edge-origin-east.staging` | CNAME | Edge ALB DNS name | From `kubectl get ingress -n engress` |
| `core-origin.staging` | CNAME | Core ALB DNS name | From `kubectl get ingress -n engress` |

### Production east naming (when ready — not blocking staging)

| Name | Type | Target |
|------|------|--------|
| `edge-origin-east` | CNAME | Prod east edge ALB |
| `core-origin-east` | CNAME | Prod east core ALB |

Keep `edge-origin` → same target as `edge-origin-east` during migration.

---

## 7. GitHub environments

Repo: **engress-io/engress** → Settings → Environments

### `staging`

- No required reviewers
- Optional environment secrets (override repo secrets if needed)

### `production`

- **Required reviewers:** add yourself (and any other approvers)
- Deployments from `deploy-production.yml` wait here

### Repository secrets (if not already set)

| Secret | Purpose |
|--------|---------|
| `AWS_DEPLOY_ROLE_ARN` | OIDC deploy role (bootstrap — already set) |
| `STAGING_CLERK_PUBLISHABLE_KEY` | SPA build for staging |
| `STAGING_SPA_BUCKET` | Optional; staging S3 bucket name |
| `CLERK_PUBLISHABLE_KEY` | Prod SPA (existing) |

---

## 8. First deploy and validation

```bash
export ENGRESS_ENV=staging
./deploy/agents/dispatch-ops.sh helm-deploy-staging

# Or manually:
./deploy/scripts/workload/helm-deploy-eks-staging.sh

# Smoke + P07B v1 validation:
./deploy/scripts/smoke/validate.sh

curl -sf https://staging.engress.io/api/healthz
```

### Staging agent binaries

After edge deploy, CI publishes to `staging.engress.io/downloads/staging/latest/` (or run locally):

```bash
./deploy/scripts/workload/build-agent-staging.sh
```

Test agent:

```bash
curl -fsSL https://staging.engress.io/downloads/staging/latest/engress-linux-arm64 -o /tmp/engress-staging
chmod +x /tmp/engress-staging
/tmp/engress-staging defaults   # should show staging.engress.io / staging edge_addr
```

---

## 9. Confirm CI flow

1. Merge to `main` a trivial change (or empty commit) touching `core/` or `edge/`
2. **Actions → Deploy to staging** — should build, deploy, validate
3. **Actions → Deploy to production** — should appear; **wait for your approval**
4. Approve → same image SHA promotes to prod east + west

Emergency prod-only path: **Deploy to EKS (manual prod reconcile)** workflow.

---

## SSM parameter checklist (staging)

| Parameter | Source |
|-----------|--------|
| `engress-terraform-tfvars-staging` | `publish-ssm-tfvars.sh` |
| `engress-staging-neon-db-connection-string` | Neon console |
| `engress-staging-clerk-secret-key` | Clerk dashboard |
| `engress-staging-clerk-publishable-key` | Clerk dashboard |
| `engress-staging-clerk-webhook-secret` | Clerk webhooks (optional) |
| `engress-staging-tunnel-ca-cert-pem` | openssl or copy prod |
| `engress-staging-tunnel-ca-key-pem` | openssl or copy prod |
| `engress-staging-session-key` | auto via bootstrap script |
| `engress-staging-metrics-ingest-secret` | auto via bootstrap script |
| `engress-staging-deploy-*` | Terraform deploy-config stack |

---

## Troubleshooting

| Symptom | Check |
|---------|--------|
| Staging workflow skips | `aws ssm get-parameter --name engress-staging-deploy-eks-east-cluster-name` |
| Core crash loop | `kubectl logs -n engress deploy/engress-core`; Neon URL + Clerk key in SSM |
| 401 on staging app | Clerk publishable key mismatch (SSM vs GitHub `STAGING_CLERK_PUBLISHABLE_KEY`) |
| Tunnel mTLS fails | `engress-edge-secrets-staging` exists; CA PEM in SSM |
| Prod deployed without approval | Confirm `deploy-k8s.yml` has no `push:` trigger on main |

---

## Related docs

- Narrative: `docs/superpowers/narratives/2026-06-30-p07a-staging-environment.md`
- Spec: `specs/2026-06-28-p07a-staging-environment-design.md`
- Clerk prod setup: `internal-docs/core-docs/ops/clerk-billing-ci-setup.md`
