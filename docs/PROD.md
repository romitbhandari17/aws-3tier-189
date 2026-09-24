# Production Readiness: What Changes From This Demo

This demo (see `docs/CONTEXT.md`, `docs/ALB.md`) intentionally keeps every
tier as simple/cheap as possible. This document is the checklist of what to
change **before** running this for real traffic — organized by networking,
security, cost, and reliability. Nothing here is implemented yet; it's the
plan for when this iteration starts.

---

## 1. Networking: Replace ALB + Public HTTP with VPC Link

### Why this changes
Today, API Gateway reaches ECS via a **public ALB** over plain HTTP (see
`docs/ALB.md`, section 3). That means:
- Traffic between API Gateway and the ALB is **unencrypted** (plain HTTP,
  port 80).
- The ALB's security group allows `0.0.0.0/0` on port 80 — **anyone** with
  the ALB's DNS name can hit the backend directly, completely bypassing API
  Gateway (and any throttling/auth/WAF you put there).
- The ALB and ECS tasks sit in the **default VPC's public subnets**, more
  exposed surface than necessary.

### What VPC Link does instead
A **VPC Link** lets API Gateway call a **private** load balancer/NLB living
inside your VPC, without that load balancer ever getting a public IP or
route to the internet.

```
Postman → API Gateway (public) → VPC Link (private ENI in your VPC) → NLB/ALB (private) → ECS (private subnet) → RDS (private subnet)
```

### Changes required
| Area | Demo (today) | Prod (VPC Link) |
|---|---|---|
| Load balancer | Public ALB, `internal = false` | Internal ALB/NLB, `internal = true`, no public IP |
| Subnets | Default VPC's public subnets | Purpose-built **private subnets** (see §2) |
| API Gateway integration | `HTTP_PROXY` straight to ALB DNS name | `HTTP_PROXY` (or `AWS_PROXY` for HTTP APIs) via a `aws_api_gateway_vpc_link` resource pointing at an **NLB** (REST APIs require NLB for VPC Link, not ALB directly) |
| ALB/NLB security group | `0.0.0.0/0` on port 80 | No public ingress at all; only reachable from the VPC Link's ENIs |
| ECS task `assign_public_ip` | `true` (needed to reach ECR from a public subnet) | `false` — use a **NAT Gateway** or **VPC endpoints for ECR/S3/CloudWatch Logs** instead (see §3 cost note) |
| Terraform | `aws_lb` (ALB) in `modules/ecs/main.tf` | New `aws_lb` (NLB, internal) + new `aws_api_gateway_vpc_link` + updated `apigw` module's `uri`/`connection_type = "VPC_LINK"` |

### Trade-offs to weigh
- VPC Link + NAT Gateway costs more than a public ALB (NAT Gateway has an
  hourly + per-GB charge — see §4 cost table).
- More Terraform to maintain (private subnets, NAT/endpoints, NLB, VPC Link
  resource) — no longer "one ALB and done."
- Worth it once this is more than a demo: closes the "bypass API Gateway
  entirely" hole and removes the backend's public exposure.

---

## 2. Networking: Move Off the Default VPC

**Today:** every module (`rds`, `ecs`) uses `data "aws_vpc" "default"` and
`data "aws_subnets" "default"` — the account's default VPC, whose subnets are
all public by default.

**Prod:** build a dedicated VPC (e.g. via a Terraform module or the
`terraform-aws-modules/vpc/aws` registry module) with:
- **Public subnets** — only for the NLB/ALB's ENIs (if using VPC Link) or a
  NAT Gateway.
- **Private subnets** — ECS tasks and RDS live here, no direct route to the
  internet.
- **VPC endpoints** (Gateway endpoint for S3, Interface endpoints for ECR
  API/DKR and CloudWatch Logs) so ECS tasks in private subnets can still pull
  images and ship logs **without** a NAT Gateway, if you want to avoid its
  cost entirely.

---

## 3. Security Changes

