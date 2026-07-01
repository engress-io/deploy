# Staging environment setup (P07A)

Operator checklist to provision `staging.engress.io`. Code and CI are in-repo; these steps require console access.

## 1. Neon

Create a `staging` branch from production schema (empty or fixture data only).

Store connection string in SSM:

```bash
aws ssm put-parameter --name engress-staging-neon-db-connection-string \
  --type SecureString --value 'postgresql://...' --overwrite
```

## 2. Clerk

Create a separate Clerk application (staging). Add test users only.

```bash
aws ssm put-parameter --name engress-staging-clerk-secret-key --type SecureString --value 'sk_...' --overwrite
aws ssm put-parameter --name engress-staging-clerk-publishable-key --type String --value 'pk_...' --overwrite
```

## 3. Terraform

Copy [`deploy/terraform/env/staging.tfvars.example`](../terraform/env/staging.tfvars.example) to SSM:

```bash
./deploy/scripts/terraform/publish-ssm-tfvars.sh deploy/terraform/env/staging.tfvars.example engress-terraform-tfvars-staging
```

Apply staging stacks (separate state key):

```bash
export ENGRESS_TFSTATE_KEY=engress/deploy/staging/terraform.tfstate
./deploy/agents/dispatch-ops.sh plan-stack stack=eks-east env=staging
./deploy/agents/dispatch-ops.sh apply-stack stack=eks-east env=staging
# Repeat for network-east, frontend, deploy-config as stacks land in P08 split
```

Until per-stack staging applies exist, use monolith with `-var-file` staging tfvars and isolated state backend.

## 4. DNS (Spaceship)

| Record | Target |
|--------|--------|
| `staging` (A/ALIAS) | Staging CloudFront distribution |
| `*.edge.staging` (A) | Staging east NLB public IP |
| `edge-origin-east.staging` (CNAME) | Staging edge ALB |
| `core-origin.staging` (CNAME) | Staging core ALB |

## 5. GitHub

- Environment `staging` — no approval required
- Environment `production` — required reviewers

## 6. First deploy

After SSM `engress-staging-deploy-*` params exist:

```bash
ENGRESS_ENV=staging ./deploy/scripts/workload/helm-deploy-eks.sh --env staging
```

Or dispatch: `./deploy/agents/dispatch-ops.sh helm-deploy-staging`

## 7. Verify

```bash
ENGRESS_ENV=staging ./deploy/scripts/smoke/smoke-test.sh
ENGRESS_ENV=staging ENGRESS_STAGING_BASE=staging.engress.io ./deploy/scripts/smoke/validate.sh
curl -sf https://staging.engress.io/api/healthz
```
