# Why This Demo Uses an Application Load Balancer (ALB)

## 1. Where the ALB Sits
```
Postman / Client
      │  HTTPS
      ▼
API Gateway  (Tier 1 — public REST API, GET /courses/count)
      │  HTTP_PROXY integration, plain HTTP
      ▼
ALB          ← this component
      │  forwards to whichever tasks are healthy
      ▼
ECS Fargate task(s) (Tier 2 — Flask app, port 5000)
      │  SQL
      ▼
RDS (Tier 3 — MySQL)
```

## 2. Why ECS Fargate Needs the ALB (Not a Direct Connection)

**Fargate tasks don't have stable, predictable addresses.** Each time a task
is stopped/restarted/redeployed, ECS assigns it a **new private IP** (and,
optionally, a new public IP). API Gateway's `HTTP_PROXY` integration needs one
fixed URL to call — it can't "know" which of possibly-changing task IPs is
currently alive. The ALB solves this by giving the whole service **one stable
DNS name** (`aws_lb.app.dns_name`) that never changes, regardless of how many
times tasks restart or how many are running.

Concretely, the ALB is doing three jobs here:

1. **Stable entry point** — API Gateway's `backend_url` is hardcoded to the
   ALB's DNS name (see `src/infra/main.tf`: `backend_url =
   "http://${module.ecs.alb_dns_name}/courses/count"`). Without the ALB,
   every task restart would require updating that URL.

2. **Health checking / self-healing** — The ALB's target group polls
   `/courses/count` on each task (see `aws_lb_target_group.app.health_check`
   in `src/infra/modules/ecs/main.tf`). If a task is unhealthy (e.g. crashed,
   still starting, or can't reach RDS), the ALB stops sending it traffic —
   this is exactly why a bad deploy shows up as a `503` from the ALB rather
   than requests hitting a dead task.

3. **Registration/deregistration automation** — When ECS starts a new task
   (e.g. during a deploy or scale-out), it automatically registers the task's
   new IP with the ALB's target group (`load_balancer` block on
   `aws_ecs_service.app`), and deregisters it on shutdown. No manual wiring
   needed even as tasks come and go.

## 3. Why Not Skip the ALB and Have API Gateway Call ECS Directly?

This was an open question early on (see `docs/CONTEXT.md`, section 9:
"ALB + ECS vs direct API Gateway → ECS integration (VPC Link)"). The
alternative would be a **VPC Link**, which lets API Gateway reach a private
ALB/NLB inside a VPC without the ALB needing a public IP.

We chose **ALB + plain HTTP_PROXY** instead of VPC Link because:
- It's simpler to set up and reason about for a demo — no VPC Link resource,
  no private integration configuration.
- The ALB's DNS name is directly usable as the `backend_url`, with no extra
  networking layer.
- Trade-off (acceptable for a demo, called out in the security-groups
  comments): the ALB's security group allows `HTTP` from `0.0.0.0/0` on port
  80 rather than only from API Gateway — meaning anyone with the ALB's DNS
  name could hit it directly, bypassing API Gateway. Fine for a demo; a
  production setup would tighten this (e.g. VPC Link, or an ALB security
  group restricted to API Gateway's IP ranges/WAF).

## 4. What Would Break Without the ALB
- API Gateway would have no stable target to call — you'd have to manually
  update the integration's URL every time a task's IP changed.
- No automatic health checking — a crashed or DB-unreachable task would just
  silently fail requests instead of being taken out of rotation.
- No path for horizontal scaling — if `desired_count` in `aws_ecs_service.app`
  were ever raised above 1, there would be no way to distribute requests
  across multiple tasks without a load balancer.

## 5. Where This Lives in the Code
| Resource | File | Purpose |
|---|---|---|
| `aws_security_group.alb` | `src/infra/modules/ecs/main.tf` | Firewall: allow HTTP/80 from anywhere in (demo only) |
| `aws_lb.app` | `src/infra/modules/ecs/main.tf` | The ALB itself, public, in the default VPC's subnets |
| `aws_lb_target_group.app` | `src/infra/modules/ecs/main.tf` | Where the ALB forwards traffic; health-checks `/courses/count` |
| `aws_lb_listener.http` | `src/infra/modules/ecs/main.tf` | Routes port-80 traffic to the target group |
| `aws_ecs_service.app.load_balancer` | `src/infra/modules/ecs/main.tf` | Auto-registers/deregisters ECS tasks with the target group |
| `alb_dns_name` output | `src/infra/modules/ecs/outputs.tf` | Consumed by the `apigw` module as `backend_url` |