| Item | Demo (today) | Prod |
|---|---|---|
| API Gateway auth | `authorization = "NONE"` on `GET /courses/count` (see `modules/apigw/main.tf`) — anyone with the URL can call it | Add an authorizer: **API key** (simplest), **IAM auth** (SigV4), or a **Cognito/JWT authorizer** depending on who's calling |
| API Gateway abuse protection | None | Add a **usage plan + throttling/quota**, and consider **AWS WAF** in front of the API |
| DB credentials | Plaintext `db_password` in `dev.tfvars` (gitignored, but stored in **plaintext in Terraform state**) | Move to **AWS Secrets Manager** (or SSM Parameter Store, SecureString) — generate the password, store it there, have RDS and the ECS task definition reference the secret ARN instead of a literal string. Terraform's `aws_db_instance` supports `manage_master_user_password = true` to have RDS generate/rotate it in Secrets Manager automatically. |
| ECS task env vars | `DB_PASSWORD` passed as a **plain environment variable** in the task definition (`modules/ecs/main.tf`) — visible to anyone who can call `DescribeTaskDefinition` | Use the task definition's `secrets` block (not `environment`) to inject it from Secrets Manager/SSM at container start — never rendered in plaintext in the task definition JSON |
| RDS security group | Allows port 3306 from the **entire VPC CIDR** (`modules/rds/main.tf`) | Restrict to just the **ECS tasks' security group** (`security_groups = [aws_security_group.ecs_tasks.id]`) instead of a broad CIDR block |
| RDS encryption | Not set (defaults to unencrypted for this engine/instance class unless specified) | Set `storage_encrypted = true` (with a KMS key) on `aws_db_instance` |
| RDS public access | Already `publicly_accessible = false` — keep this | No change needed, already correct |
| ALB security group | `0.0.0.0/0` on port 80 (HTTP only) | If keeping any public-facing LB: add an **ACM certificate + HTTPS listener (443)**, redirect 80→443, and scope ingress down (e.g. to API Gateway's IP ranges or behind VPC Link so it's not public at all — see §1) — **explained in detail in §3.1 below** |
| IAM task role | Empty (no permissions) — fine today since the app only talks to RDS directly | Once using Secrets Manager, grant the **task role** (not execution role) least-privilege `secretsmanager:GetSecretValue` scoped to just that one secret ARN |
| ECR image scanning | Not enabled | Enable `image_scanning_configuration { scan_on_push = true }` on `aws_ecr_repository` to catch known CVEs in your image |
| Terraform state | Presumably local state (`terraform.tfstate` in the repo dir) | Move to a **remote backend** (S3 + DynamoDB lock table) with encryption, so state (which contains the DB password today) isn't sitting in plaintext on a laptop or in git history |
| Logging/audit | CloudWatch Logs for the app container only | Add **VPC Flow Logs**, **CloudTrail** (if not already on for the account), and **RDS audit/log exports** if compliance requires it |

### 3.1 Detail: Securing the Public ALB (HTTPS + Ingress Scoping)

