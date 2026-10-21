# agentic-verdict

**Job 3 — AI Pass 2 hub.** Final LLM review, `🤖 AI Code Review` PR comment, and labels.

Does **not** run lint, Semgrep, Docker, or DAST. It only **consumes artifacts** from earlier jobs and posts the verdict. Later you can feed DAST / Burp reports into the same Pass 2 step.

## Three hubs

| Order | Hub | Job | Responsibility |
|------:|-----|-----|----------------|
| 1 | [`agentic-review`](https://github.com/pulumamidi-harsha/agentic-review) | `ai-review-phase1.yml` | Pass 1, lint/test checks, security; uploads `agentic-coverage` |
| 2 | [`agentic-quality-gate`](https://github.com/pulumamidi-harsha/agentic-quality-gate) | `quality-gate.yml` | Semgrep, duplication %, complexity, coverage % |
| 3 | **agentic-verdict** (this) | `ai-verdict.yml` | Pass 2 + PR comment/labels |

## Caller (all three in one workflow)

See [`examples/caller-orchestrated.yml`](examples/caller-orchestrated.yml).

```text
ai-phase1  →  quality-gate  →  ai-verdict
```

Pin every `uses:` / `pipeline_ref` to a **full SHA** before production.

## Secrets

- `AI_API_KEY`, `AI_API_ENDPOINT` (required)
- `ORG_PAT` (optional; clone private hubs)

## Skip labels

`skip-ai-review`, `skip-ai-verdict`, or `no-review`.
