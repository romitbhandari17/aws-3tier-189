# Project Context: everythingAWS 3-Tier Demo

## 1. Purpose
This is a **demo/learning project** showing a minimal AWS 3-tier architecture.
The app exposes a single API that returns the number of courses offered by
"everythingAWS". The goal is simplicity — minimum code, heavily commented,
so newcomers to AWS aren't overwhelmed.

## 2. What the API Does
- One endpoint: `GET /courses/count`
- Returns JSON like: `{ "channel": "everythingAWS", "courseCount": 42 }`
- The count is read from a database row (RDS), not hardcoded, to demonstrate
  the 3-tier flow (client → API → app → DB).
- No UI. The API is meant to be called directly via **Postman** (or curl)
  for demo purposes.

## 3. Architecture (3 Tiers)

```
Postman / Client
      │  HTTPS
      ▼
[Tier 1] Amazon API Gateway (REST or HTTP API)
      │  integrates with
      ▼
[Tier 2] ECS Fargate (containerized backend service)
      │  SQL query
      ▼
[Tier 3] Amazon RDS (relational database, e.g. Postgres/MySQL)
```

- **Tier 1 — API Gateway**: Public entry point. Routes `GET /courses/count`
  to the ECS service (via VPC Link / Cloud Map, since Fargate has no public ALB
  in the simplest setup — decision on ALB vs VPC Link to be finalized during
  implementation).
- **Tier 2 — ECS Fargate**: Runs one small containerized app (Node.js or
  Python, TBD) with a single route. Serverless containers — no EC2 to manage.
- **Tier 3 — RDS**: A small managed database instance holding a single table
  with the course count for "everythingAWS".

## 4. Non-Goals (keep it minimal)
- No authentication/authorization (demo only).
- No frontend/UI.
- No CI/CD pipeline (unless requested later).
- No multi-environment setup (just one demo environment).
- No autoscaling policies beyond defaults.

## 5. Tech Stack (proposed, to confirm before coding)
| Layer            | Choice                              |
|------------------|--------------------------------------|
| API Layer        | Amazon API Gateway                  |
| Compute          | ECS Fargate (1 task, 1 container)    |
| Database         | Amazon RDS (PostgreSQL or MySQL)     |
| App language     | Node.js (Express) — simple & common  |
| IaC (optional)   | Terraform or AWS CDK — TBD           |

## 6. Data Model (minimal)
Single table, e.g. `courses`:
| column      | type     | example              |
|-------------|----------|----------------------|
| id          | serial   | 1                    |
| channel     | text     | everythingAWS        |
| course_count| int      | 42                   |

## 7. Code & Documentation Style
- Keep code minimal — one small handler, one small DB query module.
- Every file/function gets a brief comment explaining *what* and *why*.
- Avoid extra abstractions, middleware, or boilerplate not needed for the demo.

## 8. How It Will Be Tested/Demoed
- Deploy infra to AWS.
- Open Postman, hit the API Gateway invoke URL: `GET /courses/count`.
- Confirm JSON response with course count sourced from RDS.

## 9. Open Decisions (to resolve before/while coding)
- Terraform vs CDK vs manual console setup for IaC.
- ALB + ECS vs direct API Gateway → ECS integration (VPC Link).
- Node.js vs Python for the backend service.
- Exact DB engine: PostgreSQL vs MySQL.

## 10. Future Iteration: RAG + Agentic AI

**Goal:** Extend the demo to show a Bedrock-powered AI feature (e.g. an
AI-generated answer/description alongside the course count), and evolve it
from a single LLM call into genuine **Agentic AI** — an agent that reasons,
chooses tools, and loops (plan → act → observe) rather than just returning
generated text.

**Key architecture question: ECS or Lambda for the AI logic?**

| Factor | ECS Fargate | Lambda |
|---|---|---|
| Amazon Bedrock Agents (managed) | Can *invoke* the agent from ECS, but Bedrock Agents' Action Groups (its "tools") **must be backed by Lambda** — an AWS platform constraint, not a choice. | **Required** for the tool/action-executor layer when using managed Bedrock Agents. |
| Custom agent loop (e.g. LangChain/LangGraph orchestrating Bedrock model calls yourself) | Better fit — no execution time cap (Lambda maxes at 15 min), can hold conversation/session state, supports streaming/long-lived connections. | Fine for short, stateless single-turn calls; cold starts add latency; awkward for multi-turn memory. |
| RAG retrieval step | Can keep a local cache/index warm across requests. | Each cold invocation may re-init clients; fine for bursty/infrequent use; scales to zero. |
| Cost model | Always-on, billed whether used or not (like our current Fargate task). | Pay-per-invocation — cheaper for a rarely-used demo feature. |
| Operational simplicity | Keeps everything in one existing service (our Flask app). | Adds a second compute type to explain in the demo. |

