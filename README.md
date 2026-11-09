# agentic-verdict

**Job 3 — AI Pass 2 hub.** Final LLM review, `🤖 AI Code Review` PR comment, and labels.

Does **not** run lint, Semgrep, Docker, or DAST. It only **consumes artifacts** from earlier jobs and posts the verdict. Later, DAST reports from [agentic-dast](https://github.com/bayer-int/agentic-dast#readme) can feed the same Pass 2 step.

## Part of the Agentic AppSec platform

This repo is one of four hubs that together give Bayer teams agentic SAST and DAST checks: open-source scanners, with findings explained and prioritized by AI. For the problem statement, the full architecture diagram and the end-to-end PR flow, see **[Platform overview in agentic-review](https://github.com/bayer-int/agentic-review#platform-overview)**.

```mermaid
flowchart LR
    LOCAL["Developer machine<br/>run-qg · chat · pre-push"]
    subgraph PRF["Pull request — GitHub Actions"]
        direction LR
        R["1 · agentic-review<br/>AI Pass 1"] --> Q["2 · agentic-quality-gate<br/>Sonar-style gate"] --> V["3 · agentic-verdict<br/>AI Pass 2"]
    end
    URL[("Non-prod URL")] --> D["4 · agentic-dast<br/>ZAP · Nuclei · AI triage"]
    LOCAL -. "same engines and rules" .-> Q

    classDef hub fill:#10384f,stroke:#0091df,stroke-width:2px,color:#ffffff
    classDef here fill:#de0043,stroke:#10384f,stroke-width:3px,color:#ffffff
    classDef dev fill:#e7f8ff,stroke:#0091df,stroke-width:2px,color:#10384f
    classDef env fill:#f5f5f5,stroke:#737373,color:#10384f
    class R,Q,V,D hub
    class V here
    class LOCAL dev
    class URL env
    style PRF fill:#f4fbff,stroke:#10384f,color:#10384f
```

<sub>Highlighted in pink: this repo.</sub>

| # | Hub | Role |
|:-:|:----|:-----|
| 1 | [agentic-review](https://github.com/bayer-int/agentic-review#readme) | AI Pass 1: detects the stack, runs lint / test / build, dependency audit, secret and IaC scans |
| 2 | [agentic-quality-gate](https://github.com/bayer-int/agentic-quality-gate#readme) | Sonar-style gate: security hotspots, secrets, duplication, complexity, coverage. Also runs locally as `run-qg` |
| 3 | **agentic-verdict** (this repo) | AI Pass 2: weighs all evidence, posts the final PR review, approve / request changes, label |
| 4 | [agentic-dast](https://github.com/bayer-int/agentic-dast#readme) | Runtime scans of a live non-prod URL (OWASP ZAP + Nuclei) with AI triage into a sticky Issue |

---

## Where it sits in the PR pipeline

| Order | Hub | Workflow | Responsibility |
|------:|-----|-----|----------------|
| 1 | [`agentic-review`](https://github.com/bayer-int/agentic-review#readme) | `ai-review-phase1.yml` | Pass 1, lint/test checks, security; uploads `agentic-coverage` |
| 2 | [`agentic-quality-gate`](https://github.com/bayer-int/agentic-quality-gate#readme) | `quality-gate.yml` | Semgrep, duplication %, complexity, coverage % |
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
