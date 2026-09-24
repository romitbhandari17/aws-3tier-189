# Cost Estimate — Current Demo Deployment

## ⚠️ Important Caveat
This document does **not** reflect actual AWS billing data. This tooling
session has no AWS credentials configured (`aws sts get-caller-identity`
fails), so the numbers below are a **list-price estimate** computed from the
exact resource sizes defined in Terraform (`src/infra/`), assuming everything
has been running 24/7 in `us-east-1` since deploy, at standard On-Demand
pricing (no Free Tier, no Reserved/Savings Plans applied).

**See §3 below for how to pull your real, actual cost** — that's the number
to trust, not this estimate.

---

## 1. Estimated Monthly Cost by Resource

Based on `src/infra/envs/dev/dev.tfvars` + module defaults as of this
writing: `db.t3.micro` RDS (single-AZ, 20GB gp2), Fargate task (`cpu=256`,
`memory=512`, `desired_count=1`), one ALB, one REST API Gateway.

| Resource | Config (from Terraform) | Pricing basis (us-east-1, on-demand) | Est. monthly cost |
|---|---|---|---|
| **RDS instance** (`modules/rds/main.tf`) | `db.t3.micro`, MySQL 8.0, Single-AZ | ~$0.017/hr compute | ~$12.50 |
| **RDS storage** | `gp2`, 20 GB | ~$0.115/GB-month | ~$2.30 |
| **ECS Fargate task** (`modules/ecs/main.tf`) | 0.25 vCPU, 0.5 GB memory, 1 task, always-on | vCPU ~$0.04048/hr + memory ~$0.004445/GB-hr | ~$9.00 |
| **Application Load Balancer** | 1 ALB, always-on, low request volume | ~$0.0225/hr base + ~$0.008/LCU-hr (demo traffic ≈ well under 1 LCU) | ~$16.50 |
| **API Gateway (REST API)** | `GET /courses/count`, demo-level traffic | $3.50 per million requests | < $1.00 (negligible at demo volume) |
| **ECR repository storage** | One small Python/Flask image (~150–250 MB) | $0.10/GB-month | < $0.10 |
| **CloudWatch Logs** | 7-day retention (`modules/ecs/main.tf`), low volume | $0.50/GB ingested + $0.03/GB-month stored | < $0.50 |
| **Data transfer** | Minimal (demo traffic only) | First 100GB/month out often within Free Tier | ~$0.00–1.00 |
| **Total (estimate)** | | | **≈ $42–45 / month** |

### Where most of the cost comes from
The **ALB** (~$16.50/mo) and **RDS** (~$14.80/mo combined compute+storage)
together account for ~70% of the estimated total — both run continuously
regardless of how little traffic the demo actually gets, since neither is
usage-based like API Gateway. This lines up with the cost-optimization ideas
already in `docs/PROD.md` §4 (right-sizing, Fargate Spot, reconsidering the
ALB via VPC Link, etc.).

### What this estimate does *not* include
- Any **Free Tier** eligibility (a new/eligible AWS account gets 750 hrs/month
  of `db.t3.micro` RDS and some ALB/data-transfer allowances free for 12
  months — could make the *actual* cost near $0 if still eligible).
- **NAT Gateway** — not used today (public subnets), so $0; would apply only
  if/when the VPC Link change from `docs/PROD.md` §1 is made.
- One-time or irregular costs (e.g. extra ECR storage from multiple pushed
  image tags via `deploy.sh` — each build tags a new version, see §2 below).
- Taxes, support plan fees, or any Reserved Instance/Savings Plan discounts.

---

## 2. Note: `deploy.sh` Accumulates ECR Images Over Time
Every run of `deploy.sh` pushes a **new uniquely-tagged image** (git sha +
timestamp) in addition to `:latest`, and none are ever deleted. This is a
small, slow-growing cost (`$0.10/GB-month` per stored image) that isn't
reflected above as a fixed number — see `docs/PROD.md` §4 ("ECR storage" row)
for the fix (an ECR lifecycle policy to expire old/untagged images
automatically).

---

## 3. How to Get Your *Actual* Cost (Recommended)

The estimate above is a planning number — here's how to see real spend:

### Option A: AWS Cost Explorer (easiest, console)
1. AWS Console → **Billing and Cost Management** → **Cost Explorer**.
2. Group by **Service**, filter by **Region = us-east-1** and date range
   since your first `terraform apply`.
3. Once the tagging change below is applied and has been active for a
   billing cycle, you can instead filter by **Tag: Project =
   aws-internal-199** to isolate *only* this project's resources (useful if
   other things run in the same account).

### Option B: AWS CLI (`aws ce get-cost-and-usage`)
Requires `ce:GetCostAndUsage` permission and valid credentials configured
locally (this sandbox has neither):
```bash
aws ce get-cost-and-usage \
  --time-period Start=2026-09-01,End=2026-09-30 \
  --granularity MONTHLY \
  --metrics "UnblendedCost" \
  --group-by Type=DIMENSION,Key=SERVICE \
  --region us-east-1
```

### Option C: Filter by tag (now enabled)
`src/infra/providers.tf` now sets `default_tags` on the AWS provider:
```hcl
default_tags {
  tags = {
    Project     = var.project_name   # "aws-internal-199"
    Environment = var.environment    # "dev"
    ManagedBy   = "terraform"
  }
}
```
Every resource this Terraform config creates (or updates via `terraform
apply`) from now on will carry these tags. Two things to do to make tag-based
cost tracking work:
1. **Activate the tag as a cost allocation tag** — Billing Console → **Cost
   Allocation Tags** → find `Project`/`Environment` → **Activate**. (Tags
   must be activated before Cost Explorer/CUR can filter/group by them — this
   is an AWS one-time manual step, not something Terraform can do.)
2. **Re-apply** (`terraform apply` or run `./deploy.sh`) so existing
   resources get the new tags retroactively (Terraform will update
   in-place; this does not recreate anything).
3. Wait ~24 hrs for tags to propagate into Cost Explorer, then filter by
   `Project = aws-internal-199`.

### Option D: Resource Groups & Tag Editor (quick manual check, no waiting)
Console → **Resource Groups & Tag Editor** → search by tag `Project =
aws-internal-199` → see every live resource this project owns right now,
useful for a sanity check independent of billing data.

---

## 4. Recommendation
Once real cost data is available (Option A or B above, after a few days/a
billing cycle), replace the estimate table in §1 with actual numbers and
compare against it — that will show which estimate assumptions (traffic
volume, Free Tier eligibility, etc.) were off, and should directly inform
which `docs/PROD.md` §4 cost-optimization items are worth prioritizing first.