This only applies **if** you keep a public-facing load balancer at all (e.g.
you haven't yet moved to VPC Link per §1). It's three separate problems with
today's `modules/ecs/main.tf` setup, each with its own fix:

**Problem 1 — Traffic is unencrypted (plain HTTP, port 80)**
Right now `aws_lb_listener.http` only listens on port 80 and forwards HTTP as-is.
Anyone on the network path between API Gateway and the ALB (or anyone who
hits the ALB directly) sees requests/responses in plaintext, including
whatever data flows through `/courses/count` — fine for a course count today,
not fine once real data is involved.

*Fix:*
1. **Request/import an ACM certificate** for a domain name that resolves to
   the ALB (e.g. `api.yourdomain.com`) — via `aws_acm_certificate` +
   `aws_acm_certificate_validation` (DNS validation, typically through
   Route 53). ACM certificates are free; you just need a domain and DNS
   control.
2. **Add an HTTPS listener** — a new `aws_lb_listener` on port 443, protocol
   `HTTPS`, with `certificate_arn` pointing at the ACM cert, and
   `ssl_policy` set to a modern policy (e.g.
   `ELBSecurityPolicy-TLS13-1-2-2021-06`). Its `default_action` forwards to
   the same target group as today.
3. **Redirect port 80 → 443** — change the existing `aws_lb_listener.http`'s
   `default_action` from `type = "forward"` to:
   ```hcl
   default_action {
     type = "redirect"
     redirect {
       port        = "443"
       protocol    = "HTTPS"
       status_code = "HTTP_301"
     }
   }
   ```
   This keeps port 80 open (so old links / plain HTTP callers get redirected
   instead of failing outright) but no actual application traffic is ever
   served over it in plaintext.

**Problem 2 — The ALB's security group accepts traffic from anywhere (`0.0.0.0/0`)**
Even after adding HTTPS, `aws_security_group.alb`'s ingress rule
(`cidr_blocks = ["0.0.0.0/0"]`) still lets **any IP on the internet** reach
the ALB directly on port 80/443 — completely bypassing API Gateway, and with
it any throttling, API keys, WAF rules, or logging you've configured there.
The intent is for **only API Gateway** to be able to reach the backend.

*Fix — two options, in order of preference:*
- **Preferred: switch to VPC Link (§1)** — the ALB/NLB becomes `internal =
  true` with no public IP at all, so this problem disappears entirely
  instead of being mitigated.
- **If a public ALB must remain** (e.g. VPC Link isn't ready yet): restrict
  `aws_security_group.alb`'s ingress `cidr_blocks` to **API Gateway's
  published IP ranges** for your region, pulled from AWS's
  [`ip-ranges.json`](https://ip-ranges.amazonaws.com/ip-ranges.json) feed
  filtered on `service = "API_GATEWAY"`. This is *not* a perfect boundary
  (those ranges are shared across all AWS customers' API Gateways, not
  unique to yours), but it does stop random internet scanners/attackers from
  hitting the ALB directly — a real improvement over `0.0.0.0/0`, just not as
  strong as VPC Link's true network isolation. In Terraform, this typically
  means a `data "aws_ip_ranges"` data source (`services = ["api_gateway"]`) feeding
  the security group rule's `cidr_blocks` instead of the literal
  `0.0.0.0/0` used today.

**Problem 3 — No defense against high-volume/malicious traffic at the LB layer**
Not addressed by HTTPS or IP scoping alone. Once traffic reaches the ALB,
nothing stops a flood of requests. Consider **AWS WAF** attached to the ALB
(or to API Gateway, which is usually the better attachment point) with
managed rule groups (e.g. `AWSManagedRulesCommonRuleSet`) plus rate-based
rules, as a follow-up once the above is in place.

**Summary of Terraform changes for this item:**
| Resource | Change |
|---|---|
| `aws_acm_certificate` / `aws_acm_certificate_validation` | New — cert for the ALB's domain |
| `aws_lb_listener.https` (new) | Port 443, `certificate_arn`, forwards to existing target group |
| `aws_lb_listener.http` (existing) | Change `default_action` from `forward` to `redirect` (80→443) |
| `aws_security_group.alb` | Replace `cidr_blocks = ["0.0.0.0/0"]` with API Gateway's IP ranges (or remove public ingress entirely once on VPC Link) |

---

## 4. Cost Optimization Changes

| Item | Demo (today) | Prod consideration |
|---|---|---|
| RDS instance class | `db.t3.micro`, single instance, `multi_az = false` (`modules/rds/main.tf` default) | Right-size based on real load; enable `multi_az = true` for prod HA (roughly doubles RDS cost, but removes single-instance-failure risk) |
| RDS storage | `gp2`, 20 GB fixed | Consider `gp3` (cheaper per-GB, tunable IOPS independent of size) and enable **storage autoscaling** (`max_allocated_storage`) instead of guessing a fixed size |
| RDS engine choice: standard RDS vs Aurora Serverless v2 | Standard RDS MySQL, `db.t3.micro`, always-on | **Keep standard RDS for this workload** — see §4.1. Only switch to Aurora Serverless v2 if traffic becomes spiky/unpredictable or you specifically need Aurora's HA/replication model. |
| ECS Fargate sizing | `cpu = 256`, `memory = 512`, `desired_count = 1` | Right-size via load testing; consider **Fargate Spot** for non-critical/prod-tolerant workloads (up to ~70% cheaper) mixed with a small baseline of standard Fargate for reliability |
| ECS scaling | Fixed `desired_count = 1`, no autoscaling | Add **Application Auto Scaling** (target tracking on CPU/ALB request count) so you pay for capacity only when traffic needs it, and don't fall over under load |
| NAT Gateway (if adopting VPC Link, §1) | N/A today (public subnets avoid this cost) | NAT Gateway has an hourly charge **plus** per-GB data processing — for a low-traffic API, **VPC endpoints** (S3 gateway endpoint is free; interface endpoints have a small hourly cost but no per-GB data charge for many services) can be cheaper than a NAT Gateway |
| CloudWatch Logs retention | 7 days (`modules/ecs/main.tf`) — already cost-conscious | Keep short retention in prod too unless compliance requires longer; export to S3/Glacier for cheap long-term storage if needed instead of raising CloudWatch retention |
| ECR storage | Untagged/older images accumulate indefinitely (`force_delete = true` only helps `terraform destroy`) | Add an **ECR lifecycle policy** to expire untagged images / old tags automatically, so storage cost doesn't grow forever |
| API Gateway type | REST API (`aws_api_gateway_rest_api`) | If features used stay simple, an **HTTP API** (`aws_apigatewayv2_api`) is materially cheaper per-request than a REST API for the same traffic — worth reconsidering once auth/VPC Link requirements are finalized, since HTTP APIs also support VPC Link (v2) |
| Multi-environment cost | Only `dev` exists | Prod environment should get its own state/tfvars (`envs/prod/`), but avoid duplicating expensive resources (e.g. NAT Gateway per environment) where a shared dev/staging setup is acceptable |

### 4.1 Detail: Aurora Serverless v2 vs Our Current RDS — Which Is Cheaper?

**Short answer: for this workload (steady, low, predictable traffic), our
current plain RDS `db.t3.micro` is cheaper than Aurora Serverless v2.**
Aurora Serverless v2 only pays off once traffic is spiky/unpredictable
enough that a fixed-size instance would otherwise be over-provisioned most
of the time.

**Why — rough us-east-1 monthly numbers:**

| | Current RDS (`db.t3.micro`) | Aurora Serverless v2 |
|---|---|---|
| Compute pricing model | Flat hourly rate for a fixed instance size | Billed per **ACU-hour** (~$0.12/ACU-hr); capacity scales between a min/max ACU you configure |
| Minimum footprint | `db.t3.micro` running 24/7 ≈ **$0.017/hr → ~$12–13/month** | Minimum capacity is typically **0.5 ACU** running continuously (it doesn't scale below that for production workloads) → 0.5 × $0.12 × 730 hrs ≈ **~$44/month for compute alone** |
| Storage | `gp2`, 20 GB fixed ≈ **~$2/month** | Aurora cluster storage ~$0.10/GB-month **plus** I/O request charges (~$0.20 per million requests) — can add up even at modest traffic, unlike RDS's flat storage price |
| **Rough total today's demo** | **~$15/month** | **~$44+/month** (compute alone already ~3x higher) |

**Why Aurora Serverless v2 costs more here:** its lowest billable step (0.5
ACU) is priced higher than the smallest fixed RDS instance class, and — for
production workloads — it doesn't scale down to zero, so you're paying that
0.5 ACU floor around the clock even when idle, on top of per-request storage
I/O charges standard RDS doesn't have.

**When Aurora Serverless v2 would actually be the cheaper/better choice:**
- **Bursty or unpredictable traffic** — e.g. mostly idle but with occasional
  large spikes. A fixed RDS instance sized for the spike would sit
  over-provisioned (and cost more) most of the time; Aurora Serverless v2
  scales up only during the spike and back down after.
- **Dev/test environments using the newer "scale-to-zero" capability**
  (announced re:Invent 2024) — lets Aurora Serverless v2 idle down to 0 ACU
  after a period of inactivity, which can beat an always-on `db.t3.micro` for
  a database that sits unused most of the day. Not intended/positioned for
  production SLA workloads, though.
- **You need Aurora's architecture regardless of cost** — e.g. its
  storage-layer replication (6 copies across 3 AZs) and fast (sub-30-second)
  failover, independent of any cost comparison.

**Recommendation for this project:** stay on standard RDS unless/until
traffic patterns become spiky enough to justify re-evaluating — revisit this
decision alongside the `multi_az` question above once real usage data
exists.

---

## 5. Reliability / Operational Changes (not covered above)
- **Multiple ECS tasks across multiple AZs** — today `desired_count = 1` means
  a single point of failure; bump to 2+ once the ALB/NLB and subnets span
  multiple AZs.
- **RDS automated backups** — confirm `backup_retention_period` is set
  (currently relying on the provider default; verify it's non-zero) and test
  a restore at least once before going live.
- **Deployment safety** — `deploy.sh` currently does `terraform apply
  -auto-approve`; for prod, remove `-auto-approve` (require a manual review of
  the plan) or gate it behind a CI/CD approval step.
- **Alarms** — add CloudWatch Alarms on ECS service health, ALB/NLB target
  health, and RDS CPU/storage, wired to SNS/on-call notification.

---

## 6. Suggested Order of Work
1. Move DB credentials to Secrets Manager (quick win, biggest security gap).
2. Tighten RDS security group to ECS-only (one-line change).
3. Add API Gateway auth (API key or IAM) + usage plan/throttling.
4. Move Terraform state to a remote backend.
5. Build the dedicated VPC + VPC Link + private subnets (bigger effort,
   do once the above are in place so you're not debugging two things at once).
6. Add autoscaling, alarms, and multi-AZ once the above networking/security
   foundation is solid.

*This document defines scope and intent only — no implementation has started.
Update `docs/CONTEXT.md`'s "Open Decisions" once work on any item here begins.*