**Decision:** Use **Amazon Bedrock Agents (managed)**, with a **Knowledge Base
for RAG** and **Lambda** as the tool executor. This is confirmed for a later
iteration — **work starts only after the 3-tier API (Gateway → ECS → RDS) is
fully deployed and verified working end-to-end via Postman.**

**Possible AWS building blocks:**
- **Amazon Bedrock Agents** — managed agent runtime; handles the reasoning
  loop (plan → call tool → observe → respond) for you.
- **Bedrock Knowledge Base** — if the agent needs RAG (retrieval-augmented
  generation) over reference docs about course content.
- **Lambda (Action Group executor)** — backs the agent's tool calls, e.g. a
  function that reads from the RDS `courses` table.
- **ECS Fargate app** — stays the entry point; forwards "smart" requests to
  the Bedrock Agent instead of answering them directly.

### 10.1 Detailed design: Bedrock Agent + RAG (Knowledge Base)

**Why RAG here:** The agent's job is to answer questions about everythingAWS
course content in natural language (e.g. "roughly what topics does
everythingAWS cover?"). Rather than the model guessing/hallucinating, RAG lets
it retrieve real reference text and ground its answer in that content.

**Components:**

1. **Data source (the "knowledge")**
   - A small set of plain-text/Markdown documents describing everythingAWS
     course content (created by us — not scraped, kept minimal for the demo).
   - Stored in an **S3 bucket** — Bedrock Knowledge Bases read directly from S3.

2. **Bedrock Knowledge Base**
   - Points at the S3 bucket above.
   - Bedrock automatically **chunks** the documents, generates **embeddings**
     (via a Bedrock embedding model, e.g. Titan Embeddings), and stores them
     in a **vector store** (Bedrock supports Amazon OpenSearch Serverless,
     Aurora pgvector, Pinecone, etc. — OpenSearch Serverless is the simplest
     "fully managed, no infra to run" choice for this demo).
   - No manual embedding/indexing code required — Bedrock manages the
     ingestion pipeline once configured.

3. **Amazon Bedrock Agent**
   - **Instructions**: a short prompt defining its role, e.g. "You answer
     questions about the courses offered by everythingAWS, using the provided
     course count tool and knowledge base."
   - **Foundation model**: a Bedrock-hosted model (e.g. Claude) powers its
     reasoning.
   - **Attached Knowledge Base**: the one created in step 2 — lets the agent
     retrieve relevant document chunks automatically when a question needs it.
   - **Action Group**: one tool, `get_course_count`, described via a small
     OpenAPI schema (path, params, response shape) so the agent knows when
     and how to call it.

4. **Lambda (Action Group executor)**
   - A small function implementing `get_course_count`.
   - Connects to the same RDS `courses` table as the ECS app (read-only query).
   - This is the **only new compute** introduced — everything else in this
     step is either S3 (storage) or fully-managed Bedrock services.

5. **How ECS fits in**
   - The Flask app (already handling `GET /courses/count`) gets a new route,
     e.g. `GET /courses/ask?question=...`.
   - That route calls the Bedrock Agent's `InvokeAgent` API with the
     question, and returns the agent's final answer as JSON.
   - ECS does **not** run any AI/agent logic itself — it's just a thin proxy
     into the managed Bedrock Agent, keeping the app minimal.

**Request flow end-to-end:**
```
Postman → API Gateway → ECS (Flask: /courses/ask)
        → Bedrock Agent (InvokeAgent)
              ├─ retrieves relevant chunks from Knowledge Base (RAG)
              └─ decides to call Action Group → Lambda → RDS (if needed)
        → Agent composes final answer
        → ECS returns it as JSON → Postman
```

**Not yet decided (to resolve when this iteration starts):**
- Exact wording/scope of the seed documents for the Knowledge Base.
- Which vector store to use (OpenSearch Serverless vs. Aurora pgvector) —
  OpenSearch Serverless is the current lean choice (no DB to manage).
- Which Bedrock foundation model to use for the agent.
- Whether `/courses/ask` needs any guardrails (e.g. Bedrock Guardrails) given
  it's a public demo endpoint.

---
*This document defines scope and intent only. No implementation code has been
written yet — see repo root once implementation begins.*
