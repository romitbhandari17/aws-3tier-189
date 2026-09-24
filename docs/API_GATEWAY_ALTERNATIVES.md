# API Gateway: Why We Use It, and the Alternative of Calling the ALB Directly

## 1. Can You Skip API Gateway and Hit the ALB Directly?
**Yes — today, you already can.** The ALB in this demo is public
(`internal = false` in `modules/ecs/main.tf`) and its security group allows
inbound HTTP from `0.0.0.0/0` on port 80 (see `docs/ALB.md` §3 and
`docs/PROD.md` §3.1, "Problem 2"). That means the ALB's DNS name is a fully
working, unauthenticated entry point on its own:

```bash
curl http://aws-internal-199-dev-alb-1741414475.us-east-1.elb.amazonaws.com/courses/count
```

This works right now, in parallel with the API Gateway URL — API Gateway
isn't in the request path at all when you call the ALB directly; it's simply
*another* public entry point in front of the same backend.

## 2. What This Means Architecturally
```
                     ┌─────────────────┐
Postman ──────────▶ │   API Gateway    │ ──┐
   │                 └─────────────────┘   │
   │                                         ▼
   └───────────────────────────────────▶  ALB  ──▶ ECS Fargate ──▶ RDS
        (direct, bypasses API GW)
```
Both paths reach the same ECS tasks. This is actually called out as a known
trade-off of the current setup in `docs/ALB.md` §3 and `docs/PROD.md` §3.1 —
the public ALB is a real gap today, not a hypothetical one.

## 3. Advantages of Keeping API Gateway (Even Though the ALB Is Reachable)

| Capability | Via API Gateway | Calling ALB Directly |
|---|---|---|
| **Auth** (API key, IAM/SigV4, Cognito/JWT, Lambda authorizer) | Supported natively — attach an authorizer or usage plan with almost no app code changes | Not available — ALB has no request-level auth of its own beyond listener rules; you'd have to build auth into the Flask app itself |
| **Throttling / quotas** | Built-in **usage plans** (e.g. "100 req/sec, 10,000 req/day per API key") | None — ALB just forwards everything it receives to a healthy target |
| **Request/response transformation** | Can reshape requests/responses, add headers, map errors, without touching backend code | None — whatever the app returns is exactly what the caller gets |
| **Centralized API management** | One place to see all routes, versions, stages (`dev`/`prod`), and deprecate/version endpoints cleanly | ALB only knows about listeners/target groups, not "API" concepts like versioning |
| **Usage metering / API keys per consumer** | Each caller can get their own API key, individually tracked/throttled/revoked | No concept of "callers" at all — anyone who has the URL is indistinguishable from anyone else |
| **WAF / AWS Shield integration** | Easy to attach AWS WAF directly to the API Gateway stage | Can attach WAF to an ALB too, but it's a separate config, not something API Gateway centralizes for you |
| **Decoupling clients from infra changes** | Clients call a stable API Gateway URL; the backend (ALB, ECS, even swapping to Lambda later) can change without clients noticing | Clients are coupled directly to the ALB's DNS name — any backend architecture change (e.g. adopting VPC Link per `docs/PROD.md` §1) breaks them |
| **Network exposure** | Can be combined with **VPC Link** (`docs/PROD.md` §1) so the ALB/NLB behind it is never public at all | Requires the ALB to stay public, since there's nothing else to receive the traffic |
| **Logging / access logs / X-Ray tracing** | CloudWatch access logs + X-Ray tracing built into API Gateway | ALB has its own separate access logs (S3), not integrated with API Gateway's request-tracing model |
| **Cost at demo-level traffic** | REST API: $3.50/million requests — negligible at this volume (see `docs/COSTS.md` §1) | Free (no per-request charge for ALB beyond its flat hourly + LCU cost, already paid regardless) |

**Bottom line:** for a demo, API Gateway adds a bit of cost and complexity for
capabilities you're not using yet (no auth, no throttling configured today —
`authorization = "NONE"` in `modules/apigw/main.tf`). Its real value shows up
once you need auth, rate limiting, multiple consumers, or want to keep the
backend infra swappable/private — which is exactly the direction
`docs/PROD.md` describes for a production setup.

## 4. Why This Demo Keeps API Gateway Anyway
Per `docs/CONTEXT.md` §3/§9, API Gateway was chosen as "Tier 1" from the
start specifically to **demonstrate the 3-tier pattern** (client → API layer
→ compute → data), not because this specific demo currently needs auth or
throttling. Removing it would technically still work (see §1 above), but
would collapse the architecture to 2 tiers and lose the teaching value of
showing how a managed API layer fronts a container backend.

## 5. If You Wanted to Actually Remove API Gateway
Not recommended for this project's stated purpose (§4), but if a leaner
demo/prod variant intentionally wanted ALB as the sole public entry point:
1. Delete the `apigw` module block from `src/infra/main.tf`.
2. Point clients at the ALB's DNS name directly (or put a custom domain +
   Route 53 record + ACM cert in front of the ALB instead — see
   `docs/PROD.md` §3.1 for the HTTPS listener setup either way).
3. You'd then need to build any auth/throttling/rate-limiting **into the
   Flask app itself** (e.g. Flask-Limiter, API key middleware) since the ALB
   won't provide it, unlike API Gateway.
4. You'd lose the option to later hide the ALB entirely behind VPC Link
   (`docs/PROD.md` §1) — that pattern specifically depends on API Gateway
   being the public-facing piece.

## 6. Closing the Direct-ALB Gap (Instead of Removing API Gateway)
If the goal is "only API Gateway should be usable, not the raw ALB" (the more
likely intent for prod), the fix isn't removing API Gateway — it's closing
the direct-access hole documented in `docs/PROD.md` §3.1 ("Problem 2"):
either restrict the ALB security group to API Gateway's published IP ranges,
or (stronger) move to an internal ALB/NLB behind a **VPC Link**
(`docs/PROD.md` §1), so the ALB has no public IP for anyone to call directly
in the first place.
